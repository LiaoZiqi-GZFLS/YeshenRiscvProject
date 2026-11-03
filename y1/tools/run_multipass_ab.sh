#!/usr/bin/env bash
# run_multipass_ab.sh —— y1 C4a.5a 闸门：**宽层多趟累加（片上部分和）+ §4.4 requant 乘子**的数值判据。
#
# 被测行为（`rtl/PartialSumBuf.scala` + `rtl/Conv3x3Slice.scala` 的新口 + `rtl/MultiPassUnit.scala`）：
#   一个"宽层"（C_in > 8 或 C_out > 8）拆成 `ceil(C_in/8) × ceil(C_out/8)` 趟（C4a.4 冻结规则）；
#   每趟 = `Conv3x3Slice` 的一次流式通过；部分和在**片上** `PartialSumBuf`（`readSync` + 上电初值 0 ⇒
#   block RAM 结构）里跨 `ci` 趟累加（**32 bit**，★ §3.7：行宽 64→32 bit，缺省 `PSW=32`）；末趟做**唯一一次** §4.4 requant
#   `((acc·M) >> 24) >> 6 + z_y`。**编排器 = 装置**（`rtl_test/MultiPassTb.v`；C4a.5b 里换成 `UnitExec`）。
#
# ============================== 判据 ==============================
#  0) **参考自检**（python；不成立 exit 3）：`tools/multipass_ref.py --selftest`
#     · 拆趟 == 整层（C4a.4 的 `conv_tiled` 逐字复用）+ int32 恒等；
#     · **四份预测都有牙**（M=2^24 / 漏一趟 / 不写回 / 初值非 0 的预测都必须 != 黄金）；
#     · 黄金非退化（distinct > 1）。
#  1) **参考供料**：`--gate` 对**真表（`gen/c4a_tiling/c4a_tiling.json`）里每一种宽 `(C_in,C_out,GROUP)`**
#     造一个确定性层，断言 `conv_tiled == conv_vec`（整层）、黄金非退化、四份预测都有牙；落盘
#     `x/w/b` + 五份黄金到 `gen/c4a_mp/shape_*/`。
#  2) **正对照（逐字节）**：对每个宽形状跑 RTL 多趟 ⇒ `Y == gold.hex`（`MISMATCH=0`）。
#  3) **乘子确实生效（§4.4）**：同一形状改用 `+M=2^24`（单位乘子）⇒ `Y == gold_unity.hex`（**精确命中**，
#     即 `((acc·2^24)>>24)>>6 == acc>>6`）**且** `!= gold.hex`（真乘子与单位乘子给出的结果不同）。
#  4) **负对照 A1（漏一趟）**：`+DROPCI=0`（该 `ci` 趟整趟不喂）⇒ `Y == gold_drop.hex`（**精确命中**
#     C4a.4 `conv_tiled(drop_ci_block=0)` 的预测）**且** `!= gold.hex`。
#  5) **负对照 A2（部分和从不写回）**：scratch 拷贝网表，把 `PartialSumBuf` 的写口钉成 0（只动这一处）
#     ⇒ `Y == gold_nops.hex`（精确命中"只 requant 末趟 partial"）**且** `!= gold.hex`。
#     ★ 只在 `n_ci ≥ 2` 的形状上有意义（单趟 ⇒ 结构上没有跨趟累加可漏，判据标 N/A）。
#  6) **负对照 B（部分和缓冲初值非 0）**：scratch 拷贝网表，把 `PartialSumBuf` 的 `.init` 初值块的
#     co=0 行改成 `K`（只动这一处）⇒ `Y == gold_mutb.hex`（精确命中 `requant(acc+K)`）**且** `!= gold.hex`。
#     ⇒ 这一发正是"第 1 趟累加器清零（靠**上电初值 0**）"这条口径的牙。
#  7) **退化守卫**：每形状的黄金与 RTL 输出都 `distinct > 1`（防"全 0 也通过"）。
#  8) **结构证据（本片只证"结构对"；DRM 的 `dev_map` 判据是 C4a.5b）**：
#     · `gen/MultiPassUnit.v` 里 `PartialSumBuf` 是**一条 `Mem`**：`reg [255:0] mem [0:255];`
#       （★ §3.7：= C_out 行 × 4 B/32 bit 的字 × `NCOB*PIXMAX` 个字 = 65536 bit **不在 FF 里**）+ **同步读**
#       `mem_spinal_port1 <= mem[rd_addr];`（块 RAM 的标准形态）+ 写侧地址译码 `mem[wr_addr] <= wr_word;`；
#     · 断言：模块内有**恰好一个**存储阵列、**没有**组合读（不存在 `assign rd_data_N = mem[...]`）；
#     · `tools/check_dangling.py gen/MultiPassUnit.v` 零悬空。
#
# 退出码：0 = 全绿；1 = 判据红（MISMATCH/退化/结构）；2 = 负对照没发火（判据无牙）；3 = 前置缺失。
#
# ★★ 2026-10-11 §4.5-A 重锚（**显式**，不是悄悄放宽）：黄金 `quant_ref.py`（md5
#    d1c75dc262cfd46bb6f7c66bf93ac159，commit a77efb3）改对称权重后逐层张量全变 ⇒ 本闸门消费的
#    `gen/c4a_mp/shape_*/`（x/w/b + 五份黄金 .hex）与 `gen/c4a_tiling/c4a_tiling.json` 的形状集合
#    是**旧口径**缓存，已作废。**本闸门不存硬编码黄金 md5 锚点**：黄金由 `multipass_ref.py` 每次
#    运行**重算**（逐字复用 C4a.4 `conv_tiled` + C4a.2 `conv_vec`）⇒ **自动适配**；重锚 = 重跑刷新
#    `gen/c4a_mp/`（gitignore，不入库）。★ Tb 侧 `z_x = z_w = 0`（**无 zero-point 中心化**）这条
#    **刻意简化保持不变**（本闸门只证多趟算术，中心化由转换器的 §4.5 闸门单独证明）；判据与负对照
#    （M 分辨度 / A1 漏趟 / A2 不写回 / B 初值非 0 / 结构 / 退化守卫）**一字未改**。本次重锚后的产物
#    指纹记在 commit message（**不**在本文件钉 md5 —— 免得下次黄金再变又留一个死锚点）。
#
# 用法：bash y1/tools/run_multipass_ab.sh   （可 PY=<python> 覆盖解释器；KEEP_TMP=1 留中间件）
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

# ★ 可被环境覆盖的口（与既有闸门的 `RTL=` / `TOOL=` 同一套惯例）：**只给发火证据用**——
#   红证据 1（退出 1）= 把 `NL` 指向一份"requant 移位被改"的 scratch 网表；
#   红证据 2（退出 2）= 把 `TB` 指向一份"忽略 +DROPCI"的 scratch 装置（负对照于是发不了火）。
tool="${TOOL:-tools/multipass_ref.py}"
tb="${TB:-rtl_test/MultiPassTb.v}"
nl="${NL:-gen/MultiPassUnit.v}"
shapes="gen/c4a_tiling/c4a_tiling.json"
mpdir="gen/c4a_mp"

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

for f in "$tool" "$tb" "$nl" "$shapes"; do
  [ -f "$f" ] || { echo "FATAL: 缺 $f"; echo "RESULT: FAIL"; exit 3; }
done
[ -n "$IVERILOG" ] && [ -n "$VVP" ] || { echo "FATAL: 找不到 iverilog/vvp"; echo "RESULT: FAIL"; exit 3; }

work="$(mktemp -d)"
cleanup() {
  if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => 中间件留在 $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT

export PYTHONPATH="./.pydeps;../third_party/yunet/deps"
export PYTHONIOENCODING=utf-8

echo "== run_multipass_ab: 宽层多趟累加（片上部分和 32bit，★ §3.7）+ §4.4 requant 乘子 =="
echo "   tb=$tb  nl=$nl"
echo "   py=$PY  iverilog=$IVERILOG  vvp=$VVP"
echo "   tmp=$work"

# cnt <gold-file> <token-file> -> 不符 token 数（长度不等取较长者；任一侧缺失 = -1）
cnt() {
  "$PY" - "$1" "$2" <<'PYEOF'
import sys
def load(p):
    try:
        return [t.lower() for t in open(p, encoding="utf-8", errors="replace").read().split()]
    except OSError:
        return None
a, b = load(sys.argv[1]), load(sys.argv[2])
if a is None or b is None:
    print(-1)
elif len(a) != len(b):
    print(max(len(a), len(b)))
else:
    print(sum(1 for i, j in zip(a, b) if i != j))
PYEOF
}

# distinct <token-file> -> 不同 token 个数
distinct() {
  "$PY" - "$1" <<'PYEOF'
import sys
try:
    t = open(sys.argv[1], encoding="utf-8", errors="replace").read().split()
except OSError:
    print(-1); sys.exit(0)
print(len(set(x.lower() for x in t)) if t else -1)
PYEOF
}

# ---------------- 0) 参考自检 ----------------
echo "---- [0] tools/multipass_ref.py --selftest（拆趟==整层 + 四份预测都有牙 + 退化守卫）----"
if ! "$PY" "$tool" --selftest > "$work/st.out" 2> "$work/st.err"; then
  echo "FATAL: 参考自检没过 ⇒ 用例/参考写错了（不是硬件的问题）"; tail -20 "$work/st.out"; exit 3
fi
grep -c '^  PASS' "$work/st.out" | sed 's/^/    PASS 断言数=/'
# 只印自检的汇总行（**过滤掉**子工具的 `RESULT:` ⇒ 整条闸门最后只有**一行** `RESULT: PASS`）
grep -v '^RESULT:' "$work/st.out" | tail -1 | sed 's/^/    /'

# ---------------- 1) 参考供料（真表宽形状）----------------
echo "---- [1] 参考供料：真表宽形状（conv_tiled == conv_vec；四份预测都有牙；落盘 gen/c4a_mp）----"
if ! "$PY" "$tool" --gate --outdir "$mpdir" > "$work/refgate.out" 2> "$work/refgate.err"; then
  echo "JUDGE-RED: 参考供料未过（拆趟 != 整层 / 黄金退化 / 负对照没牙）"
  tail -10 "$work/refgate.out"; exit 1
fi
grep -E '^(GATE|SHAPES_WIDE|MULTIPASS_REF)' "$work/refgate.out" | sed 's/^/    /'
N_SHAPES="$(grep -oE '^SHAPES_WIDE=[0-9]+' "$work/refgate.out" | head -1 | cut -d= -f2)"
[ -n "$N_SHAPES" ] && [ "$N_SHAPES" -gt 0 ] || { echo "FATAL: 没有宽形状"; exit 3; }

# ---------------- 2) 结构证据：PartialSumBuf 必须是 block RAM 结构 ----------------
echo "---- [2] 结构证据：PartialSumBuf = 一条 Mem（同步读 + 地址译码写），不是 FF/LUTRAM ----"
"$PY" - "$nl" <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r"^module PartialSumBuf\b.*?^endmodule", src, re.S | re.M)
if not m:
    print("STRUCT-ERROR: 网表里找不到 module PartialSumBuf"); sys.exit(1)
body = m.group(0)
arrs = re.findall(r"reg\s*\[(\d+):0\]\s*(\w+)\s*\[0:(\d+)\]\s*;", body)
print("IBUF mem 阵列声明: %s" % (arrs,))
syncrd = re.findall(r"(\w+)\s*<=\s*mem\[(\w+)\];", body)
wr = re.findall(r"mem\[(\w+)\]\s*<=\s*(\w+);", body)
comb = re.findall(r"assign\s+rd_data_\d+\s*=\s*mem\[", body)
fpga = len(re.findall(r"if\(wr_en\)", body))
ok = True
if len(arrs) != 1:
    print("STRUCT-BAD: 期望恰好 1 个存储阵列，实测 %d" % len(arrs)); ok = False
else:
    w, nm, dep = int(arrs[0][0]) + 1, arrs[0][1], int(arrs[0][2]) + 1
    print("  · 存储阵列 = 1 条 `%s [%d bit] x %d 字` ⇒ %d bit **在 RAM 里，不在 FF 里**" % (nm, w, dep, w * dep))
    print("  · 字 = C_out 行 x 4 B = 256 bit（C_out=8；★ §3.7）；深度 = NCOB*PIXMAX = %d" % dep)
if len(syncrd) != 1:
    print("STRUCT-BAD: 期望恰好 1 处**同步读**（`X <= mem[rd]`），实测 %d" % len(syncrd)); ok = False
else:
    print("  · 同步读 = `%s <= mem[%s]`（块 RAM 的标准形态：读口寄存一拍）" % syncrd[0])
if len(wr) != 1 or fpga != 1:
    print("STRUCT-BAD: 写口形状不符（mem[..]<=.. %d 处 / if(wr_en) %d 处）" % (len(wr), fpga)); ok = False
else:
    print("  · 写口 = `if(wr_en) mem[%s] <= %s`（地址译码写）" % (wr[0][0], wr[0][1]))
if comb:
    print("STRUCT-BAD: 发现**组合读**（`assign rd_data_N = mem[...]`）⇒ 会落 LUTRAM（C3 输出存储那类）"); ok = False
else:
    print("  · 无组合读（对比：C3 的 `UnitExec.outMem` 用 `readAsync` ⇒ LUTRAM；本模块**故意**用同步读）")
init_lines = len(re.findall(r"mem\[\d+\]\s*=\s*\d*'b0+;", body))
print("  · 上电初值 0：%d 个字（`Mem` 无复位 ⇒ '第 1 趟累加器清零'靠它；负对照 B 就打在这里）" % init_lines)
if init_lines != 0 and init_lines != dep:
    print("STRUCT-BAD: 初值块只覆盖 %d/%d 个字" % (init_lines, dep)); ok = False
print("STRUCT: %s" % ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
PYEOF
STRUCT_RC=$?
if [ "$STRUCT_RC" -ne 0 ]; then echo "JUDGE-RED: 结构判据红"; echo "RESULT: FAIL"; exit 1; fi
if [ -f tools/check_dangling.py ]; then
"$PY" tools/check_dangling.py "$nl" | grep -v '^RESULT:' | tail -2 | sed 's/^/    /'
  "$PY" tools/check_dangling.py "$nl" >/dev/null || { echo "JUDGE-RED: 有悬空实例"; echo "RESULT: FAIL"; exit 1; }
fi

# ---------------- 3) 编译三份网表（好 / 写口关掉 / 初值非 0）----------------
echo "---- [3] iverilog 编译（MultiPassTb + 好网表 / 写口关掉突变体 / 初值非 0 突变体）----"
if ! "$IVERILOG" -g2012 -o "$work/mp.vvp" "$tb" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败"; sed -n '1,30p' "$work/iv.log"; exit 1
fi
echo "    好网表编译 OK"

# 突变 A2：把 PartialSumBuf 的写口钉成 0（**只动这一处**）
if ! "$PY" - "$nl" "$work/mp_nowrite.v" <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r"^module PartialSumBuf\b.*?^endmodule", src, re.S | re.M)
if not m:
    print("MUT-ERROR: 找不到 module PartialSumBuf"); sys.exit(1)
body, n = re.subn(r"if\(wr_en\) begin", "if(1'b0) begin", m.group(0))
if n != 1:
    print("MUT-ERROR: if(wr_en) 命中 %d 处（期望 1）⇒ 生成风格变了" % n); sys.exit(1)
print("MUT_A2: PartialSumBuf 写口 `if(wr_en)` -> `if(1'b0)`（%d 处）⇒ 部分和从不写回" % n)
open(sys.argv[2], "w", encoding="utf-8", newline="\n").write(src[:m.start()] + body + src[m.end():])
PYEOF
then
  echo "JUDGE-RED: 构造'写口关掉'突变体失败"; echo "RESULT: FAIL"; exit 2
fi
"$IVERILOG" -g2012 -o "$work/mp_nowrite.vvp" "$tb" "$work/mp_nowrite.v" > "$work/iv_nw.log" 2>&1 \
  || { echo "JUDGE-RED: 写口关掉突变体编译失败"; sed -n '1,20p' "$work/iv_nw.log"; exit 2; }

# 突变 B：把 PartialSumBuf 的初值块 co=0 行（低 32 bit）改成 K（**只动这一处**）
if ! "$PY" - "$nl" "$work/mp_initk.v" 13 <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
K = int(sys.argv[3])
m = re.search(r"^module PartialSumBuf\b.*?^endmodule", src, re.S | re.M)
if not m:
    print("MUT-ERROR: 找不到 module PartialSumBuf"); sys.exit(1)
body, n = re.subn(r"(mem\[\d+\]\s*=\s*)256'b0+;", r"\g<1>{192'b0, 64'd%d};" % K, m.group(0))
if n < 1:
    print("MUT-ERROR: 初值块 256'b0... 命中 0 处 ⇒ 生成风格变了"); sys.exit(1)
print("MUT_B: PartialSumBuf 初值块 %d 个字的 co=0 行 -> %d（其余位仍 0）⇒ 第 1 趟读到非 0" % (n, K))
open(sys.argv[2], "w", encoding="utf-8", newline="\n").write(src[:m.start()] + body + src[m.end():])
PYEOF
then
  echo "JUDGE-RED: 构造'初值非 0'突变体失败"; echo "RESULT: FAIL"; exit 2
fi
"$IVERILOG" -g2012 -o "$work/mp_initk.vvp" "$tb" "$work/mp_initk.v" > "$work/iv_ik.log" 2>&1 \
  || { echo "JUDGE-RED: 初值非 0 突变体编译失败"; sed -n '1,20p' "$work/iv_ik.log"; exit 2; }
echo "    两份突变体编译 OK（都是**外科式**：只动 PartialSumBuf 里的那一处）"

# run_tb <vvp> <tag> <shape-dir> <M> <ZY> [extra plusargs...] -> 打印 Y 到 $work/<tag>.y
run_tb() {
  local vvp="$1" tag="$2" d="$3" M="$4" ZY="$5"; shift 5
  local CIN COUT H IW
  CIN="$(sed -n 's/^CIN=//p' "$d/params.txt")"
  COUT="$(sed -n 's/^COUT=//p' "$d/params.txt")"
  H="$(sed -n 's/^H=//p' "$d/params.txt")"
  IW="$(sed -n 's/^IW=//p' "$d/params.txt")"
  ( cd "$work" && "$VVP" "$vvp" \
      "+XFILE=$PWD_ABS/$d/x.hex" "+WFILE=$PWD_ABS/$d/w.hex" "+BFILE=$PWD_ABS/$d/b.hex" \
      "+CIN=$CIN" "+COUT=$COUT" "+H=$H" "+IW=$IW" "+M=$M" "+ZY=$ZY" "$@" ) \
      > "$work/$tag.log" 2>&1
  local rc=$?
  grep -E '^MP ' "$work/$tag.log" | sed "s/^/    [$tag] /"
  grep '^Y ' "$work/$tag.log" | sed -e 's/^Y *//' | tr -s ' ' '\n' > "$work/$tag.y" || true
  return $rc
}
PWD_ABS="$(pwd)"

# ---------------- 4)+5)+6)+7) 逐形状跑 ----------------
echo "---- [4] 逐宽形状：正对照 + M=2^24 + 三条负对照（每条都要求**精确命中预测**且 != 黄金）----"
DEF_IW=8
TOTAL_BAD=0        # 判据红：正对照 != 黄金 / 退化 / 精确命中失败
NEG_NOFIRE=0       # 负对照没发火（预测 == 黄金）
SHAPE_LIST=""

for d in $(ls -d "$mpdir"/shape_* 2>/dev/null | sort); do
  CIN="$(sed -n 's/^CIN=//p' "$d/params.txt")"
  COUT="$(sed -n 's/^COUT=//p' "$d/params.txt")"
  GROUP="$(sed -n 's/^GROUP=//p' "$d/params.txt")"
  H="$(sed -n 's/^H=//p' "$d/params.txt")"
  IW="$(sed -n 's/^IW=//p' "$d/params.txt")"
  M="$(sed -n 's/^M=//p' "$d/params.txt")"
  ZY="$(sed -n 's/^ZY=//p' "$d/params.txt")"
  NCI="$(sed -n 's/^NCI=//p' "$d/params.txt")"
  NCO="$(sed -n 's/^NCO=//p' "$d/params.txt")"
  PASSES="$(sed -n 's/^PASSES=//p' "$d/params.txt")"
  DROPCI="$(sed -n 's/^DROPCI=//p' "$d/params.txt")"
  tagbase="s${CIN}c${COUT}o${GROUP}g"
  SHAPE_LIST="$SHAPE_LIST ${CIN}c${COUT}o${GROUP}g"
  # 清上一形状的统计（否则 n_ci==1 的形状会显示上一条的 DROP/A2 数字 —— 判据本身有守卫，
  # 但报告必须**诚实**：不适用的那一格不能印出别的形状的数）
  U_HIT=-1; U_GOLD=-1; D_HIT=-1; D_GOLD=-1; N_HIT=-1; N_GOLD=-1; B_HIT=-1; B_GOLD=-1
  A2_SHOW="A2=N/A"

  # 退化守卫（黄金 & RTL 输出）
  gd="$(distinct "$d/gold.hex")"

  # (a) 正对照
  if ! run_tb "$work/mp.vvp" "pos_$tagbase" "$d" "$M" "$ZY"; then
    echo "JUDGE-RED: 正对照装置未 PASS（$tagbase）"; tail -6 "$work/pos_$tagbase.log"; TOTAL_BAD=$((TOTAL_BAD+1)); continue
  fi
  POS_MIS="$(cnt "$d/gold.hex" "$work/pos_$tagbase.y")"
  YD="$(distinct "$work/pos_$tagbase.y")"
  [ "$POS_MIS" = "0" ] || { echo "JUDGE-RED: 正对照 !! 黄金（MISMATCH=$POS_MIS，$tagbase）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$gd" -gt 1 ] 2>/dev/null || { echo "JUDGE-RED: 退化守卫红：黄金 distinct=$gd（$tagbase）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$YD" -gt 1 ] 2>/dev/null || { echo "JUDGE-RED: 退化守卫红：RTL 输出 distinct=$YD（$tagbase）"; TOTAL_BAD=$((TOTAL_BAD+1)); }

  # (b) M = 2^24（单位乘子）：精确命中 gold_unity，且 != 黄金
  run_tb "$work/mp.vvp" "unity_$tagbase" "$d" 16777216 "$ZY" >/dev/null
  U_HIT="$(cnt "$d/gold_unity.hex" "$work/unity_$tagbase.y")"
  U_GOLD="$(cnt "$d/gold.hex" "$work/unity_$tagbase.y")"
  [ "$U_HIT" = "0" ] || { echo "JUDGE-RED: M=2^24 未精确命中（$U_HIT，$tagbase）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  if ! [ "$U_GOLD" -gt 0 ] 2>/dev/null; then
    echo "NEGCTL-FAIL: M=2^24 与真乘子结果相同（$tagbase）⇒ 乘子这条路没被验证"; NEG_NOFIRE=$((NEG_NOFIRE+1))
  fi

  # (c) 负对照 A1：漏一趟
  if [ "$NCI" -ge 2 ]; then
    run_tb "$work/mp.vvp" "drop_$tagbase" "$d" "$M" "$ZY" "+DROPCI=$DROPCI" >/dev/null
    D_HIT="$(cnt "$d/gold_drop.hex" "$work/drop_$tagbase.y")"
    D_GOLD="$(cnt "$d/gold.hex" "$work/drop_$tagbase.y")"
    [ "$D_HIT" = "0" ] || { echo "JUDGE-RED: 负对照 A1 未精确命中（$D_HIT，$tagbase）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
    if ! [ "$D_GOLD" -gt 0 ] 2>/dev/null; then
      echo "NEGCTL-FAIL: 负对照 A1（漏 ci 趟 $DROPCI）没改变输出（$tagbase）"; NEG_NOFIRE=$((NEG_NOFIRE+1))
    fi
    # (d) 负对照 A2：部分和从不写回
    run_tb "$work/mp_nowrite.vvp" "nowrite_$tagbase" "$d" "$M" "$ZY" >/dev/null
    N_HIT="$(cnt "$d/gold_nops.hex" "$work/nowrite_$tagbase.y")"
    N_GOLD="$(cnt "$d/gold.hex" "$work/nowrite_$tagbase.y")"
    [ "$N_HIT" = "0" ] || { echo "JUDGE-RED: 负对照 A2 未精确命中（$N_HIT，$tagbase）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
    if ! [ "$N_GOLD" -gt 0 ] 2>/dev/null; then
      echo "NEGCTL-FAIL: 负对照 A2（不写回）没改变输出（$tagbase）"; NEG_NOFIRE=$((NEG_NOFIRE+1))
    fi
    A2_SHOW="A2hit=$N_HIT/nops,!=gold=$N_GOLD"
  else
    A2_SHOW="A2=N/A(n_ci=1：单趟 ⇒ 没有跨趟累加可漏)"
  fi

  # (e) 负对照 B：初值非 0
  run_tb "$work/mp_initk.vvp" "initk_$tagbase" "$d" "$M" "$ZY" >/dev/null
  B_HIT="$(cnt "$d/gold_mutb.hex" "$work/initk_$tagbase.y")"
  B_GOLD="$(cnt "$d/gold.hex" "$work/initk_$tagbase.y")"
  [ "$B_HIT" = "0" ] || { echo "JUDGE-RED: 负对照 B 未精确命中（$B_HIT，$tagbase）"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  if ! [ "$B_GOLD" -gt 0 ] 2>/dev/null; then
    echo "NEGCTL-FAIL: 负对照 B（初值非 0）没改变输出（$tagbase）"; NEG_NOFIRE=$((NEG_NOFIRE+1))
  fi

  echo "SHAPE cin=$CIN cout=$COUT group=$GROUP n_ci=$NCI n_co=$NCO passes=$PASSES M=$M ZY=$ZY | POS_MISMATCH=$POS_MIS distinct(gold=$gd,rtl=$YD) | UNITY hit=$U_HIT !=gold=$U_GOLD | DROP hit=$D_HIT !=gold=$D_GOLD | $A2_SHOW | INITK hit=$B_HIT !=gold=$B_GOLD"
done

# ---------------- 判决 ----------------
echo "=========================================================================="
echo "形状集合（真表宽形状 $N_SHAPES 种）：$SHAPE_LIST"
echo "结构     = OK（PartialSumBuf：1 条 256bit x 256 字 Mem（★ §3.7） + 同步读 + 地址译码写 + 上电初值 0；无组合读）"
echo "正对照   = OK（逐个宽形状多趟流 == C4a.4 逐字节黄金；见上表 POS_MISMATCH=0）"
echo "退化守卫 = OK（黄金与 RTL 输出 distinct>1）"
echo "乘子     = OK（M=2^24 精确命中 ((acc·2^24)>>24)>>6 的预测、且 != 真乘子的黄金 ⇒ §4.4 乘子确实在数据通路上）"
echo "负对照 A1= OK（+DROPCI 漏一趟：精确命中 conv_tiled(drop_ci_block) 的预测、且 != 黄金）"
echo "负对照 A2= OK（网表突变：PartialSumBuf 写口关掉 ⇒ 精确命中'只 requant 末趟 partial'、且 != 黄金）"
echo "负对照 B = OK（网表突变：部分和缓冲初值非 0 ⇒ 精确命中 requant(acc+K)、且 != 黄金 ⇒ '第 1 趟清零'是承重项）"
if [ "$NEG_NOFIRE" -ne 0 ]; then
  echo "NEGCTL-FAIL: 有 $NEG_NOFIRE 条负对照没发火 ⇒ 判据无牙"; echo "RESULT: FAIL"; exit 2
fi
if [ "$TOTAL_BAD" -ne 0 ]; then
  echo "JUDGE-RED: $TOTAL_BAD 条判据未过"; echo "RESULT: FAIL"; exit 1
fi
echo "RESULT: PASS"
exit 0
