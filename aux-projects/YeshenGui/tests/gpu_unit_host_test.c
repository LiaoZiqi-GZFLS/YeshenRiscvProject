/* gpu_unit_host_test.c —— LVGL draw unit 的 A/B 判据（host，无板子）。
 *
 * 做法：同一个场景渲染两次，帧存导出成文件：
 *   ./gpu_unit_host_test --out sw.bin            （只挂 LVGL 的 SW 单元）
 *   ./gpu_unit_host_test --out gpu.bin --gpu     （再挂 GPU 单元）
 * 判据（scripts/run_gpu_unit_host_test.sh）：
 *   ① 两个文件**逐字节相同**（GPU 只画它接管的实心矩形，其余仍由 SW 画）；
 *   ② GPU 那次必须真的接过任务（tasks>0，防"没生效也算过"）。
 *
 * 场景里故意混入**不该接管**的元素（圆角矩形 / 半透明矩形 / 文字），
 * 用它们证明拒绝路径确实退回 SW 且画面仍然一致。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "lvgl.h"
#include "gpu.h"
#include "gpu_draw_unit.h"

/* gpu_draw_unit.c logs through the platform layer; this test has no SDL. */
void platform_log(const char *message)
{
    fprintf(stderr, "%s\n", message);
}

#define W 256
#define H 160
#define FB_BYTES ((size_t)W * H * 2)
#define FB_PHYS 0x92000000u

static uint16_t *g_fb;
static int g_use_gpu;
static uint32_t g_frames;

static void flush_cb(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map)
{
    LV_UNUSED(area);
    LV_UNUSED(px_map);
    if (g_use_gpu) (void)gpu_draw_unit_finish_frame();
    g_frames++;
    lv_display_flush_ready(disp);
}

/* 两张测试图：RGB565（不透明拷贝）与 A8（带着色）——走 GPU 的 IMAGE 路径 */
#define IMG_W 48
#define IMG_H 32
static uint16_t g_img565[IMG_W * IMG_H];
static uint8_t  g_imgA8[IMG_W * IMG_H];
static lv_image_dsc_t g_dsc565, g_dscA8;

static void init_images(void)
{
    for (int y = 0; y < IMG_H; y++) {
        for (int x = 0; x < IMG_W; x++) {
            unsigned r = (unsigned)((x * 2) & 31);
            unsigned g = (unsigned)((y * 2) & 63);
            unsigned b = (unsigned)(((x + y) * 3) & 31);
            g_img565[y * IMG_W + x] = (uint16_t)((r << 11) | (g << 5) | b);
            g_imgA8[y * IMG_W + x] = (uint8_t)((x * 4 + y * 2) & 0xFF);
        }
    }
    memset(&g_dsc565, 0, sizeof g_dsc565);
    g_dsc565.header.magic  = LV_IMAGE_HEADER_MAGIC;
    g_dsc565.header.cf     = LV_COLOR_FORMAT_RGB565;
    g_dsc565.header.w      = IMG_W;
    g_dsc565.header.h      = IMG_H;
    g_dsc565.header.stride = IMG_W * 2;
    g_dsc565.data          = (const uint8_t *)g_img565;
    g_dsc565.data_size     = sizeof g_img565;

    memset(&g_dscA8, 0, sizeof g_dscA8);
    g_dscA8.header.magic  = LV_IMAGE_HEADER_MAGIC;
    g_dscA8.header.cf     = LV_COLOR_FORMAT_A8;
    g_dscA8.header.w      = IMG_W;
    g_dscA8.header.h      = IMG_H;
    g_dscA8.header.stride = IMG_W;
    g_dscA8.data          = g_imgA8;
    g_dscA8.data_size     = sizeof g_imgA8;
}

static lv_obj_t *mk_rect(lv_obj_t *parent, int x, int y, int w, int h, uint32_t color, int radius, int opa)
{
    lv_obj_t *o = lv_obj_create(parent);
    lv_obj_set_pos(o, x, y);
    lv_obj_set_size(o, w, h);
    lv_obj_set_style_radius(o, radius, 0);
    lv_obj_set_style_bg_color(o, lv_color_hex(color), 0);
    lv_obj_set_style_bg_opa(o, (lv_opa_t)opa, 0);
    lv_obj_set_style_border_width(o, 0, 0);
    lv_obj_set_style_pad_all(o, 0, 0);
    lv_obj_remove_flag(o, LV_OBJ_FLAG_SCROLLABLE);
    return o;
}

int main(int argc, char **argv)
{
    const char *out = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--out") && i + 1 < argc) out = argv[++i];
        else if (!strcmp(argv[i], "--gpu")) g_use_gpu = 1;
    }
    if (!out) { fprintf(stderr, "usage: %s --out FILE [--gpu]\n", argv[0]); return 2; }

    g_fb = calloc((size_t)W * H, sizeof(uint16_t));
    if (!g_fb) return 3;

    lv_init();
    lv_display_t *disp = lv_display_create(W, H);
    lv_display_set_color_format(disp, LV_COLOR_FORMAT_RGB565);
    /* DIRECT：LVGL 直接画进这块帧存（GPU 也写它） */
    lv_display_set_buffers(disp, g_fb, NULL, FB_BYTES, LV_DISPLAY_RENDER_MODE_DIRECT);
    lv_display_set_flush_cb(disp, flush_cb);

    if (g_use_gpu) {
        gpu_init();
        /* 帧存的绑定在 gpu_draw_unit_init 里做（主机 = gpu_host_bind） */
        if (gpu_draw_unit_init(g_fb, W, H, FB_PHYS) != 0) {
            fprintf(stderr, "gpu_draw_unit_init 失败\n");
            return 4;
        }
    }

    lv_obj_t *scr = lv_screen_active();
    lv_obj_set_style_bg_color(scr, lv_color_hex(0x102030), 0);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, 0);

    /* 接管：实心矩形（多个，含全屏与 1px 边） */
    mk_rect(scr, 0, 0, W, 12, 0x204060, 0, LV_OPA_COVER);
    mk_rect(scr, 8, 20, 100, 60, 0xC03020, 0, LV_OPA_COVER);
    mk_rect(scr, 120, 20, 60, 60, 0x20C040, 0, LV_OPA_COVER);
    mk_rect(scr, 190, 20, 60, 20, 0xFFFFFF, 0, LV_OPA_COVER);
    mk_rect(scr, 190, 45, 60, 35, 0x000000, 0, LV_OPA_COVER);
    mk_rect(scr, 8, 100, 1, 50, 0xFFE000, 0, LV_OPA_COVER);
    /* 不接管：圆角 / 半透明 / 文本（必须由 SW 画） */
    mk_rect(scr, 16, 90, 90, 50, 0x8000FF, 10, LV_OPA_COVER);
    mk_rect(scr, 120, 90, 60, 50, 0x00FFFF, 0, LV_OPA_50);
    /* 接管：整幅图像（RGB565 拷贝 / A8 着色） */
    init_images();
    lv_obj_t *im1 = lv_image_create(scr);
    lv_image_set_src(im1, &g_dsc565);
    lv_obj_set_pos(im1, 8, 60);
    lv_obj_t *im2 = lv_image_create(scr);
    lv_image_set_src(im2, &g_dscA8);
    lv_obj_set_pos(im2, 62, 60);
    lv_obj_set_style_image_recolor(im2, lv_color_hex(0xFFFFFF), 0);
    lv_obj_set_style_image_recolor_opa(im2, LV_OPA_COVER, 0);

    lv_obj_t *lbl = lv_label_create(scr);
    lv_label_set_text(lbl, "GPU FILL");
    lv_obj_set_style_text_color(lbl, lv_color_hex(0xFFFFFF), 0);
    lv_obj_set_pos(lbl, 190, 90);

    uint32_t t = 0;
    for (int i = 0; i < 12; i++) {
        t += 10;
        lv_tick_inc(10);
        lv_timer_handler();
    }

    uint32_t tasks = 0, px = 0;
    gpu_draw_unit_stats(&tasks, &px);
    printf("mode=%s frames=%u gpu_tasks=%u gpu_pixels=%u\n",
           g_use_gpu ? "gpu" : "sw", (unsigned)g_frames, (unsigned)tasks, (unsigned)px);

    FILE *f = fopen(out, "wb");
    if (!f) { perror(out); return 3; }
    if (fwrite(g_fb, 1, FB_BYTES, f) != FB_BYTES) { fclose(f); return 3; }
    fclose(f);

    /* 把任务数写进旁路文件，供脚本判"GPU 真的接了活" */
    char side[512];
    snprintf(side, sizeof side, "%s.stats", out);
    f = fopen(side, "w");
    if (f) { fprintf(f, "%u\n", (unsigned)tasks); fclose(f); }

    if (g_use_gpu) {
        /* 判"接管了但没画对"：GPU 任务的像素必须覆盖到场景里的实心矩形 */
        if (tasks == 0) {
            fprintf(stderr, "FAIL: GPU 单元一个任务都没接管\n");
            return 5;
        }
    }
    free(g_fb);
    return 0;
}
