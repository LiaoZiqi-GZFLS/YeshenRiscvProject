#!/usr/bin/env bash
# ============ DMA 引擎「并入 SoC 后」胶合层判决装置：构建 + 跑判据（WSL）============
# 用法（WSL）：bash sim/glue_pbus/run_dma_pbus_unit.sh
# DUT：--top-module pbus_dma_top（sim/glue_pbus/pbus_dma_top.v = glue 网表 + DmaEngine 网表；
#      两个被实例化的网表 rtl/YeshenSocGlue.v / y1/gen/DmaEngine.v 都**只读**，一字不改）。
# 判据：装置打印 `=== TEST PASSED === / === TEST FAILED ===`（逐条见 tb_dma_pbus.cpp 头部）。
#   ⚠️ Verilator 只在 WSL 里（5.020）；其 stdout 经 Windows shell 管道会乱码 ⇒ 一律落盘再读。
set -u
# 仓库根从脚本自身位置反推（历史上多个闸门写死过别的 checkout 的路径）
R="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$R/sim/glue_pbus" || exit 2
OBJ=obj_dir_dma
LOG_DIR="$R/sim/reglogs"
LOG_TAG=${LOG_TAG:-}
mkdir -p "$LOG_DIR"

if [ "${NO_BUILD:-0}" != "1" ]; then
  echo "[dma] verilator 构建（--top-module pbus_dma_top = YeshenSocGlue + DmaEngine）..."
  rm -rf "$OBJ"
  # ★ --assert：把 glue 里 §4 的「装载器/CPU 组时间互斥」断言（memSel 守卫，Phase-2b 加）**真正启用**
  verilator --cc --exe --build -j 4 -Wno-fatal --assert --top-module pbus_dma_top \
    ../../rtl/YeshenSocGlue.v ../../y1/gen/DmaEngine.v pbus_dma_top.v tb_dma_pbus.cpp \
    -o dma_pbus_sim --Mdir "$OBJ" \
    > "$LOG_DIR/build_dma_pbus${LOG_TAG}.log" 2>&1 \
    || { echo "[dma] BUILD_FAIL（见 sim/reglogs/build_dma_pbus${LOG_TAG}.log）"; tail -40 "$LOG_DIR/build_dma_pbus${LOG_TAG}.log"; exit 3; }
  echo "[dma] build ok"
fi

out=$(timeout 600 "./$OBJ/dma_pbus_sim" "$@" 2>&1 | tee "$LOG_DIR/dma_pbus_unit${LOG_TAG}.log")
v=$(printf '%s\n' "$out" | grep -aoE "TEST (PASSED|FAILED)" | tail -1)
echo "[dma] => ${v:-NO-VERDICT}"
printf '%s\n' "$out" | grep -aE "^=== |^  DST_vs|^  CH_BYTES|^  GBL_ID|^  CH_ID|^  w1c|^  ok:|^  \[FAIL\]|^  错窗|^  DST_vs" | sed 's/^/    /'
if [ "$v" = "TEST PASSED" ]; then
  exit 0
else
  printf '%s\n' "$out" | grep -aE "\[FAIL\]" | head -20 | sed 's/^/    /'
  exit 1
fi
