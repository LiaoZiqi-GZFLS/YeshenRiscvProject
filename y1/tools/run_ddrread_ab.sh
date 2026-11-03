#!/usr/bin/env bash
# run_ddrread_ab.sh —— y1 AXI 主口的**读相位**字节级闸门（rtl/DdrMaster.scala + gen/DdrMaster.v）。
#
# ★ 契约变化（C2.1c）：主口现在**没有"纯读"这个操作**了 —— 一次 `start` 恒等于"把 src 上的
#   len 字节块拷到 dst"（每块 128 B，先整块读进块缓冲、再把该块整块写出去；入参非法 ⇒ err、
#   一字节不搬）。所以本闸门如实驱动**一笔完整拷贝**（+SRC/+DST/+LEN），而它盯的仍是**读相位**
#   的证据。两处判据因契约变化必须改，改法与理由（**意图不减弱**）：
#     · 旧 `WRIDLE_OK`（awvalid/wvalid/bready 全程为 0 = "读操作不碰写通道"）**在新契约下不再成立**
#       （拷贝必然要写，写半边不可能一直不动）。换成**等价强度、且更贴近桥真实约束**的一条：
#       **读写不重叠** —— `RDWR_OVERLAP=0`（同一拍不并存 R 与 W 数据）、`ARAW_OVERLAP=0`
#       （同一拍不并存 AR 与 AW）、`AW_LEAD_MAX=0`（累计 AW 数任何时刻不超累计 AR 数
#       = 写相位绝不领先读相位；桥的 `DDR3Bridge.scala:191/192` 就是 awready/wready 互斥）。
#       旧判据管的是"读的时序不被写干扰"，新判据管的是同一件事且是运行期可观测的不变量。
#     · 旧 `DUMP_OK`（导出镜像与预载**整片**逐字节相同 = "读操作不改内存"）同样不再成立
#       （拷贝会在 dst 区写东西）。换成 `SRC_UNCHANGED`：导出镜像的**源区**
#       与预载逐字节相同 —— "读相位绝不往源里写"这一条一字不少。（整片对账归块拷贝闸门。）
#     同理 `MEM wr=0` 换成 `MEM wr == LEN`（写侧必须恰好写出被拷的那些字节，不多不少）。
#
# 三个作业（与 tools/run_hostregs_ab.sh / run_weightstore_ab.sh 同风格）：
#   1) 正向：内存预载**非平凡**模式 byte[i] = (i*131 + 7) & 0xFF（全 0 之类的平凡模式会让
#      "根本没搬"静默通过），让主口拷 [SRC, SRC+LEN) -> DST，把装置每块打出的 `RDBLK <hh> ...`
#      拼起来，与 Python **独立**算出的期望逐字节对账，打印唯一一行 `MISMATCH=<n>`。
#      另外三项独立交叉对账（不盲信装置的 PASS）：
#        · `ARB <addr> arlen=<n>`：AR 的地址序列必须恰好是 SRC, SRC+128, ...（每笔 +128），
#          且**每一笔 arlen 都是 15**（P3 的运行期断言；静态断言另在 gen/DdrMaster.v 上做）。
#        · `MEM rd=<bytes> bursts=<n> maxburst=<n>`：内存模型**独立**记的读字节数/突发数必须与
#          主口自报的 RD_BYTES / CHUNKS 一致 —— 两处独立计数一起对得上才算数；
#          并额外要求 `MEM wr == LEN`（写侧只写该写的）。
#        · `+DUMPFILE` 导出的镜像里**源区**必须与 `+MEMFILE` 预载逐字节相同（读相位没改源）。
#   2) 负对照 · 对齐/长度：把 +SRC 打成非 32B 对齐（1032），再把 +LEN 打成非 32 的倍数（100，
#      它自然也非 128 的倍数），两次都必须由**装置自己报 err**（+EXPECT_ERR），且**一个字节都没搬**
#      （无 RDBLK、MEM rd=0 wr=0）。这两条证明"入参非法 ⇒ 立刻 err"不是注释里的空话。
#      （dst 侧的对齐/长度负对照在块拷贝闸门里另有其一，这里只考 src/len。）
#   3) 负对照 · 超长：+SRC/+LEN 跨出**已建模内存**（SRC=8000 LEN=512，MEMSZ=8192）。
#      本闸门**明确选**"内存模型 \$fatal"这一种（而不是"装置报 err"），并**显式断言**
#      日志里出现 `AXI-MEM OUT-OF-RANGE` 且 vvp 非 0 —— 越界读**绝不允许**安静地过。
#
# 退出码：
#   0 = 通过（正向逐字节相符 + 三项交叉对账全过 + 读写不重叠 + 两道负对照都按预期发火）
#   1 = 对账不符 / 编译或仿真失败 / 装置未 PASS / P3（地址递进、arlen）不成立 / 源区被改
#   2 = 负对照没发火，或比较器自检不过 ⇒ **闸门自身不可信**（橡皮图章）
#
# 装置契约（rtl_test/DdrReadTb.v + rtl_test/AxiMemModel.v + gen/DdrMaster.v）：
#   +SRC=<dec> +DST=<dec> +LEN=<dec>   源/目标地址与字节数（十进制）。装置**不**替 DUT 校验。
#   +MEMFILE=<file>              $readmemh 一行一个十六进制字节；由 AxiMemModel 自己取。
#   +DUMPFILE=<file>             仿真结束时回写同一格式；由 AxiMemModel 自己取。
#   +EXPECT_ERR                  可选：断言本次必须报 err（负对照用）。
#   装置输出：`ARB <addr> arlen=<n>` / `RDBLK <hh> ...`（每块一行）/ `CHUNKS=` `BURSTS=`
#             `RDWR_OVERLAP= ARAW_OVERLAP= AW_LEAD_MAX=` / `RDWR_EXCL_OK`
#             `CYC=.. RD_BYTES=.. WR_BYTES=.. ERR=..` / `RESULT: PASS|FAIL`（FAIL 时 \$fatal ⇒ vvp 非 0）。
#   内存模型输出：末尾 `MEM rd=<bytes> wr=<bytes> bursts=<n> maxburst=<n>`。
#   冻结形状（P1/P3）：数据 64 bit / id 4 bit / wstrb 8 bit；单 outstanding；每笔突发 16 拍 = 128 B。
set -uo pipefail

PY="${PY:-python}"
here="$(cd "$(dirname "$0")" && pwd)"
gen="$here/../gen"
tb="$here/../rtl_test/DdrReadTb.v"
memv="$here/../rtl_test/AxiMemModel.v"
nl="$gen/DdrMaster.v"

MEMSZ=8192                 # 必须与 DdrReadTb.v 里 AxiMemModel 的 MEMSZ 参数一致
SRC_OK=1024
DST_OK=2176                # 新契约要 dst：32B 对齐、与源区不重叠，且 (DST-SRC)%256!=0（见生成器里的非混叠断言）
LEN_OK=512                 # 4 块 x 128 B
SRC_BAD_ALIGN=1032         # 1032 % 32 == 8 ⇒ 非 32B 对齐
LEN_BAD_MULT=100           # 100 % 32 == 4  ⇒ 非 32 的倍数（自然也不是 128 的倍数）
SRC_OOL=8000               # 8000 % 32 == 0（合法），但 8000+512 > 8192 ⇒ 越界
LEN_OOL=512

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
find_tool() { # <name>
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

echo "== run_ddrread_ab: AXI 读相位 字节级读回（装置驱动一笔完整拷贝）+ 对齐/长度与超长 两道负对照 =="
echo "   tb  =$tb"
echo "   mem =$memv"
echo "   nl  =$nl"
echo "   iverilog=${IVERILOG:-<找不到>}  vvp=${VVP:-<找不到>}"
echo "   tmp =$work"

# ---------------- 前置检查 ----------------
if [ ! -f "$nl" ]; then
  echo "FATAL: 找不到网表 $nl"
  echo "       先生成: cd y1 && printf 'Test/runMain DdrMasterGen D:/code/PDS/VexiiYeshenLinux/y1/gen\\nexit\\n' | bash sbt.sh"
  exit 1
fi
if [ ! -f "$tb" ];   then echo "FATAL: 找不到装置 $tb";       exit 1; fi
if [ ! -f "$memv" ]; then echo "FATAL: 找不到内存模型 $memv"; exit 1; fi
if [ -z "$IVERILOG" ] || [ -z "$VVP" ]; then echo "FATAL: 找不到 iverilog / vvp"; exit 1; fi

# ---------------- 0) 造激励：非平凡模式 + Python 独立算的期望 ----------------
if ! "$PY" - "$work" "$MEMSZ" "$SRC_OK" "$DST_OK" "$LEN_OK" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

work = sys.argv[1]
memsz, src, dst, ln = (int(x) for x in sys.argv[2:6])

def byte(i):
    return (i * 131 + 7) & 0xFF

with open(work + "/mem.hex", "w") as f:
    for i in range(memsz):
        f.write("%02x\n" % byte(i))

# 期望：读区间 [src, src+len) 的字节，按地址升序（每块 128 B，块内也是地址升序）
assert ln % 128 == 0, "正向用例的长度必须是 128 的整数倍（块粒度）"
assert src % 32 == 0 and dst % 32 == 0, "正向用例的源/目标地址必须 32B 对齐"
assert src + ln <= dst or dst + ln <= src, "源区与目标区不得重叠"
assert max(src + ln, dst + ln) <= memsz, "越出已建模内存"
# 非混叠断言：本闸门的模式周期是 256（= 2 个块）⇒ 若 (dst-src) 是 256 的整数倍，
# dst 区的预载就会**逐字节等于**源内容，"原地不动"在这一对上会隐形。这里把它钉成断言。
assert (dst - src) % 256 != 0, "FATAL: (DST-SRC) 是 256 的整数倍 ⇒ 模式在 src/dst 这一对上混叠"
with open(work + "/exp.hex", "w") as f:
    for i in range(src, src + ln):
        f.write("%02x\n" % byte(i))

with open(work + "/exp_ar.txt", "w") as f:
    for k in range(ln // 128):
        f.write("%08x 15\n" % (src + 128 * k))

# 自检：期望不能是平凡模式（否则"没搬"也会通过）
uniq = len(set(byte(i) for i in range(src, src + ln)))
assert uniq > 1, "FATAL: 期望是全常数 ⇒ 判据没意义"
print("MEMGEN bytes=%d exp=%d uniq=%d chunks=%d (DST-SRC)%%256=%d"
      % (memsz, ln, uniq, ln // 128, (dst - src) % 256))
PYEOF
then
  echo "FATAL: 生成内存/期望失败"; exit 1
fi
[ -s "$work/mem.hex" ] && [ -s "$work/exp.hex" ] && [ -s "$work/exp_ar.txt" ] || { echo "FATAL: 激励文件缺失"; exit 1; }

# ---------------- 1) 编译 ----------------
if ! "$IVERILOG" -g2012 -o "$work/sim.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败"; sed -n '1,40p' "$work/iv.log"; exit 1
fi
echo "---- iverilog 编译 OK ----"

# 跑一次仿真。用法: run_sim <log> <src> <dst> <len> [extra plusargs...]
run_sim() {
  local log="$1" s="$2" d="$3" l="$4"; shift 4
  ( cd "$work" && "$VVP" sim.vvp "+SRC=$s" "+DST=$d" "+LEN=$l" \
      "+MEMFILE=$work/mem.hex" "+DUMPFILE=$work/$log.dump" +dump "$@" > "$log" 2>&1 )
  return $?
}

# 判定器：正向对账（逐字节 + AR 序列/arlen + 与内存模型交叉 + 镜像）。用法见文件内 sys.argv。
cat > "$work/judge1.py" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

exp_file, ar_file, log_file, memb, dumpf = sys.argv[1:6]
ln = int(sys.argv[6])
src = int(sys.argv[7])

exp = [int(x, 16) for x in open(exp_file).read().split()]

got = []
ar = []
chunks_sim = None
bursts_sim = None
wr_bursts_sim = None
overlaps = None
memline = None
for line in open(log_file, errors="replace"):
    s = line.strip()
    if s.startswith("RDBLK"):
        got += [int(x, 16) for x in s.split()[1:]]
    elif s.startswith("ARB "):
        p = s.split()
        ar.append((int(p[1], 16), int(p[2].split("=")[1])))
    elif s.startswith("CHUNKS="):
        chunks_sim = int(s.split("=")[1])
    elif s.startswith("BURSTS="):
        bursts_sim = int(s.split("=")[1])
    elif s.startswith("WR_BURSTS="):
        wr_bursts_sim = int(s.split("=")[1])
    elif s.startswith("RDWR_OVERLAP="):
        overlaps = s
    elif s.startswith("MEM rd="):
        memline = s

bad = 0

# --- 1a) 逐字节对账 ---
mis = 0
if len(got) != len(exp):
    mis += abs(len(got) - len(exp))
    print("BYTECOUNT got=%d expect=%d" % (len(got), len(exp)))
for i in range(min(len(got), len(exp))):
    if got[i] != exp[i]:
        if mis < 8:
            print("BYTEDIFF idx=%d got=%02x expect=%02x" % (i, got[i], exp[i]))
        mis += 1
print("MISMATCH=%d" % mis)

chunks = ln // 128

# --- 1b) AR 地址序列 + arlen（P3 运行期断言）---
exp_ar = [(int(t[0], 16), int(t[1])) for t in (l.split() for l in open(ar_file)) if t]
if ar != exp_ar:
    print("ARSEQ_BAD got=%s" % (" ".join("%08x/%d" % a for a in ar),))
    print("ARSEQ_BAD expect=%s" % (" ".join("%08x/%d" % a for a in exp_ar),))
    bad += 1
for a, l in ar:
    if l != 15:
        print("ARLEN_BAD addr=%08x arlen=%d" % (a, l)); bad += 1; break

# --- 1c) 与内存模型的独立计数交叉对账（wr 现在必须是 LEN：拷贝一定写满）---
if memline is None:
    print("MEMLINE_MISSING"); bad += 1
else:
    kv = dict(p.split("=") for p in memline.split()[1:])
    rd, bur, mx, wr = int(kv["rd"]), int(kv["bursts"]), int(kv["maxburst"]), int(kv["wr"])
    print("MEMCHECK rd=%d wr=%d bursts=%d maxburst=%d (expect rd=%d wr=%d bursts=%d maxburst=16)"
          % (rd, wr, bur, mx, ln, ln, 2 * chunks))
    if rd != ln:      print("MEMRD_BAD %d != %d" % (rd, ln)); bad += 1
    if wr != ln:      print("MEMWR_BAD %d != %d（拷贝必须恰好写出 len 字节）" % (wr, ln)); bad += 1
    if bur != 2 * chunks: print("MEMBURSTS_BAD %d != %d" % (bur, 2 * chunks)); bad += 1
    if mx != 16:      print("MEMMAXBURST_BAD %d != 16" % mx); bad += 1
if chunks_sim != chunks: print("CHUNKS_BAD %s != %d" % (chunks_sim, chunks)); bad += 1
if bursts_sim != chunks: print("BURSTS_BAD %s != %d" % (bursts_sim, chunks)); bad += 1
if wr_bursts_sim != chunks: print("WRBURSTS_BAD %s != %d" % (wr_bursts_sim, chunks)); bad += 1

# --- 1c2) 读写不重叠（替代旧的"写半边从不举手"；见脚本头）---
if overlaps != "RDWR_OVERLAP=0 ARAW_OVERLAP=0 AW_LEAD_MAX=0":
    print("OVERLAP_BAD %s" % overlaps); bad += 1
else:
    print("OVERLAP_OK %s" % overlaps)

# --- 1d) 源区必须没被改（替代旧的"整片镜像 == 预载"；见脚本头）---
try:
    a = open(memb, "rb").read()
    b = open(dumpf, "rb").read()
    if len(a) != len(b):
        print("DUMP_SIZE_BAD %d vs %d" % (len(a), len(b))); bad += 1
    else:
        sdiff = 0
        for i in range(src, src + ln):
            if a[i] != b[i]:
                sdiff += 1
        print("SRC_UNCHANGED diff=%d (%d bytes checked)" % (sdiff, ln))
        if sdiff != 0:
            print("SRC_CHANGED_BAD 源区里有 %d 个字节被改了 ⇒ 读相位写进了源" % sdiff); bad += 1
except OSError as e:
    print("DUMP_MISSING %s" % e); bad += 1

print("JUDGE_EXTRA=%d" % bad)
sys.exit(1 if (mis != 0 or bad != 0) else 0)
PYEOF

# ===========================================================================
# 作业 1：正向 —— 逐字节对账 + 三项交叉对账
# ===========================================================================
echo "---- 作业 1：正向 SRC=$SRC_OK DST=$DST_OK LEN=$LEN_OK ----"
run_sim main.log "$SRC_OK" "$DST_OK" "$LEN_OK"; RC=$?
if [ "$RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/main.log"; then
  echo "JUDGE-RED: 正向仿真未 PASS（vvp rc=$RC）"
  grep -E '^(RESULT|TBFAIL|TB-ERROR)' "$work/main.log" || true
  exit 1
fi
if ! grep -q '^RDWR_EXCL_OK' "$work/main.log"; then
  echo "JUDGE-RED: 读写不重叠不成立（R/W 同拍、或 AR/AW 同拍、或 AW 领先 AR）"
  grep '^TBFAIL' "$work/main.log" || true
  exit 1
fi

"$PY" "$work/judge1.py" "$work/exp.hex" "$work/exp_ar.txt" "$work/main.log" "$work/mem.hex" "$work/main.log.dump" "$LEN_OK" "$SRC_OK" \
  > "$work/judge1.out" 2>&1
JRC=$?
cat "$work/judge1.out"
MIS="$(sed -n 's/^MISMATCH=\([0-9][0-9]*\)$/\1/p' "$work/judge1.out" | tail -1)"
JX="$(sed -n 's/^JUDGE_EXTRA=\([0-9][0-9]*\)$/\1/p' "$work/judge1.out" | tail -1)"
[ -n "$MIS" ] || MIS="-1"
[ -n "$JX" ]  || JX="-1"
if [ "$JRC" -ne 0 ] || [ "$MIS" != "0" ] || [ "$JX" != "0" ]; then
  echo "RESULT: FAIL（正相对账 MISMATCH=$MIS JUDGE_EXTRA=$JX）"
  exit 1
fi

# ---------------- 比较器自检：扰动一个期望字节 ⇒ MISMATCH 必须恰好 1 ----------------
# 不做这一步就分不清"真的逐字节相符"与"比较器把两边都读成空表也报 0"。
"$PY" - "$work" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
work = sys.argv[1]
lines = [l.strip() for l in open(work + "/exp.hex") if l.strip()]
assert len(lines) > 20, "FATAL: 期望表太短，自检没意义"
lines[17] = "%02x" % ((int(lines[17], 16) ^ 0x01) & 0xFF)
open(work + "/exp_neg.hex", "w").write("\n".join(lines) + "\n")
print("CMP_SELFTEST_PERTURB idx=17")
PYEOF

if ! "$PY" - "$work/exp_neg.hex" "$work/main.log" > "$work/selftest.out" 2>&1 <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
exp = [int(x, 16) for x in open(sys.argv[1]).read().split()]
got = []
for line in open(sys.argv[2], errors="replace"):
    t = line.split()
    if t and t[0] == "RDBLK":
        got += [int(x, 16) for x in t[1:]]
mis = abs(len(got) - len(exp))
for i in range(min(len(got), len(exp))):
    if got[i] != exp[i]:
        mis += 1
print("MISMATCH=%d" % mis)
sys.exit(0 if mis == 1 else 1)
PYEOF
then
  echo "RESULT: FAIL（比较器自检不过：扰动一个期望字节后 MISMATCH 不是恰好 1）"
  cat "$work/selftest.out"
  exit 2
fi
SELFMIS="$(sed -n 's/^MISMATCH=\([0-9][0-9]*\)$/\1/p' "$work/selftest.out" | tail -1)"
echo "CMP_SELFTEST MISMATCH=$SELFMIS（期望恰好 1）"
if [ "$SELFMIS" != "1" ]; then
  echo "RESULT: FAIL（比较器自检 MISMATCH=$SELFMIS != 1）⇒ 闸门不可信"
  exit 2
fi

# ===========================================================================
# 作业 2：负对照 —— 对齐 / 长度非法 ⇒ 装置必须自己报 err，且一个字节都不搬
# ===========================================================================
neg_err() { # <tag> <src> <dst> <len> <说明>
  local tag="$1" s="$2" d="$3" l="$4" why="$5" log="$1.log" ok=1
  echo "---- 作业 2：负对照[$tag] $why (SRC=$s DST=$d LEN=$l) ----"
  run_sim "$log" "$s" "$d" "$l" +EXPECT_ERR
  if ! grep -q '^RESULT: PASS' "$work/$log"; then
    echo "NEG_RED[$tag]: 装置没按预期报 err"
    grep -E '^(RESULT|CHUNKS|CYC|DONE_SEEN)' "$work/$log" || true
    ok=0
  fi
  grep -q '^CYC=.* ERR=1' "$work/$log"        || { echo "NEG_RED[$tag]: 日志里没有 ERR=1"; ok=0; }
  grep -q '^CHUNKS=0$' "$work/$log"           || { echo "NEG_RED[$tag]: CHUNKS 非 0（搬了东西）"; ok=0; }
  grep -q '^BURSTS=0$' "$work/$log"           || { echo "NEG_RED[$tag]: 竟然发起过突发"; ok=0; }
  grep -q '^WR_BURSTS=0$' "$work/$log"        || { echo "NEG_RED[$tag]: 竟然发起过写突发"; ok=0; }
  if grep -q '^RDBLK' "$work/$log"; then echo "NEG_RED[$tag]: 竟然打出了 RDBLK（搬了数据）"; ok=0; fi
  grep -q '^MEM rd=0 wr=0 bursts=0' "$work/$log" || { echo "NEG_RED[$tag]: 内存模型记的读数/突发数不为 0"; ok=0; }
  if [ "$ok" = "1" ]; then
    echo "NEG_OK[$tag]: 装置报 err 且零搬运（CHUNKS=0 / BURSTS=WR_BURSTS=0 / 无 RDBLK / MEM rd=wr=0）"
    return 0
  fi
  return 1
}

neg_err align  "$SRC_BAD_ALIGN" "$DST_OK" "$LEN_OK"       "SRC 非 32B 对齐"    || { echo "RESULT: FAIL（负对照未发火）⇒ 闸门不可信"; exit 2; }
neg_err lenmul "$SRC_OK" "$DST_OK"        "$LEN_BAD_MULT" "LEN 非 32 的整数倍" || { echo "RESULT: FAIL（负对照未发火）⇒ 闸门不可信"; exit 2; }

# ===========================================================================
# 作业 3：负对照 —— 越界（超长）⇒ 内存模型必须 $fatal（本闸门选定的那一种）
# ===========================================================================
echo "---- 作业 3：负对照[oob] 越出已建模内存 (SRC=$SRC_OOL LEN=$LEN_OOL, MEMSZ=$MEMSZ) ----"
run_sim oob.log "$SRC_OOL" "$DST_OK" "$LEN_OOL"; RC=$?
if grep -q 'AXI-MEM OUT-OF-RANGE' "$work/oob.log"; then
  echo "NEG_OK[oob]: 内存模型按预期 fatal（AXI-MEM OUT-OF-RANGE），vvp rc=$RC"
  if [ "$RC" -eq 0 ]; then
    echo "RESULT: FAIL（报出了 fatal 但 vvp 退出码为 0 ⇒ 不能当『响亮失败』用）"
    exit 2
  fi
else
  echo "NEG_RED[oob]: 越界读没有让内存模型发火（vvp rc=$RC）"
  grep -E '^(RESULT|CHUNKS|BURSTS|CYC|DONE_SEEN|MEM )' "$work/oob.log" || true
  echo "RESULT: FAIL（越界读安静地过了）⇒ 闸门不可信"
  exit 2
fi

# ---------------- 收口 ----------------
echo "MISMATCH=$MIS"
echo "P3 运行期断言 = OK（AR 地址按 +128 递进；每笔 arlen=15）"
echo "读写不重叠 = OK（同一拍无 R+W 数据、无 AR+AW；累计 AW 始终不领先 AR）"
echo "交叉对账 = OK（MEM rd/wr/bursts/maxburst 与 RD_BYTES/CHUNKS/WR_BURSTS 相符；导出镜像的源区与预载逐字节相同）"
echo "负对照 = 2/2 发火（对齐 SRC=$SRC_BAD_ALIGN、长度倍数 LEN=$LEN_BAD_MULT 各报 err 且零搬运；越界 $SRC_OOL+$LEN_OOL 让内存模型 fatal）"
echo "比较器自检 = OK（扰动一个期望字节 ⇒ MISMATCH=1）"
echo "RESULT: PASS"
exit 0
