#include "assets.h"
#include "platform.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

bool ui_wallpaper_load(ui_wallpaper_t *wp, const char *name)
{
    memset(wp, 0, sizeof(*wp));
    char path[256];
    snprintf(path, sizeof(path), "%s/%s.bin", platform_asset_dir(), name);

    FILE *f = fopen(path, "rb");
    if (!f) {
        platform_log("wallpaper: missing file");
        return false;
    }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size != UI_SCREEN_W * UI_SCREEN_H * 2) {
        fclose(f);
        platform_log("wallpaper: wrong size");
        return false;
    }
    wp->data = malloc((size_t)size);
    if (!wp->data || fread(wp->data, 1, (size_t)size, f) != (size_t)size) {
        free(wp->data);
        wp->data = NULL;
        fclose(f);
        platform_log("wallpaper: read failed");
        return false;
    }
    fclose(f);

    wp->dsc.header.magic = LV_IMAGE_HEADER_MAGIC;
    wp->dsc.header.cf = LV_COLOR_FORMAT_RGB565;
    wp->dsc.header.w = UI_SCREEN_W;
    wp->dsc.header.h = UI_SCREEN_H;
    wp->dsc.header.stride = UI_SCREEN_W * 2;
    wp->dsc.data_size = (uint32_t)size;
    wp->dsc.data = wp->data;
    return true;
}

void ui_wallpaper_free(ui_wallpaper_t *wp)
{
    free(wp->data);
    memset(wp, 0, sizeof(*wp));
}
