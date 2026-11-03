// DdrRdQTb.v —— L2b：DdrMaster **mode=1 块槽预取**的装置（纯 Verilog，iverilog -g2012）。
//
// 盯三件事：
//   1) 一笔长 RD（1024 B = 8 个 128 B 块）在一个 `start` 内：AR 必须**背靠背多笔在飞**
//      （TB 自计 AR 握手 − rlast 握手，打印 MAXOUT；期望 ≥2；q1 负对照期望 ==1）；
//   2) 收下的字节流与内存**逐字节相同**（+OUTFILE 导出，闸门用 Python 对账）；
//   3) 尾块（992 B = 7×128+96、320 B = 2×128+64）与多请求连跑不丢不重（RDBYTES == 总和）。
//
// plusargs：+MEMFILE= / +DUMPFILE= 转给 AxiMemModel；+OUTFILE=<file> 本 TB 的收流十六进制。
// 打印：`REQ i src=... len=... done=... err=...`、`MAXOUT=<n> ARDONE=<n> RBEATS=<n> RDBYTES=<n>`、
//       `RESULT: PASS|FAIL`（FAIL 时 $fatal）。
`timescale 1ns/1ps

module DdrRdQTb;

  localparam integer MEMSZ = 16384;
  localparam integer TIMEOUT = 20000;

  reg clk = 1'b0;
  reg reset = 1'b1;
  always #5 clk = ~clk;

  reg         start;
  reg  [27:0] src, dst;
  reg  [31:0] length;
  reg  [1:0]  mode;
  wire        busy, done, err;
  wire [31:0] cyc, rd_bytes, wr_bytes;
  wire        rd_valid, rd_ready;
  wire [63:0] rd_data;
  wire        wr_ready;

  // AXI 线
  wire        axi_aw_valid, axi_aw_ready;
  wire [27:0] axi_aw_payload_addr;
  wire [3:0]  axi_aw_payload_id;
  wire [7:0]  axi_aw_payload_len;
  wire [2:0]  axi_aw_payload_size;
  wire [1:0]  axi_aw_payload_burst;
  wire [3:0]  axi_aw_payload_cache;
  wire [2:0]  axi_aw_payload_prot;
  wire        axi_w_valid, axi_w_ready;
  wire [63:0] axi_w_payload_data;
  wire [7:0]  axi_w_payload_strb;
  wire        axi_w_payload_last;
  wire        axi_b_valid, axi_b_ready;
  wire [3:0]  axi_b_payload_id;
  wire [1:0]  axi_b_payload_resp;
  wire        axi_ar_valid, axi_ar_ready;
  wire [27:0] axi_ar_payload_addr;
  wire [3:0]  axi_ar_payload_id;
  wire [7:0]  axi_ar_payload_len;
  wire [2:0]  axi_ar_payload_size;
  wire [1:0]  axi_ar_payload_burst;
  wire [3:0]  axi_ar_payload_cache;
  wire [2:0]  axi_ar_payload_prot;
  wire        axi_r_valid, axi_r_ready;
  wire [63:0] axi_r_payload_data;
  wire [3:0]  axi_r_payload_id;
  wire [1:0]  axi_r_payload_resp;
  wire        axi_r_payload_last;

  assign rd_ready = 1'b1;   // 消费端全速（预取路径的最有利情形）

  DdrMaster dut (
    .start(start), .src(src), .dst(dst), .len(length), .mode(mode),
    .sg_valid(1'b0), .sg_flush(1'b0), .sg_addr(28'd0), .sg_beatsM1(4'd0),
        .busy(busy), .done(done), .err(err), .cyc(cyc),
    .rd_bytes(rd_bytes), .wr_bytes(wr_bytes),
    .rd_valid(rd_valid), .rd_ready(rd_ready), .rd_data(rd_data),
    .wr_valid(1'b0), .wr_ready(wr_ready), .wr_data(64'd0), .wstrb(8'hFF),
    .axi_aw_valid(axi_aw_valid), .axi_aw_ready(axi_aw_ready),
    .axi_aw_payload_addr(axi_aw_payload_addr), .axi_aw_payload_id(axi_aw_payload_id),
    .axi_aw_payload_len(axi_aw_payload_len), .axi_aw_payload_size(axi_aw_payload_size),
    .axi_aw_payload_burst(axi_aw_payload_burst), .axi_aw_payload_cache(axi_aw_payload_cache),
    .axi_aw_payload_prot(axi_aw_payload_prot),
    .axi_w_valid(axi_w_valid), .axi_w_ready(axi_w_ready),
    .axi_w_payload_data(axi_w_payload_data), .axi_w_payload_strb(axi_w_payload_strb),
    .axi_w_payload_last(axi_w_payload_last),
    .axi_b_valid(axi_b_valid), .axi_b_ready(axi_b_ready),
    .axi_b_payload_id(axi_b_payload_id), .axi_b_payload_resp(axi_b_payload_resp),
    .axi_ar_valid(axi_ar_valid), .axi_ar_ready(axi_ar_ready),
    .axi_ar_payload_addr(axi_ar_payload_addr), .axi_ar_payload_id(axi_ar_payload_id),
    .axi_ar_payload_len(axi_ar_payload_len), .axi_ar_payload_size(axi_ar_payload_size),
    .axi_ar_payload_burst(axi_ar_payload_burst), .axi_ar_payload_cache(axi_ar_payload_cache),
    .axi_ar_payload_prot(axi_ar_payload_prot),
    .axi_r_valid(axi_r_valid), .axi_r_ready(axi_r_ready),
    .axi_r_payload_data(axi_r_payload_data), .axi_r_payload_id(axi_r_payload_id),
    .axi_r_payload_resp(axi_r_payload_resp), .axi_r_payload_last(axi_r_payload_last),
    .clk(clk), .reset(reset)
  );

  AxiMemModel #(.MEMSZ(MEMSZ), .ADDR_W(28)) mem0 (
    .clk(clk), .reset(reset),
    .axi_aw_valid(axi_aw_valid), .axi_aw_ready(axi_aw_ready),
    .axi_aw_payload_addr(axi_aw_payload_addr), .axi_aw_payload_id(axi_aw_payload_id),
    .axi_aw_payload_len(axi_aw_payload_len), .axi_aw_payload_size(axi_aw_payload_size),
    .axi_aw_payload_burst(axi_aw_payload_burst), .axi_aw_payload_cache(axi_aw_payload_cache),
    .axi_aw_payload_prot(axi_aw_payload_prot),
    .axi_w_valid(axi_w_valid), .axi_w_ready(axi_w_ready),
    .axi_w_payload_data(axi_w_payload_data), .axi_w_payload_strb(axi_w_payload_strb),
    .axi_w_payload_last(axi_w_payload_last),
    .axi_b_valid(axi_b_valid), .axi_b_ready(axi_b_ready),
    .axi_b_payload_id(axi_b_payload_id), .axi_b_payload_resp(axi_b_payload_resp),
    .axi_ar_valid(axi_ar_valid), .axi_ar_ready(axi_ar_ready),
    .axi_ar_payload_addr(axi_ar_payload_addr), .axi_ar_payload_id(axi_ar_payload_id),
    .axi_ar_payload_len(axi_ar_payload_len), .axi_ar_payload_size(axi_ar_payload_size),
    .axi_ar_payload_burst(axi_ar_payload_burst), .axi_ar_payload_cache(axi_ar_payload_cache),
    .axi_ar_payload_prot(axi_ar_payload_prot),
    .axi_r_valid(axi_r_valid), .axi_r_ready(axi_r_ready),
    .axi_r_payload_data(axi_r_payload_data), .axi_r_payload_id(axi_r_payload_id),
    .axi_r_payload_resp(axi_r_payload_resp), .axi_r_payload_last(axi_r_payload_last)
  );

  // ---- 在飞 AR 统计（AR 握手 − rlast 握手）----
  integer out_now, maxout, ardone, rbeats;
  always @(posedge clk) begin
    if (reset) begin
      out_now <= 0; maxout <= 0; ardone <= 0; rbeats <= 0;
    end else begin
      if (axi_ar_valid && axi_ar_ready) begin
        ardone <= ardone + 1;
        out_now <= out_now + 1;
        if (out_now + 1 > maxout) maxout <= out_now + 1;
      end
      if (axi_r_valid && axi_r_ready && axi_r_payload_last)
        out_now <= out_now - 1;
      if (rd_valid && rd_ready)
        rbeats <= rbeats + 1;
    end
  end

  // ---- 收流导出（每拍 8 字节，低字节 = 低地址，小端）----
  integer fd;
  reg [8*256-1:0] outfile;
  integer j;
  always @(posedge clk) begin
    if (!reset && rd_valid && rd_ready && fd != 0) begin
      for (j = 0; j < 8; j = j + 1)
        $fwrite(fd, "%02x", rd_data[j*8 +: 8]);
    end
  end

  // ---- 请求序列 ----
  integer tbfail;
  integer t;
  integer minout;
  task do_req(input [27:0] s, input [31:0] l);
    reg dseen, eseen;
    begin
      @(negedge clk);
      start = 1'b1; src = s; length = l; dst = 28'd0; mode = 2'd1;
      @(negedge clk);
      start = 1'b0;
      dseen = 1'b0; eseen = 1'b0; t = 0;
      while (!dseen && !eseen && t < TIMEOUT) begin
        @(posedge clk);
        if (done) dseen = 1'b1;
        if (err)  eseen = 1'b1;
        t = t + 1;
      end
      while (busy && t < TIMEOUT) begin
        @(posedge clk);
        t = t + 1;
      end
      $display("REQ src=%0d len=%0d done=%0d err=%0d cyc=%0d rd_bytes=%0d",
               s, l, dseen, eseen, cyc, rd_bytes);
      if (!dseen || eseen || t >= TIMEOUT) begin
        tbfail = tbfail + 1;
      end
    end
  endtask

  initial begin
    outfile = 0;
    fd = 0;
    tbfail = 0;
    minout = 2;
    start = 1'b0; src = 28'd0; dst = 28'd0; length = 32'd0; mode = 2'd1;
    if (!$value$plusargs("MINOUT=%d", minout)) minout = 2;
    if ($value$plusargs("OUTFILE=%s", outfile))
      fd = $fopen(outfile, "w");
    repeat (4) @(negedge clk);
    reset = 1'b0;
    @(negedge clk);

    do_req(28'h1000, 32'd1024);   // 8 个满块
    do_req(28'h2000, 32'd992);    // 7 满块 + 96 B 尾块（len 必须是 32 的倍数）
    do_req(28'h3000, 32'd320);    // 2 满块 + 64 B 尾块

    repeat (4) @(negedge clk);
    if (fd != 0) $fclose(fd);
    $display("MAXOUT=%0d ARDONE=%0d RBEATS=%0d RDBYTES=%0d",
             maxout, ardone, rbeats, rbeats * 8);
    if (tbfail == 0 && rbeats * 8 == 1024 + 992 + 320 && maxout >= minout)
      $display("RESULT: PASS");
    else begin
      $display("RESULT: FAIL tbfail=%0d rbytes=%0d maxout=%0d minout=%0d",
               tbfail, rbeats * 8, maxout, minout);
      $fatal(1, "DdrRdQTb failed");
    end
    $finish;
  end

endmodule
