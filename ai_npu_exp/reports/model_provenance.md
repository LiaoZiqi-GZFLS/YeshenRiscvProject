# M0 模型来源与指纹

本文件记录 M0 用到的每个模型产物的**来源 URL、字节数、sha256**。凡结论依赖某份权重，都以本文件为据。

## 1. 正对照模型（Part A 判据用）—— YuNet

| 项 | 值 |
|---|---|
| 用途 | `onnx_report.py` 的**正对照**：已知数字必须被复现，否则判据不可信 |
| 来源 | OpenCV Zoo，`models/face_detection_yunet/face_detection_yunet_2023mar.onnx`（GitHub LFS，走 `media.githubusercontent.com` 端点取实际内容；直接 `raw.githubusercontent.com` 只会拿到 131 B 的 LFS 指针） |
| 落盘 | `third_party/yunet/yunet.onnx`（gitignored） |
| 字节数 | 232,589 |
| sha256 | `8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4` |
| 已知值（供判据核） | `Conv 53`、`Relu 15`、`Transpose 12`、`Reshape 12`、`Sigmoid 6`、`MaxPool 4`、`Resize 2`、`Add 2`；`conv_group_hist = {1:33, 4:3, 10:3, 16:2, 32:2, 64:10}`；输入 `[1,3,640,640]` |

## 2. 负对照输入（Part A 判据用）

| 项 | 值 |
|---|---|
| 用途 | `onnx_report.py` 的**负对照**：坏输入必须非 0 退出、不得静默打印"0 算子" |
| 来源 | 同上的 LFS 指针文件 `third_party/yunet/face_detection_yunet_2023mar.onnx`（131 B ASCII，不是 ONNX） |
| 实测行为 | `google.protobuf.message.DecodeError`，exit=1 |

## 3. 候选网络权重（Part A 算子核实用）—— ultralytics YOLOv5 v3.0

| 项 | 值 |
|---|---|
| 用途 | M0 的**算子覆盖对照**对象（同族即可，不需要人脸专用权重） |
| 来源 URL | `https://github.com/ultralytics/yolov5/releases/download/v3.0/yolov5s.pt` |
| 落盘 | `ai_npu_exp/models/yolov5s.pt`（gitignored） |
| 字节数 | **15,184,597** |
| sha256 | `b15456e31d4491cc4ff57b07ed0f45e3dbaa043592099abbe24cebe4d2b2a678` |
| 归档魔数 | `50 4b 03 04`（`PK..`，zip/pytorch 归档） |
| 为什么是 v3.0 | v3.0 的 `models/common.py:26,58` 是 `nn.LeakyReLU(0.1, inplace=True)`，`models/yolov5s.yaml` 首层为 `Focus`、含 `SPP`、head 含 `Upsample`+`Concat`、yaml 内带 anchors —— 与加速器（`leakyRatio=0.1` 硬编码 + `Focus` + `shape/` 的 MaxPooling/Add/Concat/Split/UpSampling）**逐项同族** |

## 4. 未采用：YOLOv5-face（人脸专用）

| 项 | 值 |
|---|---|
| 仓库 | `deepcam-cn/yolov5-face` |
| 权重可获取性 | **不可直取**。仓内 `weights/` 只有一个 278 B 的 `download_weights.sh`；其 `README` 的权重表给的是**百度网盘 / Google Drive** 链接；GitHub releases 为空。`curl` 取不到 ⇒ M0 不依赖它 |
| 处置 | **保留为 M2 的"人脸落地目标"**，权重取件在 M2 解决（届时可用 `gdown` 或人工下载后核对 sha256） |

## 5. 复现命令

```bash
export http_proxy=http://127.0.0.1:7897 https_proxy=http://127.0.0.1:7897
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp/models
curl -sSL --max-time 300 -o yolov5s.pt \
  https://github.com/ultralytics/yolov5/releases/download/v3.0/yolov5s.pt
stat -c '%s' yolov5s.pt          # 期望 15184597
sha256sum yolov5s.pt             # 期望 b15456e31d4491cc4ff57b07ed0f45e3dbaa043592099abbe24cebe4d2b2a678
```

## 6. 导出产物（Part A 的输入图）—— `ai_npu_exp/models/yolov5s.onnx`（opset-11）

### 6.1 导出命令（实测可复现）

```bash
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp
PYTHONPATH='./deps_export;../third_party/yunet/deps' \
  /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe \
  tools/export_onnx.py models/yolov5s.pt models/yolov5s.onnx
```

两个环境口径（都是实测撞出来的，不是猜的）：

- **Windows 上 `PYTHONPATH` 必须用 `;` 分隔。** CPython 按 `os.pathsep` 切分 `PYTHONPATH`，写成 `./deps_export:../third_party/yunet/deps` 会把整串当成**一个**目录，`import torch` 直接 `ModuleNotFoundError: No module named 'torch'`。
- 脚本内 `third_party/yolov5_v3.0` 必须用**由 `__file__` 推出的绝对路径**插入 `sys.path`（相对路径会让 torch 的 DLL 加载器报 `OSError: [WinError 87]`）。

### 6.2 指纹

| 项 | 值 |
|---|---|
| 文件 | `ai_npu_exp/models/yolov5s.onnx`（gitignored，`models/` 规则覆盖） |
| 字节数 | **29,905,151** |
| sha256 | `b440e463d9212dc338e55e52ab45aa7f290c107f8bfdfa428b0d033b9914d69f` |
| opset | `ai.onnx 11`（唯一 import） |
| 节点数 | **285**（initializer 156，value_info 0） |
| 输入 | `input` `[1, 3, 640, 640]`（fp32） |
| 输出 | `output` `[1, 3, 80, 80, 85]`、`726` `[1, 3, 40, 40, 85]`、`738` `[1, 3, 20, 20, 85]` |

输出名说明：`output_names=["output"]` 只够命名**第一个**输出，另两个（P4/16、P5/32）被 exporter 自动命名成数字串 `726` / `738`。三个输出**按位置**依次是 P3/P4/P5 三个检测层的原始卷积张量。下游按位置取用，别按名字找。

### 6.3 闸门与算子直方图

`onnx.checker.check_model` **静默通过**；节点数 285（非 0）；输入 `[1,3,640,640]`；opset `ai.onnx 11`。

| op | n | | op | n |
|---|---|---|---|---|
| Conv | 70 | | Unsqueeze | 4 |
| HardSigmoid | 51 | | MaxPool | 3 |
| Mul | 51 | | Reshape | 3 |
| Constant | 41 | | Transpose | 3 |
| Concat | 18 | | Shape | 2 |
| Slice | 8 | | Cast | 2 |
| BatchNormalization | 8 | | Resize | 2 |
| LeakyRelu | 8 | | Floor | 4 |
| Add | 7 | | | |

按结构归类（供 A4/A5 的覆盖表用；节点名逐个核对过）：

- `Conv 70` = 51 个 `models.common.Conv` + 16 个 `BottleneckCSP.cv2/cv3` + 3 个 `Detect.m`。
- `HardSigmoid 51 + Mul 51` = **Hardswish 的分解**（`x * hard_sigmoid(x)`，`alpha=1/6`、beta 缺省 0.5），对应 51 个 `Conv.act`。见 6.5 的警告。
- `LeakyRelu 8`（`alpha=0.1`）+ `BatchNormalization 8`：节点名 `/model.{2,4,6,9,13,17,20,23}/bn` → 正是 8 个 `BottleneckCSP` 里 **Concat 之后**那个 BN+act。
- `Add 7` = `Bottleneck` 残差短路（`shortcut=True` 的那些；8 个 CSP 合计 12 个 Bottleneck，其中 7 个带 add）。
- `MaxPool 3` = `SPP`，`Concat 1 + Slice 6` = `Focus`。
- `Resize 2 + Shape 2 + Cast 2 + Floor 4 + Unsqueeze 4 + Slice 2 + Concat 4 + Constant ~17`：节点名 `/model.11/*`、`/model.15/*` —— 即 head 里两层 `nn.Upsample(scale_factor=2, nearest)`，opset-11 下 `Resize` 的 sizes 是**运行时由 `Shape` 算出来的**，不是常量。
- `Concat 18` = 4（head 的 `Concat` 模块）+ 8（CSP 内 cat）+ 1（SPP）+ 1（Focus）+ 4（上面 Resize 的尺寸计算）。

### 6.4 Detect head 的模式

- **export 模式：yes**（`model.model[-1].export = True`）。
- 证据有二：① dry-run 直接返回 3 个 `(1,3,ny,nx,85)` 原始张量（80/40/20），而解码分支会返回 `(torch.cat(z,1), x)`；② 直方图里**没有 `Sigmoid`、没有 grid/anchor 相关算子、没有 NMS**。锚框解码（sigmoid、`*2-0.5+grid`、`(2σ)²*anchor`、meshgrid）**全部不在图里**。
  注意：`HardSigmoid` 是 Hardswish 的分解，**不是**检测头解码里的那个 `Sigmoid`，别混。

### 6.5 必须记录的意外发现（会改 A5 的分类结论）

1. **这份权重的卷积主激活是 `nn.Hardswish`，不是 `LeakyReLU(0.1)`。** 51/51 个 `models.common.Conv` 的 `act` 都是 `torch.nn.Hardswish`；只有 8 个 `BottleneckCSP` 内部的激活是 `nn.LeakyReLU(0.1, inplace=True)`。这与 §3 里"选 v3.0 是因为 `models/common.py:26,58` 是 `nn.LeakyReLU(0.1)`"的理由**不一致**——`third_party/yolov5_v3.0`（tag v3.0，`1ddf692`）的源码确实满篇 LeakyReLU，所以**这份 `.pt` 不是该 tag 源码产出的**（应为 v3.1/v4.0 时代、`Conv` 已换成 Hardswish 之后重新上传的训练产物）。后果：加速器硬编码的 `leakyRatio=0.1` 只在这 8 个 CSP 内激活上对口，主激活要额外覆盖 `HardSigmoid`（α=1/6、β=0.5）+ `Mul`。**A5 不能按"全 LeakyReLU"下结论。**
2. **checkpoint 是 fp16 存的**（7,468,157 个参数全是 `torch.float16`；14.94 MB + pickle 开销 = 15,184,597 B）。导出脚本必须 `model.float()`，否则 initializer 全是 fp16。
3. **未调用 `model.fuse()`**（本子任务口径没要求），但 exporter 自带的 peephole 已经**顺手折了 conv+BN**：59 个 `BatchNorm2d` 只剩 8 个 `BatchNormalization`，正是 CSP 里 Concat 之后那 8 个折不掉的。所以"图里还有 BN"这句话只对那 8 个成立。
4. **Detect 实例里没有 `export` 属性**（`hasattr(...) == False`）：该 `.pt` 的 `__dict__` 里就没存这个键，但**类**是 v3.0 的 `models.yolo.Detect`，其 `forward` 会读 `self.export`，所以脚本直接赋值即可生效，无需退化到 `torch.jit.trace`，也无需放弃 export 模式。
5. **Hardswish 反序列化兼容**：解出来的 `nn.Hardswish` 对象没有 `inplace`（老 torch 的 `nn.Hardswish` 无此属性），torch 2.8 会在 `F.hardswish(input, self.inplace)` 处抛 `AttributeError: 'Hardswish' object has no attribute 'inplace'`。脚本补回 `inplace=False`（行为等价：hardswish 本来就是 out-of-place）。
6. **数值一致性没做**：`deps_export` 里没有 `onnxruntime`，而 `onnx.reference`（`ReferenceEvaluator`）在本环境**import 即整进程静默退出**（无 traceback，疑似原生崩溃）。因此本图只过了 `onnx.checker`（语法/结构合法性）+ dry-run 形状证据，**没有做"同一输入下 ONNX 输出 vs PyTorch 输出"的数值对齐**。若 A4/A5 需要数值证据，得先装 `onnxruntime`。

## 7. **替代图**（M0 Part A 实际判据图）—— `ai_npu_exp/models/yolov5s_v3src.onnx`（由 tag v3.0 源码构建）

### 7.1 为什么必须换掉 §6 的资产导出图

§6.5 第 1 条已经实证：release 资产 `v3.0/yolov5s.pt` **不是 tag v3.0 源码的产物**——它的 51 个 `models.common.Conv` 主激活是 `nn.Hardswish`（导出成 `HardSigmoid 51 + Mul 51`），只有 8 个 `BottleneckCSP` 内激活是 `LeakyReLU(0.1)`；而 `third_party/yolov5_v3.0`（tag v3.0、`1ddf692`）的源码**满篇 `nn.LeakyReLU(0.1)`**（`models/common.py:26,58`）。**资产 ≠ 源码**。

加速器硬编码的只有 `LeakyReLU(ratio=0.1)`（无 `HardSigmoid`/`Mul` 形态的激活）。M0 Part A 要拿"我们声称与加速器同族的那张图"去撞加速器的能力表；若拿 §6 的资产图去撞，`HardSigmoid 51 + Mul 51` 会被判成"加速器不支持"，而**这个不支持是我们自己选错权重造成的**——即**假阴性**，正是本子任务要避免的坑。

**算子覆盖是"图"的属性，不是"权重"的属性。** 因此按 `third_party/yolov5_v3.0/models/yolov5s.yaml` + tag v3.0 源码重建图、**随机初始化权重**，既足够（算子集合与权重数值无关），又更诚实（图与"我们声称的源码"由构造保证一致，不再依赖任何第三方资产的自我声明）。

### 7.2 构建 + 导出命令（实测可复现）

```bash
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp
PYTHONPATH='./deps_export;../third_party/yunet/deps' \
  /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe \
  tools/export_onnx_src.py models/yolov5s_v3src.onnx
```

脚本 `ai_npu_exp/tools/export_onnx_src.py`：绝对路径插入 `third_party/yolov5_v3.0` → `from models.yolo import Model` → `Model(<abs yaml>, ch=3, nc=80)`（随机权重）→ `model.eval()` → 打印 torch 侧模块/激活清点 → `model.model[-1].export = True` → `torch.onnx.export(..., opset_version=11, input_names=["input"], do_constant_folding=True)`。传**已存在的绝对 yaml 路径**，`Model.__init__` 只走 `open(cfg)`，**不触碰 `attempt_download`，无任何网络访问**。

**唯一一处适配（必须记录）**：`Model.__init__` 的签名与口径**完全一致**，`def __init__(self, cfg='yolov5s.yaml', ch=3, nc=None)`，无需改动；`nc=80` 与 yaml 相同故不触发 `Overriding` 分支。但构造会在末尾调 `self._initialize_biases()`，其中 `b = mi.bias.view(m.na, -1); b[:, 4] += math.log(...)` 是**对 leaf Variable 的 view 做原地写**，torch ≥ 1.9 直接抛：

```
RuntimeError: a view of a leaf Variable that requires grad is being used in an in-place operation.
```

（§6 的资产路径没撞上这条，是因为**反序列化不执行 `_initialize_biases`**。）处置：脚本把构造包进 `with torch.no_grad():`——**不改 `third_party/`**（只读），不改模块树、不改激活类型、不改前向图；bias 初值对本图无意义。另：v3.0 的 `Model` **没有 `self.nc` 属性**（nc 存在 `self.yaml` 里），脚本改从 `model.yaml['nc']` 读。

### 7.3 导出前的 torch 侧清点（本子任务的核心佐证）

```
module-class : Conv2d 70, BatchNorm2d 59, LeakyReLU 59, Conv 51, Bottleneck 12,
               Sequential 9, BottleneckCSP 8, Concat 4, MaxPool2d 3, ModuleList 2,
               Upsample 2, Detect 1, Focus 1, SPP 1, Model 1
act inventory: {'LeakyReLU': 59}      <- 59 = 51 个 Conv.act + 8 个 BottleneckCSP.act
LeakyReLU mods: 59      Hardswish mods: 0
stride        : [8.0, 16.0, 32.0]     dry-run outputs: [(1,3,80,80,85), (1,3,40,40,85), (1,3,20,20,85)]
```

`Hardswish 0` 与"源码全 LeakyReLU"一致，`LeakyReLU 59`（全部 `alpha=0.1`）与"加速器硬编码 ratio=0.1"逐项对口。dry-run 直接吐 3 个 `(1,3,ny,nx,85)` 原始张量 ⇒ Detect 处于 export 模式，解码分支未走。

### 7.4 指纹

| 项 | 值 |
|---|---|
| 文件 | `ai_npu_exp/models/yolov5s_v3src.onnx`（gitignored，`models/` 规则覆盖） |
| 来源 | **源码构建**：`third_party/yolov5_v3.0`（tag v3.0, `1ddf692bf89ac47d5e2dc8333cd0f4f145bb7f61`）的 `models/yolov5s.yaml` + `models/*.py`，**随机权重** |
| 字节数 | **29,840,821** |
| sha256 | `1cd8e333ad0c1742509116b3ad3dcabb198f91ff4f38ac92bde970b14859930d` |
| opset | `ai.onnx 11`（唯一 import） |
| 节点数 | **276**（initializer 86，value_info 0） |
| 输入 | `input` `[1, 3, 640, 640]`（fp32） |
| 输出 | `639` `[1, 3, 80, 80, 85]`、`651` `[1, 3, 40, 40, 85]`、`663` `[1, 3, 20, 20, 85]`（同 §6.2：未命名，**按位置**依次 P3/P4/P5） |
| 参数元素总数 | 7,449,740（initializer 7,449,693 + Constant 47），与 yolov5s 量级一致 |

### 7.5 闸门与**完整**算子直方图

`onnx.checker.check_model` **静默通过**；节点数 276（>0）；输入 `[1,3,640,640]`；opset `ai.onnx 11`；**`LeakyRelu` = 59 > 0**；**`HardSigmoid` 与 `Sigmoid` 均不存在**。四项闸门全部满足。

| op | n | | op | n |
|---|---|---|---|---|
| Identity | 70 | | Slice | 6 |
| Conv | 70 | | MaxPool | 3 |
| LeakyRelu | 59 | | Reshape | 3 |
| Constant | 31 | | Transpose | 3 |
| Concat | 14 | | Resize | 2 |
| BatchNormalization | 8 | | | |
| Add | 7 | | | |

按结构归类（节点名逐个核对过）：

- `Conv 70` = 51 个 `models.common.Conv` + 16 个 `BottleneckCSP.cv2/cv3` + 3 个 `Detect.m`。**54 个 Conv 带 bias 输入、16 个不带**：带 bias 的 51 个正是 conv+BN 被 exporter 折掉的（BN 带 bias），16 个 `cv2/cv3` 是裸 `nn.Conv2d(bias=False)`。
- `LeakyRelu 59`（**alpha = 0.1**，逐个核过属性）：51 个 `Conv.act` + 8 个 `BottleneckCSP.act`。**这就是与 §6 图的根本区别**：§6 里这 51 个是 `HardSigmoid+Mul`。
- `BatchNormalization 8` = 8 个 `BottleneckCSP` 里 **Concat 之后**那个 `bn`（折不掉的那 8 个，与 §6.5 第 3 条同因）。
- `Add 7` = `Bottleneck` 残差短路（12 个 Bottleneck 中 7 个 `shortcut=True`）。
- `MaxPool 3` = `SPP`；`Slice 6` = `Focus`（`Focus` 的 4 路切片 + 2 级再切）；`Concat 14` = 4（head 的 `Concat`）+ 8（CSP 内 cat）+ 1（SPP）+ 1（Focus）。
- `Resize 2` = head 里两层 `nn.Upsample(scale_factor=2, nearest)`；**输入是 `(X, roi, scales)` 且 roi/scales 都是 Constant** ⇒ 本图**没有** §6 里那条"运行时算尺寸"的 `Shape/Cast/Floor/Unsqueeze/Slice` 链（§6 的 `Slice 8/Concat 18` 多出来的 2/4 个正是那条链）。
- `Reshape 3 + Transpose 3` = `Detect.forward` 在 export 模式下仍执行的 `x[i].view(bs,na,no,ny,nx).permute(0,1,3,4,2)`（所以输出是 `(1,3,ny,nx,85)` 而非 `(1,255,ny,nx)`）。**不是**锚框解码。

### 7.6 A4/A5 必读：`Identity 70` 是无操作别名，别误判成"未支持算子"

本图有 §6 里**没有**的 `Identity 70`。已证其性质（逐节点核过）：

- 70 个 `Identity` 的输入**全是 initializer**（100%），输出**只被** `Conv` 的 **input[2]（bias）** 或 `BatchNormalization` 的 **input[1..4]（scale/B/mean/var）** 消费；**没有任何一个 `Conv` 把 `Identity` 当 data 输入（input[0]）** ⇒ 完全不在数据通路上。
- 成因（已实测）：**未训练** ⇒ 8 个 `BottleneckCSP.bn` 的参数**全局同值**（weight 全 1、bias 全 0、mean 全 0、var 全 0.9），且折出来的 51 个 conv bias **精确全 0**（`beta - gamma*mean/sqrt(var+eps) = 0`）；exporter 的常量池把**同值张量去重**成 1 个 initializer，其余引用点补 `Identity` 别名。**去重保值**（同名/同值），只是权重全零，对算子覆盖无影响。
- 对比：§6 的资产图权重是训练过的、BN 统计各异 ⇒ 没有去重 ⇒ 没有 `Identity`。所以 `Identity 70` 是"随机权重 + 常量池去重"的副产物，**不是图结构差异**。A5 的覆盖表应把 `Identity` 记为**直通/wire（非算子）**，否则会把 70 个假阳性塞进"加速器不支持"。

### 7.7 证据等级（一句话）

**本图的证据等级 = "tag v3.0 源码构建的图 + 随机权重"：它只用来主张算子覆盖（图里有哪些算子、什么连接、什么激活），不主张任何数值、精度或检测结果**；权重为随机、且未做 ONNX↔PyTorch 数值对齐（原因同 §6.5 第 6 条：本环境无 `onnxruntime`）。任何"精度/检测正确性"的结论都不允许引用本文件。
