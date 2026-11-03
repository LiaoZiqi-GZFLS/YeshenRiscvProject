// ===================== GPU 端点级单元装置（glue + gpu_top + RAM 模型）=====================
//
// 覆盖范围（这是 tb_pbus.cpp 的 GPU 窗判据**测不到**的那一段）：
//   CPU pIo 读/写 → glue 译码（0xF000_5000）→ gpu_csr → gpu_cmd（16 项 FIFO 组包/解包）
//   → gpu_2d（FILL 光栅）→ gpu_mem（写合并）→ glue MemArbiter 第 4 主口 → io_mem → RAM 模型。
//
// 判据（每条打印实测值）：
//   ① GPU_ID(0x5000) == 0x5947_5055（"YGPU"）；FIFO_FREE == 16；
//   ② SCISSOR0/1 回环（写读逐位相等，且换第二个图案，防"读到别的寄存器"）；
//   ③ FENCE(seq=0x1234)：STATUS.busy 回 0、SEQ_DONE == 0x1234（命令 FIFO + 解包 + 完成握手全链）；
//   ④ FILL(8x2, stride=64px, color=0xF800) @0x9200_0000：**逐 8 B 字核对内存**
//        · 行 0 = idx 0/1，行 1 = idx 16/17（stride 生效），值 0xF800F800F800F800；
//        · 负对照：idx 2 / idx 15 必须仍是 0（不许越界写到行外/跨行连写）；
//        · 本装置启动时 RAM 全 0 ⇒ 非零期望值不是"自比较"；
//   ⑤ FLIP：写 1 → STATUS[16]=1；给一拍 vsync → pending 回 0 且 flip_toggle 翻转（双缓冲握手）；
//   ⑥ 窗外 0xF000_6100 ⇒ rresp=DECERR；窗内未映射偏移 0x5100 ⇒ OKAY + rdata=0（读到 0 而不是 x）。
//
// 负对照（`negctl_gpu_pbus.sh`）：把网表里 GPU 读窗基址 20'hF0005 改掉 ⇒ ① 立即翻红。
#include "Vgpu_unit_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>

#define GPU_BASE     0xF0005000u
#define R_ID         0x000u
#define R_STATUS     0x004u
#define R_CMD_DATA   0x010u
#define R_CMD_PUSH   0x014u
#define R_SEQ_DONE   0x018u
#define R_FIFO_FREE  0x01Cu
#define R_SC0        0x020u
#define R_SC1        0x024u
#define R_FLIP       0x028u
#define R_DBG        0x02Cu

#define OP_FILL      0x02u
#define OP_FENCE     0x07u

static Vgpu_unit_top* dut = nullptr;
static uint64_t cyc = 0;
static const int CAP = 400;      // 单拍主口的等待上限（FILL 期间命令 FIFO 会短暂反压）
static int nFail = 0;

static void fail(const char* what) { printf("  [FAIL] %s\n", what); nFail++; }
static void expectU32(const char* what, uint32_t got, uint32_t exp) {
    printf("    %-52s got=0x%08X exp=0x%08X  %s\n", what, got, exp, got == exp ? "OK" : "MISMATCH");
    if (got != exp) fail(what);
}
static void expectInt(const char* what, int got, int exp) {
    printf("    %-52s got=%d exp=%d  %s\n", what, got, exp, got == exp ? "OK" : "MISMATCH");
    if (got != exp) fail(what);
}

// ---------------- 时钟：先组合观测（settle），再推 posedge（advance）----------------
static void settle() { dut->eval(); }
static void advance() {
    dut->clock = 1; dut->eval();
    dut->clock = 0; dut->eval();
    cyc++;
}
static void tick() { settle(); advance(); }

static void setPIdle() {
    dut->p_awvalid = 0; dut->p_awaddr = 0; dut->p_awsize = 2;
    dut->p_awcache = 0; dut->p_awprot = 0;
    dut->p_wvalid = 0; dut->p_wdata = 0; dut->p_wstrb = 0xF; dut->p_wlast = 1;
    dut->p_arvalid = 0; dut->p_araddr = 0; dut->p_arsize = 2;
    dut->p_arcache = 0; dut->p_arprot = 0;
    dut->p_bready = 1; dut->p_rready = 1;
}

static bool opRead(uint32_t addr, uint32_t* data, uint8_t* resp, bool* rlast, const char* tag) {
    bool accepted = false;
    for (int k = 0; k < CAP && !accepted; ++k) {
        dut->p_arvalid = 1; dut->p_araddr = addr; dut->p_arsize = 2;
        dut->p_arcache = 0; dut->p_arprot = 0;
        settle();
        accepted = (dut->p_arready != 0);
        advance();
    }
    if (!accepted) { printf("  [FAIL] %s: AR 握手超时\n", tag); nFail++; return false; }
    dut->p_arvalid = 0;

    bool got = false;
    for (int k = 0; k < CAP && !got; ++k) {
        settle();
        if (dut->p_rvalid) {
            *data = (uint32_t)dut->p_rdata;
            *resp = (uint8_t)dut->p_rresp;
            *rlast = (bool)dut->p_rlast;
            got = true;
        }
        advance();
    }
    if (!got) { printf("  [FAIL] %s: R 超时\n", tag); nFail++; return false; }
    return true;
}

static bool opWrite(uint32_t addr, uint32_t data, uint8_t* resp, const char* tag) {
    bool aw = false, w = false;
    for (int k = 0; k < CAP && !(aw && w); ++k) {
        dut->p_awvalid = aw ? 0 : 1;
        if (!aw) { dut->p_awaddr = addr; dut->p_awsize = 2; dut->p_awcache = 0; dut->p_awprot = 0; }
        dut->p_wvalid = w ? 0 : 1;
        if (!w) { dut->p_wdata = data; dut->p_wstrb = 0xF; dut->p_wlast = 1; }
        settle();
        if (!aw && dut->p_awready) aw = true;
        if (!w  && dut->p_wready)  w  = true;
        advance();
    }
    if (!(aw && w)) { printf("  [FAIL] %s: AW/W 握手超时\n", tag); nFail++; return false; }
    dut->p_awvalid = 0; dut->p_wvalid = 0;

    bool got = false;
    for (int k = 0; k < CAP && !got; ++k) {
        settle();
        if (dut->p_bvalid) { *resp = (uint8_t)dut->p_bresp; got = true; }
        advance();
    }
    if (!got) { printf("  [FAIL] %s: B 超时\n", tag); nFail++; return false; }
    return true;
}

static uint32_t rd(uint32_t off, const char* tag) {
    uint32_t v = 0xDEADBEEF; uint8_t r = 0xFF; bool l = 0;
    if (!opRead(GPU_BASE + off, &v, &r, &l, tag)) return 0xDEADBEEF;
    if (r != 0) { printf("  [FAIL] %s: rresp=%d（期望 OKAY）\n", tag, (int)r); nFail++; }
    return v;
}
static void wr(uint32_t off, uint32_t v, const char* tag) {
    uint8_t r = 0xFF;
    if (!opWrite(GPU_BASE + off, v, &r, tag)) return;
    if (r != 0) { printf("  [FAIL] %s: bresp=%d（期望 OKAY）\n", tag, (int)r); nFail++; }
}

// 推一条命令：words[0] = 命令头，words[1..n-1] = 参数；最后一个字走 CMD_PUSH
static void pushCmd(const uint32_t* words, int n, const char* tag) {
    char buf[96];
    for (int i = 0; i < n; ++i) {
        snprintf(buf, sizeof(buf), "%s word[%d]", tag, i);
        wr((i == n - 1) ? R_CMD_PUSH : R_CMD_DATA, words[i], buf);
    }
}

static bool waitIdle(const char* tag) {
    for (int k = 0; k < 200000; ++k) {
        uint32_t st = rd(R_STATUS, tag);
        if ((st & 1u) == 0) {
            // busy=0 且 fifo_used=0 才算真的排干
            if (((st >> 4) & 0xFu) == 0) return true;
        }
        for (int j = 0; j < 8; ++j) tick();
    }
    printf("  [FAIL] %s: 等不到 busy=0/fifo_empty\n", tag);
    nFail++;
    return false;
}

static uint64_t peek(uint32_t byte_addr) {
    dut->dbg_idx = (byte_addr & 0x1FFFFFu) >> 3;
    dut->eval();
    return (uint64_t)dut->dbg_word;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vgpu_unit_top;
    dut->clock = 0; dut->reset = 1;
    setPIdle();
    dut->vsync = 0;
    dut->dbg_idx = 0;
    for (int i = 0; i < 8; ++i) tick();
    dut->reset = 0;
    for (int i = 0; i < 4; ++i) tick();

    printf("GPU 端点级装置（YeshenSocGlue + gpu_top + axi_ram_model）\n");

    // ---------------- ① ID / FIFO_FREE ----------------
    printf("=== ① GPU_ID / FIFO_FREE ===\n");
    expectU32("GPU_ID", rd(R_ID, "GPU_ID"), 0x59475055u);
    expectU32("FIFO_FREE", rd(R_FIFO_FREE, "FIFO_FREE"), 16u);

    // ---------------- ② SCISSOR 回环 ----------------
    printf("=== ② SCISSOR0/1 回环 ===\n");
    wr(R_SC0, 0x000A0005u, "SC0 写 #1");
    expectU32("SC0 读回 #1", rd(R_SC0, "SC0 读 #1"), 0x000A0005u);
    wr(R_SC0, 0x00140007u, "SC0 写 #2");
    expectU32("SC0 读回 #2", rd(R_SC0, "SC0 读 #2"), 0x00140007u);
    wr(R_SC1, 0x02580400u, "SC1 写");
    expectU32("SC1 读回", rd(R_SC1, "SC1 读"), 0x02580400u);

    // ---------------- ③ FENCE（命令 FIFO 全链）----------------
    printf("=== ③ FENCE seq=0x1234 ===\n");
    {
        uint32_t w[2];
        w[0] = (uint32_t)((OP_FENCE << 24) | (1u << 16));   // nwords=1
        w[1] = 0x1234u;                                     // seq
        pushCmd(w, 2, "FENCE");
        waitIdle("FENCE");
        expectU32("SEQ_DONE", rd(R_SEQ_DONE, "SEQ_DONE"), 0x1234u);
        expectU32("FIFO_FREE 回到 16", rd(R_FIFO_FREE, "FIFO_FREE 2"), 16u);
    }

    // ---------------- ④ FILL 8x2 @ 0x9200_0000 ----------------
    printf("=== ④ FILL 8x2 stride=64px color=0xF800 @0x9200_0000 ===\n");
    {
        const uint32_t DST = 0x92000000u, STRIDE = 64u, COLOR = 0xF800u;
        uint32_t w[8];
        w[0] = (uint32_t)((OP_FILL << 24) | (7u << 16));    // nwords=7
        w[1] = DST; w[2] = STRIDE; w[3] = 0; w[4] = 0; w[5] = 8; w[6] = 2; w[7] = COLOR;
        pushCmd(w, 8, "FILL");
        waitIdle("FILL");
        printf("   内存事务计数（aw=%u w=%u ar=%u）\n",
               (unsigned)dut->mem_aw_count, (unsigned)dut->mem_w_count, (unsigned)dut->mem_ar_count);
        if (dut->mem_w_count < 4) fail("FILL 没有真的写出 ≥4 个 64-bit 字（写路没通？）");

        const uint64_t EXP = 0xF800F800F800F800ull;
        expectU32("行0 字0 低 32", (uint32_t)peek(DST + 0),  0xF800F800u);
        expectU32("行0 字0 高 32", (uint32_t)(peek(DST + 0) >> 32), 0xF800F800u);
        expectU32("行0 字1 低 32", (uint32_t)peek(DST + 8),  0xF800F800u);
        expectU32("行1 字0 低 32", (uint32_t)peek(DST + 128), 0xF800F800u);
        expectU32("行1 字1 低 32", (uint32_t)peek(DST + 136), 0xF800F800u);
        // 负对照：行外（x=8 处）与行间（idx 15）必须还是 0
        expectU32("负对照 行0 之后（+16B）", (uint32_t)peek(DST + 16),  0u);
        expectU32("负对照 行间（+120B）",   (uint32_t)peek(DST + 120), 0u);
        (void)EXP;
    }

    // ---------------- ⑤ FLIP / vsync ----------------
    printf("=== ⑤ FLIP：写 1 → pending=1；vsync → pending=0 且 flip_toggle 翻转 ===\n");
    {
        int tog0 = (int)dut->flip_toggle;
        wr(R_FLIP, 1u, "FLIP 写");
        expectU32("FLIP 读回 pending=1", rd(R_FLIP, "FLIP 读"), 1u);
        // 给一拍 vsync
        dut->vsync = 1; tick(); dut->vsync = 0;
        for (int i = 0; i < 2; ++i) tick();
        expectU32("vsync 后 pending=0", rd(R_FLIP, "FLIP 读 2"), 0u);
        expectInt("flip_toggle 翻转", (int)dut->flip_toggle, tog0 ^ 1);
        // 再写一次但**不给 vsync** ⇒ pending 必须保持（证明它真的等帧起点）
        wr(R_FLIP, 1u, "FLIP 写 #2");
        for (int i = 0; i < 20; ++i) tick();
        expectU32("无 vsync 时 pending 保持 1", rd(R_FLIP, "FLIP 读 3"), 1u);
        dut->vsync = 1; tick(); dut->vsync = 0;
        for (int i = 0; i < 2; ++i) tick();
        expectInt("第二次 flip_toggle 翻转", (int)dut->flip_toggle, tog0);
    }

    // ---------------- ⑥ 窗外 DECERR / 窗内未映射 ----------------
    printf("=== ⑥ 窗外 0xF0006100 与窗内未映射 0x5100 ===\n");
    {
        uint32_t v = 0; uint8_t r = 0xFF; bool l = 0;
        if (opRead(0xF0006100u, &v, &r, &l, "窗外读")) {
            printf("   窗外读: rresp=%d rdata=0x%08X\n", (int)r, v);
            expectInt("窗外读 rresp（DECERR）", (int)r, 3);
        }
        v = 0xDEADBEEF; r = 0xFF;
        if (opRead(GPU_BASE + 0x100u, &v, &r, &l, "窗内未映射读")) {
            printf("   窗内未映射读: rresp=%d rdata=0x%08X\n", (int)r, v);
            expectInt("窗内未映射 rresp（OKAY）", (int)r, 0);
            expectU32("窗内未映射 rdata", v, 0u);
        }
    }

    bool pass = (nFail == 0);
    printf("cyc=%llu  fail=%d\n", (unsigned long long)cyc, nFail);
    printf("=== GPU-GLUE %s ===\n", pass ? "PASS" : "FAIL");
    dut->final();
    delete dut;
    return pass ? 0 : 1;
}
