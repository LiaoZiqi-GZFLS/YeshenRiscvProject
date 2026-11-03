#!/usr/bin/env bash
# run_dwlane_ab.sh —— ★★ NPU v2 切片 B-1：**depthwise lane 打包探针**的闸门（数值 + 拍数 + 两条负对照）。
#
# 被测（**独立探针**，不改任何产品 RTL）：`rtl_test/DwLaneProbe.scala` 出的三档网表
#   · `gen/DwLaneBefore.v`（MODE 0）—— as-built：x 是 8 宽**广播**总线、每像素 9 个 tap-beat
#     （= `Conv3x3Slice` 的现行为；这一档是"改之前"的基准价）。
#   · `gen/DwLaneAfter2.v`（MODE 1）—— **tap-inner 打包**：x 变成**逐 lane**（lane(r,j) = 通道 r 在抽头 j 的
#     窗口值，静态寄存器直连），每拍退 8 个抽头、第 9 抽头在第 2 拍 ⇒ **2 拍/像素**（P0b 的"保守打包"）。
#   · `gen/DwLaneAfter1.v`（MODE 2）—— tap-inner + **第 9 抽头行**（多 8 个乘法器并进同一个 acc）
#     ⇒ **1 拍/像素**（P0b 的"理想式"拍数）。
#   · `gen/DwLaneAfter1Mut5.v`（MODE 2 + MUTX=5）—— **外科锚**：lane 5 的 x 路由改错（kx 由 2 改成 0）
#     ⇒ 只用于负对照 B（"路由承重"）。
#   装置 = `rtl_test/DwLaneTb.v`（一份 TB，一次只编译一份探针网表；MODE 0 需要 `-DMODE0`）。
#
# 判据（全部按**预测量**断言，不看"像不像"）：
#   [0] 前置：冻结参考自检；四份探针网表存在（md5 记入输出）。
#   [1] 正对照（**逐字节**，六个真 dw 形状 = 真表 `C ∈ {4,10,16,32,64}` + 单块基准 `C=8`）：
#       四档网表对同一作业、同一权重、同一黄金 ⇒ `MISMATCH == 0`（黄金 = 冻结 `multipass_ref` 的
#       `conv_tiled`；与 `quant_ref.conv_vec` 二实现互证由那个冻结工具自己保证）；
#       · FROZEN-before：**BEFORE 档 = 现网表口径**（广播 + 9 拍）逐字节对上黄金 ⇒ 探针对照组可信。
#   [2] 拍数（**实测**）：`BEATS == taps·NB·NPIX`，taps = 9（BEFORE）/ 2（AFTER2）/ 1（AFTER1）
#       ⇒ 实测比 9.00× / 4.50×（AFTER1 vs BEFORE）。
#   [3] 负对照 A（**tap-8 切除**，按预测量发火）：把瓦片里第 9 抽头（`mem[r*72+r*9+8]`）置 0 再跑
#       ⇒ 三档 MISMATCH **恰 ==** python 现算的预测（> 0）—— 证明"第 9 抽头真的被吃掉"。
#   [4] 负对照 B（**路由突变**，按预测量发火）：`DwLaneAfter1Mut5` 跑正规瓦片 ⇒ MISMATCH **恰 ==**
#       python 现算的预测（> 0）；同一作业在正规网表上 == 0 ⇒ 红是**路由**造成的，不是注入本身。
#   [5] 一致性：BEFORE / AFTER2 / AFTER1 三档的 Y **逐字节相同**（同一条算术、三种打包）。
#
# 退出码：0 = 全过 / 1 = 判据红 / 2 = 负对照没发火（预测 ≤ 0 或不等） / 3 = 前置缺失。
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

ref="tools/multipass_ref.py"
tb="rtl_test/DwLaneTb.v"
nlB="gen/DwLaneBefore.v"
nl1="gen/DwLaneAfter1.v"
nl2="gen/DwLaneAfter2.v"
nlM="gen/DwLaneAfter1Mut5.v"
outdir="gen/c4a_dwlane"
SEED=20261016

find_tool() {
  local n="$1" p d
  p="$(command -v "$n" 2>/dev/null || true)"
  if [ -z "$p" ]; then for d in /c/msys64/ucrt64/bin /mingw64/bin /usr/bin; do [ -x "$d/$n" ] && { p="$d/$n"; break; }; done; fi
  printf '%s' "$p"
}
IVERILOG="$(find_tool iverilog)"; VVP="$(find_tool vvp)"

echo "== run_dwlane_ab: NPU v2 切片 B-1（depthwise lane 打包探针：before/after2/after1 + 两条负对照）=="
echo "   tb=$tb  nl=$nlB $nl2 $nl1 $nlM  py=$PY  iverilog=${IVERILOG:-<none>}"

for f in "$ref" "$tb" "$nlB" "$nl2" "$nl1" "$nlM"; do
  [ -f "$f" ] || { echo "FATAL: 缺 $f（先 Test/runMain DwLaneGen ... 生成）"; echo "RESULT: FAIL"; exit 3; }
done
[ -n "$IVERILOG" ] && [ -n "$VVP" ] || { echo "FATAL: 缺 iverilog/vvp"; echo "RESULT: FAIL"; exit 3; }

work="$(mktemp -d)"
cleanup() { [ "${KEEP_TMP:-0}" = "1" ] && echo "KEEP_TMP=1 => $work" || rm -rf "$work"; }
trap cleanup EXIT
export PYTHONPATH="./.pydeps;../third_party/yunet/deps"
export PYTHONIOENCODING=utf-8
PWD_ABS="$(pwd)"

# cnt <a> <b> -> mismatch token count（长度不等 ⇒ 取较长者；缺文件 ⇒ -1）
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

echo "---- [0] 前置：冻结参考自检 ----"
"$PY" "$ref" --selftest >/dev/null 2>&1 || { echo "RESULT: FAIL 冻结参考自检没过"; exit 3; }
echo "   参考自检 OK（multipass_ref.py --selftest）"
for f in "$nlB" "$nl2" "$nl1" "$nlM"; do echo "   MD5 $f = $(md5sum "$f" | cut -d' ' -f1)"; done

echo "---- [1] 向量 + 黄金（冻结 multipass_ref）+ 两条负对照的**预测值** ----"
rm -rf "$outdir"; mkdir -p "$outdir"
# 真表 dw 形状 {4,10,16,32,64} + 单块基准 8（六个形状；C=10/32/64 覆盖多块与尾块）
SHAPES="8 16 32 64 4 10"
TOTAL_BAD=0; NEG_NOFIRE=0; SHAPE_LIST=""
for C in $SHAPES; do
  d="$outdir/shape_${C}c"
  if ! "$PY" - "$C" "$d" "$ref" "$SEED" > "$work/ref_$C.out" 2>&1 <<'PYEOF'
import sys, os, importlib.util
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
import numpy as np
C = int(sys.argv[1]); d = sys.argv[2]; tool = sys.argv[3]; seed = int(sys.argv[4])
spec = importlib.util.spec_from_file_location("multipass_ref", tool)
M = importlib.util.module_from_spec(spec); spec.loader.exec_module(M)
p, n = M.build_one(C, C, C, seed, d)          # 落 x/w/b/gold + params（冻结工具现跑）
gold = np.array([int(t, 16) for t in open(os.path.join(d, "gold.hex"))], dtype=np.int64)
assert n["d_whole"] == 0 and n["distinct"] > 1, "gold 退化/拆趟!=整层"
U8 = (lambda v: (np.asarray(v, dtype=np.int64) & 0xff))          # 黄金文件是无符号十六进制 token

# ---- 独立复算 acc_full（判据：必须与冻结 conv_tiled 的 acc_full 逐点相等）----
xq, wd, sx, sy, bfloat, biasb = M.make_layer(C, C, C, seed)
wq = wd["q"].astype(np.int64)
tiled, acc_full, parts, Mq = M.T.conv_tiled(xq, wd, sx, sy, 0, 0, bfloat, [1,1,1,1], [1,1], C, M.Z_Y,
                                            dump_passes=True)
H, W = M.H_IMG, M.W_IMG
xpad = np.zeros((C, H + 2, W + 2), dtype=np.int64)
xpad[:, 1:H+1, 1:W+1] = xq[0]
acc_rc = np.zeros((C, H, W), dtype=np.int64)
for c in range(C):
    acc_rc[c] = biasb[c]
    for ky in range(3):
        for kx in range(3):
            acc_rc[c] += wq[c, 0, ky, kx] * xpad[c, ky:ky+H, kx:kx+W]
assert np.array_equal(acc_rc, np.asarray(acc_full, dtype=np.int64)), "复算 acc_full != 冻结 acc_full"
# ---- 模型自检：本文件的 acc 模型 + requant 必须逐字节复现冻结黄金（否则负对照的预测不可信）----
assert np.array_equal(U8(M.qref.requant_int(acc_full, Mq, M.Z_Y)).reshape(-1), gold), \
       "模型自检失败：requant(acc_full) != 冻结黄金"

# ---- 预测 1：第 9 抽头（ky,kx)=(2,2) 被切除（瓦片 mem[r*72+r*9+8] 置 0）----
acc_no8 = acc_full.copy()
for c in range(C):
    acc_no8[c] -= wq[c, 0, 2, 2] * xpad[c, 2:2+H, 2:2+W]
gold_no8 = U8(M.qref.requant_int(acc_no8, Mq, M.Z_Y)).reshape(-1)
n_no8 = int(np.count_nonzero(gold_no8 != gold))

# ---- 预测 2：路由突变（MUTX=5：lane 5 的 x 由 (ky=1,kx=2) 改成 (ky=1,kx=0)）----
acc_mut = acc_full.copy()
for c in range(C):
    acc_mut[c] += wq[c, 0, 1, 2] * (xpad[c, 1:1+H, 0:0+W] - xpad[c, 1:1+H, 2:2+W])
gold_mut = U8(M.qref.requant_int(acc_mut, Mq, M.Z_Y)).reshape(-1)
n_mut = int(np.count_nonzero(gold_mut != gold))

# ---- 负对照用的瓦片文件：把对角 entry 的第 9 抽头置 0（其余逐字节不变）----
NENT = 8 * 8 * 9
toks = [int(t, 16) for t in open(os.path.join(d, "w.hex"))]
NB = (C + 7) // 8
for b in range(NB):
    base = (b * NB + b) * NENT
    for r in range(8):
        toks[base + r * 72 + r * 9 + 8] = 0
with open(os.path.join(d, "w_no8.hex"), "w", encoding="ascii", newline="\n") as f:
    f.write("".join("%02x\n" % (t & 0xff) for t in toks))
n_diff_no8 = int(np.count_nonzero(np.array(toks) != np.array([int(t,16) for t in open(os.path.join(d,"w.hex"))])))
print("MODEL_OK C=%d: acc 模型与 requant 逐字节复现冻结黄金（负对照预测的前提）" % C)
print("PRED C=%d NEG_NO8=%d NEG_MUT5=%d WDIFF_NO8=%d distinct=%d gold_md5=%s"
      % (C, n_no8, n_mut, n_diff_no8, n["distinct"], n["md5"]))
ok = (n_no8 > 0) and (n_mut > 0) and (n_diff_no8 > 0) and (n_diff_no8 <= NB * 8)
sys.exit(0 if ok else 1)
PYEOF
  then
    echo "FATAL: 向量/预测失败（C=$C）"; tail -8 "$work/ref_$C.out"; echo "RESULT: FAIL"; exit 3
  fi
  grep '^PRED ' "$work/ref_$C.out" | sed 's/^/    /'
  SHAPE_LIST="$SHAPE_LIST C$C"
done

# 取出每个形状的预测值（供断言）
pred() { # pred <C> <KEY>
  grep '^PRED ' "$work/ref_$1.out" | tr ' ' '\n' | grep "^$2=" | cut -d= -f2
}

echo "---- [1b] 编译（一份 TB，四份探针网表各编一份；BEFORE 需要 -DMODE0）----"
if ! "$IVERILOG" -g2012 -DMODE0 -o "$work/before.vvp" "$tb" "$nlB" > "$work/iv_b.log" 2>&1; then
  echo "JUDGE-RED: BEFORE 编译失败"; sed -n '1,20p' "$work/iv_b.log"; echo "RESULT: FAIL"; exit 1; fi
if ! "$IVERILOG" -g2012 -o "$work/after2.vvp" "$tb" "$nl2" > "$work/iv_2.log" 2>&1; then
  echo "JUDGE-RED: AFTER2 编译失败"; sed -n '1,20p' "$work/iv_2.log"; echo "RESULT: FAIL"; exit 1; fi
if ! "$IVERILOG" -g2012 -o "$work/after1.vvp" "$tb" "$nl1" > "$work/iv_1.log" 2>&1; then
  echo "JUDGE-RED: AFTER1 编译失败"; sed -n '1,20p' "$work/iv_1.log"; echo "RESULT: FAIL"; exit 1; fi
if ! "$IVERILOG" -g2012 -o "$work/mut5.vvp" "$tb" "$nlM" > "$work/iv_m.log" 2>&1; then
  echo "JUDGE-RED: MUT5 编译失败"; sed -n '1,20p' "$work/iv_m.log"; echo "RESULT: FAIL"; exit 1; fi
echo "    四份都编译 OK"
if [ -f tools/check_dangling.py ]; then
  for f in "$nlB" "$nl2" "$nl1" "$nlM"; do
    "$PY" tools/check_dangling.py "$f" >/dev/null || { echo "JUDGE-RED: $f 有悬空实例"; echo "RESULT: FAIL"; exit 1; }
  done
  echo "    check_dangling: 四份网表 0 悬空"
fi

# run_tb <vvp> <tag> <dir> <wfile>
run_tb() {
  local vvp="$1" tag="$2" d="$3" wf="$4"
  local CIN COUT H IW M ZY
  CIN="$(sed -n 's/^CIN=//p' "$d/params.txt")"
  COUT="$(sed -n 's/^COUT=//p' "$d/params.txt")"
  H="$(sed -n 's/^H=//p' "$d/params.txt")"
  IW="$(sed -n 's/^IW=//p' "$d/params.txt")"
  M="$(sed -n 's/^M=//p' "$d/params.txt")"
  ZY="$(sed -n 's/^ZY=//p' "$d/params.txt")"
  ( cd "$work" && "$VVP" "$vvp" \
      "+XFILE=$PWD_ABS/$d/x.hex" "+WFILE=$wf" "+BFILE=$PWD_ABS/$d/b.hex" \
      "+CIN=$CIN" "+COUT=$COUT" "+H=$H" "+IW=$IW" "+M=$M" "+ZY=$ZY" ) \
      > "$work/$tag.log" 2>&1
  grep -E '^DWLANE ' "$work/$tag.log" | sed "s/^/    /"
  grep '^Y ' "$work/$tag.log" | sed -e 's/^Y *//' | tr -s ' ' '\n' > "$work/$tag.y" || true
}

echo "---- [1c]+[2] 六个形状：三档正对照（逐字节）+ 拍数（实测 vs 预测）----"
for C in $SHAPES; do
  d="$outdir/shape_${C}c"
  NPIX="$(sed -n 's/^H=//p' "$d/params.txt")"; IW="$(sed -n 's/^IW=//p' "$d/params.txt")"
  NPIX=$(( NPIX * IW )); NB=$(( (C + 7) / 8 ))
  B9=$(( 9 * NB * NPIX )); B2=$(( 2 * NB * NPIX )); B1=$(( 1 * NB * NPIX ))
  bg() { grep -oE "BEATS=[0-9]+" "$work/$1.log" | head -1 | cut -d= -f2; }
  for v in before after2 after1; do
    case "$v" in before) vvp="$work/before.vvp";; after2) vvp="$work/after2.vvp";; after1) vvp="$work/after1.vvp";; esac
    run_tb "$vvp" "${v}_C${C}" "$d" "$PWD_ABS/$d/w.hex" >/dev/null
    if ! grep -q '^RESULT: PASS' "$work/${v}_C${C}.log"; then
      echo "JUDGE-RED: $v C=$C 没有跑完"; tail -6 "$work/${v}_C${C}.log"; TOTAL_BAD=$((TOTAL_BAD+1)); continue
    fi
    MIS="$(cnt "$d/gold.hex" "$work/${v}_C${C}.y")"
    [ "$MIS" = "0" ] || { echo "JUDGE-RED: $v C=$C MISMATCH=$MIS（对黄金）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
    BT="$(bg "${v}_C${C}")"
    case "$v" in before) BP=$B9;; after2) BP=$B2;; after1) BP=$B1;; esac
    [ "$BT" = "$BP" ] || { echo "JUDGE-RED: $v C=$C BEATS=$BT != 预测 $BP"; TOTAL_BAD=$((TOTAL_BAD+1)); }
    echo "SHAPE C=$C $v MISMATCH=$MIS BEATS=$BT(预测 $BP) MODEID=$(grep -oE 'MODEID=[0-9]+' "$work/${v}_C${C}.log" | head -1 | cut -d= -f2)"
  done
  # [5] 三档 Y 逐字节相同
  S12="$(cnt "$work/before_C${C}.y" "$work/after2_C${C}.y")"
  S13="$(cnt "$work/before_C${C}.y" "$work/after1_C${C}.y")"
  [ "$S12" = "0" ] && [ "$S13" = "0" ] || { echo "JUDGE-RED: C=$C 三档 Y 不一致（before-vs-after2=$S12, before-vs-after1=$S13）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  echo "CONSIST C=$C before==after2==after1: $S12/$S13"

  # ---- [3] 负对照 A：第 9 抽头切除（三档都必须按预测量发火）----
  PN="$(pred "$C" NEG_NO8)"
  for v in before after2 after1; do
    case "$v" in before) vvp="$work/before.vvp";; after2) vvp="$work/after2.vvp";; after1) vvp="$work/after1.vvp";; esac
    run_tb "$vvp" "${v}_no8_C${C}" "$d" "$PWD_ABS/$d/w_no8.hex" >/dev/null
    MIS="$(cnt "$d/gold.hex" "$work/${v}_no8_C${C}.y")"
    if [ "$MIS" != "$PN" ]; then
      echo "NEGCTL-FAIL: 负对照 A（tap8 切除）$v C=$C MISMATCH=$MIS != 预测 $PN"; NEG_NOFIRE=$((NEG_NOFIRE+1))
    else
      echo "NEGCTL-A C=$C $v MISMATCH=$MIS == 预测（发火）"
    fi
  done
  # ---- [4] 负对照 B：路由突变（MUTX=5）----
  PM="$(pred "$C" NEG_MUT5)"
  run_tb "$work/mut5.vvp" "mut5_C${C}" "$d" "$PWD_ABS/$d/w.hex" >/dev/null
  MIS="$(cnt "$d/gold.hex" "$work/mut5_C${C}.y")"
  if [ "$MIS" != "$PM" ]; then
    echo "NEGCTL-FAIL: 负对照 B（路由突变）C=$C MISMATCH=$MIS != 预测 $PM"; NEG_NOFIRE=$((NEG_NOFIRE+1))
  else
    echo "NEGCTL-B C=$C mut5 MISMATCH=$MIS == 预测（发火）"
  fi
done

echo "=========================================================================="
echo "shapes =$SHAPE_LIST（真表 dw 形状 {4,10,16,32,64} + 单块基准 8）"
echo "正对照   = 三档各自 == 冻结黄金（MISMATCH=0）；三档 Y 逐字节互等"
echo "拍数实测 = BEFORE 9 拍/像素/趟；AFTER2 2 拍（4.50×）；AFTER1 1 拍（9.00×）"
echo "负对照 A = 第 9 抽头切除 ⇒ 三档 MISMATCH 恰 == 预测（>0）"
echo "负对照 B = lane 5 路由改错 ⇒ MISMATCH 恰 == 预测（>0）；正规网表 == 0"
if [ "$NEG_NOFIRE" -ne 0 ]; then echo "NEGCTL-FAIL: $NEG_NOFIRE 条负对照没按预测发火"; echo "RESULT: FAIL"; exit 2; fi
if [ "$TOTAL_BAD" -ne 0 ]; then echo "JUDGE-RED: $TOTAL_BAD 条判据红"; echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
exit 0
