##
## SPDX-License-Identifier: BSD-2-Clause
##
## Copyright (c) 2019 Western Digital Corporation or its affiliates.
##
## Authors:
##   Anup Patel <anup.patel@wdc.com>
##

## Compiler flags
platform-cppflags-y =
platform-cflags-y =
platform-asflags-y =
platform-ldflags-y =

## Command for platform specific "make run"
platform-runcmd = echo Bitconnneeect

## ---- XLEN / ABI / ISA（Task 9 填实；上游是 buildroot 现场替换的占位符）----------------
## 核是 **rv64imac**：NaxGen 的 `sw/gen/plugins.scala` 里 withFloat=false / withDouble=false
## ⇒ **没有 F/D**。所以 ABI **必须 lp64（软浮点）**——用 lp64d 会让函数参数/返回值走
## f 寄存器，第一条跨函数调用就是非法指令。与 buildroot 的 naxriscv_sim_raw_defconfig
## 同口径（RV64 + RVM + RVA + RVC，无 FPU）。
## `_zicsr_zifencei` 是为新 binutils/GCC（本机 2.42/13.2）显式声明 csr / fence.i：
## 老版本的 `-march=rv64imac` 隐含它们，新版本不再隐含（会报 "requires ... extension"）。
PLATFORM_RISCV_XLEN = 64
PLATFORM_RISCV_ABI = lp64
PLATFORM_RISCV_ISA = rv64imac_zicsr_zifencei
PLATFORM_RISCV_CODE_MODEL = medany

## Blobs to build
## ⚠️ 下面三个 FW_* 地址与 `scripts/check_addr_map.py` 的台账、DTS、tb 的 SOC_PROG
##    名字表四处对账。
## ★ Y1-C4b H2b（2026-10-12）：NPU arena 的 28 MiB 保留区 [0x8040_0000, 0x8200_0000) 从内核
##    RAM 切走后，Image/FDT 抬到保留区之上（FW_TEXT_START 保持复位 PC 0x8000_0000）。
FW_DYNAMIC=y
FW_TEXT_START=0x80000000
FW_PAYLOAD=n
FW_JUMP=y
FW_JUMP_ADDR=0x82000000
FW_JUMP_FDT_ADDR=0x82F80000
