#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""board_ssh.py —— 板内**带外**（网络/ssh）命令与字节搬运的**唯一入口**。

============================ 为什么是这个形状 ============================
`docs/board_bringup.md` §6 与 `scripts/flash_and_verify.py` 已经钉死了本工程唯一可用的
ssh 走法：**Windows 侧没有可用的 ssh 口令通道**（Git Bash 的 ssh 即使 `SSH_ASKPASS_REQUIRE=force`
也拿不到 dropbear 的口令，实测 `Permission denied, please try again` ×2），
而 **WSL 里有**（`$HOME/askpass.sh` + `SSH_ASKPASS_REQUIRE=force`）。
dropbear ↔ 新版 OpenSSH 的 PQ-KEX 互操作问题也必须压 KEX（`curve25519-sha256` / `ssh-ed25519`），
否则客户端停在 `expecting SSH2_MSG_KEX_ECDH_REPLY` 一百多秒（见 `docs/开发板功能清单-2026-10-08.md`）。
⇒ 本文件把这套走法**封装成一个函数**，别的脚本不再各写一份。

另两个坑（都踩过）：
  · `wsl.exe` 自己的消息默认发 **UTF-16LE**：必须 `WSL_UTF8=1`，否则 ssh 的 ASCII 输出会和
    前一行警告混成乱码（实测 `TOUCHOK` 被读成 `佔䍕佈K`）。
  · **stdout 必须是 8-bit 干净**的字节流：二进制一律走 `base64`（板内 busybox 有），
    绝不让裸二进制过 Windows 管道。

============================ API ============================
    run(cmd, timeout=120, stdin=None) -> (rc, stdout_bytes, stderr_text)
    run_text(cmd, ...)                -> (rc, stdout_utf8)
    put(local_path, remote_path)      -> (rc, text)            # scp
    get_b64(remote_path)              -> bytes                 # 板内 base64 出来再解
    put_bytes(remote_path, data)      -> (rc, text)            # 经 stdin 写过去（小文件）
    ensure_askpass()                  -> bool

CLI：`python scripts/board_ssh.py "<remote cmd>"` 方便手搓排查。
环境变量：`BOARD_IP`（默认 192.168.1.110）、`BOARD_USER`（root）。
"""
import os
import posixpath
import re
import subprocess
import sys
import base64

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

BOARD_IP = os.environ.get("BOARD_IP", "192.168.1.110")
BOARD_USER = os.environ.get("BOARD_USER", "root")
BOARD_PW = os.environ.get("BOARD_PW", "yeshen")

SSH_OPTS = [
    "-q",
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "PreferredAuthentications=password",
    "-o", "PubkeyAuthentication=no",
    "-o", "KexAlgorithms=curve25519-sha256",
    "-o", "HostKeyAlgorithms=ssh-ed25519",
    "-o", "ConnectTimeout=10",
    "-o", "ServerAliveInterval=5",
    "-o", "ServerAliveCountMax=4",
    # ★ 2026-10-26：**连接复用**（master 由 ensure_master() 显式拉起）。
    #   板子单核 + 3% 丢包 + ed25519 主机签名慢：每次新开 TCP+KEX 要 2~15 s，且约一半
    #   会话在认证/密钥交换阶段卡死 25 s（实测 rc=124）。改成"一条常驻 master + 所有
    #   命令/scp 走它的 channel"：实测 0.07~1 s/条、0 失败（原 2~15 s、40% 成功）。
    #   注意**不要**在 SSH_OPTS 里写 ControlMaster=auto：fork 出的后台 master 会继承
    #   stdout，`$(ssh ...)` 会一直等 EOF 而挂死（实测 5 分钟不返回）。
    "-o", "ControlMaster=no",
    "-o", "ControlPath=/tmp/ssh-board-master",
    "-o", "TCPKeepAlive=yes",
]


# ---------------------------- WSL 桥 ----------------------------
def _wsl_env():
    e = dict(os.environ)
    e["WSL_UTF8"] = "1"
    e["MSYS_NO_PATHCONV"] = "1"
    return e


def wsl_bash(script, timeout=180, stdin_bytes=None):
    """在 WSL 里跑一段 bash，返回 (rc, stdout_bytes, stderr_text)。stdout 是**裸字节**。"""
    try:
        p = subprocess.run(["wsl", "-e", "bash", "-lc", script],
                           input=stdin_bytes, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, env=_wsl_env(), timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, b"", "wsl/ssh timeout after %ss" % timeout
    err = p.stderr.decode("utf-8", "replace")
    return p.returncode, p.stdout, err


def _sq(s):
    """POSIX 单引号转义（给 remote cmd 用）。"""
    return "'" + s.replace("'", "'\\''") + "'"


def askpass_path():
    return "$HOME/askpass.sh"


def ensure_askpass():
    """WSL 侧备好 askpass（幂等）。口令只写在脚本里，不进命令行。"""
    script = ("printf '#!/bin/sh\\necho %s\\n' > $HOME/askpass.sh && chmod +x $HOME/askpass.sh "
              "&& echo ASKPASS_OK" % BOARD_PW)
    rc, out, _ = wsl_bash(script, timeout=60)
    return rc == 0 and b"ASKPASS_OK" in out


def _ssh_prefix(timeout):
    return ("SSH_ASKPASS=%s SSH_ASKPASS_REQUIRE=force timeout %d ssh %s %s@%s "
            % (askpass_path(), int(timeout), " ".join(SSH_OPTS), BOARD_USER, BOARD_IP))


# ---------------------------- 常驻 master（连接复用） ----------------------------
MASTER = "/tmp/ssh-board-master"
_master_ok_until = 0.0


def master_alive():
    rc, out, err = wsl_bash("ssh -S %s -O check %s@%s" % (MASTER, BOARD_USER, BOARD_IP),
                            timeout=15)
    return rc == 0


def ensure_master(tries=3, timeout=45):
    """确保板上有一条常驻 ssh 连接；后续命令/传输都复用它（省掉 2~15 s 的握手）。

    板子单核 + 3% 丢包时，新开连接的 KEX/认证会**慢到十几秒且常卡死**；复用后实测
    0.07~1 s/条。master 用 `-f -N -M` 完全脱离 stdio（否则 `$(ssh ...)` 会等 EOF 挂死）。
    """
    global _master_ok_until
    import time as _t
    if _t.time() < _master_ok_until and master_alive():
        return True
    for t in range(tries):
        cmd = ("SSH_ASKPASS=%s SSH_ASKPASS_REQUIRE=force timeout %d "
               "ssh -f -N -M -S %s -o ControlPersist=600 %s %s@%s"
               % (askpass_path(), int(timeout), MASTER, " ".join(SSH_OPTS),
                  BOARD_USER, BOARD_IP))
        rc, out, err = wsl_bash(cmd, timeout=timeout + 10)
        if rc == 0 and master_alive():
            _master_ok_until = _t.time() + 120.0
            return True
    _master_ok_until = 0.0
    return False


# ---------------------------- API ----------------------------
def master_reset():
    """丢弃当前 master（会话卡死时用）。下一次 ensure_master() 会重建。"""
    global _master_ok_until
    _master_ok_until = 0.0
    wsl_bash("ssh -S %s -O exit %s@%s 2>/dev/null; rm -f %s"
             % (MASTER, BOARD_USER, BOARD_IP, MASTER), timeout=15)


def run(cmd, timeout=120, stdin=None, log=None):
    """板内跑一条命令（**不分配 tty** ⇒ 不碰 COM7 控制台）。返回 (rc, stdout_bytes, stderr)。

    ★ 2026-10-26：走常驻 master；若整条会话超时（rc=124，板侧 sshd 偶发卡死），
    **重建 master 再试一次**——实测这是"某次命令把连接卡住后，后续全废"的唯一可靠解法。
    """
    ensure_master()
    script = _ssh_prefix(timeout) + _sq(cmd)
    rc, out, err = wsl_bash(script, timeout=timeout + 30, stdin_bytes=stdin)
    if rc in (124, 255):
        master_reset()
        ensure_master()
        rc, out, err = wsl_bash(script, timeout=timeout + 30, stdin_bytes=stdin)
    if log is not None:
        log.write("$ %s\n" % cmd)
        log.write(out.decode("utf-8", "replace"))
        if err.strip():
            log.write("[stderr] %s\n" % err)
        log.flush()
    # 把 wsl.exe 自己的告警行剔掉（不影响解析）
    err = "\n".join(l for l in err.splitlines()
                    if not l.startswith("wsl:") and l.strip())
    return rc, out, err


def run_text(cmd, timeout=120, stdin=None, log=None):
    rc, out, err = run(cmd, timeout=timeout, stdin=stdin, log=log)
    return rc, out.decode("utf-8", "replace")


def _wsl_path(p):
    """Windows 路径 -> WSL /mnt/... 路径（已在 WSL 里的路径原样返回）。"""
    p = os.path.abspath(p).replace("\\", "/")
    m = re.match(r"^([A-Za-z]):/(.*)$", p)
    if m:
        return "/mnt/%s/%s" % (m.group(1).lower(), m.group(2))
    return p


def put(local_path, remote_path, timeout=180):
    """把一个本地文件送上板。返回 (rc, text)。

    ⚠️ 必须 `scp -O`：新版 OpenSSH 的 scp 默认走 **SFTP** 子系统，而板内 dropbear 只有
    sftp-server 没有/不在标准路径 ⇒ 实测 `sh: /usr/libexec/sftp-server: not found`。
    `-O` 回到老的 SCP 协议（板内 busybox/dropbear 都认）。scp 不通再退到 `ssh "cat > ..."`。
    """
    lp = _sq(_wsl_path(local_path))
    ensure_master()
    pre = ("SSH_ASKPASS=%s SSH_ASKPASS_REQUIRE=force timeout %d "
           % (askpass_path(), int(timeout)))
    cmd = (pre + "scp -O %s %s %s@%s:%s 2>&1"
           % (" ".join(SSH_OPTS), lp, BOARD_USER, BOARD_IP, _sq(remote_path)))
    rc, out, err = wsl_bash(cmd, timeout=timeout + 30)
    txt = out.decode("utf-8", "replace") + err
    if rc == 0:
        return rc, txt
    # 退路：ssh stdin 直灌（不依赖 sftp-server）
    cmd2 = (pre + "ssh %s %s@%s %s 2>&1"
            % (" ".join(SSH_OPTS), BOARD_USER, BOARD_IP, _sq("cat > " + remote_path)))
    rc2, out2, err2 = wsl_bash(cmd2 + " < " + lp, timeout=timeout + 30)
    return rc2, out2.decode("utf-8", "replace") + err2


def put_bytes(remote_path, data, timeout=180):
    """经 ssh stdin 把字节写到板内文件（小文件；大件用 put）。"""
    cmd = "cat > %s" % remote_path
    rc, out, err = run(cmd, timeout=timeout, stdin=data)
    return rc, err


def get_b64(remote_path, timeout=120):
    """板内 base64 编码后取回并解码（8-bit 干净）。返回 (rc, bytes)。"""
    rc, out, _ = run("base64 %s" % remote_path, timeout=timeout)
    if rc != 0:
        return rc, b""
    try:
        return 0, base64.b64decode(out)
    except Exception:
        return 1, b""


def get_file(remote_path, local_path, chunk=65536, timeout=120, tries=5):
    """板 → 主机的大文件搬运（**分块 + 每块重试 + 末尾 md5 对账**）。

    为什么这么写：ssh 直出大 stdout 会中途掉线（rc=255），tftp 在这条链路上也会停等超时；
    但复用 master 之后**单块 64 KiB 的 base64**（≈87 KB）稳定。块按 64 KiB 对齐 ⇒ 板内
    `dd bs=65536 skip=k count=1` 只做一次拷贝，RV32 上也很快。

    返回 (ok, 说明)；ok 只在"字节数对 + md5 相等"时为真。
    """
    import hashlib as _h
    ensure_master()
    rc, out, _ = run("wc -c < %s" % remote_path, timeout=30)
    try:
        n = int(out.strip() or 0)
    except ValueError:
        n = 0
    if n <= 0:
        return False, "stat 失败/空文件（rc=%s）" % rc
    buf = bytearray()
    nb = (n + chunk - 1) // chunk
    for k in range(nb):
        ln = min(chunk, n - k * chunk)
        ok = False
        for t in range(tries):
            rc, out, err = run("dd if=%s bs=%d skip=%d count=1 2>/dev/null | base64"
                               % (remote_path, chunk, k), timeout=timeout)
            if rc == 0 and out.strip():
                try:
                    buf += base64.b64decode(out)
                    ok = True
                    break
                except Exception:
                    pass
        if not ok:
            return False, "块 %d/%d 失败（%d 试）" % (k + 1, nb, tries)
    if len(buf) != n:
        return False, "长度不符 %d != %d" % (len(buf), n)
    with open(local_path, "wb") as f:
        f.write(bytes(buf))
    rc, out, _ = run("md5sum %s" % remote_path, timeout=30)
    want = out.split()[0].decode() if out.split() else ""
    got = _h.md5(bytes(buf)).hexdigest()
    return (got == want), "md5 %s vs 板上 %s" % (got, want)


def md5_hex(s):
    import hashlib
    return hashlib.md5(s).hexdigest()


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    ensure_askpass()
    rc, out, err = run(argv[1], timeout=int(argv[2]) if len(argv) > 2 else 60)
    sys.stdout.write(out.decode("utf-8", "replace"))
    if err:
        sys.stderr.write(err + "\n")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
