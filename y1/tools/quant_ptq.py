#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""quant_ptq.py —— y1 C4a.1：**冻结量化口径** + **自研 affine 训练后量化（PTQ）**工具。

本文件是 C4a 量化口径的**唯一真源**：C4a.2 的同口径 int8 参考（`quant_ref.py`）、
C4a.3 的转换器（`y1_convert.py`）都必须**逐字复用本文件**的 `calibrate / affine_params /
quant / dequant`，不得各写一套。`yunet.onnx` 是 **float32、无 QDQ**（实测）⇒ 转换器不能只
"抽取量化参数"，它**必须自己做 PTQ**——这就是本文件存在的理由。

本文件**只做离线数值**：不产 RTL、不碰 SoC、不上板。

============================================================================
Step 1：冻结的 affine 口径（逐字，不得就地改；要改走 spec 修订）
============================================================================
per-tensor affine：
  q = clamp(round(x / scale) + zero_point, -128, 127)      # 权重与激活同式
  x ≈ (q - zero_point) * scale
校准：每层张量的 min/max（默认）；可选 percentile（记在报告里）
      ★ 校准区间**先零值纳入**再求参：lo=min(lo,0)、hi=max(hi,0)（见下方附注，承重项）
权重：**对称量化**（§4.5-A：z_w ≡ 0、scale = max|w|/127 ⇒ w_q ∈ [−127,127]，**c_q=w_q 恰落 int8**）
激活：int8（scale/zp 由校准给，先零值纳入）
累加：int32；requant = 算术右移 shift（= 6，与网表展开期 SHIFT 一致）
   （若某层 shift ≠ 6 ⇒ 该层必须走独立 shift 通路；C4a 先只支持 shift=6，遇到不同的层在报告里点名）
============================================================================

口径里三处**必须被解释清楚**的点（本实现的选择，逐条记在 `reports/c4a_quant.md`）：
  · 校准默认 **min/max**（`percentile=None`）；给 `--percentile p` 时取**升序**分位
    `np.percentile(t, sorted([p, 100-p]))`（`p` 限 (0,100) 开区间），**尾部分位**（超出 [lo,hi]
    的样本）由 `clamp` 饱和吸收。★ 用升序取分位是关键：写成 `[p, 100-p]` 时 `p>50` 会给出 `lo>hi`。
  · **零值纳入**（本口径的承重项，2026-10-10 修订）：求 `scale/zp` 前先把校准区间扩到含 0 ——
    `lo=min(lo,0)`、`hi=max(hi,0)`。per-tensor affine **必须能精确表示 0**（ReLU 边界 / 零填充 /
    常量 0 都要求 0 落在可表示集合内）。否则对区间不含 0 的张量，`zp=round(-lo/scale)-128` 会落到
    int8 之外、被 `clamp` 静默吃成边界码点 ⇒ **整张量塌成极少数码点**。实测（`--onnx`，`yunet.onnx`）
    命中 **11 个张量**，其中 **3 个是真 conv 权重**（`bbox_head.multi_level_cls.0.conv2.weight [1,1,3,3]`
    区间 `[0.1465,0.3100]` ⇒ `zp` 由 `-357` 被 clamp 到 `-128`，只剩 **4** 个码点、丢掉区间 **89.7%**）。
    零值纳入后对**有限输入可证** `zp∈[-128,127]`（`-lo/(hi-lo)∈[0,1]` ⇒ `-lo/scale∈[0,255]`），
    `clamp` 退化为安全网。★ **这只改"喂给 affine 公式的区间"，公式本身一字不改** —— 是结构性修正，
    不是旁路。
  · `zero_point` 取整 = **Python `round()`**（银行家舍入）；`scale = (hi-lo)/255` 仅在 `hi==lo`
    （常数张量，零值纳入后即 `lo==hi==0`）时退化为 `1.0`。

============================================================================
Step 2/3：`--selftest` —— 七条判据，每条都对**独立期望**，且**都能被打红**
============================================================================
打印（成功时逐字）：
  SELFTEST_PTQ roundtrip_maxerr=<e>   # 反量化误差 ≤ scale/2（边界内）—— 期望 = 数学定理 scale/2
  SELFTEST_PTQ monotone=1             # x 增大 ⇒ q 不减（对**升序**输入断言 diff(q) >= 0）
  SELFTEST_PTQ clamp=1                # 超范围夹到 ±(127/-128) 边界，**不回绕** —— 期望 = int8 常量边界
  SELFTEST_PTQ scale_changed=1        # 把 scale 改 1 bit ⇒ 反量化结果按**解析预测**改变（负对照）
  SELFTEST_PTQ zero_repr=1            # **零值可表示**：全正张量（真网 conv 权重区间）不得退化
  SELFTEST_PTQ percentile_ok=1        # `--percentile p` 须 lo<=hi 且真剪尾（p=99 与 p=1 都对）
  SELFTEST_PTQ sym_weight=1           # **权重对称量化**：z_w=0 且中心化权重 c_q=w_q 恰落 int8（§4.5-A）
  RESULT: PASS

七条都不是"自己比自己"：
  1) roundtrip：误差与**数学上界** `scale/2`（由校准区间独立算出）比；
  2) monotone ：对**排序过**的输入断言差分为非负（性质，非恒等）；
  3) clamp    ：与**外部常量** `[127, -128]` 比；
  4) scale_changed：把 scale 的最低有效位翻一位（`struct` 位翻转，**真改 1 bit**），断言
     `dequant(q,scale2) - dequant(q,scale)` **等于解析预测** `(q-zp)*(scale2-scale)` 且**非零**；
  5) zero_repr：对一个**全正、不含 0** 的张量（复刻真网 `bbox_head…` 的 `[0.1465,0.3100]`）断言
     `zp∈[-128,127]`、**用量化码点数 ≥ 32**、`maxerr ≤ scale/2`（退化时 zp 被 clamp ⇒ 塌成 2~4 码点 ⇒ 必红）；
  6) percentile_ok：`calibrate(t, 99)` 与 `calibrate(t, 1)`（含离群样本）都须 `lo<=hi` 且**真剪到尾**
     （`lo>min`、`hi<max`）（取分位序写反时 `p>50` 给出 `lo>hi` ⇒ 必红）；
  7) sym_weight：对同一全正张量，`weight_params` 须给 `z_w=0` 且 `c_q = w_q − z_w = w_q` 的**最大绝对值 ≤ 127**
     且 `maxerr ≤ scale/2`（权重误用非对称 affine 时 `z_w=-128` ⇒ `c_q=w_q+128` 越界 ⇒ 必红；§4.5-A 的承重性质）。

**故障注入（负对照的"牙"）**：`--inject <fault>` 在**运行期猴补丁**上面这些纯函数，
故意打断某条 check（**不改本文件里 Step-3 的口径实现**）：
  · floor    ⇒ `quant` 用 `floor` 代替 `round` ⇒ **roundtrip** 超界（误差逼近 1·scale）；
  · noclip   ⇒ `quant` 去掉 `clamp`        ⇒ **clamp** 回绕（int8 截断）；
  · negscale ⇒ `scale` 取负                 ⇒ **monotone** 破（x 增 q 减）；
  · noscale  ⇒ `dequant` 忽略 scale         ⇒ **scale_changed** 变值消失（橡皮章）；
  · nozero   ⇒ `affine_params` 去掉零值纳入 ⇒ **zero_repr** 退化（zp 被 clamp、码点塌缩）；
  · badpct   ⇒ `calibrate` 取分位序写反     ⇒ **percentile_ok** 破（lo>hi）；
  · nosym    ⇒ 权重误用非对称 affine        ⇒ **sym_weight** 破（z_w≠0 ⇒ c_q 越 int8；§4.5-A）。
`tools/run_quant_ab.sh` 会把本文件**拷到 /tmp**（绝不改仓内文件）并逐个注入，断言
**每条 check 都被对应故障精确打红**；哪条打不红 ⇒ 退出 2（负对照没发火 = 判据无效）。

用法（全仓唯一可用 Python 组合）：
    cd /d/code/PDS/VexiiYeshenLinux/y1
    PYTHONIOENCODING=utf-8 PYTHONPATH='../third_party/yunet/deps' \
      /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe tools/quant_ptq.py --selftest
    ... tools/quant_ptq.py --onnx ../third_party/yunet/yunet.onnx [--percentile 99.9]

ONNX 依赖**只在** `--onnx` 分支里（懒 import）⇒ `--selftest` 纯数值、不需要 ONNX。
"""
import os
import sys
import math
import struct

import numpy as np

# Windows 控制台是 GBK；非 ASCII 直接写会炸，统一换成可替换字符。
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


# ============================ 冻结常量 ============================
# requant = 算术右移 shift；本代网表展开期 SHIFT = 6（C3.8 冻结：QUANT_SHIFT 必须 == 6）。
SHIFT = 6


def require_shift(layer_id, shift):
    """冻结：本代 requant 一律算术右移 `SHIFT=6`。任何 `shift != 6` 的层**必须被点名**
    （C4a 只支持 shift=6；真遇到则走 spec 修订加 per-layer shift 通路，不静默处理）。"""
    if int(shift) != SHIFT:
        raise ValueError(
            "layer %r: shift=%d != 冻结值 %d ⇒ 该层必须走独立 shift 通路（C4a 不支持）"
            % (layer_id, int(shift), SHIFT))
    return SHIFT


# ============================ Step 3：口径实现（纯函数，逐字对应 spec） ============================
def calibrate(t, percentile=None):
    """校准备每层张量的 `[lo, hi]`：默认 min/max；可选 percentile 分位（尾部由 clamp 吸收）。

    空张量（真网里存在 `size==0` 的 initializer）退化为 `(0.0, 0.0)`，不抛。
    分位用**升序**取（`sorted([p,100-p])`）⇒ 任意 `p∈(0,100)` 都保证 `lo<=hi`
    （写成 `[p,100-p]` 时 `p>50` 会给出 `lo>hi` ⇒ 求参退化）。"""
    a = np.asarray(t, dtype=np.float64)
    if a.size == 0:
        return 0.0, 0.0
    lo, hi = float(a.min()), float(a.max())
    if percentile is not None:
        p = float(percentile)
        if not (0.0 < p < 100.0):
            raise ValueError("percentile 必须在 (0,100) 开区间，收到 %r" % percentile)
        q1, q2 = sorted((p, 100.0 - p))
        lo, hi = (float(v) for v in np.percentile(a, [q1, q2]))
    return lo, hi


def affine_params(lo, hi):
    """由校准区间 `[lo,hi]` 求 per-tensor affine 参数 `(scale, zp)`，满足 `q = round(x/scale)+zp`。

    ★ 承重口径（2026-10-10 修订）：**先零值纳入** —— `lo=min(lo,0)`、`hi=max(hi,0)` 再求参。
    per-tensor affine **必须能精确表示 0**（ReLU 边界 / 零填充 / 常量 0 都要 0 落在可表示集合内）。
    否则对区间不含 0 的张量（实测真网 3 个 conv 权重，如 `[0.1465,0.3100]`），`zp=round(-lo/scale)-128`
    会落到 int8 之外、被 `clamp` 静默吃成边界码点 ⇒ 整张量塌成几个码点。零值纳入后对有限输入可证
    `zp∈[-128,127]`（`-lo/(hi-lo)∈[0,1]` ⇒ `-lo/scale∈[0,255]`），`clamp` 退化为安全网。"""
    lo = min(float(lo), 0.0)
    hi = max(float(hi), 0.0)
    scale = (hi - lo) / 255.0 if hi > lo else 1.0
    zp = int(round(-lo / scale)) - 128
    zp = max(-128, min(127, zp))
    return scale, zp


def quant(t, scale, zp):
    """affine 量化：`q = clamp(round(x/scale) + zp, -128, 127)`（返回 int8）。"""
    return np.clip(np.round(np.asarray(t, dtype=np.float64) / scale).astype(np.int32) + zp,
                   -128, 127).astype(np.int8)


def dequant(q, scale, zp):
    """affine 反量化：`x ≈ (q - zp) * scale`（返回 float64）。"""
    return (np.asarray(q).astype(np.int32) - zp) * scale


# ---- 权重侧：对称量化（§4.5-A）——与激活侧 affine 的唯一差别是 z_w ≡ 0 ----
def weight_params(t):
    """权重**对称**量化：`z_w ≡ 0`、`scale = max|t|/127`（空张量 ⇒ `scale=1.0`）。
    ★ 对称 ⇒ 中心化权重 `c_q = w_q − z_w = w_q` **恰落 int8**（`[−127,127]`）；这是 §4.5-A 的承重性质。"""
    a = np.asarray(t, dtype=np.float64)
    m = float(np.max(np.abs(a))) if a.size else 0.0
    scale = m / 127.0 if m > 0.0 else 1.0
    return scale, 0


def quant_weight(t, scale):
    """权重量化：`q = clamp(round(x/scale), -128, 127)`（`z_w ≡ 0`）。"""
    return np.clip(np.round(np.asarray(t, dtype=np.float64) / scale), -128, 127).astype(np.int8)


def dequant_weight(q, scale):
    """权重反量化：`x ≈ q * scale`（`z_w ≡ 0`）。"""
    return np.asarray(q).astype(np.int32) * scale


# ============================ 辅助：真·翻 1 bit ============================
def flip_one_bit(x):
    """把 double 的**最低有效位**翻一位（真·改 1 bit）⇒ 值确实改变。"""
    v = float(x)
    bits = struct.unpack("<Q", struct.pack("<d", v))[0]
    return struct.unpack("<d", struct.pack("<Q", bits ^ 1))[0]


# ============================ 故障注入（只用于负对照，不改上面的口径实现） ============================
_INJECTS = ("floor", "noclip", "negscale", "noscale", "nozero", "badpct", "nosym")


def _apply_injection(name):
    """运行期猴补丁：故意打断某条 check 的**唯一**来源，以证明该 check 有牙。

    ★ 这里**不**触碰 Step-3 的纯函数定义：只在 selftest 进程里覆盖全局名字。
    返回值 = 实际生效的故障名（'none' = 不注入）。
    """
    if not name or name == "none":
        return "none"
    if name not in _INJECTS:
        raise SystemExit("FATAL: 未知 --inject=%s（可选：%s）" % (name, ", ".join(_INJECTS)))
    g = globals()
    if name == "floor":
        def quant(t, scale, zp):
            return np.clip(np.floor(np.asarray(t, dtype=np.float64) / scale).astype(np.int32) + zp,
                           -128, 127).astype(np.int8)
        g["quant"] = quant
    elif name == "noclip":
        def quant(t, scale, zp):
            # 去掉 clamp ⇒ int8 截断（回绕）
            return (np.round(np.asarray(t, dtype=np.float64) / scale).astype(np.int32) + zp).astype(np.int8)
        g["quant"] = quant
    elif name == "negscale":
        _orig = g["affine_params"]
        def affine_params(lo, hi, _o=_orig):
            s, z = _o(lo, hi)
            return -s, z
        g["affine_params"] = affine_params
    elif name == "noscale":
        def dequant(q, scale, zp):
            # 忽略 scale ⇒ 改 scale 的 1 bit 不再改变结果（橡皮章）
            return (np.asarray(q).astype(np.int32) - zp).astype(np.float64)
        g["dequant"] = dequant
    elif name == "nozero":
        # 去掉零值纳入 ⇒ 不含 0 的张量 zp 越界被 clamp ⇒ 码点塌缩（退化路径）
        def affine_params(lo, hi):
            lo = float(lo); hi = float(hi)
            scale = (hi - lo) / 255.0 if hi > lo else 1.0
            zp = int(round(-lo / scale)) - 128
            return scale, max(-128, min(127, zp))
        g["affine_params"] = affine_params
    elif name == "badpct":
        # 取分位序写反（[p,100-p] 而非升序）⇒ p>50 时 lo>hi
        def calibrate(t, percentile=None):
            a = np.asarray(t, dtype=np.float64)
            if a.size == 0:
                return 0.0, 0.0
            if percentile is None:
                return float(a.min()), float(a.max())
            p = float(percentile)
            lo, hi = (float(v) for v in np.percentile(a, [p, 100.0 - p]))
            return lo, hi
        g["calibrate"] = calibrate
    elif name == "nosym":
        # 权重误用非对称 affine（零值纳入）⇒ 全正张量 zp=-128 ⇒ c_q=w_q+128 越 int8
        def weight_params(t):
            a = np.asarray(t, dtype=np.float64)
            if a.size == 0:
                return 1.0, 0
            lo, hi = min(float(a.min()), 0.0), max(float(a.max()), 0.0)
            scale = (hi - lo) / 255.0 if hi > lo else 1.0
            zp = int(round(-lo / scale)) - 128
            return scale, max(-128, min(127, zp))
        g["weight_params"] = weight_params
    return name


# ============================ Step 2/3：selftest（四条，逐条对独立期望） ============================
def selftest(inject="none"):
    """返回退出码：0 = 四条全绿；1 = 有 check 红。"""
    inj = _apply_injection(inject)
    if inj != "none":
        print("SELFTEST_PTQ inject=%s" % inj)

    fails = []
    checks = {"roundtrip": True, "monotone": True, "clamp": True, "scale_changed": True,
              "zero_repr": True, "percentile_ok": True, "sym_weight": True}

    rng = np.random.default_rng(20251010)

    # 校准张量：确定性、值域 [-3, 5]（远离 int8 上下饱和）；lo/hi 由它自己的 min/max 给。
    calib = np.concatenate([
        np.linspace(-3.0, 5.0, 4097),
        rng.uniform(-3.0, 5.0, 20000),
    ])
    lo, hi = calibrate(calib)
    scale, zp = affine_params(lo, hi)
    span = hi - lo

    # ---- check 1：roundtrip_maxerr <= scale/2（独立期望 = 数学上界） ----
    x_rt = np.concatenate([
        np.linspace(lo, hi, 200001),      # 稠密：逼近但不超过 0.5*scale 的边界
        rng.uniform(lo, hi, 50000),
    ])
    rt_err = float(np.max(np.abs(x_rt - dequant(quant(x_rt, scale, zp), scale, zp))))
    rt_bound = float(scale) / 2.0
    rt_tol = 1e-9 * max(1.0, abs(rt_bound))
    if not (rt_err <= rt_bound + rt_tol):
        checks["roundtrip"] = False
        fails.append("roundtrip: maxerr=%.9g > bound=scale/2=%.9g" % (rt_err, rt_bound))

    # ---- check 2：monotone（x 增 ⇒ q 不减；对**升序**输入断言 diff >= 0） ----
    x_mono = np.linspace(lo - 4.0 * span, hi + 4.0 * span, 100001)   # 严格递增，含两侧饱和区
    q_mono = quant(x_mono, scale, zp).astype(np.int64)
    dq_mono = np.diff(q_mono)
    n_down = int(np.count_nonzero(dq_mono < 0))
    if n_down != 0:
        checks["monotone"] = False
        fails.append("monotone: %d 处 x 增大却 q 减小（最坏 %d）" % (n_down, int(dq_mono.min())))

    # ---- check 3：clamp 不回绕（独立期望 = int8 常量边界 [127, -128]） ----
    xs = np.array([hi + 10.0 * span, lo - 10.0 * span,
                   hi + 1e5 * span, lo - 1e5 * span], dtype=np.float64)
    qs = quant(xs, scale, zp).astype(np.int64)
    exp = np.array([127, -128, 127, -128], dtype=np.int64)
    n_bad = int(np.count_nonzero(qs != exp))
    if n_bad != 0:
        checks["clamp"] = False
        fails.append("clamp: %d/4 极端值未夹到边界（期望 127/-128，实得 %s）"
                     % (n_bad, qs.tolist()))

    # ---- check 4：scale 改 1 bit ⇒ dequant 按解析预测改变（负对照，必须真发火） ----
    q4 = quant(calib, scale, zp)
    dq0 = dequant(q4, scale, zp)
    scale2 = flip_one_bit(scale)
    dq1 = dequant(q4, scale2, zp)
    pred = (q4.astype(np.int64) - zp) * (scale2 - scale)     # 解析独立预测
    bit_moved = bool(scale2 != scale)
    changed = bool(np.any(dq0 != dq1))
    pred_ok = bool(np.allclose(dq1 - dq0, pred, rtol=1e-9, atol=1e-12))
    if not (bit_moved and changed and pred_ok):
        checks["scale_changed"] = False
        fails.append("scale_changed: bit_moved=%s changed=%s pred_ok=%s（负对照没发火 ⇒ 橡皮章）"
                     % (bit_moved, changed, pred_ok))

    # ---- check 5：零值可表示（全正张量不得退化；区间复刻真网 conv 权重 [0.1465,0.3100]） ----
    t_pos = np.linspace(0.14654, 0.309966, 4097)   # 全正、不含 0；稠密 ⇒ 码点数可判
    s5, z5 = affine_params(float(t_pos.min()), float(t_pos.max()))
    q5 = quant(t_pos, s5, z5).astype(np.int64)
    n_codes5 = int(len(np.unique(q5)))
    err5 = float(np.max(np.abs(t_pos - dequant(q5, s5, z5))))
    bound5 = float(s5) / 2.0
    if not (-128 <= z5 <= 127 and n_codes5 >= 32 and err5 <= bound5 + 1e-12):
        checks["zero_repr"] = False
        fails.append("zero_repr: zp=%d codes=%d maxerr=%.6g bound=%.6g（未做零值纳入 ⇒ zp 越界被 clamp、码点塌缩）"
                     % (z5, n_codes5, err5, bound5))

    # ---- check 6：percentile 分位（lo<=hi 且真剪尾；p=99 与 p=1 都必须对） ----
    t_pc = np.concatenate([np.linspace(-1.0, 1.0, 10001), np.array([-50.0, 50.0])])   # 带离群样本
    pc_a = calibrate(t_pc, 99.0)
    pc_b = calibrate(t_pc, 1.0)
    pc_ok = (pc_a[0] <= pc_a[1]) and (pc_b[0] <= pc_b[1]) \
        and (pc_a[0] > float(t_pc.min())) and (pc_a[1] < float(t_pc.max()))
    if not pc_ok:
        checks["percentile_ok"] = False
        fails.append("percentile_ok: p99=[%.4g,%.4g] p1=[%.4g,%.4g] tmin=%.4g tmax=%.4g（分位序写反 ⇒ lo>hi）"
                     % (pc_a[0], pc_a[1], pc_b[0], pc_b[1], float(t_pc.min()), float(t_pc.max())))

    # ---- check 7：权重对称量化 ⇒ 中心化权重 c_q=w_q 恰落 int8（§4.5-A；区间不含 0 也不退化） ----
    t_w = np.linspace(0.14654, 0.309966, 4097)      # 全正（真网权重区间）
    sw7, zw7 = weight_params(t_w)
    qw7 = quant_weight(t_w, sw7).astype(np.int64)
    c7 = qw7 - zw7                                   # 中心化权重；对称 ⇒ 须 ≤127
    err7 = float(np.max(np.abs(t_w - dequant_weight(qw7, sw7))))
    if not (zw7 == 0 and c7.min() >= -128 and c7.max() <= 127
            and int(np.abs(c7).max()) <= 127 and err7 <= sw7 / 2.0 + 1e-12):
        checks["sym_weight"] = False
        fails.append("sym_weight: zp=%d c_q=[%d,%d] maxerr=%.6g（须 zp=0 且 |c_q|<=127）"
                     % (zw7, int(c7.min()), int(c7.max()), err7))

    # ---- 打印（成功时逐字 = Step-2 格式） ----
    print("SELFTEST_PTQ roundtrip_maxerr=%.6g" % rt_err)
    print("SELFTEST_PTQ monotone=%d" % (1 if checks["monotone"] else 0))
    print("SELFTEST_PTQ clamp=%d" % (1 if checks["clamp"] else 0))
    print("SELFTEST_PTQ scale_changed=%d" % (1 if checks["scale_changed"] else 0))
    print("SELFTEST_PTQ zero_repr=%d" % (1 if checks["zero_repr"] else 0))
    print("SELFTEST_PTQ percentile_ok=%d" % (1 if checks["percentile_ok"] else 0))
    print("SELFTEST_PTQ sym_weight=%d" % (1 if checks["sym_weight"] else 0))
    for f in fails:
        print("SELFTEST_PTQ FAIL %s" % f)
    if fails:
        print("RESULT: FAIL")
        return 1
    print("RESULT: PASS")
    return 0


# ============================ ONNX 依赖分支（C4a.2 / C4a.3 复用） ============================
def ptq_weight_tensor(t, percentile=None):
    """对单个权重张量做**对称** PTQ（§4.5-A）；返回 `(scale, 0, q_int8, maxerr)`。

    权重侧**不**用 `percentile`/affine（对称量化 `z_w≡0` 才有 `c_q=w_q` 落 int8）；
    参数保留只为接口兼容。"""
    scale, zp = weight_params(t)
    q = quant_weight(t, scale)
    dq = dequant_weight(q, scale)
    err = float(np.max(np.abs(np.asarray(t, dtype=np.float64) - dq))) if np.asarray(t).size else 0.0
    return scale, zp, q, err


def do_onnx(path, percentile=None):
    """`--onnx`：对真模型做**权重侧** PTQ（激活侧校准需代表性输入，留 C4a.2/C4a.3）。
    懒 import onnx ⇒ 本分支外（尤其 --selftest）不依赖 onnx。"""
    try:
        import onnx
        from onnx import numpy_helper
    except Exception as e:  # pragma: no cover
        print("FATAL: 需要 onnx（PYTHONPATH 指向 third_party/yunet/deps）: %r" % e, file=sys.stderr)
        return 3
    if not os.path.isfile(path):
        print("FATAL: ONNX 不存在: %s" % path, file=sys.stderr)
        return 3

    model = onnx.load(path)
    opsets = ",".join("%s=%d" % (o.domain or "ai.onnx", o.version) for o in model.opset_import)
    print("ONNX: %s" % path)
    print("ONNX_IR version=%d opset=%s nodes=%d initializers=%d"
          % (model.ir_version, opsets, len(model.graph.node), len(model.graph.initializer)))

    n_f32 = 0
    n_zp_nz = 0        # 权重对称量化后 zp != 0 的个数 —— 应恒为 0
    max_rel = 0.0      # max(err/scale)（对称量化的半格上界应 <= 0.5）
    for init in model.graph.initializer:
        arr = numpy_helper.to_array(init)
        if arr.dtype != np.float32:
            continue
        n_f32 += 1
        s, z, _q, err = ptq_weight_tensor(arr)
        if arr.size and z != 0:
            n_zp_nz += 1
        if s > 0 and arr.size:
            max_rel = max(max_rel, err / s)
        print("W %-44s shape=%-16s min=%.6g max=%.6g scale=%.6g zp=%4d maxerr=%.6g"
              % (init.name, str(list(arr.shape)), float(arr.min()) if arr.size else 0.0,
                 float(arr.max()) if arr.size else 0.0, s, z, err))
    print("W_PTQ float32_initializers=%d symmetric=1 zp_nonzero=%d maxrel=%.4g shift=%d"
          % (n_f32, n_zp_nz, max_rel, SHIFT))
    return 0


# ============================ CLI ============================
def _find_opt(args, name, dflt=None):
    if name in args:
        i = args.index(name)
        if i + 1 < len(args):
            return args[i + 1]
    return dflt


def main(argv):
    args = argv[1:]
    if "--selftest" in args:
        return selftest(_find_opt(args, "--inject", "none"))
    if "--onnx" in args:
        p = _find_opt(args, "--onnx")
        if not p:
            print("FATAL: --onnx 需要一个路径", file=sys.stderr)
            return 3
        pc = _find_opt(args, "--percentile")
        return do_onnx(p, float(pc) if pc is not None else None)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
