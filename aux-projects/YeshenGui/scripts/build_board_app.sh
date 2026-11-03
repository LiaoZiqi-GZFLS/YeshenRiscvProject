#!/usr/bin/env bash
# Cross-build the board GUI (RV32, static uClibc) and stage it for the
# rootfs overlay. Run under WSL, e.g.
#   cd /mnt/d/code/PDS/YeshenGui && bash scripts/build_board_app.sh
#
# Phase R second-framebuffer A/B variant:
#   GUI_VARIANT=gui2 bash scripts/build_board_app.sh
# builds with BOARD_GUI_SECOND_BUF=ON into its own build dir and stages
# board/variants/gui2/yshell. The default output (paired with the freeze/bank
# bitstream 7092e495 and images/sd_gui.img) is never touched; never mix the
# two app/bitstream/image pairs.
#
# VexiiYeshenLinux mainline variant (2026-10-30):
#   GUI_VARIANT=mainline bash scripts/build_board_app.sh
# builds BOARD_GUI_MAINLINE=ON (same source-select protocol, but GUI_CTRL is at
# window offset 0x09C instead of 0x094) and stages board/variants/mainline/yshell.
# Pair it with the mainline `gui1` bitstream only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLCHAIN="$ROOT/board/riscv32-toolchain.cmake"
GUI_VARIANT="${GUI_VARIANT:-default}"

case "$GUI_VARIANT" in
  default)
    BUILD="${BUILD_DIR:-$HOME/yeshen-gui-build/board}"
    OUT="$ROOT/board/rootfs_overlay/root/gui/yshell"
    CMAKE_EXTRA=()
    ;;
  gui2)
    BUILD="${BUILD_DIR:-$HOME/yeshen-gui-build/board_gui2}"
    OUT="$ROOT/board/variants/gui2/yshell"
    CMAKE_EXTRA=(-DBOARD_GUI_SECOND_BUF=ON)
    ;;
  mainline)
    BUILD="${BUILD_DIR:-$HOME/yeshen-gui-build/board_mainline}"
    OUT="$ROOT/board/variants/mainline/yshell"
    CMAKE_EXTRA=(-DBOARD_GUI_MAINLINE=ON)
    ;;
  mainline_gpu)
    # GPU 2D 单元变体：LVGL 直接画进 GUI 帧存（DIRECT），实心矩形/RGB565 图像走硬件。
    # 只配 `gpu1` 比特流（GPU 窗 + 第 4 主口）。
    BUILD="${BUILD_DIR:-$HOME/yeshen-gui-build/board_mainline_gpu}"
    OUT="$ROOT/board/variants/mainline_gpu/yshell"
    CMAKE_EXTRA=(-DBOARD_GUI_MAINLINE=ON -DYESHEN_GUI_GPU_UNIT=ON)
    ;;
  *)
    echo "FAIL: unknown GUI_VARIANT '$GUI_VARIANT' (expected default, gui2, mainline or mainline_gpu)" >&2
    exit 1
    ;;
esac

echo "== GUI_VARIANT=$GUI_VARIANT build=$BUILD out=$OUT"
mkdir -p "$BUILD" "$(dirname "$OUT")"

cmake -S "$ROOT/board" -B "$BUILD" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DCMAKE_BUILD_TYPE=Release \
  "${CMAKE_EXTRA[@]}"
cmake --build "$BUILD" -j"$(nproc)"

cp -f "$BUILD/yshell" "$OUT"
chmod 0755 "$OUT"

echo "== staged: $OUT"
file "$OUT"
readelf -h "$OUT" | grep -E "Class|Machine|Flags"
stat -c 'size: %s bytes' "$OUT"
du -h "$OUT"
