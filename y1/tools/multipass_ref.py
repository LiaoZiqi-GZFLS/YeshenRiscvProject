#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""multipass_ref.py —— y1 C4a.5a：**多趟累加 RTL 的向量 + 黄金**（G3 硬件半边的判据供料）。

本文件**不重写**任何参考算术：整层黄金逐字复用 `tiling_ref.conv_tiled`（= C4a.4 冻结的
「拆趟 == 整层」参考）+ `quant_ref.conv_vec`（= C4a.2 冻结的同口径整层参考），两者
**互相钉死**（本文件对每个形状都断言 `conv_tiled == conv_vec`）。本文件只做三件事：

  1. **造一个可跑的"宽层"**：形状取自 `gen/c4a_tiling/c4a_tiling.json`（C4a.4 真表形状集合，
     去重后的 `(C_in,C_out,GROUP)`），数据是**确定性合成**的（seeded RNG）。
     ★ 冻结口径：本闸门只给 `z_x = z_w = 0`（**无 zero-point 中心化**）的 int8 瓦片 —— 因为
       `Conv3x3Slice` 的 MAC 是 `mac_ref` 口径（`Σ x·w`，**没有** zero-point 减法的口；中心化
       属数据通路的上游，C4a.5b/C4a.6）。于是 `quant_ref` 的 affine 算术在本用例里**恰好**退化成
       切片的整数 MAC（`x_q - z_x = x_q`、`w_q - z_w = w_q`），逐字节对账才有意义。
       `z_y` 与每层乘子 `M` **非退化**（`z_y != 0`、`M != 2^24`）⇒ `+ z_y` 与乘子两条路都被走到。
  2. **落盘 RTL 要吃的文件**（`x/w/b`）与**四份预测黄金**：
     · `gold.hex`      —— 正对照（整层黄金，M = 真乘子）；
     · `gold_unity.hex`—— `M = 2^24` 的预测（⇒ `((acc·2^24)>>24)>>6 == acc>>6`；乘子确实生效的判据）；
     · `gold_drop.hex` —— **负对照 A1**：整层漏一个 `ci` 趟（TB 的 `+DROPCI=i`）；
     · `gold_nops.hex` —— **负对照 A2**：部分和**从不写回**（网表突变把 `PartialSumBuf` 的写口关掉）
                             ⇒ 每一趟都读到 0 ⇒ 末趟输出 = 只 requant 末趟 partial；
     · `gold_mutb.hex` —— **负对照 B**：部分和缓冲**初值非 0**（网表突变把 `.init` 的 co=0 行改成 K）
                             ⇒ 第 1 趟读到 K ⇒ 整层 acc 恰好 +K（且**只**影响每个 co-block 的第 0 个 co）。
  3. **判据自检**（`--selftest` / 每个形状在线）：四份预测必须**都 != 黄金**（否则那条负对照没牙），
     且黄金**非常数**（`distinct > 1`，退化守卫）。

用法（全仓唯一可用 Python 组合）：
    cd /d/code/PDS/VexiiYeshenLinux/y1
    PYTHONIOENCODING=utf-8 PYTHONPATH='./.pydeps;../third_party/yunet/deps' \\
      <py> tools/multipass_ref.py --gate --outdir gen/c4a_mp
    ... tools/multipass_ref.py --selftest

退出码：0 = OK；1 = 判据红（拆趟 != 整层 / 黄金退化）；2 = 负对照没牙（预测 == 黄金）；
        3 = 前置缺失（缺 shapes json）。
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

# ---- 唯一真源（逐字复用；**不**重写量化器 / conv 数学 / 拆趟规则）----
import tiling_ref as T        # conv_tiled（C4a.4 冻结的拆趟参考）+ n_passes + TILE
import quant_ref as qref      # conv_vec（C4a.2 冻结的整层参考）+ REQUANT_Q / SHIFT

TILE = T.TILE
REQUANT_Q = qref.REQUANT_Q
SHIFT = qref.SHIFT

DEFAULT_SHAPES = os.path.abspath(os.path.join(_HERE, "..", "gen", "c4a_tiling", "c4a_tiling.json"))
DEFAULT_OUTDIR = os.path.abspath(os.path.join(_HERE, "..", "gen", "c4a_mp"))

# ---- 用例冻结常量 ----
H_IMG = 4          # 图高（喂 H+1 行，最后一行是全 0 pad 行）
W_IMG = 8          # 图宽（= 网表 WIDTH，装置在 time 0 与 `imgW` 对账）
X_RANGE = 20       # 激活码点范围 [-20,20]（留足 int32 余量、又让 requant 后的分布铺得开）
W_RANGE = 20       # 权重码点范围 [-20,20]
Z_Y = -7           # 输出 zero-point（**非 0** ⇒ `+ z_y` 这条路被走到）
UNITY_M = 1 << 24  # 单位乘子（`((acc·M)>>24)>>6 == acc>>6` 的 M）
MUT_B_K = 13       # 负对照 B 的初值（写进缓冲 co 行 0）


def md5_bytes(b):
    return hashlib.md5(b).hexdigest()


def dump_hex(path, toks, w=2):
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("".join(("%0" + str(w) + "x\n") % (int(t) & ((1 << (4 * w)) - 1)) for t in toks))


def make_layer(ci, co, gg, seed):
    """造一个确定性的 `(C_in,C_out,GROUP)` 层：z_x = z_w = 0，非退化 z_y/M。

    ★ 偏置的**两种单位**必须分清（本文件唯一的一个坑，踩过）：
      · `bfloat`  —— **实数**偏置（`quant_ref.conv_vec` / `tiling_ref.conv_tiled` 吃这个，
                     它们内部再 `round(b/(s_x·s_w))` 折算到累加器单位）；
      · `biasb`   —— **累加器单位**（`round(b/(s_x·s_w))`），**RTL 吃这个**（`Conv3x3Slice.bias`
                     就是累加器单位的偏置）。把 `biasb` 当 `bfloat` 再喂回参考 ⇒ 偏偏置被折算两次
                     （实测 ±80000，输出整片饱和、distinct 塌成 2 ⇒ 负对照全部没牙）。
    """
    rng = np.random.default_rng(seed)
    xq = rng.integers(-X_RANGE, X_RANGE + 1, size=(1, ci, H_IMG, W_IMG), dtype=np.int64)
    cig = ci // gg
    wq = rng.integers(-W_RANGE, W_RANGE + 1, size=(co, cig, 3, 3), dtype=np.int64)
    # 标度：ratio = s_x·s_w/s_y = 0.05 ⇒ M ≈ 5.4e7（≠ 2^24）⇒ 乘子这条路非平凡。
    sx, sw, sy = 0.05, 0.05, 0.05
    bfloat = rng.uniform(-0.5, 0.5, size=co)
    biasb = np.round(bfloat / (sx * sw)).astype(np.int64)   # 累加器单位（与 conv_vec/conv_tiled 同一条式子）
    wd = {"q": wq.astype(np.int8), "scale": sw, "zp": 0}
    return xq, wd, sx, sy, bfloat, biasb


def passes_of(ci, co):
    return T.n_passes(ci), T.n_passes(co)


def weight_tiles(xq, wd, gg):
    """按 C4a.4 冻结的"每趟权重瓦片"规则预展开全部趟的瓦片（**与 conv_tiled 逐字同源**）。

    每趟瓦片 = `[8co_local][8ci_local][3][3]`，先全填 `z_w`（= 0）⇒ 被 SKIP 的输入通道与跨组位置
    的中心化权重恰为 0（贡献 0，与补进来的输入无关）。展平顺序 = `GroupMask.weightAddr`
    = `[co][ci_local][ky][kx]`（`Conv3x3Slice` 文件头）。
    """
    ci, co = xq.shape[1], wd["q"].shape[0]
    cig = ci // gg
    cog = co // gg
    n_ci, n_co = passes_of(ci, co)
    tiles = []
    for j in range(n_co):
        co0, co_t = j * TILE, min(TILE, co - j * TILE)
        for i in range(n_ci):
            ci0, ci_t = i * TILE, min(TILE, ci - i * TILE)
            t = np.zeros((TILE, TILE, 3, 3), dtype=np.int64)          # 默认 = z_w = 0
            for r in range(co_t):
                gco = (co0 + r) // cog
                for s in range(ci_t):
                    gci = (ci0 + s) // cig
                    if gco != gci:
                        continue
                    t[r, s] = wd["q"][co0 + r, (ci0 + s) - gci * cig]
            tiles.append(t)
    return tiles


def bias_of(biasp, j):
    """第 `j` 个 co-block 的 8 个偏置（累加器单位，int32）；`biasp=None` ⇒ 全 0。"""
    out = [0] * TILE
    if biasp is not None:
        for r in range(TILE):
            k = j * TILE + r
            if k < len(biasp):
                out[r] = int(biasp[k])
    return out


def build_one(ci, co, gg, seed, outdir):
    """一个形状：算黄金 + 落盘。返回 (params dict, 判据数字 dict)。"""
    xq, wd, sx, sy, bfloat, biasb = make_layer(ci, co, gg, seed)
    pads, strides = [1, 1, 1, 1], [1, 1]

    # ---- 整层参考（C4a.2 冻结；第二实现）----
    whole = qref.conv_vec(xq, wd, sx, sy, 0, 0, bfloat, pads, strides, gg, Z_Y)
    # ---- 拆趟参考（C4a.4 冻结；黄金）----
    tiled, acc_full, parts, M = T.conv_tiled(xq, wd, sx, sy, 0, 0, bfloat, pads, strides, gg, Z_Y,
                                             dump_passes=True)
    n_ci, n_co = passes_of(ci, co)

    # ---- 四份预测 ----
    gold = tiled.reshape(-1).astype(np.int8)
    # 2^24 单位乘子（== `clamp(acc>>6 + z_y)`）
    gold_unity = qref.requant_int(acc_full, UNITY_M, Z_Y).reshape(-1)
    # 漏一个 ci 趟（TB 的 +DROPCI=i）：对所有 co-block 都漏同一趟（与 conv_tiled 的 drop_ci_block 同义）
    # ★ 漏的必须是**非收集趟**：装置只在末趟（i == n_ci-1）收集输出 ⇒ 若漏末趟，该 co-block 整块
    #   不会产出（装置侧全 0），与 `conv_tiled(drop_ci_block=末趟)` 的预测就对不上了。
    #   取第 0 趟：连"bias 折进第 1 趟"这条规则一起被验证（漏它不是只丢 8 个通道的抽头）。
    drop_i = 0 if n_ci > 1 else 0
    gold_drop = T.conv_tiled(xq, wd, sx, sy, 0, 0, bfloat, pads, strides, gg, Z_Y,
                             drop_ci_block=drop_i)[0].reshape(-1).astype(np.int8)
    # 部分和从不写回：每一趟都读到 0 ⇒ 末趟输出 = requant(末趟 partial)
    last = np.zeros((co, H_IMG, W_IMG), dtype=np.int64)
    for (i, j, a) in parts:
        if i == n_ci - 1:
            last[j * TILE: j * TILE + a.shape[0]] = a
    gold_nops = qref.requant_int(last, M, Z_Y).reshape(-1)
    # 缓冲初值非 0：只影响每个 co-block 的第 0 行（= 输出通道 8j）
    acc_mutb = acc_full.copy()
    for j in range(n_co):
        acc_mutb[j * TILE] += MUT_B_K
    gold_mutb = qref.requant_int(acc_mutb, M, Z_Y).reshape(-1)

    gset = set(int(v) for v in gold)
    d_whole = int(np.count_nonzero(whole.reshape(-1) != gold))
    d_unity = int(np.count_nonzero(gold_unity != gold))
    d_drop = int(np.count_nonzero(gold_drop != gold))
    d_nops = int(np.count_nonzero(gold_nops != gold))
    d_mutb = int(np.count_nonzero(gold_mutb != gold))

    # ---- 落盘 ----
    d = outdir
    os.makedirs(d, exist_ok=True)
    dump_hex(os.path.join(d, "x.hex"), xq.reshape(-1))
    tiles = weight_tiles(xq, wd, gg)
    dump_hex(os.path.join(d, "w.hex"), np.concatenate([t.reshape(-1) for t in tiles]))
    btoks = []
    for j in range(n_co):
        btoks += [int(v) for v in bias_of(biasb, j)]
    dump_hex(os.path.join(d, "b.hex"), btoks, w=8)
    dump_hex(os.path.join(d, "gold.hex"), gold)
    dump_hex(os.path.join(d, "gold_unity.hex"), gold_unity)
    dump_hex(os.path.join(d, "gold_drop.hex"), gold_drop)
    dump_hex(os.path.join(d, "gold_nops.hex"), gold_nops)
    dump_hex(os.path.join(d, "gold_mutb.hex"), gold_mutb)
    with open(os.path.join(d, "params.txt"), "w", encoding="ascii", newline="\n") as f:
        f.write("CIN=%d\nCOUT=%d\nGROUP=%d\nH=%d\nIW=%d\n" % (ci, co, gg, H_IMG, W_IMG))
        f.write("M=%d\nZY=%d\nNCI=%d\nNCO=%d\nPASSES=%d\nDROPCI=%d\n" % (M, Z_Y, n_ci, n_co, n_ci * n_co, drop_i))
        f.write("MUTB_K=%d\n" % MUT_B_K)

    params = {"cin": ci, "cout": co, "group": gg, "n_ci": n_ci, "n_co": n_co,
              "passes": n_ci * n_co, "M": int(M), "zy": Z_Y, "droppi": drop_i,
              "h": H_IMG, "w": W_IMG, "mutb_k": MUT_B_K, "dir": d}
    nums = {"d_whole": d_whole, "d_unity": d_unity, "d_drop": d_drop,
            "d_nops": d_nops, "d_mutb": d_mutb, "distinct": len(gset),
            "md5": md5_bytes(np.ascontiguousarray(gold).tobytes())}
    return params, nums


def chk(cond, msg, fails):
    print("  %s  %s" % ("PASS" if cond else "FAIL", msg))
    if not cond:
        fails.append(msg)


def selftest():
    print("[multipass_ref] selftest：拆趟 == 整层 + 四份预测都有牙 + 退化守卫")
    fails = []
    cases = [(3, 16, 1), (16, 16, 1), (64, 64, 1), (64, 10, 1), (16, 32, 1),
             (10, 10, 10), (16, 16, 16), (64, 4, 1)]
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        for k, (ci, co, gg) in enumerate(cases):
            p, n = build_one(ci, co, gg, 7000 + k, td)
            chk(n["d_whole"] == 0, "ci=%d co=%d g=%d：拆趟 == 整层（差 %d）" % (ci, co, gg, n["d_whole"]), fails)
            chk(n["distinct"] > 1, "退化守卫 ci=%d co=%d g=%d：黄金非常数（distinct=%d）"
                % (ci, co, gg, n["distinct"]), fails)
            chk(n["d_unity"] > 0, "M=2^24 预测 != 黄金（差 %d）⇒ 乘子这条路有分辨度" % n["d_unity"], fails)
            chk(n["d_drop"] > 0, "负对照 A1（漏一趟）预测 != 黄金（差 %d）" % n["d_drop"], fails)
            if p["n_ci"] >= 2:
                chk(n["d_nops"] > 0, "负对照 A2（不写回）预测 != 黄金（差 %d）" % n["d_nops"], fails)
            else:
                print("  N/A   负对照 A2（不写回）：本形状 %d 个 ci 趟 ⇒ 没有跨趟累加可漏（结构性不适用）" % p["n_ci"])
            chk(n["d_mutb"] > 0, "负对照 B（初值非 0）预测 != 黄金（差 %d）" % n["d_mutb"], fails)
    print("SELFTEST_MULTIPASS cases=%d fails=%d" % (len(cases), len(fails)))
    if fails:
        print("RESULT: FAIL")
        return 1
    print("RESULT: PASS")
    return 0


def wide_shapes(shapes_json):
    """`gen/c4a_tiling/c4a_tiling.json` 的 `rows[].shape`（= C4a.4 真表形状）里**宽**的那些。"""
    j = json.load(open(shapes_json, encoding="utf-8"))
    seen = {}
    for r in j["rows"]:
        ci, co, gg = (int(v) for v in r["shape"])
        seen.setdefault((ci, co, gg), r.get("rep", "?"))
    shapes = [k for k in seen if (k[0] > TILE or k[1] > TILE)]
    return sorted(shapes), seen


def gate(args):
    if not os.path.isfile(args.shapes):
        print("FATAL: 缺形状集合 %s（先跑 tools/tiling_ref.py --gate --dump）" % args.shapes)
        return 3
    shapes, rep = wide_shapes(args.shapes)
    print("GATE shapes_json=%s wide_shapes=%d" % (os.path.basename(args.shapes), len(shapes)))
    fails = []
    toothless = []
    for k, (ci, co, gg) in enumerate(shapes):
        d = os.path.join(args.outdir, "shape_%dc_%do_%dg" % (ci, co, gg))
        p, n = build_one(ci, co, gg, 9100 + 37 * k, d)
        print("SHAPE cin=%-3d cout=%-3d group=%-3d n_ci=%d n_co=%d passes=%-3d M=%-10d ZY=%-4d "
              "WHOLE_MISMATCH=%d distinct=%-4d D_UNITY=%-6d D_DROP=%-6d D_NOPS=%-6d D_MUTB=%-6d gold_md5=%s"
              % (ci, co, gg, p["n_ci"], p["n_co"], p["passes"], p["M"], p["zy"],
                 n["d_whole"], n["distinct"], n["d_unity"], n["d_drop"], n["d_nops"], n["d_mutb"], n["md5"]))
        if n["d_whole"] != 0:
            fails.append("shape(%d,%d,%d)：拆趟 != 整层" % (ci, co, gg))
        if n["distinct"] <= 1:
            fails.append("shape(%d,%d,%d)：黄金是常数（退化）" % (ci, co, gg))
        if n["d_unity"] == 0:
            toothless.append("shape(%d,%d,%d)：M=2^24 预测 == 黄金" % (ci, co, gg))
        if n["d_drop"] == 0:
            toothless.append("shape(%d,%d,%d)：漏一趟预测 == 黄金" % (ci, co, gg))
        if p["n_ci"] >= 2 and n["d_nops"] == 0:
            toothless.append("shape(%d,%d,%d)：不写回预测 == 黄金" % (ci, co, gg))
        if n["d_mutb"] == 0:
            toothless.append("shape(%d,%d,%d)：初值非 0 预测 == 黄金" % (ci, co, gg))
    print("SHAPES_WIDE=%d WHOLE_BAD=%d DEGEN_BAD=%d TOOTHLESS=%d"
          % (len(shapes), len(fails), sum(1 for f in fails if "常数" in f), len(toothless)))
    if fails:
        print("MULTIPASS_REF: FAIL (%d)" % len(fails))
        print("RESULT: FAIL")
        return 1
    if toothless:
        print("MULTIPASS_REF: FAIL 负对照没牙：%s" % toothless)
        print("RESULT: FAIL")
        return 2
    print("MULTIPASS_REF: PASS（真表宽形状 %d 种；拆趟==整层；四份预测都有牙；黄金非退化）" % len(shapes))
    print("RESULT: PASS")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--gate", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--shapes", default=DEFAULT_SHAPES)
    ap.add_argument("--outdir", default=DEFAULT_OUTDIR)
    args = ap.parse_args(argv[1:])
    if args.selftest:
        return selftest()
    if args.gate:
        return gate(args)
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
