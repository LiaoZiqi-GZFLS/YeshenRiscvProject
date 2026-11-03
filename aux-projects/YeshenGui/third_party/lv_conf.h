#ifndef LV_CONF_H
#define LV_CONF_H

#define LV_COLOR_DEPTH 16
#define LV_USE_OS LV_OS_NONE
#define LV_USE_STDLIB_MALLOC LV_STDLIB_BUILTIN
#define LV_MEM_SIZE (2 * 1024 * 1024)
#define LV_DEF_REFR_PERIOD 16
#define LV_DPI_DEF 130

#define LV_USE_LOG 1
#define LV_LOG_LEVEL LV_LOG_LEVEL_WARN
#define LV_LOG_PRINTF 1

#define LV_USE_ASSERT_NULL 0
#define LV_USE_ASSERT_MALLOC 0
#define LV_USE_ASSERT_STYLE 0
#define LV_USE_ASSERT_MEM_INTEGRITY 0
#define LV_USE_ASSERT_OBJ 0

#define LV_FONT_MONTSERRAT_14 1
#define LV_FONT_MONTSERRAT_16 1
#define LV_FONT_MONTSERRAT_20 1
#define LV_FONT_MONTSERRAT_24 1
#define LV_FONT_UNSCII_16 1
#define LV_FONT_UNSCII_8 1
/* CJK font (Noto Sans Mono CJK SC, ui/fonts/lv_font_cjk_16.c) has >1 MiB of
 * glyph bitmap, which needs 32-bit bitmap_index in the fmt_txt tables. */
#define LV_FONT_FMT_TXT_LARGE 1
#define LV_FONT_DEFAULT &lv_font_montserrat_14

#define LV_USE_THEME_DEFAULT 1
#define LV_USE_THEME_SIMPLE 1
#define LV_USE_FLEX 1
#define LV_USE_GRID 1

#define LV_USE_IMAGE 1
#define LV_USE_LABEL 1
#define LV_USE_BUTTON 1
#define LV_USE_BUTTONMATRIX 1
#define LV_USE_TEXTAREA 1
#define LV_USE_KEYBOARD 1
#define LV_USE_CANVAS 1
#define LV_USE_SLIDER 1
#define LV_USE_SWITCH 1
#define LV_USE_MSGBOX 1
#define LV_USE_BAR 1
#define LV_USE_LINE 1

#define LV_USE_PERF_MONITOR 0
#define LV_USE_MEM_MONITOR 0
#define LV_USE_SYSMON 0

#endif
