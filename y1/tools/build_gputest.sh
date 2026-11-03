#!/bin/bash
# 交叉编 gputest（RV32、静态）—— GPU 2D 上板自检，判据在程序内部。
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 9
CC=${CC:-$HOME/vexii-build/buildroot/output/host/bin/riscv32-buildroot-linux-uclibc-gcc}
OUT=y1/build/gputest
mkdir -p y1/build
"$CC" -O2 -static -march=rv32imac -mabi=ilp32 -mcmodel=medany \
      y1/tools/gputest.c -o "$OUT" || { echo "!! compile failed"; exit 3; }
ls -l "$OUT"; md5sum "$OUT"
