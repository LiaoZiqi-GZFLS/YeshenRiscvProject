# Y1-C3 · 板级 PnR 时序收敛结论 —— **已收敛，可上板**

**日期**: 2026-10-10（收口） / 起于 2026-10-10 01:38（R0）
**脚本**: `y1/pds/pnr_soc_npu.tcl`（板级 SoC + `y1/gen/NpuTop.v`，源清单与 `y1/pds/devmap_c3.tcl` 的 integrated 模式逐行相同；含 `YESHENMINI_PNR_TAG` / `YESHENMINI_SYNTH_MODE` 两个开关）
**约束**: `cpu_clk` 10.000 ns（100 MHz）；器件 PG2L200H-6 FBB676；strategy 3 / gplace_times 4 / saved_outcome 4

---

## 0) 结论（一句话）

**`cpu_clk` 100 MHz 已收敛**（实测 **102.6483 MHz，slack +0.258**），**所有时钟 setup/recovery 零违例**，**`Design Summary : All Constraints Met`**，**比特流已产出**（9,188,552 B）。**可以上板。**

## 1) 最终读数（R4）

`Performance Summary`（慢角）：

| 时钟 | 请求 | 实测 | slack |
|---|---|---|---|
| **`cpu_clk`** | 100.0000 MHz | **102.6483 MHz** | **+0.258** |
| `core_clk`（DDR） | 125 MHz | 147.2104 MHz | +1.207 |
| `rgmii_clk` | 125 MHz | 195.6564 MHz | +2.889 |
| `rst_clk` | 125 MHz | 298.2404 MHz | +4.647 |
| `clk_in` | 27.027 MHz | 199.0446 MHz | +31.976 |

`Setup Summary(Slow)`：**每个时钟 `Failing Endpoints = 0`**（`cpu_clk` 0 / **316,224**）。
`Recovery Summary(Slow)`：**全 0**（`cpu_clk` WNS +3.020）。

四个种子：seed0 **−0.011** / **seed1 +0.234（`UserFilter: 1` ⇒ 时序收敛种子，被选用）** / seed2 / seed3（4/4 均跑完，无布线发散）。

`Device Utilization Summary`（本次出 Summary，无 DRC 中止）：
**LUT 61,530.5 / 159,800（39%）· FF 113,382 / 319,600（36%）· APM 273 / 740（37%）· Distributed RAM 1,767（5%）· DRM 32.5 / 415（8%）· IO 99 / 400**。

**比特流**：`sim/reglogs/pds_pnr_c3_r4_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit`（**9,188,552 B**）。

## 2) 收敛轨迹（逐轮 A/B；每轮只改一处，可归因）

| 轮 | 改动 | cpu_clk | WNS | failing endpoints | bitstream |
|---|---|---|---|---|---|
| R0 | （无改动，基线） | 55.08 MHz | −8.157 | 95,641 | **无**（seed 3 发散） |
| R1 | `NpuTop` 遗留 96 bit 长度派生 → 3 级寄存 | 75.78 MHz | −3.196 | 39,947 | 9,188,552 B |
| R2 | **仅**换综合档 `YESHENMINI_SYNTH_MODE=speed`（`-resource_sharing FALSE -retiming`） | 88.25 MHz | −1.332 | 7,323 | ✓ |
| R3 | 同步复位（全 13 个生成器）/ MacArray 自然宽度 + 两级流水 / `kx·ky` 解码寄存 / `runStart` 广播按片复制 | 95.83 MHz | −0.435 | 686 | ✓ |
| **R4** | `BypassExec` 的喂入长度簿记寄存化（`inBeatsR`/`outPixR` + sticky `inTail` 取代 32 bit 比较器） | **102.65 MHz** | **+0.258** | **0** | ✓ |

归因锚点（对照实验）：
- **R0 的 −8.157 ns 归因 NPU**：2026-10-07 同顶层/同约束/同流程的 **SoC-alone** PnR 曾 **MET（+0.048）并出比特流**。
- **R2 只换了综合档**（RTL 未动）⇒ 那 2 ns 是 `-ads` 的**面积导向**（资源复用 + 无 retiming）造成的，不是 RTL 缺陷。

## 3) 各轮根因与修法（可复现）

- **R1**：`NpuTop` 里 C2 时代"长度由特征图维度派生"的 `IMG_W×IMG_H×C_IN`（96 bit）+ `lenOk` **组合地接在 `DdrMaster` 的 CHK/寄存器使能上**（28 级逻辑 / 11.4 ns）。C3 调度器根本不用这条通路（长度来自描述符）。改为 `whReg → prodReg → lenReg` 三级寄存 ⇒ `DdrMaster` 只看到寄存器。
- **R2**：`synthesize -ads`（面积档）。本机只有 ADS 引擎，无 Synplify；**时序档 = `-ads -resource_sharing FALSE -retiming`**（见 [ADS/PDS 面积优化选项陷阱]）。
- **R3**：
  - **异步复位**：SpinalHDL 默认 `ASYNC`，13 个生成器都没覆盖 ⇒ NPU 成为 SoC 里唯一异步为主的块（14 async / 7 sync；CPU 5/50、glue 0/14）⇒ **88,571 负载的异步复位网** + **9,947 个 recovery 违例**。修法：全生成器 `defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC)`（**API 已对 1.15.0 jar 核对**；是 `SYNC` 不是 `ResetKind.SYNC`）。**合法性**：`soc_cpu_reset` 本就是同域同步产物（`glue_rst_sync` 2 级 + glue FF），改成同步**不引入 CDC、不丢板级"异步拉低"性质**。
  - **MacArray**：`prod.reduce(_+_)` 且**先 `.resize(32)` 再求和** ⇒ 8 个串行 32 bit 加法、无流水；占**全 SoC 加法进位单元的 71%（7,552 个 ≈ 1,888 CLMS）**，而器件 **CLMS 89% / CLMA 90%** ⇒ 这就是"普遍慢 ~2 ns"的拥塞源头。修法：乘积保持自然位宽（只在累加处加宽，累加仍 32 bit）+ **两级寄存**（4 个 pair-sum 寄存 → 平衡树 + 累加）；**逐字节相等**（整数结合律、无溢出；参考 `mac_ref.py` 用无界整数）。**节拍仍 11 拍**（`clr`+requant 挪到阵列空闲拍，`pixelPending` 把关）。
  - **`Conv3x3Slice`**：9 路优先解码 `when(ph===t+1)` 换成**寄存的 `(kx,ky)` 计数器**（每个乘法器输入锥少 2 级 + 少一条 fanout-64 网）。
  - **`UnitExec`**：`runStart` 是对 8 片的**无缓冲广播**（17,617 fanout）⇒ 按片寄存复制。
- **R4**：`bypassExec_1/rz/rb` 的 CE 路径 10 级里有 **8 级在 `BypassExec`**（描述符 mux → APM 乘法 → 32 bit 比较器）。把 `inBeatsR`/`outPixR` 在 `RDSTART` 锁存、用 sticky `inTail` 取代比较器 ⇒ CE 锥 10 → ~3 级，且**证得 `x_valid` 波形逐拍不变**（Resize 的 2W/8W 节拍契约与延迟不动）。

## 4) 判据与证据

- 时序：`All Constraints Met`；`Setup/Recovery Summary` 各时钟 **0 failing**；四种子无发散。
- 比特流：文件存在且大小合理（9,188,552 B）；`YESHENMINI_PNR_C3_DONE` 标记出现。
- 功能：**15 个单元闸门 + 台账 + 结构判据在 R1..R4 每轮都重跑且全绿**；dense/group=4/dw 三档 `MISMATCH=0`；`check_addr_map.py` PASS（16 处）；`check_dangling` PASS。
- 资源：R4 出 `Device Utilization Summary`（无 DRC 中止），LUT 39% / FF 36% / APM 37% / DRM 8%。

## 5) 上板前须知的残留（如实）

1. **`UnitExec` 有同款反模式未改**：`pixTotal = imgH*imgW` 驱动 `pixIdx == pixTotal`，`wrTotal = pixTotal*nImg` 驱动 `ri < wrTotal`。它**不在前 40 条违例里**（优于 −0.264 ns），为保持"每轮只改一处"的可归因性**故意未动** ⇒ 列为 R5 首选（若将来改 RTL 或换器件，它是第一个要看的）。
2. **CLMA 仍 ~91% 满**（R3 后 27,142/30,075）：余量薄，换布局/换种子时**摆放噪声 ±0.4 ns 会左右结果**（本轮 seed0 −0.011 vs seed1 +0.234 即此）。上板前若再改任何 RTL，**必须重跑 PnR**。
3. **时序是"综合档 + 布局"共同结果**：`speed` 综合档（`-resource_sharing FALSE -retiming`）是**必要条件**——R1 的 RTL 在 `ads` 档下只有 75.78 MHz。`pnr_soc_npu.tcl` 默认 `ads`，**复现本结果必须显式 `YESHENMINI_SYNTH_MODE=speed`**。
4. 未做：**没有上板**（烧写/复现由用户决定时机）；未做功耗分析；未做 C5 的 CPU 争用实测。
5. 本轮**未改**任何功能语义：所有修法都要求**逐字节相等**，并由 15 个闸门 + 三档数值判据守。
