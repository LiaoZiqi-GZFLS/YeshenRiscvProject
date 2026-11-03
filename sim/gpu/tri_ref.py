#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tri_ref.py —— P2a 3D 光栅器的**同口径黄金**（整数运算，逐位可复现）。

语义（与 RTL 逐条对应，改一处必须两边一起改）：
  顶点 16 B（little-endian）：{s32 x_q8_8, s32 y_q8_8, u16 z, u16 pad, u32 pad2}
    · x/y 为 8.8 定点（256 = 1 px），屏幕坐标原点在左上，y 向下
    · z ∈ [0,65535]，0=近
  三角形 = 3 个连续顶点；顶点按**有符号面积**归一成顺时针（面积 < 0 交换 v1/v2）

  采样点 = 像素中心 (px+0.5, py+0.5) ⇒ 在 8.8 网格里是 (px*256+128, py*256+128)

  边函数（Q16 单位，整数）：
    E0(x,y) = (x2-x1)*(y-y1) - (y2-y1)*(x-x1)     # 边 v1->v2
    E1(x,y) = (x0-x2)*(y-y2) - (y0-y2)*(x-x2)     # 边 v2->v0
    E2(x,y) = (x1-x0)*(y-y0) - (y1-y0)*(x-x0)     # 边 v0->v1
  内部判据：E0,E1,E2 全 ≥0（归一成正面积后）。边界（=0）算内部。
  面积 area = E0(v0)（= 归一后的 2 倍面积，>0）

  Z 平面（setup 一次，含一次整数除法，向零截断）：
    dzdx = ( (z1-z0)*(y2-y0) - (z2-z0)*(y1-y0) ) * 256 // area
    dzdy = ( (z2-z0)*(x1-x0) - (z1-z0)*(x2-x0) ) * 256 // area
    对像素中心：z(px,py) = z0 + ( dzdx*((px<<8)+128 - x0) + dzdy*((py<<8)+128 - y0) ) >> 16
    （先加后右移，除法已按 256 缩放；结果 clamp 到 [0,65535]）
  实测（RTL）用同样的整数式，避免"数学上等价但取整不同"的假 bug。

  Z 测试：ztest='less' → 新 z < 旧 z 才写；'lequal' → ≤；'off' → 总是写（并写 z）。
  初值：颜色 0x0000，Z 0xFFFF。

用法：
  python3 tri_ref.py --case <name> --out <dir>     # 生成 .vtx.hex / .exp.hex / .cfg
  python3 tri_ref.py --selftest                   # 性质自检（非退化用例）
"""
import argparse
import os
import struct
import sys

W, H = 128, 96          # 单元闸门分辨率（M1）


def q8(v):
    return int(round(v * 256))


def vtx(x, y, z):
    return (q8(x), q8(y), z & 0xFFFF)


def pack_vertex(v):
    x, y, z = v
    # s32 x, s32 y, u16 z, u16 pad, u32 pad2 = 16 B
    return struct.pack("<iiHHI", x, y, z, 0, 0)


def norm_cw(a, b, c):
    """把三角形归一成 area>0（顺时针/正面积）。"""
    area = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
    if area < 0:
        return a, c, b, -area
    return a, b, c, area


def raster_tri(a, b, c, color, ztest, color_buf, zbuf, w=W, h=H):
    a, b, c, area = norm_cw(a, b, c)
    if area == 0:
        return 0
    (x0, y0, z0), (x1, y1, z1), (x2, y2, z2) = a, b, c

    # Z 平面（整数，向零截断）
    dzdx = ((z1 - z0) * (y2 - y0) - (z2 - z0) * (y1 - y0)) * 256 // area
    dzdy = ((z2 - z0) * (x1 - x0) - (z1 - z0) * (x2 - x0)) * 256 // area

    # 包围盒（按 8.8 顶点取整到像素）
    xmin = max(0, min(x0, x1, x2) >> 8)
    xmax = min(w - 1, max(x0, x1, x2) >> 8)
    ymin = max(0, min(y0, y1, y2) >> 8)
    ymax = min(h - 1, max(y0, y1, y2) >> 8)

    # 边系数（Q16）：E_i(p) = (v_next - v_i) x (p - v_i)，正面积三角形内部 E>=0
    #   E0: v1->v2 ; E1: v2->v0 ; E2: v0->v1
    A0, B0 = -(y2 - y1), (x2 - x1)
    C0 = (y2 - y1) * x1 - (x2 - x1) * y1
    A1, B1 = -(y0 - y2), (x0 - x2)
    C1 = (y0 - y2) * x2 - (x0 - x2) * y2
    A2, B2 = -(y1 - y0), (x1 - x0)
    C2 = (y1 - y0) * x0 - (x1 - x0) * y0

    px_cnt = 0
    for py in range(ymin, ymax + 1):
        sy = (py << 8) + 128
        for px in range(xmin, xmax + 1):
            sx = (px << 8) + 128
            e0 = A0 * sx + B0 * sy + C0
            e1 = A1 * sx + B1 * sy + C1
            e2 = A2 * sx + B2 * sy + C2
            if e0 < 0 or e1 < 0 or e2 < 0:
                continue
            z = z0 + ((dzdx * (sx - x0) + dzdy * (sy - y0)) >> 16)
            if z < 0:
                z = 0
            elif z > 0xFFFF:
                z = 0xFFFF
            i = py * w + px
            if ztest == "off":
                color_buf[i] = color
                zbuf[i] = z
            else:
                ok = (z < zbuf[i]) if ztest == "less" else (z <= zbuf[i])
                if ok:
                    color_buf[i] = color
                    zbuf[i] = z
            px_cnt += 1
    return px_cnt


def clear(color, z, w=W, h=H):
    return [color] * (w * h), [z] * (w * h)


# ------------------------------------------------------------------ 用例
def build_case(name):
    """返回 (vertices, tris[(i0,i1,i2,color,ztest)], desc)。"""
    verts = []
    tris = []

    def add(a, b, c, color, ztest):
        i = len(verts)
        verts.extend([a, b, c])
        tris.append((i, i + 1, i + 2, color, ztest))

    if name == "single":
        # 一个覆盖左下半屏的直角三角形（边界恰好是对角线）
        add(vtx(0, 0, 0), vtx(W, 0, 0), vtx(0, H, 0), 0xF800, "less")
    elif name == "two_z":
        # 两个相交三角形：先远后近 —— 近的必须盖住远的
        add(vtx(4, 4, 40000), vtx(W - 8, 20, 40000), vtx(30, H - 8, 40000), 0x07E0, "less")
        add(vtx(10, 10, 1000), vtx(W - 20, 30, 1000), vtx(50, H - 20, 1000), 0x001F, "less")
    elif name == "zswap":
        # 同上但**先近后远**：远的必须被 Z 挡住（不覆盖）
        add(vtx(10, 10, 1000), vtx(W - 20, 30, 1000), vtx(50, H - 20, 1000), 0x001F, "less")
        add(vtx(4, 4, 40000), vtx(W - 8, 20, 40000), vtx(30, H - 8, 40000), 0x07E0, "less")
    elif name == "zlequal":
        # 同 Z 两个三角形：LESS 时后者不写，LEQUAL 时后者覆盖
        add(vtx(0, 0, 32768), vtx(W, 0, 32768), vtx(0, H, 32768), 0xF800, "lequal")
        add(vtx(0, 0, 32768), vtx(W, 0, 32768), vtx(0, H, 32768), 0x001F, "lequal")
    elif name == "zneg":
        # 退化：零面积三角形（三个共线点）—— 必须一个像素都不画
        add(vtx(0, 0, 100), vtx(W // 2, H // 2, 100), vtx(W, H, 100), 0xFFFF, "less")
    elif name == "offscreen":
        # 大部分在屏幕外，只露一个角
        add(vtx(-200, -200, 500), vtx(40, -200, 500), vtx(-200, 40, 500), 0xFFE0, "less")
    elif name == "edge_hit":
        # 共边两三角形（顺时针连续）：两片的并集必须无缝（边界像素只归一个）
        add(vtx(10, 10, 100), vtx(70, 10, 100), vtx(10, 60, 100), 0xF800, "less")
        add(vtx(70, 10, 100), vtx(70, 60, 100), vtx(10, 60, 100), 0x07E0, "less")
    else:
        raise SystemExit("unknown case " + name)
    return verts, tris


def plane_coeff(a, b, c):
    """与 raster_tri 里同样的整数式，单独暴露给 TB（CPU 侧就是这么算的）。"""
    a, b, c, area = norm_cw(a, b, c)
    (x0, y0, z0), (x1, y1, z1), (x2, y2, z2) = a, b, c
    if area == 0:
        return 0, 0
    dzdx = ((z1 - z0) * (y2 - y0) - (z2 - z0) * (y1 - y0)) * 256 // area
    dzdy = ((z2 - z0) * (x1 - x0) - (z1 - z0) * (x2 - x0)) * 256 // area
    return dzdx, dzdy


def run_case(name, out_dir):
    verts, tris = build_case(name)
    color_buf, zbuf = clear(0, 0xFFFF)
    for (i0, i1, i2, color, ztest) in tris:
        raster_tri(verts[i0], verts[i1], verts[i2], color, ztest, color_buf, zbuf)

    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, name + ".vtx.hex"), "w") as f:
        for v in verts:
            f.write(pack_vertex(v).hex() + "\n")
    with open(os.path.join(out_dir, name + ".exp.hex"), "w") as f:
        for i in range(W * H):
            f.write("%04x %04x\n" % (color_buf[i], zbuf[i]))
    # TB 直接吃的每三角形参数行（dzdx/dzdy 由 CPU 侧按同一整数式计算后下发）
    with open(os.path.join(out_dir, name + ".tri.hex"), "w") as f:
        for (i0, i1, i2, color, ztest) in tris:
            va, vb, vc = verts[i0], verts[i1], verts[i2]
            dzdx, dzdy = plane_coeff(va, vb, vc)
            zm = {"less": 0, "lequal": 1, "off": 2}[ztest]
            f.write("%08x %08x %08x %08x %08x %08x %04x %04x %08x %08x %01x\n" % (
                va[0] & 0xFFFFFFFF, va[1] & 0xFFFFFFFF,
                vb[0] & 0xFFFFFFFF, vb[1] & 0xFFFFFFFF,
                vc[0] & 0xFFFFFFFF, vc[1] & 0xFFFFFFFF,
                va[2], color,
                dzdx & 0xFFFFFFFF, dzdy & 0xFFFFFFFF, zm))
    print("case %s: %d verts, %d tris -> %s" % (name, len(verts), len(tris), out_dir))


def selftest():
    """性质自检：不依赖 RTL，先证黄金本身不是恒真/恒假。"""
    ok = True

    # ① 覆盖左下半屏的直角三角形：像素数应为 W*H/2 的"含对角线"版本
    color_buf, zbuf = clear(0, 0xFFFF)
    n = raster_tri(vtx(0, 0, 0), vtx(W, 0, 0), vtx(0, H, 0), 1, "less", color_buf, zbuf)
    expect = W * H // 2
    if n != expect:
        print("  [selftest] FAIL single: %d != %d" % (n, expect))
        ok = False
    # 像素 (0,0) 必须在，(W-1,H-1) 必须不在（对角线上另算）
    if color_buf[0] != 1 or color_buf[(H - 1) * W + (W - 1)] != 0:
        print("  [selftest] FAIL single coverage corners")
        ok = False

    # ② Z：先远后近 ⇒ 近的赢；先近后远 ⇒ 远的被挡
    c1, z1 = clear(0, 0xFFFF)
    raster_tri(vtx(0, 0, 40000), vtx(W, 0, 40000), vtx(0, H, 40000), 0xF800, "less", c1, z1)
    raster_tri(vtx(0, 0, 1000), vtx(W, 0, 1000), vtx(0, H, 1000), 0x001F, "less", c1, z1)
    if c1[0] != 0x001F:
        print("  [selftest] FAIL z far-then-near")
        ok = False
    c2, z2 = clear(0, 0xFFFF)
    raster_tri(vtx(0, 0, 1000), vtx(W, 0, 1000), vtx(0, H, 1000), 0x001F, "less", c2, z2)
    raster_tri(vtx(0, 0, 40000), vtx(W, 0, 40000), vtx(0, H, 40000), 0xF800, "less", c2, z2)
    if c2[0] != 0x001F:
        print("  [selftest] FAIL z near-then-far")
        ok = False

    # ③ LEQUAL：同 Z 后画者赢
    c3, z3 = clear(0, 0xFFFF)
    raster_tri(vtx(0, 0, 100), vtx(W, 0, 100), vtx(0, H, 100), 0xF800, "lequal", c3, z3)
    raster_tri(vtx(0, 0, 100), vtx(W, 0, 100), vtx(0, H, 100), 0x001F, "lequal", c3, z3)
    if c3[0] != 0x001F:
        print("  [selftest] FAIL lequal")
        ok = False
    # 用 LESS 必须**不**覆盖（负对照）
    c4, z4 = clear(0, 0xFFFF)
    raster_tri(vtx(0, 0, 100), vtx(W, 0, 100), vtx(0, H, 100), 0xF800, "less", c4, z4)
    raster_tri(vtx(0, 0, 100), vtx(W, 0, 100), vtx(0, H, 100), 0x001F, "less", c4, z4)
    if c4[0] != 0xF800:
        print("  [selftest] FAIL less-negative")
        ok = False

    # ④ 退化三角形不画
    c5, z5 = clear(0, 0xFFFF)
    n5 = raster_tri(vtx(0, 0, 1), vtx(W // 2, H // 2, 1), vtx(W, H, 1), 0xFFFF, "less", c5, z5)
    if n5 != 0 or any(v != 0 for v in c5):
        print("  [selftest] FAIL degenerate painted %d" % n5)
        ok = False

    # ⑤ 共边两片：并集无洞（每像素至少被一片覆盖）
    c6, z6 = clear(0, 0xFFFF)
    raster_tri(vtx(10, 10, 100), vtx(70, 10, 100), vtx(10, 60, 100), 1, "less", c6, z6)
    raster_tri(vtx(70, 10, 100), vtx(70, 60, 100), vtx(10, 60, 100), 2, "less", c6, z6)
    quad = [(x, y) for y in range(10, 60) for x in range(10, 70)]
    holes = sum(1 for (x, y) in quad if c6[y * W + x] == 0)
    if holes:
        print("  [selftest] FAIL shared-edge holes=%d" % holes)
        ok = False

    print("tri_ref selftest:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--case")
    ap.add_argument("--out", default="sim/gpu/gold3d")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        sys.exit(selftest())
    if not a.case:
        raise SystemExit("need --case or --selftest")
    run_case(a.case, a.out)


if __name__ == "__main__":
    main()
