// ============================================================================================
// `sdloader_dma_top` 判决装置（Verilator）：**SD 装载器当 DMA 引擎的第一个真客户**（Phase-2c）。
//
// DUT：--top-module sdloader_dma_top = `YeshenSocGlue`（内含 SdLoader/SdSpi）+ `DmaEngine`
//      （两个网表都**只读、一字不改**；接线见 sdloader_dma_top.v 的头部）。
//
// ★ 本装置**同时**实例化装置侧的 **SPI SD 卡模型**（CMD0/8/55+ACMD41/58/17，数据源 = 卡镜像）
//   与 **64bit AXI4 内存模型** —— 这就是"最小 SPI/SD 卡模型 harness"这条路的落点。为什么选它
//   （而不是"给装载器喂 wr_valid/wr_data 打桩"）：D3 要证的是"**同一张卡上的同一份镜像**，改走
//   引擎之后装载结果逐字节不变"。打桩会把 SPI 读块时序/表解析/字节反转这三段承重逻辑绕掉 ⇒
//   证不到"客户端切换是安全的"。SPI 卡模型是现成的（`sim/sdloader/tb_sdloader.cpp` 已用它抓出过
//   2026-10-05 的字节反转 bug），代价低、覆盖真、可复用，所以直接复用该惯用法。
//
// 判据（每条都能翻红；★ = 本相承重）：
//   J1【正·通路 A 基线】`sdDmaMode=0`（装载器**直写内存**）：卡镜像 → DDR **逐字节**正确、放核。
//   J2【★ D3 核心】`sdDmaMode=1`（装载器**喂引擎**）与通路 A 的装载结果**逐字节相同**（= D3）。
//   J3【★ 切换是真的】通路 A：CSR 主口/喂流**一笔都没有**、`owner` 从不等于 7（绕过引擎）；
//        通路 B：CSR 主口被**装载器**举过、`wr_valid_0` 举过、§3.5 `owner==7`(OWN_DMA_WR) 出现过
//        （⇒ 字节确实经过了引擎，不是"看起来像"）。
//   J4【记账】两通路写进 `io.mem` 的 **W 拍数 == 镜像字节数/8**、B 次数 == AW 次数、AR 恒 0、
//        `wstrb` 恒 0xFF、放核状态 `sd_state==3` 且 `sd_err==0`。
//   J5【负对照·判据自检】`SD_NC=1` 把通路 A 快照的第 13 字节翻一位 ⇒ **J2 必须翻红**（证明"逐字节
//        比较"这个判据本身有分辨力，不是恒绿的橡皮图章）。
//
// 地址口径（本装置与板级 DDR 通路的等价性）：内存模型按 **`addr & 0x3FFF_FFFF`** 索引
//   —— 这正是 `src/soc/DDR3Bridge.scala` 对 AXI 地址的取法（`awaddr(29,2)` 为字地址 ⇒ bit31/30 被丢）。
//   于是卡上表的 `0x8000_0000` 与引擎 28bit 主口的 `0x0000_0000` 落在**同一个 DDR 字节**上
//   （板级 DDR 基址 0x8000_0000 在这条通路上是**纯别名**）⇒ 两条通路的镜像**直接可比**。
//
// 用法：./sdloader_dma_sim [timeout_cycles]      （缺省 40e6 拍）
// ============================================================================================
#include "Vsdloader_dma_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <cstring>
#include <map>
#include <vector>

static Vsdloader_dma_top *dut;
static uint64_t cyc = 0;
static int nFail = 0;
static void fail(const char *w) { printf("  [FAIL] %s\n", w); nFail++; }
static void ok(const char *w)   { printf("  [ok]   %s\n", w); }

// ---------------------------------------------------------------- 卡镜像
static std::vector<uint8_t> g_card;
static bool load_card(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return false;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    g_card.resize((size_t)n);
    size_t got = fread(g_card.data(), 1, (size_t)n, f);
    fclose(f);
    return got == (size_t)n;
}

// ---------------------------------------------------------------- DDR 内存模型（AXI4 从方）
// 索引口径 = `addr & 0x3FFF_FFFF`（见文件头："板级 DDR 基址是纯别名"）
#define DDR_ALIAS_MASK 0x3FFFFFFFu
static std::map<uint32_t, uint8_t> g_mem;
static uint32_t alias(uint32_t a) { return a & DDR_ALIAS_MASK; }
static uint64_t mem64(uint32_t a) {
    uint64_t v = 0;
    for (int b = 0; b < 8; ++b) { auto it = g_mem.find(alias(a + b)); v |= (uint64_t)(it == g_mem.end() ? 0 : it->second) << (8 * b); }
    return v;
}
static void put8(uint32_t a, uint8_t d) { g_mem[alias(a)] = d; }

// ---- 计数器（每通路清零）----
static long cAr = 0, cAw = 0, cW = 0, cB = 0, cWlast = 0, cRlast = 0;
static long cBRespErr = 0, cWStrbBad = 0, cAwSizeBad = 0, cBstraddle = 0;
static long eCsrAw = 0, eCsrAr = 0, eWrValid = 0, eWrReady = 0, eOwnerDma = 0, eOwnerAny = 0;
static uint32_t csrAwAddr = 0;
static long nWrCtrl = 0, nWrDst = 0, nWrLen = 0, nWrMode = 0, nWrOther = 0, nPoll = 0, csrV = 0;
static uint32_t lastPoll = 0;

// ---- 从方状态 ----
static int rdState = 0; static uint32_t rdAddr = 0; static int rdBeatsLeft = 0;
static int wrActive = 0; static uint32_t wrAddr = 0; static int wrBeatsLeft = 0; static int bPend = 0;
static uint32_t wrBase = 0;

static void spi_step();                       // 前向声明（SPI 卡模型在下面定义，advance 要用它）
static uint8_t spi_tx = 0xFF;                 // 卡模型当前移出的字节（settle 每拍把它摆到 MISO）

static void memComb() {
    dut->io_mem_ar_arready = (rdState == 0) ? 1 : 0;
    dut->io_mem_aw_awready = (wrActive == 0 && bPend == 0) ? 1 : 0;
    dut->io_mem_w_wready   = (wrActive && !bPend) ? 1 : 0;
    dut->io_mem_r_rvalid   = (rdState == 1) ? 1 : 0;
    dut->io_mem_r_rdata    = (rdState == 1) ? mem64(rdAddr) : 0;
    dut->io_mem_r_rlast    = (rdState == 1 && rdBeatsLeft == 1) ? 1 : 0;
    dut->io_mem_r_rid = 0; dut->io_mem_r_rresp = 0;
    dut->io_mem_b_bvalid = bPend ? 1 : 0; dut->io_mem_b_bid = 0;
    dut->io_mem_b_bresp = 0;
}

// 沿前快照（⚠️ 与 tb_dma_pbus.cpp 同一口径：握手判据用**边沿前**的 valid/ready）
struct SnapM {
    bool arv, arr; uint32_t araddr; int arlen;
    bool rv, rr, rlast;
    bool awv, awr; uint32_t awaddr; int awlen; int awsize;
    bool wv, wr; uint64_t wd; uint8_t wstrb; bool wlast;
    bool bv, br;
};
static SnapM sm;

static void settle() {
    dut->io_sd_miso = (spi_tx >> 7) & 1;      // 卡模型：本拍把 MISO 摆成当前要移出的位（MSB 先）
    memComb(); dut->eval();
    sm.arv = dut->io_mem_ar_arvalid; sm.arr = dut->io_mem_ar_arready;
    sm.araddr = dut->io_mem_ar_araddr; sm.arlen = (int)dut->io_mem_ar_arlen;
    sm.rv = dut->io_mem_r_rvalid; sm.rr = dut->io_mem_r_rready; sm.rlast = dut->io_mem_r_rlast;
    sm.awv = dut->io_mem_aw_awvalid; sm.awr = dut->io_mem_aw_awready;
    sm.awaddr = dut->io_mem_aw_awaddr; sm.awlen = (int)dut->io_mem_aw_awlen;
    sm.awsize = (int)dut->io_mem_aw_awsize;
    sm.wv = dut->io_mem_w_wvalid; sm.wr = dut->io_mem_w_wready;
    sm.wd = dut->io_mem_w_wdata; sm.wstrb = (uint8_t)dut->io_mem_w_wstrb; sm.wlast = dut->io_mem_w_wlast;
    sm.bv = dut->io_mem_b_bvalid; sm.br = dut->io_mem_b_bready;
}
static void postEdge() {
    if (sm.arv && sm.arr) { rdState = 1; rdAddr = sm.araddr; rdBeatsLeft = sm.arlen + 1; cAr++; }
    if (rdState == 1 && sm.rv && sm.rr) { if (sm.rlast) cRlast++; rdAddr += 8; if (--rdBeatsLeft == 0) rdState = 0; }
    if (sm.awv && sm.awr) {
        wrActive = 1; wrBase = sm.awaddr; wrAddr = sm.awaddr; wrBeatsLeft = sm.awlen + 1; cAw++;
        if (sm.awsize != 3) cAwSizeBad++;
    }
    if (wrActive && !bPend && sm.wv && sm.wr) {
        if (sm.wstrb != 0xFF) cWStrbBad++;
        for (int b = 0; b < 8; ++b) if ((sm.wstrb >> b) & 1) put8(wrAddr + b, (uint8_t)(sm.wd >> (8 * b)));
        wrAddr += 8; cW++;
        if (sm.wlast) cWlast++;
        if (--wrBeatsLeft == 0) {
            bPend = 1;
            if (!sm.wlast) cBstraddle++;                 // wlast 与 awlen 不一致
        }
    }
    if (bPend && sm.bv && sm.br) { bPend = 0; wrActive = 0; cB++; }
    // 观测计数（只读）
    if (dut->obs_dmaAxi_awvalid) eCsrAw++;
    // CSR 事务统计（只作证据）：按地址记写次数 + 轮询次数与**最后一次**读回值
    if (dut->obs_dmaAxi_awvalid && dut->obs_dmaAxi_awready) { csrAwAddr = dut->obs_dmaAxi_awaddr & 0xFF; }
    if (dut->obs_dmaAxi_wvalid && dut->obs_dmaAxi_wready) {
        if (csrAwAddr == 0x00) nWrCtrl++;
        else if (csrAwAddr == 0x0C) nWrDst++;
        else if (csrAwAddr == 0x10) nWrLen++;
        else if (csrAwAddr == 0x14) nWrMode++;
        else nWrOther++;
        if (csrV < 24) { printf("      [csr] WR 0x%02X <= 0x%08X\n", csrAwAddr, dut->obs_dmaAxi_wdata); csrV++; }
    }
    if (dut->obs_dmaAxi_rvalid) { nPoll++; lastPoll = dut->obs_dmaAxi_rdata; }
    if (dut->obs_dmaAxi_arvalid) eCsrAr++;
    if (dut->obs_wrValid0) eWrValid++;
    if (dut->obs_wrReady0) eWrReady++;
    if (dut->obs_glue_owner == 7) eOwnerDma++;
    if (dut->obs_glue_owner != 0) eOwnerAny++;
}
static void advance() { dut->clock = 1; dut->eval(); postEdge(); dut->clock = 0; dut->eval(); spi_step(); cyc++; }
static void tick() { settle(); advance(); }

// ---------------------------------------------------------------- SPI SD 卡模型（照抄 sim/sdloader/tb_sdloader.cpp）
static int      spi_bit = 0;
static uint8_t  spi_rx = 0;
static int      spi_bitsLeft = 8;
static int      g_csHi = 1;
static int      g_csViol = 0;
static int      spi_stage = 0;
static uint8_t  spi_cmd = 0;
static uint32_t spi_arg = 0;
static std::deque<uint8_t> spi_out;
// ★ CMD18 多块读：g_multi=1 时模型在每块 514 字节后自动接上下一块的 0xFE 令牌；
//   CMD12 收尾把它清掉（与 SD SPI 的 READ_MULTIPLE_BLOCK 语义一致）。
static int      g_multi = 0;
static uint32_t g_baseLba = 0;
static uint32_t g_blkIdx = 0;
static int      spi_dataLeft = 0;
static uint32_t spi_dataPtr = 0;
static int      g_acmdBusy = 0;
static int      g_verbose = 0;
static int      spi_sckP = 0, spi_csP = 1;     // 上一拍的 SCK/CS（边沿检测；每通路复位）

static void start_multi_block() {
    spi_out.push_back(0xFE);
    spi_dataPtr = ((uint64_t)g_baseLba + g_blkIdx) * 512u;
    spi_dataLeft = 512 + 2;
}

static uint8_t spi_next() {
    if (!spi_out.empty()) { uint8_t b = spi_out.front(); spi_out.pop_front(); return b; }
    if (spi_dataLeft > 0) {
        spi_dataLeft--;
        uint8_t b = (spi_dataPtr < g_card.size()) ? g_card[spi_dataPtr] : 0xFF;
        spi_dataPtr++;
        if (spi_dataLeft == 0 && g_multi) { g_blkIdx++; start_multi_block(); }
        return b;
    }
    return 0xFF;
}
static void spi_load_byte() { spi_tx = spi_next(); spi_bitsLeft = 8; }

static void spi_handle_byte(uint8_t b) {
    if (spi_stage == 0) {
        if ((b & 0xC0) == 0x40) {
            if (!g_csHi) { g_csViol++; if (g_csViol <= 3) printf("[card] CS-FRAMING VIOLATION\n"); }
            g_csHi = 0;
            spi_cmd = b & 0x3F; spi_arg = 0; spi_stage = 1;
        }
        return;
    }
    if (spi_stage <= 4) { spi_arg = (spi_arg << 8) | b; spi_stage++; return; }
    switch (spi_cmd) {
      case 0:  spi_out.push_back(0x01); break;
      case 8:  spi_out.push_back(0x01); spi_out.push_back(0x00); spi_out.push_back(0x00);
               spi_out.push_back(0x01); spi_out.push_back(0xAA); break;
      case 55: spi_out.push_back(0x01); break;
      case 41: if (g_acmdBusy > 0) { spi_out.push_back(0x01); g_acmdBusy--; } else spi_out.push_back(0x00); break;
      case 58: spi_out.push_back(0x00); spi_out.push_back(0xC0); spi_out.push_back(0xFF);
               spi_out.push_back(0x80); spi_out.push_back(0x00); break;
      case 17: spi_out.push_back(0x00); spi_out.push_back(0xFF); spi_out.push_back(0xFE);
               spi_dataPtr = spi_arg * 512u; spi_dataLeft = 512 + 2; break;
      // ★ CMD18：R1 之后连续发块（每块 0xFE + 512B + 2B），直到 CMD12 或 CS 抬起
      case 18: spi_out.push_back(0x00);
               g_multi = 1; g_baseLba = spi_arg; g_blkIdx = 0; start_multi_block(); break;
      // ★ CMD12：停多块读，回 R1=0x00
      case 12: g_multi = 0; spi_dataLeft = 0; spi_out.push_back(0x00); break;
      default: spi_out.push_back(0x04); break;
    }
    if (g_verbose >= 1) printf("[card] cmd=%u arg=0x%08X\n", spi_cmd, spi_arg);
    spi_stage = 0;
}

static void spi_step() {
    int sckN = dut->io_sd_sck, csN = dut->io_sd_cs_n, mos = dut->io_sd_mosi;
    if (csN && !spi_csP) { spi_bit = 0; spi_rx = 0; spi_stage = 0; spi_out.clear(); spi_dataLeft = 0; g_multi = 0; g_csHi = 1; spi_load_byte(); }
    if (!csN) {
        if (sckN && !spi_sckP) {
            spi_rx = (uint8_t)((spi_rx << 1) | (mos & 1));
            if (++spi_bit == 8) { spi_bit = 0; spi_handle_byte(spi_rx); spi_rx = 0; }
        } else if (!sckN && spi_sckP) {
            spi_tx = (uint8_t)(spi_tx << 1);
            if (--spi_bitsLeft == 0) spi_load_byte();
        }
    }
    spi_sckP = sckN; spi_csP = csN;
}

// ---------------------------------------------------------------- 卡表 → 期望字节
struct Ent { uint32_t addr, lba, nblk; };
static std::vector<Ent> g_ents;

static uint32_t be32(size_t o) {
    return ((uint32_t)g_card[o] << 24) | ((uint32_t)g_card[o + 1] << 16) | ((uint32_t)g_card[o + 2] << 8) | g_card[o + 3];
}

// 通路快照：每个表项区间逐字节抓下来
static std::vector<uint8_t> snapshot_entries() {
    std::vector<uint8_t> v;
    for (auto &e : g_ents)
        for (uint32_t i = 0; i < e.nblk * 512u; ++i) {
            auto it = g_mem.find(alias(e.addr + i));
            v.push_back(it == g_mem.end() ? 0 : it->second);
        }
    return v;
}

static void reset_counters() {
    cAr = cAw = cW = cB = cWlast = cRlast = 0;
    cBRespErr = cWStrbBad = cAwSizeBad = cBstraddle = 0;
    eCsrAw = eCsrAr = eWrValid = eWrReady = eOwnerDma = eOwnerAny = 0;
    nWrCtrl = nWrDst = nWrLen = nWrMode = nWrOther = nPoll = csrV = 0; lastPoll = 0;
}

static void doReset(int sdDmaMode) {
    dut->io_loadMode = 1; dut->io_bootTimeout = 1000;
    dut->io_sdDmaMode = sdDmaMode;
    dut->io_sd_miso = 1;
    dut->io_mem_r_rvalid = 0; dut->io_mem_b_bvalid = 0;
    dut->reset = 1;
    for (int i = 0; i < 12; ++i) tick();
    dut->reset = 0;
    for (int i = 0; i < 6; ++i) tick();
    rdState = wrActive = bPend = 0;
    g_mem.clear();
    spi_bit = 0; spi_rx = 0; spi_tx = 0xFF; spi_bitsLeft = 8; g_csHi = 1; g_csViol = 0;
    spi_stage = 0; spi_cmd = 0; spi_arg = 0; spi_out.clear(); spi_dataLeft = 0; spi_dataPtr = 0; g_multi = 0;
    spi_sckP = 0; spi_csP = 1;
}

// 跑一趟装载：返回 0 = 正常放核；1 = 失败/超时
struct Pass {
    int      rc = 1;
    int      st = 0, err = 0;
    uint64_t cyc = 0;
    std::vector<uint8_t> img;
};
static Pass run_pass(int sdDmaMode, uint64_t maxCyc) {
    Pass p;
    doReset(sdDmaMode);
    reset_counters();
    int dbg = getenv("SD_DEBUG") ? atoi(getenv("SD_DEBUG")) : 0;
    int dbgN = 0;
    uint64_t c0 = cyc;
    while (cyc - c0 < maxCyc) {
        tick();
        if (dbg && dut->obs_dmaMem_awvalid && dbgN < dbg) {
            printf("    [dbg %3d] owner=%d rdBusy=%d | io_mem AW v/r=%d/%d W v/r=%d/%d B v/r=%d/%d | dMem AW v/r=%d/%d W v/r=%d/%d B v/r=%d/%d | wr_stream v/r=%d/%d\n",
                   dbgN++, (int)dut->obs_glue_owner, (int)dut->obs_glue_memRdBusy,
                   (int)dut->io_mem_aw_awvalid, (int)dut->io_mem_aw_awready,
                   (int)dut->io_mem_w_wvalid, (int)dut->io_mem_w_wready,
                   (int)dut->io_mem_b_bvalid, (int)dut->io_mem_b_bready,
                   (int)dut->obs_dmaMem_awvalid, (int)dut->obs_dmaMem_awready,
                   (int)dut->obs_dmaMem_wvalid, (int)dut->obs_dmaMem_wready,
                   (int)dut->obs_dmaMem_bvalid, (int)dut->obs_dmaMem_bready,
                   (int)dut->obs_wrValid0, (int)dut->obs_wrReady0);
        }
        int st = (int)dut->obs_sd_state;
        if (st == 4) { p.rc = 1; break; }
        if (st == 3) { p.rc = 0; break; }
    }
    for (int i = 0; i < 40; ++i) tick();        // 排空（放核后再多跑几拍，快照前后无在飞拍）
    p.st = (int)dut->obs_sd_state;
    p.err = (int)dut->obs_sd_err;
    p.cyc = cyc - c0;
    p.img = snapshot_entries();
    return p;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *img = getenv("SD_IMG") ? getenv("SD_IMG") : "../reglogs/sd_small.img";
    if (!load_card(img)) { printf("[FAIL] 打不开卡镜像 %s\n", img); return 2; }
    if (g_card.size() < 12 || memcmp(g_card.data(), "YSLD", 4) != 0) { printf("[FAIL] 卡镜像魔数不对\n"); return 2; }
    uint32_t nent = be32(4);
    if (nent < 1 || nent > 8) { printf("[FAIL] 卡表项数 %u 不合法\n", nent); return 2; }
    for (uint32_t i = 0; i < nent; ++i)
        g_ents.push_back(Ent{be32(8 + 12 * i), be32(12 + 12 * i), be32(16 + 12 * i)});
    uint64_t imgBytes = 0;
    printf("卡镜像 %s: %zu B = %zu 块, %u 个表项\n", img, g_card.size(), g_card.size() / 512, nent);
    for (auto &e : g_ents) {
        printf("  表项: DDR 0x%08X  lba %u  %u 块 (%u B)\n", e.addr, e.lba, e.nblk, e.nblk * 512u);
        imgBytes += (uint64_t)e.nblk * 512u;
    }
    uint64_t maxCyc = (argc > 1 ? strtoull(argv[1], nullptr, 0) : 40000000ULL);
    g_verbose = getenv("SD_VERBOSE") ? atoi(getenv("SD_VERBOSE")) : 0;

    dut = new Vsdloader_dma_top;
    dut->io_loadMode = 1; dut->io_sdDmaMode = 0; dut->io_sd_miso = 1;
    dut->clock = 0; dut->eval();

    printf("=== J1 通路 A（sdDmaMode=0：装载器**直写内存**）===\n");
    Pass A = run_pass(0, maxCyc);
    printf("  cyc=%llu state=%d err=%d | io_mem AR=%ld AW=%ld W=%ld B=%ld wlast=%ld | CSR-AW=%ld wr_stream v/r=%ld/%ld | owner==7 次数=%ld\n",
           (unsigned long long)A.cyc, A.st, A.err, cAr, cAw, cW, cB, cWlast, eCsrAw, eWrValid, eWrReady, eOwnerDma);
    long aAr = cAr, aAw = cAw, aW = cW, aB = cB, aCsrAw = eCsrAw, aWrV = eWrValid, aOwner = eOwnerDma;
    if (A.rc != 0) fail("J1 通路 A 未放核（state!=3）");
    if (A.err != 0) fail("J1 通路 A 报错（sd_err != 0）");
    if (A.st == 3 && A.err == 0) ok("J1 通路 A 放核且无错");

    printf("=== J2 通路 B（sdDmaMode=1：装载器**喂 DMA 引擎**）===\n");
    Pass B = run_pass(1, maxCyc);
    printf("  cyc=%llu state=%d err=%d | io_mem AR=%ld AW=%ld W=%ld B=%ld wlast=%ld | CSR-AW=%ld wr_stream v/r=%ld/%ld | owner==7 次数=%ld\n",
           (unsigned long long)B.cyc, B.st, B.err, cAr, cAw, cW, cB, cWlast, eCsrAw, eWrValid, eWrReady, eOwnerDma);
    printf("  CSR 明细：DST=%ld LEN=%ld MODE=%ld START=%ld 其它=%ld | 轮询=%ld 次，最后一次读回=0x%08X\n",
           nWrDst, nWrLen, nWrMode, nWrCtrl, nWrOther, nPoll, lastPoll);
    long bAr = cAr, bAw = cAw, bW = cW, bB = cB, bCsrAw = eCsrAw, bWrV = eWrValid, bWrR = eWrReady, bOwner = eOwnerDma;
    if (B.rc != 0) fail("J2 通路 B 未放核（state!=3）");
    if (B.err != 0) fail("J2 通路 B 报错（sd_err != 0）");

    // ---- J2 核心：两通路逐字节相同 + 都与卡镜像一致 ----
    if (A.img.size() != B.img.size()) { fail("J2 两通路镜像长度不同"); }
    else {
        long bad = 0, first = -1, badCard = 0;
        for (size_t i = 0; i < A.img.size(); ++i) {
            if (A.img[i] != B.img[i]) { bad++; if (first < 0) first = (long)i; }
        }
        // 与卡镜像独立对账（找 (addr,i) 对应的卡偏移）
        size_t idx = 0;
        for (auto &e : g_ents)
            for (uint32_t blk = 0; blk < e.nblk; ++blk)
                for (uint32_t k = 0; k < 512; ++k) {
                    size_t cardOff = (size_t)(e.lba + blk) * 512 + k;
                    uint8_t want = (cardOff < g_card.size()) ? g_card[cardOff] : 0;
                    if (A.img[idx] != want) badCard++;
                    idx++;
                }
        printf("  D3：通路A vs 通路B 逐字节 **BAD=%ld**（first=%ld，共 %zu B）| 与卡镜像 BAD=%ld\n",
               bad, first, A.img.size(), badCard);
        if (bad)     fail("J2（★D3）两条通路的装载结果不逐字节相同");
        if (badCard) fail("J2 通路 A 与卡镜像不一致（基线就不对）");
        if (!bad && !badCard && A.rc == 0 && B.rc == 0) ok("J2（★D3）同一镜像经引擎装载 == 直写装载（逐字节）");
    }
    // ---- J5 负对照自检：装置把通路 A 快照翻一位 ⇒ 上面那条判据必须翻红 ----
    if (getenv("SD_NC") && !A.img.empty()) {
        size_t i = A.img.size() / 2;
        A.img[i] ^= 0xFF;
        long bad = 0;
        for (size_t k = 0; k < A.img.size() && k < B.img.size(); ++k) if (A.img[k] != B.img[k]) bad++;
        printf("=== J5 负对照（判据自检）：把通路 A 快照第 %zu 字节翻一位 ⇒ 逐字节判据须翻红 ===\n", i);
        if (bad) ok("J5 判据有分辨力（翻一位 ⇒ 逐字节比较报出差异）");
        else     fail("J5 逐字节判据对『翻一位』无反应（恒绿的橡皮图章）");
    }

    // ---- J3 切换是真的 ----
    printf("=== J3 客户端切换是不是真的 ===\n");
    printf("  通路 A: CSR 主口 AW/AR=%ld/%ld（期望 0/0）| 喂流 valid=%ld（期望 0）| owner==7 次数=%ld（期望 0）\n",
           aCsrAw, 0L, aWrV, aOwner);
    if (aCsrAw || aWrV || aOwner) fail("J3 通路 A 竟出现了引擎流量（直写通路应完全绕过引擎）");
    else ok("J3 通路 A 完全绕过引擎（CSR 0 笔、喂流 0 笔、§3.5 owner 从不进 DMA 类）");
    printf("  通路 B: CSR 主口 AW=%ld（期望 >0）| 喂流 valid=%ld ready=%ld（期望 >0）| owner==7 次数=%ld（期望 >0）\n",
           bCsrAw, bWrV, bWrR, bOwner);
    if (bCsrAw <= 0)  fail("J3 通路 B 装载器没有编程引擎 CSR");
    if (bWrV <= 0)    fail("J3 通路 B 喂流 valid 从未抬起");
    if (bOwner <= 0)  fail("J3 通路 B §3.5 从未把总线授予 DMA 类（引擎没真搬）");
    if (bCsrAw > 0 && bWrV > 0 && bOwner > 0)
        ok("J3 通路 B 经【装载器 CSR 编程 → 喂流 → §3.5 DMA 类 → io.mem】整条通路");

    // ---- J4 记账 ----
    printf("=== J4 记账 ===\n");
    long wantW = (long)(imgBytes / 8);
    printf("  W 拍：通路 A=%ld 通路 B=%ld（期望 %ld = 镜像 %llu B / 8）| AW: A=%ld B=%ld | B 响应: A=%ld B=%ld | AR: A=%ld B=%ld\n",
           aW, bW, wantW, (unsigned long long)imgBytes, aAw, bAw, aB, bB, aAr, bAr);
    printf("  wstrb 非 0xFF 拍=%ld | awsize!=3 次数=%ld | wlast 与 awlen 不符=%ld\n", cWStrbBad, cAwSizeBad, cBstraddle);
    if (aW != wantW) fail("J4 通路 A 的 W 拍数 != 镜像字节数/8");
    if (bW != wantW) fail("J4 通路 B 的 W 拍数 != 镜像字节数/8");
    if (aB != aAw || bB != bAw) fail("J4 B 响应次数 != AW 次数");
    if (aAr || bAr) fail("J4 出现了内存读（两条通路都不该读）");
    if (cWStrbBad || cAwSizeBad || cBstraddle) fail("J4 写拍有非全字节有效/突发描述不合规");
    if (aW == wantW && bW == wantW && aB == aAw && bB == bAw && !aAr && !bAr && !cWStrbBad && !cAwSizeBad && !cBstraddle)
        ok("J4 两条通路的 W 拍/B/AW 记账都吻合、无读、突发合规");
    if (g_csViol) fail("J4 卡模型报 CS 定帧违规（命令之间没有 CS 高脉冲）");

    printf("cyc=%llu  fail=%d\n", (unsigned long long)cyc, nFail);
    printf("=== %s ===\n", nFail == 0 ? "TEST PASSED" : "TEST FAILED");
    dut->final();
    delete dut;
    return nFail == 0 ? 0 : 1;
}
