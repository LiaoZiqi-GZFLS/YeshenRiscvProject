#pragma once

#include <stddef.h>

#define TERM_COLS 100
#define TERM_SCROLLBACK 200

typedef struct term_screen term_screen_t;

term_screen_t *term_screen_create(void);
void term_screen_free(term_screen_t *s);
void term_screen_feed(term_screen_t *s, const char *data, size_t len);
void term_screen_clear(term_screen_t *s);
const char *term_screen_text(term_screen_t *s);
int term_screen_line_count(const term_screen_t *s);
void term_screen_cursor(const term_screen_t *s, int *row, int *col);
