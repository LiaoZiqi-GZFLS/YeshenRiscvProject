# Y1 小 spec：**NPU 独立时钟域**（把 NPU 从 `cpu_clk` 解耦）

- 日期：2026-10-11
- 上游：`docs/superpowers/specs/2026-10-08-yunet-accelerator-small-design.md`（Y1 总设）、
  `docs/superpowers/specs/2026-10-10-y1-c4-converter-and-coverage-design.md`（C4）
- 动因（实测）：C4a 把 NPU 做进 SoC 后，板级 PnR 的 **`cpu_clk` 被 NPU 拖住** ——
  加 C4a RTL 前 C3 是 `All Constraints Met`（102.65 MHz）；加后一度掉到 **46.74 MHz**，
  两轮流水化后到 **72.53 MHz**（仍未达 100）。NPU 与 CPU 同域 ⇒ **NPU 的长路径直接封顶 CPU 频率**。
- 用户裁决（2026-10-11）：**给 NPU 单独一个时钟**，避免以后提 CPU 频率时被 NPU 拖累。
- 状态：**待审阅**（§4 的待裁决项给了推荐值）

---

## 1. 目标与范围

**做什么**：把 `NpuTop` 移出 `soc_clk`（= `cpu_clk`），放进独立的 `npu_clk` 域；在 NPU 的三个对外接口上做 **CDC**，
使 **NPU 的时序不再约束 `cpu_clk`**，且 **CPU 频率与 NPU 频率各自独立可调**。

**不做什么**：不改 NPU 内部语义/描述符格式/寄存器契约；不改 CPU 核；不改 DDR3 IP；
不做 Y5（摄像头）与 C5（帧率实测）；本 spec 只解"时钟域"这一件事。

## 2. 现状（实测事实，带出处）

| 项 | 现状 | 出处 |
|---|---|---|
| 时钟源 | PLL `pll_100m_125m` 只暴露 `clkout0=100 MHz`（→ `soc_clk`）与 `clkout1=126.5625 MHz`（**未接线**）；`CLKOUT2..6` 被 tie 掉 | `board/pll_100m_125m.v:69-71,88-90,361-375` |
| SoC 是单时钟？ | **是**。`soc_clk` = `cpu_clk`(100 MHz)：CPU / glue / LiteEth / **NPU** / DDR3Bridge 的 AXI 侧 全在这一个域 | `board/yeshen_mini_board_top.v:294,403`；`board/yeshen_mini_soc.v:533,639,734` |
| NPU 实例 | `NpuTop u_npu (.clk(soc_clk), .reset(soc_cpu_reset))`，端口名 `clk`/`reset`；**内部无任何时钟域划分** | `board/yeshen_mini_soc.v:733-735`；`y1/gen/NpuTop.v:60-61` |
| 已有跨域 | 只在 `DDR3Bridge`：`clock`(cpu_clk) ↔ `io_ddr_clk`(core_clk)，机制 = 5 条 `CDCPipe` 四相电平握手（AW/W/AR/R/done） | `src/soc/DDR3Bridge.scala:150-174`；`board_top:403,405` |
| 现成 CDC 原语 | **只有** `src/soc/CDCQueue.scala:11` `class CDCPipe[T]` = **单字四相电平握手**（非 FIFO、非 AXI CDC）；`src/` 里没有别的 | `src/soc/CDCQueue.scala:11-26` |
| NPU 三个接口 | (a) **寄存器窗** AXI4-Lite：`0xF000_C000`/16 KiB；(b) **内存主口** AXI4：addr 28b / data 64b / id 4b / wstrb 8b，**汇入 glue §3.5 的单一未完成（single-outstanding）汇聚点**（与 CPU 共享）；(c) **IRQ** 电平保持，写 `CTRL.soft_reset` 清，PLIC 源 3 | `YeshenSocGlue.scala:107-108,560-735,776-871,324-326`；`yeshen_mini_soc.v:688-756` |
| NPU 复位 | `soc_cpu_reset = glue_reset\|cpu_reset`，是 `soc_clk` 域 2-FF **同步释放**；NPU 网表用**同步复位** | `yeshen_mini_soc.v:210-215,220,735,88-96` |
| 约束风格 | `create_clock`(clk_in/ref_clk/cpu_clk) + `create_generated_clock`(rst/core/phy) + `set_clock_groups -asynchronous`（如 cpu_clk↔core_clk）；**定义顺序有要求** | `constraints/yeshen_mini.fdc:86,88,113,118-127,134-144` |
| 软件 | DTS `npu@f000c000` **没有** `clock-frequency`/`clocks` 属性（NPU 自计时，host 只下描述符 + 等 IRQ） | `sw/.../linux_raw.dts:186-192` |

## 3. 三条路（含推荐）

| 方案 | 内容 | 代价 |
|---|---|---|
| **(A) NPU 整块独立域 + 三处 CDC（推荐）** | 新增 `npu_clk`（复用 `clkout1` 重新参数化，或新加 PLL 输出），`NpuTop` 整块进 `npu_clk`；三处 CDC：(a) 主机窗 AXI4-Lite 异步桥，(b) **内存主口 AXI4 异步桥（放在 glue **汇聚点之前**）**，(c) IRQ 电平 → 2-FF 同步；(d) 各域自带复位同步释放。**glue 的汇聚点/仲裁保持全程 `cpu_clk` 不变**。 | 要**自建 AXI CDC**（仓里只有单字握手原语）；CDC 面积 + 验证是新风险类；NPU 频率要单独定 |
| (B) 只把 NPU 的"核"（LayerSched/UnitExec）放慢，DdrMaster 留 cpu_clk | 在 NpuTop 内部划两域，只对计算核做 CDC | 内部 CDC 更细碎、判据更难；收益同 A 但风险更高 |
| (C) 时钟使能（CE）降速，不加真时钟 | NPU 仍 `cpu_clk`，只把使能按 1/2 拍 | **不解耦时序**（路径仍须在 cpu_clk 周期内收敛）⇒ **不解问题**，排除 |

**推荐 (A)**：唯一真正解耦、且把"冻结的 glue 汇聚点"原样保住的路子。

## 4. 待裁决项（给了推荐值）

1. **`npu_clk` 频率**：推荐**目标 50 MHz 起步**（NPU 现有网表在 R2 后估到 72.5 MHz，留足余量；且 50=100/2 好做）。
   ⚠ 备选：不固定，取"NPU 单独 PnR 能收敛的最坏角落频率"。**要有意选**（NPU 吞吐 ∝ 它自己的频率）。
2. **时钟来源**：推荐**复用 `clkout1` 重新参数化**（现未接线，改动最小）；备选新加一路 PLL 输出。
3. **CDC 放哪**：推荐**全放在 glue 边界**（NPU 侧干净、glue 汇聚点不动）；备选放进 `NpuTop`。
4. **内存口 CDC 的粒度**：AXI4 全握手异步桥（**慢但简单**、够用：NPU 本就 single-outstanding）**vs**
   带异步 FIFO 的流水桥（快、面积大）。推荐**全握手**（与现有 `DdrMaster` 的节拍口径一致、最容易证 CDC 正确）。

## 5. 判据（G1–G6，每条都要**正负对照**）

- **G1（两时钟仿真）**：TB 以**非整数比**两个时钟（如 cpu 100 / npu 37）驱动，**现有全部数值闸门逐字节不变**。
  负对照：把两域接成同一时钟 ⇒ 该判据应"失去意义"（须显式标注，不算通过）。
- **G2（CDC 无丢失/重复）**：内存口/主机窗各跑**背靠背** N 笔，出 == 入 且数据逐字节对；**负对照**：把桥的容量/握手掐短 ⇒ 必须红。
- **G3（IRQ + 复位跨域）**：`npu_clk` 域置起的 IRQ 在 `cpu_clk` 域被稳定观测（电平保持语义不变）；
  两域**复位释放顺序**明确，复位期间 NPU 不出错误事务。
- **G4（时序——本立项的**目的**）**：`npu_clk` 自己在目标频率 `All Constraints Met`；**`cpu_clk` 回到 100 MHz `All Constraints Met`**；
  且"把 NPU 拿掉/降频"与"CPU 频率"解耦（给出对照读数）。
- **G5（回归）**：15 个单元闸门 + C4a 的 8 个闸门 + 台账 + dangling 全绿；**板级上板六级验收不变**（NPU 功能语义没变）。
- **G6（面积 + 软件）**：`dev_map` 记录 CDC 的 Δ 面积；DTS/驱动**无需改**（NPU 自计时）—— 如确需改，写明改什么。

## 6. 风险

| # | 风险 | 处置 |
|---|---|---|
| R1 | 仓里没有 AXI CDC 原语 ⇒ 自建 | 复用 `DDR3Bridge` 的 `CDCPipe` 纪律 + G2 的背靠背判据 |
| R2 | 把 glue 的 single-outstanding 汇聚点拆到两域 | **不拆**：CDC 放在汇聚点之前（§3-A） |
| R3 | CDC 验证是新风险类（亚稳态/漏拍） | 非整数比时钟 + 背靠背 + 掐短负对照（G1/G2/G3） |
| R4 | NPU 降频 ⇒ 帧率下降 | 频率是**有意选**的（§4.1）；与 C5 的帧率口径合账 |
| R5 | 面积（异步桥/握手寄存器） | G6 记 Δ；走 S5 的 `dev_map` 闸门 |
| R6 | 改的是**已验收**的板级集成 | G5 全回归 + 上板六级重跑 |

## 7. 边界与依赖

- 不做：不改 NPU 内部语义、描述符格式、寄存器契约；不做 Y5/C5。
- 依赖：`y1/gen/NpuTop.v`（当前网表）；板级 `pll_100m_125m.v`（可能改参数）；`constraints/yeshen_mini.fdc`（加时钟）。
- 与 C4 的关系：本 spec **不阻塞 C4a 关闭**；C4a 按现口径收口（时序以"NPU 已流水化后的最好值"记录），
  本 spec 作为 **C4b 之前的先决结构改动**推进。
- **C2.4（conditional，两时钟 + 行为级桥模型 ⇒ J2 实测）**：本 spec 把它从"条件项"**转正**并具体化。

## 8. N5b 集成结果（2026-10-11，§3-A 落地）

**已做**：`NpuTop` 整块搬进 `npu_clk`；三座 N3/N4/N5 桥 + `NpuResetSync` **在 Verilog 层**接进
`board/yeshen_mini_soc.v`（glue 的 Chisel 未改），glue 的 pBus 译码 / §3.5 汇聚点**全程 cpu_clk 不变**；
N2/N2b 的 `npu_clk_alive` 脚手架删除（`npu_clk` 有了真功能负载）。

**G1（两时钟）转绿**：`y1/tools/run_twoclock_ab.sh` 现报 **GREEN**（`VERDICT: N5B-OK`）——
单时钟正对照 PASS、两时钟（cpu 100 / npu 37，非整数比）PASS 且逐字节 `MISMATCH=0`、确定性 2×、
负对照（掐断 AR 跨域）发火。**N1 的"先红基线"由此被解掉**（N1 的装置口径不改，只把桥接进去）。

**诚实标注（新事实，供 N6）**：N4 的桥是 **beat-serialized（单拍一手握）** CDC ⇒ 块拷贝比"直连"慢约 4×
（实测：单时钟 ~4150 ns / 16 拍突发；两时钟 ~6270 ns）。128 KiB 拷贝经两座桥约需 8~13 ms（直连约 2 ms）。
这是 spec §4.4 已裁决的"慢但简单"的**预期代价**（本桥吞吐瓶颈在跨域握手往返，不在拍级带宽）；
板级帧率影响的合账留给 N6/C5。

