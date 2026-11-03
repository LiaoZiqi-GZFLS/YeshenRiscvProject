// ===================== MemArbiter 单元判决装置（真仲裁器 / Phase-1）=====================
//
// DUT：--top-module MemArbiter（网表 build_memarb/MemArbiter.v，由
//      `java -cp YeshenSocGlue.jar MemArbiter build_memarb` 生成；参数 N=3 / WEIGHTS=(2,1,1) /
//      AGE_MAX=32 —— 见 src/soc/MemArbiter.scala 的 `object MemArbiter`）。
//
// 本装置把仲裁器**当成一个"授权调度器"**来判（这正是它的接口，见其文件头）：
//   · 每拍给 io_req_0..2（三类各自"有请求"）+ io_free（总线空闲）；
//   · 采样 io_pick / io_pickV（本拍授给谁）；
//   · **事务模型**：一旦授予某类，就让 io_free=0 保持 T 拍（T 由确定性 LCG 取 txMin..txMax），
//     模拟"一笔事务占住总线 T 拍"，然后 io_free=1。⇒ 授权延迟是**实拍数**。
//
// 两个延迟口径（都在"一段连续请求"内测）：
//   · **lat**（拍）   = 从该类请求**连续抬起**的那一拍，到它被授予那一拍（含）的拍数；
//   · **miss**（次）  = 这段等待里"**它想要、总线也空闲**、却没被授予"的拍数 = **错过的授权机会数**。
//     `miss` 是本仲裁器**内在**的公平性口径（与事务长短无关）；`lat` 是端到端口径。
//
// 判据（每条都有负对照，见 sim/memarb/negctl_memarb.sh）：
//   J1 **有界等待（正）**：并发压力下每类的最坏 `miss` ≤ BOUND_OPP 且最坏 `lat` ≤ BOUND_CYC。
//   J2 **无饿死（正）**：并发压力下每类的授予次数 ≥ MIN_GRANTS。
//   J3 **配额（正）**：满争用作业里授予次数 CPU:NPU:DMA ≈ 2:1:1（= 权重），在容忍窗口内。
//   J4 **单主人不变性（回归）**：只有一类有请求时，它的 `miss` **恒为 0**（每个空闲拍都被授予）、
//     另两类授予数**恒为 0** ⇒ 与"直接连过去"逐拍同值。
//   J5 **纪律**：任何一拍都不许 pickV=1 而 free=0。
//   J6 **守卫不扰动配额（正）**：正常权重下三类都不进 starving（配额就是权重比，不被老化扰动）。
//
// 时钟：单时钟 clock；reset **同步高有效**（Chisel 生成）。复位保持 4 拍。
// ⚠️ 采样/推进分两步（照 sim/ddr3bridge、sim/glue_pbus 的惯例）：
//   settle()  = 本拍**上升沿之前** eval 并采样组合输出（pick/pickV 都是**组合**的）；
//   advance() = 打上升沿（寄存器更新）→ **边沿后**先记账、再推进事务模型（算出下一拍 req/free）→ 落低。
#include "VMemArbiter.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>

// -------------------- 参数（与 src/soc/MemArbiter.scala 的 GEN_* 对齐）--------------------
#define NCLS        3
#define W_CPU       2
#define W_NPU       1
#define W_DMA       1
#define AGE_MAX     32
#define BOUND_OPP   6        // J1：内在口径上界（WRR 的 W-1 = 3，留余量）
#define BOUND_CYC   40       // J1：短事务（T<=3）的拍数上界
#define MIN_GRANTS  2000

static VMemArbiter* dut = nullptr;
static uint64_t cyc = 0;
static int nFail = 0;
static void fail(const char* what) { printf("  [FAIL] %s\n", what); nFail++; }

// -------------------- 确定性 LCG（可复现）--------------------
static uint32_t rngState = 0x1234ABCDu;
static uint32_t rngNext() { rngState = rngState * 1664525u + 1013904223u; return rngState >> 8; }
static int rngRange(int lo, int hi) { return lo + (int)(rngNext() % (uint32_t)(hi - lo + 1)); }

static int  g_pick = 0;
static bool g_pickV = false;

static bool  req[NCLS];          // 本拍给 DUT 的 req
static bool  freeIn = true;      // 本拍给 DUT 的 free
static int   busyLeft = 0;       // 事务占住总线剩余拍数（>0 ⇒ free=0）
static int   txMin = 1, txMax = 3;

static int   prob[NCLS];         // 每类"想要"的百分比
static bool  want[NCLS];

static long  nGrant[NCLS];
static long  maxLat[NCLS], sumLat[NCLS], nLat[NCLS];
static long  maxMiss[NCLS];
static bool  dem[NCLS];          // 该类当前有一段"连续请求"在等
static long  demStart[NCLS];
static long  miss[NCLS];         // 当前这段等待里错过的授权机会数

static long  nPickVwhenBusy = 0; // 纪律：pickV=1 而 free=0（不许发生）
static long  nStarveCycles[NCLS]; // 只读观察：各类处于 starving 的拍数（老化在工作）

static void resetStats() {
  for (int c = 0; c < NCLS; ++c) {
    nGrant[c]=0; maxLat[c]=0; sumLat[c]=0; nLat[c]=0; maxMiss[c]=0;
    dem[c]=false; demStart[c]=0; miss[c]=0; nStarveCycles[c]=0;
  }
  nPickVwhenBusy = 0; busyLeft = 0; freeIn = true;
  for (int c = 0; c < NCLS; ++c) req[c] = false;
}

static void settle() {
  dut->eval();
  g_pick  = (int)dut->io_pick;
  g_pickV = dut->io_pickV != 0;
  if (g_pickV && !freeIn) nPickVwhenBusy++;
  uint32_t sv = (uint32_t)dut->io_dbgStarve;
  for (int c = 0; c < NCLS; ++c) if ((sv >> c) & 1u) nStarveCycles[c]++;
}

// 在当前（第 cyc 拍）的输入与采样结果上记账，然后推进工作量与事务模型到下一拍。
static void modelPostEdge() {
  for (int c = 0; c < NCLS; ++c) {
    bool granted = g_pickV && (g_pick == c);
    // --- 本拍记账 ---
    if (req[c] && !granted) {
      if (!dem[c]) { dem[c] = true; demStart[c] = (long)cyc; miss[c] = 0; }
      if (freeIn) miss[c]++;                      // 想要 + 总线空闲 + 没给我 = 错过一次机会
    }
    if (granted) {
      nGrant[c]++;
      if (dem[c]) {
        long lat = (long)(cyc - demStart[c]) + 1;
        if (lat > maxLat[c]) maxLat[c] = lat;
        if (miss[c] > maxMiss[c]) maxMiss[c] = miss[c];
        sumLat[c] += lat; nLat[c]++;
      }
      dem[c] = false;
    }
    // --- 下一拍的请求（被服务的那类下一拍重新抬 = 背靠背）---
    want[c] = (rngRange(0, 99) < prob[c]);
    req[c] = want[c];
    if (!want[c]) dem[c] = false;                 // 撤销请求 ⇒ 这一段作废
  }
  // 事务模型：本拍被授予 ⇒ 从**下一拍**起占住总线 txMin..txMax 拍（free=0），然后 free=1
  if (g_pickV) busyLeft = rngRange(txMin, txMax);
  if (busyLeft > 0) { busyLeft--; freeIn = false; }
  else freeIn = true;
}

static void applyInputs() {
  dut->io_req_0 = req[0] ? 1 : 0;
  dut->io_req_1 = req[1] ? 1 : 0;
  dut->io_req_2 = req[2] ? 1 : 0;
  dut->io_free  = freeIn ? 1 : 0;
}
static void advance() {
  applyInputs();
  dut->clock = 1; dut->eval();
  modelPostEdge();
  dut->clock = 0; dut->eval();
  cyc++;
}
static void tick() { applyInputs(); settle(); advance(); }

static void runJob(const char* tag, long ncyc, int p0, int p1, int p2) {
  resetStats();
  prob[0]=p0; prob[1]=p1; prob[2]=p2;
  // 起始**所有 req 都低**（否则第 0 拍会"凭空"给非目标类一次授予，把单主人回归测歪）
  for (int c = 0; c < NCLS; ++c) { req[c]=false; want[c]=false; dem[c]=false; miss[c]=0; demStart[c]=(long)cyc; }
  freeIn = true; busyLeft = 0;
  applyInputs();
  for (long k = 0; k < ncyc; ++k) tick();
  printf("  [JOB %-7s] grants CPU=%-6ld NPU=%-6ld DMA=%-6ld | maxLat %2ld/%2ld/%2ld cyc | maxMiss %ld/%ld/%ld | starveCyc %ld/%ld/%ld\n",
         tag, nGrant[0], nGrant[1], nGrant[2], maxLat[0], maxLat[1], maxLat[2],
         maxMiss[0], maxMiss[1], maxMiss[2], nStarveCycles[0], nStarveCycles[1], nStarveCycles[2]);
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  dut = new VMemArbiter;
  dut->clock = 0; dut->reset = 1; dut->io_req_0 = 0; dut->io_req_1 = 0; dut->io_req_2 = 0; dut->io_free = 0;
  for (int k = 0; k < 4; ++k) { dut->clock = 1; dut->eval(); dut->clock = 0; dut->eval(); cyc++; }
  dut->reset = 0;
  printf("=== MemArbiter 单元判决（N=%d, W=(%d,%d,%d), AGE_MAX=%d, BOUND_OPP<=%d, BOUND_CYC<=%d）===\n",
         NCLS, W_CPU, W_NPU, W_DMA, AGE_MAX, BOUND_OPP, BOUND_CYC);

  // ---- J1/J2：并发压力（CPU 重、NPU 中、DMA 满 ⇒ DMA 是被保护的低优先类）----
  txMin = 1; txMax = 3;
  runJob("stress", 200000, 90, 80, 100);
  for (int c = 0; c < NCLS; ++c) {
    if (nGrant[c] == 0) fail("J1 有界等待失败：某类一次都没被授予（等待 = 无界）");
    if (maxMiss[c] > BOUND_OPP) fail("J1 有界等待失败：某类最坏 miss > 上界");
    if (maxLat[c]  > BOUND_CYC) fail("J1 有界等待失败：某类最坏 lat > 上界");
    if (nGrant[c]  < MIN_GRANTS) fail("J2 无饿死失败：某类授予次数 < 下限");
  }

  // ---- J3：满争用 ⇒ 授予比 ≈ 权重 2:1:1 ----
  runJob("full", 200000, 100, 100, 100);
  {
    double r01 = nGrant[1] ? (double)nGrant[0]/nGrant[1] : 0.0;
    double r21 = nGrant[1] ? (double)nGrant[2]/nGrant[1] : 0.0;
    printf("  [QUOTA] CPU:NPU = %.3f (期望 ~2.0) | DMA:NPU = %.3f (期望 ~1.0)\n", r01, r21);
    if (!(r01 > 1.7 && r01 < 2.3)) fail("J3 配额比 CPU:NPU 不在 2:1 窗口");
    if (!(r21 > 0.8 && r21 < 1.2)) fail("J3 配额比 DMA:NPU 不在 1:1 窗口");
    for (int c = 0; c < NCLS; ++c) if (maxMiss[c] > BOUND_OPP || maxLat[c] > BOUND_CYC)
      fail("J1（满争用）有界等待失败");
  }

  // ---- J6：老化守卫**没有被误触发**（正常权重下配额不被扰动；starveCycles 应为 0）----
  //   本项是"配额不被扰动"的正向证据；负对照见 NC-D（pickV 门被咬掉 ⇒ 单主人出现气泡）。
  if (nStarveCycles[0] != 0 || nStarveCycles[1] != 0 || nStarveCycles[2] != 0)
    fail("J6 守卫误触发：正常权重下出现了 starving（配额会被扰动）");
  printf("  [GUARD] 正常权重下各 starving 拍数 = %ld/%ld/%ld（应为 0 ⇒ 配额不被老化扰动）\n",
         nStarveCycles[0], nStarveCycles[1], nStarveCycles[2]);

  // ---- J5 纪律 ----
  if (nPickVwhenBusy != 0) fail("J5 纪律：出现 pickV=1 而 free=0");

  // ---- J4 单主人回归（三类各跑一遍）----
  for (int only = 0; only < NCLS; ++only) {
    int p[NCLS] = {0,0,0}; p[only] = 100;
    txMin = 1; txMax = 1;
    runJob(only==0?"singleC":(only==1?"singleN":"singleD"), 20000, p[0], p[1], p[2]);
    const char* nm = only==0?"CPU":(only==1?"NPU":"DMA");
    if (maxMiss[only] != 0) fail("J4 单主人失败：出现附加延迟（miss != 0）");
    if (maxLat[only] != 2)  fail("J4 单主人失败：最坏 lat != 2（T=1 的模型下应恒为 2）");
    if (nGrant[(only+1)%3] != 0 || nGrant[(only+2)%3] != 0) fail("J4 单主人失败：授予了别的类");
    if (nGrant[only] < 5000) fail("J4 单主人失败：授予次数太少（没在跑？）");
    printf("  [SINGLE %s] grants=%ld maxLat=%ld maxMiss=%ld（另两类 0 授予）\n",
           nm, nGrant[only], maxLat[only], maxMiss[only]);
  }

  printf("\n%s\n", nFail ? "=== TEST FAILED ===" : "=== TEST PASSED ===");
  delete dut;
  return nFail ? 1 : 0;
}
