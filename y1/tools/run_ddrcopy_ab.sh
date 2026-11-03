#!/usr/bin/env bash
# run_ddrcopy_ab.sh —— y1 **块拷贝**主口（rtl/DdrMaster.scala + gen/DdrMaster.v）的 J1 字节级往返闸门
#                     + J2「主口自己加的开销」测量口。
#
# 契约（rtl/DdrMaster.scala 头部）：一次 `start` 恒等于"把 src 上的 len 字节块拷到 dst"，
#   每块 **≤ 128 B（尾块缩短至 32 B 的整数倍）**，**先整块读进块缓冲、再把该块整块写出去**；读写**不重叠**。
#   入参非法（src/dst 非 32B 对齐、len 非 32 的整数倍（C3.3：粒度 128 B -> 32 B）、len == 0）⇒ err 一拍、**一字节不搬**。
#
# 作业（1 正 + 1 自检 + 3 负）：
#   作业 1 正向 —— 预载**非平凡、且对"整块平移"不混叠**的模式，拷 LEN = **1 MiB**（>= 1 MB；
#     小长度会让计数器的错位藏起来），然后把 `+DUMPFILE` 导出的内存镜像与 Python **独立**算出的
#     黄金镜像做**整片逐字节**对账，打印唯一一行 `MISMATCH=<n>` 与首个不符偏移 `FIRST_OFF=<n>`；
#     并把三个区域各自点名：
#       · `DST_EQ_SRC_BAD=0`   dst 区逐字节 == **原地**的 src 区（拷贝真的发生了、且内容对）；
#       · `SRC_UNCHANGED_BAD=0` src 区逐字节 == 预载（源**没被改动** —— 挡住"拷贝其实是把源
#                                覆写成别的东西"这类退化）；
#       · `NEIGHBOR_BAD=0`     dst 区**之外**所有字节 == 预载（含紧邻 dst 前后各 32 B）
#                              —— 挡住"多写/越界写"（尾块越界正是本契约把 len 钉成 32 B 整数倍的理由）。
#     另外四项独立交叉对账（不盲信装置的 PASS）：
#       · `ARB <addr> arlen=<n>` / `AWB <addr> awlen=<n>`：读/写地址序列必须恰好是
#         SRC,SRC+128,... 与 DST,DST+128,...，且**每一笔 arlen/awlen 都是 15**（P3 运行期断言）；
#       · `MEM rd=<b> wr=<b> bursts=<n> maxburst=<n>`：内存模型**独立**记的读/写字节数与突发数
#         必须与装置自报的 `RD_BYTES`/`WR_BYTES`/块数一致（两处独立计数一起对得上才算数）；
#       · `RDWR_OVERLAP=0` / `ARAW_OVERLAP=0` / `AW_LEAD_MAX=0` / `WLAST_BAD=0`：读写不重叠、
#         AR/AW 不同拍、写相位绝不领先读相位、每笔写突发恰好 16 拍且末拍 wlast=1。
#     最后算 J2：groups = LEN/32、cyc_per_group = (CYC - 搬运本身必走的拍数)/groups，判据 **<= 2**。
#   作业 2 负对照 A（**网表突变**，不是测试钩子）—— 拷一份 gen/DdrMaster.v，把 CHK 里写基址的初值
#     `wbase <= dst;` 改成 `wbase <= dst + 128;`（= **整条写地址序列平移一块**）。用同一装置重跑：
#     装置本身照旧 PASS（握手/字节计数一个不变 —— 判据的理由），但字节对账**必须**报
#     `MISMATCH > 0` 且**首个不符偏移恰好 == DST**（dst 的第 0 字节再也没人写它 ⇒ 它还是预载，
#     而黄金镜像那里是源内容；两者因"模式不对块混叠"必然不同）。
#     （**不用"故意给个非对齐 dst"来当这条负对照**：那在新契约下会正确地走 err 路径，
#      根本到不了字节比较，见作业 4。）
#   作业 3 负对照 B（**字节粒度**）—— 把源区**恰好一个字节**改掉（SRC+61，61 % 8 = 5 ⇒ 既不是
#     8 字节行对齐也不是块对齐），用同一装置重跑：dst 区对黄金镜像的 MISMATCH 必须**恰好 1**、
#     且首个不符偏移恰好 == DST+61。若比较器是"按块/按 8 字节行"的，这两个数都不可能是这个值。
#   作业 4 负对照 C（**err 路径**，新契约的硬条款）—— 三种非法入参各跑一次，必须由**装置自己**
#     报 err 且**一字节不搬**（无 ARB/AWB、MEM rd=wr=bursts=0、镜像与预载逐字节相同）：
#       · dst 非 32B 对齐；· len 非 32 的整数倍（32-B 粒度是 C3.3 引入的契约；旧口径的 128-B
#         样例 LEN-64 在新契约下已**合法**，故此处改挂 LEN-8 使其恒为非法，见 ERR_LEN_MULT_OFF）；
#       · len == 0。
#   比较器自检 —— 扰动黄金镜像里一个期望字节 ⇒ MISMATCH 必须**恰好 1**（不做这步就分不清
#     "真的逐字节相符"与"比较器把两边都读成空表也报 0"）。
#
# 退出码：
#   0 = 通过（正向整片逐字节相符 + 三区域干净 + 四项交叉对账全过 + J2 <= 2 + 3 道负对照都发火 + 自检过）
#   1 = 对账不符 / 编译或仿真失败 / 装置未 PASS / P3（地址递进、arlen/awlen）不成立 / J2 超判据
#   2 = 负对照没发火，或模式生成/比较器自检不过 ⇒ **闸门自身不可信**（橡皮图章）
#
# 装置契约（rtl_test/DdrCopyTb.v + rtl_test/AxiMemModel.v + gen/DdrMaster.v）：
#   +SRC= +DST= +LEN=（十进制）  +MEMFILE= +DUMPFILE=（模型自己取）  +EXPECT_ERR（可选）
#   装置输出：`ARB <addr> arlen=<n>` / `AWB <addr> awlen=<n>` / `BOK <addr>` / 计数行 /
#             `CYC=<n> RD_BYTES=<n> WR_BYTES=<n> ERR=<b>` / `RESULT: PASS|FAIL`（FAIL ⇒ $fatal ⇒ vvp 非 0）
#   内存模型输出：末尾 `MEM rd=<bytes> wr=<bytes> bursts=<n> maxburst=<n>`
set -uo pipefail

PY="${PY:-python}"
here="$(cd "$(dirname "$0")" && pwd)"
gen="$here/../gen"
tb="$here/../rtl_test/DdrCopyTb.v"
memv="$here/../rtl_test/AxiMemModel.v"
nl="$gen/DdrMaster.v"

# ---- 用例常量（必须与 rtl_test/DdrCopyTb.v 里 AxiMemModel 的 MEMSZ 一致）----
MEMSZ=2621440              # 2.5 MiB：够放 [SRC,SRC+LEN) + [DST,DST+LEN) + 前后两段"邻居"
SRC=131072                 # 0x20000，32B 对齐
DST=1441792                # 0x160000，32B 对齐；与 src 区不重叠
LEN=1048576                # **1 MiB**（>= 1 MB；块数 N=8192，地址计数器要真的翻很多次）
PERIOD=251                 # 模式周期：素数，与块长 128 互素 ⇒ 整块平移 k 格（k<251）必被发现
OFF_1BYTE=61               # 负对照 B 破坏的源字节下标：61 % 8 = 5（非 8 字节行对齐、非块对齐）
# 负对照 C 的非法长度偏移（**判据前提更新，见下**）。
#   【为什么 64 变成 8】旧值 64 挂的是旧契约 `len % 128 == 0`：LEN-64 = 1048512 不是 128 的整数倍 ⇒
#   旧装置"静默多拷 64 B"，正是负对照要堵的那条。C3.3（commit f922032，rtl/DdrMaster.scala 头注）
#   把长度契约**有意**放宽到 32 B 粒度（`len % 32 == 0`，为一个描述符 32 B 服务）；于是
#   LEN-64 = 1048512 = 32766×32 **变成合法长度** ⇒ 该负对照不再发火（装置正确地 err=0）。
#   这是**判据前提跟着契约放宽一起改**，不是 RTL 回归。新值取 8：LEN-8 = 1048568，
#   1048568 % 32 = 24 ≠ 0 ⇒ 在新契约下**恒为非法长度**（旧口径下 8 亦非法，两头都对）。
ERR_LEN_MULT_OFF=8

work="$(mktemp -d)"
cleanup() {
  if [ "${KEEP_TMP:-0}" = "1" ]; then
    echo "KEEP_TMP=1 => 激励与日志留在 $work"
  else
    rm -rf "$work"
  fi
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

echo "== run_ddrcopy_ab: 块拷贝主口 1 MiB 字节级往返 + 三个负对照 + 主口开销(J2) =="
echo "   tb  =$tb"
echo "   mem =$memv"
echo "   nl  =$nl"
echo "   iverilog=${IVERILOG:-<找不到>}  vvp=${VVP:-<找不到>}"
echo "   tmp =$work"
echo "   用例 SRC=$SRC DST=$DST LEN=$LEN (MEMSZ=$MEMSZ PERIOD=$PERIOD)"

# ---------------- 前置检查 ----------------
if [ ! -f "$nl" ]; then
  echo "FATAL: 找不到网表 $nl"
  echo "       先生成: cd y1 && printf 'Test/runMain DdrMasterGen D:/code/PDS/VexiiYeshenLinux/y1/gen\\nexit\\n' | bash sbt.sh"
  exit 1
fi
if [ ! -f "$tb" ];   then echo "FATAL: 找不到装置 $tb";       exit 1; fi
if [ ! -f "$memv" ]; then echo "FATAL: 找不到内存模型 $memv"; exit 1; fi
if [ -z "$IVERILOG" ] || [ -z "$VVP" ]; then echo "FATAL: 找不到 iverilog / vvp"; exit 1; fi

# ---------------- 0) 造激励：非平凡 + **非块混叠**模式；Python 独立算黄金镜像 ----------------
if ! "$PY" - "$work" "$MEMSZ" "$SRC" "$DST" "$LEN" "$PERIOD" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

work = sys.argv[1]
memsz, src, dst, ln, period = (int(x) for x in sys.argv[2:7])

def pat(i):
    """周期恰好 = period（251）的模式。`(i%251)*131+7` 再 %251：131 与 251 互素 ⇒ 在 0..250 上
    是个**排列**（周期恰 251，不是它的某个因数），任取 128 个连续字节都两两不同（非平凡）。"""
    return ((i % period) * 131 + 7) % period

# ---------------- 非混叠断言（闸门可信度的前提；不成立就直接红，不许"先跑再说"）----------------
# 1) 周期必须**恰好**是 period：否则"平移 k 格"可能落回同一相位。
assert len(set(pat(i) for i in range(period))) == period, "FATAL: 模式周期不是恰好 %d" % period
# 2) period 与块长 128 互素（251 是素数且 251 > 128）⇒ 整块平移 k 格（k=1..16）
#    会让窗口里**每一个字节**都变 ⇒ "地址整块偏一格"对字节比较**必然可见**。
assert period % 128 != 0 and 128 % period != 0, "FATAL: 模式周期与块长不互素"
for k in range(1, 17):
    assert all(pat(j) != pat(j + 128 * k) for j in range(0, 4 * period)), \
        "FATAL: 模式对整块平移混叠 k=%d" % k
# 3) src 与 dst 的相位差不能是 period 的整数倍：否则**原地不动**也能让 dst 区看起来"等于源内容"。
#    （更强的等价说法在下面用 diff_pre == ln 直接断言：dst 区预载与源内容**每一个字节**都不同 ⇒
#      任何"没写/漏写一格"都会在字节对账里现形。注意这里**不**要求 (dst-src) 不是 128 的倍数：
#      地址差多少个块是使用者的自由，而"整块平移"类缺陷由第 2) 条的 251 互素来兜。）
assert (dst - src) % period != 0, "FATAL: src/dst 相位对混叠 ⇒ 不拷贝也能过字节对账"

# ---------------- 结构自检 ----------------
assert src % 32 == 0 and dst % 32 == 0, "FATAL: 地址必须 32B 对齐"
assert ln % 128 == 0 and ln > 0, "FATAL: 长度必须是 128 的正整数倍"
assert src + ln <= dst or dst + ln <= src, "FATAL: src/dst 区重叠（本用例要求不重叠）"
assert max(src + ln, dst + ln) <= memsz, "FATAL: 越出已建模内存"
assert min(src, dst) >= 128, "FATAL: 前面要留出邻居字节"
assert memsz - (dst + ln) >= 128, "FATAL: 后面要留出邻居字节"

pre = bytes(pat(i) for i in range(memsz))
with open(work + "/mem.hex", "w") as f:
    for b in pre:
        f.write("%02x\n" % b)

# 黄金镜像 = 预载，但 dst 区换成 src 区的**内容**（= 拷贝正确的样子）。
golden = pre[:dst] + pre[src:src + ln] + pre[dst + ln:]
with open(work + "/exp.hex", "w") as f:
    for b in golden:
        f.write("%02x\n" % b)

# 期望的 AR / AW 序列（地址每块 +128，突发长度恒 15）
with open(work + "/exp_ar.txt", "w") as f:
    for k in range(ln // 128):
        f.write("%08x 15\n" % (src + 128 * k))
with open(work + "/exp_aw.txt", "w") as f:
    for k in range(ln // 128):
        f.write("%08x 15\n" % (dst + 128 * k))

# 自检：源窗口非平凡（全常数会让"没搬"也通过），且 dst 区**确实**与预载不同
uniq = len(set(pre[src:src + 128]))
assert uniq > 1, "FATAL: 源窗口是常数 ⇒ 判据没意义"
diff_pre = sum(1 for j in range(ln) if pre[src + j] != pre[dst + j])
assert diff_pre == ln, "FATAL: dst 区预载与源内容逐字节相同（%d/%d）⇒ 不拷贝也能过" % (diff_pre, ln)

print("MEMGEN bytes=%d chunks=%d uniq128=%d dst_vs_preload_diff=%d period=%d"
      % (memsz, ln // 128, uniq, diff_pre, period))
print("NONALIAS: 周期恰 %d；与 128 互素；整块平移 k=1..16 每字节都变；(DST-SRC)%%%d=%d!=0"
      % (period, period, (dst - src) % period))
PYEOF
then
  echo "FATAL: 生成内存/黄金镜像失败（或非混叠断言不成立）⇒ 闸门不可信"
  exit 2
fi
[ -s "$work/mem.hex" ] && [ -s "$work/exp.hex" ] && [ -s "$work/exp_ar.txt" ] && [ -s "$work/exp_aw.txt" ] \
  || { echo "FATAL: 激励文件缺失"; exit 1; }

# ---------------- 1) 编译（好网表）----------------
if ! "$IVERILOG" -g2012 -o "$work/sim.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败（好网表）"; sed -n '1,40p' "$work/iv.log"; exit 1
fi
echo "---- iverilog 编译 OK（好网表）----"

# 跑一次仿真。用法: run_sim <vvp> <logbase> <memfile> <src> <dst> <len> [extra plusargs...]
run_sim() {
  local vvp="$1" log="$2" mf="$3" s="$4" d="$5" l="$6"; shift 6
  ( cd "$work" && "$VVP" "$vvp" \
      "+SRC=$s" "+DST=$d" "+LEN=$l" \
      "+MEMFILE=$mf" "+DUMPFILE=$work/$log.dump" +dump "$@" > "$log" 2>&1 )
  return $?
}

# 逐字节比较的公共实现：按 64 KiB 块先做 C 级切片比较跳过相同的块，只在不同的块里逐字节数。
cat > "$work/cmpbytes.py" <<'PYEOF'
def load(p):
    return bytes.fromhex("".join(open(p).read().split()))

def diffs(a, b, base=0):
    """等长字节串的逐字节比较 -> (count, first_abs_off)；first = -1 表示完全相同。"""
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

# ---------------- 判定器 1：正向（整片 + 三区域 + 四条交叉对账 + J2）----------------
cat > "$work/judge1.py" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from cmpbytes import load, diffs
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

mem_f, exp_f, dump_f, log_f, ar_f, aw_f = sys.argv[2:8]
src, dst, ln = (int(x) for x in sys.argv[8:11])

pre, gol, got = load(mem_f), load(exp_f), load(dump_f)
bad = 0

# --- 1a) 整片逐字节：镜像 vs 黄金镜像 ---
mis, first = diffs(got, gol)
print("MISMATCH=%d" % mis)
print("FIRST_OFF=%d" % first)

# --- 1b) 三个区域各自点名 ---
d_bad, d_first = diffs(got[dst:dst + ln], got[src:src + ln], dst)      # dst 区 == **原地** src 区
s_bad, s_first = diffs(got[src:src + ln], pre[src:src + ln], src)      # src 区 == 预载（没被改）
n_bad, n_first = diffs(got[:dst], pre[:dst], 0)
t_bad, t_first = diffs(got[dst + ln:], pre[dst + ln:], dst + ln)
print("DST_EQ_SRC_BAD=%d (first=%d)" % (d_bad, d_first))
print("SRC_UNCHANGED_BAD=%d (first=%d)" % (s_bad, s_first))
print("NEIGHBOR_BAD=%d (before_dst=%d at %d, after_dstlen=%d at %d)"
      % (n_bad + t_bad, n_bad, n_first, t_bad, t_first))
neig32_b = sum(1 for j in range(32) if got[dst - 32 + j] != pre[dst - 32 + j])
neig32_a = sum(1 for j in range(32) if got[dst + ln + j] != pre[dst + ln + j])
print("NEIGHBOR32 before_dst=%d after_dstlen=%d" % (neig32_b, neig32_a))
if d_bad or s_bad or n_bad + t_bad or neig32_b or neig32_a:
    bad += 1

# --- 1c) AR / AW 地址序列 + 突发长度（P3 运行期断言）---
ar, aw = [], []
memline, tb = None, {}
# 装置的自报计数：一行里可能塞多个 key=value（`AR_BURSTS=.. AW_BURSTS=.. B_OK=..`）⇒ 按 token 扫。
INTEREST = ("CYC", "RD_BYTES", "WR_BYTES", "ERR", "CHUNKS", "AR_BURSTS", "AW_BURSTS",
            "B_OK", "RD_BEATS", "WR_BEATS", "RDWR_OVERLAP", "ARAW_OVERLAP",
            "AW_LEAD_MAX", "WLAST_BAD")
for line in open(log_f, errors="replace"):
    t = line.split()
    if not t:
        continue
    if t[0] == "ARB":
        ar.append((int(t[1], 16), int(t[2].split("=")[1])))
        continue
    if t[0] == "AWB":
        aw.append((int(t[1], 16), int(t[2].split("=")[1])))
        continue
    if t[0] == "MEM":
        memline = line.strip()
        continue
    for p in t:
        if "=" in p:
            k, v = p.split("=", 1)
            if k in INTEREST:
                try:
                    tb[k] = int(v)
                except ValueError:
                    pass

exp_ar = [(int(t[0], 16), int(t[1])) for t in (l.split() for l in open(ar_f)) if t]
exp_aw = [(int(t[0], 16), int(t[1])) for t in (l.split() for l in open(aw_f)) if t]
chunks = ln // 128
if ar != exp_ar:
    print("ARSEQ_BAD got=%d expect=%d firstbad=%s" % (len(ar), len(exp_ar),
          next((("0x%08x/0x%08x" % (a[0], b[0])) for a, b in zip(ar, exp_ar) if a != b), "-")))
    bad += 1
else:
    print("ARSEQ_OK %d 笔，地址逐笔 +128" % len(ar))
if aw != exp_aw:
    print("AWSEQ_BAD got=%d expect=%d firstbad=%s" % (len(aw), len(exp_aw),
          next((("0x%08x/0x%08x" % (a[0], b[0])) for a, b in zip(aw, exp_aw) if a != b), "-")))
    bad += 1
else:
    print("AWSEQ_OK %d 笔，地址逐笔 +128" % len(aw))
if any(l != 15 for _, l in ar): print("ARLEN_BAD"); bad += 1
if any(l != 15 for _, l in aw): print("AWLEN_BAD"); bad += 1

# --- 1d) 与内存模型的独立计数交叉对账 ---
if memline is None:
    print("MEMLINE_MISSING"); bad += 1
else:
    kv = dict(p.split("=") for p in memline.split()[1:])
    rd, wr, bur, mx = int(kv["rd"]), int(kv["wr"]), int(kv["bursts"]), int(kv["maxburst"])
    print("MEMCHECK rd=%d wr=%d bursts=%d maxburst=%d (expect rd=%d wr=%d bursts=%d maxburst=16)"
          % (rd, wr, bur, mx, ln, ln, 2 * chunks))
    if rd != ln:          print("MEMRD_BAD %d != %d" % (rd, ln)); bad += 1
    if wr != ln:          print("MEMWR_BAD %d != %d" % (wr, ln)); bad += 1
    if bur != 2 * chunks: print("MEMBURSTS_BAD %d != %d" % (bur, 2 * chunks)); bad += 1
    if mx != 16:          print("MEMMAXBURST_BAD %d != 16" % mx); bad += 1

for k, v in (("RD_BYTES", ln), ("WR_BYTES", ln), ("AR_BURSTS", chunks),
             ("AW_BURSTS", chunks), ("B_OK", chunks), ("CHUNKS", chunks),
             ("RD_BEATS", ln // 8), ("WR_BEATS", ln // 8), ("ERR", 0),
             ("RDWR_OVERLAP", 0), ("ARAW_OVERLAP", 0), ("AW_LEAD_MAX", 0), ("WLAST_BAD", 0)):
    if tb.get(k) != v:
        print("TBBAD %s=%s != %d" % (k, tb.get(k), v)); bad += 1
print("TBCHECK AR_BURSTS=%s AW_BURSTS=%s B_OK=%s RD_BYTES=%s WR_BYTES=%s RDWR_OVERLAP=%s AW_LEAD_MAX=%s"
      % (tb.get("AR_BURSTS"), tb.get("AW_BURSTS"), tb.get("B_OK"),
         tb.get("RD_BYTES"), tb.get("WR_BYTES"), tb.get("RDWR_OVERLAP"), tb.get("AW_LEAD_MAX")))

# --- 1e) J2：主口自己加的开销 ---
cyc = tb.get("CYC")
groups = ln // 32                     # 一个 32 B DDR 事务的量
beat_cycles = 2 * (ln // 8)           # 搬运数据本身必走的拍数：读 LEN/8 拍 + 写 LEN/8 拍（8 B/拍）
overhead = cyc - beat_cycles
cpg = overhead / groups               # 主口每 32 B 加了多少拍（含块间那 5 拍的固定开销摊薄）
cpg_total = cyc / groups              # 字面口径 CYC/groups（见下"两个数都印"的理由）
print("J2 cyc=%d rd_bytes=%s wr_bytes=%s" % (cyc, tb.get("RD_BYTES"), tb.get("WR_BYTES")))
print("J2 groups=%d beat_cycles=%d overhead=%d cyc_per_group=%.6f cyc_per_group_total=%.6f"
      % (groups, beat_cycles, overhead, cpg, cpg_total))
if cyc < beat_cycles:
    print("J2_SANITY_BAD CYC=%d < 搬运下限 %d" % (cyc, beat_cycles)); bad += 1
if cpg > 2.0:
    print("J2_OVERHEAD_BAD cyc_per_group=%.6f > 2" % cpg); bad += 1
else:
    print("J2_OVERHEAD_OK cyc_per_group=%.6f <= 2" % cpg)

print("JUDGE_EXTRA=%d" % bad)
sys.exit(1 if (mis != 0 or bad != 0 or cpg > 2.0) else 0)
PYEOF

# ===========================================================================
# 作业 1：正向 —— SRC -> DST，1 MiB
# ===========================================================================
echo "---- 作业 1：正向 SRC=$SRC DST=$DST LEN=$LEN ($(( LEN / 1048576 )) MiB, $(( LEN / 128 )) 块) ----"
run_sim sim.vvp main.log "$work/mem.hex" "$SRC" "$DST" "$LEN"; RC=$?
if [ "$RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/main.log"; then
  echo "JUDGE-RED: 正向仿真未 PASS（vvp rc=$RC）"
  grep -E '^(RESULT|TBFAIL|TB-ERROR|CYC=|AR_BURSTS|MEM )' "$work/main.log" || true
  exit 1
fi

"$PY" "$work/judge1.py" "$work" "$work/mem.hex" "$work/exp.hex" "$work/main.log.dump" "$work/main.log" \
  "$work/exp_ar.txt" "$work/exp_aw.txt" "$SRC" "$DST" "$LEN" > "$work/judge1.out" 2>&1
JRC=$?
cat "$work/judge1.out"
MIS="$(sed -n 's/^MISMATCH=\([0-9][0-9]*\)$/\1/p' "$work/judge1.out" | tail -1)"
JX="$(sed -n 's/^JUDGE_EXTRA=\([0-9][0-9]*\)$/\1/p' "$work/judge1.out" | tail -1)"
CPG="$(sed -n 's/^J2 groups=[0-9]* beat_cycles=[0-9]* overhead=[0-9]* cyc_per_group=\([0-9.]*\).*$/\1/p' "$work/judge1.out" | tail -1)"
CPGT="$(sed -n 's/^J2 .*cyc_per_group_total=\([0-9.]*\)$/\1/p' "$work/judge1.out" | tail -1)"
[ -n "$MIS" ] || MIS="-1"
[ -n "$JX" ]  || JX="-1"
[ -n "$CPG" ] || CPG="-1"
grep -E '^(ARSEQ|AWSEQ|MEMCHECK|TBCHECK|NEIGHBOR32)' "$work/judge1.out" || true
if [ "$JRC" -ne 0 ] || [ "$MIS" != "0" ] || [ "$JX" != "0" ]; then
  echo "RESULT: FAIL（正相对账 MISMATCH=$MIS JUDGE_EXTRA=$JX）"
  exit 1
fi
echo "正相对账 OK：整片 MISMATCH=0；dst==src 且 src 未改且邻居未动；AR/AW 序列与 arlen 全对；"
echo "              与内存模型交叉对账相符；读写不重叠 / 写不领先读 / 每笔 wlast 正确。"

# ---------------- 比较器自检：扰动黄金镜像里一个期望字节 ⇒ MISMATCH 必须恰好 1 ----------------
"$PY" - "$work" "$DST" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
work, dst = sys.argv[1], int(sys.argv[2])
lines = [l.strip() for l in open(work + "/exp.hex") if l.strip()]
assert len(lines) > dst + 40, "FATAL: 黄金镜像太短，自检没意义"
idx = dst + 17
lines[idx] = "%02x" % ((int(lines[idx], 16) ^ 0x01) & 0xFF)
open(work + "/exp_neg.hex", "w").write("\n".join(lines) + "\n")
print("CMP_SELFTEST_PERTURB idx=%d" % idx)
PYEOF

if ! "$PY" - "$work" "$work/exp_neg.hex" "$work/main.log.dump" > "$work/selftest.out" 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from cmpbytes import load, diffs
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
exp, got = load(sys.argv[2]), load(sys.argv[3])
mis, first = diffs(got, exp)
print("MISMATCH=%d FIRST_OFF=%d" % (mis, first))
sys.exit(0 if mis == 1 else 1)
PYEOF
then
  echo "RESULT: FAIL（比较器自检不过：扰动一个期望字节后 MISMATCH 不是恰好 1）"
  cat "$work/selftest.out"
  exit 2
fi
SELFMIS="$(sed -n 's/^MISMATCH=\([0-9][0-9]*\).*$/\1/p' "$work/selftest.out" | tail -1)"
echo "CMP_SELFTEST MISMATCH=$SELFMIS（期望恰好 1）"
if [ "$SELFMIS" != "1" ]; then
  echo "RESULT: FAIL（比较器自检 MISMATCH=$SELFMIS != 1）⇒ 闸门不可信"
  exit 2
fi

# ===========================================================================
# 作业 2：负对照 A —— **网表突变**：整条写地址序列平移一块（wbase 初值 +128）
#   装置照旧 PASS（握手/计数一个不变），但字节对账必须报 MISMATCH>0 且 FIRST_OFF == DST：
#   dst 区的第 0 字节再也没人写它（写都落在 dst+128 起）⇒ 它还是预载，而黄金镜像是源内容。
# ===========================================================================
echo "---- 作业 2：负对照 A[写地址整条平移一块] wbase := dst + 128 ----"
if ! "$PY" - "$nl" "$work/DdrMaster_shift.v" > "$work/mutgen.out" 2>&1 <<'PYEOF'
import re
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
src = open(sys.argv[1], encoding="utf-8").read()
pat = r"^(\s*)wbase <= dst;$"
rep = r"\1wbase <= (dst + 28'h0000080);"
new, n = re.subn(pat, rep, src, flags=re.M)
print("MUTGEN_HITS=%d" % n)
if n != 1:
    sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(new)
PYEOF
then
  echo "RESULT: FAIL（无法构造 写地址平移 突变网表）"; cat "$work/mutgen.out"
  exit 2
fi
cat "$work/mutgen.out"

if ! "$IVERILOG" -g2012 -o "$work/mut.vvp" "$tb" "$memv" "$work/DdrMaster_shift.v" > "$work/iv_mut.log" 2>&1; then
  echo "RESULT: FAIL（突变网表编译失败）⇒ 闸门不可信"; sed -n '1,40p' "$work/iv_mut.log"; exit 2
fi
run_sim mut.vvp mut.log "$work/mem.hex" "$SRC" "$DST" "$LEN"; MRC=$?
if ! grep -q '^RESULT: PASS' "$work/mut.log"; then
  echo "RESULT: FAIL（突变网表下装置未 PASS：突变把主口改坏了，负对照不成立）"
  grep -E '^(RESULT|TBFAIL|CYC=|MEM )' "$work/mut.log" || true
  exit 2
fi
grep -E '^(CYC=|AR_BURSTS|MEM )' "$work/mut.log" || true
MUTMEM="$(grep '^MEM rd=' "$work/mut.log" | tail -1)"
echo "突变网表 MEM 计数 = $MUTMEM（必须与好网表相同：突变只改了 写到哪里 ，没改 搬多少 ）"
case "$MUTMEM" in
  "MEM rd=$LEN wr=$LEN bursts=$(( 2 * LEN / 128 )) maxburst=16") : ;;
  *) echo "RESULT: FAIL（突变把字节数/突发数也改了 ⇒ 它不再是纯地址平移，负对照不干净）"; exit 2 ;;
esac

"$PY" - "$work" "$work/exp.hex" "$work/mut.log.dump" "$DST" "$LEN" > "$work/mutjudge.out" 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from cmpbytes import load, diffs
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
exp, got, dst, ln = load(sys.argv[2]), load(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
mis, first = diffs(got, exp)
print("MUTMISMATCH=%d" % mis)
print("MUTFIRST_OFF=%d" % first)
print("MUTEXPECT_FIRST_OFF=%d" % dst)
sys.exit(0 if (mis > 0 and first == dst) else 1)
PYEOF
MUTC=$?
cat "$work/mutjudge.out"
MUTMIS="$(sed -n 's/^MUTMISMATCH=\([0-9][0-9]*\)$/\1/p' "$work/mutjudge.out" | tail -1)"
MUTFIRST="$(sed -n 's/^MUTFIRST_OFF=\([0-9-][0-9]*\)$/\1/p' "$work/mutjudge.out" | tail -1)"
if [ "$MUTC" -ne 0 ] || [ "${MUTMIS:-0}" -le 0 ] 2>/dev/null || [ "$MUTFIRST" != "$DST" ]; then
  echo "RESULT: FAIL（写地址平移突变没被字节判据抓住：MISMATCH=$MUTMIS FIRST_OFF=$MUTFIRST 期望 $DST）⇒ 闸门不可信"
  exit 2
fi
echo "NEG_OK[shift]: 字节判据抓住了写地址平移（MISMATCH=$MUTMIS，首个不符偏移 $MUTFIRST == DST）"

# ===========================================================================
# 作业 3：负对照 B —— **字节粒度**：源区恰好一个字节被改（SRC+61）
#   dst 区对黄金镜像必须**恰好 1** 个字节不符，且首个不符偏移恰好 == DST+61。
# ===========================================================================
echo "---- 作业 3：负对照 B[字节粒度] 源区 SRC+$OFF_1BYTE 改一个字节 ----"
"$PY" - "$work/mem.hex" "$work/mem_neg1.hex" "$SRC" "$OFF_1BYTE" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
mem, out, src, off = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
lines = [l.strip() for l in open(mem) if l.strip()]
idx = src + off
old = int(lines[idx], 16)
lines[idx] = "%02x" % (old ^ 0xFF)
open(out, "w").write("\n".join(lines) + "\n")
print("NEGB_PERTURB addr=%d old=%02x new=%02x" % (idx, old, old ^ 0xFF))
PYEOF
run_sim sim.vvp neg1.log "$work/mem_neg1.hex" "$SRC" "$DST" "$LEN"; N1RC=$?
if [ "$N1RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/neg1.log"; then
  echo "RESULT: FAIL（负对照 B 的仿真未 PASS：装置本身没问题，才有资格谈字节判据）"
  grep -E '^(RESULT|TBFAIL|CYC=|MEM )' "$work/neg1.log" || true
  exit 2
fi

"$PY" - "$work" "$work/exp.hex" "$work/neg1.log.dump" "$work/mem_neg1.hex" \
      "$SRC" "$DST" "$LEN" "$OFF_1BYTE" > "$work/negbjudge.out" 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from cmpbytes import load, diffs
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
exp, got = load(sys.argv[2]), load(sys.argv[3])
pre_run  = load(sys.argv[4])
src, dst, ln, off = (int(x) for x in sys.argv[5:9])
# dst 区 vs 黄金（黄金里是**未受损**的源内容）⇒ 受损的那一个字节在 dst 区里冒出来，且只有它
mis, first = diffs(got[dst:dst + ln], exp[dst:dst + ln], dst)
print("NEGB_MISMATCH=%d" % mis)
print("NEGB_FIRST_OFF=%d" % first)
print("NEGB_EXPECT_FIRST_OFF=%d" % (dst + off))
# src 区 / 邻居 vs **本次运行**的预载（"没被改"这句判据的正确参照物）
s_bad, s_first = diffs(got[src:src + ln], pre_run[src:src + ln], src)
n_bad, n_first = diffs(got[:dst], pre_run[:dst], 0)
t_bad, t_first = diffs(got[dst + ln:], pre_run[dst + ln:], dst + ln)
print("NEGB_SRC_UNCHANGED_BAD=%d NEGB_NEIGHBOR_BAD=%d" % (s_bad, n_bad + t_bad))
sys.exit(0 if (mis == 1 and first == dst + off and s_bad == 0 and n_bad + t_bad == 0) else 1)
PYEOF
NBJ=$?
cat "$work/negbjudge.out"
NBMIS="$(sed -n 's/^NEGB_MISMATCH=\([0-9][0-9]*\)$/\1/p' "$work/negbjudge.out" | tail -1)"
NBFIRST="$(sed -n 's/^NEGB_FIRST_OFF=\([0-9][0-9]*\)$/\1/p' "$work/negbjudge.out" | tail -1)"
if [ "$NBJ" -ne 0 ] || [ "${NBMIS:-0}" != "1" ] || [ "$NBFIRST" != "$(( DST + OFF_1BYTE ))" ]; then
  echo "RESULT: FAIL（单字节负对照 MISMATCH=$NBMIS FIRST_OFF=$NBFIRST 期望 1 / $(( DST + OFF_1BYTE ))）⇒ 闸门不可信"
  exit 2
fi
echo "NEG_OK[onebyte]: 单字节受损 ⇒ dst 区 MISMATCH=$NBMIS 恰为 1，首个不符偏移 $NBFIRST（= DST+$OFF_1BYTE）"
echo "                 ⇒ 比较器确实**按字节**（块粒度会报 1 块/128 字节，8 字节行粒度会报到 8 对齐的偏移上）"

# ===========================================================================
# 作业 4：负对照 C —— err 路径（三种非法入参各一次，必须 err 且**一字节不搬**）
# ===========================================================================
neg_err() { # <tag> <src> <dst> <len> <说明>
  local tag="$1" s="$2" d="$3" l="$4" why="$5" log="err_$1.log" ok=1
  echo "---- 作业 4：负对照 C[$tag] $why (SRC=$s DST=$d LEN=$l) ----"
  run_sim sim.vvp "$log" "$work/mem.hex" "$s" "$d" "$l" +EXPECT_ERR
  if ! grep -q '^RESULT: PASS' "$work/$log"; then
    echo "NEG_RED[$tag]: 装置没按预期报 err"
    grep -E '^(RESULT|CYC=|AR_BURSTS|CHUNKS)' "$work/$log" || true
    ok=0
  fi
  grep -q '^CYC=.* ERR=1' "$work/$log"       || { echo "NEG_RED[$tag]: 日志里没有 ERR=1"; ok=0; }
  grep -q '^AR_BURSTS=0 AW_BURSTS=0 B_OK=0$' "$work/$log" || { echo "NEG_RED[$tag]: 竟然发起过突发"; ok=0; }
  grep -q '^CHUNKS=0$' "$work/$log"          || { echo "NEG_RED[$tag]: 抓到了块（搬了东西）"; ok=0; }
  grep -q '^MEM rd=0 wr=0 bursts=0' "$work/$log" || { echo "NEG_RED[$tag]: 内存模型记的读/写/突发数不为 0"; ok=0; }
  if grep -q '^ARB \|^AWB \|^BOK ' "$work/$log"; then echo "NEG_RED[$tag]: 竟然举过 AR/AW"; ok=0; fi
  # 镜像必须与预载逐字节相同（比"计数器为 0"更硬的一句：一个字节都没动）
  local same
  same="$("$PY" - "$work/mem.hex" "$work/$log.dump" "$work" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[3])
from cmpbytes import load, diffs
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
a, b = load(sys.argv[1]), load(sys.argv[2])
c, f = diffs(a, b)
print("%d %d" % (c, f))
PYEOF
)"
  if [ "$same" != "0 -1" ]; then echo "NEG_RED[$tag]: 镜像与预载不同（diff=$same）⇒ 非法入参竟然改了内存"; ok=0; fi
  if [ "$ok" = "1" ]; then
    echo "NEG_OK[$tag]: 装置报 err 且零搬运（AR/AW/B=0、CHUNKS=0、MEM rd=wr=bursts=0、镜像==预载）"
    return 0
  fi
  return 1
}

neg_err dstalign "$SRC" "$(( DST + 8 ))"  "$LEN"                      "DST 非 32B 对齐" || { echo "RESULT: FAIL（负对照未发火）⇒ 闸门不可信"; exit 2; }
neg_err lenmult  "$SRC" "$DST"            "$(( LEN - ERR_LEN_MULT_OFF ))" "LEN 非 32 的整数倍（32-B 粒度是 C3.3 引入的契约；非 32 倍数必须于 CHK 态响亮 err 且零搬运）" || { echo "RESULT: FAIL（负对照未发火）⇒ 闸门不可信"; exit 2; }
neg_err lenzero  "$SRC" "$DST"            "0"                         "LEN == 0" || { echo "RESULT: FAIL（负对照未发火）⇒ 闸门不可信"; exit 2; }

# ---------------- 收口 ----------------
echo "MISMATCH=$MIS"
echo "J2: groups=$(( LEN / 32 )) cyc_per_group=$CPG（判据 <= 2）cyc_per_group_total=$CPGT（字面 CYC/groups，见下）"
echo "P3 运行期断言 = OK（AR/AW 地址各按 +128 递进；每笔 arlen/awlen=15；读写不重叠；写不领先读）"
echo "交叉对账 = OK（MEM rd/wr/bursts/maxburst 与装置自报相符；+DUMPFILE 与黄金镜像逐字节相同）"
echo "负对照 A[写地址平移] = 发火（MISMATCH=$MUTMIS>0，首个不符偏移 $MUTFIRST == DST）"
echo "负对照 B[单字节] = 发火（MISMATCH=$NBMIS 恰好 1，首个不符偏移 $NBFIRST == DST+$OFF_1BYTE）"
echo "负对照 C[err 路径] = 3/3 发火（dst 非对齐 / len 非 32 倍数 / len=0 各报 err 且零搬运）"
echo "比较器自检 = OK（扰动一个期望字节 ⇒ MISMATCH=1）"
echo "J2 喂给 predict_traffic.py 的数 = $CPG"
echo "J2 口径说明：cyc_per_group = (CYC - 搬运数据本身必走的拍数) / groups —— 它就是"
echo "  \"主口在从方之外**自己**加了几个 100 MHz 拍 / 每 32 B\"，判据 <= 2（= 主口侧 <= 20 ns/32 B）。"
echo "  字面的 CYC/groups = $CPGT 不可能 <= 2：一次拷贝对每个 32 B 要**读 4 拍 + 写 4 拍 = 8 拍**"
echo "  （8 B/拍、读写又不重叠），8 是地板；把地板算成\"开销\"会让判据恒红，不是判据想说的意思。"
echo "RESULT: PASS"
exit 0
