#!/usr/bin/env bash
# =============================================================================
# run_mem_cdc_ab.sh —— Y1「NPU 独立时钟域」plan Task **N4** 的闸门：
#   **NpuMemCdc（cpu_clk ⇄ npu_clk 的 AXI4 内存主口异步桥）的独立两时钟正/负对照**。
#   （spec §3-A(b) 内存主口 CDC / §4.4 burst 口径 / §5-G2 "无丢失/重复" / §6-R1 复用 CDCPipe 纪律）
#
# 本闸门要证的（每一档都带**能失败**的对照）：
#   ① **正**（cpu 100 MHz / npu 37 MHz，非整数比 2.7027…；**变长从口延迟**由 stall shim 注入）：
#      npu 侧手摇 AXI4 主口按 stim 脚本逐条执行 —— awlen 0..15 全覆盖的**带状写**（含 16 种 wstrb，
#      含部分字节/零字节写）、**块拷贝**（bpb∈{4,8,12,16}）、**回读**；**4 个作业**（相位平移两档、
#      停滞注入 0/3/7 拍、同钟对照），每档跑两次（确定性 2×）：
#        · **计数判据（无丢失/无重复的第一半）**：TB 侧 `COUNTS awb/arb/bok/wbeats/rbeats` 与
#          内存模型 `MEM rd=/wr=/bursts=/maxburst=` 双双等于独立 python 黄金的期望值（**两处独立
#          计数一起对得上**才算数）；
#        · **数据判据（第二半）**：TB 逐拍 `RD` 事实行与黄金**逐字节**相同（读路径无丢失/重复/错位），
#          且仿真末导出镜像与黄金镜像**整片逐字节**相同（写路径含部分 wstrb 一字不差）。
#   ② **比较器自检**（不盲信）：把黄金镜像里**一个字节**改掉，MISMATCH 必须**恰好 1** ⇒ 证明对账
#      是逐字节的，不是橡皮图章。
#   ③ **负对照（必须发火）** —— 网表突变（python 定点改一行，命中数必须恰好 1）：
#        NEG-A：W 跨域的 **`wstrb` 载荷被短接成 8'hFF** ⇒ 部分字节写被整字写掉 ⇒ 字节对账必须
#               MISMATCH>0（且内存模型的 `wr=` 计数也偏大）。
#        NEG-B：**AR 跨域被掐断**（arPipe 的 enq_valid 恒 0）⇒ 读地址一个都到不了 cpu 侧
#               ⇒ 主口等 RVALID 超时 ⇒ 装置必须红（**事务丢失**）。
#        NEG-C：**R 通道的 deq.valid 恒 1**（空队列也给 valid）⇒ 主口读到陈旧/重复载荷
#               ⇒ 读回错位/挂死（**陈旧载荷**）。
#      ★ 三道用同一份装置、同一份 stim，只有网表不同 ⇒ 红的归因唯一。
#      ★ NEG-C 的锚点是顶层 `assign npuMem_r_valid = rPipe_io_deq_valid;`（全文件恰好 1 处）。
#
# 退出码（与仓里其它 run_*_ab.sh 同约定）：
#   0 = 通过（4 个正作业全绿 + 逐字节对账 + 计数/序列对账 + 比较器自检恰好 1 + 三道负对照都发火）
#   1 = MISMATCH / 序列或计数不符 / 装置未 PASS / 确定性 2× 不一致 ⇒ 桥或装置有问题
#   2 = 负对照没发火，或比较器自检不是恰好 1 ⇒ **闸门自身不可信**
#   3 = 前置缺失（网表/TB/内存模型/iverilog/激励生成失败）
#
# 装置契约：rtl_test/NpuMemCdcTb.v + rtl_test/AxiMemModel.v + gen/NpuMemCdc.v
#   激励：每行 `<op> <addr> <dst> <bytes> <bpb> <strb> <pat>`（十六进制；语义见 TB 文件头）
#   plusargs：+STIMFILE= +MEMFILE= +DUMPFILE= +dump +STALLMAX= +SAME_CLK +PHASE_INV +PHASE_DLY_PS= +SEED=
#   事实行：CFG / STIM / AWB / ARB / BOK / WBEAT / RD / COUNTS / TBFAIL / RESULT: PASS|FAIL
#          内存模型：MEM rd= wr= bursts= maxburst=
# =============================================================================
set -uo pipefail

PY="${PY:-python}"
here="$(cd "$(dirname "$0")" && pwd)"
tb="$here/../rtl_test/NpuMemCdcTb.v"
memv="$here/../rtl_test/AxiMemModel.v"
nl="$here/../gen/NpuMemCdc.v"
MEMSZ=32768

work_msys="$(mktemp -d)"
# ⚠️ 本机 `python` 是 Windows 版，看不懂 MSYS `/tmp` ⇒ 全脚本用 **cygpath -m** 的混合路径（C:/...）。
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

echo "== run_mem_cdc_ab: NpuMemCdc（AXI4 内存主口异步桥）两时钟正/负对照 =="
echo "   tb  =$tb"
echo "   mem =$memv"
echo "   nl  =$nl"
echo "   两时钟 = cpu_clk 100.000MHz : npu_clk 37.000MHz（非整数比 100/37 = 2.7027…）"
echo "   工具   = iverilog=${IVERILOG:-<找不到>}  vvp=${VVP:-<找不到>}  tmp=$work"

# ---------------- 前置检查（缺任一件 => 3）----------------
pre_missing=0
[ -f "$tb" ]   || { echo "PRECOND-FAIL: 缺 TB $tb"; pre_missing=1; }
[ -f "$memv" ] || { echo "PRECOND-FAIL: 缺内存模型 $memv"; pre_missing=1; }
[ -f "$nl" ]   || { echo "PRECOND-FAIL: 缺网表 $nl"; pre_missing=1; }
[ -n "$IVERILOG" ] || { echo "PRECOND-FAIL: 找不到 iverilog"; pre_missing=1; }
[ -n "$VVP" ]      || { echo "PRECOND-FAIL: 找不到 vvp"; pre_missing=1; }
if [ "$pre_missing" != "0" ]; then
  echo "       先生成网表: cd y1 && printf 'Test/runMain NpuMemCdcGen D:/code/PDS/VexiiYeshenLinux/y1/gen\\nexit\\n' | bash sbt.sh"
  echo "VERDICT: PRECONDITION-MISSING"; exit 3
fi

# ===========================================================================
# 0) 造 stim + 独立 python 黄金（预载镜像 / 末态镜像 / 逐拍读回序列 / 计数器期望）
# ===========================================================================
if ! "$PY" - "$work" "$MEMSZ" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

work = sys.argv[1]
MEMSZ = int(sys.argv[2])

# 模式真源（与 rtl_test/NpuMemCdcTb.v 的 pbyte() **同一公式**，独立实现）
def pbyte(a, k, j, pat):
    return (pat ^ (a & 0xFF) ^ ((a >> 8) & 0xFF) ^ ((k*0x11) & 0xFF) ^ ((j*0x59) & 0xFF)) & 0xFF

def pre(i):                       # 预载模式：周期 251、131 与 251 互素 ⇒ 非平凡
    return ((i % 251) * 131 + 7) % 251

# ---------------------------------------------------------------------------
# 作业表（每项 = (op, addr, dst, bytes, bpb, strb, pat)）
#   op 0 = WRITE（带状写，按 strb 逐字节）/ 1 = READ（回读）/ 2 = COPY（读进缓冲再整块写）
# ---------------------------------------------------------------------------
jobs = []
# 段 A：awlen 0..15 全覆盖（bpb=1..16，每笔单突发），strb 轮遍整字/部分/零字节
STROBES = [0xFF,0x0F,0xF0,0x01,0x80,0xAA,0x55,0x03,0x0C,0x30,0xC0,0xE7,0x18,0x7E,0x81,0x00]
for idx, bpb in enumerate(range(1, 17)):
    a = 0x0000 + idx * 0x100
    jobs.append((0, a, 0, bpb*8, bpb, STROBES[idx], (0x13*idx + 0x40) & 0xFF))
# 段 B：块拷贝（bpb ∈ {4,8,12,16}；src 在 [0x2000,0x3000)，dst 在 [0x3000,0x4000)）
copies = [
    (0x2000, 0x3000, 128, 4),
    (0x2100, 0x3100, 256, 8),
    (0x2300, 0x3300, 512, 16),
    (0x2500, 0x3500, 96,  12),
    (0x2600, 0x3600, 1024,16),
    (0x2A00, 0x3A00, 64,  4),
]
for (s, d, nb, bpb) in copies:
    jobs.append((2, s, d, nb, bpb, 0xFF, 0))
# 段 C：回读若干（验证读路径 + 拷贝落地；覆盖部分字节写过的区与拷贝区）
reads = [
    (0x0100, 16, 2),      # 段 A 里 strb=0x0F（部分字节写）
    (0x0700, 64, 8),      # 段 A 里 strb=0x03（部分字节写）
    (0x0F00, 128, 16),    # 段 A 里 strb=0x00 的零字节写（内容应等于预载）
    (0x3000, 128, 16),    # 拷贝落地 1
    (0x3100, 256, 16),    # 拷贝落地 2
    (0x3600, 1024, 16),   # 拷贝落地（1024B 那笔整块）
    (0x2000, 128, 16),    # 源区（应等于预载）
]
for (a, nb, bpb) in reads:
    jobs.append((1, a, 0, nb, bpb, 0, 0))

# ---------------------------------------------------------------------------
# 黄金推演（**独立实现**，与 TB/AxiMemModel 同口径）
# ---------------------------------------------------------------------------
mem = bytearray(pre(i) for i in range(MEMSZ))
exp_rd = []                              # (addr, k, data64) 逐拍
awb = arb = wbeats = rbeats = 0
wr_bytes = rd_bytes = 0
maxburst = 0

def bstep(bpb):
    return bpb * 8

for (op, addr, dst, nb, bpb, strb, pat) in jobs:
    st = bstep(bpb)
    assert nb % st == 0, "bytes 不是 bpb*8 的整数倍"
    nburst = nb // st
    assert addr % 32 == 0, "addr 未 32B 对齐"
    assert 1 <= bpb <= 16, "bpb 越界"
    for b in range(nburst):
        assert (addr + b*st) % 32 == 0, "突发首址未 32B 对齐"
        assert addr + nb <= MEMSZ, "越界"
        maxburst = max(maxburst, bpb)
    if op == 0:
        for b in range(nburst):
            ba = addr + b*st
            for k in range(bpb):
                beat = ba + k*8
                for j in range(8):
                    if (strb >> j) & 1:
                        mem[beat + j] = pbyte(beat, k, j, pat)
                wr_bytes += bin(strb).count("1")
        awb += nburst
    elif op == 1:
        for b in range(nburst):
            ba = addr + b*st
            for k in range(bpb):
                beat = ba + k*8
                v = sum(mem[beat + j] << (8*j) for j in range(8))
                exp_rd.append((ba, k, v))
        rd_bytes += nb
        arb += nburst
    else:
        tmp = []
        for b in range(nburst):
            ba = addr + b*st
            for k in range(bpb):
                beat = ba + k*8
                v = sum(mem[beat + j] << (8*j) for j in range(8))
                exp_rd.append((ba, k, v))
                tmp.append(v)
        rd_bytes += nb
        arb += nburst
        assert dst % 32 == 0, "dst 未 32B 对齐"
        assert dst + nb <= MEMSZ, "dst 越界"
        for b in range(nburst):
            da = dst + b*st
            assert da % 32 == 0, "写突发首址未 32B 对齐"
            for k in range(bpb):
                beat = da + k*8
                v = tmp[b*bpb + k]
                for j in range(8):
                    mem[beat + j] = (v >> (8*j)) & 0xFF
        wr_bytes += nb
        awb += nburst
for (op, addr, dst, nb, bpb, strb, pat) in jobs:
    if op != 1:
        wbeats += nb // 8
    if op == 2:
        rbeats += nb // 8
    if op == 1:
        rbeats += nb // 8
bok = awb
bursts = arb + awb

# ---- 自检（闸门可信度的前提；不成立就响亮报红，不许"先跑再说"）----
# ① 必须真的覆盖了 awlen 0..15 与多种部分 strobe
seen_bpb = set(j[4] for j in jobs if j[0] == 0)
assert seen_bpb == set(range(1, 17)), "FATAL: awlen 未覆盖 0..15（实际 %s）" % sorted(seen_bpb)
partial = [j[5] for j in jobs if j[0] == 0 and j[5] not in (0xFF, 0x00)]
assert len(partial) >= 10, "FATAL: 部分 wstrb 写太少"
assert 0x00 in [j[5] for j in jobs if j[0] == 0], "FATAL: 缺零字节写探针"
# ② 必须真的发生了拷贝（dst 区预载 != 源内容）——否则"不拷贝也能过"
for (s, d, nb, bpb) in copies:
    diff = sum(1 for i in range(nb) if mem[d+i] != pre(d+i))
    assert diff > 0, "FATAL: COPY dst 区预载与预载相同 => 判据没意义"
# ③ 读回序列非空且数据有区分度（相邻读回值不同者够多）
assert len(exp_rd) >= 200, "FATAL: 读回探针太少"
diff_rd = sum(1 for i in range(1, len(exp_rd)) if exp_rd[i][2] != exp_rd[i-1][2])
assert diff_rd >= 50, "FATAL: 读回值区分度太低 => 陈旧/错位载荷抓不住"
# ④ 整片黄金必须与预载**不同**（拷贝真的改了内存）
pre_mem = bytearray(pre(i) for i in range(MEMSZ))
assert bytes(mem) != bytes(pre_mem), "FATAL: 末态镜像与预载逐字节相同 => 判据没意义"

open(work + "/stim.txt", "w").write(
    "".join("%x %x %x %x %x %x %x\n" % j for j in jobs))
open(work + "/mem.hex", "w").write("".join("%02x\n" % b for b in pre_mem))
open(work + "/exp.hex", "w").write("".join("%02x\n" % b for b in mem))
open(work + "/exp_rd.txt", "w").write(
    "".join("%08x %d %016x\n" % e for e in exp_rd))
open(work + "/exp_counts.txt", "w").write(
    "%d %d %d %d %d %d %d %d %d\n" % (awb, arb, bok, wbeats, rbeats, rd_bytes, wr_bytes, bursts, maxburst))
print("STIMGEN_OK jobs=%d reads=%d exp_rd=%d counts(awb=%d arb=%d bok=%d w=%d r=%d rdb=%d wrb=%d bursts=%d maxb=%d)"
      % (len(jobs), len(reads), len(exp_rd), awb, arb, bok, wbeats, rbeats, rd_bytes, wr_bytes, bursts, maxburst))
PYEOF
then
  echo "VERDICT: PRECONDITION-MISSING (激励/黄金生成失败 或 自检不过)"; exit 3
fi
[ -s "$work/stim.txt" ] && [ -s "$work/mem.hex" ] && [ -s "$work/exp.hex" ] || {
  echo "VERDICT: PRECONDITION-MISSING (激励/黄金文件缺失)"; exit 3; }
echo "   stim = $work/stim.txt（$(wc -l < "$work/stim.txt") 行 jobs）"

# ===========================================================================
# 1) 逐字节比较 + 判定器
#    用法： judge.py <work> <log> <tag> [perturb]
#      perturb=0：正常；perturb=1：把黄金第 1 个字节 XOR 0x01（比较器自检用）
# ===========================================================================
cat > "$work/cmpbytes.py" <<'PYEOF'
def load(p):
    return bytes.fromhex("".join(open(p).read().split()))

def diffs(a, b, base=0):
    """等长字节串逐字节比较 -> (count, first_abs_off)；first=-1 表示完全相同。"""
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

cat > "$work/judge.py" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
sys.path.insert(0, sys.argv[1])
from cmpbytes import load, diffs

work, log, tag = sys.argv[1], sys.argv[2], sys.argv[3]
perturb = int(sys.argv[4]) if len(sys.argv) > 4 else 0

# ---- 黄金：末态镜像 ----
exp = bytearray(load(work + "/exp.hex"))
if perturb:
    exp[0] ^= 0x01                 # 只翻**一个字节的最低位** ⇒ 恰好 1 个字节不符
exp = bytes(exp)

# ---- 黄金：逐拍读回序列 ----
G_rd = []
for ln in open(work + "/exp_rd.txt"):
    t = ln.split()
    if len(t) == 3:
        G_rd.append((int(t[0], 16), int(t[1]), int(t[2], 16)))

# ---- 黄金：计数期望 ----
cw, cr, cbk, cwbe, crbe, crdb, cwrb, cbur, cmax = [int(x) for x in open(work + "/exp_counts.txt").read().split()]

# ---- 装置事实行 ----
R_rd = []; counts = None; memline = None; res = None
for ln in open(log, errors="replace"):
    t = ln.split()
    if not t:
        continue
    if t[0] == "RD" and len(t) >= 4:
        R_rd.append((int(t[1], 16), int(t[2]), int(t[3], 16)))
    elif t[0] == "COUNTS":
        counts = dict(kv.split("=") for kv in ln.split()[1:])
    elif t[0] == "MEM" and len(t) >= 5:
        memline = ln.split()
    elif t[0] == "RESULT:" and len(t) >= 2:
        res = t[1]

try:
    got = load(work + "/" + tag + ".dump")
except Exception as e:
    got = b""

mx = mb = 0; first = -1
if got:
    mx, first = diffs(got, exp)
    # 首个不符偏移所属的字节数（MISMATCH_BYTES）：统计不符的字节个数
    mb = sum(1 for i in range(min(len(got), len(exp))) if got[i] != exp[i])
else:
    mx = len(exp); mb = len(exp)

# ---- ① 读回序列逐元素/逐字节对账（读路径无丢失/无重复/无错位）----
rx = 0; rdb = 0
if len(R_rd) != len(G_rd):
    rx += abs(len(R_rd) - len(G_rd))
    print("[%s] RDSEQ_LEN tb=%d gold=%d" % (tag, len(R_rd), len(G_rd)))
for i in range(min(len(R_rd), len(G_rd))):
    if R_rd[i] != G_rd[i]:
        rx += 1
        # 逐字节差异计数
        dv = R_rd[i][2] ^ G_rd[i][2]
        rdb += sum(1 for b in range(8) if ((dv >> (8*b)) & 0xFF))
        if rx <= 5:
            print("[%s] RDSEQ_MISMATCH idx=%d tb=(%08x,%d,%016x) gold=(%08x,%d,%016x)"
                  % (tag, i, R_rd[i][0], R_rd[i][1], R_rd[i][2], G_rd[i][0], G_rd[i][1], G_rd[i][2]))

# ---- ② 计数对账（两处独立计数）----
cx = 0
if counts is None:
    cx += 1; print("[%s] COUNTS_MISSING" % tag)
else:
    def gi(d, k): return int(d.get(k, "-1"))
    expc = dict(awb=cw, arb=cr, bok=cbk, wbeats=cwbe, rbeats=crbe)
    gotc = dict(awb=gi(counts,"awb"), arb=gi(counts,"arb"), bok=gi(counts,"bok"),
                wbeats=gi(counts,"wbeats"), rbeats=gi(counts,"rbeats"))
    if gotc != expc:
        cx += 1; print("[%s] COUNTS_MISMATCH got=%s expect=%s" % (tag, gotc, expc))
mm = 0
if memline is None:
    mm += 1; print("[%s] MEMLINE_MISSING" % tag)
else:
    # MEM rd= wr= bursts= maxburst=
    def mval(name):
        for tok in memline:
            if tok.startswith(name + "="):
                return int(tok.split("=")[1])
        return -1
    expm = dict(rd=crdb, wr=cwrb, bursts=cbur, maxburst=cmax)
    gotm = dict(rd=mval("rd"), wr=mval("wr"), bursts=mval("bursts"), maxburst=mval("maxburst"))
    if gotm != expm:
        mm += 1; print("[%s] MEM_MISMATCH got=%s expect=%s" % (tag, gotm, expm))

print("[%s] MISMATCH=%d MISMATCH_BYTES=%d FIRST_OFF=%d" % (tag, mx, mb, first))
print("[%s] RDSEQ=%d RDBYTES=%d COUNTS=%d MEMC=%d RESULT=%s" % (tag, rx, rdb, cx, mm, res or "?"))
PYEOF

# ===========================================================================
# 2) 编译（好网表；负对照另编）
# ===========================================================================
if ! "$IVERILOG" -g2012 -o "$work/sim.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "PRECOND-FAIL: iverilog 编译失败（好网表）:"; sed -n '1,40p' "$work/iv.log"
  echo "VERDICT: PRECONDITION-MISSING (compile)"; exit 3
fi
echo "---- iverilog 编译 OK（好网表）----"

# 跑一次仿真。用法: run_sim <vvp> <base> <plusargs...>
run_sim() {
  local vvp="$1"; local base="$2"; shift 2
  ( cd "$work" && "$VVP" "$vvp" "+STIMFILE=$work/stim.txt" \
      "+MEMFILE=$work/mem.hex" "+DUMPFILE=$work/$base.dump" +dump "$@" > "$base.log" 2>&1 )
}
norm_log() { sed -E -e 's#([+][A-Za-z_]+=)[^ ]+#\1PATH#g' -e 's#(MEM (LOADED|DUMPED) )[^ ]+#\1PATH#g' "$1"; }

FAIL=0          # 1 = 正/对账失败 ⇒ exit 1
NEGFAIL=0       # 1 = 负对照/自检没发火 ⇒ exit 2

# ===========================================================================
# 3) 正作业：4 档（停滞注入 × 相位 × 同钟），每档跑两次（确定性 2×）
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
  grep -q '^RESULT: PASS' "$work/$tag.log" || { echo "   TB_RED[$tag]"; grep -E '^(RESULT|TBFAIL|BAD)' "$work/$tag.log" | head -5 | sed 's/^/      /'; ok=0; }
  grep -E '^(CFG|STIM|COUNTS|MEM |RESULT:)' "$work/$tag.log" | sed 's/^/   /'
  "$PY" "$work/judge.py" "$work" "$work/$tag.log" "$tag" 0 > "$work/j_$tag.out" 2>&1 || true
  cat "$work/j_$tag.out" | sed 's/^/   /'
  local mis=$(sed -n 's/.*MISMATCH=\([0-9]*\) .*/\1/p' "$work/j_$tag.out" | head -1)
  local rdq=$(sed -n 's/.*RDSEQ=\([0-9]*\) .*/\1/p' "$work/j_$tag.out" | head -1)
  local cnq=$(sed -n 's/.*COUNTS=\([0-9]*\) .*/\1/p' "$work/j_$tag.out" | head -1)
  local mmq=$(sed -n 's/.*MEMC=\([0-9]*\) .*/\1/p' "$work/j_$tag.out" | head -1)
  if [ "${mis:-X}" != "0" ] || [ "${rdq:-X}" != "0" ] || [ "${cnq:-X}" != "0" ] || [ "${mmq:-X}" != "0" ]; then
    ok=0
  fi
  [ "$ok" = "1" ] && echo "   POS_OK[$tag]: 整片逐字节 MISMATCH=0；读回序列/两处计数全对"
  return $(( 1 - ok ))
}

echo "==== 正作业 1/4：stallmax=0、0 相位 ===="
run_pos j1 "+STALLMAX=0" || FAIL=1
echo "==== 正作业 2/4：stallmax=3、npu 相位半周期移位 ===="
run_pos j2 "+STALLMAX=3" "+PHASE_INV" || FAIL=1
echo "==== 正作业 3/4：stallmax=7、相位半周期再平移 6757ps ===="
run_pos j3 "+STALLMAX=7" "+PHASE_INV" "+PHASE_DLY_PS=6757" || FAIL=1
echo "==== 正作业 4/4：同钟对照（+SAME_CLK）、stallmax=2 ===="
run_pos j4 "+STALLMAX=2" "+SAME_CLK" || FAIL=1

# ---- 比较器自检（用刚跑出来的 j1）：黄金翻一个字节的最低位 ⇒ MISMATCH 必须恰好 1 ----
echo "---- [自检·比较器] 黄金第 1 个字节 XOR 0x01 ⇒ MISMATCH 必须恰好 1 ----"
"$PY" "$work/judge.py" "$work" "$work/j1.log" j1 1 > "$work/j_selftest.out" 2>&1 || true
cat "$work/j_selftest.out" | sed 's/^/   /'
sm="$(sed -n 's/.*MISMATCH=\([0-9]*\) .*/\1/p' "$work/j_selftest.out" | head -1)"
sb="$(sed -n 's/.*MISMATCH_BYTES=\([0-9]*\) .*/\1/p' "$work/j_selftest.out" | head -1)"
if [ "${sm:-X}" = "1" ] && [ "${sb:-X}" = "1" ]; then
  echo "   SELFTEST_OK（恰好 1 字节 ⇒ 对账是逐字节的，不是橡皮图章）"
else
  echo "   SELFTEST_RED: MISMATCH=${sm:-?} MISMATCH_BYTES=${sb:-?}（应各为 1）⇒ 闸门不可信"
  NEGFAIL=1
fi

# ===========================================================================
# 4) 负对照 A：网表突变 —— W 跨域的 **`wstrb` 载荷短接成 8'hFF**
#    锚点 = 顶层 `assign cpuMem_w_payload_strb = wPipe_io_deq_payload_strb;`（全文件恰好 1 处）。
#    期望：部分字节写被整字写掉 ⇒ 字节对账 MISMATCH>0（且内存模型 wr= 偏大）。
# ===========================================================================
echo "==== 负对照 A[网表突变: W 的 wstrb 短接 8'hFF] 必须红（数据损坏）===="
if ! "$PY" - "$nl" "$work/mut_strb.v" > "$work/mutgen_a.out" 2>&1 <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
src = open(sys.argv[1], encoding="utf-8").read()
pat = re.compile(r"assign cpuMem_w_payload_strb\s*=\s*wPipe_io_deq_payload_strb;")
new, n = pat.subn("assign cpuMem_w_payload_strb = 8'hFF;", src)
print("MUTGEN_HITS=%d" % n)
if n != 1:
    sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(new)
PYEOF
then
  echo "   MUTGEN_RED（锚点命中数不是恰好 1）"; cat "$work/mutgen_a.out" | sed 's/^/      /'; NEGFAIL=1
else
  cat "$work/mutgen_a.out" | sed 's/^/   /'
  if ! "$IVERILOG" -g2012 -o "$work/mut_strb.vvp" "$tb" "$memv" "$work/mut_strb.v" > "$work/iv_a.log" 2>&1; then
    echo "   MUT_COMPILE_RED"; sed -n '1,20p' "$work/iv_a.log" | sed 's/^/      /'; NEGFAIL=1
  else
    run_sim "$work/mut_strb.vvp" negA "+STALLMAX=0"
    grep -E '^(RESULT:|TBFAIL|MEM )' "$work/negA.log" | sed 's/^/   /'
    "$PY" "$work/judge.py" "$work" "$work/negA.log" negA 0 > "$work/j_negA.out" 2>&1 || true
    cat "$work/j_negA.out" | sed -n '1,12p' | sed 's/^/   /'
    am="$(sed -n 's/.*MISMATCH=\([0-9]*\) .*/\1/p' "$work/j_negA.out" | head -1)"
    ab="$(sed -n 's/.*MISMATCH_BYTES=\([0-9]*\) .*/\1/p' "$work/j_negA.out" | head -1)"
    ac="$(sed -n 's/.*MEMC=\([0-9]*\) .*/\1/p' "$work/j_negA.out" | head -1)"
    if [ -z "${ab:-}" ] || [ "${ab:-0}" = "0" ]; then
      echo "   NEG_RED[negA]: 短接 wstrb 后**没**抓到字节损坏（MISMATCH=${am:-?} BYTES=${ab:-?}）⇒ 闸门不可信"
      NEGFAIL=1
    else
      echo "   NEG_OK[negA]: 短接 wstrb ⇒ **字节对账** MISMATCH=${am} BYTES=$ab > 0（首个不符字节偏移"
      echo "                 $(sed -n 's/.*FIRST_OFF=\([0-9-]*\).*/\1/p' "$work/j_negA.out" | head -1)）；计数判据 MEMC=${ac}"
      echo "                 （参考：好网表同一配置 MISMATCH=0/MEMC=0）⇒ 「wstrb 必须跟着数据跨」是**承重**的。"
    fi
  fi
fi

# ===========================================================================
# 5) 负对照 B：网表突变 —— **AR 跨域掐断**（arPipe 的 enq_valid 恒 0）
#    锚点 = arPipe 实例的 `.io_enq_valid (npuMem_ar_valid)`（全文件恰好 1 处）。
#    期望：读地址一笔都到不了 cpu 侧 ⇒ 主口等 RVALID 超时 ⇒ `RESULT: FAIL timeout`（**事务丢失**）。
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
pat = re.compile(r"\.io_enq_valid\s*\(\s*npuMem_ar_valid\s*\)")
new, n = pat.subn(".io_enq_valid         (1'b0                      )", src)
print("MUTGEN_HITS=%d" % n)
if n != 1:
    sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(new)
PYEOF
then
  echo "   MUTGEN_RED（锚点命中数不是恰好 1）"; cat "$work/mutgen_b.out" | sed 's/^/      /'; NEGFAIL=1
else
  cat "$work/mutgen_b.out" | sed 's/^/   /'
  if ! "$IVERILOG" -g2012 -o "$work/mut_ar.vvp" "$tb" "$memv" "$work/mut_ar.v" > "$work/iv_b.log" 2>&1; then
    echo "   MUT_COMPILE_RED"; sed -n '1,20p' "$work/iv_b.log" | sed 's/^/      /'; NEGFAIL=1
  else
    run_sim "$work/mut_ar.vvp" negB "+STALLMAX=0"
    grep -E '^(RESULT:|TBFAIL)' "$work/negB.log" | sed 's/^/   /'
    bres="$(grep -m1 '^RESULT:' "$work/negB.log" || true)"
    bnpu="$(grep -c '^RD ' "$work/negB.log")"
    if [ "${bres#RESULT: FAIL}" = "$bres" ]; then
      echo "   NEG_RED[negB]: 掐断 AR 后装置**没有**报红（[${bres:-无 RESULT 行}]）⇒ 闸门不可信"
      NEGFAIL=1
    else
      echo "   NEG_OK[negB]: 掐断 AR ⇒ 装置红：[$bres]（RD 事实行数=$bnpu ⇒ 读数据一笔没跨回来；"
      echo "                 好网表同配置下 RD 行数 = 黄金读回条数）⇒ 「读地址必须跨域」是**承重**的。"
    fi
  fi
fi

# ===========================================================================
# 6) 负对照 C：网表突变 —— **R 通道的 deq.valid 恒 1**（不按队列空满）
#    新版 R 通道是 `NpuMemCdcFifo`（环形 FIFO + 4 条 CdcPipeSp）；把顶层
#    `assign npuMem_r_valid = rPipe_io_deq_valid;` 改成恒 1 ⇒ 空队列也给 RVALID
#    ⇒ 主口读到陈旧/重复载荷（或装置红）。
#    锚点 = 该顶层赋值（全文件恰好 1 处）；命中数不是恰好 1 就 exit 2（闸门不可信）。
# ===========================================================================
echo "==== 负对照 C[网表突变: R 的 deq.valid 恒 1] 必须红（陈旧/重复载荷）===="
if ! "$PY" - "$nl" "$work/mut_mask.v" > "$work/mutgen_c.out" 2>&1 <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
src = open(sys.argv[1], encoding="utf-8").read()
pat = re.compile(r"assign npuMem_r_valid\s*=\s*rPipe_io_deq_valid;")
new, n = pat.subn("assign npuMem_r_valid = 1'b1;", src)
print("MUTGEN_HITS=%d" % n)
if n != 1:
    sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(new)
PYEOF
then
  echo "   MUTGEN_RED（锚点命中数不是恰好 1）"; cat "$work/mutgen_c.out" | sed 's/^/      /'; NEGFAIL=1
else
  cat "$work/mutgen_c.out" | sed 's/^/   /'
  if ! "$IVERILOG" -g2012 -o "$work/mut_mask.vvp" "$tb" "$memv" "$work/mut_mask.v" > "$work/iv_c.log" 2>&1; then
    echo "   MUT_COMPILE_RED"; sed -n '1,20p' "$work/iv_c.log" | sed 's/^/      /'; NEGFAIL=1
  else
    run_sim "$work/mut_mask.vvp" negC "+STALLMAX=0"
    grep -E '^(RESULT:|TBFAIL)' "$work/negC.log" | sed 's/^/   /'
    "$PY" "$work/judge.py" "$work" "$work/negC.log" negC 0 > "$work/j_negC.out" 2>&1 || true
    cat "$work/j_negC.out" | sed -n '1,8p' | sed 's/^/   /'
    cm="$(sed -n 's/.*MISMATCH=\([0-9]*\) .*/\1/p' "$work/j_negC.out" | head -1)"
    crq="$(sed -n 's/.*RDSEQ=\([0-9]*\) .*/\1/p' "$work/j_negC.out" | head -1)"
    cr="$(grep -m1 '^RESULT:' "$work/negC.log" || true)"
    # 红的方式可以是"对账不符"或"装置红（挂死）"——两者都算发火；只要不是 (PASS 且 MISMATCH=0/RDSEQ=0)
    if [ "${cm:-}" = "0" ] && [ "${crq:-}" = "0" ] && [ "${cr#RESULT: PASS}" = "" ]; then
      echo "   NEG_RED[negC]: R 的 deq.valid 恒 1 后**照样全绿**（MISMATCH=${cm} RDSEQ=${crq}、[${cr}]）⇒ 闸门不可信"
      NEGFAIL=1
    else
      echo "   NEG_OK[negC]: R 的 deq.valid 恒 1（空队列也给 valid）⇒ 读回错位/重复/挂死：MISMATCH=${cm:-?} RDSEQ=${crq:-?} [${cr:-无 RESULT}]"
      echo "                 ⇒ 「R 的 valid 必须由队列空满决定」这一格是**承重**的。"
    fi
  fi
fi

# ===========================================================================
# 7) 判定
# ===========================================================================
echo "==================== 判定 ===================="
if [ "$NEGFAIL" != "0" ]; then
  echo "负对照/自检没有按预期发火 ⇒ **闸门自身不可信**（不是 DUT 的问题）。"
  echo "VERDICT: NEG-CONTROL-NOT-FIRED"
  echo "RESULT: FAIL (negative controls did not fire)"
  exit 2
fi
if [ "$FAIL" != "0" ]; then
  echo "正作业或对账未全绿（逐字节/读回序列/计数/确定性任一项红）⇒ 桥或装置有问题。"
  echo "VERDICT: MISMATCH"
  echo "RESULT: FAIL (positive jobs / byte-exact accounting)"
  exit 1
fi

echo "正作业 4/4 = 全绿：cpu 100MHz / npu 37MHz（非整数比 2.7027…；另含同钟对照）下，4 档配置"
echo "  （stallmax 0/3/7/2；相位 0 / 半周期 / +6757ps）逐条：RESULT: PASS、COUNTS 与内存模型计数"
echo "  双双等于黄金、TB 逐拍 RD 与黄金**逐字节**相同、末态镜像**整片逐字节** MISMATCH=0、确定性 2× 一致。"
echo "负对照 3/3 = 发火：① wstrb 短接 ⇒ 字节损坏（MISMATCH>0）；② AR 掐断 ⇒ 事务丢失（装置红）；"
echo "  ③ R 的一次性消费掩码掐掉 ⇒ 读回错位/重复。三道都压在跨域承重点上。"
echo "比较器自检 = 恰好 1 字节（不是橡皮图章）。"
echo "VERDICT: N4-OK（AXI4 内存主口异步桥：跨域无丢失/无重复/字节级正确；三道负对照 + 比较器自检都在承重点上发火）"
echo "RESULT: PASS"
exit 0
