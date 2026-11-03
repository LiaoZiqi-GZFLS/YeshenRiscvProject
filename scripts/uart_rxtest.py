#!/usr/bin/env python3
"""uart_rxtest.py -- per-byte causal RX test.

Sends one byte at a time and records exactly what (and when) comes back.
If the tty echoes, a single 'A' must come back as 0x41.

Usage: python -u scripts/uart_rxtest.py COM7 28800
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
s.reset_input_buffer()


def grab(secs):
    t0 = time.time()
    out = []
    while time.time() - t0 < secs:
        d = s.read(256)
        if d:
            for b in d:
                out.append((round((time.time() - t0) * 1000, 1), b))
    return out


print("idle 3s ->", grab(3))
for ch in (b"A", b"U", b"a", b"\n", b"5"):
    print("send 0x%02x ->" % ch[0], flush=True)
    s.write(ch)
    time.sleep(0.05)
    r = grab(1.5)
    print("   got %d bytes: %s" % (len(r), [(t, hex(v)) for t, v in r[:20]]), flush=True)
print("send 'ABC\\n' ->", flush=True)
s.write(b"ABC\r")
time.sleep(0.05)
r = grab(3)
print("   got %d bytes: %s" % (len(r), [(t, hex(v)) for t, v in r[:40]]))
s.close()
