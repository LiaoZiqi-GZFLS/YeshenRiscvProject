#include "snake_core.h"

#include <string.h>

#define SNAKE_START_LEN 3
#define SNAKE_START_TICK 240
#define SNAKE_MIN_TICK 120
#define SNAKE_FOOD_STEP 5

/* 0 up, 1 right, 2 down, 3 left */
static const int8_t DX[4] = {0, 1, 0, -1};
static const int8_t DY[4] = {-1, 0, 1, 0};

uint32_t snake_rand(snake_t *s)
{
    uint32_t x = s->rng ? s->rng : 0x9E3779B9u;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    s->rng = x;
    return x;
}

static bool occupied(const snake_t *s, int x, int y)
{
    for (int i = 0; i < s->len; i++) {
        if (s->x[i] == x && s->y[i] == y) return true;
    }
    return false;
}

static void place_food(snake_t *s)
{
    if (s->len >= SNAKE_MAX) {
        s->food_x = -1;
        s->food_y = -1;
        return;
    }

    for (int i = 0; i < 200; i++) {
        int x = (int)(snake_rand(s) % SNAKE_W);
        int y = (int)(snake_rand(s) % SNAKE_H);
        if (!occupied(s, x, y)) {
            s->food_x = (int8_t)x;
            s->food_y = (int8_t)y;
            return;
        }
    }

    for (int y = 0; y < SNAKE_H; y++) {
        for (int x = 0; x < SNAKE_W; x++) {
            if (!occupied(s, x, y)) {
                s->food_x = (int8_t)x;
                s->food_y = (int8_t)y;
                return;
            }
        }
    }

    s->food_x = -1;
    s->food_y = -1;
}

void snake_init(snake_t *s, uint32_t seed)
{
    memset(s, 0, sizeof(*s));
    s->rng = seed ? seed : 1u;
    s->len = SNAKE_START_LEN;
    s->dir = 1;
    s->next_dir = 1;
    s->tick_ms = SNAKE_START_TICK;
    s->status = SNAKE_READY;

    int hx = SNAKE_W / 2;
    int hy = SNAKE_H / 2;
    for (int i = 0; i < SNAKE_START_LEN; i++) {
        s->x[i] = (int8_t)(hx - i);
        s->y[i] = (int8_t)hy;
    }

    place_food(s);
}

void snake_start(snake_t *s)
{
    if (s->status == SNAKE_OVER) return;
    s->status = SNAKE_RUNNING;
}

void snake_set_dir(snake_t *s, int dir)
{
    if (dir < 0 || dir > 3) return;
    if (s->status == SNAKE_OVER) return;
    if (dir == (s->next_dir + 2) % 4) return; /* no 180 degree reversal */
    s->next_dir = (int8_t)dir;
}

void snake_tick(snake_t *s)
{
    if (s->status != SNAKE_RUNNING) return;

    s->dir = s->next_dir;
    int hx = s->x[0] + DX[s->dir];
    int hy = s->y[0] + DY[s->dir];

    if (hx < 0 || hx >= SNAKE_W || hy < 0 || hy >= SNAKE_H) {
        s->status = SNAKE_OVER;
        return;
    }

    bool grow = (hx == s->food_x && hy == s->food_y);

    /* When not growing the tail vacates its cell this tick. */
    int body = grow ? s->len : s->len - 1;
    for (int i = 0; i < body; i++) {
        if (s->x[i] == hx && s->y[i] == hy) {
            s->status = SNAKE_OVER;
            return;
        }
    }

    if (grow && s->len < SNAKE_MAX) {
        for (int i = s->len; i > 0; i--) {
            s->x[i] = s->x[i - 1];
            s->y[i] = s->y[i - 1];
        }
        s->x[0] = (int8_t)hx;
        s->y[0] = (int8_t)hy;
        s->len++;
        s->score += 10;

        if ((s->len - SNAKE_START_LEN) % SNAKE_FOOD_STEP == 0) {
            if (s->tick_ms > SNAKE_MIN_TICK + SNAKE_FOOD_STEP) {
                s->tick_ms -= SNAKE_FOOD_STEP;
            } else {
                s->tick_ms = SNAKE_MIN_TICK;
            }
        }
        place_food(s);
        return;
    }

    for (int i = s->len - 1; i > 0; i--) {
        s->x[i] = s->x[i - 1];
        s->y[i] = s->y[i - 1];
    }
    s->x[0] = (int8_t)hx;
    s->y[0] = (int8_t)hy;
}
