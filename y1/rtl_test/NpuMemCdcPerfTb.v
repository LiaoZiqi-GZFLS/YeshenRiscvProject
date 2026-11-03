//=============================================================================
// NpuMemCdcPerfTb.v —— NpuMemCdc **R 通道吞吐**测量装置（只测速率，不测数值）
//
// 结构：
//   npu_clk 侧：读主口背靠背发 READ burst（arlen = ALEN，地址 +32B 递增），
//               R 端 rready=1 全速收；统计 NAR 笔 AR 到最后一拍 R 的拍数。
//   cpu_clk 侧：极简 AXI 读从口：AR 入 8 深队列（立即 ready），按序逐笔回 R，
//               每笔首拍前插 +LAT 拍延迟（测延迟敏感性），R 数据为递增计数器。
// 判据（打印）：
//   NPUCLK_MHZ / AR_BURSTS / BEATS / CYCLES / BEATS_PER_CYCLE / BYTES_PER_CYCLE /
//   MBPS_NPU / AR_PER_CYCLE / LAT
// 用法：
//   vvp perf.vvp +NAR=512 +ALEN=3 +LAT=1 +CPU_MHZ=100 +NPU_MHZ=54
//   （ALEN 是 AXI arlen：3 => 4 拍 = 32B；15 => 16 拍 = 128B）
//=============================================================================
`timescale 1ns/1ps

module NpuMemCdcPerfTb;

  // ---- 时钟（默认 cpu 100MHz / npu 54MHz，与板级一致）----
  real    cpu_mhz = 100.0;
  real    npu_mhz = 54.0;
  initial begin
    if (!$value$plusargs("CPU_MHZ=%f", cpu_mhz)) cpu_mhz = 100.0;
    if (!$value$plusargs("NPU_MHZ=%f", npu_mhz)) npu_mhz = 54.0;
  end
  reg cpu_clk = 0, npu_clk = 0;
  initial forever #(500.0/cpu_mhz) cpu_clk = ~cpu_clk;
  initial forever #(500.0/npu_mhz) npu_clk = ~npu_clk;

  reg reset = 1;                       // 高有效，两域同时
  wire cpu_rstn = ~reset, npu_rstn = ~reset;

  // ---- npu 侧主口 ----
  reg         m_awvalid = 0, m_wvalid = 0, m_bready = 1;
  reg  [27:0] m_awaddr = 0; reg [3:0] m_awid = 0; reg [7:0] m_awlen = 0;
  reg  [2:0]  m_awsize = 3; reg [1:0] m_awburst = 1; reg [3:0] m_awcache = 0; reg [2:0] m_awprot = 0;
  reg  [63:0] m_wdata = 0; reg  [7:0] m_wstrb = 8'hFF; reg m_wlast = 0;
  reg         m_arvalid = 0;
  reg  [27:0] m_araddr = 0; reg [3:0] m_arid = 0; reg [7:0] m_arlen = 0;
  reg  [2:0]  m_arsize = 3; reg [1:0] m_arburst = 1; reg [3:0] m_arcache = 0; reg [2:0] m_arprot = 0;
  reg         m_rready = 1;
  wire        m_awready, m_wready, m_bvalid, m_arready, m_rvalid, m_rlast;
  wire [3:0]  m_bid, m_rid; wire [1:0] m_bresp, m_rresp; wire [63:0] m_rdata;

  // ---- DUT（cpu 侧主口）----
  wire        c_awvalid, c_wvalid, c_bready, c_arvalid, c_rready, c_awready, c_wready, c_bvalid, c_arready, c_rvalid, c_rlast;
  wire [27:0] c_awaddr, c_araddr;
  wire [3:0]  c_awid, c_arid, c_bid, c_rid;
  wire [7:0]  c_awlen, c_arlen; wire [2:0] c_awsize, c_arsize; wire [1:0] c_awburst, c_arburst;
  wire [3:0]  c_awcache, c_arcache; wire [2:0] c_awprot, c_arprot;
  wire [63:0] c_wdata, c_rdata; wire [7:0] c_wstrb; wire c_wlast; wire [1:0] c_bresp, c_rresp;

  assign c_awready = 1'b0;
  assign c_wready  = 1'b0;
  assign c_bvalid  = 1'b0;
  assign c_bid     = 4'd0;
  assign c_bresp   = 2'd0;
  assign c_bready  = 1'b0;

  NpuMemCdc dut (
    .cpuClk(cpu_clk), .cpuRstn(cpu_rstn), .npuClk(npu_clk), .npuRstn(npu_rstn),
    .npuMem_aw_valid(m_awvalid), .npuMem_aw_ready(m_awready),
    .npuMem_aw_payload_addr(m_awaddr), .npuMem_aw_payload_id(m_awid), .npuMem_aw_payload_len(m_awlen),
    .npuMem_aw_payload_size(m_awsize), .npuMem_aw_payload_burst(m_awburst),
    .npuMem_aw_payload_cache(m_awcache), .npuMem_aw_payload_prot(m_awprot),
    .npuMem_w_valid(m_wvalid), .npuMem_w_ready(m_wready), .npuMem_w_payload_data(m_wdata),
    .npuMem_w_payload_strb(m_wstrb), .npuMem_w_payload_last(m_wlast),
    .npuMem_b_valid(m_bvalid), .npuMem_b_ready(m_bready), .npuMem_b_payload_id(m_bid),
    .npuMem_b_payload_resp(m_bresp),
    .npuMem_ar_valid(m_arvalid), .npuMem_ar_ready(m_arready),
    .npuMem_ar_payload_addr(m_araddr), .npuMem_ar_payload_id(m_arid), .npuMem_ar_payload_len(m_arlen),
    .npuMem_ar_payload_size(m_arsize), .npuMem_ar_payload_burst(m_arburst),
    .npuMem_ar_payload_cache(m_arcache), .npuMem_ar_payload_prot(m_arprot),
    .npuMem_r_valid(m_rvalid), .npuMem_r_ready(m_rready), .npuMem_r_payload_data(m_rdata),
    .npuMem_r_payload_id(m_rid), .npuMem_r_payload_resp(m_rresp), .npuMem_r_payload_last(m_rlast),
    .cpuMem_aw_valid(c_awvalid), .cpuMem_aw_ready(c_awready),
    .cpuMem_aw_payload_addr(c_awaddr), .cpuMem_aw_payload_id(c_awid), .cpuMem_aw_payload_len(c_awlen),
    .cpuMem_aw_payload_size(c_awsize), .cpuMem_aw_payload_burst(c_awburst),
    .cpuMem_aw_payload_cache(c_awcache), .cpuMem_aw_payload_prot(c_awprot),
    .cpuMem_w_valid(c_wvalid), .cpuMem_w_ready(c_wready), .cpuMem_w_payload_data(c_wdata),
    .cpuMem_w_payload_strb(c_wstrb), .cpuMem_w_payload_last(c_wlast),
    .cpuMem_b_valid(c_bvalid), .cpuMem_b_ready(c_bready), .cpuMem_b_payload_id(c_bid),
    .cpuMem_b_payload_resp(c_bresp),
    .cpuMem_ar_valid(c_arvalid), .cpuMem_ar_ready(c_arready),
    .cpuMem_ar_payload_addr(c_araddr), .cpuMem_ar_payload_id(c_arid), .cpuMem_ar_payload_len(c_arlen),
    .cpuMem_ar_payload_size(c_arsize), .cpuMem_ar_payload_burst(c_arburst),
    .cpuMem_ar_payload_cache(c_arcache), .cpuMem_ar_payload_prot(c_arprot),
    .cpuMem_r_valid(c_rvalid), .cpuMem_r_ready(c_rready), .cpuMem_r_payload_data(c_rdata),
    .cpuMem_r_payload_id(c_rid), .cpuMem_r_payload_resp(c_rresp), .cpuMem_r_payload_last(c_rlast)
  );

  // =========================================================================
  // cpu 侧：极简读从口（8 深 AR 队列；按序回 R；每笔首拍前 +LAT 拍）
  // =========================================================================
  integer LAT = 1;
  initial if (!$value$plusargs("LAT=%d", LAT)) LAT = 1;

  reg [27:0] q_addr [0:7];
  reg [7:0]  q_len  [0:7];
  reg [3:0]  q_id   [0:7];
  integer q_wr = 0, q_rd = 0, q_cnt = 0;

  assign c_arready = (q_cnt < 8);

  reg        serving = 0;
  reg [7:0]  rlen = 0, rbeat = 0;
  integer    rdelay = 0;
  reg        rv = 0, rl = 0;
  reg [63:0] rd = 0;
  assign c_rvalid = rv;
  assign c_rdata  = rd;
  assign c_rid    = 4'd0;
  assign c_rresp  = 2'd0;
  assign c_rlast  = rl;

  wire ar_acc = c_arvalid && c_arready;
  wire q_pop  = (!serving) && (q_cnt != 0);

  always @(posedge cpu_clk) begin
    if (!cpu_rstn) begin
      q_wr <= 0; q_rd <= 0; q_cnt <= 0;
      serving <= 0; rv <= 0; rl <= 0; rbeat <= 0; rdelay <= 0; rd <= 0;
    end else begin
      // AR 入队（q_cnt 的加减必须合成一条表达式：同拍入队+出队时后写会覆盖前写）
      if (ar_acc) begin
        q_addr[q_wr] <= c_araddr;
        q_len[q_wr]  <= c_arlen;
        q_id[q_wr]   <= c_arid;
        q_wr <= (q_wr == 7) ? 0 : q_wr + 1;
      end
      q_cnt <= q_cnt + (ar_acc ? 1 : 0) - (q_pop ? 1 : 0);
      // R 服务
      if (!serving) begin
        rv <= 0;
        if (q_cnt != 0) begin
          serving <= 1;
          rlen <= q_len[q_rd];
          rbeat <= 0;
          rdelay <= LAT;
          q_rd <= (q_rd == 7) ? 0 : q_rd + 1;
          rd <= {32'd0, q_addr[q_rd]} + 64'h1000;
        end
      end else begin
        if (rv) begin
          if (c_rready) begin
            if (rbeat == rlen) begin
              serving <= 0; rv <= 0; rl <= 0;
            end else begin
              rbeat <= rbeat + 1;
              rl <= (rbeat + 1 == rlen);
              rd <= rd + 64'd8;
            end
          end
        end else if (rdelay == 0) begin
          rv <= 1;
          rl <= (rlen == 0);
        end else begin
          rdelay <= rdelay - 1;
        end
      end
    end
  end

  // =========================================================================
  // npu 侧：背靠背读（NAR 笔；每笔 ALEN+1 拍）
  // =========================================================================
  integer NAR = 512;
  integer ALEN = 3;
  initial begin
    if (!$value$plusargs("NAR=%d", NAR)) NAR = 512;
    if (!$value$plusargs("ALEN=%d", ALEN)) ALEN = 3;
  end

  integer ar_sent = 0, r_beats = 0, ar_cycles = 0;
  reg     started = 0;
  time    t_start = 0, t_end = 0;
  reg     done = 0;
  integer beats_total = 0;

  always @(posedge npu_clk) begin
    if (!npu_rstn) begin
      ar_sent <= 0; r_beats <= 0; started <= 0; done <= 0; ar_cycles <= 0;
      m_arvalid <= 0;
    end else if (!done) begin
      // AR：保持 valid 直到全部发完（DUT 的 arPipe 反压天然限流）
      if (ar_sent < NAR) begin
        m_arvalid <= 1;
        m_araddr  <= 28'h1000 + (ar_sent * ((ALEN + 1) * 8));
        m_arlen   <= ALEN;
        if (m_arvalid && m_arready) begin
          ar_sent <= ar_sent + 1;
          if (!started) begin started <= 1; t_start <= $time; end
        end
      end else begin
        m_arvalid <= 0;
      end
      if (m_arvalid && m_arready) ar_cycles <= ar_cycles + 1;
      // R：全速收
      if (m_rvalid && m_rready) begin
        r_beats <= r_beats + 1;
        if (r_beats == NAR * (ALEN + 1) - 1) begin
          t_end <= $time;
          done  <= 1;
        end
      end
    end
  end

  // =========================================================================
  // 主流程
  // =========================================================================
  initial begin
    beats_total = 0;
    repeat (20) @(posedge cpu_clk);
    reset = 0;
    repeat (20) @(posedge npu_clk);

    beats_total = NAR * (ALEN + 1);
    wait (done);
    repeat (4) @(posedge npu_clk);

    begin : report
      real cyc, bpc, mbps, arpc;
      cyc  = (t_end - t_start) / (1000.0 / npu_mhz);   // ns / ns-per-cycle
      bpc  = beats_total / cyc;
      arpc = ar_sent / cyc;
      mbps = bpc * 8.0 * npu_mhz;                      // 8B/beat
      $display("PERF LAT=%0d NAR=%0d ALEN=%0d BEATS=%0d AR=%0d CYCLES=%.1f BEATS_PER_CYCLE=%.3f BYTES_PER_CYCLE=%.2f MBPS_NPU=%.1f AR_PER_CYCLE=%.3f",
               LAT, NAR, ALEN, beats_total, ar_sent, cyc, bpc, bpc*8.0, mbps, arpc);
    end
    $finish;
  end

  initial begin
    #50000000;
    $display("PERF TIMEOUT ar_sent=%0d r_beats=%0d", ar_sent, r_beats);
    $finish;
  end

endmodule
