#!/usr/bin/env python3
"""uart_stress_probe.py -- 把 UART 的 RX 错误**按类型**压出来（零 RTL 改动）。

判据源：/proc/tty/driver/serial —— 8250 驱动把 tty->icount 暴露出来：
    `0: uart:16550A mmio:0xF0001000 irq:1 tx:N rx:N fe:N oe:N pe:N brk:N ...`
    （fe/oe/pe/brk 只在非零时才打印）
  · oe = overrun（RX FIFO 溢出）      ⇒ 缓冲/响应速度问题
  · fe = framing error（采样点错）    ⇒ 波特/时序问题
  · pe = parity error                 ⇒ 线干扰
三类完全不同的机理，一次就能分开。

做法：先读基线 → 往 COM 口**背靠背**灌 N 行长命令（每行 ~200 字符，纯注释、无害）→ 再读。
另外同时把主机侧写失败的次数也报出来（写不动 ≠ 板子丢，要分开）。

用法：python -u scripts/uart_stress_probe.py [COM] [BAUD] [行数] [行长]
"""
import re
import subprocess
import sys
import time

import serial

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM7"
BAUD = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
N = int(sys.argv[3]) if len(sys.argv) > 3 else 40
LEN = int(sys.argv[4]) if len(sys.argv) > 4 else 200


def sh(c):
    return subprocess.run(c, capture_output=True, text=True, errors="replace").stdout


def counters():
    out = sh([sys.executable, "-u", "scripts/guest_cmd.py", PORT, str(BAUD),
              "cat /proc/tty/driver/serial"])
    m = re.search(r"^0:\s+uart:(\S+).*?tx:(\d+)\s+rx:(\d+)(.*)$", out, re.M)
    if not m:
        print("!! 解析失败:\n", out[-400:])
        return None
    rest = m.group(4)
    def g(k):
        mm = re.search(rf"\b{k}:(\d+)", rest)
        return int(mm.group(1)) if mm else 0
    return dict(type=m.group(1), tx=int(m.group(2)), rx=int(m.group(3)),
                fe=g("fe"), oe=g("oe"), pe=g("pe"), brk=g("brk")), out


a, _ = counters()
if a is None:
    sys.exit(1)
print(f"基线: {a}")

line = ("true # " + "x" * max(0, LEN - 7)).encode() + b"\r"
s = serial.Serial(PORT, BAUD, timeout=0.2)
s.dtr = False
s.rts = False
time.sleep(0.3)
t0 = time.time()
sent = 0
for _ in range(N):
    try:
        s.write(line)
        sent += len(line)
    except Exception as e:
        print("写失败:", e)
        break
s.flush()
dt = time.time() - t0
s.close()
print(f"主机背靠背写入 {N} 行 × {LEN} 字符 = {sent} 字节，用时 {dt:.2f}s")

time.sleep(2.0)
b, raw = counters()
if b is None:
    sys.exit(1)
print(f"复测: {b}")
print(f"DELTA: tx {b['tx']-a['tx']:+d}  rx {b['rx']-a['rx']:+d}"
      f"  fe {b['fe']-a['fe']:+d}  oe {b['oe']-a['oe']:+d}"
      f"  pe {b['pe']-a['pe']:+d}  brk {b['brk']-a['brk']:+d}")
d = b
if d["oe"] - a["oe"] > 0 and d["fe"] - a["fe"] == 0 and d["pe"] - a["pe"] == 0:
    print("=> 定性：**溢出(overrun)** —— RX FIFO 被填满/没人及时取走（缓冲或中断响应问题）")
elif d["fe"] - a["fe"] > 0:
    print("=> 定性：**framing** —— 采样点错（波特误差/UARTRx 时序）")
elif d["pe"] - a["pe"] > 0:
    print("=> 定性：**parity** —— 线干扰")
else:
    print("=> 本轮没触发任何 RX 错误（加大 N/LEN 或降波特以逼近阈值）")
