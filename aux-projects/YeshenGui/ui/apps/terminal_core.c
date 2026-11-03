#include "terminal_core.h"

#include <stdlib.h>
#include <string.h>

/* Minimal line-oriented screen model for the GUI terminal. It keeps the last
 * TERM_SCROLLBACK lines and strips CSI/OSC/charset escapes; SGR colors are
 * intentionally ignored (TERM=dumb on the shell side). */
struct term_screen {
    char lines[TERM_SCROLLBACK][TERM_COLS + 1];
    int count;
    int row;
    int col;
    int esc;
    char text[TERM_SCROLLBACK * (TERM_COLS + 1) + 1];
};

term_screen_t *term_screen_create(void)
{
    term_screen_t *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->count = 1;
    s->lines[0][0] = '\0';
    return s;
}

void term_screen_free(term_screen_t *s)
{
    free(s);
}

static void new_line(term_screen_t *s)
{
    if (s->row + 1 >= TERM_SCROLLBACK) {
        memmove(s->lines[0], s->lines[1],
                sizeof(s->lines[0]) * (TERM_SCROLLBACK - 1));
        s->row = TERM_SCROLLBACK - 1;
        memset(s->lines[s->row], 0, sizeof(s->lines[s->row]));
        s->count = TERM_SCROLLBACK;
    } else {
        s->row++;
        if (s->row + 1 > s->count) s->count = s->row + 1;
        memset(s->lines[s->row], 0, sizeof(s->lines[s->row]));
    }
    s->col = 0;
}

static void put_char(term_screen_t *s, char c)
{
    if (s->col >= TERM_COLS) new_line(s);
    size_t len = strlen(s->lines[s->row]);
    if (s->col > (int)len) {
        memset(s->lines[s->row] + len, ' ', (size_t)(s->col - (int)len));
        len = (size_t)s->col;
    }
    s->lines[s->row][s->col] = c;
    if ((size_t)s->col >= len) s->lines[s->row][s->col + 1] = '\0';
    s->col++;
}

static void backspace(term_screen_t *s)
{
    if (s->col > 0) s->col--;
}

static void tab(term_screen_t *s)
{
    do {
        put_char(s, ' ');
    } while (s->col % 8 != 0);
}

void term_screen_feed(term_screen_t *s, const char *data, size_t len)
{
    if (!s || !data) return;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)data[i];

        if (s->esc == 2) {
            if (c >= 0x40 && c <= 0x7e) s->esc = 0; /* CSI final byte */
            continue;
        }
        if (s->esc == 3) {
            if (c == 0x07) s->esc = 0; /* OSC terminated by BEL */
            continue;
        }
        if (s->esc == 4) {
            s->esc = 0; /* one-byte charset designator */
            continue;
        }
        if (s->esc == 1) {
            if (c == '[') s->esc = 2;
            else if (c == ']') s->esc = 3;
            else if (c == '(' || c == ')') s->esc = 4;
            else s->esc = 0;
            continue;
        }
        if (c == 0x1b) {
            s->esc = 1;
            continue;
        }

        switch (c) {
        case '\r':
            s->col = 0;
            break;
        case '\n':
            new_line(s);
            break;
        case '\b':
            backspace(s);
            break;
        case '\t':
            tab(s);
            break;
        default:
            /* Bytes >= 0x80 are passed through so UTF-8 text reaches the
             * label; the LVGL font decodes it. Column accounting stays
             * byte-based, so a 3-byte hanzi occupies 3 cells here although
             * it renders 2 cells wide. */
            if (c >= 0x20 && c != 0x7f) put_char(s, (char)c);
            else if (c == 0x0b || c == 0x0c) new_line(s);
            break;
        }
    }
}

void term_screen_clear(term_screen_t *s)
{
    if (!s) return;
    s->count = 1;
    s->row = 0;
    s->col = 0;
    s->esc = 0;
    s->lines[0][0] = '\0';
    s->text[0] = '\0';
}

const char *term_screen_text(term_screen_t *s)
{
    if (!s) return "";
    size_t off = 0;
    for (int i = 0; i < s->count; i++) {
        size_t len = strlen(s->lines[i]);
        if (i + 1 < s->count) {
            memcpy(s->text + off, s->lines[i], len);
            off += len;
            s->text[off++] = '\n';
        } else if (len) {
            memcpy(s->text + off, s->lines[i], len);
            off += len;
        }
    }
    s->text[off] = '\0';
    return s->text;
}

int term_screen_line_count(const term_screen_t *s)
{
    return s ? s->count : 0;
}

void term_screen_cursor(const term_screen_t *s, int *row, int *col)
{
    if (row) *row = s ? s->row : 0;
    if (col) *col = s ? s->col : 0;
}
