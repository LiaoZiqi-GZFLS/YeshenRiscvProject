#!/usr/bin/env bash
# run_nputop_ab.sh —— y1「主机寄存器层 + DDR 块拷贝主口」集成体（rtl/NpuTop.scala + gen/NpuTop.v）
#                     的**端到端可编程块拷贝**闸门（主机写寄存器 -> 拷贝发生 -> 字节精确 -> done + IRQ）。
#
# 交付物（本闸门要证的那条链，缺一不可）：
#   主机 AxiLite4 写 SRC_ADDR/DST_ADDR/IMG_W/IMG_H/C_IN -> 写 CTRL.start
#     -> NpuTop 从特征图维度派生 len = IMG_W*IMG_H*C_IN 并驱动 DdrMaster
#       -> 主口在 DDR 上把 src 的 len 字节块拷到 dst
#         -> 主机轮询 STATUS 看到 done；顶层 irq 抬起（电平，直到 soft_reset 确认）。
#
# 长度口径（本集成契约；寄存器表**没有**长度寄存器）：len = IMG_W x IMG_H x C_IN（int8）。
#   不合法（0 / 非 128 的整数倍 / 溢出 32 位）时 NpuTop 驱动 len=0 -> 主口在 CHK 态报 err 且
#   一字节不搬；NpuTop 把该 err 锁成粘滞电平喂 sched_err -> STATUS.bit1，主机轮询必看到。
#
# 作业（1 正 + 1 比较器自检 + 2 负）：
#   作业 1 正向 —— 预载**非平凡、且对"整块平移"不混叠**的模式（周期 251，与块长 128 互素），
#     用 IMG_W=256 IMG_H=64 C_IN=8 => len=131072（128 的整数倍）编程一次拷贝。等 STATUS.done 后：
#       · 导出镜像与 Python 独立算的黄金镜像**整片逐字节**对账，打印唯一一行 `MISMATCH=<n>` 与
#         首个不符偏移 `FIRST_OFF=<n>`，并把三个区域各自点名：
#           `DST_EQ_SRC_BAD=0`（dst 区 == **原地** src 区）、
#           `SRC_UNCHANGED_BAD=0`（src 区 == 预载）、
#           `NEIGHBOR_BAD=0`（dst 区之外全部 == 预载，含紧邻 dst 前后 32 B）；
#       · IRQ 纪律：`PRE_IRQ=0`（启动前不举）、`POST_IRQ=1`（完成后举）、`IRQ_AFTER_ACK=0`
#         （写 soft_reset 后落下 ⇒ 不是卡死在高）、`IRQ_RISES=1` 且 `IRQ_HIGH_CYCLES>=50`
#         （保持电平，不是单拍脉冲 —— 电平敏感的 PLIC 才看得见）；
#       · 与内存模型交叉对账：`MEM rd=len wr=len bursts=2*chunks maxburst=16`。
#   作业 2 比较器自检 —— 扰动黄金镜像里一个期望字节 ⇒ MISMATCH 必须**恰好 1**。
#   作业 3 负对照 A（**非法长度**）—— IMG_W=250 IMG_H=3 C_IN=1 => 750（不是 128 的整数倍）。
#     必须由**主机**经 STATUS 观察到 err（STATUS_POST bit1=1），且**零搬运**：内存模型
#     `MEM rd=0 wr=0 bursts=0`、镜像与预载逐字节相同、无 done。
#   作业 4 负对照 B（**网表突变**）—— 把 gen/NpuTop.v 里派生的 len 整条 +128 再重跑：TB 照旧
#     PASS（握手没问题），但字节对账**必须**报 MISMATCH>0（尾部邻居被多写的 128 B 污染）。
#     这条证明闸门不是橡皮图章。
#
# 退出码：
#   0 = 通过（整片逐字节相符 + 三区域干净 + IRQ 纪律成立 + 两道负对照都发火 + 自检过）
#   1 = 对账不符 / 编译或仿真失败 / 装置未 PASS / IRQ 纪律不成立
#   2 = 负对照没发火，或模式/比较器自检不过 ⇒ **闸门自身不可信**
#
# 装置契约（rtl_test/NpuTopTb.v + rtl_test/AxiMemModel.v + gen/NpuTop.v）：
#   +SRC= +DST= +IMG_W= +IMG_H= +C_IN=（十进制） +MEMFILE= +DUMPFILE=（模型自己取） +EXPECT_ERR（可选）
#   装置输出：ID_READ / STATUS_PRE / CTRL_PRE / PRE_IRQ= / RB_OK / DONE_SEEN= / ERR_SEEN= /
#             STATUS_POST / CTRL_POST / POST_IRQ= / IRQ_HELD_AFTER_50= / IRQ_AFTER_ACK= /
#             STATUS_AFTER_ACK / IRQ_HIGH_CYCLES= / IRQ_RISES= / `RESULT: PASS|FAIL`
#   内存模型输出：末尾 `MEM rd=<bytes> wr=<bytes> bursts=<n> maxburst=<n>`
set -uo pipefail

PY="${PY:-python}"
here="$(cd "$(dirname "$0")" && pwd)"
gen="$here/../gen"
tb="$here/../rtl_test/NpuTopTb.v"
memv="$here/../rtl_test/AxiMemModel.v"
nl="$gen/NpuTop.v"

# ---- 用例常量（MEMSZ 必须与 rtl_test/NpuTopTb.v 里 AxiMemModel 的 MEMSZ 一致）----
MEMSZ=786432              # 768 KiB：容得下 src 区 + dst 区 + 前后邻居
SRC=131072                # 0x20000，32B 对齐
DST=393216                # 0x60000，32B 对齐；与 src 区不重叠
IMG_W=256
IMG_H=64
C_IN=8
LEN=$(( IMG_W * IMG_H * C_IN ))   # = 131072（128 的整数倍）
PERIOD=251                # 模式周期：素数，与块长 128 互素
NEG_IMG_W=250             # 非法长度负对照：250*3*1 = 750（不是 128 的整数倍）
NEG_IMG_H=3
NEG_C_IN=1
NEG_LEN=$(( NEG_IMG_W * NEG_IMG_H * NEG_C_IN ))

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

echo "== run_nputop_ab: NpuTop 集成（HostRegs+DdrMaster+IRQ）端到端可编程块拷贝 =="
echo "   tb  =$tb"
echo "   mem =$memv"
echo "   nl  =$nl"
echo "   iverilog=${IVERILOG:-<找不到>}  vvp=${VVP:-<找不到>}"
echo "   tmp =$work"
echo "   正用例 IMG_W=$IMG_W IMG_H=$IMG_H C_IN=$C_IN => LEN=$LEN (MEMSZ=$MEMSZ SRC=$SRC DST=$DST PERIOD=$PERIOD)"
echo "   负用例 A IMG_W=$NEG_IMG_W IMG_H=$NEG_IMG_H C_IN=$NEG_C_IN => LEN=$NEG_LEN（不是 128 的整数倍）"

# ---------------- 前置检查 ----------------
if [ ! -f "$nl" ]; then
  echo "FATAL: 找不到网表 $nl"
  echo "       先生成: cd y1 && printf 'Test/runMain NpuTopGen D:/code/PDS/VexiiYeshenLinux/y1/gen\\nexit\\n' | bash sbt.sh"
  exit 1
fi
if [ ! -f "$tb" ];   then echo "FATAL: 找不到装置 $tb";       exit 1; fi
if [ ! -f "$memv" ]; then echo "FATAL: 找不到内存模型 $memv"; exit 1; fi
if [ -z "$IVERILOG" ] || [ -z "$VVP" ]; then echo "FATAL: 找不到 iverilog / vvp"; exit 1; fi

# ---------------- 0) 造激励：非平凡 + **非块混叠**模式；Python 独立算黄金镜像 ----------------
if ! "$PY" - "$work" "$MEMSZ" "$SRC" "$DST" "$LEN" "$PERIOD" "$NEG_LEN" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

work = sys.argv[1]
memsz, src, dst, ln, period, neglen = (int(x) for x in sys.argv[2:8])

def pat(i):
    """周期恰好 = period（251）的模式。`(i%251)*131+7` 再 %251：131 与 251 互素 ⇒ 在 0..250 上
    是个**排列**（周期恰 251，不是它的某个因数），任取 128 个连续字节都两两不同（非平凡）。"""
    return ((i % period) * 131 + 7) % period

# ---------------- 非混叠断言（闸门可信度的前提；不成立就直接红，不许"先跑再说"）----------------
assert len(set(pat(i) for i in range(period))) == period, "FATAL: 模式周期不是恰好 %d" % period
assert period % 128 != 0 and 128 % period != 0, "FATAL: 模式周期与块长不互素"
for k in range(1, 17):
    assert all(pat(j) != pat(j + 128 * k) for j in range(0, 4 * period)), \
        "FATAL: 模式对整块平移混叠 k=%d" % k
assert (dst - src) % period != 0, "FATAL: src/dst 相位对混叠 => 不拷贝也能过字节对账"

# ---------------- 结构自检 ----------------
assert src % 32 == 0 and dst % 32 == 0, "FATAL: 地址必须 32B 对齐"
assert ln % 128 == 0 and ln > 0, "FATAL: 长度必须是 128 的正整数倍"
assert src + ln <= dst or dst + ln <= src, "FATAL: src/dst 区重叠（本用例要求不重叠）"
assert max(src + ln, dst + ln) <= memsz, "FATAL: 越出已建模内存"
assert min(src, dst) >= 128, "FATAL: 前面要留出邻居字节"
assert memsz - (dst + ln) >= 128, "FATAL: 后面要留出邻居字节"
# 负对照 A 的长度必须**确实**不是 128 的整数倍（否则那道负对照根本没发火的机会）
assert neglen % 128 != 0, "FATAL: 负对照 A 的长度 %d 竟是 128 的整数倍 => 用例无效" % neglen

pre = bytes(pat(i) for i in range(memsz))
with open(work + "/mem.hex", "w") as f:
    for b in pre:
        f.write("%02x\n" % b)

# 黄金镜像 = 预载，但 dst 区换成 src 区的**内容**（= 拷贝正确的样子）。
golden = pre[:dst] + pre[src:src + ln] + pre[dst + ln:]
with open(work + "/exp.hex", "w") as f:
    for b in golden:
        f.write("%02x\n" % b)

# 自检：源窗口非平凡，且 dst 区**确实**与预载不同
uniq = len(set(pre[src:src + 128]))
assert uniq > 1, "FATAL: 源窗口是常数 => 判据没意义"
diff_pre = sum(1 for j in range(ln) if pre[src + j] != pre[dst + j])
assert diff_pre == ln, "FATAL: dst 区预载与源内容逐字节相同（%d/%d）=> 不拷贝也能过" % (diff_pre, ln)

print("MEMGEN bytes=%d chunks=%d uniq128=%d dst_vs_preload_diff=%d period=%d"
      % (memsz, ln // 128, uniq, diff_pre, period))
print("NONALIAS: 周期恰 %d；与 128 互素；整块平移 k=1..16 每字节都变；(DST-SRC)%%%d=%d!=0"
      % (period, period, (dst - src) % period))
print("NEGLEN_CHECK neglen=%d neglen%%128=%d (!=0)" % (neglen, neglen % 128))
PYEOF
then
  echo "FATAL: 生成内存/黄金镜像失败（或非混叠断言不成立）⇒ 闸门不可信"
  exit 2
fi
[ -s "$work/mem.hex" ] && [ -s "$work/exp.hex" ] || { echo "FATAL: 激励文件缺失"; exit 1; }

# ---------------- 1) 编译（好网表）----------------
if ! "$IVERILOG" -g2012 -o "$work/sim.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败（好网表）"; sed -n '1,40p' "$work/iv.log"; exit 1
fi
echo "---- iverilog 编译 OK（好网表）----"

# 逐字节比较的公共实现
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

# 跑一次仿真。用法: run_sim <logbase> <src> <dst> <imgw> <imgh> <cin> [extra plusargs...]
run_sim() {
  local log="$1" s="$2" d="$3" iw="$4" ih="$5" ic="$6"; shift 6
  ( cd "$work" && "$VVP" "$work/sim.vvp" \
      "+SRC=$s" "+DST=$d" "+IMG_W=$iw" "+IMG_H=$ih" "+C_IN=$ic" \
      "+MEMFILE=$work/mem.hex" "+DUMPFILE=$work/$log.dump" +dump "$@" > "$log" 2>&1 )
  return $?
}

# ---------------- 判定器：正向（整片 + 三区域 + IRQ 纪律 + 交叉对账）----------------
cat > "$work/judge_pos.py" <<'PYEOF'
import sys, re
sys.path.insert(0, sys.argv[1])
from cmpbytes import load, diffs
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

mem_f, exp_f, dump_f, log_f = sys.argv[2:6]
src, dst, ln = (int(x) for x in sys.argv[6:9])

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

# --- 1c) 解析 TB 事实行 ---
txt = open(log_f, errors="replace").read()
def tok(name):
    # 不锚行首/行尾：一行里可能并排两个 key=value（如 `DONE_SEEN=1 ERR_SEEN=0`）
    m = re.search(r"\b%s=(\d+)\b" % name, txt)
    return int(m.group(1)) if m else None
def hextok(name):
    m = re.search(r"^%s ([0-9a-fA-F]+)$" % name, txt, re.M)
    return int(m.group(1), 16) if m else None

pre_irq   = tok("PRE_IRQ")
post_irq  = tok("POST_IRQ")
held50    = tok("IRQ_HELD_AFTER_50")
ack_irq   = tok("IRQ_AFTER_ACK")
irq_cyc   = tok("IRQ_HIGH_CYCLES")
irq_rises = tok("IRQ_RISES")
done_seen = tok("DONE_SEEN")
err_seen  = tok("ERR_SEEN")
status_post = hextok("STATUS_POST")
status_ack  = hextok("STATUS_AFTER_ACK")

print("IRQ DISC: PRE_IRQ=%s POST_IRQ=%s IRQ_HELD_AFTER_50=%s IRQ_AFTER_ACK=%s IRQ_HIGH_CYCLES=%s IRQ_RISES=%s"
      % (pre_irq, post_irq, held50, ack_irq, irq_cyc, irq_rises))
print("EVENT: DONE_SEEN=%s ERR_SEEN=%s STATUS_POST=%s STATUS_AFTER_ACK=%s"
      % (done_seen, err_seen, ("%08x" % status_post) if status_post is not None else None,
         ("%08x" % status_ack) if status_ack is not None else None))
print("RB_OK_present=%d" % (1 if re.search(r"^RB_OK$", txt, re.M) else 0))

# IRQ 纪律：启动前 0；完成后 1；保持（>=50 拍、恰好 1 次上升沿）；确认后 0
if pre_irq != 0:            print("IRQ_BAD PRE_IRQ=%s != 0" % pre_irq); bad += 1
if post_irq != 1:           print("IRQ_BAD POST_IRQ=%s != 1" % post_irq); bad += 1
if held50 != 1:             print("IRQ_BAD IRQ_HELD_AFTER_50=%s != 1" % held50); bad += 1
if ack_irq != 0:            print("IRQ_BAD IRQ_AFTER_ACK=%s != 0" % ack_irq); bad += 1
if irq_rises != 1:          print("IRQ_BAD IRQ_RISES=%s != 1" % irq_rises); bad += 1
if irq_cyc is None or irq_cyc < 50:
    print("IRQ_BAD IRQ_HIGH_CYCLES=%s < 50 (kept-level check failed => looks like a 1-cycle pulse)" % irq_cyc); bad += 1
# 事件：必须 done 无 err
if done_seen != 1:          print("EVT_BAD DONE_SEEN=%s != 1" % done_seen); bad += 1
if err_seen != 0:           print("EVT_BAD ERR_SEEN=%s != 0" % err_seen); bad += 1
if status_post is not None and ((status_post & 0x1) != 0x1):
    print("EVT_BAD STATUS_POST done_sticky 未置位 = %08x" % status_post); bad += 1
if status_post is not None and ((status_post & 0x2) != 0):
    print("EVT_BAD STATUS_POST err 不该置位 = %08x" % status_post); bad += 1

# --- 1d) 与内存模型的独立计数交叉对账 ---
m = re.search(r"^MEM rd=(\d+) wr=(\d+) bursts=(\d+) maxburst=(\d+)$", txt, re.M)
chunks = ln // 128
if not m:
    print("MEMLINE_MISSING"); bad += 1
else:
    rd, wr, bur, mx = (int(g) for g in m.groups())
    print("MEMCHECK rd=%d wr=%d bursts=%d maxburst=%d (expect rd=%d wr=%d bursts=%d maxburst=16)"
          % (rd, wr, bur, mx, ln, ln, 2 * chunks))
    if rd != ln:          print("MEMRD_BAD %d != %d" % (rd, ln)); bad += 1
    if wr != ln:          print("MEMWR_BAD %d != %d" % (wr, ln)); bad += 1
    if bur != 2 * chunks: print("MEMBURSTS_BAD %d != %d" % (bur, 2 * chunks)); bad += 1
    if mx != 16:          print("MEMMAXBURST_BAD %d != 16" % mx); bad += 1

print("JUDGE_EXTRA=%d" % bad)
sys.exit(1 if (mis != 0 or bad != 0) else 0)
PYEOF

# ===========================================================================
# 作业 1：正向 —— 编程 len=131072 的一次拷贝
# ===========================================================================
echo "---- 作业 1：正向 IMG_W=$IMG_W IMG_H=$IMG_H C_IN=$C_IN => LEN=$LEN（$(( LEN / 128 )) 块）----"
run_sim pos.log "$SRC" "$DST" "$IMG_W" "$IMG_H" "$C_IN"; RC=$?
if [ "$RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/pos.log"; then
  echo "JUDGE-RED: 正向仿真未 PASS（vvp rc=$RC）"
  grep -E '^(RESULT|TBFAIL|TB-ERROR|ID_READ|STATUS_|CTRL_|RB_|DONE_SEEN|ERR_SEEN|MEM )' "$work/pos.log" || true
  exit 1
fi
grep -E '^(ID_READ|STATUS_PRE|CTRL_PRE|PRE_IRQ|DONE_SEEN|ERR_SEEN|STATUS_POST|CTRL_POST|POST_IRQ|IRQ_|STATUS_AFTER_ACK|MEM )' "$work/pos.log" || true

"$PY" "$work/judge_pos.py" "$work" "$work/mem.hex" "$work/exp.hex" "$work/pos.log.dump" "$work/pos.log" \
  "$SRC" "$DST" "$LEN" > "$work/judge_pos.out" 2>&1
JRC=$?
cat "$work/judge_pos.out"
MIS="$(sed -n 's/^MISMATCH=\([0-9][0-9]*\)$/\1/p' "$work/judge_pos.out" | tail -1)"
JX="$(sed -n 's/^JUDGE_EXTRA=\([0-9][0-9]*\)$/\1/p' "$work/judge_pos.out" | tail -1)"
[ -n "$MIS" ] || MIS="-1"
[ -n "$JX" ]  || JX="-1"
if [ "$JRC" -ne 0 ] || [ "$MIS" != "0" ] || [ "$JX" != "0" ]; then
  echo "RESULT: FAIL（正相对账 MISMATCH=$MIS JUDGE_EXTRA=$JX）"
  exit 1
fi
echo "正相对账 OK：整片 MISMATCH=0；dst==src 且 src 未改且邻居未动；IRQ 纪律成立；与内存模型交叉对账相符。"

# ---------------- 比较器自检：扰动黄金镜像里一个期望字节 => MISMATCH 必须恰好 1 ----------------
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
if ! "$PY" - "$work" "$work/exp_neg.hex" "$work/pos.log.dump" > "$work/selftest.out" 2>&1 <<'PYEOF'
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
cat "$work/selftest.out"
SELFMIS="$(sed -n 's/^MISMATCH=\([0-9][0-9]*\).*$/\1/p' "$work/selftest.out" | tail -1)"
if [ "$SELFMIS" != "1" ]; then
  echo "RESULT: FAIL（比较器自检 MISMATCH=$SELFMIS != 1）⇒ 闸门不可信"
  exit 2
fi
echo "CMP_SELFTEST OK（扰动一个期望字节 => MISMATCH=1，比较器确实逐字节）"

# ===========================================================================
# 作业 3：负对照 A —— 非法长度（主机必须经 STATUS 观察到 err，且零搬运）
# ===========================================================================
echo "---- 作业 3：负对照 A[非法长度] IMG_W=$NEG_IMG_W IMG_H=$NEG_IMG_H C_IN=$NEG_C_IN => LEN=$NEG_LEN（非 128 倍数）----"
# 记下预载的 md5，稍后拿导出镜像做逐字节"没动过"判据
run_sim neg_len.log "$SRC" "$DST" "$NEG_IMG_W" "$NEG_IMG_H" "$NEG_C_IN" +EXPECT_ERR; NRC=$?
if [ "$NRC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/neg_len.log"; then
  echo "NEG_RED[len]: 装置没按预期报 err"
  grep -E '^(RESULT|TBFAIL|STATUS_|DONE_SEEN|ERR_SEEN|MEM )' "$work/neg_len.log" || true
  echo "RESULT: FAIL（负对照未发火）⇒ 闸门不可信"; exit 2
fi
grep -E '^(ID_READ|STATUS_PRE|STATUS_POST|STATUS_AFTER_ACK|DONE_SEEN|ERR_SEEN|PRE_IRQ|POST_IRQ|IRQ_AFTER_ACK|MEM )' "$work/neg_len.log" || true
nl_ok=1
grep -q '^DONE_SEEN=0 ERR_SEEN=1$' "$work/neg_len.log"        || { echo "NEG_RED[len]: 主机没看到 err / 看到 done"; nl_ok=0; }
grep -q '^MEM rd=0 wr=0 bursts=0 maxburst=0$' "$work/neg_len.log" || { echo "NEG_RED[len]: 内存模型记的读/写/突发数不为 0"; nl_ok=0; }
# STATUS_POST bit1 必须为 1（主机经 STATUS 观察到 err）
sp="$(sed -n 's/^STATUS_POST \([0-9a-fA-F]\{8\}\)$/\1/p' "$work/neg_len.log" | tail -1)"
if [ -z "$sp" ]; then echo "NEG_RED[len]: 缺 STATUS_POST"; nl_ok=0; else
  b1=$(( (0x$sp >> 1) & 1 ))
  echo "NEG_STATUS_POST=0x$sp -> err_bit=$b1"
  [ "$b1" = "1" ] || { echo "NEG_RED[len]: STATUS.bit1(err) 不是 1"; nl_ok=0; }
fi
# 导出镜像必须与预载逐字节相同（一个字节都没动）
same="$("$PY" - "$work/mem.hex" "$work/neg_len.log.dump" "$work" <<'PYEOF'
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
echo "NEG_DUMP_DIFF=$same（应 0 -1：零搬运）"
[ "$same" = "0 -1" ] || { echo "NEG_RED[len]: 镜像与预载不同（diff=$same）⇒ 非法长度竟然改了内存"; nl_ok=0; }
if [ "$nl_ok" != "1" ]; then echo "RESULT: FAIL（负对照未发火）⇒ 闸门不可信"; exit 2; fi
echo "NEG_OK[len]: 主机经 STATUS 观察到 err；零搬运（MEM rd=wr=bursts=0、镜像==预载、无 done）"

# ===========================================================================
# 作业 4：负对照 B —— 网表突变：派生的 len 整条 +128（尾部邻居会被多写 128 B）
# ===========================================================================
echo "---- 作业 4：负对照 B[网表突变: 派生 len +128] ----"
# ★ 突变锚点的前提更新（**判据不变、突变强度不变，只换被指的网表语句**）：
#   · C3.12：NpuTop 例化了 LayerSched（其内部另有 3 个 DdrMaster）⇒ 顶层拷贝主口例化名从写死的
#     `ddrMaster_1` 漂成 `ddrMaster_4`；当时锚点是 `assign ddrMaster_<N>_len = (lenOk ? _zz_len : 32'h0);`。
#   · **C3.17（Round1 时序）**：为把这条 28 级组合链从 DdrMaster 的 CE 路径上摘掉，`len` 改成了
#     **三级寄存流水**（`whReg -> prodReg -> lenReg`）⇒ 那条 `assign ..._len = ...` **不再存在**
#     （顶层端口现在直接接寄存器：`.len(lenReg[31:0])`）。所以锚点从「输出 assign」搬到
#     「寄存长度那一级的**次态表达式**」：
#         lenReg <= (lenOk ? _zz_lenReg : 32'h0);
#     它仍是**唯一**一条“派生长度”语句（LayerSched 内部 DdrMaster 的 len 是输入端口，不生成它），
#     `_zz_lenReg` 就是 `prodReg[31:0]`（= C2 时代被驱动的那个值）。突变体仍把派生长度**整条 +128**
#     ⇒ 尾部邻居会被多写 128 B，字节判据（首个不符偏移 == DST+LEN）依旧必须发火。★ 只动锚点，判据/
#     期望都不动 ⇒ 负对照 B 的强度一字未减。
if ! "$PY" - "$nl" "$work/NpuTop_lenplus.v" > "$work/mutgen.out" 2>&1 <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
src = open(sys.argv[1], encoding="utf-8").read()
pat = re.compile(r"lenReg\s*<=\s*\(lenOk \? _zz_lenReg : 32'h0\);")
new, n = pat.subn(r"lenReg <= (lenOk ? (_zz_lenReg + 32'h00000080) : 32'h0);", src)
print("MUTGEN_HITS=%d" % n)
if n != 1:
    sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(new)
PYEOF
then
  echo "RESULT: FAIL（无法构造 len+128 突变网表）"; cat "$work/mutgen.out"; exit 2
fi
cat "$work/mutgen.out"

if ! "$IVERILOG" -g2012 -o "$work/mut.vvp" "$tb" "$memv" "$work/NpuTop_lenplus.v" > "$work/iv_mut.log" 2>&1; then
  echo "RESULT: FAIL（突变网表编译失败）⇒ 闸门不可信"; sed -n '1,40p' "$work/iv_mut.log"; exit 2
fi
( cd "$work" && "$VVP" "$work/mut.vvp" \
    "+SRC=$SRC" "+DST=$DST" "+IMG_W=$IMG_W" "+IMG_H=$IMG_H" "+C_IN=$C_IN" \
    "+MEMFILE=$work/mem.hex" "+DUMPFILE=$work/mut.dump" +dump > "$work/mut.log" 2>&1 ); MRC=$?
if ! grep -q '^RESULT: PASS' "$work/mut.log"; then
  echo "RESULT: FAIL（突变网表下装置未 PASS：突变把集成体改坏了，负对照不成立）"
  grep -E '^(RESULT|TBFAIL|DONE_SEEN|ERR_SEEN|MEM )' "$work/mut.log" || true
  exit 2
fi
grep -E '^(DONE_SEEN|ERR_SEEN|MEM )' "$work/mut.log" || true
"$PY" - "$work" "$work/exp.hex" "$work/mut.dump" "$DST" "$LEN" > "$work/mutjudge.out" 2>&1 <<'PYEOF'
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
print("MUTEXPECT_FIRST_OFF=%d" % (dst + ln))
sys.exit(0 if (mis > 0 and first == dst + ln) else 1)
PYEOF
MUTC=$?
cat "$work/mutjudge.out"
MUTMIS="$(sed -n 's/^MUTMISMATCH=\([0-9][0-9]*\)$/\1/p' "$work/mutjudge.out" | tail -1)"
MUTFIRST="$(sed -n 's/^MUTFIRST_OFF=\([0-9-][0-9]*\)$/\1/p' "$work/mutjudge.out" | tail -1)"
if [ "$MUTC" -ne 0 ] || [ "${MUTMIS:-0}" -le 0 ] 2>/dev/null || [ "$MUTFIRST" != "$(( DST + LEN ))" ]; then
  echo "RESULT: FAIL（len+128 突变没被字节判据抓住：MISMATCH=$MUTMIS FIRST_OFF=$MUTFIRST 期望 >0 / $(( DST + LEN ))）⇒ 闸门不可信"
  exit 2
fi
echo "NEG_OK[mutlen]: 字节判据抓住了派生长度 +128（MISMATCH=$MUTMIS，首个不符偏移 $MUTFIRST == DST+LEN）"

# ---------------- 收口 ----------------
IRQCYC="$(sed -n 's/^IRQ_HIGH_CYCLES=\([0-9]*\).*$/\1/p' "$work/pos.log" | tail -1)"
[ -n "$IRQCYC" ] || IRQCYC="?"
echo "MISMATCH=$MIS"
echo "三区域：DST_EQ_SRC_BAD=0 SRC_UNCHANGED_BAD=0 NEIGHBOR_BAD=0（整片逐字节相符）"
echo "IRQ 纪律：PRE_IRQ=0 / POST_IRQ=1 / IRQ_AFTER_ACK=0 / IRQ_RISES=1 / IRQ_HIGH_CYCLES=$IRQCYC（保持电平，非单拍脉冲）"
echo "负对照 A[非法长度] = 发火（主机经 STATUS 看到 err；零搬运）"
echo "负对照 B[len+128 突变] = 发火（MISMATCH=$MUTMIS>0，首个不符偏移 $MUTFIRST == DST+LEN）"
echo "比较器自检 = OK（扰动一个期望字节 => MISMATCH=1）"
echo "RESULT: PASS"
exit 0
