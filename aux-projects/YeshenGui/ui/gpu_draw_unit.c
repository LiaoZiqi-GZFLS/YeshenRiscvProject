/* gpu_draw_unit.c —— LVGL 9.2 draw unit：实心矩形与整幅图像走硬件 2D 引擎。
 *
 * 接管的类型（其余一律在 evaluate 里拒绝、交回 SW 单元，**不做半途降级**）：
 *   · FILL  ：目标就是屏幕帧存，物理地址已知；
 *   · IMAGE ：RGB565 / A8，无旋转/缩放/倾斜、无 mask、不 tile、不带着色。
 *             源在堆上只有虚拟地址 ⇒ 首次用到时整块复制进**固定物理区 arena**
 *             （0xBF20_0000，/dev/mem + O_SYNC ⇒ CPU 写完 GPU 立刻可见，
 *             不需要 cbo.flush）。
 *   · LABEL ：暂不接（要遍历字形 + 字体位图，像素占比小），SW 单元照常画。
 *
 * 判据（host，见 tests/gpu_unit_host_test.c）：同一场景 GPU 单元开/关两次渲染的
 *   帧存逐字节相同，且 GPU 那次必须真的接管了任务。
 */
#include "gpu_draw_unit.h"

#ifdef YESHEN_GUI_GPU_UNIT

#include "lvgl.h"
#include "src/lvgl_private.h"   /* 自定义 draw unit 要 lv_draw_task_t / lv_layer_t 的完整定义 */
#include "gpu.h"
#include "platform.h"     /* platform_log()（-Wimplicit-function-declaration） */

#include <stdio.h>
#include <string.h>

#define GPU_DRAW_UNIT_ID 2   /* 1 = LVGL 的 SW 单元（lv_draw_sw.c 里 DRAW_UNIT_ID_SW） */

typedef struct {
    lv_draw_unit_t base;
} gpu_unit_t;

static uint16_t *s_fb;
static int       s_w, s_h;
static uint32_t  s_fb_phys;
static uint32_t  s_tasks, s_pixels;

/* ---- 图像源缓存：堆上的图像复制进 arena，换一个 GPU 能读的物理地址 ---- */
typedef struct {
    const void *src;
    uint32_t phys;
    void    *host;      /* arena 里的可写视图；bind_image 的零拷贝源为 NULL */
    int      stride_px;
    int      w, h;
    uint8_t  cf;
} img_cache_t;

#define IMG_CACHE_N 8
static img_cache_t s_imgs[IMG_CACHE_N];
static int         s_nimg;

static const img_cache_t *img_ensure(const lv_image_dsc_t *img)
{
    if (!img || !img->data || img->header.w == 0 || img->header.h == 0) return NULL;
    if (img->header.cf != LV_COLOR_FORMAT_RGB565) return NULL;
    for (int i = 0; i < s_nimg; i++)
        if (s_imgs[i].src == (const void *)img) return &s_imgs[i];
    if (s_nimg >= IMG_CACHE_N) return NULL;

    int bpp = 2;
    size_t bytes = (size_t)img->header.stride * img->header.h;
    uint32_t phys = 0;
    void *dst = gpu_arena_alloc(bytes, &phys);
    if (!dst) return NULL;
    memcpy(dst, img->data, bytes);

    img_cache_t *c = &s_imgs[s_nimg++];
    c->src       = img;
    c->phys      = phys;
    c->host      = dst;
    c->stride_px = (int)img->header.stride / bpp;
    c->w         = (int)img->header.w;
    c->h         = (int)img->header.h;
    c->cf        = (uint8_t)img->header.cf;
    return c;
}

/* 见头文件：按物理地址直接绑定，跳过 arena 拷贝。 */
void gpu_draw_unit_bind_image(const lv_image_dsc_t *img, uint32_t phys, int stride_px)
{
    if (!img || !phys || img->header.w == 0 || img->header.h == 0) return;
    for (int i = 0; i < s_nimg; i++)
        if (s_imgs[i].src == (const void *)img) {
            s_imgs[i].phys = phys;
            s_imgs[i].host = NULL;
            s_imgs[i].stride_px = stride_px;
            s_imgs[i].w = (int)img->header.w;
            s_imgs[i].h = (int)img->header.h;
            return;
        }
    if (s_nimg >= IMG_CACHE_N) return;
    img_cache_t *c = &s_imgs[s_nimg++];
    c->src       = img;
    c->phys      = phys;
    c->host      = NULL;
    c->stride_px = stride_px;
    c->w         = (int)img->header.w;
    c->h         = (int)img->header.h;
    c->cf        = (uint8_t)img->header.cf;
}

/* 见头文件：原地改过内容的图像，把新像素重新灌进它的 arena 源。 */
void gpu_draw_unit_touch(const lv_image_dsc_t *img)
{
    if (!img || !img->data) return;
    for (int i = 0; i < s_nimg; i++)
        if (s_imgs[i].src == (const void *)img) {
            if (s_imgs[i].host)
                memcpy(s_imgs[i].host, img->data,
                       (size_t)img->header.stride * img->header.h);
            return;
        }
}

static int img_acceptable(const lv_draw_image_dsc_t *d)
{
    if (!d || !d->src) return 0;
    if (d->rotation != 0 || d->scale_x != LV_SCALE_NONE || d->scale_y != LV_SCALE_NONE) return 0;
    if (d->skew_x != 0 || d->skew_y != 0) return 0;
    if (d->bitmap_mask_src != NULL || d->tile) return 0;
    if (d->blend_mode != LV_BLEND_MODE_NORMAL) return 0;
    /* 只接 RGB565：A8 图像在 LVGL 里走的是"掩码 + 着色"，混合口径与 GFX 的
     * A8 字形路径不一致（实测逐像素有差异）⇒ 一律交回 SW，不做近似。 */
    if (d->header.cf != LV_COLOR_FORMAT_RGB565) return 0;
    if (d->recolor_opa > LV_OPA_TRANSP) return 0;      /* 着色交回 SW */
    return 1;
}

static int32_t gpu_evaluate(lv_draw_unit_t *u, lv_draw_task_t *t)
{
    LV_UNUSED(u);
    if (!s_fb) return 0;

    lv_draw_dsc_base_t *b = (lv_draw_dsc_base_t *)t->draw_dsc;
    lv_layer_t *layer = b ? b->layer : NULL;
    /* 只接**屏幕层**（DIRECT 模式下 draw_buf 就是我们的帧存）；中间层交回 SW */
    if (!layer || !layer->draw_buf || (const void *)layer->draw_buf->data != (const void *)s_fb) return 0;

    if (t->type == LV_DRAW_TASK_TYPE_FILL) {
        lv_draw_fill_dsc_t *d = (lv_draw_fill_dsc_t *)t->draw_dsc;
        if (!d) return 0;
        if (d->grad.dir != LV_GRAD_DIR_NONE) return 0;   /* 渐变交回 SW */
        if (d->radius > 0) return 0;                     /* 圆角交回 SW */
        if (d->opa < LV_OPA_COVER) return 0;             /* 半透明交回 SW（FILL 无 alpha 参数） */
    } else if (t->type == LV_DRAW_TASK_TYPE_IMAGE) {
        lv_draw_image_dsc_t *d = (lv_draw_image_dsc_t *)t->draw_dsc;
        if (!img_acceptable(d)) return 0;
        if (!img_ensure((const lv_image_dsc_t *)d->src)) return 0;   /* arena 满 ⇒ 交回 SW */
    } else {
        return 0;
    }

    t->preferred_draw_unit_id = GPU_DRAW_UNIT_ID;
    t->preference_score = 0;      /* 越小越优先 */
    return 0;
}

static int32_t gpu_dispatch(lv_draw_unit_t *u, lv_layer_t *layer)
{
    LV_UNUSED(u);
    if (!s_fb) return LV_DRAW_UNIT_IDLE;
    if (!layer->draw_buf || (const void *)layer->draw_buf->data != (const void *)s_fb) return LV_DRAW_UNIT_IDLE;

    lv_draw_task_t *t = lv_draw_get_next_available_task(layer, NULL, GPU_DRAW_UNIT_ID);
    if (!t) return LV_DRAW_UNIT_IDLE;

    t->state = LV_DRAW_TASK_STATE_IN_PROGRESS;

    if (t->type == LV_DRAW_TASK_TYPE_FILL) {
        lv_draw_fill_dsc_t *d = (lv_draw_fill_dsc_t *)t->draw_dsc;
        lv_area_t a = t->area;
        if (d && d->grad.dir == LV_GRAD_DIR_NONE && d->radius <= 0 &&
            d->opa >= LV_OPA_COVER && _lv_area_intersect(&a, &a, &t->clip_area)) {
            int x = a.x1, y = a.y1;
            int w = lv_area_get_width(&a);
            int h = lv_area_get_height(&a);
            if (w > 0 && h > 0) {
                uint16_t c = lv_color_to_u16(d->color);
                if (gpu_fill(s_fb_phys, s_w, x, y, w, h, c) == 0) {
                    s_tasks++;
                    s_pixels += (uint32_t)w * (uint32_t)h;
                }
            }
        }
    } else if (t->type == LV_DRAW_TASK_TYPE_IMAGE) {
        lv_draw_image_dsc_t *d = (lv_draw_image_dsc_t *)t->draw_dsc;
        const img_cache_t *c = (d && img_acceptable(d))
                             ? img_ensure((const lv_image_dsc_t *)d->src) : NULL;
        lv_area_t a = t->area;
        {
            static int once;
            if (!once && c) {
                once = 1;
                char msg[192];
                snprintf(msg, sizeof msg,
                         "GPU-IMG: task_area=(%d..%d,%d..%d) clip=(%d..%d,%d..%d) img=%dx%d stride=%d",
                         (int)t->area.x1, (int)t->area.x2, (int)t->area.y1, (int)t->area.y2,
                         (int)t->clip_area.x1, (int)t->clip_area.x2,
                         (int)t->clip_area.y1, (int)t->clip_area.y2,
                         c->w, c->h, c->stride_px);
                platform_log(msg);
            }
        }
        if (c && _lv_area_intersect(&a, &a, &t->clip_area)) {
            int w = lv_area_get_width(&a);
            int h = lv_area_get_height(&a);
            /* 无变换：源起点 = 图像左上 + 被裁掉的偏移 */
            int sx = a.x1 - t->area.x1;
            int sy = a.y1 - t->area.y1;
            /* ★ 2026-11-01：原来"超出图像范围就整块不画"，但桌面（DIRECT 模式）抽到的
             *   任务区域可能比图像大（实测 3D 图 640x448 被按整屏 1024x600 派下来），
             *   于是这一块直接留成 LVGL 底色 = **白屏**。改成把源/目标一起夹紧到图像
             *   尺寸内，画能画的那部分。 */
            if (sx < 0) { a.x1 -= sx; w += sx; sx = 0; }
            if (sy < 0) { a.y1 -= sy; h += sy; sy = 0; }
            if (sx + w > c->w) w = c->w - sx;
            if (sy + h > c->h) h = c->h - sy;
            if (sx >= 0 && sy >= 0 && w > 0 && h > 0) {
                int blend = (d->opa < LV_OPA_COVER);
                int rc = gpu_blit(c->phys, c->stride_px, 0, sx, sy, w, h,
                                  s_fb_phys, s_w, a.x1, a.y1, blend, (int)d->opa);
                if (rc == 0) {
                    s_tasks++;
                    s_pixels += (uint32_t)w * (uint32_t)h;
                }
            }
        }
    }

    /* ★ 2026-11-01：**每个任务提交后等它落地**。GPU 命令是异步排队的，而 LVGL 的
     *   软件绘制（图标圆角/文字）是 CPU 即时写的 —— 不同步时，排在队首的大图 BLIT
     *   （桌面壁纸 1024x600）可能晚于后面的软件绘制执行，把图标整片盖掉（板上实测：
     *   图标区只剩壁纸色）。等一拍即恢复严格的 z 序，代价是每任务 0.2~2 ms。 */
    (void)gpu_draw_unit_finish_frame();

    t->state = LV_DRAW_TASK_STATE_READY;
    return 1;
}

int gpu_draw_unit_init(uint16_t *fb, int w, int h, uint32_t fb_phys)
{
    if (!fb || w <= 0 || h <= 0) return -1;
    if (!gpu_present() && gpu_init() != 0) return -1;
    s_fb = fb;
    s_w = w;
    s_h = h;
    s_fb_phys = fb_phys;
    s_tasks = s_pixels = 0;
    s_nimg = 0;
    /* 主机侧：把"物理地址"绑到这块内存（板端是空实现，真帧存本来就有物理地址） */
    gpu_host_bind(fb_phys, fb, (size_t)w * h * 2);
    if (gpu_arena_init() != 0) return -1;

    gpu_unit_t *unit = (gpu_unit_t *)lv_draw_create_unit(sizeof(gpu_unit_t));
    if (!unit) return -1;
    unit->base.dispatch_cb = gpu_dispatch;
    unit->base.evaluate_cb = gpu_evaluate;
    return 0;
}

int gpu_draw_unit_finish_frame(void)
{
    if (!s_fb) return 0;
    if (s_tasks == 0) return 0;      /* 这一帧没接过任务 ⇒ 不占 FIFO */
    return (gpu_fence() < 0) ? -1 : 0;
}

void gpu_draw_unit_stats(uint32_t *tasks, uint32_t *pixels)
{
    if (tasks) *tasks = s_tasks;
    if (pixels) *pixels = s_pixels;
}

#endif /* YESHEN_GUI_GPU_UNIT */
