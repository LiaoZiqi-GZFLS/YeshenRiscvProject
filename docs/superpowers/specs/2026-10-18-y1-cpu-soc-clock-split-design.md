# Y1 CPU / SoC 时钟拆分设计（2026-10-18）

## 1. 目标与非目标

**目标**：把 VexiiRiscv 核从 `soc_clk`（100 MHz，外设/CLINT/PLIC/DDR 桥/DMA 所在域）中拆出来，核改跑独立 `cpu_clk`。第一步两域都跑 100 MHz 做功能等价；第二步只把 `cpu_clk` 抬到 108 MHz（PLL 合法档），SoC 仍 100 MHz。

**非目标**：
- 不改 VexiiRiscv 核内部（网表不动）。
- 不动 DDR（`core_clk` 125 MHz）、LiteEth（`rgmii_clk`）、NPU（`npu_clk`）三个域。
- 本步不追 108 MHz 的 PnR 收敛；先证明拆分本身无功能回归。

**为什么拆**：当前 `cpu_clk` 域 = 核 + 全部 SoC 外设，PnR 慢角估计上限 107.09 MHz；且升频会连带改 UART 波特、`timebase-frequency`、BootSel/装载器分频。拆开后 SoC 固定 100 MHz，这些软件/外设口径全部不动，只有核单独升频。

## 2. 现状与目标拓扑

```
现状：
  pll_100m_125m ── cpu_clk(100M) ──┬── VexiiRiscv u_cpu
                                   └── YeshenSocGlue (CLINT/PLIC/UART/SD/DMA/AXI 汇聚)
                                       └── DDR 桥 / LiteEth / NPU 桥的 soc 侧

目标：
  pll_100m_125m ── soc_clk(100M) ── YeshenSocGlue（一切外设、CLINT、PLIC、DDR 桥、DMA）
  pll_cpu       ── cpu_clk(100M→108M) ── VexiiRiscv u_cpu
        │
        └── 三条 AXI4 主口经异步 FIFO 桥 → glue 的 io_cpuFetch/io_cpuLsu/io_cpuIo
  CLINT mtime ──Gray CDC──→ cpu 域 rdtime
  glue 中断电平 ──2FF──→ cpu 域 mtip/msip/meip/seip
  复位：glue_reset | cpu_reset ──异步置位/同步释放（各域）──→ CPU + 桥两侧 FIFO
```

**CLINT 留在 soc 域**：`mtime` 仍是 100 MHz 时基，DTS `timebase-frequency`、16550 `clock-frequency`、BootSel/装载器分频全部不变。CPU 的 `rdtime` 经 Gray CDC 读 100 MHz 时基（最多滞后几拍），与 CLINT 的 `mtimecmp` 比较口径一致。

## 3. 异步桥

三条 AXI4 主口全部“逐通道异步 FIFO”：

| 口 | 通道 | 位宽 |
|:--|:--|:--|
| Fetch（只读） | AR / R | AR 52b；R 64+2+1 |
| LSU（全 AXI4） | AW / W / B / AR / R | AW 52b；W 64+8+1；B 2b；AR 52b；R 64+2+1 |
| IO（Cacheless，单拍） | AW / W / B / AR / R | AW 32+3+4+3；W 32+4+1；B 2b；AR 42b；R 32+2+1 |

- 每个通道一个 dual-clock FIFO（depth 16，Gray 指针 + 2FF 同步，1 拍/项稳态吞吐）。
- 源域 `valid/ready` 直接接 FIFO 写侧；目的域 `valid = !empty`、`ready` 接 FIFO 读侧。
- 请求方向 CPU→SoC；响应方向 SoC→CPU（B/R 的 FIFO 源/目的域对调）。
- 无 AXI ID（CPU 口本来就没有），故无乱序/ID 重排问题。
- 只增加“每笔 miss / MMIO”约 5–10 拍延迟；L1 命中路径完全不经过桥，稳态吞吐不受影响。

模块（新增，均放 `board/`）：
- `dcfifo.v`：Gray 指针异步 FIFO（参数 WIDTH/DEPTH）。
- `axi4_cdc_fetch.v`：AR/R 桥。
- `axi4_cdc_lsu.v`：AW/W/B/AR/R 桥（64b）。
- `axi4_cdc_io.v`：AW/W/B/AR/R 桥（32b、无 len/burst）。

**为什么不用仓里现成的 `CdcFifo`**：它是 4 相握手 + lanes 的吞吐型 FIFO，每项 4–6 拍；AXI 的每拍 R/W 都过一次会显著拖慢 refill。这里用真 dual-clock FIFO（1 拍/项）。

## 4. 时钟源

新增第三颗 `GTP_GPLL`（器件 GPLL 用量 4/10，有余量）：

- `board/pll_cpu.v`：27 MHz → VCO 675 MHz（RATIOI=1 / RATIOM=1 / RATIOF=25，PFD=27、VCO∈[600,1200]）。
  - 100 MHz：`RATIO0=6.75`（=6+6/8，1/8 网格合法），`DUTY0=6`。
  - 108 MHz：`RATIO0=6.25`（=6+2/8），`DUTY0=6`；675/6.25=108.000000 精确。
- `GTP_CLKBUFG` 缓冲后进 `u_soc.cpu_clk`。
- 原 `pll_100m_125m` 的 clkout0 更名 `soc_clk`（物理参数一字不改）。

## 5. FDC 改动

- `create_clock -name soc_clk [get_pins {u_pll/u_gpll/CLKOUT0}] -period 10.000`（原 `cpu_clk` 全部语义改名为 `soc_clk`）。
- `create_clock -name cpu_clk [get_pins {u_pll_cpu/u_gpll/CLKOUT0}] -period 10.000`（第一步；第二步 9.259）。
- `set_clock_groups -asynchronous`：`cpu_clk` ↔ `soc_clk`、`npu_clk`、`core_clk`、`phy_dq_*`、`rgmii_clk`、`clk_in/ref_clk`。
- 原 `cpu_clk` 与各域的异步组改为 `soc_clk`（NPU 桥的 soc 侧仍在 `soc_clk`）。

## 6. 复位与特权输入

- `bridge_rst = glue_reset | cpu_reset`（soc 域电平，CPU 装载期/上电期有效）：
  - CPU 域：异步置位、2FF 同步释放 → `u_cpu.reset` + 桥源侧 FIFO 复位。
  - soc 域：同一信号同步 → 桥目的侧 FIFO 复位（保证两侧 FIFO 一起清）。
- `rdtime[63:0]`：soc 域 `mtime` → `mtime ^ (mtime>>1)` → 2FF 进 cpu 域 → Gray→binary → `u_cpu.PrivilegedPlugin_logic_rdtime`。
- `int_m_timer/int_m_soft/int_m_ext/int_s_ext`：各自 2FF 进 cpu 域。
- 其余（`cpu_reset` 输出给 NPU、`io_npuIrq`）保持 soc 域不变。

## 7. 软件影响

- **第一步 100/100：零软件改动**（timebase/UART/BootSel/装载器全在 soc 域）。
- **第二步 108 MHz**：timebase/UART 仍 100 MHz，Linux/OpenSBI 无改动。唯一口径问题：CoreMark 端口用 `rdtime`（100 MHz 时基）当 cycles，打印的 `Coremark/MHz` 会虚高 8%；合法分数 `iterations/sec`（墙钟）仍正确。届时把端口打印改成 `iterations_per_sec / CPU_MHZ`（或直接标 CPU 频率）。

## 8. 验证计划

1. **桥单元 TB**（iverilog，Git Bash）：两时钟 100/108，随机背压，跑 AR/R 突发、AW/W/B、IO 单拍；逐字节对账；负对照（去同步器 / 单侧复位）必须失败。
2. **lint**：Verilator（WSL）对 `dcfifo/axi4_cdc_* + yeshen_mini_soc`。
3. **功能等价（100/100）**：上板 Linux 启动 marker → CoreMark 5500 → y1run 12/12；与拆分前逐项对比。
4. **升频 108**：PnR 9.259 ns 闭合 + 上板复跑；CPU 估计上限 107.09，差 79 ps，需 seed sweep。
5. **资源/时序**：dev_map 记录 LUT/FF/DRM 增量；PnR 报告 `soc_clk` 10.000 / `cpu_clk` 9.259（或 10.000）两组 WNS。

## 9. 风险

- CDC 指针/复位错误 → 数据错/挂死：靠桥 TB + 单侧复位负对照。
- 桥增加 miss 延迟 → CoreMark 小幅下降（预计 <1%），108 MHz 升频净赚。
- 两侧 FIFO 复位不同步 → 半笔事务：统一用 `bridge_rst` 清两侧。
- FDC 改名遗漏 → 旧 `cpu_clk` 约束落到新网或落空：用 `grep cpu_clk` 全量核对 + PDS 时序报告时钟表。

## 10. 实施结果（第一步 100/100）

**单元闸门**：
- `sim/cpu_soc_cdc/tb_axi_cdc.v`：100↔108 MHz、100↔400 MHz、随机背压；LSU 单拍/8-beat、IO、Fetch 全部逐字节 PASS；`DCFIFO_BAD_DATA` 负对照会红。
- `sim/cpu_soc_cdc/tb_cpu_domain_cdc.v`：rdtime 单调、滞后 <32 拍、IRQ 置/撤、复位断言/释放 PASS。
- 注：RTL 仿真无法建模亚稳态，`DCFIFO_BAD_SYNC` 负对照不会红；CDC 正确性依赖标准 Gray 结构 + 复位配对，最终由 PnR/上板判定。

**dev_map**（tag `split100`）：无 ERROR；LUT 76,220.5（48%）、FF 105,530（34%）、DRM 255.5（62%）、Distributed RAM 8,112（21%）、GPLL 5/10。相对 cpufast：LUT +313、FF +532（FIFO 存储落到分布式 RAM）。

**PnR**（tag `split100b`，100/100，speed 综合，seed 0 收敛即停）：

| 时钟 | 请求 | 估计上限 | WNS |
|:--|--:|--:|--:|
| `soc_clk` | 100.000 MHz | 108.5658 MHz | +0.789 ns |
| `cpu_clk` | 100.000 MHz | **107.0664 MHz** | +0.660 ns |
| `npu_clk` | 54.3478 MHz | 56.6123 MHz | +0.736 ns |
| `core_clk`（DDR） | 125 MHz | 140.7460 MHz | +0.895 ns |

- Design Summary：**All Constraints Met**。
- seed 0：place 12m18s / route 11m14s / optimize 1m56s；总 compile→bitstream 45m16s。
- 比特流：9,188,552 B，md5 **`42f64af01e4d37342127c09ee1f33957`**。
- **判读**：`cpu_clk` 仍是 107.07 MHz（拆分前 107.09），符合预期——限制路径在核内（late-ALU→branch flush→PC/History→FetchL1 bank CE），拆分只解耦外设。第二步 108 MHz 还差约 81 ps（9.340→9.259 ns），需 9.259 ns 约束重新 PnR + seed sweep；必要时动 flush→fetch 路径。

## 11. 板上 Linux 挂死排查（2026-10-18）

**现象**：`split100b`（真异步 100/100）启动到 dropbear 后，`S97uart_dbg.sh` 打印
`IRQDBG start` + `IRQDBG 1: 68 SiFive PLIC 1 ttyS0` 即停住；无用户态 marker/login，ping 不通。
裸机 `BootSel C` CoreMark 5500 正常（459.208338 iter/s、4.59 CM/MHz、CRC 全对）。

**同频对照**（tag `split100_sync`：`u_soc.cpu_clk` 临时接 `soc_clk`，三座桥/CDC 逻辑保留）：
同样停在 `IRQDBG 1` ⇒ **排除异步 CDC/跨时钟域**，问题在桥的数据路/协议。

**IO 桥持续压力**：原 FIFO 桥 64 笔背靠背写 + 64 笔读（`tb_axi_cdc_stream`）PASS，
B 计数 64；说明 FIFO 满/空/绕圈边界不是根因。

**根因假设**：IO 桥源侧 ready 只看 FIFO 空间 ⇒ CPU 认为一笔 MMIO 写已完成、立刻发
LSR 读时，读走另一条 FIFO 先到 glue，UART 控制台的“写 THR → 读 LSR”次序反转，
printk 等 THRE 时挂死。裸机 CoreMark 的简单轮询序列没有暴露。

**修复（候选）**：`board/axi4_cdc_io.v` 重写为
- 传输：复用 `NpuAxiLiteCdc`（NPU 主机寄存器窗已在板上验证的 4 相握手 CDC，单 outstanding）；
- 源侧事务锁：一笔读/写完整完成（R/B 握手）前不接受下一笔，读/写互不超车；
- IO 单拍：`size=2`、`cache=0`、`wlast/rlast=1`（glue 的 IO 从口不使用 size/cache），`prot/wstrb` 透传。

**闸门**：`tb_axi_cdc` PASS；`tb_axi_cdc_stream` 64 笔写 + 64 笔**串行**读数据全对，
但 B 计数 66 vs 64（多 2 个 B），作为已知待观察项；板级结果为准。
（复核口径：TB 的 B 计数按 `bvalid` 电平拍计数而非 fire 拍；NPU CDC 的 deq.valid
在 fire 前保持，背压期间会多计拍。板上 `split100_ord` 三项验收全过，未观察到多余 B
引发的写跟踪错乱。）

**修复结论（2026-10-19 上板验收）**：`split100_ord` 比特流（异步 100/100）
**Linux 完整启动**，`S97uart_dbg.sh` 五轮 `IRQDBG` + `UARTDBG` + `PLICDBG` +
`IRQDBG end` 全部打完，`login:` 出现；`flash_and_verify.py --no-net` 八个 marker 全 PASS
⇒ 根因假设成立：**IO 桥读/写超车**是 Linux 挂死的真因。

**PnR**（tag `split100_ord`，异步 100/100，speed，seed 0 −0.005 未收敛 → seed 1 收敛）：

| 时钟 | 请求 | 估计上限 | WNS |
|:--|--:|--:|--:|
| `soc_clk` | 100.000 MHz | 106.1008 MHz | +0.575 ns |
| `cpu_clk` | 100.000 MHz | 106.0783 MHz | +0.573 ns |
| `npu_clk` | 54.3478 MHz | 56.0978 MHz | +0.574 ns |
| `core_clk`（DDR） | 125 MHz | 138.4275 MHz | +0.776 ns |

- Design Summary：**All Constraints Met**（Best Slack Seed 1；seed0 Setup(Slow) −0.005，
  多 seed 策略按 `-pick_first_timing_convergence_seed true` 自动换 seed，总耗时 38m51s）。
- 比特流：9,188,552 B，md5 **`906b011557f0009446176efb7cbf79dd`**。

**上板功能等价（100/100）**：

| 验收项 | 结果 | 与拆分前对比 |
|:--|:--|:--|
| Linux 启动 | 8 marker 全 PASS，`login:` 可登录 | 一致（修复后） |
| CoreMark 5500 | 459.208530 iter/s，11.977129 s，**4.59 CM/MHz**，crc `e714/1fd7/8e3a/33ff` | 一致（原 459.208338 / 4.59 / 同 CRC） |
| y1run 1 帧 | **12/12 PASS**，4.509 s/帧 | 一致（L2b 基线 4.510–4.547 s） |

⇒ 第一步 100/100 收口。下一步：`pll_cpu` RATIO0=9.375（108 MHz）+ FDC 9.259 ns 重新 PnR。

## 12. 第二步：CPU 108 MHz（2026-10-19）

**配置**：`board/pll_cpu.v` `STATIC_RATIO0=9.375 / STATIC_DUTY0=9`（VCO 1012.5 / 9.375 =
**108.000000 MHz**，1/8 网格精确）；`constraints/yeshen_mini.fdc`
`create_clock cpu_clk -period 9.259 -waveform {0 4.6295}`。soc_clk / npu_clk / DDR 全部不动。

**PnR**（tag `split108`，异步，speed，fresh）：

| 时钟 | 请求 | 估计上限 | WNS |
|:--|--:|--:|--:|
| `cpu_clk` | 108.003 MHz | **113.7398 MHz** | +0.467 ns |
| `soc_clk` | 100.000 MHz | 106.8947 MHz | +0.645 ns |
| `npu_clk` | 54.3478 MHz | 55.9660 MHz | +0.532 ns |
| `core_clk`（DDR） | 125 MHz | 136.6680 MHz | +0.683 ns |

- seed 0 Setup(Slow) **−0.006**（仅差 6 ps）→ 自动换 seed；seed 1 **+0.111** 收敛即停。
- 总 compile→bit_stream 37m16s；比特流 9,188,552 B，md5 **`fe58cf5e53b525a7747f58193655ebba`**。
- 结论：拆分后 CPU 域在 108 MHz 有 **+0.467 ns** 余量（拆分前 100 MHz 下估计上限 107.09，
  拆分 + 桥的物理实现反而把上限推到 113.74 —— 头号路径仍能收敛，与"拆分不解核内路径"不矛盾：
  这是本轮布局/优化后的实测上限，不是拆分本身带来的频率增益）。

**上板验收（108 MHz）**：

| 验收项 | 结果 |
|:--|:--|
| Linux 启动 | 8 marker 全 PASS；IRQDBG 五轮 + UARTDBG + PLICDBG + `IRQDBG end` 全打完 |
| CoreMark 5500 | **496.406746 iter/s**，11.079624 s，CRC `e714/1fd7/8e3a/33ff` 全对 |
| y1run 1 帧 | **12/12 PASS**，4.508 s/帧（NPU 在 54 MHz，不受 CPU 升频影响） |
| 板内定时器 | UART 登录下 `date; sleep 2; date` 精确 +2 s；`/proc/interrupts` timer 正常递增 |

- CoreMark 吞吐 **×1.0810**（496.4067 / 459.2085），与 108/100 的频率比一致；CRC 与 100/100、
  拆分前完全相同 ⇒ 升频未改变数值行为。
- 板上打印的 `4.96 Coremark/MHz` 是 `core_main.c` 的 `1e6/ticks×iterations` 口径
  （ticks = 100 MHz mtime）——它是"每 1e6 mtime 拍完成的迭代数"，随 CPU 升频同比放大；
  **真实每 MHz 效率 = 496.4067 / 108.003 = 4.596 CM/MHz，与 100 MHz 的 4.592 持平**。
- 观测（不阻塞交付）：108 MHz 刚启动后的窗口内，主机经 WSL/dropbear 的 ssh 命令偶发
  `rc=255`（约 20 s = `ServerAliveInterval×CountMax` 超时），表现为命令已执行、输出已回但
  会话不关闭；同一时刻 UART 登录、y1run、`sleep` 全部健康。**Linux 稳定运行后复测全部
  `rc=0`**（`sleep 2` 精确 +2 s、y1run 12/12）⇒ 判定为 boot 后瞬态（dropbear/网络初始化
  窗口 + 主机 WSL），不是 108 MHz 功能缺陷。

**交付配置与回退**：当前源即 108 MHz 配置；回 100 MHz 只需改两处（PLL RATIO0=10.125/
DUTY0=10，FDC period 10.000/waveform 5.000），100/100 的已验证比特流为
`split100_ord`（md5 `906b0115…`）。
