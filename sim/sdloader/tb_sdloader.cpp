// ============================================================================================
// `SdLoader` 单元装置（Verilator）：SPI SD 卡模型 + AXI 写从方 ⇒ 验"卡上镜像 → DDR → 放核"。
//
// 为什么要这个装置（2026-10-05 教训）：`SdSpi`/`SdLoader` 的初始化+搬运路径**从来没有仿真覆盖**
//   （`sim/tb_naxmini.cpp` 里连 sd 钩子都没有）⇒ 上板才暴露：**插了卡（能真读）就卡死**——控制台
//   100s 静默，`io_state` 既不到 4（失败）也不 release ⇒ 卡在中间态。本装置把卡模型接上，直接在
//   仿真里看 `io_state` 停在哪一步。
//
// 装置组成：
//   · **SPI SD 卡模型**（mode 0，CPOL=0/CPHA=0）：CMD0 / CMD8(R7=0x1AA) / CMD55+ACMD41 / CMD58(CCS=1)
//     / CMD17(0xFE token + 512B + 2B CRC)，数据源 = `sim/reglogs/sd.img`（块 0 = 'YSLD' 表）；
//   · **AXI 写从方**：收 AW（awlen 固定 4 ⇒ 每笔 4 拍 64bit）、收 W、回 B，按字节地址写内存模型；
//   · 判据：放核（`io_released`）**且** 写进 DDR 的每个字节等于卡镜像对应字节。
//
// 用法：tb_sdloader [timeout_cycles]   （默认 40e6 拍；真机 8.7MB 按 25MHz SPI 约 11s ≈ 1.1e9 拍，
//        仿真按 100MHz 建模 ⇒ 先用 40e6 拍（0.4s 等价）判"是不是**卡死**"而不是"慢"）
// ⚠️ 装置纪律：握手判据用**沿前**的 valid/ready；SPI 模型按 DUT 输出的 SCK 边沿采样。
// ============================================================================================
#include "VSdLoader.h"
#include "VSdLoader___024root.h"      // --public-flat-rw 时读内部信号需要完整类型
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <map>
#include <vector>

static VSdLoader *dut;

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

// ---------------------------------------------------------------- DDR 内存模型（AXI 写从方）
static std::map<uint64_t, uint8_t> g_ddr;
static uint64_t g_awCnt = 0, g_wBeat = 0, g_bCnt = 0;
static uint32_t g_awAddr = 0;
static int      g_beatInBurst = 0;
static int      g_bPending = 0;
static int      g_bpMode = 0;                 // 1 = 回压档：B 故意迟几拍回
static int      g_acmdBusy = 0;               // ACMD41 前 n 次回 0x01（busy），用来覆盖重发 CMD55 的路

// ---------------------------------------------------------------- SPI SD 卡模型
static int      spi_bit = 0;
static uint8_t  spi_rx = 0;
static uint8_t  spi_tx = 0xFF;                // 正在移出的字节（MSB 先）
static int      spi_bitsLeft = 8;             // 当前字节还剩几位没移出
static int      g_csHi = 1;                   // 上一条命令之后 CS 拉高过没有（SPI 每条命令靠 CS 定帧）
static int      g_csViol = 0;                 // CS 定帧违规计数（本装置把这种错帧判红）
static int      spi_stage = 0;                // 0=空闲 1..4=收 arg 5=收 crc
static uint8_t  spi_cmd = 0;
static uint32_t spi_arg = 0;
static std::deque<uint8_t> spi_out;
// ★ CMD18 多块读：g_multi=1 时模型在每块 514 字节后自动接上下一块的 0xFE 令牌；
//   CMD12 收尾把它清掉（与 SD SPI 的 READ_MULTIPLE_BLOCK 语义一致）。
static int      g_multi = 0;
static int      g_cmd12neg = 0;   // 负控：CMD12 回非 0（挂 CMD18 的收尾错误码）
static uint32_t g_baseLba = 0;
static uint32_t g_blkIdx = 0;
static int      spi_dataLeft = 0;
static uint64_t spi_dataPtr = 0;

static int g_verbose = 0;                     // 0=静默 1=只记命令 2=每个收发字节
static uint8_t spi_next();                    // 前向声明（spi_load_byte 先用到）
static void spi_load_byte() {
    spi_tx = spi_next(); spi_bitsLeft = 8;
    if (g_verbose >= 2) printf("[card] TX %02X\n", spi_tx);
}

static void start_multi_block() {
    spi_out.push_back(0xFE);
    spi_dataPtr = ((uint64_t)g_baseLba + g_blkIdx) * 512u;
    spi_dataLeft = 512 + 2;
}

static uint8_t spi_next() {
    // ⚠️ 顺序：**先把已排队的响应字节发完**（R1 / gap / 0xFE token），再发 512B 数据。
    //    写反了会把镜像首字节（'Y'=0x59）当 R1 发出去 ⇒ DUT 判"R1 bit7=1 非法" ⇒ sdErr=5。
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

static void spi_handle_byte(uint8_t b) {
    if (g_verbose >= 2) printf("[card] RX %02X (stage=%d)\n", b, spi_stage);
    if (spi_stage == 0) {
        if ((b & 0xC0) == 0x40) {
            if (!g_csHi) { g_csViol++; if (g_csViol <= 3) printf("[card] CS-FRAMING VIOLATION: new command without CS-high gap\n"); }
            g_csHi = 0;
            spi_cmd = b & 0x3F; spi_arg = 0; spi_stage = 1;
        }
        return;
    }
    if (spi_stage <= 4) { spi_arg = (spi_arg << 8) | b; spi_stage++; return; }
    switch (spi_cmd) {
      case 0:  spi_out.push_back(0x01); break;                                 // CMD0 → idle
      case 8:  spi_out.push_back(0x01);
               spi_out.push_back(0x00); spi_out.push_back(0x00);
               spi_out.push_back(0x01); spi_out.push_back(0xAA); break;        // R7 = 0x1AA
      case 55: spi_out.push_back(0x01); break;                                 // CMD55
      // ACMD41：真实卡在初始化期间会**反复回 0x01(busy)**，就绪后才回 0x00。
      // `SD_ACMD41_BUSY=n` 让模型先回 n 次 0x01 —— 用来覆盖"必须重发 CMD55+ACMD41"那条路
      // （2026-10-06 板上就是因为 SdSpi 只认 0x00 而卡在 ACMD41 超时，装置当时零覆盖）。
      case 41: if (g_acmdBusy > 0) { spi_out.push_back(0x01); g_acmdBusy--; }
               else spi_out.push_back(0x00); break;
      case 58: spi_out.push_back(0x00);
               spi_out.push_back(0xC0); spi_out.push_back(0xFF);
               spi_out.push_back(0x80); spi_out.push_back(0x00); break;        // OCR: CCS=1 (SDHC)
      case 17: spi_out.push_back(0x00); spi_out.push_back(0xFF);
               spi_out.push_back(0xFE);                                        // R1 + gap + data token
               spi_dataPtr = (uint64_t)spi_arg * 512u; spi_dataLeft = 512 + 2; break;
      // ★ CMD18：R1 之后连续发块（每块 0xFE + 512B + 2B），直到 CMD12 或 CS 抬起
      case 18: spi_out.push_back(0x00);
               g_multi = 1; g_baseLba = spi_arg; g_blkIdx = 0; start_multi_block(); break;
      // ★ CMD12：停多块读，回 R1=0x00（DUT 只认 0x00）
      case 12: g_multi = 0; spi_dataLeft = 0;
               spi_out.push_back(g_cmd12neg ? 0x04 : 0x00); break;
      default: spi_out.push_back(0x04); break;
    }
    if (g_verbose >= 1)
        printf("[card] cmd=%u (0x%02X) arg=0x%08X -> resp 0x%02X,outq=%zu\n",
               spi_cmd, 0x40 | spi_cmd, spi_arg, spi_out.empty() ? 0xFF : spi_out.front(), spi_out.size());
    spi_stage = 0;
}

// ---------------------------------------------------------------- 一拍
static int g_lastState = -1;

// 内部状态转储（--public-flat-rw）：st 是 FSM 真值（io_state 是重映射后的视图）
static void dump(const char *tag, uint64_t c) {
    printf("[%s @cyc=%llu] st=%u hIdx=%u hdrMode=%u sdlLba=%u hdrSel=%u sdErr=%u grp=%u groupFull=%u wState=%u wCnt=%u io_state=%u\n",
           tag, (unsigned long long)c,
           (unsigned)dut->rootp->SdLoader__DOT__st,
           (unsigned)dut->rootp->SdLoader__DOT__hIdx,
           (unsigned)dut->rootp->SdLoader__DOT__hdrMode,
           (unsigned)dut->rootp->SdLoader__DOT__sdlLba,
           (unsigned)dut->io_hdrSel,
           (unsigned)dut->rootp->SdLoader__DOT___sd_io_err,
           (unsigned)dut->rootp->SdLoader__DOT__grp,
           (unsigned)dut->rootp->SdLoader__DOT__groupFull,
           (unsigned)dut->rootp->SdLoader__DOT__wState,
           (unsigned)dut->rootp->SdLoader__DOT__wCnt,
           (unsigned)dut->io_state);
    printf("[%s] errR=%u\n", tag, (unsigned)dut->rootp->SdLoader__DOT__errR);
    printf("[%s] sdSpi: sckCnt=%u ph=%u st=%u err=%u misoHi=%u initRetry=%u\n", tag,
           (unsigned)dut->rootp->SdLoader__DOT__sd__DOT__sckCnt,
           (unsigned)dut->rootp->SdLoader__DOT__sd__DOT__ph,
           (unsigned)dut->rootp->SdLoader__DOT__sd__DOT__st,
           (unsigned)dut->rootp->SdLoader__DOT__sd__DOT__errCode,
           (unsigned)dut->rootp->SdLoader__DOT__sd__DOT__misoHi,
           (unsigned)dut->rootp->SdLoader__DOT__sd__DOT__initRetry);
}

static int g_bp = 0;                          // 回压档：每 64 拍里前 g_bp 拍 awready/wready/bvalid 拉低
static uint32_t g_bpCnt = 0;
static int g_misoStuck = -1;                  // -1=正常卡模型 0/1=把 MISO 钉死在该电平（对照板侧"卡不回话"）

static void tick() {
    // (1) 从方在本拍给 DUT 的输入（基于上一拍末的状态）
    g_bpCnt++;
    int busy = (g_bp > 0) && ((g_bpCnt & 63u) < (uint32_t)g_bp);
    dut->io_awready = busy ? 0 : 1;
    dut->io_wready  = busy ? 0 : 1;
    dut->io_bvalid  = (g_bPending && !busy) ? 1 : 0;
    dut->io_sdMiso  = (g_misoStuck >= 0) ? g_misoStuck : ((spi_tx >> 7) & 1);

    // (2) 沿前快照 ⚠️ **必须沿前取 payload**：DUT 在同一沿就推进 wIdx ⇒ 沿后读 io_wdata 会拿到**下一拍**
    int awv = dut->io_awvalid; uint32_t awaddr = dut->io_awaddr;
    int wrv = dut->io_wvalid;  uint64_t wdata = dut->io_wdata; int wlastv = dut->io_wlast;
    int brd = dut->io_bready;
    int sckP = dut->io_sdSck, csP = dut->io_sdCsN;

    // (3) 上升沿
    dut->clock = 1; dut->eval();

    // (4) 用沿前 valid/ready/data 判握手
    if (awv && dut->io_awready) { g_awAddr = awaddr; g_beatInBurst = 0; g_awCnt++; }
    if (wrv && dut->io_wready) {
        if (g_verbose >= 1 && g_beatInBurst == 0 && g_awCnt <= 6)
            printf("[tb] AW@%08X beat0 wdata=%016llX  (lsb byte=%02X)\n",
                   g_awAddr, (unsigned long long)wdata, (unsigned)(wdata & 0xFF));
        for (int k = 0; k < 8; k++) g_ddr[(uint64_t)g_awAddr + g_beatInBurst * 8 + k] = (uint8_t)((wdata >> (8 * k)) & 0xFF);
        g_beatInBurst++; g_wBeat++;
        if (wlastv || g_beatInBurst == 4) g_bPending = 1;
    }
    if (g_bPending && brd && !busy) { g_bPending = 0; g_bCnt++; }

    // (5) 下降沿
    dut->clock = 0; dut->eval();

    // (6) SPI 模型：看这一刻 SCK/CS 相对上一拍的边沿
    int sckN = dut->io_sdSck, csN = dut->io_sdCsN, mos = dut->io_sdMosi;
    if (csN && !csP) { spi_bit = 0; spi_rx = 0; spi_stage = 0; spi_out.clear(); spi_dataLeft = 0; g_multi = 0; g_csHi = 1; spi_load_byte(); }
    if (!csN) {
        if (sckN && !sckP) {                       // 上升沿：采 MOSI
            spi_rx = (uint8_t)((spi_rx << 1) | (mos & 1));
            if (++spi_bit == 8) { spi_bit = 0; spi_handle_byte(spi_rx); spi_rx = 0; }
        } else if (!sckN && sckP) {                // 下降沿：移出**下一位**（8 位一字节，不是每边沿换字节！）
            spi_tx = (uint8_t)(spi_tx << 1);
            if (--spi_bitsLeft == 0) spi_load_byte();
        }
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *img = getenv("SD_IMG") ? getenv("SD_IMG") : "../reglogs/sd.img";
    int hdrSel = getenv("SD_HDR") ? atoi(getenv("SD_HDR")) : 0;
    if (!load_card(img)) { printf("[FAIL] 打不开卡镜像 %s\n", img); return 2; }
    int neg = (getenv("SD_NEG") != nullptr);
    if (neg) { g_card[(hdrSel ? 32768ULL * 512 : 0)] = 'X'; printf("[tb] 负控：把块 0 魔数改成 'XSLD'（loader 应**如期失败**：state=4、不放核）\n"); }
    // ★ CRC 负对照（2026-10-25）：两级 CRC 各自必须**会变红**，否则等于没加。
    //   1 = 改**载荷**一个字节 ⇒ 段 CRC（errCode 8）；2 = 改**表项**的目标地址（保持 32B 对齐）
    //   ⇒ 表头 CRC（errCode 7）。后者正是段 CRC 抓不到的那类错（数据没错、写到错的地方）。
    if (getenv("SD_CMD12_NEG")) { g_cmd12neg = 1; printf("[tb] CMD12 neg: card answers CMD12 with 0x04 (loader must fail)\n"); }
    int crcNeg = getenv("SD_CRC_NEG") ? atoi(getenv("SD_CRC_NEG")) : 0;
    int crcExpErr = 0;
    if (crcNeg) {
        size_t hoff = (hdrSel ? 32768ULL : 0ULL) * 512;
        auto be = [&](size_t o) -> uint32_t {
            return ((uint32_t)g_card[o] << 24) | ((uint32_t)g_card[o + 1] << 16) |
                   ((uint32_t)g_card[o + 2] << 8) | g_card[o + 3];
        };
        if (crcNeg == 1) {                       // 段 CRC：翻载荷首块的一个字节
            uint32_t sb = be(hoff + 12);
            size_t o = (size_t)sb * 512;
            g_card[o] ^= 0x01;
            crcExpErr = 8;
            printf("[tb] CRC 负控 1：载荷块 %u 的首字节翻一位（期望 errCode=8 / state=4 / 不放核）\n", sb);
        } else if (crcNeg == 2) {                // 表头 CRC：翻目标地址（bit15，仍 32B 对齐）
            g_card[hoff + 9] ^= 0x01;
            crcExpErr = 7;
            printf("[tb] CRC 负控 2：表项 0 的目标地址翻一位（期望 errCode=7 / state=4 / 不放核）\n");
        } else {
            printf("[tb] 未知 SD_CRC_NEG=%d（只支持 1/2）\n", crcNeg);
            return 2;
        }
    }
    printf("[tb] card image %s: %zu bytes = %zu blocks, hdrSel=%d\n", img, g_card.size(), g_card.size() / 512, hdrSel);
    g_bpMode = getenv("SD_BP") ? atoi(getenv("SD_BP")) : 0;
    g_verbose = getenv("SD_VERBOSE") ? atoi(getenv("SD_VERBOSE")) : 0;
    g_bp = getenv("SD_BP") ? atoi(getenv("SD_BP")) : 0;
    if (g_bp) printf("[tb] AXI backpressure SD_BP=%d (first %d of 64 cycles not ready)\n", g_bp, g_bp);
    if (getenv("SD_MISO")) { g_misoStuck = atoi(getenv("SD_MISO")); printf("[tb] 对照：把 MISO 钉死在 %d（模拟板侧卡不回话）\n", g_misoStuck); }
    if (getenv("SD_ACMD41_BUSY")) { g_acmdBusy = atoi(getenv("SD_ACMD41_BUSY")); printf("[tb] 卡模型：ACMD41 前 %d 次回 0x01(busy) 再回 0x00\n", g_acmdBusy); }

    dut = new VSdLoader;
    dut->reset = 1; dut->io_active = 0; dut->io_hdrSel = (hdrSel ? 1 : 0); dut->io_sdMiso = 1;
    dut->clock = 0; dut->eval();
    for (int i = 0; i < 8; i++) tick();
    dut->reset = 0; dut->io_active = 1;

    uint64_t maxCyc = (argc > 1 ? strtoull(argv[1], nullptr, 0) : 40000000ULL);
    uint64_t c = 0;
    unsigned lastRaw = 0xFF;
    int      ntrans = 0;
    for (; c < maxCyc; c++) {
        tick();
        unsigned raw = dut->rootp->SdLoader__DOT__st;
        if (raw != lastRaw) {
            if (ntrans < 80) dump("st", c);
            else if (ntrans == 80) printf("[tb] ...(后续状态跳变已省略)\n");
            ntrans++;
            lastRaw = raw;
        }
        if (dut->io_released) { printf("[tb] RELEASED @cyc=%llu\n", (unsigned long long)c); break; }
    }
    dump("end", c);
    printf("[tb] end: cyc=%llu state=%u released=%u | AW=%llu W=%llu B=%llu | ddr bytes=%zu\n",
           (unsigned long long)c, dut->io_state, dut->io_released,
           (unsigned long long)g_awCnt, (unsigned long long)g_wBeat, (unsigned long long)g_bCnt, g_ddr.size());

    if (neg) {                                   // 负控：期望"如期失败"（不放核且 state=4）
        int ok = (!dut->io_released && dut->io_state == 4);
        printf(ok ? "=== TEST PASSED === (负控如期失败 state=4)\n" : "=== TEST FAILED === (负控没失败)\n");
        delete dut; return ok ? 0 : 1;
    }
    if (g_cmd12neg) {                            // CMD12 负控：多块读的收尾必须会红
        unsigned se = (unsigned)dut->rootp->SdLoader__DOT__sd__DOT__errCode;
        int ok = (!dut->io_released && dut->io_state == 4 && se == 7);
        printf("[tb] CMD12 neg judge: state=%u sdErr=%u (want state=4 sdErr=7) released=%u\n",
               (unsigned)dut->io_state, se, (unsigned)dut->io_released);
        printf(ok ? "=== TEST PASSED === (CMD12 neg fired as expected)\n" : "=== TEST FAILED === (CMD12 neg did not fire)\n");
        delete dut; return ok ? 0 : 1;
    }
    if (crcNeg) {                                // CRC 负控：判"如期失败 + 错误码正好是那一路"
        unsigned e = (unsigned)dut->rootp->SdLoader__DOT__errR;
        int ok = (!dut->io_released && dut->io_state == 4 && (int)e == crcExpErr);
        printf("[tb] CRC 负控判据：state=%u err=%u（期望 state=4 err=%d）released=%u\n",
               (unsigned)dut->io_state, e, crcExpErr, (unsigned)dut->io_released);
        printf(ok ? "=== TEST PASSED === (CRC 负控如期失败)\n" : "=== TEST FAILED === (CRC 负控没抓到)\n");
        delete dut; return ok ? 0 : 1;
    }
    if (!dut->io_released) {
        printf("=== TEST FAILED === (未放核，state=%u；lHdrRd=2 lCopyRd=5 lWr=6 lFail=8)\n", dut->io_state);
        delete dut; return 1;
    }
    // 逐字节对账
    auto be32 = [&](size_t o) -> uint32_t {
        return ((uint32_t)g_card[o] << 24) | ((uint32_t)g_card[o + 1] << 16) | ((uint32_t)g_card[o + 2] << 8) | g_card[o + 3];
    };
    size_t hdrOff = (hdrSel ? 32768ULL : 0ULL) * 512;
    if (g_card.size() < hdrOff + 12 || g_card[hdrOff] != 'Y' || g_card[hdrOff + 1] != 'S' || g_card[hdrOff + 2] != 'L' || g_card[hdrOff + 3] != 'D') {
        printf("=== TEST FAILED === (卡镜像块 0 魔数不对)\n"); delete dut; return 1;
    }
    uint32_t nent = be32(hdrOff + 4);
    size_t bad = 0, checked = 0;
    for (uint32_t i = 0; i < nent && i < 8; i++) {
        uint32_t dst = be32(hdrOff + 8 + 12 * i), lba = be32(hdrOff + 12 + 12 * i), nblk = be32(hdrOff + 16 + 12 * i);
        for (uint32_t b = 0; b < nblk; b++) {
            for (uint32_t k = 0; k < 512; k++) {
                uint64_t cardOff = (uint64_t)(lba + b) * 512 + k;
                if (cardOff >= g_card.size()) continue;
                uint8_t want = g_card[cardOff];
                uint64_t a = (uint64_t)dst + (uint64_t)b * 512 + k;
                auto it = g_ddr.find(a);
                uint8_t got = (it == g_ddr.end()) ? 0 : it->second;
                if (got != want) { if (bad < 5) printf("[tb] DDR[%08llX] = %02X 期望 %02X\n", (unsigned long long)a, got, want); bad++; }
                checked++;
            }
        }
    }
    printf("[tb] 对账：checked=%zu bad=%zu（表项数 %u）\n", checked, bad, nent);
    if (g_csViol) printf("[tb] CS-FRAMING VIOLATION x%d (命令之间没有 CS 高脉冲)\n", g_csViol);
    int ok = (bad == 0 && g_csViol == 0);
    printf(ok ? "=== TEST PASSED ===\n" : "=== TEST FAILED ===\n");
    delete dut;
    return ok ? 0 : 1;
}
