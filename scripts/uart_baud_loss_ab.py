#!/usr/bin/env python3
"""uart_baud_loss_ab.py -- A/B the RX loss against the tty baud (needs a root shell).

Hypothesis: the ~12% char loss is the 1-byte RX register being overwritten because
the software ISR cannot always keep up with one byte per 87 us @115200. If so, the
loss must collapse when the tty is put on a slower baud (260 us/byte @38400).

Method: from the logged-in shell, `stty -F /dev/ttyS0 <b>`; measure loss by sending a
known char string (no CR: the shell's line editor just echoes it) and diffing the echo.

Usage: python -u scripts/uart_baud_loss_ab.py COM7
"""
import sys
import time

import serial

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM7"
ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
N = 60
SENT = (ALPHABET * ((N // len(ALPHABET)) + 1))[:N]


def measure(baud):
    s = serial.Serial(PORT, baud, timeout=0.05)
    s.dtr = False
    s.rts = False
    time.sleep(0.4)
    if baud != 115200:
        time.sleep(0.4)
    s.reset_input_buffer()
    t0 = time.time()
    s.write(SENT.encode())
    buf = b""
    while time.time() - t0 < 0.3 + N * 12.0 / baud:
        d = s.read(4096)
        if d:
            buf += d
    echo = "".join(ch for ch in buf.decode("ascii", "replace") if ch in ALPHABET)
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
    s.write(b"\x15\r")          # Ctrl-U (kill line) + CR to clear the pending line
    time.sleep(0.3)
    d = b""
    t1 = time.time()
    while time.time() - t1 < 0.5:
        d += s.read(4096)
    s.close()
    return kept, len(lost), echo, d


def stty(baud, target):
    s = serial.Serial(PORT, baud, timeout=0.05)
    s.dtr = False
    s.rts = False
    time.sleep(0.3)
    s.reset_input_buffer()
    s.write(("stty -F /dev/ttyS0 %d\r" % target).encode())
    time.sleep(1.0)
    out = b""
    t0 = time.time()
    while time.time() - t0 < 1.0:
        out += s.read(4096)
    s.close()
    return out


print("== confirm logged in @115200 ==", flush=True)
s = serial.Serial(PORT, 115200, timeout=0.2)
s.dtr = False
s.rtx = False
s.write(b"\r")
time.sleep(0.6)
b = s.read(4096)
print("prompt:", repr(b[-60:]), flush=True)
s.close()
if b"#" not in b:
    print("!! not at a shell prompt - log in first (scripts/uart_login_retry.py)", flush=True)

for baud in (115200, 38400, 115200):
    kept, lost, echo, after = measure(baud)
    print("@%-7d kept %d/%d = %.1f%%  lost=%d  echo=%r" % (
        baud, kept, N, 100.0 * kept / N, lost, echo[:70]), flush=True)
    if baud != 115200:
        print("   (next: restore 115200)", flush=True)

print("== restore tty to 115200 ==", flush=True)
out = stty(38400, 115200)
print("stty out:", repr(out[-80:]), flush=True)
time.sleep(0.5)
s = serial.Serial(PORT, 115200, timeout=0.2)
s.dtr = False
s.write(b"\r")
time.sleep(0.6)
print("after restore:", repr(s.read(4096)[-80:]), flush=True)
s.close()
