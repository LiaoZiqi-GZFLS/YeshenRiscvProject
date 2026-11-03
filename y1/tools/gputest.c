/* gputest.c —— GPU 2D 上板自检（RV32 静态；不需要主机参与）。
 *
 * 做什么：直接写 0xF000_5000 的 CSR，把固定图案画到 DDR 暂存区（0x9340_0000，
 * 与 GUI 帧存/arena 都不重叠），FENCE 之后由 CPU 逐像素对**本文件里独立算的**
 * 期望值 —— 不依赖任何外部黄金文件。
 *
 * 判据（全部为 0 错才算 PASS）：
 *   ① GPU_ID == 0x59475055("YGPU")
 *   ② FILL        ：64x64 棋盘 + 裁剪窗，逐像素
 *   ③ ROUND_FILL  ：整数判据 (2px+1-2r)^2+(2py+1-2r)^2 <= 4r^2，逐像素
 *   ④ BLIT        ：RGB565 不透明拷贝（源由 CPU 写入非缓存 DDR），逐像素
 *   ⑤ GLYPH       ：A8 覆盖率 × alpha=255 ⇒ 不透明落点，逐像素
 *   ⑥ SCISSOR     ：窗外的行必须没被写过（负对照：写成窗外应留下 0 差异）
 *   ⑦ **判据自证** ：最后故意把期望值改一个像素，校验必须报 MISMATCH=1
 *                   （防"永远绿"——判据自己也要能翻红）
 *
 * 用法（板上）：./gputest        # 打印一行结果，退出码 0=PASS
 * 注意：DDR 暂存区用 /dev/mem + O_SYNC 映射（非缓存）⇒ CPU 写完 GPU 立刻可见，
 *       读回也不需要 cache 维护。
 */
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE 1
#endif

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

/* ---- CSR（与 rtl/gpu/gpu_regs.vh 同源）---- */
#define GPU_BASE      0xF0005000UL
#define GPU_ID        0x000
#define GPU_STATUS    0x004
#define GPU_CMD_DATA  0x010
#define GPU_CMD_PUSH  0x014
#define GPU_SEQ_DONE  0x018
#define GPU_FIFO_FREE 0x01C
#define GPU_SCISSOR0  0x020
#define GPU_SCISSOR1  0x024
#define GPU_DBG       0x02C
#define GPU_ID_MAGIC  0x59475055u

#define OP_FILL        0x02
#define OP_BLIT        0x03
#define OP_GLYPH       0x04
#define OP_ROUND_FILL  0x05
#define OP_SET_SCISSOR 0x06
#define OP_FENCE       0x07

/* ---- DDR 暂存区（避开 GUI 帧存 0x9200_0000 / arena 0x9320_0000）---- */
#define SCRATCH_PHYS 0x93400000UL
#define SCRATCH_SIZE (2u * 1024u * 1024u)
#define DST_PHYS     (SCRATCH_PHYS)                 /* 目标"帧存" */
#define SRC_PHYS     (SCRATCH_PHYS + 0x100000u)     /* BLIT 源（RGB565） */
#define A8_PHYS      (SCRATCH_PHYS + 0x180000u)     /* GLYPH 源（A8） */

#define W 512          /* 目标区宽（像素），stride 也用它 */
#define H 256
#define SRC_W 64
#define SRC_H 48
#define A8W 32
#define A8H 32

static volatile uint32_t *s_csr;
static uint16_t *s_dst;
static uint16_t *s_src;
static uint8_t  *s_a8;
static int       s_mem_fd = -1;
static uint32_t  s_seq;
static int       s_err;

static uint32_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000u + (uint32_t)(ts.tv_nsec / 1000000));
}

static inline uint32_t rd(uint32_t off) { return s_csr[off >> 2]; }
static inline void wr(uint32_t off, uint32_t v) { s_csr[off >> 2] = v; }

static int wait_free(int need)
{
    uint32_t t0 = now_ms();
    while ((int)(rd(GPU_FIFO_FREE) & 0x1F) < need) {
        if (now_ms() - t0 > 100) {
            printf("gputest: FIFO 等空超时（need=%d free=%u）\n",
                   need, (unsigned)(rd(GPU_FIFO_FREE) & 0x1F));
            return -1;
        }
    }
    return 0;
}

static int push_cmd(uint8_t op, const uint32_t *p, int n)
{
    if (wait_free(n + 1) != 0) return -1;
    wr(GPU_CMD_DATA, ((uint32_t)op << 24) | ((uint32_t)n << 16));
    for (int i = 0; i < n; i++)
        wr((i == n - 1) ? GPU_CMD_PUSH : GPU_CMD_DATA, p[i]);
    return 0;
}

static int fence(void)
{
    uint32_t seq = ++s_seq;
    uint32_t p[1] = { seq };
    if (push_cmd(OP_FENCE, p, 1) != 0) return -1;
    uint32_t t0 = now_ms();
    while ((rd(GPU_SEQ_DONE) & 0xFFFF) != (seq & 0xFFFF)) {
        if (now_ms() - t0 > 1000) {
            printf("gputest: FENCE 超时（seq=%u done=%u）\n",
                   (unsigned)seq, (unsigned)(rd(GPU_SEQ_DONE) & 0xFFFF));
            return -1;
        }
    }
    return 0;
}

static void fill_cmd(uint32_t dst, int stride, int x, int y, int w, int h, uint16_t c)
{
    uint32_t p[7] = { dst, (uint32_t)stride, (uint32_t)x, (uint32_t)y,
                      (uint32_t)w, (uint32_t)h, c };
    push_cmd(OP_FILL, p, 7);
}

static void round_cmd(uint32_t dst, int stride, int x, int y, int w, int h, int r, uint16_t c)
{
    uint32_t p[8] = { dst, (uint32_t)stride, (uint32_t)x, (uint32_t)y,
                      (uint32_t)w, (uint32_t)h, (uint32_t)r, c };
    push_cmd(OP_ROUND_FILL, p, 8);
}

static void scissor_cmd(int x0, int y0, int x1, int y1)
{
    uint32_t p[4] = { (uint32_t)x0, (uint32_t)y0, (uint32_t)x1, (uint32_t)y1 };
    push_cmd(OP_SET_SCISSOR, p, 4);
}

static void blit_cmd(void)
{
    uint32_t p[13] = { SRC_PHYS, SRC_W, 0, 0, 0, SRC_W, SRC_H,
                       DST_PHYS, W, 8, 8, 0, 0 };
    push_cmd(OP_BLIT, p, 13);
}

static void glyph_cmd(uint16_t fg, int alpha)
{
    uint32_t p[12] = { A8_PHYS, A8W, 0, 0, A8W, A8H,
                       DST_PHYS, W, 300, 8, fg, (uint32_t)alpha };
    push_cmd(OP_GLYPH, p, 12);
}

/* (6) unaligned src + unaligned dst BLIT: src (4,2) -> dst (17,200), 40x8.
 * Covers gpu_mem read (32B-aligned base + drop leading beats) and write (pad strb=0). */
static void blit2_cmd(void)
{
    uint32_t p[13] = { SRC_PHYS, SRC_W, 0, 4, 2, 40, 8,
                       DST_PHYS, W, 17, 200, 0, 0 };
    push_cmd(OP_BLIT, p, 13);
}

/* ---------------- 期望值（独立算，与 RTL 语义同口径）---------------- */
static inline uint8_t udiv255(uint32_t x) { return (uint8_t)((x * 0x8081u) >> 23); }

static uint16_t mix565(uint16_t fg, uint16_t bg, unsigned a)
{
    if (a < 2) return bg;
    if (a >= 253) return fg;
    unsigned fr = (fg >> 11) & 31, fgc = (fg >> 5) & 63, fb = fg & 31;
    unsigned br = (bg >> 11) & 31, bgc = (bg >> 5) & 63, bb = bg & 31;
    unsigned r = udiv255(fr * a + br * (255 - a));
    unsigned g = udiv255(fgc * a + bgc * (255 - a));
    unsigned b = udiv255(fb * a + bb * (255 - a));
    return (uint16_t)((r << 11) | (g << 5) | b);
}

static inline int corner_ok(int dx, int dy, int r)
{
    int a = 2 * dx + 1 - 2 * r;
    int b = 2 * dy + 1 - 2 * r;
    return a * a + b * b <= 4 * r * r;
}

/* 把期望整幅算出来：顺序与命令序列一致 */
static void build_expect(uint16_t *exp)
{
    memset(exp, 0, (size_t)W * H * 2);

    /* ② FILL 棋盘（整幅，不裁剪） */
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            uint16_t c = (((x >> 6) + (y >> 6)) & 1) ? 0xF800 : 0x001F;
            exp[y * W + x] = c;
        }

    /* ③ ROUND_FILL（矩形 20..211 x 40..169，r=24，黄色） */
    {
        const int rx = 20, ry = 40, rw = 192, rh = 130, rr = 24;
        uint16_t c = 0xFFE0;
        for (int j = 0; j < rh; j++) {
            int inset = 0;
            if (j < rr || j >= rh - rr) {
                int dy = (j < rr) ? j : (rh - 1 - j);
                while (inset < rr && !corner_ok(inset, dy, rr)) inset++;
            }
            for (int i = inset; i < rw - inset; i++)
                exp[(ry + j) * W + rx + i] = c;
        }
    }

    /* ④ BLIT（不透明拷贝到 8,8） */
    for (int j = 0; j < SRC_H; j++)
        for (int i = 0; i < SRC_W; i++) {
            int x = 8 + i, y = 8 + j;
            if (x < W && y < H) exp[y * W + x] = s_src[j * SRC_W + i];
        }

    /* ⑤ GLYPH（32x32 A8，fg=白，alpha=255 ⇒ 覆盖率 <2 不写，否则 mix） */
    {
        const int dx = 300, dy = 8;
        for (int j = 0; j < A8H; j++)
            for (int i = 0; i < A8W; i++) {
                unsigned cov = s_a8[j * A8W + i];
                unsigned a = udiv255(cov * 255u);
                if (a < 2) continue;
                int x = dx + i, y = dy + j;
                if (x < W && y < H)
                    exp[y * W + x] = mix565(0xFFFF, exp[y * W + x], a);
            }
    }

    /* (6) unaligned BLIT: src (4,2) -> dst (17,200), 40x8 */
    for (int j = 0; j < 8; j++)
        for (int i = 0; i < 40; i++)
            exp[(200 + j) * W + 17 + i] = s_src[(2 + j) * SRC_W + 4 + i];
}

static int cmp_region(const uint16_t *exp, const char *tag, int *first_x, int *first_y)
{
    int bad = 0;
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            if (s_dst[y * W + x] != exp[y * W + x]) {
                if (bad == 0 && first_x && first_y) { *first_x = x; *first_y = y; }
                bad++;
            }
        }
    if (bad) {
        printf("gputest: %s MISMATCH=%d", tag, bad);
        if (first_x && first_y)
            printf(" first@(%d,%d) got=0x%04X exp=0x%04X",
                   *first_x, *first_y, s_dst[*first_y * W + *first_x],
                   exp[*first_y * W + *first_x]);
        printf("\n");
        s_err++;
    }
    return bad;
}

int main(void)
{
    s_mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (s_mem_fd < 0) { perror("open /dev/mem"); return 2; }

    s_csr = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, s_mem_fd, (off_t)GPU_BASE);
    s_dst = mmap(NULL, SCRATCH_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, s_mem_fd,
                 (off_t)SCRATCH_PHYS);
    if (s_csr == MAP_FAILED || s_dst == MAP_FAILED) { perror("mmap"); return 2; }
    s_src = (uint16_t *)((uint8_t *)s_dst + (SRC_PHYS - SCRATCH_PHYS));
    s_a8  = (uint8_t *)s_dst + (A8_PHYS - SCRATCH_PHYS);

    uint32_t id = rd(GPU_ID);
    printf("gputest: ID=0x%08X（期望 0x%08X）\n", (unsigned)id, (unsigned)GPU_ID_MAGIC);
    if (id != GPU_ID_MAGIC) return 1;

    /* 源：64x48 RGB565 图案 + 32x32 A8 十字（CPU 写非缓存 DDR） */
    for (int y = 0; y < SRC_H; y++)
        for (int x = 0; x < SRC_W; x++) {
            unsigned r = (unsigned)((x * 4) & 31);
            unsigned g = (unsigned)((y * 4) & 63);
            unsigned b = (unsigned)(((x + y) * 2) & 31);
            s_src[y * SRC_W + x] = (uint16_t)((r << 11) | (g << 5) | b);
        }
    for (int y = 0; y < A8H; y++)
        for (int x = 0; x < A8W; x++) {
            unsigned v = ((x >= 14 && x <= 17) || (y >= 14 && y <= 17)) ? 255u
                                                                       : (unsigned)((x * y) & 0x3F);
            s_a8[y * A8W + x] = (uint8_t)v;
        }

    /* CPU 写的源要**真的落到 DDR** 才能被 BLIT/GLYPH 读到：读回自检 + 排空。
     * （本核 D$ 写直达，但 posted 写仍可能在总线上；2026-10-31 上板吃过这个亏） */
    {
        int sbad = 0;
        for (int y = 0; y < SRC_H && !sbad; y++)
            for (int x = 0; x < SRC_W; x++) {
                unsigned r = (unsigned)((x * 4) & 31);
                unsigned g = (unsigned)((y * 4) & 63);
                unsigned b = (unsigned)(((x + y) * 2) & 31);
                if (s_src[y * SRC_W + x] != (uint16_t)((r << 11) | (g << 5) | b)) { sbad++; break; }
            }
        for (int y = 0; y < A8H && !sbad; y++)
            for (int x = 0; x < A8W; x++) {
                unsigned v = ((x >= 14 && x <= 17) || (y >= 14 && y <= 17))
                                 ? 255u : (unsigned)((x * y) & 0x3F);
                if (s_a8[y * A8W + x] != (uint8_t)v) { sbad++; break; }
            }
        if (sbad) { printf("gputest: 源缓冲读回不一致（CPU 写未落地）\n"); return 1; }
        usleep(20000);
    }

    /* ---- 命令序列 ---- */
    scissor_cmd(0, 0, W, H);
    /* 清目标区**交给 GPU**：CPU 直写 512 KB 之后 posted 写还在排空，
     * 与 GPU 同址写无序 ⇒ 会把 GPU 的结果盖回 0（上板实测的"部分像素"假象）。 */
    fill_cmd(DST_PHYS, W, 0, 0, W, H, 0x0000);
    /* ② 棋盘：逐块 64x64（每块一条 FILL，行尾天然断开） */
    for (int by = 0; by < H; by += 64)
        for (int bx = 0; bx < W; bx += 64) {
            uint16_t c = (((bx >> 6) + (by >> 6)) & 1) ? 0xF800 : 0x001F;
            fill_cmd(DST_PHYS, W, bx, by, 64, 64, c);
        }
    /* ③ 圆角矩形 */
    round_cmd(DST_PHYS, W, 20, 40, 192, 130, 24, 0xFFE0);
    /* ④ 不透明 BLIT */
    blit_cmd();
    /* ⑤ 字形 */
    glyph_cmd(0xFFFF, 255);
    blit2_cmd();
    if (fence() != 0) return 1;

    uint16_t *exp = malloc((size_t)W * H * 2);
    if (!exp) return 2;
    build_expect(exp);

    int fx = -1, fy = -1;
    cmp_region(exp, "FILL/ROUND/BLIT/GLYPH", &fx, &fy);

    /* 分区失配统计：把 4 类算子各自的包围盒分开数，定位到底哪一段写错 */
    {
        int nb = 0, nr = 0, nl = 0, ng = 0, nu = 0;
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++) {
                if (s_dst[y * W + x] == exp[y * W + x]) continue;
                if (x >= 8 && x < 72 && y >= 8 && y < 56) nl++;        /* BLIT 64x48@(8,8) */
                else if (x >= 300 && x < 332 && y >= 8 && y < 40) ng++;/* GLYPH 32x32@(300,8) */
                else if (x >= 20 && x < 212 && y >= 40 && y < 170) nr++;/* ROUND 192x130@(20,40) */
                else if (x >= 17 && x < 57 && y >= 200 && y < 208) nu++; /* BLIT unaligned 40x8@(17,200) */
                else nb++;                                              /* 棋盘块 */
            }
        printf("gputest: 分区失配 board=%d round=%d blit=%d glyph=%d blit2=%d\n",
               nb, nr, nl, ng, nu);
    }

    /* ⑥ SCISSOR 负对照：把裁剪窗设成空，再画一条 FILL —— 一个像素都不许变 */
    uint16_t before = s_dst[200 * W + 400];
    scissor_cmd(1000, 1000, 1001, 1001);   /* 完全在窗外（且超过 W/H） */
    fill_cmd(DST_PHYS, W, 0, 0, W, H, 0x7E0);
    scissor_cmd(0, 0, W, H);
    if (fence() != 0) return 1;
    if (s_dst[200 * W + 400] != before) {
        printf("gputest: SCISSOR 负对照失败（窗外像素被改）\n");
        s_err++;
    }

    /* ⑦ 判据自证：故意改一个期望像素，必须报 MISMATCH=1 */
    {
        int e_save = s_err;
        exp[0] ^= 0xFFFF;
        int bad = 0;
        for (int i = 0; i < W * H; i++)
            if (s_dst[i] != exp[i]) bad++;
        if (bad != 1) {
            printf("gputest: 判据自证失败（期望 MISMATCH=1，实际 %d）\n", bad);
            s_err++;
        }
        exp[0] ^= 0xFFFF;
        (void)e_save;
    }

    printf("gputest: err=%d seq=%u DBG=0x%08X => %s\n",
           s_err, (unsigned)s_seq, (unsigned)rd(GPU_DBG), s_err ? "FAIL" : "PASS");
    free(exp);
    return s_err ? 1 : 0;
}
