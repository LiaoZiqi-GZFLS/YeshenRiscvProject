# Y1-L2b：DdrMaster 读预取（多 outstanding）小 spec

日期：2026-10-18　上游：`2026-10-17-y1-npu-performance-design.md` §7/§8、`y1/reports/npu_v2_board_frame.md` §17.5

## 1. 基线（已实测）

- 上板 `y1run` **4.5981 s/帧 @ 54 MHz**（旧 6.2628 s；CDC burst FIFO 已落地）。
- gather 每 tile 约 **8 平面 × 34 窗口行**的 RD；每行 `len = (aHi-aLo)·8 B`（32×32 tile 一般为
  272 B、20 列 160 B、16 列 128 B）。
- `DdrMaster` 的 RD 模式把一行拆成 **≤128 B 的块**，块与块之间是
  `AR → R → RDSTR → WNEXT → AR` **完全串行**（单块缓冲）；gather 还在行间等 `!busy`。
  ⇒ 一行 272 B 要付 **3 次 AR 往返**，且上一行没收完不发下一行。

## 2. 两个候选

### A. 块槽预取（推荐，先做）
在 `DdrMaster` 的 **mode=1** 内加 `Q=4` 个 128 B 槽：AR 提前发到后面 1..3 块，R 按槽落数，
`RDSTR` 从槽 0 推流的同时槽 1..3 在收；槽空出发下一笔。**不改 gather 契约**，不改 mode 0/2。
- 收益：一行 272 B 的 3 次串行 AR 变 1 次（首块）+ 2 次重叠；160 B 由 2 次变 1 次。
- 风险：低（消费者仍是 `rd_valid/rd_ready` 流；只是生产者内部多了 3 个槽）。
- 面积：+3×128 B 缓冲（≈3k FF）+ 槽元数据；LUT 约 +1–2k。
- 闸门：新 `run_ddrmaster_rdq_ab.sh`（背靠背 RD、outstanding 峰值观察、Q=1 负对照）；
  既有 `run_ddrcopy_ab.sh`/`run_nputop_ab.sh`/`run_nputop_sched_ab.sh` 必须不变绿。
- 上板：`y1run --frames 3`，12/12 不变，帧时间应下降。

### B. 跨请求队列（下一步，条件）
把整行请求也排队（Q=4），gather 提前入队下一行、用**拍数完成**替代 `!busy` 等待。
- 收益：再消掉行间 AR 往返；与 A 叠加。
- 风险：高（消费者契约变化、死锁/饥饿、行锁步与 pad 行交互）；需要新的行级闸门。
- 触发条件：A 落地后重新测帧时间；若 gather 仍占主导再做。

## 3. 判据（A）

1. 结构：Q=4 槽、同 AXI ID、按序收数；`arvalid` 背靠背 ≥2 笔（TB 观察口）。
2. 数值：既有 `run_ddrcopy_ab.sh` 与 `run_nputop_ab.sh` **逐字节不变**；新增 RD 多笔用例
   与单笔黄金逐字节相同。
3. 负对照：Q=1 退化档 → outstanding 峰值回到 1（证明"多"是结构性生效的）。
4. 上板：`y1run` 3 帧 12/12（逐字节黄金），帧时间 vs 4.5981 s。
5. 资源：dev_map 0 error；LUT/FF 增量如实记录；PnR 18.4 ns 继续 All Constraints Met（54 MHz 板钟）。

## 4. 诚实边界

- A 只重叠**同一行内的块**；行与行之间仍由 gather 顺序驱动。若一行 ≤128 B（16 列），A 无收益。
- AXI 侧多 outstanding 已被 DDR3Bridge P0 支持（`outR < DEPTH=4`、`rdQ` 深度 8），本设计不碰桥。
- 若 A 后帧时间下降 <5%，说明瓶颈已转向计算/其他单元，应先做归因而不是上 B。

## 5. 归因实验（用户裁决：先只做归因，未写 RTL）

**两时钟差分**：同一网表、同一 18.4 ns 约束、同一 `y1run`/payload，只把 NPU PLL 从
**54 MHz 临时降到 27 MHz**（RATIO0 12.5→25.0），测 `T(27)`；用 `T(f)=C/f+G` 解：

- `C` = 随 NPU 时钟缩放的等效周期数（计算/FSM/流式处理）；
- `G` = 与 NPU 时钟无关的固定时间（DDR 延迟/带宽、CPU 侧等）；
- 计算：`C = (T27 − T54) / (1/27 − 1/54)`，`G = T54 − C/54`。

若 `G/T54` 很小（<10%）⇒ gather 已不是主要瓶颈，L2b 的队列优先级下降，应先做计算/其他单元；
若 `G/T54` 仍大 ⇒ 按方案 A 落地块槽预取，再做 B。

测完把 PLL 回 12.5（54 MHz）并重烧认证比特流 `c4a_l2d8v`。

## 6. 落地时发现的结构性前提（2026-10-18，方案 A 实测）

**现象**：A 的 DdrMaster 单测（`run_ddrmaster_rdq_ab.sh`）全绿（q4 在飞 4 笔），但把
DmaEngine 换成 q4 后 `run_dmaeng_ab.sh` 在 `RD LEN=160`（2 块）挂死；进一步审
`src/YeshenSocGlue.scala` 的合并点，发现**同一假设遍及全 SoC**：

- `DmaEngine` 的通道间仲裁器是**事务级单笔**（授予持有到 `rlast/B`，`inFlightR` 单 bit）；
- `YeshenSocGlue` 的 `owner` 状态机同样在**首个 `rlast`** 释放授权，而 `npuMem.arvalid`
  在授权期内是持续直通的 ⇒ 第二笔 AR 会被收下，但它对应的 R 拍在 `owner` 回 IDLE 后**无人接收**。

⇒ **A 单独落地会只在单测里成立，上板必挂**。因此本 spec 追加两条**承重改动**：

1. `YeshenSocGlue`：把"读主人"的释放条件从"首个 `rlast`"改为"**末笔 `rlast`**"——
   新增 `rdOut`（0..4）在授权期内对 AR/R 末拍做增减，`rdOut_next==0` 才释放。
   单笔主人（CPU Fetch/LSU、DMA）的 `rdOut` 恒 0/1 ⇒ 逐拍行为与旧版相同（单主人 transcript 0 差异）。
2. `DmaEngine` 的两个通道：**`rqDepth=1`**（保持其仲裁器的单笔契约）；块槽预取只给
   **直连 NpuTop 的 DdrMaster**。这是契约约束，不是性能取舍。

**闸门**：`sim/glue_pbus/tb_memmerge.cpp` 增 J_MM5（NPU 背靠背 3 笔读 + 4 深 AR 内存模型）；
`sim/glue_pbus/negctl_memmerge.sh` 增 NC_L2B（`rdOut===1` → `true.B` ⇒ 复现旧行为）——
期望 J_MM5 红。DMA 引擎的负对照是 `run_dmaeng_ab.sh` 的 `RD LEN=160`/COPY 多块用例本身。

**边界（如实）**：`DdrMaster` 的块槽预取只在**一笔 RD 跨多块**时生效：
- 宽路 gather 的 32 B 单块请求**不受益**（这是方案 B 的范畴）；
- 窄路行 gather（272/160/128 B）与权重段装载（576 B/单元）**受益**。
`UnitExec.v` / `UnitExec_w32.v` / `UnitExec_w640.v` 三份 TILING=false 网表**保持字节冻结**
（`dd9ee31e…`/`af509071…`/`781bb0fd…`）；它们只是测试网表，板级只用 `NpuTop.v`（已重生成）。

## 7. 结果（2026-10-18）

- **上板 A/B**：`y1run --frames 3` **4.5467 s/帧**（旧 4.5981 s，**−1.12%**；12/12 逐字节不变）。
- 按 §4 的预设：收益 **<5%** ⇒ **不直接上方案 B**；先归因"宽路 32 B 单块 gather 的每请求往返"
  （A 结构性帮不到它），再决定 B/计算侧。
- 附带发现并修复的**承重前提**：`YeshenSocGlue` 的 owner 改为"末笔 rlast 才释放"（`rdOut`），
  `DmaEngine` 通道退回 `rqDepth=1`；新闸门 J_MM5 + NC_L2B 已入 `run_memmerge_unit.sh` /
  `negctl_memmerge.sh`。
- PnR：ads 档在 18.4 ns 未收敛（seed0 −0.445 / seed1 −0.584，失败路径为既有计算/线缓冲路径）；
  `YESHENMINI_SYNTH_MODE=speed`（`-resource_sharing FALSE -retiming`）seed0
  **All Constraints Met**（npu est 56.3444 MHz / +0.652），比特流 `cdc5a6b7…`。
