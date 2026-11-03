#!/usr/bin/env python3
"""eth_unique_ip_rx.py -- 用"全新未用过的 IP"绕开所有 ARP 缓存/冲突问题，测板子 RX。

为什么：`10.16.147.211` 的主机缓存被别的设备（MAC 00-00-5E-00-01-01）占着 ⇒ 主机发单播发错口。
换一个板子独占的新 IP（主机里**没有任何缓存**）⇒ 主机会**真的广播** ARP ⇒ 广播经交换机必到板子
（只要板子 RX 是活的）⇒ 板卡 GMII rxBytes 动。

用主机 SentBroadcastPackets 增量确认"主机确实发了广播"（激励非零），否则结论作废。
"""
import re
import subprocess
import sys
import time

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM7"
BAUD = sys.argv[2] if len(sys.argv) > 2 else "115200"
IFIDX = "27"
NEWIP = sys.argv[3] if len(sys.argv) > 3 else "10.16.199.9"


def sh(c):
    return subprocess.run(c, capture_output=True, text=True, errors="replace").stdout


def ps(c):
    return sh(["powershell", "-NoProfile", "-Command", c]).strip()


def board_read():
    cmd = ("printf 'GM %s\\n' $(devmem 0xF000B010); "
           "cat /sys/class/net/eth0/statistics/rx_packets")
    out = sh([sys.executable, "-u", "scripts/guest_cmd.py", PORT, BAUD, cmd])
    m = re.search(r"GM\s+0x([0-9A-Fa-f]{8})", out)
    n = re.findall(r"^\s*(\d+)\s*$", out, re.M)
    if not m or not n:
        print("!! 解析失败:\n", out[-400:])
        return None
    w4 = int(m.group(1), 16)
    return dict(gmii_rx=w4 & 0xFFFF, rxpk=int(n[0]))


print(f"== 1) 板子加新 IP {NEWIP} ==")
out = sh([sys.executable, "-u", "scripts/guest_cmd.py", PORT, BAUD,
          f"ip addr add {NEWIP}/17 dev eth0; ip addr show eth0 | grep inet"])
print(re.sub(r"[^\x20-\x7E\n]", "", out))

print(f"== 2) 主机侧：确认没有 {NEWIP} 的缓存 ==")
print(re.sub(r"[^\x20-\x7E\n]", "", ps(
    f"Get-NetNeighbor -IPAddress {NEWIP} -ErrorAction SilentlyContinue | "
    "Select-Object IPAddress,State,LinkLayerAddress | Format-Table -AutoSize")) or "  (无缓存)")

b0 = board_read()
sb0 = ps(f"(Get-NetAdapter -InterfaceIndex {IFIDX} | Get-NetAdapterStatistics).SentBroadcastPackets")
print(f"== 3) 基线 board={b0}  host SentBcast={sb0} ==")

print(f"== 4) 主机 ping {NEWIP} ==")
ping_out = sh(["ping", "-n", "4", "-w", "500", NEWIP])
print(re.sub(r"[^\x20-\x7E\n]", "", ping_out))
time.sleep(1.5)
b1 = board_read()
sb1 = ps(f"(Get-NetAdapter -InterfaceIndex {IFIDX} | Get-NetAdapterStatistics).SentBroadcastPackets")
print(f"== 5) 结果 board={b1}  host SentBcast={sb1} ==")
print(f"   host 发广播 = {int(sb1)-int(sb0):+d}   （0 => 激励无效，结论作废）")
print(f"   GMII rxBytes = {b1['gmii_rx']-b0['gmii_rx']:+d}   netdev rx_packets = {b1['rxpk']-b0['rxpk']:+d}")
print("== 6) 主机缓存（ping 后）==")
print(re.sub(r"[^\x20-\x7E\n]", "", ps(
    f"Get-NetNeighbor -IPAddress {NEWIP} -ErrorAction SilentlyContinue | "
    "Select-Object IPAddress,State,LinkLayerAddress | Format-Table -AutoSize")) or "  (仍无缓存 => 板子没回)")
