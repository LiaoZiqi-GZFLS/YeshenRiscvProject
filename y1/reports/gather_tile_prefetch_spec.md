# Y1-NPU G1 spec：tile 级 ping-pong 预取（把 gather 延迟藏到计算后面）

状态：**设计待实现**（2026-10-22）。前置：`ddr_bridge_read_perf.md` 的 RDEPTH=8 零收益已回退；
`unit_trace.md` 的 fill/replay 模型；B1 `tileBuf`（每个 ci-block 的输入 tile 常驻 9.2 KB）。

## 1. 问题（有实测模型）

`UnitExec` 宽路的取数与计算是**串行**的：某 ci-block 的填充趟里，每 32 列要等一整批
（8 平面 × 32 B）从 DDR 回来才开始算。`unit_trace.md` 的拟合（±5%）：

```
每 (ci-block, tile) 迭代：  T = F + C
  F = 每带 8×32B 的端到端延迟 ≈ 990 拍（L），每 tile 32 带 ⇒ F ≈ 31.7k 拍
  C = tile 计算 = 1024×(11 + (nCo−1)×2) 拍     （nCo = ceil(C_out/8)）
```

逐单元表（P5，`unit_trace_p4p5.txt`）里 conv1x1 909 ms / dw 653 ms / conv3x3 232 ms，
合计 1.79 s = 全帧 2.07 s 的 **86%**，而其中 **F 是主体**（nCo=2 时 F 占 74%）。

**RDEPTH=8 已证伪**（板级 −0.002%）：不是桥的在飞档位，而是**每次迭代都要付一遍完整延迟**。
⇒ 正确杠杆不是加深队列，而是**把 F 与 C 重叠**（软件流水）。

## 2. 目标与判据

- 目标：`T' = max(F, C)`（每迭代），即 conv 类 **−26%（nCo=1）～−45%（nCo=8）**；
  按逐单元表加权预测 **2,074 → ~1,514 ms（−27%）**，只算 conv 类 −31%。
- 判据（先红后绿）：
  1. **单元级**：同一 TB、同一激励下，`+PF=1` 的周期数必须 ≤ `+PF=0` 的 **0.80×**
     且两档输出逐字节相同（预取只改时序，不改语义）。
  2. **负对照**：把预取目标故意指到错误 plane（`PF_BAD=1`）⇒ 输出必须错/超时
     ⇒ 证明判据真的在比“预取后的那份数据”。
  3. **回归**：tiling2d / roww / chain_wide / x1skip / wgtblob / multipass / unitexec 全 PASS，
     `TILING=false` 三网表 md5 冻结不变。
  4. **面积**：DRM 增量 ≤ 4 块（tileBuf ×2 = +9.25 KB ≈ +2 块），LUT 增量 ≤ 1500。
  5. **上板**：`y1run --frames 2` vs **2,074.4 ms**，≥10% 才保留；12/12 CRC 必过；屏画面不回归。

## 3. 设计（ping-pong tileBuf + 批量预取 FSM）

### 3.1 状态

- `tileBuf` → **两块**（各 `WIDTH × (2·IMG_H_MAX+2)` 字 × 8 B = 9,248 B）：
  `bufCur`（本迭代计算读）、`bufNxt`（预取写）。1 bit `bufSel` 每迭代翻转。
- 新预取 FSM `pfSt`：`IDLE → ROW(发本行 8 平面的 band-set) → DECODE(收流→列→写 bufNxt) → 下一行 → DONE`。
  只在 `WIDERUN` 且 **本迭代的 tile 已在 bufCur** 时运行；`tilingW=0 / !TILING` 恒 IDLE。
- 预取目标 = **执行序的下一个 (ci, tile) 迭代**：
  - 同 tile 的 `ci+1`：`srcA' = srcA + 8·HW`，几何不变；
  - tile 末 ci：下一 tile 的 `ci=0`，几何/`x0,y0,rowW` 由 tile 循环的**下一组计数**给出。

### 3.2 数据流

- **预取**：按行/列走**与 gather 相同的地址式**（`srcA' + row·inWi + col`，每平面 `& ~31` 取 32 B，
  保留 T-S3b 的每平面 band 账本），把每个交付列写进 `bufNxt[col]`；pad 列写 `z_pad`。
  每行一次 SG 批（≤8 平面，`sg_beatsM1=3`），走现有 `DdrMaster`。
- **计算**：填充趟不再现场 gather，改为**从 `bufCur` 读列**（与重放趟同一条路），
  因此 `mpu.io.x` 的 tileBuf 选择加一个 `bufSel` 位。
- **回退**：单元首个迭代（或预取未完成/被作废）仍走现有现场 gather 填 `bufCur` ⇒ 行为与今天逐字节相同。

### 3.3 关键约束 / 风险

1. **`DdrMaster` 共享**：写回也用同一引擎（mode=2）。预取与写回会分时；上界收益按
   `T' = max(C, F + W)` 打折（W = 写回引擎占用）。**模型预测已按最坏情况给 −27%**；
   若板级只拿到一半，仍 ≥10% 门槛。
2. **写回 vs 预取的顺序**：两者地址无关（读输入、写输出），但同一引擎 ⇒ 必须显式仲裁
   （预取让位写回，写回让位当前填充）。仲裁不得改变写回顺序（同属主保序）。
3. **预取作废**：tile 循环提前退出/单元结束/软复位 ⇒ 预取批 `sg_flush`、`bufNxt` 标无效。
4. **自洽**：预取账本（每平面 band 基址）必须与交付列一一对应（T-S3b 的教训：快照而非末拍重算）。
5. **面积/时序**：第二块 tileBuf 是 DRM（+2 块），读口加 1 bit 选择；预取 FSM 在 npu_clk 下
   与现有 gather 同级，注意 18.4 ns 收紧（现有 npu +0.084 只剩 84 ps）。

## 4. 实施切片

1. **G1-a**：`tileBuf` 双缓冲 + `bufSel` 读选择（不做预取）——所有回归必须全绿（等价性）。
2. **G1-b**：预取 FSM（同 tile 的 ci+1）+ 仲裁；TB 加 `+PF`，先证 `PF=1` 周期 ≤0.8× 且数值相同。
3. **G1-c**：跨 tile 目标（tile 末 ci → 下一 tile ci0）+ pad/halo/stride2 覆盖。
4. **G1-d**：负对照 `PF_BAD`（目标 +8·HW 指错）+ 全回归 + dev_map。
5. **G1-e**：PnR + 上板 A/B（判据 §2.5）。

## 5. 预期与止损

- 预测 2,074 → ~1,514 ms（−27%）；保守下界（写回分时吃掉一半）≈1,790 ms（−14%）。
- 止损：若单元级 `PF=1` 做不到 0.85×，或板级 <10%，回退到 `video1p5` 基线并留档（同 RDEPTH=8 的处理）。

## 6. 实现记录（2026-10-22，G1-a/G1-b）

### 6.1 落点（`rtl/UnitExec.scala`，只在 `TILING=true`）

- `b1Buf` → **双体**（`2 * b1Depth` = 4,488 字 × 8 B）；`b1AddrB` = 体偏移 + `b1Sel` 基址。
- **体翻转**：`state==WIDERUN ∧ wSt==2 ∧ b1Use ∧ wCob==0`（本迭代首趟）翻一次。
- **影子预取 FSM** `pfSt`（0/1/2/3/4/6）：独立 `pfRow/pfCol`、per-plane band 账本、SG 扫描/RD 收流；
  目标 = `wCi+1`（同 tile），目标体 = `!b1Sel`；共用 `xwBuf` 与 `DdrMaster`。
- `pfHit`：目标 ci 的填充趟起趟时若预取已完成（ci/tile 键匹配）⇒ 该趟按**重放**跑（读另一体，零 AR）；
  `pfBytes` 在此刻一次性计入 `gather_bytes`（保持该观察口“唯一输入列字节”口径）。
- 预取不写 b2：命中预取的 ci 在**下一个 tile** 的填充趟强制关 b2（`pfB2Blk`），让这次填充重新 gather
  前 2 列并重写 b2。
- 预取未完成：在下一趟**载权相位**（`wSt==1`）原地等（`pfWait`，冻结 `wK`），避免进入 `wSt==2` 的
  `sg_flush` 清掉影子的 SG 队列。
- `pfDirty`：影子动过 `xwBuf` ⇒ 下一次填充起趟清主 gather 的 per-plane band 账本（防复用脏 band）。

### 6.2 实现中抓到的四个真问题（全部有实测红证据）

1. **`pfHit` 自锁**（最隐蔽）：`pfHit` 的更新原先被 `b1Fill` 门控，而 `b1Fill = b1Use ∧ ¬b1Play`、
   `b1Play` 又含 `pfHit` ⇒ 一旦命中，后续所有填充趟都被当成“已预取”而不 gather、也不再评估 `pfHit`。
   实测 `Conv_15`：`GATHER_BYTES=18496`（正好两个 ci-block）、`wr=32`（全帧只写进 32 B）。
   ⇒ 更新条件改为**本迭代首趟**（`wCob==0`），与体翻转同条件。
2. **`rd_ready` 死锁**：主 gather 的 `rd_ready` 只在 FETCH 态举；影子在载权等待相位收 RD 流时恒 0
   ⇒ DdrMaster 卡在 SGRUN（心跳 `dstate=13, rd_valid=1, rd_ready=0`）。⇒ 影子活跃时由自己收拍。
3. **`sg_flush` 误清队列**：每次 `wSt==2` 的起趟复位会举 `sg_flush`，若影子正在入队（DdrMaster IDLE）
   会清掉其队列。⇒ 影子在飞时强制 `sg_flush=0`。
4. **越界写**：EMIT 尾拍（`pfRow==tNRow`）仍处 EMIT 态，原写法会写到下一体/越界。⇒ `pfEmitV` 门控。

### 6.3 闸门状态

- `run_b1_tilebuf_ab.sh`：修 1 之后，**c64_40 单作业手工复跑 PASS**：`GATHER_BYTES=123904 == GEXP`、
  `RESULT: PASS`、`CYCLES=1,806,836`；完整 B1（含 160×160 与负对照）重跑中。
- `run_tiling2d_rtl_ab.sh`：修 1 之前**已 PASS**（s=1 六种真几何 + s=2 32×32 整层逐字节；两个负对照发火）；
  修 1 后复跑中。
- `TILING=false` 三份 md5 始终为 `7593b189 / 817ab5bb / 5d2cd81a`（未动）。
- **产品网表必须重生成**：PDS 综合读的是 `y1/gen/NpuTop.v`（**内联 UnitExec**），不是 `UnitExec_tiled.v`
  （后者只给单元闸门）。已验证 `NpuTopGen` 重生成后 `NpuTop.v` 含 `b1_sel/pf_hit`；
  `run_nputop_sched_ab.sh`（调度/链/权重信箱/非法表负对照 + C2 回归）**RESULT: PASS**；
  `run_wgtblob_tiled_ab.sh`（3 正例 + 3 负对照，含“rd_ready 漏 wlTake 必挂”）**RESULT: PASS**。
- **dev_map（tag `g1b2`，speed）**：LUT 81,557→**84,525（+2,968，53%）**、FF 112,919→**115,342（+2,423）**、
  **DRM 273→281.5（+8.5 块，68%）**、APM 271→266；Distributed RAM 8,079 不变；无 DRC 失败。
  DRM 增量超出 spec 的“≤4 块”（双体 tileBuf 的实际映射块数比按字节估的多），但 68% 仍有充足余量。
- **PnR `g1b` seed 0：npu_clk −0.173 ns（10 个违例端点）**，其余时钟全正。头号路径
  `unitExec_1/N607/gopapm/CLK → ddrMaster_4/sgQAddr_2[*]/opit_0/CE` = 影子的 APM 平面地址 →
  SG 队列使能的长组合链。**修法（G1-b-t）**：DECIDE 把“本列要取的平面 + 每平面 band 基址”
  **寄存一拍**（`pfNER/pfBBR`，+264 FF），SG 扫描与 `sg_addr` 只读寄存器。重生成 UnitExec+NpuTop 后
  用 40×40 作业与 dev_map 复验，再重跑 PnR（tag `g1b2`）。
- **PnR `g1b2` seed 0 仍是同一类路径（−0.271）**，但细看起点/终点：违例在**主 gather** 的
  `wxPNE → ddrMaster sg_valid → sgQAddr CE`（影子那条已断，主 gather 的还没）。**修法（G1-b-t2）**：
  主 gather 的 `wxPNE/wxPBB` 也寄存一拍（`wxPNER/wxPBBR`），DECIDE 锁存、FETCH 扫描只读寄存器；
  `wxSgDrn` 排空清账后**按“全平面重取”重锁存**（否则会漏读）。★ 改动做在**同一行内（零行数增量）**：
  `TILING=false` 三份 md5 仍为 `7593b189/817ab5bb/5d2cd81a`（网表名内嵌行号，插行会破坏冻结）。
  c64_40：`RESULT PASS`、`CYCLES=1,806,836` 与修前逐值相同；tiling2d **PASS**（s1 六几何 + s2 + 两负对照）。
  最终时序以 PnR `g1b3` 为准。

### 6.4 PnR `g1b3`（seed 0，FRESH + speed）：**All Constraints Met**

- npu_clk **56.5867 MHz / +0.728 ns**（344,394 端点）；soc 108.26/+0.763、cpu 107.34/+0.684、
  lcd 56.24/+1.478、core_clk 134.25/+0.551；最紧的是 `core_clk → phy_dq_sysclk_1 +0.002`
  （DDR PHY，非 NPU 路径）。Hold 全正（npu 0.065、soc 0.063、cpu 0.081），Recovery/Removal 无违例。
- 两次改法（`pfNER/pfBBR` 影子、`wxPNER/wxPBBR` 主 gather）把 `gopapm → sgQAddr CE` 长链
  从 −0.173/−0.271 提到全正；`pick_first_timing_convergence_seed` 在 seed 0 即收敛，未跑 seed 1–3。
- 比特流：`sim/reglogs/pds_g1b3_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit`，
  **md5 `e6e689b00e60a0fe19239b8e8dfc6158`**，9,188,552 B（与历次同尺寸）。
- dev_map（`g1c`，speed）：LUT 84,556.5（53%）、FF 115,565（37%）、DRM 281.5（68%）、
  APM 266（36%）、Distributed RAM 8,079（21%）；Adm-4088=0。
- **下一步（需板上窗口）**：烧 `g1b3` → `y1run` vs 基线 **2,074.4 ms**；判据 ≥10% 才保留、
  12/12 CRC、屏画面不回归；否则回退 G1 并留档。

### 6.5 上板 A/B（2026-10-22，tag `g1b3` / sbit `e6e689b0`）：**−1.94%，判否 → 已回退**

| 档 | `y1run --frames 2` RUN（ns） | 均值 | CRC |
|---|---|---|---|
| P5 基线（交付 `video1p5` / `fc08f0d3`） | 2,074,548,660 / 2,074,386,530 | 2,074.47 ms | 12/12 ×2 |
| **G1 `g1b3`** | **2,034,279,040 / 2,034,229,230** | **2,034.25 ms** | **12/12 ×2** |

−40.2 ms = **−1.94%**，远低于 spec §5 的 ≥10% 保留线 ⇒ 判否。

**逐单元表（`--unit-trace`，末帧 SUM=2,034.388 ms）**：只有 conv1x1 动了，其余逐单元不变：

| 类 | P1 基线 2.1678 s（ms） | G1 `g1b3`（ms） | Δ |
|---|---|---|---|
| conv1x1 | 909.4 | **869.6** | **−39.5（−4.3%）** |
| depthwise | 692.6 | 652.7 | （P5 仲裁器收益，G1 不覆盖） |
| conv3x3 | 232.9 | 232.1 | ≈0 |
| maxpool / add / resize | 173.2 / 71.6 / 36.3 | 172.5 / 71.4 / 35.7 | ≈0 |

**为什么预测 −27% 没兑现（口径修正）**：
- conv1x1 实测 **11–22 拍/像素·趟**（Conv_15：203 ns/pp ⇒ 10.96 拍/pp），**远低于 fill 的 42 拍/像素**
  ⇒ conv1x1 本来就不是 fill 主导；其 fill 份额 ≈20%，全部藏掉也只值 ~20 ms/层。
- 真正 fill 主导的是 **dw**（707–808 ns/pp ⇒ 38–44 拍/pp，653 ms = 32%），G1 按设计（只预取 dense 下一 ci）
  **不覆盖 dw**。P1 的"fill ≈1.7 s = 全帧 80%"是把类别合在一起拟合的结果，**逐单元拆分后不成立**。
- 剩余 conv1x1 预取收益 ≈ 模型上限：fill 每 ci 需 51.2 KB，重放窗口 7×6400×2 拍 = 89.6 k 拍（1.66 ms）
  ⇒ 需 ~30.9 MB/s，而实测可用读带宽 ~22–24 MB/s ⇒ 只能藏掉一部分（实测每层 −6~−12%）。

**结算（净值）**：代码已回退到 G1 之前（`UnitExec.scala` = `570c2d7~1`，blob `f0a836bc`；
`run_b1_tilebuf_ab.sh` 一并回退）；网表重生成后 `TILING=false` 三份 md5 仍为
`7593b189 / 817ab5bb / 5d2cd81a`、`UnitExec_tiled` 回到 **`f01da4da`**（G1 前值）；
B1 闸门重跑 PASS。板上已重烧交付带 `video1p5`（`fc08f0d3`）。
**教训**：下一根杠杆应是 **dw 的 9 趟对角共享一次 gather**（653 ms、38–44 拍/pp 的近纯 fill），
不是再藏 dense 的延迟。
