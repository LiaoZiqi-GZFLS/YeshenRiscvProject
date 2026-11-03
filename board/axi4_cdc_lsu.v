// axi4_cdc_lsu —— LSU L1 全 AXI4 主口的 dual-clock 桥（64-bit data）。
// 源侧 = VexiiRiscv（cpu_clk），目的侧 = YeshenSocGlue（soc_clk）。
// 五个通道各自一个 dcfifo：AW/W/AR 源→目的，B/R 目的→源。无 ID。
module axi4_cdc_lsu (
    input  wire        sclk,
    input  wire        srst,
    input  wire        dclk,
    input  wire        drst,

    // ---- source (CPU master) ----
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_awaddr,
    input  wire [7:0]  s_awlen,
    input  wire [2:0]  s_awsize,
    input  wire [1:0]  s_awburst,
    input  wire [3:0]  s_awcache,
    input  wire [2:0]  s_awprot,

    input  wire        s_wvalid,
    output wire        s_wready,
    input  wire [63:0] s_wdata,
    input  wire [7:0]  s_wstrb,
    input  wire        s_wlast,

    output wire        s_bvalid,
    input  wire        s_bready,
    output wire [1:0]  s_bresp,

    input  wire        s_arvalid,
    output wire        s_arready,
    input  wire [31:0] s_araddr,
    input  wire [7:0]  s_arlen,
    input  wire [2:0]  s_arsize,
    input  wire [1:0]  s_arburst,
    input  wire [3:0]  s_arcache,
    input  wire [2:0]  s_arprot,

    output wire        s_rvalid,
    input  wire        s_rready,
    output wire [63:0] s_rdata,
    output wire [1:0]  s_rresp,
    output wire        s_rlast,

    // ---- destination (SoC slave) ----
    output wire        d_awvalid,
    input  wire        d_awready,
    output wire [31:0] d_awaddr,
    output wire [7:0]  d_awlen,
    output wire [2:0]  d_awsize,
    output wire [1:0]  d_awburst,
    output wire [3:0]  d_awcache,
    output wire [2:0]  d_awprot,

    output wire        d_wvalid,
    input  wire        d_wready,
    output wire [63:0] d_wdata,
    output wire [7:0]  d_wstrb,
    output wire        d_wlast,

    input  wire        d_bvalid,
    output wire        d_bready,
    input  wire [1:0]  d_bresp,

    output wire        d_arvalid,
    input  wire        d_arready,
    output wire [31:0] d_araddr,
    output wire [7:0]  d_arlen,
    output wire [2:0]  d_arsize,
    output wire [1:0]  d_arburst,
    output wire [3:0]  d_arcache,
    output wire [2:0]  d_arprot,

    input  wire        d_rvalid,
    output wire        d_rready,
    input  wire [63:0] d_rdata,
    input  wire [1:0]  d_rresp,
    input  wire        d_rlast
);
    // ---------------- AW: CPU -> SoC ----------------
    wire [51:0] aw_din  = {s_awaddr, s_awlen, s_awsize, s_awburst, s_awcache, s_awprot};
    wire [51:0] aw_dout;
    wire        aw_full, aw_empty;
    dcfifo #(.WIDTH(52), .AW(4)) u_aw (
        .sclk (sclk), .srst (srst), .sdin (aw_din),  .swr (s_awvalid), .sfull (aw_full),
        .dclk (dclk), .drst (drst), .dout (aw_dout), .drd (d_awready), .dempty(aw_empty)
    );
    assign s_awready = ~aw_full;
    assign d_awvalid = ~aw_empty;
    assign {d_awaddr, d_awlen, d_awsize, d_awburst, d_awcache, d_awprot} = aw_dout;

    // ---------------- W: CPU -> SoC ----------------
    wire [72:0] w_din  = {s_wdata, s_wstrb, s_wlast};
    wire [72:0] w_dout;
    wire        w_full, w_empty;
    dcfifo #(.WIDTH(73), .AW(4)) u_w (
        .sclk (sclk), .srst (srst), .sdin (w_din),  .swr (s_wvalid), .sfull (w_full),
        .dclk (dclk), .drst (drst), .dout (w_dout), .drd (d_wready), .dempty(w_empty)
    );
    assign s_wready = ~w_full;
    assign d_wvalid = ~w_empty;
    assign {d_wdata, d_wstrb, d_wlast} = w_dout;

    // ---------------- B: SoC -> CPU ----------------
    wire [1:0] b_din = d_bresp;
    wire [1:0] b_dout;
    wire       b_full, b_empty;
    dcfifo #(.WIDTH(2), .AW(2)) u_b (
        .sclk (dclk), .srst (drst), .sdin (b_din),  .swr (d_bvalid), .sfull (b_full),
        .dclk (sclk), .drst (srst), .dout (b_dout), .drd (s_bready), .dempty(b_empty)
    );
    assign d_bready = ~b_full;
    assign s_bvalid = ~b_empty;
    assign s_bresp  = b_dout;

    // ---------------- AR: CPU -> SoC ----------------
    wire [51:0] ar_din  = {s_araddr, s_arlen, s_arsize, s_arburst, s_arcache, s_arprot};
    wire [51:0] ar_dout;
    wire        ar_full, ar_empty;
    dcfifo #(.WIDTH(52), .AW(4)) u_ar (
        .sclk (sclk), .srst (srst), .sdin (ar_din),  .swr (s_arvalid), .sfull (ar_full),
        .dclk (dclk), .drst (drst), .dout (ar_dout), .drd (d_arready), .dempty(ar_empty)
    );
    assign s_arready = ~ar_full;
    assign d_arvalid = ~ar_empty;
    assign {d_araddr, d_arlen, d_arsize, d_arburst, d_arcache, d_arprot} = ar_dout;

    // ---------------- R: SoC -> CPU ----------------
    wire [66:0] r_din  = {d_rdata, d_rresp, d_rlast};
    wire [66:0] r_dout;
    wire        r_full, r_empty;
    dcfifo #(.WIDTH(67), .AW(4)) u_r (
        .sclk (dclk), .srst (drst), .sdin (r_din),  .swr (d_rvalid), .sfull (r_full),
        .dclk (sclk), .drst (srst), .dout (r_dout), .drd (s_rready), .dempty(r_empty)
    );
    assign d_rready = ~r_full;
    assign s_rvalid = ~r_empty;
    assign {s_rdata, s_rresp, s_rlast} = r_dout;
endmodule
