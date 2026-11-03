#!/usr/bin/env python3
"""uart_echo_test.py -- at a known `buildroot login:` prompt, is a typed char echoed?

Usage: python -u scripts/uart_echo_test.py COM7 9600
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


def rd(secs):
    t0 = time.time()
    out = b""
    while time.time() - t0 < secs:
        d = s.read(4096)
        if d:
            out += d
    return out


def txt(b):
    return "".join(chr(c) if 32 <= c < 127 else ("\\r" if c == 13 else
                   "\\n" if c == 10 else ".") for c in b)


# reach a real login prompt (last output ends with it)
print("== drive to login prompt ==", flush=True)
for i in range(8):
    b = rd(0.4)
    if b.endswith(b"buildroot login: "):
        print("at prompt (attempt %d)" % i, flush=True)
        break
    s.write(b"\r")
    b = rd(1.2)
    print("  cr -> %s" % txt(b).strip()[-90:], flush=True)
else:
    print("!! never reached a quiescent login prompt", flush=True)

for payload in (b"q", b"x", b"qqqqq", b"ABCDE", b"root\r"):
    s.reset_input_buffer()
    t0 = time.time()
    s.write(payload)
    time.sleep(0.05)
    r = rd(1.2)
    print("send %-8r -> %2d B (%.0f ms): %s" % (
        payload, len(r), (time.time() - t0) * 1000, txt(r)), flush=True)
    time.sleep(0.3)
s.close()
