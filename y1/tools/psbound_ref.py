#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""psbound_ref.py —— y1 **spec §3.7** 的界判据供料：**满幅度激励 + 两份预测**（32 bit / 24 bit）。

本节要证的一件事：`PartialSumBuf` 的行宽从 64 bit 收到 **32 bit** 之后，
**在可证界上的最坏激励下**数值仍**逐字节**等于冻结参考；而把它再收到 **24 bit**
（**低于可证界**）时**必红**（回绕 = 静默错值）。

可证界（spec §3.7，逐字）：
    `|acc| ≤ max|x|·max|w|·taps`，`x ∈ [-128,127]`、`w ∈ [-127,127]`（§4.5 对称量化 `z_w ≡ 0`）
    ⇒ `|x·w| ≤ 128×127 = 16,256`；taps 最大 = `(C_in/GROUP)×9 ≤ 64×9 = 576`（dense `C_in=64/GROUP=1`）
    ⇒ `|acc| ≤ 16,256 × 576 = 9,363,456 < 2^24` ⇒ **25 bit 有符号够**，32 bit 留 ~2^7 余量。

本文件**不写第三条算术**：黄金逐字复用 `tiling_ref.conv_tiled`（C4a.4 冻结的拆趟参考），
权重瓦片逐字复用 `multipass_ref.weight_tiles`（与冻结闸门同一份展开规则），requant 逐字复用
`quant_ref.requant_int`。本文件只做三件事：

  1. **造"顶到界"的激励**（两种极值极性，各一个用例）：
     · `pos`：`x ≡ +127`、`w ≡ +127` ⇒ 内部像素 acc = **+9,290,304** = 127·127·576（**码值正极值**）；
     · `neg`：`x ≡ -128`、`w ≡ +127` ⇒ 内部像素 acc = **-9,363,456** = 128·127·576（★ **就是可证界本身** ——
       界里的 128 来自 int8 码的**负偏斜** `x = -128`，正的极值只有 127 ⇒ 只有 `neg` 这一档能顶到界）。
     几何取缺省网表 `gen/MultiPassUnit.v`（`WIDTH=8`）能吃下的最大 tap 数：`C_in=64`（8 个 ci 趟 ×
     8 通道 × 9 taps = 576），`C_out=8`（1 个 co-block）、`H=4,W=8`（NPU 像素数 32 = `PIXMAX`）。
     ★ 边缘像素的 taps 少于 576（零填充）⇒ 只有**内部像素**顶到界；这正是"界"的定义。
  2. **两份预测**（都由冻结参考给出）：
     · `gold.hex`    —— 32 bit：`requant_int(acc, M, z_y)`（M = 2^24 单位乘子 ⇒ `= clamp(acc>>6)`）；
     · `gold_ps24.hex` —— 24 bit：`requant_int(wrap24(acc), M, z_y)`，`wrap24` = 24 bit 二补数回绕
       （RTL 的窄累加器在**最后一次加法**上溢出一次；中间部分和 |·| ≤ 8,193,024 < 2^23 ⇒ 不回绕）。
     判据（`tools/run_psbound_ab.sh`）：32 bit 网表**精确命中** `gold.hex`；24 bit 网表**精确命中**
     `gold_ps24.hex` **且** `!= gold.hex`（⇒ 负对照有牙，且错法被逐字节钉死）。
  3. **落盘** `x.hex / w.hex / b.hex / params.txt`（`MultiPassTb.v` 直接吃；`+M` = 2^24、`+ZY` = 0、
     `+PADV` = 0、`+ROWB` = 4/3），并把**参考侧的峰值 |acc|** 印出来（与装置实测的 `MP PEAKABS=` 对账）。

用法（全仓唯一可用 Python 组合）：
    cd /d/code/PDS/VexiiYeshenLinux/y1
    PYTHONIOENCODING=utf-8 PYTHONPATH='./.pydeps;../third_party/yunet/deps' \\
      <py> tools/psbound_ref.py --outdir gen/c4a_psbound
    ... tools/psbound_ref.py --selftest

退出码：0 = OK；1 = 判据红（顶不到界 / 预测退化 / 24 bit 预测 == 32 bit 预测）；3 = 前置缺失。
"""
import os
import sys
import argparse

import numpy as np

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import tiling_ref as T          # conv_tiled（C4a.4 冻结的拆趟参考）
import quant_ref as qref        # requant_int
import multipass_ref as MP      # weight_tiles / bias_of / dump_hex（与冻结闸门同一份展开规则）

# ---- 用例几何（= 缺省网表 gen/MultiPassUnit.v 的档位；见文件头）----
CI, CO, GG = 64, 8, 1           # taps = (CI/GROUP)*9 = 576（dense 上限）
H_IMG, W_IMG = 4, 8             # NPIX = 32 = PIXMAX（网表缺省）
ZY_OUT = 0                      # 输出 zero-point（本用例：z_y = 0）
# ★ 标度取 `(s_x·s_w)/s_y = 2^-6` ⇒ `M = round(ratio·2^30) = 2^24` —— 正是 RTL 口径里的
#   **单位乘子**（`((acc·2^24)>>24)>>6 == acc>>6`）；TB 用 `+M=16777216` 喂同一份数。
SX = SW = 0.125
SY = 1.0
UNIT_M = 1 << 24
TAPS_REACHED = (H_IMG - 2) * (W_IMG - 2)   # 顶到界的内部像素数（2 行 × 6 列 = 12）
TAPS_MAX = (CI // GG) * 9
BOUND = 128 * 127 * TAPS_MAX               # = 9,363,456（spec §3.7 的可证界）
CASES = [("pos", 127, 127), ("neg", -128, 127)]


def wrap_signed(v, bits):
    """二补数回绕到 `bits` 位有符号（RTL 窄累加器的截断语义）。"""
    m = 1 << bits
    return ((np.asarray(v, dtype=np.int64) + (m >> 1)) % m) - (m >> 1)


def build_case(name, xval, wval, outdir):
    """造一个用例：满幅度激励 + 两份预测 + 落盘。返回 (params, nums)。"""
    xq = np.full((1, CI, H_IMG, W_IMG), xval, dtype=np.int64)
    wq = np.full((CO, CI // GG, 3, 3), wval, dtype=np.int64)
    wd = {"q": wq.astype(np.int8), "scale": SW, "zp": 0}
    out, acc_full, parts, M = T.conv_tiled(
        xq, wd, SX, SY, 0, 0, None, [1, 1, 1, 1], [1, 1], GG, ZY_OUT, dump_passes=True)

    peak = int(np.max(np.abs(acc_full)))
    # ---- 逐趟写回的**存储**峰值（= 装置 `MP PEAKABS=` 的量具；逐字复刻 RTL 的"每趟截断写回"）----
    #   32 bit 档：每趟写回值 = 真实部分和（不截断）⇒ 上界 = peak；
    #   24 bit 档：每趟写回值 = wrap24(真实部分和) ⇒ 第 8 趟（> 2^23）被吃掉，存储峰值反而**下降**。
    accs = np.zeros_like(acc_full)
    peak_w32 = 0
    peak_w24 = 0
    for (i, j, a) in parts:
        accs[j * T.TILE: j * T.TILE + a.shape[0]] += a          # bias=None ⇒ 已折 0
        peak_w32 = max(peak_w32, int(np.max(np.abs(accs))))
        peak_w24 = max(peak_w24, int(np.max(np.abs(wrap_signed(accs, 24)))))
    gold = out.reshape(-1).astype(np.int8)
    gold24 = qref.requant_int(wrap_signed(acc_full, 24), M, ZY_OUT).reshape(-1).astype(np.int8)
    d24 = int(np.count_nonzero(gold24 != gold))

    d = os.path.join(outdir, name)
    os.makedirs(d, exist_ok=True)
    MP.dump_hex(os.path.join(d, "x.hex"), xq.reshape(-1))
    tiles = MP.weight_tiles(xq, wd, GG)
    MP.dump_hex(os.path.join(d, "w.hex"), np.concatenate([t.reshape(-1) for t in tiles]))
    btoks = []
    for j in range(T.n_passes(CO)):
        btoks += [int(v) for v in MP.bias_of(None, j)]
    MP.dump_hex(os.path.join(d, "b.hex"), btoks, w=8)
    MP.dump_hex(os.path.join(d, "gold.hex"), gold)
    MP.dump_hex(os.path.join(d, "gold_ps24.hex"), gold24)
    with open(os.path.join(d, "params.txt"), "w", encoding="ascii", newline="\n") as f:
        f.write("CIN=%d\nCOUT=%d\nGROUP=%d\nH=%d\nIW=%d\n" % (CI, CO, GG, H_IMG, W_IMG))
        f.write("M=%d\nZY=%d\nNCI=%d\nNCO=%d\nPASSES=%d\n" % (M, ZY_OUT, T.n_passes(CI), T.n_passes(CO),
                                                             T.n_passes(CI) * T.n_passes(CO)))
        f.write("XV=%d\nWV=%d\nTAPS=%d\nBOUND=%d\nPEAK_REF=%d\nD24=%d\n"
                % (xval, wval, TAPS_MAX, BOUND, peak, d24))
        f.write("PEAK_EXP=%d\nPEAK24_EXP=%d\n" % (peak_w32, peak_w24))

    params = {"case": name, "xval": xval, "wval": wval, "M": int(M), "taps": TAPS_MAX,
              "bound": BOUND, "peak_ref": peak, "peak_w32": peak_w32, "peak_w24": peak_w24, "d24": d24,
              "distinct": int(len(set(int(v) for v in gold))),
              "distinct24": int(len(set(int(v) for v in gold24))), "dir": d}
    nums = {"peak": peak, "d24": d24, "distinct": params["distinct"],
            "distinct24": params["distinct24"], "M_unit": (int(M) == UNIT_M)}
    return params, nums


def run(outdir):
    print("[psbound_ref] §3.7 满幅度激励：taps=%d（= (C_in/GROUP)×9）⇒ 可证界 |acc| ≤ %d" % (TAPS_MAX, BOUND))
    fails = []
    peaks = {}
    for (name, xval, wval) in CASES:
        p, n = build_case(name, xval, wval, outdir)
        # 本用例自己的极值：`|x·w|·taps`（`x = -128` 时 |x| = 128，其余按码值）
        case_bound = (128 if xval == -128 else abs(xval)) * abs(wval) * TAPS_MAX
        peaks[name] = n["peak"]
        print("PSBOUND %s x=%d w=%d M=%d taps=%d peak|acc|(ref)=%d case_bound=%d bound=%d "
              "stored_peak(w32=%d,w24=%d) gold24!=gold(diff_bytes)=%d distinct(gold=%d,24=%d) dir=%s"
              % (name, xval, wval, p["M"], p["taps"], n["peak"], case_bound, p["bound"],
                 p["peak_w32"], p["peak_w24"], n["d24"], n["distinct"], n["distinct24"], p["dir"]))
        if p["peak_w32"] != n["peak"]:
            fails.append("%s：逐趟写回峰值 %d != 参考峰值 %d（量具模型对不上）" % (name, p["peak_w32"], n["peak"]))
        # 判据（供料侧自检；装置侧由 run_psbound_ab.sh 判）
        if n["peak"] != case_bound:
            fails.append("%s：参考峰值 %d != 本档极值 %d ⇒ 激励没顶到界" % (name, n["peak"], case_bound))
        if not n["M_unit"]:
            fails.append("%s：M=%d != 2^24（单位乘子）⇒ 判据不再是纯 >>6" % (name, p["M"]))
        if n["distinct24"] <= 1:
            fails.append("%s：24 bit 预测退化（distinct24=%d）" % (name, n["distinct24"]))
        if n["d24"] <= 0:
            fails.append("%s：24 bit 预测 == 32 bit 预测 ⇒ 负对照没牙（没顶到界？）" % name)
    if max(peaks.values()) != BOUND:
        fails.append("两档的峰值上界 %d != spec §3.7 的可证界 %d ⇒ 没有一档顶到界"
                     % (max(peaks.values()), BOUND))
    if fails:
        for f in fails:
            print("  FAIL  %s" % f)
        print("RESULT: FAIL")
        return 1
    print("PSBOUND_REF cases=%d BOUND=%d TAPS=%d INTERIOR_PX=%d" % (len(CASES), BOUND, TAPS_MAX, TAPS_REACHED))
    print("RESULT: PASS")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--outdir", default=os.path.abspath(os.path.join(_HERE, "..", "gen", "c4a_psbound")))
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            return run(td)
    return run(os.path.abspath(a.outdir))


if __name__ == "__main__":
    sys.exit(main())
