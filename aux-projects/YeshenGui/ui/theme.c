#include "theme.h"

static bool s_dark;
static int s_wallpaper;
static ui_theme_colors_t s_light;
static ui_theme_colors_t s_dark_c;
static ui_theme_colors_t s_now;

void ui_theme_init(void)
{
    s_light = (ui_theme_colors_t){
        .bg = LV_COLOR_MAKE(0x12, 0x18, 0x20),
        .panel = LV_COLOR_MAKE(0xE9, 0xED, 0xF2),
        .panel_text = LV_COLOR_MAKE(0x1F, 0x29, 0x33),
        .window = LV_COLOR_MAKE(0xF7, 0xF9, 0xFC),
        .border = LV_COLOR_MAKE(0xC9, 0xD1, 0xDB),
        .title = LV_COLOR_MAKE(0xDD, 0xE3, 0xEA),
        .text = LV_COLOR_MAKE(0x1F, 0x29, 0x33),
        .accent = LV_COLOR_MAKE(0xA8, 0x00, 0x30),
        .success = LV_COLOR_MAKE(0x2E, 0x7D, 0x32),
        .warning = LV_COLOR_MAKE(0xE0, 0xA1, 0x00),
    };
    s_dark_c = (ui_theme_colors_t){
        .bg = LV_COLOR_MAKE(0x1F, 0x29, 0x33),
        .panel = LV_COLOR_MAKE(0x1F, 0x29, 0x33),
        .panel_text = LV_COLOR_MAKE(0xF5, 0xF7, 0xFA),
        .window = LV_COLOR_MAKE(0x2B, 0x34, 0x40),
        .border = LV_COLOR_MAKE(0x3E, 0x4C, 0x59),
        .title = LV_COLOR_MAKE(0x34, 0x41, 0x4F),
        .text = LV_COLOR_MAKE(0xF5, 0xF7, 0xFA),
        .accent = LV_COLOR_MAKE(0xE5, 0x48, 0x4D),
        .success = LV_COLOR_MAKE(0x4C, 0xAF, 0x50),
        .warning = LV_COLOR_MAKE(0xFF, 0xC1, 0x07),
    };
    s_dark = false;
    /* 0 = ink（深色近黑，均值 RGB(9,16,21)），1 = paper（浅色，均值 (218,227,233)）。
     * 默认给 paper：所谓 "Debian 风格" 的观感是浅色底，ink 在板上看上去就是"黑屏"。
     * 用户仍可在 Settings 里切回 ink。 */
    s_wallpaper = 1;
    s_now = s_light;
}

bool ui_theme_is_dark(void) { return s_dark; }
void ui_theme_set_dark(bool dark) { s_dark = dark; s_now = dark ? s_dark_c : s_light; }
const ui_theme_colors_t *ui_theme_colors(void) { return &s_now; }
int ui_theme_wallpaper(void) { return s_wallpaper; }
void ui_theme_set_wallpaper(int index) { s_wallpaper = index ? 1 : 0; }
