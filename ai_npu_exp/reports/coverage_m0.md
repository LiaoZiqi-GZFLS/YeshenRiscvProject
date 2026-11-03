# M0 算子覆盖报告（三态判据）

- **候选图**：`ai_npu_exp/models/yolov5s_v3src.onnx`
  （sha256 `1cd8e333ad0c1742509116b3ad3dcabb198f91ff4f38ac92bde970b14859930d`，29,840,821 B；gitignored，报告件 `reports/ops_yolov5s_v3src.txt`）
- **对照件（Control A / 负例）**：`third_party/yunet/yunet.onnx`
  （sha256 `8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4`，232,589 B）
- **判据脚本**：`ai_npu_exp/tools/check_coverage.py`（三态：覆盖 / 需主机旁路 / 不覆盖；`Identity`/`Constant` 单列为 `wire`，不计算子）
- **加速器算子面（权威，读自 `third_party/SpinalHDL_CNN_Accelerator` RTL，只读）**：
  - 卷积仅 `conv11`/`conv33`、**仅稠密**（全 Scala 源码零 `group`/`depthwise`/`dilation`），可选 stride 与四侧 padding；
  - 激活仅 `LeakyRelu`，`leakyRatio` 硬编码 `0.1`（`conv/compute/ConvConfig.scala`）；普通 `Relu` = ratio 0，需改配置常量、非新通路；
  - INT8 逐层量化带 bias/scale/shift（`conv/compute/Quan.scala`）——BN 折叠的天然去处；
  - `shape/` 支持 MaxPooling、Add（`AddAdd`/`AddScale`）、Concat、Split、UpSampling；主干有 `Focus`；
  - 锚点解码不在 RTL（锚表在主机侧），检测头为 export 模式（输出 3 个裸头张量）。

**证据等级：** 本图由 tag `v3.0` 源码 + `models/yolov5s.yaml` 构建，**权重为随机权重**，Detect 处于 export 模式；本报告只做**算子覆盖**判定，**不含任何数值/精度验证**；分组直方图与算子表均取自机器生成的 `reports/ops_yolov5s_v3src.txt`。

---

## 1. 判据（三态规则）

分界是**位置**，不是算子名：

- **在卷积块内部**（卷积与激活之间、或需按通道分组才能表达）→ **不覆盖**；
- **在卷积块之间或检测头外** → 至多 **需主机旁路**（RV32 在两次 NPU 调用之间、借加速器既有的“逐层、特征落 DDR”编排完成）；
- 加速器**原生实现**的算子 → **覆盖**。

闸门：**覆盖表内不得出现任何 `不覆盖` 条目**。

---

## 2. 候选图覆盖表（`check_coverage.py reports/ops_yolov5s_v3src.txt` 原样）

| op | count | decision | 依据 |
|---|---|---|---|
| Identity | 70 | wire | 非算子（参数别名/常量池去重产物）。报告本身不含连线与消费方信息，无法仅凭报告断言“仅作参数别名”；据外部核验：70 个 Identity 全部以 initializer 为输入，仅被 Conv bias(50)/BatchNorm 参数(20) 消费，零条落在数据通路 ⇒ 判 wire |
| Conv | 70 | 覆盖 | 全 group=1 稠密卷积，k∈{1,3}、stride∈{1,2}、pads∈{0,1}，均落在原生 conv11/conv33 面内 |
| LeakyRelu | 59 | 覆盖 | 加速器原生 LeakyRelu；报告不含 alpha，据外部核验 alpha=0.1 与硬编码 leakyRatio(ConvConfig.scala)=0.1 一致 |
| Constant | 31 | wire | 非算子：常量池节点（initializer 别名/标量），不参与计算 |
| Concat | 14 | 覆盖 | shape/Concat 原生实现 |
| BatchNormalization | 8 | 需主机旁路 | 位置：Concat 之后、LeakyReLU 之前（BottleneckCSP 尾部），属块边界而非“卷积↔激活”之间；后向无 conv 可折、前向被激活阻断（BN→act→Conv1×1），不可权值折叠。加速器无现成 per-channel affine 通路（shape/Add 有 AddScale 缩放，但未见 per-channel bias 通路、且本次未在 RTL 核实）⇒ 保守判需主机旁路：特征落 DDR 后由 RV32 做 (x-mean)/sqrt(var+eps)*γ+β。【若改判“覆盖”必须先核实】AddScale 能表达含 bias 的 per-channel affine 且能串入 CSP 尾部——本次未核实，M2 编译器裁决 |
| Add | 7 | 覆盖 | shape/Add（AddAdd 两路相加）原生实现，对应残差短路 |
| Slice | 6 | 需主机旁路 | Focus 主干切片 + 检测头/网格切片，位于块边界；shape/ 只有通道切分 Split、无通用 Slice ⇒ 主机在特征落 DDR 后切片 |
| MaxPool | 3 | 覆盖 | shape/MaxPooling 原生实现 |
| Reshape | 3 | 需主机旁路 | 纯张量重排，无算力，可并入主机侧搬运/寻址完成 |
| Transpose | 3 | 需主机旁路 | 纯布局置换，无算力，可并入主机侧搬运/寻址完成 |
| Resize | 2 | 覆盖 | neck 的 2× 最近邻上采样 ≙ 原生 shape/UpSampling；报告不含 Resize 的 mode/scale，具体缩放语义需在 M1 对齐 |

汇总：`wire=2, 覆盖=6, 需主机旁路=4`；`conv_group_hist = {"1": 70}`（70/70 稠密，无分组卷积）。

---

## 3. 判据可信性证据（正负对照）

判据先在一“已知坏”输入上验红、再在一“已知好”输入上验绿；两者都对，才说明它真在读分组直方图。

### Control A（负例，YuNet）—— 必须红

命令（报告 `yunet_ops.txt` 由 `onnx_report.py` 现场重生成）：

```bash
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp
PYTHONPATH='../third_party/yunet/deps' \
  /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe \
  tools/onnx_report.py ../third_party/yunet/yunet.onnx > /tmp/yunet_ops.txt
python tools/check_coverage.py /tmp/yunet_ops.txt | tail -5 ; echo "exit=$?"
```

输出尾部（原样）：

```
不覆盖：存在分组卷积（group=4:3, group=10:3, group=16:2, group=32:2, group=64:10；20/53 个卷积非稠密）

汇总：不覆盖=1, 覆盖=4, 需主机旁路=3
conv_group_hist：{"1": 33, "4": 3, "10": 3, "16": 2, "32": 2, "64": 10}
RESULT: FAIL grouped-conv
exit=0
```

> **注意**：`exit=0` 是**管道假象**——`$?` 取的是管道末端 `tail` 的退出码，不是判据的。判据真实退出码经直接运行取得为 **`true_exit=1`（非零）**。完整表见下：

| op | count | decision | 依据 |
|---|---|---|---|
| Conv | 53 | 不覆盖 | 存在分组卷积（group=4:3, group=10:3, group=16:2, group=32:2, group=64:10；20/53 非稠密）；加速器 RTL 仅 conv33/conv11 稠密实现，源码无 group/depthwise/dilation |
| Relu | 15 | 覆盖 | ≡ LeakyRelu(ratio=0)，只需把 ConvConfig 常量改为 0，不新增数据通路 |
| Transpose | 12 | 需主机旁路 | 纯布局置换，无算力，可并入主机侧搬运/寻址完成 |
| Reshape | 12 | 需主机旁路 | 纯张量重排，无算力，可并入主机侧搬运/寻址完成 |
| Sigmoid | 6 | 需主机旁路 | 非原生非线性；报告不含位置信息，按“块间/检测头外可主机旁路”处理（若实际位于卷积块内部则应升为不覆盖） |
| MaxPool | 4 | 覆盖 | shape/MaxPooling 原生实现 |
| Resize | 2 | 覆盖 | neck 的 2× 最近邻上采样 ≙ 原生 shape/UpSampling；报告不含 Resize 的 mode/scale，具体缩放语义需在 M1 对齐 |
| Add | 2 | 覆盖 | shape/Add（AddAdd 两路相加）原生实现，对应残差短路 |

即复现了既有结论：**YuNet 20/53 卷积为分组/depthwise，原样不可行**。

### Control B（正例，v3.0 源码图）—— 必须绿

```bash
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp
python tools/check_coverage.py reports/ops_yolov5s_v3src.txt | tail -5 ; echo "exit=$?"
```

输出尾部（原样；真实退出码 `true_exit=0`）：

```
汇总：wire=2, 覆盖=6, 需主机旁路=4
conv_group_hist：{"1": 70}
RESULT: PASS
```

---

## 4. 判决

```
RESULT: PASS
```

**覆盖表内无任何 `不覆盖` 条目 ⇒ 闸门通过。** 候选图（YOLOv5 v3.0 源码构建）的算子可全部映射为「覆盖」（6 类原生算子）或「需主机旁路」（4 类块间/头外算子），无一项落在卷积块内部不可表达。

---

## 5. 未决项（open items）

以下为被判 `需主机旁路` 或带 `需核实` 的条目——**M2（编译器/编排）必须逐条裁决**：

1. **BatchNormalization（8 个）——最关键的一项。**
   位置在 `Concat → BN → LeakyReLU → Conv(1×1)`（BottleneckCSP 尾部）：后向无 conv 可折、前向被激活阻断，**不能权值折叠**。当前判 `需主机旁路`（RV32 在特征落 DDR 后做逐通道 affine）。
   **要改判「覆盖」必须先核实**：`shape/Add` 的 `AddScale` 路径能表达**含 bias** 的 per-channel affine（当前只见缩放 `scale`、未见 per-channel bias 通路），且能串入 CSP 尾部。本次**未在 RTL 核实**该路径 ⇒ 标 `需核实`。
2. **Slice（6 个）**：位于 Focus 主干（4 个，`x[..., ::2, ::2]` 类切片）与检测头/网格构造区（2 个）。`shape/` 仅有通道切分 `Split`、无通用按范围 Slice ⇒ 判 `需主机旁路`（主机在 DDR 上切片/搬运）。若 M1 证明 `Split` 语义可覆盖主干 Focus 切片，可部分升级为覆盖。
3. **Reshape（3）/ Transpose（3）**：检测头逐尺度的纯张量重排/布局置换，无算力 ⇒ `需主机旁路`；确认落在头外即可。
4. **Resize（2，判覆盖但语义需核实）**：报告中**不含** Resize 的 `mode`/`scale`；判覆盖的前提是“neck 的 2× 最近邻上采样 ≙ 原生 UpSampling”。需在 M1 对齐缩放语义（整数倍 / 最近邻）。
5. **LeakyRelu（59）**：报告**不含** `alpha`；判覆盖依赖外部核验 `alpha = 0.1 == leakyRatio`。若权重来源改变，需重核。
6. **Identity（70）/ Constant（31）**：判 `wire`（非算子）的**连线条件无法仅凭报告断言**（报告不含输入/消费方），依据为外部核验的“全部以 initializer 为输入、仅作 Conv bias / BN 参数被消费、零条数据通路”。此为随机权重下常量池去重的产物；**训练权重下该 70 个 Identity 应消失**，M1 需复跑确认。

---

## 6. 复现

```bash
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp
# 负例（须红，真退出码 1）
PYTHONPATH='../third_party/yunet/deps' \
  /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe \
  tools/onnx_report.py ../third_party/yunet/yunet.onnx > /tmp/yunet_ops.txt
python tools/check_coverage.py /tmp/yunet_ops.txt ; echo "exit=$?"
# 正例（须绿，真退出码 0）
python tools/check_coverage.py reports/ops_yolov5s_v3src.txt ; echo "exit=$?"
```
