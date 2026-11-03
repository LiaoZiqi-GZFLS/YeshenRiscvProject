// tb_gpu_mem_unalign.v —— gpu_mem 读引擎「32 B 对齐取数 + 丢前导拍」闸门。
//
// 背景：DDR 用户口是 32 B/拍，8 B 粒度但非 32 B 对齐的突发会被整段下移，
// 所以 gpu_mem 从 32 B 块首取数、把前 pad=addr[4:3] 拍丢掉。此闸门专门盯 pad>0：
// 丢掉的拍**不能**计入 rd_left，否则 rd_last 永远不来、读 FSM 卡在 RD_DATA。
//
// 用例（rd_beats = 7 ⇒ 要交付 8 拍）：
//   A) pad=0  addr=0x000  → arlen=7  → 交付 8 拍，末拍 rd_last
//   B) pad=1  addr=0x008  → arlen=8  → 交付 8 拍，首拍 = 第 1 个字
//   C) pad=3  addr=0x018  → arlen=10 → 交付 8 拍，首拍 = 第 3 个字
//   D) 负对照：C 的首拍期望故意错一个字，判据必须报 MISMATCH
//
// RAM 内容用写口预置（不用层次化引用，iverilog/verilator 都能跑）。
`timescale 1ns/1ps
module tb_gpu_mem_unalign;

  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg         rd_req = 0;
  reg  [31:0] rd_addr = 0;
  reg  [7:0]  rd_beats = 0;
  wire        rd_busy;
  wire [63:0] rd_data;
  wire        rd_valid, rd_last;

  reg         wr_valid = 0;
  reg  [31:0] wr_addr = 0;
  reg  [63:0] wr_data = 0;
  reg  [7:0]  wr_strb = 0;
  wire        wr_ready;
  reg         wr_flush = 0;

  wire [31:0] araddr, awaddr;
  wire [7:0]  arlen, awlen;
  wire [2:0]  arsize, awsize;
  wire [1:0]  arburst, awburst;
  wire        arvalid, awvalid;
  wire [63:0] rdata, wdata;
  wire [7:0]  wstrb;
  wire        rlast, rvalid, rready, wlast, wvalid, wready, bvalid, bready;
  wire [1:0]  bresp;
  wire [31:0] aw_count, w_count, ar_count;
  wire [1:0]  dbg_wrs, dbg_rds;
  wire [4:0]  dbg_wcnt;
  wire [31:0] dbg_rd_ar, dbg_rd_b01, dbg_rd_b23;
  wire [7:0]  dbg_rd_cnt, dbg_rd_len;
  wire        arready, awready;

  gpu_mem dut (
      .clk(clk), .rst(rst),
      .rd_req(rd_req), .rd_addr(rd_addr), .rd_beats(rd_beats), .rd_busy(rd_busy),
      .rd_data(rd_data), .rd_valid(rd_valid), .rd_last(rd_last),
      .wr_valid(wr_valid), .wr_addr(wr_addr), .wr_data(wr_data), .wr_strb(wr_strb),
      .wr_ready(wr_ready), .wr_flush(wr_flush),
      .m_araddr(araddr), .m_arlen(arlen), .m_arsize(arsize), .m_arburst(arburst),
      .m_arvalid(arvalid), .m_arready(arready),
      .m_rdata(rdata), .m_rresp(2'b00), .m_rlast(rlast), .m_rvalid(rvalid), .m_rready(rready),
      .m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(awsize), .m_awburst(awburst),
      .m_awvalid(awvalid), .m_awready(awready),
      .m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast), .m_wvalid(wvalid), .m_wready(wready),
      .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
      .dbg_wrs(dbg_wrs), .dbg_wcnt(dbg_wcnt), .dbg_rds(dbg_rds),
      .dbg_rd_ar(dbg_rd_ar), .dbg_rd_cnt(dbg_rd_cnt), .dbg_rd_len(dbg_rd_len),
      .dbg_rd_b01(dbg_rd_b01), .dbg_rd_b23(dbg_rd_b23)
  );

  axi_ram_model #(.AW(10)) ram (
      .clk(clk), .rst(rst),
      .araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
      .rdata(rdata), .rlast(rlast), .rvalid(rvalid), .rready(rready),
      .awaddr(awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
      .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
      .bresp(bresp), .bvalid(bvalid), .bready(bready),
      .aw_count(aw_count), .w_count(w_count), .ar_count(ar_count),
      .dbg_idx(16'd0), .dbg_word(),
      .dbg_bvalid(), .dbg_wactive(), .dbg_wleft()
  );

  integer errors = 0;
  integer i;
  reg [63:0] memq [0:31];        // 本 TB 自己的期望副本，memq[i] 对应地址 i*8
  reg [63:0] got  [0:15];
  integer nbeats;
  reg [31:0] ar_addr_q;
  reg [7:0]  ar_len_q;

  always @(posedge clk) if (arvalid && arready) begin
    ar_addr_q <= araddr;
    ar_len_q  <= arlen;
  end

  task automatic wr_word(input [31:0] a, input [63:0] d);
    begin
      @(negedge clk);
      while (!wr_ready) @(negedge clk);
      wr_valid = 1'b1; wr_addr = a; wr_data = d; wr_strb = 8'hFF;
      @(negedge clk);
      wr_valid = 1'b0;
    end
  endtask

  initial begin
    repeat (3) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);

    // ---- 用写口预置 32 个字 ----
    for (i = 0; i < 32; i = i + 1) begin
      memq[i] = {32'hA5A5_0000 | i[15:0], 16'h5A5A + i[15:0]};
      wr_word(i * 8, memq[i]);
    end
    @(negedge clk); wr_flush = 1'b1;
    @(negedge clk); wr_flush = 1'b0;
    repeat (20) @(negedge clk);

    // ---- A) pad=0 ----
    run_read(32'h0000_0000, 8'd7, "A pad=0", 0);
    // ---- B) pad=1 ----
    run_read(32'h0000_0008, 8'd7, "B pad=1", 0);
    // ---- C) pad=3 ----
    run_read(32'h0000_0018, 8'd7, "C pad=3", 0);
    // ---- D) 负对照 ----
    run_read(32'h0000_0018, 8'd7, "D negctl", 1);

    if (errors == 0) $display("MEM_UNALIGN PASS（正例 3 全对，负例被抓）");
    else             $display("MEM_UNALIGN FAIL errors=%0d", errors);
    $finish;
  end

  task automatic run_read(input [31:0] a, input [7:0] beats, input [127:0] tag,
                          input integer negate);
    integer k, to, bad;
    reg [31:0] blk;
    reg [63:0] exp;
    reg        got_last;
    begin
      blk = {a[31:5], 5'b000};
      @(negedge clk);
      rd_addr = a; rd_beats = beats; rd_req = 1'b1;
      @(negedge clk);
      rd_req = 1'b0;

      k = 0; to = 0; got_last = 1'b0;
      while (to < 400 && !got_last) begin
        @(negedge clk);
        if (rd_valid) begin
          got[k] = rd_data;
          k = k + 1;
          if (rd_last) got_last = 1'b1;
        end else to = to + 1;
      end

      if (!got_last) begin
        $display("  FAIL %0s: rd_last 没来 —— 交付 %0d/%0d 拍，rds=%0d rd_ar=%08x len=%0d cnt=%0d",
                 tag, k, beats + 1, dut.rds, dbg_rd_ar, dbg_rd_len, dbg_rd_cnt);
        errors = errors + 1;
      end else if (k !== beats + 1) begin
        $display("  FAIL %0s: 交付 %0d 拍 != %0d 拍", tag, k, beats + 1);
        errors = errors + 1;
      end else if (ar_addr_q !== blk) begin
        $display("  FAIL %0s: AR 地址 %08x != 32B 块首 %08x", tag, ar_addr_q, blk);
        errors = errors + 1;
      end else if (ar_len_q !== beats + {6'd0, a[4:3]}) begin
        $display("  FAIL %0s: AR len %0d != %0d", tag, ar_len_q, beats + a[4:3]);
        errors = errors + 1;
      end else begin
        bad = 0;
        for (i = 0; i < beats + 1; i = i + 1) begin
          exp = memq[(blk >> 3) + a[4:3] + i];
          if (negate && i == 0) exp = memq[(blk >> 3) + i];
          if (got[i] !== exp) begin
            if (bad < 3)
              $display("  MISMATCH %0s beat%0d got=%016x exp=%016x", tag, i, got[i], exp);
            bad = bad + 1;
          end
        end
        if (negate) begin
          if (bad == 0) begin
            $display("  FAIL %0s: 负对照没被抓到 —— 判据没有区分力", tag);
            errors = errors + 1;
          end else $display("  ok %0s: 负对照按预期报 MISMATCH", tag);
        end else if (bad != 0) begin
          $display("  FAIL %0s: %0d 拍数据不符", tag, bad);
          errors = errors + 1;
        end else $display("  ok %0s: arlen=%0d 交付 %0d 拍", tag, ar_len_q, beats + 1);
      end
      repeat (5) @(negedge clk);
    end
  endtask

  initial begin
    #400_000;
    $display("MEM_UNALIGN FAIL 总超时（rds=%0d rd_ar=%08x rd_cnt=%0d rd_len=%0d）",
             dut.rds, dbg_rd_ar, dbg_rd_cnt, dbg_rd_len);
    $finish;
  end

endmodule