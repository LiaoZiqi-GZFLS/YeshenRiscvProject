#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""add_src2_ref.py —— y1 C4b-E1：`Add` **第二路源（表内偏移 k）** 的供料 + 黄金（BypassExec 聚焦判据）。

背景（spec §4.6）：冻结的 8 字描述符只有一个 `SRC_ADDR`，而 `Add` 是唯一双输入单元。E1 把
第二路源表达成 **`w3[31:16] = SRC2_K`**（= 表序下行 k 位那条描述符的 `DST_ADDR`）。本工具**消费真表**：

  · `IMG_W/IMG_H`（= 输出几何）**逐字**取自该 `Add` 的描述符；
  · `C_IN/C_OUT` **投影**到本代旁路通路的档位 C=8（**一个通道块**，与 `tools/layout_adapt_ref.py` 同口径）；
  · `SRC_ADDR/DST_ADDR` 重定位到小地址；**第二路源地址 `SRC2` = 表序 `idx-k` 那条描述符的 `DST_ADDR`**
    （`k = (w3>>16)&0xFFFF` **从 `gen/desc.bin` 逐字读**，不是本工具编的）。

产出（落 `--out`）：
  · `mem.hex`   —— 内存镜像初值：A（第一路）写在 SRC、B（第二路）写在 SRC2、**C（"错 k"缓冲）**写在 SRC2W
  · `goldb.hex` —— **期望 DST**（= `clamp8(A+B)`，逐字节；NHWC 列序 = `[pixel][c]`）
  · `colb.hex`  —— **期望列流**（DUT 的 `col_dbg` 在 B 趟吐的列 = B 的逐字节列流）
  · `wrongb.hex`—— **负对照预测**：把 `SRC2` 指到 SRC2W（等价于"k 差一"读到邻居缓冲）时 DUT 会吐出什么
  · `job.json`  —— 几何 + 描述符 8 字（含真表 `w3` 的 `SRC2_K`）+ 地址 + 三条非退化断言

自检（`--selftest`）：两条**独立实现**互证（向量化 vs 朴素三重循环）+ 三条非退化断言：
  ① A/B/C 非常数且两两不同；② `clamp(A+B) != clamp(A+C)`（⇒ "错 k"可观测、不是橡皮章）；
  ③ 向量上真出现饱和（SAT_EVENTS>0）。
"""

import argparse
import json
import os
import struct
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

_HERE = os.path.dirname(os.path.abspath(__file__))
_Y1 = os.path.abspath(os.path.join(_HERE, ".."))

C_BLOCK = 8                 # 本代旁路通路的档位（BypassExec C=8 = DdrMaster 一拍 8 B）
SRC_RELOC  = 0x00001000      # A（第一路）
SRC2_RELOC = 0x00010000      # B（第二路 = 生产者 DST）
SRC2W_RELOC = 0x00020000     # C（"错 k"缓冲：邻居项的 DST 位置）
DST_RELOC  = 0x00030000      # 输出
MEMSZ = 0x00080000           # 建模内存（AxiMemModel 的 MEMSZ）


def _i8(v):
    v &= 0xFF
    return v - 256 if v >= 128 else v


def clamp8(v):
    return 127 if v > 127 else (-128 if v < -128 else v)


def load_units(idx_path):
    with open(idx_path, encoding="utf-8") as fh:
        return json.load(fh)


def desc_words(desc_path, idx):
    with open(desc_path, "rb") as fh:
        fh.seek(idx * 32)
        raw = fh.read(32)
    if len(raw) != 32:
        raise SystemExit("FATAL: desc.bin 太短（idx=%d）" % idx)
    return list(struct.unpack("<8I", raw))


def patch_words(words, c_block=C_BLOCK, src=SRC_RELOC, dst=DST_RELOC):
    """把描述符投影到旁路档位并重定位地址（只动 `w2` 的 C_IN/C_OUT 与 `w4/w5`）。
    ★ `w3` **逐字不动** ⇒ `SRC2_K`（`w3[31:16]`）仍是真表那一位。"""
    w = list(words)
    w[2] = ((c_block & 0xFFFF) << 16) | (c_block & 0xFFFF)
    w[4] = src & 0xFFFFFFFF
    w[5] = dst & 0xFFFFFFFF
    return w


def make_a(npix):
    return [((p * 37 + 11 + 5) & 0xFF) for p in range(npix)]


def make_b(npix):
    return [((p * 97 + 23) & 0xFF) for p in range(npix)]


def make_c(npix):
    return [((p * 53 + 71) & 0xFF) for p in range(npix)]


def add_cols_naive(a, b, c):
    """← 实现 ②：朴素三重循环（逐像素逐通道饱和加；返回 0..255 的字节）。"""
    return [[clamp8(_i8(a[p * c + cc]) + _i8(b[p * c + cc])) & 0xFF for cc in range(c)]
            for p in range(len(a) // c)]


def add_flat_vec(a, b):
    """← 实现 ①：向量化（逐字节饱和加，[pixel][c] 展平）。"""
    return [clamp8(_i8(x) + _i8(y)) & 0xFF for x, y in zip(a, b)]


def build_one(units, desc_path, layer, outdir):
    u = None
    for uu in units["units"]:
        if uu["name"] == layer:
            u = uu
            break
    if u is None:
        raise SystemExit("FATAL: 真表里没有单元 %s" % layer)
    if u["op"] != "Add":
        raise SystemExit("FATAL: %s 不是 Add（op=%s）" % (layer, u["op"]))
    idx = int(u["idx"])
    img_w = int(u["table_geom"]["IMG_W"])
    img_h = int(u["table_geom"]["IMG_H"])
    words_raw = desc_words(desc_path, idx)
    k = (words_raw[3] >> 16) & 0xFFFF
    if k < 1:
        raise SystemExit("FATAL: %s 的 SRC2_K=%d（真表应 >=1；先跑 y1_convert.py --gate）" % (layer, k))
    prod_idx = idx - k
    if prod_idx < 0:
        raise SystemExit("FATAL: %s 的 k=%d > 表序 %d" % (layer, k, idx))
    prod_dst = desc_words(desc_path, prod_idx)[5]        # 第二路源 = 生产者的真 DST_ADDR
    npix = img_w * img_h
    outpix = npix                                        # Add 逐点：in == out
    c = C_BLOCK
    words = patch_words(words_raw)
    a = make_a(npix * c)
    b = make_b(npix * c)
    cc_ = make_c(npix * c)
    gold = add_flat_vec(a, b)
    gold_vec = [v for row in add_cols_naive(a, b, c) for v in row]   # ← 独立实现 ②
    wrong = add_flat_vec(a, cc_)
    outdir = outdir or _Y1
    os.makedirs(outdir, exist_ok=True)

    def wr(name, lines):
        with open(os.path.join(outdir, name), "w") as fh:
            fh.write("\n".join(lines) + "\n")

    mem = ["00"] * (DST_RELOC + c * outpix + 1024)
    for p, v in enumerate(a):
        mem[SRC_RELOC + p] = "%02x" % v
    for p, v in enumerate(b):
        mem[SRC2_RELOC + p] = "%02x" % v
    for p, v in enumerate(cc_):
        mem[SRC2W_RELOC + p] = "%02x" % v
    wr("mem.hex", mem)
    wr("colb.hex", ["%02x" % v for v in b])              # B 列流（DUT col_dbg 在 B 趟吐的列）
    wr("goldb.hex", ["%02x" % v for v in gold])
    wr("wrongcol.hex", ["%02x" % v for v in cc_])        # "错 k"缓冲 C 的列流（DUT 会读到的）
    wr("wrongb.hex", ["%02x" % v for v in wrong])

    sat = sum(1 for x, y in zip(a, b) if not (-128 <= _i8(x) + _i8(y) <= 127))
    a_ne_b = (a != b)
    gold_ne_wrong = (gold != wrong)
    nonconst = (len(set(a)) > 1 and len(set(b)) > 1 and len(set(cc_)) > 1)
    two_impl = (gold == gold_vec)
    rows = {
        "layer": layer, "idx": idx, "op": u["op"], "k": int(k), "producer_idx": prod_idx,
        "producer_dst": int(prod_dst),
        "img_w": img_w, "img_h": img_h, "npix": npix, "outpix": outpix, "c_block": c,
        "c_in_real": int(u["own"]["C_IN"]), "c_out_real": int(u["own"]["C_OUT"]),
        "src": SRC_RELOC, "src2": SRC2_RELOC, "src2w": SRC2W_RELOC, "dst": DST_RELOC,
        "rd_bytes": 2 * c * npix, "wr_bytes": c * outpix,
        "desc": [int(v) for v in words],
        "sat_events": sat, "a_ne_b": a_ne_b, "gold_ne_wrong": gold_ne_wrong,
        "nonconst": nonconst, "two_impl": two_impl,
        "gold_distinct": len(set(gold)),
        "first_bad_pred": next((i for i, (x, y) in enumerate(zip(gold, wrong)) if x != y), -1),
    }
    with open(os.path.join(outdir, "job.json"), "w") as fh:
        json.dump(rows, fh, indent=1)
    print("ADDSRC2_REF layer=%-8s idx=%d k=%d prod_idx=%d IMG=%dx%d NPIX=%d C=%d(real %d->%d) "
          "SRC=%#x SRC2=%#x DST=%#x rd=%d wr=%d distinct=%d"
          % (layer, idx, k, prod_idx, img_w, img_h, npix, c, rows["c_in_real"], rows["c_out_real"],
             SRC_RELOC, SRC2_RELOC, DST_RELOC, rows["rd_bytes"], rows["wr_bytes"], rows["gold_distinct"]))
    print("ADDSRC2_REF_SELFTEST two_impl=%d nonconst=%d a_ne_b=%d gold_ne_wrong=%d sat=%d first_bad_pred=%d"
          % (1 if two_impl else 0, 1 if nonconst else 0, 1 if a_ne_b else 0,
             1 if gold_ne_wrong else 0, sat, rows["first_bad_pred"]))
    print("ADDSRC2_DESC " + " ".join("%08x" % v for v in words))
    return rows


def selftest():
    n = 0
    for (w_, h_) in ((4, 4), (16, 16), (40, 40), (80, 80)):
        npix = w_ * h_
        for c in (8,):
            a, b, cc_ = make_a(npix * c), make_b(npix * c), make_c(npix * c)
            g1 = add_flat_vec(a, b)
            g2 = [v for row in add_cols_naive(a, b, c) for v in row]
            gw = add_flat_vec(a, cc_)
            assert g1 == g2, "two impl mismatch %dx%d" % (w_, h_)
            assert a != b, "A == B (degenerate) %dx%d" % (w_, h_)
            assert g1 != gw, "gold == wrong-k pred (degenerate) %dx%d" % (w_, h_)
            assert len(set(a)) > 1 and len(set(b)) > 1 and len(set(cc_)) > 1
            n += 1
    print("ADDSRC2_SELFTEST cases=%d fails=0" % n)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--idx", default=os.path.join(_Y1, "gen", "wgt_index.json"))
    ap.add_argument("--desc", default=os.path.join(_Y1, "gen", "desc.bin"))
    ap.add_argument("--layer", default="Add_44")
    ap.add_argument("--out", default=os.path.join(_Y1, "gen", "c4b_addsrc2"))
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)
    if args.selftest:
        selftest()
        return 0
    units = load_units(args.idx)
    build_one(units, args.desc, args.layer, args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
