#!/usr/bin/env python3
"""uart_rate_dep.py -- is the RX loss rate-dependent? (needs a logged-in shell)

Mechanism under test: `Uart16550` has a **1-byte** RX register. If a byte lands while the
8250 ISR is between the IRQ and its RBR read (~10 us), it is overwritten -> loss.
Prediction: back-to-back bytes lose ~10-15%, but the SAME bytes sent with wide gaps lose 0%.

Usage: python -u scripts/uart_rate_dep.py COM7 115200
"""
import sys
import time

import serial

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM7"
BAUD = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
N = 40


def run(gap_s, label):
    sent = (ALPHABET * 3)[:N]
    s = serial.Serial(PORT, BAUD, timeout=0.02)
    s.dtr = False
    s.rts = False
    time.sleep(0.3)
    s.write(b"\x15")            # Ctrl-U: kill any pending line
    time.sleep(0.2)
    s.reset_input_buffer()
    for ch in sent:
        s.write(ch.encode())
        if gap_s:
            time.sleep(gap_s)
    # ★ 读窗口从"发完"起算（上一版从发送前起算 ⇒ 慢速档窗口在发完之前就关了 ⇒ 空回包假象）
    buf = b""
    t_read = time.time() + 0.4 + N * 12.0 / BAUD
    while time.time() < t_read:
        d = s.read(4096)
        if d:
            buf += d
    echo = "".join(c for c in buf.decode("ascii", "replace") if c in ALPHABET)
    i, lost = 0, []
    for c in echo:
        if i >= len(sent):
            break
        if c == sent[i]:
            i += 1
        else:
            j = sent.find(c, i)
            if j < 0:
                continue
            lost.extend(range(i, j))
            i = j + 1
    if i < len(sent):
        lost.extend(range(i, len(sent)))
    kept = N - len(lost)
    print("%-22s kept %2d/%d = %5.1f%%  lost=%s" % (
        label, kept, N, 100.0 * kept / N, lost[:12]), flush=True)
    s.write(b"\x15")
    time.sleep(0.2)
    s.close()


run(0.0, "back-to-back")
run(0.020, "20 ms gap per char")
run(0.0, "back-to-back (repeat)")
