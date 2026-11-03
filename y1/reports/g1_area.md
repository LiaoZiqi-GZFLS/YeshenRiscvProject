# Y1 G1 面积闸门报告 —— 卷积切片（640 宽行缓冲）dev_map

**判定：`G1 PASS`**

- 度量对象：`y1/rtl/Conv3x3Slice.scala` 生成的 **GROUP=1** 网表（权重存储最大档，576 项，最坏情形），
  行缓冲 **WIDTH=640**（真实宽度；16 宽会低估行缓冲面积）。
- 度量方式：PDS 2025.2 `dev_map`（synthesis + device mapping，**无板级引脚/时钟约束**，**未跑 PnR**）。
- 器件：`PG2L200H / FBB676 / -6`（与 SoC 基线同一行，见下）。
- 逻辑日期：2026-10-08。

---

## 1) 被测网表指纹

| 项 | 值 |
|---|---|
| 文件 | `y1/gen/Conv3x3Slice.v`（gitignored） |
| md5 | `e54fc5232644745ad113c1d80e879f16` |
| 行数 | `51879` |
| 字节 | `1723446` |
| WIDTH / GROUP | `640 / 1` |
| 顶层模块 | `Conv3x3Slice`（PDS 自动识别：`I: Top module is unspecified` → `I: Module "Conv3x3Slice" is set as top module`，日志 49–50 行） |
| 生成命令 | `cd y1 && printf 'Test/runMain SliceGen D:/code/PDS/VexiiYeshenLinux/y1/gen 640\nexit\n' \| bash sbt.sh` |
| header 口径 | `headerWithDate=false` + `headerWithRepoHash=false`（网表头只有 SpinalHDL 版本，无日期/无 repo hash，指纹可复现） |

---

## 2) 切片四项头号数字（逐字取自日志 `Device Utilization Summary`）

| 资源 | Used | Available | Utilization(%) |
|---|---|---|---|
| LUT | `26447` | `159800` | `17` |
| FF | `87409` | `319600` | `28` |
| APM | `40` | `740` | `6` |
| DRM | `0` | `415` | `0` |

（同段还有 `Distributed RAM 0 / 39500 / 0`、`IO 156 / 400 / 39`、`USCM 1 / 32 / 4`、
`CCS 1 / 1 / 100`，与本闸门无关，仅备查。）

**关键观察：DRM = 0。** 640 宽的行缓冲没有被推断成 BRAM（`GTP_DRM36K` 在 Cell Usage 里根本不出现），
而是落成了寄存器组（FF 87409 / `GTP_DFF_CE 87407`）。所以切片的 BRAM 压力为 0。

---

## 3) 数字来源（明确声明）

**来源 = `Device Utilization Summary`**（日志 597–627 行）。`dev_map` **正常收尾**，
打印了该段（本工程资源未超限，未触发 `DRC-0018` / `DeviceMap-2003` / `Program Error`），
故**无需**退回 `Mapping Summary` + `GTP_*` 行。

两处独立口径**互相印证**，因此上述数字可靠：

- `Mapping Summary`（日志 233–244 行）：`Total LUTs: 26447`、`Total Registers: 87409`、
  `Total DRMs = 0.0`、`Total APMs = 40.00` —— 与 Device Utilization Summary 完全一致。
- `Cell Usage`（日志 214 行起）：`GTP_APM_E2 40 uses`，且**无** `GTP_DRM36K_*` 行（DRM 0）。

> 说明：上一轮第三方加速器探针（`ai_npu_exp`）正是因资源超限被 `DRC-0018` 中止、
> **没有**打印 `Device Utilization Summary`，只能取 `Mapping Summary`。**本次没有复现那种情况**，
> 因此本报告直接采用 `Device Utilization Summary`，并用另两处口径交叉验证。

---

## 4) G1 闸门逐项判定（切片自身）

| 资源 | 阈值 | 实测 | 余量 | 判定 |
|---|---|---|---|---|
| LUT | ≤ 30 000 | `26447` | 3553 | **PASS** |
| APM | ≤ 100 | `40` | 60 | **PASS** |
| DRM | ≤ 60 | `0` | 60 | **PASS** |

---

## 5) SoC + 切片 vs 器件上限

SoC 基线取自本仓库自身日志 `sim/reglogs/m_yeshen_devmap.log`（2026-10-07 20:52，
`Device Utilization Summary`，同 log 8509–8513 行，器件同为 PG2L200H）：

- LUT `14130.5` / 159800

- FF `17124` / 319600

- APM `4` / 740

- DRM `23.5` / 415

| 资源 | SoC 基线 | 切片 | 合计 | 器件可用 | 合计 ≤ 器件？ |
|---|---|---|---|---|---|
| LUT | `14130.5` | `26447` | `40577.5` | 159800 | **YES** |
| FF | `17124` | `87409` | `104533` | 319600 | **YES** |
| APM | `4` | `40` | `44` | 740 | **YES** |
| DRM | `23.5` | `0` | `23.5` | 415 | **YES** |

四项全部 `YES`：SoC + 切片对器件上限均有充裕余量（LUT 约 25%，FF 约 33%，APM 约 6%，DRM 约 6%）。

---

## 6) 裁决

```
G1 PASS
```

切片四项均满足 LUT ≤ 30 000、APM ≤ 100、DRM ≤ 60；且 SoC + 切片对器件四项上限全部 `YES`。

---

## 7) 证据等级声明

本结论是**独立切片**的 **synthesis + device mapping** 结果，工程内**没有板级引脚/时钟约束**
（无顶层 `board/yeshen_mini_board_top.v`，故未写 FDC，未造假引脚；IO 156 为无约束占位、不具物理意义）。
它**不是**已布局布线的上板结果，**时序未被评估**（本任务不跑 PnR）。
`Device Utilization Summary` 的资源数字可审计、可复现（网表 md5 见第 1 节），但面积结论**不覆盖**
时序收敛性与板上可用频率。

---

## 8) 原始日志块（可审计，逐字复制）

切片 `Device Utilization Summary`（`y1/pds/devmap_slice.log` 597–627 行）：

```text
Device Utilization Summary:
+-------------------------------------------------------------------------+
| Logic Utilization     | Used      | Available     | Utilization(%)     
+-------------------------------------------------------------------------+
| APM                   | 40        | 740           | 6                  
| FF                    | 87409     | 319600        | 28                 
| LUT                   | 26447     | 159800        | 17                 
| Distributed RAM       | 0         | 39500         | 0                  
| DRM                   | 0         | 415           | 0                  
| IO                    | 156       | 400           | 39                 
| RCKB                  | 0         | 40            | 0                  
| SCANCHAIN             | 0         | 1             | 0                  
| USCM                  | 1         | 32            | 4                  
| CCS                   | 1         | 1             | 100                
| ADC                   | 0         | 1             | 0                  
| DDR_PHY               | 0         | 40            | 0                  
| HSSTLP_LANE           | 0         | 8             | 0                  
| HSSTLP_PLL            | 0         | 4             | 0                  
| GPLL                  | 0         | 10            | 0                  
| PPLL                  | 0         | 10            | 0                  
| DDRPHY_CPD            | 0         | 20            | 0                  
| HCKB                  | 0         | 120           | 0                  
| IOCKB                 | 0         | 40            | 0                  
| MRCKB                 | 0         | 20            | 0                  
| PCIE                  | 0         | 1             | 0                  
| DDRPHY_IOCLK_DIV      | 0         | 10            | 0                  
| ANALOG                | 0         | 1             | 0                  
| TSERDES               | 0         | 80            | 0                  
| KEYRAM                | 0         | 1             | 0                  
| GCLK_INBUF_SYN        | 0         | 40            | 0                  
+-------------------------------------------------------------------------+
```

切片 `Mapping Summary`（同 log 233–246 行，交叉印证）：

```text
Mapping Summary:
Total LUTs: 26447 of 159800 (16.55%)
	LUTs as dram: 0 of 39500 (0.00%)
	LUTs as logic: 26447
Total Registers: 87409 of 319600 (27.35%)
Total Latches: 0

DRM36K/FIFO:
Total DRMs = 0.0 of 415 (0.00%)

APM:
Total APMs = 40.00 of 740 (5.41%)

Total I/O ports = 156 of 400 (39.00%)
```

SoC 基线 `Device Utilization Summary`（`sim/reglogs/m_yeshen_devmap.log` 8505–8535 行，摘录相关行）：

```text
Device Utilization Summary:
+---------------------------------------------------------------------------+
| Logic Utilization     | Used        | Available     | Utilization(%)     
+---------------------------------------------------------------------------+
| APM                   | 4           | 740           | 1                  
| FF                    | 17124       | 319600        | 6                  
| LUT                   | 14130.5     | 159800        | 9                  
| Distributed RAM       | 224         | 39500         | 1                  
| DRM                   | 23.5        | 415           | 6                  
...
```

---

## 9) 两套网表约定 —— 数值判据 WIDTH=16，面积测量 WIDTH=640（**后补**，不改上面的数字）

> 本节是**后补的约定说明**，第 1–8 节的面积数字**一字未改**：它们取自 **WIDTH=640** 那次运行的
> `dev_map` 日志（已提交为证据 `y1/pds/devmap_slice.log`），测量本身不在质疑之列。

**同一份源码、两个宽度 ⇒ 是两份分别生成的网表，不能互相顶替：**

| 用途 | WIDTH | 网表指纹 | 生成命令 |
|---|---|---|---|
| **面积闸门 G1** | **640** | md5 `e54fc5232644745ad113c1d80e879f16`，51,879 行（见第 1 节） | `cd y1 && printf 'Test/runMain SliceGen D:/code/PDS/VexiiYeshenLinux/y1/gen 640\nexit\n' \| bash sbt.sh` |
| **数值判据** | **16** | `gen/Conv3x3Slice.v`（`WIDTH=16`，网表内 `imgW=16'h0010`） | `cd y1 && printf 'Test/runMain SliceGen D:/code/PDS/VexiiYeshenLinux/y1/gen 16\nexit\n' \| bash sbt.sh` |

- 面积数字的**指纹钉在 WIDTH=640**：只有 640 宽的行缓冲才能反映真实宽度下的面积（16 宽会低估行缓冲）。
- 数值判据（`tools/run_numeric_ab.sh`）的定点用例是 **C_in=C_out=8、W=16**，因此它要的网表**必须是 WIDTH=16**。
- 两者是**两套独立生成**的产物：面积测量之后**必须**用 `SliceGen <outDir> 16` 重生成数值网表才能跑判据。

**已加响亮保护（不会再静默复发）：** 切片新增只读常量输出 `imgW`（= 生成该网表时的 `WIDTH`），
`rtl_test/Conv3x3Tb.v` 在 **time 0** 拿 `+IW` 与 `imgW` 对账，不符立即 `$fatal` 报红、指名要按请求宽度
重生成 —— 而不是像以前那样以"大范围 MISMATCH"的形式事后暴露（那既晚又像数值 bug）。
（与既有的 `grp`/`+GROUP` 档位对账同一招。）
