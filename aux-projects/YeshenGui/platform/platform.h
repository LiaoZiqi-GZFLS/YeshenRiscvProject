#pragma once

#include <stdbool.h>
#include <stdint.h>

#define UI_SCREEN_W 1024
#define UI_SCREEN_H 600

typedef enum {
    UI_KEY_NONE = 0,
    UI_KEY_TAB,
    UI_KEY_ENTER,
    UI_KEY_ESC,
    UI_KEY_BACKSPACE,
    UI_KEY_UP,
    UI_KEY_DOWN,
    UI_KEY_LEFT,
    UI_KEY_RIGHT,
    UI_KEY_CHAR,
    UI_KEY_CTRL_C,
    UI_KEY_CTRL_D,
    UI_KEY_CTRL_W,
    UI_KEY_KEY3,
} ui_key_type_t;

typedef struct {
    ui_key_type_t type;
    char ch;
} ui_key_t;

typedef struct {
    int width;
    int height;
    uint16_t *pixels;  /* RGB565, stride_px pixels per row */
    int stride_px;
} ui_surface_t;

void platform_init(int width, int height);
void platform_shutdown(void);
void platform_flush(const ui_surface_t *surface, int x1, int y1, int x2, int y2);

/* Display service: queue a flushed area to the board's present worker so the
 * UI thread does not block on uncached DDR writes. Host writes inline. */
void platform_present_start(void);
void platform_present_stop(void);
void platform_present(const ui_surface_t *surface, int x1, int y1, int x2, int y2);
/* Touch service: blocking evdev reader thread keeping an (x,y,pressed)
 * snapshot; platform_poll_touch then costs no syscall. */
void platform_touch_service_start(void);
uint32_t platform_time_ms(void);
void platform_delay_ms(uint32_t ms);
bool platform_should_quit(void);

/* Host returns true with mouse coordinates; board Phase S returns false. */
bool platform_poll_touch(int *x, int *y, bool *pressed);
/* Board touch calibration aid: log raw/scaled evdev samples for N seconds. */
void platform_touch_probe(int seconds);
/* Host/SDL and board UART keyboard. */
bool platform_poll_key(ui_key_t *key);

const char *platform_asset_dir(void);
void platform_log(const char *message);

/* Board Phase R: switch the LCD between the GUI framebuffers (false) and the
 * live camera (true). The host backend logs and keeps the GUI. */
void platform_set_camera_mode(bool on);
bool platform_camera_mode(void);

/* Board Phase R: which camera feeds the framebuffer (CAM_CTRL[0], 0 = CAM0,
 * 1 = CAM1). The camera app applies the persisted default at startup. */
void platform_set_camera_source(int src);
int platform_camera_source(void);
/* Disable the VIDEO overlay boxes (used when face detection is turned off). */
void platform_clear_overlay(void);
/* Stop using /dev/ttyS0 as a key source (getty owns the console on boot). */
void platform_uart_keyboard_disable(void);

/* ---- ★ GPU DIRECT 模式（YESHEN_GUI_GPU_UNIT）----
 * LVGL 直接画进这块全屏 RGB565 缓冲，GPU 也写它：
 *   · 主机 = SDL 影子缓冲（g_shadow）；
 *   · 板端 = GUI 帧存（0xBE00_0000，非缓存映射）。
 * 返回 NULL ⇒ 这个后端没有可直写的帧存（调用方退回 PARTIAL 模式）。 */
uint16_t *platform_framebuffer(void);
/* 帧存物理基址（主机没有物理地址 ⇒ 返回 0）。 */
uint32_t platform_framebuffer_phys(void);
/* 整屏推到显示：主机上传整张纹理；板端 no-op（LCD 直接扫 DDR）。 */
void platform_present_full(void);

/* 主线 GPU 变体：让 LCD **固定读 bank1**（GUI_CTRL[1]=1 且不再 FLIP）。
 * 单缓冲直接画进被扫描的 bank 会"每帧都看得见"⇒ 闪烁；改成只画 bank0、
 * 每帧用一次硬件 BLIT 整帧镜像到 bank1（见 ui/app.c flush_cb_gpu）。 */
void platform_gui_use_bank1(void);

#ifdef UI_HOST
void platform_screenshot(const char *path);
#endif
