#!/usr/bin/env python3
"""load_images.py -- push the four images into DDR via the on-board UART loader, then release the CPU.

Protocol (from src/peripheral/UartLoader.scala):
  frame = 'W' + addr[4B BE] + len[4B BE] + data[len] + xor8
    . every byte EXCEPT the trailing checksum byte is ACKed with 0x06
    . the checksum byte is answered 'K' (ok) / 'E' (bad)
    . xor8 = XOR over the DATA bytes only
    . addr MUST be 32B aligned
  'J' -> 'K' then the CPU is released;  '?' -> 'Y'

Why Python (not the PowerShell twin): the loader needs a small guard after each ACK before the
next byte; Windows' 15.6ms timer granularity makes sub-ms pacing impossible in PowerShell, and the
8.7 MB payload would take tens of hours.  Here the guard is a perf_counter busy-wait.

Usage:
  python load_images.py --port COM7 [--root D:/.../sw/images] [--guard-us 300]
                        [--only linux.dtb] [--no-jump] [--console-s 120]
"""
import argparse
import os
import sys
import time

import serial  # pyserial

IMAGES = [
    ("fw_jump.bin", 0x80000000),
    ("Image",       0x82000000),
    ("linux.dtb",   0x82F80000),
    ("rootfs.cpio", 0x83000000),
]
ACK, K, E, Y = 0x06, 0x4B, 0x45, 0x59
BANNER = {ord(c) for c in "YSLD\n"}


def busydelay(seconds):
    if seconds <= 0:
        return
    t_end = time.perf_counter() + seconds
    while time.perf_counter() < t_end:
        pass


def drain_quiet(ser, quiet=0.6, max_s=8.0):
    t0 = time.perf_counter()
    last = t0
    while time.perf_counter() - t0 < max_s:
        n = ser.in_waiting
        if n:
            ser.read(n)
            last = time.perf_counter()
        elif time.perf_counter() - last > quiet:
            return
        else:
            time.sleep(0.05)


class Loader:
    def __init__(self, ser, guard_us):
        self.ser = ser
        self.guard = guard_us / 1e6
        self.skipped = 0
        self.n_sent = 0      # bytes written to the port
        self.n_read = 0      # bytes read back (ACKs + strays)
        self.n_stray = 0     # bytes that were neither ACK nor K/E (banner etc.)
        self.flash_tcl = ""  # set from --flash-tcl; used to hard-reset a stuck loader

    def send_expect(self, b, want, ctx, tries=3):
        """Send one byte, then read until `want` arrives (tolerating banner strays).

        NOTE: do NOT flush the input buffer per byte -- the loader ACKs exactly once per byte, and
        a flush racing with a late ACK would make us re-send that byte (duplicate) and break the
        frame checksum (observed as 'E' after an otherwise perfect 1323-byte frame).
        """
        for t in range(tries):
            self.ser.write(bytes([b]))
            self.n_sent += 1
            # Was 60 s (sized for the old 115200 link).  On the slow 28/28800 link a lost ACK would
            # otherwise cost 4x60 s before the frame is retried -- minutes of dead air per glitch.
            deadline = time.perf_counter() + 5.0
            while time.perf_counter() < deadline:
                r = self.ser.read(1)
                if not r:
                    break
                v = r[0]
                self.n_read += 1
                if v == want:
                    busydelay(self.guard)
                    return
                if v in BANNER:
                    self.skipped += 1
                    self.n_stray += 1
                    continue
                raise SystemExit(f"ctx={ctx} want {want:02X} got {v:02X}")
            print(f"   timeout retry {t} ({ctx})", flush=True)
        raise SystemExit(f"ctx={ctx} wait {want:02X} failed")

    def probe(self):
        drain_quiet(self.ser)
        self.ser.write(bytes([0x3F]))
        deadline = time.perf_counter() + 5.0
        while time.perf_counter() < deadline:
            r = self.ser.read(1)
            if r and r[0] == Y:
                print(f"probe OK ('?' -> 'Y'), skipped {self.skipped} banner bytes", flush=True)
                return
        raise SystemExit("probe failed: no 'Y'")

    def flush(self, max_bytes=1024):
        """A skew leaves the loader stuck in pData, which it only leaves by finishing the frame.
        Feed dummy data bytes until it answers K/E (returning it to the command state).  The dummy
        writes land inside the region we are about to rewrite, so they are harmless."""
        dummy = bytes([0xA5]) * 16
        sent = 0
        while sent < max_bytes:
            self.ser.write(dummy)
            self.n_sent += 16
            sent += 16
            # Was 0.25 s per 16-byte chunk -> up to 135 s of silent dead air per stuck frame.
            # The loader only needs enough dummy bytes to finish its partial frame; ~1 KB at a
            # 30 ms per-chunk wait is plenty and keeps a bad frame's recovery ~2 s.
            t_end = time.perf_counter() + 0.03
            while time.perf_counter() < t_end:
                r = self.ser.read(1)
                if not r:
                    break
                self.n_read += 1
                if r[0] in (K, E):
                    return True
        return False

    def reflash(self):
        """Hard reset: reconfiguring the FPGA resets the loader's frame state machine.  Costs ~10s."""
        if not self.flash_tcl:
            return False
        import subprocess
        print("    -> hard reset: re-flashing bitstream to clear the loader state", flush=True)
        subprocess.run([r"C:/Pango/PDS_2025.2-ads/bin/cdt_cfg_shell.exe", "-file", self.flash_tcl],
                       capture_output=True)
        time.sleep(1.5)
        self.ser.read(self.ser.in_waiting)
        return True

    def resync(self):
        """Handshake check: the loader answers 'Y' ONLY in its command state.  Run before every
        frame so that each frame starts from a verified clean state (otherwise a single stray byte
        skews the exchange and every later frame dies on "checksum got 06")."""
        self.ser.read(self.ser.in_waiting)
        busydelay(self.guard)
        self.ser.write(bytes([0x3F]))
        deadline = time.perf_counter() + 2.0
        while time.perf_counter() < deadline:
            r = self.ser.read(1)
            if r and r[0] == Y:
                busydelay(self.guard * 4)
                self.ser.read(self.ser.in_waiting)
                return True
        return False

    def ensure_cmd_state(self):
        """Get the loader back to its command state after any failure, escalating only as far as
        needed: an idle '?' -> 'Y' ping, then dummy-byte flush, then a bitstream reflash (a full
        reconfigure is the only thing that clears a frame stuck waiting on a corrupted length)."""
        if self.resync():
            return True
        self.flush()
        if self.resync():
            return True
        self.reflash()
        return self.resync()

    def frame_checked(self, addr, data, tries=6):
        """Send one <=chunk frame, retrying the WHOLE frame on 'E' (checksum) or a stall.

        The host->board link shows a low-rate byte corruption (caught by the loader's xor8), so
        keep frames small and retry per frame: a retry rewrites the same 32B-aligned group, so
        partial writes are harmless.  A corrupted header byte can instead leave the loader
        mid-frame, which is why EVERY failure (including a failed entry resync) goes through the
        same recovery ladder rather than bailing out.
        """
        for t in range(tries):
            s0, r0, y0 = self.n_sent, self.n_read, self.n_stray
            if not self.ensure_cmd_state():
                raise SystemExit(f"frame @ {addr:#010X}: loader unrecoverable before send")
            try:
                self.frame(addr, data)
                if t:
                    print(f"    (retry ok after {t})", flush=True)
                return
            except SystemExit as ex:
                if not self.ensure_cmd_state():
                    raise SystemExit(f"frame @ {addr:#010X}: loader unrecoverable")
                print(f"    frame retry {t+1}/{tries} @ {addr:#010X}: {ex}"
                      f"   [ACCT] sent={self.n_sent-s0} read={self.n_read-r0}"
                      f" stray={self.n_stray-y0} (read-sent={self.n_read-r0-(self.n_sent-s0):+d})", flush=True)
        raise SystemExit(f"frame @ {addr:#010X} failed after {tries} tries")

    def frame(self, addr, data):
        assert addr & 0x1F == 0, f"addr not 32B aligned: {addr:#x}"
        length = len(data)
        x = 0
        for b in data:
            x ^= b
        hdr = bytes([0x57,
                     (addr >> 24) & 0xFF, (addr >> 16) & 0xFF, (addr >> 8) & 0xFF, addr & 0xFF,
                     (length >> 24) & 0xFF, (length >> 16) & 0xFF, (length >> 8) & 0xFF, length & 0xFF])
        t0 = time.perf_counter()
        s0, r0, y0 = self.n_sent, self.n_read, self.n_stray
        for b in hdr:
            self.send_expect(b, ACK, "hdr")
        sent = 0
        for b in data:
            self.send_expect(b, ACK, "data")
            sent += 1
            if sent % 32 == 0:
                el = time.perf_counter() - t0
                print(f"    {sent}/{length} B  {el:.1f}s  {sent/1024/el:.1f} KB/s", flush=True)
        # checksum byte: answered K/E (no 0x06)
        self.send_expect(x, K, "xor8")
        # The 32nd data byte of a group has its ACK DEFERRED until the 32B burst completes, and on a
        # chunk-boundary frame that ACK can land AFTER the K -> a strict one-send-one-read host then
        # desyncs by one byte and the next frame dies on "checksum got 06".  Drain it here.
        busydelay(self.guard * 10)
        # Must keep chunk == 32 (addresses must stay 32B aligned), so absorb the deferred ACK of the
        # 32nd byte that can land after the K: read until the line is quiet for ~3ms (max 40ms).
        t_end = time.perf_counter() + 0.04
        quiet_until = time.perf_counter() + 0.003
        while time.perf_counter() < t_end:
            n = self.ser.in_waiting
            if n:
                self.ser.read(n)
                quiet_until = time.perf_counter() + 0.003
            elif time.perf_counter() > quiet_until:
                break
            else:
                busydelay(0.0002)
        el = time.perf_counter() - t0
        d_sent, d_read = self.n_sent - s0, self.n_read - r0
        if d_read != d_sent:
            print(f"    [ACCT] @{addr:#010X} sent={d_sent} read={d_read} stray={self.n_stray - y0}"
                  f"  (read-sent={d_read - d_sent:+d})", flush=True)
        else:
            print(f"    OK {length} B  {el:.1f}s  {length/1024/el:.1f} KB/s", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM7")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--root", default="D:/code/PDS/NaxYeshenLinux/sw/images")
    ap.add_argument("--guard-us", type=int, default=300)
    ap.add_argument("--only", default="")
    ap.add_argument("--no-jump", action="store_true")
    ap.add_argument("--console-s", type=float, default=120.0)
    ap.add_argument("--console-baud", type=int, default=115200)
    ap.add_argument("--console-sweep", default="", help="comma list of bauds to try on the console (overrides --console-baud)")
    ap.add_argument("--flash-tcl", default="", help="re-flash this tcl to hard-reset the loader on a stuck skew")
    # 31 (not 32): a 32-byte frame ends exactly on the loader's write-group boundary, whose ACK is
    # DEFERRED until the burst completes and can then land AFTER the frame's K -> a strict
    # one-send-one-read host desyncs by one byte and every later frame dies on "checksum got 06".
    # 31 keeps every frame inside a partial group (flushed by pTail), so the ACK order is clean.
    ap.add_argument("--chunk", type=int, default=32)
    a = ap.parse_args()

    ser = serial.Serial(a.port, a.baud, timeout=1, write_timeout=2.0)
    print(f"PORT {a.port} opened @ {a.baud}  guard={a.guard_us}us", flush=True)
    ld = Loader(ser, a.guard_us)
    ld.flash_tcl = a.flash_tcl
    ld.probe()

    for name, addr in IMAGES:
        if a.only and name != a.only:
            continue
        path = os.path.join(a.root, name)
        if not os.path.exists(path):
            raise SystemExit(f"missing {path}")
        data = open(path, "rb").read()
        print(f"==> {name}: {len(data)} B @ {addr:#010X}  (chunk={a.chunk})", flush=True)
        for off in range(0, len(data), a.chunk):
            ld.frame_checked(addr + off, data[off:off + a.chunk])

    if not a.no_jump:
        print("==> 'J' releasing CPU (console goes back to the SoC)", flush=True)
        ld.send_expect(0x4A, K, "J")
        print("CPU released.", flush=True)

    if a.console_sweep:
        # A looping probe keeps transmitting, so we can change the host baud on the fly and look
        # for the marker in each candidate.  Useful when the SoC console rate is only nominal
        # (PLL/FDC discrepancy) and the exact divisor is unknown.
        bauds = [int(b) for b in a.console_sweep.split(",") if b.strip()]
        want = os.environ.get("SWEEP_WANT", "NAXMINI")
        for b in bauds:
            ser.baudrate = b
            time.sleep(0.2)
            ser.read(ser.in_waiting)          # drop the previous-baud garbage
            out = bytearray()
            t0 = time.perf_counter()
            while time.perf_counter() - t0 < 2.0:
                n = ser.in_waiting
                if n:
                    out += ser.read(n)
                else:
                    time.sleep(0.02)
            txt = "".join(chr(c) if 32 <= c < 127 or c == 10 else "." for c in out)
            hit = want in txt
            print(f"--- baud {b}: {len(out)} B  marker={hit}  hex[:64]={bytes(out[:64]).hex()}")
            print(txt[:300])
            if hit:
                print(f"*** console rate = {b} ***", flush=True)
                break
        ser.close()

    elif a.console_s > 0:
        # The LOADER talks at --baud, but after 'J' the SoC console (8250) runs at whatever the
        # firmware/kernel programmed (115200 in our images).  Switch, or the capture is garbage.
        if a.console_baud != a.baud:
            ser.baudrate = a.console_baud
            print(f"=== console baud -> {a.console_baud} ===", flush=True)
            time.sleep(0.3)
            ser.read(ser.in_waiting)
        print(f"=== reading console for {a.console_s:.0f}s ===", flush=True)
        out = bytearray()
        t0 = time.perf_counter()
        while time.perf_counter() - t0 < a.console_s:
            n = ser.in_waiting
            if n:
                out += ser.read(n)
            else:
                time.sleep(0.05)
        ser.close()
        txt = "".join(chr(c) if 32 <= c < 127 or c == 10 else "." for c in out)
        print(f"=== console {len(out)} bytes ===")
        print(txt)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
