/* gputest3d.c —— P2a 3D 板上判据（自检：C 里独立算黄金，逐像素比颜色 + Z）
 *
 *  ① ID 魔数
 *  ② CLEAR3D：颜色缓冲 640×480 清 0、Z 缓冲清 0xFFFF（抽查若干行）
 *  ③ DRAW_TRIS：两个三角形（先远后近，近的只盖左半边）→ 逐像素比黄金
 *  ④ Z 负对照：把近的那个改成 zmode=OFF 再画一次 —— 判据必须报错（证明有区分力）
 *  ⑤ COMPOSITE3D：把 640×480 颜色缓冲贴到另开的 320×200 缓冲 (8,4)，
 *     逐像素比"目标区=源、其余=哨兵"
 *
 * 与 RTL 同口径（rtl/gpu/tri_setup.v / tri_raster.v / sim/gpu/tri_ref.py）：
 *   顶点 (x_q8,y_q8,z)，面积归一（area<0 交换 v1/v2），边函数 E>=0 为内，
 *   像素中心 (px<<8)+128，z = z0 + ((dzdx*(sx-x0)+dzdy*(sy-y0))>>16)
 */
#define _DEFAULT_SOURCE 1
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define GPU_BASE        0xF0005000UL
#define GPU_CMD_DATA    0x010
#define GPU_CMD_PUSH    0x014
#define GPU_SEQ_DONE    0x018
#define GPU_FIFO_FREE   0x01C
#define GPU_DBG         0x02C

#define OP_CLEAR3D      0x10
#define OP_DRAW_TRIS    0x11
#define OP_COMPOSITE3D  0x12
#define OP_FENCE        0x07

#define COLOR3D  0x93000000UL
#define Z3D      0x93100000UL
#define ARENA    0x93200000UL
#define W3D 640
#define H3D 480

/* 复合目标：320×200 @ 0x93280000（arena 内，16 B 对齐）。
 * ⚠️ dst 行宽必须 ≥ dx + w，否则每行会**线性溢出到下一行行首**（RTL 是按 stride 定位、
 * 按 w 连续写，不做行内裁剪）：原来 DW3D=256 + DX3D=8 + w=256 ⇒ 每行尾部 8 px 落到
 * 下一行 x=0..7，判据报 195×8=1560 个失配（2026-11-01 上板实测，是判据几何错、不是 RTL 错）。 */
#define DST3D   0x93280000UL
#define DW3D 320
#define DH3D 200
#define DX3D 8
#define DY3D 4
#define SENTINEL 0xAAAA

static volatile uint32_t *csr;
static uint8_t *dram;          /* 0x9300_0000 起 2.5 MB 的窗口 */
static uint16_t *color3d, *z3d, *dstbuf;
static uint32_t *arena;

#define GPU_DBG2        0x030
#define GPU_DBG3        0x034

static inline uint32_t rd(uint32_t o) { return csr[o >> 2]; }
static inline void wr(uint32_t o, uint32_t v) { csr[o >> 2] = v; }

/* 挂死时把边界探针打干净再退出：STATUS/SEQ/FREE + 3D FSM 状态 + 读引擎 + gpu_mem 写侧。
 * 没有这一层，主机只能看到一个不动的进程（上一轮就是这样丢掉定位信息的）。 */
static void dump_probes(const char *why)
{
    uint32_t st = rd(0x004), d1 = rd(GPU_DBG), d3 = rd(GPU_DBG3);
    printf("  !! %s\n", why);
    printf("     STATUS=%08X SEQ=%08X FREE=%08X DBG=%08X DBG2=%08X DBG3=%08X\n",
           st, rd(GPU_SEQ_DONE), rd(GPU_FIFO_FREE), d1, rd(GPU_DBG2), d3);
    printf("     op=%02X st3d=%u lastcyc=%u | mem=%02X rdlen=%u rdcnt=%u\n",
           (d1 >> 24) & 0xFF, (d1 >> 16) & 0xFF, d1 & 0xFFFF,
           (d3 >> 24) & 0xFF, (d3 >> 16) & 0xFF, (d3 >> 8) & 0xFF);
    fflush(stdout);
}

static void push(uint8_t op, const uint32_t *p, int n)
{
    long budget = 40000000L;
    while ((int)(rd(GPU_FIFO_FREE) & 0x1F) < n + 1) {
        if (--budget == 0) { dump_probes("push: FIFO free timeout"); exit(3); }
    }
    wr(GPU_CMD_DATA, ((uint32_t)op << 24) | ((uint32_t)n << 16));
    for (int i = 0; i < n; i++)
        wr((i == n - 1) ? GPU_CMD_PUSH : GPU_CMD_DATA, p[i]);
}

/* ★ 2026-11-02：**这块 SoC 的 /dev/mem 是可缓存的**（VexiiRiscv 的 PMA 不区分 UC），
 * 所以 CPU↔GPU 共享 DDR 必须自己做 CBO 维护，否则判据会"自己骗自己"：
 *   · CPU 写哨兵 → 脏行留在 L1D → GPU 已把正确像素写进 DDR，CPU 却读回自己的旧值
 *     （现象 = got=AAAA exp=001F，"像丢了 1.8% 的写拍"，第二次比对又变干净 —— 因为
 *      第一次比对读 128 KB 把脏行挤回 DDR 了）；P0 的 zicbom 就是为这条链开的。
 *   · 写三角形记录同样要 flush，否则 GPU 可能读到旧记录。
 * 约定：CPU 写完 → cbo_flush；GPU 写完、CPU 要读 → cbo_inval（此前必须已 flush 过）。 */
static inline void cbo_flush(void *p) { __asm__ volatile("cbo.flush (%0)" :: "r"(p) : "memory"); }
/* 本核只放行 CBCFE（flush/clean）；CBIE=0 ⇒ cbo.inval 故意 SIGILL（P0 的门），
 * 所以"丢缓存里的旧副本"一律用 cbo.flush（干净行 = 直接丢弃）。 */
static inline void cbo_inval(void *p) { __asm__ volatile("cbo.flush (%0)" :: "r"(p) : "memory"); }
static void cbo_range(void *p, size_t n, int inval)
{
    uintptr_t a = (uintptr_t)p & ~(uintptr_t)63;
    uintptr_t e = ((uintptr_t)p + n + 63) & ~(uintptr_t)63;
    for (; a < e; a += 64) { if (inval) cbo_inval((void *)a); else cbo_flush((void *)a); }
}
#define RANGE_FLUSH(p, n) cbo_range((p), (n), 0)
#define RANGE_INVAL(p, n) cbo_range((p), (n), 1)

static int g_err;
/* ⚠️ `GPU_SEQ_DONE` **不能单独当完成判据**：gpu_cmd 对非 FENCE 命令也会 +1（已知 wart），
 * 所以 fence(seq) 可能被前一条命令的完成提前满足 —— 2026-11-01 上板实测：fence 在 DRAW
 * 只画到第 33/300 个 tile 时就返回了，随后的比对纯靠"CPU 比 GPU 慢"侥幸对上。
 * 真判据 = SEQ 到位 **且** GPU 空闲（STATUS.bit0 覆盖 busy 与队列非空）。 */
static void fence(void)
{
    static uint32_t seq = 1;
    uint32_t q[1] = { seq };
    long budget = 60000000L;
    printf("  [fence %u] push 求完成 ...\n", seq);
    push(OP_FENCE, q, 1);
    while (((rd(GPU_SEQ_DONE) & 0xFFFF) != (seq & 0xFFFF)) || ((rd(0x004) & 1u) != 0)) {
        if (--budget == 0) { dump_probes("fence timeout"); exit(3); }
    }
    printf("  [fence %u] done（SEQ=%08X）\n", seq, rd(GPU_SEQ_DONE));
    seq++;
}

/* ---------------- 三角形记录（48 B） ---------------- */
typedef struct {
    int32_t x0, y0, x1, y1, x2, y2;   /* 8.8 */
    uint16_t z0, z1, z2;
    uint16_t color;
    int32_t dzdx, dzdy;
    uint16_t zmode;
} tri_t;

static void rec_pack(uint8_t *d, const tri_t *t)
{
    uint64_t *w = (uint64_t *)d;
    w[0] = ((uint64_t)(uint32_t)t->y0 << 32) | (uint32_t)t->x0;
    w[1] = ((uint64_t)(uint32_t)t->y1 << 32) | (uint32_t)t->x1;
    w[2] = ((uint64_t)(uint32_t)t->y2 << 32) | (uint32_t)t->x2;
    w[3] = ((uint64_t)(uint32_t)t->dzdx << 32) | ((uint64_t)t->color << 16) | t->z0;
    w[4] = ((uint64_t)(t->zmode & 3) << 32) | (uint32_t)t->dzdy;
    w[5] = 0;
}

/* 有符号除法取 floor（C 的 / 是向零截断，与 Python // 和 RTL 的 >>> 不同） */
static int64_t fdiv(int64_t a, int64_t b)
{
    int64_t q = a / b;
    if ((a % b) != 0 && ((a < 0) != (b < 0))) q--;
    return q;
}
static int64_t sar16(int64_t v) { return (v >= 0) ? (v >> 16) : -(((-v) + 0xFFFF) >> 16); }

/* 与 RTL 同式的 Z 平面系数（area 用原顶点序；平面与绕向无关） */
static void plane(const tri_t *t, int32_t *dzdx, int32_t *dzdy)
{
    int64_t area = (int64_t)(t->x1 - t->x0) * (t->y2 - t->y0)
                 - (int64_t)(t->y1 - t->y0) * (t->x2 - t->x0);
    if (area == 0) { *dzdx = 0; *dzdy = 0; return; }
    int64_t n1 = (int64_t)(t->z1 - t->z0) * (t->y2 - t->y0)
               - (int64_t)(t->z2 - t->z0) * (t->y1 - t->y0);
    int64_t n2 = (int64_t)(t->z2 - t->z0) * (t->x1 - t->x0)
               - (int64_t)(t->z1 - t->z0) * (t->x2 - t->x0);
    *dzdx = (int32_t)fdiv(n1 * 256, area);
    *dzdy = (int32_t)fdiv(n2 * 256, area);
}

/* ---------------- C 黄金光栅 ---------------- */
static void raster_tri(uint16_t *cb, uint16_t *zb, const tri_t *t)
{
    int32_t x0 = t->x0, y0 = t->y0, x1 = t->x1, y1 = t->y1, x2 = t->x2, y2 = t->y2;
    uint16_t z0 = t->z0, z1 = t->z1, z2 = t->z2;
    int64_t area = (int64_t)(x1 - x0) * (y2 - y0) - (int64_t)(y1 - y0) * (x2 - x0);
    if (area == 0) return;
    if (area < 0) {
        int32_t tx = x1; x1 = x2; x2 = tx;
        int32_t ty = y1; y1 = y2; y2 = ty;
        uint16_t tz = z1; z1 = z2; z2 = tz;
        area = -area;
    }
    int32_t dzdx = t->dzdx, dzdy = t->dzdy;
    /* 边函数系数 */
    int64_t A0 = -(int64_t)(y2 - y1), B0 = (int64_t)(x2 - x1);
    int64_t C0 = (int64_t)(y2 - y1) * x1 - (int64_t)(x2 - x1) * y1;
    int64_t A1 = -(int64_t)(y0 - y2), B1 = (int64_t)(x0 - x2);
    int64_t C1 = (int64_t)(y0 - y2) * x2 - (int64_t)(x0 - x2) * y2;
    int64_t A2 = -(int64_t)(y1 - y0), B2 = (int64_t)(x1 - x0);
    int64_t C2 = (int64_t)(y1 - y0) * x0 - (int64_t)(x1 - x0) * y0;

    int xmin = (x0 < x1 ? (x0 < x2 ? x0 : x2) : (x1 < x2 ? x1 : x2)) >> 8;
    int xmax = (x0 > x1 ? (x0 > x2 ? x0 : x2) : (x1 > x2 ? x1 : x2)) >> 8;
    int ymin = (y0 < y1 ? (y0 < y2 ? y0 : y2) : (y1 < y2 ? y1 : y2)) >> 8;
    int ymax = (y0 > y1 ? (y0 > y2 ? y0 : y2) : (y1 > y2 ? y1 : y2)) >> 8;
    if (xmin < 0) xmin = 0;
    if (ymin < 0) ymin = 0;
    if (xmax > W3D - 1) xmax = W3D - 1;
    if (ymax > H3D - 1) ymax = H3D - 1;

    for (int py = ymin; py <= ymax; py++) {
        for (int px = xmin; px <= xmax; px++) {
            int64_t sx = ((int64_t)px << 8) + 128;
            int64_t sy = ((int64_t)py << 8) + 128;
            int64_t e0 = A0 * sx + B0 * sy + C0;
            int64_t e1 = A1 * sx + B1 * sy + C1;
            int64_t e2 = A2 * sx + B2 * sy + C2;
            if (e0 < 0 || e1 < 0 || e2 < 0) continue;
            int64_t z = z0 + sar16((int64_t)dzdx * (sx - x0) + (int64_t)dzdy * (sy - y0));
            if (z < 0) z = 0;
            if (z > 0xFFFF) z = 0xFFFF;
            int i = py * W3D + px;
            int ok;
            if (t->zmode == 2) ok = 1;
            else if (t->zmode == 1) ok = (z <= zb[i]);
            else ok = (z < zb[i]);
            if (ok) { cb[i] = t->color; zb[i] = (uint16_t)z; }
        }
    }
}

static uint16_t *g_cb, *g_zb;

static void golden(const tri_t *tris, int n)
{
    for (int i = 0; i < W3D * H3D; i++) { g_cb[i] = 0; g_zb[i] = 0xFFFF; }
    for (int k = 0; k < n; k++) raster_tri(g_cb, g_zb, &tris[k]);
}

static int cmp_buf(const uint16_t *cb, const uint16_t *zb, const char *tag)
{
    int bad = 0;
    /* GPU 刚写完这两块 ⇒ CPU 缓存副本是旧的，先丢 */
    RANGE_INVAL((void *)cb, (size_t)W3D * H3D * 2);
    RANGE_INVAL((void *)zb, (size_t)W3D * H3D * 2);
    for (int i = 0; i < W3D * H3D; i++) {
        if (cb[i] != g_cb[i] || zb[i] != g_zb[i]) {
            if (bad < 8)
                printf("  MISMATCH %s idx=%d (x=%d,y=%d) got=%04X/%04X exp=%04X/%04X\n",
                       tag, i, i % W3D, i / W3D, cb[i], zb[i], g_cb[i], g_zb[i]);
            bad++;
        }
    }
    return bad;
}

/* 记录参数：三个顶点用 8.8，颜色/zmode 由调用方给 */
static void mk_tri(tri_t *t, int ax, int ay, int az, int bx, int by, int bz,
                   int cx, int cy, int cz, uint16_t color, uint16_t zmode)
{
    memset(t, 0, sizeof(*t));
    t->x0 = ax * 256; t->y0 = ay * 256; t->z0 = (uint16_t)az;
    t->x1 = bx * 256; t->y1 = by * 256; t->z1 = (uint16_t)bz;
    t->x2 = cx * 256; t->y2 = cy * 256; t->z2 = (uint16_t)cz;
    t->color = color;
    t->zmode = zmode;
    plane(t, &t->dzdx, &t->dzdy);
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

#ifdef SELFTEST
/* 主机自检：不碰 /dev/mem，只算黄金并打校验和（与 sim/gpu/tri_ref.py 对账用） */
int main(void)
{
    tri_t tris[2];
    g_cb = malloc(W3D * H3D * 2);
    g_zb = malloc(W3D * H3D * 2);
    mk_tri(&tris[0], 0, 0, 40000, 639, 0, 40000, 0, 479, 40000, 0x07E0, 0);
    mk_tri(&tris[1], 8, 8, 1000, 400, 60, 1000, 40, 460, 1000, 0x001F, 0);
    golden(tris, 2);
    {
        uint64_t h = 1469598103934665603ull;
        int painted = 0;
        for (int i = 0; i < W3D * H3D; i++) {
            h = (h ^ g_cb[i]) * 1099511628211ull;
            h = (h ^ g_zb[i]) * 1099511628211ull;
            if (g_cb[i]) painted++;
        }
        printf("SELFTEST painted=%d hash=%016llx\n", painted, (unsigned long long)h);
    }
    return 0;
}
#else
int main(int argc, char **argv)
{
    int reps = 1;
    for (int i = 1; i < argc; i++)
        if (!strcmp(argv[i], "-r") && i + 1 < argc) reps = atoi(argv[++i]);
    if (reps < 1) reps = 1;
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    /* 行缓冲/全缓冲会让挂死时一个字都留不下（上一轮就是这样丢掉步骤信息的） */
    setvbuf(stdout, NULL, _IONBF, 0);
    if (fd < 0) { perror("open"); return 2; }
    csr = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)GPU_BASE);
    /* 3 MB 要盖到 DST3D(0x93280000) + 256x200x2 = 0x299000；原来只映射 0x280000
     * ⇒ dstbuf 正好落在映射边界外，写哨兵就 SIGSEGV（2026-11-01 上板实测）。 */
    dram = mmap(NULL, 0x300000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)COLOR3D);
    if (csr == MAP_FAILED || dram == MAP_FAILED) { perror("mmap"); return 2; }
    color3d = (uint16_t *)(dram + 0);
    z3d     = (uint16_t *)(dram + (Z3D - COLOR3D));
    dstbuf  = (uint16_t *)(dram + (DST3D - COLOR3D));
    arena   = (uint32_t *)(dram + (ARENA - COLOR3D));

    g_cb = malloc(W3D * H3D * 2);
    g_zb = malloc(W3D * H3D * 2);
    if (!g_cb || !g_zb) { printf("gputest3d: no mem\n"); return 2; }

    uint32_t id = rd(0x000);
    printf("gputest3d: ID=0x%08X\n", id);
    if (id != 0x59475055u) return 1;

    /* ---- ② CLEAR3D ---- */
    printf("step2: CLEAR3D 640x480\n");
    clear3d(0x0000, 0xFFFF);
    fence();
    int bad = 0;
    for (int i = 0; i < W3D * H3D; i++)
        if (color3d[i] != 0 || z3d[i] != 0xFFFF) bad++;
    printf("gputest3d: CLEAR3D bad=%d\n", bad);
    if (bad) g_err++;

    /* ---- ③ DRAW_TRIS：先远后近 ----
     * -r N 把这一步（CLEAR + DRAW + fence + 逐像素比对）重复 N 次：
     * 挂死是间歇性的，重复才能在一次上板里复现，且每轮都带探针快照。 */
    tri_t tris[2];
    mk_tri(&tris[0], 0, 0, 40000, 639, 0, 40000, 0, 479, 40000, 0x07E0, 0); /* 远：全屏绿 */
    mk_tri(&tris[1], 8, 8, 1000, 400, 60, 1000, 40, 460, 1000, 0x001F, 0);  /* 近：蓝 */
    for (int k = 0; k < 2; k++) rec_pack((uint8_t *)(arena + k * 12), &tris[k]);
    __sync_synchronize();
    RANGE_FLUSH(arena, 96);          /* 记录要被 GPU 读 ⇒ 必须先落 DDR */
    usleep(20000);

    for (int rep = 0; rep < reps; rep++) {
        printf("step3[%d/%d]: CLEAR3D + DRAW_TRIS x2\n", rep + 1, reps);
        fflush(stdout);
        clear3d(0x0000, 0xFFFF);
        draw3d(ARENA, 2);
        fence();
        dump_probes("after draw3d");
        golden(tris, 2);
        bad = cmp_buf(color3d, z3d, "draw3d");
        printf("gputest3d: DRAW_TRIS bad=%d\n", bad);
        if (bad) g_err++;
    }

    /* ---- ④ Z 负对照 ----
     * 原来的写法（只把近的 zmode 改成 OFF）**没有区分力**：近三角形 z=1000 本来就过 LESS，
     * OFF 与 LESS 结果逐像素相同 ⇒ diff=0 是必然的（2026-11-01 上板实测）。
     * 改成：把第二条记录的 z 拉到 60000（比远平面 40000 更远）+ zmode=OFF
     *   ⇒ 正确语义（LESS）应当**整块被拒**（只剩绿色），OFF 则照写（蓝色）⇒ 两者必然不同。 */
    {
        tri_t neg = tris[1];
        neg.z0 = neg.z1 = neg.z2 = 60000;
        neg.zmode = 2;      /* OFF：总是写 */
        plane(&neg, &neg.dzdx, &neg.dzdy);
        rec_pack((uint8_t *)(arena + 12), &neg);
        __sync_synchronize();
        RANGE_FLUSH(arena + 12, 48);
        usleep(20000);
        printf("step4: Z 负对照（z=60000 + zmode=OFF）\n");
        clear3d(0x0000, 0xFFFF);
        draw3d(ARENA, 2);
        fence();
        /* 用"正确"的黄金（zmode=LESS：更远的蓝被拒 ⇒ 全绿）去比 —— 必须不相同 */
        golden(tris, 2);
        int diff = cmp_buf(color3d, z3d, "negctl-vs-correct");
        printf("gputest3d: Z 负对照 diff=%d（必须 >0，否则判据无区分力）\n", diff);
        if (diff == 0) g_err++;
        /* 复原第二条记录 */
        rec_pack((uint8_t *)(arena + 12), &tris[1]);
        __sync_synchronize();
        RANGE_FLUSH(arena + 12, 48);
        usleep(20000);
    }

    /* ---- ⑤ COMPOSITE3D：640×480 → 256×200 缓冲 (8,4)，w 取 256（%64==0） ---- */
    for (int i = 0; i < DW3D * DH3D; i++) dstbuf[i] = SENTINEL;
    __sync_synchronize();
    RANGE_FLUSH(dstbuf, (size_t)DW3D * DH3D * 2);   /* 哨兵要落 DDR，别在贴图后才回写 */
    usleep(20000);
    printf("step5: CLEAR3D + DRAW_TRIS + COMPOSITE3D\n");
    clear3d(0x0000, 0xFFFF);
    draw3d(ARENA, 2);
    comp3d(DST3D, DW3D, DX3D, DY3D, 256, DH3D - DY3D);
    fence();
    RANGE_INVAL(dstbuf, (size_t)DW3D * DH3D * 2);
    golden(tris, 2);
    int cbad = 0;
    for (int y = 0; y < DH3D; y++)
        for (int x = 0; x < DW3D; x++) {
            uint16_t exp;
            if (x >= DX3D && x < DX3D + 256 && y >= DY3D)
                exp = g_cb[(y - DY3D) * W3D + (x - DX3D)];
            else
                exp = SENTINEL;
            if (dstbuf[y * DW3D + x] != exp) {
                if (cbad < 8)
                    printf("  MISMATCH comp (x=%d,y=%d) got=%04X exp=%04X\n",
                           x, y, dstbuf[y * DW3D + x], exp);
                cbad++;
            }
        }
    printf("gputest3d: COMPOSITE3D bad=%d\n", cbad);
    if (cbad) g_err++;

    /* ---- ⑥ 复合的两次判别实验（板上定位用，不改 RTL）----
     *  (a) 同一目标**再贴一次**：若第二次变干净 ⇒ 丢拍是随机的（每次重新写就补上）；
     *  (b) 换成 **dx=0**（32 B 对齐 ⇒ gpu_mem 不需要补 pad 拍）：若变干净 ⇒ 与 pad 路径有关。 */
    {
        int c2 = 0;
        comp3d(DST3D, DW3D, DX3D, DY3D, 256, DH3D - DY3D);
        fence();
        RANGE_INVAL(dstbuf, (size_t)DW3D * DH3D * 2);
        for (int y = 0; y < DH3D; y++)
            for (int x = 0; x < DW3D; x++) {
                uint16_t exp = (x >= DX3D && x < DX3D + 256 && y >= DY3D)
                             ? g_cb[(y - DY3D) * W3D + (x - DX3D)] : SENTINEL;
                if (dstbuf[y * DW3D + x] != exp) c2++;
            }
        printf("gputest3d: COMPOSITE3D 2nd-pass bad=%d\n", c2);
        fflush(stdout);

        for (int i = 0; i < DW3D * DH3D; i++) dstbuf[i] = SENTINEL;
        __sync_synchronize();
        RANGE_FLUSH(dstbuf, (size_t)DW3D * DH3D * 2);
        usleep(20000);
        comp3d(DST3D, DW3D, 0, DY3D, 256, DH3D - DY3D);   /* dx=0 ⇒ 32B 对齐 */
        fence();
        RANGE_INVAL(dstbuf, (size_t)DW3D * DH3D * 2);
        int c0 = 0;
        for (int y = 0; y < DH3D; y++)
            for (int x = 0; x < DW3D; x++) {
                uint16_t exp = (x < 256 && y >= DY3D)
                             ? g_cb[(y - DY3D) * W3D + x] : SENTINEL;
                if (dstbuf[y * DW3D + x] != exp) c0++;
            }
        printf("gputest3d: COMPOSITE3D dx=0 bad=%d\n", c0);
    }

    printf("gputest3d: err=%d DBG=0x%08X => %s\n", g_err,
           (unsigned)rd(GPU_DBG), g_err ? "FAIL" : "PASS");
    return g_err ? 1 : 0;
}
#endif
