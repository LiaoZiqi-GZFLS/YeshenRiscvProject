#!/usr/bin/env python3
"""eth_load_images.py -- push the four Linux images into DDR over UDP (EthLoader).

Wire format (see docs/superpowers/specs/2026-10-04-eth-loader-design.md §3/§4.3 and
src/peripheral/EthLoader.scala):
    UDP payload = 'Y','S','L','D' | seq(u16 BE) | ddr_addr(u32 BE) | data[...]   (10-byte header)
    END frame   = header only (payload len 10); the `ddr_addr` field carries the expected
                  16-bit XOR over ALL data bytes sent (low 16 bits used).
    RESTART     = header only with ddr_addr = 0xFFFF_FFFF: clears the board-side accumulator
                  AND the per-seq dedup bitmap, so the host can redo a whole pass without a reflash.
`seq` MUST be unique per frame: the board keeps a 1-bit-per-seq bitmap and DROPS any frame whose
seq was already seen (otherwise the global-XOR release criterion would be corrupted by duplicates).

No retransmit protocol yet (that is stage 2 of spec 4.3): pace at <= ~8000 pkt/s and rely on the
final XOR; on mismatch send a RESTART and redo the pass. Use eth_status_listen.py to watch the
board's reverse-channel status frames (`'N','X','B',1 | rxBytes(u32 BE)`).

Usage:
  python eth_load_images.py --src 192.168.1.105 --dst 192.168.1.11
  python eth_load_images.py --only fw_jump.bin --rate 2000     # smoke test
"""
import argparse
import os
import socket
import struct
import sys
import time

IMAGES = [
    ("fw_jump.bin", 0x80000000),
    ("Image",       0x82000000),
    ("linux.dtb",   0x82F80000),
    ("rootfs.cpio", 0x83000000),
]
MAGIC = b"YSLD"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default="192.168.1.105", help="host address on the board-facing NIC")
    ap.add_argument("--dst", default="192.168.1.11", help="board address (top-level LOCAL_IP)")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--root", default="sw/images")
    ap.add_argument("--only", default="")
    ap.add_argument("--file", default="", help="单文件模式：发送任意裸文件（配合 --addr），忽略 IMAGES")
    ap.add_argument("--addr", default="0x80000000", help="--file 的目标 DDR 地址")
    ap.add_argument("--rate", type=int, default=6000,
                    help="packets/s (measured lossless ceiling ~8000; 0 = blast)")
    ap.add_argument("--chunk", type=int, default=1408, help="data bytes per packet (must be a multiple of 32; 1408 + 8 = 1416)")
    ap.add_argument("--no-end", action="store_true", help="do not send the END/xor frame")
    ap.add_argument("--restart", action="store_true",
                    help="先发一个重装帧（addr=0xFFFF_FFFF）把板内 xor/计数/verdict 清回出厂 "
                         "——用于整幅 xor 对不上时**免重烧**重来一轮")
    ap.add_argument("--repeat", type=int, default=1, help="send the whole payload N times")
    a = ap.parse_args()

    assert (a.chunk + 8) <= 1472, "keep the UDP payload within the Ethernet MTU"
    assert a.chunk % 32 == 0, "chunk must be a multiple of 32 so every packet stays 32B-aligned"

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 * 1024 * 1024)
    s.bind((a.src, 0))
    dst = (a.dst, a.port)
    print(f"host {a.src} -> board {a.dst}:{a.port}   chunk={a.chunk} B/data-packet  rate={a.rate} pkt/s",
          flush=True)

    if a.restart:
        for _ in range(2):                      # 发两遍保险（重装是幂等的）
            s.sendto(MAGIC + struct.pack(">H", 0xFFFF) + struct.pack(">I", 0xFFFFFFFF), dst)
            time.sleep(0.05)
        print("RESTART frame sent (addr=0xFFFFFFFF)", flush=True)

    seq = 0
    total_pkts = 0
    total_bytes = 0
    for rnd in range(a.repeat):
        xor = 0
        n = 0
        t0 = time.perf_counter()
        imgs = [(os.path.basename(a.file), int(a.addr, 0))] if a.file else IMAGES
        for name, base in imgs:
            if a.only and name != a.only:
                continue
            path = a.file if a.file else os.path.join(a.root, name)
            if not os.path.exists(path):
                raise SystemExit(f"missing {path}")
            data = open(path, "rb").read()
            print(f"==> {name}: {len(data)} B @ {base:#010X}", flush=True)
            for off in range(0, len(data), a.chunk):
                blk = data[off:off + a.chunk]
                addr = base + off
                assert addr & 0x1F == 0, f"addr not 32B aligned: {addr:#x}"
                for b in blk:
                    xor ^= b
                s.sendto(MAGIC + struct.pack(">H", seq & 0xFFFF) + struct.pack(">I", addr) + blk, dst)
                seq += 1
                n += 1
                if a.rate:
                    while time.perf_counter() - t0 < n / a.rate:
                        pass
        dt = time.perf_counter() - t0
        total_pkts += n
        total_bytes += int(n * a.chunk)
        print(f"round {rnd + 1}/{a.repeat}: {n} pkts in {dt:.2f}s  "
              f"({n / max(dt, 1e-9):.0f} pkt/s, {n * a.chunk / max(dt, 1e-9) / 1e6:.1f} MB/s)", flush=True)

    if not a.no_end:
        end = MAGIC + struct.pack(">H", 0xFFFE) + struct.pack(">I", xor & 0xFFFF)
        for _ in range(3):                      # a few copies: the END frame is what releases the CPU
            s.sendto(end, dst)
            time.sleep(0.05)
        print(f"END sent x3, expected xor16 = 0x{xor & 0xFFFF:04X}", flush=True)

    print(f"TOTAL {total_pkts} pkts / {total_bytes / 1e6:.2f} MB data", flush=True)
    print("next: the CPU leaves reset only if the board's XOR matched -- watch the UART console; "
          "silence means a mismatch, just re-run this script.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
