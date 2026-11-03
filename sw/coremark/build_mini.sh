#!/usr/bin/env bash
# build_mini.sh -- build the tiny bisection probe (test_mini.c) with the same port as CoreMark.
set -e
cd "$(dirname "$0")"
C="riscv64-unknown-elf-gcc -O2 -ffreestanding -march=rv64imac_zicsr -mabi=lp64 -mcmodel=medany -DITERATIONS=1 -I. -Iport"
$C -c test_mini.c -o test_mini.o
$C -c port/core_portme.c -o port/core_portme.o
$C -c port/mini_libc.c -o port/mini_libc.o
$C -c start.S -o start.o
$C test_mini.o port/core_portme.o port/mini_libc.o start.o -nostdlib -Tapp.ld -lgcc -o mini.elf -Wl,-Map,mini.map
riscv64-unknown-elf-objcopy -O binary mini.elf mini.bin
ls -l mini.bin
riscv64-unknown-elf-objdump -d mini.elf | sed -n '1,45p'
