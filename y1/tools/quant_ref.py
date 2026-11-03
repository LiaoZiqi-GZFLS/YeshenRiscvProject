#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""quant_ref.py —— y1 C4a.2：**同口径 int8 整网参考**（G2/G3/G4 的黄金）。

本文件**逐字复用** `quant_ptq.py` 冻结的量化口径 —— 激活侧 affine（`calibrate / affine_params /
quant / dequant`）、**权重侧对称**（`weight_params / quant_weight / dequant_weight`，§4.5-A）——
与 requant 移位守卫（`SHIFT / require_shift`）—— 不另写一套量化器。
它也**复用** `ddr_traffic.GraphView` 的**算子顺序**（`GV.nodes`，即 ONNX 图节点序），
不自己重推算子序 —— 与 C3/C4 冻结表的层序同源。

============================================================================
Step 1：冻结参考的行为（逐字；要改走 spec 修订）
============================================================================
**输入**（本仓无代表性人脸图，2026-10-10 决策）
  · 确定性合成图：`np.random.default_rng(20261010).random((1,3,640,640), float32)`
    （U[0,1)，与真输入同 shape；真图属 C4b/G7）。**我们的 int8 参考与 ORT float 用同一张**。
  · 无真图 ⇒ 不写任何东西进 `third_party/`。

**校准**（自研 PTQ，逐字调 `quant_ptq`）
  · 对同一张合成图跑**一次 ORT float**，抓每个张量的 min/max（把全部中间张量临时加成
    graph.output，**只在内存里改**，不落盘）；
  · `calibrate` → `affine_params` 得每个激活张量的 `(scale, zp)`（min/max 口径，零值纳入）；
  · 权重：**对称量化**（§4.5-A，2026-10-11 裁决）—— 109 个 float32 initializer 里 53 个 Conv 权重
    逐个走 `weight_params`（`s_w = max|w|/127`、`z_w ≡ 0`）→ `quant_weight` 求 `w_q`。
    ★ 为什么权重对称：per-tensor **非对称**权重 zp 让"中心化权重" `w_q − z_w` 需 9 bit；
      对称（`z_w ≡ 0`）保 `w_q ∈ [−127,127]` 恰落 int8 ⇒ 硬件 MAC 维持 int8×int8。
    **激活仍走 affine**（`calibrate`/`affine_params`，零值纳入；`quant`/`dequant`）。
    非 NPU 常量按图的真实用法分类（见 §"initializer 分类"）。

**执行**：逐层按算子顺序执行 `Conv/Relu/MaxPool/Resize/Add/Sigmoid/Transpose/Reshape`；
张量一律 int8 + per-tensor affine `(s, z)`：`x ≈ (q - z)·s`。

**★ Q/DQ 位置（冻结，不插入额外 DQ）**
  · 累加 int32：`acc = Σ (x_q - z_x)·(w_q - z_w) + round(bias/(s_x·s_w))`
    （bias 落在"累加器单位"里：1 单位 = s_x·s_w）；
    ★ 权重对称 ⇒ `z_w ≡ 0`，上式退化为 `Σ (x_q - z_x)·w_q`（`w_q` 本身即中心化权重，恰落 int8）。
  · requant（**唯一**的层间缩放，整数、无浮点 DQ）：
        `y_q = clamp( ((acc · M) >> REQUANT_Q) >> SHIFT + z_y , -128, 127 )`
        `M    = round( (s_x·s_w / s_y) · 2^(SHIFT+REQUANT_Q) )`      # 每层 Q 格式乘子
        `SHIFT = 6`（冻结；逐层 `require_shift` 断言）  `REQUANT_Q = 24`
    ★ `>>SHIFT` 就是冻结的 requant 步；`>>REQUANT_Q` 是**乘子自身的 Q 格式**归一。
    ★ 为什么必须有乘子：纯 `acc >> 6` 只在 `s_x·s_w/s_y == 2^-6` 时成立；实测
      `s_x·s_w/s_y ≈ 2^-9`（层 0：`sx=1/255`、`sw≈3.9e-3`、`sy=2.167/255` ⇒ `ratio≈1.8e-3`），
      `>>6` 表达不了 ⇒ 纯移位版整网偏差 ≈100%、且中间层塌成常数（见报告 §11 的探针表）。
      乘子 + 移位是真实 NPU 的标准 requant 形式，仍是**纯整数**（无层间浮点 DQ）。
  · 所有算子（含旁路）都用**同一条** requant 折算到**输出张量**的 `(s_y, z_y)`。

**算子口径（逐条冻结）**
  · `Conv`：一般分组卷积（`GROUP=C` 即 depthwise 的特例）；`pads`/`strides` 按属性；
    零填充 = 填**代表实数 0 的码点 `z_x`**（affine 语义下"补 0"）；含 bias。
  · `Relu`：`max(实数, 0)` ⇒ 整数域 `max(q - z_x, 0)` 再 requant 到 `(s_y,z_y)`。
  · `MaxPool`：2×2/s2 **int8 取最大**（同刻度下 max 保序），再 requant 到 `(s_y,z_y)`。
  · `Resize`：`nearest`/`asymmetric`/`floor` ⇒ `src = floor(out/scale)`（= x2 最近邻逐位复制），再 requant。
  · `Add`：两路 affine 相加（两路刻度可不同，各自折算到 s_y 后求和），再 clamp。
  · `Sigmoid`：**256 项 int8→int8 查表**（与 C3 冻结 `bypass_ref.sigmoid_lut` 同形），
    表由本层的 affine A/D 现算：`lut[k] = quant(sigmoid(dequant(k-128, s_x, z_x)), s_y, z_y)`。
  · `Transpose` / `Reshape`：numpy（"折进寻址"是 C4a.7，**不在本任务**）。

**落盘**：每个节点输出张量 → `gen/c4a_ref/layers/NNN_<op>_<tensor>.npy`（gitignore）；
逐层 md5（**对 int8 原始字节**）+ 形状 + distinct + `max|ours - ORT_float|` →
`reports/c4a_ref_layers.json`（仓内）。

============================================================================
Step 2：判据（`run_quant_ref.sh` / `--gate`）
============================================================================
  1) **正对照**：整网跑完，**所有** graph 输出与"**第二实现**"（`conv_naive`：逐输出通道/抽头
     的独立实现，不用 im2col/matmul）**逐点一致** ⇒ `MISMATCH=0`；另在 `--selftest` 里用
     **朴素三重循环**（`conv_scalar`）交叉验证 `conv_vec`，把"朴素"这一条钉死。
  2) **与 float ORT 的容差**：逐层记 `max|ours - ORT_float|`（**只是记录，不是判据**；判据在 C4b/G7）。
  3) **负对照（有牙）**：把某层**激活** `zp` 改 1 ⇒ 该层起往后的中间张量 md5 必须变（`MD5_DIFF_LAYERS >= 1`）；
     不 flip（delta=0）⇒ `MD5_DIFF_LAYERS == 0`（证明这条判据不是橡皮章）。靶层取**激活**张量（`419` = 首层 Conv 输出）：
     权重对称后 `z_w ≡ 0`，权重 zp 不再可翻 ⇒ 负对照只能且确实落在激活侧。
  4) **退化守卫**：输入非常数、且末层输出 `distinct > 1`（防"全 0 也通过"）。

**initializer 分类（109 个 float32，逐类点名）**
  · `Conv.input[1]` 且形状 `[C_out, C_in/G, kh, kw]` ⇒ **NPU 权重**（int8 PTQ）。
  · `Conv.input[2]` 形状 `[C_out]` ⇒ **NPU bias**（浮点，落累加器单位）。
  · `Resize.input[2]` 形状 `[4]`（`W464/W465`）= 上采样 scales ⇒ **不量化**，当浮点常量用。
  · `Resize.input[1]` 形状 `[0]`（`W240`）= roi ⇒ 空张量，本口径不用。
  · int64 形状常量（`W290/W362/W395` = Reshape 的 shape）⇒ 非 float32，不是 NPU 张量。
  · `bbox_head.multi_level_obj.0.conv1.bias [1]` ⇒ 喂真 conv 的 bias ⇒ **是 NPU 张量**（按 bias 处理）。
  统计：53 权重 + 53 bias + `W240`(空) + `W464` + `W465` = 109。✓

用法（全仓唯一可用 Python 组合）：
    cd /d/code/PDS/VexiiYeshenLinux/y1
    PYTHONIOENCODING=utf-8 PYTHONPATH='./.pydeps;../third_party/yunet/deps' \
      <py> tools/quant_ref.py --selftest
    ... tools/quant_ref.py --gate [--dump]                       # 整网正对照 + 落盘 + JSON
    ... tools/quant_ref.py --zp-mutate <tensor> [--delta 1] [--base-json ...]   # 负对照
"""
import os
import sys
import json
import hashlib
import argparse

import numpy as np

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

# ---- 唯一真源（逐字复用）----
# 激活侧 affine：calibrate/affine_params/quant/dequant；权重侧对称：weight_params/quant_weight/dequant_weight（§4.5-A）
from quant_ptq import (calibrate, affine_params, quant, dequant,
                       weight_params, quant_weight, dequant_weight,
                       SHIFT, require_shift)

import onnx
from onnx import shape_inference, numpy_helper

# ---- 冻结件：复用它冻结的算子顺序（GV.nodes）----
import ddr_traffic

# ============================ 冻结常量 ============================
REQUANT_Q = 24          # 每层乘子 M 的额外 Q 格式小数位（M 的总小数位 = SHIFT+REQUANT_Q）
SEED = 20261010         # 确定性合成输入
DEFAULT_ONNX = os.path.abspath(os.path.join(_HERE, "..", "..", "third_party", "yunet", "yunet.onnx"))
DEFAULT_JSON = os.path.abspath(os.path.join(_HERE, "..", "reports", "c4a_ref_layers.json"))
DEFAULT_DUMP = os.path.abspath(os.path.join(_HERE, "..", "gen", "c4a_ref"))

# 负对照默认靶层（node 0 的输出；首层中段、码点分布健康）
DEFAULT_MUTATE = "419"

# 参考里**不量化**的 float32 initializer（按图的真实用法）
NON_NPU_FLOAT = {"240": "Resize roi (shape=[0], empty -> unused)",
                 "464": "Resize scales [4] -> upsample ratio for Resize_43",
                 "465": "Resize scales [4] -> upsample ratio for Resize_49"}


def synth_input(shape):
    """确定性合成输入（冻结决策：仓内无代表性人脸图 ⇒ 用定 seed 的 U[0,1) 图，两路共用）。"""
    return np.random.default_rng(SEED).random(size=tuple(shape), dtype=np.float32)


def md5_bytes(b):
    return hashlib.md5(b).hexdigest()


def md5_file(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for blk in iter(lambda: fh.read(65536), b""):
            h.update(blk)
    return h.hexdigest()


def attr_ints(node, key, dflt=None):
    for a in node.attribute:
        if a.name == key:
            return list(a.ints)
    return dflt


def attr_str(node, key, dflt=None):
    for a in node.attribute:
        if a.name == key:
            return a.s.decode()
    return dflt


def attr_int(node, key, dflt=None):
    for a in node.attribute:
        if a.name == key:
            return a.i
    return dflt


# ============================ requant（冻结形式） ============================
def scale_ratio_multiplier(ratio):
    """每层 Q 格式乘子：`M = round(ratio · 2^(SHIFT+REQUANT_Q))`（ratio 见文件头）。"""
    return int(round(float(ratio) * (1 << (SHIFT + REQUANT_Q))))


def requant_int(v, M, z_out):
    """冻结 requant：`clamp( ((v·M) >> REQUANT_Q) >> SHIFT + z_out, -128, 127 )`（算术右移）。"""
    y = ((np.asarray(v, dtype=np.int64) * np.int64(M)) >> REQUANT_Q) >> SHIFT
    return np.clip(y + np.int64(z_out), -128, 127).astype(np.int8)


def requant_shift_only(v, z_out):
    """**诊断用**：纯 `>>SHIFT`（无乘子）—— 证明"纯移位表达不了标定出的 scale 比"（报告 §11）。"""
    y = np.asarray(v, dtype=np.int64) >> SHIFT
    return np.clip(y + np.int64(z_out), -128, 127).astype(np.int8)


# ============================ 模型 / 校准 ============================
class Model(object):
    """把 ONNX 图、initializer、校准参数、算子顺序打包（算子序取自 ddr_traffic.GraphView）。"""

    def __init__(self, onnx_path, synth=None):
        self.onnx_path = onnx_path
        self.md5 = md5_file(onnx_path)
        self.m = onnx.load(onnx_path)
        self.mi = shape_inference.infer_shapes(self.m)
        self.g = self.mi.graph
        self.init = {i.name: numpy_helper.to_array(i) for i in self.g.initializer}
        self.input_name = self.g.input[0].name
        self.input_shape = [d.dim_value for d in self.g.input[0].type.tensor_type.shape.dim]
        self.output_names = [o.name for o in self.g.output]
        # 算子顺序 = ddr_traffic.GraphView 的节点序（冻结件），不自己重推
        self.gv = ddr_traffic.GraphView(onnx_path)
        self.nodes = list(self.gv.nodes)
        assert [n.name for n in self.nodes] == [n.name for n in self.g.node], \
            "ddr_traffic.GraphView.nodes 与 ONNX 图节点序不一致"
        # 输入（两路共用）
        self.x_float = synth_input(self.input_shape) if synth is None else synth
        self.ort = self._run_ort_float()

    # ---- 一次 ORT float，抓全部中间张量（只改内存里的 ModelProto）----
    def _run_ort_float(self):
        import onnxruntime as ort
        m2 = onnx.ModelProto()
        m2.CopyFrom(self.mi)
        del m2.graph.output[:]
        for v in list(self.g.value_info) + list(self.g.output):
            if v.name in self.init:
                continue
            o = m2.graph.output.add()
            o.name = v.name
            o.type.CopyFrom(v.type)
        so = ort.SessionOptions()
        so.log_severity_level = 3
        sess = ort.InferenceSession(m2.SerializeToString(), so, providers=["CPUExecutionProvider"])
        out = sess.run(None, {self.input_name: self.x_float})
        return {nm: np.asarray(v) for nm, v in zip([o.name for o in m2.graph.output], out)}

    # ---- 校准：激活 (s,z) + 权重 (s,z,w_q) + bias + Resize scales + Reshape shape ----
    def build_params(self):
        act = {}
        for name, v in self.ort.items():
            lo, hi = calibrate(v)
            act[name] = {"lo": lo, "hi": hi, "scale": None, "zp": None}
        lo, hi = calibrate(self.x_float)
        act[self.input_name] = {"lo": lo, "hi": hi, "scale": None, "zp": None}
        for name in act:
            s, z = affine_params(act[name]["lo"], act[name]["hi"])
            act[name]["scale"], act[name]["zp"] = s, z

        weights, biases, rsz_scales, reshape_shape = {}, {}, {}, {}
        classified = []
        for name, arr in self.init.items():
            cons = [(i, self.nodes[i]) for i in range(len(self.nodes)) if name in self.nodes[i].input]
            if arr.dtype != np.float32:
                classified.append((name, "int64 常量（Reshape shape）— 非 NPU 张量", list(arr.shape)))
                if cons and cons[0][1].op_type == "Reshape":
                    reshape_shape[name] = [int(v) for v in arr]
                continue
            optype = cons[0][1].op_type if cons else "?"
            idx_of = list(cons[0][1].input).index(name) if cons else -1
            if optype == "Resize" and idx_of == 2:
                rsz_scales[name] = np.asarray(arr, dtype=np.float64)
                classified.append((name, "Resize scales — 不量化（浮点常量）", list(arr.shape)))
            elif optype == "Resize":
                classified.append((name, "Resize roi — 空/不用", list(arr.shape)))
            elif optype == "Conv" and idx_of == 1:
                # 权重侧对称量化（§4.5-A）：z_w ≡ 0、s_w = max|w|/127 ⇒ w_q 恰落 int8。
                s, z = weight_params(arr)
                weights[name] = {"scale": s, "zp": z, "q": quant_weight(arr, s), "float": arr}
                classified.append((name, "NPU 权重（Conv.input[1]，对称 z_w≡0 / §4.5-A）", list(arr.shape)))
            elif optype == "Conv" and idx_of == 2:
                biases[name] = np.asarray(arr, dtype=np.float64)
                classified.append((name, "NPU bias（Conv.input[2]）", list(arr.shape)))
            else:
                raise SystemExit("FATAL: 未分类的 float32 initializer %s（consumers=%s）"
                                 % (name, [(n.op_type, i) for i, n in cons]))
        self.act, self.weights, self.biases = act, weights, biases
        self.rsz_scales, self.reshape_shape = rsz_scales, reshape_shape
        self.classified = classified


# ============================ 算子实现 ============================
# --- Conv：向量化（im2col + matmul）---
def conv_vec(xq, w, sx, sy, zw, xy, biasp, pads, strides, group, zy):
    pt, pl, pb, pr = pads
    sh, sw = strides
    CI, H, W = xq.shape[1], xq.shape[2], xq.shape[3]
    CO, CG, KH, KW = w["q"].shape
    Ho, Wo = (H + pt + pb - KH) // sh + 1, (W + pl + pr - KW) // sw + 1
    xc = xq.astype(np.int64) - np.int64(xy)                       # 补 0 = 补"实数 0 的码点"
    xp = np.pad(xc, ((0, 0), (0, 0), (pt, pb), (pl, pr)), constant_values=0)
    out = np.zeros((CO, Ho, Wo), dtype=np.int64)
    cog, cig = CO // group, CI // group
    for gi in range(group):
        cols = np.zeros((cig * KH * KW, Ho * Wo), dtype=np.int64)
        k = 0
        for ci in range(cig):
            ca = gi * cig + ci
            for ky in range(KH):
                for kx in range(KW):
                    cols[k] = xp[0, ca, ky:ky + sh * Ho:sh, kx:kx + sw * Wo:sw].reshape(-1)
                    k += 1
        wm = w["q"][gi * cog:(gi + 1) * cog].reshape(cog, -1).astype(np.int64) - np.int64(zw)
        acc = wm @ cols
        if biasp is not None:
            b = biasp[gi * cog:(gi + 1) * cog]
            acc = acc + np.round(b[:, None] / (sx * w["scale"])).astype(np.int64)
        out[gi * cog:(gi + 1) * cog] = acc.reshape(cog, Ho, Wo)
    M = scale_ratio_multiplier((sx * w["scale"]) / sy)
    return requant_int(out, M, zy).reshape(1, CO, Ho, Wo)


# --- Conv：逐输出通道/抽头的独立实现（第二实现；不用 im2col/matmul）---
def conv_naive(xq, w, sx, sy, zw, xy, biasp, pads, strides, group, zy):
    pt, pl, pb, pr = pads
    sh, sw = strides
    CI, H, W = xq.shape[1], xq.shape[2], xq.shape[3]
    CO, CG, KH, KW = w["q"].shape
    Ho, Wo = (H + pt + pb - KH) // sh + 1, (W + pl + pr - KW) // sw + 1
    xc = xq.astype(np.int64) - np.int64(xy)
    xp = np.pad(xc, ((0, 0), (0, 0), (pt, pb), (pl, pr)), constant_values=0)
    cog, cig = CO // group, CI // group
    ratio = (sx * w["scale"]) / sy
    M = scale_ratio_multiplier(ratio)
    out = np.zeros((1, CO, Ho, Wo), dtype=np.int8)
    wq = w["q"].astype(np.int64)
    for co in range(CO):
        gi = co // cog
        acc = np.zeros((Ho, Wo), dtype=np.int64)
        for cil in range(cig):
            ca = gi * cig + cil
            for ky in range(KH):
                for kx in range(KW):
                    acc += (wq[co, cil, ky, kx] - np.int64(zw)) * \
                        xp[0, ca, ky:ky + sh * Ho:sh, kx:kx + sw * Wo:sw]
        if biasp is not None:
            acc += int(round(float(biasp[co]) / (sx * w["scale"])))
        out[0, co] = requant_int(acc, M, zy)
    return out


# --- Conv：朴素三重循环（纯 Python；只给 --selftest 的小张量交叉验证用）---
def conv_scalar(xq, w, sx, sy, zw, xy, biasp, pads, strides, group, zy):
    pt, pl, pb, pr = pads
    sh, sw = strides
    CI, H, W = xq.shape[1], xq.shape[2], xq.shape[3]
    CO, CG, KH, KW = w["q"].shape
    Ho, Wo = (H + pt + pb - KH) // sh + 1, (W + pl + pr - KW) // sw + 1
    xl = xq[0].astype(np.int64).tolist()
    wl = w["q"].tolist()
    cog, cig = CO // group, CI // group
    M = scale_ratio_multiplier((sx * w["scale"]) / sy)
    out = np.zeros((1, CO, Ho, Wo), dtype=np.int8)
    for co in range(CO):
        gi = co // cog
        for y in range(Ho):
            for x in range(Wo):
                acc = 0
                for cil in range(cig):
                    ca = gi * cig + cil
                    for ky in range(KH):
                        iy = y * sh + ky - pt
                        if iy < 0 or iy >= H:
                            continue
                        for kx in range(KW):
                            ix = x * sw + kx - pl
                            if ix < 0 or ix >= W:
                                continue
                            acc += (wl[co][cil][ky][kx] - zw) * (xl[ca][iy][ix] - xy)
                if biasp is not None:
                    acc += int(round(float(biasp[co]) / (sx * w["scale"])))
                v = ((acc * M) >> REQUANT_Q) >> SHIFT
                out[0, co, y, x] = max(-128, min(127, v + zy))
    return out


def sigmoid_lut(sx, zx, sy, zy):
    """256 项 int8→int8 表：`lut[k] = quant(sigmoid(dequant(k-128, sx, zx)), sy, zy)`。"""
    codes = np.arange(-128, 128, dtype=np.float64)
    z = dequant(codes.astype(np.int8), sx, zx)
    return quant(1.0 / (1.0 + np.exp(-z)), sy, zy)


# ============================ 整网执行 ============================
def run_net(M, params, naive=False, zp_mutate=None, delta=0, dump_dir=None, fault=None):
    """按算子顺序跑完整网；返回 (tensors, records)。

    naive=True 走**第二实现**（conv_naive + 显式循环的旁路算子）；否则走向量化实现。
    zp_mutate: 该张量的 zp 加 `delta`（负对照）；dump_dir: 每个节点输出落 .npy。
    fault: 故障注入（只作用向量化路径）—— 让第 N 个 Conv 的 requant 偏 1 个码点，
           用于证明"向量化 vs 第二实现"这条判据**能被打红**（橡皮章反证）。
    """
    act, weights, biases = params["act"], params["weights"], params["biases"]
    rsz, rshape = params["rsz_scales"], params["reshape_shape"]

    def P(name):
        """该张量的 affine 参数（**未变异**：消费侧一致地用真值）。"""
        return act[name]["scale"], act[name]["zp"]

    def ZY(name):
        """该张量**被写入时**用的 zero-point。负对照只改这里（= 生产者把码点写偏 1），
        消费侧仍用真 `z` ⇒ 实数整体偏 `delta·s` ⇒ **真正向下游传播**（不是同改同消的恒等）。"""
        z = act[name]["zp"]
        if zp_mutate is not None and name == zp_mutate:
            z = max(-128, min(127, z + delta))
        return z

    T = {M.input_name: quant(M.x_float, *P(M.input_name))}
    records = []

    for idx, n in enumerate(M.nodes):
        op = n.op_type
        outs = [x for x in n.output if x]
        if op == "Conv":
            x = T[n.input[0]]
            sx, zx = P(n.input[0])
            sy, _ = P(outs[0])
            zy = ZY(outs[0])
            w = dict(weights[n.input[1]])
            zw = w["zp"]
            biasp = biases.get(n.input[2]) if len(n.input) > 2 else None
            grp = attr_int(n, "group", 1)
            pads = attr_ints(n, "pads", [0, 0, 0, 0])
            strides = attr_ints(n, "strides", [1, 1])
            if naive:
                y = conv_naive(x, w, sx, sy, zw, zx, biasp, pads, strides, grp, zy)
            else:
                y = conv_vec(x, w, sx, sy, zw, zx, biasp, pads, strides, grp, zy)
                if fault is not None and idx == fault:
                    y = np.clip(y.astype(np.int32) + 1, -128, 127).astype(np.int8)   # 故障注入
            T[outs[0]] = y
            require_shift(n.name, SHIFT)
        elif op == "Relu":
            x = T[n.input[0]]
            sx, zx = P(n.input[0])
            sy, _ = P(outs[0])
            zy = ZY(outs[0])
            M_ = scale_ratio_multiplier(sx / sy)
            v = np.maximum(x.astype(np.int64) - np.int64(zx), 0)
            T[outs[0]] = requant_int(v, M_, zy)
        elif op == "MaxPool":
            x = T[n.input[0]]
            sx, zx = P(n.input[0])
            sy, _ = P(outs[0])
            zy = ZY(outs[0])
            sh, sw = attr_ints(n, "strides", [2, 2])
            KH, KW = attr_ints(n, "kernel_shape", [2, 2])
            C, H, W = x.shape[1:]
            Ho, Wo = H // sh, W // sw
            if naive:
                y = np.zeros((1, C, Ho, Wo), dtype=np.int8)
                for c in range(C):
                    for yy in range(Ho):
                        for xx in range(Wo):
                            m = -128
                            for dy in range(KH):
                                for dx in range(KW):
                                    v = int(x[0, c, yy * sh + dy, xx * sw + dx])
                                    if v > m:
                                        m = v
                            y[0, c, yy, xx] = m
            else:
                y = x.reshape(1, C, Ho, sh, Wo, sw).max(axis=(3, 5)).astype(np.int8)
            M_ = scale_ratio_multiplier(sx / sy)
            T[outs[0]] = requant_int(y.astype(np.int64) - np.int64(zx), M_, zy)
        elif op == "Resize":
            x = T[n.input[0]]
            sc = rsz[n.input[2]]
            sx, zx = P(n.input[0])
            sy, _ = P(outs[0])
            zy = ZY(outs[0])
            C, H, W = x.shape[1:]
            Ho, Wo = int(H * float(sc[2])), int(W * float(sc[3]))
            M_ = scale_ratio_multiplier(sx / sy)
            if naive:
                y = np.zeros((1, C, Ho, Wo), dtype=np.int8)
                for c in range(C):
                    for Y in range(Ho):
                        sy_ = int(Y // float(sc[2]))
                        for X in range(Wo):
                            y[0, c, Y, X] = x[0, c, sy_, int(X // float(sc[3]))]
            else:
                yi = (np.arange(Ho) // float(sc[2])).astype(np.int64)
                xi = (np.arange(Wo) // float(sc[3])).astype(np.int64)
                y = x[:, :, yi][:, :, :, xi]
            T[outs[0]] = requant_int(y.astype(np.int64) - np.int64(zx), M_, zy)
        elif op == "Add":
            a, b = T[n.input[0]], T[n.input[1]]
            sa, za = P(n.input[0])
            sb, zb = P(n.input[1])
            sy, _ = P(outs[0])
            zy = ZY(outs[0])
            Ma = scale_ratio_multiplier(sa / sy)
            Mb = scale_ratio_multiplier(sb / sy)
            va = (a.astype(np.int64) - np.int64(za)) * np.int64(Ma)
            vb = (b.astype(np.int64) - np.int64(zb)) * np.int64(Mb)
            s = ((va + vb) >> REQUANT_Q) >> SHIFT
            T[outs[0]] = np.clip(s + np.int64(zy), -128, 127).astype(np.int8)
        elif op == "Sigmoid":
            x = T[n.input[0]]
            sx, zx = P(n.input[0])
            sy, _ = P(outs[0])
            zy = ZY(outs[0])
            lut = sigmoid_lut(sx, zx, sy, zy)
            idxr = (x.astype(np.int64) + 128)
            if naive:
                flat = [int(lut[int(k)]) for k in idxr.reshape(-1).tolist()]
                T[outs[0]] = np.array(flat, dtype=np.int8).reshape(x.shape)
            else:
                T[outs[0]] = lut[idxr].reshape(x.shape).astype(np.int8)
        elif op == "Transpose":
            x = T[n.input[0]]
            perm = attr_ints(n, "perm", [0, 2, 3, 1])
            if naive:
                T[outs[0]] = np.array(np.transpose(x, perm).tolist(), dtype=np.int8)
            else:
                T[outs[0]] = np.transpose(x, perm).copy()
        elif op == "Reshape":
            x = T[n.input[0]]
            want = list(rshape[n.input[1]])
            shp = []
            for i, v in enumerate(want):
                if v == 0:
                    shp.append(x.shape[i])
                elif v == -1:
                    shp.append(-1)
                else:
                    shp.append(int(v))
            T[outs[0]] = x.reshape(shp).copy()
        else:
            raise SystemExit("FATAL: 未实现的算子 %s（%s）" % (op, n.name))

        y = T[outs[0]]
        rec = {"idx": idx, "op": op, "name": n.name, "tensor": outs[0],
               "shape": list(y.shape), "nbytes": int(y.nbytes),
               "md5": md5_bytes(np.ascontiguousarray(y).tobytes()),
               "distinct": int(len(np.unique(y)))}
        if outs[0] in M.ort:
            s, z = act[outs[0]]["scale"], act[outs[0]]["zp"]
            ref = dequant(y, s, z).reshape(-1)
            ov = np.asarray(M.ort[outs[0]], dtype=np.float64).reshape(-1)
            dev = float(np.max(np.abs(ref - ov))) if ov.size else 0.0
            rng = act[outs[0]]["hi"] - act[outs[0]]["lo"]
            rec["ort_max_abs_dev"] = dev
            rec["layer_range"] = rng
            rec["ort_dev_pct_of_range"] = 100.0 * dev / rng if rng > 0 else 0.0
        records.append(rec)
        if dump_dir:
            os.makedirs(dump_dir, exist_ok=True)
            np.save(os.path.join(dump_dir, "%03d_%s_%s.npy" % (idx, op, outs[0])), y)
    return T, records


def run_net_both(M, params, dump_dir=None):
    """向量化 + 第二实现各跑一遍；返回 (T_vec, rec_vec, T_naive, mism)。"""
    Tv, rv = run_net(M, params, naive=False, dump_dir=dump_dir)
    Tn, rn = run_net(M, params, naive=True)
    mism = {}
    for name in M.output_names:
        mism[name] = int(np.count_nonzero(Tv[name] != Tn[name]))
    return Tv, rv, Tn, mism


# ============================ --selftest（小张量：三重循环 vs 向量化） ============================
def selftest():
    print("[quant_ref] selftest：冻结件复用 + requant 口径 + 朴素三重循环交叉验证")
    fails = []

    def chk(cond, msg):
        print("  %s  %s" % ("PASS" if cond else "FAIL", msg))
        if not cond:
            fails.append(msg)

    # 0) requant 口径：算术右移 + clamp
    chk(int(((np.int64(-1) * 1) >> REQUANT_Q) >> SHIFT) == -1, "算术右移：-1 不变号（不是逻辑右移）")
    v = np.array([10 ** 9, -10 ** 9], dtype=np.int64)
    full = 1 << (SHIFT + REQUANT_Q)          # ratio == 1 ⇒ 乘子 M = 2^(SHIFT+REQUANT_Q)
    chk(list(requant_int(v, full, 0)) == [127, -128], "requant 大数照样 clamp 到 int8")
    chk(scale_ratio_multiplier(2.0 ** -SHIFT) == (1 << REQUANT_Q),
        "M(ratio=2^-SHIFT) == 2^REQUANT_Q（乘子 Q 格式自洽）")

    # 1) 三重循环 == 向量化（大/小、dense/depthwise/group）
    rng = np.random.default_rng(7)
    cases = [(3, 4, 5, 7, 1, [1, 1, 1, 1], [1, 1]),
             (2, 2, 4, 4, 2, [1, 1, 1, 1], [1, 1]),
             (4, 4, 3, 6, 4, [1, 1, 1, 1], [1, 1]),
             (2, 3, 5, 5, 1, [0, 0, 0, 0], [1, 1])]
    for (ci, co, hh, ww, gg, pads, strides) in cases:
        xq = quant(rng.normal(0, 1, (1, ci, hh, ww)), 0.05, -3)
        wf = rng.normal(0, 0.2, (co, ci // gg, 3, 3))
        sw, zw = weight_params(wf)                       # 权重对称（§4.5-A）：zw≡0
        wd = {"q": quant_weight(wf, sw), "scale": sw, "zp": zw}
        bias = rng.normal(0, 0.1, co)
        sx, sy = 0.05, 0.04
        a = conv_vec(xq, wd, sx, sy, zw, -3, bias, pads, strides, gg, -6)
        b = conv_naive(xq, wd, sx, sy, zw, -3, bias, pads, strides, gg, -6)
        c = conv_scalar(xq, wd, sx, sy, zw, -3, bias, pads, strides, gg, -6)
        nd_vec_naive = int(np.count_nonzero(a.reshape(-1) != b.reshape(-1)))
        nd_naive_scalar = int(np.count_nonzero(b.reshape(-1) != c.reshape(-1)))
        chk(nd_vec_naive == 0 and nd_naive_scalar == 0,
            "ci=%d co=%d %dx%d g=%d pads=%s：im2col==抽头循环==三重循环（差 %d / %d）"
            % (ci, co, hh, ww, gg, pads, nd_vec_naive, nd_naive_scalar))
    # 权重侧对称（§4.5-A）：黄金里权重 zp 恒 0、s_w=max|w|/127、w_q 恰落 int8、roundtrip ≤ s_w/2（改回 affine 即红）
    _wf = rng.normal(0, 0.2, (4, 3, 3, 3))
    _sw, _zw = weight_params(_wf)
    _wq = quant_weight(_wf, _sw).astype(np.int64)
    _werr = float(np.max(np.abs(_wf - dequant_weight(_wq, _sw))))
    chk(_zw == 0 and _sw > 0.0 and int(np.max(np.abs(_wq))) <= 127 and _werr <= _sw / 2.0,
        "权重对称（§4.5-A）：z_w=0、s_w=max|w|/127、w_q∈[-127,127]、roundtrip≤s_w/2")

    # 朴素三重循环真的动了（不是恒等）
    xq = quant(rng.normal(0, 1, (1, 2, 4, 4)), 0.05, -3)
    wf = rng.normal(0, 0.2, (2, 2, 3, 3))
    sw, zw = weight_params(wf)                           # 权重对称（§4.5-A）：zw≡0
    wd = {"q": quant_weight(wf, sw), "scale": sw, "zp": zw}
    chk(len(np.unique(conv_scalar(xq, wd, 0.05, 0.04, zw, -3, None, [1, 1, 1, 1], [1, 1], 1, -6))) > 1,
        "朴素三重循环输出非常数（判据有分辨率）")

    # 2) Sigmoid 表：256 项、单调不减、与冻结公式逐项一致（输出码点落在该张量自己的 affine 刻度上）
    sx_, zx_, sy_, zy_ = 0.02, -10, 0.004, -128
    lut = sigmoid_lut(sx_, zx_, sy_, zy_)
    codes = np.arange(-128, 128, dtype=np.int64)
    ref = quant(1.0 / (1.0 + np.exp(-dequant(codes.astype(np.int8), sx_, zx_))), sy_, zy_)
    chk(len(lut) == 256 and all(-128 <= int(v) <= 127 for v in lut),
        "Sigmoid 表 256 项、值在 int8 内")
    chk(all(int(lut[i]) <= int(lut[i + 1]) for i in range(255)), "Sigmoid 表单调不减")
    chk(int(np.count_nonzero(lut != ref)) == 0, "Sigmoid 表 == quant(sigmoid(dequant(x))) 逐项")
    chk(len(np.unique(lut)) > 1, "Sigmoid 表非常数（判据有分辨率）")

    if fails:
        print("SELFTEST_REF: FAIL (%d)" % len(fails))
        print("RESULT: FAIL")
        return 1
    print("SELFTEST_REF: PASS")
    print("RESULT: PASS")
    return 0


# ============================ --gate / --zp-mutate ============================
def _fmt_rec(rec):
    if "ort_max_abs_dev" in rec:
        return "dev=%.4g (%.2f%% of range)" % (rec["ort_max_abs_dev"], rec["ort_dev_pct_of_range"])
    return "dev=n/a"


def do_gate(args):
    M = Model(args.onnx)
    M.build_params()
    print("REF model=%s md5=%s" % (os.path.basename(M.onnx_path), M.md5))
    print("REF input=%s shape=%s (synthetic seed=%d, U[0,1)) md5=%s"
          % (M.input_name, M.input_shape, SEED, md5_bytes(np.ascontiguousarray(M.x_float).tobytes())))
    print("REF nodes=%d float32_init_weights=%d biases=%d resize_scales=%d"
          % (len(M.nodes), len(M.weights), len(M.biases), len(M.rsz_scales)))
    for nm, why, shp in sorted(M.classified):
        print("REF init %-52s %-42s shape=%s" % (nm, why, shp))

    # 1) 正对照：向量化 vs 第二实现
    dump = DEFAULT_DUMP if args.dump else None
    if dump:
        os.makedirs(dump, exist_ok=True)
    Tv, recs, Tn, mism = run_net_both(M, _params_of(M), dump_dir=dump)
    total_mism = sum(mism.values())
    for name in M.output_names:
        print("REF mismatch %-10s = %d" % (name, mism[name]))

    # 4) 退化守卫
    in_distinct = int(len(np.unique(Tv[M.input_name])))
    last = M.nodes[-1].output[0]
    last_distinct = int(len(np.unique(Tv[last])))
    print("GUARD input_distinct=%d lastlayer=%s lastlayer_distinct=%d" % (in_distinct, last, last_distinct))

    # 2) 逐层 ORT 偏差（记录）
    devs = [(r["idx"], r["tensor"], r["ort_max_abs_dev"], r["ort_dev_pct_of_range"])
            for r in recs if "ort_max_abs_dev" in r]
    worst = max(devs, key=lambda t: t[3])
    worst_abs = max(devs, key=lambda t: t[2])
    print("ORT_DEV layers_recorded=%d worst_pct_layer=%s(%d) pct_of_range=%.2f%%"
          % (len(devs), worst[1], worst[0], worst[3]))
    print("ORT_DEV worst_abs_layer=%s(%d) max_abs_dev=%.6g pct_of_range=%.2f%%"
          % (worst_abs[1], worst_abs[0], worst_abs[2], worst_abs[3]))

    # 3a) 判据分辨度：给向量化路径注入 1 个码点的故障 ⇒ MISMATCH 必须 > 0（橡皮章反证）
    fault_idx = next(i for i, n in enumerate(M.nodes) if n.op_type == "Conv")
    Tf, _ = run_net(M, _params_of(M), naive=False, fault=fault_idx)
    fault_mism = sum(int(np.count_nonzero(Tf[nm] != Tn[nm])) for nm in M.output_names)
    print("FAULT_MISMATCH=%d (inject +1 code at conv idx=%d => judge can go red)"
          % (fault_mism, fault_idx))

    # 3b) 权重指纹（对称口径 §4.5-A）：逐 Conv 权重的 int8 字节 md5 + 聚合 md5（换口径必变）
    wfps = []
    for nm in sorted(M.weights):
        w = M.weights[nm]
        b = np.ascontiguousarray(w["q"]).tobytes()
        wfps.append({"name": nm, "shape": list(w["q"].shape), "nbytes": len(b),
                     "md5": md5_bytes(b), "scale": float(w["scale"]), "zp": int(w["zp"])})
    w_agg = md5_bytes("".join("%s:%s" % (x["name"], x["md5"]) for x in wfps).encode("ascii"))
    print("WEIGHT_MD5 count=%d all_symmetric=%s aggregate=%s"
          % (len(wfps), int(all(x["zp"] == 0 for x in wfps)), w_agg))

    # 落盘 JSON + 中间张量
    payload = {
        "artifact": os.path.basename(DEFAULT_JSON),
        "frozen": {"SHIFT": SHIFT, "REQUANT_Q": REQUANT_Q, "seed": SEED,
                   "input_shape": M.input_shape, "onnx": M.onnx_path, "onnx_md5": M.md5,
                   "quant_ptq_md5": md5_file(os.path.join(_HERE, "quant_ptq.py")),
                   "quant_ref_md5": md5_file(os.path.abspath(__file__)),
                   "calibration": "min/max + zero-inclusion (quant_ptq.affine_params)",
                   "activation_quant": "affine (calibrate/affine_params + quant/dequant+zero-inclusion)",
                   "weight_quant": "symmetric z_w=0, scale=max|w|/127 (quant_ptq.weight_params, §4.5-A)",
                   "requant": "(acc * M) >> REQUANT_Q >> SHIFT, M=round(ratio*2^(SHIFT+REQUANT_Q))",
                   "input": "deterministic synthetic U[0,1), seed=%d (no representative image in repo)" % SEED},
        "initializer_classification": [{"name": nm, "role": why, "shape": shp}
                                       for nm, why, shp in sorted(M.classified)],
        "weights": {"count": len(wfps), "all_symmetric": bool(all(x["zp"] == 0 for x in wfps)),
                    "aggregate_md5": w_agg, "list": wfps},
        "layers": recs,
        "summary": {
            "nodes": len(M.nodes), "layers_dumped": len(recs),
            "final_mismatch_total": total_mism,
            "final_mismatch_per_output": mism,
            "input_distinct": in_distinct, "lastlayer": last, "lastlayer_distinct": last_distinct,
            "ort_dev_recorded": len(devs),
            "ort_dev_worst_layer": worst[1], "ort_dev_worst_pct_of_range": worst[3],
            "weights_count": len(wfps), "weights_aggregate_md5": w_agg,
        },
    }
    json_path = args.json
    with open(json_path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1, sort_keys=False)
    print("JSON %s bytes=%d md5=%s" % (json_path, os.path.getsize(json_path),
                                       md5_file(json_path)))
    if dump:
        print("DUMP dir=%s files=%d" % (dump, len(os.listdir(dump))))

    ok = (total_mism == 0) and (in_distinct > 1) and (last_distinct > 1)
    print("MISMATCH=%d" % total_mism)
    print("REF_RESULT: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def _params_of(M):
    return {"act": M.act, "weights": M.weights, "biases": M.biases,
            "rsz_scales": M.rsz_scales, "reshape_shape": M.reshape_shape}


def do_zp_mutate(args):
    """负对照：把某张量的 zp 加 delta，逐层 md5 与基线 JSON 对账。"""
    M = Model(args.onnx)
    M.build_params()
    base_md5 = {}
    bjson = args.base_json or args.json
    if bjson and os.path.isfile(bjson):
        with open(bjson, encoding="utf-8") as fh:
            for r in json.load(fh)["layers"]:
                base_md5[r["tensor"]] = r["md5"]
    T, recs = run_net(M, _params_of(M), naive=False,
                      zp_mutate=args.zp_mutate, delta=args.delta)
    diffs = [r for r in recs if base_md5.get(r["tensor"]) not in (None, r["md5"])]
    first = diffs[0]["idx"] if diffs else -1
    print("ZP_MUTATE tensor=%s delta=%+d" % (args.zp_mutate, args.delta))
    print("MD5_DIFF_LAYERS=%d" % len(diffs))
    print("MD5_FIRST_DIFF_IDX=%d" % first)
    print("MD5_TOTAL_LAYERS=%d" % len([r for r in recs if r["tensor"] in base_md5]))
    for r in diffs[:6]:
        print("ZP_DIFF idx=%d op=%s tensor=%s" % (r["idx"], r["op"], r["tensor"]))
    print("REF_RESULT: PASS")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--onnx", default=DEFAULT_ONNX)
    ap.add_argument("--json", default=DEFAULT_JSON)
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--gate", action="store_true")
    ap.add_argument("--dump", action="store_true")
    ap.add_argument("--zp-mutate", default=None)
    ap.add_argument("--delta", type=int, default=1)
    ap.add_argument("--base-json", default=None)
    args = ap.parse_args(argv[1:])
    if args.selftest:
        return selftest()
    if not os.path.isfile(args.onnx):
        print("FATAL: ONNX 不存在: %s" % args.onnx, file=sys.stderr)
        return 3
    if args.zp_mutate:
        return do_zp_mutate(args)
    if args.gate:
        return do_gate(args)
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
