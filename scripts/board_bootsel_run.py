#!/usr/bin/env python3
"""board_bootsel_run.py -- 重配置 FPGA（触发 BootSel 窗口）+ 窗口内发 L/C + 采集串口。

用法：
  python -u scripts/board_bootsel_run.py --key C --tag pnr_c4a_cpufast --secs 90
  python -u scripts/board_bootsel_run.py --key L --tag pnr_c4a_cpufast
  python -u scripts/board_bootsel_run.py --key C --no-flash        # 只发键 + 采集（需手动复位）

判据（打印，不静默）：
  · 看到 `[Y1] L=Linux C=CoreMark >` 提示；
  · key=C：看到 CoreMark 文本与 `crcfinal`（或 SD 失败/回退的报错）；
  · key=L：看到 Linux marker。
输出：sim/reglogs/bootsel_<key>.log（ASCII，替换非法字节）。
"""
import argparse
import os
import re
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PDS_BIN = os.environ.get("PDS_BIN", r"C:\Pango\PDS_2025.2-ads\bin")
LOG = os.path.join(ROOT, "sim", "reglogs")


def start_cdt(port):
    import socket
    s = socket.socket()
    try:
        s.settimeout(0.5)
        if s.connect_ex(("127.0.0.1", port)) == 0:
            return True
    finally:
        s.close()
    exe = os.path.join(PDS_BIN, "cdt_js.exe")
    if not os.path.exists(exe):
        print(f"FATAL: 缺 {exe}")
        return False
    subprocess.Popen([exe, "-port", str(port)], cwd=ROOT,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2.5)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--key", default="C", choices=["C", "L"])
    ap.add_argument("--tag", default="pnr_c4a_cpufast")
    ap.add_argument("--com", default="COM7")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--secs", type=float, default=90.0)
    ap.add_argument("--jtag-port", type=int, default=62000)
    ap.add_argument("--no-flash", action="store_true")
    a = ap.parse_args()

    import serial
    ser = serial.Serial(a.com, a.baud, timeout=0.05)
    out = []
    stop = False

    def reader():
        while not stop:
            try:
                d = ser.read(4096)
            except Exception:
                break
            if d:
                out.append(d)
    th = threading.Thread(target=reader, daemon=True)
    th.start()

    flash = None
    if not a.no_flash:
        if not start_cdt(a.jtag_port):
            return 2
        env = dict(os.environ, YESHENMINI_TAG=a.tag, YESHENMINI_JTAG_PORT=str(a.jtag_port))
        flash = subprocess.Popen(
            [os.path.join(PDS_BIN, "cdt_cfg_shell.exe"), "-file",
             os.path.join(ROOT, "pds", "flash_yeshen.tcl").replace("/", "\\")],
            env=env, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        # 编程期间 + 编程结束后 3s，持续发键（窗口只在配置完成后才开）
        t0 = time.time()
        while flash.poll() is None and time.time() - t0 < 120:
            ser.write(a.key.encode()); ser.flush()
            time.sleep(0.05)
        for _ in range(80):
            ser.write(a.key.encode()); ser.flush()
            time.sleep(0.05)
        fout = flash.stdout.read().decode("ascii", "replace") if flash.stdout else ""
        done = re.findall(r"done bit\):\s*(\d)", fout)
        print(f"[bootsel] flash done_bit={done[-1] if done else '?'}")

    # 采集
    t_end = time.time() + a.secs
    while time.time() < t_end:
        time.sleep(0.2)
    stop = True
    time.sleep(0.1)
    raw = b"".join(out)
    txt = raw.decode("ascii", "replace")
    path = os.path.join(LOG, f"bootsel_{a.key}.log")
    with open(path, "w", errors="replace") as f:
        f.write(txt)
    print(f"[bootsel] captured {len(raw)} B -> {path}")
    print("---- tail ----")
    print(txt[-2500:])
    print("---- verdicts ----")
    print("prompt   :", "YES" if "[Y1] L=Linux C=CoreMark" in txt else "NO")
    print("coremark :", "YES" if "crcfinal" in txt else "NO")
    print("linux    :", "YES" if "Linux version" in txt else "NO")
    crc = re.findall(r"crcfinal\s*:\s*0x([0-9a-fA-F]+)", txt)
    if crc:
        print("crcfinal :", ",".join(crc))
    ticks = re.findall(r"Total ticks\s*:\s*(\d+)", txt)
    if ticks:
        print("ticks    :", ",".join(ticks))
    return 0


if __name__ == "__main__":
    sys.exit(main())
