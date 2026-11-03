// ===================== DDR3Bridge 单元装置（V1 闸门）=====================
// 为什么需要它：`DDR3Bridge` 是板级关键路径上的组件（CPU 侧 AXI4 从口 ↔ 紫光同创 DDR3 IP 的
// 256bit 简化 AXI 主口），而本工程里它**没有任何仿真覆盖**——`tb_naxmini.cpp` 的 DUT 是
// `NaxMiniGlue`，桥不在数据通路上。V1 把它的 AXI 从口从 32bit 改成 64bit，
// 所以先要有**独立可验证**的单元判据，才允许动它（spec §4 V1 行）。
//
// 装置：`--top-module DDR3Bridge`，两侧都换模型
//   * axi 侧（本模块时钟域）= 按拍推进的 AXI4 主方：发 AW/W/AR，收 B/R；
//   * DDR 侧（`io_ddr_clk` 域）= 行为级从方：256bit 数据 + 32bit 逐字节 wstrb、
//     **每笔 AW 只吃 1 个 256bit beat**、**每笔 AR 只回 1 拍**、R 延迟 `R_LATENCY` 拍。
//
// **本装置与 AXI 从口位宽无关**：同一份源码、同一批判据，用 `-DAXI_W=32|64` 切数据位宽。
//   32bit（S1 阳性基线，打的是 64bit 化**之前**的设计）：每 32B 组 = 8 拍、wstrb 4bit；
//   64bit（S2 阳性）：每 32B 组 = 4 拍、wstrb 8bit。
//   ⇒ "同一个测试在两种位宽下都通过"本身就是"宽度映射改对了"的判据。
//
// 判据（每一条都在两种位宽下语义相同）：
//   ① 整组写→读回逐字节对账（32B 一组）：W32 组 + R32（写完整组后*同一区域*读回，逐字节比）；
//   ② 跨多组的一笔长突发（64B 行 = 两组）：W64/R64，DDR 侧必须恰 2 笔事务且地址递进 32B；
//   ③ 短/部分 `wstrb` 的写：W1p（单拍 + 隔字节掩码）⇒ 只有被选中的字节落地，其余保持哨兵；
//   ④ 读突发的 `rlast` 位置：每个读用例都断言 `rlast` 只落在最后一拍；
//   ⑤ B 响应恰一次（只在末组之后）；
//   ⑥ **B 通道 id 回带**（Task 19 新加）：`B.bid` 必须**逐用例**等于该笔 AW 的 `awid`
//      —— 写用例的 `awid` 一律非 0（旧 7 条 = 5，新用例 = 0xA，**两个不同的非 0 id 同场对照**，
//      这样"bid 恒 0"和"bid 被钉死成某个常数"两类缺陷都会当场翻红）。
//      负对照 = `sim/ddr3bridge/negctl_ddr3bridge.sh` 的 **NC5**（把 `axi.b.bid := wrAwId`
//      精确替换成 `0.U`，即摘掉回带）⇒ 本装置必须 FAILED。
//   另加：残组（`GRP_BEATS+1` 拍）写/读 —— 末组未用 lane 的 `wstrb` 必须清零（同 32B 内其余字节是哨兵）。
// 数据模式：主方第 i 拍第 j 字节 = `(base + i*AXI_BYTES + j) & 0xFF`（连续字节序列）⇒
//   逐字节对账能区分 lane 错位 / 组重复 / 组漏写。
//
// **DDR 侧协议不变**的断言（V1 只改 AXI 从口宽度，这些一律不许动）：
//   * 每笔 DDR 事务**只发 1 个 256bit beat**：`io_ddrAwLen`/`io_ddrArLen` 恒 0（呈现即校验）；
//   * 每笔地址 **32B 对齐**（32bit 字地址低 3 位为 0）；
//   * 每笔地址递进 = **8 个 32bit 字 = 32B**（与 AXI 从口位宽无关：DDR 侧地址单位是 32bit 字）；
//   * 读回单拍：`rvalid` 与 `rlast` 同拍。
//
// 负对照：`sim/ddr3bridge/negctl_ddr3bridge.sh`（补丁一律走 `patch_exact.py`，替换不到就报错）。
#include "VDDR3Bridge.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <map>
#include <vector>
#include <deque>

#ifndef AXI_W
#error "必须给 -DAXI_W=32 或 -DAXI_W=64（AXI 从口数据位宽）"
#endif
#if (AXI_W != 32) && (AXI_W != 64)
#error "AXI_W 只支持 32 / 64"
#endif

#define AXI_BYTES   (AXI_W / 8)                 /* 每 AXI 拍字节数：4 / 8 */
#define GRP_BYTES   32                          /* DDR 侧一笔 256bit = 32B（协议不变）*/
#define GRP_BEATS   (GRP_BYTES / AXI_BYTES)      /* 每 32B 组的 AXI 拍数：8 / 4 */
#define DDR_WORD_STEP 8                          /* 每笔 DDR 事务的地址递进：8 个 32bit 字 = 32B */

#if AXI_W == 64
typedef uint64_t bus_t;
#else
typedef uint32_t bus_t;
#endif

static VDDR3Bridge* dut;
static uint64_t cyc    = 0;
static uint64_t MAX_CYC = 200000;

// ===================== DDR3 IP 侧模型（ddr 域）=====================
// 内存按**字节**建模（逐字节对账是本装置的判据核心）；未写过的字节 = 哨兵。
static std::map<uint32_t, uint8_t> ddrMem;
static const uint8_t DDR_SENTINEL = 0xDE;

static uint8_t memRd(uint32_t byteAddr) {
    std::map<uint32_t, uint8_t>::iterator it = ddrMem.find(byteAddr);
    return (it == ddrMem.end()) ? DDR_SENTINEL : it->second;
}

static int R_LATENCY = 3;                        // DDR 读延迟（拍，ddr 域）；可用 R_LAT 覆盖

// ===================== DDR3 IP 侧模型（ddr 域）=====================
// ★ Y1-DMA Phase-0 升级：从"一次一笔事务"的状态机换成**带命令队列的 IP 行为级模型**。
//   为什么必须换：改前的模型 `ipState` 一次只认一笔事务（AW 收下后必须等 W 拍吃完才回 idle），
//   于是**桥就算真能多未完成也观察不到**（IP 侧自己把它们串行化了）⇒ 判据会变成"测模型"而不是
//   "测桥"。真紫光 DDR3 IP 的 AW/AR 是**独立的通道 + 命令队列**，所以这里照它的样子建模：
//     · AW：只要命令队列没满（`AWDEPTH`）就收 ⇒ 允许多笔写事务**同时挂账**；
//     · AR：同理（`ARDEPTH`），数据按 AR 顺序回来、各带 `R_LATENCY` 延迟（流水）；
//     · W：只要 AW 队列非空就吃 1 拍（DDR 侧 W 没有 wvalid；桥保证"有 AW 挂账 ⇒ W 数据已到"）；
//     · R：每拍回 1 个字（没有 rready ⇒ 呈现 1 拍即被取走；桥靠信用保证一定收得下）。
//   ⚠️ 既有 8 条用例都是一笔一笔串行的 ⇒ 新旧模型在它们上面行为等价（判据一条没松）。
//   ⚠️ W 的采样必须用**本拍开始前**的 AW 队列长度：桥的 `ipWrPend` 也是"上一拍已发、本拍未取"，
//      用本拍推送后的长度会让两边差一拍 ⇒ 桥还没拿到数据、模型却已经把 W 拍吃掉（数据错位）。
static std::deque<uint32_t> awQ;                 // 已收下 AW、等 W 拍（FIFO ⇒ W 顺序 = AW 顺序）
struct RdEnt { int lat; uint32_t word; };
static std::deque<RdEnt>  rdQ;                   // 已收下 AR、等读延迟
static std::deque<uint32_t> rOutQ;               // 数据已出、等回给桥
static const int AWDEPTH = 4;
static const int ARDEPTH = 4;
static int      ipState = 0;                     // 仅给 DDR_DBG 打印用（本拍 IP 在做什么）
static uint32_t ipWord  = 0;

static int nAwFire = 0, nWBeat = 0, nArFire = 0, nRBeat = 0;
static std::vector<uint32_t> awTrace, arTrace;   // DDR 侧地址纸带
static int nStrbPartial = 0;                     // ddrWStrb 非全 1 的 beat 数（部分掩码证据）
static bool ipFail = false;
static char ipMsg[256];
static uint32_t ipRWord[8];                      // 回读的 8 个 32bit 字

static void ipFailf(const char* what, uint32_t a, uint32_t b) {
    if (ipFail) return;
    ipFail = true;
    snprintf(ipMsg, sizeof ipMsg, "%s（got=0x%X exp=0x%X）", what, a, b);
}

// 在 ddr 上升沿之后调用：采样 DUT 的 ddr 域输出、推进模型、驱动下一拍的 ddr 域输入
static void ddrIpModel() {
  int awR = 0, wR = 0, arR = 0, rV = 0;
  ipState = 0;

  // ---- DDR 侧协议不变：呈现即校验（单 beat / 32B 对齐）----
  if (dut->io_ddrAwValid) {
    if (dut->io_ddrAwLen != 0)   ipFailf("DDR 写事务不是单 beat（awlen != 0）", dut->io_ddrAwLen, 0);
    if ((dut->io_ddrAwAddr & 7u) != 0) ipFailf("DDR 写地址不是 32B 对齐", dut->io_ddrAwAddr, 0);
  }
  if (dut->io_ddrArValid) {
    if (dut->io_ddrArLen != 0)   ipFailf("DDR 读事务不是单 beat（arlen != 0）", dut->io_ddrArLen, 0);
    if ((dut->io_ddrArAddr & 7u) != 0) ipFailf("DDR 读地址不是 32B 对齐", dut->io_ddrArAddr, 0);
  }

  // ---- AW：命令队列有位置就收（多未完成的前提）----
  const size_t awPre = awQ.size();
  awR = ((int)awPre < AWDEPTH) ? 1 : 0;
  if (dut->io_ddrAwValid && awR) {
    ipWord = dut->io_ddrAwAddr;
    awQ.push_back(ipWord);
    awTrace.push_back(ipWord);
    nAwFire++;
  }

  // ---- W：AW 队列非空就吃 **1 拍**（用本拍开始前的长度，与桥的 ipWrPend 严格对齐）----
  wR = (awPre > 0) ? 1 : 0;
  if (wR) {
    ipState = 1;
    uint32_t word = awQ.front(); awQ.pop_front();
    uint32_t strb = dut->io_ddrWStrb;
    if (strb != 0xFFFFFFFFu) nStrbPartial++;
    if (getenv("DDR_DBG"))
      printf("    [DDR-W] word=0x%X byte=0x%X strb=%08X\n", word, word * 4u, strb);
    // `wstrb` 是**逐字节**掩码（每 32bit lane 占 4 bit）：0xF 的 lane 才落地。
    for (int i = 0; i < 8; ++i) {         // i = 32bit lane
      uint32_t bs = (strb >> (4 * i)) & 0xFu;
      if (bs == 0) continue;
      uint32_t wd = dut->io_ddrWData[i];
      for (int b = 0; b < 4; ++b)
        if (((bs >> b) & 1u) != 0)
          ddrMem[word * 4u + (uint32_t)(4 * i + b)] = (uint8_t)((wd >> (8 * b)) & 0xFFu);
    }
    nWBeat++;
  }

  // ---- AR：命令队列有位置就收 ----
  arR = ((int)rdQ.size() < ARDEPTH) ? 1 : 0;
  if (dut->io_ddrArValid && arR) {
    RdEnt e; e.lat = R_LATENCY; e.word = dut->io_ddrArAddr;
    rdQ.push_back(e);
    arTrace.push_back(e.word);
    nArFire++;
  }

  // ---- 读延迟：**只推进队首**（顺序即协议）----
  if (!rdQ.empty()) {
    ipState = 2;
    if (--rdQ.front().lat <= 0) { rOutQ.push_back(rdQ.front().word); rdQ.pop_front(); }
  }

  // ---- R：每拍回 **1 个字**（len 恒 0 ⇒ rlast 与 rvalid 同拍）----
  for (int i = 0; i < 8; ++i) ipRWord[i] = 0;
  if (!rOutQ.empty()) {
    ipState = 3;
    uint32_t word = rOutQ.front(); rOutQ.pop_front();
    rV = 1;
    for (int i = 0; i < 8; ++i) {
      uint32_t v = 0;
      for (int b = 0; b < 4; ++b)
        v |= ((uint32_t)memRd(word * 4u + (uint32_t)(4 * i + b))) << (8 * b);
      ipRWord[i] = v;
    }
    nRBeat++;
  }

  dut->io_ddrAwReady = (uint8_t)awR;
  dut->io_ddrWReady  = (uint8_t)wR;
  dut->io_ddrArReady = (uint8_t)arR;
  dut->io_ddrRValid  = (uint8_t)rV;
  dut->io_ddrRLast   = (uint8_t)rV;             // 单 beat ⇒ rlast 与 rvalid 同拍
  for (int i = 0; i < 8; ++i) dut->io_ddrRData[i] = ipRWord[i];
}

// ===================== AXI 主方模型（axi 域）=====================
enum Mode { W_ONLY, W_THEN_R, R_ONLY };
enum Strb { STRB_FULL, STRB_ALT };                // 全掩码 / 隔字节（beat 内偶数 byte index 有效）

struct TestCase {
    const char* name;
    Mode        mode;
    uint32_t    addr;      // 字节地址（32B 对齐）
    int         beats;     // AXI 拍数
    uint32_t    base;      // 数据模式起点：突发内第 k 字节 = (base + k) & 0xFF
    int         expWrDdr;  // 期望的 DDR 写事务数
    int         expRdDdr;  // 期望的 DDR 读事务数
    Strb        strb;
    uint32_t    awid;      // ★ Task 19：本用例的 AXI write id（**必须非 0**：判 ⑥ 的输入）
};

// 拍数一律按"每 32B 组 = GRP_BEATS 拍"表达 ⇒ 两种位宽下语义完全相同：
//   1 拍       = 短突发（32bit: 4B / 64bit: 8B）
//   2*GRP_BEATS= 64B    = Dcache 行回写/行填充（32bit: 16 拍 / 64bit: 8 拍）
//   GRP_BEATS+1= 残组（32bit: 9 拍 36B / 64bit: 5 拍 40B，末组只剩 1 拍）
// 末列 = 该用例的 `awid`（判 ⑥ 的输入）：旧 7 条沿用 5（与历史日志一致），
//   **新增的 BID 用例用 0xA** —— 同一场跑里出现两个不同的非 0 id，
//   「bid 恒 0」和「bid 被钉死成常数」两类缺陷都逃不过。
static const TestCase kTests[] = {
    {"W32  整组写 (32B=GRP_BEATS 拍, 全掩码, 1 笔 DDR)",     W_ONLY,   0x00001000u, GRP_BEATS,     0xA0u, 1, 0, STRB_FULL, 5},
    {"R32  整组写→读回逐字节对账 (同区域, 1 笔 DDR)",         W_THEN_R, 0x00001040u, GRP_BEATS,     0xB0u, 1, 1, STRB_FULL, 5},
    {"W64  跨两组写 (64B 行回写 = 2 笔 DDR)",                W_ONLY,   0x00002000u, 2*GRP_BEATS,   0xC0u, 2, 0, STRB_FULL, 5},
    {"R64  跨两组写→读回 (64B 行填充, 2 笔 DDR)",             W_THEN_R, 0x00002080u, 2*GRP_BEATS,   0xD0u, 2, 2, STRB_FULL, 5},
    {"W1p  短突发 + 部分 wstrb (1 拍, 隔字节掩码)",           W_ONLY,   0x00003000u, 1,             0xE0u, 1, 0, STRB_ALT,  5},
    {"W9r  残组写 (GRP_BEATS+1 拍, 末组只有 1 拍有效)",       W_ONLY,   0x00004000u, GRP_BEATS+1,   0x10u, 2, 0, STRB_FULL, 5},
    {"R9r  残组读回 (预置内存, 2 笔 DDR, rlast 在末拍)",      R_ONLY,   0x00004080u, GRP_BEATS+1,   0x70u, 0, 2, STRB_FULL, 5},
    // ★ Task 19 新增：B 通道 id 回带正例（awid = 0xA ≠ 0，也 ≠ 前面 7 条的 5）
    {"BID  写 id 回带正例 (awid=0xA ⇒ B.bid 必须 == 0xA)",    W_ONLY,   0x00005000u, GRP_BEATS,     0x50u, 1, 0, STRB_FULL, 0xAu},
};
static const int kNumTests = (int)(sizeof(kTests) / sizeof(kTests[0]));

static int  mstTest = 0, mstState = 0, mstPhase = 0, mstBeat = 0;
// 每个用例的记账起点：在**用例开始时**整体取一次（不是发命令时取），否则"本用例没有发某一路命令"
// 时会把上一个用例的计数算进本用例（S1 第一次跑就踩到：W64 报"读事务数=1"）。
static int  awMark = 0, arMark = 0, strbMark = 0, nB = 0;
static uint32_t lastBid = 0xFFFFFFFFu;            // ★ Task 19：本用例线上实际看到的 B.bid
static std::vector<bus_t> rGot;                  // 本用例收到的 R 数据拍
static int  lastRIdx = -1;                       // rlast 所在 beat 序号
static int  preloaded = -1;

static int  nFail = 0;
static void fail(const char* what) { printf("  [FAIL] %s\n", what); nFail++; }

static void takeMarks() { awMark = nAwFire; arMark = nArFire; strbMark = nStrbPartial; nB = 0; lastBid = 0xFFFFFFFFu; }

// 复位期间**不能**让主方模型跑：复位时 `wrState` 被扣在 0 ⇒ `awready` 恒 1，
// 主方会以为 AW 已握手、转去等 `wready`（复位期间恒 0），复位一放就永久卡死。
static bool mstStarted = false;

// 突发内第 off 个字节的期望值（连续字节序列 ⇒ lane 错位/组重复都逃不过逐字节比）
static uint8_t patByte(uint32_t base, int off) { return (uint8_t)((base + (uint32_t)off) & 0xFFu); }

static bus_t beatValue(uint32_t base, int beat) {
    bus_t v = 0;
    for (int j = 0; j < AXI_BYTES; ++j)
        v |= ((bus_t)patByte(base, beat * AXI_BYTES + j)) << (8 * j);
    return v;
}
static uint32_t beatStrb(Strb m, int beat) {
    if (m == STRB_FULL) return (1u << AXI_BYTES) - 1u;
    uint32_t s = 0;
    for (int j = 0; j < AXI_BYTES; ++j)
        if (((beat + j) & 1) == 0) s |= 1u << j;
    return s;
}
static bool byteStrobed(Strb m, int off) {
    if (m == STRB_FULL) return true;
    return ((((off / AXI_BYTES) + (off % AXI_BYTES)) & 1) == 0);
}

// 地址纸带：逐笔 = 首址 + 8k（32bit 字）⇒ 每笔 32B（两种 AXI 位宽下相同）
static void checkTrace(const char* what, const std::vector<uint32_t>& tr, int mark, int groups, uint32_t addr) {
    uint32_t w0 = addr >> 2;
    for (int k = 0; k < groups; ++k) {
        uint32_t want = w0 + (uint32_t)(DDR_WORD_STEP * k);
        uint32_t got  = tr[(size_t)(mark + k)];
        if (got != want) {
            printf("  %s地址[%d] = 0x%X（期望 0x%X = 首址 + %d 字 = +%dB）\n",
                   what, k, got, want, DDR_WORD_STEP * k, DDR_WORD_STEP * k * 4);
            fail("DDR 地址没有按 8 字（32B）递进");
            return;
        }
    }
}

// ---- 判定 ----
static void judgeTest() {
    const TestCase& t = kTests[mstTest];
    printf("=== %s ===\n", t.name);
    int burstBytes = t.beats * AXI_BYTES;
    int groups     = (burstBytes + GRP_BYTES - 1) / GRP_BYTES;   // 期望的 DDR 事务数

    // ① DDR 侧事务数（= 每 32B 组一笔；"每 32B 组几拍"写错会在这里翻红）
    int wrGot = nAwFire - awMark, rdGot = nArFire - arMark;
    if (wrGot != t.expWrDdr) {
        printf("  DDR 写事务数 = %d（期望 %d，本笔突发 %d 字节 / 每笔 32B）\n", wrGot, t.expWrDdr, burstBytes);
        fail("DDR 写事务数不符 ⇒ 多拍突发没有按 32B 分组");
    }
    if (rdGot != t.expRdDdr) {
        printf("  DDR 读事务数 = %d（期望 %d）\n", rdGot, t.expRdDdr);
        fail("DDR 读事务数不符 ⇒ 多拍突发没有按 32B 分组");
    }
    if (t.expWrDdr + t.expRdDdr != groups * (t.mode == W_THEN_R ? 2 : 1))
        fail("装置自检：期望事务数与 32B 分组算式不一致");

    // ② DDR 侧地址纸带（写/读各查各自的事务；**只在事务数对上了才查**，否则纸带下标越界，
    //    会打出一行误导的假地址——真红的是上面那条"事务数不符"）
    if (t.expWrDdr && wrGot == t.expWrDdr) checkTrace("DDR 写", awTrace, awMark, t.expWrDdr, t.addr);
    if (t.expRdDdr && rdGot == t.expRdDdr) checkTrace("DDR 读", arTrace, arMark, t.expRdDdr, t.addr);

    // ③ 写侧：按 32B 组对齐的整段逐字节对账（含残组 padding 必须保持哨兵）
    if (t.mode != R_ONLY) {
        int bad = 0, padBad = 0;
        for (int off = 0; off < groups * GRP_BYTES; ++off) {
            uint8_t want = (off < burstBytes && byteStrobed(t.strb, off)) ? patByte(t.base, off) : DDR_SENTINEL;
            uint8_t got  = memRd(t.addr + (uint32_t)off);
            if (got != want) {
                if (off >= burstBytes) padBad++;
                else bad++;
                if (bad + padBad <= 4)
                    printf("  mem[byte +%d] = 0x%02X（期望 0x%02X）%s\n", off, got, want,
                           off >= burstBytes ? "  ← 残组 padding 不该落地" : "");
            }
        }
        if (bad)    { printf("  写数据逐字节错 %d/%d\n", bad, burstBytes); fail("写数据没有逐字节落到正确的字节地址"); }
        if (padBad) { printf("  残组 padding 被写脏 %d 字节\n", padBad); fail("残组未用 lane 的 wstrb 未清零"); }
    }

    // ④ 读侧：逐字节对账 + rlast 位置
    if (t.mode != W_ONLY) {
        if ((int)rGot.size() != t.beats) {
            printf("  R beat 数 = %zu（期望 %d）\n", rGot.size(), t.beats);
            fail("R beat 数不符");
        } else {
            int bad = 0;
            for (int b = 0; b < t.beats; ++b)
                for (int j = 0; j < AXI_BYTES; ++j) {
                    uint8_t want = patByte(t.base, b * AXI_BYTES + j);
                    uint8_t got  = (uint8_t)((rGot[(size_t)b] >> (8 * j)) & 0xFFu);
                    if (got != want) {
                        if (bad < 4) printf("  rdata[beat %d, byte %d] = 0x%02X（期望 0x%02X）\n", b, j, got, want);
                        bad++;
                    }
                }
            if (bad) { printf("  读数据逐字节错 %d/%d\n", bad, burstBytes); fail("读数据没有逐字节正确返回"); }
            if (lastRIdx != t.beats - 1) {
                printf("  rlast 落在 beat %d（期望 %d）\n", lastRIdx, t.beats - 1);
                fail("rlast 位置错");
            }
        }
    }

    // ⑤ B 响应：一笔写突发恰 1 次（只在末组之后）
    if (t.mode != R_ONLY && nB != 1) {
        printf("  B 次数 = %d（期望 1）\n", nB);
        fail("B 响应不是恰一次");
    }

    // ⑥ ★ Task 19：B 通道 id 回带 —— `B.bid` 必须等于本笔 AW 的 `awid`。
    //    逐用例断言（case 2 里已判），这里只打读数；写用例的 awid 一律非 0（装置自检）。
    if (t.mode != R_ONLY) {
        if (t.awid == 0) fail("装置自检：写用例的 awid 不该是 0（否则判 ⑥ 退化成'恒 0 也算对'）");
        if (nB == 1)
            printf("  [BID] awid=0x%X ⇒ B.bid=0x%X %s\n", t.awid, lastBid,
                   lastBid == t.awid ? "OK（回带）" : "MISMATCH（没回带）");
    }

    printf("  ddr: aw=%d ar=%d wBeat=%d rBeat=%d | 本用例 ddrWStrb!=全1 的 beat=%d | 组数=%d 组拍数=%d\n",
           nAwFire, nArFire, nWBeat, nRBeat, nStrbPartial - strbMark, groups, GRP_BEATS);
    if (t.strb == STRB_ALT && (nStrbPartial - strbMark) == 0)
        fail("部分 wstrb 没有传到 DDR 侧（ddrWStrb 全 1）");
}

// ★ Phase-0 背靠背作业的驱动器（定义在后面；这里前向声明，因为它挂在 axi 主方模型末尾调用）
static void b2bModel();

// 每拍（axi 上升沿之后）调用
static void axiMasterModel() {
    dut->io_axi_aw_awvalid = 0;
    dut->io_axi_w_wvalid   = 0;
    dut->io_axi_ar_arvalid = 0;
    dut->io_axi_b_bready   = 1;
    dut->io_axi_r_rready   = 1;

    if (!mstStarted) return;
    if (mstTest >= kNumTests) { b2bModel(); return; }   // 8 条既有用例跑完 ⇒ 接 Phase-0 背靠背作业
    const TestCase& t = kTests[mstTest];
    bool reading = (t.mode == R_ONLY) || (t.mode == W_THEN_R && mstPhase == 1);

    switch (mstState) {
      case 0:                                    // 发 AW 或 AR
        if (!reading) {
            dut->io_axi_aw_awaddr  = t.addr;
            dut->io_axi_aw_awlen   = (uint32_t)(t.beats - 1);
            dut->io_axi_aw_awid    = t.awid;       // ★ Task 19：逐用例的 id（判 ⑥ 的输入）
            dut->io_axi_aw_awvalid = 1;
            if (dut->io_axi_aw_awready) { mstState = 1; mstBeat = 0; }
        } else {
            // 纯读用例**自带预置**（不依赖写通路：否则写侧一个 bug 会让读判据一起变红、分不清是谁错）
            if (t.mode == R_ONLY && preloaded != mstTest) {
                for (int off = 0; off < t.beats * AXI_BYTES; ++off)
                    ddrMem[t.addr + (uint32_t)off] = patByte(t.base, off);
                preloaded = mstTest;
            }
            dut->io_axi_ar_araddr  = t.addr;
            dut->io_axi_ar_arlen   = (uint32_t)(t.beats - 1);
            dut->io_axi_ar_arid    = 5;
            dut->io_axi_ar_arvalid = 1;
            if (dut->io_axi_ar_arready) {
                mstState = 3; mstBeat = 0;
                rGot.clear(); lastRIdx = -1;
            }
        }
        break;

      case 1:                                    // 发 W beat
        dut->io_axi_w_wdata  = beatValue(t.base, mstBeat);
        dut->io_axi_w_wstrb  = beatStrb(t.strb, mstBeat);
        dut->io_axi_w_wlast  = (mstBeat == t.beats - 1);
        dut->io_axi_w_wvalid = 1;
        if (dut->io_axi_w_wready) {
            if (getenv("DDR_DBG"))
                printf("    [AXI-W] beat=%d data=0x%llX strb=0x%X\n",
                       mstBeat, (unsigned long long)dut->io_axi_w_wdata, (unsigned)dut->io_axi_w_wstrb);
            mstBeat++;
            if (mstBeat >= t.beats) mstState = 2;
        }
        break;

      case 2:                                    // 等 B
        if (dut->io_axi_b_bvalid) {
            lastBid = (uint32_t)dut->io_axi_b_bid;
            // ★ Task 19：判 ⑥ —— B 通道**必须**回带本笔 AW 的 id（从方不许硬编码/漏带）。
            if (lastBid != t.awid) {
                printf("  [BID] awid=0x%X ⇒ 线上 B.bid=0x%X（期望 0x%X）⇒ 从方没有回带 AW id\n",
                       t.awid, lastBid, t.awid);
                fail("B 通道没有回带 AW id（bid != awid）");
            }
            if (dut->io_axi_b_bresp != 0) fail("bresp != OKAY");
            nB++;
            mstState = 5;
        }
        break;

      case 3:                                    // 收 R beat
        if (dut->io_axi_r_rvalid) {
            if (dut->io_axi_r_rid != 5) fail("rid 与 arid 不符");
            if (dut->io_axi_r_rresp != 0) fail("rresp != OKAY");
            rGot.push_back((bus_t)dut->io_axi_r_rdata);
            if (dut->io_axi_r_rlast) lastRIdx = mstBeat;
            mstBeat++;
            if (mstBeat >= t.beats) mstState = 5;
        }
        break;

      case 5:                                    // 手势先撤一拍再判定
        if (t.mode == W_THEN_R && mstPhase == 0) { mstPhase = 1; mstState = 0; mstBeat = 0; }
        else mstState = 6;
        break;

      case 6:
        judgeTest();
        mstTest++;
        mstState = 0; mstPhase = 0; mstBeat = 0;
        takeMarks();                       // 下一个用例的记账起点
        break;
    }
}

// =====================================================================
// ★ Y1-DMA Phase-0 新作业：**背靠背 N 笔**（写-only / 读-only / 读写混）
//   为什么要它：既有 8 条用例都是"一笔一笔、等响应再发下一笔"，**结构上问不出"能不能多未完成"**。
//   本作业的 AXI 主方**不等响应就继续发下一笔**（真背靠背），判据四条：
//     ① **逐字节对账**：写区逐字节 == 期望模式；读回逐拍逐字节 == 期望模式；
//     ② **DDR 地址纸带**：每笔 +32B（= 8 个 32bit 字）逐笔递进（写/读各查各自）；
//     ③ **B / rlast 次数**：每笔写恰 1 个 B（且 `bid` 按序 = 1+k）、每笔读恰 1 次 rlast 且在末拍；
//     ④ **★「未完成 > 1」的证据**：DUT **自报**的 `io_dbgOutW`/`io_dbgOutR` 在**本作业内的高水位**
//        必须 ≥ `B2B_MIN_OUT`（默认 2）。改前的单未完成设计（以及把 `LANES/DEPTH` 打成 1 的
//        负对照 NC6）**证不出** ≥2 —— `outW/outR ≤ DEPTH` 由 AXI 口的信用计数**保证**，
//        所以这不是"看起来能到 2"，而是"DEPTH=1 时结构上到不了 2"。
//        （另打印一条**外部口径**高水位：AW 发−B 回 / AR 发−rlast 回，作旁证。）
// =====================================================================
static const int      B2B_N     = 8;             // 每个方向的笔数（混合作业各 4 笔）
static const uint32_t B2B_WBASE = 0x00020000u;   // 写作业区（32B 对齐，每笔 32B）
static const uint32_t B2B_RBASE = 0x00030000u;   // 读作业区
static const uint32_t B2B_WPAT  = 0x40u;         // 写模式起点（每笔再偏移）
static const uint32_t B2B_RPAT  = 0x90u;

static int  b2bJob = -1;          // -1=未开始 0=写 1=读 2=混 3=全结束
static int  b2bNw = 0, b2bNr = 0;
static int  b2bAwI = 0, b2bArI = 0, b2bWI = 0, b2bWBeat = 0, b2bB = 0;
static int  b2bRIdx = 0, b2bRBeat = 0, b2bRlast = 0;
static long b2bWBad = 0, b2bRBad = 0;
static long b2bNrBytes = 0;
static long b2bAWmark = 0, b2bARmark = 0;
static long b2bExtMaxW = 0, b2bExtMaxR = 0;      // 外部口径高水位（旁证）
static int  b2bDutMaxW = 0, b2bDutMaxR = 0;      // ★ DUT 自报口径高水位（判据 ④）
static int  b2bMinOut = 2;                       // B2B_MIN_OUT（负对照可调成 1 之外的口径）
static uint64_t b2bCyc0 = 0;                     // 本作业起始拍（速度口径用）

static uint32_t b2bPat(uint32_t pat, int k) { return pat + (uint32_t)(k * GRP_BEATS * AXI_BYTES); }

static void b2bSetup(int job) {
  b2bJob = job;
  b2bNw = (job == 0) ? B2B_N : (job == 2 ? B2B_N / 2 : 0);
  b2bNr = (job == 1) ? B2B_N : (job == 2 ? B2B_N / 2 : 0);
  b2bAwI = b2bArI = b2bWI = b2bWBeat = b2bB = 0;
  b2bRIdx = b2bRBeat = b2bRlast = 0;
  b2bWBad = b2bRBad = 0;
  b2bNrBytes = 0;
  b2bDutMaxW = b2bDutMaxR = 0;
  b2bExtMaxW = b2bExtMaxR = 0;
  b2bAWmark = nAwFire; b2bARmark = nArFire;
  b2bCyc0 = cyc;                                  // ★ 速度口径起点
  // 读作业区**自带预置**（不依赖写通路：否则写侧一个 bug 会把读判据也染红、分不清是谁错）
  for (int k = 0; k < b2bNr; ++k)
    for (int off = 0; off < GRP_BEATS * AXI_BYTES; ++off)
      ddrMem[B2B_RBASE + (uint32_t)(32 * k) + (uint32_t)off] = patByte(b2bPat(B2B_RPAT, k), off);
  printf("=== B2B 作业 %d：写 %d 笔 / 读 %d 笔（每笔 32B = %d 拍 × %d bit）===\n",
         job, b2bNw, b2bNr, GRP_BEATS, AXI_W);
}

static void b2bCheck() {
  // ① 写区逐字节（写作业区**只有本作业写过**）
  for (int k = 0; k < b2bNw; ++k)
    for (int off = 0; off < GRP_BEATS * AXI_BYTES; ++off) {
      uint8_t want = patByte(b2bPat(B2B_WPAT, k), off);
      uint8_t got  = memRd(B2B_WBASE + (uint32_t)(32 * k) + (uint32_t)off);
      if (got != want) {
        if (b2bWBad < 4) printf("  写 mem[笔 %d +%d] = 0x%02X（期望 0x%02X）\n", k, off, got, want);
        b2bWBad++;
      }
    }
  if (b2bWBad)   { printf("  B2B 写数据逐字节错 %ld 字节\n", b2bWBad); fail("B2B 写数据没有逐字节落地"); }
  if (b2bRBad)   { printf("  B2B 读数据逐字节错 %ld 字节\n", b2bRBad); fail("B2B 读数据没有逐字节返回"); }
  // ② DDR 地址纸带（每笔 +8 字 = 32B）
  for (int k = 0; k < b2bNw; ++k) {
    uint32_t want = (B2B_WBASE >> 2) + (uint32_t)(DDR_WORD_STEP * k);
    uint32_t got  = awTrace[(size_t)(b2bAWmark + k)];
    if (got != want) { printf("  B2B 写地址[%d] = 0x%X（期望 0x%X = 首址 + %d 字）\n", k, got, want, DDR_WORD_STEP * k);
                       fail("B2B 写地址没有按 8 字（32B）递进"); break; }
  }
  for (int k = 0; k < b2bNr; ++k) {
    uint32_t want = (B2B_RBASE >> 2) + (uint32_t)(DDR_WORD_STEP * k);
    uint32_t got  = arTrace[(size_t)(b2bARmark + k)];
    if (got != want) { printf("  B2B 读地址[%d] = 0x%X（期望 0x%X = 首址 + %d 字）\n", k, got, want, DDR_WORD_STEP * k);
                       fail("B2B 读地址没有按 8 字（32B）递进"); break; }
  }
  // ③ B / rlast 次数
  if (b2bB != b2bNw)     { printf("  B2B B 次数 = %d（期望 %d）\n", b2bB, b2bNw); fail("B2B B 响应不是每笔恰一次"); }
  if (b2bRlast != b2bNr) { printf("  B2B rlast 次数 = %d（期望 %d）\n", b2bRlast, b2bNr); fail("B2B rlast 不是每笔恰一次"); }
  if (b2bNrBytes != (long)b2bNr * GRP_BEATS * AXI_BYTES) {
    printf("  B2B 读回字节 = %ld（期望 %d）\n", b2bNrBytes, b2bNr * GRP_BEATS * AXI_BYTES); fail("B2B 读回拍数不符");
  }
  // ④ ★「未完成 > 1」的证据（DUT 自报是**判据**；外部口径是旁证）
  printf("  [OUTSTANDING] 写：DUT自报峰值=%d（外部口径 %ld）｜读：DUT自报峰值=%d（外部口径 %ld）｜要求 ≥ %d\n",
         b2bDutMaxW, b2bExtMaxW, b2bDutMaxR, b2bExtMaxR, b2bMinOut);
  if (b2bNw > 0 && b2bDutMaxW < b2bMinOut) {
    printf("  [FAIL] 写未完成峰值 %d < %d ⇒ 拿不出「未完成 > 1」的证据（单未完成形态）\n", b2bDutMaxW, b2bMinOut);
    fail("B2B 写未完成峰值不够（outstanding > 1 的证据缺失）");
  }
  if (b2bNr > 0 && b2bDutMaxR < b2bMinOut) {
    printf("  [FAIL] 读未完成峰值 %d < %d ⇒ 拿不出「未完成 > 1」的证据（单未完成形态）\n", b2bDutMaxR, b2bMinOut);
    fail("B2B 读未完成峰值不够（outstanding > 1 的证据缺失）");
  }
  if (!b2bWBad && !b2bRBad && b2bB == b2bNw && b2bRlast == b2bNr)
    printf("  B2B 作业 %d：逐字节对 + 纸带对 + B/rlast 对（见上面的 [OUTSTANDING] 行）\n", b2bJob);

  // ★ 速度口径：本作业的**墙上拍数 / 搬运字节**（axi 域 100MHz ⇒ 1 B/cyc = 100 MB/s）
  {
    long bytes = (long)(b2bNw + b2bNr) * GRP_BEATS * AXI_BYTES;
    unsigned long long el = cyc - b2bCyc0;
    printf("  [SPEED] 作业 %d：%llu cyc / %ld B = %.3f cyc/B = %.1f MB/s（axi 100MHz 口径）\n",
           b2bJob, el, bytes, (double)el / (double)bytes, 100.0 * (double)bytes / (double)el);
  }
}

static void b2bModel() {
  if (b2bJob < 0) b2bSetup(0);
  if (b2bJob > 2) return;
  static int b2bDbgN = 0;
  if (getenv("B2B_DBG") && b2bJob == 0 && b2bDbgN < 200) {
    b2bDbgN++;
    printf("    [cyc %3llu] awv=%d awr=%d wv=%d wr=%d bv=%d br=%d | outW=%d max=%d outR=%d | ddrAWv=%d ddrAWr=%d Wr=%d Arv=%d Rv=%d\n",
           (unsigned long long)cyc, (int)dut->io_axi_aw_awvalid, (int)dut->io_axi_aw_awready,
           (int)dut->io_axi_w_wvalid, (int)dut->io_axi_w_wready,
           (int)dut->io_axi_b_bvalid, (int)dut->io_axi_b_bready,
           (int)dut->io_dbgOutW, (int)dut->io_dbgMaxOutW, (int)dut->io_dbgOutR,
           (int)dut->io_ddrAwValid, (int)dut->io_ddrAwReady, (int)dut->io_ddrWReady,
           (int)dut->io_ddrArValid, (int)dut->io_ddrRValid);
  }

  // 发 AW：**只要 (awvalid&awready) 就继续发下一笔，不等 B**（这就是"背靠背"）
  if (b2bAwI < b2bNw) {
    dut->io_axi_aw_awaddr  = B2B_WBASE + (uint32_t)(32 * b2bAwI);
    dut->io_axi_aw_awlen   = (uint32_t)(GRP_BEATS - 1);
    dut->io_axi_aw_awid    = (uint32_t)(1 + b2bAwI);
    dut->io_axi_aw_awvalid = 1;
    if (dut->io_axi_aw_awready) {
      if (getenv("B2B_DBG")) printf("  [B2BAW] 收下 k=%d id=%d addr=0x%X (outW=%d max=%d)\n", b2bAwI, 1 + b2bAwI, B2B_WBASE + 32u * b2bAwI, (int)dut->io_dbgOutW, (int)dut->io_dbgMaxOutW);
      b2bAwI++;
    }
  }
  // 发 W（按笔顺序、一拍一拍）
  if (b2bWI < b2bNw) {
    dut->io_axi_w_wdata  = beatValue(b2bPat(B2B_WPAT, b2bWI), b2bWBeat);
    dut->io_axi_w_wstrb  = (1u << AXI_BYTES) - 1u;
    dut->io_axi_w_wlast  = (b2bWBeat == GRP_BEATS - 1);
    dut->io_axi_w_wvalid = 1;
    if (dut->io_axi_w_wready) {
      if (getenv("B2B_DBG"))
        printf("  [B2BW] k=%d beat=%d data0=%02X\n", b2bWI, b2bWBeat,
               (unsigned)((uint64_t)dut->io_axi_w_wdata & 0xFFu));
      b2bWBeat++;
      if (b2bWBeat >= GRP_BEATS) { b2bWBeat = 0; b2bWI++; }
    }
  }
  // 发 AR：**只要 arready 就继续发下一笔**（读侧的多未完成）
  if (b2bArI < b2bNr) {
    dut->io_axi_ar_araddr  = B2B_RBASE + (uint32_t)(32 * b2bArI);
    dut->io_axi_ar_arlen   = (uint32_t)(GRP_BEATS - 1);
    dut->io_axi_ar_arid    = 5;
    dut->io_axi_ar_arvalid = 1;
    if (dut->io_axi_ar_arready) b2bArI++;
  }
  // 收 B（按 AW 顺序 ⇒ bid 必须逐笔 = 1+k）
  if (dut->io_axi_b_bvalid && dut->io_axi_b_bready) {
    if (getenv("B2B_DBG"))
      printf("  [B2BB] n=%d bid=0x%X bvalid=%d outW=%d max=%d\n", b2bB, (unsigned)dut->io_axi_b_bid, (int)dut->io_axi_b_bvalid, (int)dut->io_dbgOutW, (int)dut->io_dbgMaxOutW);
    if (b2bB < b2bNw && (uint32_t)dut->io_axi_b_bid != (uint32_t)(1 + b2bB)) {
      printf("  [BID] B2B 第 %d 个 B 的 bid=0x%X（期望 0x%X）\n",
             b2bB, (unsigned)dut->io_axi_b_bid, (unsigned)(1 + b2bB));
      fail("B2B B 通道没有按序回带 awid");
    }
    b2bB++;
  }
  // 收 R（逐拍逐字节对；rlast 必须落在每笔末拍）
  if (dut->io_axi_r_rvalid && dut->io_axi_r_rready) {
    if (b2bRIdx < b2bNr) {
      if (dut->io_axi_r_rid != 5) fail("B2B rid 与 arid 不符");
      for (int j = 0; j < AXI_BYTES; ++j) {
        uint8_t want = patByte(b2bPat(B2B_RPAT, b2bRIdx), b2bRBeat * AXI_BYTES + j);
        uint8_t got  = (uint8_t)(((uint64_t)dut->io_axi_r_rdata >> (8 * j)) & 0xFFu);
        if (got != want) {
          if (b2bRBad < 4) printf("  读 [笔 %d 拍 %d 字节 %d] = 0x%02X（期望 0x%02X）\n", b2bRIdx, b2bRBeat, j, got, want);
          b2bRBad++;
        }
      }
      b2bNrBytes += AXI_BYTES;
    }
    if (dut->io_axi_r_rlast) {
      if (b2bRBeat != GRP_BEATS - 1) {
        printf("  B2B rlast 落在拍 %d（期望 %d）\n", b2bRBeat, GRP_BEATS - 1);
        fail("B2B rlast 位置错");
      }
      b2bRIdx++; b2bRlast++; b2bRBeat = 0;
    } else {
      b2bRBeat++;
    }
  }
  // 未完成采样（DUT 自报 = 判据；外部口径 = 旁证）
  { int v = (int)dut->io_dbgOutW; if (v > b2bDutMaxW) b2bDutMaxW = v; }
  { int v = (int)dut->io_dbgOutR; if (v > b2bDutMaxR) b2bDutMaxR = v; }
  { long v = (long)(nAwFire - b2bAWmark) - (long)b2bB;  if (v > b2bExtMaxW) b2bExtMaxW = v; }
  { long v = (long)(nArFire - b2bARmark) - (long)b2bRlast; if (v > b2bExtMaxR) b2bExtMaxR = v; }

  bool done = (b2bAwI == b2bNw) && (b2bWI == b2bNw) && (b2bB == b2bNw) &&
              (b2bArI == b2bNr) && (b2bRIdx == b2bNr) && (b2bRlast == b2bNr) &&
              (b2bNrBytes == (long)b2bNr * GRP_BEATS * AXI_BYTES);
  if (done) {
    b2bCheck();
    if (b2bJob >= 2) b2bJob = 3; else b2bSetup(b2bJob + 1);
  }
}

// ===================== 时钟 =====================
// axi 域 = 板上 cpu_clk（100MHz）；ddr 域由 `DDR_MHZ` 给（板上 core_clk = 125MHz）。
// 用 Bresenham 分摊到每拍（125 ⇒ 每 4 拍 5 个 ddr 上升沿）。CDC 是 4 相电平握手，与频率比无关
// （源码注释原话）⇒ 至少跑 1:1 与 5:4 两档当敏感度对照。
static int ddrMhz   = 100;
static int ddrAccum = 0;

static void ddrEdge() {
    dut->io_ddr_clk = 0; dut->eval();
    dut->io_ddr_clk = 1; dut->eval();
    ddrIpModel();                        // 采样 DUT → 推进模型 → 驱动下一拍
    dut->eval();
}
static void axiEdge() {
    dut->clock = 0; dut->eval();
    dut->clock = 1; dut->eval();
    axiMasterModel();
    dut->eval();
}

int main(int argc, char** argv) {
    VerilatedContext ctx;
    ctx.commandArgs(argc, argv);
    if (getenv("DDR_MHZ"))     ddrMhz   = atoi(getenv("DDR_MHZ"));
    if (getenv("DDR_MAX_CYC")) MAX_CYC  = strtoull(getenv("DDR_MAX_CYC"), NULL, 10);
    if (getenv("R_LAT"))       R_LATENCY = atoi(getenv("R_LAT"));         // DDR 读延迟（Phase-0 可调档）
    if (getenv("B2B_MIN_OUT")) b2bMinOut = atoi(getenv("B2B_MIN_OUT"));   // 未完成证据的下限

    dut = new VDDR3Bridge;
    // 复位：`reset` 高有效（axi 域）；`io_ddr_rstn` 板级给 ddr_init_done（高 = 可跑）
    dut->reset = 1; dut->io_ddr_rstn = 0;
    dut->io_axi_aw_awaddr = 0; dut->io_axi_aw_awlen = 0; dut->io_axi_aw_awid = 0;
    dut->io_axi_aw_awvalid = 0;
    dut->io_axi_w_wdata = 0; dut->io_axi_w_wstrb = 0; dut->io_axi_w_wlast = 0;
    dut->io_axi_w_wvalid = 0;
    dut->io_axi_ar_araddr = 0; dut->io_axi_ar_arlen = 0; dut->io_axi_ar_arid = 0;
    dut->io_axi_ar_arvalid = 0;
    dut->io_axi_b_bready = 1; dut->io_axi_r_rready = 1;
    dut->io_ddrAwReady = 1; dut->io_ddrWReady = 0; dut->io_ddrArReady = 1;
    for (int i = 0; i < 8; ++i) dut->io_ddrRData[i] = 0;
    dut->io_ddrRValid = 0; dut->io_ddrRLast = 0;
    for (int i = 0; i < 8; ++i) { ddrEdge(); axiEdge(); }
    dut->reset = 0; dut->io_ddr_rstn = 1;
    for (int i = 0; i < 2; ++i) { ddrEdge(); axiEdge(); }   // 复位撤离后再起步
    takeMarks();
    mstStarted = true;

    printf("DDR3Bridge 单元装置：AXI_W=%d（每 32B 组 = %d 拍，wstrb %dbit）| %d 个测试 | ddr=%dMHz max_cyc=%llu\n",
           AXI_W, GRP_BEATS, AXI_BYTES, kNumTests, ddrMhz, (unsigned long long)MAX_CYC);
    printf("Task 19：B 通道 id 回带判据已并入每个写用例（awid 非 0；末条 `BID` 用 0xA）"
           "⇒ 摘掉回带（负对照 NC5）必须 TEST FAILED\n");
    printf("Phase-0：8 条既有用例之后接 **B2B 背靠背 N=%d 笔**（写/读/混）作业；"
           "未完成证据取 DUT 自报 `io_dbgOutW/io_dbgOutR` 的作业内高水位，要求 ≥ %d"
           "（把 LANES/DEPTH 打成 1 的负对照 NC6 ⇒ 结构上到不了 2 ⇒ 必 TEST FAILED）\n",
           B2B_N, b2bMinOut);

    while (cyc < MAX_CYC && !ipFail && (mstTest < kNumTests || b2bJob <= 2)) {
        ddrAccum += ddrMhz;                  // Bresenham：5:4 时每 4 拍给 5 个 ddr 上升沿
        while (ddrAccum >= 100) { ddrAccum -= 100; ddrEdge(); }
        axiEdge();
        cyc++;
        if (getenv("DDR_DBG") && cyc < 60)
            printf("  [cyc %3llu] awv=%d awr=%d wv=%d wr=%d bv=%d | ddrAWv=%d ddrAWr=%d ddrWr=%d ddrARv=%d ddrRr=%d "
                   "| mst(st=%d beat=%d ph=%d) ip(st=%d)\n",
                   (unsigned long long)cyc,
                   (int)dut->io_axi_aw_awvalid, (int)dut->io_axi_aw_awready,
                   (int)dut->io_axi_w_wvalid, (int)dut->io_axi_w_wready, (int)dut->io_axi_b_bvalid,
                   (int)dut->io_ddrAwValid, (int)dut->io_ddrAwReady, (int)dut->io_ddrWReady,
                   (int)dut->io_ddrArValid, (int)dut->io_ddrRValid,
                   mstState, mstBeat, mstPhase, ipState);
    }

    if (ipFail) printf("  [FAIL] %s\n", ipMsg);

    bool done = (mstTest >= kNumTests) && (b2bJob > 2);
    if (!done && !ipFail)
        printf("  [FAIL] 拍数上限 %llu 内没跑完（既有用例卡在 %d 状态 %d beat %d phase %d；B2B 作业 %d：aw=%d/%d w=%d/%d b=%d/%d ar=%d/%d r=%d/%d）⇒ 挂死\n",
               (unsigned long long)MAX_CYC, mstTest, mstState, mstBeat, mstPhase,
               b2bJob, b2bAwI, b2bNw, b2bWI, b2bNw, b2bB, b2bNw, b2bArI, b2bNr, b2bRlast, b2bNr);
    if (!done) nFail++;

    printf("cyc=%llu  ddr: aw=%d ar=%d wBeat=%d rBeat=%d\n",
           (unsigned long long)cyc, nAwFire, nArFire, nWBeat, nRBeat);

    bool pass = done && (nFail == 0);
    printf("=== %s ===\n", pass ? "TEST PASSED" : "TEST FAILED");
    dut->final();
    delete dut;
    return pass ? 0 : 1;
}
