// tb_gpu_csr.v —— gpu_csr + gpu_cmd 单元闸门：
//   ① ID magic
//   ② 一条 FILL（1 头 + 5 参数，最后字用 CMD_PUSH）：cmd_start/参数流/SEQ_DONE++
//   ③ FENCE：SEQ_DONE 等于它的 seq 参数
//   ④ SCISSOR 读写回
//   ⑤ FLIP：pending 置位 → vsync 清位并翻转 flip_toggle
//   ⑥ 未实现偏移（0x040）写忽略、读 0
//   ⑦ 命令消费完后 FIFO_FREE 回到 16
`timescale 1ns/1ps
module tb_gpu_csr;

  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  // AXI-Lite
  reg  [11:0] awaddr = 0; reg awvalid = 0;
  reg  [31:0] wdata = 0;  reg [3:0] wstrb = 0; reg wvalid = 0;
  wire        bvalid;     reg bready = 1;
  reg  [11:0] araddr = 0; reg arvalid = 0;
  wire [31:0] rdata;      wire rvalid; reg rready = 1;

  wire [31:0] cmd_word; wire cmd_wr, cmd_push;
  wire [4:0]  cmd_used; wire cmd_busy;
  wire [15:0] seq_done; wire [7:0] last_op; wire [15:0] last_cycles;
  wire [2:0] dbg_state; wire [7:0] dbg_left;
  wire        flip_toggle;
  reg         vsync = 0;

  gpu_csr csr (
      .clk(clk), .rst(rst),
      .s_awaddr(awaddr), .s_awvalid(awvalid), .s_awready(),
      .s_wdata(wdata), .s_wstrb(wstrb), .s_wvalid(wvalid), .s_wready(),
      .s_bvalid(bvalid), .s_bready(bready),
      .s_araddr(araddr), .s_arvalid(arvalid), .s_arready(),
      .s_rdata(rdata), .s_rvalid(rvalid), .s_rready(rready),
      .cmd_word(cmd_word), .cmd_wr(cmd_wr), .cmd_push(cmd_push),
      .cmd_used(cmd_used), .cmd_busy(cmd_busy), .seq_done(seq_done),
      .last_op(last_op), .last_cycles(last_cycles),
      .dbg_st3d(8'd0), .dbg_mem(8'd0),
      .flip_toggle(flip_toggle), .vsync(vsync)
  );

  // 执行器模型：hold>0 时每笔完成后再等 hold 拍（验 FENCE 的"等引擎"语义）
  reg        par_ready = 1;
  reg [7:0]  need = 0;
  reg        done_p = 0;
  integer    hold = 0;
  reg [15:0] hcnt = 0;
  reg        pend = 0;
  wire       cmd_start; wire [7:0] cmd_op, cmd_nwords; wire [15:0] cmd_flags;
  wire [31:0] par_data; wire par_valid;

  gpu_cmd cmd (
      .clk(clk), .rst(rst),
      .wr_word(cmd_word), .wr_en(cmd_wr), .wr_push(cmd_push),
      .used(cmd_used), .busy(cmd_busy),
      .cmd_start(cmd_start), .cmd_op(cmd_op), .cmd_nwords(cmd_nwords),
      .cmd_flags(cmd_flags),
      .par_data(par_data), .par_valid(par_valid), .par_ready(par_ready),
      .cmd_done(done_p),
      .seq_done(seq_done), .last_op(last_op), .last_cycles(last_cycles),
      .dbg_state(dbg_state), .dbg_left(dbg_left)
  );

  always @(posedge clk) begin
    if (rst) begin
      done_p <= 0; need <= 0; pend <= 0; hcnt <= 0;
    end else begin
      done_p <= 1'b0;
      if (cmd_start) begin
        need <= cmd_nwords;
        hcnt <= hold[15:0];
        if (cmd_nwords == 8'd0) pend <= 1'b1;
      end else if (par_valid && par_ready && need != 8'd0) begin
        if (need == 8'd1) pend <= 1'b1;
        need <= need - 8'd1;
      end
      if (pend) begin
        if (hcnt == 16'd0) begin pend <= 1'b0; done_p <= 1'b1; end
        else hcnt <= hcnt - 16'd1;
      end
    end
  end

  integer errors = 0;
  task automatic chk(input [31:0] got, input [31:0] exp, input [127:0] tag);
    begin
      if (got !== exp) begin
        $display("  MISMATCH %0s got=%08x exp=%08x", tag, got, exp);
        errors = errors + 1;
      end
    end
  endtask

  task automatic axi_wr(input [11:0] a, input [31:0] d);
    begin
      @(negedge clk);
      awaddr = a; awvalid = 1; wdata = d; wstrb = 4'hF; wvalid = 1;
      @(negedge clk);
      awvalid = 0; wvalid = 0;
    end
  endtask

  task automatic axi_rd(input [11:0] a, output [31:0] d);
    begin
      @(negedge clk);
      araddr = a; arvalid = 1;
      @(negedge clk);
      arvalid = 0;
      d = rdata;
    end
  endtask

  // 参数收集
  reg [31:0] got_par [0:7];
  integer    npar = 0;
  reg [7:0]  seen_op = 0;
  integer    starts = 0;

  always @(posedge clk) begin
    if (par_valid && par_ready) $display("  [dbg] par_valid data=%08x state=%0d left=%0d", par_data, dbg_state, dbg_left);
    if (par_valid && par_ready && npar < 8) begin
      got_par[npar] <= par_data;
      npar <= npar + 1;
    end
    if (cmd_start) begin
      seen_op <= cmd_op;
      starts  <= starts + 1;
      npar    <= 0;
    end
  end

  reg [31:0] d;
  integer i;

  initial begin
    repeat (4) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);

    // ① ID
    axi_rd(12'h000, d);
    chk(d, 32'h59475055, "ID");

    // ② FILL: 头 {op=02,nwords=5,flags=0} + 5 参数（最后字走 CMD_PUSH）
    axi_wr(12'h010, {8'h02, 8'd5, 16'h0000});
    axi_wr(12'h010, 32'h9220_0000);       // dst
    axi_wr(12'h010, 32'd1024);            // stride_px
    axi_wr(12'h010, 32'd10);              // x
    axi_wr(12'h010, 32'd20);              // y
    axi_wr(12'h014, 32'h0000_07E0);       // w|h<<16（最后字，PUSH）
    repeat (30) @(negedge clk);
    chk({24'd0, seen_op}, 32'h02, "FILL op");
    if (starts != 1) begin
      $display("  MISMATCH starts=%0d (exp 1)", starts);
      errors = errors + 1;
    end
    if (npar != 5) begin
      $display("  MISMATCH params=%0d (exp 5)", npar);
      errors = errors + 1;
    end
    chk(got_par[0], 32'h9220_0000, "FILL p0");
    chk(got_par[1], 32'd1024,      "FILL p1");
    chk(got_par[4], 32'h0000_07E0, "FILL p4");
    chk({16'd0, seq_done}, 32'd1, "SEQ after FILL");

    // ③ FENCE seq=0x1234（1 个参数）
    axi_wr(12'h010, {8'h07, 8'd1, 16'h0000});
    axi_wr(12'h014, 32'h0000_1234);
    repeat (20) @(negedge clk);
    chk({16'd0, seq_done}, 32'h1234, "SEQ after FENCE");

    // ④ SCISSOR
    axi_wr(12'h020, 32'h0064_00C8);       // x0=200,y0=100
    axi_wr(12'h024, 32'h012C_0190);       // x1=300,y1=400
    axi_rd(12'h020, d); chk(d, 32'h0064_00C8, "SC0");
    axi_rd(12'h024, d); chk(d, 32'h012C_0190, "SC1");

    // ⑤ FLIP
    axi_wr(12'h028, 32'h1);
    axi_rd(12'h004, d);
    if (d[16] !== 1'b1) begin
      $display("  MISMATCH STATUS.flip_pending=0 after FLIP");
      errors = errors + 1;
    end
    if (d[17] !== 1'b0) begin
      $display("  MISMATCH STATUS.flip_toggle=1 before vsync（回读位应是旧 bank）");
      errors = errors + 1;
    end
    @(negedge clk); vsync = 1;
    @(negedge clk); vsync = 0;
    repeat (2) @(negedge clk);
    axi_rd(12'h004, d);
    if (d[16] !== 1'b0) begin
      $display("  MISMATCH STATUS.flip_pending still set after vsync");
      errors = errors + 1;
    end
    if (flip_toggle !== 1'b1) begin
      $display("  MISMATCH flip_toggle did not toggle");
      errors = errors + 1;
    end
    // [17] 回读位必须与生效的 flip_toggle 一致（翻转后读回 1）
    if (d[17] !== 1'b1) begin
      $display("  MISMATCH STATUS.flip_toggle=0 after vsync（回读位没跟上翻转）");
      errors = errors + 1;
    end
    // 第二次 FLIP + vsync ⇒ 回读位跟着回到 0
    axi_wr(12'h028, 32'h1);
    @(negedge clk); vsync = 1; @(negedge clk); vsync = 0;
    repeat (2) @(negedge clk);
    axi_rd(12'h004, d);
    if (d[17] !== 1'b0) begin
      $display("  MISMATCH STATUS.flip_toggle=1 after 2nd flip（回读位没回到 0）");
      errors = errors + 1;
    end

    // ⑥ 未实现偏移
    axi_wr(12'h040, 32'hDEAD_BEEF);
    axi_rd(12'h040, d); chk(d, 32'd0, "unimpl-0x040");

    // ⑧ FENCE 完成语义：FENCE 自己的引擎完成之前，SEQ_DONE 不得提前发布
    //    （板上实测：无此约束时软件读到半成品）
    repeat (10) @(negedge clk);
    hold = 60;
    axi_wr(12'h010, {8'h07, 8'd1, 16'h0000});   // 慢 FENCE（1 参数）
    axi_wr(12'h014, 32'h0000_2222);
    wait (par_valid && par_ready);              // 参数被收下的那一拍
    @(negedge clk);
    repeat (10) @(negedge clk);                 // 引擎还要 60 拍
    if (seq_done === 16'h2222) begin
      $display("  MISMATCH FENCE 提前发布（引擎未完成时 seq_done=%04x）", seq_done);
      errors = errors + 1;
    end
    wait (seq_done === 16'h2222);               // 最终必须发布
    repeat (2) @(negedge clk);
    chk({16'd0, seq_done}, 32'h2222, "SEQ after slow FENCE");
    hold = 0;

    // ⑦ FIFO 空闲回到 16
    repeat (10) @(negedge clk);
    axi_rd(12'h01C, d); chk(d, 32'd16, "FIFO_FREE");

    if (errors == 0) $display("CSR PASS（id, fill, fence, scissor, flip, unimpl, fifo-free）");
    else             $display("CSR FAIL errors=%0d", errors);
    $finish;
  end

  initial begin
    #100000;
    $display("CSR FAIL timeout（used=%0d busy=%0d）", cmd_used, cmd_busy);
    $finish;
  end

endmodule
