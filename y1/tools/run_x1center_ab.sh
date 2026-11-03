#!/usr/bin/env bash
# run_x1center_ab.sh —— ★★ S4-C：1×1 **居中采样**（one_x1 把槽 0 采在窗口中心）的专用闸门。
#
# 背景（为什么需要本闸门）：`Conv3x3Slice` 的 1×1 跳拍（X1SKIP）过去只发 tap 0，而 tap 0 是窗口
#   **左上** (y-1,x-1)；ONNX / `quant_ref.conv_vec` 的 1×1 是**居中** (y,x)。于是真表 26 个 1×1
#   单元整体偏移 (-1,-1)（仿 0/1.6M、板 0/6400 的证据见 reports/npu_v2_board_frame.md §15.7）。
#   修法（已在 `rtl/Conv3x3Slice.scala`）：像素起点在 `one_x1` 时 tapKx/tapKy = (1,1)，权重槽仍 tapK=0
#   ⇒ blob 布局一字不变；3×3 路径（one_x1=0）逐字不变。
#
# 被测：`gen/UnitExec_tiled.v`（TILING=true，X1SKIP 只在 TILING 档存在；= 板级同参档）
#   装置：`rtl_test/UnitExecWideTb.v`（`-DUE_CGEOM -DUE_X1OBS`）+ `rtl_test/AxiMemModel.v`。
#
# 判据（全部按预测量断言，不看"像不像"）：
#   1) **正对照（承重）**：16→16 / 8×8、真 1×1 权重（DUT blob 放槽 0）、TYPE=2
#      ⇒ DST 逐字节 == `quant_ref.conv_vec` 的**真 1×1 核**（KH=KW=1、pads=0）黄金,
#      `MISMATCH == 0`；同一黄金亦 == `tiling_ref.conv_tiled`（真 1×1 核）⇒ 两条独立参考互证；
#      `X1_BEATS == 1·P·(tTh+1)·tOutPerRow`（跳拍仍是 1 拍/像素/趟）。
#   2) **3×3 路径不变**：同一 blob/几何，TYPE=1 ⇒ DST 逐字节 == **旧的左上口径**黄金
#      （3×3 核、槽 0 在 (0,0)、pads=1）且 `X1_BEATS == 9·P·(tTh+1)·tOutPerRow`
#      ⇒ 修复只动了 one_x1 分支，9 抽头路径一字未动。
#   3) **负对照（必发火）**：同一 DUT dump 对**旧左上口径**黄金 ⇒ `MISMATCH == PRED`
#      （PRED = #(centered_gold ≠ shifted_gold)，python 现算）且 `PRED > 0`。
#   4) **网表突变（外科锚）**：把 `_zz_one_x1 <= (desc_0[7:0] == 8'h02)` 掐成 `1'b0`
#      ⇒ 同一作业的 DUT dump **逐字节 == 旧左上口径黄金**（0/PRED 的翻面）—— 说明红↔绿由
#      "TYPE=2 的居中采样"这一条逻辑决定，且突变后精确复现修复前的行为。
#
# 退出码：0 = 全过 / 1 = 判据红 / 2 = 负对照/突变没发火（或锚不唯一）/ 3 = 前置缺失。
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

tb="rtl_test/UnitExecWideTb.v"
memv="rtl_test/AxiMemModel.v"
nl="gen/UnitExec_tiled.v"
ref="tools/tiling_ref.py"
qref="tools/quant_ref.py"
MEMSZ=2621440
SRC=131072            # 0x20000：tiled 档激活平面（NCHW）
DST=2097152           # 0x200000：输出区
CIN=16; COUT=16; HH=8; WW=8; SEED=20261017
PASSES=4
TI_PIX=$(( (HH + 1) * (WW + 2) ))     # tiled：每趟出 (tTh+1)*tOutPerRow 像素
TI_B9=$(( 9 * PASSES * TI_PIX )); TI_B1=$(( PASSES * TI_PIX ))

find_tool() {
  local n="$1" p d
  p="$(command -v "$n" 2>/dev/null || true)"
  if [ -z "$p" ]; then for d in /c/msys64/ucrt64/bin /mingw64/bin /usr/bin; do [ -x "$d/$n" ] && { p="$d/$n"; break; }; done; fi
  printf '%s' "$p"
}
IVERILOG="$(find_tool iverilog)"; VVP="$(find_tool vvp)"

echo "== run_x1center_ab: 1×1 居中采样（TYPE=2 ⇒ 槽 0 采在窗口中心）=="
echo "   nl=$nl  py=$PY  iverilog=${IVERILOG:-<none>}"
echo "   预测拍数：TYPE=1: $TI_B9  TYPE=2: $TI_B1（tiled；P=$PASSES, TI_PIX=$TI_PIX）"

for f in "$nl" "$tb" "$memv" "$ref" "$qref"; do
  [ -f "$f" ] || { echo "FATAL: 缺 $f"; echo "RESULT: FAIL"; exit 3; }
done
[ -n "$IVERILOG" ] && [ -n "$VVP" ] || { echo "FATAL: 缺 iverilog/vvp"; echo "RESULT: FAIL"; exit 3; }

work="$(mktemp -d)"
cleanup() { [ "${KEEP_TMP:-0}" = "1" ] && echo "KEEP_TMP=1 => $work" || rm -rf "$work"; }
trap cleanup EXIT
export PYTHONPATH="./.pydeps;../third_party/yunet/deps"
export PYTHONIOENCODING=utf-8

TOTAL_BAD=0; NEG_NOFIRE=0
judge() {  # judge <dump> <gold.hex> <len> <base> -> MISMATCH=...
  "$PY" - "$1" "$2" "$3" "$4" <<'PYEOF'
import sys
d = [int(x, 16) for x in open(sys.argv[1], encoding="utf-8").read().split()]
g = [int(x, 16) for x in open(sys.argv[2], encoding="utf-8").read().split()]
ln, base = int(sys.argv[3]), int(sys.argv[4])
k = min(ln, len(g), max(0, len(d) - base))
print("MISMATCH=%d" % (sum(1 for i in range(k) if d[base + i] != g[i]) + max(0, ln - k)))
PYEOF
}

# -----------------------------------------------------------------------------
# 0) 前置：冻结参考自检
# -----------------------------------------------------------------------------
"$PY" "$ref" --selftest2d >/dev/null 2>&1 || { echo "RESULT: FAIL 参考自检没过"; exit 3; }
echo "---- 0) 参考自检 OK（tiling_ref.py --selftest2d）----"

# -----------------------------------------------------------------------------
# 1) 作业生成：真 1×1 居中黄金 + 旧左上黄金 + DUT 槽 0 blob
# -----------------------------------------------------------------------------
cat > "$work/genjob.py" <<'PYEOF'
import sys, os
sys.path.insert(0, sys.argv[1])
import numpy as np
import tiling_ref as T
import quant_ref as Q
import multipass_ref as MP

Z_Y = -7

def dump(path, toks, w=2):
    m = (1 << (4 * w)) - 1
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("".join(("%0" + str(w) + "x\n") % (int(t) & m) for t in toks))

def main():
    tools, work, cin, cout, H, W, seed = sys.argv[1], sys.argv[2], *(int(v) for v in sys.argv[3:8])
    src, dst, memsz = (int(v) for v in sys.argv[8:11])
    rng = np.random.default_rng(seed)
    xq = rng.integers(-20, 21, size=(1, cin, H, W), dtype=np.int64)
    w0 = rng.integers(-20, 21, size=(cout, cin), dtype=np.int64)   # 真 1×1 权重 [co][ci]
    sx = sw = sy = 0.05
    bfloat = rng.uniform(-0.5, 0.5, size=cout)
    biasb = np.round(bfloat / (sx * sw)).astype(np.int64)

    def wd(q): return {"q": q.astype(np.int8), "scale": sw, "zp": 0}
    # 真 1×1（ONNX/quant_ref 口径）：KH=KW=1、pad=0
    q11 = np.ascontiguousarray(w0).reshape(cout, cin, 1, 1)
    gold_c = Q.conv_vec(xq, wd(q11), sx, sy, 0, 0, bfloat, [0, 0, 0, 0], [1, 1], 1, Z_Y)
    gc2, _, _, M = T.conv_tiled(xq, wd(q11), sx, sy, 0, 0, bfloat, [0, 0, 0, 0], [1, 1], 1, Z_Y,
                                dump_passes=True)
    assert np.array_equal(gc2, gold_c), "两条独立参考对真 1x1 不一致"
    gold_center = gold_c.reshape(-1).astype(np.int8)
    # 旧口径（修复前 as-built）：3×3 核、槽 0 在 (0,0)、pads=1 ⇒ 采 (y-1,x-1)
    q3 = np.zeros((cout, cin, 3, 3), dtype=np.int64); q3[:, :, 0, 0] = w0
    gs, _, _, Ms = T.conv_tiled(xq, wd(q3), sx, sy, 0, 0, bfloat, [1, 1, 1, 1], [1, 1], 1, Z_Y,
                                dump_passes=True)
    assert np.array_equal(gs, Q.conv_vec(xq, wd(q3), sx, sy, 0, 0, bfloat, [1, 1, 1, 1], [1, 1], 1, Z_Y)), \
        "旧口径两条参考不一致"
    gold_shift = gs.reshape(-1).astype(np.int8)
    pred_neg = int(np.count_nonzero(gold_center != gold_shift))
    assert int(M) == int(Ms), "两种口径的乘子不同"
    assert pred_neg > 0, "居中/左上两份黄金相同 ⇒ 负对照没牙（用例退化）"

    n_ci, n_co = T.n_passes(cin), T.n_passes(cout)
    assert n_ci * 8 == cin and n_co * 8 == cout
    # DUT 9 槽 blob：真 1×1 权重放**槽 0**（真表布局；修后的 RTL 在 one_x1 时把它采在中心）
    tiles = MP.weight_tiles(xq, wd(q3), 1)
    btoks = []
    for j in range(n_co):
        btoks += [int(v) for v in MP.bias_of(biasb, j)]

    d = os.path.join(work, "job")
    os.makedirs(d, exist_ok=True)
    dump(os.path.join(d, "w.hex"), np.concatenate([t.reshape(-1) for t in tiles]))
    dump(os.path.join(d, "b.hex"), btoks, w=8)
    dump(os.path.join(d, "x.hex"), np.zeros(8, dtype=np.int64))   # 占位（tiled 不喂列流）
    dump(os.path.join(d, "gold_center.hex"), gold_center)
    dump(os.path.join(d, "gold_shift.hex"), gold_shift)
    pre = np.array([((i % 251) * 131 + 7) % 251 for i in range(memsz)], dtype=np.int64)
    assert int(np.count_nonzero(pre[dst:dst + len(gold_center)] != gold_center)) >= int(0.9 * len(gold_center)), \
        "DST 预载与黄金过近"
    mem = pre.copy(); mem[src:src + xq[0].size] = xq[0].reshape(-1)
    dump(os.path.join(d, "mem.hex"), mem)
    with open(os.path.join(d, "job.txt"), "w", encoding="ascii", newline="\n") as f:
        f.write("CIN=%d\nCOUT=%d\nGROUP=1\nH=%d\nW=%d\n" % (cin, cout, H, W))
        f.write("SRC=%d\nDST=%d\nM=%d\nZPAD=0\nZY=%d\nNCI=%d\nNCO=%d\n"
                % (src, dst, int(M), Z_Y, n_ci, n_co))
        f.write("NCOL=1\nLEN=%d\nPRED_NEG=%d\n" % (len(gold_center), pred_neg))
    print("JOBGEN CIN=%d COUT=%d %dx%d n_ci=%d n_co=%d M=%d pred_neg=%d len=%d"
          % (cin, cout, H, W, n_ci, n_co, int(M), pred_neg, len(gold_center)))

main()
PYEOF

"$PY" "$work/genjob.py" "$(pwd)/tools" "$work" "$CIN" "$COUT" "$HH" "$WW" "$SEED" "$SRC" "$DST" "$MEMSZ" \
  > "$work/genjob.out" 2>&1 || { echo "RESULT: FAIL 供料失败"; tail -12 "$work/genjob.out"; exit 3; }
grep -E '^JOBGEN' "$work/genjob.out" | sed 's/^/    /'
eval "$(sed 's/^/X_/' "$work/job/job.txt" | tr '\n' ' ')"

# -----------------------------------------------------------------------------
# 2) iverilog 编译（产品网表）
# -----------------------------------------------------------------------------
echo "---- 2) iverilog 编译（UnitExecWideTb + AxiMemModel + gen/UnitExec_tiled.v；-DUE_CGEOM -DUE_X1OBS）----"
if ! "$IVERILOG" -g2012 -DUE_CGEOM -DUE_X1OBS -o "$work/sim.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败"; sed -n '1,30p' "$work/iv.log"; echo "RESULT: FAIL"; exit 1
fi
echo "   编译 OK"

run_tb() {  # run_tb <vvp> <tag> <TYPE>
  ( cd "$work" && "$VVP" "$1" \
      "+XFILE=$work/job/x.hex" "+WFILE=$work/job/w.hex" "+BFILE=$work/job/b.hex" \
      "+MEMFILE=$work/job/mem.hex" "+DUMPFILE=$work/$2.dump" +dump +TILED_W \
      "+CIN=${X_CIN}" "+COUT=${X_COUT}" "+GROUP=${X_GROUP}" "+H=${X_H}" "+W=${X_W}" \
      "+TYPE=$3" "+FLAGS=1" "+SRC=${X_SRC}" "+DST=${X_DST}" "+INB=${X_LEN}" \
      "+QSHIFT=6" "+LID=0" "+M=${X_M}" "+ZPAD=${X_ZPAD}" "+ZY=${X_ZY}" \
      "+NCOL=${X_NCOL}" "+NCI=${X_NCI}" "+NCO=${X_NCO}" "+TMT=4000000" ) > "$work/$2.log" 2>&1
}
beats_of() { sed -n 's/^X1_BEATS=\([0-9]*\).*/\1/p' "$1" | head -1; }
pass_of()  { grep -q '^RESULT: PASS' "$1" && echo 1 || echo 0; }

# -----------------------------------------------------------------------------
# 3) 正对照：TYPE=2（1×1 跳拍）== 居中黄金
# -----------------------------------------------------------------------------
echo "---- 3) 正对照：TYPE=2（1×1）对 quant_ref 真 1×1 居中黄金 ----"
run_tb "$work/sim.vvp" t2 2
P="$(pass_of "$work/t2.log")"; B="$(beats_of "$work/t2.log")"
MM="$(judge "$work/t2.dump" "$work/job/gold_center.hex" "$X_LEN" "$X_DST" | sed -n 's/^MISMATCH=//p')"
echo "   [TYPE=2] PASS=$P MISMATCH=$MM（应 0）X1_BEATS=$B（预测 $TI_B1）"
[ "$P" = 1 ] || { echo "JUDGE-RED: TYPE=2 装置未 PASS"; sed -n '1,8p' "$work/t2.log"; TOTAL_BAD=$((TOTAL_BAD+1)); }
[ "$MM" = 0 ] || { echo "JUDGE-RED: 1×1 输出 != 居中黄金（MISMATCH=$MM）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
[ "$B" = "$TI_B1" ] || { echo "JUDGE-RED: TYPE=2 X1_BEATS=$B != $TI_B1"; TOTAL_BAD=$((TOTAL_BAD+1)); }

# -----------------------------------------------------------------------------
# 4) 3×3 路径不变：TYPE=1 == 旧左上口径黄金，9× 拍
# -----------------------------------------------------------------------------
echo "---- 4) 3×3 路径不变：TYPE=1 对旧左上口径黄金 ----"
run_tb "$work/sim.vvp" t1 1
P="$(pass_of "$work/t1.log")"; B="$(beats_of "$work/t1.log")"
MM1="$(judge "$work/t1.dump" "$work/job/gold_shift.hex" "$X_LEN" "$X_DST" | sed -n 's/^MISMATCH=//p')"
echo "   [TYPE=1] PASS=$P MISMATCH=$MM1（应 0）X1_BEATS=$B（预测 $TI_B9）"
[ "$P" = 1 ] || { echo "JUDGE-RED: TYPE=1 装置未 PASS"; TOTAL_BAD=$((TOTAL_BAD+1)); }
[ "$MM1" = 0 ] || { echo "JUDGE-RED: 3×3 路径变了（MISMATCH=$MM1）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
[ "$B" = "$TI_B9" ] || { echo "JUDGE-RED: TYPE=1 X1_BEATS=$B != $TI_B9"; TOTAL_BAD=$((TOTAL_BAD+1)); }

# -----------------------------------------------------------------------------
# 5) 负对照：同一 DUT dump 对旧左上黄金 ⇒ 必按预测量发火
# -----------------------------------------------------------------------------
echo "---- 5) 负对照：同一 TYPE=2 dump 对旧左上口径黄金（必发火）----"
PRED="$X_PRED_NEG"
echo "   预测量 PRED=$PRED（= #(居中黄金 ≠ 左上黄金)）"
MMN="$(judge "$work/t2.dump" "$work/job/gold_shift.hex" "$X_LEN" "$X_DST" | sed -n 's/^MISMATCH=//p')"
echo "   [NEG TYPE=2 vs 旧口径] MISMATCH=$MMN（预测 $PRED）"
[ "$MMN" = "$PRED" ] || { echo "JUDGE-RED: 负对照未按预测量发火（MM=$MMN != $PRED）"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }
[ "${MMN:-0}" != 0 ] || { echo "NEGCTL-FAIL: 负对照没发火（MISMATCH=0）"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }

# -----------------------------------------------------------------------------
# 6) 网表突变（外科锚）：掐掉 TYPE=2 译码 ⇒ 精确复现修复前的左上行为
# -----------------------------------------------------------------------------
echo "---- 6) 网表突变：_zz_one_x1 <= ... 掐成 1'b0（TYPE=2 译码拆掉）----"
"$PY" - "$nl" "$work/nl_mut.v" <<'PYEOF' || { echo "NEGCTL-FAIL: 突变锚不唯一"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }
import sys
src, out = sys.argv[1], sys.argv[2]
data = open(src, "rb").read().decode("utf-8")
lines = data.split("\n"); hit = 0
for i, l in enumerate(lines):
    if ("_zz_one_x1 <=" in l) and ("desc_0[7 : 0]" in l):
        lines[i] = "      _zz_one_x1 <= 1'b0;   // X1CENTER-MUT (TYPE=2 decode cut)"
        hit += 1
if hit != 1:
    print("MUTATE-FAIL hits=%d (anchor not unique)" % hit); sys.exit(1)
with open(out, "w", encoding="utf-8", newline="") as f:
    f.write("\n".join(lines))
print("   MUTATE: 1 site (anchor unique)")
PYEOF
if [ -f "$work/nl_mut.v" ]; then
  "$IVERILOG" -g2012 -DUE_CGEOM -DUE_X1OBS -o "$work/mut.vvp" "$tb" "$memv" "$work/nl_mut.v" > "$work/iv_mut.log" 2>&1 \
    || { echo "RESULT: FAIL 突变网表编译失败"; sed -n '1,10p' "$work/iv_mut.log"; exit 1; }
  run_tb "$work/mut.vvp" mut 2
  PM="$(pass_of "$work/mut.log")"; BM="$(beats_of "$work/mut.log")"
  MMS="$(judge "$work/mut.dump" "$work/job/gold_shift.hex" "$X_LEN" "$X_DST" | sed -n 's/^MISMATCH=//p')"
  MMC="$(judge "$work/mut.dump" "$work/job/gold_center.hex" "$X_LEN" "$X_DST" | sed -n 's/^MISMATCH=//p')"
  echo "   [MUT TYPE=2] PASS=$PM vs 旧左上 MISMATCH=$MMS（应 0） vs 居中 MISMATCH=$MMC（应 $PRED） X1_BEATS=$BM（应回到 $TI_B9）"
  [ "$PM" = 1 ] || { echo "JUDGE-RED: 突变网表装置未 PASS"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$MMS" = 0 ] || { echo "JUDGE-RED: 突变后未精确复现修复前行为（vs 旧口径 MM=$MMS）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$MMC" = "$PRED" ] || { echo "JUDGE-RED: 突变后 vs 居中 MM=$MMC != $PRED"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$BM" = "$TI_B9" ] || { echo "NEGCTL-FAIL: 突变后拍数 $BM != $TI_B9 ⇒ 跳拍没被拆掉"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }
fi

# -----------------------------------------------------------------------------
# 7) 收口
# -----------------------------------------------------------------------------
echo "=========================================================================="
if [ "$TOTAL_BAD" != 0 ]; then echo "RESULT: FAIL（判据红 $TOTAL_BAD 条）"; exit 1; fi
if [ "$NEG_NOFIRE" != 0 ]; then echo "RESULT: FAIL（负对照/突变没发火 $NEG_NOFIRE 条）"; exit 2; fi
echo "RESULT: PASS"
echo "  1×1 居中：TYPE=2 == quant_ref 真 1×1（0/$X_LEN）；旧左上口径差 $PRED/$X_LEN（负对照发火）"
echo "  3×3 路径：TYPE=1 仍 == 旧左上口径（0/$X_LEN，$TI_B9 拍 = 9×）"
echo "  网表突变：TYPE=2 译码掐掉 ⇒ 逐字节复现修复前左上行为（0/$PRED 的翻面）"
exit 0
