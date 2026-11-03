#!/usr/bin/env python3
"""uart_xoff_ab.py -- 证明"控制台静默 = XOFF 软件流控"，并给出修法（零 RTL）。

机理：Linux 的 `tty_std_termios` 默认带 `ICRNL|IXON` ⇒ 控制台 tty **默认吃 ^S/^Q 流控**。
只要 RX 流里出现一个 **0x13(^S)**，tty 就**停发**（输出队列满 ⇒ shell 阻塞在 write ⇒ 不读输入
⇒ 什么都不回显），直到收到 **0x11(^Q)**。硬件此时完全空闲（实测 LSR=0x60 THRE/TEMT=1、
IIR=0xC1 无中断待处理、IER=0x05）—— 所以**不是硬件/波特/FIFO 问题**。

本脚本做三件事（正-反-复原）：
  A) `stty -ixon` 关掉流控  ⇒ 灌一串 0x13 ⇒ **控制台应当照常有回显**（正控）
  B) `stty ixon`  打开流控  ⇒ 灌一个 0x13 ⇒ **控制台应当静默**（反控；用 ^Q 复原）
  C) `stty -ixon` 复原成可用状态
用法：python -u scripts/uart_xoff_ab.py [COM] [BAUD]
"""
import subprocess
import sys
import time

import serial

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM7"
BAUD = int(sys.argv[2]) if len(sys.argv) > 2 else 115200


def guest(cmd, secs=6):
    return subprocess.run([sys.executable, "-u", "scripts/guest_cmd.py", PORT, str(BAUD), cmd],
                          capture_output=True, text=True, errors="replace").stdout


def talk(payload, wait=1.6):
    """直接对串口写 payload，返回收到的字节。"""
    s = serial.Serial(PORT, BAUD, timeout=0.3)
    s.dtr = False
    s.rts = False
    time.sleep(0.25)
    s.reset_input_buffer()
    s.write(payload)
    time.sleep(wait)
    d = s.read(8192)
    s.write(b"\x11")          # 无论如何补一个 XON，避免把控制台留在停发态
    s.close()
    return d


def alive(tag):
    d = talk(b"\r")
    ok = b"#" in d
    print(f"  [{tag}] 回显 {'有（#）' if ok else '无'}  收到 {len(d)} 字节")
    return ok


print("== A) 关掉 IXON 后灌 0x13（正控：应当照样活）==")
print(guest("stty -ixon; stty -a | head -1"))
a_ok = alive("关流控后，单独发 \\r")

s = serial.Serial(PORT, BAUD, timeout=0.3)
s.dtr = False; s.rts = False; time.sleep(0.25); s.reset_input_buffer()
s.write(b"\x13" * 5 + b"\r")
time.sleep(1.6)
d = s.read(8192)
s.close()
print(f"  发 5 个 ^S 后收到 {len(d)} 字节；含 '#' = {b'#' in d}")
print("  => A " + ("PASS（关流控后 ^S 不再能停住控制台）" if b"#" in d else "FAIL"))

print("== B) 打开 IXON 后灌 1 个 0x13（反控：应当静默）==")
print(guest("stty ixon; stty -a | head -1"))
s = serial.Serial(PORT, BAUD, timeout=0.3)
s.dtr = False; s.rts = False; time.sleep(0.25); s.reset_input_buffer()
s.write(b"\x13")
time.sleep(0.3)
s.write(b"\r")
time.sleep(1.6)
d = s.read(8192)
print(f"  发 1 个 ^S 后收到 {len(d)} 字节；含 '#' = {b'#' in d}")
s.write(b"\x11")          # ^Q 复原
time.sleep(0.6)
d2 = s.read(8192)
print(f"  补 ^Q 后收到 {len(d2)} 字节；含 '#' = {b'#' in d2}")
s.close()
print("  => B " + ("PASS（开着流控时 ^S 能停、^Q 能救）"
                   if (b"#" not in d and b"#" in d2) else "FAIL"))

print("== C) 复原（关掉 IXON，让控制台保持可用）==")
print(guest("stty -ixon; echo XOFF_AB_DONE"))
