# -*- coding: utf-8 -*-
"""Capture the board UART console (e.g. COM7) at 115200 and print it line by line.

Windows consoles here are GBK, so **nothing may be printed raw**: any byte the board
emits that is not ASCII (or a stray 0xFF during FPGA configuration) decodes to U+FFFD
and crashes print(). Everything goes through `emit()`, which strips to ASCII, and the
raw bytes are also appended to a file so nothing is lost.
"""
import sys
import time

import serial

port = sys.argv[1] if len(sys.argv) > 1 else "COM7"
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 12.0
baud = int(sys.argv[3]) if len(sys.argv) > 3 else 115200
raw_path = sys.argv[4] if len(sys.argv) > 4 else "sim/reglogs/uart_raw.bin"


def emit(text):
    sys.stdout.write(text.encode("ascii", "replace").decode("ascii") + "\n")
    sys.stdout.flush()


s = serial.Serial(port, baud, timeout=0.2)
s.reset_input_buffer()
# ★ 2026-10-08：开口后先补一个 **^Q(XON)**。控制台 tty 默认带 `IXON`，只要 RX 流里出现过
#   一个杂散 0x13(^S)（主机开串口拨 DTR/RTS 时 CP2102 可能吐一个）就会**停发** ——
#   表现为"板子全静默"但硬件空闲（见 docs §20 / scripts/uart_xoff_ab.py）。
#   补 ^Q 是无害的：正常状态下它只是流控的"继续"信号。
s.write(b"\x11")
emit(f"# listening {port} @{baud} for {secs}s (raw -> {raw_path})")

t_end = time.time() + secs
buf = b""
n = 0
raw = open(raw_path, "wb")
try:
    while time.time() < t_end:
        d = s.read(256)
        if d:
            raw.write(d)
            buf += d
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                emit(f"[{time.strftime('%H:%M:%S')}] {line.decode('ascii', 'replace').rstrip(chr(13))}")
                n += 1
    if buf:
        emit(f"[tail-no-newline] {len(buf)} bytes: {buf[:120].decode('ascii', 'replace')!r}")
finally:
    raw.close()
    s.close()
emit(f"# {n} lines captured from {port} (raw bytes -> {raw_path})")
