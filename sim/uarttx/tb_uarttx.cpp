// ===================== UARTTx 发帧形状单元装置 =====================
// DUT = rtl/YeshenSocGlue.v 里抽出来的 `module UARTTx`（run_unit.sh 每次重抽 ⇒ 测的是交付产物）。
//
// 为什么需要它（2026-10-07）：控制台是 8N1（`lcrReg=0x13`，校验位不实现），但 UARTTx 原来
// **不管 LCR 怎么写都恒发一个校验位** ⇒ 一帧 = 11 位（start+8data+parity+stop）。对端按 8N1 收时
// "停止位"位置上读到的是校验位：校验位=0 的字节（'H'=0x48、0x00、0x55…）被对端判帧错。
// USB 桥一般仍把字节交出来，所以启动日志"看起来是对的"⇒ 这个缺陷被掩盖了很久。
//
// 方法（**每字节单独复位、只发一帧** ⇒ 波形无歧义，不做任何"帧长猜测"）：
//   复位 → 第 16 拍给 1 拍 io_start → 录 40 位；
//   ① e = 第一个下降沿（帧起点）；
//   ② 用 **8N1/10 位模板**（start + 8data(LSB 先) + stop=1）逐拍比对 [e, e+10*BIT)，
//      要求**零失配**；
//   ③ 用 **带校验位/11 位模板** 比对 [e, e+11*BIT)，要求**必须失配** ⇒ 证明"确实没有校验位槽"；
//   ④ 帧后 [e+10*BIT, e+12*BIT) 必须全高（回到空闲）。
//   覆盖 0x00/0x55/0xAA/0x48/0xFF/0x41/0x7E（校验位 0/1 的都要测）。
// 负对照：`run_unit.sh --negctl` 对抽出的模块做单行变异（数据位 7 的下一状态 3'h4→3'h3，
//   插回校验位槽）⇒ 本装置必须判 FAIL。变异只落在临时副本，交付产物零改动（前后记 md5）。
// 时序口径：baudTick 周期 4 拍 ⇒ 1 位 = 16 拍。

#include <cstdint>
#include <cstdio>
#include <vector>

#include "VUARTTx.h"
#include "verilated.h"

static const int BIT = 16;
static const int TICKDIV = 4;

static VUARTTx *dut;
static uint64_t cyc = 0;

static void tick_edge() {
  dut->clock = 0;
  dut->eval();
  dut->clock = 1;
  dut->eval();
  cyc++;
}

static void reset_dut() {
  dut->clock = 0;
  dut->io_data = 0;
  dut->io_start = 0;
  dut->io_baudTick = 0;
  dut->reset = 1;
  for (int i = 0; i < 8; i++) tick_edge();
  dut->reset = 0;
  dut->eval();
}

static int parity_of(int b) {
  int p = 0;
  for (int i = 0; i < 8; i++) p ^= (b >> i) & 1;
  return p;
}

// 与期望位序列逐拍比对（跳过每格边界 ±2 拍），返回失配拍数
static int cmp_bits(const std::vector<int> &wave, size_t e, const std::vector<int> &bits) {
  int mm = 0;
  for (size_t s = 0; s < bits.size(); s++)
    for (int k = 2; k < BIT - 1; k++) {
      size_t idx = e + s * BIT + k;
      if (idx < wave.size() && wave[idx] != bits[s]) mm++;
    }
  return mm;
}

static std::vector<int> tmpl(int b, int w) {
  std::vector<int> bits;
  bits.push_back(0);
  for (int i = 0; i < 8; i++) bits.push_back((b >> i) & 1);
  if (w == 11) bits.push_back(parity_of(b));
  bits.push_back(1);
  return bits;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  dut = new VUARTTx;

  const int payload[] = {0x00, 0x55, 0xAA, 0x48, 0xFF, 0x41, 0x7E};
  const int NP = (int)(sizeof(payload) / sizeof(payload[0]));
  int bad = 0;

  for (int i = 0; i < NP; i++) {
    int b = payload[i];
    reset_dut();
    cyc = 0;
    std::vector<int> wave;

    // 16 拍空闲，然后 1 拍 io_start
    auto pump = [&](int n, int data, int start) {
      for (int k = 0; k < n; k++) {
        dut->io_data = data;
        dut->io_start = start;
        dut->io_baudTick = (cyc % TICKDIV == 0);
        wave.push_back(dut->io_txd);
        tick_edge();
      }
    };
    pump(16, b, 0);
    pump(1, b, 1);
    pump(45 * BIT, b, 0);

    size_t e = 0;
    bool found = false;
    for (size_t k = 1; k + 1 < wave.size(); k++)
      if (wave[k] == 1 && wave[k + 1] == 0) { e = k + 1; found = true; break; }

    if (!found) {
      printf("  byte=0x%02X  !! 找不到起始沿\n", b);
      bad++;
      continue;
    }
    int mm10 = cmp_bits(wave, e, tmpl(b, 10));
    int mm11 = cmp_bits(wave, e, tmpl(b, 11));
    bool idle_ok = true;
    for (int c = 0; c < 2 * BIT; c++) {
      size_t idx = e + 10 * (size_t)BIT + c;
      if (idx >= wave.size() || wave[idx] != 1) idle_ok = false;
    }
    bool ok = (mm10 == 0) && (mm11 > 0) && idle_ok;
    printf("  byte=0x%02X parity=%d  e=%zu  mm(8N1/10bit)=%-3d mm(11bit)=%-3d idle_after=%d  %s\n",
           b, parity_of(b), e, mm10, mm11, (int)idle_ok, ok ? "OK" : "BAD");
    if (!ok) {
      bad++;
      printf("        wave = ");
      for (size_t c = 0; c < wave.size() && c < e + 13 * (size_t)BIT; c++)
        if (c >= e) putchar('0' + wave[c]);
      printf("\n");
      printf("        8N1 = ");
      for (int v : tmpl(b, 10)) for (int k = 0; k < BIT; k++) putchar('0' + v);
      printf("\n");
    }
  }

  printf("---- %d problems ----\n", bad);
  printf("=== TEST %s ===\n", bad ? "FAILED" : "PASSED");
  delete dut;
  return bad ? 1 : 0;
}
