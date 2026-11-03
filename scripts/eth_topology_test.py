#!/usr/bin/env python3
"""eth_topology_test.py -- 判定"板子到底接在主机哪个网卡上"。

背景：主机有两个可能是板子的口
  ifIndex 5  = 192.168.1.105/24   （板子也配了 192.168.1.110/24，同段）
  ifIndex 27 = 10.16.147.67/17    （板子也配了 10.16.147.211/17，同段）
板子两个 IP 都在！所以"哪个口接的线"必须用**板子自发广播**、看哪个口收到来定，不能靠猜。

做法：让板子 ping 主机（迫使板子发 ARP 广播），同时量两个口的 RecepcionBroadcastPackets 增量。
判据：**增量非 0 的那一口 = 板子的链路**。
"""
import re
import subprocess
import sys
import time

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM7"
BAUD = sys.argv[2] if len(sys.argv) > 2 else "115200"
IDXS = [5, 27]
TARGET = sys.argv[3] if len(sys.argv) > 3 else "192.168.1.105"


def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, errors="replace").stdout


def stats(idx):
    ps = (f"(Get-NetAdapter -InterfaceIndex {idx} | Get-NetAdapterStatistics) | "
          "Select-Object ReceivedBroadcastPackets,ReceivedUnicastPackets,ReceivedBytes | "
          "ConvertTo-Csv -NoTypeInformation")
    out = sh(["powershell", "-NoProfile", "-Command", ps])
    rows = [l for l in out.splitlines() if re.match(r'^"\d', l)]
    v = [int(x.strip('"')) for x in rows[0].split(",")]
    return v


def name(idx):
    out = sh(["powershell", "-NoProfile", "-Command",
              f"(Get-NetAdapter -InterfaceIndex {idx}).Name"])
    return out.strip()


print("== 各口描述 ==")
for i in IDXS:
    print(f"  ifIndex {i}: {name(i)}")

print(f"== 让板子 ping {TARGET}（板子发 ARP 广播）==")
pre = {i: stats(i) for i in IDXS}
out = sh([sys.executable, "-u", "scripts/guest_cmd.py", PORT, BAUD,
          f"ping -c 6 -W 1 {TARGET}"])
txt = re.sub(r"[^\x20-\x7E\n]", "", out)
print("  board ping:", [l for l in txt.splitlines() if "packet" in l or "loss" in l][-1:] or "?")
time.sleep(1.5)
post = {i: stats(i) for i in IDXS}
print("== 主机两口增量（板子广播到哪个口）==")
for i in IDXS:
    print(f"  ifIndex {i}: recv_bcast {pre[i][0]} -> {post[i][0]} ({post[i][0]-pre[i][0]:+d})"
          f"  recv_ucast ({post[i][1]-pre[i][1]:+d})  recv_bytes ({post[i][2]-pre[i][2]:+d})")

print("== 主机邻居表（找板子 MAC 02-00-00-00-00-01）==")
print(re.sub(r"[^\x20-\x7E\n]", "",
             sh(["powershell", "-NoProfile", "-Command",
                 "Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | "
                 "Where-Object {$_.LinkLayerAddress -like '02-00-00*' -or $_.IPAddress -like '192.168.1.11*' "
                 "-or $_.IPAddress -like '10.16.147.21*'} | "
                 "Select-Object IPAddress,State,LinkLayerAddress,InterfaceIndex | Format-Table -AutoSize"])))
