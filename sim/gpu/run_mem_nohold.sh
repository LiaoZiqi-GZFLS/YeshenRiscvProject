#!/bin/bash
# run_mem_nohold.sh —— 用**简化 AXI 从方**（不等 rready、逐拍推进）跑 gpu_mem 读闸门，
# 用来离线复现"板上读 burst 丢头几拍"的现象。
set -u
cd "$(dirname "$0")/../.." || exit 9
OD=sim/reglogs/obj_gpu_mem_nh
mkdir -p "$OD"
verilator --binary --timing -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-DECLFILENAME \
  -DRAM_NO_HOLD -Isim/gpu -Irtl/gpu --top-module tb_gpu_mem \
  sim/gpu/tb_gpu_mem.v sim/gpu/axi_ram_model.v rtl/gpu/gpu_mem.v \
  -Mdir "$OD" -o tb >"$OD/build.log" 2>&1
rc=$?
if [ $rc -ne 0 ]; then echo "!! verilator build failed rc=$rc"; tail -20 "$OD/build.log"; exit 3; fi
"$OD/tb" | tee sim/reglogs/gpu_mem_nohold.log
grep -q "MEM PASS" sim/reglogs/gpu_mem_nohold.log
