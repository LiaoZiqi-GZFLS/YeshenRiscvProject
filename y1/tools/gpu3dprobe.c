// gpu3dprobe.c —— 3D 上板最小探针：分步 fflush + 每条命令带**超时** + 逐字回读 FIFO 余量。
//   usage: gpu3dprobe [W] [H] [mode]
//     mode 0 = CLEAR 后插 FENCE（默认）；1 = 不插；
//     mode 2 = **只读观察**：不推任何命令，每秒 dump 一次 CSR，用来在被判挂死时
//              从**另一个进程**读走 3D FSM / 读引擎边界状态（不动被观察者）。
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define GPU_BASE  0xF0005000UL
#define R_ID 0x000
#define R_STATUS 0x004
#define R_CMD_DATA 0x010
#define R_CMD_PUSH 0x014
#define R_SEQ_DONE 0x018
#define R_FIFO_FREE 0x01C
#define R_DBG  0x02C
#define R_DBG2 0x030
#define R_DBG3 0x034
#define R_DBG4 0x038
#define R_DBG5 0x03C

#define OP_FENCE 0x07
#define OP_CLEAR3D 0x10
#define OP_DRAW_TRIS 0x11

static volatile uint32_t *csr;

static inline uint32_t rd(uint32_t o) { return csr[o >> 2]; }
static inline void wr(uint32_t o, uint32_t v) { csr[o >> 2] = v; }

static void dump(const char *why)
{
    printf("  [%s] STATUS=%08x SEQ=%08x FREE=%08x DBG=%08x DBG2=%08x DBG3=%08x DBG4=%08x DBG5=%08x\n",
           why, rd(R_STATUS), rd(R_SEQ_DONE), rd(R_FIFO_FREE), rd(R_DBG), rd(R_DBG2),
           rd(R_DBG3), rd(R_DBG4), rd(R_DBG5));
    uint32_t d1 = rd(R_DBG), d3 = rd(R_DBG3);
    printf("       -> op=%02x st3d=%0d lastcyc=%0d | wrs=%0d wcnt=%0d rdlen=%0d rdcnt=%0d\n",
           (d1 >> 24) & 0xFF, (d1 >> 16) & 0xFF, d1 & 0xFFFF,
           (d3 >> 30) & 3, (d3 >> 25) & 0x1F, (d3 >> 16) & 0xFF, (d3 >> 8) & 0xFF);
    fflush(stdout);
}

static int wait_free(int n, long budget)
{
    while (budget-- > 0)
        if ((int)(rd(R_FIFO_FREE) & 0x1F) >= n) return 0;
    dump("wait_free timeout");
    return 1;
}

static int push(uint8_t op, const uint32_t *p, int n)
{
    if (wait_free(n + 1, 3000000)) return 1;
    wr(R_CMD_DATA, ((uint32_t)op << 24) | ((uint32_t)n << 16));
    for (int i = 0; i < n; i++)
        wr((i == n - 1) ? R_CMD_PUSH : R_CMD_DATA, p[i]);
    return 0;
}

static int fence(uint32_t seq, long budget)
{
    uint32_t q[1] = { seq };
    if (push(OP_FENCE, q, 1)) return 1;
    while (budget-- > 0)
        if ((rd(R_SEQ_DONE) & 0xFFFF) == (seq & 0xFFFF)) return 0;
    dump("fence timeout");
    return 1;
}

int main(int argc, char **argv)
{
    int W = (argc > 1) ? atoi(argv[1]) : 64;
    int H = (argc > 2) ? atoi(argv[2]) : 32;
    int mode = (argc > 3) ? atoi(argv[3]) : 0;
    uint32_t CB = 0x93000000UL, ZB = 0x93100000UL, ARENA = 0x93200000UL;

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 2; }
    csr = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)GPU_BASE);
    uint8_t *dram = mmap(NULL, 0x400000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)CB);
    if (csr == MAP_FAILED || dram == MAP_FAILED) { perror("mmap"); return 2; }

    printf("probe: W=%d H=%d mode=%d ID=%08x FREE=%08x\n",
           W, H, mode, rd(R_ID), rd(R_FIFO_FREE)); fflush(stdout);

    if (mode == 2) {
        /* 只读观察：不动 FIFO，不推命令。每秒一次，共 6 次。 */
        for (int k = 0; k < 6; k++) {
            dump("obs");
            sleep(1);
        }
        printf("PROBE OBS DONE\n"); fflush(stdout);
        return 0;
    }

    /* ---- 1) CLEAR3D ---- */
    uint32_t c[8] = { 0x07E0, 0xFFFF, (uint32_t)W, (uint32_t)H, CB, (uint32_t)W, ZB, (uint32_t)W };
    if (push(OP_CLEAR3D, c, 8)) return 3;
    if (mode == 0) {
        if (fence(1, 50000000)) return 3;
        printf("step1 CLEAR3D ok\n"); fflush(stdout);
    } else {
        printf("step1 CLEAR3D pushed (no fence)\n"); fflush(stdout);
    }

    /* ---- 2) DRAW_TRIS：整屏三角形（记录字序与 gputest3d 的 rec_pack 逐字一致）---- */
    int32_t *r = (int32_t *)(dram + (ARENA - CB));
    memset(r, 0, 48);
    r[0] = 0;
    r[1] = 0;
    r[2] = (W - 1) * 256;
    r[3] = 0;
    r[4] = 0;
    r[5] = (H - 1) * 256;
    r[6] = (int32_t)((0xF800u << 16) | 0x0000u);   /* color<<16 | z0 */
    r[7] = 0;                                       /* dzdx */
    r[8] = 0;                                       /* dzdy */
    r[9] = 0;                                       /* zmode = LESS */
    printf("rec: %08x %08x %08x %08x %08x\n", r[0], r[2], r[4], r[6], r[9]); fflush(stdout);

    uint32_t d[8] = { ARENA, 1, (uint32_t)W, (uint32_t)H, CB, (uint32_t)W, ZB, (uint32_t)W };
    printf("  free before head=%08x\n", rd(R_FIFO_FREE)); fflush(stdout);
    wr(R_CMD_DATA, ((uint32_t)OP_DRAW_TRIS << 24) | (8u << 16));
    printf("  free after  head=%08x\n", rd(R_FIFO_FREE)); fflush(stdout);
    for (int i = 0; i < 8; i++) {
        wr((i == 7) ? R_CMD_PUSH : R_CMD_DATA, d[i]);
        printf("  free after  p%d=%08x\n", i, rd(R_FIFO_FREE)); fflush(stdout);
    }

    if (fence(mode ? 1 : 2, 50000000)) return 4;
    printf("step2 DRAW_TRIS ok\n"); fflush(stdout);

    /* ---- 3) 抽查 ---- */
    uint16_t *cb = (uint16_t *)(dram);
    uint16_t *zb = (uint16_t *)(dram + (ZB - CB));
    int nz = 0, nzff = 0;
    for (int i = 0; i < W * H; i++) { if (zb[i] != 0xFFFF) nz++; else nzff++; }
    printf("cb[0]=%04x cb[1]=%04x cb[%d]=%04x  z: written=%d kept=%d\n",
           cb[0], cb[1], W + 1, cb[W + 1], nz, nzff);
    fflush(stdout);
    printf("PROBE DONE\n"); fflush(stdout);
    return 0;
}
