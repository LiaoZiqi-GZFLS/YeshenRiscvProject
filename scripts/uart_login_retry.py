#!/usr/bin/env python3
"""uart_login_retry.py -- log in through a lossy RX by retrying.

RX currently drops ~12% of chars, so a 4-char username often arrives mangled.
Retry until `#` appears, then optionally run commands (argv[4..] = shell commands).

Usage: python -u scripts/uart_login_retry.py COM7 115200 [max_tries] ["cmd1" "cmd2" ...]
"""
import sys
import time

import serial

port = sys.argv[1] if len(sys.argv) > 1 else "COM7"
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
max_tries = int(sys.argv[3]) if len(sys.argv) > 3 else 25
cmds = sys.argv[4:]

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


def to_prompt(secs=1.2):
    for _ in range(6):
        b = rd(0.3)
        if b.endswith(b"buildroot login: "):
            return True
        s.write(b"\r")
        b = rd(secs)
        if b.endswith(b"buildroot login: "):
            return True
    return False


logged = False
for k in range(max_tries):
    if not to_prompt():
        print("[%d] no prompt" % k, flush=True)
        continue
    s.reset_input_buffer()
    s.write(b"root\r")
    r = b""
    t0 = time.time()
    while time.time() - t0 < 2.0:
        d = s.read(4096)
        if d:
            r += d
            if b"Password:" in r or b"login:" in r:
                break
    if b"Password:" not in r:
        print("[%d] username not accepted (rx mangled): %s" % (k, txt(r).strip()[-70:]),
              flush=True)
        continue
    s.write(b"\r")
    t0 = time.time()
    r = b""
    while time.time() - t0 < 3.0:
        d = s.read(4096)
        if d:
            r += d
            if b"#" in r or b"incorrect" in r:
                break
    if b"#" in r:
        print("[%d] LOGGED IN" % k, flush=True)
        logged = True
        break
    print("[%d] password rejected: %s" % (k, txt(r).strip()[-70:]), flush=True)

print("=== %s (tries=%d) ===" % ("LOGGED IN" if logged else "FAILED", k + 1), flush=True)

if logged:
    for c in cmds:
        s.write((c + "\r").encode())
        t0 = time.time()
        buf = b""
        while time.time() - t0 < 3.0:
            d = s.read(4096)
            if d:
                buf += d
        print("$ %s\n%s" % (c, txt(buf).strip()), flush=True)
s.close()
