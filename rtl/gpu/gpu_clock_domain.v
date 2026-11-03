// gpu_clock_domain.v —— GPU 独立时钟域的**唯一**入口：把整个 `gpu_top` 连同三处对外接口
// 一起搬到 `gpu_clk`，对外端口与 `gpu_top` **逐字一致**（外加两路时钟/复位）。
//
// 为什么要有这一层（用户裁决 2026-11-01：「我希望后面GPU还是要有单独时钟，方便后续优化」）：
//   gpu10 PnR 里 **soc_clk 的头号路径就在 `u_soc/u_gpu/u_2d`**（blend → 减法 → APM 乘法
//   → 加法树，9.574ns / est 104.4496MHz，slack 仅 +0.426）。GPU 不该给整个 SoC 的主频封顶，
//   提 gpu_clk 时也不该被 SoC 侧逻辑拖住。⇒ 整块搬进独立域，两个方向都解耦。
//   本档 gpu_clk = **100.000MHz（与 soc_clk 同频）**：改时钟域这一步要求**零行为变化**，
//   提频是独立的下一次 PnR（pll_gpu.v 文件头列了 112.5/120/125/133.3 四个格点）。
//
// 跨域清单（只有这三处，全部有桥/同步器）：
//   (a) **寄存器窗**（AXI4-Lite，soc 从 → gpu 主）：`gpu_axil_cdc`（五座 dcfifo）；
//   (b) **DDR 主口**（AXI4，gpu 源 → soc 目的）：`gpu_mem_cdc`（五座 dcfifo，W/R 深度 32）；
//   (c) **显示握手**：
//        · `vsync` 输入是 **soc 域电平（每读一帧翻转一次）** —— 电平跨域，gpu 域 2FF 后
//          取"异或沿"出单拍脉冲（**不能用脉冲跨域**：gpu_clk 慢于 soc_clk 时会漏采）；
//        · `flip_toggle` 是 gpu 域电平 → soc 域 2FF 后输出（同样靠电平，不靠脉冲）。
//   (d) **复位**：gpu 域 = 异步置位 / gpu_clk 同步释放；异步源 = `async_rst | soc_rst`
//       ⇒ **gpu 域的释放永远不早于 soc 域**，保证两座桥的 dcfifo 不会"一侧先跑"。
//
// ⚠️ `gpu_top` 本身**一行未改**（所有单元闸门仍按单时钟直接例化它）；改时钟域的影响面
//    被收在本文件 + 两座桥里。
module gpu_clock_domain (
    // ---- 时钟 / 复位 ----
    input  wire        soc_clk,
    input  wire        soc_rst,      // soc 域同步、高有效（= glue_reset）
    input  wire        async_rst,    // 板级异步、高有效（与 soc_rst 同源；作 gpu 域异步置位）
    input  wire        gpu_clk,      // GPU 独立时钟（板级第五颗 GPLL，见 board/pll_gpu.v）

    // ---- 寄存器窗从口（soc_clk；← glue.io_gpuAxi_*）----
    input  wire [11:0] s_awaddr,
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wvalid,
    output wire        s_wready,
    output wire        s_bvalid,
    input  wire        s_bready,
    input  wire [11:0] s_araddr,
    input  wire        s_arvalid,
    output wire        s_arready,
    output wire [31:0] s_rdata,
    output wire        s_rvalid,
    input  wire        s_rready,

    // ---- DDR 主口（soc_clk；→ glue.io_gpuMem_*）----
    output wire [31:0] m_araddr,
    output wire [7:0]  m_arlen,
    output wire [2:0]  m_arsize,
    output wire [1:0]  m_arburst,
    output wire        m_arvalid,
    input  wire        m_arready,
    input  wire [63:0] m_rdata,
    input  wire [1:0]  m_rresp,
    input  wire        m_rlast,
    input  wire        m_rvalid,
    output wire        m_rready,
    output wire [31:0] m_awaddr,
    output wire [7:0]  m_awlen,
    output wire [2:0]  m_awsize,
    output wire [1:0]  m_awburst,
    output wire        m_awvalid,
    input  wire        m_awready,
    output wire [63:0] m_wdata,
    output wire [7:0]  m_wstrb,
    output wire        m_wlast,
    output wire        m_wvalid,
    input  wire        m_wready,
    input  wire [1:0]  m_bresp,
    input  wire        m_bvalid,
    output wire        m_bready,

    // ---- 显示（soc_clk 侧电平）----
    input  wire        vsync,        // 每读一帧翻转一次（电平，非脉冲）
    output wire        flip_toggle   // 0=bank0 1=bank1（电平）
);

  // =====================================================================
  // 复位：gpu 域异步置位 / gpu_clk 同步释放（异步源含 soc_rst ⇒ 释放不早于 soc 域）
  // =====================================================================
  wire gpu_async_rst = async_rst | soc_rst;

  reg [1:0] gpu_rst_sync;
  always @(posedge gpu_clk or posedge gpu_async_rst) begin
    if (gpu_async_rst) gpu_rst_sync <= 2'b11;
    else               gpu_rst_sync <= {gpu_rst_sync[0], 1'b0};
  end
  wire gpu_rst = gpu_rst_sync[1];

  // =====================================================================
  // (c) 显示握手：都走**电平**，脉冲只在本域内产生
  // =====================================================================
  reg vs1, vs2;
  always @(posedge gpu_clk or posedge gpu_async_rst) begin
    if (gpu_async_rst) begin vs1 <= 1'b0; vs2 <= 1'b0; end
    else               begin vs1 <= vsync; vs2 <= vs1; end
  end
  wire vsync_pulse = vs1 ^ vs2;

  wire flip_gpu;

  reg fl1, fl2;
  always @(posedge soc_clk or posedge async_rst) begin
    if (async_rst) begin fl1 <= 1'b0; fl2 <= 1'b0; end
    else           begin fl1 <= flip_gpu; fl2 <= fl1; end
  end
  assign flip_toggle = fl2;

  // =====================================================================
  // (a) 寄存器窗跨域
  // =====================================================================
  wire [11:0] ax_awaddr;
  wire        ax_awvalid, ax_awready;
  wire [31:0] ax_wdata, ax_rdata;
  wire [3:0]  ax_wstrb;
  wire        ax_wvalid, ax_wready;
  wire        ax_bvalid, ax_bready;
  wire [1:0]  ax_bresp, ax_rresp;
  wire [11:0] ax_araddr;
  wire        ax_arvalid, ax_arready;
  wire        ax_rvalid, ax_rready;

  gpu_axil_cdc u_axil_cdc (
      .s_clk (soc_clk), .s_rst (soc_rst),
      .m_clk (gpu_clk), .m_rst (gpu_rst),

      .s_awaddr (s_awaddr), .s_awvalid (s_awvalid), .s_awready (s_awready),
      .s_wdata  (s_wdata),  .s_wstrb   (s_wstrb),   .s_wvalid  (s_wvalid), .s_wready (s_wready),
      .s_bvalid (s_bvalid), .s_bready  (s_bready),  .s_bresp   (),
      .s_araddr (s_araddr), .s_arvalid (s_arvalid), .s_arready (s_arready),
      .s_rdata  (s_rdata),  .s_rvalid  (s_rvalid),  .s_rready  (s_rready), .s_rresp (),

      .m_awaddr (ax_awaddr), .m_awvalid (ax_awvalid), .m_awready (ax_awready),
      .m_wdata  (ax_wdata),  .m_wstrb   (ax_wstrb),   .m_wvalid  (ax_wvalid), .m_wready (ax_wready),
      .m_bvalid (ax_bvalid), .m_bready  (ax_bready),  .m_bresp   (ax_bresp),
      .m_araddr (ax_araddr), .m_arvalid (ax_arvalid), .m_arready (ax_arready),
      .m_rdata  (ax_rdata),  .m_rvalid  (ax_rvalid),  .m_rready  (ax_rready), .m_rresp (ax_rresp)
  );

  // =====================================================================
  // (b) DDR 主口跨域
  // =====================================================================
  wire [31:0] mm_araddr, mm_awaddr;
  wire [7:0]  mm_arlen, mm_awlen;
  wire [2:0]  mm_arsize, mm_awsize;
  wire [1:0]  mm_arburst, mm_awburst;
  wire        mm_arvalid, mm_arready, mm_awvalid, mm_awready;
  wire [63:0] mm_rdata, mm_wdata;
  wire [1:0]  mm_rresp, mm_bresp;
  wire        mm_rlast, mm_rvalid, mm_rready;
  wire [7:0]  mm_wstrb;
  wire        mm_wlast, mm_wvalid, mm_wready;
  wire        mm_bvalid, mm_bready;

  gpu_mem_cdc u_mem_cdc (
      .s_clk (gpu_clk), .s_rst (gpu_rst),
      .d_clk (soc_clk), .d_rst (soc_rst),

      .s_awaddr (mm_awaddr), .s_awlen  (mm_awlen),  .s_awsize (mm_awsize), .s_awburst (mm_awburst),
      .s_awvalid(mm_awvalid), .s_awready(mm_awready),
      .s_wdata  (mm_wdata),  .s_wstrb  (mm_wstrb),  .s_wlast  (mm_wlast),
      .s_wvalid (mm_wvalid), .s_wready (mm_wready),
      .s_bvalid (mm_bvalid), .s_bready (mm_bready), .s_bresp  (mm_bresp),
      .s_araddr (mm_araddr), .s_arlen  (mm_arlen),  .s_arsize (mm_arsize), .s_arburst (mm_arburst),
      .s_arvalid(mm_arvalid), .s_arready(mm_arready),
      .s_rdata  (mm_rdata),  .s_rresp  (mm_rresp),  .s_rlast  (mm_rlast),
      .s_rvalid (mm_rvalid), .s_rready (mm_rready),

      .d_awaddr (m_awaddr), .d_awlen  (m_awlen),  .d_awsize (m_awsize), .d_awburst (m_awburst),
      .d_awcache(        ), .d_awprot (        ),
      .d_awvalid(m_awvalid), .d_awready(m_awready),
      .d_wdata  (m_wdata),  .d_wstrb  (m_wstrb),  .d_wlast  (m_wlast),
      .d_wvalid (m_wvalid), .d_wready (m_wready),
      .d_bvalid (m_bvalid), .d_bready (m_bready), .d_bresp  (m_bresp),
      .d_araddr (m_araddr), .d_arlen  (m_arlen),  .d_arsize (m_arsize), .d_arburst (m_arburst),
      .d_arcache(        ), .d_arprot (        ),
      .d_arvalid(m_arvalid), .d_arready(m_arready),
      .d_rdata  (m_rdata),  .d_rresp  (m_rresp),  .d_rlast  (m_rlast),
      .d_rvalid (m_rvalid), .d_rready (m_rready)
  );

  // =====================================================================
  // 引擎（**整块在 gpu_clk**）
  // =====================================================================
  gpu_top u_gpu (
      .clk (gpu_clk), .rst (gpu_rst),

      .s_awaddr (ax_awaddr), .s_awvalid (ax_awvalid), .s_awready (ax_awready),
      .s_wdata  (ax_wdata),  .s_wstrb   (ax_wstrb),   .s_wvalid  (ax_wvalid), .s_wready (ax_wready),
      .s_bvalid (ax_bvalid), .s_bready  (ax_bready),
      .s_araddr (ax_araddr), .s_arvalid (ax_arvalid), .s_arready (ax_arready),
      .s_rdata  (ax_rdata),  .s_rvalid  (ax_rvalid),  .s_rready  (ax_rready),

      .m_araddr (mm_araddr), .m_arlen (mm_arlen), .m_arsize (mm_arsize), .m_arburst (mm_arburst),
      .m_arvalid(mm_arvalid), .m_arready(mm_arready),
      .m_rdata  (mm_rdata),  .m_rresp (mm_rresp), .m_rlast (mm_rlast),
      .m_rvalid (mm_rvalid), .m_rready(mm_rready),

      .m_awaddr (mm_awaddr), .m_awlen (mm_awlen), .m_awsize (mm_awsize), .m_awburst (mm_awburst),
      .m_awvalid(mm_awvalid), .m_awready(mm_awready),
      .m_wdata  (mm_wdata),  .m_wstrb (mm_wstrb), .m_wlast (mm_wlast),
      .m_wvalid (mm_wvalid), .m_wready(mm_wready),
      .m_bresp  (mm_bresp),  .m_bvalid(mm_bvalid), .m_bready(mm_bready),

      .vsync (vsync_pulse), .flip_toggle (flip_gpu)
  );

endmodule
