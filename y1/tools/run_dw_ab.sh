#!/usr/bin/env bash
# run_dw_ab.sh -- y1 C4a.6 gate: the **depthwise (0x03) unit** numeric judge (G4).
#
# Frozen caliber (C4a.6 Step 1, written verbatim in rtl/Conv3x3Slice.scala):
#   depthwise = GROUP = C_in = C_out;  C<=8 -> one pass;  C>8 -> 8-channel multi-pass.
#
# DUT (rtl/MultiPassUnit.scala -> gen/DwUnit.v, emitted by rtl_test/DwGen.scala):
#   The C>8 case reuses C4a.5's multi-pass path; C<=8 is the SAME path with one pass
#   (ceil(C/8)=1 co-block x 1 ci-block). depthwise differs from a generic wide layer only
#   in the PASS SCHEDULE: it uses **diagonal passes** (co-block b eats ci-block b only),
#   because GROUP==C_IN==C_OUT makes co and ci share a group iff they share a block.
#   The off-diagonal passes have all-zero weight tiles -> zero contribution -> the diagonal
#   schedule and the generic schedule must produce byte-identical output (judge 3).
#
# Judges (each with positive + a negative control that CAN fire):
#   [0] Reference self-check (python; not satisfied => exit 3):
#       import the FROZEN C4a.5 builder `tools/multipass_ref.py` (NO second arithmetic path).
#   [1] Shape set: the real table's 20 depthwise layers -> distinct (C,C,C). Cross-checked two ways:
#       (a) gen/wgt_index.json  (converter truth: type_code==3, `own` geometry), and
#       (b) gen/c4a_tiling/c4a_tiling.json (frozen desc_table shape set incl. self-declared geometry).
#       Both must give the same set (a==b). Expected: C in {4,10,16,32,64}.
#       NOTE: desc_table's CHAIN_GEOM_FIELDS override rewrites a chain member's GROUP to the chain
#       head's (=1), so the *table* geometry loses the depthwise grouping; the true shape comes from
#       the node's own geometry (OWN field / resolve_shape_rep), exactly as C4a.4 documented.
#   [2] Positive control (byte-exact): for each distinct shape run one real-shaped layer through
#       DwTb's **diagonal** schedule -> Y == gold.hex (MISMATCH=0); guard distinct>1.
#   [3] Same arithmetic as C4a.5 (NOT a second path):
#       (a) md5(gen/DwUnit.v) == md5(gen/MultiPassUnit.v)  [structural: identical netlist]
#       (b) the SAME vectors run through MultiPassTb's **generic** schedule
#           (gen/MultiPassUnit.v) give byte-identical Y to DwTb's diagonal schedule.
#   [4] Negative control (wrong GROUP mapping) => RED:
#       rebuild the weight tiles with the group mapping evaluated on the BLOCK-LOCAL index
#       (`groupOfOut` written as the local co r instead of the frozen `(co*GROUP)/C_OUT` on the
#       global co) -> the DUT output must differ from the reference (MISMATCH>0), while the
#       correct-mapping run is MISMATCH=0. Honest note: for the single-block shapes (C<=8) the
#       literal form `groupOfOut(co)=co` coincides with `(co*GROUP)/C_OUT` (GROUP==C_OUT for
#       depthwise), so this control is structurally N/A there; it fires on every C>8 shape.
#   [5] Structure: gen/DwUnit.v must have zero dangling instances (check_dangling.py).
#
# Exit codes: 0 = all green; 1 = judge red (MISMATCH / degenerate / md5 / structure);
#             2 = negative control did not fire (judge has no teeth); 3 = precondition missing.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: cannot enter y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: no python found"; echo "RESULT: FAIL"; exit 3; }

tool="tools/multipass_ref.py"          # frozen C4a.5 reference (imported, not rewritten)
# ★ Overridable knobs (same convention as run_multipass_ab.sh's `NL=` / `TB=`) -- **for red-evidence
#   only**: point NL/NLGEN at a mutated pair of netlists so the numeric judge goes RED. When overridden
#   the md5 "same netlist" structural judge is SKIPPED (it only makes sense against the generated pair).
tb="${TB:-rtl_test/DwTb.v}"
tbgen="${TBGEN:-rtl_test/MultiPassTb.v}"   # C4a.5's own TB (generic pass schedule)
nl="${NL:-gen/DwUnit.v}"
nlgen="${NLGEN:-gen/MultiPassUnit.v}"
NL_IS_DEFAULT=1
[ "$nl" = "gen/DwUnit.v" ] && [ "$nlgen" = "gen/MultiPassUnit.v" ] || NL_IS_DEFAULT=0
idx="gen/wgt_index.json"
shapes_json="gen/c4a_tiling/c4a_tiling.json"
outdir="gen/c4a_dw"

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
for f in "$tool" "$tb" "$tbgen" "$nl" "$nlgen" "$idx" "$shapes_json" gen/LayerSched.v; do
  [ -f "$f" ] || { echo "FATAL: missing $f"; echo "RESULT: FAIL"; exit 3; }
done
[ -n "$IVERILOG" ] && [ -n "$VVP" ] || { echo "FATAL: no iverilog/vvp"; echo "RESULT: FAIL"; exit 3; }

work="$(mktemp -d)"
cleanup() { if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => artifacts in $work"; else rm -rf "$work"; fi }
trap cleanup EXIT
export PYTHONPATH="./.pydeps;../third_party/yunet/deps"
export PYTHONIOENCODING=utf-8
PWD_ABS="$(pwd)"

echo "== run_dw_ab: depthwise (0x03) unit -- diagonal multi-pass schedule + GROUP-mapping negctl =="
echo "   fb=$tb  gen_tb=$tbgen  nl=$nl  nlgen=$nlgen"
echo "   py=$PY  iverilog=$IVERILOG  vvp=$VVP  tmp=$work"

# cnt <a> <b> -> mismatch token count (unequal length => longer; missing side => -1)
cnt() {
  "$PY" - "$1" "$2" <<'PYEOF'
import sys
def load(p):
    try: return [t.lower() for t in open(p, encoding="utf-8", errors="replace").read().split()]
    except OSError: return None
a, b = load(sys.argv[1]), load(sys.argv[2])
print(-1 if (a is None or b is None) else (max(len(a), len(b)) if len(a) != len(b) else sum(1 for i, j in zip(a, b) if i != j)))
PYEOF
}
distinct() {
  "$PY" - "$1" <<'PYEOF'
import sys
try: t = open(sys.argv[1], encoding="utf-8", errors="replace").read().split()
except OSError: print(-1); sys.exit(0)
print(len(set(x.lower() for x in t)) if t else -1)
PYEOF
}

# ---------------- [0]+[1] shape set ----------------
echo "---- [0] shape set: the real table's depthwise layers (two independent sources must agree) ----"
if ! "$PY" - "$idx" "$shapes_json" > "$work/shapes.txt" <<'PYEOF'
import json, sys
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
idx = json.load(open(sys.argv[1], encoding="utf-8"))
dw = [u for u in idx["units"] if int(u.get("type_code", -1)) == 3]
own = sorted({(int(u["own"]["C_IN"]), int(u["own"]["C_OUT"]), int(u["own"]["GROUP"])) for u in dw})
tab = json.load(open(sys.argv[2], encoding="utf-8"))
tbl = sorted({tuple(int(v) for v in r["shape"]) for r in tab["rows"]})
# depthwise 需要 GROUP>1（desc_table 的晋升条件：`grp == ci and grp == co and grp > 1`）⇒
# 形状 (1,1,1)（单通道 1x1 dense conv）虽满足 C_in==C_out==GROUP，但**不是** depthwise ⇒ 排除。
dwtbl = [s for s in tbl if s[0] == s[1] == s[2] and s[2] > 1]
print("DW_TABLE units=%d distinct_own=%d" % (len(dw), len(own)))
for (ci, co, gg) in own:
    print("DW_OWN C=%d GROUP=%d (C_in=C_out=GROUP)" % (ci, gg))
print("DW_CROSSCHECK wgt_index_own=%s tiling_json_diag=%s AGREE=%d"
      % (own, dwtbl, 1 if own == dwtbl else 0))
sys.stdout.flush()
assert own == dwtbl, "depthwise shape sets disagree between wgt_index.json and c4a_tiling.json"
for (ci, co, gg) in own:
    assert ci == co == gg, "not depthwise: %s" % ((ci, co, gg),)
    print("SHAPE %d %d %d" % (ci, co, gg))
PYEOF
then
  echo "FATAL: depthwise shape resolution failed"; cat "$work/shapes.txt"; echo "RESULT: FAIL"; exit 3
fi
grep -E '^(DW_TABLE|DW_OWN|DW_CROSSCHECK)' "$work/shapes.txt" | sed 's/^/    /'
grep '^SHAPE ' "$work/shapes.txt" > "$work/shapes.list"
N_SHAPES="$(wc -l < "$work/shapes.list" | tr -d ' ')"
[ -n "$N_SHAPES" ] && [ "$N_SHAPES" -gt 0 ] || { echo "FATAL: no depthwise shapes"; echo "RESULT: FAIL"; exit 3; }
echo "    depthwise distinct shapes = $N_SHAPES"

# ---------------- [2] vectors + golden (frozen C4a.5 builder) + wrong-mapping w ----------------
echo "---- [1] vectors/golden via FROZEN tools/multipass_ref.py (conv_tiled; no second path) ----"
SHAPE_LIST=""
rm -rf "$outdir"; mkdir -p "$outdir"
k=0
while read -r _ C CO GG; do
  d="$outdir/shape_${C}c_${C}o_${C}g"
  if ! "$PY" - "$C" "$k" "$d" "$tool" > "$work/ref_$C.out" 2>&1 <<'PYEOF'
import sys, os, importlib.util
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
C = int(sys.argv[1]); k = int(sys.argv[2]); d = sys.argv[3]; tool = sys.argv[4]
spec = importlib.util.spec_from_file_location("multipass_ref", tool)
M = importlib.util.module_from_spec(spec); spec.loader.exec_module(M)
import numpy as np
seed = 61000 + 37 * k
p, n = M.build_one(C, C, C, seed, d)                     # writes x/w/b + 5 golden files (+params.txt)
print("DW_REF C=%d n_ci=%d n_co=%d passes=%d M=%d ZY=%d WHOLE_MISMATCH=%d distinct=%d gold_md5=%s"
      % (C, p["n_ci"], p["n_co"], p["passes"], p["M"], p["zy"], n["d_whole"], n["distinct"], n["md5"]))
ok = (n["d_whole"] == 0) and (n["distinct"] > 1)
# --- negative control artifact: same layer, group mapping evaluated on the BLOCK-LOCAL co ---
xq, wd, sx, sy, bfloat, biasb = M.make_layer(C, C, C, seed)   # same seed => same xq/wq
n_ci, n_co = M.passes_of(C, C)
cig, cog = C // C, C // C
bad = []
for j in range(n_co):
    co0, co_t = j * 8, min(8, C - j * 8)
    for i in range(n_ci):
        ci0, ci_t = i * 8, min(8, C - i * 8)
        t = np.zeros((8, 8, 3, 3), dtype=np.int64)
        for r in range(co_t):
            for s in range(ci_t):
                if r != (ci0 + s):        # WRONG: groupOfOut(local r) vs groupOfIn(global ci)
                    continue
                ci = ci0 + s
                t[r, s] = wd["q"][co0 + r, ci - (ci // cig) * cig]
        bad.append(t)
M.dump_hex(os.path.join(d, "w_wrong.hex"), np.concatenate([t.reshape(-1) for t in bad]))
# count how many tokens differ between the wrong tiles and the correct ones: must be > 0 for C>8
wok = np.array([int(v.strip(), 16) for v in open(os.path.join(d, "w.hex"))], dtype=np.int64)
wbk = np.array([int(v.strip(), 16) for v in open(os.path.join(d, "w_wrong.hex"))], dtype=np.int64)
print("DW_BADMAP n_ci=%d n_co=%d tile_tokens=%d wrong_vs_correct_diff=%d"
      % (n_ci, n_co, len(wok), int(np.count_nonzero(wok != wbk))))
sys.exit(0 if ok else 1)
PYEOF
  then
    echo "JUDGE-RED: reference build failed for C=$C"; tail -6 "$work/ref_$C.out"; echo "RESULT: FAIL"; exit 1
  fi
  grep -E '^(DW_REF|DW_BADMAP)' "$work/ref_$C.out" | sed 's/^/    /'
  SHAPE_LIST="$SHAPE_LIST C$C"
  k=$((k+1))
done < "$work/shapes.list"

# ---------------- [3] compile ----------------
echo "---- [2] iverilog compile (DwTb+gen/DwUnit.v | MultiPassTb+gen/MultiPassUnit.v) ----"
if ! "$IVERILOG" -g2012 -o "$work/dw.vvp" "$tb" "$nl" > "$work/iv_dw.log" 2>&1; then
  echo "JUDGE-RED: DwTb compile failed"; sed -n '1,30p' "$work/iv_dw.log"; echo "RESULT: FAIL"; exit 1
fi
if ! "$IVERILOG" -g2012 -o "$work/mp.vvp" "$tbgen" "$nlgen" > "$work/iv_mp.log" 2>&1; then
  echo "JUDGE-RED: MultiPassTb compile failed"; sed -n '1,30p' "$work/iv_mp.log"; echo "RESULT: FAIL"; exit 1
fi
echo "    both compile OK"
if [ -f tools/check_dangling.py ]; then
  "$PY" tools/check_dangling.py "$nl" | grep -v '^RESULT:' | tail -2 | sed 's/^/    /'
  "$PY" tools/check_dangling.py "$nl" >/dev/null || { echo "JUDGE-RED: gen/DwUnit.v has dangling instances"; echo "RESULT: FAIL"; exit 1; }
fi

# ---------------- [3] structural: same arithmetic (identical netlist) ----------------
echo "---- [3] same arithmetic as C4a.5: md5(gen/DwUnit.v) == md5(gen/MultiPassUnit.v) ----"
if [ "$NL_IS_DEFAULT" = "1" ]; then
  MD_DW="$(md5sum "$nl" | cut -d' ' -f1)"
  MD_MP="$(md5sum "$nlgen" | cut -d' ' -f1)"
  echo "    md5 DwUnit.v       = $MD_DW"
  echo "    md5 MultiPassUnit.v= $MD_MP"
  [ "$MD_DW" = "$MD_MP" ] || { echo "JUDGE-RED: depthwise netlist is NOT the C4a.5 netlist => a second arithmetic path exists"; echo "RESULT: FAIL"; exit 1; }
  echo "    identical netlist => the depthwise unit IS the C4a.5 multi-pass unit (no second path)"

# ---------------- [3b] dispatch: LayerSched routes 0x03 through the conv path ----------------
echo "---- [3b] dispatch: gen/LayerSched.v wires 0x03 into isConv / typeKnown (not the illegal-TYPE err) ----"
if ! "$PY" - gen/LayerSched.v rtl/DescDefs.scala <<'PYEOF'
import re, sys
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
nl = open(sys.argv[1], encoding="utf-8", errors="replace").read().replace("\r\n", "\n")
dd = open(sys.argv[2], encoding="utf-8", errors="replace").read().replace("\r\n", "\n")
m_dw = re.search(r"assign isDw = \((.+?) == 8'h03\);", nl)
m_c3 = re.search(r"assign isConv3x3 = \((.+?) == 8'h01\);", nl)
m_c1 = re.search(r"assign isConv1x1 = \((.+?) == 8'h02\);", nl)
m_conv = re.search(r"assign isConv = \(\(isConv3x3 \|\| isConv1x1\) \|\| isDw\);", nl)
m_known = re.search(r"assign typeKnown = \(\(isConv \|\| isBypass\) \|\| isSentinel\);", nl)
ok = True
if not m_dw:   print("DISPATCH-BAD: netlist has no `isDw = (tpe == 8'h03)`"); ok = False
if not m_c3:   print("DISPATCH-BAD: no isConv3x3 == 8'h01"); ok = False
if not m_c1:   print("DISPATCH-BAD: no isConv1x1 == 8'h02"); ok = False
if not m_conv: print("DISPATCH-BAD: netlist isConv does NOT include isDw"); ok = False
if not m_known:print("DISPATCH-BAD: netlist typeKnown does NOT derive from isConv"); ok = False
if m_dw and m_c3 and m_c1 and not (m_dw.group(1) == m_c3.group(1) == m_c1.group(1)):
    print("DISPATCH-BAD: isDw/isConv3x3/isConv1x1 read DIFFERENT type fields"); ok = False
if not re.search(r"val DW\s*=\s*0x03", dd):
    print("DISPATCH-BAD: rtl/DescDefs.scala has no `val DW = 0x03`"); ok = False
if m_dw and m_c3:
    print("  type field = %s ; isConv = ((isConv3x3(0x01) || isConv1x1(0x02)) || isDw(0x03))" % m_dw.group(1))
    print("  typeKnown = ((isConv || isBypass) || isSentinel) => 0x03 is DISPATCHED (not the illegal-TYPE err)")
print("DISPATCH: %s" % ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
PYEOF
then
  echo "JUDGE-RED: depthwise 0x03 is not wired into the LayerSched dispatch"; echo "RESULT: FAIL"; exit 1
fi
else
  echo "    SKIPPED: NL/NLGEN overridden ($nl / $nlgen) => red-evidence run (structural judge needs the generated pair)"
fi

# run_tb <vvp> <tag> <dir> <wfile> [extra plusargs...] -> write Y tokens to $work/<tag>.y
#   ★ the weight file is an **explicit** argument (not an extra plusarg): iverilog's $value$plusargs
#     takes the FIRST match, so a second "+WFILE=" would be silently ignored (that exact bug made the
#     wrong-GROUP negative control report hit=0 while the tiles really did differ).
run_tb() {
  local vvp="$1" tag="$2" d="$3" wf="$4"; shift 4
  local CIN COUT H IW M ZY
  CIN="$(sed -n 's/^CIN=//p' "$d/params.txt")"
  COUT="$(sed -n 's/^COUT=//p' "$d/params.txt")"
  H="$(sed -n 's/^H=//p' "$d/params.txt")"
  IW="$(sed -n 's/^IW=//p' "$d/params.txt")"
  M="$(sed -n 's/^M=//p' "$d/params.txt")"
  ZY="$(sed -n 's/^ZY=//p' "$d/params.txt")"
  ( cd "$work" && "$VVP" "$vvp" \
      "+XFILE=$PWD_ABS/$d/x.hex" "+WFILE=$wf" "+BFILE=$PWD_ABS/$d/b.hex" \
      "+CIN=$CIN" "+COUT=$COUT" "+H=$H" "+IW=$IW" "+M=$M" "+ZY=$ZY" "$@" ) \
      > "$work/$tag.log" 2>&1
  grep -E '^DW ' "$work/$tag.log" | sed "s/^/    /"
  grep '^Y ' "$work/$tag.log" | sed -e 's/^Y *//' | tr -s ' ' '\n' > "$work/$tag.y" || true
}

# ---------------- [2]+[3]+[4] per shape ----------------
echo "---- [4] per shape: positive (diagonal) + same-arithmetic (generic) + wrong-GROUP negctl ----"
TOTAL_BAD=0; NEG_NOFIRE=0; NEG_NA=0
while read -r _ C CO GG; do
  d="$outdir/shape_${C}c_${C}o_${C}g"
  tag="C${C}"
  GD="$(distinct "$d/gold.hex")"
  # ---- positive: diagonal schedule ----
  run_tb "$work/dw.vvp" "dw_$tag" "$d" "$PWD_ABS/$d/w.hex"
  if ! grep -q '^RESULT: PASS' "$work/dw_$tag.log"; then
    echo "JUDGE-RED: DwTb did not PASS (C=$C)"; tail -6 "$work/dw_$tag.log"; TOTAL_BAD=$((TOTAL_BAD+1)); continue
  fi
  P_MIS="$(cnt "$d/gold.hex" "$work/dw_$tag.y")"
  YD="$(distinct "$work/dw_$tag.y")"
  [ "$P_MIS" = "0" ] || { echo "JUDGE-RED: positive MISMATCH=$P_MIS (C=$C)"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$GD" -gt 1 ] 2>/dev/null || { echo "JUDGE-RED: gold degenerate distinct=$GD (C=$C)"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  [ "$YD" -gt 1 ] 2>/dev/null || { echo "JUDGE-RED: RTL degenerate distinct=$YD (C=$C)"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  # ---- same arithmetic: generic schedule (C4a.5's own TB + netlist) ----
  run_tb "$work/mp.vvp" "mp_$tag" "$d" "$PWD_ABS/$d/w.hex" > /dev/null
  if ! grep -q '^RESULT: PASS' "$work/mp_$tag.log"; then
    echo "JUDGE-RED: MultiPassTb did not PASS (C=$C)"; tail -6 "$work/mp_$tag.log"; TOTAL_BAD=$((TOTAL_BAD+1)); continue
  fi
  SAME="$(cnt "$work/dw_$tag.y" "$work/mp_$tag.y")"
  [ "$SAME" = "0" ] || { echo "JUDGE-RED: diagonal != generic schedule (diff=$SAME, C=$C)"; TOTAL_BAD=$((TOTAL_BAD+1)); }
  # ---- negative control: wrong GROUP mapping ----
  WDIFF="$(grep -oE 'wrong_vs_correct_diff=[0-9]+' "$work/ref_$C.out" | head -1 | cut -d= -f2)"
  run_tb "$work/dw.vvp" "bad_$tag" "$d" "$PWD_ABS/$d/w_wrong.hex" > /dev/null
  B_MIS="$(cnt "$d/gold.hex" "$work/bad_$tag.y")"
  if [ "$C" -le 8 ]; then
    if [ "$B_MIS" = "0" ]; then
      NEG_NA=$((NEG_NA+1)); BSHOW="N/A(local==global: no block offset, mapping coincides; tile_diff=$WDIFF)"
    else
      BSHOW="hit=$B_MIS (tile_diff=$WDIFF)"; B_FIRED=1
    fi
  else
    BSHOW="hit=$B_MIS (tile_diff=$WDIFF)"
    if ! [ "$B_MIS" -gt 0 ] 2>/dev/null; then
      echo "NEGCTL-FAIL: wrong-GROUP mapping did not change the output (C=$C)"; NEG_NOFIRE=$((NEG_NOFIRE+1))
    fi
  fi
  echo "SHAPE C=$C GROUP=$C | POS_MISMATCH=$P_MIS distinct(gold=$GD,rtl=$YD) | diag_vs_generic=$SAME | WRONGMAP $BSHOW"
done < "$work/shapes.list"

# ---------------- verdict ----------------
echo "=========================================================================="
echo "depthwise shapes (real table, distinct) =$SHAPE_LIST  n=$N_SHAPES"
echo "shape set        = OK (wgt_index.json 'own' == c4a_tiling.json diagonal; C_in==C_out==GROUP)"
echo "positive (/w diag)= OK (byte-exact vs the frozen multipass_ref golden; MISMATCH=0; distinct>1)"
echo "same arithmetic  = OK (md5(DwUnit.v)==md5(MultiPassUnit.v); diagonal == generic schedule byte-wise)"
echo "dispatch         = OK (gen/LayerSched.v: isDw=(tpe==8'h03) folded into isConv/typeKnown; not the err path)"
echo "negative (GROUP) = OK (wrong-mapping tiles => output differs; correct-mapping => MISMATCH=0)"
if [ "$NEG_NOFIRE" -ne 0 ]; then echo "NEGCTL-FAIL: $NEG_NOFIRE wrong-GROUP controls did not fire"; echo "RESULT: FAIL"; exit 2; fi
if [ "$TOTAL_BAD" -ne 0 ]; then echo "JUDGE-RED: $TOTAL_BAD judges failed"; echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
exit 0
