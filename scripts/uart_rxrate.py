#!/usr/bin/env python3
"""uart_rxrate.py -- clean RX loss measurement (no CR, so login state never changes).

At a quiescent `buildroot login: ` prompt the tty echoes whatever it receives, and a
line without CR keeps login waiting -> the echo is exactly what the FPGA received.
Sends N known chars, reads the echo, and diffs position by position (allowed: drops).

Usage: python -u scripts/uart_rxrate.py COM7 115200 [trials] [N]
"""
import sys
import time

import serial

port = sys.argv[1] if len(sys.argv) > 1 else "COM7"
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
trials = int(sys.argv[3]) if len(sys.argv) > 3 else 4
N = int(sys.argv[4]) if len(sys.argv) > 4 else 60

s = serial.Serial(port, baud, timeout=0.05)
s.dtr = False
s.rts = False
time.sleep(0.3)

ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
SENT = (ALPHABET * ((N // len(ALPHABET)) + 1))[:N]


def rd(secs):
    t0 = time.time()
    out = b""
    while time.time() - t0 < secs:
        d = s.read(4096)
        if d:
            out += d
    return out


def to_prompt():
    for _ in range(10):
        b = rd(0.4)
        if b.endswith(b"buildroot login: "):
            return True
        s.write(b"\r")
        b = rd(1.5)
        if b.endswith(b"buildroot login: "):
            return True
    return False


total_sent = total_kept = 0
for t in range(trials):
    if not to_prompt():
        print("!! no prompt", flush=True)
        break
    s.reset_input_buffer()
    t0 = time.time()
    s.write(SENT.encode())
    buf = b""
    while time.time() - t0 < 0.3 + N * 12.0 / baud:
        d = s.read(4096)
        if d:
            buf += d
    echo = "".join(ch for ch in buf.decode("ascii", "replace") if ch in ALPHABET)
    # 顺序比对：允许丢字符
    i = 0
    lost = []
    for ch in echo:
        if i >= len(SENT):
            break
        if ch == SENT[i]:
            i += 1
        else:
            j = SENT.find(ch, i)
            if j < 0:
                continue
            lost.extend(range(i, j))
            i = j + 1
    if i < len(SENT):
        lost.extend(range(i, len(SENT)))
    kept = len(SENT) - len(lost)
    total_sent += len(SENT)
    total_kept += kept
    print("trial %d: sent %d kept %d lost %d (%s) echo=%r" % (
        t, len(SENT), kept, len(lost), lost[:20], echo[:len(SENT)]), flush=True)
    s.write(b"\r")
    rd(1.0)

if total_sent:
    print("TOTAL kept %d/%d = %.1f%% (lost %.1f%%)" % (
        total_kept, total_sent, 100.0 * total_kept / total_sent,
        100.0 * (total_sent - total_kept) / total_sent), flush=True)
s.close()
