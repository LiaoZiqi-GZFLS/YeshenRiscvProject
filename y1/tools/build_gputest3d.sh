#!/bin/bash
# 交叉编 gputest3d（RV32、静态）。工具链在 WSL 里（Windows 侧没有那份 buildroot）。
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 9
OUT=y1/build/gputest3d
mkdir -p y1/build

W=$(pwd -W 2>/dev/null)                 # D:/code/PDS/VexiiYeshenLinux
WPATH="/mnt/$(printf %s "${W:0:1}" | tr 'A-Z' 'a-z')${W:2}"
CC_WSL=${CC_WSL:-$HOME/vexii-build/buildroot/output/host/bin/riscv32-buildroot-linux-uclibc-gcc}
CC_WSL=${CC_WSL/\/c\/Users\/Ziqi/\~}    # Git Bash 的 $HOME 是 /c/Users/Ziqi ⇒ WSL 侧是 ~

MSYS_NO_PATHCONV=1 wsl -e bash -lc "cd '$WPATH' && $CC_WSL -O2 -static -march=rv32imac_zicbom -mabi=ilp32 -mcmodel=medany y1/tools/gputest3d.c -o $OUT" \
    || { echo "!! compile failed"; exit 3; }
ls -l "$OUT"; md5sum "$OUT"
