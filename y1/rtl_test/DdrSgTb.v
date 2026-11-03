// DdrSgTb.v —— B3b：DdrMaster **mode=3 多事务散读（SG-RD）**的装置（iverilog -g2012）。
//
// 盯四件事：
//   1) 一批 N 项（每项 32/64 B、地址可任意 32 B 对齐）的收流与内存**逐字节相同**（+OUTFILE 导出，
//      闸门用 Python 按项序拼期望、逐字节对账）；RDBYTES == Σ项长；
//   2) AR **多笔在飞**：TB 自计 AR 握手 − rlast（MAXOUT），N≥2 的批次期望 ≥2；
//   3) 负对照（每条单独可判）：地址非 32B 对齐 / beatsM1 不是 4 的倍数 ⇒ sg_ready=0 + err；
//      空队 start(mode=3) ⇒ err；队满（第 9 项）⇒ sg_ready=0；忙时入队 ⇒ sg_ready=0；
//   4) 批与批之间不串：每批 done 后队列清空，下一批重新入队。
//
// plusargs：+MEMFILE= / +DUMPFILE= 转给 AxiMemModel；+OUTFILE=<file> 收流十六进制（每拍 16 个 hex 字符）。
// 打印：`SG ...` 探针行、`BATCH n=... bytes=... maxout=... done=...`、`RESULT: PASS|FAIL`。
`timescale 1ns/1ps

module DdrSgTb;

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

  reg         sg_valid;
  reg         sg_flush;
  wire        sg_ready;
  reg  [27:0] sg_addr;
  reg  [3:0]  sg_beatsM1;

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

  assign rd_ready = 1'b1;

  DdrMaster dut (
    .start(start), .src(src), .dst(dst), .len(length), .mode(mode),
    .sg_valid(sg_valid), .sg_ready(sg_ready), .sg_addr(sg_addr), .sg_beatsM1(sg_beatsM1),
    .sg_flush(sg_flush),
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

  // ---- 在飞 AR 统计 ----
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

  // ---- 收流导出 ----
  integer fd;
  reg [8*256-1:0] outfile;
  integer j;
  always @(posedge clk) begin
    if (!reset && rd_valid && rd_ready && fd != 0) begin
      for (j = 0; j < 8; j = j + 1)
        $fwrite(fd, "%02x", rd_data[j*8 +: 8]);
    end
  end

  // ---- 任务 ----
  integer tbfail;
  integer t;

  // 一项入队：kind=1 期望接收；kind=2 非法（ready=0 + err=1）；kind=0 队满（ready=0、err 必须 0）
  task enq(input [27:0] a, input [3:0] bm1, input [1:0] kind);
    reg rdy, e;
    begin
      while (busy) @(negedge clk);      // 只在 IDLE 试
      @(negedge clk);
      sg_valid = 1'b1; sg_addr = a; sg_beatsM1 = bm1;
      #1; rdy = sg_ready;
      @(negedge clk);
      sg_valid = 1'b0;
      #1; e = err;
      $display("SG enq a=%0d bm1=%0d ready=%0d err=%0d kind=%0d", a, bm1, rdy, e, kind);
      if (kind == 2'd1) begin if (!rdy) tbfail = tbfail + 1; end
      else if (kind == 2'd2) begin if (rdy || !e) tbfail = tbfail + 1; end
      else begin if (rdy || e) tbfail = tbfail + 1; end
    end
  endtask

  task start_sg(input [3:0] n, input exp_ok);
    reg e; integer i;
    begin
      @(negedge clk);
      start = 1'b1; mode = 2'd3; src = 28'd0; dst = 28'd0; length = 32'd0;
      @(negedge clk);
      start = 1'b0;
      $display("SG start n=%0d exp_ok=%0d", n, exp_ok);
      if (!exp_ok) begin
        // 空批：err 在 start 后 1–2 拍出现；等到它并等回 IDLE
        e = 0;
        for (i = 0; i < 8; i = i + 1) begin @(posedge clk); #1; if (err) e = 1; end
        if (!e) tbfail = tbfail + 1;
        while (busy) @(negedge clk);
      end
    end
  endtask

  task wait_done(input [31:0] exp_bytes);
    reg dseen, eseen;
    begin
      dseen = 1'b0; eseen = 1'b0; t = 0;
      while (!dseen && !eseen && t < TIMEOUT) begin
        @(posedge clk); #1;
        if (done) dseen = 1'b1;
        if (err)  eseen = 1'b1;
        t = t + 1;
      end
      $display("BATCH exp=%0d done=%0d err=%0d rd_bytes=%0d maxout=%0d",
               exp_bytes, dseen, eseen, rd_bytes, maxout);
      if (!dseen || eseen || rd_bytes != exp_bytes) tbfail = tbfail + 1;
    end
  endtask

  // 一项 32B（或 64B）的实际读出字节数
  function [31:0] nbytes(input [3:0] bm1); begin nbytes = (bm1 + 1) * 8; end endfunction

  integer k;
  initial begin
    outfile = 0; fd = 0; tbfail = 0;
    start = 1'b0; src = 28'd0; dst = 28'd0; length = 32'd0; mode = 2'd1;
    sg_valid = 1'b0; sg_flush = 1'b0; sg_addr = 28'd0; sg_beatsM1 = 4'd0;
    if ($value$plusargs("OUTFILE=%s", outfile)) fd = $fopen(outfile, "w");
    repeat (4) @(negedge clk);
    reset = 1'b0;
    @(negedge clk);

    // ---- 负对照 1：非法地址/拍数（不入队、不搬）----
    enq(28'h1004, 4'd3, 2'd2);
    enq(28'h1000, 4'd2, 2'd2);
    // ---- 负对照 2：空队 start(mode=3) ----
    start_sg(4'd0, 1'b0);

    // ---- 负对照 3：入队 2 项后 **flush** ⇒ 队列清空 ⇒ start(mode=3) 必报 err ----
    enq(28'h1000, 4'd3, 2'd1);
    enq(28'h1040, 4'd3, 2'd1);
    @(negedge clk); sg_flush = 1'b1;
    @(negedge clk); sg_flush = 1'b0;
    $display("SG flush done");
    start_sg(4'd0, 1'b0);

    // ---- 正档 A：N=1 ----
    maxout = 0; ardone = 0; rbeats = 0;
    enq(28'h1000, 4'd3, 2'd1);
    start_sg(4'd1, 1'b1);
    wait_done(32'd32);

    // ---- 正档 B：N=8 + 队满/忙时入队探针 ----
    maxout = 0; ardone = 0; rbeats = 0;
    for (k = 0; k < 8; k = k + 1) enq(28'h2000 + k * 28'h100, 4'd3, 2'd1);
    enq(28'h2800, 4'd3, 2'd0);          // 第 9 项：队满 ⇒ ready=0
    start_sg(4'd8, 1'b1);
    repeat (3) @(negedge clk);
    // 忙时入队探针（状态非 IDLE ⇒ ready=0；不写入、不报 err）
    @(negedge clk); sg_valid = 1'b1; sg_addr = 28'h2F00; sg_beatsM1 = 4'd3;
    #1; $display("SG busy-enq ready=%0d", sg_ready); if (sg_ready) tbfail = tbfail + 1;
    @(negedge clk); sg_valid = 1'b0;
    wait_done(32'd256);

    // ---- 正档 C：N=2、混合长度（32B + 64B）----
    maxout = 0; ardone = 0; rbeats = 0;
    enq(28'h3000, 4'd3, 2'd1);
    enq(28'h3040, 4'd7, 2'd1);
    start_sg(4'd2, 1'b1);
    wait_done(32'd96);

    repeat (4) @(negedge clk);
    if (fd != 0) $fclose(fd);
    $display("SG TOTAL ardone=%0d rbeats=%0d maxout_last=%0d tbfail=%0d", ardone, rbeats, maxout, tbfail);
    if (tbfail == 0) $display("RESULT: PASS");
    else begin $display("RESULT: FAIL tbfail=%0d", tbfail); $fatal(1, "DdrSgTb failed"); end
    $finish;
  end

  integer tmo;
  initial begin
    for (tmo = 0; tmo < 200000; tmo = tmo + 1) @(posedge clk);
    $display("RESULT: FAIL global timeout"); $fatal(1, "DdrSgTb timeout");
  end

endmodule
