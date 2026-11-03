#!/bin/bash
# run_mem.sh —— gpu_mem 单元闸门：写 burst / 读 burst / 写合并 / strb=0 负对照
set -u
cd "$(dirname "$0")/../.." || exit 9
mkdir -p /tmp/obj_gpu_mem
verilator --binary --timing -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-DECLFILENAME \
  -Isim/gpu -Irtl/gpu --top-module tb_gpu_mem \
  sim/gpu/tb_gpu_mem.v sim/gpu/axi_ram_model.v rtl/gpu/gpu_mem.v \
  -Mdir /tmp/obj_gpu_mem -o tb >/tmp/obj_gpu_mem/build.log 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  echo "!! verilator build failed rc=$rc"; tail -25 /tmp/obj_gpu_mem/build.log; exit 3
fi
/tmp/obj_gpu_mem/tb | tee sim/reglogs/gpu_mem_tb.log
grep -q "MEM PASS" sim/reglogs/gpu_mem_tb.log
