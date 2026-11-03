#!/bin/bash
# ===================== MemArbiter 单元装置：构建 + 跑判据（WSL）=====================
# 用法（WSL）：bash sim/memarb/run_unit.sh
# DUT：--top-module MemArbiter（网表 build_memarb/MemArbiter.v，见 gen_memarb.sh）。
# 判据：装置打印 `=== TEST PASSED === / === TEST FAILED ===`（源码与逐条判据见 tb_memarb.cpp 头部）。
#   ⚠️ Verilator 只在 WSL 里（5.020）；其 stdout 经 Windows shell 管道会乱码 ⇒ 一律落盘再读。
# 环境变量：
#   NO_GEN=1   跳过网表重生成（用现成的 build_memarb/MemArbiter.v）
#   NETLIST    网表路径（默认 <repo>/build_memarb/MemArbiter.v）
#   LOG_TAG    日志名后缀（负对照脚本用 `_nc<条>`，**避免把阳性日志冲掉**）
set -u
# 仓库根从脚本自身位置反推（同 sim/ddr3bridge/run_unit.sh 的说明：写死过别的 checkout ⇒ 会打错树）
R="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$R/sim/memarb" || exit 2        # ⚠️ 必须在自己的目录里起 verilator（--Mdir 让 make 在此目录跑）
SIM=sim/memarb
NO_GEN=${NO_GEN:-0}
NETLIST=${NETLIST:-$R/build_memarb/MemArbiter.v}
LOG_TAG=${LOG_TAG:-}
OBJ=obj_dir
LOG_DIR="$R/sim/reglogs"
mkdir -p "$LOG_DIR"

if [ "$NO_GEN" != "1" ]; then
  ( cd "$R" && bash "$SIM/gen_memarb.sh" ) || exit 2
fi
[ -f "$NETLIST" ] || { echo "缺网表 $NETLIST（先跑 sim/memarb/gen_memarb.sh）"; exit 2; }

echo "[memarb] verilator 构建（--top-module MemArbiter，netlist=$NETLIST）..."
rm -rf "$OBJ"
verilator --cc --exe --build -j 4 -Wno-fatal --top-module MemArbiter \
  "$NETLIST" tb_memarb.cpp -o memarb_sim --Mdir "$OBJ" \
  > "$LOG_DIR/build_memarb.log" 2>&1 \
  || { echo "[memarb] BUILD_FAIL（见 sim/reglogs/build_memarb.log）"; tail -25 "$LOG_DIR/build_memarb.log"; exit 3; }
echo "[memarb] build ok"

out=$(timeout 300 "./$OBJ/memarb_sim" 2>&1 | tee "$LOG_DIR/memarb_unit${LOG_TAG}.log")
v=$(printf '%s\n' "$out" | grep -aoE "TEST (PASSED|FAILED)" | tail -1)
echo "[memarb] => ${v:-NO-VERDICT}"
if [ "$v" = "TEST PASSED" ]; then
  exit 0
else
  printf '%s\n' "$out" | grep -aE "\[FAIL\]|^=== " | head -20 | sed 's/^/    /'
  exit 1
fi
