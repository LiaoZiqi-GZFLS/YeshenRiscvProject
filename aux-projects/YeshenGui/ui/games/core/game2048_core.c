#include "game2048_core.h"

#include <string.h>

/* xorshift32: deterministic, seedable, never stuck at 0. */
uint32_t g2048_rand(g2048_t *g)
{
    uint32_t x = g->rng ? g->rng : 0x9E3779B9u;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    g->rng = x;
    return x;
}

/* Line traversal orders index 0 = the edge tiles slide toward. */
static void line_coords(int dir, int line, int i, int *r, int *c)
{
    switch (dir) {
    case 0: /* up */
        *r = i;
        *c = line;
        break;
    case 2: /* down */
        *r = G2048_N - 1 - i;
        *c = line;
        break;
    case 3: /* left */
        *r = line;
        *c = i;
        break;
    default: /* right */
        *r = line;
        *c = G2048_N - 1 - i;
        break;
    }
}

static void spawn(g2048_t *g)
{
    int empty = 0;
    for (int r = 0; r < G2048_N; r++)
        for (int c = 0; c < G2048_N; c++)
            if (g->cell[r][c] == 0) empty++;
    if (empty == 0) return;

    int pick = (int)(g2048_rand(g) % (uint32_t)empty);
    uint16_t value = (g2048_rand(g) % 10u) == 0u ? 4u : 2u;

    for (int r = 0; r < G2048_N; r++) {
        for (int c = 0; c < G2048_N; c++) {
            if (g->cell[r][c] != 0) continue;
            if (pick == 0) {
                g->cell[r][c] = value;
                return;
            }
            pick--;
        }
    }
}

void g2048_init(g2048_t *g, uint32_t seed)
{
    memset(g, 0, sizeof(*g));
    g->rng = seed ? seed : 1u;
    g->status = G2048_RUNNING;
    spawn(g);
    spawn(g);
}

bool g2048_can_move(const g2048_t *g)
{
    for (int r = 0; r < G2048_N; r++) {
        for (int c = 0; c < G2048_N; c++) {
            if (g->cell[r][c] == 0) return true;
            if (c + 1 < G2048_N && g->cell[r][c] == g->cell[r][c + 1]) return true;
            if (r + 1 < G2048_N && g->cell[r][c] == g->cell[r + 1][c]) return true;
        }
    }
    return false;
}

static bool has_won_value(const g2048_t *g)
{
    for (int r = 0; r < G2048_N; r++)
        for (int c = 0; c < G2048_N; c++)
            if (g->cell[r][c] >= 2048u) return true;
    return false;
}

bool g2048_move(g2048_t *g, int dir)
{
    if (dir < 0 || dir > 3) return false;
    if (g->status == G2048_OVER) return false;

    bool changed = false;

    for (int line = 0; line < G2048_N; line++) {
        uint16_t src[G2048_N] = {0};
        uint16_t merged[G2048_N] = {0};
        uint16_t out[G2048_N] = {0};
        int n = 0;
        int m = 0;

        for (int i = 0; i < G2048_N; i++) {
            int r, c;
            line_coords(dir, line, i, &r, &c);
            src[i] = g->cell[r][c];
        }

        /* compact non-zero tiles */
        for (int i = 0; i < G2048_N; i++) {
            if (src[i] != 0) merged[n++] = src[i];
        }

        /* merge equal neighbours once per line */
        for (int i = 0; i < n; i++) {
            if (i + 1 < n && merged[i] == merged[i + 1]) {
                uint16_t v = (uint16_t)(merged[i] * 2u);
                out[m++] = v;
                g->score += v;
                i++;
            } else {
                out[m++] = merged[i];
            }
        }

        for (int i = 0; i < G2048_N; i++) {
            int r, c;
            line_coords(dir, line, i, &r, &c);
            if (g->cell[r][c] != out[i]) {
                g->cell[r][c] = out[i];
                changed = true;
            }
        }
    }

    if (!changed) return false;

    spawn(g);

    if (has_won_value(g)) {
        g->status = G2048_WON;
    } else if (!g2048_can_move(g)) {
        g->status = G2048_OVER;
    } else {
        g->status = G2048_RUNNING;
    }
    return true;
}
