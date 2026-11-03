// ============================================================================
// y1run.c —— 板内**纯 C** YuNet 整帧 runner（payload → 起跑 → 逐字节判据）
//
// 数据来源：TF 卡第 5 槽 payload（SdLoader 上电装到物理 0x81E00000；格式见
//   y1/tools/build_board_payload.py）。payload 自带 input/desc/权重信箱映像/7346 条信箱
//   记录/12 路输出计划 + 逐字节黄金；本程序启动先用 CRC32 校验每个段，再使用。
//
// 为什么纯 C：主机 Python 驱动的传输/回读是分钟级（ssh 2.8 s/会话、tftp 8 KB 子块），
//   而一帧只有 6.5 s；把"投递 + 起跑 + 回读 + 比对"全放进板内一个静态进程后，测试循环
//   只剩帧时间本身（+ <1 s 的 memcpy/校验）。
//
// 用法（板内）：
//   y1run [--frames N] [--payload PHYS] [--no-golden] [--skip-copy] [--quiet]
//   缺省：frames=1, payload=0x81E00000, 有黄金就比对。
//
// 判据（全部必须过）：
//   1) payload magic/version/长度合法，5 个段的 CRC32 与 header 相等；
//   2) input/desc/权重信箱映像 memcpy 到 arena 后，**就地回读 CRC32** 与主机侧相等；
//   3) 帧 done=1 且 err=0（30 s 超时）；
//   4) 12 路输出（按 payload 输出表）CRC32 与黄金相等；有 golden 段时再做 memcmp。
// 输出一行判词：`Y1RUN: PASS frames=.. outputs=12/12 ns=..` 或 `Y1RUN: FAIL <reason>`。
//
// 编译：见 build_y1run.sh（riscv32 static，与 ddmem/npurun_t 同一工具链）。
// ============================================================================
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "y1_common.h"        /* 地址/寄存器/payload 头/CRC/时钟/mmap（Task 9 抽出） */

static volatile int g_quiet = 0;
#define SAY(...) do { if (!g_quiet) printf(__VA_ARGS__); } while (0)

static int fail(const char *why) {
    printf("Y1RUN: FAIL %s\n", why);
    fflush(stdout);
    return 1;
}

int main(int argc, char **argv) {
    int frames = 1, no_golden = 0, skip_copy = 0, reset_delay_us = 10000, poison = 0, unit_trace = 0;
    unsigned long payload_phys = PAYLOAD_BASE_DEF;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--frames") && i + 1 < argc) frames = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--payload") && i + 1 < argc) payload_phys = strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--no-golden")) no_golden = 1;
        else if (!strcmp(argv[i], "--skip-copy")) skip_copy = 1;
        else if (!strcmp(argv[i], "--reset-delay-us") && i + 1 < argc) reset_delay_us = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--poison")) poison = 1;
        else if (!strcmp(argv[i], "--unit-trace")) unit_trace = 1;
        else if (!strcmp(argv[i], "--quiet")) g_quiet = 1;
        else { fprintf(stderr, "usage: y1run [--frames N] [--payload PHYS] [--no-golden] [--skip-copy] [--reset-delay-us N] [--unit-trace] [--quiet]\n"); return 2; }
    }
    if (frames < 1 || frames > 1000) return 2;
    if (payload_phys & 0x3F) return fail("payload 地址未 64B 对齐");

    crc_init();
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("!! y1run: open(/dev/mem)"); return 3; }

    uint8_t *pl = (uint8_t *)map_phys(fd, payload_phys, PAYLOAD_MAX, "payload");
    uint8_t *arena = (uint8_t *)map_phys(fd, ARENA_BASE, ARENA_SIZE, "arena");
    uint8_t *reg = (uint8_t *)map_phys(fd, REG_BASE, PAGE, "regs");
    if (!pl || !arena || !reg) return 3;

    struct hdr *h = (struct hdr *)pl;
    if (memcmp(h->magic, "Y1PL", 4) != 0) return fail("payload magic != Y1PL（卡没写/第 5 槽没装）");
    if (h->version != 1) return fail("payload version != 1");
    if (h->total < HDR_SIZE || h->total > PAYLOAD_MAX) return fail("payload total_size 越界");
    if (h->desc_count == 0 || h->desc_count > 4096) return fail("desc_count 越界");
    if (h->n_out == 0 || h->n_out > MAX_OUT) return fail("n_outputs 越界");
    if (HDR_SIZE < 160u + 32u * h->n_out) return fail("输出表越过 header");
    if (h->n_mb == 0 || h->n_mb > 1000000) return fail("n_mb_records 越界");
    for (int i = 0; i < NSEG; i++) {
        if (h->seg[i].len && (uint64_t)h->seg[i].off + h->seg[i].len > h->total)
            return fail("段表越界");
    }

    /* ---- 1) payload 段 CRC ---- */
    static const char *sname[NSEG] = {"desc", "wgt_mailbox", "input_int8", "mb_records", "golden_raw", "rsv"};
    for (int i = 0; i < 5; i++) {
        uint32_t c = h->seg[i].len ? crc32_buf(pl + h->seg[i].off, h->seg[i].len) : 0;
        if (c != h->seg[i].crc) {
            printf("!! seg %s crc=%08x != %08x\n", sname[i], c, h->seg[i].crc);
            return fail("payload 段 CRC 不符");
        }
        SAY("  payload %-12s len=%7u crc=%08x OK\n", sname[i], h->seg[i].len, c);
    }

    /* ---- 2) 投递到 arena（input/desc/权重信箱映像）并就地回读 CRC ---- */
    if (!skip_copy) {
        const struct { int id; uint32_t dst_npu; uint32_t len; } cp[] = {
            {SEG_INPUT, h->input_npu, h->input_bytes},
            {SEG_DESC,  h->desc_npu,  h->seg[SEG_DESC].len},
            {SEG_WGT,   h->mbx_npu,   h->mbx_bytes},
        };
        for (unsigned k = 0; k < sizeof(cp) / sizeof(cp[0]); k++) {
            if (!cp[k].len) continue;
            memcpy(arena + cp[k].dst_npu, pl + h->seg[cp[k].id].off, cp[k].len);
            __sync_synchronize();
            uint32_t c = crc32_buf(arena + cp[k].dst_npu, cp[k].len);
            if (c != h->seg[cp[k].id].crc) {
                printf("!! copy %s dst=0x%08x crc=%08x != %08x\n",
                       sname[cp[k].id], cp[k].dst_npu, c, h->seg[cp[k].id].crc);
                return fail("arena 回读 CRC 不符");
            }
            SAY("  copy %-12s -> npu=0x%08x len=%7u crc=%08x OK\n",
                sname[cp[k].id], cp[k].dst_npu, cp[k].len, c);
        }
    }

    /* ---- 3) 回放 7346 条信箱记录（addr/data/we） ---- */
    volatile uint32_t *ra = (volatile uint32_t *)(reg + R_WGT_A);
    volatile uint32_t *rd = (volatile uint32_t *)(reg + R_WGT_D);
    volatile uint32_t *rw = (volatile uint32_t *)(reg + R_WGT_WE);
    volatile uint32_t *ctrl = (volatile uint32_t *)(reg + R_CTRL);
    volatile uint32_t *status = (volatile uint32_t *)(reg + R_STATUS);
    volatile uint32_t *desc_a = (volatile uint32_t *)(reg + R_DESC_A);
    volatile uint32_t *desc_n = (volatile uint32_t *)(reg + R_DESC_N);

    const uint8_t *mbr = pl + h->seg[SEG_MB].off;
    if (!skip_copy) {
        uint64_t t0 = now_ns();
        for (uint32_t i = 0; i < h->n_mb; i++) {
            uint32_t a, d;
            memcpy(&a, mbr + 8u * i, 4);
            memcpy(&d, mbr + 8u * i + 4, 4);
            *ra = a; *rd = d; __sync_synchronize(); *rw = 1u; __sync_synchronize();
        }
        __sync_synchronize();
        SAY("  mailbox %u records programmed (%llu ns)\n", h->n_mb,
            (unsigned long long)(now_ns() - t0));
    }

    /* ---- 4) 逐帧：清 → 参数 → start → poll → 输出比对 ---- */
    const uint8_t *gold = h->seg[SEG_GOLDEN].len ? pl + h->seg[SEG_GOLDEN].off : NULL;
    int nok = 0, nfail = 0;
    for (int f = 0; f < frames; f++) {
        *status = 0x1u;
        *ctrl = CTRL_SOFT_RESET;
        if (reset_delay_us > 0) usleep(reset_delay_us);
        *desc_a = h->desc_npu;
        *desc_n = h->desc_count;
        if (poison) {
            for (uint32_t i = 0; i < h->n_out; i++)
                memset(arena + h->out[i].npu, 0x5A, h->out[i].bytes);
            __sync_synchronize();
        }
        __sync_synchronize();
        uint64_t t0 = now_ns();
        *ctrl = CTRL_START;
        uint32_t st = 0;
        uint64_t t1 = t0;
        uint32_t last_ui = 0;
        for (;;) {
            st = *status;
            if (unit_trace) {                     /* ★ STATUS[31:8] = 已完成单元数（只读遥测） */
                uint32_t ui = st >> 8;
                if (ui != last_ui) {
                    uint64_t tn = now_ns();
                    printf("U %u %llu\n", ui, (unsigned long long)(tn - t0));
                    last_ui = ui;
                }
            }
            if ((st & 0x3u) != 0u) { t1 = now_ns(); break; }
            if (now_ns() - t0 > 30000000000ull) { t1 = now_ns(); break; }
        }
        if ((st & 0x3u) == 0u) { printf("Y1RUN: FAIL frame timeout status=0x%08x\n", st); return 5; }
        if (st & 0x2u) { printf("Y1RUN: FAIL npu err status=0x%08x\n", st); return 5; }

        int bad = 0;
        uint32_t goff = 0;
        for (uint32_t i = 0; i < h->n_out; i++) {
            const struct out *o = &h->out[i];
            const uint8_t *dst = arena + o->npu;
            uint32_t c = crc32_buf(dst, o->bytes);
            int ok = (c == o->crc);
            if (ok && gold && !no_golden) {
                if (goff + o->bytes > h->golden_bytes) ok = 0;
                else ok = (memcmp(dst, gold + goff, o->bytes) == 0);
            }
            if (!ok) {
                bad++;
                printf("  OUT %-8s npu=0x%08x len=%u crc=%08x want=%08x %s\n",
                       o->name, o->npu, o->bytes, c, o->crc,
                       (gold && !no_golden) ? "MEMCMP/CRC FAIL" : "CRC FAIL");
            } else {
                SAY("  OUT %-8s npu=0x%08x len=%u crc=%08x OK\n", o->name, o->npu, o->bytes, c);
            }
            goff += o->bytes;
        }
        printf("RUN %d ns=%llu status=0x%08x outputs=%u/%u\n", f,
               (unsigned long long)(t1 - t0), st, h->n_out - bad, h->n_out);
        fflush(stdout);
        if (bad) nfail++; else nok++;
    }

    printf("Y1RUN: %s frames=%d pass=%d fail=%d\n", nfail ? "FAIL" : "PASS", frames, nok, nfail);
    fflush(stdout);
    munmap(pl, PAYLOAD_MAX);
    munmap(arena, ARENA_SIZE);
    munmap(reg, PAGE);
    close(fd);
    return nfail ? 1 : 0;
}
