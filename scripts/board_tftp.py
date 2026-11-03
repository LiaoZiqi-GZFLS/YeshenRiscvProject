#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""board_tftp.py —— 板 → 主机**大块回读**的传输通路（板内 busybox `tftp -p` + 本机 UDP 接收器）。

为什么需要（S3-2 上板实测，2026-10-16）：
  现网 **ssh 会话的大 stdout 必死**：stdout ≳1.5 KB / 流式 ≳1.5 s ⇒ `rc=255` 且输出**整丢**
  （实测 `head -c 4096/6000/6400 f | base64` 全 rc=255、out 为空；同一数据写文件再 `md5sum`
  正常；小命令 ~87.5% 成功）。12 路输出合计 ~131 KB ⇒ 走 ssh stdout 不可行。
  反方向（host→board stdin）大块正常（404 KB 已在板上验过 md5）⇒ 板→主机改走
  **板内 tftp 客户端主动推**（UDP/TFTP，RFC 1350 + blksize 选项 OACK）到本机 192.168.1.105。
  判据与写通路同款：**两侧 md5 逐字节相等**才采纳（ssh 命令的 rc 只记账，不作判据 ——
  tftp 推完之后会话掉线不影响净荷）。

API：
    host_ip_for_board()                    -> "192.168.1.105"（按到板子的路由取本机源地址）
    pull_board_file(remote, local, ...)    -> (ok, md5, nbytes, detail)
        · remote = 板内**已存在**的文件（调用方先用 ddmem 落盘并取板上 md5sum）
        · 内部：接收器线程 + `busybox tftp -p -b SIZE -l remote -r <name> HOST PORT`（重试）
        · 成功判据：收全文件（长度 == blocks*blksize 语义）且 **md5 与板上 md5sum 相等**

CLI（手搓排查 / 单文件取回）：
    python scripts/board_tftp.py pull <board_file> <local_path> [port] [blksize]
"""
import hashlib
import os
import re
import socket
import struct
import subprocess
import sys
import threading
import time

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import board_ssh as BS  # noqa: E402

BOARD_IP = BS.BOARD_IP
DEF_PORT = 6969


def host_ip_for_board(board_ip=BOARD_IP):
    """本机到板子的源地址（UDP connect 技巧；主机与板子同网段才能直达）。"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((board_ip, 22))
        return s.getsockname()[0]
    finally:
        s.close()


# --------------------------------------------------------------------------
# 最小 TFTP 接收器（只做 WRQ 写请求方向；单会话串行）
# --------------------------------------------------------------------------
OP_RRQ, OP_WRQ, OP_DATA, OP_ACK, OP_ERROR, OP_OACK = 1, 2, 3, 4, 5, 6


class TftpReceiver(object):
    """一次收一个文件（WRQ）。blksize 协商（OACK）；重复块只重发 ACK 不重写。"""

    def __init__(self, port=DEF_PORT, blksize_max=4096, quiet=False):
        self.port = port
        self.blksize_max = blksize_max
        self.quiet = quiet
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("0.0.0.0", port))
        self.result = None          # (filename, bytes)
        self.error = None

    def _recv_from(self, addr, deadline):
        while time.time() < deadline:
            remain = max(0.05, min(1.0, deadline - time.time()))
            self.sock.settimeout(remain)
            try:
                data, a = self.sock.recvfrom(65536)
            except socket.timeout:
                continue
            if a[0] == addr[0]:
                return data
        return None

    def serve_once(self, timeout=180.0):
        """阻塞收一个文件；返回 (filename, bytes) 或抛 TimeoutError/ValueError。"""
        deadline = time.time() + timeout
        self.sock.settimeout(1.0)
        # ---- 等 WRQ ----
        wrq = None
        while time.time() < deadline:
            try:
                data, addr = self.sock.recvfrom(65536)
            except socket.timeout:
                continue
            if len(data) >= 4 and struct.unpack(">H", data[:2])[0] == OP_WRQ:
                wrq = (data, addr)
                break
        if wrq is None:
            raise TimeoutError("等 WRQ 超时（%ss 内无写请求）" % timeout)
        data, addr = wrq
        parts = data[2:].split(b"\x00")
        filename = parts[0].decode("utf-8", "replace")
        opts = {}
        i = 2
        while i + 1 < len(parts):
            if parts[i]:
                opts[parts[i].decode().lower()] = parts[i + 1].decode()
            i += 2
        blk = 512
        if "blksize" in opts:
            try:
                blk = max(8, min(int(opts["blksize"]), self.blksize_max))
            except ValueError:
                blk = 512
        oack_opts = b""
        if "blksize" in opts:
            oack_opts = b"blksize\x00%d\x00" % blk
        if oack_opts:
            self.sock.sendto(struct.pack(">HH", OP_OACK, 0) + oack_opts, addr)
        else:
            self.sock.sendto(struct.pack(">HH", OP_ACK, 0), addr)
        if not self.quiet:
            print("  [tftp] WRQ file=%s blksize=%d from %s:%d%s" % (
                filename, blk, addr[0], addr[1], "（OACK）" if oack_opts else ""), flush=True)

        # ---- 收 DATA ----
        buf, expect = bytearray(), 1
        while time.time() < deadline:
            d = self._recv_from(addr, deadline)
            if d is None:
                break
            if len(d) < 4:                          # 短包（乱序/串扰）直接丢，绝不让它炸 unpack
                continue
            op = struct.unpack(">H", d[:2])[0]
            if op == OP_WRQ:                       # OACK 丢了：重发 OACK/ACK0
                self.sock.sendto(struct.pack(">HH", OP_OACK, 0) + oack_opts if oack_opts
                                 else struct.pack(">HH", OP_ACK, 0), addr)
                continue
            if op == OP_ERROR:
                raise ValueError("板内 tftp 报错：%r" % d[4:].decode("utf-8", "replace"))
            if op != OP_DATA or len(d) < 4:
                continue
            bno = struct.unpack(">H", d[2:4])[0]
            payload = d[4:]
            if bno == (expect & 0xFFFF):
                buf += payload
                self.sock.sendto(struct.pack(">HH", OP_ACK, bno), addr)
                expect += 1
                if len(payload) < blk:
                    self.result = (filename, bytes(buf))
                    return self.result
            elif bno == ((expect - 1) & 0xFFFF):   # 重复块：重发 ACK
                self.sock.sendto(struct.pack(">HH", OP_ACK, bno), addr)
        raise TimeoutError("收 DATA 超时/中断：bytes=%d（最后期望块=%d）" % (len(buf), expect))


# --------------------------------------------------------------------------
# 高层：板内文件 → 本地（含板上 md5sum 与本地 md5 对账）
# --------------------------------------------------------------------------
MD5_RE = re.compile(rb"^([0-9a-f]{32})\s+(\S+)\s*$", re.M)


def board_md5(remote_file, tries=6, timeout=30):
    """板上 md5sum（小 stdout，安全）；返回 (md5|None, detail)。"""
    last = ""
    for t in range(tries):
        rc, out, err = BS.run("md5sum %s" % remote_file, timeout=timeout)
        m = MD5_RE.search(out)
        if m:
            return m.group(1).decode(), "rc=%s" % rc
        last = "rc=%s out=%r err=%s" % (rc, out[:60], err.strip()[:60])
        time.sleep(0.4)
    return None, last


def _pick_receiver_py():
    """接收进程的解释器：Windows 防火墙的入站 UDP 允许规则按**可执行文件**匹配
    （实测本机：`C:\\python314\\python.exe` 与 miniconda3 有规则、venv 的没有；本网段 Public 档）
    ⇒ 默认挑 python314；可用环境变量 `BOARD_TFTP_PY` 覆盖。"""
    env = os.environ.get("BOARD_TFTP_PY")
    if env and os.path.exists(env):
        return env
    for cand in (r"C:\python314\python.exe", r"C:\ProgramData\miniconda3\python.exe"):
        if os.path.exists(cand):
            return cand
    return sys.executable


def _warm_arp(board_ip=BOARD_IP):
    """预热**本机** ARP/邻居表（板子的 MAC）。

    为什么需要（S3-2 实测的"OACK 无影"）：ssh 走的是 WSL（NAT）⇒ Windows 侧网络栈**看不到**
    板子的流量 ⇒ 它对板子 IP 的邻居项会冷掉；tftp 的第一发（OACK/ACK0）要先 ARP，在丢包链路上
    ARP 请求/应答一丢，客户端整轮就 `tftp: timeout`（实测连续多轮"WRQ 到了、OACK 无影"）。
    每次尝试前先 ping 一发（ICMP 应答也进邻居表），把这一跳预热掉。
    """
    try:
        subprocess.run(["ping", "-n", "1", "-w", "1500", board_ip],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    except Exception:                              # noqa: BLE001
        pass


def pull_board_file(remote_file, local_path, port=DEF_PORT, blksize=4096, tries=6,
                    host_ip=None, quiet=False, recv_py=None, blksize_ladder=(4096, 4096, 2048, 2048),
                    md5_want=None):
    """板内 remote_file → 本地 local_path。返回 (ok, md5, nbytes, detail)。

    接收器在**独立进程**里跑（`recv` 子命令；默认解释器见 `_pick_receiver_py`），
    本调用进程只负责 ssh 侧发命令 —— 两侧 md5 相等才落盘（rc 只记账）。
    ★ 现网实测（S3-2）：板内 busybox tftp 是**停等**协议、**总耐心 ∝ 块数**（16 KB 文件按 512 B
    分 32 块必 `tftp: timeout`；按 4096 分 4 块就能过）⇒ 梯子**优先大块**（4096）重复试探，
    只在久试不过时才降档；单文件 >16 KB 由调用方（`board_ddr._read_tftp`）切块。客户端一退出
    就**立刻**收掉接收器（不等空转）。
    `md5_want`：调用方**刚**从 DDR 重读并已取得的板上 md5（省一次 ssh；None = 本函数自己取）。
    """
    host = host_ip or host_ip_for_board()
    local_path = os.path.abspath(local_path)       # ★ 接收器子进程 cwd 不同 ⇒ 必须绝对路径
    rname = os.path.basename(remote_file)
    py = recv_py or _pick_receiver_py()
    if md5_want is None:                           # 调用方没给 ⇒ 自取（多一条 ssh）
        md5_want, d1 = board_md5(remote_file)
        if md5_want is None:
            return False, None, 0, "板上 md5sum 失败：%s" % d1
    last = ""
    for t in range(tries):
        blk = blksize if t == 0 else blksize_ladder[(t - 1) % len(blksize_ladder)]
        port_i = port + t                          # 每试独立端口：不存在"上一试的接收器还占着口"
        tmp_out = "%s.try%d" % (local_path, t)
        if os.path.exists(tmp_out):
            os.remove(tmp_out)
        p = subprocess.Popen([py, os.path.abspath(__file__), "recv", str(port_i), tmp_out, "60"],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             cwd=_HERE, env=dict(os.environ, PYTHONIOENCODING="utf-8"))
        time.sleep(0.4)
        _warm_arp(BS.BOARD_IP)                     # ★ 试前预热本机邻居表（OACK 的第一跳）
        cmd = "busybox tftp -p -b %d -l %s -r %s %s %d" % (blk, remote_file, rname, host, port_i)
        rc, out, err = BS.run(cmd, timeout=120)
        # 客户端已退出 ⇒ 不再有 DATA 来；给接收器 ≤4 s 收尾，超时就收掉（不再空等 90 s）
        try:
            rout, _ = p.communicate(timeout=4.0)
        except subprocess.TimeoutExpired:
            p.kill()
            rout, _ = p.communicate()
        if os.path.exists(tmp_out):
            data = open(tmp_out, "rb").read()
            md5_got = hashlib.md5(data).hexdigest()
            if md5_got == md5_want:
                os.replace(tmp_out, local_path)
                return True, md5_got, len(data), "blk=%d rc=%s recv=%s" % (
                    blk, rc, rout.decode("utf-8", "replace").strip()[:90])
            last = "blk=%d md5 不等（板上 %s vs 收到 %s，%d B）" % (blk, md5_want, md5_got, len(data))
        else:
            last = "blk=%d recv(rc=%s) %s；ssh rc=%s %s" % (
                blk, p.returncode, rout.decode("utf-8", "replace").strip()[:400],
                rc, err.strip()[:60])
        if not quiet:
            print("  [tftp] 第 %d/%d 试不顺：%s" % (t + 1, tries, last), flush=True)
        time.sleep(0.5)
    return False, None, 0, last


def _main(argv):
    if not argv:
        print(__doc__)
        return 2
    if argv[0] == "recv":
        # 最小接收器（独立进程用）：recv <port> <outfile> [timeout_s]
        # ★ 必须用 C:\python314\python.exe 跑本子命令：Windows 防火墙的 "Python" 入站 UDP
        #   允许规则是按**可执行文件路径**匹配的（C:\python314\python.exe / miniconda3 有规则，
        #   venv 的 python.exe 没有；本网段是 Public 档）。
        port = int(argv[1]) if len(argv) > 1 else DEF_PORT
        out = os.path.abspath(argv[2]) if len(argv) > 2 else os.path.abspath("tftp_recv.bin")
        tmo = float(argv[3]) if len(argv) > 3 else 120.0
        os.makedirs(os.path.dirname(out), exist_ok=True)
        rx = TftpReceiver(port=port, quiet=False)
        try:
            fname, data = rx.serve_once(timeout=tmo)
        except Exception:                          # noqa: BLE001 —— 追栈要能穿到调用方
            import traceback
            tb = traceback.format_exc()
            traceback.print_exc()
            try:
                with open(out + ".exc.log", "w", encoding="utf-8") as fh:
                    fh.write(tb)
            except Exception:                      # noqa: BLE001
                pass
            return 2
        open(out, "wb").write(data)
        md5 = hashlib.md5(data).hexdigest()
        print("RECV ok file=%s nbytes=%d md5=%s wrote=%s" % (fname, len(data), md5, out))
        return 0
    if argv[0] != "pull" or len(argv) < 3:
        print(__doc__)
        return 2
    remote, local = argv[1], argv[2]
    port = int(argv[3]) if len(argv) > 3 else DEF_PORT
    blk = int(argv[4]) if len(argv) > 4 else 2048
    BS.ensure_askpass()
    print("host_ip_for_board = %s" % host_ip_for_board())
    ok, md5, n, detail = pull_board_file(remote, local, port=port, blksize=blk)
    print("PULL %s: ok=%s md5=%s nbytes=%d  %s" % (remote, ok, md5, n, detail))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
