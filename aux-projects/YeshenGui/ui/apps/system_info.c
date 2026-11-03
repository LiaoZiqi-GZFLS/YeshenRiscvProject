/* System Info: a two-column read-only summary of the host/board.
 * /proc and /sys reads are small and non-blocking; getifaddrs() is local. */
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE 1
#endif
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include "apps.h"

#include "theme.h"
#include "wm.h"

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <unistd.h>

#define REFRESH_MS        1000
#define FIELD_LABEL_COLOR 0x6B7785u

typedef struct {
    lv_obj_t *cpu;
    lv_obj_t *load;
    lv_obj_t *memory;
    lv_obj_t *uptime;
    lv_obj_t *ipv4;
    lv_obj_t *mac;
    lv_obj_t *kernel;
    lv_obj_t *board;
    lv_obj_t *build;
    lv_timer_t *timer;
} sysinfo_ctx_t;

static void update_cb(lv_timer_t *timer);
static void update_values(sysinfo_ctx_t *ctx);

/* ------------------------------------------------------------------ */
/* Host/board readers                                                  */
/* ------------------------------------------------------------------ */

static void read_first_line(const char *path, char *out, size_t out_sz)
{
    if (!out || out_sz == 0) return;
    out[0] = '\0';

    FILE *f = fopen(path, "r");
    if (!f) return;
    if (!fgets(out, (int)out_sz, f)) out[0] = '\0';
    fclose(f);

    size_t n = strlen(out);
    while (n > 0 && (out[n - 1] == '\n' || out[n - 1] == '\r' ||
                     out[n - 1] == ' ' || out[n - 1] == '\t')) {
        out[--n] = '\0';
    }
}

static void read_meminfo(unsigned long *total_kb, unsigned long *avail_kb)
{
    if (!total_kb || !avail_kb) return;
    *total_kb = 0;
    *avail_kb = 0;

    FILE *f = fopen("/proc/meminfo", "r");
    if (!f) return;

    char line[128];
    unsigned long total = 0, avail = 0;
    bool have_total = false, have_avail = false;
    while (fgets(line, sizeof(line), f)) {
        if (!strncmp(line, "MemTotal:", 9)) {
            have_total = sscanf(line + 9, "%lu", &total) == 1;
        } else if (!strncmp(line, "MemAvailable:", 13)) {
            have_avail = sscanf(line + 13, "%lu", &avail) == 1;
        }
        if (have_total && have_avail) break;
    }
    fclose(f);

    /* Both are needed for the "xx / yy MiB" field; otherwise report n/a. */
    if (!have_total || !have_avail) return;
    *total_kb = total;
    *avail_kb = avail;
}

static void read_ipv4(char *out, size_t out_sz)
{
    if (!out || out_sz == 0) return;
    out[0] = '\0';

    struct ifaddrs *ifs = NULL;
    if (getifaddrs(&ifs) != 0) return;

    for (struct ifaddrs *ifa = ifs; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
        if (ifa->ifa_flags & IFF_LOOPBACK) continue;
        if (ifa->ifa_name && !strcmp(ifa->ifa_name, "lo")) continue;

        const struct sockaddr_in *sin =
            (const struct sockaddr_in *)ifa->ifa_addr;
        if (!inet_ntop(AF_INET, &sin->sin_addr, out, (socklen_t)out_sz)) {
            out[0] = '\0';
        }
        break;
    }
    freeifaddrs(ifs);
}

static void format_uptime(char *out, size_t out_sz)
{
    if (!out || out_sz == 0) return;
    out[0] = '\0';

    FILE *f = fopen("/proc/uptime", "r");
    if (!f) return;
    double seconds = 0.0;
    int got = fscanf(f, "%lf", &seconds);
    fclose(f);
    if (got != 1 || seconds < 0.0) return;

    unsigned long total = (unsigned long)seconds;
    unsigned long days = total / 86400UL;
    unsigned long hours = (total % 86400UL) / 3600UL;
    unsigned long mins = (total % 3600UL) / 60UL;
    snprintf(out, out_sz, "%lud %02lu:%02lu", days, hours, mins);
}

/* ------------------------------------------------------------------ */
/* UI                                                                  */
/* ------------------------------------------------------------------ */

static lv_obj_t *create_plain(lv_obj_t *parent)
{
    lv_obj_t *o = lv_obj_create(parent);
    lv_obj_set_style_bg_opa(o, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(o, 0, 0);
    lv_obj_set_style_radius(o, 0, 0);
    lv_obj_set_style_pad_all(o, 0, 0);
    lv_obj_set_scrollbar_mode(o, LV_SCROLLBAR_MODE_OFF);
    lv_obj_remove_flag(o, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_remove_flag(o, LV_OBJ_FLAG_CLICKABLE);
    return o;
}

static lv_obj_t *create_card(lv_obj_t *parent, int x, int y, int w, int h,
                             const char *title)
{
    lv_obj_t *card = lv_obj_create(parent);
    lv_obj_set_pos(card, x, y);
    lv_obj_set_size(card, w, h);
    lv_obj_set_style_bg_color(card, ui_theme_colors()->panel, 0);
    lv_obj_set_style_bg_opa(card, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(card, 1, 0);
    lv_obj_set_style_border_color(card, ui_theme_colors()->border, 0);
    lv_obj_set_style_radius(card, 8, 0);
    lv_obj_set_style_pad_all(card, 16, 0);
    lv_obj_set_style_pad_row(card, 0, 0);
    lv_obj_set_scrollbar_mode(card, LV_SCROLLBAR_MODE_OFF);
    lv_obj_remove_flag(card, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_flex_flow(card, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(card, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START,
                          LV_FLEX_ALIGN_START);

    lv_obj_t *heading = lv_label_create(card);
    lv_label_set_text(heading, title);
    lv_obj_set_style_text_font(heading, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(heading, ui_theme_colors()->accent, 0);
    lv_obj_set_style_pad_bottom(heading, 6, 0);
    return card;
}

static lv_obj_t *add_field(lv_obj_t *card, const char *name)
{
    lv_obj_t *row = create_plain(card);
    lv_obj_set_size(row, LV_PCT(100), 44);
    lv_obj_set_style_pad_column(row, 10, 0);
    lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(row, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER,
                          LV_FLEX_ALIGN_CENTER);

    lv_obj_t *key = lv_label_create(row);
    lv_obj_set_width(key, 96);
    lv_label_set_text(key, name);
    lv_label_set_long_mode(key, LV_LABEL_LONG_CLIP);
    lv_obj_set_style_text_font(key, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(key, lv_color_hex(FIELD_LABEL_COLOR), 0);

    lv_obj_t *value = lv_label_create(row);
    lv_obj_set_flex_grow(value, 1);
    lv_label_set_text(value, "n/a");
    lv_label_set_long_mode(value, LV_LABEL_LONG_DOT);
    lv_obj_set_style_text_font(value, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(value, ui_theme_colors()->text, 0);
    return value;
}

static void build_header(lv_obj_t *content)
{
    lv_obj_t *header = create_plain(content);
    lv_obj_set_pos(header, 0, 0);
    lv_obj_set_size(header, LV_PCT(100), 34);

    lv_obj_t *swirl = lv_obj_create(header);
    lv_obj_set_size(swirl, 30, 30);
    lv_obj_set_pos(swirl, 0, 2);
    lv_obj_set_style_bg_color(swirl, ui_theme_colors()->accent, 0);
    lv_obj_set_style_bg_opa(swirl, LV_OPA_COVER, 0);
    lv_obj_set_style_radius(swirl, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_border_width(swirl, 0, 0);
    lv_obj_set_style_pad_all(swirl, 0, 0);
    lv_obj_set_scrollbar_mode(swirl, LV_SCROLLBAR_MODE_OFF);
    lv_obj_remove_flag(swirl, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_remove_flag(swirl, LV_OBJ_FLAG_CLICKABLE);

    lv_obj_t *glyph = lv_label_create(swirl);
    lv_label_set_text(glyph, LV_SYMBOL_LOOP);
    lv_obj_set_style_text_font(glyph, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(glyph, lv_color_white(), 0);
    lv_obj_center(glyph);

    lv_obj_t *title = lv_label_create(header);
    lv_label_set_text(title, "YeshenGui Debian-style Desktop");
    lv_obj_set_style_text_font(title, &lv_font_montserrat_20, 0);
    lv_obj_set_style_text_color(title, ui_theme_colors()->text, 0);
    lv_obj_set_pos(title, 42, 3);
}

static void update_values(sysinfo_ctx_t *ctx)
{
    if (!ctx) return;
    char buf[160];

    lv_label_set_text(ctx->cpu, "100 MHz");

    double load = 0.0;
    read_first_line("/proc/loadavg", buf, sizeof(buf));
    if (buf[0] && sscanf(buf, "%lf", &load) == 1) {
        /* libc snprintf: LVGL's formatter has %f disabled in lv_conf. */
        snprintf(buf, sizeof(buf), "%.2f", load);
        lv_label_set_text(ctx->load, buf);
    } else {
        lv_label_set_text(ctx->load, "n/a");
    }

    unsigned long total_kb = 0, avail_kb = 0;
    read_meminfo(&total_kb, &avail_kb);
    if (total_kb > 0) {
        snprintf(buf, sizeof(buf), "%lu / %lu MiB", total_kb / 1024UL,
                 avail_kb / 1024UL);
        lv_label_set_text(ctx->memory, buf);
    } else {
        lv_label_set_text(ctx->memory, "n/a");
    }

    format_uptime(buf, sizeof(buf));
    lv_label_set_text(ctx->uptime, buf[0] ? buf : "n/a");

    read_ipv4(buf, sizeof(buf));
    lv_label_set_text(ctx->ipv4, buf[0] ? buf : "n/a");

    read_first_line("/sys/class/net/eth0/address", buf, sizeof(buf));
    lv_label_set_text(ctx->mac, buf[0] ? buf : "n/a");

    struct utsname u;
    if (uname(&u) == 0) {
        snprintf(buf, sizeof(buf), "%s %s", u.sysname, u.release);
        lv_label_set_text(ctx->kernel, buf);
    } else {
        lv_label_set_text(ctx->kernel, "n/a");
    }

    lv_label_set_text(ctx->board, "PanGu 100K200K MINI / PG2L200H");
    lv_label_set_text(ctx->build, "YeshenGui Phase S");
}

static void update_cb(lv_timer_t *timer)
{
    update_values((sysinfo_ctx_t *)lv_timer_get_user_data(timer));
}

static void content_delete_cb(lv_event_t *e)
{
    sysinfo_ctx_t *ctx = (sysinfo_ctx_t *)lv_event_get_user_data(e);
    if (!ctx) return;
    if (ctx->timer) {
        lv_timer_delete(ctx->timer);
        ctx->timer = NULL;
    }
    lv_free(ctx);
}

/* ------------------------------------------------------------------ */
/* Public API                                                          */
/* ------------------------------------------------------------------ */

void app_system_info_open(void)
{
    lv_obj_t *content = NULL;
    ui_window_t *win = wm_open("System Info", 900, 460, false, &content, NULL);
    if (!win || !content) return;

    sysinfo_ctx_t *ctx = lv_malloc_zeroed(sizeof(*ctx));
    if (!ctx) {
        wm_close(win);
        return;
    }

    lv_obj_set_style_pad_all(content, 20, 0);
    lv_obj_remove_flag(content, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scrollbar_mode(content, LV_SCROLLBAR_MODE_OFF);

    build_header(content);

    lv_obj_t *left = create_card(content, 0, 50, 416, 326, "Resources");
    ctx->cpu = add_field(left, "CPU");
    ctx->load = add_field(left, "Load");
    ctx->memory = add_field(left, "Memory");
    ctx->uptime = add_field(left, "Uptime");

    lv_obj_t *right = create_card(content, 436, 50, 416, 326, "System");
    ctx->ipv4 = add_field(right, "IPv4");
    ctx->mac = add_field(right, "MAC");
    ctx->kernel = add_field(right, "Kernel");
    ctx->board = add_field(right, "Board");
    ctx->build = add_field(right, "Build");

    ctx->timer = lv_timer_create(update_cb, REFRESH_MS, ctx);
    update_values(ctx);

    lv_obj_add_event_cb(content, content_delete_cb, LV_EVENT_DELETE, ctx);
    wm_enable_bubble(content);
}
