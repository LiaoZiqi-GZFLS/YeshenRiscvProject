// gpu_unit_top.v —— GPU 端点级闸门的装置外壳：YeshenSocGlue + gpu_top + 64-bit AXI RAM 模型。
//
// 为什么要多这一层：`tb_pbus.cpp` 只把 `io_gpuAxi_*` 当"窗内偏移转发口"来测（从方是常量替身），
//   测不到"CSR → 命令 FIFO → 2D 引擎 → gpu_mem → MemArbiter 第 4 主口 → io_mem"这条全链。
//   本外壳把真 `gpu_top` 接到胶合块上，内存侧用 `sim/gpu/axi_ram_model.v`（同一份模型，AW 加宽到 21），
//   CPU 侧只留 pIo 主口 + 一个 vsync 脉冲口 + 内存窥视口给 C++ 装置驱动。
//
// 其余从方一律"永远 ready / 不主动发"的静态替身：本装置只关心 GPU 这一条路。
module gpu_unit_top (
    input  wire        clock,
    input  wire        reset,

    // CPU 单拍 AXI-Lite 主口（TB 驱动；对到 glue 的 io_cpuIo_*）
    input  wire        p_awvalid,
    output wire        p_awready,
    input  wire [31:0] p_awaddr,
    input  wire [2:0]  p_awsize,
    input  wire [3:0]  p_awcache,
    input  wire [2:0]  p_awprot,
    input  wire        p_wvalid,
    output wire        p_wready,
    input  wire [31:0] p_wdata,
    input  wire [3:0]  p_wstrb,
    input  wire        p_wlast,
    output wire        p_bvalid,
    input  wire        p_bready,
    output wire [1:0]  p_bresp,
    input  wire        p_arvalid,
    output wire        p_arready,
    input  wire [31:0] p_araddr,
    input  wire [2:0]  p_arsize,
    input  wire [3:0]  p_arcache,
    input  wire [2:0]  p_arprot,
    output wire        p_rvalid,
    input  wire        p_rready,
    output wire [31:0] p_rdata,
    output wire [1:0]  p_rresp,
    output wire        p_rlast,

    // 显示侧：TB 给一个 vsync 脉冲；flip_toggle 接出来看
    input  wire        vsync,
    output wire        flip_toggle,

    // 内存窥视（ram 模型的调试口）
    input  wire [20:0] dbg_idx,
    output wire [63:0] dbg_word,
    output wire [31:0] mem_aw_count,
    output wire [31:0] mem_w_count,
    output wire [31:0] mem_ar_count
);

  // ---------------- GPU：CSR 从口 ← glue.io_gpuAxi_*，DDR 主口 ↔ glue.io_gpuMem_* ----------------
  wire        gpu_awvalid, gpu_awready, gpu_wvalid, gpu_wready, gpu_bvalid, gpu_bready;
  wire [31:0] gpu_awaddr, gpu_wdata;
  wire [2:0]  gpu_awprot;
  wire [3:0]  gpu_wstrb;
  wire [1:0]  gpu_bresp;
  wire        gpu_arvalid, gpu_arready, gpu_rvalid, gpu_rready;
  wire [31:0] gpu_araddr, gpu_rdata;
  wire [2:0]  gpu_arprot;
  wire [1:0]  gpu_rresp;

  wire [31:0] gm_araddr, gm_awaddr;
  wire [7:0]  gm_arlen, gm_awlen;
  wire [2:0]  gm_arsize, gm_awsize;
  wire [1:0]  gm_arburst, gm_awburst;
  wire        gm_arvalid, gm_arready, gm_awvalid, gm_awready;
  wire [63:0] gm_rdata, gm_wdata;
  wire [1:0]  gm_rresp, gm_bresp;
  wire        gm_rlast, gm_rvalid, gm_rready;
  wire [7:0]  gm_wstrb;
  wire        gm_wlast, gm_wvalid, gm_wready, gm_bvalid, gm_bready;

  // AXI-Lite 主口位宽差异：glue 的 io_gpuAxi_*addr 是 32 位（高 20 位恒 0），gpu_top 只吃窗内 12 位
  wire [11:0] gpu_awaddr12 = gpu_awaddr[11:0];
  wire [11:0] gpu_araddr12 = gpu_araddr[11:0];

  gpu_top u_gpu (
      .clk(clock), .rst(reset),
      .s_awaddr(gpu_awaddr12), .s_awvalid(gpu_awvalid), .s_awready(gpu_awready),
      .s_wdata(gpu_wdata), .s_wstrb(gpu_wstrb), .s_wvalid(gpu_wvalid), .s_wready(gpu_wready),
      .s_bvalid(gpu_bvalid), .s_bready(gpu_bready),
      .s_araddr(gpu_araddr12), .s_arvalid(gpu_arvalid), .s_arready(gpu_arready),
      .s_rdata(gpu_rdata), .s_rvalid(gpu_rvalid), .s_rready(gpu_rready),

      .m_araddr(gm_araddr), .m_arlen(gm_arlen), .m_arsize(gm_arsize), .m_arburst(gm_arburst),
      .m_arvalid(gm_arvalid), .m_arready(gm_arready),
      .m_rdata(gm_rdata), .m_rresp(gm_rresp), .m_rlast(gm_rlast), .m_rvalid(gm_rvalid),
      .m_rready(gm_rready),

      .m_awaddr(gm_awaddr), .m_awlen(gm_awlen), .m_awsize(gm_awsize), .m_awburst(gm_awburst),
      .m_awvalid(gm_awvalid), .m_awready(gm_awready),
      .m_wdata(gm_wdata), .m_wstrb(gm_wstrb), .m_wlast(gm_wlast), .m_wvalid(gm_wvalid),
      .m_wready(gm_wready),
      .m_bresp(gm_bresp), .m_bvalid(gm_bvalid), .m_bready(gm_bready),

      .vsync(vsync), .flip_toggle(flip_toggle)
  );

  // ---------------- 内存模型：2 MiB（AW=21）----------------
  wire [31:0] m_araddr, m_awaddr;
  wire [7:0]  m_arlen, m_awlen;
  wire        m_arvalid, m_arready, m_awvalid, m_awready;
  wire [63:0] m_rdata, m_wdata;
  wire [7:0]  m_wstrb;
  wire        m_wlast, m_wvalid, m_wready, m_rlast, m_rvalid, m_rready, m_bvalid, m_bready;
  wire [1:0]  m_bresp;
  wire [31:0] m_aw_count, m_w_count, m_ar_count;

  axi_ram_model #(.AW(21), .INIT_FILE("")) u_ram (
      .clk(clock), .rst(reset),
      .araddr(m_araddr), .arlen(m_arlen), .arvalid(m_arvalid), .arready(m_arready),
      .rdata(m_rdata), .rlast(m_rlast), .rvalid(m_rvalid), .rready(m_rready),
      .awaddr(m_awaddr), .awlen(m_awlen), .awvalid(m_awvalid), .awready(m_awready),
      .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast), .wvalid(m_wvalid), .wready(m_wready),
      .bresp(m_bresp), .bvalid(m_bvalid), .bready(m_bready),
      .aw_count(m_aw_count), .w_count(m_w_count), .ar_count(m_ar_count),
      .dbg_idx(dbg_idx), .dbg_word(dbg_word),
      .dbg_bvalid(), .dbg_wactive(), .dbg_wleft()
  );

  assign mem_aw_count = m_aw_count;
  assign mem_w_count  = m_w_count;
  assign mem_ar_count = m_ar_count;

  // ---------------- 胶合块 ----------------
  YeshenSocGlue u_glue (
      .clock(clock),
      // CPU 取指/访存两条内存主口：本装置不发起
      .io_cpuFetch_arready(  ),
      .io_cpuFetch_araddr(32'd0), .io_cpuFetch_arlen(8'd0), .io_cpuFetch_arsize(3'd0),
      .io_cpuFetch_arburst(2'd1), .io_cpuFetch_arcache(4'd0), .io_cpuFetch_arprot(3'd0),
      .io_cpuFetch_rready(1'b0),
      .io_cpuFetch_rvalid(), .io_cpuFetch_rdata(), .io_cpuFetch_rresp(), .io_cpuFetch_rlast(),
      .io_cpuLsu_awvalid(1'b0), .io_cpuLsu_awready(), .io_cpuLsu_awaddr(32'd0),
      .io_cpuLsu_awlen(8'd0), .io_cpuLsu_awsize(3'd0), .io_cpuLsu_awburst(2'd1),
      .io_cpuLsu_awcache(4'd0), .io_cpuLsu_awprot(3'd0),
      .io_cpuLsu_wvalid(1'b0), .io_cpuLsu_wready(), .io_cpuLsu_wdata(64'd0),
      .io_cpuLsu_wstrb(8'd0), .io_cpuLsu_wlast(1'b0),
      .io_cpuLsu_bvalid(), .io_cpuLsu_bready(1'b0), .io_cpuLsu_bresp(),
      .io_cpuLsu_arvalid(1'b0), .io_cpuLsu_arready(), .io_cpuLsu_araddr(32'd0),
      .io_cpuLsu_arlen(8'd0), .io_cpuLsu_arsize(3'd0), .io_cpuLsu_arburst(2'd1),
      .io_cpuLsu_arcache(4'd0), .io_cpuLsu_arprot(3'd0),
      .io_cpuLsu_rvalid(), .io_cpuLsu_rready(1'b0), .io_cpuLsu_rdata(),
      .io_cpuLsu_rresp(), .io_cpuLsu_rlast(),
      // CPU 外设主口（本装置唯一驱动的主口）
      .io_cpuIo_awvalid(p_awvalid), .io_cpuIo_awready(p_awready), .io_cpuIo_awaddr(p_awaddr),
      .io_cpuIo_awsize(p_awsize), .io_cpuIo_awcache(p_awcache), .io_cpuIo_awprot(p_awprot),
      .io_cpuIo_wvalid(p_wvalid), .io_cpuIo_wready(p_wready), .io_cpuIo_wdata(p_wdata),
      .io_cpuIo_wstrb(p_wstrb), .io_cpuIo_wlast(p_wlast),
      .io_cpuIo_bvalid(p_bvalid), .io_cpuIo_bready(p_bready), .io_cpuIo_bresp(p_bresp),
      .io_cpuIo_arvalid(p_arvalid), .io_cpuIo_arready(p_arready), .io_cpuIo_araddr(p_araddr),
      .io_cpuIo_arsize(p_arsize), .io_cpuIo_arcache(p_arcache), .io_cpuIo_arprot(p_arprot),
      .io_cpuIo_rvalid(p_rvalid), .io_cpuIo_rready(p_rready), .io_cpuIo_rdata(p_rdata),
      .io_cpuIo_rresp(p_rresp), .io_cpuIo_rlast(p_rlast),
      .io_rdtime(), .io_intMTime(), .io_ethIrq(1'b0),
      // NPU / DMA 内存主口：不发起
      .io_npuMem_awready(), .io_npuMem_awaddr(28'd0), .io_npuMem_awid(4'd0),
      .io_npuMem_awlen(8'd0), .io_npuMem_awsize(3'd0), .io_npuMem_awburst(2'd1),
      .io_npuMem_awcache(4'd0), .io_npuMem_awprot(3'd0),
      .io_npuMem_wvalid(1'b0), .io_npuMem_wready(), .io_npuMem_wdata(64'd0),
      .io_npuMem_wstrb(8'd0), .io_npuMem_wlast(1'b0),
      .io_npuMem_bvalid(), .io_npuMem_bready(1'b0), .io_npuMem_bid(), .io_npuMem_bresp(),
      .io_npuMem_arvalid(1'b0), .io_npuMem_arready(), .io_npuMem_araddr(28'd0),
      .io_npuMem_arid(4'd0), .io_npuMem_arlen(8'd0), .io_npuMem_arsize(3'd0),
      .io_npuMem_arburst(2'd1), .io_npuMem_arcache(4'd0), .io_npuMem_arprot(3'd0),
      .io_npuMem_rvalid(), .io_npuMem_rready(1'b0), .io_npuMem_rdata(),
      .io_npuMem_rid(), .io_npuMem_rresp(), .io_npuMem_rlast(),
      .io_dmaMem_awvalid(1'b0), .io_dmaMem_awready(), .io_dmaMem_awaddr(30'd0), .io_dmaMem_awid(4'd0),
      .io_dmaMem_awlen(8'd0), .io_dmaMem_awsize(3'd0), .io_dmaMem_awburst(2'd1),
      .io_dmaMem_awcache(4'd0), .io_dmaMem_awprot(3'd0),
      .io_dmaMem_wvalid(1'b0), .io_dmaMem_wready(), .io_dmaMem_wdata(64'd0),
      .io_dmaMem_wstrb(8'd0), .io_dmaMem_wlast(1'b0),
      .io_dmaMem_bvalid(), .io_dmaMem_bready(1'b0), .io_dmaMem_bid(), .io_dmaMem_bresp(),
      .io_dmaMem_arvalid(1'b0), .io_dmaMem_arready(), .io_dmaMem_araddr(30'd0),
      .io_dmaMem_arid(4'd0), .io_dmaMem_arlen(8'd0), .io_dmaMem_arsize(3'd0),
      .io_dmaMem_arburst(2'd1), .io_dmaMem_arcache(4'd0), .io_dmaMem_arprot(3'd0),
      .io_dmaMem_rvalid(), .io_dmaMem_rready(1'b0), .io_dmaMem_rdata(),
      .io_dmaMem_rid(), .io_dmaMem_rresp(), .io_dmaMem_rlast(),
      // 汇聚后的内存主口 → RAM 模型
      .io_mem_ar_arid(), .io_mem_ar_araddr(m_araddr), .io_mem_ar_arlen(m_arlen),
      .io_mem_ar_arsize(), .io_mem_ar_arburst(), .io_mem_ar_arlock(), .io_mem_ar_arcache(),
      .io_mem_ar_arprot(), .io_mem_ar_arvalid(m_arvalid), .io_mem_ar_arready(m_arready),
      .io_mem_r_rid(4'd0), .io_mem_r_rdata(m_rdata), .io_mem_r_rresp(m_rresp),
      .io_mem_r_rlast(m_rlast), .io_mem_r_rvalid(m_rvalid), .io_mem_r_rready(m_rready),
      .io_mem_aw_awid(), .io_mem_aw_awaddr(m_awaddr), .io_mem_aw_awlen(m_awlen),
      .io_mem_aw_awsize(), .io_mem_aw_awburst(), .io_mem_aw_awcache(), .io_mem_aw_awprot(),
      .io_mem_aw_awvalid(m_awvalid), .io_mem_aw_awready(m_awready),
      .io_mem_w_wid(), .io_mem_w_wdata(m_wdata), .io_mem_w_wstrb(m_wstrb),
      .io_mem_w_wlast(m_wlast), .io_mem_w_wvalid(m_wvalid), .io_mem_w_wready(m_wready),
      .io_mem_b_bid(4'd0), .io_mem_b_bresp(m_bresp), .io_mem_b_bvalid(m_bvalid),
      .io_mem_b_bready(m_bready),
      // 串口/GPIO/装载
      .io_uart_rxd(1'b1), .io_gpio_in(13'd0), .io_gpio_out(), .io_irq(),
      // ETH / NPU / DMA / VIDEO 的 AXI-Lite 从方：永远 ready 的静态替身
      .io_ethAxi_awready(1'b1), .io_ethAxi_awaddr(), .io_ethAxi_awprot(),
      .io_ethAxi_wvalid(), .io_ethAxi_wready(1'b1), .io_ethAxi_wdata(), .io_ethAxi_wstrb(),
      .io_ethAxi_bvalid(1'b0), .io_ethAxi_bready(), .io_ethAxi_bresp(2'd0),
      .io_ethAxi_arvalid(), .io_ethAxi_arready(1'b1), .io_ethAxi_araddr(), .io_ethAxi_arprot(),
      .io_ethAxi_rvalid(1'b0), .io_ethAxi_rready(), .io_ethAxi_rdata(32'd0), .io_ethAxi_rresp(2'd0),
      .io_npuAxi_awvalid(), .io_npuAxi_awready(1'b1), .io_npuAxi_awaddr(), .io_npuAxi_awprot(),
      .io_npuAxi_wvalid(), .io_npuAxi_wready(1'b1), .io_npuAxi_wdata(), .io_npuAxi_wstrb(),
      .io_npuAxi_bvalid(1'b0), .io_npuAxi_bready(), .io_npuAxi_bresp(2'd0),
      .io_npuAxi_arvalid(), .io_npuAxi_arready(1'b1), .io_npuAxi_araddr(), .io_npuAxi_arprot(),
      .io_npuAxi_rvalid(1'b0), .io_npuAxi_rready(), .io_npuAxi_rdata(32'd0), .io_npuAxi_rresp(2'd0),
      .io_dmaAxi_awvalid(), .io_dmaAxi_awready(1'b1), .io_dmaAxi_awaddr(), .io_dmaAxi_awprot(),
      .io_dmaAxi_wvalid(), .io_dmaAxi_wready(1'b1), .io_dmaAxi_wdata(), .io_dmaAxi_wstrb(),
      .io_dmaAxi_bvalid(1'b0), .io_dmaAxi_bready(), .io_dmaAxi_bresp(2'd0),
      .io_dmaAxi_arvalid(), .io_dmaAxi_arready(1'b1), .io_dmaAxi_araddr(), .io_dmaAxi_arprot(),
      .io_dmaAxi_rvalid(1'b0), .io_dmaAxi_rready(), .io_dmaAxi_rdata(32'd0), .io_dmaAxi_rresp(2'd0),
      .io_videoAxi_awvalid(), .io_videoAxi_awready(1'b1), .io_videoAxi_awaddr(), .io_videoAxi_awprot(),
      .io_videoAxi_wvalid(), .io_videoAxi_wready(1'b1), .io_videoAxi_wdata(), .io_videoAxi_wstrb(),
      .io_videoAxi_bvalid(1'b0), .io_videoAxi_bready(), .io_videoAxi_bresp(2'd0),
      .io_videoAxi_arvalid(), .io_videoAxi_arready(1'b1), .io_videoAxi_araddr(), .io_videoAxi_arprot(),
      .io_videoAxi_rvalid(1'b0), .io_videoAxi_rready(), .io_videoAxi_rdata(32'd0), .io_videoAxi_rresp(2'd0),
      // ★ GPU CSR 从口 ↔ gpu_top 的 s_*
      .io_gpuAxi_awvalid(gpu_awvalid), .io_gpuAxi_awready(gpu_awready),
      .io_gpuAxi_awaddr(gpu_awaddr), .io_gpuAxi_awprot(gpu_awprot),
      .io_gpuAxi_wvalid(gpu_wvalid), .io_gpuAxi_wready(gpu_wready),
      .io_gpuAxi_wdata(gpu_wdata), .io_gpuAxi_wstrb(gpu_wstrb),
      .io_gpuAxi_bvalid(gpu_bvalid), .io_gpuAxi_bready(gpu_bready), .io_gpuAxi_bresp(gpu_bresp),
      .io_gpuAxi_arvalid(gpu_arvalid), .io_gpuAxi_arready(gpu_arready),
      .io_gpuAxi_araddr(gpu_araddr), .io_gpuAxi_arprot(gpu_arprot),
      .io_gpuAxi_rvalid(gpu_rvalid), .io_gpuAxi_rready(gpu_rready),
      .io_gpuAxi_rdata(gpu_rdata), .io_gpuAxi_rresp(gpu_rresp),
      // ★ GPU DDR 主口 ↔ gpu_top 的 m_*
      .io_gpuMem_awvalid(gm_awvalid), .io_gpuMem_awready(gm_awready), .io_gpuMem_awaddr(gm_awaddr),
      .io_gpuMem_awlen(gm_awlen), .io_gpuMem_awsize(gm_awsize), .io_gpuMem_awburst(gm_awburst),
      .io_gpuMem_awcache(4'd0), .io_gpuMem_awprot(3'd0),
      .io_gpuMem_wvalid(gm_wvalid), .io_gpuMem_wready(gm_wready), .io_gpuMem_wdata(gm_wdata),
      .io_gpuMem_wstrb(gm_wstrb), .io_gpuMem_wlast(gm_wlast),
      .io_gpuMem_bvalid(gm_bvalid), .io_gpuMem_bready(gm_bready), .io_gpuMem_bresp(gm_bresp),
      .io_gpuMem_arvalid(gm_arvalid), .io_gpuMem_arready(gm_arready), .io_gpuMem_araddr(gm_araddr),
      .io_gpuMem_arlen(gm_arlen), .io_gpuMem_arsize(gm_arsize), .io_gpuMem_arburst(gm_arburst),
      .io_gpuMem_arcache(4'd0), .io_gpuMem_arprot(3'd0),
      .io_gpuMem_rvalid(gm_rvalid), .io_gpuMem_rready(gm_rready), .io_gpuMem_rdata(gm_rdata),
      .io_gpuMem_rresp(gm_rresp), .io_gpuMem_rlast(gm_rlast),
      // 装载链：不激活
      .io_loadMode(1'b0), .io_bootTimeout(32'd0), .io_loadActive(),
      .io_sd_miso(1'b1), .io_sd_cs_n(), .io_sdDmaMode(1'b0),
      .io_dmaWrValid(), .io_dmaWrData(), .io_dmaWrReady(1'b1),
      .io_sd_state(), .io_sd_dbg()
  );

endmodule
