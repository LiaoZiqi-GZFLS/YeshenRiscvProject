/* =============================================================================
 * y1/partA/ddr_bw_test.c —— 板端 DDR **有效带宽**实测（Linux 用户态，RV32）
 * -----------------------------------------------------------------------------
 * 目的
 *   计划中的加速器把每层特征图经 DDR 往返：30.5 MB/帧 ⇒ @10fps 必须 305 MB/s、
 *   @15fps 必须 458 MB/s。本程序给出**可解释**的实测值：不是"一个数"，而是
 *   "数 + 判别它测的到底是不是 DDR"。
 *
 * 【必须处理的方法学陷阱 —— 本程序存在的唯一理由】
 *   本核是 **RV32**：最宽的单次访问只有 **32 bit**，一次内存搬运是
 *   `load`+`store` = **2 条指令/元素**。所以 **CPU 驱动**这条路径的上界 ≈
 *   `4 B / (元素指令数)` 每周期，100 MHz 下量级只有 **~200 MB/s**，
 *   **低于 305 MB/s 的需求**。于是：单纯测到一个低值，只能说
 *   "**CPU 驱不动 DDR**"，**不能**说 "DDR 慢"。两者必须分开。
 *
 * 【判别规则（width sweep，本程序的核心判据）】
 *   同一足迹下分别用 volatile uint8_t / uint16_t / uint32_t 访问，比吞吐：
 *     · 吞吐**随访问位宽大致成比例放大**（r8:r16:r32 ≈ 1:2:4）
 *         ⇒ 循环 **指令/CPU 受限**：每条访存指令搬的字节数变了、指令速率没变。
 *           此时**绝对数字与 DDR 无关**，测不出 DDR 上限 ⇒ 必须升级到 A3 的
 *           AXI 主口微基准（让 fabric 主口去发，绕开 CPU 的指令速率）。
 *     · 吞吐**跨位宽大致持平（平坦）**
 *         ⇒ 循环 **内存受限**，数字才有意义，才可与 305/458 MB/s 比较。
 *   阈值（写死在下面，且每次运行都把原始比值打出来供人工复核）：
 *     平坦      r32/r8 ≤ 1.40（对 read/write/rmw 三个 mode **全部**成立）
 *     强放大    r32/r8 ≥ 1.80（任一 mode 成立即算"有指令受限证据"）
 *     1.40~1.80 之间 ⇒ 不判平坦（保守：不主张这个数是 DDR 数），走指令受限分支。
 *
 * 【缓存负对照（measurement validity，第 5 条要求）】
 *   同一测法再对一个**小**缓冲（默认 32 KiB，能装进 cache）跑一遍。
 *   小缓冲速率必须**明显高于**大缓冲（判据：**32 位那一行**的 ratio = small/big
 *   ≥ **1.50**，三个 mode 都要成立）。若**不**明显高 ⇒ 大缓冲那个数**不是**
 *   DRAM 在限速 ⇒ 本次测量**无效**，报告里不许引用该数字。
 *   注意：若循环本就是 **CPU 受限**，小缓冲**不会**变快是**正常**的——所以
 *   "无效"只在**同时**满足"负对照不成立"且"位宽扫描毫无放大证据"时才判
 *   （既没测到 DRAM、又不能用 CPU 受限解释 ⇒ 自相矛盾 ⇒ 无效）。
 *
 * 【判定优先级（写死在代码里，原始数字全打出来）】
 *   P1  (!cache_ok && !scaling_evidence)                  -> MEASUREMENT_INVALID_CACHE_CONTROL_FAILED
 *   P2  all_flat（内存受限）: 与 305/458 比较
 *         ref ≥ 458                                        -> MEMORY_BOUND_MEETS_458
 *         ref ≥ 305                                        -> MEMORY_BOUND_MEETS_305
 *         ref < 305                                        -> MEMORY_BOUND_BELOW_305
 *   P3  其余（有放大证据 / 不判平坦）                      -> INSN_BOUND_DDR_CEILING_UNKNOWN
 *   其中 ref = max(u32 read, u32 write) 的大缓冲速率（架构流的是特征图，是读+写，
 *   不是 rmw；取两者较大者作为"可达值"的代表）。
 *
 * 【RESULT 行为纯 ASCII】
 *   本板控制台是 GBK 味的、仓内被非 ASCII 打印坑过 ⇒ 程序**只打 ASCII**。
 *   中文结论写在报告 y1/reports/ddr_bandwidth.md 里，与这里的 ASCII 码一一映射：
 *     MEMORY_BOUND_MEETS_458   -> RESULT: 内存受限，达 305 MB/s（且达 458 MB/s 15fps 档）
 *     MEMORY_BOUND_MEETS_305   -> RESULT: 内存受限，达 305 MB/s
 *     MEMORY_BOUND_BELOW_305   -> RESULT: 内存受限，只达 10fps 档
 *        ⚠️ 映射文字按任务书给的措辞；但 **<305 MB/s 时其实连 10fps 档也达不到**，
 *           写报告时必须把这一点讲明，别让"只达 10fps 档"被读成"305 达标"。
 *     INSN_BOUND_DDR_CEILING_UNKNOWN -> RESULT: 指令受限，本次测不出 DDR 上限（须升级到 A3 的 AXI 主口微基准）
 *     MEASUREMENT_INVALID_CACHE_CONTROL_FAILED -> RESULT: 测法无效（缓存负对照未成立）
 *
 * 【口径】
 *   · MB = 1e6 字节（十进制），与 305 / 458 MB/s 同口径。
 *   · read / write / rmw **分开测、分开报**。
 *   · 一个 pass 的"字节数" = size × reps；reps 由 min-work 目标定（默认 16 MiB，
 *     可用第 4 个参数覆盖），保证每个 pass 计时够长（小缓冲靠 reps 补足）。
 *   · **rmw 的 MB/s 按"足迹"算**（size×reps）。它实际产生的 DDR 流量是这个数的
 *     **2×**（每元素一次读 + 一次写）；要按"总线流量"比较时须乘 2。此处统一按
 *     足迹口径，是为了让三个位宽之间可比（位宽扫描的判别只需要可比）。
 *   · 预热 pass 丢弃；取 N 个 pass 里**最好**（时间最短）的一次；N 默认 3，可参数覆盖。
 *   · 大缓冲默认 64 MiB（为了打死 cache）；分配不到就**响亮失败**（ALLOC/FATAL 行），
 *     并报告**实际拿到的** size。
 *
 * 用法
 *   ddr_bw_test [size_bytes] [n_passes] [small_bytes] [minwork_bytes]
 *     默认 size = 67108864（64 MiB）、n = 3、small = 32768、minwork = 16777216。
 *     small = 0 ⇒ 跳过缓存负对照（此时 P1 不参与，直接按位宽扫描判）。
 *   例  ./ddr_bw_test                     # 64 MiB + 32 KiB 负对照，N=3
 *       ./ddr_bw_test 33554432 5          # 32 MiB，N=5
 *       ./ddr_bw_test 67108864 3 8192     # 负对照用小缓冲 8 KiB
 *       ./ddr_bw_test 4194304 1 32768 4194304   # 快速探针：每 pass 只搬 4 MiB
 * =============================================================================
 */
#define _POSIX_C_SOURCE 199309L

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

/* 结果回写点：让 volatile 读循环的累加值有可观测归宿（防被优化掉） */
static volatile uint32_t g_sink;

static double now_s(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        perror("clock_gettime");
        exit(4);
    }
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

/* ---------------------------------------------------------------------------
 * 一次 pass：把 size 字节的缓冲整整走 reps 遍。
 * mode: 0=read  1=write  2=rmw(read-modify-write)
 * 用 volatile 指针 ⇒ 每个元素都是**真的一次访存**，不会被优化掉。
 * ------------------------------------------------------------------------- */
static double run_pass(int width, int mode, void *buf, size_t size, long reps)
{
    double t0, t1;
    long r;
    size_t i;

    t0 = now_s();
    if (width == 8) {
        volatile uint8_t *p = (volatile uint8_t *)buf;
        uint32_t acc = 0;
        if (mode == 0) {
            for (r = 0; r < reps; r++)
                for (i = 0; i < size; i++) acc += p[i];
        } else if (mode == 1) {
            for (r = 0; r < reps; r++)
                for (i = 0; i < size; i++) p[i] = (uint8_t)0x5Au;
        } else {
            for (r = 0; r < reps; r++)
                for (i = 0; i < size; i++) p[i] = (uint8_t)(p[i] + 1u);
        }
        g_sink = acc;
    } else if (width == 16) {
        volatile uint16_t *p = (volatile uint16_t *)buf;
        size_t n = size / 2;
        uint32_t acc = 0;
        if (mode == 0) {
            for (r = 0; r < reps; r++)
                for (i = 0; i < n; i++) acc += p[i];
        } else if (mode == 1) {
            for (r = 0; r < reps; r++)
                for (i = 0; i < n; i++) p[i] = (uint16_t)0x5A5Au;
        } else {
            for (r = 0; r < reps; r++)
                for (i = 0; i < n; i++) p[i] = (uint16_t)(p[i] + 1u);
        }
        g_sink = acc;
    } else {
        volatile uint32_t *p = (volatile uint32_t *)buf;
        size_t n = size / 4;
        uint32_t acc = 0;
        if (mode == 0) {
            for (r = 0; r < reps; r++)
                for (i = 0; i < n; i++) acc += p[i];
        } else if (mode == 1) {
            for (r = 0; r < reps; r++)
                for (i = 0; i < n; i++) p[i] = 0x5A5A5A5Au;
        } else {
            for (r = 0; r < reps; r++)
                for (i = 0; i < n; i++) p[i] = p[i] + 1u;
        }
        g_sink = acc;
    }
    t1 = now_s();
    return t1 - t0;
}

/* 一个 (width, mode) 的 MB/s：预热 1 遍丢弃，取 n 遍里最好的一次。 */
static double measure(int width, int mode, void *buf, size_t size,
                      size_t minwork, int npass)
{
    long reps = (long)((minwork + size - 1) / size);
    double best = 0.0;
    double bytes;
    int k;

    if (reps < 1) reps = 1;
    bytes = (double)size * (double)reps;

    (void)run_pass(width, mode, buf, size, reps);      /* 预热，丢弃 */
    for (k = 0; k < npass; k++) {
        double dt = run_pass(width, mode, buf, size, reps);
        double mbs;
        if (dt <= 0.0) continue;
        mbs = bytes / dt / 1e6;
        if (mbs > best) best = mbs;
    }
    return best;
}

/* 真实触页：malloc 可能只给了 overcommit 的地址空间，逐页写一次强制落实物理页 */
static void touch_pages(void *p, size_t n)
{
    volatile unsigned char *q = (volatile unsigned char *)p;
    size_t i;
    for (i = 0; i + 4096 <= n; i += 4096) q[i] = 1;
    if (n > 0) q[n - 1] = 1;
}

/* 分配；不够就减半重试并**响亮**打印；连 4 KiB 都拿不到就 FATAL。
 * 注意：小缓冲可能是 32 KiB 这种，**不能**拿 1 MiB 当地板（踩过：直接 FATAL 退出，
 * 整个测量一行都没跑，只留下 3 行 ALLOC 头）。 */
static void *alloc_buf(size_t want, size_t *got)
{
    size_t s = want;
    void *p;

    while (s >= (size_t)4096u) {
        p = malloc(s);
        if (p != NULL) {
            *got = s;
            if (s != want)
                printf("WARN alloc_degraded want=%lu got=%lu\n",
                       (unsigned long)want, (unsigned long)s);
            touch_pages(p, s);
            return p;
        }
        printf("WARN malloc_failed size=%lu next_try=%lu\n",
               (unsigned long)s, (unsigned long)(s / 2));
        s /= 2;
    }
    printf("FATAL cannot_allocate_min_4KiB want=%lu\n", (unsigned long)want);
    exit(3);
}

int main(int argc, char **argv)
{
    size_t want = 64u * 1024u * 1024u;
    int npass = 3;
    size_t small = 32768u;
    size_t minwork = 16u * 1024u * 1024u;
    static const int   widths[3] = { 8, 16, 32 };
    static const char *mnames[3] = { "read", "write", "rmw" };
    void *big = NULL, *sm = NULL;
    size_t bigsz = 0, smsz = 0;
    double big_mbs[3][3], sm_mbs[3][3];
    double sratio[3];
    int scaling_modes = 0, all_flat = 1, cache_fail = 0;
    int cache_ok, i, j;
    double ref, r;

    /* 逐行吐：板上跑得慢，行缓冲才能在 /tmp 的文件里看到"卡在哪一格" */
    setvbuf(stdout, NULL, _IOLBF, 4096);

    if (argc > 1) want    = (size_t)strtoul(argv[1], NULL, 10);
    if (argc > 2) npass   = (int)strtol(argv[2], NULL, 10);
    if (argc > 3) small   = (size_t)strtoul(argv[3], NULL, 10);
    if (argc > 4) minwork = (size_t)strtoul(argv[4], NULL, 10);
    if (want < 4096u) want = 64u * 1024u * 1024u;
    if (npass < 1) npass = 3;
    if (minwork < 4096u) minwork = 16u * 1024u * 1024u;

    printf("CFG size_req=%lu n=%d small_req=%lu minwork=%lu\n",
           (unsigned long)want, npass, (unsigned long)small,
           (unsigned long)minwork);

    big = alloc_buf(want, &bigsz);
    printf("ALLOC which=big want=%lu got=%lu\n",
           (unsigned long)want, (unsigned long)bigsz);
    if (bigsz < 4u * 1024u * 1024u)
        printf("WARN big_buffer_too_small size=%lu cache_not_defeated_maybe\n",
               (unsigned long)bigsz);

    if (small > 0) {
        sm = alloc_buf(small, &smsz);
        printf("ALLOC which=small want=%lu got=%lu\n",
               (unsigned long)small, (unsigned long)smsz);
    } else {
        printf("ALLOC which=small skipped\n");
    }

    /* ---- 主扫描：大缓冲（每 4 MiB 以上就真在 DRAM 里） ---- */
    for (i = 0; i < 3; i++)
        for (j = 0; j < 3; j++) {
            printf("PROG which=big width=%d mode=%s\n", widths[i], mnames[j]);
            big_mbs[i][j] = measure(widths[i], j, big, bigsz, minwork, npass);
            printf("BW width=%d mode=%s MBs=%.1f size=%lu n=%d\n",
                   widths[i], mnames[j], big_mbs[i][j],
                   (unsigned long)bigsz, npass);
        }

    /* ---- 缓存负对照：小缓冲（默认 32 KiB，装得进 cache） ---- */
    if (sm != NULL) {
        for (i = 0; i < 3; i++)
            for (j = 0; j < 3; j++) {
                printf("PROG which=small width=%d mode=%s\n", widths[i], mnames[j]);
                sm_mbs[i][j] = measure(widths[i], j, sm, smsz, minwork, npass);
                printf("BW width=%d mode=%s MBs=%.1f size=%lu n=%d\n",
                       widths[i], mnames[j], sm_mbs[i][j],
                       (unsigned long)smsz, npass);
            }
    } else {
        for (i = 0; i < 3; i++)
            for (j = 0; j < 3; j++) sm_mbs[i][j] = 0.0;
    }

    /* ---- 位宽扫描判据（CPU 受限 vs 内存受限） ---- */
    for (j = 0; j < 3; j++) {
        sratio[j] = (big_mbs[0][j] > 0.0) ? big_mbs[2][j] / big_mbs[0][j] : 0.0;
        printf("SCALING mode=%s r8=%.1f r16=%.1f r32=%.1f r32_over_r8=%.2f r16_over_r8=%.2f\n",
               mnames[j], big_mbs[0][j], big_mbs[1][j], big_mbs[2][j], sratio[j],
               (big_mbs[0][j] > 0.0) ? big_mbs[1][j] / big_mbs[0][j] : 0.0);
        if (sratio[j] >= 1.80) scaling_modes++;
        if (sratio[j] > 1.40)  all_flat = 0;
    }

    /* ---- 缓存负对照判据（只看 32 位那一行：DRAM 效应在那里最显） ---- */
    if (sm != NULL) {
        for (i = 0; i < 3; i++)
            for (j = 0; j < 3; j++) {
                double ratio = (big_mbs[i][j] > 0.0)
                             ? sm_mbs[i][j] / big_mbs[i][j] : 0.0;
                printf("CACHECTRL width=%d mode=%s big=%.1f small=%.1f ratio=%.2f ok=%d\n",
                       widths[i], mnames[j], big_mbs[i][j], sm_mbs[i][j],
                       ratio, ratio >= 1.50 ? 1 : 0);
                if (i == 2 && ratio < 1.50) cache_fail = 1;
            }
    }
    cache_ok = (sm != NULL) ? (cache_fail ? 0 : 1) : 1;
    printf("CACHECTRL_RESULT ok=%d threshold=1.50 scope=width32\n", cache_ok);

    /* ---- 取"可达值"代表：u32 read / u32 write 里较大者 ---- */
    ref = big_mbs[2][0] > big_mbs[2][1] ? big_mbs[2][0] : big_mbs[2][1];
    printf("VERDICT cache_ok=%d scaling_modes=%d all_flat=%d ref_mbs=%.1f"
           " need_10fps=305.0 need_15fps=458.0 meets305=%d meets458=%d\n",
           cache_ok, scaling_modes, all_flat, ref,
           ref >= 305.0 ? 1 : 0, ref >= 458.0 ? 1 : 0);
    printf("SINK v=%lu\n", (unsigned long)g_sink);

    /* ---- 判定（优先级见文件头） ---- */
    if (!cache_ok && scaling_modes == 0) {
        printf("RESULT: MEASUREMENT_INVALID_CACHE_CONTROL_FAILED\n");
    } else if (all_flat) {
        if (ref >= 458.0)      printf("RESULT: MEMORY_BOUND_MEETS_458\n");
        else if (ref >= 305.0) printf("RESULT: MEMORY_BOUND_MEETS_305\n");
        else                   printf("RESULT: MEMORY_BOUND_BELOW_305\n");
    } else {
        printf("RESULT: INSN_BOUND_DDR_CEILING_UNKNOWN\n");
    }

    r = 0.0; (void)r;
    free(big);
    free(sm);
    return 0;
}
