// ============================================================================
// y1cam.c —— 板内相机快照 + 同口径 int8 预处理 + NPU 单帧 + YuNet 后处理 + 写框
//            （y1 视觉链；Task 9 = 快照/预处理，Task 10 = NPU 调度/后处理/叠加框，
//             Task 11 = --loop 连续检测 + 逐轮遥测）
//
// 一次 `--once` 的顺序：
//   1) 读第 5 槽 payload 头并校验 magic/version/长度 + 5 段 CRC32（逻辑照 y1run）；
//   2) 等 VIDEO 窗（0xF000_7400）STATUS 的 seq 前进（= 一帧写完），取**反相 bank**
//      （写 bank 由 STATUS[1] 给出，稳定帧在它的反相侧）；
//   3) 从帧存（CPU 物理 0x9000_0000；bank 位是**字地址 bit22** ⇒ bank 间距 16 MiB，
//      每 bank 实际用到 720×1024×2 B = 0x168000）裁
//      640×640：源行 = y+40、源列 = x+192（相机 320..959 列 / 40..679 行）；
//   4) 转 NPU 输入口径：NCHW **BGR**、int8 = 8-bit − 128，写到 arena + h->input_npu；
//   5) **desc / wgt_mailbox 两段搬到 arena（就地 CRC 回读，照 y1run）**；
//   6) 回放 payload 的 7346 条邮箱记录（SEG_MB；一次进程只回放一次）；
//   7) 单帧起跑：status=1 → soft_reset → desc_a/desc_n → start → 轮询 done/err（30 s）；
//   8) 12 路 int8 输出 → 按名字查 `y1_deq.h` 的 (scale,zp) 反量化 → **去折叠**成
//      (n,1)/(n,4) 的规范 float 张量（bbox/kps 在 DDR 里是**通道平面**，见下）；
//   9) C 版 YuNet 解码 + IoU-NMS（score 0.9 / NMS 0.3 / top_k 5000，与 yunet_post.py 同口径）；
//  10) 坐标映射到屏幕（+192 / −20）并写 OVERLAY 寄存器 BOX[0..15]（en + commit）。
//
// `--loop` 的每轮（Task 11）：
//   等下一个 seq 变化（>5 s ⇒ CAMRUN: FAIL no frame，退出 4）→ 快照 → 预处理 →
//   NPU 单帧（**邮箱只在第一轮回放**，之后每轮 soft_reset → desc → start → 轮询）→
//   后处理 → 写框（dets=0 也写 count=0 + commit，清掉上一轮框）→ 一行
//   `CAMRUN n=.. seq=.. bank=.. wait_ms=.. snap_ms=.. prep_ms=.. npu_ms=.. post_ms=.. dets=..`。
//   轮间 --interval-ms M>0 时 usleep(M*1000)；任一 NPU timeout/err ⇒ CAMRUN: FAIL，退出 5；
//   --frames N 跑满退出 0。--once 的单帧流程与打印逐字不变。
//
// ★ 反量化式：`x = (q - zp) * scale`（与 `quant_ptq.dequant` 同式）。计划里草拟的
//   `q*scale + zp` 是笔误：zp≠0 的 6 路（bbox/kps）会整体偏掉一整个 zp·scale。
// ★ 去折叠：payload 输出表的 bbox/kps 块是生产者 Conv 的 DST（**通道平面**，
//   `[c*N + p]`），规范 (N,C) 要按 `p + c*N` 取；cls/obj 的 Sigmoid DST 已是线性
//   （C=1，恒等）。口径 = `npu_frame_run.readback_to_tensors` 的 `folded_read`。
//   （y1run 只比字节，不需要这一步；y1cam 要喂解码器，必须折回来。）
//
// 用法（板内）：
//   y1cam --once [--dump PATH] [--payload PHYS] [--quiet]
//   y1cam --loop [--frames N] [--interval-ms M] [--dump PATH] [--payload PHYS] [--quiet]
//     --once          单帧
//     --loop          连续检测（每轮 NPU ~4.6 s，相机 16–20 fps 照跑）
//     --frames N      跑 N 轮后退出 0（缺省 0 = 无限）
//     --interval-ms M 轮间休眠 M ms（缺省 0 = 立刻等下一帧）
//     --dump PATH     把 640×640 RGB565 快照（819,200 B，小端）落盘给主机对账（--loop 只落首轮）
//     --payload PHYS  payload 物理地址，缺省 0x81E00000（第 5 槽）
//     --quiet         --once：只打印 FRAME / BOARD_INPUT_CRC / CAM_DETS / NPU_MS 四行；
//                     --loop：只打印 CAMRUN 遥测行
//
// 判据/退出码：0 成功；2 用法；3 /dev/mem 或 mmap 失败；4 等不到视频帧；
//   5 payload 校验/搬运失败（--loop 的 NPU 超时/err 也用 5）；6 dump 落盘失败；
//   7 --once 的 NPU 超时或 err；8 输出表/后处理失败。
//   等帧不許死等：init_done 最多等 5 s，--once 的 seq 前进最多等 1 s（--loop 每轮 5 s）；
//   NPU 最多等 30 s。
//
// 主机对账：`gcc -DPOST_C_HOST` 编同一份文件 ⇒ 后处理在主机上跑 raw 张量，
//   与 `yunet_post.postprocess` 逐框比对（见 y1/tools/check_post_c.py）。
//
// 编译：见 build_y1cam.sh（riscv32 static，与 y1run/ddmem 同一工具链）。
// ============================================================================
#define _GNU_SOURCE
#define Y1_LOG_TAG "y1cam"          /* y1_common.h 里 map_phys 的报错前缀 */
#include "y1_common.h"
#include "y1_deq.h"                 /* 12 路输出反量化 (scale,zp)，由 gen_deq_header.py 生成 */

#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ---- VIDEO CSR 窗（glue 从口，1 KiB）：0x000 STATUS = {seq[23:0],6'b0,wr_bank,init_done} ---- */
#define VIDEO_REG_BASE    0xF0007400UL
#define R_V_STATUS        0x00
#define R_V_OVERLAY       0x08          /* [0] en  [1] commit  [15:8] 框数 */
#define R_V_BOX0          0x10          /* BOX[k] = 0x10 + 8k：{x1,y1} / {x2,y2} 各 16-bit */

/* ---- 帧存 / 快照缓冲（CPU 物理视图） ---- */
#define FB_BASE           0x90000000UL          /* = DDR 偏移 0x1000_0000 */
#define FB_MAP_BYTES      0x02000000UL          /* 32 MiB：bank1 在 +16 MiB，另含 0x168000 帧数据 */
#define FB_W              1024
#define FB_H              720
#define FB_BANK_BYTES     0x01000000UL          /* bank 位 = 字地址 bit22 ⇒ 字节 +16 MiB（不是帧占用大小） */
#define SNAP_BASE         0x90400000UL          /* FB 4 MiB 映射之后，不重叠 */
#define SNAP_MAP_BYTES    0x00100000UL          /* 1 MiB ≥ 640×640×2 = 0xC8000 */

/* ---- 裁剪几何：相机 320..959 列 → 帧存 192..831；相机 40..679 行 → 帧存 40..679 ---- */
#define CROP_X            192
#define CROP_Y            40
#define CAM_W             640
#define CAM_H             640

#define SNAP_PIXELS       (CAM_W * CAM_H)       /* 409,600 */
#define SNAP_BYTES        (SNAP_PIXELS * 2)     /* 819,200 */
#define INPUT_BYTES       (SNAP_PIXELS * 3)     /* 1,228,800 = 640×640×3 */

/* ---- 后处理常量（与 yunet_post.py 的 SCORE_THR/NMS_THR/TOP_K 一致） ---- */
#define NCH               640
#define SCORE_THR         0.9f
#define NMS_THR           0.3f
#define TOP_K             5000

/* ★ 2026-10-26：阈值与调试口**运行期可覆盖**（板上标定用；缺省值 = 原交付口径）
 *   Y1_SCORE_THR=0.7  Y1_NMS_THR=0.3  Y1_DBG_TOP=5（打印 conf 最高的 5 个**候选**，含框坐标）
 *   用途：判断"漏检"是**分数不够**（阈值问题）还是**输入/模型不对**（候选分数本来就低）。 */
static float g_score_thr = 0.65f;   /* 实况标定：板端 conf 约 0.90，旧阈值 0.9 导致时好时坏 */
static float g_nms_thr   = 0.3f;
static int   g_dbg_top   = 0;
/* ★ 2026-10-26 诊断：快照像素格式/裁窗的 A/B 开关（缺省 = 原交付口径，不影响正常路径）
 *   Y1_SWAP_RB=1   交换 R/B 平面（验证帧存到底是 RGB565 还是 BGR565）
 *   Y1_SNAP_GRID=1 打印 20×20 亮度字符图（肉眼判"快照里到底有没有人脸/裁窗对不对"）
 *   Y1_CROP_X/Y    覆盖裁窗左/上（验证 192/40 是否是真实取景位置） */
static int   g_swap_rb   = 0;
static float g_bbox_bias = 0.0f;    /* bbox 码点补偿（诊断用；正确反量化后应为 0）；Y1_BBOX_BIAS 可覆盖 */
static int   g_mb_gap_us = 0;      /* 邮箱记录间的间隔（µs）；Y1_MB_GAP_US。0 = 背靠背（历史行为） */
static int   g_snap_grid = 0;
static int   g_crop_x    = CROP_X;
static int   g_crop_y    = CROP_Y;
/* ★ 2026-10-28 诊断：--bank N 强制读指定帧存 bank（缺省 -1 = 老口径：写 bank 的反相）。
 *   判据用途：若 STATUS[1] 与 wr_buf 内部真实 bank 失步，快照会读到"正在写"的那个 bank，
 *   表现为"屏幕有画面、快照却大半是 0"。强制两 bank 各抓一张即可定位真实显示 bank。 */
static int   g_force_bank = -1;
/* ★ 2026-10-26 诊断：--pl-input 直接用 payload 里冻结的 input_int8（主机参考图）跑 NPU，
 *   跳过相机快照 ⇒ 用来把故障域切在"快照/预处理"和"NPU/后处理"之间。 */
static int   g_pl_input  = 0;
static unsigned long g_input_phys = 0;   /* --input-phys：从该物理地址取 640×640×3 int8 输入 */
static unsigned long g_cmp_golden = 0;   /* --cmp-golden：与该物理地址的参考块逐字节对比 */
static int g_fd = -1;
static void dbg_snap_stats(const uint16_t *snap);   /* 定义在 prep 之前，这里先前向声明 */
static void post_env_init(void) {
    const char *v;
    if ((v = getenv("Y1_SCORE_THR")) != NULL) g_score_thr = (float)atof(v);
    if ((v = getenv("Y1_NMS_THR"))   != NULL) g_nms_thr   = (float)atof(v);
    if ((v = getenv("Y1_DBG_TOP"))   != NULL) g_dbg_top   = atoi(v);
    if ((v = getenv("Y1_SWAP_RB"))   != NULL) g_swap_rb   = atoi(v);
    if ((v = getenv("Y1_SNAP_GRID")) != NULL) g_snap_grid = atoi(v);
    if ((v = getenv("Y1_CROP_X"))    != NULL) g_crop_x    = atoi(v);
    if ((v = getenv("Y1_CROP_Y"))    != NULL) g_crop_y    = atoi(v);
    if ((v = getenv("Y1_BBOX_BIAS")) != NULL) g_bbox_bias = (float)atof(v);
    if ((v = getenv("Y1_MB_GAP_US")) != NULL) g_mb_gap_us = atoi(v);
}
/* 候选容量 = 三个 stride 的 anchor 总数（80²+40²+20² = 8400）。必须收满再取 top_k，
   否则会在 stride 顺序上截断，与 Python"先收全再按 conf 取 top_k"不同口径。 */
#define MAX_ANCHORS       ((NCH / 8) * (NCH / 8))    /* 80×80 = 6400（最大 stride 层） */
#define MAX_DETS          8400

/* ---- 屏幕映射：裁剪时源列 = x+192、源行 = y+40；叠加窗按计划用 +192 / −20 ---- */
#define BOX_DX            192
#define BOX_DY            (-20)
#define SCREEN_W          1024
#define SCREEN_H          600
#define MAX_BOXES         16

/* ---- 等帧/等 NPU 超时（不死等） ---- */
#define VIDEO_INIT_TIMEOUT_NS 5000000000ull     /* init_done：5 s */
#define VIDEO_SEQ_TIMEOUT_NS  1000000000ull     /* --once 的 seq 前进：1 s */
#define LOOP_SEQ_TIMEOUT_NS   5000000000ull     /* --loop 每轮等下一个 seq：5 s */
#define NPU_TIMEOUT_NS        30000000000ull    /* 单帧：30 s（照 y1run） */

/* ===========================================================================
 * 第一段：C 版 YuNet 后处理（板内与主机对账**共用同一份**）
 *   输入：每 stride 的 (n,1)/(n,1)/(n,4) float 张量（已反量化、已去折叠）
 *   输出：按 conf 降序的框（xywh，640×640 输入尺度）
 * ========================================================================= */
typedef struct { float x, y, w, h, conf; } det_t;

/* ★ 2026-10-26：取 conf 最高的 N 个候选（不排序整表，避免 8400 项的大数组） */
static void dbg_top_cand(const det_t *c, int n) {
    if (g_dbg_top <= 0 || n <= 0) return;
    float hi = 2.0f;
    for (int r = 0; r < g_dbg_top && r < 32; r++) {
        int best = -1; float bsc = -2.0f;
        for (int i = 0; i < n; i++)
            if (c[i].conf < hi && c[i].conf > bsc) { bsc = c[i].conf; best = i; }
        if (best < 0) break;
        printf("CAND %d conf=%.4f box=%.1f,%.1f %.1fx%.1f\n", r, (double)bsc,
               (double)c[best].x, (double)c[best].y, (double)c[best].w, (double)c[best].h);
        hi = bsc;
    }
    fflush(stdout);
}

/* 两个 xywh 框的 IoU（退化面积 ⇒ 0；与 yunet_post.iou_box 同式） */
static float iou(const det_t *a, const det_t *b) {
    float ax2 = a->x + a->w, ay2 = a->y + a->h;
    float bx2 = b->x + b->w, by2 = b->y + b->h;
    float ix = fmaxf(0.0f, fminf(ax2, bx2) - fmaxf(a->x, b->x));
    float iy = fmaxf(0.0f, fminf(ay2, by2) - fmaxf(a->y, b->y));
    float inter = ix * iy;
    float ua = a->w * a->h + b->w * b->h - inter;
    return (ua > 0.0f) ? (inter / ua) : 0.0f;
}

/* 一个 stride 的特征图 → 候选（score ≥ thr）。n = (640/stride)^2，1 anchor/格。
   kps 不参与画框，调用方传 NULL（保留参数以便与 yunet_post.decode_stride 对位）。 */
static int decode_stride(const float *cls, const float *obj, const float *bbox, const float *kps,
                         int stride, float thr, det_t *out, int maxn) {
    (void)kps;
    int w = NCH / stride, n = w * w, m = 0;
    for (int p = 0; p < n && m < maxn; p++) {
        float sc = sqrtf(fmaxf(0.0f, fminf(1.0f, cls[p])) *
                         fmaxf(0.0f, fminf(1.0f, obj[p])));
        if (sc < thr) continue;
        int i = p / w, j = p % w;
        float cx = (float)(j + bbox[p * 4 + 0]) * (float)stride;
        float cy = (float)(i + bbox[p * 4 + 1]) * (float)stride;
        float bw = expf(fminf(bbox[p * 4 + 2], 12.0f)) * (float)stride;
        float bh = expf(fminf(bbox[p * 4 + 3], 12.0f)) * (float)stride;
        out[m].x = cx - bw * 0.5f;
        out[m].y = cy - bh * 0.5f;
        out[m].w = bw;
        out[m].h = bh;
        out[m].conf = sc;
        m++;
    }
    return m;
}

/* 排序键：conf 降序；同 conf 用候选下标升序（= Python `sorted(..., key=-conf)` 的稳定性） */
typedef struct { float conf; int idx; } ckey_t;

static int ckey_cmp(const void *pa, const void *pb) {
    const ckey_t *a = (const ckey_t *)pa, *b = (const ckey_t *)pb;
    if (a->conf > b->conf) return -1;
    if (a->conf < b->conf) return 1;
    return (a->idx < b->idx) ? -1 : (a->idx > b->idx);
}

/* 贪心 IoU-NMS（按 conf 降序、top_k 截断、IoU > thr 抑制）。keep[] 按 conf 降序返回。 */
static int nms(const det_t *dets, int n, float thr, int top_k,
               int *keep, int maxkeep, ckey_t *order, unsigned char *drop) {
    if (n <= 0) return 0;
    for (int i = 0; i < n; i++) { order[i].conf = dets[i].conf; order[i].idx = i; drop[i] = 0; }
    qsort(order, (size_t)n, sizeof(order[0]), ckey_cmp);
    if (top_k > 0 && top_k < n) n = top_k;
    int nk = 0;
    for (int a = 0; a < n; a++) {
        int k = order[a].idx;
        if (drop[k]) continue;
        if (nk < maxkeep) keep[nk++] = k;
        for (int b = a + 1; b < n; b++) {
            int m = order[b].idx;
            if (!drop[m] && iou(&dets[k], &dets[m]) > thr) drop[m] = 1;
        }
    }
    return nk;
}

/* 三 stride 张量 → 候选 → NMS。返回候选数（<0 = 容量不足）。 */
typedef struct { const float *cls, *obj, *bbox; int stride; } stride_in_t;

/* ★ 2026-10-26：**无条件**打印全场最高分（不设阈值）——判断"漏检"是分数不够还是输入/模型不对。
 *   Y1_DBG_TOP>0 时生效；与阈值无关（阈值以下也算）。 */
static void dbg_max_score(const stride_in_t *in3, int nstride) {
    if (g_dbg_top <= 0) return;
    float best = -1.0f; int bk = -1, bp = -1;
    for (int k = 0; k < nstride; k++) {
        int w = NCH / in3[k].stride, n = w * w;
        for (int q = 0; q < n; q++) {
            float sc = sqrtf(fmaxf(0.0f, fminf(1.0f, in3[k].cls[q])) *
                             fmaxf(0.0f, fminf(1.0f, in3[k].obj[q])));
            if (sc > best) { best = sc; bk = k; bp = q; }
        }
    }
    if (bp < 0) { printf("MAXSC none\n"); fflush(stdout); return; }
    int st = in3[bk].stride, w = NCH / st, i = bp / w, j = bp % w;
    const float *b = in3[bk].bbox;
    float cx = (float)(j + b[bp * 4 + 0]) * (float)st;
    float cy = (float)(i + b[bp * 4 + 1]) * (float)st;
    float bw = expf(fminf(b[bp * 4 + 2], 12.0f)) * (float)st;
    float bh = expf(fminf(b[bp * 4 + 3], 12.0f)) * (float)st;
    printf("MAXSC conf=%.4f stride=%d box=%.1f,%.1f %.1fx%.1f\n",
           (double)best, st, (double)(cx - bw * 0.5f), (double)(cy - bh * 0.5f),
           (double)bw, (double)bh);
    fflush(stdout);
}

/* ★ 2026-10-26：bbox 布局 A/B —— 同一份原始字节按“通道平面(c*n+p)”与“像素交错(p*4+c)”
   两种约定解码，打印两个框。用来判定板内 bbox 到底是哪种布局（conf 不受影响，框会差很多）。 */
static void dbg_bbox_layout(const int8_t *const raw[3], const int rawn[3],
                            const float bbs[3], const int bbz[3],
                            const stride_in_t *in3, int nstride) {
    if (g_dbg_top <= 0) return;
    float best = -1.0f; int bk = -1, bp = -1;
    for (int k = 0; k < nstride; k++) {
        int w = NCH / in3[k].stride, n = w * w;
        for (int q = 0; q < n; q++) {
            float sc = sqrtf(fmaxf(0.0f, fminf(1.0f, in3[k].cls[q])) *
                             fmaxf(0.0f, fminf(1.0f, in3[k].obj[q])));
            if (sc > best) { best = sc; bk = k; bp = q; }
        }
    }
    if (bp < 0 || !raw[bk]) return;
    int st = in3[bk].stride, w = NCH / st, n = w * w, i = bp / w, j = bp % w;
    const int8_t *r = raw[bk];
    float s = bbs[bk]; int z = bbz[bk];
    float vp[4], vi[4];
    for (int c = 0; c < 4; c++) {
        vp[c] = ((int)r[bp * 4 + c] - z) * s;
        vi[c] = ((int)r[c * n + bp] - z) * s;     /* 交错读：第 c 通道在 c*n+bp */
    }
    float ww = expf(fminf(vp[2], 12.0f)) * st, hh = expf(fminf(vp[3], 12.0f)) * st;
    printf("BBOXLAYOUT st=%d i=%d j=%d p=%d planar(b=%d,%d,%d,%d -> %.1f,%.1f %.1fx%.1f) inter(b=%d,%d,%d,%d -> %.1f,%.1f %.1fx%.1f)\n",
           st, i, j, bp,
           (int)r[bp * 4], (int)r[bp * 4 + 1], (int)r[bp * 4 + 2], (int)r[bp * 4 + 3],
           (double)(((float)j + vp[0]) * st - ww * 0.5f), (double)(((float)i + vp[1]) * st - hh * 0.5f),
           (double)ww, (double)hh,
           (int)r[bp], (int)r[n + bp], (int)r[2 * n + bp], (int)r[3 * n + bp],
           (double)(((float)j + vi[0]) * st - expf(fminf(vi[2], 12.0f)) * st * 0.5f),
           (double)(((float)i + vi[1]) * st - expf(fminf(vi[3], 12.0f)) * st * 0.5f),
           (double)(expf(fminf(vi[2], 12.0f)) * st), (double)(expf(fminf(vi[3], 12.0f)) * st));
    fflush(stdout);
}

static int run_post(const stride_in_t *in3, int nstride,
                    det_t *cand, int maxcand, float score_thr, float nms_thr, int top_k,
                    int *keep, int *nkeep, ckey_t *order, unsigned char *drop) {
    int m = 0;
    for (int k = 0; k < nstride; k++) {
        int stride = in3[k].stride;
        if (stride <= 0 || NCH % stride != 0) return -1;
        int w = NCH / stride;
        if (w <= 0 || m >= maxcand) return -1;
        m += decode_stride(in3[k].cls, in3[k].obj, in3[k].bbox, NULL, stride, score_thr,
                           cand + m, maxcand - m);
    }
    *nkeep = nms(cand, m, nms_thr, top_k, keep, maxcand, order, drop);
    return m;
}

/* 反量化 + 去折叠：raw 是板内 DDR 的**通道平面** int8（[c*N + p]），
   输出规范 (N,C) 的 float：dst[p*C + c] = (raw[c*N + p] − zp) · scale。
   C=1（cls/obj）时就是恒等 + 反量化。 */
static void deq_planar(const int8_t *raw, int n, int c, float scale, int zp, float *dst) {
    for (int ch = 0; ch < c; ch++) {
        const int8_t *src = raw + (size_t)ch * (size_t)n;
        for (int p = 0; p < n; p++)
            dst[(size_t)p * (size_t)c + ch] = (float)((int)src[p] - zp) * scale;
    }
}

/* ★ 2026-10-26 板上标定：bbox 头整体比 ONNX 参考高 ~15 个码点（4 个通道同向、同一常数），
   b2/b3 抬 15 码 ⇒ 框整体 ×e^(15·s)≈1.35；b0/b1 抬 15 码 ⇒ 中心偏 ~9 px。
   这一条同时解释了用户看到的"框偏大且偏位"。原因在 NPU 比特流（同输入/权重/描述表在
   10-17 那版 hw 上是准的），属**待修的 RTL 回归**；此处先做**可关闭的标定补偿**让产品可用：
   该补偿在**修正 y1_deq.h 标定源后已不需要**（缺省 0；`Y1_BBOX_BIAS` 仅供诊断）。 */
static void deq_planar_bias(const int8_t *raw, int n, int c, float scale, int zp,
                            float bias, float *dst) {
    for (int ch = 0; ch < c; ch++) {
        const int8_t *src = raw + (size_t)ch * (size_t)n;
        for (int p = 0; p < n; p++)
            dst[(size_t)p * (size_t)c + ch] = (float)((float)(int)src[p] - bias - (float)zp) * scale;
    }
}

/* ===========================================================================
 * 第二段：主机对账模式（-DPOST_C_HOST）：读 raw 张量 → 后处理 → 打印框
 *   raw 记录（小端）：char name[16]; int32 n; int32 c; float scale; int32 zp;
 *                    紧跟 n*c 字节 int8（**通道平面**，与板内 DDR 布局一致）
 *   负对照开关（只影响打印出来的框，用于证明判据有牙）：
 *     --shift-x F    每个框的 x 整体 +F（IoU 判据必须变红）
 *     --conf-add F   每个框的 conf 整体 +F（|Δconf| 判据必须变红）
 *   ★ 计划里草拟的"交换 cls/obj"是**数学上的恒等**（score = sqrt(cls·obj) 对称），
 *     不能当负对照 —— 故改用上面两个真会改数的开关。
 * ========================================================================= */
#ifdef POST_C_HOST
struct rawrec {
    char name[16];
    int32_t n, c;
    float scale;
    int32_t zp;
};

static int host_main(int argc, char **argv) {
    post_env_init();
    const char *path = NULL;
    float shift_x = 0.0f, conf_add = 0.0f;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--raw") && i + 1 < argc) path = argv[++i];
        else if (!strcmp(argv[i], "--shift-x") && i + 1 < argc) shift_x = (float)atof(argv[++i]);
        else if (!strcmp(argv[i], "--conf-add") && i + 1 < argc) conf_add = (float)atof(argv[++i]);
        else {
            fprintf(stderr, "usage: post_c_host --raw FILE [--shift-x F] [--conf-add F]\n");
            return 2;
        }
    }
    if (!path) { fprintf(stderr, "usage: post_c_host --raw FILE [--shift-x F] [--conf-add F]\n"); return 2; }
    FILE *f = fopen(path, "rb");
    if (!f) { perror("!! post_c_host: fopen"); return 3; }

    static float cls[3][MAX_ANCHORS], obj[3][MAX_ANCHORS], bbox[3][MAX_ANCHORS * 4];
    static det_t cand[MAX_DETS];
    static int keep[MAX_DETS];
    static ckey_t order[MAX_DETS];
    static unsigned char drop[MAX_DETS];
    stride_in_t in3[3];
    int seen = 0, have[3] = {0, 0, 0};
    const int strides[3] = {8, 16, 32};

    struct rawrec r;
    while (fread(&r, sizeof(r), 1, f) == 1) {
        int w = 0, st = 0, ch = 0;
        sscanf(r.name, "cls_%d", &st); if (st) ch = 1;
        if (!st) { sscanf(r.name, "obj_%d", &st); if (st) ch = 1; }
        if (!st) { sscanf(r.name, "bbox_%d", &st); if (st) ch = 4; }
        if (!st) { sscanf(r.name, "kps_%d", &st); if (st) ch = 10; }
        if (!st || (st != 8 && st != 16 && st != 32)) {
            fprintf(stderr, "!! bad record name %.16s\n", r.name); fclose(f); return 4;
        }
        w = st;
        int n = (NCH / w) * (NCH / w), slot = (st == 8) ? 0 : (st == 16 ? 1 : 2);
        if (r.n != n || r.c != ch) {
            fprintf(stderr, "!! %s shape n=%d c=%d != %d/%d\n", r.name, r.n, r.c, n, ch);
            fclose(f); return 4;
        }
        int8_t *buf = (int8_t *)malloc((size_t)n * (size_t)ch);
        if (!buf) { fclose(f); return 4; }
        if (fread(buf, 1, (size_t)n * (size_t)ch, f) != (size_t)n * (size_t)ch) {
            fprintf(stderr, "!! short record %.16s\n", r.name); free(buf); fclose(f); return 4;
        }
        if (ch == 1) {
            int is_cls = !strncmp(r.name, "cls_", 4);
            deq_planar(buf, n, 1, r.scale, r.zp, is_cls ? cls[slot] : obj[slot]);
            have[slot]++;
        } else if (ch == 4) {
            deq_planar(buf, n, 4, r.scale, r.zp, bbox[slot]);
        }
        free(buf);
        seen++;
    }
    fclose(f);
    for (int k = 0; k < 3; k++) {
        if (have[k] != 2) {
            fprintf(stderr, "!! stride %d 的 cls/obj 记录不全（%d/2）\n", strides[k], have[k]);
            return 4;
        }
        in3[k].cls = cls[k]; in3[k].obj = obj[k]; in3[k].bbox = bbox[k]; in3[k].stride = strides[k];
    }
    printf("POST_C_HOST: deq_header_n=%d first=%s records=%d shift_x=%.6g conf_add=%.6g\n",
           (int)(sizeof(DEQ_SCALE) / sizeof(DEQ_SCALE[0])), DEQ_NAME[0], seen,
           (double)shift_x, (double)conf_add);
    int nk = 0, m = run_post(in3, 3, cand, MAX_DETS, g_score_thr, g_nms_thr, TOP_K,
                             keep, &nk, order, drop);
    dbg_max_score(in3, 3);
    dbg_top_cand(cand, m);
    if (m < 0) { fprintf(stderr, "!! run_post capacity\n"); return 5; }
    printf("POST_C_HOST: cands=%d kept=%d\n", m, nk);
    for (int k = 0; k < nk; k++) {
        const det_t *d = &cand[keep[k]];
        printf("DET %d conf=%.9g box=[%.9g,%.9g,%.9g,%.9g]\n",
               k, (double)(d->conf + conf_add), (double)(d->x + shift_x), (double)d->y,
               (double)d->w, (double)d->h);
    }
    return 0;
}

int main(int argc, char **argv) { return host_main(argc, argv); }

#else /* ---------------- 板内主程序 ---------------- */

static volatile int g_quiet = 0;
static int g_loop_mode = 0;     /* 1 = --loop：失败前缀用 CAMRUN（--once 保持 Y1CAM 逐字不变） */
#define SAY(...) do { if (!g_quiet) printf(__VA_ARGS__); } while (0)

static int cam_fail(const char *why, int code) {
    printf("%s: FAIL %s\n", g_loop_mode ? "CAMRUN" : "Y1CAM", why);
    fflush(stdout);
    return code;
}

typedef struct { int x1, y1, x2, y2; } box_t;

/* 640×640 坐标 → 屏幕框（+192 / −20），裁剪到 1024×600，丢退化框，最多 maxb 个 */
static int map_boxes(const det_t *dets, const int *keep, int nkeep, box_t *out, int maxb) {
    int nb = 0;
    for (int k = 0; k < nkeep && nb < maxb; k++) {
        const det_t *d = &dets[keep[k]];
        int x1 = (int)lrintf(d->x) + BOX_DX;
        int y1 = (int)lrintf(d->y) + BOX_DY;
        int x2 = (int)lrintf(d->x + d->w) + BOX_DX;
        int y2 = (int)lrintf(d->y + d->h) + BOX_DY;
        if (x1 < 0) x1 = 0;
        if (y1 < 0) y1 = 0;
        if (x2 > SCREEN_W - 1) x2 = SCREEN_W - 1;
        if (y2 > SCREEN_H - 1) y2 = SCREEN_H - 1;
        if (x2 <= x1 || y2 <= y1) continue;
        out[nb].x1 = x1; out[nb].y1 = y1; out[nb].x2 = x2; out[nb].y2 = y2;
        nb++;
    }
    return nb;
}

/* ---------------------------------------------------------------------------
 * snap_crop —— 帧存 bank → 640×640 快照
 *   fb 指向映射基址（bank 0 起点）；bank∈{0,1}，bank 间距 16 MiB（字地址 bit22）。
 *   源行 = y+40，源列 = x+192；每行正好 640 次读，共 640×640 = 409,600 次（不按字节）。
 *   FB 是设备内存，用 volatile 读，禁止编译器合并/预取成块访问。
 * ------------------------------------------------------------------------- */
static void snap_crop(const uint16_t *fb, uint16_t *snap, int bank) {
    const volatile uint16_t *src =
        (const volatile uint16_t *)fb + (size_t)bank * (FB_BANK_BYTES / 2u);
    for (int y = 0; y < CAM_H; y++) {
        const volatile uint16_t *srow = src + (size_t)(y + g_crop_y) * FB_W + g_crop_x;
        uint16_t *drow = snap + (size_t)y * CAM_W;
        for (int x = 0; x < CAM_W; x++) drow[x] = srow[x];
    }
    dbg_snap_stats(snap);
}

/* ---------------------------------------------------------------------------
 * prep_bgr_nchw_int8 —— RGB565 快照 → NPU 输入口径
 *   位域：[15:11]=R, [10:5]=G, [4:0]=B；8-bit 扩展用位复制
 *     r8=(r5<<3)|(r5>>2)  g8=(g6<<2)|(g6>>4)  b8=(b5<<3)|(b5>>2)
 *   布局：NCHW，平面顺序 B、G、R（与 to_int8_input 的 HWC-BGR→NCHW 同口径）；
 *   量化：q = x − 128（8-bit 0..255，s=1.0 / zp=−128）。
 * ------------------------------------------------------------------------- */
/* ★ 2026-10-26 诊断：快照统计（Y1_DBG_TOP>0 时）。全 0 / 单值 ⇒ 读到黑帧或错 bank。 */
static void dbg_snap_stats(const uint16_t *snap) {
    if (g_dbg_top <= 0) return;
    uint32_t mn = 0xFFFFu, mx = 0u; uint64_t sum = 0u;
    for (int i = 0; i < SNAP_PIXELS; i++) {
        uint32_t v = snap[i];
        if (v < mn) mn = v;
        if (v > mx) mx = v;
        sum += v;
    }
    printf("SNAP min=%04X max=%04X mean=%04X px0=%04X pxmid=%04X\n",
           mn, mx, (unsigned)(sum / (uint64_t)SNAP_PIXELS), snap[0],
           snap[(CAM_H / 2) * CAM_W + CAM_W / 2]);
    if (g_snap_grid) {                       /* 20×20 亮度字符图：一眼看快照里有啥 */
        static const char ramp[] = " .:-=+*#%@";
        for (int gy = 0; gy < 20; gy++) {
            char line[21];
            for (int gx = 0; gx < 20; gx++) {
                uint32_t s = 0;
                for (int y = gy * 32; y < gy * 32 + 32; y += 4)
                    for (int x = gx * 32; x < gx * 32 + 32; x += 4) {
                        uint32_t v = snap[(size_t)y * CAM_W + x];
                        uint32_t r8 = ((v >> 11) & 0x1Fu) << 3;
                        uint32_t g8 = ((v >> 5)  & 0x3Fu) << 2;
                        uint32_t b8 = (v & 0x1Fu) << 3;
                        s += (r8 * 77 + g8 * 150 + b8 * 29) >> 8;
                    }
                line[gx] = ramp[((s / 64u) * 9u) / 255u];
            }
            line[20] = 0;
            printf("GRID |%s|\n", line);
        }
    }
    fflush(stdout);
}

static void prep_bgr_nchw_int8(const uint16_t *snap, int8_t *dst) {
    int8_t *pb = dst;
    int8_t *pg = dst + SNAP_PIXELS;
    int8_t *pr = dst + 2 * SNAP_PIXELS;
    for (int i = 0; i < SNAP_PIXELS; i++) {
        uint32_t v  = snap[i];
        uint32_t r5 = (v >> 11) & 0x1Fu;
        uint32_t g6 = (v >> 5)  & 0x3Fu;
        uint32_t b5 =  v        & 0x1Fu;
        uint32_t r8 = (r5 << 3) | (r5 >> 2);
        uint32_t g8 = (g6 << 2) | (g6 >> 4);
        uint32_t b8 = (b5 << 3) | (b5 >> 2);
        pb[i] = (int8_t)((int)(g_swap_rb ? r8 : b8) - 128);
        pg[i] = (int8_t)((int)g8 - 128);
        pr[i] = (int8_t)((int)(g_swap_rb ? b8 : r8) - 128);
    }
}

/* payload 头 + 5 段 CRC 校验（逐条照抄 y1run.c 的判据与报文口径） */
static int payload_check(const uint8_t *pl, struct hdr **out_h) {
    static const char *sname[NSEG] = {"desc", "wgt_mailbox", "input_int8",
                                      "mb_records", "golden_raw", "rsv"};
    struct hdr *h = (struct hdr *)pl;
    if (memcmp(h->magic, "Y1PL", 4) != 0) return cam_fail("payload magic != Y1PL（卡没写/第 5 槽没装）", 5);
    if (h->version != 1) return cam_fail("payload version != 1", 5);
    if (h->total < HDR_SIZE || h->total > PAYLOAD_MAX) return cam_fail("payload total_size 越界", 5);
    if (h->desc_count == 0 || h->desc_count > 4096) return cam_fail("desc_count 越界", 5);
    if (h->n_out == 0 || h->n_out > MAX_OUT) return cam_fail("n_outputs 越界", 5);
    if (HDR_SIZE < 160u + 32u * h->n_out) return cam_fail("输出表越过 header", 5);
    if (h->n_mb == 0 || h->n_mb > 1000000) return cam_fail("n_mb_records 越界", 5);
    for (int i = 0; i < NSEG; i++) {
        if (h->seg[i].len && (uint64_t)h->seg[i].off + h->seg[i].len > h->total)
            return cam_fail("段表越界", 5);
    }
    for (int i = 0; i < 5; i++) {
        uint32_t c = h->seg[i].len ? crc32_buf(pl + h->seg[i].off, h->seg[i].len) : 0;
        if (c != h->seg[i].crc) {
            printf("!! seg %s crc=%08x != %08x\n", sname[i], c, h->seg[i].crc);
            return cam_fail("payload 段 CRC 不符", 5);
        }
        SAY("  payload %-12s len=%7u crc=%08x OK\n", sname[i], h->seg[i].len, c);
    }
    /* 输入槽必须装得下 640×640×3 的 int8 张量（与主机 input_int8 同口径） */
    if (h->input_bytes != (uint32_t)INPUT_BYTES) {
        printf("!! input_bytes=%u != %u\n", h->input_bytes, (unsigned)INPUT_BYTES);
        return cam_fail("payload input_bytes 不是 640x640x3", 5);
    }
    if ((uint64_t)h->input_npu + (uint64_t)INPUT_BYTES > (uint64_t)ARENA_SIZE)
        return cam_fail("input_npu 越过 arena", 5);
    *out_h = h;
    return 0;
}

/* desc / wgt_mailbox 两段搬进 arena（就地 CRC 回读；照 y1run 的第 2 步） */
static int payload_to_arena(const uint8_t *pl, const struct hdr *h, uint8_t *arena) {
    struct { int id; uint32_t dst, len; } cp[2] = {
        {SEG_DESC, h->desc_npu,  h->seg[SEG_DESC].len},
        {SEG_WGT,  h->mbx_npu,   h->mbx_bytes},
    };
    static const char *sname[NSEG] = {"desc", "wgt_mailbox", "input_int8",
                                      "mb_records", "golden_raw", "rsv"};
    if (h->mbx_bytes != h->seg[SEG_WGT].len)
        return cam_fail("payload mbx_bytes 与 wgt_mailbox 段长不符", 5);
    for (unsigned k = 0; k < 2; k++) {
        if (!cp[k].len) continue;
        if ((uint64_t)cp[k].dst + cp[k].len > (uint64_t)ARENA_SIZE)
            return cam_fail("payload 段越过 arena", 5);
        memcpy(arena + cp[k].dst, pl + h->seg[cp[k].id].off, cp[k].len);
        __sync_synchronize();
        uint32_t c = crc32_buf(arena + cp[k].dst, cp[k].len);
        if (c != h->seg[cp[k].id].crc) {
            printf("!! copy %s dst=0x%08x crc=%08x != %08x\n",
                   sname[cp[k].id], cp[k].dst, c, h->seg[cp[k].id].crc);
            return cam_fail("arena 回读 CRC 不符", 5);
        }
        SAY("  copy %-12s -> npu=0x%08x len=%7u crc=%08x OK\n",
            sname[cp[k].id], cp[k].dst, cp[k].len, c);
    }
    return 0;
}

/* 输出名 → y1_deq.h 下标（顺序可能与 OUT_NAMES 不同；按名字匹配） */
static int deq_index(const char *name) {
    for (int i = 0; i < Y1_DEQ_N; i++)
        if (strcmp(name, DEQ_NAME[i]) == 0) return i;
    return -1;
}

/* 输出名 → (stride, 通道数)。名字形如 cls_8 / bbox_32 / kps_16。 */
static int out_geom(const char *name, int *stride, int *ch) {
    const char *us = strchr(name, '_');
    if (!us || !us[1]) return -1;
    if (!strncmp(name, "cls", 3)) *ch = 1;
    else if (!strncmp(name, "obj", 3)) *ch = 1;
    else if (!strncmp(name, "bbox", 4)) *ch = 4;
    else if (!strncmp(name, "kps", 3)) *ch = 10;
    else return -1;
    *stride = atoi(us + 1);
    return (*stride == 8 || *stride == 16 || *stride == 32) ? 0 : -1;
}

/* 整块落盘（EINTR 重试；短写继续） */
static int write_file(const char *path, const void *buf, size_t len) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { perror("!! y1cam: open(dump)"); return -1; }
    const uint8_t *p = (const uint8_t *)buf;
    size_t done = 0;
    while (done < len) {
        ssize_t n = write(fd, p + done, len - done);
        if (n < 0) {
            if (errno == EINTR) continue;
            perror("!! y1cam: write(dump)");
            close(fd);
            return -1;
        }
        done += (size_t)n;
    }
    if (close(fd) != 0) { perror("!! y1cam: close(dump)"); return -1; }
    return 0;
}

/* ---------------------------------------------------------------------------
 * 后处理工作区（~737 KB，放 BSS；--once 与 --loop 共用，单线程）
 * ------------------------------------------------------------------------- */
typedef struct {
    float cls[3][MAX_ANCHORS], obj[3][MAX_ANCHORS], bbox[3][MAX_ANCHORS * 4];
    const int8_t *raw_bbox[3];      /* 诊断：bbox 原始块（未去折叠），用于布局 A/B */
    int raw_bbox_n[3];
    float bb_s[3];
    int bb_z[3];
    det_t cand[MAX_DETS];
    int keep[MAX_DETS];
    ckey_t order[MAX_DETS];
    unsigned char drop[MAX_DETS];
} post_ctx_t;

static post_ctx_t g_post;

/* 12 路 int8 输出 → 反量化/去折叠（口径见文件头 ★）→ 三 stride 的 float 张量。
   成功 0；失败已打报文并返回退出码（8）。 */
static int deq_outputs(const struct hdr *h, const uint8_t *arena, post_ctx_t *pc,
                       stride_in_t in3[3]) {
    int have[3] = {0, 0, 0};
    for (uint32_t i = 0; i < h->n_out; i++) {
        const struct out *o = &h->out[i];
        /* ★ 2026-10-26 诊断：逐路输出指纹（与主机黄金对账用；Y1_DBG_TOP>0 时打印） */
        if (g_dbg_top > 0 && (uint64_t)o->npu + o->bytes <= (uint64_t)ARENA_SIZE) {
            printf("OUT %-8s npu=0x%08x bytes=%u crc=%08x b0=%d,%d,%d,%d\n",
                   o->name, o->npu, o->bytes, crc32_buf(arena + o->npu, o->bytes),
                   (int)(int8_t)arena[o->npu], (int)(int8_t)arena[o->npu + 1],
                   (int)(int8_t)arena[o->npu + 2], (int)(int8_t)arena[o->npu + 3]);
        }
        int di = deq_index(o->name);
        if (di < 0) {
            printf("!! 输出名 %s 不在 y1_deq.h\n", o->name);
            return cam_fail("输出名不匹配反量化表", 8);
        }
        int stride = 0, ch = 0;
        if (out_geom(o->name, &stride, &ch) != 0) {
            printf("!! 输出名 %s 的 stride/通道不认识\n", o->name);
            return cam_fail("输出名不认识", 8);
        }
        int wn = NCH / stride, n = wn * wn;
        uint32_t want = (uint32_t)n * (uint32_t)ch;
        if (o->bytes != want || (uint64_t)o->npu + want > (uint64_t)ARENA_SIZE) {
            printf("!! 输出 %s npu=0x%08x bytes=%u（期望 %u）\n", o->name, o->npu, o->bytes, want);
            return cam_fail("输出表长度/地址不对", 8);
        }
        int slot = (stride == 8) ? 0 : (stride == 16 ? 1 : 2);
        const int8_t *raw = (const int8_t *)(arena + o->npu);
        if (!strncmp(o->name, "cls", 3)) {
            deq_planar(raw, n, 1, DEQ_SCALE[di], DEQ_ZP[di], pc->cls[slot]);
            have[slot] |= 1;
        } else if (!strncmp(o->name, "obj", 3)) {
            deq_planar(raw, n, 1, DEQ_SCALE[di], DEQ_ZP[di], pc->obj[slot]);
            have[slot] |= 2;
        } else if (!strncmp(o->name, "bbox", 4)) {
            deq_planar_bias(raw, n, 4, DEQ_SCALE[di], DEQ_ZP[di], g_bbox_bias, pc->bbox[slot]);
            pc->raw_bbox[slot] = raw;
            pc->raw_bbox_n[slot] = n;
            pc->bb_s[slot] = DEQ_SCALE[di];
            pc->bb_z[slot] = DEQ_ZP[di];
            have[slot] |= 4;
        }
        /* kps_*：不画关键点（口径在 yunet_post.py），只做了名字/长度校验 */
    }
    for (int k = 0; k < 3; k++) {
        if ((have[k] & 7) != 7) {
            printf("!! stride %d 的 cls/obj/bbox 不全（0x%x）\n", 8 << k, have[k]);
            return cam_fail("payload 输出表缺 cls/obj/bbox", 8);
        }
        in3[k].cls = pc->cls[k]; in3[k].obj = pc->obj[k]; in3[k].bbox = pc->bbox[k];
        in3[k].stride = 8 << k;
    }
    return 0;
}

/* ★ 2026-10-26：把 12 路输出与主机参考块（按同一布局排好、放在 DDR 指定物理地址）逐字节对比。
   用来判定"板上 NPU 的结果与参考是否逐字节一致"——只回 CRC 看不出差异形状。 */
static void cmp_golden_blocks(const struct hdr *h, const uint8_t *arena) {
    if (!g_cmp_golden || g_fd < 0) return;
    uint32_t total = 0;
    for (uint32_t i = 0; i < h->n_out; i++) total += h->out[i].bytes;
    size_t mlen = ((size_t)total + 0xFFFu) & ~(size_t)0xFFFu;
    const uint8_t *g = (const uint8_t *)map_phys(g_fd, g_cmp_golden, mlen, "golden");
    if (!g) { printf("!! cmp-golden map 失败\n"); return; }
    uint32_t off = 0; unsigned long badtot = 0;
    for (uint32_t i = 0; i < h->n_out; i++) {
        const struct out *o = &h->out[i];
        const uint8_t *b = arena + o->npu;
        unsigned long bad = 0; long first = -1;
        for (uint32_t k = 0; k < o->bytes; k++) {
            if (b[k] != g[off + k]) {
                if (first < 0) first = (long)k;
                bad++;
            }
        }
        printf("CMP %-8s bytes=%u bad=%lu first=%ld (board=%d gold=%d)\n",
               o->name, o->bytes, bad, first,
               first >= 0 ? (int)(int8_t)b[first] : 0,
               first >= 0 ? (int)(int8_t)g[off + (uint32_t)first] : 0);
        if (!strncmp(o->name, "bbox", 4)) {   /* 差值分布：判定"系统常数偏置"还是"逐点误差" */
            long dsum = 0; int dmin = 999, dmax = -999; unsigned long within1 = 0;
            for (uint32_t k = 0; k < o->bytes; k++) {
                int d = (int)(int8_t)b[k] - (int)(int8_t)g[off + k];
                dsum += d;
                if (d < dmin) dmin = d;
                if (d > dmax) dmax = d;
                if (d >= -1 && d <= 1) within1++;
            }
            printf("CMPSTAT %-8s n=%u mean=%.2f min=%d max=%d within1=%lu\n",
                   o->name, o->bytes, (double)dsum / (double)o->bytes, dmin, dmax, within1);
        }
        off += o->bytes;
        badtot += bad;
    }
    printf("CMP total_bad=%lu / %u\n", badtot, off);
    munmap((void *)g, mlen);
    fflush(stdout);
}

/* 一帧后处理：反量化 → 解码/NMS → 屏幕映射 → 写 OVERLAY（en + commit）。
   nb=0 也提交 count=0，清掉上一轮框。返回框数（≥0）；失败返回负退出码（报文已打）。 */
static int post_and_draw(const struct hdr *h, const uint8_t *arena, uint8_t *vreg,
                         post_ctx_t *pc, int *nc_out, int *nk_out, box_t bx[MAX_BOXES]) {
    stride_in_t in3[3];
    cmp_golden_blocks(h, arena);
    int rc = deq_outputs(h, arena, pc, in3);
    if (rc) return -rc;

    int nk = 0;
    int nc = run_post(in3, 3, pc->cand, MAX_DETS, g_score_thr, g_nms_thr, TOP_K,
                      pc->keep, &nk, pc->order, pc->drop);
    dbg_max_score(in3, 3);
    dbg_bbox_layout(pc->raw_bbox, pc->raw_bbox_n, pc->bb_s, pc->bb_z, in3, 3);
    dbg_top_cand(pc->cand, nc);
    if (nc < 0) return -cam_fail("后处理容量不足", 8);
    *nc_out = nc;
    *nk_out = nk;

    int nb = map_boxes(pc->cand, pc->keep, nk, bx, MAX_BOXES);

    volatile uint32_t *ovl  = (volatile uint32_t *)(vreg + R_V_OVERLAY);
    volatile uint32_t *breg = (volatile uint32_t *)(vreg + R_V_BOX0);
    for (int k = 0; k < nb; k++) {
        /* ★ 2026-10-26：overlay.v 取 `bx1 <= bq[31:16]`、`by1 <= bq[15:0]`
           ⇒ **高 16 位 = x、低 16 位 = y**（此前写反，框被沿对角线转置）。 */
        breg[2 * k + 0] = ((uint32_t)(uint16_t)bx[k].x1 << 16) | (uint32_t)(uint16_t)bx[k].y1;
        breg[2 * k + 1] = ((uint32_t)(uint16_t)bx[k].x2 << 16) | (uint32_t)(uint16_t)bx[k].y2;
    }
    *ovl = (uint32_t)((unsigned)nb << 8) | 1u;      /* 后备 bank：先装框数 + en */
    __sync_synchronize();
    *ovl = (uint32_t)((unsigned)nb << 8) | 3u;      /* en + commit（nb=0 也提交，清旧框） */
    __sync_synchronize();
    return nb;
}

/* ---------------------------------------------------------------------------
 * run_loop —— `--loop`：连续检测（Task 11）
 *   每轮：等下一个 seq 变化（5 s 超时）→ 快照 → 预处理 → NPU 单帧（邮箱仅首轮）
 *   → 后处理 → 写框 → 一行 CAMRUN 遥测。返回进程退出码。
 * ------------------------------------------------------------------------- */
static int run_loop(const struct hdr *h, uint8_t *reg, uint8_t *arena, uint8_t *fb,
                    uint8_t *snapm, uint8_t *vreg, const uint8_t *pl,
                    unsigned frames, unsigned interval_ms, const char *dump_path) {
    volatile uint32_t *st     = (volatile uint32_t *)(vreg + R_V_STATUS);
    volatile uint32_t *ra     = (volatile uint32_t *)(reg + R_WGT_A);
    volatile uint32_t *rd     = (volatile uint32_t *)(reg + R_WGT_D);
    volatile uint32_t *rw     = (volatile uint32_t *)(reg + R_WGT_WE);
    volatile uint32_t *ctrl   = (volatile uint32_t *)(reg + R_CTRL);
    volatile uint32_t *nstat  = (volatile uint32_t *)(reg + R_STATUS);
    volatile uint32_t *desc_a = (volatile uint32_t *)(reg + R_DESC_A);
    volatile uint32_t *desc_n = (volatile uint32_t *)(reg + R_DESC_N);
    uint16_t *snap = (uint16_t *)snapm;

    /* 首轮前等 init_done（5 s，与 --once 同值） */
    if ((st[0] & 0x1u) == 0u) {
        uint64_t t0 = now_ns();
        while ((st[0] & 0x1u) == 0u) {
            if (now_ns() - t0 > VIDEO_INIT_TIMEOUT_NS)
                return cam_fail("no frame", 4);
            usleep(1000);
        }
        SAY("  video init_done after %llu ns\n", (unsigned long long)(now_ns() - t0));
    }

    for (unsigned n = 1; frames == 0 || n <= frames; n++) {
        /* ---- 1) 等下一个 seq 变化（每轮从"当前"起等，超时 5 s） ---- */
        uint32_t s0   = st[0];
        uint32_t seq0 = s0 >> 8;
        uint64_t tw   = now_ns();
        uint32_t s1;
        for (;;) {
            s1 = st[0];
            if ((s1 >> 8) != seq0) break;
            if (now_ns() - tw > LOOP_SEQ_TIMEOUT_NS)
                return cam_fail("no frame", 4);
            usleep(1000);
        }
        uint64_t t_det = now_ns();
        uint32_t seq   = s1 >> 8;
        unsigned bank  = (g_force_bank >= 0) ? (unsigned)g_force_bank
                                             : (unsigned)((~(s1 >> 1)) & 1u);   /* 写 bank 反相 = 稳定帧 */

        /* ---- 2) 快照（640×640，帧存内列 192..831 / 行 40..679） ---- */
        uint64_t t_snap = now_ns();
        snap_crop((const uint16_t *)fb, snap, (int)bank);
        __sync_synchronize();
        unsigned snap_ms = (unsigned)((now_ns() - t_snap) / 1000000ull);
        unsigned wait_ms = (unsigned)((t_det - tw) / 1000000ull);

        if (dump_path && n == 1) {
            if (write_file(dump_path, snap, SNAP_BYTES) != 0)
                return cam_fail("dump write failed", 6);
            SAY("  dump -> %s (%u bytes)\n", dump_path, (unsigned)SNAP_BYTES);
        }

        /* ---- 3) 预处理 → arena + input_npu ---- */
        uint64_t t_prep = now_ns();
        prep_bgr_nchw_int8(snap, (int8_t *)(arena + h->input_npu));
        __sync_synchronize();
        unsigned prep_ms = (unsigned)((now_ns() - t_prep) / 1000000ull);

        /* ---- 4) 首轮：desc/wgt → arena + 回放邮箱（以后每轮只 reset/start） ---- */
        if (n == 1) {
            int rc = payload_to_arena(pl, h, arena);
            if (rc) return rc;
            const uint8_t *mbr = pl + h->seg[SEG_MB].off;
            uint64_t tm = now_ns();
            for (uint32_t i = 0; i < h->n_mb; i++) {
                uint32_t a, d;
                memcpy(&a, mbr + 8u * i, 4);
                memcpy(&d, mbr + 8u * i + 4, 4);
                *ra = a; *rd = d; __sync_synchronize(); *rw = 1u; __sync_synchronize();
                if (g_mb_gap_us > 0) usleep((useconds_t)g_mb_gap_us);
            }
            __sync_synchronize();
            SAY("  mailbox %u records programmed (%llu ns)\n", h->n_mb,
                (unsigned long long)(now_ns() - tm));
        }

        /* ---- 5) NPU 单帧：status=1 → soft_reset → desc → start → 轮询 ---- */
        *nstat = 0x1u;
        *ctrl = CTRL_SOFT_RESET;
        usleep(10000);
        *desc_a = h->desc_npu;
        *desc_n = h->desc_count;
        __sync_synchronize();
        uint64_t tn = now_ns();
        *ctrl = CTRL_START;
        uint32_t stv = 0;
        for (;;) {
            stv = *nstat;
            if ((stv & 0x3u) != 0u) break;
            if (now_ns() - tn > NPU_TIMEOUT_NS) break;
            usleep(100);          /* 不能忙等：单核跑满会饿死 dropbear/网络栈（实测 ssh 50% 超时） */
        }
        unsigned npu_ms = (unsigned)((now_ns() - tn) / 1000000ull);   /* 只计 start→done */
        if ((stv & 0x3u) == 0u) {
            printf("!! npu timeout status=0x%08x\n", stv);
            return cam_fail("npu timeout", 5);
        }
        if (stv & 0x2u) {
            printf("!! npu err status=0x%08x\n", stv);
            return cam_fail("npu err", 5);
        }
        __sync_synchronize();

        /* ---- 6) 后处理 + 写框（dets=0 也 commit） ---- */
        uint64_t t_post = now_ns();
        int nc = 0, nk = 0;
        box_t bx[MAX_BOXES];
        int nb = post_and_draw(h, arena, vreg, &g_post, &nc, &nk, bx);
        if (nb < 0) return -nb;
        unsigned post_ms = (unsigned)((now_ns() - t_post) / 1000000ull);

        /* ---- 7) 一行遥测（--quiet 下也打；这是 --loop 的唯一必打行） ---- */
        printf("CAMRUN n=%u seq=%u bank=%u wait_ms=%u snap_ms=%u prep_ms=%u npu_ms=%u post_ms=%u dets=%d\n",
               n, seq, bank, wait_ms, snap_ms, prep_ms, npu_ms, post_ms, nb);
        fflush(stdout);
        for (int k = 0; k < nb; k++)
            SAY("BOX %d=[%d,%d,%d,%d] conf=%.4f\n", k, bx[k].x1, bx[k].y1, bx[k].x2, bx[k].y2,
                (double)g_post.cand[g_post.keep[k]].conf);

        /* ---- 8) 轮间休眠（最后一轮后不休，直接退出 0） ---- */
        if (interval_ms > 0 && (frames == 0 || n < frames))
            usleep((useconds_t)(interval_ms * 1000u));
    }
    return 0;
}

/* 十进制/0x 前缀无符号参数：成功 0；多余字符或空串 -1 */
static int parse_uint(const char *s, unsigned *out) {
    char *end = NULL;
    if (!s || !*s) return -1;
    unsigned long v = strtoul(s, &end, 0);
    if (!end || *end) return -1;
    *out = (unsigned)v;
    return 0;
}

static void usage(void) {
    fprintf(stderr, "usage: y1cam --once [--dump PATH] [--payload PHYS] [--bank N] [--quiet]\n");
    fprintf(stderr, "       y1cam --loop [--frames N] [--interval-ms M] [--dump PATH] [--payload PHYS] [--bank N] [--quiet]\n");
}

int main(int argc, char **argv) {
    post_env_init();
    int once = 0, loop = 0;
    int frames_set = 0, interval_set = 0;
    unsigned frames = 0, interval_ms = 0;
    const char *dump_path = NULL;
    unsigned long payload_phys = PAYLOAD_BASE_DEF;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--once")) once = 1;
        else if (!strcmp(argv[i], "--loop")) loop = 1;
        else if (!strcmp(argv[i], "--frames") && i + 1 < argc) {
            if (parse_uint(argv[++i], &frames) != 0) { usage(); return 2; }
            frames_set = 1;
        }
        else if (!strcmp(argv[i], "--interval-ms") && i + 1 < argc) {
            if (parse_uint(argv[++i], &interval_ms) != 0) { usage(); return 2; }
            interval_set = 1;
        }
        else if (!strcmp(argv[i], "--dump") && i + 1 < argc) dump_path = argv[++i];
        else if (!strcmp(argv[i], "--payload") && i + 1 < argc) payload_phys = strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--bank") && i + 1 < argc) {
            unsigned b = 0;
            if (parse_uint(argv[++i], &b) != 0 || b > 1u) { usage(); return 2; }
            g_force_bank = (int)b;
        }
        else if (!strcmp(argv[i], "--pl-input")) g_pl_input = 1;
        else if (!strcmp(argv[i], "--input-phys") && i + 1 < argc) {
            g_input_phys = strtoul(argv[++i], NULL, 0);
            if (g_input_phys & 0xFFFu) return cam_fail("--input-phys 未 4KiB 对齐", 2);
        }
        else if (!strcmp(argv[i], "--cmp-golden") && i + 1 < argc) {
            g_cmp_golden = strtoul(argv[++i], NULL, 0);
            if (g_cmp_golden & 0xFFFu) return cam_fail("--cmp-golden 未 4KiB 对齐", 2);
        }
        else if (!strcmp(argv[i], "--quiet")) g_quiet = 1;
        else { usage(); return 2; }
    }
    if (once + loop != 1) { usage(); return 2; }
    if (once && (frames_set || interval_set)) { usage(); return 2; }
    g_loop_mode = loop;
    if (payload_phys & 0x3F) return cam_fail("payload 地址未 64B 对齐", 2);

    crc_init();
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    g_fd = fd;
    if (fd < 0) { perror("!! y1cam: open(/dev/mem)"); return 3; }

    uint8_t *reg   = (uint8_t *)map_phys(fd, REG_BASE, PAGE, "regs");
    uint8_t *arena = (uint8_t *)map_phys(fd, ARENA_BASE, ARENA_SIZE, "arena");
    uint8_t *fb    = (uint8_t *)map_phys(fd, FB_BASE, FB_MAP_BYTES, "fb");
    uint8_t *snapm = (uint8_t *)map_phys(fd, SNAP_BASE, SNAP_MAP_BYTES, "snap");
    uint8_t *vreg  = (uint8_t *)map_phys(fd, VIDEO_REG_BASE, PAGE, "video");
    uint8_t *pl    = (uint8_t *)map_phys(fd, payload_phys, PAYLOAD_MAX, "payload");
    if (!reg || !arena || !fb || !snapm || !vreg || !pl) { close(fd); return 3; }

    /* ---- 1) payload 校验 ---- */
    struct hdr *h = NULL;
    int rc = payload_check(pl, &h);
    if (rc) { close(fd); return rc; }
    SAY("  payload ok: total=%u input_npu=0x%08x input_bytes=%u\n",
        h->total, h->input_npu, h->input_bytes);

    if (loop) {
        rc = run_loop(h, reg, arena, fb, snapm, vreg, pl, frames, interval_ms, dump_path);
        munmap(pl, PAYLOAD_MAX);
        munmap(vreg, PAGE);
        munmap(snapm, SNAP_MAP_BYTES);
        munmap(fb, FB_MAP_BYTES);
        munmap(arena, ARENA_SIZE);
        munmap(reg, PAGE);
        close(fd);
        return rc;
    }

    /* ---- 2) 等一帧：init_done → seq 前进 → 取反相 bank（--pl-input 时跳过） ---- */
    uint16_t *snap = (uint16_t *)snapm;
    uint32_t seq = 0;
    unsigned bank = 0;
    if (g_input_phys) {
        /* --input-phys：主机把一张已知图的 int8 输入（NCHW BGR, q=x-128）写到该 DDR 地址，
           本程序只做搬运 ⇒ 用来给"NPU+后处理"喂确定性的脸图（相机不在环里）。 */
        const uint8_t *pin = (const uint8_t *)map_phys(fd, g_input_phys, INPUT_BYTES, "inp");
        if (!pin) return cam_fail("map input-phys 失败", 3);
        memcpy(arena + h->input_npu, pin, INPUT_BYTES);
        munmap((void *)pin, INPUT_BYTES);
        __sync_synchronize();
        printf("PHYSINPUT phys=0x%08lx npu=0x%08x len=%u crc=%08x\n",
               g_input_phys, h->input_npu, (unsigned)INPUT_BYTES,
               crc32_buf(arena + h->input_npu, INPUT_BYTES));
    } else if (!g_pl_input) {
    volatile uint32_t *st = (volatile uint32_t *)(vreg + R_V_STATUS);
    uint32_t s0 = st[0];
    if ((s0 & 0x1u) == 0u) {
        uint64_t t0 = now_ns();
        while ((st[0] & 0x1u) == 0u) {
            if (now_ns() - t0 > VIDEO_INIT_TIMEOUT_NS)
                return cam_fail("no video frames", 4);
            usleep(1000);
        }
        SAY("  video init_done after %llu ns\n", (unsigned long long)(now_ns() - t0));
        s0 = st[0];
    }

    uint32_t seq0 = s0 >> 8;
    uint32_t s1 = s0;
    uint64_t t0 = now_ns();
    for (;;) {
        s1 = st[0];
        if ((s1 >> 8) != seq0) break;
        if (now_ns() - t0 > VIDEO_SEQ_TIMEOUT_NS)
            return cam_fail("no video frames", 4);
        usleep(100);              /* 让出 CPU（理由同 NPU 轮询处） */
    }
    seq = s1 >> 8;
    bank = (g_force_bank >= 0) ? (unsigned)g_force_bank
                               : (unsigned)((~(s1 >> 1)) & 1u);   /* 写 bank 反相 = 稳定帧 */
    SAY("  frame: status=0x%08x seq %u -> %u bank=%u (wait %llu ns)\n",
        s1, seq0, seq, bank, (unsigned long long)(now_ns() - t0));

    /* ---- 3) 快照（640×640，帧存内列 192..831 / 行 40..679） ---- */
    snap_crop((const uint16_t *)fb, snap, (int)bank);
    __sync_synchronize();
    SAY("  snap 640x640 from fb bank %u (row+%d col+%d)\n", bank, g_crop_y, g_crop_x);

    if (dump_path) {
        if (write_file(dump_path, snap, SNAP_BYTES) != 0)
            return cam_fail("dump write failed", 6);
        SAY("  dump -> %s (%u bytes)\n", dump_path, (unsigned)SNAP_BYTES);
    }

    /* ---- 4) 预处理 → arena + input_npu ---- */
    prep_bgr_nchw_int8(snap, (int8_t *)(arena + h->input_npu));
    } else {
        /* --pl-input：直接拿 payload 的 input_int8（主机对账图），不碰相机 */
        if (h->seg[SEG_INPUT].len != (uint32_t)INPUT_BYTES)
            return cam_fail("payload input_int8 段长不符", 5);
        memcpy(arena + h->input_npu, pl + h->seg[SEG_INPUT].off, INPUT_BYTES);
        __sync_synchronize();
        if (crc32_buf(arena + h->input_npu, INPUT_BYTES) != h->seg[SEG_INPUT].crc)
            return cam_fail("payload input_int8 CRC 不符", 5);
        printf("PLINPUT npu=0x%08x len=%u crc=%08x (payload 冻结输入)\n",
               h->input_npu, (unsigned)INPUT_BYTES, h->seg[SEG_INPUT].crc);
    }
    __sync_synchronize();
    uint32_t crc = crc32_buf(arena + h->input_npu, INPUT_BYTES);
    SAY("  input_int8 npu=0x%08x len=%u (NCHW BGR, q=x-128)\n",
        h->input_npu, (unsigned)INPUT_BYTES);

    /* ---- 5) desc / wgt_mailbox → arena（NPU 只认 arena 内的地址） ---- */
    rc = payload_to_arena(pl, h, arena);
    if (rc) { close(fd); return rc; }

    /* ---- 6) 回放邮箱记录（照 y1run.c：addr/data/we，一条一拍） ---- */
    volatile uint32_t *ra    = (volatile uint32_t *)(reg + R_WGT_A);
    volatile uint32_t *rd    = (volatile uint32_t *)(reg + R_WGT_D);
    volatile uint32_t *rw    = (volatile uint32_t *)(reg + R_WGT_WE);
    volatile uint32_t *ctrl  = (volatile uint32_t *)(reg + R_CTRL);
    volatile uint32_t *nstat = (volatile uint32_t *)(reg + R_STATUS);
    volatile uint32_t *desc_a = (volatile uint32_t *)(reg + R_DESC_A);
    volatile uint32_t *desc_n = (volatile uint32_t *)(reg + R_DESC_N);

    const uint8_t *mbr = pl + h->seg[SEG_MB].off;
    {
        uint64_t tm = now_ns();
        for (uint32_t i = 0; i < h->n_mb; i++) {
            uint32_t a, d;
            memcpy(&a, mbr + 8u * i, 4);
            memcpy(&d, mbr + 8u * i + 4, 4);
            *ra = a; *rd = d; __sync_synchronize(); *rw = 1u; __sync_synchronize();
            if (g_mb_gap_us > 0) usleep((useconds_t)g_mb_gap_us);
        }
        __sync_synchronize();
        SAY("  mailbox %u records programmed (%llu ns)\n", h->n_mb,
            (unsigned long long)(now_ns() - tm));
    }

    /* ---- 7) 单帧起跑（照 y1run；soft_reset 后留 10 ms 复位时间，与 y1run 缺省同值） ---- */
    *nstat = 0x1u;
    *ctrl = CTRL_SOFT_RESET;
    usleep(10000);
    *desc_a = h->desc_npu;
    *desc_n = h->desc_count;
    __sync_synchronize();
    uint64_t tn = now_ns();
    *ctrl = CTRL_START;
    uint32_t stv = 0;
    for (;;) {
        stv = *nstat;
        if ((stv & 0x3u) != 0u) break;
        if (now_ns() - tn > NPU_TIMEOUT_NS) break;
        usleep(100);              /* 让出 CPU（理由同 --loop 的 NPU 轮询处） */
    }
    unsigned long long npu_ms = (unsigned long long)((now_ns() - tn) / 1000000ull);
    if ((stv & 0x3u) == 0u) {
        printf("!! npu timeout status=0x%08x\n", stv);
        return cam_fail("npu timeout", 7);
    }
    if (stv & 0x2u) {
        printf("!! npu err status=0x%08x\n", stv);
        return cam_fail("npu err", 7);
    }
    SAY("  npu done status=0x%08x ns=%llu\n", stv, (unsigned long long)(now_ns() - tn));
    __sync_synchronize();

    /* ---- 8–10) 反量化/去折叠 → 解码/NMS → 映射 → 写叠加框（en + commit） ---- */
    int nc = 0, nk = 0;
    box_t bx[MAX_BOXES];
    int nb = post_and_draw(h, arena, vreg, &g_post, &nc, &nk, bx);
    if (nb < 0) return -nb;
    SAY("  post: cands=%d kept=%d (score_thr=%.2f nms_thr=%.2f top_k=%d)\n",
        nc, nk, (double)g_score_thr, (double)g_nms_thr, TOP_K);

    for (int k = 0; k < nb; k++)
        SAY("BOX %d=[%d,%d,%d,%d] conf=%.4f\n", k, bx[k].x1, bx[k].y1, bx[k].x2, bx[k].y2,
            (double)g_post.cand[g_post.keep[k]].conf);

    /* ---- 判据行（--quiet 时只有这四行） ---- */
    printf("FRAME seq=%u bank=%u\n", seq, bank);
    printf("BOARD_INPUT_CRC=%08x\n", crc);
    printf("CAM_DETS=%d\n", nb);
    printf("NPU_MS=%llu\n", npu_ms);
    fflush(stdout);

    munmap(pl, PAYLOAD_MAX);
    munmap(vreg, PAGE);
    munmap(snapm, SNAP_MAP_BYTES);
    munmap(fb, FB_MAP_BYTES);
    munmap(arena, ARENA_SIZE);
    munmap(reg, PAGE);
    close(fd);
    return 0;
}
#endif /* POST_C_HOST */
