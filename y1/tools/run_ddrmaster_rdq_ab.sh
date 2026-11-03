#!/usr/bin/env bash
# =============================================================================
# run_ddrmaster_rdq_ab.sh —— L2b：DdrMaster **mode=1 块槽预取**闸门（正 + 负对照）
#
# 判据（全部必须成立）：
#   ① q4 正档（gen/DdrMaster.v，rqDepth=4）：一笔 1024 B 的 RD 内 AR **背靠背多笔在飞**
#      （TB 自计 MAXOUT ≥ 2）+ 三个请求的收流与内存**逐字节相同** + RDBYTES=2336；
#   ② q1 负对照（gen/DdrMaster_q1.v，rqDepth=1）：**结构性退化为单块串行**（MAXOUT == 1），
#      数据仍逐字节相同（证明"多"不是靠错数据换来的）；
#   ③ 两档的 `MEM rd=2336` 与 TB 自报 RDBYTES 交叉一致。
#
# 退出码：0=通过 / 1=红 / 3=前置缺失。
# 只读资产：gen/DdrMaster*.v / rtl_test/DdrRdQTb.v / rtl_test/AxiMemModel.v 一字不改。
# =============================================================================
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
gen="$here/../gen"
tb="$here/../rtl_test/DdrRdQTb.v"
memv="$here/../rtl_test/AxiMemModel.v"
nl4="$gen/DdrMaster.v"
nl1="$gen/DdrMaster_q1.v"

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
PY="${PY:-python}"

echo "== run_ddrmaster_rdq_ab: DdrMaster mode=1 块槽预取（Q=4 正档 / Q=1 负对照）=="
echo "   tb=$tb  mem=$memv  nl4=$nl4  nl1=$nl1"
echo "   iverilog=${IVERILOG:-<找不到>} vvp=${VVP:-<找不到>}"

missing=0
[ -f "$tb" ] || { echo "PRECOND-FAIL: 缺 $tb"; missing=1; }
[ -f "$memv" ] || { echo "PRECOND-FAIL: 缺 $memv"; missing=1; }
[ -f "$nl4" ] || { echo "PRECOND-FAIL: 缺 $nl4（先生成 DdrMasterGen）"; missing=1; }
[ -f "$nl1" ] || { echo "PRECOND-FAIL: 缺 $nl1（先生成 DdrMasterGen）"; missing=1; }
[ -n "$IVERILOG" ] || { echo "PRECOND-FAIL: 找不到 iverilog"; missing=1; }
[ -n "$VVP" ] || { echo "PRECOND-FAIL: 找不到 vvp"; missing=1; }
if [ "$missing" != "0" ]; then echo "VERDICT: PRECONDITION-MISSING"; exit 3; fi

work_msys="$(mktemp -d)"
work="$(cygpath -m "$work_msys" 2>/dev/null || printf '%s' "$work_msys")"
cleanup() { [ "${KEEP_TMP:-0}" = "1" ] && echo "KEEP_TMP=1 => $work" || rm -rf "$work_msys"; }
trap cleanup EXIT

# ---- 激励：16 KiB 周期模式；期望 = 三段请求的拼接 ----
"$PY" - "$work" <<'PYEOF'
import sys
work = sys.argv[1]
MEMSZ = 16384
mem = bytes(((i*131 + 7) & 0xFF) for i in range(MEMSZ))
open(work + "/mem.hex", "w").write("".join("%02x\n" % b for b in mem))
exp = mem[0x1000:0x1000+1024] + mem[0x2000:0x2000+992] + mem[0x3000:0x3000+320]
open(work + "/exp.hex", "w").write(exp.hex())
print("MEMGEN bytes=%d exp=%d" % (MEMSZ, len(exp)))
PYEOF
[ -s "$work/exp.hex" ] || { echo "VERDICT: PRECONDITION-MISSING (激励生成失败)"; exit 3; }

run_one() {
  local tag="$1" nl="$2" minout="$3"
  if ! "$IVERILOG" -g2012 -o "$work/$tag.vvp" "$tb" "$memv" "$nl" > "$work/$tag.iv.log" 2>&1; then
    echo "JUDGE-RED[$tag]: iverilog 编译失败"; sed -n '1,30p' "$work/$tag.iv.log"; return 1
  fi
  ( cd "$work" && "$VVP" "$work/$tag.vvp" \
      "+MEMFILE=$work/mem.hex" "+OUTFILE=$work/$tag.out" "+MINOUT=$minout" > "$work/$tag.log" 2>&1 )
  local rc=$?
  echo "---- [$tag] vvp rc=$rc MINOUT=$minout ----"
  grep -E '^(REQ |MAXOUT=|MEM |RESULT)' "$work/$tag.log" | sed 's/^/   /'
  return $rc
}

fail=0
run_one q4 "$nl4" 2 || fail=1
run_one q1 "$nl1" 1 || fail=1

# ---- 判据 ----
if [ "$fail" != "0" ]; then echo "VERDICT: RED（q4 或 q1 仿真未 PASS）"; exit 1; fi

check() {  # check <tag> <regex> <描述>
  if ! grep -Eq "$2" "$work/$1.log"; then
    echo "JUDGE-RED[$1]: $3 不满足（$2）"; return 1
  fi
  return 0
}
check q4 '^RESULT: PASS' "q4 RESULT" || fail=1
check q1 '^RESULT: PASS' "q1 RESULT" || fail=1
q4out="$(sed -n 's/^MAXOUT=\([0-9]*\).*/\1/p' "$work/q4.log" | tail -1)"
q1out="$(sed -n 's/^MAXOUT=\([0-9]*\).*/\1/p' "$work/q1.log" | tail -1)"
q4cyc="$(grep -o 'cyc=[0-9]*' "$work/q4.log" | tr '\n' ' ')"
q1cyc="$(grep -o 'cyc=[0-9]*' "$work/q1.log" | tr '\n' ' ')"
echo "   q4 MAXOUT=${q4out:-?} cyc: $q4cyc"
echo "   q1 MAXOUT=${q1out:-?} cyc: $q1cyc"
[ -n "$q4out" ] && [ "$q4out" -ge 2 ] || { echo "JUDGE-RED: q4 MAXOUT=${q4out:-?} < 2（没有背靠背 AR）"; fail=1; }
[ -n "$q1out" ] && [ "$q1out" -eq 1 ] || { echo "JUDGE-RED: q1 MAXOUT=${q1out:-?} != 1（负对照未退化）"; fail=1; }
for t in q4 q1; do
  check "$t" '^MEM rd=2336 wr=0 ' "$t MEM rd" || fail=1
  check "$t" 'RDBYTES=2336' "$t RDBYTES" || fail=1
done

# ---- 逐字节对账 ----
for t in q4 q1; do
  if ! "$PY" - "$work/exp.hex" "$work/$t.out" <<'PYEOF'
import sys
exp = open(sys.argv[1]).read().strip()
got = open(sys.argv[2]).read().strip()
if len(exp) != len(got):
    print("MISMATCH-LEN exp=%d got=%d" % (len(exp), len(got))); sys.exit(1)
if exp != got:
    n = min(len(exp), len(got)); d = next((i for i in range(n) if exp[i] != got[i]), n)
    print("MISMATCH first_hexchar=%d" % d); sys.exit(1)
print("BYTES-OK %d" % (len(exp)//2))
PYEOF
  then echo "JUDGE-RED[$t]: 收流与内存不逐字节相同"; fail=1; fi
done

if [ "$fail" != "0" ]; then echo "VERDICT: RED"; exit 1; fi
echo "VERDICT: RDQ-OK（q4 MAXOUT=$q4out 背靠背在飞；q1 MAXOUT=$q1out 负对照退化；两档收流逐字节 == 内存）"
echo "RESULT: PASS"
exit 0
