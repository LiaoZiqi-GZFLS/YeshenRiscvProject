#!/bin/bash
# run_3d_ab.sh —— P2a 3D 子系统闸门（CLEAR3D + DRAW_TRIS 逐像素对黄金）
#   usage: bash sim/gpu/run_3d_ab.sh [case ...]   默认 one zoccl span
set -u
cd "$(dirname "$0")/../.." || exit 9
CASES=${*:-"one zoccl span comp comp4"}
fail=0
for c in $CASES; do
  python3 sim/gpu/mk3d_case.py --case "$c" --out sim/gpu/gold3d >/dev/null || { echo "!! mk fail $c"; exit 3; }
  cat > sim/gpu/tri3d_cfg.svh <<CFG
\`define INIT_FILE "sim/gpu/gold3d/$c.ram.hex"
\`define EXP_FILE  "sim/gpu/gold3d/$c.exp.hex"
\`define CFG_FILE  "sim/gpu/gold3d/$c.cfg"
CFG
  rm -rf /tmp/obj_gpu_3d
  verilator --binary --timing -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-DECLFILENAME \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Isim/gpu -Irtl/gpu --top-module tb_gpu_3d \
    sim/gpu/tb_gpu_3d.v sim/gpu/axi_ram_model.v rtl/gpu/gpu_mem.v rtl/gpu/gpu_3d.v \
    rtl/gpu/tri_setup.v rtl/gpu/tri_raster.v ${TRUNC:-} \
    -Mdir ${OBJ:-/tmp/obj_gpu_3d} -o tb >${OBJ:-/tmp/obj_gpu_3d}_build.log 2>&1
  if [ $? -ne 0 ]; then echo "!! build failed ($c)"; tail -25 ${OBJ:-/tmp/obj_gpu_3d}_build.log; exit 3; fi
  echo "== case $c =="
  ${OBJ:-/tmp/obj_gpu_3d}/tb | tee "sim/reglogs/gpu_3d_$c.log" | grep -E "MISMATCH|3D PASS|3D FAIL|3D TIMEOUT|TB-ERROR" | head -10
  grep -q "3D PASS" "sim/reglogs/gpu_3d_$c.log" || fail=1
done
exit $fail
