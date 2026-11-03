#!/bin/bash
# ===================== DDR3Bridge 64bit 改造的负对照（S3）=====================
# 依据 skill 规则 3：每条新判据都要有负对照——把新加的那道门从网表里**单独摘掉**，判据必须翻红。
# 每个用例都是**在 64bit 源码上回退一处**（其余不动），这样"判据是不是在测这一处"是可证的。
# 用法（WSL）：bash sim/ddr3bridge/negctl_ddr3bridge.sh
#   只跑某条：NC_ONLY=NC1 bash sim/ddr3bridge/negctl_ddr3bridge.sh
#   换位宽：  NC_AXI_W=32 bash sim/ddr3bridge/negctl_ddr3bridge.sh
#             （S1 阶段用它证明**装置本身**有区分力；S3 正式跑用默认 64）
#
#   NC1：每笔 DDR 事务的地址步进摘掉（`wqAddr/arAddr + 8.U` → 不加）
#        ⇒ 期望 FAILED（多组写会写到同一处：第 2 组覆盖第 1 组、后半段永远是哨兵；地址纸带也不符）
#        ⚠️ Phase-0 重锚：地址递进的**站点**从 ddr 域搬到了 axi 域（`wqAddr`/`arAddr`），
#           因为"每 32B 组一笔单 beat 事务"的地址现在在 axi 侧按 beat 算好（见文件头"分组语义"）。
#   NC2：每条 CdcFifo 的「本次呈现已取用」标志**不再置位**（`dTaken(dLane) := true.B` 摘掉）
#        ⇒ 期望 FAILED。改前这条门在 DDR3Bridge 里是 `wItemTaken`（写）/`rItemTaken`（读）两个，
#           Phase-0 之后合成**一条**（`CdcFifo` 的 `dTaken`，每条道一个）⇒ 本负对照打在它上面。
#        （`deq.valid` 是电平：不置 'taken' 就会把**同一份呈现**反复收进目的队列 ⇒ 数据重复/错位。）
#   NC3（★ 必须保留）：步进减半（`+ 8.U` → `+ 4.U`，即某处 spec §2 表里写的 `+4`）
#        ⇒ 期望 FAILED：DDR 侧地址单位是 **32bit 字**，一笔 DDR 事务 = 256bit = 32B = **8 字**；
#           +4 字 = 16B ⇒ 第 2 笔与第 1 笔半重叠（byte 16..47）、末 16 B 永远收不到数据。
#           证据另见 Pango DDR3 IP example design（`test_wr_ctrl_v1_0.v`：`init_addr + 8` 每 wready）。
#   NC4（★ 读侧那条门的**另一半**）：`dTaken` **不再清零**（摘掉 `when(!p.io.deq.valid) { dTaken(i) := false }`）
#        ⇒ 期望 FAILED（标志一旦置 1 就永不复位 ⇒ 该道被封死 ⇒ 后续呈现收不进来、跑不完/数据缺）。
#           （NC2 摘"置位"、NC4 摘"清零"，同一道门的两个半边 —— 改前的 wItemTaken/rItemTaken 各占一半。）
#   NC5（Task 19）：**B 通道不再回带 AW id**（`axi.b.bid := doneCdc.io.deq.bits` → `:= 0.U`）
#        ⇒ 期望 FAILED：判 ⑥ 要求 `B.bid == awid`（旧 7 条 awid=5、末条 BID 用例 awid=0xA；
#           Phase-0 的 B2B 写作业还要求 8 个 B **按序** 回带 1..8）。
#           **为什么这条负对照重要**：本核 D$ 的写回槽是按 AXI **write id** 选的
#           （`rtl/NaxSocMini.v` 的 `writeback_slots_N_fire`），B 回带的 id 错了会把写回响应
#           投到错槽 ⇒ `writebackBusy` 永不清 ⇒ 前端被 halt。
#   NC6（★ Phase-0 新增）：把多未完成档位打成 **1**（`LANES = 4`→`1`、`DEPTH = 4`→`1`）
#        ⇒ 期望 FAILED —— 这是本轮**承重**的那条负对照：
#           · 功能仍然逐字节对（B2B 的"逐字节/纸带/B-rlast"三条照过）；
#           · 但 DUT 自报的未完成峰值 `outW/outR ≤ DEPTH = 1`（**由 AXI 口信用计数结构保证**）
#             ⇒ `[OUTSTANDING]` 判据必然翻红 ⇒ 证明"FIFO 深度/道数"是**承重的**、不是摆设。
# ⚠️ 补丁一律走 `sim/ddr3bridge/patch_exact.py`（精确串替换 + **替换不到就报错**）：
#    用 sed 曾静默 no-op，把"没打上补丁"读成了"负对照通过"（YeshenCore §5.13.8）。
set -u
# 仓库根从脚本自身位置反推（同 run_unit.sh 的说明：写死过 NaxYeshenLinux ⇒ 会打错树）
R="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$R" || exit 2
SRC=src/soc/DDR3Bridge.scala
CDC=src/soc/CDCQueue.scala
BAK=/tmp/ddr3bridge_v1_fixed.scala
BAKC=/tmp/cdcqueue_v1_fixed.scala
cp "$SRC" "$BAK" || exit 2
cp "$CDC" "$BAKC" || exit 2

FAILED_ANY=0
AXI_W_NC=${NC_AXI_W:-64}

restore() { cp "$BAK" "$SRC"; cp "$BAKC" "$CDC"; }
trap restore EXIT

patch() {   # $1=旧串 $2=新串（替换不到直接算失败）；只打 DDR3Bridge.scala
  python3 sim/ddr3bridge/patch_exact.py "$SRC" "$1" "$2" || { echo "  ✗ 补丁未命中：$1"; FAILED_ANY=1; return 1; }
}
patchc() {  # $1=旧串 $2=新串；打 CDCQueue.scala（CdcFifo 的「本次呈现已取用」门）
  python3 sim/ddr3bridge/patch_exact.py "$CDC" "$1" "$2" || { echo "  ✗ 补丁未命中(CDCQueue)：$1"; FAILED_ANY=1; return 1; }
}

run_case() {   # $1=名字  $2=期望判定
  local name=$1 expect=$2 v=""
  local log="sim/reglogs/nc_ddr3bridge_${name}_w${AXI_W_NC}.log"
  # LOG_TAG 让负对照的**内层**单元日志另起名字，别把 S1/S2 的阳性日志冲掉
  AXI_W=$AXI_W_NC LOG_TAG="_nc${name}" bash sim/ddr3bridge/run_unit.sh > "$log" 2>&1
  v=$(grep -aoE "TEST (PASSED|FAILED)" "$log" | tail -1)
  echo "  $name (AXI_W=$AXI_W_NC) => ${v:-NO-VERDICT}（期望 TEST $expect）"
  grep -aE "\[FAIL\]|NO-VERDICT|BUILD_FAIL" "$log" | head -4 | sed 's/^/     /'
  [ "$v" = "TEST $expect" ] || FAILED_ANY=1
}

only=${NC_ONLY:-ALL}
want() { [ "$only" = "ALL" ] || [ "$only" = "$1" ]; }

if want NC1; then
  echo "=== NC1：每笔 DDR 事务不再递进地址（+8 字）==="
  cp "$BAK" "$SRC"; cp "$BAKC" "$CDC"
  patch "wqAddr    := wqAddr + 8.U" "wqAddr    := wqAddr"
  patch "arAddr := arAddr + 8.U; arGrpLeft := arGrpLeft - 1.U" "arAddr := arAddr; arGrpLeft := arGrpLeft - 1.U"
  run_case nc1 FAILED
fi

if want NC2; then
  echo "=== NC2：CdcFifo 目的域不再轮转（dLane 冻结 ⇒ 只收第 0 道）==="
  cp "$BAK" "$SRC"; cp "$BAKC" "$CDC"
  patchc "    dLane := (dLane + 1.U) & lMask                                     // 同源域：道号按 lanes 取模" "    dLane := dLane"
  run_case nc2 FAILED
fi

if want NC3; then
  echo "=== NC3（★保留）：步进减半（+8 字 → +4 字，= 16B，spec §2 表里的 +4）==="
  cp "$BAK" "$SRC"; cp "$BAKC" "$CDC"
  patch "wqAddr    := wqAddr + 8.U" "wqAddr    := wqAddr + 4.U"
  patch "arAddr := arAddr + 8.U; arGrpLeft := arGrpLeft - 1.U" "arAddr := arAddr + 4.U; arGrpLeft := arGrpLeft - 1.U"
  run_case nc3 FAILED
fi

if want NC4; then
  echo "=== NC4（★）：CdcFifo 的「本次呈现已取用」不再清零（标志一旦置 1 就永不复位）==="
  cp "$BAK" "$SRC"; cp "$BAKC" "$CDC"
  patchc "    when(!p.io.deq.valid) { dTaken(i) := false.B }                      // 呈现撤销 ⇒ 允许取下一份
" ""
  run_case nc4 FAILED
fi

if want NC5; then
  echo "=== NC5（Task 19）：B 通道不再回带 AW id（axi.b.bid → 0.U）==="
  cp "$BAK" "$SRC"; cp "$BAKC" "$CDC"
  # 精确串替换：**替换不到就报错**（patch_exact.py 的纪律）；这一处就是"回带"这道门本身。
  patch "  axi.b.bid    := doneCdc.io.deq.bits
" "  axi.b.bid    := 0.U
"
  run_case nc5 FAILED
fi

if want NC6; then
  echo "=== NC6（★Phase-0 承重项）：多未完成档位打成 1（LANES/DEPTH = 1）==="
  cp "$BAK" "$SRC"; cp "$BAKC" "$CDC"
  patch "  private val LANES = 4" "  private val LANES = 1"
  patch "  private val DEPTH = 4" "  private val DEPTH = 1"
  run_case nc6 FAILED
fi

# 收尾：恢复源码并**重生成干净网表**（别把负对照的网表留在工作区）
# ⚠️ 必须 REBUILD_JAR=1：jar 里嵌的是**编译过的** DDR3Bridge，改过源码就得重编 jar，
#    否则这里会用上一轮的补丁版代码再生成一次"干净"网表。
restore
echo "=== 重生成干净网表（回到未打补丁的源码）==="
REBUILD_JAR=1 bash sim/ddr3bridge/gen_bridge.sh | tail -2

echo "=== 完成：负对照结论 $([ $FAILED_ANY = 0 ] && echo '各条都按期望翻红' || echo '有异常，见上') ==="
exit $FAILED_ANY
