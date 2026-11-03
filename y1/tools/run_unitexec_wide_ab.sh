#!/usr/bin/env bash
# run_unitexec_wide_ab.sh —— y1 C4a.5b 闸门：**宽层多趟通路（UnitExec 级）**的数值判据。
#
# 被测行为（`rtl/UnitExec.scala` 的 `WIDERUN` + `MultiPassUnit`/`PartialSumBuf` + §4.4/§4.5 参数）：
#   一个**宽层**（`C_in>8 || C_out>8`）经**权置信箱**把 `M`/`z_pad`/`z_y`/`bias_adj` 按 `LAYER_ID`
#   灌进片上参数表 ⇒ `UnitExec` 自己驱动 `ceil(C_in/8)×ceil(C_out/8)` 趟（跨 `ci` 趟在片上部分和里累加、
#   **只在末趟 requant 一次**）⇒ pad 行/列用 `z_pad` ⇒ 输出落 `DST`（DDR）。
#
# 用例（`tools/wide_exec_ref.py` 供料；`+DUMPFILE` 逐字节对黄金）：
#   A) **真层** `Conv_0`（`gen/wgt_index.json` + `gen/wgt_blob.bin`）：C_IN=3 C_OUT=16 3x3、
#      `z_x = z_pad = -128`（**非 0**）、`z_y = 41`、`M = 57384`、`bias_adj[16]`、`n_ci=1 n_co=2`。
#      ⇒ 宽（C_OUT>8）、**pad 码点非 0**（pad 这条路真有分辨度）、真乘子非单位元。
#   B) **合成宽层** 16→16（真 3x3 核）：`n_ci=2 n_co=2` ⇒ **打跨 ci 趟累加（读回+加+写回）**。
#
# 判据（每条都要过）：
#   0) **参考自检**（python；不成立 exit 3）：`wide_exec_ref.py --selftest`（拆趟==整层 + 两条负对照都有牙）。
#   1) **正对照（逐字节）**：DUT 的 `DST` 区 == `gold.hex`（`MISMATCH=0`）；邻居/其它区未被改；
#      `WR_BYTES == C_out*H*W`、`AR/AW/B` 与内存模型计数一致、`RD_PEAK == 0`（宽层无 DDR 读）。
#   2) **自报对账**：`WIDE_ON=1`、`WIDE_PASSES == n_ci*n_co`、`RTL_M/RTL_ZPAD/RTL_ZY/RTL_LAYER` == 灌进去的值。
#   3) **负对照 A（pad 用字节 0）**：`+ZPAD=0` ⇒ 输出**精确命中** `gold_pad0.hex`（0 差）**且** != 黄金。
#   4) **负对照 B（去 bias_adj）**：`BFILE` 全 0 ⇒ 输出**精确命中** `gold_nobias.hex`（0 差）**且** != 黄金。
#   5) **退化守卫**：黄金与 RTL 输出都 `distinct > 1`。
#
# 退出码：0 = 全绿；1 = 判据红（MISMATCH/退化/自报不符）；2 = 负对照没发火（判据无牙）；3 = 前置缺失。
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

tool="tools/wide_exec_ref.py"
tb="rtl_test/UnitExecWideTb.v"
memv="rtl_test/AxiMemModel.v"
nl="gen/UnitExec.v"
outdir="gen/c4a_wide"
MEMSZ=2621440

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
for f in "$tool" "$tb" "$memv" "$nl"; do
  [ -f "$f" ] || { echo "FATAL: 缺 $f"; echo "RESULT: FAIL"; exit 3; }
done
[ -n "$IVERILOG" ] && [ -n "$VVP" ] || { echo "FATAL: 找不到 iverilog/vvp"; echo "RESULT: FAIL"; exit 3; }

work="$(mktemp -d)"
cleanup() { if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => 中间件在 $work"; else rm -rf "$work"; fi }
trap cleanup EXIT
export PYTHONPATH="./.pydeps;../third_party/yunet/deps"
export PYTHONIOENCODING=utf-8

echo "== run_unitexec_wide_ab: 宽层多趟（UnitExec 级：信箱参数 + 多趟累加 + pad=z_pad）=="
echo "   nl=$nl  tb=$tb  py=$PY  iverilog=$IVERILOG  vvp=$VVP  tmp=$work"

# 逐字节比较（token 文件）-> 不符数（长度不等取较长者；缺一侧 = -1）
cnt() {
  "$PY" - "$1" "$2" <<'PYEOF'
import sys
def load(p):
    try: return [t.lower() for t in open(p, encoding="utf-8", errors="replace").read().split()]
    except OSError: return None
a, b = load(sys.argv[1]), load(sys.argv[2])
print(-1 if (a is None or b is None) else (max(len(a), len(b)) if len(a) != len(b) else sum(1 for i, j in zip(a, b) if i != j)))
PYEOF
}
distinct() {
  "$PY" - "$1" <<'PYEOF'
import sys
try: t = open(sys.argv[1], encoding="utf-8", errors="replace").read().split()
except OSError: print(-1); sys.exit(0)
print(len(set(x.lower() for x in t)) if t else -1)
PYEOF
}

echo "---- [0] tools/wide_exec_ref.py --selftest（拆趟==整层 + 两条负对照都有牙）----"
if ! "$PY" "$tool" --selftest > "$work/st.out" 2>&1; then
  echo "JUDGE-RED(3): 参考自检没过 ⇒ 用例/参考写错了"; tail -10 "$work/st.out"; echo "RESULT: FAIL"; exit 3
fi
grep -E '^(SELFTEST|RESULT:)' "$work/st.out" | grep -v '^RESULT:' | sed 's/^/    /'

echo "---- [1] 供料：真层 Conv_0（lid0，3→16）+ 合成宽层（16→16，打跨 ci 趟累加）----"
for spec in "--lid 0" "--synth 16 16"; do
  if ! "$PY" "$tool" $spec --H 4 --W 64 --outdir "$outdir" > "$work/ref.out" 2>&1; then
    echo "JUDGE-RED(1): 供料失败（$spec）"; tail -10 "$work/ref.out"; echo "RESULT: FAIL"; exit 1
  fi
  grep -E '^WIDE_REF' "$work/ref.out" | sed 's/^/    /'
done

echo "---- [2] iverilog 编译（UnitExecWideTb + AxiMemModel + gen/UnitExec.v）----"
if ! "$IVERILOG" -g2012 -o "$work/wide.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED(1): iverilog 编译失败"; sed -n '1,30p' "$work/iv.log"; echo "RESULT: FAIL"; exit 1
fi
echo "    编译 OK"

TOTAL_BAD=0; NEG_NOFIRE=0; JOBS=""

for d in $(ls -d "$outdir"/lid*_* "$outdir"/synth_* 2>/dev/null | sort); do
  [ -f "$d/job.txt" ] || continue
  eval "$(sed 's/^/X_/' "$d/job.txt" | tr '\n' ' ')"   # 直接把 KV 变成 shell 变量（前缀 X_）
  CIN="${X_CIN}"; COUT="${X_COUT}"; HH="${X_H}"; WW="${X_W}"; SRC="${X_SRC}"; DST="${X_DST}"
  INB="${X_IN_BYTES}"; QSH="${X_QSHIFT}"; LID="${X_LID}"; MV="${X_M}"; ZP="${X_ZPAD}"; ZY="${X_ZY}"
  NCOL="${X_NCOL}"; NCI="${X_NCI}"; NCO="${X_NCO}"; NPASS="${X_NPASS}"; NM="${X_NAME}"
  JOBS="$JOBS $NM"
  tag="$(basename "$d")"
  LEN=$(( COUT * HH * WW ))

  # ---- 内存镜像：素周期 251 的模式；`DST` 区预载与黄金不同 ⇒ "不写"必被抓住 ----
  "$PY" - "$d" "$work" "$MEMSZ" "$SRC" "$DST" "$LEN" <<'PYEOF'
import sys
d, work, memsz, src, dst, ln = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
g = [int(l.strip(), 16) for l in open(d + "/gold.hex") if l.strip()]
pre = [((i % 251) * 131 + 7) % 251 for i in range(memsz)]
dif = sum(1 for j in range(ln) if pre[dst + j] != g[j])
assert dif >= int(ln * 0.9), "dst 预载与黄金只差 %d/%d" % (dif, ln)
txt = "".join("%02x\n" % b for b in pre)
open(work + "/mem.hex", "w").write(txt)
open(work + "/pre.hex", "w").write(txt)
b = [int(l.strip(), 16) for l in open(d + "/b.hex") if l.strip()]
open(work + "/b_zero.hex", "w").write("".join("%08x\n" % 0 for _ in b))
print("MEMGEN %s dst_preload_vs_gold_diff=%d/%d" % (d.split('/')[-1], dif, ln))
PYEOF
  [ -s "$work/mem.hex" ] || { echo "JUDGE-RED(3): $tag mem.hex 缺"; exit 3; }

  # slice_dump <dump> <dst> <len> <out>  -> 把 dump 的 DST 区切成独立文件（供逐字节比较）
  slice_dump() {
    "$PY" - "$1" "$2" "$3" "$4" <<'PYEOF'
import sys
dump, dst, ln, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
d = []
for l in open(dump, encoding="utf-8", errors="replace"):
    s = l.strip()
    if not s: continue
    try: d.append(int(s, 16) & 0xFF)
    except ValueError: d.append(-1)
seg = d[dst:dst+ln]
open(out, "w").write("".join("%02x\n" % (v & 0xFF) for v in seg))
print(len(seg))
PYEOF
  }

  # run_job <b-tag> <zpad-arg> <bfile> <dump>
  run_job() {
    local tag2="$1" zparg="$2" bf="$3"
    ( cd "$work" && "$VVP" "$work/wide.vvp" \
        "+XFILE=$PWD_ABS/$d/x.hex" "+WFILE=$PWD_ABS/$d/w.hex" "+BFILE=$PWD_ABS/$bf" \
        "+MEMFILE=$work/mem.hex" "+DUMPFILE=$work/$tag2.dump" +dump \
        "+CIN=$CIN" "+COUT=$COUT" "+GROUP=1" "+H=$HH" "+W=$WW" "+TYPE=1" "+FLAGS=1" \
        "+SRC=$SRC" "+DST=$DST" "+INB=$INB" "+QSHIFT=$QSH" "+LID=$LID" \
        "+M=$MV" "+ZPAD=$zparg" "+ZY=$ZY" "+NCOL=$NCOL" "+NCI=$NCI" "+NCO=$NCO" ) \
        > "$work/$tag2.log" 2>&1
  }
  PWD_ABS="$(pwd)"

  # ---- 3) 正对照 ----
  run_job "pos_$tag" "$ZP" "$d/b.hex" || true
  grep -E '^(TB WIDE|DONE_SEEN|RESULT)' "$work/pos_$tag.log" | sed "s/^/    [$tag] /"
  if ! grep -q '^RESULT: PASS' "$work/pos_$tag.log"; then
    echo "JUDGE-RED(1): 正对照装置未 PASS（$tag）"; tail -8 "$work/pos_$tag.log"; TOTAL_BAD=$((TOTAL_BAD+1)); continue
  fi
  # 自报对账
  REP="$(grep -m1 '^TB WIDE RTL:' "$work/pos_$tag.log")"
  case "$REP" in
    *"WIDE_ON=1 WIDE_PASSES=$NPASS"*"RTL_M=$MV RTL_ZPAD=$ZP RTL_ZY=$ZY RTL_LAYER=$LID"*) : ;;
    *) echo "JUDGE-RED(1): 自报不符（$tag）"; echo "  got=$REP"; TOTAL_BAD=$((TOTAL_BAD+1));;
  esac
  # 数值：DST 区 vs 黄金
  "$PY" - "$work/pos_$tag.dump" "$d/gold.hex" "$DST" "$LEN" "$work/pre" > "$work/pos_$tag.judge" <<'PYEOF'
import sys
dump, gold, dst, ln, pre = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
def load(p):
    out = []
    for l in open(p, encoding="utf-8", errors="replace"):
        s = l.strip()
        if not s: continue
        try: out.append(int(s, 16))
        except ValueError: out.append(-1)
    return out
d = load(dump); g = load(gold); p = load(pre + ".hex")
k = min(ln, len(g), max(0, len(d) - dst))
mis = sum(1 for i in range(k) if d[dst+i] != g[i]) + max(0, ln - k)
nb32 = sum(1 for i in range(32) if d[dst-32+i] != p[dst-32+i]) if dst >= 32 else 0
print("MISMATCH=%d" % mis)
print("DST_NEIGHBOR32_BAD=%d" % nb32)
print("XBYTES=%d" % sum(1 for v in d[dst:dst+k] if v < 0))
PYEOF
  sed 's/^/    /' "$work/pos_$tag.judge"
  MPOS="$(sed -n 's/^MISMATCH=//p' "$work/pos_$tag.judge")"
  NB="$(sed -n 's/^DST_NEIGHBOR32_BAD=//p' "$work/pos_$tag.judge")"
  slice_dump "$work/pos_$tag.dump" "$DST" "$LEN" "$work/pos_$tag.dst" > /dev/null
  GD="$(distinct "$d/gold.hex")"; YD="$(distinct "$work/pos_$tag.dst")"
  [ "$MPOS" = "0" ] || { echo "JUDGE-RED(1): 正对照 != 黄金（MISMATCH=$MPOS，$tag）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$NB" = "0" ] || { echo "JUDGE-RED(1): dst 邻居被改（$NB，$tag）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$GD" -gt 1 ] 2>/dev/null || { echo "JUDGE-RED(1): 黄金退化 distinct=$GD（$tag）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$YD" -gt 1 ] 2>/dev/null || { echo "JUDGE-RED(1): RTL 输出退化 distinct=$YD（$tag）"; TOTAL_BAD=$((TOTAL_BAD+1)); }

  # ---- 负对照 A：pad 用字节 0 ⇒ 精确命中 gold_pad0 且 != 黄金 ----
  run_job "pad0_$tag" 0 "$d/b.hex" || true
  slice_dump "$work/pad0_$tag.dump" "$DST" "$LEN" "$work/pad0_$tag.dst" > /dev/null
  AH="$(cnt "$d/gold_pad0.hex" "$work/pad0_$tag.dst")"
  AG="$(cnt "$d/gold.hex" "$work/pad0_$tag.dst")"
  [ "$AH" = "0" ] || { echo "JUDGE-RED(1): 负对照 A 未精确命中（$AH，$tag）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$AG" -gt 0 ] 2>/dev/null || { echo "NEGCTL-FAIL: 负对照 A（pad=0）没改变输出（$tag）"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }

  # ---- 负对照 B：bias_adj 全 0 ⇒ 精确命中 gold_nobias 且 != 黄金 ----
  run_job "nb_$tag" "$ZP" "$work/b_zero.hex" || true
  slice_dump "$work/nb_$tag.dump" "$DST" "$LEN" "$work/nb_$tag.dst" > /dev/null
  BH="$(cnt "$d/gold_nobias.hex" "$work/nb_$tag.dst")"
  BG="$(cnt "$d/gold.hex" "$work/nb_$tag.dst")"
  [ "$BH" = "0" ] || { echo "JUDGE-RED(1): 负对照 B 未精确命中（$BH，$tag）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$BG" -gt 0 ] 2>/dev/null || { echo "NEGCTL-FAIL: 负对照 B（去 bias_adj）没改变输出（$tag）"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }

  echo "JOB $NM n_ci=$NCI n_co=$NCO passes=$NPASS M=$MV ZPAD=$ZP | POS_MISMATCH=$MPOS distinct(gold=$GD,rtl=$YD) | PAD0 hit=$AH !=gold=$AG | NOBIAS hit=$BH !=gold=$BG"
done

echo "=========================================================================="
echo "作业集合：$JOBS"
echo "正对照   = OK（DUT 的 DST 区逐字节 == 黄金；邻居未动；WR_BYTES == C_out*H*W；宽层 RD_PEAK=0）"
echo "自报/信箱= OK（WIDE_ON/PASSES/RTL_M/RTL_ZPAD/RTL_ZY/RTL_LAYER == 经信箱按 LAYER_ID 灌进去的值）"
echo "负对照 A = OK（pad 用字节 0 ⇒ 精确命中 gold_pad0、且 != 黄金）"
echo "负对照 B = OK（bias_adj 全 0 ⇒ 精确命中 gold_nobias、且 != 黄金）"
echo "退化守卫 = OK（黄金 distinct>1）"
if [ "$NEG_NOFIRE" -ne 0 ]; then echo "NEGCTL-FAIL: $NEG_NOFIRE 条负对照没发火"; echo "RESULT: FAIL"; exit 2; fi
if [ "$TOTAL_BAD" -ne 0 ]; then echo "JUDGE-RED: $TOTAL_BAD 条判据未过"; echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
exit 0
