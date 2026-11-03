/* Board keyboard input: the serial console acts as a raw key source.
 * This file is only compiled into the board binary; the host uses SDL. */
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE 1
#endif
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include "platform.h"
#include "board_touch.h"

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdlib.h>
#include <termios.h>
#include <unistd.h>

#define UART_DEFAULT_DEVICE "/dev/ttyS0"

/* A lone ESC is reported after this quiet period so it is not confused
 * with the start of a split arrow-key sequence. */
#define UART_ESC_TIMEOUT_MS 30

static int s_fd = -1;
static bool s_open_tried;
static bool s_disabled;

/* Boot-to-GUI images leave getty on /dev/ttyS0: opening the port as a raw
 * keyboard would steal its bytes, so --no-uart disables this source and only
 * gpio-keys (KEY4) and the touch panel drive the UI. */
void platform_uart_keyboard_disable(void)
{
    s_disabled = true;
}
static bool s_have_termios;
static struct termios s_saved_tio;

/* 0 = normal, 1 = after ESC, 2 = after ESC '['. */
static int s_esc_state;
static uint32_t s_esc_ms;
static int s_pushback = -1;

static void uart_restore(void)
{
    if (s_fd < 0) return;
    if (s_have_termios) {
        tcsetattr(s_fd, TCSANOW, &s_saved_tio);
        s_have_termios = false;
    }
    close(s_fd);
    s_fd = -1;
}

static void uart_open(void)
{
    if (s_fd >= 0 || s_open_tried || s_disabled) return;
    s_open_tried = true;

    const char *dev = getenv("UI_TTY");
    if (!dev || !*dev) dev = UART_DEFAULT_DEVICE;

    int fd = open(dev, O_RDONLY | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) {
        platform_log("input: cannot open UART keyboard device");
        return;
    }

    if (tcgetattr(fd, &s_saved_tio) == 0) {
        struct termios raw = s_saved_tio;
        cfmakeraw(&raw);
        raw.c_cc[VMIN] = 0;
        raw.c_cc[VTIME] = 0;
        if (tcsetattr(fd, TCSANOW, &raw) == 0) s_have_termios = true;
    }
    /* A UART that is not a tty still works as a byte stream. */
    s_fd = fd;
    atexit(uart_restore);
}

/* Returns one byte, or -1 when the non-blocking device has no data. */
static int uart_get_byte(void)
{
    if (s_pushback >= 0) {
        int c = s_pushback;
        s_pushback = -1;
        return c;
    }
    unsigned char c;
    ssize_t n = read(s_fd, &c, 1);
    if (n == 1) return (int)c;
    return -1;
}

static void key_set(ui_key_t *key, ui_key_type_t type)
{
    key->type = type;
    key->ch = 0;
}

bool platform_poll_key(ui_key_t *key)
{
    if (!key) return false;
    if (board_key3_poll(key)) return true;

    uart_open();
    if (s_fd < 0) return false;

    uint32_t now = platform_time_ms();
    if (s_esc_state != 0 &&
        (uint32_t)(now - s_esc_ms) >= UART_ESC_TIMEOUT_MS) {
        s_esc_state = 0;
        key_set(key, UI_KEY_ESC);
        return true;
    }

    for (;;) {
        int c = uart_get_byte();
        if (c < 0) return false;

        if (s_esc_state == 2) {
            s_esc_state = 0;
            switch (c) {
            case 'A': key_set(key, UI_KEY_UP);    return true;
            case 'B': key_set(key, UI_KEY_DOWN);  return true;
            case 'C': key_set(key, UI_KEY_RIGHT); return true;
            case 'D': key_set(key, UI_KEY_LEFT);  return true;
            default:
                /* Not a recognised arrow; report the ESC and keep the byte. */
                s_pushback = c;
                key_set(key, UI_KEY_ESC);
                return true;
            }
        }
        if (s_esc_state == 1) {
            if (c == '[') {
                s_esc_state = 2;
                continue;
            }
            s_esc_state = 0;
            s_pushback = c;
            key_set(key, UI_KEY_ESC);
            return true;
        }

        switch (c) {
        case 0x1B:
            s_esc_state = 1;
            s_esc_ms = now;
            continue;
        case '\r':
        case '\n':
            key_set(key, UI_KEY_ENTER);
            return true;
        case '\t':
            key_set(key, UI_KEY_TAB);
            return true;
        case 0x7F:
        case '\b':
            key_set(key, UI_KEY_BACKSPACE);
            return true;
        case 0x03:
            key_set(key, UI_KEY_CTRL_C);
            return true;
        case 0x04:
            key_set(key, UI_KEY_CTRL_D);
            return true;
        case 0x17:
            key_set(key, UI_KEY_CTRL_W);
            return true;
        default:
            if (c >= 32 && c <= 126) {
                key_set(key, UI_KEY_CHAR);
                key->ch = (char)c;
                return true;
            }
            /* Ignore other control bytes. */
            break;
        }
    }
}
