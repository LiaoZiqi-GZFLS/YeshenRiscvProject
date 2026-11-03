/*
 * wakejitter —— 板端唤醒/定时精度探针（K1/K2 内核对照实验的判据）
 *
 * 用法：
 *   ./wakejitter [n] [period_us]     每次 clock_nanosleep(period) 后测实际间隔
 *   ./wakejitter --drift [secs]      测 CLOCK_MONOTONIC/REALTIME 与主机秒表的一致性
 *
 * 输出（前一种）：
 *   res_ns / overshoot 的 min,p50,p90,p99,max / 均值 / 超 500us 次数 / 总墙钟
 * 判据：HZ_PERIODIC+!hrtimer 下 overshoot 的上界 ≈ 一个 tick（4 ms，HZ=250）；
 *       hrtimers 生效后应降到几十~几百 µs 量级。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdint.h>

static int cmp_d(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static double ts_diff_us(const struct timespec *a, const struct timespec *b) {
    return (double)(b->tv_sec - a->tv_sec) * 1e6 + (double)(b->tv_nsec - a->tv_nsec) / 1e3;
}

static int do_drift(int secs) {
    struct timespec m0, m1, r0, r1, req;
    req.tv_sec = secs; req.tv_nsec = 0;
    clock_gettime(CLOCK_MONOTONIC, &m0);
    clock_gettime(CLOCK_REALTIME,  &r0);
    clock_nanosleep(CLOCK_MONOTONIC, 0, &req, NULL);
    clock_gettime(CLOCK_MONOTONIC, &m1);
    clock_gettime(CLOCK_REALTIME,  &r1);
    printf("drift: mono=%.6f s  real=%.6f s  (host stopwatch 应与之相符)\n",
           ts_diff_us(&m0, &m1) / 1e6, ts_diff_us(&r0, &r1) / 1e6);
    return 0;
}

int main(int argc, char **argv) {
    struct timespec res;
    clock_getres(CLOCK_MONOTONIC, &res);
    printf("clock_getres(CLOCK_MONOTONIC) = %ld ns\n", (long)res.tv_nsec);

    if (argc > 1 && strcmp(argv[1], "--drift") == 0)
        return do_drift(argc > 2 ? atoi(argv[2]) : 10);

    long n = argc > 1 ? atol(argv[1]) : 2000;
    long period_us = argc > 2 ? atol(argv[2]) : 1000;
    if (n <= 0 || n > 200000) { fprintf(stderr, "bad n\n"); return 2; }

    double *os = malloc(sizeof(double) * n);
    if (!os) { fprintf(stderr, "oom\n"); return 2; }
    struct timespec req = { period_us / 1000000, (period_us % 1000000) * 1000 };

    /* 预热 100 次，避免首轮缺页/首次进入 hrtimer 的异常值污染统计 */
    struct timespec a, b;
    for (int i = 0; i < 100; i++) {
        clock_gettime(CLOCK_MONOTONIC, &a);
        clock_nanosleep(CLOCK_MONOTONIC, 0, &req, NULL);
        clock_gettime(CLOCK_MONOTONIC, &b);
    }

    struct timespec t0, t1;
    long over500 = 0;
    double sum = 0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (long i = 0; i < n; i++) {
        clock_gettime(CLOCK_MONOTONIC, &a);
        clock_nanosleep(CLOCK_MONOTONIC, 0, &req, NULL);
        clock_gettime(CLOCK_MONOTONIC, &b);
        double d = ts_diff_us(&a, &b) - (double)period_us;
        if (d < 0) d = 0;
        os[i] = d; sum += d;
        if (d > 500.0) over500++;
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    qsort(os, n, sizeof(double), cmp_d);
    printf("n=%ld period=%ldus  overshoot_us: min=%.1f p50=%.1f p90=%.1f p99=%.1f max=%.1f mean=%.1f  >500us=%ld  wall=%.3fs\n",
           n, period_us, os[0], os[n / 2], os[(long)(n * 0.90)], os[(long)(n * 0.99)],
           os[n - 1], sum / (double)n, over500, ts_diff_us(&t0, &t1) / 1e6);
    free(os);
    return 0;
}
