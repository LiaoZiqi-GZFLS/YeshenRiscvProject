#!/usr/bin/env bash
# ===================== SdLoader 单元装置（**通路 A：直写内存**）：构建 + 跑判据（WSL）=====================
# 用法（WSL）：bash sim/sdloader/run_unit.sh
# 依赖：rtl/YeshenSocGlue.v（由 `sim/glue_pbus/gen_glue.sh` 从 src/ 重生成）
# 判据：装置打印 `=== TEST PASSED ===` / `=== TEST FAILED ===`（源码与判据见 tb_sdloader.cpp）。
#   ★ Y1-DMA Phase-2c：本闸门 = **Phase-2c 之前的通路（装载器直写 DDR）**，与
#     `run_sdloader_dma_unit.sh`（喂 DMA 引擎的通路 B + D3 逐字节比对）成对。
# ⚠️ 仓库根**从脚本自身位置反推**（历史版本写死过 `/mnt/d/code/PDS/NaxYeshenLinux` ⇒ 判了**别的树**）。
set -u
R="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$R/sim/sdloader" || exit 2          # ⚠️ 必须在自己的目录里起 verilator（--Mdir 会让 make 在该目录跑）
NETLIST="$R/rtl/YeshenSocGlue.v"
UNIT="$R/sim/sdloader/SdLoader_unit.v"
LOG_DIR="$R/sim/reglogs"
mkdir -p "$LOG_DIR"

[ -f "$NETLIST" ] || { echo "缺网表 $NETLIST（先跑 sim/glue_pbus/gen_glue.sh）"; exit 2; }

# 小卡镜像（28 块 = 14 KB）；缺了就现造（与 run_sdloader_dma_unit.sh 同一份）
if [ ! -f "$R/sim/reglogs/sd_small.img" ]; then
  echo "[unit] 造小卡镜像 sim/reglogs/sd_small.img ..."
  python3 "$R/sim/mk_sd_image.py" --out "$R/sim/reglogs/sd_small.img" \
    --entry 0x80000000="$R/sim/sdloader/testdata/a.bin" \
    --entry 0x80400000="$R/sim/sdloader/testdata/b.bin" \
    --entry 0x80F80000="$R/sim/sdloader/testdata/c.bin" \
    || { echo "[unit] 造镜像失败"; exit 2; }
fi

# ---- 从整份 glue 网表里切出 SdLoader + 它的子模块 SdSpi（Verilator 只看 --top-module 及其子层）----
# ⚠️ 必须连 firtool 的**宏前导**（ASSERT_VERBOSE_COND_/STOP_COND_ 的 ifndef/define）一起切。
awk '/^module /{exit} {print}' "$NETLIST" > "$UNIT"
awk '/^module SdSpi\(/,/^endmodule/'    "$NETLIST" >> "$UNIT"
awk '/^module SdLoader\(/,/^endmodule/' "$NETLIST" >> "$UNIT"
n_spi=$(grep -c "^module SdSpi("    "$UNIT" || true)
n_sdl=$(grep -c "^module SdLoader(" "$UNIT" || true)
if [ "$n_spi" != "1" ] || [ "$n_sdl" != "1" ]; then
  echo "[unit] 切网表失败：SdSpi=$n_spi SdLoader=$n_sdl（网表变了？）"; exit 2
fi
echo "[unit] 切出 $(wc -l < "$UNIT") 行（SdSpi + SdLoader）"

echo "[unit] verilator 构建（--top-module SdLoader）..."
rm -rf obj_dir
verilator --cc --exe --build -j 4 -Wno-fatal --public-flat-rw --top-module SdLoader \
  "$UNIT" tb_sdloader.cpp -o sdloader_sim --Mdir obj_dir \
  > "$LOG_DIR/build_sdloader.log" 2>&1 \
  || { echo "[unit] BUILD_FAIL（见 sim/reglogs/build_sdloader.log）"; tail -30 "$LOG_DIR/build_sdloader.log"; exit 3; }
echo "[unit] build ok"

# 默认用**小镜像**（28 块 / 14 KB）跑：真机 8.7MB 按 divFast=1 要 ~2.8e8 拍，仿真没必要。
# 要跑真镜像：SD_IMG=../reglogs/sd.img bash sim/sdloader/run_unit.sh 3000000000
export SD_IMG="${SD_IMG:-../reglogs/sd_small.img}"
out=$(./obj_dir/sdloader_sim "${1:-5000000}" 2>&1 | tee "$LOG_DIR/sdloader_unit.log")
v=$(printf '%s\n' "$out" | grep -aoE "TEST (PASSED|FAILED)" | tail -1)
echo "[unit] => ${v:-NO-VERDICT}"
exit $([ "$v" = "TEST PASSED" ] && echo 0 || echo 1)
