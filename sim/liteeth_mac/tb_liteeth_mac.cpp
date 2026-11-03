// ===================== LiteEth MAC 黑盒单元装置 =====================
// DUT = `third_party/liteeth_mac/liteeth_mac_top.v`（生成的 Verilog 黑盒，**不改**）。
//
// 为什么需要它（2026-10-07 板级定案）：板上 `eth0` 起来、CSR/槽/时钟全通（观测窗实测
//   `rxcHi=rxcLo=1`、`txEnSeen=1`、`csrCnt` 在涨），但**一个包都不走**，而且
//   驱动侧 `READER_READY(0x1C)` 首帧后永远回不到 1（帧卡在"发一半"），RX 侧 `writer_slot` 恒 0。
//   ⇒ 板上再猜下去成本太高，把**黑盒本身**放进 Verilator：三个时钟域都真实驱动，
//     照 `litex_liteeth.c` 的**原样序列**重放，看它到底能不能收发。
//
// 判据（每条都能翻红）：
//   A(TX) 写 tx 槽 + CSR{SLOT,LENGTH,START} ⇒ `pads_tx_en/data` 必须吐出
//          7×0x55 + 0xD5 + 载荷(+padding) + CRC32；且事后 **`READER_READY` 必须回 1**。
//   B(RX) 在 `pads_rx_*` 上喂一帧**CRC 正确**的 GMII 帧 ⇒ `WRITER_SLOT` 必须变、`bus_rx` 槽里
//          必须能读回同一载荷；且 `CRC_ERRORS/PREAMBLE_ERRORS` 为 0。
//   C(NEG) 喂**CRC 故意错**的帧 ⇒ 必须记 `CRC_ERRORS` 且**不**写槽（证明 B 的判据不是恒绿）。
//
// 时钟：`sys_clk`(10ns) / `clock_pads_rx`(8ns) / `clock_pads_tx`(8ns) 三个**独立**时钟，
//   相位错开 —— 与板上一致（sys=soc_clk 100MHz，两个 PHY 域 = rgmii_clk 125MHz）。

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "Vliteeth_mac_top.h"
#include "verilated.h"

static Vliteeth_mac_top *dut;
static uint64_t sys_cyc = 0, rx_cyc = 0, tx_cyc = 0;

// ---- CSR 字节偏移（照 litex_liteeth.c 的 #define；Wishbone CSR 用**字**地址）----
enum {
  CS_WRITER_SLOT = 0x00, CS_WRITER_LENGTH = 0x04, CS_WRITER_ERRORS = 0x08,
  CS_WRITER_EV_STATUS = 0x0C, CS_WRITER_EV_PENDING = 0x10, CS_WRITER_EV_ENABLE = 0x14,
  CS_READER_START = 0x18, CS_READER_READY = 0x1C, CS_READER_LEVEL = 0x20,
  CS_READER_SLOT = 0x24, CS_READER_LENGTH = 0x28, CS_READER_EV_STATUS = 0x2C,
  CS_READER_EV_PENDING = 0x30, CS_READER_EV_ENABLE = 0x34,
  CS_PREAMBLE_CRC = 0x38, CS_PREAMBLE_ERRORS = 0x3C, CS_CRC_ERRORS = 0x40,
};

static void tick() {
  // 三个时钟各自在周期中点翻转（相位互不相同）
  dut->sys_clk = (sys_cyc % 10) < 5 ? 1 : 0;
  dut->clock_pads_rx = (rx_cyc % 8) < 4 ? 1 : 0;
  dut->clock_pads_tx = ((tx_cyc + 3) % 8) < 4 ? 1 : 0;
  sys_cyc++; rx_cyc++; tx_cyc++;
  dut->eval();
}

// ⚠️⚠️ 装置坑（第一版踩过，**当场被自查抓住**）：等待窗口给 20 拍，而三个时钟周期是 10/8/8 拍
//   ⇒ 20 拍只有 **2 个 sys 上升沿**，LiteX 的 Wishbone 从口要好几拍才 ack ⇒ **每次访问都在超时前返回**，
//   写根本没落（回读 LENGTH=0、槽里全 FF）⇒ 于是"TX 不发、RX 不收"全是**装置的假象**。
//   现在：等 200 拍 + **超时必须报出来**（绝不静默放过）。
static int g_ack_timeout = 0;

#define WAIT_ACK(sig)                                                     \
  do {                                                                    \
    int _ok = 0;                                                          \
    for (int _i = 0; _i < 200; _i++) { tick(); if (sig) { _ok = 1; break; } } \
    if (!_ok) g_ack_timeout++;                                            \
    /* ★★★ 撤 cyc/stb 的正确姿势（两次踩坑后的定案）：                      */ \
    /*   · 一看到 ack 就撤 ⇒ 访问只持续 1 拍 < 1 个 sys 周期 ⇒ 采不到；      */ \
    /*   · 无脑多撑几拍 ⇒ LiteX 的 wb2csr FSM 会**再发一次**访问 ⇒ 重复读写。*/ \
    /*   ⇒ 只撑到**下一个 sys 上升沿**（保证恰好被采到一次）就撤。          */ \
    while ((sys_cyc % 10) != 0) tick();   /* 走到上升沿前一刻 */           \
    tick();                               /* 这一拍是上升沿（cyc/stb 仍有效）*/ \
  } while (0)

// ---------------- CSR（Wishbone，**字**寻址）----------------
static uint32_t csr_read(uint32_t byteoff) {
  dut->wb_csr_adr = byteoff >> 2;
  dut->wb_csr_cyc = 1; dut->wb_csr_stb = 1; dut->wb_csr_we = 0;
  dut->wb_csr_sel = 0xF;
  WAIT_ACK(dut->wb_csr_ack);
  uint32_t v = dut->wb_csr_dat_r;
  dut->wb_csr_cyc = 0; dut->wb_csr_stb = 0;
  tick(); tick();
  return v;
}

static void csr_write(uint32_t byteoff, uint32_t data) {
  dut->wb_csr_adr = byteoff >> 2;
  dut->wb_csr_dat_w = data;
  dut->wb_csr_cyc = 1; dut->wb_csr_stb = 1; dut->wb_csr_we = 1;
  dut->wb_csr_sel = 0xF;
  WAIT_ACK(dut->wb_csr_ack);
  dut->wb_csr_cyc = 0; dut->wb_csr_stb = 0; dut->wb_csr_we = 0;
  tick(); tick();
}

// ---------------- 槽从口（Wishbone，**字**寻址 + 字节使能；2026-10-07 起 dw=32）----------------
// 原来是 dw=8（字节寻址、sel 只有 1 位）。dw=32 后：字地址 = 字节偏移>>2，
// `sel = 1<<(字节偏移&3)`，数据要放进对应 lane —— 与板上 `liteeth_wrap` 的映射**逐字相同**，
// 这样本装置同时也在验"字节序是否正确"（判据 A/B 的载荷/前导逐字节比对就是它的照妖镜）。
static void slot_write(bool tx, uint32_t byteoff, uint8_t d) {
  uint32_t adr = byteoff >> 2;
  uint32_t sel = 1u << (byteoff & 3);
  uint32_t dat = (uint32_t)d << (8 * (byteoff & 3));
  if (tx) { dut->bus_tx_adr = adr; dut->bus_tx_dat_w = dat;
            dut->bus_tx_cyc = 1; dut->bus_tx_stb = 1; dut->bus_tx_sel = sel; dut->bus_tx_we = 1;
            WAIT_ACK(dut->bus_tx_ack);
            dut->bus_tx_cyc = 0; dut->bus_tx_stb = 0; }
  else     { dut->bus_rx_adr = adr; dut->bus_rx_dat_w = dat;
            dut->bus_rx_cyc = 1; dut->bus_rx_stb = 1; dut->bus_rx_sel = sel; dut->bus_rx_we = 1;
            WAIT_ACK(dut->bus_rx_ack);
            dut->bus_rx_cyc = 0; dut->bus_rx_stb = 0; }
  tick(); tick();
}

static uint8_t slot_read(bool tx, uint32_t byteoff) {
  uint32_t adr = byteoff >> 2;
  uint32_t word = 0;
  if (tx) { dut->bus_tx_adr = adr; dut->bus_tx_cyc = 1; dut->bus_tx_stb = 1; dut->bus_tx_sel = 0xF; dut->bus_tx_we = 0;
            WAIT_ACK(dut->bus_tx_ack);
            word = dut->bus_tx_dat_r; dut->bus_tx_cyc = 0; dut->bus_tx_stb = 0; }
  else    { dut->bus_rx_adr = adr; dut->bus_rx_cyc = 1; dut->bus_rx_stb = 1; dut->bus_rx_sel = 0xF; dut->bus_rx_we = 0;
            WAIT_ACK(dut->bus_rx_ack);
            word = dut->bus_rx_dat_r; dut->bus_rx_cyc = 0; dut->bus_rx_stb = 0; }
  tick(); tick();
  return (uint8_t)((word >> (8 * (byteoff & 3))) & 0xFF);
}

// ---------------- 以太网 CRC32（反射，poly 0xEDB88320）----------------
static uint32_t eth_crc32(const std::vector<uint8_t> &d) {
  uint32_t c = 0xFFFFFFFFu;
  for (uint8_t b : d) {
    c ^= b;
    for (int i = 0; i < 8; i++) c = (c >> 1) ^ (0xEDB88320u & (uint32_t)(-(int32_t)(c & 1)));
  }
  return ~c;
}

// ---------------- 在 GMII RX 上喂一帧（含前导；crc_ok 控制 CRC 是否正确）----------------
static void send_gmii_frame(const std::vector<uint8_t> &payload, bool crc_ok) {
  std::vector<uint8_t> f;
  for (int i = 0; i < 7; i++) f.push_back(0x55);
  f.push_back(0xD5);
  for (uint8_t b : payload) f.push_back(b);
  uint32_t crc = eth_crc32(payload);
  if (!crc_ok) crc ^= 0xFFFFFFFFu;
  for (int i = 0; i < 4; i++) f.push_back((crc >> (8 * i)) & 0xFF);
  // 每个字节 = 8 拍 clock_pads_rx（gmii 8bit @ 该域时钟）
  for (uint8_t b : f) {
    for (int k = 0; k < 8; k++) { dut->pads_rx_data = b; dut->pads_rx_dv = 1; dut->pads_rx_er = 0; tick(); }
  }
  // 帧间空隙
  for (int k = 0; k < 40; k++) { dut->pads_rx_dv = 0; dut->pads_rx_data = 0; tick(); }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vliteeth_mac_top;
  int bad = 0;

  // ---- 复位（sys_rst 高若干个 sys 拍）----
  dut->sys_rst = 1;
  dut->pads_rx_dv = 0; dut->pads_rx_data = 0; dut->pads_rx_er = 0;
  dut->wb_csr_adr = 0; dut->wb_csr_dat_w = 0; dut->wb_csr_sel = 0xF;
  dut->wb_csr_cyc = 0; dut->wb_csr_stb = 0; dut->wb_csr_we = 0;
  for (int i = 0; i < 40; i++) tick();
  dut->sys_rst = 0;
  for (int i = 0; i < 80; i++) tick();

  printf("== CSR 基线 ==\n");
  printf("  PREAMBLE_CRC(0x38) = 0x%08X  READER_READY(0x1C) = 0x%08X\n",
         csr_read(CS_PREAMBLE_CRC), csr_read(CS_READER_READY));

  // ---- 装置自查（其二）：CSR **写-读扫描**：哪些字的写能落、回读到什么 ----
  //   这一条是第一版"写不落"事故的根因探针：ack 全拿到但值不落 ⇒ 必须逐字查清，别猜。
  // ⚠️ 上一版这里用**32 位值**去比**窄寄存器**（1/8/16 位），比较本身就不成立 —— 判据错了。
  //   现在只挑**可写且可回读**的寄存器，按它自己的宽度写、按自己的宽度读：
  //     · word 13 `reader_ev_enable0`（1 位，可写可读）
  //     · word 10 `reader_length0`（16 位，驱动 write16 就写它）
  //     · word  9 `reader_slot0`（槽号）
  printf("== CSR 写读自查（按各寄存器自己的宽度）==\n");
  csr_write(CS_READER_EV_ENABLE, 1);
  printf("  reader_ev_enable0(0x34): 写 1 读回 %u (应 1)\n", csr_read(CS_READER_EV_ENABLE) & 1);
  csr_write(CS_READER_LENGTH, 42);
  printf("  reader_length0(0x28)  : 写 42 读回 %u (应 42)\n", csr_read(CS_READER_LENGTH) & 0xFFFF);
  csr_write(CS_READER_SLOT, 1);
  printf("  reader_slot0(0x24)    : 写 1 读回 %u (应 1)\n", csr_read(CS_READER_SLOT) & 0xFF);
  // 复位后重新初始化，避免扫描污染后面的用例
  dut->sys_rst = 1;
  for (int i = 0; i < 40; i++) tick();
  dut->sys_rst = 0;
  for (int i = 0; i < 80; i++) tick();

  // ============================ A：TX ============================
  {
    std::vector<uint8_t> payload;                 // 一个 42 字节的 ARP 样子（够短，看 padding）
    for (int i = 0; i < 6; i++) payload.push_back(0xFF);          // dst = broadcast
    for (int i = 0; i < 6; i++) payload.push_back(0x02 + i);      // src
    payload.push_back(0x08); payload.push_back(0x06);             // ethertype = ARP
    for (int i = 12; i < 42; i++) payload.push_back((uint8_t)(0xA0 + i));

    for (size_t i = 0; i < payload.size(); i++) slot_write(true, (uint32_t)i, payload[i]);
    // ⚠️ 先审装置：写完必须**回读**，确认 CSR 写真的落了（否则后面全是在怪设计）
    uint32_t tb0 = slot_read(true, 0), tb1 = slot_read(true, 1), tb41 = slot_read(true, 41);
    printf("== 装置自查 == tx 槽回读 [0]=%02X [1]=%02X [41]=%02X (应为 FF 00 %02X)\n",
           tb0, tb1, tb41, (unsigned)(0xA0 + 41));
    if (tb0 != 0xFF || tb1 != 0x00 || tb41 != (uint8_t)(0xA0 + 41)) {
      printf("   !! 槽写没落 ⇒ 装置问题，先修装置\n");
      bad++;
    }
    uint32_t ready0 = csr_read(CS_READER_READY) & 0xFF;
    csr_write(CS_READER_SLOT, 0);
    csr_write(CS_READER_LENGTH, (uint32_t)payload.size());
    csr_write(CS_READER_START, 1);
    // ⚠️ 采样必须**紧接** START —— 之前在 START 后先做了 4 次 CSR 回读，那几十拍里
    //    8 字节前导（64 拍）就已经发完了 ⇒ 采到的"没有前导"是**采集窗口**问题，不是设计问题。
    printf("== A(TX) == READY(before)=%u  (CSR 回读挪到采样之后)\n", ready0);
    // 采样 pads_tx_en/data，收出线上字节序列
    // ⚠️ 修（2026-10-07）：原版"只在 tx_en 上升沿取一个字节"是**错的** —— GMII 的 tx_en 是
    //    **整帧电平**（一拍一字节），所以那样只会取到每段的头一个字节（正确流=1 个字节）。
    //    现在：tx_en 高时**每 8 个 tick 取一次**（= 一个 clock_pads_tx 周期 = GMII 一拍），
    //    并统计"最长连续 tx_en 拍数"= 这一版新加的**决定性判据**
    //    （板上实测：坏=4 拍；好应≈ (前导 8 + 帧长 + padding) × 8 拍）。
    std::vector<uint8_t> got;
    int en_high = 0, run = 0, run_max = 0, since_edge = 0;
    for (int i = 0; i < 20000; i++) {
      tick();
      if (dut->pads_tx_en) {
        en_high++;
        run++;
        if (run > run_max) run_max = run;
        if (since_edge == 7) got.push_back(dut->pads_tx_data);   // tx 时钟高相位中点取样
        since_edge = (since_edge + 1) & 7;
      } else { run = 0; since_edge = 0; }
    }
    uint32_t ready1 = csr_read(CS_READER_READY) & 0xFF;
    printf("  pads_tx_en 高拍数=%d 最长连续=%d 拍(=%.1f 字节)  收到 %zu 字节  READER_READY(after)=%u\n",
           en_high, run_max, run_max / 8.0, got.size(), ready1);
    // 前导 + SFD 检查
    bool pre_ok = got.size() >= 8;
    for (int i = 0; pre_ok && i < 7; i++) pre_ok = (got[i] == 0x55);
    if (pre_ok) pre_ok = (got[7] == 0xD5);
    // 载荷检查
    bool pay_ok = pre_ok && (got.size() >= 8 + payload.size());
    for (size_t i = 0; pay_ok && i < payload.size(); i++) pay_ok = (got[8 + i] == payload[i]);
    bool cont_ok = (run_max >= 60 * 8);      // 一帧最短 60 字节 + 前导 8 ⇒ 至少 68 拍连续
    printf("  preamble+SFD=%s  payload=%s  连续(tx_en>=68B)=%s => %s\n",
           pre_ok ? "OK" : "BAD", pay_ok ? "OK" : "BAD", cont_ok ? "OK" : "BAD",
           (pre_ok && pay_ok && cont_ok) ? "PASS" : "FAIL");
    if (!(pre_ok && pay_ok && cont_ok)) {
      bad++;
      printf("    got[0..24] =");
      for (size_t i = 0; i < got.size() && i < 25; i++) printf(" %02X", got[i]);
      printf("\n");
    }
  }

  // ============================ B：RX（CRC 正确）============================
  {
    std::vector<uint8_t> rxframe;
    for (int i = 0; i < 6; i++) rxframe.push_back(0x11);          // dst
    for (int i = 0; i < 6; i++) rxframe.push_back(0x22);          // src
    rxframe.push_back(0x08); rxframe.push_back(0x00);             // IPv4
    for (int i = 14; i < 60; i++) rxframe.push_back((uint8_t)(0x30 + i));   // 60B 最小帧

    uint32_t wr_before = csr_read(CS_WRITER_SLOT) & 0xFF;
    send_gmii_frame(rxframe, true);
    for (int i = 0; i < 400; i++) tick();
    uint32_t wr_after = csr_read(CS_WRITER_SLOT) & 0xFF;
    uint32_t wr_len = csr_read(CS_WRITER_LENGTH) & 0xFFFF;
    std::vector<uint8_t> rd;
    for (size_t i = 0; i < rxframe.size(); i++) rd.push_back(slot_read(false, (uint32_t)i));
    bool same = (rd.size() == rxframe.size());
    for (size_t i = 0; same && i < rxframe.size(); i++) same = (rd[i] == rxframe[i]);
    uint32_t crc_err = csr_read(CS_CRC_ERRORS);
    printf("== B(RX) == writer_slot %u->%u  writer_length=%u 槽内载荷一致=%s CRC_ERRORS=%u => %s\n",
           wr_before, wr_after, wr_len, same ? "OK" : "BAD", crc_err,
           (wr_after != wr_before || wr_len != 0) && same ? "PASS" : "FAIL");
    if (!((wr_after != wr_before || wr_len != 0) && same)) {
      bad++;
      printf("    rd[0..24] =");
      for (size_t i = 0; i < rd.size() && i < 25; i++) printf(" %02X", rd[i]);
      printf("\n");
    }
  }

  // ============================ C：负控（CRC 故意错）============================
  {
    std::vector<uint8_t> badf;
    for (int i = 0; i < 6; i++) badf.push_back(0x33);
    for (int i = 0; i < 6; i++) badf.push_back(0x44);
    badf.push_back(0x08); badf.push_back(0x00);
    for (int i = 14; i < 60; i++) badf.push_back((uint8_t)(0x50 + i));
    uint32_t c_before = csr_read(CS_CRC_ERRORS);
    uint32_t wr_before = csr_read(CS_WRITER_SLOT) & 0xFF;
    send_gmii_frame(badf, false);
    for (int i = 0; i < 400; i++) tick();
    uint32_t c_after = csr_read(CS_CRC_ERRORS);
    uint32_t wr_after = csr_read(CS_WRITER_SLOT) & 0xFF;
    bool neg_ok = (c_after != c_before);
    printf("== C(NEG) == CRC_ERRORS %u->%u  writer_slot %u->%u => %s\n",
           c_before, c_after, wr_before, wr_after, neg_ok ? "PASS" : "FAIL");
    if (!neg_ok) bad++;
  }

  printf("[unit] WB ack timeouts = %d  (0 = 每次访问都拿到 ack)\n", g_ack_timeout);
  printf("---- %d problems ----\n", bad);
  printf("=== TEST %s ===\n", bad ? "FAILED" : "PASSED");
  delete dut;
  return bad ? 1 : 0;
}
