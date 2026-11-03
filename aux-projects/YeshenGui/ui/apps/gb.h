#pragma once

#include "lvgl.h"

/* Embedded Peanut-GB player: renders 160x144 into an LVGL canvas inside an
 * ordinary yshell window (no full-screen hand-off, no separate process). */
void gb_embed_open(lv_obj_t *parent, const char *rom_path);
void gb_embed_close(void);
/* Physical KEY4: 1 while held, 0 on release. Mapped to the A button so a
 * direction can be held on the touch pad at the same time. */
void gb_embed_key(int pressed);
bool gb_embed_running(void);
uint32_t gb_embed_frames(void);
