/* cube3d.c —— 桌面里的 3D 应用：窗口内一块 640×480 的 GPU 3D 画面。
 *
 * 思路（不碰 RTL）：
 *   · 3D 引擎固定画进 GPU_COLOR3D（0xBF00_0000，640×480 RGB565）+ GPU_Z3D 的 Z 缓冲；
 *   · 把这块**物理缓冲**用 gpu_draw_unit_bind_image() 绑成一张普通 LVGL 图像的源
 *     ⇒ 桌面绘制时走 GPU BLIT 零拷贝，且不会读到缓存里的旧帧；
 *   · 定时器里：CPU 算 12 个三角形（背面剔除 + 逐面 N·L 光照 + 每面常数深度）→
 *     CLEAR3D/DRAW_TRIS/FENCE → 图像失效让桌面重画；
 *   · 触摸拖动改 yaw/pitch，松手后自转。
 *
 * 性能口径：一次渲染 ≈ 每面 6×6=36 个 32×32 tile（相机 z=6 ⇒ 立方体约 230 px），
 *   三个可见面 ≈ 110 个 tile ≈ 80 ms（DDR 延迟主导，见 gpu-p2a 报告）。
 */
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE 1
#endif

#include "apps.h"

#include "gpu.h"
#include "gpu_draw_unit.h"
#include "gpu_regs.h"
#include "theme.h"
#include "wm.h"

#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define VB_W 640
#define VB_H 480          /* GPU 3D 缓冲固定 640x480 */
#define VB_SHOW_H 448     /* 窗口里只显示上半 448 行：桌面可用区 1024x524，
                           * 顶面板 40 + 任务栏 36 ⇒ 窗口高 ≤ 524-36(标题)-16(内边距) */
#define CYP (VB_SHOW_H / 2.0f)
#define WIN_W (VB_W + 24)
#define WIN_H (VB_SHOW_H + 36 + 16)
#define CAM_Z 6.0f
#define FOCAL (480.0f * 1.2f)
#define BG3D 0xE77Eu /* RGB565 #E7EDF4，与主题的浅冷灰一致 */
#define ACCENT565 0xA806u   /* #A80030 → RGB565 */

#define TICK_MS 150

typedef struct { float x, y, z; } v3;

/* 顶点编号：i&1→x=±1, i&2→y=±1, i&4→z=±1 */
static const int CUBE_TRI[12][3] = {
    {0,1,3},{0,3,2},   /* -Z */
    {4,5,7},{4,7,6},   /* +Z */
    {0,4,5},{0,5,1},   /* -Y */
    {3,2,6},{3,6,7},   /* +Y */
    {0,2,6},{0,6,4},   /* -X */
    {1,3,7},{1,7,5},   /* +X */
};
static const int FACE_V[6][4] = {
    {0,1,2,3}, {4,5,6,7}, {0,1,4,5}, {2,3,6,7}, {0,2,4,6}, {1,3,5,7}
};
static const float FACE_N[6][3] = {
    {0,0,-1}, {0,0,1}, {0,-1,0}, {0,1,0}, {-1,0,0}, {1,0,0}
};

static lv_obj_t       *s_img;
static lv_image_dsc_t  s_dsc;
static lv_timer_t     *s_timer;
static uint8_t        *s_pix;      /* GPU_COLOR3D 的 CPU 视图（桌面 SW 回退时也读它） */
static uint32_t        s_tri_phys;
static uint8_t        *s_recs;
static float           s_yaw = 0.6f, s_pitch = 0.35f;
static int             s_drag;
static int             s_ok;

static uint16_t shade565(uint16_t c, float s)
{
    int r = (c >> 11) & 0x1F, g = (c >> 5) & 0x3F, b = c & 0x1F;
    r = (int)(r * s + 0.5f); g = (int)(g * s + 0.5f); b = (int)(b * s + 0.5f);
    if (r > 31) r = 31;
    if (g > 63) g = 63;
    if (b > 31) b = 31;
    return (uint16_t)((r << 11) | (g << 5) | b);
}

static void rot(v3 *p, float cy, float sy, float cp, float sp)
{
    float x = p->x * cy + p->z * sy;
    float z = -p->x * sy + p->z * cy;
    float y = p->y * cp - z * sp;
    float z2 = p->y * sp + z * cp;
    p->x = x; p->y = y; p->z = z2;
}

static int32_t q8(float v) { return (int32_t)(v * 256.0f + (v >= 0 ? 0.5f : -0.5f)); }

/* 写一条 48 B 记录：顶点已是屏幕 8.8，z 为常数（凸立方体只需面间排序） */
static void emit(uint8_t *rec, const int32_t *x, const int32_t *y, uint16_t z, uint16_t color)
{
    uint64_t *w = (uint64_t *)rec;
    w[0] = ((uint64_t)(uint32_t)y[0] << 32) | (uint32_t)x[0];
    w[1] = ((uint64_t)(uint32_t)y[1] << 32) | (uint32_t)x[1];
    w[2] = ((uint64_t)(uint32_t)y[2] << 32) | (uint32_t)x[2];
    w[3] = ((uint64_t)color << 16) | z;   /* dzdx = 0 */
    w[4] = 0;                             /* dzdy = 0, zmode = LESS */
    w[5] = 0;
}

static int build_records(float yaw, float pitch)
{
    float sy = sinf(yaw), cy = cosf(yaw), sp = sinf(pitch), cp = cosf(pitch);
    v3 cube[8];
    for (int i = 0; i < 8; i++) {
        cube[i].x = (i & 1) ? 1.0f : -1.0f;
        cube[i].y = (i & 2) ? 1.0f : -1.0f;
        cube[i].z = (i & 4) ? 1.0f : -1.0f;
        rot(&cube[i], cy, sy, cp, sp);
    }
    int vis[6];
    for (int f = 0; f < 6; f++) {
        v3 n = { FACE_N[f][0], FACE_N[f][1], FACE_N[f][2] }, c = { 0, 0, 0 };
        rot(&n, cy, sy, cp, sp);
        for (int k = 0; k < 4; k++) {
            const v3 *p = &cube[FACE_V[f][k]];
            c.x += p->x * 0.25f; c.y += p->y * 0.25f; c.z += p->z * 0.25f;
        }
        vis[f] = (n.x * (0 - c.x) + n.y * (0 - c.y) + n.z * (CAM_Z - c.z)) > 0.0f;
    }
    int n = 0;
    for (int t = 0; t < 12; t++) {
        if (!vis[t / 2]) continue;
        int32_t sx[3], sy8[3];
        float zs = 0.0f;
        int ok = 1;
        for (int k = 0; k < 3; k++) {
            v3 p = cube[CUBE_TRI[t][k]];
            float zc = CAM_Z - p.z;
            if (zc < 0.2f) { ok = 0; break; }
            sx[k]  = q8(320.0f + FOCAL * p.x / zc);
            sy8[k] = q8(CYP - FOCAL * p.y / zc);
            zs += zc;
        }
        if (!ok) continue;
        zs /= 3.0f;
        int zi = (int)((zs - 0.2f) / 7.8f * 60000.0f + 0.5f);
        if (zi < 0) zi = 0;
        if (zi > 60000) zi = 60000;
        v3 nn = { FACE_N[t / 2][0], FACE_N[t / 2][1], FACE_N[t / 2][2] };
        rot(&nn, cy, sy, cp, sp);
        float ndl = nn.x * (-0.45f) + nn.y * 0.55f + nn.z * 0.72f;
        if (ndl < 0.0f) ndl = 0.0f;
        uint16_t col = shade565(ACCENT565, 0.32f + 0.78f * ndl);
        emit(s_recs + n * 48, sx, sy8, (uint16_t)zi, col);
        n++;
    }
    return n;
}

static void tick_cb(lv_timer_t *t)
{
    LV_UNUSED(t);
    if (!s_ok) return;
    int n = build_records(s_yaw, s_pitch);
    gpu_clear3d(BG3D, 0xFFFF);
    if (n) gpu_draw_tris(s_tri_phys, n);
    if (gpu_fence() < 0) { s_ok = 0; return; }
    if (!s_drag) s_yaw += 0.03f;
    if (s_yaw > 3.14159265f) s_yaw -= 6.28318531f;
    if (s_yaw < -3.14159265f) s_yaw += 6.28318531f;
    lv_obj_invalidate(s_img);
}

static void img_event(lv_event_t *e)
{
    lv_event_code_t code = lv_event_get_code(e);
    if (code == LV_EVENT_PRESSED) {
        s_drag = 1;
    } else if (code == LV_EVENT_PRESSING) {
        lv_point_t v;
        lv_indev_t *indev = lv_indev_active();
        if (!indev) return;
        lv_indev_get_vect(indev, &v);
        s_yaw   += (float)v.x * 0.02f;
        s_pitch += (float)v.y * 0.02f;
        if (s_pitch > 1.4f) s_pitch = 1.4f;
        if (s_pitch < -1.4f) s_pitch = -1.4f;
    } else if (code == LV_EVENT_RELEASED || code == LV_EVENT_PRESS_LOST) {
        s_drag = 0;
    }
}

static void on_close(ui_window_t *win)
{
    LV_UNUSED(win);
    if (s_timer) { lv_timer_delete(s_timer); s_timer = NULL; }
    s_img = NULL;
    s_ok = 0;
}

void app_cube3d_close(void)
{
    if (s_img) on_close(NULL);
}

void app_cube3d_open(void)
{
    if (s_img) { lv_obj_move_foreground(lv_obj_get_parent(s_img)); return; }
    if (!gpu_present()) {
        lv_obj_t *c = NULL;
        ui_window_t *w = wm_open("3D Cube", 360, 160, false, &c, NULL);
        if (w) {
            lv_obj_t *l = lv_label_create(c);
            lv_label_set_text(l, "GPU not present");
            lv_obj_center(l);
        }
        return;
    }

    /* 记录区（12×48 B）+ 3D 颜色缓冲的 CPU 视图 */
    void *recs = gpu_arena_alloc(12 * 48, &s_tri_phys);
    if (!recs) return;
    s_recs = (uint8_t *)recs;
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd >= 0) {
        void *p = mmap(NULL, VB_W * VB_H * 2, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)GPU_COLOR3D);
        if (p != MAP_FAILED) s_pix = p;
        close(fd);
    }

    lv_obj_t *content = NULL;
    ui_window_t *win = wm_open("3D Cube", WIN_W, WIN_H, false, &content, on_close);
    if (!win || !content) return;

    s_dsc.header.magic  = LV_IMAGE_HEADER_MAGIC;
    s_dsc.header.cf     = LV_COLOR_FORMAT_RGB565;
    s_dsc.header.w      = VB_W;
    s_dsc.header.h      = VB_SHOW_H;
    s_dsc.header.stride = VB_W * 2;
    s_dsc.data_size     = VB_W * VB_H * 2;   /* 缓冲仍是整帧，只显示前 VB_SHOW_H 行 */
    s_dsc.data          = s_pix;

    s_img = lv_image_create(content);
    lv_image_set_src(s_img, &s_dsc);
    lv_obj_set_size(s_img, VB_W, VB_SHOW_H);   /* 显式尺寸：别让布局给的区域大于图像本身 */
    lv_obj_remove_flag(s_img, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(s_img, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_center(s_img);
    lv_obj_add_event_cb(s_img, img_event, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(s_img, img_event, LV_EVENT_PRESSING, NULL);
    lv_obj_add_event_cb(s_img, img_event, LV_EVENT_RELEASED, NULL);
    lv_obj_add_event_cb(s_img, img_event, LV_EVENT_PRESS_LOST, NULL);
    {
        lv_area_t ic;
        lv_obj_update_layout(content);
        lv_obj_get_coords(s_img, &ic);
        char msg[160];
        snprintf(msg, sizeof msg, "cube3d: img obj=(%d..%d,%d..%d) dsc=%dx%d",
                 (int)ic.x1, (int)ic.x2, (int)ic.y1, (int)ic.y2, VB_W, VB_SHOW_H);
        platform_log(msg);
    }
    /* 零拷贝：BLIT 直接读 3D 引擎写的那块物理缓冲。
     * 只有 GPU draw unit 变体才有这个绑定口；SW 版（host_sw 闸门）没有。 */
#ifdef YESHEN_GUI_GPU_UNIT
    gpu_draw_unit_bind_image(&s_dsc, GPU_COLOR3D, VB_W);
#endif

    s_ok = 1;
    s_timer = lv_timer_create(tick_cb, TICK_MS, NULL);
    tick_cb(NULL);
}
