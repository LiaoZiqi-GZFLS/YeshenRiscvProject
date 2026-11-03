#!/usr/bin/env bash
# =============================================================================
# run_cpu_coremark.sh —— 裸核 CoreMark 仿真（Verilator）
#
# DUT = rtl/vexiiriscv/VexiiRiscv.v（当前核配置，**不含** DDR/SoC）
# 装置 = tb_coremark.cpp：3 个 AXI4 从口 + 8 MiB 内存 + UART(THR/LSR) + rdtime 端口
# 判据 = UART 出现 crcfinal；CoreMark/MHz = Iterations / Total ticks
#
# 用法（WSL）：bash sim/cpu_coremark/run_cpu_coremark.sh [bin] [max_cycles] [mem_lat]
#   MEM_LAT=1 ≈ 上游 ready-factor 2 的理想内存；MEM_LAT 越大越接近慢内存。
# =============================================================================
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
net="$root/rtl/vexiiriscv/VexiiRiscv.v"
bin="${1:-$root/sw/images/coremark_rv32_i10.bin}"
bin="$(cd "$(dirname "$bin")" && pwd)/$(basename "$bin")"
maxc="${2:-200000000}"
lat="${3:-1}"
log="$root/sim/reglogs/cpu_coremark_i10_lat${lat}.log"

[ -x "$(command -v verilator)" ] || { echo "FATAL: 缺 verilator（WSL）"; exit 2; }
[ -f "$net" ] || { echo "FATAL: 缺 $net"; exit 2; }
[ -f "$bin" ] || { echo "FATAL: 缺 $bin"; exit 2; }

cd "$here" || exit 2
if [ "${NO_BUILD:-0}" != "1" ]; then
  rm -rf obj_dir
  verilator --cc --exe --build -j 2 -Wno-fatal --top-module VexiiRiscv --Mdir obj_dir \
    "$net" tb_coremark.cpp -o coremark_sim -CFLAGS "-O2" \
    > "$root/sim/reglogs/build_cpu_coremark.log" 2>&1 \
    || { echo "FATAL: verilator build failed（见 sim/reglogs/build_cpu_coremark.log）"; tail -25 "$root/sim/reglogs/build_cpu_coremark.log"; exit 3; }
fi

echo "[sim] core=$(md5sum "$net" | cut -d' ' -f1) bin=$(md5sum "$bin" | cut -d' ' -f1) lat=$lat"
./obj_dir/coremark_sim "$bin" "$maxc" "$lat" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
grep -q "crcfinal" "$log" && grep -q "CoreMark/MHz" "$log" || rc=1
echo "[sim] log=$log rc=$rc"
exit $rc
