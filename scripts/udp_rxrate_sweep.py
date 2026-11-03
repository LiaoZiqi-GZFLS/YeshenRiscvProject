#!/usr/bin/env python3
"""udp_rxrate_sweep.py -- find the board's sustainable UDP ingestion rate.

The experiment build returns a 20-byte datagram each second carrying
   pkt_cnt / byte_cnt / last_len  (see udp_rxcount_read.py)
so we can measure, per rate point, exactly how many of the packets we injected the FPGA ingested.

Usage: python udp_rxrate_sweep.py [n_per_point] [payload_bytes]
"""
import socket
import struct
import sys
import time

n_per = int(sys.argv[1]) if len(sys.argv) > 1 else 500
size = int(sys.argv[2]) if len(sys.argv) > 2 else 1400
SRC = "192.168.1.105"
DST = ("192.168.1.11", 8080)
PORT = 8080

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((SRC, PORT))
s.settimeout(0.3)
payload = bytes((i * 7) & 0xFF for i in range(size))


def read_cnt(wait_s=4.0):
    """Wait for a fresh counter datagram and return (pkt, byte)."""
    t0 = time.perf_counter()
    while time.perf_counter() - t0 < wait_s:
        try:
            d, _ = s.recvfrom(2048)
        except socket.timeout:
            continue
        if len(d) >= 16 and d[0:3] == b"RXC":
            pkt, byt, _ln = struct.unpack(">III", d[4:16])
            return pkt, byt
    raise SystemExit("no counter datagram")


print(f"payload {size} B, {n_per} pkts per point")
for rate in [500, 1000, 2000, 4000, 8000, 16000, 32000, 0]:
    pkt0, byt0 = read_cnt()
    if rate == 0:
        t0 = time.perf_counter()
        for _ in range(n_per):
            s.sendto(payload, DST)
        dt = time.perf_counter() - t0
        label = f"blast ({n_per / dt:.0f} pkt/s actual)"
    else:
        t0 = time.perf_counter()
        for i in range(n_per):
            s.sendto(payload, DST)
            target = t0 + (i + 1) / rate
            while time.perf_counter() < target:
                pass
        dt = time.perf_counter() - t0
        label = f"{rate} pkt/s (actual {n_per / dt:.0f})"
    time.sleep(1.2)
    pkt1, byt1 = read_cnt()
    got_p, got_b = pkt1 - pkt0, byt1 - byt0
    print(f"  {label:34s} -> ingested {got_p:5d}/{n_per} pkts  {got_b/1e6:7.3f} MB  "
          f"loss {100.0 * (n_per - got_p) / n_per:5.1f}%  ingest {got_b / dt / 1e6:6.1f} MB/s")
