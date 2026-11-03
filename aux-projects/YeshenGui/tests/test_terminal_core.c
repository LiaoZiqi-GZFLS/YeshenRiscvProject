#include "ui/apps/terminal_core.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static void feed_str(term_screen_t *s, const char *text)
{
    term_screen_feed(s, text, strlen(text));
}

int main(void)
{
    term_screen_t *s = term_screen_create();
    assert(s);

    assert(strcmp(term_screen_text(s), "") == 0);

    feed_str(s, "hello");
    assert(strcmp(term_screen_text(s), "hello") == 0);

    term_screen_clear(s);
    feed_str(s, "abc\rX");
    assert(strcmp(term_screen_text(s), "Xbc") == 0);

    term_screen_clear(s);
    feed_str(s, "abc\bX");
    assert(strcmp(term_screen_text(s), "abX") == 0);

    term_screen_clear(s);
    feed_str(s, "a\tb");
    assert(strcmp(term_screen_text(s), "a       b") == 0);

    term_screen_clear(s);
    feed_str(s, "\x1b[31mred\x1b[0m");
    assert(strcmp(term_screen_text(s), "red") == 0);

    term_screen_clear(s);
    feed_str(s, "\x1b[");
    feed_str(s, "31mred");
    assert(strcmp(term_screen_text(s), "red") == 0);

    term_screen_clear(s);
    feed_str(s, "\x07ok");
    assert(strcmp(term_screen_text(s), "ok") == 0);

    term_screen_clear(s);
    {
        char line[TERM_COLS + 8];
        for (int i = 0; i < TERM_COLS + 5; i++) line[i] = 'x';
        line[TERM_COLS + 5] = '\0';
        feed_str(s, line);
        const char *text = term_screen_text(s);
        assert(strlen(text) == (size_t)(TERM_COLS + 1 + 5));
        assert(text[TERM_COLS] == '\n');
        for (int i = 0; i < TERM_COLS; i++) assert(text[i] == 'x');
        for (int i = 0; i < 5; i++) assert(text[TERM_COLS + 1 + i] == 'x');
    }

    term_screen_clear(s);
    for (int i = 0; i < 250; i++) {
        char line[32];
        int n = snprintf(line, sizeof(line), "L%03d\n", i);
        term_screen_feed(s, line, (size_t)n);
    }
    assert(term_screen_line_count(s) == TERM_SCROLLBACK);
    {
        const char *text = term_screen_text(s);
        assert(strncmp(text, "L051\n", 5) == 0);
        assert(strstr(text, "L050\n") == NULL);
        assert(strstr(text, "L249\n") != NULL);
    }

    term_screen_clear(s);
    assert(strcmp(term_screen_text(s), "") == 0);
    assert(term_screen_line_count(s) == 1);

    term_screen_free(s);
    puts("terminal_core: PASS");
    return 0;
}
