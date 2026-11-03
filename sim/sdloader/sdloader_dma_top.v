// =============================================================================
// sdloader_dma_top —— Y1-DMA Phase-2c 的装置头：**SD 装载器当 DMA 引擎的第一个真客户**。
//
// 与 sim/glue_pbus/pbus_dma_top.v 同因同构（那里判的是"CPU 编程的 DMA"）：本 wrapper 把两个
// **只读网表**装进同一个 Verilator 模型并使二者"板级那样"互连：
//   · `rtl/YeshenSocGlue.v`（内含 SdLoader + SdSpi；一字不改）
//   · `y1/gen/DmaEngine.v`（一字不改）
//
// 三根承重接线（装置侧新增，对应板级的同一段）：
//   ① `glue.io_dmaAxi_*`（CSR 窗主口）↔ `DmaEngine.axilite_*` —— 装载期由 glue **内部**把
//      这根窗主口让给 `SdLoader` 的 CSR 小主口（见 `YeshenSocGlue.scala` §3 的 `sdDmaCsr` 选通）；
//   ② `glue.io_dmaMem_*`（内存主口从方）↔ `DmaEngine.axi_*` —— 引擎的写突发汇入 §3.5 第 6 个主人；
//   ③ `glue.io_dmaWrValid/dmaWrData`（喂流）→ `DmaEngine.wr_valid_0/wr_data_0`、
//      `glue.io_dmaWrReady` ← `DmaEngine.wr_ready_0`（通道 0 = SD 装载器；通道 1 = 网络留口）。
//
// `io_sdDmaMode`（strap）是**两条通路的选择**，装置靠它在一份镜像上跑两次、逐字节比：
//   · =0 ⇒ 装载器**直写内存**（Phase-2b 及以前的行为；`io.mem` 由 glue 的"装载器分支"驱动）
//   · =1 ⇒ 装载器**喂引擎**（`io.mem` 由 §3.5 的 DMA 类驱动）
// 板上恒接 1（新通路），装置里来回切（D3 判据的承重开关）。
//
// ⚠️ 纪律：本文件是 `sim/sdloader/**` 的**装置侧新增件**（不是 RTL）；两个被实例化的网表都只读。
// =============================================================================
`timescale 1ns/1ps

module sdloader_dma_top(
  input         clock,
  input         reset,

  // ---------- 装载链 strap + TF 卡 SPI 引脚（本装置驱动卡模型）----------
  input         io_loadMode,
  input  [31:0] io_bootTimeout,
  input         io_sdDmaMode,
  output        io_sd_sck,
  output        io_sd_mosi,
  input         io_sd_miso,
  output        io_sd_cs_n,

  // ---------- 内存从口（glue 是主方；本装置建模真 64bit INCR 内存，见 tb_sdloader_dma.cpp）----------
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
  output [1:0]  io_mem_aw_awlock,
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

  // ---------- 观测（只读）----------
  output [3:0]  obs_sd_state,
  output [3:0]  obs_sd_err,
  output [31:0] obs_sd_dbg2,
  output        obs_loadActive,
  output        obs_cpuReset,
  output        obs_dma_irq,
  // §3.5 的 owner（4bit）：通路 B 应看到 7（OWN_DMA_WR）；通路 A 应恒 0（装载器绕过 §3.5）
  output [3:0]  obs_glue_owner,
  // CSR 窗主口的握手（证据：通路 B 上装载器真的在编程引擎；通路 A 上恒 0）
  output        obs_dmaAxi_awvalid,
  output [31:0] obs_dmaAxi_awaddr,
  output        obs_dmaAxi_awready,
  output [31:0] obs_dmaAxi_wdata,
  output        obs_dmaAxi_wvalid,
  output        obs_dmaAxi_wready,
  output [31:0] obs_dmaAxi_araddr,
  output        obs_dmaAxi_arvalid,
  output        obs_dmaAxi_arready,
  output        obs_dmaAxi_rvalid,
  output [31:0] obs_dmaAxi_rdata,
  // 喂流端口（证据：通路 B 上引擎真的在 WSTR 态举 ready / 装载器真的在举 valid）
  output        obs_wrValid0,
  output        obs_wrReady0,
  // 诊断：glue ↔ DmaEngine 内存主口握手 + §3.5 的内部量（层次引用只作证据，不改 RTL）
  output        obs_dmaMem_awvalid,
  output        obs_dmaMem_awready,
  output        obs_dmaMem_wvalid,
  output        obs_dmaMem_wready,
  output        obs_dmaMem_bvalid,
  output        obs_dmaMem_bready,
  output        obs_glue_memRdBusy
);

  // ---------------- glue ↔ DmaEngine 的连线 ----------------
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
  wire        glue_dmaWrValid, glue_dmaWrReady;
  wire [63:0] glue_dmaWrData;

  // ---------------- 被观测/被丢弃的 glue 输出 ----------------
  wire [63:0] glue_rdtime;
  wire        glue_intMTime, glue_intMSoft, glue_intMExt, glue_intSExt, glue_irq, glue_uart_txd;
  wire        glue_loadActive, glue_cpuReset;
  wire [7:0]  glue_gpio_out, glue_gpio_dir;
  wire [3:0]  glue_sd_state, glue_sd_err;
  wire [31:0] glue_sd_dbg, glue_sd_dbg2;
  wire        g_cpuFetch_arready, g_cpuFetch_rvalid;
  wire [63:0] g_cpuFetch_rdata;
  wire [1:0]  g_cpuFetch_rresp;
  wire        g_cpuFetch_rlast;
  wire        g_cpuLsu_awready, g_cpuLsu_wready, g_cpuLsu_bvalid, g_cpuLsu_arready;
  wire        g_cpuLsu_rvalid;
  wire [63:0] g_cpuLsu_rdata;
  wire [1:0]  g_cpuLsu_rresp;
  wire        g_cpuLsu_rlast;
  wire        g_cpuIo_awready, g_cpuIo_wready, g_cpuIo_bvalid, g_cpuIo_arready, g_cpuIo_rvalid;
  wire [31:0] g_cpuIo_rdata;
  wire [1:0]  g_cpuIo_bresp, g_cpuIo_rresp;
  wire        g_cpuIo_rlast;
  wire        g_npuMem_awready, g_npuMem_wready, g_npuMem_bvalid, g_npuMem_arready;
  wire        g_npuMem_rvalid, g_npuMem_rlast;
  wire [3:0]  g_npuMem_bid, g_npuMem_rid;
  wire [1:0]  g_npuMem_bresp, g_npuMem_rresp;
  wire [63:0] g_npuMem_rdata;
  wire        g_npuAxi_awvalid, g_npuAxi_wvalid, g_npuAxi_arvalid;
  wire [31:0] g_npuAxi_awaddr, g_npuAxi_wdata, g_npuAxi_araddr;
  wire [2:0]  g_npuAxi_awprot, g_npuAxi_arprot;
  wire [3:0]  g_npuAxi_wstrb;
  wire        g_npuAxi_bready, g_npuAxi_rready;
  wire        g_ethAxi_awvalid, g_ethAxi_wvalid, g_ethAxi_bready, g_ethAxi_arvalid, g_ethAxi_rready;
  wire [31:0] g_ethAxi_awaddr, g_ethAxi_wdata, g_ethAxi_araddr;
  wire [2:0]  g_ethAxi_awprot, g_ethAxi_arprot;
  wire [3:0]  g_ethAxi_wstrb;

  // ===========================================================================
  // DUT①：YeshenSocGlue（原网表，一字不改）
  // ===========================================================================
  YeshenSocGlue u_glue(
    .clock(clock), .reset(reset),

    // ---- CPU 三个内存/外设主口：本装置不发起（装载期 CPU 被扣复位 ⇒ 结构性静默）----
    .io_cpuFetch_arvalid(1'b0), .io_cpuFetch_arready(g_cpuFetch_arready),
    .io_cpuFetch_araddr(32'h0), .io_cpuFetch_arlen(8'h0), .io_cpuFetch_arsize(3'h0),
    .io_cpuFetch_arburst(2'h1), .io_cpuFetch_arcache(4'h0), .io_cpuFetch_arprot(3'h0),
    .io_cpuFetch_rvalid(g_cpuFetch_rvalid), .io_cpuFetch_rready(1'b0),
    .io_cpuFetch_rdata(g_cpuFetch_rdata), .io_cpuFetch_rresp(g_cpuFetch_rresp),
    .io_cpuFetch_rlast(g_cpuFetch_rlast),

    .io_cpuLsu_awvalid(1'b0), .io_cpuLsu_awready(g_cpuLsu_awready),
    .io_cpuLsu_awaddr(32'h0), .io_cpuLsu_awlen(8'h0), .io_cpuLsu_awsize(3'h0),
    .io_cpuLsu_awburst(2'h1), .io_cpuLsu_awcache(4'h0), .io_cpuLsu_awprot(3'h0),
    .io_cpuLsu_wvalid(1'b0), .io_cpuLsu_wready(g_cpuLsu_wready),
    .io_cpuLsu_wdata(64'h0), .io_cpuLsu_wstrb(8'h0), .io_cpuLsu_wlast(1'b0),
    .io_cpuLsu_bvalid(g_cpuLsu_bvalid), .io_cpuLsu_bready(1'b0), .io_cpuLsu_bresp(),
    .io_cpuLsu_arvalid(1'b0), .io_cpuLsu_arready(g_cpuLsu_arready),
    .io_cpuLsu_araddr(32'h0), .io_cpuLsu_arlen(8'h0), .io_cpuLsu_arsize(3'h0),
    .io_cpuLsu_arburst(2'h1), .io_cpuLsu_arcache(4'h0), .io_cpuLsu_arprot(3'h0),
    .io_cpuLsu_rvalid(g_cpuLsu_rvalid), .io_cpuLsu_rready(1'b0),
    .io_cpuLsu_rdata(g_cpuLsu_rdata), .io_cpuLsu_rresp(g_cpuLsu_rresp),
    .io_cpuLsu_rlast(g_cpuLsu_rlast),

    .io_cpuIo_awvalid(1'b0), .io_cpuIo_awready(g_cpuIo_awready),
    .io_cpuIo_awaddr(32'h0), .io_cpuIo_awsize(3'h2), .io_cpuIo_awcache(4'h0),
    .io_cpuIo_awprot(3'h0),
    .io_cpuIo_wvalid(1'b0), .io_cpuIo_wready(g_cpuIo_wready),
    .io_cpuIo_wdata(32'h0), .io_cpuIo_wstrb(4'hF), .io_cpuIo_wlast(1'b1),
    .io_cpuIo_bvalid(g_cpuIo_bvalid), .io_cpuIo_bready(1'b1), .io_cpuIo_bresp(g_cpuIo_bresp),
    .io_cpuIo_arvalid(1'b0), .io_cpuIo_arready(g_cpuIo_arready),
    .io_cpuIo_araddr(32'h0), .io_cpuIo_arsize(3'h2), .io_cpuIo_arcache(4'h0),
    .io_cpuIo_arprot(3'h0),
    .io_cpuIo_rvalid(g_cpuIo_rvalid), .io_cpuIo_rready(1'b1),
    .io_cpuIo_rdata(g_cpuIo_rdata), .io_cpuIo_rresp(g_cpuIo_rresp), .io_cpuIo_rlast(g_cpuIo_rlast),

    .io_rdtime(glue_rdtime),
    .io_intMTime(glue_intMTime), .io_intMSoft(glue_intMSoft),
    .io_intMExt(glue_intMExt), .io_intSExt(glue_intSExt),

    .io_ethIrq(1'b0), .io_npuIrq(1'b0), .io_dmaIrq(dma_irq),

    // ---- NPU 内存主口：本装置不发起（全静默）----
    .io_npuMem_awvalid(1'b0), .io_npuMem_awready(g_npuMem_awready),
    .io_npuMem_awaddr(28'h0), .io_npuMem_awid(4'h0), .io_npuMem_awlen(8'h0),
    .io_npuMem_awsize(3'h0), .io_npuMem_awburst(2'h1), .io_npuMem_awcache(4'h0),
    .io_npuMem_awprot(3'h0),
    .io_npuMem_wvalid(1'b0), .io_npuMem_wready(g_npuMem_wready),
    .io_npuMem_wdata(64'h0), .io_npuMem_wstrb(8'h0), .io_npuMem_wlast(1'b0),
    .io_npuMem_bvalid(g_npuMem_bvalid), .io_npuMem_bready(1'b0),
    .io_npuMem_bid(g_npuMem_bid), .io_npuMem_bresp(g_npuMem_bresp),
    .io_npuMem_arvalid(1'b0), .io_npuMem_arready(g_npuMem_arready),
    .io_npuMem_araddr(28'h0), .io_npuMem_arid(4'h0), .io_npuMem_arlen(8'h0),
    .io_npuMem_arsize(3'h0), .io_npuMem_arburst(2'h1), .io_npuMem_arcache(4'h0),
    .io_npuMem_arprot(3'h0),
    .io_npuMem_rvalid(g_npuMem_rvalid), .io_npuMem_rready(1'b0),
    .io_npuMem_rdata(g_npuMem_rdata), .io_npuMem_rid(g_npuMem_rid),
    .io_npuMem_rresp(g_npuMem_rresp), .io_npuMem_rlast(g_npuMem_rlast),

    // ---- 内存/ETH 从口（本装置建模）----
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
    .io_gpio_in(8'h0), .io_gpio_out(glue_gpio_out), .io_gpio_dir(glue_gpio_dir),
    .io_irq(glue_irq),

    // ---- ETH 从口：永远 ready + 不产生响应（本装置不驱动它的主方 ⇒ 结构性无事务）----
    .io_ethAxi_awvalid(g_ethAxi_awvalid), .io_ethAxi_awready(1'b1),
    .io_ethAxi_awaddr(g_ethAxi_awaddr), .io_ethAxi_awprot(g_ethAxi_awprot),
    .io_ethAxi_wvalid(g_ethAxi_wvalid), .io_ethAxi_wready(1'b1),
    .io_ethAxi_wdata(g_ethAxi_wdata), .io_ethAxi_wstrb(g_ethAxi_wstrb),
    .io_ethAxi_bvalid(1'b0), .io_ethAxi_bready(g_ethAxi_bready), .io_ethAxi_bresp(2'h0),
    .io_ethAxi_arvalid(g_ethAxi_arvalid), .io_ethAxi_arready(1'b1),
    .io_ethAxi_araddr(g_ethAxi_araddr), .io_ethAxi_arprot(g_ethAxi_arprot),
    .io_ethAxi_rvalid(1'b0), .io_ethAxi_rready(g_ethAxi_rready),
    .io_ethAxi_rdata(32'h0), .io_ethAxi_rresp(2'h0),

    // ---- NPU 寄存器窗主口：同理（glue 是主方；不产生事务）----
    .io_npuAxi_awvalid(g_npuAxi_awvalid), .io_npuAxi_awready(1'b1),
    .io_npuAxi_awaddr(g_npuAxi_awaddr), .io_npuAxi_awprot(g_npuAxi_awprot),
    .io_npuAxi_wvalid(g_npuAxi_wvalid), .io_npuAxi_wready(1'b1),
    .io_npuAxi_wdata(g_npuAxi_wdata), .io_npuAxi_wstrb(g_npuAxi_wstrb),
    .io_npuAxi_bvalid(1'b0), .io_npuAxi_bready(g_npuAxi_bready), .io_npuAxi_bresp(2'h0),
    .io_npuAxi_arvalid(g_npuAxi_arvalid), .io_npuAxi_arready(1'b1),
    .io_npuAxi_araddr(g_npuAxi_araddr), .io_npuAxi_arprot(g_npuAxi_arprot),
    .io_npuAxi_rvalid(1'b0), .io_npuAxi_rready(g_npuAxi_rready),
    .io_npuAxi_rdata(32'h0), .io_npuAxi_rresp(2'h0),

    // ★ DMA 寄存器窗主口 → DmaEngine.axilite_*（接线核心之一；装载期 glue 内部让给 SdLoader）
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

    // ★ DMA 内存主口 ← DmaEngine.axi_*（接线核心之二；汇入 §3.5 汇聚点）
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

    // ★ 装载链 + 喂流（接线核心之三）
    .io_loadMode(io_loadMode), .io_bootTimeout(io_bootTimeout), .io_loadActive(glue_loadActive),
    .io_sd_sck(io_sd_sck), .io_sd_mosi(io_sd_mosi), .io_sd_miso(io_sd_miso),
    .io_sd_cs_n(io_sd_cs_n), .io_cpuReset(glue_cpuReset),
    .io_sdDmaMode(io_sdDmaMode),
    .io_dmaWrValid(glue_dmaWrValid), .io_dmaWrData(glue_dmaWrData),
    .io_dmaWrReady(glue_dmaWrReady),
    .io_sd_state(glue_sd_state), .io_sd_err(glue_sd_err),
    .io_sd_dbg(glue_sd_dbg), .io_sd_dbg2(glue_sd_dbg2)
  );

  // ===========================================================================
  // DUT②：DmaEngine（CSR 从口 + AXI4 内存主口；原网表，一字不改）
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

    // 通道 0 = SD 装载器（WR 模式：从 wr_stream 灌、写 DDR）；通道 1 = 网络留口（本相空闲）
    .rd_valid_0(), .rd_valid_1(),
    .rd_ready_0(1'b0), .rd_ready_1(1'b0),
    .rd_data_0(), .rd_data_1(),
    .wr_valid_0(glue_dmaWrValid), .wr_valid_1(1'b0),
    .wr_ready_0(glue_dmaWrReady), .wr_ready_1(),
    .wr_data_0(glue_dmaWrData), .wr_data_1(64'b0)
  );

  // ---------------- 观测透出 ----------------
  assign obs_sd_state       = glue_sd_state;
  assign obs_sd_err         = glue_sd_err;
  assign obs_sd_dbg2        = glue_sd_dbg2;
  assign obs_loadActive     = glue_loadActive;
  assign obs_cpuReset       = glue_cpuReset;
  assign obs_dma_irq        = dma_irq;
  assign obs_glue_owner     = u_glue.owner;      // 层次引用（只作证据，不改 RTL）
  assign obs_dmaAxi_awvalid = dmaAxi_awvalid;
  assign obs_dmaAxi_awaddr  = dmaAxi_awaddr;
  assign obs_dmaAxi_awready = dmaAxi_awready;
  assign obs_dmaAxi_wdata   = dmaAxi_wdata;
  assign obs_dmaAxi_wvalid  = dmaAxi_wvalid;
  assign obs_dmaAxi_wready  = dmaAxi_wready;
  assign obs_dmaAxi_araddr  = dmaAxi_araddr;
  assign obs_dmaAxi_arvalid = dmaAxi_arvalid;
  assign obs_dmaAxi_arready = dmaAxi_arready;
  assign obs_dmaAxi_rvalid  = dmaAxi_rvalid;
  assign obs_dmaAxi_rdata   = dmaAxi_rdata;
  assign obs_wrValid0       = glue_dmaWrValid;
  assign obs_wrReady0       = glue_dmaWrReady;
  assign obs_dmaMem_awvalid = dmaMem_awvalid;
  assign obs_dmaMem_awready = dmaMem_awready;
  assign obs_dmaMem_wvalid  = dmaMem_wvalid;
  assign obs_dmaMem_wready  = dmaMem_wready;
  assign obs_dmaMem_bvalid  = dmaMem_bvalid;
  assign obs_dmaMem_bready  = dmaMem_bready;
  assign obs_glue_memRdBusy = u_glue.memRdBusy;

endmodule
