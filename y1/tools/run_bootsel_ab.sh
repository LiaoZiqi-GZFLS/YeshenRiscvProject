#!/usr/bin/env bash
# =============================================================================
# run_bootsel_ab.sh —— 上电计划选择器 BootSel 单元闸门
#
# DUT = 从 rtl/YeshenSocGlue.v 切出的**真网表** module BootSel（含 io_timeout）。
# 判据：
#   1) BootSelTb 的 C/L/Z/超时 + owner/lineFree 行为全绿；
#   2) 提示串**离线解码**：TB 把 io_txd 每次跳变写进 bootsel_txd.log，本脚本按
#      8680 ns/位 解成 28B 串，4 个用例各一次，逐字节 == 期望串；
#   3) 负对照：把 `assign io_sel = selR;` 突变成常量 0 ⇒ 'C' 用例必须红。
# 退出码：0 全绿；1 判据不符；2 装置/网表自检失败。
# =============================================================================
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
net="$root/rtl/YeshenSocGlue.v"
tb="$root/y1/rtl_test/BootSelTb.v"
work="$(mktemp -d)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

find_tool() {
  local n="$1" p d
  p="$(command -v "$n" 2>/dev/null || true)"
  if [ -z "$p" ]; then
    for d in /c/msys64/ucrt64/bin /mingw64/bin /usr/bin; do
      [ -x "$d/$n" ] && { p="$d/$n"; break; }
    done
  fi
  printf '%s' "$p"
}
IVERILOG="$(find_tool iverilog)"
VVP="$(find_tool vvp)"
PY="${PY:-$(command -v python3 || command -v python)}"
[ -n "$IVERILOG" ] && [ -n "$VVP" ] || { echo "FATAL: 缺 iverilog/vvp"; exit 2; }
[ -f "$net" ] || { echo "FATAL: 缺 $net（先跑 sim/glue_pbus/gen_glue.sh）"; exit 2; }

awk '/^module BootSel\(/,/^endmodule/' "$net" > "$work/BootSel.v"
grep -q "io_timeout" "$work/BootSel.v" || { echo "FATAL: 切出的 BootSel 没有 io_timeout（网表过期？）"; exit 2; }
grep -q "assign io_sel = selR;" "$work/BootSel.v" || { echo "FATAL: 找不到 io_sel 赋值锚点"; exit 2; }
echo "[bootsel] 切出 $(wc -l < "$work/BootSel.v") 行"

run_one() { # run_one <verilog> <tag>
  local v="$1" tag="$2"
  "$IVERILOG" -g2012 -o "$work/$tag.vvp" "$v" "$tb" > "$work/$tag.iv" 2>&1 \
    || { echo "JUDGE-RED: iverilog 编译失败"; tail -20 "$work/$tag.iv"; return 2; }
  ( cd "$work" && "$VVP" "$tag.vvp" > "$tag.log" 2>&1 )
  local rc=$?
  grep -aE "^(CASE|TBFAIL|RESULT)" "$work/$tag.log" | sed 's/^/  /'
  return $rc
}

fails=0
echo "---- 正例（真网表）----"
run_one "$work/BootSel.v" pos || true
grep -q "^RESULT: PASS" "$work/pos.log" || { echo "JUDGE-RED: 正例未 PASS"; fails=$((fails+1)); }

echo "---- 提示串离线解码（8680 ns/位，115200）----"
"$PY" - "$work/bootsel_txd.log" <<'DECODE_PY'
import sys
BIT = 8680000.0  # iverilog $time 以 ps 计（timescale 1ns/1ps）
want = b"\r\n[Y1] L=Linux C=CoreMark > "
tr = []
for line in open(sys.argv[1], errors="replace"):
    p = line.split()
    if len(p) == 2:
        tr.append((int(p[0]), int(p[1])))
if not tr:
    print("DECODE_FAIL: empty tx log"); sys.exit(1)
def val_at(t):
    v = 1
    for tt, vv in tr:
        if tt <= t: v = vv
        else: break
    return v
out = bytearray()
t = 0
while True:
    fall = None
    for tt, vv in tr:
        if tt >= t and vv == 0:
            fall = tt; break
    if fall is None: break
    bits = 0
    for k in range(8):
        if val_at(fall + BIT * (1.5 + k)): bits |= 1 << k
    out.append(bits)
    t = fall + BIT * 10.0
print("DECODE: %d bytes" % len(out))
if len(out) != 4 * len(want):
    print("DECODE_FAIL: %d bytes != %d (want 4 prompts)" % (len(out), 4 * len(want))); sys.exit(1)
for i in range(4):
    chunk = bytes(out[i*len(want):(i+1)*len(want)])
    if chunk != want:
        print("DECODE_FAIL: prompt[%d]=%r want %r" % (i, chunk, want)); sys.exit(1)
print("DECODE_OK: 4/4 prompts byte-exact")
DECODE_PY
[ $? -eq 0 ] || fails=$((fails+1))

echo "---- 负对照（io_sel 强制 0 ⇒ 'C' 用例必须红）----"
"$PY" - "$work/BootSel.v" "$work/BootSel_mut.v" <<'MUT_PY'
import sys
s = open(sys.argv[1], errors='replace').read()
old = 'assign io_sel = selR;'
new = "assign io_sel = 1'b0;"
assert old in s, 'anchor missing'
open(sys.argv[2], 'w').write(s.replace(old, new, 1))
MUT_PY
run_one "$work/BootSel_mut.v" neg || true
if grep -q "^RESULT: FAIL" "$work/neg.log"; then
  echo "  NEG-OK：突变网表按期望翻红"
else
  echo "JUDGE-RED: 突变网表仍 PASS（闸门无鉴别力）"; fails=$((fails+1))
fi

if [ "$fails" -eq 0 ]; then
  echo "RESULT: PASS"
  exit 0
else
  echo "RESULT: FAIL（$fails 处）"
  exit 1
fi
