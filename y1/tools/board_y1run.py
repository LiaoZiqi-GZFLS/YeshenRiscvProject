#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""board_y1run.py —— 主机侧：投 payload/runner 到板子，然后跑板内纯 C 整帧 runner。

payload → 物理 0x81E00000（第 5 卡槽同一位置；本脚本用于卡镜像落地前的联调）。
runner  → /tmp/npu_f1/y1run（scp）。
判据全部在板内（y1run 自己校验 payload CRC、回读 CRC、12 路输出 CRC/逐字节），
本脚本只负责投递与收 stdout（--quiet 保证输出 <1.5 KB，避开 ssh 大 stdout 的坑）。

用法（cwd=y1）：
  PYTHONPATH='./.pydeps;../third_party/yunet/deps' python tools/board_y1run.py \
      --payload build/y1_payload.bin --runner build/y1run_rv32 --frames 1
  # 已投过：--no-upload --skip-copy --frames 3
"""
import argparse
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
Y1 = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(os.path.dirname(Y1), "scripts"))
os.chdir(Y1)

import board_ddr as BDD  # noqa: E402
import board_ssh as BS  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--payload", default="build/y1_payload.bin")
    ap.add_argument("--payload-phys", type=lambda s: int(s, 0), default=0x81E00000)
    ap.add_argument("--runner", default="build/y1run_rv32")
    ap.add_argument("--remote-dir", default="/tmp/npu_f1")
    ap.add_argument("--frames", type=int, default=1)
    ap.add_argument("--no-upload", action="store_true")
    ap.add_argument("--runner-only", action="store_true", help="只重传 runner，不传 payload")
    ap.add_argument("--reset-delay-us", type=int, default=None)
    ap.add_argument("--poison", action="store_true", help="起跑前把输出区填 0x5A（负对照）")
    ap.add_argument("--skip-copy", action="store_true")
    ap.add_argument("--net-chunk", type=int, default=262144)
    ap.add_argument("--net-tries", type=int, default=8)
    ap.add_argument("--timeout", type=float, default=180.0)
    args = ap.parse_args()

    bdd = BDD.BoardDdr(workdir=args.remote_dir, chunk=args.net_chunk,
                       tries=args.net_tries, quiet=False, timeout=args.timeout)
    bdd.prepare(os.path.abspath(os.path.join("build", "ddmem_rv32")))
    if not args.no_upload:
        data = open(args.payload, "rb").read()
        t0 = time.time()
        ev = bdd.write(args.payload_phys, data, label="y1_payload")
        print("PAYLOAD_UPLOAD %d B %.1f s md5=%s"
              % (len(data), time.time() - t0, ev["md5"]))
    if args.runner_only:
        rc, txt = BS.put(os.path.abspath(args.runner), args.remote_dir + "/y1run",
                         timeout=args.timeout)
        if rc != 0:
            print("JUDGE-RED: runner 上传失败 rc=%s %s" % (rc, txt.strip()[:200]))
            return 1
    elif not args.no_upload:
        rc, txt = BS.put(os.path.abspath(args.runner), args.remote_dir + "/y1run",
                         timeout=args.timeout)
        if rc != 0:
            print("JUDGE-RED: runner 上传失败 rc=%s %s" % (rc, txt.strip()[:200]))
            return 1
    cmd = ("chmod +x %s/y1run && %s/y1run --payload 0x%08X --frames %d --quiet%s%s%s"
           % (args.remote_dir, args.remote_dir, args.payload_phys, args.frames,
              " --skip-copy" if args.skip_copy else "",
              (" --reset-delay-us %d" % args.reset_delay_us) if args.reset_delay_us is not None else "",
              " --poison" if args.poison else ""))
    print("$ " + cmd)
    rc, out, err = BS.run(cmd, timeout=args.timeout + 60.0)
    txt = out.decode("utf-8", "replace")
    print(txt)
    if rc != 0:
        print("(ssh rc=%s err=%s)" % (rc, err.strip()[:200]))
    bdd.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())
