#!/usr/bin/env python3
"""uart_flood.py -- push a known byte burst at the board console so the board can count RX.

Why: the board's probe samples LSR.DR in a tight loop. During that window something must
actually be driving the line, otherwise the count is trivially zero and proves nothing.
This floods `count` bytes of a repeating pattern at the console baud.

Usage: python -u scripts/uart_flood.py <PORT> <BAUD> [COUNT]
"""
import sys
import time

import serial

port = sys.argv[1] if len(sys.argv) > 1 else "COM7"
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 28800
count = int(sys.argv[3]) if len(sys.argv) > 3 else 4000

s = serial.Serial(port, baud, timeout=0.2)
# 'A' = 0x41 -> alternating bits, good for framing margin. No CR, so we don't hammer the
# login prompt with thousands of newlines.
payload = b"A" * 256
sent = 0
t0 = time.time()
while sent < count:
    n = s.write(payload[: min(len(payload), count - sent)])
    s.flush()
    sent += n
print(f"# flooded {sent} bytes @{baud} in {time.time() - t0:.1f}s")
s.close()
