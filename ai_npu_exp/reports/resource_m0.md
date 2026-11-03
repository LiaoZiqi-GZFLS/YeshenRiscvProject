# M0-B10：NPU 独立 dev_map 资源报告与「能否与 SoC 共板」余量结论

> **一句话结论：这台第三方 SpinalHDL CNN 加速器（YOLOv5 族 640×640 INT8）的独立网表自己就装不下 PG2L200H —— LUT 需要 232,746 / 器件只有 159,800（145.65%），APM 与 DRM 双双 100% 用满。与现有 RV32 Linux SoC 共享同一颗器件的方案 = NO-GO。**

- **状态**：`dev_map` 这一步**本身失败**（PDS task exit code 1，`E: DRC-0018` 资源不足），因此 **PDS 从未打印 `Device Utilization Summary`**（本日志里该字符串出现 0 次）。
  但本报告的每一个资源数字都取自**同一次运行**产生的日志/报告：
  - `synthesize -ads` 阶段打印的 `Mapping Summary`（与 `Npu.snr` 的逐模块表一致），
  - `dev_map` 阶段打印的溢出判据 `C: DeviceMap-2003` / `E: DRC-0018`，
  - 综合阶段的 `apm_drm_hrm_lutram_utilization.log` / `synthesize_resource_utilization.db`。
  LUT（232,746）与 IO（1,176）在 `synthesize` 与 `dev_map` 两处**逐字一致**，互相印证。

---

## 0. 运行口径（可复现）

| 项 | 值 |
|---|---|
| 命令 | `/c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file "D:/code/PDS/VexiiYeshenLinux/ai_npu_exp/pds/devmap_npu.tcl" > ai_npu_exp/pds/devmap_npu.log 2>&1` |
| 工作目录 | `D:/code/PDS/VexiiYeshenLinux`（既有脚本依赖） |
| 脚本 | `D:/code/PDS/VexiiYeshenLinux/ai_npu_exp/pds/devmap_npu.tcl`（由 `pds/run_devmap_yeshen.tcl` 改核） |
| 日志 | `D:/code/PDS/VexiiYeshenLinux/ai_npu_exp/pds/devmap_npu.log`（7.5 MB，gitignored） |
| 器件行 | `create_project ... -synthesize_tool 2 -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6` |
| 设计源 | **只有** `ai_npu_exp/gen/Npu.v`（顶层 `Npu`；md5 `fe303ee095a1592285af3c076c919817`）。**无** SoC / DDR3 IP / `board/` 文件 |
| 约束 | **无**（纯资源探针，无板级顶层，未臆造带假引脚的 FDC） |
| 工程目录 | `ai_npu_exp/pds/pds_m0_npu.000/`（与 SoC 的 `sim/reglogs/pds_devmap_p10.000` 隔离） |
| 退出码 / 墙钟 | **exit=1**（PDS 子任务 `Device Map` exit code 1）/ **904 s（15 min 04 s）**：compile→dev_map 共 14m53s，其中 dev_map 自身 2m40s |
| 编译错误 | `compile` 的 `error_info.txt` 为空（0 error）；186 条 `W: Sdm-2008`（`ram_style`/`max_fanout` 属性非法被忽略）+ 少量 `parallel_case` 提示 |

`dev_map` 的完整失败文本（**原文**）：

```
C: DeviceMap-2003: The resource of LUT is overrange in design, The total num is 159800.00, but there are 232746.00 in the design.
E: DRC-0018: The resource of LUT is not enough, please reduce it.
C: DeviceMap-2003: The resource of IO is overrange in design, The total num is 400.00, but there are 1176.00 in the design.
E: DRC-0018: The resource of IO is not enough, please reduce it.
Program Error Out.
Run process "Device Map" failed, exit code: 1.
W: Failed to execute the script :
```

`dev_map` 只报了 **LUT 与 IO** 两项溢出（APM/DRM 未报溢出，是因为它们在映射阶段就已**用满并被钳制**，见 §4/§5）。**IO 的溢出（1176/400）是无引脚约束造成的假阳性**：独立网表没有板级顶层，1176 个端口全被当 I/O 处理。**LUT 的溢出与引脚约束无关**（见 §6）。

---

## 1. NPU 自身的四项头条数字

取自本次运行日志中的 `synthesize -ads` → `Mapping Summary`（`Npu.snr` 的逐模块表首行为 `Npu`，数字完全相同）：

| 资源 | Used | Available | Utilization(%) |
|---|---|---|---|
| LUT | **232,746** | 159,800 | **145.65** |
| FF（Total Registers） | **297,037** | 319,600 | **92.94** |
| APM（Pango 硬乘块） | **740.00** | 740 | **100.00** |
| DRM（块 RAM） | **415.0** | 415 | **100.00** |

辅助项（同一 `Mapping Summary`）：

| 项 | Used | Available | Utilization(%) |
|---|---|---|---|
| LUTs as dram（分布式 RAM） | 8,704 | 39,500 | 22.04 |
| LUTs as logic | 224,042 | — | — |
| Total I/O ports | 1,176 | 400 | 294.00 |
| Total Latches | 0 | — | — |

> **注**：APM = **740.00 / 740 = 100.00%**、DRM = **415.0 / 415 = 100.00%**，两者**恰好等于器件总量**——这是器件上限（饱和），不是巧合。证据：DRM 有 71 条显式的「装不下」告警（§5），且综合的 APM/DRM 最终映射报告的条目数与器件上限一一对应（740 条 APM、415 条 `GTP_DRM36K_E1`）。**即：这两项的「需求」≥ 器件上限，「Used」是被钳制后的数字，真实缺口只会更大。**

---

## 2. SoC 基线（引用本仓自己的日志，非本次运行）

引自 `D:/code/PDS/VexiiYeshenLinux/sim/reglogs/m_yeshen_devmap.log`（2026-10-07 20:52，`Device Utilization Summary:` 第 8505 行起，原样）：

| 资源 | Used | Available | Utilization(%) |
|---|---|---|---|
| APM | 4 | 740 | 1 |
| FF | 17124 | 319600 | 6 |
| LUT | 14130.5 | 159800 | 9 |
| Distributed RAM | 224 | 39500 | 1 |
| DRM | 23.5 | 415 | 6 |
| IO | 99 | 400 | 25 |

---

## 3. SoC + NPU 相加与判据

| 资源 | SoC 基线 | NPU（本次运行） | 相加 | Available | 占器件 |
|---|---|---|---|---|---|
| LUT | 14,130.5 | 232,746 | **246,876.5** | 159,800 | 154.5 % |
| FF | 17,124 | 297,037 | **314,161** | 319,600 | 98.3 % |
| APM | 4 | 740 | **744** | 740 | 100.5 % |
| DRM | 23.5 | 415.0 | **438.5** | 415 | 105.7 % |

**判据行（原样）**：

```
SoC + NPU <= 159800 for LUT: NO  (used 246876.5 / available 159800)
SoC + NPU <= 319600 for FF:  YES (used 314161 / available 319600)
SoC + NPU <= 740 for APM:    NO  (used 744 / available 740)
SoC + NPU <= 415 for DRM:    NO  (used 438.5 / available 415)
```

- **LUT / APM / DRM 三项已判 NO，且 LUT 与 APM/DRM 都**不是「差一点」**：NPU 独立就要 145.65% 的 LUT，APM 与 DRM 独立就已各自 100 % 用满。**
- FF 是**唯一**表面为 YES 的一项（314,161 / 319,600，仅余 5,439 个 FF ≈ 1.7 %），但在 LUT/APM/DRM 已决的情况下无意义。
- **APM 与 DRM 的相加是「乐观下界」**：NPU 的数被钳在 740/415，真实需求更大 ⇒ 真实缺口只会更大。

**⇒ M0 的 go/no-go：加速器与 SoC 共板 = NO-GO。**

---

## 4. DSP 预算分析（1152 个 MAC × 26×9 到底去哪了）

**网表实测**（`grep -cE "\bDSP \w+ \(" ai_npu_exp/gen/Npu.v`）：

- **1152** 个 `DSP`（MAC）实例。其模块体内算术为 `dspSum(26-bit signed) * $signed({1'b0,b}(9-bit))`，即与任务描述一致的**有符号 26×9 乘法**（B7 的行为化替代，6 级流水）。
- **勘误（本任务书与此处实际网表不符）**：现网表里**没有** `Mul` 模块、也没有 `Mul` 例化。小乘法器是 4 个行为模块各 17 个实例：`leakyReluMul`×17、`scaleMul`×17、`concatMul`×17、`addMul`×17（共 68）。综合的乘法器清册（`apm_drm_hrm_lutram_utilization.log`，原样）：

```
-----Multipliers :
                    6 x 10     Multipliers := 1
                    6 x 11     Multipliers := 2
                    10 x 6     Multipliers := 2
                    16 x 15     Multipliers := 16
                    26 x 9     Multipliers := 1152
                    32 x 33     Multipliers := 48
                    48 x 33     Multipliers := 16
```

  乘法器需求合计 **1237**（1152 + 85）。

**APM 实际用量（原样）**：

```
GTP_APM_E2                  740 uses
...
APM:
Total APMs = 740.00 of 740 (100.00%)
```

**结论**：

1. **算术没有被吸收进硬块——器件装不下。** APM 用量 = 740 / 740 = **100.00 %**，即器件上**每一个** APM 都被吃掉，且**一个都不剩给 SoC**（SoC 基线本身要用 4 个）。日志里没有「Not enough APM」告警，只是因为 PDS 直接把放不下的乘法器做在 fabric 里，而不是报错。
2. **乘法器绝不是与 DSP 块一一对应。** 需求 ≥ 1152 个 26×9（另有 85 个其它尺寸），可用 APM 只有 740 ⇒ **至少 412 个（≥ 36 %）的 MAC 乘法器拿不到 APM，落在 LUT/FF fabric 里**。
3. **LUT 因此被抬高了多少——日志无法给出定量数字，我不猜。** 日志不做「按来源归因 LUT」。可确证的只有原材料构成：232,746 个 LUT 里 **191,794 个是 `GTP_LUT6CARRY`**（带进位链的 LUT，即算术），22,727 个 `GTP_LUT6D`，8,704 个是分布式 RAM（见 §5）。即**绝大部分 LUT 是进位链算术**，与「乘法器落 fabric」一致；但我**不能**从这份日志里把「乘法器 fabric」与「其余逻辑」的 LUT 数分开。
4. 附带旁证：APM 最终映射报告里每个 MAC 都映成一个**小尺寸** APM 形态（`X 8(signed) × Y 8(unsigned)`、`XB 24`、`P 32`），即**一个 26×9 MAC ≈ 一个 APM** ⇒ 1152 个 MAC 需要 1152 个 APM，而器件只有 740 个。这正是 LUT 爆炸的算术根因。

---

## 5. BRAM 分析

**（a）`ram_style` 标签在本工具链里完全无效。** 网表里 17 处 `(* ram_style = "block" *)`，但 PDS 逐处告警（同一句 164 次）：

```
W: Sdm-2008: The attribute named ram_style is not legal, then it has no effect, ignore its value.
```

⇒ **这 17 个标签没有起到任何作用**；同理，任务书点名的 **4 个未打标签的存储**（实测：`channelMem [0:31]×128`、`logic_ram [0:31]×128`、`logic_ram [0:4095]×128`（≈512 Kbit）、`logic_ram [0:15]×128`）在本次运行里**与已打标签的兄弟没有任何区别**——PDS 一律靠自己的推断。所以「补标签」在这条工具链上不是有效手段。

**（b）块 RAM 已 100 % 用满并发生溢出**（原样）：

```
GTP_DRM36K_E1               415 uses
...
DRM36K/FIFO:
Total DRMs = 415.0 of 415 (100.00%)
...
	LUTs as dram: 8704 of 39500 (22.04%)
```

**71 条**显式的「块 RAM 装不下，退回 LUT RAM」告警（`grep -c "Adm-4088"` = 71），受影响的正是**每个大存储的最后一 bank**：

```
W: Adm-4088: Not enough DRM resource to implement ram 'conv_0/convCompute_1/loadWeight_1/weightRam_7_2/mem_1', trying to decompose using LUT ram.
...
W: Adm-4088: Not enough DRM resource to implement ram 'shape_1/maxPooling_1/rowMem_7', trying to decompose using LUT ram.
W: Adm-4088: Not enough DRM resource to implement ram 'conv_0/convCompute_1/dataGenerate_1/featureGenerate_1/mem_0_7', trying to decompose using LUT ram.
W: Adm-4088: Not enough DRM resource to implement ram 'shape_1/upSampling_1/channelMem/fifo/logic_ram_0', trying to decompose using LUT ram.
W: Adm-4088: Not enough DRM resource to implement ram 'conv_0/convCompute_1/stride_1/fifo/fifo/logic_ram_14', trying to decompose using LUT ram.
```

（受影响名字覆盖 `weightRam_7_*` / `weightRam_8_*`、`maxPooling_1/rowMem_7`、`fifo/fifo/logic_ram_14`、`waXpmSyncFifo_*/fifo/logic_ram_7`、`dataGenerate/featureGenerate/mem_*_7`、`padding_1/fsm_fifo`、`upSampling_1/channelMem` 与 `dataTemp` —— 因为是**容量**不足，不是某个存储的形状问题。）

**（c）大存储到底进没进块 RAM？——「进了一部分，剩下溢出到分布式 RAM」。**

- 综合的 `Distributed RAM, Block RAM and HRM: Final Mapping Report` 共 **647 行 RAM 记录**：**415 行**落在 `GTP_DRM36K_E1`（且没有一行占用 2 个以上 DRM，即一个 RAM 数组 ≈ 一个 36K 块），另外 **232 行**没有块 RAM 原语（分布式 RAM / HRM）。
- 溢出代价已计入 LUT：**8,704 个 LUT 被当分布式 RAM 用**（`LUTs as dram: 8704 of 39500`），是 232,746 那部分 LUT 的组成部分之一。
- **算术对照**：415 × 36 Kbit ≈ **14.9 Mbit**（1 K=1000）/ **15.3 Mbit**（1 K=1024）的块 RAM 容量。而 B5/B6 记录的存储算式是 ≈4.7 Mbit 权重 + ≈2.25 Mbit 特征 FIFO ≈ **7 Mbit** —— **低于**上述容量，**却仍然 100 % 用满并溢出 71 个数组**。
  ⇒ 两种可能（**日志不能判定是哪种，我不猜**）：(i) 真实工作集比 B5/B6 的算式更大（映射报告里确有 144 个不同的 `weightRam_*` 实例与 647 行 RAM 记录）；(ii) PDS 的块 RAM 打包有浪费（例如窄/小的数组各占满一个 36 Kbit 块）。
  ⇒ **能确证的是**：大存储**只在对得上容量的那部分**进了块 RAM，装不下的那部分落到了分布式 RAM；因此**不能**声称整个权重 + 特征工作集都进了块 RAM。

---

## 6. 证据等级（本结论的效力边界）

**本报告是 `synthesize -ads` + `dev_map`（综合 + 器件映射）阶段的结果，针对的是「独立 NPU 网表」——没有板级顶层、没有任何引脚/时钟/IO 约束。它不是上板结果，也不是 PnR（布局布线）后的结果；本报告完全没有触及时序**（日志里只有 `W: Timing-4087: Port '...' is not constrained, it is treated as combinational output` 这类「未约束」提示，没有 `All Constraints Met`，也没有任何 fmax 结论）。

据此：

- **IO 1176 / 400 = 294 %** 是**假阳性**：独立网表没有引脚可约束，1176 个端口全被当 I/O。将来把 NPU 例化进带板级顶层的设计时，这个数字不适用。**本报告不据此下任何结论。**
- **LUT 232,746 / 159,800**、**FF 297,037**、**APM 740/740**、**DRM 415/415** 与引脚约束**无关**：它们来自逻辑映射与器件映射，`dev_map` 与 `synthesize` 两处对 LUT/IO 的独立计数逐字一致即为佐证。**这三项（LUT/APM/DRM）的溢出是本 M0 的实质结论。**
- 行为化替代（B5 FIFO / B6 / B7 MAC / B8 乘法器 / B9b）在**功能语义**上经过正负对照，但**本报告不评价其面积/时序等价性**：行为化替代可能比原厂 Xilinx IP 显著更贵，这一点本报告无法从日志中分离出来。

---

## 附录 A：原始资源摘录（`ai_npu_exp/pds/devmap_npu.log`，原样，本报告全部数字的来源）

```
Cell Usage:
GTP_APM_E2                  740 uses
GTP_DFF                   276319 uses
GTP_DFF_E                  1054 uses
GTP_DFF_R                 15003 uses
GTP_DFF_RE                 4645 uses
GTP_DFF_S                    14 uses
GTP_DFF_SE                    2 uses
GTP_DRM36K_E1               415 uses
GTP_GRS                       1 use
GTP_INV                      84 uses
GTP_LUT1                     31 uses
GTP_LUT2                    221 uses
GTP_LUT3                    688 uses
GTP_LUT4                    373 uses
GTP_LUT5                   1487 uses
GTP_LUT6                   6721 uses
GTP_LUT6CARRY             191794 uses
GTP_LUT6D                 22727 uses
GTP_MUX2LUT7                157 uses
GTP_MUX2LUT8                 62 uses
GTP_RAM128X1DP              608 uses
GTP_RAM32X2DP                 3 uses
GTP_RAM32X2X4               255 uses
GTP_RAM64X1X4              2280 uses

I/O ports: 1176
GTP_INBUF                 481 uses
GTP_OUTBUF                695 uses

Mapping Summary:
Total LUTs: 232746 of 159800 (145.65%)
	LUTs as dram: 8704 of 39500 (22.04%)
	LUTs as logic: 224042
Total Registers: 297037 of 319600 (92.94%)
Total Latches: 0

DRM36K/FIFO:
Total DRMs = 415.0 of 415 (100.00%)

APM:
Total APMs = 740.00 of 740 (100.00%)

Total I/O ports = 1176 of 400 (294.00%)

W: Public-4059: The design has 232746 LUTs, but only 159800 available in the device.
W: Public-4059: The design has 1176 I/O, but only 400 available in the device.
```

以及 `dev_map` 失败判据（同上日志）：

```
C: DeviceMap-2003: The resource of LUT is overrange in design, The total num is 159800.00, but there are 232746.00 in the design.
E: DRC-0018: The resource of LUT is not enough, please reduce it.
C: DeviceMap-2003: The resource of IO is overrange in design, The total num is 400.00, but there are 1176.00 in the design.
E: DRC-0018: The resource of IO is not enough, please reduce it.
Program Error Out.
Run process "Device Map" failed, exit code: 1.
```

## 附录 B：本次运行的工程内报告（同一次运行产出，可复核）

| 文件（相对 `ai_npu_exp/pds/pds_m0_npu.000/`） | 内容 |
|---|---|
| `prj_tasks/syn_1/synthesize/Npu.snr` | `Device Utilization Summary Of Each Module`（逐模块；`Npu` 行为 §1 数字） |
| `prj_tasks/syn_1/synthesize/apm_drm_hrm_lutram_utilization.log` | APM/DRM 最终映射报告 + 乘法器清册 |
| `prj_tasks/syn_1/synthesize/report_db/synthesize_resource_utilization.db` | 逐实体资源表（XML） |
| `prj_tasks/pnr_1/device_map/run.log` | `dev_map` 阶段日志（§附录 A 的判据原文） |
| `prj_tasks/syn_1/compile/error_info.txt` | 空（0 compile error） |

（工程 DB 为构建产物，按 `ai_npu_exp/.gitignore` 不入库。）
