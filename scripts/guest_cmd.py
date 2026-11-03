#!/usr/bin/env python3
"""guest_cmd.py -- 通过串口在（已登录的）客人机 shell 里跑一批命令并取回输出。

为什么现在能做（2026-10-07 之前不行）：控制台曾经 RX 不通，兄弟工程的结论是
"进不去板子跑 ifconfig，只能靠 RTL 自带的口子" —— E1 收口后这条**作废**，
板内观测的直接通道就是登录后的 shell。

用法：
  python -u scripts/guest_cmd.py COM7 115200 "cmd1" "cmd2" ...
  echo "cmd1" > cmds.txt ; python -u scripts/guest_cmd.py COM7 115200 --file cmds.txt

机制：每条命令前后包一对不可混淆的 marker（`@@BEG<n>@@` / `@@END<n>@@`），逐条等到 END 再发下一条，
所以不依赖提示符形状（PS1 带 ANSI 转义）。全部原文落盘 sim/reglogs/guest_cmd.log。
"""
import sys
import time

import serial

args = sys.argv[1:]
PORT = "COM7"
BAUD = 115200
if len(args) >= 2 and args[0].startswith("COM"):
    PORT, BAUD = args[0], int(args[1])
    args = args[2:]

cmds = []
if args and args[0] == "--file":
    cmds = [l.rstrip("\n") for l in open(args[1], encoding="utf-8") if l.strip()]
else:
    cmds = [a for a in args if a.strip()]
if not cmds:
    sys.exit("no commands given")

s = serial.Serial(PORT, BAUD, timeout=0.05)
s.dtr = False
s.rts = False
time.sleep(0.3)

# 清场：上一轮若把 shell 留在 PS2 `>`（未闭合引号/`$(`），后续命令会被并进那条续行，
# 而 have_shell 只看 `#`（回显里也有）⇒ 会误判成"拿到提示符"。先 Ctrl-C 复位到 PS1。
# ⚠️ 还要补一个 **^Q(XON)**：控制台 tty 默认带 `IXON`，RX 流里任何一个杂散 0x13(^S)
#    都会让 tty **停发**（输出队列满 ⇒ shell 阻塞在 write ⇒ 不读输入 ⇒ 什么都不回显），
#    硬件此时完全空闲（实测 LSR=0x60 / IIR=0xC1）。见 docs §20 与 scripts/uart_xoff_ab.py。
s.write(b"\x03\r\x11")
time.sleep(0.25)
s.reset_input_buffer()

LOG = open("sim/reglogs/guest_cmd.log", "w", encoding="utf-8", errors="replace")


def read_until(pred, secs):
    t0 = time.time()
    buf = b""
    while time.time() - t0 < secs:
        d = s.read(4096)
        if d:
            buf += d
            if pred(buf):
                break
    LOG.write(buf.decode("latin-1"))
    LOG.flush()
    return buf


def have_shell(secs=1.0):
    s.reset_input_buffer()
    s.write(b"\r")
    b = read_until(lambda x: b"#" in x, secs)
    return b"#" in b


if not have_shell(2.5):
    print("!! 没拿到 shell 提示符（先跑 scripts/uart_login_retry.py 或 uart_login_test.py）",
          flush=True)

# ⚠️ marker 必须**在输入行里不以字面量出现**：tty 会把整行命令回显回来，若 marker 是字面量
#    （`echo @@BEG0@@; cmd; echo @@END0@@`）就会先命中**回显**里的那一份 ⇒ 切出来的是命令本身而不是输出。
#    做法：用 shell 变量拼出 marker（输入里是 `X${B}X` / `B=BEG0`，输出里是 `XBEG0X`）⇒ 不会撞。
for i, c in enumerate(cmds):
    s.reset_input_buffer()
    s.write(('B=BEG%d; E=END%d; echo "X${B}X"; %s; echo "X${E}X"\r'
             % (i, i, c)).encode())
    out_beg = ("XBEG%dX" % i).encode()
    out_end = ("XEND%dX" % i).encode()
    buf = read_until(lambda x: out_end in x, 20.0)
    txt = buf.decode("latin-1")
    body = txt.split(out_beg.decode(), 1)[1] if out_beg.decode() in txt else txt
    if out_end.decode() in body:
        body = body.split(out_end.decode(), 1)[0]
    body = body.strip("\r\n").strip()
    print("=== $ %s ===" % c, flush=True)
    print(body if body else "(no output)", flush=True)
    time.sleep(0.15)

s.close()
LOG.close()
print("--- transcript -> sim/reglogs/guest_cmd.log ---", flush=True)
