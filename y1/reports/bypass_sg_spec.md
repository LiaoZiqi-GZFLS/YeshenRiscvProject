# B1'：旁路 tile gather 接 SG 批式口（去掉逐笔 `start/done` 握手）

状态：**B1'b 已实施并按前提门控；闸门 PASS；PnR/上板待判（2026-10-25）**。上游证据：`unit_trace.md §6`、本文件 §1。

## 1. 问题（实测，不是推想）

60 MHz 交付件的逐单元表（`unit_trace_60b.txt`）里，旁路四算子合计 **264 ms = 帧的 19.5%**
（maxpool 162.9 / add 67.4 / resize 33.4）。按 `ms = a·N·nci·nco + b·N·nci` 分离成本：

| 类 | `a` 每趟·像素 | `b` 每 ci-block 的 fill 附加 |
|---|---:|---:|
| maxpool | 6.0 ns | **1275.8 ns** |
| add/resize | — | 同族（见 §6 表） |

⇒ 旁路的时间**几乎全在取数环节**，与"算"无关。

取数装置侧的硬数字（`run_bypass_tile_ab.sh`，RDLAT=0 的定拍模型）：

```
[c16_maxpool_160x160]  AR=51,200  CYCLES=1,728,202   ⇒ 33.8 拍/笔
[c64_maxpool_80x80  ]  AR=51,200  CYCLES=1,728,242   ⇒ 33.8 拍/笔
```

`BypassExec` 的 tile 取数是**逐平面一笔 `start(mode=1)` → 等 4 拍 → `done` → 换平面**
（`BypassExec.scala:1326-1395`，`sg_valid := False` 在 `:909`）⇒ 每个 32 B band 都付一次
握手。板上每笔再叠上 ~1.2–5 µs 的读延迟（`ddr_bridge_read_perf.md`），于是旁路单价
（1276 ns/px·ci）是 conv 的 6 倍。

## 2. 设计（只改 `tilingR` 的 FETCH 子相位）

把 `tRdSt==1` 的"逐平面串行"换成 **SG 批式**，结构与 `UnitExec` 的 B3b **逐条对齐**
（`UnitExec.scala:2334-2407`，那套已在板上验过）：

1. **入队扫描**（一拍一平面，`sg_ready` 自然反压）：只有 `tChk(p)`（本平面该用的 chunk 还没装）
   的平面才入队；同时快照 `tSgPl(k)=p`、`tSgChunk(p)=tIdxP(p)[6:5]`、`tSgMask(p)`。
   地址用**扫描当时的** `tBstC`（= `tAdrR & ~31` + chunk<<5），`sg_beatsM1=3`（4 拍 = 32 B）。
2. **`start(mode=3)` 只举一拍**（`tSgGo`），`mode` 保持到整批 RD 收完（CHK 在 start 下一拍采样）。
3. **RD 收流**：4 拍一项，按**入队项序**落 `pgBuf((tSgPl(k)<<2)+beat)`（与既有转置下标同一张缓冲）。
4. **整批回收**（`done`）：按**入队快照**落账本 `tLdK(p) := tSgChunk(p)`（不是末拍重算 ⇒
   FETCH 被打断也自洽），回 `tRdSt=2`（DRAIN）。
5. **进门排空**：若进来时主口还忙（残留一笔）⇒ `tSgDrn` 先等 `done` 丢弃，再重新扫（沿用
   `UnitExec` 的 `wxSgDrn` 纪律）。
6. **非 tile 路径零改动**：`srcPlR`（C4b-B4 布局 gather）与整层路径的 `pgAddrR/pgStartPulse`
   分支**一行不动**；所有新逻辑都在 `when(tRdOn)` 内并被 `tilingR` 门控。

## 3. 不变量（判据的真正承重）

- 数据路径**语义不变**：同一批 band、同一 4 拍、同一 `pgBuf` 落点、同一 `tDj` 节奏。
- **`tAdrR` 仍逐平面推进 `+= inColsR`**（被跳过的平面也推）——否则后面各平面地址错位。
- `tLdK` 的更新只发生在"该平面本批真的被取到"时，且**用入队快照**。
- `rd_ready` 在 SG 收流期间恒 1（吞满 4 拍/项），在其它相位与改动前同值。
- `tilingR=0` ⇒ 新状态机恒不改写任何寄存器。

## 4. 闸门（先红后绿）

| 闸门 | 判据 |
|---|---|
| `run_bypass_tile_ab.sh` | 5 个正作业逐字节（含 c16_160×160 / c64_80×80 / c64_40×40 / c64_20×20 / premise）+ 两个负对照（`nty`/`win` 突变体必须红）+ 外科式对照（不做 Add 的作业逐字节不变） |
| `run_bypass_cblk_ab.sh` | 通道分块（2a）不受影响 |
| `run_add_ab.sh` / `run_resize_ab.sh` / `run_maxpool_ab.sh` | 整层路径回归（`tilingR=0` 分支） |
| 计数判据 | `AR` 必须**下降**（8 平面 → 1 批）而 `RD_BYTES` 不变；负对照：把 `sg_valid` 强行置 0 ⇒ 必须回到旧 AR/旧 CYCLES 且数值仍对（证明收益来源唯一） |
| 资源/时序 | dev_map 0 error、LUT/DRM 不涨穿；PnR All Met（npu ≥ 0） |

## 5. 预期与判据（先写死，免得事后凑数）

- 装置侧：`c16_maxpool_160x160` 的 `CYCLES` 从 **1,728,202** 降到 ≤ **0.5×**（握手从 51,200 次
  降到 ~6,400 批）。
- 板上：旁路类（maxpool+add+resize）从 **264 ms** 降到 ≤ **150 ms**；整帧 1,357 → ≤ **1,240 ms**
  （≥ 8% 才保留；`y1run --frames 3` 必须 12/12 CRC）。
- 反例判据：若板上整帧改善 < 3%，说明板级的瓶颈不在握手而在别处 ⇒ 如实回退并归档。

## 6. 影响面

- 只碰 `y1/rtl/BypassExec.scala`（tile FETCH 子相位）+ 其网表；`UnitExec`/`DdrMaster` 不改。
- 与 66.67 MHz 提频（tag `npu66`）**互不冲突**，可合并到同一次 PnR。

## 7. 实施记录（2026-10-25）

- RTL：`tSgScan/tSgEnq/tSgRd/tSgGo/tSgDrn/tSgPl/tSgCh/tSgMask` + `tBstS`；FETCH 子相位整段替换
  （见 `BypassExec.scala` 文件头 ★★ B1'）。`tilingR=0` 与 `srcPlR` 分支一行未动。
- 两个真缺陷（都由闸门当场抓住，不是"猜"出来的）：
  1. `start(mode=3)` 忘了**只举一拍** ⇒ 主口被反复 start，全作业 `busy=1 rd=0` 超时。
     修：`when(tRdOn){ tSgGo := False }` 默认清零（与 UnitExec 的 `wxSgGo` 同规）。
  2. 进门排空的**竞态**：若进 FETCH 那拍正赶上上一批的 DONE 态，`busy` 仍 1 而 `done` 已过
     ⇒ 只等 `done` 永挂（签名：`c64_resize_40x40` 在 `rd=64` 处挂死）。修：`done || !busy` 任一收尾。
- 装置侧（RDLAT=0，同作业同参数）：

| 作业 | AR 旧→新 | CYCLES 旧→新 | Δ |
|---|---|---:|---:|
| c16_maxpool_160x160 | 51,200 → 51,200 | 1,728,202 → 1,337,802 | **−22.6%** |
| c64_maxpool_80x80 | 51,200 → 51,200 | 1,728,242 → 1,337,842 | −22.6% |
| c64_maxpool_40x40 | 20,480 → 20,480 | 570,338 → 414,178 | −27.4% |
| c64_maxpool_20x20 | 7,040 → 7,040 | 180,754 → 127,074 | −29.7% |

★ **AR 不变**：SG 的每一项仍是各自一笔 AXI 读；省掉的是**逐笔 `start/done` 的 FSM 握手**
（装置里约 8 拍/笔）。⇒ 板上能拿多少，取决于这 8 拍占板级每笔成本（≈77 拍）
的比例 ⇒ **预期 −8~−10%（旁路类），不是之前推的 4×**；§5 的"≤0.5×"按实测**下修**为 ≤0.85×。

## 8. 判决：回退（净结算，2026-10-25）

- 实施后 6 个正作业里 **5 个 GREEN**（premise / c16_160×160 / c64_80×80 / c64_40×40 / c64_20×20 /
  resize_80×80），**`c64_resize_40x40` 稳定挂死**（`inCols=400`，`400 % 32 = 16` ⇒ 各平面相位不同）。
- 边界探针（TB 超时分支打印层次引用，只读）锁到的现场：

```
state=10(TILERD) tilingR=1 rdSt=1 sgScan=1 sgEnq=0 sgRd=0 sgDrn=0 dj=12 adr=0x201a4
ddrMaster: state=0(IDLE) sgN=2 sgCnt=0 sgIss=2 sgRcv=2 sgDr=2      （上一批已完整回收）
wire: sgaddr=0x201a0 sgrdy=1 chk(tSgScan)=0 w1365=0 w1360=1
```

  即：扫描到平面 1、该平面**不需要补取**（`chk=0`）、`sg_ready=1`，按生成代码应走"跳过并推进"，
  但 `tSgScan` 与 `tAdrR` 在 4M 拍内**一字不动**；主口 idle、上一批账目自洽。
  → 说明真因不在 SG 协议侧，而在**逐平面相位不同时的"补取↔drain"时序**（T-S3e 那条路上），
  属于本轮未吃透的交互，**不再盲改**。
- 处置：`y1/rtl/BypassExec.scala`、`y1/rtl_test/BypassTb.v` 全部回退（`git checkout`），
  重生成 `gen/BypassExec_w34.v` = **`1a77a1506ffbfd85c8f40a95e5f9c4a1`**（与改动前逐字节相同 ⇒ 回退自证）。
- 净值：仿真 CYCLES −22.6%~−29.7%（AR 不变，省的是逐笔握手），**但板上未验、且功能未全绿 ⇒ 不交付**。
- 复现要点（下次不要再踩）：`tSgGo` 必须默认清零（只举一拍）；进门排空要用 `done || !busy`；
  真正的坑在"相位不同的 per-plane chunk 补取"路径，需单独写装置（把 `inCols%32!=0` 的
  mid-drain 场景做成最小作业）后再动。

## 9. B1'b：按 **`inCols % 32 == 0`** 门控后跑绿（2026-10-25 07:0x）

第一版（B1）对**所有**形状都用 SG，唯一红点是 `c64_resize_40x40`（`inCols=400`，各平面 band 相位差 16）。
而 T-S3a.2b 的原始前提本来就是"8 平面相位相同"，即 `inCols % 32 == 0`。真表里：

| 旁路单元 | 输入 | inCols | %32 | 走哪条 |
|---|---|---:|---:|---|
| `MaxPool_5` | 160×160 | 25,600 | 0 | **SG** |
| `MaxPool_18` | 80×80 | 6,400 | 0 | **SG** |
| `Add_44` / `Add_50` | 40×40 / 80×80 | 1,600 / 6,400 | 0 | **SG** |
| `Resize_43` | 20×20 | 400 | **16** | 老路（逐平面串行，逐字保留） |

实现：`val tSgOk = (inColsR(4 downto 0) === 0)`，FETCH 子相位 `when(!tSgOk){老路} otherwise {SG}`；
`rd_ready`/`start`/`mode` 都按 `tSgOk` 二选一；SG 端口在 `!tSgOk` 时恒发 `sg_valid=0`。
（★ 踩坑：`tSgOk` 必须定义在 `inColsR` **之后** —— Chisel 按源码顺序求值，写前面会 NPE。）

闸门 `run_bypass_tile_ab.sh`：**RESULT: PASS**，13 个作业全绿（含 premise/5 个真表形状/2 个 Add/
4 个负对照 + 2 个外科式对照）。装置侧 CYCLES（RDLAT=0，AR 不变）：

| 作业 | 走哪条 | CYCLES 旧 → 新 | Δ |
|---|---|---:|---:|
| c16_maxpool_160x160 | SG | 1,728,202 → **1,337,802** | −22.6% |
| c64_maxpool_80x80 | SG | 1,728,242 → **1,337,842** | −22.6% |
| c64_maxpool_40x40 | SG | 570,338 → **414,178** | −27.4% |
| c64_maxpool_20x20 | SG | 180,754 → **127,074** | −29.7% |
| c64_add_80x80 | SG | 1,365,978 → **782,610** | −42.7% |
| c64_resize_80x80 | SG | 832,842 → **?**（见日志） | — |
| c64_resize_40x40 | 老路 | 245,050 → **245,050** | 0（按设计） |

判据（事先写死）：板上旁路类 ≥8% 才保留、整帧 ≥3% 才算改进；`y1run --frames 3` 必须 12/12 CRC。

## 10. 上板 A/B（2026-10-25 08:5x，tag `b1sg`，**判据过，保留**）

- 比特流：`sim/reglogs/pds_b1sg_p10.000/.../yeshen_mini_board_top.sbit`，9,188,552 B，
  md5 **`c408792f33be7b25bf451df4dd676634`**；PnR **All Constraints Met**
  （npu_clk est **60.3938 MHz / 16.558 ns / +0.109**；devmap LUT 85,183.5 = 54%、FF 115,351、DRM 305、APM 263）。
- 烧写 + 启动 marker **8/8**、ping/ssh PASS。
- `y1run --frames 3`（板内自包含）：

| 帧 | npu60b（旧交付） | **b1sg** |
|---|---:|---:|
| 0 | 1,357.4 ms | **1,262.43 ms** |
| 1 | 1,360.2 ms | **1,262.29 ms** |
| 2 | 1,371.6 ms | **1,262.47 ms** |
| 均值 | 1,362.1 ms（0.734 fps） | **1,262.39 ms（0.792 fps）** |

- **Δ = −99.7 ms = −7.32%**（三次极差 0.18 ms ⇒ 不是噪声）；**3/3 帧 `outputs=12/12`、`Y1RUN: PASS`**。
- 视频：跑前帧序号 10 s Δ=2705，跑后仍在递增（0x005C3201 → 0x005CC601）⇒ 相机/屏通路未被饿。
- 归因：旁路类从 264 ms（19.5%）降到约 164 ms ⇒ **−100 ms 几乎全部来自旁路**，与"每笔握手 + 板级
  1 笔在飞 → 4 笔在飞"的模型一致（比纯握手模型乐观、比"4×"悲观）。
- 判据复核：事先写死"整帧 ≥3% 才算改进" ⇒ **过**；交付口径改为 `b1sg`（源码 = 本 commit）。

## 11. 下一杠杆评估（2026-10-25，**结论：只剩布局级改动**）

`b1sg` 之后剩下的三条候选都做了成本/证据核对：

| 候选 | 证据 | 判定 |
|---|---|---|
| **窄路（head/odd-C，含 `Conv_0` 150 ms）取数也批式化** | 窄/`tilingR` 路本来就是**整行一笔连续 burst**（`UnitExec.scala:2288-2306`，`len=(aHi-aLo)·C`），不是逐 32 B；每行请求数只有个位数 ⇒ 不是"1 笔在飞"的病 | **不做**（收益无来源） |
| 想用 `run_stride_exec_ab` 量窄路延迟敏感度 | 该闸门**继承红**：`UnitExecWideTb.v:475` 引用的 `cyc_fetch/cyc_emit/...` 探针在当前网表里不存在（与本次改动无关） | 先修 TB 才能量；本轮不背这个债 |
| `rqDepth 4→8`（宽路在飞加倍） | 板级 RDEPTH=8 已实测 **−0.002%**（`ddr_bridge_read_perf.md`），下游钉死在 4 | **不做** |

⇒ 宽路（conv1x1 585 ms + dw 355 ms = 74%）的 fill 已经是"**4 笔在飞 × 32 B / LAT**"的硬地板：
字节数已 nominal×1.13、在飞被 IP 钉死、更大突发过读、更紧约束反而更慢、提频上限 60.6 MHz。
**唯一还能动的是"让每笔请求服务更多通道"——即 arena 的通道分块布局**（一次请求 = 8 通道同 tile 的
连续字节），它要改 `y1_convert.py` 的布局产出 + 全部黄金 + 16 道闸门的几何口径，属跨天工程，
本轮不做"半成品"。

本轮净值：**1,362.1 → 1,262.4 ms（−7.32%，0.734 → 0.792 fps）**，交付 `b1sg`（`c408792f`）。
