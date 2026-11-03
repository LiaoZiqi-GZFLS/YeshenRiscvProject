/*
 * core_portme.c -- board timing + console for CoreMark on NaxMini.
 *
 * Time base = mtime via `rdtime`. In NaxSocMini the CLINT increments mtime once per socClk
 * (rtl/NaxSocMini.v: `logic_time <= logic_time + 1` gated only by !stop) and soc_clk = 100 MHz
 * (pll_100m_125m), so EE_TICKS_PER_SEC = 100e6.
 *
 * Console = the 16550 at 0xF0001000 (8N1; DLL=54 -> 115200-ish at 100 MHz), the same block the
 * probe and Linux use. THRE (LSR bit 5) means "FIFO empty" in our RTL, so polling it is safe with
 * the 16-deep TX FIFO.
 */
#include "coremark.h"
#include "core_portme.h"

#define UART_BASE 0xF0001000u
#define UART_THR  (*(volatile unsigned int *)(UART_BASE + 0x00))
#define UART_DLM  (*(volatile unsigned int *)(UART_BASE + 0x04))
#define UART_LCR  (*(volatile unsigned int *)(UART_BASE + 0x0C))
#define UART_LSR  (*(volatile unsigned int *)(UART_BASE + 0x14))

static unsigned long rdtime32(void)
{
    unsigned int t;
    __asm__ volatile("rdtime %0" : "=r"(t));
    return t;
}

void uart_init(void)
{
    UART_LCR = 0x80;      /* DLAB=1 -> 0x00/0x04 are DLL/DLM */
    UART_THR = 54;        /* DLL: 100 MHz / (16*54) = 115740 baud */
    UART_DLM = 0;
    UART_LCR = 0x03;      /* 8N1, DLAB=0 */
}

int uart_putc(int c)
{
    while ((UART_LSR & 0x20) == 0) { }   /* wait THRE */
    UART_THR = (unsigned int)(c & 0xFF);
    return c;
}

/* ---- CoreMark timing interface ---- */
#define CORETIMETYPE            unsigned long
#define GETMYTIME(_t)           (*_t = rdtime32())
#define MYTIMEDIFF(fin, ini)    ((fin) - (ini))
#define TIMER_RES_DIVIDER       1
#define SAMPLE_TIME_IMPLEMENTATION 1
#define EE_TICKS_PER_SEC        100000000

static CORETIMETYPE start_time_val, stop_time_val;

void start_time(void) { GETMYTIME(&start_time_val); }
void stop_time(void)  { GETMYTIME(&stop_time_val); }

CORE_TICKS get_time(void)
{
    return (CORE_TICKS)MYTIMEDIFF(stop_time_val, start_time_val);
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
    return ((secs_ret)ticks) / (secs_ret)EE_TICKS_PER_SEC;
}

ee_u32 default_num_contexts = 1;

volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    uart_init();
    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
        ee_printf("ERROR! ee_ptr_int is not pointer sized\n");
    if (sizeof(ee_u32) != 4)
        ee_printf("ERROR! ee_u32 is not 32b\n");
    p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
    p->portable_id = 0;
}
