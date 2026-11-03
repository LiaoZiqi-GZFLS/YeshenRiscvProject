// ============================================================================
// npurun_t.c —— 板内**单进程** NPU 帧计时器（mmap /dev/mem；start→done 精确墙钟）
//
// 为什么需要：npurun 的驱动（y1/tools/npu_frame_run.py）走 UART `devmem` 轮询 STATUS，
//   单次轮询 ~1.5 s（10 ms/字符 发命令 + 1.2 s drain）——**分辨不出**百毫秒级的帧。
//   本工具把"写 start → 忙等 STATUS(done|err)"收进**一个进程**：
//     · 寄存器经 mmap 直读（单次 load，无 fork/exec/串口）；
//     · CLOCK_MONOTONIC 纳秒计时 ⇒ µs 级分辨。
//   它**不搬数据**：前提 = DDR 里的 input/desc/blob/信箱已由驱动就位、NPU 处于 IDLE。
//
// 用法（板内）：
//   npurun_t [desc_addr] [desc_count] [frames]      # 十六进制可带 0x 前缀
//   缺省：0x00100000 / 67 / 1
// 每帧：CTRL.soft_reset(=2) → DESC_ADDR → DESC_COUNT → CTRL.start(=1) → 忙等 STATUS
//   粘滞位语义（HostRegs.scala）：STATUS.bit0=done（写 1 清）、bit1=err（soft_reset 清）。
// 输出（stdout，一行一帧）：
//   RUN i ns=<Δns> status=0x........ done=<0|1> err=<0|1>
// 汇总：RUNS=n OK=n ERR=n TIMEOUT=n ；退出码 0=全 done / 1=有 err / 3=超时。
// 编译见 build_npurun_t.sh（与本目录 ddmem.c 同一工具链、同一 -static 口径）。
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

#define REG_BASE 0xF000C000UL
#define R_CTRL   0x00
#define R_STATUS 0x04

#define CTRL_START      0x1u
#define CTRL_SOFT_RESET 0x2u

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

int main(int argc, char **argv) {
    unsigned long desc_addr  = 0x00100000UL;
    unsigned long desc_count = 67;
    int frames = 1;
    if (argc > 1) desc_addr  = strtoul(argv[1], NULL, 0);
    if (argc > 2) desc_count = strtoul(argv[2], NULL, 0);
    if (argc > 3) frames     = atoi(argv[3]);
    if (frames < 1 || frames > 1000) { fprintf(stderr, "frames out of range\n"); return 2; }

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 3; }
    long page = sysconf(_SC_PAGESIZE);
    unsigned long base = REG_BASE & ~((unsigned long)page - 1);
    unsigned long off  = REG_BASE - base;
    volatile uint32_t *reg = mmap(NULL, (size_t)page, PROT_READ | PROT_WRITE,
                                  MAP_SHARED, fd, (off_t)base);
    if (reg == MAP_FAILED) { perror("mmap"); close(fd); return 3; }
    volatile uint32_t *ctrl   = (volatile uint32_t *)((char *)reg + off + R_CTRL);
    volatile uint32_t *status = (volatile uint32_t *)((char *)reg + off + R_STATUS);

    int nok = 0, nerr = 0, nto = 0;
    for (int i = 0; i < frames; i++) {
        // 清 done 粘滞位（w1c）+ 清 errSticky（soft_reset）；然后定案表参数。
        *status = 0x1u;
        *ctrl   = CTRL_SOFT_RESET;
        *((volatile uint32_t *)((char *)reg + off + 0x34)) = (uint32_t)desc_addr;   // DESC_ADDR
        *((volatile uint32_t *)((char *)reg + off + 0x38)) = (uint32_t)desc_count;  // DESC_COUNT
        __sync_synchronize();
        uint64_t t0 = now_ns();
        *ctrl = CTRL_START;
        uint32_t st = 0;
        uint64_t t1 = t0;
        for (;;) {
            st = *status;
            if ((st & 0x3u) != 0u) { t1 = now_ns(); break; }
            if (now_ns() - t0 > 30000000000ull) { t1 = now_ns(); break; }   // 30 s spin 上界
        }
        printf("RUN %d ns=%llu status=0x%08x done=%u err=%u\n", i,
               (unsigned long long)(t1 - t0), st, st & 1u, (st >> 1) & 1u);
        fflush(stdout);
        if ((st & 0x3u) == 0u) nto++;
        else if (st & 0x2u)    nerr++;
        else                   nok++;
    }
    printf("RUNS=%d OK=%d ERR=%d TIMEOUT=%d\n", frames, nok, nerr, nto);
    munmap((void *)reg, (size_t)page);
    close(fd);
    if (nto) return 3;
    if (nerr) return 1;
    return 0;
}
