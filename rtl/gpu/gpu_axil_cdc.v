// gpu_axil_cdc.v —— GPU 寄存器窗（AXI4-Lite）的跨时钟域桥。
//
//   从侧（slave，`s_*`）= **soc_clk**：逐字镜像 gpu_top 的 s_* 端口，接 glue 的 io_gpuAxi_*；
//   主侧（master，`m_*`）= **gpu_clk**：接 gpu_top 的 s_*。
//
// 结构：五个 dcfifo（AW/W/AR 从→主，B/R 主→从），深度 4 —— 与 board/axi4_cdc_lsu.v 同款写法。
//   · 没有 ID、没有 burst（AXI4-Lite），所以每通道就是一个 FIFO，无排序/归并逻辑；
//   · `m_awready` 等由 FIFO 的 full 反相给出（AXI 允许从侧反压主侧）；
//   · **带 prot 吗？** 不带 —— gpu_csr 只吃窗内 12 位偏移，prot 是装饰位（glue 侧也恒 0）。
//     少 3 bit × 2 条通道，省下的都是 FIFO 的触发器。
//
// ⚠️ gpu_csr 的写口要求 **awvalid 与 wvalid 同时有效** 才应答（见 gpu_csr.v `s_awready`）。
//    两座 FIFO 独立 ⇒ 主侧可能出现"只有 AW 没有 W"的窗口：此时 gpu_csr 不应答，
//    AW 停在 FIFO 口（drd 无效）等 W 到齐 —— 不会丢，也不会死锁（W 由同一主机随后发出）。
//
// ⚠️ 复位口径：dcfifo 两侧指针必须**同时**被扣住（各域同步释放可以，但不能一方先跑）。
//    本模块只接收 wrapper 给的 `s_rst` / `m_rst`，两者的异步源相同、m 域释放不早于 s 域
//    （见 gpu_clock_domain.v 的复位段）。
module gpu_axil_cdc (
    input  wire        s_clk,
    input  wire        s_rst,       // 同步、高有效（soc 域）
    input  wire        m_clk,
    input  wire        m_rst,       // 同步、高有效（gpu 域，释放不早于 s_rst）

    // ---- 从侧（soc_clk；← glue.io_gpuAxi_*）----
    input  wire [11:0] s_awaddr,
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wvalid,
    output wire        s_wready,
    output wire        s_bvalid,
    input  wire        s_bready,
    output wire [1:0]  s_bresp,
    input  wire [11:0] s_araddr,
    input  wire        s_arvalid,
    output wire        s_arready,
    output wire [31:0] s_rdata,
    output wire        s_rvalid,
    input  wire        s_rready,
    output wire [1:0]  s_rresp,

    // ---- 主侧（gpu_clk；→ gpu_top.s_*）----
    output wire [11:0] m_awaddr,
    output wire        m_awvalid,
    input  wire        m_awready,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_wstrb,
    output wire        m_wvalid,
    input  wire        m_wready,
    input  wire        m_bvalid,
    output wire        m_bready,
    input  wire [1:0]  m_bresp,
    output wire [11:0] m_araddr,
    output wire        m_arvalid,
    input  wire        m_arready,
    input  wire [31:0] m_rdata,
    input  wire        m_rvalid,
    output wire        m_rready,
    input  wire [1:0]  m_rresp
);

  // ---------------- AW ----------------
  wire [11:0] aw_dout;
  wire        aw_full, aw_empty;
  dcfifo #(.WIDTH(12), .AW(2)) u_aw (
      .sclk (s_clk), .srst (s_rst), .sdin (s_awaddr), .swr (s_awvalid), .sfull (aw_full),
      .dclk (m_clk), .drst (m_rst), .dout (aw_dout),   .drd (m_awready), .dempty (aw_empty)
  );
  assign s_awready = ~aw_full;
  assign m_awvalid = ~aw_empty;
  assign m_awaddr  = aw_dout;

  // ---------------- W ----------------
  wire [35:0] w_dout;
  wire        w_full, w_empty;
  dcfifo #(.WIDTH(36), .AW(2)) u_w (
      .sclk (s_clk), .srst (s_rst), .sdin ({s_wdata, s_wstrb}), .swr (s_wvalid), .sfull (w_full),
      .dclk (m_clk), .drst (m_rst), .dout (w_dout),             .drd (m_wready), .dempty (w_empty)
  );
  assign s_wready = ~w_full;
  assign m_wvalid = ~w_empty;
  assign {m_wdata, m_wstrb} = w_dout;

  // ---------------- B ----------------
  wire [1:0] b_dout;
  wire       b_full, b_empty;
  dcfifo #(.WIDTH(2), .AW(2)) u_b (
      .sclk (m_clk), .srst (m_rst), .sdin (m_bresp), .swr (m_bvalid), .sfull (b_full),
      .dclk (s_clk), .drst (s_rst), .dout (b_dout),  .drd (s_bready), .dempty (b_empty)
  );
  assign m_bready = ~b_full;
  assign s_bvalid = ~b_empty;
  assign s_bresp  = b_dout;

  // ---------------- AR ----------------
  wire [11:0] ar_dout;
  wire        ar_full, ar_empty;
  dcfifo #(.WIDTH(12), .AW(2)) u_ar (
      .sclk (s_clk), .srst (s_rst), .sdin (s_araddr), .swr (s_arvalid), .sfull (ar_full),
      .dclk (m_clk), .drst (m_rst), .dout (ar_dout),   .drd (m_arready), .dempty (ar_empty)
  );
  assign s_arready = ~ar_full;
  assign m_arvalid = ~ar_empty;
  assign m_araddr  = ar_dout;

  // ---------------- R ----------------
  wire [33:0] r_dout;
  wire        r_full, r_empty;
  dcfifo #(.WIDTH(34), .AW(2)) u_r (
      .sclk (m_clk), .srst (m_rst), .sdin ({m_rdata, m_rresp}), .swr (m_rvalid), .sfull (r_full),
      .dclk (s_clk), .drst (s_rst), .dout (r_dout),             .drd (s_rready), .dempty (r_empty)
  );
  assign m_rready = ~r_full;
  assign s_rvalid = ~r_empty;
  assign {s_rdata, s_rresp} = r_dout;

endmodule
