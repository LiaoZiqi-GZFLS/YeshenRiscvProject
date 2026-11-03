#!/usr/bin/env bash
# run_inlayout_ab.sh —— ★★ C4b-B3 闸门：**输入布局契约**（DDR 的通道平面张量 → NPU 读到的 ci-block 列流）
#
# 被测行为（`rtl/UnitExec.scala` 的 `WIDERUN` + 本任务新增的 **DDR gather**；`XDMA_EN` = 信箱区域 7 道 0）：
#   宿主把**一张图**按**冻结布局**（通道平面 / NCHW：元素 `(c,p)` 在 `SRC_ADDR + c*H*W + p`）写进 DDR；
#   DUT **自己**从 DDR gather 成"行主序 8 通道列流"（一拍一列）喂 `MultiPassUnit`；
#   `C_in % 8 != 0` 的通道（真表 `Conv_0` 的 3..7）**不在张量里** ⇒ 由 RTL 零填充（与 B1c 权重零填充同口径）。
#
# 用例（`tools/wide_exec_ref.py` 供料；**不重写算术**）：
#   A) 真层 `Conv_0`（C_IN=3 C_OUT=16，`n_ci=1 n_co=2`）—— **首次消费 + `C_in=3` 的零填充**这条；
#   B) 合成宽层 16→16（`n_ci=2 n_co=2`）—— **多趟（跨 ci-block gather + 累加）**这条。
#
# 判据（每条都要过）：
#   0) 参考自检：`wide_exec_ref.py --selftest`（拆趟==整层 + 两条负对照都有牙）。
#   1) **正对照（逐列逐通道，字节级）**：装置导出的"**被 DUT 收下的列流**" == 参考 `x.hex`
#      （= 冻结布局的预期列流）⇒ `COL_MISMATCH=0`；**且** `DST` 区 == `gold.hex`（数值端到端）；
#      `RD_PEAK == +XEXP`（gather 从 DDR 读回的字节数 == Σ_趟(有效平面数 × H*W)）。
#   2) **负对照（必须发火）**：把同一张图按**通道序反**写进 DDR（`xin_bad.hex`）⇒
#      列流 `!=` 预期（`NEG_COL_MISMATCH>0`）**且** `DST != 黄金`（`NEG_DST_MISMATCH>0`）⇒ 判据有牙、可定位。
#   3) **结构性判据**：装置**不驱动** `wide_x`（若 DUT 误走外部端口 ⇒ 列流全 0 ⇒ 判据 1 当场红）。
#
# 退出码：0 = 全绿；1 = 判据红；2 = 负对照没发火；3 = 前置缺失。
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

tool="tools/wide_exec_ref.py"
tb="rtl_test/XLayoutTb.v"
memv="rtl_test/AxiMemModel.v"
nl="${XLAY_NL:-gen/UnitExec.v}"
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
cleanup() { if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => 中间件在 $work"; else rm -rf "$work"; fi; }
trap cleanup EXIT
export PYTHONPATH="./.pydeps;../third_party/yunet/deps"
export PYTHONIOENCODING=utf-8

echo "== run_inlayout_ab: 输入布局契约（DDR 通道平面 -> NPU 收下的 ci-block 列流）=="
echo "   nl=$nl  tb=$tb  py=$PY  iverilog=$IVERILOG  vvp=$VVP  tmp=$work"

echo "---- [0] tools/wide_exec_ref.py --selftest（拆趟==整层 + 两条负对照都有牙）----"
if ! "$PY" "$tool" --selftest > "$work/st.out" 2>&1; then
  echo "JUDGE-RED(3): 参考自检没过 ⇒ 用例/参考写错了"; tail -10 "$work/st.out"; echo "RESULT: FAIL"; exit 3
fi
grep -E '^(SELFTEST|RESULT:)' "$work/st.out" | grep -v '^RESULT:' | sed 's/^/    /'

echo "---- [1] 供料：真层 Conv_0（lid0，3->16，首次消费 + C_in=3 零填充）+ 合成宽层（16->16，n_ci=2）----"
for spec in "--lid 0" "--synth 16 16"; do
  if ! "$PY" "$tool" $spec --H 4 --W 64 --outdir "$outdir" > "$work/ref.out" 2>&1; then
    echo "JUDGE-RED(1): 供料失败（$spec）"; tail -10 "$work/ref.out"; echo "RESULT: FAIL"; exit 1
  fi
  grep -E '^WIDE_REF' "$work/ref.out" | sed 's/^/    /'
done

echo "---- [2] iverilog 编译（XLayoutTb + AxiMemModel + gen/UnitExec.v）----"
if ! "$IVERILOG" -g2012 -o "$work/xlay.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED(1): iverilog 编译失败"; sed -n '1,30p' "$work/iv.log"; echo "RESULT: FAIL"; exit 1
fi
echo "    编译 OK"

TOTAL_BAD=0; NEG_NOFIRE=0; JOBS=""

for d in $(ls -d "$outdir"/lid*_* "$outdir"/synth_* 2>/dev/null | sort); do
  [ -f "$d/job.txt" ] || continue
  [ -f "$d/xin.hex" ] || continue
  [ -f "$d/xin_bad.hex" ] || continue
  eval "$(sed 's/^/X_/' "$d/job.txt" | tr '\n' ' ')"   # KV -> shell 变量（前缀 X_）
  CIN="${X_CIN}"; COUT="${X_COUT}"; HH="${X_H}"; WW="${X_W}"; SRC="${X_SRC}"; DST="${X_DST}"
  INB="${X_IN_BYTES}"; QSH="${X_QSHIFT}"; LID="${X_LID}"; MV="${X_M}"; ZP="${X_ZPAD}"; ZY="${X_ZY}"
  NCOL="${X_NCOL}"; NCI="${X_NCI}"; NCO="${X_NCO}"; NPASS="${X_NPASS}"; NM="${X_NAME}"; XEXP="${X_XEXP}"
  JOBS="$JOBS $NM"
  tag="$(basename "$d")"
  LEN=$(( COUT * HH * WW ))
  XLEN=$(( CIN * HH * WW ))

  # ---- 内存镜像：素周期 251 的底纹；**宿主的那张图**写进 `SRC`；`DST` 区预载与黄金不同 ----
  build_mem() {   # $1 = 输入张量文件（通道平面）  $2 = 输出镜像（绝对路径）
    "$PY" - "$1" "$d" "$2" "$MEMSZ" "$SRC" "$DST" "$LEN" "$XLEN" <<'PYEOF'
import sys
xin_p, d, out_p, memsz, src, dst, ln, xln = (sys.argv[1], sys.argv[2], sys.argv[3],
    int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7]), int(sys.argv[8]))
g = [int(l.strip(), 16) for l in open(d + "/gold.hex") if l.strip()]
xi = [int(l.strip(), 16) for l in open(xin_p) if l.strip()]
assert len(xi) == xln, "输入张量字节数 %d != C_IN*H*W=%d" % (len(xi), xln)
assert src + xln <= dst, "输入张量(%d..%d)与 DST(%d)重叠" % (src, src + xln, dst)
pre = [((i % 251) * 131 + 7) % 251 for i in range(memsz)]
dif = sum(1 for j in range(ln) if pre[dst + j] != g[j])
assert dif >= int(ln * 0.9), "dst 预载与黄金只差 %d/%d" % (dif, ln)
for j, b in enumerate(xi):
    pre[src + j] = b & 0xFF
open(out_p, "w").write("".join("%02x\n" % b for b in pre))
print("MEMGEN %s img@%d(%dB) dst_preload_vs_gold_diff=%d/%d" % (d.split('/')[-1], src, xln, dif, ln))
PYEOF
  }

  build_mem "$d/xin.hex" "$work/mem_pos.mem" > "$work/memgen_pos.out" 2>&1 \
    || { echo "JUDGE-RED(3): 正对照内存镜像失败（$tag）"; cat "$work/memgen_pos.out"; exit 3; }
  sed 's/^/    /' "$work/memgen_pos.out"
  build_mem "$d/xin_bad.hex" "$work/mem_bad.mem" > "$work/memgen_bad.out" 2>&1 \
    || { echo "JUDGE-RED(3): 负对照内存镜像失败（$tag）"; cat "$work/memgen_bad.out"; exit 3; }

  PWD_ABS="$(pwd)"
  # run_job <stem> <x-in-file>   （stem 同时用于 log / xcol / dump / mem）
  run_job() {
    ( cd "$work" && "$VVP" "$work/xlay.vvp" \
        "+WFILE=$PWD_ABS/$d/w.hex" "+BFILE=$PWD_ABS/$d/b.hex" \
        "+XIN=$PWD_ABS/$2" "+XDUMP=$work/$1.xcol" "+XEXP=$XEXP" \
        "+MEMFILE=$work/$1.mem" "+DUMPFILE=$work/$1.dump" +dump \
        "+CIN=$CIN" "+COUT=$COUT" "+GROUP=1" "+H=$HH" "+W=$WW" "+TYPE=1" "+FLAGS=${FLAGS_ARG:-1}" \
        "+SRC=$SRC" "+DST=$DST" "+INB=$INB" "+QSHIFT=$QSH" "+LID=$LID" \
        "+M=$MV" "+ZPAD=$ZP" "+ZY=$ZY" "+NCOL=$NCOL" "+NCI=$NCI" "+NCO=$NCO" ) \
        > "$work/$1.log" 2>&1
  }

  # ---- 3) 正对照 ----
  #   `XLAY_HEAD_ONLY=1` ⇒ 跳过本段（只跑 4b 的 head 变体；用于在 tiled 网表上单测 `xg` 路径：
  #   tiled 网表的非 head 宽层走 `wx`，列序与整层黄金不同，那几项在这里没有意义）。
  if [ "${XLAY_HEAD_ONLY:-0}" != "1" ]; then
  if ! run_job "mem_pos" "$d/xin.hex"; then
    echo "JUDGE-RED(1): 正对照装置未跑完（$tag）"; tail -8 "$work/mem_pos.log"; TOTAL_BAD=$((TOTAL_BAD+1)); continue
  fi
  grep -E '^(TB XLAY|DONE_SEEN|RESULT)' "$work/mem_pos.log" | sed "s/^/    [$tag] /"
  if ! grep -q '^RESULT: PASS' "$work/mem_pos.log"; then
    echo "JUDGE-RED(1): 正对照装置未 PASS（$tag）"; tail -8 "$work/mem_pos.log"; TOTAL_BAD=$((TOTAL_BAD+1)); continue
  fi
  # 自报对账（与既有宽层闸门同一口径）
  REP="$(grep -m1 '^TB XLAY RTL:' "$work/mem_pos.log")"
  case "$REP" in
    *"WIDE_ON=1 WIDE_PASSES=$NPASS"*"RTL_M=$MV RTL_ZPAD=$ZP RTL_ZY=$ZY RTL_LAYER=$LID"*) : ;;
    *) echo "JUDGE-RED(1): 自报不符（$tag）"; echo "  got=$REP"; TOTAL_BAD=$((TOTAL_BAD+1));;
  esac

  # ---- 3b) 内存模型独立计数（★ 与 DUT 内部计数**两处独立**）：gather 从 DDR 读回的总字节数 == XEXP ----
  MERRD="$(sed -n 's/^MEM rd=\([0-9]*\) wr=.*/\1/p' "$work/mem_pos.log" | tail -1)"
  MERWR="$(sed -n 's/^MEM rd=[0-9]* wr=\([0-9]*\) .*/\1/p' "$work/mem_pos.log" | tail -1)"
  MEBST="$(sed -n 's/.*bursts=\([0-9]*\) maxburst.*/\1/p' "$work/mem_pos.log" | tail -1)"
  [ "$MERRD" = "$XEXP" ] || { echo "JUDGE-RED(1): 内存模型读回 $MERRD != XEXP=$XEXP（$tag）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$MERWR" = "$LEN" ]  || { echo "JUDGE-RED(1): 内存模型写出 $MERWR != C_out*H*W=$LEN（$tag）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  echo "    [$tag] MEM rd=$MERRD(期望 $XEXP) wr=$MERWR(期望 $LEN) bursts=$MEBST"

  # ---- 4) 判据：**列流**（逐列逐通道）+ DST 数值 ----
  judge() {   # $1 = 列流 dump; $2 = DDR dump
    "$PY" - "$1" "$d/x.hex" "$2" "$d/gold.hex" "$DST" "$LEN" "$NCOL" <<'PYEOF'
import sys
xcol_p, xref_p, dump_p, gold_p, dst, ln, ncol = (sys.argv[1], sys.argv[2], sys.argv[3],
    sys.argv[4], int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7]))
# 预期列流：`x.hex` 是**扁平字节序列**（每列 8 个通道，通道 0 在前）⇒ 按 8 个一组还原成列
xr = [int(l.strip(), 16) for l in open(xref_p) if l.strip()]
xr_cols = ["".join("%02x" % b for b in xr[i * 8:i * 8 + 8]) for i in range(len(xr) // 8)]
got = [l.strip().lower() for l in open(xcol_p, encoding="utf-8", errors="replace") if l.strip()]
ncol_cmp = min(len(got), len(xr_cols))
col_mis = sum(1 for i in range(ncol_cmp) if got[i] != xr_cols[i]) + abs(len(got) - len(xr_cols))
first = next((i for i in range(ncol_cmp) if got[i] != xr_cols[i]), -1)
lane_mis = 0
if first >= 0:
    a, b = got[first], xr_cols[first]
    lane_mis = sum(1 for k in range(0, 16, 2) if a[k:k + 2] != b[k:k + 2])
def load(p):
    out = []
    for l in open(p, encoding="utf-8", errors="replace"):
        s = l.strip()
        if not s: continue
        try: out.append(int(s, 16))
        except ValueError: out.append(-1)
    return out
dd = load(dump_p); gg = load(gold_p)
k = min(ln, len(gg), max(0, len(dd) - dst))
dst_mis = sum(1 for i in range(k) if dd[dst + i] != gg[i]) + max(0, ln - k)
print("COL_COUNT=%d/%d" % (len(got), ncol))
print("COL_MISMATCH=%d" % col_mis)
print("COL_FIRST_BAD=%d" % first)
print("COL_FIRST_BAD_LANES=%d" % lane_mis)
print("DST_MISMATCH=%d" % dst_mis)
PYEOF
  }
  judge "$work/mem_pos.xcol" "$work/mem_pos.dump" > "$work/pos_judge"
  sed 's/^/    /' "$work/pos_judge"
  PC="$(sed -n 's/^COL_MISMATCH=//p' "$work/pos_judge")"
  PD="$(sed -n 's/^DST_MISMATCH=//p' "$work/pos_judge")"
  [ "$PC" = "0" ] || { echo "JUDGE-RED(1): 正对照列流 != 冻结布局（COL_MISMATCH=$PC，$tag）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$PD" = "0" ] || { echo "JUDGE-RED(1): 正对照 DST != 黄金（DST_MISMATCH=$PD，$tag）"; TOTAL_BAD=$((TOTAL_BAD+1)); }

  # ---- 5) 负对照：**通道序反** ⇒ 列流必须不同、DST 必须不同（且装置仍能跑完）----
  run_job "mem_bad" "$d/xin_bad.hex" || true
  if ! grep -q '^RESULT: PASS' "$work/mem_bad.log"; then
    echo "JUDGE-RED(1): 负对照装置未 PASS（$tag）—— 负对照本身没跑完，判据不算数"
    tail -6 "$work/mem_bad.log"; TOTAL_BAD=$((TOTAL_BAD+1)); continue
  fi
  judge "$work/mem_bad.xcol" "$work/mem_bad.dump" > "$work/bad_judge"
  sed 's/^/    /' "$work/bad_judge"
  NC="$(sed -n 's/^COL_MISMATCH=//p' "$work/bad_judge")"
  ND="$(sed -n 's/^DST_MISMATCH=//p' "$work/bad_judge")"
  NL="$(sed -n 's/^COL_FIRST_BAD_LANES=//p' "$work/bad_judge")"
  [ "$NC" -gt 0 ] 2>/dev/null || { echo "NEGCTL-FAIL: 负对照（通道序反）列流与预期**相同**（$tag）⇒ 判据没牙"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }
  [ "$ND" -gt 0 ] 2>/dev/null || { echo "NEGCTL-FAIL: 负对照（通道序反）DST 与黄金**相同**（$tag）⇒ 判据没牙"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }

  fi   # XLAY_HEAD_ONLY

  # ---- 4b) head 变体（`XLAY_HEAD=1`）：`FLAGS.bit0=0` ⇒ `isHead` ⇒ 宽路走 **`xg`** ----
  #   `tilingWideC` 要求 `!isHead` ⇒ 这是本仓**唯一**能让宽路落到 `xg`（非 tiled gather）的档；
  #   配 `XLAY_NL=gen/UnitExec_tiled.v` 即覆盖 **XG-SG**（SG 批式 xg）。head 不写 DST ⇒ **只判列流**。
  if [ "${XLAY_HEAD:-0}" = "1" ]; then
    FLAGS_ARG=0
    run_job "mem_head" "$d/xin.hex" || true
    FLAGS_ARG=1
    if ! grep -q '^RESULT: PASS' "$work/mem_head.log"; then
      echo "JUDGE-RED(1): head 变体装置未 PASS（$tag）"
      tail -6 "$work/mem_head.log"; TOTAL_BAD=$((TOTAL_BAD+1))
    else
      judge "$work/mem_head.xcol" "$work/mem_head.dump" > "$work/head_judge"
      sed 's/^/    head: /' "$work/head_judge"
      HC="$(sed -n 's/^COL_MISMATCH=//p' "$work/head_judge")"
      [ "$HC" = "0" ] || { echo "JUDGE-RED(1): head 列流 != 冻结布局（COL_MISMATCH=$HC，$tag）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
      echo "HEAD $NM col_mis=$HC（xg 路径，只判列流）"
    fi
  fi

  echo "JOB $NM CIN=$CIN COUT=$COUT C_out%8=$(($COUT % 8)) n_ci=$NCI n_co=$NCO col=$NCOL XEXP=$XEXP | POS col_mis=$PC dst_mis=$PD | NEG col_mis=$NC (首列 $NL 道错) dst_mis=$ND"
done

echo "=========================================================================="
echo "作业集合：$JOBS"
echo "正对照   = OK（**被收下的列流**逐列逐通道 == 冻结布局的预期列流；DST == 黄金；RD_PEAK == +XEXP）"
echo "负对照   = OK（通道序反 ⇒ 列流与 DST 都变 ⇒ 判据有牙，且能定位到首列/首道）"
echo "结构性   = OK（装置**不驱动** wide_x：列来源确实在 DUT 内部的 DDR gather 通路上）"
if [ "$NEG_NOFIRE" -ne 0 ]; then echo "NEGCTL-FAIL: $NEG_NOFIRE 条负对照没发火"; echo "RESULT: FAIL"; exit 2; fi
if [ "$TOTAL_BAD" -ne 0 ]; then echo "JUDGE-RED: $TOTAL_BAD 条判据未过"; echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
exit 0
