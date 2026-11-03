/* Snake: LVGL frontend for the deterministic snake core.
 *
 * Layout (inside the maximized window content):
 *   top bar    Score / Speed / Pause
 *   board      20x15 cells of 24px (480x360), centred
 *   d-pad      four 64x48 arrow buttons, right of the board
 *   overlays   "Swipe or use D-pad to start" + Start
 *              "Game over" + Restart
 *
 * Input: swipe gestures on the content, the four D-pad buttons and
 * LV_EVENT_KEY on the content (arrows, p). Task 12 wires the global
 * keypad group; until then the window content receives keyboard events
 * when it has focus.
 *
 * The board is 300 plain lv_obj cells. Every tick recomputes the logical
 * cell kinds and only writes the style of cells that changed.
 */

#include "theme.h"
#include "wm.h"
#include "games/core/snake_core.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define SNAKE_CELL_SIZE   24
#define SNAKE_BOARD_W     (SNAKE_W * SNAKE_CELL_SIZE)
#define SNAKE_BOARD_H     (SNAKE_H * SNAKE_CELL_SIZE)
#define SNAKE_TOP_H       48
#define SNAKE_BOARD_GAP   8
#define SNAKE_BLOCK_GAP   40
#define SNAKE_BUTTON_W    120
#define SNAKE_ARROW_W     64
#define SNAKE_ARROW_H     48
#define SNAKE_ARROW_GAP   8
#define SNAKE_DPAD_W      (3 * SNAKE_ARROW_W + 2 * SNAKE_ARROW_GAP)
#define SNAKE_DPAD_H      (3 * SNAKE_ARROW_H + 2 * SNAKE_ARROW_GAP)

#define SNAKE_COLOR_GRID  0x1F2933u
#define SNAKE_COLOR_BODY  0xA80030u
#define SNAKE_COLOR_HEAD  0xE5484Du
#define SNAKE_COLOR_FOOD  0x2E7D32u
#define SNAKE_COLOR_BTN   0x8F6B4Fu

/* Logical cell kinds used for incremental redraws. */
enum {
    SNAKE_CELL_EMPTY = 0,
    SNAKE_CELL_BODY,
    SNAKE_CELL_HEAD,
    SNAKE_CELL_FOOD,
};

typedef struct snake_ctx snake_ctx_t;

typedef struct {
    snake_ctx_t *ctx;
    int dir;
} snake_arrow_t;

struct snake_ctx {
    snake_t game;
    lv_timer_t *timer;
    uint32_t applied_tick_ms;
    bool paused;

    lv_obj_t *score_label;
    lv_obj_t *speed_label;
    lv_obj_t *pause_btn;
    lv_obj_t *pause_label;
    lv_obj_t *board;
    lv_obj_t *cell[SNAKE_H][SNAKE_W];
    uint8_t shown[SNAKE_H][SNAKE_W];
    snake_arrow_t arrow[4];

    lv_obj_t *overlay;
    lv_obj_t *overlay_msg;
    lv_obj_t *start_btn;
    lv_obj_t *restart_btn;
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

static void add_pressed(lv_obj_t *btn, lv_color_t color)
{
    lv_obj_set_style_bg_color(btn, color, LV_STATE_PRESSED);
    lv_obj_set_style_bg_opa(btn, LV_OPA_30, LV_STATE_PRESSED);
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

static uint32_t new_seed(void)
{
    s_generation++;
    return (uint32_t)time(NULL) * 2654435761u ^ s_generation;
}

static uint32_t kind_color(uint8_t kind)
{
    switch (kind) {
    case SNAKE_CELL_BODY: return SNAKE_COLOR_BODY;
    case SNAKE_CELL_HEAD: return SNAKE_COLOR_HEAD;
    case SNAKE_CELL_FOOD: return SNAKE_COLOR_FOOD;
    default:              return SNAKE_COLOR_GRID;
    }
}

/* ------------------------------------------------------------------ */
/* Rendering                                                           */
/* ------------------------------------------------------------------ */

/* Recompute the logical board and repaint only cells whose kind changed. */
static void paint_board(snake_ctx_t *ctx)
{
    uint8_t next[SNAKE_H][SNAKE_W];
    memset(next, SNAKE_CELL_EMPTY, sizeof(next));

    if (ctx->game.food_x >= 0 && ctx->game.food_y >= 0) {
        next[ctx->game.food_y][ctx->game.food_x] = SNAKE_CELL_FOOD;
    }
    for (int i = ctx->game.len - 1; i >= 1; i--) {
        int x = ctx->game.x[i];
        int y = ctx->game.y[i];
        if (x >= 0 && x < SNAKE_W && y >= 0 && y < SNAKE_H) {
            next[y][x] = SNAKE_CELL_BODY;
        }
    }
    if (ctx->game.len > 0) {
        int x = ctx->game.x[0];
        int y = ctx->game.y[0];
        if (x >= 0 && x < SNAKE_W && y >= 0 && y < SNAKE_H) {
            next[y][x] = SNAKE_CELL_HEAD;
        }
    }

    for (int y = 0; y < SNAKE_H; y++) {
        for (int x = 0; x < SNAKE_W; x++) {
            uint8_t kind = next[y][x];
            if (kind == ctx->shown[y][x]) continue;
            ctx->shown[y][x] = kind;
            lv_obj_set_style_bg_color(
                ctx->cell[y][x], lv_color_hex(kind_color(kind)), 0);
        }
    }
}

static void update_labels(snake_ctx_t *ctx)
{
    lv_label_set_text_fmt(ctx->score_label, "Score: %u",
                          (unsigned)ctx->game.score);
    lv_label_set_text_fmt(ctx->speed_label, "Speed: %ums",
                          (unsigned)ctx->game.tick_ms);
}

/* ------------------------------------------------------------------ */
/* Overlay / game state                                                */
/* ------------------------------------------------------------------ */

static void hide_overlay(snake_ctx_t *ctx)
{
    if (ctx->overlay) lv_obj_add_flag(ctx->overlay, LV_OBJ_FLAG_HIDDEN);
}

static void show_start_overlay(snake_ctx_t *ctx)
{
    if (!ctx->overlay) return;
    lv_label_set_text(ctx->overlay_msg, "Swipe or use D-pad to start");
    lv_obj_set_style_text_font(ctx->overlay_msg, &lv_font_montserrat_20, 0);
    lv_obj_remove_flag(ctx->start_btn, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(ctx->restart_btn, LV_OBJ_FLAG_HIDDEN);
    lv_obj_remove_flag(ctx->overlay, LV_OBJ_FLAG_HIDDEN);
    lv_obj_move_foreground(ctx->overlay);
}

static void show_game_over_overlay(snake_ctx_t *ctx)
{
    if (!ctx->overlay) return;
    lv_label_set_text(ctx->overlay_msg, "Game over");
    lv_obj_set_style_text_font(ctx->overlay_msg, &lv_font_montserrat_24, 0);
    lv_obj_add_flag(ctx->start_btn, LV_OBJ_FLAG_HIDDEN);
    lv_obj_remove_flag(ctx->restart_btn, LV_OBJ_FLAG_HIDDEN);
    lv_obj_remove_flag(ctx->overlay, LV_OBJ_FLAG_HIDDEN);
    lv_obj_move_foreground(ctx->overlay);
}

static void set_pause_label(snake_ctx_t *ctx, bool paused)
{
    if (ctx->pause_label) {
        lv_label_set_text(ctx->pause_label, paused ? "Resume" : "Pause");
    }
}

static void start_game(snake_ctx_t *ctx)
{
    if (!ctx || ctx->game.status == SNAKE_OVER) return;

    snake_start(&ctx->game);
    ctx->paused = false;
    set_pause_label(ctx, false);
    hide_overlay(ctx);
    update_labels(ctx);

    if (ctx->timer) {
        ctx->applied_tick_ms = ctx->game.tick_ms;
        lv_timer_set_period(ctx->timer, ctx->game.tick_ms);
        lv_timer_reset(ctx->timer);
        lv_timer_resume(ctx->timer);
    }
}

static void toggle_pause(snake_ctx_t *ctx)
{
    if (!ctx || ctx->game.status != SNAKE_RUNNING) return;

    ctx->paused = !ctx->paused;
    set_pause_label(ctx, ctx->paused);
    if (!ctx->timer) return;
    if (ctx->paused) {
        lv_timer_pause(ctx->timer);
    } else {
        lv_timer_reset(ctx->timer);
        lv_timer_resume(ctx->timer);
    }
}

static void restart_game(snake_ctx_t *ctx)
{
    if (!ctx) return;

    snake_init(&ctx->game, new_seed());
    ctx->paused = false;
    ctx->applied_tick_ms = ctx->game.tick_ms;
    set_pause_label(ctx, false);
    if (ctx->timer) {
        lv_timer_pause(ctx->timer);
        lv_timer_set_period(ctx->timer, ctx->game.tick_ms);
    }
    update_labels(ctx);
    paint_board(ctx);
    show_start_overlay(ctx);
}

/* First direction starts a ready game; later ones turn the snake. */
static void handle_dir(snake_ctx_t *ctx, int dir)
{
    if (!ctx || ctx->game.status == SNAKE_OVER) return;
    if (ctx->paused) return;

    snake_set_dir(&ctx->game, dir);
    if (ctx->game.status == SNAKE_READY) start_game(ctx);
}

/* ------------------------------------------------------------------ */
/* Callbacks                                                           */
/* ------------------------------------------------------------------ */

static void tick_cb(lv_timer_t *t)
{
    snake_ctx_t *ctx = (snake_ctx_t *)lv_timer_get_user_data(t);
    if (!ctx) return;

    snake_tick(&ctx->game);
    paint_board(ctx);
    update_labels(ctx);

    if (ctx->game.tick_ms != ctx->applied_tick_ms) {
        ctx->applied_tick_ms = ctx->game.tick_ms;
        lv_timer_set_period(t, ctx->game.tick_ms);
    }

    if (ctx->game.status == SNAKE_OVER) {
        ctx->paused = false;
        set_pause_label(ctx, false);
        lv_timer_pause(t);
        show_game_over_overlay(ctx);
    }
}

static void arrow_click_cb(lv_event_t *e)
{
    snake_arrow_t *arrow = (snake_arrow_t *)lv_event_get_user_data(e);
    if (!arrow || !arrow->ctx) return;
    handle_dir(arrow->ctx, arrow->dir);
}

static void pause_click_cb(lv_event_t *e)
{
    toggle_pause((snake_ctx_t *)lv_event_get_user_data(e));
}

static void start_click_cb(lv_event_t *e)
{
    start_game((snake_ctx_t *)lv_event_get_user_data(e));
}

static void restart_click_cb(lv_event_t *e)
{
    restart_game((snake_ctx_t *)lv_event_get_user_data(e));
}

static int key_to_dir(uint32_t key)
{
    switch (key) {
    case LV_KEY_UP:    return 0;
    case LV_KEY_RIGHT: return 1;
    case LV_KEY_DOWN:  return 2;
    case LV_KEY_LEFT:  return 3;
    default:           return -1;
    }
}

static void key_cb(lv_event_t *e)
{
    snake_ctx_t *ctx = (snake_ctx_t *)lv_event_get_user_data(e);
    if (!ctx) return;

    lv_indev_t *indev = lv_indev_active();
    if (!indev) return;
    uint32_t key = lv_indev_get_key(indev);

    int dir = key_to_dir(key);
    if (dir >= 0) {
        handle_dir(ctx, dir);
        return;
    }
    if (key == 'p' || key == 'P') toggle_pause(ctx);
}

static int gesture_to_dir(lv_dir_t dir)
{
    switch (dir) {
    case LV_DIR_TOP:    return 0;
    case LV_DIR_RIGHT:  return 1;
    case LV_DIR_BOTTOM: return 2;
    case LV_DIR_LEFT:   return 3;
    default:            return -1;
    }
}

static void gesture_cb(lv_event_t *e)
{
    snake_ctx_t *ctx = (snake_ctx_t *)lv_event_get_user_data(e);
    if (!ctx) return;

    lv_indev_t *indev = lv_indev_active();
    if (!indev) return;
    int dir = gesture_to_dir(lv_indev_get_gesture_dir(indev));
    if (dir >= 0) handle_dir(ctx, dir);
}

static void game_delete_cb(lv_event_t *e)
{
    snake_ctx_t *ctx = (snake_ctx_t *)lv_event_get_user_data(e);
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

static void build_top_bar(snake_ctx_t *ctx, lv_obj_t *content, int width)
{
    ctx->score_label = make_label(content, "Score: 0", 4, 12,
                                  &lv_font_montserrat_20,
                                  ui_theme_colors()->text);
    ctx->speed_label = make_label(content, "Speed: 130ms", 196, 12,
                                  &lv_font_montserrat_20,
                                  ui_theme_colors()->text);

    ctx->pause_btn = lv_button_create(content);
    lv_obj_set_pos(ctx->pause_btn, width - SNAKE_BUTTON_W, 0);
    lv_obj_set_size(ctx->pause_btn, SNAKE_BUTTON_W, SNAKE_TOP_H);
    style_flat(ctx->pause_btn, SNAKE_COLOR_BTN, lv_color_white(), 8);
    add_pressed(ctx->pause_btn, ui_theme_colors()->accent);
    lv_obj_add_event_cb(ctx->pause_btn, pause_click_cb, LV_EVENT_CLICKED, ctx);

    ctx->pause_label = lv_label_create(ctx->pause_btn);
    lv_label_set_text(ctx->pause_label, "Pause");
    lv_obj_set_style_text_font(ctx->pause_label, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(ctx->pause_label, lv_color_white(), 0);
    lv_obj_center(ctx->pause_label);
}

static void build_board(snake_ctx_t *ctx, lv_obj_t *content, int x, int y)
{
    ctx->board = lv_obj_create(content);
    lv_obj_set_pos(ctx->board, x, y);
    lv_obj_set_size(ctx->board, SNAKE_BOARD_W, SNAKE_BOARD_H);
    lv_obj_set_style_bg_color(ctx->board, lv_color_hex(SNAKE_COLOR_GRID), 0);
    lv_obj_set_style_bg_opa(ctx->board, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(ctx->board, 0, 0);
    lv_obj_set_style_radius(ctx->board, 0, 0);
    lv_obj_set_style_pad_all(ctx->board, 0, 0);
    lv_obj_set_style_shadow_width(ctx->board, 0, 0);
    lv_obj_remove_flag(ctx->board, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_remove_flag(ctx->board, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_scrollbar_mode(ctx->board, LV_SCROLLBAR_MODE_OFF);

    for (int gy = 0; gy < SNAKE_H; gy++) {
        for (int gx = 0; gx < SNAKE_W; gx++) {
            lv_obj_t *cell = lv_obj_create(ctx->board);
            lv_obj_set_pos(cell, gx * SNAKE_CELL_SIZE, gy * SNAKE_CELL_SIZE);
            lv_obj_set_size(cell, SNAKE_CELL_SIZE, SNAKE_CELL_SIZE);
            lv_obj_set_style_bg_color(cell, lv_color_hex(SNAKE_COLOR_GRID), 0);
            lv_obj_set_style_bg_opa(cell, LV_OPA_COVER, 0);
            lv_obj_set_style_border_width(cell, 0, 0);
            lv_obj_set_style_radius(cell, 0, 0);
            lv_obj_set_style_pad_all(cell, 0, 0);
            lv_obj_set_style_shadow_width(cell, 0, 0);
            lv_obj_remove_flag(cell, LV_OBJ_FLAG_SCROLLABLE);
            lv_obj_remove_flag(cell, LV_OBJ_FLAG_CLICKABLE);
            ctx->cell[gy][gx] = cell;
        }
    }
}

static lv_obj_t *make_arrow(snake_ctx_t *ctx, lv_obj_t *parent, int x, int y,
                            int dir, const char *symbol, int slot)
{
    lv_obj_t *btn = lv_button_create(parent);
    lv_obj_set_pos(btn, x, y);
    lv_obj_set_size(btn, SNAKE_ARROW_W, SNAKE_ARROW_H);
    style_flat(btn, SNAKE_COLOR_BTN, lv_color_white(), 8);
    add_pressed(btn, ui_theme_colors()->accent);

    ctx->arrow[slot].ctx = ctx;
    ctx->arrow[slot].dir = dir;
    lv_obj_add_event_cb(btn, arrow_click_cb, LV_EVENT_CLICKED,
                        &ctx->arrow[slot]);

    lv_obj_t *label = lv_label_create(btn);
    lv_label_set_text(label, symbol);
    lv_obj_set_style_text_font(label, &lv_font_montserrat_24, 0);
    lv_obj_set_style_text_color(label, lv_color_white(), 0);
    lv_obj_center(label);
    return btn;
}

static void build_dpad(snake_ctx_t *ctx, lv_obj_t *content, int x, int y)
{
    lv_obj_t *dpad = lv_obj_create(content);
    lv_obj_set_pos(dpad, x, y);
    lv_obj_set_size(dpad, SNAKE_DPAD_W, SNAKE_DPAD_H);
    lv_obj_set_style_bg_opa(dpad, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(dpad, 0, 0);
    lv_obj_set_style_pad_all(dpad, 0, 0);
    lv_obj_set_style_shadow_width(dpad, 0, 0);
    lv_obj_remove_flag(dpad, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_remove_flag(dpad, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_scrollbar_mode(dpad, LV_SCROLLBAR_MODE_OFF);

    int mid_x = SNAKE_ARROW_W + SNAKE_ARROW_GAP;
    int mid_y = SNAKE_ARROW_H + SNAKE_ARROW_GAP;
    int right_x = 2 * (SNAKE_ARROW_W + SNAKE_ARROW_GAP);
    int down_y = 2 * (SNAKE_ARROW_H + SNAKE_ARROW_GAP);

    make_arrow(ctx, dpad, mid_x, 0, 0, LV_SYMBOL_UP, 0);
    make_arrow(ctx, dpad, right_x, mid_y, 1, LV_SYMBOL_RIGHT, 1);
    make_arrow(ctx, dpad, mid_x, down_y, 2, LV_SYMBOL_DOWN, 2);
    make_arrow(ctx, dpad, 0, mid_y, 3, LV_SYMBOL_LEFT, 3);
}

static lv_obj_t *make_overlay_button(snake_ctx_t *ctx, lv_obj_t *parent,
                                     const char *text,
                                     lv_event_cb_t cb)
{
    lv_obj_t *btn = lv_button_create(parent);
    lv_obj_set_size(btn, 150, 44);
    style_flat(btn, SNAKE_COLOR_BTN, lv_color_white(), 8);
    add_pressed(btn, ui_theme_colors()->accent);
    lv_obj_add_event_cb(btn, cb, LV_EVENT_CLICKED, ctx);

    lv_obj_t *label = lv_label_create(btn);
    lv_label_set_text(label, text);
    lv_obj_set_style_text_font(label, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(label, lv_color_white(), 0);
    lv_obj_center(label);
    return btn;
}

static void build_overlay(snake_ctx_t *ctx, lv_obj_t *content, int width,
                          int height)
{
    ctx->overlay = lv_obj_create(content);
    lv_obj_set_size(ctx->overlay, 440, 190);
    lv_obj_align(ctx->overlay, LV_ALIGN_CENTER, 0, 0);
    lv_obj_set_style_bg_color(ctx->overlay, lv_color_hex(0x1F2933), 0);
    lv_obj_set_style_bg_opa(ctx->overlay, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(ctx->overlay, 0, 0);
    lv_obj_set_style_radius(ctx->overlay, 0, 0);
    lv_obj_set_style_pad_all(ctx->overlay, 0, 0);
    lv_obj_remove_flag(ctx->overlay, LV_OBJ_FLAG_SCROLLABLE);
    /* Not clickable: the dimmed area must not swallow D-pad presses, and a
     * swipe that starts outside the card must still reach the content. */
    lv_obj_remove_flag(ctx->overlay, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_scrollbar_mode(ctx->overlay, LV_SCROLLBAR_MODE_OFF);

    lv_obj_t *card = lv_obj_create(ctx->overlay);
    lv_obj_set_size(card, 440, 190);
    lv_obj_center(card);
    lv_obj_set_style_bg_color(card, ui_theme_colors()->window, 0);
    lv_obj_set_style_bg_opa(card, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(card, 1, 0);
    lv_obj_set_style_border_color(card, ui_theme_colors()->border, 0);
    lv_obj_set_style_radius(card, 12, 0);
    lv_obj_set_style_pad_all(card, 20, 0);
    lv_obj_set_style_shadow_width(card, 0, 0);
    lv_obj_remove_flag(card, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_remove_flag(card, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_scrollbar_mode(card, LV_SCROLLBAR_MODE_OFF);
    lv_obj_set_flex_flow(card, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(card, LV_FLEX_ALIGN_CENTER,
                          LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_row(card, 18, 0);

    ctx->overlay_msg = lv_label_create(card);
    lv_label_set_text(ctx->overlay_msg, "Swipe or use D-pad to start");
    lv_obj_set_style_text_font(ctx->overlay_msg, &lv_font_montserrat_20, 0);
    lv_obj_set_style_text_color(ctx->overlay_msg, ui_theme_colors()->text, 0);

    ctx->start_btn = make_overlay_button(ctx, card, "Start", start_click_cb);
    ctx->restart_btn = make_overlay_button(ctx, card, "Restart",
                                           restart_click_cb);
    lv_obj_add_flag(ctx->restart_btn, LV_OBJ_FLAG_HIDDEN);

    lv_obj_add_flag(ctx->overlay, LV_OBJ_FLAG_HIDDEN);
}

static void build_ui(snake_ctx_t *ctx, lv_obj_t *content)
{
    lv_obj_remove_flag(content, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scrollbar_mode(content, LV_SCROLLBAR_MODE_OFF);
    lv_obj_add_flag(content, LV_OBJ_FLAG_CLICKABLE);

    /* The WM sets the content size but LVGL has not run a layout pass yet;
     * resolve it now so the centred board block gets real coordinates. */
    lv_obj_update_layout(content);

    int width = (int)lv_obj_get_content_width(content);
    int height = (int)lv_obj_get_content_height(content);

    build_top_bar(ctx, content, width);

    int board_x = (width - SNAKE_BOARD_W) / 2;
    int board_y = SNAKE_TOP_H + SNAKE_BOARD_GAP +
                  (height - SNAKE_TOP_H - SNAKE_BOARD_GAP -
                   SNAKE_BOARD_H) / 2;
    int dpad_x = board_x + SNAKE_BOARD_W + SNAKE_BLOCK_GAP;
    if (dpad_x + SNAKE_DPAD_W > width) {
        dpad_x = width - SNAKE_DPAD_W - 4;
    }
    int dpad_y = board_y + SNAKE_BOARD_H - SNAKE_DPAD_H;

    build_board(ctx, content, board_x, board_y);
    build_dpad(ctx, content, dpad_x, dpad_y);
    build_overlay(ctx, content, width, height);

    /* A draggable content steals swipes and repaints the whole window while
     * the finger is down; the board is fixed. */
    lv_obj_remove_flag(content, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scrollbar_mode(content, LV_SCROLLBAR_MODE_OFF);

    /* Swipes are sent to the first ancestor without GESTURE_BUBBLE.
     * Stop at the window content so its callback receives them. */
    lv_obj_remove_flag(content, LV_OBJ_FLAG_GESTURE_BUBBLE);
    lv_obj_add_event_cb(content, key_cb, LV_EVENT_KEY, ctx);
    lv_obj_add_event_cb(content, gesture_cb, LV_EVENT_GESTURE, ctx);

    paint_board(ctx);
    update_labels(ctx);
}

/* ------------------------------------------------------------------ */
/* Public API                                                          */
/* ------------------------------------------------------------------ */

void game_snake_open(void)
{
    lv_obj_t *content = NULL;
    ui_window_t *win = wm_open("Snake", 0, 0, true, &content, NULL);
    if (!win || !content) return;

    snake_ctx_t *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) {
        wm_close(win);
        return;
    }

    snake_init(&ctx->game, new_seed());
    ctx->applied_tick_ms = ctx->game.tick_ms;

    build_ui(ctx, content);
    ctx->timer = lv_timer_create(tick_cb, ctx->game.tick_ms, ctx);
    if (ctx->timer) lv_timer_pause(ctx->timer);
    show_start_overlay(ctx);
    lv_obj_add_event_cb(content, game_delete_cb, LV_EVENT_DELETE, ctx);
    wm_enable_bubble(content);
}
