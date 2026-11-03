#!/usr/bin/env bash
# run_roww_ab.sh —— y1 T-S1 闸门：**一张网表（W_MAX=640）按运行期行宽 `rowW` 重放真表 6 个输入行宽**。
#
# 上游出处：spec `docs/superpowers/specs/2026-10-13-y1-runtime-width-and-tiling-design.md`
#   §3.1（把 `inWOk` 从**编译期等式**改成**运行期界限**：`rowW := IMG_W·s`，`go` 拍闩存，此后计数/寻址
#   全走运行值、分配仍按 `W_MAX`）+ §5 **T1**（一张网表重放 `desc.bin` 的 6 个行宽全部逐字节对黄金；
#   负对照把 `rowW` 钉死成 640 ⇒ 非 640 的层必红）+ §7 S1（`W_MAX=640`，无 tile 循环）。
#
# 为什么需要它：真表 `desc.bin` 的 conv 类输入行宽 `= IMG_W·STRIDE` 有 **6 个**（`c4b_frame.md` §9.5）：
#   `{640,320,160,80,40,20}`。改动前 `inWOk` 是**编译期等式** `WIDTH ∈ [IMG_W·s-s+1, IMG_W·s]`
#   ⇒ 一张网表只能服务**一个**行宽（`s=1` 时退化成 `IMG_W == WIDTH`）。T-S1 把它改成运行期界限后，
#   **同一张网表**必须能跑完这 6 个行宽且**逐字节正确** —— 这就是本闸门证死的东西。
#
# ============================== 判据 ==============================
#  0) **参考自检**：`tools/stride_ref.py --selftest`（两套独立实现互证；`s=1` == 冻结 C4a.5b caliber）。
#  1) **供料（6 个真行宽）**：`stride_ref.py --emit`（**冻结参考，不写第三条**；与 D1/D1b 同一份工具）
#     ——真 `Conv_0` 权重/参数（`--lid 0`），`s=1`，输入行宽 `W ∈ {640,320,160,80,40,20}`，
#     输入真行数 `H = 2560/W`（⇒ 每作业输出 `COUT·H·W = 16·2560` 字节、`NCOL = 5120` 列流）。
#     ★ 这就是「(等价行宽) 作业」：真行宽取自真表，几何按该网表的上限 `PIXW = WIDTH·IMG_H_MAX = 2560` 取满。
#  2) **正对照（逐字节，一张网表）**：`gen/UnitExec_w640.v`（W_MAX=640）逐作业跑 `UnitExecWideTb`：
#     · `DST` 区逐字节 == 黄金（`MISMATCH=0`）；邻居未动；黄金非退化（`distinct>1`）；
#     · 装置自报 `WIDE_ON=1`、网表按 `W_MAX` 分配（`RTL_MAXPIX=2560`）；
#     · **运行期行宽自报** `RTL_ROW_W == W`（6 个作业 ⇒ **6 个不同的值** ⇒ 闩存真在跑）。
#  3) **负对照（有牙，必须发火）**：**外科式网表突变**（一刀，只动 `UnitExec` 里 `go` 拍的那一条闩存）
#       `rowW <= inWMax[19:0];`  ->  `rowW <= 20'h00280;`   （= 把 `rowW` **钉死成 640**，忽略 latch）
#     ——即「不当运行期行宽、只当那一个常量」：
#       · 打在 `W=640` 作业上 ⇒ `MISMATCH == 0` 且装置仍 PASS（**这一刀是外科式的**：640 层本来就该 640）；
#       · 打在其余 5 个**非 640** 作业上 ⇒ 输出必变（`MISMATCH > 0` 或装置不 PASS）**必须全发火**。
#       哪一发**没**发火 ⇒ 本闸门退出 2（判据无牙 ⇒ 不可信）。
#
# 退出码：0 = 全绿；1 = 正对照红（不等 / 自报不符 / 退化）；2 = 负对照没发火（判据无牙）；
#         3 = 前置缺失（缺 python / 缺 iverilog / 缺网表或参考）。
#
# 用法：bash y1/tools/run_roww_ab.sh（可 PY= / NL= / OUTDIR= 覆盖；KEEP_TMP=1 留中间件）
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

tool="tools/stride_ref.py"                  # ★ 冻结参考（D1/D1b 同一份工具）——**不写第三条参考**
tb="rtl_test/UnitExecWideTb.v"
memv="rtl_test/AxiMemModel.v"
nl="${NL:-gen/UnitExec_w640.v}"             # ★★ W_MAX = 640 的网表（一张网表跑 6 个行宽）
outdir="${OUTDIR:-gen/c4b_roww}"
MEMSZ=2621440                               # 必须与 TB 里 AxiMemModel 的 MEMSZ 一致
SRC=$((0x20000)); DST=$((0x200000))         # 与既有宽层闸门同一档
WMAX=640                                    # 本网表的分配口径（= UnitExecGen 的 WIDTH）
WIDTHS="640 320 160 80 40 20"               # ★ 真表 6 个输入行宽（desc.bin 的 IMG_W·STRIDE）
PIXW=2560                                   # = WIDTH·IMG_H_MAX = 640·4（每作业输出像素上限）

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

# 结构前提：网表必须真的带 T-S1 的运行期行宽（闩存 + 观察口），否则一切对账无意义。
grep -q 'assign row_w = rowW;' "$nl" || { echo "FATAL: $nl 缺 T-S1 观察口 row_w（未按 T-S1 RTL 重生成）"; echo "RESULT: FAIL"; exit 3; }
LATCH='rowW <= inWMax[19:0];'
LATCH_N="$(grep -cF "$LATCH" "$nl")"
[ "$LATCH_N" = "1" ] || { echo "FATAL: $nl 里 T-S1 闩存 '$LATCH' 命中 $LATCH_N 处（期望 1）⇒ 负对照靶点不唯一"; echo "RESULT: FAIL"; exit 3; }

work="$(mktemp -d)"
cleanup() { if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => 中间件在 $work"; else rm -rf "$work"; fi; }
trap cleanup EXIT
export PYTHONPATH="./.pydeps;../third_party/yunet/deps"
export PYTHONIOENCODING=utf-8
PWD_ABS="$(pwd)"

echo "== run_roww_ab: 一张网表（W_MAX=$WMAX）按运行期 rowW 重放真表 6 个输入行宽 =="
echo "   nl=$nl  tb=$tb  py=$PY  iverilog=$IVERILOG  tmp=$work"
echo "   行宽 = $WIDTHS （真表 desc.bin 的 conv 类输入行宽 IMG_W·STRIDE）"

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

# ---------------- 0) 参考自检 ----------------
echo "---- [0] tools/stride_ref.py --selftest（两套实现互证 + s=1 == 冻结 caliber）----"
if ! "$PY" "$tool" --selftest > "$work/st.out" 2>&1; then
  echo "FATAL: 参考自检没过 ⇒ 用例/参考写错了（不是硬件的问题）"; tail -12 "$work/st.out"; echo "RESULT: FAIL"; exit 3
fi
grep -c '^  PASS' "$work/st.out" | sed 's/^/    PASS 断言数=/'

# ---------------- 1) 供料：6 个真行宽（冻结参考 --emit） ----------------
echo "---- [1] 供料：stride_ref --emit —— 真 Conv_0（--lid 0）s=1，W∈{$WIDTHS}，H=2560/W ----"
emit() {
  local d="$1"; shift
  if ! "$PY" "$tool" --emit --outdir "$d" "$@" > "$work/emit.out" 2>&1; then
    echo "JUDGE-RED(3): 供料失败（$*）"; tail -8 "$work/emit.out"; exit 3
  fi
  grep -E '^STRIDE_REF ' "$work/emit.out" | sed 's/^/    /'
}
mkdir -p "$outdir"
JOBS=""
for w in $WIDTHS; do
  h=$(( PIXW / w ))
  emit "$outdir/w$w" --lid 0 --stride 1 --h "$h" --w "$w"
  JOBS="$JOBS w$w"
done
for w in $WIDTHS; do
  for f in xcol.hex w.hex b.hex gold.hex job.txt; do
    [ -s "$outdir/w$w/$f" ] || { echo "FATAL: 缺 $outdir/w$w/$f"; echo "RESULT: FAIL"; exit 3; }
  done
done

# ---------------- 2) 编译（好网表 + "rowW 钉成 640" 突变体） ----------------
echo "---- [2] iverilog 编译（UnitExecWideTb + AxiMemModel + 好网表 / 突变体）----"
ivc() { # ivc <out-vvp> <netlist> <tag>
  if ! "$IVERILOG" -g2012 -o "$1" "$tb" "$memv" "$2" > "$work/iv_$3.log" 2>&1; then
    echo "JUDGE-RED(1): iverilog 编译失败（$3）"; sed -n '1,25p' "$work/iv_$3.log"; echo "RESULT: FAIL"; exit 1
  fi
}
ivc "$work/good.vvp" "$nl" "good" && echo "    好网表编译 OK（$nl）"
if ! "$PY" - "$nl" "$work/mut_roww640.v" "$LATCH" <<'PYEOF'
import sys
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
a, out = sys.argv[3], sys.argv[2]
b = "  rowW <= 20'h00280;   // MUT: pin rowW to 640 (W_MAX) — ignore the runtime latch"
n = src.count(a)
if n != 1:
    print("MUT-ERROR: %s 里 '%s' 命中 %d 处（期望 1）" % (sys.argv[1], a, n)); sys.exit(1)
open(out, "w", encoding="utf-8", newline="\n").write(src.replace(a, b))
print("MUT: %s 的 rowW 闩存 -> 20'h00280（1 处）⇒ **rowW 钉死成 640**" % sys.argv[1])
PYEOF
then
  echo "JUDGE-RED(2): 构造突变体失败"; echo "RESULT: FAIL"; exit 2
fi
cmp -s "$nl" "$work/mut_roww640.v" && { echo "JUDGE-RED(2): 突变网表与原文相同"; echo "RESULT: FAIL"; exit 2; }
ivc "$work/mut.vvp" "$work/mut_roww640.v" "mut" && echo "    突变体编译 OK（外科式：只动 go 拍那一条闩存）"

memgen() { # memgen <dir>  —— 素周期 251 的镜像；DST 区预载与黄金压倒性不同 ⇒ "不写"必被抓住
  local d="$1"
  "$PY" - "$d" "$work" "$MEMSZ" "$DST" <<'PYEOF'
import sys
d, work, memsz, dst = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
g = [int(l.strip(), 16) for l in open(d + "/gold.hex") if l.strip()]
ln = len(g)
pre = [((i % 251) * 131 + 7) % 251 for i in range(memsz)]
dif = sum(1 for j in range(ln) if pre[dst + j] != g[j])
assert dif >= int(ln * 0.9), "dst 预载与黄金只差 %d/%d" % (dif, ln)
txt = "".join("%02x\n" % b for b in pre)
open(work + "/mem.hex", "w").write(txt)
open(work + "/pre.hex", "w").write(txt)
print("MEMGEN %s dst_len=%d dst_preload_vs_gold_diff=%d/%d" % (d.split('/')[-1], ln, dif, ln))
PYEOF
}

judge_dst() { # judge_dst <dump> <gold> <len> <out>  -> MISMATCH / 邻居
  "$PY" - "$1" "$2" "$3" "$4" "$DST" <<'PYEOF'
import sys
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
dump, gold, ln, out, dst = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], int(sys.argv[5])
def load(p):
    o = []
    for l in open(p, encoding="utf-8", errors="replace"):
        s = l.strip()
        if not s: continue
        try: o.append(int(s, 16) & 0xFF)
        except ValueError: o.append(-1)
    return o
d = load(dump); g = load(gold); p = load(dump.rsplit('/', 1)[0] + "/pre.hex")
k = min(ln, len(g))
first = -1
for i in range(k):
    if dst + i >= len(d) or d[dst + i] != g[i]:
        first = i; break
mis = sum(1 for i in range(k) if dst + i >= len(d) or d[dst + i] != g[i]) + max(0, ln - k)
nb = 0
if dst >= 32:
    nb += sum(1 for i in range(32) if d[dst - 32 + i] != p[dst - 32 + i])
for i in range(32):
    if dst + ln + i < len(d) and d[dst + ln + i] != p[dst + ln + i]: nb += 1
open(out, "w").write("MISMATCH=%d\nDST_NEIGHBOR32_BAD=%d\nFIRST_IDX=%d\n" % (mis, nb, first))
print("MISMATCH=%d DST_NEIGHBOR32_BAD=%d FIRST_IDX=%d" % (mis, nb, first))
PYEOF
}

# run_job <vvp> <dir> <tag>  —— 从 job.txt 组 plusarg 跑一次（列流 = xcol.hex）
run_job() {
  local vvp="$1" d="$2" tag="$3"
  local CIN COUT HIN WIN H W NCOL INB STRIDE M ZP ZY NCI NCO
  CIN="$(sed -n 's/^CIN=//p' "$d/job.txt")";  COUT="$(sed -n 's/^COUT=//p' "$d/job.txt")"
  HIN="$(sed -n 's/^HIN=//p' "$d/job.txt")";  WIN="$(sed -n 's/^WIN=//p' "$d/job.txt")"
  H="$(sed -n 's/^HO=//p' "$d/job.txt")";     W="$(sed -n 's/^WO=//p' "$d/job.txt")"
  STRIDE="$(sed -n 's/^STRIDE=//p' "$d/job.txt")"; M="$(sed -n 's/^M=//p' "$d/job.txt")"
  ZP="$(sed -n 's/^ZPAD=//p' "$d/job.txt")";  ZY="$(sed -n 's/^ZY=//p' "$d/job.txt")"
  NCI="$(sed -n 's/^NCI=//p' "$d/job.txt")";  NCO="$(sed -n 's/^NCO=//p' "$d/job.txt")"
  NCOL="$(sed -n 's/^NCOL=//p' "$d/job.txt")"; INB=$(( CIN * HIN * WIN ))
  ( cd "$work" && "$VVP" "$vvp" \
      "+XFILE=$PWD_ABS/$d/xcol.hex" "+WFILE=$PWD_ABS/$d/w.hex" "+BFILE=$PWD_ABS/$d/b.hex" \
      "+MEMFILE=$work/mem.hex" "+DUMPFILE=$work/$tag.dump" +dump \
      "+CIN=$CIN" "+COUT=$COUT" "+GROUP=1" "+H=$H" "+W=$W" "+TYPE=1" "+FLAGS=1" \
      "+SRC=$SRC" "+DST=$DST" "+INB=$INB" "+QSHIFT=6" "+LID=0" \
      "+M=$M" "+ZPAD=$ZP" "+ZY=$ZY" "+NCOL=$NCOL" "+NCI=$NCI" "+NCO=$NCO" "+STRIDE=$STRIDE" ) \
      > "$work/$tag.log" 2>&1
}

# ---------------- 3) 逐作业：一张网表 × 6 个行宽（正对照，逐字节） ----------------
echo "---- [3] 逐作业：$nl 的 DST 区逐字节 == 黄金（6 个真行宽）+ 自报 RTL_ROW_W == 行宽 ----"
TOTAL_BAD=0
declare -A ROWW
for w in $WIDTHS; do
  d="$outdir/w$w"
  COUT="$(sed -n 's/^COUT=//p' "$d/job.txt")"
  HO_="$(sed -n 's/^HO=//p' "$d/job.txt")"; WO_="$(sed -n 's/^WO=//p' "$d/job.txt")"
  LEN=$(( COUT * HO_ * WO_ ))
  memgen "$d" | sed 's/^/    /'
  run_job "$work/good.vvp" "$d" "pos_w$w"
  grep -E '^(TB WIDE|RESULT)' "$work/pos_w$w.log" | sed "s/^/    [w$w] /"
  if ! grep -q '^RESULT: PASS' "$work/pos_w$w.log"; then
    echo "JUDGE-RED(1): 装置未 PASS（w=$w）"; tail -6 "$work/pos_w$w.log"; TOTAL_BAD=$((TOTAL_BAD+1)); continue
  fi
  REP="$(grep -m1 '^TB WIDE RTL:' "$work/pos_w$w.log")"
  RMAXP="$(printf '%s' "$REP" | sed -n 's/.*RTL_MAXPIX=\([0-9]*\).*/\1/p')"
  [ "$RMAXP" = "$PIXW" ] || { echo "JUDGE-RED(1): 网表 RTL_MAXPIX=$RMAXP != $PIXW（w=$w）⇒ 不是 W_MAX=$WMAX 的网表"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  case "$REP" in *"WIDE_ON=1"*) : ;; *) echo "JUDGE-RED(1): 宽通路未开（w=$w）got=$REP"; TOTAL_BAD=$((TOTAL_BAD+1));; esac
  # ★ 运行期行宽自报：必须 == 本作业行宽（6 个作业 ⇒ 6 个不同的值）
  RW="$(grep -m1 '^TB WIDE ROW:' "$work/pos_w$w.log" | sed -n 's/.*RTL_ROW_W=\([0-9]*\).*/\1/p')"
  ROWW[$w]="${RW:-?}"
  [ "$RW" = "$w" ] || { echo "JUDGE-RED(1): 运行期行宽自报 RTL_ROW_W=$RW != 行宽 $w（闩存没在跑）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  judge_dst "$work/pos_w$w.dump" "$d/gold.hex" "$LEN" "$work/pos_w$w.judge" | sed 's/^/    /'
  MPOS="$(sed -n 's/^MISMATCH=//p' "$work/pos_w$w.judge")"
  NB="$(sed -n 's/^DST_NEIGHBOR32_BAD=//p' "$work/pos_w$w.judge")"
  GD="$(distinct "$d/gold.hex")"
  [ "$MPOS" = "0" ] || { echo "JUDGE-RED(1): 正对照 != 黄金（MISMATCH=$MPOS，w=$w）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$NB" = "0" ]  || { echo "JUDGE-RED(1): dst 邻居被改（$NB，w=$w）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$GD" -gt 1 ] 2>/dev/null || { echo "JUDGE-RED(1): 黄金退化 distinct=$GD（w=$w）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  echo "JOB w=$w H=$HO_ | DST_MISMATCH=$MPOS neigh=$NB distinct(gold=$GD) RTL_ROW_W=$RW RTL_MAXPIX=$RMAXP"
done

# 6 个自报值必须互不相同（"一张网表跑出 6 个行宽"的直接证据）
NDIST="$(printf '%s\n' "${ROWW[@]}" | sort -u | wc -l)"
echo "   运行期行宽自报集合 = [${ROWW[640]} ${ROWW[320]} ${ROWW[160]} ${ROWW[80]} ${ROWW[40]} ${ROWW[20]}]（互异值 $NDIST/6）"
[ "$NDIST" = "6" ] || { echo "JUDGE-RED(1): 6 个行宽自报没有互异（$NDIST/6）⇒ 闩存没在跑"; TOTAL_BAD=$((TOTAL_BAD+1)); }

# ---------------- 4) 负对照：rowW 钉成 640 ⇒ 非 640 必红（640 必绿，外科式） ----------------
echo "---- [4] 负对照：网表突变「rowW 钉成 640」⇒ 非 640 行宽必红、640 行宽必绿（外科式）----"
NEG_NOFIRE=0
for w in $WIDTHS; do
  d="$outdir/w$w"
  COUT="$(sed -n 's/^COUT=//p' "$d/job.txt")"
  HO_="$(sed -n 's/^HO=//p' "$d/job.txt")"; WO_="$(sed -n 's/^WO=//p' "$d/job.txt")"
  LEN=$(( COUT * HO_ * WO_ ))
  memgen "$d" >/dev/null
  run_job "$work/mut.vvp" "$d" "mut_w$w"
  judge_dst "$work/mut_w$w.dump" "$d/gold.hex" "$LEN" "$work/mut_w$w.judge" > /dev/null
  MMIS="$(sed -n 's/^MISMATCH=//p' "$work/mut_w$w.judge")"
  TPASS=0; grep -q '^RESULT: PASS' "$work/mut_w$w.log" && TPASS=1
  if [ "$w" = "640" ]; then
    # 外科式：640 层的真行宽本来就是 640 ⇒ 这一刀不该改变它
    if [ "$MMIS" = "0" ] && [ "$TPASS" = "1" ]; then
      echo "NEG-OK  [w=640]  + 突变体：MISMATCH=$MMIS tbPASS=$TPASS（==0/1 ⇒ 这一刀对 640 层是空的 ⇒ 外科式）"
    else
      echo "NEG-BAD [w=640]  + 突变体：MISMATCH=$MMIS tbPASS=$TPASS（期望 0/1）⇒ 这一刀不是外科式"; NEG_NOFIRE=$((NEG_NOFIRE+1))
    fi
  else
    if [ "$MMIS" != "0" ] || [ "$TPASS" != "1" ]; then
      echo "NEG-FIRE[w=$w] + 突变体：MISMATCH=$MMIS tbPASS=$TPASS（>0 或 !PASS ⇒ 非 640 层必红，发火）"
    else
      echo "NEG-NOFIRE[w=$w] + 突变体：MISMATCH=$MMIS tbPASS=$TPASS（==0/1）⇒ 负对照没发火（判据无牙）"; NEG_NOFIRE=$((NEG_NOFIRE+1))
    fi
  fi
done

# 黄金分辨度：6 个行宽的黄金必须互不相同（否则"行宽真改了输出"没被刻画）
declare -A GMD5
NGOLD=0
for w in $WIDTHS; do
  m="$("$PY" -c "import hashlib,sys;print(hashlib.md5(bytes(int(l,16)&0xFF for l in open(sys.argv[1]) if l.strip())).hexdigest())" "$outdir/w$w/gold.hex")"
  GMD5[$w]="$m"
done
NGOLD="$(printf '%s\n' "${GMD5[@]}" | sort -u | wc -l)"
echo "   黄金分辨度：6 个行宽的黄金值 md5 互异数 = $NGOLD/6（>1 ⇒ 行宽确实改了输出）"
[ "$NGOLD" = "6" ] || echo "   ★ 注意：有行宽的黄金相同（可接受，但削弱分辨度）"

# ---------------- 判决 ----------------
echo "=========================================================================="
echo "T-S1（运行期行宽 rowW；spec §5 T1）："
echo "  参考     = OK（stride_ref --selftest：两套实现互证；s=1 == 冻结 C4a.5b caliber）"
echo "  正对照   = OK（**一张网表** $nl 重放真表 6 个行宽 {$WIDTHS} ⇒ DST 逐字节 == 黄金；"
echo "                   自报 RTL_ROW_W 互异 6/6；WIDE_ON=1；RTL_MAXPIX=$PIXW = W_MAX·IMG_H_MAX）"
echo "  负对照   = 见上（rowW 钉成 640：非 640 必红、640 必绿 ⇒ 定点发火 + 外科式）"
if [ "$NEG_NOFIRE" -ne 0 ]; then echo "NEGCTL-FAIL: $NEG_NOFIRE 条负对照没发火"; echo "RESULT: FAIL"; exit 2; fi
if [ "$TOTAL_BAD" -ne 0 ]; then echo "JUDGE-RED: $TOTAL_BAD 条判据未过"; echo "RESULT: FAIL"; exit 1; fi
echo "ROW W RESULT: PASS"
echo "RESULT: PASS"
exit 0
