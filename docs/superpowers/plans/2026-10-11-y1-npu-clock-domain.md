# Y1 实施计划：**NPU 独立时钟域**（把 NPU 从 `cpu_clk` 解耦）

> **For agentic workers:** REQUIRED SUB-SKILL: 用 `superpowers:subagent-driven-development` 逐任务执行。
> 复选 `- [ ]` 跟踪。

**Goal:** `NpuTop` 移出 `soc_clk`，放进独立 `npu_clk` 域；三处 CDC（寄存器窗 / 内存主口 / IRQ+复位）；
使 **`cpu_clk` 的时序不再被 NPU 封顶**，两者频率各自独立。

**Architecture:** 复用 PLL 未接线的 `clkout1` 作 `npu_clk`（可重参数化）；**CDC 全部放在 glue 边界**，
glue 的 single-outstanding 汇聚点**全程留在 `cpu_clk`**；NPU 内部零改动。

**Tech Stack:** SpinalHDL 1.15.0 / Scala 2.12.18 + sbt；iverilog（两时钟 TB）；Pango PDS 2025.2（dev_map/PnR）。

**设计依据：** `docs/superpowers/specs/2026-10-11-y1-npu-clock-domain-design.md`；事实清单见其 §2。

**前置（已收口）：** C3 上板六级验收；C4a 功能全绿（时序见下）。**本计划在 C4b 之前做。**

---

## 全局约定（沿用 C3/C4a 计划，逐条相同）

- **不上板**（除非用户给时机）；只做 RTL + 仿真 + 综合/映射/PnR 的离线部分。
- **只读资产**：`third_party/**` 与冻结工具（`ddr_traffic.py`/`fusion_buffer.py`/`bypass_traffic.py`/
  `mac_ref.py`/`bypass_ref.py`/`conv_unit_ref.py`/`desc_table.py`）—— **import 复用，绝不改**。
- **不改**：NPU 描述符格式、寄存器契约、CPU 核、DDR3 IP、`y1/gen/NpuTop.v` 的**语义**。
- **判据必须带正负对照**；产物记指纹（md5/字节数）；不匹配要**响亮失败**；闸门退出码 `0/1/2/3`。
- **生成器** `headerWithDate=false` / `headerWithRepoHash=false`。
- **Python 环境**：`cd /d/code/PDS/VexiiYeshenLinux/y1 && PYTHONIOENCODING=utf-8 PYTHONPATH='./.pydeps;../third_party/yunet/deps' /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe <script>`。
- **提交**（本机无 git 身份；**不 push**；**绝不改 git config**）：单次注入 `GIT_AUTHOR_*` / `GIT_COMMITTER_*`。
- **每轮 RTL 改动后**：15 个单元闸门 + 台账 + dangling 全绿；**改了 RTL 就要重跑 PnR**。

## 文件结构（预期新增/改动）

```
board/
├── pll_100m_125m.v          # 【改】clkout1 重参数化为 npu_clk（或新增一路输出）
└── yeshen_mini_board_top.v  # 【改】把 npu_clk 接到 SoC 的新端口
board/yeshen_mini_soc.v      # 【改】NpuTop 改接 npu_clk；新增 npu_clk/npu_rstn 端口
src/YeshenSocGlue.scala      # 【改】三处 CDC（寄存器窗 / 内存口 / IRQ+复位）
constraints/yeshen_mini.fdc  # 【改】create_clock(npU) + set_clock_groups -asynchronous
rtl_test/                    # 【新】两时钟 TB 装置
y1/reports/npu_clock.md      # 【新】报告（G1–G6 + 面积/时序）
```

---

### Task N1: 两时钟仿真装置（**先红**）—— G1 的装置半

**Files:** Create `rtl_test/NpuTwoClockTb.v`（或扩既有 `board/` 级 TB）+ `y1/tools/run_twoclock_ab.sh`

- [ ] **Step 1**：把 glue+NpuTop 的现有 TB 改成**两个独立时钟**（cpu 100 MHz / npu **非整数比**，如 37 MHz）。
- [ ] **Step 2**：**先红** —— 在两域还没做 CDC 时，内存口/主机窗在异频下必然出错 ⇒ 断言必须**红**（这就是"CDC 缺失"的负对照基线）。
- [ ] **Step 3**：判据：`run_twoclock_ab.sh` 退出码 `0/1/2`；打印两时钟频率比与失败形状。

### Task N2: `npu_clk` 时钟源 + 板级拓扑 + 约束

**Files:** Modify `board/pll_100m_125m.v`、`board/yeshen_mini_board_top.v`、`constraints/yeshen_mini.fdc`

- [ ] **Step 1**：把 `clkout1` 重参数化为目标 `npu_clk`（§4.1 裁决值，默认 **50 MHz**）；板级把它接到新的 `soc` 端口。
- [ ] **Step 2**：fdc 加 `create_clock`/`create_generated_clock`（按 §2 的现有风格、注意**定义顺序**）+ `set_clock_groups -asynchronous {cpu_clk} {npu_clk}`。
- [ ] **Step 3**：判据：`dev_map`/轻量综合能报出**两个独立时钟**（时钟树/`report_clocks` 两域都在）；给读数。
- [ ] **Step 4**：**注意**：本节只加时钟与约束，**先不接 NPU**（NpuTop 此时仍 cpu_clk）⇒ 设计行为不变，是个安全中间态。

### Task N3: 寄存器窗 AXI4-Lite 异步桥 —— G2 半

**Files:** Modify `src/YeshenSocGlue.scala`；Create `rtl_test/NpuCdcAxiLiteTb.v` + 判据

- [ ] **Step 1**：在 glue 边界做 `cpu_clk → npu_clk` 的 AXI4-Lite 桥（全握手，复用 `CDCPipe` 纪律；AXI-Lite 单笔 ⇒ 简单）。
- [ ] **Step 2**：判据（正）：穷举写/读回**逐字节对**（沿用 C1.1 的寄存器穷举口径）；**负对照**：掐短握手 ⇒ 必红。
- [ ] **Step 3**：回归：既有 `run_hostregs_ab.sh` 等仍绿。

### Task N4: 内存主口 AXI4 异步桥（**放在 glue 汇聚点之前**）—— G2 半

**Files:** Modify `src/YeshenSocGlue.scala`；Create `rtl_test/NpuCdcAxiMemTb.v` + 判据

- [ ] **Step 1**：在 **汇聚点之前**做 `npu_clk → cpu_clk` 的 AXI4 异步桥（AW/W/B/AR/R 五通道，全握手）；
  **glue 的 single-outstanding 汇聚点/仲裁保持全程 `cpu_clk`，一个字不改**。
- [ ] **Step 2**：判据（正）：**背靠背** N 笔 1 KB 块拷贝（复用 C2.1c 的 J1 字节级往返口径），出==入、数据逐字节对；
  **负对照**：把桥的握手/容量掐短 ⇒ 必红（证明"容量"这一拍在起作用）。
- [ ] **Step 3**：G2 的"无丢失/重复"用**计数 + 数据双判据**（不只比末值）。

### Task N5: IRQ + 复位跨域 —— G3

**Files:** Modify `src/YeshenSocGlue.scala`、`board/yeshen_mini_soc.v`

- [ ] **Step 1**：IRQ（**电平保持**语义不变）`npu_clk → cpu_clk` 用 2-FF 同步（保持到 `CTRL.soft_reset` 清）。
- [ ] **Step 2**：**复位**：每域各自的复位同步释放（异步置位 / 同步释放）；`npu_clk` 域的 NPU 复位释放顺序写进文件头。
- [ ] **Step 3**：判据：IRQ 在异频下被稳定观测（正）；复位期间不出错误事务（负对照：把释放顺序调反 ⇒ 必红）。

### Task N5b: **集成** —— 三桥 + reset sync 接进板级 SoC + `NpuTop` 搬 `npu_clk`（**已完成**）

- [x] **Step 1**：`board/yeshen_mini_soc.v` 在 Verilog 层例化 `Npu{AxiLite,Mem,Irq}Cdc` + `NpuResetSync`
  （glue 的 Chisel **不改**）：glue.io_npuAxi_* ↔ NpuAxiLiteCdc ↔ NpuTop.axilite_*；
  NpuTop.axi_* ↔ NpuMemCdc ↔ glue.io_npuMem_*（§3.5 汇聚点不变）；NpuTop.irq → NpuIrqCdc → glue.io_npuIrq；
  `NpuResetSync` 产两域低有效复位（cpu 先/npu 后），`NpuTop.reset = ~npuRstn`。
- [x] **Step 2**：`NpuTop.clk` 改接 `npu_clk`；删 `npu_clk_alive` 脚手架（SoC 端口 + 板级诊断字节 + 头注释）。
- [x] **Step 3**：`devmap_c4a.tcl` / `pnr_c4a.tcl` 源清单加 `board/pll_50m.v` + 4 份桥网表；
  新增 `y1/pds/devmap_n5b.tcl`（N5b 探针）。
- [x] **Step 4**：`NpuTwoClockTb.v` 接 4 份桥网表（与板级同拓扑），`run_twoclock_ab.sh` 改为**两时钟绿 + 掐断 AR 负对照**。
- [x] **Step 5**：`CdcPipeSp` 定义名参数化（N4 用 `NpuMemCdcPipe*`）以解两桥同处一设计时的子模块重名；重生成两桥网表。
- [x] **Step 6**：回归（全部 `run_*_ab.sh` + 台账 + dangling 全绿）、netlist 确定性 2×、`dev_map` 探针（两钟 + npu_clk 真负载）。

### Task N6: 收口 —— 回归 + 面积/时序 + 板级重跑

**Files:** Modify `y1/pds/{devmap,pnr}_*.tcl`（含新时钟）；Create `y1/reports/npu_clock.md`

- [ ] **Step 1**：**G4**：`npu_clk` 在目标频率 `All Constraints Met`；**`cpu_clk` 回到 100 MHz `All Constraints Met`**；
  给出对照读数（"NPU 在/不在 `cpu_clk`"两种）。
- [ ] **Step 2**：**G5**：15 单元闸门 + C4a 8 闸门 + 台账 + dangling 全绿；**上板六级验收**重跑（时机由用户给）。
- [ ] **Step 3**：**G6**：`dev_map` 记 CDC 的 Δ 面积；确认 DTS/驱动**无需改**（NPU 自计时）。
- [ ] **Step 4**：`y1/reports/npu_clock.md` 写清 **G1–G6 的证据**与**能证/不能证**（不能证 C5 帧率）。

---

## 自查记录

1. **覆盖面**：§3-A 的三处 CDC → N3/N4/N5；§2 的时钟源 → N2；§5 的 G1–G6 → N1/N3/N4/N5/N6。
2. **占位**：无 TBD；待裁决项（§4）给了推荐值，用户可在审阅时改。
3. **不阻塞**：本计划**不阻塞 C4a 关闭**；C4a 以"NPU 流水化后的最好时序"记档，本计划作为 **C4b 前的先决结构改动**。
4. **一处诚实标注**：`cpu_clk` 能否在 N4/R3b 之后已回 100 MHz、从而"本计划只是提前投保"——**要等 R3b 判词**；
   若已回 100，本计划仍做（用户要为 CPU 提频留头），但 G4 的"收益"读数会变成"余量"而不是"救回"。
