#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""wide_exec_ref.py —— y1 C4a.5b：**宽层多趟通路（UnitExec 级）**的向量 + 黄金供料。

被测行为（`rtl/UnitExec.scala` 的 `WIDERUN` 通路 + `MultiPassUnit`/`PartialSumBuf` + §4.4/§4.5 参数）：
  一个**宽层**（`C_in>8 || C_out>8`）经**权置信箱**把 §4.4 的 `M`、§4.5 的 `z_pad/z_y/bias_adj` 按 `LAYER_ID`
  灌进片上参数表 ⇒ `UnitExec` 自己驱动 `ceil(C_in/8)×ceil(C_out/8)` 趟（`ci` 趟在片上部分和里跨趟累加，
  **只在末趟做唯一一次 requant**）⇒ pad 行/列用 `z_pad`（真 0 码点）⇒ 输出落 `DST`。

★ 本文件**不重写**任何量化/卷积算术：黄金 = §4.5-A 的**硬件口径**（与 `tools/y1_convert.py` 的
  `hw_conv_variants` 同一条式子），并且**逐字节自检**它等于"按 (co-block, ci-block) 拆趟再累加"的结果
  （即 C4a.4 冻结的"拆趟 == 整层"恒等式在本用例上成立）。

用例（默认 = **真层** `Conv_0`，来自 `gen/wgt_index.json` + `gen/wgt_blob.bin`）：
  C_IN=3 C_OUT=16 3x3、`z_x = z_pad = -128`（**非 0**）、`z_y = 41`、`M = 57384`、`bias_adj[16]`。
  ⇒ 宽（C_OUT>8）、pad 码点非 0（**pad 这条路真有分辨度**）、真乘子非单位元。
  另可用 `--synth CIN COUT` 造**合成宽层**（默认 16→16）专门打**跨 ci 趟累加**（`n_ci ≥ 2`）。

落盘（TB/闸门消费）：
  `job.txt`  —— 标量（CIN/COUT/GROUP/H/W/TYPE/FLAGS/SRC/DST/IN_BYTES/QSHIFT/LID/M/ZPAD/ZY/NCI/NCO/NCOL/NPASS）
  `w.hex`    —— **趟序**权重瓦片字节流（每趟 576 = `[co_local][ci_local][ky][kx]`；SKIP/跨组填 0）
  `x.hex`    —— `wide_x` 列流：一趟 `H` 行 × `W` 列 × 8 通道（趟序 = co-block 外、ci-block 内）；
                **pad 行由 `UnitExec` 自己合成（= `z_pad`）**，装置不喂。
  `b.hex`    —— `bias_adj`（每行 8 个十六进制数字 = int32，`[co-block][co]`）
  `gold.hex` —— 黄金 `[co][y][x]`（`C_OUT*H*W` 字节）
  `gold_pad0.hex` / `gold_nobias.hex` —— 两条**负对照**的预测（pad 用字节 0 / `bias_adj` 全 0）

退出码：0 = OK；1 = 判据红（拆趟 != 整层 / 黄金退化）；2 = 负对照没牙（预测 == 黄金）；3 = 前置缺失。
"""
import os
import sys
import json
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

REQUANT_Q = 24
SHIFT = 6
TILE = 8

DEFAULT_INDEX = os.path.abspath(os.path.join(_HERE, "..", "gen", "wgt_index.json"))
DEFAULT_BLOB = os.path.abspath(os.path.join(_HERE, "..", "gen", "wgt_blob.bin"))
DEFAULT_OUTDIR = os.path.abspath(os.path.join(_HERE, "..", "gen", "c4a_wide"))


def dump_hex(path, toks, w=2):
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("".join(("%0" + str(w) + "x\n") % (int(t) & ((1 << (4 * w)) - 1)) for t in toks))


def requant(acc, M, zy):
    y = ((np.asarray(acc, dtype=np.int64) * np.int64(M)) >> REQUANT_Q) >> SHIFT
    return np.clip(y + np.int64(zy), -128, 127).astype(np.int8)


def conv_acc(x8, wseg, padval, bias):
    """§4.5-A 硬件口径的 **int32 acc**（`Σ x_q·w_q + bias`；补位用 `padval`，**不**做 (x−z_x)）。

    `x8` = (1, CI8, H, W) 8 通道铺开的输入；`wseg` = (CO, CI8, 3, 3) 冻结布局（1×1 的其余抽头为 0）。
    """
    CO, CG, KH, KW = wseg.shape
    H, W = x8.shape[2], x8.shape[3]
    xp = np.pad(x8.astype(np.int64), ((0, 0), (0, 0), (1, 1), (1, 1)), constant_values=int(padval))
    acc = np.zeros((CO, H, W), dtype=np.int64)
    for ky in range(3):
        for kx in range(3):
            xs = xp[0, :, ky:ky + H, kx:kx + W]
            for ci in range(CG):
                acc += wseg[:, ci, ky, kx][:, None, None] * xs[ci][None, :, :]
    return acc + np.asarray(bias, dtype=np.int64)[:, None, None]


def build_real(index_path, blob_path, lid):
    """从**真转换器产物**读一层的权重 + §4.4/§4.5 参数（默认 `Conv_0`）。"""
    idx = json.load(open(index_path, encoding="utf-8"))
    u = [x for x in idx["units"] if x["idx"] == lid][0]
    cen = [x for x in idx["centering"] if x["layer_id"] == lid][0]
    req = [x for x in idx["requant_mult"] if x["layer_id"] == lid][0]
    w = u["weight"]
    blob = open(blob_path, "rb").read()
    co, ci = int(u["own"]["C_OUT"]), int(u["own"]["C_IN"])
    wraw = np.frombuffer(blob[w["offset"]:w["offset"] + w["nbytes"]], dtype=np.int8).reshape(co, ci, 3, 3)
    return {"cin": ci, "cout": co, "w": wraw.astype(np.int64), "M": int(req["M"]),
            "z_pad": int(cen["z_pad"]), "z_y": int(cen["z_y"]),
            "bias_adj": np.asarray(cen["bias_adj"], dtype=np.int64), "name": u["name"]}


def build_synth(cin, cout, seed=4242):
    """合成宽层（专打 `n_ci ≥ 2` 的跨趟累加）：真 3x3 核、`z_x = -128`、非单位乘子。

    ★ 量程是**调过**的（实测：`M=3e6`、`w∈[-10,10]` ⇒ 黄金 distinct=64、两条负对照都发火）——
      合成层的目的是**打跨趟累加与 pad 码点这两条路**，不是复现真网的标度。"""
    w = np.random.default_rng(seed).integers(-10, 11, size=(cout, cin, 3, 3), dtype=np.int64)
    g = np.random.default_rng(seed + 1)
    return {"cin": cin, "cout": cout, "w": w, "M": 3_000_000,
            "z_pad": -128, "z_y": int(g.integers(-2, 3)),
            "bias_adj": g.integers(-10, 11, size=cout).astype(np.int64),
            "name": "Synth_%d_%d" % (cin, cout)}


def build_one(spec, H, W, outdir, seed=99):
    cin, cout = int(spec["cin"]), int(spec["cout"])
    w, M, zp, zy, bj = spec["w"], int(spec["M"]), int(spec["z_pad"]), int(spec["z_y"]), spec["bias_adj"]
    n_ci = (cin + TILE - 1) // TILE
    n_co = (cout + TILE - 1) // TILE
    CI8, CO8 = n_ci * TILE, n_co * TILE

    xq = np.random.default_rng(seed).integers(-20, 21, size=(1, cin, H, W)).astype(np.int64)
    x8 = np.zeros((1, CI8, H, W), dtype=np.int64)
    x8[0, :cin] = xq[0]
    # 整层 8 通道口径的权重（缺的通道/行填 0 ⇒ 零贡献）
    wfull = np.zeros((CO8, CI8, 3, 3), dtype=np.int64)
    wfull[:cout, :cin] = w
    # 趟瓦片（供 wRam；趟序 = co-block 外、ci-block 内）
    tiles = np.zeros((n_co * n_ci, TILE, TILE, 3, 3), dtype=np.int64)
    for cob in range(n_co):
        for ci in range(n_ci):
            tiles[cob * n_ci + ci] = wfull[cob * TILE:(cob + 1) * TILE, ci * TILE:(ci + 1) * TILE]
    bj8 = np.zeros(CO8, dtype=np.int64)
    bj8[:cout] = bj

    # ---- 整层 acc 与拆趟累加 acc（**必须逐字节相同** = C4a.4 恒等式）----
    acc_full = conv_acc(x8, wfull, zp, bj8)
    acc_tiled = np.zeros((CO8, H, W), dtype=np.int64)
    for cob in range(n_co):
        for ci in range(n_ci):
            p = conv_acc(x8[:, ci * TILE:(ci + 1) * TILE],
                         wfull[cob * TILE:(cob + 1) * TILE, ci * TILE:(ci + 1) * TILE], zp, np.zeros(TILE))
            acc_tiled[cob * TILE:(cob + 1) * TILE] += p
    acc_tiled += bj8[:, None, None]
    tiled_eq = bool(np.array_equal(acc_full, acc_tiled))

    acc_pad0 = conv_acc(x8, wfull, 0, bj8)              # 负对照 a：pad 用**字节 0**
    acc_nobias = conv_acc(x8, wfull, zp, np.zeros(CO8))  # 负对照 b：`bias_adj` 全 0
    gold = requant(acc_full, M, zy)[:cout]
    gold_pad0 = requant(acc_pad0, M, zy)[:cout]
    gold_nobias = requant(acc_nobias, M, zy)[:cout]
    g = gold.reshape(-1).tolist()
    degenerate = len(set(g)) <= 1
    d_pad0 = int(np.count_nonzero(gold_pad0 != gold))
    d_nobias = int(np.count_nonzero(gold_nobias != gold))

    # ---- `wide_x` 列流：趟序（co-block 外、ci-block 内），每趟 `H*W` 列、每列 **8 个通道**
    #      （列 = 一个像素的 `[ci_local=0..7]`；`x8` 是 `[channel][y][x]` ⇒ transpose 到 `[y][x][channel]`）----
    xstream = np.concatenate([x8[0, ci * TILE:(ci + 1) * TILE].transpose(1, 2, 0).reshape(-1)
                              for _ in range(n_co) for ci in range(n_ci)])
    # ---- ★★ C4b-B3：**输入张量的冻结布局**（通道平面 / NCHW）+ 预期的列流 + 负对照 ----
    #   冻结契约（见 `y1/reports/c4b_input_layout.md`）：DDR 上的激活张量按**通道平面**存放，
    #   元素 `(c, p)`（`p = y*W + x`）落在 `SRC_ADDR + c*H*W + p`；`C_in % 8 != 0` 的那些通道
    #   （真表 `Conv_0` 的 3..7）**不存在于张量里** ⇒ 由 RTL 侧零填充（与 B1c 权重零填充同口径）。
    #   ⇒ `xin.hex` 落盘的字节数 = `C_in*H*W`（= 宿主真正要写到 DDR 的那张图）。
    #   预期列流 == 既有 `x.hex`（同一张量经 gather 后的行主序 8 通道列流）。
    xin = np.ascontiguousarray(x8[0][:cin]).reshape(-1).astype(np.int8)
    #   负对照：**通道序反**（平面序反转）—— 写入同一张 DDR 图，但元素错位 ⇒ gather 出来的列
    #   逐字节与预期不同（且输出 != 黄金）。这是"布局写错 ⇒ 必须红"的靶子。
    xin_bad = np.ascontiguousarray(x8[0][:cin][::-1]).reshape(-1).astype(np.int8)
    os.makedirs(outdir, exist_ok=True)
    dump_hex(os.path.join(outdir, "xin.hex"), xin)
    dump_hex(os.path.join(outdir, "xin_bad.hex"), xin_bad)
    dump_hex(os.path.join(outdir, "w.hex"), tiles.reshape(-1))
    dump_hex(os.path.join(outdir, "x.hex"), xstream)
    dump_hex(os.path.join(outdir, "b.hex"), bj8, w=8)
    dump_hex(os.path.join(outdir, "gold.hex"), gold.reshape(-1))
    dump_hex(os.path.join(outdir, "gold_pad0.hex"), gold_pad0.reshape(-1))
    dump_hex(os.path.join(outdir, "gold_nobias.hex"), gold_nobias.reshape(-1))
    with open(os.path.join(outdir, "job.txt"), "w", encoding="ascii", newline="\n") as f:
        f.write("NAME=%s\n" % spec["name"])
        f.write("CIN=%d\nCOUT=%d\nGROUP=1\nH=%d\nW=%d\n" % (cin, cout, H, W))
        f.write("TYPE=1\nFLAGS=1\nSRC=%d\nDST=%d\n" % (0x20000, 0x200000))
        f.write("IN_BYTES=%d\nQSHIFT=%d\nLID=0\n" % (cin * H * W, SHIFT))
        f.write("M=%d\nZPAD=%d\nZY=%d\n" % (M, zp, zy))
        f.write("NCI=%d\nNCO=%d\nNCOL=%d\nNPASS=%d\n" % (n_ci, n_co, n_co * n_ci * H * W, n_ci * n_co))
        # ★★ C4b-B3：gather 从 DDR **应读**的字节数 = Σ_趟 (本趟有效平面数 × H*W)
        #   （每个 co-block 都要把 n_ci 个 ci-block 的平面各读一遍 ⇒ 乘 n_co）。
        xexp = n_co * sum(min(TILE, cin - TILE * i) for i in range(n_ci)) * H * W
        f.write("XEXP=%d\n" % xexp)
    return {"cin": cin, "cout": cout, "n_ci": n_ci, "n_co": n_co, "M": M, "zp": zp, "zy": zy,
            "tiled_eq": tiled_eq, "degenerate": degenerate, "distinct": len(set(g)),
            "d_pad0": d_pad0, "d_nobias": d_nobias, "NCOL": n_co * n_ci * H * W,
            "tile_nonzero": int(np.count_nonzero(tiles)), "dir": outdir}


def main(argv):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--outdir", default=DEFAULT_OUTDIR)
    ap.add_argument("--index", default=DEFAULT_INDEX)
    ap.add_argument("--blob", default=DEFAULT_BLOB)
    ap.add_argument("--lid", type=int, default=0)
    ap.add_argument("--synth", nargs=2, type=int, metavar=("CIN", "COUT"))
    ap.add_argument("--H", type=int, default=4)
    ap.add_argument("--W", type=int, default=64)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv[1:])

    if args.selftest:
        fails = 0
        for sp in [build_synth(16, 16), build_synth(16, 24), build_synth(24, 16)]:
            r = build_one(sp, 4, 8, os.path.join(args.outdir, "selftest_%d_%d" % (sp["cin"], sp["cout"])))
            ok = r["tiled_eq"] and (not r["degenerate"]) and r["d_pad0"] > 0 and r["d_nobias"] > 0
            print("SELFTEST %-14s tiled_eq=%d distinct=%-4d d_pad0=%-6d d_nobias=%-6d %s"
                  % (sp["name"], r["tiled_eq"], r["distinct"], r["d_pad0"], r["d_nobias"],
                     "PASS" if ok else "FAIL"))
            fails += 0 if ok else 1
        print("SELFTEST_WIDE fails=%d" % fails)
        print("RESULT: %s" % ("PASS" if fails == 0 else "FAIL"))
        return 0 if fails == 0 else 1

    if args.synth:
        spec = build_synth(int(args.synth[0]), int(args.synth[1]))
        tag = "synth_%d_%d" % (spec["cin"], spec["cout"])
    else:
        if not (os.path.isfile(args.index) and os.path.isfile(args.blob)):
            print("FATAL: 缺 %s / %s（先跑 tools/y1_convert.py）" % (args.index, args.blob))
            return 3
        spec = build_real(args.index, args.blob, args.lid)
        tag = "lid%d_%s" % (args.lid, spec["name"])
    r = build_one(spec, args.H, args.W, os.path.join(args.outdir, tag))
    print("WIDE_REF %s CIN=%d COUT=%d n_ci=%d n_co=%d M=%d ZPAD=%d ZY=%d NCOL=%d"
          % (spec["name"], r["cin"], r["cout"], r["n_ci"], r["n_co"], r["M"], r["zp"], r["zy"], r["NCOL"]))
    print("WIDE_REF tiled_eq=%d distinct=%d d_pad0=%d d_nobias=%d tile_nonzero=%d dir=%s"
          % (r["tiled_eq"], r["distinct"], r["d_pad0"], r["d_nobias"], r["tile_nonzero"], r["dir"]))
    rc = 0
    if not r["tiled_eq"]:
        print("JUDGE-RED: 拆趟 != 整层（恒等式破）"); rc = 1
    if r["degenerate"]:
        print("JUDGE-RED: 黄金退化（distinct<=1）"); rc = 1
    if r["d_pad0"] == 0:
        print("NEGCTL-FAIL: pad=字节0 的预测 == 黄金 ⇒ 负对照没牙"); rc = 2
    if r["d_nobias"] == 0:
        print("NEGCTL-FAIL: 去 bias_adj 的预测 == 黄金 ⇒ 负对照没牙"); rc = 2
    print("RESULT: %s" % ("PASS" if rc == 0 else "FAIL"))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
