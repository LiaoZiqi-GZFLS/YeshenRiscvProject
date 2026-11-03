/*
 * core_portme.h -- CoreMark 的 **Linux 用户态** port（VexiiYeshenLinux / RV32）。
 *
 * 与同目录树上的裸机 port（`sw/coremark/port/`）的区别：
 *   · 时钟 = `clock_gettime(CLOCK_MONOTONIC)`（纳秒）—— 裸机那份用 `rdtime` CSR；
 *   · 输出 = libc 的 `printf`（HAS_PRINTF=1 ⇒ core_main 里的 ee_printf 直接映射过去）；
 *   · 单进程（MULTITHREAD=1 但 fork/socket 全关）—— 我们目的是**这台机器的分数**，不是多核口径。
 *
 * ⚠️ XLEN=32：`ee_ptr_int` 必须是指针宽度（rv32 上 `long` 正好 32 位）。
 */
#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#include <stddef.h>

#define HAS_FLOAT  1
#define HAS_TIME_H 1
#define USE_CLOCK  0
#define HAS_STDIO  1
#define HAS_PRINTF 1

#define COMPILER_VERSION "GCC" __VERSION__
#define COMPILER_FLAGS   FLAGS_STR
#define MEM_LOCATION     "STATIC"

typedef unsigned long long CORE_TICKS;
#define NSECS_PER_SEC    1000000000ULL
#define EE_TICKS_PER_SEC 1000000000ULL

/* ★ 必须给真实主频：CoreMark 的 "Coremark/MHz" 那一行只在定义了 CPU_FREQ 时才按它换算，
 *   否则会用上游 linux port 的占位值（实测会打出 "0.15 Coremark/MHz" 这种误导数字，
 *   真值是 148.18 iter/s ÷ 100 MHz = **1.48 CoreMark/MHz**）。
 *   本板 cpu_clk = 板级 PLL CLKOUT0 = **100.000 MHz 精确**（见 board/pll_100m_125m.v）。 */
#define CPU_FREQ         100000000

typedef signed short   ee_s16;
typedef unsigned short ee_u16;
typedef signed int     ee_s32;
typedef double         ee_f32;
typedef unsigned char  ee_u8;
typedef unsigned int   ee_u32;
typedef long           ee_ptr_int;   /* rv32: long = 32bit = 指针宽度 */
typedef size_t         ee_size_t;

#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x)-1) & ~3))

#define SEED_METHOD       SEED_VOLATILE
#define MEM_METHOD        MEM_STATIC
#define MULTITHREAD       1
#define USE_PTHREAD       0
#define USE_FORK          0
#define USE_SOCKET        0
#define MAIN_HAS_NOARGC   1
#define MAIN_HAS_NORETURN 1

extern ee_u32 default_num_contexts;

typedef struct CORE_PORTABLE_S
{
    ee_u8 portable_id;
} core_portable;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

#if !defined(PROFILE_RUN) && !defined(PERFORMANCE_RUN) \
    && !defined(VALIDATION_RUN)
#if (TOTAL_DATA_SIZE == 1200)
#define PROFILE_RUN 1
#elif (TOTAL_DATA_SIZE == 2000)
#define PERFORMANCE_RUN 1
#else
#define VALIDATION_RUN 1
#endif
#endif

#if HAS_PRINTF
#include <stdio.h>
#define ee_printf printf
#endif

#endif /* CORE_PORTME_H */
