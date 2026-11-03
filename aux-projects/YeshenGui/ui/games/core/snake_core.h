#pragma once
#include <stdbool.h>
#include <stdint.h>

#define SNAKE_W 20
#define SNAKE_H 15
#define SNAKE_MAX (SNAKE_W * SNAKE_H)

typedef enum { SNAKE_READY, SNAKE_RUNNING, SNAKE_OVER } snake_status_t;

typedef struct {
    int8_t x[SNAKE_MAX];
    int8_t y[SNAKE_MAX];
    int len;
    int8_t dir;
    int8_t next_dir;
    int8_t food_x, food_y;
    uint32_t score;
    uint32_t tick_ms;
    uint32_t rng;
    snake_status_t status;
} snake_t;

void snake_init(snake_t *s, uint32_t seed);
void snake_start(snake_t *s);
void snake_set_dir(snake_t *s, int dir); /* 0 up, 1 right, 2 down, 3 left */
void snake_tick(snake_t *s);
uint32_t snake_rand(snake_t *s);
