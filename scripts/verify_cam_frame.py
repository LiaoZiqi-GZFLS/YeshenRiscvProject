#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_cam_frame.py -- 一条命令取整帧并出取证指标（相机画面判据）。

为什么要它：相机画面是"人眼看 + 指标对账"两件事，但每次上板手动敲
`ifconfig eth0 down` / `devmem ... ETH_EN` / 读两块 1.2 MB / 再交还网络，
容易漏掉最后一步把网络留在 H2 服务手里。本脚本把这一串绑成一次，
**并且 finally 里一定交还网络**。

通路：H2 硬件读存服务（`eth_memread.read_mem`）——819 KB 约 0.1-0.24 s，
比 ssh 分块（~33 KB/s，还会断）快两个数量级。单笔请求上限实测约 256 KB，
所以按 256 KB 分块。

读数口径：帧存 1024x600 RGB565，两个 bank 各 16 MiB 步长，基址 0x9000_0000。
（`grab_cam.py --path hw` 自带的 640x640 窗口对 1024x600 帧存是错的，别用。）

判据（打印出来，别只看"没报错"）：
  · impulse%   与左右邻都不同、而左右邻相同的像素占比 —— 花屏时约 3.5%
  · uniq565    不同 RGB565 值个数 —— 花屏/近乎无信号时只有两三百
  · chroma     mean|R-G| / mean|B-G|
  · R=0 比例   非黑像素里 R 恰好为 0 的占比（"只毁颜色"的直接指征）

用法：
  python -u scripts/verify_cam_frame.py                 # 两个 bank 都读
  python -u scripts/verify_cam_frame.py --bank 1 --outdir cam_chk
"""
import argparse
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

W, H = 1024, 600
FB_BASE = 0x90000000
BANK_STRIDE = 0x01000000
N = W * H * 2
CHUNK = 256 * 1024


def sh(args, timeout=180):
    p = subprocess.run(args, cwd=ROOT, capture_output=True, text=True,
                       errors="replace", timeout=timeout)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def guest(com, baud, *cmds, timeout=180):
    rc, out = sh([sys.executable, "-u", "scripts/guest_cmd.py", com, str(baud)] + list(cmds),
                 timeout=timeout)
    return rc, out


def read_bank(board, bank):
    import eth_memread
    addr = FB_BASE + bank * BANK_STRIDE
    buf = bytearray()
    for off in range(0, N, CHUNK):
        n = min(CHUNK, N - off)
        b = eth_memread.read_mem(board, addr + off, n, timeout=0.30,
                                retries=8, verbose=False)
        if len(b) != n:
            raise RuntimeError("bank%d off=%d 只收到 %d/%d 字节" % (bank, off, len(b), n))
        buf += b
    return bytes(buf)


def metrics(b):
    rg = bg = m = imp = tot = 0
    uniq = set()
    nz = rz = 0
    for y in range(H):
        base = y * W * 2
        prev = None
        for x in range(W):
            i = base + x * 2
            w = b[i] | (b[i + 1] << 8)
            r = ((w >> 11) & 0x1F) << 3
            g = ((w >> 5) & 0x3F) << 2
            bl = (w & 0x1F) << 3
            uniq.add(w)
            if w:
                nz += 1
                if r == 0:
                    rz += 1
            if prev is not None:
                rg += abs(r - prev[0])
                bg += abs(bl - prev[1])
                m += 1
            prev = (r, bl)
            if 0 < x < W - 1:
                i0 = i - 2
                i2 = i + 2
                a = b[i0] | (b[i0 + 1] << 8)
                d = b[i2] | (b[i2 + 1] << 8)
                if a == d and w != a:
                    imp += 1
                tot += 1
    return dict(chroma_rg=rg / m, chroma_bg=bg / m, impulse=100.0 * imp / tot,
                uniq565=len(uniq), nonzero=100.0 * nz / (W * H),
                r_zero_pct=(100.0 * rz / nz if nz else 0.0))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--com", default="COM7")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--board", default="192.168.1.110")
    ap.add_argument("--bank", default="both", choices=["both", "0", "1"])
    ap.add_argument("--outdir", default="cam_chk")
    a = ap.parse_args()

    outdir = os.path.join(ROOT, a.outdir)
    os.makedirs(outdir, exist_ok=True)

    print("== 1/4 串口登录 ==", flush=True)
    rc, out = sh([sys.executable, "-u", "scripts/uart_login_pw.py", a.com, str(a.baud), "yeshen"],
                 timeout=240)
    print("  login rc=%d%s" % (rc, "" if "LOGGED IN" in out else "（可能已经登录，继续）"), flush=True)
    rc, out = guest(a.com, a.baud, "id")
    if "uid=0" not in out:
        print("  !! 拿不到 root 壳，放弃（先看 UART 是否在 login:）", flush=True)
        return 2

    print("== 2/4 交出 MAC 给 H2 读存服务 ==", flush=True)
    eth_was_down = False
    try:
        guest(a.com, a.baud, "ifconfig eth0 down")
        rc, out = guest(a.com, a.baud, "devmem 0xF0007494 32 1", "devmem 0xF0007494 32")
        if "0x00000001" not in out:
            print("  !! ETH_EN 没置起来：\n" + out, flush=True)
            return 3
        eth_was_down = True
        print("  ETH_EN=1", flush=True)

        print("== 3/4 读整帧 ==", flush=True)
        banks = [0, 1] if a.bank == "both" else [int(a.bank)]
        for bk in banks:
            b = read_bank(a.board, bk)
            raw = os.path.join(outdir, "vfy_b%d.bin" % bk)
            open(raw, "wb").write(b)
            mt = metrics(b)
            print("  bank%d  bytes=%d  zeros=%.2f%%  nonzero=%.2f%%" %
                  (bk, len(b), 100.0 * b.count(0) / len(b), mt["nonzero"]), flush=True)
            print("         chroma R-G=%.1f B-G=%.1f  impulse=%.2f%%  uniq565=%d  R=0占比=%.1f%%"
                  % (mt["chroma_rg"], mt["chroma_bg"], mt["impulse"], mt["uniq565"],
                     mt["r_zero_pct"]), flush=True)
            try:
                from PIL import Image
                im = Image.new("RGB", (W, H))
                px = im.load()
                for y in range(H):
                    base = y * W * 2
                    for x in range(W):
                        i = base + x * 2
                        w = b[i] | (b[i + 1] << 8)
                        px[x, y] = (((w >> 11) & 0x1F) << 3, ((w >> 5) & 0x3F) << 2,
                                    (w & 0x1F) << 3)
                png = os.path.join(outdir, "vfy_b%d.png" % bk)
                im.save(png)
                print("         -> %s" % png, flush=True)
            except Exception as e:
                print("         (PNG 跳过: %s)" % e, flush=True)
        print("== 4/4 交还网络 ==", flush=True)
        return 0
    finally:
        if eth_was_down:
            guest(a.com, a.baud, "devmem 0xF0007494 32 0", "ifconfig eth0 up")
            print("  已交还（ETH_EN=0 + eth0 up）", flush=True)


if __name__ == "__main__":
    sys.exit(main())