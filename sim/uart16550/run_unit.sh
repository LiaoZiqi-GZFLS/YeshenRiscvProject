#!/usr/bin/env bash
# ===================== Uart16550 接收 FIFO 单元装置：构建 + 跑判据（WSL）=====================
# 用法（WSL）：
#   bash sim/uart16550/run_unit.sh            # 正控：期望 TEST PASSED
#   bash sim/uart16550/run_unit.sh --negctl    # 负对照：把接收推入门变异成"仅空时收"（退回 1 级），期望 FAILED
# DUT：从交付产物 rtl/YeshenSocGlue.v 里现抽 `module Uart16550`（负对照用临时副本变异）。
# 判据见 tb_uart16550.cpp 头部。⚠️ stdout 一律落盘再读（Verilator 经 Windows 管道会乱码）。
set -u
R=/mnt/d/code/PDS/VexiiYeshenLinux
cd "$R/sim/uart16550" || exit 2
LOG_DIR="$R/sim/reglogs"
mkdir -p "$LOG_DIR"
NEG=0
[ "${1:-}" = "--negctl" ] && NEG=1

SRC="$R/rtl/YeshenSocGlue.v"
MD5_BEFORE=$(md5sum "$SRC" | cut -d' ' -f1)

# 抽一个模块（含它依赖的 UARTTx/UARTRx —— 三者都在同一份产物里）
extract() {
  local name="$1"
  local s e
  s=$(grep -n "^module ${name}(" "$SRC" | head -1 | cut -d: -f1)
  if [ -z "$s" ]; then echo "[unit] FAIL: 产物里找不到 module ${name}"; exit 2; fi
  e=$(awk -v s="$s" 'NR>=s && /^endmodule/{print NR; exit}' "$SRC")
  sed -n "${s},${e}p" "$SRC"
  echo "[unit]   extracted ${name}: 行 ${s}..${e}" >&2
}
: > Uart16550_extracted.v
extract Uart16550   >> Uart16550_extracted.v
extract UARTTx      >> Uart16550_extracted.v
extract UARTRx      >> Uart16550_extracted.v
echo "[unit] extracted Uart16550+UARTTx+UARTRx from $SRC (md5 $MD5_BEFORE)"

DUT=Uart16550_extracted.v
TAG=pos
if [ "$NEG" = "1" ]; then
  TAG=neg
  # 精确单行变异：接收推入条件加上"仅当 FIFO 为空"⇒ 等价退回 1 级寄存器，背靠背突发必丢
  echo "[unit] negctl: 变异 Uart16550_mut.v（接收推入退回 1 级）"
  python3 - "$DUT" "Uart16550_mut.v" <<'PY'
import sys
src = open(sys.argv[1]).read()
old = "wire        rxPush = _rx_io_valid & ~rxFull & ~fcrRxClear;"
new = "wire        rxPush = _rx_io_valid & ~rxFull & ~fcrRxClear & (rxCount == 5'h0);"
assert src.count(old) == 1, "mutation anchor not unique: %d" % src.count(old)
open(sys.argv[2], "w").write(src.replace(old, new))
PY
  DUT=Uart16550_mut.v
fi

OBJ=obj_dir_$TAG
rm -rf "$OBJ"
verilator --cc --exe --build -j 4 -Wno-fatal --top-module Uart16550 \
  "$DUT" tb_uart16550.cpp -o u16550_sim --Mdir "$OBJ" \
  > "$LOG_DIR/build_u16550_$TAG.log" 2>&1 \
  || { echo "[unit] BUILD_FAIL（见 sim/reglogs/build_u16550_$TAG.log）"; tail -40 "$LOG_DIR/build_u16550_$TAG.log"; exit 3; }

out=$(timeout 300 "./$OBJ/u16550_sim" 2>&1 | tee "$LOG_DIR/u16550_unit_$TAG.log")
v=$(printf '%s\n' "$out" | grep -aoE "TEST (PASSED|FAILED)" | tail -1)
echo "[unit] => ${v:-NO-VERDICT}  (mode=$TAG)"

MD5_AFTER=$(md5sum "$SRC" | cut -d' ' -f1)
if [ "$MD5_BEFORE" != "$MD5_AFTER" ]; then
  echo "[unit] !!! 交付产物被动过！$MD5_BEFORE -> $MD5_AFTER"; exit 4
fi
echo "[unit] rtl/YeshenSocGlue.v md5 未变（$MD5_AFTER）"

if [ "$NEG" = "1" ]; then
  [ "$v" = "TEST FAILED" ] && { echo "[unit] negctl OK"; exit 0; }
  echo "[unit] 负对照没翻红 ⇒ 判据分辨不出 1 级退回"; exit 1
fi
[ "$v" = "TEST PASSED" ] && exit 0
exit 1
