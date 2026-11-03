#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cb_layout_account.py —— **通道分块（CB）布局** vs 现 **planar** 布局的取数账本（离线）。

只做算术，不碰 RTL/网表。口径全部来自本仓已冻结的几何契约：

  · tile：出数 `32×32`，输入窗口 `34×34`（halo ±1）；`s=2` 时 tile 宽 16、窗口 `2·16+2 = 34`。
  · planar band：每平面每 tile 行按 32 B 对齐读，**每 32 像素一个 band**；
    账本按平面各记（T-S3b），相邻 tile 的 2 列 halo 会**重读一次 band**。
    => 每 (平面, tile 行) 的 band 数 = ⌈(窗起点%32 + 34)/32⌉ ∈ {2,3}（平均 2.06…）
       —— 但**同一 tile 内 34 行**的 band 不共享（行跨步），所以每 tile 的 band 数按行累加。
  · 校准锚：`run_b1_tilebuf_ab.sh` 对 **Conv_15**（C_in=32, 160×160, nCi=4）实测
    `GATHER_BYTES = 924,800`（= nominal 819,200 × 1.1289）。本工具必须复现该值（§4 判据 ①）。

CB 布局（spec `arena_channel_block_spec.md`）：
  · 32×32 tile、块内 8 通道交织（每像素 8 B）=> 一个 tile 的**一行 32 像素 = 256 B 连续**；
  · 34 列窗口 = 本 tile 的 256 B（2×128 B）+ 邻 tile 的 2 像素 halo（16 B，1 笔）；
  · SG 项上限 128 B => 每 (8 通道块, tile 行) = **3 笔**（2×128 B + 1×16 B），字节 = 272 B。

用法：
  python tools/cb_layout_account.py                # 全表 + 汇总
  python tools/cb_layout_account.py --unit 15      # 单单元
  python tools/cb_layout_account.py --selftest     # 判据（含负对照）
"""
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
Y1 = os.path.dirname(HERE)
IDX = os.path.join(Y1, "gen", "wgt_index.json")

TILE = 32          # 出数 tile 宽/高
HALO = 2           # 窗口比出数多 2 列（左右各 1）
BAND = 32          # planar band 字节
SG_MAX = 128       # SG 单笔上限


def npass(c):
    return (int(c) + 7) // 8


def tile_geom(u):
    """返回 (tile 宽, tile 高, 窗宽) —— s=2 时 tile 宽减半（真表 `Conv_0`）。"""
    o = u["own"]
    stride = int(u.get("stride", 1) or 1)
    tw = TILE if stride == 1 else TILE // 2
    th = TILE
    win = stride * tw + HALO
    return tw, th, win


def planar(u):
    """(requests, bytes) —— 校准后的现布局模型。

    用闸门实测锚定（§4 ①）：Conv_15 的 `GATHER_BYTES = 924,800` = nominal × 1.1289 = (34/32)²。
    => 真实 gather 是**每 (平面, tile 行) 一笔 34 B 的连续行段**（不是 32 B band 对齐）：
       每 tile 的每平面 = 34 行 × 34 B；tile 数 = ⌈W/32⌉·⌈H/32⌉；每 8 通道块 × ⌈C_in/8⌉。
    """
    o = u["own"]
    H, W = int(o["IMG_H"]), int(o["IMG_W"])
    nci = npass(int(o["C_IN"]))
    tw, th, win = tile_geom(u)
    ntx = (W + tw - 1) // tw
    nty = (H + th - 1) // th
    rows = th + HALO                                   # 含上下 halo：34 行
    req = ntx * nty * rows * 8                         # 8 个平面各一笔
    byt = ntx * nty * rows * win * 8                   # 每笔窗口宽 win 字节
    return req * nci, byt * nci


def cb(u):
    """(requests, bytes) —— CB 布局：一个 128 B 请求服务 8 通道 × 16 像素。

    tile 行 34 像素 × 8 通道 = 272 B 连续 => ⌈272/128⌉ = 3 笔（2×128 B + 1×16 B）；字节 = 272 B。
    """
    o = u["own"]
    H, W = int(o["IMG_H"]), int(o["IMG_W"])
    nci = npass(int(o["C_IN"]))
    tw, th, win = tile_geom(u)
    ntx = (W + tw - 1) // tw
    nty = (H + th - 1) // th
    rows = th + HALO
    per_row = win * 8                                  # 272 B
    req = (per_row + SG_MAX - 1) // SG_MAX             # = 3
    return ntx * nty * rows * req * nci, ntx * nty * rows * per_row * nci


def units():
    return json.load(open(IDX, encoding="utf-8"))["units"]


def main():
    sel = None
    if "--unit" in sys.argv:
        sel = int(sys.argv[sys.argv.index("--unit") + 1])
    if "--selftest" in sys.argv:
        return selftest()

    tot_p = tot_c = 0
    tb_p = tb_c = 0
    print("%-3s %-11s %-10s %6s %6s %10s %10s %8s %8s %6s" %
          ("idx", "name", "type", "nCi", "win", "planar_req", "cb_req", "p_B", "c_B", "req×"))
    for i, u in enumerate(units()):
        if sel is not None and i != sel:
            continue
        if u["type"] not in ("conv1x1", "conv3x3", "depthwise"):
            continue
        p, pb = planar(u)
        c, cby = cb(u)
        o = u["own"]
        _, _, win = tile_geom(u)
        print("%-3d %-11s %-10s %6d %6d %10d %10d %8d %8d %6.2f" %
              (i, u["name"], u["type"], npass(int(o["C_IN"])), win, p, c, pb, cby,
               (p / c) if c else 0.0))
        tot_p += p; tot_c += c; tb_p += pb; tb_c += cby
    print("\nTOTAL   requests %d -> %d (÷%.2f)   bytes %d -> %d (%.0f%%)" %
          (tot_p, tot_c, (tot_p / tot_c) if tot_c else 0, tb_p, tb_c,
           100.0 * tb_c / tb_p if tb_p else 0))
    return 0


def selftest():
    us = units()
    conv15 = next(u for u in us if u["name"] == "Conv_15")
    p, pb = planar(conv15)
    ok1 = (pb == 924800)
    print("(1) anchor: Conv_15 planar bytes = %d (expect 924,800) %s" % (pb, "OK" if ok1 else "FAIL"))
    c, cb_b = cb(conv15)
    print("    CB: requests %d / bytes %d  (planar %d / %d)" % (c, cb_b, p, pb))
    ok2 = (c > 0 and cb_b == pb)
    print("(2) CB bytes == planar (same useful bytes): %s" % ("OK" if ok2 else "FAIL"))
    # (3) 负对照：把 halo 去掉（rows=th, win=tw）=> 模型必须明显变小（说明模型对几何敏感）
    save = (HALO,)
    g = globals()
    g["HALO"] = 0
    p0, _ = planar(conv15)
    g["HALO"] = save[0]
    ok3 = (p0 < 0.95 * p)
    print("(3) negative control (no halo => %.3f x, must be <0.95): %s" % (p0 / p, "OK" if ok3 else "FAIL"))
    ok = ok1 and ok2 and ok3
    print("RESULT: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
