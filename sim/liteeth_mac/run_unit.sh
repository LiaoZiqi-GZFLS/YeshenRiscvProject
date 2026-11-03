#!/usr/bin/env bash
# ===================== LiteEth MAC 黑盒单元装置：构建 + 跑判据（WSL）=====================
# 用法（WSL）：bash sim/liteeth_mac/run_unit.sh
# DUT：third_party/liteeth_mac/liteeth_mac_top.v（**不改输入件**）。
# 判据：A(TX 吐前导+载荷且 READY 回 1) / B(RX 写槽且载荷一致) / C(CRC 错必须记错，负控)。
# 详见 tb_liteeth_mac.cpp 头部。⚠️ stdout 一律落盘再读（Verilator 经 Windows 管道会乱码）。
set -u
R=/mnt/d/code/PDS/VexiiYeshenLinux
cd "$R/sim/liteeth_mac" || exit 2
LOG_DIR="$R/sim/reglogs"
mkdir -p "$LOG_DIR"
OBJ=obj_dir
rm -rf "$OBJ"
verilator --cc --exe --build -j 4 -Wno-fatal --top-module liteeth_mac_top \
  ../../third_party/liteeth_mac/liteeth_mac_top.v tb_liteeth_mac.cpp -o mac_sim --Mdir "$OBJ" \
  > "$LOG_DIR/build_mac.log" 2>&1 \
  || { echo "[unit] BUILD_FAIL（见 sim/reglogs/build_mac.log）"; tail -40 "$LOG_DIR/build_mac.log"; exit 3; }
echo "[unit] build ok"
out=$(timeout 600 "./$OBJ/mac_sim" 2>&1 | tee "$LOG_DIR/mac_unit.log")
v=$(printf '%s\n' "$out" | grep -aoE "TEST (PASSED|FAILED)" | tail -1)
echo "[unit] => ${v:-NO-VERDICT}"
[ "$v" = "TEST PASSED" ] && exit 0
exit 1
