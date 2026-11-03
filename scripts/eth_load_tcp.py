#!/usr/bin/env python3
"""eth_load_tcp.py -- TCP twin of eth_load_images.py: push the four Linux images into DDR
over a TCP connection, with byte-identical record payloads to the UDP loader.

Wire format (see docs/superpowers/specs/2026-10-04-eth-loader-design.md and
src/peripheral/EthLoader.scala -- the board side consumes the SAME payloads as UDP):
    TCP record  = u32 big-endian length | length payload bytes
    payload     = 'Y','S','L','D' | seq(u16 BE) | ddr_addr(u32 BE) | data[...]   (10-byte header)
    END payload = header only (payload len 10); the `ddr_addr` field carries the expected
                  16-bit XOR over ALL data bytes sent (low 16 bits used).
    RESTART     = header only with ddr_addr = 0xFFFF_FFFF: clears the board-side accumulator
                  AND the per-seq dedup bitmap, so the host can redo a whole pass without a reflash.

Reliability comes from TCP itself -- NO --rate pacing, NO retransmit protocol: blast with
sendall and let TCP do ordering/delivery. `seq` stays unique per frame across the whole run
(mirrors the UDP loader's global counter, which the board's 1-bit-per-seq bitmap relies on).

Line-level parity with eth_load_images.py (that file is authoritative and untouched):
    UDP L80-87 file/only/addr selection   -> main(), identical
    UDP L89-90 chunk split                 -> build_frames(), identical
    UDP L92   32B-align assert             -> build_frames(), identical
    UDP L93-94 `for b in blk: xor ^= b`    -> build_frames(), identical (accumulates over frames)
    UDP L95   header construction          -> build_frames(), byte-identical payload
    UDP L96   seq increment                -> build_frames(), global counter continues across rounds
    UDP L77   `xor = 0` at start of round  -> build_frames() inits xor=0 per call (reset per round)
    UDP L108  END payload (xor & 0xFFFF)   -> main(), same bytes (sent x2; TCP guarantees order)
    UDP L69   RESTART payload              -> main(), same bytes (sent twice)
    UDP --rate is the ONLY dropped option: TCP has no pacing.

Usage:
  python eth_load_tcp.py --src 192.168.1.105 --dst 192.168.1.11
  python eth_load_tcp.py --only fw_jump.bin               # smoke test
  python eth_load_tcp.py --repeat 3                        # 3 rounds, xor resets per round
  python eth_load_tcp.py --selftest                        # offline xor/roundtrip checks
"""
import argparse
import os
import socket
import struct
import sys
import tempfile
import time

IMAGES = [
    ("fw_jump.bin", 0x80000000),
    ("Image",       0x82000000),
    ("linux.dtb",   0x82F80000),
    ("rootfs.cpio", 0x83000000),
]
MAGIC = b"YSLD"


def frame(payload):
    """One TCP record: u32 big-endian length + payload (payload == one UDP datagram payload)."""
    return struct.pack(">I", len(payload)) + payload


def build_frames(data_list, chunk=1408, seq=0):
    """The per-round walk, factored out of main() so --selftest exercises the very same code.

    data_list: [(ddr_base_addr, file_bytes), ...]
    Returns (list_of_payloads, xor16): each payload is byte-identical to what the UDP loader
    puts in a datagram (10-byte header + up to `chunk` data bytes); xor16 is the running
    per-byte XOR over ALL data bytes of this round (low 16 bits) for the END frame.
    xor restarts at 0 on every call -- mirrors UDP L77 (`xor = 0` per round).
    """
    payloads = []
    xor = 0
    for base, data in data_list:
        for off in range(0, len(data), chunk):          # UDP L89
            blk = data[off:off + chunk]                 # UDP L90
            addr = base + off
            assert addr & 0x1F == 0, f"addr not 32B aligned: {addr:#x}"   # UDP L92
            for b in blk:                               # UDP L93
                xor ^= b                                # UDP L94
            payloads.append(MAGIC + struct.pack(">H", seq & 0xFFFF) + struct.pack(">I", addr) + blk)  # UDP L95
            seq += 1                                    # UDP L96
    return payloads, xor & 0xFFFF


def selftest():
    """Offline checks: xor parity vs an independent reference + byte-parity round trip."""
    n = 10000
    data = bytes((i * 7 + 13) & 0xFF for i in range(n))   # patterned, NEVER all zeros
    assert any(data), "test vector must be nonzero"

    # write a temporary nonzero binary file and read it back through the same path main() uses
    fd, path = tempfile.mkstemp(prefix="eth_tcp_selftest_", suffix=".bin")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        with open(path, "rb") as f:
            data = f.read()
    finally:
        os.unlink(path)
    assert len(data) == n, f"expected {n} B, got {len(data)}"

    base = 0x80000000
    payloads, xor16 = build_frames([(base, data)], chunk=1408, seq=0)
    assert payloads, "no frames built"

    # (a) xor16 vs a reference computed independently in the selftest (straight per-byte xor)
    ref = 0
    for b in data:
        ref ^= b
    ref &= 0xFFFF
    assert xor16 == ref, f"XOR MISMATCH: build_frames=0x{xor16:04X} reference=0x{ref:04X}"
    print(f"XOR MATCH  xor16=0x{xor16:04X} over {len(data)} B in {len(payloads)} frames", flush=True)

    # (b) byte-parity round trip: strip the 10-byte headers from the re-serialized records
    out = bytearray()
    for i, p in enumerate(payloads):
        assert p[:4] == MAGIC, f"frame {i}: bad magic {p[:4]!r}"
        seq_field, addr = struct.unpack(">H I", p[4:10])
        assert seq_field == i, f"frame {i}: seq {seq_field} != {i}"
        assert addr == base + len(out), f"frame {i}: addr {addr:#x} != {base + len(out):#x}"
        assert 10 <= len(p) <= 10 + 1408, f"frame {i}: payload len {len(p)}"
        rec = frame(p)                                  # u32 length prefix + payload
        (rlen,) = struct.unpack(">I", rec[:4])
        assert rlen == len(p), f"frame {i}: length prefix {rlen} != {len(p)}"
        assert rec[4:] == p, f"frame {i}: record body != payload"
        out += rec[4 + 10:]                         # strip u32 length prefix AND 10-byte header
    assert bytes(out) == data, "ROUNDTRIP MISMATCH: stripped stream != input bytes"
    print(f"ROUNDTRIP OK  {len(payloads)} frames re-serialized -> {len(out)} B == input", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default="192.168.1.105", help="host address on the board-facing NIC")
    ap.add_argument("--dst", default="192.168.1.11", help="board address (top-level LOCAL_IP)")
    ap.add_argument("--port", type=int, default=8081)
    ap.add_argument("--root", default="sw/images")
    ap.add_argument("--only", default="")
    ap.add_argument("--file", default="", help="单文件模式：发送任意裸文件（配合 --addr），忽略 IMAGES")
    ap.add_argument("--addr", default="0x80000000", help="--file 的目标 DDR 地址")
    ap.add_argument("--chunk", type=int, default=1408, help="data bytes per record (must be a multiple of 32; 1408 + 10-byte header)")
    ap.add_argument("--no-end", action="store_true", help="do not send the END/xor frame")
    ap.add_argument("--restart", action="store_true",
                    help="先发一个重装帧（addr=0xFFFF_FFFF）把板内 xor/计数/verdict 清回出厂 "
                         "——用于整幅 xor 对不上时**免重烧**重来一轮")
    ap.add_argument("--repeat", type=int, default=1, help="send the whole payload N times")
    ap.add_argument("--selftest", action="store_true",
                    help="离线自检：临时非零文件走 build_frames，校验 xor 参考实现 + 字节级回环")
    a = ap.parse_args()

    if a.selftest:
        selftest()
        return

    assert a.chunk % 32 == 0, "chunk must be a multiple of 32 so every record stays 32B-aligned"

    # bind the source NIC exactly like the UDP loader (s.bind((a.src, 0))) -- create_connection's
    # source_address does the same bind before connect
    s = socket.create_connection((a.dst, a.port), timeout=5,
                                 source_address=(a.src, 0) if a.src else None)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    print(f"host {a.src} -> board {a.dst}:{a.port} (TCP)   chunk={a.chunk} B/data-record  "
          f"no rate limit (TCP)", flush=True)

    if a.restart:
        for _ in range(2):                       # 发两遍保险（重装是幂等的）；TCP 保序保达，无需 sleep
            s.sendall(frame(MAGIC + struct.pack(">H", 0xFFFF) + struct.pack(">I", 0xFFFFFFFF)))
        print("RESTART frame sent x2 (addr=0xFFFFFFFF)", flush=True)

    seq = 0
    total_pkts = 0
    total_bytes = 0
    xor = 0
    for rnd in range(a.repeat):
        n = 0
        sent = 0
        t0 = time.perf_counter()
        imgs = [(os.path.basename(a.file), int(a.addr, 0))] if a.file else IMAGES
        items = []
        for name, base in imgs:                   # UDP L80-87
            if a.only and name != a.only:
                continue
            path = a.file if a.file else os.path.join(a.root, name)
            if not os.path.exists(path):
                raise SystemExit(f"missing {path}")
            data = open(path, "rb").read()
            print(f"==> {name}: {len(data)} B @ {base:#010X}", flush=True)
            items.append((base, data))
        # xor resets per round: build_frames() starts its accumulator at 0 on every call (UDP L77)
        payloads, xor = build_frames(items, a.chunk, seq)
        for p in payloads:
            s.sendall(frame(p))                   # blast, no pacing -- TCP has our back
            n += 1
            sent += len(p) - 10
        seq += len(payloads)
        dt = time.perf_counter() - t0
        total_pkts += n
        total_bytes += sent
        print(f"round {rnd + 1}/{a.repeat}: {n} pkts in {dt:.2f}s  "
              f"({n / max(dt, 1e-9):.0f} pkt/s, {sent / max(dt, 1e-9) / 1e6:.1f} MB/s, "
              f"{sent * 8 / max(dt, 1e-9) / 1e6:.1f} Mbps)", flush=True)

    if not a.no_end:
        end = MAGIC + struct.pack(">H", 0xFFFE) + struct.pack(">I", xor & 0xFFFF)   # UDP L108
        for _ in range(2):                       # 发两遍：TCP 保证顺序与送达（UDP 版发 3 次是因为可能丢包）
            s.sendall(frame(end))
        print(f"END sent x2, expected xor16 = 0x{xor & 0xFFFF:04X}", flush=True)

    print(f"TOTAL {total_pkts} pkts / {total_bytes / 1e6:.2f} MB data", flush=True)
    print("next: the CPU leaves reset only if the board's XOR matched -- watch the UART console; "
          "silence means a mismatch, just re-run this script.", flush=True)
    s.close()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
