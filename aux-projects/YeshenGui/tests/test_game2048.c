#include "../ui/games/core/game2048_core.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void clear(g2048_t *g) { memset(g, 0, sizeof(*g)); g->status = G2048_RUNNING; g->rng = 1; }

int main(void) {
    g2048_t g;
    g2048_init(&g, 1234);
    int n = 0;
    for (int r=0;r<4;r++) for (int c=0;c<4;c++) if (g.cell[r][c]) n++;
    assert(n == 2);

    clear(&g);
    g.cell[0][0] = 2; g.cell[0][1] = 2; g.cell[0][2] = 2; g.cell[0][3] = 2;
    assert(g2048_move(&g, 3)); /* left */
    assert(g.cell[0][0] == 4);
    assert(g.cell[0][1] == 4);
    assert(g.score == 8);

    clear(&g);
    g.cell[0][0] = 2; g.cell[0][1] = 2; g.cell[0][2] = 4;
    assert(g2048_move(&g, 3));
    assert(g.cell[0][0] == 4 && g.cell[0][1] == 4);

    clear(&g);
    for (int r=0;r<4;r++) for (int c=0;c<4;c++) g.cell[r][c] = (r+c)%2 ? 2 : 4;
    assert(!g2048_can_move(&g));

    clear(&g);
    g.cell[0][0] = 2048;
    g2048_move(&g, 1);
    assert(g.status == G2048_WON);

    printf("test_game2048: PASS\n");
    return 0;
}
