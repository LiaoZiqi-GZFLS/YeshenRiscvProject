#!/usr/bin/env python3
"""eth_tcp_e2e.py -- TCP 端到端判据：板上用 micropython 起一个一次性 TCP 服务端，主机去连。

为什么这么测：镜像里没有 sshd/nc/telnetd（`which` 均为空），但有 `micropython`（带 socket）。
TCP 是 ssh 的前提，所以用脚本语言起个真服务端，测"外部能否在板上建 TCP 连接 + 收发字节"。

用法：python -u scripts/eth_tcp_e2e.py [COM] [BAUD] [板IP] [端口]
"""
import re
import socket
import subprocess
import sys
import time

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM7"
BAUD = sys.argv[2] if len(sys.argv) > 2 else "115200"
BOARD = sys.argv[3] if len(sys.argv) > 3 else "192.168.1.110"
TPORT = int(sys.argv[4]) if len(sys.argv) > 4 else 1234

SRV = (
    "import socket\n"
    "s=socket.socket()\n"
    "s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)\n"
    f"s.bind(('0.0.0.0',{TPORT}))\n"
    "s.listen(1)\n"
    "print('TCPDBG listening')\n"
    "c,a=s.accept()\n"
    "print('TCPDBG accepted')\n"
    "d=c.recv(64)\n"
    "print('TCPDBG got',d)\n"
    "c.send(b'TCP-FROM-BOARD\\n')\n"
    "c.close()\n"
    "print('TCPDBG served')\n"
)


def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, errors="replace").stdout


def guest(cmd, secs=None):
    args = [sys.executable, "-u", "scripts/guest_cmd.py", PORT, BAUD, cmd]
    return sh(args)


# 1) 板上起服务端（后台）。源码用 **hex + `xxd -r -p`** 送过去，彻底绕开引号/转义
#    （上一版把 python 源码放进双引号字符串，`\'` 原样落进文件 ⇒ micropython 语法错、服务端没起）。
hexs = SRV.encode("ascii").hex()
launch = (f"printf '%s' {hexs} | xxd -r -p > /tmp/tcpsrv.py; "
          "micropython /tmp/tcpsrv.py > /tmp/tcpsrv.log 2>&1 & echo launched")
print("== 板上启动 micropython TCP 服务端 ==")
print("  ", guest(launch).strip().splitlines()[-3:])
time.sleep(2.5)

# 2) 主机连过去
print(f"== 主机连 {BOARD}:{TPORT} ==")
ok = False
try:
    c = socket.create_connection((BOARD, TPORT), timeout=5)
    c.sendall(b"HOST-PAYLOAD-1234\n")
    data = c.recv(64)
    c.close()
    print("  主机收到:", data)
    ok = (b"TCP-FROM-BOARD" in data)
except Exception as e:
    print("  连接/收发失败:", e)

# 3) 板侧日志
print("== 板侧日志 ==")
log = guest("cat /tmp/tcpsrv.log")
for ln in log.splitlines():
    if "TCPDBG" in ln:
        print("  ", ln.strip())

print("=> TCP " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
