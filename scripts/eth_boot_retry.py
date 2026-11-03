#!/usr/bin/env python3
"""eth_boot_retry.py -- 反复"重烧比特流 + 用网口灌四镜像"，直到控制台出现引导标记。

为什么需要重试：链路/PHY 有 ~0.04%/包 的偶发丢包（实测：厂家栈自报 9 轮少 24 包，
≈2.7 包/轮），而 EthLoader 的放核判据是**整幅全局 xor**（fail-safe）⇒ 一轮 6203 包
单次成功率只有约 e^-2.7 ≈ 7%。失败时 loader 会 latch 失败并把总线交给串口装载器，
所以**每轮必须重烧**才能复位它的状态（除非将来加一个"重装帧"）。

判据（不用眼睛看）：控制台在 115200 下出现**连续可打印 ASCII** ⇒ 已放核且 OS 在
打印（未放核时线上是 UartLoader 以 28.9k 波特 ACK 噪声被 115200 采成的固定 4 值图案，
一个可打印字符都没有）。命中 `MARKERS` 任一即算成功并落盘控制台日志。

用法： python scripts/eth_boot_retry.py [max_attempts=25] [rate=3000] [read_s=45]
"""
import os
import re
import subprocess
import sys
import time

import serial

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COM = "COM7"
BAUD = 115200
FLASH_TCL = os.path.join(ROOT, "pds/flash_ethloader.tcl")
CDT = "C:/pango/PDS_2025.2-ads/bin/cdt_cfg_shell.exe"
SENDER = os.path.join(ROOT, "scripts/eth_load_images.py")
LOG_DIR = os.path.join(ROOT, "sim/reglogs")
HOST_IP = "192.168.1.105"
BOARD_IP = "192.168.1.11"

# 判据串：先出现的是 OpenSBI banner，最后出现的是 P1 主判据（用户态 marker）
MARKERS = [b"OpenSBI", b"Linux version", b"VEXIIYESHEN-OK"]


def sh(cmd, timeout=180):
    p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
    return (p.returncode, (p.stdout or "") + (p.stderr or ""))


def flash():
    rc, out = sh(f'"{CDT}" -file "{FLASH_TCL}"')
    ok = "done bit" in out and "done bit): 1" in out
    return ok, out.strip().splitlines()[-1] if out.strip() else ""

def warm_arp():
    sh(f'ping -n 2 -S {HOST_IP} {BOARD_IP}', timeout=30)

def send(rate, restart=False):
    extra = " --restart" if restart else ""
    rc, out = sh(f'python "{SENDER}" --rate {rate}{extra}', timeout=300)
    return rc == 0, out.strip().splitlines()[-3:] if out.strip() else []


def main():
    attempts = int(sys.argv[1]) if len(sys.argv) > 1 else 25
    rate = int(sys.argv[2]) if len(sys.argv) > 2 else 3000
    read_s = float(sys.argv[3]) if len(sys.argv) > 3 else 45.0

    ser = serial.Serial(COM, BAUD, timeout=0.05)
    print(f"listening {COM} @{BAUD}; up to {attempts} attempts, rate={rate} pkt/s", flush=True)

    for att in range(1, attempts + 1):
        t0 = time.perf_counter()
        if att == 1:
            ok, line = flash()                      # 只有第 1 轮需要烧：之后靠重装帧复位
            if not ok:
                print(f"[{att}] FLASH FAIL: {line}", flush=True)
                continue
        if att == 1 or att % 20 == 0:
            warm_arp()
        while ser.in_waiting:
            ser.read(ser.in_waiting)                      # 丢掉上一轮残留
        rc, tail = send(rate, restart=(att > 1))
        if not rc:
            print(f"[{att}] SEND FAIL: {tail}", flush=True)
            continue
        buf = bytearray()
        t_end = time.perf_counter() + read_s
        hit = None
        while time.perf_counter() < t_end:
            d = ser.read(4096)
            if d:
                buf += d
                for m in MARKERS:
                    if m in buf:
                        hit = m
                        break
                if hit:
                    break
        dt = time.perf_counter() - t0
        if hit:
            path = os.path.join(LOG_DIR, f"boot_success_att{att}.log")
            print(f"[{att}] *** 成功：命中 {hit.decode()}（{dt:.1f}s，控制台已收 {len(buf)} 字节）"
                  f" 日志 {path} ***", flush=True)
            # 再多收一会儿，把后面的引导日志也落盘
            t2 = time.perf_counter() + 20
            while time.perf_counter() < t2:
                d = ser.read(4096)
                if d:
                    buf += d
            with open(path, "wb") as f:
                f.write(bytes(buf))
            print(f"[{att}] 最终日志 {len(buf)} 字节 -> {path}", flush=True)
            return 0
        printable = sum(1 for b in buf if 32 <= b < 127)
        fpath = os.path.join(LOG_DIR, f"boot_fail_att{att}.raw")
        with open(fpath, "wb") as f:
            f.write(bytes(buf))
        # 顺带把"可打印片段"打出来，便于判断这条通路在打什么
        runs, cur = [], bytearray()
        for b in buf:
            if 32 <= b < 127 or b in (10, 13):
                cur.append(b)
            else:
                if len(cur) >= 6:
                    runs.append(cur.decode("latin1"))
                cur = bytearray()
        if len(cur) >= 6:
            runs.append(cur.decode("latin1"))
        print(f"[{att}] 未放核（{dt:.1f}s，收到 {len(buf)} 字节，可打印 {printable}，"
              f"可打印串 {len(runs)} 条）-> {fpath}", flush=True)
        for r in runs[:6]:
            print("       |" + r[:120].replace("\r", "\\r").replace("\n", "\\n") + "|", flush=True)
    print("用尽尝试次数仍未成功", flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
