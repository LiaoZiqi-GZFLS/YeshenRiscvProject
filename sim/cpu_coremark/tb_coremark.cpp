// ============================================================================
// tb_coremark.cpp —— VexiiRiscv 单核 CoreMark 仿真台架（Verilator）
//
// 目的：在不含 DDR/SoC 的裸核环境下测 CoreMark/MHz（= 每次迭代的周期数倒数）。
// 组成：
//   · FetchL1 AXI4 读从口（64bit，len 突发）
//   · LsuL1   AXI4 读/写从口（64bit，len 突发 + wstrb）
//   · LsuCacheless AXI4 从口（32bit）：UART 16550 @0xF0001000（THR/LSR）+
//     上游 sim 地址（0x10000000 / 0x1001BFF8）兼容
//   · rdtime 端口 = 自由运行 64bit 周期计数
//
// ★ 从口模型：AR / AW / W 全部**入队**（不因 R 流或 B 未回而拉低 ready），
//   响应按 FIFO 顺序产生。这样对核呈现"几乎总是可接"的内存，避免 max-ipc 的
//   多 outstanding / 预取流水线因为 backpressure 进入内部死锁（2026-10-18 实测：
//   逐拍拉低 ar_ready 会让 store buffer/late ALU/refill8 的核在首个 UART 写后停住）。
//
// 用法：./coremark_sim <coremark.bin> <max_cycles> [mem_lat]
// ============================================================================
#include "VVexiiRiscv.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <tuple>
#include <vector>

static VVexiiRiscv* dut;
static uint64_t g_mtime = 0;
static std::vector<uint8_t> g_mem(8u << 20, 0);
static std::string g_uart;
static bool g_dlab = false;
static int g_lat = 1;

static const uint32_t MEM_BASE = 0x80000000u;
static const uint32_t MEM_SIZE = 8u << 20;

static uint64_t mem_rd64(uint32_t addr) {
  uint64_t v = 0;
  for (int i = 0; i < 8; i++) {
    uint32_t a = addr + i;
    if (a >= MEM_BASE && a - MEM_BASE < MEM_SIZE) v |= (uint64_t)g_mem[a - MEM_BASE] << (8 * i);
  }
  return v;
}
static void mem_wr(uint32_t addr, uint64_t data, uint8_t strb) {
  for (int i = 0; i < 8; i++) {
    if (!((strb >> i) & 1)) continue;
    uint32_t a = addr + i;
    if (a >= MEM_BASE && a - MEM_BASE < MEM_SIZE) g_mem[a - MEM_BASE] = (uint8_t)(data >> (8 * i));
  }
}

// ---------------------------------------------------------------- 读通道（FIFO 请求队列）
struct RdCh {
  std::deque<std::pair<uint32_t, int>> q;
  int st = 0, wait = 0, beat = 0, len = 0;
  uint32_t addr = 0;
  bool ar_ready() const { return q.size() < 8; }
  bool r_valid() const { return st == 2; }
  bool r_last() const { return beat >= len; }
  void ar_fire(uint32_t a, int l) { q.push_back(std::make_pair(a, l)); }
  void cycle(bool r_fire) {
    if (st == 0) {
      if (!q.empty()) {
        addr = q.front().first; len = q.front().second; q.pop_front();
        beat = 0; wait = g_lat; st = 1;
      }
    } else if (st == 1) {
      if (wait > 0) wait--; else st = 2;
    } else {
      if (r_fire) {
        if (beat >= len) { st = 0; beat = 0; }
        else beat++;
      }
    }
  }
};

// ---------------------------------------------------------------- 写通道（AW/W 入队，B 按顺序回）
struct WrCh {
  std::deque<std::pair<uint32_t, int>> awq;
  std::deque<std::tuple<uint64_t, uint8_t, bool>> wq;
  int beat = 0, b_pending = 0;
  bool b_valid = false;
  bool aw_ready() const { return awq.size() < 4; }
  bool w_ready() const { return wq.size() < 16; }
  void aw_fire(uint32_t a, int l) { awq.push_back(std::make_pair(a, l)); }
  void w_fire(uint64_t d, uint8_t s, bool last) { wq.push_back(std::make_tuple(d, s, last)); }
  void cycle(bool b_fire) {
    if (!awq.empty() && !wq.empty() && !b_valid) {
      uint32_t a = awq.front().first;
      uint64_t d; uint8_t s; bool last;
      std::tie(d, s, last) = wq.front(); wq.pop_front();
      uint32_t ea = a + (uint32_t)beat * 8;
      mem_wr(ea, d, s);
      if (ea == 0xF000100Cu) g_dlab = ((d & 0x80) != 0);
      else if (ea == 0xF0001000u && !g_dlab) g_uart.push_back((char)(d & 0xFF));
      else if (ea == 0x10000000u) g_uart.push_back((char)(d & 0xFF));
      if (last) { awq.pop_front(); beat = 0; b_pending++; }
      else beat++;
    }
    if (!b_valid && b_pending > 0) b_valid = true;
    if (b_valid && b_fire) { b_valid = false; b_pending--; }
  }
};

static RdCh g_rd_fetch, g_rd_lsu, g_rd_cc;
static WrCh g_wr_lsu, g_wr_cc;

static void eval_low()  { dut->clk = 0; dut->eval(); }
static void eval_high() { dut->clk = 1; dut->eval(); }

static bool has_line(const std::string& s, const std::string& key) {
  size_t p = s.find(key);
  return p != std::string::npos && s.find('\n', p) != std::string::npos;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 3) { fprintf(stderr, "usage: %s <coremark.bin> <max_cycles> [mem_lat]\n", argv[0]); return 2; }
  const char* bin = argv[1];
  uint64_t maxCyc = strtoull(argv[2], nullptr, 0);
  if (argc > 3) g_lat = atoi(argv[3]);

  FILE* f = fopen(bin, "rb");
  if (!f) { fprintf(stderr, "cannot open %s\n", bin); return 2; }
  size_t n = fread(g_mem.data(), 1, g_mem.size(), f);
  fclose(f);
  printf("[tb] image %s: %zu bytes; mem_lat=%d; maxCyc=%llu\n", bin, n, g_lat, (unsigned long long)maxCyc);

  dut = new VVexiiRiscv;
  dut->clk = 0; dut->reset = 1;
  dut->PrivilegedPlugin_logic_rdtime = 0;
  dut->PrivilegedPlugin_logic_harts_0_int_m_timer = 0;
  dut->PrivilegedPlugin_logic_harts_0_int_m_software = 0;
  dut->PrivilegedPlugin_logic_harts_0_int_m_external = 0;
  dut->PrivilegedPlugin_logic_harts_0_int_s_external = 0;
  dut->LsuL1Axi4Plugin_logic_axi_aw_ready = 0; dut->LsuL1Axi4Plugin_logic_axi_w_ready = 0;
  dut->LsuL1Axi4Plugin_logic_axi_b_valid = 0; dut->LsuL1Axi4Plugin_logic_axi_b_payload_resp = 0;
  dut->LsuL1Axi4Plugin_logic_axi_ar_ready = 0; dut->LsuL1Axi4Plugin_logic_axi_r_valid = 0;
  dut->LsuL1Axi4Plugin_logic_axi_r_payload_data = 0; dut->LsuL1Axi4Plugin_logic_axi_r_payload_resp = 0;
  dut->LsuL1Axi4Plugin_logic_axi_r_payload_last = 0;
  dut->FetchL1Axi4Plugin_logic_axi_ar_ready = 0; dut->FetchL1Axi4Plugin_logic_axi_r_valid = 0;
  dut->FetchL1Axi4Plugin_logic_axi_r_payload_data = 0; dut->FetchL1Axi4Plugin_logic_axi_r_payload_resp = 0;
  dut->FetchL1Axi4Plugin_logic_axi_r_payload_last = 0;
  dut->LsuCachelessAxi4Plugin_logic_axi_aw_ready = 0; dut->LsuCachelessAxi4Plugin_logic_axi_w_ready = 0;
  dut->LsuCachelessAxi4Plugin_logic_axi_b_valid = 0; dut->LsuCachelessAxi4Plugin_logic_axi_b_payload_resp = 0;
  dut->LsuCachelessAxi4Plugin_logic_axi_ar_ready = 0; dut->LsuCachelessAxi4Plugin_logic_axi_r_valid = 0;
  dut->LsuCachelessAxi4Plugin_logic_axi_r_payload_data = 0; dut->LsuCachelessAxi4Plugin_logic_axi_r_payload_resp = 0;
  dut->LsuCachelessAxi4Plugin_logic_axi_r_payload_last = 0;

  for (int i = 0; i < 32; i++) { eval_low(); eval_high(); }
  dut->reset = 0;

  uint64_t cyc = 0;
  for (; cyc < maxCyc; cyc++) {
    eval_low();

    // ---- 采样本拍握手（ready 为上一拍 commit 驱动的值）----
    bool f_ar = dut->FetchL1Axi4Plugin_logic_axi_ar_valid && dut->FetchL1Axi4Plugin_logic_axi_ar_ready;
    bool f_r  = dut->FetchL1Axi4Plugin_logic_axi_r_valid  && dut->FetchL1Axi4Plugin_logic_axi_r_ready;
    bool l_ar = dut->LsuL1Axi4Plugin_logic_axi_ar_valid && dut->LsuL1Axi4Plugin_logic_axi_ar_ready;
    bool l_r  = dut->LsuL1Axi4Plugin_logic_axi_r_valid  && dut->LsuL1Axi4Plugin_logic_axi_r_ready;
    bool l_aw = dut->LsuL1Axi4Plugin_logic_axi_aw_valid && dut->LsuL1Axi4Plugin_logic_axi_aw_ready;
    bool l_w  = dut->LsuL1Axi4Plugin_logic_axi_w_valid  && dut->LsuL1Axi4Plugin_logic_axi_w_ready;
    bool l_b  = dut->LsuL1Axi4Plugin_logic_axi_b_valid  && dut->LsuL1Axi4Plugin_logic_axi_b_ready;
    bool c_ar = dut->LsuCachelessAxi4Plugin_logic_axi_ar_valid && dut->LsuCachelessAxi4Plugin_logic_axi_ar_ready;
    bool c_r  = dut->LsuCachelessAxi4Plugin_logic_axi_r_valid  && dut->LsuCachelessAxi4Plugin_logic_axi_r_ready;
    bool c_aw = dut->LsuCachelessAxi4Plugin_logic_axi_aw_valid && dut->LsuCachelessAxi4Plugin_logic_axi_aw_ready;
    bool c_w  = dut->LsuCachelessAxi4Plugin_logic_axi_w_valid  && dut->LsuCachelessAxi4Plugin_logic_axi_w_ready;
    bool c_b  = dut->LsuCachelessAxi4Plugin_logic_axi_b_valid  && dut->LsuCachelessAxi4Plugin_logic_axi_b_ready;

    if (f_ar) g_rd_fetch.ar_fire(dut->FetchL1Axi4Plugin_logic_axi_ar_payload_addr, dut->FetchL1Axi4Plugin_logic_axi_ar_payload_len);
    if (l_ar) g_rd_lsu.ar_fire(dut->LsuL1Axi4Plugin_logic_axi_ar_payload_addr, dut->LsuL1Axi4Plugin_logic_axi_ar_payload_len);
    if (c_ar) g_rd_cc.ar_fire(dut->LsuCachelessAxi4Plugin_logic_axi_ar_payload_addr, 0);
    if (l_aw) g_wr_lsu.aw_fire(dut->LsuL1Axi4Plugin_logic_axi_aw_payload_addr, dut->LsuL1Axi4Plugin_logic_axi_aw_payload_len);
    if (c_aw) g_wr_cc.aw_fire(dut->LsuCachelessAxi4Plugin_logic_axi_aw_payload_addr, 0);
    if (l_w)  g_wr_lsu.w_fire(dut->LsuL1Axi4Plugin_logic_axi_w_payload_data,
                              dut->LsuL1Axi4Plugin_logic_axi_w_payload_strb, dut->LsuL1Axi4Plugin_logic_axi_w_payload_last);
    if (c_w)  g_wr_cc.w_fire(dut->LsuCachelessAxi4Plugin_logic_axi_w_payload_data,
                              dut->LsuCachelessAxi4Plugin_logic_axi_w_payload_strb, true);

    g_rd_fetch.cycle(f_r); g_rd_lsu.cycle(l_r); g_rd_cc.cycle(c_r);
    g_wr_lsu.cycle(l_b);   g_wr_cc.cycle(c_b);

    eval_high();

    // ---- 为下一拍驱动从口 ----
    dut->FetchL1Axi4Plugin_logic_axi_ar_ready = g_rd_fetch.ar_ready();
    dut->FetchL1Axi4Plugin_logic_axi_r_valid = g_rd_fetch.r_valid();
    dut->FetchL1Axi4Plugin_logic_axi_r_payload_data = mem_rd64(g_rd_fetch.addr + (uint32_t)g_rd_fetch.beat * 8);
    dut->FetchL1Axi4Plugin_logic_axi_r_payload_resp = 0;
    dut->FetchL1Axi4Plugin_logic_axi_r_payload_last = g_rd_fetch.r_last();

    dut->LsuL1Axi4Plugin_logic_axi_ar_ready = g_rd_lsu.ar_ready();
    dut->LsuL1Axi4Plugin_logic_axi_r_valid = g_rd_lsu.r_valid();
    dut->LsuL1Axi4Plugin_logic_axi_r_payload_data = mem_rd64(g_rd_lsu.addr + (uint32_t)g_rd_lsu.beat * 8);
    dut->LsuL1Axi4Plugin_logic_axi_r_payload_resp = 0;
    dut->LsuL1Axi4Plugin_logic_axi_r_payload_last = g_rd_lsu.r_last();
    dut->LsuL1Axi4Plugin_logic_axi_aw_ready = g_wr_lsu.aw_ready();
    dut->LsuL1Axi4Plugin_logic_axi_w_ready = g_wr_lsu.w_ready();
    dut->LsuL1Axi4Plugin_logic_axi_b_valid = g_wr_lsu.b_valid;
    dut->LsuL1Axi4Plugin_logic_axi_b_payload_resp = 0;

    dut->LsuCachelessAxi4Plugin_logic_axi_ar_ready = g_rd_cc.ar_ready();
    dut->LsuCachelessAxi4Plugin_logic_axi_r_valid = g_rd_cc.r_valid();
    {
      uint32_t a = g_rd_cc.addr + (uint32_t)g_rd_cc.beat * 4;
      uint32_t v = 0;
      if (a == 0xF0001014u) v = 0x60u;
      else if (a == 0x1001BFF8u) v = (uint32_t)g_mtime;
      dut->LsuCachelessAxi4Plugin_logic_axi_r_payload_data = v;
    }
    dut->LsuCachelessAxi4Plugin_logic_axi_r_payload_resp = 0;
    dut->LsuCachelessAxi4Plugin_logic_axi_r_payload_last = 1;
    dut->LsuCachelessAxi4Plugin_logic_axi_aw_ready = g_wr_cc.aw_ready();
    dut->LsuCachelessAxi4Plugin_logic_axi_w_ready = g_wr_cc.w_ready();
    dut->LsuCachelessAxi4Plugin_logic_axi_b_valid = g_wr_cc.b_valid;
    dut->LsuCachelessAxi4Plugin_logic_axi_b_payload_resp = 0;

    g_mtime++;
    dut->PrivilegedPlugin_logic_rdtime = g_mtime;

    if (has_line(g_uart, "crcfinal")) break;
  }

  printf("\n[tb] cycles=%llu mtime=%llu uart_bytes=%zu\n", (unsigned long long)cyc,
         (unsigned long long)g_mtime, g_uart.size());
  printf("---- UART ----\n%s\n--------------\n", g_uart.c_str());

  double ticks = 0, iters = 0;
  size_t p = g_uart.find("Total ticks");
  if (p != std::string::npos) { size_t q = g_uart.find(':', p); if (q != std::string::npos) ticks = strtod(g_uart.c_str() + q + 1, nullptr); }
  p = g_uart.find("Iterations       :");
  if (p != std::string::npos) { size_t q = g_uart.find(':', p); if (q != std::string::npos) iters = strtod(g_uart.c_str() + q + 1, nullptr); }
  if (ticks > 0) printf("[tb] ticks=%.0f iters=%.0f => CoreMark/MHz = %.4f (iters*1e6/ticks)\n",
                        ticks, iters, iters * 1e6 / ticks);
  else           printf("[tb] could not parse ticks/iters\n");

  delete dut;
  return (has_line(g_uart, "crcfinal") && ticks > 0) ? 0 : 1;
}
