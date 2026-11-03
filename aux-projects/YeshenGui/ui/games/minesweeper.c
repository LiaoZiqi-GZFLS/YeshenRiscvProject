/* Minesweeper: LVGL frontend for the deterministic mines core.
 *
 * Layout (inside the maximized window content):
 *   top bar    Mines left / Time / Reset
 *   board      10x10 cells of 36px (360x360), centred
 *   overlay    "You win" / "Game over" + Play again
 *
 * Input: touch click reveals, long press flags (400ms, LVGL's pointer
 * long-press time), and window-content LV_EVENT_KEY handles the keypad
 * cursor (arrows, Enter, f). Task 12 adds the global keypad group.
 *
 * All mine logic lives in mines_core.c: this file only calls mines_reveal /
 * mines_flag and renders the resulting state.
 */

#include "theme.h"
#include "wm.h"
#include "games/core/mines_core.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

#define MINES_CELL_SIZE   36
#define MINES_BOARD_SIZE  (MINES_W * MINES_CELL_SIZE)
#define MINES_BOARD_GAP   8
#define MINES_TOP_H       48
#define MINES_BUTTON_W    120
#define MINES_DOT_SIZE    14

#define MINES_CLOSED_BG   0xB8C4D0u
#define MINES_OPEN_BG     0xE9EDF2u
#define MINES_GRID_LINE   0xA9B7C6u
#define MINES_FLAG_RED    0xD32F2Fu
#define MINES_MINE_BLACK  0x000000u

typedef struct mines_ctx mines_ctx_t;

typedef struct {
    mines_ctx_t *ctx;
    int x;
    int y;
    /* LVGL sends CLICKED after LONG_PRESSED on release; swallow that click so
     * a long press only toggles the flag. Cleared on the next press. */
    bool swallow_click;
} mines_cell_t;

struct mines_ctx {
    mines_t game;
    lv_timer_t *timer;
    uint32_t seconds;

    lv_obj_t *mines_label;
    lv_obj_t *time_label;
    lv_obj_t *board;
    lv_obj_t *cell[MINES_H][MINES_W];
    lv_obj_t *face[MINES_H][MINES_W];
    lv_obj_t *dot[MINES_H][MINES_W];
    mines_cell_t cells[MINES_H][MINES_W];

    lv_obj_t *overlay;
    lv_obj_t *overlay_msg;

    int cursor_x;
    int cursor_y;
};

static uint32_t s_generation;

/* ------------------------------------------------------------------ */
/* Small style helpers                                                 */
/* ------------------------------------------------------------------ */

static void style_flat(lv_obj_t *obj, uint32_t bg, lv_color_t fg, int radius)
{
    lv_obj_set_style_bg_color(obj, lv_color_hex(bg), 0);
    lv_obj_set_style_bg_opa(obj, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(obj, 0, 0);
    lv_obj_set_style_radius(obj, radius, 0);
    lv_obj_set_style_pad_all(obj, 0, 0);
    lv_obj_set_style_shadow_width(obj, 0, 0);
    lv_obj_set_style_text_color(obj, fg, 0);
}

static lv_obj_t *make_label(lv_obj_t *parent, const char *text, int x, int y,
                            const lv_font_t *font, lv_color_t color)
{
    lv_obj_t *label = lv_label_create(parent);
    lv_label_set_text(label, text);
    lv_obj_set_pos(label, x, y);
    lv_obj_set_style_text_font(label, font, 0);
    lv_obj_set_style_text_color(label, color, 0);
    return label;
}

/* Fixed digit palette: colour as well as shape distinguishes the count. */
static lv_color_t number_color(uint8_t n)
{
    switch (n) {
    case 1:  return lv_color_hex(0x1D5FBFu); /* blue */
    case 2:  return lv_color_hex(0x2E7D32u); /* green */
    case 3:  return lv_color_hex(0xD32F2Fu); /* red */
    case 4:  return lv_color_hex(0x1A237Eu); /* dark navy */
    case 5:  return lv_color_hex(0x7B1F1Fu); /* dark red */
    case 6:  return lv_color_hex(0x00838Fu); /* teal */
    case 7:  return lv_color_hex(0x212121u); /* near black */
    default: return lv_color_hex(0x616161u); /* 8: grey */
    }
}

static uint32_t new_seed(void)
{
    s_generation++;
    return (uint32_t)time(NULL) * 2654435761u ^ s_generation;
}

/* ------------------------------------------------------------------ */
/* Rendering                                                           */
/* ------------------------------------------------------------------ */

static void render_cell(mines_ctx_t *ctx, int x, int y)
{
    lv_obj_t *cell = ctx->cell[y][x];
    lv_obj_t *label = ctx->face[y][x];
    lv_obj_t *dot = ctx->dot[y][x];

    bool open = ctx->game.open[y][x] != 0;
    bool flag = ctx->game.flag[y][x] != 0;
    bool lost = ctx->game.status == MINES_LOST;
    bool mine = ctx->game.mine[y][x] != 0;

    lv_obj_set_style_bg_color(
        cell, lv_color_hex(open ? MINES_OPEN_BG : MINES_CLOSED_BG), 0);

    if (lost && mine && !flag) {
        /* Reveal every mine when the game is lost; core data only, no logic. */
        lv_label_set_text(label, "");
        lv_obj_remove_flag(dot, LV_OBJ_FLAG_HIDDEN);
    } else if (flag) {
        lv_label_set_text(label, LV_SYMBOL_PLAY);
        lv_obj_set_style_text_color(label, lv_color_hex(MINES_FLAG_RED), 0);
        lv_obj_add_flag(dot, LV_OBJ_FLAG_HIDDEN);
    } else if (open && ctx->game.adj[y][x] > 0) {
        lv_label_set_text_fmt(label, "%u",
                              (unsigned)ctx->game.adj[y][x]);
        lv_obj_set_style_text_color(
            label, number_color(ctx->game.adj[y][x]), 0);
        lv_obj_add_flag(dot, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_label_set_text(label, "");
        lv_obj_add_flag(dot, LV_OBJ_FLAG_HIDDEN);
    }

    bool cursor = x == ctx->cursor_x && y == ctx->cursor_y;
    lv_obj_set_style_border_width(cell, cursor ? 2 : 1, 0);
    lv_obj_set_style_border_color(
        cell, cursor ? ui_theme_colors()->accent
                     : lv_color_hex(MINES_GRID_LINE), 0);
    lv_obj_set_style_border_side(cell, LV_BORDER_SIDE_FULL, 0);
}

static int count_flags(const mines_ctx_t *ctx)
{
    int flags = 0;
    for (int y = 0; y < MINES_H; y++) {
        for (int x = 0; x < MINES_W; x++) {
            if (ctx->game.flag[y][x]) flags++;
        }
    }
    return flags;
}

static void render_all(mines_ctx_t *ctx)
{
    for (int y = 0; y < MINES_H; y++) {
        for (int x = 0; x < MINES_W; x++) render_cell(ctx, x, y);
    }
    lv_label_set_text_fmt(ctx->mines_label, "Mines left: %d",
                          MINES_COUNT - count_flags(ctx));
    lv_label_set_text_fmt(ctx->time_label, "Time: %us",
                          (unsigned)ctx->seconds);
}

/* ------------------------------------------------------------------ */
/* Overlay / game state                                                */
/* ------------------------------------------------------------------ */

static void hide_overlay(mines_ctx_t *ctx)
{
    if (ctx->overlay) lv_obj_add_flag(ctx->overlay, LV_OBJ_FLAG_HIDDEN);
}

static void show_overlay(mines_ctx_t *ctx, bool won)
{
    if (!ctx->overlay) return;
    lv_label_set_text(ctx->overlay_msg, won ? "You win" : "Game over");
    lv_obj_remove_flag(ctx->overlay, LV_OBJ_FLAG_HIDDEN);
    lv_obj_move_foreground(ctx->overlay);
}

static void stop_timer(mines_ctx_t *ctx)
{
    if (ctx->timer) lv_timer_pause(ctx->timer);
}

static void after_action(mines_ctx_t *ctx)
{
    render_all(ctx);
    if (ctx->game.status == MINES_WON) {
        stop_timer(ctx);
        show_overlay(ctx, true);
    } else if (ctx->game.status == MINES_LOST) {
        stop_timer(ctx);
        show_overlay(ctx, false);
    }
}

static void reset_game(mines_ctx_t *ctx)
{
    mines_init(&ctx->game, new_seed());
    ctx->seconds = 0;
    ctx->cursor_x = 0;
    ctx->cursor_y = 0;
    hide_overlay(ctx);
    if (ctx->timer) lv_timer_resume(ctx->timer);
    render_all(ctx);
}

/* ------------------------------------------------------------------ */
/* Callbacks                                                           */
/* ------------------------------------------------------------------ */

static void timer_cb(lv_timer_t *t)
{
    mines_ctx_t *ctx = (mines_ctx_t *)lv_timer_get_user_data(t);
    if (!ctx) return;
    if (ctx->game.status != MINES_RUNNING) {
        lv_timer_pause(t);
        return;
    }
    ctx->seconds++;
    lv_label_set_text_fmt(ctx->time_label, "Time: %us",
                          (unsigned)ctx->seconds);
}

static void cell_pressed_cb(lv_event_t *e)
{
    mines_cell_t *cell = (mines_cell_t *)lv_event_get_user_data(e);
    if (cell) cell->swallow_click = false;
}

static void cell_clicked_cb(lv_event_t *e)
{
    mines_cell_t *cell = (mines_cell_t *)lv_event_get_user_data(e);
    if (!cell || !cell->ctx) return;
    mines_ctx_t *ctx = cell->ctx;

    if (cell->swallow_click) {
        cell->swallow_click = false;
        return;
    }
    if (ctx->game.status != MINES_RUNNING) return;

    ctx->cursor_x = cell->x;
    ctx->cursor_y = cell->y;
    mines_reveal(&ctx->game, cell->x, cell->y);
    after_action(ctx);
}

static void cell_long_pressed_cb(lv_event_t *e)
{
    mines_cell_t *cell = (mines_cell_t *)lv_event_get_user_data(e);
    if (!cell || !cell->ctx) return;
    mines_ctx_t *ctx = cell->ctx;
    if (ctx->game.status != MINES_RUNNING) return;

    /* The release still produces CLICKED; do not treat it as a reveal. */
    cell->swallow_click = true;
    ctx->cursor_x = cell->x;
    ctx->cursor_y = cell->y;
    mines_flag(&ctx->game, cell->x, cell->y);
    after_action(ctx);
}

static void reset_cb(lv_event_t *e)
{
    mines_ctx_t *ctx = (mines_ctx_t *)lv_event_get_user_data(e);
    if (ctx) reset_game(ctx);
}

static void key_cb(lv_event_t *e)
{
    mines_ctx_t *ctx = (mines_ctx_t *)lv_event_get_user_data(e);
    if (!ctx || ctx->game.status != MINES_RUNNING) return;

    uint32_t key = lv_indev_get_key(lv_indev_active());
    /* Enter arrives both as LV_EVENT_KEY and as PRESSED/CLICKED on the
     * focused content; content_activated_cb handles it once. */
    if (key == 'f' || key == 'F') {
        mines_flag(&ctx->game, ctx->cursor_x, ctx->cursor_y);
        after_action(ctx);
        return;
    }

    int x = ctx->cursor_x;
    int y = ctx->cursor_y;
    switch (key) {
    case LV_KEY_UP:    y--; break;
    case LV_KEY_DOWN:  y++; break;
    case LV_KEY_LEFT:  x--; break;
    case LV_KEY_RIGHT: x++; break;
    default: return;
    }
    if (x < 0) x = 0;
    if (x >= MINES_W) x = MINES_W - 1;
    if (y < 0) y = 0;
    if (y >= MINES_H) y = MINES_H - 1;
    if (x == ctx->cursor_x && y == ctx->cursor_y) return;

    ctx->cursor_x = x;
    ctx->cursor_y = y;
    render_all(ctx);
}

/* LVGL's keypad input turns Enter into PRESSED/CLICKED on the focused
 * object instead of an LV_EVENT_KEY, so reveal from CLICKED too. Bubbled
 * cell clicks and pointer clicks on the content are ignored. */
static void content_activated_cb(lv_event_t *e)
{
    mines_ctx_t *ctx = (mines_ctx_t *)lv_event_get_user_data(e);
    if (!ctx || ctx->game.status != MINES_RUNNING) return;
    if (lv_event_get_target(e) != lv_event_get_current_target(e)) return;

    lv_indev_t *indev = lv_indev_active();
    if (!indev || lv_indev_get_type(indev) != LV_INDEV_TYPE_KEYPAD) return;

    mines_reveal(&ctx->game, ctx->cursor_x, ctx->cursor_y);
    after_action(ctx);
}

static void game_delete_cb(lv_event_t *e)
{
    mines_ctx_t *ctx = (mines_ctx_t *)lv_event_get_user_data(e);
    if (!ctx) return;
    if (ctx->timer) {
        lv_timer_delete(ctx->timer);
        ctx->timer = NULL;
    }
    free(ctx);
}

/* ------------------------------------------------------------------ */
/* UI construction                                                     */
/* ------------------------------------------------------------------ */

static void build_top_bar(mines_ctx_t *ctx, lv_obj_t *content, int width)
{
    ctx->mines_label = make_label(content, "Mines left: 30", 4, 12,
                                  &lv_font_montserrat_20,
                                  ui_theme_colors()->text);
    ctx->time_label = make_label(content, "Time: 0s", width / 2 - 40, 12,
                                 &lv_font_montserrat_20,
                                 ui_theme_colors()->text);

    lv_obj_t *reset = lv_button_create(content);
    lv_obj_set_pos(reset, width - MINES_BUTTON_W, 0);
    lv_obj_set_size(reset, MINES_BUTTON_W, MINES_TOP_H);
    style_flat(reset, 0x8F6B4Fu, lv_color_white(), 8);
    lv_obj_add_event_cb(reset, reset_cb, LV_EVENT_CLICKED, ctx);
    lv_obj_t *label = lv_label_create(reset);
    lv_label_set_text(label, "Reset");
    lv_obj_set_style_text_font(label, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(label, lv_color_white(), 0);
    lv_obj_center(label);
}

static void build_board(mines_ctx_t *ctx, lv_obj_t *content, int x, int y)
{
    ctx->board = lv_obj_create(content);
    lv_obj_set_pos(ctx->board, x, y);
    lv_obj_set_size(ctx->board, MINES_BOARD_SIZE, MINES_BOARD_SIZE);
    lv_obj_set_style_bg_color(ctx->board, lv_color_hex(MINES_GRID_LINE), 0);
    lv_obj_set_style_bg_opa(ctx->board, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(ctx->board, 0, 0);
    lv_obj_set_style_radius(ctx->board, 2, 0);
    lv_obj_set_style_pad_all(ctx->board, 0, 0);
    lv_obj_set_style_shadow_width(ctx->board, 0, 0);
    lv_obj_remove_flag(ctx->board, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scrollbar_mode(ctx->board, LV_SCROLLBAR_MODE_OFF);

    for (int gy = 0; gy < MINES_H; gy++) {
        for (int gx = 0; gx < MINES_W; gx++) {
            mines_cell_t *cell = &ctx->cells[gy][gx];
            cell->ctx = ctx;
            cell->x = gx;
            cell->y = gy;

            lv_obj_t *btn = lv_button_create(ctx->board);
            lv_obj_set_pos(btn, gx * MINES_CELL_SIZE, gy * MINES_CELL_SIZE);
            lv_obj_set_size(btn, MINES_CELL_SIZE, MINES_CELL_SIZE);
            lv_obj_set_style_bg_color(btn, lv_color_hex(MINES_CLOSED_BG), 0);
            lv_obj_set_style_bg_opa(btn, LV_OPA_COVER, 0);
            lv_obj_set_style_border_width(btn, 1, 0);
            lv_obj_set_style_border_color(btn,
                                          lv_color_hex(MINES_GRID_LINE), 0);
            lv_obj_set_style_radius(btn, 0, 0);
            lv_obj_set_style_pad_all(btn, 0, 0);
            lv_obj_set_style_shadow_width(btn, 0, 0);
            lv_obj_set_style_bg_color(btn, lv_color_hex(0xAAB8C6),
                                      LV_STATE_PRESSED);
            lv_obj_add_event_cb(btn, cell_pressed_cb, LV_EVENT_PRESSED, cell);
            lv_obj_add_event_cb(btn, cell_clicked_cb, LV_EVENT_CLICKED, cell);
            lv_obj_add_event_cb(btn, cell_long_pressed_cb,
                                LV_EVENT_LONG_PRESSED, cell);

            lv_obj_t *label = lv_label_create(btn);
            lv_label_set_text(label, "");
            lv_obj_set_style_text_font(label, &lv_font_montserrat_20, 0);
            lv_obj_center(label);

            lv_obj_t *dot = lv_obj_create(btn);
            lv_obj_set_size(dot, MINES_DOT_SIZE, MINES_DOT_SIZE);
            lv_obj_set_style_bg_color(dot, lv_color_hex(MINES_MINE_BLACK), 0);
            lv_obj_set_style_bg_opa(dot, LV_OPA_COVER, 0);
            lv_obj_set_style_border_width(dot, 0, 0);
            lv_obj_set_style_radius(dot, LV_RADIUS_CIRCLE, 0);
            lv_obj_set_style_pad_all(dot, 0, 0);
            lv_obj_set_style_shadow_width(dot, 0, 0);
            lv_obj_remove_flag(dot, LV_OBJ_FLAG_CLICKABLE);
            lv_obj_remove_flag(dot, LV_OBJ_FLAG_SCROLLABLE);
            lv_obj_center(dot);
            lv_obj_add_flag(dot, LV_OBJ_FLAG_HIDDEN);

            ctx->cell[gy][gx] = btn;
            ctx->face[gy][gx] = label;
            ctx->dot[gy][gx] = dot;
        }
    }
}

static void build_overlay(mines_ctx_t *ctx, lv_obj_t *content, int width,
                          int height)
{
    ctx->overlay = lv_obj_create(content);
    lv_obj_set_size(ctx->overlay, 300, 170);
    lv_obj_align(ctx->overlay, LV_ALIGN_CENTER, 0, 0);
    lv_obj_set_style_bg_color(ctx->overlay, lv_color_hex(0x1F2933), 0);
    lv_obj_set_style_bg_opa(ctx->overlay, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(ctx->overlay, 0, 0);
    lv_obj_set_style_radius(ctx->overlay, 0, 0);
    lv_obj_set_style_pad_all(ctx->overlay, 0, 0);
    lv_obj_remove_flag(ctx->overlay, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scrollbar_mode(ctx->overlay, LV_SCROLLBAR_MODE_OFF);

    lv_obj_t *card = lv_obj_create(ctx->overlay);
    lv_obj_set_size(card, 300, 170);
    lv_obj_center(card);
    lv_obj_set_style_bg_color(card, ui_theme_colors()->window, 0);
    lv_obj_set_style_bg_opa(card, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(card, 1, 0);
    lv_obj_set_style_border_color(card, ui_theme_colors()->border, 0);
    lv_obj_set_style_radius(card, 12, 0);
    lv_obj_set_style_pad_all(card, 20, 0);
    lv_obj_set_style_shadow_width(card, 0, 0);
    lv_obj_remove_flag(card, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scrollbar_mode(card, LV_SCROLLBAR_MODE_OFF);
    lv_obj_set_flex_flow(card, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(card, LV_FLEX_ALIGN_CENTER,
                          LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_row(card, 18, 0);

    ctx->overlay_msg = lv_label_create(card);
    lv_label_set_text(ctx->overlay_msg, "You win");
    lv_obj_set_style_text_font(ctx->overlay_msg, &lv_font_montserrat_24, 0);
    lv_obj_set_style_text_color(ctx->overlay_msg, ui_theme_colors()->text, 0);

    lv_obj_t *again = lv_button_create(card);
    lv_obj_set_size(again, 150, 44);
    style_flat(again, 0x8F6B4Fu, lv_color_white(), 8);
    lv_obj_add_event_cb(again, reset_cb, LV_EVENT_CLICKED, ctx);
    lv_obj_t *label = lv_label_create(again);
    lv_label_set_text(label, "Play again");
    lv_obj_set_style_text_font(label, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(label, lv_color_white(), 0);
    lv_obj_center(label);

    lv_obj_add_flag(ctx->overlay, LV_OBJ_FLAG_HIDDEN);
}

static void build_ui(mines_ctx_t *ctx, lv_obj_t *content)
{
    lv_obj_remove_flag(content, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scrollbar_mode(content, LV_SCROLLBAR_MODE_OFF);
    lv_obj_update_layout(content);

    int width = (int)lv_obj_get_content_width(content);
    int height = (int)lv_obj_get_content_height(content);

    build_top_bar(ctx, content, width);

    int board_x = (width - MINES_BOARD_SIZE) / 2;
    int board_y = MINES_TOP_H + MINES_BOARD_GAP +
                  (height - MINES_TOP_H - MINES_BOARD_GAP -
                   MINES_BOARD_SIZE) / 2;
    build_board(ctx, content, board_x, board_y);
    build_overlay(ctx, content, width, height);

    lv_obj_add_flag(content, LV_OBJ_FLAG_CLICKABLE |
                            LV_OBJ_FLAG_CLICK_FOCUSABLE);
    lv_obj_add_event_cb(content, key_cb, LV_EVENT_KEY, ctx);
    lv_obj_add_event_cb(content, content_activated_cb, LV_EVENT_CLICKED, ctx);

    render_all(ctx);
}

/* ------------------------------------------------------------------ */
/* Public API                                                          */
/* ------------------------------------------------------------------ */

void game_minesweeper_open(void)
{
    lv_obj_t *content = NULL;
    ui_window_t *win = wm_open("Minesweeper", 0, 0, true, &content, NULL);
    if (!win || !content) return;

    mines_ctx_t *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) {
        wm_close(win);
        return;
    }

    mines_init(&ctx->game, new_seed());
    ctx->cursor_x = 0;
    ctx->cursor_y = 0;

    build_ui(ctx, content);
    ctx->timer = lv_timer_create(timer_cb, 1000, ctx);
    lv_obj_add_event_cb(content, game_delete_cb, LV_EVENT_DELETE, ctx);
    wm_enable_bubble(content);
}
