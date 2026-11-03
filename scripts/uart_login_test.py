#!/usr/bin/env python3
"""uart_login_test.py -- full interactive-console criterion at a given baud.

Log in as root/empty-password, run a command, and require BOTH the command echo
and the command OUTPUT to come back byte-identical.

Usage: python -u scripts/uart_login_test.py COM7 9600
"""
import re
import sys
import time

import serial

port = sys.argv[1] if len(sys.argv) > 1 else "COM7"
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 9600

s = serial.Serial(port, baud, timeout=0.2)
s.dtr = False
s.rts = False
time.sleep(0.3)
s.reset_input_buffer()

log = []


def drain(secs):
    t0 = time.time()
    buf = b""
    while time.time() - t0 < secs:
        d = s.read(4096)
        if d:
            buf += d
    log.append(buf)
    return buf


def show(tag, b):
    txt = "".join(chr(c) if 32 <= c < 127 or c in (10, 13) else "." for c in b)
    print("--- %s (%d B) ---\n%s" % (tag, len(b), txt), flush=True)


print("== wake ==", flush=True)
s.write(b"\r\r")
show("wake", drain(1.5))

print("== login root ==", flush=True)
s.write(b"root\r")
show("after user", drain(1.5))

print("== empty password ==", flush=True)
s.write(b"\r")
show("after pass", drain(2.0))

print("== command ==", flush=True)
MARK = "CONSOLE-OK-4242"
s.write(("echo %s\r" % MARK).encode())
r = drain(3.0)
show("cmd", r)

allt = b"".join(log)
flat = re.sub(rb"\s+", b"", allt).decode("ascii", "replace")
n = flat.count(MARK)
echo_ok = ("echo" + MARK) in flat
out_ok = n >= 2
print("cmd_echo_seen=%s marker_occurrences=%d" % (echo_ok, n), flush=True)
print("=== LOGIN TEST %s ===" % ("PASS" if (echo_ok and out_ok) else "FAIL"), flush=True)
s.close()
