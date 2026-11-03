#!/usr/bin/env bash
# ============================================================================
# hubfix_ab.sh -- T33 的 A/B：对"打过 F2 的网表"建装置并跑 repro + 正控
#
# 用法：  bash scripts/hubfix_ab.sh            # 缺省用 rtl_hubfix / obj_dir_hubfix
#         RTL_DIR=rtl/hubfix OBJ=obj_dir_x bash scripts/hubfix_ab.sh
#
# 判据（预登记）：
#   0) 与交付 rtl/NaxSocMini.v 的差异**只应集中在 slots_valids 那一处逻辑**
#   1) 正控  probe_console_pack  => TEST PASSED / frames=8 cyc=82918（默认行为不变）
#   2) repro probe_t29_pure      => 不再 timeout（出现 T29E / 帧数不再是 7）
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
RTL_DIR=${RTL_DIR:-rtl_hubfix}
OBJ=${OBJ:-obj_dir_hubfix}

[ -f "$RTL_DIR/NaxSocMini.v" ] || { echo "缺 $RTL_DIR/NaxSocMini.v（还没生成？）"; exit 1; }

echo "===== 0) 网表对账：F2 是不是唯一差异 ====="
grep -n "slots_valids <=" "$RTL_DIR/NaxSocMini.v" | head -3
echo "--- delivered(rtl/) 里同一行 ---"
grep -n "slots_valids <=" rtl/NaxSocMini.v | head -3
echo "--- 逐行差异（期望：只有 slots_valids 那一行 / 或完全无差异之外的少量行）---"
diff rtl/NaxSocMini.v "$RTL_DIR/NaxSocMini.v" | head -30
echo "(diff 行数：$(diff rtl/NaxSocMini.v "$RTL_DIR/NaxSocMini.v" | grep -c '^[<>]' || true) )"

echo
echo "===== 建装置（与 obj_dir_m2g2peek 同参数）====="
verilator --cc --exe --build -j 8 -Wno-fatal -DNAXMINI_DBG_PBUS --top-module nax_mini_soc \
  board/nax_mini_soc.v "$RTL_DIR/NaxSocMini.v" rtl/NaxMiniGlue.v \
  rtl/vendor/RamXilinx.v rtl/vendor/Ram_1w_1ra.v sim/tb_naxmini.cpp \
  -CFLAGS "-DTB_PEEK_CODE=1" -CFLAGS -DBUS_BYTES=8 -o naxminip --Mdir "$OBJ" 2>&1 | tail -3
[ -x "$OBJ/naxminip" ] || { echo "建装置失败"; exit 1; }

echo
echo "===== 1) 正控（期望 TEST PASSED / frames=8 cyc=82918）====="
SOC_PROG='sim/probe_console_pack.bin@0x80000000' SOC_MAX_CYC=200000 ./"$OBJ"/naxminip 2>&1 \
  | grep -E "^TEST PASSED|^FAIL" | tail -2

echo
echo "===== 2) repro probe_t29_pure（期望不再 timeout）====="
SOC_MEM_MIB=256 SOC_EXPECT='T29E' SOC_MAX_CYC=700000 \
  SOC_PROG='sim/probe_t29_pure.bin@0x80000000' ./"$OBJ"/naxminip 2>&1 \
  | grep -E "^TEST PASSED|^FAIL" | tail -2
