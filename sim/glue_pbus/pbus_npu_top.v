// =============================================================================
// pbus_npu_top —— glue_pbus 装置专属的「最小 SoC 头」：把 NPU 寄存器窗的**真实从口**
//                 （`y1/gen/HostRegs.v`）接到 `YeshenSocGlue` 的 `io_npuAxi_*` 主口上。
//
// 为什么需要这个 wrapper（而不是直接 --top-module YeshenSocGlue）：
//   现有装置 `tb_pbus.cpp` 的 top 是 `YeshenSocGlue`，它的 `io_npuAxi_*` 是**顶层的悬空输出**
//   —— 网表里根本没有 HostRegs 实例（板级 `board/yeshen_mini_soc.v` 才把 glue.io_npuAxi 接到
//   `NpuTop.axilite_*`）。要判「CPU→glue→NPU 寄存器窗写通路是否真的通」，必须把 NPU 侧的
//   AxiLite4 从口也拉进同一个 Verilator 网表里 —— 否则读 ID(0x30) 不可能读回常数 0x594E5031
//   （那是 HostRegs 的活体证明，写死在它内部）。
//
//   本 wrapper 只做两件事：
//     ① 实例化 `YeshenSocGlue`（原样，不动），把它的 `io_npuAxi_*` 主口
//        **逐根**接到 `HostRegs` 的 `axilite_*` 从口（= 板级那一段接线的等价物）；
//     ② 把 glue 的其它输入按「静默」口径钉死（cpuFetch/cpuLsu 不发起、npuMem 不发起、
//        loadMode=0、uart_rxd=1、sd_miso=1、ethIrq=0、npuIrq=0、gpio_in=0），
//        把 TB 要驱动的口（cpuIo / mem / ethAxi）原样透出，把要观测的口透出。
//
//   HostRegs 的 `sched_busy/done/err` 钉 0（本装置只测寄存器窗，不跑调度器）；
//   读回口 `desc_count/desc_addr/img_w/start` 透出，作为「写到底落没落进寄存器」的铁证。
//
// ⚠️ 纪律：本文件是 `sim/glue_pbus/**` 的**新增件**（装置侧），**不是 RTL**；
//    两个被实例化的网表（rtl/YeshenSocGlue.v、y1/gen/HostRegs.v）都只读、一字不改。
// =============================================================================
`timescale 1ns/1ps

module pbus_npu_top(
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

  // ---------- 内存从口（本装置建模：永远 ready + 单拍 B/R=OKAY，只为防挂死） ----------
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
  output        io_intMSoft,
  // glue ↔ HostRegs 的 NPU 寄存器窗握手（现场证据：AW/W 什么时候同时被举、awready/wready 何时才肯回）
  output        obs_npuAxi_awvalid,
  output [31:0] obs_npuAxi_awaddr,
  output        obs_npuAxi_awready,
  output        obs_npuAxi_wvalid,
  output        obs_npuAxi_wready,
  output        obs_npuAxi_bvalid,
  output        obs_npuAxi_bresp,
  output        obs_npuAxi_arvalid,
  output [31:0] obs_npuAxi_araddr,
  output        obs_npuAxi_arready,
  output        obs_npuAxi_rvalid,
  output [31:0] obs_npuAxi_rdata,
  output [1:0]  obs_npuAxi_rresp,
  // HostRegs 寄存器读回（写到底落没落进寄存器）
  output [31:0] obs_hreg_desc_count,
  output [31:0] obs_hreg_desc_addr,
  output [31:0] obs_hreg_img_w,
  output        obs_hreg_start,

  // ---------- 反事实探针（诊断用，非 DUT 功能）----------
  // 0 = 与板级**逐字一致**的接线（把 glue 送来的**整根**地址直给 HostRegs）；
  // 1 = 把地址剥到 16 KiB 窗内偏移（`addr[13:0]`）再给 HostRegs。
  // 用途：区分「通路死了是因为地址基址没被剥掉」还是「因为别的（AW/W 时序/译码）」。
  input         probe_strip_base
);

  // ---------------- glue ↔ HostRegs 之间的 NPU 寄存器窗连线 ----------------
  wire        npuAxi_awvalid;
  wire        npuAxi_awready;
  wire [31:0] npuAxi_awaddr;
  wire [2:0]  npuAxi_awprot;
  wire        npuAxi_wvalid;
  wire        npuAxi_wready;
  wire [31:0] npuAxi_wdata;
  wire [3:0]  npuAxi_wstrb;
  wire        npuAxi_bvalid;
  wire        npuAxi_bready;
  wire [1:0]  npuAxi_bresp;
  wire        npuAxi_arvalid;
  wire        npuAxi_arready;
  wire [31:0] npuAxi_araddr;
  wire [2:0]  npuAxi_arprot;
  wire        npuAxi_rvalid;
  wire        npuAxi_rready;
  wire [31:0] npuAxi_rdata;
  wire [1:0]  npuAxi_rresp;

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

  // ---------------- HostRegs 读回 ----------------
  wire [31:0] hreg_img_w, hreg_img_h, hreg_c_in, hreg_c_out, hreg_group;
  wire [31:0] hreg_src_addr, hreg_dst_addr, hreg_qshift, hreg_layer_id;
  wire [31:0] hreg_desc_addr, hreg_desc_count;
  wire        hreg_start, hreg_soft_reset, hreg_busy, hreg_done, hreg_done_sticky, hreg_err;
  wire        hreg_kstride, hreg_kpad;

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
    .io_intMTime(glue_intMTime), .io_intMSoft(io_intMSoft),
    .io_intMExt(glue_intMExt), .io_intSExt(glue_intSExt),

    .io_ethIrq(1'b0),
    .io_npuIrq(1'b0),

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

    // ★ NPU 寄存器窗主口 → HostRegs 从口（本 wrapper 的接线核心）
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
    // Phase-2c 新增的端口：本装置不跑装载通路 ⇒ SD-DMA strap 钉 0（老通路），喂流结构化空闲
    .io_sdDmaMode(1'b0),
    .io_dmaWrValid(), .io_dmaWrData(), .io_dmaWrReady(1'b0),
    .io_sd_state(glue_sd_state), .io_sd_err(glue_sd_err),
    .io_sd_dbg(glue_sd_dbg), .io_sd_dbg2(glue_sd_dbg2)
  );

  // ===========================================================================
  // DUT②：HostRegs（NPU 寄存器窗的真实 AxiLite4 从口；原网表，一字不改）
  // ===========================================================================
  // ⚠️ 地址口径（本案的现场证据）：HostRegs 是 AxiLite4SlaveFactory 生成的**基址 0** 从口
  //    —— 它内部 `bus_*AddressMasked = addr & ~3` 后直接与 0x00..0x38 比较，**不剥窗基址**。
  //    而 glue（`io.npuAxi.araddr := pR`，见 src/YeshenSocGlue.scala:621/628）与板级
  //    （board/yeshen_mini_soc.v:735/746）都把**整根** SoC 地址递下来。⇒ 下面这一根直连
  //    就是**板级等价接线**（probe_strip_base=0）。
  //    探针 probe_strip_base=1 时改喂 `addr[13:0]`（16 KiB 窗内偏移）——用来证明「唯一的问题
  //    就是基址没剥、不是 AW/W 时序」。
  wire [31:0] hreg_awaddr = probe_strip_base ? {18'h0, npuAxi_awaddr[13:0]} : npuAxi_awaddr;
  wire [31:0] hreg_araddr = probe_strip_base ? {18'h0, npuAxi_araddr[13:0]} : npuAxi_araddr;

  HostRegs u_hregs(
    .axilite_aw_valid(npuAxi_awvalid), .axilite_aw_ready(npuAxi_awready),
    .axilite_aw_payload_addr(hreg_awaddr), .axilite_aw_payload_prot(npuAxi_awprot),
    .axilite_w_valid(npuAxi_wvalid), .axilite_w_ready(npuAxi_wready),
    .axilite_w_payload_data(npuAxi_wdata), .axilite_w_payload_strb(npuAxi_wstrb),
    .axilite_b_valid(npuAxi_bvalid), .axilite_b_ready(npuAxi_bready),
    .axilite_b_payload_resp(npuAxi_bresp),
    .axilite_ar_valid(npuAxi_arvalid), .axilite_ar_ready(npuAxi_arready),
    .axilite_ar_payload_addr(hreg_araddr), .axilite_ar_payload_prot(npuAxi_arprot),
    .axilite_r_valid(npuAxi_rvalid), .axilite_r_ready(npuAxi_rready),
    .axilite_r_payload_data(npuAxi_rdata), .axilite_r_payload_resp(npuAxi_rresp),
    .sched_busy(1'b0), .sched_done(1'b0), .sched_err(1'b0),
    .start(hreg_start), .soft_reset(hreg_soft_reset), .busy(hreg_busy),
    .done(hreg_done), .done_sticky(hreg_done_sticky), .err(hreg_err),
    .img_w(hreg_img_w), .img_h(hreg_img_h), .c_in(hreg_c_in), .c_out(hreg_c_out),
    .group_1(hreg_group), .kernel_stride(hreg_kstride), .kernel_pad(hreg_kpad),
    .src_addr(hreg_src_addr), .dst_addr(hreg_dst_addr), .quant_shift(hreg_qshift),
    .layer_id(hreg_layer_id), .desc_addr(hreg_desc_addr), .desc_count(hreg_desc_count),
    .clk(clock), .reset(reset)
  );

  // ---------------- 观测透出 ----------------
  assign obs_npuAxi_awvalid = npuAxi_awvalid;
  assign obs_npuAxi_awaddr  = npuAxi_awaddr;
  assign obs_npuAxi_awready = npuAxi_awready;
  assign obs_npuAxi_wvalid  = npuAxi_wvalid;
  assign obs_npuAxi_wready  = npuAxi_wready;
  assign obs_npuAxi_bvalid  = npuAxi_bvalid;
  assign obs_npuAxi_bresp   = npuAxi_bresp;
  assign obs_npuAxi_arvalid = npuAxi_arvalid;
  assign obs_npuAxi_araddr  = npuAxi_araddr;
  assign obs_npuAxi_arready = npuAxi_arready;
  assign obs_npuAxi_rvalid  = npuAxi_rvalid;
  assign obs_npuAxi_rdata   = npuAxi_rdata;
  assign obs_npuAxi_rresp   = npuAxi_rresp;

  assign obs_hreg_desc_count = hreg_desc_count;
  assign obs_hreg_desc_addr  = hreg_desc_addr;
  assign obs_hreg_img_w      = hreg_img_w;
  assign obs_hreg_start      = hreg_start;

endmodule
