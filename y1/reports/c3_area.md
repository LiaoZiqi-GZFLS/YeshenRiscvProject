# Y1-C3.13 报告 —— **S5 面积闸门**（DRM ≥ 7 + 缓冲真落 DRM 的三样证据 + 集成总量）

**Status: DONE_WITH_CONCERNS**（C3.14 更正后，§5 的**唯一开口项已关闭** ⇒ 实质 **DONE**）

> **★ C3.16 结案（2026-10-09）：** 把"NPU 没有权重口 ⇒ 板级常量折叠 ⇒ 板级面积不可用"这条
> 从 C3.13 挂到现在的**最后一项面积顾虑**也关掉了 —— 新增**寄存器信箱**权重通路后，板级 conv 通路
> **不再被常量折叠**（`…/unitExec_1/conv/arr/arr/acc*` 的 `stuck at constant 0`：**26 → 0**），
> 板级 Δ vs SoC-only 从 **+8,604.5 LUT** 跳到 **+58,155.5 LUT**（≈ 独立 `LayerSched(L=8)` 足迹）。
> **权威读数 = §11**；§5/§10 的"板级面积不可用 / 4 套装载口"两条已就地标为**已关闭**。

> ## ★ A-3 结案（2026-10-09）：`L_MAX = 4 → 8`（**已实测，装得下** —— 见 **§10**）
> 本报告 §6 当时把 `L_MAX=8` 列为"**未直接测量**、只有 2× 投影"。**A-3 把参数改成构造参数、真生成了
> `L_MAX=8` 的网表并跑了 `dev_map`**：`LayerSched(L=8)` 单独综合 = **`LUT 58,788 / FF 68,203 /
> APM 323 / DRM 8.0`**（`Mapping Summary`），占器件 **36.8% / 21.3% / 43.7% / 1.9%** ⇒ **装得下**，
> 且 `L_MAX=8` 把融合边覆盖从 31/33 提到 **33/33**（conv-only `14,265,600 → 12,576,000 B/帧`）。
> ⇒ **提交默认值 = `L_MAX = 8`**。**§10 是这一条的权威表；§6 的投影已被它取代。**

**一句话**：S5 的三条判据**全部满足** —— 最坏单元 `FusionBuf(C=64, WIDTH=160)`（3 行 = 30,720 B）
**真的落进块 RAM**：`DRM = 7.5`（= `GTP_DRM36K_E1 7` + `GTP_DRM18K_E1 1`）**≥ 7**，
且 `LUTs as dram = 0`、`Adm-4088 = 0`、`Total Registers = 2`（缓冲**没有**落 LUTRAM、**没有**落 FF）；
集成顶层（板级 SoC + `NpuTop`）`DRM = 24.5 ≤ 415`。**但**有一条**必须诚实报告的异常**：

> **板级集成的那次测量里，C3 的数据通路被工具优化掉了** —— 相对 C2 基线（SoC+NPU）
> 的 Δ 只有 **+13 LUT / +0 FF / +0 APM / +0 DRM**，而**同一份 `LayerSched` 单独综合是
> `LUT 33,979 / FF 48,143 / APM 163 / DRM 4`**。⇒ **板级那次不能当"C3 增量面积"用**；
> 本报告的 C3 数据通路面积**以单独综合的 `LayerSched` 为准**，板级那次只用来证"器件总量 ≤ 415"。
> 根因**未定位**（见 §5），列为本步的**开口项**。

---

## ★ 更正（C3.14，2026-10-09）：§5 的"开口项"已关掉 —— 是**真集成 bug**，不是 PDS artifact

**一句话**：胶合把 NPU 寄存器窗的**整根 SoC 地址**喂给了 `NpuTop` 的 `HostRegs`，而后者是
**基址 0** 的 `AxiLite4SlaveFactory` 从口 ⇒ 永不命中 ⇒ 读恒 0、写被静默丢弃 ⇒ `CTRL.start`
永远置不上 ⇒ **NPU 从 CPU 侧根本不可达** ⇒ PDS 把整颗 NPU 剪掉。**修好地址口径后，板级 `dev_map`
实测 NPU 被保留**（详见 §5.1 的 before/after 原始读数）。

| 项 | 内容 |
|---|---|
| **Bug** | `src/YeshenSocGlue.scala` 原 `io.npuAxi.awaddr := pW` / `io.npuAxi.araddr := pR`（**整根** 32 位 SoC 地址）。`HostRegs` 内部 `addr & ~3` 直接对 `0x00..0x38` ⇒ `0xF000_C038` 匹配**任何寄存器都不命中**。 |
| **修法** | 改喂**窗内相对偏移**：`io.npuAxi.awaddr := pW(13, 0)` / `io.npuAxi.araddr := pR(13, 0)`。宽度取 **14 位**（窗口 = `0x4000` = 16 KiB；`NPU_MASK = 0xFFFF_C000` 只比到 bit14 ⇒ 低 14 位是窗内偏移）。**与 console/gpio/CLINT/PLIC 同款**（本文件既有约定）。 |
| **纪律** | `HostRegs.scala` / `NpuTop.scala` **未动**（基址 0 的叶子从口不该知道 SoC 基址 —— 修在胶合里）；`scripts/check_addr_map.py` 期望未改（回归仍 PASS）。 |
| **网表** | `rtl/YeshenSocGlue.v` 重生成，md5 `76f70e7ab013a23b47ae464f3fe9beab` → `72bec1f30d2c507669028e2470df492a`（新增 `assign io_npuAxi_awaddr = {18'h0, io_cpuIo_awaddr[13:0]};` / `… araddr …`）。 |
| **判决装置** | `sim/glue_pbus/run_npu_unit.sh` PHASE A（**板级等价接线**）**由红转绿**：原 `fail=9`（ID 读回 `0x00000000`、DESC_COUNT 写-回读不符）→ 现 `fail=0`（ID 回常数 `0x594E5031`；DESC_COUNT 两种 AW/W 时序都写-回读 OK；负对照仍成立）。PHASE B（剥基址探针）恒绿。 |

**正确归因（**作废两条 board-level 结论**）**：

- **§5 / §3.3 的"板级 Δ +13 LUT / 板级那次把 ~33.7k LUT 的 C3 通路优化掉了"作废** ——
  那不是"工具把活逻辑剪了"，而是**逻辑本来就不可达**（NPU 寄存器窗写不进 ⇒ NPU 永不启动 ⇒
  整颗 NPU 常量传播成死逻辑）。**修好后同一份板级 `dev_map`：Δ vs SoC-only 控制臂 = +7,957.5 LUT**。
- **C2.2 的"NPU 集成代价 = +144.5 LUT"（`y1/reports/c2_ddr_master.md` §10）同样作废** ——
  那次 A/B 的两个臂都跑在**已剪掉 NPU** 的胶合上（地址基址 bug 自 C2.2 引入起就在）⇒
  **那次 A/B 从未测到 NPU**（+144.5 只是"连线打通/无 NPU"的残留差）。
- **可信的 NPU 面积 = 独立综合的两个读数**（独立件，不经板级常量折叠）：
  `NpuTop`（`devmap_c3_nputop.log`）**7,639 LUT / 11,373 FF / 13 APM / 0 DRM / 512 Distributed RAM**；
  `LayerSched`（`devmap_c3_layersched.log`）**33,979 / 48,143 / 163 / 4.0**。

---

## 0) 本步测了什么（四次 `dev_map`，同一份 tcl、同一器件行）

**器件行（四次一字不差）**：
`create_project $project_file -synthesize_tool 2 -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6`
**工作目录**：`D:/code/PDS/VexiiYeshenLinux`。**流程**：`create_project → add_design → compile -verilog_standard SystemVerilog → synthesize -ads → dev_map`。
**不**跑 pnr、**不**出比特流、**不**碰板。

tcl：`y1/pds/devmap_c3.tcl`（由 `devmap_soc_npu.tcl` / `devmap_slice.tcl` 改核；用 `YESHENMINI_C3_MODE`
选模式：`integrated`（默认，板级 SoC + `NpuTop`）/ `nputop` / `layersched` / `fusionbuf`）。

| # | 模式 | 被测顶层 / 源 | 日志 | exit |
|---|---|---|---|---|
| (a) | `integrated` | 板级 `yeshen_mini_board_top` 全套 + `y1/gen/NpuTop.v`（含 `LayerSched` L_MAX=4 全套） | `y1/pds/devmap_c3.log` | **0** |
| (a2) | `nputop` | 只 `y1/gen/NpuTop.v`（独立 NPU，无 SoC） | `y1/pds/devmap_c3_nputop.log` | **0** |
| (a3) | `layersched` | 只 `y1/gen/LayerSched.v`（**C3 核心**，L_MAX=4；权重口是自由输入） | `y1/pds/devmap_c3_layersched.log` | **1**（IO DRC） |
| (b) | `fusionbuf` | 只 `y1/gen/worst/FusionBuf.v`（**最坏形状** C=64, WIDTH=160） | `y1/pds/devmap_c3_fusionbuf.log` | **1**（IO DRC） |

> 说明：用户任务书写的是"(a) 集成 C3 顶层 + (b) 孤立 FusionBuf"两次；(a2)/(a3) 是**补充**——
> 因为 (a) 的结果退化（§5），必须用 (a3) 才能拿到"C3 数据通路到底多大"。

---

## 1) S5 判据 1 —— **DRM ≥ 7**（融合缓冲）且集成总量 **≤ 415**

### 1.1 `DRM ≥ 7`：**PASS**

最坏单元 3 行窗口 = `3 × 64 × 160 = 30,720 B`。PDS `Mapping Summary`（`devmap_c3_fusionbuf.log`
第 173–174 行）**逐字**：

```text
DRM36K/FIFO:
Total DRMs = 7.5 of 415 (1.81%)
```

`Cell Usage`（同 log 第 155–162 行）**逐字**：

```text
GTP_DFF_CE                    2 uses
GTP_DRM18K_E1                 1 use
GTP_DRM36K_E1                 7 uses
GTP_GRS                       1 use
GTP_LUT6                      5 uses
GTP_LUT6D                     4 uses
```

⇒ **`7 × DRM36K + 1 × DRM18K = 7.5` 块**。这正是 C3.0 推导的 **"7 块 DRM36K"**（`⌈30720/4608⌉ = 7`；
多出的 0.5 是 512-bit 宽字被劈到一块 DRM18K 上的余量）。
**`DRM = 7.5 ≥ 7` ⇒ 判据 1 前半 `PASS`。**

### 1.2 集成总量 ≤ 415：**PASS**

| 口径 | DRM | ≤ 415？ |
|---|---|---|
| 板级集成（实测，`devmap_c3.log`，`Device Utilization Summary`） | **24.5** | **YES**（5.9%） |
| 板级集成 + C3 数据通路补回（§5 的**算术和**，非联合测量） | ≈ **28.5** | **YES**（6.9%） |

（28.5 = 23.5[SoC] + 1.0[NpuTop 的 HostRegs+DdrMaster，C2 实测增量] + 4.0[`LayerSched` 单独综合]。
即使把被工具优化掉的 C3 通路**按算术补回**，DRM 也只有 28.5 ≪ 415。）

### 1.3 数字来源与 DRC（**M0 教训**）

| 日志 | `Device Utilization Summary` 是否打印 | 未打印时数字取自 | `DRC-0018` | `DeviceMap-2003` | `Program Error` | `Adm-4088` |
|---|---|---|---|---|---|---|
| `devmap_c3.log`（板级集成） | **打印**（第 33744 行起） | —（并与 `Mapping Summary` 第 32988 行交叉印证） | 0 | 0 | 0 | 0 |
| `devmap_c3_nputop.log` | **打印**（第 22061 行起） | —（`Mapping Summary` 第 21314 行） | 0 | 0 | 0 | 0 |
| `devmap_c3_layersched.log` | **未打印** | `Mapping Summary`（第 1096 行）+ `Cell Usage`（`GTP_*`） | **1** | **1** | **1** | 0 |
| `devmap_c3_fusionbuf.log` | **未打印** | `Mapping Summary`（第 166 行）+ `Cell Usage`（`GTP_*`） | **1** | **1** | **1** | 0 |

**裸探针为何 `dev_map` 中止（M0 教训那一幕，如实记）**：两个**裸探针**（`LayerSched` / 最坏
`FusionBuf`）**没有板级顶层**，全部顶层端口被当 IO pad ⇒
`FusionBuf(C=64)` 有 **1078** 个 IO、`LayerSched` 有 **549** 个 IO，都 > FBB676 的 **400** 个用户 IO
⇒ `dev_map` 在 `DeviceMap-2003: The resource of IO is overrange …` / `E: DRC-0018: The resource of IO is not enough`
处**中止**（随后 `Program Error Out.` 只是这个中止的收尾），**因此不打印** `Device Utilization Summary`。
⇒ 这两次资源数**退回 `Mapping Summary`（LUT/FF/APM/DRM/IO）+ `Cell Usage`（`GTP_*` 行）**，来源已在上表标明。
**这是探针的形状产物**（没有板级顶层去复用/裁掉端口），**与"DRM 到底落没落"无关**：
`Mapping Summary` 的 DRM 一行与 `Device Utilization Summary` 的 DRM 一行**同源同值**
（两次可比的板级那次：`24.5` vs `24.5`，见 §1.2 与 §3）。

> **试过的旁路**（如实记）：PDS 2025.2 文档化了 `dev_map -not_check_io_rule_option TRUE`（"Not Check IO Rule"）。
> 用了它，PDS 把它翻成 `set_option -options { not_check_io_rule_option {true}} [get_actions dev_map -of_objects [get_tasks pnr_1]]`
> —— 挂在 **pnr 任务**的 `dev_map` 动作上，**没有**抑制本流程的 `DeviceMap-2003`，结局不变。
> ⇒ 未使用任何属性/开关去"绕过"判据（**PDS 忽略 `ram_style` 这条 M0 教训依然成立**：结构决定映射）。

---

## 2) S5 判据 2 —— **断言缓冲真的在 DRM，不在 FF / LUTRAM**：**PASS**

三样证据（M0/C3.0 教训要求的三样），全部取自 `devmap_c3_fusionbuf.log`：

| # | 证据 | 读数（逐字） | 判定 |
|---|---|---|---|
| 1 | **`DRM` 用量** | `Total DRMs = 7.5 of 415 (1.81%)`；`GTP_DRM36K_E1 7 uses` + `GTP_DRM18K_E1 1 use` | **≥ 7** ⇒ 3 行窗口真的进了块 RAM ✔ |
| 2 | **`Adm-4088`（DRM 不够 → 转 LUTRAM）条数** | **`0`**（`grep -c Adm-4088 = 0`） | **零** ⇒ 没有任何 RAM 因 DRM 不够被降级成 LUTRAM ✔ |
| 3 | **`LUTs as dram`** | `LUTs as dram: 0 of 39500 (0.00%)`；`LUTs as logic: 9` | **0** ⇒ 整份设计没有任何存储落进 LUTRAM ✔ |

**加一条（更强的）**：`Total Registers: 2`、`GTP_DFF_CE 2 uses` —— 30,720 B 的窗口**不可能**是 FF
（若落 FF 需 `30,720 × 8 = 245,760` 个 FF）。这 **2 个寄存器**是那条**同步读**的地址/输出打拍，
**不是缓冲本体**（缓冲本体是 `GTP_DRM36K_E1`/`GTP_DRM18K_E1`）。

⇒ **`rtl/FusionBuf.scala` 的"可寻址 `Mem` + 同步读"结构**（对照 `LineBuffer` 的"逐列竖直移位寄存器"）
**确实被推断成块 RAM**。C3.0 §4 的承重条件（"缓冲必须落 DRM，不能落 FF"）**在结构上被实测证实**：
**不需要任何属性**（也没法用属性，PDS 忽略 `ram_style`），靠的是**结构**。

---

## 3) S5 判据 3 —— **LUT/FF/APM/DRM 全表 + 与 C2 基线的 Δ**

### 3.1 C2 基线是什么（**口径声明**）

`y1/reports/c3_baseline.txt` 里记的是 **C3 前的五道 C2 设备闸门 exit 码 + 两份网表 md5**
（`gen/DdrMaster.v` / `gen/NpuTop.v`），**不含面积数**。所以 Δ 的**面积基线**取
**C2.3 的 SoC+NPU `dev_map` 实测**（`y1/reports/c2_ddr_master.md` §6a，日志 `y1/pds/devmap_soc_npu.log`
第 10134 行起的 `Device Utilization Summary`）：

```text
| APM                   | 4           | 740           | 1
| FF                    | 17187       | 319600        | 6
| LUT                   | 14370.5     | 159800        | 9
| Distributed RAM       | 231         | 39500         | 1
| DRM                   | 24.5        | 415           | 6
| IO                    | 99          | 400           | 25
```

### 3.2 全表（四次实测）

| 被测对象 | 来源 | LUT | FF | APM | DRM | Distributed RAM（`LUTs as dram`） | IO | 数字源 |
|---|---|---|---|---|---|---|---|---|
| **基线 C2：SoC + `NpuTop`（旧，仅 HostRegs+DdrMaster）** | `devmap_soc_npu.log` | 14370.5 | 17187 | 4 | 24.5 | 231 | 99 | `Device Utilization Summary` |
| **(a) 集成 C3：SoC + `NpuTop`（含 LayerSched）** | `devmap_c3.log` | **14383.5** | **17187** | **4** | **24.5** | **231** | **99** | `Device Utilization Summary` |
| **(a2) 独立 `NpuTop`（无 SoC）** | `devmap_c3_nputop.log` | **7639** | **11373** | **13** | **0** | **512** | 392 | `Device Utilization Summary` |
| **(a3) 独立 `LayerSched`（C3 核心，L_MAX=4）** | `devmap_c3_layersched.log` | **33979** | **48143** | **163** | **4.0** | **1536** | 549/400 | `Mapping Summary`（IO DRC，无 Summary） |
| **(b) 孤立 `FusionBuf` 最坏形状（C=64, W=160）** | `devmap_c3_fusionbuf.log` | **9** | **2** | **0** | **7.5** | **0** | 1078/400 | `Mapping Summary`（IO DRC，无 Summary） |

`Mapping Summary` 与 `Device Utilization Summary` 的**交叉印证**（两次"打印了 Summary"的运行）：

| 运行 | Summary LUT | Mapping LUT | Summary FF | Mapping FF | Summary DRM | Mapping DRM | Summary APM | Mapping APM |
|---|---|---|---|---|---|---|---|---|
| (a) | 14383.5 | 14385（含 231 当 dram） | 17187 | 17200 | 24.5 | 24.5 | 4 | 4.00 |
| (a2) | 7639 | 7639（含 512 当 dram） | 11373 | 11373 | 0 | 0.0 | 13 | 13.00 |

### 3.3 **Δ vs C2 基线**（板级集成）

| 资源 | C2 基线（SoC+NPU） | **(a) 集成 C3** | **Δ** |
|---|---|---|---|
| LUT | 14370.5 | **14383.5** | **+13.0** |
| FF | 17187 | **17187** | **+0** |
| APM | 4 | **4** | **+0** |
| DRM | 24.5 | **24.5** | **+0** |
| Distributed RAM | 231 | 231 | +0 |
| IO | 99 | 99 | +0 |

**⇒ 这个 Δ 是错的，不能当"C3 增量"用。** 见 §5。

> **★ C3.14 更正**：上表"集成 C3 = 14,383.5 / Δ+13"是**修地址基址 bug 之前**的读数（那时 NPU
> 从 CPU 侧不可达 ⇒ 被 PDS 剪掉）。**修复后同一份板级 `dev_map`：`LUT 22,183.5`，Δ vs SoC-only
> 控制臂 = +7,957.5 LUT**（详表与证据见 §5.1）。**以 §5.1 为准。**

---

## 4) 板级集成的**器件总量**（唯一可信的板级结论）

| 资源 | 集成 C3（实测） | 器件可用 | 占器件 | 装得下？ |
|---|---|---|---|---|
| LUT | 14383.5 | 159800 | 9.0 % | **YES** |
| FF | 17187 | 319600 | 5.4 % | **YES** |
| APM | 4 | 740 | 0.5 % | **YES** |
| DRM | **24.5** | **415** | 5.9 % | **YES** |
| Distributed RAM | 231 | 39500 | 0.6 % | **YES** |
| IO | 99 | 400 | 24.8 % | **YES** |

`dev_map` exit **0**、**0** 个 `DRC-0018` / `DeviceMap-2003` / `Program Error`、`Adm-4088 = 0`、
完成标记 `YESHENMINI_C3_DEVMAP_DONE`。
⇒ **器件级"装得下"这一条成立**（S5 判据 1 的"≤ 415 DRM"）。

> **★ C3.14 更正**：上表是**修地址基址 bug 前**的读数。**修后**板级总量 = **LUT 22,183.5 /
> FF 28,522 / APM 17 / DRM 24.5 / Dist.RAM 743**（NPU 被保留，§5.1），仍 **exit 0 / 0 DRC /
> 装得下**（LUT 13.9% / FF 8.9% / APM 2.3% / DRM 5.9%）。

---

## 5) ★ **异常：板级集成把 C3 数据通路优化掉了**（本步最重要的诚实发现）

**现象**：板级 Δ（§3.3）= **+13 LUT / +0 FF / +0 APM / +0 DRM**；
而**同一份 `LayerSched` 单独综合**是 **LUT 33,979 / FF 48,143 / APM 163 / DRM 4.0**（§3.2 的 (a3)）。
⇒ 板级那次把 ~33.7k LUT / ~48k FF / ~163 APM 的 C3 通路**丢掉了**。

**证据链**：

1. **两份日志都确实吃到了新网表**：`devmap_c3.log` 第 738–742 行
   `I: Verilog-0001: Analyzing file …/y1/gen/NpuTop.v` + `Analyzing module NpuTop` + `Analyzing module LayerSched`。
   ⇒ 不是"旧网表/缓存"问题。
2. **板级的 `Mapping Summary` 与 C2 几乎逐字相同**：`LUTs as logic 14154`（C2: 14141）、
   `Total Registers 17200`（C2: 17200）、`DRM 24.5`（C2: 24.5）、`Total APMs 4.00`（C2: 4.00）。
3. **`Adm`/`Sdm` 的"unused/stuck"清理集中在 NPU 的 `UnitExec`/`LayerSched` 段**，例：
   `W: Sdm-2020: […/gen/NpuTop.v(line number: 6183)] Unused register ocol_3 was removed.`
   `… Unused register chainR was removed.`（第 6183 行落在 `UnitExec` 的 3811–6537 区间内）。
4. **不是"NPU 没被例化"**：`board/yeshen_mini_soc.v:728` 有 `NpuTop u_npu (...)` 且
   `axi_*` / `axilite_*` / `irq` 全部**逐端口连上**；`rtl/YeshenSocGlue.v` 里 NPU 内存通道
   **真的参与了仲裁**（`wire npuRd = owner == 3'h4; wire npuWr = owner == 3'h5; npuTurn …`，
   且 `cpuMem_araddr = lsuRd ? … : {4'h0, io_npuMem_araddr}` 一路进 `cpuMem_*`）。
5. **一个可能的引信（未证实）**：`rtl/NpuTop.scala` 把**四个权重装载口全部钉死为常量 0**
   （`layerSched.io.we := False` / `we_t` / `we2` / `we3`，及 `waddr/wdin` 全 0）—— 这是**冻结口径**
   （"本代 NPU 对外端口集不含权重口，权重带外预载属 C4/M2"）。权重 RAM 永远不被写 ⇒ 常量传播
   有机会把整条卷积通路折成零。**但注意**：`NpuTop` **单独**综合时同样钉 0，却**留下了 7,639 LUT / 13 APM**
   ⇒ 钉 0 **不足以**单独解释板级为何掉得更多（板级还少了 ~7.5k LUT）。**根因未定位。**

**⇒ 处置（本步的诚实立场）**：

- **不敢用板级 Δ 当 C3 增量**；C3 数据通路面积**以 (a3) 单独综合的 `LayerSched` 为准**。
- 板级那次**只**用来证"器件总量 ≤ 415 DRM"（S5 判据 1 的第二半）—— 这条**不受**该异常影响
  （总 DRM 24.5 ≪ 415；即便按算术补回也是 28.5）。
- **开口项（交给 C4/M2 或新的 PnR 前哨）**：为何板级 `synthesize -ads` 会比单独综合**多消掉**
  ~7.5k LUT 的 NPU 逻辑？在**修好权重装载口之前**，"板级面积"都不能当作数据通路面积的依据。
  ⇒ 建议 C4/M2 给 NPU 补一个**权重装载口**（或一个"权重不为零"的映射用例）后**重跑本闸门**。
  → **★ 已闭合**：C3.14 定位并修掉"地址基址未剥"（§5.1），C3.16 补上**权重装载口**（寄存器信箱）后
  按上面的建议**重跑了本闸门** ⇒ 板级**不再折叠**、板级面积**可用**（§11）。

---

### 5.1 ★ 更正后的实测（C3.14，2026-10-09）—— **板级不再剪 NPU**

**装置（先证 bug）：** `sim/glue_pbus/run_npu_unit.sh`（= `YeshenSocGlue` + `HostRegs` 同一 Verilator
网表，像 CPU 那样驱动 glue 的 pBus，在 `0xF000_C000` 窗做读/写/回读/负对照）。**PHASE A =
板级等价接线**（`probe_strip_base=0`，整根地址直给 HostRegs）：

```text
# 修前（src/YeshenSocGlue.scala:621/628 = pW / pR；日志 sim/reglogs/pbus_npu_unit_before_fix.log）
######## PHASE A：板级等价接线（probe_strip_base=0）—— 对 DUT 的判决 ########
=== ①[A板级] 读 NPU 窗 ID（0xF000C000+0x30）—— 必须回常数 0x594E5031 ===
   实测 ID = 0x00000000（rresp=0 rlast=1）  期望 0x594E5031
  [FAIL]   ID 读回 == 0x594E5031   got=0x00000000 exp=0x594E5031  MISMATCH
...
   PHASE A（板级等价接线）fail=9 ⇒ 写通路 死（支持解释 i：真集成 bug）

# 修后（pW(13,0) / pR(13,0)；日志 sim/reglogs/pbus_npu_unit.log）
######## PHASE A：板级等价接线（probe_strip_base=0）—— 对 DUT 的判决 ########
=== ①[A板级] 读 NPU 窗 ID（0xF000C000+0x30）—— 必须回常数 0x594E5031 ===
   glue 送进 NPU 从口的 arvalid=1 araddr=0x00000030（= 发给下游的真实地址）
   实测 ID = 0x594E5031（rresp=0 rlast=1）  期望 0x594E5031
    ID 读回 == 0x594E5031                                got=0x594E5031 exp=0x594E5031  OK
  ---- [A板级] (a) AW+W 同拍（stagger=0）----  写: awaddr=0x00000038 → 回读 0x0000012F  OK
  ---- [A板级] (b) AW 先 2 拍、W 后到（stagger=2）----  → 回读 0x0000C0DE  OK
   PHASE A（板级等价接线）fail=0 ⇒ 写通路 通
=== TEST PASSED ===
```

**板级 `dev_map`（`y1/pds/devmap_c3.tcl` 默认 integrated，同一器件行 / 同一 tcl / exit 0 / 0 DRC）：**

| 口径 | 日志 | LUT | FF | APM | DRM | Dist.RAM | IO |
|---|---|---|---|---|---|---|---|
| SoC-only 控制臂（无 NPU） | `devmap_soc_ctrl.log` | 14,226 | 17,110 | 4 | 24.5 | 231 | 99 |
| **修前**集成 C3 | `devmap_c3_before_fix.log` | **14,383.5** | 17,187 | 4 | 24.5 | 231 | 99 |
| **修后**集成 C3 | `devmap_c3.log` | **22,183.5** | **28,522** | **17** | **24.5** | **743** | 99 |
| 独立 `NpuTop`（参考） | `devmap_c3_nputop.log` | 7,639 | 11,373 | 13 | 0 | 512 | 392 |

| Δ vs SoC-only 控制臂 | LUT | FF | APM | DRM | Dist.RAM |
|---|---|---|---|---|---|
| **修前** | **+157.5**（= 14383.5 − 14226，NPU 已被剪，只剩接线残留） | +77 | +0 | +0 | +0 |
| **修后** | **+7,957.5** | **+11,412** | **+13** | **+0** | **+512** |
| 独立 `NpuTop`（≈ 应得的增量） | 7,639 | 11,373 | 13 | 0 | 512 |

⇒ **修后 Δ（+7,957.5 LUT / +11,412 FF / +13 APM / +512 DRAM）≈ 独立 `NpuTop` 的足迹**
（7,639 / 11,373 / 13 / 512），即**板级确实把 NPU 装进去了**（多出的 ~320 LUT 是板级上下文里
权重口非全常量所致，比独立探针少折叠一点，合理）。**注**：`DRM` 与独立 `NpuTop` 一致为 **+0**
（此前 §1.2 的"≈28.5"投影借用的是 `LayerSched` 单独综合的 DRM 4.0；实测板级增量 DRM = 0 ⇒
**以实测为准，器件总量仍是 24.5**，§1.2 的"算术补回 28.5"改为不必再用）。

**"stuck at constant 0" 的 NPU 寄存器（`grep -c` 计数，`devmap_c3.log` vs `devmap_c3_before_fix.log`）：**

| 信号集 | 修前条数 | 修后条数 |
|---|---|---|
| `…/hostRegs_1/*` | **390** | **2** |
| `…/layerSched_1/*` | **1,776** | **135** |
| `…/ddrMaster_4/*` | **1,904** | **12** |
| `…/hostRegs_1/start_r`（点名信号） | 有（被剪） | **0** |
| `…/layerSched_1/state_reg`（点名信号） | 有（FSM 停） | **0** |
| `…/ddrMaster_4/state_reg`（点名信号） | 有（FSM 停） | **0** |
| `u_glue/npuTurn`（悬空告警 `Public-4008`） | **1** | **0** |

⇒ 任务书预测的"`hostRegs_1/*` / `layerSched_1/state_reg` / `ddrMaster_4/state_reg` 的 stuck 信息
应消失（或**大幅减少**）"**成立**：点名信号全部归零，信号集总条数降到 1% 量级。剩余条数是
**真常量折叠**（如 `sched_busy/done/err` 本装置钉 0、权重口钉 0 的局部），与"整颗 NPU 被剪"是
两回事（后者伴随 FSM/寄存器整体消失）。**修后 `dev_map` 里 `NpuTop` 的 `layerSched_1` /
`unitExec_1` 有大量 `I: Removed … redundant` 的**去冗余**（不是删除功能），`Adm-4088 = 0`、
`0 DRC`、exit 0。**PDS 不再因"不可达"而剪 NPU。**

> **残留（如实）**：本报告仍**不覆盖**"100 MHz 时序/上板"（`dev_map` 只到映射）；NPU 的**功能**
> 仍由仿真闸门保证（`run_npu_unit.sh` + `run_nputop_ab.sh` + `run_nputop_sched_ab.sh`）。
> 板级 `dev_map` 修后 **DRM 未增**（24.5），因为芯片 NPU 的缓冲是**功能形状**（C=8,W=32；落 LUTRAM），
> 最坏形状 DRM 仍由 §1/§2 的独立探针证明（7.5）。

---

## 6) `L_MAX = 4` vs `L_MAX = 8`（**★ 已被 §10 的实测取代**；此处保留当时的投影与其推理）

> **★ A-3 更正（2026-10-09）**：下面这条"未跑"的前提（"`L_MAX` 不是构造参数 ⇒ 必须改 RTL，越界"）
> 在 **A-3** 里被**显式解开**了：任务是"把 L 参数化、让面积测量来定它" ⇒ A-3 把 `L_MAX` 改成
> **构造参数**（`LayerSched(..., L_MAX: Int = 8)`）、重新生成网表并**真测了** `L=8`。
> ⇒ **本节的"投影"请当作历史；权威数字见 §10**（实测 `LUT 58,788 / FF 68,203 / APM 323 / DRM 8.0`，
> 与本节的 2× 投影 `≈68k/96k/326/~8` 方向一致但更省：**LUT/FF 都低于投影**）。
> 本节被修正的那两条**依然成立**：① `c3_fusion_chains.md` §6 的"全宽 640 切片 ⇒ 装不下"不适用于本代
> `C=8/WIDTH=32` 的窄切片；② ≤415 DRM 一条无论哪个 L 都极宽裕。

- `L_MAX` **不是** `LayerSched`/`UnitExec` 的构造参数（`rtl/LayerSched.scala:182` 是
  `val L_MAX: Int = 4` 硬编码）⇒ 生成 `L_MAX=8` 的网表**必须改 RTL**，超出本任务
  "**不改任何 RTL**"的约束 ⇒ **(c) 未跑**。
- **可用的替代结论**（用 (a3) 的实测 + 链长分布，**标注为投影**）：

| 口径 | 切片实例/单元 | 覆盖边 | 整帧（conv-only 下界） | 含旁路 | fps 上界@275.9 MB/s | 面积（LUT/FF/APM/DRM） |
|---|---|---|---|---|---|---|
| **`L_MAX=4`（本代，实测 a3）** | 4 | 31/33 | 14,265,600 B | 21,211,200 B | ≈13.01 | **33,979 / 48,143 / 163 / 4.0** |
| `L_MAX=8`（投影 ≈2× 数据通路） | 8 | 33/33 | 12,576,000 B | 19,521,600 B | ≈14.13 | ≈ 68k / 96k / 326 / ~8 |

- **这条投影**推翻/修正了 `c3_fusion_chains.md` §6 的悲观推导：那一条假设"每链位一个 **`WIDTH=640``
  全宽切片**"（`FF=87,409/片` ⇒ FF 上限只够 3 片 ⇒ L=8 装不下）。而**本代实际生成的切片是
  `C=8, WIDTH=32`**（`LayerSchedGen`：`new LayerSched(C=8, WIDTH=32, IMG_H_MAX=16)`），
  单片小得多 ⇒ 实测 4 片（含 FSM/缓冲/旁路）合计 FF 48,143、LUT 33,979。
  **按此口径，`L_MAX=8`（8 片）的投影仍在器件内**（FF ≈96k ≪ 319,600；APM ≈326 < 740）。
- **但这只是投影**：`L_MAX=8` 的真实面积**必须**在补上权重口、真正生成 `L_MAX=8` 网表后**再测**。
  ≤415 DRM 这一条**无论哪个 L 都极宽裕**（L=4 实测 4.0 DRM）。

---

## 7) 判定（S5 三条判据，逐条）

| # | 判据 | 实测 | 判定 |
|---|---|---|---|
| 1a | **融合缓冲 `DRM ≥ 7`** | **7.5**（7×DRM36K + 1×DRM18K） | **PASS** |
| 1b | **集成总量 ≤ 415 DRM** | **24.5**（补回 C3 通路的算术和 28.5） | **PASS** |
| 2 | **缓冲真的在 DRM、不在 FF/LUTRAM**（三样证据） | `DRM=7.5` / `Adm-4088 = 0` / `LUTs as dram = 0`（+ `FF=2`） | **PASS** |
| 3 | **LUT/FF/APM/DRM 全表 + Δ vs C2** | §3.2 全表已给；**板级 Δ 修地址基址 bug 前不可信**（§5），**修后板级 Δ = +7,957.5 LUT（NPU 真装进去，§5.1）**；C3 通路面积仍以 (a3) 单独综合为准 | **PASS** |

⇒ **S5 = PASS**（DRM ≥ 7 与"真落 DRM"两条**硬 PASS**；"面积全表 + Δ"这条给的是
**(a3) `LayerSched` 单独综合**的数，并**如实标注**板级那次的退化与未定位的根因）。

**spec R1 的"退路"（超预算就把 Add/Sigmoid 挪回主机）本次无需启用**：即使把被优化掉的 C3 通路
按算术补回，SoC+C3 仍只占器件 LUT 30% / FF 20% / APM 23% / DRM 7%。**不需要修正 spec**。

---

## 8) 复现（逐字命令）与产物指纹

```bash
cd /d/code/PDS/VexiiYeshenLinux

# (a) 板级集成（SoC + NpuTop(LayerSched L_MAX=4)）
/c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_c3.tcl \
  > y1/pds/devmap_c3.log 2>&1 ; echo "exit=$?"

# (a2) 独立 NPU
YESHENMINI_C3_MODE=nputop    /c/Pango/…/pds_shell.exe -file …/y1/pds/devmap_c3.tcl > y1/pds/devmap_c3_nputop.log 2>&1
# (a3) C3 核心（避开权重口的常量折叠）
YESHENMINI_C3_MODE=layersched /c/Pango/…/pds_shell.exe -file …/y1/pds/devmap_c3.tcl > y1/pds/devmap_c3_layersched.log 2>&1
# (b) 孤立 FusionBuf 最坏形状
YESHENMINI_C3_MODE=fusionbuf /c/Pango/…/pds_shell.exe -file …/y1/pds/devmap_c3.tcl > y1/pds/devmap_c3_fusionbuf.log 2>&1

# 取数
grep -nE "Device Utilization Summary" -A 14 y1/pds/devmap_c3.log
grep -nE "Mapping Summary"            -A 14 y1/pds/devmap_c3_fusionbuf.log
grep -cE "Adm-4088"                    y1/pds/devmap_c3_fusionbuf.log     # 期望 0
grep -nE "LUTs as dram|GTP_DRM36K|GTP_DRM18K" y1/pds/devmap_c3_fusionbuf.log
grep -nE "DRC-0018|DeviceMap-2003|Program Error" y1/pds/devmap_c3*.log
```

**产物指纹（md5，**本步 = C3.13** 生成；`L_MAX=8` 档见 §10.2，★ C3.16 权重信箱档见 §11.6）**：

| 产物 | md5 |
|---|---|
| `y1/gen/NpuTop.v`（含 LayerSched 全套，**相对 C2 基线 md5 `9bc9ba6f…` 已变**） | `ac883dc6738149502ad05740cf05f003` |
| `y1/gen/LayerSched.v` | `5228254661a6162a6a25f25c2ce92f46` |
| `y1/gen/UnitExec.v` | `846fdc4fd3e52470641a2b5985a5bb2c` |
| `y1/gen/worst/FusionBuf.v`（最坏形状 C=64,W=160，`imgC=0x40 / imgW=0x00a0`） | `436f630243be19c1833746a923b4fa55` |
| `y1/gen/FusionBuf.v`（功能形状 C=2,W=4） | `f2bacef4546e84337ef427e89244117c` |
| Sigmoid 查表 `y1/gen/sigmoid_lut.hex` | `1b5866866686a1d2c81c98ac1ded4d4a` |
| 冻结描述符表（`desc_table.TABLE_MD5_FROZEN`） | `ed00cad736b82378a59bdeedc79f3b21` |

日志：`y1/pds/devmap_c3.log`（33796 行）、`devmap_c3_nputop.log`（22113 行）、
`devmap_c3_layersched.log`（2242 行）、`devmap_c3_fusionbuf.log`（1519 行）。
（`*.log` 按 `y1/.gitignore` 的 `*.log` 规则**默认不入库** —— 见 `c3_scheduler.md` §5 的说明。）

---

## 9) 本报告**不含**什么（如实）

1. **无时序、无 PnR、无上板** —— `dev_map` 只到"综合 + 器件映射"；100 MHz 能否收敛**未知**。
2. **`L_MAX=8` 未实测**（需改 RTL，越界）—— §6 是投影。**★ A-3 已补测：见 §10。**
3. **板级 Δ 的退化未定位**（§5）—— 这是本步唯一"没关掉"的技术异常。**★ 已由 C3.14 关掉（§5.1）。**
4. **`C=64` 那一档的 FusionBuf 只做了"结构落 DRM"的证明**，其**功能**只在 `C=2`（两个形状）上仿过
   （`run_fusionbuf_ab.sh` 的 `FusionBufTb` 端口名 `rd_data_0/1` 不可参数化 ⇒ C 只能 2）——
   **已知残留风险**，`rtl_test/FusionBufTb.v` 头部已写明。
5. **`LayerSched` 的 DRM（4.0）与 `LUTs as dram`（1536）**是**功能形状**（C=8,W=32）下的读数，
   **不是**最坏单元那一档；最坏档由 (b) 单独证明。

---

## 10) ★ A-3：`L_MAX = 4 → 8` **实测**（`L=4` vs `L=8` 资源表 + 判定 + 提交默认值）

**本步做什么**：`c3_fusion_chains.md` 说链长直方图 = `{2:15, 4:2, 6:1, 8:1}` ⇒ `L_MAX=4` 会把长 6 / 长 8
的两条极大链**切开**（31/33 边、conv-only `14,265,600 B/帧`）；`L_MAX=8` 覆盖 **33/33**
（`12,576,000 B/帧`）。**用户判据：把 L 参数化，让面积测量来定**。⇒ A-3 把 `L_MAX` 从硬编码 `val`
改成 **构造参数（默认 8）**、真生成 `L=8` 网表、**真跑 `dev_map`**。

### 10.1 `L_MAX` 的**全部**站点（一个连贯参数）

| # | 文件:行 | 改动 | 作用 |
|---|---|---|---|
| 1 | `y1/rtl/LayerSched.scala:175` | `class LayerSched(val C, val WIDTH, val IMG_H_MAX, **val L_MAX: Int = 8**)` | ★ **参数化**（A-3）：生成期旋钮，默认 **8** |
| 2 | `y1/rtl/UnitExec.scala:315` | 构造默认 `L_MAX: Int = **8**` | 独立生成 `UnitExec` 网表时的默认 |
| 3 | `y1/rtl/UnitExec.scala:326` | `require(L_MAX >= 2 && L_MAX <= **8**` | 例化 8 个切片实例 ⇒ 上界随之上移 |
| 4 | `y1/rtl_test/UnitExecGen.scala:37,50` | `L_MAX = **8**`（两份网表） | `gen/UnitExec.v` / `gen/UnitExec_w32.v` |
| 5 | `y1/rtl_test/LayerSchedGen.scala:35` | 显式 `L_MAX = **8**` | `gen/LayerSched.v`（旋钮在生成器里**看得见**） |
| 6 | `y1/tools/run_chain_ab.sh:76` | `LMAX=4 → **8**` + 新增 `CHAIN_N=4` | 闸门前提：网表上限 8、用例链长 4 |
| 7 | `y1/tools/run_chain_ab.sh:662` | 越限负对照 `+CHAINLEN=6 → **9**` | 6 已不再越 8 的界；9 = L_MAX+1 |
| 8 | `y1/tools/run_fuse_ab.sh:503` | `EXP_CLR … LMAX=4 → **8**` | 自报行里的一格常数 |
| 9 | `y1/pds/devmap_c3.tcl`（注释 4 处） | `L_MAX=4 → 8` | 探针标签 |

`LayerSched` 把 `L_MAX` **显式**传给 `UnitExec`（`LayerSched.scala:271`）⇒ 两处不会漂开。
**权重装载口仍是冻结的 4 套**（`we/we_t/we2/we3`）：`L_MAX>4` 时切片 4..7 **共用**第 4 套
（面积上装载口数与切片数无关；"每链位一套独立装载口"列为 C4/M2 开口项，已在 `UnitExec.scala` 文件头写明）。

### 10.2 生成的网表（`L=8`）与确定性

| 产物 | md5 | 规模 |
|---|---|---|
| `y1/gen/LayerSched.v`（`C=8,WIDTH=32,IMG_H_MAX=16,L_MAX=8`） | `d2d62877a85a28e22874a506432da2b2` | `Conv3x3Slice ×8` / `FusionBuf ×9` / `WeightStore ×8` |
| `y1/gen/NpuTop.v`（含上述 `LayerSched`） | `12d5f2c93326d3d41c8d3976d7e4227e` | — |
| `y1/gen/UnitExec.v`（`W=64,H=4,L=8`） | `656b1d86000cdadf90392df45b8fdfc9` | `Conv3x3Slice ×8` / `FusionBuf ×9` |
| `y1/gen/UnitExec_w32.v`（`W=32,H=8,L=8`） | `756dc74d80bc2df69d752a00cbcb4fdf` | `Conv3x3Slice ×8` / `FusionBuf ×9` / `arr_p>>>6 ×8`（单份定义） |

**确定性**：同一套旋钮连生成两次，四个 md5 **逐字节相同**（`headerWithDate=false` /
`headerWithRepoHash=false` 保持）。
**例化计数**：`Conv3x3Slice = L_MAX`、`FusionBuf = L_MAX+1`（链闸门 §7 断言的就是这两条，已随前提更新为 8/9）。
**`arr_p >>> 3'd6` 仍恰好 8 处**：`oneFilePerComponent=false` 下 `Conv3x3Slice` 只有 1 份**定义**
⇒ `run_unitexec_ab.sh` 的 shift 突变锚（期望 8 处命中）与 `run_fuse_head_ab.sh` 的 `midWrEn` 锚
（恰好 1 处）**一字未动**、逐字仍命中。

### 10.3 资源表：`L=4` vs `L=8`（`LayerSched` **单独** `dev_map`）

**装置**：`YESHENMINI_C3_MODE=layersched … pds_shell -file y1/pds/devmap_c3.tcl`
（只 `add_design y1/gen/LayerSched.v`，无板级约束；流程 `create_project → add_design → compile
-verilog_standard SystemVerilog → synthesize -ads → dev_map`；器件行与 §0 一字不差）。
**数字来源（M0 教训）**：裸探针**没有板级顶层** ⇒ 549 个顶层端口全被当 IO pad > FBB676 的 400
⇒ `dev_map` 以 `DeviceMap-2003` + `E: DRC-0018`（**IO**）中止 ⇒ **不打印** `Device Utilization Summary`
⇒ 两档都取 **`Mapping Summary` + `Cell Usage`（`GTP_*`）**，来源如实标注。两次 `L` 的 IO **都是 549/400**
（`L_MAX` 不改端口 ⇒ 端口数不变，符合预期）。两档日志的收尾**一致**：
`DRC-0018 = 1 / DeviceMap-2003 = 1 / Program Error = 1 / Adm-4088 = 0`，末行 `W: Failed to execute the script`
（中止发生在 `dev_map` 里 ⇒ **无** `Y1_C3_LAYERSCHED_DEVMAP_DONE`；`exit = 1`）——**这是裸探针的形状产物，与 DRM 无关**（§1.3 同款）。

| 资源 | **`L=4`**（实测） | **`L=8`**（实测） | Δ | 器件可用 | `L=8` 占器件 |
|---|---|---|---|---|---|
| **LUT** | 33,979（21.26%） | **58,788（36.79%）** | **+24,809** | 159,800 | **36.8%**（余 101,012） |
| **FF** | 48,143（15.06%） | **68,203（21.34%）** | **+20,060** | 319,600 | **21.3%**（余 251,397） |
| **APM** | 163.00（22.03%） | **323.00（43.65%）** | **+160** | 740 | **43.7%**（余 417） |
| **DRM** | 4.0（0.96%） | **8.0（1.93%）** | **+4.0** | 415 | **1.9%**（余 407） |
| **Dist.RAM**（`LUTs as dram`） | 1,536（3.89%） | **1,536（3.89%）** | **+0** | 39,500 | 3.9% |
| IO | 549 / 400 | 549 / 400 | +0 | 400 | **137%（刻意超，见上）** |

**逐字读数**（`y1/pds/devmap_c3_layersched.log`，`Mapping Summary` 段）：

```text
Total LUTs: 58788 of 159800 (36.79%)
	LUTs as dram: 1536 of 39500 (3.89%)
	LUTs as logic: 57252
Total Registers: 68203 of 319600 (21.34%)
DRM36K/FIFO:
Total DRMs = 8.0 of 415 (1.93%)
APM:
Total APMs = 323.00 of 740 (43.65%)
Total I/O ports = 549 of 400 (137.25%)
```

`Cell Usage`（同 log）交叉印证：`GTP_DRM36K_E1 8 uses`、`GTP_APM_E2 323 uses`、
`GTP_DFF_C 45 + GTP_DFF_CE 68136 + GTP_DFF_PE 22`（≈ 68,203 FF）。`L=4` 的对应行保存在
`y1/pds/devmap_c3_layersched_lmax4.log`（33,979 / 48,143 / 163 / 4.0 / 1,536）。

**两条可对账的"线性"关系**（说明 `L=8` 是"再多 4 片"，没有隐藏超线性）：

| | 每片边际 | 固定开销（FSM + `DescFetch` + `BypassExec` 四单元 + `DdrMaster` + `bufs(0)`） | 校验 |
|---|---|---|---|
| LUT | **≈ 6,202** | ≈ 9,170 | 9,170 + 8×6,202 = 58,786 ≈ **58,788** ✔ |
| FF | **≈ 5,015** | ≈ 28,083 | 28,083 + 8×5,015 = 68,203 = **68,203** ✔ |
| APM | **40.0**（与 `g1_area.md` 的"40 APM/片"同值） | ≈ 3 | 3 + 8×40 = **323** ✔ |
| DRM | **1.0** | 0 | 4.0 → 8.0 ✔ |

### 10.4 **判定：`L=8` 装得下**（余量宽裕）

| 资源 | `L=8` 占器件 | 余量 | 判定 |
|---|---|---|---|
| LUT | 36.8% | **63.2%**（余 101,012） | **FITS** |
| FF | 21.3% | **78.7%**（余 251,397） | **FITS** |
| APM | 43.7% | **56.3%**（余 417） | **FITS**（最紧的一项，仍有 2.3× 余量） |
| DRM | 1.9% | **98.1%**（余 407） | **FITS** |

**加到 SoC 上也装得下**：SoC-only 控制臂（`devmap_soc_ctrl.log`）= `LUT 14,226 / FF 17,110 /
APM 4 / DRM 24.5 / DistRAM 231`。**算术和**（SoC-only + `LayerSched(L=8)` 单独综合）：

| | LUT | FF | APM | DRM | DistRAM |
|---|---|---|---|---|---|
| SoC-only | 14,226 | 17,110 | 4 | 24.5 | 231 |
| `LayerSched(L=8)` | 58,788 | 68,203 | 323 | 8.0 | 1,536 |
| **和** | **73,014（45.7%）** | **85,313（26.7%）** | **327（44.2%）** | **32.5（7.8%）** | 1,767（4.5%） |

**板级实测（含 `L=8` 的 `NpuTop`）**：`y1/pds/devmap_c3_lmax8.log`（同一 tcl / 器件行 / `exit 0` /
**0** `DRC-0018` / **0** `DeviceMap-2003` / 完成标记 `Y1_C3_INTEGRATED_DEVMAP_DONE`）：

| 口径 | 日志 | LUT | FF | APM | DRM | Dist.RAM |
|---|---|---|---|---|---|---|
| SoC-only 控制臂 | `devmap_soc_ctrl.log` | 14,226 | 17,110 | 4 | 24.5 | 231 |
| 集成 C3（`L_MAX=4`，C3.14 修地址后） | `devmap_c3.log` | 22,183.5 | 28,522 | 17 | 24.5 | 743 |
| **集成 C3（`L_MAX=8`，本步）** | `devmap_c3_lmax8.log` | **22,830.5** | **28,842** | **17** | **24.5** | **743** |
| **Δ（`L=8` − `L=4`，板级）** | — | **+647** | **+320** | **+0** | **+0** | **+0** |

> **为什么板级 Δ 只有 +647 LUT / +320 FF**：板级 `NpuTop` 把**四个权重装载口全部钉死为常量 0**（冻结
> 口径）⇒ conv 数据通路被**常量折叠**，多出来的 4 片基本被折掉；而**独立探针的权重口是自由输入**
> ⇒ 折叠不了 ⇒ **只有独立探针（§10.3）能代表"权重可装载的 NPU 数据通路"**。这与 C3.13 的教训同款
> （板级面积 ≠ 数据通路面积）。**器件结论以独立探针为准：`L=8` LUT 36.8% / APM 43.7% / DRM 1.9%。**
>
> **★ C3.16 更正（2026-10-09）**：上面这个 blockquote 的**根因**（"权重口钉 0 ⇒ 常量折叠"）已被
> C3.16 的**寄存器信箱**消除 ⇒ 板级 conv 通路**不再折叠**，板级 Δ 升到 **+58,155.5 LUT**
> （≈ 独立 `LayerSched(L=8)` 的足迹）。**权威读数改看 §11**；本节保留当时的推理与投影。

### 10.5 **提交的默认值 = `L_MAX = 8`**（判据："装得下有宽裕 ⇒ 选覆盖 33/33 的那档"）

判据满足（四样资源余量分别 63% / 79% / 56% / 98%，最紧的 APM 仍有 2.3× 余量）⇒ 按用户判据
**把默认值取到 `L_MAX = 8`**（它把融合边覆盖从 31/33 提到 **33/33**）。

**流量 / fps 影响**（`c3_scheduler.md` §5 同口径，conv-only 下界 + 旁路 `6,945,600 B`）：

| 默认值 | 覆盖边 | conv-only B/帧 | 含旁路 B/帧 | fps 上界 @275.9 MB/s |
|---|---|---|---|---|
| `L_MAX=4`（旧默认） | 31/33 | 14,265,600 | 21,211,200 | ≈ 13.01 |
| **`L_MAX=8`（新默认）** | **33/33** | **12,576,000** | **19,521,600** | **≈ 14.13** |

⇒ 新默认**省 1,689,600 B/帧（−8.0%）**、fps 上界 **13.01 → 14.13（+8.6%）**；
两个拆点（`Conv_10→Conv_12` = 819,200 B、`Conv_34→Conv_36` = 25,600 B）**消失**。

### 10.6 回归（6 道闸门，`L=8` 网表）

| 闸门 | exit | 判据变化 |
|---|---|---|
| `run_sched_ab.sh` | **0** | 无（`LayerSched` 端口/行为未变；表内链长 2 ⇒ 与 `L_MAX` 无关） |
| `run_chain_ab.sh` | **0** | ★ 前提更新（§10.1 #6/#7）：`LMAX→8`、新增 `CHAIN_N=4`、越限 `6→9`、实例计数 8/9 |
| `run_fuse_ab.sh` | **0** | ★ 前提更新（§10.1 #8）：自报行 `LMAX=4→8` |
| `run_unitexec_ab.sh` | **0** | 无（`arr_p>>>6` 锚仍 8 处、`shift` 突变仍精确命中） |
| `run_fuse_head_ab.sh` | **0** | 无（`midWrEn` 锚仍恰好 1 处命中） |
| `run_nputop_sched_ab.sh` | **0** | 无 |
| `run_nputop_ab.sh` | **0** | 无 |

**两处被显式更新的"网表形状前提"**（都是**常数移动**、不是放宽判据）：`run_chain_ab.sh` 的
(a) 实例计数 `Conv3x3Slice = L_MAX` / `FusionBuf = L_MAX+1`、越限负对照的越限值；
(b) `run_fuse_ab.sh` 的自报 `LMAX`。负对照的**强度不变**（链长越限仍由 RTL `err + 零搬运` 抓，
实例计数仍由逐字 grep 抓）。**没有**任何判据被弱化，也**没有**"不是常数移动"的破裂。

### 10.7 复现

```bash
cd /d/code/PDS/VexiiYeshenLinux
# 生成（L=8；连跑两次 md5 不变）
cd y1 && printf 'Test/runMain UnitExecGen D:/code/PDS/VexiiYeshenLinux/y1/gen\nTest/runMain LayerSchedGen D:/code/PDS/VexiiYeshenLinux/y1/gen\nTest/runMain NpuTopGen D:/code/PDS/VexiiYeshenLinux/y1/gen\nexit\n' | bash sbt.sh
# 独立探针（L=8；裸探针 IO 超限属预期，取 Mapping Summary）
YESHENMINI_C3_MODE=layersched /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_c3.tcl > y1/pds/devmap_c3_layersched.log 2>&1
# 板级集成（L=8，exit 0）
YESHENMINI_DEVMAP_PERIOD=10.000 /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_c3.tcl > y1/pds/devmap_c3_lmax8.log 2>&1
# 取数
grep -nE "Mapping Summary" -A 14 y1/pds/devmap_c3_layersched.log
grep -nE "Device Utilization Summary" -A 10 y1/pds/devmap_c3_lmax8.log
```

### 10.8 本节的**残留**（如实）

1. **无时序 / 无 PnR** —— `dev_map` 只到映射；`L=8` 在 100 MHz 能否收敛**未知**（APM 43.7% 是
   APM 资源的占用，不直接等于时序压力，但"多 4 片"确实让 `UnitExec` 的 fan-out/布线变大）。
2. ~~**权重装载口仍只有 4 套** —— `L_MAX>4` 时切片 4..7 共用第 4 套 ⇒ **`L=8` 的链"每片一份独立权重"
   这条还不能由硬件表达**（面积上不影响本表；列为 C4/M2 开口项）。~~
   → **★ C3.16 已关闭**：装载口改成**一套寄存器信箱**（`wgt_sel/wgt_addr/wgt_data/wgt_we`），
   `UnitExec` 对每个切片做 `sel===i` 比较 ⇒ **`L_MAX=8` 片各自独立可写**（数值证据见
   `c3_scheduler.md` §8.3 的 W2 作业 + 负对照 D；见 §11）。
3. ~~**板级面积不可用作数据通路面积**（权重口钉 0 ⇒ 常量折叠）—— 同上，以独立探针为准。~~
   → **★ C3.16 已关闭**：权重可装载后板级 conv 通路**不再折叠**，板级 Δ 升到 +58,155.5 LUT
   （≈ 独立探针足迹）⇒ **板级面积现在与独立探针同量级**（见 §11）。

---

## 11) ★ C3.16：**寄存器信箱权重通路** ⇒ 板级面积更正（`L_MAX=8`）

**一句话**：把"NPU 对外没有权重口 ⇒ `NpuTop` 把四个装载口全钉 0 ⇐ 由此产生的**板级常量折叠**"
这条 **C3.13 起挂着的开口项** 关掉：新增 **寄存器信箱**（`HostRegs` 的 `WGT_SEL/WGT_ADDR/WGT_DATA/
WGT_WE`，经同一条 AxiLite 寄存器窗逐字节装载），`LayerSched` 引出一套信箱口、`UnitExec` 把它
**扇出**到全部 `L_MAX` 个切片（每片 `we = wgt_we && (sel===i)`）。**对外端口集不变** ⇒ `YeshenSocGlue`
/ 板级 / 地址台账**零改动**。契约与数值证据见 `c3_scheduler.md` §8。

### 11.1 信箱契约（口径要点）

| 偏移 | 名字 | 类型 | 语义 |
|---|---|---|---|
| `0x3C` | `WGT_SEL` | RW（整 32 位存储） | 目标切片下标（`0..L_MAX-1`=`0..7`） |
| `0x40` | `WGT_ADDR` | RW（整 32 位存储） | 切片内条目下标（`0..NENTRY-1`，dense = 576） |
| `0x44` | `WGT_DATA` | RW（整 32 位存储） | 载荷 = **低 8 位**（int8） |
| `0x48` | `WGT_WE` | **WO，自清单拍** | 写 1 起效、下一拍自落 0；回读恒 0 |

* **一次一个 int8**（`WeightStore` 装载口 = `SInt(8)` 冻结口径）；**必须在 `CTRL.start` 之前**做完（带外预载）。
* **扇出在 `UnitExec`**：`wgt_addr/wgt_data` 广播到每片，`we` 带 `sel===i` 比较 ⇒ **最多一片被写**、
  **`L_MAX` 片各自独立可写**（旧的"A-3 四套口在 `L_MAX>4` 时切片 4..7 alias 第 4 套"已删除）。

### 11.2 Verification A —— 顶层**数值**证据（`run_nputop_sched_ab.sh`，exit 0）

| 作业 | 判据（逐字） |
|---|---|
| 作业 1（**免费负对照**） | 3 条目表、**不写信箱** ⇒ `MISMATCH=0`，`DST0/DST1 = 零张量`（区分"通路存在但没写"与"通路不存在"） |
| W1 正（切片 0，576 B） | `MISMATCH=0`，`WGT_LOADED slices=1 entries=576 bytes=576`，`MEM rd=4192 wr=2560` |
| **W1 负 C**（权重错 1 字节） | vs 正确黄金 `MISMATCH=229`（**>0**）；vs 扰动权重黄金 `MISMATCH=0`（**输出跟权重走**） |
| W2 正（8 片链） | `MISMATCH=0`，`WGT_LOADED slices=8 entries=576 bytes=4608`，`MEM rd=2336 wr=2048` |
| **W2 负 D**（别名折叠 ×4 + 全零） | `ID=2042 / W4=1838 / W5=1922 / W6=1995 / W7=1984`（**全 >0**）⇒ 8 片独立可写 |

### 11.3 **板级 / 独立探针面积**（更正后的权威读数）

**装置**：`YESHENMINI_C3_MODE={integrated,nputop,layersched} … pds_shell -file y1/pds/devmap_c3.tcl`
（同 §0 的器件行；日志 `devmap_c3_after_wgt*.log`，同名 `.exit` 记退出码）。

| 口径 | 日志 | exit | LUT | FF | APM | DRM | Dist.RAM |
|---|---|---|---|---|---|---|---|
| SoC-only 控制臂（无 NPU） | `devmap_soc_ctrl.log` | 0 | 14,226 | 17,110 | 4 | 24.5 | 231 |
| 板级 **修地址后 + 权重口钉 0**（C3.15，`L=8`） | `devmap_c3_lmax8.log` | 0 | **22,830.5** | 28,842 | 17 | 24.5 | 743 |
| **板级 + 权重信箱**（★ C3.16，`L=8`） | `devmap_c3_after_wgt.log` | **0** | **72,381.5** | **105,282** | **465** | **32.5** | **1,767** |
| 独立 `NpuTop`（C3.13，无信箱） | `devmap_c3_nputop.log` | 0 | 7,639 | 11,373 | 13 | 0 | 512 |
| 独立 `NpuTop`（★ + 信箱） | `devmap_c3_after_wgt_nputop.log` | **0** | **61,474** | **88,134** | **333** | **8.0** | **1,536** |
| 独立 `LayerSched(L=8)`（C3.15） | `devmap_c3_layersched.log` | 1（IO DRC） | 58,788 | 68,203 | 323 | 8.0 | 1,536 |
| 独立 `LayerSched(L=8)`（★ + 信箱） | `devmap_c3_after_wgt_layersched.log` | **1**（IO DRC） | **60,704** | **86,635** | 323 | 8.0 | 1,536 |

**数字来源（M0 教训）**：板级 / 独立 `NpuTop` 两次都**打印了** `Device Utilization Summary`（`DRC-0018 = 0`、
`DeviceMap-2003 = 0`）；两个裸 `LayerSched` 探针**仍因顶层端口当 IO pad 超 400 而中止**
（`DeviceMap-2003` / `E: DRC-0018` / `Program Error Out` / `W: Failed to execute the script`）⇒
**取 `Mapping Summary` + `Cell Usage`（`GTP_*`）；这是裸探针的形状产物，与 DRM 无关**（同 §1.3）。

| 口径 | 日志 | Δ vs SoC-only（LUT） |
|---|---|---|
| 板级 **权重口钉 0**（C3.15） | `devmap_c3_lmax8.log` | **+8,604.5** |
| 板级 **+ 权重信箱**（C3.16） | `devmap_c3_after_wgt.log` | **+58,155.5**（≈ 独立 `LayerSched(L=8)` 的 58,788/60,704 足迹） |

⇒ **实测板级总量（`Device Utilization Summary`）**：

```text
| APM               | 465     | 740     | 63
| FF                | 105282  | 319600  | 33
| LUT               | 72381.5 | 159800  | 46
| Distributed RAM   | 1767    | 39500   | 5
| DRM               | 32.5    | 415     | 8
| IO                | 99      | 400     | 25
```

`Mapping Summary`（同 log）交叉印证：`Total LUTs: 72383 of 159800 (45.30%)` /
`Total Registers: 105295` / `Total DRMs = 32.5` / `Total APMs = 465.00`。
**`DRM 32.5 ≤ 415`、`Adm-4088 = 0`、exit 0、完成标记 `YESHENMINI_C3_DEVMAP_DONE`** ⇒ **装得下**。

### 11.4 **常量折叠消失**的证据（点名的三条 + conv 累加器）

`grep -c "stuck at constant 0"`（板级 `devmap_c3_lmax8.log`【权重口钉 0】→ `devmap_c3_after_wgt.log`【信箱】）：

| 点名信号 / 信号集 | 钉 0（C3.15） | ★ 信箱（C3.16） |
|---|---|---|
| `…/hostRegs_1/start_r` | 0 | **0** |
| `…/layerSched_1/state_reg` | 0 | **0** |
| `…/ddrMaster_4/state_reg` | 0 | **0** |
| **`…/unitExec_1/conv/arr/arr/acc*`（**conv 累加器**，判"卷积通路留没留住"的点名集）** | **26** | **0** |
| 全 log 的 `stuck at constant 0` 总条数 | 38,796 | **1,724** |

⇒ **判据成立**：补上权重通路后，`UnitExec` 的 **conv 累加器一条都不再被折成常量 0**（26 → **0**），
log 里的"stuck at 0"总量降到 **1/22**（剩下的 1,724 条是 FSM 空闲态、未用字段等**真常量**的局部去冗余，
不是"整条数据通路被剪"）。**独立 `NpuTop` 探针同向**：`conv/arr/arr/acc*` 的 stuck **26 → 0**。

### 11.5 缺口清单的口径变更（本档）

| 缺口 | C3.13/C3.15 的写法 | ★ C3.16 的写法 |
|---|---|---|
| 权重通路 | "**没有权重装载通路**"（`NpuTop` 把权重口钉 0）⇒ 顶层只能跑零张量 | "**寄存器信箱权重装载已加**（4 档 + `sel===i` 扇出，`L_MAX` 片各自独立可写）"；**残留**：**"权重从 DDR 搬"（描述符无权重指针，需转换器 + DMA）仍是 C4/M2** |
| 板级面积可用性 | "权重口钉 0 ⇒ 常量折叠 ⇒ **板级面积不能当数据通路面积用**" | **已关闭**：板级不再折叠（§11.4），板级 Δ **+58,155.5 LUT ≈ 独立探针足迹** |
| `L=8` 每片独立权重 | "4 套口 ⇒ 切片 4..7 共用第 4 套 ⇒ 硬件表达不了" | **已关闭**：信箱逐片选（W2 负对照 D 五档全发火，§11.2） |

### 11.6 复现

```bash
cd /d/code/PDS/VexiiYeshenLinux/y1
bash tools/run_nputop_sched_ab.sh            # W1/W2 权重数值 + 两个负对照 ⇒ RESULT: PASS (exit 0)
bash tools/run_hostregs_ab.sh                # 19 格穷举 + WGT_WE 自清单拍 ⇒ RESULT: PASS (exit 0)
# 板级 / 两个独立探针（同 §0 器件行；裸探针 IO 超限属预期，取 Mapping Summary）
YESHENMINI_C3_MODE=integrated /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file y1/pds/devmap_c3.tcl > y1/pds/devmap_c3_after_wgt.log 2>&1
YESHENMINI_C3_MODE=nputop     /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file y1/pds/devmap_c3.tcl > y1/pds/devmap_c3_after_wgt_nputop.log 2>&1
YESHENMINI_C3_MODE=layersched /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file y1/pds/devmap_c3.tcl > y1/pds/devmap_c3_after_wgt_layersched.log 2>&1
# 取数
grep -A12 "Device Utilization Summary" y1/pds/devmap_c3_after_wgt.log
grep -nE "Mapping Summary" -A14 y1/pds/devmap_c3_after_wgt_layersched.log
grep -cE "stuck at constant 0" y1/pds/devmap_c3_lmax8.log y1/pds/devmap_c3_after_wgt.log
```

**网表指纹（★ C3.16 重生成；连跑两次 `md5sum` 一致）**：

| 网表 | md5 | 相对 C3.15 的 Δ |
|---|---|---|
| `y1/gen/HostRegs.v` | `040716cd44ca5b47e5c55ff8a040f83d` | 已变（+`WGT_SEL/WGT_ADDR/WGT_DATA/WGT_WE`；表 15 → 19 格） |
| `y1/gen/UnitExec.v` | `87c1991dc0a0789fa062a80354b935c3` | 已变（4 套装载口 → 信箱扇出） |
| `y1/gen/UnitExec_w32.v` | `ba4b46898bdf11ce9227000b28836ef5` | 已变（同上） |
| `y1/gen/LayerSched.v` | `a39d640761826187fb75fe0255c04eb5` | 已变（同上） |
| `y1/gen/NpuTop.v` | `c9c801b0b488600c804c59a1590443e1` | 已变（信箱接线；**对外端口集不变**） |
| `rtl/YeshenSocGlue.v` | `72bec1f30d2c507669028e2470df492a` | **零改动**（C3.16 不碰胶合） |

**残留（如实）**：本档**只**做了"权重可装载 + 板级不再折叠"；**无时序 / 无 PnR / 无上板**不变；
**"权重从 DDR 搬"（转换器 + DMA，或给描述符补权重指针）仍是 C4/M2**。板级 `DRM` 从 24.5 → **32.5**
（NPU 缓冲不再被折掉后显形），仍 ≪ 415。板级 `FF` 105,282 比"算术和（SoC 17,110 + `LayerSched`
68,203 = 85,313）"高约 20k：这是**真做映射**（`Device Utilization Summary`）与"C3.13 的算术投影"
的差 —— **以实测为准**（投影不再使用）。
