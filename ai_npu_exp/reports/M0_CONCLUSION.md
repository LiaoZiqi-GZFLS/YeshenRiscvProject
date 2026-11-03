# M0 可行性探针 —— 结论报告

- 日期：2026-10-08
- 工程：VexiiYeshenLinux（盘古676 200K MINI / Pango **PG2L200H-6IFBB676**）
- spec：`docs/superpowers/specs/2026-10-08-ai-accelerator-m0-design.md`
- 计划：`docs/superpowers/plans/2026-10-08-ai-accelerator-m0.md`
- 工程目录：`ai_npu_exp/`

---

## 1. 一句话结论

**对第三方 SpinalHDL CNN 加速器（`third_party/SpinalHDL_CNN_Accelerator`，commit `e9597a9`）的 M0 探针结论：算子覆盖 PASS，但器件资源 NO-GO。**

- **算子覆盖 PASS**（Part A）：YOLOv5 v3.0 架构的图，70 个 Conv **全部 group=1**、激活是 **LeakyRelu 59（α=0.1，与加速器硬编码一致）**，覆盖表中**无"不覆盖"项**。
- **器件资源 NO-GO**（Part B）：按其**作者默认配置** `ConvConfig(8,16,16,…)` 生成的网表，**NPU 单独**就 LUT 145.65%、APM 100%、DRM 100% ⇒ **与现有 RV32 SoC 共用器件不可能**。

**根因**：该设计为 YOLOv5s 类（≈7 GMAC）配了 **1152 个 MAC 乘法器**，而本器件只有 **740 个 APM** ⇒ 至少 412 个溢出到 LUT/FF fabric。这是**吞吐取向**问题，**不是** YuNet 的结论（YuNet 只需 344 M-MAC/帧，是它的约 1/20）。

## 2. Part A —— 算子覆盖（PASS）

**产物**：`reports/coverage_m0.md`、`reports/ops_yolov5s_v3src.txt`、`reports/model_provenance.md`、判据 `tools/check_coverage.py`。

**候选图**：`models/yolov5s_v3src.onnx`（29,840,821 B / sha256 `1cd8e333ad0c1742509116b3ad3dcabb198f91ff4f38ac92bde970b14859930d`），由 **tag v3.0 源码 + `models/yolov5s.yaml` 构建（随机权重）**。

**三条关键判断**：
1. **算子覆盖是图的性质、与权重无关** ⇒ 源码构建即可，无需真权重。
2. **实证推翻一个假设**：ultralytics release 的 `v3.0/yolov5s.pt` **并非**由 tag v3.0 代码产出 —— 该资产里 51 个 `Conv.act` 是 `nn.Hardswish`（导出成 `HardSigmoid`+`Mul`），只有 8 个 `BottleneckCSP` 内部激活是 `LeakyReLU(0.1)`；而 tag v3.0 源码是**全 LeakyReLU**。直接拿该资产核算子会**假阴性**。已留档，资产导出的 `.onnx` 仅作对照件。
3. **70 个 `Identity` + 31 个 `Constant` 是常量去重的 wire，不是算子**（逐节点核过：输入都是 initializer，只被 Conv bias / BN 参数消费）。

**判据可信度（正负对照）**：
| 输入 | 期望 | 实测 |
|---|---|---|
| YuNet（`yunet.onnx`） | FAIL 且点名 grouped-conv | `RESULT: FAIL grouped-conv`，exit 1 ✔ |
| YOLOv5 v3.0 源码图 | PASS | `RESULT: PASS`，exit 0 ✔ |
| 合成含 `Silu` | FAIL | `RESULT: FAIL Silu`，exit 1 ✔ |
| 合成含 `group=64` | FAIL | `RESULT: FAIL grouped-conv`，exit 1 ✔ |

**遗留 open items**（交给后续 M1/M2）：
1. **8 个 `BatchNormalization`** 处在 `Concat → BN → LeakyReLU → Conv1×1` 的块尾，**折不进前/后卷积** ⇒ 判"需主机旁路（需核实 `shape/Add` 的 `AddScale` 能否表达逐通道 affine）"。
2. `Slice 6 / Reshape 3 / Transpose 3` 需主机旁路。
3. `Resize 2` 判覆盖，但报告未给 mode/scale，M1 要核是 nearest。
4. 证据等级：**ONNX 级**（非源码级）；无 ONNX↔PyTorch 数值对齐（无 onnxruntime，`onnx.reference` 在本机崩溃）。

## 3. Part B —— Pango 化与器件资源（NO-GO）

**Pango 化完整度（7 个覆盖文件，全部"整文件覆盖"，只读克隆零改动）**：
`config/Config.scala`(useUram=false)、`wa/xip/memory/xpm/XPM_MEMORY_SDPRAM.scala`、`wa/WaFifo.scala`、`wa/xip/math/DSP.scala`、`wa/xip/math/Mul.scala`、`wa/xip/math/AddSub.scala`、`wa/xip/axi/StreamDataWidthConvert.scala`、`misc/TotalTcl.scala`。

| 指标 | 值 |
|---|---|
| 最终网表 | `gen/Npu.v` md5 **`fe303ee095a1592285af3c076c919817`**（2,055,315 B、**64 个 module**、确定性可复现） |
| Xilinx 原语 | `xpm_memory_sdpram` / `xpm_fifo_sync` / `dsp_macro` / `mult_gen` **全部清零** |
| 悬空实例 | **113 → 0** |
| Xilinx IP tcl | 不再生成（`port/verilog/` 不再出现） |
| 综合 | `sbt compile` + `synthesize -ads` **0 error** |

**`dev_map` 结果（`reports/resource_m0.md`，日志 `pds/devmap_npu.log`）**：

| 资源 | NPU 单独 | 器件可用 | 占比 | SoC 基线 | SoC + NPU |
|---|---|---|---|---|---|
| **LUT** | **232,746** | 159,800 | **145.65 %** ⚠️ | 14,130.5 | **246,876.5 ⇒ NO** |
| FF | 297,037 | 319,600 | 92.94 % | 17,124 | 314,161 ⇒ 勉强 YES |
| **APM(DSP)** | **740.00** | 740 | **100 %** ⚠️ | 4 | 744 ⇒ **NO** |
| **DRM(BRAM)** | **415.0** | 415 | **100 %** ⚠️ | 23.5 | 438.5 ⇒ **NO** |

`E: DRC-0018: The resource of LUT is not enough` → `Program Error Out.`（exit 1，故**没有** `Device Utilization Summary`；上面数字来自 `synthesize -ads` 的 `Mapping Summary` 与 `dev_map` 的 `GTP_APM_E2 740 uses` / `GTP_DRM36K_E1 415 uses`，且两个阶段独立一致）。

**B11（PnR）按 spec §6.1 的预先规则跳过** —— dev_map 已显示无余量，续跑 PnR 无意义。

**四条硬事实（后续必读）**：
1. **PDS 忽略 `ram_style`**（`W: Sdm-2008: The attribute named ram_style is not legal … ignore` ×164）⇒ B5/B6 打的 17 处 `ram_style="block"` **是空操作**；真正有效的是"改成同步读"（让存储器可被 BRAM 推断）。**别再靠这个属性调 Pango 的存储器映射。**
2. **APM 100 % 饱和**：1152 个 MAC 乘法器 vs 740 个 APM ⇒ 至少 **412 个（≥36 %）** 溢出到 LUT/FF；232,746 个 LUT 里 **191,794 个是 `GTP_LUT6CARRY`**（进位链算术）。
3. **DRM 100 % 饱和**且 **71 处** `Not enough DRM resource … decompose using LUT ram`（`LUTs as dram: 8704`）。
4. **IO 1176/400 是假阳性**（独立网表无引脚约束），**不支持任何结论**。

**证据等级**：独立 NPU + **无板级引脚/时钟约束**的 `dev_map`（综合 + 器件映射），**非**布局布线后的上板结果，**不含时序**。
**未验证项**：无功能仿真（延迟契约都是**结构性**证明：数寄存器级数、查位段边界）；`AddSub` 的 7 组配置做了 iverilog 数值对照，`Mul` 的 5 个模块做了 310 向量对照，`DSP`/`sdpram`/`DWC` 只有结构证明。

## 4. 这套工作留下了什么（可复用资产）

| 资产 | 位置 | 价值 |
|---|---|---|
| 参考仓库零改动的**复制 + 整文件覆盖**机制 | `ai_npu_exp/port/apply_pango_port.sh` | 任何第三方 RTL 的改造都能这样安全施加 |
| 可用的 **sbt 构建**（本机 sbt 在 Coursier bin，不在 PATH） | `ai_npu_exp/port/{build.sbt,project/build.properties,sbt.sh}` | 本机跑 SpinalHDL 的完整配方 |
| **确定性生成**配方 | `ai_npu_exp/rtl_gen/GenNpu.scala` | `headerWithDate=false` **且** `headerWithRepoHash=false`（否则头里嵌仓库 HEAD，指纹跨 commit 必变 ⇒ 判据退化成永真） |
| **"例化 ⊆ 定义"结构判据** | `ai_npu_exp/tools/check_dangling.py` | B9 抓出 113 个悬空 BlackBox 才补上；**name-based 判据看不出 componentName 命名的 BlackBox** |
| 无 Xilinx 残留判据（带注释剥离） | `ai_npu_exp/tools/check_no_xilinx.sh` | 带正负对照 |
| per-模块延迟/位段判据 | `check_sdpram_latency.py` / `check_dsp_latency.py` / `check_mul.py` / `check_addsub_latency.py` / `check_dwc_latency.py` | 全部带正负对照 |
| `dev_map` 独立装置 tcl | `ai_npu_exp/pds/devmap_npu.tcl` | 器件串与 PDS 用法已成文 |
| **YuNet 真实算力画像** | `ai_npu_exp/tools/yunet_profile.py` + `reports/yunet_compute_profile.txt` | 344 M-MAC/帧、权重 50.3 KB、激活流量 30.5 MB/帧 —— Y1 的输入 |

## 5. 本次探针的净账

- **拿到的**：① 第三方加速器的**完整可行裁决**（算子覆盖 PASS / 资源 NO-GO）与根因；② 一套**跑得通的 Pango 化 + 判据 + 器件映射**链路（可复用于任何 RTL 的集成）；③ YuNet 的**实测算力画像**；④ 两次**实证推翻假设**（`v3.0/yolov5s.pt` 资产≠源码；PDS 忽略 `ram_style`）。
- **没拿到的**：没有任何上板验证，没有时序，没有功能仿真，**DDR 有效带宽从未实测**。
- **对决策的影响**：把"移植第三方加速器跑 YuNet"这条路**否掉**（且是**便宜地**否掉：探针成本远低于做完 M1–M4 再发现装不下），转而指向**自研小型加速器** —— 见 `docs/superpowers/specs/2026-10-08-yunet-accelerator-small-design.md`。
