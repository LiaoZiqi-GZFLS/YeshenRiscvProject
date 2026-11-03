#!/usr/bin/env bash
# ===================== GPU 端点级闸门：构建 + 跑判据（WSL）=====================
# 用法（WSL）：bash sim/glue_pbus/run_gpu_unit.sh
# DUT：sim/glue_pbus/gpu_unit_top.v（内部例化 rtl/YeshenSocGlue.v + rtl/gpu/gpu_top.v + sim/gpu/axi_ram_model.v）
# 判据：装置打印 `=== GPU-GLUE PASS === / FAIL`（逐条判据见 tb_gpu_unit.cpp 头部）
set -u
R=/mnt/d/code/PDS/VexiiYeshenLinux
cd "$R/sim/glue_pbus" || exit 2
LOG_DIR="$R/sim/reglogs"
mkdir -p "$LOG_DIR"
OBJ=obj_dir_gpu

echo "[gpu] verilator 构建（top=gpu_unit_top）..."
rm -rf "$OBJ"
verilator --cc --exe --build -j 4 -Wno-fatal --top-module gpu_unit_top \
  gpu_unit_top.v ../../rtl/YeshenSocGlue.v ../../rtl/gpu/gpu_top.v ../../rtl/gpu/gpu_csr.v \
  ../../rtl/gpu/gpu_cmd.v ../../rtl/gpu/gpu_2d.v ../../rtl/gpu/gpu_mem.v \
  ../../rtl/gpu/gpu_3d.v ../../rtl/gpu/tri_setup.v ../../rtl/gpu/tri_raster.v \
  ../../sim/gpu/axi_ram_model.v \
  tb_gpu_unit.cpp -o gpu_sim -I../../rtl/gpu --Mdir "$OBJ" \
  > "$LOG_DIR/build_gpu_unit.log" 2>&1 \
  || { echo "[gpu] BUILD_FAIL（见 sim/reglogs/build_gpu_unit.log）"; tail -40 "$LOG_DIR/build_gpu_unit.log"; exit 3; }
echo "[gpu] build ok"

out=$(timeout 600 "./$OBJ/gpu_sim" 2>&1 | tee "$LOG_DIR/gpu_unit.log")
v=$(printf '%s\n' "$out" | grep -aoE "GPU-GLUE (PASS|FAIL)" | tail -1)
echo "[gpu] => ${v:-NO-VERDICT}"
if [ "$v" = "GPU-GLUE PASS" ]; then
  exit 0
else
  printf '%s\n' "$out" | grep -aE "\[FAIL\]|MISMATCH" | head -20 | sed 's/^/    /'
  exit 1
fi
