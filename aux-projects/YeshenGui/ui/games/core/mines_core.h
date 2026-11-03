#pragma once
#include <stdbool.h>
#include <stdint.h>

#define MINES_W 10
#define MINES_H 10
#define MINES_COUNT 30

typedef enum { MINES_RUNNING, MINES_WON, MINES_LOST } mines_status_t;

typedef struct {
    uint8_t mine[MINES_H][MINES_W];
    uint8_t open[MINES_H][MINES_W];
    uint8_t flag[MINES_H][MINES_W];
    uint8_t adj[MINES_H][MINES_W];
    uint8_t first;
    mines_status_t status;
    uint32_t rng;
    int opened;
} mines_t;

void mines_init(mines_t *m, uint32_t seed);
void mines_reveal(mines_t *m, int x, int y);
void mines_flag(mines_t *m, int x, int y);
void mines_prepare_test(mines_t *m); /* recompute adj from mine[][] for tests */
uint32_t mines_rand(mines_t *m);
