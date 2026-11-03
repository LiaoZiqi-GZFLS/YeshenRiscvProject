/* gpu.c —— 2D GPU 命令封装：板端走 MMIO，主机（UI_HOST）走同语义软件模拟。
 *
 * 板端路径与 RTL 的契约（逐条来自 rtl/gpu/）：
 *   · 命令字 {op[7:0], nwords[7:0], flags[15:0]}；nwords 不含头；
 *   · 普通字写 GPU_CMD_DATA，一条命令的最后一个字写 GPU_CMD_PUSH；
 *   · 执行侧按 FIFO 顺序，FENCE 完成后 SEQ_DONE = seq；
 *   · FLIP 写 1 ⇒ STATUS.flip_pending=1，读到视频读帧起点后自清。
 * 主机路径把同样的语义作用在 gpu_host_bind() 绑定的内存上（逐像素与
 * VexiiYeshenLinux/sim/gpu/gpu2d_ref.c 一致，tests/gpu_host_test.c 对黄金逐字节核）。
 */
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE 1
#endif
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include "gpu.h"
#include "gpu_regs.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define GPU_BASE_PHYS 0xF0005000UL
#define GPU_WAIT_MS   100

static gpu_stats_t s_stats;
static int         s_inited;

/* ======================================================================= */
#if defined(UI_HOST)
/* ============================ 主机：软件模拟 ============================ */

#define HOST_MAX_REGIONS 8

typedef struct {
    uint32_t phys;
    uint8_t *mem;
    size_t   len;
} host_region_t;

static host_region_t s_regions[HOST_MAX_REGIONS];
static int           s_nregions;

static int s_sc_x0, s_sc_y0, s_sc_x1 = 1 << 20, s_sc_y1 = 1 << 20;

void gpu_host_bind(uint32_t phys, void *mem, size_t len)
{
    if (s_nregions >= HOST_MAX_REGIONS) return;
    s_regions[s_nregions].phys = phys;
    s_regions[s_nregions].mem  = (uint8_t *)mem;
    s_regions[s_nregions].len  = len;
    s_nregions++;
}

void gpu_host_unbind_all(void)
{
    s_nregions = 0;
    s_sc_x0 = s_sc_y0 = 0;
    s_sc_x1 = s_sc_y1 = 1 << 20;
}

/* 返回到 phys 的指针；越界 / 未绑定 ⇒ NULL（调用方跳过该像素） */
static uint8_t *h_at(uint32_t phys, size_t bytes)
{
    for (int i = 0; i < s_nregions; i++) {
        uint32_t base = s_regions[i].phys;
        if (phys >= base && (size_t)(phys - base) + bytes <= s_regions[i].len)
            return s_regions[i].mem + (phys - base);
    }
    return NULL;
}

static inline uint16_t h_rd16(uint32_t phys)
{
    uint8_t *p = h_at(phys, 2);
    return p ? (uint16_t)(p[0] | (p[1] << 8)) : 0xFFFFu;
}
static inline void h_wr16(uint32_t phys, uint16_t v)
{
    uint8_t *p = h_at(phys, 2);
    if (!p) return;
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)(v >> 8);
}
static inline uint8_t h_rd8(uint32_t phys)
{
    uint8_t *p = h_at(phys, 1);
    return p ? p[0] : 0;
}

static inline uint8_t udiv255(uint32_t x) { return (uint8_t)((x * 0x8081u) >> 23); }

static uint16_t mix565(uint16_t fg, uint16_t bg, unsigned a)
{
    if (a < 2) return bg;
    if (a >= 253) return fg;
    unsigned fr = (fg >> 11) & 31, fgc = (fg >> 5) & 63, fb_ = fg & 31;
    unsigned br = (bg >> 11) & 31, bgc = (bg >> 5) & 63, bb = bg & 31;
    unsigned r = udiv255(fr * a + br * (255 - a));
    unsigned g = udiv255(fgc * a + bgc * (255 - a));
    unsigned b = udiv255(fb_ * a + bb * (255 - a));
    return (uint16_t)((r << 11) | (g << 5) | b);
}

/* 写像素（带 scissor；越界丢弃） */
static void h_put(uint32_t base, int stride_px, int x, int y, uint16_t c)
{
    if (x < s_sc_x0 || x >= s_sc_x1 || y < s_sc_y0 || y >= s_sc_y1) return;
    h_wr16(base + (uint32_t)((size_t)y * stride_px + x) * 2u, c);
}
static uint16_t h_get(uint32_t base, int stride_px, int x, int y)
{
    return h_rd16(base + (uint32_t)((size_t)y * stride_px + x) * 2u);
}

static inline int in_corner(int px, int py, int r)
{
    int A = 2 * px + 1 - 2 * r;
    int B = 2 * py + 1 - 2 * r;
    return A * A + B * B <= 4 * r * r;
}

int gpu_fill(uint32_t dst, int stride_px, int x, int y, int w, int h, uint16_t color)
{
    s_stats.ops++;
    for (int j = 0; j < h; j++)
        for (int i = 0; i < w; i++) h_put(dst, stride_px, x + i, y + j, color);
    return 0;
}

int gpu_round_fill(uint32_t dst, int stride_px, int x, int y, int w, int h,
                   int radius, uint16_t color)
{
    s_stats.ops++;
    if (w <= 0 || h <= 0) return 0;
    if (radius > w / 2) radius = w / 2;
    if (radius > h / 2) radius = h / 2;
    if (radius < 0) radius = 0;
    for (int j = 0; j < h; j++) {
        int inset = 0;
        if (j < radius || j >= h - radius) {
            int dy = (j < radius) ? j : (h - 1 - j);
            int px = 0;
            while (px < radius && !in_corner(px, dy, radius)) px++;
            inset = px;
        }
        for (int i = inset; i < w - inset; i++)
            h_put(dst, stride_px, x + i, y + j, color);
    }
    return 0;
}

int gpu_set_scissor(int x0, int y0, int x1, int y1)
{
    s_sc_x0 = x0; s_sc_y0 = y0;
    s_sc_x1 = x1; s_sc_y1 = y1;
    return 0;
}

int gpu_blit(uint32_t src, int src_stride_px, int fmt, int sx, int sy, int w, int h,
             uint32_t dst, int dst_stride_px, int dx, int dy, int blend, int alpha)
{
    (void)fmt;
    s_stats.ops++;
    for (int j = 0; j < h; j++) {
        for (int i = 0; i < w; i++) {
            uint16_t s = h_rd16(src + (uint32_t)((size_t)(sy + j) * src_stride_px + (sx + i)) * 2u);
            int px = dx + i, py = dy + j;
            if (!blend) { h_put(dst, dst_stride_px, px, py, s); continue; }
            unsigned a = (unsigned)alpha;
            if (a < 2) continue;
            if (a >= 253) { h_put(dst, dst_stride_px, px, py, s); continue; }
            h_put(dst, dst_stride_px, px, py,
                  mix565(s, h_get(dst, dst_stride_px, px, py), a));
        }
    }
    return 0;
}

int gpu_glyph(uint32_t src, int src_stride_px, int sx, int sy, int w, int h,
              uint32_t dst, int dst_stride_px, int dx, int dy, uint16_t fg, int alpha)
{
    s_stats.ops++;
    for (int j = 0; j < h; j++) {
        for (int i = 0; i < w; i++) {
            unsigned cov = h_rd8(src + (uint32_t)((size_t)(sy + j) * src_stride_px + (sx + i)));
            unsigned a = udiv255(cov * (unsigned)alpha);
            if (a < 2) continue;
            int px = dx + i, py = dy + j;
            h_put(dst, dst_stride_px, px, py,
                  mix565(fg, h_get(dst, dst_stride_px, px, py), a));
        }
    }
    return 0;
}

int  gpu_fence(void) { return (int)s_stats.fences++; }
int  gpu_flip(void)  { return 0; }
int  gpu_flip_async(void) { return 0; }

void gpu_mem_sync(const void *p, size_t len) { (void)p; (void)len; }

static uint8_t *s_arena;
static size_t   s_arena_used;

int gpu_arena_init(void)
{
    if (s_arena) return 0;
    s_arena = malloc(GPU_ARENA_SIZE);
    if (!s_arena) return -1;
    s_arena_used = 0;
    gpu_host_bind(GPU_ARENA_PHYS, s_arena, GPU_ARENA_SIZE);
    return 0;
}

void *gpu_arena_alloc(size_t len, uint32_t *phys)
{
    if (!s_arena && gpu_arena_init() != 0) return NULL;
    len = (len + 3u) & ~(size_t)3u;
    if (s_arena_used + len > GPU_ARENA_SIZE) return NULL;
    void *p = s_arena + s_arena_used;
    if (phys) *phys = GPU_ARENA_PHYS + (uint32_t)s_arena_used;
    s_arena_used += len;
    return p;
}

void gpu_arena_reset(void)
{
    s_arena_used = 0;
}

int gpu_present(void) { return 0; }

int gpu_init(void)
{
    memset(&s_stats, 0, sizeof s_stats);
    s_inited = 1;
    return 0;
}

void gpu_shutdown(void)
{
    gpu_host_unbind_all();
    s_inited = 0;
}

const gpu_stats_t *gpu_stats(void) { return &s_stats; }

/* 3D：主机模拟未实现（LVGL 预览用不到）；板端见下方 MMIO 段。 */
int gpu_clear3d(uint16_t color, uint16_t z) { (void)color; (void)z; return -1; }
int gpu_draw_tris(uint32_t tri_phys, int count) { (void)tri_phys; (void)count; return -1; }
int gpu_composite3d(uint32_t dst, int dst_stride_px, int dx, int dy)
{ (void)dst; (void)dst_stride_px; (void)dx; (void)dy; return -1; }

#else  /* ============================ 板端：MMIO ============================ */

#include <errno.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static volatile uint32_t *s_csr;
static uint32_t           s_seq;
static int                s_mem_fd = -1;

static inline uint32_t rd(uint32_t off)          { return s_csr[off >> 2]; }
static inline void     wr(uint32_t off, uint32_t v) { s_csr[off >> 2] = v; }

static uint32_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000u + (uint32_t)(ts.tv_nsec / 1000000));
}

static int wait_free(int need)
{
    uint32_t t0 = now_ms();
    for (;;) {
        int free_words = (int)(rd(GPU_FIFO_FREE) & 0x1F);
        if (free_words >= need) return 0;
        if (now_ms() - t0 > GPU_WAIT_MS) {
            s_stats.errors++;
            return -1;
        }
    }
}

/* 推一条命令：hdr + params（nwords 不含头）；最后一个字用 CMD_PUSH */
static int push_cmd(uint8_t op, const uint32_t *params, int nwords)
{
    if (wait_free(nwords + 1) != 0) return -1;
    wr(GPU_CMD_DATA, ((uint32_t)op << 24) | ((uint32_t)nwords << 16));
    for (int i = 0; i < nwords; i++) {
        uint32_t off = (i == nwords - 1) ? GPU_CMD_PUSH : GPU_CMD_DATA;
        wr(off, params[i]);
    }
    s_stats.ops++;
    return 0;
}

int gpu_init(void)
{
    memset(&s_stats, 0, sizeof s_stats);
    s_mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (s_mem_fd < 0) {
        printf("gpu: open /dev/mem failed (%s)\n", strerror(errno));
        return -1;
    }
    void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED,
                   s_mem_fd, (off_t)GPU_BASE_PHYS);
    if (p == MAP_FAILED) {
        printf("gpu: mmap CSR failed (%s)\n", strerror(errno));
        close(s_mem_fd);
        s_mem_fd = -1;
        return -1;
    }
    s_csr = (volatile uint32_t *)p;
    uint32_t id = rd(GPU_ID);
    s_stats.present = (id == GPU_ID_MAGIC);
    if (!s_stats.present)
        printf("gpu: GPU_ID=0x%08X（期望 0x%08X）⇒ 比特流没有 GPU 或窗没译码\n",
               (unsigned)id, (unsigned)GPU_ID_MAGIC);
    s_seq = 0;
    s_inited = 1;
    return s_stats.present ? 0 : -1;
}

static uint8_t *s_arena;
static size_t   s_arena_used;

int gpu_arena_init(void)
{
    if (s_arena) return 0;
    if (s_mem_fd < 0) return -1;
    void *p = mmap(NULL, GPU_ARENA_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED,
                   s_mem_fd, (off_t)GPU_ARENA_PHYS);
    if (p == MAP_FAILED) {
        printf("gpu: arena mmap 失败（%s）\n", strerror(errno));
        return -1;
    }
    s_arena = (uint8_t *)p;
    s_arena_used = 0;
    return 0;
}

void *gpu_arena_alloc(size_t len, uint32_t *phys)
{
    if (!s_arena && gpu_arena_init() != 0) return NULL;
    len = (len + 3u) & ~(size_t)3u;
    if (s_arena_used + len > GPU_ARENA_SIZE) return NULL;
    void *p = s_arena + s_arena_used;
    if (phys) *phys = GPU_ARENA_PHYS + (uint32_t)s_arena_used;
    s_arena_used += len;
    return p;
}

void gpu_arena_reset(void) { s_arena_used = 0; }

void gpu_shutdown(void)
{
    if (s_arena) { munmap(s_arena, GPU_ARENA_SIZE); s_arena = NULL; }
    if (s_csr) { munmap((void *)s_csr, 4096); s_csr = NULL; }
    if (s_mem_fd >= 0) { close(s_mem_fd); s_mem_fd = -1; }
    s_inited = 0;
}

int gpu_present(void) { return s_stats.present; }

int gpu_fill(uint32_t dst, int stride_px, int x, int y, int w, int h, uint16_t color)
{
    uint32_t p[7] = { dst, (uint32_t)stride_px, (uint32_t)x, (uint32_t)y,
                      (uint32_t)w, (uint32_t)h, color };
    return push_cmd(OP_FILL, p, 7);
}

int gpu_round_fill(uint32_t dst, int stride_px, int x, int y, int w, int h,
                   int radius, uint16_t color)
{
    uint32_t p[8] = { dst, (uint32_t)stride_px, (uint32_t)x, (uint32_t)y,
                      (uint32_t)w, (uint32_t)h, (uint32_t)radius, color };
    return push_cmd(OP_ROUND_FILL, p, 8);
}

int gpu_set_scissor(int x0, int y0, int x1, int y1)
{
    /* 只走命令 FIFO：寄存器直写会**插队**到 FIFO 里已排队的 2D 命令前面
     * （寄存器立即生效 ⇒ 前面那些 fill 会被新裁剪窗裁掉）。RTL 的 SET_SCISSOR
     * 在 S_DEC 里按序更新 scx0..scx1，与主机模拟同语义。 */
    uint32_t p[4] = { (uint32_t)x0, (uint32_t)y0, (uint32_t)x1, (uint32_t)y1 };
    return push_cmd(OP_SET_SCISSOR, p, 4);
}

int gpu_blit(uint32_t src, int src_stride_px, int fmt, int sx, int sy, int w, int h,
             uint32_t dst, int dst_stride_px, int dx, int dy, int blend, int alpha)
{
    uint32_t p[13] = { src, (uint32_t)src_stride_px, (uint32_t)fmt,
                       (uint32_t)sx, (uint32_t)sy, (uint32_t)w, (uint32_t)h,
                       dst, (uint32_t)dst_stride_px, (uint32_t)dx, (uint32_t)dy,
                       (uint32_t)(blend & 1), (uint32_t)alpha };
    return push_cmd(OP_BLIT, p, 13);
}

int gpu_glyph(uint32_t src, int src_stride_px, int sx, int sy, int w, int h,
              uint32_t dst, int dst_stride_px, int dx, int dy, uint16_t fg, int alpha)
{
    uint32_t p[12] = { src, (uint32_t)src_stride_px, (uint32_t)sx, (uint32_t)sy,
                       (uint32_t)w, (uint32_t)h, dst, (uint32_t)dst_stride_px,
                       (uint32_t)dx, (uint32_t)dy, fg, (uint32_t)alpha };
    return push_cmd(OP_GLYPH, p, 12);
}

/* ---- 3D（板端）---- */
int gpu_clear3d(uint16_t color, uint16_t z)
{
    uint32_t p[8] = { color, z, GPU_3D_W, GPU_3D_H,
                      GPU_COLOR3D, GPU_3D_W, GPU_Z3D, GPU_3D_W };
    return push_cmd(OP_CLEAR3D, p, 8);
}

int gpu_draw_tris(uint32_t tri_phys, int count)
{
    uint32_t p[8] = { tri_phys, (uint32_t)count, GPU_3D_W, GPU_3D_H,
                      GPU_COLOR3D, GPU_3D_W, GPU_Z3D, GPU_3D_W };
    return push_cmd(OP_DRAW_TRIS, p, 8);
}

int gpu_composite3d(uint32_t dst, int dst_stride_px, int dx, int dy)
{
    uint32_t p[8] = { GPU_COLOR3D, GPU_3D_W, dst, (uint32_t)dst_stride_px,
                      GPU_3D_W, GPU_3D_H, (uint32_t)dx, (uint32_t)dy };
    return push_cmd(OP_COMPOSITE3D, p, 8);
}

int gpu_fence(void)
{
    uint32_t seq = ++s_seq;
    uint32_t p[1] = { seq };
    if (push_cmd(OP_FENCE, p, 1) != 0) return -1;
    uint32_t t0 = now_ms();
    for (;;) {
        if ((rd(GPU_SEQ_DONE) & 0xFFFF) == (seq & 0xFFFF)) {
            s_stats.fences++;
            uint32_t dbg = rd(GPU_DBG);
            s_stats.last_op     = dbg & 0xFFFF;
            s_stats.last_cycles = dbg >> 16;
            return (int)seq;
        }
        if (now_ms() - t0 > GPU_WAIT_MS) {
            s_stats.errors++;
            printf("gpu: FENCE seq=%u 超时（SEQ_DONE=%u）\n",
                   (unsigned)seq, (unsigned)(rd(GPU_SEQ_DONE) & 0xFFFF));
            return -1;
        }
    }
}

int gpu_flip(void)
{
    uint32_t t0 = now_ms();
    wr(GPU_FLIP, 1u);
    /* 先等 flip_pending 真的置起（寄存器写要到下一拍才可见），再等它在
     * 读帧起点自清 —— 否则头一次读就可能读到 0，把"没生效"当成功。 */
    int seen = 0;
    for (;;) {
        uint32_t st = rd(GPU_STATUS);
        if (st & (1u << 16)) seen = 1;
        else if (seen) return 0;
        if (now_ms() - t0 > GPU_WAIT_MS) {
            s_stats.errors++;
            printf("gpu: FLIP 超时（%s）\n", seen ? "等不到 vsync" : "pending 未置起");
            return -1;
        }
    }
}

int gpu_flip_async(void)
{
    wr(GPU_FLIP, 1u);
    return 0;
}

void gpu_mem_sync(const void *p, size_t len)
{
#if defined(GPU_HAVE_CBO) && defined(__riscv)
    uintptr_t a = (uintptr_t)p & ~(uintptr_t)63;
    uintptr_t e = ((uintptr_t)p + len + 63u) & ~(uintptr_t)63;
    for (; a < e; a += 64)
        __asm__ volatile("cbo.flush (%0)" :: "r"(a) : "memory");
#else
    (void)p; (void)len;   /* 调用方必须用非缓存映射（/dev/mem + O_SYNC 或 uncached） */
#endif
}

const gpu_stats_t *gpu_stats(void) { return &s_stats; }

void gpu_host_bind(uint32_t phys, void *mem, size_t len) { (void)phys; (void)mem; (void)len; }
void gpu_host_unbind_all(void) {}

#endif /* UI_HOST */
