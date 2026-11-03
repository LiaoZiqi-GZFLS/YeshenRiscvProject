#!/usr/bin/env bash
# 闸门：用主机模拟重放 VexiiYeshenLinux 的六个 2D 黄金用例，逐字节比对帧存。
# 用法：bash scripts/run_gpu_host_test.sh
# 前提：VexiiYeshenLinux 与本仓同级（../VexiiYeshenLinux/sim/gpu/gold）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GOLD="${GOLD_DIR:-$ROOT/../VexiiYeshenLinux/sim/gpu/gold}"
BUILD="${BUILD_DIR:-/tmp/yeshen-gui-gpu-test}"

if [ ! -f "$GOLD/fill_rect.fb.bin" ]; then
    echo "GPU_HOST: FAIL（找不到黄金目录 $GOLD）"
    exit 2
fi

cmake -S "$ROOT/host" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build "$BUILD" --target gpu_host_test -j"$(nproc 2>/dev/null || echo 4)" > /dev/null
"$BUILD/gpu_host_test" "$GOLD"
