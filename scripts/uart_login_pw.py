#!/usr/bin/env python3
"""uart_login_pw.py -- 串口登录（**带口令**版）。

为什么需要：2026-10-07 给 root 设了口令（dropbear 拒绝空口令登录），原来的免密登录
（`uart_login_until.py` 只发用户名）已经进不去了 —— 本镜像开始控制台登录也要输口令。

用法：python -u scripts/uart_login_pw.py COM7 115200 yeshen
成功后用 `scripts/guest_cmd.py COM7 115200 "<cmd>"` 继续。
"""
import sys
import time

import serial

port = sys.argv[1] if len(sys.argv) > 1 else "COM7"
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
pw = sys.argv[3] if len(sys.argv) > 3 else "yeshen"


def emit(t):
    sys.stdout.write(t.encode("ascii", "replace").decode("ascii") + "\n")
    sys.stdout.flush()


s = serial.Serial(port, baud, timeout=0.2)
s.dtr = False
s.rts = False
time.sleep(0.3)
s.write(b"\x03\r")          # 清场：别把上一轮的未闭合引号带进来
time.sleep(0.4)
s.reset_input_buffer()


def wait_for(pat, secs):
    t0 = time.time()
    buf = b""
    while time.time() - t0 < secs:
        d = s.read(4096)
        if d:
            buf += d
            if pat in buf:
                return True, buf
    return False, buf


ok, buf = wait_for(b"login:", 3.0)
if not ok:
    ok, buf = wait_for(b"#", 2.0)
    if ok:
        emit("ALREADY LOGGED IN")
        s.close()
        sys.exit(0)
    emit("!! 没看到 login: 提示符（串口没输出？）")
    sys.exit(1)

s.write(b"root\r")
ok, buf = wait_for(b"assword:", 5.0)
if not ok:
    # 有的配置直接给 shell（空口令），那就已经在 shell 里了
    ok2, buf2 = wait_for(b"#", 2.0)
    emit("NO_PASSWORD_PROMPT -> " + ("shell ok" if ok2 else "unknown"))
    s.close()
    sys.exit(0 if ok2 else 2)

s.write(pw.encode() + b"\r")
ok, buf = wait_for(b"#", 8.0)
emit("== LOGGED IN ==" if ok else "!! 口令似乎不对（8s 内没拿到 #）")
s.close()
sys.exit(0 if ok else 3)
