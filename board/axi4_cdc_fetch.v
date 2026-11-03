// axi4_cdc_fetch —— Fetch L1 只读 AXI4 主口的 dual-clock 桥。
// 源侧 = VexiiRiscv（cpu_clk），目的侧 = YeshenSocGlue（soc_clk）。
// AR: 源→目的；R: 目的→源。无 ID，无乱序。每通道一个 dcfifo（depth 16）。
module axi4_cdc_fetch (
    input  wire        sclk,
    input  wire        srst,
    input  wire        dclk,
    input  wire        drst,

    // ---- source (CPU master) ----
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
