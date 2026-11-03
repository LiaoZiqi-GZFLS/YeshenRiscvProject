# Y1-CPU-Perf：上游 max-ipc 性能开关（可用子集）+ 32K I\$/16K D\$

日期：2026-10-18　上游：用户「I\$ 32K」→「打开所有上游生成器的性能开关」

## 1. 最终配置（已通过裸核 CoreMark 功能闸门）

| 项 | 取值 | 状态 |
|:--|:--|:--|
| I\$ | 64 组 × 8 路 × 64 B = **32 KiB** | ✔（MMU 限 sets≤64，`Param.scala:944`） |
| D\$ | 64 组 × 4 路 × 64 B = **16 KiB** | ✔（同上） |
| **Late ALU / storeRs2Late** | 开（`allowBypassFrom=0`） | ✔ **主收益：1.65→4.47** |
| LSU store buffer | 4 slots × 32 ops | ✔（不增分，但不拖后腿） |
| LSU RPT + software prefetch | 开 | ✔（不增分） |
| 除法器 | radix 4 | ✔（不增分） |
| BTB + GShare + RAS、dispatcher/aligner | 既有 | ✔ |
| Fetch NL 预取 + refill3 | **关** | ✘ 本 SoC/TB 上卡死 |
| LSU refill/writeback 8 | **关** | ✘ 与 late ALU/SB 组合卡死（单项无收益） |

核网表：`rtl/vexiiriscv/VexiiRiscv.v`，**29,693 行**，md5 **`24dfc978afb437f5f08024873dbc3a9c`**
（gen 两次一致）。命令行见 `scripts/gen_core.sh`。

## 2. 裸核 CoreMark 结果（i10，lat=1，CRC `e714/1fd7/8e3a/fcaf` 全部正确）

| 配置 | Total ticks | CoreMark/MHz |
|:--|--:|--:|
| 8 KiB（boot1 基线） | 6,089,100 | 1.6423 |
| 32K/16K cache-only | 6,068,584 | 1.6478 |
| **32K/16K + late ALU + SB + RPT/soft + div4** | **2,235,970** | **4.4723** |

`4.4723` 与上游注释里的「2l + late ALU = 4.39」同量级；差距来自我们的 cache/编译器/配置差异。
store buffer、RPT/soft、div4 单独或叠加都不改变分数（瓶颈在 late ALU 之后的执行通路）。

## 3. 台架修复（重要，避免误判）

最初 max-ipc 全量在裸核台架上"启动即卡死"，一度怀疑核缺陷。实际是**从口 backpressure 模型不足**：
原模型在 R 流/B 未回时把 `ar_ready/aw_ready` 拉低，max-ipc 的前端/存储流水线在合法回压下进入内部停滞
（状态显示 B 已被接受、所有通道空闲，但核不再发射）。改为
**AR 队列 8 / AW 队列 4 / W 队列 16、响应 FIFO、几乎总是可接** 后：
store buffer / late ALU / refill8 单独均恢复正常。随后才定位到
fetch NL 预取/refill3 与 LSU refill8 组合是真实不可用项。

结论：先前"核卡死"的归因作废；**late ALU 等开关本身是好的**。

## 4. PnR 结果（tag `cpufast`，speed，100 MHz）

- **All Constraints Met**：`cpu_clk` WNS **+0.662 ns**（72,821 endpoints）/ `npu_clk` **+0.728 ns**
  （boot1 基线 +0.819/+0.857 ⇒ late ALU 组合只吃掉 0.157 ns CPU 余量）。
- 资源 vs boot1：LUT 73,239→**75,907.5**（48%）/ FF 102,967→**104,998**（33%）/
  DRAM 7,872→7,908（21%）/ DRM 241.5→**255.5**（62%）/ APM 269→270（37%）。
- 比特流：9,188,552 B，md5 **`3722e1c440c4e070c9f7435c99d74955`**。

## 5. 上板（已完成，合法分数）

同一张 ITERS=5500 卡、同一 100 MHz：

| 核 | Total ticks | Iterations/Sec | CoreMark/MHz | 时长 |
|:--|--:|--:|--:|--:|
| boot1（8 KiB） | 3,347,157,311 | 164.318539 | 1.64 | 33.472 s |
| cpufast | 1,197,712,069 | **459.208865** | **4.59** | 11.977 s |

速度比 **2.795×**；均 >10 s；阶段 CRC 一致（`e714/1fd7/8e3a`），`crcfinal 0x33ff`。
Linux 默认/`L` 均启动 PASS；`y1run` 12/12 @4.5096 s/帧（−0.8%）。
ITERS=4100 的同卡趋势：cpufast 4.5996（8.91 s，不合规）/ boot1 1.6423（24.97 s，合规）。
CoreMark 时基已改 32 位 rdtime，板上时间/分数打印正常。

## 6. 回退

`gen_core.sh` 去掉上述性能项，重生成后核 md5 必须回到 `562aa39a…`（8K 基线）。
