#!/usr/bin/env bash
# ============================================================================
# promote_hubfix.sh -- T33：把 F2 网表升为交付（替换 rtl/NaxSocMini.v）
#
# 前提（都要先绿）：
#   - scripts/hubfix_ab.sh 已过（正控 frames=8 cyc=82918 + repro TEST PASSED）
#   - P1 主判据（四镜像 → VEXIIYESHEN-OK）已在 F2 装置上过
# 行为：
#   1) 记录替换前 rtl/NaxSocMini.v 的 sha256（可回退的锚点）
#   2) 校验 rtl_hubfix/NaxSocMini.v 与它的功能差异**只有 slots_valids 一行**
#   3) 覆盖 rtl/NaxSocMini.v，并再次打印 sha256 与差异行数（自证）
#   4) 提示：重跑 dev_map/PnR 对账 + 更新 docs/交付-2026-09-30.md 的 sha256
# 注意：这是**改动交付物**的动作，按项目纪律应当由控制器下令后再跑。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

NEW=rtl_hubfix/NaxSocMini.v
OLD=rtl/NaxSocMini.v
[ -f "$NEW" ] || { echo "缺 $NEW"; exit 1; }

echo "== 1) 替换前锚点 =="
BEFORE=$(sha256sum "$OLD" | awk '{print $1}')
echo "   $OLD = $BEFORE"

echo "== 2) 功能差异校验（期望只有 slots_valids）=="
NDIFF=$(diff "$OLD" "$NEW" | grep -c '^[<>]' || true)
echo "   diff 行数（含生成器 hash 注释）= $NDIFF"
diff "$OLD" "$NEW" | grep '^[<>]' | grep -v '^[<>] //' | grep -vE 'slots_valids <=' && {
  echo "   !! 除了 slots_valids 还有其它功能差异 —— 停手，先查"; exit 1; } || true
echo "   OK：功能差异只在 slots_valids"

echo "== 3) 覆盖并自证 =="
cp "$NEW" "$OLD"
AFTER=$(sha256sum "$OLD" | awk '{print $1}')
echo "   $OLD = $AFTER"
echo "   rtl_hubfix = $(sha256sum "$NEW" | awk '{print $1}')"
[ "$BEFORE" != "$AFTER" ] && echo "   OK：已替换" || echo "   ?? 没变"

echo
echo "== 4) 还要做（见 spec §0.1/§6）=="
echo "   !! 关键：pds/run_pnr.tcl 的默认路径(A)会**复用 Task-14 的 dev_map 工程**，"
echo "      那个工程里的 mapped 网表是**旧 rtl/NaxSocMini.v** 来的 => 必须重建，"
echo "      否则 PnR/比特流还是旧网表。用：NAXMINI_PNR_FRESH=1"
echo "   - dev_map（期望 0 error / 0 DRC）："
echo "       /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file pds/run_devmap.tcl > sim/reglogs/t33_devmap.log 2>&1"
echo "   - 资源/时序对账基线（M0-c / 交付文档）：LUT 22327(13.97%)、CPU 域 MET、WNS 见 report_timing"
echo "   - 单 seed PnR + 比特流："
echo "       NAXMINI_PNR_FRESH=1 /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file pds/run_pnr.tcl > sim/reglogs/t33_pnr.log 2>&1"
echo "     （判据：grep -c 'All Constraints Met' / 'NAXMINI_PNR_DONE' / 比特流大小，小时级、放后台）"
echo "   - 更新 docs/交付-2026-09-30.md 里 rtl/NaxSocMini.v 的 sha256 + 新比特流信息"
echo "   - 上游两仓零改动自证：bash scripts/make_nax_fork.sh 会再验一次"
