#!/usr/bin/env python3
"""uart_loss.py -- measure RX character loss on the console tty.

Method: drive to a quiescent `buildroot login: ` prompt, then send N known chars
(echo is on at the login prompt) and diff the echo against what we sent.
Prints the exact positions lost, then does a real root/empty-password login and
runs a command.

Usage: python -u scripts/uart_loss.py COM7 115200 [N]
"""
import re
import sys
import time

import serial

port = sys.argv[1] if len(sys.argv) > 1 else "COM7"
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
N = int(sys.argv[3]) if len(sys.argv) > 3 else 64

s = serial.Serial(port, baud, timeout=0.05)
s.dtr = False
s.rts = False
time.sleep(0.3)
acc = []


def txt(b):
    return "".join(chr(c) if 32 <= c < 127 else ("\\r" if c == 13 else
                   "\\n" if c == 10 else ".") for c in b)


def wait_for(pat, secs):
    t0 = time.time()
    buf = b""
    while time.time() - t0 < secs:
        d = s.read(4096)
        if d:
            buf += d
            acc.append(d)
            if pat in buf:
                return True, buf
    return False, buf


# 1. quiescent login prompt
for _ in range(8):
    ok, b = wait_for(b"login: ", 0.5)
    if ok:
        break
    s.write(b"\r")
    ok, b = wait_for(b"login: ", 1.5)
    if ok:
        break
print("prompt:", txt(b).strip()[-60:], flush=True)

# 2. loss test: send a known alphabet, ask the tty to echo it back
ALPHABET = ("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
SENT = (ALPHABET * ((N // len(ALPHABET)) + 1))[:N]
s.reset_input_buffer()
acc.clear()
t0 = time.time()
s.write(SENT.encode())
s.write(b"\r")
time.sleep(0.4)
buf = b""
while time.time() - t0 < 0.4 + N * 12.0 / baud:
    d = s.read(4096)
    if d:
        buf += d
        acc.append(d)
echo = buf.decode("ascii", "replace")
flat = "".join(ch for ch in echo if ch not in "\r\n")
# 逐字符对齐（顺序比对，允许丢失）
i = 0
kept = []
for ch in flat:
    if i < len(SENT) and ch == SENT[i]:
        kept.append(i)
        i += 1
    elif i < len(SENT) and ch in SENT[i:]:
        # 丢了一个或多个
        j = SENT.index(ch, i)
        for k in range(i, j):
            kept.append(-(k + 1))
        kept.append(j)
        i = j + 1
lost = [-k - 1 for k in kept if k < 0]
print("sent %d chars, echo kept %d, LOST %d  (%.1f%%)" % (
    len(SENT), sum(1 for k in kept if k >= 0), len(lost), 100.0 * len(lost) / len(SENT)),
    flush=True)
print("echo :", repr(flat[:120]), flush=True)
print("sent :", repr(SENT[:120]), flush=True)
print("lost positions:", lost[:40], flush=True)

# 3. real login
print("== login ==", flush=True)
time.sleep(0.5)
ok, b = wait_for(b"login: ", 2.0)
if not ok:
    s.write(b"\r")
    ok, b = wait_for(b"login: ", 3.0)
s.reset_input_buffer()
s.write(b"root\r")
ok, b = wait_for(b"Password:", 5.0)
print("after user: %s" % txt(b).strip()[-80:], flush=True)
s.write(b"\r")
ok, b = wait_for(b"#", 6.0)
print("after pass: %s" % txt(b).strip()[-120:], flush=True)
print("== %s ==" % ("LOGGED IN" if ok else "NOT LOGGED IN"), flush=True)

if ok:
    MARK = "CONSOLE-OK-4242"
    s.write(("echo %s 12345\r" % MARK).encode())
    time.sleep(0.5)
    t0 = time.time()
    buf = b""
    while time.time() - t0 < 3.0:
        d = s.read(4096)
        if d:
            buf += d
            acc.append(d)
    print("cmd out: %s" % txt(buf).strip()[-200:], flush=True)
    flat2 = re.sub(rb"\s+", b"", b"".join(acc)).decode("ascii", "replace")
    print("marker_occurrences=%d has_echo=%s" % (
        flat2.count(MARK), ("echo" + MARK) in flat2), flush=True)
s.close()
