#pragma once

#include "platform.h"

/* Poll the gpio-keys KEY3 event (goodix touch is handled by
 * platform_poll_touch in board_touch.c). Returns true when a press was
 * queued. */
bool board_key3_poll(ui_key_t *key);
