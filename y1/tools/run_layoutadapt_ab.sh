#!/usr/bin/env bash
# run_layoutadapt_ab.sh —— y1 C4b-B4 闸门：**conv 的通道平面 ↔ 旁路单元的 NHWC 列流**（消费者侧 strided read）。
#
# 为什么需要它：B3（`reports/c4b_input_layout.md`）冻结了"DDR 上激活张量是**通道平面**（NCHW）"，
#   而四个旁路单元的自然流形状是 NHWC（一拍一列 = 一个像素的 C 个通道）。真网里 `conv -> maxpool`
#   的相邻对正是"生产者写平面、消费者按步长读"——本闸门钉的就是**消费侧那一步**（`BypassExec` 的
#   `src_planar`/`dst_planar`，投递 = 信箱区域 7 道 2 按 `LAYER_ID` 索引，见 `LayerSched.scala`）。
#
# ============================== 判据 ==============================
#  0) **供料自检**（`tools/layout_adapt_ref.py --selftest`）：两条独立实现互证 + 三条非退化断言
#     （源非常数 / 列流 != "连续读"预测 / 黄金 != 负对照黄金）⇒ 负对照不可能是橡皮章。
#  1) **正对照（逐列逐通道 + 数值端到端）**：
#     · 真表几何（`MaxPool_25`：`IMG_W=IMG_H=40`，描述符逐字取自 `gen/desc.bin`；`C_IN/C_OUT` 投影到
#       本代旁路通路的档位 C=8 即"一个通道块"、`SRC/DST` 重定位进仿真镜像 —— 都在报告里明写）；
#     · `+SPLANAR=1 +DPLANAR=1`：DUT 从**平面**张量按步长 `HW` gather 出列流、再把输出按平面写回；
#     · 判据 = `COL_MISMATCH=0`（**被单元收下的每一列**逐字节 == 参考的列流）**且**
#       `DST_MISMATCH=0`（主口**真实写出的字节**按平面序 == 黄金）⇒ 这就是 conv->bypass 与
#       bypass->conv 的**逐字节交接**（交接面上的字节两边都验过）。
#  2) **回归锚（模式 0 = 今天的线性 NHWC）**：同一几何、同一张图按 NHWC 摆、`+SPLANAR=0 +DPLANAR=0`
#     ⇒ `DST_MISMATCH=0` **且列流逐字节相同**（两模式的列流本来就是同一条，见供料注释）⇒
#     证明本片是**加法**：默认两位为 0 时与改动前**逐字节同形**。
#  3) **负对照（必须发火）**：外科式网表突变（scratch 拷贝，绝不动 `gen/`）把 gather 的
#     **平面步长丢掉**（`pgAddrR + inColsR` -> `pgAddrR + 32`，即"连续读"）⇒
#       · 平面档（正对照的同一作业）必须 **RED**，且 `COL_FIRST_BAD` 把**首个坏列**定出来；
#       · 模式 0 档（同一突变体）必须 **GREEN**（它根本不走 gather）⇒ 这一刀是**外科式**的。
#  4) **结构判据**：`check_dangling.py gen/BypassExec.v` 零悬空；网表**确定性 2×**（重生成逐字节相同）。
#  5) **H1 的 SRC 自洽**（本任务的第三条 DoD）：重跑 `tools/run_convert_ab.sh`，要求 `SRC_WRITTEN ok=1`
#     （每个 `SRC_ADDR` 都写在读之前）+ 该闸门整体 PASS ⇒ 本片没有动描述符/地址折进。
#
# 退出码：0 = PASS；1 = 判据红；2 = 负对照没发火；3 = 前置缺失。
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
command -v "$PY" >/dev/null 2>&1 || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

ref="tools/layout_adapt_ref.py"
tb="rtl_test/LayoutAdaptTb.v"
mm="rtl_test/AxiMemModel.v"
net="gen/BypassExec.v"
dangling="tools/check_dangling.py"
[ -f "$ref" ] || { echo "FATAL: 缺 $ref"; echo "RESULT: FAIL"; exit 3; }
[ -f "$tb" ]  || { echo "FATAL: 缺 $tb";  echo "RESULT: FAIL"; exit 3; }
[ -f "$net" ] || { echo "FATAL: 缺 $net（先跑 BypassExecGen）"; echo "RESULT: FAIL"; exit 3; }
Y1="$(pwd)"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
rc=0; neg_fired=0; neg_ok=0

echo "== run_layoutadapt_ab: 布局适配（conv 通道平面 <-> 旁路 NHWC 列流）=="
echo "   ref=$ref  tb=$tb  net=$net  tmp=$work"

echo "---- [0] 供料自检（两套实现互证 + 非退化）----"
"$PY" "$ref" --selftest || { echo "RESULT: FAIL"; exit 1; }

# ---------------------------------------------------------------- 供料 ----
echo "---- [1] 供料：真表 MaxPool_25（IMG 40x40 与 40x8 条带）----"
mk_case() {  # $1 = tag  $2 = img_h
  local d="$work/$1"
  "$PY" tools/layout_adapt_ref.py --layer MaxPool_25 --img-h "$2" --out "$d" 2>&1 | sed 's/^/    /'
  [ -f "$d/job.json" ] || { echo "FATAL: 供料失败 $d"; exit 3; }
}
mk_case A 40; mk_case B 8

desc_of() { "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); print(' '.join('%08x'%v for v in d['desc']))" "$1/job.json"; }
field_of() { "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]])" "$1/job.json" "$2"; }

# ---------------------------------------------------------------- 编译 ----
echo "---- [2] iverilog 编译（LayoutAdaptTb + AxiMemModel + gen/BypassExec.v）----"
compile_all() {  # $1 = netlist path（绝对或相对 y1/）  $2 = 输出名
  local nl="$1"; case "$nl" in /*) ;; *) nl="$Y1/$nl" ;; esac
  for d in A B; do
    ( cd "$work/$d" && iverilog -g2012 -o "$2" -s LayoutAdaptTb "$Y1/$tb" "$Y1/$mm" "$nl" ) || return 1
  done
}
compile_all "$net" sim.out || { echo "  compile FAIL"; echo "RESULT: FAIL"; exit 1; }
echo "  compile OK（A/B 两档）"

# ---------------------------------------------------------------- 跑一档 ----
run_case() {  # $1=tag $2=splanar $3=dplanar $4=memfile $5=goldfile $6=净表输入路径 $7=sim 可执行名
  local d="$work/$1"
  local sp="$2" dp="$3" memf="$4" goldf="$5" simn="${7:-sim.out}"
  local dd; dd="$(desc_of "$d")"
  local C NPIX OUTPIX SRC DST
  C="$(field_of "$d" c_block)"; NPIX="$(field_of "$d" npix)"; OUTPIX="$(field_of "$d" outpix)"
  SRC="$(field_of "$d" src)"; DST="$(field_of "$d" dst)"
  set -- $dd
  ( cd "$d" && timeout 900 vvp "$simn" \
      "+S0=$1" "+S1=$2" "+S2=$3" "+S3=$4" "+S4=$5" "+S5=$6" "+S6=$7" "+S7=$8" \
      "+SPLANAR=$sp" "+DPLANAR=$dp" "+C=$C" "+NPIX=$NPIX" "+OUTPIX=$OUTPIX" \
      "+SRC=$SRC" "+DST=$DST" \
      "+COLFILE=colb.hex" "+GOLDFILE=$goldf" "+COLOUTFILE=colout.txt" \
      "+MEMFILE=$memf" "+DUMPFILE=dump.hex" ) 2>&1 | grep -E "TB LADAPT: COL_N|TB LADAPT: RESULT|TB-ERROR|^RESULT:"
}

echo "---- [3] 正对照：平面档（SPLANAR=1 DPLANAR=1）----"
for t in A B; do
  echo "  [$t]"
  out="$(run_case "$t" 1 1 mem.hex goldb.hex "$net")"
  echo "$out" | sed 's/^/    /'
  echo "$out" | grep -q "COL_MISMATCH=0" || rc=1
  echo "$out" | grep -q "DST_MISMATCH=0" || rc=1
  echo "$out" | grep -q "RESULT: PASS"   || rc=1
done

echo "---- [4] 回归锚：模式 0（SPLANAR=0 DPLANAR=0，源按 NHWC 摆）----"
out="$(run_case B 0 0 mem_nhwc.hex gold_nhwc.hex "$net")"
echo "$out" | sed 's/^/    /'
echo "$out" | grep -q "DST_MISMATCH=0" || rc=1
echo "$out" | grep -q "RESULT: PASS"  || rc=1

echo "---- [5] 负对照：网表突变「把平面步长丢掉」（连续读）----"
mut="$work/mut"; mkdir -p "$mut"
"$PY" - "$net" "$mut/BypassExec.v" <<'PYEOF'
import sys
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
old = "pgAddrR <= (pgAddrR + inColsR);"
new = "pgAddrR <= (pgAddrR + 32'd32);"
assert src.count(old) == 1, "mutation anchor not unique: %d" % src.count(old)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
print("  MUT: %s  ->  %s" % (old, new))
PYEOF
compile_all "$mut/BypassExec.v" simm.out || { echo "  mutation compile FAIL"; echo "RESULT: FAIL"; exit 1; }
out="$(run_case B 1 1 mem.hex goldb.hex "$mut/BypassExec.v" simm.out)"
echo "  [B + 突变体（平面档，必须发火）]"; echo "$out" | sed 's/^/    /'
echo "$out" | grep -qE "COL_MISMATCH=[1-9]" && neg_fired=1
echo "$out" | grep -q "COL_FIRST_BAD=[0-9]" || neg_fired=0
out2="$(run_case B 0 0 mem_nhwc.hex gold_nhwc.hex "$mut/BypassExec.v" simm.out)"
echo "  [B + 同一突变体（模式 0，必须仍绿 = 外科式）]"; echo "$out2" | sed 's/^/    /'
echo "$out2" | grep -q "DST_MISMATCH=0" && neg_ok=1
[ "$neg_fired" = "1" ] && [ "$neg_ok" = "1" ] || rc=2

echo "---- [6] 结构判据：悬空 + 网表确定性 2x ----"
"$PY" "$dangling" "$net" | tail -1 | sed 's/^/    /'
"$PY" "$dangling" "$net" | grep -q "total dangling instances: 0" || rc=1
md5a="$(md5sum "$net" | cut -d' ' -f1)"
printf 'Test/runMain BypassExecGen gen 8 80 40\nexit\n' | bash sbt.sh >/dev/null 2>&1
md5b="$(md5sum "$net" | cut -d' ' -f1)"
if [ "$md5a" = "$md5b" ]; then echo "    DETERMINISM_2X_OK  md5(gen/BypassExec.v)=$md5b"; else echo "    DETERMINISM FAIL $md5a vs $md5b"; rc=1; fi

echo "---- [7] H1 的 SRC 自洽（重跑转换器闸门）----"
if PY="$PY" bash tools/run_convert_ab.sh > "$work/conv.log" 2>&1; then
  grep -E "SRC_WRITTEN ok=|^RESULT:" "$work/conv.log" | head -4 | sed 's/^/    /'
  grep -q "SRC_WRITTEN ok=1" "$work/conv.log" || { echo "    SRC_WRITTEN 不是 ok=1"; rc=1; }
else
  echo "    转换器闸门 FAIL（尾 5 行）："; tail -5 "$work/conv.log" | sed 's/^/    /'; rc=1
fi

echo "---- [8] 真表交接面（旁路 DST == 其消费 conv 的 SRC）----"
"$PY" - <<'PYEOF' | sed 's/^/    /'
import json, struct, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
idx = json.load(open("gen/wgt_index.json", encoding="utf-8"))
blob = open("gen/desc.bin", "rb").read()
def dw(i): return list(struct.unpack("<8I", blob[i*32:(i+1)*32]))
for u in idx["units"]:
    if u["op"] in ("MaxPool", "Resize", "Sigmoid"):
        w = dw(u["idx"])
        print("LAYER %-12s %-8s IMG=%dx%d C=%d->%d SRC=%#010x DST=%#010x" %
              (u["name"], u["op"], (w[1] >> 16) & 0xFFFF, w[1] & 0xFFFF,
               (w[2] >> 16) & 0xFFFF, w[2] & 0xFFFF, w[4], w[5]))
    if u["op"] in ("Conv",):
        pass
cons = {}
for i, u in enumerate(idx["units"]):
    cons.setdefault(u["in_tensor"], []).append(u["name"])
for u in idx["units"]:
    if u["op"] in ("MaxPool",):
        cs = cons.get(u["out_tensor"], [])
        if cs:
            j = [k for k, v in enumerate(idx["units"]) if v["name"] == cs[0]][0]
            print("HANDOFF %-12s DST=%#010x  ->  %-10s SRC=%#010x  %s" %
                  (u["name"], dw(u["idx"])[5], cs[0], dw(j)[4],
                   "SAME" if dw(u["idx"])[5] == dw(j)[4] else "DIFF"))
PYEOF

echo "--------------------------------------------------------------------------"
if [ "$rc" = "0" ] && [ "$neg_fired" = "1" ] && [ "$neg_ok" = "1" ]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL (rc=$rc neg_fired=$neg_fired neg_surgical=$neg_ok)"
fi
exit "$rc"
