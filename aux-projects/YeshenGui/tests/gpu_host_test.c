/* gpu_host_test.c —— 用**主机模拟**重放 VexiiYeshenLinux 的六个 2D 黄金用例，
 * 与 `sim/gpu/gold/<case>.fb.bin` 逐字节比对。
 *
 * 为什么这样判：黄金是**独立写的参考实现**（`sim/gpu/gpu2d_ref.c`），RTL 已经与它
 * 逐字节吻合；本测试把同一批命令参数喂给 `platform/gpu.c` 的主机路径 ——
 * 若驱动层把参数顺序/stride/阈值搞错，帧存立刻不同。
 *
 * 用例参数与 gpu2d_ref.c 的 build_case() 逐条相同（重复写死是为了让黄金变脏时
 * 这里能当场发现——文件比对就是判据）。
 *
 * 用法：gpu_host_test <gold_dir>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "gpu.h"

#define W 1024
#define H 600
#define FB_BYTES ((size_t)W * H * 2)
#define ASSET_ADDR 0x00200000u
#define A8_ADDR    (ASSET_ADDR + 64 * 48 * 2)

static uint16_t *g_fb;
static uint8_t  *g_assets;
static const char *g_gold;
static int g_fail;

static void *load_file(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    if (!f) { printf("  load: 打不开 %s\n", path); return NULL; }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    void *p = malloc((size_t)n);
    if (!p || fread(p, 1, (size_t)n, f) != (size_t)n) { fclose(f); free(p); return NULL; }
    fclose(f);
    if (len) *len = (size_t)n;
    return p;
}

static size_t g_assets_len;

static void reset_fb(void)
{
    char path[512];
    size_t len = 0;
    gpu_host_unbind_all();
    gpu_host_bind(ASSET_ADDR, g_assets, g_assets_len);
    snprintf(path, sizeof path, "%s/fb_initial.bin", g_gold);
    void *init = load_file(path, &len);
    if (!init || len != FB_BYTES) { g_fail = 1; free(init); return; }
    memcpy(g_fb, init, FB_BYTES);
    free(init);
    gpu_host_bind(0, g_fb, FB_BYTES);
    gpu_set_scissor(0, 0, W, H);
}

/* ---- 用例（参数逐条照抄 gpu2d_ref.c:build_case）---- */
static void case_fill_rect(void)
{
    gpu_fill(0, W, 10, 20, 100, 50, 0xF81F);
    gpu_fill(0, W, 60, 40, 200, 120, 0x07E0);
    gpu_fill(0, W, 1000, 580, 100, 100, 0x001F);
    gpu_fill(0, W, 5, 300, 1, 200, 0xFFE0);
    gpu_fence();
}

static void case_blit565(void)
{
    const uint32_t S = ASSET_ADDR;
    gpu_blit(S, 64, 0, 0, 0, 64, 48, 0, W, 100, 100, 0, 0);
    gpu_blit(S, 64, 0, 0, 0, 64, 48, 0, W, 300, 100, 1, 128);
    gpu_blit(S, 64, 0, 0, 0, 64, 48, 0, W, 500, 100, 1, 254);
    gpu_blit(S, 64, 0, 0, 0, 64, 48, 0, W, 700, 100, 1, 1);
    gpu_blit(S, 64, 0, 16, 16, 32, 32, 0, W, 880, 100, 0, 0);
    gpu_fence();
}

static void case_glyph(void)
{
    const uint32_t A = A8_ADDR;
    gpu_glyph(A, 32, 0, 0, 32, 32, 0, W, 200, 200, 0xFFFF, 255);
    gpu_glyph(A, 32, 0, 0, 32, 32, 0, W, 260, 200, 0xF800, 128);
    gpu_glyph(A, 32, 0, 0, 32, 32, 0, W, 320, 200, 0x001F, 0);
    gpu_glyph(A, 32, 8, 8, 16, 16, 0, W, 380, 200, 0x07E0, 200);
    gpu_fence();
}

static void case_round32(void)
{
    gpu_round_fill(0, W, 50, 50, 200, 120, 32, 0xFD20);
    gpu_round_fill(0, W, 300, 50, 80, 80, 0, 0x001F);
    gpu_round_fill(0, W, 400, 50, 60, 60, 30, 0x07FF);
    gpu_round_fill(0, W, 500, 50, 60, 60, 100, 0xF81F);
    gpu_round_fill(0, W, 700, 50, 1, 1, 0, 0xFFFF);
    gpu_fence();
}

static void case_scissor(void)
{
    gpu_set_scissor(200, 100, 400, 300);
    gpu_fill(0, W, 0, 0, W, H, 0xF800);
    gpu_fill(0, W, 399, 299, 10, 10, 0x07E0);
    gpu_blit(ASSET_ADDR, 64, 0, 0, 0, 64, 48, 0, W, 380, 280, 0, 0);
    gpu_glyph(A8_ADDR, 32, 0, 0, 32, 32, 0, W, 390, 290, 0xFFFF, 255);
    gpu_fence();
}

static void case_edge(void)
{
    gpu_fill(0, W, 100, 100, 0, 50, 0xFFFF);
    gpu_fill(0, W, 100, 100, 50, 0, 0xFFFF);
    gpu_fill(0, W, 1023, 599, 1, 1, 0xF81F);
    gpu_fill(0, W, 0, 0, 1, 1, 0x07E0);
    gpu_set_scissor(500, 400, 600, 500);
    gpu_blit(ASSET_ADDR, 64, 0, 0, 0, 64, 48, 0, W, 0, 0, 0, 0);
    gpu_set_scissor(0, 0, W, H);
    gpu_round_fill(0, W, 800, 400, 32, 32, 16, 0x001F);
    gpu_fence();
}

struct tcase { const char *name; void (*run)(void); };
static const struct tcase k_cases[] = {
    { "fill_rect", case_fill_rect },
    { "blit565",   case_blit565   },
    { "glyph",     case_glyph     },
    { "round32",   case_round32   },
    { "scissor",   case_scissor   },
    { "edge",      case_edge      },
};

static int run_case(const struct tcase *c)
{
    char path[512];
    size_t len = 0;
    reset_fb();
    if (g_fail) return 1;
    c->run();
    snprintf(path, sizeof path, "%s/%s.fb.bin", g_gold, c->name);
    uint8_t *exp = load_file(path, &len);
    if (!exp) return 1;
    if (len != FB_BYTES) {
        printf("  %-10s 黄金尺寸 %zu != %zu\n", c->name, len, FB_BYTES);
        free(exp);
        return 1;
    }
    size_t first = FB_BYTES;
    for (size_t i = 0; i < FB_BYTES; i++) {
        if (exp[i] != ((uint8_t *)g_fb)[i]) { first = i; break; }
    }
    int ok = (first == FB_BYTES);
    printf("  %-10s %s", c->name, ok ? "MATCH" : "MISMATCH");
    if (!ok) {
        size_t px = first / 2;
        printf("  first@byte %zu (x=%zu y=%zu) got=0x%04X exp=0x%04X",
               first, px % W, px / W, g_fb[px],
               (uint16_t)(exp[first] | (exp[first + 1] << 8)));
        size_t bad = 0;
        for (size_t i = 0; i < FB_BYTES; i += 2) {
            uint16_t e = (uint16_t)(exp[i] | (exp[i + 1] << 8));
            if (e != g_fb[i / 2]) bad++;
        }
        printf("  (diff px=%zu/%d)", bad, W * H);
    }
    printf("\n");
    free(exp);
    return ok ? 0 : 1;
}

int main(int argc, char **argv)
{
    g_gold = (argc > 1) ? argv[1] : "../VexiiYeshenLinux/sim/gpu/gold";
    g_fb = calloc((size_t)W * H, sizeof(uint16_t));
    if (!g_fb) return 3;
    if (gpu_init() != 0) { printf("gpu_init 失败\n"); return 3; }
    {
        char path[512];
        snprintf(path, sizeof path, "%s/assets.bin", g_gold);
        g_assets = load_file(path, &g_assets_len);
        if (!g_assets) return 3;
    }

    int fails = 0;
    for (size_t i = 0; i < sizeof k_cases / sizeof k_cases[0]; i++)
        fails += run_case(&k_cases[i]);

    gpu_shutdown();
    free(g_fb);
    free(g_assets);
    printf("GPU_HOST: %s (%d/%zu 例)\n",
           fails == 0 ? "PASS" : "FAIL", (int)(sizeof k_cases / sizeof k_cases[0]) - fails,
           sizeof k_cases / sizeof k_cases[0]);
    return fails == 0 ? 0 : 1;
}
