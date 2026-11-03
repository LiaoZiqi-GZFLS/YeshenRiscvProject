#!/bin/bash
# 交叉编 gpu3dprobe（RV32、静态）—— 3D 上板边界探针
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 9
CC=${CC:-$HOME/vexii-build/buildroot/output/host/bin/riscv32-buildroot-linux-uclibc-gcc}
OUT=y1/build/gpu3dprobe
mkdir -p y1/build
"$CC" -O2 -static -march=rv32imac -mabi=ilp32 -mcmodel=medany \
      y1/tools/gpu3dprobe.c -o "$OUT" || { echo "!! compile failed"; exit 3; }
ls -l "$OUT"; md5sum "$OUT"
