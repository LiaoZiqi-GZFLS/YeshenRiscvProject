#!/usr/bin/env bash
# ===================== UARTTx 发帧形状单元装置：构建 + 跑判据（WSL）=====================
# 用法（WSL）：
#   bash sim/uarttx/run_unit.sh             # 正控：期望 TEST PASSED（交付产物 8N1 = 10 位帧）
#   bash sim/uarttx/run_unit.sh --negctl     # 负对照：单行变异插回校验位槽，期望 TEST FAILED
# DUT：从交付产物 rtl/YeshenSocGlue.v 里现抽 `module UARTTx`（负对照用**临时副本**变异，
#      交付产物零改动 —— 变异前后对 rtl/YeshenSocGlue.v 记 md5 自证）。
# 判据见 tb_uarttx.cpp 头部。⚠️ stdout 一律落盘再读（Verilator 经 Windows 管道会乱码）。
set -u
R=/mnt/d/code/PDS/VexiiYeshenLinux
cd "$R/sim/uarttx" || exit 2
LOG_DIR="$R/sim/reglogs"
mkdir -p "$LOG_DIR"
NEG=0
[ "${1:-}" = "--negctl" ] && NEG=1

SRC="$R/rtl/YeshenSocGlue.v"
MD5_BEFORE=$(md5sum "$SRC" | cut -d' ' -f1)
start=$(grep -n '^module UARTTx(' "$SRC" | head -1 | cut -d: -f1)
if [ -z "$start" ]; then echo "[unit] FAIL: 产物里找不到 module UARTTx"; exit 2; fi
end=$(awk -v s="$start" 'NR>=s && /^endmodule/{print NR; exit}' "$SRC")
sed -n "${start},${end}p" "$SRC" > UARTTx_extracted.v
echo "[unit] extracted UARTTx: $SRC 行 ${start}..${end} (md5 $MD5_BEFORE)"

DUT=UARTTx_extracted.v
TAG=pos
if [ "$NEG" = "1" ]; then
  TAG=neg
  # 精确单行变异：数据位 7 的下一状态从 sStop(3'h4) 改回 sParity(3'h3) ⇒ 11 位帧
  python3 - "$DUT" > UARTTx_mut.v <<'PY'
import sys
src = open(sys.argv[1]).read()
anchor = "if (bitTick & (&bitIndex))\n            state <= 3'h4;"
assert src.count(anchor) == 1, "mutation anchor not unique: %d" % src.count(anchor)
sys.stdout.write(src.replace(anchor, "if (bitTick & (&bitIndex))\n            state <= 3'h3;"))
PY
  echo "[unit] negctl: 已生成 UARTTx_mut.v（插回校验位槽）"
  DUT=UARTTx_mut.v
fi

OBJ=obj_dir_$TAG
rm -rf "$OBJ"
verilator --cc --exe --build -j 4 -Wno-fatal --top-module UARTTx \
  "$DUT" tb_uarttx.cpp -o uarttx_sim --Mdir "$OBJ" \
  > "$LOG_DIR/build_uarttx_$TAG.log" 2>&1 \
  || { echo "[unit] BUILD_FAIL（见 sim/reglogs/build_uarttx_$TAG.log）"; tail -40 "$LOG_DIR/build_uarttx_$TAG.log"; exit 3; }

out=$(timeout 120 "./$OBJ/uarttx_sim" 2>&1 | tee "$LOG_DIR/uarttx_unit_$TAG.log")
v=$(printf '%s\n' "$out" | grep -aoE "TEST (PASSED|FAILED)" | tail -1)
echo "[unit] => ${v:-NO-VERDICT}  (mode=$TAG)"

MD5_AFTER=$(md5sum "$SRC" | cut -d' ' -f1)
if [ "$MD5_BEFORE" != "$MD5_AFTER" ]; then
  echo "[unit] !!! 交付产物被动过！$MD5_BEFORE -> $MD5_AFTER"
  exit 4
fi
echo "[unit] rtl/YeshenSocGlue.v md5 未变（$MD5_AFTER）"

if [ "$NEG" = "1" ]; then
  [ "$v" = "TEST FAILED" ] && { echo "[unit] 负对照按预期翻红 ✓"; exit 0; }
  echo "[unit] 负对照没翻红 ⇒ 装置分辨不出 11 位帧，判据无效"; exit 1
fi
[ "$v" = "TEST PASSED" ] && exit 0
exit 1
