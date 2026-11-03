# gather 与算的重叠（G3）：把 fill 藏进 drain

日期：2026-10-25　状态：**spec（未动代码）**　前置：`b1sg` 交付（1,262.4 ms）、`xgsg` 在跑

## 1. 先纠正一条账：整帧读字节是 17.42 MB，不是 22.57 MB

`y1/tools/cb_layout_account.py` 的 `planar()` 按"**每个 tile 都读满 34 列**"建模
（`byt = ntx·nty·rows·win·8·nci`），它只在 `W%32==0` 的层上与实测重合
（`Conv_15` 924,800 = nominal×1.1289）；**对 40×40 / 20×20 这类层会把边缘 tile 当满窗**，
于是把整帧抬到 22.57 MB 并写进了 `arena_channel_block_spec.md §6` 与
`wrapup_status_2026-10-23.md §J.12` 的"1 FPS == 读地板"结论。

RTL 和闸门都不是满窗口径：`UnitExec.scala` 的 tile 网格按
`ox1=min(ox0+WT, Wo)`、`oy1=min(oy0+HT, Ho)` **裁剪**；闸门 `run_b1_tilebuf_ab.sh` 的
`gexp()` 也逐 tile 用 `tw=min(WT, W-tx·WT)`、`th=min(HT, H-ty·HT)` 算期望，并与
`gather_bytes` 逐值对过（`GB_OK=1`）。按同口径重算整帧：

| 分辨率 | 单元数 | 交付字节 | nominal | 放大 |
|---|---:|---:|---:|---:|
| 160×160 | 8 | 6,936,000 | 6,144,000 | 1.13 |
| 80×80 | 14 | 4,851,776 | 4,198,400 | 1.16 |
| 320×320 | 3 | 4,046,000 | 3,584,000 | 1.13 |
| 40×40 | 14 | 1,270,016 | 1,049,600 | 1.21 |
| 20×20 | 14 | 317,504 | 262,400 | 1.21 |
| **合计** | 53 | **17,421,296** | 15,238,400 | **1.143** |

⇒ conv/dw 的 gather = **17.42 MB**；加旁路读约 1.6 MB ⇒ 读地板 ≈ **720–790 ms**（@24.2 MB/s），
**不是 1.0 s**。两个旧报告里的 22.57 MB 与"1 FPS == 地板"作废（已回填更正指针）。

## 2. 板上反证：逐单元时间就落在"交付字节 / 24.2 MB/s"上

用 `unit_trace_60b.txt`（60 MHz、`npu60b`）的实测 ms 与上表逐单元比：

| 单元 | 类型 | 交付字节 | 地板 @24.2 | 实测 ms | 占比 |
|---|---|---:|---:|---:|---:|
| Conv_3 | dw 320² | 1,849,600 | 76 | **76.28** | 100% |
| Conv_16 | dw 160² | 1,849,600 | 76 | **75.28** | 99% |
| Conv_13 | dw 160² | 924,800 | 38 | **37.51** | 99% |
| Conv_10 | dw 160² | 924,800 | 38 | **37.48** | 99% |
| Conv_2 | 1×1 320² | 1,849,600 | 76 | 89.80 | 85% |
| Conv_15 | 1×1 160² | 924,800 | 38 | 103.96 | **37%** |

- **dw 逐个贴着读墙**（99–100%）⇒ dw 的 355 ms 已经是纯 fill，无可重叠。
- **conv1x1 只吃到 37–85%**：`Conv_15` 这类"fill 38 ms + 算 66 ms"的单元占多数，
  585 ms 里约 **220 ms 是 fill、360 ms 是算**，二者**串行**（FETCH → DRAIN 严格互斥）。

## 3. 结论：帧 = fill + 算，重叠度为零

逐类把"交付字节 ÷ 24.2 MB/s"（地板）与实测 ms 并排（`unit_trace_60b.txt`，60 MHz）：

| 类 | 单元数 | 地板 ms | 实测 ms | 实测/地板 | 非 fill（算） |
|---|---:|---:|---:|---:|---:|
| depthwise | — | 332 | 355 | **1.07** | 23 |
| conv1x1 | — | 373 | 585 | **1.57** | **212** |
| conv3x3（`Conv_0` 为主） | 1 大 | 15* | 154 | 10.5* | ~139* |
| 旁路四算子 | 14 | 205† | 263 | 1.28 | 58 |
| **合计** | | **925** | **1,357** | 1.47 | **~432** |

\* `Conv_0` 的地板被上面 `s=2` 的公式低估（表里按输出几何算）；它的真读量 ≈ 1.35 MB
（640×640×3 的 s=2 窗口）⇒ 地板 ≈ 56 ms，实测 154 ⇒ 仍是**串行 1 笔在飞**的暴露（本片 `xgsg` 在修）。
† 旁路取 `wgt_index.in_bytes` 合计 4.45 MB（maxpool 3.79 + add 0.51×2 输入 + resize 0.13），
×1.13–1.21 的裁剪放大 ≈ 5.0 MB。

⇒ **地板 ≈ 925 ms；实测 1,357 ms 的地板外部分 ≈ 432 ms，且与 fill 完全不重叠**
（`wxSt` 的 FETCH/EMIT 串行）。可重叠上限 = 各单元的 `min(fill, 算)` ≈ **340 ms**
（conv1x1 212 为主）⇒ 帧 **~1,000–1,050 ms（0.95–1.0 fps）**；
叠加 `xgsg` 的 ~−90 ms ⇒ **~930–960 ms（1.04–1.07 fps）**。

## 4. 设计（只动 `TILING` 的**宽路 tiled** 相位）

现状（`UnitExec.scala:2440-2480` 的 `wx` 小 FSM）：每列走 `DECIDE`→(`FETCH` 若本 band 未装)→`EMIT`，
`wxSt` 串行；`xwBuf` 只有一份。`DdrMaster` 在 `done` 后回 IDLE，下一 band 的 `start` 必须等
EMIT 走完 ⇒ 整段 fill 暴露。

### 4.1 关键地址事实（决定了 prefetch 可以**零乘法器**）

`wxPBB(p) = (wxGAbs + tInPixW·p) & ~31`。同一行内**下一个 band** = `wxPBB(p) + 32`
（`+32` 不改低 5 位 ⇒ 对齐结果恰是下一条 32 B band）。⇒ prefetch 地址直接取
`wxPBB(p) + 32`，**不新增任何 `tInPixW·p` 乘链**（对 npu 头号路径零影响）。

同一行的下一个 band 存在 ⇔ `wxG + 32` 仍在窗口内（`tWinLo ≤ wxG+32 < tWinHi`）：
s=1 的 34 列窗口 ⇒ 只在 `wCol ∈ {0,1}` 成立；s=2 的 18 列窗口 ⇒ 永不成立（自动退化为今天的串行，
**不引入新语义**）。

### 4.2 结构

1. `xwBuf` 扩成 2 份（`64 × C·8 bit`；C=8 时共 512 B）。`wxSgBuf`（本批写入哪份）、
   `wxEBuf`（当前喂列读哪份）各 1 位。
2. **第二本 band 账**：`wxB2V`（1 位）+ `wxB2B`（32 位）—— prefetch 完成时写它，
   不动 `wxBndV/wxBndB`（保持"主账 = 主 fetch 装的 band"语义）。`wxPNE(p)` 改为
   `!((wxBndV(p) && wxPBB(p)===wxBndB(p)) || (wxB2V && wxPBB(p)===wxB2B))`；
   喂列时 `wxEBuf := (wxBB === wxB2B) && wxB2V`。
3. **prefetch 子相位**（只在 `wxSt === EMIT` 时活动，复用主 FSM 的 `wxSg*` 扫描/收流寄存器，
   但**另一组**：`wpvScan/wpvEnq/wpvRd/wpvGo/wpvDrn`）：
   - 进入条件：本行还没 prefetch 过（`wpvRowOk === False`）∧ `wCol ≤ 1` ∧ 主口 IDLE ∧
     `wxG+32` 在窗口内 ∧ `wxNPl ≥ 1`；
   - 扫 `p=0..7` 中 `wxUse(p)` 且 `wxPBB(p)+32 =/= wxB2B` 的平面 ⇒ `sg_addr = wxPBB(p)+32`，
     `sg_beatsM1 = 3`；扫完发一拍 `start(mode=3)`；
   - 收流落 `xwBuf` 的**另一份**（`wxSgBuf`），`done` 时写 `wxB2V/wxB2B`；
   - 与主 gather 的互斥：**同一时刻只允许一批在飞**（`wpvGo` 只在 `!ddrMaster.io.busy` 且
     `wxSt===EMIT` 时举）；EMIT 结束时若 prefetch 未完成 ⇒ 记"未命中"，本行退回串行（不阻塞）。
4. **命中快路**：DECIDE 时若 `wxNeedB` 为假（因为 `wxB2B` 命中）⇒ 照今天一样直接 EMIT，
   只是 `wxEBuf` 指向另一份。
5. **边界**：换 tile / 换 ci / 换行 ⇒ 清 `wpvRowOk` 与 `wxB2V`（`+32` 的地址不再属于本行窗口）。

### 4.3 为什么这是最小可行版（不做跨行/跨 tile）

跨行预取要给"下一行首个 band"重算 `wxRowBas + tInWi + …`（含一次 `tInWi` 乘），
既碰时序又碰窗口边界；而本行第二个 band 的地址是**纯加法**。先拿这一档：
每行 2 个 band ⇒ 每行**暴露 1 个**，宽路 s=1 层的 fill 约减半。

## 5. 闸门

1. **单元级（先红后绿）**：复用 `run_b1_tilebuf_ab.sh` —— 逐字节 == 冻结黄金、
   `GATHER_BYTES` 逐值不变（**字节数不许变**）；新增诊断 `OVL_HIT`（下一组是否已在飞）。
   负对照：把提前发关掉（等价今天的串行）⇒ 数值仍逐字节对、周期变长（红点唯一）。
2. **tiling2d / b2_halo**：s=1 六几何 + s=2 32×32 + 两负对照全绿。
3. **冻结**：`TILING=false` 三份 md5 不变（`2a53bcd0/fa688c59/90ffe8e5`）。
4. **时序**：PnR `All Constraints Met`，npu 域 WNS ≥ 0 @16.667 ns；DRM 余量（现 305/415）。
5. **上板**：`y1run --frames 3` 12/12 ×3；对 `xgsg` 定案值 **≥5% 才保留**（本 spec 预期 −12~17%）；
   视频/屏幕不回归（`VIDEO.STATUS` seq 5 s 内增长、`init_done=1`）。

## 6. 风险

| 风险 | 对策 |
|---|---|
| 与 G2-c 同类的 owner/`done` 竞态（那次 2/12 CRC） | 只允许一批在飞；换组只在 `done` 之后登记；单元闸门里加"双批并发"负对照必须红 |
| `xwBuf` 双份抬 DRAM/FF | 512 B×2；先看 dev_map，DRM 305→306 以内可接受 |
| 提前发把 `rd_ready` 争给收流相位、饿死 DRAIN | 收流只在 `sg_rd` 相位给 `rd_ready`；DRAIN 相位优先 |
| 视觉回归 | 上板 A/B 同时看 `init_done`/seq 与 12/12 CRC |

## 7. 停止条件

若单元闸门证明"下一组在飞"没有减少周期（<2%）⇒ 说明 `DdrMaster` 的 `done→IDLE` 不是瓶颈
（另有限制项），本片回退并留档，不再迭代。

## 8. 实施锚点（G3-lite，等 G4 上板定案后照此改）

前提：G4 已把 `xwBuf` 扩到 64 项（平面×8 字），**32 B band 只占 4 字** ⇒ 每平面还剩 4 字空位，
正好放"本行的第二个 band"——G3-lite **不需要再扩缓冲**。

| 项 | 现状（`UnitExec.scala`） | 改法 |
|---|---|---|
| 状态机 | `wxSt`：1=DECIDE / 2=FETCH / 3=EMIT | 不变；prefetch 只在 `wxSt===3` 活动 |
| 需要新 band | `wxNeedB = wxPNE.reduce(_||_)` | 不变（第二 band 命中时不触发 FETCH） |
| 第二本账 | 无 | 加 `wxB2V(p)/wxB2B(p)`（8+8 个 reg）；`wxPNE(p)` 追加 `|| (wxB2V(p) && wxPBB(p)===wxB2B(p))` 的取反项 |
| 取数 | 主 gather 的 `wxSg*` 扫/发/收 | 加 **第二组** `wpvScan/wpvEnq/wpvRd/wpvGo/wpvDrain`（各 4/4/1/1/1 位） |
| 触发 | — | `wxSt===3 && !wpvDone && wCol<=1 && !ddrMaster.io.busy && (wxG+32)<tWinHi` |
| 地址 | — | `sg_addr = wxPBB(p) + 32`（**纯加法**）；`sg_beatsM1=3` |
| 落点 | `xwBuf(plane*8 + beat)` | prefetch 落 `xwBuf(plane*8 + 4 + beat)` |
| 读列 | `xwBuf(cl*8 + PIDX(cl)(5:3))`（G4 两 band 档）或 `PIDX(4:3)` | 追加：本列所属 band == `wxB2B` 时用 `+4` 偏移 |
| 边界 | — | 换行（`wRow` 前进）/ 换 tile / 换 ci ⇒ `wpvDone:=False`、`wxB2V:=False` |
| 冻结 | `TILING=false` 三网表 | 全部新代码放在 `if (TILING)` 分支 ⇒ 归一化 diff 必须仍是 **0 行** |

判据：`run_b1` 的 `+G4_SEEN` 旁再加 `OVL_SEEN`（prefetch 真的发过 batch）；
`OVL_SEEN=1` 且逐字节对；再把触发关掉做负对照 ⇒ 数值仍对、`CYCLES` 变长（红点唯一）。
上板：对 G4 定案值 **≥5% 才保留**。
