#!/usr/bin/env python3
"""Generate 1024x600 RGB565 wallpapers: Debian Ink / Debian Paper."""
import math
import struct
import sys
from pathlib import Path

W, H = 1024, 600


def rgb565(r, g, b):
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def lerp(a, b, t):
    return int(a + (b - a) * t)


def generate(path, top, bottom, swirl, alpha):
    data = bytearray(W * H * 2)
    cx, cy = 760.0, 300.0
    for y in range(H):
        t = y / (H - 1)
        br = lerp(top[0], bottom[0], t)
        bg = lerp(top[1], bottom[1], t)
        bb = lerp(top[2], bottom[2], t)
        for x in range(W):
            r, g, b = br, bg, bb
            dx, dy = x - cx, y - cy
            rad = math.hypot(dx, dy)
            if 24.0 < rad < 330.0:
                ang = math.atan2(dy, dx)
                arm = (ang + rad / 42.0) % (2.0 * math.pi)
                band = min(arm, 2.0 * math.pi - arm)
                if band < 0.20:
                    a = alpha * (1.0 - band / 0.20)
                    r = lerp(r, swirl[0], a)
                    g = lerp(g, swirl[1], a)
                    b = lerp(b, swirl[2], a)
            struct.pack_into("<H", data, (y * W + x) * 2, rgb565(r, g, b))
    Path(path).write_bytes(data)
    print(f"{path}: {len(data)} bytes")


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "ui/assets")
    out.mkdir(parents=True, exist_ok=True)
    generate(out / "wallpaper_ink.bin",
             (18, 24, 32), (9, 13, 20), (168, 0, 48), 0.58)
    generate(out / "wallpaper_paper.bin",
             (238, 242, 247), (206, 216, 228), (168, 0, 48), 0.28)


if __name__ == "__main__":
    main()
