/*
 * core_portme.c -- Linux 用户态计时/初始化（见 core_portme.h 的说明）。
 *
 * 计时口径：`clock_gettime(CLOCK_MONOTONIC)` 取纳秒，`EE_TICKS_PER_SEC = 1e9`
 * ⇒ `time_in_secs()` 直接 (ticks / 1e9)。
 *   ⚠️ 用 MONOTONIC 而不是 REALTIME：后者会被 NTP/时区调整干扰。
 */
#include <time.h>

#include "coremark.h"
#include "core_portme.h"

ee_u32 default_num_contexts = 1;

/* SEED_VOLATILE 模式的种子：值必须与 CoreMark 标准一致（也与 sw/coremark/ 的裸机 port 同一个），
 * 否则 CRC 对不上、两条线的分数不可比。seed4 = ITERATIONS 是标准约定。 */
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

#define CORETIMETYPE unsigned long long

static CORETIMETYPE start_time_val, stop_time_val;

static inline void GETMYTIME(CORETIMETYPE *t)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    *t = (CORETIMETYPE)ts.tv_sec * NSECS_PER_SEC + (CORETIMETYPE)ts.tv_nsec;
}
#define MYTIMEDIFF(fin, ini) ((fin) - (ini))

void start_time(void) { GETMYTIME(&start_time_val); }
void stop_time(void)  { GETMYTIME(&stop_time_val); }

CORE_TICKS get_time(void)
{
    return (CORE_TICKS)MYTIMEDIFF(stop_time_val, start_time_val);
}

/* 秒（CoreMark 用 secs_ret = double，见 coremark.h 的 HAS_FLOAT 分支） */
secs_ret time_in_secs(CORE_TICKS ticks)
{
    return (secs_ret)((double)ticks / (double)EE_TICKS_PER_SEC);
}

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc; (void)argv;

    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
        ee_printf("ERROR! Please define ee_ptr_int to a type that holds a pointer!\n");
    if (sizeof(ee_u32) != 4)
        ee_printf("ERROR! Please define ee_u32 to a 32b unsigned type!\n");
    (void)start_time_val; (void)stop_time_val;
    p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
    p->portable_id = 0;
}
