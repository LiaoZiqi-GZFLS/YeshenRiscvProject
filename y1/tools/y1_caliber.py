# -*- coding: utf-8 -*-
"""y1_caliber.py —— Y1 交付口径的三处**宿主侧**补正（2026-10-17，S4-B）。

背景（板上实测定案，见 `reports/npu_v2_board_frame.md` §15）：
  · **D1 标定域**：转换器此前用 `quant_ref` 的默认合成输入 `U[0,1)`（输入激活 `s=1/255`），
    而驱动实际灌的是 **0..255** 真图码点（`s=1`）⇒ 首层 `bias_adj`/`M` 差 255 倍，整网退化。
    ⇒ 本文件提供 `calib_nchw(img)`：与黄金**同一张**真图（帧）做标定。
  · **D2 折进零点**：15 个 `Relu` 折进单元的 epilogue 必须用 `z_y_eff`（= -128），
    驱动此前投的是 `z_y`（conv 自刻度）⇒ 输出整体偏 +169、逐通道饱和。
    ⇒ 驱动侧改投 `z_y_eff`（`npu_frame_run.mailbox_writes`）。
  · **D4 Sigmoid 固定点**：`SigmoidUnit` 的 256 项 LUT 是**冻结的 Q3.4→Q0.7**
    （`out = round(127·sigmoid(x/16))`），与转换器按标定刻度生成的 per-layer LUT 不同源。
    本代**不重出比特流** ⇒ 把 6 个 Sigmoid 的输入/输出刻度**强制**到 LUT 的口径：
      输入（生产者 3×3 尾卷积的输出 + Transpose/Reshape 视图）= `s=1/16, z=0`（Q3.4）
      输出（cls_*/obj_* 六路）                    = `s=1/127, z=0`（Q0.7）
    ⇒ `apply_sigmoid_fix(act, nodes)`。真值 logit 超出 ±8 的（obj 头，实测 -40..+10）
    在 sigmoid 上饱和到 0/1，数值无害（sigmoid(±8)=0.00034/0.99966）。
    这条是 C3/SigmoidUnit 文件头点名的"换刻度 = 换这张表"开口项的**免 RTL**落法。
"""
import math

SIG_IN_SCALE = 1.0 / 16.0          # Q3.4：1 个整数位 + 4 个小数位
SIG_IN_ZP = 0
SIG_OUT_SCALE = 1.0 / 127.0        # Q0.7：127·sigmoid ∈ [0,127]
SIG_OUT_ZP = 0


def _tensor_producer(nodes, name):
    for n in nodes:
        if name in n.output:
            return n
    return None


def sigmoid_chains(nodes):
    """→ [{sigmoid, producer_out, views, out}]：沿每个 Sigmoid 的输入回溯 Transpose/Reshape 到 Conv。"""
    out = []
    for n in nodes:
        if n.op_type != "Sigmoid":
            continue
        if not n.output or not n.output[0]:
            continue
        cur = n.input[0]
        views = []
        seen = set()
        while cur not in seen:
            seen.add(cur)
            p = _tensor_producer(nodes, cur)
            if p is None:
                break
            if p.op_type in ("Transpose", "Reshape"):
                views.append(cur)
                cur = p.input[0]
                continue
            if p.op_type == "Conv":
                out.append({"sigmoid": n.name, "producer_out": cur,
                            "views": list(views), "out": n.output[0]})
            break
    return out


def _set_affine(act, t, s, z):
    if t not in act:
        return False
    act[t]["scale"] = float(s)
    act[t]["zp"] = int(z)
    # lo/hi 与 (s,z) 自洽：码点 -128/127 对应的实数
    act[t]["lo"] = (-128 - z) * s
    act[t]["hi"] = (127 - z) * s
    return True


def apply_sigmoid_fix(act, nodes):
    """把 6 个 Sigmoid 的输入/输出刻度钉到冻结 LUT 的 Q3.4/Q0.7。返回链条清单。"""
    chains = sigmoid_chains(nodes)
    for ch in chains:
        for t in [ch["producer_out"]] + ch["views"]:
            _set_affine(act, t, SIG_IN_SCALE, SIG_IN_ZP)
        _set_affine(act, ch["out"], SIG_OUT_SCALE, SIG_OUT_ZP)
    return chains


def calib_nchw(img_path):
    """真图（0..255，BGR-raw）→ (1,3,H,W) float32，供 `quant_ref.Model(onnx, synth=...)`。"""
    import sys, os
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    import yunet_post as YP
    return YP.to_nchw(YP.preprocess_image(img_path))
