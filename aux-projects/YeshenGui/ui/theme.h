#pragma once
#include "lvgl.h"
#include <stdbool.h>

typedef struct {
    lv_color_t bg;
    lv_color_t panel;
    lv_color_t panel_text;
    lv_color_t window;
    lv_color_t border;
    lv_color_t title;
    lv_color_t text;
    lv_color_t accent;
    lv_color_t success;
    lv_color_t warning;
} ui_theme_colors_t;

void ui_theme_init(void);
bool ui_theme_is_dark(void);
void ui_theme_set_dark(bool dark);
const ui_theme_colors_t *ui_theme_colors(void);
int ui_theme_wallpaper(void);
void ui_theme_set_wallpaper(int index);
