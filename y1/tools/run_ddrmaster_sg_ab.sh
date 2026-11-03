#!/usr/bin/env bash
# =============================================================================
# run_ddrmaster_sg_ab.sh —— B3b：DdrMaster **mode=3 多事务散读（SG-RD）**闸门
#
# 判据（全部必须成立）：
#   ① 三批 SG（N=1 / N=8 / N=2 混合 32+64 B）的收流与内存**逐字节相同**；
#      每批 `rd_bytes` == Σ项长（32 / 256 / 96），全跑 `MEM rd=384`；
#   ② 多笔在飞是真的：N=8 批 `maxout >= 2`（AR 背靠背多笔，非串行）；
#      N=1 批 `maxout == 1`（单事务结构上限，正对照）；
#   ③ TB 内负对照全绿（`tbfail=0`）：非 32B 对齐 / 拍数非 4 倍数 ⇒ ready=0+err；
#      空队 start(mode=3) ⇒ err；第 9 项队满 ⇒ ready=0；忙时入队 ⇒ ready=0；
#   ④ 结构性负对照（本脚本构造）：把网表 `(sgIss-sgDr) < 4` 改成 `< 1` 的 mutant
#      ⇒ 数据仍逐字节相同、但 N=8 批 maxout 退回 1（证明判据 ② 会变红）；
#   ⑤ 比较器自检：把期望流翻 1 bit，逐字节对账必须报 MISMATCH（证明判据 ① 会变红）。
#
# 退出码：0=通过 / 1=红 / 3=前置缺失。
# 只读资产：rtl_test/DdrSgTb.v / rtl_test/AxiMemModel.v（一字不改）。
# GEN_DIR=<dir> 可指向别处的 DdrMaster*.v（默认 ../gen）。
# =============================================================================
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
gen="${GEN_DIR:-$here/../gen}"
tb="$here/../rtl_test/DdrSgTb.v"
memv="$here/../rtl_test/AxiMemModel.v"
nl="$gen/DdrMaster.v"

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

echo "== run_ddrmaster_sg_ab: DdrMaster mode=3 多事务散读（正档 / 1-outstanding mutant / 比较器自检）=="
echo "   tb=$tb  mem=$memv  nl=$nl"
echo "   iverilog=${IVERILOG:-<找不到>} vvp=${VVP:-<找不到>}"

missing=0
[ -f "$tb" ] || { echo "PRECOND-FAIL: 缺 $tb"; missing=1; }
[ -f "$memv" ] || { echo "PRECOND-FAIL: 缺 $memv"; missing=1; }
[ -f "$nl" ] || { echo "PRECOND-FAIL: 缺 $nl（先生成 DdrMasterGen）"; missing=1; }
[ -n "$IVERILOG" ] || { echo "PRECOND-FAIL: 找不到 iverilog"; missing=1; }
[ -n "$VVP" ] || { echo "PRECOND-FAIL: 找不到 vvp"; missing=1; }
if [ "$missing" != "0" ]; then echo "VERDICT: PRECONDITION-MISSING"; exit 3; fi

work_msys="$(mktemp -d)"
work="$(cygpath -m "$work_msys" 2>/dev/null || printf '%s' "$work_msys")"
cleanup() { [ "${KEEP_TMP:-0}" = "1" ] && echo "KEEP_TMP=1 => $work" || rm -rf "$work_msys"; }
trap cleanup EXIT

# ---- 激励与期望：16 KiB 周期模式；期望 = A(N=1) + B(N=8) + C(N=2 混合长度) 的项序拼接 ----
"$PY" - "$work" <<'PYEOF'
import sys
work = sys.argv[1]
MEMSZ = 16384
mem = bytes(((i*37 + 11) & 0xFF) for i in range(MEMSZ))
open(work + "/mem.hex", "w").write("".join("%02x\n" % b for b in mem))
batches = [
    [(0x1000, 32)],
    [(0x2000 + k*0x100, 32) for k in range(8)],
    [(0x3000, 32), (0x3040, 64)],
]
exp = b"".join(mem[a:a+n] for b in batches for (a, n) in b)
open(work + "/exp.hex", "w").write(exp.hex())
open(work + "/batch_bytes.txt", "w").write(" ".join(str(sum(n for _, n in b)) for b in batches))
print("MEMGEN bytes=%d exp=%d batches=%d" % (MEMSZ, len(exp), len(batches)))
PYEOF
[ -s "$work/exp.hex" ] || { echo "VERDICT: PRECONDITION-MISSING (激励生成失败)"; exit 3; }
exp_sizes="$(cat "$work/batch_bytes.txt")"

# 逐字节对账（打印 MISMATCH 或 BYTES-OK；返回 1 表示不等）
cmp_bytes() {  # cmp_bytes <exp.hex> <out.hex>
  "$PY" - "$1" "$2" <<'PYEOF'
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
}

run_one() {  # run_one <tag> <nlfile>
  local tag="$1" nlfile="$2"
  if ! "$IVERILOG" -g2012 -o "$work/$tag.vvp" "$tb" "$memv" "$nlfile" > "$work/$tag.iv.log" 2>&1; then
    echo "JUDGE-RED[$tag]: iverilog 编译失败"; sed -n '1,30p' "$work/$tag.iv.log"; return 1
  fi
  ( cd "$work" && "$VVP" "$work/$tag.vvp" \
      "+MEMFILE=$work/mem.hex" "+OUTFILE=$work/$tag.out" > "$work/$tag.log" 2>&1 )
  local rc=$?
  echo "---- [$tag] vvp rc=$rc ----"
  grep -E '^(SG |BATCH |MEM |MAXOUT_MODEL|RESULT)' "$work/$tag.log" | sed 's/^/   /'
  return $rc
}

fail=0
run_one base "$nl" || fail=1

# ---- mutant：只允许 1 笔在飞（把生成网表里的 `< 16'h0004` 收窄到 `< 16'h0001`）----
if grep -q "_zz__zz_axi_ar_valid_1 < 16'h0004" "$nl"; then
  sed "s/_zz__zz_axi_ar_valid_1 < 16'h0004/_zz__zz_axi_ar_valid_1 < 16'h0001/" "$nl" > "$work/DdrMaster_o1.v"
  if cmp -s "$nl" "$work/DdrMaster_o1.v"; then
    echo "JUDGE-RED[o1]: mutant 未产生差异（锚点失效）"; fail=1
  else
    run_one o1 "$work/DdrMaster_o1.v" || fail=1
  fi
else
  echo "JUDGE-RED[o1]: 网表里找不到 outstanding 上限锚点（生成式变了？）"; fail=1
fi

if [ "$fail" != "0" ]; then echo "VERDICT: RED（仿真未 PASS 或 mutant 未产生）"; exit 1; fi

check() {  # check <tag> <regex> <描述>
  if ! grep -Eq "$2" "$work/$1.log"; then
    echo "JUDGE-RED[$1]: $3 不满足（$2）"; return 1
  fi
  return 0
}
batch_line() { sed -n "s/^BATCH exp=$2 .*maxout=\([0-9]*\).*/\1/p" "$work/$1.log" | tail -1; }

check base '^RESULT: PASS' "base RESULT" || fail=1
check base '^MEM rd=384 wr=0 ' "base MEM rd" || fail=1
check base 'SG TOTAL .*tbfail=0' "base TB 负对照" || fail=1
check o1   '^RESULT: PASS' "o1 RESULT" || fail=1
check o1   '^MEM rd=384 wr=0 ' "o1 MEM rd" || fail=1

# 每批字节数（按 BATCH 行 exp= / rd_bytes= 交叉）
for pair in "32" "256" "96"; do
  check base "^BATCH exp=$pair .*rd_bytes=$pair " "base BATCH exp=$pair" || fail=1
done
b1="$(batch_line base 32)"
b8="$(batch_line base 256)"
b2="$(batch_line base 96)"
echo "   base maxout: N=1 -> ${b1:-?} / N=8 -> ${b8:-?} / N=2 -> ${b2:-?}"
[ -n "$b1" ] && [ "$b1" -eq 1 ] || { echo "JUDGE-RED: base N=1 maxout=${b1:-?} != 1"; fail=1; }
[ -n "$b8" ] && [ "$b8" -ge 2 ] || { echo "JUDGE-RED: base N=8 maxout=${b8:-?} < 2（没有多笔在飞）"; fail=1; }

o8="$(batch_line o1 256)"
o1b="$(batch_line o1 32)"
echo "   o1   maxout: N=1 -> ${o1b:-?} / N=8 -> ${o8:-?}"
[ -n "$o8" ] && [ "$o8" -eq 1 ] || { echo "JUDGE-RED[o1]: mutant N=8 maxout=${o8:-?} != 1（收窄没生效）"; fail=1; }
if [ -n "$o8" ] && [ "$o8" -ge 2 ]; then
  echo "JUDGE-RED[o1]: mutant 仍 >=2，MAXOUT 判据对 outstanding 不敏感"; fail=1
fi

# ---- 逐字节对账（正档 + mutant 都必须等于内存；证明 mutant 只丢并发、不丢数据）----
for t in base o1; do
  if ! cmp_bytes "$work/exp.hex" "$work/$t.out"; then
    echo "JUDGE-RED[$t]: 收流与内存不逐字节相同"; fail=1
  fi
done

# ---- 比较器自检：期望流翻 1 bit，对账必须变红 ----
"$PY" - "$work/exp.hex" "$work/exp_bad.hex" <<'PYEOF'
import sys
h = bytearray(open(sys.argv[1]).read().strip(), "ascii")
h[0] = ord('0') if h[0] != ord('0') else ord('1')
open(sys.argv[2], "w").write(h.decode())
PYEOF
if cmp_bytes "$work/exp_bad.hex" "$work/base.out" > "$work/selfcheck.log" 2>&1; then
  echo "JUDGE-RED: 比较器自检失败（翻 1 bit 仍判相等）"; fail=1
else
  echo "   selfcheck: 逐字节比较器可红（$(cat "$work/selfcheck.log")）"
fi

if [ "$fail" != "0" ]; then echo "VERDICT: RED"; exit 1; fi
echo "VERDICT: SG-OK（三批共 384 B 逐字节 == 内存；N=8 maxout=$b8 多笔在飞；mutant maxout=$o8 判据可红；比较器可红）"
echo "RESULT: PASS"
exit 0
