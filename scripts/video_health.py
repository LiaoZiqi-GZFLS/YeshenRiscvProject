#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""video_health.py —— 视频通路「空闲 vs NPU 负载」的板端对账（只读 + 起停 y1cam）。

问题（2026-10-23）：集成版（CPU+NPU+摄像头+屏幕）画质比单独 cam 版明显下降。
`rd_buf` 的结构决定嫌疑：**每显示行只提前一行发一次取数请求，显示侧不看 valid/ready**
（取数被拖慢 ⇒ 屏幕读到环形缓冲里的旧内容 ⇒ 撕裂/花屏）。

寄存器（board/cam/video_regs.v）：
  VIDEO_BASE 0xF0007400 +0x000 STATUS：[0] init_done / [1] 写 bank / [31:8] 24-bit 帧序号
                        +0x004 DBG    ：[15:0] 视频读请求等待计数（来自仲裁器 32 位计数器的低 16 位）

⚠️ 计数器只有 16 位：满量程 65,536 拍 = 0.655 ms。所以本工具**不做跨窗口速率换算**，
只做两种可判读的采样：
  · `delta`：窗口内 Δ 未回卷（Δ<65536/2）⇒ 等待拍数可信；
  · `WRAPPED`：Δ 已回卷 ⇒ 只能证明"等待很多"，具体值不可用。
空闲时预期 Δ=0（视频读每个行消隐期独占 DDR）；负载下若 Δ>0 ⇒ 视频读被 NPU 拖住。

协议（同一块板/同一会话）：
  1) idle：y1cam 不在跑，采样两次；
  2) loaded：起 y1cam --loop，settle 秒后采样两次；
  3) 停 y1cam，再采样一次（回空闲）。
判读：
  · idle Δ=0、loaded Δ>0 ⇒ **DDR 仲裁/带宽**是画质下降的直接机制；
  · 两边 Δ=0 而画面仍差 ⇒ 与 NPU 无关，查静态差异（裁列 128..1151 / ROW_OFFSET=60 / 时钟域）。

用法：
  python -u scripts/video_health.py
  python -u scripts/video_health.py --window 0.2 --settle 5
  python -u scripts/video_health.py --no-npu          # 只测空闲（负对照）
"""
import argparse
import re
import sys
import time

import board_ssh as BS

VIDEO = 0xF0007400
Y1CAM = "/root/y1/y1cam"
SOC_HZ = 100e6


def _rd(addr):
    rc, out, err = BS.run("devmem 0x%X 32" % addr, timeout=20)
    if rc != 0:
        raise RuntimeError("devmem 0x%X failed: %s" % (addr, err or out))
    m = re.search(rb"0x([0-9A-Fa-f]{1,8})", out)
    if not m:
        raise RuntimeError("cannot parse devmem: %r" % out)
    return int(m.group(1), 16)


def _sample(win):
    d0 = _rd(VIDEO + 4)
    s0 = _rd(VIDEO)
    time.sleep(win)
    d1 = _rd(VIDEO + 4)
    s1 = _rd(VIDEO)
    dd = (d1 - d0) & 0xFFFF
    wrapped = dd >= 0x8000            # 半量程以上一律按回卷记（宁可保守）
    frames = ((s1 >> 8) - (s0 >> 8)) & 0xFFFFFF
    return dd, wrapped, frames, s1


def _report(tag, win):
    try:
        dd, wrapped, frames, s = _sample(win)
    except Exception as e:
        print("%-10s FAILED: %s" % (tag, e))
        return None
    txt = ("WRAPPED(>32767)" if wrapped else "delta=%d cyc (%.3f ms)"
           % (dd, dd / SOC_HZ * 1e3))
    fps = frames / win if win > 0 else 0.0
    print("%-10s vid_stall %-24s frames=%3d (%.1f fps) STATUS=0x%08X"
          % (tag, txt, frames, fps, s))
    return dict(delta=dd, wrapped=wrapped, frames=frames, status=s)


def _stop_y1cam():
    BS.run("if [ -f /run/y1cam.pid ]; then kill $(cat /run/y1cam.pid) 2>/dev/null; fi; "
           "sleep 1; kill -0 $(cat /run/y1cam.pid 2>/dev/null) 2>/dev/null && echo STILL || echo STOPPED",
           timeout=30)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--window", type=float, default=0.2)
    ap.add_argument("--settle", type=float, default=5.0)
    ap.add_argument("--run-cmd", default=Y1CAM + " --loop --quiet")
    ap.add_argument("--no-npu", action="store_true")
    a = ap.parse_args()

    if not BS.ensure_askpass():
        print("askpass: FAIL")
        return 2
    try:
        _rd(VIDEO)
    except Exception as e:
        print("VIDEO CSR unreachable (wrong bitstream/board): %s" % e)
        return 2

    _stop_y1cam()
    print("== idle ==")
    idle1 = _report("idle-1", a.window)
    _report("idle-2", a.window)
    if a.no_npu:
        return 0

    print("== start: %s ==" % a.run_cmd)
    BS.run("(%s >/dev/null 2>&1 &) ; sleep 1; echo STARTED" % a.run_cmd, timeout=30)
    time.sleep(a.settle)
    print("== loaded ==")
    load1 = _report("loaded-1", a.window)
    _report("loaded-2", a.window)
    _stop_y1cam()
    print("== idle again ==")
    back = _report("idle-3", a.window)

    if idle1 and load1:
        if load1["wrapped"] or load1["delta"] > 0:
            verdict = "=> NPU traffic DOES stall the video read (contention is real)"
        else:
            verdict = "=> no video-read stall under NPU load: look at static path differences"
        print("\nVERDICT: idle=%s loaded=%s %s"
              % ("0" if idle1["delta"] == 0 and not idle1["wrapped"] else str(idle1["delta"]),
                 "WRAPPED" if load1["wrapped"] else str(load1["delta"]), verdict))
    if back:
        print("        back-to-idle delta=%s (negative control: should return to idle)"
              % ("WRAPPED" if back["wrapped"] else back["delta"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
