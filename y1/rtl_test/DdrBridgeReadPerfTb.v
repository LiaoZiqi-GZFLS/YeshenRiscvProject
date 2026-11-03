//=============================================================================
// DdrBridgeReadPerfTb.v —— DDR3Bridge **读吞吐/延迟曲线**测量（只测速率）
//
// 结构：
//   AXI 侧（100 MHz）：读主口背靠背发 READ（arlen=ALEN，地址 +32B），在飞 ≤ K 笔；
//                       R 端 rready=1 全速收；统计首笔 AR→最后一拍 R 的时钟数。
//   DDR 侧（125 MHz）：**流水化**读模型：AR 队列 8 深，每笔命令一个 due=cyc+LAT，
//                       到期按序每拍回一个 256bit beat（单 beat 命令，arlen=0）。
//                       不建 rready（与真 DDR IP 用户口一致，靠桥的 inflightR 信用兜住）。
// 用法：
//   vvp perf.vvp +LAT=40 +K=4 +ALEN=3 +N=256 +CLK_MHZ=100 +DCLK_MHZ=125
//   （ALEN=3 → 32B 突发；ALEN=15 → 128B 突发）
// 打印：BRPERF LAT= K= ALEN= N= CYCLES= BEATS= B/CYCLE= MBPS= MAXOUTR=
//=============================================================================
`timescale 1ns/1ps

module DdrBridgeReadPerfTb;

  real clk_mhz = 100.0, dclk_mhz = 125.0;
  integer LAT = 40, K = 4, ALEN = 3, N = 256;
  // ★ 2026-10-25：AR 队列深度可调（默认 8 = 历史口径；产品档下游 AR 队列实测只能吃 ~4 笔）
  integer QD = 8;
  initial begin
    if (!$value$plusargs("CLK_MHZ=%f", clk_mhz))  clk_mhz = 100.0;
    if (!$value$plusargs("DCLK_MHZ=%f", dclk_mhz)) dclk_mhz = 125.0;
    if (!$value$plusargs("LAT=%d", LAT)) LAT = 40;
    if (!$value$plusargs("K=%d", K)) K = 4;
    if (!$value$plusargs("ALEN=%d", ALEN)) ALEN = 3;
    if (!$value$plusargs("QD=%d", QD)) QD = 8;
    if (!$value$plusargs("N=%d", N)) N = 256;
  end
  reg clk = 0, dclk = 0;
  initial forever #(500.0/clk_mhz) clk = ~clk;
  initial forever #(500.0/dclk_mhz) dclk = ~dclk;

  reg reset = 1;
  reg ddr_rstn = 0;
  initial begin
    reset = 1; ddr_rstn = 0;
    repeat (20) @(posedge clk);
    repeat (10) @(posedge dclk);
    reset = 0; ddr_rstn = 1;
  end

  // ---------------- AXI 侧主口 ----------------
  reg  [31:0] ar_addr = 0;
  reg  [7:0]  ar_len = 0;
  reg         ar_valid = 0;
  wire        ar_ready;
  wire [3:0]  r_id;
  wire [63:0] r_data;
  wire [1:0]  r_resp;
  wire        r_last, r_valid;
  reg         r_ready = 1;

  // 写侧全部闲置（桥的 AW/W 通道不受影响）
  wire        aw_ready, w_ready, b_valid;
  wire [3:0]  b_id; wire [1:0] b_resp;

  // DDR 侧模型
  wire [27:0] d_awaddr, d_araddr;
  wire [3:0]  d_awlen, d_arlen;
  wire        d_awvalid, d_arvalid;
  reg         d_awready = 0;
  wire        d_arready;
  wire        d_wready = 1'b0;
  wire [255:0] d_wdata, d_rdata;
  wire [31:0] d_wstrb;
  wire        d_wvalid, d_rvalid, d_rlast;
  wire [3:0]  maxoutr;

  DDR3Bridge dut (
    .clock(clk), .reset(reset),
    .io_ddr_clk(dclk), .io_ddr_rstn(ddr_rstn),
    .io_axi_ar_arid(4'd0), .io_axi_ar_araddr(ar_addr), .io_axi_ar_arlen(ar_len),
    .io_axi_ar_arsize(3'd3), .io_axi_ar_arburst(2'b01), .io_axi_ar_arlock(2'd0),
    .io_axi_ar_arcache(4'd0), .io_axi_ar_arprot(3'd0),
    .io_axi_ar_arvalid(ar_valid), .io_axi_ar_arready(ar_ready),
    .io_axi_r_rid(r_id), .io_axi_r_rdata(r_data), .io_axi_r_rresp(r_resp),
    .io_axi_r_rlast(r_last), .io_axi_r_rvalid(r_valid), .io_axi_r_rready(r_ready),
    .io_axi_aw_awid(4'd0), .io_axi_aw_awaddr(32'd0), .io_axi_aw_awlen(8'd0),
    .io_axi_aw_awsize(3'd3), .io_axi_aw_awburst(2'b01), .io_axi_aw_awlock(2'd0),
    .io_axi_aw_awcache(4'd0), .io_axi_aw_awprot(3'd0),
    .io_axi_aw_awvalid(1'b0), .io_axi_aw_awready(aw_ready),
    .io_axi_w_wid(4'd0), .io_axi_w_wdata(64'd0), .io_axi_w_wstrb(8'hFF), .io_axi_w_wlast(1'b0),
    .io_axi_w_wvalid(1'b0), .io_axi_w_wready(w_ready),
    .io_axi_b_bid(b_id), .io_axi_b_bresp(b_resp), .io_axi_b_bvalid(b_valid), .io_axi_b_bready(1'b1),
    .io_ddrAwAddr(d_awaddr), .io_ddrAwLen(d_awlen), .io_ddrAwValid(d_awvalid), .io_ddrAwReady(d_awready),
    .io_ddrWData(d_wdata), .io_ddrWStrb(d_wstrb), .io_ddrWReady(d_wready),
    .io_ddrArAddr(d_araddr), .io_ddrArLen(d_arlen), .io_ddrArValid(d_arvalid), .io_ddrArReady(d_arready),
    .io_ddrRData(d_rdata), .io_ddrRValid(d_rvalid), .io_ddrRLast(d_rlast),
    .io_dbgOutW(), .io_dbgOutR(), .io_dbgMaxOutW(), .io_dbgMaxOutR(maxoutr)
  );

  // ---------------- DDR 侧流水读模型 ----------------
  reg [27:0] q_addr [0:7];
  integer    q_due  [0:7];
  integer    q_wr = 0, q_rd = 0;
  integer    q_cnt = 0;
  integer    dcyc = 0;
  reg [27:0] h_addr;             // 队头地址（组合读出）
  wire ar_fire = d_arvalid && d_arready;
  wire head_v  = (q_cnt != 0) && (q_due[q_rd] <= dcyc);
  wire pop     = head_v;

  assign d_arready  = (q_cnt < QD);
  always @(*) h_addr = (q_cnt != 0) ? q_addr[q_rd] : 28'd0;
  assign d_rvalid = head_v;
  assign d_rdata  = {8{h_addr[7:0]}};     // 简单可区分的模式（不判数值）
  assign d_rlast  = 1'b1;

  always @(posedge dclk) begin
    if (!ddr_rstn) begin
      q_wr <= 0; q_rd <= 0; q_cnt <= 0; dcyc <= 0;
    end else begin
      dcyc <= dcyc + 1;
      if (ar_fire) begin
        q_addr[q_wr] <= d_araddr;
        q_due[q_wr]  <= dcyc + LAT;
        q_wr <= (q_wr == 7) ? 0 : q_wr + 1;
      end
      if (pop) q_rd <= (q_rd == 7) ? 0 : q_rd + 1;
      q_cnt <= q_cnt + (ar_fire ? 1 : 0) - (pop ? 1 : 0);
    end
  end

  // ---------------- AXI 主：在飞 ≤ K ----------------
  integer ar_issued = 0, r_beats = 0, r_bursts = 0;
  integer clicks = 0;
  reg started = 0; time t0 = 0, t1 = 0;
  reg done = 0;
  wire [15:0] outstanding = ar_issued - r_bursts;

  always @(posedge clk) begin
    if (!reset && !done) begin
      // AR
      ar_valid <= (ar_issued < N) && (outstanding < K);
      ar_len   <= ALEN[7:0];
      ar_addr  <= 32'h0000_1000 + (ar_issued * ((ALEN + 1) * 8));
      if (ar_valid && ar_ready) begin
        ar_issued <= ar_issued + 1;
        if (!started) begin started <= 1; t0 <= $time; end
      end
      // R
      if (r_valid && r_ready) begin
        r_beats <= r_beats + 1;
        if (r_last) r_bursts <= r_bursts + 1;
        if (r_beats == N * (ALEN + 1) - 1) begin
          t1 <= $time; done <= 1;
        end
      end
    end
  end

  initial begin
    wait (done);
    repeat (4) @(posedge clk);
    begin : rep
      real cyc, bpc, mbps;
      cyc  = (t1 - t0) / (1000.0 / clk_mhz);
      bpc  = (N * (ALEN + 1)) / cyc;
      mbps = bpc * 8.0 * clk_mhz;
      $display("BRPERF LAT=%0d K=%0d ALEN=%0d N=%0d CYCLES=%.1f BEATS=%0d R_BURSTS=%0d B/CYCLE=%.3f MBPS=%.1f MAXOUTR=%0d",
               LAT, K, ALEN, N, cyc, N*(ALEN+1), r_bursts, bpc, mbps, maxoutr);
    end
    $finish;
  end

  initial begin
    #20000000;
    $display("BRPERF TIMEOUT ar=%0d rb=%0d rburst=%0d maxoutr=%0d", ar_issued, r_beats, r_bursts, maxoutr);
    $finish;
  end

endmodule
