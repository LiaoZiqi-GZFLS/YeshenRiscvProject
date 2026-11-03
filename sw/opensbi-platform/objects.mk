#
# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2019 Western Digital Corporation or its affiliates.
#
# Authors:
#   Anup Patel <anup.patel@wdc.com>
#
# =============================================================================
# Task 22（M2-b）：OpenSBI v1.6 平台 —— 本文件是 v1.6 唯一会被 Makefile 自动 include 的
#                 "平台配置文件"（`Makefile` 里 `include $(platform-object-mks)`，
#                 而 `platform-object-mks = find $(platform_src_dir) -iname objects.mk`）。
#
# ★ 为什么还需要下面那行 `-include`：v1.6 的 Makefile **不再** include 平台的 `config.mk`
#   （全仓库 `grep -rn config\.mk Makefile` 无命中），FW_*/PLATFORM_RISCV_* 现在由各平台的
#   `objects.mk` 承载（对比 `platform/template/objects.mk`、`platform/kendryte/k210/objects.mk`）。
#   我们的三个 FW_* 与 XLEN/ABI/ISA 按 Task 9/22 的契约「一字不改」地留在同目录 `config.mk` 里
#   （`scripts/check_addr_map.py` 的台账也是读那个文件），所以这里显式把它拉进来。
#   顺序上放在最前面：本文件在 Makefile 的 `ifndef PLATFORM_RISCV_ABI/ISA`（行 ~287）
#   **之前**被 include，所以 config.mk 里的值会赢过 Makefile 的默认值（默认会是 rv64imafdc！）。
# =============================================================================

-include $(platform_src_dir)/config.mk

# config.mk 没被 include 进来 = 立刻炸，绝不静默用上 OpenSBI 的默认跳转地址/ISA
ifeq ($(strip $(FW_JUMP_ADDR)),)
$(error naxmini platform: $(platform_src_dir)/config.mk was not included (platform_src_dir undefined?) -- refusing to build with default FW_JUMP_ADDR/ISA)
endif

#
# Compiler pre-processor flags
platform-cppflags-y =

# C Compiler and assembler flags.
platform-cflags-y =
platform-asflags-y =

# Linker flags: additional libraries and object files that the platform
# code needs can be added here
platform-ldflags-y =

# Space separated list of object file names to be compiled for the platform
platform-objs-y += platform.o

# NOTE: 老版（v0.8）那行 "-I$(BR2_EXTERNAL_NAXMINI_PATH)/boards/naxmini/opensbi" 已删除 ——
#       v1.6 是**把整个平台目录拷进 `<opensbi>/platform/<name>/`** 后再 `make PLATFORM=<name>`
#       （我们的 `sw/buildroot-external/package/opensbi-ext/opensbi-ext.mk` 的 PRE_BUILD_HOOK 与
#        `scripts/build_opensbi.sh` 都是这个口径），platform.c 不 include 任何本地头，
#       也不需要那个只有 buildroot 才有的变量。
