#pragma once
#include "lvgl.h"
#include <stdbool.h>

typedef struct ui_window ui_window_t;
typedef void (*ui_close_cb_t)(ui_window_t *win);

void wm_init(lv_obj_t *window_layer, lv_obj_t *taskbar);
ui_window_t *wm_open(const char *title, int w, int h, bool maximized,
                     lv_obj_t **content_out, ui_close_cb_t on_close);
void wm_close(ui_window_t *win);
void wm_close_all(void);
void wm_focus(ui_window_t *win);
void wm_minimize(ui_window_t *win);
void wm_show_desktop(void);
void wm_close_focused(void);
int wm_count(void);
/* Title of the focused window, or NULL when the desktop has focus. */
const char *wm_focused_title(void);
void wm_enable_bubble(lv_obj_t *obj);
