#!/usr/bin/env python3
"""uart_scale.py -- does the board's response scale with how much we send?

If the FPGA really receives, a 1000-byte burst must produce a much bigger
reaction than a 1-byte burst. If the reaction is a fixed 1-4 bytes regardless,
the "response" is coupling/noise, not reception.

Usage: python -u scripts/uart_scale.py COM7 28800
"""
import sys
import time

import serial

port = sys.argv[1] if len(sys.argv) > 1 else "COM7"
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 28800

s = serial.Serial(port, baud, timeout=0.02)
s.dtr = False
s.rts = False
time.sleep(0.3)


def idle(secs):
    t0 = time.time()
    n = 0
    while time.time() - t0 < secs:
        d = s.read(4096)
        n += len(d)
    return n


def burst(nbytes, ch=b"U"):
    s.reset_input_buffer()
    t0 = time.time()
    s.write(ch * nbytes)
    time.sleep(0.05)
    out = b""
    while time.time() - t0 < 0.05 + max(1.0, nbytes * 10 / baud * 3):
        d = s.read(4096)
        if d:
            out += d
    return out


print("idle 5s baseline bytes:", idle(5), flush=True)
for n in (1, 10, 100, 1000, 4000):
    r = burst(n)
    print("sent %5d bytes -> got %4d bytes  head=%s" % (
        n, len(r), r[:24].hex()), flush=True)
    time.sleep(1.0)
    print("   post-idle 2s extra:", idle(2), flush=True)
s.close()
