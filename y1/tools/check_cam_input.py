#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_cam_input.py —— 主机侧对账：板上 `y1cam --dump` 的 640×640 RGB565 快照 → 同口径 int8 CRC

用法：
  python check_cam_input.py <snap_640x640_rgb565.raw> [--swap-br]

输入：y1cam --dump 落盘的原始文件（640×640 个 little-endian uint16，共 819,200 B）
输出：一行 `HOST_INPUT_CRC=%08x`——对 1,228,800 B 的 NCHW-BGR int8 张量做 zlib.crc32。

口径（与板内 y1cam.c 的 prep_bgr_nchw_int8 逐条对应）：
  位域 [15:11]=R, [10:5]=G, [4:0]=B；位复制扩展
  r8=(r5<<3)|(r5>>2)、g8=(g6<<2)|(g6>>4)、b8=(b5<<3)|(b5>>2)；
  NCHW 平面顺序 B、G、R；int8 = 8-bit − 128（s=1.0 / zp=−128，与 to_int8_input 同口径）。

对账：`BOARD_INPUT_CRC`（板内）== `HOST_INPUT_CRC`（本脚本）⇒ 快照与预处理同口径。

负对照：--swap-br 把 B/R 平面顺序对调。只要图像不是纯灰（B==R），CRC **必变**。
"""
import sys
import zlib

import numpy as np

W = H = 640
N = W * H


def usage(code=2):
    print("usage: check_cam_input.py <snap_640x640_rgb565.raw> [--swap-br]", file=sys.stderr)
    return code


def main(argv):
    path = None
    swap = False
    for a in argv[1:]:
        if a == "--swap-br":
            swap = True
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        elif a.startswith("-"):
            print("!! unknown option: %s" % a, file=sys.stderr)
            return usage()
        elif path is None:
            path = a
        else:
            print("!! too many positional args", file=sys.stderr)
            return usage()
    if path is None:
        return usage()

    raw = np.fromfile(path, dtype='<u2')
    if raw.size != N:
        print("!! %s: %d u16 != %d（应为 %d B 的 640x640 RGB565）"
              % (path, int(raw.size), N, N * 2), file=sys.stderr)
        return 3
    raw = raw.reshape(H, W)

    r = ((raw >> 11) & 0x1F).astype(np.uint8)
    g = ((raw >> 5) & 0x3F).astype(np.uint8)
    b = (raw & 0x1F).astype(np.uint8)
    r8 = (r << 3) | (r >> 2)
    g8 = (g << 2) | (g >> 4)
    b8 = (b << 3) | (b >> 2)

    planes = [b8, g8, r8]                      # NCHW：B、G、R
    if swap:
        planes[0], planes[2] = planes[2], planes[0]   # 负对照：B/R 对调

    q = (np.stack(planes).astype(np.int16) - 128).astype(np.int8)
    print("HOST_INPUT_CRC=%08x" % (zlib.crc32(q.tobytes()) & 0xffffffff))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
