#!/usr/bin/env python3
"""board_y1run_ab.py —— 板内 NPU 回归（y1run 12/12）的**正确姿势**。

★ 为什么需要这个脚本（2026-10-27 实测事故）：
  板上自启服务 `/etc/init.d/S99y1cam.sh` 会常驻 `y1cam --loop`，它**一直在驱动同一颗 NPU**、
  反复写同一批输出缓冲区。与 `y1run` 并发时两者互踩 ⇒ y1run 报 CRC 不符、**同一输入每次 CRC 都不同**
  （看起来像"NPU 比特流坏了 / 硬件时序边际"）。停掉循环后同一比特流 **连跑 3 次全 12/12 PASS**。
  ⇒ 任何 y1run 判据都必须先停 y1cam，跑完再恢复。

做法：停循环 → 跑 N 次 → 每次解析 `Y1RUN: PASS|FAIL` → 恢复自启。
用法：`python -u scripts/board_y1run_ab.py [--n 3] [--keep-stopped]`
退出码：0 = 全过；1 = 有失败；3 = 环境问题（ssh/停不掉/脚本缺失）。
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import board_ssh as BS  # noqa: E402

Y1RUN = "/root/y1/y1run"
INITD = "/etc/init.d/S99y1cam.sh"


def sh(cmd, timeout=180):
    rc, out, err = BS.run(cmd, timeout=timeout)
    return rc, (out or b"").decode("utf-8", "replace"), (err or "")


def n_running():
    rc, out, _ = sh("ps -o pid,args | grep -v grep | grep -c 'y1cam --loop'", timeout=60)
    try:
        return int(out.strip().splitlines()[-1])
    except Exception:
        return -1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=3)
    ap.add_argument("--keep-stopped", action="store_true")
    a = ap.parse_args()

    if not BS.ensure_askpass():
        print("FATAL: WSL askpass 准备失败")
        return 3

    print(f"== 停 y1cam 循环（当前 {n_running()} 个）==")
    sh("for p in $(pidof y1cam); do kill -9 $p; done; sleep 1", timeout=60)
    left = n_running()
    print(f"   剩余 {left}")
    if left != 0:
        print("FATAL: y1cam 停不掉（判据会被污染，拒绝继续）")
        return 3

    fails = 0
    try:
        for i in range(1, a.n + 1):
            rc, out, err = sh(f"{Y1RUN} 2>&1", timeout=180)
            line = [l for l in out.splitlines() if l.startswith("Y1RUN:")]
            run = [l for l in out.splitlines() if l.startswith("RUN 0")]
            verdict = line[-1] if line else f"<无判据行 rc={rc}> {err[:80]}"
            print(f"  [{i}/{a.n}] {run[-1] if run else ''} | {verdict}")
            if not (line and "PASS" in line[-1]):
                fails += 1
    finally:
        if a.keep_stopped:
            print("== --keep-stopped：不恢复 y1cam ==")
        else:
            print("== 恢复 y1cam 循环 ==")
            sh(f"{INITD} start >/dev/null 2>&1; sleep 2", timeout=60)
            print(f"   现在 {n_running()} 个")

    print(f"RESULT: {'PASS' if fails == 0 else 'FAIL'} ({a.n - fails}/{a.n})")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
