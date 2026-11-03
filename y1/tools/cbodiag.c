/* cbodiag.c —— CBO 语义探针（上板用，人看输出）
 *   A) cbo.inval 必须 SIGILL（menvcfg/senvcfg.CBIE=0）——验证 CBO 解码+CSR 门控真的生效
 *   B) 4 KB（< D$16K）缓冲填 P1 → cbo.clean 逐行 → /dev/mem 读回，统计等于 P1 的字节数
 *   C) 同缓冲重填 P1 → cbo.flush 逐行 → 同上
 */
#define _GNU_SOURCE
#define _DEFAULT_SOURCE 1
#include <fcntl.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define PAGE 4096UL
#define LEN  PAGE
static sigjmp_buf jb;
static void on_ill(int s) { (void)s; siglongjmp(jb, 1); }

static void fill(uint8_t *b, size_t n, uint32_t seed)
{
    uint32_t x = seed ? seed : 1;
    for (size_t i = 0; i < n; i++) {
        x ^= x << 13; x ^= x >> 17; x ^= x << 5;
        b[i] = (uint8_t)(x ^ (uint32_t)(i * 7));
    }
}

static unsigned long long pa_of(void *p)
{
    int fd = open("/proc/self/pagemap", O_RDONLY);
    if (fd < 0) return 0;
    off_t off = ((unsigned long)p / PAGE) * 8;
    uint64_t e = 0;
    if (pread(fd, &e, 8, off) != 8 || !(e & (1ULL << 63))) { close(fd); return 0; }
    close(fd);
    return (e & ((1ULL << 55) - 1)) * PAGE + ((unsigned long)p % PAGE);
}

int main(void)
{
    uint8_t *buf = NULL;
    if (posix_memalign((void **)&buf, PAGE, LEN) != 0 || !buf) { printf("FAIL alloc\n"); return 2; }
    memset(buf, 0, LEN);
    unsigned long long pa = pa_of(buf);
    if (!pa) { printf("FAIL pagemap(need root)\n"); return 2; }
    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) { printf("FAIL /dev/mem\n"); return 2; }
    uint8_t *hw = mmap(NULL, LEN, PROT_READ, MAP_SHARED, fd, (off_t)pa);
    if (hw == MAP_FAILED) { printf("FAIL mmap\n"); return 2; }

    signal(SIGILL, on_ill);

    /* A) cbo.inval 应该 SIGILL（CBIE=0） */
    int inval_trapped = 0;
    if (sigsetjmp(jb, 1) == 0) {
        __asm__ volatile("cbo.inval (%0)" :: "r"(buf) : "memory");
    } else inval_trapped = 1;
    printf("A) cbo.inval trapped=%d (exp 1)\n", inval_trapped);

    /* B) clean */
    fill(buf, LEN, 0x11112222u);
    for (size_t o = 0; o < LEN; o += 64)
        __asm__ volatile("cbo.clean (%0)" :: "r"(buf + o) : "memory");
    __sync_synchronize();
    int eq = 0;
    for (size_t i = 0; i < LEN; i++) if (hw[i] == buf[i]) eq++;
    printf("B) clean: hw==buf %d/%lu\n", eq, (unsigned long)LEN);

    /* C) flush */
    fill(buf, LEN, 0x33334444u);
    for (size_t o = 0; o < LEN; o += 64)
        __asm__ volatile("cbo.flush (%0)" :: "r"(buf + o) : "memory");
    __sync_synchronize();
    eq = 0;
    for (size_t i = 0; i < LEN; i++) if (hw[i] == buf[i]) eq++;
    printf("C) flush: hw==buf %d/%lu\n", eq, (unsigned long)LEN);
    printf("   hw[0..7]=%02x%02x%02x%02x%02x%02x%02x%02x\n",
           hw[0], hw[1], hw[2], hw[3], hw[4], hw[5], hw[6], hw[7]);
    printf("   buf[0..7]=%02x%02x%02x%02x%02x%02x%02x%02x\n",
           buf[0], buf[1], buf[2], buf[3], buf[4], buf[5], buf[6], buf[7]);
    munmap(hw, LEN); close(fd); free(buf);

    /* E) 4 KB，**完全不 flush**：写直达的话 DDR 也应是 P1 */
    {
        uint8_t *b3 = NULL;
        if (posix_memalign((void **)&b3, PAGE, LEN) == 0 && b3) {
            memset(b3, 0, LEN);
            unsigned long long pa3 = pa_of(b3);
            int fd3 = open("/dev/mem", O_RDONLY | O_SYNC);
            uint8_t *h3 = mmap(NULL, LEN, PROT_READ, MAP_SHARED, fd3, (off_t)pa3);
            fill(b3, LEN, 0x77778888u);
            __sync_synchronize();
            int eq = 0;
            for (size_t i = 0; i < LEN; i++) if (h3[i] == b3[i]) eq++;
            printf("E) no-flush 4KB: hw==buf %d/%lu (write-through => 4096)\n", eq, (unsigned long)LEN);
        }
    }

    /* D) 32 KB（> D$16K）：按 4 KB 分块统计，看哪一半出错 */
    {
        const size_t L2 = 8 * PAGE;
        uint8_t *b2 = NULL;
        if (posix_memalign((void **)&b2, PAGE, L2) != 0 || !b2) { printf("D) FAIL alloc\n"); return 2; }
        memset(b2, 0, L2);
        unsigned long long pa2 = pa_of(b2);
        if (!pa2) { printf("D) FAIL pagemap\n"); return 2; }
        int fd2 = open("/dev/mem", O_RDONLY | O_SYNC);
        uint8_t *h2 = mmap(NULL, L2, PROT_READ, MAP_SHARED, fd2, (off_t)pa2);
        if (h2 == MAP_FAILED) { printf("D) FAIL mmap\n"); return 2; }

        fill(b2, L2, 0x55556666u);
        for (size_t o = 0; o < L2; o += 64)
            __asm__ volatile("cbo.flush (%0)" :: "r"(b2 + o) : "memory");
        __sync_synchronize();
        for (int c = 0; c < 8; c++) {
            int eq = 0;
            for (size_t i = c * PAGE; i < (size_t)(c + 1) * PAGE; i++)
                if (h2[i] == b2[i]) eq++;
            printf("D) chunk%d (%luKB..%luKB): %d/%lu\n", c,
                   (unsigned long)c * 4, (unsigned long)(c + 1) * 4, eq, (unsigned long)PAGE);
        }
        printf("D) PA=0x%llx\n", pa2);
    }
    return 0;
}