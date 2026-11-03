#!/usr/bin/env python3
"""eth_tx_probe.py -- 判"板子到底发没发"以及"主机那一侧到底收没收到"。

背景：板子接在主机的 ifIndex 5（192.168.1.105 <-板子-> 192.168.1.110）。
      A) 板子 ping 主机 => 板子会发 ARP 请求（广播）。
      判据：
        · 板卡 tx_packets / GMII txBytes 涨 => **板子确实在发**（MAC/datapath 出得去）
        · 主机 ifIndex 5 的 Received* 涨   => **板上发的东西到了主机**（PHY/线缆/对端口 通）
      两者一对照就能把"板子没发" 与 "发了但没到" 分开。
"""
import re
import subprocess
import sys
import time

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM7"
BAUD = sys.argv[2] if len(sys.argv) > 2 else "115200"
IFIDX = sys.argv[3] if len(sys.argv) > 3 else "5"
HOSTIP = sys.argv[4] if len(sys.argv) > 4 else "192.168.1.105"


def sh(c):
    return subprocess.run(c, capture_output=True, text=True, errors="replace").stdout


def ps(c):
    return sh(["powershell", "-NoProfile", "-Command", c]).strip()


def board_read():
    cmd = ("cat /sys/class/net/eth0/statistics/tx_packets /sys/class/net/eth0/statistics/rx_packets; "
           "printf 'GM %s\\n' $(devmem 0xF000B010)")
    out = sh([sys.executable, "-u", "scripts/guest_cmd.py", PORT, BAUD, cmd])
    m = re.search(r"GM\s+0x([0-9A-Fa-f]{8})", out)
    n = re.findall(r"^\s*(\d+)\s*$", out, re.M)
    if not m or len(n) < 2:
        print("!! 解析失败:\n", out[-300:])
        return None
    w4 = int(m.group(1), 16)
    return dict(txp=int(n[0]), rxp=int(n[1]), gmii_tx=(w4 >> 16) & 0xFFFF, gmii_rx=w4 & 0xFFFF)


def hstats(idx):
    o = ps(f"(Get-NetAdapter -InterfaceIndex {idx} | Get-NetAdapterStatistics) | "
           "Select-Object ReceivedBroadcastPackets,ReceivedUnicastPackets,ReceivedBytes,"
           "SentBroadcastPackets,SentBytes | ConvertTo-Csv -NoTypeInformation")
    rows = [l for l in o.splitlines() if re.match(r'^"\d', l)]
    v = [int(x.strip('"')) for x in rows[0].split(",")]
    return dict(rcb=v[0], ruc=v[1], rby=v[2], sbc=v[3], sby=v[4])


print(f"== 主机 ifIndex {IFIDX} 累计（看这个口 RX 到底活没活过）==")
h = hstats(IFIDX)
print("  ", h)

b0 = board_read()
print(f"== 板卡基线: {b0} ==")

print(f"== 板子 ping {HOSTIP} ==")
out = sh([sys.executable, "-u", "scripts/guest_cmd.py", PORT, BAUD, f"ping -c 5 -W 1 {HOSTIP}"])
txt = re.sub(r"[^\x20-\x7E\n]", "", out)
print("  ", [l for l in txt.splitlines() if "packet" in l or "loss" in l][-1:] or "?")
time.sleep(1.5)
b1 = board_read()
h1 = hstats(IFIDX)
print(f"== 板卡: tx_packets {b0['txp']}->{b1['txp']} ({b1['txp']-b0['txp']:+d})  "
      f"GMII txBytes {b0['gmii_tx']}->{b1['gmii_tx']} ({b1['gmii_tx']-b0['gmii_tx']:+d}) ==")
print(f"== 主机 ifIndex {IFIDX} RX: rcb {h['rcb']}->{h1['rcb']} ({h1['rcb']-h['rcb']:+d})  "
      f"ruc {h['ruc']}->{h1['ruc']} ({h1['ruc']-h['ruc']:+d})  "
      f"rby {h['rby']}->{h1['rby']} ({h1['rby']-h['rby']:+d}) ==")
print(f"== 主机 ifIndex {IFIDX} 自己发了多少: sbc {h1['sbc']-h['sbc']:+d} sby {h1['sby']-h['sby']:+d} ==")
print("== 板子发/主机收 对照 ==")
if b1["txp"] - b0["txp"] > 0 and h1["rby"] - h["rby"] == 0:
    print("  -> 板子在发，但主机一点没收到 ⇒ 板->主机方向 断（PHY/RGMII TX 或线缆/对端口）")
elif b1["txp"] - b0["txp"] == 0:
    print("  -> 板子压根没发（驱动/MAC TX 侧卡住）")
elif h1["rby"] - h["rby"] > 0:
    print("  -> 板发、主机收：板->主机通")
