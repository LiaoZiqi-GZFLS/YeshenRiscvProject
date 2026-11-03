/* sim.h -- output hook for ee_printf.c (which #includes <sim.h> and calls sim_putchar).
 * On the board "sim" is just the on-SoC 16550; uart_putc lives in core_portme.c. */
#pragma once

int uart_putc(int c);

static inline int sim_putchar(int c)
{
    return uart_putc(c);
}
