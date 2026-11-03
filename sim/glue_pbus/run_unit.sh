#!/usr/bin/env bash
# ===================== YeshenSocGlue 外设总线译码单元装置：构建 + 跑判据（WSL）=====================
# 用法（WSL）：bash sim/glue_pbus/run_unit.sh
# DUT：rtl/YeshenSocGlue.v（--top-module YeshenSocGlue，**输入件不改**；只读它）。
# 判据：装置打印 `=== TEST PASSED === / === TEST FAILED ===`（源码与逐条判据见 tb_pbus.cpp 头部）。
#   ⚠️ Verilator 只在 WSL 里（5.020）；其 stdout 经 Windows shell 管道会乱码 ⇒ 一律落盘再读。
set -u
R=/mnt/d/code/PDS/VexiiYeshenLinux
cd "$R/sim/glue_pbus" || exit 2      # 必须在自己的目录里起 verilator（--Mdir 让 make 在此目录跑）
LOG_DIR="$R/sim/reglogs"
mkdir -p "$LOG_DIR"
OBJ=obj_dir

echo "[unit] verilator 构建（--top-module YeshenSocGlue，netlist=rtl/YeshenSocGlue.v）..."
rm -rf "$OBJ"
verilator --cc --exe --build -j 4 -Wno-fatal --top-module YeshenSocGlue \
  ../../rtl/YeshenSocGlue.v tb_pbus.cpp -o pbus_sim --Mdir "$OBJ" \
  > "$LOG_DIR/build_pbus.log" 2>&1 \
  || { echo "[unit] BUILD_FAIL（见 sim/reglogs/build_pbus.log）"; tail -30 "$LOG_DIR/build_pbus.log"; exit 3; }
echo "[unit] build ok"

out=$(timeout 300 "./$OBJ/pbus_sim" 2>&1 | tee "$LOG_DIR/pbus_unit.log")
v=$(printf '%s\n' "$out" | grep -aoE "TEST (PASSED|FAILED)" | tail -1)
echo "[unit] => ${v:-NO-VERDICT}"
if [ "$v" = "TEST PASSED" ]; then
  exit 0
else
  printf '%s\n' "$out" | grep -aE "\[FAIL\]" | head -20 | sed 's/^/    /'
  exit 1
fi
