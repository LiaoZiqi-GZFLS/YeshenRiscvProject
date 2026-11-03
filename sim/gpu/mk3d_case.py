#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mk3d_case.py —— 生成 gpu_3d(DRAW_TRIS) 子系统闸门的初始化/期望文件。

输出（默认 sim/gpu/gold3d/）：
  <case>.ram.hex   AXI RAM 模型初值（@字地址 + 16 hex 数字，只写三角形记录区）
  <case>.exp.hex   逐像素 `color z`（hex），按 W*H 行
  <case>.cfg       `W H TRI_ADDR TRI_COUNT COLOR_BASE COLOR_STRIDE Z_BASE Z_STRIDE CLEAR_C CLEAR_Z`

缓冲区几何固定为 64×32（两 tile 宽 × 一 tile 高），颜色缓冲 0x1000、Z 缓冲 0x4000、
三角形记录 0x0800（都在 AW=16 的 8 B 字模型里）。
"""
import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tri_ref as T   # 复用同口径光栅

W, H = 64, 32
COLOR_BASE, Z_BASE, TRI_BASE = 0x1000, 0x4000, 0x0800
CLEAR_C, CLEAR_Z = 0x0000, 0xFFFF
# 复合目标：96×40 缓冲区、偏移 (7,3)、哨兵色 0xAAAA
DW, DH = 96, 40
DST_BASE, DST_STRIDE = 0x8000, 96
DX, DY = 8, 3   # dst_x 必须是 4 的倍数（每拍写满 8 B = 4 px）
SENTINEL = 0xAAAA


def build(name):
    """返回 [(v0,v1,v2,color,zmode), ...]（v 为 (x_q8,y_q8,z)）。"""
    if name == "one":
        return [(T.vtx(4, 4, 100), T.vtx(60, 8, 100), T.vtx(10, 28, 100), 0xF800, "less")]
    if name == "zoccl":
        # 先远后近：近的必须覆盖；近的三角形只盖住左半边
        return [(T.vtx(0, 0, 40000), T.vtx(63, 0, 40000), T.vtx(0, 31, 40000), 0x07E0, "less"),
                (T.vtx(2, 2, 1000), T.vtx(34, 6, 1000), T.vtx(6, 29, 1000), 0x001F, "less")]
    if name == "comp":
        # 复合用例：一个三角形 → 颜色缓冲 → 复合到 dst (7,3)
        return [(T.vtx(4, 4, 200), T.vtx(56, 10, 200), T.vtx(12, 28, 200), 0xF81F, "less")]
    if name == "span":
        # 跨 tile 边界的三角形（x=20..44 跨 32 像素边界）
        return [(T.vtx(20, 2, 500), T.vtx(44, 10, 500), T.vtx(28, 30, 500), 0xFFE0, "less")]
    if name == "comp4":
        # 多块复合：源 256 宽 ⇒ COMPOSITE3D 每行 **4 个 64 px 块**（cchunks=4）。
        # 既有 comp 用例源宽 64 ⇒ cchunks=1，**多块推进这条路从来没被覆盖**，
        # 而板上判据（640 宽取 256 贴图）正是 4 块 —— 2026-11-02 补上。
        return [(T.vtx(4, 2, 300), T.vtx(250, 8, 300), T.vtx(12, 29, 300), 0x07E0, "less")]
    raise SystemExit("unknown case " + name)


# 逐用例几何覆盖（默认 64×32 源 + 96×40 目标）
GEOM = {
    # 基址要重排：256×32 的颜色缓冲 16 KB，默认的 Z_BASE=0x4000 会压在颜色区里
    "comp4": dict(W=256, H=32, DW=320, DH=40, DX=8, DY=3,
                  CB=0x1000, ZB=0x6000, DB=0x20000),
}


def emit(name, out_dir):
    g = GEOM.get(name, {})
    W = g.get("W", globals()["W"]); H = g.get("H", globals()["H"])
    DW = g.get("DW", globals()["DW"]); DH = g.get("DH", globals()["DH"])
    DX = g.get("DX", globals()["DX"]); DY = g.get("DY", globals()["DY"])
    CB = g.get("CB", COLOR_BASE); ZB = g.get("ZB", Z_BASE); DB = g.get("DB", DST_BASE)
    tris = build(name)
    # 黄金：用 tri_ref 的 raster_tri 逐三角形画
    cb, zb = T.clear(CLEAR_C, CLEAR_Z, W, H)
    for (a, b, c, color, ztest) in tris:
        T.raster_tri(a, b, c, color, ztest, cb, zb, W, H)

    os.makedirs(out_dir, exist_ok=True)
    # ---- 三角形记录（48 B/个，6 个 8 B 字）----
    recs = []
    for (a, b, c, color, ztest) in tris:
        dzdx, dzdy = T.plane_coeff(a, b, c)
        zm = {"less": 0, "lequal": 1, "off": 2}[ztest]
        w0 = (a[1] & 0xFFFFFFFF) << 32 | (a[0] & 0xFFFFFFFF)
        w1 = (b[1] & 0xFFFFFFFF) << 32 | (b[0] & 0xFFFFFFFF)
        w2 = (c[1] & 0xFFFFFFFF) << 32 | (c[0] & 0xFFFFFFFF)
        w3 = ((dzdx & 0xFFFFFFFF) << 32) | ((color & 0xFFFF) << 16) | (a[2] & 0xFFFF)
        w4 = ((zm & 0x3) << 32) | (dzdy & 0xFFFFFFFF)
        recs += [w0, w1, w2, w3, w4, 0]

    with open(os.path.join(out_dir, name + ".ram.hex"), "w") as f:
        f.write("@%04x\n" % (TRI_BASE // 8))
        for w in recs:
            f.write("%016x\n" % w)

    comp = (name in ("comp", "comp4"))
    exp = [(cb[i], zb[i]) for i in range(W * H)]
    if comp:
        # dst 先被 CLEAR3D 填成哨兵色，再把 3D 颜色缓冲贴到 (DX,DY)
        db = [(SENTINEL, CLEAR_Z) for _ in range(DW * DH)]
        for y in range(H):
            for x in range(W):
                db[(DY + y) * DW + DX + x] = (cb[y * W + x], CLEAR_Z)
        exp += db

    with open(os.path.join(out_dir, name + ".exp.hex"), "w") as f:
        for (c, z) in exp:
            f.write("%04x %04x\n" % (c, z))

    with open(os.path.join(out_dir, name + ".cfg"), "w") as f:
        f.write("%d %d %d %d %d %d %d %d %04x %04x %d %d %d %d %d %d\n" % (
            W, H, TRI_BASE, len(tris), CB, W, ZB, W, CLEAR_C, CLEAR_Z,
            1 if comp else 0, DB, DW, DX, DY, DW * DH))
    print("case %s: %d tris%s -> %s" % (name, len(tris), " +composite" if comp else "", out_dir))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--case", required=True)
    ap.add_argument("--out", default="sim/gpu/gold3d")
    a = ap.parse_args()
    emit(a.case, a.out)
