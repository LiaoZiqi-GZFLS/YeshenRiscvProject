# AI 加速模块可行性探针（M0）设计

- 日期：2026-10-08
- 工程：VexiiYeshenLinux —— VexiiRiscv **RV32** Linux SoC，盘古676 200K MINI（Pango PG2L200H-6IFBB676）
- 状态：**待用户审阅**
- 前置：本设计是 `superpowers:brainstorming` 的产出；审阅通过后转入 `writing-plans` 出实施计划

---

## 1. 背景

用户在 VexiiYeshenLinux 上「加一个 AI 加速模块，然后跑 YuNet 人脸检测」。经探明，待集成的加速器是第三方 SpinalHDL 项目 `SpinalHDL_CNN_Accelerator`（只读克隆）。在把硬件搬上板之前，必须先回答两个问题：**算力/算子对得上吗**、**这台 200K 器件装得下吗**。M0 就是回答这两个问题的探针，不追求跑通检测。

## 2. 本轮已定的决策

| 决策 | 取值 | 理由 |
|---|---|---|
| 探针终点 | **M0 可行性探针**（不出框、不集成） | 高风险新路径先写小 spec 再动手 |
| M0 内部顺序 | **先算子覆盖核实（主线 B），后 RTL 移植（主线 A）** | 算子不覆盖是便宜的先杀判据，避免先浪费 RTL 移植与 PnR 机时 |
| 候选对照模型 | **YOLOv5 v3.0 的架构**（由 tag v3.0 源码 + `models/yolov5s.yaml` 构建，随机权重） | 算子覆盖是**图的性质、与权重无关**；源码构建保证图与"我们声称同族的那份代码"严格一致。见 §5.1 的资产/源码不符发现 |
| 工程形态 | **新建独立最小工程，RTL 从只读克隆复制来改** | 调试阶梯先最小独立工程；且 `third_party` 克隆必须零改动 |

## 3. 关键事实（已核实，均带出处）

### 3.1 加速器画像（`third_party/SpinalHDL_CNN_Accelerator`，只读克隆）

它是 `liuwei9/spinal_yolo` 的分支 —— **为 YOLO 系（YOLOv5 风格）640×640 INT8 检测器设计**。证据：

1. `src/main/scala/conv/dataGenerate/Focus.scala` + `config/Config.scala` 的 `enFocus` → YOLOv5 的 Focus 首层。
2. `conv/compute/ConvConfig.scala` 的 `ConvType` 只有 `conv33` / `conv11`；`CONV_STATE` 另有 `CONV11_8X`（1×1、8× 通道扩张）。
3. 激活只有 `conv/compute/activation/LeakyRelu.scala`，且 `ConvConfig.leakyRatio = 0.1` **硬编码**。
4. `shape/` 目录 = MaxPooling / Add / Concat / Split / UpSampling → YOLOv5 的 FPN/PAN 颈部。
5. 注释掉的仿真配置（`src/test/scala/TbConv.scala`、`src/test/scala/InstructionGen.scala`）写死 `ConvSimConfig(640, 640, 8, 32, …, CONV_STATE.CONV33, …)`，配套 `.coe` 为 `simData/first/weight_3_8(12).coe`、`feature_real825_640_conv1_leak(1).coe`、`out_api_conv2_leak_stride2.coe` → 640×640、3→8 首层、leaky、stride2。
6. `conv/compute/Quan.scala`：INT8 + 每层 bias / scale / shift。
7. anchor 表**不在 RTL 里** ⇒ anchor 解码在主机侧（RTL 只产出原始头张量）。

**接口**：

- 主机口 = `Npu.scala` 的 `regSData = slave(AxiLite4(log2Up(1 MiB), 32))`，寄存器表由 `instruction/Instruction.scala` 经 regif `BusInterface` 自动生成（卷积/shape 的状态+控制、逐层参数、DMA 地址/长度、`convCascade`）。
- 数据面 = `Config.useXilinxDma = true` 分支：对外是 **AXI-Stream + 64 位 `cmd`(addr/len) / `valid` / `introut` 握手**，即指望外部 Xilinx AXI-DMA IP 搬数据。仓内另有一条**被整块注释掉的内部 DMA 分支**（`!useXilinxDma`，`wa/dma/DmaRead|DmaWrite`，AXI4 主口），其中 `Npu.scala:137` 的 `convSDataCmd.cmd` 混用了 `register.dma(0)(1)(1)`（疑似复制粘贴缺陷，仅作记录）。
- **仓库里没有"模型 → 指令"的编译器**：`src/main/python/` 只有一个 `paddingMode.py`。README 所称"高层次编译器"不在本仓。

**Xilinx 专属依赖（Pango 化的对象）**：

- `wa/xip/memory/xpm/XPM_MEMORY_SDPRAM.scala`、`XPM_FIFO_SYNC.scala`、`XPM_MEMORY_SPROM.scala` —— 均为 `extends BlackBox`，包的是 Xilinx 原语 `xpm_memory_sdpram` / `xpm_fifo_sync` / `xpm_memory_sprom`。
- 其上是 **SpinalHDL 组件 `class sdpram(...)`**（同文件 line 136），带 `latency` 参数：**`MEM_TYPE.block` → 2 拍、`MEM_TYPE.ultra` → 12 拍**（`conv/compute/Weight.scala:325` 等处如此取用）。
- `wa/xip/math/{DSP,Mul,AddSub}.scala`、`wa/xip/debug/Ila.scala`、`wa/xip/axi/StreamDataWidthConvert.scala`。
- `misc/TotalTcl.scala` 自动生成例化 **Xilinx IP** 的 tcl。
- `Config.useUram = true`（Pango 无 URAM）。
- 仓内另有非 IP 的 `wa/xip/memory/ip/BlockRam/{Bram.scala,TDRam.scala,BramDataType.scala}`，可作替换落点。
- 工具链：`build.sbt` = **Scala 2.12.18 + SpinalHDL 1.15.0**（README 仍写 1.7.3，属版本漂移）。

### 3.2 原目标模型裁决（YuNet，M0 主线 B 的第一轮）

官方 `face_detection_yunet_2023mar.onnx`（sha256 `8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4`，232,589 B）：输入 1×3×640×640 RGB、opset 11 / pytorch 1.7、权重 112 张量 / 212,520 B。

算子：Conv 53、Relu 15、Transpose 12、Reshape 12、Sigmoid 6、MaxPool 4、Resize 2、Add 2（**无 PReLU、无 LeakyRelu**）。Conv 的 group 直方图 `{1:33, 16:2, 32:2, 64:10, 4:3, 10:3}` ⇒ **20/53 是分组/深度可分离卷积，且整个 backbone 的 3×3 空间混合全是 depthwise**。输出 12 个 anchor-free 头（3 尺度 × cls/obj/bbox/kps）。

**裁决：原样不可行。** 加速器全源码 `group|depthwise` 零命中，只支持 dense conv33/conv11。这是设计取向差异（YuNet = MobileNet 式 depthwise + anchor-free），不是边角不兼容。

**该裁决带来的路线变更**：放弃 YuNet，改用**与硬件同族**的 YOLO 系人脸检测网（决策见 §2）。

### 3.3 本器件资源基线（本仓权威出处）

`sim/reglogs/m_yeshen_devmap.log`（2026-10-07 20:52，tag `m_yeshen`）的 Device Utilization Summary：

| 资源 | Used | Available | % |
|---|---|---|---|
| LUT | 14,130.5 | 159,800 | **9** |
| FF | 17,124 | 319,600 | 6 |
| APM（DSP） | 4 | 740 | 1 |
| DRM（Block RAM） | 23.5 | 415 | 6 |
| Distributed RAM | 224 | 39,500 | 1 |
| IO | 99 | 400 | 25 |

**结论：现有 SoC 仅占 LUT 9%，余量约 145K LUT。** 加速器是否装得下，取决于 §6 的 Pango 化后的真实数字 —— 这个数字只能由 M0 步 2 给出，不得从别的工程或别的器件外推。

## 4. 范围

### 4.1 M0 做什么

1. **算子覆盖核实**：候选 YOLO 系人脸检测网逐层对照加速器算子集，产出覆盖表（§5）。
2. **RTL 落地探针**：生成 `Npu` Verilog → Pango 化 Xilinx 专属依赖 → PDS `dev_map`（资源）→ 视情况 PnR（时序）（§6）。

### 4.2 M0 不做什么

- SoC 集成（AXI 互连、时钟/复位、地址图、中断）—— M1。
- Linux 驱动与用户态运行时 —— M3。
- 模型 → 加速器指令/权重的转换器 —— M2。
- 上板出框、性能/加速比 —— M4。
- 修改只读克隆 `third_party/SpinalHDL_CNN_Accelerator`（零改动）。

## 5. 步 1 —— 算子覆盖核实（主线 B′）

### 5.1 输入

- 候选模型：**YOLOv5 v3.0 的架构**（输入按 640×640），由 **tag v3.0 的源码 + `models/yolov5s.yaml` 构建，权重用随机初始化**。

  **为什么"架构 + 随机权重"就够**：本步回答的是**算子覆盖**，那是**图的性质**，与权重数值无关。用源码构建才能保证图与"我们声称同族的那份代码"严格一致。

  **2026-10-08 实测发现（重要，实证推翻了一个假设）**：ultralytics release 的 `v3.0/yolov5s.pt` 资产**并非**由 tag v3.0 的代码产出 —— 该 `.pt` 里 51 个 `Conv.act` 是 `nn.Hardswish`（导出成 `HardSigmoid`+`Mul`），只有 8 个 `BottleneckCSP` 内部激活是 `LeakyReLU(0.1)`；而 tag v3.0 的源码是**全 LeakyReLU**。⇒ **资产 ≠ 源码**。若直接拿该资产核算子，会因为它自身与源码不符而误判成"不覆盖"（Hardswish 不在加速器能力内）——那是**假阴性**。故本步改用**源码构建的图**，并把该不符作为一条**发现**留档（该资产导出的 ONNX 保留作对照件，但不作为 M0 结论依据）。

  **为什么不是 YOLOv5-face**：YOLOv5-face（`deepcam-cn/yolov5-face`）的权重**只发布在百度网盘 / Google Drive**（其 README 权重表给出的是网盘链接，仓内 `weights/` 仅有一个 278 B 的下载脚本，且 GitHub releases 为空），curl 不可达。而 M0 要回答的是**算子覆盖**，同族即可，不依赖人脸专用权重。**YOLOv5-face 作为 M2 的人脸落地目标是保留的**，其权重取件在 M2 解决。

  **为什么选 v3.0 源码**：`models/common.py` 第 26/58 行是 `nn.LeakyReLU(0.1, inplace=True)`；`models/yolov5s.yaml` 首层是 `Focus`、含 `SPP`、head 含 `Upsample`+`Concat`、yaml 内带 anchors —— 与加速器的 hardwired 假设逐项对上（这是加速器设计取向的正面镜像）。

- 取件属步 1 的工作：克隆 tag v3.0 到 `third_party/yolov5_v3.0`（commit `1ddf692bf89ac47d5e2dc8333cd0f4f145bb7f61`）→ 由 `models/yolov5s.yaml` 构建模型 → 以 `torch.onnx.export` 按 **opset 11** 导出（与 YuNet 同一 opset，便于复用分析脚本）。来源、指纹与导出命令必须记入报告。
- 分析工具：把已就绪的 `third_party/yunet/analyze_yunet.py`（已含 op 直方图 + Conv 的 group/kernel/stride/pad/dilation 展开 + shape inference）通用化为与模型无关的脚本，落在 M0 工程内。
- 环境：`onnx` 1.19.1 已装在 `third_party/yunet/deps`（用 `NaxYeshenLinux/sim/reglogs/lxvenv` 的 py3.9 跑，`PYTHONPATH=./deps`）。

### 5.2 产出

一张覆盖表，每行 = 一个 ONNX 算子（或算子实例），三态取一：

- **覆盖** —— 加速器原生支持；
- **需主机旁路** —— 加速器不直接支持，但**处在卷积块之间（或检测头外）**，按该加速器既有的"逐层由主机编排、层间特征落 DDR"范式可由 RV32 在 NPU 调用之间补齐（如块间 Transpose / Reshape、头侧 Sigmoid、少量逐元素算子）；
- **不覆盖** —— 既不在加速器内，也无法在主机侧低成本补齐（判据见 §5.3）。

### 5.3 判定规则（消除歧义）

- 三态的分界线是**位置**，不是算子名：
  - **在卷积块内部**（卷积与激活之间、或需按通道分组）→ 落在**不覆盖**；
  - **在卷积块之间或检测头外** → 至多**需主机旁路**。
  典型"不覆盖"= **分组/深度可分离卷积**、以及**块内激活与硬件不符**（见下）。
- **激活是第一风险项**：加速器只有 LeakyReLU（ratio 硬编码 0.1）。步 1 必须查明候选模型的激活：
  - 若为 **LeakyReLU**（或可退化为 ratio=0 的 **ReLU**）→ 覆盖；
  - 若为 **SiLU/Swish/HardSwish/PReLU** → 判**不覆盖**（因为把激活移到主机侧意味着每层特征图多一轮 DDR 往返，代价不可接受）；此时按 §5.5 回炉。
- **necks 的 Concat/Split/UpSample/MaxPool/Add** → 逐项对照 `shape/` 目录能力，落在"覆盖"或"需主机旁路"。
- **anchor 头解码** → 一律"需主机旁路"（accelerator 的 anchor 表不在 RTL 内，与这一范式一致）。

### 5.4 通过判据

**覆盖表中无"不覆盖"项**。任何"不覆盖"项都会使 M0 判定为不通过（按 §5.5 回炉）。

### 5.5 回炉规则（事先约定，避免临场含糊）

出现"不覆盖"时，按以下顺序尝试，每次只改一个变量并记录：

1. 换成同一族中**激活为 LeakyReLU/ReLU** 的版本/变体；
2. 缩小输入分辨率或通道数（降低资源压力，不解决算子缺口）；
3. 若仍不覆盖，则把结论写成"候选模型不匹配"，并把该结论交回用户在"补硬件算子 / 再换模型 / 停"之间决策 —— **不在 M0 内自行开展改硬件或换模型**。

## 6. 步 2 —— RTL 生成 + Pango 化 + 综合闸门（主线 A）

### 6.1 子步

**2.1 工具链**：搭 Scala 2.12.18 + SpinalHDL 1.15.0 的 sbt 环境，生成 `Npu` Verilog。

- 风险：sbt 首次拉依赖需走本机代理（`http_proxy=127.0.0.1:7897`）；生成耗时（README 自认"需要一些时间"）。
- 产物指纹：生成的 Verilog 文件 md5/行数。

**2.2 Pango 化**（核心风险）：在 M0 工程内复制一份 Scala 源码，按下表逐项替换。

| 原（Xilinx） | 改为 | 约束 |
|---|---|---|
| `Config.useUram = true` | `false` | Pango 无 URAM |
| `wa/xip/memory/xpm/XPM_MEMORY_SDPRAM.scala` 的 `class sdpram` | 仓内 `wa/xip/memory/ip/BlockRam/TDRam.scala`，或 SpinalHDL `Mem` 手工加流水 | **必须保持 `latency` 契约**（block=2 / ultra=12 拍）。卷积流水线的 valid 延迟计数（如 `ConvComputeCtrl.scala` 的 `normDelayCount`/`mValidDelayCount*`）按此写死，改错会全盘错位 |
| `wa/xip/memory/xpm/XPM_MEMORY_SPROM.scala` | 同上（只读口） | 同上 |
| `wa/xip/memory/xpm/XPM_FIFO_SYNC.scala` / `WaFifo.scala` 的 `WaXpmSyncFifo` | SpinalHDL `StreamFifo` 或仓内 FIFO | 保持深度语义 |
| `wa/xip/math/{DSP,Mul,AddSub}.scala` | SpinalHDL 推断乘法 / Pango DSP 宏 | 位宽与符号性（signed/unsigned）不得变 |
| `wa/xip/debug/Ila.scala` | 移除（或换 Pango ILA） | 仅调试 |
| `misc/TotalTcl.scala` | 停用其 Xilinx IP tcl 生成 | 不产生 `.xci` 依赖 |

**2.3 综合闸门**：PDS `dev_map` 取资源；资源通过再 PnR 取时序。

- 判据：综合 **0 error**；资源报告落盘。
- 是否续跑 PnR 的**事先约定规则**：`dev_map` 显示「SoC + NPU ≤ 159,800 LUT」（即有余量）则续跑 PnR 取时序；否则**停**，直接以"资源超限"作为 M0 结论，不再耗 PnR 机时。

### 6.2 Pango 化通过判据

- 综合 0 error；
- 生成网表**无 `xpm_*` 悬空实例**（用字符串扫描自证）；
- 资源清单（LUT/FF/DSP/DRM）落盘，并显式给出「SoC + NPU ≤ 159,800 LUT」的结论。

## 7. 风险与缓解

| # | 风险 | 缓解 |
|---|---|---|
| R1 | 候选模型激活不是 LeakyReLU（YOLOv5 后期版本默认 SiLU） | 步 1 首查；按 §5.5 回炉换版本 |
| R2 | `sdpram` 的 `latency` 契约在替换后失守，导致卷积流水线错位 | 替换件显式参数化 latency；**仿真数值对照**（复用仓内 `TbConv`/`TbStride` 之类的最小装置）作为回归 |
| R3 | SpinalHDL 1.15.0 与源码不兼容（README 写 1.7.3） | 若编译失败，二分到 README 版本；版本改动记入 spec 修订 |
| R4 | sbt 环境/代理搭建不畅 | 代理已验证可用；必要时与已有 `YeshenSocGlue.jar` 的构建链对齐 |
| R5 | 资源即便装得下，时序也可能不收敛 | M0 只要求"资源结论 + 尽力时序"；时序收敛作为 M1 的风险，不在 M0 卡死 |
| R6 | 本机工具链静默失败（PDS） | 按既有纪律：查 SAC/事件、看进程、看日志尾 |

## 8. 验收判据（M0 收口）

1. 算子覆盖表落盘，**无"不覆盖"项**（§5.4）；
2. `Npu` 在 Pango 工具链下**综合 0 error**；
3. 资源报告落盘，给出与 §3.3 基线对照的**余量结论**；
4. 每条结论附**可复现命令 + 产物指纹**（md5/字节数/行数）。
5. 只读克隆 `third_party/SpinalHDL_CNN_Accelerator` **零改动**（用 `git status` 自证）。

## 9. 产物与落盘

- M0 工程：`VexiiYeshenLinux/ai_npu_exp/`（新建；独立最小工程）。其中含：通用化的 ONNX 分析脚本、Pango 化后的 Scala 源码副本、生成的 Verilog、分析/资源报告。
- 分析报告：`VexiiYeshenLinux/docs/`（与既有 `board_bringup.md` 同目录）。
- 本 spec：`docs/superpowers/specs/2026-10-08-ai-accelerator-m0-design.md`。
- 克隆与模型文件均位于被 gitignore 的 `third_party/` 下，不入库。

## 10. 后续里程碑边界（不在本轮，仅界定范围）

- **M1 SoC 集成**：AxiLite4 从口 + 数据面（AXI-Stream/DMA，或用内部 AXI4-DMA 分支）接入现有 AXI 互连；时钟/复位/地址图/中断；Linux 侧寄存器读写。
- **M2 模型落地**：模型 → 指令 + 量化权重 + 内存布局（转换器需自写，M0 已确认仓内没有）。
- **M3 运行时**：用户态喂图/取结果 + 前后处理（letterbox / decode / NMS）。
- **M4 端到端验收**：单图进出出框 + 留档；性能/加速比可选。

## 11. 引用与指纹

| 对象 | 位置 / 指纹 |
|---|---|
| 加速器克隆 | `third_party/SpinalHDL_CNN_Accelerator`（只读） |
| YuNet ONNX | `third_party/yunet/yunet.onnx`，sha256 `8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4`，232,589 B |
| ONNX 分析脚本 | `third_party/yunet/analyze_yunet.py`（`onnx` 1.19.1 于 `third_party/yunet/deps`） |
| 资源基线 | `sim/reglogs/m_yeshen_devmap.log`（2026-10-07 20:52） |
| 候选模型（M0 用） | YOLOv5 v3.0 **架构**（tag v3.0 源码 + `models/yolov5s.yaml`，随机权重）；克隆 `third_party/yolov5_v3.0` |
| YOLOv5 v3.0 源码仓 | commit `1ddf692bf89ac47d5e2dc8333cd0f4f145bb7f61` |
| ⚠️ 资产/源码不符（发现） | release 资产 `v3.0/yolov5s.pt`（15,184,597 B / sha256 `b15456e31d4491cc4ff57b07ed0f45e3dbaa043592099abbe24cebe4d2b2a678`）里 51 个 `Conv.act` 是 `nn.Hardswish`，**不是**该 tag 的 LeakyReLU ⇒ 不作为 M0 结论依据，只留作对照 |
| 加速器取向的正面镜像 | v3.0 `models/common.py:26,58` `nn.LeakyReLU(0.1)`；`models/yolov5s.yaml` 首层 `Focus` + `SPP` + `Upsample`/`Concat` + anchors |
| 人脸落地目标（M2） | `deepcam-cn/yolov5-face`，权重仅在百度网盘 / Google Drive |
| 相关既有文档 | `docs/开发板功能清单-2026-10-08.md`、`docs/交付-2026-10-07.md`、`docs/board_bringup.md` |
