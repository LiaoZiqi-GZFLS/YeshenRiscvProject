#!/usr/bin/env bash
# =============================================================================
# rd_buf display-read latency margin gate
#
# Question: how much DDR read latency can the LCD line buffer tolerate before the
# panel shows stale pixels (= the "花" speckle seen on the integrated build)?
#
# Measured here with a latency-model TB (real rd_buf + behaviourally equivalent
# rd_fram_buf + real 1024x600@51.923MHz timing). The DDR model returns one 64-beat
# line read, LAT ddr_clk cycles (125 MHz) after the request; every 16-bit word
# carries the request index, so a displayed word identifies which line's data the
# panel is actually showing.
#
# Assertions (positive + negative control):
#   LAT=0     -> MISMATCH=0   (baseline framing / addressing correct)
#   LAT=3000  -> MISMATCH=0   (tolerates ~24 us, i.e. nearly one full display line)
#   LAT=3250  -> MISMATCH>0   (gate can fire: > 1 line => stale data lands on screen)
#
# The last one is the negative control: without it, "MISMATCH=0" would be
# indistinguishable from a checker that never fires.
#
# Usage: bash y1/tools/run_rdbuf_lat_ab.sh
# =============================================================================
set -u
cd "$(dirname "$0")/../.." || exit 2

RDBUF=board/cam/vendor/tutorial/rd_buf.v
MODEL=y1/tools/rdbuf_bram_model.v
TB=y1/tools/rdbuf_lat_tb.v

find_tool() {
  local n="$1" p d
  p="$(command -v "$n" 2>/dev/null)" && { echo "$p"; return 0; }
  for d in /c/tools/*/bin /c/iverilog/bin /usr/bin /usr/local/bin; do
    [ -x "$d/$n" ] && { echo "$d/$n"; return 0; }
  done
  return 1
}
IV=$(find_tool iverilog) || { echo "RESULT: FAIL (iverilog not found)"; exit 1; }
VV=$(find_tool vvp)       || { echo "RESULT: FAIL (vvp not found)"; exit 1; }

W=$(mktemp -d)
cp "$RDBUF" "$W/rd_buf.v"

run_lat() {
  local lat="$1" out
  "$IV" -g2005 -P "rdbuf_lat_tb.NFRAME=3" -P "rdbuf_lat_tb.LAT=$lat" \
        -o "$W/sim_$lat" "$W/rd_buf.v" "$MODEL" "$TB" 2>/dev/null || return 2
  out=$("$VV" "$W/sim_$lat" 2>/dev/null | grep '^TB ') || return 2
  echo "$out"
  echo "$out" | sed -n 's/.*MISMATCH=\([0-9]*\).*/\1/p'
}

fail=0
echo "== rd_buf DDR-read latency margin (lcd line = 1344 clk = 25.89 us = 3236 ddr clk) =="
for lat in 0 3000 3250; do
  line=$(run_lat "$lat"); rc=$?
  if [ $rc -ne 0 ]; then
    echo "[LAT=$lat] BUILD/RUN ERROR"; fail=1; continue
  fi
  mm=$(echo "$line" | sed -n 's/.*MISMATCH=\([0-9]*\).*/\1/p')
  echo "[LAT=$lat] $line"
  case "$lat" in
    0)    [ "$mm" -eq 0 ] || { echo "  !! expected 0 (baseline wrong)"; fail=1; } ;;
    3000) [ "$mm" -eq 0 ] || { echo "  !! expected 0 (margin < 3000 ddr clk)"; fail=1; } ;;
    3250) [ "$mm" -gt 0 ] || { echo "  !! negative control did NOT fire (checker is blind)"; fail=1; } ;;
  esac
done

if [ "$fail" -eq 0 ]; then
  echo "RESULT: PASS (tolerates <=~3150 ddr_clk ~= 25.2 us; >1 line goes red as it must)"
else
  echo "RESULT: FAIL"
fi
exit "$fail"
