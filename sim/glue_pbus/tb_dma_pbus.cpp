// ===================== DMA 引擎「并入 SoC 后」的胶合层判决装置 =====================
//
// DUT：--top-module pbus_dma_top（= YeshenSocGlue + DmaEngine；两个网表都只读、一字不改）。
//   回答的问题：**引擎接进 SoC 之后，一条真实 DMA 搬运能不能走通整条集成通路** ——
//     CPU/装置写 CSR 窗（glue pBus 解码 0xF000_6000）→ DmaEngine.axilite_* → 引擎发起 AXI4 →
//     glue §3.5 第 6 个主人（MemArbiter 类 2 = DMA）拿到总线 → io.mem（真 64bit 内存模型）→
//     读回数据 → COPY 写回 → 完成/err → CSR 回读 + IRQ（PLIC 源 4 的输入线）。
//
// 判据（每条都能翻红）：
//   J1【正·核心】胶合层 DMA COPY **逐字节正确**：装置预载源区 → 程序 CH0（SRC/DST/LEN/MODE=COPY）→
//        start → 轮询 done ⇒ 目标区**逐字节** == 源区、`CH_BYTES == LEN`、**源区未被改**。
//   J2【正·通路】master port + 仲裁被**真实驱动**：io_mem 上 AR/AW/W 计数 **> 0**（引擎真的过 §3.5
//        打到内存），且 CSR 窗读回引擎活体常数 `GBL_ID == 0x59444D41`（"YDMA"）。
//   J3【正·中断】完成后引擎 `irq`（= GBL_DONE|GBL_ERR 线或，= glue.io_dmaIrq = PLIC 源 4 的输入）== 1；
//        写 `CH_STATUS` w1c 后 `irq` == 0（清源）。
//   J4【负·窗口基址】把**同一个偏移**放到**未译码的错窗口基址**上：读不回 `GBL_ID`、
//        写得到 DECERR、且**不产生任何内存搬运**（`GBL_DONE` 不动）⇒ 证明"窗基址必须对"。
//
// 时钟：单时钟 `clock`；`reset` 同步高有效。采样/推进分两步（照 sim/ddr3bridge、glue_pbus 惯例）。
#include "Vpbus_dma_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>

// ---------------- 地址（对到 src/YeshenSocGlue.scala:YeshenMap.DMA_* + y1/rtl/DmaEngine.scala 的 CSR 表）----------------
#define DMA_BASE      0xF0006000u   // DMA CSR 窗（256 B，掩码 0xFFFF_FF00）
#define DMA_CTRL      (DMA_BASE + 0x00)   // W: bit0 start / bit1 abort；R: bit8 busy / bit9 done_sticky
#define DMA_STATUS    (DMA_BASE + 0x04)   // R: bit0 done / bit1 err / bit2 aborted；W: w1c
#define DMA_SRC       (DMA_BASE + 0x08)
#define DMA_DST       (DMA_BASE + 0x0C)
#define DMA_LEN       (DMA_BASE + 0x10)
#define DMA_MODE      (DMA_BASE + 0x14)
#define DMA_BYTES     (DMA_BASE + 0x18)
#define DMA_ID        (DMA_BASE + 0x24)
#define DMA_GBL_ID    (DMA_BASE + 0x80)
#define DMA_GBL_DONE  (DMA_BASE + 0x8C)
#define GBL_ID_CONST  0x59444D41u   // "YDMA"
#define CH_ID_CONST   0x444D4100u   // "DMA\0" | 0

#define WRONG_BASE    0xF0006100u   // 未译码的空段（DMA 窗 0x6000-0x60FF 之后；2026-10-31 0x5000 被 GPU 占用后改）⇒ DECERR

// ---- 用例常量 ----
#define SRC0   0x1000u
#define DST0   0x8000u
#define LEN0   512u
#define SRC1   0x2000u
#define DST1   0xA000u
#define LEN1   256u
#define MEM_BYTES (256u*1024u)

static Vpbus_dma_top* dut = nullptr;
static uint64_t cyc = 0;
static const int CAP = 200;
static int nFail = 0;
static void fail(const char* what) { printf("  [FAIL] %s\n", what); nFail++; }
static void ok(const char* what)   { printf("  [ok]   %s\n", what); }

// ---------------- 真内存模型（64bit INCR 突发；1 拍读延迟；写收完一拍 B）----------------
static uint8_t mem[MEM_BYTES];
static uint8_t expectByte(uint32_t a) { return (uint8_t)(0xA5u + a * 7u + (a >> 8) * 13u); }
static uint64_t readMem64(uint32_t a) { uint64_t v = 0; for (int b = 0; b < 8; ++b) v |= (uint64_t)mem[(a + b) & (MEM_BYTES - 1)] << (8 * b); return v; }
static void writeMem64(uint32_t a, uint64_t d, uint8_t strb) { for (int b = 0; b < 8; ++b) if ((strb >> b) & 1) mem[(a + b) & (MEM_BYTES - 1)] = (uint8_t)(d >> (8 * b)); }

static long nMemAr = 0, nMemAw = 0, nMemW = 0, nMemB = 0, nMemRlast = 0, nRwOverlap = 0;
static int rdState = 0; static uint32_t rdAddr = 0; static int rdBeatsLeft = 0;
static int wrActive = 0; static uint32_t wrAddr = 0; static int wrBeatsLeft = 0; static int bPend = 0;

static void memComb() {
    dut->io_mem_ar_arready = (rdState == 0) ? 1 : 0;
    dut->io_mem_aw_awready = (wrActive == 0 && bPend == 0) ? 1 : 0;
    dut->io_mem_w_wready   = (wrActive && !bPend) ? 1 : 0;
    dut->io_mem_r_rvalid   = (rdState == 1) ? 1 : 0;
    dut->io_mem_r_rdata    = (rdState == 1) ? readMem64(rdAddr) : 0;
    dut->io_mem_r_rlast    = (rdState == 1 && rdBeatsLeft == 1) ? 1 : 0;
    dut->io_mem_r_rid = 0; dut->io_mem_r_rresp = 0;
    dut->io_mem_b_bvalid = bPend ? 1 : 0; dut->io_mem_b_bid = 0; dut->io_mem_b_bresp = 0;
}

// ---- ETH 从口：永远 ready + 单拍 OKAY（防挂死；本装置不驱动它的主方）----
static uint8_t eth_bvalid = 0, eth_rvalid = 0;
static void ethComb() {
    if (dut->io_ethAxi_awvalid && dut->io_ethAxi_awready) eth_bvalid = 1;
    if (eth_bvalid && dut->io_ethAxi_bready) eth_bvalid = 0;
    if (dut->io_ethAxi_arvalid && dut->io_ethAxi_arready) eth_rvalid = 1;
    if (eth_rvalid && dut->io_ethAxi_rready) eth_rvalid = 0;
    dut->io_ethAxi_awready = 1; dut->io_ethAxi_wready = 1;
    dut->io_ethAxi_arready = 1;
    dut->io_ethAxi_bvalid = eth_bvalid; dut->io_ethAxi_bresp = 0;
    dut->io_ethAxi_rvalid = eth_rvalid; dut->io_ethAxi_rdata = 0; dut->io_ethAxi_rresp = 0;
}

// ★ AXI 握手采样口径：值在**本拍**有效、在**边沿**采样 ⇒ 必须在时钟边沿**之前**
//   （clock=0 的 settle）把本拍握手快照下来，边沿之后的 postEdge 用**快照**推进模型。
//   （踩过的坑：若在 `clock=1; eval()` **之后**读 dut 的 valid/ready 来判握手，DUT 里
//    `owner`/引擎寄存器会在该边沿更新 ⇒ 看到的是"边沿后的 valid + 边沿前的 ready"的
//    混合值 ⇒ 误判一次 AR 握手 ⇒ 内存模型提前进"读在飞"⇒ 与 DUT 死锁。）
struct SnapM { bool arv, arr; uint32_t araddr; int arlen;
               bool rv, rr, rlast;
               bool awv, awr; uint32_t awaddr; int awlen;
               bool wv, wr; uint64_t wd; uint8_t wstrb;
               bool bv, br; };
static SnapM snapm;

static void settle() {
    memComb(); ethComb(); dut->eval();
    snapm.arv = dut->io_mem_ar_arvalid; snapm.arr = dut->io_mem_ar_arready;
    snapm.araddr = dut->io_mem_ar_araddr; snapm.arlen = (int)dut->io_mem_ar_arlen;
    snapm.rv = dut->io_mem_r_rvalid; snapm.rr = dut->io_mem_r_rready; snapm.rlast = dut->io_mem_r_rlast;
    snapm.awv = dut->io_mem_aw_awvalid; snapm.awr = dut->io_mem_aw_awready;
    snapm.awaddr = dut->io_mem_aw_awaddr; snapm.awlen = (int)dut->io_mem_aw_awlen;
    snapm.wv = dut->io_mem_w_wvalid; snapm.wr = dut->io_mem_w_wready;
    snapm.wd = dut->io_mem_w_wdata; snapm.wstrb = (uint8_t)dut->io_mem_w_wstrb;
    snapm.bv = dut->io_mem_b_bvalid; snapm.br = dut->io_mem_b_bready;
}
static void postEdge() {
    if (snapm.arv && snapm.arr) { rdState = 1; rdAddr = snapm.araddr; rdBeatsLeft = snapm.arlen + 1; nMemAr++; }
    if (rdState == 1 && snapm.rv && snapm.rr) { if (snapm.rlast) nMemRlast++; rdAddr += 8; if (--rdBeatsLeft == 0) rdState = 0; }
    if (snapm.awv && snapm.awr) { wrActive = 1; wrAddr = snapm.awaddr; wrBeatsLeft = snapm.awlen + 1; nMemAw++; }
    if (wrActive && !bPend && snapm.wv && snapm.wr) { writeMem64(wrAddr, snapm.wd, snapm.wstrb); wrAddr += 8; nMemW++; if (--wrBeatsLeft == 0) bPend = 1; }
    if (bPend && snapm.bv && snapm.br) { bPend = 0; wrActive = 0; nMemB++; }
    if (snapm.arv && snapm.awv) nRwOverlap++;
}
static void advance() { dut->clock = 1; dut->eval(); postEdge(); dut->clock = 0; dut->eval(); cyc++; }
static void tick() { settle(); advance(); }

static void setCpuIoIdle() {
    dut->io_cpuIo_awvalid = 0; dut->io_cpuIo_awaddr = 0; dut->io_cpuIo_awsize = 2;
    dut->io_cpuIo_awcache = 0; dut->io_cpuIo_awprot = 0;
    dut->io_cpuIo_wvalid  = 0; dut->io_cpuIo_wdata  = 0; dut->io_cpuIo_wstrb = 0xF; dut->io_cpuIo_wlast = 1;
    dut->io_cpuIo_arvalid = 0; dut->io_cpuIo_araddr = 0; dut->io_cpuIo_arsize = 2;
    dut->io_cpuIo_arcache = 0; dut->io_cpuIo_arprot = 0;
    dut->io_cpuIo_bready  = 1; dut->io_cpuIo_rready = 1;
}

static void doReset() {
    setCpuIoIdle();
    dut->reset = 1;
    for (int i = 0; i < 12; ++i) tick();
    dut->reset = 0;
    for (int i = 0; i < 6; ++i) tick();
    rdState = wrActive = bPend = 0; eth_bvalid = eth_rvalid = 0;
}

// ---------------- pBus（cpuIo）单拍读 / 写（照 tb_npu_pbus 的 opRead/opWriteStagger）----------------
static bool opRead(uint32_t addr, uint32_t* data, uint8_t* resp, const char* tag) {
    bool accepted = false;
    for (int k = 0; k < CAP && !accepted; ++k) {
        dut->io_cpuIo_arvalid = 1; dut->io_cpuIo_araddr = addr;
        dut->io_cpuIo_arsize = 2; dut->io_cpuIo_arcache = 0; dut->io_cpuIo_arprot = 0;
        settle();
        accepted = (dut->io_cpuIo_arready != 0);
        advance();
    }
    if (!accepted) { printf("  [FAIL] %s: AR 握手超时（>%d 拍）\n", tag, CAP); nFail++; return false; }
    dut->io_cpuIo_arvalid = 0;
    bool got = false;
    for (int k = 0; k < CAP && !got; ++k) {
        settle();
        if (dut->io_cpuIo_rvalid) { *data = (uint32_t)dut->io_cpuIo_rdata; *resp = (uint8_t)dut->io_cpuIo_rresp; got = true; }
        advance();
    }
    if (!got) { printf("  [FAIL] %s: R 超时（>%d 拍）\n", tag, CAP); nFail++; return false; }
    return true;
}
static bool opWrite(uint32_t addr, uint32_t data, uint8_t* resp, const char* tag) {
    bool aw = false, w = false;
    for (int k = 0; k < CAP && !(aw && w); ++k) {
        dut->io_cpuIo_awvalid = aw ? 0 : 1; dut->io_cpuIo_awaddr = addr;
        dut->io_cpuIo_awsize = 2; dut->io_cpuIo_awcache = 0; dut->io_cpuIo_awprot = 0;
        dut->io_cpuIo_wvalid  = w  ? 0 : 1; dut->io_cpuIo_wdata = data;
        dut->io_cpuIo_wstrb = 0xF; dut->io_cpuIo_wlast = 1;
        settle();
        if (!aw && dut->io_cpuIo_awready) aw = true;
        if (!w  && dut->io_cpuIo_wready)  w  = true;
        advance();
    }
    if (!(aw && w)) { printf("  [FAIL] %s: AW/W 握手超时（>%d 拍）\n", tag, CAP); nFail++; return false; }
    dut->io_cpuIo_awvalid = 0; dut->io_cpuIo_wvalid = 0;
    bool got = false;
    for (int k = 0; k < CAP && !got; ++k) {
        settle();
        if (dut->io_cpuIo_bvalid) { *resp = (uint8_t)dut->io_cpuIo_bresp; got = true; }
        advance();
    }
    if (!got) { printf("  [FAIL] %s: B 超时（>%d 拍）\n", tag, CAP); nFail++; return false; }
    return true;
}

// ---------------- 跑一笔 COPY 并轮询完成 ----------------
static bool runCopy(uint32_t src, uint32_t dst, uint32_t len, const char* tag) {
    uint8_t r = 0;
    printf("  -- [%s] 程序 CH0：SRC=0x%X DST=0x%X LEN=%u MODE=0(COPY) --\n", tag, src, dst, len);
    if (!opWrite(DMA_SRC,  src, &r, "写 SRC")) return false;
    if (!opWrite(DMA_DST,  dst, &r, "写 DST")) return false;
    if (!opWrite(DMA_LEN,  len, &r, "写 LEN")) return false;
    if (!opWrite(DMA_MODE, 0u,  &r, "写 MODE")) return false;
    if (r != 0) { printf("  [FAIL] 程序阶段 bresp=%d（应 OKAY=0）\n", (int)r); nFail++; return false; }
    if (!opWrite(DMA_CTRL, 1u,  &r, "写 CH_CTRL.start")) return false;

    // ---- 诊断：start 后头 ~60 拍把 io_mem 与 dmaAxi 握手态打出来（busy 排查用）----
    if (getenv("DMA_DEBUG")) {
        for (int i = 0; i < 60; ++i) {
            settle();
            printf("    [dbg %2d] owner=%d rdbusy=%d | dMem AR v/r=%d/%d | R v/r/last=%d/%d/%d | AW v/r=%d/%d | W v/r=%d/%d | B v/r=%d/%d | mem AR v/r=%d/%d R v/r/last=%d/%d/%d\n",
                   i,
                   (int)dut->obs_glue_owner, (int)dut->obs_glue_memRdBusy,
                   (int)dut->obs_dmaMem_arvalid, (int)dut->obs_dmaMem_arready,
                   (int)dut->obs_dmaMem_rvalid, (int)dut->obs_dmaMem_rready, (int)dut->obs_dmaMem_rlast,
                   (int)dut->obs_dmaMem_awvalid, (int)dut->obs_dmaMem_awready,
                   (int)dut->obs_dmaMem_wvalid, (int)dut->obs_dmaMem_wready,
                   (int)dut->obs_dmaMem_bvalid, (int)dut->obs_dmaMem_bready,
                   (int)dut->io_mem_ar_arvalid, (int)dut->io_mem_ar_arready,
                   (int)dut->io_mem_r_rvalid, (int)dut->io_mem_r_rready, (int)dut->io_mem_r_rlast);
            advance();
        }
    }

    long guard = 0;
    for (;;) {
        uint32_t st = 0;
        if (!opRead(DMA_STATUS, &st, &r, "轮询 CH_STATUS")) return false;
        if (st & 0x1u) { printf("    完成：CH_STATUS=0x%X（done_sticky）cyc=%llu\n", st, (unsigned long long)cyc); break; }
        if (st & 0x2u) { printf("  [FAIL] %s: 引擎报 err（CH_STATUS=0x%X）\n", tag, st); nFail++; return false; }
        if (st & 0x4u) { printf("  [FAIL] %s: 引擎报 aborted（CH_STATUS=0x%X）\n", tag, st); nFail++; return false; }
        if (++guard > 200000) { printf("  [FAIL] %s: 完成超时\n", tag); nFail++; return false; }
    }
    return true;
}

// ---------------- J1：逐字节 ----------------
static void j1_copy(const char* tag, uint32_t src, uint32_t dst, uint32_t len) {
    printf("=== J1[%s] 胶合层 DMA COPY 逐字节（SRC=0x%X → DST=0x%X，%u B）===\n", tag, src, dst, len);
    long ar0 = nMemAr, aw0 = nMemAw, w0 = nMemW;
    if (!runCopy(src, dst, len, tag)) return;
    // 目标区逐字节 == 源区（源区仍是**预载图案** ⇒ 同时证明"源未被改"）
    long bad = 0, first = -1, srcBad = 0;
    for (uint32_t i = 0; i < len; ++i) {
        if (mem[(dst + i) & (MEM_BYTES - 1)] != expectByte(src + i)) { bad++; if (first < 0) first = (long)i; }
        if (mem[(src + i) & (MEM_BYTES - 1)] != expectByte(src + i)) srcBad++;
    }
    printf("  DST_vs_SRC_BAD=%ld FIRST=%ld | SRC_UNCHANGED_BAD=%ld\n", bad, first, srcBad);
    if (bad)    fail("J1 目标区与源区不逐字节相等");
    if (srcBad) fail("J1 源区被改动（应原样）");
    uint8_t r = 0; uint32_t by = 0;
    if (!opRead(DMA_BYTES, &by, &r, "读 CH_BYTES")) return;
    printf("  CH_BYTES=%u（期望 %u）| io_mem 本次增量 AR=%ld AW=%ld W=%ld\n",
           by, len, nMemAr - ar0, nMemAw - aw0, nMemW - w0);
    if (by != len) fail("J1 CH_BYTES != LEN");
    if (!bad && !srcBad && by == len) ok("J1 COPY 逐字节正确 + 源未改 + 记账对");
    // J2：master port + 仲裁被真实驱动
    if (nMemAr - ar0 <= 0 || nMemAw - aw0 <= 0 || nMemW - w0 <= 0) fail("J2 io_mem 未被 DMA 驱动（master port/仲裁没通）");
    else ok("J2 DMA 经 §3.5 真实驱动 io_mem（AR/AW/W 计数均 > 0）");
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vpbus_dma_top;
    for (uint32_t a = 0; a < MEM_BYTES; ++a) mem[a] = expectByte(a);
    setCpuIoIdle(); dut->clock = 0;
    doReset();

    printf("DMA 引擎「并入 SoC 后」胶合层判决装置（--top-module pbus_dma_top = glue + DmaEngine）\n");
    printf("窗 DMA=0x%08X（256 B）；错窗基址=0x%08X\n", DMA_BASE, WRONG_BASE);

    // ---- J2a：CSR 窗可达（活体常数）----
    {
        uint32_t id = 0; uint8_t r = 0;
        if (opRead(DMA_GBL_ID, &id, &r, "读 GBL_ID")) {
            printf("  GBL_ID=0x%08X（期望 0x%08X，\"YDMA\"）rresp=%d\n", id, GBL_ID_CONST, (int)r);
            if (id == GBL_ID_CONST) ok("J2 CSR 窗在 0xF000_6000 可达（GBL_ID 活体）");
            else fail("J2 GBL_ID 读回不符（CSR 窗不通）");
        }
        uint32_t cid = 0;
        if (opRead(DMA_ID, &cid, &r, "读 CH_ID")) {
            printf("  CH_ID=0x%08X（期望 0x%08X）\n", cid, CH_ID_CONST);
            if (cid != CH_ID_CONST) fail("J2 CH_ID 读回不符");
        }
    }

    // ---- J1/J2：两笔 COPY（含回环）----
    j1_copy("A", SRC0, DST0, LEN0);
    j1_copy("B", SRC1, DST1, LEN1);

    // ---- J3：中断（irq 电平 + w1c 清源）----
    printf("=== J3 中断：完成后 irq=1；写 CH_STATUS w1c 后 irq=0 ===\n");
    settle();
    printf("  完成后 obs_dma_irq=%d（期望 1）\n", (int)dut->obs_dma_irq);
    if (!dut->obs_dma_irq) fail("J3 完成后 irq 未抬起");
    else ok("J3 完成后 irq 抬起（= glue.io_dmaIrq = PLIC 源 4 输入）");
    {
        uint8_t r = 0;
        if (opWrite(DMA_STATUS, 0x7u, &r, "写 CH_STATUS w1c")) {
            // 让 w1c 生效
            for (int i = 0; i < 4; ++i) tick();
            settle();
            printf("  w1c 后 obs_dma_irq=%d（期望 0）\n", (int)dut->obs_dma_irq);
            if (dut->obs_dma_irq) fail("J3 w1c 后 irq 未清");
            else ok("J3 CH_STATUS w1c 清源（irq 落 0）");
        }
    }

    // ---- J4：负对照（错窗基址 ⇒ CSR 不可达）----
    printf("=== J4 负对照：错窗基址 0x%08X（同偏移 +0x80）不可达 ===\n", WRONG_BASE);
    {
        long aw0 = nMemAw;
        uint32_t v = 0; uint8_t r = 0;
        if (opRead(WRONG_BASE + 0x80, &v, &r, "读错窗 GBL_ID")) {
            printf("  错窗读回=0x%08X rresp=%d（期望 != 0x%08X，且 DECERR=3）\n", v, (int)r, GBL_ID_CONST);
            if (v == GBL_ID_CONST) fail("J4 错窗基址竟读回 GBL_ID（窗口没被解码？）");
            else ok("J4 错窗基址读不回 GBL_ID");
            if (r != 3) fail("J4 错窗读未回 DECERR");
        }
        // 错窗上写 start，并确认**没有搬运**（GBL_DONE 不动）
        uint8_t wr = 0;
        if (opWrite(WRONG_BASE + 0x00, 1u, &wr, "写错窗 CH_CTRL.start")) {
            printf("  错窗写 bresp=%d（期望 DECERR=3）\n", (int)wr);
            for (int i = 0; i < 40; ++i) tick();
            uint32_t done = 0; uint8_t rr = 0;
            if (opRead(DMA_GBL_DONE, &done, &rr, "读 GBL_DONE")) {
                printf("  错窗写后 GBL_DONE=0x%X（期望 0）| io_mem AW 增量=%ld（期望 0）\n", done, nMemAw - aw0);
                if (done != 0)        fail("J4 错窗写竟触发了搬运");
                if (nMemAw - aw0 != 0) fail("J4 错窗写产生了内存写");
                if (done == 0 && nMemAw - aw0 == 0) ok("J4 错窗写被拒且零搬运");
            }
        }
    }

    // ---- 结构自检：读写互斥（§4 纪律②的运行时版本）----
    printf("=== 自检：io_mem 计数 AR=%ld AW=%ld W=%ld B=%ld rlast=%ld | AR/AW 同拍=%ld（期望 0）===\n",
           nMemAr, nMemAw, nMemW, nMemB, nMemRlast, nRwOverlap);
    if (nRwOverlap != 0) fail("AR 与 AW 同拍（读写互斥被破）");
    if (nMemB != nMemAw) fail("写 B 次数 != AW 次数");

    bool pass = (nFail == 0);
    printf("cyc=%llu  fail=%d\n", (unsigned long long)cyc, nFail);
    printf("=== %s ===\n", pass ? "TEST PASSED" : "TEST FAILED");
    dut->final();
    delete dut;
    return pass ? 0 : 1;
}
