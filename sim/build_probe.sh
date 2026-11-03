#!/usr/bin/env bash
# 重建一个裸机探针 .bin（从 sim/<name>.S）。用法：bash sim/build_probe.sh probe_console_loop
set -eu
cd /mnt/d/code/PDS/NaxYeshenLinux
N=${1:-probe_console_loop}
riscv64-unknown-elf-gcc -march=rv64ima -mabi=lp64 -nostdlib -nostartfiles \
  -Wl,-Ttext=0x80000000 -o "sim/$N.elf" "sim/$N.S"
riscv64-unknown-elf-objcopy -O binary "sim/$N.elf" "sim/$N.bin"
ls -l "sim/$N.bin"
