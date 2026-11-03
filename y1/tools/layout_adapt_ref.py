#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""layout_adapt_ref.py —— y1 C4b-B4：**conv 平面 ↔ 旁路 NHWC 的布局适配**（消费者侧 strided read）的供料 + 黄金。

口径（与 `reports/c4b_input_layout.md` §1 冻结的输入布局契约同源）：
  · DDR 上激活张量是**通道平面（NCHW）**：`off(c,p) = c*Npix + p`（`Npix` = 该张量的像素数）；
  · 旁路单元的**自然流形状**是 NHWC：一拍一列 = 一个像素的 C 个通道。
  ⇒ 当生产者是 **conv**（写平面）而消费者是**旁路单元**时，消费侧必须按步长 `Npix` 取数：
      第 `p` 列 = `(x[0][p], x[1][p], ..., x[C-1][p])`      ← 本工具算的就是这条（`folded_read` 同一口径）
  反向（旁路写、conv 读）：旁路把列流**散射**成平面写回，于是下游 conv 读到的仍是平面。

本工具**消费真表**（`gen/wgt_index.json` + `gen/desc.bin`）：
  · `IMG_W/IMG_H`（= 输出几何）**逐字**取自该单元的描述符；
  · `C_IN/C_OUT` **投影**到本代旁路通路的档位 C=8（**一个通道块** —— 见报告"能证/不能证"）；
  · `SRC_ADDR/DST_ADDR` **重定位**到小地址（仿真内存镜像），几何口径不受影响。

产出（落 `--out`）：
  · `mem.hex`  —— 内存镜像初值：源**平面**张量写在 SRC（`AxiMemModel` 的 `+MEMFILE=` 格式）
  · `col.hex`  —— **期望列流**（一拍一列 × C 字节；`p` 行 = 第 `p` 个像素的 C 个通道）
  · `gold.hex` —— **期望 DST**（按平面写：`C` 个平面 × `outPix` 字节）
  · `col_bad.hex`/`gold_bad.hex` —— **负对照预测**：把步长丢掉（连续读）时 DUT 会吐出什么
  · `job.txt`  —— 几何 + 描述符 8 字（供装置 `+S0..+S7` 逐字驱动 = "真表"证据）

自检（`--selftest`）：两条**独立实现**互证（向量化转置 vs 朴素三重循环）+ 三次非退化断言：
  ① 源非常数；② 列流 != 连续读预测（⇒ 负对照可观测、不是橡皮章）；③ 黄金 != 负对照黄金。
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

C_BLOCK = 8            # 本代旁路通路的档位（BypassExec 的 C=8 = DdrMaster 一拍 8 B）
SRC_RELOC = 0x00001000  # 源张量的仿真地址（32 B 对齐；几何口径不受影响）
DST_RELOC = 0x00080000  # 目标张量的仿真地址（32 B 对齐）


# ---------------------------------------------------------------- 真表读取 ----
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
    """把描述符字投影到本代旁路通路的档位并重定位地址（只改 `w2` 的 C_IN/C_OUT 与 `w4/w5` 的地址）。

    `w1` = IMG_W/IMG_H（**逐字不动**）、`w3` = TYPE/FLAGS（**逐字不动**）、`w6` = IN_BYTES（**不动**）、
    `w7` = LAYER_ID 等（**不动**）⇒ 几何/算子身份仍是**真表**的那一条。"""
    w = list(words)
    c_in = (w[2] >> 16) & 0xFFFF
    c_out = w[2] & 0xFFFF
    w[2] = ((c_block & 0xFFFF) << 16) | (c_block & 0xFFFF)
    w[4] = src & 0xFFFFFFFF
    w[5] = dst & 0xFFFFFFFF
    return w, c_in, c_out


# ---------------------------------------------------------------- 几何 ----
def geom_of(op, img_w, img_h):
    """由算子的**输出几何**反推输入几何（与 `BypassExec.scala` 文件头 §"四个算子各不相同的几何"同一口径）。"""
    if op == "maxpool":
        inw, inh = 2 * img_w, 2 * img_h
    elif op == "resize":
        inw, inh = img_w // 2, img_h // 2
    else:                                  # add / sigmoid：逐点
        inw, inh = img_w, img_h
    return inw, inh, inw * inh


# ---------------------------------------------------------------- 向量 ----
def make_src(c, npix):
    """源**平面**张量（`c` 个平面 × `npix` 像素）的确定性 int8 图案（随 c 与 p 都变 ⇒ 非退化）。"""
    return [[((cc * 37 + p * 11 + 5) & 0xFF) for p in range(npix)] for cc in range(c)]


def plain_cols(x):                      # ← 实现 ①：向量化（列 p = 各平面第 p 个字节）
    c, npix = len(x), len(x[0])
    return [tuple(x[cc][p] for cc in range(c)) for p in range(npix)]


def contiguous_cols(x):                 # ← 连续读（"把步长丢掉"）的预测
    c, npix = len(x), len(x[0])
    flat = [x[cc][p] for cc in range(c) for p in range(npix)]
    return [tuple(flat[(p * c + cc) % len(flat)] for cc in range(c)) for p in range(npix)]


def _s8(v):
    """把 0..255 的字节读成 **int8**（激活是**有符号 int8** —— `MaxPoolUnit` 的窗口比较是
    `SInt(8)` 的有符号比较，这正是"取最大"在本硬件上的口径）。"""
    return v - 256 if v >= 128 else v


def maxpool_cols(cols, inw, inh, c):    # ← 实现 ②：朴素三重循环（2x2/s2 逐点）
    oh, ow = inh // 2, inw // 2
    out = [[0] * (oh * ow) for _ in range(c)]
    for cc in range(c):
        for y in range(oh):
            for xx in range(ow):
                vals = []
                for dy in (0, 1):
                    for dx in (0, 1):
                        p = (2 * y + dy) * inw + (2 * xx + dx)
                        vals.append(_s8(cols[p][cc]))
                out[cc][y * ow + xx] = max(vals) & 0xFF
    return out, oh, ow


def maxpool_cols_vec(cols, inw, inh, c):  # ← 实现 ①：向量化（同一个算子的第二条实现，互证）
    oh, ow = inh // 2, inw // 2
    out = [[0] * (oh * ow) for _ in range(c)]
    for cc in range(c):
        for y in range(oh):
            for xx in range(ow):
                vals = [_s8(cols[(2 * y + dy) * inw + (2 * xx + dx)][cc]) for dy in (0, 1) for dx in (0, 1)]
                out[cc][y * ow + xx] = max(vals) & 0xFF
    return out


def flat_plane(planes):
    """按**平面**展平（= 下游 conv 读到的 DDR 字节序）。"""
    return [b for pl in planes for b in pl]


def hex_bytes(vals):
    return "".join("%02x" % (v & 0xFF) for v in vals)


# ---------------------------------------------------------------- 一档 ----
def build_one(units, desc_path, layer, outdir, img_h_ovr=None):
    u = None
    for uu in units["units"]:
        if uu["name"] == layer:
            u = uu
            break
    if u is None:
        raise SystemExit("FATAL: 真表里没有单元 %s" % layer)
    op = {"MaxPool": "maxpool", "Resize": "resize", "Add": "add", "Sigmoid": "sigmoid"}[u["op"]]
    img_w = int(u["table_geom"]["IMG_W"])
    img_h = int(u["table_geom"]["IMG_H"]) if img_h_ovr is None else int(img_h_ovr)
    if op != "maxpool":
        raise SystemExit("FATAL: 本片只覆盖 maxpool（见报告 能证/不能证 一节）")
    inw, inh, npix = geom_of(op, img_w, img_h)
    outpix = img_w * img_h
    c = C_BLOCK
    words_raw = desc_words(desc_path, u["idx"])
    words, c_in_real, c_out_real = patch_words(words_raw)
    if img_h_ovr is not None:                       # 条带：只改 IMG_H（行宽 IMG_W/WIDTH 保持真值）
        words[1] = ((img_h & 0xFFFF) << 16) | (img_w & 0xFFFF)   # ★ w1 = [15:0]IMG_W [31:16]IMG_H
    x = make_src(c, npix)
    cols = plain_cols(x)
    cols_bad = contiguous_cols(x)
    gold, oh, ow = maxpool_cols(cols, inw, inh, c)
    gold_vec = maxpool_cols_vec(cols, inw, inh, c)
    gold_bad, _oh2, _ow2 = maxpool_cols(cols_bad, inw, inh, c)
    outdir = outdir or _Y1
    os.makedirs(outdir, exist_ok=True)

    def wr(name, lines):
        with open(os.path.join(outdir, name), "w") as fh:
            fh.write("\n".join(lines) + "\n")

    # 内存镜像：源张量写在 SRC（平面）
    mem = ["00"] * (DST_RELOC + c * outpix + 1024)
    for k, b in enumerate(flat_plane(x)):
        mem[SRC_RELOC + k] = "%02x" % b
    wr("mem.hex", mem)
    wr("col.hex", [hex_bytes(cols[p]) for p in range(npix)])
    wr("col_bad.hex", [hex_bytes(cols_bad[p]) for p in range(npix)])
    wr("gold.hex", [hex_bytes(flat_plane(gold))])
    wr("gold_bad.hex", [hex_bytes(flat_plane(gold_bad))])
    # 逐字节档（供装置 `$readmemh` 直读）：列流按"一拍一列、列内 C 道"的顺序展平
    wr("colb.hex", ["%02x" % cols[p][cc] for p in range(npix) for cc in range(c)])
    wr("goldb.hex", ["%02x" % v for v in flat_plane(gold)])
    # ★ **回归锚（模式 0 = 今天的线性 NHWC）**：源按 NHWC 摆（像素主序、通道连续）、DST 也按 NHWC 收。
    #   两模式的**列流完全相同**（列 p 都是 8 个平面的第 p 个字节）⇒ COLFILE 可共用；只有
    #   MEMFILE / GOLDFILE 换一套（证明 B4 是**加法**：`src_planar=dst_planar=0` 逐字节同旧行为）。
    mem2 = ["00"] * (DST_RELOC + c * outpix + 1024)
    for p in range(npix):
        for cc in range(c):
            mem2[SRC_RELOC + p * c + cc] = "%02x" % x[cc][p]
    wr("mem_nhwc.hex", mem2)
    wr("gold_nhwc.hex", ["%02x" % gold[cc][p] for p in range(outpix) for cc in range(c)])

    two_impl = (gold == gold_vec)
    col_neq_bad = (cols != cols_bad)
    gold_neq_bad = (flat_plane(gold) != flat_plane(gold_bad))
    src_nonconst = (len(set(flat_plane(x))) > 1)
    rows = {
        "layer": layer, "idx": int(u["idx"]), "op": op,
        "img_w": img_w, "img_h": img_h, "inw": inw, "inh": inh, "npix": npix, "outpix": outpix,
        "c_block": c, "c_in_real": c_in_real, "c_out_real": c_out_real,
        "oh": oh, "ow": ow, "src": SRC_RELOC, "dst": DST_RELOC,
        "rd_bytes": c * npix, "wr_bytes": c * outpix,
        "nburst": c * npix // 32,
        "desc": [int(v) for v in words],
        "two_impl": two_impl, "col_neq_bad": col_neq_bad, "gold_neq_bad": gold_neq_bad,
        "src_nonconst": src_nonconst,
        "gold_distinct": len(set(flat_plane(gold))),
        "col_first_bad_pred": next((p for p in range(npix) if cols[p] != cols_bad[p]), -1),
    }
    with open(os.path.join(outdir, "job.json"), "w") as fh:
        json.dump(rows, fh, indent=1)
    print("LADAPT_REF layer=%-12s op=%-8s IMG=%dx%d IN=%dx%d NPIX=%d OUTPIX=%d C=%d(real %d->%d) "
          "SRC=%#x DST=%#x rd=%d wr=%d distinct=%d"
          % (layer, op, img_w, img_h, inw, inh, npix, outpix, c, c_in_real, c_out_real,
             SRC_RELOC, DST_RELOC, c * npix, c * outpix, rows["gold_distinct"]))
    print("LADAPT_REF_SELFTEST two_impl=%d src_nonconst=%d col_neq_bad=%d gold_neq_bad=%d "
          "col_first_bad_pred=%d distinct=%d"
          % (1 if two_impl else 0, 1 if src_nonconst else 0, 1 if col_neq_bad else 0,
             1 if gold_neq_bad else 0, rows["col_first_bad_pred"], rows["gold_distinct"]))
    print("LADAPT_DESC " + " ".join("%08x" % v for v in words))
    return rows


# ---------------------------------------------------------------- selftest ----
def selftest():
    """两条独立实现 + 三条非退化断言（不碰真表 ⇒ 纯校口径）。"""
    n_ok = 0
    for (img_w, img_h) in ((4, 4), (16, 16), (40, 40), (80, 80)):
        inw, inh, npix = geom_of("maxpool", img_w, img_h)
        for c in (8,):
            x = make_src(c, npix)
            cols = plain_cols(x)
            g1, _oh, _ow = maxpool_cols(cols, inw, inh, c)
            g2 = maxpool_cols_vec(cols, inw, inh, c)
            cb = contiguous_cols(x)
            gb, _a, _b = maxpool_cols(cols=cb, inw=inw, inh=inh, c=c)
            assert g1 == g2, "two impl mismatch %dx%d" % (img_w, img_h)
            assert cols != cb, "col stream == contiguous read (degenerate) %dx%d" % (img_w, img_h)
            assert flat_plane(g1) != flat_plane(gb), "gold == negctl gold %dx%d" % (img_w, img_h)
            assert len(set(flat_plane(x))) > 1
            n_ok += 1
    print("LADAPT_SELFTEST cases=%d fails=0" % n_ok)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--idx", default=os.path.join(_Y1, "gen", "wgt_index.json"))
    ap.add_argument("--desc", default=os.path.join(_Y1, "gen", "desc.bin"))
    ap.add_argument("--layer", default="MaxPool_25")
    ap.add_argument("--img-h", type=int, default=None, help="覆盖 IMG_H（条带：行宽保持真值）")
    ap.add_argument("--out", default=os.path.join(_Y1, "gen", "c4b_ladapt"))
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)
    if args.selftest:
        selftest()
        return 0
    units = load_units(args.idx)
    build_one(units, args.desc, args.layer, args.out, args.img_h)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
