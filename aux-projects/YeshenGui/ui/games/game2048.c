/* 2048: LVGL frontend for the deterministic game2048 core.
 *
 * Layout (inside the maximized window content):
 *   top bar    Score / Best (session) / New Game
 *   board      4x4 tiles, 80px each with an 8px gap (360x360)
 *   d-pad      four 64x48 arrow buttons in a cross, right of the board
 *
 * Input: arrow buttons, window-content LV_EVENT_KEY (Task 12 adds the
 * keyboard group) and LV_EVENT_GESTURE swipes.
 */

#include "theme.h"
#include "wm.h"
#include "games/core/game2048_core.h"

#include <stdint.h>
#include <stdlib.h>
#include <time.h>

#define G2048_TILE_SIZE   80
#define G2048_TILE_GAP    8
#define G2048_BOARD_SIZE  360
#define G2048_BOARD_PAD   8
#define G2048_TOP_H       48
#define G2048_BLOCK_GAP   40
#define G2048_ARROW_W     64
#define G2048_ARROW_H     48
#define G2048_ARROW_GAP   8
#define G2048_DPAD_W      (3 * G2048_ARROW_W + 2 * G2048_ARROW_GAP)
#define G2048_DPAD_H      (3 * G2048_ARROW_H + 2 * G2048_ARROW_GAP)

#define G2048_BOARD_BG    0xBBADA0u
#define G2048_EMPTY_BG    0xCDC1B4u
#define G2048_TEXT_DARK   0x776E65u
#define G2048_TEXT_LIGHT  0xF9F6F2u
#define G2048_ACCENT_BTN  0x8F6B4Fu

typedef struct g2048_ctx g2048_ctx_t;

typedef struct {
    g2048_ctx_t *ctx;
    int dir;
} g2048_arrow_t;

struct g2048_ctx {
    g2048_t *g;
    bool won_shown;

    lv_obj_t *score_label;
    lv_obj_t *best_label;
    lv_obj_t *board;
    lv_obj_t *tile[G2048_N * G2048_N];
    lv_obj_t *tile_label[G2048_N * G2048_N];
    g2048_arrow_t arrow[4];

    lv_obj_t *overlay;
    lv_obj_t *overlay_msg;
    lv_obj_t *continue_btn;
};

/* Session-only best score (spec 8.4: never persisted). */
static uint32_t s_best;

static void game_delete_cb(lv_event_t *e);
static void arrow_click_cb(lv_event_t *e);
static void new_game_cb(lv_event_t *e);
static void continue_cb(lv_event_t *e);
static void restart_cb(lv_event_t *e);
static void key_cb(lv_event_t *e);
static void gesture_cb(lv_event_t *e);

/* ------------------------------------------------------------------ */
/* Colours and small style helpers                                     */
/* ------------------------------------------------------------------ */

static uint32_t tile_bg(uint16_t value)
{
    switch (value) {
    case 0:    return G2048_EMPTY_BG;
    case 2:    return 0xEEE4DAu;
    case 4:    return 0xEDE0C8u;
    case 8:    return 0xF2B179u;
    case 16:   return 0xF59563u;
    case 32:   return 0xF67C5Fu;
    case 64:   return 0xF65E3Bu;
    case 128:  return 0xEDCF72u;
    case 256:  return 0xEDCC61u;
    case 512:  return 0xEDC850u;
    case 1024: return 0xEDC53Fu;
    default:   return 0xEDC22Eu; /* 2048 and above */
    }
}

static lv_color_t tile_fg(uint16_t value)
{
    return value <= 4 ? lv_color_hex(G2048_TEXT_DARK)
                      : lv_color_hex(G2048_TEXT_LIGHT);
}

static void style_flat(lv_obj_t *obj, uint32_t bg, lv_color_t fg)
{
    lv_obj_set_style_bg_color(obj, lv_color_hex(bg), 0);
    lv_obj_set_style_bg_opa(obj, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(obj, 0, 0);
    lv_obj_set_style_radius(obj, 6, 0);
    lv_obj_set_style_pad_all(obj, 0, 0);
    lv_obj_set_style_shadow_width(obj, 0, 0);
    lv_obj_set_style_text_color(obj, fg, 0);
}

static void add_pressed(lv_obj_t *btn, lv_color_t color)
{
    lv_obj_set_style_bg_color(btn, color, LV_STATE_PRESSED);
    lv_obj_set_style_bg_opa(btn, LV_OPA_30, LV_STATE_PRESSED);
}

/* ------------------------------------------------------------------ */
/* Core <-> UI synchronisation                                         */
/* ------------------------------------------------------------------ */

static void update_tile(g2048_ctx_t *ctx, int index, uint16_t value)
{
    lv_obj_t *tile = ctx->tile[index];
    lv_obj_t *label = ctx->tile_label[index];

    lv_obj_set_style_bg_color(tile, lv_color_hex(tile_bg(value)), 0);
    if (value == 0) {
        lv_label_set_text(label, "");
    } else {
        lv_label_set_text_fmt(label, "%u", (unsigned)value);
        lv_obj_set_style_text_color(label, tile_fg(value), 0);
    }
}

static void update_score(g2048_ctx_t *ctx)
{
    lv_label_set_text_fmt(ctx->score_label, "Score: %u",
                          (unsigned)ctx->g->score);
    lv_label_set_text_fmt(ctx->best_label, "Best (session): %u",
                          (unsigned)s_best);
}

static void update_all(g2048_ctx_t *ctx)
{
    for (int r = 0; r < G2048_N; r++) {
        for (int c = 0; c < G2048_N; c++) {
            update_tile(ctx, r * G2048_N + c, ctx->g->cell[r][c]);
        }
    }
    update_score(ctx);
}

/* ------------------------------------------------------------------ */
/* Overlay                                                             */
/* ------------------------------------------------------------------ */

static void hide_overlay(g2048_ctx_t *ctx)
{
    if (ctx->overlay) lv_obj_add_flag(ctx->overlay, LV_OBJ_FLAG_HIDDEN);
}

static void show_overlay(g2048_ctx_t *ctx, bool won)
{
    if (!ctx->overlay) return;

    lv_label_set_text(ctx->overlay_msg, won ? "You win" : "Game over");
    if (won) {
        lv_obj_remove_flag(ctx->continue_btn, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(ctx->continue_btn, LV_OBJ_FLAG_HIDDEN);
    }

    lv_obj_remove_flag(ctx->overlay, LV_OBJ_FLAG_HIDDEN);
    lv_obj_move_foreground(ctx->overlay);
}

/* ------------------------------------------------------------------ */
/* Moves                                                               */
/* ------------------------------------------------------------------ */

static void do_move(g2048_ctx_t *ctx, int dir)
{
    if (!ctx || !ctx->g) return;
    if (!g2048_move(ctx->g, dir)) return;

    if (ctx->g->score > s_best) s_best = ctx->g->score;
    update_all(ctx);

    if (ctx->g->status == G2048_WON && !ctx->won_shown) {
        ctx->won_shown = true;
        show_overlay(ctx, true);
    } else if (ctx->g->status == G2048_OVER ||
               (ctx->g->status == G2048_WON && !g2048_can_move(ctx->g))) {
        /* The core reports WON whenever a 2048 tile exists, even if the
         * board is also full; the spec still wants Game over for no moves. */
        show_overlay(ctx, false);
    }
}

static void new_game(g2048_ctx_t *ctx)
{
    if (!ctx || !ctx->g) return;

    g2048_init(ctx->g, (uint32_t)time(NULL));
    ctx->won_shown = false;
    hide_overlay(ctx);
    update_all(ctx);
}

/* ------------------------------------------------------------------ */
/* UI construction                                                     */
/* ------------------------------------------------------------------ */

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

static void build_top_bar(g2048_ctx_t *ctx, lv_obj_t *content, int width)
{
    ctx->score_label = make_label(content, "Score: 0", 4, 12,
                                  &lv_font_montserrat_20,
                                  ui_theme_colors()->text);
    ctx->best_label = make_label(content, "Best (session): 0", 196, 12,
                                 &lv_font_montserrat_20,
                                 ui_theme_colors()->text);

    lv_obj_t *new_btn = lv_button_create(content);
    lv_obj_set_pos(new_btn, width - 120, 0);
    lv_obj_set_size(new_btn, 120, G2048_TOP_H);
    style_flat(new_btn, G2048_ACCENT_BTN, lv_color_white());
    lv_obj_set_style_radius(new_btn, 8, 0);
    add_pressed(new_btn, ui_theme_colors()->accent);
    lv_obj_add_event_cb(new_btn, new_game_cb, LV_EVENT_CLICKED, ctx);

    lv_obj_t *label = lv_label_create(new_btn);
    lv_label_set_text(label, "New Game");
    lv_obj_set_style_text_font(label, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(label, lv_color_white(), 0);
    lv_obj_center(label);
}

static void build_board(g2048_ctx_t *ctx, lv_obj_t *content, int x, int y)
{
    ctx->board = lv_obj_create(content);
    lv_obj_set_pos(ctx->board, x, y);
    lv_obj_set_size(ctx->board, G2048_BOARD_SIZE, G2048_BOARD_SIZE);
    lv_obj_set_style_bg_color(ctx->board, lv_color_hex(G2048_BOARD_BG), 0);
    lv_obj_set_style_bg_opa(ctx->board, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(ctx->board, 0, 0);
    lv_obj_set_style_radius(ctx->board, 8, 0);
    lv_obj_set_style_pad_all(ctx->board, 0, 0);
    lv_obj_set_style_shadow_width(ctx->board, 0, 0);
    lv_obj_remove_flag(ctx->board, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scrollbar_mode(ctx->board, LV_SCROLLBAR_MODE_OFF);

    for (int r = 0; r < G2048_N; r++) {
        for (int c = 0; c < G2048_N; c++) {
            int index = r * G2048_N + c;
            lv_obj_t *tile = lv_obj_create(ctx->board);
            lv_obj_set_pos(tile, G2048_BOARD_PAD +
                                c * (G2048_TILE_SIZE + G2048_TILE_GAP),
                           G2048_BOARD_PAD +
                                r * (G2048_TILE_SIZE + G2048_TILE_GAP));
            lv_obj_set_size(tile, G2048_TILE_SIZE, G2048_TILE_SIZE);
            lv_obj_set_style_bg_opa(tile, LV_OPA_COVER, 0);
            lv_obj_set_style_border_width(tile, 0, 0);
            lv_obj_set_style_radius(tile, 6, 0);
            lv_obj_set_style_pad_all(tile, 0, 0);
            lv_obj_set_style_shadow_width(tile, 0, 0);
            lv_obj_remove_flag(tile, LV_OBJ_FLAG_SCROLLABLE);
            lv_obj_set_scrollbar_mode(tile, LV_SCROLLBAR_MODE_OFF);

            lv_obj_t *label = lv_label_create(tile);
            lv_label_set_text(label, "");
            lv_obj_set_style_text_font(label, &lv_font_montserrat_24, 0);
            lv_obj_center(label);

            ctx->tile[index] = tile;
            ctx->tile_label[index] = label;
        }
    }
}

static lv_obj_t *make_arrow(g2048_ctx_t *ctx, lv_obj_t *parent, int x, int y,
                            int dir, const char *symbol, int slot)
{
    lv_obj_t *btn = lv_button_create(parent);
    lv_obj_set_pos(btn, x, y);
    lv_obj_set_size(btn, G2048_ARROW_W, G2048_ARROW_H);
    style_flat(btn, 0xD6C9BCu, lv_color_hex(G2048_TEXT_DARK));
    lv_obj_set_style_radius(btn, 8, 0);
    add_pressed(btn, ui_theme_colors()->accent);

    ctx->arrow[slot].ctx = ctx;
    ctx->arrow[slot].dir = dir;
    lv_obj_add_event_cb(btn, arrow_click_cb, LV_EVENT_CLICKED,
                        &ctx->arrow[slot]);

    lv_obj_t *label = lv_label_create(btn);
    lv_label_set_text(label, symbol);
    lv_obj_set_style_text_font(label, &lv_font_montserrat_24, 0);
    lv_obj_set_style_text_color(label, lv_color_hex(G2048_TEXT_DARK), 0);
    lv_obj_center(label);
    return btn;
}

static void build_dpad(g2048_ctx_t *ctx, lv_obj_t *content, int x, int y)
{
    lv_obj_t *dpad = lv_obj_create(content);
    lv_obj_set_pos(dpad, x, y);
    lv_obj_set_size(dpad, G2048_DPAD_W, G2048_DPAD_H);
    lv_obj_set_style_bg_opa(dpad, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(dpad, 0, 0);
    lv_obj_set_style_pad_all(dpad, 0, 0);
    lv_obj_set_style_shadow_width(dpad, 0, 0);
    lv_obj_remove_flag(dpad, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scrollbar_mode(dpad, LV_SCROLLBAR_MODE_OFF);

    int mid_x = G2048_ARROW_W + G2048_ARROW_GAP;
    int mid_y = G2048_ARROW_H + G2048_ARROW_GAP;
    int right_x = 2 * (G2048_ARROW_W + G2048_ARROW_GAP);
    int down_y = 2 * (G2048_ARROW_H + G2048_ARROW_GAP);

    make_arrow(ctx, dpad, mid_x, 0, 0, LV_SYMBOL_UP, 0);
    make_arrow(ctx, dpad, right_x, mid_y, 1, LV_SYMBOL_RIGHT, 1);
    make_arrow(ctx, dpad, mid_x, down_y, 2, LV_SYMBOL_DOWN, 2);
    make_arrow(ctx, dpad, 0, mid_y, 3, LV_SYMBOL_LEFT, 3);
}

static void build_overlay(g2048_ctx_t *ctx, lv_obj_t *content, int width,
                          int height)
{
    ctx->overlay = lv_obj_create(content);
    lv_obj_set_size(ctx->overlay, 340, 190);
    lv_obj_align(ctx->overlay, LV_ALIGN_CENTER, 0, 0);
    lv_obj_set_style_bg_color(ctx->overlay, lv_color_hex(0x1F2933), 0);
    lv_obj_set_style_bg_opa(ctx->overlay, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(ctx->overlay, 0, 0);
    lv_obj_set_style_radius(ctx->overlay, 0, 0);
    lv_obj_set_style_pad_all(ctx->overlay, 0, 0);
    lv_obj_remove_flag(ctx->overlay, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scrollbar_mode(ctx->overlay, LV_SCROLLBAR_MODE_OFF);

    lv_obj_t *card = lv_obj_create(ctx->overlay);
    lv_obj_set_size(card, 340, 190);
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

    lv_obj_t *row = lv_obj_create(card);
    lv_obj_set_size(row, LV_PCT(100), 48);
    lv_obj_set_style_bg_opa(row, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(row, 0, 0);
    lv_obj_set_style_pad_all(row, 0, 0);
    lv_obj_set_style_shadow_width(row, 0, 0);
    lv_obj_remove_flag(row, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scrollbar_mode(row, LV_SCROLLBAR_MODE_OFF);
    lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(row, LV_FLEX_ALIGN_CENTER,
                          LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_column(row, 12, 0);

    ctx->continue_btn = lv_button_create(row);
    lv_obj_set_size(ctx->continue_btn, 120, 44);
    style_flat(ctx->continue_btn, G2048_ACCENT_BTN, lv_color_white());
    lv_obj_set_style_radius(ctx->continue_btn, 8, 0);
    add_pressed(ctx->continue_btn, ui_theme_colors()->accent);
    lv_obj_add_event_cb(ctx->continue_btn, continue_cb, LV_EVENT_CLICKED, ctx);
    lv_obj_t *cl = lv_label_create(ctx->continue_btn);
    lv_label_set_text(cl, "Continue");
    lv_obj_set_style_text_font(cl, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(cl, lv_color_white(), 0);
    lv_obj_center(cl);

    lv_obj_t *restart_btn = lv_button_create(row);
    lv_obj_set_size(restart_btn, 120, 44);
    style_flat(restart_btn, G2048_ACCENT_BTN, lv_color_white());
    lv_obj_set_style_radius(restart_btn, 8, 0);
    add_pressed(restart_btn, ui_theme_colors()->accent);
    lv_obj_add_event_cb(restart_btn, restart_cb, LV_EVENT_CLICKED, ctx);
    lv_obj_t *rl = lv_label_create(restart_btn);
    lv_label_set_text(rl, "Restart");
    lv_obj_set_style_text_font(rl, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(rl, lv_color_white(), 0);
    lv_obj_center(rl);

    lv_obj_add_flag(ctx->overlay, LV_OBJ_FLAG_HIDDEN);
}

static void build_ui(g2048_ctx_t *ctx, lv_obj_t *content)
{
    lv_obj_remove_flag(content, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scrollbar_mode(content, LV_SCROLLBAR_MODE_OFF);

    /* The WM sets the content size but LVGL has not run a layout pass yet;
     * resolve it now so the centred board block gets real coordinates. */
    lv_obj_update_layout(content);

    int width = (int)lv_obj_get_content_width(content);
    int height = (int)lv_obj_get_content_height(content);

    build_top_bar(ctx, content, width);

    int block_w = G2048_BOARD_SIZE + G2048_BLOCK_GAP + G2048_DPAD_W;
    int block_x = (width - block_w) / 2;
    int board_y = G2048_TOP_H + 8 +
                  (height - G2048_TOP_H - 8 - G2048_BOARD_SIZE) / 2;
    int dpad_x = block_x + G2048_BOARD_SIZE + G2048_BLOCK_GAP;
    int dpad_y = board_y + G2048_BOARD_SIZE - G2048_DPAD_H;

    build_board(ctx, content, block_x, board_y);
    build_dpad(ctx, content, dpad_x, dpad_y);
    build_overlay(ctx, content, width, height);

    /* Swipe gestures are sent to the first ancestor without GESTURE_BUBBLE.
     * Stop at the window content so its callback receives them. */
    lv_obj_remove_flag(content, LV_OBJ_FLAG_GESTURE_BUBBLE);
    lv_obj_add_event_cb(content, key_cb, LV_EVENT_KEY, ctx);
    lv_obj_add_event_cb(content, gesture_cb, LV_EVENT_GESTURE, ctx);

    update_all(ctx);
}

/* ------------------------------------------------------------------ */
/* Callbacks                                                           */
/* ------------------------------------------------------------------ */

static void game_delete_cb(lv_event_t *e)
{
    g2048_ctx_t *ctx = (g2048_ctx_t *)lv_event_get_user_data(e);
    if (!ctx) return;
    free(ctx->g);
    free(ctx);
}

static void arrow_click_cb(lv_event_t *e)
{
    g2048_arrow_t *arrow = (g2048_arrow_t *)lv_event_get_user_data(e);
    if (!arrow || !arrow->ctx) return;
    if (!lv_obj_has_flag(arrow->ctx->overlay, LV_OBJ_FLAG_HIDDEN)) return;
    do_move(arrow->ctx, arrow->dir);
}

static void new_game_cb(lv_event_t *e)
{
    new_game((g2048_ctx_t *)lv_event_get_user_data(e));
}

static void continue_cb(lv_event_t *e)
{
    g2048_ctx_t *ctx = (g2048_ctx_t *)lv_event_get_user_data(e);
    if (!ctx) return;
    hide_overlay(ctx);
    /* A win can also fill the board; continuing then turns into game over. */
    if (!g2048_can_move(ctx->g)) show_overlay(ctx, false);
}

static void restart_cb(lv_event_t *e)
{
    new_game((g2048_ctx_t *)lv_event_get_user_data(e));
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
    g2048_ctx_t *ctx = (g2048_ctx_t *)lv_event_get_user_data(e);
    if (!ctx) return;
    if (!lv_obj_has_flag(ctx->overlay, LV_OBJ_FLAG_HIDDEN)) return;

    uint32_t key = lv_indev_get_key(lv_indev_active());
    int dir = key_to_dir(key);
    if (dir >= 0) do_move(ctx, dir);
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
    g2048_ctx_t *ctx = (g2048_ctx_t *)lv_event_get_user_data(e);
    if (!ctx) return;
    if (!lv_obj_has_flag(ctx->overlay, LV_OBJ_FLAG_HIDDEN)) return;

    lv_indev_t *indev = lv_indev_active();
    if (!indev) return;
    int dir = gesture_to_dir(lv_indev_get_gesture_dir(indev));
    if (dir >= 0) do_move(ctx, dir);
}

/* ------------------------------------------------------------------ */
/* Public API                                                          */
/* ------------------------------------------------------------------ */

void game_2048_open(void)
{
    lv_obj_t *content = NULL;
    ui_window_t *win = wm_open("2048", 0, 0, true, &content, NULL);
    if (!win || !content) return;

    g2048_ctx_t *ctx = calloc(1, sizeof(*ctx));
    g2048_t *g = malloc(sizeof(*g));
    if (!ctx || !g) {
        free(ctx);
        free(g);
        wm_close(win);
        return;
    }

    g2048_init(g, (uint32_t)time(NULL));
    ctx->g = g;

    build_ui(ctx, content);
    lv_obj_add_event_cb(content, game_delete_cb, LV_EVENT_DELETE, ctx);
    wm_enable_bubble(content);
}
