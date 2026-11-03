#!/usr/bin/env python3
"""Task 12 证据脚本：把 [ALIGN] 逐拍日志里的 (FETCH_PC, WORD) 对与 ELF 镜像逐字节对账。

用法：
    python3 scripts/check_aligner_window.py <log> <image.bin> [--base 0x80000000]

读 `sim/tb_naxmini.cpp` 里 TB_ALIGN=1 打出来的行：
    [ALIGN] <cyc> IN iv=.. pc=<FETCH_PC> ... w=<64bit word> ...
并对每一行判定 WORD 是否 == 镜像里 [pc, pc+8) 的 8 字节：
    MATCH      完全一致
    OFF-k      等于 [pc-k, pc-k+8)，k>0（窗口整体偏低 k 字节）
    其它       打印实际/期望，人工看

输出：每个 (pc, 偏移) 的计数表 + 全部 OFF 行的原文（限 N 条）。
这是纯离线对账，不参与仿真，也不改任何 RTL/网表。
"""
import re
import sys
from collections import Counter

ALIGN_RE = re.compile(
    r"^\[ALIGN\]\s+(\d+)\s+IN iv=(\d).*?\bpc=([0-9A-Fa-f]+).*?\bw=([0-9A-Fa-f]+)\s+\|"
)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    log_path, bin_path = sys.argv[1], sys.argv[2]
    base = 0x80000000
    if "--base" in sys.argv:
        base = int(sys.argv[sys.argv.index("--base") + 1], 0)

    img = open(bin_path, "rb").read()

    def mem64(addr):
        off = addr - base
        if off < 0 or off + 8 > len(img):
            return None
        return int.from_bytes(img[off:off + 8], "little")

    n_line = n_invalid = 0
    stats = Counter()
    detail = []
    for line in open(log_path, "r", errors="replace"):
        m = ALIGN_RE.match(line)
        if not m:
            continue
        cyc, iv, pc, w = int(m.group(1)), int(m.group(2)), int(m.group(3), 16), int(m.group(4), 16)
        n_line += 1
        if iv == 0:
            n_invalid += 1
            continue
        exp = mem64(pc)
        if exp is None:
            continue
        off = 0
        found = None
        for k in range(0, 17, 4):          # 允许 0/4/8/12/16 字节的偏移
            cand = mem64(pc - k)
            if cand is not None and cand == w:
                found, off = k, k
                break
        if found is None:
            stats["MISMATCH(不在任何一种偏移下)"] += 1
            if len(detail) < 12:
                detail.append(f"cyc={cyc} pc={pc:08X} w={w:016X} expect[0]={exp:016X}")
        else:
            stats["MATCH" if off == 0 else f"OFF-{off}"] += 1

    print(f"log            = {log_path}")
    print(f"image          = {bin_path}  ({len(img)} B, base=0x{base:08X})")
    print(f"[ALIGN] 行数    = {n_line}（其中 iv=0 的 {n_invalid} 行不参与对账）")
    for k in sorted(stats):
        print(f"  {k:34s} {stats[k]}")
    for d in detail:
        print("  " + d)
    return 0


if __name__ == "__main__":
    sys.exit(main())
