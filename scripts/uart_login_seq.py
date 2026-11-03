#!/usr/bin/env python3
"""uart_login_seq.py -- explicit root/empty-password login at a fixed baud.

Usage: python -u scripts/uart_login_seq.py COM7 9600
"""
import re
import sys
import time

import serial

port = sys.argv[1] if len(sys.argv) > 1 else "COM7"
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 9600

s = serial.Serial(port, baud, timeout=0.1)
s.dtr = False
s.rts = False
time.sleep(0.3)
s.reset_input_buffer()

acc = b""


def rd(secs):
    global acc
    t0 = time.time()
    out = b""
    while time.time() - t0 < secs:
        d = s.read(4096)
        if d:
            out += d
            acc += d
    return out


def show(tag, b):
    txt = "".join(chr(c) if 32 <= c < 127 or c in (10, 13) else "." for c in b)
    print("--- %s ---\n%s" % (tag, txt.rstrip()), flush=True)


def send(b):
    print(">>> %r" % b, flush=True)
    s.write(b)


# get back to a clean login prompt
for _ in range(3):
    b = rd(0.5)
    if b"buildroot login:" in b:
        break
    send(b"\r")
    b = rd(2.0)
    show("reset->", b)
    if b"buildroot login:" in b:
        break

show("state", rd(0.5))
send(b"root\r")
show("after-user", rd(2.0))
send(b"\r")
b = rd(3.0)
show("after-pass", b)

MARK = "CONSOLE-OK-4242"
send(("echo %s 12345\r" % MARK).encode())
show("cmd", rd(3.0))

flat = re.sub(rb"\s+", b"", acc).decode("ascii", "replace")
print("marker_occurrences=%d  has_echo=%s" % (
    flat.count(MARK), ("echo" + MARK) in flat), flush=True)
s.close()
