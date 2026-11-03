/* Settings: appearance (theme and wallpaper), a host-safe reboot action and
 * the about/build card. The Camera switch row enters Phase R camera mode on
 * the board (the host logs and shows a board-only note); Brightness is still
 * an inert Phase R placeholder and never touches backlight registers.
 *
 * Changing the theme re-applies the whole shell (desktop_apply_theme), which
 * deletes the settings window. The rebuild is deferred to an async call so
 * the switch callback finishes before its parent window goes away.
 */
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE 1
#endif
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include "apps.h"

#include "desktop.h"
#include "platform.h"
#include "theme.h"
#include "wm.h"

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define SETTINGS_W     900
#define SETTINGS_H     460
#define LEFT_X         0
#define RIGHT_X        440
#define CARD_W         420
#define FIELD_COLOR    0x6B7785u
#define MUTED_COLOR    0x8A97A5u
#define ROW_H          40
#define PHASE_ROW_H    34
#define MODAL_W        460
#define MODAL_H        220
#define MODAL_BTN_W    110
#define MODAL_BTN_H    44
#define MODAL_BTN_Y    136

typedef struct {
    ui_window_t *win;
    lv_obj_t *theme_switch;
    lv_obj_t *wall_ink;
    lv_obj_t *wall_paper;
} settings_ctx_t;

static settings_ctx_t *s_ctx;
static lv_obj_t *s_modal;
static bool s_theme_pending;

static void theme_switch_cb(lv_event_t *e);
static void theme_rebuild_async(void *unused);
static void wallpaper_ink_cb(lv_event_t *e);
static void wallpaper_paper_cb(lv_event_t *e);
static void brightness_info_cb(lv_event_t *e);
static void camera_switch_cb(lv_event_t *e);
static void reboot_clicked_cb(lv_event_t *e);
static void reboot_yes_cb(lv_event_t *e);
static void modal_close_cb(lv_event_t *e);
static void modal_deleted_cb(lv_event_t *e);
static lv_obj_t *modal_create(const char *title, const char *text);
static void modal_add_button(lv_obj_t *panel, const char *text, int x,
                             bool primary, lv_event_cb_t cb, void *user_data);

/* ------------------------------------------------------------------ */
/* Small helpers                                                       */
/* ------------------------------------------------------------------ */

static lv_obj_t *create_plain(lv_obj_t *parent)
{
    lv_obj_t *o = lv_obj_create(parent);
    lv_obj_set_style_bg_opa(o, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(o, 0, 0);
    lv_obj_set_style_radius(o, 0, 0);
    lv_obj_set_style_pad_all(o, 0, 0);
    lv_obj_set_scrollbar_mode(o, LV_SCROLLBAR_MODE_OFF);
    lv_obj_remove_flag(o, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_remove_flag(o, LV_OBJ_FLAG_CLICKABLE);
    return o;
}

static lv_obj_t *create_row(lv_obj_t *parent, int height)
{
    lv_obj_t *row = create_plain(parent);
    lv_obj_set_size(row, LV_PCT(100), height);
    lv_obj_set_style_pad_column(row, 8, 0);
    lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(row, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER,
                          LV_FLEX_ALIGN_CENTER);
    return row;
}

static void style_flat_button(lv_obj_t *btn, lv_color_t bg, lv_color_t border,
                              bool filled)
{
    lv_obj_set_style_bg_color(btn, bg, 0);
    lv_obj_set_style_bg_opa(btn, filled ? LV_OPA_COVER : LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(btn, filled ? 0 : 1, 0);
    lv_obj_set_style_border_color(btn, border, 0);
    lv_obj_set_style_radius(btn, 6, 0);
    lv_obj_set_style_pad_all(btn, 0, 0);
    lv_obj_set_style_shadow_width(btn, 0, 0);
}

static lv_obj_t *create_card(lv_obj_t *parent, int x, int y, int w, int h,
                             const char *title)
{
    lv_obj_t *card = lv_obj_create(parent);
    lv_obj_set_pos(card, x, y);
    lv_obj_set_size(card, w, h);
    lv_obj_set_style_bg_color(card, ui_theme_colors()->panel, 0);
    lv_obj_set_style_bg_opa(card, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(card, 1, 0);
    lv_obj_set_style_border_color(card, ui_theme_colors()->border, 0);
    lv_obj_set_style_radius(card, 8, 0);
    lv_obj_set_style_pad_all(card, 14, 0);
    lv_obj_set_style_pad_row(card, 6, 0);
    lv_obj_set_scrollbar_mode(card, LV_SCROLLBAR_MODE_OFF);
    lv_obj_remove_flag(card, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_flex_flow(card, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(card, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START,
                          LV_FLEX_ALIGN_START);

    lv_obj_t *heading = lv_label_create(card);
    lv_label_set_text(heading, title);
    lv_obj_set_style_text_font(heading, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(heading, ui_theme_colors()->accent, 0);
    lv_obj_set_style_pad_bottom(heading, 6, 0);
    return card;
}

static void add_about_row(lv_obj_t *card, const char *key, const char *value)
{
    lv_obj_t *row = create_row(card, 28);

    lv_obj_t *key_label = lv_label_create(row);
    lv_obj_set_width(key_label, 116);
    lv_label_set_text(key_label, key);
    lv_label_set_long_mode(key_label, LV_LABEL_LONG_CLIP);
    lv_obj_set_style_text_font(key_label, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(key_label, lv_color_hex(FIELD_COLOR), 0);

    lv_obj_t *value_label = lv_label_create(row);
    lv_obj_set_flex_grow(value_label, 1);
    lv_label_set_text(value_label, value);
    lv_label_set_long_mode(value_label, LV_LABEL_LONG_DOT);
    lv_obj_set_style_text_font(value_label, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(value_label, ui_theme_colors()->text, 0);
}

static void set_wall_button_active(lv_obj_t *btn, bool active)
{
    if (!btn) return;
    lv_obj_set_style_bg_color(btn, active ? ui_theme_colors()->accent
                                          : ui_theme_colors()->window, 0);
    lv_obj_set_style_bg_opa(btn, active ? LV_OPA_20 : LV_OPA_COVER, 0);
    lv_obj_set_style_border_color(btn, active ? ui_theme_colors()->accent
                                              : ui_theme_colors()->border, 0);
    lv_obj_set_style_border_width(btn, active ? 2 : 1, 0);
    lv_obj_t *label = lv_obj_get_child(btn, 0);
    if (label) {
        lv_obj_set_style_text_color(label, active ? ui_theme_colors()->accent
                                                  : ui_theme_colors()->text, 0);
    }
}

static void update_wallpaper_styles(void)
{
    if (!s_ctx) return;
    int active = ui_theme_wallpaper();
    set_wall_button_active(s_ctx->wall_ink, active == 0);
    set_wall_button_active(s_ctx->wall_paper, active == 1);
}

/* ------------------------------------------------------------------ */
/* Modals (deferred v1 replacement for lv_msgbox styling)              */
/* ------------------------------------------------------------------ */

static lv_obj_t *modal_create(const char *title, const char *text)
{
    if (s_modal) return NULL;

    lv_obj_t *backdrop = lv_obj_create(lv_layer_top());
    lv_obj_set_pos(backdrop, 0, 0);
    lv_obj_set_size(backdrop, UI_SCREEN_W, UI_SCREEN_H);
    lv_obj_set_style_bg_color(backdrop, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(backdrop, LV_OPA_50, 0);
    lv_obj_set_style_border_width(backdrop, 0, 0);
    lv_obj_set_style_radius(backdrop, 0, 0);
    lv_obj_set_style_pad_all(backdrop, 0, 0);
    lv_obj_set_scrollbar_mode(backdrop, LV_SCROLLBAR_MODE_OFF);
    lv_obj_remove_flag(backdrop, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(backdrop, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(backdrop, modal_deleted_cb, LV_EVENT_DELETE, NULL);

    lv_obj_t *panel = lv_obj_create(backdrop);
    lv_obj_set_size(panel, MODAL_W, MODAL_H);
    lv_obj_center(panel);
    lv_obj_set_style_bg_color(panel, ui_theme_colors()->window, 0);
    lv_obj_set_style_bg_opa(panel, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(panel, 2, 0);
    lv_obj_set_style_border_color(panel, ui_theme_colors()->accent, 0);
    lv_obj_set_style_radius(panel, 10, 0);
    lv_obj_set_style_pad_all(panel, 20, 0);
    lv_obj_set_style_shadow_width(panel, 24, 0);
    lv_obj_set_style_shadow_opa(panel, LV_OPA_30, 0);
    lv_obj_set_style_shadow_color(panel, lv_color_black(), 0);
    lv_obj_set_scrollbar_mode(panel, LV_SCROLLBAR_MODE_OFF);
    lv_obj_remove_flag(panel, LV_OBJ_FLAG_SCROLLABLE);

    lv_obj_t *heading = lv_label_create(panel);
    lv_obj_set_pos(heading, 0, 0);
    lv_label_set_text(heading, title);
    lv_obj_set_style_text_font(heading, &lv_font_montserrat_20, 0);
    lv_obj_set_style_text_color(heading, ui_theme_colors()->accent, 0);

    lv_obj_t *body = lv_label_create(panel);
    lv_obj_set_pos(body, 0, 34);
    lv_obj_set_size(body, MODAL_W - 40, 86);
    lv_label_set_text(body, text);
    lv_label_set_long_mode(body, LV_LABEL_LONG_WRAP);
    lv_obj_set_style_text_font(body, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(body, ui_theme_colors()->text, 0);

    s_modal = backdrop;
    return backdrop;
}

static void modal_add_button(lv_obj_t *panel, const char *text, int x,
                             bool primary, lv_event_cb_t cb, void *user_data)
{
    lv_obj_t *btn = lv_button_create(panel);
    lv_obj_set_pos(btn, x, MODAL_BTN_Y);
    lv_obj_set_size(btn, MODAL_BTN_W, MODAL_BTN_H);
    lv_obj_set_style_bg_color(btn, primary ? ui_theme_colors()->accent
                                           : ui_theme_colors()->panel, 0);
    lv_obj_set_style_bg_opa(btn, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(btn, primary ? 0 : 1, 0);
    lv_obj_set_style_border_color(btn, ui_theme_colors()->border, 0);
    lv_obj_set_style_radius(btn, 6, 0);
    lv_obj_set_style_pad_all(btn, 0, 0);
    lv_obj_set_style_shadow_width(btn, 0, 0);

    lv_obj_t *label = lv_label_create(btn);
    lv_label_set_text(label, text);
    lv_obj_set_style_text_font(label, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(label,
                                primary ? lv_color_white()
                                        : ui_theme_colors()->text, 0);
    lv_obj_center(label);

    lv_obj_add_event_cb(btn, cb, LV_EVENT_CLICKED, user_data);
}

static void modal_deleted_cb(lv_event_t *e)
{
    if (s_modal == lv_event_get_target(e)) s_modal = NULL;
}

static void modal_close_cb(lv_event_t *e)
{
    lv_obj_t *backdrop = (lv_obj_t *)lv_event_get_user_data(e);
    if (backdrop) lv_obj_delete(backdrop);
}

static void open_info_modal(const char *title, const char *text)
{
    lv_obj_t *backdrop = modal_create(title, text);
    if (!backdrop) return;
    lv_obj_t *panel = lv_obj_get_child(backdrop, 0);
    if (panel) {
        modal_add_button(panel, "OK", 310, true, modal_close_cb, backdrop);
    }
}

/* ------------------------------------------------------------------ */
/* Callbacks                                                           */
/* ------------------------------------------------------------------ */

static void theme_switch_cb(lv_event_t *e)
{
    lv_obj_t *sw = lv_event_get_target(e);
    bool dark = lv_obj_has_state(sw, LV_STATE_CHECKED);
    if (dark == ui_theme_is_dark()) return;

    ui_theme_set_dark(dark);
    if (!s_theme_pending) {
        s_theme_pending = true;
        /* The rebuild deletes this window; let the event finish first. */
        if (lv_async_call(theme_rebuild_async, NULL) != LV_RESULT_OK) {
            s_theme_pending = false;
            platform_log("settings: theme rebuild could not be scheduled");
        }
    }
}

static void theme_rebuild_async(void *unused)
{
    (void)unused;
    s_theme_pending = false;
    platform_log("settings: applying theme (desktop rebuild)");
    desktop_apply_theme();
}

static void wallpaper_ink_cb(lv_event_t *e)
{
    (void)e;
    desktop_set_wallpaper(0);
    update_wallpaper_styles();
}

static void wallpaper_paper_cb(lv_event_t *e)
{
    (void)e;
    desktop_set_wallpaper(1);
    update_wallpaper_styles();
}

static void brightness_info_cb(lv_event_t *e)
{
    (void)e;
    open_info_modal("Phase R",
                    "Brightness control is planned for Phase R. "
                    "Phase S does not touch RTL or backlight registers.");
}

static void camera_switch_cb(lv_event_t *e)
{
    (void)e;
#ifdef UI_HOST
    open_info_modal("Camera",
                    "Camera switch is board-only. The host demo keeps the "
                    "GUI; on the board, press 'c' over UART to return.");
#else
    platform_set_camera_mode(true);
#endif
}

static void reboot_clicked_cb(lv_event_t *e)
{
    (void)e;
    lv_obj_t *backdrop = modal_create(
        "Reboot", "Restart YeshenGui now? Open windows will be lost.");
    if (!backdrop) return;
    lv_obj_t *panel = lv_obj_get_child(backdrop, 0);
    if (!panel) return;
    modal_add_button(panel, "No", 188, false, modal_close_cb, backdrop);
    modal_add_button(panel, "Yes", 310, true, reboot_yes_cb, backdrop);
}

static void reboot_yes_cb(lv_event_t *e)
{
    lv_obj_t *backdrop = (lv_obj_t *)lv_event_get_user_data(e);
    if (backdrop) lv_obj_delete(backdrop);
#ifdef UI_HOST
    platform_log("reboot skipped on host");
#else
    sync();
    if (system("reboot") != 0) platform_log("settings: reboot command failed");
#endif
}

static void content_delete_cb(lv_event_t *e)
{
    settings_ctx_t *ctx = (settings_ctx_t *)lv_event_get_user_data(e);
    if (s_ctx == ctx) s_ctx = NULL;
    if (ctx) lv_free(ctx);
}

/* ------------------------------------------------------------------ */
/* UI construction                                                     */
/* ------------------------------------------------------------------ */

static void build_header(lv_obj_t *content)
{
    lv_obj_t *header = create_plain(content);
    lv_obj_set_pos(header, 0, 0);
    lv_obj_set_size(header, LV_PCT(100), 34);

    lv_obj_t *swirl = lv_obj_create(header);
    lv_obj_set_size(swirl, 30, 30);
    lv_obj_set_pos(swirl, 0, 2);
    lv_obj_set_style_bg_color(swirl, ui_theme_colors()->accent, 0);
    lv_obj_set_style_bg_opa(swirl, LV_OPA_COVER, 0);
    lv_obj_set_style_radius(swirl, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_border_width(swirl, 0, 0);
    lv_obj_set_style_pad_all(swirl, 0, 0);
    lv_obj_set_scrollbar_mode(swirl, LV_SCROLLBAR_MODE_OFF);
    lv_obj_remove_flag(swirl, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_remove_flag(swirl, LV_OBJ_FLAG_CLICKABLE);

    lv_obj_t *glyph = lv_label_create(swirl);
    lv_label_set_text(glyph, LV_SYMBOL_SETTINGS);
    lv_obj_set_style_text_font(glyph, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(glyph, lv_color_white(), 0);
    lv_obj_center(glyph);

    lv_obj_t *title = lv_label_create(header);
    lv_label_set_text(title, "Settings");
    lv_obj_set_style_text_font(title, &lv_font_montserrat_20, 0);
    lv_obj_set_style_text_color(title, ui_theme_colors()->text, 0);
    lv_obj_set_pos(title, 42, 3);

    lv_obj_t *subtitle = lv_label_create(header);
    lv_label_set_text(subtitle, "YeshenGui Phase S");
    lv_obj_set_style_text_font(subtitle, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(subtitle, ui_theme_colors()->accent, 0);
    lv_obj_align(subtitle, LV_ALIGN_TOP_RIGHT, 0, 8);
}

static void build_appearance(settings_ctx_t *ctx, lv_obj_t *content)
{
    lv_obj_t *card = create_card(content, LEFT_X, 46, CARD_W, 194,
                                 "Appearance");

    lv_obj_t *theme_row = create_row(card, ROW_H);

    lv_obj_t *theme_label = lv_label_create(theme_row);
    lv_obj_set_flex_grow(theme_label, 1);
    lv_label_set_text(theme_label, "Theme");
    lv_obj_set_style_text_font(theme_label, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(theme_label, ui_theme_colors()->text, 0);

    lv_obj_t *light = lv_label_create(theme_row);
    lv_label_set_text(light, "Light");
    lv_obj_set_style_text_font(light, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(light, lv_color_hex(MUTED_COLOR), 0);

    ctx->theme_switch = lv_switch_create(theme_row);
    lv_obj_set_size(ctx->theme_switch, 64, 32);
    lv_obj_set_style_bg_color(ctx->theme_switch, ui_theme_colors()->border, 0);
    lv_obj_set_style_bg_color(ctx->theme_switch, ui_theme_colors()->accent,
                              LV_PART_INDICATOR | LV_STATE_CHECKED);
    if (ui_theme_is_dark()) {
        lv_obj_add_state(ctx->theme_switch, LV_STATE_CHECKED);
    }
    lv_obj_add_event_cb(ctx->theme_switch, theme_switch_cb,
                        LV_EVENT_VALUE_CHANGED, NULL);

    lv_obj_t *dark = lv_label_create(theme_row);
    lv_label_set_text(dark, "Dark");
    lv_obj_set_style_text_font(dark, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(dark, lv_color_hex(MUTED_COLOR), 0);

    lv_obj_t *hint = lv_label_create(card);
    lv_obj_set_size(hint, LV_PCT(100), 32);
    lv_label_set_long_mode(hint, LV_LABEL_LONG_WRAP);
    lv_label_set_text(hint,
                      "Theme changes rebuild the desktop and close windows; "
                      "reopen Settings afterwards.");
    lv_obj_set_style_text_font(hint, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(hint, lv_color_hex(MUTED_COLOR), 0);

    lv_obj_t *wall_row = create_row(card, ROW_H);

    lv_obj_t *wall_label = lv_label_create(wall_row);
    lv_obj_set_width(wall_label, 84);
    lv_label_set_text(wall_label, "Wallpaper");
    lv_obj_set_style_text_font(wall_label, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(wall_label, ui_theme_colors()->text, 0);

    ctx->wall_ink = lv_button_create(wall_row);
    lv_obj_set_flex_grow(ctx->wall_ink, 1);
    lv_obj_set_height(ctx->wall_ink, 36);
    style_flat_button(ctx->wall_ink, ui_theme_colors()->window,
                      ui_theme_colors()->border, false);
    lv_obj_t *ink_label = lv_label_create(ctx->wall_ink);
    lv_label_set_text(ink_label, "Debian Ink");
    lv_obj_set_style_text_font(ink_label, &lv_font_montserrat_14, 0);
    lv_obj_center(ink_label);
    lv_obj_add_event_cb(ctx->wall_ink, wallpaper_ink_cb, LV_EVENT_CLICKED, NULL);

    ctx->wall_paper = lv_button_create(wall_row);
    lv_obj_set_flex_grow(ctx->wall_paper, 1);
    lv_obj_set_height(ctx->wall_paper, 36);
    style_flat_button(ctx->wall_paper, ui_theme_colors()->window,
                      ui_theme_colors()->border, false);
    lv_obj_t *paper_label = lv_label_create(ctx->wall_paper);
    lv_label_set_text(paper_label, "Debian Paper");
    lv_obj_set_style_text_font(paper_label, &lv_font_montserrat_14, 0);
    lv_obj_center(paper_label);
    lv_obj_add_event_cb(ctx->wall_paper, wallpaper_paper_cb, LV_EVENT_CLICKED,
                        NULL);

    update_wallpaper_styles();
}

static void build_display_rows(lv_obj_t *content)
{
    lv_obj_t *card = create_card(content, LEFT_X, 252, CARD_W, 128,
                                 "Display");
    lv_obj_set_style_pad_all(card, 12, 0);
    lv_obj_set_style_pad_row(card, 4, 0);
    lv_obj_t *heading = lv_obj_get_child(card, 0);
    if (heading) lv_obj_set_style_pad_bottom(heading, 4, 0);

    static const struct {
        const char *text;
        const char *chip;
        bool enabled;
        lv_event_cb_t cb;
    } rows[] = {
        { "Brightness", "Phase R", false, brightness_info_cb },
        { "Camera switch", "Switch", true, camera_switch_cb },
    };

    for (size_t i = 0; i < sizeof(rows) / sizeof(rows[0]); i++) {
        lv_obj_t *row = lv_button_create(card);
        lv_obj_set_size(row, LV_PCT(100), PHASE_ROW_H);
        lv_obj_set_style_bg_opa(row, LV_OPA_TRANSP, 0);
        lv_obj_set_style_border_width(row, 0, 0);
        lv_obj_set_style_radius(row, 6, 0);
        lv_obj_set_style_pad_all(row, 0, 0);
        lv_obj_set_style_shadow_width(row, 0, 0);
        lv_obj_set_style_bg_color(row, ui_theme_colors()->accent,
                                  LV_STATE_PRESSED);
        lv_obj_set_style_bg_opa(row, LV_OPA_20, LV_STATE_PRESSED);
        lv_obj_add_event_cb(row, rows[i].cb, LV_EVENT_CLICKED, NULL);

        lv_obj_t *name = lv_label_create(row);
        lv_label_set_text(name, rows[i].text);
        lv_obj_set_style_text_font(name, &lv_font_montserrat_16, 0);
        lv_obj_set_style_text_color(name, rows[i].enabled
                                              ? ui_theme_colors()->text
                                              : lv_color_hex(MUTED_COLOR), 0);
        lv_obj_align(name, LV_ALIGN_LEFT_MID, 10, 0);

        lv_obj_t *chip = lv_label_create(row);
        lv_label_set_text(chip, rows[i].chip);
        lv_obj_set_style_text_font(chip, &lv_font_montserrat_14, 0);
        lv_obj_set_style_text_color(chip, rows[i].enabled
                                          ? lv_color_white()
                                          : lv_color_black(), 0);
        lv_obj_set_style_bg_color(chip, rows[i].enabled
                                           ? ui_theme_colors()->accent
                                           : ui_theme_colors()->warning, 0);
        lv_obj_set_style_bg_opa(chip, LV_OPA_COVER, 0);
        lv_obj_set_style_radius(chip, 5, 0);
        lv_obj_set_style_pad_hor(chip, 6, 0);
        lv_obj_set_style_pad_ver(chip, 1, 0);
        lv_obj_align(chip, LV_ALIGN_RIGHT_MID, -4, 0);
    }
}

static void build_system(lv_obj_t *content)
{
    lv_obj_t *card = create_card(content, RIGHT_X, 46, CARD_W, 110,
                                 "System");

    lv_obj_t *row = create_row(card, ROW_H);

    lv_obj_t *text = lv_label_create(row);
    lv_obj_set_flex_grow(text, 1);
    lv_label_set_text(text, "Restart YeshenGui.");
    lv_obj_set_style_text_font(text, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(text, ui_theme_colors()->text, 0);

    lv_obj_t *reboot = lv_button_create(row);
    lv_obj_set_size(reboot, 160, ROW_H);
    lv_obj_set_style_bg_color(reboot, ui_theme_colors()->accent, 0);
    lv_obj_set_style_bg_opa(reboot, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(reboot, 0, 0);
    lv_obj_set_style_radius(reboot, 6, 0);
    lv_obj_set_style_pad_all(reboot, 0, 0);
    lv_obj_set_style_shadow_width(reboot, 0, 0);
    lv_obj_add_event_cb(reboot, reboot_clicked_cb, LV_EVENT_CLICKED, NULL);

    lv_obj_t *label = lv_label_create(reboot);
    lv_label_set_text(label, "Reboot");
    lv_obj_set_style_text_font(label, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(label, lv_color_white(), 0);
    lv_obj_center(label);
}

static void build_about(lv_obj_t *content)
{
    lv_obj_t *card = create_card(content, RIGHT_X, 168, CARD_W, 212,
                                 "About");

    char lvgl[16];
    snprintf(lvgl, sizeof(lvgl), "%d.%d.%d", LVGL_VERSION_MAJOR,
             LVGL_VERSION_MINOR, LVGL_VERSION_PATCH);

    add_about_row(card, "Version", "YeshenGui Phase S");
    add_about_row(card, "Build", __DATE__);
    add_about_row(card, "LVGL", lvgl);
    add_about_row(card, "Original Vexii", "e79bcf0");

    lv_obj_t *disclaimer = lv_label_create(card);
    lv_obj_set_width(disclaimer, LV_PCT(100));
    lv_label_set_text(disclaimer, "Debian-style demo, not Debian");
    lv_obj_set_style_text_font(disclaimer, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(disclaimer, ui_theme_colors()->warning, 0);
}

static void build_ui(settings_ctx_t *ctx, lv_obj_t *content)
{
    lv_obj_set_style_pad_all(content, 16, 0);
    lv_obj_remove_flag(content, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scrollbar_mode(content, LV_SCROLLBAR_MODE_OFF);

    build_header(content);
    build_appearance(ctx, content);
    build_display_rows(content);
    build_system(content);
    build_about(content);
}

/* ------------------------------------------------------------------ */
/* Public API                                                          */
/* ------------------------------------------------------------------ */

void app_settings_open(void)
{
    if (s_ctx) {
        wm_focus(s_ctx->win);
        return;
    }

    lv_obj_t *content = NULL;
    ui_window_t *win = wm_open("Settings", SETTINGS_W, SETTINGS_H, false,
                               &content, NULL);
    if (!win || !content) return;

    settings_ctx_t *ctx = lv_malloc_zeroed(sizeof(*ctx));
    if (!ctx) {
        wm_close(win);
        return;
    }
    ctx->win = win;
    s_ctx = ctx;

    build_ui(ctx, content);

    lv_obj_add_event_cb(content, content_delete_cb, LV_EVENT_DELETE, ctx);
    wm_enable_bubble(content);
}
