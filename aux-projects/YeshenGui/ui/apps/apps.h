#pragma once

#include "platform.h"

void app_system_info_open(void);
void app_files_open(void);
void app_settings_open(void);
void app_cube3d_open(void);
void app_cube3d_close(void);
void game_2048_open(void);
void game_minesweeper_open(void);
void game_snake_open(void);

void terminal_open(void);
void terminal_close(void);
bool terminal_is_open(void);
void terminal_handle_key(const ui_key_t *key);
/* Test/demo hooks: press an on-screen key by its label, or click a toolbar
 * button by its label; both return false when the label is not present. */
bool terminal_osk_press(const char *text);
bool terminal_osk_click(const char *text);
bool terminal_osk_visible(void);
/* Demo hook: push UTF-8 text straight into the screen model (no PTY). */
void terminal_demo_feed(const char *utf8);
