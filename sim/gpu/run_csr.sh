#!/bin/bash
# run_csr.sh —— gpu_csr + gpu_cmd 单元闸门
set -u
cd "$(dirname "$0")/../.." || exit 9
mkdir -p /tmp/obj_gpu_csr
verilator --binary --timing -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-DECLFILENAME \
  -Isim/gpu -Irtl/gpu --top-module tb_gpu_csr \
  sim/gpu/tb_gpu_csr.v rtl/gpu/gpu_csr.v rtl/gpu/gpu_cmd.v \
  -Mdir /tmp/obj_gpu_csr -o tb >/tmp/obj_gpu_csr/build.log 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  echo "!! verilator build failed rc=$rc"; tail -25 /tmp/obj_gpu_csr/build.log; exit 3
fi
/tmp/obj_gpu_csr/tb | tee sim/reglogs/gpu_csr_tb.log
grep -q "CSR PASS" sim/reglogs/gpu_csr_tb.log
