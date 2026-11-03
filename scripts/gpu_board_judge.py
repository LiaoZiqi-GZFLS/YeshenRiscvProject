#!/usr/bin/env python3
"""GPU/P0 上板判据（主机侧驱动）：把判据二进制送上板、跑、取判定。

前置（**用户给板窗口时才跑**）：
  · gpu：板上跑 `gpu4` 比特流（GPU 窗 0xF000_5000 + 第 4 主口 + 2D 引擎），卡是 sd_gpu0.img 或更新版；
  · cbo：板上跑 `gpu0` 比特流（带 zicbom 核）+ 同一张卡（固件 menvcfg / 内核 senvcfg 已在镜像里）；
  · 主机侧 ssh 通路可用（scripts/board_ssh.py 的 master 复用）。

判据：
  --test gpu（默认）：`gputest: err=0 seq=... DBG=0x........ => PASS`
      err 明细见 y1/tools/gputest.c：ID / FILL 棋盘 / ROUND_FILL / BLIT / GLYPH 逐像素、
      scissor 负对照、以及**判据自证**（故意改一个期望像素必须报 MISMATCH=1）。
  --test cbo：`CBO POS=1 NEG=1 ...`（rc=0）
      正例=写→cbo.flush→/dev/mem 直读一致；负例=不 flush 时读回不同。SIGILL 会打印
      `CBO SIGILL (cbo.flush 在该特权级被拒)` 并 rc=132 ⇒ 放行位没生效。

用法：
  python scripts/gpu_board_judge.py                # gputest：送 + 跑 + 判定
  python scripts/gpu_board_judge.py --test cbo     # cbotest：送 + 跑 + 判定
  python scripts/gpu_board_judge.py --no-push      # 板上已有 /tmp/<bin>，只跑
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import board_ssh  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TESTS = {
    "gpu": {
        "local": os.path.join(ROOT, "y1", "build", "gputest"),
        "remote": "/tmp/gputest",
        "args": "",
    },
    "cbo": {
        "local": os.path.join(ROOT, "y1", "build", "cbotest"),
        "remote": "/tmp/cbotest",
        "args": " 0x12345678",
    },
    "3d": {
        "local": os.path.join(ROOT, "y1", "build", "gputest3d"),
        "remote": "/tmp/gputest3d",
        "args": "",
    },
}


def _s(x):
    # board_ssh.run 的 out/err 可能是 bytes 也可能是 str（不同分支），统一成 str
    if isinstance(x, (bytes, bytearray)):
        return x.decode("utf-8", "replace")
    return x or ""


def judge(text, test):
    if test in ("gpu", "3d"):
        m = re.search(r"=>\s*(PASS|FAIL)", text)
        if m is None:
            return None
        return m.group(1)
    m = re.search(r"CBO POS=(\d)\s+NEG=(\d)\s+GATE=(\d)", text)
    if m is None:
        return None
    return "PASS" if all(g == "1" for g in m.groups()) else "FAIL"


def main(argv):
    do_push = "--no-push" not in argv
    test = "gpu"
    if "--test" in argv:
        i = argv.index("--test")
        if i + 1 >= len(argv) or argv[i + 1] not in TESTS:
            print("FAIL: --test 只接受 %s" % "|".join(TESTS))
            return 2
        test = argv[i + 1]
    spec = TESTS[test]

    if do_push:
        if not os.path.isfile(spec["local"]):
            print("FAIL: 没有 %s（先跑 y1/tools/build_%s.sh）" % (spec["local"], test))
            return 2
        rc, txt = board_ssh.put(spec["local"], spec["remote"], timeout=300)
        if rc != 0:
            # scp -O 与 ssh stdin 两条路都可能被 WSL 路径改写弄坏（rc=255）——
            # 退到 put_bytes（走 run() 的 stdin 通路，实测可用）
            print("scp 上传失败（rc=%d），改用 put_bytes 重试" % rc)
            with open(spec["local"], "rb") as f:
                data = f.read()
            rc, txt = board_ssh.put_bytes(spec["remote"], data, timeout=600)
            if rc != 0:
                print("FAIL: 上传失败（rc=%d）\n%s" % (rc, txt[-400:]))
                return 2
        print("pushed: %s -> %s（%d B）" % (spec["local"], spec["remote"],
                                           os.path.getsize(spec["local"])))

    board_ssh.run("chmod 755 %s" % spec["remote"], timeout=60)
    rc, out, err = board_ssh.run("%s%s; echo RC=$?" % (spec["remote"], spec["args"]), timeout=300)
    text = _s(out) + _s(err)
    print(text.strip())

    v = judge(text, test)
    if v is None:
        print("VERDICT: NO-VERDICT（板上没打印判定行；先看上面的输出）")
        return 1
    print("VERDICT:", v)
    return 0 if v == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
