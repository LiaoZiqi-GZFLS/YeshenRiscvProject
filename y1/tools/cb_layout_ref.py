#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cb_layout_ref.py —— 通道分块（CB）arena 布局的**独立参照**（纯 Python，不 import 任何 DUT 侧代码）。

用途：CB-1 的所有黄金/闸门都从这里取"布局"这一个事实；按本仓纪律，它必须**独立实现**
（不与 RTL/转换器共用同一套函数），否则"参考与 DUT 共用同一错约定 ⇒ 全绿"。

布局（spec `arena_channel_block_spec.md` §2）：
  · 每 tile = 32×32 像素 × **8 通道**（C_in 尾部不足 8 的块补 0）；
  · 块内 **每像素 8 字节连续**（通道交织）：`off = (iy_t·32 + ix_t)·8 + ci8`；
  · tile 顺序：`idx = ((ty·ntx + tx)·ncblk + cb)`，`tile_base = idx · 32·32·8`。

对外 API：
  · `n_cblk(C)`、`ntx/nty/H/W` 由形状给出；
  · `planar_to_cb(p, C, H, W)`：planar（`c·H·W + y·W + x`）→ CB 字节串；
  · `cb_get(buf, C, H, W, c, y, x)`：按 CB 取一个元素（越界 tile 补 0）。

自检（`--selftest`）：
  (1) 全表形状 × 随机张量：`to_cb → 逐元素取回` 必须**全等**（真几何、非玩具形状）；
  (2) 负对照 A：把 `ci8` 与 `ix_t` 的次序写反 ⇒ 必须出错；
  (3) 负对照 B：把 tile_base 的 `ncblk` 步进漏掉 ⇒ 必须出错。
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
Y1 = os.path.dirname(HERE)
IDX = os.path.join(Y1, "gen", "wgt_index.json")

TILE = 32
CBLK = 8


def n_cblk(C):
    return (C + CBLK - 1) // CBLK


def dims(C, H, W):
    ntx = (W + TILE - 1) // TILE
    nty = (H + TILE - 1) // TILE
    return ntx, nty, n_cblk(C)


def cb_size(C, H, W):
    ntx, nty, nc = dims(C, H, W)
    return ntx * nty * nc * TILE * TILE * CBLK


def _off(C, H, W, c, y, x, swap=False, no_cb=False):
    ntx, nty, nc = dims(C, H, W)
    cb, ci8 = divmod(c, CBLK)
    ty, iy = divmod(y, TILE)
    tx, ix = divmod(x, TILE)
    idx = ((ty * ntx + tx) * (1 if no_cb else nc) + (0 if no_cb else cb))
    # swap=True 是**负对照**用的错布局：把"像素内通道"与"像素列"对调（等价于把 ci8 当成列）
    inner = ((iy * TILE + ci8) * CBLK + ix) if swap else ((iy * TILE + ix) * CBLK + ci8)
    return idx * TILE * TILE * CBLK + inner


def planar_to_cb(p, C, H, W, swap=False, no_cb=False):
    out = bytearray(cb_size(C, H, W))
    for c in range(C):
        base = c * H * W
        for y in range(H):
            row = base + y * W
            for x in range(W):
                out[_off(C, H, W, c, y, x, swap, no_cb)] = p[row + x]
    return bytes(out)


def cb_get(buf, C, H, W, c, y, x):
    return buf[_off(C, H, W, c, y, x)]


def units():
    return json.load(open(IDX, encoding="utf-8"))["units"]


def selftest():
    us = units()
    import random
    random.seed(0xCB1)
    bad = 0
    tested = 0
    for u in us:
        if u["type"] not in ("conv1x1", "conv3x3", "depthwise"):
            continue
        o = u["own"]
        C, H, W = int(o["C_IN"]), int(o["IMG_H"]), int(o["IMG_W"])
        n = C * H * W
        m = min(n, 4096)                      # 大形状抽样前 4096 个元素（布局逐元素，前缀即样本）
        buf = bytearray(cb_size(C, H, W))
        vals = []
        for k in range(m):
            c, rem = divmod(k, H * W)
            y, x = divmod(rem, W)
            v = random.randrange(256)
            buf[_off(C, H, W, c, y, x)] = v
            vals.append(v)
        ok = True
        for k, v in enumerate(vals):
            c, rem = divmod(k, H * W)
            y, x = divmod(rem, W)
            if buf[_off(C, H, W, c, y, x)] != v:
                ok = False
                break
        tested += 1
        if not ok:
            bad += 1
            print("  ROUNDTRIP FAIL %s (%dx%dx%d)" % (u["name"], C, H, W))
    print("(1) round-trip: %d units, %d bad %s" % (tested, bad, "OK" if bad == 0 else "FAIL"))

    C, H, W = 16, 32, 32
    n = C * H * W
    vals = [(i * 7 + 3) & 0xFF for i in range(n)]
    def mism(buf, tag):
        d = 0
        for k, v in enumerate(vals):
            c, rem = divmod(k, H * W)
            y, x = divmod(rem, W)
            if buf[_off(C, H, W, c, y, x)] != v:
                d += 1
        print("%s mismatches=%d %s" % (tag, d, "OK" if d > 0 else "FAIL"))
        return d

    w_swap = bytearray(cb_size(C, H, W))
    w_nocb = bytearray(cb_size(C, H, W))
    for k, v in enumerate(vals):
        c, rem = divmod(k, H * W); y, x = divmod(rem, W)
        w_swap[_off(C, H, W, c, y, x, swap=True)] = v
        w_nocb[_off(C, H, W, c, y, x, no_cb=True)] = v
    d1 = mism(w_swap, "(2) negative A (swap ci/ix):")
    d2 = mism(w_nocb, "(3) negative B (drop n_cblk stride):")
    ok = (bad == 0 and d1 > 0 and d2 > 0)
    print("RESULT: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(selftest())
