#pragma once
#include <stdbool.h>
#include <stdint.h>

#define G2048_N 4

typedef enum { G2048_RUNNING, G2048_WON, G2048_OVER } g2048_status_t;

typedef struct {
    uint16_t cell[G2048_N][G2048_N];
    uint32_t score;
    uint32_t rng;
    g2048_status_t status;
} g2048_t;

void g2048_init(g2048_t *g, uint32_t seed);
bool g2048_move(g2048_t *g, int dir); /* 0 up, 1 right, 2 down, 3 left */
bool g2048_can_move(const g2048_t *g);
uint32_t g2048_rand(g2048_t *g);
