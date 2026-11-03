#!/usr/bin/env python3
"""udp_rxcount_read.py -- read the board's RX byte/packet counters.

The experiment build of the vendor 2_11 demo returns a 20-byte datagram once a second whose
payload is:  'R','X','C',0x01 | pkt_cnt(be32) | byte_cnt(be32) | last_len(be32) | 'E','N','D',0x0A

Usage: python udp_rxcount_read.py [listen_s] [src_ip] [board_ip]
"""
import socket
import struct
import sys
import time

listen_s = float(sys.argv[1]) if len(sys.argv) > 1 else 6.0
src_ip = sys.argv[2] if len(sys.argv) > 2 else "192.168.1.105"
board_ip = sys.argv[3] if len(sys.argv) > 3 else "192.168.1.11"
PORT = 8080

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((src_ip, PORT))
s.settimeout(0.5)

t0 = time.perf_counter()
last = None
n = 0
while time.perf_counter() - t0 < listen_s:
    try:
        data, addr = s.recvfrom(2048)
    except socket.timeout:
        continue
    n += 1
    if len(data) >= 20 and data[0:3] == b"RXC":
        pkt, byt, ln = struct.unpack(">III", data[4:16])
        last = (pkt, byt, ln)
        print(f"  #{n} from {addr[0]}  pkt_cnt={pkt}  byte_cnt={byt}  last_len={ln}", flush=True)
    else:
        print(f"  #{n} from {addr[0]}  (banner) {data[:24]!r}", flush=True)
if last:
    print(f"LAST: pkt_cnt={last[0]} byte_cnt={last[1]} last_len={last[2]}   (datagrams seen {n})")
else:
    print(f"NO counter datagram (datagrams seen {n})")
