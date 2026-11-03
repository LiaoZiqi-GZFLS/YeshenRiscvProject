/* Files: a read-only directory browser with a text preview pane.
 *
 * The board runs as root and starts in /root. On the host simulator /root is
 * usually mode 0700 and unreadable; in that case the browser falls back to
 * $HOME (or "/") and shows a note explaining the substitution. Nothing in
 * this app writes to disk.
 */
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE 1
#endif
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include "apps.h"

#include "platform.h"
#include "theme.h"
#include "wm.h"

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define FILES_W       900
#define FILES_H       460
#define LIST_W        520
#define PREVIEW_W     340
#define PANE_GAP      16
#define ROW_H         48
#define MAX_ROWS      256
#define PREVIEW_LINES 20
#define META_W        132
#define PATH_LEN      256
#define META_COLOR    0x6B7785u

typedef struct {
    char cwd[PATH_LEN];
    ui_window_t *win;
    lv_obj_t *path_label;
    lv_obj_t *note_label;
    lv_obj_t *list;
    lv_obj_t *preview_pane;
    lv_obj_t *preview_title;
    lv_obj_t *preview;
} files_ctx_t;

typedef struct {
    char name[256];
    bool is_dir;
    unsigned long long size;
    time_t mtime;
} files_entry_t;

/* Per-row path passed to row_click_cb; freed by the row's DELETE handler. */
typedef struct {
    char path[PATH_LEN + 260];
} files_row_info_t;

static files_ctx_t *s_ctx;

static void files_refresh(void);
static void row_click_cb(lv_event_t *e);
static void preview_file(const char *path);
static void go_parent_cb(lv_event_t *e);
static void enter_dir(const char *path);
static void preview_reset(void);
static void add_message_row(const char *text);

/* ------------------------------------------------------------------ */
/* Small helpers                                                       */
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

static void copy_path(char *dst, size_t dst_sz, const char *src)
{
    if (!dst || dst_sz == 0) return;
    size_t n = 0;
    if (src) {
        while (src[n] != '\0' && n + 1 < dst_sz) n++;
    }
    if (n > 0) memcpy(dst, src, n);
    dst[n] = '\0';
}

static void normalize_path(char *path)
{
    if (!path) return;
    char *write = path;
    for (const char *read = path; *read; read++) {
        if (*read == '/' && write > path && write[-1] == '/') continue;
        *write++ = *read;
    }
    *write = '\0';
    if (write > path + 1 && write[-1] == '/') write[-1] = '\0';
    if (path[0] == '\0') {
        path[0] = '/';
        path[1] = '\0';
    }
}

static void path_parent(char *path)
{
    if (!path || !strcmp(path, "/")) return;
    char *slash = strrchr(path, '/');
    if (!slash || slash == path) {
        strcpy(path, "/");
    } else {
        *slash = '\0';
    }
}

static bool dir_openable(const char *path)
{
    if (!path || !path[0]) return false;
    DIR *d = opendir(path);
    if (!d) return false;
    closedir(d);
    return true;
}

static void format_size(unsigned long long bytes, char *out, size_t out_sz)
{
    if (bytes < 1024ULL) {
        snprintf(out, out_sz, "%llu B", bytes);
    } else if (bytes < 1024ULL * 1024ULL) {
        snprintf(out, out_sz, "%.1f KB", (double)bytes / 1024.0);
    } else if (bytes < 1024ULL * 1024ULL * 1024ULL) {
        snprintf(out, out_sz, "%.1f MB", (double)bytes / (1024.0 * 1024.0));
    } else {
        snprintf(out, out_sz, "%.1f GB",
                 (double)bytes / (1024.0 * 1024.0 * 1024.0));
    }
}

static void format_date(time_t when, char *out, size_t out_sz)
{
    struct tm tmv;
    if (when > 0 && localtime_r(&when, &tmv) != NULL) {
        strftime(out, out_sz, "%Y-%m-%d", &tmv);
    } else {
        snprintf(out, out_sz, "-");
    }
}

static int entry_cmp(const void *a, const void *b)
{
    const files_entry_t *ea = (const files_entry_t *)a;
    const files_entry_t *eb = (const files_entry_t *)b;
    if (ea->is_dir != eb->is_dir) return ea->is_dir ? -1 : 1;
    int cmp = strcasecmp(ea->name, eb->name);
    if (cmp != 0) return cmp;
    return strcmp(ea->name, eb->name);
}

/* ------------------------------------------------------------------ */
/* Rows                                                                */
/* ------------------------------------------------------------------ */

static lv_obj_t *create_row_base(const char *icon, lv_color_t icon_color,
                                 const char *name, const char *meta)
{
    lv_obj_t *row = lv_button_create(s_ctx->list);
    lv_obj_set_size(row, LV_PCT(100), ROW_H);
    lv_obj_set_style_bg_opa(row, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(row, 0, 0);
    lv_obj_set_style_radius(row, 6, 0);
    lv_obj_set_style_pad_all(row, 8, 0);
    lv_obj_set_style_pad_column(row, 10, 0);
    lv_obj_set_style_shadow_width(row, 0, 0);
    lv_obj_set_style_bg_color(row, ui_theme_colors()->accent, LV_STATE_PRESSED);
    lv_obj_set_style_bg_opa(row, LV_OPA_20, LV_STATE_PRESSED);
    lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(row, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER,
                          LV_FLEX_ALIGN_CENTER);

    lv_obj_t *icon_label = lv_label_create(row);
    lv_label_set_text(icon_label, icon);
    lv_obj_set_style_text_font(icon_label, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(icon_label, icon_color, 0);

    lv_obj_t *name_label = lv_label_create(row);
    lv_obj_set_flex_grow(name_label, 1);
    lv_label_set_text(name_label, name);
    lv_label_set_long_mode(name_label, LV_LABEL_LONG_DOT);
    lv_obj_set_style_text_font(name_label, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(name_label, ui_theme_colors()->text, 0);

    lv_obj_t *meta_label = lv_label_create(row);
    lv_obj_set_width(meta_label, META_W);
    lv_label_set_text(meta_label, meta ? meta : "");
    lv_label_set_long_mode(meta_label, LV_LABEL_LONG_CLIP);
    lv_obj_set_style_text_font(meta_label, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(meta_label, lv_color_hex(META_COLOR), 0);
    lv_obj_set_style_text_align(meta_label, LV_TEXT_ALIGN_RIGHT, 0);

    return row;
}

static void row_info_delete_cb(lv_event_t *e)
{
    files_row_info_t *info = (files_row_info_t *)lv_event_get_user_data(e);
    if (info) lv_free(info);
}

static void add_parent_row(void)
{
    lv_obj_t *row = create_row_base(LV_SYMBOL_UP, ui_theme_colors()->accent,
                                    "..", "");
    lv_obj_add_event_cb(row, go_parent_cb, LV_EVENT_CLICKED, NULL);
}

static void add_entry_row(const files_entry_t *entry, const char *path)
{
    char meta[32];
    if (entry->is_dir) {
        format_date(entry->mtime, meta, sizeof(meta));
    } else {
        format_size(entry->size, meta, sizeof(meta));
    }

    lv_obj_t *row = create_row_base(
        entry->is_dir ? LV_SYMBOL_DIRECTORY : LV_SYMBOL_FILE,
        entry->is_dir ? ui_theme_colors()->accent : lv_color_hex(META_COLOR),
        entry->name, meta);

    files_row_info_t *info = lv_malloc(sizeof(*info));
    if (!info) return; /* Row stays visible but inert. */
    copy_path(info->path, sizeof(info->path), path);
    lv_obj_add_event_cb(row, row_info_delete_cb, LV_EVENT_DELETE, info);
    lv_obj_add_event_cb(row, row_click_cb, LV_EVENT_CLICKED, info);
}

static void add_message_row(const char *text)
{
    lv_obj_t *row = create_plain(s_ctx->list);
    lv_obj_set_size(row, LV_PCT(100), ROW_H);
    lv_obj_set_style_pad_all(row, 8, 0);
    lv_obj_set_style_pad_column(row, 10, 0);
    lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(row, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER,
                          LV_FLEX_ALIGN_CENTER);

    lv_obj_t *icon = lv_label_create(row);
    lv_label_set_text(icon, LV_SYMBOL_WARNING);
    lv_obj_set_style_text_font(icon, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(icon, ui_theme_colors()->warning, 0);

    lv_obj_t *label = lv_label_create(row);
    lv_obj_set_flex_grow(label, 1);
    lv_label_set_text(label, text);
    lv_label_set_long_mode(label, LV_LABEL_LONG_WRAP);
    lv_obj_set_style_text_font(label, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(label, ui_theme_colors()->warning, 0);
}

/* ------------------------------------------------------------------ */
/* Preview                                                             */
/* ------------------------------------------------------------------ */

static void preview_reset(void)
{
    if (!s_ctx) return;
    lv_label_set_text(s_ctx->preview_title, "Preview");
    lv_label_set_text(s_ctx->preview, "Select a file to preview.");
    lv_obj_scroll_to_y(s_ctx->preview_pane, 0, LV_ANIM_OFF);
}

static void preview_set(const char *title, const char *text)
{
    if (!s_ctx) return;
    lv_label_set_text(s_ctx->preview_title, title);
    lv_label_set_text(s_ctx->preview, text);
    lv_obj_scroll_to_y(s_ctx->preview_pane, 0, LV_ANIM_OFF);
}

static void preview_file(const char *path)
{
    if (!s_ctx || !path) return;

    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    char title[96];
    snprintf(title, sizeof(title), "Preview: %s", name);

    FILE *f = fopen(path, "rb");
    if (!f) {
        char msg[160];
        snprintf(msg, sizeof(msg), "[unreadable: %s]", strerror(errno));
        preview_set(title, msg);
        return;
    }

    char raw[4096];
    size_t got = fread(raw, 1, sizeof(raw), f);
    fclose(f);

    bool binary = false;
    for (size_t i = 0; i < got; i++) {
        unsigned char c = (unsigned char)raw[i];
        if (c == 0 || c == 0x7F ||
            (c < 0x20 && c != '\n' && c != '\r' && c != '\t')) {
            binary = true;
            break;
        }
    }
    if (binary) {
        preview_set(title, "[binary]");
        return;
    }

    /* First PREVIEW_LINES lines, capped by the label buffer. */
    char text[4096];
    size_t used = 0;
    int lines = 0;
    bool truncated = false;
    for (size_t i = 0; i < got; i++) {
        if (lines >= PREVIEW_LINES) {
            truncated = true;
            break;
        }
        if (used + 2 >= sizeof(text)) {
            truncated = true;
            break;
        }
        text[used++] = raw[i];
        if (raw[i] == '\n') lines++;
    }
    text[used] = '\0';

    if (used == 0) {
        preview_set(title, "[empty file]");
        return;
    }
    if (truncated) {
        static const char marker[] = "\n[preview truncated]";
        size_t room = sizeof(text) - 1 - used;
        size_t n = sizeof(marker) - 1;
        if (n > room) n = room;
        memcpy(text + used, marker, n);
        used += n;
        text[used] = '\0';
    }
    preview_set(title, text);
}

/* ------------------------------------------------------------------ */
/* Navigation                                                          */
/* ------------------------------------------------------------------ */

static void enter_dir(const char *path)
{
    if (!s_ctx || !path) return;
    copy_path(s_ctx->cwd, sizeof(s_ctx->cwd), path);
    normalize_path(s_ctx->cwd);
    files_refresh();
}

static void go_parent_cb(lv_event_t *e)
{
    (void)e;
    if (!s_ctx) return;
    path_parent(s_ctx->cwd);
    files_refresh();
}

static void row_click_cb(lv_event_t *e)
{
    const files_row_info_t *info =
        (const files_row_info_t *)lv_event_get_user_data(e);
    if (!s_ctx || !info) return;

    struct stat st;
    if (stat(info->path, &st) == 0 && S_ISDIR(st.st_mode)) {
        enter_dir(info->path);
    } else {
        preview_file(info->path);
    }
}

/* ------------------------------------------------------------------ */
/* Directory listing                                                   */
/* ------------------------------------------------------------------ */

static void files_refresh(void)
{
    if (!s_ctx) return;

    lv_obj_clean(s_ctx->list);
    preview_reset();

    char label[PATH_LEN + 16];
    snprintf(label, sizeof(label), LV_SYMBOL_DIRECTORY "  %s", s_ctx->cwd);
    lv_label_set_text(s_ctx->path_label, label);

    if (strcmp(s_ctx->cwd, "/") != 0) add_parent_row();

    DIR *dir = opendir(s_ctx->cwd);
    if (!dir) {
        char msg[PATH_LEN + 96];
        snprintf(msg, sizeof(msg), "Cannot open %s: %s", s_ctx->cwd,
                 strerror(errno));
        add_message_row(msg);
        platform_log(msg);
        return;
    }

    size_t cap = 64;
    size_t count = 0;
    files_entry_t *entries = lv_malloc(cap * sizeof(*entries));
    bool oom = (entries == NULL);
    bool truncated = false;

    struct dirent *de;
    while (!oom && (de = readdir(dir)) != NULL) {
        if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, "..")) continue;
        if (count >= MAX_ROWS) {
            truncated = true;
            break;
        }

        char path[PATH_LEN + 260];
        snprintf(path, sizeof(path), "%s/%s", s_ctx->cwd, de->d_name);
        normalize_path(path);

        struct stat st;
        if (stat(path, &st) != 0) continue; /* Broken link/unreadable. */

        if (count == cap) {
            size_t next_cap = cap * 2;
            files_entry_t *grown =
                lv_realloc(entries, next_cap * sizeof(*entries));
            if (!grown) {
                oom = true;
                break;
            }
            entries = grown;
            cap = next_cap;
        }

        files_entry_t *entry = &entries[count++];
        snprintf(entry->name, sizeof(entry->name), "%s", de->d_name);
        entry->is_dir = S_ISDIR(st.st_mode);
        entry->size = (unsigned long long)st.st_size;
        entry->mtime = st.st_mtime;
    }
    closedir(dir);

    if (oom) {
        add_message_row("Out of memory while reading this directory.");
        if (entries) lv_free(entries);
        lv_obj_scroll_to_y(s_ctx->list, 0, LV_ANIM_OFF);
        wm_enable_bubble(s_ctx->list);
        return;
    }

    qsort(entries, count, sizeof(*entries), entry_cmp);
    for (size_t i = 0; i < count; i++) {
        char path[PATH_LEN + 260];
        snprintf(path, sizeof(path), "%s/%s", s_ctx->cwd, entries[i].name);
        normalize_path(path);
        add_entry_row(&entries[i], path);
    }

    if (truncated) {
        add_message_row("Directory listing truncated at 256 entries.");
    }
    lv_free(entries);

    lv_obj_scroll_to_y(s_ctx->list, 0, LV_ANIM_OFF);
    /* New rows need the bubble flag so presses reach the window's focus
     * handler in wm.c. */
    wm_enable_bubble(s_ctx->list);
}

/* ------------------------------------------------------------------ */
/* UI construction                                                     */
/* ------------------------------------------------------------------ */

static void build_panes(files_ctx_t *ctx, lv_obj_t *content, int panes_y)
{
    int panes_h = 400 - panes_y;

    ctx->list = lv_obj_create(content);
    lv_obj_set_pos(ctx->list, 0, panes_y);
    lv_obj_set_size(ctx->list, LIST_W, panes_h);
    lv_obj_set_style_bg_color(ctx->list, ui_theme_colors()->panel, 0);
    lv_obj_set_style_bg_opa(ctx->list, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(ctx->list, 1, 0);
    lv_obj_set_style_border_color(ctx->list, ui_theme_colors()->border, 0);
    lv_obj_set_style_radius(ctx->list, 8, 0);
    lv_obj_set_style_pad_all(ctx->list, 6, 0);
    lv_obj_set_style_pad_row(ctx->list, 2, 0);
    lv_obj_set_scrollbar_mode(ctx->list, LV_SCROLLBAR_MODE_AUTO);
    lv_obj_set_scroll_dir(ctx->list, LV_DIR_VER);
    lv_obj_set_flex_flow(ctx->list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(ctx->list, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START,
                          LV_FLEX_ALIGN_START);

    ctx->preview_pane = lv_obj_create(content);
    lv_obj_set_pos(ctx->preview_pane, LIST_W + PANE_GAP, panes_y);
    lv_obj_set_size(ctx->preview_pane, PREVIEW_W, panes_h);
    lv_obj_set_style_bg_color(ctx->preview_pane, ui_theme_colors()->panel, 0);
    lv_obj_set_style_bg_opa(ctx->preview_pane, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(ctx->preview_pane, 1, 0);
    lv_obj_set_style_border_color(ctx->preview_pane,
                                  ui_theme_colors()->border, 0);
    lv_obj_set_style_radius(ctx->preview_pane, 8, 0);
    lv_obj_set_style_pad_all(ctx->preview_pane, 10, 0);
    lv_obj_set_style_pad_row(ctx->preview_pane, 8, 0);
    lv_obj_set_scrollbar_mode(ctx->preview_pane, LV_SCROLLBAR_MODE_AUTO);
    lv_obj_set_scroll_dir(ctx->preview_pane, LV_DIR_VER);
    lv_obj_set_flex_flow(ctx->preview_pane, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(ctx->preview_pane, LV_FLEX_ALIGN_START,
                          LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START);

    ctx->preview_title = lv_label_create(ctx->preview_pane);
    lv_obj_set_width(ctx->preview_title, LV_PCT(100));
    lv_label_set_text(ctx->preview_title, "Preview");
    lv_label_set_long_mode(ctx->preview_title, LV_LABEL_LONG_DOT);
    lv_obj_set_style_text_font(ctx->preview_title, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(ctx->preview_title,
                                ui_theme_colors()->accent, 0);

    ctx->preview = lv_label_create(ctx->preview_pane);
    lv_obj_set_width(ctx->preview, LV_PCT(100));
    lv_label_set_text(ctx->preview, "Select a file to preview.");
    lv_label_set_long_mode(ctx->preview, LV_LABEL_LONG_WRAP);
    lv_obj_set_style_text_font(ctx->preview, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(ctx->preview, ui_theme_colors()->text, 0);
}

static void build_ui(files_ctx_t *ctx, lv_obj_t *content)
{
    lv_obj_set_style_pad_all(content, 8, 0);
    lv_obj_remove_flag(content, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scrollbar_mode(content, LV_SCROLLBAR_MODE_OFF);

    ctx->path_label = lv_label_create(content);
    lv_obj_set_pos(ctx->path_label, 2, 2);
    lv_obj_set_size(ctx->path_label, 872, 24);
    lv_label_set_text(ctx->path_label, LV_SYMBOL_DIRECTORY "  /");
    lv_label_set_long_mode(ctx->path_label, LV_LABEL_LONG_DOT);
    lv_obj_set_style_text_font(ctx->path_label, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(ctx->path_label, ui_theme_colors()->text, 0);

    ctx->note_label = lv_label_create(content);
    lv_obj_set_pos(ctx->note_label, 2, 26);
    lv_obj_set_size(ctx->note_label, 872, 20);
    lv_label_set_text(ctx->note_label, "");
    lv_label_set_long_mode(ctx->note_label, LV_LABEL_LONG_DOT);
    lv_obj_set_style_text_font(ctx->note_label, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(ctx->note_label, ui_theme_colors()->warning, 0);
    lv_obj_add_flag(ctx->note_label, LV_OBJ_FLAG_HIDDEN);

    build_panes(ctx, content, 34);
}

static void resolve_start_dir(files_ctx_t *ctx)
{
    snprintf(ctx->cwd, sizeof(ctx->cwd), "/root");
    if (dir_openable(ctx->cwd)) return;

    const char *fallback = NULL;
    const char *home = getenv("HOME");
    if (home && home[0] == '/' && dir_openable(home)) {
        fallback = home;
    } else {
        fallback = "/";
    }
    copy_path(ctx->cwd, sizeof(ctx->cwd), fallback);
    char note[PATH_LEN + 64];
    snprintf(note, sizeof(note), "Note: /root unreadable; showing %s",
             fallback);
    lv_label_set_text(ctx->note_label, note);
    lv_obj_remove_flag(ctx->note_label, LV_OBJ_FLAG_HIDDEN);
    lv_obj_set_y(ctx->list, 56);
    lv_obj_set_height(ctx->list, 400 - 56);
    lv_obj_set_y(ctx->preview_pane, 56);
    lv_obj_set_height(ctx->preview_pane, 400 - 56);
    platform_log(note);
}

static void content_delete_cb(lv_event_t *e)
{
    files_ctx_t *ctx = (files_ctx_t *)lv_event_get_user_data(e);
    if (s_ctx == ctx) s_ctx = NULL;
    if (ctx) lv_free(ctx);
}

/* ------------------------------------------------------------------ */
/* Public API                                                          */
/* ------------------------------------------------------------------ */

void app_files_open(void)
{
    /* One Files window keeps the static refresh helpers unambiguous. */
    if (s_ctx) {
        wm_focus(s_ctx->win);
        return;
    }

    lv_obj_t *content = NULL;
    ui_window_t *win = wm_open("Files", FILES_W, FILES_H, false, &content,
                               NULL);
    if (!win || !content) return;

    files_ctx_t *ctx = lv_malloc_zeroed(sizeof(*ctx));
    if (!ctx) {
        wm_close(win);
        return;
    }
    ctx->win = win;
    s_ctx = ctx;

    build_ui(ctx, content);
    resolve_start_dir(ctx);
    files_refresh();

    lv_obj_add_event_cb(content, content_delete_cb, LV_EVENT_DELETE, ctx);
    wm_enable_bubble(content);
}
