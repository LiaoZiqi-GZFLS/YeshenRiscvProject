/*
 * core_portme.h -- CoreMark port for the NaxMini board (PG2L200H, NaxRiscv RV64).
 *
 * Differences vs the upstream naxriscv_sim port:
 *   - timer = the core's own mtime (rdtime), which ticks once per soc_clk (100 MHz);
 *   - console = the 16550 at 0xF0001000 (same one Linux uses), not the sim's 0x10000000;
 *   - MEM_STATIC (no malloc/heap);
 *   - xlen=64: ee_u32 is 32-bit, ee_ptr_int is 64-bit.
 * Kept HAS_FLOAT=1 so CoreMark prints a real fractional score; the CPU has no F/D, so the
 * compiler emits libgcc soft-float calls (both the sim port and this one rely on that).
 */
#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#include <stddef.h>

#define HAS_FLOAT  1
#define HAS_TIME_H 0
#define USE_CLOCK  0
#define HAS_STDIO  0
#define HAS_PRINTF 0

typedef unsigned long long CORE_TICKS;

#define COMPILER_VERSION "GCC" __VERSION__
#define COMPILER_FLAGS   FLAGS_STR
#define MEM_LOCATION     "STATIC"

typedef signed short   ee_s16;
typedef unsigned short ee_u16;
typedef signed int     ee_s32;
typedef double         ee_f32;
typedef unsigned char  ee_u8;
typedef unsigned int   ee_u32;
typedef long           ee_ptr_int;
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

extern int ee_printf(const char *fmt, ...);

#endif /* CORE_PORTME_H */
