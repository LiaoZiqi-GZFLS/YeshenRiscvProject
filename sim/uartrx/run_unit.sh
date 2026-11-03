#!/usr/bin/env bash
# ===================== UARTRx 收字节单元装置：构建 + 跑判据（WSL）=====================
# 用法（WSL）：bash sim/uartrx/run_unit.sh
# DUT：**从交付产物 rtl/YeshenSocGlue.v 里现抽** `module UARTRx`（每次重抽 ⇒ 测的永远是当前产物）。
# 判据：装置打印 `=== TEST PASSED === / === TEST FAILED ===`（逐条判据见 tb_uartrx.cpp 头部）。
# ⚠️ Verilator 只在 WSL 里；其 stdout 经 Windows shell 管道会乱码 ⇒ 一律落盘再读。
set -u
R=/mnt/d/code/PDS/VexiiYeshenLinux
cd "$R/sim/uartrx" || exit 2
LOG_DIR="$R/sim/reglogs"
mkdir -p "$LOG_DIR"

SRC="$R/rtl/YeshenSocGlue.v"
start=$(grep -n '^module UARTRx(' "$SRC" | head -1 | cut -d: -f1)
if [ -z "$start" ]; then echo "[unit] FAIL: 产物里找不到 module UARTRx"; exit 2; fi
end=$(awk -v s="$start" 'NR>=s && /^endmodule/{print NR; exit}' "$SRC")
sed -n "${start},${end}p" "$SRC" > UARTRx_extracted.v
echo "[unit] extracted UARTRx: $SRC 行 ${start}..${end}"

OBJ=obj_dir
rm -rf "$OBJ"
verilator --cc --exe --build -j 4 -Wno-fatal --top-module UARTRx \
  UARTRx_extracted.v tb_uartrx.cpp -o uartrx_sim --Mdir "$OBJ" \
  > "$LOG_DIR/build_uartrx.log" 2>&1 \
  || { echo "[unit] BUILD_FAIL（见 sim/reglogs/build_uartrx.log）"; tail -40 "$LOG_DIR/build_uartrx.log"; exit 3; }
echo "[unit] build ok"

out=$(timeout 120 "./$OBJ/uartrx_sim" 2>&1 | tee "$LOG_DIR/uartrx_unit.log")
v=$(printf '%s\n' "$out" | grep -aoE "TEST (PASSED|FAILED)" | tail -1)
echo "[unit] => ${v:-NO-VERDICT}"
if [ "$v" = "TEST PASSED" ]; then
  exit 0
fi
printf '%s\n' "$out" | grep -aE "MISMATCH|fail" | head -20 | sed 's/^/    /'
exit 1
