#!/usr/bin/env bash
# =============================================================================
# run_axilite_cdc_ab.sh —— Y1「NPU 独立时钟域」plan Task **N3** 的闸门：
#   **NpuAxiLiteCdc（cpu_clk ⇄ npu_clk 的 AXI4-Lite 异步桥）的独立两时钟正/负对照**。
#   （spec §3-A(a) 主机寄存器窗 CDC / §5-G2 "无丢失/重复" / §6-R1 "复用 CDCPipe 纪律"）
#
# 本闸门要证的（每一档都带**能失败**的对照）：
#   ① **正**（穷举 + 变长从口延迟 + 变相位）：cpu 100 MHz / npu 37 MHz（**非整数比 2.7027…**）
#      下，主机侧 AXI4-Lite 主机逐条执行 stim，npu 侧寄存器从口的响应延迟在 LATMIN..LATMAX
#      **逐笔轮转**（覆盖 1 拍到长延迟），**5 个作业**（含相位平移两种、反压注入、同钟对照）：
#        · 桥那侧收到的写序列（`NPU_W`）与 stim **逐元素相同**（地址/data/strb 全同）
#          ⇒ 无丢失、无重复、无乱序（G2 的"计数 + 数据双判据"：另有 `COUNTS` 计数对账）；
#        · 读地址序列（`NPU_R`）与 stim 逐元素相同；
#        · 主机读回（`HOST_R`）与**独立 python 模型**的黄金**逐字节**相同（MISMATCH=0）。
#   ② **比较器自检**（不盲信）：把黄金里**一个字节**改掉，MISMATCH 必须**恰好 1** ⇒ 证明对账是
#      逐元素/逐字节的，不是"整行不等就算 1"的橡皮图章。
#   ③ **负对照（必须发火）** —— 网表突变（python 定点改一行，命中数必须恰好 1）：
#        NEG-A：W 通道跨域的 **`wstrb` 载荷被短接成 4'hF** ⇒ 半个字节的写被整字写掉
#               ⇒ 桥那侧看到的 strobe 就不是主机发的那个（`WRSEQ>0`），读回也与黄金不符
#               （**数据损坏**，MISMATCH>0）。
#        NEG-B：**AR 跨域被掐断**（`arPipe` 的 enq_valid 恒 0）⇒ 读地址一个都到不了 NPU 侧
#               ⇒ 主机等 RVALID 超时（**事务丢失**），`RESULT: FAIL`。
#        NEG-C：**R 通道的一次性消费掩码被掐掉**（`deq.valid` 从"一笔一个脉冲"退化成电平保持）
#               ⇒ 主机在新一笔 AR 之后握到**上一笔的残留 RVALID** ⇒ 读回整体错位（**陈旧载荷**）。
#      ★ 三道用的都是同一个作业（J1 的配置）**同一份装置**，只有网表不同 ⇒ 红的归因唯一。
#      ★ NEG-C 的锚点**自寻址**（先从顶层 `rPipe` 实例行读出它例化的 `CdcPipeSp*` 模块名），
#        不写死展开序号；命中数不是恰好 1 就 exit 2（闸门不可信），绝不静默跳过。
#
# 退出码（与仓里其它 run_*_ab.sh 同约定）：
#   0 = 通过（5 个正作业全绿 + 逐字节对账 + 计数/序列对账 + 比较器自检恰好 1 + 三道负对照都发火）
#   1 = MISMATCH / 序列或计数不符 / 装置未 PASS / 确定性 2× 不一致 ⇒ 桥或装置有问题
#   2 = 负对照没发火，或比较器自检不是恰好 1 ⇒ **闸门自身不可信**
#   3 = 前置缺失（网表/TB/iverilog/激励生成失败）
#
# 装置契约：rtl_test/NpuAxiLiteCdcTb.v + gen/NpuAxiLiteCdc.v
#   +STIMFILE=<file> 每行 `<op> <addr> <data> <strb>`：op=0 写 / op=1 读（十六进制）。
#   plusargs：+LATMIN= +LATMAX= +WAITMAX= +SAME_CLK +PHASE_INV +PHASE_DLY_PS= +SEED=
#   事实行：CFG / STIM / NPU_W <seq> <addr> <data> <strb> / NPU_R <seq> <addr> /
#           HOST_R <seq> <addr> <data> / COUNTS host_wr=.. host_rd=.. npu_wr=.. npu_rd=.. /
#           TBFAIL .. / RESULT: PASS|FAIL
#   ★ 从口语义（黄金的唯一真源，写在装置文件头、python 按同一口径独立算）：
#       窗内偏移 = addr[13:0]；< 0x80 ⇒ 32 个 32bit 寄存器，写按 **wstrb 逐字节** 合并；
#       ≥ 0x80 ⇒ 读回 `0xBAD00000 ^ addr`（整根 32bit 地址的指纹），写忽略（仍 OKAY）。
# =============================================================================
set -uo pipefail

PY="${PY:-python}"
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
tb="$here/../rtl_test/NpuAxiLiteCdcTb.v"
nl="$here/../gen/NpuAxiLiteCdc.v"

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

echo "== run_axilite_cdc_ab: NpuAxiLiteCdc（AXI4-Lite 异步桥）两时钟正/负对照 =="
echo "   tb =$tb"
echo "   nl =$nl"
echo "   两时钟 = cpu_clk 100.000MHz : npu_clk 37.000MHz（非整数比 100/37 = 2.7027…）"
echo "   工具   = iverilog=${IVERILOG:-<找不到>}  vvp=${VVP:-<找不到>}  tmp=$work"

# ---------------- 前置检查（缺任一件 => 3）----------------
pre_missing=0
[ -f "$tb" ] || { echo "PRECOND-FAIL: 缺 TB $tb"; pre_missing=1; }
[ -f "$nl" ] || { echo "PRECOND-FAIL: 缺网表 $nl"; pre_missing=1; }
[ -n "$IVERILOG" ] || { echo "PRECOND-FAIL: 找不到 iverilog"; pre_missing=1; }
[ -n "$VVP" ]      || { echo "PRECOND-FAIL: 找不到 vvp"; pre_missing=1; }
if [ "$pre_missing" != "0" ]; then
  echo "       先生成网表: cd y1 && printf 'Test/runMain NpuAxiLiteCdcGen D:/code/PDS/VexiiYeshenLinux/y1/gen\\nexit\\n' | bash sbt.sh"
  echo "VERDICT: PRECONDITION-MISSING"; exit 3
fi

# ===========================================================================
# 0) 造激励 + 独立 python 黄金（从口语义见文件头；模式两两不同 ⇒ 地址译码错位藏不住）
# ===========================================================================
if ! "$PY" - "$work" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

work = sys.argv[1]
BASE  = 0xF000C000      # NPU 寄存器窗基址（与 glue 的 NPU_BASE / 装置的 localparam 同）
NREG  = 32

def off2addr(off):
    return (BASE | off) & 0xFFFFFFFF

# ---- 地址派生的、两两不同的模式（C1.1 穷举口径：同一个模式会掩盖地址译码错位）----
def pat(i):
    return (0xA5A50000 | ((i * 0x11 + 0x5A) & 0xFFFF)) & 0xFFFFFFFF

def pat_hi(i):
    return (pat(i) ^ 0x5A5A0000) & 0xFFFFFFFF

stim = []          # (is_write, addr, data, strb)

# 段 A：穷举全部 32 个寄存器（整字 strobe=F），写完再全部回读
for i in range(NREG):
    stim.append((1, off2addr(4 * i), pat(i), 0xF))
for i in range(NREG):
    stim.append((0, off2addr(4 * i), 0, 0))
# 段 B：**逐字节 strobe 穷举**（对 4 个寄存器轮遍 10 种 strobe），每笔写后立刻回读
#   写入值按 (寄存器, strobe) 派生 ⇒ 全部两两不同（含 strobe=0 的"零字节写"）
STROBES = [0x0, 0x1, 0x2, 0x4, 0x8, 0xF, 0x3, 0xC, 0x5, 0xA, 0x9, 0x6, 0xB, 0xD, 0xE, 0x7]
for j, r in enumerate([0, 5, 13, 31]):
    for s in STROBES:
        stim.append((1, off2addr(4 * r), pat_hi(r) ^ (0x11 * (j * 16 + s)) ^ (s << 8), s))
        stim.append((0, off2addr(4 * r), 0, 0))
# 段 C：极值/交替模式（整字），写完立刻回读（stuck-at 与位序都藏不住）
EXT = [0x00000000, 0xFFFFFFFF, 0xAAAAAAAA, 0x55555555, 0xDEADBEEF, 0x0F0F0F0F, 0xF0F0F0F0, 0x80000001]
for j, v in enumerate(EXT):
    r = 16 + j
    stim.append((1, off2addr(4 * r), v, 0xF))
    stim.append((0, off2addr(4 * r), 0, 0))
# 段 D：窗外（偏移 ≥ 0x80）—— 读回整根 32bit 地址的指纹（地址高位错一位就变）
for off in [0x80, 0x100, 0x200, 0x1FFC, 0x3FFC, 0x0100, 0x3454]:
    stim.append((0, off2addr(off), 0, 0))
# 段 E：窗外写必须被忽略（仍 OKAY）：先窗外写垃圾，再看窗内寄存器一字未动
stim.append((1, off2addr(0x1000), 0xCAFEF00D, 0xF))
stim.append((0, off2addr(0x1000), 0, 0))            # 窗外读 = 指纹（不受那次写影响）
for r in [0, 17, 31]:
    stim.append((0, off2addr(4 * r), 0, 0))         # 窗内值仍应等于段 C 之后的样子
# 段 F：窗内**逐字节** strobe 再打一遍（与段 B 不同的寄存器/不同的派生值）
for r in [3, 9, 22, 27]:
    stim.append((1, off2addr(4 * r), (0x00F00000 | (r << 8) | 0x3C) & 0xFFFFFFFF, 0x5))
    stim.append((0, off2addr(4 * r), 0, 0))
    stim.append((1, off2addr(4 * r), (0xF0000000 | (r << 16) | 0xA5) & 0xFFFFFFFF, 0xA))
    stim.append((0, off2addr(4 * r), 0, 0))

# ---- 从口语义模型（黄金）----
def golden(stim):
    rf = [0] * NREG
    out = []
    for (w, a, d, s) in stim:
        off = a & 0x3FFF
        if w:
            if off < 0x80:
                i = off >> 2
                v = rf[i]
                for lane in range(4):
                    if (s >> lane) & 1:
                        m = 0xFF << (lane * 8)
                        v = ((v & ~m) | (d & m)) & 0xFFFFFFFF
                rf[i] = v
        else:
            out.append(rf[off >> 2] if off < 0x80 else (0xBAD00000 ^ a) & 0xFFFFFFFF)
    return out

g     = golden(stim)
rd    = [a for (w, a, d, s) in stim if not w]     # 读地址序列（与 g 一一对应）

# ---- 自检 1：写模式两两不同（C1.1 口径：同一个模式会掩盖地址译码错位）----
wpts = [d for (w, a, d, s) in stim if w]
assert len(wpts) == len(set(wpts)), "FATAL: 写模式出现撞值 => 地址译码错位会静默通过"
# ---- 自检 2：部分 strobe 写要够多，且必须覆盖 strobe=0（零字节写）与整字 ----
partial = [s for (w, a, d, s) in stim if w and s != 0xF]
assert len(partial) >= 20, "FATAL: 部分 strobe 写太少"
assert 0x0 in partial and 0xF in [s for (w, a, d, s) in stim if w], "FATAL: strobe 没覆盖全"
# ---- 自检 3（**针对本桥的风险类**）：**地址不同的相邻两次回读，值必须不同** ----
#   否则"把第 i 笔的 R 配给第 i+1 笔"这类错位/陈旧载荷会**看不出来**。
#   （地址相同的相邻回读允许值相同：那是刻意的"不变量探针"，值本身没有区分度。）
bad = [(i, rd[i - 1], rd[i]) for i in range(1, len(g)) if rd[i] != rd[i - 1] and g[i] == g[i - 1]]
assert not bad, "FATAL: 地址不同的相邻回读撞值 %d 处 => 陈旧/错位载荷抓不住" % len(bad)
# ---- 自检 4：窗外读（整根 32bit 地址的指纹）要够多且地址互不相同 ----
oor = sorted(set(a for a in rd if (a & 0x3FFF) >= 0x80))
assert len(oor) >= 5, "FATAL: 窗外读探针太少"
assert len(set((0xBAD00000 ^ a) & 0xFFFFFFFF for a in oor)) == len(oor), "FATAL: 窗外指纹撞值"

open(work + "/stim.txt", "w").write(
    "".join(("%x %08x %08x %x\n" % (1, a, d, s)) if w else ("%x %08x\n" % (0, a))
            for (w, a, d, s) in stim))
print("STIMGEN_OK n=%d nw=%d nr=%d partial_w=%d oor_reads=%d"
      % (len(stim), len(wpts), len(rd), len(partial), len(oor)))
PYEOF
then
  echo "VERDICT: PRECONDITION-MISSING (激励生成失败)"; exit 3
fi
[ -s "$work/stim.txt" ] || { echo "VERDICT: PRECONDITION-MISSING (stim.txt 缺失)"; exit 3; }
echo "   stim = $work/stim.txt（$(wc -l < "$work/stim.txt") 行）"

# ===========================================================================
# 1) 判据器：从口语义模型（黄金）+ 三方对账（NPU_W/NPU_R/COUNTS vs stim；HOST_R vs 黄金）
#    用法： judge.py <work> <log> [tag] [perturb]
#      perturb=0：正常；perturb=1：把黄金里**第 1 个字节** XOR 0x01（比较器自检用）
# ===========================================================================
cat > "$work/judge.py" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

work, log, tag = sys.argv[1], sys.argv[2], sys.argv[3]
perturb = int(sys.argv[4]) if len(sys.argv) > 4 else 0

# ---- stim（**按文件顺序**读入：写/读是交错的，黄金必须按同一顺序推演）----
order, sw, sr = [], [], []
for ln in open(work + "/stim.txt"):
    t = ln.split()
    if len(t) == 4 and t[0] == "1":
        order.append(("W", int(t[1], 16), int(t[2], 16), int(t[3], 16)))
        sw.append((int(t[1], 16), int(t[2], 16), int(t[3], 16)))
    elif len(t) == 2 and t[0] == "0":
        order.append(("R", int(t[1], 16), 0, 0))
        sr.append(int(t[1], 16))

# ---- 从口模型（黄金；与装置文件头/Verilog 的语义同一口径，独立实现）----
def golden(order):
    rf = [0] * 32
    out = []
    for (k, a, d, s) in order:
        off = a & 0x3FFF
        if k == "W":
            if off < 0x80:
                i = off >> 2
                v = rf[i]
                for lane in range(4):
                    if (s >> lane) & 1:
                        m = 0xFF << (lane * 8)
                        v = ((v & ~m) | (d & m)) & 0xFFFFFFFF
                rf[i] = v
        else:
            out.append(rf[off >> 2] if off < 0x80 else (0xBAD00000 ^ a) & 0xFFFFFFFF)
    return out

g = golden(order)
if perturb:
    g[0] ^= 0x01                     # 只翻**一个字节的最低位** ⇒ 恰好 1 个字节不符

# ---- 装置事实行 ----
nw, nr, hr, counts, res = [], [], [], None, None
for ln in open(log, errors="replace"):
    t = ln.split()
    if not t:
        continue
    if t[0] == "NPU_W" and len(t) >= 5:
        nw.append((int(t[2], 16), int(t[3], 16), int(t[4], 16)))
    elif t[0] == "NPU_R" and len(t) >= 3:
        nr.append(int(t[2], 16))
    elif t[0] == "HOST_R" and len(t) >= 4:
        hr.append((int(t[2], 16), int(t[3], 16)))
    elif t[0] == "COUNTS":
        counts = ln.split(None, 1)[1].strip()
    elif t[0] == "RESULT:" and t[1] == "PASS":
        res = "PASS"

# ---- ① 写序列逐元素对账（无丢失/无重复/无乱序）----
wx = 0
if len(nw) != len(sw):
    wx += abs(len(nw) - len(sw))
    print("[%s] WRSEQ_LEN npu_w=%d stim_w=%d" % (tag, len(nw), len(sw)))
for i in range(min(len(nw), len(sw))):
    if nw[i] != sw[i]:
        wx += 1
        if wx <= 5:
            print("[%s] WRSEQ_MISMATCH idx=%d npu=%s stim=%s" % (tag, i, nw[i], sw[i]))
# ---- ② 读地址序列逐元素对账 ----
rx = 0
if len(nr) != len(sr):
    rx += abs(len(nr) - len(sr))
    print("[%s] RDSEQ_LEN npu_r=%d stim_r=%d" % (tag, len(nr), len(sr)))
for i in range(min(len(nr), len(sr))):
    if nr[i] != sr[i]:
        rx += 1
        if rx <= 5:
            print("[%s] RDSEQ_MISMATCH idx=%d npu=%08x stim=%08x" % (tag, i, nr[i], sr[i]))
# ---- ③ 主机读回 vs 黄金（逐字 + 逐字节）----
mx = 0; mb = 0; first = -1
if len(hr) != len(sr):
    mx += abs(len(hr) - len(sr))
    print("[%s] HOSTR_LEN host_r=%d stim_r=%d" % (tag, len(hr), len(sr)))
for i in range(min(len(hr), len(sr))):
    a, v = hr[i]
    if a != sr[i]:
        mx += 1
        print("[%s] HOSTR_ADDR idx=%d host=%08x stim=%08x" % (tag, i, a, sr[i]))
        continue
    if v != g[i]:
        mx += 1
        if mx <= 5:
            print("[%s] HOSTR_VALUE idx=%d addr=%08x got=%08x expect=%08x" % (tag, i, a, v, g[i]))
        for b in range(4):
            if ((v >> (8 * b)) & 0xFF) != ((g[i] >> (8 * b)) & 0xFF):
                mb += 1
                if first < 0:
                    first = i * 4 + b
# ---- ④ 计数对账 ----
cx = 0
if counts is None:
    cx += 1; print("[%s] COUNTS_MISSING" % tag)
else:
    exp = "host_wr=%d host_rd=%d npu_wr=%d npu_rd=%d" % (len(sw), len(sr), len(sw), len(sr))
    if counts != exp:
        cx += 1; print("[%s] COUNTS_MISMATCH got=[%s] expect=[%s]" % (tag, counts, exp))

print("[%s] MISMATCH=%d MISMATCH_BYTES=%d FIRST_OFF=%d" % (tag, mx, mb, first))
print("[%s] WRSEQ=%d RDSEQ=%d COUNTS=%d RESULT=%s" % (tag, wx, rx, cx, res or "?"))
PYEOF

# ===========================================================================
# 2) 编译（好网表；负对照另编）
# ===========================================================================
if ! "$IVERILOG" -g2012 -o "$work/sim.vvp" "$tb" "$nl" > "$work/iv.log" 2>&1; then
  echo "PRECOND-FAIL: iverilog 编译失败（好网表）:"; sed -n '1,40p' "$work/iv.log"
  echo "VERDICT: PRECONDITION-MISSING (compile)"; exit 3
fi
echo "---- iverilog 编译 OK（好网表）----"

# 跑一次仿真。用法: run_sim <netlist_vvp> <base> <plusargs...>
run_sim() {
  local vvp="$1"; local base="$2"; shift 2
  ( cd "$work" && "$VVP" "$vvp" "+STIMFILE=$work/stim.txt" "$@" > "$base.log" 2>&1 )
}
norm_log() { sed -E 's#([+][A-Za-z_]+=)[^ ]+#\1PATH#g' "$1"; }

FAIL=0          # 1 = 正/对账失败 ⇒ exit 1
NEGFAIL=0       # 1 = 负对照/自检没发火 ⇒ exit 2

# ===========================================================================
# 3) 正作业：5 档（延迟区间 × 相位 × 反压 × 同钟），每档跑两次（确定性 2×）
#    J1 基准延迟轮转 1..7，零反压，0 相位
#    J2 长延迟 13..13（素数、远超同步深度），反压 3 拍，npu 相位平移半周期
#    J3 延迟 1..5，反压 5 拍，npu 相位半周期 + 再平移 6757ps（≈1/4 个 npu 周期）
#    J4 延迟 4..4 恒值，反压 1 拍，npu 相位平移 1201ps
#    J5 同钟（+SAME_CLK，100/100）延迟 1..7 ⇒ 与跨域无关的 AXI 协议对照
# ===========================================================================
run_pos() {   # <tag> <plusargs...>
  local tag="$1"; shift
  run_sim "$work/sim.vvp" "$tag" "$@"
  run_sim "$work/sim.vvp" "${tag}__2" "$@"
  local ok=1
  if diff -q <(norm_log "$work/$tag.log") <(norm_log "$work/${tag}__2.log") >/dev/null 2>&1; then
    echo "   DETERMINISM[$tag]=OK（两次日志逐字节相同）"
  else
    echo "   DETERMINISM[$tag]=DIFF（两次日志不同！）"; ok=0
  fi
  grep -q '^RESULT: PASS' "$work/$tag.log" || { echo "   TB_RED[$tag]"; grep -E '^(RESULT|TBFAIL)' "$work/$tag.log" | head -5 | sed 's/^/      /'; ok=0; }
  grep -E '^(CFG|STIM|COUNTS|RESULT:)' "$work/$tag.log" | sed 's/^/   /'
  "$PY" "$work/judge.py" "$work" "$work/$tag.log" "$tag" 0 > "$work/j_$tag.out" 2>&1 || true
  cat "$work/j_$tag.out" | sed 's/^/   /'
  local mis=$(sed -n 's/.*MISMATCH=\([0-9]*\) .*/\1/p' "$work/j_$tag.out" | head -1)
  local wsq=$(sed -n 's/.*WRSEQ=\([0-9]*\) .*/\1/p' "$work/j_$tag.out" | head -1)
  local rdq=$(sed -n 's/.*RDSEQ=\([0-9]*\) .*/\1/p' "$work/j_$tag.out" | head -1)
  local cnq=$(sed -n 's/.*RDSEQ=[0-9]* COUNTS=\([0-9]*\) .*/\1/p' "$work/j_$tag.out" | head -1)
  if [ "${mis:-X}" != "0" ] || [ "${wsq:-X}" != "0" ] || [ "${rdq:-X}" != "0" ] || [ "${cnq:-X}" != "0" ]; then
    ok=0
  fi
  [ "$ok" = "1" ] && echo "   POS_OK[$tag]: 逐字节 MISMATCH=0；写/读序列与计数全对"
  return $(( 1 - ok ))
}

echo "==== 正作业 1/5：延迟轮转 1..7、零反压、0 相位 ===="
run_pos j1 "+LATMIN=1" "+LATMAX=7" "+WAITMAX=0" || FAIL=1
echo "==== 正作业 2/5：长延迟 13..13、反压 3、npu 相位半周期移位 ===="
run_pos j2 "+LATMIN=13" "+LATMAX=13" "+WAITMAX=3" "+PHASE_INV" || FAIL=1
echo "==== 正作业 3/5：延迟 1..5、反压 5、相位再平移 6757ps ===="
run_pos j3 "+LATMIN=1" "+LATMAX=5" "+WAITMAX=5" "+PHASE_INV" "+PHASE_DLY_PS=6757" || FAIL=1
echo "==== 正作业 4/5：延迟 4..4 恒值、反压 1、相位平移 1201ps ===="
run_pos j4 "+LATMIN=4" "+LATMAX=4" "+WAITMAX=1" "+PHASE_DLY_PS=1201" || FAIL=1
echo "==== 正作业 5/5：同钟对照（+SAME_CLK）、延迟 1..7、反压 2 ===="
run_pos j5 "+LATMIN=1" "+LATMAX=7" "+WAITMAX=2" "+SAME_CLK" || FAIL=1

# ---- 比较器自检（用刚跑出来的 j1 日志）：黄金里翻**一个字节的最低位** ⇒ MISMATCH 必须恰好 1 ----
echo "---- [自检·比较器] 黄金第 1 个字节 XOR 0x01 ⇒ MISMATCH 必须恰好 1 ----"
"$PY" "$work/judge.py" "$work" "$work/j1.log" selftest 1 > "$work/j_selftest.out" 2>&1 || true
cat "$work/j_selftest.out" | sed 's/^/   /'
sm="$(sed -n 's/.*MISMATCH=\([0-9]*\) .*/\1/p' "$work/j_selftest.out" | head -1)"
sb="$(sed -n 's/.*MISMATCH_BYTES=\([0-9]*\) .*/\1/p' "$work/j_selftest.out" | head -1)"
if [ "${sm:-X}" = "1" ] && [ "${sb:-X}" = "1" ]; then
  echo "   SELFTEST_OK（恰好 1 笔 / 1 个字节 ⇒ 对账是逐元素逐字节的，不是橡皮图章）"
else
  echo "   SELFTEST_RED: MISMATCH=${sm:-?} MISMATCH_BYTES=${sb:-?}（应各为 1）⇒ 闸门不可信"
  NEGFAIL=1
fi

# ===========================================================================
# 5) 负对照 A：网表突变 —— W 跨域的 **wstrb 载荷短接成 4'hF**
#    锚点 = 顶层 `wPipe` 例化的 `.io_enq_payload_strb (io_axilite_w_payload_strb[3:0] )`，
#    全文件**恰好 1 处**（其余 4 条管道没有 strb 载荷）⇒ 归因唯一。
# ===========================================================================
echo "==== 负对照 A[网表突变: W 的 wstrb 短接 4'hF] 必须红（数据损坏）===="
if ! "$PY" - "$nl" "$work/mut_strb.v" > "$work/mutgen_a.out" 2>&1 <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
src = open(sys.argv[1], encoding="utf-8").read()
pat = re.compile(r"\.io_enq_payload_strb\s*\(io_axilite_w_payload_strb\s*\[\s*3\s*:\s*0\s*\]\s*\)")
new, n = pat.subn(".io_enq_payload_strb (4'hF) ", src)
print("MUTGEN_HITS=%d" % n)
if n != 1:
    sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(new)
PYEOF
then
  echo "   MUTGEN_RED（锚点命中数不是恰好 1）"; cat "$work/mutgen_a.out" | sed 's/^/      /'; NEGFAIL=1
else
  cat "$work/mutgen_a.out" | sed 's/^/   /'
  if ! "$IVERILOG" -g2012 -o "$work/mut_strb.vvp" "$tb" "$work/mut_strb.v" > "$work/iv_a.log" 2>&1; then
    echo "   MUT_COMPILE_RED"; sed -n '1,20p' "$work/iv_a.log" | sed 's/^/      /'; NEGFAIL=1
  else
    run_sim "$work/mut_strb.vvp" negA "+LATMIN=1" "+LATMAX=7" "+WAITMAX=0"
    grep -E '^(RESULT:|TBFAIL)' "$work/negA.log" | sed 's/^/   /'
    "$PY" "$work/judge.py" "$work" "$work/negA.log" negA 0 > "$work/j_negA.out" 2>&1 || true
    cat "$work/j_negA.out" | sed -n '1,12p' | sed 's/^/   /'
    am=$(sed -n 's/.*MISMATCH=\([0-9]*\) .*/\1/p' "$work/j_negA.out" | head -1)
    ab=$(sed -n 's/.*MISMATCH_BYTES=\([0-9]*\) .*/\1/p' "$work/j_negA.out" | head -1)
    aw=$(sed -n 's/.*WRSEQ=\([0-9]*\) .*/\1/p' "$work/j_negA.out" | head -1)
    if [ -z "${ab:-}" ] || [ "${ab:-0}" = "0" ]; then
      echo "   NEG_RED[negA]: 短接 wstrb 后**没**抓到字节损坏（MISMATCH=${am:-?} BYTES=${ab:-?}）⇒ 闸门不可信"
      NEGFAIL=1
    else
      echo "   NEG_OK[negA]: 短接 wstrb ⇒ **字节对账** MISMATCH=${am} BYTES=$ab > 0（首个不符字节偏移"
      echo "                 $(sed -n 's/.*FIRST_OFF=\([0-9-]*\).*/\1/p' "$work/j_negA.out" | head -1)）；序列对账 WRSEQ=${aw}"
      echo "                 （参考：好网表同一配置 WRSEQ=0/MISMATCH=0）"
      echo "                 ⇒ 「wstrb 必须跟着数据一起跨」这一拍是**承重**的。"
    fi
  fi
fi

# ===========================================================================
# 6) 负对照 B：网表突变 —— **AR 跨域掐断**（arPipe 的 enq_valid 恒 0）
#    锚点 = 顶层 `arPipe` 例化的 `.io_enq_valid (io_axilite_ar_valid )`，全文件恰好 1 处。
#    期望：读地址一笔都到不了 NPU 侧 ⇒ 主机等 RVALID 超时 ⇒ `RESULT: FAIL`（**事务丢失**）。
# ===========================================================================
echo "==== 负对照 B[网表突变: AR 跨域掐断] 必须红（读事务丢失）===="
if ! "$PY" - "$nl" "$work/mut_ar.v" > "$work/mutgen_b.out" 2>&1 <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
src = open(sys.argv[1], encoding="utf-8").read()
pat = re.compile(r"\.io_enq_valid\s*\(io_axilite_ar_valid\s*\)")
new, n = pat.subn(".io_enq_valid (1'b0)", src)
print("MUTGEN_HITS=%d" % n)
if n != 1:
    sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(new)
PYEOF
then
  echo "   MUTGEN_RED（锚点命中数不是恰好 1）"; cat "$work/mutgen_b.out" | sed 's/^/      /'; NEGFAIL=1
else
  cat "$work/mutgen_b.out" | sed 's/^/   /'
  if ! "$IVERILOG" -g2012 -o "$work/mut_ar.vvp" "$tb" "$work/mut_ar.v" > "$work/iv_b.log" 2>&1; then
    echo "   MUT_COMPILE_RED"; sed -n '1,20p' "$work/iv_b.log" | sed 's/^/      /'; NEGFAIL=1
  else
    run_sim "$work/mut_ar.vvp" negB "+LATMIN=1" "+LATMAX=7" "+WAITMAX=0"
    grep -E '^(RESULT:|TBFAIL|COUNTS)' "$work/negB.log" | sed 's/^/   /'
    bres="$(grep -m1 '^RESULT:' "$work/negB.log" || true)"
    bnpu="$(grep -c '^NPU_R' "$work/negB.log")"
    if [ "${bres#RESULT: FAIL}" = "$bres" ]; then
      echo "   NEG_RED[negB]: 掐断 AR 后装置**没有**报红（[${bres:-无 RESULT 行}]）⇒ 闸门不可信"
      NEGFAIL=1
    else
      echo "   NEG_OK[negB]: 掐断 AR ⇒ 装置红：[$bres]（NPU_R 事实行数=$bnpu ⇒ 读地址一笔没跨过去；"
      echo "                 好网表同配置下 NPU_R 行数 = stim 的读条数）"
      echo "                 ⇒ 「读地址必须跨域」这一拍是**承重**的。"
    fi
  fi
fi

# ===========================================================================
# 7) 负对照 C：网表突变 —— **把 R 通道的一次性消费掩码掐掉**（"缩短握手纪律"）
#    `CDCPipe` 的四相电平握手在目的域**握手后仍然举着 deq.valid**（电平要保持到源撤 req）
#    —— 对 AXI 而言那是"同一笔会被消费两次"的坑，本桥用 `dMask` 把它收敛成"一笔 = 一个
#    valid 脉冲"（见 RTL 文件头）。这里把 `dMask` 从 valid 表达式里摘掉 ⇒ **退化成电平保持**，
#    主机在新一笔 AR 之后立刻会"握"到上一笔的残留 RVALID ⇒ 读数据错位（**陈旧载荷**）。
#    ★ 锚点用**自寻址**：先从顶层 `rPipe` 实例行里读出它例化的那个 `CdcPipeSp*` 模块名，
#      只在该模块体内改一行（命中数必须恰好 1）—— 不写死 `CdcPipeSp_4` 这种展开序号。
#    ★ 这一道**必然发火**由生成器的"自检 3"保证：地址不同的相邻两次回读，黄金值必不相同
#      ⇒ 把上一笔的数据配给下一笔，一定对不上。
# ===========================================================================
echo "==== 负对照 C[网表突变: R 通道一次性掩码掐掉] 必须红（陈旧/错位载荷）===="
if ! "$PY" - "$nl" "$work/mut_mask.v" > "$work/mutgen_c.out" 2>&1 <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
src = open(sys.argv[1], encoding="utf-8").read()
# ① 顶层 rPipe 例化的模块名
m = re.search(r"^\s*(CdcPipeSp\w*)\s+rPipe\s*\(", src, re.M)
if not m:
    print("MUTGEN_ERR=no_rPipe_instance"); sys.exit(2)
mod = m.group(1)
# ② 只在该模块体内改（module <mod> ( ... endmodule）
start = src.index("module %s (" % mod)
end   = src.index("endmodule", start)
block = src[start:end]
pat = re.compile(r"assign io_deq_valid = \(dPending && \(! dMask\)\);")
new, n = pat.subn("assign io_deq_valid = dPending;", block)
print("MUTGEN_MODULE=%s MUTGEN_HITS=%d" % (mod, n))
if n != 1:
    sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(src[:start] + new + src[end:])
PYEOF
then
  echo "   MUTGEN_RED（锚点命中数不是恰好 1）"; cat "$work/mutgen_c.out" | sed 's/^/      /'; NEGFAIL=1
else
  cat "$work/mutgen_c.out" | sed 's/^/   /'
  if ! "$IVERILOG" -g2012 -o "$work/mut_mask.vvp" "$tb" "$work/mut_mask.v" > "$work/iv_c.log" 2>&1; then
    echo "   MUT_COMPILE_RED"; sed -n '1,20p' "$work/iv_c.log" | sed 's/^/      /'; NEGFAIL=1
  else
    run_sim "$work/mut_mask.vvp" negC "+LATMIN=1" "+LATMAX=7" "+WAITMAX=0"
    grep -E '^(RESULT:|TBFAIL|COUNTS)' "$work/negC.log" | sed 's/^/   /'
    "$PY" "$work/judge.py" "$work" "$work/negC.log" negC 0 > "$work/j_negC.out" 2>&1 || true
    cat "$work/j_negC.out" | sed -n '1,10p' | sed 's/^/   /'
    cm=$(sed -n 's/.*MISMATCH=\([0-9]*\) .*/\1/p' "$work/j_negC.out" | head -1)
    cw=$(sed -n 's/.*WRSEQ=\([0-9]*\) .*/\1/p' "$work/j_negC.out" | head -1)
    cr="$(grep -m1 '^RESULT:' "$work/negC.log" || true)"
    if [ -z "${cm:-}" ] || [ "${cm:-0}" = "0" ]; then
      echo "   NEG_RED[negC]: 掐掉一次性掩码后**没**抓到错位（MISMATCH=${cm:-?}、[${cr:-无 RESULT}]）⇒ 闸门不可信"
      NEGFAIL=1
    else
      echo "   NEG_OK[negC]: 掐掉 R 的一次性掩码 ⇒ 读回错位：MISMATCH=$cm（写序列 WRSEQ=${cw}、[${cr}]）"
      echo "                 ⇒ 「deq.valid 必须一笔一个脉冲（而不是电平保持）」这一格是**承重**的"
      echo "                    —— 这也是本装置初版**当场抓到**的那个坑（当时 AR 还没跨过去，"
      echo "                    主机就握到了上一笔的残留 RVALID）。"
    fi
  fi
fi

# ===========================================================================
# 8) 判定
# ===========================================================================
echo "==================== 判定 ===================="
if [ "$NEGFAIL" != "0" ]; then
  echo "负对照/自检没有按预期发火 ⇒ **闸门自身不可信**（不是 DUT 的问题）。"
  echo "VERDICT: NEG-CONTROL-NOT-FIRED"
  echo "RESULT: FAIL (negative controls did not fire)"
  exit 2
fi
if [ "$FAIL" != "0" ]; then
  echo "正作业或对账未全绿（逐字节/序列/计数/确定性任一项红）⇒ 桥或装置有问题。"
  echo "VERDICT: MISMATCH"
  echo "RESULT: FAIL (positive jobs / byte-exact accounting)"
  exit 1
fi

echo "正作业 5/5 = 全绿：cpu 100MHz / npu 37MHz（非整数比）下，5 档配置（延迟轮转 1..7 / 恒 13 /"
echo "  1..5 / 恒 4；相位 0 / 半周期 / +6757ps / +1201ps；反压 0/3/5/1；含同钟对照）"
echo "  逐条：RESULT: PASS、NPU_W == stim 写序列（逐元素）、NPU_R == stim 读序列、COUNTS 全对、"
echo "  HOST_R 与独立 python 黄金**逐字节 MISMATCH=0**、确定性 2× 一致。"
echo "负对照 3/3 = 发火：① wstrb 短接 ⇒ 字节损坏（MISMATCH>0、序列仍对）；② AR 掐断 ⇒ 事务丢失（装置红）；"
echo "  ③ R 的一次性消费掩码掐掉 ⇒ 读回错位（陈旧载荷，MISMATCH>0）。三道都压在跨域承重点上。"
echo "比较器自检 = 恰好 1 笔 / 1 字节（不是橡皮图章）。"
echo "VERDICT: N3-OK（AXI4-Lite 异步桥：跨域无丢失/无重复/字节级正确；三道负对照 + 比较器自检都在承重点上发火）"
echo "RESULT: PASS"
exit 0
