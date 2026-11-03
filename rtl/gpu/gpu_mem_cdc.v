// gpu_mem_cdc.v —— GPU DDR 主口（AXI4，64-bit data / 32-bit addr，**无 ID**）的跨时钟域桥。
//
//   源侧（`s_*`）= **gpu_clk**：接 gpu_top 的 m_*；
//   目的侧（`d_*`）= **soc_clk**：接 glue 的 io_gpuMem_*（MemArbiter 第 4 组，权重最低）。
//
// 结构 = board/axi4_cdc_lsu.v 的同款五 FIFO（AW/W/AR 源→目的，B/R 目的→源），只改两处：
//
//   ① **W / R 的深度 16 → 32（AW=5）**。理由：gpu_mem 会把 8 B 粒度 burst 对齐到板级
//      32 B 块，最坏 `rd_beats(≤15) + pad(≤3)` = **19 拍**；而 glue 的简化 AXI 从口在
//      `rready=0` 时**不保持 rvalid**（gpu_mem 文件头 ★ 记着这条上板实测：BLIT 源少 2 拍）。
//      ⇒ R 侧 FIFO 必须在**一整笔 burst 内永不为满**，否则会丢拍。32 > 19，安全。
//      W 侧同样按 19 拍留量（W 有 `wready` 反压，本来不会丢，但同深度便于对账）。
//   ② 目的侧显式给出 `awcache/awprot/arcache/arprot`（gpu_top 没有这三类输出）：
//      恒 0。**与改动前等价** —— 今天这三根在 yeshen_mini_soc.v 里就是悬空 wire，
//      PDS 综合按 0 处理，板上 2D 判据一直 PASS；这里只是把"隐式 0"写成"显式 0"。
//
// ⚠️ 复位口径同 gpu_axil_cdc.v：两侧指针必须同时被扣住。
module gpu_mem_cdc (
    input  wire        s_clk,
    input  wire        s_rst,       // gpu 域（同步、高有效）
    input  wire        d_clk,
    input  wire        d_rst,       // soc 域（同步、高有效）

    // ---- 源侧：gpu_clk（← gpu_top.m_*）----
    input  wire [31:0] s_awaddr,
    input  wire [7:0]  s_awlen,
    input  wire [2:0]  s_awsize,
    input  wire [1:0]  s_awburst,
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [63:0] s_wdata,
    input  wire [7:0]  s_wstrb,
    input  wire        s_wlast,
    input  wire        s_wvalid,
    output wire        s_wready,
    output wire        s_bvalid,
    input  wire        s_bready,
    output wire [1:0]  s_bresp,
    input  wire [31:0] s_araddr,
    input  wire [7:0]  s_arlen,
    input  wire [2:0]  s_arsize,
    input  wire [1:0]  s_arburst,
    input  wire        s_arvalid,
    output wire        s_arready,
    output wire [63:0] s_rdata,
    output wire [1:0]  s_rresp,
    output wire        s_rlast,
    output wire        s_rvalid,
    input  wire        s_rready,

    // ---- 目的侧：soc_clk（→ glue.io_gpuMem_*）----
    output wire [31:0] d_awaddr,
    output wire [7:0]  d_awlen,
    output wire [2:0]  d_awsize,
    output wire [1:0]  d_awburst,
    output wire [3:0]  d_awcache,
    output wire [2:0]  d_awprot,
    output wire        d_awvalid,
    input  wire        d_awready,
    output wire [63:0] d_wdata,
    output wire [7:0]  d_wstrb,
    output wire        d_wlast,
    output wire        d_wvalid,
    input  wire        d_wready,
    input  wire        d_bvalid,
    output wire        d_bready,
    input  wire [1:0]  d_bresp,
    output wire [31:0] d_araddr,
    output wire [7:0]  d_arlen,
    output wire [2:0]  d_arsize,
    output wire [1:0]  d_arburst,
    output wire [3:0]  d_arcache,
    output wire [2:0]  d_arprot,
    output wire        d_arvalid,
    input  wire        d_arready,
    input  wire [63:0] d_rdata,
    input  wire [1:0]  d_rresp,
    input  wire        d_rlast,
    input  wire        d_rvalid,
    output wire        d_rready
);

  assign d_awcache = 4'd0;
  assign d_awprot  = 3'd0;
  assign d_arcache = 4'd0;
  assign d_arprot  = 3'd0;

  // ---------------- AW ----------------
  wire [44:0] aw_dout;
  wire        aw_full, aw_empty;
  dcfifo #(.WIDTH(45), .AW(3)) u_aw (
      .sclk (s_clk), .srst (s_rst),
      .sdin ({s_awaddr, s_awlen, s_awsize, s_awburst}), .swr (s_awvalid), .sfull (aw_full),
      .dclk (d_clk), .drst (d_rst), .dout (aw_dout),    .drd (d_awready), .dempty (aw_empty)
  );
  assign s_awready = ~aw_full;
  assign d_awvalid = ~aw_empty;
  assign {d_awaddr, d_awlen, d_awsize, d_awburst} = aw_dout;

  // ---------------- W（深度 32，见文件头 ①）----------------
  wire [72:0] w_dout;
  wire        w_full, w_empty;
  dcfifo #(.WIDTH(73), .AW(5)) u_w (
      .sclk (s_clk), .srst (s_rst), .sdin ({s_wdata, s_wstrb, s_wlast}), .swr (s_wvalid), .sfull (w_full),
      .dclk (d_clk), .drst (d_rst), .dout (w_dout),                      .drd (d_wready), .dempty (w_empty)
  );
  assign s_wready = ~w_full;
  assign d_wvalid = ~w_empty;
  assign {d_wdata, d_wstrb, d_wlast} = w_dout;

  // ---------------- B ----------------
  wire [1:0] b_dout;
  wire       b_full, b_empty;
  dcfifo #(.WIDTH(2), .AW(2)) u_b (
      .sclk (d_clk), .srst (d_rst), .sdin (d_bresp), .swr (d_bvalid), .sfull (b_full),
      .dclk (s_clk), .drst (s_rst), .dout (b_dout),  .drd (s_bready), .dempty (b_empty)
  );
  assign d_bready = ~b_full;
  assign s_bvalid = ~b_empty;
  assign s_bresp  = b_dout;

  // ---------------- AR ----------------
  wire [44:0] ar_dout;
  wire        ar_full, ar_empty;
  dcfifo #(.WIDTH(45), .AW(3)) u_ar (
      .sclk (s_clk), .srst (s_rst),
      .sdin ({s_araddr, s_arlen, s_arsize, s_arburst}), .swr (s_arvalid), .sfull (ar_full),
      .dclk (d_clk), .drst (d_rst), .dout (ar_dout),    .drd (d_arready), .dempty (ar_empty)
  );
  assign s_arready = ~ar_full;
  assign d_arvalid = ~ar_empty;
  assign {d_araddr, d_arlen, d_arsize, d_arburst} = ar_dout;

  // ---------------- R（深度 32，见文件头 ①）----------------
  wire [66:0] r_dout;
  wire        r_full, r_empty;
  dcfifo #(.WIDTH(67), .AW(5)) u_r (
      .sclk (d_clk), .srst (d_rst), .sdin ({d_rdata, d_rresp, d_rlast}), .swr (d_rvalid), .sfull (r_full),
      .dclk (s_clk), .drst (s_rst), .dout (r_dout),                      .drd (s_rready), .dempty (r_empty)
  );
  assign d_rready = ~r_full;
  assign s_rvalid = ~r_empty;
  assign {s_rdata, s_rresp, s_rlast} = r_dout;

endmodule
