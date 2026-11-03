#!/usr/bin/env bash
# =============================================================================
# run_twoclock_ab.sh —— N1「两时钟装置」闸门（**N5b 集成后转绿**）。
#
# 交付物（本闸门要证的三件事，互为对照）：
#   ① **正对照**（harness 可信）：同一激励跑 **单时钟**（+SAME_CLK，npu_clk 并到 cpu_clk）
#      必须**全绿** —— TB 报 `RESULT: PASS` 且导出镜像与 Python 黄金**逐字节对**（MISMATCH=0）。
#   ② **★ N5b 交付**：同一激励跑 **两时钟**（cpu 100 MHz / npu 37 MHz，非整数比 2.7027…）
#      也必须**全绿** —— N3/N4/N5 的三座异步桥 + NpuResetSync 已按板级拓扑接进 TB
#      （glue → 桥 → NpuTop，`NpuTop.clk = npu_clk`）⇒ N1 的"先红基线"**已被解掉**。
#   ③ **负对照（必须发火）**：把 **AR 跨域掐断**（`NpuAxiLiteCdc` 的 `arPipe.io_enq_valid` 恒 0，
#      python 定点改一行，命中数必须恰好 1）⇒ 主机寄存器窗的读地址**一个都到不了 npu 域** ⇒
#      主机等 RVALID 超时 ⇒ 两时钟装置必须**红**（TB `RESULT: FAIL`）。这一红证明本闸门**能**检出
#      缺失/被破坏的 CDC —— 即 ② 的"全绿"是**真的靠桥在起作用**，不是橡皮图章。
#
# 退出码（与仓里其它 run_*_ab.sh 同约定）：
#   0 = 通过（单时钟绿 + 两时钟绿 + 负对照发火 + 两时钟确定性 2×）
#   1 = 本该干净的跑不干净（正/两时钟未 PASS，或镜像与黄金不符，或确定性 2× 不一致）⇒ 装置/DUT 有问题
#   2 = 负对照没发火（掐断 AR 后两时钟**竟**还全绿）⇒ **闸门自身不可信**
#   3 = 前置缺失：网表/TB/工具找不到，或编译失败
#
# 基线复用：`sim/glue_pbus/`（glue 的 NPU 寄存器窗装置）+ `y1/rtl_test/{NpuTopTb.v,AxiMemModel.v}`
#   + `y1/tools/run_nputop_ab.sh`（主机编程 → NPU 端到端块拷贝的激励与黄金口径）。
# 只读资产：`rtl/YeshenSocGlue.v` / `y1/gen/NpuTop.v` / `y1/gen/Npu{AxiLite,Mem,Irq}Cdc.v` /
#   `y1/gen/NpuResetSync.v` / `AxiMemModel.v` **一字不改**（负对照只在 $work 里的副本上改）。
# =============================================================================
set -uo pipefail

PY="${PY:-python}"
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
tb="$here/../rtl_test/NpuTwoClockTb.v"
memv="$here/../rtl_test/AxiMemModel.v"
glue="$repo/rtl/YeshenSocGlue.v"
nl="$here/../gen/NpuTop.v"
# ---- N5b：三座异步桥 + 复位同步器（TB 与板级同拓扑接入；见 NpuTwoClockTb.v 文件头）----
b_axilite="$here/../gen/NpuAxiLiteCdc.v"
b_memcdc="$here/../gen/NpuMemCdc.v"
b_irqcdc="$here/../gen/NpuIrqCdc.v"
b_rstsync="$here/../gen/NpuResetSync.v"

# ---- 用例常量（**逐条沿用 run_nputop_ab.sh 的端到端块拷贝口径**；MEMSZ 必须与 TB 里 AxiMemModel 的 MEMSZ 一致）----
MEMSZ=786432              # 768 KiB（与 TB 的 localparam MEMSZ 一致）
SRC=131072                # 0x20000，32B 对齐
DST=393216                # 0x60000，32B 对齐
IMG_W=256
IMG_H=64
C_IN=8
LEN=$(( IMG_W * IMG_H * C_IN ))   # = 131072（128 的整数倍）
PERIOD=251                # 模式周期：素数，与块长 128 互素

work_msys="$(mktemp -d)"
# ⚠️ 本机 `python` 是 Windows 版（C:\Python314），看不懂 MSYS `/tmp` ⇒ 全脚本用 **cygpath -m**
#    的混合路径（C:/...），bash / msys iverilog / Windows python 三方都能认。缺 cygpath 时退回原样。
work="$(cygpath -m "$work_msys" 2>/dev/null || printf '%s' "$work_msys")"
cleanup() {
  if [ "${KEEP_TMP:-0}" = "1" ]; then
    echo "KEEP_TMP=1 => 激励与日志留在 $work"
  else
    rm -rf "$work_msys"
  fi
}
trap cleanup EXIT

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

echo "== run_twoclock_ab: NPU 两时钟装置（N5b 集成后：三桥 + reset sync；期望两时钟 GREEN）=="
echo "   tb    =$tb"
echo "   mem   =$memv"
echo "   glue  =$glue"
echo "   nl    =$nl"
echo "   brg   =$b_axilite"
echo "   brg   =$b_memcdc"
echo "   brg   =$b_irqcdc"
echo "   brg   =$b_rstsync"
echo "   两时钟 = cpu_clk 100.000MHz  :  npu_clk 37.000MHz  (非整数比 100/37 = 2.7027…)"
echo "   用例  = SRC=$SRC DST=$DST IMG_W=$IMG_W IMG_H=$IMG_H C_IN=$C_IN => LEN=$LEN (MEMSZ=$MEMSZ)"
echo "   工具  = iverilog=${IVERILOG:-<找不到>}  vvp=${VVP:-<找不到>}  tmp=$work"

# ---------------- 前置检查（缺任一件 => 3）----------------
pre_missing=0
[ -f "$tb" ]      || { echo "PRECOND-FAIL: 缺 TB $tb"; pre_missing=1; }
[ -f "$memv" ]    || { echo "PRECOND-FAIL: 缺内存模型 $memv"; pre_missing=1; }
[ -f "$glue" ]    || { echo "PRECOND-FAIL: 缺 glue 网表 $glue"; pre_missing=1; }
[ -f "$nl" ]      || { echo "PRECOND-FAIL: 缺 NpuTop 网表 $nl"; pre_missing=1; }
[ -f "$b_axilite" ] || { echo "PRECOND-FAIL: 缺 NpuAxiLiteCdc 网表 $b_axilite"; pre_missing=1; }
[ -f "$b_memcdc" ]  || { echo "PRECOND-FAIL: 缺 NpuMemCdc 网表 $b_memcdc"; pre_missing=1; }
[ -f "$b_irqcdc" ]  || { echo "PRECOND-FAIL: 缺 NpuIrqCdc 网表 $b_irqcdc"; pre_missing=1; }
[ -f "$b_rstsync" ] || { echo "PRECOND-FAIL: 缺 NpuResetSync 网表 $b_rstsync"; pre_missing=1; }
[ -n "$IVERILOG" ] || { echo "PRECOND-FAIL: 找不到 iverilog"; pre_missing=1; }
[ -n "$VVP" ]      || { echo "PRECOND-FAIL: 找不到 vvp"; pre_missing=1; }
if [ "$pre_missing" != "0" ]; then echo "VERDICT: PRECONDITION-MISSING"; exit 3; fi

# ---------------- 网表指纹（取证）----------------
echo "---- 网表指纹（md5）----"
"$PY" - "$nl" "$b_axilite" "$b_memcdc" "$b_irqcdc" "$b_rstsync" <<'PYEOF'
import hashlib, sys
for p in sys.argv[1:]:
    try:
        d = hashlib.md5(open(p, "rb").read()).hexdigest()
    except OSError as e:
        d = "<ERR %s>" % e
    print("   md5 %s  %s" % (d, p))
PYEOF

# ---------------- 0) 造激励：非混叠模式 + Python 独立算黄金镜像 ----------------
if ! "$PY" - "$work" "$MEMSZ" "$SRC" "$DST" "$LEN" "$PERIOD" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

work = sys.argv[1]
memsz, src, dst, ln, period = (int(x) for x in sys.argv[2:7])

def pat(i):
    """周期恰好 = period（251）的模式；131 与 251 互素 ⇒ 0..250 上是排列。"""
    return ((i % period) * 131 + 7) % period

assert len(set(pat(i) for i in range(period))) == period, "FATAL: 模式周期不是恰好 %d" % period
assert period % 128 != 0 and 128 % period != 0, "FATAL: 模式周期与块长不互素"
for k in range(1, 17):
    assert all(pat(j) != pat(j + 128 * k) for j in range(0, 4 * period)), "FATAL: 整块平移混叠 k=%d" % k
assert (dst - src) % period != 0, "FATAL: src/dst 相位对混叠"
assert src % 32 == 0 and dst % 32 == 0, "FATAL: 地址必须 32B 对齐"
assert ln % 128 == 0 and ln > 0, "FATAL: 长度必须是 128 的正整数倍"
assert src + ln <= dst or dst + ln <= src, "FATAL: src/dst 区重叠"
assert max(src + ln, dst + ln) <= memsz, "FATAL: 越出已建模内存"

pre = bytes(pat(i) for i in range(memsz))
with open(work + "/mem.hex", "w") as f:
    for b in pre:
        f.write("%02x\n" % b)

golden = pre[:dst] + pre[src:src + ln] + pre[dst + ln:]
with open(work + "/exp.hex", "w") as f:
    for b in golden:
        f.write("%02x\n" % b)

uniq = len(set(pre[src:src + 128]))
assert uniq > 1, "FATAL: 源窗口是常数"
diff_pre = sum(1 for j in range(ln) if pre[src + j] != pre[dst + j])
assert diff_pre == ln, "FATAL: dst 区预载与源内容逐字节相同 => 不拷贝也能过"
print("MEMGEN bytes=%d chunks=%d uniq128=%d dst_vs_preload_diff=%d period=%d"
      % (memsz, ln // 128, uniq, diff_pre, period))
PYEOF
then
  echo "VERDICT: PRECONDITION-MISSING (激励生成失败)"; exit 3
fi
[ -s "$work/mem.hex" ] && [ -s "$work/exp.hex" ] || { echo "VERDICT: PRECONDITION-MISSING (激励文件缺失)"; exit 3; }

# ---------------- 1) 编译（正装置一次；负装置另一次）----------------
# 正装置：真实桥网表
if ! "$IVERILOG" -g2012 -o "$work/sim.vvp" \
      "$tb" "$memv" "$glue" "$nl" "$b_axilite" "$b_memcdc" "$b_irqcdc" "$b_rstsync" \
      > "$work/iv.log" 2>&1; then
  echo "PRECOND-FAIL: iverilog 编译（正装置）失败:"; sed -n '1,40p' "$work/iv.log"; echo "VERDICT: PRECONDITION-MISSING (compile)"; exit 3
fi
echo "---- iverilog 编译 OK（正装置：glue + 3 桥 + reset sync + NpuTop）----"

# 负装置：把 NpuAxiLiteCdc.v 拷进 $work 后**掐断 AR 跨域**（arPipe.io_enq_valid 恒 0），再编译。
#   ★ 锚点自校验：命中数必须**恰好 1**，否则 exit 2（闸门不可信，绝不静默跳过）。
cp "$b_axilite" "$work/NpuAxiLiteCdc.v"
if ! "$PY" - "$work/NpuAxiLiteCdc.v" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
pat = r"\.io_enq_valid\s*\(io_axilite_ar_valid\s*\)"
hits = re.findall(pat, s)
if len(hits) != 1:
    print("MUT-ANCHOR-BAD: io_enq_valid(io_axilite_ar_valid) 命中 %d（要恰好 1）" % len(hits))
    sys.exit(2)
s2 = re.sub(pat, ".io_enq_valid(1'b0)", s)
open(p, "w").write(s2)
print("MUT-OK: 掐断 AR 跨域（arPipe.io_enq_valid = 1'b0），命中数 = 1")
PYEOF
then
  echo "VERDICT: NEG-CONTROL-ANCHOR-BAD（负对照锚点命中数不是恰好 1 => 闸门不可信）"; exit 2
fi
if ! "$IVERILOG" -g2012 -o "$work/sim_neg.vvp" \
      "$tb" "$memv" "$glue" "$nl" "$work/NpuAxiLiteCdc.v" "$b_memcdc" "$b_irqcdc" "$b_rstsync" \
      > "$work/iv_neg.log" 2>&1; then
  echo "PRECOND-FAIL: iverilog 编译（负装置）失败:"; sed -n '1,40p' "$work/iv_neg.log"; echo "VERDICT: PRECONDITION-MISSING (compile-neg)"; exit 3
fi
echo "---- iverilog 编译 OK（负装置：AR 跨域掐断）----"

# 逐字节比较的公共实现
cat > "$work/cmpbytes.py" <<'PYEOF'
def load(p):
    return bytes.fromhex("".join(open(p).read().split()))

def diffs(a, b, base=0):
    assert len(a) == len(b), "length %d vs %d" % (len(a), len(b))
    n = len(a); B = 1 << 16; cnt = 0; first = -1; i = 0
    while i < n:
        j = min(i + B, n)
        if a[i:j] != b[i:j]:
            for k in range(i, j):
                if a[k] != b[k]:
                    if first < 0:
                        first = base + k
                    cnt += 1
        i = j
    return cnt, first
PYEOF

# 跑一次仿真。用法: run_sim <vvp> <base> [SAME_CLK]  -> 写 <base>.log 与 <base>.dump
run_sim() {
  local vvp="$1"; local base="$2"; shift 2
  ( cd "$work" && "$VVP" "$vvp" \
      "+SRC=$SRC" "+DST=$DST" "+IMG_W=$IMG_W" "+IMG_H=$IMG_H" "+C_IN=$C_IN" \
      "+MEMFILE=$work/mem.hex" "+DUMPFILE=$work/$base.dump" +dump "$@" > "$base.log" 2>&1 )
  return $?
}
# 归一化日志（去掉 tmp 路径与各自 dump 名）——确定性 2× 比对用
norm_log() { sed -E 's#(MEM (LOADED|DUMPED)) [^ ]+#\1 PATH#' "$1"; }
# 只判字节：导出镜像 vs 黄金
judge_bytes() {   # $1=logbase  -> 打印 "MISMATCH=<n> FIRST_OFF=<n>"
  "$PY" - "$work" "$1" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from cmpbytes import load, diffs
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
work, base = sys.argv[1], sys.argv[2]
exp = load(work + "/exp.hex")
try:
    got = load(work + "/" + base + ".dump")
except Exception as e:
    print("MISMATCH=? FIRST_OFF=? (no dump: %s)" % e)
    sys.exit(0)
mis, first = diffs(got, exp)
print("MISMATCH=%d FIRST_OFF=%d" % (mis, first))
PYEOF
}

# ===========================================================================
# ① 正对照：单时钟（+SAME_CLK）—— 必须全绿
# ===========================================================================
echo "---- [正对照] 单时钟 SAME_CLK ----"
run_sim "$work/sim.vvp" same_1 +SAME_CLK; SRC1=$?
echo "   --- same_1.log 事实行 ---"
grep -E '^(CLKCFG|ID_READ|STATUS_PRE|CTRL_PRE|PRE_IRQ|RB_OK|DONE_SEEN|ERR_SEEN|STATUS_POST|CTRL_POST|POST_IRQ|IRQ_HELD_AFTER_50|IRQ_AFTER_ACK|IRQ_HIGH_CYCLES|MEM |RESULT:)' "$work/same_1.log" | sed 's/^/   /' || true
SAME_BYTES="$(judge_bytes same_1)"
echo "   单时钟字节对账: $SAME_BYTES"
SAME_MIS="$(printf '%s\n' "$SAME_BYTES" | sed -n 's/^MISMATCH=\([0-9][0-9]*\).*/\1/p')"
SAME_PASS=0
if [ "$SRC1" -eq 0 ] && grep -q '^RESULT: PASS' "$work/same_1.log"; then SAME_PASS=1; fi

# ===========================================================================
# ② ★ N5b 交付：两时钟（cpu 100 / npu 37）—— 集成后必须全绿；顺带确定性 2×
# ===========================================================================
echo "---- [N5b·两时钟] cpu100/npu37：两次跑（确定性 2×）----"
run_sim "$work/sim.vvp" two_1; TC1=$?
run_sim "$work/sim.vvp" two_2; TC2=$?
if diff -q <(norm_log "$work/two_1.log") <(norm_log "$work/two_2.log") >/dev/null 2>&1; then
  echo "   DETERMINISM[two]=OK（两次日志逐字节相同）"
  TWO_DET=1
else
  echo "   DETERMINISM[two]=DIFF（两次日志不同！）"
  TWO_DET=0
fi
echo "   --- two_1.log 事实行 ---"
grep -E '^(CLKCFG|ID_READ|STATUS_PRE|CTRL_PRE|PRE_IRQ|RB_OK|DONE_SEEN|ERR_SEEN|STATUS_POST|CTRL_POST|POST_IRQ|IRQ_HELD_AFTER_50|IRQ_AFTER_ACK|IRQ_HIGH_CYCLES|MEM |TBFAIL|RESULT:)' "$work/two_1.log" | sed 's/^/   /' || true
TWO_BYTES="$(judge_bytes two_1)"
echo "   两时钟字节对账: $TWO_BYTES"
TWO_MIS="$(printf '%s\n' "$TWO_BYTES" | sed -n 's/^MISMATCH=\([0-9][0-9]*\).*/\1/p')"
TWO_PASS=0
if [ "$TC1" -eq 0 ] && [ "$TC2" -eq 0 ] && grep -q '^RESULT: PASS' "$work/two_1.log"; then TWO_PASS=1; fi

# ===========================================================================
# ③ 负对照：两时钟 + AR 跨域掐断 —— 必须红
# ===========================================================================
echo "---- [负对照] 两时钟 + AR 跨域掐断（arPipe.io_enq_valid=0）—— 必须红 ----"
run_sim "$work/sim_neg.vvp" neg_1; NC1=$?
NEG_BYTES="$(judge_bytes neg_1)"
NEG_MIS="$(printf '%s\n' "$NEG_BYTES" | sed -n 's/^MISMATCH=\([0-9][0-9]*\).*/\1/p')"
NEG_FAIL_TB=0
grep -q '^RESULT: FAIL' "$work/neg_1.log" && NEG_FAIL_TB=1
echo "   TB: $(grep -E '^(TBFAIL|RESULT: FAIL|RESULT: PASS)' "$work/neg_1.log" | head -4 | tr '\n' '|')"
echo "   内存侧: $NEG_BYTES （导出镜像 vs 黄金）"
NEG_RED=0
[ "$NEG_FAIL_TB" = "1" ] && NEG_RED=1
if [ -n "${NEG_MIS:-}" ] && [ "${NEG_MIS:-0}" != "0" ]; then NEG_RED=1; fi

# ===========================================================================
# 判定
# ===========================================================================
echo "==================== 判定 ===================="
if [ "$SAME_PASS" != "1" ] || [ "${SAME_MIS:-X}" != "0" ]; then
  echo "正对照（单时钟）未全绿：RESULT_PASS=$SAME_PASS SRC1=$SRC1 字节对账=$SAME_BYTES"
  echo "VERDICT: MISMATCH（装置/DUT 在单时钟下就不干净 => 闸门不可信）"
  exit 1
fi
echo "正对照[单时钟]              = 全绿（RESULT: PASS；逐字节 MISMATCH=0）=> harness 本身可信。"

if [ "$TWO_PASS" != "1" ] || [ "${TWO_MIS:-X}" != "0" ] || [ "$TWO_DET" != "1" ]; then
  echo "两时钟（N5b 交付）未全绿：RESULT_PASS=$TWO_PASS TC1=$TC1 TC2=$TC2 字节对账=$TWO_BYTES 确定性=$TWO_DET"
  echo "VERDICT: MISMATCH（N5b 集成后两时钟仍未绿 => CDC 接线/桥有问题）"
  exit 1
fi
echo "N5b[两时钟 100/37 集成]     = 全绿（RESULT: PASS；逐字节 MISMATCH=0；确定性 2×）=> N1 先红基线已解。"

if [ "$NEG_RED" != "1" ]; then
  echo "负对照（两时钟 + 掐断 AR）竟全绿：RESULT_FAIL=$NEG_FAIL_TB 字节对账=$NEG_BYTES"
  echo "VERDICT: NEG-CONTROL-NOT-FIRED（掐断跨域后两时钟没红 => 闸门不可信）"
  exit 2
fi
echo "负对照[两时钟 + AR 跨域掐断] = 红（$([ "$NEG_FAIL_TB" = 1 ] && echo 'TB RESULT: FAIL' || echo "字节 MISMATCH=$NEG_MIS")）=> 闸门能检出被破坏的 CDC。"

echo "VERDICT: N5B-OK（单时钟绿 / 两时钟绿 / 负对照红 / 确定性 2×）"
exit 0
