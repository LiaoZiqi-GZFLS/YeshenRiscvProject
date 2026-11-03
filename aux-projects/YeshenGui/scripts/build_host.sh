#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD_DIR:-$HOME/yeshen-gui-build/host}"
mkdir -p "$BUILD" "$ROOT/build"
if [[ ! -f "$ROOT/ui/assets/wallpaper_ink.bin" || ! -f "$ROOT/ui/assets/wallpaper_paper.bin" ]]; then
    bash "$ROOT/scripts/gen_assets.sh"
fi
cmake -S "$ROOT/host" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
      -DYESHEN_GUI_GPU_UNIT=ON
cmake --build "$BUILD" -j"$(nproc)"
cp -f "$BUILD/yshell_host" "$ROOT/build/yshell_host"
echo "built: $ROOT/build/yshell_host"
