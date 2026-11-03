/* gpu2d_ref.c —— GPU 2D 算子的**独立**黄金参考（与 RTL 无关，单独写）。
 *
 * 输出（--out 目录）：
 *   fb_initial.bin     初始帧存（1024x600 RGB565 LE，所有用例共用）
 *   assets.bin         源素材：0x180000 起（64x48 RGB565 + 32x32 A8）
 *   <case>.fb.bin      执行后的帧存
 *   <case>.cmds.hex    该用例的命令字序列（32-bit，每行一个 8 位十六进制）——RTL TB 直接回放
 *
 * 语义以 LVGL 9.2 为准（third_party/lvgl/src/misc/lv_color_op.c）：
 *   mix(fg,bg,a) 每通道 = UDIV255(fg*a + bg*(255-a))，UDIV255(x)=(x*0x8081)>>23
 *   阈值同 LVGL：a<2 不写；a>=253 直接拷贝。
 * ROUND_FILL 用整数精确判据（无 sqrt）：
 *   A=2*px+1-2r, B=2*py+1-2r, A^2+B^2 <= 4r^2 ⇒ 填充
 *
 * 命令字 = {op[7:0], nwords[7:0], flags[15:0]} + 参数（nwords 不含头）。
 * 地址口径：dst/src 都是**物理地址**；TB 里帧存放 0x0，素材放 0x180000。
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FB_W_DEF 1024
#define FB_H_DEF 600
#define ASSET_ADDR 0x00200000u   /* 2 MB：避开 1.23 MB 的帧存区 */

#define OP_NOP        0x01
#define OP_FILL       0x02
#define OP_BLIT       0x03
#define OP_GLYPH      0x04
#define OP_ROUND_FILL 0x05
#define OP_SET_SCISSOR 0x06
#define OP_FENCE      0x07

static int W = FB_W_DEF, H = FB_H_DEF;
static uint16_t *fb;
static uint16_t src565[64 * 48];
static uint8_t  a8img[32 * 32];

static int sc_x0, sc_y0, sc_x1, sc_y1;

/* ---------------- 命令列表 ---------------- */
typedef struct { uint32_t w[16]; int n; } cmd_t;
static cmd_t cmds[64];
static int   ncmd;
static uint32_t seq_counter;

static cmd_t *cmd_begin(int op, int nwords)
{
    cmd_t *c = &cmds[ncmd++];
    c->w[0] = ((uint32_t)op << 24) | ((uint32_t)nwords << 16);
    c->n = 1;
    return c;
}
static void cmd_put(cmd_t *c, uint32_t v) { c->w[c->n++] = v; }

static void add_fill(uint32_t dst, uint32_t stride, int x, int y, int w, int h, uint16_t c)
{
    cmd_t *p = cmd_begin(OP_FILL, 7);
    cmd_put(p, dst); cmd_put(p, stride);
    cmd_put(p, (uint32_t)x); cmd_put(p, (uint32_t)y);
    cmd_put(p, (uint32_t)w); cmd_put(p, (uint32_t)h);
    cmd_put(p, c);
}
static void add_round(uint32_t dst, uint32_t stride, int x, int y, int w, int h, int r, uint16_t c)
{
    cmd_t *p = cmd_begin(OP_ROUND_FILL, 8);
    cmd_put(p, dst); cmd_put(p, stride);
    cmd_put(p, (uint32_t)x); cmd_put(p, (uint32_t)y);
    cmd_put(p, (uint32_t)w); cmd_put(p, (uint32_t)h);
    cmd_put(p, (uint32_t)r); cmd_put(p, c);
}
static void add_scissor(int x0, int y0, int x1, int y1)
{
    cmd_t *p = cmd_begin(OP_SET_SCISSOR, 4);
    cmd_put(p, (uint32_t)x0); cmd_put(p, (uint32_t)y0);
    cmd_put(p, (uint32_t)x1); cmd_put(p, (uint32_t)y1);
}
static void add_blit(uint32_t src, uint32_t ss, uint32_t fmt, int sx, int sy, int w, int h,
                     uint32_t dst, uint32_t ds, int dx, int dy, uint32_t flags, uint32_t alpha)
{
    cmd_t *p = cmd_begin(OP_BLIT, 13);
    cmd_put(p, src); cmd_put(p, ss); cmd_put(p, fmt);
    cmd_put(p, (uint32_t)sx); cmd_put(p, (uint32_t)sy);
    cmd_put(p, (uint32_t)w);  cmd_put(p, (uint32_t)h);
    cmd_put(p, dst); cmd_put(p, ds);
    cmd_put(p, (uint32_t)dx); cmd_put(p, (uint32_t)dy);
    cmd_put(p, flags); cmd_put(p, alpha);
}
static void add_glyph(uint32_t src, uint32_t ss, int sx, int sy, int w, int h,
                      uint32_t dst, uint32_t ds, int dx, int dy, uint16_t fg, uint32_t alpha)
{
    cmd_t *p = cmd_begin(OP_GLYPH, 12);
    cmd_put(p, src); cmd_put(p, ss);
    cmd_put(p, (uint32_t)sx); cmd_put(p, (uint32_t)sy);
    cmd_put(p, (uint32_t)w);  cmd_put(p, (uint32_t)h);
    cmd_put(p, dst); cmd_put(p, ds);
    cmd_put(p, (uint32_t)dx); cmd_put(p, (uint32_t)dy);
    cmd_put(p, fg); cmd_put(p, alpha);
}
static void add_fence(void)
{
    cmd_t *p = cmd_begin(OP_FENCE, 1);
    cmd_put(p, ++seq_counter);
}

/* ---------------- 参考执行 ---------------- */
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

static void put_px(int x, int y, uint16_t c)
{
    if (x < sc_x0 || x >= sc_x1 || y < sc_y0 || y >= sc_y1) return;
    if (x < 0 || x >= W || y < 0 || y >= H) return;
    fb[(size_t)y * W + x] = c;
}
static uint16_t get_px(int x, int y)
{
    if (x < 0 || x >= W || y < 0 || y >= H) return 0;
    return fb[(size_t)y * W + x];
}

static void exec_fill(uint32_t *p)
{
    (void)p[0]; int stride = (int)p[1];   /* stride 以像素计；黄金固定 W */
    int x = (int)p[2], y = (int)p[3], w = (int)p[4], h = (int)p[5];
    uint16_t c = (uint16_t)p[6];
    for (int j = 0; j < h; j++)
        for (int i = 0; i < w; i++) put_px(x + i, y + j, c);
    (void)stride;
}

static int in_corner(int px, int py, int r)
{
    int A = 2 * px + 1 - 2 * r;
    int B = 2 * py + 1 - 2 * r;
    return A * A + B * B <= 4 * r * r;
}

static void exec_round(uint32_t *p)
{
    int x = (int)p[2], y = (int)p[3], w = (int)p[4], h = (int)p[5];
    int r = (int)p[6];
    uint16_t c = (uint16_t)p[7];
    if (w <= 0 || h <= 0) return;
    if (r > w / 2) r = w / 2;
    if (r > h / 2) r = h / 2;
    if (r < 0) r = 0;
    for (int j = 0; j < h; j++) {
        int inset = 0;
        if (j < r || j >= h - r) {
            int dy = (j < r) ? j : (h - 1 - j);
            int px = 0;
            while (px < r && !in_corner(px, dy, r)) px++;
            inset = px;
        }
        for (int i = inset; i < w - inset; i++) put_px(x + i, y + j, c);
    }
}

static void exec_scissor(uint32_t *p)
{
    sc_x0 = (int)p[0]; sc_y0 = (int)p[1];
    sc_x1 = (int)p[2]; sc_y1 = (int)p[3];
}

static void exec_blit(uint32_t *p)
{
    int ss = (int)p[1], sx = (int)p[3], sy = (int)p[4];
    int w = (int)p[5], h = (int)p[6];
    int dx = (int)p[9], dy = (int)p[10];
    int blend = (int)(p[11] & 1);
    unsigned alpha = (unsigned)p[12];
    for (int j = 0; j < h; j++)
        for (int i = 0; i < w; i++) {
            uint16_t s = src565[(size_t)(sy + j) * ss + (sx + i)];
            int px = dx + i, py = dy + j;
            if (blend) {
                unsigned a = alpha;
                if (a < 2) continue;
                if (a >= 253) { put_px(px, py, s); continue; }
                put_px(px, py, mix565(s, get_px(px, py), a));
            } else {
                put_px(px, py, s);
            }
        }
}

static void exec_glyph(uint32_t *p)
{
    int ss = (int)p[1], sx = (int)p[2], sy = (int)p[3];
    int w = (int)p[4], h = (int)p[5];
    int dx = (int)p[8], dy = (int)p[9];
    uint16_t fg = (uint16_t)p[10];
    unsigned alpha = (unsigned)p[11];
    for (int j = 0; j < h; j++)
        for (int i = 0; i < w; i++) {
            unsigned cov = a8img[(size_t)(sy + j) * ss + (sx + i)];
            unsigned a = udiv255(cov * alpha);
            if (a < 2) continue;
            int px = dx + i, py = dy + j;
            put_px(px, py, mix565(fg, get_px(px, py), a));
        }
}

static void run_cmds(void)
{
    for (int i = 0; i < ncmd; i++) {
        uint32_t *w = cmds[i].w;
        switch (w[0] >> 24) {
        case OP_FILL:       exec_fill(w + 1); break;
        case OP_ROUND_FILL: exec_round(w + 1); break;
        case OP_SET_SCISSOR: exec_scissor(w + 1); break;
        case OP_BLIT:       exec_blit(w + 1); break;
        case OP_GLYPH:      exec_glyph(w + 1); break;
        case OP_FENCE:      break;
        default:            break;
        }
    }
}

/* ---------------- 用例 ---------------- */
static void init_fb(void)
{
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            unsigned r = (unsigned)(x * 31 / (W - 1));
            unsigned g = (unsigned)(y * 63 / (H - 1));
            unsigned b = (unsigned)(((x ^ y) >> 3) & 31);
            fb[(size_t)y * W + x] = (uint16_t)((r << 11) | (g << 5) | b);
        }
}
static void init_assets(void)
{
    // 每像素唯一编码（高位标记 0x8000）——旧的 (x*4)&31 图案周期 8/16，
    // 会把"源指针整体挪几个像素"这类错误掩盖掉（上板 BLIT 偏移就是被它藏住的）。
    for (int y = 0; y < 48; y++)
        for (int x = 0; x < 64; x++)
            src565[y * 64 + x] = (uint16_t)(0x8000u | ((unsigned)y << 6) | (unsigned)x);
    for (int y = 0; y < 32; y++)
        for (int x = 0; x < 32; x++) {
            unsigned v = 0;
            if (x >= 14 && x <= 17) v = 255;
            if (y >= 14 && y <= 17) v = 255;
            if (v == 0) v = (unsigned)((x * y) & 255);
            a8img[y * 32 + x] = (uint8_t)v;
        }
}

static void build_case(const char *name)
{
    seq_counter = 0;
    ncmd = 0;
    sc_x0 = 0; sc_y0 = 0; sc_x1 = W; sc_y1 = H;
    uint32_t SRC = ASSET_ADDR, A8 = ASSET_ADDR + 64 * 48 * 2;

    if (!strcmp(name, "fill_rect")) {
        add_fill(0, W, 10, 20, 100, 50, 0xF81F);
        add_fill(0, W, 60, 40, 200, 120, 0x07E0);
        add_fill(0, W, 1000, 580, 100, 100, 0x001F);
        add_fill(0, W, 5, 300, 1, 200, 0xFFE0);
        add_fence();
    } else if (!strcmp(name, "blit565")) {
        add_blit(SRC, 64, 0, 0, 0, 64, 48, 0, W, 100, 100, 0, 0);
        add_blit(SRC, 64, 0, 0, 0, 64, 48, 0, W, 300, 100, 1, 128);
        add_blit(SRC, 64, 0, 0, 0, 64, 48, 0, W, 500, 100, 1, 254);
        add_blit(SRC, 64, 0, 0, 0, 64, 48, 0, W, 700, 100, 1, 1);
        add_blit(SRC, 64, 0, 16, 16, 32, 32, 0, W, 880, 100, 0, 0);
        add_fence();
    } else if (!strcmp(name, "blit8")) {
        // 复现上板失败几何：dx=8（目标字节地址 & 0x18 = 16）、64x48 源
        add_fill(0, W, 0, 0, W, H, 0x1234);
        add_blit(SRC, 64, 0, 0, 0, 64, 48, 0, W, 8, 8, 0, 0);
        add_blit(SRC, 64, 0, 4, 0, 64, 1, 0, W, 24, 8, 0, 0);
        add_fence();
    } else if (!strcmp(name, "glyph")) {
        add_glyph(A8, 32, 0, 0, 32, 32, 0, W, 200, 200, 0xFFFF, 255);
        add_glyph(A8, 32, 0, 0, 32, 32, 0, W, 260, 200, 0xF800, 128);
        add_glyph(A8, 32, 0, 0, 32, 32, 0, W, 320, 200, 0x001F, 0);
        add_glyph(A8, 32, 8, 8, 16, 16, 0, W, 380, 200, 0x07E0, 200);
        add_fence();
    } else if (!strcmp(name, "round32")) {
        add_round(0, W, 50, 50, 200, 120, 32, 0xFD20);
        add_round(0, W, 300, 50, 80, 80, 0, 0x001F);
        add_round(0, W, 400, 50, 60, 60, 30, 0x07FF);
        add_round(0, W, 500, 50, 60, 60, 100, 0xF81F);
        add_round(0, W, 700, 50, 1, 1, 0, 0xFFFF);
        add_fence();
    } else if (!strcmp(name, "scissor")) {
        add_scissor(200, 100, 400, 300);
        add_fill(0, W, 0, 0, W, H, 0xF800);
        add_fill(0, W, 399, 299, 10, 10, 0x07E0);
        add_blit(SRC, 64, 0, 0, 0, 64, 48, 0, W, 380, 280, 0, 0);
        add_glyph(A8, 32, 0, 0, 32, 32, 0, W, 390, 290, 0xFFFF, 255);
        add_fence();
    } else if (!strcmp(name, "edge")) {
        add_fill(0, W, 100, 100, 0, 50, 0xFFFF);
        add_fill(0, W, 100, 100, 50, 0, 0xFFFF);
        add_fill(0, W, 1023, 599, 1, 1, 0xF81F);
        add_fill(0, W, 0, 0, 1, 1, 0x07E0);
        add_scissor(500, 400, 600, 500);
        add_blit(SRC, 64, 0, 0, 0, 64, 48, 0, W, 0, 0, 0, 0);
        add_scissor(0, 0, W, H);
        add_round(0, W, 800, 400, 32, 32, 16, 0x001F);
        add_fence();
    } else {
        fprintf(stderr, "unknown case %s\n", name);
        exit(2);
    }
}

static void wr(const char *path, const void *p, size_t n)
{
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); exit(3); }
    if (fwrite(p, 1, n, f) != n) { perror(path); exit(3); }
    fclose(f);
}

int main(int argc, char **argv)
{
    const char *cs = NULL, *out = "gold";
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--case") && i + 1 < argc) cs = argv[++i];
        else if (!strcmp(argv[i], "--out") && i + 1 < argc) out = argv[++i];
        else if (!strcmp(argv[i], "--fb") && i + 1 < argc) sscanf(argv[++i], "%dx%d", &W, &H);
        else { fprintf(stderr, "usage: %s --case NAME [--fb WxH] [--out DIR]\n", argv[0]); return 2; }
    }
    if (!cs) { fprintf(stderr, "missing --case\n"); return 2; }

    fb = calloc((size_t)W * H, sizeof(uint16_t));
    if (!fb) return 3;
    init_assets();

    char path[512];
    init_fb();
    snprintf(path, sizeof path, "%s/fb_initial.bin", out);
    wr(path, fb, (size_t)W * H * 2);
    snprintf(path, sizeof path, "%s/assets.bin", out);
    {
        static uint8_t assets[64 * 48 * 2 + 32 * 32];
        memcpy(assets, src565, sizeof src565);
        memcpy(assets + sizeof src565, a8img, sizeof a8img);
        wr(path, assets, sizeof assets);
    }

    build_case(cs);
    run_cmds();

    snprintf(path, sizeof path, "%s/%s.fb.bin", out, cs);
    wr(path, fb, (size_t)W * H * 2);

    snprintf(path, sizeof path, "%s/%s.cmds.hex", out, cs);
    {
        FILE *f = fopen(path, "w");
        if (!f) { perror(path); return 3; }
        for (int i = 0; i < ncmd; i++)
            for (int k = 0; k < cmds[i].n; k++) fprintf(f, "%08x\n", cmds[i].w[k]);
        fclose(f);
    }

    printf("case=%s fb=%dx%d cmds=%d\n", cs, W, H, ncmd);
    free(fb);
    return 0;
}
