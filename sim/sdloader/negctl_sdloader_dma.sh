#!/usr/bin/env bash
# ============ Y1-DMA Phase-2c 的**负对照**：D3 判据必须能翻红（把承重的那两处打歪）============
# 纪律（沿用 sim/glue_pbus/negctl_*.sh）：判据要能翻红 —— 把**承重逻辑**打歪、重生成胶合网表、
#   重跑装置，必须 **TEST FAILED**；跑完**恢复源码 + 重生成干净网表**并核对 md5 与跑前一致。
#
#   NC_SDLDMA1（★ 喂流的**字节序**打歪）：`SdLoader.scala` 里喂给引擎的那一拍 64bit
#       `Cat(wBuf(2i+1), wBuf(2i))` → `Cat(wBuf(2i), wBuf(2i+1))`（高低半交换）。
#       ⇒ 通路 B 的镜像**逐字节**与通路 A 不同（每 4 字节组反序）⇒ **J2（D3）翻红**。
#       （这正是 2026-10-05 那个"字节反转"事故的同构变异：承重的就是这一处的字节序。）
#   NC_SDLDMA2（★ 主口选通**忘了模式门**）：`memSel = uartEnable || (sdEnable && !io.sdDmaMode)`
#       → `uartEnable || sdEnable`（= 老的 loadActive 口径）。
#       ⇒ 通路 B 里装载器**仍然**占着 `io.mem` 的装载器分支（该分支在 DMA 模式下恒 0）
#       ⇒ 引擎的写突发全被选通挡掉 ⇒ 通路 B 写不进镜像 ⇒ **J2（D3）翻红**。
#       （这条钉住的是本相发现的那个真坑：Phase-2b 的 `memSel = loadActive` 在 2c 下不再成立。）
#
# ⚠️ 补丁必须"替换不到就报错"（sim/glue_pbus/patch_exact.py）—— 用 sed 曾静默 no-op。
set -u
R="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$R" || exit 2
SRC=src/peripheral/SdLoader.scala
GSRC=src/YeshenSocGlue.scala
NET=rtl/YeshenSocGlue.v
BAK_S=/tmp/sdloader_p2c_src.scala
BAK_G=/tmp/glue_p2c_src.scala
cp "$SRC" "$BAK_S" || exit 2
cp "$GSRC" "$BAK_G" || exit 2
MD5_BEFORE=$(md5sum "$NET" | awk '{print $1}')
echo "[nc] 跑前 $NET md5 = $MD5_BEFORE"

FAILED_ANY=0
restore() { cp "$BAK_S" "$SRC"; cp "$BAK_G" "$GSRC"; }
trap restore EXIT

patch() { python3 sim/glue_pbus/patch_exact.py "$1" "$2" "$3" || { echo "  x 补丁未命中：$2"; FAILED_ANY=1; return 1; }; }

run_case() {  # $1=名字  $2=期望判定
  local name=$1 expect=$2 v=""
  local log="sim/reglogs/nc_sdldma_${name}.log"
  REBUILD_JAR=1 bash sim/glue_pbus/gen_glue.sh > "$log" 2>&1 \
    || { echo "  $name => GEN_FAIL（见 $log）"; FAILED_ANY=1; return; }
  # ⚠️ **不能** NO_BUILD=1：网表刚被换掉，必须让 verilator 用新网表重编装置
  LOG_TAG="_nc${name}" bash sim/sdloader/run_sdloader_dma_unit.sh > "sim/reglogs/nc_sdldma_${name}_run.log" 2>&1
  v=$(grep -aoE "TEST (PASSED|FAILED)" "sim/reglogs/sdloader_dma_unit_nc${name}.log" 2>/dev/null | tail -1)
  echo "  $name => ${v:-NO-VERDICT}（期望 TEST $expect）"
  grep -aE "\[FAIL\]|NO-VERDICT|BUILD_FAIL|D3：|未放核|报错" "sim/reglogs/sdloader_dma_unit_nc${name}.log" 2>/dev/null | head -6 | sed 's/^/     /'
  [ "$v" = "TEST $expect" ] || FAILED_ANY=1
}

only=${NC_ONLY:-ALL}
want() { [ "$only" = "ALL" ] || [ "$only" = "$1" ]; }

if want NC_SDLDMA1; then
  echo "=== NC_SDLDMA1（★ 必须）：喂流 64bit 高低半交换 ⇒ 通路 B 镜像逐字节不同 ⇒ J2 翻红 ==="
  restore
  patch "$SRC" \
    "io.dmaWrData  := Cat(wBuf((dbIdx << 1) + 1.U), wBuf(dbIdx << 1))" \
    "io.dmaWrData  := Cat(wBuf(dbIdx << 1), wBuf((dbIdx << 1) + 1.U))"
  run_case NC_SDLDMA1 FAILED
fi

if want NC_SDLDMA2; then
  echo "=== NC_SDLDMA2（★ 必须）：memSel 忘了模式门（退回 loadActive 口径）⇒ 引擎流量被挡 ⇒ J2 翻红 ==="
  restore
  patch "$GSRC" \
    "private val memSel = uartEnable || (sdEnable && !io.sdDmaMode)" \
    "private val memSel = uartEnable || sdEnable"
  run_case NC_SDLDMA2 FAILED
fi

# ---- 恢复 + 重生成干净网表 + 核对 md5 ----
restore
REBUILD_JAR=1 bash sim/glue_pbus/gen_glue.sh > sim/reglogs/nc_sdldma_restore.log 2>&1 \
  || { echo "[nc] 恢复重生成失败（见 sim/reglogs/nc_sdldma_restore.log）"; exit 1; }
MD5_AFTER=$(md5sum "$NET" | awk '{print $1}')
echo "[nc] 跑后 $NET md5 = $MD5_AFTER"
[ "$MD5_AFTER" = "$MD5_BEFORE" ] || { echo "[nc] ⚠️ 网表未逐字节复原！"; FAILED_ANY=1; }

if [ "$FAILED_ANY" = "0" ]; then
  echo "[nc] 全部负对照按期望翻红，且源码/网表已复原 ⇒ PASS"
  exit 0
else
  echo "[nc] 有负对照未按期望翻红（或复原失败）⇒ FAIL"
  exit 1
fi
