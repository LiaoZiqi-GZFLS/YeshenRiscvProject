#!/usr/bin/env python3
"""flash_and_verify.py -- 一键"烧板 + 验启动"，可选再跑网络判据。

做四件事（每件都留判据，不靠"看起来成功了"）：
  1) **前置检查**：同 cwd 是否有别的会话在动板子（cdt/pds/listen_uart 进程）、COM 口在不在
  2) **起采集**（t=0 覆盖完整启动）→ 烧写（cdt_js 自报端口；`flash_yeshen.tcl` 的 TAG 可传）
  3) **验启动 marker**：SDR 有帧 / OpenSBI banner / `Linux version` / `slots:` / dropbear / VEXIIYESHEN-OK
  4) （可选）**网络判据**：主机 ping（读整行"来自<板IP>的回复"）+ 一次 ssh（带 curve25519 KEX）

!! 本脚本**不动卡**（卡上镜像要变时先跑 `build_all.sh --only images,sdimg` + 写卡）。
!! 断电/换卡后 FPGA 配置会丢 => 重烧就是恢复手段之一（本脚本正好做这件事）。

用法：
  python -u scripts/flash_and_verify.py                       # 烧 m9 + 验启动
  python -u scripts/flash_and_verify.py --tag m10 --no-net
  python -u scripts/flash_and_verify.py --com COM7 --secs 150 --board 192.168.1.110
"""
import argparse
import glob
import os
import re
import socket
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PDS_BIN = os.environ.get("PDS_BIN", r"C:\Pango\PDS_2025.2-ads\bin")
LOG = os.path.join(ROOT, "sim", "reglogs")


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, errors="replace", **kw)


def ps_available_names():
    out = sh(["powershell", "-NoProfile", "-Command",
              "Get-CimInstance Win32_Process | Select-Object -ExpandProperty Name"]).stdout
    return out


def preflight(com):
    print("== 1/4 前置检查 ==")
    names = ps_available_names()
    busy = [n for n in ("cdt_cfg_shell.exe", "pds_shell.exe") if n.lower() in names.lower()]
    leftovers = []
    out = sh(["powershell", "-NoProfile", "-Command",
              "Get-CimInstance Win32_Process -Filter \"name='python.exe'\" | "
              "Select-Object -ExpandProperty CommandLine"]).stdout
    for ln in out.splitlines():
        if "listen_uart" in ln or "guest_cmd" in ln:
            leftovers.append(ln.strip()[:80])
    if busy:
        print(f"  !! 有 JTAG/PDS 进程在跑：{busy}（别的会话可能正在用板子）")
    if leftovers:
        print(f"  !! 有采集/交互脚本在跑（会占 {com}）：{leftovers}")
        print("     -> 先关掉它们再烧；本脚本不会替你杀进程")
    # COM 口
    try:
        import serial.tools.list_ports as lp
        ports = [p.device for p in lp.comports()]
        print(f"  串口: {ports}")
        if com not in ports:
            print(f"  !! {com} 不在列表里")
    except Exception as e:
        print("  (pyserial 不可用，跳过串口检查:", e, ")")
    jt = [n for n in ("cdt_js.exe",) if n.lower() in names.lower()]
    print(f"  cdt_js 状态: {'在跑' if jt else '未跑（脚本会起）'}")


def free_tcp_port(lo=62000, hi=63000):
    for p in range(lo, hi):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.bind(("127.0.0.1", p))
            return p
        except OSError:
            continue
        finally:
            s.close()
    return None


def _wait_port_log(logpath, tries=5):
    for _ in range(tries):
        try:
            txt = open(logpath, errors="replace").read()
        except FileNotFoundError:
            txt = ""
        m = re.search(r"port\s*:\s*(\d+)", txt)
        if m:
            return m.group(1), txt
        time.sleep(2)
    return None, (txt if 'txt' in locals() else "")


def start_cdt_js():
    """起/复用 JTAG 服务；默认口被 Windows 排除区占用时换空闲口（返回端口字符串）。"""
    logpath = os.path.join(LOG, "cdt_js.log")
    out = sh(["powershell", "-NoProfile", "-Command",
              "Get-CimInstance Win32_Process -Filter \"name='cdt_js.exe'\" | "
              "Select-Object -ExpandProperty ProcessId"]).stdout.strip()
    if out:
        print("  cdt_js 已在跑")
    else:
        print("  起 cdt_js ...")
        subprocess.Popen([os.path.join(PDS_BIN, "cdt_js.exe")],
                         stdout=open(logpath, "w"), stderr=subprocess.STDOUT)
        time.sleep(10)
    port, txt = _wait_port_log(logpath)
    if port:
        return port
    # 2026-10-18 实测：65420 会落进 Windows 动态保留区（65399-65498）=> Socket bind error。
    if "Socket bind error" in txt or "listening port" in txt:
        p = free_tcp_port()
        if p is None:
            return None
        print(f"  默认口被占（Socket bind error）=> 改用 {p}")
        subprocess.Popen([os.path.join(PDS_BIN, "cdt_js.exe"), "-port", str(p)],
                         stdout=open(logpath, "w"), stderr=subprocess.STDOUT)
        time.sleep(8)
        port, _ = _wait_port_log(logpath, tries=3)
        return port
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", default="m9")
    ap.add_argument("--com", default="COM7")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--secs", type=float, default=120.0, help="启动采集窗口（秒）")
    ap.add_argument("--board", default="192.168.1.110")
    ap.add_argument("--no-net", action="store_true", help="跳过网络判据")
    a = ap.parse_args()
    os.makedirs(LOG, exist_ok=True)

    preflight(a.com)

    print("== 2/4 起采集 + 烧写 ==")
    port = start_cdt_js()
    if port is None:
        print("  !! 读不到 cdt_js 自报端口");  return 3
    print(f"  cdt_js port = {port}（flash_yeshen.tcl 里写死 65420，不一致就得改）")
    raw = os.path.join(LOG, "fv_raw.bin")
    cap = os.path.join(LOG, "fv_boot.txt")
    cap_p = subprocess.Popen([sys.executable, "-u", os.path.join("scripts", "listen_uart.py"),
                              a.com, str(a.secs), str(a.baud), raw],
                             stdout=open(cap, "w"), stderr=subprocess.STDOUT, cwd=ROOT)
    time.sleep(3)
    env = dict(os.environ, YESHENMINI_TAG=a.tag, YESHENMINI_JTAG_PORT=str(port))
    fl = sh([os.path.join(PDS_BIN, "cdt_cfg_shell.exe"),
             "-file", os.path.join(ROOT, "pds", "flash_yeshen.tcl").replace("/", "\\")], env=env)
    ftxt = fl.stdout + fl.stderr
    open(os.path.join(LOG, "fv_flash.out"), "w", errors="replace").write(ftxt)
    tagline = [l for l in ftxt.splitlines() if "tag=" in l]
    donebit = re.findall(r"done bit\):\s*(\d)", ftxt)
    print("  " + (tagline[0].strip() if tagline else "(无 tag 行)"))
    print(f"  done bit = {donebit[-1] if donebit else '?'}（必须 1）")
    if not donebit or donebit[-1] != "1":
        cap_p.terminate()
        print("  !! 配置未成功（done bit != 1）=> 检查 cdt_js 端口/TF 卡/板子供电");  return 4

    print(f"== 3/4 等采集（{a.secs:.0f}s）==")
    cap_p.wait()

    print("== 4/4 验启动 marker ==")
    txt = open(cap, errors="replace").read()
    checks = [
        ("SD 装载有 SDR 帧",      re.search(r"\bSDR [0-9A-F]{18}", txt) is not None),
        # SDR 帧 = "SDR " + 18 hex；第 3 个 hex 字符的最高位 = dbg 的 bit31 = misoHi
        # （good 例 `SDR 20B418…` 第3字符 B => misoHi=1；坏例 `SDR 103A90…` 第3字符 3 => misoHi=0）
        ("SDR 里 misoHi=1（卡在）", re.search(r"\bSDR [0-9A-Fa-f]{2}[89A-Fa-f]", txt) is not None),
        ("OpenSBI banner",        "Platform Console Device" in txt or "OpenSBI" in txt),
        ("Linux 起来",            "Linux version 5.10" in txt),
        ("LiteEth 驱动+槽数",      re.search(r"liteeth .*eth0: irq .*slots:", txt) is not None),
        ("dropbear 起来",         "Starting dropbear sshd: OK" in txt),
        ("用户态 marker",         "VEXIIYESHEN-OK" in txt),
        ("登录提示符",            "login:" in txt),
    ]
    bad = 0
    for name, ok in checks:
        print(f"  [{'ok' if ok else '!!'}] {name}")
        bad += 0 if ok else 1
    if bad:
        print("  => 启动判据未全过；首查：卡插实（misoHi）、换卡后是否忘了重烧、串口是否被别的脚本占")
        return 1
    print("  => 启动 PASS")

    if a.no_net:
        print("（--no-net：跳过网络判据）");  return 0

    print("== 附加：网络判据 ==")
    p = sh(["powershell", "-NoProfile", "-Command", f"ping -n 3 -w 800 {a.board}"]).stdout
    reply = re.search(r"(\d+)\s*ms.*TTL=(\d+)", p) or re.search(r"TTL=(\d+)", p)
    print(f"  ping {a.board}: {'PASS' if reply else 'FAIL'}（必须读整行回复，别只看丢包率）")
    ssh = sh(["wsl", "-e", "bash", "-lc",
              'SSH_ASKPASS=$HOME/askpass.sh SSH_ASKPASS_REQUIRE=force timeout 30 ssh '
              '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null '
              '-o PreferredAuthentications=password -o PubkeyAuthentication=no '
              '-o KexAlgorithms=curve25519-sha256 -o HostKeyAlgorithms=ssh-ed25519 '
              f'root@{a.board} "echo FLASH_VERIFY_SSH_OK"'], env=dict(os.environ, MSYS_NO_PATHCONV="1"))
    print(f"  ssh: {'PASS' if 'FLASH_VERIFY_SSH_OK' in ssh.stdout else 'FAIL'}"
          f"（口令 yeshen；首次要 $HOME/askpass.sh）")
    return 0 if (reply and "FLASH_VERIFY_SSH_OK" in ssh.stdout) else 1


if __name__ == "__main__":
    sys.exit(main())
