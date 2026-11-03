#pragma once
#include "lvgl.h"
#include <stdbool.h>

typedef struct {
    uint8_t *data;
    lv_image_dsc_t dsc;
} ui_wallpaper_t;

bool ui_wallpaper_load(ui_wallpaper_t *wp, const char *name);
void ui_wallpaper_free(ui_wallpaper_t *wp);
