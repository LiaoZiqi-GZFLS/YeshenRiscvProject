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

## ---- XLEN / ABI / ISA -------------------------------------------------------
## This project is RV32 (VexiiRiscv xlen=32, rv32imac, no F/D => ABI MUST be ilp32).
## The RV64 row (the original NaxYeshenLinux profile) is kept behind #ifdef.
## `_zicsr_zifencei` is declared explicitly: under new binutils/GCC, csr / fence.i
## are no longer implied by -mimac.
##
## NOTE: values are given directly here (not via the upstream XLEN/ABI/ISA
## placeholders); this copy is our verified platform config. The naxmini_setup.sh
## cpp pass only handles #ifdef and leaves everything else as-is.
#ifdef RV32
PLATFORM_RISCV_XLEN = 32
PLATFORM_RISCV_ABI = ilp32
PLATFORM_RISCV_ISA = rv32imac_zicsr_zifencei
#else
PLATFORM_RISCV_XLEN = 64
PLATFORM_RISCV_ABI = lp64
PLATFORM_RISCV_ISA = rv64imac_zicsr_zifencei
#endif
PLATFORM_RISCV_CODE_MODEL = medany

## Blobs to build
## WARNING: the FW_* addresses below are cross-checked against
## scripts/check_addr_map.py (EXPECT), the DTS and the tb SOC_PROG name table.
## ★ Y1-C4b H2b (2026-10-12): the NPU full-frame arena is carved out of kernel RAM at
## [0x8040_0000, 0x8200_0000) (see boards/naxmini/linux/linux_raw.dts reserved-memory,
## task H2) ==> the Linux Image/FDT/initrd MUST live ABOVE 0x8200_0000, else the no-map
## memblock_remove unmaps the kernel own Image and the board will not boot.
## FW_TEXT_START stays at the reset PC 0x8000_0000; FW_JUMP_ADDR (Image entry) moves
## 0x8040_0000 -> 0x8200_0000 (4 MiB aligned: RV32 Sv32 PGDIR=4 MiB; RELOCATABLE=n,
## setup_vm() derives load_pa at run time ==> no re-link needed) and FW_JUMP_FDT_ADDR
## (the a1 handed to Linux) moves 0x80F8_0000 -> 0x82F8_0000.
FW_DYNAMIC=y
FW_TEXT_START=0x80000000
FW_PAYLOAD=n
FW_JUMP=y
FW_JUMP_ADDR=0x82000000
FW_JUMP_FDT_ADDR=0x82F80000
