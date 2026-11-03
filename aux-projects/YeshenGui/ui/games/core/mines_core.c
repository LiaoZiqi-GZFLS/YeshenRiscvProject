#include "mines_core.h"

#include <string.h>

#define MINES_CELLS (MINES_W * MINES_H)
#define MINES_SAFE_CELLS (MINES_CELLS - MINES_COUNT)

uint32_t mines_rand(mines_t *m)
{
    uint32_t x = m->rng ? m->rng : 0x9E3779B9u;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    m->rng = x;
    return x;
}

static bool in_bounds(int x, int y)
{
    return x >= 0 && x < MINES_W && y >= 0 && y < MINES_H;
}

static void compute_adj(mines_t *m)
{
    memset(m->adj, 0, sizeof(m->adj));
    for (int y = 0; y < MINES_H; y++) {
        for (int x = 0; x < MINES_W; x++) {
            if (m->mine[y][x]) continue;
            uint8_t n = 0;
            for (int dy = -1; dy <= 1; dy++) {
                for (int dx = -1; dx <= 1; dx++) {
                    int nx = x + dx;
                    int ny = y + dy;
                    if ((dx == 0 && dy == 0) || !in_bounds(nx, ny)) continue;
                    if (m->mine[ny][nx]) n++;
                }
            }
            m->adj[y][x] = n;
        }
    }
}

/* Keep the first click safe: if the clicked cell holds a mine, move that mine
 * to the first non-mine cell in row-major order. */
static void move_first_mine(mines_t *m, int x, int y)
{
    if (!m->mine[y][x]) return;
    for (int cy = 0; cy < MINES_H; cy++) {
        for (int cx = 0; cx < MINES_W; cx++) {
            if (cx == x && cy == y) continue;
            if (m->mine[cy][cx]) continue;
            m->mine[cy][cx] = 1;
            m->mine[y][x] = 0;
            return;
        }
    }
}

static void generate(mines_t *m, int sx, int sy)
{
    memset(m->mine, 0, sizeof(m->mine));
    memset(m->open, 0, sizeof(m->open));
    memset(m->flag, 0, sizeof(m->flag));
    m->opened = 0;

    /* Pick MINES_COUNT distinct cells out of everything but (sx,sy) with a
     * partial Fisher-Yates shuffle, so generation always terminates. */
    int cand[MINES_CELLS];
    int n = 0;
    for (int y = 0; y < MINES_H; y++) {
        for (int x = 0; x < MINES_W; x++) {
            if (x == sx && y == sy) continue;
            cand[n++] = y * MINES_W + x;
        }
    }

    for (int i = 0; i < MINES_COUNT; i++) {
        int j = i + (int)(mines_rand(m) % (uint32_t)(n - i));
        int swap = cand[i];
        cand[i] = cand[j];
        cand[j] = swap;
        m->mine[cand[i] / MINES_W][cand[i] % MINES_W] = 1;
    }

    move_first_mine(m, sx, sy);
    m->first = 0;
    compute_adj(m);
}

static void flood_open(mines_t *m, int x, int y)
{
    int stack[MINES_CELLS];
    int sp = 0;

    m->open[y][x] = 1;
    m->opened++;
    if (m->adj[y][x] == 0) stack[sp++] = y * MINES_W + x;

    while (sp > 0) {
        int idx = stack[--sp];
        int cx = idx % MINES_W;
        int cy = idx / MINES_W;
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                int nx = cx + dx;
                int ny = cy + dy;
                if ((dx == 0 && dy == 0) || !in_bounds(nx, ny)) continue;
                if (m->open[ny][nx] || m->flag[ny][nx] || m->mine[ny][nx]) continue;
                m->open[ny][nx] = 1;
                m->opened++;
                if (m->adj[ny][nx] == 0) stack[sp++] = ny * MINES_W + nx;
            }
        }
    }
}

void mines_init(mines_t *m, uint32_t seed)
{
    memset(m, 0, sizeof(*m));
    m->rng = seed ? seed : 1u;
    m->first = 1;
    m->status = MINES_RUNNING;
    m->opened = 0;
}

void mines_reveal(mines_t *m, int x, int y)
{
    if (!in_bounds(x, y)) return;

    if (m->first) generate(m, x, y);
    if (m->status != MINES_RUNNING) return;
    if (m->flag[y][x] || m->open[y][x]) return;

    if (m->mine[y][x]) {
        m->open[y][x] = 1;
        m->opened++;
        m->status = MINES_LOST;
        return;
    }

    flood_open(m, x, y);
    if (m->opened == MINES_SAFE_CELLS) m->status = MINES_WON;
}

void mines_flag(mines_t *m, int x, int y)
{
    if (!in_bounds(x, y)) return;
    if (m->open[y][x]) return;
    m->flag[y][x] = (uint8_t)!m->flag[y][x];
}

void mines_prepare_test(mines_t *m)
{
    memset(m->open, 0, sizeof(m->open));
    memset(m->flag, 0, sizeof(m->flag));
    compute_adj(m);
    m->first = 0;
    m->opened = 0;
    m->status = MINES_RUNNING;
}
