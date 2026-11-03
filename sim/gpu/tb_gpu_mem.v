// tb_gpu_mem.v —— gpu_mem 单元闸门：
//   ① 16 拍写 burst → RAM 逐字核对
//   ② 16 拍读 burst → 数据流逐拍核对
//   ③ 32 拍连写只 flush 一次 → 恰好 2 次 AW（16+16）、32 拍 W
//   ④ 负对照：wstrb=0 的一拍不得改变 RAM
`timescale 1ns/1ps
module tb_gpu_mem;

  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  // DUT 端口
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
  wire dbg_bvalid, dbg_wactive;
  wire [7:0] dbg_wleft;
  reg  [15:0] dbg_idx = 0;
  wire [63:0] dbg_word;
  wire [31:0] dbg_rd_ar, dbg_rd_b01, dbg_rd_b23;
  wire [7:0]  dbg_rd_cnt, dbg_rd_len;

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

  wire arready, awready;
`ifdef RAM_NO_HOLD
  localparam RAM_NH = 1;
`else
  localparam RAM_NH = 0;
`endif
  axi_ram_model #(.AW(16), .NO_HOLD(RAM_NH)) ram (
      .clk(clk), .rst(rst),
      .araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
      .rdata(rdata), .rlast(rlast), .rvalid(rvalid), .rready(rready),
      .awaddr(awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
      .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
      .bresp(bresp), .bvalid(bvalid), .bready(bready),
      .aw_count(aw_count), .w_count(w_count), .ar_count(ar_count),
      .dbg_idx(dbg_idx), .dbg_word(dbg_word),
      .dbg_bvalid(dbg_bvalid), .dbg_wactive(dbg_wactive), .dbg_wleft(dbg_wleft)
  );

  integer errors = 0;

  always @(posedge clk)
    if (awvalid && awready) $display("  [dbg] AW addr=%08x len=%0d", awaddr, awlen);
  always @(posedge clk)
    if (arvalid && arready) $display("  [dbg] AR addr=%08x len=%0d", araddr, arlen);

  task automatic check64(input [15:0] idx, input [63:0] exp, input [127:0] tag);
    begin
      dbg_idx = idx;
      #1;
      if (dbg_word !== exp) begin
        $display("  MISMATCH %0s idx=%0d got=%016x exp=%016x", tag, idx, dbg_word, exp);
        errors = errors + 1;
      end
    end
  endtask

  task automatic wr_word(input [31:0] a, input [63:0] d, input [7:0] s);
    begin
      @(negedge clk);
      while (!wr_ready) @(negedge clk);
      wr_valid = 1'b1; wr_addr = a; wr_data = d; wr_strb = s;
      @(negedge clk);
      wr_valid = 1'b0;
    end
  endtask

  task automatic do_flush;
    begin
      @(negedge clk);
      wr_flush = 1'b1;
      @(negedge clk);
      wr_flush = 1'b0;
    end
  endtask

  reg [63:0] rx;
  reg [7:0]  rxi;

  initial begin
    repeat (4) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);

    // ---------- ① 16 拍写 ----------
    for (rxi = 0; rxi < 16; rxi = rxi + 1)
      wr_word(32'h100 + rxi * 8, {32'hA5A5_0000 + rxi, 32'h1111_0000 + rxi}, 8'hFF);
    $display("  [dbg] stage1 written, aw_count=%0d w_count=%0d", aw_count, w_count);
    do_flush;
    wait (aw_count == 1);
    $display("  [dbg] stage1 aw seen");
    repeat (20) @(negedge clk);
    for (rxi = 0; rxi < 16; rxi = rxi + 1)
      check64(6'h20 + rxi, {32'hA5A5_0000 + rxi, 32'h1111_0000 + rxi}, "write16");

    // ---------- ② 16 拍读 ----------
    @(negedge clk);
    rd_req = 1'b1; rd_addr = 32'h100; rd_beats = 8'd15;
    @(negedge clk);
    rd_req = 1'b0;
    rxi = 0;
    while (rxi < 16) begin
      @(negedge clk);            // 在半个周期后采样，避开 posedge 的寄存器更新竞争
      if (rd_valid) begin
        check64(6'h20 + rxi, rd_data, "read16");
        if (rd_last !== (rxi == 15)) begin
          $display("  MISMATCH read16 rlast at beat %0d (last=%0d)", rxi, rd_last);
          errors = errors + 1;
        end
        rxi = rxi + 1;
      end
    end
    repeat (4) @(negedge clk);
    if (rd_busy) begin
      $display("  MISMATCH rd_busy stayed high");
      errors = errors + 1;
    end

    // ---------- ③ 32 拍连写，只 flush 一次 ----------
    // 前 16 拍自触发一次 burst，后 16 拍靠 flush
    for (rxi = 0; rxi < 32; rxi = rxi + 1)
      wr_word(32'h400 + rxi * 8, {32'h5A5A_0000 + rxi, 32'h2222_0000 + rxi}, 8'hFF);
    do_flush;
    wait (aw_count == 3);
    wait (w_count == 48);
    repeat (20) @(negedge clk);
    for (rxi = 0; rxi < 32; rxi = rxi + 1)
      check64(8'h80 + rxi, {32'h5A5A_0000 + rxi, 32'h2222_0000 + rxi}, "write32");

    // ---------- ④ 负对照：strb=0 不写 ----------
    wr_word(32'h600 + 0, 64'hDEAD_BEEF_DEAD_BEEF, 8'h00);
    do_flush;
    wait (aw_count == 4);
    repeat (20) @(negedge clk);
    dbg_idx = 16'hC0;
    #1;
    if (dbg_word !== 64'd0) begin
      $display("  MISMATCH strb0 changed RAM: %016x", dbg_word);
      errors = errors + 1;
    end

    // ---------- ⑤ 非 32B 对齐：写 4 字 @0x708（pad=1），再按同址读 4 拍 ----------
    for (rxi = 0; rxi < 4; rxi = rxi + 1)
      wr_word(32'h708 + rxi * 8, {32'hC3C3_0000 + rxi, 32'h3333_0000 + rxi}, 8'hFF);
    do_flush;
    wait (aw_count == 5);
    repeat (20) @(negedge clk);
    for (rxi = 0; rxi < 4; rxi = rxi + 1)
      check64(16'hE1 + rxi, {32'hC3C3_0000 + rxi, 32'h3333_0000 + rxi}, "unalign-wr");
    dbg_idx = 16'hE0;                      // 前补的空拍必须没写
    #1;
    if (dbg_word !== 64'd0) begin
      $display("  MISMATCH unalign pad word changed: %016x", dbg_word);
      errors = errors + 1;
    end

    @(negedge clk);
    rd_req = 1'b1; rd_addr = 32'h708; rd_beats = 8'd3;
    @(negedge clk);
    rd_req = 1'b0;
    rxi = 0;
    while (rxi < 4) begin
      @(negedge clk);
      if (rd_valid) begin
        check64(16'hE1 + rxi, rd_data, "unalign-rd");
        if (rd_last !== (rxi == 3)) begin
          $display("  MISMATCH unalign-rd rlast at beat %0d (last=%0d)", rxi, rd_last);
          errors = errors + 1;
        end
        rxi = rxi + 1;
      end
    end
    repeat (4) @(negedge clk);

    if (errors == 0) $display("MEM PASS（write16, read16, combine32: aw=%0d, strb0-neg, unalign8B）", aw_count);
    else             $display("MEM FAIL errors=%0d", errors);
    $finish;
  end

  // 超时保护
  initial begin
    #200000;
    $display("MEM FAIL timeout（aw=%0d w=%0d ar=%0d wr_ready=%0d wrs=%0d wcnt=%0d rds=%0d bvalid=%0d wactive=%0d wleft=%0d）",
             aw_count, w_count, ar_count, wr_ready, dbg_wrs, dbg_wcnt, dbg_rds, dbg_bvalid, dbg_wactive, dbg_wleft);
    $finish;
  end

endmodule
