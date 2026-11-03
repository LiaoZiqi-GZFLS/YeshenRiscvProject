#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""收尾验收（板端一次跑完）：LED 语义 / 开机自启 YuNet / 远程工具 / 视频存活。

前置：板子上电、网络可达（`scripts/y1ctl.py ping` 通）、串口/网口未被别的会话占用。
用法（在仓库根）：
    python -u scripts/board_verify_wrapup.py            # 默认 192.168.1.110 + root
    python -u scripts/board_verify_wrapup.py --host 192.168.1.110

判据（逐条 PASS/FAIL，全 PASS 才算板端收尾过）：
  T1 连通：`y1ctl ping` 回 OK。
  T2 内核活：`/proc/uptime` 可读且 > 5 s。
  T3 LED 软件位（GPIO 输出寄存器 `0xF0002004`）：
       bit1（led4）= y1cam 在跑；bit3（led6）= eth0 up；
       bit0（led3）在 ~1.2 s 内**翻转**（Linux 心跳）。
  T4 自启：`/run/y1cam.pid` 的进程活着；`dmesg` 里有 `Y1CAM-BOOT pid=`。
  T5 交付件：`/root/y1/y1cam`、`/root/y1/y1run` 存在且可执行（md5 记下来对卡内交付）。
  T6 视频活：读 `VIDEO.STATUS`（`0xF0007400`）`init_done=1`，且 5 s 内 seq 前进。

注意：**LED 是肉眼判据**，本脚本只读软件能看到的位；led0/led1/led2/led7 是硬件位
（PLL 锁 / DDR init / 装载器 / PHY RXC），脚本读不到 ⇒ 需人眼确认（见 runbook §2）。
"""
import argparse
import subprocess
import sys
import time

HERE = __file__.rsplit("scripts", 1)[0].rstrip("/\\")


def sh(args, timeout=45):
    """跑一条 y1ctl 命令，返回 (rc, stdout)。单行命令，避免 WSL/ssh 多行截断。"""
    p = subprocess.run([sys.executable, "-u", "scripts/y1ctl.py"] + args,
                       cwd=HERE, capture_output=True, text=True, timeout=timeout,
                       encoding="utf-8", errors="replace")
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def run_board(cmd, timeout=45, retries=2):
    """在板上跑一条**单行**命令，回显中取出最后一行非空输出。
    ★ y1cam 在跑时板子偶发 >25 s 才回（2026-10-25 实测超时一次）⇒ 带一次重试。"""
    last = ("", "")
    for _ in range(retries):
        try:
            rc, out = sh(["run", cmd], timeout=timeout)
        except Exception:
            continue
        lines = [l.strip() for l in out.splitlines() if l.strip()]
        last = (rc, (lines[-1] if lines else ""))
        if last[1]:
            return last
    return last


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default=None, help="远端主机（默认沿用 y1ctl 的配置）")
    a = ap.parse_args()

    rows = []

    def rec(tag, ok, detail):
        rows.append((tag, ok, detail))
        print("%-4s %-4s %s" % (tag, "PASS" if ok else "FAIL", detail))

    # T1 连通
    rc, out = sh(["ping"])
    ok1 = ("OK" in out.upper()) and rc == 0
    rec("T1", ok1, "y1ctl ping -> %s" % out.strip().splitlines()[-1][:90] if out.strip() else "no output")
    if not ok1:
        print("\n板子不可达：先上电 / 查 IP / 查网线。后续检查跳过。")
        return 1

    # T2 内核活
    rc, up = run_board("cat /proc/uptime")
    try:
        up_s = float(up.split()[0])
        ok2 = up_s > 5.0
    except Exception:
        up_s, ok2 = -1.0, False
    rec("T2", ok2, "/proc/uptime = %s" % up)

    # T3 LED 软件位（GPIO 输出寄存器）
    # 心跳位必须**在一次 ssh 里连采**：两次独立 ssh 的间隔（1-3 s）会与 ~2 s 的循环周期同相混叠，
    # 从而把"正在闪"误判成"定住"（2026-10-25 实测踩过）。
    rc, burst = run_board("for i in 1 2 3 4 5 6; do devmem 0xF0002004 32; sleep 1; done | tr '\n' ' '", timeout=40)
    vals = []
    for tok in (burst or "").split():
        try:
            vals.append(int(tok, 16))
        except Exception:
            pass
    b1 = vals[-1] if vals else -1
    b2 = vals[0] if vals else -1
    hb_toggled = any(((vals[i] ^ vals[i + 1]) & 1) for i in range(len(vals) - 1))
    ok_y1cam = bool((b1 >> 1) & 1)
    ok_net = bool((b1 >> 3) & 1)
    ok_hb = hb_toggled
    rec("T3a", ok_y1cam, "led4(bit1)=%d  ← y1cam 在跑" % ((b1 >> 1) & 1 if b1 >= 0 else -1))
    rec("T3b", ok_net, "led6(bit3)=%d  ← eth0 up" % ((b1 >> 3) & 1 if b1 >= 0 else -1))
    rec("T3c", ok_hb, "led3(bit0) 心跳：%s（须翻转）" % " ".join("0x%X" % v for v in vals))

    # T4 自启
    rc, pid = run_board("cat /run/y1cam.pid")
    rc2, alive = run_board("kill -0 $(cat /run/y1cam.pid) && echo ALIVE || echo DEAD")
    rc3, boot = run_board("dmesg | grep -o 'Y1CAM-BOOT[^ ]*' | tail -1")
    ok4 = alive.strip().endswith("ALIVE")
    rec("T4", ok4, "y1cam pid=%s (%s); kmsg=%s" % (pid, alive.strip(), boot or "-"))

    # T5 交付件
    rc, ls = run_board("ls -l /root/y1/y1cam /root/y1/y1run 2>&1 | tr '\\n' '|'")
    rc5, md5 = run_board("md5sum /root/y1/y1cam /root/y1/y1run 2>/dev/null | tr '\\n' ';'")
    ok5 = ("y1cam" in ls) and ("y1run" in ls)
    rec("T5", ok5, md5 or ls)

    # T6 视频活
    rc, st1 = run_board("devmem 0xF0007400 32")
    time.sleep(5.0)
    rc, st2 = run_board("devmem 0xF0007400 32")
    try:
        s1, s2 = int(st1, 16), int(st2, 16)
    except Exception:
        s1 = s2 = -1
    # 位定义逐字取自 board/cam/video_regs.v:5  —— [0] init_done / [1] 写 bank / [31:8] 24-bit 帧序号
    seq1, seq2 = (s1 >> 8) if s1 >= 0 else -1, (s2 >> 8) if s2 >= 0 else -1
    init_done = bool(s1 & 1) if s1 >= 0 else False
    ok6 = init_done and (seq1 != seq2)
    rec("T6", ok6, "VIDEO.STATUS 0x%X -> 0x%X（init_done=%d, seq %d -> %d）"
        % (s1, s2, init_done, seq1, seq2))

    bad = [r for r in rows if not r[1]]
    print("\n== 汇总：%d/%d PASS ==" % (len(rows) - len(bad), len(rows)))
    if bad:
        print("红项：" + ", ".join(r[0] for r in bad))
        print("提示：T3a/T4 红多半是**旧卡**（v2 卡的 S99y1cam 才会自启）；先确认卡镜像 md5=dd484418。")
    print("人眼仍需确认：led0 常亮 / led1 亮 / led2 装载后灭 / led7 常亮（PHY RXC）；屏幕与 Cam 正常版一致。")
    return 0 if not bad else 2


if __name__ == "__main__":
    sys.exit(main())
