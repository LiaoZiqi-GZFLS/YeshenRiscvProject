#!/usr/bin/env python3
"""sd_load_measure.py -- read the board UART at 115200 and time the TF-card load.

Why: the loader prints `SDR <18 hex>` every 100 ms while it owns the line
(hex[0:2] = {state(4), err(4)}, state: 0=idle 1=table 2=copy 3=done 4=fail).
The gap between the first `state=2` and the first `state=3` is the data phase,
which is exactly what the 5 -> 25 MHz change is supposed to shrink.

Usage (Windows console is GBK: nothing non-ASCII is ever printed):
  python -u scripts/sd_load_measure.py COM7 30        # 30 s window, card in
  python -u scripts/sd_load_measure.py COM7 12 --no-card

Judgement printed at the end (all ASCII):
  RESULT card   ok   state3 @  3.9s  data_phase= 3.4s  errs=[...]
  RESULT no-card FAIL state4 err=1  (expected: card missing/unseated)
"""
import sys
import time

import serial

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM7"
SECS = float(sys.argv[2]) if len(sys.argv) > 2 else 20.0
BAUD = 115200
NO_CARD = "--no-card" in sys.argv


def emit(s):
    sys.stdout.write(s.encode("ascii", "replace").decode("ascii") + "\n")
    sys.stdout.flush()


ser = serial.Serial(PORT, BAUD, timeout=0.1)
ser.reset_input_buffer()
ser.write(b"\x11")                      # ^Q: the console tty has IXON; a stray ^S would look like silence
t0 = time.time()
end = t0 + SECS
buf = b""
rows = []                               # (t, kind, payload)
ylsl = 0
while time.time() < end:
    d = ser.read(512)
    if not d:
        continue
    buf += d
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        line = line.strip(b"\r")
        t = time.time() - t0
        if line.startswith(b"SDR "):
            hexs = line[4:].split()[0].decode("ascii", "replace") if line[4:].split() else ""
            if len(hexs) >= 2:
                try:
                    st = int(hexs[0:2], 16) >> 4
                    er = int(hexs[0:2], 16) & 0xF
                    rows.append((t, st, er))
                except ValueError:
                    pass
        elif line.startswith(b"YSLD"):
            ylsl += 1
        elif line and not line.startswith(b"SDR"):
            txt = line.decode("ascii", "replace")
            if "Linux" in txt or "OpenSBI" in txt or "Y1CAM" in txt:
                rows.append((t, "log", txt[:60]))

states = [(t, st, er) for (t, st, er) in rows if isinstance(st, int)]
first = {}
for t, st, er in states:
    first.setdefault(st, (t, er))
errs = sorted({er for (_, _, er) in states if er})

if not states:
    emit(f"RESULT {SECS:g}s window: no SDR line (SD loader never owned the line)")
    emit(f"       YSLD repeats={ylsl}, other lines={sum(1 for r in rows if r[1] == 'log')}")
    raise SystemExit(1 if NO_CARD else 2)

emit(f"# {SECS:g}s window @{PORT} {BAUD}: {len(states)} SDR lines, YSLD repeats={ylsl}")
for st, (t, er) in sorted(first.items(), key=lambda kv: kv[1][0]):
    emit(f"  state={st} first at {t:6.2f}s  (err={er})")
if 2 in first and 3 in first:
    emit(f"  data phase (state2 -> state3) = {first[3][0] - first[2][0]:.2f}s")
if 3 in first:
    emit(f"  load done at {first[3][0]:.2f}s, errs seen={errs or [0]}")
    emit(f"RESULT card ok  state3@{first[3][0]:.2f}s  data_phase={first[3][0] - first.get(2, (first[3][0], 0))[0]:.2f}s  errs={errs or [0]}")
    raise SystemExit(0)
if 4 in first:
    emit(f"RESULT card FAIL state=4 err={first[4][1]} (7=header CRC 8=seg CRC 1=SD path 2=magic 3=count 4=entry)")
    raise SystemExit(0 if NO_CARD and first[4][1] == 1 else 3)
emit("RESULT inconclusive (no state 3 or 4 in window)")
raise SystemExit(4)
