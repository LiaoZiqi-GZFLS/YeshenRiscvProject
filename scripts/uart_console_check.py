#!/usr/bin/env python3
"""uart_console_check.py -- judge whether the UART console is usable as a COMMAND LINE.

What it asserts (and why this is the right criterion):
  The tty echoes every character it receives. So if we send a known long payload and the
  echo comes back BYTE-FOR-BYTE identical, then RX is lossless -- which is what makes an
  interactive shell possible at all. A single dropped byte (the failure mode of a 1-byte
  RX register polled by the 8250 backup timer) shows up immediately as a mismatch.

Method: wake -> login (root, empty password) -> send `echo <PATTERN>` -> compare echo.
Line wrapping inserts CR/LF, so both sides are stripped of CR/LF before the compare.

Negative control (must go red): run the SAME script against the image with the serial node
  left at irq=0 (sw/images/sd_irq0_negctl.img). It must report FAIL.
  -> scripts/uart_console_check.py COM7            # expects PASS
  -> scripts/uart_console_check.py COM7 --expect fail   # negative-control arm

Exit code: 0 iff the observed verdict equals the expected one.
"""
import argparse
import re
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("pyserial missing: pip install pyserial")

# 36 chars x 6 = 216 chars of payload (>= 200), all shell-safe
PATTERN = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ" * 6
PAYLOAD = "echo " + PATTERN


def drain(s, seconds, sink):
    end = time.time() + seconds
    buf = b""
    while time.time() < end:
        d = s.read(4096)
        if d:
            buf += d
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                sink.append(line.decode("ascii", "replace").rstrip("\r"))
    if buf:
        sink.append(buf.decode("ascii", "replace"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("port")
    ap.add_argument("--expect", choices=["pass", "fail"], default="pass")
    ap.add_argument("--baud", type=int, default=115200)
    a = ap.parse_args()

    s = serial.Serial(a.port, a.baud, timeout=0.2)
    s.reset_input_buffer()
    seen = []

    print("== wake ==", flush=True)
    s.write(b"\r")
    drain(s, 2, seen)

    print("== login (root / empty password) ==", flush=True)
    s.write(b"root\r")
    drain(s, 2, seen)
    s.write(b"\r")
    drain(s, 3, seen)

    print("== send %d-byte payload ==" % len(PAYLOAD), flush=True)
    s.write(PAYLOAD.encode() + b"\r")
    drain(s, 6, seen)
    s.close()

    text = "\n".join(seen)
    # Windows console is GBK: never print decoded bytes raw (a replacement char crashes it).
    with open("sim/reglogs/uart_console_raw.txt", "w", encoding="utf-8") as fh:
        fh.write(text)
    safe = text.encode("ascii", "replace").decode("ascii")
    print("--- received (%d lines) ---" % len(seen), flush=True)
    print(safe, flush=True)
    print("--- end (raw also saved to sim/reglogs/uart_console_raw.txt) ---", flush=True)

    # Line wrapping inserts CR/LF; strip all whitespace before comparing, because a dropped
    # character changes the reconstructed string while wrapping does not.
    flat_rx = re.sub(r"\s+", "", text)
    flat_tx = re.sub(r"\s+", "", PAYLOAD)
    got_echo = flat_tx in flat_rx

    # A second, independent signal: the shell must have actually run the command, i.e. the
    # echoed OUTPUT (not just the input echo) must appear too. Count occurrences.
    n_pat = flat_rx.count(re.sub(r"\s+", "", PATTERN))

    verdict = "PASS" if (got_echo and n_pat >= 2) else "FAIL"
    print("echo_byte_identical=%s  payload_occurrences=%d (>=2 means both the echo AND the "
          "command output came back)" % (got_echo, n_pat), flush=True)
    print("=== CONSOLE %s ===" % verdict, flush=True)

    want = a.expect.upper()
    if verdict == want:
        print("=> verdict matches expectation (%s); exit 0" % want, flush=True)
        return 0
    print("=> verdict %s but expected %s; exit 1" % (verdict, want), flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
