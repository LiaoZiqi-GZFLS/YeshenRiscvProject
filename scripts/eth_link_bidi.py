#!/usr/bin/env python3
"""eth_link_bidi.py -- 双向连通性判据（板上/板上各自发起），用**方向正确**的主机计数器。

⚠️ 语义（之前用反过一次）：
  Get-NetAdapterStatistics.ReceivedBroadcastPackets = **主机收到**的广播（= 板子发出的）
  Get-NetAdapterStatistics.SentBroadcastPackets     = **主机发出**的广播（= 板子应收到的）

A) 板→主机：板上 ping 主机；主机 Received* 涨 => 板子 TX 到线上且主机收到
B) 主机→板：主机 flush 邻居 + ping 板；板 GMII rxBytes / netdev rx_packets 涨 => 板子 RX 收到
"""
import re
import subprocess
import sys
import time

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM7"
BAUD = sys.argv[2] if len(sys.argv) > 2 else "115200"
IFIDX = sys.argv[3] if len(sys.argv) > 3 else "27"
HOSTIP = sys.argv[4] if len(sys.argv) > 4 else "10.16.147.67"
BOARD = sys.argv[5] if len(sys.argv) > 5 else "10.16.147.211"


def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, errors="replace").stdout


def host_stats():
    ps = (f"(Get-NetAdapter -InterfaceIndex {IFIDX} | Get-NetAdapterStatistics) | "
          "Select-Object ReceivedBroadcastPackets,SentBroadcastPackets,ReceivedUnicastPackets,"
          "SentUnicastPackets,ReceivedBytes,SentBytes | ConvertTo-Csv -NoTypeInformation")
    out = sh(["powershell", "-NoProfile", "-Command", ps])
    rows = [l for l in out.splitlines() if re.match(r'^"\d', l)]
    v = [int(x.strip('"')) for x in rows[0].split(",")]
    return dict(rb=v[0], sb=v[1], ru=v[2], su=v[3], rby=v[4], sby=v[5])


def board_read():
    cmd = ("cat /sys/class/net/eth0/statistics/rx_packets "
           "/sys/class/net/eth0/statistics/tx_packets; "
           "printf 'GM %s\\n' $(devmem 0xF000B010)")
    out = sh([sys.executable, "-u", "scripts/guest_cmd.py", PORT, BAUD, cmd])
    nums = re.findall(r"^\s*(\d+)\s*$", out, re.M)
    m = re.search(r"GM\s+0x([0-9A-Fa-f]{8})", out)
    if len(nums) < 2 or not m:
        print("!! 板上读数解析失败：\n", out[-400:])
        return None
    w4 = int(m.group(1), 16)
    return dict(rxp=int(nums[0]), txp=int(nums[1]), gmii_rx=w4 & 0xFFFF, gmii_tx=(w4 >> 16) & 0xFFFF)


def d(a, b, k):
    return b[k] - a[k]


print("======== A) 板 -> 主机 ========")
h0 = host_stats()
print(f"  host before: recv_bcast={h0['rb']} recv_ucast={h0['ru']} recv_bytes={h0['rby']}")
out = sh([sys.executable, "-u", "scripts/guest_cmd.py", PORT, BAUD,
          f"ping -c 4 -W 1 {HOSTIP}"])
txt = re.sub(r"[^\x20-\x7E\n]", "", out)
print("  board ping ->", [l for l in txt.splitlines() if "packet" in l or "loss" in l][-1:] or "?")
time.sleep(1)
h1 = host_stats()
print(f"  host after : recv_bcast={h1['rb']} recv_ucast={h1['ru']} recv_bytes={h1['rby']}")
print(f"  DELTA: recv_bcast={d(h0,h1,'rb'):+d} recv_ucast={d(h0,h1,'ru'):+d} recv_bytes={d(h0,h1,'rby'):+d}")
print("  => 板 TX 到线上" if d(h0, h1, "rb") + d(h0, h1, "ru") > 0 else "  => 主机什么也没收到（板 TX 或链路问题）")

print("======== B) 主机 -> 板 ========")
b0 = board_read()
if b0 is None:
    sys.exit(1)
print(f"  board before: netdev rx_packets={b0['rxp']} tx_packets={b0['txp']} GMII rxBytes={b0['gmii_rx']}")
h0 = host_stats()
sh(["powershell", "-NoProfile", "-Command",
    f"Remove-NetNeighbor -IPAddress {BOARD} -Confirm:$false -ErrorAction SilentlyContinue"])
for _ in range(6):
    sh(["ping", "-n", "1", "-w", "300", BOARD])
h1 = host_stats()
time.sleep(1)
b1 = board_read()
print(f"  host sent: bcast={d(h0,h1,'sb'):+d} ucast={d(h0,h1,'su'):+d} bytes={d(h0,h1,'sby'):+d}")
print(f"  board after : netdev rx_packets={b1['rxp']} GMII rxBytes={b1['gmii_rx']}")
print(f"  DELTA: netdev rx_packets={d(b0,b1,'rxp'):+d} GMII rxBytes={d(b0,b1,'gmii_rx'):+d}")
print("  => 板 RX 收到" if d(b0, b1, "gmii_rx") > 0 else "  => 板 GMII 引脚什么都没收到（RX 断）")

print("======== 主机邻居状态 ========")
print(re.sub(r"[^\x20-\x7E\n]", "",
             sh(["powershell", "-NoProfile", "-Command",
                 f"Get-NetNeighbor -IPAddress {BOARD} -ErrorAction SilentlyContinue | "
                 "Select-Object IPAddress,State,LinkLayerAddress | Format-Table -AutoSize"])))
