#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""dw_wide_ref.py —— ★ C4b-C2：**真 depthwise 单元**经**集成宽通路**的向量 + 黄金供料。

被测行为（`rtl/UnitExec.scala` 的 `WIDERUN` 子 FSM 的**对角趟调度**）：
  `GROUP == C_in == C_out > 1`（真表 `0x03`）⇒ 每个 co-block `b` 只跑**一趟**（`(b,b)`）、
  该趟即成品（`MultiPassUnit`/`DwUnit` 的冻结对角口径，C4a.6）。输入列流 = **输入喂一次**
  （`nCo` 块 × `H*W` 列 × 8 通道；dense 的 `nCo*nCi` 倍扇出在这里被省掉）。

★ 本文件**不重写任何算术**：黄金逐字复用**冻结的** `tools/wide_exec_ref.py` 的
  `build_one`（其内部 = §4.5-A 硬件口径的 `conv_acc` + `requant`；同一份式子也被
  `run_unitexec_wide_ab.sh` / `run_wide_tail_ab.sh` 当黄金用）。本文件只做**两件数据布局**的事：
  1. **把真 blob 的 depthwise 紧凑段展开成对角稠密矩阵**：真表 depthwise 的段长 = `C_out*9`
     （每组只有一个输入通道），而 `wide_exec_ref` 的 `build_one` 吃稠密 `(C_out,C_in,3,3)`。
     展开 = 把第 `c` 个通道的 9 个抽头放回 `w[c,c,:,:]`，其余（非对角）为 0 —— 与转换器
     `y1_convert.py` 的"depthwise 段 = 对角"以及 `multipass_ref.weight_tiles` 的 group 掩码**同源**。
  2. **把一般列流裁成对角列流**：`build_one` 落的一般流是 `nCo` 份 `nCi` 块；对角趟只需**第一份**
     （`nCi` 块，`nCi==nCo`）。
  ⇒ 两份产物（`x.hex` 对角列流、`gold.hex` 黄金）落在 `--outdir`，由闸门消费；`wRam` 的权重
    由 DUT 自己从 **DDR 真 offset** 装载（闸门用 `+WBASE=BLOB_BASE+offset`、`+WFILE=` 全 0 自证）。

用法（全仓唯一可用 Python 组合）：
    cd /d/code/PDS/VexiiYeshenLinux/y1
    PYTHONIOENCODING=utf-8 PYTHONPATH='./.pydeps;../third_party/yunet/deps' \
      <py> tools/dw_wide_ref.py --lid 11 --H 4 --W 64 --outdir gen/c4b_dwwide/lid11_Conv_16

退出码：0 = OK；1 = 判据红（不是 depthwise / 拆趟 != 整层 / 黄金退化）；3 = 前置缺失。
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

# ★ 唯一的算术来源（冻结；**不**重写）
import wide_exec_ref as W

TILE = 8
DEFAULT_INDEX = os.path.abspath(os.path.join(_HERE, "..", "gen", "wgt_index.json"))
DEFAULT_BLOB = os.path.abspath(os.path.join(_HERE, "..", "gen", "wgt_blob.bin"))


def load_depthwise(index_path, blob_path, lid):
    """真表里第 `lid` 个单元的 depthwise 权重（紧凑 `C_out*9` 段）展开成对角稠密 `(C,C,3,3)`。"""
    idx = json.load(open(index_path, encoding="utf-8"))
    try:
        u = [x for x in idx["units"] if x["idx"] == lid][0]
        cen = [x for x in idx["centering"] if x["layer_id"] == lid][0]
        req = [x for x in idx["requant_mult"] if x["layer_id"] == lid][0]
    except IndexError:
        return None
    o, w = u["own"], u["weight"]
    if w is None:
        return None
    ci, co, gg = int(o["C_IN"]), int(o["C_OUT"]), int(o["GROUP"])
    if not (ci == co == gg and gg > 1):
        return None
    off, nb = int(w["offset"]), int(w["nbytes"])
    if nb != co * 9:
        raise AssertionError("depthwise 段长应为 C_out*9=%d，实得 %d" % (co * 9, nb))
    blob = open(blob_path, "rb").read()
    seg = np.frombuffer(blob[off:off + nb], dtype=np.int8).astype(np.int64).reshape(co, 9)
    diag = np.zeros((co, ci, 3, 3), dtype=np.int64)
    for c in range(co):
        diag[c, c] = seg[c].reshape(3, 3)
    spec = {"cin": ci, "cout": co, "w": diag, "M": int(req["M"]), "z_pad": int(cen["z_pad"]),
            "z_y": int(cen["z_y"]), "bias_adj": np.asarray(cen["bias_adj"], dtype=np.int64),
            "name": u["name"]}
    return {"lid": lid, "name": u["name"], "ci": ci, "co": co, "group": gg,
            "off": off, "nbytes": nb, "aligned": (nb + 31) // 32 * 32,
            "spec": spec}


def build(args):
    d = load_depthwise(args.index, args.blob, args.lid)
    if d is None:
        print("NOT-DEPTHWISE lid=%d（真表里不是 depthwise 单元）" % args.lid)
        return 3
    r = W.build_one(d["spec"], args.H, args.W, args.outdir, seed=args.seed)
    # ---- 布局 2：把一般列流裁成对角列流（第一份 = 每块各一次）----
    xp = os.path.join(args.outdir, "x.hex")
    toks = open(xp, encoding="ascii").read().split()
    blk = args.H * args.W * TILE                 # 一个 ci-block 的列数 × 8 通道（token 数）
    keep = r["n_ci"] * blk
    if len(toks) != r["NCOL"] * TILE:
        print("JUDGE-RED: 一般列流 token 数 %d != NCOL*8=%d" % (len(toks), r["NCOL"] * TILE))
        return 1
    with open(xp, "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(toks[:keep]) + "\n")
    # ---- 判据自检（沿用冻结参考的恒等式 + 退化守卫）----
    ok = True
    if r["cin"] != r["cout"]:
        print("JUDGE-RED: cin(%d) != cout(%d)" % (r["cin"], r["cout"])); ok = False
    if not r["tiled_eq"]:
        print("JUDGE-RED: 拆趟 != 整层（C4a.4 恒等式在本用例上破了）"); ok = False
    if r["distinct"] <= 1:
        print("JUDGE-RED: 黄金退化 distinct=%d" % r["distinct"]); ok = False
    print("DW_WIDE_REF lid=%d %s C=%d G=%d off=%d nbytes=%d ceil32=%d n_ci=%d n_co=%d "
          "NCOL_gen_cols=%d x_tokens_gen=%d x_tokens_diag=%d NCOL_diag_cols=%d passes_diag=%d "
          "M=%d ZPAD=%d ZY=%d distinct=%d tiled_eq=%d dir=%s"
          % (d["lid"], d["name"], d["ci"], d["group"], d["off"], d["nbytes"], d["aligned"],
             r["n_ci"], r["n_co"], r["NCOL"], r["NCOL"] * TILE, keep, keep // TILE, r["n_co"],
             r["M"], r["zp"], r["zy"], r["distinct"], r["tiled_eq"], args.outdir))
    return 0 if ok else 1


def main(argv):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--lid", type=int, required=True)
    ap.add_argument("--H", type=int, default=4)
    ap.add_argument("--W", type=int, default=64)
    ap.add_argument("--seed", type=int, default=1234)
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--index", default=DEFAULT_INDEX)
    ap.add_argument("--blob", default=DEFAULT_BLOB)
    args = ap.parse_args(argv[1:])
    if not (os.path.isfile(args.index) and os.path.isfile(args.blob)):
        print("FATAL: 缺 %s / %s（先跑 tools/y1_convert.py）" % (args.index, args.blob))
        return 3
    return build(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
