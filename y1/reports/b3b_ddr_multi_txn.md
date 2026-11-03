# B3b 设计：DdrMaster 多事务队列（SG-RD，mode=3）

状态：**实施完成（仿真全绿；PnR `video1b3b` 进行中）**。实测：SG 单元闸门 + 5 个 DdrMaster 回归 +
B2 四档 + B1/旁路 5 个回归全绿；`s2` 喂列拍数 −36.8%、`dw` −36.8%、`c16` −11.8%、`c64` −3.3%。
目标：把宽层 gather 的 **8 个平面**从"逐平面 14 拍往返"改成"一次进队、多笔在飞、按序回收"。

## 1. 现状与缺口

- `DdrMaster.start` 只在 **IDLE** 接受（`is(IDLE){ when(io.start){...} }`）；`rqDepth=4` 的块槽预取
  只作用于**一笔事务内部**的连续块（`qAddr += bytes`）。
- 宽层 gather 的 8 个平面是 **8 笔非连续事务**（地址间隔 `tInPixW=HW`），每笔 32 B：
  AR→4 拍 R→推流→done，实测每平面 ~14 拍、8 平面串行 ≈ 112 拍/band。
- 桥已验证支持 **≥4 笔 AR 在飞**（L2b 的 `qCanIssue` 就是 4 槽；`run_ddrmaster_rdq_ab.sh` 的
  `MAXOUT≥2` 正档）。⇒ 只要把"多笔事务"接进同一个槽流，就能把 8×14 拍压到 ~latency + 32 拍。

## 2. 契约（新增，向后兼容）

### 2.1 端口（新增 4 个输入 / 1 个输出，只在 mode=3 使用）

```
io.sg_valid    : in  Bool
io.sg_ready    : out Bool            // = (state===IDLE) && (sgCnt < SG_DEPTH)
io.sg_addr     : in  UInt(ADDR_W)    // 必须 32 B 对齐
io.sg_beatsM1  : in  UInt(4 bits)    // 每项拍数-1；合法 = 3/7/11/15（32/64/96/128 B）
```

- 队深 `SG_DEPTH = 8`（= 宽层 `NCOB_MAX`，一次 gather 最多 8 个平面）。
- 入队**只在 IDLE** 允许（`sg_ready` 只在 IDLE 且未满时举）；忙时的入队被反压（不静默丢）。
- 非法项（地址非 32 B 对齐 / `beatsM1(1:0) != 2'b11`）⇒ `sg_ready=0` + `err` 一拍（不搬、不丢队列）。
- 队内保存 `{addr, beatsM1}`（8 × 32 bit 寄存器）；`sgCnt` = 当前队内项数。

### 2.2 模式 3（SG-RD）

- `start && mode===3`：把 `sgN := sgCnt` 闩存；`sgN==0` ⇒ `err` 一拍、回 IDLE；
  否则清 `sgIss/sgRcv/sgDr`，进 **SGRUN**。
- SGRUN（与 QRUN 同构，只是地址来自队列）：
  - `sgCanIssue = (sgIss < sgN) && ((sgIss - sgDr) < RQ)`；
  - AR：`addr = sgQ[sgIss % SG_DEPTH].addr`、`len = sgQ[...].beatsM1`；握手后 `sgIss++`；
  - R：按序落 `qbuf[sgRcv % RQ]`，按 `qLen[slot]` 收满一项后 `sgRcv++`（同一 AXI ID、按序 R ⇒ 无需 id 重排）；
  - 排空：`rd_valid` 从 `qbuf[sgDr % RQ]` 按拍推，收满一项后 `sgDr++`；
  - `sgIss==sgN && sgDr==sgN` ⇒ DONE（**一个** `done` 脉冲）；DONE 里清 `sgCnt := 0`。
- `rd_bytes = Σ items`；`wr_bytes=0`；`busy/done/err/cyc` 语义不变。
- **mode 0/1/2 的路径一行不改**；`sg_*` 在非 3 模式下无副作用。
- ★ 承重细节（2026-10-21 实测）：`start` 是**一拍脉冲**，而 `CHK` 在**下一拍**才读 `io.mode` ⇒
  `mode` 必须**保持到 CHK 采样那一拍**（实现用 `wxSgRd` 整个收流相位），不能跟随 `start` 脉冲。
  否则 CHK 读回 1 ⇒ 整批退化成单笔 QRUN（每批只落平面 0），计数仍然对、数值全错。

### 2.3 其它实例化

`BypassExec / DescFetch / NpuTop / DmaEngine` 的 DdrMaster 实例：
`.sg_valid(False), .sg_addr(0), .sg_beatsM1(0)`（不接线即无 SG 行为）。
**注意**：加端口会改 `TILING=false` 三份网表的 md5（DdrMaster 被内联）⇒ 需要**主动重锚**
（6 个闸门的 `EXPECT_*` 常量 + 备注）；这是接口级变更的已知代价，不是回归。

## 3. gather 接线（UnitExec，宽路 tile）

- DECIDE（`wxNeedB`）里做入队，**不新增 wxSt 状态**（wxSt 仍是 2 bit）：
  - `enqCnt` 从 0 起：每拍对**下一个需要取的平面** `p`（`wxPNE(p)`）发 `sg_valid`，
    `sg_addr = wxFAdrR + p*tInPixW`、`sg_beatsM1=3`，并记 `sgPl(enqCnt)=p`；
    `sg_ready` 未举则保持（顺带天然反压）。
  - 入队完（enqCnt==k）⇒ 发 `start(mode=3)`、`wxSt := FETCH`。
  - **残余在飞**（上一条 tail 预取）：DECIDE 进门先看 `ddrMaster.busy` ⇒ 在 DECIDE 里
    `rd_ready=1` 排空到 `done`，清全部 `wxBndV`，再入队（等价于现有 `wxOrphan` 的语义）。
- FETCH：`rd_valid` 按拍写 `xwBuf(sgPl(wxFPl)*4 + wxFBe)`；4 拍后 `wxFPl++`；
  `done` ⇒ 对 `sgPl(0..k-1)` 落 band 账本（`addr & ~31`）、`b2FB += 32k`（仅 `wRow<tNRow`）、回 DECIDE。
- `gather_fetch_bytes` 的口径**不变**（仍是"窗口行、每个 32 B band 计 32"）；
  `gather_bytes`（交付）不变。
- 取数集合与顺序：`wxPNE` 的判定一字不改 ⇒ 与 B2/B3a 的逐列模型**逐 band 相同**。

## 4. 闸门

1. **DdrMaster SG 单元闸门**（新 `rtl_test/DdrSgTb.v` + `run_ddrmaster_sg_ab.sh`，照抄 `DdrRdQTb`
   的 MAXOUT/字节对账骨架）：
   - 正档：N=1/2/4/8，地址随机 32 B 对齐、散布在 16 KB；收流逐字节 == 内存；`RDBYTES=N*32`；
     `MAXOUT ≥ 2`（N≥2）；一项一个 32 B。
   - 负对照（每条单独发火）：① `sg_addr%32!=0` ⇒ ready 低 + err；② `beatsM1=2` ⇒ ready 低 + err；
     ③ `sgN=0` 的 mode=3 ⇒ err；④ 忙时 `sg_valid` ⇒ ready 低；⑤ 第 9 项 ⇒ ready 低（队满）。
   - 回归：既有 5 个 DdrMaster 闸门（copy/read/write/stream/rdq）全绿（TB 补 `sg_*` tie-off）。
2. **gather 回归**：`run_b2_halo_ab.sh` 四档逐字节 + 双口径计数与 B2/B3a **逐值相同**。
3. `TILING=false` 三份重锚后的 md5 + 其它既有绿闸门。
4. PnR（`video1b3b`）+ 上板 A/B：`y1run` 12/12 CRC、`NPU_MS` 与 B3a 的 2.6141 s 对照。

## 5. 风险与对策

| # | 风险 | 对策 |
|:--|:--|:--|
| R1 | 多笔 AR 在飞要求 R **按序**（同一 `arid=0`） | 桥/模型已保证；SG 只按序落槽，不做 id 重排 |
| R2 | 残余 tail 预取与新批次冲突 | DECIDE 先排空 + 清账（复用 orphan 语义）；`gather_fetch_bytes` 仍只数窗口行 |
| R3 | 入队期间 `wxPNE` 变化 | 入队全在 DECIDE 内完成，`wCol/wRow` 不动 ⇒ `wxPNE` 稳定 |
| R4 | `TILING=false` 冻结被接口变更打破 | **主动重锚** 6 个闸门的 md5 + 在报告写明；既有模式行为用闸门回归证明 |
| R5 | 队满/非法项静默丢 | `sg_ready` 反压 + `err` 脉冲；负对照逐条 |
| R6 | 面积/时序 | 8×32 bit 队 + 现有 qbuf 复用；dev_map 记账，npu 域 +0.533 ns 余量紧，需看 PnR |
| R7 | `mode` 被 CHK 晚一拍采样 | 用 `wxSgRd`（整批相位）保持 mode=3；已用 s2 逐字节 0 失配 + SG 探针 `dstate=13` 验证 |
| R8 | 趟收工打断半批入队 ⇒ 残留项堆到队满（scan 死锁） | `sg_flush`（IDLE 清队）+ 每趟起步清 SG 子相位；c16 从挂死 → PASS |
| R9 | **B2 shadow 的"最后一 tile 写"污染左邻 halo** | 写口加 `tTx != tNtx-1`；由 B1 负对照（`b1_play=0` ⇒ 重放趟也读 shadow）暴露：c64_40 突变档 3515→0 失配 |

## 6. 预期

- 8 平面/band 的串行 112 拍 → `latency + 8×4` 拍量级（`RQ=4` 时两批）。按 B3a 的 46 ms/MB 单价，
  这 **不减字节**、只减等待；收益取决于"每笔突发等待"在帧时里的占比（G7 的 −8.1% 是 B2 的下界参考）。
- 上板以 `y1run`/`NPU_MS` 的 A/B 为准，不预设数字。


## 7. 实施记录（2026-10-21）

### 7.1 RTL 落地

- `DdrMaster.scala`：`mode=3` SG-RD。8 项队（`sgQAddr/sgQLen/sgCnt`，IDLE 入队、非法项 `ready=0+err`、
  队满反压）；`SGRUN` 里 AR 按队序背靠背、R 按序落 `qbuf[sgRcv%RQ]`、按序排空；整批 `done` 一拍并清队。
  新增 `sg_flush`（**仅 IDLE 生效**）用于清掉"半批从未 start"的残留。
- `UnitExec.scala`（全部在 `if (TILING)` 内）：
  - DECIDE 里扫 0..7 找 `wxPNE` 的平面逐项入队（`wxSgScan/wxSgEnq/wxSgPl/wxSgMask/wxSgBB`，band 基址在入队时快照）；
    扫完后 `wxSgGo` 一拍，RD 相位按项序 4 拍落 `xwBuf`，`done` 按快照落每平面 band 账本并 `b2FB += 32k`。
  - `sg_flush` 在每趟起步（`wSt==2` 且 `tilingW`）脉冲一次，同时清 SG 子相位。
  - `rd_ready` 的 tiling 支并入 `wxSgDrn`（残留排空首拍也能收）。
- 其余 4 个 DdrMaster 实例（BypassExec / DescFetch / NpuTop / DmaEngine）与 6 个 TB 补 `sg_flush` tie-off。

### 7.2 集成期抓出的三个真缺陷（全部有对照实验）

| # | 症状 | 根因 | 修法 | 证据 |
|---|---|---|---|---|
| D1 | c64 取数计数**精确**但数值几乎全错；s2 档每批只落 1 项 | `start` 是一拍脉冲，`CHK` **下一拍**才读 `io.mode` ⇒ 读回 1，整批退化成 QRUN | `mode` 由 `wxSgRd` 保持到整批收流结束 | SG 探针 `dstate=13`；s2 逐字节 0 失配 |
| D2 | c16 挂死：`wxSt=2`、`scan=6`、`sgCnt=8` | pass 收工早于入队完成 ⇒ 半批（2 项）留队；下一趟再入 6 项即满 ⇒ `sg_ready` 恒 0 | `sg_flush`（IDLE 清队）+ 每趟起步清子相位 | c16 从 12M 拍 timeout → 1,381,732 拍 PASS |
| D3 | B1 负对照（`b1_play=0`）数值错 3515 | **B2 shadow 的最后一 tile 也写**自己的"后 2 列"⇒ 覆盖左邻 halo；正常模式"读完才写"掩盖 | 写口限定 `tTx != tNtx-1`（并只认填充趟） | c64_40 突变档 3515 → **0** 失配 |

### 7.3 闸门（全部 PASS）

- `run_ddrmaster_sg_ab.sh`：N=1/8/2 三批共 384 B 逐字节 == 内存；N=8 `MAXOUT=4`、N=1 `=1`；
  结构性 mutant（`(sgIss-sgDr)<1`）数据仍对而 `MAXOUT=1`；比较器自检可红；TB 内 6 条负对照全发火
  （非对齐地址 / 拍数非 4 倍数 / 空批 start / 队满第 9 项 / 忙时入队 / **flush 后 start 必 err**）。
- 既有 DdrMaster 五闸门：copy / read / write / 32B-stream / rdq 全 PASS。
- `run_b2_halo_ab.sh`（`RESULT: PASS`）：

| 档 | 逐字节 | 交付 `gather_bytes` | 取数 `gather_fetch_bytes` | CYC_WR（B3b / B2） | Δ |
|---|---|---|---|---|---|
| c64_40x40 | 0 | 123,904 | 196,608 | 1,358,320 / 1,405,168 | **−3.3%** |
| c16_160x160 | 0 | 462,400 | 774,144 | 1,381,732 / 1,566,196 | **−11.8%** |
| dw16_80x80 | 0 | 0 | 215,040 | 87,970 / 139,210 | **−36.8%** |
| s2_3x16 | 0 | 53,856 | 87,360 | 126,580 / 200,290 | **−36.8%** |

  负对照 `b2_hit=0`：数值仍对、交付不变、取数回到 219,136（判据必红）；G7（c16，同网表 A/B）−3.9%。
- 其余回归全 PASS：`run_b1_tilebuf_ab`（含 `b1_play=0` 突变：991,232 = 8×、MISMATCH=0）、
  `run_x1skip_ab`、`run_dci_ab`、`run_dwpack_ab`、`run_wgtblob_tiled_ab`（3/3 正例 + 3 条负对照）。

### 7.4 指纹与冻结

- `TILING=false` 三网表（**接口变更 ⇒ 主动重锚 6 个闸门常量**）：
  B3b 前 `dd9ee31e/af509071/781bb0fd` → B3b 后 **`7593b189ae8339e291c2fa398d0fcb2b` /
  `817ab5bbce2ef0bcaae556c8a9ded41b` / `5d2cd81addb84c62b2407f64aa0ac3a2`**。
  （`build/b2_regen/{base,new}_tfalse` 的源码中性证据属 B2 轮，本接口变更后失效 ⇒ 归档到
  `build/b3b/archive_b2_regen/`，B2 报告里的证据仍是当轮有效。）
- `gen/UnitExec_tiled.v` = **`b0081e7c7addb12949eb65f4e7051b70`**；`gen/DdrMaster.v` = `58eae303…`；
  `gen/NpuTop.v` = `c489aab9…`。
- 全量重生成 2×：`gen/` vs `build/b3b/regen2/` **48/48 文件逐字节相同**。
- 闸门锚点同步：`run_wgtblob_tiled_ab.sh` 的两处网表突变锚（`when_UnitExec_l2098`）与
  `MEM rd>=128` 口径随新网表重锚；其余 5 个 md5 断言只改常量。

### 7.5 PnR（`video1b3b`，FRESH + speed）

- 入口：`YESHENMINI_PNR_TAG=video1b3b YESHENMINI_PNR_FRESH=1 YESHENMINI_SYNTH_MODE=speed`，
  脚本 **`pds/run_pnr_yeshen.tcl`**。
  ★ 注意：`y1/pds/pnr_c4a.tcl` 的源列表缺 `pll_cpu.v`/`pll_lcd.v`，`FRESH=1` 建工程会在 elaborate
  处报 `'pll_cpu' is referenced to undefined module`（继承缺口，与本轮 RTL 无关）⇒ 用 status-quo 的
  `run_pnr_yeshen.tcl`（其 87-89/103 行已加三颗板级 PLL）。
- **All Constraints Met**（多 seed，seed0 OK；总耗时 ≈36 min，syn 13m40s + place 13m35s + route 9m56s +
  route-opt 2m14s + bitstream）：

| 时钟 | 要求 | 估计 | Slack（B3b / B3a） |
|---|---|---|---|
| soc_clk | 100 MHz | 107.53 | +0.700 / +0.776 |
| cpu_clk | 100 MHz | 107.26 | +0.677 / +0.617 |
| **npu_clk** | 54.35 MHz @18.4 ns | **56.48** | **+0.696 / +0.533** |

- 资源（syn）：LUT **80,750 / 50.53%**（B3a 79,185 ⇒ **+1,565**，SG 队 8×32 + 8×4 + 计账）、
  Register 110,626、DRM **273 / 65.78%**（不变）、APM **271 / 36.62%**（不变）。
- 比特流：`sim/reglogs/pds_video1b3b_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit`
  **9,188,552 B**，md5 **`eee657ba1882fee52cacd165f1eebed9`**。
### 7.6 上板 A/B（2026-10-21）

- 烧写：`flash_and_verify.py --tag video1b3b --com COM7`，`done bit=1`；启动 marker **8/8 PASS**
  （SD 装载 / SDRAM / OpenSBI / Linux / LiteEth / dropbear / 用户态 / 登录提示符）；ping + ssh PASS。
- `y1run --frames 1`：**RUN 0 ns=2,167,779,350（2.1678 s）**，`outputs=12/12`（12 路 CRC 全对），
  `Y1RUN: PASS frames=1 pass=1 fail=0`。
- `y1cam --once --quiet`：**`NPU_MS=2169`**（`FRAME seq=25321 bank=0`、`BOARD_INPUT_CRC=27e9c919`）。

| 口径 | B2 | B3a | **B3b** | Δ vs B3a |
|---|---|---|---|---|
| `y1run` RUN | 2.7242 s | 2.6141 s | **2.1678 s** | **−446.3 ms（−17.1%）** |
| `y1cam` NPU_MS | 2725 | 2613 | **2169** | **−444 ms（−17.0%）** |

数值判据由 `y1run` 的 **12/12 CRC** 承担（gather 数据路径与 B3a 逐字节同源）。
帧时收益（−17%）明显大于四个合成档的喂列拍数收益（−3.3%…−36.8%），说明真帧里**宽层 gather 等待的占比更高**。


## 8. 逐层/逐单元时间归因（2026-10-21，B3b 之后）

### 8.1 实测

- `y1run --frames 3` 的 RUN：2,169,595,380 / 2,167,185,180 / 2,167,173,730 ns ⇒ **稳态 2.1672 s**，
  首帧只多 ~2.4 ms（无暖机问题）。
- 板级 **npu_clk = 54.000 MHz**（`board/pll_50m.v` RATIO0=12.5；56.25 档已证伪）⇒ **≈117.1 M 拍/帧**。
- 全帧 conv/dw 的**逐像素趟数**（mac_account 逐单元表，A=1×1 跳拍已生效）：
  1×1 3.894 M + dw 0.892 M + dense 0.222 M = **5.008 M 像素·趟**。

### 8.2 能对上的部分

| 项 | 拍数 | 时间 | 占实测 | 出处 |
|---|---|---|---|---|
| tap 拍（A 后：1×1=1、dw/dense=9） | 13.92 M | 0.258 s | 11.9% | `mac_account.py`（RTL 口径） |
| + 每像素趟的 收列/出数（+2） | +10.02 M | +0.186 s | +8.6% | `Conv3x3Slice` FSM |
| **切片流水线下界合计** | **23.94 M** | **0.443 s** | **20.5%** | |
| DDR 流量（模型 a，63.1 MB @275.9 MB/s） | ≈12.4 M | 0.229 s | 10.6% | `mac_account.py` 场景 (a) |
| **实测** | **117.1 M** | **2.167 s** | 100% | 板上 RDtime |

### 8.3 结论：还有 ~4.9× 的"非 tap"空间

- 实测 / 切片流水线下界 = **4.9×**；即使把 DDR 侧按模型满带宽再算一遍，仍有 **≈1.7 s（~93 M 拍）
  不在 tap、也不在搬运字节账上**。
- 合成档的旁证：`run_b2_halo_ab.sh` 里宽层 conv 的 `CYC_WR` 折成 **13.3–13.5 拍/像素·趟**
  （c64/c16，离 11 拍地板只 +2.3）；按同一单价外推全帧 conv 只需 ≈1.2 s ⇒ 差额主要在
  **14 个旁路单元（maxpool/resize/add/sigmoid）+ 67 个单元的逐单元建场/权重段装载 +
  非宽几何（s=2 / C=3 / C=10 尾块）**，但这三块目前**没有逐单元时间戳可切**。
- 现有寄存器只有整帧 done/err（HostRegs 0x00/0x04），`mb_records` 是主机写参数、不是时间戳。
- 试过**前缀截断差分**（改 payload 头 `desc_count=N`）⇒ 被 LayerSched 的表尾哨兵校验挡下
  （`status=0x2`、零搬运）；合法截断必须同时把 `desc[N]` 改成 0xFF 并重算段 CRC，属改表实验，
  本轮未做。

### 8.4 下一步建议（待拍板）

1. **只读逐单元时间戳**（不动数据路径）：HostRegs 增 2 个 RO 字（`unit_idx` / 上一单元拍数），
   LayerSched 在每次 `done` 处锁存；y1run 轮询即可得 67 行逐单元表。一次 PnR + 一次烧写（~1.5 h）。
2. 拿到表后按"拍/像素·趟"排序，优先修 ≥2× 单价的单元类（旁路 / s=2 / 小 C 尾块）。
3. 行 halo（map §3.3）只值取数的 ~4.8%，在 8.3 的量级面前优先级低。
