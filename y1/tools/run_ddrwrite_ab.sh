#!/usr/bin/env bash
# run_ddrwrite_ab.sh —— y1 AXI 主口的**写相位**字节级闸门（rtl/DdrMaster.scala + gen/DdrMaster.v）。
#
# ★ 契约变化（C2.1c）：主口现在**没有"纯写"这个操作**了 —— 一次 `start` 恒等于"把 src 上的
#   len 字节块拷到 dst"（每块 128 B，先整块读进块缓冲、再把该块整块写出去；非法入参 ⇒ err、
#   一字节不搬）。旧装置那套"先用一笔读把块缓冲灌好（dst=0），再发两笔纯写（src=0）"在新契约下
#   **本身就是非法入参**，所以本闸门改为发**两笔完整拷贝**：SRC1->DST，紧接着（背靠背）SRC2->DST2。
#   它盯的判据一条没少，且两处因契约变化必须改的地方都说清了理由：
#     · 旧 "纯读相位里 aw_bursts 必须仍是 0"（= 写请求只在写相位发）→ 换成**更直接**的运行期断言
#       `ORPHAN_W=0`：任何一拍举 W 之前必须有一笔**已被收下的 AW**挂着（`src/YeshenSocGlue.scala:764`
#       那条 ★ 约束 —— "W 必须与 AW 同门" —— 的运行期版本），外加每笔写突发恰好 16 拍且末拍
#       wlast=1（`WLAST_BAD=0`）。旧判据管的是"写请求别发早了"，新判据管的是同一件事且更靠下游。
#     · 旧的"块缓冲由读相位预置、两笔写共用同一份缓冲"→ 新契约下每笔拷贝各自读源、各自写目标，
#       于是背靠背那条改判成"**第二笔拷贝必须真的落地**"（DST2 区逐字节 = SRC2 的内容）。
#       抓的缺陷是同一个：**第二笔被吞掉**。
#
# 闸门（本脚本 + 内嵌 Python）做**独立**判据，不盲信装置的 PASS：
#   1) 把内存镜像（+DUMPFILE）与 Python **独立**算的期望**整片逐字节**对账，打印唯一一行 `MISMATCH=<n>`；
#   2) `AWB <addr> awlen=<n>`：AW 的地址序列必须恰好是 DST,DST+128,... 与 DST2,DST2+128,...
#      且**每一笔 awlen 都是 15**（P3 的运行期断言；静态断言另在 gen/DdrMaster.v 上做）；
#   3) `MEM rd=<bytes> wr=<bytes> bursts=<n> maxburst=<n>`：内存模型**独立**记的读/写字节数与
#      突发数必须与预期一致（两处独立计数一起对得上才算数）；
#   4) **反向方向**（不许写越界）：写区 [DST,DST+LEN) ∪ [DST2,DST2+LEN) **之外**的每一个字节，
#      都必须与预载文件逐字节相同（含紧邻 DST 之前、DST+LEN 之后的两段）；
#   5) **背靠背**：DST2 区必须真的被写成了 SRC2 的那一份内容（第二笔没被吞）。
#
# 三个作业：
#   作业 1 正向 —— 上述 1..5 全过；
#   作业 2 负对照 A（**网表突变**，不是测试钩子）—— 把 gen/DdrMaster.v 拷一份，把**一条 wstrb 位**
#     在某**一拍**上强置 0（每笔突发的第 0 拍、strb 的 bit0，`8'hFF` -> `8'hFE`），用同一装置重跑：
#     装置本身照旧 PASS（握手计数不变），但**字节对账必须抓到**（MISMATCH>0）—— 证明判据看的是
#     **字节**，不是"有没有发过一拍写"。
#   作业 3 负对照 B（背靠背）—— 见上 5)：两笔都要落地；若第二笔被吞（DST2 区仍是预载）⇒ 判据红。
#
# 退出码：
#   0 = 通过（逐字节相符 + AW 序列/awlen + 内存模型交叉 + 反向未越界 + 背靠背两笔都落地
#            + W-AW 同门 + wstrb 突变被抓住）
#   1 = 对账不符 / 编译或仿真失败 / 装置未 PASS / P3 不成立 / 背靠背第二笔被吞
#   2 = 负对照没发火（wstrb 突变没被字节判据抓到），或比较器自检不过 ⇒ **闸门自身不可信**
#
# 装置契约（rtl_test/DdrWriteTb.v）：+SRC1= +DST= +LEN= +SRC2= +DST2= +MEMFILE= +DUMPFILE=（十进制/路径）
set -uo pipefail

PY="${PY:-python}"
here="$(cd "$(dirname "$0")" && pwd)"
gen="$here/../gen"
tb="$here/../rtl_test/DdrWriteTb.v"
memv="$here/../rtl_test/AxiMemModel.v"
nl="$gen/DdrMaster.v"

MEMSZ=8192                 # 必须与 DdrWriteTb.v 里 AxiMemModel 的 MEMSZ 参数一致
SRC1=512                   # 第 1 笔拷贝的源（模式区）
DST=2048                   # 第 1 笔拷贝的目标
SRC2=1024                  # 第 2 笔拷贝的源（背靠背；与 SRC1 的内容**逐字节不同**）
DST2=3072                  # 第 2 笔拷贝的目标
LEN=512                    # 每笔拷贝 4 块 x 128 B

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

echo "== run_ddrwrite_ab: AXI 写相位 字节级写 + wstrb 网表突变与背靠背 两道负对照 =="
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

# ---------------- 0) 造激励：非平凡、**非块混叠**的模式 + Python 独立算的期望 ----------------
# 模式的**周期 = 251（素数，与块长 128 互素）**：
#   `pat(i) = ((i % 251) * 131 + 7) % 251`。131 与 251 互素 ⇒ 0..250 上是个**排列** ⇒ 任取 128 个
#   连续字节（= 一个块缓冲）都**两两不同**（非平凡）。周期 251 **不是 128 的倍数**（也不是其因数）：
#   于是把任一段 128 字节窗口整体平移**整数个块**（±128、±256…）都会**至少改变一个字节**（251 ∤ 128k,
#   k≠0）⇒ 写地址"整块偏一格"不可能被字节对账漏过。这正是 C2.1a 读任务踩过的坑的**反面**：
#   那里用 `(i*131+7)&0xFF`（周期 256 = 正好 2 个块）⇒ 第 k 块与第 k+2 块逐字节相同，整块平移对字节
#   比较**隐形**；本闸门把周期取成 251 就是为了让它**可见**（C2.1c 的块拷贝闸门同源）。
if ! "$PY" - "$work" "$MEMSZ" "$SRC1" "$DST" "$SRC2" "$DST2" "$LEN" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

work = sys.argv[1]
memsz, src1, dst, src2, dst2, ln = (int(x) for x in sys.argv[2:8])
PERIOD = 251                      # 素数，与块长 128 互素

def pat(i):
    return ((i % PERIOD) * 131 + 7) % PERIOD   # 周期恰好 251，值域 0..250，非平凡

def expected(i):
    """拷贝 1：SRC1 -> DST；拷贝 2：SRC2 -> DST2；其余 = 预载模式（源区不许被改）。"""
    if dst  <= i < dst + ln:  return pat(src1 + (i - dst))
    if dst2 <= i < dst2 + ln: return pat(src2 + (i - dst2))
    return pat(i)

assert ln % 128 == 0 and ln > 0, "LEN 必须是 128 的正整数倍"
assert src1 % 32 == 0 and dst % 32 == 0 and src2 % 32 == 0 and dst2 % 32 == 0, "地址必须 32B 对齐"
assert dst + ln <= memsz and dst2 + ln <= memsz and src1 + ln <= memsz and src2 + ln <= memsz, "越出已建模内存"
# 四个区间两两不重叠（源区不许被写，目标区不许被当成源）
def ov(a, b): return a < b + ln and b < a + ln
for a, b in ((src1, dst), (src1, dst2), (src2, dst), (src2, dst2), (dst, dst2)):
    assert not ov(a, b), "区间重叠: %d / %d" % (a, b)

# ---- 非混叠断言（闸门可信度的前提）----
assert len(set(pat(i) for i in range(PERIOD))) == PERIOD, "模式周期不是恰好 251"
for k in range(1, 17):
    assert all(pat(j) != pat(j + 128 * k) for j in range(0, 4 * PERIOD)), "模式对整块平移混叠 k=%d" % k
# 每一对"源 -> 目标"的相位差都不能是 251 的整数倍，否则该目标区**不写**也等于源内容
for s, d, tag in ((src1, dst, "SRC1->DST"), (src2, dst2, "SRC2->DST2"), (dst, dst2, "DST->DST2")):
    assert (d - s) % PERIOD != 0, "FATAL: %s 相位混叠（不写也能过关）" % tag
# 两笔拷贝的源内容必须逐字节不同 —— 否则"第二笔其实重放了第一笔的缓冲"会隐形
assert (src2 - src1) % PERIOD != 0, "FATAL: SRC1/SRC2 内容相同 ⇒ 背靠背判据分不清两笔"

with open(work + "/mem.hex", "w") as f:
    for i in range(memsz):
        f.write("%02x\n" % pat(i))
with open(work + "/exp.hex", "w") as f:
    for i in range(memsz):
        f.write("%02x\n" % expected(i))

# 期望的 AW 序列（两笔拷贝，每笔 awlen=15，地址每块 +128）
with open(work + "/exp_aw.txt", "w") as f:
    for k in range(ln // 128):
        f.write("%08x 15\n" % (dst + 128 * k))
    for k in range(ln // 128):
        f.write("%08x 15\n" % (dst2 + 128 * k))

uniq = len(set(pat(src1 + j) for j in range(128)))
assert uniq > 1, "FATAL: 块缓冲是全常数 ⇒ 判据没意义"
diff1 = sum(1 for j in range(ln) if pat(src1 + j) != pat(dst + j))
diff2 = sum(1 for j in range(ln) if pat(src2 + j) != pat(dst2 + j))
assert diff1 == ln and diff2 == ln, "FATAL: 目标区预载与源内容相同（%d/%d）⇒ 不写也能过" % (diff1, ln)

print("MEMGEN bytes=%d bufuniq=%d period=%d chunks_per_copy=%d copies=2" % (memsz, uniq, PERIOD, ln // 128))
print("NONALIAS: 周期恰 251；与 128 互素；整块平移可见；(DST-SRC1)%%251=%d (DST2-SRC2)%%251=%d (SRC2-SRC1)%%251=%d"
      % ((dst - src1) % PERIOD, (dst2 - src2) % PERIOD, (src2 - src1) % PERIOD))
PYEOF
then
  echo "FATAL: 生成内存/期望失败（或非混叠断言不成立）"; exit 1
fi
[ -s "$work/mem.hex" ] && [ -s "$work/exp.hex" ] && [ -s "$work/exp_aw.txt" ] || { echo "FATAL: 激励文件缺失"; exit 1; }

# ---------------- 1) 编译（好网表）----------------
if ! "$IVERILOG" -g2012 -o "$work/sim.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败（好网表）"; sed -n '1,40p' "$work/iv.log"; exit 1
fi
echo "---- iverilog 编译 OK（好网表）----"

run_sim() { # run_sim <vvp> <logbase>
  local vvp="$1" log="$2"
  ( cd "$work" && "$VVP" "$vvp" \
      "+SRC1=$SRC1" "+DST=$DST" "+LEN=$LEN" "+SRC2=$SRC2" "+DST2=$DST2" \
      "+MEMFILE=$work/mem.hex" "+DUMPFILE=$work/$log.dump" +dump > "$log" 2>&1 )
  return $?
}

# 判定器：整片字节对账 + AW 序列/awlen + 内存模型交叉 + 反向未越界 + 背靠背 + W-AW 同门。
# 用法: judge.py <exp.hex> <exp_aw.txt> <log> <dump> <mem.hex> <len> <dst> <dst2> <src2>
cat > "$work/judge.py" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

exp_file, aw_file, log_file, dump_file, mem_file = sys.argv[1:6]
ln, dst, dst2, src2 = (int(x) for x in sys.argv[6:10])
chunks = ln // 128

exp = [int(x, 16) for x in open(exp_file).read().split()]
pre = [int(x, 16) for x in open(mem_file).read().split()]
got = [int(x, 16) for x in open(dump_file).read().split()]

aw = []
memline = None
tb = {}
for line in open(log_file, errors="replace"):
    s = line.strip()
    if s.startswith("AWB "):
        p = s.split()
        aw.append((int(p[1], 16), int(p[2].split("=")[1])))
    elif s.startswith("MEM rd="):
        memline = s
    else:
        for p in s.split():
            if "=" in p:
                k, v = p.split("=", 1)
                if k in ("AW_BURSTS", "AR_BURSTS", "B_OK", "RD_BYTES1", "WR_BYTES1",
                         "WR_BYTES2", "ORPHAN_W", "WLAST_BAD", "ERR"):
                    try:
                        tb[k] = int(v)
                    except ValueError:
                        pass

bad = 0

# --- 1) 整片逐字节对账 ---
mis = abs(len(got) - len(exp))
if len(got) != len(exp):
    print("BYTECOUNT got=%d expect=%d" % (len(got), len(exp)))
for i in range(min(len(got), len(exp))):
    if got[i] != exp[i]:
        if mis < 8:
            print("BYTEDIFF idx=%d got=%02x expect=%02x" % (i, got[i], exp[i]))
        mis += 1
print("MISMATCH=%d" % mis)

# --- 2) AW 地址序列 + awlen（P3 运行期断言）---
exp_aw = [(int(t[0], 16), int(t[1])) for t in (l.split() for l in open(aw_file)) if t]
if aw != exp_aw:
    print("AWSEQ_BAD got=%s" % (" ".join("%08x/%d" % a for a in aw),))
    print("AWSEQ_BAD expect=%s" % (" ".join("%08x/%d" % a for a in exp_aw),))
    bad += 1
for a, l in aw:
    if l != 15:
        print("AWLEN_BAD addr=%08x awlen=%d" % (a, l)); bad += 1; break

# --- 3) 与内存模型的独立计数交叉对账（两笔拷贝各读 LEN、各写 LEN）---
if memline is None:
    print("MEMLINE_MISSING"); bad += 1
else:
    kv = dict(p.split("=") for p in memline.split()[1:])
    rd, wr, bur, mx = int(kv["rd"]), int(kv["wr"]), int(kv["bursts"]), int(kv["maxburst"])
    # 两笔拷贝：每笔 = chunks 笔 AR + chunks 笔 AW（块拷贝里每块读一次、写一次）
    exp_rd, exp_wr, exp_bur = 2 * ln, 2 * ln, 2 * 2 * chunks
    print("MEMCHECK rd=%d wr=%d bursts=%d maxburst=%d (expect rd=%d wr=%d bursts=%d maxburst=16)"
          % (rd, wr, bur, mx, exp_rd, exp_wr, exp_bur))
    if rd  != exp_rd:  print("MEMRD_BAD %d != %d" % (rd, exp_rd));  bad += 1
    if wr  != exp_wr:  print("MEMWR_BAD %d != %d" % (wr, exp_wr));  bad += 1
    if bur != exp_bur: print("MEMBURSTS_BAD %d != %d" % (bur, exp_bur)); bad += 1
    if mx  != 16:      print("MEMMAXBURST_BAD %d != 16" % mx);      bad += 1

# --- 4) 反向方向：写区之外的字节必须与预载逐字节相同（含紧邻两段）---
def in_write(i):
    return (dst <= i < dst + ln) or (dst2 <= i < dst2 + ln)
viol = 0
for i in range(min(len(got), len(pre))):
    if not in_write(i) and got[i] != pre[i]:
        if viol < 8:
            print("NEIGHBOR_DIFF idx=%d got=%02x preload=%02x" % (i, got[i], pre[i]))
        viol += 1
before = sum(1 for j in range(32) if got[dst - 32 + j] != pre[dst - 32 + j])
after  = sum(1 for j in range(32) if got[dst + ln + j] != pre[dst + ln + j])
if viol or before or after:
    print("NEIGHBOR_BAD total=%d before_dst=%d after_dstlen=%d" % (viol, before, after)); bad += 1
else:
    print("NEIGHBOR_OK 写区之外 %d 字节全部未动（before_dst/after_dstlen 各 32B 逐字节相同）"
          % (len(pre) - 2 * ln))

# --- 5) 背靠背：DST2 区必须真的被写成 **SRC2 的那一份内容**（第二笔没被吞）---
b2 = sum(1 for j in range(ln) if got[dst2 + j] != exp[dst2 + j])
buf2 = [exp[dst2 + j] for j in range(128)]
if b2 != 0:
    print("BACK2BACK_BAD DST2 区有 %d 字节与 SRC2 内容不符（第二笔疑似被吞）" % b2); bad += 1
else:
    print("BACK2BACK_OK DST2 区 %d 字节 = SRC2 的内容（第二笔写落地；首块 %s）"
          % (ln, " ".join("%02x" % b for b in buf2[:8])))

# --- 6) 装置自报的计数（独立交叉）+ W-AW 同门 ---
if tb.get("AW_BURSTS") != 2 * chunks: print("TBAW_BAD %s != %d" % (tb.get("AW_BURSTS"), 2 * chunks)); bad += 1
if tb.get("AR_BURSTS") != 2 * chunks: print("TBAR_BAD %s != %d" % (tb.get("AR_BURSTS"), 2 * chunks)); bad += 1
if tb.get("B_OK")      != 2 * chunks: print("TBBOK_BAD %s != %d" % (tb.get("B_OK"), 2 * chunks)); bad += 1
if tb.get("RD_BYTES1") != ln:         print("TBRD1_BAD %s != %d" % (tb.get("RD_BYTES1"), ln)); bad += 1
if tb.get("WR_BYTES1") != ln:         print("TBWR1_BAD %s != %d" % (tb.get("WR_BYTES1"), ln)); bad += 1
if tb.get("WR_BYTES2") != ln:         print("TBWR2_BAD %s != %d" % (tb.get("WR_BYTES2"), ln)); bad += 1
if tb.get("ORPHAN_W")  != 0:          print("TBORPHAN_BAD %s != 0（W 与 AW 不同门）" % (tb.get("ORPHAN_W"),)); bad += 1
if tb.get("WLAST_BAD") != 0:          print("TBWLAST_BAD %s != 0" % (tb.get("WLAST_BAD"),)); bad += 1
if tb.get("ERR", 1)    != 0:          print("TBERR_BAD %s != 0" % (tb.get("ERR"),)); bad += 1
print("TBCHECK AW_BURSTS=%s B_OK=%s ORPHAN_W=%s WLAST_BAD=%s WR_BYTES1=%s WR_BYTES2=%s"
      % (tb.get("AW_BURSTS"), tb.get("B_OK"), tb.get("ORPHAN_W"), tb.get("WLAST_BAD"),
         tb.get("WR_BYTES1"), tb.get("WR_BYTES2")))

print("JUDGE_EXTRA=%d" % bad)
sys.exit(1 if (mis != 0 or bad != 0) else 0)
PYEOF

# ===========================================================================
# 作业 1：正向 —— 两笔拷贝（第 2 笔背靠背）
# ===========================================================================
echo "---- 作业 1：正向 SRC1=$SRC1 DST=$DST LEN=$LEN，背靠背 SRC2=$SRC2 DST2=$DST2 ----"
run_sim sim.vvp main.log; RC=$?
if [ "$RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/main.log"; then
  echo "JUDGE-RED: 正向仿真未 PASS（vvp rc=$RC）"
  grep -E '^(RESULT|TBFAIL|TB-ERROR|MEM |AW_BURSTS|B_OK|WR_BYTES|ORPHAN_W|ERR=)' "$work/main.log" || true
  exit 1
fi

"$PY" "$work/judge.py" "$work/exp.hex" "$work/exp_aw.txt" "$work/main.log" "$work/main.log.dump" "$work/mem.hex" \
  "$LEN" "$DST" "$DST2" "$SRC2" > "$work/judge.out" 2>&1
JRC=$?
cat "$work/judge.out"
MIS="$(sed -n 's/^MISMATCH=\([0-9][0-9]*\)$/\1/p' "$work/judge.out" | tail -1)"
JX="$(sed -n 's/^JUDGE_EXTRA=\([0-9][0-9]*\)$/\1/p' "$work/judge.out" | tail -1)"
[ -n "$MIS" ] || MIS="-1"
[ -n "$JX" ]  || JX="-1"
if [ "$JRC" -ne 0 ] || [ "$MIS" != "0" ] || [ "$JX" != "0" ]; then
  echo "RESULT: FAIL（正相对账 MISMATCH=$MIS JUDGE_EXTRA=$JX）"
  exit 1
fi

# ---------------- 比较器自检：扰动一个期望字节 ⇒ MISMATCH 必须恰好 1 ----------------
# 不做这一步就分不清"真的逐字节相符"与"比较器把两边都读成空表也报 0"。
"$PY" - "$work" "$DST" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
work, dst = sys.argv[1], int(sys.argv[2])
lines = [l.strip() for l in open(work + "/exp.hex") if l.strip()]
idx = dst + 17
assert len(lines) > idx, "FATAL: 期望表太短，自检没意义"
lines[idx] = "%02x" % ((int(lines[idx], 16) ^ 0x01) & 0xFF)
open(work + "/exp_neg.hex", "w").write("\n".join(lines) + "\n")
print("CMP_SELFTEST_PERTURB idx=%d" % idx)
PYEOF

if ! "$PY" - "$work/exp_neg.hex" "$work/main.log.dump" > "$work/selftest.out" 2>&1 <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
exp = [int(x, 16) for x in open(sys.argv[1]).read().split()]
got = [int(x, 16) for x in open(sys.argv[2]).read().split()]
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
# 作业 2：负对照 A —— **网表突变**：把一条 wstrb 位在**一拍**上强置 0
#   做法：拷 gen/DdrMaster.v，把 `assign axi_w_payload_strb = 8'hff;` 改成
#         "(state==DdrState_W && wbi==0) ? 8'hfe : 8'hff" —— 即每笔突发的**第 0 拍**、strb 的**bit0**
#         被清 0（正好"一条 wstrb 位、一拍"）。用**同一装置**重跑：装置照旧 PASS（握手计数不变），
#         但**字节对账必须 MISMATCH>0** —— 证明判据盯的是字节，不是"发过写拍"。
# ===========================================================================
echo "---- 作业 2：负对照 A[wstrb 网表突变] 清 bit0 on beat0 ----"
if ! "$PY" - "$nl" "$work/DdrMaster_mut.v" > "$work/mutgen.out" 2>&1 <<'PYEOF'
import re
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
src = open(sys.argv[1], encoding="utf-8").read()
pat = r"assign axi_w_payload_strb = _zz_axi_w_payload_strb;"
rep = "assign axi_w_payload_strb = ((state == DdrState_W) && (wbi == 4'b0000)) ? 8'hfe : _zz_axi_w_payload_strb;"
new, n = re.subn(pat, rep, src)
print("MUTGEN_HITS=%d" % n)
if n != 1:
    sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(new)
PYEOF
then
  echo "RESULT: FAIL（无法构造 wstrb 突变网表）"; cat "$work/mutgen.out"
  exit 2
fi
cat "$work/mutgen.out"

if ! "$IVERILOG" -g2012 -o "$work/mut.vvp" "$tb" "$memv" "$work/DdrMaster_mut.v" > "$work/iv_mut.log" 2>&1; then
  echo "RESULT: FAIL（突变网表编译失败）⇒ 闸门不可信"; sed -n '1,40p' "$work/iv_mut.log"; exit 2
fi
run_sim mut.vvp mut.log; MRC=$?
if ! grep -q '^RESULT: PASS' "$work/mut.log"; then
  echo "RESULT: FAIL（突变网表下装置未 PASS：突变把主口改坏了，负对照不成立）"
  grep -E '^(RESULT|TBFAIL|MEM )' "$work/mut.log" || true
  exit 2
fi
MUTMIS="$("$PY" - "$work/exp.hex" "$work/mut.log.dump" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
exp = [int(x, 16) for x in open(sys.argv[1]).read().split()]
got = [int(x, 16) for x in open(sys.argv[2]).read().split()]
mis = abs(len(got) - len(exp))
for i in range(min(len(got), len(exp))):
    if got[i] != exp[i]:
        mis += 1
print(mis)
PYEOF
)"
echo "WSTRB_MUTANT MISMATCH=$MUTMIS（必须 > 0，否则字节判据是橡皮图章）"
if [ "${MUTMIS:-0}" -gt 0 ] 2>/dev/null; then
  echo "NEG_OK[wstrb]: 字节判据抓住了 wstrb 突变（MISMATCH=$MUTMIS；每笔拷贝被清掉的第 0 拍 = 4 个字节）"
else
  echo "RESULT: FAIL（wstrb 突变没被字节判据抓到）⇒ 闸门不可信"
  grep -E '^MEM ' "$work/mut.log" || true
  exit 2
fi

# ===========================================================================
# 作业 3 的判定已在作业 1 的 judge.py 里（BACK2BACK_OK / NEIGHBOR_OK）；这里只在收口复述。
# ===========================================================================
echo "---- 作业 3：背靠背 + 反向未越界（判据见上 BACK2BACK_OK / NEIGHBOR_OK）----"
grep -q '^BACK2BACK_OK' "$work/judge.out" || { echo "RESULT: FAIL（背靠背第二笔没落地）"; exit 1; }
grep -q '^NEIGHBOR_OK'  "$work/judge.out" || { echo "RESULT: FAIL（写越界：写区之外有字节被改）"; exit 1; }

# ---------------- 收口 ----------------
echo "MISMATCH=$MIS"
echo "P3 运行期断言 = OK（AW 地址按 +128 递进；每笔 awlen=15）"
echo "W-AW 同门 = OK（ORPHAN_W=0；每笔写突发恰好 16 拍且末拍 wlast=1）"
echo "交叉对账 = OK（MEM rd/wr/bursts/maxburst 与装置自报相符；+DUMPFILE 与期望逐字节相同）"
echo "背靠背 = OK（两笔拷贝都落地；DST 区 = SRC1 内容、DST2 区 = SRC2 内容，各 $LEN 字节）"
echo "反向未越界 = OK（写区之外全部字节 = 预载）"
echo "负对照 A[wstrb 突变] = 发火（MISMATCH=$MUTMIS>0）"
echo "比较器自检 = OK（扰动一个期望字节 ⇒ MISMATCH=1）"
echo "RESULT: PASS"
exit 0
