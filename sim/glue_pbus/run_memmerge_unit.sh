#!/usr/bin/env bash
# ============ YeshenSocGlue 内存合并点（§3.5）判决装置：构建 + 跑判据（WSL）============
# 用法（WSL）：
#   bash sim/glue_pbus/run_memmerge_unit.sh                       # 阳性（J_MM1/J_MM3）
#   bash sim/glue_pbus/run_memmerge_unit.sh --golden  <file>      # 记单主人 transcript（改动**前**跑）
#   bash sim/glue_pbus/run_memmerge_unit.sh --compare <file>      # 与 golden 比（改动**后**跑 ⇒ J_MM2）
# DUT：--top-module YeshenSocGlue（netlist=rtl/YeshenSocGlue.v，**只读输入件**）。
# 判据：装置打印 `=== TEST PASSED === / === TEST FAILED ===`（源码与逐条判据见 tb_memmerge.cpp 头部）。
#   ⚠️ Verilator 只在 WSL 里（5.020）；其 stdout 经 Windows shell 管道会乱码 ⇒ 一律落盘再读。
# 环境变量：NO_BUILD=1（复用已编好的 obj_dir_memmerge）、LOG_TAG（日志名后缀）
set -u
# 仓库根从脚本自身位置反推（历史上多个闸门写死过别的 checkout 的路径）
R="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$R/sim/glue_pbus" || exit 2
OBJ=obj_dir_memmerge
LOG_DIR="$R/sim/reglogs"
LOG_TAG=${LOG_TAG:-}
mkdir -p "$LOG_DIR"

if [ "${NO_BUILD:-0}" != "1" ]; then
  echo "[memmerge] verilator 构建（--top-module YeshenSocGlue）..."
  rm -rf "$OBJ"
  verilator --cc --exe --build -j 4 -Wno-fatal --top-module YeshenSocGlue \
    ../../rtl/YeshenSocGlue.v tb_memmerge.cpp -o memmerge_sim --Mdir "$OBJ" \
    > "$LOG_DIR/build_memmerge${LOG_TAG}.log" 2>&1 \
    || { echo "[memmerge] BUILD_FAIL（见 sim/reglogs/build_memmerge${LOG_TAG}.log）"; tail -30 "$LOG_DIR/build_memmerge${LOG_TAG}.log"; exit 3; }
  echo "[memmerge] build ok"
fi

out=$(timeout 600 "./$OBJ/memmerge_sim" "$@" 2>&1 | tee "$LOG_DIR/memmerge_unit${LOG_TAG}.log")
v=$(printf '%s\n' "$out" | grep -aoE "TEST (PASSED|FAILED)" | tail -1)
echo "[memmerge] => ${v:-NO-VERDICT}"
printf '%s\n' "$out" | grep -aE "^=== |^  \[LAT|^  \[DISC|^  \[QUOTA|^  \[GOLDEN|^  \[REGRESS|^  \[JOB|^  \[DIF" | sed 's/^/    /'
if [ "$v" = "TEST PASSED" ]; then
  exit 0
else
  printf '%s\n' "$out" | grep -aE "\[FAIL\]" | head -20 | sed 's/^/    /'
  exit 1
fi
