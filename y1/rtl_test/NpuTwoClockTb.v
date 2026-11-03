// =============================================================================
// NpuTwoClockTb.v —— N1「两时钟装置」→ **N5b 集成后转绿**。
//
// 任务：给 **glue + NpuTop 区域**拉**两根独立时钟**：
//   · cpu_clk ≈ 100 MHz     —— 驱动 YeshenSocGlue（pBus 译码/汇聚）+ AxiMemModel；
//   · npu_clk  =  37 MHz    —— **非整数比**（100/37 = 2.7027…）驱动 NpuTop，故意打破任何"恰好对齐"。
//
// ★★ N5b：本 TB 现在**与板级**同拓扑地接入 N3/N4/N5 的三座异步桥 + NpuResetSync
//   （板级见 `board/yeshen_mini_soc.v` 文件头【11】）：
//       glue.io_npuAxi_*  → `NpuAxiLiteCdc` cpu 从口 ；桥 npu 主口 → NpuTop.axilite_*
//       NpuTop.axi_*      → `NpuMemCdc`   npu 从口 ；桥 cpu 主口 → glue.io_npuMem_*
//       NpuTop.irq        → `NpuIrqCdc` 2-FF → glue.io_npuIrq
//       `NpuResetSync`    → cpu 域/npu 域低有效复位（**cpu 先、npu 后**）；NpuTop.clk = **npu_clk**
//   ⇒ N1 的"先红基线"（无 CDC 时异频必红）**已被 N5b 的集成解掉**：同一激励在异频下
//     主窗/内存口/IRQ 都逐字节对 ⇒ **GREEN**。单时钟（+SAME_CLK）仍是正对照（同一激励必须全绿）。
//
// 基线复用（不重造）：
//   · `sim/glue_pbus/pbus_npu_top.v`（＋`tb_npu_pbus.cpp`）—— glue 的 NPU 寄存器窗装置：
//       本 TB 的 `YeshenSocGlue u_glue(...)` 端口表**逐条照抄**它（含全部静默 tie-off）。
//   · `y1/rtl_test/NpuTopTb.v` + `y1/tools/run_nputop_ab.sh` —— 主机编程 → NPU 端到端块拷贝的
//       激励与判据：本 TB 的 AxiLite 主机 task（axi_write/axi_read/poll_status）与寄存器偏移口径
//       逐段复用它；字节级黄金由 tools/run_twoclock_ab.sh 的 python 独立算。
//
// 与板级接线的等价物（`board/yeshen_mini_soc.v`）：
//   glue.io_npuAxi_*  ↔ NpuAxiLiteCdc ↔ NpuTop.axilite_*   （寄存器窗，0xF000_C000 / 16 KiB）
//   NpuTop.axi_*      ↔ NpuMemCdc   ↔ glue.io_npuMem_*     （内存主口，汇入 glue §3.5 汇聚点）
//   glue.io_mem_*     ↔ AxiMemModel                        （汇聚点下游的 DDR 从口；本装置只在 CPU 域）
//   **唯一与板级的差别**：本 TB 无板级 loader（`cpu_reset` 恒 0）、引脚/PHY 用不着（静默）。
//
// ★ 时钟：两根都从 t=0 起振、无随机；+SAME_CLK 时 npu_clk 直接并到 cpu_clk
//   ⇒ 单时钟是"正对照"（同一激励必须逐字节对、全绿），**两时钟在集成后也全绿**（= N5b 的 GREEN）。
//
// plusargs：
//   +SRC= +DST= +IMG_W= +IMG_H= +C_IN=（十进制，沿用 run_nputop_ab.sh 口径）
//   +MEMFILE= +DUMPFILE= +dump       （转给 AxiMemModel，它自己取）
//   +SAME_CLK                        （可选：把 npu_clk 并到 cpu_clk ⇒ 正对照）
// 输出事实行：CLKCFG / ID_READ / RB_OK / DONE_SEEN / ERR_SEEN / STATUS_* / PRE|POST_IRQ /
//   IRQ_HELD_AFTER_50 / IRQ_AFTER_ACK / RESULT: PASS|FAIL
// 采样口径（与 NpuTopTb 同）：所有主机驱动在 negedge，所有握手判据在 posedge 采样。
// =============================================================================
`timescale 1ns/1ps

module NpuTwoClockTb;

  // ---- NPU 寄存器窗基址（与 YeshenSocGlue.scala 的 NPU_BASE 同；glue 内部会剥到 14bit 窗内偏移）----
  localparam [31:0] NPU_BASE = 32'hF000C000;
  localparam [31:0] ID_CONST = 32'h594E5031;   // "YNP1"（HostRegs 活体常数）

  localparam integer TIMEOUT   = 500000;         // 轮询 STATUS 的次数上限（N5b：桥是"单拍一手握"CDC，
                                                 //   整块拷贝比直连慢 ~4x ⇒ 轮询次数上限相应放大）
  localparam integer SIM_LIMIT = 30000000;       // 全局看门狗（ns = 30 ms）：N5b 后整块 128 KiB 拷贝
                                                 //   经 beat-serialized 两座桥约需 8~13 ms（直连约 2 ms）

  // ===========================================================================
  // 两根独立时钟 + 可选的"并钟"开关
  // ===========================================================================
  reg cpu_clk  = 1'b0;
  always #5.0 cpu_clk = ~cpu_clk;              // 周期 10.0 ns  ⇒ 100   MHz

  reg npu_clk_i = 1'b0;
  always #13.514 npu_clk_i = ~npu_clk_i;       // 周期 27.028 ns ⇒ 37.0 MHz（非 100 的整数分频）

  reg same_clk = 1'b0;                          // +SAME_CLK ⇒ 1（正对照：npu_clk 并到 cpu_clk）
  wire npu_clk = same_clk ? cpu_clk : npu_clk_i;

  reg reset = 1'b1;                             // 高有效；两域同源（复位跨域是 N5 的活）

  // ===========================================================================
  // 主机侧（CPU 域）AxiLite4 主方：驱动 glue.io_cpuIo_*
  // ===========================================================================
  reg         p_awvalid;  wire        p_awready;
  reg  [31:0] p_awaddr;   reg  [2:0]  p_awprot;
  reg         p_wvalid;   wire        p_wready;
  reg  [31:0] p_wdata;    reg  [3:0]  p_wstrb;   reg p_wlast;
  wire        p_bvalid;   reg         p_bready;   wire [1:0] p_bresp;
  reg         p_arvalid;  wire        p_arready;
  reg  [31:0] p_araddr;   reg  [2:0]  p_arprot;
  wire        p_rvalid;   reg         p_rready;   wire [31:0] p_rdata;  wire [1:0] p_rresp;
  wire        p_rlast;

  // ===========================================================================
  // glue ↔ NpuAxiLiteCdc（cpu 侧从口）——`npuAxi_*`（板级同名）
  // ===========================================================================
  wire        npuAxi_awvalid, npuAxi_awready;
  wire [31:0] npuAxi_awaddr;
  wire [2:0]  npuAxi_awprot;
  wire        npuAxi_wvalid, npuAxi_wready;
  wire [31:0] npuAxi_wdata;
  wire [3:0]  npuAxi_wstrb;
  wire        npuAxi_bvalid, npuAxi_bready;
  wire [1:0]  npuAxi_bresp;
  wire        npuAxi_arvalid, npuAxi_arready;
  wire [31:0] npuAxi_araddr;
  wire [2:0]  npuAxi_arprot;
  wire        npuAxi_rvalid, npuAxi_rready;
  wire [31:0] npuAxi_rdata;
  wire [1:0]  npuAxi_rresp;
  // ===========================================================================
  // NpuAxiLiteCdc（npu 侧主口）↔ NpuTop.axilite_*  —— `npuAxi2_*`
  // ===========================================================================
  wire        npuAxi2_awvalid, npuAxi2_awready;
  wire [31:0] npuAxi2_awaddr;
  wire [2:0]  npuAxi2_awprot;
  wire        npuAxi2_wvalid, npuAxi2_wready;
  wire [31:0] npuAxi2_wdata;
  wire [3:0]  npuAxi2_wstrb;
  wire        npuAxi2_bvalid, npuAxi2_bready;
  wire [1:0]  npuAxi2_bresp;
  wire        npuAxi2_arvalid, npuAxi2_arready;
  wire [31:0] npuAxi2_araddr;
  wire [2:0]  npuAxi2_arprot;
  wire        npuAxi2_rvalid, npuAxi2_rready;
  wire [31:0] npuAxi2_rdata;
  wire [1:0]  npuAxi2_rresp;

  // ===========================================================================
  // NpuMemCdc（cpu 侧主口）↔ glue.io_npuMem_*：内存主口（AXI4，64bit/28bit/4bit）—— `npuMem_*`
  // ===========================================================================
  wire        npuMem_awvalid, npuMem_awready;
  wire [27:0] npuMem_awaddr;
  wire [3:0]  npuMem_awid;
  wire [7:0]  npuMem_awlen;
  wire [2:0]  npuMem_awsize;
  wire [1:0]  npuMem_awburst;
  wire [3:0]  npuMem_awcache;
  wire [2:0]  npuMem_awprot;
  wire        npuMem_wvalid, npuMem_wready;
  wire [63:0] npuMem_wdata;
  wire [7:0]  npuMem_wstrb;
  wire        npuMem_wlast;
  wire        npuMem_bvalid, npuMem_bready;
  wire [3:0]  npuMem_bid;
  wire [1:0]  npuMem_bresp;
  wire        npuMem_arvalid, npuMem_arready;
  wire [27:0] npuMem_araddr;
  wire [3:0]  npuMem_arid;
  wire [7:0]  npuMem_arlen;
  wire [2:0]  npuMem_arsize;
  wire [1:0]  npuMem_arburst;
  wire [3:0]  npuMem_arcache;
  wire [2:0]  npuMem_arprot;
  wire        npuMem_rvalid, npuMem_rready;
  wire [63:0] npuMem_rdata;
  wire [3:0]  npuMem_rid;
  wire [1:0]  npuMem_rresp;
  wire        npuMem_rlast;

  // ===========================================================================
  // npu 侧：NpuTop.axi_* ↔ NpuMemCdc.npuMem_* —— `npuMem2_*`
  // ===========================================================================
  wire        npuMem2_awvalid, npuMem2_awready;
  wire [27:0] npuMem2_awaddr;
  wire [3:0]  npuMem2_awid;
  wire [7:0]  npuMem2_awlen;
  wire [2:0]  npuMem2_awsize;
  wire [1:0]  npuMem2_awburst;
  wire [3:0]  npuMem2_awcache;
  wire [2:0]  npuMem2_awprot;
  wire        npuMem2_wvalid, npuMem2_wready;
  wire [63:0] npuMem2_wdata;
  wire [7:0]  npuMem2_wstrb;
  wire        npuMem2_wlast;
  wire        npuMem2_bvalid, npuMem2_bready;
  wire [3:0]  npuMem2_bid;
  wire [1:0]  npuMem2_bresp;
  wire        npuMem2_arvalid, npuMem2_arready;
  wire [27:0] npuMem2_araddr;
  wire [3:0]  npuMem2_arid;
  wire [7:0]  npuMem2_arlen;
  wire [2:0]  npuMem2_arsize;
  wire [1:0]  npuMem2_arburst;
  wire [3:0]  npuMem2_arcache;
  wire [2:0]  npuMem2_arprot;
  wire        npuMem2_rvalid, npuMem2_rready;
  wire [63:0] npuMem2_rdata;
  wire [3:0]  npuMem2_rid;
  wire [1:0]  npuMem2_rresp;
  wire        npuMem2_rlast;

  wire        npu_irq;        // NpuTop.irq（npu_clk 域电平保持）—— 也被观测
  wire        npu_irq_cpu;    // NpuIrqCdc 同步到 cpu 域后 → glue.io_npuIrq（PLIC 源 3）
  wire        cpu_rstn;       // NpuResetSync：cpu 域低有效复位
  wire        npu_rstn;       // NpuResetSync：npu 域低有效复位（**晚于 cpu**）
  wire        npu_reset;      // = ~npu_rstn（NpuTop 的同步、高有效复位）

  // ===========================================================================
  // glue ↔ AxiMemModel：CPU 域内存从口（glue.io_mem_*；板级接 DDR3Bridge）
  // ===========================================================================
  wire [3:0]  io_mem_ar_arid;
  wire [31:0] io_mem_ar_araddr;
  wire [7:0]  io_mem_ar_arlen;
  wire [2:0]  io_mem_ar_arsize;
  wire [1:0]  io_mem_ar_arburst;
  wire [2:0]  io_mem_ar_arlock;     // 模型无 lock ⇒ 悬空
  wire [3:0]  io_mem_ar_arcache;
  wire [2:0]  io_mem_ar_arprot;
  wire        io_mem_ar_arvalid, io_mem_ar_arready;
  wire [3:0]  io_mem_r_rid;
  wire [63:0] io_mem_r_rdata;
  wire [1:0]  io_mem_r_rresp;
  wire        io_mem_r_rlast, io_mem_r_rvalid, io_mem_r_rready;
  wire [3:0]  io_mem_aw_awid;
  wire [31:0] io_mem_aw_awaddr;
  wire [7:0]  io_mem_aw_awlen;
  wire [2:0]  io_mem_aw_awsize;
  wire [1:0]  io_mem_aw_awburst;
  wire [3:0]  io_mem_aw_awcache;
  wire [2:0]  io_mem_aw_awprot;
  wire        io_mem_aw_awvalid, io_mem_aw_awready;
  wire [3:0]  io_mem_w_wid;
  wire [63:0] io_mem_w_wdata;
  wire [7:0]  io_mem_w_wstrb;
  wire        io_mem_w_wlast, io_mem_w_wvalid, io_mem_w_wready;
  wire [3:0]  io_mem_b_bid;
  wire [1:0]  io_mem_b_bresp;
  wire        io_mem_b_bvalid, io_mem_b_bready;

  // ===========================================================================
  // 被观测/被丢弃的 glue 输出（与原装置逐条一致，只是本 TB 不驱动它们）
  // ===========================================================================
  wire [63:0] glue_rdtime;
  wire        glue_intMTime, glue_intMSoft, glue_intMExt, glue_intSExt;
  wire        glue_irq, glue_uart_txd;
  wire        glue_loadActive, glue_cpuReset;
  wire        glue_sd_sck, glue_sd_mosi, glue_sd_cs_n;
  wire [3:0]  glue_sd_state, glue_sd_err;
  wire [31:0] glue_sd_dbg, glue_sd_dbg2;
  wire        glue_cpuFetch_arready, glue_cpuFetch_rvalid;
  wire [63:0] glue_cpuFetch_rdata;
  wire [1:0]  glue_cpuFetch_rresp;
  wire        glue_cpuFetch_rlast;
  wire        glue_cpuLsu_awready, glue_cpuLsu_wready, glue_cpuLsu_bvalid, glue_cpuLsu_arready;
  wire        glue_cpuLsu_rvalid;
  wire [63:0] glue_cpuLsu_rdata;
  wire [1:0]  glue_cpuLsu_rresp;
  wire        glue_cpuLsu_rlast;
  wire [7:0]  glue_gpio_out, glue_gpio_dir;

  // ===========================================================================
  // DUT①：YeshenSocGlue（原网表，只读；端口表照抄 sim/glue_pbus/pbus_npu_top.v）
  //   时钟 = cpu_clk（100 MHz）
  // ===========================================================================
  YeshenSocGlue u_glue(
    .clock(cpu_clk),
    .reset(reset),

    // CPU 内存主口（本装置不发起，静默）
    .io_cpuFetch_arvalid(1'b0), .io_cpuFetch_arready(glue_cpuFetch_arready),
    .io_cpuFetch_araddr(32'h0), .io_cpuFetch_arlen(8'h0), .io_cpuFetch_arsize(3'h0),
    .io_cpuFetch_arburst(2'h1), .io_cpuFetch_arcache(4'h0), .io_cpuFetch_arprot(3'h0),
    .io_cpuFetch_rvalid(glue_cpuFetch_rvalid), .io_cpuFetch_rready(1'b0),
    .io_cpuFetch_rdata(glue_cpuFetch_rdata), .io_cpuFetch_rresp(glue_cpuFetch_rresp),
    .io_cpuFetch_rlast(glue_cpuFetch_rlast),

    .io_cpuLsu_awvalid(1'b0), .io_cpuLsu_awready(glue_cpuLsu_awready),
    .io_cpuLsu_awaddr(32'h0), .io_cpuLsu_awlen(8'h0), .io_cpuLsu_awsize(3'h0),
    .io_cpuLsu_awburst(2'h1), .io_cpuLsu_awcache(4'h0), .io_cpuLsu_awprot(3'h0),
    .io_cpuLsu_wvalid(1'b0), .io_cpuLsu_wready(glue_cpuLsu_wready),
    .io_cpuLsu_wdata(64'h0), .io_cpuLsu_wstrb(8'h0), .io_cpuLsu_wlast(1'b0),
    .io_cpuLsu_bvalid(glue_cpuLsu_bvalid), .io_cpuLsu_bready(1'b0), .io_cpuLsu_bresp(),
    .io_cpuLsu_arvalid(1'b0), .io_cpuLsu_arready(glue_cpuLsu_arready),
    .io_cpuLsu_araddr(32'h0), .io_cpuLsu_arlen(8'h0), .io_cpuLsu_arsize(3'h0),
    .io_cpuLsu_arburst(2'h1), .io_cpuLsu_arcache(4'h0), .io_cpuLsu_arprot(3'h0),
    .io_cpuLsu_rvalid(glue_cpuLsu_rvalid), .io_cpuLsu_rready(1'b0),
    .io_cpuLsu_rdata(glue_cpuLsu_rdata), .io_cpuLsu_rresp(glue_cpuLsu_rresp),
    .io_cpuLsu_rlast(glue_cpuLsu_rlast),

    // CPU 外设主口（本装置驱动 = "CPU 那样的 pBus 主方"）
    .io_cpuIo_awvalid(p_awvalid), .io_cpuIo_awready(p_awready),
    .io_cpuIo_awaddr(p_awaddr), .io_cpuIo_awsize(3'h2),
    .io_cpuIo_awcache(4'h0), .io_cpuIo_awprot(p_awprot),
    .io_cpuIo_wvalid(p_wvalid), .io_cpuIo_wready(p_wready),
    .io_cpuIo_wdata(p_wdata), .io_cpuIo_wstrb(p_wstrb), .io_cpuIo_wlast(p_wlast),
    .io_cpuIo_bvalid(p_bvalid), .io_cpuIo_bready(p_bready), .io_cpuIo_bresp(p_bresp),
    .io_cpuIo_arvalid(p_arvalid), .io_cpuIo_arready(p_arready),
    .io_cpuIo_araddr(p_araddr), .io_cpuIo_arsize(3'h2),
    .io_cpuIo_arcache(4'h0), .io_cpuIo_arprot(p_arprot),
    .io_cpuIo_rvalid(p_rvalid), .io_cpuIo_rready(p_rready),
    .io_cpuIo_rdata(p_rdata), .io_cpuIo_rresp(p_rresp), .io_cpuIo_rlast(p_rlast),

    .io_rdtime(glue_rdtime),
    .io_intMTime(glue_intMTime), .io_intMSoft(glue_intMSoft),
    .io_intMExt(glue_intMExt), .io_intSExt(glue_intSExt),

    .io_ethIrq(1'b0),
    .io_npuIrq(npu_irq_cpu),

    // NPU 内存主口（本装置由 NpuTop 驱动；板级等价）
    .io_npuMem_awvalid(npuMem_awvalid), .io_npuMem_awready(npuMem_awready),
    .io_npuMem_awaddr(npuMem_awaddr), .io_npuMem_awid(npuMem_awid),
    .io_npuMem_awlen(npuMem_awlen), .io_npuMem_awsize(npuMem_awsize),
    .io_npuMem_awburst(npuMem_awburst), .io_npuMem_awcache(npuMem_awcache),
    .io_npuMem_awprot(npuMem_awprot),
    .io_npuMem_wvalid(npuMem_wvalid), .io_npuMem_wready(npuMem_wready),
    .io_npuMem_wdata(npuMem_wdata), .io_npuMem_wstrb(npuMem_wstrb),
    .io_npuMem_wlast(npuMem_wlast),
    .io_npuMem_bvalid(npuMem_bvalid), .io_npuMem_bready(npuMem_bready),
    .io_npuMem_bid(npuMem_bid), .io_npuMem_bresp(npuMem_bresp),
    .io_npuMem_arvalid(npuMem_arvalid), .io_npuMem_arready(npuMem_arready),
    .io_npuMem_araddr(npuMem_araddr), .io_npuMem_arid(npuMem_arid),
    .io_npuMem_arlen(npuMem_arlen), .io_npuMem_arsize(npuMem_arsize),
    .io_npuMem_arburst(npuMem_arburst), .io_npuMem_arcache(npuMem_arcache),
    .io_npuMem_arprot(npuMem_arprot),
    .io_npuMem_rvalid(npuMem_rvalid), .io_npuMem_rready(npuMem_rready),
    .io_npuMem_rdata(npuMem_rdata), .io_npuMem_rid(npuMem_rid),
    .io_npuMem_rresp(npuMem_rresp), .io_npuMem_rlast(npuMem_rlast),

    // 内存从口（本装置接 AxiMemModel）
    .io_mem_ar_arid(io_mem_ar_arid), .io_mem_ar_araddr(io_mem_ar_araddr),
    .io_mem_ar_arlen(io_mem_ar_arlen), .io_mem_ar_arsize(io_mem_ar_arsize),
    .io_mem_ar_arburst(io_mem_ar_arburst), .io_mem_ar_arlock(io_mem_ar_arlock),
    .io_mem_ar_arcache(io_mem_ar_arcache), .io_mem_ar_arprot(io_mem_ar_arprot),
    .io_mem_ar_arvalid(io_mem_ar_arvalid), .io_mem_ar_arready(io_mem_ar_arready),
    .io_mem_r_rid(io_mem_r_rid), .io_mem_r_rdata(io_mem_r_rdata),
    .io_mem_r_rresp(io_mem_r_rresp), .io_mem_r_rlast(io_mem_r_rlast),
    .io_mem_r_rvalid(io_mem_r_rvalid), .io_mem_r_rready(io_mem_r_rready),
    .io_mem_aw_awid(io_mem_aw_awid), .io_mem_aw_awaddr(io_mem_aw_awaddr),
    .io_mem_aw_awlen(io_mem_aw_awlen), .io_mem_aw_awsize(io_mem_aw_awsize),
    .io_mem_aw_awburst(io_mem_aw_awburst), .io_mem_aw_awcache(io_mem_aw_awcache),
    .io_mem_aw_awprot(io_mem_aw_awprot),
    .io_mem_aw_awvalid(io_mem_aw_awvalid), .io_mem_aw_awready(io_mem_aw_awready),
    .io_mem_w_wid(io_mem_w_wid), .io_mem_w_wdata(io_mem_w_wdata),
    .io_mem_w_wstrb(io_mem_w_wstrb), .io_mem_w_wlast(io_mem_w_wlast),
    .io_mem_w_wvalid(io_mem_w_wvalid), .io_mem_w_wready(io_mem_w_wready),
    .io_mem_b_bid(io_mem_b_bid), .io_mem_b_bresp(io_mem_b_bresp),
    .io_mem_b_bvalid(io_mem_b_bvalid), .io_mem_b_bready(io_mem_b_bready),

    .io_uart_txd(glue_uart_txd), .io_uart_rxd(1'b1),
    .io_gpio_in(8'h0), .io_gpio_out(glue_gpio_out), .io_gpio_dir(glue_gpio_dir),
    .io_irq(glue_irq),

    // ETH 从口（本装置不访问；恒 ready、无响应 —— 与 glue_pbus 装置的"防挂死"口径同）
    .io_ethAxi_awvalid(), .io_ethAxi_awready(1'b1),
    .io_ethAxi_awaddr(), .io_ethAxi_awprot(),
    .io_ethAxi_wvalid(), .io_ethAxi_wready(1'b1),
    .io_ethAxi_wdata(), .io_ethAxi_wstrb(),
    .io_ethAxi_bvalid(1'b0), .io_ethAxi_bready(), .io_ethAxi_bresp(2'b00),
    .io_ethAxi_arvalid(), .io_ethAxi_arready(1'b1),
    .io_ethAxi_araddr(), .io_ethAxi_arprot(),
    .io_ethAxi_rvalid(1'b0), .io_ethAxi_rready(),
    .io_ethAxi_rdata(32'h0), .io_ethAxi_rresp(2'b00),

    // ★ NPU 寄存器窗主口 → NpuTop.axilite_*（板级等价接线）
    .io_npuAxi_awvalid(npuAxi_awvalid), .io_npuAxi_awready(npuAxi_awready),
    .io_npuAxi_awaddr(npuAxi_awaddr), .io_npuAxi_awprot(npuAxi_awprot),
    .io_npuAxi_wvalid(npuAxi_wvalid), .io_npuAxi_wready(npuAxi_wready),
    .io_npuAxi_wdata(npuAxi_wdata), .io_npuAxi_wstrb(npuAxi_wstrb),
    .io_npuAxi_bvalid(npuAxi_bvalid), .io_npuAxi_bready(npuAxi_bready),
    .io_npuAxi_bresp(npuAxi_bresp),
    .io_npuAxi_arvalid(npuAxi_arvalid), .io_npuAxi_arready(npuAxi_arready),
    .io_npuAxi_araddr(npuAxi_araddr), .io_npuAxi_arprot(npuAxi_arprot),
    .io_npuAxi_rvalid(npuAxi_rvalid), .io_npuAxi_rready(npuAxi_rready),
    .io_npuAxi_rdata(npuAxi_rdata), .io_npuAxi_rresp(npuAxi_rresp),

    .io_loadMode(1'b0), .io_loadActive(glue_loadActive),
    .io_sd_sck(glue_sd_sck), .io_sd_mosi(glue_sd_mosi), .io_sd_miso(1'b1),
    .io_sd_cs_n(glue_sd_cs_n), .io_cpuReset(glue_cpuReset),
    .io_sd_state(glue_sd_state), .io_sd_err(glue_sd_err),
    .io_sd_dbg(glue_sd_dbg), .io_sd_dbg2(glue_sd_dbg2)
  );

  // ===========================================================================
  // ★ N5b：复位同步器 + 三座异步桥（与板级 board/yeshen_mini_soc.v 同拓扑）
  // ===========================================================================
  // 复位：异步置位 / 同步释放，cpu 先、npu 后（TB 无 loader ⇒ asyncRst = reset）
  NpuResetSync u_rst_sync (
    .io_cpuClk   (cpu_clk),
    .io_npuClk   (npu_clk),
    .io_asyncRst (reset),
    .io_cpuRstn  (cpu_rstn),
    .io_npuRstn  (npu_rstn)
  );
  assign npu_reset = ~npu_rstn;

  // (a) 主机寄存器窗 AXI4-Lite 异步桥：glue.io_npuAxi_*（npuAxi_*）⇄ NpuTop.axilite_*（npuAxi2_*）
  NpuAxiLiteCdc u_npu_axilite_cdc (
    .io_cpuClk  (cpu_clk),
    .io_cpuRstn (cpu_rstn),
    .io_npuClk  (npu_clk),
    .io_npuRstn (npu_rstn),
    .io_axilite_aw_valid        (npuAxi_awvalid),
    .io_axilite_aw_ready        (npuAxi_awready),
    .io_axilite_aw_payload_addr (npuAxi_awaddr),
    .io_axilite_aw_payload_prot (npuAxi_awprot),
    .io_axilite_w_valid         (npuAxi_wvalid),
    .io_axilite_w_ready         (npuAxi_wready),
    .io_axilite_w_payload_data  (npuAxi_wdata),
    .io_axilite_w_payload_strb  (npuAxi_wstrb),
    .io_axilite_b_valid         (npuAxi_bvalid),
    .io_axilite_b_ready         (npuAxi_bready),
    .io_axilite_b_payload_resp  (npuAxi_bresp),
    .io_axilite_ar_valid        (npuAxi_arvalid),
    .io_axilite_ar_ready        (npuAxi_arready),
    .io_axilite_ar_payload_addr (npuAxi_araddr),
    .io_axilite_ar_payload_prot (npuAxi_arprot),
    .io_axilite_r_valid         (npuAxi_rvalid),
    .io_axilite_r_ready         (npuAxi_rready),
    .io_axilite_r_payload_data  (npuAxi_rdata),
    .io_axilite_r_payload_resp  (npuAxi_rresp),
    .io_npu_axilite_aw_valid        (npuAxi2_awvalid),
    .io_npu_axilite_aw_ready        (npuAxi2_awready),
    .io_npu_axilite_aw_payload_addr (npuAxi2_awaddr),
    .io_npu_axilite_aw_payload_prot (npuAxi2_awprot),
    .io_npu_axilite_w_valid         (npuAxi2_wvalid),
    .io_npu_axilite_w_ready         (npuAxi2_wready),
    .io_npu_axilite_w_payload_data  (npuAxi2_wdata),
    .io_npu_axilite_w_payload_strb  (npuAxi2_wstrb),
    .io_npu_axilite_b_valid         (npuAxi2_bvalid),
    .io_npu_axilite_b_ready         (npuAxi2_bready),
    .io_npu_axilite_b_payload_resp  (npuAxi2_bresp),
    .io_npu_axilite_ar_valid        (npuAxi2_arvalid),
    .io_npu_axilite_ar_ready        (npuAxi2_arready),
    .io_npu_axilite_ar_payload_addr (npuAxi2_araddr),
    .io_npu_axilite_ar_payload_prot (npuAxi2_arprot),
    .io_npu_axilite_r_valid         (npuAxi2_rvalid),
    .io_npu_axilite_r_ready         (npuAxi2_rready),
    .io_npu_axilite_r_payload_data  (npuAxi2_rdata),
    .io_npu_axilite_r_payload_resp  (npuAxi2_rresp)
  );

  // (b) 内存主口 AXI4 异步桥：NpuTop.axi_*（npuMem2_*）⇄ glue.io_npuMem_*（npuMem_*）
  NpuMemCdc u_npu_mem_cdc (
    .cpuClk  (cpu_clk),
    .cpuRstn (cpu_rstn),
    .npuClk  (npu_clk),
    .npuRstn (npu_rstn),
    .npuMem_aw_valid        (npuMem2_awvalid),
    .npuMem_aw_ready        (npuMem2_awready),
    .npuMem_aw_payload_addr (npuMem2_awaddr),
    .npuMem_aw_payload_id   (npuMem2_awid),
    .npuMem_aw_payload_len  (npuMem2_awlen),
    .npuMem_aw_payload_size (npuMem2_awsize),
    .npuMem_aw_payload_burst(npuMem2_awburst),
    .npuMem_aw_payload_cache(npuMem2_awcache),
    .npuMem_aw_payload_prot (npuMem2_awprot),
    .npuMem_w_valid         (npuMem2_wvalid),
    .npuMem_w_ready         (npuMem2_wready),
    .npuMem_w_payload_data  (npuMem2_wdata),
    .npuMem_w_payload_strb  (npuMem2_wstrb),
    .npuMem_w_payload_last  (npuMem2_wlast),
    .npuMem_b_valid         (npuMem2_bvalid),
    .npuMem_b_ready         (npuMem2_bready),
    .npuMem_b_payload_id    (npuMem2_bid),
    .npuMem_b_payload_resp  (npuMem2_bresp),
    .npuMem_ar_valid        (npuMem2_arvalid),
    .npuMem_ar_ready        (npuMem2_arready),
    .npuMem_ar_payload_addr (npuMem2_araddr),
    .npuMem_ar_payload_id   (npuMem2_arid),
    .npuMem_ar_payload_len  (npuMem2_arlen),
    .npuMem_ar_payload_size (npuMem2_arsize),
    .npuMem_ar_payload_burst(npuMem2_arburst),
    .npuMem_ar_payload_cache(npuMem2_arcache),
    .npuMem_ar_payload_prot (npuMem2_arprot),
    .npuMem_r_valid         (npuMem2_rvalid),
    .npuMem_r_ready         (npuMem2_rready),
    .npuMem_r_payload_data  (npuMem2_rdata),
    .npuMem_r_payload_id    (npuMem2_rid),
    .npuMem_r_payload_resp  (npuMem2_rresp),
    .npuMem_r_payload_last  (npuMem2_rlast),
    .cpuMem_aw_valid        (npuMem_awvalid),
    .cpuMem_aw_ready        (npuMem_awready),
    .cpuMem_aw_payload_addr (npuMem_awaddr),
    .cpuMem_aw_payload_id   (npuMem_awid),
    .cpuMem_aw_payload_len  (npuMem_awlen),
    .cpuMem_aw_payload_size (npuMem_awsize),
    .cpuMem_aw_payload_burst(npuMem_awburst),
    .cpuMem_aw_payload_cache(npuMem_awcache),
    .cpuMem_aw_payload_prot (npuMem_awprot),
    .cpuMem_w_valid         (npuMem_wvalid),
    .cpuMem_w_ready         (npuMem_wready),
    .cpuMem_w_payload_data  (npuMem_wdata),
    .cpuMem_w_payload_strb  (npuMem_wstrb),
    .cpuMem_w_payload_last  (npuMem_wlast),
    .cpuMem_b_valid         (npuMem_bvalid),
    .cpuMem_b_ready         (npuMem_bready),
    .cpuMem_b_payload_id    (npuMem_bid),
    .cpuMem_b_payload_resp  (npuMem_bresp),
    .cpuMem_ar_valid        (npuMem_arvalid),
    .cpuMem_ar_ready        (npuMem_arready),
    .cpuMem_ar_payload_addr (npuMem_araddr),
    .cpuMem_ar_payload_id   (npuMem_arid),
    .cpuMem_ar_payload_len  (npuMem_arlen),
    .cpuMem_ar_payload_size (npuMem_arsize),
    .cpuMem_ar_payload_burst(npuMem_arburst),
    .cpuMem_ar_payload_cache(npuMem_arcache),
    .cpuMem_ar_payload_prot (npuMem_arprot),
    .cpuMem_r_valid         (npuMem_rvalid),
    .cpuMem_r_ready         (npuMem_rready),
    .cpuMem_r_payload_data  (npuMem_rdata),
    .cpuMem_r_payload_id    (npuMem_rid),
    .cpuMem_r_payload_resp  (npuMem_rresp),
    .cpuMem_r_payload_last  (npuMem_rlast)
  );

  // (c) IRQ 电平跨域（npu → cpu，2-FF）：NpuTop.irq（npu_irq）→ glue.io_npuIrq（npu_irq_cpu）
  NpuIrqCdc u_npu_irq_cdc (
    .io_cpuClk      (cpu_clk),
    .io_cpuRstn     (cpu_rstn),
    .io_npuClk      (npu_clk),
    .io_npuRstn     (npu_rstn),
    .io_npuIrq      (npu_irq),
    .io_cpuIrq      (npu_irq_cpu),
    .io_cpuClearReq (1'b0),
    .io_npuClearReq ()
  );

  // ===========================================================================
  // DUT②：NpuTop（原网表，只读；端口表照抄 board/yeshen_mini_soc.v）
  //   时钟 = **npu_clk**（37 MHz，非整数比）；复位 = ~npu_rstn（npu 域同步释放，cpu 先/npu 后）
  //   三个接口接三座桥的 npu 侧（npuAxi2_* / npuMem2_* / npu_irq）
  // ===========================================================================
  NpuTop u_npu (
    .clk   (npu_clk),
    .reset (npu_reset),

    .axilite_aw_valid        (npuAxi2_awvalid),
    .axilite_aw_ready        (npuAxi2_awready),
    .axilite_aw_payload_addr (npuAxi2_awaddr),
    .axilite_aw_payload_prot (npuAxi2_awprot),
    .axilite_w_valid         (npuAxi2_wvalid),
    .axilite_w_ready         (npuAxi2_wready),
    .axilite_w_payload_data  (npuAxi2_wdata),
    .axilite_w_payload_strb  (npuAxi2_wstrb),
    .axilite_b_valid         (npuAxi2_bvalid),
    .axilite_b_ready         (npuAxi2_bready),
    .axilite_b_payload_resp  (npuAxi2_bresp),
    .axilite_ar_valid        (npuAxi2_arvalid),
    .axilite_ar_ready        (npuAxi2_arready),
    .axilite_ar_payload_addr (npuAxi2_araddr),
    .axilite_ar_payload_prot (npuAxi2_arprot),
    .axilite_r_valid         (npuAxi2_rvalid),
    .axilite_r_ready         (npuAxi2_rready),
    .axilite_r_payload_data  (npuAxi2_rdata),
    .axilite_r_payload_resp  (npuAxi2_rresp),

    .axi_aw_valid         (npuMem2_awvalid), .axi_aw_ready         (npuMem2_awready),
    .axi_aw_payload_addr  (npuMem2_awaddr),  .axi_aw_payload_id    (npuMem2_awid),
    .axi_aw_payload_len   (npuMem2_awlen),   .axi_aw_payload_size  (npuMem2_awsize),
    .axi_aw_payload_burst (npuMem2_awburst), .axi_aw_payload_cache (npuMem2_awcache),
    .axi_aw_payload_prot  (npuMem2_awprot),
    .axi_w_valid          (npuMem2_wvalid),  .axi_w_ready          (npuMem2_wready),
    .axi_w_payload_data   (npuMem2_wdata),   .axi_w_payload_strb   (npuMem2_wstrb),
    .axi_w_payload_last   (npuMem2_wlast),
    .axi_b_valid          (npuMem2_bvalid),  .axi_b_ready          (npuMem2_bready),
    .axi_b_payload_id     (npuMem2_bid),     .axi_b_payload_resp   (npuMem2_bresp),
    .axi_ar_valid         (npuMem2_arvalid), .axi_ar_ready         (npuMem2_arready),
    .axi_ar_payload_addr  (npuMem2_araddr),  .axi_ar_payload_id    (npuMem2_arid),
    .axi_ar_payload_len   (npuMem2_arlen),   .axi_ar_payload_size  (npuMem2_arsize),
    .axi_ar_payload_burst (npuMem2_arburst), .axi_ar_payload_cache (npuMem2_arcache),
    .axi_ar_payload_prot  (npuMem2_arprot),
    .axi_r_valid          (npuMem2_rvalid),  .axi_r_ready          (npuMem2_rready),
    .axi_r_payload_data   (npuMem2_rdata),   .axi_r_payload_id     (npuMem2_rid),
    .axi_r_payload_resp   (npuMem2_rresp),   .axi_r_payload_last   (npuMem2_rlast),

    .irq (npu_irq)
  );

  // ===========================================================================
  // DUT③：AxiMemModel（CPU 域从口；MEMSZ 必须与 run_twoclock_ab.sh 一致）
  // ===========================================================================
  localparam integer MEMSZ = 786432;
  AxiMemModel #(.MEMSZ(MEMSZ), .ADDR_W(28)) mem0 (
    .clk(cpu_clk), .reset(reset),
    .axi_aw_valid(io_mem_aw_awvalid), .axi_aw_ready(io_mem_aw_awready),
    .axi_aw_payload_addr(io_mem_aw_awaddr[27:0]), .axi_aw_payload_id(io_mem_aw_awid),
    .axi_aw_payload_len(io_mem_aw_awlen), .axi_aw_payload_size(io_mem_aw_awsize),
    .axi_aw_payload_burst(io_mem_aw_awburst), .axi_aw_payload_cache(io_mem_aw_awcache),
    .axi_aw_payload_prot(io_mem_aw_awprot),
    .axi_w_valid(io_mem_w_wvalid), .axi_w_ready(io_mem_w_wready),
    .axi_w_payload_data(io_mem_w_wdata), .axi_w_payload_strb(io_mem_w_wstrb),
    .axi_w_payload_last(io_mem_w_wlast),
    .axi_b_valid(io_mem_b_bvalid), .axi_b_ready(io_mem_b_bready),
    .axi_b_payload_id(io_mem_b_bid), .axi_b_payload_resp(io_mem_b_bresp),
    .axi_ar_valid(io_mem_ar_arvalid), .axi_ar_ready(io_mem_ar_arready),
    .axi_ar_payload_addr(io_mem_ar_araddr[27:0]), .axi_ar_payload_id(io_mem_ar_arid),
    .axi_ar_payload_len(io_mem_ar_arlen), .axi_ar_payload_size(io_mem_ar_arsize),
    .axi_ar_payload_burst(io_mem_ar_arburst), .axi_ar_payload_cache(io_mem_ar_arcache),
    .axi_ar_payload_prot(io_mem_ar_arprot),
    .axi_r_valid(io_mem_r_rvalid), .axi_r_ready(io_mem_r_rready),
    .axi_r_payload_data(io_mem_r_rdata), .axi_r_payload_id(io_mem_r_rid),
    .axi_r_payload_resp(io_mem_r_rresp), .axi_r_payload_last(io_mem_r_rlast)
  );

  // ===========================================================================
  // IRQ 仪器（电平证据）；**在 cpu 域采样**（PLIC 在 cpu 域）
  // ===========================================================================
  integer irq_high_cycles;
  integer irq_rises;
  reg     irq_prev = 1'b0;
  always @(posedge cpu_clk) begin
    if (!reset) begin
      if (npu_irq) irq_high_cycles = irq_high_cycles + 1;
      if (npu_irq && !irq_prev) irq_rises = irq_rises + 1;
      irq_prev <= npu_irq;
    end
  end

  integer tbfail;

  // ======================= 手摇 AxiLite4 主机（复用 NpuTopTb）=======================
  task fail_timeout(input [8*64-1:0] why);
    begin
      $display("RESULT: FAIL timeout %0s", why);
      $finish;
    end
  endtask

  // 写：地址是 **窗基址 + 窗内偏移**（glue 内部把整根地址剥到 14bit 偏移再喂 HostRegs）
  task axi_write(input [31:0] off, input [31:0] data);
    integer t; reg ok;
    begin
      @(negedge cpu_clk);
      p_awvalid = 1'b1; p_awaddr = NPU_BASE + off; p_awprot = 3'b000;
      p_wvalid  = 1'b1; p_wdata  = data; p_wstrb = 4'hF; p_wlast = 1'b1;
      p_bready  = 1'b0;
      t = 0; ok = 1'b0;
      while (!ok) begin
        @(posedge cpu_clk);
        if (p_awready && p_wready) ok = 1'b1;
        else begin t = t + 1; if (t > 200) fail_timeout("aw/w ready"); end
      end
      @(negedge cpu_clk);
      p_awvalid = 1'b0; p_wvalid = 1'b0; p_bready = 1'b1;
      t = 0; ok = 1'b0;
      while (!ok) begin
        @(posedge cpu_clk);
        if (p_bvalid) ok = 1'b1;
        else begin t = t + 1; if (t > 200) fail_timeout("b valid"); end
      end
      if (p_bresp !== 2'b00) begin
        tbfail = tbfail + 1;
        $display("TBFAIL: write BRESP=%b off=%08x", p_bresp, off);
      end
      @(negedge cpu_clk);
      p_bready = 1'b0;
    end
  endtask

  task axi_read(input [31:0] off, output [31:0] data);
    integer t; reg ok;
    begin
      @(negedge cpu_clk);
      p_arvalid = 1'b1; p_araddr = NPU_BASE + off; p_arprot = 3'b000;
      p_rready  = 1'b0;
      t = 0; ok = 1'b0;
      while (!ok) begin
        @(posedge cpu_clk);
        if (p_arready) ok = 1'b1;
        else begin t = t + 1; if (t > 200) fail_timeout("ar ready"); end
      end
      @(negedge cpu_clk);
      p_arvalid = 1'b0; p_rready = 1'b1;
      t = 0; ok = 1'b0;
      while (!ok) begin
        @(posedge cpu_clk);
        if (p_rvalid) begin data = p_rdata; ok = 1'b1; end
        else begin t = t + 1; if (t > 200) fail_timeout("r valid"); end
      end
      if (p_rresp !== 2'b00) begin
        tbfail = tbfail + 1;
        $display("TBFAIL: read RRESP=%b off=%08x", p_rresp, off);
      end
      @(negedge cpu_clk);
      p_rready = 1'b0;
    end
  endtask

  task poll_status(output dseen, output eseen);
    integer k; reg [31:0] st;
    begin
      dseen = 1'b0; eseen = 1'b0; k = 0;
      while (!dseen && !eseen) begin
        axi_read(32'h00000004, st);
        if ((st & 32'h1) === 32'h1) dseen = 1'b1;
        if ((st & 32'h2) === 32'h2) eseen = 1'b1;
        k = k + 1;
        if (k > TIMEOUT) fail_timeout("poll STATUS");
      end
      $display("STATUS_TERM %08x", st);
    end
  endtask

  // ============================== 主流程 ==============================
  reg [31:0] src_v, dst_v, w_v, h_v, c_v;
  reg [31:0] rv, rb;
  reg        irq_pre, irq_post, irq_ack;
  reg        done_seen, err_seen;

  initial begin
    p_awvalid = 1'b0; p_awaddr = 32'h0; p_awprot = 3'b0;
    p_wvalid  = 1'b0; p_wdata  = 32'h0; p_wstrb  = 4'h0; p_wlast = 1'b0;
    p_bready  = 1'b0;
    p_arvalid = 1'b0; p_araddr = 32'h0; p_arprot = 3'b0;
    p_rready  = 1'b0;
    tbfail = 0; irq_high_cycles = 0; irq_rises = 0;
    done_seen = 1'b0; err_seen = 1'b0;
    irq_pre = 1'b0; irq_post = 1'b0; irq_ack = 1'b0;

    if ($test$plusargs("SAME_CLK")) same_clk = 1'b1;

    if (!$value$plusargs("SRC=%d",   src_v)) begin $display("TB-ERROR: missing +SRC=");   $finish; end
    if (!$value$plusargs("DST=%d",   dst_v)) begin $display("TB-ERROR: missing +DST=");   $finish; end
    if (!$value$plusargs("IMG_W=%d", w_v))   begin $display("TB-ERROR: missing +IMG_W="); $finish; end
    if (!$value$plusargs("IMG_H=%d", h_v))   begin $display("TB-ERROR: missing +IMG_H="); $finish; end
    if (!$value$plusargs("C_IN=%d",  c_v))   begin $display("TB-ERROR: missing +C_IN=");  $finish; end

    $display("CLKCFG same_clk=%0d cpu_clk=100.000MHz npu_clk=%0s ratio_cpu_over_npu=%0s",
             same_clk, same_clk ? "100.000MHz(via cpu_clk)" : "37.000MHz",
             same_clk ? "1.0000" : "2.7027");
    $display("TB NPU SRC=%0d DST=%0d IMG_W=%0d IMG_H=%0d C_IN=%0d LEN_EXPECT=%0d",
             src_v, dst_v, w_v, h_v, c_v, w_v * h_v * c_v);

    // 复位：两域同源、高有效
    repeat (4) @(negedge cpu_clk);
    reset = 1'b0;
    @(negedge cpu_clk);

    // ---- 1) ID 常数（从口活着的证明）----
    axi_read(32'h00000030, rv);
    $display("ID_READ %08x", rv);
    if (rv !== ID_CONST) begin tbfail = tbfail + 1; $display("TBFAIL: ID_READ %08x != %08x", rv, ID_CONST); end

    // ---- 2) 起手 STATUS / CTRL 全 0 ----
    axi_read(32'h00000004, rv); $display("STATUS_PRE %08x", rv);
    if (rv !== 32'h0) begin tbfail = tbfail + 1; $display("TBFAIL: STATUS_PRE 非 0 = %08x", rv); end
    axi_read(32'h00000000, rv); $display("CTRL_PRE %08x", rv);
    if (rv !== 32'h0) begin tbfail = tbfail + 1; $display("TBFAIL: CTRL_PRE 非 0 = %08x", rv); end

    // ---- 3) IRQ 启动之前必须为 0 ----
    irq_pre = npu_irq;
    $display("PRE_IRQ=%0d", irq_pre);

    // ---- 4) 编程 + 回读对账 ----
    axi_write(32'h00000020, src_v);   // SRC_ADDR
    axi_write(32'h00000024, dst_v);   // DST_ADDR
    axi_write(32'h00000008, w_v);     // IMG_W
    axi_write(32'h0000000C, h_v);     // IMG_H
    axi_write(32'h00000010, c_v);     // C_IN
    axi_read(32'h00000020, rb); if (rb !== src_v) begin tbfail=tbfail+1; $display("TBFAIL: SRC_ADDR rb=%08x != %08x", rb, src_v); end
    axi_read(32'h00000024, rb); if (rb !== dst_v) begin tbfail=tbfail+1; $display("TBFAIL: DST_ADDR rb=%08x != %08x", rb, dst_v); end
    axi_read(32'h00000008, rb); if (rb !== w_v)   begin tbfail=tbfail+1; $display("TBFAIL: IMG_W rb=%08x != %08x", rb, w_v); end
    axi_read(32'h0000000C, rb); if (rb !== h_v)   begin tbfail=tbfail+1; $display("TBFAIL: IMG_H rb=%08x != %08x", rb, h_v); end
    axi_read(32'h00000010, rb); if (rb !== c_v)   begin tbfail=tbfail+1; $display("TBFAIL: C_IN rb=%08x != %08x", rb, c_v); end
    if (tbfail == 0) $display("RB_OK");

    // ---- 5) 启动（CTRL.bit0，自清）----
    axi_write(32'h00000000, 32'h00000001);

    // ---- 6) 轮询 STATUS ----
    poll_status(done_seen, err_seen);
    $display("DONE_SEEN=%0d ERR_SEEN=%0d", done_seen, err_seen);

    axi_read(32'h00000004, rv); $display("STATUS_POST %08x", rv);
    axi_read(32'h00000000, rv); $display("CTRL_POST %08x", rv);

    // ---- 7) IRQ 完成后为 1；保持 50 拍 ----
    irq_post = npu_irq;
    $display("POST_IRQ=%0d", irq_post);
    repeat (50) @(negedge cpu_clk);
    $display("IRQ_HELD_AFTER_50=%0d", npu_irq);

    // ---- 8) 确认（soft_reset），IRQ 必须落下 ----
    axi_write(32'h00000000, 32'h00000002);
    repeat (4) @(negedge cpu_clk);
    irq_ack = npu_irq;
    $display("IRQ_AFTER_ACK=%0d", irq_ack);
    axi_read(32'h00000004, rv); $display("STATUS_AFTER_ACK %08x", rv);
    $display("IRQ_HIGH_CYCLES=%0d IRQ_RISES=%0d", irq_high_cycles, irq_rises);

    // ---- 判据（TB 侧只判"主机看到了什么"；字节对账归闸门 python）----
    if (irq_pre !== 1'b0) begin tbfail = tbfail + 1; $display("TBFAIL: 启动前 IRQ 就为 1"); end
    if (irq_post !== 1'b1) begin tbfail = tbfail + 1; $display("TBFAIL: 完成后 IRQ 不是 1（电平没锁住）"); end
    if (irq_ack  !== 1'b0) begin tbfail = tbfail + 1; $display("TBFAIL: soft_reset 后 IRQ 没落下（卡死在高）"); end
    if (!done_seen)        begin tbfail = tbfail + 1; $display("TBFAIL: 没看到 done"); end
    if (err_seen)          begin tbfail = tbfail + 1; $display("TBFAIL: 看到 err"); end

    if (tbfail == 0) $display("RESULT: PASS");
    else             $display("RESULT: FAIL tbfail=%0d", tbfail);
    $finish;
  end

  // 兜底：不收敛时也停在确定时刻并报红（dump 仍会由 AxiMemModel 的 final 写出）
  initial begin
    #SIM_LIMIT;
    $display("RESULT: FAIL timeout(global watchdog %0d ns)", SIM_LIMIT);
    $finish;
  end

endmodule
