#!/bin/bash
# ===================== MemArbiter 真仲裁器的负对照（Phase-1 / T1.2）=====================
# 纪律：每条判据都要能翻红 —— 把对应那道门**单独**从源码里摘掉/打歪，重生成网表，判据必须 TEST FAILED。
# 用法（git-bash 或 WSL）：bash sim/memarb/negctl_memarb.sh
#   只跑某条：NC_ONLY=NC_A bash sim/memarb/negctl_memarb.sh
#
#   NC_A（★ 本任务**必须**的那条：**配额退化 ⇒ 饿死**）：
#       `GEN_WEIGHTS = Seq(2, 1, 1)` → `Seq(2, 1, 0)`（第 2 类 = DMA 配额清零）。
#       权重 0 = **结构性不可达**（不进轮转、也不进老化提升）⇒ 该类**永远拿不到授予**。
#       期望：TEST FAILED，且**红在** J1（有界等待）/ J2（无饿死）上 —— 这正是"有界等待是可失效的"。
#   NC_B（配额比打歪）：`Seq(2, 1, 1)` → `Seq(1, 1, 1)`。
#       期望：TEST FAILED，红在 J3（CPU:NPU 应 ≈2 却成了 1）。
#   NC_C（授权门与"空闲"脱钩）：`io.pickV := io.free && anyReq` → `io.pickV := anyReq`。
#       期望：TEST FAILED，红在 J5（出现 pickV=1 而 free=0 —— 事务在飞还发授权）。
#   NC_D（在单主人路径上**插入气泡**）：`io.pickV := io.free && anyReq`
#       → `io.pickV := io.free && anyReq && (budget =/= 0.U)`（只在配额未尽时发授权）。
#       期望：TEST FAILED，红在 J4（单主人出现附加延迟/授予次数塌掉 ⇒ "单主人变了吗"当场可见）。
#
# ⚠️ 补丁一律走 sim/memarb/patch_exact.py（精确串替换 + **替换不到就报错**）—— 用 sed 曾静默 no-op，
#    把"没打上补丁"读成了"负对照通过"（YeshenCore §5.13.8）。
# ⚠️ 跑完**必须**把源码恢复并**重生成干净网表**（别把负对照的网表/源码留在工作区）。
set -u
# 仓库根从脚本自身位置反推（不要写死路径 —— Phase-0 抓到过别的 checkout 的写死路径）
R="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$R" || exit 2
SRC=src/soc/MemArbiter.scala
BAK=/tmp/memarb_phase1_src.scala
cp "$SRC" "$BAK" || exit 2

FAILED_ANY=0
restore() { cp "$BAK" "$SRC"; }
trap restore EXIT

patch() {  # $1=旧串 $2=新串（替换不到 ⇒ 直接算失败）
  python3 sim/memarb/patch_exact.py "$SRC" "$1" "$2" || { echo "  ✗ 补丁未命中：$1"; FAILED_ANY=1; return 1; }
}

run_case() {  # $1=名字  $2=期望判定（FAILED）
  local name=$1 expect=$2 v=""
  local log="sim/reglogs/nc_memarb_${name}.log"
  # REBUILD_JAR=1：jar 里嵌的是**编译过的**源码，改过源码就得重编 jar
  # LOG_TAG 让内层单元日志另起名字，别把阳性日志冲掉
  REBUILD_JAR=1 LOG_TAG="_nc${name}" bash sim/memarb/run_unit.sh > "$log" 2>&1
  v=$(grep -aoE "TEST (PASSED|FAILED)" "$log" | tail -1)
  echo "  $name => ${v:-NO-VERDICT}（期望 TEST $expect）"
  grep -aE "\[FAIL\]|NO-VERDICT|BUILD_FAIL" "$log" | head -5 | sed 's/^/     /'
  [ "$v" = "TEST $expect" ] || FAILED_ANY=1
}

only=${NC_ONLY:-ALL}
want() { [ "$only" = "ALL" ] || [ "$only" = "$1" ]; }

if want NC_A; then
  echo "=== NC_A（★ 必须）：配额退化 ⇒ DMA 类被饿死（GEN_WEIGHTS 第 3 项 1 → 0）==="
  restore
  patch "  val GEN_WEIGHTS = Seq(2, 1, 1)" "  val GEN_WEIGHTS = Seq(2, 1, 0)"
  run_case NC_A FAILED
fi

if want NC_B; then
  echo "=== NC_B：配额比打歪（Seq(2,1,1) → Seq(1,1,1)）==="
  restore
  patch "  val GEN_WEIGHTS = Seq(2, 1, 1)" "  val GEN_WEIGHTS = Seq(1, 1, 1)"
  run_case NC_B FAILED
fi

if want NC_C; then
  echo "=== NC_C：授权门与「空闲」脱钩（pickV = anyReq，丢掉 free）==="
  restore
  patch "  io.pickV   := io.free && anyReq" "  io.pickV   := anyReq"
  run_case NC_C FAILED
fi

if want NC_D; then
  echo "=== NC_D：单主人路径插入气泡（pickV 额外要求 budget != 0）==="
  restore
  patch "  io.pickV   := io.free && anyReq" "  io.pickV   := io.free && anyReq && (budget =/= 0.U)"
  run_case NC_D FAILED
fi

# 收尾：恢复源码 + 重生成干净网表
restore
echo "=== 重生成干净网表（回到未打补丁的源码）==="
REBUILD_JAR=1 bash sim/memarb/gen_memarb.sh | tail -2
echo "=== 完成：负对照结论 $([ $FAILED_ANY = 0 ] && echo '各条都按期望翻红' || echo '有异常，见上') ==="
exit $FAILED_ANY
