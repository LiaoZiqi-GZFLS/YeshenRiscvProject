#!/usr/bin/env bash
# Task 13: 64bit 内存口配置的判据装置（**仿真装置专用顶层**，不改任何交付件）
#
# 为什么不能照任务书原样用 board/nax_mini_soc.v：
#   · rtl64/NaxSocMini.v 的 mBus_wdata/wstrb/rdata 是 64bit，board/nax_mini_soc.v 的
#     mbus_* 中间线硬编码 32bit ⇒ 实测 3 条 WIDTHEXPAND（板级顶层那三条 347/348/363）
#     ⇒ 核读回的 64bit 字高半恒 0（假红）。
#   · NaxMiniGlue.io_cpuMem_* 也是 32bit（Chisel 生成产物，已归档）。
#   · sim/tb_naxmini.cpp 的 BUS_BYTES 是常量 4，**没有** AXI_DATA_BYTES 宏
#     （那个宏在 M0-b 的 sim/tb_memmark.cpp 里）⇒ `-CFLAGS -DAXI_DATA_BYTES=8` 对判据装置是空操作。
# ⇒ 用 sim/top_naxsoc64.v（端口表与 board 版逐字一致）+ sim/axi64to32.v（64→32 拆位桥）替换板级顶层。
set -u
cd /mnt/d/code/PDS/NaxYeshenLinux || exit 9

SRC64="sim/top_naxsoc64.v sim/axi64to32.v rtl64/NaxSocMini.v rtl/NaxMiniGlue.v rtl/vendor/RamXilinx.v rtl/vendor/Ram_1w_1ra.v sim/tb_naxmini.cpp"

# 1) 判据装置（无内视；tb 一行都不改）
verilator --cc --exe --build -j 8 -Wno-fatal --top-module nax_mini_soc \
  $SRC64 -o naxmini64 --Mdir obj_dir_naxmini64 \
  > sim/reglogs/t13_64_build.log 2>&1
echo "CRIT64_BUILD_EXIT=$?"
grep -c "Cannot find module" sim/reglogs/t13_64_build.log | sed 's/^/cannot-find-module: /'
ls -l obj_dir_naxmini64/naxmini64 2>/dev/null || echo "(no crit64 binary)"

# 2) 取证装置（TB_PEEK_CODE + NAXMINI_DBG_PBUS：与 T12 同一个 tb 宏组合）
verilator --cc --exe --build -j 8 -Wno-fatal -DNAXMINI_DBG_PBUS --top-module nax_mini_soc \
  $SRC64 -CFLAGS "-DTB_PEEK_CODE=1" -o naxmini64p --Mdir obj_dir_t13peek \
  > sim/reglogs/t13_64peek_build.log 2>&1
echo "PEEK64_BUILD_EXIT=$?"
ls -l obj_dir_t13peek/naxmini64p 2>/dev/null || echo "(no peek64 binary)"
