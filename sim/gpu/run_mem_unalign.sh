#!/bin/bash
# run_mem_unalign.sh —— gpu_mem 读引擎「32 B 对齐取数 + 丢前导拍」闸门（pad=0/1/3 + 负对照）
set -u
cd "$(dirname "$0")/../.." || exit 9
mkdir -p /tmp/obj_gpu_mem_un
verilator --binary --timing -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-DECLFILENAME \
  -Isim/gpu -Irtl/gpu --top-module tb_gpu_mem_unalign \
  sim/gpu/tb_gpu_mem_unalign.v sim/gpu/axi_ram_model.v rtl/gpu/gpu_mem.v \
  -Mdir /tmp/obj_gpu_mem_un -o tb >/tmp/obj_gpu_mem_un/build.log 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  echo "!! verilator build failed rc=$rc"; tail -25 /tmp/obj_gpu_mem_un/build.log; exit 3
fi
/tmp/obj_gpu_mem_un/tb | tee sim/reglogs/gpu_mem_unalign_tb.log
grep -q "MEM_UNALIGN PASS" sim/reglogs/gpu_mem_unalign_tb.log