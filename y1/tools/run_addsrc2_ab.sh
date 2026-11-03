#!/usr/bin/env bash
# run_addsrc2_ab.sh —— y1 C4b-E1 闸门：**`Add` 的第二路源（保留位「表内偏移」约定）**。
#
# 为什么需要它：冻结的 8 字描述符只有一个 `SRC_ADDR`，而 `Add` 是唯一双输入单元。E1 把第二路源
#   表达成 **`w3[31:16] = SRC2_K`**（= 表序下行 k 位那条描述符的 `DST_ADDR`，spec §4.6）——
#   `LayerSched` 用**表内 DST 历史**把它查出来喂给 `BypassExec.io.src2`；`BypassExec` 据此走
#   **两趟读**（A 从 `SRC_ADDR`、B 从 `src2`）并逐列饱和相加。本闸门钉的是**这条新通路**。
#
# ============================== 判据 ==============================
#  0) **供料自检**（`tools/add_src2_ref.py --selftest`）：两条独立实现互证 + 三条非退化断言
#     （A/B/C 两两不同 / 黄金 != "错 k"预测 / 饱和点 > 0）⇒ 负对照不可能是橡皮章。
#  1) **正对照（真表两个 Add）**：`Add_44`（IMG 40x40）与 `Add_50`（IMG 80x80），描述符逐字取自
#     `gen/desc.bin`（`C_IN/C_OUT` 投影到 C=8 一个通道块、`SRC/SRC2/DST` 重定位进仿真镜像；
#     `w3[31:16]` 保留真表的 `SRC2_K`）。判据 = `COL_MISMATCH=0`（DUT 的 B 列流逐字节 == B）
#     **且** `DST_MISMATCH=0`（主口真实写出的字节 == `clamp8(A+B)`）⇒ "Add 读两路源"的逐字节证据。
#     ★ 每个真几何用一份 **WIDTH = IMG_W** 的变体网表（`BypassExec` 的 `WIDTH` 是展开期常量；
#       add44 -> WIDTH=40、add50 -> WIDTH=80，与 `_w5/_w6` 变体同一手法）。
#  2) **负对照 ①（错 k ⇒ 必须发火，且精确定位）**：把 `+SRC2` 指到 **"k 差一"那一条的 DST 位置**
#     （真表里 `dstHist[(idx-(k+1))]` 会给出的地址，预载一个**不同的** C 图案）⇒
#       · vs 黄金：`DST_MISMATCH>0` + 报 `DST_FIRST_BAD`（**可定位**）+ 装置 FAIL；
#       · vs **C 的预测**：装置输出**精确命中** `clamp8(A+C)`（`COL/DST_MISMATCH=0`）⇒ 读的就是"邻居缓冲"。
#  3) **负对照 ②（网表突变：src2 读偏一列）**：外科式突变（scratch 拷贝）把 `mSrc <= src2` 改成
#     `mSrc <= src2 + 8`（B 起始地址偏一个像素）⇒ 正对照作业必须 **RED**（`DST_MISMATCH>0`）。
#  4) **负对照 ③（描述符突变：`SRC2_K` 清零）**：把真表 `w3` 的高 16 位清 0 ⇒ DUT 退回 C3.7 的**列交织**
#     旧约定（从 `SRC_ADDR` 读 2 倍）⇒ 输出 **RED**（证明 `SRC2_K` 这一位**承重**，不是装饰）。
#  5) **结构 / 确定性**：`check_dangling.py gen/BypassExec.v` 零悬空；**规范网表**重生成 2× 逐字节相同。
#  6) **转换器回归**：重跑 `tools/run_convert_ab.sh` ⇒ `SRC_WRITTEN ok=1`（H1）**且** `SRC2_CORRECT ok=1`
#     （E1：每个 Add 的 `SRC2_K` == 表序 − 图推导的生产者表序）。
#
# 退出码：0 = PASS；1 = 判据红；2 = 负对照没发火；3 = 前置缺失。
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
command -v "$PY" >/dev/null 2>&1 || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

ref="tools/add_src2_ref.py"
tb="rtl_test/AddSrc2Tb.v"
mm="rtl_test/AxiMemModel.v"
net="gen/BypassExec.v"
dangling="tools/check_dangling.py"
[ -f "$ref" ] || { echo "FATAL: 缺 $ref"; echo "RESULT: FAIL"; exit 3; }
[ -f "$tb" ]  || { echo "FATAL: 缺 $tb";  echo "RESULT: FAIL"; exit 3; }
[ -f "$net" ] || { echo "FATAL: 缺 $net（先跑 BypassExecGen）"; echo "RESULT: FAIL"; exit 3; }
Y1="$(pwd)"

find_tool() { local n="$1" p d; p="$(command -v "$n" 2>/dev/null || true)"
  if [ -z "$p" ]; then for d in /c/msys64/ucrt64/bin /mingw64/bin /usr/bin; do
    if [ -x "$d/$n" ]; then p="$d/$n"; break; fi; done; fi; printf '%s' "$p"; }
IVERILOG="$(find_tool iverilog)"; VVP="$(find_tool vvp)"

work="$(mktemp -d)"; trap 'rm -rf "$work" gen/_eas2_nl40 gen/_eas2_nl80' EXIT
rc=0; neg_fired=0; neg_ok=1; neg_mut=0; neg_k0=0
NL44="gen/_eas2_nl40/BypassExec.v"; NL50="gen/_eas2_nl80/BypassExec.v"

echo "== run_addsrc2_ab: Add 第二路源（表内偏移 k：SRC2 = DST_ADDR[idx-k]）=="
echo "   ref=$ref  tb=$tb  net=$net  tmp=$work"

echo "---- [0] 供料自检（两套实现互证 + 非退化）----"
"$PY" "$ref" --selftest || { echo "RESULT: FAIL"; exit 3; }

# ---------------------------------------------------------------- 供料 ----
echo "---- [1] 供料：真表 Add_44（40x40）+ Add_50（80x80）----"
mk_case() {  # $1 = tag  $2 = layer
  local d="$work/$1"
  "$PY" tools/add_src2_ref.py --layer "$2" --out "$d" 2>&1 | sed 's/^/    /'
  [ -f "$d/job.json" ] || { echo "FATAL: 供料失败 $d"; exit 3; }
}
mk_case add44 Add_44
mk_case add50 Add_50

desc_of() { "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); print(' '.join('%08x'%v for v in d['desc']))" "$1/job.json"; }
field_of() { "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]])" "$1/job.json" "$2"; }

# ---------------------------------------------------------------- 变体网表（WIDTH = IMG_W）----
echo "---- [2a] 生成 WIDTH 变体网表（add44: WIDTH=40 IMG_H_MAX=40；add50: WIDTH=80 IMG_H_MAX=80）----"
printf 'Test/runMain BypassExecGen gen/_eas2_nl40 8 40 40\nTest/runMain BypassExecGen gen/_eas2_nl80 8 80 80\nexit\n' | bash sbt.sh > "$work/gen.log" 2>&1
[ -f "$NL44" ] && [ -f "$NL50" ] || { echo "  变体网表生成失败"; tail -8 "$work/gen.log"; echo "RESULT: FAIL"; exit 1; }
echo "  OK: add44 -> $NL44；add50 -> $NL50"

# ---------------------------------------------------------------- 编译 ----
echo "---- [2b] iverilog 编译（AddSrc2Tb + AxiMemModel + 各档变体网表）----"
compile_case() {  # $1=tag $2=netlist $3=输出名
  local tag="$1" nl="$2" out="$3"; case "$nl" in /*) ;; *) nl="$Y1/$nl" ;; esac
  ( cd "$work/$tag" && iverilog -g2012 -o "$out" -s AddSrc2Tb "$Y1/$tb" "$Y1/$mm" "$nl" )
}
compile_case add44 "$NL44" sim.out || { echo "  compile FAIL [add44]"; echo "RESULT: FAIL"; exit 1; }
compile_case add50 "$NL50" sim.out || { echo "  compile FAIL [add50]"; echo "RESULT: FAIL"; exit 1; }
echo "  compile OK（add44/add50 两档）"

# ---------------------------------------------------------------- 跑一档 ----
run_case() {  # $1=tag $2=src2(空=真表) $3=gold bn $4=col bn $5=w3覆盖(hex,空=真表) $6=sim exe
  local tag="$1" s2_in="$2" goldb="$3" colb="$4" w3ovr="${5:-}" simn="${6:-sim.out}"
  local d="$work/$tag"
  local dd; dd="$(desc_of "$d")"
  local C NPIX OUTPIX SRC SRC2 DST
  C="$(field_of "$d" c_block)"; NPIX="$(field_of "$d" npix)"; OUTPIX="$(field_of "$d" outpix)"
  SRC="$(field_of "$d" src)"; SRC2="$(field_of "$d" src2)"; DST="$(field_of "$d" dst)"
  local s2="$s2_in"; [ -n "$s2" ] || s2="$SRC2"
  set -- $dd
  local a0="$1" a1="$2" a2="$3" a3="$4" a4="$5" a5="$6" a6="$7" a7="$8"
  if [ -n "$w3ovr" ]; then a3="$w3ovr"; fi
  ( cd "$d" && timeout 900 vvp "$simn" \
      "+S0=$a0" "+S1=$a1" "+S2=$a2" "+S3=$a3" "+S4=$a4" "+S5=$a5" "+S6=$a6" "+S7=$a7" \
      "+C=$C" "+NPIX=$NPIX" "+OUTPIX=$OUTPIX" "+SRC=$SRC" "+SRC2=$s2" "+DST=$DST" \
      "+COLFILE=$colb" "+GOLDFILE=$goldb" "+COLOUTFILE=colout.txt" \
      "+MEMFILE=mem.hex" "+DUMPFILE=dump.hex" ) 2>&1 | grep -E "TB ADDS2:|TB-ERROR|^RESULT:|MEM rd="
}

echo "---- [3] 正对照：真表两个 Add（A@SRC、B@SRC2）逐字节 ----"
for t in add44 add50; do
  echo "  [$t]"
  d="$work/$t"; npix="$(field_of "$d" npix)"; outpix="$(field_of "$d" outpix)"
  out="$(run_case "$t" "" goldb.hex colb.hex "" sim.out)"
  echo "$out" | sed 's/^/    /'
  echo "$out" | grep -q "COL_MISMATCH=0" || rc=1
  echo "$out" | grep -q "DST_MISMATCH=0" || rc=1
  echo "$out" | grep -q "RESULT: PASS"   || rc=1
  # 独立计数（AxiMemModel 的总线字节；C=8 ⇒ 两路读 = 2*8*npix、一路写 = 8*outpix）
  echo "$out" | grep -q "MEM rd=$(( 16 * npix ))" || { echo "    MEM rd != $((16*npix))（两路读）"; rc=1; }
  echo "$out" | grep -q "wr=$(( 8 * outpix ))" || { echo "    MEM wr != $((8*outpix))（一路写）"; rc=1; }
done

echo "---- [4] 负对照①：错 k（SRC2 指到邻居缓冲 C）⇒ 必须发火 + 可定位 ----"
for t in add44 add50; do
  d="$work/$t"; s2w="$(field_of "$d" src2w)"
  echo "  [$t: +SRC2=$s2w（k 差一位置），黄金仍是 clamp8(A+B)]"
  out="$(run_case "$t" "$s2w" goldb.hex colb.hex "" sim.out)"
  echo "$out" | sed 's/^/    /'
  echo "$out" | grep -qE "DST_MISMATCH=[1-9]" && neg_fired=1
  echo "$out" | grep -q "DST_FIRST_BAD=[0-9]" || neg_fired=0
  echo "$out" | grep -q "RESULT: FAIL" || neg_fired=0
done
for t in add44 add50; do
  d="$work/$t"; s2w="$(field_of "$d" src2w)"
  out2="$(run_case "$t" "$s2w" wrongb.hex wrongcol.hex "" sim.out)"
  echo "  [$t 精确命中 clamp8(A+C)] $(echo "$out2" | grep -E 'COL_N|COL_MISMATCH|DST_MISMATCH|RESULT:')"
  echo "$out2" | grep -q "COL_MISMATCH=0" || neg_ok=0
  echo "$out2" | grep -q "DST_MISMATCH=0" || neg_ok=0
  echo "$out2" | grep -q "RESULT: PASS"   || neg_ok=0
done
[ "$neg_fired" = "1" ] && [ "$neg_ok" = "1" ] || rc=2

echo "---- [5] 负对照②：网表突变「B 起始地址偏一列」（src2 -> src2+8）⇒ 正对照必须 RED ----"
mut="$work/mut"; mkdir -p "$mut"
"$PY" - "$Y1/$NL44" "$mut/BypassExec.v" <<'PYEOF'
import sys
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
old = "          mSrc <= src2;"
new = "          mSrc <= (src2 + 28'd32);"
assert src.count(old) == 1, "mutation anchor not unique: %d" % src.count(old)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
print("  MUT: %s  ->  %s" % (old.strip(), new.strip()))
PYEOF
( cd "$work/add44" && iverilog -g2012 -o simm.out -s AddSrc2Tb "$Y1/$tb" "$Y1/$mm" "$mut/BypassExec.v" ) \
  || { echo "  mutation compile FAIL"; echo "RESULT: FAIL"; exit 1; }
out="$(run_case add44 "" goldb.hex colb.hex "" simm.out)"
echo "  [add44 + 突变体]"; echo "$out" | sed 's/^/    /'
echo "$out" | grep -qE "DST_MISMATCH=[1-9]" && neg_mut=1
echo "$out" | grep -q "DST_FIRST_BAD=[0-9]" || neg_mut=0
[ "$neg_mut" = "1" ] || rc=2

echo "---- [6] 负对照③：描述符突变「SRC2_K 清零」⇒ DUT 退回列交织 ⇒ 正对照必须 RED ----"
w3="$(desc_of "$work/add44" | cut -d' ' -f4)"
w3z="$("$PY" -c "print('%08x' % (int('$w3',16) & 0xFFFF))")"
echo "  [add44: w3 $w3 -> $w3z（SRC2_K=0 ⇒ 列交织旧通路）]"
out="$(run_case add44 "" goldb.hex colb.hex "$w3z" sim.out)"
echo "$out" | sed 's/^/    /'
echo "$out" | grep -qE "DST_MISMATCH=[1-9]" && neg_k0=1
echo "$out" | grep -q "DST_FIRST_BAD=[0-9]" || neg_k0=0
[ "$neg_k0" = "1" ] || rc=2

echo "---- [7] 结构判据：悬空 + 规范网表确定性 2x ----"
"$PY" "$dangling" "$net" | tail -1 | sed 's/^/    /'
"$PY" "$dangling" "$net" | grep -q "total dangling instances: 0" || rc=1
md5a="$(md5sum "$net" | cut -d' ' -f1)"
printf 'Test/runMain BypassExecGen gen 8 80 40\nexit\n' | bash sbt.sh >/dev/null 2>&1
md5b="$(md5sum "$net" | cut -d' ' -f1)"
if [ "$md5a" = "$md5b" ]; then echo "    DETERMINISM_2X_OK  md5(gen/BypassExec.v)=$md5b"; else echo "    DETERMINISM FAIL $md5a vs $md5b"; rc=1; fi

echo "---- [8] 转换器回归：H1 SRC_WRITTEN + E1 SRC2_CORRECT（重跑转换器闸门）----"
if PY="$PY" bash tools/run_convert_ab.sh > "$work/conv.log" 2>&1; then
  grep -E "SRC_WRITTEN ok=|SRC2_CORRECT ok=|NEGCTL_SRC2_K|^RESULT:" "$work/conv.log" | head -6 | sed 's/^/    /'
  grep -q "SRC_WRITTEN ok=1" "$work/conv.log" || { echo "    SRC_WRITTEN 不是 ok=1"; rc=1; }
  grep -q "SRC2_CORRECT ok=1" "$work/conv.log" || { echo "    SRC2_CORRECT 不是 ok=1"; rc=1; }
else
  echo "    转换器闸门 FAIL（尾 5 行）："; tail -5 "$work/conv.log" | sed 's/^/    /'; rc=1
fi

echo "--------------------------------------------------------------------------"
if [ "$rc" = "0" ] && [ "$neg_fired" = "1" ] && [ "$neg_ok" = "1" ] && [ "$neg_mut" = "1" ] && [ "$neg_k0" = "1" ]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL (rc=$rc neg_fired=$neg_fired neg_ok=$neg_ok neg_mut=$neg_mut neg_k0=$neg_k0)"
fi
exit "$rc"
