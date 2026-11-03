#!/usr/bin/env python3
"""uart_login_until.py -- state-driven login: wait for each expected prompt.

Usage: python -u scripts/uart_login_until.py COM7 9600
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

transcript = []


def wait_for(pats, secs):
    """Read until one of the byte-patterns appears or timeout. Returns (which, buf)."""
    t0 = time.time()
    buf = b""
    while time.time() - t0 < secs:
        d = s.read(4096)
        if d:
            buf += d
            for i, p in enumerate(pats):
                if p in buf:
                    transcript.append(buf)
                    return i, buf
    transcript.append(buf)
    return -1, buf


def show(tag, b):
    txt = "".join(chr(c) if 32 <= c < 127 or c in (10, 13) else "." for c in b)
    print("--- %s ---\n%s" % (tag, txt.rstrip()), flush=True)


# 1. get to a login prompt
which, b = wait_for([b"login:"], 2.0)
if which < 0:
    s.write(b"\r")
    which, b = wait_for([b"login:"], 3.0)
show("prompt", b)
if which < 0:
    print("!! no login prompt", flush=True)

# 2. username
s.write(b"root\r")
which, b = wait_for([b"Password:", b"login:"], 4.0)
show("after username", b)
if which == 1:
    print("!! bounced back to login (username rejected)", flush=True)

# 3. empty password
s.write(b"\r")
which, b = wait_for([b"#", b"$", b"incorrect", b"login:"], 4.0)
show("after password", b)
if which in (0, 1):
    print("== LOGGED IN ==", flush=True)
else:
    print("== login did not complete ==", flush=True)

# 4. run a command
MARK = "CONSOLE-OK-4242"
s.write(("echo %s 12345\r" % MARK).encode())
time.sleep(0.4)
which, b = wait_for([b"\r\n"], 3.0)
show("cmd out", b)

allt = b"".join(transcript)
flat = re.sub(rb"\s+", b"", allt).decode("ascii", "replace")
print("marker_occurrences=%d  has_echo_cmd=%s" % (
    flat.count(MARK), ("echo" + MARK) in flat), flush=True)
s.close()
