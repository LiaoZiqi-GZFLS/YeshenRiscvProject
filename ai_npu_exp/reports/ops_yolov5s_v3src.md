# YOLOv5 v3.0 源码构建图的原始算子报告

- 输入产物：`models/yolov5s_v3src.onnx`（29840821 B，sha256 `1cd8e333ad0c1742509116b3ad3dcabb198f91ff4f38ac92bde970b14859930d`，gitignored）
- 生成方式：`tools/export_onnx_src.py`（tag v3.0 源码 + `models/yolov5s.yaml`，随机权重，Detect 处于 export 模式）
- 本文件由 `tools/onnx_report.py` 的输出**原样**转存，未经筛选或修改。
- 对照件：`models/yolov5s.onnx`（release 资产导出，Hardswish 版）**不作为 M0 结论依据**。

## 原始报告（原样）

```
== io ==
  in  input [1, 3, 640, 640]
  out 639 [1, 3, 80, 80, 85]
  out 651 [1, 3, 40, 40, 85]
  out 663 [1, 3, 20, 20, 85]
== ops ==
  Identity 70
  Conv 70
  LeakyRelu 59
  Constant 31
  Concat 14
  BatchNormalization 8
  Add 7
  Slice 6
  MaxPool 3
  Reshape 3
  Transpose 3
  Resize 2
== conv ==
  1 /model.0/conv/conv/Conv group=1 k=[3, 3] s=[1, 1] p=[1, 1, 1, 1] d=[1, 1]
  2 /model.1/conv/Conv group=1 k=[3, 3] s=[2, 2] p=[1, 1, 1, 1] d=[1, 1]
  3 /model.2/cv1/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  4 /model.2/m/m.0/cv1/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  5 /model.2/m/m.0/cv2/conv/Conv group=1 k=[3, 3] s=[1, 1] p=[1, 1, 1, 1] d=[1, 1]
  6 /model.2/cv3/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  7 /model.2/cv2/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  8 /model.2/cv4/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  9 /model.3/conv/Conv group=1 k=[3, 3] s=[2, 2] p=[1, 1, 1, 1] d=[1, 1]
  10 /model.4/cv1/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  11 /model.4/m/m.0/cv1/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  12 /model.4/m/m.0/cv2/conv/Conv group=1 k=[3, 3] s=[1, 1] p=[1, 1, 1, 1] d=[1, 1]
  13 /model.4/m/m.1/cv1/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  14 /model.4/m/m.1/cv2/conv/Conv group=1 k=[3, 3] s=[1, 1] p=[1, 1, 1, 1] d=[1, 1]
  15 /model.4/m/m.2/cv1/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  16 /model.4/m/m.2/cv2/conv/Conv group=1 k=[3, 3] s=[1, 1] p=[1, 1, 1, 1] d=[1, 1]
  17 /model.4/cv3/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  18 /model.4/cv2/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  19 /model.4/cv4/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  20 /model.5/conv/Conv group=1 k=[3, 3] s=[2, 2] p=[1, 1, 1, 1] d=[1, 1]
  21 /model.6/cv1/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  22 /model.6/m/m.0/cv1/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  23 /model.6/m/m.0/cv2/conv/Conv group=1 k=[3, 3] s=[1, 1] p=[1, 1, 1, 1] d=[1, 1]
  24 /model.6/m/m.1/cv1/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  25 /model.6/m/m.1/cv2/conv/Conv group=1 k=[3, 3] s=[1, 1] p=[1, 1, 1, 1] d=[1, 1]
  26 /model.6/m/m.2/cv1/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  27 /model.6/m/m.2/cv2/conv/Conv group=1 k=[3, 3] s=[1, 1] p=[1, 1, 1, 1] d=[1, 1]
  28 /model.6/cv3/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  29 /model.6/cv2/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  30 /model.6/cv4/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  31 /model.7/conv/Conv group=1 k=[3, 3] s=[2, 2] p=[1, 1, 1, 1] d=[1, 1]
  32 /model.8/cv1/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  33 /model.8/cv2/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  34 /model.9/cv1/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  35 /model.9/m/m.0/cv1/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  36 /model.9/m/m.0/cv2/conv/Conv group=1 k=[3, 3] s=[1, 1] p=[1, 1, 1, 1] d=[1, 1]
  37 /model.9/cv3/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  38 /model.9/cv2/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  39 /model.9/cv4/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  40 /model.10/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  41 /model.13/cv1/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  42 /model.13/m/m.0/cv1/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  43 /model.13/m/m.0/cv2/conv/Conv group=1 k=[3, 3] s=[1, 1] p=[1, 1, 1, 1] d=[1, 1]
  44 /model.13/cv3/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  45 /model.13/cv2/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  46 /model.13/cv4/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  47 /model.14/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  48 /model.17/cv1/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  49 /model.17/m/m.0/cv1/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  50 /model.17/m/m.0/cv2/conv/Conv group=1 k=[3, 3] s=[1, 1] p=[1, 1, 1, 1] d=[1, 1]
  51 /model.17/cv3/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  52 /model.17/cv2/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  53 /model.17/cv4/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  54 /model.18/conv/Conv group=1 k=[3, 3] s=[2, 2] p=[1, 1, 1, 1] d=[1, 1]
  55 /model.20/cv1/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  56 /model.20/m/m.0/cv1/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  57 /model.20/m/m.0/cv2/conv/Conv group=1 k=[3, 3] s=[1, 1] p=[1, 1, 1, 1] d=[1, 1]
  58 /model.20/cv3/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  59 /model.20/cv2/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  60 /model.20/cv4/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  61 /model.21/conv/Conv group=1 k=[3, 3] s=[2, 2] p=[1, 1, 1, 1] d=[1, 1]
  62 /model.23/cv1/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  63 /model.23/m/m.0/cv1/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  64 /model.23/m/m.0/cv2/conv/Conv group=1 k=[3, 3] s=[1, 1] p=[1, 1, 1, 1] d=[1, 1]
  65 /model.23/cv3/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  66 /model.23/cv2/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  67 /model.23/cv4/conv/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  68 /model.24/m.0/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  69 /model.24/m.1/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
  70 /model.24/m.2/Conv group=1 k=[1, 1] s=[1, 1] p=[0, 0, 0, 0] d=[1, 1]
== conv_group_hist == {"1": 70}
== activations ==
  LeakyRelu 59
```
