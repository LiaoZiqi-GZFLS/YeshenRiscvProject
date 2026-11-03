#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""stride_ref.py —— y1 C4b-D1：**卷积步长（`stride >= 2`）** 的向量 + 黄金供料。

被测行为（`rtl/Conv3x3Slice.scala` 的 `stride` 口 + `rtl/MultiPassUnit.scala` 的直通）：
  `Conv(stride=s, pads=1, K=3)` 的输出 `(y,x)` 的窗口中心 = 输入 `(s·y, s·x)`；本模块**照旧逐列收满**
  输入（3 个 tap 恒为相邻三列），只是**像素相位**按 `s` 抽稀 ⇒ 输出 `Ho×Wo`
  （`Ho = floor((H_in-1)/s)+1`、`Wo = floor((W_in-1)/s)+1`）。

★ 本文件**不重写**任何量化/卷积算术：
  · 乘子 `M` / `z_pad` / `z_y` / `bias_adj` 从**真转换器产物**（`gen/wgt_index.json` + `gen/wgt_blob.bin`）
    读（`wide_exec_ref.build_real`，与 `run_unitexec_wide_ab.sh` **同一份**§4.4/§4.5 口径）；
  · `requant` **逐字复用** `wide_exec_ref.requant`（`((acc·M)>>24)>>6 + z_y` 后钳位）；
  · **步长只是"取样位置"**：算术本体（`Σ x_q·w_q`、pad 码点、跨 ci 趟 int32 累加、单次 requant）
    与 stride=1 **一字不差**（`--selftest` 里对 `s=1` 逐字节钉死 `wide_exec_ref.conv_acc`）。

两套独立实现（互为第二实现，`--selftest` 里逐字节互证）：
  1. `hw_acc_vec`   ：向量化（3×3 个 tap 各一次抽稀切片后广播加）；
  2. `hw_acc_naive` ：**逐输出像素**的显式 3×3 窗口（慢但直白；用来抓"抽稀相位/边界写错"这类错）。

用法（全仓唯一可用 Python 组合）：
    cd /d/code/PDS/VexiiYeshenLinux/y1
    PYTHONIOENCODING=utf-8 PYTHONPATH='./.pydeps;../third_party/yunet/deps' \\
      <py> tools/stride_ref.py --selftest
    ... tools/stride_ref.py --emit --lid 0 --stride 2 --h 8 --w 640 --outdir gen/c4a_stride/lid0_s2

退出码：0 = OK；1 = 判据红（两套实现不一致 / 黄金退化）；2 = 负对照没牙（`s=1` 与 `s=2` 输出相同）；
        3 = 前置缺失（缺 index/blob）。
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

import wide_exec_ref as W          # build_real / build_synth / requant（**不重写**量化/卷积口径）
import tiling_ref as T             # n_passes / TILE（拆趟规则）

TILE = T.TILE
REQUANT_Q = 24
SHIFT = 6

DEFAULT_INDEX = os.path.join(_HERE, "..", "gen", "wgt_index.json")
DEFAULT_BLOB = os.path.join(_HERE, "..", "gen", "wgt_blob.bin")


def dump_hex(path, toks, w=2):
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("".join(("%0" + str(w) + "x\n") % (int(t) & ((1 << (4 * w)) - 1)) for t in toks))


# ============================ 实现 1：向量化（抽稀切片） ============================
def hw_acc_vec(x8, wseg, padval, bias, s):
    """`Σ x·w`（空间 pad=1、**填充码点 = `padval`**、按步长 `s` 抽稀取样）+ bias。

    `x8` = (1, CI8, H_in, W_in)；`wseg` = (CO, CI8, 3, 3)（冻结布局）。返回 int64 (CO, Ho, Wo)。
    """
    CO, CG, KH, KW = wseg.shape
    Hin, Win = x8.shape[2], x8.shape[3]
    Ho, Wo = (Hin - 1) // s + 1, (Win - 1) // s + 1
    xp = np.pad(x8.astype(np.int64), ((0, 0), (0, 0), (1, 1), (1, 1)), constant_values=int(padval))
    acc = np.zeros((CO, Ho, Wo), dtype=np.int64)
    for ky in range(KH):
        for kx in range(KW):
            # 抽稀取样：从 pad 坐标 (ky, kx) 起，行/列各取 Ho/Wo 个、跨步 s
            xs = xp[0, :, ky:ky + s * Ho:s, kx:kx + s * Wo:s]
            for ci in range(CG):
                acc += wseg[:, ci, ky, kx][:, None, None] * xs[ci][None, :, :]
    return acc + np.asarray(bias, dtype=np.int64)[:, None, None]


# ============================ 实现 2：逐输出像素的显式窗口（第二实现） ============================
def hw_acc_naive(x8, wseg, padval, bias, s):
    """**直白版**：对每个输出像素把 3×3 窗口的输入按 `padval` 补边后逐 tap 相加。

    没有任何向量化/切片技巧 ⇒ 与 `hw_acc_vec` 是**两条独立的实现**（互为第二实现）。
    """
    CO, CG, KH, KW = wseg.shape
    Hin, Win = x8.shape[2], x8.shape[3]
    Ho, Wo = (Hin - 1) // s + 1, (Win - 1) // s + 1
    acc = np.zeros((CO, Ho, Wo), dtype=np.int64)
    for oy in range(Ho):
        for ox in range(Wo):
            for ky in range(KH):
                for kx in range(KW):
                    iy = oy * s + ky - 1        # 窗口中心 = (s·oy, s·ox)，pad=1
                    ix = ox * s + kx - 1
                    if iy < 0 or iy >= Hin or ix < 0 or ix >= Win:
                        col = np.full(CG, int(padval), dtype=np.int64)   # 越界 ⇒ 用**填充码点**
                    else:
                        col = x8[0, :, iy, ix].astype(np.int64)
                    acc[:, oy, ox] += (wseg[:, :, ky, kx] * col[None, :]).sum(axis=1)
    return acc + np.asarray(bias, dtype=np.int64)[:, None, None]


# ============================ 趟瓦片 / 供料 ============================
def weight_tiles(wq, n_ci, n_co):
    """按 C4a.4 冻结规则展开趟瓦片：`[pass][8co][8ci][3][3]`，SKIP 通道填 `z_w = 0`。

    与 `wide_exec_ref` / `multipass_ref.weight_tiles` 同一口径（本用例 `GROUP=1`、`z_w=0`）。
    """
    co, ci = wq.shape[0], wq.shape[1]
    tiles = []
    for j in range(n_co):
        co0, co_t = j * TILE, min(TILE, co - j * TILE)
        for i in range(n_ci):
            ci0, ci_t = i * TILE, min(TILE, ci - i * TILE)
            t = np.zeros((TILE, TILE, 3, 3), dtype=np.int64)
            for r in range(co_t):
                for s in range(ci_t):
                    t[r, s] = wq[co0 + r, ci0 + s]
            tiles.append(t)
    return tiles


def bias_per_cob(bias_adj, n_co):
    """`[co-block][co_local]`（int32）—— 与 MultiPassTb 的 `+BFILE` 布局同序。"""
    out = []
    for j in range(n_co):
        for r in range(TILE):
            k = j * TILE + r
            out.append(int(bias_adj[k]) if bias_adj is not None and k < len(bias_adj) else 0)
    return out


def build_one(spec, Hin, Win, s, outdir, seed=99, xr=20):
    """一个用例：算黄金 + 落盘（x/w/b/gold/job）。返回 (job dict, 判据数字 dict)。"""
    cin, cout = int(spec["cin"]), int(spec["cout"])
    M, zp, zy = int(spec["M"]), int(spec["z_pad"]), int(spec["z_y"])
    bj = spec["bias_adj"]
    n_ci, n_co = T.n_passes(cin), T.n_passes(cout)
    CI8, CO8 = n_ci * TILE, n_co * TILE
    Ho, Wo = (Hin - 1) // s + 1, (Win - 1) // s + 1

    # ---- 输入：合成"中灰图"（码点 ∈ [-xr, xr]，缺省 ±20 —— 与既有真层闸门同一量程）----
    #   ★ 真网 `Conv_0` 的输入码点 = `round(255·x_real) - 128`（`s_x = 1/255, z_x = -128`）
    #     ⇒ ±20 相当于 `x_real ∈ [0.42,0.58]`（中灰）；边界仍用真网的 `z_pad = -128`。
    xq = np.random.default_rng(seed).integers(-xr, xr + 1, size=(1, cin, Hin, Win), dtype=np.int64)
    x8 = np.zeros((1, CI8, Hin, Win), dtype=np.int64)
    x8[0, :cin] = xq[0]

    # ---- 整层 acc（两条独立实现互证）----
    wfull = np.zeros((CO8, CI8, 3, 3), dtype=np.int64)
    wfull[:cout, :cin] = spec["w"]
    bias_full = np.zeros(CO8, dtype=np.int64)
    if bj is not None:
        bias_full[:cout] = bj
    acc_vec = hw_acc_vec(x8, wfull, zp, bias_full, s)
    acc_nai = hw_acc_naive(x8, wfull, zp, bias_full, s)
    d_twoimpl = int(np.count_nonzero(acc_vec != acc_nai))

    # ---- 拆趟（逐 co-block 的 int32 部分和累加；与硬件逐趟序一致）----
    tiles = weight_tiles(spec["w"], n_ci, n_co)
    acc_tiled = np.zeros((CO8, Ho, Wo), dtype=np.int64)
    for j in range(n_co):
        accj = np.zeros((TILE, Ho, Wo), dtype=np.int64)
        for i in range(n_ci):
            t = np.zeros((CO8, CI8, 3, 3), dtype=np.int64)
            t[j * TILE:(j + 1) * TILE, i * TILE:(i + 1) * TILE] = tiles[j * n_ci + i]
            b = np.zeros(CO8, dtype=np.int64)
            if i == 0:
                b[j * TILE:(j + 1) * TILE] = [bias_per_cob(bj, n_co)[j * TILE + r] for r in range(TILE)]
            accj += hw_acc_vec(x8, t, zp, b, s)[j * TILE:(j + 1) * TILE]
        acc_tiled[j * TILE:(j + 1) * TILE] = accj
    d_tiled = int(np.count_nonzero(acc_tiled != acc_vec))
    # int32 无溢出佐证（硬件累加器是 int32）
    int32_ok = bool(np.max(np.abs(acc_vec)) < (1 << 31)) if acc_vec.size else True

    gold = W.requant(acc_vec[:cout], M, zy).reshape(-1).astype(np.int8)
    distinct = int(len(set(int(v) for v in gold)))

    # ---- 落盘 ----
    os.makedirs(outdir, exist_ok=True)
    dump_hex(os.path.join(outdir, "x.hex"), xq.reshape(-1))
    # ---- ★★ C4b-D1b：`xcol.hex` —— **UnitExec 级**的 `wide_x` 列流 -------------------------------
    #   一拍一列 = 一个像素的 8 个通道；趟序 = **co-block 外、ci-block 内**（与 `w.hex` 的趟序同序）。
    #   形状与 `wide_exec_ref` 的 `x.hex` **逐字同式**（同一份输入张量走"平面 → 行主序列流"的**纯搬字节**：
    #   同一列流既供 `MultiPassUnit` 的 `MultiPassTb`（`x.hex` = 通道平面，直接索引）、
    #   也供集成 `UnitExec` 的 `UnitExecWideTb`（`xcol.hex` = 列流，一拍一列）——**没有第三条口径**）。
    #   ★ `UnitExec`（`WIDERUN`）逐趟喂 `inRows = IMG_H·s` 个**真行**（各 `WIDTH` 列）；
    #     第 `inRows` 行 = 下边 pad 行由 DUT 自己合成 `z_pad` ⇒ **列流里没有 pad 行**。
    xstream = np.concatenate([x8[0, ci * TILE:(ci + 1) * TILE].transpose(1, 2, 0).reshape(-1)
                              for _ in range(n_co) for ci in range(n_ci)])
    dump_hex(os.path.join(outdir, "xcol.hex"), xstream)
    dump_hex(os.path.join(outdir, "w.hex"), np.concatenate([t.reshape(-1) for t in tiles]))
    dump_hex(os.path.join(outdir, "b.hex"), bias_per_cob(bj, n_co), w=8)
    dump_hex(os.path.join(outdir, "gold.hex"), gold)
    job = {"CIN": cin, "COUT": cout, "GROUP": 1, "HIN": Hin, "WIN": Win, "STRIDE": s,
           "HO": Ho, "WO": Wo, "NPIX": Ho * Wo, "M": M, "ZY": zy, "ZPAD": zp, "PADV": zp,
           "NCI": n_ci, "NCO": n_co, "NPASS": n_ci * n_co,
           # ★★ C4b-D1b：集成 `UnitExec` 的列流总数 = 趟数 × 输入真行数 × 输入行宽
           #   （= `UnitExecWideTb` 的 `+NCOL`；`s=1` ⇒ `n_co*n_ci*Hin*Win`，与 C4a.5b **逐字同值**）。
           "NCOL": n_ci * n_co * Hin * Win, "NAME": spec.get("name", "synth")}
    with open(os.path.join(outdir, "job.txt"), "w", encoding="ascii", newline="\n") as f:
        f.write("".join("%s=%s\n" % (k, v) for k, v in sorted(job.items())))
    nums = {"d_twoimpl": d_twoimpl, "d_tiled": d_tiled, "distinct": distinct,
            "int32_ok": int32_ok, "gold_md5": hashlib.md5(
                np.ascontiguousarray(gold).tobytes()).hexdigest()}
    return job, nums


# ============================ --selftest ============================
def selftest():
    print("[stride_ref] selftest：两条独立实现互证 + s=1 与冻结 caliber 逐字节 + s=2 非退化")
    fails = []
    neg_nofire = []
    import tempfile

    def chk(cond, msg):
        print("  %s  %s" % ("PASS" if cond else "FAIL", msg))
        if not cond:
            fails.append(msg)

    cases = [(3, 16, 2), (16, 16, 2), (64, 64, 2), (3, 16, 3), (10, 4, 2),
             (3, 16, 1), (16, 16, 1)]   # 末两条是 `s=1`：钉死与冻结 caliber 逐字节相同
    with tempfile.TemporaryDirectory() as td:
        for k, (ci, co, s) in enumerate(cases):
            spec = W.build_synth(ci, co, seed=8300 + k)
            j, n = build_one(spec, 9, 7, s, os.path.join(td, "c%d" % k), seed=3100 + k)
            chk(n["d_twoimpl"] == 0, "ci=%d co=%d s=%d：向量化 == 逐像素朴素（差 %d）"
                % (ci, co, s, n["d_twoimpl"]))
            chk(n["d_tiled"] == 0, "ci=%d co=%d s=%d：拆趟累加 == 整层 acc（差 %d）"
                % (ci, co, s, n["d_tiled"]))
            chk(n["distinct"] > 1, "ci=%d co=%d s=%d：黄金非退化（distinct=%d）" % (ci, co, s, n["distinct"]))
            chk(n["int32_ok"] == 1, "ci=%d co=%d s=%d：int32 无溢出" % (ci, co, s))
            # 负对照：s>1 与 s=1 的输出必须不同（否则"步长在数据通路上"这件事没被验证）
            if s != 1:
                build_one(spec, 9, 7, 1, os.path.join(td, "c%d_s1" % k), seed=3100 + k)
                g1 = open(os.path.join(td, "c%d_s1" % k, "gold.hex"), encoding="ascii").read().split()
                gs = open(os.path.join(td, "c%d" % k, "gold.hex"), encoding="ascii").read().split()
                same = bool(g1 == gs)
                if same:
                    neg_nofire.append("ci=%d co=%d s=%d：s>1 与 s=1 输出相同" % (ci, co, s))
                chk(not same, "负对照 ci=%d co=%d s=%d：s>1 的输出 != s=1 的输出" % (ci, co, s))
            else:
                print("  N/A   负对照（s>1 != s=1）：本用例 s=1 ⇒ 结构性不适用")
                chk(True, "负对照 ci=%d co=%d s=1：N/A（结构性不适用）" % (ci, co))
            # ★ 承重锚：`s = 1` 时本工具与**冻结的 C4a.5b caliber**（wide_exec_ref.conv_acc）逐字节相同
            if s == 1:
                xq = np.random.default_rng(3100 + k).integers(-128, 128, size=(1, ci, 9, 7), dtype=np.int64)
                x8 = np.zeros((1, T.n_passes(ci) * TILE, 9, 7), dtype=np.int64)
                x8[0, :ci] = xq[0]
                wf = np.zeros((T.n_passes(co) * TILE, T.n_passes(ci) * TILE, 3, 3), dtype=np.int64)
                wf[:co, :ci] = spec["w"]
                bf = np.zeros(T.n_passes(co) * TILE, dtype=np.int64)
                if spec["bias_adj"] is not None:
                    bf[:co] = spec["bias_adj"]
                a1 = hw_acc_vec(x8, wf, spec["z_pad"], bf, 1)
                a2 = W.conv_acc(x8, wf, spec["z_pad"], bf)
                chk(bool(np.array_equal(a1, a2)),
                    "s=1：本工具 acc == 冻结 C4a.5b caliber（wide_exec_ref.conv_acc）逐字节")
    print("SELFTEST_STRIDE cases=%d fails=%d" % (len(cases), len(fails)))
    if fails:
        print("RESULT: FAIL")
        return 1
    if neg_nofire:
        print("STRIDE_REF: FAIL 负对照没牙：%s" % neg_nofire)
        print("RESULT: FAIL")
        return 2
    print("RESULT: PASS")
    return 0


# ============================ --emit ============================
def do_emit(args):
    if args.lid is not None:
        if not (os.path.isfile(args.index) and os.path.isfile(args.blob)):
            print("FATAL: 缺 %s / %s" % (args.index, args.blob))
            return 3
        spec = W.build_real(args.index, args.blob, args.lid)
    else:
        spec = W.build_synth(args.synth[0], args.synth[1])
    job, nums = build_one(spec, args.h, args.w, args.stride, args.outdir, seed=args.seed, xr=args.xr)
    print("STRIDE_REF name=%s CIN=%d COUT=%d HIN=%d WIN=%d S=%d HO=%d WO=%d NPIX=%d M=%d ZY=%d ZPAD=%d "
          "NCI=%d NCO=%d NPASS=%d"
          % (spec.get("name"), job["CIN"], job["COUT"], job["HIN"], job["WIN"], job["STRIDE"],
             job["HO"], job["WO"], job["NPIX"], job["M"], job["ZY"], job["ZPAD"],
             job["NCI"], job["NCO"], job["NPASS"]))
    print("STRIDE_REF twoimpl_diff=%d tiled_diff=%d distinct=%d int32_ok=%d gold_md5=%s"
          % (nums["d_twoimpl"], nums["d_tiled"], nums["distinct"], nums["int32_ok"], nums["gold_md5"]))
    if nums["d_twoimpl"] != 0 or nums["d_tiled"] != 0 or nums["distinct"] <= 1 or nums["int32_ok"] == 0:
        print("STRIDE_REF: FAIL（两套实现不一致 / 拆趟 != 整层 / 黄金退化 / int32 溢出）")
        print("RESULT: FAIL")
        return 1
    print("RESULT: PASS")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--emit", action="store_true")
    ap.add_argument("--lid", type=int, default=None, help="真网层号（默认用 --synth）")
    ap.add_argument("--synth", nargs=2, type=int, default=[16, 16])
    ap.add_argument("--h", type=int, default=8, help="输入**真行数** H_in（TB 会多喂 1 行 pad）")
    ap.add_argument("--w", type=int, default=640, help="输入行宽 W_in（= 网表 WIDTH）")
    ap.add_argument("--stride", type=int, default=2)
    ap.add_argument("--seed", type=int, default=99)
    ap.add_argument("--xr", type=int, default=20, help="合成激活码点范围 ±xr（缺省 20 = 中灰图）")
    ap.add_argument("--index", default=DEFAULT_INDEX)
    ap.add_argument("--blob", default=DEFAULT_BLOB)
    ap.add_argument("--outdir", default=os.path.join(_HERE, "..", "gen", "c4a_stride"))
    args = ap.parse_args(argv[1:])
    if args.selftest:
        return selftest()
    if args.emit:
        return do_emit(args)
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
