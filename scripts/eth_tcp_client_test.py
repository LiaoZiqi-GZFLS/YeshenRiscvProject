#!/usr/bin/env python3
"""eth_tcp_client_test.py -- 真 TCP 判据（主机当服务端、板子当客户端，走 busybox `wget`）。

为什么用这个方向：板上那颗 micropython 的 `bind` 在本镜像里两个协议都报
`TypeError: object with buffer protocol required`（**板内工具受限**，不是网络问题），
起不了服务端。于是反过来：主机起 HTTP 服务端，板上用 busybox `wget` 去取 —— 板侧只依赖
`wget` 这一个已存在且常用的工具，方向也正好覆盖"板子作为 TCP 客户端"（与 ssh 客户端同向）。

⚠️ 若板子取不到：先分清是"主机防火墙挡入站 TCP"还是"链路不通"——本脚本会把
主机侧的 accept 情况也打出来（服务端 access log 落盘）。

用法：python -u scripts/eth_tcp_client_test.py [COM] [BAUD] [主机IP] [端口]
"""
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM7"
BAUD = sys.argv[2] if len(sys.argv) > 2 else "115200"
HOSTIP = sys.argv[3] if len(sys.argv) > 3 else "192.168.1.105"
HPORT = int(sys.argv[4]) if len(sys.argv) > 4 else 8080

payload = "TCP-PROBE-OK-7391"
d = tempfile.mkdtemp(prefix="tcpprobe_")
with open(os.path.join(d, "probe.txt"), "w") as f:
    f.write(payload + "\n")

logpath = os.path.join(d, "srv.log")
srv = subprocess.Popen([sys.executable, "-u", "-m", "http.server", str(HPORT),
                        "--bind", HOSTIP, "--directory", d],
                       stdout=open(logpath, "w"), stderr=subprocess.STDOUT)
time.sleep(1.5)

# 本机自测：主机自己先取一次，确认服务端真的在听（否则后面失败会赖到板上）
try:
    import urllib.request
    self_ok = urllib.request.urlopen(f"http://{HOSTIP}:{HPORT}/probe.txt", timeout=3).read().decode().strip()
except Exception as e:
    self_ok = f"<self-test failed: {e}>"
print(f"== 主机自测（本机取自己的服务端）: {self_ok}")

print(f"== 板上 wget http://{HOSTIP}:{HPORT}/probe.txt ==")
out = subprocess.run([sys.executable, "-u", "scripts/guest_cmd.py", PORT, BAUD,
                      f"wget -T 5 -q -O - http://{HOSTIP}:{HPORT}/probe.txt; echo WGET_RC=$?"],
                     capture_output=True, text=True, errors="replace").stdout
body = out.encode("ascii", "replace").decode("ascii")
print(body[-800:])

ok = payload in body
print(f"== 主机服务端日志 ==")
with open(logpath, "r", errors="replace") as f:
    print(f.read()[-600:] or "  (无请求到达服务端)")

srv.terminate()
try:
    srv.wait(timeout=5)
except Exception:
    srv.kill()
shutil.rmtree(d, ignore_errors=True)
print("=> TCP " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
