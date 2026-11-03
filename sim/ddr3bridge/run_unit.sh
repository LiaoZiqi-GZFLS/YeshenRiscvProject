#!/bin/bash
# ===================== DDR3Bridge 单元装置：构建 + 跑判据（WSL）=====================
# 用法（WSL）：AXI_W=32 bash sim/ddr3bridge/run_unit.sh     # 32bit 从口（S1 阳性基线）
#              AXI_W=64 bash sim/ddr3bridge/run_unit.sh     # 64bit 从口（S2 阳性）
#   AXI_W 默认 64（V1 交付形态）。
# 环境变量：
#   NO_GEN=1        跳过网表重生成（用 NETLIST 指向的现成产物）
#   NETLIST         网表路径（默认 <repo>/build_ddr/DDR3Bridge.v）；S1 复现 32bit 时指向
#                   独立由 `attic/DDR3Bridge32.scala` 生成的那一份（不必改 src/，见 §1）
#   DDR_MHZ_LIST    时钟比敏感度对照（默认 "100 125"；axi 恒 100MHz）
#   LOG_TAG         日志名后缀（默认空；负对照脚本用 `_nc<条>`，**避免把 S1/S2 的阳性日志冲掉**）
#   DDR_MAX_CYC / DDR_DBG  透传给装置
# 判据：装置打印 `=== TEST PASSED === / === TEST FAILED ===`（源码与判据见 tb_ddrbridge.cpp）。
set -u
# ⚠️ 仓库根**从脚本自身位置反推**（`<repo>/sim/ddr3bridge/run_unit.sh`）：
#    本闸门历史上写死过 `/mnt/d/code/PDS/NaxYeshenLinux`，搬到本仓库后那是个**别的 checkout**
#    （`git log`/`git remote` 都不同）⇒ 会去跑另一棵树的网表，判据照样打印 PASS 却什么都没守住。
R="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$R/sim/ddr3bridge" || exit 2        # ⚠️ 必须在自己的目录里起 verilator：`--Mdir` 会让 make 在该目录里跑，
                                        #    源文件用仓库相对路径会找不到
SIM=sim/ddr3bridge
AXI_W=${AXI_W:-64}
NO_GEN=${NO_GEN:-0}
NETLIST=${NETLIST:-$R/build_ddr/DDR3Bridge.v}
DDR_MHZ_LIST=${DDR_MHZ_LIST:-"100 125"}
LOG_TAG=${LOG_TAG:-}
OBJ="obj_dir_w${AXI_W}"
LOG_DIR="$R/sim/reglogs"
mkdir -p "$LOG_DIR"

if [ "$NO_GEN" != "1" ]; then
  ( cd "$R" && bash "$SIM/gen_bridge.sh" ) || exit 2
fi
[ -f "$NETLIST" ] || { echo "缺网表 $NETLIST（先跑 sim/ddr3bridge/gen_bridge.sh）"; exit 2; }

echo "[unit] verilator 构建（AXI_W=$AXI_W，--top-module DDR3Bridge，netlist=$NETLIST）..."
# ⚠️ 位宽宏必须走 `-CFLAGS -DAXI_W=`（C++ 侧）；裸 `-D` 是给 Verilog 预处理器的（T13 踩过这个坑）
verilator --cc --exe --build -j 8 -Wno-fatal --top-module DDR3Bridge \
  "$NETLIST" tb_ddrbridge.cpp \
  -CFLAGS "-DAXI_W=$AXI_W" \
  -o ddr3bridge_sim --Mdir "$OBJ" > "$LOG_DIR/build_ddr3bridge_w${AXI_W}.log" 2>&1 \
  || { echo "[unit] BUILD_FAIL（见 sim/reglogs/build_ddr3bridge_w${AXI_W}.log）"; tail -15 "$LOG_DIR/build_ddr3bridge_w${AXI_W}.log"; exit 3; }
echo "[unit] build ok"

FAILED=0
for MHZ in $DDR_MHZ_LIST; do
  out=$(DDR_MHZ=$MHZ timeout 300 "./$OBJ/ddr3bridge_sim" 2>&1 | tee "$LOG_DIR/ddr3bridge_unit_w${AXI_W}${LOG_TAG}_${MHZ}mhz.log")
  v=$(printf '%s\n' "$out" | grep -aoE "TEST (PASSED|FAILED)" | tail -1)
  echo "[unit] AXI_W=$AXI_W ddr=${MHZ}MHz => ${v:-NO-VERDICT}"
  if [ "$v" != "TEST PASSED" ]; then
    printf '%s\n' "$out" | grep -aE "\[FAIL\]|^=== |（期望" | head -20 | sed 's/^/    /'
    FAILED=1
  fi
done
echo "=== 单元装置结论（AXI_W=$AXI_W）：$([ $FAILED = 0 ] && echo '全部 PASSED' || echo '有 FAILED') ==="
exit $FAILED
