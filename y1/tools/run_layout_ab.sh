#!/usr/bin/env bash
# run_layout_ab.sh -- y1 C4a.7 gate: layout ops (Transpose/Reshape) folded into ADDRESSING (G5).
#
# Why: YuNet has 12 Transpose + 12 Reshape between layers. If they were executed as real units
# they would (a) need descriptor entries and (b) move the tensor through DDR (read + write).
# C4a.7 folds them into the consumer's addressing: the consumer reads the producer's LINEAR DDR
# buffer directly through `(src_stride, src_order)` -- no unit, no extra DDR traffic.
#
# Judged (python: `tools/y1_convert.py --layout`, whose fold caliber == `compute_layout_fold`):
#   [1] EQUIV (criterion 1): for EVERY position carrying Transpose/Reshape, reading the source
#       through the folded `(src_stride, src_order)` == the explicit transpose/reshape reference,
#       BYTE-EXACT (id-permutation + int8 pattern). `LAYOUT_EQUIV ... MISMATCH_total=0`.
#   [2] TRAFFIC (criterion 2): the folded layout ops move `0` DDR bytes; the "not folded" control
#       (each op as an explicit unit: read in + write out) moves `2*sum(numel)` bytes. BOTH numbers
#       are printed. `not_increased=1` (folded <= unfolded). Caliber reuses FROZEN `ddr_traffic`
#       GraphView (int8, 1 byte/elem).
#   [3] NEGCTL (criterion 3): reversing `src_order` at each order-driven position must go RED
#       (rebuilt addressing != explicit reference). `NEGCTL_LAYOUT_ORDER reversible=N fired=N`.
#   [0] NO UNITS: the descriptor payload node count == the frozen 67 (sum of the C3 TYPE histogram);
#       zero layout ops in the payload. `LAYOUT_NO_UNITS payload_nodes=67 layout_in_payload=0`.
#   plus an external anchor: the recomputed fold == the persisted `gen/wgt_index.json.layout_fold`.
#
# Red evidence (proves the judges are not rubber stamps; run against the same tool):
#   `--layout --inject nobadorder` => the reverse-order negative control is disabled => FIRED=0
#   => exit code MUST be 2.
#
# Exit codes: 0 = PASS; 1 = judge red; 2 = negative control did not fire; 3 = precondition missing.
#
# Usage: bash y1/tools/run_layout_ab.sh   (override interpreter with PY=<python>)
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: cannot enter y1/"; echo "RESULT: FAIL"; exit 3; }

tool="tools/y1_convert.py"
onnx="../third_party/yunet/yunet.onnx"
idx="gen/wgt_index.json"
pydeps="./.pydeps"                 # numpy 2.0.2 / onnx 1.19.1 / onnxruntime 1.19.2
deps="../third_party/yunet/deps"

[ -f "$tool" ] || { echo "FATAL: missing $tool"; echo "RESULT: FAIL"; exit 3; }
[ -f "$onnx" ] || { echo "FATAL: missing model $onnx"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: no python found"; echo "RESULT: FAIL"; exit 3; }

export PYTHONPATH="$pydeps;$deps"
export PYTHONIOENCODING=utf-8

work="$(mktemp -d)"
cleanup() { if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => keeping $work"; else rm -rf "$work"; fi; }
trap cleanup EXIT

echo "== run_layout_ab: Transpose/Reshape folded into (src_stride, src_order) -- G5 =="
echo "   tool=$tool"
echo "   onnx=$onnx"
echo "   py  =$PY"
echo "   tmp =$work"

# Rebuild the persisted index once if it is absent (the fold is cross-checked against it).
if [ ! -f "$idx" ]; then
  echo "   $idx absent => regenerating with --gate ..."
  "$PY" "$tool" --gate > "$work/gate_seed.out" 2>&1 \
    || { echo "FATAL: failed to seed $idx"; tail -8 "$work/gate_seed.out"; echo "RESULT: FAIL"; exit 3; }
fi

# ---------------- [1] main run: fold == explicit + traffic + negative control ----------------
"$PY" "$tool" --layout > "$work/lay.out" 2> "$work/lay.err"
rc=$?
echo "---- [1] y1_convert.py --layout (fold == explicit + traffic + reverse-order negctl) ----"
grep -vE '^(LAYOUT_POS|LAYOUT_TRAFFIC_OP|NEGCTL_LAYOUT_ORDER_DETAIL) ' "$work/lay.out"
[ -s "$work/lay.err" ] && sed -n '1,20p' "$work/lay.err" >&2

if [ "$rc" -eq 3 ]; then echo "JUDGE-RED: precondition missing (rc=3)"; echo "RESULT: FAIL"; exit 3; fi
if [ "$rc" -eq 2 ]; then echo "NEGCTL-FAIL: negative control did not fire (rc=2)"; echo "RESULT: FAIL"; exit 2; fi

# ---- extract each judge (do NOT trust the RESULT blurb alone) ----
fail() { echo "JUDGE-RED: $1"; echo "RESULT: FAIL"; exit 1; }
if [ "$rc" -ne 0 ] || ! grep -q '^RESULT: PASS$' "$work/lay.out"; then
  fail "layout judge did not pass (rc=$rc)"
fi
grep -q '^LAYOUT_FOLD entries=18 ops_transpose=12 ops_reshape=12 ' "$work/lay.out" \
  || fail "expected 18 layout positions (12 Transpose + 12 Reshape)"
grep -q '^LAYOUT_EQUIV entries=18 byte_exact=18 MISMATCH_total=0 ' "$work/lay.out" \
  || fail "criterion 1: folded addressing != explicit transpose reference (byte-exact)"
grep -q '^LAYOUT_TRAFFIC_FOLDED read=0 write=0 total=0$' "$work/lay.out" \
  || fail "criterion 2: folding must move 0 DDR bytes"
grep -qE '^LAYOUT_TRAFFIC_UNFOLDED read=[0-9]+ write=[0-9]+ total=[1-9][0-9]*$' "$work/lay.out" \
  || fail "criterion 2: the 'not folded' control must move >0 bytes"
grep -q '^LAYOUT_TRAFFIC .* not_increased=1$' "$work/lay.out" \
  || fail "criterion 2: folding INCREASED the DDR read+write bytes"
grep -q '^NEGCTL_LAYOUT_ORDER reversible=12 fired=12 ' "$work/lay.out" \
  || fail "criterion 3: reversing src_order did not go RED on every order-driven position"
grep -q '^LAYOUT_NO_UNITS payload_nodes=67 expected=67 layout_in_payload=0 ' "$work/lay.out" \
  || fail "layout ops leaked into the descriptor payload (they must be folded, not units)"
grep -q '^LAYOUT_INDEX_AGREE ok=1 entries=18 recomputed=18 ' "$work/lay.out" \
  || fail "recomputed fold != persisted gen/wgt_index.json.layout_fold"

F_TOT="$(grep -oE '^LAYOUT_TRAFFIC_FOLDED .*' "$work/lay.out" | sed -E 's/.*total=//')"
U_TOT="$(grep -oE '^LAYOUT_TRAFFIC_UNFOLDED .*' "$work/lay.out" | sed -E 's/.*total=//')"
N_FOLD="$(grep -oE '^NEGCTL_LAYOUT_ORDER reversible=[0-9]+' "$work/lay.out" | sed -E 's/.*=//')"
N_FIRE="$(grep -oE '^NEGCTL_LAYOUT_ORDER .*fired=[0-9]+' "$work/lay.out" | sed -E 's/.*fired=//')"
echo "   判据 1 OK：18 个位置（12 Transpose + 12 Reshape）折进 (src_stride, src_order) == 显式参考（逐字节）"
echo "   判据 2 OK：折进搬运 total=$F_TOT B  vs  不折进 total=$U_TOT B（不增）"
echo "   判据 3 OK：反转 src_order  $N_FIRE/$N_FOLD  位置发火"

# ---------------- [2] determinism: two runs give identical fold/traffic fingerprints ----------------
key() { grep -E '^(LAYOUT_FOLD|LAYOUT_EQUIV|LAYOUT_TRAFFIC |LAYOUT_TRAFFIC_FOLDED|LAYOUT_TRAFFIC_UNFOLDED|LAYOUT_TRAFFIC_NET |NEGCTL_LAYOUT_ORDER |LAYOUT_NO_UNITS|LAYOUT_INDEX_AGREE) ' "$1"; }
key "$work/lay.out" > "$work/key_a.txt"
"$PY" "$tool" --layout > "$work/lay2.out" 2>&1
key "$work/lay2.out" > "$work/key_b.txt"
if ! diff -q "$work/key_a.txt" "$work/key_b.txt" > /dev/null; then
  echo "  fingerprint A:"; sed -n '1,12p' "$work/key_a.txt"
  echo "  fingerprint B:"; sed -n '1,12p' "$work/key_b.txt"
  fail "two runs gave different fold/traffic fingerprints (non-deterministic)"
fi
echo "---- [2] determinism: two runs give identical fold/traffic fingerprints ----"
sed 's/^/   /' "$work/key_a.txt"

# ---------------- [3] red evidence: disabling the negctl must make the judge go RED (rc=2) --------
"$PY" "$tool" --layout --inject nobadorder > "$work/red.out" 2>&1
r2=$?
if [ "$r2" -ne 2 ] || ! grep -q '^NEGCTL_LAYOUT_ORDER .*fired=0' "$work/red.out"; then
  echo "NO-RED: --inject nobadorder did not make the negctl judge go RED (rc=$r2)"
  echo "RESULT: FAIL"; exit 1
fi
echo "---- [3] red evidence: --inject nobadorder => NEGCTL_LAYOUT_ORDER fired=0, rc=$r2 ----"
grep -E '^(NEGCTL_LAYOUT_ORDER |NEGCTL-FAIL|JUDGE-RED)' "$work/red.out" | sed 's/^/    /'

# ---------------- verdict ----------------
echo "=========================================================================="
echo "layout fold (C4a.7 / G5):"
echo "  positions  = 18 (Transpose 12 + Reshape 12; 12 source tensors) folded into (src_stride, src_order)"
echo "  criterion 1= folded addressing == explicit transpose/reshape reference, BYTE-EXACT (MISMATCH_total=0)"
echo "  criterion 2= DDR read+write: folded total=$F_TOT B  vs  not-folded total=$U_TOT B  =>  NOT increased"
echo "  criterion 3= reversed src_order => RED on $N_FIRE/$N_FOLD order-driven positions"
echo "  no units   = payload_nodes=67 (frozen) with 0 layout ops in the descriptor payload"
echo "  anchor     = recomputed fold == gen/wgt_index.json.layout_fold (18 entries)"
echo "  red evidence= --inject nobadorder => negctl FIRED=0 => rc=2 (judge has teeth)"
echo "  determinism = two runs give identical fold/traffic fingerprints"
echo "RESULT: PASS"
exit 0
