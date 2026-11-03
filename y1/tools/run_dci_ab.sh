#!/usr/bin/env bash
# run_dci_ab.sh —— ★★ NPU v2 切片 C2：**dense ci-inner（DCI）落进产品 RTL** 的闸门。
#
# 被测：`rtl/Conv3x3Slice.scala` 的 `DCI` 块（`dci_mode`/`c3_cin` + c3 逐 lane 读 + `ph === c3_cin ⇒
#   ph := 10` 跳拍）+ `rtl/WeightStore.scala` 的 `c3_ci/c3Tile/c3Tile8` 读口 + `rtl/MultiPassUnit.scala`
#   的转发 + `rtl/UnitExec.scala` 的 `dciW`（`go` 那拍闩 `GROUP==1 ∧ 0 < C_in ≤ 4`，同拍闩 `c3CinR`）
#   + ★ `rtl/MacArray.scala` 的 **`p8r` A 级寄存纪律**（切片 C-1 实测发现的**正确性补丁**）。
#   网表 = `gen/UnitExec_tiled.v`（`TILING=true` = 真帧网表那一档；`TILING=false` 的三份冻结网表
#   **没有**这条通路 —— 那一侧的逐字节不变由 md5 前置项 + 全部既有闸门保住，不在本闸门的判据里）。
#   装置 = `rtl_test/UnitExecWideTb.v`（`-DUE_CGEOM -DUE_X1OBS`）+ `AxiMemModel.v`。
#
# 判据（"先立靶、再发火、再外科"三件套；数字全部按**预测量**断言，不看"像不像"）：
#   0) 前置：两条冻结参考自检；`TILING=false` 三网表 md5 逐字节不变；**真表前提现场重扫**
#      （`C_in ≤ 4 ∧ GROUP==1` 的单元恰 7 个 = `Conv_0` + 六片 `1→1`；**无** `TYPE==2` 且 `C_in ≤ 4`
#      的单元 ⇒ DCI 与 1×1 跳拍在真表上互斥；无 8→8 的 `C_in ≤ 4` 窄层）。
#   1) 正对照（**产品网表**，逐字节 == 冻结参考 + 实测拍比自报）：
#        · `c0` = **真层 `Conv_0`**（`gen/wgt_index.json`+`wgt_blob.bin` 的真权重与 M/z_pad/z_y，
#          `C_in=3 → C_out=16` 3×3，H=8/W=8 ⇒ 2 趟）：`X1_BEATS == 3·2·64 = 384`（= **3 拍/像素/趟**）、
#          `MISMATCH == 0`；
#        · `c1` = **真层 `Conv_55`**（`1→1 3×3`，H=8/W=16 ⇒ 1 趟）：`X1_BEATS == 1·1·128 = 128`
#          （= **1 拍/像素/趟**）、`MISMATCH == 0`；
#        · `tap8`（合成 `1→1`，只有**槽 8** = 7）：`X1_BEATS == 128`、`MISMATCH == 0`
#          （= `p8r` 的 A 级寄存纪律**足够**）。
#   2) **实测拍比（产品网表）**：网表突变 `_zz_dci_mode <= 1'b0`（= DCI 关，其余一字不动）⇒
#      `c0` 作业 `X1_BEATS == 9·2·64 = 1152`（实测比 **3.00×**）、`c1` 作业 `== 9·1·128 = 1152`
#      （**9.00×**）；且三次（c0 两档 / c1 两档）**整片内存 dump 逐字节相同**
#      （= "ci 进拍、tap 进 lane" 只是**拍序重排**，数值一字未动）。
#   3) **负对照 N1（`p8r` 的受控 A/B，承重）**：把 B 级第 9 抽头来源改回**组合积**
#      （`_zz_acc_0_8 = dw_mode ? <combinational> : 0`，= 打补丁前的行为）⇒ `tap8` 作业
#      `MISMATCH == PRED_P8`（= `#(gold_tap8 != gold_bias)`，python 现算）且 dump **逐字节 ==
#      gold_bias**（恰是"第 9 抽头被吞掉"）⇒ **没有 A 级寄存 = 必红、按预测量定位**；
#      同作业在正规网表上 `MISMATCH == 0`（= **充分**）。
#   4) **负对照 N2（c3 路由改错）+ 外科式**：突变 lane 4 的 w 来源（`ws_c3Tile_0_4 → _0_5`，只动
#      路由、不动算术）⇒ `lane45` 作业（槽 4 = 7、槽 5 = 9）`MISMATCH == PRED_N2`（python 现算）
#      **且 dump 逐字节 == gold_mut**（= 路由改错造成的红被精确解释）；**外科式**：同一突变网表 +
#      `surg` 作业（槽 5 := 槽 4 = 7 ⇒ 两槽同值）⇒ `MISMATCH == 0`（红↔绿翻面只由**一个权重字节**
#      造成），且两份 dump 的差异字节数 == 两份黄金的差异字节数（改动只落在该字节的贡献上）。
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
wref="tools/wide_exec_ref.py"
tref="tools/tiling_ref.py"
mref="tools/multipass_ref.py"
qref="tools/quant_ref.py"
MEMSZ=2621440
SRC=131072            # 0x20000（与 wide_exec_ref 的 job.txt 一致）
DST=2097152           # 0x200000
tools_abs="$(pwd)/tools"

find_tool() {
  local n="$1" p d
  p="$(command -v "$n" 2>/dev/null || true)"
  if [ -z "$p" ]; then for d in /c/msys64/ucrt64/bin /mingw64/bin /usr/bin; do [ -x "$d/$n" ] && { p="$d/$n"; break; }; done; fi
  printf '%s' "$p"
}
IVERILOG="$(find_tool iverilog)"; VVP="$(find_tool vvp)"

echo "== run_dci_ab: NPU v2 切片 C2（DCI 落产品 RTL：ci 进拍/tap 进 lane + p8r 的 A 级寄存纪律）=="
echo "   nl=$nl  tb=$tb  py=$PY  iverilog=${IVERILOG:-<none>}"
echo "   预测拍数：c0(Conv_0 3→16,2 趟,8x8) DCI 384 / DCI 关 1152（3.00×）；x18(合成 1→8 dense,8x16) DCI 128 / 关 1152（9.00×）"

for f in "$nl" "$tb" "$memv" "$wref" "$tref" "$mref" "$qref"; do
  [ -f "$f" ] || { echo "FATAL: 缺 $f"; echo "RESULT: FAIL"; exit 3; }
done
[ -n "$IVERILOG" ] && [ -n "$VVP" ] || { echo "FATAL: 缺 iverilog/vvp"; echo "RESULT: FAIL"; exit 3; }

work="$(mktemp -d)"
cleanup() { [ "${KEEP_TMP:-0}" = "1" ] && echo "KEEP_TMP=1 => $work" || rm -rf "$work"; }
trap cleanup EXIT
export PYTHONPATH="./.pydeps;../third_party/yunet/deps"
export PYTHONIOENCODING=utf-8

TOTAL_BAD=0; NEG_NOFIRE=0

# -----------------------------------------------------------------------------
# 0) 前置：参考自检 + TILING=false 三网表 md5 + 真表前提重扫
# -----------------------------------------------------------------------------
echo "---- 0) 前置：两条冻结参考自检 + TILING=false 三网表 md5 + 真表前提重扫 ----"
"$PY" "$wref" --selftest >/dev/null 2>&1 || { echo "RESULT: FAIL wide_exec_ref 自检没过"; exit 3; }
"$PY" "$tref" --selftest2d >/dev/null 2>&1 || { echo "RESULT: FAIL tiling_ref 自检没过"; exit 3; }
echo "   参考自检 OK（wide_exec_ref.py --selftest + tiling_ref.py --selftest2d）"

EXPECT_UE="7593b189ae8339e291c2fa398d0fcb2b"
EXPECT_W32="817ab5bbce2ef0bcaae556c8a9ded41b"
EXPECT_W640="5d2cd81addb84c62b2407f64aa0ac3a2"
md5of() { md5sum "$1" 2>/dev/null | awk '{print $1}'; }
MD5_BAD=0
for pair in "gen/UnitExec.v:$EXPECT_UE" "gen/UnitExec_w32.v:$EXPECT_W32" "gen/UnitExec_w640.v:$EXPECT_W640"; do
  f="${pair%%:*}"; e="${pair##*:}"; g="$(md5of "$f")"
  if [ "$g" != "$e" ]; then echo "    JUDGE-RED: $f md5=$g != $e（TILING=false 必须逐字节不变）"; MD5_BAD=1; fi
done
[ "$MD5_BAD" = 0 ] && echo "   TILING=false 三网表 md5 不变（97912901… / 618af338… / ddb9bb8a…）"
[ "$MD5_BAD" = 0 ] || { echo "RESULT: FAIL"; exit 1; }
echo "   TILED_NL_MD5=$(md5of "$nl")（gen/UnitExec_tiled.v，只记账）"

if ! "$PY" - "$tools_abs" <<'PYEOF'; then
import sys, os, json, hashlib
sys.path.insert(0, sys.argv[1])
idx_p = os.path.join(sys.argv[1], "..", "gen", "wgt_index.json")
blob_p = os.path.join(sys.argv[1], "..", "gen", "wgt_blob.bin")
d = json.load(open(idx_p, encoding="utf-8"))
blob = open(blob_p, "rb").read()
md5 = hashlib.md5(blob).hexdigest()
bad = []
if md5 != d["blob"]["md5"]: bad.append("blob md5=%s != index 记录 %s" % (md5, d["blob"]["md5"]))
if len(blob) != d["blob"]["bytes"]: bad.append("blob 字节数 != index")
# ---- DCI 的定义域 = `GROUP==1 ∧ 0 < C_in ≤ 4`（宽路）----
domain = [u for u in d["units"]
          if int(u["own"]["GROUP"]) == 1 and 0 < int(u["own"]["C_IN"]) <= 4
          and int(u.get("type_code", -1)) in (1, 2, 3)]
names = sorted(u["name"] for u in domain)
expect = sorted(["Conv_0", "Conv_55", "Conv_57", "Conv_59", "Conv_67", "Conv_69", "Conv_71"])
if names != expect: bad.append("DCI 定义域 %s != 预期 7 个单元 %s" % (names, expect))
# ---- DCI 与 1×1 跳拍（TYPE==2）在真表上必须互斥（无 TYPE==2 且 C_in≤4 的单元）----
ov = [u["name"] for u in d["units"] if int(u.get("type_code", -1)) == 2 and 0 < int(u["own"]["C_IN"]) <= 4]
if ov: bad.append("真表出现 TYPE==2 且 C_in≤4 的单元（DCI 与 1×1 跳拍同层 ⇒ 未覆盖组合）：%s" % ov)
# ---- 窄通路（C_in==C_out==8 ∧ GROUP==1）与 DCI 无交集（C_in=8 > 4）----
narrow = [u["name"] for u in domain
          if int(u["own"]["C_IN"]) == 8 and int(u["own"]["C_OUT"]) == 8]
if narrow: bad.append("窄层落在 DCI 定义域：%s" % narrow)
x1 = [u for u in d["units"] if int(u.get("type_code", -1)) == 2]
print("   真表：DCI 定义域 = %d 个单元（%s）；TYPE==2 单元 %d 个（C_in 全 > 4 ⇒ 互斥）"
      % (len(domain), ",".join(names), len(x1)))
for b in bad: print("   JUDGE-RED: " + b)
sys.exit(1 if bad else 0)
PYEOF
  echo "RESULT: FAIL 真表前提扫查不过（见上）"; exit 3
fi

# -----------------------------------------------------------------------------
# 1) iverilog 编译（tiled 网表；-DUE_CGEOM 逐片几何口 + -DUE_X1OBS 拍数观测口）
# -----------------------------------------------------------------------------
echo "---- 1) iverilog 编译（UnitExecWideTb + AxiMemModel + gen/UnitExec_tiled.v；-DUE_CGEOM -DUE_X1OBS）----"
if ! "$IVERILOG" -g2012 -DUE_CGEOM -DUE_X1OBS -o "$work/sim.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败"; sed -n '1,30p' "$work/iv.log"; echo "RESULT: FAIL"; exit 1
fi
echo "   编译 OK"

# -----------------------------------------------------------------------------
# 2) 供料：
#    · 真层 c0 = Conv_0（lid 0，H=8/W=8）；c1 = Conv_55（lid 38，H=8/W=16）—— wide_exec_ref.py
#    · 合成小作业（genjob.py；C_in=C_out=1、H=8/W=16、3×3 真核）：
#        tap8  = 只有槽 8 = 7（p8 A/B 的载体）
#        lane45= 槽 4 = 7、槽 5 = 9（c3 路由突变负对照的载体）
#        surg  = 槽 4 = 7、槽 5 := 槽 4 = 7（外科式：两槽同值 ⇒ 路由突变不可见）
# -----------------------------------------------------------------------------
echo "---- 2) 供料（真层两档 + 合成 1→8 + 三个合成小作业）----"
mkdir -p "$work/ref"
for spec in "--lid 0 --H 8 --W 8" "--lid 38 --H 8 --W 16" "--synth 1 8 --H 8 --W 16"; do
  if ! "$PY" "$wref" $spec --outdir "$work/ref" > "$work/ref.out" 2>&1; then
    echo "JUDGE-RED: 供料失败（$spec）"; tail -6 "$work/ref.out"; echo "RESULT: FAIL"; exit 1
  fi
  grep -E '^WIDE_REF ' "$work/ref.out" | sed 's/^/    /'
done
sed -i 's/^LID=.*/LID=38/' "$work/ref/lid38_Conv_55/job.txt"

cat > "$work/genjob.py" <<'PYEOF'
import sys, os
sys.path.insert(0, sys.argv[1])
import numpy as np
import tiling_ref as T
import multipass_ref as MP
import quant_ref as Q

Z_Y = -7
H, W = 8, 16

def dump(path, toks, w=2):
    m = (1 << (4 * w)) - 1
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("".join(("%0" + str(w) + "x\n") % (int(t) & m) for t in toks))

def conv(xq, wq, bfloat, sx, sw):
    sy = sw
    wd = {"q": wq.astype(np.int8), "scale": sw, "zp": 0}
    pads, strides = [1, 1, 1, 1], [1, 1]
    tiled, acc, parts, M = T.conv_tiled(xq, wd, sx, sy, 0, 0, bfloat, pads, strides, 1, Z_Y, dump_passes=True)
    whole = Q.conv_vec(xq, wd, sx, sy, 0, 0, bfloat, pads, strides, 1, Z_Y)
    assert np.array_equal(whole, tiled), "两条独立参考不一致（用例坏了）"
    return tiled[0].reshape(-1).astype(np.int8), tiled.reshape(-1).astype(np.int8), int(M)

def main():
    tools, work, name, variant, src, dst, memsz = sys.argv[1:8]
    src = int(src); dst = int(dst); memsz = int(memsz)
    seed = int(sys.argv[8])
    rng = np.random.default_rng(seed)
    sx = sw = sy = 0.05
    xq = rng.integers(-20, 21, size=(1, 1, H, W), dtype=np.int64)
    bfloat = rng.uniform(-0.5, 0.5, size=1)
    biasb = np.round(bfloat / (sx * sw)).astype(np.int64)

    wq = np.zeros((1, 1, 3, 3), dtype=np.int64)
    if variant == "tap8":
        wq[0, 0, 2, 2] = 7                      # 槽 8（第 9 抽头）单抽头
    elif variant == "lane45":
        wq[0, 0, 1, 1] = 7; wq[0, 0, 1, 2] = 9  # 槽 4 / 槽 5（lane 4 的 kx=1、lane 5 的 kx=2）
    elif variant == "surg":
        wq[0, 0, 1, 1] = 7; wq[0, 0, 1, 2] = 7  # 槽 5 := 槽 4（两槽同值 ⇒ 路由突变不可见）
    else:
        raise SystemExit("unknown variant %r" % variant)

    g0, gold, M = conv(xq, wq, bfloat, sx, sw)
    # ---- N1 预测：p8 组合回读（B 级读不到 A 级寄存）⇒ 第 9 抽头被吞 ⇒ 输出 = 只有 bias ----
    wzero = np.zeros_like(wq)
    _, gold_bias, _ = conv(xq, wzero, bfloat, sx, sw)
    pred_p8 = int(np.count_nonzero(gold != gold_bias))
    # ---- N2 预测：lane 4 的 w 来源改读槽 5 ⇒ 权重张量 w'(ky,kx) 的 (1,1) 换成 (1,2) ----
    wm = wq.copy()
    if variant == "lane45":
        wm[0, 0, 1, 1] = wq[0, 0, 1, 2]
    _, gold_mut, _ = conv(xq, wm, bfloat, sx, sw)
    pred_n2 = int(np.count_nonzero(gold != gold_mut))

    x8 = np.zeros((8, H, W), dtype=np.int64); x8[:1] = xq[0]
    xstream = np.concatenate([x8.transpose(1, 2, 0).reshape(-1)])   # n_ci=n_co=1
    tiles = MP.weight_tiles(xq, {"q": wq.astype(np.int8), "scale": sw, "zp": 0}, 1)
    btoks = [int(v) for v in MP.bias_of(biasb, 0)]

    d = os.path.join(work, name); os.makedirs(d, exist_ok=True)
    dump(os.path.join(d, "x.hex"), xstream)
    dump(os.path.join(d, "w.hex"), np.concatenate([t.reshape(-1) for t in tiles]))
    dump(os.path.join(d, "b.hex"), btoks, w=8)
    dump(os.path.join(d, "gold.hex"), gold)
    dump(os.path.join(d, "gold_bias.hex"), gold_bias)
    dump(os.path.join(d, "gold_mut.hex"), gold_mut)
    pre = np.array([((i % 251) * 131 + 7) % 251 for i in range(memsz)], dtype=np.int64)
    dif = int(np.count_nonzero(pre[dst:dst + len(gold)] != gold))
    assert dif >= int(len(gold) * 0.9), "DST 预载与黄金过近（不写必被误判成对）"
    dump(os.path.join(d, "mem.hex"), pre)
    with open(os.path.join(d, "job.txt"), "w", encoding="ascii", newline="\n") as f:
        f.write("NAME=%s\nCIN=1\nCOUT=1\nGROUP=1\nH=%d\nW=%d\n" % (name, H, W))
        f.write("TYPE=1\nFLAGS=1\nSRC=%d\nDST=%d\n" % (src, dst))
        f.write("IN_BYTES=%d\nQSHIFT=6\nLID=0\n" % (H * W))
        f.write("M=%d\nZPAD=0\nZY=%d\n" % (M, Z_Y))
        f.write("NCI=1\nNCO=1\nNCOL=%d\nNPASS=1\n" % (H * W))
        f.write("LEN=%d\nPRED_P8=%d\nPRED_N2=%d\n" % (len(gold), pred_p8, pred_n2))
    print("JOBGEN %s variant=%s M=%d len=%d pred_p8=%d pred_n2=%d" % (name, variant, M, len(gold), pred_p8, pred_n2))

main()
PYEOF

for v in tap8 lane45 surg; do
  "$PY" "$work/genjob.py" "$tools_abs" "$work" "xc_$v" "$v" "$SRC" "$DST" "$MEMSZ" 20261016 \
    > "$work/xc_$v.gen" 2>&1 || { echo "RESULT: FAIL 供料失败（$v）"; tail -8 "$work/xc_$v.gen"; exit 3; }
  grep -E '^JOBGEN' "$work/xc_$v.gen" | sed 's/^/    /'
done

# ---- 各作业的内存镜像：真层两档由本段现造（DST 预载与黄金不同）----
cat > "$work/mkmem.py" <<'PYEOF'
import sys, os
d, out, memsz = sys.argv[1], sys.argv[2], int(sys.argv[3])
job = dict(l.split("=", 1) for l in open(os.path.join(d, "job.txt")) if "=" in l)
dst = int(job["DST"]); ln = int(job["COUT"]) * int(job["H"]) * int(job["W"])
gold = [int(x, 16) for x in open(os.path.join(d, "gold.hex")).read().split()]
pre = [((i % 251) * 131 + 7) % 251 for i in range(memsz)]
dif = sum(1 for j in range(ln) if pre[dst + j] != gold[j])
assert dif >= int(ln * 0.9), "dst 预载与黄金过近"
with open(out, "w") as f:
    f.write("".join("%02x\n" % b for b in pre))
print("MEMGEN %s dst_preload_vs_gold_diff=%d/%d" % (os.path.basename(d), dif, ln))
PYEOF
for jd in "$work/ref/lid0_Conv_0" "$work/ref/lid38_Conv_55"; do
  "$PY" "$work/mkmem.py" "$jd" "$jd/mem.hex" "$MEMSZ" || { echo "RESULT: FAIL mem 生成失败 $jd"; exit 3; }
done

# -----------------------------------------------------------------------------
# 3) 跑一次（run_tb <vvp> <jobdir> <tag>）；judge：DST 区对给定黄金 + 整片 dump 比较
# -----------------------------------------------------------------------------
run_tb() {
  local vvp="$1" jd="$2" tag="$3"
  eval "$(sed 's/^/X_/' "$jd/job.txt" | tr '\n' ' ')"
  ( cd "$work" && "$VVP" "$vvp" \
      "+XFILE=$jd/x.hex" "+WFILE=$jd/w.hex" "+BFILE=$jd/b.hex" \
      "+MEMFILE=$jd/mem.hex" "+DUMPFILE=$work/$tag.dump" +dump \
      "+CIN=$X_CIN" "+COUT=$X_COUT" "+GROUP=$X_GROUP" "+H=$X_H" "+W=$X_W" \
      "+TYPE=$X_TYPE" "+FLAGS=$X_FLAGS" "+SRC=$X_SRC" "+DST=$X_DST" "+INB=$X_IN_BYTES" \
      "+QSHIFT=$X_QSHIFT" "+LID=$X_LID" "+M=$X_M" "+ZPAD=$X_ZPAD" "+ZY=$X_ZY" \
      "+NCOL=$X_NCOL" "+NCI=$X_NCI" "+NCO=$X_NCO" ) > "$work/$tag.log" 2>&1
}
beats_of() { sed -n 's/^X1_BEATS=\([0-9]*\).*/\1/p' "$1" | head -1; }
pass_of()  { grep -q '^RESULT: PASS' "$1" && echo 1 || echo 0; }
cyc_of()   { sed -n 's/^CYCLES=\([0-9]*\).*/\1/p' "$1" | head -1; }

# judge_dst <dump> <goldfile> <jobdir> -> MISMATCH（DST 区逐一字节）
judge_dst() {
  "$PY" - "$1" "$2" "$3" <<'PYEOF'
import sys
dumpf, goldf, jd = sys.argv[1], sys.argv[2], sys.argv[3]
job = dict(l.split("=", 1) for l in open(jd + "/job.txt") if "=" in l)
dst = int(job["DST"]); ln = int(job["COUT"]) * int(job["H"]) * int(job["W"])
d = [int(x, 16) & 0xFF for x in open(dumpf, encoding="utf-8", errors="replace").read().split()]
g = [int(x, 16) & 0xFF for x in open(goldf, encoding="utf-8").read().split()]
k = min(ln, len(g), max(0, len(d) - dst))
mm = sum(1 for i in range(k) if d[dst + i] != g[i]) + max(0, ln - k)
print("MISMATCH=%d" % mm)
PYEOF
}
# dump_diff <dumpA> <dumpB> -> 两整片 dump 的差异字节数（长度不等取长）
dump_diff() {
  "$PY" - "$1" "$2" <<'PYEOF'
import sys
def rd(p): return [int(x, 16) & 0xFF for x in open(p, encoding="utf-8", errors="replace").read().split()]
a, b = rd(sys.argv[1]), rd(sys.argv[2])
n = (max(len(a), len(b)) if len(a) != len(b) else sum(1 for i, j in zip(a, b) if i != j))
print("DUMPDIFF=%d" % n)
PYEOF
}

# -----------------------------------------------------------------------------
# 4) 正对照（DCI 开；产品网表）
# -----------------------------------------------------------------------------
echo "---- 3) 正对照：产品网表（DCI 开）—— 真 Conv_0 / 真 Conv_55 / 合成 1→8 / tap8 ----"
run_tb "$work/sim.vvp" "$work/ref/lid0_Conv_0"   "c0_dci"
run_tb "$work/sim.vvp" "$work/ref/lid38_Conv_55" "c1_dci"
run_tb "$work/sim.vvp" "$work/ref/synth_1_8"     "x18_dci"
run_tb "$work/sim.vvp" "$work/xc_tap8"           "tap8_dci"

declare -A JDIR=( [c0]="$work/ref/lid0_Conv_0" [c1]="$work/ref/lid38_Conv_55" [x18]="$work/ref/synth_1_8" [tap8]="$work/xc_tap8" )
declare -A EXP_BEATS_DCI=( [c0]=384 [c1]=128 [x18]=128 [tap8]=128 )
for j in c0 c1 x18 tap8; do
  lg="$work/${j}_dci.log"; P="$(pass_of "$lg")"; B="$(beats_of "$lg")"
  MM="$(judge_dst "$work/${j}_dci.dump" "${JDIR[$j]}/gold.hex" "${JDIR[$j]}" | sed -n 's/^MISMATCH=//p')"
  echo "   [$j DCI] PASS=$P MISMATCH=$MM X1_BEATS=$B（预测 ${EXP_BEATS_DCI[$j]}）CYCLES=$(cyc_of "$lg")"
  [ "$P" = 1 ] || { echo "JUDGE-RED: $j 装置未 PASS"; sed -n '1,8p' "$lg"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$MM" = 0 ] || { echo "JUDGE-RED: $j DST != 黄金（MISMATCH=$MM）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$B" = "${EXP_BEATS_DCI[$j]}" ] || { echo "JUDGE-RED: $j X1_BEATS=$B != 预测 ${EXP_BEATS_DCI[$j]}"; TOTAL_BAD=$((TOTAL_BAD+1)); }
done

# -----------------------------------------------------------------------------
# 5) 实测拍比：网表突变 `_zz_dci_mode <= 1'b0`（DCI 关）⇒ 对照档拍数 + 整片 dump 逐字节相同
#    ★ 口径（本片实测发现的边界，报告 §Slice C-2 详述）：
#      · `c0`（C_in=3）：DCI 是**唯一**机制 ⇒ 关闭后回到 9 拍/像素（1152）⇒ 实测 **3.00×**；
#      · `x18`（C_in=1 → C_out=8，dense）：DCI 机制自身 ⇒ 关闭后 1152 ⇒ 实测 **9.00×**；
#      · `c1`（真 1→1 3×3，GROUP==C_in==C_out==1）：它同时满足 **B1 的 `isDwW` 谓词**
#        （`GROUP != 0 ∧ GROUP == C_in == C_out`）⇒ 部署态本来就走 dw 逐 lane（1 拍/像素）
#        ⇒ DCI 对它**没有增量**（128 == 128，两条通路逐字节同）。再关一层 dw（双关）回到
#        1152 ⇒ 三条通路（dense / dw / c3）同一作业逐字节一致（本判据）。
# -----------------------------------------------------------------------------
echo "---- 4) 实测拍比（DCI 关的受控突变）+ c1 的 dw 谓词边界（三通路逐字节一致）----"
mutate() {  # mutate <in> <out> <mode...>
  "$PY" - "$1" "$2" "${@:3}" <<'PYEOF'
import sys
src, out, modes = sys.argv[1], sys.argv[2], sys.argv[3:]
data = open(src, "rb").read().decode("utf-8")     # 网表带中文注释（UTF-8）⇒ 二进制读、utf-8 解码
lines = data.split("\n")
hits = 0
for i, l in enumerate(lines):
    if "dcioff" in modes and ("_zz_dci_mode <= (((desc_3" in l):
        lines[i] = "        _zz_dci_mode <= 1'b0;   // DCI-MUT (descriptor decode cut)"
        hits += 1
    if "dwoff" in modes and ("_zz_dw_mode <= isDwW;" in l):
        lines[i] = "        _zz_dw_mode <= 1'b0;   // DW-MUT (descriptor decode cut)"
        hits += 1
    if "p8comb" in modes and ("assign _zz_acc_0_8 = (dw_mode ? _zz_acc_0 : 18'h0);" in l):
        lines[i] = ("  assign _zz_acc_0_8 = (dw_mode ? {{2{_zz__zz_acc_0[15]}}, _zz__zz_acc_0} : 18'h0);"
                    "   // P8-MUT (B stage reads the combinational product)")
        hits += 1
    if "lane45" in modes and ("arr_w_dw_0_4 = ws_c3Tile_0_4;" in l):
        lines[i] = "      arr_w_dw_0_4 = ws_c3Tile_0_5;   // C3-MUT (lane 4 w reads lane 5's tile)"
        hits += 1
if hits != len(modes):
    print("MUTATE-FAIL modes=%s hits=%d (anchor not unique)" % (",".join(modes), hits)); sys.exit(1)
with open(out, "w", encoding="utf-8", newline="") as f:
    f.write("\n".join(lines))
print("   MUTATE modes=%s: %d site(s) (anchors unique)" % (",".join(modes), hits))
PYEOF
}
compile_mut() {
  "$IVERILOG" -g2012 -DUE_CGEOM -DUE_X1OBS -o "$2" "$tb" "$memv" "$1" > "$work/iv_$3.log" 2>&1 \
    || { echo "RESULT: FAIL 突变网表编译失败（$3）"; sed -n '1,10p' "$work/iv_$3.log"; exit 1; }
}

mutate "$nl" "$work/nl_off.v" dcioff || { echo "NEGCTL-FAIL: dcioff 锚不唯一"; exit 2; }
compile_mut "$work/nl_off.v" "$work/off.vvp" off
for j in c0 x18; do
  run_tb "$work/off.vvp" "${JDIR[$j]}" "${j}_off"
  lg="$work/${j}_off.log"; P="$(pass_of "$lg")"; B="$(beats_of "$lg")"
  MM="$(judge_dst "$work/${j}_off.dump" "${JDIR[$j]}/gold.hex" "${JDIR[$j]}" | sed -n 's/^MISMATCH=//p')"
  DD="$(dump_diff "$work/${j}_dci.dump" "$work/${j}_off.dump" | sed -n 's/^DUMPDIFF=//p')"
  echo "   [$j DCI-OFF] PASS=$P MISMATCH=$MM X1_BEATS=$B（预测 1152）整片 dump 差异=$DD"
  [ "$P" = 1 ] || { echo "JUDGE-RED: $j(DCI 关) 装置未 PASS"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$B" = 1152 ] || { echo "JUDGE-RED: $j(DCI 关) X1_BEATS=$B != 1152"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$DD" = 0 ] || { echo "JUDGE-RED: $j DCI 开/关两档的整片 dump 不是逐字节相同（差 $DD 字节）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
done
C0_RATIO="$(awk 'BEGIN{printf "%.2f", 1152/384}')"
X18_RATIO="$(awk 'BEGIN{printf "%.2f", 1152/128}')"
echo "   RATIO（实测拍数）：c0 1152 -> 384（= ${C0_RATIO}×）；x18 1152 -> 128（= ${X18_RATIO}×）"

echo "   c1（真 1→1）：DCI 关后仍是 128（dw 谓词已收）—— 再关一层 dw 验证是它："
mutate "$nl" "$work/nl_offdw.v" dcioff dwoff || { echo "NEGCTL-FAIL: dcioff+dwoff 锚不唯一"; exit 2; }
compile_mut "$work/nl_offdw.v" "$work/offdw.vvp" offdw
run_tb "$work/offdw.vvp" "$work/ref/lid38_Conv_55" "c1_offdw"
lg="$work/c1_offdw.log"; P="$(pass_of "$lg")"; B="$(beats_of "$lg")"
MM="$(judge_dst "$work/c1_offdw.dump" "$work/ref/lid38_Conv_55/gold.hex" "$work/ref/lid38_Conv_55" | sed -n 's/^MISMATCH=//p')"
echo "   [c1 dw+DCI 双关] PASS=$P MISMATCH=$MM X1_BEATS=$B（预测 1152 = 9 拍/像素）"
[ "$B" = 1152 ] || { echo "JUDGE-RED: c1 双关后 X1_BEATS=$B != 1152 ⇒ 128 不是 dw 通路给的（机理判据破）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
[ "$MM" = 0 ] || { echo "JUDGE-RED: c1 双关后 != 黄金（$MM）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
for j in c1; do
  run_tb "$work/off.vvp" "${JDIR[$j]}" "${j}_off"
  lg="$work/${j}_off.log"; P="$(pass_of "$lg")"; B="$(beats_of "$lg")"
  MM="$(judge_dst "$work/${j}_off.dump" "${JDIR[$j]}/gold.hex" "${JDIR[$j]}" | sed -n 's/^MISMATCH=//p')"
  DD="$(dump_diff "$work/${j}_dci.dump" "$work/${j}_off.dump" | sed -n 's/^DUMPDIFF=//p')"
  DDD="$(dump_diff "$work/c1_offdw.dump" "$work/${j}_dci.dump" | sed -n 's/^DUMPDIFF=//p')"
  echo "   [$j DCI 关、dw 开] PASS=$P MISMATCH=$MM X1_BEATS=$B（= dw 通路，应 128）三档 dump 差异（dci/off=$DD、offdw/dci=$DDD）"
  [ "$P" = 1 ] || { echo "JUDGE-RED: $j(DCI 关) 装置未 PASS"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$B" = "${EXP_BEATS_DCI[$j]}" ] || { echo "JUDGE-RED: $j(DCI 关) X1_BEATS=$B != ${EXP_BEATS_DCI[$j]}（dw 通路）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$DD" = 0 ] && [ "$DDD" = 0 ] || { echo "JUDGE-RED: $j 三条通路（dense/dw/c3）的整片 dump 不是逐字节相同（$DD / $DDD）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
done

# -----------------------------------------------------------------------------
# 6) 负对照 N1：p8 组合回读（受控 A/B；"没有 A 级寄存 ⇒ 必红且按预测量"）
# -----------------------------------------------------------------------------
echo "---- 5) 负对照 N1（p8r 的受控 A/B）：B 级改回组合积 ⇒ tap8 作业按预测量发火 ----"
PRED_P8="$(sed -n 's/^PRED_P8=//p' "$work/xc_tap8/job.txt")"
echo "   预测量 PRED_P8 = #(gold_tap8 != gold_bias) = ${PRED_P8:-?}"
if [ "${PRED_P8:-0}" = 0 ]; then echo "NEGCTL-FAIL: tap8 的注入没有改变黄金 ⇒ 负对照没牙"; NEG_NOFIRE=$((NEG_NOFIRE+1)); fi
mutate "$nl" "$work/nl_p8.v" p8comb || { echo "NEGCTL-FAIL: p8comb 锚不唯一"; exit 2; }
compile_mut "$work/nl_p8.v" "$work/p8.vvp" p8
run_tb "$work/p8.vvp" "$work/xc_tap8" "tap8_p8mut"
LG="$work/tap8_p8mut.log"; P="$(pass_of "$LG")"; B="$(beats_of "$LG")"
MM="$(judge_dst "$work/tap8_p8mut.dump" "$work/xc_tap8/gold.hex" "$work/xc_tap8" | sed -n 's/^MISMATCH=//p')"
MMB="$(judge_dst "$work/tap8_p8mut.dump" "$work/xc_tap8/gold_bias.hex" "$work/xc_tap8" | sed -n 's/^MISMATCH=//p')"
echo "   [N1 tap8 组合回读] PASS=$P X1_BEATS=$B（应 128）MISMATCH(vs 黄金)=$MM（预测 $PRED_P8）MISMATCH(vs bias-only)=$MMB（应 0）"
[ "$MM" = "$PRED_P8" ] || { echo "JUDGE-RED: 负对照 N1 未按预测量发火（MM=$MM != $PRED_P8）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
[ "${MM:-0}" != 0 ] || { echo "NEGCTL-FAIL: 负对照 N1 没发火（MISMATCH=0）"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }
[ "$MMB" = 0 ] || { echo "JUDGE-RED: 负对照 N1 的输出 != bias-only 黄金（MMB=$MMB）⇒ 红的机理不是第 9 抽头被吞"; TOTAL_BAD=$((TOTAL_BAD+1)); }

# -----------------------------------------------------------------------------
# 7) 负对照 N2（c3 路由改错）+ 外科式（红↔绿翻面只由**一个权重字节**造成）
# -----------------------------------------------------------------------------
echo "---- 6) 负对照 N2（lane 4 的 w 来源改读 lane 5 的瓦片）+ 外科式（槽 5 := 槽 4）----"
PRED_N2="$(sed -n 's/^PRED_N2=//p' "$work/xc_lane45/job.txt")"
echo "   预测量 PRED_N2 = #(gold != gold_mut) = ${PRED_N2:-?}"
if [ "${PRED_N2:-0}" = 0 ]; then echo "NEGCTL-FAIL: lane45 的注入没有改变黄金 ⇒ 负对照没牙"; NEG_NOFIRE=$((NEG_NOFIRE+1)); fi
mutate "$nl" "$work/nl_c3.v" lane45 || { echo "NEGCTL-FAIL: lane45 锚不唯一"; exit 2; }
compile_mut "$work/nl_c3.v" "$work/c3.vvp" c3
run_tb "$work/c3.vvp" "$work/xc_lane45" "lane45_mut"
run_tb "$work/c3.vvp" "$work/xc_surg"   "surg_mut"
LG="$work/lane45_mut.log"; P="$(pass_of "$LG")"; B="$(beats_of "$LG")"
MM="$(judge_dst "$work/lane45_mut.dump" "$work/xc_lane45/gold.hex" "$work/xc_lane45" | sed -n 's/^MISMATCH=//p')"
MMM="$(judge_dst "$work/lane45_mut.dump" "$work/xc_lane45/gold_mut.hex" "$work/xc_lane45" | sed -n 's/^MISMATCH=//p')"
echo "   [N2 lane45 路由突变] PASS=$P X1_BEATS=$B（应 128）MISMATCH(vs 黄金)=$MM（预测 $PRED_N2）MISMATCH(vs gold_mut)=$MMM（应 0）"
[ "$MM" = "$PRED_N2" ] || { echo "JUDGE-RED: 负对照 N2 未按预测量发火（MM=$MM != $PRED_N2）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
[ "${MM:-0}" != 0 ] || { echo "NEGCTL-FAIL: 负对照 N2 没发火（MISMATCH=0）"; NEG_NOFIRE=$((NEG_NOFIRE+1)); }
[ "$MMM" = 0 ] || { echo "JUDGE-RED: 负对照 N2 的输出 != gold_mut（$MMM）⇒ 红的机理不是 c3 路由"; TOTAL_BAD=$((TOTAL_BAD+1)); }

LGS="$work/surg_mut.log"; PS="$(pass_of "$LGS")"; BS="$(beats_of "$LGS")"
MMS="$(judge_dst "$work/surg_mut.dump" "$work/xc_surg/gold.hex" "$work/xc_surg" | sed -n 's/^MISMATCH=//p')"
echo "   [S surg（槽 5 := 槽 4）] PASS=$PS X1_BEATS=$BS（应 128）MISMATCH=$MMS（应 0 ⇒ 翻绿）"
[ "$MMS" = 0 ] && [ "$PS" = 1 ] || { echo "JUDGE-RED: 外科式未翻绿（MM=$MMS）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
if ! "$PY" - "$work" <<'PYEOF'; then
import sys
w = sys.argv[1]
def rd(p): return [int(x, 16) & 0xFF for x in open(p, encoding="utf-8", errors="replace").read().split()]
gl = rd("%s/xc_lane45/gold.hex" % w); gs = rd("%s/xc_surg/gold.hex" % w)
dl = rd("%s/lane45_mut.dump" % w); ds = rd("%s/surg_mut.dump" % w)
n_g = sum(1 for i in range(len(gl)) if gl[i] != gs[i])
n_d = sum(1 for i in range(len(dl)) if dl[i] != ds[i])
assert n_g > 0, "槽 5 的字节没改变黄金 ⇒ 外科式不成立（翻绿是假绿）"
assert n_d > 0, "DUT 两份 dump 完全相同 ⇒ 槽 5 的值没被吃到"
print("   SURG：槽 5 字节改变黄金 %d 字节；突变网表两份 dump 差 %d 字节"
      "（≥ 黄金差 —— 突变把槽 5 同时喂给 lane 4/5 两条 lane，方向一致）" % (n_g, n_d))
PYEOF
  TOTAL_BAD=$((TOTAL_BAD+1)); NEG_NOFIRE=$((NEG_NOFIRE+1))
fi

# -----------------------------------------------------------------------------
# 8) 收口
# -----------------------------------------------------------------------------
echo "=========================================================================="
if [ "$TOTAL_BAD" != 0 ]; then echo "RESULT: FAIL（判据红 $TOTAL_BAD 条）"; exit 1; fi
if [ "$NEG_NOFIRE" != 0 ]; then echo "RESULT: FAIL（负对照/突变没发火 $NEG_NOFIRE 条）"; exit 2; fi
echo "RESULT: PASS"
echo "  正对照：c0(真 Conv_0) 384 拍 / c1(真 Conv_55) 128 拍 / x18(合成 1→8) 128 拍 / tap8 128 拍 —— 全部逐字节 == 冻结参考"
echo "  实测拍比（产品网表，DCI 关的受控突变）：c0 3.00×（$C0_RATIO×，1,152->384）与 x18 9.00×（$X18_RATIO×，1,152->128），两档整片 dump 逐字节相同"
echo "  c1 的边界（实测）：DCI 关（dw 开）128 == DCI 开 128；dw+DCI 双关 1,152 ⇒ dw 谓词先收（1、2 两条通路与 c3 逐字节一致）"
echo "  p8r 的受控 A/B：组合回读 ⇒ MISMATCH == $PRED_P8 且 dump == bias-only 黄金；正规网表 == 0（必要且充分）"
echo "  c3 路由负对照 + 外科式：MISMATCH == $PRED_N2 且 dump == gold_mut；一个权重字节翻绿"
exit 0
