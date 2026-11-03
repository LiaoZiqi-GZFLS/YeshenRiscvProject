#!/usr/bin/env python3
"""uart_baud_sweep.py -- find the baud the tty is ACTUALLY using right now.

Boot log decoded cleanly at 28800, but typing produces garbage. If /etc/inittab's
getty line (`console 0`) re-programs the tty after boot, the post-boot baud differs
from the boot-log baud. Because TX and RX share one divisor, opening the port at the
tty's real baud must make BOTH the prompt echo and our typed input readable.

So: for each candidate baud, open, send CR, and score how printable the reply is.
The baud with the highest printable ratio is the live one.

Usage: python -u scripts/uart_baud_sweep.py COM7
"""
import sys
import time

import serial

port = sys.argv[1] if len(sys.argv) > 1 else "COM7"
BAUDS = [115200, 57600, 38400, 28800, 19200, 9600, 4800, 2400, 300, 1200]

for b in BAUDS:
    try:
        s = serial.Serial(port, b, timeout=0.2)
    except Exception as e:  # noqa: BLE001
        print("baud %-7d OPEN FAILED %s" % (b, e), flush=True)
        continue
    s.dtr = False
    s.rts = False
    time.sleep(0.2)
    s.reset_input_buffer()
    s.write(b"\r")
    time.sleep(0.5)
    s.write(b"root\r")
    t0 = time.time()
    buf = b""
    while time.time() - t0 < 1.5:
        d = s.read(4096)
        if d:
            buf += d
    s.close()
    printable = sum(1 for c in buf if 32 <= c < 127 or c in (10, 13))
    ratio = printable / max(len(buf), 1)
    txt = "".join(chr(c) if 32 <= c < 127 else "." for c in buf[:70])
    print("baud %-7d bytes=%-5d printable=%.2f | %s" % (b, len(buf), ratio, txt), flush=True)
