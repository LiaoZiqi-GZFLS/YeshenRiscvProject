// ============================================================================
// y1_common.h —— 板内 C 工具共用件（从 y1run.c 顶部原样抽出）
//
// 内容：NPU host 窗口 / arena / payload 槽的地址与寄存器偏移、payload 头结构、
//   CRC32（IEEE 802.3，反射多项式 0xEDB88320，与 zlib.crc32 同口径）、
//   monotonic 纳秒时钟、/dev/mem 物理映射。
//
// 使用方：y1run.c（整帧 runner）、y1cam.c（相机快照/预处理）。
//   两者都在单 TU 里用，故这里的实体一律 static / static inline（无多重定义）。
//
// 报错前缀：map_phys 的 stderr 报文用 Y1_LOG_TAG（默认 "y1run"，保持 y1run 原
//   报文逐字不变）；y1cam.c 在 include 前 `#define Y1_LOG_TAG "y1cam"` 覆盖。
// ============================================================================
#ifndef Y1_COMMON_H
#define Y1_COMMON_H

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <time.h>

#ifndef Y1_LOG_TAG
#define Y1_LOG_TAG "y1run"
#endif

#define PAGE 4096UL
#define PAYLOAD_BASE_DEF 0x81E00000UL
#define PAYLOAD_MAX      0x00200000UL          /* 2 MiB 槽 */
#define ARENA_BASE       0x80000000UL
#define ARENA_SIZE       0x02000000UL          /* 32 MiB，含 arena + payload */
#define REG_BASE         0xF000C000UL

#define R_CTRL    0x00
#define R_STATUS  0x04
#define R_DESC_A  0x34
#define R_DESC_N  0x38
#define R_WGT_A   0x40
#define R_WGT_D   0x44
#define R_WGT_WE  0x48
#define CTRL_START      0x1u
#define CTRL_SOFT_RESET 0x2u

#define HDR_SIZE      1024u
#define SEG_DESC      0
#define SEG_WGT       1
#define SEG_INPUT     2
#define SEG_MB        3
#define SEG_GOLDEN    4
#define NSEG          6
#define MAX_OUT       27          /* header 1024 B: 160 + 27*32 = 1024 */

struct seg { uint32_t off, len, crc, rsv; };
struct out { char name[16]; uint32_t npu, bytes, crc, rsv; };
struct hdr {
    char magic[4];
    uint32_t version, total, desc_count, n_out, n_mb;
    uint32_t input_npu, desc_npu, mbx_npu, mbx_bytes, input_bytes, golden_bytes;
    uint32_t rsv[4];
    struct seg seg[NSEG];
    struct out out[MAX_OUT];
};

static inline uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* ---- CRC32（IEEE 802.3，反射多项式 0xEDB88320；与 zlib.crc32 同口径） ---- */
static uint32_t crc_tab[256];
static inline void crc_init(void) {
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        crc_tab[i] = c;
    }
}
static inline uint32_t crc32_buf(const void *p, size_t n) {
    const uint8_t *b = (const uint8_t *)p;
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) c = crc_tab[(c ^ b[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

static inline void *map_phys(int fd, unsigned long phys, size_t len, const char *what) {
    unsigned long pa = phys & ~(PAGE - 1);
    size_t off = (size_t)(phys - pa);
    size_t ml = (off + len + PAGE - 1) & ~(PAGE - 1);
    void *m = mmap(NULL, ml, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)pa);
    if (m == MAP_FAILED) {
        /* 字面量拼接：Y1_LOG_TAG 取缺省值时与 y1run 原报文逐字相同 */
        fprintf(stderr, "!! " Y1_LOG_TAG ": mmap %s phys=0x%08lX len=%zu failed: %s\n",
                what, phys, len, strerror(errno));
        return NULL;
    }
    return (char *)m + off;
}

#endif /* Y1_COMMON_H */
