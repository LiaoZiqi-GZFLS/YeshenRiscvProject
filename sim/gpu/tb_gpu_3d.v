// tb_gpu_3d.v —— gpu_3d(CLEAR3D + DRAW_TRIS) + gpu_mem + AXI RAM 模型端到端闸门。
//
// 流程：读 cfg（W H TRI_ADDR TRI_COUNT CB CS ZB ZS CLEAR_C CLEAR_Z）→ 发 CLEAR3D →
//      发 DRAW_TRIS → 逐像素对黄金（颜色 + Z）。
// 三角形记录由 mk3d_case.py 生成的 ram.hex 预载进 RAM 模型（@字地址语法）。
`timescale 1ns/1ps
`include "tri3d_cfg.svh"
module tb_gpu_3d;

  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

`ifdef RAM_TRUNC32
  localparam RAM_T32 = 1;      // 板级 DDR 用户口：突发起始按 32 B 块对齐
`else
  localparam RAM_T32 = 0;
`endif

  wire        rd_req, rd_busy, rd_valid, rd_last;
  wire [31:0] rd_addr;
  wire [7:0]  rd_beats;
  wire [63:0] rd_data;
  wire [7:0]  dbg_state;

  wire        wr_valid, wr_ready, wr_flush, wr_idle;
  wire [31:0] wr_addr;
  wire [63:0] wr_data;
  wire [7:0]  wr_strb;

  // 背压档（`-GWSTALL=1`，见 run_3d_stall.sh）：**在 gpu_mem 内部**掐 wr_ready，
  // 收发两侧看到同一个 ready。⚠️ 不能只在 TB 侧把 ready 挡给生产者 —— gpu_mem 内部仍会
  // 按自己的 ready 收数，于是"保持到 ready"的生产者会把同一拍重复交付（实测假红）。
`ifdef WSTALL
  integer stall_cyc = 0;
  always @(posedge clk) if (wr_valid && !wr_ready) stall_cyc = stall_cyc + 1;
  final $display("  [wstall] wr_valid&&!wr_ready 拍数 = %0d | dbg_state=%02x（bit7=非法状态粘滞）", stall_cyc, dbg_state);
`endif

  wire [31:0] araddr, awaddr;
  wire [7:0]  arlen, awlen;
  wire [2:0]  arsize, awsize;
  wire [1:0]  arburst, awburst;
  wire        arvalid, arready, awvalid, awready;
  wire [63:0] rdata, wdata;
  wire [1:0]  rresp, bresp;
  wire        rlast, rvalid, rready, wlast, wvalid, wready, bvalid, bready;
  wire [7:0]  wstrb;
  wire [31:0] aw_count, w_count, ar_count;

  reg         start = 0;
  reg  [7:0]  op = 8'h10;
  reg  [31:0] p0 = 0, p1 = 0, p2 = 0, p3 = 0, p4 = 0, p5 = 0, p6 = 0, p7 = 0;
  wire        busy, done;

  gpu_3d u_3d (
      .clk(clk), .rst(rst), .start(start), .op(op),
      .p0(p0), .p1(p1), .p2(p2), .p3(p3), .p4(p4), .p5(p5), .p6(p6), .p7(p7),
      .busy(busy), .done(done),
      .rd_req(rd_req), .rd_addr(rd_addr), .rd_beats(rd_beats),
      .rd_busy(rd_busy), .rd_data(rd_data), .rd_valid(rd_valid), .rd_last(rd_last),
      .wr_valid(wr_valid), .wr_addr(wr_addr), .wr_data(wr_data), .wr_strb(wr_strb),
      .wr_ready(wr_ready), .wr_flush(wr_flush), .wr_idle(wr_idle),
      .dbg_state(dbg_state)
  );

  gpu_mem u_mem (
      .clk(clk), .rst(rst),
      .rd_req(rd_req), .rd_addr(rd_addr), .rd_beats(rd_beats),
      .rd_busy(rd_busy), .rd_data(rd_data), .rd_valid(rd_valid), .rd_last(rd_last),
      .wr_valid(wr_valid), .wr_addr(wr_addr), .wr_data(wr_data), .wr_strb(wr_strb),
      .wr_ready(wr_ready), .wr_flush(wr_flush),
      .m_araddr(araddr), .m_arlen(arlen), .m_arsize(arsize), .m_arburst(arburst),
      .m_arvalid(arvalid), .m_arready(arready),
      .m_rdata(rdata), .m_rresp(2'b00), .m_rlast(rlast), .m_rvalid(rvalid), .m_rready(rready),
      .m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(awsize), .m_awburst(awburst),
      .m_awvalid(awvalid), .m_awready(awready),
      .m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast), .m_wvalid(wvalid), .m_wready(wready),
      .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
      .dbg_wrs(), .dbg_wcnt(), .dbg_rds(), .wr_idle(wr_idle),
      .dbg_rd_ar(), .dbg_rd_cnt(), .dbg_rd_len(), .dbg_rd_b01(), .dbg_rd_b23()
  );

  reg  [15:0] dbg_idx;
  wire [63:0] dbg_word;

  axi_ram_model #(.AW(16), .INIT_FILE(`INIT_FILE), .TRUNC32(RAM_T32)) ram (
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

  integer errors = 0;
  integer fd, r, i, k, wcount, fr;
  integer t_w, t_h, t_tri, t_cnt, t_cb, t_cs, t_zb, t_zs, t_cc, t_cz;
  integer t_comp, t_db, t_ds, t_dx, t_dy, t_dn, t_dw, t_dh;
  integer ec, ez, got_c, got_z;
  reg [63:0] cw_word, zw_word;
  reg [31:0] idx_c, idx_z;

  task run_cmd(input [7:0] cop, input [31:0] a0, a1, a2, a3, a4, a5, a6, a7);
    begin
      @(negedge clk);
      op = cop; p0 = a0; p1 = a1; p2 = a2; p3 = a3; p4 = a4; p5 = a5; p6 = a6; p7 = a7;
      start = 1;
      @(negedge clk);
      start = 0;
      while (!done) @(negedge clk);
      repeat (10) @(negedge clk);
    end
  endtask

  initial begin
    fd = $fopen(`CFG_FILE, "r");
    if (fd == 0) begin $display("TB-ERROR cfg"); $finish; end
    r = $fscanf(fd, "%d %d %d %d %d %d %d %d %x %x %d %d %d %d %d %d\n",
                t_w, t_h, t_tri, t_cnt, t_cb, t_cs, t_zb, t_zs, t_cc, t_cz,
                t_comp, t_db, t_ds, t_dx, t_dy, t_dn);
    $fclose(fd);
    if (r != 16) begin $display("TB-ERROR cfg parse r=%0d", r); $finish; end
    t_dw = t_ds;
    t_dh = (t_ds == 0) ? 0 : (t_dn / t_ds);

    repeat (4) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);

    run_cmd(8'h10, t_cc, t_cz, t_w, t_h, t_cb, t_cs, t_zb, t_zs);      // CLEAR3D
    if (t_comp != 0)
      run_cmd(8'h10, 32'hAAAA, 32'hFFFF, t_dw, t_dh, t_db, t_ds, t_zb, t_zs); // 目标区哨兵
    run_cmd(8'h11, t_tri, t_cnt, t_w, t_h, t_cb, t_cs, t_zb, t_zs);    // DRAW_TRIS
    if (t_comp != 0)
      run_cmd(8'h12, t_cb, t_cs, t_db, t_ds, t_w, t_h, t_dx, t_dy);    // COMPOSITE3D

    fd = $fopen(`EXP_FILE, "r");
    if (fd == 0) begin $display("TB-ERROR exp"); $finish; end
    wcount = (t_w * t_h) / 4;
    for (k = 0; k < wcount; k = k + 1) begin
      idx_c = (t_cb / 8) + k;
      idx_z = (t_zb / 8) + k;
      dbg_idx = idx_c[15:0]; #1; cw_word = dbg_word;
      dbg_idx = idx_z[15:0]; #1; zw_word = dbg_word;
      for (i = 0; i < 4; i = i + 1) begin
        fr = $fscanf(fd, "%x %x\n", ec, ez);
        got_c = (i == 0) ? cw_word[15:0]  :
                (i == 1) ? cw_word[31:16] :
                (i == 2) ? cw_word[47:32] : cw_word[63:48];
        got_z = (i == 0) ? zw_word[15:0]  :
                (i == 1) ? zw_word[31:16] :
                (i == 2) ? zw_word[47:32] : zw_word[63:48];
        if ((fr != 2) || (got_c !== ec) || (got_z !== ez)) begin
          if (errors < 8)
            $display("  MISMATCH idx=%0d got=%04x/%04x exp=%04x/%04x fr=%0d",
                     k * 4 + i, got_c, got_z, ec, ez, fr);
          errors = errors + 1;
        end
      end
    end
    // 复合目标区（CLEAR3D 填哨兵，COMPOSITE3D 覆盖源矩形）
    if (t_comp != 0) begin
      wcount = t_dn / 4;
      for (k = 0; k < wcount; k = k + 1) begin
        idx_c = (t_db / 8) + k;
        dbg_idx = idx_c[15:0]; #1; cw_word = dbg_word;
        for (i = 0; i < 4; i = i + 1) begin
          fr = $fscanf(fd, "%x %x\n", ec, ez);
          got_c = (i == 0) ? cw_word[15:0]  :
                  (i == 1) ? cw_word[31:16] :
                  (i == 2) ? cw_word[47:32] : cw_word[63:48];
          if ((fr != 2) || (got_c !== ec)) begin
            if (errors < 16)
              $display("  MISMATCH comp idx=%0d got=%04x exp=%04x fr=%0d",
                       k * 4 + i, got_c, ec, fr);
            errors = errors + 1;
          end
        end
      end
    end
    $fclose(fd);

    if (errors == 0) $display("3D PASS（DRAW_TRIS %0dx%0d，%0d 三角形%s，aw=%0d w=%0d）",
                              t_w, t_h, t_cnt, (t_comp != 0) ? " +COMPOSITE" : "",
                              aw_count, w_count);
    else             $display("3D FAIL errors=%0d", errors);
    $finish;
  end

  initial begin
    #50000000;
    $display("3D TIMEOUT state=%0d", dbg_state);
    $finish;
  end

endmodule
