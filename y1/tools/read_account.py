#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Y1-NPU B1-T0：DDR **输入读**逐单元账（nominal vs co-block 重读 vs B1 复用后）。

背景（spec `2026-10-20-y1-npu-b-input-reuse-design.md` §1、plan B1-T0）
--------------------------------------------------------------------
板端 4.66 s/帧、conv1x1 61% + dw 21%，成本与激活 inB 强相关（0.30 µs/B）⇒ 帧被**读放大**限住。
根因（读 RTL `y1/rtl/UnitExec.scala:1368-1369` 的趟序）：
    宽层 = `for co-block j:  for ci-block i:`   ⇒ **co-block 外、ci-block 内**
    每个 co-block 都从 DDR 重读**同一份**输入张量 ⇒ 输入读 = nominal × nCo，nCo = ceil(C_out/8)。
B1 的目标：ci-block 的输入 tile 只读一次、在片上 tileBuf 里跨 co-block 复用 ⇒ 输入读 = nominal。

本工具只做账，**不改 RTL、不改冻结工具、不碰板**；三个输入全部只读。

输入（权威，只读）
------------------
1. `y1/reports/npu_v2_mac_table.txt`（主源，几何列）——只取**第一张逐单元表**
   （表头 `idx name type flags ...` 到 `MAC_TOTAL=` 之间）。该表第一段恰 53 个 conv/dw 单元。
   ★ 文件后面还有第二张 `issued Top-12` 排行表，列序不同（无 `flags` 列、多 `passes/taps_eff/issued`）；
     行级正则若**不限段**地扫全文件会把它当成 12 个新单元重复计入（并把列错位读成几何）——
     这正是 B1-T0 之前快速模型的 65 行口径。本工具默认**排除**，另用 `NAIVE_*` 行把旧口径
     原样复现出来（= 15,021 KiB / 67.17 MiB / 4.579×），供对账。
2. `y1/gen/wgt_index.json`（交叉源）——67 个单元的 `own` 真几何与 `in_bytes`。
3. `y1/gen/desc.bin`（交叉源）——67 条载荷描述符 + 哨兵（2176 B / 68 项），按 `y1/tools/desc_table.py`
   文件头冻结的位打包**本地译码**（只读；不 import desc_table —— 它在模块级 import `ddr_traffic`，
   而 `ddr_traffic` 依赖 onnx，离线环境里拉不起来）。译码结果逐单元与 `wgt_index.table_geom` 对账。

口径（逐单元可复算）
--------------------
    nCi = ceil(C_in/8)          nCo = ceil(C_out/8)          passes = nCi*nCo
    nominal_in  = C_in*H*W          （1 B/元素；Q8 激活。stride 不改变读入张量大小）
    current_read = nominal_in * nCo （单位置 1：趟序 co-block 外 ⇒ 每个 co-block 重读全部输入）
    reuse_read   = nominal_in       （B1 目标：ci-block tile 驻留片上，跨 co-block 复用）
    amplification = Σcurrent_read / Σnominal_in
只统计 conv1x1 / conv3x3 / depthwise（desc TYPE 0x01/0x02/0x03）。maxpool/resize/add/sigmoid 的
输入读属旁路算子（冻结 `bypass_traffic.py` 口径），不并入本账。

用法（在 `y1/` 下）
-------------------
    python tools/read_account.py                  # 正控：当前趟序的账
    python tools/read_account.py --force-nco1     # 负控：强制 nCo=1（必须塌回 nominal）
    python tools/read_account.py --exclude-small-tail   # 敏感性：剔掉 6 个 conv3x3 小尾单元
    python tools/read_account.py --all            # 打印全部 53 行（默认只打 top-10）
    python tools/read_account.py --json           # 机器可读（供闸门/报告取数）

退出码：0 = 账算完且三条交叉 CHECK 全过；1 = CHECK 失败（输入互相矛盾）；3 = 环境/输入错误。
"""
import argparse
import json
import os
import re
import struct
import sys

# Git Bash / WSL 终端按 UTF-8 解码；Windows 默认 cp936 会把中文打成乱码。
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

# ---- 逐单元表（第一段）的行正则：idx name type flags C_in C_out GROUP H W ----
ROW_RE = re.compile(
    r"^\s*(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+")
CONV_TYPES = ("conv1x1", "conv3x3", "depthwise")
TYPE_CODE = {"conv3x3": 0x01, "conv1x1": 0x02, "depthwise": 0x03}


def ceil8(n):
    return (n + 7) // 8


def align32(n):
    return (n + 31) // 32 * 32


def die(msg, code=3):
    sys.stderr.write("FATAL: %s\n" % msg)
    sys.stderr.write("TOOL_RESULT: FAIL\n")
    sys.exit(code)


# ----------------------------------------------------------------- 主源：MAC 表
def parse_mac_table(path):
    """返回 (units, naive_units)。

    units       —— 第一张逐单元表的 conv/dw 行（53 个；默认口径）
    naive_units —— 整文件行扫的 conv/dw 行（65 个；复现 B1-T0 之前的快速模型口径，仅作对账）
    """
    if not os.path.isfile(path):
        die("缺文件 %s" % path)
    units, naive = [], []
    in_table, seen_header, stopped = False, False, False
    with open(path, encoding="utf-8") as f:
        for line in f:
            if not seen_header and line.startswith("idx") and "name" in line and "type" in line:
                seen_header = True
                in_table = True
                continue
            if line.startswith("MAC_TOTAL="):
                in_table = False
                stopped = True
                continue
            m = ROW_RE.match(line)
            if not m or m.group(3) not in CONV_TYPES:
                continue
            u = dict(idx=int(m.group(1)), name=m.group(2), type=m.group(3),
                     flags=m.group(4), cin=int(m.group(5)), cout=int(m.group(6)),
                     group=int(m.group(7)), h=int(m.group(8)), w=int(m.group(9)))
            naive.append(u)
            if in_table:
                units.append(u)
    if not seen_header or not stopped:
        die("MAC 表结构不认识（找不到表头或 MAC_TOTAL 终止行）：%s" % path)
    if len(units) != 53:
        die("第一张逐单元表应有 53 个 conv/dw 单元，实得 %d" % len(units))
    return units, naive


# ------------------------------------------------------- 交叉源：wgt_index.json
def load_wgt_index(path):
    if not os.path.isfile(path):
        die("缺文件 %s" % path)
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    units = d.get("units")
    if not isinstance(units, list) or len(units) != 67:
        die("wgt_index.json 的 units 应为 67 项")
    out = {}
    for i, u in enumerate(units):
        own = u["own"]
        out[u["name"]] = dict(idx=i, name=u["name"], type=u["type"], code=int(u["type_code"]),
                              cin=int(own["C_IN"]), cout=int(own["C_OUT"]),
                              h=int(own["IMG_H"]), w=int(own["IMG_W"]),
                              group=int(own["GROUP"]), in_bytes=int(u["in_bytes"]),
                              table_geom=u.get("table_geom"))
    return d, out


# ------------------------------------------------------ 交叉源：desc.bin（本地译码）
def decode_desc(path):
    """按 `desc_table.py` 文件头的冻结位打包译码（每项 8 个 32-bit 小端字）。"""
    if not os.path.isfile(path):
        die("缺文件 %s" % path)
    b = open(path, "rb").read()
    if len(b) % 32 != 0:
        die("desc.bin 长度不是 32 B 的整数倍：%d" % len(b))
    out = []
    for i in range(len(b) // 32):
        w = struct.unpack_from("<8I", b, i * 32)
        out.append(dict(TYPE=w[0] & 0xFF, FLAGS=(w[0] >> 8) & 0xFF,
                        IMG_W=w[1] & 0xFFFF, IMG_H=(w[1] >> 16) & 0xFFFF,
                        C_IN=w[2] & 0xFFFF, C_OUT=(w[2] >> 16) & 0xFFFF,
                        GROUP=w[3] & 0xFF, STRIDE=(w[3] >> 8) & 0xF,
                        IN_BYTES=w[6]))
    return out


# --------------------------------------------------------------------- 计算
def compute(units, force_nco1=False):
    rows = []
    for u in units:
        nci = ceil8(u["cin"])
        nco = 1 if force_nco1 else ceil8(u["cout"])
        nominal = u["cin"] * u["h"] * u["w"]
        rows.append(dict(u, nci=nci, nco=nco, passes=nci * nco, nominal=nominal,
                         current=nominal * nco, reuse=nominal))
    return rows


def totals(rows):
    n = sum(r["nominal"] for r in rows)
    c = sum(r["current"] for r in rows)
    return dict(units=len(rows), nominal=n, current=c, reuse=n,
                amp=(float(c) / n if n else 0.0))


MIB = 1024.0 * 1024.0
MB = 1e6


def print_rows(rows, limit):
    hdr = ("idx  name      type       C_in C_out    H    W  nCi nCo passes"
           "     nominal    current      reuse")
    print(hdr)
    print("-" * len(hdr))
    for r in rows[:limit]:
        print("%3d  %-9s %-9s %4d %5d %4d %4d %4d %3d %6d %11d %10d %10d"
              % (r["idx"], r["name"], r["type"], r["cin"], r["cout"], r["h"], r["w"],
                 r["nci"], r["nco"], r["passes"], r["nominal"], r["current"], r["reuse"]))
    if limit < len(rows):
        print("... (%d of %d rows; use --all for the full table)" % (limit, len(rows)))


def emit_totals(t, tag=""):
    print("TOTAL_UNITS%s=%d" % (tag, t["units"]))
    print("TOTAL_NOMINAL_BYTES%s=%d" % (tag, t["nominal"]))
    print("TOTAL_CURRENT_BYTES%s=%d" % (tag, t["current"]))
    print("TOTAL_REUSE_BYTES%s=%d" % (tag, t["reuse"]))
    print("TOTAL_SAVED_BYTES%s=%d" % (tag, t["current"] - t["reuse"]))
    print("AMPLIFICATION%s=%.6f" % (tag, t["amp"]))
    print("TOTAL_NOMINAL_MIB%s=%.6f" % (tag, t["nominal"] / MIB))
    print("TOTAL_CURRENT_MIB%s=%.6f" % (tag, t["current"] / MIB))
    print("TOTAL_REUSE_MIB%s=%.6f" % (tag, t["reuse"] / MIB))
    print("TOTAL_NOMINAL_MB%s=%.6f" % (tag, t["nominal"] / MB))
    print("TOTAL_CURRENT_MB%s=%.6f" % (tag, t["current"] / MB))
    print("TOTAL_REUSE_MB%s=%.6f" % (tag, t["reuse"] / MB))


def main(argv):
    ap = argparse.ArgumentParser(description="Y1-NPU B1-T0 DDR input read accounting")
    ap.add_argument("--table", default="reports/npu_v2_mac_table.txt")
    ap.add_argument("--wgt-index", default="gen/wgt_index.json")
    ap.add_argument("--desc", default="gen/desc.bin")
    ap.add_argument("--force-nco1", action="store_true",
                    help="negative control: force nCo=1 (all co-blocks share one read)")
    ap.add_argument("--exclude-small-tail", action="store_true",
                    help="sensitivity: drop the 6 1x1-tap 3x3 tail units")
    ap.add_argument("--all", action="store_true", help="print all rows (default top-10)")
    ap.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    a = ap.parse_args(argv)

    units, naive = parse_mac_table(a.table)
    wdoc, wunits = load_wgt_index(a.wgt_index)
    descs = decode_desc(a.desc)

    # ---- CHECK 1：MAC 表几何 == wgt_index 的 own 真几何，且 in_bytes 自洽 ----
    # in_bytes 的冻结口径 = 真输入张量字节：stride>1 时输入比输出大 stride^2 倍
    # （真表只有 Conv_0 s=2：640x640x3），C_in=1 折档平面另有 32 B 对齐补位。
    bad = []
    for u in units:
        w = wunits.get(u["name"])
        if w is None:
            bad.append((u["name"], "missing in wgt_index"))
            continue
        if (w["type"], w["cin"], w["cout"], w["h"], w["w"], w["group"]) != \
           (u["type"], u["cin"], u["cout"], u["h"], u["w"], u["group"]):
            bad.append((u["name"], "mac=%s wgt=%s" % (
                (u["type"], u["cin"], u["cout"], u["h"], u["w"], u["group"]),
                (w["type"], w["cin"], w["cout"], w["h"], w["w"], w["group"]))))
        else:
            stride = descs[w["idx"]]["STRIDE"] or 1
            want = align32(u["cin"] * u["h"] * u["w"] * stride * stride)
            if w["in_bytes"] != want:
                bad.append((u["name"], "in_bytes %d != align32(C_in*H*W*s^2) %d"
                            % (w["in_bytes"], want)))
    chk1 = "OK(53/53)" if not bad else "FAIL(%d)" % len(bad)

    # ---- CHECK 2：desc.bin 译码 == wgt_index.table_geom（67/67）----
    bad2 = []
    for i, u in enumerate(wdoc["units"]):
        d, g = descs[i], u["table_geom"]
        if (d["TYPE"], d["IMG_W"], d["IMG_H"], d["C_IN"], d["C_OUT"], d["GROUP"]) != \
           (int(u["type_code"]), g["IMG_W"], g["IMG_H"], g["C_IN"], g["C_OUT"], g["GROUP"]):
            bad2.append(u["name"])
    chk2 = "OK(67/67)" if not bad2 else "FAIL(%d: %s)" % (len(bad2), ",".join(bad2[:5]))

    # ---- CHECK 3：desc.bin 里每个 conv/dw 单元的 TYPE 码与名一致 ----
    bad3 = []
    for i, u in enumerate(wdoc["units"]):
        if u["type"] in CONV_TYPES and descs[i]["TYPE"] != TYPE_CODE[u["type"]]:
            bad3.append(u["name"])
    chk3 = "OK(53/53)" if not bad3 else "FAIL(%d)" % len(bad3)

    sel = units
    if a.exclude_small_tail:
        sel = [u for u in sel if not (u["type"] == "conv3x3" and u["cin"] == 1 and u["cout"] == 1)]

    rows = compute(sel, force_nco1=a.force_nco1)
    rows.sort(key=lambda r: (-r["current"], r["idx"]))
    t = totals(rows)

    # 旧口径（整文件行扫 65 行）——只用于证明快速模型的数从哪来，不参与任何判据
    nrows = compute(naive)
    nt = totals(nrows)

    mode = "force-nco1(nCo:=1)" if a.force_nco1 else "current(nCo:=ceil(C_out/8))"
    ok = chk1.startswith("OK") and chk2.startswith("OK") and chk3.startswith("OK")
    if a.json:
        # --json 只吐一份合法 JSON（结果在 "result" 字段），不混打印
        print(json.dumps(dict(result="PASS" if ok else "FAIL", mode=mode,
                              force_nco1=a.force_nco1,
                              exclude_small_tail=a.exclude_small_tail,
                              checks=dict(mac_vs_wgt=chk1, desc_vs_wgt=chk2, desc_type=chk3),
                              units=rows, totals=t, naive_totals=nt), indent=1))
        return 0 if ok else 1
    else:
        print("== Y1-NPU B1-T0 DDR 输入读账 ==")
        print("   table=%s  wgt=%s  desc=%s" % (a.table, a.wgt_index, a.desc))
        print("   mode=%s  units=%d%s" % (mode, len(rows),
                                          "  (excl. 6 small 3x3 tails)" if a.exclude_small_tail else ""))
        print("   CHECK mac_table_vs_wgt_index=%s" % chk1)
        print("   CHECK desc_bin_vs_wgt_index=%s" % chk2)
        print("   CHECK desc_bin_type_codes=%s" % chk3)
        print("")
        if a.all:
            print("== all %d units, sorted by current_read ==" % len(rows))
        else:
            print("== top-%d by current_read (co-block 重读) ==" % min(10, len(rows)))
        print_rows(rows, len(rows) if a.all else 10)
        print("")
        print("== totals ==")
        emit_totals(t)
        print("NOTE_AMPLIFICATION=current_read/nominal_in  (%.6f x)" % t["amp"])
        print("NOTE_UNITS=conv1x1/conv3x3/depthwise only; maxpool/resize/add/sigmoid excluded")
        print("NOTE_UNIT_BYTES=1 B per activation element (Q8); H*W = unit output grid")
        # 敏感性：把 nominal 换成 wgt_index 的**真输入张量字节**（含 stride^2 与 32 B 补位）
        alt_n = sum(wunits[r["name"]]["in_bytes"] for r in rows)
        alt_c = sum(wunits[r["name"]]["in_bytes"] * r["nco"] for r in rows)
        print("ALT_TRUE_IN_NOMINAL_BYTES=%d" % alt_n)
        print("ALT_TRUE_IN_CURRENT_BYTES=%d" % alt_c)
        print("ALT_TRUE_IN_NOMINAL_MIB=%.6f" % (alt_n / MIB))
        print("ALT_TRUE_IN_CURRENT_MIB=%.6f" % (alt_c / MIB))
        print("ALT_TRUE_IN_AMPLIFICATION=%.6f" % (float(alt_c) / alt_n if alt_n else 0.0))
        print("NOTE_ALT=True in_bytes counts Conv_0's 640x640x3 input (s=2 => 4x of H*W)")
        print("NOTE_ALT=plus 32 B plane padding on the two 20x20 C_in=1 3x3 tails")
        print("NOTE_NAIVE=whole-file row scan (65 rows) reproduces the pre-B1-T0 quick model:")
        print("NOTE_NAIVE=it also counts the 'issued Top-12' ranking block, whose columns are")
        print("NOTE_NAIVE=shifted (no flags column) => 12 units double counted, geometry garbage")
        print("NAIVE_RAW_SCAN_UNITS=%d" % nt["units"])
        print("NAIVE_RAW_SCAN_NOMINAL_BYTES=%d" % nt["nominal"])
        print("NAIVE_RAW_SCAN_NOMINAL_KIB=%.4f" % (nt["nominal"] / 1024.0))
        print("NAIVE_RAW_SCAN_CURRENT_BYTES=%d" % nt["current"])
        print("NAIVE_RAW_SCAN_CURRENT_MIB=%.4f" % (nt["current"] / MIB))
        print("NAIVE_RAW_SCAN_AMPLIFICATION=%.4f" % nt["amp"])

    if not ok:
        print("TOOL_RESULT: FAIL")
        return 1
    print("TOOL_RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
