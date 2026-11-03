#!/usr/bin/env python3
"""eth_rx_disambig.py -- RX 侧"三层同步对账"，用来把 +0 结果里混着的三种可能分开。

三种可能：
  (a) 主机侧根本没发出去（拓扑/网卡/防火墙）   -> host_tx_bcast 不涨
  (b) 发出去了但没到板上 GMII 引脚（PHY/RGMII/延迟） -> host_tx_bcast 涨 而 GMII rxBytes 不涨
  (c) 到了引脚但没进驱动（MAC/datapath/CSR）      -> GMII rxBytes 涨 而 netdev rx_packets 不涨

三层量：
  主机: ifIndex<IDX> ReceivedBroadcastPackets (板子 ARP 是广播；主力激励)
  板卡: GMII W4.rxBytes（`liteeth_wrap` 在 rgmii_clk 上数 rx_dv 期间的字节，**引脚级**、与防火墙无关）
         netdev eth0 statistics/rx_packets（**驱动级**，进协议栈的包）
用法：python -u scripts/eth_rx_disambig.py [COM] [BAUD] [IFIDX] [BOARDIP] [N]
"""
import re
import subprocess
import sys
import time

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM7"
BAUD = sys.argv[2] if len(sys.argv) > 2 else "115200"
IFIDX = sys.argv[3] if len(sys.argv) > 3 else "27"
BOARD = sys.argv[4] if len(sys.argv) > 4 else "10.16.147.211"
N = int(sys.argv[5]) if len(sys.argv) > 5 else 20

DEV = "eth0"


def board_read():
    cmd = (f"cat /sys/class/net/{DEV}/statistics/rx_packets /sys/class/net/{DEV}/statistics/rx_bytes; "
           f"printf 'GM %s %s %s %s %s\\n' $(devmem 0xF000B000) $(devmem 0xF000B004) "
           f"$(devmem 0xF000B008) $(devmem 0xF000B00C) $(devmem 0xF000B010)")
    out = subprocess.run([sys.executable, "-u", "scripts/guest_cmd.py", PORT, BAUD, cmd],
                         capture_output=True, text=True, encoding="utf-8", errors="replace")
    t = out.stdout
    rxp = re.search(r"\b(\d+)\b(?=\s*GM)", t)
    gmm = re.search(r"GM\s+0x([0-9A-Fa-f]{8})\s+0x([0-9A-Fa-f]{8})\s+0x([0-9A-Fa-f]{8})\s+"
                    r"0x([0-9A-Fa-f]{8})\s+0x([0-9A-Fa-f]{8})", t)
    if not gmm:
        print("!! 板上读数解析失败；原始尾巴：")
        print(t[-500:])
        return None
    w = [int(x, 16) for x in gmm.groups()]
    # rx_packets / rx_bytes 是 cat 的两行纯数字，取 marker 前最后两个
    stats = re.findall(r"^\s*(\d+)\s*$", t, re.M)
    rxp = int(stats[0]) if len(stats) >= 1 else -1
    rxb = int(stats[1]) if len(stats) >= 2 else -1
    return {"rxp": rxp, "rxb": rxb, "gmii_rx": w[4] & 0xFFFF, "gmii_tx": (w[4] >> 16) & 0xFFFF,
            "w0": w[0], "w1": w[1]}


def host_bcast():
    ps = (f"(Get-NetAdapter -InterfaceIndex {IFIDX} | Get-NetAdapterStatistics) | "
          "Select-Object ReceivedBroadcastPackets,ReceivedUnicastPackets,ReceivedBytes | "
          "ConvertTo-Csv -NoTypeInformation")
    out = subprocess.run(["powershell", "-NoProfile", "-Command", ps],
                         capture_output=True, text=True, errors="replace")
    try:
        # CSV 第二行是数据行："<bcast>","<ucast>","<bytes>"
        rows = [l for l in out.stdout.splitlines() if re.match(r'^"\d', l)]
        v = [int(x.strip('"')) for x in rows[0].split(",")]
        return v[0], v[1], v[2]
    except Exception as e:
        print("!! 主机计数器解析失败:", e, out.stdout[:300])
        return -1, -1, -1


def force_arp():
    subprocess.run(["powershell", "-NoProfile", "-Command",
                    f"Remove-NetNeighbor -IPAddress {BOARD} -Confirm:$false -ErrorAction SilentlyContinue"],
                   capture_output=True)
    for _ in range(N):
        subprocess.run(["ping", "-n", "1", "-w", "200", BOARD],
                       capture_output=True, text=True, errors="replace")


print("== 基线 ==")
b0 = board_read()
h0 = host_bcast()
if b0 is None:
    sys.exit(1)
print(f"  board: netdev rx_packets={b0['rxp']} rx_bytes={b0['rxb']}  GMII rxBytes={b0['gmii_rx']} txBytes={b0['gmii_tx']}  W1=0x{b0['w1']:08X}")
print(f"  host : bcast={h0[0]} ucast={h0[1]} bytes={h0[2]}")

print(f"== 发起 ARP 冲击（flush 邻居 + {N} 次 ping 到 {BOARD}）==")
force_arp()
time.sleep(1)

print("== 复测 ==")
b1 = board_read()
h1 = host_bcast()
print(f"  board: netdev rx_packets={b1['rxp']} rx_bytes={b1['rxb']}  GMII rxBytes={b1['gmii_rx']} txBytes={b1['gmii_tx']}  W1=0x{b1['w1']:08X}")
print(f"  host : bcast={h1[0]} ucast={h1[1]} bytes={h1[2]}")

print("== DELTA ==")
hb = h1[0] - h0[0]
grx = b1["gmii_rx"] - b0["gmii_rx"]
nrxp = b1["rxp"] - b0["rxp"]
print(f"  host bcast_tx   = {hb:+d}")
print(f"  GMII rxBytes    = {grx:+d}")
print(f"  netdev rx_packets = {nrxp:+d}")
print("== 判读 ==")
if hb <= 0:
    print("  -> (a) 主机没发出去：拓扑/网卡/防火墙问题（激励为 0）")
elif grx <= 0:
    print("  -> (b) 主机发了但板卡 GMII 引脚没收到：PHY/RGMII/延迟 层")
elif nrxp <= 0:
    print("  -> (c) 到了引脚但没进驱动：MAC/datapath/CSR 层")
else:
    print("  -> (d) 三层都通，RX 正常")
