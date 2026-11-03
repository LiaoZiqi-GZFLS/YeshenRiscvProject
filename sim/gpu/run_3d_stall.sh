#!/bin/bash
# run_3d_stall.sh —— 写口**背压**闸门：把 gpu_mem 的 wr_ready 按周期掐掉一部分，
#   验证 gpu_3d 的 tile 写回在 wr_ready 掉低时不会丢拍。
#
# 动因（2026-11-01）：`S_S1W/S_S2W` 原来只在下一拍撤 wr_valid、不看 wr_ready；
#   而 gpu_mem 的 wr_ready 平时**恒高**，所以既有闸门一条都覆盖不到这条路径。
#
# 用法：bash sim/gpu/run_3d_stall.sh [case ...]      默认 one comp
#       RTL3D=<别的 gpu_3d.v> bash ...              用替身 RTL 跑（A/B / 红臂）
set -u
cd "$(dirname "$0")/../.." || exit 9
CASES=${*:-"one comp"}
RTL3D=${RTL3D:-rtl/gpu/gpu_3d.v}
TAG=${TAG:-stall}
fail=0
for c in $CASES; do
  python3 sim/gpu/mk3d_case.py --case "$c" --out sim/gpu/gold3d >/dev/null || { echo "!! mk fail $c"; exit 3; }
  cat > sim/gpu/tri3d_cfg.svh <<CFG
\`define INIT_FILE "sim/gpu/gold3d/$c.ram.hex"
\`define EXP_FILE  "sim/gpu/gold3d/$c.exp.hex"
\`define CFG_FILE  "sim/gpu/gold3d/$c.cfg"
CFG
  obj="/tmp/obj_3ds_${TAG}_${c}"
  rm -rf "$obj"
  verilator --binary --timing -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-DECLFILENAME \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -DWSTALL -Isim/gpu -Irtl/gpu --top-module tb_gpu_3d \
    sim/gpu/tb_gpu_3d.v sim/gpu/axi_ram_model.v rtl/gpu/gpu_mem.v "$RTL3D" \
    rtl/gpu/tri_setup.v rtl/gpu/tri_raster.v \
    -Mdir "$obj" -o tb >"${obj}_build.log" 2>&1 || {
      echo "!! build failed ($c)"; tail -20 "${obj}_build.log"; exit 3; }
  echo "== case $c（RTL3D=$RTL3D）=="
  "$obj/tb" | tee "sim/reglogs/gpu_3d_${TAG}_$c.log" \
    | grep -E "wstall|MISMATCH|3D PASS|3D FAIL|3D TIMEOUT|TB-ERROR" | head -12
  grep -q "3D PASS" "sim/reglogs/gpu_3d_${TAG}_$c.log" || fail=1
done
exit $fail