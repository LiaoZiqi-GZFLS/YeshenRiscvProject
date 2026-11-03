/* gpudiag.c —— 32B 粒度判别（板侧）
 *
 *  A: 对齐源，dx=18,dy=20,w=8   ⇒ 落点 18(掩码0x18) 还是 16(掩码0x1F)
 *  B: sx=4（源字节 +8），dx=0,dy=30,w=8 ⇒ 读侧是否也按 32B 对齐（值会变 src[0..7]）
 */
#define _DEFAULT_SOURCE 1
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>

#define GPU_BASE      0xF0005000UL
#define GPU_CMD_DATA  0x010
#define GPU_CMD_PUSH  0x014
#define GPU_SEQ_DONE  0x018
#define GPU_FIFO_FREE 0x01C
#define GPU_DBG       0x02C
#define OP_FILL       0x02
#define OP_BLIT       0x03
#define OP_FENCE      0x07

#define SCRATCH_PHYS 0x93400000UL
#define SCRATCH_SIZE (2u * 1024u * 1024u)
#define SRC_PHYS     (SCRATCH_PHYS + 0x100000u)
#define W 512
#define H 256
#define SW 128

static volatile uint32_t *csr;
static uint16_t *fb;
static uint16_t *src;

static inline uint32_t rd(uint32_t o) { return csr[o >> 2]; }
static inline void wr(uint32_t o, uint32_t v) { csr[o >> 2] = v; }

static void push(uint8_t op, const uint32_t *p, int n)
{
    while ((int)(rd(GPU_FIFO_FREE) & 0x1F) < n + 1) { }
    wr(GPU_CMD_DATA, ((uint32_t)op << 24) | ((uint32_t)n << 16));
    for (int i = 0; i < n; i++)
        wr((i == n - 1) ? GPU_CMD_PUSH : GPU_CMD_DATA, p[i]);
}

static void blit(int sx, int dx, int dy)
{
    uint32_t p[13] = { SRC_PHYS, SW, 0, (uint32_t)sx, 0, 8, 1,
                       SCRATCH_PHYS, W, (uint32_t)dx, (uint32_t)dy, 0, 0 };
    push(OP_BLIT, p, 13);
}

static void rowdump(int y)
{
    printf("y=%d:", y);
    for (int x = 0; x < 80; x++)
        if (fb[y * W + x] != 0x1234) printf(" x%d=%04X", x, fb[y * W + x]);
    printf("\n");
}

int main(void)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open"); return 2; }
    csr = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)GPU_BASE);
    fb  = mmap(NULL, SCRATCH_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)SCRATCH_PHYS);
    if (csr == MAP_FAILED || fb == MAP_FAILED) { perror("mmap"); return 2; }
    src = (uint16_t *)((uint8_t *)fb + (SRC_PHYS - SCRATCH_PHYS));

    for (int x = 0; x < SW; x++) src[x] = (uint16_t)(0x8000u | (unsigned)x);

    uint32_t f[7] = { (uint32_t)SCRATCH_PHYS, W, 0, 0, W, H, 0x1234 };
    uint32_t q[1] = { 1 };
    uint32_t done = rd(GPU_SEQ_DONE) & 0xFFFF;
    push(OP_FILL, f, 7);
    push(OP_FENCE, q, 1);
    while (((rd(GPU_SEQ_DONE) & 0xFFFF) - done) < 1) { }

    blit(0, 18, 20);
    blit(4, 0, 30);
    push(OP_FENCE, q, 1);
    while (((rd(GPU_SEQ_DONE) & 0xFFFF) - done) < 2) { }

    printf("DBG=0x%08X\n", rd(GPU_DBG));
    rowdump(20);
    rowdump(30);
    return 0;
}
