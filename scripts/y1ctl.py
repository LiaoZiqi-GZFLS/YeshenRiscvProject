#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""y1ctl.py —— 开发板远程「命令 + 文件」一站式工具（SSH / SCP / TFTP）。

一条命令覆盖日常上板动作，全部走现网的**可用**通路（口径见 scripts/board_ssh.py）：

  run    板内执行命令（不分配 tty，不碰 COM 控制台）
  put    主机 → 板（scp -O；不通时退 ssh stdin 直灌），**两侧 md5 相等才算成功**
  get    板 → 主机（≤48 KB 走 ssh/base64；更大的走板内 busybox tftp 主动推 UDP），**同款 md5 判据**
  ls     列板内目录（大小 + mtime）
  status 一条命令出健康摘要（uptime/内存/根文件系统/网口/NPU/VIDEO/y1cam 进程）
  ping   连通性 + 口令通道自检

典型用法：
  python scripts/y1ctl.py status
  python scripts/y1ctl.py run "cat /proc/loadavg"
  python scripts/y1ctl.py put sw/images/rootfs_v2.cpio /root/rootfs.cpio
  python scripts/y1ctl.py put --exec build/y1cam /root/y1/y1cam
  python scripts/y1ctl.py get /root/y1/frame.bin out/frame.bin
  python scripts/y1ctl.py ls /root/y1

为什么不是 SFTP：板内是 dropbear，**没有 /usr/libexec/sftp-server**（实测
`sh: /usr/libexec/sftp-server: not found`）⇒ 新版 OpenSSH scp 默认的 SFTP 模式不可用，
本工具显式 `scp -O` 回到 SCP 协议，并在失败时退到 `ssh "cat > file"`。

环境变量：BOARD_IP（默认 192.168.1.110）/ BOARD_USER（root）/ BOARD_PW（yeshen）。
"""
import argparse
import hashlib
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import board_ssh as BS  # noqa: E402

SMALL_MAX = 48 * 1024          # ssh/stdout 走 base64 的安全上限（>1.5 KB 的大 stdout 会掉会话）


def _md5_file(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def _q(s):
    return "'" + str(s).replace("'", "'\\''") + "'"


def _board_md5(remote):
    rc, out, err = BS.run("md5sum %s" % _q(remote))
    if rc != 0:
        return None
    tok = out.decode("utf-8", "replace").split()
    return tok[0] if tok else None


def cmd_ping(a):
    if not BS.ensure_askpass():
        print("askpass: FAIL (WSL 侧写不出 $HOME/askpass.sh)")
        return 1
    rc, out, err = BS.run("echo Y1CTL_PONG; uname -srm", timeout=20)
    ok = rc == 0 and b"Y1CTL_PONG" in out
    print("board %s@%s: %s" % (BS.BOARD_USER, BS.BOARD_IP, "OK" if ok else "FAIL"))
    if out:
        print(out.decode("utf-8", "replace").strip())
    if not ok and err:
        print(err.strip())
    return 0 if ok else 1


def cmd_run(a):
    rc, out, err = BS.run(a.cmd, timeout=a.timeout)
    sys.stdout.write(out.decode("utf-8", "replace"))
    if err:
        sys.stderr.write(err + "\n")
    return rc


def cmd_put(a):
    if not os.path.isfile(a.local):
        print("no such file: %s" % a.local)
        return 2
    remote = a.remote or ("/root/" + os.path.basename(a.local))
    want = _md5_file(a.local)
    rc, txt = BS.put(a.local, remote, timeout=a.timeout)
    got = _board_md5(remote)
    if a.exec:
        BS.run("chmod +x %s" % _q(remote))
    ok = rc == 0 and got == want
    print("put %s -> %s  local_md5=%s board_md5=%s  %s"
          % (a.local, remote, want[:8], (got or "?")[:8], "OK" if ok else "MISMATCH"))
    if not ok and txt.strip():
        print(txt.strip())
    return 0 if ok else 1


def cmd_get(a):
    rc, out, err = BS.run("stat -c %%s %s" % _q(a.remote), timeout=30)
    if rc != 0:
        print("remote stat failed: %s" % (err or out.decode("utf-8", "replace")))
        return 2
    size = int(out.decode("ascii", "replace").strip() or -1)
    local = a.local or os.path.basename(a.remote)
    want = _board_md5(a.remote)
    if want is None:
        print("board md5sum failed")
        return 1
    if size <= SMALL_MAX:
        rc, data = BS.get_b64(a.remote, timeout=a.timeout)
        if rc != 0:
            print("base64 pull failed (rc=%d)" % rc)
            return 1
        with open(local, "wb") as f:
            f.write(data)
        got = _md5_file(local)
    else:
        import board_tftp as BT
        ok, got, n, detail = BT.pull_board_file(a.remote, local, port=a.port,
                                                blksize=a.blksize, md5_want=want)
        if not ok:
            print("tftp pull failed: %s" % detail)
            return 1
    ok = got == want and os.path.getsize(local) == size
    print("get %s -> %s  %d B  board_md5=%s local_md5=%s  %s"
          % (a.remote, local, size, want[:8], got[:8], "OK" if ok else "MISMATCH"))
    return 0 if ok else 1


def cmd_ls(a):
    rc, out, err = BS.run("ls -l %s" % _q(a.remote), timeout=30)
    sys.stdout.write(out.decode("utf-8", "replace"))
    if err:
        sys.stderr.write(err + "\n")
    return rc


# 板内一次性读 32 位寄存器的 helper（只读；不写任何 CSR ⇒ 不会扰动在跑的通路）
_STATUS_SCRIPT = r"""
echo "== board =="
uptime
free | head -3
df -h / 2>/dev/null | tail -1
echo "== net =="
ip -4 addr show 2>/dev/null | grep -E "inet |^[0-9]+:" | head -6
echo "== npu =="
for r in 00 04 30; do
  printf 'NPU+0x%s=' "$r"; devmem 0xF000C0$r 2>/dev/null || echo NA
done
echo "== video =="
for r in 00 04; do
  printf 'VID+0x%s=' "$r"; devmem 0xF00074$r 2>/dev/null || echo NA
done
echo "== y1cam =="
if [ -f /run/y1cam.pid ] && kill -0 "$(cat /run/y1cam.pid)" 2>/dev/null; then
  echo "running pid=$(cat /run/y1cam.pid)"
else
  echo "not running"
fi
"""


def cmd_status(a):
    rc, out, err = BS.run(_STATUS_SCRIPT, timeout=30)
    sys.stdout.write(out.decode("utf-8", "replace"))
    if err:
        sys.stderr.write("[stderr] " + err + "\n")
    return rc


def main(argv=None):
    ap = argparse.ArgumentParser(description="board remote command/file tool (ssh/scp/tftp)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("run", help="run a command on the board")
    p.add_argument("cmd")
    p.add_argument("--timeout", type=int, default=120)
    p.set_defaults(fn=cmd_run)

    p = sub.add_parser("put", help="host -> board (md5 verified)")
    p.add_argument("local")
    p.add_argument("remote", nargs="?")
    p.add_argument("--exec", action="store_true", help="chmod +x after upload")
    p.add_argument("--timeout", type=int, default=300)
    p.set_defaults(fn=cmd_put)

    p = sub.add_parser("get", help="board -> host (md5 verified)")
    p.add_argument("remote")
    p.add_argument("local", nargs="?")
    p.add_argument("--port", type=int, default=6969)
    p.add_argument("--blksize", type=int, default=4096)
    p.add_argument("--timeout", type=int, default=120)
    p.set_defaults(fn=cmd_get)

    p = sub.add_parser("ls", help="list a board directory")
    p.add_argument("remote")
    p.set_defaults(fn=cmd_ls)

    p = sub.add_parser("status", help="one-shot board health summary")
    p.set_defaults(fn=cmd_status)

    p = sub.add_parser("ping", help="connectivity + password channel check")
    p.set_defaults(fn=cmd_ping)

    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
