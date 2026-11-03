#!/usr/bin/env python3
"""eth_iface_hunt.py -- 逐个候选网卡做"板子 RX 有没有动"的判据，找出板子真正的链路。

之前所有 RX 测试都走 ifIndex 27（目标 10.16.147.211）；但主机路由表里
`192.168.1.0/24 -> ifIndex 5`，而板子也配了 `192.168.1.110/24`。
**ifIndex 5 从没被发过包** —— 这可能就是一直 +0 的原因。

对每个 (ifIndex, target)：
  · 记板卡 GMII rxBytes 基线
  · 主机 ping target（按路由会从该 ifIndex 出去）；记该 ifIndex 的 SentBroadcastPackets 增量
  · 复测板卡 GMII rxBytes
判据：**rxBytes 动的那一组 = 板子真正的链路**。
"""
import re
import subprocess
import sys
import time

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM7"
BAUD = sys.argv[2] if len(sys.argv) > 2 else "115200"
CASES = [(5, "192.168.1.110"), (27, "10.16.147.211")]


def sh(c):
    return subprocess.run(c, capture_output=True, text=True, errors="replace").stdout


def ps(c):
    return sh(["powershell", "-NoProfile", "-Command", c]).strip()


def board_read():
    cmd = "printf 'GM %s\\n' $(devmem 0xF000B010)"
    out = sh([sys.executable, "-u", "scripts/guest_cmd.py", PORT, BAUD, cmd])
    m = re.search(r"GM\s+0x([0-9A-Fa-f]{8})", out)
    if not m:
        print("!! 解析失败:\n", out[-300:])
        return None
    w4 = int(m.group(1), 16)
    return w4 & 0xFFFF


b_start = board_read()
print(f"起始 GMII rxBytes = {b_start}")

for idx, target in CASES:
    print(f"---- ifIndex {idx} -> {target} ----")
    sb0 = ps(f"(Get-NetAdapter -InterfaceIndex {idx} | Get-NetAdapterStatistics).SentBroadcastPackets")
    b0 = board_read()
    out = sh(["ping", "-n", "5", "-w", "500", target])
    lost = re.findall(r"([0-9]+)%", re.sub(r"[^\x20-\x7E\n%]", "", out))
    time.sleep(1.2)
    b1 = board_read()
    sb1 = ps(f"(Get-NetAdapter -InterfaceIndex {idx} | Get-NetAdapterStatistics).SentBroadcastPackets")
    print(f"  host SentBcast {sb0} -> {sb1}  ({int(sb1)-int(sb0):+d})")
    print(f"  board GMII rxBytes {b0} -> {b1}  ({b1-b0:+d})   ping loss={lost}")
    print("  => 命中！" if b1 > b0 else "  => 没动")

print(f"结束 GMII rxBytes = {board_read()}  (起始 {b_start})")
print("== 板子缓存（谁可达）==")
print(re.sub(r"[^\x20-\x7E\n]", "", sh([sys.executable, "-u", "scripts/guest_cmd.py", PORT, BAUD,
                                         "ip neigh show"])))
