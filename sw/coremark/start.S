/* start.S -- CoreMark entry for the NaxMini board (RV64).  Reset vector = 0x80000000. */
.section .init
.globl _start
.type _start,@function

#define MSTATUS_FS_INITIAL (1 << 13)

_start:
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop

    la sp, _sp

    /* .data is loaded in place (LMA == VMA), so this copy is a no-op; kept for parity. */
    la a0, _data_lma
    la a1, _data
    la a2, _edata
    bgeu a1, a2, 2f
1:  ld t0, (a0)
    sd t0, (a1)
    addi a0, a0, 8
    addi a1, a1, 8
    bltu a1, a2, 1b
2:

    /* clear .bss */
    la a0, __bss_start
    la a1, _end
    bgeu a0, a1, 2f
1:  sd zero, (a0)
    addi a0, a0, 8
    bltu a0, a1, 1b
2:

    call main

1:  j 1b          /* MAIN_HAS_NORETURN: main never returns; park here if it does */

    .globl _init
_init:
    ret
