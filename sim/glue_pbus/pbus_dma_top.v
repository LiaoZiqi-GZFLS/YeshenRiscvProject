// =============================================================================
// pbus_dma_top —— glue_pbus 装置专属的「最小 SoC 头」：把 DMA 引擎的真实从口
//                 （`y1/gen/DmaEngine.v`）接到 `YeshenSocGlue` 的 `io_dmaAxi_*` 从口主口 +
//                 `io_dmaMem_*` 主口上。
//
// 为什么需要这个 wrapper（与 pbus_npu_top.v 同因）：
//   现有装置 `tb_pbus.cpp` 的 top 是 `YeshenSocGlue`，它的 `io_dmaAxi_*`（CSR 从口主方）与
//   `io_dmaMem_*`（内存主口从方）在顶层都是**悬空** —— 网表里根本没有 DmaEngine 实例
//   （板级 `board/yeshen_mini_soc.v` 的【12】才把它接上）。要判「CPU→glue→DMA CSR 窗 + DMA 主口
//   →glue§3.5→内存」这条**完整集成通路**是否真的通，必须把 DMA 引擎也拉进同一个 Verilator 网表。
//
//   本 wrapper 只做两件事：
//     ① 实例化 `YeshenSocGlue`（原样，不动），把它的 `io_dmaAxi_*` 主口**逐根**接到 `DmaEngine.axilite_*`
//        从口、把 `DmaEngine.axi_*` 主口逐根接回 `io_dmaMem_*`（= 板级那一段接线的等价物）；
//     ② 把 glue 的其它输入按「静默」口径钉死（cpuFetch/cpuLsu/npuMem 不发起、loadMode=0、
//        uart_rxd=1、sd_miso=1、ethIrq=0、npuIrq=0、gpio_in=0），把 TB 要驱动的口
//        （cpuIo / mem / ethAxi）原样透出，把要观测的口透出。
//
//   DmaEngine 的每通道流口结构化空闲（rd_ready=0 / wr_valid=0）—— 本装置只测 COPY（DDR→DDR）。
//
// ⚠️ 纪律：本文件是 `sim/glue_pbus/**` 的**新增件**（装置侧），**不是 RTL**；
//    两个被实例化的网表（rtl/YeshenSocGlue.v、y1/gen/DmaEngine.v）都只读、一字不改。
// =============================================================================
`timescale 1ns/1ps

module pbus_dma_top(
  input         clock,
  input         reset,

  // ---------- CPU 侧单拍外设主口（本装置驱动；= 核的 LsuCachelessAxi4Plugin） ----------
  input         io_cpuIo_awvalid,
  output        io_cpuIo_awready,
  input  [31:0] io_cpuIo_awaddr,
  input  [2:0]  io_cpuIo_awsize,
  input  [3:0]  io_cpuIo_awcache,
  input  [2:0]  io_cpuIo_awprot,
  input         io_cpuIo_wvalid,
  output        io_cpuIo_wready,
  input  [31:0] io_cpuIo_wdata,
  input  [3:0]  io_cpuIo_wstrb,
  input         io_cpuIo_wlast,
  output        io_cpuIo_bvalid,
  input         io_cpuIo_bready,
  output [1:0]  io_cpuIo_bresp,
  input         io_cpuIo_arvalid,
  output        io_cpuIo_arready,
  input  [31:0] io_cpuIo_araddr,
  input  [2:0]  io_cpuIo_arsize,
  input  [3:0]  io_cpuIo_arcache,
  input  [2:0]  io_cpuIo_arprot,
  output        io_cpuIo_rvalid,
  input         io_cpuIo_rready,
  output [31:0] io_cpuIo_rdata,
  output [1:0]  io_cpuIo_rresp,
  output        io_cpuIo_rlast,

  // ---------- 内存从口（本装置建模：真 64bit INCR 内存模型，见 tb_dma_pbus.cpp） ----------
  output [3:0]  io_mem_ar_arid,
  output [31:0] io_mem_ar_araddr,
  output [7:0]  io_mem_ar_arlen,
  output [2:0]  io_mem_ar_arsize,
  output [1:0]  io_mem_ar_arburst,
  output [2:0]  io_mem_ar_arlock,
  output [3:0]  io_mem_ar_arcache,
  output [2:0]  io_mem_ar_arprot,
  output        io_mem_ar_arvalid,
  input         io_mem_ar_arready,
  input  [3:0]  io_mem_r_rid,
  input  [63:0] io_mem_r_rdata,
  input  [1:0]  io_mem_r_rresp,
  input         io_mem_r_rlast,
  input         io_mem_r_rvalid,
  output        io_mem_r_rready,
  output [3:0]  io_mem_aw_awid,
  output [31:0] io_mem_aw_awaddr,
  output [7:0]  io_mem_aw_awlen,
  output [2:0]  io_mem_aw_awsize,
  output [1:0]  io_mem_aw_awburst,
  output        io_mem_aw_awlock,
  output [3:0]  io_mem_aw_awcache,
  output [2:0]  io_mem_aw_awprot,
  output        io_mem_aw_awvalid,
  input         io_mem_aw_awready,
  output [3:0]  io_mem_w_wid,
  output [63:0] io_mem_w_wdata,
  output [7:0]  io_mem_w_wstrb,
  output        io_mem_w_wlast,
  output        io_mem_w_wvalid,
  input         io_mem_w_wready,
  input  [3:0]  io_mem_b_bid,
  input  [1:0]  io_mem_b_bresp,
  input         io_mem_b_bvalid,
  output        io_mem_b_bready,

  // ---------- ETH 从口（本装置建模：永远 ready + 单拍 B/R=OKAY） ----------
  output        io_ethAxi_awvalid,
  input         io_ethAxi_awready,
  output [31:0] io_ethAxi_awaddr,
  output [2:0]  io_ethAxi_awprot,
  output        io_ethAxi_wvalid,
  input         io_ethAxi_wready,
  output [31:0] io_ethAxi_wdata,
  output [3:0]  io_ethAxi_wstrb,
  input         io_ethAxi_bvalid,
  output        io_ethAxi_bready,
  input  [1:0]  io_ethAxi_bresp,
  output        io_ethAxi_arvalid,
  input         io_ethAxi_arready,
  output [31:0] io_ethAxi_araddr,
  output [2:0]  io_ethAxi_arprot,
  input         io_ethAxi_rvalid,
  output        io_ethAxi_rready,
  input  [31:0] io_ethAxi_rdata,
  input  [1:0]  io_ethAxi_rresp,

  // ---------- 观测（不驱动，只看） ----------
  output [7:0]  io_gpio_out,
  output [7:0]  io_gpio_dir,
  // 引擎 dmaIrq（= GBL_DONE|GBL_ERR 线或）直连 glue.io_dmaIrq —— 判据里看它的电平变化
  output        obs_dma_irq,
  // glue ↔ DmaEngine 的 CSR 窗握手（现场证据：AW/W/AR 什么时候被举、ready 何时回）
  output        obs_dmaAxi_awvalid,
  output [31:0] obs_dmaAxi_awaddr,
  output        obs_dmaAxi_awready,
  output        obs_dmaAxi_wvalid,
  output        obs_dmaAxi_wready,
  output        obs_dmaAxi_bvalid,
  output [1:0]  obs_dmaAxi_bresp,
  output        obs_dmaAxi_arvalid,
  output [31:0] obs_dmaAxi_araddr,
  output        obs_dmaAxi_arready,
  output        obs_dmaAxi_rvalid,
  output        obs_dmaAxi_rready,
  output [31:0] obs_dmaAxi_rdata,
  output [1:0]  obs_dmaAxi_rresp,

  // ---- ★ 诊断：glue ↔ DmaEngine 的**内存主口**握手（= io_dmaMem_*）----
  output        obs_dmaMem_arvalid,
  output        obs_dmaMem_arready,
  output        obs_dmaMem_rvalid,
  output        obs_dmaMem_rready,
  output        obs_dmaMem_rlast,
  output        obs_dmaMem_awvalid,
  output        obs_dmaMem_awready,
  output        obs_dmaMem_wvalid,
  output        obs_dmaMem_wready,
  output        obs_dmaMem_bvalid,
  output        obs_dmaMem_bready,
  // ---- ★ 诊断：glue §3.5 的 owner（4 bit）与 memRdBusy（层次引用，只作证据）----
  output [3:0]  obs_glue_owner,
  output        obs_glue_memRdBusy
);

  // ---------------- glue ↔ DmaEngine 之间的连线 ----------------
  wire        dmaAxi_awvalid, dmaAxi_awready;
  wire [31:0] dmaAxi_awaddr;
  wire [2:0]  dmaAxi_awprot;
  wire        dmaAxi_wvalid, dmaAxi_wready;
  wire [31:0] dmaAxi_wdata;
  wire [3:0]  dmaAxi_wstrb;
  wire        dmaAxi_bvalid, dmaAxi_bready;
  wire [1:0]  dmaAxi_bresp;
  wire        dmaAxi_arvalid, dmaAxi_arready;
  wire [31:0] dmaAxi_araddr;
  wire [2:0]  dmaAxi_arprot;
  wire        dmaAxi_rvalid, dmaAxi_rready;
  wire [31:0] dmaAxi_rdata;
  wire [1:0]  dmaAxi_rresp;

  wire        dmaMem_awvalid, dmaMem_awready;
  wire [27:0] dmaMem_awaddr;
  wire [3:0]  dmaMem_awid;
  wire [7:0]  dmaMem_awlen;
  wire [2:0]  dmaMem_awsize;
  wire [1:0]  dmaMem_awburst;
  wire [3:0]  dmaMem_awcache;
  wire [2:0]  dmaMem_awprot;
  wire        dmaMem_wvalid, dmaMem_wready;
  wire [63:0] dmaMem_wdata;
  wire [7:0]  dmaMem_wstrb;
  wire        dmaMem_wlast;
  wire        dmaMem_bvalid, dmaMem_bready;
  wire [3:0]  dmaMem_bid;
  wire [1:0]  dmaMem_bresp;
  wire        dmaMem_arvalid, dmaMem_arready;
  wire [27:0] dmaMem_araddr;
  wire [3:0]  dmaMem_arid;
  wire [7:0]  dmaMem_arlen;
  wire [2:0]  dmaMem_arsize;
  wire [1:0]  dmaMem_arburst;
  wire [3:0]  dmaMem_arcache;
  wire [2:0]  dmaMem_arprot;
  wire        dmaMem_rvalid, dmaMem_rready;
  wire [63:0] dmaMem_rdata;
  wire [3:0]  dmaMem_rid;
  wire [1:0]  dmaMem_rresp;
  wire        dmaMem_rlast;

  wire        dma_irq;

  // ---------------- 被观测/被丢弃的 glue 输出 ----------------
  wire [63:0] glue_rdtime;
  wire        glue_intMTime, glue_intMExt, glue_intSExt;
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
  wire        glue_npuMem_awready, glue_npuMem_wready, glue_npuMem_bvalid, glue_npuMem_arready;
  wire        glue_npuMem_rvalid, glue_npuMem_rlast;
  wire [3:0]  glue_npuMem_bid, glue_npuMem_rid;
  wire [1:0]  glue_npuMem_bresp, glue_npuMem_rresp;
  wire [63:0] glue_npuMem_rdata;
  wire        glue_npuAxi_awready, glue_npuAxi_wready, glue_npuAxi_bvalid;
  wire [1:0]  glue_npuAxi_bresp;
  wire        glue_npuAxi_arready, glue_npuAxi_rvalid;
  wire [31:0] glue_npuAxi_rdata;
  wire [1:0]  glue_npuAxi_rresp;
  // glue 对 NPU 寄存器窗是**主方** ⇒ 这些是 glue 的**输出**，必须落到 wire（不能接常数）
  wire        glue_npuAxi_awvalid, glue_npuAxi_wvalid, glue_npuAxi_arvalid;
  wire [31:0] glue_npuAxi_awaddr, glue_npuAxi_wdata, glue_npuAxi_araddr;
  wire [2:0]  glue_npuAxi_awprot, glue_npuAxi_arprot;
  wire [3:0]  glue_npuAxi_wstrb;
  wire        glue_npuAxi_bready, glue_npuAxi_rready;   // VexiiAxiLite32 里 bready/rready 也是 Output

  // ===========================================================================
  // DUT①：YeshenSocGlue（原网表，一字不改）
  // ===========================================================================
  YeshenSocGlue u_glue(
    .clock(clock),
    .reset(reset),

    // CPU 内存主口（本装置不发起）
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

    // CPU 外设主口（本装置驱动 = 「CPU 那样的 pBus 主方」）
    .io_cpuIo_awvalid(io_cpuIo_awvalid), .io_cpuIo_awready(io_cpuIo_awready),
    .io_cpuIo_awaddr(io_cpuIo_awaddr), .io_cpuIo_awsize(io_cpuIo_awsize),
    .io_cpuIo_awcache(io_cpuIo_awcache), .io_cpuIo_awprot(io_cpuIo_awprot),
    .io_cpuIo_wvalid(io_cpuIo_wvalid), .io_cpuIo_wready(io_cpuIo_wready),
    .io_cpuIo_wdata(io_cpuIo_wdata), .io_cpuIo_wstrb(io_cpuIo_wstrb),
    .io_cpuIo_wlast(io_cpuIo_wlast),
    .io_cpuIo_bvalid(io_cpuIo_bvalid), .io_cpuIo_bready(io_cpuIo_bready),
    .io_cpuIo_bresp(io_cpuIo_bresp),
    .io_cpuIo_arvalid(io_cpuIo_arvalid), .io_cpuIo_arready(io_cpuIo_arready),
    .io_cpuIo_araddr(io_cpuIo_araddr), .io_cpuIo_arsize(io_cpuIo_arsize),
    .io_cpuIo_arcache(io_cpuIo_arcache), .io_cpuIo_arprot(io_cpuIo_arprot),
    .io_cpuIo_rvalid(io_cpuIo_rvalid), .io_cpuIo_rready(io_cpuIo_rready),
    .io_cpuIo_rdata(io_cpuIo_rdata), .io_cpuIo_rresp(io_cpuIo_rresp),
    .io_cpuIo_rlast(io_cpuIo_rlast),

    .io_rdtime(glue_rdtime),
    .io_intMTime(glue_intMTime), .io_intMSoft(),
    .io_intMExt(glue_intMExt), .io_intSExt(glue_intSExt),

    .io_ethIrq(1'b0),
    .io_npuIrq(1'b0),
    .io_dmaIrq(dma_irq),

    // NPU 内存主口（本装置不发起；全静默）
    .io_npuMem_awvalid(1'b0), .io_npuMem_awready(glue_npuMem_awready),
    .io_npuMem_awaddr(28'h0), .io_npuMem_awid(4'h0), .io_npuMem_awlen(8'h0),
    .io_npuMem_awsize(3'h0), .io_npuMem_awburst(2'h1), .io_npuMem_awcache(4'h0),
    .io_npuMem_awprot(3'h0),
    .io_npuMem_wvalid(1'b0), .io_npuMem_wready(glue_npuMem_wready),
    .io_npuMem_wdata(64'h0), .io_npuMem_wstrb(8'h0), .io_npuMem_wlast(1'b0),
    .io_npuMem_bvalid(glue_npuMem_bvalid), .io_npuMem_bready(1'b0),
    .io_npuMem_bid(glue_npuMem_bid), .io_npuMem_bresp(glue_npuMem_bresp),
    .io_npuMem_arvalid(1'b0), .io_npuMem_arready(glue_npuMem_arready),
    .io_npuMem_araddr(28'h0), .io_npuMem_arid(4'h0), .io_npuMem_arlen(8'h0),
    .io_npuMem_arsize(3'h0), .io_npuMem_arburst(2'h1), .io_npuMem_arcache(4'h0),
    .io_npuMem_arprot(3'h0),
    .io_npuMem_rvalid(glue_npuMem_rvalid), .io_npuMem_rready(1'b0),
    .io_npuMem_rdata(glue_npuMem_rdata), .io_npuMem_rid(glue_npuMem_rid),
    .io_npuMem_rresp(glue_npuMem_rresp), .io_npuMem_rlast(glue_npuMem_rlast),

    // NPU 寄存器窗主口（本装置不驱动；glue 的输出落 wire，输入静默）
    .io_npuAxi_awvalid(glue_npuAxi_awvalid), .io_npuAxi_awready(glue_npuAxi_awready),
    .io_npuAxi_awaddr(glue_npuAxi_awaddr), .io_npuAxi_awprot(glue_npuAxi_awprot),
    .io_npuAxi_wvalid(glue_npuAxi_wvalid), .io_npuAxi_wready(glue_npuAxi_wready),
    .io_npuAxi_wdata(glue_npuAxi_wdata), .io_npuAxi_wstrb(glue_npuAxi_wstrb),
    .io_npuAxi_bvalid(glue_npuAxi_bvalid), .io_npuAxi_bready(glue_npuAxi_bready),
    .io_npuAxi_bresp(glue_npuAxi_bresp),
    .io_npuAxi_arvalid(glue_npuAxi_arvalid), .io_npuAxi_arready(glue_npuAxi_arready),
    .io_npuAxi_araddr(glue_npuAxi_araddr), .io_npuAxi_arprot(glue_npuAxi_arprot),
    .io_npuAxi_rvalid(glue_npuAxi_rvalid), .io_npuAxi_rready(glue_npuAxi_rready),
    .io_npuAxi_rdata(glue_npuAxi_rdata), .io_npuAxi_rresp(glue_npuAxi_rresp),

    // 内存/ETH 从口（本装置建模）
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
    .io_mem_aw_awburst(io_mem_aw_awburst), .io_mem_aw_awlock(io_mem_aw_awlock),
    .io_mem_aw_awcache(io_mem_aw_awcache), .io_mem_aw_awprot(io_mem_aw_awprot),
    .io_mem_aw_awvalid(io_mem_aw_awvalid), .io_mem_aw_awready(io_mem_aw_awready),
    .io_mem_w_wid(io_mem_w_wid), .io_mem_w_wdata(io_mem_w_wdata),
    .io_mem_w_wstrb(io_mem_w_wstrb), .io_mem_w_wlast(io_mem_w_wlast),
    .io_mem_w_wvalid(io_mem_w_wvalid), .io_mem_w_wready(io_mem_w_wready),
    .io_mem_b_bid(io_mem_b_bid), .io_mem_b_bresp(io_mem_b_bresp),
    .io_mem_b_bvalid(io_mem_b_bvalid), .io_mem_b_bready(io_mem_b_bready),

    .io_uart_txd(glue_uart_txd), .io_uart_rxd(1'b1),
    .io_gpio_in(8'h0), .io_gpio_out(io_gpio_out), .io_gpio_dir(io_gpio_dir),
    .io_irq(glue_irq),

    .io_ethAxi_awvalid(io_ethAxi_awvalid), .io_ethAxi_awready(io_ethAxi_awready),
    .io_ethAxi_awaddr(io_ethAxi_awaddr), .io_ethAxi_awprot(io_ethAxi_awprot),
    .io_ethAxi_wvalid(io_ethAxi_wvalid), .io_ethAxi_wready(io_ethAxi_wready),
    .io_ethAxi_wdata(io_ethAxi_wdata), .io_ethAxi_wstrb(io_ethAxi_wstrb),
    .io_ethAxi_bvalid(io_ethAxi_bvalid), .io_ethAxi_bready(io_ethAxi_bready),
    .io_ethAxi_bresp(io_ethAxi_bresp),
    .io_ethAxi_arvalid(io_ethAxi_arvalid), .io_ethAxi_arready(io_ethAxi_arready),
    .io_ethAxi_araddr(io_ethAxi_araddr), .io_ethAxi_arprot(io_ethAxi_arprot),
    .io_ethAxi_rvalid(io_ethAxi_rvalid), .io_ethAxi_rready(io_ethAxi_rready),
    .io_ethAxi_rdata(io_ethAxi_rdata), .io_ethAxi_rresp(io_ethAxi_rresp),

    // ★ DMA 寄存器窗主口 → DmaEngine.axilite_*（本 wrapper 的接线核心之一）
    .io_dmaAxi_awvalid(dmaAxi_awvalid), .io_dmaAxi_awready(dmaAxi_awready),
    .io_dmaAxi_awaddr(dmaAxi_awaddr), .io_dmaAxi_awprot(dmaAxi_awprot),
    .io_dmaAxi_wvalid(dmaAxi_wvalid), .io_dmaAxi_wready(dmaAxi_wready),
    .io_dmaAxi_wdata(dmaAxi_wdata), .io_dmaAxi_wstrb(dmaAxi_wstrb),
    .io_dmaAxi_bvalid(dmaAxi_bvalid), .io_dmaAxi_bready(dmaAxi_bready),
    .io_dmaAxi_bresp(dmaAxi_bresp),
    .io_dmaAxi_arvalid(dmaAxi_arvalid), .io_dmaAxi_arready(dmaAxi_arready),
    .io_dmaAxi_araddr(dmaAxi_araddr), .io_dmaAxi_arprot(dmaAxi_arprot),
    .io_dmaAxi_rvalid(dmaAxi_rvalid), .io_dmaAxi_rready(dmaAxi_rready),
    .io_dmaAxi_rdata(dmaAxi_rdata), .io_dmaAxi_rresp(dmaAxi_rresp),

    // ★ DMA 内存主口 ← DmaEngine.axi_*（本 wrapper 的接线核心之二；汇入 §3.5 汇聚点）
    .io_dmaMem_awvalid(dmaMem_awvalid), .io_dmaMem_awready(dmaMem_awready),
    .io_dmaMem_awaddr(dmaMem_awaddr), .io_dmaMem_awid(dmaMem_awid),
    .io_dmaMem_awlen(dmaMem_awlen), .io_dmaMem_awsize(dmaMem_awsize),
    .io_dmaMem_awburst(dmaMem_awburst), .io_dmaMem_awcache(dmaMem_awcache),
    .io_dmaMem_awprot(dmaMem_awprot),
    .io_dmaMem_wvalid(dmaMem_wvalid), .io_dmaMem_wready(dmaMem_wready),
    .io_dmaMem_wdata(dmaMem_wdata), .io_dmaMem_wstrb(dmaMem_wstrb),
    .io_dmaMem_wlast(dmaMem_wlast),
    .io_dmaMem_bvalid(dmaMem_bvalid), .io_dmaMem_bready(dmaMem_bready),
    .io_dmaMem_bid(dmaMem_bid), .io_dmaMem_bresp(dmaMem_bresp),
    .io_dmaMem_arvalid(dmaMem_arvalid), .io_dmaMem_arready(dmaMem_arready),
    .io_dmaMem_araddr(dmaMem_araddr), .io_dmaMem_arid(dmaMem_arid),
    .io_dmaMem_arlen(dmaMem_arlen), .io_dmaMem_arsize(dmaMem_arsize),
    .io_dmaMem_arburst(dmaMem_arburst), .io_dmaMem_arcache(dmaMem_arcache),
    .io_dmaMem_arprot(dmaMem_arprot),
    .io_dmaMem_rvalid(dmaMem_rvalid), .io_dmaMem_rready(dmaMem_rready),
    .io_dmaMem_rdata(dmaMem_rdata), .io_dmaMem_rid(dmaMem_rid),
    .io_dmaMem_rresp(dmaMem_rresp), .io_dmaMem_rlast(dmaMem_rlast),

    .io_loadMode(1'b0), .io_loadActive(glue_loadActive),
    .io_sd_sck(glue_sd_sck), .io_sd_mosi(glue_sd_mosi), .io_sd_miso(1'b1),
    .io_sd_cs_n(glue_sd_cs_n), .io_cpuReset(glue_cpuReset),
    // Phase-2c 新增：本装置不跑装载通路 ⇒ SD-DMA strap 钉 0（= 老通路），喂流按 `SdLoader` 的门恒静默
    .io_sdDmaMode(1'b0),
    .io_dmaWrValid(), .io_dmaWrData(), .io_dmaWrReady(1'b0),
    .io_sd_state(glue_sd_state), .io_sd_err(glue_sd_err),
    .io_sd_dbg(glue_sd_dbg), .io_sd_dbg2(glue_sd_dbg2)
  );

  // ===========================================================================
  // DUT②：DmaEngine（DMA CSR 从口 + AXI4 内存主口；原网表，一字不改）
  // ===========================================================================
  DmaEngine u_dma(
    .clk(clock), .reset(reset),
    .irq(dma_irq),

    .axilite_aw_valid(dmaAxi_awvalid), .axilite_aw_ready(dmaAxi_awready),
    .axilite_aw_payload_addr(dmaAxi_awaddr), .axilite_aw_payload_prot(dmaAxi_awprot),
    .axilite_w_valid(dmaAxi_wvalid), .axilite_w_ready(dmaAxi_wready),
    .axilite_w_payload_data(dmaAxi_wdata), .axilite_w_payload_strb(dmaAxi_wstrb),
    .axilite_b_valid(dmaAxi_bvalid), .axilite_b_ready(dmaAxi_bready),
    .axilite_b_payload_resp(dmaAxi_bresp),
    .axilite_ar_valid(dmaAxi_arvalid), .axilite_ar_ready(dmaAxi_arready),
    .axilite_ar_payload_addr(dmaAxi_araddr), .axilite_ar_payload_prot(dmaAxi_arprot),
    .axilite_r_valid(dmaAxi_rvalid), .axilite_r_ready(dmaAxi_rready),
    .axilite_r_payload_data(dmaAxi_rdata), .axilite_r_payload_resp(dmaAxi_rresp),

    .axi_aw_valid(dmaMem_awvalid), .axi_aw_ready(dmaMem_awready),
    .axi_aw_payload_addr(dmaMem_awaddr), .axi_aw_payload_id(dmaMem_awid),
    .axi_aw_payload_len(dmaMem_awlen), .axi_aw_payload_size(dmaMem_awsize),
    .axi_aw_payload_burst(dmaMem_awburst), .axi_aw_payload_cache(dmaMem_awcache),
    .axi_aw_payload_prot(dmaMem_awprot),
    .axi_w_valid(dmaMem_wvalid), .axi_w_ready(dmaMem_wready),
    .axi_w_payload_data(dmaMem_wdata), .axi_w_payload_strb(dmaMem_wstrb),
    .axi_w_payload_last(dmaMem_wlast),
    .axi_b_valid(dmaMem_bvalid), .axi_b_ready(dmaMem_bready),
    .axi_b_payload_id(dmaMem_bid), .axi_b_payload_resp(dmaMem_bresp),
    .axi_ar_valid(dmaMem_arvalid), .axi_ar_ready(dmaMem_arready),
    .axi_ar_payload_addr(dmaMem_araddr), .axi_ar_payload_id(dmaMem_arid),
    .axi_ar_payload_len(dmaMem_arlen), .axi_ar_payload_size(dmaMem_arsize),
    .axi_ar_payload_burst(dmaMem_arburst), .axi_ar_payload_cache(dmaMem_arcache),
    .axi_ar_payload_prot(dmaMem_arprot),
    .axi_r_valid(dmaMem_rvalid), .axi_r_ready(dmaMem_rready),
    .axi_r_payload_data(dmaMem_rdata), .axi_r_payload_id(dmaMem_rid),
    .axi_r_payload_resp(dmaMem_rresp), .axi_r_payload_last(dmaMem_rlast),

    // 每通道流口（本装置只测 COPY ⇒ 结构化空闲）
    .rd_valid_0(), .rd_valid_1(),
    .rd_ready_0(1'b0), .rd_ready_1(1'b0),
    .rd_data_0(), .rd_data_1(),
    .wr_valid_0(1'b0), .wr_valid_1(1'b0),
    .wr_ready_0(), .wr_ready_1(),
    .wr_data_0(64'b0), .wr_data_1(64'b0)
  );

  // ---------------- 观测透出 ----------------
  assign obs_dma_irq          = dma_irq;
  assign obs_dmaAxi_awvalid   = dmaAxi_awvalid;
  assign obs_dmaAxi_awaddr    = dmaAxi_awaddr;
  assign obs_dmaAxi_awready   = dmaAxi_awready;
  assign obs_dmaAxi_wvalid    = dmaAxi_wvalid;
  assign obs_dmaAxi_wready    = dmaAxi_wready;
  assign obs_dmaAxi_bvalid    = dmaAxi_bvalid;
  assign obs_dmaAxi_bresp     = dmaAxi_bresp;
  assign obs_dmaAxi_arvalid   = dmaAxi_arvalid;
  assign obs_dmaAxi_araddr    = dmaAxi_araddr;
  assign obs_dmaAxi_arready   = dmaAxi_arready;
  assign obs_dmaAxi_rvalid    = dmaAxi_rvalid;
  assign obs_dmaAxi_rready    = dmaAxi_rready;
  assign obs_dmaAxi_rdata     = dmaAxi_rdata;
  assign obs_dmaAxi_rresp     = dmaAxi_rresp;

  // ---- 诊断：内存主口握手 + glue 内部 owner/memRdBusy（层次引用只作证据，不改 RTL）----
  assign obs_dmaMem_arvalid = dmaMem_arvalid;
  assign obs_dmaMem_arready = dmaMem_arready;
  assign obs_dmaMem_rvalid  = dmaMem_rvalid;
  assign obs_dmaMem_rready  = dmaMem_rready;
  assign obs_dmaMem_rlast   = dmaMem_rlast;
  assign obs_dmaMem_awvalid = dmaMem_awvalid;
  assign obs_dmaMem_awready = dmaMem_awready;
  assign obs_dmaMem_wvalid  = dmaMem_wvalid;
  assign obs_dmaMem_wready  = dmaMem_wready;
  assign obs_dmaMem_bvalid  = dmaMem_bvalid;
  assign obs_dmaMem_bready  = dmaMem_bready;
  assign obs_glue_owner     = u_glue.owner;
  assign obs_glue_memRdBusy = u_glue.memRdBusy;

endmodule
