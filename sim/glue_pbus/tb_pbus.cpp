// ===================== YeshenSocGlue 外设总线译码单元装置 =====================
//
// 为什么需要它：`YeshenSocGlue`（由 `src/YeshenSocGlue.scala` 生成，网表 `rtl/YeshenSocGlue.v`）把
//   自研 RV32 核的三条 AXI4 主口合并/分流：其中第三条 `io_cpuIo_*`（**单拍 32bit**，无 len/burst）
//   被译码到外设总线（console / GPIO / ETH / CLINT / PLIC）。**这条译码此前没有任何仿真覆盖**
//   —— 一个基址常量写错，板子要跑起来才看得见。本装置把 `rtl/YeshenSocGlue.v:3850-3863` 的
//   每一个译码窗口逐个钉成**可观测、可翻红**的断言。
//
// DUT：--top-module YeshenSocGlue。单时钟 `clock` + **同步高有效** `reset`（复位保持若干拍再放）。
//   把所有可能干扰的输入静默：io_loadMode=0（两个装载器都不激活）、io_uart_rxd=1（空闲高）、
//   io_sd_miso=1、io_ethIrq=0、io_gpio_in=0；两条 CPU 内存主口（cpuFetch/cpuLsu）全 0 不发起。
//
// 判据（每条都打印实测值 ⇒ 现场可读，不是冒烟）：
//   ① CLINT mtime 真的在走：读 MTIME_LO(+0xBFF8) 两次，中间隔若干拍，第二次必须更大。
//   ② CLINT mtimecmp 回环：写 +0x4000 / +0x4004，分半读回逐位相等。
//   ③ CLINT msip 回环：写 +0x0000 bit0=1，读回 ==1，且 `io_intMSoft` 引脚随之拉高。
//   ④ PLIC priority 回环：源 1(+0x0004) / 源 2(+0x0008) 各写一个非 0 常量并读回。
//   ⑤ GPIO：写 DATA_OUT(+0x04)/DIRECTION(+0x08)，**看引脚** io_gpio_out/io_gpio_dir 随之改变；
//      再换第二个图案确认一次（防"引脚被钉死"这类假通过）。
//   ⑥ Console：读 ns16550a LSR(+0x14) 的**已知空闲值 0x60**（THRE(b5)|TEMT(b6) 同置）
//      ⇒ 译码 + 读数据通路是活的（rresp 必须 OKAY）。
//   ⑦ ETH 三窗（mac 0xF0003000 / mdio 0xF0004000 / buffer 0xF0008000，8KiB=0x2000）：
//      读写各一笔，`io_ethAxi_arvalid/awvalid` 必须置起、且 `io_ethAxi_araddr/awaddr` == 发出的地址；
//      对 console/GPIO/CLINT/PLIC（外加三处**窗口边界外**地址）必须**不**置起。
//   ⑦b VIDEO 窗（2026-10-19 V1-T6；基址 0xF0007400，**1 KiB** 掩码 0xFFFF_FC00）：
//      基址 0x7400 与 BOX0 0x7410 各读写一笔 ⇒ `io_videoAxi_arvalid/awvalid` 必须置起，
//      且 `io_videoAxi_araddr/awaddr` == **窗内偏移**（0x000 / 0x010；下游 video_regs 是偏移从口），
//      读回从方模型的恒定图案 0xA5A50001、bresp/rresp=0。**同时**这两处 `io_ethAxi_*valid` 必须为 0
//      （不许一个地址被两个窗同时认领）。
//      反面：0x5000 / 0x7000 两个**未译码洞探针**仍必须 DECERR，且 `io_videoAxi_*valid` 与
//      `io_ethAxi_*valid` **都**为 0（VIDEO 窗把 0x7400–0x77FF 占走，不许顺带吃掉 0x7000）。
//   ⑧ DECERR：读、写各一笔落在谁都不译码的地址（0xF0100000，远离所有窗）⇒ rresp/bresp == 2'b11。
//
// 装置自检：`io_mem_*` 只提供"永远 ready + 单拍 B/R=OKAY"的从方，防止内存路挂死；因为
//   io_loadMode=0 且两条 CPU 内存主口不驱动，本装置**不该**有哪怕一笔内存事务 ⇒ 结尾断言
//   内存侧三个计数器全 0（证明上面的断言不依赖内存从方）。`io_ethAxi` 也有一份 always-ready 从方。
//   每个等待循环都有拍数上限，超时即 fail（挂死会被报出来，而不是把装置挂住）。
//
// 负对照：`sim/glue_pbus/negctl_pbus.sh` 用 patch_exact.py **精确改一行**把 CLINT **读窗基址**
//   从 16'hF001 改到 16'hF002 ⇒ 判据 ①（以及依赖它的 ②③）立刻翻红 ⇒ 期望 `=== TEST FAILED ===`。
#include "VYeshenSocGlue.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>

// ---------------- 译码窗口基址（对到 rtl/YeshenSocGlue.v:3850-3863）----------------
#define ADDR_CONSOLE   0xF0001000u   // [31:12]==20'hF0001
#define ADDR_GPIO      0xF0002000u   // [31:12]==20'hF0002
#define ADDR_ETH_MAC   0xF0003000u   // [31:8] ==24'hF00030
#define ADDR_ETH_MDIO  0xF0004000u   // [31:8] ==24'hF00040
#define ADDR_ETH_BUF   0xF0008000u   // [31:13]==19'h78004（8KiB）
#define ADDR_CLINT     0xF0010000u   // [31:16]==16'hF001
#define ADDR_PLIC      0xF0C00000u   // [31:22]==10'h3C3
#define ADDR_VIDEO     0xF0007400u   // [31:10]==22'h3C001D（1 KiB，掩码 0xFFFF_FC00）
#define ADDR_GPU       0xF0005000u   // 2026-10-31 GPU P1：4 KiB（掩码 0xFFFF_F000）
#define ADDR_UNDEC     0xF0100000u   // 谁都不译码（CLINT 与 PLIC 之间，远离所有窗）⇒ DECERR

// 寄存器偏移（对到 src/peripheral/*.scala）
#define CONSOLE_LSR         (ADDR_CONSOLE + 0x14)              // ns16550a LSR
#define GPIO_DATA_OUT       (ADDR_GPIO + 0x04)
#define GPIO_DIRECTION      (ADDR_GPIO + 0x08)
#define CLINT_MSIP          (ADDR_CLINT + 0x0000)
#define CLINT_MTIMECMP_LO   (ADDR_CLINT + 0x4000)
#define CLINT_MTIMECMP_HI   (ADDR_CLINT + 0x4004)
#define CLINT_MTIME_LO      (ADDR_CLINT + 0xBFF8)
#define PLIC_PRIO1          (ADDR_PLIC + 0x04)
#define PLIC_PRIO2          (ADDR_PLIC + 0x08)

static VYeshenSocGlue* dut = nullptr;
static uint64_t  cyc   = 0;
static const int CAP   = 64;        // 每个等待循环的拍数上限（超时即 fail）
static int       nFail = 0;

static void fail(const char* what) { printf("  [FAIL] %s\n", what); nFail++; }

// ---------------- ETH 外发观测（组合透传：io_ethAxi_araddr=io_cpuIo_araddr 等）----------------
static int      g_ethArSeen = 0, g_ethAwSeen = 0;
static uint32_t g_ethArAddr = 0, g_ethAwAddr = 0;
static void ethMonReset() { g_ethArSeen = 0; g_ethAwSeen = 0; g_ethArAddr = 0; g_ethAwAddr = 0; }

// ---------------- 从方模型（内存 / ETH），只做"永不挂死"的兜底 ----------------
static int      g_memAr = 0, g_memAw = 0, g_memW = 0;
static uint8_t  mem_bvalid = 0, mem_rvalid = 0;
static void memSlavePostEdge() {
    if (mem_bvalid && dut->io_mem_b_bready) mem_bvalid = 0;
    if (mem_rvalid && dut->io_mem_r_rready) mem_rvalid = 0;
    if (dut->io_mem_aw_awvalid && dut->io_mem_aw_awready) g_memAw++;
    if (dut->io_mem_w_wvalid  && dut->io_mem_w_wready)  { g_memW++; mem_bvalid = 1; }
    if (dut->io_mem_ar_arvalid && dut->io_mem_ar_arready) { g_memAr++; mem_rvalid = 1; }
    dut->io_mem_b_bvalid = mem_bvalid;
    dut->io_mem_r_rvalid = mem_rvalid;
}

static int      g_ethAwFire = 0, g_ethWFire = 0, g_ethArFire = 0;
static uint8_t  eth_bvalid = 0, eth_rvalid = 0;
static void ethSlavePostEdge() {
    if (eth_bvalid && dut->io_ethAxi_bready) eth_bvalid = 0;
    if (eth_rvalid && dut->io_ethAxi_rready) eth_rvalid = 0;
    if (dut->io_ethAxi_awvalid && dut->io_ethAxi_awready) g_ethAwFire++;
    if (dut->io_ethAxi_wvalid  && dut->io_ethAxi_wready)  { g_ethWFire++; eth_bvalid = 1; }
    if (dut->io_ethAxi_arvalid && dut->io_ethAxi_arready) { g_ethArFire++; eth_rvalid = 1; }
    dut->io_ethAxi_bvalid = eth_bvalid;
    dut->io_ethAxi_rvalid = eth_rvalid;
}

// ---------------- VIDEO 窗从方模型（永远 ready；写：bvalid 一拍；读：rvalid 一拍，rdata 恒定）----------------
// 下游真件是 `board/cam/video_regs.v` 的 AxiLite 从口（Task 7 才在板级接）；本装置只需要一个
// "会应答、图案可认"的替身：读数据恒为 0xA5A50001（既不是 0 也不是 x ⇒ 证明确实是**这根** rdata
// 通路被选通，而不是默认分支的 0）。写侧只回一拍 OKAY，不建模寄存器回环（寄存器语义归 U4 的装置）。
static const uint32_t VIDEO_RDATA = 0xA5A50001u;
static int      g_vidArSeen = 0, g_vidAwSeen = 0;
static uint32_t g_vidArAddr = 0, g_vidAwAddr = 0;
static void vidMonReset() { g_vidArSeen = 0; g_vidAwSeen = 0; g_vidArAddr = 0; g_vidAwAddr = 0; }

static int      g_vidAwFire = 0, g_vidWFire = 0, g_vidArFire = 0;
static uint8_t  vid_bvalid = 0, vid_rvalid = 0;
static void vidSlavePostEdge() {
    if (vid_bvalid && dut->io_videoAxi_bready) vid_bvalid = 0;
    if (vid_rvalid && dut->io_videoAxi_rready) vid_rvalid = 0;
    if (dut->io_videoAxi_awvalid && dut->io_videoAxi_awready) g_vidAwFire++;
    if (dut->io_videoAxi_wvalid  && dut->io_videoAxi_wready)  { g_vidWFire++; vid_bvalid = 1; }
    if (dut->io_videoAxi_arvalid && dut->io_videoAxi_arready) { g_vidArFire++; vid_rvalid = 1; }
    dut->io_videoAxi_bvalid = vid_bvalid; dut->io_videoAxi_bresp = 0;
    dut->io_videoAxi_rvalid = vid_rvalid; dut->io_videoAxi_rdata = VIDEO_RDATA;
    dut->io_videoAxi_rresp  = 0;
}

// ---------------- GPU 窗从方模型（2026-10-31；下游 = 板级 gpu_top 的 AXI-Lite 从口）----------------
// 判据要点：glue 给 GPU 的地址必须是**窗内偏移**（pR(11,0)/pW(11,0)），若透传整根 SoC 地址，
//   下游 gpu_csr 的 `addr[11:0]` 恰好一致 ⇒ 地址错也看不出来；所以这里同时断言 araddr==addr&0xFFF。
static const uint32_t GPU_RDATA = 0x47505531u;   // "GPU1"：非 0 非 x ⇒ 证明确实是 GPU 这根口被选通
static int      g_gpuArSeen = 0, g_gpuAwSeen = 0;
static uint32_t g_gpuArAddr = 0, g_gpuAwAddr = 0;
static void gpuMonReset() { g_gpuArSeen = 0; g_gpuAwSeen = 0; g_gpuArAddr = 0; g_gpuAwAddr = 0; }

static int      g_gpuAwFire = 0, g_gpuWFire = 0, g_gpuArFire = 0;
static uint8_t  gpu_bvalid = 0, gpu_rvalid = 0;
static void gpuSlavePostEdge() {
    if (gpu_bvalid && dut->io_gpuAxi_bready) gpu_bvalid = 0;
    if (gpu_rvalid && dut->io_gpuAxi_rready) gpu_rvalid = 0;
    if (dut->io_gpuAxi_awvalid && dut->io_gpuAxi_awready) g_gpuAwFire++;
    if (dut->io_gpuAxi_wvalid  && dut->io_gpuAxi_wready)  { g_gpuWFire++; gpu_bvalid = 1; }
    if (dut->io_gpuAxi_arvalid && dut->io_gpuAxi_arready) { g_gpuArFire++; gpu_rvalid = 1; }
    dut->io_gpuAxi_bvalid = gpu_bvalid; dut->io_gpuAxi_bresp = 0;
    dut->io_gpuAxi_rvalid = gpu_rvalid; dut->io_gpuAxi_rdata = GPU_RDATA;
    dut->io_gpuAxi_rresp  = 0;
}

// ---------------- 时钟：本装置把"组合电平采样"与"时钟推进"分成两步 ----------------
// 为什么必须分开：外设（CLINT/UART/GPIO/PLIC）的 rValid 是**在 AR 握手那一拍就置起**的寄存器
//   ⇒ 应答电平只存活"握手后、下一拍 posedge 之前"这一个组合窗口。若像别处那样"先 posedge 再读
//   输出"，读到的就是已经把它清掉之后的值 ⇒ 永远 R 超时（本装置第一次跑就踩到了这个）。
// 因此：`settle()` 先算本拍组合（调用方已摆好输入）并观测；`advance()` 才推 posedge + 从方反应。
static void settle() {
    dut->eval();                                   // 本拍组合（含译码）
    if (dut->io_ethAxi_arvalid) { g_ethArSeen++; g_ethArAddr = dut->io_ethAxi_araddr; }
    if (dut->io_ethAxi_awvalid) { g_ethAwSeen++; g_ethAwAddr = dut->io_ethAxi_awaddr; }
    if (dut->io_videoAxi_arvalid) { g_vidArSeen++; g_vidArAddr = dut->io_videoAxi_araddr; }
    if (dut->io_videoAxi_awvalid) { g_vidAwSeen++; g_vidAwAddr = dut->io_videoAxi_awaddr; }
    if (dut->io_gpuAxi_arvalid)   { g_gpuArSeen++; g_gpuArAddr = dut->io_gpuAxi_araddr; }
    if (dut->io_gpuAxi_awvalid)   { g_gpuAwSeen++; g_gpuAwAddr = dut->io_gpuAxi_awaddr; }
}
static void advance() {
    dut->clock = 1; dut->eval();                   // posedge（时序更新）
    memSlavePostEdge();
    ethSlavePostEdge();
    vidSlavePostEdge();
    gpuSlavePostEdge();
    dut->clock = 0; dut->eval();                   // negedge
    cyc++;
}
static void tick() { settle(); advance(); }        // 空闲推进（输入先摆好）

static void setCpuIoIdle() {
    dut->io_cpuIo_awvalid = 0; dut->io_cpuIo_awaddr = 0; dut->io_cpuIo_awsize = 2;
    dut->io_cpuIo_awcache = 0; dut->io_cpuIo_awprot = 0;
    dut->io_cpuIo_wvalid  = 0; dut->io_cpuIo_wdata  = 0; dut->io_cpuIo_wstrb = 0xF; dut->io_cpuIo_wlast = 1;
    dut->io_cpuIo_arvalid = 0; dut->io_cpuIo_araddr = 0; dut->io_cpuIo_arsize = 2;
    dut->io_cpuIo_arcache = 0; dut->io_cpuIo_arprot = 0;
    dut->io_cpuIo_bready  = 1; dut->io_cpuIo_rready = 1;
}

// ---------------- 单拍 AXI 主口：读 / 写 ----------------
// 读：arvalid + 稳定地址 → 等 arready → 等 rvalid，采 rdata/rresp/rlast（都在 posedge 前采样）。
static bool opRead(uint32_t addr, uint32_t* data, uint8_t* resp, bool* rlast, const char* tag) {
    bool accepted = false;
    for (int k = 0; k < CAP && !accepted; ++k) {
        dut->io_cpuIo_arvalid = 1; dut->io_cpuIo_araddr = addr;
        dut->io_cpuIo_arsize = 2;  dut->io_cpuIo_arcache = 0; dut->io_cpuIo_arprot = 0;
        settle();
        accepted = (dut->io_cpuIo_arready != 0);
        advance();                                     // 握手在本拍 posedge 发生
    }
    if (!accepted) { printf("  [FAIL] %s: AR 握手超时（>%d 拍）\n", tag, CAP); nFail++; return false; }
    dut->io_cpuIo_arvalid = 0;

    bool got = false;
    for (int k = 0; k < CAP && !got; ++k) {
        settle();                                      // ★ posedge 之前采样 R（应答只活这一拍）
        if (dut->io_cpuIo_rvalid) {
            *data = (uint32_t)dut->io_cpuIo_rdata; *resp = (uint8_t)dut->io_cpuIo_rresp;
            *rlast = (bool)dut->io_cpuIo_rlast; got = true;
        }
        advance();                                     // 完成本拍（含 R 握手，清 rSel/设备 rValid）
    }
    if (!got) { printf("  [FAIL] %s: R 超时（>%d 拍）\n", tag, CAP); nFail++; return false; }
    return true;
}

// 写：awvalid+wvalid 同拍 + 稳定地址 → 等 awready/wready → 等 bvalid，采 bresp。
static bool opWrite(uint32_t addr, uint32_t data, uint8_t* resp, const char* tag) {
    bool aw = false, w = false;
    for (int k = 0; k < CAP && !(aw && w); ++k) {
        dut->io_cpuIo_awvalid = aw ? 0 : 1;
        if (!aw) { dut->io_cpuIo_awaddr = addr; dut->io_cpuIo_awsize = 2;
                   dut->io_cpuIo_awcache = 0; dut->io_cpuIo_awprot = 0; }
        dut->io_cpuIo_wvalid = w ? 0 : 1;
        if (!w) { dut->io_cpuIo_wdata = data; dut->io_cpuIo_wstrb = 0xF; dut->io_cpuIo_wlast = 1; }
        settle();
        if (!aw && dut->io_cpuIo_awready) aw = true;
        if (!w  && dut->io_cpuIo_wready)  w  = true;
        advance();
    }
    if (!(aw && w)) { printf("  [FAIL] %s: AW/W 握手超时（>%d 拍）\n", tag, CAP); nFail++; return false; }
    dut->io_cpuIo_awvalid = 0; dut->io_cpuIo_wvalid = 0;

    bool got = false;
    for (int k = 0; k < CAP && !got; ++k) {
        settle();                                      // ★ posedge 之前采样 B
        if (dut->io_cpuIo_bvalid) { *resp = (uint8_t)dut->io_cpuIo_bresp; got = true; }
        advance();                                     // 完成本拍（含 B 握手，清 wSel/设备 bValid）
    }
    if (!got) { printf("  [FAIL] %s: B 超时（>%d 拍）\n", tag, CAP); nFail++; return false; }
    return true;
}

// ---------------- 观测辅助（打印 + 判定）----------------
static void expectU32(const char* what, uint32_t got, uint32_t exp) {
    printf("    %-46s got=0x%08X exp=0x%08X  %s\n", what, got, exp, got == exp ? "OK" : "MISMATCH");
    if (got != exp) fail(what);
}
static void expectInt(const char* what, int got, int exp) {
    printf("    %-46s got=%d exp=%d  %s\n", what, got, exp, got == exp ? "OK" : "MISMATCH");
    if (got != exp) fail(what);
}

// ===================== 判据 ① CLINT mtime 在走 =====================
static void case1_mtime() {
    printf("=== ① CLINT mtime 计数（读 +0xBFF8 两次，第二次必须更大）===\n");
    uint32_t t1 = 0, t2 = 0; uint8_t r1 = 0, r2 = 0; bool l1 = 0, l2 = 0;
    if (!opRead(CLINT_MTIME_LO, &t1, &r1, &l1, "mtime#1")) return;
    printf("   第一次读 mtime_lo = %u（rresp=%d）\n", t1, (int)r1);
    if (r1 != 0) fail("mtime 读 rresp != OKAY（CLINT 读窗没译码到？）");
    for (int i = 0; i < 500; ++i) { setCpuIoIdle(); tick(); }     // 隔 500 拍
    if (!opRead(CLINT_MTIME_LO, &t2, &r2, &l2, "mtime#2")) return;
    printf("   第二次读 mtime_lo = %u（rresp=%d），Δ=%u\n", t2, (int)r2, t2 - t1);
    if (r2 != 0) fail("mtime 第二次读 rresp != OKAY");
    if (!(t2 > t1)) fail("mtime 没有随时间增大（计数器/译码不对）");
}

// ===================== 判据 ② CLINT mtimecmp 回环 =====================
static void case2_mtimecmp() {
    printf("=== ② CLINT mtimecmp 回环（写 +0x4000/+0x4004，分半读回）===\n");
    const uint32_t LO = 0x11223344u, HI = 0xAABBCCDDu;
    uint8_t r = 0;
    if (!opWrite(CLINT_MTIMECMP_LO, LO, &r, "mtimecmp_lo 写")) return; expectInt("mtimecmp_lo 写 bresp", r, 0);
    if (!opWrite(CLINT_MTIMECMP_HI, HI, &r, "mtimecmp_hi 写")) return; expectInt("mtimecmp_hi 写 bresp", r, 0);
    uint32_t v0 = 0, v1 = 0; bool l = 0;
    if (!opRead(CLINT_MTIMECMP_LO, &v0, &r, &l, "mtimecmp_lo 读")) return;
    if (!opRead(CLINT_MTIMECMP_HI, &v1, &r, &l, "mtimecmp_hi 读")) return;
    expectU32("mtimecmp_lo 读回", v0, LO);
    expectU32("mtimecmp_hi 读回", v1, HI);
}

// ===================== 判据 ③ CLINT msip 回环 =====================
static void case3_msip() {
    printf("=== ③ CLINT msip 回环（写 +0x0000 bit0，读回 + io_intMSoft）===\n");
    uint8_t r = 0;
    if (!opWrite(CLINT_MSIP, 0x1u, &r, "msip 写")) return; expectInt("msip 写 bresp", r, 0);
    uint32_t v = 0; bool l = 0;
    if (!opRead(CLINT_MSIP, &v, &r, &l, "msip 读")) return;
    expectU32("msip 读回", v, 0x1u);
    setCpuIoIdle(); tick();
    expectInt("io_intMSoft 引脚", (int)dut->io_intMSoft, 1);
}

// ===================== 判据 ④ PLIC priority 回环 =====================
static void case4_plic_prio() {
    printf("=== ④ PLIC priority 回环（源 1 @+0x0004 / 源 2 @+0x0008）===\n");
    const uint32_t P1 = 0x7u, P2 = 0x3u;
    uint8_t r = 0; uint32_t v = 0; bool l = 0;
    if (!opWrite(PLIC_PRIO1, P1, &r, "plic prio1 写")) return; expectInt("plic prio1 写 bresp", r, 0);
    if (!opRead (PLIC_PRIO1, &v, &r, &l, "plic prio1 读")) return; expectU32("plic prio1 读回", v, P1);
    if (!opWrite(PLIC_PRIO2, P2, &r, "plic prio2 写")) return; expectInt("plic prio2 写 bresp", r, 0);
    if (!opRead (PLIC_PRIO2, &v, &r, &l, "plic prio2 读")) return; expectU32("plic prio2 读回", v, P2);
}

// ===================== 判据 ⑤ GPIO：看引脚 =====================
static void case5_gpio() {
    printf("=== ⑤ GPIO 数据/方向寄存器 → io_gpio_out / io_gpio_dir 引脚 ===\n");
    uint8_t r = 0;
    if (!opWrite(GPIO_DIRECTION, 0x0Fu, &r, "GPIO DIRECTION 写")) return;
    if (!opWrite(GPIO_DATA_OUT,  0xA5u, &r, "GPIO DATA_OUT 写 #1")) return;
    setCpuIoIdle(); tick();
    expectU32("io_gpio_out（图案 #1）", (uint32_t)dut->io_gpio_out, 0xA5u);
    expectU32("io_gpio_dir（图案 #1）", (uint32_t)dut->io_gpio_dir, 0x0Fu);
    // 换第二个图案：证明引脚真的跟着寄存器变（防"钉死"）
    if (!opWrite(GPIO_DATA_OUT, 0x5Au, &r, "GPIO DATA_OUT 写 #2")) return;
    setCpuIoIdle(); tick();
    expectU32("io_gpio_out（图案 #2）", (uint32_t)dut->io_gpio_out, 0x5Au);
    // 再读回寄存器本体
    uint32_t v = 0; bool l = 0;
    if (!opRead(GPIO_DATA_OUT, &v, &r, &l, "GPIO DATA_OUT 读")) return;
    expectU32("GPIO DATA_OUT 读回", v, 0x5Au);
}

// ===================== 判据 ⑥ Console LSR 空闲值 =====================
static void case6_console() {
    printf("=== ⑥ Console(ns16550a) LSR 空闲值（读 +0x14，期望 THRE|TEMT = 0x60）===\n");
    uint32_t v = 0; uint8_t r = 0; bool l = 0;
    if (!opRead(CONSOLE_LSR, &v, &r, &l, "console LSR 读")) return;
    printf("   LSR = 0x%02X（THRE=%d TEMT=%d DR=%d，rresp=%d）\n",
           v & 0xFF, (v >> 5) & 1, (v >> 6) & 1, v & 1, (int)r);
    expectInt("LSR 读 rresp", (int)r, 0);
    expectU32("LSR 空闲值", v, 0x60u);
}

// ===================== 判据 ⑦⑧ ETH 三窗 / VIDEO 窗 / 边界 / DECERR =====================
enum EthK { K_ETH = 0, K_LOCAL = 1, K_UNDEC = 2, K_VIDEO = 3, K_GPU = 4 };
struct EthCase { uint32_t addr; EthK kind; const char* name; };
static const char* kindName(EthK k) {
    switch (k) {
        case K_ETH:   return "ETH";
        case K_LOCAL: return "本地";
        case K_VIDEO: return "VIDEO";
        case K_GPU:   return "GPU";
        default:      return "未译码";
    }
}
static const EthCase kEthCases[] = {
    { ADDR_ETH_MAC,            K_ETH,   "ETH mac  基址 0xF0003000" },
    { ADDR_ETH_MAC  + 0x00Cu,  K_ETH,   "ETH mac  窗内 0xF000300C" },
    { ADDR_ETH_MDIO,           K_ETH,   "ETH mdio 基址 0xF0004000" },
    { ADDR_ETH_MDIO + 0x0008u, K_ETH,   "ETH mdio 窗内 0xF0004008" },
    { ADDR_ETH_BUF,            K_ETH,   "ETH buf  基址 0xF0008000" },
    { ADDR_ETH_BUF  + 0x1000u, K_ETH,   "ETH buf  窗内 0xF0009000" },
    { ADDR_ETH_BUF  + 0x1FFCu, K_ETH,   "ETH buf  窗尾 0xF0009FFC" },
    // ★ 2026-10-19 V1-T6：VIDEO 窗（0xF0007400，1 KiB）。两条都断言**窗内偏移**（0x000 / 0x010）。
    { ADDR_VIDEO,              K_VIDEO, "VIDEO 窗基址 0xF0007400（偏移 0x000）" },
    { ADDR_VIDEO + 0x010u,     K_VIDEO, "VIDEO BOX0 0xF0007410（偏移 0x010）" },
    // ★ 2026-10-31 GPU P1：CSR 窗 0xF0005000（4 KiB）。下游 gpu_csr 按**窗内偏移**译码 ⇒ 断言偏移。
    { ADDR_GPU,                K_GPU,   "GPU 窗基址 0xF0005000（偏移 0x000，GPU_ID）" },
    { ADDR_GPU + 0x02Cu,       K_GPU,   "GPU DBG 0xF000502C（偏移 0x02C）" },
    { ADDR_ETH_MAC  + 0x0100u, K_UNDEC, "边界 0xF0003100（mac 窗后 256B）" },
    // ★ 2026-10-31：GPU 窗占了 0x5000–0x5FFF。原先的“空段”探针 0xF0005000 改成紧跟 DMA 窗之后的
    //    0xF0006100（DMA 窗 0x6000–0x60FF，掩码 0xFFFF_FF00）⇒ 仍在**所有**窗之外。
    //    注意别用 0xF000A000 —— 它在 ETH buf 窗（0x8000–0xBFFF，掩码 0xFFFF_C000）**里面**。
    { 0xF0006100u,             K_UNDEC, "边界 0xF0006100（GPU 0x5FFF / DMA 0x60FF 之后的空段）" },
    // ⚠️ 2026-10-09 适配（装置比 RTL 老）：`ETH_BUF_MASK` 已从 0xFFFF_E000 加宽到 0xFFFF_C000
    //    （rx 槽 2→4，见 YeshenMap 注释）⇒ buf 窗现在是 0x8000–0xBFFF，原来这条“buf 窗后 0xF000A000”
    //    已经**落进窗内**（不再是“未译码”）。改用一个**仍为空段**的地址 0xF0007000（0x5000–0x7FFF 空闲），
    //    保住“窗外地址必须不外发/不被译码”的原意。仅此一行；其余判据（console/CLINT/PLIC/GPIO）不动。
    // ★ 2026-10-19 V1-T6：VIDEO 窗取 0x7400–0x77FF（掩码 0xFFFF_FC00）⇒ 这位仍然**在窗外**，
    //    探针原意不变；本轮额外断言它不会误发 io_videoAxi_*valid。
    { 0xF0007000u,             K_UNDEC, "边界 0xF0007000（buf 窗前的空段）" },
    { ADDR_UNDEC,              K_UNDEC, "未译码 0xF0100000" },
    { CONSOLE_LSR,             K_LOCAL, "console LSR 0xF0001014" },
    { ADDR_GPIO,               K_LOCAL, "GPIO DATA_IN 0xF0002000" },
    { CLINT_MTIME_LO,          K_LOCAL, "CLINT mtime 0xF001BFF8" },
    { PLIC_PRIO2,              K_LOCAL, "PLIC prio2 0xF0C00008" },
};
static const int kNumEthCases = (int)(sizeof(kEthCases) / sizeof(kEthCases[0]));

static void case7_eth_and_undec() {
    printf("=== ⑦④ ETH 三窗 / VIDEO 窗转发 / 非本窗不外发；⑧ 未译码 DECERR ===\n");
    for (int i = 0; i < kNumEthCases; ++i) {
        const EthCase& c = kEthCases[i];
        const char* kn = kindName(c.kind);
        printf("  -- [%s] %s --\n", kn, c.name);
        const uint32_t winOff = c.addr & 0x3FFu;   // VIDEO 1 KiB 窗内偏移（其余窗不看这一项）

        // ---- 读 ----
        ethMonReset(); vidMonReset(); gpuMonReset();
        uint32_t d = 0; uint8_t r = 0; bool l = 0;
        if (opRead(c.addr, &d, &r, &l, c.name)) {
            uint8_t expResp = (c.kind == K_UNDEC) ? 3 : 0;
            printf("     读: ethAxi_arvalid=%d araddr=0x%08X | videoAxi_arvalid=%d araddr=0x%03X | "
                   "gpuAxi_arvalid=%d araddr=0x%03X | rresp=%d rdata=0x%08X rlast=%d\n",
                   g_ethArSeen, g_ethArAddr, g_vidArSeen, g_vidArAddr,
                   g_gpuArSeen, g_gpuArAddr, (int)r, d, (int)l);
            if (c.kind != K_GPU && g_gpuArSeen != 0) fail("非 GPU 窗读外发了 io_gpuAxi_arvalid");
            if (c.kind == K_ETH) {
                if (g_ethArSeen == 0)      fail("ETH 窗读没有外发 io_ethAxi_arvalid");
                if (g_ethArAddr != c.addr) fail("io_ethAxi_araddr != 读出的地址");
                if (g_vidArSeen != 0)      fail("ETH 窗读误发 io_videoAxi_arvalid");
            } else if (c.kind == K_VIDEO) {
                if (g_ethArSeen != 0)      fail("VIDEO 窗读误发 io_ethAxi_arvalid");
                if (g_vidArSeen == 0)      fail("VIDEO 窗读没有外发 io_videoAxi_arvalid");
                if (g_vidArAddr != winOff) fail("io_videoAxi_araddr != 窗内偏移（应给偏移，不是整根 SoC 地址）");
                expectU32("VIDEO 窗读回（从方恒定图案）", d, VIDEO_RDATA);
            } else if (c.kind == K_GPU) {
                if (g_ethArSeen != 0)       fail("GPU 窗读误发 io_ethAxi_arvalid");
                if (g_vidArSeen != 0)       fail("GPU 窗读误发 io_videoAxi_arvalid");
                if (g_gpuArSeen == 0)       fail("GPU 窗读没有外发 io_gpuAxi_arvalid");
                if (g_gpuArAddr != winOff)  fail("io_gpuAxi_araddr != 窗内偏移（应给偏移，不是整根 SoC 地址）");
                expectU32("GPU 窗读回（从方恒定图案）", d, GPU_RDATA);
            } else {
                if (g_ethArSeen != 0)      fail("非 ETH 窗读外发了 io_ethAxi_arvalid");
                if (g_vidArSeen != 0)      fail("非 VIDEO 窗读外发了 io_videoAxi_arvalid");
            }
            if (r != expResp)              fail("读 rresp 不符合（本窗 OKAY / 未译码 DECERR）");
            if (c.kind == K_ETH && !l)     fail("ETH 窗读 rlast 未在单拍上置起");
        }

        // ---- 写 ----
        ethMonReset(); vidMonReset(); gpuMonReset();
        uint8_t wr = 0;
        if (opWrite(c.addr, 0x12345678u, &wr, c.name)) {
            uint8_t expResp = (c.kind == K_UNDEC) ? 3 : 0;
            printf("     写: ethAxi_awvalid=%d awaddr=0x%08X | videoAxi_awvalid=%d awaddr=0x%03X | "
                   "gpuAxi_awvalid=%d awaddr=0x%03X | bresp=%d\n",
                   g_ethAwSeen, g_ethAwAddr, g_vidAwSeen, g_vidAwAddr,
                   g_gpuAwSeen, g_gpuAwAddr, (int)wr);
            if (c.kind != K_GPU && g_gpuAwSeen != 0) fail("非 GPU 窗写外发了 io_gpuAxi_awvalid");
            if (c.kind == K_ETH) {
                if (g_ethAwSeen == 0)      fail("ETH 窗写没有外发 io_ethAxi_awvalid");
                if (g_ethAwAddr != c.addr) fail("io_ethAxi_awaddr != 写出的地址");
                if (g_vidAwSeen != 0)      fail("ETH 窗写误发 io_videoAxi_awvalid");
            } else if (c.kind == K_VIDEO) {
                if (g_ethAwSeen != 0)      fail("VIDEO 窗写误发 io_ethAxi_awvalid");
                if (g_vidAwSeen == 0)      fail("VIDEO 窗写没有外发 io_videoAxi_awvalid");
                if (g_vidAwAddr != winOff) fail("io_videoAxi_awaddr != 窗内偏移（应给偏移，不是整根 SoC 地址）");
            } else if (c.kind == K_GPU) {
                if (g_ethAwSeen != 0)      fail("GPU 窗写误发 io_ethAxi_awvalid");
                if (g_vidAwSeen != 0)      fail("GPU 窗写误发 io_videoAxi_awvalid");
                if (g_gpuAwSeen == 0)      fail("GPU 窗写没有外发 io_gpuAxi_awvalid");
                if (g_gpuAwAddr != winOff) fail("io_gpuAxi_awaddr != 窗内偏移（应给偏移，不是整根 SoC 地址）");
            } else {
                if (g_ethAwSeen != 0)      fail("非 ETH 窗写外发了 io_ethAxi_awvalid");
                if (g_vidAwSeen != 0)      fail("非 VIDEO 窗写外发了 io_videoAxi_awvalid");
            }
            if (wr != expResp)             fail("写 bresp 不符合（本窗 OKAY / 未译码 DECERR）");
        }
    }
}

// 判据 ⑧ 单独再打一遍原始 rresp/bresp（与窗口表里的检查同源，便于现场一眼看到 2'b11）
static void case8_decerr_explicit() {
    printf("=== ⑧ DECERR 原始应答（地址 0xF0100000）===\n");
    uint32_t d = 0; uint8_t r = 0; bool l = 0;
    if (opRead(ADDR_UNDEC, &d, &r, &l, "DECERR 读")) {
        printf("   读  rresp=%d rdata=0x%08X（期望 rresp=3 DECERR, rdata=0）\n", (int)r, d);
        expectInt("未译码读 rresp", (int)r, 3);
        expectU32("未译码读 rdata", d, 0u);
    }
    uint8_t wr = 0;
    if (opWrite(ADDR_UNDEC, 0xDEADBEEFu, &wr, "DECERR 写")) {
        printf("   写  bresp=%d（期望 3 DECERR）\n", (int)wr);
        expectInt("未译码写 bresp", (int)wr, 3);
    }
}

// ===================== 初始化 + 复位 =====================
static void initDut() {
    dut->clock = 0; dut->reset = 1;
    // 静默可能干扰的输入
    dut->io_loadMode = 0; dut->io_bootTimeout = 100000000;
    dut->io_uart_rxd = 1;
    dut->io_sd_miso  = 1;
    dut->io_ethIrq   = 0;
    dut->io_gpio_in  = 0;
    // 两条 CPU 内存主口：不发起
    dut->io_cpuFetch_arvalid = 0; dut->io_cpuFetch_araddr = 0; dut->io_cpuFetch_arlen = 0;
    dut->io_cpuFetch_arsize = 0; dut->io_cpuFetch_arburst = 1; dut->io_cpuFetch_arcache = 0;
    dut->io_cpuFetch_arprot = 0; dut->io_cpuFetch_rready = 0;
    dut->io_cpuLsu_awvalid = 0; dut->io_cpuLsu_awaddr = 0; dut->io_cpuLsu_awlen = 0;
    dut->io_cpuLsu_awsize = 0; dut->io_cpuLsu_awburst = 1; dut->io_cpuLsu_awcache = 0; dut->io_cpuLsu_awprot = 0;
    dut->io_cpuLsu_wvalid = 0; dut->io_cpuLsu_wdata = 0; dut->io_cpuLsu_wstrb = 0; dut->io_cpuLsu_wlast = 0;
    dut->io_cpuLsu_bready = 0;
    dut->io_cpuLsu_arvalid = 0; dut->io_cpuLsu_araddr = 0; dut->io_cpuLsu_arlen = 0;
    dut->io_cpuLsu_arsize = 0; dut->io_cpuLsu_arburst = 1; dut->io_cpuLsu_arcache = 0; dut->io_cpuLsu_arprot = 0;
    dut->io_cpuLsu_rready = 0;
    // cpuIo 主口（本装置驱动）
    setCpuIoIdle();
    // io_mem_* 从方（永远 ready + 单拍 OKAY），只为防挂死
    dut->io_mem_ar_arready = 1;
    dut->io_mem_aw_awready = 1; dut->io_mem_w_wready = 1;
    dut->io_mem_r_rid = 0; dut->io_mem_r_rdata = 0; dut->io_mem_r_rresp = 0;
    dut->io_mem_r_rlast = 1; dut->io_mem_r_rvalid = 0;
    dut->io_mem_b_bid = 0; dut->io_mem_b_bresp = 0; dut->io_mem_b_bvalid = 0;
    // io_ethAxi 从方（永远 ready + 单拍 OKAY）
    dut->io_ethAxi_awready = 1; dut->io_ethAxi_wready = 1;
    dut->io_ethAxi_bvalid = 0;  dut->io_ethAxi_bresp = 0;
    dut->io_ethAxi_arready = 1; dut->io_ethAxi_rvalid = 0;
    dut->io_ethAxi_rdata = 0;   dut->io_ethAxi_rresp = 0;
    // io_videoAxi 从方（永远 ready + 单拍 OKAY；读数据恒定图案）——VIDEO 窗的活体证明
    dut->io_videoAxi_awready = 1; dut->io_videoAxi_wready = 1;
    dut->io_videoAxi_bvalid = 0;  dut->io_videoAxi_bresp = 0;
    dut->io_videoAxi_arready = 1; dut->io_videoAxi_rvalid = 0;
    dut->io_videoAxi_rdata = VIDEO_RDATA; dut->io_videoAxi_rresp = 0;
    // io_gpuAxi 从方（永远 ready + 单拍 OKAY；读数据恒定图案）——GPU 窗的活体证明
    dut->io_gpuAxi_awready = 1; dut->io_gpuAxi_wready = 1;
    dut->io_gpuAxi_bvalid = 0;  dut->io_gpuAxi_bresp = 0;
    dut->io_gpuAxi_arready = 1; dut->io_gpuAxi_rvalid = 0;
    dut->io_gpuAxi_rdata = GPU_RDATA; dut->io_gpuAxi_rresp = 0;
    // io_gpuMem 从方（GPU 的 DDR 主口）：本装置里 GPU 只做 CSR 读写，不该有内存事务 ⇒ 给足 ready 防挂死
    dut->io_gpuMem_awready = 1; dut->io_gpuMem_wready = 1;
    dut->io_gpuMem_bvalid = 0;  dut->io_gpuMem_bresp = 0;
    dut->io_gpuMem_arready = 1; dut->io_gpuMem_rvalid = 0;
    dut->io_gpuMem_rdata = 0;   dut->io_gpuMem_rresp = 0; dut->io_gpuMem_rlast = 0;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new VYeshenSocGlue;
    initDut();

    for (int i = 0; i < 8; ++i) tick();      // 复位保持若干拍
    dut->reset = 0;
    for (int i = 0; i < 4; ++i) tick();      // 复位撤离后再跑几拍

    printf("YeshenSocGlue 外设总线译码单元装置（--top-module YeshenSocGlue）\n");
    printf("窗口：console 0x%08X / GPIO 0x%08X / ETH mac 0x%08X / mdio 0x%08X / buf 0x%08X / "
           "GPU 0x%08X / CLINT 0x%08X / PLIC 0x%08X / VIDEO 0x%08X\n",
           ADDR_CONSOLE, ADDR_GPIO, ADDR_ETH_MAC, ADDR_ETH_MDIO, ADDR_ETH_BUF, ADDR_GPU,
           ADDR_CLINT, ADDR_PLIC, ADDR_VIDEO);

    case1_mtime();
    case2_mtimecmp();
    case3_msip();
    case4_plic_prio();
    case5_gpio();
    case6_console();
    case7_eth_and_undec();
    case8_decerr_explicit();

    // ---- 装置自检：内存从方从未被用到（io_loadMode=0 且两条内存主口不发起）----
    printf("=== 装置自检：io_mem_* 事务计数（期望全 0，证明判据不依赖内存从方）===\n");
    printf("   io_mem: ar=%d aw=%d w=%d | io_ethAxi: ar=%d aw=%d w=%d | io_videoAxi: ar=%d aw=%d w=%d | "
           "io_gpuAxi: ar=%d aw=%d w=%d\n",
           g_memAr, g_memAw, g_memW, g_ethArFire, g_ethAwFire, g_ethWFire,
           g_vidArFire, g_vidAwFire, g_vidWFire, g_gpuArFire, g_gpuAwFire, g_gpuWFire);
    expectInt("io_mem AR 事务数", g_memAr, 0);
    expectInt("io_mem AW 事务数", g_memAw, 0);
    expectInt("io_mem W  事务数", g_memW, 0);
    // VIDEO 自检：两条读 + 两条写都必须真的走过 videoAxi 这根口（否则上面的 offset 判据是空的）
    expectInt("io_videoAxi AR 事务数（★窗口表跑到 video 才非 0）", g_vidArFire >= 2 ? 1 : 0, 1);
    expectInt("io_videoAxi AW 事务数", g_vidAwFire >= 2 ? 1 : 0, 1);
    expectInt("io_videoAxi W  事务数", g_vidWFire  >= 2 ? 1 : 0, 1);
    // GPU 自检：两条读 + 两条写都必须真的走过 gpuAxi 这根口
    expectInt("io_gpuAxi AR 事务数（★窗口表跑到 GPU 才非 0）", g_gpuArFire >= 2 ? 1 : 0, 1);
    expectInt("io_gpuAxi AW 事务数", g_gpuAwFire >= 2 ? 1 : 0, 1);
    expectInt("io_gpuAxi W  事务数", g_gpuWFire  >= 2 ? 1 : 0, 1);

    bool pass = (nFail == 0);
    printf("cyc=%llu  fail=%d\n", (unsigned long long)cyc, nFail);
    printf("=== %s ===\n", pass ? "TEST PASSED" : "TEST FAILED");
    dut->final();
    delete dut;
    return pass ? 0 : 1;
}
