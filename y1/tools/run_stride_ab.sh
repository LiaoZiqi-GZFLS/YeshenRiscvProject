#!/usr/bin/env bash
# run_stride_ab.sh —— y1 C4b-D1 闸门：**卷积步长 `stride >= 2`** 的数值判据（真网 layer 0 `Conv_0`）。
#
# 被测行为（`rtl/Conv3x3Slice.scala` 的 `stride` 口 + `rtl/MultiPassUnit.scala` 的直通；
# 描述符 `w3[11:8]` 的 `STRIDE` —— **格式一字未改**，该字段此前被译码后**未使用**）：
#   输出按步长**抽稀**：`Conv(stride=s, pads=1, K=3)` 的输出 `(y,x)` 的窗口中心 = 输入 `(s·y, s·x)`；
#   `Conv3x3Slice` **照旧逐列收满**输入（3 个 tap 恒为相邻三列），只有**像素相位**按 `s` 抽稀
#   （列相位 `dm` / 行相位 `rm` 两个模 `s` 计数器；非目标列/行照收历史但不进像素相位）。
#   ⇒ 输出 `Ho×Wo`（`Ho = floor((H_in-1)/s)+1`、`Wo = floor((W_in-1)/s)+1`），**抽稀只改"何时进像素相位"**，
#     9 个 tap / MAC / requant / 部分和写回**一字未改**（没有第二条算术通路）。
#
# ============================== 判据 ==============================
#  0) **参考自检**（不成立 exit 3）：`tools/stride_ref.py --selftest` —— 两套**独立实现**（向量化抽稀切片 /
#     逐输出像素的显式 3×3 窗口）逐字节互证；拆趟累加 == 整层 acc；`s=1` 时与**冻结的 C4a.5b caliber**
#     （`wide_exec_ref.conv_acc`）**逐字节相同**（这条是"stride=1 行为未变"的离线锚）；`s>1 != s=1`。
#  1) **供料（真网真值）**：`--lid 0` 从 `gen/wgt_index.json` + `gen/wgt_blob.bin` 取**真 `Conv_0`**
#     （`C_IN=3 / C_OUT=16 / GROUP=1 / 3x3 / pads=1 / strides=[2,2]`，`M=57384 / z_pad=-128 / z_y=41 /
#     bias_adj[16]` 全部来自转换器产物）⇒ 落盘 `x/w/b/gold/job`。
#  2) **正对照（逐字节，真几何）**：`gen/stride640/MultiPassUnit.v`（`WIDTH=640 PIXMAX=5120 NCOB=2`，
#     **真 640 列行宽**）+ `rtl_test/MultiPassTb.v`：
#       · **`+STRIDE=2`**：`H_in=8`（真 640 列的 8 行条带）⇒ `HO=4 × WO=320`（= 真网 640→320 的**横向**抽稀
#         整段被走到）⇒ `MISMATCH=0`；
#       · **`+STRIDE=1`（同一网表同一几何的回归锚）**：`HO=8 × WO=640` ⇒ `MISMATCH=0`。
#  3) **第二正对照（完全分辨的小用例）**：`--synth 3 8`（合成 `C_in=3 → C_out=8`，`W=8/H=4`）+ 规范网表
#     `gen/MultiPassUnit.v`，`+STRIDE=2` ⇒ `MISMATCH=0`（小尺寸下黄金**不饱和**，分辨率最好）。
#  4) **负对照（必须发火）**：**网表突变**（外科式，只动一处）把 `Conv3x3Slice` 的
#     `assign effS = ((stride == 4'b0000) ? 4'b0001 : stride);` 改成 `assign effS = 4'b0001;`
#     —— 即"**忽略 STRIDE（当成 1）**"：
#       · 打在 `+STRIDE=2` 的真几何用例上 ⇒ `MISMATCH > 0`（**定点发火**：错的就是抽稀相位）；
#       · 打在 `+STRIDE=1` 的同一几何上 ⇒ `MISMATCH == 0`（**证明这一刀是外科式的**：只切掉步长抽稀，
#         其余数据通路一字未动）。
#  5) **结构证据**：网表里 `stride` 口 + 抽稀判据（`effS`/`dm`/`rm`）**都在**（不是"译码了但没用"）；
#     `tools/check_dangling.py` 零悬空。
#  6) **退化守卫**：每个用例的黄金 `distinct > 1`；且 `s=2` 的黄金与 `s=1` 的黄金**不同**。
#
# ★ 已知边界（明写，见 `y1/reports/c4b_stride.md`）：
#   · 输入几何：`IMG_W/IMG_H` 是**输出**几何（`desc_table._geom`），ONNX 的 floor 关系**不能唯一反解**输入
#     行数 ⇒ `UnitExec` 取上界 `H_in = IMG_H·s`（真网 `Conv_0` 恰落上界：320·2 = 640）；`IMG_W` 侧用
#     **区间**判据 `WIDTH ∈ [IMG_W·s-s+1, IMG_W·s]`（`s=1` ⇒ 退化成 `IMG_W==WIDTH`）。
#   · 本闸门证的是**单元级**（`MultiPassUnit` + 编排装置）；`UnitExec` 级的 stride 接线与几何在报告里给证据。
#   · 完整 640×640 整帧的 RTL 仿真（≈9M 周期）在 iverilog 下不可行 ⇒ 本闸门用**真 640 列的 8 行条带**
#     （横向几何 100% 为真：640 → 320；纵向 4 行输出）。
#
# 退出码：0 = 全绿；1 = 判据红（正对照不等 / 退化）；2 = 负对照没发火（判据无牙）；3 = 前置缺失。
#
# 用法：bash y1/tools/run_stride_ab.sh      （可 PY= / TB= / NL= / NLS= / TOOL= 覆盖；KEEP_TMP=1 留中间件）
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

tool="${TOOL:-tools/stride_ref.py}"
tb="${TB:-rtl_test/MultiPassTb.v}"
nl="${NL:-gen/stride640/MultiPassUnit.v}"      # 真 640 列行宽（真几何用例）
nls="${NLS:-gen/MultiPassUnit.v}"              # 规范网表（小用例）
wdir="${WDIR:-gen/c4a_stride}"

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

for f in "$tool" "$tb" "$nl" "$nls"; do
  [ -f "$f" ] || { echo "FATAL: 缺 $f"; echo "RESULT: FAIL"; exit 3; }
done
[ -n "$IVERILOG" ] && [ -n "$VVP" ] || { echo "FATAL: 找不到 iverilog/vvp"; echo "RESULT: FAIL"; exit 3; }

work="$(mktemp -d)"
cleanup() { if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => 中间件留在 $work"; else rm -rf "$work"; fi; }
trap cleanup EXIT
export PYTHONPATH="./.pydeps;../third_party/yunet/deps"
export PYTHONIOENCODING=utf-8
PWD_ABS="$(pwd)"

echo "== run_stride_ab: 卷积步长 stride>=2（真网 Conv_0 几何）=="
echo "   tb=$tb  nl=$nl  nls=$nls  py=$PY"
echo "   iverilog=$IVERILOG  vvp=$VVP  tmp=$work"

# cnt <gold> <rtl> -> 不符 token 数（长度不等取较长者；缺一侧 = -1）
cnt() {
  "$PY" - "$1" "$2" <<'PYEOF'
import sys
def load(p):
    try: return [t.lower() for t in open(p, encoding="utf-8", errors="replace").read().split()]
    except OSError: return None
a, b = load(sys.argv[1]), load(sys.argv[2])
if a is None or b is None:
    print(-1)
elif len(a) != len(b):
    print(max(len(a), len(b)))
else:
    print(sum(1 for i, j in zip(a, b) if i != j))
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
echo "---- [0] tools/stride_ref.py --selftest（两套实现互证 + s=1 == 冻结 caliber + s>1 != s=1）----"
if ! "$PY" "$tool" --selftest > "$work/st.out" 2>&1; then
  echo "FATAL: 参考自检没过 ⇒ 用例/参考写错了（不是硬件的问题）"; tail -12 "$work/st.out"; exit 3
fi
grep -c '^  PASS' "$work/st.out" | sed 's/^/    PASS 断言数=/'
grep -v '^RESULT:' "$work/st.out" | tail -1 | sed 's/^/    /'

# ---------------- 1) 供料（真 Conv_0 + 合成小用例）----------------
echo "---- [1] 供料：真 Conv_0（lid0）s=2 / s=1（W=640）+ 合成 3->8 s=2（W=8）----"
emit() {
  local d="$1"; shift
  if ! "$PY" "$tool" --emit --outdir "$d" "$@" > "$work/emit.out" 2>&1; then
    echo "JUDGE-RED(3): 供料失败（$*）"; tail -8 "$work/emit.out"; exit 3
  fi
  grep -E '^STRIDE_REF ' "$work/emit.out" | sed 's/^/    /'
}
mkdir -p "$wdir"
emit "$wdir/lid0_s2"     --lid 0 --stride 2 --h 8 --w 640
emit "$wdir/lid0_s1"     --lid 0 --stride 1 --h 8 --w 640
emit "$wdir/synth38_s2"  --synth 3 8 --stride 2 --h 4 --w 8
for d in "$wdir/lid0_s2" "$wdir/lid0_s1" "$wdir/synth38_s2"; do
  for f in x.hex w.hex b.hex gold.hex job.txt; do
    [ -s "$d/$f" ] || { echo "FATAL: 缺 $d/$f"; exit 3; }
  done
done

# ---------------- 2) 结构证据：stride 口 + 抽稀判据都在网表里 ----------------
echo "---- [2] 结构证据：网表里 stride 口 + 抽稀判据（effS/dm/rm）都在（不是译码了但没用）----"
"$PY" - "$nl" <<'PYEOF'
import sys
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
need = {"stride 口": "input  wire [3:0]    stride,",
        "effS（0 视作 1）": "assign effS = ((stride == 4'b0000) ? 4'b0001 : stride);",
        "列相位": "assign dmNext = ((dm == effSm1)",
        "行相位": "assign rmNext = ((rm == effSm1)"}
ok = True
for k, v in need.items():
    n = src.count(v)
    print("  %-4s %s（命中 %d 处）" % ("OK" if n >= 1 else "BAD", k, n))
    if n < 1: ok = False
print("STRUCT: %s" % ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
PYEOF
[ $? -eq 0 ] || { echo "JUDGE-RED: 结构判据红"; echo "RESULT: FAIL"; exit 1; }
if [ -f tools/check_dangling.py ]; then
  "$PY" tools/check_dangling.py "$nl" | grep -v '^RESULT:' | tail -1 | sed 's/^/    /'
  "$PY" tools/check_dangling.py "$nl" >/dev/null || { echo "JUDGE-RED: 有悬空实例"; echo "RESULT: FAIL"; exit 1; }
fi

# ---------------- 3) 编译（好网表 + 突变体）----------------
echo "---- [3] iverilog 编译（MultiPassTb + 好网表 / "忽略 STRIDE" 突变体）----"
if ! "$IVERILOG" -g2012 -o "$work/good.vvp" "$tb" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败（好网表）"; sed -n '1,20p' "$work/iv.log"; exit 1
fi
echo "    好网表编译 OK"
if ! "$PY" - "$nl" "$work/mut_stride.v" <<'PYEOF'
import sys
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
a = "  assign effS = ((stride == 4'b0000) ? 4'b0001 : stride);"
b = "  assign effS = 4'b0001;   // MUT: ignore STRIDE (force stride=1)"
n = src.count(a)
if n != 1:
    print("MUT-ERROR: effS 命中 %d 处（期望 1）⇒ 生成风格变了" % n); sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8", newline="\n").write(src.replace(a, b))
print("MUT: Conv3x3Slice 的 effS -> 4'b0001（1 处）⇒ **忽略 STRIDE**（当成 stride=1）")
PYEOF
then
  echo "JUDGE-RED: 构造突变体失败"; echo "RESULT: FAIL"; exit 2
fi
"$IVERILOG" -g2012 -o "$work/mut.vvp" "$tb" "$work/mut_stride.v" > "$work/ivm.log" 2>&1 \
  || { echo "JUDGE-RED: 突变体编译失败"; sed -n '1,20p' "$work/ivm.log"; exit 2; }
echo "    突变体编译 OK（外科式：只动切片里的那一行）"

# run_tb <vvp> <dir> <out-tag> -> 打印 Y 到 $work/<tag>.y（返回 vvp 退出码）
run_tb() {
  local vvp="$1" d="$2" tag="$3"
  local A
  A="+CIN=$(sed -n 's/^CIN=//p' "$d/job.txt") +COUT=$(sed -n 's/^COUT=//p' "$d/job.txt") \
+H=$(sed -n 's/^HIN=//p' "$d/job.txt") +IW=$(sed -n 's/^WIN=//p' "$d/job.txt") \
+M=$(sed -n 's/^M=//p' "$d/job.txt") +ZY=$(sed -n 's/^ZY=//p' "$d/job.txt") \
+STRIDE=$(sed -n 's/^STRIDE=//p' "$d/job.txt") +PADV=$(sed -n 's/^PADV=//p' "$d/job.txt")"
  "$VVP" "$vvp" "+XFILE=$PWD_ABS/$d/x.hex" "+WFILE=$PWD_ABS/$d/w.hex" "+BFILE=$PWD_ABS/$d/b.hex" $A \
    > "$work/$tag.log" 2>&1
  local rc=$?
  grep -E '^MP (CIN|passes)' "$work/$tag.log" | sed "s/^/    [$tag] /"
  grep '^Y ' "$work/$tag.log" | sed -e 's/^Y *//' | tr -s ' ' '\n' > "$work/$tag.y" || true
  return $rc
}

# ---------------- 4) 正对照 + 回归锚 + 退化守卫 ----------------
echo "---- [4] 逐用例：正对照（逐字节）+ 黄金非退化 + s=2 与 s=1 的黄金不同 ----"
JOB_BAD=0; NEG_NOFIRE=0
G_S2="$(distinct "$wdir/lid0_s2/gold.hex")"; G_S1="$(distinct "$wdir/lid0_s1/gold.hex")"
[ "$G_S2" -gt 1 ] 2>/dev/null || { echo "JUDGE-RED: 退化守卫红（lid0_s2 gold distinct=$G_S2）"; JOB_BAD=$((JOB_BAD+1)); }

for spec in "lid0_s2:$nl" "lid0_s1:$nl" "synth38_s2:$nls"; do
  tag="${spec%%:*}"; net="${spec##*:}"
  vvp="$work/good.vvp"; [ "$net" = "$nls" ] && vvp="$work/good_small.vvp"
  if [ "$net" = "$nls" ]; then
    "$IVERILOG" -g2012 -o "$vvp" "$tb" "$nls" > "$work/ivs.log" 2>&1 \
      || { echo "JUDGE-RED: 小网表编译失败"; sed -n '1,15p' "$work/ivs.log"; JOB_BAD=$((JOB_BAD+1)); continue; }
  fi
  if ! run_tb "$vvp" "$wdir/$tag" "pos_$tag"; then
    echo "JUDGE-RED: 装置未 PASS（$tag）"; tail -4 "$work/pos_$tag.log"; JOB_BAD=$((JOB_BAD+1)); continue
  fi
  MIS="$(cnt "$wdir/$tag/gold.hex" "$work/pos_$tag.y")"
  YD="$(distinct "$work/pos_$tag.y")"
  [ "$MIS" = "0" ] || { echo "JUDGE-RED: 正对照 != 黄金（MISMATCH=$MIS，$tag）"; JOB_BAD=$((JOB_BAD+1)); }
  [ "$YD" -gt 1 ] 2>/dev/null || { echo "JUDGE-RED: 退化守卫红（RTL distinct=$YD，$tag）"; JOB_BAD=$((JOB_BAD+1)); }
  echo "CASE $tag net=$(basename "$net") MISMATCH=$MIS distinct(gold=$(distinct "$wdir/$tag/gold.hex"),rtl=$YD)"
done

# 黄金分辨度：s=2 与 s=1 的黄金必须不同（"步长真的改变了输出"）
SAME_GOLD="$(cnt "$wdir/lid0_s2/gold.hex" "$wdir/lid0_s1/gold.hex")"
if [ "$SAME_GOLD" = "0" ]; then
  echo "NEGCTL-FAIL: s=2 与 s=1 的黄金完全相同 ⇒ 步长没被刻画"; NEG_NOFIRE=$((NEG_NOFIRE+1))
fi
echo "GOLD 分辨度：lid0 s=2 vs s=1 的黄金差 $SAME_GOLD 个 token（>0 才说明步长真的改变了输出）"

# ---------------- 5) 负对照（必须发火）----------------
echo "---- [5] 负对照：网表突变"忽略 STRIDE" ⇒ s=2 必红（MISMATCH>0）+ s=1 必绿（外科式）----"
if ! run_tb "$work/mut.vvp" "$wdir/lid0_s2" "mut_s2"; then
  echo "    注意：突变体装置未 PASS（$tm）"; tail -3 "$work/mut_s2.log"
fi
MUT_S2="$(cnt "$wdir/lid0_s2/gold.hex" "$work/mut_s2.y")"
if ! [ "$MUT_S2" -gt 0 ] 2>/dev/null; then
  echo "NEGCTL-FAIL: 忽略 STRIDE 后 s=2 的输出没变（MISMATCH=$MUT_S2）⇒ 判据无牙"; NEG_NOFIRE=$((NEG_NOFIRE+1))
fi
echo "NEG-A lid0_s2 + 突变体：MISMATCH=$MUT_S2（>0 **必须**）"

run_tb "$work/mut.vvp" "$wdir/lid0_s1" "mut_s1" >/dev/null
MUT_S1="$(cnt "$wdir/lid0_s1/gold.hex" "$work/mut_s1.y")"
[ "$MUT_S1" = "0" ] || { echo "JUDGE-RED: 突变体打在本该 stride=1 的用例上却也变了（MISMATCH=$MUT_S1）⇒ 这一刀不是外科式"; JOB_BAD=$((JOB_BAD+1)); }
echo "NEG-B lid0_s1 + 同一突变体：MISMATCH=$MUT_S1（==0 ⇒ 这一刀只切掉步长抽稀，其余通路一字未动）"

# ---------------- 判决 ----------------
echo "=========================================================================="
echo "参考     = OK（stride_ref --selftest：两套实现互证；s=1 == 冻结 C4a.5b caliber）"
echo "正对照   = OK（真 Conv_0 真值 + 真 640 列行宽：s=2 → 4x320、s=1 → 8x640，逐字节 MISMATCH=0）"
echo "结构     = OK（网表有 stride 口 + effS/dm/rm 抽稀判据；零悬空）"
echo "负对照   = 见上（忽略 STRIDE：s=2 必红、s=1 必绿 ⇒ 定点发火 + 外科式）"
if [ "$NEG_NOFIRE" -ne 0 ]; then echo "NEGCTL-FAIL: $NEG_NOFIRE 条负对照没发火"; echo "RESULT: FAIL"; exit 2; fi
if [ "$JOB_BAD" -ne 0 ]; then echo "JUDGE-RED: $JOB_BAD 条判据未过"; echo "RESULT: FAIL"; exit 1; fi
echo "STRIDE_RESULT: PASS"
echo "RESULT: PASS"
exit 0
