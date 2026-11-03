#!/usr/bin/env python3
"""eth_tx_delay_sweep.py -- 扫 TX 时钟延迟（dly_txclk），判据在**主机侧**。

为什么这样判：
  · 板子发 ARP 请求 = **广播帧** => 主机网卡的 `ReceivedBroadcastPackets` 增量就是"过线几个" ✓
    （纯线路层判据，不依赖板子计数、也不受主机防火墙影响 —— 防火墙只影响 ICMP 应答）
  · 扫 `dly_txclk`（TXC 相对数据的相位）**同时完成两件事**：
      ① **验旋钮真的作用到 IDELAY**（否则各档数字会**完全一样**、且和静止时一样）
      ② 找出**最佳 TX 相位**
  · 相对比较才是要点：同样的"板子发 N 个 ARP"刺激，比较各档主机收到几个。

用法：python -u scripts/eth_tx_delay_sweep.py COM7 115200 [txclk列表] [rx固定]
"""
import re
import subprocess
import sys
import time

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM7"
BAUD = sys.argv[2] if len(sys.argv) > 2 else "115200"
TX_LIST = [int(x) for x in sys.argv[3].split(",")] if len(sys.argv) > 3 else \
          [0, 32, 64, 96, 128, 160, 200, 247]
RX_FIX = int(sys.argv[4]) if len(sys.argv) > 4 else 247
IFIDX = 27                      # 与板子同段那个口（10.16.147.67）
HOST = "10.16.147.67"
N_ARP = 5


def guest(cmd, timeout=30):
    r = subprocess.run([sys.executable, "-u", "scripts/guest_cmd.py", PORT, BAUD, cmd],
                       capture_output=True, text=True, encoding="utf-8", errors="replace",
                       timeout=timeout)
    return r.stdout


def host_bcast():
    # ⚠️ `Get-NetAdapterStatistics` 的对象里**没有 InterfaceIndex 属性**（第一版按它筛 => 恒返 -1，
    #    于是八档"+0"全是废数）。正解：先用 `Get-NetAdapter -InterfaceIndex` 拿到那个对象再管线上送。
    r = subprocess.run(["powershell", "-NoProfile", "-Command",
                        "(Get-NetAdapter -InterfaceIndex %d | Get-NetAdapterStatistics).ReceivedBroadcastPackets" % IFIDX],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    m = re.search(r"\d+", r.stdout)
    if not m:
        print("   !! ????????%r" % r.stdout[:120])
        return -1
    return int(m.group(0))


print("== TX ???????rx ?? %d??? ????? ifIndex %d ????? ==" % (RX_FIX, IFIDX))
print("  txclk | ??? %d ? ARP ?????????" % N_ARP)
base0 = host_bcast()
for tx in TX_LIST:
    guest("devmem 0xF000B01C 32 0x%X" % ((tx << 8) | RX_FIX))
    time.sleep(0.2)
    b = host_bcast()
    guest("ip neigh flush all 2>/dev/null; for i in $(seq %d); do ping -c 1 -W 1 %s >/dev/null 2>&1; done; echo ok"
          % (N_ARP, HOST))
    time.sleep(0.5)
    a = host_bcast()
    print("  %5d | %+d   (?? %d)" % (tx, a - b, b), flush=True)
print("== ??????????????????? => ???????? IDELAY????????????? ==")
