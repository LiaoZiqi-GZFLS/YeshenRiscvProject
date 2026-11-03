/* cbotest -- GPU P0 判据（上板自检；判据在本文件里独立成立）
 *
 * 板上实测（2026-10-31）：本核 L1 D$ 是**写直达**——CPU 普通写不 flush 也已落在 DDR。
 * 因此 P0 的正确判据不是"不 flush 就该不一致"，而是这三条：
 *   ① POS  ：32 KB 缓冲 CPU 写(逐行 cbo.flush)后，逐**页**取 PA 读 DDR == 写入值
 *             （验证 store→DDR 可见性 + flush 不破坏数据；逐页取 PA 是因为
 *              posix_memalign 只保证虚拟连续，物理页不一定连续）
 *   ② GATE ：cbo.inval 必须 SIGILL（menvcfg/senvcfg.CBIE=0）——证明 CBO 解码 +
 *             特权门控链真的生效（放行位只放 CBCFE，没放 CBIE）
 *   ③ NEG  ：判据自证——读 **buf 的物理页**、比"改坏一个字节的期望值"，
 *             同一条比对路径必须报不一致且落在第 0 页。
 *             ⚠️ 不能拿改坏的副本自己的 PA 去比（那份 DDR 内容就是改坏值 ⇒ 恒真）。
 *             （本核写直达 ⇒ 构造不出"缓存 vs DDR 分歧"，只能用自证做 NEG）
 *
 * 三条全 1 才 PASS。若核没实现 Zicbom，第一条 cbo 就 SIGILL（退出码 132）。
 */
#define _GNU_SOURCE
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
#define LEN  (8 * PAGE)

static sigjmp_buf g_ill;

static void on_sigill(int sig)
{
    (void)sig;
    siglongjmp(g_ill, 1);
}

static inline void cbo_flush(void *p)
{
    __asm__ volatile("cbo.flush (%0)" :: "r"(p) : "memory");
}

static inline void cbo_inval(void *p)
{
    __asm__ volatile("cbo.inval (%0)" :: "r"(p) : "memory");
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

static void fill(uint8_t *b, size_t n, uint32_t seed)
{
    uint32_t x = seed ? seed : 1u;
    for (size_t i = 0; i < n; i++) {
        x ^= x << 13; x ^= x >> 17; x ^= x << 5;
        b[i] = (uint8_t)(x ^ (uint32_t)(i * 7));
    }
}

/* 逐页取 PA 再读：posix_memalign 只保证**虚拟**连续，物理页不一定连续。
 * pa_src 决定读哪几页物理内存，exp 是被比对的期望字节——两者分开，
 * NEG 才能"读 buf 的物理页、比改坏的期望值"。 */
static int hw_page_match(int mfd, const uint8_t *pa_src, const uint8_t *exp,
                         size_t len, size_t *bad_off)
{
    for (size_t o = 0; o < len; o += PAGE) {
        unsigned long long pa = pa_of((void *)(pa_src + o));
        if (!pa) return -1;
        uint8_t *hw = mmap(NULL, PAGE, PROT_READ, MAP_SHARED, mfd, (off_t)pa);
        if (hw == MAP_FAILED) return -1;
        int eq = (memcmp(hw, exp + o, PAGE) == 0);
        munmap(hw, PAGE);
        if (!eq) { if (bad_off) *bad_off = o; return 0; }
    }
    return 1;
}

int main(void)
{
    signal(SIGILL, on_sigill);

    uint8_t *buf = NULL;
    if (posix_memalign((void **)&buf, PAGE, LEN) != 0 || !buf) {
        printf("CBO FAIL alloc\n"); return 2;
    }
    memset(buf, 0, LEN);

    int mfd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mfd < 0) { printf("CBO FAIL /dev/mem\n"); return 2; }

    /* ① POS：写 + flush，逐页比对 DDR */
    fill(buf, LEN, 0x12345678u);
    if (sigsetjmp(g_ill, 1) != 0) {
        printf("CBO SIGILL (cbo.flush 在该特权级被拒)\n");
        return 132;
    }
    for (size_t off = 0; off < LEN; off += 64) cbo_flush(buf + off);
    __sync_synchronize();
    size_t bad = 0;
    int pos = (hw_page_match(mfd, buf, buf, LEN, &bad) == 1);

    /* ② GATE：cbo.inval 必须 SIGILL */
    int gate = 0;
    if (sigsetjmp(g_ill, 1) == 0) cbo_inval(buf);
    else gate = 1;

    /* ③ NEG：判据自证——把期望缓冲改一个字节，同一条比对路径必须报不一致
     *    （不依赖缓存性质；若 hw_page_match 恒真，这里会 neg=0 变红） */
    int neg = 0;
    size_t neg_bad = (size_t)-1;
    {
        uint8_t *exp = (uint8_t *)malloc(LEN);
        if (exp) {
            memcpy(exp, buf, LEN);
            exp[123] ^= 0xFF;
            /* 读的是 buf 的物理页（DDR 里是正确值），比的是改坏的 exp */
            int rc = hw_page_match(mfd, buf, exp, LEN, &neg_bad);
            neg = (rc == 0 && neg_bad == 0);
            free(exp);
        }
    }

    printf("CBO POS=%d NEG=%d GATE=%d LEN=%zu\n", pos, neg, gate, LEN);
    if (!pos) printf("CBO first bad page off=%zu\n", bad);
    if (!neg) printf("CBO self-proof did not fire (bad=%zu)\n", neg_bad);
    return (pos && neg && gate) ? 0 : 1;
}