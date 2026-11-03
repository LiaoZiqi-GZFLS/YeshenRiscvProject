#!/usr/bin/env bash
# =============================================================================
# build_npurun_t.sh —— 交叉编 y1/tools/npurun_t.c（板内单进程帧计时器；同 build_ddmem.sh 口径）
#
# 用法（WSL 里跑，工具链取自 buildroot 输出，与 ddmem 同一份）：
#   wsl -e bash -lc 'bash /mnt/d/code/PDS/VexiiYeshenLinux/y1/tools/build_npurun_t.sh'
# 产物：y1/build/npurun_t_rv32（static，strip）
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 9            # -> y1/
Y1=$(pwd)

CC=${CC:-$HOME/vexii-build/buildroot/output/host/bin/riscv32-buildroot-linux-uclibc-gcc}
[ -x "$CC" ] || { echo "!! 找不到交叉编译器：$CC"; exit 2; }

mkdir -p "$Y1/build"
OUT="$Y1/build/npurun_t_rv32"

# -D_FILE_OFFSET_BITS=64：ilp32 的 off_t 语义，mmap offset 才不会溢出（同 ddmem 的坑）
CFLAGS=(-O2 -Wall -static -D_FILE_OFFSET_BITS=64
        -march=rv32imac_zicsr_zifencei -mabi=ilp32 -mcmodel=medany)

echo "CC  = $CC"
echo "SRC = $Y1/tools/npurun_t.c"
"$CC" "${CFLAGS[@]}" "$Y1/tools/npurun_t.c" -o "$OUT" || { echo "!! 编译失败"; exit 3; }
"${CC%gcc}strip" "$OUT" 2>/dev/null || true
ls -l "$OUT"
md5sum "$OUT"
echo "下一步：scp $OUT root@192.168.1.110:/tmp/npu_f1/"
