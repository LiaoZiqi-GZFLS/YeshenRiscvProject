# Y1 NPU 性能设计（2026-10-17，S4-C 数值收口后）

> 状态：**spec（待批）**。数值正确性已在 S4-C 收口（板端检出正确人脸，G7 的 IoU/conf/计数全过）。
> 本文只谈**帧率**。目标（用户早前定）：**≥10 fps**；当前实测 **0.15403 fps**（6.4921 s/帧）。

## 1. 已测基线（本仓证据）

| 量 | 值 | 出处 |
|:--|:--|:--|
| 整帧 | **6.4921 s**（×3，±0.005%） | `reports/npu_v2_board_frame.md` §15.9 |
| 逐单元成本 | 1×1 **61%** / dw **21%** / maxpool+add+resize **6.4%** / 3×3 尾 **0.2%** / sigmoid ~0 | §14.5 的 67 点梯子 |
| 成本与体量 | `inc ~ outB` 相关 **0.83**；"有用字节"≈0.3 µs/B（≈3.3 MB/s） | §14.5 |
| 读放大（模型） | 宽路 tile 每 co-block 重读窗口 ⇒ C=64 dense **~23×** | `c4b_tiling_s2.md` §11.5（仅 2 点校准） |
| 去融合流量 | **31.9 MB/帧** | A2.5（`ddr_traffic.py` 冻结件） |
| 板端可达 DDR（CPU u32） | 38–47 MB/s；桥静态上界 275.9 MB/s | A2 / §14.5 |

## 2. 三个上界（在 56.25 MHz、单单元 8×8 阵列下）

1. **计算（阵列）上界**：344,224,000 MAC ÷ (64 MAC/beat × 56.25 MHz) = **95.6 ms/帧 ⇒ 10.46 fps**，
   前提是阵列**满占空**。
2. **DDR 上界（去融合表）**：31.9 MB ÷ 275.9 MB/s = **115.6 ms ⇒ 8.6 fps**（理想背靠背）。
   按实测有效 ~75 MB/s ⇒ **0.43 s ⇒ 2.3 fps**。
3. **观测**：6.492 s ⇒ 比"放大后带宽上界"还慢 **~15×** ⇒ 主因不止带宽，还有**延迟/空转**：
   仿真里 desc[1] 是 **23.3 拍 / 像素-趟**（10.46 M 拍 ÷ 448,800 拍），而计算只需 ~1 拍。

## 3. 杠杆（按"收益/成本"排序）

| 杠杆 | 作用 | 预估 | 成本 |
|:--|:--|:--|:--|
| **L0 量具** | 给单单元加 AR 计数/分段计时（gather / 计算 / 写回），并做"同层不同 pass 数""同 pass 不同 tile"的对照 | 把 23 拍/px 拆成延迟 vs 带宽 | 小（探针 + 1 次上板） |
| **L2 gather 流水/加深 in-flight** | 预取下一 band/下一平面；AR 队列加深（当前 `RD_PEAK=32`，但每拍只发 1 笔） | 若 23→5 拍/px ⇒ **~4×** | 中（UnitExec 的 `wx*` 通路） |
| **L1 输入复用（跨 co-block）** | 同一 ci-block 的窗口/像素在 co-block 循环期间**留在片上**（tile 缓冲 ~9 KB 或寄存器级 co 内循环） | 消除 nCo 重读：C=64 层 **~8×** | 中-大（循环嵌套重排 + PSB 读写带宽） |
| **L3 重新融合（链）** | 流量 31.9 → 12.58 MB；同时省掉中间张量的往返 | **~2.5× 流量** + 延迟 | 大（此前撞 LUT 墙；需单骨架方案） |
| **L4 提频** | 56.25 → 62.5 MHz（18.4→16.0 ns 需重 PnR） | **+11%** | 中（重 PnR；当前 slack +0.829 有余量） |

## 4. 建议的执行顺序

**L0（先量）→ L2（最便宜的大头）→ L1 →（视结果）L3/L4。**

- **为什么先 L0**：23 拍/px 里"延迟"和"带宽"的比例决定 L2 与 L1 的先后；盲做 L1 可能只把带宽降下来、仍被延迟卡住。
- **为什么 L2 优先于 L1**：不动数据布局、不改数值口径，风险最低；若延迟占主导，单靠它就能把 6.49 s 拉到 ~1.6 s（0.6 fps）。
- **10 fps 的诚实判断**：即使 L2+L1 把有效带宽拉到 275 MB/s、把阵列占空拉到 ~80%，去融合 31.9 MB
  对应 8.6 fps；**≥10 fps 还须 L3（融合）+ L4（提频）**。若用户接受"先到 2–4 fps 再谈 10"，按上面顺序即可。

## 5. 每片的 DoD（不变式）

- **数值不变**：12 路输出与 S4-C 的 `board_face_s4c.json` **逐字节相同**（新网表重跑，`--int8` 黄金不变）；
- 全字节级闸门 PASS（含 `run_x1center_ab`）；
- 上板 fps ×3（`npurun_t`）+ 与上一档的对照表；
- 每次 RTL 改动都过 `TILING=false` 路径的数值闸门（1×1 修复已把旧 md5 基线作废，新基线随片记账）。

## 6. 风险与边界

- tile 缓冲的 DRAM 代价：板级 DRM 余量紧张（§15 记账），9 KB 缓冲是否落 BRAM 需 dev_map 先判；
- L2 可能只是把延迟藏起来、带宽仍是瓶颈 ⇒ L0 的 AR 计数是判据；
- L3 的 LUT 墙是既有结论，若要重启需先按"单骨架"方案重估面积；
- 所有"预估倍数"都标为**模型值**，以板上 ×3 实测为唯一判据。

## 7. 2026-10-17 追加：tiled-wide gather 的实测形态与修正后的 L2

**实测（RTL + 板内）**：tile 宽路的 gather 在 `UnitExec.scala:2304-2335`：
- 每个**窗口行**、每个**平面**发一笔 **32 B RD**（`DdrMaster` 的 RD 模式），收完 8 个平面才进 EMIT；
- `DdrMaster` 是**结构性单 outstanding**（`DdrMaster.scala:42`），下一笔必须等 `done`（AR→R→RDSTR→WNEXT→IDLE）；
- 32×32 tile ⇒ **8 平面 × 34 窗口行 = 272 笔 AR/tile**；每笔只带 4 拍数据。

**修正**：把 32 B 加长到 128 B **不会减少 AR 数**（窗口行是行跨步的，128 B 只覆盖同一行更多列），
只会把输入流量放大 ~4×；因此 L2 的正确杠杆是 **读请求队列 + 多 outstanding**（同 ID、按序收数），
把 272 笔的往返重叠起来。次要杠杆仍是 L1（跨 co-block 复用输入窗口）。
- 预期：23.3 拍/px → 约 4–6 拍/px（若 8 笔在飞）；
- 前提：DDR3Bridge 的 P0 多 outstanding 已就位（`reports/dma_phase0.md`）；
- 判据：`TILING=false` 逐字节冻结 + 全几何 golden + 上板 12 路输出 md5 不变 + 板内 `y1run` 3 帧计时。

## 8. 2026-10-17 追加：**跨域 CDC 是 32 B 握手的真正承重点**（修正 L2 的先后）

**代码事实**（`y1/rtl/NpuMemCdc.scala` 文件头）：
- NPU 内存主口跨 `npu_clk → cpu_clk` 的桥 **按设计单 outstanding**；
- **AR/AW 描述子一次 4 相握手，W/R 的每个数据拍各自一次 4 相握手**（无 beat FIFO）；
- 即一笔 32 B 读在板上 = **1 次 AR 跨域往返 + 4 次 R 拍跨域往返**；这与 gather 的 8 平面串行叠加，
  正对应 23 拍/px 的量级。
- 因此 **只改 `DdrMaster`/gather 的 outstanding 不够**：CDC 会把多笔 AR/每个 beat 重新串行化。

**修正后的顺序**：
1. **CDC burst 化**：把 `NpuMemCdc` 的 5 条 `CdcPipeSp`（AW/W/AR/B/R）替换为仓里已验证的
   `CdcFifo`（`src/soc/CDCQueue.scala`；`lanes=1, depth=16..64`），接口不变；AR/B 描述子也可
   进 FIFO ⇒ 允许多笔在飞。文件头自己就写明"未来可把 W/R 换成异步 FIFO，接口形状不变"。
   判据：扩展 `run_mem_cdc_ab.sh`（现有 4 个单 outstanding 作业 + 新增**背靠背多 AR**作业 +
   depth=1 退化负对照 + R/W FIFO 短接负对照）。
2. **再看 gather/DdrMaster 请求队列**（原 #429/#430）：CDC FIFO 就位后，多 AR 才真正并行。
3. 之后仍是 L1（跨 co-block 复用）→ L3/L4。

**预期**：CDC FIFO 单刀可去掉每笔 R 数据的 4 次跨域往返；若 R 拍不再逐拍握手，gather 的
32 B 读从"AR 往返 + 4 次往返"降到"AR 往返 + 4 拍流"，量级上足以把 6.26 s 拉进 2–3 s 档；
多 AR 队列再把 AR 往返重叠，才谈 4–6 拍/px。**仍以板上 `y1run` 3 帧实测为唯一判据。**

## 9. 2026-10-17 深夜：CDC FIFO 落地 + 资源大砍（L_MAX=2 / depth=8）

**已落地（代码 + 闸门，commit `3155ca4`）**：
- `y1/rtl/NpuMemCdcFifo.scala`（新）：源/目的双环 FIFO + `lanes=4` 个 `CdcPipeSp` 轮转并发；
  `NpuMemCdc` 的 5 条通道全部换用（AW/W/B/AR/R），接口不变。
- FIFO depth：AW/AR/B 原本 8，W/R 由 16 收到 **8**（`lanes=4` 不变 ⇒ depth≥lanes 不限制并发）。
- **板级 `L_MAX=8 → 2`**：真表 de-fuse 后 8 套链切片只有 slice0 被用；`L_MAX=1` 在本实现不可行
  （`sliceRest` 空序列的 `reduce` 展开失败），L=2 是最小合法值。链功能仍由 L=8 验证网表
  `gen_chain8/NpuTop.v` 承载（`run_nputop_sched_ab.sh` 的 W2 专用），不进板级。

**闸门**：`run_mem_cdc_ab.sh` PASS（depth 8）；`run_twoclock_ab.sh` PASS（单/两时钟逐字节 0 +
确定性 2× + AR 掐断负对照红）；`run_nputop_sched_ab.sh` PASS（3 plain + W2 8 片链 `MISMATCH=0`）。

**面积（dev_map `c4a_l2d8`，0 error）**：LUT **128,055→68,366.5（81%→43%）**、
APM **542→260（74%→36%）**、FF 155,943→89,877（49%→29%）、DRM 247.5→241.5。
APM 的 −282 精确归到 6 套切片（47 APM/切片）；LUT/FF 是 L=2 与 depth 16→8 的合计，
未单独拆 depth 的贡献（depth 只影响 FIFO 寄存器阵列）。

**性能判据仍未闭合**：本次只改结构与面积，**板上 A/B 未做**（PnR/上板在后续片）。
下一刀不变：DdrMaster/gather 的读请求队列（#429/#430）——CDC 已能多 beat 在飞，
但 `DdrMaster` 仍是结构性单 outstanding，gather 的 272 笔 AR/tile 仍逐笔往返。
