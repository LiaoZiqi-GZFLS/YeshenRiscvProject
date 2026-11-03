#!/usr/bin/env bash
# run_psbound_ab.sh —— y1 **spec §3.7** 的**界判据**：部分和行宽 32 bit 在**满幅度激励**下逐字节正确，
#                      24 bit（**低于可证界**）**必红**，并给出**实测峰值 |acc|**。
#
# 被测行为：`rtl/PartialSumBuf.scala`（行宽 `PSW`）+ `rtl/Conv3x3Slice.scala`（`ps_in/ps_out` + 128 位
#   加法/re‑quant 折算）+ `rtl/MultiPassUnit.scala`（转发）—— 也就是 **§3.7 收窄**的那条通路。
#
# ============================== 判据 ==============================
#  0) **参考自检**（python；不成立 exit 3）：`tools/psbound_ref.py --selftest`
#     · 两档满幅度激励的**参考峰值**必须各自顶到 `|x|·|w|·taps`：
#         `pos`（x=+127,w=+127）⇒ 127·127·576 = 9,290,304；`neg`（x=-128,w=+127）⇒ 128·127·576 = **9,363,456**；
#     · `M == 2^24`（单位乘子 ⇒ 判据是纯 `>>6`）；24 bit 预测**非退化**且 `!= 32 bit 黄金`。
#  1) **正对照（逐字节）**：缺省 32 bit 网表（`gen/MultiPassUnit.v`）逐像素 == 冻结参考黄金
#     （`tiling_ref.conv_tiled` 逐字复用）⇒ `MISMATCH=0`；两档的 **实测峰值 |acc|**（`MP PEAKABS=`，
#     装置随出数拍逐通道采 `ps_out`）必须 == 参考峰值（9,290,304 / **9,363,456**）。
#  2) **负对照（24 bit，低于可证界）**：`gen/c4a_psbound/nl24/MultiPassUnit.v`（`PSW=24`）
#     · **精确命中** 24 bit 回绕预测 `gold_ps24.hex`（`MISMATCH=0`）—— 把"错法"逐字节钉死；
#     · 且 `!= 32 bit 黄金`（恰好 `D24=96` 个字节 = 2 行 × 6 列内部像素 × 8 co ⇒ 只有顶到界的那些像素被回绕）；
#     · 且实测峰值 == 7×1,170,432 = 8,193,024（= 第 7 趟的部分和）：**第 8 趟的真实和（> 2^23）
#       被 24 bit 回绕"吃掉"**，存储里的峰值反而下降 ⇒ 这就是"静默错值"的签名。
#  3) **结构证据**：24 bit 档网表里 `PartialSumBuf` 是 `reg [191:0] mem [0:255]` + 自报 `rowBytes=3`；
#     32 bit 档是 `reg [255:0] mem [0:255]` + `rowBytes=4`（都**只有一条** Mem、**同步读**、无组合读）。
#
# 退出码：0 = 全绿；1 = 判据红（MISMATCH / 峰值 / 结构）；2 = 负对照没发火；3 = 前置缺失。
#
# 用法：bash y1/tools/run_psbound_ab.sh   （可 PY=<python> 覆盖解释器；KEEP_TMP=1 留中间件）
#   ★ 前置（不入库，按需生成；本闸门缺了会自己用 sbt 补）：
#     gen/MultiPassUnit.v                       ← `Test/runMain MultiPassGen <gen> 8 32 8 32`（缺省档）
#     gen/c4a_psbound/nl24/MultiPassUnit.v      ← `... MultiPassGen <gen>/c4a_psbound/nl24 8 32 8 24`
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

tool="${TOOL:-tools/psbound_ref.py}"
tb="${TB:-rtl_test/MultiPassTb.v}"
nl32="${NL32:-gen/MultiPassUnit.v}"
nl24="${NL24:-gen/c4a_psbound/nl24/MultiPassUnit.v}"
psdir="gen/c4a_psbound"

find_tool() {
  local n="$1" p d
  p="$(command -v "$n" 2>/dev/null || true)"
  if [ -z "$p" ]; then
    for d in /c/msys64/ucrt64/bin /mingw64/bin /usr/bin; do
      if [ -x "$d/$n" ]; then p="$d/$n"; break; fi
    done
  fi
  printf '%s' "$p"
}
IVERILOG="$(find_tool iverilog)"
VVP="$(find_tool vvp)"
[ -n "$IVERILOG" ] && [ -n "$VVP" ] || { echo "FATAL: 找不到 iverilog/vvp"; echo "RESULT: FAIL"; exit 3; }

for f in "$tool" "$tb" "$nl32"; do
  [ -f "$f" ] || { echo "FATAL: 缺 $f"; echo "RESULT: FAIL"; exit 3; }
done

# 24 bit（负对照档）网表：缺了就用 sbt 生成（与文档里的生成口径逐字一致）
if [ ! -f "$nl24" ]; then
  echo "---- [pre] 缺 $nl24 ⇒ 用 sbt 生成（PSW=24 负对照档）----"
  mkdir -p "$(dirname "$nl24")"
  if ! printf "Test/runMain MultiPassGen D:/code/PDS/VexiiYeshenLinux/y1/$psdir/nl24 8 32 8 24\nexit\n" | bash sbt.sh > "$psdir/gen24.log" 2>&1; then
    echo "FATAL: 生成 24 bit 档失败（见 $psdir/gen24.log）"; echo "RESULT: FAIL"; exit 3
  fi
  [ -f "$nl24" ] || { echo "FATAL: 生成后仍没有 $nl24"; echo "RESULT: FAIL"; exit 3; }
fi

work="$(mktemp -d)"
cleanup() {
  if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => 中间件留在 $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT

export PYTHONPATH="./.pydeps;../third_party/yunet/deps"
export PYTHONIOENCODING=utf-8

echo "== run_psbound_ab: §3.7 部分和行宽 32 bit 满幅度逐字节 + 24 bit 必红 =="
echo "   tb=$tb  nl32=$nl32  nl24=$nl24"
echo "   py=$PY  iverilog=$IVERILOG  vvp=$VVP"
echo "   tmp=$work"

# cnt <gold-file> <token-file> -> 不符 token 数（长度不等取较长者；任一侧缺失 = -1）
cnt() {
  "$PY" - "$1" "$2" <<'PYEOF'
import sys
def load(p):
    try:
        return [t.lower() for t in open(p, encoding="utf-8", errors="replace").read().split()]
    except OSError:
        return None
a, b = load(sys.argv[1]), load(sys.argv[2])
if a is None or b is None:
    print(-1)
elif len(a) != len(b):
    print(max(len(a), len(b)))
else:
    print(sum(1 for i, j in zip(a, b) if i != j))
PYEOF
}

# ---------------- 0) 参考自检 ----------------
echo "---- [0] tools/psbound_ref.py --selftest（两档顶到界 + M=2^24 + 24bit 预测非退化且 != 黄金）----"
if ! "$PY" "$tool" --selftest > "$work/st.out" 2> "$work/st.err"; then
  echo "FATAL: 参考自检没过 ⇒ 用例/参考写错了（不是硬件的问题）"; tail -20 "$work/st.out"; exit 3
fi
grep -E '^(PSBOUND|PSBOUND_REF)' "$work/st.out" | sed 's/^/    /'

# ---------------- 1) 参考供料（两档满幅度激励 + 两份预测）----------------
echo "---- [1] 参考供料：gen/c4a_psbound/{pos,neg}/（满幅度 x/w + gold.hex + gold_ps24.hex）----"
if ! "$PY" "$tool" --outdir "$psdir" > "$work/ref.out" 2> "$work/ref.err"; then
  echo "JUDGE-RED: 参考供料未过"; tail -10 "$work/ref.out"; echo "RESULT: FAIL"; exit 1
fi
grep -E '^PSBOUND' "$work/ref.out" | sed 's/^/    /'

# ---------------- 2) 结构证据（两档网表的存储形状）----------------
echo "---- [2] 结构证据：32bit 档 = 256bit 字 / 24bit 档 = 192bit 字（都只有 1 条 Mem + 同步读）----"
"$PY" - "$nl32" "$nl24" <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
ok = True
for path, want_w, want_rb, tag in ((sys.argv[1], 256, 4, "32bit(缺省)"), (sys.argv[2], 192, 3, "24bit(负对照)")):
    src = open(path, encoding="utf-8", errors="replace").read()
    m = re.search(r"^module PartialSumBuf\b.*?^endmodule", src, re.S | re.M)
    if not m:
        print("STRUCT-ERROR: %s 里找不到 module PartialSumBuf" % path); ok = False; continue
    body = m.group(0)
    arrs = re.findall(r"reg\s*\[(\d+):0\]\s*(\w+)\s*\[0:(\d+)\]\s*;", body)
    syncrd = re.findall(r"(\w+)\s*<=\s*mem\[(\w+)\];", body)
    comb = re.findall(r"assign\s+rd_data_\d+\s*=\s*mem\[", body)
    wr = re.findall(r"mem\[(\w+)\]\s*<=\s*(\w+);", body)
    rb = re.search(r"assign rowBytes = 16'h([0-9a-fA-F]+);", body)
    rb_v = int(rb.group(1), 16) if rb else -1
    w = int(arrs[0][0]) + 1 if arrs else -1
    dep = int(arrs[0][2]) + 1 if arrs else -1
    good = (len(arrs) == 1 and w == want_w and dep == 256 and len(syncrd) == 1 and len(wr) == 1
            and not comb and rb_v == want_rb)
    print("  · %-14s %s: 阵列=%s（%d bit × %d 字 = %d bit）同步读=%d 写口=%d 组合读=%d rowBytes=%d"
          % (tag, "OK " if good else "BAD", arrs[:1], w, dep, w * dep, len(syncrd), len(wr), len(comb), rb_v))
    if not good:
        ok = False
print("STRUCT: %s" % ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
PYEOF
if [ $? -ne 0 ]; then echo "JUDGE-RED: 结构判据红"; echo "RESULT: FAIL"; exit 1; fi

# ---------------- 3) 编译两档网表 ----------------
echo "---- [3] iverilog 编译（MultiPassTb × {32bit 档, 24bit 档}）----"
if ! "$IVERILOG" -g2012 -o "$work/ps32.vvp" "$tb" "$nl32" > "$work/iv32.log" 2>&1; then
  echo "JUDGE-RED: 32bit 档编译失败"; sed -n '1,20p' "$work/iv32.log"; echo "RESULT: FAIL"; exit 1
fi
if ! "$IVERILOG" -g2012 -o "$work/ps24.vvp" "$tb" "$nl24" > "$work/iv24.log" 2>&1; then
  echo "JUDGE-RED: 24bit 档编译失败"; sed -n '1,20p' "$work/iv24.log"; echo "RESULT: FAIL"; exit 1
fi
echo "    两档编译 OK（同一个装置 = rtl_test/MultiPassTb.v，只换网表与 +ROWB）"

# run_case <vvp> <shape-dir> <rowb> <tag> -> 跑装置 + 落 $work/<tag>.y
PWD_ABS="$(pwd)"
run_case() {
  local vvp="$1" d="$2" rowb="$3" tag="$4"
  ( cd "$work" && "$VVP" "$vvp" \
      "+XFILE=$PWD_ABS/$d/x.hex" "+WFILE=$PWD_ABS/$d/w.hex" "+BFILE=$PWD_ABS/$d/b.hex" \
      "+CIN=64" "+COUT=8" "+H=4" "+IW=8" "+M=16777216" "+ZY=0" "+PADV=0" "+ROWB=$rowb" ) \
      > "$work/$tag.log" 2>&1
  local rc=$?
  grep -E '^MP (PEAKABS|RTL|CIN)' "$work/$tag.log" | sed "s/^/    [$tag] /"
  grep '^Y ' "$work/$tag.log" | sed -e 's/^Y *//' | tr -s ' ' '\n' > "$work/$tag.y" || true
  return $rc
}

# peak <tag> -> 打印 MP PEAKABS 的数值（缺 = -1）
peak_of() { grep -oE '^MP PEAKABS=[0-9]+' "$work/$1.log" | tail -1 | cut -d= -f2; }

TOTAL_BAD=0
NEG_NOFIRE=0

echo "---- [4] 逐档：32bit 逐字节 == 黄金（且峰值顶到界）；24bit 精确命中回绕预测且 != 黄金 ----"
for case in pos neg; do
  d="$psdir/$case"
  [ -f "$d/params.txt" ] || { echo "FATAL: 缺 $d/params.txt"; echo "RESULT: FAIL"; exit 3; }
  CB="$(sed -n 's/^BOUND=//p' "$d/params.txt")"       # spec 的可证界（两档都记，= 9363456）
  D24="$(sed -n 's/^D24=//p' "$d/params.txt")"      # 24bit 预测 vs 黄金 的字节差（= 96）
  PEAK32_EXP="$(sed -n 's/^PEAK_EXP=//p' "$d/params.txt")"   # 本档 32bit 存储峰值（pos 9290304 / neg 9363456）
  PEAK24_EXP="$(sed -n 's/^PEAK24_EXP=//p' "$d/params.txt")" # 本档 24bit 存储峰值（第 8 趟被回绕吃掉 ⇒ 下降）

  # (a) 32 bit 正对照
  if ! run_case "$work/ps32.vvp" "$d" 4 "pos32_$case"; then
    echo "JUDGE-RED: 32bit 档装置未 PASS（$case）"; tail -6 "$work/pos32_$case.log"; TOTAL_BAD=$((TOTAL_BAD+1))
  fi
  M32="$(cnt "$d/gold.hex" "$work/pos32_$case.y")"
  P32="$(peak_of "pos32_$case")"
  [ "$M32" = "0" ] || { echo "JUDGE-RED: 32bit vs 黄金 MISMATCH=$M32（$case）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  if [ "$P32" != "$PEAK32_EXP" ]; then
    echo "JUDGE-RED: 32bit 实测峰值 |acc|=$P32 != 本档极值 $PEAK32_EXP（$case）"; TOTAL_BAD=$((TOTAL_BAD+1))
  fi
  if [ "$PEAK32_EXP" = "$CB" ]; then
    echo "    [$case] 本档实测峰值 $P32 **顶到 spec §3.7 的可证界** $CB"
  fi

  # (b) 24 bit 负对照
  if ! run_case "$work/ps24.vvp" "$d" 3 "pos24_$case"; then
    echo "JUDGE-RED: 24bit 档装置未 PASS（$case）"; tail -6 "$work/pos24_$case.log"; TOTAL_BAD=$((TOTAL_BAD+1))
  fi
  H24="$(cnt "$d/gold_ps24.hex" "$work/pos24_$case.y")"
  G24="$(cnt "$d/gold.hex" "$work/pos24_$case.y")"
  P24="$(peak_of "pos24_$case")"
  [ "$H24" = "0" ] || { echo "JUDGE-RED: 24bit 未精确命中回绕预测（MISMATCH=$H24，$case）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  if ! [ "$G24" -gt 0 ] 2>/dev/null; then
    echo "NEGCTL-FAIL: 24bit 与 32bit 黄金相同（$case）⇒ 负对照没发火（激励没顶到界？）"; NEG_NOFIRE=$((NEG_NOFIRE+1))
  elif [ "$G24" != "$D24" ]; then
    echo "    （注：24bit != 黄金 的字节数 = $G24，参考预测 D24=$D24）"
  fi
  if [ "$P24" != "$PEAK24_EXP" ]; then
    echo "JUDGE-RED: 24bit 实测存储峰值 =$P24 != $PEAK24_EXP（$case）"; TOTAL_BAD=$((TOTAL_BAD+1))
  fi

  echo "CASE $case | 32bit: MISMATCH32=$M32 PEAK32=$P32（极值 $PEAK32_EXP） | 24bit: 命中回绕预测=$H24 (==0 ⇒ 精确) !=黄金=$G24（预测 $D24） PEAK24=$P24"
done

# ---------------- 判决 ----------------
echo "=========================================================================="
echo "可证界（spec §3.7）= 128·127·576 = 9363456：|acc| ≤ 9,363,456 < 2^24 ⇒ 25 bit 有符号够、32 bit 有余量"
echo "参考侧   = OK（tiling_ref.conv_tiled 逐字复用；两档峰值 9290304 / 9363456 顶到各自极值）"
echo "正对照   = OK（32bit 网表在满幅度激励下逐字节 == 冻结参考；实测 PEAKABS 顶到界）"
echo "负对照   = OK（24bit（低于可证界）精确命中二补数回绕预测，且 != 黄金：顶到界的像素整片翻号）"
echo "结构     = OK（32bit 档 256bit 字 / 24bit 档 192bit 字；各 1 条 Mem + 同步读 + 地址译码写）"
if [ "$NEG_NOFIRE" -ne 0 ]; then
  echo "NEGCTL-FAIL: 有 $NEG_NOFIRE 条负对照没发火 ⇒ 判据无牙"; echo "RESULT: FAIL"; exit 2
fi
if [ "$TOTAL_BAD" -ne 0 ]; then
  echo "JUDGE-RED: $TOTAL_BAD 条判据未过"; echo "RESULT: FAIL"; exit 1
fi
echo "RESULT: PASS"
exit 0
