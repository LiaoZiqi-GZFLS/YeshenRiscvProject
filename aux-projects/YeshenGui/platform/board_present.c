/* Board present service: asynchronous framebuffer flush.
 *
 * Why: the LCD scans the GUI buffer continuously while the CPU writes it. The
 * LVGL flush callback used to memcpy each 100-row strip straight into /dev/mem
 * (uncached, shared with two camera writers), so a full-window redraw blocked
 * the UI thread for tens of milliseconds and the touch/key polling that runs
 * in that thread stalled with it -- the user saw bands appear top to bottom.
 *
 * Now flush_cb copies the strip into one of a small pool of cached staging
 * slots and returns immediately (LVGL may reuse its draw buffer at once); a
 * worker thread drains the slots into the framebuffer in order. The UI thread
 * keeps rendering and sampling input while DDR writes are in flight; with
 * three or four slots the queue absorbs a whole full-screen redraw.
 */
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE 1
#endif

#include "platform.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

/* Must cover the tallest rect LVGL hands us: its draw buffer is
 * UI_SCREEN_W x 100 pixels (ui/app.c g_buf1/g_buf2). */
#define PRESENT_ROWS 100
#define PRESENT_SLOTS 4

typedef struct {
    int x1, y1, x2, y2;
    int w, h;
} present_job_t;

static uint16_t *s_px[PRESENT_SLOTS];
static present_job_t s_job[PRESENT_SLOTS];
static bool s_busy[PRESENT_SLOTS];
static int s_q[PRESENT_SLOTS];
static int s_qh, s_qt, s_qn;

static pthread_mutex_t s_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t s_work = PTHREAD_COND_INITIALIZER;
static pthread_cond_t s_free = PTHREAD_COND_INITIALIZER;
static pthread_t s_thread;
static bool s_started;
static bool s_stop;

static void *present_worker(void *arg)
{
    (void)arg;
    for (;;) {
        pthread_mutex_lock(&s_lock);
        while (s_qn == 0 && !s_stop) pthread_cond_wait(&s_work, &s_lock);
        if (s_qn == 0) {           /* s_stop && queue drained */
            pthread_mutex_unlock(&s_lock);
            break;
        }
        int slot = s_q[s_qh];
        s_qh = (s_qh + 1) % PRESENT_SLOTS;
        s_qn--;
        present_job_t job = s_job[slot];
        uint16_t *px = s_px[slot];
        pthread_mutex_unlock(&s_lock);

        ui_surface_t s = {
            .width = job.w,
            .height = job.h,
            .pixels = px,
            .stride_px = job.w,
        };
        platform_flush(&s, job.x1, job.y1, job.x2, job.y2);

        pthread_mutex_lock(&s_lock);
        s_busy[slot] = false;
        pthread_cond_signal(&s_free);
        pthread_mutex_unlock(&s_lock);
    }
    return NULL;
}

void platform_present_start(void)
{
    if (s_started) return;
    for (int i = 0; i < PRESENT_SLOTS; i++) {
        s_px[i] = malloc((size_t)UI_SCREEN_W * PRESENT_ROWS * 2);
        if (!s_px[i]) {
            for (int j = 0; j < i; j++) {
                free(s_px[j]);
                s_px[j] = NULL;
            }
            platform_log("present: no memory; flushing inline");
            return;
        }
        s_busy[i] = false;
    }
    s_qh = s_qt = s_qn = 0;
    s_stop = false;
    if (pthread_create(&s_thread, NULL, present_worker, NULL) != 0) {
        for (int i = 0; i < PRESENT_SLOTS; i++) {
            free(s_px[i]);
            s_px[i] = NULL;
        }
        platform_log("present: pthread_create failed; flushing inline");
        return;
    }
    s_started = true;
    platform_log("YGUI-PRESENT async");
}

void platform_present_stop(void)
{
    if (!s_started) return;
    pthread_mutex_lock(&s_lock);
    s_stop = true;
    pthread_cond_broadcast(&s_work);
    pthread_mutex_unlock(&s_lock);
    pthread_join(s_thread, NULL);
    for (int i = 0; i < PRESENT_SLOTS; i++) {
        free(s_px[i]);
        s_px[i] = NULL;
    }
    s_started = false;
}

void platform_present(const ui_surface_t *surface, int x1, int y1, int x2, int y2)
{
    int w = x2 - x1 + 1;
    int h = y2 - y1 + 1;
    if (!s_started || !surface || !surface->pixels || w <= 0 || h <= 0 ||
        w > UI_SCREEN_W || h > PRESENT_ROWS || surface->stride_px < w) {
        platform_flush(surface, x1, y1, x2, y2);
        return;
    }

    pthread_mutex_lock(&s_lock);
    int slot = -1;
    for (;;) {
        for (int i = 0; i < PRESENT_SLOTS; i++) {
            if (!s_busy[i]) {
                slot = i;
                break;
            }
        }
        if (slot >= 0) break;
        pthread_cond_wait(&s_free, &s_lock);
    }
    s_busy[slot] = true;
    pthread_mutex_unlock(&s_lock);

    uint16_t *dst = s_px[slot];
    const uint16_t *src = surface->pixels;
    for (int r = 0; r < h; r++) {
        memcpy(dst + (size_t)r * (size_t)w,
               src + (size_t)r * (size_t)surface->stride_px, (size_t)w * 2);
    }

    pthread_mutex_lock(&s_lock);
    s_job[slot].x1 = x1;
    s_job[slot].y1 = y1;
    s_job[slot].x2 = x2;
    s_job[slot].y2 = y2;
    s_job[slot].w = w;
    s_job[slot].h = h;
    s_q[s_qt] = slot;
    s_qt = (s_qt + 1) % PRESENT_SLOTS;
    s_qn++;
    pthread_cond_signal(&s_work);
    pthread_mutex_unlock(&s_lock);
}
