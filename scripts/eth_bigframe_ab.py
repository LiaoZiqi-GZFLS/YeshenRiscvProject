#!/usr/bin/env python3
"""eth_bigframe_ab.py -- 验证「板 → 主机发大帧（>~1 KB）坏」这件事，两侧独立观测的 A/B。

被测主张（工作区里那份非我所写的记录）：小帧通、**大帧（>~1 KB）一个字节都发不出去**。
本脚本不去"证明它"，而是给它**两个独立观测量**，让结论自己浮出来：

  板内（串口，独立于网络）：GMII 观测窗 `0xF000B010`(W4: txBytes/rxBytes) 与 `0xF000B014`
      (W5: rxRunMax/txRunMax)。**`txRunMax` = MAC 见过的最长连续 tx_en 拍数** =>
      一帧 1442 B 应当给出 ~1450；若它停在 ~101（历史值）就是"MAC 根本没把长帧连续发出去"。
  主机（ifIndex5 = 板子的对口网卡）：`ReceivedBytes / ReceivedUnicastPackets` 增量
      => 板子发的帧**到底有没有到主机**（独立于板子的自述）。

A/B 两臂：`-s 1000`（小帧正控，应通）与 `-s 1400`（大帧被测）。ICMP 载荷 S => 帧长 ≈ S+42。

⚠️ 按被测主张，大帧那臂**可能把板子卡死**：本脚本尽量容错（每步超时），
   真卡死了恢复办法 = **重烧一次比特流**（重跑 SoC POR 让 Linux 从卡重启，不用重写卡）。

用法：python -u scripts/eth_bigframe_ab.py [COM] [BAUD] [主机IP]
"""
import re
import subprocess
import sys
import time

# Windows 控制台是 GBK：print 到非 GBK 字符（⇒/✓ 等）会 UnicodeEncodeError 把脚本打死
# ⇒ 一律按本工程的纪律做 ASCII 消毒（不可编码的字符替换掉，绝不因为打印而中断采集）。
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(errors="replace")

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM7"
BAUD = sys.argv[2] if len(sys.argv) > 2 else "115200"
HOSTIP = sys.argv[3] if len(sys.argv) > 3 else "192.168.1.105"
IFIDX = "5"
SIZES = [1000, 1400]


def guest(cmd, secs=25):
    r = subprocess.run([sys.executable, "-u", "scripts/guest_cmd.py", PORT, BAUD, cmd],
                       capture_output=True, text=True, errors="replace", timeout=secs)
    return r.stdout


def ps(cmd):
    return subprocess.run(["powershell", "-NoProfile", "-Command", cmd],
                          capture_output=True, text=True, errors="replace").stdout


def host_rx():
    o = ps(f"(Get-NetAdapter -InterfaceIndex {IFIDX} | Get-NetAdapterStatistics) | "
           "Select-Object ReceivedBytes,ReceivedUnicastPackets | ConvertTo-Csv -NoTypeInformation")
    rows = [l for l in o.splitlines() if re.match(r'^"\d', l)]
    if not rows:
        return None
    b, u = (int(x.strip('"')) for x in rows[0].split(","))
    return dict(bytes=b, ucast=u)


def board_gmii():
    """板内观测。⚠️ GMII 观测窗（0xF000B0xx）的计数器是 **16bit txBytes/rxBytes、8bit runMax**
    => 早就在 65535/255 打满了（实测），**不能再当判据**。改读：
      · /proc/net/dev 的 eth0 tx/rx 包数·字节数（驱动级，64bit，不饱和）
      · 仍把观测窗一起读回来，只为**记录它已饱和**这个事实
    命令保持短。"""
    o = guest("grep eth0 /proc/net/dev; printf 'GM %s %s\\n' $(devmem 0xF000B010) $(devmem 0xF000B014)")
    m = re.search(r"eth0:\s*(\d+)\s+(\d+)\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+(\d+)\s+(\d+)", o)
    g = re.search(r"GM\s+0x([0-9A-Fa-f]{8})\s+0x([0-9A-Fa-f]{8})", o)
    if not m:
        return None
    d = dict(rxBytes=int(m.group(1)), rxPackets=int(m.group(2)),
             txBytes=int(m.group(3)), txPackets=int(m.group(4)))
    if g:
        w4, w5 = int(g.group(1), 16), int(g.group(2), 16)
        d["win_txBytes"] = w4 >> 16
        d["win_txRunMax"] = (w5 >> 16) & 0xFF
        d["win_saturated"] = (w4 >> 16) == 0xFFFF and ((w5 >> 16) & 0xFF) == 0xFF
    return d


print("== 0) 先登控制台（观测通道；它走 UART，不受网口大帧缺陷影响）==")
subprocess.run([sys.executable, "-u", "scripts/uart_login_pw.py", PORT, BAUD, "yeshen"],
               capture_output=True, text=True, errors="replace", timeout=60)

base = board_gmii()
print(f"  板内基线: {base}")
if base is None:
    print("  !! 读不到观测窗；先确认串口/登录");  sys.exit(1)

ARMS = [
    ("单发·小帧", f"ping -c 3 -s 1000 {HOSTIP}"),
    ("单发·大帧", f"ping -c 3 -s 1400 {HOSTIP}"),
    ("批量·大帧", f"ping -c 100 -i 0.02 -s 1400 {HOSTIP}"),
]

for name, cmd in ARMS:
    print(f"\n===== 臂 {name}：`{cmd}` =====")
    b0, h0 = board_gmii(), host_rx()
    if b0 is None:
        print("  !! 读不到板内计数（板子可能已卡死）");  break
    if b0.get("win_saturated"):
        print("  （注意：GMII 观测窗计数已饱和 0xFFFF/0xFF => 那一列只作「仪器已打满」的记录）")
    t0 = time.time()
    try:
        out = guest(cmd, secs=60)
    except subprocess.TimeoutExpired:
        out = "<guest_cmd 超时>"
    dt = time.time() - t0
    txt = re.sub(r"[^\x20-\x7E\n]", "", out)
    print("  板发送:", [l for l in txt.splitlines() if "packet" in l or "loss" in l][-1:] or "?")
    b1, h1 = board_gmii(), host_rx()
    if b1 is None or h1 is None:
        print(f"  !! 复测读不到（板子/网络卡死）耗时 {dt:.1f}s => 需要重烧恢复")
        sys.exit(2)
    dtxp, dtxb = b1["txPackets"] - b0["txPackets"], b1["txBytes"] - b0["txBytes"]
    hrx, huc = h1["bytes"] - h0["bytes"], h1["ucast"] - h0["ucast"]
    print(f"  板内(驱动级): tx_packets +{dtxp}  tx_bytes +{dtxb}")
    print(f"  主机(capture): bytes +{hrx}  unicast +{huc}   [耗时 {dt:.1f}s]")
    ok = (dtxp > 0) and (huc > 0) and (hrx > 0)
    print("  判读: " + ("**发出去了**（板侧 tx>0 且主机侧也收到）" if ok else "**没发成**（一侧为 0）"))

print("\n== 结论口径 ==")
print("  · 两臂都好 => 该主张不成立（要另找解释）")
print("  · 单发好 / 批量坏 => **主张成立**，且限定了条件：单帧能发，**持续/批量 TX 会卡**")
print("  · 都坏 => 更严重（连单发都不行）")
print("  · 板子卡死 => 重烧比特流恢复（pds/flash_yeshen.tcl，TAG=m9）")
