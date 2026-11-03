# Y1-CPU-Perf 报告 —— 上游性能开关（可用子集）+ 32K I\$/16K D\$

日期：2026-10-18　规格：`docs/superpowers/specs/2026-10-18-y1-l1-cache-32k-design.md`

**Status: 仿真/上板/PnR 全部收口（合法 4.59 CM/MHz，上板 A/B 2.795×）。**

## 1. 结论

- **I\$ 32 KiB / D\$ 16 KiB 本身只值 +0.34%**（1.6423 → 1.6478）。
- **真正的杠杆是 late ALU**：同一二进制、同一台架，**4.4723 CoreMark/MHz**（+171%）。
  store buffer 4×32、RPT/software prefetch、div4 单独或叠加都不改变分数（不拖后腿）。
- 这与上游注释里的「2l + late ALU = 4.39」同量级，说明我们的核配置已到该档。

## 2. 裸核 CoreMark（i10，lat=1，CRC 全部 `e714/1fd7/8e3a/fcaf`）

| 配置 | Total ticks | CoreMark/MHz |
|:--|--:|--:|
| 8 KiB（boot1 基线） | 6,089,100 | 1.6423 |
| 32K/16K cache-only | 6,068,584 | 1.6478 |
| 32K/16K + late ALU | 2,236,007 | 4.4723 |
| 32K/16K + late ALU + SB | 2,235,970 | 4.4723 |
| **32K/16K + late ALU + SB + div4 + RPT/soft** | **2,235,970** | **4.4723** |
| 32K/16K + late ALU + SB + LSU refill8 | 卡死（无 UART） | — |
| 上一行 + fetch NL 预取/refill3 | 卡死（无 UART） | — |

最终核网表：29,693 行，md5 **`24dfc978afb437f5f08024873dbc3a9c`**（gen 两次一致）。

## 3. 台架修复（关键）

最初 max-ipc 全量「启动即卡死」，一度怀疑核；实际是**我们从口的 backpressure 太强**：
R 流/B 未回时拉低 `ar_ready`/`aw_ready`，max-ipc 的前端/存储流水线在合法回压下进入内部停滞。
把 AXI 从口改为 **AR 队列 8 / AW 队列 4 / W 队列 16、响应 FIFO、几乎总是可接** 后，
store buffer / late ALU / refill8 单独全部恢复正常；随后才定位到真正不可用的组合：
**fetch NL 预取/refill3** 与 **LSU refill8/writeback8**（且这两项单独都没有分数收益）。

台架：`sim/cpu_coremark/tb_coremark.cpp`，运行 `run_cpu_coremark.sh`。

## 4. 面积/时序（PnR `cpufast`）

- **All Constraints Met**：`cpu_clk` WNS **+0.662 ns** / `npu_clk` **+0.728 ns**
  （boot1 基线 +0.819/+0.857；late ALU 组合只吃掉 0.157 ns CPU 余量）。
- 资源 vs boot1：LUT 73,239 → 75,907.5（48%）；FF 102,967 → 104,998（33%）；
  DRAM 7,872 → 7,908（21%）；DRM 241.5 → 255.5（62%）；APM 269 → 270（37%）。
- 比特流：9,188,552 B，md5 `3722e1c440c4e070c9f7435c99d74955`。
- boot1 基线比特流：`ede37d2878347babbf4ce0cce95b7fd5`。

## 5. 上板（已完成，合法分数）

同一张 **ITERS=5500** 卡（`sd_boot_score5500.img`）、同一 100 MHz：

| 核 | Total ticks | Iterations/Sec | CoreMark/MHz | 时长 |
|:--|--:|--:|--:|--:|
| boot1（8 KiB I$，无 max-ipc） | 3,347,157,311 | 164.318539 | **1.64** | 33.472 s |
| **cpufast（32K/16K + late ALU 等）** | **1,197,712,069** | **459.208865** | **4.59** | 11.977 s |

- 速度比 **2.795×**；两者均 >10 s（合法）；阶段 CRC 一致（`e714/1fd7/8e3a`），
  `crcfinal 0x33ff`（同一 ITERS=5500；crcfinal 随迭代数累计）。
- Linux：默认超时与显式 `L` 均 PASS（SD→OpenSBI→Linux→LiteEth→dropbear→登录）；
  `y1run --frames 1` **12/12**，4.5096 s/帧（L2b 基线 4.5467 s，−0.8%）。
- 时基修复：CoreMark 端口改 **32 位 rdtime**（单次 <42.9 s 不回绕）后，
  板上 `Total time`/`Iterations/Sec`/`Coremark/MHz` 打印全部正确。
- 附：ITERS=4100 的同卡 A/B 为 cpufast 891,372,623 ticks（4.5996 CM/MHz，8.91 s）vs
  boot1 2,496,502,443 ticks（1.6423，24.97 s）；因 cpufast <10 s 不作合法分数，仅作趋势。

## 6. 两组未启用旋钮的边际收益（上游理想内存台架，2026-10-18）

问题：`fetch NL prefetch/refill3` 与 `LSU refill8/writeback8` 在我们 TB 上会挂，
值不值得扩 TB 把它们放进来？

**仪器**：上游 `RegressionSingle`（独立副本；CoreMark ELF `rv32imac`，ITERATIONS=10；
benchmark 的 `ibus/dbusReadyFactor` 改成环境变量 `BMK_READY_FACTOR`）。
**配置** = 第 2 节当前 SoC 配置（32K I$/16K D$ + late ALU + RPT/SW prefetch 等）。
脚本：`scripts/bench_vexii_knobs.sh`。
同一配置在上游台架是 **4.93 CM/MHz**（理想内存 + 上游 port），高于我们 TB 的 4.4723；
这里只做同台架 A/B。

| ready factor | base | +fetch | +LSU | both |
|:--|--:|--:|--:|--:|
| 2.0（每拍 ready，理想内存） | 2,026,625 | 2,025,827 (−0.039%) | 2,026,618 (−0.0003%) | 2,024,901 (−0.085%) |
| 0.5 | 2,026,448 | — | — | 2,027,228 (+0.038%) |
| 0.1（≈10 拍/次握手） | 2,032,003 | — | — | 2,032,940 (+0.046%) |

（数字为 Total ticks，10 iter；越小越好。）

- base 的 ready factor 从 2.0 压到 0.1，总 ticks 只涨 **0.265%** —— 这是 CoreMark
  全部内存延迟暴露的**上限**（32K I$ 已装下整个负载）。
- 两组旋钮在理想内存下合计 **−0.085%**，在 0.5/0.1 背压下反而 **+0.04%**；
  连上面 0.265% 的上限都没吃到。
- **结论：不值得为 CoreMark 扩展我们的 TB**，两项保持关闭；5.24 的差距不在它们。
- 边界：该结论只对 CoreMark（L1 常驻）。对真实大工作集（Linux/推理）未测；
  若将来要追那类负载，再用带延迟模型的台架单独评估。
