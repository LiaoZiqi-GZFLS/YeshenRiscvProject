// tb_tri_raster.v —— tri_setup + tri_raster 单元闸门：逐像素颜色 + Z 对 C 黄金。
//
// 输入（由 sim/gpu/tri_ref.py 生成，加 -I<dir> 或用 `define）：
//   TRI_FILE : 每行一个三角形 `v0x v0y v1x v1y v2x v2y z0 color dzdx dzdy zmode`（hex）
//   EXP_FILE : 每行一个像素 `color z`（hex，W*H 行）
`timescale 1ns/1ps
`include "tri_cfg.svh"
module tb_tri_raster;

  parameter W = 128;
  parameter H = 96;
  localparam NPX = W * H;

  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  // ---- setup ----
  reg         st_start = 0;
  reg  [31:0] v0x = 0, v0y = 0, v1x = 0, v1y = 0, v2x = 0, v2y = 0;
  wire        st_busy, st_done;
  wire signed [23:0] a0, b0, a1, b1, a2, b2;
  wire signed [47:0] c0, c1, c2;
  wire [15:0] bx0, by0, bx1, by1;
  wire signed [47:0] area;
  wire        degen;

  tri_setup u_setup (
      .clk(clk), .rst(rst),
      .start(st_start),
      .v0x(v0x), .v0y(v0y), .v1x(v1x), .v1y(v1y), .v2x(v2x), .v2y(v2y),
      .wmax(W[15:0]), .hmax(H[15:0]),
      .busy(st_busy), .done(st_done),
      .a0(a0), .b0(b0), .a1(a1), .b1(b1), .a2(a2), .b2(b2),
      .c0(c0), .c1(c1), .c2(c2),
      .bx0(bx0), .by0(by0), .bx1(bx1), .by1(by1),
      .area(area), .degen(degen)
  );

  // ---- raster ----
  reg         ra_start = 0;
  reg  [15:0] r_color = 0, r_z0 = 0;
  reg  signed [23:0] r_dzdx = 0, r_dzdy = 0;
  reg  [23:0] r_vx0 = 0, r_vy0 = 0;
  reg  [1:0]  r_zmode = 0;
  wire        ra_busy, ra_done;
  wire [17:0] z_raddr;
  wire [15:0] z_rdata;
  wire        we;
  wire [17:0] waddr;
  wire [15:0] wcolor, wz;

  reg [15:0] color_mem [0:NPX-1];
  reg [15:0] z_mem     [0:NPX-1];
  assign z_rdata = z_mem[z_raddr];

  tri_raster u_raster (
      .clk(clk), .rst(rst),
      .start(ra_start),
      .a0(a0), .b0(b0), .a1(a1), .b1(b1), .a2(a2), .b2(b2),
      .c0(c0), .c1(c1), .c2(c2),
      .bx0(bx0), .by0(by0), .bx1(bx1), .by1(by1),
      .stride(W[15:0]), .xorg(16'd0), .yorg(16'd0),
      .color(r_color), .z0v(r_z0),
      .dzdx(r_dzdx), .dzdy(r_dzdy),
      .vx0(r_vx0), .vy0(r_vy0),
      .zmode(r_zmode),
      .busy(ra_busy), .done(ra_done),
      .z_raddr(z_raddr), .z_rdata(z_rdata),
      .we(we), .waddr(waddr), .wcolor(wcolor), .wz(wz)
  );

  always @(posedge clk) begin
    if (we) begin
      color_mem[waddr] <= wcolor;
      z_mem[waddr]     <= wz;
    end
  end

  integer i, ntri, errors, fd, r;
  integer tv0x, tv0y, tv1x, tv1y, tv2x, tv2y, tz0, tcolor, tdzdx, tdzdy, tzm;
  integer ec, ez;
  reg [31:0] tmp;
  integer nread;

  initial begin
    for (i = 0; i < NPX; i = i + 1) begin
      color_mem[i] = 16'd0;
      z_mem[i]     = 16'hFFFF;
    end
    errors = 0;
    ntri   = 0;
    repeat (4) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);

    fd = $fopen(`TRI_FILE, "r");
    if (fd == 0) begin
      $display("TB-ERROR cannot open TRI_FILE");
      $finish;
    end
    while (!$feof(fd)) begin
      r = $fscanf(fd, "%x %x %x %x %x %x %x %x %x %x %x\n",
                  tv0x, tv0y, tv1x, tv1y, tv2x, tv2y, tz0, tcolor, tdzdx, tdzdy, tzm);
      if (r == 11) begin
        ntri = ntri + 1;
        // ---- setup ----
        @(negedge clk);
        v0x = tv0x; v0y = tv0y; v1x = tv1x; v1y = tv1y; v2x = tv2x; v2y = tv2y;
        st_start = 1;
        @(negedge clk);
        st_start = 0;
        while (!st_done) @(negedge clk);
        if (`DBG != 0) $display("  [dbg] tri %0d setup done bbox=(%0d,%0d)-(%0d,%0d) area=%0d degen=%0d",
                                ntri, bx0, by0, bx1, by1, area, degen);
        // ---- raster ----
        @(negedge clk);
        r_color = tcolor[15:0];
        r_z0    = tz0[15:0];
        r_dzdx  = tdzdx[23:0];
        r_dzdy  = tdzdy[23:0];
        r_vx0   = tv0x[23:0];
        r_vy0   = tv0y[23:0];
        r_zmode = tzm[1:0];
        ra_start = 1;
        @(negedge clk);
        ra_start = 0;
        while (!ra_done) @(negedge clk);
        if (`DBG != 0) $display("  [dbg] tri %0d raster done", ntri);
      end
    end
    $fclose(fd);

    // ---- 逐像素比对 ----
    fd = $fopen(`EXP_FILE, "r");
    if (fd == 0) begin
      $display("TB-ERROR cannot open EXP_FILE");
      $finish;
    end
    i = 0;
    while (!$feof(fd) && i < NPX) begin
      r = $fscanf(fd, "%x %x\n", ec, ez);
      if (r == 2) begin
        if ((color_mem[i] !== ec[15:0]) || (z_mem[i] !== ez[15:0])) begin
          if (errors < 8)
            $display("  MISMATCH idx=%0d (x=%0d,y=%0d) got=%04x/%04x exp=%04x/%04x",
                     i, i % W, i / W, color_mem[i], z_mem[i], ec[15:0], ez[15:0]);
          errors = errors + 1;
        end
        i = i + 1;
      end
    end
    $fclose(fd);

    if (errors == 0) $display("TRI PASS（%0d 三角形，%0d 像素逐点吻合）", ntri, NPX);
    else             $display("TRI FAIL mismatches=%0d", errors);
    $finish;
  end

  initial begin
    #20000000;
    $display("TRI TIMEOUT");
    $finish;
  end

endmodule
