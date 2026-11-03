#include "app.h"
#include "apps/apps.h"
#include "apps/gb.h"
#include "desktop.h"
#include "platform.h"
#include "theme.h"
#include "wm.h"
#include "lvgl.h"
#ifdef YESHEN_GUI_GPU_UNIT
#include "gpu.h"
#include "gpu_draw_unit.h"
#endif
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint16_t g_buf1[UI_SCREEN_W * 100];
static uint16_t g_buf2[UI_SCREEN_W * 100];
static lv_display_t *g_disp;
static lv_group_t *g_group;

/* LVGL flushes since the last YGUI-FPS window (liveness marker only). */
static uint32_t g_frames;

/* Keys that are not global shortcuts are handed to the keypad indev. */
static ui_key_t g_key_q[16];
static int g_qh, g_qt;
static bool g_key_release;
static bool g_quit;

static void app_shutdown(void)
{
    platform_present_stop();
    platform_shutdown();
}

static void flush_cb(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map)
{
    ui_surface_t s = {
        .width = lv_area_get_width(area),
        .height = lv_area_get_height(area),
        .pixels = (uint16_t *)px_map,
        .stride_px = lv_area_get_width(area),
    };
    platform_present(&s, area->x1, area->y1, area->x2, area->y2);
    g_frames++;
    lv_display_flush_ready(disp);
}

#ifdef YESHEN_GUI_GPU_UNIT
/* 每帧整屏重绘（≈30 Hz）：DIRECT 模式没有备份缓冲，只靠脏区推断会在切应用后留下
 * "未刷新/黑块"（板上实测）。整屏失效后 LVGL 每帧重画全部内容，flush 时整帧镜像，
 * 显示端永远是一帧完整画面。 */
static void full_refresh_cb(lv_timer_t *t)
{
    LV_UNUSED(t);
    static int n;
    if (++n >= 60) {
        n = 0;
        uint32_t tasks = 0, px = 0;
        char msg[128];
        gpu_draw_unit_stats(&tasks, &px);
        snprintf(msg, sizeof msg, "GPU-UNIT stat: tasks=%u px=%u frames=%u",
                 (unsigned)tasks, (unsigned)px, (unsigned)g_frames);
        platform_log(msg);
    }
    if (lv_screen_active()) lv_obj_invalidate(lv_screen_active());
}

/* DIRECT 模式：LVGL 直接画进 GUI 帧存，GPU 画它接管的实心矩形；
 * 每帧末尾排干 GPU 队列、**把主帧存镜像到另一个 bank**，再登记 FLIP。
 *
 * ★ 2026-11-01 修闪烁：LCD 的读 bank = GUI_CTRL[1] ^ GPU.flip_toggle，而这里每帧都
 *   FLIP ⇒ 屏幕在两个 bank 之间来回切；但 LVGL 只画 0xBE00_0000 那一块，另一个 bank
 *   是旧内容 ⇒ 看到"新/旧画面交替闪 + 图标消失"（板上实测）。用硬件 BLIT 每帧把可见区
 *   镜像到另一 bank，两边始终一致，翻页就看不出来。
 *
 * ★ 2026-11-03：镜像只搬**本轮 flush 的脏区并集**。整屏 1024x600x2 = 1.2 MB 每帧搬一次
 *   是之前流畅度的大头（GB 窗口每帧只脏 320x288，却能吃掉整屏的带宽）。
 */
static lv_area_t s_dirty;
static bool s_dirty_valid;
static uint32_t s_blit_ms, s_blit_n, s_blit_max;

static void flush_cb_gpu(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map)
{
    (void)px_map;
    if (!s_dirty_valid) {
        s_dirty = *area;
        s_dirty_valid = true;
    } else {
        if (area->x1 < s_dirty.x1) s_dirty.x1 = area->x1;
        if (area->y1 < s_dirty.y1) s_dirty.y1 = area->y1;
        if (area->x2 > s_dirty.x2) s_dirty.x2 = area->x2;
        if (area->y2 > s_dirty.y2) s_dirty.y2 = area->y2;
    }
    if (lv_display_flush_is_last(disp)) {
        (void)gpu_draw_unit_finish_frame();
        uint32_t src = platform_framebuffer_phys();
        if (src && s_dirty_valid) {
            /* ★ bank1 的地址是 **0xBE00_0000 + 8 MiB**：RTL 里 GUI 的 bank 偏移是
             *   32-bit **字地址的 bit21**（`ar_gui = GUI_BASE_WORD + {bank,21'd0}`）⇒
             *   2^21 字 = 8 MiB，不是直觉上的 2 MiB（板上实测：翻到 bank1 显示的是
             *   0xBE80_0000 的内容）。镜像必须打到 0xBE80_0000 + 同一行偏移。 */
            int x = s_dirty.x1, y = s_dirty.y1;
            int w = lv_area_get_width(&s_dirty), h = lv_area_get_height(&s_dirty);
            if (x < 0) { w += x; x = 0; }
            if (y < 0) { h += y; y = 0; }
            if (x + w > UI_SCREEN_W) w = UI_SCREEN_W - x;
            if (y + h > UI_SCREEN_H) h = UI_SCREEN_H - y;
            if (w > 0 && h > 0) {
                uint32_t t0 = platform_time_ms();
                (void)gpu_blit(src, UI_SCREEN_W, 0, x, y, w, h,
                               src + 0x800000u, UI_SCREEN_W, x, y, 0, 0);
                (void)gpu_draw_unit_finish_frame();   /* 镜像落地再翻页 */
                uint32_t dt = platform_time_ms() - t0;
                s_blit_ms += dt;
                if (dt > s_blit_max) s_blit_max = dt;
                s_blit_n++;
            }
        }
        platform_present_full();
        g_frames++;
        s_dirty_valid = false;
    }
    lv_display_flush_ready(disp);
}
#endif

static void keyq_push(ui_key_t k);

static void touch_cb(lv_indev_t *indev, lv_indev_data_t *data)
{
    static bool was_pressed, swiped;
    static int start_x, start_y;
    int x = 0, y = 0;
    bool pressed = false;
    platform_poll_touch(&x, &y, &pressed);

    if (pressed && !was_pressed) {
        start_x = x;
        start_y = y;
        swiped = false;
    }
    if (pressed && !swiped) {
        const char *f = wm_focused_title();
        bool game = f && (!strcmp(f, "Snake") || !strcmp(f, "2048") ||
                          !strcmp(f, "Minesweeper"));
        if (game) {
            int dx = x - start_x;
            int dy = y - start_y;
            int adx = dx < 0 ? -dx : dx;
            int ady = dy < 0 ? -dy : dy;
            if (adx >= 28 || ady >= 28) {
                ui_key_t k = { .ch = 0 };
                if (adx >= ady)
                    k.type = dx > 0 ? UI_KEY_RIGHT : UI_KEY_LEFT;
                else
                    k.type = dy > 0 ? UI_KEY_DOWN : UI_KEY_UP;
                keyq_push(k);
                swiped = true;
            }
        }
    }
    was_pressed = pressed;

    data->point.x = (int32_t)x;
    data->point.y = (int32_t)y;
    data->state = pressed ? LV_INDEV_STATE_PRESSED : LV_INDEV_STATE_RELEASED;
}

static void keyq_push(ui_key_t k)
{
    int next = (g_qt + 1) % 16;
    if (next == g_qh) {
        /* Burst overflow: drop the oldest queued key. */
        g_qh = (g_qh + 1) % 16;
    }
    g_key_q[g_qt] = k;
    g_qt = next;
}

static uint32_t key_to_lv(const ui_key_t *k)
{
    switch (k->type) {
    case UI_KEY_TAB:       return LV_KEY_NEXT;
    case UI_KEY_ENTER:     return LV_KEY_ENTER;
    case UI_KEY_ESC:       return LV_KEY_ESC;
    case UI_KEY_BACKSPACE: return LV_KEY_BACKSPACE;
    case UI_KEY_UP:        return LV_KEY_UP;
    case UI_KEY_DOWN:      return LV_KEY_DOWN;
    case UI_KEY_LEFT:      return LV_KEY_LEFT;
    case UI_KEY_RIGHT:     return LV_KEY_RIGHT;
    default:               return (uint32_t)(unsigned char)k->ch;
    }
}

/* Generate a short press + release for every queued key. LVGL only reports
 * a key press on a RELEASED -> PRESSED transition, so returning one key per
 * read would silently drop all but the first of a burst. */
static void key_read_cb(lv_indev_t *indev, lv_indev_data_t *data)
{
    (void)indev;
    if (g_key_release) {
        g_key_release = false;
        data->state = LV_INDEV_STATE_RELEASED;
        data->continue_reading = (g_qh != g_qt);
        return;
    }
    if (g_qh == g_qt) {
        data->state = LV_INDEV_STATE_RELEASED;
        return;
    }

    ui_key_t k = g_key_q[g_qh];
    g_qh = (g_qh + 1) % 16;
    data->key = key_to_lv(&k);
    data->state = LV_INDEV_STATE_PRESSED;
    g_key_release = true;
    data->continue_reading = true;
}

static void toggle_camera_mode(void)
{
    bool camera = !platform_camera_mode();
    platform_set_camera_mode(camera);
    desktop_camera_mode_changed(camera);
    if (!camera) {
        lv_obj_invalidate(lv_screen_active());
        lv_refr_now(NULL);
    }
}

/* Global shortcuts are consumed before LVGL sees the key. */
static bool ui_global_key(const ui_key_t *k)
{
    const char *focus = wm_focused_title();

    /* Physical KEY4 (evdev KEY_F13). While the embedded Game Boy runs it is
     * the A button (press and release both arrive here); otherwise it is the
     * camera-return key and never enters camera mode. */
    if (k->type == UI_KEY_KEY3) {
        if (gb_embed_running()) {
            gb_embed_key(k->ch ? 1 : 0);
        } else if (k->ch && platform_camera_mode()) {
            desktop_camera_leave();
        }
        return true;
    }

    /* While the terminal is focused every key belongs to the shell, except
     * Ctrl+W which closes the window. This keeps 'c'/'t'/'q' as text. */
    if (focus && !strcmp(focus, "Terminal")) {
        if (k->type == UI_KEY_CTRL_W) {
            terminal_close();
            return true;
        }
        terminal_handle_key(k);
        return true;
    }

    if (k->type == UI_KEY_CTRL_C) {
        /* Outside the terminal, Ctrl+C always stops yshell. */
        g_quit = true;
        return true;
    }
    if (k->type != UI_KEY_CHAR) return false;

    /* Minesweeper uses f/F to flag the cell under the keypad cursor. */
    if ((k->ch == 'f' || k->ch == 'F') && focus &&
        !strcmp(focus, "Minesweeper")) {
        return false;
    }

    switch (k->ch) {
    case 'c':
        if (platform_camera_mode()) desktop_camera_leave();
        else desktop_open_camera();
        return true;
    case 'g': desktop_open_games(); return true;
    case 'f': app_files_open(); return true;
    case 'i': app_system_info_open(); return true;
    case 's': app_settings_open(); return true;
    case 't': terminal_open(); return true;
    case '1': game_2048_open(); return true;
    case '2': game_minesweeper_open(); return true;
    case '3': game_snake_open(); return true;
    case 'q': wm_close_focused(); return true;
    default:  return false;
    }
}

static void pump_ms(uint32_t ms)
{
    uint32_t last = platform_time_ms();
    uint32_t end = last + ms;
    while ((int32_t)(platform_time_ms() - end) < 0) {
        uint32_t now = platform_time_ms();
        lv_tick_inc(now - last);
        last = now;
        lv_timer_handler();
        platform_delay_ms(10);
    }
}

int ui_app_main(int argc, char **argv)
{
    const char *shot = NULL;
    const char *shot_dir = NULL;
    const char *term_test = NULL;
    const char *osk_test = NULL;
    int touch_probe = -1;
    bool demo = false;
    bool no_uart = false;
    bool camera_card = false;
    bool cube3d = false;   /* 开发钩子：启动后直接开 3D 应用（--cube3d） */
    const char *gb_rom = NULL;   /* 开发钩子：启动后直接开内嵌 Game Boy 窗口（--gb <rom>） */
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--screenshot") && i + 1 < argc) shot = argv[++i];
        else if (!strcmp(argv[i], "--screenshots") && i + 1 < argc) shot_dir = argv[++i];
        else if (!strcmp(argv[i], "--terminal-test") && i + 1 < argc) term_test = argv[++i];
        else if (!strcmp(argv[i], "--osk-test") && i + 1 < argc) osk_test = argv[++i];
        else if (!strcmp(argv[i], "--touch-probe") && i + 1 < argc) {
            touch_probe = atoi(argv[++i]);
        }
        else if (!strcmp(argv[i], "--demo")) demo = true;
        else if (!strcmp(argv[i], "--no-uart")) no_uart = true;
        else if (!strcmp(argv[i], "--camera-card")) camera_card = true;
        else if (!strcmp(argv[i], "--cube3d")) cube3d = true;
        else if (!strcmp(argv[i], "--gb") && i + 1 < argc) gb_rom = argv[++i];
    }

    platform_init(UI_SCREEN_W, UI_SCREEN_H);
    /* Boot-to-GUI images leave getty on ttyS0; the GUI must not steal it. */
    if (no_uart) platform_uart_keyboard_disable();
    if (touch_probe > 0) {
        platform_touch_probe(touch_probe);
        app_shutdown();
        return 0;
    }
    platform_present_start();
    platform_touch_service_start();
    lv_init();
    g_disp = lv_display_create(UI_SCREEN_W, UI_SCREEN_H);
    lv_display_set_color_format(g_disp, LV_COLOR_FORMAT_RGB565);
#ifdef YESHEN_GUI_GPU_UNIT
    /* 有可直写帧存 ⇒ DIRECT + GPU 单元；否则退回原来的 PARTIAL 路径 */
    uint16_t *fb = platform_framebuffer();
    if (fb && gpu_init() == 0) {
        lv_display_set_buffers(g_disp, fb, NULL,
                               (uint32_t)UI_SCREEN_W * UI_SCREEN_H * 2,
                               LV_DISPLAY_RENDER_MODE_DIRECT);
        lv_display_set_flush_cb(g_disp, flush_cb_gpu);
        if (gpu_draw_unit_init(fb, UI_SCREEN_W, UI_SCREEN_H,
                               platform_framebuffer_phys()) != 0) {
            platform_log("GPU-UNIT-UNAVAILABLE（继续用 SW 渲染）");
        } else {
            platform_log("GPU-UNIT-ON");
            platform_gui_use_bank1();   /* LCD 固定读 bank1，LVGL 只画 bank0 */
        }
    } else
#endif
    {
        lv_display_set_buffers(g_disp, g_buf1, g_buf2, sizeof(g_buf1),
                               LV_DISPLAY_RENDER_MODE_PARTIAL);
        lv_display_set_flush_cb(g_disp, flush_cb);
    }

    lv_indev_t *indev = lv_indev_create();
    lv_indev_set_type(indev, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(indev, touch_cb);

    g_group = lv_group_create();
    if (g_group) lv_group_set_default(g_group);
    lv_indev_t *keypad = lv_indev_create();
    lv_indev_set_type(keypad, LV_INDEV_TYPE_KEYPAD);
    lv_indev_set_read_cb(keypad, key_read_cb);
    if (g_group) lv_indev_set_group(keypad, g_group);

    ui_theme_init();
    desktop_init();
    if (cube3d) app_cube3d_open();
    if (gb_rom) desktop_open_gb_rom(gb_rom);

#ifdef UI_HOST
    if (term_test) {
        terminal_open();
        pump_ms(1500);
        const char *cmd = "uname -a";
        for (const char *p = cmd; *p; p++) {
            ui_key_t k = { .type = UI_KEY_CHAR, .ch = *p };
            terminal_handle_key(&k);
            pump_ms(30);
        }
        ui_key_t enter = { .type = UI_KEY_ENTER, .ch = 0 };
        terminal_handle_key(&enter);
        pump_ms(2000);
        platform_screenshot(term_test);
        terminal_close();
        pump_ms(100);
        app_shutdown();
        return 0;
    }
    if (osk_test) {
        terminal_open();
        pump_ms(1200);
        if (!terminal_osk_visible()) fprintf(stderr, "OSK not shown on focus\n");
        const char *seq[] = {
            "l", "s", LV_SYMBOL_NEW_LINE,
            "u", "n", "a", "m", "e", LV_SYMBOL_NEW_LINE,
            "s", "l", "e", "e", "p", " ", "1#", "1", "0", "0", "abc",
            LV_SYMBOL_NEW_LINE,
        };
        for (size_t i = 0; i < sizeof(seq) / sizeof(seq[0]); i++) {
            if (!terminal_osk_press(seq[i])) {
                fprintf(stderr, "OSK key missing: %s\n", seq[i]);
            }
            pump_ms(120);
        }
        pump_ms(500);
        if (!terminal_osk_click("Ctrl+C")) fprintf(stderr, "OSK Ctrl+C missing\n");
        pump_ms(1500);
        platform_screenshot(osk_test);
        if (!terminal_osk_click("Hide")) fprintf(stderr, "OSK Hide missing\n");
        pump_ms(300);
        if (terminal_osk_visible()) fprintf(stderr, "OSK hide failed\n");
        terminal_close();
        pump_ms(100);
        app_shutdown();
        return 0;
    }
#else
    (void)term_test;
    (void)osk_test;
#endif

    if (camera_card) desktop_open_camera();
    if (demo || shot_dir) desktop_demo_start(shot_dir);

    uint32_t last = platform_time_ms();
    uint32_t fps_mark = last;
#ifdef YESHEN_GUI_GPU_UNIT
    uint32_t th_ms = 0, th_max = 0;
    uint32_t s_gt_prev = 0, s_gpx_prev = 0;
#endif
    if (shot) {
        /* Single S0 screenshot after a few frames. */
        for (int i = 0; i < 30; i++) {
            uint32_t now = platform_time_ms();
            lv_tick_inc(now - last);
            last = now;
            lv_timer_handler();
            platform_delay_ms(10);
        }
#ifdef UI_HOST
        platform_screenshot(shot);
#else
        (void)shot;
#endif
        app_shutdown();
        return 0;
    }

    while (!g_quit && !platform_should_quit()) {
        ui_key_t k;
        while (!g_quit && platform_poll_key(&k)) {
            if (!ui_global_key(&k)) keyq_push(k);
        }

        uint32_t now = platform_time_ms();
        lv_tick_inc(now - last);
        last = now;
        uint32_t t_lv = platform_time_ms();
        uint32_t next = lv_timer_handler();
#ifdef YESHEN_GUI_GPU_UNIT
        {
            uint32_t th = platform_time_ms() - t_lv;
            th_ms += th;
            if (th > th_max) th_max = th;
        }
#endif
        if ((uint32_t)(now - fps_mark) >= 5000u) {
            /* fps = LVGL flush 次数；lvth = 每轮 lv_timer_handler 的总/峰值毫秒；
             * blit = bank0→bank1 镜像的总/峰值毫秒。三者一起才能把"每帧 53 ms"
             * 拆开归因（模拟 / 合成 / 发布）。 */
#ifdef YESHEN_GUI_GPU_UNIT
            char msg[160];
            uint32_t gt = 0, gpx = 0, dt_t, dt_px;
            gpu_draw_unit_stats(&gt, &gpx);
            dt_t = gt - s_gt_prev;
            dt_px = gpx - s_gpx_prev;
            s_gt_prev = gt;
            s_gpx_prev = gpx;
            snprintf(msg, sizeof(msg),
                     "YGUI-FPS %u lvth=%ums/%umax blit=%ums/%umax blits=%u gt=%u gpx=%u",
                     (unsigned)g_frames, (unsigned)th_ms, (unsigned)th_max,
                     (unsigned)s_blit_ms, (unsigned)s_blit_max, (unsigned)s_blit_n,
                     (unsigned)dt_t, (unsigned)dt_px);
            th_ms = th_max = 0;
            s_blit_ms = s_blit_max = 0;
            s_blit_n = 0;
#else
            char msg[32];
            snprintf(msg, sizeof(msg), "YGUI-FPS %u", (unsigned)g_frames);
#endif
            platform_log(msg);
            g_frames = 0;
            fps_mark = now;
        }
        platform_delay_ms(next < 2 ? 2 : (next > 10 ? 10 : next));
        if (shot_dir && desktop_demo_done()) break;
    }
    platform_log("YGUI-EXIT");
    app_shutdown();
    return 0;
}
