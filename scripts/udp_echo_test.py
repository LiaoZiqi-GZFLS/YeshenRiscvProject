#!/usr/bin/env python3
"""eth_demo_link_test.py -- verify the vendor 2_11_ethernet_test demo over UDP.

From eth_udp_test.v:
    LOCAL_MAC = 11:11:11:11:11:11   LOCAL_IP = 192.168.1.110   LOCL_PORT = 8080
    DEST_IP   = 192.168.1.105       DEST_PORT = 8080
and its FSM is ARP_REQ -> ARP_WAIT -> ... -> SEND -> WAIT(1s) -> loop.  So the board is the
SENDER: it ARPs for 192.168.1.105 and pushes a UDP datagram there about once a second.

Host side: put the board-facing NIC on 192.168.1.105/24 and just LISTEN -- receiving anything at
all proves RGMII RX + ARP + TX.  We also send a probe and report whether it comes back, which
additionally exercises the board's receive path.

Usage: python eth_demo_link_test.py [listen_s] [iface_ip] [board_ip]
"""
import socket
import sys
import time

listen_s = float(sys.argv[1]) if len(sys.argv) > 1 else 12.0
iface_ip = sys.argv[2] if len(sys.argv) > 2 else "192.168.1.105"
board_ip = sys.argv[3] if len(sys.argv) > 3 else "192.168.1.110"
PORT = 8080

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((iface_ip, PORT))
s.settimeout(0.5)
print(f"listening on {iface_ip}:{PORT} for the board ({board_ip}) for {listen_s:.0f}s", flush=True)

probe = b"NAXMINI-ETH-TEST-0123456789ABCDEF"
s.sendto(probe, (board_ip, PORT))
print(f"-> sent probe {len(probe)} B to {board_ip}:{PORT}", flush=True)

n = 0
probe_echo = 0
t0 = time.perf_counter()
last_report = 0.0
while time.perf_counter() - t0 < listen_s:
    try:
        data, addr = s.recvfrom(4096)
    except socket.timeout:
        continue
    n += 1
    if data == probe:
        probe_echo += 1
    if n <= 5 or time.perf_counter() - last_report > 3.0:
        last_report = time.perf_counter()
        print(f"  #{n} from {addr[0]}:{addr[1]}  len={len(data)}  "
              f"echo={data == probe}  head={data[:48]!r}", flush=True)

print(f"RESULT: board datagrams received = {n}; byte-identical echo of our probe = {probe_echo}")
