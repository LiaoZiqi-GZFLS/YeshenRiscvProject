#!/usr/bin/env bash
# 闸门：LVGL draw unit 的 A/B（GPU 单元 vs 纯 SW），host 上跑，不需要板子。
#
#   ① 单元级：同一场景（实心矩形 + 圆角 + 半透明 + 文本）渲染两次，
#      帧存逐字节相同；GPU 那次必须真的接管了任务（tasks>0）。
#   ② 整机级：yshell 的 DIRECT+GPU 版与 PARTIAL+SW 版各截一张图，逐字节相同。
#
# 用法：bash scripts/run_gpu_unit_host_test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

cmake -S host -B build/host_sw -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build build/host_sw --target yshell_host -j"$(nproc 2>/dev/null || echo 4)" > /dev/null

cmake -S host -B build/host_gpu -DCMAKE_BUILD_TYPE=Release -DYESHEN_GUI_GPU_UNIT=ON > /dev/null
cmake --build build/host_gpu --target yshell_host gpu_unit_host_test \
      -j"$(nproc 2>/dev/null || echo 4)" > /dev/null

fail=0
# ---- ① 单元级 A/B ----
build/host_gpu/gpu_unit_host_test --out build/ab_sw.bin > build/ab_sw.log
build/host_gpu/gpu_unit_host_test --out build/ab_gpu.bin --gpu > build/ab_gpu.log
if cmp -s build/ab_sw.bin build/ab_gpu.bin; then
    echo "UNIT: 帧存一致（$(stat -c %s build/ab_sw.bin) B）  $(cat build/ab_gpu.log)"
else
    echo "UNIT: FAIL（GPU 单元与 SW 渲染不同）"
    cmp -l build/ab_sw.bin build/ab_gpu.bin | head -5
    fail=1
fi
tasks=$(cat build/ab_gpu.bin.stats 2>/dev/null || echo 0)
if [ "${tasks:-0}" -gt 0 ]; then
    echo "UNIT: GPU 接管 $tasks 个任务（非退化）"
else
    echo "UNIT: FAIL（GPU 单元一个任务都没接管）"
    fail=1
fi

# ---- ② 整机级截图 A/B ----
SDL_VIDEODRIVER=dummy build/host_sw/yshell_host  --screenshot build/shot_sw.ppm  > build/run_sw.log  2>&1
SDL_VIDEODRIVER=dummy build/host_gpu/yshell_host --screenshot build/shot_gpu.ppm > build/run_gpu.log 2>&1
if cmp -s build/shot_sw.ppm build/shot_gpu.ppm; then
    echo "APP:  截屏一致（$(stat -c %s build/shot_sw.ppm) B）"
else
    echo "APP:  FAIL（整机截图不同）"
    cmp -l build/shot_sw.ppm build/shot_gpu.ppm | head -5
    fail=1
fi
grep -q "GPU-UNIT-ON" build/run_gpu.log && echo "APP:  GPU 单元已挂上（日志 GPU-UNIT-ON）" \
    || { echo "APP:  FAIL（GPU 版日志里没有 GPU-UNIT-ON）"; fail=1; }

if [ "$fail" -eq 0 ]; then
    echo "GPU_UNIT_HOST: PASS"
else
    echo "GPU_UNIT_HOST: FAIL"
fi
exit "$fail"
