#!/bin/bash
# 交叉编 cbotest（RV32、静态、带 zicbom），并做反汇编冒烟。
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 9
CC=${CC:-$HOME/vexii-build/buildroot/output/host/bin/riscv32-buildroot-linux-uclibc-gcc}
OD=${OD:-$HOME/vexii-build/buildroot/output/host/bin/riscv32-buildroot-linux-uclibc-objdump}
OUT=y1/build/cbotest
mkdir -p y1/build
"$CC" -O2 -static -march=rv32imac_zicbom -mabi=ilp32 -mcmodel=medany \
      y1/tools/cbotest.c -o "$OUT" || { echo "!! compile failed"; exit 3; }
"$OD" -d "$OUT" | grep -c -E "cbo\.(flush|clean|inval)" | sed 's/^/cbo_insns=/'
ls -l "$OUT"; md5sum "$OUT"
