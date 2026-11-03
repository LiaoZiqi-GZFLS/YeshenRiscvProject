#!/usr/bin/env bash
# =============================================================================
# build_ddmem.sh —— 交叉编 y1/tools/ddmem.c 成板内静态小工具（Y1 C4b-F1）
#
# 为什么需要：低 2 MB 的 NPU 主机写入区（phys < 0x8200_0000）用 **read/write 系统调用**
#   碰 /dev/mem 会**内核 oops**（riscv32 `xlate_dev_mem_ptr=__va` 的线性映射不覆盖那里）；
#   只有 **mmap** 一路（`devmem` 用的那条）能读写。busybox 只给一 word，1.2 MB 不可能。
#   ⇒ 编一个静态的 mmap 搬运器，scp 上板即可（板内**不需要任何构建环境**）。
#
# 用法（**WSL 里跑**，工具链取自 buildroot 输出）：
#   wsl -e bash -lc 'bash /mnt/d/code/PDS/VexiiYeshenLinux/y1/tools/build_ddmem.sh'
# 产物：y1/build/ddmem_rv32（strip 后 ~30 KB）
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 9            # -> y1/
Y1=$(pwd)
REPO=$(cd "$Y1/.." && pwd)

CC=${CC:-$HOME/vexii-build/buildroot/output/host/bin/riscv32-buildroot-linux-uclibc-gcc}
[ -x "$CC" ] || { echo "!! 找不到交叉编译器：$CC"; exit 2; }

mkdir -p "$Y1/build"
OUT="$Y1/build/ddmem_rv32"

# ⚠️ -D_FILE_OFFSET_BITS=64：ilp32 默认 off_t 是 32 位有符号，mmap 的 `offset` 参数
#    传 0x8014_0000 会被当成**负数** ⇒ EINVAL。devmem 也是这么编的。
CFLAGS=(-O2 -Wall -static -D_FILE_OFFSET_BITS=64
        -march=rv32imac_zicsr_zifencei -mabi=ilp32 -mcmodel=medany)

echo "CC  = $CC"
echo "SRC = $Y1/tools/ddmem.c"
"$CC" "${CFLAGS[@]}" "$Y1/tools/ddmem.c" -o "$OUT" || { echo "!! 编译失败"; exit 3; }
"${CC%gcc}strip" "$OUT" 2>/dev/null || true
ls -l "$OUT"
md5sum "$OUT"
echo "下一步：scp $OUT root@192.168.1.110:/tmp/npu_f1/"
