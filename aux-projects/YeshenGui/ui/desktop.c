/* mkdir(), sysconf() and localtime_r() are POSIX; ask glibc for them even
 * though CMake compiles with -std=c11. */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include "desktop.h"

#include "apps/apps.h"
#include "apps/gb.h"
#include "assets.h"
#include "platform.h"
#include "theme.h"
#include "wm.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#ifndef UI_HOST
#include <fcntl.h>
#include <signal.h>
#include <sys/wait.h>
#endif
#include <dirent.h>

#define SCREEN_W       1024
#define SCREEN_H       600
#define DESKTOP_Y      40
#define DESKTOP_H      524
#define PANEL_H        40
#define TASKBAR_Y      (SCREEN_H - TASKBAR_H)
#define TASKBAR_H      36
#define MENU_W         320
#define TILE_SIZE      96
#define TILE_STEP      112
#define ICON_MARGIN    24
#define ICON_ROWS      3
#define DEMO_PERIOD_MS 1200

#define GAMES_W        900
#define GAMES_H        460
#define GAME_CARD_W    280
#define GAME_CARD_H    140
#define GAME_CARD_GAP  12

/* Colour blocks for the desktop tiles (spec 7.5). */
#define ICON_COLOR_FILES    0x2F6FD0u /* folder, blue */
#define ICON_COLOR_SYSTEM   0x5A6B7Bu /* chip, grey */
#define ICON_COLOR_GAMES    0xA80030u /* gamepad, red */
#define ICON_COLOR_SETTINGS 0x4A5B6Eu /* gear, grey-blue */
#define ICON_COLOR_CAMERA   0x2E7D32u /* camera, green */
#define ICON_COLOR_TERMINAL 0x111827u /* terminal, near-black */

typedef struct {
    const char *title;
    const char *symbol;
    uint32_t color;
} desktop_icon_t;

static const desktop_icon_t s_icons[] = {
    { "Files",    LV_SYMBOL_DIRECTORY, ICON_COLOR_FILES    },
    { "System",   LV_SYMBOL_DRIVE,     ICON_COLOR_SYSTEM   },
    { "Games",    LV_SYMBOL_PLAY,      ICON_COLOR_GAMES    },
    { "Settings", LV_SYMBOL_SETTINGS,  ICON_COLOR_SETTINGS },
    { "Camera",   LV_SYMBOL_VIDEO,     ICON_COLOR_CAMERA   },
    { "3D",       LV_SYMBOL_IMAGE,     0x7C3AEDu          },
    { "Terminal", LV_SYMBOL_KEYBOARD,  ICON_COLOR_TERMINAL },
};

#define ICON_COUNT ((int)(sizeof(s_icons) / sizeof(s_icons[0])))

static lv_obj_t *s_root;
static lv_obj_t *s_wall_layer;
static lv_obj_t *s_icon_layer;
static lv_obj_t *s_window_layer;
static lv_obj_t *s_panel;
static lv_obj_t *s_taskbar;
static lv_obj_t *s_menu;
static lv_obj_t *s_menu_backdrop;
static lv_obj_t *s_wall_img;
static lv_obj_t *s_cpu_label;
static lv_obj_t *s_mem_label;
static lv_obj_t *s_clock_label;
static lv_obj_t *s_icon_labels[ICON_COUNT];
static lv_timer_t *s_tick_timer;
static lv_timer_t *s_demo_timer;
static lv_obj_t *s_hot;
static lv_timer_t *s_hot_timer;
static bool s_hot_pressed;
static uint32_t s_hot_ms;
static bool s_camera_mode;
static ui_window_t *s_games_win;
static ui_wallpaper_t s_wall;
static bool s_wall_loaded;
static char s_shot_dir[320];
static int s_demo_step;
static bool s_demo_done;

static void menu_toggle_cb(lv_event_t *e);
static void menu_item_cb(lv_event_t *e);
static void menu_backdrop_cb(lv_event_t *e);
static void icon_event_cb(lv_event_t *e);
static void quick_event_cb(lv_event_t *e);
static void show_desktop_cb(lv_event_t *e);
static void clock_timer_cb(lv_timer_t *t);
static void demo_timer_cb(lv_timer_t *t);
static void update_status(void);
static bool demo_screenshot(const char *name);
static void open_app(const char *title);
static void open_info_card(const char *title, const char *body);
static void open_camera_card(void);
static void style_cam_button(lv_obj_t *btn, bool active);
static void camera_detect_cb(lv_event_t *e);
static void camera_plain_cb(lv_event_t *e);
static void camera_src_cb(lv_event_t *e);
static void camera_source_load(void);
static void games_close_cb(ui_window_t *win);
static void games_card_cb(lv_event_t *e);
static void gb_close_cb(ui_window_t *win);
static void gb_rom_cb(lv_event_t *e);

/* ------------------------------------------------------------------ */
/* Small helpers                                                       */
/* ------------------------------------------------------------------ */

static lv_obj_t *create_layer(lv_obj_t *parent, int x, int y, int w, int h)
{
    lv_obj_t *o = lv_obj_create(parent);
    lv_obj_set_pos(o, x, y);
    lv_obj_set_size(o, w, h);
    lv_obj_set_style_bg_opa(o, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(o, 0, 0);
    lv_obj_set_style_radius(o, 0, 0);
    lv_obj_set_style_pad_all(o, 0, 0);
    lv_obj_set_scrollbar_mode(o, LV_SCROLLBAR_MODE_OFF);
    lv_obj_remove_flag(o, LV_OBJ_FLAG_SCROLLABLE);
    return o;
}

static void make_button_flat(lv_obj_t *btn, lv_color_t bg, lv_color_t border,
                             bool transparent)
{
    lv_obj_set_style_bg_color(btn, bg, 0);
    lv_obj_set_style_bg_opa(btn, transparent ? LV_OPA_TRANSP : LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(btn, transparent ? 0 : 1, 0);
    lv_obj_set_style_border_color(btn, border, 0);
    lv_obj_set_style_radius(btn, 6, 0);
    lv_obj_set_style_pad_all(btn, 0, 0);
    lv_obj_set_style_shadow_width(btn, 0, 0);
}

static void add_pressed_feedback(lv_obj_t *btn)
{
    lv_obj_set_style_bg_color(btn, ui_theme_colors()->accent, LV_STATE_PRESSED);
    lv_obj_set_style_bg_opa(btn, LV_OPA_30, LV_STATE_PRESSED);
}

static lv_color_t icon_label_color(void)
{
    /* Icon tiles sit on the wallpaper: ink wallpaper needs light labels,
     * while the paper wallpaper needs dark labels in both themes. */
    if (ui_theme_wallpaper() == 0) return lv_color_white();
    return lv_color_hex(0x1F2933);
}

static void update_icon_label_colors(void)
{
    lv_color_t color = icon_label_color();
    for (int i = 0; i < ICON_COUNT; i++) {
        if (s_icon_labels[i]) {
            lv_obj_set_style_text_color(s_icon_labels[i], color, 0);
        }
    }
}

/* ------------------------------------------------------------------ */
/* Wallpaper                                                           */
/* ------------------------------------------------------------------ */

static bool load_wallpaper(void)
{
    const char *name = ui_theme_wallpaper() ? "wallpaper_paper" : "wallpaper_ink";
    ui_wallpaper_t next;

    if (!ui_wallpaper_load(&next, name)) {
        platform_log("desktop: wallpaper unavailable, using solid background");
        if (s_wall_layer) {
            lv_obj_set_style_bg_color(s_wall_layer, ui_theme_colors()->bg, 0);
            lv_obj_set_style_bg_opa(s_wall_layer, LV_OPA_COVER, 0);
        }
        return false;
    }

    if (s_wall_img) {
        lv_obj_delete(s_wall_img);
        s_wall_img = NULL;
    }
    if (s_wall_loaded) {
        lv_image_cache_drop(&s_wall.dsc);
        ui_wallpaper_free(&s_wall);
    }
    s_wall = next;
    s_wall_loaded = true;

    s_wall_img = lv_image_create(s_wall_layer);
    lv_image_set_src(s_wall_img, &s_wall.dsc);
    lv_obj_set_pos(s_wall_img, 0, 0);
    lv_obj_set_style_bg_opa(s_wall_layer, LV_OPA_TRANSP, 0);
    return true;
}

/* ------------------------------------------------------------------ */
/* Layers                                                              */
/* ------------------------------------------------------------------ */

static void build_wallpaper_layer(void)
{
    s_wall_layer = create_layer(s_root, 0, 0, SCREEN_W, SCREEN_H);
    lv_obj_remove_flag(s_wall_layer, LV_OBJ_FLAG_CLICKABLE);
    load_wallpaper();
}

static void build_icon_tile(int index)
{
    const desktop_icon_t *def = &s_icons[index];
    int col = index / ICON_ROWS;
    int row = index % ICON_ROWS;
    int x = ICON_MARGIN + col * TILE_STEP;
    int y = ICON_MARGIN + row * TILE_STEP;

    lv_obj_t *tile = lv_button_create(s_icon_layer);
    lv_obj_set_pos(tile, x, y);
    lv_obj_set_size(tile, TILE_SIZE, TILE_SIZE);
    make_button_flat(tile, ui_theme_colors()->accent, ui_theme_colors()->border,
                     true);
    lv_obj_set_style_radius(tile, 8, 0);
    add_pressed_feedback(tile);
    lv_obj_add_event_cb(tile, icon_event_cb, LV_EVENT_CLICKED, (void *)def->title);

    lv_obj_t *square = lv_obj_create(tile);
    lv_obj_set_size(square, 56, 56);
    lv_obj_align(square, LV_ALIGN_TOP_MID, 0, 6);
    lv_obj_set_style_bg_color(square, lv_color_hex(def->color), 0);
    lv_obj_set_style_bg_opa(square, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(square, 0, 0);
    lv_obj_set_style_radius(square, 12, 0);
    lv_obj_set_style_pad_all(square, 0, 0);
    lv_obj_remove_flag(square, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_remove_flag(square, LV_OBJ_FLAG_CLICKABLE);

    lv_obj_t *glyph = lv_label_create(square);
    lv_label_set_text(glyph, def->symbol);
    lv_obj_set_style_text_font(glyph, &lv_font_montserrat_24, 0);
    lv_obj_set_style_text_color(glyph, lv_color_white(), 0);
    lv_obj_center(glyph);

    lv_obj_t *name = lv_label_create(tile);
    lv_label_set_text(name, def->title);
    lv_obj_set_style_text_font(name, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(name, icon_label_color(), 0);
    lv_obj_align(name, LV_ALIGN_BOTTOM_MID, 0, -2);
    s_icon_labels[index] = name;
}

static void build_icon_layer(void)
{
    s_icon_layer = create_layer(s_root, 0, DESKTOP_Y, SCREEN_W, DESKTOP_H);
    lv_obj_remove_flag(s_icon_layer, LV_OBJ_FLAG_CLICKABLE);
    for (int i = 0; i < ICON_COUNT; i++) build_icon_tile(i);
}

static void build_window_layer(void)
{
    s_window_layer = create_layer(s_root, 0, DESKTOP_Y, SCREEN_W, DESKTOP_H);
    /* Empty desktop clicks must fall through to the icon layer. */
    lv_obj_remove_flag(s_window_layer, LV_OBJ_FLAG_CLICKABLE);
}

/* ------------------------------------------------------------------ */
/* Applications menu                                                   */
/* ------------------------------------------------------------------ */

static void menu_set_visible(bool visible)
{
    if (s_menu) {
        if (visible) lv_obj_remove_flag(s_menu, LV_OBJ_FLAG_HIDDEN);
        else lv_obj_add_flag(s_menu, LV_OBJ_FLAG_HIDDEN);
    }
    if (s_menu_backdrop) {
        if (visible) lv_obj_remove_flag(s_menu_backdrop, LV_OBJ_FLAG_HIDDEN);
        else lv_obj_add_flag(s_menu_backdrop, LV_OBJ_FLAG_HIDDEN);
    }
}

/* Transparent click-catcher over the desktop area. It starts at y=40 so the
 * top panel (and its Applications button) stays reachable, and it is created
 * before the menu so the menu is drawn and hit-tested on top. */
static void build_menu_backdrop(void)
{
    s_menu_backdrop = create_layer(s_root, 0, DESKTOP_Y, SCREEN_W,
                                   SCREEN_H - DESKTOP_Y);
    lv_obj_add_flag(s_menu_backdrop, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(s_menu_backdrop, menu_backdrop_cb, LV_EVENT_CLICKED,
                        NULL);
    lv_obj_add_flag(s_menu_backdrop, LV_OBJ_FLAG_HIDDEN);
}

static void add_menu_group(const char *text)
{
    lv_obj_t *l = lv_label_create(s_menu);
    lv_label_set_text(l, text);
    lv_obj_set_width(l, LV_PCT(100));
    lv_obj_set_style_text_font(l, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(l, ui_theme_colors()->accent, 0);
    lv_obj_set_style_pad_left(l, 4, 0);
    lv_obj_set_style_pad_top(l, 6, 0);
}

static void add_menu_item(const char *symbol, const char *name, const char *title)
{
    char text[64];
    snprintf(text, sizeof(text), "%s  %s", symbol, name);

    lv_obj_t *btn = lv_button_create(s_menu);
    lv_obj_set_size(btn, LV_PCT(100), 56);
    make_button_flat(btn, ui_theme_colors()->accent, ui_theme_colors()->border,
                     true);
    add_pressed_feedback(btn);
    lv_obj_add_event_cb(btn, menu_item_cb, LV_EVENT_CLICKED, (void *)title);

    lv_obj_t *l = lv_label_create(btn);
    lv_label_set_text(l, text);
    lv_obj_set_style_text_font(l, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(l, ui_theme_colors()->text, 0);
    lv_obj_align(l, LV_ALIGN_LEFT_MID, 14, 0);
}

static void build_menu(void)
{
    build_menu_backdrop();

    s_menu = lv_obj_create(s_root);
    lv_obj_set_pos(s_menu, 0, DESKTOP_Y);
    lv_obj_set_size(s_menu, MENU_W, DESKTOP_H);
    lv_obj_set_style_bg_color(s_menu, ui_theme_colors()->window, 0);
    lv_obj_set_style_bg_opa(s_menu, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(s_menu, 1, 0);
    lv_obj_set_style_border_color(s_menu, ui_theme_colors()->border, 0);
    lv_obj_set_style_radius(s_menu, 0, 0);
    lv_obj_set_style_pad_all(s_menu, 8, 0);
    lv_obj_set_style_pad_row(s_menu, 2, 0);
    lv_obj_set_scrollbar_mode(s_menu, LV_SCROLLBAR_MODE_OFF);
    lv_obj_remove_flag(s_menu, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_flex_flow(s_menu, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(s_menu, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START,
                          LV_FLEX_ALIGN_CENTER);
    lv_obj_add_flag(s_menu, LV_OBJ_FLAG_HIDDEN);

    lv_obj_t *header = lv_label_create(s_menu);
    lv_label_set_text(header, "Applications");
    lv_obj_set_width(header, LV_PCT(100));
    lv_obj_set_style_text_font(header, &lv_font_montserrat_20, 0);
    lv_obj_set_style_text_color(header, ui_theme_colors()->text, 0);
    lv_obj_set_style_pad_left(header, 4, 0);

    add_menu_group("Games");
    add_menu_item(LV_SYMBOL_PLAY, "2048", "2048");
    add_menu_item(LV_SYMBOL_WARNING, "Minesweeper", "Minesweeper");
    add_menu_item(LV_SYMBOL_LOOP, "Snake", "Snake");

    add_menu_group("Accessories");
    add_menu_item(LV_SYMBOL_KEYBOARD, "Terminal", "Terminal");
    add_menu_item(LV_SYMBOL_DIRECTORY, "Files", "Files");
    add_menu_item(LV_SYMBOL_VIDEO, "Camera", "Camera");

    add_menu_group("System");
    add_menu_item(LV_SYMBOL_LIST, "System Info", "System Info");
    add_menu_item(LV_SYMBOL_SETTINGS, "Settings", "Settings");
}

/* ------------------------------------------------------------------ */
/* Top panel                                                           */
/* ------------------------------------------------------------------ */

static void add_quick_button(const char *symbol, const char *name)
{
    char text[48];
    snprintf(text, sizeof(text), "%s %s", symbol, name);

    lv_obj_t *btn = lv_button_create(s_panel);
    lv_obj_set_size(btn, 100, 32);
    make_button_flat(btn, ui_theme_colors()->panel, ui_theme_colors()->border,
                     true);
    lv_obj_add_event_cb(btn, quick_event_cb, LV_EVENT_CLICKED, (void *)name);

    lv_obj_t *l = lv_label_create(btn);
    lv_label_set_text(l, text);
    lv_obj_set_style_text_font(l, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(l, ui_theme_colors()->panel_text, 0);
    lv_obj_center(l);
}

static void build_panel(void)
{
    s_panel = lv_obj_create(s_root);
    lv_obj_set_pos(s_panel, 0, 0);
    lv_obj_set_size(s_panel, SCREEN_W, PANEL_H);
    lv_obj_set_style_bg_color(s_panel, ui_theme_colors()->panel, 0);
    lv_obj_set_style_bg_opa(s_panel, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(s_panel, 2, 0);
    lv_obj_set_style_border_color(s_panel, ui_theme_colors()->accent, 0);
    lv_obj_set_style_border_side(s_panel, LV_BORDER_SIDE_BOTTOM, 0);
    lv_obj_set_style_radius(s_panel, 0, 0);
    lv_obj_set_style_pad_all(s_panel, 6, 0);
    lv_obj_set_style_pad_column(s_panel, 6, 0);
    lv_obj_set_scrollbar_mode(s_panel, LV_SCROLLBAR_MODE_OFF);
    lv_obj_remove_flag(s_panel, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_flex_flow(s_panel, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(s_panel, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER,
                          LV_FLEX_ALIGN_CENTER);

    /* Debian-style swirl + Applications. */
    lv_obj_t *apps = lv_button_create(s_panel);
    lv_obj_set_size(apps, 150, 32);
    make_button_flat(apps, ui_theme_colors()->title, ui_theme_colors()->border,
                     false);
    lv_obj_add_event_cb(apps, menu_toggle_cb, LV_EVENT_CLICKED, NULL);

    lv_obj_t *swirl = lv_obj_create(apps);
    lv_obj_set_size(swirl, 24, 24);
    lv_obj_align(swirl, LV_ALIGN_LEFT_MID, 4, 0);
    lv_obj_set_style_bg_color(swirl, ui_theme_colors()->accent, 0);
    lv_obj_set_style_bg_opa(swirl, LV_OPA_COVER, 0);
    lv_obj_set_style_radius(swirl, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_border_width(swirl, 0, 0);
    lv_obj_set_style_pad_all(swirl, 0, 0);
    lv_obj_remove_flag(swirl, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_remove_flag(swirl, LV_OBJ_FLAG_CLICKABLE);

    lv_obj_t *swirl_glyph = lv_label_create(swirl);
    lv_label_set_text(swirl_glyph, LV_SYMBOL_LOOP);
    lv_obj_set_style_text_font(swirl_glyph, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(swirl_glyph, lv_color_white(), 0);
    lv_obj_center(swirl_glyph);

    lv_obj_t *apps_label = lv_label_create(apps);
    lv_label_set_text(apps_label, "Applications");
    lv_obj_set_style_text_font(apps_label, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(apps_label, ui_theme_colors()->panel_text, 0);
    lv_obj_align(apps_label, LV_ALIGN_LEFT_MID, 32, 0);

    add_quick_button(LV_SYMBOL_PLAY, "Games");
    add_quick_button(LV_SYMBOL_KEYBOARD, "Terminal");
    add_quick_button(LV_SYMBOL_DIRECTORY, "Files");
    add_quick_button(LV_SYMBOL_DRIVE, "System");
    add_quick_button(LV_SYMBOL_SETTINGS, "Settings");

    lv_obj_t *spacer = lv_obj_create(s_panel);
    lv_obj_set_size(spacer, 1, 1);
    lv_obj_set_flex_grow(spacer, 1);
    lv_obj_set_style_bg_opa(spacer, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(spacer, 0, 0);
    lv_obj_set_style_pad_all(spacer, 0, 0);
    lv_obj_remove_flag(spacer, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_remove_flag(spacer, LV_OBJ_FLAG_CLICKABLE);

    s_cpu_label = lv_label_create(s_panel);
    lv_obj_set_width(s_cpu_label, 80);
    lv_label_set_text(s_cpu_label, "CPU --");
    lv_label_set_long_mode(s_cpu_label, LV_LABEL_LONG_CLIP);
    lv_obj_set_style_text_font(s_cpu_label, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(s_cpu_label, ui_theme_colors()->panel_text, 0);
    lv_obj_set_style_text_align(s_cpu_label, LV_TEXT_ALIGN_CENTER, 0);

    s_mem_label = lv_label_create(s_panel);
    lv_obj_set_width(s_mem_label, 80);
    lv_label_set_text(s_mem_label, "MEM --");
    lv_label_set_long_mode(s_mem_label, LV_LABEL_LONG_CLIP);
    lv_obj_set_style_text_font(s_mem_label, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(s_mem_label, ui_theme_colors()->panel_text, 0);
    lv_obj_set_style_text_align(s_mem_label, LV_TEXT_ALIGN_CENTER, 0);

    s_clock_label = lv_label_create(s_panel);
    lv_obj_set_width(s_clock_label, 80);
    lv_label_set_text(s_clock_label, "--:--");
    lv_label_set_long_mode(s_clock_label, LV_LABEL_LONG_CLIP);
    lv_obj_set_style_text_font(s_clock_label, &lv_font_montserrat_24, 0);
    lv_obj_set_style_text_color(s_clock_label, ui_theme_colors()->panel_text, 0);
    lv_obj_set_style_text_align(s_clock_label, LV_TEXT_ALIGN_CENTER, 0);
}

/* ------------------------------------------------------------------ */
/* Taskbar                                                             */
/* ------------------------------------------------------------------ */

static void build_taskbar(void)
{
    s_taskbar = lv_obj_create(s_root);
    lv_obj_set_pos(s_taskbar, 0, TASKBAR_Y);
    lv_obj_set_size(s_taskbar, SCREEN_W, TASKBAR_H);
    lv_obj_set_style_bg_color(s_taskbar, ui_theme_colors()->panel, 0);
    lv_obj_set_style_bg_opa(s_taskbar, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(s_taskbar, 1, 0);
    lv_obj_set_style_border_color(s_taskbar, ui_theme_colors()->border, 0);
    lv_obj_set_style_border_side(s_taskbar, LV_BORDER_SIDE_TOP, 0);
    lv_obj_set_style_radius(s_taskbar, 0, 0);
    lv_obj_set_style_pad_all(s_taskbar, 4, 0);
    lv_obj_set_style_pad_column(s_taskbar, 6, 0);
    lv_obj_set_scrollbar_mode(s_taskbar, LV_SCROLLBAR_MODE_OFF);
    lv_obj_remove_flag(s_taskbar, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_flex_flow(s_taskbar, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(s_taskbar, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER,
                          LV_FLEX_ALIGN_CENTER);

    lv_obj_t *show = lv_button_create(s_taskbar);
    lv_obj_set_size(show, 140, 28);
    make_button_flat(show, ui_theme_colors()->window, ui_theme_colors()->border,
                     false);
    lv_obj_set_style_radius(show, 4, 0);
    lv_obj_add_event_cb(show, show_desktop_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *sl = lv_label_create(show);
    lv_label_set_text(sl, "Show Desktop");
    lv_obj_set_style_text_font(sl, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(sl, ui_theme_colors()->panel_text, 0);
    lv_obj_center(sl);

    lv_obj_t *version = lv_label_create(s_taskbar);
    lv_label_set_text(version, "YeshenGui S1");
    lv_obj_set_style_text_font(version, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(version, ui_theme_colors()->panel_text, 0);
}

/* ------------------------------------------------------------------ */
/* Status: CPU / memory / clock                                        */
/* ------------------------------------------------------------------ */

/* Real CPU utilization from the aggregate "cpu" line of /proc/stat.
 *
 * 旧实现是 loadavg*100/ncpu —— 单核板上只要有任何后台负载 (load≈1) 就恒显示
 * 100%，与真实占用无关（2026-10-30 上板实测：显示 100% 而 top 里 yshell 只占 6%、
 * idle 58%）。改成两次采样求 busy 占比；第一次调用没有基准，返回 -1（显示 CPU --）。 */
static int read_cpu_percent(void)
{
    static unsigned long prev_total, prev_idle;
    static bool have_prev;

    FILE *f = fopen("/proc/stat", "r");
    if (!f) return -1;
    char line[128];
    if (!fgets(line, sizeof(line), f)) { fclose(f); return -1; }
    fclose(f);

    unsigned long user = 0, nice = 0, sys = 0, idle = 0, iow = 0, irq = 0, sirq = 0;
    if (sscanf(line, "cpu %lu %lu %lu %lu %lu %lu %lu",
               &user, &nice, &sys, &idle, &iow, &irq, &sirq) < 4)
        return -1;

    unsigned long total = user + nice + sys + idle + iow + irq + sirq;
    unsigned long idl   = idle + iow;   /* iowait 也算空闲（与 top 口径一致） */

    if (!have_prev) {
        prev_total = total; prev_idle = idl; have_prev = true;
        return -1;
    }
    unsigned long dt = total - prev_total;
    unsigned long di = idl - prev_idle;
    prev_total = total; prev_idle = idl;
    if (dt == 0) return -1;

    unsigned long busy = (dt > di) ? (dt - di) : 0;
    int pct = (int)((busy * 100UL + dt / 2) / dt);
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;
    return pct;
}

static int read_mem_percent(void)
{
    FILE *f = fopen("/proc/meminfo", "r");
    if (!f) return -1;
    char line[128];
    unsigned long total = 0, avail = 0;
    bool have_avail = false;
    while (fgets(line, sizeof(line), f)) {
        if (!strncmp(line, "MemTotal:", 9)) {
            (void)sscanf(line + 9, "%lu", &total);
        } else if (!strncmp(line, "MemAvailable:", 13)) {
            have_avail = sscanf(line + 13, "%lu", &avail) == 1;
        }
        if (total && have_avail) break;
    }
    fclose(f);
    if (total == 0 || !have_avail) return -1;

    unsigned long used = total > avail ? total - avail : 0;
    return (int)((used * 100 + total / 2) / total);
}

static void update_status(void)
{
    char buf[32];

    int cpu = read_cpu_percent();
    if (cpu >= 0) snprintf(buf, sizeof(buf), "CPU %d%%", cpu);
    else snprintf(buf, sizeof(buf), "CPU --");
    if (s_cpu_label) lv_label_set_text(s_cpu_label, buf);

    int mem = read_mem_percent();
    if (mem >= 0) snprintf(buf, sizeof(buf), "MEM %d%%", mem);
    else snprintf(buf, sizeof(buf), "MEM --");
    if (s_mem_label) lv_label_set_text(s_mem_label, buf);

    time_t now = time(NULL);
    struct tm tm_now;
    if (now != (time_t)-1 && localtime_r(&now, &tm_now) != NULL) {
        strftime(buf, sizeof(buf), "%H:%M", &tm_now);
    } else {
        snprintf(buf, sizeof(buf), "--:--");
    }
    if (s_clock_label) lv_label_set_text(s_clock_label, buf);
}

/* ------------------------------------------------------------------ */
/* Public API                                                          */
/* ------------------------------------------------------------------ */

#ifndef UI_HOST
static void hot_pressed_cb(lv_event_t *e)
{
    (void)e;
    s_hot_pressed = true;
    s_hot_ms = platform_time_ms();
}

static void hot_released_cb(lv_event_t *e)
{
    (void)e;
    s_hot_pressed = false;
}

static void hot_timer_cb(lv_timer_t *t)
{
    (void)t;
    if (!s_hot_pressed || !s_camera_mode) return;
    if ((uint32_t)(platform_time_ms() - s_hot_ms) >= 2000u) {
        s_hot_pressed = false;
        desktop_camera_leave();
    }
}

static void build_hot_corner(void)
{
    s_hot = lv_obj_create(s_root);
    lv_obj_set_pos(s_hot, 0, 0);
    lv_obj_set_size(s_hot, 64, 64);
    lv_obj_set_style_bg_opa(s_hot, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(s_hot, 0, 0);
    lv_obj_set_style_radius(s_hot, 0, 0);
    lv_obj_set_style_pad_all(s_hot, 0, 0);
    lv_obj_remove_flag(s_hot, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(s_hot, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_flag(s_hot, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_event_cb(s_hot, hot_pressed_cb, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(s_hot, hot_released_cb, LV_EVENT_RELEASED, NULL);
}
#endif

void desktop_camera_mode_changed(bool camera)
{
#ifndef UI_HOST
    s_camera_mode = camera;
    if (!s_hot) return;
    if (camera) {
        lv_obj_remove_flag(s_hot, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(s_hot, LV_OBJ_FLAG_CLICKABLE);
    } else {
        lv_obj_add_flag(s_hot, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(s_hot, LV_OBJ_FLAG_CLICKABLE);
        s_hot_pressed = false;
    }
#else
    (void)camera;
#endif
}

void desktop_init(void)
{
    s_root = lv_screen_active();
    lv_obj_set_style_bg_color(s_root, ui_theme_colors()->bg, 0);
    lv_obj_set_style_bg_opa(s_root, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(s_root, 0, 0);
    lv_obj_set_style_pad_all(s_root, 0, 0);
    lv_obj_set_scrollbar_mode(s_root, LV_SCROLLBAR_MODE_OFF);
    lv_obj_remove_flag(s_root, LV_OBJ_FLAG_SCROLLABLE);

    s_wall_layer = NULL;
    s_icon_layer = NULL;
    s_window_layer = NULL;
    s_panel = NULL;
    s_taskbar = NULL;
    s_menu = NULL;
    s_menu_backdrop = NULL;
    s_wall_img = NULL;
    s_cpu_label = NULL;
    s_mem_label = NULL;
    s_clock_label = NULL;
    s_games_win = NULL;
    s_hot = NULL;
    s_hot_pressed = false;
    s_camera_mode = false;
    for (int i = 0; i < ICON_COUNT; i++) s_icon_labels[i] = NULL;

    build_wallpaper_layer();
    build_icon_layer();
    build_window_layer();
    build_menu();
    build_panel();
    build_taskbar();

    wm_init(s_window_layer, s_taskbar);

#ifdef UI_HOST
    /* no camera hot corner on the host */
#else
    build_hot_corner();
    if (!s_hot_timer) s_hot_timer = lv_timer_create(hot_timer_cb, 50, NULL);
    camera_source_load();
#endif

    if (!s_tick_timer) s_tick_timer = lv_timer_create(clock_timer_cb, 1000, NULL);
    update_status();
}

void desktop_set_wallpaper(int index)
{
    ui_theme_set_wallpaper(index);
    if (!s_wall_layer) return;
    if (load_wallpaper()) update_icon_label_colors();
}

void desktop_apply_theme(void)
{
    if (!s_root) {
        desktop_init();
        return;
    }

    /* v1: rebuild the shell; open windows are closed by this operation.
     * Close them through the WM first: deleting s_root children directly
     * would orphan ui_window_t allocations and taskbar bookkeeping. */
    wm_close_all();
    while (lv_obj_get_child_count(s_root) > 0) {
        lv_obj_delete(lv_obj_get_child(s_root, 0));
    }
    if (s_wall_loaded) {
        lv_image_cache_drop(&s_wall.dsc);
        ui_wallpaper_free(&s_wall);
        s_wall_loaded = false;
    }
    s_wall_img = NULL;
    s_wall_layer = NULL;
    s_icon_layer = NULL;
    s_window_layer = NULL;
    s_panel = NULL;
    s_taskbar = NULL;
    s_menu = NULL;
    s_menu_backdrop = NULL;
    s_cpu_label = NULL;
    s_mem_label = NULL;
    s_clock_label = NULL;
    s_hot = NULL;
    s_hot_pressed = false;
    s_camera_mode = false;
    for (int i = 0; i < ICON_COUNT; i++) s_icon_labels[i] = NULL;

    desktop_init();
}

void desktop_open_placeholder(const char *title)
{
    open_info_card(title, "This screen will be implemented in Plan B.");
}

/* Info card used by generic placeholders: a 900x460 window with a phase
 * marker, a heading and one explanatory line. */
static void open_info_card(const char *title, const char *body)
{
    if (!title) title = "App";
    if (!body) body = "";

    lv_obj_t *content = NULL;
    if (!wm_open(title, 900, 460, false, &content, NULL) || !content) return;

    lv_obj_set_style_pad_all(content, 24, 0);

    lv_obj_t *stage = lv_label_create(content);
    lv_label_set_text(stage, "YeshenGui  -  Phase S");
    lv_obj_set_style_text_font(stage, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(stage, ui_theme_colors()->accent, 0);
    lv_obj_align(stage, LV_ALIGN_TOP_LEFT, 0, 0);

    lv_obj_t *heading = lv_label_create(content);
    lv_label_set_text(heading, title);
    lv_obj_set_style_text_font(heading, &lv_font_montserrat_20, 0);
    lv_obj_set_style_text_color(heading, ui_theme_colors()->text, 0);
    lv_obj_align(heading, LV_ALIGN_TOP_LEFT, 0, 28);

    lv_obj_t *rule = lv_obj_create(content);
    lv_obj_set_size(rule, 120, 3);
    lv_obj_align(rule, LV_ALIGN_TOP_LEFT, 0, 62);
    lv_obj_set_style_bg_color(rule, ui_theme_colors()->accent, 0);
    lv_obj_set_style_bg_opa(rule, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(rule, 0, 0);
    lv_obj_set_style_radius(rule, 2, 0);
    lv_obj_set_style_pad_all(rule, 0, 0);
    lv_obj_remove_flag(rule, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_remove_flag(rule, LV_OBJ_FLAG_CLICKABLE);

    lv_obj_t *body_label = lv_label_create(content);
    lv_label_set_text(body_label, body);
    lv_obj_set_style_text_font(body_label, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(body_label, ui_theme_colors()->text, 0);
    lv_obj_align(body_label, LV_ALIGN_TOP_LEFT, 0, 84);

    wm_enable_bubble(content);
}

/* ------------------------------------------------------------------ */
/* Camera app (board: the live J10 feed takes over the whole LCD)      */
/* ------------------------------------------------------------------ */

static lv_obj_t *s_cam0_btn;
static lv_obj_t *s_cam1_btn;
static int s_cam_src;

#define CAM_SRC_FILE    "/etc/y1cam.default"
#define CAM_DEFAULT_SRC 1   /* CAM1 is the factory default (user decision) */

#ifndef UI_HOST
/* y1cam only runs while face detection is requested: S99y1cam.sh stays off
 * by default so an idle desktop does not burn CPU on the NPU. Leaving the
 * camera view must stop it, otherwise boxes keep being drawn behind the GUI. */
static pid_t s_y1cam_pid;

static bool y1cam_running(void)
{
    if (s_y1cam_pid <= 0) return false;
    if (kill(s_y1cam_pid, 0) == 0) return true;
    s_y1cam_pid = 0;
    return false;
}

static void y1cam_start(void)
{
    if (y1cam_running()) return;
    pid_t pid = fork();
    if (pid < 0) {
        platform_log("camera: fork failed; face detection unavailable");
        return;
    }
    if (pid == 0) {
        int null_fd = open("/dev/null", O_RDWR);
        if (null_fd >= 0) dup2(null_fd, 0);
        /* Keep y1cam's CAMRUN telemetry: it is the only way to tell
         * "no face in view" from "pipeline broke" on the board. */
        int log_fd = open("/tmp/y1cam.log", O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (log_fd >= 0) {
            dup2(log_fd, 1);
            dup2(log_fd, 2);
            if (log_fd > 2) close(log_fd);
        } else if (null_fd >= 0) {
            dup2(null_fd, 1);
            dup2(null_fd, 2);
        }
        if (null_fd > 2) close(null_fd);
        execl("/root/y1/y1cam", "y1cam", "--loop", "--quiet", (char *)NULL);
        _exit(127);
    }
    s_y1cam_pid = pid;
    char msg[64];
    snprintf(msg, sizeof(msg), "YGUI-CAM y1cam start pid=%d", (int)pid);
    platform_log(msg);
}

static void y1cam_stop(void)
{
    if (!y1cam_running()) return;
    kill(s_y1cam_pid, SIGTERM);
    for (int i = 0; i < 20; i++) {
        if (waitpid(s_y1cam_pid, NULL, WNOHANG) == s_y1cam_pid) {
            s_y1cam_pid = 0;
            platform_log("YGUI-CAM y1cam stopped");
            return;
        }
        platform_delay_ms(10);
    }
    kill(s_y1cam_pid, SIGKILL);
    waitpid(s_y1cam_pid, NULL, 0);
    s_y1cam_pid = 0;
    platform_log("YGUI-CAM y1cam killed");
}
#endif

static void camera_source_apply(int src, bool save)
{
    s_cam_src = src ? 1 : 0;
    platform_set_camera_source(s_cam_src);
#ifndef UI_HOST
    if (save) {
        FILE *f = fopen(CAM_SRC_FILE, "w");
        if (f) {
            fprintf(f, "%d\n", s_cam_src);
            fclose(f);
        }
    }
#else
    (void)save;
#endif
}

static void camera_source_load(void)
{
    int v = CAM_DEFAULT_SRC;
#ifndef UI_HOST
    FILE *f = fopen(CAM_SRC_FILE, "r");
    if (f) {
        if (fscanf(f, "%d", &v) != 1 || (v != 0 && v != 1)) v = CAM_DEFAULT_SRC;
        fclose(f);
    }
#endif
    camera_source_apply(v, false);
}

static void camera_enter(bool detect)
{
#ifdef UI_HOST
    platform_log(detect ? "host: detect request (no-op)"
                        : "host: plain view request (no-op)");
#else
    if (detect) {
        platform_log("YGUI-CAM mode=detect");
        y1cam_start();
    } else {
        platform_log("YGUI-CAM mode=plain");
        y1cam_stop();
        platform_clear_overlay();
    }
#endif
    /* Nothing of the GUI is visible while the camera owns the LCD; minimise
     * every window so the desktop is what KEY4/hot-corner returns to. */
    wm_show_desktop();
    platform_set_camera_mode(true);
    desktop_camera_mode_changed(true);
}

static void info_heading(lv_obj_t *content, const char *stage_text,
                         const char *heading_text)
{
    lv_obj_t *stage = lv_label_create(content);
    lv_label_set_text(stage, stage_text);
    lv_obj_set_style_text_font(stage, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(stage, ui_theme_colors()->accent, 0);
    lv_obj_align(stage, LV_ALIGN_TOP_LEFT, 0, 0);

    lv_obj_t *heading = lv_label_create(content);
    lv_label_set_text(heading, heading_text);
    lv_obj_set_style_text_font(heading, &lv_font_montserrat_20, 0);
    lv_obj_set_style_text_color(heading, ui_theme_colors()->text, 0);
    lv_obj_align(heading, LV_ALIGN_TOP_LEFT, 0, 28);

    lv_obj_t *rule = lv_obj_create(content);
    lv_obj_set_size(rule, 120, 3);
    lv_obj_align(rule, LV_ALIGN_TOP_LEFT, 0, 62);
    lv_obj_set_style_bg_color(rule, ui_theme_colors()->accent, 0);
    lv_obj_set_style_bg_opa(rule, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(rule, 0, 0);
    lv_obj_set_style_radius(rule, 2, 0);
    lv_obj_set_style_pad_all(rule, 0, 0);
    lv_obj_remove_flag(rule, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_remove_flag(rule, LV_OBJ_FLAG_CLICKABLE);
}

/* Camera card: pick the view (face detection or plain), pick CAM0/CAM1, then
 * hand the LCD over. Back from the live view with KEY4 or a 2 s long-press in
 * the top-left corner. */
static void open_camera_card(void)
{
    lv_obj_t *content = NULL;
    if (!wm_open("Camera", 900, 460, false, &content, NULL) || !content) {
        return;
    }

    lv_obj_set_style_pad_all(content, 24, 0);
    info_heading(content, "YeshenGui  -  Camera", "J10 stereo camera");

    const char *body =
        "Choose how the live feed starts. Face detection runs y1cam (YuNet) "
        "and draws boxes; plain view just mirrors the sensor and leaves the "
        "NPU idle.";

    lv_obj_t *body_label = lv_label_create(content);
    lv_obj_set_pos(body_label, 0, 84);
    lv_obj_set_width(body_label, 800);
    lv_label_set_long_mode(body_label, LV_LABEL_LONG_WRAP);
    lv_label_set_text(body_label, body);
    lv_obj_set_style_text_font(body_label, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(body_label, ui_theme_colors()->text, 0);

    s_cam0_btn = NULL;
    s_cam1_btn = NULL;

    lv_obj_t *detect = lv_button_create(content);
    lv_obj_set_pos(detect, 0, 152);
    lv_obj_set_size(detect, 250, 56);
    make_button_flat(detect, ui_theme_colors()->accent,
                     ui_theme_colors()->border, false);
    add_pressed_feedback(detect);
    lv_obj_add_event_cb(detect, camera_detect_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *detect_label = lv_label_create(detect);
    lv_label_set_text(detect_label, "Detect faces");
    lv_obj_set_style_text_font(detect_label, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(detect_label, lv_color_white(), 0);
    lv_obj_center(detect_label);

    lv_obj_t *plain = lv_button_create(content);
    lv_obj_set_pos(plain, 270, 152);
    lv_obj_set_size(plain, 250, 56);
    make_button_flat(plain, ui_theme_colors()->window,
                     ui_theme_colors()->border, false);
    add_pressed_feedback(plain);
    lv_obj_add_event_cb(plain, camera_plain_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *plain_label = lv_label_create(plain);
    lv_label_set_text(plain_label, "Plain view");
    lv_obj_set_style_text_font(plain_label, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(plain_label, ui_theme_colors()->text, 0);
    lv_obj_center(plain_label);

    lv_obj_t *src_cap = lv_label_create(content);
    lv_label_set_text(src_cap, "Camera source (KEY2 also toggles)");
    lv_obj_set_style_text_font(src_cap, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(src_cap, ui_theme_colors()->text, 0);
    lv_obj_set_pos(src_cap, 0, 228);

    s_cam0_btn = lv_button_create(content);
    lv_obj_set_pos(s_cam0_btn, 0, 250);
    lv_obj_set_size(s_cam0_btn, 120, 44);
    lv_obj_add_event_cb(s_cam0_btn, camera_src_cb, LV_EVENT_CLICKED, (void *)0);
    lv_obj_t *cam0_label = lv_label_create(s_cam0_btn);
    lv_label_set_text(cam0_label, "CAM0");
    lv_obj_set_style_text_font(cam0_label, &lv_font_montserrat_16, 0);
    lv_obj_center(cam0_label);

    s_cam1_btn = lv_button_create(content);
    lv_obj_set_pos(s_cam1_btn, 132, 250);
    lv_obj_set_size(s_cam1_btn, 120, 44);
    lv_obj_add_event_cb(s_cam1_btn, camera_src_cb, LV_EVENT_CLICKED,
                        (void *)1);
    lv_obj_t *cam1_label = lv_label_create(s_cam1_btn);
    lv_label_set_text(cam1_label, "CAM1");
    lv_obj_set_style_text_font(cam1_label, &lv_font_montserrat_16, 0);
    lv_obj_center(cam1_label);

    lv_obj_t *hint = lv_label_create(content);
    lv_label_set_text(hint,
                      "Back to the desktop: press KEY4, or long-press the "
                      "top-left corner for 2 s.");
    lv_obj_set_style_text_font(hint, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(hint, ui_theme_colors()->text, 0);
    lv_obj_set_pos(hint, 0, 312);

    s_cam_src = platform_camera_source();
    if (s_cam_src < 0) s_cam_src = CAM_DEFAULT_SRC;
    style_cam_button(s_cam0_btn, s_cam_src == 0);
    style_cam_button(s_cam1_btn, s_cam_src == 1);

    wm_enable_bubble(content);
}

void desktop_open_camera(void)
{
    open_camera_card();
}

static void style_cam_button(lv_obj_t *btn, bool active)
{
    if (!btn) return;
    make_button_flat(btn, active ? ui_theme_colors()->accent
                                 : ui_theme_colors()->window,
                     ui_theme_colors()->border, false);
    lv_obj_t *label = lv_obj_get_child(btn, 0);
    if (label) {
        lv_obj_set_style_text_color(
            label, active ? lv_color_white() : ui_theme_colors()->text, 0);
    }
}

static void camera_detect_cb(lv_event_t *e)
{
    (void)e;
    camera_enter(true);
}

static void camera_plain_cb(lv_event_t *e)
{
    (void)e;
    camera_enter(false);
}

static void camera_src_cb(lv_event_t *e)
{
    int src = (int)(intptr_t)lv_event_get_user_data(e);
    camera_source_apply(src, true);
    style_cam_button(s_cam0_btn, s_cam_src == 0);
    style_cam_button(s_cam1_btn, s_cam_src == 1);
}

void desktop_camera_leave(void)
{
#ifndef UI_HOST
    y1cam_stop();
    platform_clear_overlay();
#endif
    platform_set_camera_mode(false);
    desktop_camera_mode_changed(false);
    lv_obj_invalidate(lv_screen_active());
    lv_refr_now(NULL);
}

/* ------------------------------------------------------------------ */
/* Games launcher                                                      */
/* ------------------------------------------------------------------ */

static lv_obj_t *make_game_card(lv_obj_t *parent, int x, int y,
                                const char *title, const char *description,
                                const char *symbol, uint32_t icon_color)
{
    lv_obj_t *card = lv_button_create(parent);
    lv_obj_set_pos(card, x, y);
    lv_obj_set_size(card, GAME_CARD_W, GAME_CARD_H);
    make_button_flat(card, ui_theme_colors()->title, ui_theme_colors()->border,
                     false);
    lv_obj_set_style_radius(card, 10, 0);
    add_pressed_feedback(card);
    lv_obj_add_event_cb(card, games_card_cb, LV_EVENT_CLICKED, (void *)title);

    lv_obj_t *icon = lv_obj_create(card);
    lv_obj_set_pos(icon, 18, 18);
    lv_obj_set_size(icon, 52, 52);
    lv_obj_set_style_bg_color(icon, lv_color_hex(icon_color), 0);
    lv_obj_set_style_bg_opa(icon, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(icon, 0, 0);
    lv_obj_set_style_radius(icon, 10, 0);
    lv_obj_set_style_pad_all(icon, 0, 0);
    lv_obj_remove_flag(icon, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_remove_flag(icon, LV_OBJ_FLAG_CLICKABLE);

    lv_obj_t *glyph = lv_label_create(icon);
    lv_label_set_text(glyph, symbol);
    lv_obj_set_style_text_font(glyph, &lv_font_montserrat_24, 0);
    lv_obj_set_style_text_color(glyph, lv_color_white(), 0);
    lv_obj_center(glyph);

    lv_obj_t *name = lv_label_create(card);
    lv_label_set_text(name, title);
    lv_obj_set_pos(name, 84, 24);
    lv_obj_set_style_text_font(name, &lv_font_montserrat_20, 0);
    lv_obj_set_style_text_color(name, ui_theme_colors()->text, 0);

    lv_obj_t *desc = lv_label_create(card);
    lv_label_set_text(desc, description);
    lv_obj_set_pos(desc, 18, 84);
    lv_obj_set_width(desc, GAME_CARD_W - 36);
    lv_label_set_long_mode(desc, LV_LABEL_LONG_WRAP);
    lv_obj_set_style_text_font(desc, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(desc, ui_theme_colors()->text, 0);
    lv_obj_set_style_text_opa(desc, LV_OPA_70, 0);
    return card;
}

void desktop_open_games(void)
{
    if (s_games_win) {
        wm_focus(s_games_win);
        return;
    }

    lv_obj_t *content = NULL;
    ui_window_t *win = wm_open("Games", GAMES_W, GAMES_H, false, &content,
                               games_close_cb);
    if (!win || !content) return;
    s_games_win = win;

    /* The WM assigns the content size but no layout pass has run yet. */
    lv_obj_update_layout(content);
    int width = (int)lv_obj_get_content_width(content);

    lv_obj_t *heading = lv_label_create(content);
    lv_label_set_text(heading, "Choose a game");
    lv_obj_set_pos(heading, 12, 4);
    lv_obj_set_style_text_font(heading, &lv_font_montserrat_24, 0);
    lv_obj_set_style_text_color(heading, ui_theme_colors()->text, 0);

    lv_obj_t *subtitle = lv_label_create(content);
    lv_label_set_text(subtitle, "Tap a card to launch it");
    lv_obj_set_pos(subtitle, 12, 38);
    lv_obj_set_style_text_font(subtitle, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(subtitle, ui_theme_colors()->text, 0);
    lv_obj_set_style_text_opa(subtitle, LV_OPA_70, 0);

    int row_w = 3 * GAME_CARD_W + 2 * GAME_CARD_GAP;
    int row_x = (width - row_w) / 2;
    if (row_x < 0) row_x = 0;
    int row_y = 96;

    make_game_card(content, row_x, row_y, "2048",
                   "Slide and merge the tiles to reach 2048.",
                   LV_SYMBOL_LIST, 0xEDC22Eu);
    make_game_card(content, row_x + GAME_CARD_W + GAME_CARD_GAP, row_y,
                   "Minesweeper",
                   "Clear every safe square and flag the mines.",
                   LV_SYMBOL_WARNING, 0x5A6B7Bu);
    make_game_card(content, row_x + 2 * (GAME_CARD_W + GAME_CARD_GAP), row_y,
                   "Snake",
                   "Eat, grow, and avoid the walls and your tail.",
                   LV_SYMBOL_LOOP, ICON_COLOR_GAMES);

    /* ★ 2026-11-02：第四张卡 —— Game Boy（Peanut-GB，全屏接管帧存，退出后自动回桌面）。 */
    make_game_card(content, row_x, row_y + GAME_CARD_H + GAME_CARD_GAP,
                   "Game Boy",
                   "Peanut-GB emulator. Pick a ROM from /root/gb/roms.",
                   LV_SYMBOL_VIDEO, 0x6E5AA8u);
}

static void games_close_cb(ui_window_t *win)
{
    if (s_games_win == win) s_games_win = NULL;
}

static void games_card_cb(lv_event_t *e)
{
    const char *title = (const char *)lv_event_get_user_data(e);
    ui_window_t *win = s_games_win;

    /* Close the launcher before opening the game so both never compete
     * for the WM's three window slots. */
    s_games_win = NULL;
    if (win) wm_close(win);
    if (title) open_app(title);
}

/* ---- Game Boy（Peanut-GB）：ROM 选择 → 全屏接管帧存 → 退出后回桌面 ---- */
#define GB_WINDOW_W   640
#define GB_WINDOW_H   460
#define GB_MAX_ROM    64
#define GB_ROM_DIR    "/root/gb/roms"

static ui_window_t *s_gb_win;
static char s_gb_roms[GB_MAX_ROM][96];
static int  s_gb_rom_count;

/* Player window: the emulator core lives inside yshell and draws into an
 * LVGL canvas, so closing the window stops it and nothing else changes. */
#define GB_PLAY_W 820
#define GB_PLAY_H 520
static ui_window_t *s_gb_play_win;

static void gb_close_cb(ui_window_t *win)
{
    if (s_gb_win == win) s_gb_win = NULL;
}

static void gb_play_close_cb(ui_window_t *win)
{
    if (s_gb_play_win != win) return;
    s_gb_play_win = NULL;
    gb_embed_close();
    platform_log("gb: window closed");
}

static void gb_open_player(const char *path)
{
    if (!path || !path[0]) return;
    if (s_gb_play_win) {
        wm_focus(s_gb_play_win);
        return;
    }

    lv_obj_t *content = NULL;
    ui_window_t *win = wm_open("Game Boy", GB_PLAY_W, GB_PLAY_H, false,
                               &content, gb_play_close_cb);
    if (!win || !content) return;
    s_gb_play_win = win;
    lv_obj_update_layout(content);
    gb_embed_open(content, path);
}

static void gb_launch_index(int idx)
{
    if (idx < 0 || idx >= s_gb_rom_count) return;
    gb_open_player(s_gb_roms[idx]);
}

void desktop_open_gb_rom(const char *path)
{
    gb_open_player(path);
}

static void gb_rom_cb(lv_event_t *e)
{
    int idx = (int)(intptr_t)lv_event_get_user_data(e);
    ui_window_t *win = s_gb_win;

    s_gb_win = NULL;
    if (win) wm_close(win);
    gb_launch_index(idx);
}

void desktop_open_gb(void)
{
    if (s_gb_win) {
        wm_focus(s_gb_win);
        return;
    }

    lv_obj_t *content = NULL;
    ui_window_t *win = wm_open("Game Boy", GB_WINDOW_W, GB_WINDOW_H, false,
                               &content, gb_close_cb);
    if (!win || !content) return;
    s_gb_win = win;

    lv_obj_update_layout(content);
    int width = (int)lv_obj_get_content_width(content);

    lv_obj_t *heading = lv_label_create(content);
    lv_label_set_text(heading, "Choose a Game Boy ROM");
    lv_obj_set_pos(heading, 12, 4);
    lv_obj_set_style_text_font(heading, &lv_font_montserrat_24, 0);
    lv_obj_set_style_text_color(heading, ui_theme_colors()->text, 0);

    lv_obj_t *subtitle = lv_label_create(content);
    lv_label_set_text(subtitle, "ROMs live in " GB_ROM_DIR
                                 " (drop .gb files there and rebuild the card)");
    lv_obj_set_pos(subtitle, 12, 38);
    lv_obj_set_style_text_font(subtitle, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(subtitle, ui_theme_colors()->text, 0);
    lv_obj_set_style_text_opa(subtitle, LV_OPA_70, 0);

    lv_obj_t *list = lv_obj_create(content);
    lv_obj_set_pos(list, 12, 66);
    lv_obj_set_size(list, width - 24, GB_WINDOW_H - 110);
    lv_obj_set_style_bg_opa(list, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(list, 0, 0);
    lv_obj_set_style_pad_all(list, 0, 0);
    lv_obj_set_flex_flow(list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_style_pad_row(list, 8, 0);

    s_gb_rom_count = 0;
    DIR *dir = opendir(GB_ROM_DIR);
    if (dir) {
        struct dirent *ent;
        while ((ent = readdir(dir)) != NULL && s_gb_rom_count < GB_MAX_ROM) {
            size_t n = strlen(ent->d_name);
            if (n < 4 || strcasecmp(ent->d_name + n - 3, ".gb") != 0) continue;
            snprintf(s_gb_roms[s_gb_rom_count], sizeof s_gb_roms[0], "%s/%s",
                     GB_ROM_DIR, ent->d_name);

            lv_obj_t *row = lv_button_create(list);
            lv_obj_set_width(row, lv_pct(100));
            lv_obj_set_height(row, 46);
            make_button_flat(row, ui_theme_colors()->title,
                             ui_theme_colors()->border, false);
            lv_obj_set_style_radius(row, 8, 0);
            add_pressed_feedback(row);
            lv_obj_add_event_cb(row, gb_rom_cb, LV_EVENT_CLICKED,
                                (void *)(intptr_t)s_gb_rom_count);

            lv_obj_t *ico = lv_label_create(row);
            lv_label_set_text(ico, LV_SYMBOL_PLAY);
            lv_obj_set_style_text_color(ico, lv_color_hex(0x6E5AA8u), 0);
            lv_obj_align(ico, LV_ALIGN_LEFT_MID, 12, 0);

            lv_obj_t *name = lv_label_create(row);
            lv_label_set_text(name, ent->d_name);
            lv_obj_set_style_text_font(name, &lv_font_montserrat_16, 0);
            lv_obj_set_style_text_color(name, ui_theme_colors()->text, 0);
            lv_obj_align(name, LV_ALIGN_LEFT_MID, 44, 0);

            s_gb_rom_count++;
        }
        closedir(dir);
    }

    if (s_gb_rom_count == 0) {
        lv_obj_t *empty = lv_label_create(list);
        lv_label_set_text(empty, "No .gb files found in " GB_ROM_DIR ".");
        lv_obj_set_style_text_color(empty, ui_theme_colors()->text, 0);
        lv_obj_set_style_text_opa(empty, LV_OPA_70, 0);
    }
}

/* Real apps replace their placeholder as each plan task lands. */
static void open_app(const char *title)
{
    if (title && !strcmp(title, "Games")) {
        desktop_open_games();
        return;
    }
    if (title && !strcmp(title, "2048")) {
        game_2048_open();
        return;
    }
    if (title && !strcmp(title, "Minesweeper")) {
        game_minesweeper_open();
        return;
    }
    if (title && !strcmp(title, "Snake")) {
        game_snake_open();
        return;
    }
    if (title && !strcmp(title, "Game Boy")) {
        desktop_open_gb();
        return;
    }
    if (title && !strcmp(title, "Files")) {
        app_files_open();
        return;
    }
    if (title && (!strcmp(title, "System") || !strcmp(title, "System Info"))) {
        app_system_info_open();
        return;
    }
    if (title && !strcmp(title, "Settings")) {
        app_settings_open();
        return;
    }
    if (title && !strcmp(title, "Camera")) {
        open_camera_card();
        return;
    }
    if (title && !strcmp(title, "Terminal")) {
        terminal_open();
        return;
    }
    if (title && !strcmp(title, "3D")) {
        app_cube3d_open();
        return;
    }
    desktop_open_placeholder(title);
}

void desktop_demo_start(const char *screenshot_dir)
{
    s_demo_done = false;
    s_demo_step = 0;
    s_shot_dir[0] = '\0';

    if (screenshot_dir && screenshot_dir[0]) {
        snprintf(s_shot_dir, sizeof(s_shot_dir), "%s", screenshot_dir);
        if (mkdir(s_shot_dir, 0755) != 0 && errno != EEXIST) {
            platform_log("desktop: cannot create screenshot directory");
        }
    }

    if (s_demo_timer) lv_timer_delete(s_demo_timer);
    s_demo_timer = lv_timer_create(demo_timer_cb, DEMO_PERIOD_MS, NULL);
}

bool desktop_demo_done(void) { return s_demo_done; }

/* ------------------------------------------------------------------ */
/* Callbacks                                                           */
/* ------------------------------------------------------------------ */

static void menu_toggle_cb(lv_event_t *e)
{
    (void)e;
    menu_set_visible(lv_obj_has_flag(s_menu, LV_OBJ_FLAG_HIDDEN));
}

static void menu_item_cb(lv_event_t *e)
{
    const char *title = (const char *)lv_event_get_user_data(e);
    menu_set_visible(false);
    open_app(title);
}

static void menu_backdrop_cb(lv_event_t *e)
{
    (void)e;
    menu_set_visible(false);
}

static void icon_event_cb(lv_event_t *e)
{
    const char *title = (const char *)lv_event_get_user_data(e);
    menu_set_visible(false);
    open_app(title);
}

static void quick_event_cb(lv_event_t *e)
{
    const char *title = (const char *)lv_event_get_user_data(e);
    menu_set_visible(false);
    open_app(title);
}

static void show_desktop_cb(lv_event_t *e)
{
    (void)e;
    menu_set_visible(false);
    wm_show_desktop();
}

static void clock_timer_cb(lv_timer_t *t)
{
    (void)t;
    update_status();
}

static bool demo_screenshot(const char *name)
{
    if (!s_shot_dir[0]) return false;
#ifdef UI_HOST
    /* The host screenshot reads a shadow framebuffer that is only updated
     * by a render pass; refresh now so the capture includes the current
     * step (e.g. wm_show_desktop() issued just before desktop.ppm). */
    lv_refr_now(NULL);
    char path[sizeof(s_shot_dir) + 32];
    snprintf(path, sizeof(path), "%s/%s", s_shot_dir, name);
    platform_screenshot(path);
    platform_log(path);
    return true;
#else
    (void)name;
    return false;
#endif
}

static void demo_timer_cb(lv_timer_t *t)
{
    (void)t;
    switch (s_demo_step) {
    case 0:
        open_app("Files");
        break;
    case 1:
        open_app("2048");
        break;
    case 2:
        open_app("Minesweeper");
        break;
    case 3:
        open_app("Snake");
        break;
    case 4:
        open_app("System Info");
        break;
    case 5:
        open_app("Settings");
        break;
    case 6:
        wm_show_desktop();
        demo_screenshot("desktop.ppm");
        break;
    case 7:
        open_app("Games");
        break;
    case 8:
        demo_screenshot("window.ppm");
        break;
    case 9:
        /* Mirror games_card_cb(): the launcher closes before the GB picker
         * opens, so the demo screenshot shows the same stacking a user sees. */
        if (s_games_win) {
            ui_window_t *win = s_games_win;
            s_games_win = NULL;
            wm_close(win);
        }
        open_app("Game Boy");
        break;
    case 10:
        demo_screenshot("gbpicker.ppm");
        break;
    case 11:
        menu_set_visible(false);
        wm_show_desktop();
        open_app("Terminal");
        terminal_demo_feed("Hello, world!  UTF-8 \xe6\x98\xbe\xe7\xa4\xba\xe6\xb5\x8b\xe8\xaf\x95\r\n"
                           "\xe4\xbd\xa0\xe5\xa5\xbd\xef\xbc\x8c\xe4\xb8\x96\xe7\x95\x8c\xef\xbc\x81"
                           " \xe4\xb8\xad\xe6\x96\x87\xe7\xbb\x88\xe7\xab\xaf\r\n"
                           "\xe7\xac\xac\xe4\xba\x8c\xe8\xa1\x8c\xef\xbc\x9a\xe4\xb8\x80\xe4\xba\x8c"
                           "\xe4\xb8\x89\xe5\x9b\x9b\xe4\xba\x94\xe5\x85\xad\xe4\xb8\x83\xe5\x85\xab"
                           "\xe4\xb9\x9d\xe5\x8d\x81 1234567890\r\n");
        break;
    case 12:
        if (demo_screenshot("terminal_cjk.ppm")) s_demo_done = true;
        break;
    default:
        break;
    }
    s_demo_step = (s_demo_step + 1) % 13;
}
