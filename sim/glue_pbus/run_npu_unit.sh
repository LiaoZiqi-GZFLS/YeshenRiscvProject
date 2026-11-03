#!/usr/bin/env bash
# ============ NPU 寄存器窗「CPU 侧写通路」判决装置：构建 + 跑判据（WSL）============
# 用法（WSL）：bash sim/glue_pbus/run_npu_unit.sh
# DUT：--top-module pbus_npu_top（sim/glue_pbus/pbus_npu_top.v = glue 网表 + HostRegs 网表；
#      两个被实例化的网表 rtl/YeshenSocGlue.v / y1/gen/HostRegs.v 都**只读**，一字不改）。
# 判据：装置打印 `=== TEST PASSED === / === TEST FAILED ===`（逐条见 tb_npu_pbus.cpp 头部）。
#   ⚠️ Verilator 只在 WSL 里（5.020）；其 stdout 经 Windows shell 管道会乱码 ⇒ 一律落盘再读。
#
# 这是**新增件**：既有 run_unit.sh（console/CLINT/PLIC 那套，top=YeshenSocGlue）原样不动。
set -u
R=/mnt/d/code/PDS/VexiiYeshenLinux
cd "$R/sim/glue_pbus" || exit 2
LOG_DIR="$R/sim/reglogs"
mkdir -p "$LOG_DIR"
OBJ=obj_dir_npu

echo "[npu] verilator 构建（--top-module pbus_npu_top = YeshenSocGlue + HostRegs）..."
rm -rf "$OBJ"
verilator --cc --exe --build -j 4 -Wno-fatal --top-module pbus_npu_top \
  ../../rtl/YeshenSocGlue.v ../../y1/gen/HostRegs.v pbus_npu_top.v tb_npu_pbus.cpp \
  -o npu_pbus_sim --Mdir "$OBJ" \
  > "$LOG_DIR/build_pbus_npu.log" 2>&1 \
  || { echo "[npu] BUILD_FAIL（见 sim/reglogs/build_pbus_npu.log）"; tail -40 "$LOG_DIR/build_pbus_npu.log"; exit 3; }
echo "[npu] build ok"

out=$(timeout 300 "./$OBJ/npu_pbus_sim" 2>&1 | tee "$LOG_DIR/pbus_npu_unit.log")
v=$(printf '%s\n' "$out" | grep -aoE "TEST (PASSED|FAILED)" | tail -1)
echo "[npu] => ${v:-NO-VERDICT}"
if [ "$v" = "TEST PASSED" ]; then
  exit 0
else
  printf '%s\n' "$out" | grep -aE "\[FAIL\]" | head -20 | sed 's/^/    /'
  exit 1
fi
