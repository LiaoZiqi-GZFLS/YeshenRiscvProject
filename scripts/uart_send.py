#!/usr/bin/env python3
"""uart_send.py -- drive the board console over UART: send lines, print whatever comes back.

Why this exists: `listen_uart.py` is read-only. To answer questions the board itself can
answer (e.g. "does eth0 have carrier?") we must type at the login prompt. This is the
minimal tool for that: no expect, no PTY magic -- just write a line, read for a while.

Usage:
    python -u scripts/uart_send.py <PORT> <read_seconds_per_line> LINE [LINE ...]
Example:
    python -u scripts/uart_send.py COM7 3 "root" "" "ip -s link show eth0"
Special:
    a LINE of exactly "\\r"  sends a bare CR (to get a fresh prompt)

Notes:
  * Always use `python -u` (unbuffered) or you will see nothing for minutes.
  * The console echoes what you type; that echo is printed too, prefixed with ">>".
"""
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("pyserial missing: pip install pyserial")


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    port = sys.argv[1]
    dwell = float(sys.argv[2])
    lines = sys.argv[3:]

    s = serial.Serial(port, 115200, timeout=0.2)
    print(f"# {port} @115200, {len(lines)} line(s), {dwell}s dwell each")

    def drain(seconds):
        end = time.time() + seconds
        buf = b""
        while time.time() < end:
            d = s.read(256)
            if d:
                buf += d
                while b"\n" in buf:
                    ln, buf = buf.split(b"\n", 1)
                    print(ln.decode("ascii", "replace").rstrip("\r"), flush=True)

    drain(1.0)
    for ln in lines:
        payload = b"\r" if ln == "\\r" else (ln + "\r").encode("ascii", "replace")
        print(f">> {ln!r}", flush=True)
        s.write(payload)
        drain(dwell)
    drain(1.0)
    s.close()


if __name__ == "__main__":
    main()
