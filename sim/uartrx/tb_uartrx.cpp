// ===================== UARTRx 收字节单元装置 =====================
// DUT = rtl/YeshenSocGlue.v 里抽出来的 `module UARTRx`（run_unit.sh 每次重新抽，测的就是交付产物）。
//
// 为什么需要它（2026-10-07 板级实测定案）：
//   板子上板后控制台"**单个字符能回显、连发一串全丢**"（10 个 'q' 间隔 100ms 发 = 10/10 回显；
//   连发 10 个 = 0/10、30 个 = 0/30）。根因在 UARTRx 的采样栅格：
//     · 起始位采样之后，第一个数据位只隔 **3** 个 baudTick（应为 4）⇒ 所有数据位都早半位；
//     · FSM 恒走 **sParity** 槽（本口是 8N1，没有校验位）⇒ 停止位采样点再晚一位
//       ⇒ 落在**下一字节的起始位**里 ⇒ 判帧错 ⇒ 整字节丢弃。
//   ⇒ 只有"后面跟空闲"的孤立字节收得下；任何背靠背突发全灭。
//
// 判据（必须能翻红）：4 个相位 × 3 个序列，收到的字节必须**逐字节正确且数量精确**。
//   phase    = 起始沿相对 baudTick 栅格的偏移（0..3 拍），实测系统里是随机的，必须全试。
//   序列 A   = 1 字节 + 长空闲（现状本来就能过 —— 正控，保证装置不是恒红）
//   序列 B   = "HELLO" 5 字节背靠背
//   序列 C   = 0x00..0x0F 16 字节背靠背
// 注：装置必须打印 `=== TEST PASSED === / === TEST FAILED ===`（run_unit.sh 按此行判)。
//
// 时序口径：baudTick 周期 4 拍 ⇒ 1 位 = 4 tick = 16 拍（与 Uart16550 里 `rxTick` 的
//   "位周期 = 16*bdiv" 同一比例；DUT 内部只看 tick，不看分频绝对拍数）。

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "VUARTRx.h"
#include "verilated.h"

static const int BIT = 16;     // 一位 = 16 拍
static const int TICKDIV = 4;  // baudTick 每 4 拍一次 ⇒ 一位 = 4 tick

static VUARTRx *dut;
static uint64_t cyc = 0;

struct Sent {
  std::vector<int> bytes;
  uint64_t t0 = 0;
  bool active = false;
};

static Sent run;

static int level_at(uint64_t t) {
  if (!run.active) return 1;
  if (t < run.t0) return 1;
  uint64_t rel = t - run.t0;
  uint64_t frame = rel / (10 * BIT);
  if (frame >= run.bytes.size()) return 1;  // 发完 → 空闲高
  int slot = (int)((rel % (10 * BIT)) / BIT);  // 0=起始 1..8=数据 9=停止
  if (slot == 0) return 0;
  if (slot == 9) return 1;
  return (run.bytes[frame] >> (slot - 1)) & 1;
}

// 推进一拍；返回本拍是否收到字节（valid 是 1 拍脉冲 ⇒ 每拍都要看）
static bool step() {
  dut->io_baudTick = (cyc % TICKDIV == 0);
  dut->io_rxd = level_at(cyc);
  dut->clock = 0;
  dut->eval();
  dut->clock = 1;
  dut->eval();
  cyc++;
  return dut->io_valid != 0;
}

static void reset_dut() {
  dut->clock = 0;
  dut->io_rxd = 1;
  dut->io_baudTick = 0;
  dut->reset = 1;
  for (int i = 0; i < 8; i++) {
    dut->clock = 0;
    dut->eval();
    dut->clock = 1;
    dut->eval();
  }
  dut->reset = 0;
  dut->eval();
}

struct CaseResult {
  std::string name;
  std::vector<int> want;
  std::vector<int> got;
  bool ok() const {
    if (want.size() != got.size()) return false;
    for (size_t i = 0; i < want.size(); i++)
      if (want[i] != got[i]) return false;
    return true;
  }
};

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  dut = new VUARTRx;

  std::vector<CaseResult> results;

  for (int phase = 0; phase < 4; phase++) {
    std::vector<std::vector<int>> seqs;
    seqs.push_back({0x55});                              // A：孤立字节（正控）
    seqs.push_back({0x48, 0x45, 0x4C, 0x4C, 0x4F});      // B："HELLO"
    {
      std::vector<int> v;                                 // C：0x00..0x0F
      for (int i = 0; i < 16; i++) v.push_back(i);
      seqs.push_back(v);
    }

    const char *names[3] = {"A-single", "B-burst5", "C-burst16"};

    for (int si = 0; si < 3; si++) {
      reset_dut();
      cyc = 0;
      run.bytes = seqs[si];
      run.active = true;
      run.t0 = (uint64_t)phase + BIT;  // 起始沿相对 tick 栅格偏移 phase 拍

      uint64_t total = run.t0 + (uint64_t)run.bytes.size() * 10 * BIT + 6 * BIT;
      std::vector<int> got;
      while (cyc < total) {
        if (step()) got.push_back(dut->io_data);
      }
      run.active = false;

      CaseResult r;
      r.name = std::string("phase") + std::to_string(phase) + "/" + names[si];
      r.want = run.bytes;
      r.got = got;
      results.push_back(r);

      printf("[case] %-18s want %2zu B, got %2zu B, %s\n", r.name.c_str(),
             r.want.size(), r.got.size(), r.ok() ? "OK" : "MISMATCH");
      if (!r.ok()) {
        printf("        want:");
        for (int b : r.want) printf(" %02X", b);
        printf("\n        got :");
        for (int b : r.got) printf(" %02X", b);
        printf("\n");
      }
    }
  }

  int bad = 0;
  for (auto &r : results)
    if (!r.ok()) bad++;

  printf("---- %zu cases, %d failed ----\n", results.size(), bad);
  printf("=== TEST %s ===\n", bad ? "FAILED" : "PASSED");
  delete dut;
  return bad ? 1 : 0;
}
