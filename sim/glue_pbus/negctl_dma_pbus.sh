#!/usr/bin/env bash
# ============ DMA 并入 SoC（§3.5 第 6 个主人 + CSR 窗）的**负对照**（Phase-2b）============
# 纪律：判据要能翻红 —— 把**承重接线**打歪，重生成胶合网表，装置必须 TEST FAILED。
#
#   NC_DMA1（★ 本任务**必须**的那条：**窗基址打歪 ⇒ DMA CSR 不可达**）：
#       `src/YeshenSocGlue.scala` 的 `val DMA_BASE = 0xF0006000L` → `0xF0007000L`
#       （把 DMA 窗挪到另一个空段）⇒ 装置在 0xF000_6000 上读不到 `GBL_ID`、写不进 CSR
#       ⇒ 程序阶段拿不到 bresp=OKAY / 读不回活体常数 ⇒ **J2（窗可达）直接红**。
#       期望：TEST FAILED。
#   NC_DMA2（★ 第二条：**§3.5 第 6 个主人的请求线被钉 0**）：
#       `private val dmaPend = io.dmaMem.awvalid || io.dmaMem.arvalid` → `false.B`
#       （仲裁器永远看不到 DMA 有请求 ⇒ 结构性不可达 ⇒ 引擎拿不到总线）
#       ⇒ 搬运一笔也发不出去（io_mem 无流量、永不 done） ⇒ **J1 完成超时 + J2 无流量** 红。
#       期望：TEST FAILED。
#
# ⚠️ 补丁必须"替换不到就报错"（sim/glue_pbus/patch_exact.py）—— 用 sed 曾静默 no-op。
# ⚠️ 跑完**必须**恢复源码 + 重生成**干净**网表，并核对 rtl/YeshenSocGlue.v 的 md5 与跑前一致。
set -u
R="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$R" || exit 2
SRC=src/YeshenSocGlue.scala
NET=rtl/YeshenSocGlue.v
BAK=/tmp/glue_p2b_src.scala
cp "$SRC" "$BAK" || exit 2
MD5_BEFORE=$(md5sum "$NET" | awk '{print $1}')
echo "[nc] 跑前 $NET md5 = $MD5_BEFORE"

FAILED_ANY=0
restore() { cp "$BAK" "$SRC"; }
trap restore EXIT

patch() { python3 sim/glue_pbus/patch_exact.py "$SRC" "$1" "$2" || { echo "  x 补丁未命中：$1"; FAILED_ANY=1; return 1; }; }

run_case() {  # $1=名字  $2=期望判定
  local name=$1 expect=$2 v=""
  local log="sim/reglogs/nc_dma_${name}.log"
  REBUILD_JAR=1 bash sim/glue_pbus/gen_glue.sh > "$log" 2>&1 \
    || { echo "  $name => GEN_FAIL（见 $log）"; FAILED_ANY=1; return; }
  # ⚠️ **不能** NO_BUILD=1：网表刚被换掉，必须让 verilator 用新网表重编装置
  LOG_TAG="_nc${name}" bash sim/glue_pbus/run_dma_pbus_unit.sh > "sim/reglogs/nc_dma_${name}_run.log" 2>&1
  v=$(grep -aoE "TEST (PASSED|FAILED)" "sim/reglogs/dma_pbus_unit_nc${name}.log" 2>/dev/null | tail -1)
  echo "  $name => ${v:-NO-VERDICT}（期望 TEST $expect）"
  grep -aE "\[FAIL\]|NO-VERDICT|BUILD_FAIL|完成超时|GBL_ID" "sim/reglogs/dma_pbus_unit_nc${name}.log" 2>/dev/null | head -6 | sed 's/^/     /'
  [ "$v" = "TEST $expect" ] || FAILED_ANY=1
}

only=${NC_ONLY:-ALL}
want() { [ "$only" = "ALL" ] || [ "$only" = "$1" ]; }

if want NC_DMA1; then
  echo "=== NC_DMA1（★ 必须）：窗基址打歪 0xF000_6000 → 0xF000_7000 ⇒ DMA CSR 不可达 ==="
  restore
  patch "  val DMA_BASE = 0xF0006000L" "  val DMA_BASE = 0xF0007000L"
  run_case NC_DMA1 FAILED
fi

if want NC_DMA2; then
  echo "=== NC_DMA2（★ 必须）：§3.5 第 6 个主人请求线钉 0（dmaPend=false）⇒ 引擎拿不到总线 ==="
  restore
  patch "private val dmaPend = io.dmaMem.awvalid || io.dmaMem.arvalid" "private val dmaPend = false.B"
  run_case NC_DMA2 FAILED
fi

# 收尾：恢复源码 + 重生成干净网表 + 核对 md5
restore
echo "=== 重生成干净网表（回到未打补丁的源码）==="
REBUILD_JAR=1 bash sim/glue_pbus/gen_glue.sh | tail -1
MD5_AFTER=$(md5sum "$NET" | awk '{print $1}')
echo "[nc] 恢复后 $NET md5 = $MD5_AFTER"
if [ "$MD5_AFTER" != "$MD5_BEFORE" ]; then echo "[nc] x 恢复后网表与跑前**不一致**！"; exit 5; fi
echo "[nc] 恢复后与跑前**逐字节一致**"
echo "=== 完成：负对照结论 $([ $FAILED_ANY = 0 ] && echo '各条都按期望翻红' || echo '有异常，见上') ==="
exit $FAILED_ANY
