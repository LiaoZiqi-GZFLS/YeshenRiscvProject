#!/usr/bin/env bash
# =============================================================================
# build_y1run.sh —— 交叉编 y1/tools/y1run.c（板内纯 C 整帧 runner；static）
#
# 用法（WSL 里跑，工具链取自 buildroot 输出，与 ddmem/npurun_t 同一份）：
#   wsl -e bash -lc 'bash /mnt/d/code/PDS/VexiiYeshenLinux/y1/tools/build_y1run.sh'
# 产物：y1/build/y1run_rv32（static，strip）
# 可选：--install 把产物复制到 rootfs overlay（= 烘进 rootfs.cpio）
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 9            # -> y1/
Y1=$(pwd)
REPO=$(cd "$Y1/.." && pwd)
OVERLAY="$REPO/sw/buildroot-external/boards/naxmini/linux/rootfs_overlay/root/y1"

CC=${CC:-$HOME/vexii-build/buildroot/output/host/bin/riscv32-buildroot-linux-uclibc-gcc}
[ -x "$CC" ] || { echo "!! 找不到交叉编译器：$CC"; exit 2; }

mkdir -p "$Y1/build"
OUT="$Y1/build/y1run_rv32"

CFLAGS=(-O2 -Wall -static -D_FILE_OFFSET_BITS=64
        -march=rv32imac_zicsr_zifencei -mabi=ilp32 -mcmodel=medany)

echo "CC  = $CC"
echo "SRC = $Y1/tools/y1run.c"
"$CC" "${CFLAGS[@]}" "$Y1/tools/y1run.c" -o "$OUT" || { echo "!! 编译失败"; exit 3; }
"${CC%gcc}strip" "$OUT" 2>/dev/null || true
ls -l "$OUT"
md5sum "$OUT"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$OVERLAY"
  cp -f "$OUT" "$OVERLAY/y1run"
  chmod +x "$OVERLAY/y1run"
  echo "installed -> $OVERLAY/y1run"
fi
