#include "../ui/games/core/mines_core.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    mines_t m;
    mines_init(&m, 7);
    mines_reveal(&m, 0, 0);
    assert(!m.mine[0][0]);
    assert(m.status == MINES_RUNNING || m.status == MINES_WON);

    mines_init(&m, 7);
    memset(m.mine, 0, sizeof(m.mine));
    m.mine[9][9] = 1;
    m.mine[0][0] = 1;
    m.first = 0;
    m.status = MINES_RUNNING;
    mines_prepare_test(&m);
    mines_reveal(&m, 9, 9);
    assert(m.status == MINES_LOST);

    mines_init(&m, 7);
    memset(m.mine, 0, sizeof(m.mine));
    m.mine[0][0] = 1;
    m.first = 0;
    m.status = MINES_RUNNING;
    mines_prepare_test(&m);
    mines_flag(&m, 0, 0);
    assert(m.flag[0][0] == 1);
    mines_flag(&m, 0, 0);
    assert(m.flag[0][0] == 0);

    printf("test_minesweeper: PASS\n");
    return 0;
}
