#!/usr/bin/env python3
"""eth_arp_relearn.py -- 先修好主机的 ARP 缓存（它把板子 IP 缓存成了别的 MAC），再测 RX。

为什么必须先修：主机 arp 表里 `10.16.147.211 -> 00-00-5E-00-01-01`，而板子 MAC 是
`02:00:00:00:00:01`（DT 固定）。**交换机**只会把发往 00:00:5E:... 的单播送到别人口上
=> 之前"主机 ping 板子"的帧根本没到板子（也不是广播）。所以要先让主机学到正确 MAC。

修法：板子 ping 主机的 10.16.147.67 => 板子发**广播** ARP 请求，源字段
       = 10.16.147.211 / 02:00:00:00:00:01 => 主机据此更新缓存（无需板子 RX）。

然后：
  ① 主机缓存里的板子 MAC 是否变成 02-00-00-00-00-01
  ② 主机再 ping 板子（此时是**到正确 MAC 的单播**，交换机会送到板子）
  ③ 板卡 GMII rxBytes 是否动 => 这是"板子 RX 到底通不通"的最终判据
"""
import re
import subprocess
import sys
import time

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM7"
BAUD = sys.argv[2] if len(sys.argv) > 2 else "115200"
IFIDX = "27"
BOARD = "10.16.147.211"
HOST = "10.16.147.67"


def sh(c):
    return subprocess.run(c, capture_output=True, text=True, errors="replace").stdout


def ps(cmd):
    return sh(["powershell", "-NoProfile", "-Command", cmd])


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


print("== 0) 权限 & 当前缓存 ==")
print(ps("([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent())"
         ".IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)"))
print(re.sub(r"[^\x20-\x7E\n]", "", ps(
    f"Get-NetNeighbor -IPAddress {BOARD} -ErrorAction SilentlyContinue | "
    "Select-Object IPAddress,State,LinkLayerAddress,InterfaceIndex | Format-Table -AutoSize")))

print(f"== 1) 板子 ping {HOST}（发广播 ARP，逼主机学正确 MAC）==")
out = sh([sys.executable, "-u", "scripts/guest_cmd.py", PORT, BAUD, f"ping -c 4 -W 1 {HOST}"])
txt = re.sub(r"[^\x20-\x7E\n]", "", out)
print("  ", [l for l in txt.splitlines() if "packet" in l or "loss" in l][-1:] or "?")
time.sleep(1.5)
print("== 2) 主机缓存现在是什么 ==")
print(re.sub(r"[^\x20-\x7E\n]", "", ps(
    f"Get-NetNeighbor -IPAddress {BOARD} -ErrorAction SilentlyContinue | "
    "Select-Object IPAddress,State,LinkLayerAddress | Format-Table -AutoSize")))

print(f"== 3) 板子侧基线 ==")
b0 = board_read()
print("  ", b0)

print(f"== 4) 主机 ping {BOARD}（到正确 MAC 的单播）==")
h0 = ps(f"(Get-NetAdapter -InterfaceIndex {IFIDX} | Get-NetAdapterStatistics).SentBroadcastPackets")
for _ in range(8):
    sh(["ping", "-n", "1", "-w", "300", BOARD])
h1 = ps(f"(Get-NetAdapter -InterfaceIndex {IFIDX} | Get-NetAdapterStatistics).SentBroadcastPackets")
time.sleep(1.5)
b1 = board_read()
print("  ", b1)
print(f"== 5) DELTA: GMII rxBytes={b1['gmii_rx']-b0['gmii_rx']:+d}  netdev rx_packets={b1['rxpk']-b0['rxpk']:+d}"
      f"  (host sent_bcast {h0.strip()}->{h1.strip()})")
print("== 6) 主机缓存（ping 之后）==")
print(re.sub(r"[^\x20-\x7E\n]", "", ps(
    f"Get-NetNeighbor -IPAddress {BOARD} -ErrorAction SilentlyContinue | "
    "Select-Object IPAddress,State,LinkLayerAddress | Format-Table -AutoSize")))
