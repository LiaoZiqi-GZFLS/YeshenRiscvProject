#!/usr/bin/env python3
"""uart_spacing_test.py -- spaced singles vs back-to-back burst.

Hypothesis: UARTRx samples the stop bit one bit-period late, so it lands inside the
NEXT byte's start bit -> back-to-back bytes are flagged as framing errors and dropped.
If so: 10 chars sent 100 ms apart all echo; 10 chars back-to-back mostly do not.

Usage: python -u scripts/uart_spacing_test.py COM7 9600
"""
import sys
import time

import serial

port = sys.argv[1] if len(sys.argv) > 1 else "COM7"
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 9600

s = serial.Serial(port, baud, timeout=0.05)
s.dtr = False
s.rts = False
time.sleep(0.3)


def txt(b):
    return "".join(chr(c) if 32 <= c < 127 else ("\\r" if c == 13 else
                   "\\n" if c == 10 else ".") for c in b)


def rd(secs):
    t0 = time.time()
    out = b""
    while time.time() - t0 < secs:
        d = s.read(4096)
        if d:
            out += d
    return out


# settle to a quiescent login prompt
for _ in range(8):
    b = rd(0.4)
    if b.endswith(b"buildroot login: "):
        break
    s.write(b"\r")
    rd(1.2)
rd(0.3)

print("== 10 chars, 100 ms apart ==", flush=True)
out = b""
for _ in range(10):
    s.write(b"q")
    time.sleep(0.10)
    out += rd(0.06)
print("echoed %d/10 : %s" % (out.count(b"q"), txt(out)), flush=True)

time.sleep(0.5)
rd(0.5)

print("== 10 chars back-to-back ==", flush=True)
s.write(b"q" * 10)
time.sleep(0.4)
out = rd(1.5)
print("echoed %d/10 : %s" % (out.count(b"q"), txt(out)), flush=True)

time.sleep(0.5)
rd(0.5)
print("== 30 chars back-to-back ==", flush=True)
s.write(b"q" * 30)
time.sleep(1.0)
out = rd(1.5)
print("echoed %d/30 : %s" % (out.count(b"q"), txt(out)), flush=True)
s.close()
