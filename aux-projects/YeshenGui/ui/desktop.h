#pragma once
#include "lvgl.h"
#include <stdbool.h>

void desktop_init(void);
void desktop_set_wallpaper(int index);
void desktop_apply_theme(void);
void desktop_camera_mode_changed(bool camera);
/* Stop y1cam, clear the overlay boxes and hand the LCD back to the GUI.
 * Shared by KEY4, the hot corner and the keyboard. */
void desktop_camera_leave(void);
/* Open the camera card (same as clicking the Camera icon). */
void desktop_open_camera(void);
void desktop_demo_start(const char *screenshot_dir);
void desktop_open_placeholder(const char *title);
void desktop_open_games(void);
void desktop_open_gb(void);
/* Dev hook: open the embedded Game Boy player straight on one ROM. */
void desktop_open_gb_rom(const char *path);

/* True once the scripted demo has written its two screenshots. */
bool desktop_demo_done(void);
