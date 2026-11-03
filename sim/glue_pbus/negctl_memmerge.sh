#!/usr/bin/env bash
# ============ YeshenSocGlue 内存合并点（§3.5 真仲裁）的**负对照**（Phase-1 / T1.2）============
# 纪律：判据要能翻红 —— 把**配额**打歪，重生成胶合网表，判据必须 TEST FAILED。
#
#   NC_MM1（★ 本任务**必须**的那条：**配额退化 ⇒ 一类被饿死**）：
#       `src/YeshenSocGlue.scala` 的 `private val ARB_WEIGHTS = Seq(2, 1, 1)` → `Seq(2, 0, 1)`
#       （**类 1 = NPU** 的配额清零 ⇒ 结构性不可达 ⇒ `npuMem` 永远拿不到授权）。
#       期望：TEST FAILED，且**红在 J_MM1**（并发作业里 npuMem 跑不完 / 其等待无界）。
#   NC_MM2（配额比打歪）：`Seq(2,1,1)` → `Seq(1,1,1)`。
#       期望：TEST FAILED，红在 J_MM4（类间授予比 CPU:NPU 从 2:1 掉到 1:1）。
#   NC_L2B（L2b 多 outstanding 的**承重条件**）：把 `(rdOut === 1.U)` 改成 `true.B`
#       ⇒ 授权在**首个 rlast** 就释放（旧纪律）⇒ J_MM5 必须红（后续 R 被挡/超时）。
#
# ⚠️ 补丁必须"替换不到就报错"（sim/glue_pbus/patch_exact.py）—— 用 sed 曾静默 no-op。
# ⚠️ 跑完**必须**恢复源码 + 重生成**干净**网表，并核对 rtl/YeshenSocGlue.v 的 md5 与跑前一致。
set -u
R="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$R" || exit 2
SRC=src/YeshenSocGlue.scala
NET=rtl/YeshenSocGlue.v
BAK=/tmp/glue_p1_src.scala
cp "$SRC" "$BAK" || exit 2
MD5_BEFORE=$(md5sum "$NET" | awk '{print $1}')
echo "[nc] 跑前 $NET md5 = $MD5_BEFORE"

FAILED_ANY=0
restore() { cp "$BAK" "$SRC"; }
trap restore EXIT

patch() { python3 sim/glue_pbus/patch_exact.py "$SRC" "$1" "$2" || { echo "  ✗ 补丁未命中：$1"; FAILED_ANY=1; return 1; }; }

run_case() {  # $1=名字  $2=期望判定
  local name=$1 expect=$2 v=""
  local log="sim/reglogs/nc_memmerge_${name}.log"
  REBUILD_JAR=1 bash sim/glue_pbus/gen_glue.sh > "$log" 2>&1 \
    || { echo "  $name => GEN_FAIL（见 $log）"; FAILED_ANY=1; return; }
  # ⚠️ **不能** NO_BUILD=1：网表刚被换掉，必须让 verilator 用新网表重编装置
  LOG_TAG="_nc${name}" bash sim/glue_pbus/run_memmerge_unit.sh > "sim/reglogs/nc_memmerge_${name}_run.log" 2>&1
  v=$(grep -aoE "TEST (PASSED|FAILED)" "sim/reglogs/memmerge_unit_nc${name}.log" 2>/dev/null | tail -1)
  echo "  $name => ${v:-NO-VERDICT}（期望 TEST $expect）"
  grep -aE "\[FAIL\]|NO-VERDICT|BUILD_FAIL" "sim/reglogs/memmerge_unit_nc${name}.log" 2>/dev/null | head -5 | sed 's/^/     /'
  [ "$v" = "TEST $expect" ] || FAILED_ANY=1
}

only=${NC_ONLY:-ALL}
want() { [ "$only" = "ALL" ] || [ "$only" = "$1" ]; }

if want NC_MM1; then
  echo "=== NC_MM1（★ 必须）：配额退化 ⇒ NPU 类被饿死（ARB_WEIGHTS 第 2 项 1 → 0）==="
  restore
  patch "  private val ARB_WEIGHTS = Seq(2, 1, 1)" "  private val ARB_WEIGHTS = Seq(2, 0, 1)"
  run_case NC_MM1 FAILED
fi

if want NC_MM2; then
  echo "=== NC_MM2：配额比打歪（Seq(2,1,1) → Seq(1,1,1)）==="
  restore
  patch "  private val ARB_WEIGHTS = Seq(2, 1, 1)" "  private val ARB_WEIGHTS = Seq(1, 1, 1)"
  run_case NC_MM2 FAILED
fi

if want NC_L2B; then
  echo "=== NC_L2B：授权在首个 rlast 就释放（L2b 承重条件被打掉）==="
  restore
  patch "when(rdOwner && rlastFire && !arFire && (rdOut === 1.U)) { owner := OWN_IDLE }" \
        "when(rdOwner && rlastFire && !arFire && true.B) { owner := OWN_IDLE }"
  run_case NC_L2B FAILED
fi

# 收尾：恢复源码 + 重生成干净网表 + 核对 md5
restore
echo "=== 重生成干净网表（回到未打补丁的源码）==="
REBUILD_JAR=1 bash sim/glue_pbus/gen_glue.sh | tail -1
MD5_AFTER=$(md5sum "$NET" | awk '{print $1}')
echo "[nc] 恢复后 $NET md5 = $MD5_AFTER"
if [ "$MD5_AFTER" != "$MD5_BEFORE" ]; then echo "[nc] ✗ 恢复后网表与跑前**不一致**！"; exit 5; fi
echo "[nc] 恢复后与跑前**逐字节一致**"
echo "=== 完成：负对照结论 $([ $FAILED_ANY = 0 ] && echo '各条都按期望翻红' || echo '有异常，见上') ==="
exit $FAILED_ANY
