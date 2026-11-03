#!/usr/bin/env python3
"""udp_flood_test.py -- measure how fast we can push UDP at the board (link ceiling for a
UDP-based loader).

CAVEAT: the vendor 2_11 demo is a PURE SENDER (fixed 20-byte banner once a second).  It does not
echo and exposes no receive counter, so this measures the HOST->board link rate, NOT the FPGA's
ingestion rate.  Board-side ingestion needs a counter/echo we do not have yet.

Usage: python udp_flood_test.py [n_pkts] [payload_bytes] [dst_ip]
"""
import socket
import sys
import time

n = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
size = int(sys.argv[2]) if len(sys.argv) > 2 else 1400
dst_ip = sys.argv[3] if len(sys.argv) > 3 else "192.168.1.11"
src_ip = "192.168.1.105"
PORT = 8080

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((src_ip, 0))
s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 * 1024 * 1024)
payload = bytes((i * 7) & 0xFF for i in range(size))

# warm-up so the first-packet ARP/neighbour lookup is not counted
s.sendto(payload, (dst_ip, PORT))
time.sleep(0.2)

sent = 0
err = None
t0 = time.perf_counter()
for i in range(n):
    try:
        s.sendto(payload, (dst_ip, PORT))
        sent += 1
    except OSError as e:
        err = f"send error at pkt {i}: {e}"
        break
dt = time.perf_counter() - t0

mb = sent * size / 1e6
print(f"payload {size} B -> {dst_ip}:{PORT}")
print(f"sent {sent}/{n} pkts = {mb:.2f} MB in {dt:.3f} s")
print(f"  => {mb / dt:.1f} MB/s   {sent / dt:.0f} pkt/s   ({sent * size * 8 / dt / 1e6:.0f} Mbit/s)")
if err:
    print("  " + err)
print(f"  projected for 8.73 MB: {8.73 / (mb / dt):.1f} s" if mb > 0 else "")
