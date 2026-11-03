#!/usr/bin/env bash
# run_hostregs_ab.sh —— 主机寄存器层（rtl/HostRegs.scala + gen/HostRegs.v）的**穷举回读**闸门。
#
# 三项职责（与 tools/run_weightstore_ab.sh / run_linebuffer_ab.sh 同风格）：
#   1) 穷举回读：对寄存器表里**每一个**寄存器写一个**地址派生的、彼此不同**的模式
#      （0xA5A50000 | (offset>>2)），再把它们**全部**回读，逐元素对账，打印唯一一行
#      `MISMATCH=<n>`。模式必须两两不同 —— 全用同一个模式的话，地址译码错位会静默通过。
#   2) 只读语义：写一个值进 ID(0x30) 后回读必须仍是常数 0x594E5031；且**任何写之前**
#      ID 就必须读回常数。装置（HostRegsTb.v）打印 PRE_ID/POST_ID 与 RO_BEFORE_OK/RO_AFTER_OK，
#      闸门另做**独立**的 grep 断言（不盲信装置的 PASS）。
#   3) 负对照（必须抓住，且是"恰好 1"）：把**一个**期望值扰动（IMG_W 的期望 XOR 1），重新跑一遍
#      仿真+对账，断言 MISMATCH **恰好等于 1**（不是"非 0"）。这同时证明比较是**逐元素**的，
#      不是"整行某处不等就算 1"。
#   4) ★ C3.16 权重信箱语义（**新增的一档判据**）：三个 RW 档（WGT_SEL/WGT_ADDR/WGT_DATA）参与上面
#      19 格的穷举回读；`WGT_WE` 是**只写 + 自清单拍**——装置显式写 1 后：导出端口恰好高 **1 拍**、
#      随后自己落回 0、回读恒 0。闸门独立 grep `WGT_WE_PULSES 1` / `WGT_WE_NOW 0` / `WGT_RB_WE 00000000`。
#
# 退出码：
#   0 = 通过（MISMATCH=0 + 只读语义 OK + 装置 PASS + 负对照恰好 1）
#   1 = 对账不符 / 编译或仿真失败 / 装置未 PASS / 只读语义不成立 / 向量自检失败
#   2 = 负对照没抓住（MISMATCH != 1）⇒ 闸门自身不可信
#
# 装置契约：rtl_test/HostRegsTb.v + gen/HostRegs.v（定点生成，AxiLite4 32/32）
#   +VECFILE=<file>  每行一对十六进制「地址 值」：`<addr_hex> <value_hex>`（字节地址 = 表偏移）。
#   装置按文件顺序**先逐条写、再逐条回读**，逐条打印 `READ <addr> <value>`；
#   末尾打印 `RESULT: PASS` / `RESULT: FAIL`（FAIL 时 $fatal ⇒ vvp 非 0）。
#
# 寄存器表（冻结，与 rtl/HostRegs.scala 头部逐字一致；改表要同步改这里）：
#   0x00 CTRL(混合) 0x04 STATUS(RO；[31:8]=逐单元遥测) 0x08 IMG_W 0x0C IMG_H 0x10 C_IN 0x14 C_OUT 0x18 GROUP
#   0x1C KERNEL 0x20 SRC_ADDR 0x24 DST_ADDR 0x28 QUANT_SHIFT 0x2C LAYER_ID 0x30 ID(RO=0x594E5031)
#   0x34 DESC_ADDR(RW) 0x38 DESC_COUNT(RW)   ← ★ C3.12 新增两档（与既有 10 个 RW 档同姿，整 32 位）
#   0x3C WGT_SEL(RW) 0x40 WGT_ADDR(RW) 0x44 WGT_DATA(RW) 0x48 WGT_WE(WO，自清单拍)
#                                             ← ★ C3.16 新增四档：权重信箱（表尾随之从 0x38 挪到 0x48）
set -uo pipefail

PY="${PY:-python}"
here="$(cd "$(dirname "$0")" && pwd)"
gen="$here/../gen"
tb="$here/../rtl_test/HostRegsTb.v"
nl="$gen/HostRegs.v"

work="$(mktemp -d)"
cleanup() {
  if [ "${KEEP_TMP:-0}" = "1" ]; then
    echo "KEEP_TMP=1 => 向量与日志留在 $work"
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

echo "== run_hostregs_ab: 主机寄存器层（AxiLite4 从口 + 寄存器表）穷举回读 =="
echo "   tb =$tb"
echo "   nl =$nl"
echo "   iverilog=${IVERILOG:-<找不到>}  vvp=${VVP:-<找不到>}"
echo "   tmp=$work"

# ---------------- 前置检查 ----------------
if [ ! -f "$nl" ]; then
  echo "FATAL: 找不到网表 $nl"
  echo "       先生成: cd y1 && printf 'Test/runMain HostRegsGen D:/code/PDS/VexiiYeshenLinux/y1/gen\\nexit\\n' | bash sbt.sh"
  exit 1
fi
if [ ! -f "$tb" ]; then echo "FATAL: 找不到装置 $tb"; exit 1; fi
if [ -z "$IVERILOG" ] || [ -z "$VVP" ]; then echo "FATAL: 找不到 iverilog / vvp"; exit 1; fi

# ---------------- 1) 造向量与期望（python 独立生成）----------------
# 指令：对表里每一项写模式 p(off) = 0xA5A50000 | (off>>2)；
#       期望回读 = p(off)（纯 RW）/ 0（CTRL、STATUS）/ 0x594E5031（ID）。
if ! "$PY" - "$work" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

work = sys.argv[1]

ID_CONST = 0x594E5031
# (offset, name, kind)  kind: rw=纯读写 / ctrl=混合旺写(bit0/1自清,bit8/9只读) / status=只读 / id=只读常数
#                            wo=只写（自清单拍；回读恒 0）
TABLE = [
    (0x00, "CTRL",        "ctrl"),
    (0x04, "STATUS",      "status"),
    (0x08, "IMG_W",       "rw"),
    (0x0C, "IMG_H",       "rw"),
    (0x10, "C_IN",        "rw"),
    (0x14, "C_OUT",       "rw"),
    (0x18, "GROUP",       "rw"),
    (0x1C, "KERNEL",      "rw"),
    (0x20, "SRC_ADDR",    "rw"),
    (0x24, "DST_ADDR",    "rw"),
    (0x28, "QUANT_SHIFT", "rw"),
    (0x2C, "LAYER_ID",    "rw"),
    (0x30, "ID",          "id"),
    (0x34, "DESC_ADDR",   "rw"),   # ★ C3.12：层调度器描述符表基址（整 32 位 RW，逐字回读）
    (0x38, "DESC_COUNT",  "rw"),   # ★ C3.12：层调度器载荷项数（整 32 位 RW，逐字回读）
    (0x3C, "WGT_SEL",     "rw"),   # ★ C3.16：权重信箱——目标切片下标（整 32 位 RW，逐字回读）
    (0x40, "WGT_ADDR",    "rw"),   # ★ C3.16：权重信箱——切片内条目下标（整 32 位 RW，逐字回读）
    (0x44, "WGT_DATA",    "rw"),   # ★ C3.16：权重信箱——int8 载荷在低 8 位（整 32 位存储，逐字回读）
    (0x48, "WGT_WE",      "wo"),   # ★ C3.16：权重信箱——自清单拍写使能（只写；回读恒 0）
]

def pattern(off):
    return (0xA5A50000 | (off >> 2)) & 0xFFFFFFFF

def expect(off, kind):
    if kind == "ctrl":
        return 0x00000000          # bit0/1 自清 ⇒ 读 0；bit8/9 = busy/done = 0（装置把状态输入接 0）
    if kind == "status":
        # ★ P1：STATUS[31:8] = sched_unitIndex（装置在整个穷举段驱动 0x00ABCD）；
        #   bit0/1 在没有事件时读 0。
        return 0x00ABCD00
    if kind == "id":
        return ID_CONST            # 写它永远读回常数
    if kind == "wo":
        return 0x00000000          # 只写档（自清单拍）：没有任何读 handler ⇒ 回读恒 0
    return pattern(off)            # 纯 RW：逐字回读

# 自检 1：模式必须**两两不同**（否则地址译码错位会静默通过）
pats = [pattern(off) for off, _, _ in TABLE]
assert len(pats) == len(set(pats)), "FATAL: 地址派生模式出现撞值 ⇒ 用例没意义"
# 自检 2：模式不能恰好等于 ID 常数或 0（否则期望会含糊）
assert ID_CONST not in pats, "FATAL: 某个模式 == ID 常数"
assert 0 not in pats, "FATAL: 某个模式 == 0"
# 自检 3：期望里 CTRL/STATUS/ID/WGT_WE 与写入模式**不同**（否则"写入模式 ≠ 期望"这道对账没区分度）
for off, name, kind in TABLE:
    if kind in ("ctrl", "status", "id", "wo"):
        assert expect(off, kind) != pattern(off), "FATAL: %s 的期望与写入模式相同 ⇒ 无区分度" % name
# 自检 4：★ C3.16 —— `WGT_WE` 的写入模式**不能**带 bit0（否则穷举段会真的发一次写脉冲，
#   把"1 拍脉冲"这个判据搅浑；脉冲的判据由 HostRegsTb 的 4d) 段**显式**写 1 来给）。
assert (pattern(0x48) & 1) == 0, "FATAL: WGT_WE 的写入模式带了 bit0 ⇒ 会误发写脉冲"

vec = open(work + "/vec.hex", "w")
exp = open(work + "/exp.txt", "w")
man = open(work + "/manifest.txt", "w")
for off, name, kind in TABLE:
    p = pattern(off)
    e = expect(off, kind)
    vec.write("%08x %08x\n" % (off, p))
    exp.write("%08x %08x\n" % (off, e))
    man.write("%08x %-12s %-7s write=%08x expect=%08x\n" % (off, name, kind, p, e))
vec.close(); exp.close(); man.close()
print("VECGEN_OK n=%d" % len(TABLE))
PYEOF
then
  echo "FATAL: 生成向量/期望失败"; exit 1
fi

for f in vec.hex exp.txt manifest.txt; do
  [ -s "$work/$f" ] || { echo "FATAL: $f 缺失或为空"; exit 1; }
done
echo "---- 寄存器表 / 向量 / 期望 ----"
cat "$work/manifest.txt"

# 对账器：读期望文件与仿真日志里的 READ 行，逐元素比较，打印 MISMATCH=<n>。
# 用法： cmp.py <exp_file> <sim_log> [tag]
cat > "$work/cmp.py" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

exp_file, log_file = sys.argv[1], sys.argv[2]
tag = sys.argv[3] if len(sys.argv) > 3 else "main"

expected = []
for ln in open(exp_file):
    t = ln.split()
    if len(t) == 2:
        expected.append((int(t[0], 16), int(t[1], 16)))

readback = {}
order = []
for ln in open(log_file, errors="replace"):
    t = ln.split()
    if len(t) == 3 and t[0] == "READ":
        a, v = int(t[1], 16), int(t[2], 16)
        if a not in readback:
            order.append(a)
        readback[a] = v

mis = 0
exp_addrs = set(a for a, _ in expected)
for a, e in expected:
    if a not in readback:
        mis += 1
        print("MISSING addr=%08x expect=%08x（装置没打印这条 READ）" % (a, e))
    elif readback[a] != e:
        mis += 1
        print("MISMATCH addr=%08x got=%08x expect=%08x" % (a, readback[a], e))
for a in order:
    if a not in exp_addrs:
        mis += 1
        print("UNEXPECTED addr=%08x got=%08x（期望表里没有这个地址）" % (a, readback[a]))

print("n_expected=%d n_read=%d" % (len(expected), len(readback)))
print("MISMATCH=%d" % mis)
PYEOF

# 只读语义的独立断言（不盲信装置 PASS）
check_ro() { # <log>
  local log="$1" bad=0 id="594e5031"
  grep -q '^RO_BEFORE_OK' "$log" || { echo "JUDGE-RED: 缺 RO_BEFORE_OK（写之前 ID 未读回常数）"; bad=1; }
  grep -q '^RO_AFTER_OK'  "$log" || { echo "JUDGE-RED: 缺 RO_AFTER_OK（写之后 ID 未读回常数）";  bad=1; }
  grep -q "^PRE_ID $id$" "$log" || { echo "JUDGE-RED: PRE_ID != $id";  bad=1; }
  grep -q "^POST_ID $id$" "$log" || { echo "JUDGE-RED: POST_ID != $id"; bad=1; }
  grep -q '^UNMAPPED_OK'  "$log" || { echo "JUDGE-RED: 缺 UNMAPPED_OK（未映射读=0/写被忽略 未过）"; bad=1; }
  grep -q '^LIVE_OK'      "$log" || { echo "JUDGE-RED: 缺 LIVE_OK（busy/done/err 只读位未接通）"; bad=1; }
  # ★ C3.16：权重信箱的四条导出真的接在网络上（写进去 → 端口上看得见），且 `WGT_WE` 是自清单拍
  grep -q '^WGT_OK'       "$log" || { echo "JUDGE-RED: 缺 WGT_OK（权重信箱导出/自清单拍 未过）"; bad=1; }
  grep -q '^WGT_WE_PULSES 1$' "$log" || { echo "JUDGE-RED: WGT_WE_PULSES != 1（写使能不是单拍脉冲）"; bad=1; }
  grep -q '^WGT_WE_NOW 0$'    "$log" || { echo "JUDGE-RED: WGT_WE_NOW != 0（写使能没自清）"; bad=1; }
  grep -q '^WGT_RB_WE 00000000$' "$log" || { echo "JUDGE-RED: WGT_WE 回读 != 0（只写档被读回）"; bad=1; }
  return $bad
}

run_sim() { # <logname> <vecfile> -> 0/1
  local log="$1" vf="$2" rc=0
  ( cd "$work" && "$VVP" sim.vvp "+VECFILE=$vf" > "$log" 2>&1 ) || rc=$?
  if [ "$rc" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/$log"; then
    echo "JUDGE-RED: 装置未 PASS（vvp rc=$rc，log=$log）"
    grep '^RESULT:' "$work/$log" || true
    grep '^TBFAIL'  "$work/$log" || true
    return 1
  fi
  return 0
}

# ---------------- 2) 编译 ----------------
if ! "$IVERILOG" -g2012 -o "$work/sim.vvp" "$tb" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败"; sed -n '1,30p' "$work/iv.log"; exit 1
fi
echo "---- iverilog 编译 OK ----"

# ---------------- 3) 主跑：正向对账 ----------------
run_sim main.log "$work/vec.hex" || exit 1
if ! check_ro "$work/main.log"; then exit 1; fi

echo "---- 装置日志摘录（READ / RO / UNMAPPED / LIVE / WGT）----"
grep -E '^(READ|PRE_ID|POST_ID|RO_|UNMAPPED|LIVE|WGT)' "$work/main.log" || true

"$PY" "$work/cmp.py" "$work/exp.txt" "$work/main.log" main | tee "$work/cmp_main.out"
MIS="$(sed -n 's/^MISMATCH=\([0-9][0-9]*\)$/\1/p' "$work/cmp_main.out" | tail -1)"
[ -n "$MIS" ] || MIS="-1"
if [ "$MIS" != "0" ]; then
  echo "RESULT: FAIL（正相对账 MISMATCH=$MIS）"
  exit 1
fi

# ---------------- 4) 负对照：扰动**一个**期望值 ⇒ 必须恰好 1 ----------
# 扰动 IMG_W(0x08) 的期望（XOR 1）。向量不动、仿真重跑，比较器必须报告**恰好 1**个不符。
"$PY" - "$work" <<'PYEOF'
import sys
work = sys.argv[1]
src = work + "/exp.txt"
dst = work + "/exp_neg.txt"
out = []
hit = 0
for ln in open(src):
    t = ln.split()
    if len(t) == 2 and int(t[0], 16) == 0x08:
        v = int(t[1], 16) ^ 1
        out.append("%08x %08x\n" % (int(t[0], 16), v))
        hit += 1
    else:
        out.append(ln)
assert hit == 1, "FATAL: 负对照扰动命中 %d 条（要恰好 1）" % hit
open(dst, "w").writelines(out)
print("NEGPERT_OK addr=00000008")
PYEOF
[ -s "$work/exp_neg.txt" ] || { echo "FATAL: 负对照期望缺失"; exit 2; }

run_sim neg.log "$work/vec.hex" || { echo "RESULT: FAIL（负对照仿真没跑通）"; exit 2; }
"$PY" "$work/cmp.py" "$work/exp_neg.txt" "$work/neg.log" neg | tee "$work/cmp_neg.out"
NEGMIS="$(sed -n 's/^MISMATCH=\([0-9][0-9]*\)$/\1/p' "$work/cmp_neg.out" | tail -1)"
[ -n "$NEGMIS" ] || NEGMIS="-1"
echo "NEG_MISMATCH=$NEGMIS"
if [ "$NEGMIS" != "1" ]; then
  echo "RESULT: FAIL（负对照未按预期恰 1 发火，NEG_MISMATCH=$NEGMIS）⇒ 闸门不可信"
  exit 2
fi

# ---------------- 收口 ----------------
echo "MISMATCH=$MIS"
echo "RO 检查 = OK（PRE_ID/POST_ID = 0x594E5031，含未映射与状态位 LIVE）"
echo "负对照 = 恰好 1（NEG_MISMATCH=$NEGMIS，逐元素比较成立）"
echo "RESULT: PASS"
exit 0
