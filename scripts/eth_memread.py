#!/usr/bin/env python3
"""eth_memread.py -- host client for the board's H2 hardware memory-read service.

Protocol (frozen in docs/superpowers/specs/2026-10-28-eth-memread-service-design.md)
  request  : UDP -> BOARD:22850, 16 B payload, big-endian
             'YMEM' | addr(u32, CPU physical) | len(u32) | seq(u32)
  response : one or more UDP datagrams, each = 16 B header + <=1400 B payload
             'YMEM' | seq(u32) | off(u32) | len(u16) | flags(u16, bit0 = last)

Host-side rules that matter on this board:
  * the service only replies while the board's netdev is down and ETH_EN=1
    (VIDEO+0x094 bit0); see the spec for the enable/disable sequence.
  * one request is served at a time; the reply comes back to the requester's
    source port, so bind before sending.
  * frames can arrive out of order in principle; reassemble by `off`, stop at
    `last`, and fail loudly on holes/short reads instead of writing a short file.

Example
  python3 scripts/eth_memread.py --board 192.168.1.110 \\
      --addr 0x90000000 --len 819200 --out frame_rgb565.bin
"""
import argparse
import socket
import struct
import sys
import time

MAGIC = b"YMEM"
PORT = 22850
HDR = 16
MAX_PAY = 1400


def build_request(addr: int, length: int, seq: int) -> bytes:
    return MAGIC + struct.pack(">III", addr & 0xFFFFFFFF, length & 0xFFFFFFFF, seq & 0xFFFFFFFF)


def parse_frame(pkt: bytes):
    if len(pkt) < HDR or pkt[:4] != MAGIC:
        return None
    seq, off, ln, flags = struct.unpack(">IIHH", pkt[4:HDR])
    payload = pkt[HDR:HDR + ln]
    if len(payload) != ln:
        return None
    return seq, off, ln, flags, payload


def read_mem(board: str, addr: int, length: int, timeout: float = 0.30,
             retries: int = 5, verbose: bool = True) -> bytes:
    seq = int(time.time()) & 0xFFFFFFFF
    req = build_request(addr, length, seq)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("", 0))                       # replies come back to this port
    sock.settimeout(timeout)

    buf = bytearray(length)
    got = bytearray(length)                  # 1 = byte covered
    covered = 0
    last_seen = False

    for attempt in range(retries):
        sock.sendto(req, (board, PORT))
        deadline = time.time() + max(timeout, 1.0)
        while time.time() < deadline and not last_seen:
            try:
                pkt, peer = sock.recvfrom(2048)
            except socket.timeout:
                break
            fr = parse_frame(pkt)
            if fr is None:
                continue
            fseq, off, ln, flags, payload = fr
            if fseq != seq:
                continue                     # stale reply from an earlier request
            if off + ln > length:
                raise SystemExit(f"reply overruns the request: off={off} len={ln} > {length}")
            buf[off:off + ln] = payload
            for i in range(off, off + ln):
                if not got[i]:
                    got[i] = 1
                    covered += 1
            if flags & 1:
                last_seen = True
            if verbose:
                sys.stderr.write("\r  %.1f%% (%d/%d B)" % (100.0 * covered / length, covered, length))
                sys.stderr.flush()
        if last_seen and covered >= length:
            break
        if verbose:
            sys.stderr.write("\n  retry %d/%d (covered %d/%d)\n"
                             % (attempt + 1, retries, covered, length))

    sock.close()
    if verbose:
        sys.stderr.write("\n")
    if covered != length:
        raise SystemExit(f"incomplete: {covered}/{length} bytes (last={last_seen})")
    return bytes(buf)


def main() -> int:
    ap = argparse.ArgumentParser(description="H2 hardware memory-read client")
    ap.add_argument("--board", required=True, help="board IPv4 (service MY_IP, default 192.168.1.110)")
    ap.add_argument("--addr", required=True, help="CPU physical address, e.g. 0x90000000")
    ap.add_argument("--len", required=True, help="bytes to read")
    ap.add_argument("--out", help="write the bytes here (default: summary only)")
    ap.add_argument("--timeout", type=float, default=0.30, help="per-attempt socket timeout (s)")
    ap.add_argument("--retries", type=int, default=5)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    addr = int(args.addr, 0)
    length = int(args.len, 0)
    if length <= 0:
        raise SystemExit("--len must be positive")

    t0 = time.time()
    data = read_mem(args.board, addr, length, args.timeout, args.retries, not args.quiet)
    dt = time.time() - t0
    if args.out:
        with open(args.out, "wb") as f:
            f.write(data)
    print("read %d bytes from 0x%08X in %.3f s (%.1f kB/s)"
          % (length, addr, dt, length / 1024.0 / max(dt, 1e-9)))
    if args.out:
        print("wrote %s" % args.out)
    else:
        print("first 32 B: " + data[:32].hex(" "))
    return 0


if __name__ == "__main__":
    sys.exit(main())
