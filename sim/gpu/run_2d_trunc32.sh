#!/bin/bash
# run_2d_trunc32.sh —— 同 run_2d.sh，但把 DDR 模型换成**板级 32 B 粒度**（TRUNC32=1）：
#   · 读/写突发的起始地址按 32 B 块向下取整（数据口 256 bit = 32 B/拍）
#   · 8 B 粒度但非 32 B 对齐的突发会整段下移 —— 板级 gpu9 的实测现象
#
# usage:
#   bash sim/gpu/run_2d_trunc32.sh [case ...]
#   GPU_MEM_OVERRIDE=/path/to/old_gpu_mem.v bash sim/gpu/run_2d_trunc32.sh blit8   # 红臂
set -u
cd "$(dirname "$0")/../.." || exit 9
CASES=${*:-"fill_rect blit565 glyph round32 scissor edge blit8"}
MEM=${GPU_MEM_OVERRIDE:-rtl/gpu/gpu_mem.v}
OBJ=${OBJ:-/tmp/obj_gpu_2d_t32}
TAG=$(basename "$MEM" .v)
fail=0
echo "[t32] gpu_mem = $MEM"
for c in $CASES; do
  python3 sim/gpu/mk_hex.py --case "$c" --gold sim/gpu/gold >/dev/null || { echo "!! hex fail $c"; exit 3; }
  cat > sim/gpu/tb_cfg.svh <<EOF
\`define INIT_FILE "sim/gpu/gold/$c.init.hex"
\`define EXP_FILE  "sim/gpu/gold/$c.exp.hex"
\`define CMD_FILE  "sim/gpu/gold/$c.cmds.hex"
EOF
  rm -rf "$OBJ"
  verilator --binary --timing -DRAM_TRUNC32 -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-DECLFILENAME \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    -Isim/gpu -Irtl/gpu --top-module tb_gpu_2d \
    sim/gpu/tb_gpu_2d.v sim/gpu/axi_ram_model.v \
    rtl/gpu/gpu_cmd.v rtl/gpu/gpu_2d.v "$MEM" \
    -Mdir "$OBJ" -o tb >"$OBJ.build.log" 2>&1
  if [ $? -ne 0 ]; then
    echo "!! verilator build failed"; tail -20 "$OBJ.build.log"; exit 3
  fi
  echo "== case $c =="
  "$OBJ/tb" | tee "sim/reglogs/gpu_2d_t32_${TAG}_$c.log" | grep -E "MISMATCH|PASS|FAIL|cmds_words" | head -12
  grep -q "2D PASS" "sim/reglogs/gpu_2d_t32_${TAG}_$c.log" || fail=1
done
exit $fail
