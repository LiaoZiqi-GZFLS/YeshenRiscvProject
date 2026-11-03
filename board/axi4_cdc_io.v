// axi4_cdc_io —— CPU Cacheless IO 口的跨域桥（MMIO 强序版）。
//
// 2026-10-18 板上 Linux 挂死后的重写：
//   旧版用 per-channel FIFO，源侧 ready 只看 FIFO 空间 ⇒ CPU 认为一笔 MMIO 写已
//   完成、立刻发 LSR 读时，读会走另一条 FIFO 先到 glue，UART 控制台写/读次序反转。
//   同频对照也挂死 ⇒ 问题不在 CDC，而在这一“源侧 ready 解耦”。
//
// 本版：
//   · 传输复用 `NpuAxiLiteCdc`（NPU 主机寄存器窗已在板上验证过的 4 相握手 CDC，
//     单 outstanding，enq.ready 只在目的域确认后才放行）；
//   · 源侧加事务锁：一笔读/写完整完成（R 握手 / B 握手）前，不接受下一笔，
//     且读/写互不超车；
//   · IO 口是单拍 32-bit：size/cache 固定为 3'd2/4'd0（glue 的 IO 从口不使用它们），
//     wlast/rlast 固定为 1；prot 原样透传；wstrb 原样透传。
module axi4_cdc_io (
    input  wire        sclk,          // cpu_clk
    input  wire        srst,          // active high
    input  wire        dclk,          // soc_clk
    input  wire        drst,          // active high

    // ---- source (CPU master) ----
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_awaddr,
    input  wire [2:0]  s_awsize,
    input  wire [3:0]  s_awcache,
    input  wire [2:0]  s_awprot,

    input  wire        s_wvalid,
    output wire        s_wready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wlast,

    output wire        s_bvalid,
    input  wire        s_bready,
    output wire [1:0]  s_bresp,

    input  wire        s_arvalid,
    output wire        s_arready,
    input  wire [31:0] s_araddr,
    input  wire [2:0]  s_arsize,
    input  wire [3:0]  s_arcache,
    input  wire [2:0]  s_arprot,

    output wire        s_rvalid,
    input  wire        s_rready,
    output wire [31:0] s_rdata,
    output wire [1:0]  s_rresp,
    output wire        s_rlast,

    // ---- destination (SoC glue slave) ----
    output wire        d_awvalid,
    input  wire        d_awready,
    output wire [31:0] d_awaddr,
    output wire [2:0]  d_awsize,
    output wire [3:0]  d_awcache,
    output wire [2:0]  d_awprot,

    output wire        d_wvalid,
    input  wire        d_wready,
    output wire [31:0] d_wdata,
    output wire [3:0]  d_wstrb,
    output wire        d_wlast,

    input  wire        d_bvalid,
    output wire        d_bready,
    input  wire [1:0]  d_bresp,

    output wire        d_arvalid,
    input  wire        d_arready,
    output wire [31:0] d_araddr,
    output wire [2:0]  d_arsize,
    output wire [3:0]  d_arcache,
    output wire [2:0]  d_arprot,

    input  wire        d_rvalid,
    output wire        d_rready,
    input  wire [31:0] d_rdata,
    input  wire [1:0]  d_rresp,
    input  wire        d_rlast
);
    // ---------------- 源侧事务锁 ----------------
    reg rd_busy, aw_seen, w_seen, wr_busy;

    wire bridge_awready, bridge_wready, bridge_arready;
    wire bridge_bvalid, bridge_rvalid;

    assign s_awready = bridge_awready && !rd_busy && !aw_seen && !wr_busy;
    assign s_wready  = bridge_wready  && !rd_busy && !w_seen  && !wr_busy;
    assign s_arready = bridge_arready && !rd_busy && !aw_seen && !w_seen && !wr_busy;

    wire aw_fire = s_awvalid && s_awready;
    wire w_fire  = s_wvalid  && s_wready;
    wire ar_fire = s_arvalid && s_arready;
    wire b_fire  = s_bvalid  && s_bready;
    wire r_fire  = s_rvalid  && s_rready;

    always @(posedge sclk) begin
        if (srst) begin
            rd_busy <= 1'b0; aw_seen <= 1'b0; w_seen <= 1'b0; wr_busy <= 1'b0;
        end else begin
            if (ar_fire) rd_busy <= 1'b1;
            if (r_fire)  rd_busy <= 1'b0;

            if (aw_fire) aw_seen <= 1'b1;
            if (w_fire)  w_seen  <= 1'b1;
            if (aw_seen && w_seen) wr_busy <= 1'b1;
            if (b_fire) begin
                wr_busy <= 1'b0; aw_seen <= 1'b0; w_seen <= 1'b0;
            end
        end
    end

    // ---------------- 传输：已验证的 4 相 AXI-Lite CDC ----------------
    NpuAxiLiteCdc u_bridge (
        .io_cpuClk (sclk),
        .io_cpuRstn(!srst),
        .io_npuClk (dclk),
        .io_npuRstn(!drst),

        .io_axilite_aw_valid        (s_awvalid),
        .io_axilite_aw_ready        (bridge_awready),
        .io_axilite_aw_payload_addr (s_awaddr),
        .io_axilite_aw_payload_prot (s_awprot),
        .io_axilite_w_valid         (s_wvalid),
        .io_axilite_w_ready         (bridge_wready),
        .io_axilite_w_payload_data  (s_wdata),
        .io_axilite_w_payload_strb  (s_wstrb),
        .io_axilite_b_valid         (bridge_bvalid),
        .io_axilite_b_ready         (s_bready),
        .io_axilite_b_payload_resp  (s_bresp),
        .io_axilite_ar_valid        (s_arvalid),
        .io_axilite_ar_ready        (bridge_arready),
        .io_axilite_ar_payload_addr (s_araddr),
        .io_axilite_ar_payload_prot (s_arprot),
        .io_axilite_r_valid         (bridge_rvalid),
        .io_axilite_r_ready         (s_rready),
        .io_axilite_r_payload_data  (s_rdata),
        .io_axilite_r_payload_resp  (s_rresp),

        .io_npu_axilite_aw_valid        (d_awvalid),
        .io_npu_axilite_aw_ready        (d_awready),
        .io_npu_axilite_aw_payload_addr (d_awaddr),
        .io_npu_axilite_aw_payload_prot (d_awprot),
        .io_npu_axilite_w_valid         (d_wvalid),
        .io_npu_axilite_w_ready         (d_wready),
        .io_npu_axilite_w_payload_data  (d_wdata),
        .io_npu_axilite_w_payload_strb  (d_wstrb),
        .io_npu_axilite_b_valid         (d_bvalid),
        .io_npu_axilite_b_ready         (d_bready),
        .io_npu_axilite_b_payload_resp  (d_bresp),
        .io_npu_axilite_ar_valid        (d_arvalid),
        .io_npu_axilite_ar_ready        (d_arready),
        .io_npu_axilite_ar_payload_addr (d_araddr),
        .io_npu_axilite_ar_payload_prot (d_arprot),
        .io_npu_axilite_r_valid         (d_rvalid),
        .io_npu_axilite_r_ready         (d_rready),
        .io_npu_axilite_r_payload_data  (d_rdata),
        .io_npu_axilite_r_payload_resp  (d_rresp)
    );

    assign s_bvalid = bridge_bvalid;
    assign s_rvalid = bridge_rvalid;
    assign s_rlast  = 1'b1;                 // IO 单拍读
    assign d_awsize = 3'd2;                 // 32-bit；glue 的 IO 从口不使用 size
    assign d_awcache = 4'd0;
    assign d_wlast  = 1'b1;
    assign d_arsize = 3'd2;
    assign d_arcache = 4'd0;
    assign d_rlast  = 1'b1;

    // 未用输入：s_awsize/s_awcache/s_arsize/s_arcache/s_wlast（IO 单拍固定口径）
endmodule
