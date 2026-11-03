#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mk_hex.py —— 把黄金的二进制产物转成 $readmemh 能吃的 64-bit 字（小端语义）。

  python mk_hex.py --case fill_rect --gold sim/gpu/gold

产物：
  <case>.init.hex   @0 = fb_initial.bin 的 153600 个 8 B 字；@0x40000 = assets.bin（2 MB 处）
  <case>.exp.hex    fb 的 153600 个字（期望值）
"""
import argparse
import pathlib
import struct

FB_W, FB_H = 1024, 600
FB_BYTES = FB_W * FB_H * 2
ASSET_WORD = 0x200000 // 8


def words(data, n):
    out = []
    for i in range(n):
        chunk = data[i * 8:(i + 1) * 8]
        if len(chunk) < 8:
            chunk = chunk + b'\x00' * (8 - len(chunk))
        out.append(struct.unpack('<Q', chunk)[0])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--case', required=True)
    ap.add_argument('--gold', default='sim/gpu/gold')
    a = ap.parse_args()
    g = pathlib.Path(a.gold)
    fb0 = (g / 'fb_initial.bin').read_bytes()
    fb1 = (g / (a.case + '.fb.bin')).read_bytes()
    assets = (g / 'assets.bin').read_bytes()
    assert len(fb0) == FB_BYTES and len(fb1) == FB_BYTES, (len(fb0), len(fb1))

    with open(g / (a.case + '.init.hex'), 'w') as f:
        f.write('@0\n')
        for w in words(fb0, FB_BYTES // 8):
            f.write('%016x\n' % w)
        f.write('@%x\n' % ASSET_WORD)
        for w in words(assets, (len(assets) + 7) // 8):
            f.write('%016x\n' % w)

    with open(g / (a.case + '.exp.hex'), 'w') as f:
        for w in words(fb1, FB_BYTES // 8):
            f.write('%016x\n' % w)

    print('hex ok:', a.case, FB_BYTES // 8, 'fb words +', (len(assets) + 7) // 8, 'asset words')


if __name__ == '__main__':
    main()
