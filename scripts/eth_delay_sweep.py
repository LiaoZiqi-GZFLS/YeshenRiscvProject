#!/usr/bin/env python3
"""eth_delay_sweep.py -- RGMII 延迟运行期扫描（不需要重出带）。

前提：m8 起的比特流把厂家那两个 IDELAY 常量提到了端口，并挂在 **0xF000B01C**（可写）：
  写 = {dly_txclk[15:8], dly_rx[7:0]}（0..247，10ps/step）；读回同格式。

判据（每档一个二进制结果）：
  · 板子主动 ARP 主机（`ip neigh flush all` + `ping -c1 10.16.147.67`）后，看 `.105` 是
    **REACHABLE/DELAY/STALE（通）** 还是 **FAILED/INCOMPLETE（不通）** —— 这是**一个完整的往返**
    （板的 ARP 请求出去 + 主机的应答回来），且不受主机防火墙影响（ICMP 可能被拦，ARP 不会）。
  · 顺带记录 ping 的 received 计数与板子的 `rx_packets`/`tx_packets` 增量。

用法：python -u scripts/eth_delay_sweep.py COM7 115200 [rx列表] [txclk]
  默认 rx 扫：247 240 224 208 192 176 160 128 96 64 32 0（txclk 固定 100）
"""
import re
import subprocess
import sys
import time

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM7"
BAUD = sys.argv[2] if len(sys.argv) > 2 else "115200"
RX_LIST = [int(x) for x in sys.argv[3].split(",")] if len(sys.argv) > 3 else \
          [247, 240, 224, 208, 192, 176, 160, 128, 96, 64, 32, 0]
TXCLK = int(sys.argv[4]) if len(sys.argv) > 4 else 100

GOOD = ("REACHABLE", "DELAY", "STALE", "PROBE")


def guest(cmd, timeout=25):
    r = subprocess.run([sys.executable, "-u", "scripts/guest_cmd.py", PORT, BAUD, cmd],
                       capture_output=True, text=True, encoding="utf-8", errors="replace",
                       timeout=timeout)
    return r.stdout


def try_value(rx):
    val = (TXCLK << 8) | rx
    # 1) 写延迟
    guest("devmem 0xF000B01C 32 0x%X; devmem 0xF000B01C" % val)
    # 2) 清 ARP + 触发一次往返
    out = guest("ip neigh flush all 2>/dev/null; ping -c 1 -W 1 10.16.147.67 >/dev/null 2>&1; "
                "echo PINGDONE; ip neigh show")
    state = "-"
    rx_ok = False
    for ln in out.splitlines():
        if "10.16.147.67" in ln:
            state = ln.strip().split()[-1]
            rx_ok = any(g in ln for g in GOOD)
    # 3) 计数器
    cnt = guest("cat /sys/class/net/eth0/statistics/rx_packets; "
                "cat /sys/class/net/eth0/statistics/tx_packets")
    nums = re.findall(r"^\s*(\d+)\s*$", cnt, re.M)
    rxp = nums[0] if nums else "?"
    txp = nums[1] if len(nums) > 1 else "?"
    return rx_ok, state, rxp, txp


print("== RGMII 延迟扫描：txclk=%d 固定，rx 逐个试 ==" % TXCLK)
print("   rx   | 往返 | .105 状态      | rx_packets | tx_packets")
best = []
for rx in RX_LIST:
    try:
        ok, state, rxp, txp = try_value(rx)
    except subprocess.TimeoutExpired:
        print("  %4d | TIMEOUT" % rx, flush=True)
        continue
    print("  %4d |  %s  | %-14s | %10s | %10s" % (rx, "通" if ok else "断", state, rxp, txp),
          flush=True)
    if ok:
        best.append(rx)
    time.sleep(0.3)

print("== 通过的档位: %s ==" % (best if best else "无 —— 说明不是(只)RX 延迟的问题"))
if best:
    print("建议：把 dly_rx 固定在中间的通过档（%d），再扫 dly_txclk（脚本第 4 个参数）。"
          % best[len(best) // 2])
