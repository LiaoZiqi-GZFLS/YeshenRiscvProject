#!/usr/bin/env python3
"""uart_latency.py -- measure RX->echo round trip precisely at a given baud.

Usage: python -u scripts/uart_latency.py COM7 9600
"""
import sys
import time

import serial

port = sys.argv[1] if len(sys.argv) > 1 else "COM7"
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 9600

s = serial.Serial(port, baud, timeout=0.01)
s.dtr = False
s.rts = False
time.sleep(0.3)


def collect(secs):
    out = []
    t0 = time.time()
    while time.time() - t0 < secs:
        d = s.read(4096)
        if d:
            for c in d:
                out.append((round((time.time() - t0) * 1000, 1), c))
    return out


print("settle 3s:", [(t, chr(c) if 32 <= c < 127 else hex(c)) for t, c in collect(3)],
      flush=True)

for label, data in (("single CR", b"\r"),
                    ("5 x 'a'", b"aaaaa"),
                    ("20 x 'a'", b"a" * 20),
                    ("40 x 'a'", b"a" * 40)):
    s.reset_input_buffer()
    t_write = time.time()
    s.write(data)
    r = collect(6.0)
    print("%-10s sent %2d B; got %2d B; first at %s ms; all within %s ms" % (
        label, len(data), len(r),
        (r[0][0] if r else "-"), (r[-1][0] if r else "-")), flush=True)
    print("           bytes: %s" % "".join(
        chr(c) if 32 <= c < 127 else ("\\r" if c == 13 else "\\n" if c == 10 else "?")
        for _, c in r)[:120], flush=True)
    print("           write took %.1f ms" % ((time.time() - t_write - 6.0) * 1000 + 6000 -
                                             (r[-1][0] if r else 6000)), flush=True)
s.close()
