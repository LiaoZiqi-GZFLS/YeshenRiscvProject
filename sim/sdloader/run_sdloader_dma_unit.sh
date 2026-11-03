#!/usr/bin/env bash
# ============ Y1-DMA Phase-2c 判决装置：**SD 装载器当 DMA 引擎的第一个真客户**（WSL）============
# 用法（WSL）：bash sim/sdloader/run_sdloader_dma_unit.sh
# DUT：--top-module sdloader_dma_top（= rtl/YeshenSocGlue.v（内含 SdLoader/SdSpi）+ y1/gen/DmaEngine.v；
#      两个网表都**只读、一字不改**；接线见 sim/sdloader/sdloader_dma_top.v 头部）。
# 判据：J1 直写基线 / **J2（★D3）同一镜像经引擎装载 == 直写装载（逐字节）** / J3 切换是真的 /
#      J4 记账 / J5 负对照自检。逐条见 tb_sdloader_dma.cpp 头部。
# ⚠️ 仓库根**从脚本自身位置反推**（历史上有闸门写死过别的 checkout 的路径 ⇒ 判了别的树）。
#   Verilator 只在 WSL 里（5.020）；stdout 经 Windows 管道会乱码 ⇒ 一律落盘再读。
set -u
R="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$R/sim/sdloader" || exit 2
OBJ=obj_dir_dma
LOG_DIR="$R/sim/reglogs"
LOG_TAG=${LOG_TAG:-}
mkdir -p "$LOG_DIR"

[ -f "$R/rtl/YeshenSocGlue.v" ] || { echo "[sdldma] 缺网表 rtl/YeshenSocGlue.v（先跑 sim/glue_pbus/gen_glue.sh）"; exit 2; }
[ -f "$R/y1/gen/DmaEngine.v" ] || { echo "[sdldma] 缺网表 y1/gen/DmaEngine.v（先跑 DmaEngineGen）"; exit 2; }

# 小卡镜像（28 块 = 14 KB，3 个表项，目标地址取 0x8000_0000 段 = 真机口径）；缺了就现造。
if [ ! -f "$R/sim/reglogs/sd_small.img" ]; then
  echo "[sdldma] 造小卡镜像 sim/reglogs/sd_small.img ..."
  python3 "$R/sim/mk_sd_image.py" --out "$R/sim/reglogs/sd_small.img" \
    --entry 0x80000000="$R/sim/sdloader/testdata/a.bin" \
    --entry 0x80400000="$R/sim/sdloader/testdata/b.bin" \
    --entry 0x80F80000="$R/sim/sdloader/testdata/c.bin" \
    || { echo "[sdldma] 造镜像失败"; exit 2; }
fi

if [ "${NO_BUILD:-0}" != "1" ]; then
  echo "[sdldma] verilator 构建（--top-module sdloader_dma_top = glue + DmaEngine）..."
  rm -rf "$OBJ"
  # ★ --assert：把 SdLoader / glue 里的守卫断言真正启用（见 run_dma_pbus_unit.sh 同一手法）
  verilator --cc --exe --build -j 4 -Wno-fatal --assert --top-module sdloader_dma_top \
    "$R/rtl/YeshenSocGlue.v" "$R/y1/gen/DmaEngine.v" sdloader_dma_top.v tb_sdloader_dma.cpp \
    -o sdloader_dma_sim --Mdir "$OBJ" \
    > "$LOG_DIR/build_sdloader_dma${LOG_TAG}.log" 2>&1 \
    || { echo "[sdldma] BUILD_FAIL（见 sim/reglogs/build_sdloader_dma${LOG_TAG}.log）"; tail -40 "$LOG_DIR/build_sdloader_dma${LOG_TAG}.log"; exit 3; }
  echo "[sdldma] build ok"
fi

# 默认用**小镜像**（28 块 = 14 KB，含 3 个表项，目标地址在 0x8000_0000 段 = 真机口径）。
# 要跑真镜像：SD_IMG="$R/sim/reglogs/sd.img" bash sim/sdloader/run_sdloader_dma_unit.sh 3000000000
export SD_IMG="${SD_IMG:-../reglogs/sd_small.img}"
out=$(timeout 900 "./$OBJ/sdloader_dma_sim" "$@" 2>&1 | tee "$LOG_DIR/sdloader_dma_unit${LOG_TAG}.log")
v=$(printf '%s\n' "$out" | grep -aoE "TEST (PASSED|FAILED)" | tail -1)
echo "[sdldma] => ${v:-NO-VERDICT}"
printf '%s\n' "$out" | grep -aE "^  |^=== |^卡镜像|^  表项" | sed 's/^/    /'
if [ "$v" = "TEST PASSED" ]; then
  exit 0
else
  printf '%s\n' "$out" | grep -aE "\[FAIL\]" | head -20 | sed 's/^/    /'
  exit 1
fi
