#include "platform.h"

#ifdef UI_HOST

#include <SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static SDL_Window *g_win;
static SDL_Renderer *g_ren;
static SDL_Texture *g_tex;
static uint16_t g_shadow[UI_SCREEN_W * UI_SCREEN_H];
static int g_mx, g_my;
static bool g_mouse_down;
static bool g_quit;
static ui_key_t g_keys[16];
static int g_key_head, g_key_tail;

static void push_key(ui_key_t k)
{
    int next = (g_key_tail + 1) % 16;
    if (next == g_key_head) {
        g_key_head = (g_key_head + 1) % 16; /* drop oldest */
    }
    g_keys[g_key_tail] = k;
    g_key_tail = next;
}

static void pump_events(void)
{
    SDL_Event e;
    while (SDL_PollEvent(&e)) {
        if (e.type == SDL_QUIT) {
            g_quit = true;
        } else if (e.type == SDL_MOUSEMOTION) {
            g_mx = e.motion.x;
            g_my = e.motion.y;
        } else if (e.type == SDL_MOUSEBUTTONDOWN && e.button.button == SDL_BUTTON_LEFT) {
            g_mx = e.button.x;
            g_my = e.button.y;
            g_mouse_down = true;
        } else if (e.type == SDL_MOUSEBUTTONUP && e.button.button == SDL_BUTTON_LEFT) {
            g_mx = e.button.x;
            g_my = e.button.y;
            g_mouse_down = false;
        } else if (e.type == SDL_KEYDOWN && !e.key.repeat) {
            ui_key_t k = { .type = UI_KEY_NONE, .ch = 0 };
            SDL_Keycode s = e.key.keysym.sym;
            if (s == SDLK_TAB) k.type = UI_KEY_TAB;
            else if (s == SDLK_RETURN || s == SDLK_KP_ENTER) k.type = UI_KEY_ENTER;
            else if (s == SDLK_ESCAPE) k.type = UI_KEY_ESC;
            else if (s == SDLK_BACKSPACE) k.type = UI_KEY_BACKSPACE;
            else if (s == SDLK_UP) k.type = UI_KEY_UP;
            else if (s == SDLK_DOWN) k.type = UI_KEY_DOWN;
            else if (s == SDLK_LEFT) k.type = UI_KEY_LEFT;
            else if (s == SDLK_RIGHT) k.type = UI_KEY_RIGHT;
            else if (s == SDLK_c && (SDL_GetModState() & KMOD_CTRL)) k.type = UI_KEY_CTRL_C;
            else if (s == SDLK_d && (SDL_GetModState() & KMOD_CTRL)) k.type = UI_KEY_CTRL_D;
            else if (s == SDLK_w && (SDL_GetModState() & KMOD_CTRL)) k.type = UI_KEY_CTRL_W;
            else if (s >= 32 && s <= 126) {
                k.type = UI_KEY_CHAR;
                k.ch = (char)s;
            }
            if (k.type != UI_KEY_NONE) push_key(k);
        }
    }
}

void platform_init(int width, int height)
{
    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        exit(1);
    }
    g_win = SDL_CreateWindow("YeshenGui", SDL_WINDOWPOS_CENTERED,
                             SDL_WINDOWPOS_CENTERED, width, height, 0);
    if (!g_win) {
        fprintf(stderr, "SDL_CreateWindow: %s\n", SDL_GetError());
        exit(1);
    }
    g_ren = SDL_CreateRenderer(g_win, -1, 0);
    if (!g_ren) {
        fprintf(stderr, "SDL_CreateRenderer: %s\n", SDL_GetError());
        exit(1);
    }
    g_tex = SDL_CreateTexture(g_ren, SDL_PIXELFORMAT_RGB565,
                              SDL_TEXTUREACCESS_STREAMING, width, height);
    if (!g_tex) {
        fprintf(stderr, "SDL_CreateTexture: %s\n", SDL_GetError());
        exit(1);
    }
    SDL_ShowCursor(SDL_ENABLE);
}

void platform_shutdown(void)
{
    if (g_tex) SDL_DestroyTexture(g_tex);
    if (g_ren) SDL_DestroyRenderer(g_ren);
    if (g_win) SDL_DestroyWindow(g_win);
    SDL_Quit();
}

void platform_flush(const ui_surface_t *s, int x1, int y1, int x2, int y2)
{
    if (!s || !s->pixels) return;
    int w = x2 - x1 + 1;
    int h = y2 - y1 + 1;
    if (w <= 0 || h <= 0) return;

    for (int row = 0; row < h; row++) {
        memcpy(&g_shadow[(y1 + row) * UI_SCREEN_W + x1],
               &s->pixels[row * s->stride_px], (size_t)w * 2);
    }

    SDL_Rect r = { x1, y1, w, h };
    SDL_UpdateTexture(g_tex, &r, &g_shadow[y1 * UI_SCREEN_W + x1],
                      UI_SCREEN_W * 2);
    SDL_RenderClear(g_ren);
    SDL_RenderCopy(g_ren, g_tex, NULL, NULL);
    SDL_RenderPresent(g_ren);
}

uint32_t platform_time_ms(void)
{
    return SDL_GetTicks();
}

void platform_delay_ms(uint32_t ms)
{
    SDL_Delay(ms);
}

bool platform_should_quit(void)
{
    pump_events();
    return g_quit;
}

bool platform_poll_touch(int *x, int *y, bool *pressed)
{
    pump_events();
    if (x) *x = g_mx;
    if (y) *y = g_my;
    if (pressed) *pressed = g_mouse_down;
    return true;
}

void platform_touch_probe(int seconds)
{
    (void)seconds;
}

bool platform_poll_key(ui_key_t *key)
{
    if (g_key_head == g_key_tail) return false;
    *key = g_keys[g_key_head];
    g_key_head = (g_key_head + 1) % 16;
    return true;
}

const char *platform_asset_dir(void)
{
    const char *env = getenv("YESHENGUI_ASSET_DIR");
    return env ? env : "ui/assets";
}

void platform_log(const char *message)
{
    fprintf(stderr, "%s\n", message);
    fflush(stderr);
}

/* The host has no RTL switch: keep the GUI and only log the request so the
 * shortcut/card code can be exercised without board hardware. */
void platform_set_camera_mode(bool on)
{
    platform_log(on ? "host: camera mode requested (no-op)"
                    : "host: GUI mode requested (no-op)");
}

bool platform_camera_mode(void)
{
    return false;
}

void platform_set_camera_source(int src)
{
    platform_log(src ? "host: CAM1 requested (no-op)" : "host: CAM0 requested (no-op)");
}

int platform_camera_source(void)
{
    return -1;
}

void platform_clear_overlay(void)
{
}

/* Board-only framebuffer bank split; the host keeps one shadow framebuffer. */
void platform_gui_use_bank1(void)
{
}

void platform_uart_keyboard_disable(void)
{
}

void platform_present_start(void)
{
}

void platform_present_stop(void)
{
}

void platform_present(const ui_surface_t *surface, int x1, int y1, int x2, int y2)
{
    platform_flush(surface, x1, y1, x2, y2);
}

void platform_touch_service_start(void)
{
}

uint16_t *platform_framebuffer(void) { return g_shadow; }
uint32_t platform_framebuffer_phys(void) { return 0; }

void platform_present_full(void)
{
    if (!g_tex) return;
    SDL_UpdateTexture(g_tex, NULL, g_shadow, UI_SCREEN_W * 2);
    SDL_RenderClear(g_ren);
    SDL_RenderCopy(g_ren, g_tex, NULL, NULL);
    SDL_RenderPresent(g_ren);
}

void platform_screenshot(const char *path)
{
    FILE *f = fopen(path, "wb");
    if (!f) {
        fprintf(stderr, "screenshot: cannot open %s\n", path);
        return;
    }
    fprintf(f, "P6\n%d %d\n255\n", UI_SCREEN_W, UI_SCREEN_H);
    for (int i = 0; i < UI_SCREEN_W * UI_SCREEN_H; i++) {
        uint16_t p = g_shadow[i];
        unsigned r = (p >> 11) & 0x1F;
        unsigned g = (p >> 5) & 0x3F;
        unsigned b = p & 0x1F;
        unsigned char rgb[3] = {
            (unsigned char)((r << 3) | (r >> 2)),
            (unsigned char)((g << 2) | (g >> 4)),
            (unsigned char)((b << 3) | (b >> 2)),
        };
        fwrite(rgb, 1, 3, f);
    }
    fclose(f);
}

#endif /* UI_HOST */
