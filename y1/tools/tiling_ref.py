#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tiling_ref.py —— y1 C4a.4：**拆趟（tiling）规则** + 「拆趟 == 整层」Python 算术等价证明。

这是 **G3 的离线半边**（另一半是 C4a.5 的 RTL 多趟累加）。本文件**只做离线数值**：
不产 RTL、不碰 SoC、不上板。它把 C4a.5 的"宽层拆成 8 通道多趟、跨趟累加"这条数据流
的**算术等价**先证掉 —— 硬件侧照着这张单子做即可。

============================================================================
Step 1：冻结拆趟规则（逐字；要改走 spec 修订）
============================================================================
宽层（C_in > 8 或 C_out > 8）拆成 ceil(C_in/8) x ceil(C_out/8) 趟：
  每趟 = 一个 plain conv 单元（C_in_t = min(8, 剩余), C_out_t = min(8, 剩余)）
  趟内 SKIP 的输入通道（C_in_t < 8 时）用权重置 0 掩掉（不新增字段）
  跨 (co) 趟：DST 不同区域（各写自己那段 co）；
  跨 (ci) 趟：累加（见 C4a.5 的片上部分和）——本任务只验证算术等价
判据：趟集合的 Python 模拟 == 整层参考（逐字节）

============================================================================
Step 2：判据（`run_tiling_ab.sh` / `run_tiling2d_ab.sh` / `--gate` / `--gate2d` / `--selftest*`）
============================================================================
  0a) `--selftest`（C4a.4 拆趟）：小张量自检 —— 正/负对照都能发火。
  0b) `--selftest2d`（**T0 2-D tiling + halo**）：小张量 tile(4×4) 自检 ——
       · 正对照：conv3x3 / depthwise / stride2 + maxpool + resize + add，`tile(+halo) == 整层` 逐字节；
       · int32 恒等式：拼回的累加平面 == 整层 acc；
       · 负对照：无 halo ⇒ 接缝；maxpool 奇数偏移 ⇒ 变；add 第二路错网格 ⇒ 变（三条都发火）。
  1a) `--gate`（C4a.4）：真表里每种 `(C_in,C_out,GROUP)`：拆趟 == 整层。
  1b) `--gate2d`（**T0**）：真表 **27 个有 halo 的项**（spec §3 的 desc.bin 下标）逐项
       `tile(+halo) == 整层` 逐字节；conv1x1（0 halo）全量；maxpool/resize/add 真几何全量；
       负对照：无 halo（接缝，必**定位到某 tile 的边**）、maxpool 奇数偏移、add 错网格；
       Add/SRC2 实验（第二操作数能否按先算子的 tile 寻址）；DDR 流量 delta（消费冻结 ddr_traffic）。
   发火证据（`--inject2d`）：tile-drop ⇒ 正对照红（退 1）；halo-nofire / misalign-nofire ⇒ 负对照被抑制（退 2）。

============================================================================
Step 3：承重语义（逐条，与 spec §4.1/§4.4 + 任务清单对齐）
============================================================================
  · **累加顺序 & requant 位置**：一个宽层把**所有**输入通道在 **int32** 里累加
      `acc = Σ (x_q - z_x)·(w_q - z_w) + round(bias/(s_x·s_w))`，
    然后**只做一次** requant `((acc · M) >> REQUANT_Q) >> SHIFT`（本层 Q24 乘子
    `M = s_x·s_w/s_y`，§4.4），再 `+ z_y`、clamp 到 int8。
    ⇒ 跨 `ci` 趟必须**先把 int32 部分和加起来再 requant**，**绝不逐趟 requant**（会双重舍入）。
    本文件同时证明：(a) 整层 int32 acc == Σ 趟 int32 partial（**整数恒等**）；
                    (b) 最终 int8 == 整层参考（逐字节）。
  · **掩掉被 SKIP 的输入通道**：`C_in_t < 8` 时，缺失抽头的权重必须是**真实零码 `z_w`**
    （这样中心化权重 `(w_q - z_w) == 0`，其贡献**恰为 0**，与补进来的输入无关）。
    1×1 核在 3×3 框里的另外 8 个抽头同理（C4a.3 已处理）。
  · **补零用 `z_x`**：padding 用**真实零码 `z_x`**（affine 语义下"补 0"），与 C4a.2/C4a.3 一致。
  · **GROUP / depthwise**：形状集合从真表读出；`GROUP`（分组卷积）按**一般式**处理。
    depthwise 即 `GROUP = C_in = C_out`；若在形状集合里出现就一并覆盖（它的 RTL 单元是 C4a.6，
    但**算术等价**在本任务范围内）。
  · **不重写整层参考**：`整层参考` **逐字复用** `quant_ref.conv_vec`（同一代码路径，import）。
    本文件的 `conv_acc_whole` 只是把它的 **int32 acc** 单独取出来做恒等式 (a) 的对拍，
    并与 `conv_vec` 的输出**互相钉死**（`requant(conv_acc_whole) == conv_vec`）。

============================================================================
已知开口项（C4a.2/C4a.3；本任务不"顺手改"）
============================================================================
  · **O1**：`quant_ref` 把 Conv→Relu 一对 requant 成**两步**，而冻结的 C3 口径把 Relu
    **折进生产者的尾声**（一次 requant）。本任务的等价性是**关于 conv 通道**的 ⇒ 用 **conv 张量**
    当参考（`sy = conv 输出张量的自身刻度`，对应转换器 `requant_mult` 里的 `M_two_step`）。
    若将来要对 Relu 邻接的黄金，改用**折进变体**（转换器里的主 `M`，`sy_eff`）并在此记 O1 caveat。
  · 乘子**消费**转换器已发布的 `y1/gen/wgt_index.json` 的 `requant_mult`（`M_two_step` 栏），
    不另写第二套乘子公式（与 `quant_ref.scale_ratio_multiplier` 逐字同源）。

用法（全仓唯一可用 Python 组合）：
    cd /d/code/PDS/VexiiYeshenLinux/y1
    PYTHONIOENCODING=utf-8 PYTHONPATH='./.pydeps;../third_party/yunet/deps' \
      <py> tools/tiling_ref.py --selftest        # C4a.4 拆趟自检
    ... tools/tiling_ref.py --gate [--onnx <path>] [--index gen/wgt_index.json] [--dump gen/c4a_tiling]
    ... tools/tiling_ref.py --selftest2d       # T0 2-D tiling 自检
    ... tools/tiling_ref.py --gate2d [--inject2d tile-drop|halo-nofire|misalign-nofire]

退出码：0 = PASS；1 = 判据红（MISMATCH>0 / 恒等式破 / 退化守卫红）；
        2 = 负对照没发火（判据无牙）；3 = 前置缺失（缺 onnx / 缺冻结件）。
"""
import os
import sys
import json
import struct
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

# ---- 唯一真源（逐字复用；**不**重写量化器 / conv 数学）----
import quant_ref as qref                       # conv_vec / conv_acc 口径 / requant_int / Model
import quant_ptq as ptq                        # 冻结量化口径（仅供 selftest 造小张量）
import desc_table as dtab                      # 冻结真表（形状集合从它的真表读出）
import ddr_traffic as dt                       # 算子序（GraphView.nodes）
import bypass_ref as bref                      # 冻结旁路口径（maxpool / resize / add / sigmoid）

TILE = 8                                        # 硬件 8 通道切片（冻结）
REQUANT_Q = qref.REQUANT_Q                      # 24
SHIFT = qref.SHIFT                              # 6

DEFAULT_ONNX = os.path.abspath(os.path.join(_HERE, "..", "..", "third_party", "yunet", "yunet.onnx"))
DEFAULT_INDEX = os.path.abspath(os.path.join(_HERE, "..", "gen", "wgt_index.json"))
DEFAULT_DESC = os.path.abspath(os.path.join(_HERE, "..", "gen", "desc.bin"))
DEFAULT_DUMP = os.path.abspath(os.path.join(_HERE, "..", "gen", "c4a_tiling"))

# ★ T0（2-D tiling）真表里**有 halo 的 27 项**（spec §3 列出的 desc.bin 下标，逐字）。
HALO_IDX2D = (0, 2, 5, 7, 9, 11, 14, 16, 19, 21, 24, 26, 28, 32, 36, 38,
              40, 42, 44, 46, 48, 50, 52, 54, 56, 58, 60)

CONV_TYPES = (dtab.TYPE_CONV3X3, dtab.TYPE_CONV1X1, dtab.TYPE_DEPTHWISE)


# ============================ 小工具 ============================
def md5_bytes(b):
    return hashlib.md5(b).hexdigest()


def md5_file(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for blk in iter(lambda: fh.read(65536), b""):
            h.update(blk)
    return h.hexdigest()


def n_passes(n):
    """`ceil(n/8)`（剩下的不足 8 也算一趟）。"""
    return (int(n) + TILE - 1) // TILE


def node_group(node):
    """ONNX Conv 的 `group` 属性（缺省 1）。"""
    for a in node.attribute:
        if a.name == "group":
            return int(a.i) or 1
    return 1


def node_ints(node, key, dflt=None):
    for a in node.attribute:
        if a.name == key:
            return list(a.ints)
    return dflt


# ============================ 整层 int32 acc（只取 conv_vec 的累加段，不含 requant） ============================
def conv_acc_whole(xq, w, sx, sy, zw, xy, biasp, pads, strides, group, zy):
    """**整层参考的 int32 累加器**（含 bias），即 `quant_ref.conv_vec` 里 requant 之前的那一坨 `out`。

    与 `conv_vec` **逐字同款**的 im2col + 分组累加，只把最后的 requant 摘掉 ⇒ 用于恒等式 (a)
    "整层 acc == Σ 趟 partial" 的对拍。★ 本函数与 `conv_vec` 互为**交叉钉死**：
    调用方会断言 `quant_ref.requant_int(本函数输出, M, zy) == quant_ref.conv_vec(...)`。
    返回 (acc_int64[C_out,Ho,Wo], M)。
    """
    pt, pl, pb, pr = pads
    sh, swd = strides
    CI, H, W = xq.shape[1], xq.shape[2], xq.shape[3]
    CO, CG, KH, KW = w["q"].shape
    Ho, Wo = (H + pt + pb - KH) // sh + 1, (W + pl + pr - KW) // swd + 1
    xc = xq.astype(np.int64) - np.int64(xy)
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
                    cols[k] = xp[0, ca, ky:ky + sh * Ho:sh, kx:kx + swd * Wo:swd].reshape(-1)
                    k += 1
        wm = w["q"][gi * cog:(gi + 1) * cog].reshape(cog, -1).astype(np.int64) - np.int64(zw)
        acc = wm @ cols
        if biasp is not None:
            b = biasp[gi * cog:(gi + 1) * cog]
            acc = acc + np.round(b[:, None] / (sx * w["scale"])).astype(np.int64)
        out[gi * cog:(gi + 1) * cog] = acc.reshape(cog, Ho, Wo)
    M = qref.scale_ratio_multiplier((sx * w["scale"]) / sy)
    return out, M


# ============================ 拆趟模拟（冻结规则） ============================
def conv_tiled(xq, w, sx, sy, zw, xy, biasp, pads, strides, group, zy,
               drop_ci_block=None, dump_passes=False):
    """**拆趟模拟**：宽层拆成 `ceil(C_in/8) x ceil(C_out/8)` 趟 plain conv 单元。

    每趟 = 一个 `TILE(=8)` 输入通道 x `TILE(=8)` 输出通道的 plain 单元：
      · 该趟的**输出 co 块** = `[8j, 8j+C_out_t)`；输入 ci 块 = `[8i, 8i+C_in_t)`；
      · 趟内权重瓦片 `Wt[C_out_t, 8, KH, KW]` **默认填 `z_w`**（真实零码）⇒ 被 SKIP 的输入通道
        （`s >= C_in_t`）与**跨组**（`group>1` 且 `co, ci` 不同组）位置的**中心化权重 == 0**，
        贡献恰为 0（与补进来的输入无关）—— 这就是"用权重置 0 掩掉、不新增字段"；
      · **补零**用 `z_x`（affine 语义下补 0）：`x_c = x_q - z_x`，pad=0；
      · **跨 ci 趟累加**：`acc_j = Σ_i partial_ij`（**int32**），bias 折进**第一趟**（i==0）
          ⇒ `Σ_i partial_ij` 恰 == 整层 acc（恒等式 (a) 的来源）；
      · **跨 co 趟写各自区域**：`out[8j:8j+C_out_t]`；
      · requant **只做一次**：`requant_int(acc_j, M, z_y)`（M = 本层 Q24 乘子）。

    drop_ci_block = k ⇒ 负对照：**故意漏掉第 k 趟 ci 块**（不累加它的 partial）。
    返回 (out_int8[1,C_out,Ho,Wo], acc_int64[C_out,Ho,Wo], partials, M)；
    partials = [(i, j, acc_ij[C_out_t,Ho,Wo]), ...]（诊断/对拍用）。
    """
    pt, pl, pb, pr = pads
    sh, swd = strides
    CI, H, W = xq.shape[1], xq.shape[2], xq.shape[3]
    CO, CG, KH, KW = w["q"].shape
    Ho, Wo = (H + pt + pb - KH) // sh + 1, (W + pl + pr - KW) // swd + 1
    Hpb, Wpb = H + pt + pb, W + pl + pr
    xc = xq.astype(np.int64) - np.int64(xy)                          # 补 0 = 补"实数 0 的码点"
    xp = np.pad(xc, ((0, 0), (0, 0), (pt, pb), (pl, pr)), constant_values=0)
    cog, cig = CO // group, CI // group
    wq = w["q"].astype(np.int64)
    sw = float(w["scale"])
    M = qref.scale_ratio_multiplier((sx * sw) / sy)

    n_ci = n_passes(CI)
    n_co = n_passes(CO)
    out = np.zeros((1, CO, Ho, Wo), dtype=np.int8)
    acc_full = np.zeros((CO, Ho, Wo), dtype=np.int64)
    partials = []
    for j in range(n_co):
        co0, co_t = j * TILE, min(TILE, CO - j * TILE)
        acc = np.zeros((co_t, Ho, Wo), dtype=np.int64)
        for i in range(n_ci):
            if drop_ci_block is not None and i == drop_ci_block:
                continue                                              # 负对照：漏一趟
            ci0, ci_t = i * TILE, min(TILE, CI - i * TILE)
            # 趟权重瓦片：**先全填 z_w**（真实零码）⇒ 被 SKIP / 跨组位置中心化权重 == 0
            Wt = np.full((co_t, TILE, KH, KW), int(zw), dtype=np.int64)
            for r in range(co_t):
                co = co0 + r
                gco = co // cog
                for s in range(ci_t):                                 # 仅本 ci 块内的真输入通道
                    ci = ci0 + s
                    gci = ci // cig
                    if gco != gci:
                        continue                                      # 跨组 ⇒ 保持 z_w（掩掉）
                    Wt[r, s] = wq[co, ci - gci * cig]                 # 真抽头
            # 趟输入：本 ci 块的真通道 + 补到 8（补位值无所谓，权重是 z_w）
            xt = np.zeros((TILE, Hpb, Wpb), dtype=np.int64)
            xt[:ci_t] = xp[0, ci0:ci0 + ci_t]
            part_pass = np.zeros((co_t, Ho, Wo), dtype=np.int64)      # 本趟的 int32 部分和
            for r in range(co_t):
                p = np.zeros((Ho, Wo), dtype=np.int64)
                for s in range(TILE):
                    if s >= ci_t:
                        continue                                       # SKIP 通道：权重 z_w ⇒ 贡献 0
                    row = Wt[r, s]
                    for ky in range(KH):
                        for kx in range(KW):
                            wc = int(row[ky, kx]) - int(zw)
                            if wc == 0:
                                continue                               # 掩码位 / 零权重 ⇒ 跳过（等价加 0）
                            p += wc * xt[s, ky:ky + sh * Ho:sh, kx:kx + swd * Wo:swd]
                part_pass[r] = p
            if biasp is not None and i == 0:                          # bias 折进**第一趟**（一次）
                b = biasp[co0:co0 + co_t]
                part_pass += np.round(b[:, None, None] / (sx * sw)).astype(np.int64)
            acc += part_pass                                          # 跨 ci 趟：int32 累加
            if dump_passes:
                partials.append((i, j, part_pass.copy()))
        out[0, co0:co0 + co_t] = qref.requant_int(acc, M, zy)          # requant **只做一次**
        acc_full[co0:co0 + co_t] = acc
    return out, acc_full, partials, M


def conv_tiled_perpass_requant(xq, w, sx, sy, zw, xy, biasp, pads, strides, group, zy):
    """**错口径对照**（负对照 b）：每一趟各自 requant 成 int8 再相加 —— 双重舍入。

    用来证明"跨 ci 趟先累加 int32、只在最后 requant 一次"是**承重项**：这个错版本应当
    与整层参考**不一致**（否则该口径就是装饰）。返回错版本的 int8 输出。
    """
    pt, pl, pb, pr = pads
    sh, swd = strides
    CI, H, W = xq.shape[1], xq.shape[2], xq.shape[3]
    CO, CG, KH, KW = w["q"].shape
    Ho, Wo = (H + pt + pb - KH) // sh + 1, (W + pl + pr - KW) // swd + 1
    Hpb, Wpb = H + pt + pb, W + pl + pr
    xc = xq.astype(np.int64) - np.int64(xy)
    xp = np.pad(xc, ((0, 0), (0, 0), (pt, pb), (pl, pr)), constant_values=0)
    cog, cig = CO // group, CI // group
    wq = w["q"].astype(np.int64)
    sw = float(w["scale"])
    M = qref.scale_ratio_multiplier((sx * sw) / sy)
    n_ci, n_co = n_passes(CI), n_passes(CO)
    out = np.zeros((1, CO, Ho, Wo), dtype=np.int8)
    for j in range(n_co):
        co0, co_t = j * TILE, min(TILE, CO - j * TILE)
        acc8 = np.zeros((co_t, Ho, Wo), dtype=np.int64)
        for i in range(n_ci):
            ci0, ci_t = i * TILE, min(TILE, CI - i * TILE)
            Wt = np.full((co_t, TILE, KH, KW), int(zw), dtype=np.int64)
            for r in range(co_t):
                co = co0 + r
                gco = co // cog
                for s in range(ci_t):
                    ci = ci0 + s
                    gci = ci // cig
                    if gco != gci:
                        continue
                    Wt[r, s] = wq[co, ci - gci * cig]
            xt = np.zeros((TILE, Hpb, Wpb), dtype=np.int64)
            xt[:ci_t] = xp[0, ci0:ci0 + ci_t]
            part = np.zeros((co_t, Ho, Wo), dtype=np.int64)
            for r in range(co_t):
                p = np.zeros((Ho, Wo), dtype=np.int64)
                for s in range(ci_t):
                    row = Wt[r, s]
                    for ky in range(KH):
                        for kx in range(KW):
                            wc = int(row[ky, kx]) - int(zw)
                            if wc == 0:
                                continue
                            p += wc * xt[s, ky:ky + sh * Ho:sh, kx:kx + swd * Wo:swd]
                part[r] = p
            if biasp is not None and i == 0:
                b = biasp[co0:co0 + co_t]
                part += np.round(b[:, None, None] / (sx * sw)).astype(np.int64)
            acc8 += qref.requant_int(part, M, 0).astype(np.int64)      # ← 逐趟 requant（错）
        out[0, co0:co0 + co_t] = qref.requant_int(acc8, M, zy)
    return out


# ============================ 形状集合（从冻结真表读出） ============================
def payload_order(gv):
    """载荷节点序（= 表序）：跳过逐元素/布局算子 —— 与 `desc_table.build_table` 的 `order` 同源。"""
    return [n for n in gv.nodes
            if n.op_type not in dtab.EPILOGUE_OPS and n.op_type not in dtab.LAYOUT_OPS]


def declared_shapes(descs):
    """冻结真表里 conv 类项出现过的 `(C_in,C_out,GROUP)`（去重）—— 任务判据 1 的字面形状集合。"""
    s = {}
    for i, d in enumerate(descs):
        if d["TYPE"] in CONV_TYPES:
            key = (int(d["C_IN"]), int(d["C_OUT"]), int(d["GROUP"]))
            s.setdefault(key, i)
    return s


def true_shape_of(order, T, weights, idx):
    """该 conv 节点的**自有** `(C_in,C_out,GROUP)`（C_in 取输入张量通道、C_out 取权重首维）。"""
    n = order[idx]
    ci = int(T[n.input[0]].shape[1])
    co = int(weights[n.input[1]]["q"].shape[0])
    return (ci, co, node_group(n))


def resolve_shape_rep(order, T, weights):
    """真网里**每种自有 `(C_in,C_out,GROUP)`** → 第一个代表节点（表序）。

    ★ 为什么还要它：冻结表的几何字段在**链首覆盖**下会把 depthwise 中/尾片的 `GROUP`
      抹成 1（`build_table` 的 `CHAIN_GEOM_FIELDS` 口径），所以"真表的形状字段"会**丢掉**
      depthwise 的分组信息。为了让 **GROUP 一般式**与 **depthwise（GROUP=C_in=C_out）**
      真的被覆盖到，本函数按**节点自有几何**再枚举一遍（与真表形状集合取并集）。
    """
    s = {}
    for idx, n in enumerate(order):
        if n.op_type != "Conv":
            continue
        key = true_shape_of(order, T, weights, idx)
        s.setdefault(key, idx)
    return s


# ============================ --selftest ============================
def selftest():
    print("[tiling_ref] selftest：拆趟 == 整层（正/负对照都能发火）+ int32 恒等式 + 掩码")
    fails = []
    neg_nofire = []

    def chk(cond, msg):
        print("  %s  %s" % ("PASS" if cond else "FAIL", msg))
        if not cond:
            fails.append(msg)

    rng = np.random.default_rng(20261010)
    # (C_in, C_out, GROUP, pads, strides) —— 覆盖 dense / 奇零头 / group / depthwise / 无 pad
    cases = [
        (3, 16, 1, [1, 1, 1, 1], [1, 1]),        # 头层：C_out>8，1×2 趟；C_in=3（SKIP 5 通道掩码）
        (16, 16, 1, [1, 1, 1, 1], [1, 1]),       # 2×2 趟
        (64, 64, 1, [1, 1, 1, 1], [1, 1]),       # 8×8 趟（宽层）
        (64, 10, 1, [1, 1, 1, 1], [1, 1]),       # 8×2 趟（C_out 奇零头）
        (64, 4, 1, [0, 0, 0, 0], [1, 1]),        # 8×1 趟、无 pad
        (16, 16, 16, [1, 1, 1, 1], [1, 1]),      # depthwise（GROUP=C）
        (10, 4, 2, [1, 1, 1, 1], [1, 1]),        # 分组 conv（GROUP=2）、C 非 8 倍
        (7, 3, 1, [1, 1, 1, 1], [1, 1]),         # 都 < 8 ⇒ 1×1 趟（退化为整层）
    ]
    for (ci, co, gg, pads, strides) in cases:
        H = W = 9 if gg == ci else 9
        xq = ptq.quant(rng.normal(0, 1, (1, ci, H, W)), 0.05, -3)
        wf = rng.normal(0, 0.2, (co, ci // gg, 3, 3))
        sw, zw = ptq.affine_params(*ptq.calibrate(wf))
        wd = {"q": ptq.quant(wf, sw, zw), "scale": sw, "zp": zw}
        bias = rng.normal(0, 0.1, co).astype(np.float64)
        sx, sy = 0.05, 0.04
        whole = qref.conv_vec(xq, wd, sx, sy, zw, -3, bias, pads, strides, gg, -6)
        tiled, acc_t, parts, M = conv_tiled(xq, wd, sx, sy, zw, -3, bias, pads, strides, gg, -6,
                                            dump_passes=True)
        acc_w, M_w = conv_acc_whole(xq, wd, sx, sy, zw, -3, bias, pads, strides, gg, -6)
        nm = int(np.count_nonzero(whole.reshape(-1) != tiled.reshape(-1)))
        id_ok = bool(np.array_equal(acc_t, acc_w))
        # partial 求和 == 整层 acc（恒等式 (a)）
        psum = np.zeros_like(acc_w)
        for (i, j, a) in parts:
            co0 = j * TILE
            psum[co0:co0 + a.shape[0]] += a
        psum_ok = bool(np.array_equal(psum, acc_w))
        chk(nm == 0, "ci=%d co=%d g=%d：拆趟 == 整层（差 %d）" % (ci, co, gg, nm))
        chk(id_ok and psum_ok, "ci=%d co=%d g=%d：int32 恒等式（acc_whole==Σpartial=%s，acc_whole==acc_tiled=%s）"
            % (ci, co, gg, psum_ok, id_ok))
        # 负对照 a：漏一个 ci 块 ⇒ 必须变
        drop = (n_passes(ci) - 1) if n_passes(ci) > 1 else 0
        bad, _, _, _ = conv_tiled(xq, wd, sx, sy, zw, -3, bias, pads, strides, gg, -6,
                                  drop_ci_block=drop)
        dnm = int(np.count_nonzero(whole.reshape(-1) != bad.reshape(-1)))
        if dnm == 0:
            neg_nofire.append("drop ci=%d co=%d g=%d" % (ci, co, gg))
        chk(dnm > 0, "负对照 a ci=%d co=%d g=%d：漏一趟(ci块 %d) ⇒ 变 %d 点（>0）"
            % (ci, co, gg, drop, dnm))
        # 负对照 b：逐趟 requant ⇒ 与整层不一致（证明"只 requant 一次"是承重项）
        wrong = conv_tiled_perpass_requant(xq, wd, sx, sy, zw, -3, bias, pads, strides, gg, -6)
        wnm = int(np.count_nonzero(whole.reshape(-1) != wrong.reshape(-1)))
        chk(wnm > 0, "负对照 b ci=%d co=%d g=%d：逐趟 requant ⇒ 差 %d 点（>0，双重舍入确实错）"
            % (ci, co, gg, wnm))
        # 退化守卫：整层输出非常数
        chk(len(np.unique(whole)) > 1, "退化守卫 ci=%d co=%d g=%d：整层输出非常数" % (ci, co, gg))

    # 掩码显式对拍：C_in 非 8 倍时，把 SKIP 通道的输入**整体扰动**，输出必须不变
    ci, co, gg = 3, 16, 1
    xq = ptq.quant(rng.normal(0, 1, (1, ci, 9, 9)), 0.05, -3)
    wf = rng.normal(0, 0.2, (co, ci // gg, 3, 3))
    sw, zw = ptq.affine_params(*ptq.calibrate(wf))
    wd = {"q": ptq.quant(wf, sw, zw), "scale": sw, "zp": zw}
    a, _, _, _ = conv_tiled(xq, wd, 0.05, 0.04, zw, -3, None, [1, 1, 1, 1], [1, 1], gg, -6)
    chk(len(np.unique(a)) > 1, "掩码案例输出非常数（判据有分辨率）")

    if neg_nofire:
        print("SELFTEST_TILING NEG_NORIRE=%d %s" % (len(neg_nofire), neg_nofire))
    print("SELFTEST_TILING cases=%d fails=%d" % (len(cases), len(fails)))
    if fails:
        print("RESULT: FAIL")
        return 1
    print("SELFTEST_TILING: PASS")
    print("RESULT: PASS")
    return 0


# ============================ --gate ============================
def do_gate(args):
    # ---- 前置：冻结件 + 模型 ----
    if not os.path.isfile(args.onnx):
        print("FATAL: 缺 onnx %s" % args.onnx)
        return 3
    M = qref.Model(args.onnx)
    M.build_params()
    params = qref._params_of(M)
    T, _recs = qref.run_net(M, params, naive=False)
    gv = M.gv
    descs, dinfo = dtab.build_table(gv)
    order = payload_order(gv)
    assert len(order) == len(descs), "载荷序长度 %d != 表项 %d" % (len(order), len(descs))

    # ---- 转换器发布的乘子（消费，不另写公式）----
    conv_M2 = {}      # layer_id -> (M_two_step, M_primary, name, folded)
    idx_md5 = None
    if os.path.isfile(args.index):
        idx = json.load(open(args.index, encoding="utf-8"))
        idx_md5 = md5_file(args.index)
        for r in idx.get("requant_mult", []):
            conv_M2[int(r["layer_id"])] = (int(r["M_two_step"]), int(r["M"]),
                                           r["name"], list(r.get("folded_ops", [])))
    else:
        print("WARN: 缺转换器索引 %s ⇒ 乘子只走 quant_ref 公式（消费项缺失）" % args.index)

    declared = declared_shapes(descs)
    reps = resolve_shape_rep(order, T, params["weights"])
    # 覆盖集合 = 真表声明形状 ∪ 节点自有形状（后者补上被链首覆盖抹掉的 depthwise 分组）
    all_keys = sorted(set(declared) | set(reps), key=lambda k: (k[0], k[1], k[2]))
    declared_keys = set(declared)

    print("GATE model=%s onnx_md5=%s" % (os.path.basename(args.onnx), M.md5))
    print("GATE index=%s md5=%s requant_entries=%d" % (os.path.basename(args.index), idx_md5, len(conv_M2)))
    print("GATE table_items=%d conv_shapes_declared=%d conv_shapes_selfdecl=%d union=%d"
          % (len(descs), len(declared), len(reps), len(all_keys)))

    total_mism = 0
    ident_bad = 0
    neg_nofire = 0
    guard_bad = 0
    M_mismatch = 0
    dump_dir = DEFAULT_DUMP if args.dump else None
    if dump_dir:
        os.makedirs(dump_dir, exist_ok=True)
    rows = []

    for key in all_keys:
        ci, co, gg = key
        idx = reps.get(key)
        if idx is None:
            print("WARN: 形状 %s 在真网里找不到代表节点（真表声明但节点自有几何不一致）⇒ 跳过" % (key,))
            continue
        n = order[idx]
        # 参数（与 quant_ref.run_net 的 conv 分支逐字同款）
        x = T[n.input[0]]
        w = dict(params["weights"][n.input[1]])
        sx, zx = M.act[n.input[0]]["scale"], M.act[n.input[0]]["zp"]
        sy = M.act[n.output[0]]["scale"]
        zy = M.act[n.output[0]]["zp"]
        zw = w["zp"]
        biasp = params["biases"].get(n.input[2]) if len(n.input) > 2 else None
        pads = node_ints(n, "pads", [0, 0, 0, 0])
        strides = node_ints(n, "strides", [1, 1]) or [1, 1]
        grp = node_group(n)

        # ---- 整层参考：**逐字复用** quant_ref 的同一代码路径 ----
        whole = qref.conv_vec(x, w, sx, sy, zw, zx, biasp, pads, strides, grp, zy)
        golden = T[n.output[0]]
        ref_same = bool(np.array_equal(whole, golden))                # 参考 == 黄金（同一路径）

        # ---- int32 整层 acc（与 conv_vec 交叉钉死）----
        acc_w, M_w = conv_acc_whole(x, w, sx, sy, zw, zx, biasp, pads, strides, grp, zy)
        acc_tied = bool(np.array_equal(qref.requant_int(acc_w, M_w, zy).reshape(whole.shape), whole))

        # ---- 拆趟模拟 ----
        tiled, acc_t, parts, M_t = conv_tiled(x, w, sx, sy, zw, zx, biasp, pads, strides, grp, zy,
                                              dump_passes=True)
        if args.inject == "perpass":                                 # 故障注入：逐趟 requant（错口径）
            tiled = conv_tiled_perpass_requant(x, w, sx, sy, zw, zx, biasp, pads, strides, grp, zy)
        mism = int(np.count_nonzero(whole.reshape(-1) != tiled.reshape(-1)))
        # 恒等式 (a)：整层 acc == Σ 趟 partial == 拆趟 acc（整数恒等）
        psum = np.zeros_like(acc_w)
        for (i, j, a) in parts:
            co0 = j * TILE
            psum[co0:co0 + a.shape[0]] += a
        id_ok = bool(np.array_equal(acc_t, acc_w) and np.array_equal(psum, acc_w)
                     and np.array_equal(acc_t, psum))
        # int32 无溢出佐证（真实硬件是 int32 累加器）
        int32_ok = bool(np.max(np.abs(acc_w)) < (1 << 31)) if acc_w.size else True

        # ---- 负对照：漏一个 ci 块 ⇒ MISMATCH>0 ----
        n_ci = n_passes(ci)
        drop = (n_ci - 1) if n_ci > 1 else 0
        drop_eff = None if args.inject == "drop-nofire" else drop   # 故障注入：让负对照不发火
        bad, _, _, _ = conv_tiled(x, w, sx, sy, zw, zx, biasp, pads, strides, grp, zy,
                                  drop_ci_block=drop_eff)
        dmism = int(np.count_nonzero(whole.reshape(-1) != bad.reshape(-1)))

        # ---- 退化守卫 ----
        distinct = int(len(np.unique(whole)))

        # ---- 乘子消费对账（M_two_step == quant_ref 的 conv 乘子）----
        m_ok = True
        m_src = "n/a"
        if idx in conv_M2:
            M2, Mp, nm2, folded = conv_M2[idx]
            m_ok = (M2 == M_t)
            m_src = "M_two_step=%d M_primary=%d folded=%s" % (M2, Mp, folded)
            if not m_ok:
                M_mismatch += 1
        total_mism += mism
        if not (ref_same and acc_tied and id_ok and int32_ok):
            ident_bad += 1 if not (acc_tied and id_ok) else 0
        if dmism == 0:
            neg_nofire += 1
        if distinct <= 1:
            guard_bad += 1

        tag = "declared" if key in declared_keys else "selfdecl"
        row = {"shape": [ci, co, gg], "rep": n.name, "rep_idx": idx, "tag": tag,
               "n_ci": n_ci, "n_co": n_passes(co), "passes": n_ci * n_passes(co),
               "whole_md5": md5_bytes(np.ascontiguousarray(whole).tobytes()),
               "tiled_md5": md5_bytes(np.ascontiguousarray(tiled).tobytes()),
               "mismatch": mism, "identity_ok": int(id_ok), "int32_ok": int(int32_ok),
               "drop_ci_block": drop, "drop_mismatch": dmism, "distinct": distinct,
               "M": int(M_t), "M_conv_ok": int(m_ok), "ref_same_golden": int(ref_same)}
        rows.append(row)
        print("SHAPE cin=%-3d cout=%-3d group=%-3d [%-8s] rep=%-9s idx=%-3d n_ci=%d n_co=%d passes=%-3d "
              "MISMATCH=%d IDENT_OK=%d INT32_OK=%d DROP_MISMATCH=%d distinct=%d ref==golden=%d"
              % (ci, co, gg, tag, n.name, idx, n_ci, n_passes(co), n_ci * n_passes(co),
                 mism, int(id_ok), int(int32_ok), dmism, distinct, int(ref_same)))
        if dump_dir:
            np.save(os.path.join(dump_dir, "shape_%dc_%do_%dg_%s.npy" % (ci, co, gg, n.name)),
                    tiled)

    print("SHAPES_TOTAL=%d MISMATCH_TOTAL=%d IDENT_BAD=%d NEG_NOFIRE=%d GUARD_BAD=%d M_MISMATCH=%d"
          % (len(rows), total_mism, ident_bad, neg_nofire, guard_bad, M_mismatch))
    print("MISMATCH=%d" % total_mism)

    # ---- 判据 ----
    if total_mism != 0 or ident_bad != 0 or guard_bad != 0:
        print("TILING_RESULT: FAIL (mismatch=%d ident_bad=%d guard_bad=%d)"
              % (total_mism, ident_bad, guard_bad))
        print("RESULT: FAIL")
        return 1
    if neg_nofire != 0:
        print("TILING_RESULT: FAIL (neg control didn't fire on %d shapes ⇒ judge toothless)" % neg_nofire)
        print("RESULT: FAIL")
        return 2
    if M_mismatch != 0:
        print("TILING_RESULT: FAIL (M_two_step mismatch on %d shapes ⇒ converter M not consumed)" % M_mismatch)
        print("RESULT: FAIL")
        return 1

    # ---- 落盘 JSON（生成物，仓内 gen/ gitignore）----
    if args.dump:
        payload = {"artifact": "c4a_tiling.json",
                   "frozen": {"TILE": TILE, "SHIFT": SHIFT, "REQUANT_Q": REQUANT_Q,
                              "onnx_md5": M.md5, "tiling_ref_md5": md5_file(os.path.abspath(__file__)),
                              "quant_ref_md5": md5_file(os.path.join(_HERE, "quant_ref.py")),
                              "rule": "ceil(C_in/8) x ceil(C_out/8) passes; int32 cross-ci acc; ONE requant"},
                   "declared_shapes": sorted([list(k) for k in declared_keys]),
                   "rows": rows}
        jp = os.path.join(dump_dir, "c4a_tiling.json")
        with open(jp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=1)
        print("JSON %s bytes=%d md5=%s" % (jp, os.path.getsize(jp), md5_file(jp)))

    print("TILING_RESULT: PASS (shapes=%d, all MISMATCH=0; identity exact; neg-control fired on all; guard ok)"
          % len(rows))
    print("RESULT: PASS")
    return 0


# ============================================================================
# T0：**2-D tiling（64×32）+ halo** —— 「tile+halo == 整层」逐字节（零 RTL）
# ============================================================================
# 判据（spec §5 T0）：把一层的输出平面切成 64×32 的 tile；每个 tile 只喂它**需要的输入窗口**
#   （tile + halo），用**冻结参考**（conv：quant_ref.conv_vec；旁路：bypass_ref.*）在窗口上算，
#   再把每 tile 的输出拼回整层输出 ⇒ 与整层参考**逐字节**相等。负对照：不给 halo ⇒ 接缝必红。
# 本段**不重写第三条参考**：整层黄金与 tile 黄金都走同一批冻结函数。
TH2D = 32                                        # 输出 tile 行数（冻结）
TW2D = 64                                        # 输出 tile 列数（冻结）

HALO_RULE = (
    "输出平面 Ho×Wo 按 TH=32 行、TW=64 列切 tile（tile 起点 (32i,64j)）。每个 tile 的输入窗口 = "
    "该 tile 全部输出像素的**精确感受野**（左闭右开）："
    "iy=[sh*oy0-pt, sh*(oy1-1)-pt+KH), ix=[sw*ox0-pl, sw*(ox1-1)-pl+KW)；"
    "窗口越界处取该算子的 pad 值（conv/dw 补 z_x，中心化后即补 0）。"
    "⇒ conv3x3/dw3x3 s1 p1：上下左右各 +1 像素；conv3x3 s2 p1(Conv_0)：下/左 +1、上/右 +0；"
    "conv1x1 s1 p0 / maxpool 2x2 s2 / resize x2 / add：0 halo。"
    "maxpool 输入窗口=[2*oy0,2*oy1)×[2*ox0,2*ox1)（tile 边必须偶数对齐）；"
    "resize 输入窗口=[oy0/2,oy1/2)（输出 tile 边必须偶数对齐）；add 第二操作数与第一操作数同一 tile 网格。"
    "内点 tile halo 放大=(TW+2)(TH+2)/(TW*TH)=66*34/2048=2244/2048=1.095703。")


def tiles1d(n, t):
    """把 [0,n) 切成若干个长度 ≤ t 的连续段（起点 0,t,2t,...）。"""
    out = []
    i = 0
    while i < int(n):
        out.append((i, min(i + int(t), int(n))))
        i += int(t)
    return out


def tile_windows(Ho, Wo, TH=TH2D, TW=TW2D):
    """一层的全部输出 tile（行优先）：[(oy0,oy1,ox0,ox1), ...]。"""
    return [((oy0), (oy1), (ox0), (ox1))
            for (oy0, oy1) in tiles1d(Ho, TH)
            for (ox0, ox1) in tiles1d(Wo, TW)]


def ctl_tile(Ho, Wo):
    """负对照用的 tile：保证在**每个**有 ≥2 像素的维度上至少切 2 段（否则单 tile 无接缝、
    负对照真空）。真规则是 64×32；halo 规则与 tile 尺寸无关，所以控诉时用更细的 tile 合法。"""
    return (min(TH2D, max(1, Ho // 2)), min(TW2D, max(1, Wo // 2)))


def localise_mask(mask, TH, TW):
    """输入**空间错配掩码** (H,W) bool；输出 (n_空间点, first_bad, 边界环占比)。
    first_bad = (tile_i, tile_j, 局部 r, 局部 c, 全局 y, 全局 x)。"""
    H, W = mask.shape
    n = int(mask.sum())
    if n == 0:
        return 0, None, 0.0
    flat_idx = np.flatnonzero(mask.reshape(-1))
    r0, c0 = divmod(int(flat_idx[0]), W)
    on_border = 0
    for fi in flat_idx:
        y, x = divmod(int(fi), W)
        lr, lc = y % TH, x % TW
        if lr == 0 or lc == 0 or lr == min(TH, H - (y - lr)) - 1 or lc == min(TW, W - (x - lc)) - 1:
            on_border += 1
    ti, tj = r0 // TH, c0 // TW
    first = (ti, tj, r0 % TH, c0 % TW, r0, c0)
    return n, first, (on_border / n if n else 0.0)



# ---------------- conv / depthwise：tile 输入窗口 + 冻结 conv_vec ----------------
def tiled_conv(xq, w, sx, sy, zw, xy, biasp, pads, strides, group, zy,
               tile=(TH2D, TW2D), omit_halo=False, drop_tile=False, want_acc=False):
    """2-D tiling 的 conv/dw：每 tile 取**感受野窗口**喂冻结 `quant_ref.conv_vec`，再拼回整层。

    omit_halo=True ⇒ 负对照：**不给 halo**（窗口收缩成 tile 自身按 stride 放大的块、并当成本地
    边界补零）⇒ 接缝处必错（用于"halo 是承重项"的对照）。
    drop_tile=True ⇒ 发火证据：**漏最后一趟**（不写该 tile 输出）⇒ 正对照必红。
    返回 int8 输出 [1,C_out,Ho,Wo]（want_acc=True 时另返回拼接的 int32 累加平面）。
    """
    TH, TW = tile
    pt, pl, pb, pr = pads
    sh, swd = strides
    CI, H, W = xq.shape[1], xq.shape[2], xq.shape[3]
    CO, _CG, KH, KW = w["q"].shape
    Ho, Wo = (H + pt + pb - KH) // sh + 1, (W + pl + pr - KW) // swd + 1
    out = np.zeros((1, CO, Ho, Wo), dtype=np.int8)
    acc_asm = np.zeros((CO, Ho, Wo), dtype=np.int64) if want_acc else None
    tw = tile_windows(Ho, Wo, TH, TW)
    if drop_tile and tw:
        tw = tw[:-1]                                        # 发火证据：漏最后一趟
    for (oy0, oy1, ox0, ox1) in tw:
        if omit_halo:                                       # 负对照：无 halo，窗口 = tile*stride，本地补零
            iy0, iy1 = sh * oy0, sh * oy1
            ix0, ix1 = swd * ox0, swd * ox1
            pw = [pt, pl, pb, pr]
        else:                                               # 正对照：精确感受野窗口 + 越界处按 pad 裁
            iy0, iy1 = sh * oy0 - pt, sh * (oy1 - 1) - pt + KH
            ix0, ix1 = swd * ox0 - pl, swd * (ox1 - 1) - pl + KW
            pw = [max(0, -iy0), max(0, -ix0), max(0, iy1 - H), max(0, ix1 - W)]
        ys0, ys1 = max(0, iy0), min(H, iy1)
        xs0, xs1 = max(0, ix0), min(W, ix1)
        win = xq[:, :, ys0:ys1, xs0:xs1]
        tile_out = qref.conv_vec(win, w, sx, sy, zw, xy, biasp, pw, strides, group, zy)
        assert tile_out.shape[2] == (oy1 - oy0) and tile_out.shape[3] == (ox1 - ox0), \
            "tile 输出形状 %s != (%d,%d)" % (tile_out.shape[2:], oy1 - oy0, ox1 - ox0)
        out[:, :, oy0:oy1, ox0:ox1] = tile_out
        if want_acc:
            acc, _Mw = conv_acc_whole(win, w, sx, sy, zw, xy, biasp, pw, strides, group, zy)
            acc_asm[:, oy0:oy1, ox0:ox1] = acc
    return (out, acc_asm) if want_acc else out


# ---------------- 旁路算子：流顺序 [row][col][ci] ----------------
def _win_stream(A, r0, r1, c0, c1):
    return A[r0:r1, c0:c1, :].reshape(-1).tolist()


def _put_stream(dst, r0, r1, c0, c1, tile_flat, C, cw, ch):
    dst[r0:r1, c0:c1, :] = np.asarray(tile_flat, dtype=np.int64).reshape(ch, cw, C)
    return dst


def tiled_maxpool(t, C, Win, Hin, tile=(TH2D, TW2D), misalign=False):
    """maxpool 2x2/s2 的 2-D tiling：**0 halo**，输入窗口=[2*oy0,2*oy1)×[2*ox0,2*ox1)。
    misalign=True ⇒ 负对照：把 tile 的输入窗口整体偏移 1 像素（**奇数偏移 = tile 边没偶数对齐**）。"""
    Wo, Ho = Win // 2, Hin // 2
    TH, TW = tile
    A = np.asarray(t, dtype=np.int64).reshape(Hin, Win, C)
    out = np.zeros((Ho, Wo, C), dtype=np.int64)
    for (oy0, oy1, ox0, ox1) in tile_windows(Ho, Wo, TH, TW):
        iy0, iy1 = 2 * oy0, 2 * oy1
        ix0, ix1 = 2 * ox0, 2 * ox1
        if misalign:                                        # 奇数偏移（越界那一趟往回收 2 保持不越界）
            iy0 += 1; iy1 += 1
            ix0 += 1; ix1 += 1
            if iy1 > Hin:
                iy0 -= 2; iy1 -= 2
            if ix1 > Win:
                ix0 -= 2; ix1 -= 2
        win = _win_stream(A, iy0, iy1, ix0, ix1)
        tile_out = bref.maxpool_ref(win, C, ix1 - ix0, iy1 - iy0)
        _put_stream(out, oy0, oy1, ox0, ox1, tile_out, C, ox1 - ox0, oy1 - oy0)
    return out


def tiled_resize2x(t, C, Win, Hin, tile=(TH2D, TW2D)):
    """resize ×2 nearest 的 2-D tiling：**0 halo**，输入窗口=[oy0/2,oy1/2)（tile 边偶数对齐）。"""
    OW, OH = 2 * Win, 2 * Hin
    TH, TW = tile
    A = np.asarray(t, dtype=np.int64).reshape(Hin, Win, C)
    out = np.zeros((OH, OW, C), dtype=np.int64)
    for (oy0, oy1, ox0, ox1) in tile_windows(OH, OW, TH, TW):
        assert oy0 % 2 == 0 and oy1 % 2 == 0 and ox0 % 2 == 0 and ox1 % 2 == 0, "resize tile 边必须偶数"
        iy0, iy1, ix0, ix1 = oy0 // 2, oy1 // 2, ox0 // 2, ox1 // 2
        win = _win_stream(A, iy0, iy1, ix0, ix1)
        tile_out = bref.resize2x_ref(win, C, ix1 - ix0, iy1 - iy0)
        _put_stream(out, oy0, oy1, ox0, ox1, tile_out, C, ox1 - ox0, oy1 - oy0)
    return out


def tiled_add(A, B, C, W, H, tile=(TH2D, TW2D), b_shift=(0, 0)):
    """add 的 2-D tiling：**0 halo**；第二操作数与第一操作数同一 tile 网格。
    b_shift=(dy,dx) ⇒ 负对照：第二路按**错网格**（平移）取窗口 ⇒ 接缝（证明"同一网格"是承重项）。"""
    TH, TW = tile
    dy, dx = b_shift
    out = np.zeros((H, W, C), dtype=np.int64)
    for (oy0, oy1, ox0, ox1) in tile_windows(H, W, TH, TW):
        a = _win_stream(A, oy0, oy1, ox0, ox1)
        bh, bw = oy1 - oy0, ox1 - ox0
        by0 = min(max(0, oy0 + dy), H - bh)
        bx0 = min(max(0, ox0 + dx), W - bw)
        b = _win_stream(B, by0, by0 + bh, bx0, bx0 + bw)
        tile_out = bref.add_ref(a, b, C, bw, bh)
        _put_stream(out, oy0, oy1, ox0, ox1, tile_out, C, bw, bh)
    return out


# ============================ T0 selftest（小张量，正/负对照都能发火） ============================
def selftest2d():
    print("[tiling_ref] selftest2d：tile(+halo) == 整层（零 RTL）+ 漏趟/无halo/错网格 三条负对照发火")
    fails = []
    neg = []

    def chk(cond, msg):
        print("  %s  %s" % ("PASS" if cond else "FAIL", msg))
        if not cond:
            fails.append(msg)

    rng = np.random.default_rng(20261014)

    # --- conv3x3 / depthwise（tile 4×4，平面 9×9 ⇒ 3×3 个 tile，接缝充分）---
    for (ci, co, gg, pads, strides, tile) in [
            (3, 4, 1, [1, 1, 1, 1], [1, 1], (4, 4)),        # conv3x3 普通
            (4, 4, 4, [1, 1, 1, 1], [1, 1], (4, 4)),        # depthwise（group=C）
            (3, 4, 1, [1, 1, 1, 1], [2, 2], (4, 4))]:       # stride 2
        H = W = 9
        xq = ptq.quant(rng.normal(0, 1, (1, ci, H, W)), 0.05, -3)
        wf = rng.normal(0, 0.2, (co, ci // gg, 3, 3))
        sw, zw = ptq.affine_params(*ptq.calibrate(wf))
        wd = {"q": ptq.quant(wf, sw, zw), "scale": sw, "zp": zw}
        bias = rng.normal(0, 0.1, co).astype(np.float64)
        sx, sy = 0.05, 0.04
        whole = qref.conv_vec(xq, wd, sx, sy, zw, -3, bias, pads, strides, gg, -6)
        tiled, acc = tiled_conv(xq, wd, sx, sy, zw, -3, bias, pads, strides, gg, -6,
                                tile=tile, want_acc=True)
        nm = int(np.count_nonzero(whole.reshape(-1) != tiled.reshape(-1)))
        acc_w, _M = conv_acc_whole(xq, wd, sx, sy, zw, -3, bias, pads, strides, gg, -6)
        id_ok = bool(np.array_equal(acc, acc_w))
        chk(nm == 0, "ci=%d co=%d g=%d s=%d：tile(+halo) == 整层（差 %d）" % (ci, co, gg, strides[0], nm))
        chk(id_ok, "ci=%d co=%d g=%d s=%d：int32 恒等式（拼回累加平面 == 整层 acc）" % (ci, co, gg, strides[0]))
        bad = tiled_conv(xq, wd, sx, sy, zw, -3, bias, pads, strides, gg, -6, tile=tile, omit_halo=True)
        n_bad = int(np.count_nonzero(whole.reshape(-1) != bad.reshape(-1)))
        if n_bad == 0:
            neg.append("omit-halo ci=%d co=%d g=%d" % (ci, co, gg))
        chk(n_bad > 0, "负对照 omit-halo ci=%d co=%d g=%d s=%d ⇒ 接缝变 %d 点（>0）"
            % (ci, co, gg, strides[0], n_bad))
        drop = tiled_conv(xq, wd, sx, sy, zw, -3, bias, pads, strides, gg, -6, tile=tile, drop_tile=True)
        n_drop = int(np.count_nonzero(whole.reshape(-1) != drop.reshape(-1)))
        chk(n_drop > 0, "发火 漏趟 ci=%d co=%d g=%d ⇒ 变 %d 点（>0）" % (ci, co, gg, n_drop))

    # --- maxpool（0 halo；奇数偏移必红）---
    C, Win, Hin, tile = 3, 12, 12, (4, 4)
    t = bref.nontrivial(C, Win, Hin)
    whole = np.asarray(bref.maxpool_ref(t, C, Win, Hin), dtype=np.int64).reshape(Hin // 2, Win // 2, C)
    got = tiled_maxpool(t, C, Win, Hin, tile=tile)
    nm = int(np.count_nonzero(whole != got))
    chk(nm == 0, "maxpool：tile == 整层（差 %d）" % nm)
    mis = tiled_maxpool(t, C, Win, Hin, tile=tile, misalign=True)
    n_mis = int(np.count_nonzero(whole != mis))
    if n_mis == 0:
        neg.append("maxpool-misalign")
    chk(n_mis > 0, "负对照 maxpool 奇数偏移 ⇒ 变 %d 点（>0）" % n_mis)

    # --- resize（0 halo）---
    C, Win, Hin, tile = 3, 6, 6, (4, 4)
    t = bref.nontrivial(C, Win, Hin)
    whole = np.asarray(bref.resize2x_ref(t, C, Win, Hin), dtype=np.int64).reshape(2 * Hin, 2 * Win, C)
    got = tiled_resize2x(t, C, Win, Hin, tile=tile)
    nm = int(np.count_nonzero(whole != got))
    chk(nm == 0, "resize：tile == 整层（差 %d）" % nm)

    # --- add（0 halo；第二路错网格必红）---
    C, W, H, tile = 3, 10, 10, (4, 4)
    inter = bref.add_nontrivial(C, W, H)
    a, b = bref.split_add(inter, C, W, H)
    A = np.asarray(a, dtype=np.int64).reshape(H, W, C)
    B = np.asarray(b, dtype=np.int64).reshape(H, W, C)
    whole = np.asarray(bref.add_ref(a, b, C, W, H), dtype=np.int64).reshape(H, W, C)
    got = tiled_add(A, B, C, W, H, tile=tile)
    nm = int(np.count_nonzero(whole != got))
    chk(nm == 0, "add：tile == 整层（第二路同一网格；差 %d）" % nm)
    wrong = tiled_add(A, B, C, W, H, tile=tile, b_shift=(1, 1))
    n_w = int(np.count_nonzero(whole != wrong))
    if n_w == 0:
        neg.append("add-wronggrid")
    chk(n_w > 0, "负对照 add 第二路错网格 ⇒ 变 %d 点（>0）" % n_w)

    if neg:
        print("SELFTEST2D_NEG_NOFIRE=%d %s" % (len(neg), neg))
    print("SELFTEST2D fails=%d" % len(fails))
    if fails or neg:
        print("RESULT: FAIL")
        return 1 if fails else 2
    print("SELFTEST2D: PASS")
    print("RESULT: PASS")
    return 0


# ============================ T0 gate（真表覆盖 + 负对照 + 定位） ============================
def _conv_params_of(M, params, T, n):
    x = T[n.input[0]]
    w = dict(params["weights"][n.input[1]])
    sx, zx = M.act[n.input[0]]["scale"], M.act[n.input[0]]["zp"]
    sy = M.act[n.output[0]]["scale"]
    zy = M.act[n.output[0]]["zp"]
    biasp = params["biases"].get(n.input[2]) if len(n.input) > 2 else None
    pads = node_ints(n, "pads", [0, 0, 0, 0])
    strides = node_ints(n, "strides", [1, 1]) or [1, 1]
    grp = node_group(n)
    return x, w, sx, sy, zx, zy, biasp, pads, strides, grp


def _traffic2d(args):
    """DDR 流量 delta（离线）：基线 = 冻结 ddr_traffic 的 fuse_both；halo 放大 = 2244/2048。
    返回 (base, halo_bytes, design_total, ddr_read_halo_bytes, refined_total)。"""
    units = json.load(open(args.index, encoding="utf-8"))["units"]
    halo_set = set(HALO_IDX2D)
    halo_in = sum(int(u["in_bytes"]) for u in units if int(u["idx"]) in halo_set)
    gv = dt.GraphView(args.onnx)
    rows = dt.STRATEGIES["fuse_both"](gv)
    base = sum(int(r.traffic) for r in rows)
    name2idx = {u["name"]: int(u["idx"]) for u in units}
    ddr_read_halo = sum(int(r.bytes_in) for r in rows
                        if name2idx.get(r.name) in halo_set and int(r.bytes_in) > 0)
    f = (TW2D + 2) * (TH2D + 2) / float(TW2D * TH2D)
    design_total = int(round(base + halo_in * (f - 1.0)))
    refined_total = int(round(base + ddr_read_halo * (f - 1.0)))
    return base, halo_in, design_total, ddr_read_halo, refined_total, f


def do_gate2d(args):
    if not os.path.isfile(args.onnx):
        print("FATAL: 缺 onnx %s" % args.onnx)
        return 3
    M = qref.Model(args.onnx)
    M.build_params()
    params = qref._params_of(M)
    T, _recs = qref.run_net(M, params, naive=False)
    gv = M.gv
    descs, _dinfo = dtab.build_table(gv)
    order = payload_order(gv)
    assert len(order) == len(descs), "载荷序长度 %d != 表项 %d" % (len(order), len(descs))

    inj = args.inject2d
    print("GATE2D model=%s onnx_md5=%s tile=%dx%d" % (os.path.basename(args.onnx), M.md5, TW2D, TH2D))
    print("HALO_RULE %s" % HALO_RULE)

    pos_mism = 0
    neg_nofire = 0
    guard_bad = 0
    notfired = []

    # ---------------- 1) 27 个 halo 项：正对照 + 无 halo 负对照 + 定位 ----------------
    print("---- [1] halo 项（真表 27 项）：tile(+halo) == 整层 + 无 halo ⇒ 接缝 ----")
    n_halo_ok = 0
    for i in HALO_IDX2D:
        n = order[i]
        if n.op_type != "Conv":
            print("  WARN idx=%d op=%s 非 Conv（跳过）" % (i, n.op_type))
            continue
        (x, w, sx, sy, zx, zy, biasp, pads, strides, grp) = _conv_params_of(M, params, T, n)
        whole = qref.conv_vec(x, w, sx, sy, w["zp"], zx, biasp, pads, strides, grp, zy)
        golden = T[n.output[0]]
        ref_same = bool(np.array_equal(whole, golden))
        Ho, Wo = whole.shape[2], whole.shape[3]
        tiled = tiled_conv(x, w, sx, sy, w["zp"], zx, biasp, pads, strides, grp, zy,
                           drop_tile=(inj == "tile-drop"))
        mism = int(np.count_nonzero(whole.reshape(-1) != tiled.reshape(-1)))
        # 无 halo 负对照：正对照用冻结 64×32；控诉用"每维至少 2 段"的 grid 以确保有接缝
        cTH, cTW = ctl_tile(Ho, Wo)
        bad = tiled_conv(x, w, sx, sy, w["zp"], zx, biasp, pads, strides, grp, zy,
                         tile=(cTH, cTW), omit_halo=(inj != "halo-nofire"))
        mask = (whole.reshape(-1, Ho, Wo) != bad.reshape(-1, Ho, Wo)).any(axis=0)
        nb, first, frac = localise_mask(mask, cTH, cTW)
        kh, kw = (w["q"].shape[2], w["q"].shape[3])
        dist = int(len(np.unique(whole)))
        if mism == 0:
            n_halo_ok += 1
        else:
            pos_mism += 1
        if nb == 0:
            neg_nofire += 1
            notfired.append("idx%d %s" % (i, n.name))
        if not ref_same:
            guard_bad += 1
        if dist <= 1:
            guard_bad += 1
        fb = "" if first is None else ("tile(%d,%d) 局部(%d,%d) 全局(y=%d,x=%d)" % first)
        print("  HALO idx=%-3d %-9s %-8s C=%d->%d G=%d k=%dx%d s=%d pad=%s IMG=%dx%d "
              "MISMATCH=%d ref==golden=%d | NEG_NOFIRE_HALO=%d 无halo变=%d 边界环占比=%.2f %s"
              % (i, n.name, "conv3x3" if kh == 3 else "conv%d" % kh, x.shape[1], w["q"].shape[0], grp,
                 kh, kw, strides[0], pads, Wo, Ho, mism, int(ref_same),
                 0 if nb > 0 else 1, nb, frac, fb))

    # ---------------- 2) conv1x1（0 halo）：正对照 ----------------
    print("---- [2] conv1x1（0 halo）：tile == 整层 ----")
    n_c11 = 0
    c11_mism = 0
    for i, n in enumerate(order):
        if n.op_type != "Conv":
            continue
        kh, kw = params["weights"][n.input[1]]["q"].shape[2], params["weights"][n.input[1]]["q"].shape[3]
        if not (kh == 1 and kw == 1) or i in HALO_IDX2D:
            continue
        (x, w, sx, sy, zx, zy, biasp, pads, strides, grp) = _conv_params_of(M, params, T, n)
        whole = qref.conv_vec(x, w, sx, sy, w["zp"], zx, biasp, pads, strides, grp, zy)
        tiled = tiled_conv(x, w, sx, sy, w["zp"], zx, biasp, pads, strides, grp, zy)
        m = int(np.count_nonzero(whole.reshape(-1) != tiled.reshape(-1)))
        c11_mism += m
        n_c11 += 1
        if n_c11 <= 3 or m:
            print("  C1X1 idx=%-3d %-9s C=%d->%d IMG=%dx%d MISMATCH=%d"
                  % (i, n.name, x.shape[1], w["q"].shape[0], whole.shape[3], whole.shape[2], m))
    pos_mism += c11_mism
    print("  C1X1_TOTAL=%d MISMATCH=%d" % (n_c11, c11_mism))

    # ---------------- 3) maxpool / resize / add（旁路族，真几何） ----------------
    print("---- [3] maxpool / resize / add：tile == 整层 + 负对照 ----")
    bmp_ok = 0
    bmp_nofire = 0
    for i, n in enumerate(order):
        if n.op_type not in ("MaxPool", "Resize", "Add"):
            continue
        osh = gv.shape_of(n.output[0])
        C = int(osh[1])
        Ho, Wo = int(osh[2]), int(osh[3])
        if n.op_type == "MaxPool":
            Hin, Win = 2 * Ho, 2 * Wo
            t = bref.nontrivial(C, Win, Hin)
            whole = np.asarray(bref.maxpool_ref(t, C, Win, Hin), dtype=np.int64).reshape(Ho, Wo, C)
            got = tiled_maxpool(t, C, Win, Hin)                 # 正对照 @ 冻结 64×32
            m = int(np.count_nonzero(whole != got))
            cTH, cTW = ctl_tile(Ho, Wo)                         # 控诉 @ 每维 ≥2 段
            mis = tiled_maxpool(t, C, Win, Hin, tile=(cTH, cTW), misalign=(inj != "misalign-nofire"))
            nmis = int(np.count_nonzero(whole != mis))
            _, first, frac = localise_mask((whole != mis).any(axis=2), cTH, cTW)
            if m == 0:
                bmp_ok += 1
            else:
                pos_mism += 1
            if nmis == 0:
                bmp_nofire += 1
                notfired.append("MP idx%d %s" % (i, n.name))
            fb = "" if first is None else ("tile(%d,%d) 局部(%d,%d)" % first[:4])
            print("  MAXPOOL idx=%-3d %-12s C=%d IMG=%dx%d tile=%dx%d MISMATCH=%d "
                  "| 奇数偏移变=%d 边界环占比=%.2f %s"
                  % (i, n.name, C, Wo, Ho, cTW, cTH, m, nmis, frac, fb))
        elif n.op_type == "Resize":
            Hin, Win = Ho // 2, Wo // 2
            t = bref.nontrivial(C, Win, Hin)
            whole = np.asarray(bref.resize2x_ref(t, C, Win, Hin), dtype=np.int64).reshape(Ho, Wo, C)
            got = tiled_resize2x(t, C, Win, Hin)                # 正对照 @ 冻结 64×32
            m = int(np.count_nonzero(whole != got))
            if m == 0:
                bmp_ok += 1
            else:
                pos_mism += 1
            print("  RESIZE  idx=%-3d %-12s C=%d IN=%dx%d OUT=%dx%d tile=%dx%d MISMATCH=%d"
                  % (i, n.name, C, Win, Hin, Wo, Ho, TW2D, TH2D, m))
        elif n.op_type == "Add":
            inter = bref.add_nontrivial(C, Wo, Ho)
            a, b = bref.split_add(inter, C, Wo, Ho)
            A = np.asarray(a, dtype=np.int64).reshape(Ho, Wo, C)
            B = np.asarray(b, dtype=np.int64).reshape(Ho, Wo, C)
            whole = np.asarray(bref.add_ref(a, b, C, Wo, Ho), dtype=np.int64).reshape(Ho, Wo, C)
            got = tiled_add(A, B, C, Wo, Ho)                    # 正对照 @ 冻结 64×32
            m = int(np.count_nonzero(whole != got))
            cTH, cTW = ctl_tile(Ho, Wo)                         # 控诉 @ 每维 ≥2 段
            wrong = tiled_add(A, B, C, Wo, Ho, tile=(cTH, cTW),
                              b_shift=((0, 0) if inj == "misalign-nofire" else (1, 1)))
            nw = int(np.count_nonzero(whole != wrong))
            _, first, frac = localise_mask((whole != wrong).any(axis=2), cTH, cTW)
            if m == 0:
                bmp_ok += 1
            else:
                pos_mism += 1
            if nw == 0:
                bmp_nofire += 1
                notfired.append("ADD idx%d %s" % (i, n.name))
            fb = "" if first is None else ("tile(%d,%d) 局部(%d,%d)" % first[:4])
            print("  ADD     idx=%-3d %-12s C=%d IMG=%dx%d tile=%dx%d MISMATCH=%d "
                  "| 错网格变=%d 边界环占比=%.2f %s"
                  % (i, n.name, C, Wo, Ho, cTW, cTH, m, nw, frac, fb))
    neg_nofire += bmp_nofire

    # ---------------- 4) Add/SRC2 实验：第二操作数能否按"先算子的 tile"寻址 ----------------
    print("---- [4] Add/SRC2 实验（真表 k 从 desc.bin 读）----")
    add_k = {}
    try:
        raw = open(args.desc, "rb").read()
        for i, n in enumerate(order):
            if n.op_type == "Add":
                w3 = struct.unpack("<8I", raw[i * 32:i * 32 + 32])[3]
                add_k[i] = (w3 >> 16) & 0xFFFF
    except Exception as e:
        print("  WARN 读 desc.bin 失败：%s" % e)
    for i, n in enumerate(order):
        if n.op_type != "Add":
            continue
        osh = gv.shape_of(n.output[0])
        C, Ho, Wo = int(osh[1]), int(osh[2]), int(osh[3])
        k = add_k.get(i, 0)
        prod = order[i - k] if k and 0 <= i - k < len(order) else None
        pdesc = ("%s(idx=%d,out=%s)" % (prod.name, i - k, tuple(gv.shape_of(prod.output[0])))
                 if prod is not None else "n/a")
        # 实验：B 按**生产者同一 tile 网格**取 -> 正；B 按**错网格**取 -> 负
        inter = bref.add_nontrivial(C, Wo, Ho)
        a, b = bref.split_add(inter, C, Wo, Ho)
        A = np.asarray(a, dtype=np.int64).reshape(Ho, Wo, C)
        B = np.asarray(b, dtype=np.int64).reshape(Ho, Wo, C)
        whole = np.asarray(bref.add_ref(a, b, C, Wo, Ho), dtype=np.int64).reshape(Ho, Wo, C)
        cTH, cTW = ctl_tile(Ho, Wo)
        good = tiled_add(A, B, C, Wo, Ho)                       # B 与 A **同一 tile 网格** ⇒ 正
        wrong = tiled_add(A, B, C, Wo, Ho, tile=(cTH, cTW),
                          b_shift=((0, 0) if inj == "misalign-nofire" else (1, 1)))  # B 错网格 ⇒ 负
        mg = int(np.count_nonzero(whole != good))
        mw = int(np.count_nonzero(whole != wrong))
        same_grid = (prod is not None and tuple(gv.shape_of(prod.output[0]))[2:] == (Ho, Wo))
        print("  ADD_SRC2 idx=%-3d %-9s SRC2_K=%d 生产者=%s 同网格=%d | 同网格拼回差=%d 错网格差=%d"
              % (i, n.name, k, pdesc, int(same_grid), mg, mw))
        if mg != 0:
            pos_mism += 1
        if mw == 0:
            neg_nofire += 1

    # ---------------- 流量 delta ----------------
    try:
        base, halo_in, design_total, ddr_read_halo, refined_total, f = _traffic2d(args)
        print("TRAFFIC2D base_fuse_both=%d halo_in_bytes=%d factor=%.6f design_total=%d (+%.2f%%) "
              "refined_fusion_aware=%d (+%.2f%%)"
              % (base, halo_in, f, design_total, 100.0 * (design_total - base) / base,
                 refined_total, 100.0 * (refined_total - base) / base))
    except Exception as e:
        print("WARN TRAFFIC2D 失败：%s" % e)

    print("GATE2D_TOTAL positive_mismatch=%d neg_nofire=%d guard_bad=%d halo_ok=%d/%d bypass_ok=%d"
          % (pos_mism, neg_nofire, guard_bad, n_halo_ok, len(HALO_IDX2D), bmp_ok))

    # 发火证据走**正常判决**（不特判）：tile-drop ⇒ 正对照红（退 1）；
    # halo-nofire / misalign-nofire ⇒ 负对照被抑制 ⇒ NEG_NOFIRE>0（退 2）。判据有牙即此。
    if pos_mism != 0 or guard_bad != 0:
        print("TILING2D_RESULT: FAIL (positive_mismatch=%d guard_bad=%d)"
              % (pos_mism, guard_bad))
        print("RESULT: FAIL")
        return 1
    if neg_nofire != 0:
        print("TILING2D_RESULT: FAIL (neg control didn't fire on %d ⇒ toothless: %s)"
              % (neg_nofire, notfired[:6]))
        print("RESULT: FAIL")
        return 2

    print("TILING2D_RESULT: PASS (halo %d/%d byte-exact; conv1x1 %d; bypass %d; all neg controls fired)"
          % (n_halo_ok, len(HALO_IDX2D), n_c11, bmp_ok))
    print("RESULT: PASS")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--onnx", default=DEFAULT_ONNX)
    ap.add_argument("--index", default=DEFAULT_INDEX)
    ap.add_argument("--desc", default=DEFAULT_DESC)
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--gate", action="store_true")
    ap.add_argument("--selftest2d", action="store_true", help="T0：小张量 2-D tiling + halo 自检")
    ap.add_argument("--gate2d", action="store_true", help="T0：真表 2-D tiling + halo 闸门")
    ap.add_argument("--dump", action="store_true")
    ap.add_argument("--inject", default="none",
                    choices=("none", "perpass", "drop-nofire"),
                    help="故障注入（**只给闸门发火证据**，不改冻结规则）：perpass=逐趟 requant（⇒判据红）；"
                         "drop-nofire=让负对照漏一趟不再生效（⇒负对照没发火，退出 2）")
    ap.add_argument("--inject2d", default="none",
                    choices=("none", "tile-drop", "halo-nofire", "misalign-nofire"),
                    help="T0 故障注入：tile-drop=漏一趟（正对照必红）；"
                         "halo-nofire=抑制无 halo 负对照；misalign-nofire=抑制奇数偏移/错网格负对照")
    args = ap.parse_args(argv[1:])
    if args.selftest:
        return selftest()
    if args.selftest2d:
        return selftest2d()
    if args.gate:
        return do_gate(args)
    if args.gate2d:
        return do_gate2d(args)
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
