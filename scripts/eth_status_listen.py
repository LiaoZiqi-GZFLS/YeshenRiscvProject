#!/usr/bin/env python3
"""eth_status_listen.py -- 听板子的反向信道状态帧（spec §4.3 第 1 段）。

板子（`eth_mac_wrapper.v` 末尾的 TX FSM）会周期性广播
    'N','X','B',0x01 | rxBytes(u32 BE)          # 8 字节载荷
其中 `rxBytes` = EthLoader 已计入的**数据字节数**（去重后）。

用法： python eth_status_listen.py [listen_s] [host_ip]
判据（第 1 段）：本脚本能持续收到状态帧、且 `rxBytes` 随灌包单调增长 ⇒ 回信道已通。
"""
import socket
import struct
import sys
import time

listen_s = float(sys.argv[1]) if len(sys.argv) > 1 else 20.0
host_ip = sys.argv[2] if len(sys.argv) > 2 else "192.168.1.105"
PORT = 8080

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((host_ip, PORT))
s.settimeout(0.5)
print(f"listening {host_ip}:{PORT} for {listen_s:g}s", flush=True)

t0 = time.perf_counter()
n = 0
last = None
while time.perf_counter() - t0 < listen_s:
    try:
        data, addr = s.recvfrom(2048)
    except socket.timeout:
        continue
    n += 1
    if len(data) >= 8 and data[0:3] == b"NXB":
        rx = struct.unpack(">I", data[4:8])[0]
        delta = "" if last is None else f"  (+{rx - last})"
        print(f"  #{n} from {addr[0]}  rxBytes={rx}{delta}", flush=True)
        last = rx
    else:
        print(f"  #{n} from {addr[0]}  (other) {data[:16]!r}", flush=True)

if last is None:
    print(f"[FAIL] 没有收到任何 NXB 状态帧（共 {n} 个报文）", flush=True)
    sys.exit(1)
print(f"[OK] 收到状态帧 {n} 个，最后 rxBytes={last}", flush=True)
