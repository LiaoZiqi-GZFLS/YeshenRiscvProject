#!/usr/bin/env python3
"""uart_login_final.py -- wait-for-state login; prints the full transcript.

Usage: python -u scripts/uart_login_final.py COM7 9600
"""
import re
import sys
import time

import serial

port = sys.argv[1] if len(sys.argv) > 1 else "COM7"
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 9600

s = serial.Serial(port, baud, timeout=0.05)
s.dtr = False
s.rts = False
time.sleep(0.3)

acc = []


def wait_for(pats, secs, tag):
    t0 = time.time()
    buf = b""
    while time.time() - t0 < secs:
        d = s.read(4096)
        if d:
            buf += d
            acc.append(d)
            for i, p in enumerate(pats):
                if p in buf:
                    return i, buf, time.time() - t0
    acc.append(buf)
    return -1, buf, time.time() - t0


def txt(b):
    return "".join(chr(c) if 32 <= c < 127 or c in (10, 13) else "." for c in b)


# 1. reach a login prompt
got = False
for attempt in range(5):
    i, b, dt = wait_for([b"login:"], 0.8, "probe")
    if i == 0:
        print("[%d] already at login prompt" % attempt, flush=True)
        got = True
        break
    s.write(b"\r")
    i, b, dt = wait_for([b"login:"], 4.0, "reset")
    print("[%d] reset -> (%.2fs) %s" % (attempt, dt, txt(b).strip()[-120:]), flush=True)
    if i == 0:
        got = True
        break
if not got:
    print("!! could not reach login prompt", flush=True)

# 2. username
s.write(b"root\r")
i, b, dt = wait_for([b"Password:", b"login:"], 8.0, "user")
print("[user] %.2fs -> %s" % (dt, txt(b).strip()[-160:]), flush=True)
if i != 0:
    print("!! username did not reach Password: prompt (i=%d)" % i, flush=True)

# 3. empty password
s.write(b"\r")
i, b, dt = wait_for([b"#", b"incorrect", b"login:"], 8.0, "pass")
print("[pass] %.2fs -> %s" % (dt, txt(b).strip()[-200:]), flush=True)
print("== %s ==" % ("LOGGED IN" if i == 0 else "NOT LOGGED IN"), flush=True)

# 4. command
MARK = "CONSOLE-OK-4242"
s.write(("echo %s 12345\r" % MARK).encode())
i, b, dt = wait_for([b"\n"], 6.0, "cmd")
print("[cmd] %.2fs -> %s" % (dt, txt(b).strip()[-200:]), flush=True)
time.sleep(0.5)
d = b""
while True:
    x = s.read(4096)
    if not x:
        break
    d += x
    acc.append(x)
print("[cmd-more] %s" % txt(d).strip()[-200:], flush=True)

allt = b"".join(acc)
flat = re.sub(rb"\s+", b"", allt).decode("ascii", "replace")
print("marker_occurrences=%d has_echo=%s" % (flat.count(MARK), ("echo" + MARK) in flat),
      flush=True)
s.close()
