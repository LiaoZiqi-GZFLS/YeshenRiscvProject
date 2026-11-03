/* test_mini.c -- bisection probe: same start.S / app.ld / uart port as CoreMark, but the
 * smallest possible C main.  If this prints, the port is fine and any failure is CoreMark-specific. */
#include "core_portme.h"

void uart_init(void);
int uart_putc(int c);
static void puts_(const char *s)
{
    while (*s) uart_putc(*s++);
}

volatile int g_sink;

int main(void)
{
    uart_init();
    puts_("MINI-OK\n");
    g_sink = 0x1234;
    puts_("MINI-DONE\n");
    for (;;) { }
    return 0;
}
