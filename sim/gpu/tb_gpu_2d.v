// tb_gpu_2d.v —— gpu_cmd + gpu_2d + gpu_mem + AXI RAM 的端到端像素闸门。
//
// 流程：$readmemh 预载初始帧存（+素材）→ 按 <case>.cmds.hex 回放命令 →
//       等命令 FSM 空闲、写侧排干 → 逐 8 B 字与 <case>.exp.hex 比对。
// 由 run_2d.sh 生成 tb_cfg.svh 指定三个文件路径（每次重编，路径写死最稳）。
`timescale 1ns/1ps
`include "tb_cfg.svh"

module tb_gpu_2d;

  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  localparam FB_WORDS = 153600;   // 1024*600*2/8
`ifdef RAM_TRUNC32
  localparam RAM_T32 = 1;         // 板级 DDR 用户口：突发起始按 32 B 块对齐
`else
  localparam RAM_T32 = 0;
`endif

  // ---------------- cmd ----------------
  reg  [31:0] wr_word = 0;
  reg         wr_en = 0;
  wire [4:0]  used;
  wire        cmd_busy;
  wire        cmd_start; wire [7:0] cmd_op, cmd_nwords; wire [15:0] cmd_flags;
  wire [31:0] par_data;  wire par_valid, par_ready;
  wire        cmd_done;
  wire [15:0] seq_done;  wire [7:0] last_op; wire [15:0] last_cycles;
  wire [2:0]  dbg_cstate; wire [7:0] dbg_cleft;

  gpu_cmd u_cmd (
      .clk(clk), .rst(rst),
      .wr_word(wr_word), .wr_en(wr_en), .wr_push(1'b0),
      .used(used), .busy(cmd_busy),
      .cmd_start(cmd_start), .cmd_op(cmd_op), .cmd_nwords(cmd_nwords), .cmd_flags(cmd_flags),
      .par_data(par_data), .par_valid(par_valid), .par_ready(par_ready),
      .cmd_done(cmd_done), .seq_done(seq_done), .last_op(last_op), .last_cycles(last_cycles),
      .dbg_state(dbg_cstate), .dbg_left(dbg_cleft)
  );

  // ---------------- 2d ----------------
  wire        wr_valid, wr_flush, wr_idle;
  wire        rd_req, rd_busy, rd_valid, rd_last;
  wire [31:0] rd_addr;
  wire [7:0]  rd_beats;
  wire [63:0] rd_data;
  wire [31:0] wr_addr;
  wire [63:0] wr_data;
  wire [7:0]  wr_strb;
  wire        wr_ready;
  wire [4:0]  dbg_state;
  wire [15:0] dbg_brow, dbg_bcx, dbg_bcxe; wire [6:0] dbg_cpx;
  wire [31:0] dbg_px, dbg_npx, dbg_nflush;
  wire [15:0] dbg_xe, dbg_pxw, dbg_scx1;
  wire [31:0] dbg_p0, dbg_p1, dbg_p2, dbg_p3, dbg_p4, dbg_p5, dbg_p6;
  wire dbg_cap; wire [7:0] dbg_pcnt, dbg_op;

  gpu_2d u_2d (
      .clk(clk), .rst(rst),
      .cmd_start(cmd_start), .cmd_op(cmd_op), .cmd_nwords(cmd_nwords), .cmd_flags(cmd_flags),
      .par_data(par_data), .par_valid(par_valid), .par_ready(par_ready),
      .cmd_done(cmd_done),
      .wr_valid(wr_valid), .wr_addr(wr_addr), .wr_data(wr_data), .wr_strb(wr_strb),
      .wr_ready(wr_ready), .wr_flush(wr_flush), .wr_idle(wr_idle),
      .rd_req(rd_req), .rd_addr(rd_addr), .rd_beats(rd_beats), .rd_busy(rd_busy),
      .rd_data(rd_data), .rd_valid(rd_valid), .rd_last(rd_last),
      .dbg_state(dbg_state), .dbg_px(dbg_px), .dbg_npx(dbg_npx), .dbg_nflush(dbg_nflush),
      .dbg_brow(dbg_brow), .dbg_bcx(dbg_bcx), .dbg_bcxe(dbg_bcxe), .dbg_cpx(dbg_cpx)
  );

  // ---------------- mem + ram ----------------
  wire [31:0] araddr, awaddr;
  wire [7:0]  arlen, awlen;
  wire [2:0]  arsize, awsize;
  wire [1:0]  arburst, awburst;
  wire        arvalid, awvalid, arready, awready;
  wire [63:0] rdata, wdata;
  wire [7:0]  wstrb;
  wire        rlast, rvalid, rready, wlast, wvalid, wready, bvalid, bready;
  wire [1:0]  bresp;
  wire [31:0] aw_count, w_count, ar_count;
  wire [1:0]  dbg_rds, dbg_wrs;
  wire [4:0]  dbg_wcnt;
  reg  [18:0] dbg_idx = 0;
  wire [63:0] dbg_word;

  gpu_mem u_mem (
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
      .dbg_wrs(dbg_wrs), .dbg_wcnt(dbg_wcnt), .dbg_rds(dbg_rds), .wr_idle(wr_idle)
  );

  axi_ram_model #(.AW(19), .INIT_FILE(`INIT_FILE), .TRUNC32(RAM_T32)) ram (
      .clk(clk), .rst(rst),
      .araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
      .rdata(rdata), .rlast(rlast), .rvalid(rvalid), .rready(rready),
      .awaddr(awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
      .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
      .bresp(bresp), .bvalid(bvalid), .bready(bready),
      .aw_count(aw_count), .w_count(w_count), .ar_count(ar_count),
      .dbg_idx(dbg_idx), .dbg_word(dbg_word),
      .dbg_bvalid(), .dbg_wactive(), .dbg_wleft()
  );


  reg [4:0] lst = 5'h1F; integer nst = 0;
  always @(negedge clk) begin
    if (dbg_state != lst && nst < 30) begin
      $display("  [st] %0d -> %0d  row=%0d cx=%0d cxe=%0d cpx=%0d", lst, dbg_state, dbg_brow, dbg_bcx, dbg_bcxe, dbg_cpx);
      lst <= dbg_state; nst = nst + 1;
    end
  end

  // ---------------- 期望值 ----------------
  reg [63:0] exp_mem [0:FB_WORDS-1];
  initial $readmemh(`EXP_FILE, exp_mem);

  // ---------------- 命令流 ----------------
  reg [31:0] cw [0:8191];
  integer i, fd, errors = 0, nwords = 0, beats = 0, wr_cyc = 0, rem = 0;
  always @(posedge clk) begin
    if (wr_valid && wr_ready) beats = beats + 1;
    if (wr_valid) wr_cyc = wr_cyc + 1;
  end
  reg [31:0] sentinel = 32'hFFFF_FFFF;
  reg [31:0] dm;

  initial begin
    for (i = 0; i < 8192; i = i + 1) cw[i] = 32'hFFFF_FFFF;
    $readmemh(`CMD_FILE, cw);
    repeat (4) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);

    // 回放命令字：**只在命令边界**限流（命令中途停手会互相等死）
    rem = 0;
    for (i = 0; i < 8192 && cw[i] !== 32'hFFFF_FFFF; i = i + 1) begin
      if (rem == 0) begin
        while (used != 5'd0) @(negedge clk);   // 等上一条整条吃掉
        rem = (cw[i] >> 16) & 8'h7F;           // nwords
      end else begin
        rem = rem - 1;
      end
      @(negedge clk);
      wr_word = cw[i];
      wr_en   = 1'b1;
      @(negedge clk);
      wr_en   = 1'b0;
    end
    nwords = i;

    // 等命令 FSM 空闲 + 写侧排干
    repeat (20) @(negedge clk);
    while (cmd_busy || used != 5'd0 || !wr_idle || dbg_state != 5'd0)
      @(negedge clk);
    repeat (20) @(negedge clk);

    // 逐字比对
    for (i = 0; i < FB_WORDS; i = i + 1) begin
      dbg_idx = i[18:0];
      #1;
      if (dbg_word !== exp_mem[i]) begin
        if (errors < 8)
          $display("  MISMATCH idx=%0d got=%016x exp=%016x", i, dbg_word, exp_mem[i]);
        errors = errors + 1;
      end
    end

    $display("cmds_words=%0d seq=%0d aw=%0d w=%0d npx=%0d nflush=%0d beats=%0d wr_cyc=%0d wrs=%0d wcnt=%0d wr_ready=%0d",
             nwords, seq_done, aw_count, w_count, dbg_npx, dbg_nflush, beats, wr_cyc, dbg_wrs, dbg_wcnt, wr_ready);
    if (errors == 0) $display("2D PASS（逐字节吻合 %0d 字）", FB_WORDS);
    else             $display("2D FAIL mismatches=%0d", errors);
    $finish;
  end

  initial begin
    #50_000_000;
    $display("2D FAIL timeout（state=%0d cmd=%0d used=%0d wr_idle=%0d ar=%0d rd_busy=%0d rd_valid=%0d）",
             dbg_state, dbg_cstate, used, wr_idle, ar_count, rd_busy, rd_valid);
    $finish;
  end

endmodule
