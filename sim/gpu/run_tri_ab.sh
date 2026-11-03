#!/bin/bash
# run_tri_ab.sh —— P2a 光栅单元闸门：tri_setup + tri_raster 逐像素对 C 黄金
#   usage: bash sim/gpu/run_tri_ab.sh [case ...]   默认七例
set -u
cd "$(dirname "$0")/../.." || exit 9
CASES=${*:-"single two_z zswap zlequal zneg offscreen edge_hit"}
fail=0
for c in $CASES; do
  python3 sim/gpu/tri_ref.py --case "$c" --out sim/gpu/gold3d >/dev/null || { echo "!! gold fail $c"; exit 3; }
  cat > sim/gpu/tri_cfg.svh <<EOF
\`define TRI_FILE "sim/gpu/gold3d/$c.tri.hex"
\`define EXP_FILE "sim/gpu/gold3d/$c.exp.hex"
EOF
  rm -rf /tmp/obj_tri
  verilator --binary --timing -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-DECLFILENAME \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -DDBG=${DBG:-0} \
    -Isim/gpu -Irtl/gpu --top-module tb_tri_raster \
    sim/gpu/tb_tri_raster.v rtl/gpu/tri_setup.v rtl/gpu/tri_raster.v \
    -Mdir /tmp/obj_tri -o tb >/tmp/obj_tri_build.log 2>&1
  if [ $? -ne 0 ]; then
    echo "!! verilator build failed ($c)"; tail -25 /tmp/obj_tri_build.log; exit 3
  fi
  echo "== case $c =="
  /tmp/obj_tri/tb | tee "sim/reglogs/tri_$c.log" | grep -E "MISMATCH|TRI PASS|TRI FAIL|TIMEOUT|TB-ERROR" | head -10
  grep -q "TRI PASS" "sim/reglogs/tri_$c.log" || fail=1
done
exit $fail
