// ===================== NPU 寄存器窗「CPU 侧写通路」判决装置 =====================
//
// 回答的问题（见 y1/reports/c3_area.md + 只读调查）：
//   PDS 综合把整个 NPU 剪掉了（`hostRegs_1/start_r… stuck at constant 0`、两引擎 FSM 全停、
//   `u_glue/npuTurn` 悬空、NPU 从未拿到 SoC 内存总线）。两种互斥解释：
//     (i) 真集成 bug —— CPU→glue→NPU 的 AxiLite **写通路**功能上是死的；
//     (ii) PDS artifact —— 通路本来是通的，只是 PDS 过度裁剪。
//   本装置把 NPU 寄存器窗的**真实从口**（`y1/gen/HostRegs.v`）拉进同一个 Verilator 网表
//   （见 `pbus_npu_top.v`，接线 = 板级 board/yeshen_mini_soc.v 那一段的等价物），然后像 CPU
//   那样驱动 pBus（= 核的 `LsuCachelessAxi4Plugin` 单拍主口 `io.cpuIo` → glue 内部 pBus），
//   在窗 `0xF000_C000` 上做**读/写/回读/负对照**。
//
// DUT：--top-module pbus_npu_top（= YeshenSocGlue + HostRegs；两个网表都只读、一字不改）。
//   单时钟 `clock` + **同步高有效** `reset`（HostRegs 侧是异步复位，但复位保持若干拍都清干净）。
//   静默：cpuFetch/cpuLsu/npuMem 不发起、loadMode=0、uart_rxd=1、sd_miso=1、ethIrq=0、npuIrq=0、gpio_in=0。
//   HostRegs.sched_busy/done/err 钉 0（本装置只测寄存器窗，不跑调度器）。
//
// 两段（关键结论就在「A 段红、B 段绿」的对比里）：
//   ▼ PHASE A（probe_strip_base=0）= **板级等价接线**：glue 把**整根** SoC 地址直给 HostRegs。
//        判据（= 契约本身）：
//          ① 读 ID(NPU+0x30) 必须 == 常数 0x594E5031（"YNP1"；HostRegs 活体证明）；
//          ② DESC_COUNT(NPU+0x38) 写-回读，**两种 AW/W 时序**：
//               (a) AW 与 W **同拍**举（= AxiLite4SlaveFactory 文档要求）；
//               (b) AW 先孤举 2 拍，再与 W 一起举（两路保持到握手）。
//             两路都要回读到写进去的值；并打印哪一路被接受 + AW 孤举那拍 awready 的电平（机制证据）。
//          ③ 负对照：写窗外未译码地址 / 窗内未映射偏移 → ID / DESC_COUNT 必须不变。
//        ⇒ 本段是**对 DUT 的判决**：通 ⇒ (ii)；不通 ⇒ (i)。
//   ▼ PHASE B（probe_strip_base=1）= **反事实探针**：只把递进 HostRegs 的地址剥成 16 KiB 窗内
//        偏移（`addr[13:0]`），其余一字不动。若本段全部转绿 ⇒ 唯一病因就是「地址基址没被剥掉」
//        （与 AW/W 时序无关、与窗口译码无关）。本段失败 ⇒ 装置自身有问题，要报出来。
//
// 装置自检：`io_mem_*` 只提供「永远 ready + 单拍 B/R=OKAY」的从方，防内存路挂死；三条 CPU 内存
//   主口与 NPU 内存主口都不发起 ⇒ 结尾断言内存三个计数器全 0。每个等待循环都有拍数上限。
#include "Vpbus_npu_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>

// ---------------- 地址（对到 src/YeshenSocGlue.scala:YeshenMap + y1/rtl/HostRegs.scala）----------------
#define NPU_BASE      0xF000C000u   // NPU 寄存器窗（16 KiB，掩码 0xFFFF_C000）
#define NPU_ID        (NPU_BASE + 0x30)   // ID          RO 常数 0x594E5031
#define NPU_DESC_ADDR (NPU_BASE + 0x34)   // DESC_ADDR   RW
#define NPU_DESC_CNT  (NPU_BASE + 0x38)   // DESC_COUNT  RW
#define NPU_ADDR_UNMAPPED_WIN (NPU_BASE + 0x200)  // 窗内未映射偏移（HostRegs 无 handler ⇒ 写被忽略）

#define ADDR_OUTSIDE  0xF0006100u   // 窗外的空段（DMA 窗 0x6000-0x60FF 之后；2026-10-31 改）⇒ 未译码 DECERR
#define ID_CONST      0x594E5031u   // "YNP1"

static Vpbus_npu_top* dut = nullptr;
static uint64_t cyc = 0;
static const int CAP = 64;
static int nFail = 0;

static void fail(const char* what) { printf("  [FAIL] %s\n", what); nFail++; }

// ---------------- 观测 glup 送出的 NPU 窗地址（组合透传）----------------
static uint32_t g_lastNpuArAddr = 0, g_lastNpuAwAddr = 0;
static int      g_npuArSeen = 0, g_npuAwSeen = 0;

// ---------------- 从方模型（内存 / ETH）：只做「永不挂死」的兜底 ----------------
static int     g_memAr = 0, g_memAw = 0, g_memW = 0;
static uint8_t mem_bvalid = 0, mem_rvalid = 0;
static void memSlavePostEdge() {
    if (mem_bvalid && dut->io_mem_b_bready) mem_bvalid = 0;
    if (mem_rvalid && dut->io_mem_r_rready) mem_rvalid = 0;
    if (dut->io_mem_aw_awvalid && dut->io_mem_aw_awready) g_memAw++;
    if (dut->io_mem_w_wvalid  && dut->io_mem_w_wready)  { g_memW++; mem_bvalid = 1; }
    if (dut->io_mem_ar_arvalid && dut->io_mem_ar_arready) { g_memAr++; mem_rvalid = 1; }
    dut->io_mem_b_bvalid = mem_bvalid;
    dut->io_mem_r_rvalid = mem_rvalid;
}
static int     g_ethAwFire = 0, g_ethWFire = 0, g_ethArFire = 0;
static uint8_t eth_bvalid = 0, eth_rvalid = 0;
static void ethSlavePostEdge() {
    if (eth_bvalid && dut->io_ethAxi_bready) eth_bvalid = 0;
    if (eth_rvalid && dut->io_ethAxi_rready) eth_rvalid = 0;
    if (dut->io_ethAxi_awvalid && dut->io_ethAxi_awready) g_ethAwFire++;
    if (dut->io_ethAxi_wvalid  && dut->io_ethAxi_wready)  { g_ethWFire++; eth_bvalid = 1; }
    if (dut->io_ethAxi_arvalid && dut->io_ethAxi_arready) { g_ethArFire++; eth_rvalid = 1; }
    dut->io_ethAxi_bvalid = eth_bvalid;
    dut->io_ethAxi_rvalid = eth_rvalid;
}

// ---------------- 时钟：组合采样（settle）与推进（advance）分两步 ----------------
static void settle() {
    dut->eval();
    if (dut->obs_npuAxi_arvalid) { g_npuArSeen++; g_lastNpuArAddr = dut->obs_npuAxi_araddr; }
    if (dut->obs_npuAxi_awvalid) { g_npuAwSeen++; g_lastNpuAwAddr = dut->obs_npuAxi_awaddr; }
}
static void advance() {
    dut->clock = 1; dut->eval();
    memSlavePostEdge();
    ethSlavePostEdge();
    dut->clock = 0; dut->eval();
    cyc++;
}
static void tick() { settle(); advance(); }

static void setCpuIoIdle() {
    dut->io_cpuIo_awvalid = 0; dut->io_cpuIo_awaddr = 0; dut->io_cpuIo_awsize = 2;
    dut->io_cpuIo_awcache = 0; dut->io_cpuIo_awprot = 0;
    dut->io_cpuIo_wvalid  = 0; dut->io_cpuIo_wdata  = 0; dut->io_cpuIo_wstrb = 0xF; dut->io_cpuIo_wlast = 1;
    dut->io_cpuIo_arvalid = 0; dut->io_cpuIo_araddr = 0; dut->io_cpuIo_arsize = 2;
    dut->io_cpuIo_arcache = 0; dut->io_cpuIo_arprot = 0;
    dut->io_cpuIo_bready  = 1; dut->io_cpuIo_rready = 1;
}

// ---------------- 读：AR 稳定 → 等 arready → 等 rvalid（posedge 前采样）----------------
static bool opRead(uint32_t addr, uint32_t* data, uint8_t* resp, bool* rlast, const char* tag) {
    g_npuArSeen = 0; g_lastNpuArAddr = 0;
    bool accepted = false;
    for (int k = 0; k < CAP && !accepted; ++k) {
        dut->io_cpuIo_arvalid = 1; dut->io_cpuIo_araddr = addr;
        dut->io_cpuIo_arsize = 2;  dut->io_cpuIo_arcache = 0; dut->io_cpuIo_arprot = 0;
        settle();
        accepted = (dut->io_cpuIo_arready != 0);
        advance();
    }
    if (!accepted) { printf("  [FAIL] %s: AR 握手超时（>%d 拍）\n", tag, CAP); nFail++; return false; }
    dut->io_cpuIo_arvalid = 0;

    bool got = false;
    for (int k = 0; k < CAP && !got; ++k) {
        settle();
        if (dut->io_cpuIo_rvalid) {
            *data = (uint32_t)dut->io_cpuIo_rdata; *resp = (uint8_t)dut->io_cpuIo_rresp;
            *rlast = (bool)dut->io_cpuIo_rlast; got = true;
        }
        advance();
    }
    if (!got) { printf("  [FAIL] %s: R 超时（>%d 拍）\n", tag, CAP); nFail++; return false; }
    return true;
}

// ---------------- 写：可调 AW/W 相对时序 ----------------
//   stagger==0：AW 与 W **同拍**举（= AxiLite4SlaveFactory 文档要求 / = 现有 opWrite 口径）
//   stagger==k：AW 先孤举 k 拍（W 不举），再与 W 一起举；两路都**保持**到各自 ready
//   awAloneAwReady：记录「AW 孤举那一拍」io_cpuIo_awready 的实测电平（=-1 表示没有该相位）
static bool opWriteStagger(uint32_t addr, uint32_t data, int stagger, uint8_t* resp,
                           int* awAloneAwReady, int* wAloneWReady, const char* tag) {
    g_npuAwSeen = 0; g_lastNpuAwAddr = 0;
    bool aw = false, w = false;
    *awAloneAwReady = -1; *wAloneWReady = -1;
    int k = 0;
    for (; k < CAP && !(aw && w); ++k) {
        bool driveAw = !aw;
        bool driveW  = (!w) && (k >= stagger);
        dut->io_cpuIo_awvalid = driveAw ? 1 : 0;
        dut->io_cpuIo_awaddr  = addr; dut->io_cpuIo_awsize = 2;
        dut->io_cpuIo_awcache = 0;    dut->io_cpuIo_awprot = 0;
        dut->io_cpuIo_wvalid  = driveW ? 1 : 0;
        dut->io_cpuIo_wdata   = data; dut->io_cpuIo_wstrb = 0xF; dut->io_cpuIo_wlast = 1;
        settle();
        if (driveAw && !driveW && *awAloneAwReady < 0) *awAloneAwReady = dut->io_cpuIo_awready ? 1 : 0;
        if (driveW && !driveAw && *wAloneWReady  < 0) *wAloneWReady  = dut->io_cpuIo_wready  ? 1 : 0;
        if (!aw && dut->io_cpuIo_awready) aw = true;
        if (!w  && dut->io_cpuIo_wready)  w  = true;
        advance();
    }
    if (!(aw && w)) { printf("  [FAIL] %s: AW/W 握手超时（>%d 拍）\n", tag, CAP); nFail++; return false; }
    dut->io_cpuIo_awvalid = 0; dut->io_cpuIo_wvalid = 0;

    bool got = false;
    for (int j = 0; j < CAP && !got; ++j) {
        settle();
        if (dut->io_cpuIo_bvalid) { *resp = (uint8_t)dut->io_cpuIo_bresp; got = true; }
        advance();
    }
    if (!got) { printf("  [FAIL] %s: B 超时（>%d 拍）\n", tag, CAP); nFail++; return false; }
    return true;
}

static void expectU32(const char* what, uint32_t got, uint32_t exp) {
    printf("    %-54s got=0x%08X exp=0x%08X  %s\n", what, got, exp, got == exp ? "OK" : "MISMATCH");
    if (got != exp) fail(what);
}
static void expectInt(const char* what, int got, int exp) {
    printf("    %-54s got=%d exp=%d  %s\n", what, got, exp, got == exp ? "OK" : "MISMATCH");
    if (got != exp) fail(what);
}

// ===================== 判据 ① 读 ID =====================
static void case1_id(const char* phase) {
    printf("=== ①[%s] 读 NPU 窗 ID（0x%08X+0x30）—— 必须回常数 0x594E5031 ===\n", phase, NPU_BASE);
    uint32_t v = 0; uint8_t r = 0; bool l = 0;
    if (!opRead(NPU_ID, &v, &r, &l, "NPU ID 读")) return;
    printf("   glue 送进 NPU 从口的 arvalid=%d araddr=0x%08X（= 发给下游的真实地址）\n",
           g_npuArSeen, g_lastNpuArAddr);
    printf("   实测 ID = 0x%08X（rresp=%d rlast=%d）  期望 0x%08X\n", v, (int)r, (int)l, ID_CONST);
    expectInt("ID 读 rresp（OKAY=0）", (int)r, 0);
    expectU32("ID 读回 == 0x594E5031", v, ID_CONST);
}

// ===================== 判据 ② DESC_COUNT 写-回读（两种 AW/W 时序）=====================
static void runWriteReadback(const char* phase, uint32_t regAddr, uint32_t payload, int stagger,
                             const char* label) {
    printf("  ---- [%s] %s（stagger=%d）----\n", phase, label, stagger);
    uint8_t wr = 0; int awAlone = -1, wAlone = -1;
    if (!opWriteStagger(regAddr, payload, stagger, &wr, &awAlone, &wAlone, label)) return;
    printf("     写: bresp=%d | glue 送出的 awvalid=%d awaddr=0x%08X\n",
           (int)wr, g_npuAwSeen, g_lastNpuAwAddr);
    printf("     机制: AW 孤举相位 io_cpuIo_awready=%d | W 孤举相位 io_cpuIo_wready=%d\n",
           awAlone, wAlone);
    expectInt("  写 bresp（OKAY=0）", (int)wr, 0);

    uint32_t v = 0; uint8_t r = 0; bool l = 0;
    if (!opRead(regAddr, &v, &r, &l, label)) return;
    // 直接观测 HostRegs 里对应的那一个导出寄存器（按写入的地址选）
    uint32_t obsDirect = 0; const char* obsName = "HostRegs.?";
    if      (regAddr == NPU_DESC_CNT ) { obsDirect = (uint32_t)dut->obs_hreg_desc_count; obsName = "HostRegs.desc_count"; }
    else if (regAddr == NPU_DESC_ADDR) { obsDirect = (uint32_t)dut->obs_hreg_desc_addr;  obsName = "HostRegs.desc_addr";  }
    printf("     直接观测 %s = 0x%08X\n", obsName, obsDirect);
    expectU32("  读回 == 写入值", v, payload);
    char buf[128]; snprintf(buf, sizeof(buf), "  %s 寄存器 == 写入值", obsName);
    expectU32(buf, obsDirect, payload);
}

static void case2_desc_count_both_timings(const char* phase) {
    printf("=== ②[%s] DESC_COUNT(0x%08X) 写-回读：AW/W 两种时序 ===\n", phase, NPU_DESC_CNT);
    runWriteReadback(phase, NPU_DESC_CNT, 0x0000012Fu, 0, "(a) AW+W 同拍");
    runWriteReadback(phase, NPU_DESC_CNT, 0x0000C0DEu, 2, "(b) AW 先 2 拍、W 后到");
    runWriteReadback(phase, NPU_DESC_ADDR, 0x1A2B3C40u, 0, "DESC_ADDR RW（同拍，异载荷）");
}

// ===================== 判据 ③ 负对照 =====================
static void case3_negative(const char* phase) {
    printf("=== ③[%s] 负对照：写窗外/窗内未映射地址，NPU 寄存器必须不变 ===\n", phase);
    uint32_t baseDC = 0; uint8_t r = 0; bool l = 0;
    if (!opRead(NPU_DESC_CNT, &baseDC, &r, &l, "读 DESC_COUNT 基线")) return;
    printf("   基线 DESC_COUNT = 0x%08X\n", baseDC);

    struct { uint32_t addr; const char* name; } negs[] = {
        { ADDR_OUTSIDE,            "窗外未译码 0xF0006100" },
        { NPU_ADDR_UNMAPPED_WIN,   "窗内未映射偏移 NPU+0x200" },
    };
    for (unsigned i = 0; i < sizeof(negs)/sizeof(negs[0]); ++i) {
        uint8_t wr = 0; int a = -1, w = -1;
        printf("  -- [%s] 负写 %s（addr=0x%08X）--\n", phase, negs[i].name, negs[i].addr);
        if (!opWriteStagger(negs[i].addr, 0xDEADBEEFu, 0, &wr, &a, &w, negs[i].name)) return;
        printf("     写 bresp=%d（窗外未译码=DECERR=3；窗内未映射=OKAY 但应被忽略）\n", (int)wr);
        uint32_t dc = 0, id = 0;
        if (!opRead(NPU_DESC_CNT, &dc, &r, &l, "负写后读 DESC_COUNT")) return;
        if (!opRead(NPU_ID,       &id, &r, &l, "负写后读 ID"))         return;
        printf("     DESC_COUNT=0x%08X ID=0x%08X\n", dc, id);
        expectU32("  负写后 DESC_COUNT 不变", dc, baseDC);
        expectU32("  负写后 ID 仍为常数", id, ID_CONST);
    }
}

// ===================== 初始化 + 复位 =====================
static void initDut() {
    dut->clock = 0; dut->reset = 1;
    dut->probe_strip_base = 0;             // 默认 = 板级等价接线
    setCpuIoIdle();
    dut->io_mem_ar_arready = 1;
    dut->io_mem_aw_awready = 1; dut->io_mem_w_wready = 1;
    dut->io_mem_r_rid = 0; dut->io_mem_r_rdata = 0; dut->io_mem_r_rresp = 0;
    dut->io_mem_r_rlast = 1; dut->io_mem_r_rvalid = 0;
    dut->io_mem_b_bid = 0; dut->io_mem_b_bresp = 0; dut->io_mem_b_bvalid = 0;
    dut->io_ethAxi_awready = 1; dut->io_ethAxi_wready = 1;
    dut->io_ethAxi_bvalid = 0;  dut->io_ethAxi_bresp = 0;
    dut->io_ethAxi_arready = 1; dut->io_ethAxi_rvalid = 0;
    dut->io_ethAxi_rdata = 0;   dut->io_ethAxi_rresp = 0;
}
static void doReset() {
    setCpuIoIdle();
    dut->reset = 1;
    for (int i = 0; i < 8; ++i) tick();
    dut->reset = 0;
    for (int i = 0; i < 4; ++i) tick();
    mem_bvalid = 0; mem_rvalid = 0; eth_bvalid = 0; eth_rvalid = 0;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vpbus_npu_top;
    initDut();
    doReset();

    printf("NPU 寄存器窗「CPU 侧写通路」判决装置（--top-module pbus_npu_top = glue + HostRegs）\n");
    printf("窗 NPU=0x%08X（ID+0x30 / DESC_ADDR+0x34 / DESC_COUNT+0x38）；负对照窗外=0x%08X\n",
           NPU_BASE, ADDR_OUTSIDE);

    // ---------------------------------------------------------------------
    // PHASE A：板级等价接线（probe_strip_base=0）—— 对 DUT 的判决
    // ---------------------------------------------------------------------
    printf("\n######## PHASE A：板级等价接线（probe_strip_base=0）—— 对 DUT 的判决 ########\n");
    dut->probe_strip_base = 0;
    doReset();
    case1_id("A板级");
    case2_desc_count_both_timings("A板级");
    case3_negative("A板级");

    int nFailA = nFail;

    // ---------------------------------------------------------------------
    // PHASE B：反事实探针（probe_strip_base=1）—— 只把地址剥成窗内偏移
    // ---------------------------------------------------------------------
    printf("\n######## PHASE B：反事实探针（probe_strip_base=1，剥掉 16KiB 窗基址）—— 归因 ########\n");
    dut->probe_strip_base = 1;
    doReset();
    case1_id("B剥基址");
    case2_desc_count_both_timings("B剥基址");
    case3_negative("B剥基址");

    // ---- 装置自检：内存从方从未被用到 ----
    printf("=== 装置自检：io_mem_* 事务计数（期望全 0；io_ethAxi 无关）===\n");
    printf("   io_mem: ar=%d aw=%d w=%d | io_ethAxi: ar=%d aw=%d w=%d\n",
           g_memAr, g_memAw, g_memW, g_ethArFire, g_ethAwFire, g_ethWFire);
    expectInt("io_mem AR 事务数", g_memAr, 0);
    expectInt("io_mem AW 事务数", g_memAw, 0);
    expectInt("io_mem W  事务数", g_memW, 0);

    printf("\n=== 判决汇总 ===\n");
    printf("   PHASE A（板级等价接线）fail=%d ⇒ 写通路 %s\n",
           nFailA, nFailA == 0 ? "通（支持解释 ii：PDS artifact）" : "死（支持解释 i：真集成 bug）");
    printf("   PHASE B（剥掉 16KiB 窗基址）fail=%d ⇒ 剥基址后写通路 %s\n",
           nFail - nFailA, (nFail - nFailA) == 0 ? "通（病因 = 地址基址没剥，与 AW/W 时序无关）" : "仍不通（装置/结论需复核）");

    bool pass = (nFail == 0);
    printf("cyc=%llu  fail=%d\n", (unsigned long long)cyc, nFail);
    printf("=== %s ===\n", pass ? "TEST PASSED" : "TEST FAILED");
    dut->final();
    delete dut;
    return pass ? 0 : 1;
}
