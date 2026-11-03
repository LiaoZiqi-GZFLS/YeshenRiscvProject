/* ddmem.c -- 板内 mmap 式 /dev/mem 读写小工具（Y1 C4b-F1 的大映像投递通路）。
 *
 * ============================ 为什么不能直接用 busybox dd ============================
 * F1 实测（2026-10-13，tag=c4b_r4 新内存图）：`dd if=X of=/dev/mem bs=4096 seek=...`
 * 在物理 0x801F0000 上**内核 oops**：
 *     Unable to handle kernel paging request at virtual address be1f4000
 *     status: 00040120 badaddr: be1f4000 cause: 0000000f   (Comm: dd)
 * 根因：riscv32 的 /dev/mem **read/write 系统调用**路径走 `xlate_dev_mem_ptr(p) = __va(p)`
 * 的**线性映射**换算。H2b 之后内存节点从物理 0x8200_0000 起（`/proc/iomem` 只有
 * `82000000-8fffffff : System RAM`）⇒ 凡是 phys < 0x8200_0000 的地址，`__va()` 算出来的
 * 虚拟地址落在 PAGE_OFFSET(0xBE00_0000) 之下、**根本没建映射** ⇒ 内核取/存指令页错 ⇒ oops。
 * 而 busybox `devmem` 用 **mmap**（`ioremap` 那一路，不看线性映射）⇒ 同一个地址读写得动。
 *
 * 结论：低 2 MB 的 NPU 主机写入区（desc/权重信箱/input）只能用 **mmap** 碰。
 * busybox 只给一 word 的 `devmem`，1.2 MB 要 307200 次进程创建（不可能）⇒ 本工具补这个洞。
 *
 * ============================ 语义 ============================
 *   ddmem wr <phys> <infile|->     把文件（或 stdin）整块写到物理地址
 *                                  成功打印：`WROK phys=0x.. len=.. RSEG=..`
 *                                  （RSEG = 写完**就地回读**逐字节比较，OK / MISMATCH n）
 *   ddmem rd <phys> <len> <out|->  从物理地址读 len 字节到文件（或 stdout）
 *                                  状态打印到 stderr，stdout 只有**裸数据**（可管进 md5sum/base64）
 *   ddmem mb <regbase> <off_addr> <off_data> <off_we> <infile|->
 *                                  **权重信箱成批投递**：输入是 8 B/条的小端记录流
 *                                  `wgt_addr(u32) data(u32)`，末条 `wgt_addr=0xFFFFFFFF`。
 *                                  每条 = 往 regbase+off_addr / +off_data 各写一 word、
 *                                  再往 regbase+off_we 写 1（HostRegs 的 WE 脉冲）。
 *                                  打印 `MBOK n=<条数>`。
 *                                  ★ 为什么必须成批：B5 的老路是 UART 逐字发
 *                                  `devmem A 0x..; devmem D 0x..; devmem WE 1`，而
 *                                  bias_adj 一项就是 6912 条 ⇒ 2 万条 devmem、
 *                                  ~900 KB 命令行、按 10 ms/字 = **2.6 小时**。
 *                                  这批寄存器也在 [0x8200_0000, 0x9000_0000) 之外
 *                                  （0xF000_C000，设备区），所以同样**只能用 mmap**。
 *
 * 对齐：地址必须 32 B 对齐（NPU 口径）；mmap 需要的页对齐在内部自己换算。
 * 只认识 32 位以内的物理地址（本板 DDR 只到 0x8FFF_FFFF，寄存器在 0xF000_C000）。
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define PAGE 4096UL

static const char *USAGE =
    "usage: ddmem wr <phys> <infile|->            # file/stdin -> /dev/mem\n"
    "       ddmem rd <phys> <len> <outfile|->     # /dev/mem -> file/stdout\n"
    "       ddmem mb <regbase> <off_a> <off_d> <off_we> <infile|->   # mailbox burst\n";

/* 把 [phys, phys+len) 映射出来，返回**首字节**指针（已做页内偏移）。 */
static void *map_phys(int fd, unsigned long long phys, size_t len,
                      void **base, size_t *maplen)
{
    unsigned long long pa = phys & ~(unsigned long long)(PAGE - 1);
    size_t off = (size_t)(phys - pa);
    size_t need = off + len;
    size_t ml = (need + PAGE - 1) & ~(PAGE - 1);
    void *m = mmap(NULL, ml, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)pa);
    if (m == MAP_FAILED) {
        fprintf(stderr, "!! ddmem: mmap(0x%08llX, %zu) failed: %s\n",
                pa, ml, strerror(errno));
        return NULL;
    }
    *base = m;
    *maplen = ml;
    return (char *)m + off;
}

static int read_all(int fd, unsigned char **out, size_t *out_len)
{
    size_t cap = 1 << 16, n = 0;
    unsigned char *b = malloc(cap);
    if (!b) return -1;
    for (;;) {
        if (n == cap) {
            cap *= 2;
            unsigned char *nb = realloc(b, cap);
            if (!nb) { free(b); return -1; }
            b = nb;
        }
        ssize_t r = read(fd, b + n, cap - n);
        if (r < 0) { free(b); return -1; }
        if (r == 0) break;
        n += (size_t)r;
    }
    *out = b;
    *out_len = n;
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 3) { fputs(USAGE, stderr); return 2; }

    unsigned long long phys = strtoull(argv[2], NULL, 0);
    if (!strcmp(argv[1], "wr") && (phys & 31ULL)) {
        fprintf(stderr, "!! ddmem: wr phys 0x%08llX 不是 32 B 对齐\n", phys);
        return 2;
    }

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("!! ddmem: open(/dev/mem)"); return 3; }

    int rc = 0;
    void *base = NULL;
    size_t maplen = 0;

    if (!strcmp(argv[1], "wr")) {
        if (argc < 4) { fputs(USAGE, stderr); close(fd); return 2; }
        unsigned char *data = NULL;
        size_t len = 0;
        if (!strcmp(argv[3], "-")) {
            if (read_all(0, &data, &len) != 0) { perror("!! ddmem: read(stdin)"); close(fd); return 3; }
        } else {
            struct stat st;
            if (stat(argv[3], &st) != 0) { perror("!! ddmem: stat"); close(fd); return 3; }
            len = (size_t)st.st_size;
            data = malloc(len ? len : 1);
            if (!data) { fprintf(stderr, "!! ddmem: malloc %zu\n", len); close(fd); return 3; }
            FILE *f = fopen(argv[3], "rb");
            if (!f) { perror("!! ddmem: fopen"); free(data); close(fd); return 3; }
            if (fread(data, 1, len, f) != len) { fprintf(stderr, "!! ddmem: short read\n"); fclose(f); free(data); close(fd); return 3; }
            fclose(f);
        }
        unsigned char *p = map_phys(fd, phys, len, &base, &maplen);
        if (!p) { free(data); close(fd); return 4; }
        memcpy(p, data, len);
        /* ★ 就地回读逐字节比较：mmap 拿不到真 DDR（保留区/未映射）时这里立刻响 */
        size_t bad = 0;
        unsigned long long firstbad = 0;
        for (size_t i = 0; i < len; i++) {
            if (p[i] != data[i]) { bad++; if (bad == 1) firstbad = phys + i; }
        }
        munmap(base, maplen);
        printf("WROK phys=0x%08llX len=%zu RSEG=%s", phys, len,
               bad ? "MISMATCH" : "OK");
        if (bad) printf(" bad=%zu firstbad=0x%08llX", bad, firstbad);
        printf("\n");
        fflush(stdout);
        free(data);
        if (bad) rc = 5;

    } else if (!strcmp(argv[1], "rd")) {
        if (argc < 5) { fputs(USAGE, stderr); close(fd); return 2; }
        size_t len = (size_t)strtoull(argv[3], NULL, 0);
        unsigned char *p = map_phys(fd, phys, len, &base, &maplen);
        if (!p) { close(fd); return 4; }
        int ofd = (!strcmp(argv[4], "-")) ? 1 : open(argv[4], O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (ofd < 0) { perror("!! ddmem: open(out)"); munmap(base, maplen); close(fd); return 3; }
        size_t n = 0;
        while (n < len) {
            ssize_t w = write(ofd, p + n, len - n);
            if (w <= 0) { perror("!! ddmem: write"); rc = 3; break; }
            n += (size_t)w;
        }
        if (ofd != 1) close(ofd);
        munmap(base, maplen);
        fprintf(stderr, "RROK phys=0x%08llX len=%zu wrote=%zu\n", phys, len, n);
        if (n != len) rc = 3;

    } else if (!strcmp(argv[1], "mb")) {
        if (argc < 7) { fputs(USAGE, stderr); close(fd); return 2; }
        unsigned long long regbase = strtoull(argv[2], NULL, 0);
        unsigned long off_a = (unsigned long)strtoul(argv[3], NULL, 0);
        unsigned long off_d = (unsigned long)strtoul(argv[4], NULL, 0);
        unsigned long off_we = (unsigned long)strtoul(argv[5], NULL, 0);
        unsigned char *data = NULL;
        size_t len = 0;
        if (!strcmp(argv[6], "-")) {
            if (read_all(0, &data, &len) != 0) { perror("!! ddmem: read(stdin)"); close(fd); return 3; }
        } else {
            struct stat st;
            if (stat(argv[6], &st) != 0) { perror("!! ddmem: stat"); close(fd); return 3; }
            len = (size_t)st.st_size;
            data = malloc(len ? len : 1);
            FILE *f = fopen(argv[6], "rb");
            if (!f) { perror("!! ddmem: fopen"); free(data); close(fd); return 3; }
            if (fread(data, 1, len, f) != len) { fclose(f); free(data); close(fd); return 3; }
            fclose(f);
        }
        /* 寄存器窗整页映射：off_* 都远小于一页，一页就够 */
        unsigned long long pa = regbase & ~(unsigned long long)(PAGE - 1);
        unsigned long inpage = (unsigned long)(regbase - pa);
        unsigned long long need = (unsigned long long)inpage
                                  + (off_a > off_we ? off_a : off_we) + 4;
        size_t ml = (size_t)((need + PAGE - 1) & ~(PAGE - 1));
        unsigned char *m = mmap(NULL, ml, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)pa);
        if (m == MAP_FAILED) {
            fprintf(stderr, "!! ddmem: mmap(0x%08llX) failed: %s\n", pa, strerror(errno));
            free(data); close(fd); return 4;
        }
        volatile unsigned int *ra = (volatile unsigned int *)(m + inpage + off_a);
        volatile unsigned int *rd = (volatile unsigned int *)(m + inpage + off_d);
        volatile unsigned int *rw = (volatile unsigned int *)(m + inpage + off_we);
        unsigned long n = 0, bad = 0;
        if (len % 8) {
            fprintf(stderr, "!! ddmem mb: 记录流 %zu B 不是 8 的整数倍\n", len);
            munmap(m, ml); free(data); close(fd); return 2;
        }
        for (size_t i = 0; i + 8 <= len; i += 8) {
            unsigned int a, d;
            memcpy(&a, data + i, 4);
            memcpy(&d, data + i + 4, 4);
            if (a == 0xFFFFFFFFu) break;
            *ra = a;                    /* WGT_ADDR */
            *rd = d;                    /* WGT_DATA */
            *rw = 1u;                   /* WGT_WE 脉冲 */
            n++;
            /* 回读 WGT_ADDR/WGT_DATA 当"这批写进去了"的就地证据 */
            if (*ra != a || *rd != d) bad++;
        }
        munmap(m, ml);
        printf("MBOK n=%lu regbase=0x%08llX RREG=%s\n", n, regbase, bad ? "MISMATCH" : "OK");
        if (bad) printf("  bad=%lu\n", bad);
        fflush(stdout);
        free(data);
        if (bad) rc = 5;

    } else {
        fputs(USAGE, stderr);
        rc = 2;
    }

    close(fd);
    return rc;
}
