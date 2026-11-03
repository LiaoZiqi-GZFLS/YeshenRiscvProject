#include "../ui/games/core/snake_core.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    snake_t s;
    snake_init(&s, 42);
    assert(s.len == 3);
    snake_start(&s);
    int hx = s.x[0], hy = s.y[0];
    snake_tick(&s);
    assert(s.status == SNAKE_RUNNING);
    assert(s.x[0] == hx + 1 && s.y[0] == hy);

    snake_init(&s, 42);
    snake_start(&s);
    s.food_x = s.x[0] + 1; s.food_y = s.y[0];
    snake_tick(&s);
    assert(s.len == 4);
    assert(s.score == 10);

    snake_init(&s, 42);
    snake_start(&s);
    for (int i = 0; i < SNAKE_W + 2; i++) snake_tick(&s);
    assert(s.status == SNAKE_OVER);

    printf("test_snake: PASS\n");
    return 0;
}
