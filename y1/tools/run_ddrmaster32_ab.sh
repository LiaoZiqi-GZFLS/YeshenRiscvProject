#!/usr/bin/env bash
# run_ddrmaster32_ab.sh —— y1 C3.3 新闸门：`DdrMaster` **32 B 粒度** + **RD/WR 流式模式** 的字节级判据。
#
# 契约（rtl/DdrMaster.scala 头部 C3.3 那两节）：
#   · `len` 粒度从 128 B 放宽到 **32 B**：`len % 32 == 0 && len != 0` 才合法；
#     每块拍数 `beats = min(16, remain/8)`、`arlen/awlen = beats-1`（**尾块缩短突发**），
#     地址每次 += `beats*8`（仍是 32 B 对齐），块缓冲仍 128 B、尾块只用前 `beats*8` 字节。
#   · `io.mode`：0=COPY（默认）1=RD（只读 ⇒ 推给 rd_stream）2=WR（只写 ⇐ wr_stream）。
#   · COPY 路径对"128 的整数倍"必须**逐拍/逐字节不变**（作业 5 专测）。
#
# 作业（5 个，含 5 个负对照 + 1 个比较器自检）：
#   作业 1 粒度正对照 —— COPY（mode=0）跑 LEN ∈ {32,64,96,160,256}（全是 32 的整数倍，**含多块+尾块**
#     的 160 = 128+32）。判据（全部**独立**算，不盲信装置 PASS）：
#       · 装置 `RESULT: PASS`（它自己查模式不越界 / orphan W / wlast 与 AW 声明长度一致 / 拍数 = LEN/8）；
#       · 内存镜像：dst 区 == **原地 src 区**（逐字节）、src 区未被改、dst 区之外（含紧邻前后 32 B）未动；
#       · `ARB/AWB` 序列 == Python 按 `beats = min(16, remain/8)` **独立重算**的黄金序列
#         （地址逐笔递进 + arlen/awlen 逐笔 = beats-1）—— 这就是"尾块缩短突发"的运行期判据；
#       · 与内存模型交叉对账：`MEM rd=wr=LEN bursts=2*块数 maxburst=最大块拍数`；
#       · 装置自报 `RD_BYTES=WR_BYTES=LEN`、`ERR=0`、`ST_RDW...` 结构性计数全 0。
#   作业 2 粒度负对照（err 路径）—— 五种非法入参各跑一次，必须 err 且**一个字节都不搬**：
#       · `len=40`（不是 32 的倍数）mode=0；· 同 len=40 走 mode=1（校验在 CHK 里，与模式无关）；
#       · `len=48`（**也不是** 32 的倍数：48 = 1.5×32。plan 原文写"48 是 32 的倍数、必须过"是算术笔误，
#         见收口处的口径说明）；· `len=0`；· `dst` 非 32B 对齐。
#   作业 3 RD 模式 —— mode=1 跑 LEN ∈ {32,96,160}。判据：内存 `wr=0`、`rd=LEN`、`bursts=块数`；
#      `rd_stream` 实际推出的 LEN 字节与预载源区**逐字节**一致；内存镜像 == 预载（**一个字节都没写**）；
#      `aw_bursts=B_OK=0`（RD 到不了写相位）；`wr_bytes=0`。含单字节负对照（见下）。
#   作业 4 WR 模式 —— mode=2 跑 LEN ∈ {32,96,160}。判据：内存 `rd=0`、`wr=LEN`、`bursts=块数`；
#      目标区逐字节 == **喂进流的字节**；其余（含源区）== 预载；`ar_bursts=RD_BEATS=0`；`rd_bytes=0`。
#   作业 5 COPY 逐拍不变（C3 的硬条款）—— 用**同一个旧装置** DdrCopyTb.v（它**没有连 `mode`**，
#      于是在新网表上悬空 = z ⇒ X ⇒ 结构性等价于 COPY：这本身就是"旧调用方不改"的运行期验证）
#      跑一个 128 整数倍的拷贝 LEN=4096，判据：
#       · `CYC == 1 + 块数*37`（37 = AR 1 + R 16 + NEXT 1 + WR 1 + W 16 + WB 1 + WNEXT 1）；
#         ★ 这个模型**独立复现**了 C2 台账里 1 MiB 的实测值：`1 + 8192*37 == 303105`（纯算术断言，
#           与 reports/c3_baseline 之前的 C2 报告 c2_ddr_master.md 记的 `cyc_per_group_added=1.250031`
#           完全同源）。模型对不上 ⇒ 说明 COPY 路径的拍数被改动过。
#       · 整片内存镜像 == 黄金镜像（逐字节）；AR/AW 序列 == 黄金（全 15、逐笔 +128）。
#
# 负对照（必须**发火**，这就是"判据不是橡皮图章"的证据）：
#   N1 单字节[RD]      —— 预载源区改 1 字节（SRC+61）⇒ RD 推出的字节必须**恰好 1 个**不符、偏移 = 61。
#                         （块粒度会报 1 块 / 8 字节行粒度会报到 8 对齐的偏移上）
#   N2 单字节[WR]      —— 喂进去的流改 1 字节（下标 13）⇒ 目标区必须**恰好 1 个**字节不符、偏移 = DST+13。
#   N3 网表突变[WR]    —— `wstrb` 常量 `8'hff` -> `8'hfe`（每拍丢掉第 0 字节）：装置照旧 PASS
#                         （握手/拍数/自报字节数一个不变），但字节判据必须报**恰好 4 个**（4 拍各 1 个）
#                         不符、首个偏移 == DST；内存模型的 `wr` 也会少 4（32 B -> 28 B，独立佐证**已断言**）。
#   N4 err 路径 ×5     —— 见作业 2（装置必须报 err 且镜像与预载逐字节相同）。
#   N5 模式越界        —— 由装置在**正常作业**里持续断言（`MODE_LEAK_BAD=0`/`STREAM_IDLE_BAD=0`），
#                         作业 3/4 的正向跑本身就是它的载体（RD 若发 AW、WR 若发 AR 都会红）。
#   比较器自检 —— 扰动黄金镜像 `DST+17` 一个期望字节 ⇒ MISMATCH 必须**恰好 1**
#                 （不做这步就分不清"真的逐字节相符"与"比较器把两边都读成空表也报 0"）。
#
# 退出码：
#   0 = 全过（作业 1-5 全绿 + 5 个负对照全发火 + 比较器自检过）
#   1 = 对账不符 / 编译或仿真失败 / 装置未 PASS / 分块与黄金序列不符
#   2 = 负对照没发火，或比较器自检不过 ⇒ **闸门自身不可信**（橡皮图章）
#
# 装置契约：
#   rtl_test/DdrStreamTb.v：+MODE= +SRC= +DST= +LEN= +MEMFILE= +DUMPFILE= +STREAMIN= +STREAMOUT= +EXPECT_ERR
#     输出 `ARB <addr> arlen=<n>` / `AWB <addr> awlen=<n>` / 计数行 / `CYC=.. RD_BYTES=.. WR_BYTES=.. ERR=..`
#     末行 `RESULT: PASS|FAIL`（FAIL ⇒ $fatal ⇒ vvp 非零）。
#   rtl_test/DdrCopyTb.v：旧装置原样复用（不连 mode）。
#   rtl_test/AxiMemModel.v：末尾 `MEM rd=<bytes> wr=<bytes> bursts=<n> maxburst=<n>`；不合规突发 $fatal。
set -uo pipefail

PY="${PY:-python}"
here="$(cd "$(dirname "$0")" && pwd)"
gen="$here/../gen"
tbs="$here/../rtl_test/DdrStreamTb.v"
tbc="$here/../rtl_test/DdrCopyTb.v"
memv="$here/../rtl_test/AxiMemModel.v"
nl="$gen/DdrMaster.v"

# ---- 用例常量（必须与 rtl_test/DdrStreamTb.v 里 AxiMemModel 的 MEMSZ 一致）----
MEMSZ=8192                 # 小内存装置
SRC=1024                   # 0x400，32B 对齐
DST=4096                   # 0x1000，32B 对齐；与 src 区不重叠
PERIOD=251                 # 与 C2 闸门同一个非混叠模式（周期恰 251、与 128 互素）
OFF_RD=61                  # N1 破坏的源字节下标（61 % 8 = 5：非 8 字节行对齐、非块对齐）
OFF_WR=13                  # N2 破坏的喂入字节下标
# ---- 作业 5 的用例（DdrCopyTb 自带 MEMSZ=2621440）----
MEMSZ_C=2621440
SRC_C=131072               # 0x20000
DST_C=1441792              # 0x160000
LEN_C=4096                 # 32 个满块（128 的整数倍 ⇒ COPY 逐拍不变该在这里成立）
CYC_PER_CHUNK=37           # AR1 + R16 + NEXT1 + WR1 + W16 + WB1 + WNEXT1
C2_MD5=e1871260a5509c95bea0f0fd8be3bf61   # reports/c3_baseline.txt 记的 C3 前基线

work="$(mktemp -d)"
cleanup() {
  if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => 激励与日志留在 $work"
  else rm -rf "$work"; fi
}
trap cleanup EXIT

# iverilog/vvp 本机在 /c/msys64/ucrt64/bin（可能不在 PATH 上）⇒ 先 PATH 后固定目录。
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

echo "== run_ddrmaster32_ab: DdrMaster 32 B 粒度 + RD/WR 流式模式（COPY 逐拍不变） =="
echo "   tb  =$tbs"
echo "   ref =$tbc（旧装置原样复用，不连 mode）"
echo "   nl  =$nl"
echo "   iverilog=${IVERILOG:-<找不到>}  vvp=${VVP:-<找不到>}"
echo "   tmp =$work"
echo "   用例 SRC=$SRC DST=$DST (MEMSZ=$MEMSZ) / 作业5 SRC=$SRC_C DST=$DST_C LEN=$LEN_C (MEMSZ=$MEMSZ_C)"

if [ ! -f "$nl" ];   then echo "FATAL: 找不到网表 $nl";   exit 1; fi
if [ ! -f "$tbs" ];  then echo "FATAL: 找不到装置 $tbs";  exit 1; fi
if [ ! -f "$tbc" ];  then echo "FATAL: 找不到装置 $tbc";  exit 1; fi
if [ ! -f "$memv" ]; then echo "FATAL: 找不到内存模型 $memv"; exit 1; fi
if [ -z "$IVERILOG" ] || [ -z "$VVP" ]; then echo "FATAL: 找不到 iverilog / vvp"; exit 1; fi

# ===========================================================================
# 0) 公共库 + 造激励
#    · mem8k.hex     ：小内存预载（周期 251 的非混叠模式）
#    · mem2p5.hex    ：作业 5 的 2.5 MiB 预载（同一模式）
#    · fed<N>.hex    ：WR 模式喂进去的流（与预载**处处不同** ⇒ "没写"不可能蒙过对比）
#    · exp_ar/aw     ：黄金 AR/AW 序列（Python 独立重算分块）
#    · g32.py        ：判据公共库（load/diffs/chunks/parse_log/...）
# ===========================================================================
cat > "$work/g32.py" <<'PYEOF'
import sys

def load(p):
    return bytes.fromhex("".join(open(p).read().split()))

def diffs(a, b, base=0):
    """等长字节串逐字节差异 -> (count, first_abs_off)；first = -1 表示完全相同。"""
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

def chunks(ln):
    """C3.3 分块的**独立实现**：每块 beats = min(16, remain/8) 拍。
    返回 [(off, beats)]；off 是相对基址的字节偏移（32 B 对齐由 8 的倍数保证）。"""
    assert ln > 0 and ln % 32 == 0, "chunks() 只接受 32 的正整数倍"
    out, off, rem = [], 0, ln
    while rem:
        beats = min(16, rem // 8)
        out.append((off, beats))
        off += beats * 8
        rem -= beats * 8
    return out

KEYS = ("CYC", "RD_BYTES", "WR_BYTES", "ERR", "DONE_SEEN", "AR_BURSTS", "AW_BURSTS",
        "B_OK", "RD_BEATS", "WR_BEATS", "ORPHAN_W", "WLAST_BAD", "WBURST_BAD",
        "RBEAT_BAD", "RDWR_OVERLAP", "ARAW_OVERLAP", "AW_LEAD_MAX", "MODE_LEAK_BAD",
        "STREAM_IDLE_BAD", "STREAM_RD_BEATS", "STREAM_WR_BEATS")

def parse_log(path):
    """-> (ar[(addr,arlen)], aw[(addr,awlen)], memline|None, tb{})"""
    ar, aw, memline, tb = [], [], None, {}
    for line in open(path, errors="replace"):
        t = line.split()
        if not t:
            continue
        if t[0] == "ARB":
            ar.append((int(t[1], 16), int(t[2].split("=")[1]))); continue
        if t[0] == "AWB":
            aw.append((int(t[1], 16), int(t[2].split("=")[1]))); continue
        if t[0] == "MEM":
            memline = line.strip(); continue
        for p in t:
            if "=" in p:
                k, v = p.split("=", 1)
                if k in KEYS:
                    try:
                        tb[k] = int(v)
                    except ValueError:
                        pass
    return ar, aw, memline, tb

def seqcheck(label, got, exp):
    """逐笔比 (addr, len-field)。不等就点名第一笔不符的位置。"""
    if got != exp:
        first = next((("0x%08x/len=%d  vs  0x%08x/len=%d" % (a[0], a[1], b[0], b[1]))
                      for a, b in zip(got, exp) if a != b), "-")
        print("%sSEQ_BAD got=%d 笔 expect=%d 笔 firstbad=%s" % (label, len(got), len(exp), first))
        return 1
    print("%sSEQ_OK %d 笔（地址逐块递进；len 域逐笔 = beats-1）" % (label, len(got)))
    return 0

def memcheck(memline, exp_rd, exp_wr, exp_bursts, exp_max):
    if memline is None:
        print("MEMLINE_MISSING"); return 1
    kv = dict(p.split("=") for p in memline.split()[1:])
    rd, wr, bur, mx = int(kv["rd"]), int(kv["wr"]), int(kv["bursts"]), int(kv["maxburst"])
    print("MEMCHECK rd=%d wr=%d bursts=%d maxburst=%d (expect rd=%d wr=%d bursts=%d maxburst=%d)"
          % (rd, wr, bur, mx, exp_rd, exp_wr, exp_bursts, exp_max))
    bad = 0
    for nm, got, exp in (("MEMRD", rd, exp_rd), ("MEMWR", wr, exp_wr),
                         ("MEMBURSTS", bur, exp_bursts), ("MEMMAXBURST", mx, exp_max)):
        if got != exp:
            print("%s_BAD %d != %d" % (nm, got, exp)); bad += 1
    return bad

def tbcheck(tb, expect):
    bad = 0
    for k, v in expect.items():
        if tb.get(k) != v:
            print("TBBAD %s=%s != %s" % (k, tb.get(k), v)); bad += 1
    return bad
PYEOF

if ! "$PY" - "$work" "$MEMSZ" "$SRC" "$DST" "$PERIOD" "$MEMSZ_C" "$SRC_C" "$DST_C" "$LEN_C" \
        "$OFF_RD" "$OFF_WR" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from g32 import chunks
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

work = sys.argv[1]
memsz, src, dst, period = (int(x) for x in sys.argv[2:6])
memsz_c, src_c, dst_c, len_c = (int(x) for x in sys.argv[6:10])
off_rd, off_wr = int(sys.argv[10]), int(sys.argv[11])

def pat(i):
    return ((i % period) * 131 + 7) % period

# ---- 非混叠断言（闸门可信度的前提）----
assert len(set(pat(i) for i in range(period))) == period, "模式周期不是恰好 %d" % period
for k in range(1, 17):
    assert all(pat(j) != pat(j + 128 * k) for j in range(0, 4 * period)), "整块平移 k=%d 混叠" % k
assert (dst - src) % period != 0, "src/dst 相位对混叠"

# ---- 结构自检 ----
assert src % 32 == 0 and dst % 32 == 0, "地址必须 32B 对齐"
assert src + 256 <= dst and dst + 256 <= memsz, "前 256 B 用例必须落在内存里且与 src 不重叠"
assert memsz - (dst + 256) >= 128, "后面要留出邻居字节"
assert min(src, dst) >= 128, "前面要留出邻居字节"

# ---- 小内存预载 ----
pre = bytes(pat(i) for i in range(memsz))
open(work + "/mem8k.hex", "w").write("\n".join("%02x" % b for b in pre) + "\n")

# ---- WR 模式喂进去的流：**与预载处处不同**（否则"没写"也能过 dst==fed 这一条）----
def fed(i):
    return (i * 7 + 11) % period
for ln in (32, 96, 160):
    fb = bytes(fed(i) for i in range(ln))
    open(work + "/fed%d.hex" % ln, "w").write("\n".join("%02x" % b for b in fb) + "\n")
    diff = sum(1 for j in range(ln) if fb[j] == pre[dst + j])
    assert diff == 0, "WR LEN=%d：喂入流与目标区预载有 %d 个字节相同 ⇒ 判据不够硬" % (ln, diff)

# ---- 源区自检：非平凡（不能全 0、不能常数），否则"没读"也能过 RD 对比 ----
for ln in (32, 96, 160):
    win = pre[src:src + ln]
    assert len(set(win)) > 1, "源窗口 LEN=%d 是常数 ⇒ RD 判据没意义" % ln
    assert any(b != 0 for b in win), "源窗口 LEN=%d 全 0 ⇒ 读到空表也能过" % ln

# ---- 黄金 AR/AW 序列（作业 1/3/4 用）----
for ln in (32, 64, 96, 160, 256):
    ch = chunks(ln)
    assert sum(b * 8 for _, b in ch) == ln, "分块字节数不自洽 LEN=%d" % ln
    assert all(o % 32 == 0 for o, _ in ch), "分块偏移不是 32B 对齐 LEN=%d" % ln
    assert all(1 <= b <= 16 for _, b in ch), "分块拍数越界 LEN=%d" % ln
    with open(work + "/exp_ar_%d.txt" % ln, "w") as f:
        for o, b in ch:
            f.write("%08x %d\n" % (src + o, b - 1))
    with open(work + "/exp_aw_%d.txt" % ln, "w") as f:
        for o, b in ch:
            f.write("%08x %d\n" % (dst + o, b - 1))
    print("CHUNKS LEN=%-4d -> %s" % (ln, " ".join("%d(+%d)" % (b, o) for o, b in ch)))

# ---- 作业 1 里 LEN=32 那一跑的**黄金镜像**（dst 区换成 src 区内容）----
#      比较器自检要扰动的是**这份**黄金镜像（扰动预载没有意义：dst 区的预载本来就会被覆盖掉）。
gold32 = pre[:dst] + pre[src:src + 32] + pre[dst + 32:]
open(work + "/exp_c32.hex", "w").write("\n".join("%02x" % b for b in gold32) + "\n")

# ---- 作业 5 的 2.5 MiB 预载 + 黄金镜像 + 黄金序列（全满块）----
assert src_c % 32 == 0 and dst_c % 32 == 0 and len_c % 128 == 0 and len_c > 0
assert src_c + len_c <= dst_c and dst_c + len_c <= memsz_c
pre_c = bytes(pat(i) for i in range(memsz_c))
open(work + "/mem2p5.hex", "w").write("\n".join("%02x" % b for b in pre_c) + "\n")
gold_c = pre_c[:dst_c] + pre_c[src_c:src_c + len_c] + pre_c[dst_c + len_c:]
open(work + "/exp_c.hex", "w").write("\n".join("%02x" % b for b in gold_c) + "\n")
nc = len_c // 128
with open(work + "/exp_ar_c.txt", "w") as f:
    for k in range(nc):
        f.write("%08x 15\n" % (src_c + 128 * k))
with open(work + "/exp_aw_c.txt", "w") as f:
    for k in range(nc):
        f.write("%08x 15\n" % (dst_c + 128 * k))
print("MEMGEN ok  mem8k=%d  mem2p5=%d  作业5 块数=%d  期望 CYC=%d (=1+%d*%d)"
      % (memsz, memsz_c, nc, 1 + nc * 37, nc, 37))
PYEOF
then
  echo "FATAL: 生成激励失败（或非混叠断言不成立）⇒ 闸门不可信"
  exit 2
fi

# ===========================================================================
# 1) 编译两份网表
# ===========================================================================
if ! "$IVERILOG" -g2012 -o "$work/stream.vvp" "$tbs" "$memv" "$nl" > "$work/iv_stream.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败（DdrStreamTb + 新网表）"
  sed -n '1,40p' "$work/iv_stream.log"; exit 1
fi
if ! "$IVERILOG" -g2012 -o "$work/copy.vvp" "$tbc" "$memv" "$nl" > "$work/iv_copy.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败（DdrCopyTb + 新网表，旧装置不连 mode）"
  sed -n '1,40p' "$work/iv_copy.log"; exit 1
fi
echo "---- iverilog 编译 OK（DdrStreamTb / DdrCopyTb × 新网表）----"

# 跑一次仿真：sim_stream <logbase> <mode> <src> <dst> <len> [extra plusargs...]
sim_stream() {
  local log="$1" md="$2" s="$3" d="$4" l="$5"; shift 5
  ( cd "$work" && "$VVP" stream.vvp \
      "+MODE=$md" "+SRC=$s" "+DST=$d" "+LEN=$l" \
      "+MEMFILE=$work/mem8k.hex" "+DUMPFILE=$work/$log.dump" +dump "$@" > "$log" 2>&1 )
  return $?
}
sim_copy() {
  local log="$1" s="$2" d="$3" l="$4"
  ( cd "$work" && "$VVP" copy.vvp \
      "+SRC=$s" "+DST=$d" "+LEN=$l" \
      "+MEMFILE=$work/mem2p5.hex" "+DUMPFILE=$work/$log.dump" +dump > "$log" 2>&1 )
  return $?
}

# ===========================================================================
# 作业 1：32 B 粒度 COPY 正对照（LEN ∈ {32,64,96,160,256}，含多块+尾块）
# ===========================================================================
echo "---- 作业 1：COPY（mode=0）粒度正对照 LEN=32/64/96/160/256 ----"
cat > "$work/judge_copy.py" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from g32 import load, diffs, chunks, parse_log, seqcheck, memcheck, tbcheck
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# argv: [1]=work(给 sys.path) [2]=log [3]=dump [4]=mem [5]=src [6]=dst [7]=len
log, dump, mem = sys.argv[2], sys.argv[3], sys.argv[4]
src, dst, ln = int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7])
pre, got = load(mem), load(dump)
ch = chunks(ln)
bad = 0

# 1a) 三个区域各自点名（钉的是"拷贝真的发生、源没被改、越界没发生"）
d_bad, d_first = diffs(got[dst:dst + ln], got[src:src + ln], dst)      # dst 区 == **原地** src 区
s_bad, s_first = diffs(got[src:src + ln], pre[src:src + ln], src)      # src 区 == 预载
n_bad, n_first = diffs(got[:dst], pre[:dst], 0)
t_bad, t_first = diffs(got[dst + ln:], pre[dst + ln:], dst + ln)
neig = sum(1 for j in range(32) if got[dst - 32 + j] != pre[dst - 32 + j]) + \
       sum(1 for j in range(32) if got[dst + ln + j] != pre[dst + ln + j])
print("COPY LEN=%d DST_EQ_SRC_BAD=%d SRC_UNCHANGED_BAD=%d NEIGHBOR_BAD=%d NEIGHBOR32_BAD=%d"
      % (ln, d_bad, s_bad, n_bad + t_bad, neig))
if d_bad or s_bad or n_bad + t_bad or neig:
    bad += 1

# 1b) 分块：AR/AW 序列 == Python 独立重算的黄金（尾块缩短突发的运行期判据）
ar, aw, memline, tb = parse_log(log)
exp_ar = [(src + o, b - 1) for o, b in ch]
exp_aw = [(dst + o, b - 1) for o, b in ch]
bad += seqcheck("COPY AR", ar, exp_ar)
bad += seqcheck("COPY AW", aw, exp_aw)

# 1c) 与内存模型交叉对账 + 装置自报
bad += memcheck(memline, ln, ln, 2 * len(ch), max(b for _, b in ch))
bad += tbcheck(tb, {"ERR": 0, "RD_BYTES": ln, "WR_BYTES": ln, "DONE_SEEN": 1,
                    "AR_BURSTS": len(ch), "AW_BURSTS": len(ch), "B_OK": len(ch),
                    "RD_BEATS": ln // 8, "WR_BEATS": ln // 8,
                    "ORPHAN_W": 0, "WLAST_BAD": 0, "WBURST_BAD": 0, "RBEAT_BAD": 0,
                    "RDWR_OVERLAP": 0, "ARAW_OVERLAP": 0, "AW_LEAD_MAX": 0,
                    "MODE_LEAK_BAD": 0, "STREAM_IDLE_BAD": 0,
                    "STREAM_RD_BEATS": 0, "STREAM_WR_BEATS": 0})
print("COPY LEN=%d CYC=%s 块数=%d" % (ln, tb.get("CYC"), len(ch)))
print("COPY LEN=%d JUDGE_EXTRA=%d" % (ln, bad))
sys.exit(1 if bad else 0)
PYEOF

COPY_LENS="32 64 96 160 256"
for L in $COPY_LENS; do
  sim_stream "c$L.log" 0 "$SRC" "$DST" "$L"; RC=$?
  if [ "$RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/c$L.log"; then
    echo "JUDGE-RED: COPY LEN=$L 装置未 PASS（vvp rc=$RC）"
    grep -E '^(RESULT|TBFAIL|CYC=)' "$work/c$L.log" || true
    exit 1
  fi
  if ! "$PY" "$work/judge_copy.py" "$work" "$work/c$L.log" "$work/c$L.log.dump" \
        "$work/mem8k.hex" "$SRC" "$DST" "$L" > "$work/jc$L.out" 2>&1; then
    echo "JUDGE-RED: COPY LEN=$L 判据不符"; cat "$work/jc$L.out"; exit 1
  fi
  grep -E '^(COPY|MEMCHECK|COPY AR|COPY AW)' "$work/jc$L.out" || true
done
echo "作业 1 PASS：LEN ∈ {$COPY_LENS} 全部逐字节往返正确，且分块/AR-AW 序列与独立重算一致"

# ------------- 比较器自检：扰动黄金镜像 DST+17 一个字节 ⇒ MISMATCH 必须恰好 1 -------------
"$PY" - "$work" "$DST" <<'PYEOF'
import sys
work, dst = sys.argv[1], int(sys.argv[2])
lines = [l.strip() for l in open(work + "/exp_c32.hex") if l.strip()]
idx = dst + 17
lines[idx] = "%02x" % ((int(lines[idx], 16) ^ 0x01) & 0xFF)
open(work + "/exp_c32_neg.hex", "w").write("\n".join(lines) + "\n")
print("CMP_SELFTEST_PERTURB idx=%d（黄金镜像里 DST+17 那一个字节）" % idx)
PYEOF
if ! "$PY" - "$work" "$work/exp_c32_neg.hex" "$work/c32.log.dump" > "$work/selftest.out" 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from g32 import load, diffs
exp, got = load(sys.argv[2]), load(sys.argv[3])
mis, first = diffs(got, exp)
print("MISMATCH=%d FIRST_OFF=%d" % (mis, first))
sys.exit(0 if mis == 1 else 1)
PYEOF
then
  echo "RESULT: FAIL（比较器自检不过）⇒ 闸门不可信"; cat "$work/selftest.out"; exit 2
fi
SM="$(sed -n 's/^MISMATCH=\([0-9]*\).*$/\1/p' "$work/selftest.out" | tail -1)"
echo "CMP_SELFTEST MISMATCH=$SM（期望恰好 1）"
[ "$SM" = "1" ] || { echo "RESULT: FAIL（比较器自检 MISMATCH=$SM != 1）⇒ 闸门不可信"; exit 2; }

# ===========================================================================
# 作业 2：粒度负对照 —— 五种非法入参必须 err 且**一个字节都不搬**
# ===========================================================================
echo "---- 作业 2：非法入参 err 负对照（len=40 ×2 模式 / len=48 / len=0 / dst 非对齐）----"
cat > "$work/judge_err.py" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from g32 import load, diffs, parse_log
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
# argv: [1]=work(给 sys.path) [2]=log [3]=dump [4]=mem
log, dump, mem = sys.argv[2], sys.argv[3], sys.argv[4]
pre, got = load(mem), load(dump)
bad = 0
mis, first = diffs(got, pre)
print("ERRCASE image_vs_preload MISMATCH=%d FIRST_OFF=%d" % (mis, first))
if mis != 0:
    bad += 1
ar, aw, memline, tb = parse_log(log)
if ar or aw:
    print("ERRCASE ARB/AWB_BAD %d/%d" % (len(ar), len(aw))); bad += 1
if memline is None or not memline.startswith("MEM rd=0 wr=0 bursts=0"):
    print("ERRCASE MEM_BAD %s" % memline); bad += 1
for k, v in (("ERR", 1), ("DONE_SEEN", 0), ("AR_BURSTS", 0), ("AW_BURSTS", 0), ("B_OK", 0),
             ("RD_BYTES", 0), ("WR_BYTES", 0), ("RD_BEATS", 0), ("WR_BEATS", 0),
             ("STREAM_RD_BEATS", 0), ("STREAM_WR_BEATS", 0)):
    if tb.get(k) != v:
        print("ERRCASE TBBAD %s=%s != %d" % (k, tb.get(k), v)); bad += 1
print("ERRCASE tb=CYC=%s ERR=%s DONE=%s AR=%s AW=%s 镜像差=%d"
      % (tb.get("CYC"), tb.get("ERR"), tb.get("DONE_SEEN"), tb.get("AR_BURSTS"),
         tb.get("AW_BURSTS"), mis))
print("ERRCASE JUDGE_EXTRA=%d" % bad)
sys.exit(1 if bad else 0)
PYEOF

neg_err() { # <tag> <mode> <src> <dst> <len> <说明>
  local tag="$1" md="$2" s="$3" d="$4" l="$5" why="$6" ok=1
  echo "---- 作业 2[$tag] $why (MODE=$md SRC=$s DST=$d LEN=$l) ----"
  sim_stream "e_$tag.log" "$md" "$s" "$d" "$l" +EXPECT_ERR; local rc=$?
  if [ "$rc" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/e_$tag.log"; then
    echo "NEG_RED[$tag]: 装置没按预期报 err（rc=$rc）"
    grep -E '^(RESULT|TBFAIL|CYC=)' "$work/e_$tag.log" || true
    ok=0
  fi
  if ! "$PY" "$work/judge_err.py" "$work" "$work/e_$tag.log" "$work/e_$tag.log.dump" \
        "$work/mem8k.hex" > "$work/je_$tag.out" 2>&1; then ok=0; fi
  cat "$work/je_$tag.out"
  [ "$ok" = "1" ] && echo "NEG_OK[$tag]: 装置报 err 且零搬运（bursts=0、镜像逐字节 == 预载）"
  [ "$ok" = "1" ]
}
neg_err len40    0 "$SRC" "$DST"            40 "LEN=40 不是 32 的倍数（COPY）"          || { echo "RESULT: FAIL（负对照未发火）⇒ 闸门不可信"; exit 2; }
neg_err len40rd  1 "$SRC" "$DST"            40 "LEN=40 不是 32 的倍数（RD；校验在 CHK，与模式无关）" || { echo "RESULT: FAIL（负对照未发火）⇒ 闸门不可信"; exit 2; }
neg_err len48    0 "$SRC" "$DST"            48 "LEN=48 = 1.5×32，**同样不是** 32 的倍数（见收口口径）" || { echo "RESULT: FAIL（负对照未发火）⇒ 闸门不可信"; exit 2; }
neg_err lenzero  0 "$SRC" "$DST"             0 "LEN=0"                                   || { echo "RESULT: FAIL（负对照未发火）⇒ 闸门不可信"; exit 2; }
neg_err dstaln   0 "$SRC" "$(( DST + 8 ))"  32 "DST 非 32B 对齐"                         || { echo "RESULT: FAIL（负对照未发火）⇒ 闸门不可信"; exit 2; }
echo "作业 2 PASS：5/5 非法入参都 err 且零搬运"

# ===========================================================================
# 作业 3：RD 模式（mode=1）
# ===========================================================================
echo "---- 作业 3：RD 流式模式（mode=1）LEN=32/96/160 ----"
cat > "$work/judge_rd.py" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from g32 import load, diffs, chunks, parse_log, seqcheck, memcheck, tbcheck
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
log, dump, mem, sout = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
src, dst, ln = int(sys.argv[6]), int(sys.argv[7]), int(sys.argv[8])
pre, got, rd = load(mem), load(dump), load(sout)
ch = chunks(ln)
bad = 0
# ① rd_stream 推出的 ln 字节 == 源区内容（逐字节）
mis, first = diffs(rd, pre[src:src + ln], 0)
print("RD LEN=%d STREAM_vs_SRC MISMATCH=%d FIRST_OFF=%d (len(stream)=%d)" % (ln, mis, first, len(rd)))
if mis or len(rd) != ln:
    bad += 1
# ② RD 一个字节都没写内存
w_bad, w_first = diffs(got, pre)
print("RD LEN=%d MEM_UNTOUCHED_BAD=%d FIRST_OFF=%d" % (ln, w_bad, w_first))
if w_bad:
    bad += 1
# ③ AR 序列（尾块缩短）== 黄金；AW 一笔都没有
ar, aw, memline, tb = parse_log(log)
bad += seqcheck("RD AR", ar, [(src + o, b - 1) for o, b in ch])
if aw:
    print("RD AWB_BAD %d 笔（RD 不该发 AW）" % len(aw)); bad += 1
else:
    print("RD AW_SEQ_OK 0 笔（RD 模式结构上到不了写相位）")
# ④ 交叉对账：wr=0、bursts=块数
bad += memcheck(memline, ln, 0, len(ch), max(b for _, b in ch))
bad += tbcheck(tb, {"ERR": 0, "RD_BYTES": ln, "WR_BYTES": 0, "DONE_SEEN": 1,
                    "AR_BURSTS": len(ch), "AW_BURSTS": 0, "B_OK": 0,
                    "RD_BEATS": ln // 8, "WR_BEATS": 0, "STREAM_RD_BEATS": ln // 8,
                    "STREAM_WR_BEATS": 0, "ORPHAN_W": 0, "WLAST_BAD": 0, "WBURST_BAD": 0,
                    "RBEAT_BAD": 0, "RDWR_OVERLAP": 0, "ARAW_OVERLAP": 0,
                    "MODE_LEAK_BAD": 0, "STREAM_IDLE_BAD": 0})
print("RD LEN=%d CYC=%s 块数=%d JUDGE_EXTRA=%d" % (ln, tb.get("CYC"), len(ch), bad))
sys.exit(1 if bad else 0)
PYEOF

for L in 32 96 160; do
  sim_stream "rd$L.log" 1 "$SRC" "$DST" "$L" "+STREAMOUT=$work/rd$L.out"; RC=$?
  if [ "$RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/rd$L.log"; then
    echo "JUDGE-RED: RD LEN=$L 装置未 PASS（vvp rc=$RC）"
    grep -E '^(RESULT|TBFAIL|CYC=)' "$work/rd$L.log" || true
    exit 1
  fi
  if ! "$PY" "$work/judge_rd.py" "$work" "$work/rd$L.log" "$work/rd$L.log.dump" \
        "$work/mem8k.hex" "$work/rd$L.out" "$SRC" "$DST" "$L" > "$work/jr$L.out" 2>&1; then
    echo "JUDGE-RED: RD LEN=$L 判据不符"; cat "$work/jr$L.out"; exit 1
  fi
  grep -E '^(RD|MEMCHECK|RD AR|RD AW)' "$work/jr$L.out" || true
done
echo "作业 3 PASS：LEN=32/96/160 的 rd_stream 逐字节 == 源，且内存 wr=0、AW 一笔未发"

# ------------- 负对照 N1：RD 源区单字节受损 ⇒ 流出**恰好 1** 个字节不符、偏移 = OFF_RD -------------
echo "---- 负对照 N1[RD 单字节] 预载 SRC+$OFF_RD 改一个字节 ----"
"$PY" - "$work/mem8k.hex" "$work/mem8k_negrd.hex" "$SRC" "$OFF_RD" <<'PYEOF'
import sys
mem, out, src, off = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
lines = [l.strip() for l in open(mem) if l.strip()]
idx = src + off
lines[idx] = "%02x" % (int(lines[idx], 16) ^ 0xFF)
open(out, "w").write("\n".join(lines) + "\n")
print("N1_PERTURB addr=%d" % idx)
PYEOF
# 用**受损的那份预载**重跑（+MEMFILE= 要换成 mem8k_negrd.hex ⇒ 手工组命令）
( cd "$work" && "$VVP" stream.vvp +MODE=1 "+SRC=$SRC" "+DST=$DST" "+LEN=96" \
    "+MEMFILE=$work/mem8k_negrd.hex" "+DUMPFILE=$work/n1.log.dump" "+STREAMOUT=$work/n1.out" +dump \
    > "$work/n1.log" 2>&1 )
N1RC=$?
if [ "$N1RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/n1.log"; then
  echo "RESULT: FAIL（N1 的仿真未 PASS：装置本身没问题才有资格谈字节判据）"
  grep -E '^(RESULT|TBFAIL|CYC=)' "$work/n1.log" || true; exit 2
fi
"$PY" - "$work" "$work/mem8k.hex" "$work/n1.out" "$SRC" "$OFF_RD" > "$work/n1.res" 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from g32 import load, diffs
pre, got = load(sys.argv[2]), load(sys.argv[3])
src, off = int(sys.argv[4]), int(sys.argv[5])
# 参照物必须是**未受损**的源（"应该读到的东西"）⇒ 受损那一个字节才会现形
mis, first = diffs(got, pre[src:src + len(got)], 0)
print("N1_MISMATCH=%d" % mis)
print("N1_FIRST_OFF=%d" % first)
print("N1_EXPECT_FIRST_OFF=%d" % off)
sys.exit(0 if (mis == 1 and first == off) else 1)
PYEOF
N1J=$?; cat "$work/n1.res"
N1M="$(sed -n 's/^N1_MISMATCH=\([0-9]*\)$/\1/p' "$work/n1.res" | tail -1)"
N1F="$(sed -n 's/^N1_FIRST_OFF=\([0-9-]*\)$/\1/p' "$work/n1.res" | tail -1)"
if [ "$N1J" -ne 0 ] || [ "$N1M" != "1" ] || [ "$N1F" != "$OFF_RD" ]; then
  echo "RESULT: FAIL（N1 没发火：MISMATCH=$N1M FIRST_OFF=$N1F 期望 1/$OFF_RD）⇒ 闸门不可信"; exit 2
fi
echo "NEG_OK[N1]: 源区单字节受损 ⇒ rd_stream 恰好 $N1M 个字节不符、偏移 $N1F（= SRC+$OFF_RD）"

# ===========================================================================
# 作业 4：WR 模式（mode=2）
# ===========================================================================
echo "---- 作业 4：WR 流式模式（mode=2）LEN=32/96/160 ----"
cat > "$work/judge_wr.py" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from g32 import load, diffs, chunks, parse_log, seqcheck, memcheck, tbcheck
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
log, dump, mem, sin = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
src, dst, ln = int(sys.argv[6]), int(sys.argv[7]), int(sys.argv[8])
pre, got, fed = load(mem), load(dump), load(sin)
ch = chunks(ln)
bad = 0
# ① 目标区逐字节 == 喂进流的字节
mis, first = diffs(got[dst:dst + ln], fed[:ln], dst)
print("WR LEN=%d DST_vs_STREAM MISMATCH=%d FIRST_OFF=%d (fed=%d B)" % (ln, mis, first, len(fed)))
if mis:
    bad += 1
# ② 其它一个字节都不许动（源区 / 邻居；两边分着点）
a_bad, a_first = diffs(got[:dst], pre[:dst], 0)
b_bad, b_first = diffs(got[dst + ln:], pre[dst + ln:], dst + ln)
print("WR LEN=%d OTHERS_BAD=%d (before=%d at %d, after=%d at %d)"
      % (ln, a_bad + b_bad, a_bad, a_first, b_bad, b_first))
if a_bad + b_bad:
    bad += 1
# ③ AW 序列（尾块缩短）== 黄金；AR 一笔都没有
ar, aw, memline, tb = parse_log(log)
bad += seqcheck("WR AW", aw, [(dst + o, b - 1) for o, b in ch])
if ar:
    print("WR ARB_BAD %d 笔（WR 不该发 AR）" % len(ar)); bad += 1
else:
    print("WR AR_SEQ_OK 0 笔（WR 模式结构上到不了读相位）")
# ④ 交叉对账：rd=0、bursts=块数
bad += memcheck(memline, 0, ln, len(ch), max(b for _, b in ch))
bad += tbcheck(tb, {"ERR": 0, "RD_BYTES": 0, "WR_BYTES": ln, "DONE_SEEN": 1,
                    "AR_BURSTS": 0, "AW_BURSTS": len(ch), "B_OK": len(ch),
                    "RD_BEATS": 0, "WR_BEATS": ln // 8, "STREAM_RD_BEATS": 0,
                    "STREAM_WR_BEATS": ln // 8, "ORPHAN_W": 0, "WLAST_BAD": 0,
                    "WBURST_BAD": 0, "RBEAT_BAD": 0, "RDWR_OVERLAP": 0, "ARAW_OVERLAP": 0,
                    "MODE_LEAK_BAD": 0, "STREAM_IDLE_BAD": 0})
print("WR LEN=%d CYC=%s 块数=%d JUDGE_EXTRA=%d" % (ln, tb.get("CYC"), len(ch), bad))
sys.exit(1 if bad else 0)
PYEOF

for L in 32 96 160; do
  sim_stream "wr$L.log" 2 "$SRC" "$DST" "$L" "+STREAMIN=$work/fed$L.hex"; RC=$?
  if [ "$RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/wr$L.log"; then
    echo "JUDGE-RED: WR LEN=$L 装置未 PASS（vvp rc=$RC）"
    grep -E '^(RESULT|TBFAIL|CYC=)' "$work/wr$L.log" || true
    exit 1
  fi
  if ! "$PY" "$work/judge_wr.py" "$work" "$work/wr$L.log" "$work/wr$L.log.dump" \
        "$work/mem8k.hex" "$work/fed$L.hex" "$SRC" "$DST" "$L" > "$work/jw$L.out" 2>&1; then
    echo "JUDGE-RED: WR LEN=$L 判据不符"; cat "$work/jw$L.out"; exit 1
  fi
  grep -E '^(WR|MEMCHECK|WR AW|WR AR)' "$work/jw$L.out" || true
done
echo "作业 4 PASS：LEN=32/96/160 的目标区逐字节 == 喂入流，且内存 rd=0、AR 一笔未发"

# ------------- 负对照 N2：喂入流单字节受损 ⇒ 目标区**恰好 1** 个字节不符、偏移 = DST+OFF_WR -----
echo "---- 负对照 N2[WR 单字节] 喂入流下标 $OFF_WR 改一个字节 ----"
"$PY" - "$work/fed96.hex" "$work/fed96_neg.hex" "$OFF_WR" <<'PYEOF'
import sys
mem, out, off = sys.argv[1], sys.argv[2], int(sys.argv[3])
lines = [l.strip() for l in open(mem) if l.strip()]
lines[off] = "%02x" % (int(lines[off], 16) ^ 0xFF)
open(out, "w").write("\n".join(lines) + "\n")
print("N2_PERTURB fed idx=%d" % off)
PYEOF
( cd "$work" && "$VVP" stream.vvp +MODE=2 "+SRC=$SRC" "+DST=$DST" "+LEN=96" \
    "+MEMFILE=$work/mem8k.hex" "+DUMPFILE=$work/n2.log.dump" "+STREAMIN=$work/fed96_neg.hex" +dump \
    > "$work/n2.log" 2>&1 )
N2RC=$?
if [ "$N2RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/n2.log"; then
  echo "RESULT: FAIL（N2 的仿真未 PASS：装置本身没问题才有资格谈字节判据）"
  grep -E '^(RESULT|TBFAIL|CYC=)' "$work/n2.log" || true; exit 2
fi
"$PY" - "$work" "$work/mem8k.hex" "$work/n2.log.dump" "$work/fed96.hex" "$DST" "$OFF_WR" \
      > "$work/n2.out" 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from g32 import load, diffs
pre, got, fed = load(sys.argv[2]), load(sys.argv[3]), load(sys.argv[4])
dst, off, ln = int(sys.argv[5]), int(sys.argv[6]), 96
# 参照物必须是**未受损**的喂入流（"应该被写进去的东西"）⇒ 受损那一个字节才会现形
mis, first = diffs(got[dst:dst + ln], fed[:ln], dst)
print("N2_MISMATCH=%d" % mis)
print("N2_FIRST_OFF=%d" % first)
print("N2_EXPECT_FIRST_OFF=%d" % (dst + off))
sys.exit(0 if (mis == 1 and first == dst + off) else 1)
PYEOF
N2J=$?; cat "$work/n2.out"
N2M="$(sed -n 's/^N2_MISMATCH=\([0-9]*\)$/\1/p' "$work/n2.out" | tail -1)"
N2F="$(sed -n 's/^N2_FIRST_OFF=\([0-9-]*\)$/\1/p' "$work/n2.out" | tail -1)"
if [ "$N2J" -ne 0 ] || [ "$N2M" != "1" ] || [ "$N2F" != "$(( DST + OFF_WR ))" ]; then
  echo "RESULT: FAIL（N2 没发火：MISMATCH=$N2M FIRST_OFF=$N2F 期望 1/$(( DST + OFF_WR ))）⇒ 闸门不可信"; exit 2
fi
echo "NEG_OK[N2]: 喂入流单字节受损 ⇒ 目标区恰好 $N2M 个字节不符、偏移 $N2F（= DST+$OFF_WR）"

# ------------- 负对照 N3：**网表突变** wstrb 8'hff -> 8'hfe（每拍丢第 0 字节）-------------
echo "---- 负对照 N3[网表突变] axi_w_payload_strb: 8'hff -> 8'hfe ----"
if ! "$PY" - "$nl" "$work/DdrMaster_strobe.v" > "$work/n3gen.out" 2>&1 <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
src = open(sys.argv[1], encoding="utf-8").read()
pat = r"^(\s*)assign axi_w_payload_strb = _zz_axi_w_payload_strb;$"
rep = r"\1assign axi_w_payload_strb = 8'hfe;"
new, n = re.subn(pat, rep, src, flags=re.M)
print("N3MUTGEN_HITS=%d" % n)
if n != 1:
    sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(new)
PYEOF
then
  echo "RESULT: FAIL（无法构造 wstrb 突变网表）"; cat "$work/n3gen.out"; exit 2
fi
cat "$work/n3gen.out"
if ! "$IVERILOG" -g2012 -o "$work/n3.vvp" "$tbs" "$memv" "$work/DdrMaster_strobe.v" > "$work/iv_n3.log" 2>&1; then
  echo "RESULT: FAIL（突变网表编译失败）⇒ 闸门不可信"; sed -n '1,30p' "$work/iv_n3.log"; exit 2
fi
( cd "$work" && "$VVP" n3.vvp +MODE=2 "+SRC=$SRC" "+DST=$DST" "+LEN=32" \
    "+MEMFILE=$work/mem8k.hex" "+DUMPFILE=$work/n3.log.dump" "+STREAMIN=$work/fed32.hex" +dump \
    > "$work/n3.log" 2>&1 )
N3RC=$?
if ! grep -q '^RESULT: PASS' "$work/n3.log"; then
  echo "RESULT: FAIL（N3 突变网表下装置未 PASS：突变把主口改坏了，负对照不成立）"
  grep -E '^(RESULT|TBFAIL)' "$work/n3.log" || true; exit 2
fi
echo "N3 突变网表装置照旧 PASS（$(grep '^MEM ' "$work/n3.log")），说明突变没动握手/拍数/自报计数"
# 独立佐证（断言，不是嘴上说说）：LEN=32 = 4 拍，突变每拍丢第 0 字节 ⇒ 内存模型独立计数的 wr 少 4 ⇒ 28。
N3_WR="$(sed -n 's/^MEM rd=[0-9]* wr=\([0-9]*\) bursts=[0-9]* maxburst=[0-9]*$/\1/p' "$work/n3.log" | tail -1)"
if [ "${N3_WR:-}" != "28" ]; then
  echo "RESULT: FAIL（N3 独立佐证不成立：内存模型 wr=${N3_WR:-?} 期望 28 = 32 B - 4 拍各丢 1 字节）⇒ 闸门不可信"; exit 2
fi
echo "NEG_OK[N3-WRCROSS]: 内存模型独立计数 wr=$N3_WR == 28（32 B 减去 4 拍各丢的第 0 字节）"
"$PY" - "$work" "$work/mem8k.hex" "$work/n3.log.dump" "$work/fed32.hex" "$DST" \
      > "$work/n3.out" 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from g32 import load, diffs
pre, got, fed = load(sys.argv[2]), load(sys.argv[3]), load(sys.argv[4])
dst, ln = int(sys.argv[5]), 32
mis, first = diffs(got[dst:dst + ln], fed[:ln], dst)
print("N3MISMATCH=%d" % mis)
print("N3FIRST_OFF=%d" % first)
print("N3EXPECT_MISMATCH=4")           # 4 拍各丢 1 个字节
print("N3EXPECT_FIRST_OFF=%d" % dst)
sys.exit(0 if (mis == 4 and first == dst) else 1)
PYEOF
N3J=$?; cat "$work/n3.out"
N3M="$(sed -n 's/^N3MISMATCH=\([0-9]*\)$/\1/p' "$work/n3.out" | tail -1)"
N3F="$(sed -n 's/^N3FIRST_OFF=\([0-9-]*\)$/\1/p' "$work/n3.out" | tail -1)"
if [ "$N3J" -ne 0 ] || [ "$N3M" != "4" ] || [ "$N3F" != "$DST" ]; then
  echo "RESULT: FAIL（N3 没被字节判据抓住：MISMATCH=$N3M FIRST_OFF=$N3F 期望 4/$DST）⇒ 闸门不可信"; exit 2
fi
echo "NEG_OK[N3]: 网表突变（每拍丢第 0 字节）被字节判据抓住：MISMATCH=$N3M（4 拍各 1 个）、首个偏移 $N3F == DST"

# ===========================================================================
# 作业 5：COPY 逐拍不变（C3 的硬条款）
#   ★ 用旧装置 DdrCopyTb.v：它**不连 `mode`** ⇒ 新网表上悬空 = z ⇒ X ⇒ if(X) 取 else ⇒ COPY。
#     所以这一跑同时就是"旧调用方不改也照样工作"的运行期验证。
#   ★ CYC 判据用**独立算出来的** 1 + 块数*37；这个模型先在不跑仿真的情况下复现 C2 台账的 1 MiB 实测值。
# ===========================================================================
echo "---- 作业 5：COPY 逐拍不变（DdrCopyTb.v 旧装置 × 新网表，mode 悬空）LEN=$LEN_C ----"
NC=$(( LEN_C / 128 ))
EXP_CYC=$(( 1 + NC * CYC_PER_CHUNK ))
EXP_CYC_1MIB=$(( 1 + 8192 * CYC_PER_CHUNK ))
echo "CYC 模型：每块 $CYC_PER_CHUNK 拍（AR1+R16+NEXT1+WR1+W16+WB1+WNEXT1）+ CHK 1 拍"
echo "          1 MiB 复现 C2 台账：1 + 8192*$CYC_PER_CHUNK = $EXP_CYC_1MIB（c2_ddr_master.md 记的 cyc_per_group_added=1.250031 = ($EXP_CYC_1MIB-262144)/32768）"
if [ "$EXP_CYC_1MIB" != "303105" ]; then
  echo "RESULT: FAIL（CYC 模型复现不了 C2 的 1 MiB 实测 303105，模型本身不可信：$EXP_CYC_1MIB）"
  exit 2
fi
echo "CYC 模型自检 OK：$EXP_CYC_1MIB == 303105（C2 基线值）"
if [ "$EXP_CYC" != "1185" ]; then
  echo "FATAL: LEN=$LEN_C 的期望 CYC=$EXP_CYC != 1185（用例常量被改过）"; exit 2
fi

sim_copy "id.log" "$SRC_C" "$DST_C" "$LEN_C"; IDRC=$?
if [ "$IDRC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/id.log"; then
  echo "JUDGE-RED: 作业 5 装置未 PASS（vvp rc=$IDRC）"
  grep -E '^(RESULT|TBFAIL|CYC=)' "$work/id.log" || true; exit 1
fi
if ! "$PY" - "$work" "$work/id.log" "$work/id.log.dump" "$work/exp_c.hex" \
        "$work/exp_ar_c.txt" "$work/exp_aw_c.txt" "$SRC_C" "$DST_C" "$LEN_C" "$EXP_CYC" \
        > "$work/id.out" 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from g32 import load, diffs, parse_log
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
# argv: [1]=work(给 sys.path) [2]=log [3]=dump [4]=黄金镜像 [5]=黄金AR [6]=黄金AW [7..10]=src/dst/len/exp_cyc
log, dump, exp_f, ar_f, aw_f = sys.argv[2:7]
src, dst, ln, exp_cyc = (int(x) for x in sys.argv[7:11])
got, gol = load(dump), load(exp_f)
bad = 0
mis, first = diffs(got, gol)
print("ID MISMATCH=%d FIRST_OFF=%d（整片 %d B）" % (mis, first, len(got)))
if mis:
    bad += 1
ar, aw, memline, tb = parse_log(log)
exp_ar = [(int(t[0], 16), int(t[1])) for t in (l.split() for l in open(ar_f)) if t]
exp_aw = [(int(t[0], 16), int(t[1])) for t in (l.split() for l in open(aw_f)) if t]
ok_ar = (ar == exp_ar); ok_aw = (aw == exp_aw)
print("ID ARSEQ_%s %d 笔；AWSEQ_%s %d 笔" % ("OK" if ok_ar else "BAD", len(ar),
                                              "OK" if ok_aw else "BAD", len(aw)))
if not (ok_ar and ok_aw):
    bad += 1
if any(l != 15 for _, l in ar) or any(l != 15 for _, l in aw):
    print("ID LENFIELD_BAD（128 倍数长度下每笔必须恒 15）"); bad += 1
cyc = tb.get("CYC")
print("ID CYC=%s 期望=%d（= 1 + %d*37）" % (cyc, exp_cyc, ln // 128))
if cyc != exp_cyc:
    print("ID CYC_BAD %s != %d ⇒ COPY 路径拍数被改过" % (cyc, exp_cyc)); bad += 1
for k, v in (("RD_BYTES", ln), ("WR_BYTES", ln), ("ERR", 0), ("DONE_SEEN", 1)):
    if tb.get(k) != v:
        print("ID TBBAD %s=%s != %s" % (k, tb.get(k), v)); bad += 1
print("ID JUDGE_EXTRA=%d" % bad)
sys.exit(1 if bad else 0)
PYEOF
then
  echo "RESULT: FAIL（作业 5 COPY 逐拍不变判据不符）"; cat "$work/id.out"; exit 1
fi
cat "$work/id.out"
echo "NEG_OK[作业5]: COPY（128 整数倍 LEN=$LEN_C）逐字节镜像相符、AR/AW 序列相符、CYC=$EXP_CYC 逐拍不变"

# 可选：真的新旧网表 A/B 对跑（给 C2_REF_NL=<C3.3 之前的 gen/DdrMaster.v> 时启用）
if [ -n "${C2_REF_NL:-}" ]; then
  if [ ! -f "$C2_REF_NL" ]; then
    echo "RESULT: FAIL（C2_REF_NL=$C2_REF_NL 不存在）"; exit 2
  fi
  REFMD5="$(md5sum "$C2_REF_NL" | awk '{print $1}')"
  echo "---- 作业 5b：新旧网表 A/B（C2_REF_NL md5=$REFMD5，C3 基线应为 $C2_MD5）----"
  if [ "$REFMD5" != "$C2_MD5" ]; then
    echo "RESULT: FAIL（C2_REF_NL 的 md5 != C3 基线 $C2_MD5 ⇒ 参照物不是 C2 那一版网表）⇒ 闸门不可信"
    exit 2
  fi
  if ! "$IVERILOG" -g2012 -o "$work/ref.vvp" "$tbc" "$memv" "$C2_REF_NL" > "$work/iv_ref.log" 2>&1; then
    echo "RESULT: FAIL（C2 参照网表编译失败）"; sed -n '1,30p' "$work/iv_ref.log"; exit 2
  fi
  ( cd "$work" && "$VVP" ref.vvp "+SRC=$SRC_C" "+DST=$DST_C" "+LEN=$LEN_C" \
      "+MEMFILE=$work/mem2p5.hex" "+DUMPFILE=$work/ref.log.dump" +dump > "$work/ref.log" 2>&1 )
  if ! grep -q '^RESULT: PASS' "$work/ref.log"; then
    echo "RESULT: FAIL（C2 参照网表未 PASS）"; exit 2
  fi
  if ! cmp -s "$work/ref.log.dump" "$work/id.log.dump"; then
    echo "RESULT: FAIL（新旧网表的内存镜像不同 ⇒ COPY 不再逐字节不变）"; exit 1
  fi
  diff <(grep -E '^(CYC=|CHUNKS=|AR_BURSTS)' "$work/ref.log") \
       <(grep -E '^(CYC=|CHUNKS=|AR_BURSTS)' "$work/id.log") > "$work/id_ab.diff" 2>&1
  diff <(grep -E '^(ARB|AWB)' "$work/ref.log") <(grep -E '^(ARB|AWB)' "$work/id.log") \
       >> "$work/id_ab.diff" 2>&1
  if [ -s "$work/id_ab.diff" ]; then
    echo "RESULT: FAIL（新旧网表的计数/AR-AW 序列不同）"; cat "$work/id_ab.diff"; exit 1
  fi
  echo "NEG_OK[作业5b]: 新旧网表 A/B 完全相同（CYC/计数行 $(grep '^CYC=' "$work/id.log")、AR/AW 序列逐字、镜像 cmp 相同）"
else
  echo "作业 5b：SKIP（未给 C2_REF_NL=）—— 上面的 CYC 模型 + 镜像 + 序列三条判据照跑；"
  echo "          想让新旧网表**真的对跑**：C2_REF_NL=<C3.3 之前的 gen/DdrMaster.v> bash tools/run_ddrmaster32_ab.sh"
fi

# ---------------- 收口 ----------------
echo "MISMATCH=0（作业 1 的逐字节往返 + 比较器自检）"
echo "P3 运行期断言 = OK（每笔都是 32B 对齐地址；len 域逐笔 = beats-1 <= 15；读写不重叠；W 不领先 AW；W 与 AW 同门）"
echo "分块 = OK（AR/AW 序列逐笔 == Python 独立重算的 min(16, remain/8) 分块；尾块短突发真的短了）"
echo "作业 2 负对照 = 5/5 发火（len=40×2 模式 / len=48 / len=0 / dst 非对齐 → err 且零搬运）"
echo "负对照 N1[RD 单字节] = 发火（流出恰好 1 个字节不符，偏移 $N1F）"
echo "负对照 N2[WR 单字节] = 发火（目标区恰好 1 个字节不符，偏移 $N2F）"
echo "负对照 N3[网表突变 wstrb] = 发火（MISMATCH=$N3M = 4 拍各 1 个，首个偏移 $N3F == DST）"
echo "负对照 N5[模式越界] = 由装置持续断言（MODE_LEAK_BAD=0 / STREAM_IDLE_BAD=0），作业 3/4 的正向跑即其载体"
echo "作业 5 COPY 逐拍不变 = OK（CYC=$EXP_CYC 与模型一致；整片镜像逐字节相同；AR/AW 序列逐字相同）"
echo "比较器自检 = OK（扰动一个期望字节 ⇒ MISMATCH=1）"
echo "★ 口径说明（plan 的算术笔误）: plan 原文写“len=48（是 32 的倍数，合法，必须过）”。48 = 1.5×32，"
echo "  按 C3.3 自己的判据 lenOk = (len % 32 == 0) 它是**非法**的；本闸门按**判据**（而不是按那句笔误）"
echo "  把它当负对照，并把 len=64（= 2×32）当它的正对照（作业 1 已覆盖 64）。"
echo "★ 附注: 放宽到 32 B 曾一度**合法化** run_ddrcopy_ab.sh 负对照 C 的 lenmult 用例（LEN-64 = 1048512 = 32766×32，"
echo "  是 32 的倍数、不是 128 的倍数）⇒ 该用例在新契约下不再是非法入参。"
echo "  该闸门**已重挂**：run_ddrcopy_ab.sh 的 ERR_LEN_MULT_OFF 已由 64 改为 8（LEN-8 恒非 32 的倍数 ⇒ 负对照重新发火）。"
echo "RESULT: PASS"
exit 0
