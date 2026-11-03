/* gpu3ddemo.c —— P2a 可互动 3D 演示（旋转立方体，触摸拖拽改 yaw/pitch）
 *
 * 每帧（CPU）：
 *   1) 12 个三角形的顶点做 MVP（固定透视）+ 视口变换 → 屏幕空间 8.8 顶点
 *   2) 每个三角形算 Z 平面系数（与 RTL 同式）→ 写 48 B 记录进 arena
 *   3) CLEAR3D → DRAW_TRIS → FENCE → COMPOSITE3D（贴到 GUI bank 的 (x0,y0)）→ FLIP
 *
 * 用法：gpu3ddemo [帧数] [触摸设备]        （默认 300 帧、不开触摸）
 *   触摸拖拽 = 改 yaw/pitch；松手后自转继续。
 *
 * 几何约束（RTL 契约）：3D 缓冲 640×480、DRAW_TRIS 的 w/h 是 32 的倍数、
 * COMPOSITE3D 的 w % 64 == 0 且 dst_x % 4 == 0。
 */
#define _DEFAULT_SOURCE 1
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define GPU_BASE        0xF0005000UL
#define GPU_CMD_DATA    0x010
#define GPU_CMD_PUSH    0x014
#define GPU_SEQ_DONE    0x018
#define GPU_FIFO_FREE   0x01C

#define OP_CLEAR3D      0x10
#define OP_DRAW_TRIS    0x11
#define OP_COMPOSITE3D  0x12
#define OP_FENCE        0x07
#define OP_FILL         0x02
#define OP_BLIT         0x03
#define OP_GLYPH        0x04
#define OP_ROUND_FILL   0x05
#define OP_SET_SCISSOR  0x06

#define COLOR3D  0x93000000UL
#define Z3D      0x93100000UL
#define ARENA    0x93200000UL
#define W3D 640
#define H3D 480

/* GUI bank：0x9200_0000（bank0）/ 0x9220_0000（bank1），1024×600 RGB565 */
#define GUI_BANK0 0x92000000UL
#define GUI_BANK1 0x92200000UL
#define GUI_W 1024
#define GUI_H 600

static volatile uint32_t *csr;
static uint8_t  *dram;         /* 0x9300_0000 起 2.5 MB */
static uint8_t  *gui;          /* 两个 bank 之一（8 MB 窗） */
static uint32_t *arena;

static inline uint32_t rd(uint32_t o) { return csr[o >> 2]; }
static inline void wr(uint32_t o, uint32_t v) { csr[o >> 2] = v; }

static void push(uint8_t op, const uint32_t *p, int n)
{
    while ((int)(rd(GPU_FIFO_FREE) & 0x1F) < n + 1) { }
    wr(GPU_CMD_DATA, ((uint32_t)op << 24) | ((uint32_t)n << 16));
    for (int i = 0; i < n; i++)
        wr((i == n - 1) ? GPU_CMD_PUSH : GPU_CMD_DATA, p[i]);
}

static uint32_t s_seq = 1;
/* ⚠️ `SEQ_DONE` 不能单独当完成判据：gpu_cmd 对非 FENCE 命令也 +1（已知 wart），
 * 只看它会让 fence 提前返回 —— 既会把 fps 算高，也会让"帧还没画完就贴图"。
 * 真判据 = SEQ 到位 **且** GPU 空闲（STATUS.bit0 覆盖 busy 与队列非空）。 */
static void fence(void)
{
    uint32_t q[1] = { s_seq };
    push(OP_FENCE, q, 1);
    while (((rd(GPU_SEQ_DONE) & 0xFFFF) != (s_seq & 0xFFFF)) || ((rd(0x004) & 1u) != 0)) { }
    s_seq++;
}

/* ---------------- 3D 数学（float，够用；每帧 12 三角形） ---------------- */
typedef struct { float x, y, z; } v3;

static void rot(v3 *p, float cy, float sy, float cp, float sp)
{
    float x = p->x * cy + p->z * sy;
    float z = -p->x * sy + p->z * cy;
    float y = p->y * cp - z * sp;
    float z2 = p->y * sp + z * cp;
    p->x = x; p->y = y; p->z = z2;
}

/* 立方体 8 顶点（±1）与 12 个三角形（每面 2 个）。
 * 顶点编号：i&1→x=±1, i&2→y=±1, i&4→z=±1。
 * ★ 2026-11-01 上板修正：±X 两面原来写成 {0,3,7}/{0,7,4} 与 {1,5,6}/{1,6,2}，
 *   把 x=-1 的顶点(0,2,4,6)和 x=+1 的(1,3,5,7)混在同一个三角形里 ⇒ 这两个"面"
 *   是斜穿立方体的怪三角形，正对左/右时露出一片杂色、并把别的面切出错位。
 *   ±X 必须只用自己的 4 个顶点。 */
static const int CUBE_TRI[12][3] = {
    {0,1,3},{0,3,2},   /* -Z 面 (0,1,2,3)：沿主对角线 {0,3} 切，两片互补 */
    {4,5,7},{4,7,6},   /* +Z 面 (4,5,6,7)：同一条主对角线 */
    {0,4,5},{0,5,1},   /* -Y 面 (0,1,4,5) */
    {3,2,6},{3,6,7},   /* +Y 面 (2,3,6,7) */
    {0,2,6},{0,6,4},   /* -X 面 (0,2,4,6) */
    {1,3,7},{1,7,5},   /* +X 面 (1,3,5,7) */
};

static int32_t f2q8(float v) { return (int32_t)(v * 256.0f + (v >= 0 ? 0.5f : -0.5f)); }

static int64_t fdiv64(int64_t a, int64_t b)
{
    int64_t q = a / b;
    if ((a % b) != 0 && ((a < 0) != (b < 0))) q--;
    return q;
}

/* 写一条 48 B 三角形记录；返回 0 表示退化被跳过 */
/* ★ 2026-11-01 上板实测的**真 bug**：原来写的是 `(v.z + 1) * 0.5 * 65535`，而 v.z 是
 *   **视空间深度 zc = 4±1**（不是 [-1,1] 的归一化值）⇒ zi ∈ [131070,196605] 全部 clamp 成
 *   65535。Z 缓冲又被清成 0xFFFF、判据 zmode=LESS ⇒ `65535 < 65535` 恒假 ⇒ **每个像素都被
 *   拒**，颜色缓冲只剩底色，COMPOSITE 再把这张"底色图"贴到桌面 ⇒ 左上角看着像黑屏。
 *   改成按近远平面线性铺开，且上限留 0xFFFF 的余量（60000）。 */
#define Z_NEAR 0.2f
#define Z_FAR  8.0f

static int emit_tri(uint8_t *rec, const v3 v[3], uint16_t color)
{
    int32_t x[3], y[3];
    uint16_t z[3];
    /* ★ 2026-11-01 上板第三修：**每个三角形整片用同一个 z**（三个顶点的质心深度）。
     *   立方体是凸体 ⇒ 面内不存在自遮挡，只需要"面与面之间"的深度排序；用常数 z 就等价于
     *   按面排序，而这正是 `gputest3d` 逐像素验证过的那条路径（它的三角形全是 dzdx=dzdy=0）。
     *   逐像素深度渐变（dzdx/dzdy）在板上从没被验证过，之前两次都栽在它的单位换算上；
     *   这里先不用，等把 dz 的契约单独开一条闸门再说。 */
    float zc_m = (v[0].z + v[1].z + v[2].z) / 3.0f;
    int zm = (int)((zc_m - Z_NEAR) / (Z_FAR - Z_NEAR) * 60000.0f + 0.5f);
    if (zm < 0) zm = 0;
    if (zm > 60000) zm = 60000;
    for (int i = 0; i < 3; i++) {
        x[i] = f2q8(v[i].x);
        y[i] = f2q8(v[i].y);
        z[i] = (uint16_t)zm;
    }
    int64_t area = (int64_t)(x[1] - x[0]) * (y[2] - y[0])
                 - (int64_t)(y[1] - y[0]) * (x[2] - x[0]);
    if (area == 0) return 0;
    int64_t n1 = (int64_t)(z[1] - z[0]) * (y[2] - y[0])
               - (int64_t)(z[2] - z[0]) * (y[1] - y[0]);
    int64_t n2 = (int64_t)(z[2] - z[0]) * (x[1] - x[0])
               - (int64_t)(z[1] - z[0]) * (x[2] - x[0]);
    /* ★ 2026-11-01 上板第二修：dz 的**单位换算少了 256**。
     *   RTL 是「每像素 zacc += dzdx，最后 zacc>>16」⇒ Δz = dzdx·Δpx/256，
     *   即 dzdx 必须是「每像素 z 增量 × 256」。而 area/n1 都在 8.8 单位里算，
     *   n1/area 是「每 8.8 单位」的梯度 ⇒ 要再乘 256(→每像素) 再乘 256(→zacc 单位)
     *   = **×65536**。原来只乘 256 ⇒ 面内几乎常数深度，面与面只靠 z0 硬排 ⇒ 看着错位。
     *   （gputest3d 的三角形全是 dzdx=dzdy=0，这条路径它从来没覆盖过。） */
    int32_t dzdx = (int32_t)fdiv64(n1 * 65536, area);
    int32_t dzdy = (int32_t)fdiv64(n2 * 65536, area);
    uint64_t *w = (uint64_t *)rec;
    w[0] = ((uint64_t)(uint32_t)y[0] << 32) | (uint32_t)x[0];
    w[1] = ((uint64_t)(uint32_t)y[1] << 32) | (uint32_t)x[1];
    w[2] = ((uint64_t)(uint32_t)y[2] << 32) | (uint32_t)x[2];
    w[3] = ((uint64_t)(uint32_t)dzdx << 32) | ((uint64_t)color << 16) | z[0];
    w[4] = (uint64_t)(uint32_t)dzdy;      /* zmode = LESS(0) */
    w[5] = 0;
    return 1;
}

static void clear3d(uint16_t color, uint16_t z)
{
    uint32_t p[8] = { color, z, W3D, H3D, COLOR3D, W3D, Z3D, W3D };
    push(OP_CLEAR3D, p, 8);
}

static void draw3d(uint32_t tri_phys, int count)
{
    uint32_t p[8] = { tri_phys, (uint32_t)count, W3D, H3D, COLOR3D, W3D, Z3D, W3D };
    push(OP_DRAW_TRIS, p, 8);
}

static void comp3d(uint32_t dst, int dst_stride, int dx, int dy, int w, int h)
{
    uint32_t p[8] = { COLOR3D, W3D, dst, (uint32_t)dst_stride, (uint32_t)w, (uint32_t)h,
                      (uint32_t)dx, (uint32_t)dy };
    push(OP_COMPOSITE3D, p, 8);
}

/* ---------------- 触摸（可选）：拖拽改 yaw/pitch ---------------- */
struct input_event_s { long tv_sec, tv_usec; uint16_t type, code; int32_t value; };

static float g_yaw, g_pitch;
static int   g_touch_fd = -1, g_dragging;
static int32_t g_last_x, g_last_y;

static void poll_touch(void)
{
    if (g_touch_fd < 0) return;
    struct input_event_s ev;
    while (read(g_touch_fd, &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) {
        if (ev.type == 3 /* EV_ABS */) {
            if (ev.code == 0x35 /* ABS_MT_POSITION_X */ || ev.code == 0 /* ABS_X */) {
                if (g_dragging) g_yaw += (float)(ev.value - g_last_x) * 0.01f;
                g_last_x = ev.value;
            } else if (ev.code == 0x36 /* ABS_MT_POSITION_Y */ || ev.code == 1 /* ABS_Y */) {
                if (g_dragging) g_pitch += (float)(ev.value - g_last_y) * 0.01f;
                g_last_y = ev.value;
            }
        } else if (ev.type == 1 /* EV_KEY */ && ev.code == 0x14A /* BTN_TOUCH */) {
            g_dragging = (ev.value != 0);
        }
    }
}

/* 渲染一帧（不含贴图）：变换 12 个三角形 → 写记录 → CLEAR3D → DRAW_TRIS → FENCE。
 * ★ 2026-11-01：sin/cos 原来是**泰勒近似**（`sy=ay-ay³/6+ay⁵/120`，只在 |a|≲1 rad 成立；
 *   yaw=π 时算出 cos≈0.13，真值 −1）⇒ 旋转矩阵根本不正交 ⇒ 立方体被剪切变形 ⇒
 *   "面错位"。改用 libm 的 sinf/cosf（构建加 -lm）。 */
/* ======================= yshell 桌面风格 UI 层 =======================
 * 规范（取自 YeshenGui）：
 *   · 画布 1024×720，**可见区在第 60..659 行**（屏幕 1024×600）；
 *   · 主题（浅色档）：窗口 #F7F9FC、边框 #C9D1DB、标题栏 #DDE3EA、正文 #1F2933、
 *     次要文字 #4A5B6E、Debian 红 accent #A80030；窗口圆角 8..10、标题栏 36~40 px；
 *   · 字体 = LVGL unscii_8（已导出成 gpu_font8.h）；
 *   · 文字用 2D 引擎的 GLYPH（A8 覆盖率 + fg），矩形用 FILL/ROUND_FILL。
 * 只画 GUI bank（0x92000000/0x92200000），跑演示时 yshell 需暂停。 */
#include "gpu_font8.h"

#define SCR_W   1024
#define SCR_H   600
#define VIS_Y0  60                       /* 可见区在 720 行帧存里的起始行 */
#define VIS_OFF (VIS_Y0 * SCR_W * 2)     /* 可见区在 bank 内的字节偏移 */

#define C565(r,g,b) ((uint16_t)((((r) & 0xF8) << 8) | (((g) & 0xFC) << 3) | ((b) >> 3)))
#define COL_BG_TOP  C565(0x1B,0x24,0x30)
#define COL_BG_BOT  C565(0x33,0x41,0x51)
#define COL_WIN     C565(0xF7,0xF9,0xFC)
#define COL_BORDER  C565(0xC9,0xD1,0xDB)
#define COL_TITLE   C565(0xDD,0xE3,0xEA)
#define COL_TEXT    C565(0x1F,0x29,0x33)
#define COL_SUBTEXT C565(0x4A,0x5B,0x6E)
#define COL_ACCENT  C565(0xA8,0x00,0x30)
#define COL_STATUS  C565(0xE9,0xED,0xF2)
#define COL_SHADOW  C565(0x0E,0x14,0x1B)
#define BG3D        C565(0xE7,0xED,0xF4)   /* 3D 视口底色（自检也用它当背景判据） */

#define WIN_X    112
#define WIN_Y    24
#define WIN_W    800
#define WIN_H    552
#define TITLE_H  40
#define STAT_H   32
#define VIEW_X   (WIN_X + (WIN_W - 640) / 2)
#define VIEW_Y   (WIN_Y + TITLE_H + 4)

static inline uint32_t bank_dst(int bank) { return (bank ? GUI_BANK1 : GUI_BANK0) + VIS_OFF; }

/* ⚠️ 2D 引擎的 scissor 是**持久状态**：yshell 被中止时会留下一个小的裁剪窗，
 * 演示若不自己设，FILL 画到窗外就被裁掉（2026-11-01 实测：渐变在 y≈256 处断掉）。 */
static void gscissor(void)
{
    uint32_t p[4] = { 0, 0, SCR_W, SCR_H };
    push(OP_SET_SCISSOR, p, 4);
}

static void gfill(uint32_t dst, int x, int y, int w, int h, uint16_t c)
{
    uint32_t p[7] = { dst, SCR_W, (uint32_t)x, (uint32_t)y, (uint32_t)w, (uint32_t)h, c };
    push(OP_FILL, p, 7);
}

static void ground_fill(uint32_t dst, int x, int y, int w, int h, int r, uint16_t c)
{
    uint32_t p[8] = { dst, SCR_W, (uint32_t)x, (uint32_t)y, (uint32_t)w, (uint32_t)h, (uint32_t)r, c };
    push(OP_ROUND_FILL, p, 8);
}

/* 文字：把 8×8 点阵展开成 A8（1 B/像素）再走 GLYPH。
 * 4 个槽轮转，避免 CPU 改写 GPU 还没读完的那块（命令是串行的，但 FIFO 允许 CPU 跑在前面）。 */
#define TEX_STRIDE 512
#define TEX_SLOTS  4
#define TEX_BYTES  (TEX_STRIDE * 10)
#define TEX_PHYS   (ARENA + 0x10000u)     /* arena 内偏移 64 KB，避开三角形记录 */

static void gtext(uint32_t dst, int x, int y, const char *s, uint16_t fg)
{
    static int slot;
    int n = 0;
    while (s[n] && n < 60) n++;
    if (!n) return;
    uint8_t *buf = (uint8_t *)(dram + (TEX_PHYS - COLOR3D) + (uint32_t)(slot & (TEX_SLOTS - 1)) * TEX_BYTES);
    memset(buf, 0, TEX_BYTES);
    for (int i = 0; i < n; i++) {
        int ch = (unsigned char)s[i];
        if (ch < 32 || ch > 126) continue;
        const unsigned char *gl = FONT8[ch - 32];
        for (int ry = 0; ry < 8; ry++)
            for (int rx = 0; rx < 8; rx++)
                if (gl[ry] & (0x80 >> rx)) buf[ry * TEX_STRIDE + i * 8 + rx] = 0xFF;
    }
    uint32_t phys = TEX_PHYS + (uint32_t)(slot & (TEX_SLOTS - 1)) * TEX_BYTES;
    slot++;
    uint32_t p[12] = { phys, TEX_STRIDE, 0, 0, (uint32_t)(n * 8), 8,
                       dst, SCR_W, (uint32_t)x, (uint32_t)y, fg, 255 };
    push(OP_GLYPH, p, 12);
}

/* 桌面外观：竖向渐变壁纸 + 带阴影/边框/标题栏的窗口（含静态文字） */
static void draw_desktop(uint32_t dst)
{
    gscissor();                       /* 先清掉残留裁剪窗 */
    for (int i = 0; i < 20; i++) {
        int r = 0x1B + (0x33 - 0x1B) * i / 19;
        int g = 0x24 + (0x41 - 0x24) * i / 19;
        int b = 0x30 + (0x51 - 0x30) * i / 19;
        gfill(dst, 0, i * (SCR_H / 20), SCR_W, SCR_H / 20, C565(r, g, b));
    }
    ground_fill(dst, WIN_X + 7, WIN_Y + 9, WIN_W, WIN_H, 12, COL_SHADOW);
    ground_fill(dst, WIN_X - 2, WIN_Y - 2, WIN_W + 4, WIN_H + 4, 12, COL_BORDER);
    ground_fill(dst, WIN_X, WIN_Y, WIN_W, WIN_H, 10, COL_WIN);
    /* 标题栏：上沿圆角、下沿方角 */
    ground_fill(dst, WIN_X, WIN_Y, WIN_W, TITLE_H, 10, COL_TITLE);
    gfill(dst, WIN_X, WIN_Y + 10, WIN_W, TITLE_H - 10, COL_TITLE);
    gfill(dst, WIN_X, WIN_Y + TITLE_H - 1, WIN_W, 1, COL_BORDER);
    /* accent 竖条 + 标题 */
    gfill(dst, WIN_X + 14, WIN_Y + 12, 5, 16, COL_ACCENT);
    gtext(dst, WIN_X + 28, WIN_Y + 16, "3D CUBE  -  GPU RASTER DEMO", COL_TEXT);
    gtext(dst, WIN_X + WIN_W - 96, WIN_Y + 16, "YSHEN", COL_SUBTEXT);
    /* 状态栏：上沿细线 + 圆角底 */
    ground_fill(dst, WIN_X, WIN_Y + WIN_H - STAT_H, WIN_W, STAT_H, 10, COL_STATUS);
    gfill(dst, WIN_X, WIN_Y + WIN_H - STAT_H, WIN_W, 10, COL_STATUS);
    gfill(dst, WIN_X, WIN_Y + WIN_H - STAT_H, WIN_W, 1, COL_BORDER);
}

/* 把 565 颜色按 s 缩放（逐面光照用） */
static uint16_t shade565(uint16_t c, float s)
{
    int r = (c >> 11) & 0x1F, g = (c >> 5) & 0x3F, b = c & 0x1F;
    r = (int)(r * s + 0.5f); g = (int)(g * s + 0.5f); b = (int)(b * s + 0.5f);
    if (r > 31) r = 31; if (g > 63) g = 63; if (b > 31) b = 31;
    return (uint16_t)((r << 11) | (g << 5) | b);
}

/* 屏幕空间轴对齐四边形 → 2 条记录（常数 z） */
static int emit_quad(uint8_t *rec, int x0, int y0, int x1, int y1, uint16_t color, uint16_t z)
{
    static const int T[2][3] = { {0,1,2}, {0,2,3} };
    int32_t X[4] = { x0, x1, x1, x0 }, Y[4] = { y0, y0, y1, y1 };
    uint64_t *w = (uint64_t *)rec;
    for (int t = 0; t < 2; t++) {
        uint64_t *o = w + t * 6;
        for (int k = 0; k < 3; k++) {
            int i = T[t][k];
            o[k] = ((uint64_t)(uint32_t)(Y[i] * 256) << 32) | (uint32_t)(X[i] * 256);
        }
        o[3] = ((uint64_t)color << 16) | z;   /* dzdx = 0 */
        o[4] = 0;                             /* dzdy = 0, zmode = LESS */
        o[5] = 0;
    }
    return 2;
}

static int render_scene(float yaw, float pitch, int shaded, float camz)
{
    const float focal = 480.0f * 1.2f, cxp = 320.0f, cyp = 240.0f;
    float syv = sinf(yaw), cyv = cosf(yaw), spv = sinf(pitch), cpv = cosf(pitch);
    static const uint16_t FACE_COL[6] = { 0xF800, 0x07E0, 0x001F, 0xFFE0, 0xF81F, 0x07FF };
    /* 每面的 4 个顶点 + 外法线（未旋转坐标）。★ 2026-11-01：**背面剔除**。
     *   透视下"侧对相机"的面仍会投出一个 77 px 宽的梯形（不是零面积）；不剔除就会
     *   切进正面的方块里 —— 上板六向自检抓到的正是这个（front/back 只有 91% 填充、
     *   左缘混进 +X 面的青色）。按法线只画朝向相机的面，凸立方体最多 3 面且互不重叠。 */
    static const int FACE_V[6][4] = {
        {0,1,2,3}, {4,5,6,7}, {0,1,4,5}, {2,3,6,7}, {0,2,4,6}, {1,3,5,7}
    };
    static const float FACE_N[6][3] = {
        {0,0,-1}, {0,0,1}, {0,-1,0}, {0,1,0}, {-1,0,0}, {1,0,0}
    };
    v3 cube[8];
    for (int i = 0; i < 8; i++) {
        cube[i].x = (i & 1) ? 1.0f : -1.0f;
        cube[i].y = (i & 2) ? 1.0f : -1.0f;
        cube[i].z = (i & 4) ? 1.0f : -1.0f;
        rot(&cube[i], cyv, syv, cpv, spv);
    }
    int vis[6];
    for (int f = 0; f < 6; f++) {
        v3 n = { FACE_N[f][0], FACE_N[f][1], FACE_N[f][2] }, c = { 0, 0, 0 };
        rot(&n, cyv, syv, cpv, spv);
        for (int k = 0; k < 4; k++) {
            const v3 *p = &cube[FACE_V[f][k]];
            c.x += p->x * 0.25f; c.y += p->y * 0.25f; c.z += p->z * 0.25f;
        }
        /* 相机在 (0,0,4)，视线朝 -Z ⇒ 面朝相机 ⇔ 法线·(相机-面心) > 0 */
        vis[f] = (n.x * (0 - c.x) + n.y * (0 - c.y) + n.z * (camz - c.z)) > 0.0f;
    }
    int nrec = 0;
    /* ★ 2026-11-01：视口背景**不再用 3D 三角形画**——3 条大色带 = 约 600 个 32×32 tile，
     * 实测把帧率从 ~4.6 压到 ~1.6 fps（每个 tile 约 0.7 ms，DDR 延迟主导）。
     * 改成 CLEAR3D 的纯色底（0 个 tile）。 */
    for (int t = 0; t < 12; t++) {
        if (!vis[t / 2]) continue;              /* 背面剔除 */
        v3 vv[3];
        int ok = 1;
        for (int k = 0; k < 3; k++) {
            v3 p = cube[CUBE_TRI[t][k]];
            float zc = camz - p.z;              /* 相机在 (0,0,4) 朝 -Z ⇒ 深度 = 4 - z（原来写成 +z，一半立方体跑到相机背后） */
            if (zc < 0.2f) { ok = 0; break; }   /* 近平面裁剪（整片丢，够用） */
            vv[k].x = cxp + focal * p.x / zc;
            vv[k].y = cyp - focal * p.y / zc;
            vv[k].z = zc;
        }
        if (!ok) continue;
        uint16_t col = FACE_COL[t / 2];
        if (shaded) {
            /* 逐面光照：视线空间固定光源（左上偏前），N·L 决定明暗；同一种材质色 */
            v3 nn = { FACE_N[t / 2][0], FACE_N[t / 2][1], FACE_N[t / 2][2] };
            rot(&nn, cyv, syv, cpv, spv);
            float ndl = nn.x * (-0.45f) + nn.y * 0.55f + nn.z * 0.72f;
            if (ndl < 0.0f) ndl = 0.0f;
            col = shade565(COL_ACCENT, 0.32f + 0.78f * ndl);
        }
        if (emit_tri((uint8_t *)(arena + nrec * 12), vv, col)) nrec++;
    }
    __sync_synchronize();
    clear3d(BG3D, 0xFFFF);                      /* 视口底色：浅冷灰（桌面风格） */
    if (nrec) draw3d(ARENA, nrec);
    fence();
    return nrec;
}

/* 六向自检（用户判据）：正对某个面时必须是一整块**纯色方块**。
 * 可见面 = 离相机最近那面（zc = 4-1 = 3）⇒ 投影半边长 = focal/3 = 192 px
 * ⇒ 期望 bbox [128,511]×[48,431]、单色、单深度（每面常数 z）。 */
static int selftest(void)
{
    static const struct { float yaw, pitch; uint16_t col; const char *name; } V[6] = {
        { 0.0f,          0.0f,          0x07E0, "front(+Z)" },
        { 3.14159265f,   0.0f,          0xF800, "back(-Z)"  },
        { 1.57079633f,   0.0f,          0xF81F, "left(-X)"  },
        { -1.57079633f,  0.0f,          0x07FF, "right(+X)" },
        { 0.0f,          1.57079633f,   0xFFE0, "down(+Y)"  },
        { 0.0f,         -1.57079633f,   0x001F, "up(-Y)"    },
    };
    const uint16_t BG = BG3D;
    const uint16_t *c3 = (const uint16_t *)dram;
    const uint16_t *z3 = (const uint16_t *)(dram + (Z3D - COLOR3D));
    int bad = 0;
    for (int v = 0; v < 6; v++) {
        render_scene(V[v].yaw, V[v].pitch, 0, 4.0f);
        int x0 = 1 << 20, y0 = 1 << 20, x1 = -1, y1 = -1;
        long n = 0, ncol = 0, nz = 0;
        uint16_t z0v = 0; int z0set = 0;
        for (int y = 0; y < H3D; y++)
            for (int x = 0; x < W3D; x++) {
                uint16_t c = c3[y * W3D + x];
                if (c == BG) continue;
                if (x < x0) x0 = x; if (x > x1) x1 = x;
                if (y < y0) y0 = y; if (y > y1) y1 = y;
                if (c == V[v].col) ncol++;
                uint16_t z = z3[y * W3D + x];
                if (!z0set) { z0v = z; z0set = 1; }
                else if (z == z0v) nz++;
                n++;
            }
        int ok_bb  = (x0 >= 122 && x0 <= 134 && x1 >= 505 && x1 <= 517 &&
                      y0 >= 42  && y0 <= 54  && y1 >= 425 && y1 <= 437);
        int ok_col = (n > 0 && ncol * 1000 >= n * 998);          /* ≥99.8% 同色 */
        int ok_z   = (n > 0 && (nz + 1) * 1000 >= n * 998);
        /* 填满度：384×384 = 147456，允许 ±1%（不许有洞、也不许多出像素） */
        int ok_fill = (n >= 145980 && n <= 148932);
        printf("  [%s] bbox=(%d..%d, %d..%d) n=%ld/147456 center=%04X exp=%04X z=%04X%s%s%s%s\n",
               V[v].name, x0, x1, y0, y1, n, n ? c3[240 * W3D + 320] : 0, V[v].col, z0v,
               ok_bb ? "" : " BBOX!", ok_col ? "" : " COLOR!", ok_z ? "" : " Z!",
               ok_fill ? "" : " FILL!");
        if (!ok_bb || !ok_col || !ok_z || !ok_fill) {
            bad++;
            for (int yy = 0; yy < 12; yy++) {
                char line[18];
                for (int xx = 0; xx < 16; xx++) {
                    uint16_t c = c3[(yy * 40 + 20) * W3D + (xx * 40 + 20)];
                    line[xx] = (c == BG) ? '.' : (c == V[v].col ? '#' : '?');
                }
                line[16] = 0;
                printf("      %s\n", line);
            }
            for (int px = 140; px <= 300; px += 40) {
                int i = 240 * W3D + px;
                printf("      x=%d c=%04X z=%04X\n", px, c3[i], z3[i]);
            }
        }
    }
    printf("gpu3ddemo: 六向自检 %s（bad=%d/6）\n", bad ? "FAIL" : "PASS", bad);
    return bad;
}

int main(int argc, char **argv)
{
    int frames = (argc > 1) ? atoi(argv[1]) : 300;
    const char *tdev = (argc > 2) ? argv[2] : NULL;
    if (frames <= 0) frames = 300;
    setvbuf(stdout, NULL, _IONBF, 0);   /* 后台跑时日志要能实时 tail（否则 4KB 才刷） */

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 2; }
    csr  = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)GPU_BASE);
    dram = mmap(NULL, 0x280000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)COLOR3D);
    gui  = mmap(NULL, GUI_W * GUI_H * 2, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)GUI_BANK0);
    if (csr == MAP_FAILED || dram == MAP_FAILED || gui == MAP_FAILED) { perror("mmap"); return 2; }
    arena = (uint32_t *)(dram + (ARENA - COLOR3D));

    uint32_t id = rd(0x000);
    printf("gpu3ddemo: ID=0x%08X frames=%d\n", id, frames);
    if (id != 0x59475055u) return 1;
    if (argc > 1 && strcmp(argv[1], "--selftest") == 0) return selftest();

    if (tdev) {
        g_touch_fd = open(tdev, O_RDONLY | O_NONBLOCK);
        printf("gpu3ddemo: touch=%s fd=%d\n", tdev, g_touch_fd);
    }

    /* 桌面外观只画一次（两个 bank 都画）——之后每帧只更新视口与状态栏，省 2D 流量 */
    draw_desktop(bank_dst(0));
    draw_desktop(bank_dst(1));
    fence();
    printf("gpu3ddemo: desktop chrome drawn (window %dx%d @ %d,%d, viewport @ %d,%d)\n",
           WIN_W, WIN_H, WIN_X, WIN_Y, VIEW_X, VIEW_Y);

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    for (int f = 0; f < frames; f++) {
        poll_touch();
        if (!g_dragging) g_yaw += 0.02f;      /* 不拖拽时自转 */
        /* 角度归一到 (-π, π]（sin/cos 已改 libm，这里只是保持角度不无限增长） */
        while (g_yaw > 3.14159265f)  g_yaw -= 6.28318531f;
        while (g_yaw < -3.14159265f) g_yaw += 6.28318531f;
        while (g_pitch > 1.5f)  g_pitch = 1.5f;
        while (g_pitch < -1.5f) g_pitch = -1.5f;

        int nrec = render_scene(g_yaw, g_pitch, 1, 5.2f);
        struct timespec tn;
        clock_gettime(CLOCK_MONOTONIC, &tn);
        double el = (double)(tn.tv_sec - t0.tv_sec) + 1e-9 * (double)(tn.tv_nsec - t0.tv_nsec);
        double fps = (el > 0.001) ? (double)(f + 1) / el : 0.0;
        char line[80];
        snprintf(line, sizeof line, "FPS %5.1f    TRIS %02d    640x480    101.25 MHZ",
                 fps, nrec);
        /* 两个 bank 都更新：`gui_bank = GUI_CTRL[1] ^ GPU.flip_toggle`，本演示不翻页，
         * 只贴一个 bank 时可能正好贴在"看不见"的那面（2026-11-01 上板踩过）。 */
        for (int b = 0; b < 2; b++) {
            uint32_t d = bank_dst(b);
            comp3d(d, SCR_W, VIEW_X, VIEW_Y, 640, 480);
            gfill(d, WIN_X + 13, WIN_Y + WIN_H - 25, 520, 18, COL_STATUS);   /* 先擦旧字 */
            gtext(d, WIN_X + 14, WIN_Y + WIN_H - 24, line, COL_SUBTEXT);
        }
        fence();

        if ((f % 30) == 0) printf("gpu3ddemo: frame %d tris=%d\n", f, nrec);
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);
    double dt = (double)(t1.tv_sec - t0.tv_sec) + 1e-9 * (double)(t1.tv_nsec - t0.tv_nsec);
    printf("gpu3ddemo: %d 帧 %.3f s => %.2f fps\n", frames, dt, (double)frames / dt);
    printf("gpu3ddemo: DBG=0x%08X\n", (unsigned)rd(0x02C));
    return 0;
}
