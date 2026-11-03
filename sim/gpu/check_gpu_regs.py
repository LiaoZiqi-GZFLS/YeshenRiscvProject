#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_gpu_regs.py —— GPU 寄存器/op 的 Verilog ↔ C 镜像闸门。

唯一来源是 rtl/gpu/gpu_regs.vh；YeshenGui/platform/gpu_regs.h 必须逐项相等。
任何一边改了另一边没跟上 ⇒ 非零退出。

用法（在 VexiiYeshenLinux 根下）： python3 sim/gpu/check_gpu_regs.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
VH = ROOT / 'rtl' / 'gpu' / 'gpu_regs.vh'
H = ROOT.parent / 'YeshenGui' / 'platform' / 'gpu_regs.h'


def parse_vh(text):
    out = {}
    for name, val in re.findall(r"`define\s+(\w+)\s+([0-9]+'h[0-9A-Fa-f_]+)", text):
        out[name] = int(val.split("'h")[1].replace('_', ''), 16)
    return out


def parse_h(text):
    out = {}
    for name, val in re.findall(r"#define\s+(\w+)\s+(0[xX][0-9A-Fa-f_]+)u?", text):
        out[name] = int(val.replace('_', ''), 16)
    return out


def main():
    if not VH.exists():
        print(f"FAIL: missing {VH}")
        return 2
    if not H.exists():
        print(f"FAIL: missing {H}")
        return 2
    v = parse_vh(VH.read_text(encoding='utf-8'))
    h = parse_h(H.read_text(encoding='utf-8'))
    only_v = sorted(set(v) - set(h))
    only_h = sorted(set(h) - set(v))
    bad = sorted(k for k in set(v) & set(h) if v[k] != h[k])
    for k in only_v:
        print(f"  - {k}: only in .vh (=0x{v[k]:08x})")
    for k in only_h:
        print(f"  + {k}: only in .h (=0x{h[k]:08x})")
    for k in bad:
        print(f"  ! {k}: .vh=0x{v[k]:08x} .h=0x{h[k]:08x}")
    if only_v or only_h or bad:
        print(f"FAIL: gpu_regs mirror mismatch ({len(only_v)}+{len(only_h)}+{len(bad)})")
        return 1
    print(f"GPU-REGS-MIRROR OK {len(v)} entries")
    return 0


if __name__ == '__main__':
    sys.exit(main())
