#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""grab_cam.py —— 一条命令从开发板抓一帧相机图，转成 PNG。

两条通路（默认 cpu）：
  cpu  ssh 触发板上 `/root/y1/y1cam --once --dump`（读帧存，640x640 RGB565）
       → `board_ssh.get_file` 分块拉回（**两侧 md5 对账**）→ 主机转 PNG。
       不动显示、不动网络，随时可用。
  hw   走 H2 硬件读存服务（`scripts/eth_memread.py` 的 read_mem）。
       ⚠️ 需**先**在 UART 控制台上做：
           ifconfig eth0 down
           devmem 0xF0007494 32 1
       抓完再 `devmem 0xF0007494 32 0` + `ifconfig eth0 up` 交还网络。

用法：
  python scripts/grab_cam.py                          # → cam_20261028_224500.png
  python scripts/grab_cam.py --out frame.png --keep-raw
  python scripts/grab_cam.py --bank 1                 # 抓另一个 bank
  python scripts/grab_cam.py --path hw --bank 0        # 硬件通路（ETH_EN 已开）

判据（打印出来，别只看"没报错"）：
  · 两侧 md5 一致（cpu 通路由 get_file 负责）
  · 图像统计：零字节占比 / 不同字节数 —— 全 0 或 85% 未写 = **读错了 bank**
    （帧存双 bank，屏显示的那个才是"活"的；2026-10-28 实测踩过）
"""
import argparse
import hashlib
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

W = H = 640
FRAME_BYTES = W * H * 2
BANK_STRIDE = 0x01000000          # 帧存 bank 跨度 16 MiB（字地址 bit22）
FB_BASE = 0x90000000


def log(msg):
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()


def to_png(raw, out_path):
    if len(raw) != FRAME_BYTES:
        raise SystemExit("frame size %d != %d (expect 640x640 RGB565)" % (len(raw), FRAME_BYTES))
    try:
        from PIL import Image
    except ImportError:
        raise SystemExit("need Pillow for PNG (pip install pillow); use --keep-raw to get the raw file")
    img = Image.new("RGB", (W, H))
    px = img.load()
    i = 0
    for y in range(H):
        for x in range(W):
            v = raw[i] | (raw[i + 1] << 8)
            i += 2
            px[x, y] = (((v >> 11) & 0x1F) * 255 // 31,
                        ((v >> 5) & 0x3F) * 255 // 63,
                        (v & 0x1F) * 255 // 31)
    img.save(out_path)


def stats(raw):
    head = raw[:81920]
    zero = sum(1 for b in head if b == 0)
    return zero, len(head), len(set(head))


def grab_cpu(remote_tool, remote_path, bank, timeout):
    """板上 y1cam --once --dump，返回 (raw_bytes, info_text)。"""
    import board_ssh
    bank_opt = (" --bank %d" % bank) if bank is not None else ""
    cmd = "%s --once --dump %s%s --quiet" % (remote_tool, remote_path, bank_opt)
    rc, out, err = board_ssh.run(cmd, timeout=timeout)
    if rc != 0:
        raise SystemExit("board y1cam failed rc=%s: %s" % (rc, (err or b"").decode("utf-8", "replace")[:300]))
    info = out.decode("utf-8", "replace").strip()
    ok, msg = board_ssh.get_file(remote_path, remote_path + ".host")
    if not ok:
        raise SystemExit("pull failed: %s" % msg)
    raw = open(remote_path + ".host", "rb").read()
    os.remove(remote_path + ".host")
    return raw, info + "\n" + msg


def grab_hw(board, bank, timeout, timeout_s):
    """硬件读存服务（ETH_EN 必须已由 UART 打开）。"""
    import eth_memread
    addr = FB_BASE + (bank or 0) * BANK_STRIDE
    raw = eth_memread.read_mem(board, addr, FRAME_BYTES, timeout=timeout_s,
                               verbose=False)
    return raw, "hw addr=0x%08X len=%d" % (addr, len(raw))


def main():
    ap = argparse.ArgumentParser(description="Grab one camera frame from the board as PNG")
    ap.add_argument("--path", choices=["cpu", "hw"], default="cpu")
    ap.add_argument("--board", default=os.environ.get("BOARD_IP", "192.168.1.110"))
    ap.add_argument("--out", default=None, help="output PNG (default cam_<timestamp>.png)")
    ap.add_argument("--bank", type=int, default=None, choices=[0, 1])
    ap.add_argument("--remote-tool", default="/root/y1/y1cam")
    ap.add_argument("--remote-path", default="/tmp/cam.bin")
    ap.add_argument("--keep-raw", action="store_true", help="also keep the .bin next to the PNG")
    ap.add_argument("--timeout", type=int, default=180, help="board command timeout (s)")
    ap.add_argument("--hw-timeout", type=float, default=0.30, help="hw path per-datagram timeout (s)")
    a = ap.parse_args()

    os.environ["BOARD_IP"] = a.board
    out_png = a.out or os.path.join(ROOT, "cam_%s.png" % time.strftime("%Y%m%d_%H%M%S"))

    t0 = time.time()
    if a.path == "cpu":
        raw, info = grab_cpu(a.remote_tool, a.remote_path, a.bank, a.timeout)
    else:
        raw, info = grab_hw(a.board, a.bank, a.timeout, a.hw_timeout)
    dt = time.time() - t0

    md5 = hashlib.md5(raw).hexdigest()
    to_png(raw, out_png)
    z, n, distinct = stats(raw)

    log("path      = %s" % a.path)
    for line in info.splitlines():
        if line.strip():
            log("board     = %s" % line.strip())
    log("bytes     = %d (md5 %s)" % (len(raw), md5))
    log("image     = %s  (%dx%d RGB565, %.2f s)" % (out_png, W, H, dt))
    log("stats     = zeros %d/%d (%.1f%%), distinct bytes %d" % (z, n, 100.0 * z / n, distinct))
    if z * 10 > n * 9:
        log("WARN      : >90%% zeros -- wrong bank, or camera not running (see docstring)")
    if a.keep_raw:
        raw_path = os.path.splitext(out_png)[0] + ".bin"
        with open(raw_path, "wb") as f:
            f.write(raw)
        log("raw       = %s" % raw_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
