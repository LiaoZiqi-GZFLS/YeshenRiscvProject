#!/usr/bin/env python3
"""eth_udp_e2e.py -- 带载荷的数据面判据（两种节奏），并把"丢在哪"分开。

判据（都读**板内**计数，与主机防火墙无关）：
  1) /proc/net/snmp 的 `Udp: InDatagrams`  —— 真正进了 UDP 层的载荷
  2) /sys/class/net/eth0/statistics/{rx_packets,rx_dropped,rx_errors}  —— 驱动层收支
两种节奏各打一轮：
  · burst  ：50 包背靠背（易撞满 2 个 rx 槽）
  · paced  ：20 包、包间 50ms
判读：
  · paced 接近全收 ⇒ 数据面是通的，burst 丢包 = 缓冲/中断处理速度（已知的架构限制）
  · paced 也几乎全丢  ⇒ 数据面真有问题

用法：python -u scripts/eth_udp_e2e.py [COM] [BAUD] [板IP]
"""
import re
import socket
import subprocess
import sys
import time

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM7"
BAUD = sys.argv[2] if len(sys.argv) > 2 else "115200"
BOARD = sys.argv[3] if len(sys.argv) > 3 else "192.168.1.110"
DPORT = 9999


def board_probe():
    # ⚠️ 命令**必须短**：串口控制台偶发坏字节（实测 `statistics` 被写成 `statistiistics`），
    #    长命令一旦坏一个字节就会把 shell 留在 PS2 续行、后续全乱。所以只读一行 `grep eth0 /proc/net/dev`。
    #    /proc/net/dev 的 eth0 行：rx_bytes rx_packets rx_errs rx_drop ... tx_bytes tx_packets ...
    cmd = "grep eth0 /proc/net/dev"
    out = subprocess.run([sys.executable, "-u", "scripts/guest_cmd.py", PORT, BAUD, cmd],
                         capture_output=True, text=True, encoding="utf-8", errors="replace").stdout
    m = re.search(r"eth0:\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+\s+\d+\s+\d+\s+\d+\s+(\d+)\s+(\d+)", out)
    if not m:
        print("!! /proc/net/dev 解析失败:\n", out[-400:])
        return None
    rx_b, rx_p, rx_e, rx_d, tx_b, tx_p = (int(x) for x in m.groups())
    return dict(rxp=rx_p, drop=rx_d, err=rx_e, txp=tx_p)


def send(n, gap):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    ok = 0
    for i in range(n):
        try:
            s.sendto(bytes([0x40 + (i & 0x3F)]) * 64, (BOARD, DPORT))
            ok += 1
        except Exception as e:
            print("send fail:", e)
            break
        if gap:
            time.sleep(gap)
    s.close()
    return ok


for label, n, gap in (("burst", 50, 0.0), ("paced", 20, 0.05)):
    b0 = board_probe()
    if b0 is None:
        sys.exit(1)
    sent = send(n, gap)
    time.sleep(1.5)
    b1 = board_probe()
    print(f"== {label}: 发 {sent} 包（间隔 {int(gap*1000)}ms）==")
    print(f"   netdev rx_packets {b0['rxp']} -> {b1['rxp']}  ({b1['rxp']-b0['rxp']:+d})"
          f"   rx_dropped {b1['drop']-b0['drop']:+d}   rx_errors {b1['err']-b0['err']:+d}"
          f"   tx_packets {b1['txp']-b0['txp']:+d}")
