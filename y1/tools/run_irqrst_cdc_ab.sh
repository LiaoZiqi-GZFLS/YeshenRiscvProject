#!/usr/bin/env bash
# =============================================================================
# run_irqrst_cdc_ab.sh —— Y1「NPU 独立时钟域」plan Task **N5** 的闸门：
#   **NpuIrqCdc（IRQ 电平 npu_clk→cpu_clk 2-FF 同步）+ NpuResetSync（每域复位同步释放，cpu 先/npu 后）
#     的独立两时钟正/负对照**（spec §3-A(c)(d) / §5-G3）。
#
# 本闸门要证的（每一档都带**能失败**的对照）：
#   ① **正 · IRQ**（cpu 100 / npu 37，非整数比 2.7027…）：npu 域 IRQ 电平在 ~120 个**逐段不同相位**上
#      置起/清除（段长 80..100 ns 的确定性伪随机）⇒
#        · `cpuIrq` 每次跳变都由**同向**的 `npuIrq` 跳变在 `[LATMIN,LATMAX]` ns 内触发（有界延迟）；
#        · `cpuIrq` **只**在 `cpu_clk==1` 时改变（同步性；把"未同步的组合跨域"挡在外面）；
#        · `cpuIrq` 跳变与 `npuIrq` 跳变**配对**（源保持 ⇒ 目的保持；无自行落、无伪起）。
#      反向口（cpu→npu）同款检查。
#   ② **正 · 复位**：`asyncRst` 异步置位后同步释放 ⇒ **`npuRstn` 严格晚于 `cpuRstn`**（顺序）；
#      复位后的合法 AXI-Lite 写/读经 **N3 活网表 `NpuAxiLiteCdc`** 全部 OKAY、计数相等；
#      **无伪事务**（cpu 侧 B 在主机无在飞请求时出现 ⇒ SPURIOUS，应 =0）。
#   ③ **比较器自检**（不盲信）：
#        · IRQ：在好日志上**注入一条无源 `CIRQ` 上升** ⇒ 判据器多报**恰好 1** 处；
#        · 复位：把日志里 `t_cpu_rel/t_npu_rel` 对调 ⇒ 判据器必须报 ORDER_BAD。
#      ⇒ 证明对账是逐事件/逐跳变得，不是橡皮图章。
#   ④ **负对照（必须发火）** —— 网表突变（python 定点改一行，命中数必须恰好 1）：
#        NEG-A：IRQ 跨域**同步器被摘掉**（`io_cpuIrq = irqSync2` → `= io_npuIrq`，组合直通）
#               ⇒ 亚稳态/毛刺类：`cpuIrq` 在 `cpu_clk==0` 时也变（ASYNC>0）、延迟 ≈0（< LATMIN）。
#        NEG-B：保持电平整成**单拍脉冲**（`io_cpuIrq = irqSync1 & ~irqSync2`）⇒ 源还举着时 `cpuIrq`
#               自己落了 ⇒ 配对判据（SPURIOUS）发火 ⇒ **电平保持语义**这一条是承重的。
#        NEG-C：**复位释放顺序反转**（`io_npuRstn = !npuRstSync[1]` → `= !io_asyncRst`）⇒ npu 先于 cpu 释放
#               ⇒ 顺序判据 ORDER_BAD + 危险行为模型吐伪事务（SPURIOUS>0）。
#      ★ 三道都用**同一份装置**、只有网表不同 ⇒ 红的归因唯一；锚点命中数不是恰好 1 就 exit 2（闸门不可信）。
#
# 退出码（与仓里其它 run_*_ab.sh 同约定）：
#   0 = 通过（IRQ + 复位正作业全绿 + 比较器自检恰好 1 + 三道负对照都发火 + 确定性 2×）
#   1 = 正作业/对账未全绿 ⇒ 模块或装置有问题
#   2 = 负对照没发火，或比较器自检不是恰好 1 ⇒ **闸门自身不可信**
#   3 = 前置缺失（网表/TB/iverilog/cygpath）
#
# 装置契约：
#   rtl_test/NpuIrqCdcTb.v     + gen/NpuIrqCdc.v
#     plusargs：+SAME_CLK +PHASE_INV +PHASE_DLY_PS= +SEED=
#     事实行：CFG / NIRQ <t> <v> / CIRQ <t> <v> / NIRQC <t> <v> / CIRC <t> <v> /
#             STATS lat_viol=.. spurious=.. async=.. rev_async=.. rev_lat_viol=.. rev_spurious=.. /
#             STATS latmax_ps=.. / RESULT: PASS|FAIL
#   rtl_test/NpuResetSyncTb.v  + gen/NpuResetSync.v + gen/NpuAxiLiteCdc.v（N3 活网表）
#     plusargs：+SAME_CLK +PHASE_INV +PHASE_DLY_PS=
#     事实行：CFG / ORDER t_cpu_rel=.. t_npu_rel=.. delta_ns=.. [ORDER_BAD..] / HAZARD .. /
#             NPUW / NPUR / HOSTR / SPURIOUS n=.. / COUNTS host_wr=.. / TBFAIL / RESULT: PASS|FAIL
# =============================================================================
set -uo pipefail

PY="${PY:-python}"
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
irq_tb="$here/../rtl_test/NpuIrqCdcTb.v"
irq_nl="$here/../gen/NpuIrqCdc.v"
rst_tb="$here/../rtl_test/NpuResetSyncTb.v"
rst_nl="$here/../gen/NpuResetSync.v"
brg_nl="$here/../gen/NpuAxiLiteCdc.v"

work_msys="$(mktemp -d)"
work="$(cygpath -m "$work_msys" 2>/dev/null || printf '%s' "$work_msys")"
cleanup() {
  if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => 日志留在 $work"; else rm -rf "$work_msys"; fi
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

echo "== run_irqrst_cdc_ab: N5 IRQ + 复位跨域（两时钟正/负对照）=="
echo "   irq_tb =$irq_tb"
echo "   irq_nl =$irq_nl"
echo "   rst_tb =$rst_tb"
echo "   rst_nl =$rst_nl（+ $brg_nl）"
echo "   两时钟 = cpu_clk 100.000MHz : npu_clk 37.000MHz（非整数比 100/37 = 2.7027…）"
echo "   工具   = iverilog=${IVERILOG:-<找不到>}  vvp=${VVP:-<找不到>}  tmp=$work"

# ---------------- 前置检查（缺任一件 => 3）----------------
pre_missing=0
for f in "$irq_tb" "$irq_nl" "$rst_tb" "$rst_nl" "$brg_nl"; do
  [ -f "$f" ] || { echo "PRECOND-FAIL: 缺 $f"; pre_missing=1; }
done
[ -n "$IVERILOG" ] || { echo "PRECOND-FAIL: 找不到 iverilog"; pre_missing=1; }
[ -n "$VVP" ]      || { echo "PRECOND-FAIL: 找不到 vvp"; pre_missing=1; }
if [ "$pre_missing" != "0" ]; then
  echo "       先生成网表: cd y1 && printf 'Test/runMain NpuIrqCdcGen D:/code/PDS/VexiiYeshenLinux/y1/gen\\nTest/runMain NpuResetSyncGen D:/code/PDS/VexiiYeshenLinux/y1/gen\\nexit\\n' | bash sbt.sh"
  echo "VERDICT: PRECONDITION-MISSING"; exit 3
fi

# ===========================================================================
# 1) IRQ 判据器（从 hop 日志独立复判：有界延迟 + 配对；不盲信装置 PASS）
#    用法： judge_irq.py <log> <tag> [perturb]
#      perturb=1：注入一条**无源** `CIRQ <t> 1`（模拟"伪 IRQ 上升"）⇒ 判据器须多报恰好 1 处
# ===========================================================================
cat > "$work/judge_irq.py" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

log, tag = sys.argv[1], sys.argv[2]
perturb = int(sys.argv[3]) if len(sys.argv) > 3 else 0

LATMIN, LATMAX_FWD, LATMAX_REV = 5.0, 32.0, 60.0

ev = []                                   # (kind, t, v) 按出现顺序
for ln in open(log, errors="replace"):
    t = ln.split()
    if not t: continue
    if t[0] in ("NIRQ", "CIRQ", "NIRQC", "CIRC") and len(t) >= 3:
        ev.append((t[0], float(t[1]), int(t[2])))

if perturb:
    ev.append(("CIRQ", 1e9, 1))           # 一条无源的伪 IRQ 上升（npuIrq 此时必为 0）

# ---- 正向：cpuIrq 由 npuIrq 触发（有界延迟 + 配对）----
npu_high = 0; t_npu_rise = -1.0; t_npu_fall = -1.0
lat_viol = 0; spurious = 0; cirq_edges = 0
# ---- 反向：npuClearReq 由 cpuClearReq 触发 ----
cpuc_high = 0; t_cpuc_rise = -1.0; t_cpuc_fall = -1.0
rev_lat_viol = 0; rev_spurious = 0
for (k, t, v) in ev:
    if k == "NIRQ":
        if v == 1: t_npu_rise = t; npu_high = 1
        else:      t_npu_fall = t; npu_high = 0
    elif k == "CIRC":
        if v == 1: t_cpuc_rise = t; cpuc_high = 1
        else:      t_cpuc_fall = t; cpuc_high = 0
    elif k == "CIRQ":
        cirq_edges += 1
        if v == 1:
            if npu_high != 1: spurious += 1
            else:
                lat = t - t_npu_rise
                if lat < LATMIN or lat > LATMAX_FWD: lat_viol += 1
        else:
            if npu_high != 0: spurious += 1
            else:
                lat = t - t_npu_fall
                if lat < LATMIN or lat > LATMAX_FWD: lat_viol += 1
    elif k == "NIRQC":
        if v == 1:
            if cpuc_high != 1: rev_spurious += 1
            else:
                lat = t - t_cpuc_rise
                if lat < LATMIN or lat > LATMAX_REV: rev_lat_viol += 1
        else:
            if cpuc_high != 0: rev_spurious += 1
            else:
                lat = t - t_cpuc_fall
                if lat < LATMIN or lat > LATMAX_REV: rev_lat_viol += 1

print("[%s] CIRQ_EDGES=%d LATVIOL=%d SPURIOUS=%d REV_LATVIOL=%d REV_SPURIOUS=%d"
      % (tag, cirq_edges, lat_viol, spurious, rev_lat_viol, rev_spurious))
PYEOF

# ===========================================================================
# 2) 复位判据器（从事实行独立复判：顺序 + 计数 + 无伪；不盲信装置 PASS）
#    用法： judge_rst.py <log> <tag> [perturb]
#      perturb=1：把 t_cpu_rel / t_npu_rel 对调 ⇒ 判据器须报 ORDER_BAD
# ===========================================================================
cat > "$work/judge_rst.py" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

log, tag = sys.argv[1], sys.argv[2]
perturb = int(sys.argv[3]) if len(sys.argv) > 3 else 0

t_cpu = t_npu = None
spurious = None
counts = None
res = None
for ln in open(log, errors="replace"):
    t = ln.split()
    if not t: continue
    if t[0] == "ORDER" and len(t) >= 4:
        t_cpu = float(t[1].split("=")[1]); t_npu = float(t[2].split("=")[1])
        if perturb: t_cpu, t_npu = t_npu, t_cpu      # 对调 ⇒ 顺序应判红
    elif t[0] == "SPURIOUS":
        spurious = int(t[1].split("=")[1])
    elif t[0] == "COUNTS":
        counts = ln.split(None, 1)[1].strip()
    elif t[0] == "RESULT:" and t[1] == "PASS":
        res = "PASS"

order_bad = 0
if t_cpu is None or t_npu is None:
    order_bad = 1
elif not (t_npu > t_cpu):
    order_bad = 1
sp_bad = 1 if (spurious is None or spurious != 0) else 0
print("[%s] t_cpu=%s t_npu=%s ORDER_BAD=%d SPURIOUS=%s COUNTSTR=[%s] RESULT=%s"
      % (tag, t_cpu, t_npu, order_bad, spurious, counts, res or "?"))
PYEOF

# ===========================================================================
# 3) 编译（好网表）
# ===========================================================================
if ! "$IVERILOG" -g2012 -o "$work/irq.vvp" "$irq_tb" "$irq_nl" > "$work/iv_irq.log" 2>&1; then
  echo "PRECOND-FAIL: iverilog 编译失败（IRQ 好网表）:"; sed -n '1,40p' "$work/iv_irq.log"
  echo "VERDICT: PRECONDITION-MISSING (compile irq)"; exit 3
fi
if ! "$IVERILOG" -g2012 -o "$work/rst.vvp" "$rst_tb" "$rst_nl" "$brg_nl" > "$work/iv_rst.log" 2>&1; then
  echo "PRECOND-FAIL: iverilog 编译失败（复位好网表）:"; sed -n '1,40p' "$work/iv_rst.log"
  echo "VERDICT: PRECONDITION-MISSING (compile rst)"; exit 3
fi
echo "---- iverilog 编译 OK（IRQ + 复位 好网表）----"

norm_log() { sed -E 's#([+][A-Za-z_]+=)[^ ]+#\1PATH#g' "$1"; }

FAIL=0          # 1 = 正/对账失败 ⇒ exit 1
NEGFAIL=0       # 1 = 负对照/自检没发火 ⇒ exit 2

run_and_check_det() {   # <vvp> <base> <plusargs...>
  local vvp="$1"; local base="$2"; shift 2
  ( cd "$work" && "$VVP" "$vvp" "$@" > "$base.log" 2>&1 )
  ( cd "$work" && "$VVP" "$vvp" "$@" > "${base}__2.log" 2>&1 )
  if diff -q <(norm_log "$work/$base.log") <(norm_log "$work/${base}__2.log") >/dev/null 2>&1; then
    echo "   DETERMINISM[$base]=OK"
  else
    echo "   DETERMINISM[$base]=DIFF（两次日志不同！）"; FAIL=1
  fi
}

# ===========================================================================
# 4) IRQ 正作业：4 档（相位/频率）× 确定性 2×
# ===========================================================================
echo "==== IRQ 正作业（有界延迟 + 配对 + 同步性）===="
irq_pos() {   # <tag> <plusargs...>
  local tag="$1"; shift
  run_and_check_det "$work/irq.vvp" "$tag" "$@"
  grep -q '^RESULT: PASS' "$work/$tag.log" || { echo "   TB_RED[$tag]"; grep -E '^(RESULT|STATS)' "$work/$tag.log" | head -4 | sed 's/^/      /'; FAIL=1; }
  grep -E '^(CFG|STATS|RESULT:)' "$work/$tag.log" | sed 's/^/   /'
  "$PY" "$work/judge_irq.py" "$work/$tag.log" "$tag" 0 > "$work/ji_$tag.out" 2>&1 || true
  cat "$work/ji_$tag.out" | sed 's/^/   /'
  local lv sp ra rs
  lv=$(sed -n 's/.*CIRQ_EDGES=[0-9]* LATVIOL=\([0-9]*\).*/\1/p' "$work/ji_$tag.out" | head -1)
  sp=$(sed -n 's/.*LATVIOL=[0-9]* SPURIOUS=\([0-9]*\).*/\1/p' "$work/ji_$tag.out" | head -1)
  ra=$(sed -n 's/.*REV_LATVIOL=\([0-9]*\).*/\1/p' "$work/ji_$tag.out" | head -1)
  rs=$(sed -n 's/.*REV_SPURIOUS=\([0-9]*\).*/\1/p' "$work/ji_$tag.out" | head -1)
  if [ "${lv:-X}" != "0" ] || [ "${sp:-X}" != "0" ] || [ "${ra:-X}" != "0" ] || [ "${rs:-X}" != "0" ]; then
    FAIL=1
  else
    echo "   POS_OK[$tag]: 有界延迟 0 违例、配对 0 伪跳变、反向口同步 0 违例"
  fi
}
irq_pos irq_j1
irq_pos irq_j2 "+SAME_CLK"
irq_pos irq_j3 "+PHASE_INV" "+PHASE_DLY_PS=6757"
irq_pos irq_j4 "+PHASE_DLY_PS=1201"

# ---- IRQ 比较器自检：注入一条无源 CIRQ 上升 ⇒ 须多报**恰好 1** ----
echo "---- [自检·IRQ 比较器] 注入一条无源 CIRQ 上升 ⇒ 判据器须多报恰好 1 处 ----"
"$PY" "$work/judge_irq.py" "$work/irq_j1.log" selftest 1 > "$work/ji_selftest.out" 2>&1 || true
cat "$work/ji_selftest.out" | sed 's/^/   /'
base_sp=$(sed -n 's/.* SPURIOUS=\([0-9]*\) .*/\1/p' "$work/ji_irq_j1.out" | head -1)
pert_sp=$(sed -n 's/.* SPURIOUS=\([0-9]*\) .*/\1/p' "$work/ji_selftest.out" | head -1)
if [ "${base_sp:-X}" = "0" ] && [ "${pert_sp:-X}" = "1" ]; then
  echo "   SELFTEST_OK[IRQ]（注入 1 条无源跳变 ⇒ 判据器多报恰好 1 ⇒ 逐跳变对账，非橡皮图章）"
else
  echo "   SELFTEST_RED[IRQ]: base_sp=${base_sp:-?} pert_sp=${pert_sp:-?}（应 0→1）⇒ 闸门不可信"
  NEGFAIL=1
fi

# ===========================================================================
# 5) 复位正作业：3 档 × 确定性 2×
# ===========================================================================
echo "==== 复位正作业（顺序 + 无伪事务 + 功能仍对）===="
rst_pos() {   # <tag> <plusargs...>
  local tag="$1"; shift
  run_and_check_det "$work/rst.vvp" "$tag" "$@"
  grep -q '^RESULT: PASS' "$work/$tag.log" || { echo "   TB_RED[$tag]"; grep -E '^(RESULT|ORDER|SPURIOUS|COUNTS)' "$work/$tag.log" | head -5 | sed 's/^/      /'; FAIL=1; }
  grep -E '^(CFG|ORDER|HAZARD|SPURIOUS|COUNTS|RESULT:)' "$work/$tag.log" | sed 's/^/   /'
  "$PY" "$work/judge_rst.py" "$work/$tag.log" "$tag" 0 > "$work/jr_$tag.out" 2>&1 || true
  cat "$work/jr_$tag.out" | sed 's/^/   /'
  local ob sp
  ob=$(sed -n 's/.*ORDER_BAD=\([0-9]*\) .*/\1/p' "$work/jr_$tag.out" | head -1)
  sp=$(sed -n 's/.* SPURIOUS=\([0-9]*\) .*/\1/p' "$work/jr_$tag.out" | head -1)
  if [ "${ob:-X}" != "0" ] || [ "${sp:-X}" != "0" ]; then
    FAIL=1
  else
    echo "   POS_OK[$tag]: npu 晚于 cpu 释放、无伪事务"
  fi
}
rst_pos rst_j1
rst_pos rst_j2 "+SAME_CLK"
rst_pos rst_j3 "+PHASE_INV" "+PHASE_DLY_PS=6757"

# ---- 复位比较器自检：对调 ORDER 时刻 ⇒ 须报 ORDER_BAD ----
echo "---- [自检·复位比较器] 对调 t_cpu_rel/t_npu_rel ⇒ 判据器须报 ORDER_BAD ----"
"$PY" "$work/judge_rst.py" "$work/rst_j1.log" selftest 1 > "$work/jr_selftest.out" 2>&1 || true
cat "$work/jr_selftest.out" | sed 's/^/   /'
sob=$(sed -n 's/.*ORDER_BAD=\([0-9]*\) .*/\1/p' "$work/jr_selftest.out" | head -1)
if [ "${sob:-X}" = "1" ]; then
  echo "   SELFTEST_OK[复位]（对调顺序 ⇒ 判据器报 ORDER_BAD ⇒ 顺序判据是承重的）"
else
  echo "   SELFTEST_RED[复位]: ORDER_BAD=${sob:-?}（应 1）⇒ 闸门不可信"
  NEGFAIL=1
fi

# ===========================================================================
# 6) 负对照 A：IRQ —— 跨域同步器被摘掉（组合直通 io_cpuIrq = io_npuIrq）
# ===========================================================================
echo "==== 负对照 A[IRQ: 摘掉同步器，组合直通] 必须红（亚稳态/毛刺类）===="
if ! "$PY" - "$irq_nl" "$work/mut_irq_a.v" > "$work/mga.out" 2>&1 <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
pat = re.compile(r"assign io_cpuIrq = irqSync2;")
new, n = pat.subn("assign io_cpuIrq = io_npuIrq;", src)
print("MUTGEN_HITS=%d" % n)
if n != 1: sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(new)
PYEOF
then
  echo "   MUTGEN_RED（命中数不是恰好 1）"; cat "$work/mga.out" | sed 's/^/      /'; NEGFAIL=1
else
  cat "$work/mga.out" | sed 's/^/   /'
  if ! "$IVERILOG" -g2012 -o "$work/mut_irq_a.vvp" "$irq_tb" "$work/mut_irq_a.v" > "$work/iva.log" 2>&1; then
    echo "   MUT_COMPILE_RED"; sed -n '1,20p' "$work/iva.log" | sed 's/^/      /'; NEGFAIL=1
  else
    ( cd "$work" && "$VVP" "$work/mut_irq_a.vvp" > "$work/negA.log" 2>&1 )
    grep -E '^(STATS|RESULT:)' "$work/negA.log" | sed 's/^/   /'
    "$PY" "$work/judge_irq.py" "$work/negA.log" negA 0 > "$work/jnA.out" 2>&1 || true
    cat "$work/jnA.out" | sed 's/^/   /'
    alv=$(sed -n 's/.*CIRQ_EDGES=[0-9]* LATVIOL=\([0-9]*\).*/\1/p' "$work/jnA.out" | head -1)
    asp=$(sed -n 's/.*LATVIOL=[0-9]* SPURIOUS=\([0-9]*\).*/\1/p' "$work/jnA.out" | head -1)
    aasync=$(sed -n 's/.*STATS lat_viol=[0-9]* spurious=[0-9]* async=\([0-9]*\) .*/\1/p' "$work/negA.log" | head -1)
    if [ -z "${alv:-}" ] || { [ "${alv:-0}" = "0" ] && [ "${aasync:-0}" = "0" ]; }; then
      echo "   NEG_RED[negA]: 组合直通后**没**抓到异步/零延迟（LATVIOL=${alv:-?} ASYNC=${aasync:-?}）⇒ 闸门不可信"
      NEGFAIL=1
    else
      echo "   NEG_OK[negA]: 摘掉同步器 ⇒ 组合跨域：LATVIOL=$alv（延迟 0 < LATMIN）、ASYNC=$aasync（在 cpu_clk==0 时也变）"
      echo "                 ⇒ 「2-FF 同步」这一格是**承重**的。"
    fi
  fi
fi

# ===========================================================================
# 7) 负对照 B：IRQ —— 保持电平整成单拍脉冲（io_cpuIrq = irqSync1 & ~irqSync2）
# ===========================================================================
echo "==== 负对照 B[IRQ: 保持电平整成单拍脉冲] 必须红（电平保持语义）===="
if ! "$PY" - "$irq_nl" "$work/mut_irq_b.v" > "$work/mgb.out" 2>&1 <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
pat = re.compile(r"assign io_cpuIrq = irqSync2;")
new, n = pat.subn("assign io_cpuIrq = (irqSync1 & (~irqSync2));", src)
print("MUTGEN_HITS=%d" % n)
if n != 1: sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(new)
PYEOF
then
  echo "   MUTGEN_RED（命中数不是恰好 1）"; cat "$work/mgb.out" | sed 's/^/      /'; NEGFAIL=1
else
  cat "$work/mgb.out" | sed 's/^/   /'
  if ! "$IVERILOG" -g2012 -o "$work/mut_irq_b.vvp" "$irq_tb" "$work/mut_irq_b.v" > "$work/ivb.log" 2>&1; then
    echo "   MUT_COMPILE_RED"; sed -n '1,20p' "$work/ivb.log" | sed 's/^/      /'; NEGFAIL=1
  else
    ( cd "$work" && "$VVP" "$work/mut_irq_b.vvp" > "$work/negB.log" 2>&1 )
    grep -E '^(STATS|RESULT:)' "$work/negB.log" | sed 's/^/   /'
    "$PY" "$work/judge_irq.py" "$work/negB.log" negB 0 > "$work/jnB.out" 2>&1 || true
    cat "$work/jnB.out" | sed 's/^/   /'
    bsp=$(sed -n 's/.* SPURIOUS=\([0-9]*\) .*/\1/p' "$work/jnB.out" | head -1)
    if [ -z "${bsp:-}" ] || [ "${bsp:-0}" = "0" ]; then
      echo "   NEG_RED[negB]: 脉冲化后**没**抓到电平保持被破坏（SPURIOUS=${bsp:-?}）⇒ 闸门不可信"
      NEGFAIL=1
    else
      echo "   NEG_OK[negB]: 电平整成单拍脉冲 ⇒ 源还举着时 cpuIrq 自行落 ⇒ 配对判据 SPURIOUS=$bsp"
      echo "                 ⇒ 「保持电平（不自行清）」这一条是**承重**的（= IRQ 电平语义不得变）。"
    fi
  fi
fi

# ===========================================================================
# 8) 负对照 C：复位 —— 释放顺序反转（io_npuRstn = !npuRstSync[1] → = !io_asyncRst）
# ===========================================================================
echo "==== 负对照 C[复位: 释放顺序反转，npu 先于 cpu] 必须红（顺序 + 伪事务）===="
if ! "$PY" - "$rst_nl" "$work/mut_rst.v" > "$work/mgc.out" 2>&1 <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
pat = re.compile(r"assign io_npuRstn = \(! npuRstSync\[1\]\);")
new, n = pat.subn("assign io_npuRstn = (! io_asyncRst);", src)
print("MUTGEN_HITS=%d" % n)
if n != 1: sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(new)
PYEOF
then
  echo "   MUTGEN_RED（命中数不是恰好 1）"; cat "$work/mgc.out" | sed 's/^/      /'; NEGFAIL=1
else
  cat "$work/mgc.out" | sed 's/^/   /'
  if ! "$IVERILOG" -g2012 -o "$work/mut_rst.vvp" "$rst_tb" "$work/mut_rst.v" "$brg_nl" > "$work/ivc.log" 2>&1; then
    echo "   MUT_COMPILE_RED"; sed -n '1,20p' "$work/ivc.log" | sed 's/^/      /'; NEGFAIL=1
  else
    ( cd "$work" && "$VVP" "$work/mut_rst.vvp" > "$work/negC.log" 2>&1 )
    grep -E '^(ORDER|HAZARD|SPURIOUS|COUNTS|RESULT:)' "$work/negC.log" | sed 's/^/   /'
    "$PY" "$work/judge_rst.py" "$work/negC.log" negC 0 > "$work/jnC.out" 2>&1 || true
    cat "$work/jnC.out" | sed 's/^/   /'
    cob=$(sed -n 's/.*ORDER_BAD=\([0-9]*\) .*/\1/p' "$work/jnC.out" | head -1)
    csp=$(sed -n 's/.* SPURIOUS=\([0-9]*\) .*/\1/p' "$work/jnC.out" | head -1)
    if [ "${cob:-0}" = "0" ] && [ "${csp:-0}" = "0" ]; then
      echo "   NEG_RED[negC]: 反转顺序后**没**抓到（ORDER_BAD=${cob:-?} SPURIOUS=${csp:-?}）⇒ 闸门不可信"
      NEGFAIL=1
    else
      echo "   NEG_OK[negC]: 反转释放顺序 ⇒ ORDER_BAD=$cob（npu 先于 cpu）、伪事务 SPURIOUS=$csp"
      echo "                 ⇒ 「cpu 先 / npu 后」这条**顺序契约**是**承重**的。"
    fi
  fi
fi

# ===========================================================================
# 9) 判定
# ===========================================================================
echo "==================== 判定 ===================="
if [ "$NEGFAIL" != "0" ]; then
  echo "负对照/自检没有按预期发火 ⇒ **闸门自身不可信**（不是 DUT 的问题）。"
  echo "VERDICT: NEG-CONTROL-NOT-FIRED"
  echo "RESULT: FAIL (negative controls did not fire)"
  exit 2
fi
if [ "$FAIL" != "0" ]; then
  echo "正作业或对账未全绿（延迟/配对/同步性/顺序/计数/确定性任一项红）⇒ 模块或装置有问题。"
  echo "VERDICT: MISMATCH"
  echo "RESULT: FAIL (positive jobs / ordering / spurious-free)"
  exit 1
fi

echo "正作业 IRQ 4/4 + 复位 3/3 = 全绿：cpu 100MHz / npu 37MHz（非整数比）下，"
echo "  IRQ：~120 个逐段不同相位上置起/清除，cpuIrq 有界延迟（≤2 cpu 周期）、只随 cpu_clk 变、与源配对；"
echo "  反向口同款；复位：npu 晚于 cpu 释放、复位后合法写读经 N3 活网表全 OKAY 且计数相等、无伪事务。"
echo "负对照 3/3 = 发火：① 摘掉同步器 ⇒ 组合跨域（异步/零延迟）；② 电平整成脉冲 ⇒ 保持语义破（伪跳变）；"
echo "  ③ 反转释放顺序 ⇒ npu 先起 + 伪事务。比较器自检 IRQ/复位各恰好 1（不是橡皮图章）。"
echo "VERDICT: N5-OK（IRQ 电平跨域保持语义 + 有界延迟 + 同步性；复位按域同步释放且顺序契约 cpu 先/npu 后；"
echo "  三道负对照 + 两道比较器自检都在承重点上发火）"
echo "RESULT: PASS"
exit 0
