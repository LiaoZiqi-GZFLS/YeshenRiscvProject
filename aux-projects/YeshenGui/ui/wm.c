#include "wm.h"
#include "theme.h"
#include <stdio.h>
#include <string.h>

#define WM_MAX 3
#define WM_DESKTOP_W 1024
#define WM_DESKTOP_H 524
#define WM_MAX_H 508
#define WM_MAX_W 1008

struct ui_window {
    lv_obj_t *root;
    lv_obj_t *title_bar;
    char title_text[32];
    lv_obj_t *content;
    lv_obj_t *close_btn;
    lv_obj_t *min_btn;
    lv_obj_t *task_btn;
    ui_close_cb_t on_close;
    int w, h;
    bool minimized;
};

static ui_window_t *s_wins[WM_MAX];
static int s_count;
static ui_window_t *s_focus;
static lv_obj_t *s_layer;
static lv_obj_t *s_taskbar;

static void update_focus_style(void);
static void focus_event_cb(lv_event_t *e);
static void close_event_cb(lv_event_t *e);
static void min_event_cb(lv_event_t *e);
static void drag_event_cb(lv_event_t *e);
static void task_event_cb(lv_event_t *e);

void wm_init(lv_obj_t *window_layer, lv_obj_t *taskbar)
{
    s_layer = window_layer;
    s_taskbar = taskbar;
    s_count = 0;
    s_focus = NULL;
}

static void taskbar_add(ui_window_t *w)
{
    w->task_btn = lv_button_create(s_taskbar);
    lv_obj_set_size(w->task_btn, 140, 28);
    lv_obj_set_style_radius(w->task_btn, 4, 0);
    lv_obj_t *l = lv_label_create(w->task_btn);
    lv_label_set_text(l, w->title_text);
    lv_obj_center(l);
    lv_obj_add_event_cb(w->task_btn, task_event_cb, LV_EVENT_CLICKED, w);
}

ui_window_t *wm_open(const char *title, int w, int h, bool maximized,
                     lv_obj_t **content_out, ui_close_cb_t on_close)
{
    if (s_count >= WM_MAX) {
        wm_close(s_wins[0]);
    }
    ui_window_t *win = lv_malloc_zeroed(sizeof(*win));
    if (!win) return NULL;
    win->on_close = on_close;
    win->w = maximized ? WM_MAX_W : w;
    win->h = maximized ? WM_MAX_H : h;
    snprintf(win->title_text, sizeof(win->title_text), "%s", title);

    win->root = lv_obj_create(s_layer);
    lv_obj_set_size(win->root, win->w, win->h);
    lv_obj_set_pos(win->root, (WM_DESKTOP_W - win->w) / 2,
                   (WM_DESKTOP_H - win->h) / 2);
    lv_obj_set_style_bg_color(win->root, ui_theme_colors()->window, 0);
    lv_obj_set_style_bg_opa(win->root, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(win->root, 1, 0);
    lv_obj_set_style_border_color(win->root, ui_theme_colors()->border, 0);
    lv_obj_set_style_radius(win->root, 8, 0);
    lv_obj_set_style_pad_all(win->root, 0, 0);
    lv_obj_set_scrollbar_mode(win->root, LV_SCROLLBAR_MODE_OFF);
    lv_obj_remove_flag(win->root, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(win->root, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_flag(win->root, LV_OBJ_FLAG_EVENT_BUBBLE);
    lv_obj_add_event_cb(win->root, focus_event_cb, LV_EVENT_PRESSED, win);

    win->title_bar = lv_obj_create(win->root);
    lv_obj_set_size(win->title_bar, win->w, 36);
    lv_obj_align(win->title_bar, LV_ALIGN_TOP_MID, 0, 0);
    lv_obj_set_style_bg_color(win->title_bar, ui_theme_colors()->title, 0);
    lv_obj_set_style_bg_opa(win->title_bar, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(win->title_bar, 0, 0);
    lv_obj_set_style_radius(win->title_bar, 8, 0);
    lv_obj_set_style_pad_all(win->title_bar, 4, 0);
    /* Bubble title bar presses so the root's focus handler raises the window. */
    lv_obj_add_flag(win->title_bar, LV_OBJ_FLAG_EVENT_BUBBLE);
    lv_obj_add_event_cb(win->title_bar, drag_event_cb, LV_EVENT_PRESSED, win);
    lv_obj_add_event_cb(win->title_bar, drag_event_cb, LV_EVENT_PRESSING, win);
    lv_obj_add_event_cb(win->title_bar, drag_event_cb, LV_EVENT_RELEASED, win);

    lv_obj_t *l = lv_label_create(win->title_bar);
    lv_label_set_text(l, title);
    lv_obj_set_style_text_font(l, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(l, ui_theme_colors()->text, 0);
    lv_obj_align(l, LV_ALIGN_LEFT_MID, 0, 0);

    win->close_btn = lv_button_create(win->title_bar);
    lv_obj_set_size(win->close_btn, 48, 32);
    lv_obj_align(win->close_btn, LV_ALIGN_RIGHT_MID, 0, 0);
    lv_obj_set_style_bg_color(win->close_btn, ui_theme_colors()->accent, 0);
    lv_obj_set_style_bg_opa(win->close_btn, LV_OPA_COVER, 0);
    lv_obj_t *cl = lv_label_create(win->close_btn);
    lv_label_set_text(cl, LV_SYMBOL_CLOSE);
    lv_obj_center(cl);
    lv_obj_add_event_cb(win->close_btn, close_event_cb, LV_EVENT_CLICKED, win);

    win->min_btn = lv_button_create(win->title_bar);
    lv_obj_set_size(win->min_btn, 48, 32);
    lv_obj_align(win->min_btn, LV_ALIGN_RIGHT_MID, -52, 0);
    /* Neutral title-bar styling: the default theme would paint it blue. */
    lv_obj_set_style_bg_color(win->min_btn, ui_theme_colors()->title, 0);
    lv_obj_set_style_bg_opa(win->min_btn, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(win->min_btn, 0, 0);
    lv_obj_set_style_radius(win->min_btn, 4, 0);
    lv_obj_set_style_shadow_width(win->min_btn, 0, 0);
    lv_obj_t *ml = lv_label_create(win->min_btn);
    lv_label_set_text(ml, LV_SYMBOL_MINUS);
    lv_obj_set_style_text_color(ml, ui_theme_colors()->text, 0);
    lv_obj_center(ml);
    lv_obj_add_event_cb(win->min_btn, min_event_cb, LV_EVENT_CLICKED, win);

    win->content = lv_obj_create(win->root);
    lv_obj_set_size(win->content, win->w - 8, win->h - 36 - 8);
    lv_obj_align(win->content, LV_ALIGN_BOTTOM_MID, 0, -4);
    lv_obj_set_style_bg_opa(win->content, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(win->content, 0, 0);
    lv_obj_set_style_pad_all(win->content, 8, 0);

    /* Games and apps attach LV_EVENT_KEY handlers to the content, so the
     * content itself is the keyboard focus object for this window. */
    lv_obj_add_flag(win->content, LV_OBJ_FLAG_CLICKABLE |
                                 LV_OBJ_FLAG_CLICK_FOCUSABLE);
    lv_group_t *group = lv_group_get_default();
    if (group) lv_group_add_obj(group, win->content);

    s_wins[s_count++] = win;
    taskbar_add(win);
    wm_focus(win);
    if (content_out) *content_out = win->content;
    /* 只失效新窗口占的那块（整屏失效代价太大：实测一帧被放大到 ~1960 万像素） */
    lv_obj_invalidate(win->root);
    if (s_taskbar) lv_obj_invalidate(s_taskbar);
    return win;
}

void wm_close(ui_window_t *win)
{
    if (!win) return;
    if (win->on_close) win->on_close(win);
    int idx = -1;
    for (int i = 0; i < s_count; i++) if (s_wins[i] == win) idx = i;
    if (idx >= 0) {
        for (int i = idx; i + 1 < s_count; i++) s_wins[i] = s_wins[i + 1];
        s_count--;
    }
    if (s_focus == win) s_focus = NULL;
    lv_area_t old_a; bool had_area = false;
    if (win->root) { lv_obj_get_coords(win->root, &old_a); had_area = true; }
    if (win->task_btn) lv_obj_delete(win->task_btn);
    if (win->root) lv_obj_delete(win->root);
    lv_free(win);
    if (!s_focus && s_count > 0) wm_focus(s_wins[s_count - 1]);
    else update_focus_style();
    /* 只重绘"窗口原来占的那块" + 任务栏。
     * ⚠️ 不要失效整屏：实测一帧会被放大到 ~1960 万像素（约 32 个整屏的过量绘制），
     *    切应用时会卡住/出现黑块 —— 那正是"结构性重绘有问题"的来源。 */
    if (had_area) lv_obj_invalidate_area(s_layer, &old_a);
    if (s_taskbar) lv_obj_invalidate(s_taskbar);
}

void wm_close_all(void)
{
    /* Pop from the top so wm_close() runs close callbacks, removes taskbar
     * buttons and frees every ui_window_t. */
    while (s_count > 0) {
        wm_close(s_wins[s_count - 1]);
    }
}

void wm_focus(ui_window_t *win)
{
    if (!win) return;
    s_focus = win;
    win->minimized = false;
    lv_obj_remove_flag(win->root, LV_OBJ_FLAG_HIDDEN);
    lv_obj_move_to_index(win->root, -1);

    lv_group_t *group = lv_group_get_default();
    if (group && win->content) {
        if (lv_obj_get_group(win->content) != group) {
            lv_group_add_obj(group, win->content);
        }
        lv_group_focus_obj(win->content);
    }
    update_focus_style();
    lv_obj_invalidate(win->root);   /* 只重绘该窗口（整屏失效代价见 wm_close 注释） */
}

void wm_minimize(ui_window_t *win)
{
    if (!win) return;
    win->minimized = true;
    lv_obj_add_flag(win->root, LV_OBJ_FLAG_HIDDEN);
    if (s_focus == win) s_focus = NULL;
    update_focus_style();
}

void wm_show_desktop(void)
{
    for (int i = 0; i < s_count; i++) {
        s_wins[i]->minimized = true;
        lv_obj_add_flag(s_wins[i]->root, LV_OBJ_FLAG_HIDDEN);
    }
    s_focus = NULL;
    update_focus_style();
}

void wm_close_focused(void)
{
    if (s_focus) wm_close(s_focus);
    else wm_show_desktop();
}

int wm_count(void) { return s_count; }

const char *wm_focused_title(void)
{
    return s_focus ? s_focus->title_text : NULL;
}

void wm_enable_bubble(lv_obj_t *obj)
{
    if (!obj) return;
    lv_obj_add_flag(obj, LV_OBJ_FLAG_EVENT_BUBBLE);
    uint32_t n = lv_obj_get_child_count(obj);
    for (uint32_t i = 0; i < n; i++) wm_enable_bubble(lv_obj_get_child(obj, i));
}

static void update_focus_style(void)
{
    for (int i = 0; i < s_count; i++) {
        ui_window_t *w = s_wins[i];
        bool f = (w == s_focus);
        lv_obj_set_style_border_color(w->root,
            f ? ui_theme_colors()->accent : ui_theme_colors()->border, 0);
        lv_obj_set_style_border_width(w->root, f ? 2 : 1, 0);
        if (w->task_btn) {
            lv_obj_set_style_bg_color(w->task_btn,
                f ? ui_theme_colors()->accent : ui_theme_colors()->panel, 0);
            lv_obj_t *l = lv_obj_get_child(w->task_btn, 0);
            if (l) lv_obj_set_style_text_color(l,
                f ? lv_color_white() : ui_theme_colors()->panel_text, 0);
        }
    }
}

static void focus_event_cb(lv_event_t *e)
{
    wm_focus((ui_window_t *)lv_event_get_user_data(e));
}

static void close_event_cb(lv_event_t *e)
{
    wm_close((ui_window_t *)lv_event_get_user_data(e));
}

static void min_event_cb(lv_event_t *e)
{
    wm_minimize((ui_window_t *)lv_event_get_user_data(e));
}

static void task_event_cb(lv_event_t *e)
{
    ui_window_t *w = (ui_window_t *)lv_event_get_user_data(e);
    if (w->minimized) wm_focus(w);
    else if (s_focus == w) wm_minimize(w);
    else wm_focus(w);
}

static void drag_event_cb(lv_event_t *e)
{
    ui_window_t *w = (ui_window_t *)lv_event_get_user_data(e);
    lv_event_code_t code = lv_event_get_code(e);
    static lv_point_t start_p;
    static int start_x, start_y;
    if (code == LV_EVENT_PRESSED) {
        lv_indev_t *indev = lv_indev_active();
        if (indev) lv_indev_get_point(indev, &start_p);
        start_x = lv_obj_get_x(w->root);
        start_y = lv_obj_get_y(w->root);
    } else if (code == LV_EVENT_PRESSING) {
        lv_indev_t *indev = lv_indev_active();
        if (!indev) return;
        lv_point_t p;
        lv_indev_get_point(indev, &p);
        int nx = start_x + (p.x - start_p.x);
        int ny = start_y + (p.y - start_p.y);
        if (nx < 0) nx = 0;
        if (ny < 0) ny = 0;
        if (nx > WM_DESKTOP_W - w->w) nx = WM_DESKTOP_W - w->w;
        if (ny > WM_DESKTOP_H - w->h) ny = WM_DESKTOP_H - w->h;
        lv_obj_set_pos(w->root, nx, ny);
    }
}
