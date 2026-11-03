/* Board display backend: RGB565 into DDR framebuffers.
 *
 * The LCD scans rows 60..659 of a 1024x720 frame (stride 2048 B). Two mutually
 * exclusive app variants exist; each is paired with its own bitstream and
 * image, and they must never be mixed:
 *
 *  - Default (BOARD_GUI_SECOND_BUF undefined): freeze/bank pair (historical:
 *    paired with the pre-carve 7092e495 bitstream). Every flush writes camera
 *    bank 0 (0xBC00_0000) only; bank 1 (0xBD00_0000) is not written (writing
 *    both only doubled DDR traffic); VIDEO GUI_CTRL (0xF0007494) freezes camera
 *    writes and makes the LCD read bank 0. In camera mode the flush is skipped
 *    so the live feed keeps both banks.
 *
 *  - BOARD_GUI_SECOND_BUF: second-framebuffer pair (current board build:
 *    GUI_VARIANT=mainline_gpu ⇒ BOARD_GUI_MAINLINE + GPU unit).
 *    The camera keeps writing its own banks; the GUI owns a separate
 *    1024x720 RGB565 buffer at 0xBE00_0000 (video AXI word 0x0F80_0000).
 *    GUI_CTRL bit0 only selects the LCD read source (1 = GUI, 0 = camera);
 *    there is no freeze. Flush writes rows 60..659 of the GUI buffer and is
 *    skipped in camera mode; ui/app.c redraws the screen on return.
 *
 * The keyboard backend lives in platform/input_uart.c. */
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE 1
#endif
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include "platform.h"

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#ifdef BOARD_GUI_SECOND_BUF
/* Phase R second framebuffer: 1024x720 RGB565 (1,474,560 B), page-aligned.
 * The RTL reads it when GUI_CTRL[0]=1 (video word 0x0F80_0000 = byte 0xBE00_0000).
 * The whole video/GPU carve now lives at the top of DDR: 0xBC00_0000..0xC000_0000. */
#define GUI_BUF_PHYS 0xBE000000UL
#ifdef BOARD_GUI_MAINLINE
#define GUI_VARIANT_NAME "mainline"
#else
#define GUI_VARIANT_NAME "gui2"
#endif
#else
#define FB0_PHYS 0xBC000000UL
#define FB1_PHYS 0xBD000000UL
#endif
#define FB_W 1024
#define FB_H 720
#define FB_BYTES ((size_t)FB_W * FB_H * 2)
#define FB_ROW_OFFSET 60

/* VIDEO CSR window is 0xF0007400..0xF00077FF. mmap() needs a page-aligned
 * offset, so map the 4 KiB page containing it and index from the page base.
 *   freeze/bank: bit0 GUI mode (freeze camera, LCD reads bank 0),
 *                bit1 gui_bank (0 selects bank 0).
 *   second buf:  bit0 gui_src (0 = camera bank, 1 = GUI buffer 0xBE00_0000);
 *                bit1 reserved.
 * Camera mode = 0, GUI mode = 0x1 in both variants.
 *
 * ★ GUI_CTRL 的窗内偏移两套 RTL 不同（**不能混用**）：
 *   YeshenGuiRtl / YeshenGuiRtl2 : +0x094 → 0xF000_7494（bit1 = gui_bank）
 *   VexiiYeshenLinux 主线        : +0x09C → 0xF000_749C（0x094 在主线上是 ETH_CTRL）
 * 缺省 0x094（既有 freeze/bank 与第二帧存两对 app/比特流/镜像逐字节不变）；
 * 主线变体由 -DBOARD_GUI_MAINLINE=ON 传下 0x49C。 */
#define VIDEO_PAGE_PHYS 0xF0007000UL
#define VIDEO_PAGE_BYTES 0x1000UL
#ifndef VIDEO_GUI_CTRL_OFF
#define VIDEO_GUI_CTRL_OFF 0x494UL
#endif
/* CAM_CTRL and OVERLAY_CTRL are shared by both RTL variants (same offsets
 * **from the 0xF0007400 window base**, not from the mmap page base):
 *   OVERLAY_CTRL   0x008 → page offset 0x408
 *   CAM_CTRL       0x00C → page offset 0x40C
 * ★ 0x008 is NOT decoded by the SoC: a store there raises a bus error
 *   (store/AMO access fault) and kills the process — verified on the board
 *   with devmem 0xF0007008. Everything must be window_base + 0x400. */
#define VIDEO_CAM_CTRL_OFF 0x40CUL
#define VIDEO_OVERLAY_CTRL_OFF 0x408UL
_Static_assert(VIDEO_GUI_CTRL_OFF >= 0x400UL, "GUI_CTRL must sit in 0xF0007400..77FF");
_Static_assert(VIDEO_CAM_CTRL_OFF >= 0x400UL, "CAM_CTRL must sit in 0xF0007400..77FF");
_Static_assert(VIDEO_OVERLAY_CTRL_OFF >= 0x400UL,
               "OVERLAY_CTRL must sit in 0xF0007400..77FF");
#ifdef BOARD_GUI_SECOND_BUF
#define VIDEO_GUI_CTRL_GUI_SRC 0x1u
#else
#define VIDEO_GUI_CTRL_GUI_MODE 0x1u
#endif

static int s_mem_fd = -1;
#ifdef BOARD_GUI_SECOND_BUF
static void *s_gui_buf;
#else
static void *s_fb0;
static void *s_fb1;
#endif
static bool s_fb_ok;
static void *s_video_page;
static volatile uint32_t *s_gui_ctrl;
static volatile uint32_t *s_cam_ctrl;
static volatile uint32_t *s_overlay_ctrl;
static bool g_camera_mode;

typedef uint32_t __attribute__((may_alias)) u32_alias;

static void log_errno(const char *what)
{
    char msg[256];
    snprintf(msg, sizeof(msg), "board_fb: %s: %s", what, strerror(errno));
    platform_log(msg);
}

void platform_gui_use_bank1(void)
{
#ifdef BOARD_GUI_SECOND_BUF
    if (!s_gui_ctrl) {
        platform_log("board_fb: GUI_CTRL is not mapped; gui_bank polarity unchanged");
        return;
    }
    /* bit0 = GUI 读源；bit1 = bank 反相 ⇒ LCD 读 bank1（bank0 留给 LVGL 画） */
    *s_gui_ctrl = VIDEO_GUI_CTRL_GUI_SRC | 0x2u;
    __sync_synchronize();
    platform_log("board_fb: LCD keeps reading bank1 (GUI_CTRL[1]=1, no flip)");
#endif
}

void platform_set_camera_mode(bool on)
{
    if (!s_gui_ctrl) {
        platform_log("board_fb: GUI_CTRL is not mapped; mode unchanged");
        return;
    }

    /* Entering camera mode: stop flushing first, then hand the LCD over.
     * Returning to GUI: select the GUI source first, then resume flushing.
     * In the second-buffer variant only the LCD read source changes; camera
     * writes keep running, and the RTL latches the source at the LCD
     * read-frame start, so the switch cannot tear the current frame. */
#ifdef BOARD_GUI_SECOND_BUF
    const uint32_t want_gui = VIDEO_GUI_CTRL_GUI_SRC;
#else
    const uint32_t want_gui = VIDEO_GUI_CTRL_GUI_MODE;
#endif
    const uint32_t want = on ? 0u : want_gui;

    if (on) {
        g_camera_mode = true;
        *s_gui_ctrl = want;
    } else {
        *s_gui_ctrl = want;
        g_camera_mode = false;
    }
    __sync_synchronize();

    uint32_t got = *s_gui_ctrl;
    char msg[128];
    snprintf(msg, sizeof(msg),
             "YGUI-CAMERA %s GUI_CTRL=0x%lx readback=0x%lx",
             on ? "camera" : "gui", (unsigned long)want, (unsigned long)got);
    platform_log(msg);
    if (got != want) {
        platform_log("board_fb: GUI_CTRL readback mismatch (new RTL required?)");
    }
}

bool platform_camera_mode(void)
{
    return g_camera_mode;
}

void platform_set_camera_source(int src)
{
    if (!s_cam_ctrl) {
        platform_log("board_fb: CAM_CTRL is not mapped; source unchanged");
        return;
    }
    /* CAM_CTRL[1] = ready, [2] = busy: read-modify-write bit 0 only. The
     * switch itself restarts the camera engine at a frame boundary, so the
     * panel shows ~0.5 s of black; the readback carries the settled value. */
    uint32_t v = *s_cam_ctrl;
    uint32_t want = (v & ~1u) | (src ? 1u : 0u);
    *s_cam_ctrl = want;
    __sync_synchronize();

    uint32_t got = *s_cam_ctrl;
    char msg[128];
    snprintf(msg, sizeof(msg), "YGUI-CAMSRC %s CAM_CTRL=0x%lx readback=0x%lx",
             (want & 1u) ? "CAM1" : "CAM0", (unsigned long)want,
             (unsigned long)got);
    platform_log(msg);
}

int platform_camera_source(void)
{
    if (!s_cam_ctrl) return -1;
    return (int)(*s_cam_ctrl & 1u);
}

void platform_clear_overlay(void)
{
    if (!s_overlay_ctrl) return;
    *s_overlay_ctrl = 0u;   /* en=0, no commit, count=0 */
    __sync_synchronize();
    platform_log("YGUI-OVL off");
}

void platform_init(int width, int height)
{
    (void)width;
    (void)height;

    s_mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (s_mem_fd < 0) {
        log_errno("cannot open /dev/mem");
        exit(1);
    }

#ifdef BOARD_GUI_SECOND_BUF
    s_gui_buf = mmap(NULL, FB_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED,
                     s_mem_fd, (off_t)GUI_BUF_PHYS);
    if (s_gui_buf == MAP_FAILED) {
        s_gui_buf = NULL;
        log_errno("cannot mmap GUI framebuffer 0xBE000000");
        exit(1);
    }
#else
    s_fb0 = mmap(NULL, FB_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED,
                 s_mem_fd, (off_t)FB0_PHYS);
    if (s_fb0 == MAP_FAILED) {
        s_fb0 = NULL;
        log_errno("cannot mmap framebuffer bank 0");
        exit(1);
    }

    s_fb1 = mmap(NULL, FB_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED,
                 s_mem_fd, (off_t)FB1_PHYS);
    if (s_fb1 == MAP_FAILED) {
        s_fb1 = NULL;
        log_errno("cannot mmap framebuffer bank 1");
        exit(1);
    }
#endif

    s_video_page = mmap(NULL, VIDEO_PAGE_BYTES, PROT_READ | PROT_WRITE,
                        MAP_SHARED, s_mem_fd, (off_t)VIDEO_PAGE_PHYS);
    if (s_video_page == MAP_FAILED) {
        s_video_page = NULL;
        log_errno("cannot mmap VIDEO CSR page");
        exit(1);
    }
    s_gui_ctrl = (volatile uint32_t *)((char *)s_video_page +
                                       VIDEO_GUI_CTRL_OFF);
    s_cam_ctrl = (volatile uint32_t *)((char *)s_video_page +
                                       VIDEO_CAM_CTRL_OFF);
    s_overlay_ctrl = (volatile uint32_t *)((char *)s_video_page +
                                           VIDEO_OVERLAY_CTRL_OFF);

    /* Phase R startup: the GUI owns the LCD before the first frame is drawn.
     * Freeze/bank: camera frozen, bank 0. Second buffer: read-source = GUI;
     * the camera keeps writing its own banks. */
    platform_set_camera_mode(false);

    platform_log("YGUI-BOOT");
#ifdef BOARD_GUI_SECOND_BUF
    {
        char msg[160];
        snprintf(msg, sizeof(msg),
                 "YGUI-VARIANT %s GUI buffer=0x%lx rows=%d..%d (GUI_CTRL[0]=gui_src, [1]=bank1)",
                 GUI_VARIANT_NAME, (unsigned long)GUI_BUF_PHYS, FB_ROW_OFFSET,
                 FB_ROW_OFFSET + UI_SCREEN_H - 1);
        platform_log(msg);
    }
#endif
}

void platform_shutdown(void)
{
#ifdef BOARD_GUI_SECOND_BUF
    if (s_gui_buf) {
        munmap(s_gui_buf, FB_BYTES);
        s_gui_buf = NULL;
    }
#else
    if (s_fb0) {
        munmap(s_fb0, FB_BYTES);
        s_fb0 = NULL;
    }
    if (s_fb1) {
        munmap(s_fb1, FB_BYTES);
        s_fb1 = NULL;
    }
#endif
    if (s_video_page) {
        munmap(s_video_page, VIDEO_PAGE_BYTES);
        s_video_page = NULL;
        s_gui_ctrl = NULL;
        s_cam_ctrl = NULL;
        s_overlay_ctrl = NULL;
    }
    if (s_mem_fd >= 0) {
        close(s_mem_fd);
        s_mem_fd = -1;
    }
}

/* One row; use 32-bit stores when both ends are word aligned and fall back
 * to a single 16-bit store for an odd tail. */
static void copy_row(uint16_t *dst, const uint16_t *src, int w)
{
    if ((((uintptr_t)src | (uintptr_t)dst) & 3u) == 0) {
        u32_alias *d32 = (u32_alias *)dst;
        const u32_alias *s32 = (const u32_alias *)src;
        int n = w >> 1;
        for (int i = 0; i < n; i++) d32[i] = s32[i];
        if (w & 1) dst[w - 1] = src[w - 1];
    } else {
        for (int i = 0; i < w; i++) dst[i] = src[i];
    }
}

void platform_flush(const ui_surface_t *surface, int x1, int y1, int x2, int y2)
{
    /* Camera mode: the camera owns the LCD. LVGL still gets
     * lv_display_flush_ready() from ui/app.c's flush callback; only the
     * DDR writes are skipped. */
    if (g_camera_mode) return;
#ifdef BOARD_GUI_SECOND_BUF
    if (!surface || !surface->pixels || !s_gui_buf) return;
#else
    if (!surface || !surface->pixels || !s_fb0 || !s_fb1) return;
#endif
    if (x1 < 0 || y1 < 0 || x2 >= UI_SCREEN_W || y2 >= UI_SCREEN_H ||
        x1 > x2 || y1 > y2) {
        return;
    }

    int w = x2 - x1 + 1;
    int h = y2 - y1 + 1;
#ifdef BOARD_GUI_SECOND_BUF
    uint16_t *gui = (uint16_t *)s_gui_buf;
#else
    uint16_t *fb0 = (uint16_t *)s_fb0;
#endif

    for (int row = 0; row < h; row++) {
        const uint16_t *src =
            surface->pixels + (size_t)row * (size_t)surface->stride_px;
        size_t dst_off = (size_t)(y1 + row + FB_ROW_OFFSET) * FB_W + x1;
#ifdef BOARD_GUI_SECOND_BUF
        copy_row(gui + dst_off, src, w);
#else
        /* GUI_CTRL[1] is never set, so the LCD always reads bank 0; writing
         * bank 1 as well only doubled the DDR flush cost. */
        copy_row(fb0 + dst_off, src, w);
#endif
    }

    if (!s_fb_ok) {
        s_fb_ok = true;
        platform_log("YGUI-FB-OK");
    }
}

uint32_t platform_time_ms(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (uint32_t)((uint64_t)ts.tv_sec * 1000u +
                      (uint64_t)ts.tv_nsec / 1000000u);
}

void platform_delay_ms(uint32_t ms)
{
    while (ms > 1000) {
        usleep(1000000);
        ms -= 1000;
    }
    usleep(ms * 1000);
}

bool platform_should_quit(void)
{
    return false;
}

const char *platform_asset_dir(void)
{
    return "/root/gui/assets";
}

void platform_log(const char *message)
{
    if (!message) return;
    int fd = open("/dev/kmsg", O_WRONLY | O_APPEND);
    if (fd < 0) return;
    size_t len = strlen(message);
    ssize_t ignored = write(fd, message, len);
    (void)ignored;
    ignored = write(fd, "\n", 1);
    (void)ignored;
    close(fd);
}

/* ---- ★ GPU DIRECT：LVGL 直接画进 GUI 帧存（BOARD_GUI_SECOND_BUF 才有）----
 * 该映射是 /dev/mem + O_SYNC（非缓存）⇒ GPU 写它、LCD 扫它都不需要 cache 维护。 */
uint16_t *platform_framebuffer(void)
{
#ifdef BOARD_GUI_SECOND_BUF
    /* LCD 从 DDR 的第 FB_ROW_OFFSET 行开始扫；LVGL 的 1024x600 视口就落在这里，
     * 步长仍是整帧 FB_W（1024）⇒ 与 platform_flush 的写入口径逐像素一致。 */
    return (uint16_t *)s_gui_buf + (size_t)FB_ROW_OFFSET * FB_W;
#else
    return NULL;
#endif
}

uint32_t platform_framebuffer_phys(void)
{
#ifdef BOARD_GUI_SECOND_BUF
    return (uint32_t)GUI_BUF_PHYS + (uint32_t)FB_ROW_OFFSET * FB_W * 2u;
#else
    return 0;
#endif
}

void platform_present_full(void)
{
    /* LCD 直接扫 DDR 帧存（换 bank 由 GPU 的 FLIP 在帧起点完成）⇒ 这里 no-op。 */
}
