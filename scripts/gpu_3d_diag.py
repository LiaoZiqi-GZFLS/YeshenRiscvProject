#!/usr/bin/env python3
"""GPU 3D 上板取证（主机侧驱动）：复现挂死 + 从**另一个进程**读走内部状态。

背景（2026-11-01）：`gputest3d` 在板上跑到第 3 组命令附近就不动了，主机卡在 FIFO 空位
轮询里；上一轮因为 stdout 全缓冲，连"停在哪一步"都没留下。本脚本把两件事一次做完：

  1. 把 `gputest3d` 丢到后台跑，**每 2 秒**看一次它的日志（关缓冲后每一步都有打点）；
  2. 一旦 30 秒内没出现判定行，就调用 `gpu3dprobe 640 480 2` —— 这是**只读观察模式**：
     不推命令、只每秒 dump 一次 CSR，所以不会干扰已经挂住的 GPU。它给出：
       · DBG[23:16] = gpu_3d FSM 状态（0=IDLE … 见 rtl/gpu/gpu_3d.v 的 localparam）
       · DBG2       = 最近一次读 burst 的 AR 地址（32 B 对齐后的）
       · DBG3       = {[31:24] 写侧 wrs/wcnt, [23:16] rd_len, [15:8] rd_cnt, [7:0] 0xA5}
       · DBG4/DBG5  = 该 burst 前 4 拍数据的低 16 位
     读 `rd_cnt < rd_len+1` ⇒ 卡在读数据；`rd_cnt == rd_len+1` 且 3D 状态在写回 ⇒ 卡在写完成。
  3. 收尾：杀掉后台的 gputest3d（它自己是死等循环），把证据整段打印出来。

用法（**需要板窗口**）：
    python scripts/gpu_3d_diag.py --run          # 全套：上传 + 跑 + 必要时取证
    python scripts/gpu_3d_diag.py --run --no-push   # 板上已有 /tmp/gputest3d，只跑
    python scripts/gpu_3d_diag.py --run --wait 60   # 判定等待上限（秒，默认 30）

⚠️ 必须显式给 `--run`：这是**真板动作**（会上传二进制、killall、跑 GPU 命令）。
   没有 `--run` 只打印用法并退出，避免被 "顺手跑一下 --help" 之类的调用误触发。

判据打印形状：出现 `gputest3d: err=... => PASS|FAIL` 就算跑完；否则打印 `HUNG` + 快照。
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import board_ssh  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEST_BIN = os.path.join(ROOT, "y1", "build", "gputest3d")
PROBE_BIN = os.path.join(ROOT, "y1", "build", "gpu3dprobe")
TEST_REM = "/tmp/gputest3d"
PROBE_REM = "/tmp/gpu3dprobe"
LOG_REM = "/tmp/g3d.log"


def _s(x):
    if isinstance(x, (bytes, bytearray)):
        return x.decode("utf-8", "replace")
    return x or ""


def push(local, remote):
    if not os.path.isfile(local):
        print("FAIL: 没有 %s（先跑 y1/tools/build_%s.sh）"
              % (local, os.path.basename(local).replace("gpu3d", "gpu3d")))
        return False
    rc, txt = board_ssh.put(local, remote, timeout=300)
    if rc == 0:
        print("pushed: %s -> %s（%d B）" % (local, remote, os.path.getsize(local)))
        return True
    print("scp 上传失败（rc=%d），改走 put_bytes" % rc)
    with open(local, "rb") as f:
        data = f.read()
    rc, txt = board_ssh.put_bytes(remote, data, timeout=600)
    if rc != 0:
        print("FAIL: 上传失败（rc=%d）%s" % (rc, _s(txt)[-300:]))
        return False
    print("pushed(put_bytes): %s -> %s（%d B）" % (local, remote, len(data)))
    return True


def main(argv):
    if "--run" not in argv:
        print(__doc__)
        print("（未给 --run：什么都不做）")
        return 0
    do_push = "--no-push" not in argv
    wait_s = 30
    if "--wait" in argv:
        i = argv.index("--wait")
        if i + 1 < len(argv):
            wait_s = int(argv[i + 1])

    if do_push:
        if not push(TEST_BIN, TEST_REM):
            return 2
        if not push(PROBE_BIN, PROBE_REM):
            return 2

    board_ssh.run("chmod 755 %s %s" % (TEST_REM, PROBE_REM), timeout=60)
    # 上一轮挂死后遗留的实例会互抢 FIFO，先清干净
    board_ssh.run("killall gputest3d gpu3dprobe 2>/dev/null; rm -f %s" % LOG_REM, timeout=60)

    print("== 后台启动 gputest3d（输出不缓冲，逐步打点）==")
    rc, out, err = board_ssh.run(
        "cd /tmp && setsid %s > %s 2>&1 < /dev/null & echo started" % (TEST_REM, LOG_REM),
        timeout=60)
    print(_s(out).strip(), _s(err).strip())

    verdict = None
    waited = 0
    while waited < wait_s:
        time.sleep(2)
        waited += 2
        rc, out, err = board_ssh.run("cat %s" % LOG_REM, timeout=60)
        txt = _s(out) + _s(err)
        if "=> PASS" in txt or "=> FAIL" in txt:
            verdict = "DONE"
            break
        tail = [ln for ln in txt.strip().splitlines() if ln.strip()][-1:] or ["(空)"]
        print("  [%2ds] %s" % (waited, tail[0][:110]))

    rc, out, err = board_ssh.run("cat %s" % LOG_REM, timeout=60)
    log = _s(out) + _s(err)
    print("== gputest3d 日志（全文）==")
    print(log.strip())

    if verdict is None:
        print("== 判定：HUNG（%d 秒内没有判定行）==" % wait_s)
        print("== 只读取证：gpu3dprobe 640 480 2（不推命令，每秒 dump 一次 CSR）==")
        rc, out, err = board_ssh.run("%s 640 480 2" % PROBE_REM, timeout=120)
        print((_s(out) + _s(err)).strip())
        print("== 收尾：杀掉后台 gputest3d ==")
        board_ssh.run("killall gputest3d", timeout=60)
        return 3

    print("== 判定：%s ==" % ("PASS" if "=> PASS" in log else "FAIL"))
    return 0 if "=> PASS" in log else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
