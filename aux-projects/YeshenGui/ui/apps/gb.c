/* Game Boy (Peanut-GB) rendered into an LVGL canvas inside a normal yshell
 * window. The emulator core runs on the LVGL timer thread; there is no
 * separate process and no full-screen frame-buffer hand-off, so the GUI keeps
 * owning the display. */

#include "apps.h"
#include "gb.h"

#include "platform.h"
#include "gpu.h"          /* gpu_arena_alloc()：arena 里零拷贝画布（-Wimplicit-function-declaration） */
#include "wm.h"

#ifdef YESHEN_GUI_GPU_UNIT
#include "gpu_draw_unit.h"
#endif

#include "lvgl.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ENABLE_LCD 1
#define ENABLE_SOUND 0
#include "peanut_gb.h"

#define GB_W 160
#define GB_H 144
/* 3x: 480x432 canvas (414 KiB). The canvas lives in the GPU arena and is
 * bound to the draw unit by physical address, so the emulator writes DDR once
 * and the GPU blits from there — no per-frame copy. The row is expanded in
 * cached RAM first, because the arena is uncached and 16-bit per-pixel stores
 * would double the bus cost. */
#define GB_SCALE 3
#define CANVAS_W (GB_W * GB_SCALE)
#define CANVAS_H (GB_H * GB_SCALE)
/* The app loop sleeps min(next_timer, 10) ms after every iteration and
 * LVGL stamps last_run when the callback returns, so a 16 ms period costs
 * ~10 ms of sleep per emulated frame. Keep the period short: each tick still
 * runs exactly one frame, and the loop's 2 ms floor takes over. */
#define GB_TICK_MS 2
#define GB_FRAME_MS 33   /* frame pacing cap: 30 fps */

static uint8_t *s_rom;
static size_t s_rom_len;
static uint8_t s_cart_ram[0x8000];
static struct gb_s s_gb;
static uint16_t *s_pixels; /* CANVAS_W * CANVAS_H, RGB565 canvas buffer */
static uint32_t s_pixels_phys; /* non-zero: canvas lives in the GPU arena */
static uint16_t *s_arena_px;   /* one-time arena allocation, reused */
static uint32_t s_arena_phys;
static lv_obj_t *s_canvas;
static lv_timer_t *s_timer;
static uint8_t s_touch_pad = 0xFF; /* on-screen gamepad */
static uint8_t s_key_pad = 0xFF;   /* KEY4 (A) */
static uint32_t s_frames;
static uint32_t s_lines;
static uint32_t s_core_ms;
static uint32_t s_touch_ms;
static uint32_t s_max_ms;
static uint32_t s_win_t0;
static uint32_t s_due_ms;   /* next frame is due at this time (60 fps cap) */
static bool s_running;

/* DMG green ramp: the same four shades gbplay used. */
static const uint16_t k_pal[4] = { 0x9FE0, 0x5B60, 0x2A60, 0x0000 };

static uint8_t rom_read(struct gb_s *g, const uint_fast32_t a)
{
    (void)g;
    return (a < s_rom_len) ? s_rom[a] : 0xFF;
}

static uint8_t ram_read(struct gb_s *g, const uint_fast32_t a)
{
    (void)g;
    return s_cart_ram[a & 0x7FFF];
}

static void ram_write(struct gb_s *g, const uint_fast32_t a, const uint8_t v)
{
    (void)g;
    s_cart_ram[a & 0x7FFF] = v;
}

static void gb_err(struct gb_s *g, const enum gb_error_e e, const uint16_t v)
{
    (void)g;
    (void)e;
    (void)v;
    platform_log("gb: core error");
}

/* One emulated LCD line -> GB_SCALE screen rows (nearest neighbour).
 * The row is expanded once in cached RAM, then written with 32-bit stores:
 * the canvas may sit in the GPU arena, which is uncached mmap(/dev/mem). */
static void lcd_line(struct gb_s *g, const uint8_t *pixels, const uint_fast8_t line)
{
    (void)g;
    if (line >= GB_H) return;
    s_lines++;

    if (!s_pixels) return;
    static uint16_t row[CANVAS_W] __attribute__((aligned(4)));
    for (int x = 0; x < GB_W; x++) {
        uint16_t c = k_pal[pixels[x] & 3];
        for (int s = 0; s < GB_SCALE; s++) row[GB_SCALE * x + s] = c;
    }
    uint16_t *dst = s_pixels + (size_t)line * GB_SCALE * CANVAS_W;
    for (int d = 0; d < GB_SCALE; d++, dst += CANVAS_W) {
        if (((uintptr_t)dst & 3u) == 0u) {
            const uint32_t *s32 = (const uint32_t *)row;
            uint32_t *d32 = (uint32_t *)dst;
            for (int i = 0; i < CANVAS_W / 2; i++) d32[i] = s32[i];
        } else {
            memcpy(dst, row, sizeof row);
        }
    }
}

/* ---- on-screen gamepad ---------------------------------------------------
 * One finger is reported at a time, so the D-pad is a single widget whose
 * direction follows the touch position (drag inside it to change direction)
 * and the action buttons are separate. KEY4 doubles as A, which is what makes
 * "hold a direction + press A" possible. */

#define DPAD_SIZE 132
#define DIRS (JOYPAD_UP | JOYPAD_DOWN | JOYPAD_LEFT | JOYPAD_RIGHT)

static void hold_cb(lv_event_t *e)
{
    uint8_t bit = (uint8_t)(uintptr_t)lv_event_get_user_data(e);
    lv_event_code_t c = lv_event_get_code(e);
    if (c == LV_EVENT_PRESSED) s_touch_pad &= (uint8_t)~bit;
    else if (c == LV_EVENT_RELEASED || c == LV_EVENT_PRESS_LOST) s_touch_pad |= bit;
}

static void dpad_cb(lv_event_t *e)
{
    lv_event_code_t c = lv_event_get_code(e);
    if (c == LV_EVENT_RELEASED || c == LV_EVENT_PRESS_LOST) {
        s_touch_pad |= DIRS;
        return;
    }
    lv_indev_t *indev = lv_indev_active();
    if (!indev) return;
    lv_point_t pt;
    lv_indev_get_point(indev, &pt);
    lv_obj_t *o = lv_event_get_current_target(e);
    lv_area_t a;
    lv_obj_get_coords(o, &a);
    int dx = pt.x - (a.x1 + a.x2) / 2;
    int dy = pt.y - (a.y1 + a.y2) / 2;
    int ady = dy < 0 ? -dy : dy;
    int adx = dx < 0 ? -dx : dx;
    int dead = (a.x2 - a.x1) / 8;

    s_touch_pad |= DIRS;
    if (adx < dead && ady < dead) return;          /* centre: no direction */
    if (adx >= ady) s_touch_pad &= (uint8_t)~(dx < 0 ? JOYPAD_LEFT : JOYPAD_RIGHT);
    else            s_touch_pad &= (uint8_t)~(dy < 0 ? JOYPAD_UP : JOYPAD_DOWN);
}

static lv_obj_t *make_pad_button(lv_obj_t *parent, int x, int y, int w, int h,
                                 const char *label, uint8_t bit, bool round)
{
    lv_obj_t *b = lv_button_create(parent);
    lv_obj_set_pos(b, x, y);
    lv_obj_set_size(b, w, h);
    lv_obj_set_style_bg_color(b, lv_color_hex(0x39485A), 0);
    lv_obj_set_style_bg_color(b, lv_color_hex(0x6E5AA8), LV_STATE_PRESSED);
    lv_obj_set_style_border_width(b, 0, 0);
    lv_obj_set_style_radius(b, round ? LV_RADIUS_CIRCLE : 10, 0);
    lv_obj_t *l = lv_label_create(b);
    lv_label_set_text(l, label);
    lv_obj_set_style_text_font(l, &lv_font_montserrat_20, 0);
    lv_obj_set_style_text_color(l, lv_color_white(), 0);
    lv_obj_center(l);
    lv_obj_add_event_cb(b, hold_cb, LV_EVENT_PRESSED, (void *)(uintptr_t)bit);
    lv_obj_add_event_cb(b, hold_cb, LV_EVENT_RELEASED, (void *)(uintptr_t)bit);
    lv_obj_add_event_cb(b, hold_cb, LV_EVENT_PRESS_LOST, (void *)(uintptr_t)bit);
    return b;
}

static void make_dpad(lv_obj_t *parent, int x, int y)
{
    lv_obj_t *pad = lv_obj_create(parent);
    lv_obj_set_pos(pad, x, y);
    lv_obj_set_size(pad, DPAD_SIZE, DPAD_SIZE);
    lv_obj_set_style_bg_opa(pad, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(pad, 0, 0);
    lv_obj_set_style_pad_all(pad, 0, 0);
    lv_obj_remove_flag(pad, LV_OBJ_FLAG_SCROLLABLE);

    /* Cross drawn from two bars plus the four arrow labels. */
    int arm = DPAD_SIZE / 3;
    lv_obj_t *v = lv_obj_create(pad);
    lv_obj_set_pos(v, arm, 0);
    lv_obj_set_size(v, arm, DPAD_SIZE);
    lv_obj_t *h = lv_obj_create(pad);
    lv_obj_set_pos(h, 0, arm);
    lv_obj_set_size(h, DPAD_SIZE, arm);
    for (int i = 0; i < 2; i++) {
        lv_obj_t *bar = i ? h : v;
        lv_obj_set_style_bg_color(bar, lv_color_hex(0x39485A), 0);
        lv_obj_set_style_bg_opa(bar, LV_OPA_COVER, 0);
        lv_obj_set_style_border_width(bar, 0, 0);
        lv_obj_set_style_radius(bar, 6, 0);
        lv_obj_set_style_pad_all(bar, 0, 0);
        lv_obj_remove_flag(bar, LV_OBJ_FLAG_SCROLLABLE);
        lv_obj_remove_flag(bar, LV_OBJ_FLAG_CLICKABLE);
    }
    /* Align each arrow to its own spoke: absolute positions drift because the
     * four glyphs do not share a width. */
    static const char *sym[4] = { LV_SYMBOL_UP, LV_SYMBOL_DOWN, LV_SYMBOL_LEFT, LV_SYMBOL_RIGHT };
    static const lv_align_t al[4] = { LV_ALIGN_TOP_MID, LV_ALIGN_BOTTOM_MID,
                                      LV_ALIGN_LEFT_MID, LV_ALIGN_RIGHT_MID };
    static const int ox[4] = { 0, 0, 3, -3 };
    static const int oy[4] = { 3, -3, 0, 0 };
    for (int i = 0; i < 4; i++) {
        lv_obj_t *l = lv_label_create(pad);
        lv_label_set_text(l, sym[i]);
        lv_obj_set_style_text_font(l, &lv_font_montserrat_20, 0);
        lv_obj_set_style_text_color(l, lv_color_white(), 0);
        lv_obj_align(l, al[i], ox[i], oy[i]);
        lv_obj_remove_flag(l, LV_OBJ_FLAG_CLICKABLE);
    }

    lv_obj_add_flag(pad, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(pad, dpad_cb, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(pad, dpad_cb, LV_EVENT_PRESSING, NULL);
    lv_obj_add_event_cb(pad, dpad_cb, LV_EVENT_RELEASED, NULL);
    lv_obj_add_event_cb(pad, dpad_cb, LV_EVENT_PRESS_LOST, NULL);
}

static void tick_cb(lv_timer_t *t)
{
    (void)t;
    if (!s_running) return;
    /* 30 fps cap: the core cannot sustain 60 Hz here, and running flat out
     * starves the rest of the system (ssh, touch, LVGL). */
    uint32_t now_ms = platform_time_ms();
    if ((int32_t)(now_ms - s_due_ms) < 0) return;
    s_due_ms += GB_FRAME_MS;
    if ((int32_t)(now_ms - s_due_ms) > (int32_t)(2 * GB_FRAME_MS)) s_due_ms = now_ms + GB_FRAME_MS;
    uint8_t pad = (uint8_t)(s_touch_pad & s_key_pad);
    /* Dev hook: GB_AUTOSTART=<frame> holds START for a few frames so the
     * title screen can be left without a touch (framerate measurements). */
    static long auto_start = -1;
    static bool auto_env;
    if (!auto_env) {
        const char *v = getenv("GB_AUTOSTART");
        auto_start = v ? strtol(v, NULL, 10) : -1;
        auto_env = true;
    }
    if (auto_start >= 0 && (long)s_frames >= auto_start && (long)s_frames < auto_start + 30)
        pad &= (uint8_t)~JOYPAD_START;
    s_gb.direct.joypad = pad;
    uint32_t t0 = platform_time_ms();
    gb_run_frame(&s_gb);
    uint32_t dt = platform_time_ms() - t0;
    s_core_ms += dt;
    if (dt > s_max_ms) s_max_ms = dt;
    s_frames++;
#ifdef YESHEN_GUI_GPU_UNIT
    if (!s_pixels_phys) {
        /* Cached fallback: the draw unit caches its source by descriptor, so
         * push the new pixels before LVGL picks the image up. The arena path
         * needs no push — the emulator wrote straight into the bound buffer. */
        uint32_t t_touch = platform_time_ms();
        gpu_draw_unit_touch(lv_canvas_get_image(s_canvas));
        s_touch_ms += platform_time_ms() - t_touch;
    }
#endif
    lv_obj_invalidate(s_canvas);
    if ((s_frames % 600u) == 0u) {
        char msg[128];
        snprintf(msg, sizeof msg,
                 "gb: frames=%u core=%ums/600 max=%ums touch=%ums wall=%ums",
                 (unsigned)s_frames, (unsigned)s_core_ms, (unsigned)s_max_ms,
                 (unsigned)s_touch_ms,
                 (unsigned)(platform_time_ms() - s_win_t0));
        platform_log(msg);
        s_core_ms = 0;
        s_max_ms = 0;
        s_touch_ms = 0;
        s_win_t0 = platform_time_ms();
    }
}

void gb_embed_close(void)
{
    if (s_timer) {
        lv_timer_delete(s_timer);
        s_timer = NULL;
    }
    s_running = false;
    if (s_canvas) {
        lv_obj_delete(s_canvas);
        s_canvas = NULL;
    }
    if (s_pixels && !s_pixels_phys) free(s_pixels);   /* arena memory has no free */
    s_pixels = NULL;
    s_pixels_phys = 0;
    free(s_rom);
    s_rom = NULL;
    s_rom_len = 0;
    s_touch_pad = 0xFF;
    s_key_pad = 0xFF;
}

void gb_embed_key(int pressed)
{
    if (!s_running) return;
    if (pressed) s_key_pad &= (uint8_t)~JOYPAD_A;
    else s_key_pad |= JOYPAD_A;
}

bool gb_embed_running(void) { return s_running; }
uint32_t gb_embed_frames(void) { return s_frames; }

void gb_embed_open(lv_obj_t *parent, const char *rom_path)
{
    gb_embed_close();

    FILE *f = fopen(rom_path, "rb");
    if (!f) {
        platform_log("gb: cannot open rom");
        return;
    }
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len <= 0 || len > 8 * 1024 * 1024) {
        fclose(f);
        platform_log("gb: bad rom size");
        return;
    }
    s_rom = malloc((size_t)len);
    if (!s_rom || fread(s_rom, 1, (size_t)len, f) != (size_t)len) {
        fclose(f);
        gb_embed_close();
        platform_log("gb: rom read failed");
        return;
    }
    fclose(f);
    s_rom_len = (size_t)len;

    if (gb_init(&s_gb, rom_read, ram_read, ram_write, gb_err, NULL) != GB_INIT_NO_ERROR) {
        gb_embed_close();
        platform_log("gb: init failed");
        return;
    }
    gb_init_lcd(&s_gb, lcd_line);
    gb_reset(&s_gb);
    s_gb.direct.joypad = 0xFF;

    /* Canvas outside LVGL's pool (480x432x2 = 414 KiB). Prefer the GPU arena:
     * it has a physical address, so the draw unit blits from it with no copy.
     * The arena is bump-allocated with no free(), so the buffer is allocated
     * once and reused across opens. Fallback: cached heap + per-frame push. */
    s_pixels = NULL;
    s_pixels_phys = 0;
#ifdef YESHEN_GUI_GPU_UNIT
    if (!s_arena_px)
        s_arena_px = (uint16_t *)gpu_arena_alloc((size_t)CANVAS_W * CANVAS_H * sizeof(uint16_t),
                                                 &s_arena_phys);
    s_pixels = s_arena_px;
    s_pixels_phys = s_arena_phys;
#endif
    if (!s_pixels) {
        s_pixels_phys = 0;
        s_pixels = calloc((size_t)CANVAS_W * CANVAS_H, sizeof(uint16_t));
    }
    if (!s_pixels) {
        gb_embed_close();
        platform_log("gb: no memory for canvas");
        return;
    }

    s_canvas = lv_canvas_create(parent);
    lv_canvas_set_buffer(s_canvas, s_pixels, CANVAS_W, CANVAS_H,
                         LV_COLOR_FORMAT_RGB565);
#ifdef YESHEN_GUI_GPU_UNIT
    if (s_pixels_phys)
        gpu_draw_unit_bind_image(lv_canvas_get_image(s_canvas), s_pixels_phys, CANVAS_W);
#endif
    lv_obj_center(s_canvas);
    /* The 3x canvas sits flush with the content area, so LVGL thinks the
     * window can scroll and paints a scrollbar under the game — a drag on the
     * screen would pan the whole window. A game window never scrolls. */
    lv_obj_remove_flag(parent, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scrollbar_mode(parent, LV_SCROLLBAR_MODE_OFF);
    {
        lv_obj_t *pw = lv_obj_get_parent(parent);
        if (pw) {
            lv_obj_remove_flag(pw, LV_OBJ_FLAG_SCROLLABLE);
            lv_obj_set_scrollbar_mode(pw, LV_SCROLLBAR_MODE_OFF);
        }
    }

    /* Visible gamepad beside the screen: D-pad left, A/B + Select/Start right. */
    lv_obj_update_layout(parent);
    make_dpad(parent, 14, 160);
    make_pad_button(parent, 664, 80, 64, 64, "A", JOYPAD_A, true);
    make_pad_button(parent, 736, 160, 64, 64, "B", JOYPAD_B, true);
    make_pad_button(parent, 668, 300, 120, 40, "SELECT", JOYPAD_SELECT, false);
    make_pad_button(parent, 668, 356, 120, 40, "START", JOYPAD_START, false);
    lv_obj_t *hint = lv_label_create(parent);
    lv_label_set_text(hint, "KEY4 = A");
    lv_obj_set_style_text_color(hint, lv_color_hex(0x39485A), 0);
    lv_obj_set_pos(hint, 668, 410);

    s_touch_pad = 0xFF;
    s_key_pad = 0xFF;
    s_frames = 0;
    s_lines = 0;
    s_core_ms = 0;
    s_touch_ms = 0;
    s_max_ms = 0;
    s_win_t0 = platform_time_ms();
    s_due_ms = platform_time_ms() + GB_FRAME_MS;
    s_running = true;
    s_timer = lv_timer_create(tick_cb, GB_TICK_MS, NULL);
#ifdef YESHEN_GUI_GPU_UNIT
    platform_log(s_pixels_phys ? "gb: canvas in GPU arena (zero-copy)"
                               : "gb: canvas in heap (per-frame push)");
#else
    platform_log("gb: rom loaded (canvas)");
#endif
}
