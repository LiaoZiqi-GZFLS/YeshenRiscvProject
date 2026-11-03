#!/usr/bin/env bash
# run_cipack_ab.sh —— ★★ NPU v2 切片 C-1：**dense ci-inner（ci 进拍、tap 进 lane）探针**的闸门。
#
# 被测（**独立探针**，不改任何产品 RTL）：`rtl_test/CiPackProbe.scala` 出的三档网表
#   · `gen/CiPackBase.v`（DCI=0）—— B1 落地后的切片当量（dense 广播 9 拍/像素 + dw 逐 lane AFTER1）；
#   · `gen/CiPackDci.v`（DCI=1）—— Base + **c3 ci-inner**（像素相位 9 → `C_in` 拍；本片被测的增量）；
#   · `gen/CiPackDciMut5.v`（DCI=1 + MUTX=5）—— **外科锚**：c3 读口里 lane 5 的 kx 由 2 改成 0。
#   装置 = `rtl_test/CiPackTb.v`（一份 TB，一次只编译一份探针网表；Base 档需要 `-DBASE`）。
#
# 作业（**真表权重**；向量/黄金由本闸门的 inline python 现算，黄金另有**第二实现**互证）：
#   · `conv0`：`Conv_0` 真权重（`C_in=3 C_out=16`，`NB=2` 趟）；x = 随机 int8（3 通道，lane 3..7 置 0）。
#     黄金二实现 = 冻结 `tools/wide_exec_ref.py` 的 `conv_acc`（§4.5-A 硬件口径）现跑对比。
#   · `c1`：`Conv_55` 真权重（`1→1 3×3`，`NB=1`）。
#   · `dw8`：`multipass_ref.build_one(8,8,8)` 的冻结向量/黄金（dw 档回归：C 的网表不许动 B1 的路）。
#
# 判据（全部按**预测量**断言，不看"像不像"）：
#   [0] 前置：`c_tail_account.py` 现跑（逐层价签锚）+ 三份探针网表存在（md5 记入输出）。
#   [1] 正对照（**逐字节**）：每作业在 Base 与 Dci 上 `MISMATCH == 0`（对黄金）且两档 **Y 逐字节相同**。
#   [2] 拍数（**实测**）：`BEATS == taps·NB·NPIX`：Base = 9；Dci 的 dense = `C_in`（conv0: 3；c1: 1）；
#       dw8（DW=1）= 1 ⇒ dense 实测比 9/C_in（conv0: 3.00×；c1: 9.00×）。
#   [3] 补位 lane 承重（正对照）：`+GARB=1`（lane ≥ C_in 喂垃圾）⇒ 两档仍 == 黄金（权重零填负责）。
#   [4] 负对照 A（**tap-8 切除**，按预测量发火）：把瓦片里每个 (co,ci) 的第 9 抽头（`mem[r*72+c*9+8]`）置 0
#       ⇒ Base 与 Dci 的 MISMATCH **恰 ==** python 现算的预测（> 0）—— 证第 9 抽头行真的被吃到。
#   [5] 负对照 B（**路由突变**，按预测量发火）：`CiPackDciMut5` 跑正规瓦片 ⇒ MISMATCH **恰 ==** 预测（> 0）；
#       同一作业在正规 Dci 网表上 == 0（外科式翻绿）⇒ 红是 c3 路由造成的。
#   [6] dw 档回归：`dw8` 作业在 Base 与 Dci 两档上都 == 冻结 `multipass_ref` 黄金、拍数 = 1/像素/趟。
#
# 退出码：0 = 全过 / 1 = 判据红 / 2 = 负对照没发火（预测 ≤ 0 或不等） / 3 = 前置缺失。
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

tb="rtl_test/CiPackTb.v"
nlBase="gen/CiPackBase.v"
nlDci="gen/CiPackDci.v"
nlMut="gen/CiPackDciMut5.v"
widx="gen/wgt_index.json"
wblob="gen/wgt_blob.bin"
outdir="gen/c4a_cipack"
SEED=20261016

find_tool() {
  local n="$1" p d
  p="$(command -v "$n" 2>/dev/null || true)"
  if [ -z "$p" ]; then for d in /c/msys64/ucrt64/bin /mingw64/bin /usr/bin; do [ -x "$d/$n" ] && { p="$d/$n"; break; }; done; fi
  printf '%s' "$p"
}
IVERILOG="$(find_tool iverilog)"; VVP="$(find_tool vvp)"

echo "== run_cipack_ab: NPU v2 切片 C-1（dense ci-inner 探针：Base / Dci / DciMut5 + 两条负对照）=="
echo "   tb=$tb  nl=$nlBase $nlDci $nlMut  py=$PY  iverilog=${IVERILOG:-<none>}"

for f in "$tb" "$nlBase" "$nlDci" "$nlMut" "$widx" "$wblob" "tools/c_tail_account.py" "tools/wide_exec_ref.py"; do
  [ -f "$f" ] || { echo "FATAL: 缺 $f（先 Test/runMain CiPackGen ... 生成）"; echo "RESULT: FAIL"; exit 3; }
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

echo "---- [0] 前置：逐层价签工具现跑 + 网表 md5 ----"
"$PY" tools/c_tail_account.py > "$work/c_tail.out" 2>&1 || { echo "RESULT: FAIL 逐层价签锚不符"; tail -12 "$work/c_tail.out"; exit 3; }
grep '^RESULT: PASS' "$work/c_tail.out" >/dev/null && echo "   c_tail_account.py RESULT: PASS（A+B1 6,781,200 / 残差 1,502,437.5 全分解）"
for f in "$nlBase" "$nlDci" "$nlMut"; do echo "   MD5 $f = $(md5sum "$f" | cut -d' ' -f1)"; done

echo "---- [1] 向量 + 黄金（真表权重）+ 负对照预测 ----"
rm -rf "$outdir"; mkdir -p "$outdir"
JOBLIST=""
for JOB in conv0 c1; do
  d="$outdir/$JOB"
  if ! "$PY" - "$JOB" "$d" "$widx" "$wblob" "$SEED" > "$work/gen_$JOB.out" 2>&1 <<'PYEOF'
import sys, os, json, importlib.util, hashlib
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
import numpy as np

JOB, d, widx, wblob, seed = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
os.makedirs(d, exist_ok=True)
idx = json.load(open(widx, encoding="utf-8"))
blob = open(wblob, "rb").read()
H = W = 8
TILE = 8

# 真表单元（idx → 真几何 + blob 段）
lid = {"conv0": 0, "c1": 50}[JOB]          # 0 = Conv_0；50 = Conv_67（另一片 1→1 dense，与 38 同形）
u = [x for x in idx["units"] if x["idx"] == lid][0]
cen = [x for x in idx["centering"] if x["layer_id"] == lid][0]
req = [x for x in idx["requant_mult"] if x["layer_id"] == lid][0]
co, ci = int(u["own"]["C_OUT"]), int(u["own"]["C_IN"])
w = np.frombuffer(blob[u["weight"]["offset"]:u["weight"]["offset"] + u["weight"]["nbytes"]],
                  dtype=np.int8).astype(np.int64).reshape(co, ci, 3, 3)

rng = np.random.default_rng(seed + lid)
xq = rng.integers(-20, 21, size=(ci, H, W)).astype(np.int64)     # 只造真通道；lane≥ci 由 TB 喂 0/垃圾

gold = None

def requant(acc, M, zy):
    y = ((np.asarray(acc, dtype=np.int64) * np.int64(M)) >> 30) + np.int64(zy)
    return np.clip(y, -128, 127).astype(np.int64)

def conv_acc_local(xq, wq, H, W):
    """本文件自己的 acc 模型（int64 精确；补位 = 0）。"""
    xp = np.zeros((wq.shape[1], H + 2, W + 2), dtype=np.int64)
    xp[:, 1:H+1, 1:W+1] = xq
    acc = np.zeros((wq.shape[0], H, W), dtype=np.int64)
    for ky in range(3):
        for kx in range(3):
            for c in range(wq.shape[1]):
                acc += wq[:, c, ky, kx][:, None, None] * xp[c, ky:ky+H, kx:kx+W]
    return acc

acc = conv_acc_local(xq, w, H, W) + np.asarray(cen["bias_adj"], dtype=np.int64)[:, None, None]
M, zy = int(req["M"]), int(cen["z_y"])
gold = requant(acc, M, zy)

# ---- 黄金二实现互证（冻结 wide_exec_ref.conv_acc；§4.5-A 硬件口径，padval=0）----
spec = importlib.util.spec_from_file_location("wide_exec_ref", "tools/wide_exec_ref.py")
WER = importlib.util.module_from_spec(spec); spec.loader.exec_module(WER)
n_ci = (ci + TILE - 1) // TILE; n_co = (co + TILE - 1) // TILE
CI8, CO8 = n_ci * TILE, n_co * TILE
x8 = np.zeros((1, CI8, H, W), dtype=np.int64); x8[0, :ci] = xq
wseg = np.zeros((CO8, CI8, 3, 3), dtype=np.int64); wseg[:co, :ci] = w
acc2 = WER.conv_acc(x8, wseg, 0, np.asarray(cen["bias_adj"][:co] + [0]*(CO8-co), dtype=np.int64))
assert np.array_equal(np.asarray(acc, dtype=np.int64), np.asarray(acc2, dtype=np.int64)[:co]), \
    "两实现 acc 不一致（黄金不可信）"
assert len(set(gold.reshape(-1).tolist())) > 1, "黄金退化"

# ---- 落盘：x（[ci][y][x]）/ 权重趟瓦片（[pass][cl][cil][tap]，ci≥C_in 与 co 越界零填）/ b / gold ----
def dump(path, toks):
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("".join("%02x\n" % (int(t) & 0xff) for t in toks))

dump(os.path.join(d, "x.hex"), xq.reshape(-1))
NB = (co + TILE - 1) // TILE
tile = np.zeros(NB * 576, dtype=np.int64)
for p in range(NB):
    for cl in range(8):
        cg = p * 8 + cl
        if cg >= co: break
        for cil in range(8):
            if cil >= ci: break
            for tap in range(9):
                tile[p * 576 + cl * 72 + cil * 9 + tap] = w[cg, cil, tap // 3, tap % 3]
dump(os.path.join(d, "w.hex"), tile)
b = np.zeros(NB * 8, dtype=np.int64)
for cg in range(co): b[cg] = cen["bias_adj"][cg]
# ★ bias 是 **int32**（累加器单位）：必须 8 位十六进制（2 位会把 -14255 截成 0x51 ⇒ 黄金/装置错位）
with open(os.path.join(d, "b.hex"), "w", encoding="ascii", newline="\n") as f:
    f.write("".join("%08x\n" % (int(t) & 0xffffffff) for t in b))
dump(os.path.join(d, "gold.hex"), gold.reshape(-1))

# ---- 负对照 A：第 9 抽头（tap=8）切除 ----
w_no8 = w.copy(); w_no8[:, :, 2, 2] = 0
acc_no8 = conv_acc_local(xq, w_no8, H, W) + np.asarray(cen["bias_adj"], dtype=np.int64)[:, None, None]
gold_no8 = requant(acc_no8, M, zy)
n_no8 = int(np.count_nonzero(gold_no8 != gold))
tile_no8 = tile.copy()
for p in range(NB):
    for cl in range(8):
        for cil in range(8):
            tile_no8[p * 576 + cl * 72 + cil * 9 + 8] = 0
dump(os.path.join(d, "w_no8.hex"), tile_no8)
n_diff_no8 = int(np.count_nonzero(tile_no8 != tile))
# 只切"真 (co,ci) 格"的 tap8（预测的口径就是这个子集；CO8 之外的行已在瓦片里为 0）
n_diff_expect = min(co, NB*8) * min(ci, 8) - int(np.count_nonzero(w[:, :, 2, 2] == 0))

# ---- 负对照 B：c3 路由突变（lane 5: (ky=1,kx=2) → (ky=1,kx=0)）----
xp = np.zeros((ci, H + 2, W + 2), dtype=np.int64); xp[:, 1:H+1, 1:W+1] = xq
acc_mut = acc.copy()
for c in range(ci):
    acc_mut += w[:, c, 1, 2][:, None, None] * (xp[c, 1:1+H, 0:W] - xp[c, 1:1+H, 2:2+W])[None, :, :]
gold_mut = requant(acc_mut, M, zy)
n_mut = int(np.count_nonzero(gold_mut != gold))
# 突变网的黄金也落盘（外科式：正规网表 == gold、突变网表 == gold_mut）
dump(os.path.join(d, "gold_mut.hex"), gold_mut.reshape(-1))

with open(os.path.join(d, "params.txt"), "w", encoding="ascii", newline="\n") as f:
    f.write("CIN=%d\nCOUT=%d\nH=%d\nIW=%d\nNB=%d\nNCIP=%d\nM=%d\nZY=%d\n"
            % (ci, co, H, W, NB, n_ci, M, zy))

print("MODEL_OK job=%s: 两实现 acc 逐点相等（wide_exec_ref.conv_acc 现跑）；黄金 distinct=%d"
      % (JOB, len(set(gold.reshape(-1).tolist()))))
print("PRED job=%s NEG_NO8=%d NEG_MUT5=%d WDIFF_NO8=%d(期望 %d) md5x=%s"
      % (JOB, n_no8, n_mut, n_diff_no8, n_diff_expect,
         hashlib.md5(xq.astype(np.int8).tobytes()).hexdigest()[:8]))
ok = (n_no8 > 0) and (n_mut > 0) and (n_diff_no8 == n_diff_expect)
sys.exit(0 if ok else 1)
PYEOF
  then
    echo "FATAL: 向量/预测失败（$JOB）"; tail -8 "$work/gen_$JOB.out"; echo "RESULT: FAIL"; exit 3
  fi
  grep '^MODEL_OK\|^PRED ' "$work/gen_$JOB.out" | sed 's/^/    /'
  JOBLIST="$JOBLIST $JOB"
done

# ---- dw8 作业：冻结 multipass_ref 供料（dw 档回归）----
d="$outdir/dw8"; mkdir -p "$d"
if ! "$PY" - "$d" "$SEED" > "$work/gen_dw8.out" 2>&1 <<'PYEOF'
import sys, os, importlib.util
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
d, seed = sys.argv[1], int(sys.argv[2])
spec = importlib.util.spec_from_file_location("multipass_ref", "tools/multipass_ref.py")
M = importlib.util.module_from_spec(spec); spec.loader.exec_module(M)
p, n = M.build_one(8, 8, 8, seed, d)      # 冻结工具现跑：x/w/b/gold + params
assert n["d_whole"] == 0 and n["distinct"] > 1, "dw8 黄金退化"
# 本闸门 TB 的 plusarg 口径：params.txt 里 CIN/COUT/H/IW/M/ZY 已是同名键
print("MODEL_OK job=dw8: 冻结 multipass_ref.build_one(8,8,8) 现跑（d_whole=0, distinct=%d）" % n["distinct"])
PYEOF
then
  echo "FATAL: dw8 供料失败"; tail -8 "$work/gen_dw8.out"; echo "RESULT: FAIL"; exit 3
fi
grep '^MODEL_OK' "$work/gen_dw8.out" | sed 's/^/    /'
JOBLIST="$JOBLIST dw8"

pred() { grep '^PRED ' "$work/gen_$1.out" | tr ' ' '\n' | grep "^$2=" | cut -d= -f2; }

echo "---- [1b] 编译（一份 TB，三份探针网表各编一份；Base 需要 -DBASE）----"
if ! "$IVERILOG" -g2012 -DBASE -o "$work/base.vvp" "$tb" "$nlBase" > "$work/iv_base.log" 2>&1; then
  echo "JUDGE-RED: Base 编译失败"; sed -n '1,20p' "$work/iv_base.log"; echo "RESULT: FAIL"; exit 1; fi
if ! "$IVERILOG" -g2012 -o "$work/dci.vvp" "$tb" "$nlDci" > "$work/iv_dci.log" 2>&1; then
  echo "JUDGE-RED: Dci 编译失败"; sed -n '1,20p' "$work/iv_dci.log"; echo "RESULT: FAIL"; exit 1; fi
if ! "$IVERILOG" -g2012 -o "$work/mut5.vvp" "$tb" "$nlMut" > "$work/iv_mut.log" 2>&1; then
  echo "JUDGE-RED: DciMut5 编译失败"; sed -n '1,20p' "$work/iv_mut.log"; echo "RESULT: FAIL"; exit 1; fi
echo "    三份都编译 OK"
if [ -f tools/check_dangling.py ]; then
  for f in "$nlBase" "$nlDci" "$nlMut"; do
    "$PY" tools/check_dangling.py "$f" >/dev/null || { echo "JUDGE-RED: $f 有悬空实例"; echo "RESULT: FAIL"; exit 1; }
  done
  echo "    check_dangling: 三份网表 0 悬空"
fi

# run_tb <vvp> <tag> <dir> <wfile> <DCI> <GARB> <DW>
run_tb() {
  local vvp="$1" tag="$2" d="$3" wf="$4" dci="$5" garb="$6" dw="$7"
  local CIN COUT H IW M ZY NCIP
  CIN="$(sed -n 's/^CIN=//p' "$d/params.txt" | head -1)"
  COUT="$(sed -n 's/^COUT=//p' "$d/params.txt" | head -1)"
  H="$(sed -n 's/^H=//p' "$d/params.txt" | head -1)"
  IW="$(sed -n 's/^IW=//p' "$d/params.txt" | head -1)"
  M="$(sed -n 's/^M=//p' "$d/params.txt" | head -1)"
  ZY="$(sed -n 's/^ZY=//p' "$d/params.txt" | head -1)"
  NCIP="$(sed -n 's/^NCIP=//p' "$d/params.txt" | head -1)"; NCIP="${NCIP:-1}"
  ( cd "$work" && "$VVP" "$vvp" \
      "+XFILE=$PWD_ABS/$d/x.hex" "+WFILE=$wf" "+BFILE=$PWD_ABS/$d/b.hex" \
      "+CIN=$CIN" "+COUT=$COUT" "+H=$H" "+IW=$IW" "+M=$M" "+ZY=$ZY" "+NCIP=$NCIP" \
      "+DCI=$dci" "+GARB=$garb" "+DW=$dw" ) \
      > "$work/$tag.log" 2>&1
  grep -E '^CIPACK ' "$work/$tag.log" | tail -2 | sed "s/^/    /"
  grep '^Y ' "$work/$tag.log" | sed -e 's/^Y *//' | tr -s ' ' '\n' > "$work/$tag.y" || true
}

TOTAL_BAD=0; NEG_NOFIRE=0
echo "---- [1c]+[2]+[6] 正对照（逐字节）+ 拍数（实测 vs 预测）+ 两档互等 ----"
# dense 作业：Base（DCI=0, 9 拍）vs Dci（DCI=1, C_in 拍）
for JOB in conv0 c1; do
  d="$outdir/$JOB"
  CIN="$(sed -n 's/^CIN=//p' "$d/params.txt" | head -1)"
  NB="$(sed -n 's/^NB=//p' "$d/params.txt" | head -1)"
  NPIX=$(( 8 * 8 ))
  B9=$(( 9 * NB * NPIX )); BD=$(( CIN * NB * NPIX ))
  bg() { grep -oE "BEATS=[0-9]+" "$work/$1.log" | head -1 | cut -d= -f2; }
  run_tb "$work/base.vvp" "base_$JOB" "$d" "$PWD_ABS/$d/w.hex" 0 0 0
  if ! grep -q '^RESULT: PASS' "$work/base_$JOB.log"; then
    echo "JUDGE-RED: base $JOB 没有跑完"; tail -6 "$work/base_$JOB.log"; TOTAL_BAD=$((TOTAL_BAD+1)); fi
  MIS="$(cnt "$d/gold.hex" "$work/base_$JOB.y")"
  [ "$MIS" = "0" ] || { echo "JUDGE-RED: base $JOB MISMATCH=$MIS（对黄金）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  BT="$(bg "base_$JOB")"
  [ "$BT" = "$B9" ] || { echo "JUDGE-RED: base $JOB BEATS=$BT != 预测 $B9"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  echo "SHAPE $JOB base  MISMATCH=$MIS BEATS=$BT(预测 $B9) MODEID=$(grep -oE 'MODEID=[0-9]+' "$work/base_$JOB.log" | head -1 | cut -d= -f2)"

  run_tb "$work/dci.vvp" "dci_$JOB" "$d" "$PWD_ABS/$d/w.hex" 1 0 0
  if ! grep -q '^RESULT: PASS' "$work/dci_$JOB.log"; then
    echo "JUDGE-RED: dci $JOB 没有跑完"; tail -6 "$work/dci_$JOB.log"; TOTAL_BAD=$((TOTAL_BAD+1)); fi
  MIS="$(cnt "$d/gold.hex" "$work/dci_$JOB.y")"
  [ "$MIS" = "0" ] || { echo "JUDGE-RED: dci $JOB MISMATCH=$MIS（对黄金）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  BT="$(bg "dci_$JOB")"
  [ "$BT" = "$BD" ] || { echo "JUDGE-RED: dci $JOB BEATS=$BT != 预测 $BD"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  RATIO=$(( B9 / BD ))
  echo "SHAPE $JOB dci   MISMATCH=$MIS BEATS=$BT(预测 $BD) 实测比=${RATIO}.00× MODEID=$(grep -oE 'MODEID=[0-9]+' "$work/dci_$JOB.log" | head -1 | cut -d= -f2)"

  S="$(cnt "$work/base_$JOB.y" "$work/dci_$JOB.y")"
  [ "$S" = "0" ] || { echo "JUDGE-RED: $JOB 两档 Y 不一致（=$S）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  echo "CONSIST $JOB base==dci: $S"

  # ---- [3] 补位 lane 承重：lane ≥ CIN 喂垃圾 ⇒ 两档仍 == 黄金 ----
  run_tb "$work/base.vvp" "base_$JOB" "$d" "$PWD_ABS/$d/w.hex" 0 1 0
  MIS_B="$(cnt "$d/gold.hex" "$work/base_$JOB.y")"
  run_tb "$work/dci.vvp" "dci_$JOB" "$d" "$PWD_ABS/$d/w.hex" 1 1 0
  MIS_D="$(cnt "$d/gold.hex" "$work/dci_$JOB.y")"
  if [ "$MIS_B" != "0" ] || [ "$MIS_D" != "0" ]; then
    echo "JUDGE-RED: $JOB GARB 档失配（base=$MIS_B dci=$MIS_D）—— 补位 lane 不是免费/零填前提不成立"
    TOTAL_BAD=$((TOTAL_BAD+1))
  else
    echo "GARB   $JOB 两档在 lane≥$CIN 喂垃圾下仍 == 黄金（补位 lane 免费：权重零填负责）"
  fi

  # ---- [4] 负对照 A：tap-8 切除 ----
  PN="$(pred "$JOB" NEG_NO8)"
  run_tb "$work/base.vvp" "base_${JOB}_no8" "$d" "$PWD_ABS/$d/w_no8.hex" 0 0 0
  MIS="$(cnt "$d/gold.hex" "$work/base_${JOB}_no8.y")"
  if [ "$MIS" != "$PN" ]; then
    echo "NEGCTL-FAIL: 负对照 A base $JOB MISMATCH=$MIS != 预测 $PN"; NEG_NOFIRE=$((NEG_NOFIRE+1))
  else echo "NEGCTL-A $JOB base  MISMATCH=$MIS == 预测（发火）"; fi
  run_tb "$work/dci.vvp" "dci_${JOB}_no8" "$d" "$PWD_ABS/$d/w_no8.hex" 1 0 0
  MIS="$(cnt "$d/gold.hex" "$work/dci_${JOB}_no8.y")"
  if [ "$MIS" != "$PN" ]; then
    echo "NEGCTL-FAIL: 负对照 A dci $JOB MISMATCH=$MIS != 预测 $PN"; NEG_NOFIRE=$((NEG_NOFIRE+1))
  else echo "NEGCTL-A $JOB dci   MISMATCH=$MIS == 预测（发火）"; fi

  # ---- [5] 负对照 B：c3 路由突变（MUTX=5）+ 外科式翻绿 ----
  PM="$(pred "$JOB" NEG_MUT5)"
  run_tb "$work/mut5.vvp" "mut5_$JOB" "$d" "$PWD_ABS/$d/w.hex" 1 0 0
  MIS="$(cnt "$d/gold.hex" "$work/mut5_$JOB.y")"
  if [ "$MIS" != "$PM" ]; then
    echo "NEGCTL-FAIL: 负对照 B $JOB MISMATCH=$MIS != 预测 $PM"; NEG_NOFIRE=$((NEG_NOFIRE+1))
  else echo "NEGCTL-B $JOB mut5  MISMATCH=$MIS == 预测（发火）"; fi
  # 外科式：突变网表的输出 == gold_mut（预测的逐字节命中，不是"数差几个"）
  MISM="$(cnt "$d/gold_mut.hex" "$work/mut5_$JOB.y")"
  [ "$MISM" = "0" ] || { echo "JUDGE-RED: 外科式 $JOB 突变输出 != gold_mut（=$MISM）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  echo "SURG   $JOB mut5 == gold_mut（外科式翻绿口径）"
done

# ---- [6] dw8 作业（DW=1）：Base 与 Dci 两档 == 冻结 multipass_ref 黄金、1 拍/像素/趟 ----
d="$outdir/dw8"
H8="$(sed -n 's/^H=//p' "$d/params.txt" | head -1)"; IW8="$(sed -n 's/^IW=//p' "$d/params.txt" | head -1)"
NB8="$(sed -n 's/^NCO=//p' "$d/params.txt" | head -1)"   # n_co = 趟数（本作业 = 1）
B1D=$(( 1 * NB8 * H8 * IW8 ))
bg() { grep -oE "BEATS=[0-9]+" "$work/$1.log" | head -1 | cut -d= -f2; }
for v in base dci; do
  run_tb "$work/$v.vvp" "${v}_dw8" "$d" "$PWD_ABS/$d/w.hex" 0 0 1
  if ! grep -q '^RESULT: PASS' "$work/${v}_dw8.log"; then
    echo "JUDGE-RED: $v dw8 没有跑完"; tail -6 "$work/${v}_dw8.log"; TOTAL_BAD=$((TOTAL_BAD+1)); fi
  MIS="$(cnt "$d/gold.hex" "$work/${v}_dw8.y")"
  [ "$MIS" = "0" ] || { echo "JUDGE-RED: $v dw8 MISMATCH=$MIS（对冻结黄金）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  BT="$(bg "${v}_dw8")"
  [ "$BT" = "$B1D" ] || { echo "JUDGE-RED: $v dw8 BEATS=$BT != 预测 $B1D"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  echo "SHAPE dw8 $v MISMATCH=$MIS BEATS=$BT(预测 $B1D)"
done
S="$(cnt "$work/base_dw8.y" "$work/dci_dw8.y")"
[ "$S" = "0" ] || { echo "JUDGE-RED: dw8 两档 Y 不一致（=$S）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
echo "CONSIST dw8 base==dci: $S"

echo "=========================================================================="
echo "jobs =$JOBLIST（真表 Conv_0 3→16 / Conv_67 1→1 / 冻结 dw 8→8）"
echo "正对照   = 每作业 Base/Dci == 黄金（MISMATCH=0）；两档 Y 逐字节互等；GARB 档不变"
echo "拍数实测 = Base 9 拍/像素/趟；Dci dense 3（conv0，3.00×）/ 1（c1，9.00×）；dw8 = 1"
echo "负对照 A = 第 9 抽头切除 ⇒ 两档 MISMATCH 恰 == 预测（>0）"
echo "负对照 B = c3 lane 5 路由改错 ⇒ MISMATCH 恰 == 预测；突变输出 == gold_mut（外科式）"
if [ "$NEG_NOFIRE" -ne 0 ]; then echo "NEGCTL-FAIL: $NEG_NOFIRE 条负对照没按预测发火"; echo "RESULT: FAIL"; exit 2; fi
if [ "$TOTAL_BAD" -ne 0 ]; then echo "JUDGE-RED: $TOTAL_BAD 条判据红"; echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
exit 0
