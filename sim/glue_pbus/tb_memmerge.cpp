// ===================== YeshenSocGlue 内存合并点（§3.5）判决装置 —— Phase-1 真仲裁 =====================
//
// DUT：--top-module YeshenSocGlue（网表 rtl/YeshenSocGlue.v）——**只读输入件**。
// 本装置把内存主口**当真主方**驱动（各自持 valid 直到 ready，AXI 标准背压），在 io_mem 上给一个
// 64bit、可做 INCR 突发的**内存模型**，然后判：
//
//   J_MM1（**正**：并发多主 + 有界等待）：把该跑的主口**同时**各跑一长串事务（读/写混），
//        ① 每主的每一笔都**完成**且**逐字节对**（读回 vs 本装置独立算出的图案）；
//        ② 每主观测到的**最坏授权延迟**（该笔 valid 首次抬起 → 对应 ready 握手，含）≤ BOUND_MM
//           ⇒ 无饿死（有界等待）。
//        ⚠️ 两套并发配置（见 main）：C1 = cpuLsu + npuMem（Phase-1 的两个真类）；
//          C2 = cpuFetch + npuMem。**为什么不做 cpuLsu+cpuFetch 同时背靠背**：CPU 组**类内**仍是
//          改前的固定优先级（LSU 写 > LSU 读 > Fetch 读），两主都背靠背时 Fetch 让位给 LSU ——
//          这是**改前就有的设计**（Phase-1 不动它），不是本相引入的饥饿（见报告 §"残余"）。
//   J_MM2（**回归**：单主人逐字节不变）：每主**独自**跑一份固定作业，把"完成序 + 地址 + 长度 +
//        每一拍数据"写成规范文本（transcript）；与**改动前网表**跑同一装置得到的 golden 比对
//        （`--golden` 记档 / `--compare` 比对）⇒ 仲裁器不许改变单主人行为。
//   J_MM3（纪律）：io_mem 上 ① AR 与 AW **永不**同拍（读写互斥，§4 的【纪律②】）；
//        ② 每笔读恰好一次 `rlast` 且只在末拍；③ 每笔写恰好一次 B；④ 读响应恒 OKAY。
//   J_MM5（L2b 回归）：NPU **背靠背多 outstanding 读** —— 合并点的 owner 必须保持到**末笔 rlast**；
//        内存模型带 4 深 AR 队列（与 DDR3Bridge outR 上限同量级）。旧网表在首笔 rlast 释放 owner
//        ⇒ 后续 R 被挡 ⇒ 本作业超时红（红证据用 `YeshenSocGlue_preL2b.v` 编同一装置即可复现）。
//
// ★ 负对照见 sim/glue_pbus/negctl_memmerge.sh（把 `ARB_WEIGHTS` 第 2 项打 0 ⇒ NPU 饿死 ⇒ J_MM1 红）。
//
// 用法：
//   ./memmerge_sim                                  # 只跑 J_MM1/J_MM3（阳性）
//   ./memmerge_sim --golden <file>                  # 另外把单主人 transcript 记到 <file>
//   ./memmerge_sim --compare <file>                 # 另外把本次单主人 transcript 与 <file> 比（不等即 FAIL）
//
// 时钟：单时钟 `clock`；`reset` **同步高有效**。采样/推进分两步（照 sim/ddr3bridge、sim/glue_pbus 惯例）：
//   settle()  = 摆输入 → eval → **采样**本拍握手值（下称 smp）；
//   advance() = 打上升沿（寄存器更新）→ 用 smp 推进主方/从方模型 → 落低。
#include "VYeshenSocGlue.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static VYeshenSocGlue* dut = nullptr;
static uint64_t cyc = 0;
static int nFail = 0;
static void fail(const char* what) { printf("  [FAIL] %s\n", what); nFail++; }

#define MEM_BYTES  (256*1024)
#define BOUND_MM   64       // J_MM1 的拍数上界（实测见 [LAT] 行；负对照会把它顶爆）
#define N_TX       300      // 并发作业每主的事务数

static uint8_t mem[MEM_BYTES];
static uint8_t expectByte(uint32_t a) { return (uint8_t)(0x5A + a * 7u + (a >> 8) * 13u); }
static uint64_t readMem64(uint32_t a) { uint64_t v = 0; for (int b = 0; b < 8; ++b) v |= (uint64_t)mem[(a + b) & (MEM_BYTES - 1)] << (8 * b); return v; }
static void writeMem64(uint32_t a, uint64_t d, uint8_t strb) { for (int b = 0; b < 8; ++b) if ((strb >> b) & 1) mem[(a + b) & (MEM_BYTES - 1)] = (uint8_t)(d >> (8 * b)); }

// -------------------- 端口指针（避免按名字写三遍）--------------------
struct RdSig { CData* arvalid; IData* araddr; CData* arlen; CData* arready;
               CData* rvalid; CData* rready; QData* rdata; CData* rresp; CData* rlast; };
struct WrSig { CData* awvalid; IData* awaddr; CData* awlen; CData* awready;
               CData* wvalid; QData* wdata; CData* wstrb; CData* wlast; CData* wready;
               CData* bvalid; CData* bready; CData* bresp; };

struct Mst {
  int  id; bool readOnly; uint32_t rdBase, wrBase;
  long total, done;
  bool active, arAcc, awAcc, wAll;
  bool isWrite; uint32_t addr; int len, beat; long startCyc;
  long nRd, nWr, maxArLat, maxAwLat;
  long nByteBad;
  std::vector<uint64_t> beatData;
};
static Mst m0, m1, m2;

static RdSig rdSigOf(const Mst& m) {
  if (m.id == 0) return RdSig{ &dut->io_cpuFetch_arvalid, &dut->io_cpuFetch_araddr, &dut->io_cpuFetch_arlen, &dut->io_cpuFetch_arready,
                               &dut->io_cpuFetch_rvalid, &dut->io_cpuFetch_rready, &dut->io_cpuFetch_rdata, &dut->io_cpuFetch_rresp, &dut->io_cpuFetch_rlast };
  if (m.id == 1) return RdSig{ &dut->io_cpuLsu_arvalid, &dut->io_cpuLsu_araddr, &dut->io_cpuLsu_arlen, &dut->io_cpuLsu_arready,
                               &dut->io_cpuLsu_rvalid, &dut->io_cpuLsu_rready, &dut->io_cpuLsu_rdata, &dut->io_cpuLsu_rresp, &dut->io_cpuLsu_rlast };
  return RdSig{ &dut->io_npuMem_arvalid, &dut->io_npuMem_araddr, &dut->io_npuMem_arlen, &dut->io_npuMem_arready,
                &dut->io_npuMem_rvalid, &dut->io_npuMem_rready, &dut->io_npuMem_rdata, &dut->io_npuMem_rresp, &dut->io_npuMem_rlast };
}
static WrSig wrSigOf(const Mst& m) {
  if (m.id == 1) return WrSig{ &dut->io_cpuLsu_awvalid, &dut->io_cpuLsu_awaddr, &dut->io_cpuLsu_awlen, &dut->io_cpuLsu_awready,
                               &dut->io_cpuLsu_wvalid, &dut->io_cpuLsu_wdata, &dut->io_cpuLsu_wstrb, &dut->io_cpuLsu_wlast, &dut->io_cpuLsu_wready,
                               &dut->io_cpuLsu_bvalid, &dut->io_cpuLsu_bready, &dut->io_cpuLsu_bresp };
  return WrSig{ &dut->io_npuMem_awvalid, &dut->io_npuMem_awaddr, &dut->io_npuMem_awlen, &dut->io_npuMem_awready,
                &dut->io_npuMem_wvalid, &dut->io_npuMem_wdata, &dut->io_npuMem_wstrb, &dut->io_npuMem_wlast, &dut->io_npuMem_wready,
                &dut->io_npuMem_bvalid, &dut->io_npuMem_bready, &dut->io_npuMem_bresp };
}

// -------------------- 采样快照 --------------------
struct SmpM { bool arv, arr, rv, rr, rresp, rlast; uint64_t rd;
              bool awv, awr, wv, wr, bv, br; uint64_t wd; uint8_t wstrb, wlast; };
struct SmpS { bool arv, arr; uint32_t araddr; uint8_t arlen; bool rv, rr, rlast; uint64_t rd;
              bool awv, awr; uint32_t awaddr; uint8_t awlen; bool wv, wr; uint64_t wd; uint8_t wstrb; bool bv, br; };
static SmpM s0, s1, s2;
static SmpS ss;

static long nMemAr = 0, nMemAw = 0, nMemW = 0, nMemB = 0, nMemRlast = 0;
static long nRwOverlap = 0, nRlastBad = 0, nBadRresp = 0;

// -------------------- 从方内存模型状态 --------------------
static int      rdState = 0;  static uint32_t rdAddr = 0;  static int rdBeatsLeft = 0;
// ★ L2b：读侧 4 深 AR 队列（与 DDR3Bridge 的 outR<DEPTH=4 同量级）。
//   空闲时 AR 直装当前流；流进行中到达的 AR 入队；末拍从队列无气泡续流。
#define AQ 4
static uint32_t aqAddr[AQ]; static int aqBeats[AQ];
static int aqWp = 0, aqRp = 0, aqCnt = 0;
static long outRdNow = 0, maxOutMem = 0;
static bool gManualNpu = false;          // J_MM5 手工驱动 npuMem（跳过 mstApply(m2) 的清零）
static int      wrActive = 0; static uint32_t wrAddr = 0;  static int wrBeatsLeft = 0; static int bPend = 0;

static uint64_t writePattern(int m, long i, int beat) { return 0xA5A5A5A500000000ULL ^ ((uint64_t)(m & 0xF) << 40) ^ ((uint64_t)(i & 0xFFFFF) << 16) ^ (uint64_t)(beat & 0xFFFF); }

static FILE* gTf = nullptr;
static void emitTx(const Mst& m);   // 前向声明（transcript 在文件末尾定义）

static void mstReset(Mst& m, int id, bool ro, uint32_t rdB, uint32_t wrB, long total) {
  m.id = id; m.readOnly = ro; m.rdBase = rdB; m.wrBase = wrB; m.total = total; m.done = 0;
  m.active = m.arAcc = m.awAcc = m.wAll = false; m.isWrite = false;
  m.addr = 0; m.len = 0; m.beat = 0; m.startCyc = 0;
  m.nRd = m.nWr = m.maxArLat = m.maxAwLat = 0; m.nByteBad = 0; m.beatData.clear();
}

// 开始下一笔定时（写在 postEdge 里，让 valid 从下一拍起抬）
static void startNext(Mst& m) {
  if (m.done >= m.total) return;
  m.isWrite = (!m.readOnly) && ((m.done & 1) != 0);
  m.len = (int)(m.done & 3);
  m.addr = (m.isWrite ? m.wrBase : m.rdBase) + (uint32_t)((m.done * 0x40) & 0x3FFF);
  m.beat = 0; m.arAcc = m.awAcc = m.wAll = false;
  m.startCyc = (long)cyc + 1;
  m.beatData.clear();
  m.active = true;
}

// 纯组合：按状态摆出 AXI 信号
static void mstApply(Mst& m) {
  if (gManualNpu && m.id == 2) return;     // J_MM5：npuMem 由手工状态机驱动
  RdSig r = rdSigOf(m); WrSig w = wrSigOf(m);
  *r.arvalid = 0; *r.rready = 1;
  if (m.id != 0) { *w.awvalid = 0; *w.wvalid = 0; *w.bready = 1; }
  if (!m.active) return;
  if (m.isWrite) {
    const int W = m.len + 1;
    if (!m.awAcc) { *w.awvalid = 1; *w.awaddr = m.addr; *w.awlen = (CData)m.len; }
    if (!m.wAll) { *w.wvalid = 1; *w.wdata = writePattern(m.id, m.done, m.beat); *w.wstrb = 0xFF; *w.wlast = (m.beat == W - 1) ? 1 : 0; }
    *w.bready = 1;
  } else {
    if (!m.arAcc) { *r.arvalid = 1; *r.araddr = m.addr; *r.arlen = (CData)m.len; }
  }
}

static void sampleMst(Mst& m, SmpM& s) {
  RdSig r = rdSigOf(m);
  s.arv = *r.arvalid; s.arr = *r.arready; s.rv = *r.rvalid; s.rr = *r.rready; s.rd = *r.rdata; s.rresp = *r.rresp; s.rlast = *r.rlast;
  if (m.id != 0) { WrSig w = wrSigOf(m); s.awv = *w.awvalid; s.awr = *w.awready; s.wv = *w.wvalid; s.wr = *w.wready;
                   s.wd = *w.wdata; s.wstrb = *w.wstrb; s.wlast = *w.wlast; s.bv = *w.bvalid; s.br = *w.bready; }
  else { s.awv = s.awr = s.wv = s.wr = s.bv = s.br = false; s.wd = 0; s.wstrb = 0; s.wlast = 0; }
}

static void postMst(Mst& m, const SmpM& s) {
  if (!m.active) { startNext(m); return; }
  if (!m.isWrite) {
    if (!m.arAcc && s.arv && s.arr) {
      m.arAcc = true; long lat = (long)cyc - m.startCyc + 1; if (lat > m.maxArLat) m.maxArLat = lat;
    }
    if (m.arAcc && s.rv && s.rr) {
      uint64_t d = s.rd; m.beatData.push_back(d);
      if (s.rresp != 0) nBadRresp++;
      for (int b = 0; b < 8; ++b) {
        uint8_t got = (uint8_t)(d >> (8 * b));
        if (got != expectByte(m.addr + (uint32_t)(m.beat * 8) + b)) m.nByteBad++;
      }
      if (s.rlast && m.beat != m.len) { if (nRlastBad < 8) printf("  [DBG] rlast 位置不符 mst=%d beat=%d len=%d cyc=%llu\n", m.id, m.beat, m.len, (unsigned long long)cyc); nRlastBad++; }
      m.beat++;
      if (m.beat == m.len + 1) { m.nRd++; m.done++; m.active = false; if (gTf) emitTx(m); startNext(m); }
    }
  } else {
    if (!m.awAcc && s.awv && s.awr) { m.awAcc = true; long lat = (long)cyc - m.startCyc + 1; if (lat > m.maxAwLat) m.maxAwLat = lat; }
    if (m.awAcc && !m.wAll && s.wv && s.wr) { m.beatData.push_back(s.wd); m.beat++; if (m.beat == m.len + 1) m.wAll = true; }
    if (m.wAll && s.bv && s.br) { m.nWr++; m.done++; m.active = false; if (gTf) emitTx(m); startNext(m); }
  }
}

static void memComb() {
  dut->io_mem_ar_arready = (aqCnt < AQ) ? 1 : 0;
  dut->io_mem_aw_awready = (wrActive == 0 && bPend == 0) ? 1 : 0;
  dut->io_mem_w_wready   = (wrActive && !bPend) ? 1 : 0;
  dut->io_mem_r_rvalid   = (rdState == 1) ? 1 : 0;
  dut->io_mem_r_rdata    = (rdState == 1) ? readMem64(rdAddr) : 0;
  dut->io_mem_r_rlast    = (rdState == 1 && rdBeatsLeft == 1) ? 1 : 0;
  dut->io_mem_r_rid = 0; dut->io_mem_r_rresp = 0;
  dut->io_mem_b_bvalid = bPend ? 1 : 0; dut->io_mem_b_bid = 0; dut->io_mem_b_bresp = 0;
}

static void applyAll() { mstApply(m0); mstApply(m1); mstApply(m2); memComb(); }
static void sampleAll() {
  sampleMst(m0, s0); sampleMst(m1, s1); sampleMst(m2, s2);
  ss.arv = dut->io_mem_ar_arvalid; ss.arr = dut->io_mem_ar_arready; ss.araddr = dut->io_mem_ar_araddr; ss.arlen = (uint8_t)dut->io_mem_ar_arlen;
  ss.rv = dut->io_mem_r_rvalid; ss.rr = dut->io_mem_r_rready; ss.rlast = dut->io_mem_r_rlast; ss.rd = dut->io_mem_r_rdata;
  ss.awv = dut->io_mem_aw_awvalid; ss.awr = dut->io_mem_aw_awready; ss.awaddr = dut->io_mem_aw_awaddr; ss.awlen = (uint8_t)dut->io_mem_aw_awlen;
  ss.wv = dut->io_mem_w_wvalid; ss.wr = dut->io_mem_w_wready; ss.wd = dut->io_mem_w_wdata; ss.wstrb = (uint8_t)dut->io_mem_w_wstrb;
  ss.bv = dut->io_mem_b_bvalid; ss.br = dut->io_mem_b_bready;
}
static void postAll() {
  postMst(m0, s0); postMst(m1, s1); postMst(m2, s2);
  // 读侧：先结算本拍 R，再收本拍 AR（同拍"末拍+新 AR"时新 AR 直装、不 double-consume）。
  if (rdState == 1 && ss.rv && ss.rr) {
    if (ss.rlast) nMemRlast++;
    rdAddr += 8;
    if (--rdBeatsLeft == 0) {
      rdState = 0; outRdNow--;
      if (aqCnt > 0) { rdAddr = aqAddr[aqRp]; rdBeatsLeft = aqBeats[aqRp]; aqRp = (aqRp + 1) % AQ; aqCnt--; rdState = 1; }
    }
  }
  if (ss.arv && ss.arr) {
    if (rdState == 0 && aqCnt == 0) { rdState = 1; rdAddr = ss.araddr; rdBeatsLeft = (int)ss.arlen + 1; }
    else { aqAddr[aqWp] = ss.araddr; aqBeats[aqWp] = (int)ss.arlen + 1; aqWp = (aqWp + 1) % AQ; aqCnt++; }
    nMemAr++; outRdNow++; if (outRdNow > maxOutMem) maxOutMem = outRdNow;
  }
  if (ss.awv && ss.awr) { wrActive = 1; wrAddr = ss.awaddr; wrBeatsLeft = (int)ss.awlen + 1; nMemAw++; }
  if (wrActive && !bPend && ss.wv && ss.wr) { writeMem64(wrAddr, ss.wd, ss.wstrb); wrAddr += 8; nMemW++; if (--wrBeatsLeft == 0) bPend = 1; }
  if (bPend && ss.bv && ss.br) { bPend = 0; wrActive = 0; nMemB++; }
  if (ss.arv && ss.awv) nRwOverlap++;
}

static void settle() { applyAll(); dut->eval(); sampleAll(); }
static void advance() { dut->clock = 1; dut->eval(); postAll(); dut->clock = 0; dut->eval(); cyc++; }
static void tick() { settle(); advance(); }

static void tieSlave() {
  dut->io_ethAxi_awready = 1; dut->io_ethAxi_wready = 1; dut->io_ethAxi_bvalid = 0; dut->io_ethAxi_bresp = 0;
  dut->io_ethAxi_arready = 1; dut->io_ethAxi_rvalid = 0; dut->io_ethAxi_rdata = 0; dut->io_ethAxi_rresp = 0;
  dut->io_npuAxi_awready = 1; dut->io_npuAxi_wready = 1; dut->io_npuAxi_bvalid = 0; dut->io_npuAxi_bresp = 0;
  dut->io_npuAxi_arready = 1; dut->io_npuAxi_rvalid = 0; dut->io_npuAxi_rdata = 0; dut->io_npuAxi_rresp = 0;
}
static void tieIdleInputs() {
  dut->io_cpuIo_awvalid = 0; dut->io_cpuIo_awaddr = 0; dut->io_cpuIo_awsize = 2; dut->io_cpuIo_awcache = 0; dut->io_cpuIo_awprot = 0;
  dut->io_cpuIo_wvalid = 0; dut->io_cpuIo_wdata = 0; dut->io_cpuIo_wstrb = 0xF; dut->io_cpuIo_wlast = 1;
  dut->io_cpuIo_bready = 1;
  dut->io_cpuIo_arvalid = 0; dut->io_cpuIo_araddr = 0; dut->io_cpuIo_arsize = 2; dut->io_cpuIo_arcache = 0; dut->io_cpuIo_arprot = 0;
  dut->io_cpuIo_rready = 1;
  dut->io_uart_rxd = 1; dut->io_sd_miso = 1; dut->io_gpio_in = 0;
  dut->io_ethIrq = 0; dut->io_npuIrq = 0; dut->io_loadMode = 0; dut->io_bootTimeout = 100000000;
  dut->io_cpuFetch_arsize = 3; dut->io_cpuFetch_arburst = 1; dut->io_cpuFetch_arcache = 0; dut->io_cpuFetch_arprot = 0;
  dut->io_cpuLsu_awsize = 3; dut->io_cpuLsu_awburst = 1; dut->io_cpuLsu_awcache = 0; dut->io_cpuLsu_awprot = 0;
  dut->io_cpuLsu_arsize = 3; dut->io_cpuLsu_arburst = 1; dut->io_cpuLsu_arcache = 0; dut->io_cpuLsu_arprot = 0;
  dut->io_npuMem_awid = 0; dut->io_npuMem_awsize = 3; dut->io_npuMem_awburst = 1; dut->io_npuMem_awcache = 0; dut->io_npuMem_awprot = 0;
  dut->io_npuMem_arid = 0; dut->io_npuMem_arsize = 3; dut->io_npuMem_arburst = 1; dut->io_npuMem_arcache = 0; dut->io_npuMem_arprot = 0;
}

// -------------------- transcript（单主人回归）--------------------
static void emitTx(const Mst& m) {
  if (!gTf) return;
  fprintf(gTf, "TX %d %c addr=%08x len=%d beats=%d data=", m.id, m.isWrite ? 'W' : 'R', m.addr, m.len, (int)m.beatData.size());
  for (size_t b = 0; b < m.beatData.size(); ++b) fprintf(gTf, "%016llx", (unsigned long long)m.beatData[b]);
  fprintf(gTf, "\n");
}

// 单主人作业（记 transcript 用）：只让 `only` 主方活动
static void singleJob(int only, std::vector<std::string>& out) {
  mstReset(m0, 0, true,  0x00000000u, 0x00040000u, only == 0 ? 24 : 0);
  mstReset(m1, 1, false, 0x00004000u, 0x00020000u, only == 1 ? 24 : 0);
  mstReset(m2, 2, false, 0x00008000u, 0x00030000u, only == 2 ? 24 : 0);
  Mst* m = only == 0 ? &m0 : (only == 1 ? &m1 : &m2);
  char buf[4096];
  FILE* tf = tmpfile();
  FILE* save = gTf; gTf = tf;
  long guard = 0;
  while (m->done < m->total) {
    tick();
    if (++guard > 200000) { fail("单主人作业没跑完"); break; }
  }
  gTf = save;
  rewind(tf);
  while (fgets(buf, sizeof(buf), tf)) { std::string s(buf); while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back(); if (!s.empty()) out.push_back(s); }
  fclose(tf);
  if (m->nByteBad) fail("单主人作业读回字节不对");
}

// 配额作业（J_MM4）：cpuLsu（类 0）与 npuMem（类 1）**持续**争用固定拍数，比"授予次数"比
static void quotaJob(long cycles) {
  mstReset(m0, 0, true,  0x00000000u, 0x00040000u, 0);
  mstReset(m1, 1, false, 0x00004000u, 0x00020000u, 1000000);
  mstReset(m2, 2, false, 0x00008000u, 0x00030000u, 1000000);
  long end = (long)cyc + cycles;
  while ((long)cyc < end) tick();
  long g1 = m1.nRd + m1.nWr, g2 = m2.nRd + m2.nWr;
  double r = g2 ? (double)g1 / (double)g2 : 0.0;
  printf("  [QUOTA] 类间授予比 CPU(cpuLsu):NPU = %ld:%ld = %.3f（权重 2:1 ⇒ 期望 ~2.0）\n", g1, g2, r);
  if (m1.nByteBad || m2.nByteBad) fail("J_MM4 配额作业读回字节不对");
  if (!(r > 1.75 && r < 2.3)) fail("J_MM4 配额比不在 2:1 窗口");
}

// J_MM5（L2b）：NPU 背靠背多 outstanding 读 —— 合并点必须在授权期内保持 owner 到**末笔 rlast**。
//   激励：三笔读（4/2/3 拍）连续发 AR（上一笔 R 未回完就发下一笔），R 按序逐字节校验。
//   旧网表（首个 rlast 即释放 owner）会在 tx0 末拍后把后续 R 挡在门外 ⇒ 超时红。
static void multiOutJob() {
  const int NTX = 3;
  const uint32_t a[NTX] = { 0x00010000u, 0x00012000u, 0x00014000u };
  const int nb[NTX] = { 4, 2, 3 };
  mstReset(m0, 0, true, 0, 0, 0);
  mstReset(m1, 1, false, 0, 0, 0);
  mstReset(m2, 2, false, 0, 0, 0);
  gManualNpu = true;
  outRdNow = 0; maxOutMem = 0;
  int issue = 0, cur = 0, beat = 0;
  long arSeen = 0, arBeforeFirstR = 0, bad = 0, guard = 0;
  bool seenFirstR = false;
  dut->io_npuMem_arvalid = 1; dut->io_npuMem_araddr = a[0]; dut->io_npuMem_arlen = (CData)(nb[0] - 1);
  dut->io_npuMem_rready  = 1;
  while (cur < NTX) {
    tick();
    if (ss.arv && ss.arr) {
      arSeen++;
      if (issue < NTX && !seenFirstR) arBeforeFirstR++;
      issue++;
      if (issue < NTX) { dut->io_npuMem_arvalid = 1; dut->io_npuMem_araddr = a[issue]; dut->io_npuMem_arlen = (CData)(nb[issue] - 1); }
      else dut->io_npuMem_arvalid = 0;
    }
    if (ss.rv && ss.rr) {
      seenFirstR = true;
      for (int b = 0; b < 8; ++b) {
        uint8_t got = (uint8_t)(ss.rd >> (8 * b));
        if (got != expectByte(a[cur] + (uint32_t)(beat * 8) + b)) bad++;
      }
      beat++;
      if (ss.rlast) {
        if (beat != nb[cur]) bad += 1000;      // 末拍位置不对
        cur++; beat = 0;
      }
    }
    if (++guard > 5000) { fail("J_MM5 多 outstanding 读超时（owner 未保持到末笔 rlast / 数据被丢）"); break; }
  }
  dut->io_npuMem_arvalid = 0; dut->io_npuMem_rready = 0; gManualNpu = false;
  printf("  [JOB] J_MM5 NPU 背靠背读：AR=%ld 笔（首拍 R 前 %ld 笔）/ io_mem 在飞峰值=%ld / 字节错=%ld\n",
         arSeen, arBeforeFirstR, maxOutMem, bad);
  if (bad) fail("J_MM5 读回字节或末拍位置不对");
  if (arBeforeFirstR < 2) fail("J_MM5 未形成背靠背 AR（首拍 R 前 <2 笔）");
  if (maxOutMem < 2)      fail("J_MM5 io_mem 在飞读峰值 <2（多 outstanding 没真发生）");
}

// 跑一个作业（只让 total>0 的主方活动）；返回三主最坏授权延迟
static long runJob(long t0, long t1, long t2) {
  mstReset(m0, 0, true,  0x00000000u, 0x00040000u, t0);
  mstReset(m1, 1, false, 0x00004000u, 0x00020000u, t1);
  mstReset(m2, 2, false, 0x00008000u, 0x00030000u, t2);
  long guard = 0;
  while (!(m0.done >= m0.total && m1.done >= m1.total && m2.done >= m2.total)) {
    tick();
    if (++guard > 400000) { fail("作业没跑完（guard 超时）"); break; }
  }
  Mst* ms[3] = { &m0, &m1, &m2 };
  long maxLat = 0;
  for (int i = 0; i < 3; ++i) {
    if (ms[i]->total == 0) continue;
    if (ms[i]->done != ms[i]->total) { printf("  [FAIL] 主 %d 没跑完（%ld/%ld）\n", i, ms[i]->done, ms[i]->total); nFail++; }
    if (ms[i]->nByteBad) { printf("  [FAIL] 主 %d 读回字节不对（%ld 处）\n", i, ms[i]->nByteBad); nFail++; }
    long l = ms[i]->maxArLat > ms[i]->maxAwLat ? ms[i]->maxArLat : ms[i]->maxAwLat;
    if (l > maxLat) maxLat = l;
    printf("  [LAT] 主 %d：maxAr=%ld maxAw=%ld（读 %ld / 写 %ld）\n", i, ms[i]->maxArLat, ms[i]->maxAwLat, ms[i]->nRd, ms[i]->nWr);
  }
  return maxLat;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  const char* goldenPath = nullptr; const char* comparePath = nullptr;
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--golden") && i + 1 < argc) goldenPath = argv[++i];
    else if (!strcmp(argv[i], "--compare") && i + 1 < argc) comparePath = argv[++i];
  }
  dut = new VYeshenSocGlue;
  for (uint32_t a = 0; a < MEM_BYTES; ++a) mem[a] = expectByte(a);
  tieIdleInputs(); tieSlave();
  mstReset(m0, 0, true, 0x00000000u, 0x00040000u, 0);
  mstReset(m1, 1, false, 0x00004000u, 0x00020000u, 0);
  mstReset(m2, 2, false, 0x00008000u, 0x00030000u, 0);
  applyAll();
  dut->clock = 0; dut->reset = 1;
  for (int k = 0; k < 4; ++k) { dut->clock = 1; dut->eval(); dut->clock = 0; dut->eval(); cyc++; }
  dut->reset = 0;
  printf("=== YeshenSocGlue 内存合并点判决（真仲裁，BOUND_MM=%d 拍）===\n", BOUND_MM);

  // ---- J_MM2：单主人 transcript（记档或比对）----
  if (goldenPath || comparePath) {
    std::vector<std::string> got;
    for (int k = 0; k < 3; ++k) singleJob(k, got);
    if (goldenPath) {
      FILE* f = fopen(goldenPath, "w");
      if (!f) { printf("  [FAIL] 打不开 %s\n", goldenPath); return 2; }
      for (auto& s : got) fprintf(f, "%s\n", s.c_str());
      fclose(f);
      printf("  [GOLDEN] 单主人 transcript %zu 行 已记到 %s\n", got.size(), goldenPath);
    } else {
      std::vector<std::string> want; char line[4096];
      FILE* f = fopen(comparePath, "r");
      if (!f) { printf("  [FAIL] 打不开 %s\n", comparePath); return 2; }
      while (fgets(line, sizeof(line), f)) { std::string s(line); while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back(); if (!s.empty()) want.push_back(s); }
      fclose(f);
      size_t n = want.size() < got.size() ? want.size() : got.size();
      long diff = 0;
      for (size_t i = 0; i < n; ++i) if (want[i] != got[i]) { if (diff < 5) printf("  [DIFF] 行 %zu\n    golden: %s\n    now   : %s\n", i, want[i].c_str(), got[i].c_str()); diff++; }
      diff += (long)(want.size() > got.size() ? want.size() - got.size() : got.size() - want.size());
      printf("  [REGRESS] 单主人 transcript：golden %zu 行 / now %zu 行，差异 %ld 行\n", want.size(), got.size(), diff);
      if (diff != 0) fail("J_MM2 单主人 transcript 与 golden **不逐字节相同**（仲裁器改了单主人行为）");
    }
  }

  // ---- J_MM1：并发多主（两套配置）----
  printf("  --- C1：cpuLsu + npuMem 同时各跑 %d 笔 ---\n", N_TX);
  long latC1 = runJob(0, N_TX, N_TX);
  printf("  [LAT] C1 最坏授权延迟 = %ld 拍（上界 %d）\n", latC1, BOUND_MM);
  if (latC1 > BOUND_MM) fail("J_MM1(C1) 有界等待破了");
  printf("  --- C2：cpuFetch + npuMem 同时各跑 %d 笔 ---\n", N_TX);
  long latC2 = runJob(N_TX, 0, N_TX);
  printf("  [LAT] C2 最坏授权延迟 = %ld 拍（上界 %d）\n", latC2, BOUND_MM);
  if (latC2 > BOUND_MM) fail("J_MM1(C2) 有界等待破了");

  // ---- J_MM3：纪律（在**所有事务都跑完**的状态下判；配额作业会截在事务中间，故放在它前面）----
  printf("  [DISC] io_mem：AR=%ld AW=%ld W=%ld B=%ld rlast=%ld\n", nMemAr, nMemAw, nMemW, nMemB, nMemRlast);
  if (nRwOverlap != 0) fail("J_MM3 AR 与 AW 同拍（读写互斥被破）");
  if (nRlastBad != 0)  fail("J_MM3 rlast 位置/次数不对");
  if (nBadRresp != 0)  fail("J_MM3 读响应不是 OKAY");
  if (nMemB != nMemAw) fail("J_MM3 写 B 次数 != AW 次数");

  // ---- J_MM5（L2b）：NPU 背靠背多 outstanding 读（owner 保持到末笔 rlast）----
  printf("  --- J_MM5：NPU 背靠背 3 笔读（多 outstanding）---\n");
  multiOutJob();

  // ---- J_MM4：类间配额（cpuLsu vs npuMem 持续争用；固定拍数后截断）----
  printf("  --- J_MM4：cpuLsu + npuMem 持续争用 30000 拍 ---\n");
  quotaJob(30000);

  printf("\n%s\n", nFail ? "=== TEST FAILED ===" : "=== TEST PASSED ===");
  delete dut;
  return nFail ? 1 : 0;
}
