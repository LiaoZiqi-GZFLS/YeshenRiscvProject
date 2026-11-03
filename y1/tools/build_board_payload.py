#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""build_board_payload.py —— 生成第 5 个 TF 卡槽的 Y1 payload（SdLoader → 物理 0x81E00000）。

payload 是**板内 C runner（y1run）唯一的数据来源**：input/desc/权重信箱映像/7346 条信箱记录/
12 路输出计划，以及可选的**逐字节黄金输出**。全部带 CRC32，板内启动时先校验再使用。

布局（小端，header 固定 1024 B，段按 64 B 对齐）：
  0   char magic[4]="Y1PL"     4  u32 version=1
  8   u32 total_size          12  u32 desc_count
  16  u32 n_outputs           20  u32 n_mb_records
  24  u32 input_npu           28  u32 desc_npu      32  u32 mbx_npu
  36  u32 mbx_bytes           40  u32 input_bytes   44  u32 golden_bytes
  48  u32 reserved[4]
  64  段表 6×{u32 off, u32 len, u32 crc32, u32 reserved}
       0=desc 1=wgt_mailbox 2=input 3=mb_records 4=golden_raw 5=reserved
  160 输出表 n_outputs×{char name[16], u32 npu_addr, u32 bytes, u32 crc32, u32 reserved}
      (12×32=384 → 到 544，仍在 1024 B header 内)

用法（cwd=y1；需要 numpy/onnx 的 Python）：
  PYTHONPATH='./.pydeps;../third_party/yunet/deps' python tools/build_board_payload.py \
      --img ../ai_npu_exp/deps_export/matplotlib/mpl-data/sample_data/grace_hopper.jpg \
      --golden-raw build/s4c/raw_golden --out build/y1_payload.bin
  # 或 --no-face
"""
import argparse
import json
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
Y1 = os.path.dirname(HERE)
sys.path.insert(0, HERE)
os.chdir(Y1)

import npu_frame_run as NFR  # noqa: E402

MAGIC = b"Y1PL"
VERSION = 1
HEADER = 1024
PAYLOAD_BASE = 0x81E00000
PAYLOAD_LIMIT = 0x82000000 - PAYLOAD_BASE   # 2 MiB
ARENA_HW_LIMIT = PAYLOAD_BASE               # 任何输出不得碰到 payload 区

SEG_DESC, SEG_WGT, SEG_INPUT, SEG_MB, SEG_GOLDEN = 0, 1, 2, 3, 4
SEG_NAMES = ["desc", "wgt_mailbox", "input_int8", "mb_records", "golden_raw"]


def crc(b):
    return zlib.crc32(b) & 0xFFFFFFFF


def align(n, a=64):
    return (n + a - 1) // a * a


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--img", help="真实测试图（与 --no-face 二选一）")
    g.add_argument("--no-face", action="store_true", help="确定性无脸合成图")
    ap.add_argument("--golden-raw", default=None,
                    help="逐字节黄金输出目录（每个输出一个 <name>.bin，长度=nbytes）；缺省则不带黄金")
    ap.add_argument("--out", default=os.path.join("build", "y1_payload.bin"))
    ap.add_argument("--json", default=None, help="payload 清单（默认 <out>.json）")
    args = ap.parse_args()

    descs, dmd5, raw, sent_ok = NFR.load_desc()
    index = NFR.load_index()
    om = NFR.onnx_out_map()
    plan = NFR.build_output_plan(descs, index, om)
    lay = NFR.layout_bits("derived")
    mbs = NFR.mailbox_writes(index, NFR.BLOB_NPU, with_params=True, xdma_en=True, layout=lay)
    recs = [(w["wgt_addr"], w["data"]) for m in mbs for w in m["writes"]]

    hwc = NFR.YP.synth_noface() if args.no_face else NFR.YP.preprocess_image(args.img)
    q = NFR.to_int8_input(hwc)
    inp = q.tobytes()
    wgt = open(NFR.WGT_BLOB, "rb").read() + open(NFR.WGT_MULT, "rb").read()
    mb = b"".join(struct.pack("<II", a & 0xFFFFFFFF, d & 0xFFFFFFFF) for a, d in recs)

    if len(plan) > 27:
        raise SystemExit("FATAL: 输出 %d 路超过 header 容量（27）" % len(plan))
    max_out = max(p["addr"] + p["nbytes"] for p in plan)
    if max_out >= ARENA_HW_LIMIT - 0x80000000:
        raise SystemExit("FATAL: 输出高水位 0x%08X 撞进 payload 区（物理 0x%08X）"
                         % (max_out, 0x80000000 + max_out))

    gold = bytearray()
    out_tbl = []
    for p in plan:
        n = int(p["nbytes"])
        b = None
        if args.golden_raw:
            fp = os.path.join(args.golden_raw, p["name"] + ".bin")
            if not os.path.isfile(fp):
                raise SystemExit("FATAL: 缺黄金块 %s" % fp)
            b = open(fp, "rb").read()
            if len(b) != n:
                raise SystemExit("FATAL: 黄金块 %s 长度 %d != %d" % (fp, len(b), n))
            gold += b
        out_tbl.append({"name": p["name"], "npu": int(p["addr"]), "bytes": n,
                        "crc32": crc(b) if b is not None else 0,
                        "desc_idx": p["desc_idx"], "kind": p["kind"]})
    gold = bytes(gold)

    segs = [(SEG_DESC, raw), (SEG_WGT, wgt), (SEG_INPUT, inp),
            (SEG_MB, mb), (SEG_GOLDEN, gold)]
    body = bytearray()
    seg_tbl = []
    for sid, data in segs:
        off = HEADER + len(body)
        body += data
        pad = align(len(body)) - len(body)
        body += b"\x00" * pad
        seg_tbl.append((off, len(data), crc(data)))
    total = HEADER + len(body)
    if total > PAYLOAD_LIMIT:
        raise SystemExit("FATAL: payload %d B 超过 2 MiB 槽（%d）" % (total, PAYLOAD_LIMIT))

    hdr = bytearray(HEADER)
    hdr[0:4] = MAGIC
    struct.pack_into("<I", hdr, 4, VERSION)
    struct.pack_into("<I", hdr, 8, total)
    struct.pack_into("<I", hdr, 12, len(descs) - 1)
    struct.pack_into("<I", hdr, 16, len(plan))
    struct.pack_into("<I", hdr, 20, len(recs))
    struct.pack_into("<I", hdr, 24, NFR.INPUT_NPU)
    struct.pack_into("<I", hdr, 28, NFR.DESC_TABLE_ADDR)
    struct.pack_into("<I", hdr, 32, NFR.BLOB_NPU)
    struct.pack_into("<I", hdr, 36, len(wgt))
    struct.pack_into("<I", hdr, 40, len(inp))
    struct.pack_into("<I", hdr, 44, len(gold))
    for i, (off, ln, c) in enumerate(seg_tbl):
        struct.pack_into("<IIII", hdr, 64 + 16 * i, off, ln, c, 0)
    for i, e in enumerate(out_tbl):
        base = 160 + 32 * i
        nm = e["name"].encode("ascii")
        hdr[base:base + 16] = nm + b"\x00" * (16 - len(nm))
        struct.pack_into("<IIII", hdr, base + 16, e["npu"], e["bytes"], e["crc32"], 0)

    blob = bytes(hdr) + bytes(body)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "wb") as f:
        f.write(blob)

    meta = {
        "payload": os.path.abspath(args.out), "bytes": len(blob),
        "md5": __import__("hashlib").md5(blob).hexdigest(),
        "base": "0x%08X" % PAYLOAD_BASE, "end": "0x%08X" % (PAYLOAD_BASE + len(blob)),
        "desc_md5": dmd5, "desc_count": len(descs) - 1,
        "input_bytes": len(inp), "input_crc32": "%08x" % crc(inp),
        "wgt_bytes": len(wgt), "wgt_crc32": "%08x" % crc(wgt),
        "mb_records": len(recs), "mb_crc32": "%08x" % crc(mb),
        "golden_bytes": len(gold), "golden": bool(args.golden_raw),
        "img": args.img, "no_face": bool(args.no_face),
        "outputs": out_tbl,
        "segments": {SEG_NAMES[i]: {"off": seg_tbl[i][0], "len": seg_tbl[i][1],
                                   "crc32": "%08x" % seg_tbl[i][2]} for i in range(len(segs))},
    }
    jp = args.json or (args.out + ".json")
    with open(jp, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=1)
    print("PAYLOAD %s  %d B  md5=%s" % (args.out, len(blob), meta["md5"]))
    print("  base=0x%08X end=0x%08X  limit=0x%08X  max_out=0x%08X"
          % (PAYLOAD_BASE, PAYLOAD_BASE + len(blob), PAYLOAD_BASE + PAYLOAD_LIMIT, max_out))
    for i, nm in enumerate(SEG_NAMES):
        if i >= len(segs):
            break
        print("  %-12s off=%7d len=%7d crc32=%08x" % (nm, seg_tbl[i][0], seg_tbl[i][1], seg_tbl[i][2]))
    print("  records=%d outputs=%d golden=%s（%d B）"
          % (len(recs), len(plan), bool(args.golden_raw), len(gold)))
    print("  manifest=%s" % jp)


if __name__ == "__main__":
    main()
