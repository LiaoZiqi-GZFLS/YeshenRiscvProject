/* Board touch/key input: GT911 via goodix evdev + KEY4 via gpio-keys.
 *
 * The touch link runs on its own thread (started by ui/app.c): it blocks in
 * poll() on the evdev node and keeps a normalised (x, y, pressed) snapshot.
 * lv_indev reads that snapshot, so a long LVGL redraw can no longer delay
 * input sampling, and the per-sample EVIOCGABS ioctls are gone (the abs
 * ranges are queried once at open). Without the thread (e.g. --touch-probe)
 * the old synchronous drain is used. */
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE 1
#endif

#include "board_touch.h"

#include "platform.h"

#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <linux/input.h>
#include <poll.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static int s_touch_fd = -1;
static bool s_touch_tried;
static int s_keys_fd = -1;
static bool s_keys_tried;

static int s_max_x = UI_SCREEN_W - 1;
static int s_max_y = UI_SCREEN_H - 1;

static int s_x = UI_SCREEN_W / 2;
static int s_y = UI_SCREEN_H / 2;
static bool s_pressed;

/* Raw values since the last SYN_REPORT and the last scaled pair. */
static int s_raw_x = -1, s_raw_y = -1;
static int s_last_raw_x = -1, s_last_raw_y = -1;

static pthread_mutex_t s_state = PTHREAD_MUTEX_INITIALIZER;
static pthread_t s_thread;
static bool s_thread_on;
static volatile bool s_thread_stop;

static bool bit_set(const unsigned long *bits, int bit)
{
    return !!(bits[bit / (int)(8 * sizeof(unsigned long))] &
              (1UL << (bit % (int)(8 * sizeof(unsigned long)))));
}

static int open_touch_event(void)
{
    glob_t g;
    int found = -1;
    if (glob("/dev/input/event*", GLOB_NOSORT, NULL, &g) != 0) return -1;

    for (size_t i = 0; i < g.gl_pathc && found < 0; i++) {
        int fd = open(g.gl_pathv[i], O_RDONLY | O_NONBLOCK);
        if (fd < 0) continue;
        unsigned long evbits[4] = {0};
        unsigned long absbits[4] = {0};
        if (ioctl(fd, EVIOCGBIT(0, sizeof(evbits)), evbits) < 0 ||
            !bit_set(evbits, EV_ABS) ||
            ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(absbits)), absbits) < 0 ||
            (!bit_set(absbits, ABS_X) && !bit_set(absbits, ABS_MT_POSITION_X))) {
            close(fd);
            continue;
        }
        found = fd;
    }
    globfree(&g);
    return found;
}

static int open_keys_event(void)
{
    glob_t g;
    int found = -1;
    if (glob("/dev/input/event*", GLOB_NOSORT, NULL, &g) != 0) return -1;

    for (size_t i = 0; i < g.gl_pathc && found < 0; i++) {
        int fd = open(g.gl_pathv[i], O_RDONLY | O_NONBLOCK);
        if (fd < 0) continue;
        unsigned long evbits[4] = {0};
        unsigned long keybits[(KEY_MAX + 1 + 8 * sizeof(unsigned long) - 1) /
                              (8 * sizeof(unsigned long))] = {0};
        if (ioctl(fd, EVIOCGBIT(0, sizeof(evbits)), evbits) < 0 ||
            !bit_set(evbits, EV_KEY) ||
            ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keybits)), keybits) < 0 ||
            !bit_set(keybits, KEY_F13)) {
            close(fd);
            continue;
        }
        found = fd;
    }
    globfree(&g);
    return found;
}

static int scale_abs(int raw, int max, int screen)
{
    if (max <= 0) return raw < 0 ? 0 : (raw >= screen ? screen - 1 : raw);
    long v = (long)raw * (screen - 1) / max;
    if (v < 0) v = 0;
    if (v > screen - 1) v = screen - 1;
    return (int)v;
}

static void touch_open(void)
{
    if (s_touch_tried) return;
    s_touch_tried = true;
    s_touch_fd = open_touch_event();
    if (s_touch_fd < 0) {
        platform_log("touch: no evdev ABS device");
        return;
    }

    struct input_absinfo xi = {0}, yi = {0};
    if (ioctl(s_touch_fd, EVIOCGABS(ABS_X), &xi) == 0 && xi.maximum > 0) {
        s_max_x = xi.maximum;
    } else if (ioctl(s_touch_fd, EVIOCGABS(ABS_MT_POSITION_X), &xi) == 0 &&
               xi.maximum > 0) {
        s_max_x = xi.maximum;
    }
    if (ioctl(s_touch_fd, EVIOCGABS(ABS_Y), &yi) == 0 && yi.maximum > 0) {
        s_max_y = yi.maximum;
    } else if (ioctl(s_touch_fd, EVIOCGABS(ABS_MT_POSITION_Y), &yi) == 0 &&
               yi.maximum > 0) {
        s_max_y = yi.maximum;
    }
}

static void keys_open(void)
{
    if (s_keys_tried) return;
    s_keys_tried = true;
    s_keys_fd = open_keys_event();
    if (s_keys_fd < 0) platform_log("keys: no evdev KEY_F13 device");
}

static void touch_handle(const struct input_event *ev)
{
    if (ev->type == EV_ABS) {
        if (ev->code == ABS_X || ev->code == ABS_MT_POSITION_X) {
            s_raw_x = ev->value;
        } else if (ev->code == ABS_Y || ev->code == ABS_MT_POSITION_Y) {
            s_raw_y = ev->value;
        } else if (ev->code == ABS_MT_TRACKING_ID) {
            s_pressed = ev->value >= 0;
        }
    } else if (ev->type == EV_KEY && ev->code == BTN_TOUCH) {
        s_pressed = ev->value != 0;
    } else if (ev->type == EV_SYN && ev->code == SYN_REPORT) {
        int rx = s_raw_x >= 0 ? s_raw_x : s_last_raw_x;
        int ry = s_raw_y >= 0 ? s_raw_y : s_last_raw_y;
        if ((s_raw_x >= 0 || s_raw_y >= 0) &&
            !(rx == s_last_raw_x && ry == s_last_raw_y)) {
            s_x = scale_abs(rx, s_max_x, UI_SCREEN_W);
            s_y = scale_abs(ry, s_max_y, UI_SCREEN_H);
            s_last_raw_x = rx;
            s_last_raw_y = ry;
        }
        s_raw_x = -1;
        s_raw_y = -1;
    }
}

static void touch_drain(void)
{
    struct input_event ev;
    while (read(s_touch_fd, &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) {
        touch_handle(&ev);
    }
}

static void *touch_worker(void *arg)
{
    (void)arg;
    while (!s_thread_stop) {
        struct pollfd p = { .fd = s_touch_fd, .events = POLLIN, .revents = 0 };
        if (poll(&p, 1, 50) <= 0) continue;
        pthread_mutex_lock(&s_state);
        touch_drain();
        pthread_mutex_unlock(&s_state);
    }
    return NULL;
}

void platform_touch_service_start(void)
{
    touch_open();
    if (s_touch_fd < 0 || s_thread_on) return;
    s_thread_stop = false;
    if (pthread_create(&s_thread, NULL, touch_worker, NULL) != 0) {
        platform_log("touch: no service thread; sampling inline");
        return;
    }
    s_thread_on = true;
    platform_log("YGUI-TOUCH-SVC");
}

bool platform_poll_touch(int *x, int *y, bool *pressed)
{
    touch_open();
    if (s_touch_fd < 0) {
        if (x) *x = 0;
        if (y) *y = 0;
        if (pressed) *pressed = false;
        return false;
    }

    int sx, sy;
    bool sp;
    if (s_thread_on) {
        pthread_mutex_lock(&s_state);
        sx = s_x;
        sy = s_y;
        sp = s_pressed;
        pthread_mutex_unlock(&s_state);
    } else {
        touch_drain();
        sx = s_x;
        sy = s_y;
        sp = s_pressed;
    }

    if (x) *x = sx;
    if (y) *y = sy;
    if (pressed) *pressed = sp;
    return true;
}

bool board_key3_poll(ui_key_t *key)
{
    keys_open();
    if (s_keys_fd < 0) return false;

    struct input_event ev;
    while (read(s_keys_fd, &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) {
        /* Both edges are reported: consumers that only want presses test
         * `ch`, the embedded Game Boy uses it as a held A button. */
        if (ev.type == EV_KEY && ev.code == KEY_F13) {
            if (key) {
                key->type = UI_KEY_KEY3;
                key->ch = (char)(ev.value ? 1 : 0);
            } else if (ev.value == 0) {
                continue;
            }
            return true;
        }
    }
    return false;
}

void platform_touch_probe(int seconds)
{
    touch_open();
    keys_open();
    if (s_touch_fd < 0) {
        printf("TOUCH none\n");
        fflush(stdout);
        return;
    }

    printf("TOUCH abs x=0..%d y=0..%d keys=%d\n", s_max_x, s_max_y,
           s_keys_fd >= 0);
    fflush(stdout);

    uint32_t end = platform_time_ms() + (uint32_t)(seconds > 0 ? seconds : 15) * 1000u;
    while ((int32_t)(platform_time_ms() - end) < 0) {
        struct input_event ev;
        bool have = false;
        while (read(s_touch_fd, &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) {
            touch_handle(&ev);
            if (ev.type == EV_SYN && ev.code == SYN_REPORT) have = true;
        }
        if (have) {
            printf("TOUCH scaled=%d,%d pressed=%d\n", s_x, s_y, s_pressed);
            fflush(stdout);
        }
        if (board_key3_poll(NULL)) {
            printf("TOUCH key4 press\n");
            fflush(stdout);
        }
        platform_delay_ms(5);
    }
    printf("TOUCH probe done\n");
    fflush(stdout);
}
