// ===================== Uart16550 接收 FIFO 单元装置 =====================
// DUT = rtl/YeshenSocGlue.v 里抽出来的 `module Uart16550`（run_unit.sh 每次重抽 ⇒ 测的是交付产物）。
// 走**真 AXI-Lite**（sAW→sW→sB / sAR→sR 三拍），与 SoC 的 pBus FSM 同款握手。
//
// 为什么需要它（2026-10-07 板级定案）：本模块对外按 16550A 上报（`fifo_size=16`），而 RX 侧原来
// **只有 1 级**寄存器。板级实测（240 字符）：
//   · 背靠背 40 字符：**只保住 82.5%–85%**（丢的位置是散的）；
//   · 每字符间隔 20 ms 发同样 40 个：**100% 全保住**。
// ⇒ 丢的原因不是波特/采样，而是"到达那拍压在 8250 ISR 从断点到读 RBR 的窗口里"⇒ 1 级寄存器被**覆盖**。
// ⇒ 修法 = 16 深接收 FIFO。**本装置就是证明"硬件真能存下 16 个背靠背字节并按序吐出"**（这正是被覆盖窗口的对症）。
//
// 判据（每条都能翻红）：
//   ① 初始化：写 DLL=1/DLM=0/LCR=0x03（⇒ 位周期 = 16*bdiv = 16 拍）—— 用真 AXI-Lite 写；
//   ② 背靠背灌 **16 字节**（0x80..0x8F）：轮询 LSR.DR 逐字节读出，必须**逐字节相等且一个不丢**；
//   ③ 读空后 LSR.DR 必须为 0（FIFO 空 ⇒ DR=0）；
//   ④ 溢出：再灌 **20 字节**（0x00..0x13）：只应读出 **16** 个（0x00..0x0F，**顺序不乱**：丢的是后来的，
//      不是覆盖最早的），且 LSR.bit1(OE) 被置起；读一次 LSR 后 OE 应清；
//   ⑤ FCR.bit1 清 FIFO：灌 4 字节后写 FCR=0x03（enable+clear RX）⇒ DR 立刻为 0；再读 RBR 不得吐出旧数据。
// 负对照（必须翻红）：`run_unit.sh --negctl` 把产物里那行接收推入条件
//   `wire rxPush = _rx_io_valid & ~rxFull & ~fcrRxClear;` 变异成"**只有 FIFO 为空才收**"
//   （等价于退回 1 级）⇒ 判据 ② 必须失败。变异只落临时副本，交付产物零改动（前后记 md5）。

#include <cstdint>
#include <cstdio>
#include <vector>

#include "VUart16550.h"
#include "verilated.h"

static const int BIT = 16;      // 位周期 = 16*bdiv，bdiv=1 ⇒ 16 拍
static const int TICKDIV = 4;   // baudTick 每 4 拍

// 寄存器（reg-shift=2 ⇒ 每个寄存器 4 字节；地址位 [4:2] 选寄存器）
enum { R_RBR = 0x00, R_IER = 0x04, R_FCR = 0x08, R_LCR = 0x0C, R_MCR = 0x10, R_LSR = 0x14 };

static VUart16550 *dut;
static uint64_t cyc = 0;
static int bad = 0;

static void tick_edge() {
  dut->clock = 0;
  dut->eval();
  dut->clock = 1;
  dut->eval();
  cyc++;
}

static void idle_cyc(int n) {
  for (int i = 0; i < n; i++) {
    tick_edge();
  }
}

// ---- 真 AXI-Lite 写（sAW → sW → sB 三拍，与 SoC 的 MMIO FSM 同款）----
static void axil_write(uint32_t addr, uint32_t data) {
  dut->io_axi_awaddr = addr & 0x1f;
  dut->io_axi_awvalid = 1;
  dut->io_axi_wdata = data;
  dut->io_axi_wvalid = 0;
  dut->io_axi_bready = 1;
  dut->io_axi_arvalid = 0;
  dut->io_axi_rready = 1;
  idle_cyc(1);
  dut->io_axi_awvalid = 0;
  dut->io_axi_wvalid = 1;
  idle_cyc(1);
  dut->io_axi_wvalid = 0;
  for (int i = 0; i < 8 && !dut->io_axi_bvalid; i++) idle_cyc(1);
  idle_cyc(1);
}

// ---- 真 AXI-Lite 读（sAR → sR 两拍）----
static uint32_t axil_read(uint32_t addr) {
  dut->io_axi_araddr = addr & 0x1f;
  dut->io_axi_arvalid = 1;
  dut->io_axi_awvalid = 0;
  dut->io_axi_wvalid = 0;
  dut->io_axi_bready = 1;
  dut->io_axi_rready = 1;
  idle_cyc(1);
  dut->io_axi_arvalid = 0;
  for (int i = 0; i < 8 && !dut->io_axi_rvalid; i++) idle_cyc(1);
  uint32_t v = dut->io_axi_rdata;
  idle_cyc(1);
  return v;
}

// ---- 在 io_rxd 上按 8N1 灌一个字节（一个位 = BIT 拍，与 bdiv=1 对齐）----
static void send_byte(int b) {
  int bits[10];
  bits[0] = 0;
  for (int i = 0; i < 8; i++) bits[i + 1] = (b >> i) & 1;
  bits[9] = 1;
  for (int s = 0; s < 10; s++)
    for (int k = 0; k < BIT; k++) {
      if (k == 0) dut->io_rxd = bits[s];
      tick_edge();
    }
  dut->io_rxd = 1;
}

static void reset_dut() {
  dut->clock = 0;
  dut->reset = 1;
  dut->io_rxd = 1;
  dut->io_axi_awaddr = 0;
  dut->io_axi_awvalid = 0;
  dut->io_axi_wdata = 0;
  dut->io_axi_wvalid = 0;
  dut->io_axi_bready = 1;
  dut->io_axi_araddr = 0;
  dut->io_axi_arvalid = 0;
  dut->io_axi_rready = 1;
  for (int i = 0; i < 8; i++) tick_edge();
  dut->reset = 0;
  dut->eval();
  cyc = 0;
}

static void init_port() {
  axil_write(R_LCR, 0x83);   // DLAB=1, 8N1
  axil_write(R_RBR, 1);      // DLL = 1  ⇒ 位周期 = 16 拍
  axil_write(R_IER, 0);      // DLM = 0
  axil_write(R_LCR, 0x03);   // DLAB=0, 8N1
  axil_write(R_FCR, 0x01);   // FIFO 使能
}

// 读走当前 FIFO 里的全部字节（先读 LSR 看 DR）
static std::vector<int> drain(int maxbytes) {
  std::vector<int> out;
  for (int i = 0; i < maxbytes; i++) {
    uint32_t lsr = axil_read(R_LSR);
    if (!(lsr & 1)) break;
    out.push_back((int)(axil_read(R_RBR) & 0xff));
  }
  return out;
}

static bool eq(const std::vector<int> &a, const std::vector<int> &b) {
  if (a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); i++)
    if (a[i] != b[i]) return false;
  return true;
}

static void dump(const char *tag, const std::vector<int> &v) {
  printf("      %s (%zu):", tag, v.size());
  for (int x : v) printf(" %02X", x);
  printf("\n");
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  dut = new VUart16550;

  // ---- ② 背靠背 16 字节：必须一个不丢、顺序正确 ----
  reset_dut();
  init_port();
  std::vector<int> want16;
  for (int i = 0; i < 16; i++) want16.push_back(0x80 + i);
  for (int b : want16) send_byte(b);
  idle_cyc(4 * BIT);
  std::vector<int> got16 = drain(32);
  bool ok16 = eq(got16, want16);
  printf("[case1] burst16  want 16 B, got %zu B -> %s\n", got16.size(), ok16 ? "OK" : "BAD");
  if (!ok16) { dump("want", want16); dump("got ", got16); bad++; }

  // ---- ③ 读空后 DR 必须为 0 ----
  uint32_t lsr = axil_read(R_LSR);
  bool ok_empty = (lsr & 1) == 0;
  printf("[case2] lsr_after_drain = 0x%02X (DR=%d) -> %s\n", lsr & 0xff, (int)(lsr & 1),
         ok_empty ? "OK" : "BAD");
  if (!ok_empty) bad++;

  // ---- ④ 溢出 20 字节：只应读出前 16 个、顺序不乱，且 OE 置起 / 读 LSR 后清 ----
  reset_dut();
  init_port();
  std::vector<int> want20;
  for (int i = 0; i < 20; i++) want20.push_back(0x00 + i);
  for (int b : want20) send_byte(b);
  idle_cyc(4 * BIT);
  uint32_t lsr_ovf = axil_read(R_LSR);
  bool oe_set = (lsr_ovf >> 1) & 1;
  std::vector<int> got = drain(32);
  std::vector<int> want_first16(want20.begin(), want20.begin() + 16);
  bool ok_ovf = (got.size() == 16) && eq(got, want_first16) && oe_set;
  printf("[case3] overflow: got %zu B, OE=%d -> %s\n", got.size(), (int)oe_set,
         ok_ovf ? "OK" : "BAD");
  if (!ok_ovf) { dump("want", want_first16); dump("got ", got); bad++; }
  uint32_t lsr2 = axil_read(R_LSR);
  bool oe_cleared = ((lsr2 >> 1) & 1) == 0;
  printf("[case4] OE cleared by reading LSR = %d -> %s\n", (int)oe_cleared,
         oe_cleared ? "OK" : "BAD");
  if (!oe_cleared) bad++;

  // ---- ⑤ FCR.bit1 清接收 FIFO ----
  reset_dut();
  init_port();
  for (int i = 0; i < 4; i++) send_byte(0x41 + i);
  idle_cyc(2 * BIT);
  axil_write(R_FCR, 0x03);            // enable + clear RX
  idle_cyc(4);
  uint32_t lsr_c = axil_read(R_LSR);
  bool ok_clear = (lsr_c & 1) == 0;
  std::vector<int> after = drain(4);
  printf("[case5] FCR clear: DR=%d, drained %zu B -> %s\n", (int)(lsr_c & 1), after.size(),
         (ok_clear && after.empty()) ? "OK" : "BAD");
  if (!(ok_clear && after.empty())) bad++;

  printf("---- %d problems ----\n", bad);
  printf("=== TEST %s ===\n", bad ? "FAILED" : "PASSED");
  delete dut;
  return bad ? 1 : 0;
}
