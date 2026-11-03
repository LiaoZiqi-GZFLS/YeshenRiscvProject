#!/usr/bin/env python3
"""uart_diag.py -- timestamped, DTR/RTS-controlled console probe.

Purpose: separate "the board is transmitting" from "my port open reset the board",
and measure the emission rate/baud of whatever is on the line.

Usage: python -u scripts/uart_diag.py COM7 28800 20
       (port, baud, idle-watch seconds)

Phases:
  A. open with DTR/RTS de-asserted, listen `idle` s  -> baseline
  B. assert DTR -> listen 5 s      (does DTR reset the board?)
  C. de-assert DTR -> listen 5 s
  D. send b"\\r" then b"HELLO-12345\\r", listen 8 s  (typing response)
All raw bytes are written to sim/reglogs/uart_diag_raw.bin and a per-phase
byte-count/rate report is printed (ASCII only -- Windows console is GBK).
"""
import collections
import sys
import time

import serial

port = sys.argv[1] if len(sys.argv) > 1 else "COM7"
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 28800
idle = float(sys.argv[3]) if len(sys.argv) > 3 else 20.0

s = serial.Serial(port, baud, timeout=0.05)
try:
    s.dtr = False
    s.rts = False
except Exception as e:  # noqa: BLE001
    print("dtr/rts set failed:", e)
time.sleep(0.2)
s.reset_input_buffer()

raw = bytearray()
report = []


def watch(secs):
    t0 = time.time()
    buf = b""
    t_first = None
    while time.time() - t0 < secs:
        d = s.read(8192)
        if d:
            if t_first is None:
                t_first = time.time() - t0
            buf += d
            raw.extend(d)
    rate = len(buf) / secs
    c = collections.Counter(buf)
    top = [(hex(b), round(n / max(len(buf), 1), 2)) for b, n in c.most_common(6)]
    report.append((len(buf), round(rate, 1), None if t_first is None else round(t_first, 2), top))
    return buf


print("== A: idle watch %.0fs (dtr=0 rts=0) ==" % idle, flush=True)
watch(idle)
print("== B: dtr=1 ==", flush=True)
s.dtr = True
watch(5)
print("== C: dtr=0 ==", flush=True)
s.dtr = False
watch(5)
print("== D: type ==", flush=True)
s.write(b"\r")
time.sleep(0.3)
s.write(b"HELLO-12345\r")
watch(8)
s.close()

open("sim/reglogs/uart_diag_raw.bin", "wb").write(bytes(raw))

for name, (n, rate, tfirst, top) in zip("ABCD", report):
    print("phase %s: bytes=%d rate=%.1f B/s first_at=%s top=%s" % (name, n, rate, tfirst, top))
print("total bytes", len(raw), "-> sim/reglogs/uart_diag_raw.bin")
