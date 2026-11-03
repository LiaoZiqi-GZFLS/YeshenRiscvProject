#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""capture_raw_outputs.py —— 把**当前 DDR 里**的 12 路 NPU 输出原样抓成逐字节黄金。

用途：给板内 C runner（y1run）的 payload 提供 golden（build_board_payload.py --golden-raw）。
注意：它**不跑帧**，抓的是板子 DDR 里现有的内容（= 最近一次 --run 的输出）；
      抓之前先确认板子没有被别的会话跑过（本脚本打印每块的 crc32/md5 供对账）。

用法（cwd=y1）：
  PYTHONPATH='./.pydeps;../third_party/yunet/deps' python tools/capture_raw_outputs.py \
      --out build/s4c/raw_golden --net-tries 8
"""
import argparse
import hashlib
import json
import os
import sys
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
Y1 = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(Y1), "scripts"))
os.chdir(Y1)

import npu_frame_run as NFR  # noqa: E402
import board_ddr as BDD  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--net-dir", default="/tmp/npu_f1")
    ap.add_argument("--net-chunk", type=int, default=262144)
    ap.add_argument("--net-tries", type=int, default=8)
    ap.add_argument("--ddmem", default=os.path.join("build", "ddmem_rv32"))
    args = ap.parse_args()

    descs, dmd5, raw, sent_ok = NFR.load_desc()
    index = NFR.load_index()
    plan = NFR.build_output_plan(descs, index, NFR.onnx_out_map())
    os.makedirs(args.out, exist_ok=True)

    bdd = BDD.BoardDdr(workdir=args.net_dir, chunk=args.net_chunk,
                       tries=args.net_tries, quiet=False)
    bdd.prepare(os.path.abspath(args.ddmem))
    rows = []
    t0 = time.time()
    for p in plan:
        n = int(p["nbytes"])
        phys = NFR.phys(p["addr"])
        b = bdd.read(phys, n)
        fp = os.path.join(args.out, p["name"] + ".bin")
        with open(fp, "wb") as f:
            f.write(b)
        rows.append({"name": p["name"], "desc_idx": p["desc_idx"], "npu": "0x%08X" % p["addr"],
                     "phys": "0x%08X" % phys, "bytes": n,
                     "crc32": "%08x" % (zlib.crc32(b) & 0xFFFFFFFF),
                     "md5": hashlib.md5(b).hexdigest()})
        print("  %-8s %7d B phys=0x%08X crc32=%s md5=%s"
              % (p["name"], n, phys, rows[-1]["crc32"], rows[-1]["md5"][:16]))
    with open(os.path.join(args.out, "plan.json"), "w", encoding="utf-8") as f:
        json.dump({"desc_md5": dmd5, "outputs": rows}, f, indent=1)
    print("CAPTURE %s  %d 块  %.1f s  stats=%s"
          % (args.out, len(rows), time.time() - t0, bdd.stats))
    bdd.close()


if __name__ == "__main__":
    main()
