#!/bin/bash
# run_2d.sh —— gpu_2d 端到端像素闸门（命令回放 + 逐 8 B 字对黄金）
#   usage: bash sim/gpu/run_2d.sh [case ...]   默认 fill_rect round32 edge
set -u
cd "$(dirname "$0")/../.." || exit 9
CASES=${*:-"fill_rect blit565 glyph round32 scissor edge blit8"}
fail=0
for c in $CASES; do
  python3 sim/gpu/mk_hex.py --case "$c" --gold sim/gpu/gold >/dev/null || { echo "!! hex fail $c"; exit 3; }
  cat > sim/gpu/tb_cfg.svh <<EOF
\`define INIT_FILE "sim/gpu/gold/$c.init.hex"
\`define EXP_FILE  "sim/gpu/gold/$c.exp.hex"
\`define CMD_FILE  "sim/gpu/gold/$c.cmds.hex"
EOF
  rm -rf /tmp/obj_gpu_2d
  verilator --binary --timing -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-DECLFILENAME -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    -Isim/gpu -Irtl/gpu --top-module tb_gpu_2d \
    sim/gpu/tb_gpu_2d.v sim/gpu/axi_ram_model.v \
    rtl/gpu/gpu_cmd.v rtl/gpu/gpu_2d.v rtl/gpu/gpu_mem.v \
    -Mdir /tmp/obj_gpu_2d -o tb >/tmp/obj_gpu_2d_build.log 2>&1
  if [ $? -ne 0 ]; then
    echo "!! verilator build failed"; tail -20 /tmp/obj_gpu_2d_build.log; exit 3
  fi
  echo "== case $c =="
  /tmp/obj_gpu_2d/tb | tee "sim/reglogs/gpu_2d_$c.log" | grep -E "MISMATCH|PASS|FAIL|cmds_words" | head -12
  grep -q "2D PASS" "sim/reglogs/gpu_2d_$c.log" || fail=1
done
exit $fail
