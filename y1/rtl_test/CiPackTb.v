//=============================================================================
// CiPackTb.v —— NPU v2 切片 C-1：**dense ci-inner 探针**的数值装置（纯 Verilog）。
//
// 被测 = `gen/CiPack{Base,Dci,DciMut5}.v`（`rtl_test/CiPackProbe.scala`，模块名恒为 CiPackProbe）。
//   · Base（DCI=false） = B1 落地后的切片当量（dense 广播 9 拍 + dw 逐 lane AFTER1）；
//   · Dci （DCI=true）  = Base + **c3 ci-inner**（`dci_mode`/`c3_cin` 两个 additive 入）。
//
// 装置口径沿用 `DwLaneTb.v`（同一套"每趟 = 一个 co-block"的编排），只把 dw 的对角趟换成**密集趟**：
//   · 每趟 = 一个 co-block（`NB = ceil(COUT/8)` 趟）；权重瓦片序 = 趟序 `[pass][cl][cil][tap]`（576 B/趟）；
//   · 喂 `H+1` 行（第 H 行 = 0 pad 行）× IW 列；只收 `NPIX = H*IW` 个有效像素/趟；
//   · `+NCIP` = 本层的 ci-block 数（真表这些单元 n_ci == 1 ⇒ 每趟读同一个 ci-block）；
//   · `+GARB=1` 时把 lane ≥ CIN 的 x 喂**非零垃圾**（证"补位 lane 由权重零填负责、值任意"）；
//   · `+DCI=1`（只有 Dci 网表有这些口）：`dci_mode=1`、`c3_cin=CIN`；`+DW=1`：`dw_mode=1`（回归 dw 档）。
//
// 判据（数值在 `tools/run_cipack_ab.sh` 里对；本装置只自检"跑完了 + 协议对"）：
//   0) time 0 对账：`+IW == imgW`（网表宽度钉死）、`+CIN/COUT ≤ 8·NB`；`+DCI` 与网表档位对账（modeId）。
//   1) 每趟产出**恰好** `NPIX` 个像素、零多余；趟数**恰好** `NB`。
//   2) 自报 `BEATS`（= `arr.en` 拍数差分和）⇒ 闸门按 `taps·NB·NPIX` 的**预测量**断言：
//      Base 9 拍/像素/趟；Dci 的 dense 作业 `CIN` 拍；dw 作业（DW=1）1 拍/像素/趟。
//
// 用法（plusarg）：
//   +XFILE= +WFILE= +BFILE= +CIN= +COUT= +H= +IW= +M= +ZY= +NCIP= +DCI= +GARB= +DW=
//   stdout：`CIPACK <k>=<v> ...`（自报）+ 一行 `Y <hh> <hh> ...`（COUT*H*IW 字节，[co][y][x]）
//           + 一行 `RESULT: PASS|FAIL`（FAIL ⇒ $fatal ⇒ vvp 非 0）。
//
// 编译口径（同一份 TB，一次只编译一份探针网表）：
//   Base 档需要 `-DBASE`（该档**没有** dci_mode/c3_cin 口）。
//=============================================================================
`timescale 1ns/1ps

module CiPackTb;
  localparam NCH   = 8;
  localparam MAXCB = 8;
  localparam MAXH  = 8;
  localparam MAXIW = 8;                    // 必须 >= +IW（网表 WIDTH=8）
  localparam MAXPIX= 64*MAXH*MAXIW;
  localparam NENT  = NCH * NCH * 9;        // 576
  localparam MAXW  = MAXCB * 8 * NENT;

  reg [8*256-1:0] xfile, wfile, bfile;

  reg [7:0]  xm  [0:64*MAXH*MAXIW-1];      // 激活 [ci][y][x]
  reg [7:0]  wm  [0:MAXW-1];               // 权重 [pass][cl][cil][tap]
  reg [31:0] bm  [0:MAXCB*8-1];            // 偏置（累加器单位，int32）
  reg [7:0]  outb[0:MAXPIX-1];             // 输出 [co][y][x]

  integer CIN, COUT, H, IW, NB_B, NBEAT, NPIX, NBYTE, MAXCYC, NENT_TOT;
  integer MPASS, MZEROY, NCIP, DO_DCI, GARB, DO_DW;

  reg clk = 1'b0;
  reg rst = 1'b1;
  reg        we    = 1'b0;
  reg [9:0]  waddr = 10'd0;
  reg [7:0]  wdin  = 8'h00;
  reg [7:0]  x     [0:NCH-1];
  reg        x_valid = 1'b0;
  wire       x_ready;
  reg        start = 1'b0;
  reg [31:0] requant_m = 32'd0;
  reg [7:0]  zero_y = 8'h00;
  reg [31:0] bias  [0:NCH-1];
  wire [7:0] y     [0:NCH-1];
  wire       y_valid;
  wire [31:0] obs_beats;
  wire [3:0]  modeId;
  wire [15:0] imgW;

  always #5 clk = ~clk;

  CiPackProbe dut (
    .we(we), .waddr(waddr), .wdin(wdin),
    .x_0(x[0]), .x_1(x[1]), .x_2(x[2]), .x_3(x[3]),
    .x_4(x[4]), .x_5(x[5]), .x_6(x[6]), .x_7(x[7]),
    .x_valid(x_valid), .x_ready(x_ready),
    .start(start), .requant_m(requant_m), .zero_y(zero_y),
    .bias_0(bias[0]), .bias_1(bias[1]), .bias_2(bias[2]), .bias_3(bias[3]),
    .bias_4(bias[4]), .bias_5(bias[5]), .bias_6(bias[6]), .bias_7(bias[7]),
    .y_0(y[0]), .y_1(y[1]), .y_2(y[2]), .y_3(y[3]),
    .y_4(y[4]), .y_5(y[5]), .y_6(y[6]), .y_7(y[7]),
    .y_valid(y_valid),
    .obs_beats(obs_beats), .modeId(modeId), .imgW(imgW),
    // dw 档使能：Base/Dci 两档都有（B1 落地后的产品口）。
    .dw_mode(DO_DW[0]),
`ifndef BASE
    // Dci 档：两个 additive 口（c3 ci-inner）。
    .dci_mode(DO_DCI[0]), .c3_cin(CIN[3:0]),
`endif
    .clk(clk), .reset(rst)
  );

  integer i, s, j, k, p, co, fi, pi, extra, cyc, row, colc, accept, ci_g, cib0;
  integer passes_run, pix_total, pix_expect, extra_total, pass_bad;
  integer beats0, beats1, beats_pass;

  initial begin
    if (!$value$plusargs("XFILE=%s", xfile)) begin $display("TB-ERROR: 缺 +XFILE="); $fatal(1, "missing XFILE"); end
    if (!$value$plusargs("WFILE=%s", wfile)) begin $display("TB-ERROR: 缺 +WFILE="); $fatal(1, "missing WFILE"); end
    if (!$value$plusargs("BFILE=%s", bfile)) begin $display("TB-ERROR: 缺 +BFILE="); $fatal(1, "missing BFILE"); end
    CIN = 0; COUT = 0; H = 0; IW = 0; MPASS = 0; MZEROY = 0;
    NCIP = 1; DO_DCI = 0; GARB = 0; DO_DW = 0;
    if (!$value$plusargs("CIN=%d", CIN))   begin $display("TB-ERROR: 缺 +CIN=");   $fatal(1, "missing CIN");   end
    if (!$value$plusargs("COUT=%d", COUT)) begin $display("TB-ERROR: 缺 +COUT=");  $fatal(1, "missing COUT");  end
    if (!$value$plusargs("H=%d", H))       begin $display("TB-ERROR: 缺 +H=");     $fatal(1, "missing H");     end
    if (!$value$plusargs("IW=%d", IW))     begin $display("TB-ERROR: 缺 +IW=");    $fatal(1, "missing IW");    end
    if (!$value$plusargs("M=%d", MPASS))   begin $display("TB-ERROR: 缺 +M=");     $fatal(1, "missing M");     end
    if (!$value$plusargs("ZY=%d", MZEROY)) begin $display("TB-ERROR: 缺 +ZY=");    $fatal(1, "missing ZY");    end
    if (!$value$plusargs("NCIP=%d", NCIP)) ;   // 缺省 1
    if (!$value$plusargs("DCI=%d", DO_DCI)) ;  // 缺省 0
    if (!$value$plusargs("GARB=%d", GARB)) ;   // 缺省 0
    if (!$value$plusargs("DW=%d", DO_DW)) ;    // 缺省 0

    if (IW != imgW) begin
      $display("TB-ERROR: +IW=%0d 与网表自报 imgW=%0d 不符", IW, imgW);
      $fatal(1, "IW mismatch");
    end
    if (CIN < 1 || CIN > 64) begin $display("TB-ERROR: CIN=%0d 越界 [1,64]", CIN); $fatal(1, "bad CIN"); end
    if (COUT < 1 || COUT > 64) begin $display("TB-ERROR: COUT=%0d 越界 [1,64]", COUT); $fatal(1, "bad COUT"); end
    if (H < 1 || H > MAXH) begin $display("TB-ERROR: H=%0d 越界 [1,%0d]", H, MAXH); $fatal(1, "bad H"); end
`ifndef BASE
    if (DO_DCI != 0 && modeId != 1) begin $display("TB-ERROR: +DCI=1 但网表 modeId=%0d（应 1=DCI）", modeId); $fatal(1, "mode mismatch"); end
    if (DO_DCI == 0 && DO_DW == 0 && modeId != 1) begin $display("TB-ERROR: dense 作业要求 Dci 网表"); $fatal(1, "mode mismatch"); end
`endif

    NB_B  = (COUT + NCH - 1) / NCH;
    NPIX  = H * IW;
    NBEAT = (H + 1) * IW;
    NBYTE = COUT * NPIX;
    NENT_TOT = NB_B * NENT;
    MAXCYC = 4096;
    if (NPIX > MAXPIX)  begin $display("TB-ERROR: NPIX=%0d > %0d", NPIX, MAXPIX); $fatal(1, "npix overflow"); end
    if (NB_B > MAXCB)   begin $display("TB-ERROR: 趟数 %0d > %0d", NB_B, MAXCB); $fatal(1, "nb>maxcb"); end
    if (NENT_TOT > MAXW)begin $display("TB-ERROR: 权重条目 %0d > %0d", NENT_TOT, MAXW); $fatal(1, "wgt overflow"); end

    for (k = 0; k < 64*MAXH*MAXIW; k = k + 1) xm[k] = 8'h00;
    for (k = 0; k < MAXPIX; k = k + 1) outb[k] = 8'h00;
    for (k = 0; k < MAXW; k = k + 1) wm[k] = 8'h00;
    for (k = 0; k < MAXCB*8; k = k + 1) bm[k] = 32'd0;
    for (k = 0; k < NCH; k = k + 1) begin x[k] = 8'h00; bias[k] = 32'd0; end

    $readmemh(xfile, xm, 0, CIN * H * IW - 1);
    $readmemh(wfile, wm, 0, NENT_TOT - 1);
    $readmemh(bfile, bm, 0, NB_B * 8 - 1);

    requant_m = MPASS[31:0];
    zero_y    = MZEROY[7:0];

    repeat (3) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    passes_run = 0; pix_total = 0; extra_total = 0; pass_bad = 0;
    beats_pass = 0;

    // ---- 密集趟：每趟一个 co-block ----
    for (j = 0; j < NB_B; j = j + 1) begin
      p = j;                                  // 趟序 = pass 号（权重文件按趟排）
      for (k = 0; k < NENT; k = k + 1) begin
        @(negedge clk);
        we = 1'b1; waddr = k[9:0]; wdin = wm[p*NENT + k];
      end
      @(negedge clk);
      we = 1'b0; waddr = 10'd0; wdin = 8'h00;

      for (co = 0; co < NCH; co = co + 1) bias[co] = bm[j*8 + co];

      @(negedge clk); start = 1'b1;
      @(negedge clk); start = 1'b0;
      beats0 = obs_beats;

      cib0 = (j % NCIP) * NCH;
      fi = 0; pi = 0; extra = 0; cyc = 0;
      while ((pi < NPIX) && (cyc < MAXCYC)) begin
        if (fi < NBEAT) begin
          row  = fi / IW;
          colc = fi % IW;
          x_valid = 1'b1;
          for (s = 0; s < NCH; s = s + 1) begin
            ci_g = cib0 + s;
            if (row < H) begin
              if (ci_g < CIN)
                x[s] = xm[(ci_g*H + row)*IW + colc];
              else if (GARB != 0)
                x[s] = 8'hA5 ^ (fi[7:0] ^ (s * 37));   // 垃圾（确定性）：证补位 lane 的值任意
              else
                x[s] = 8'h00;
            end else begin
              x[s] = 8'h00;                            // pad 行（row == H）恒 0（真系统由 z_pad 合成）
            end
          end
        end else begin
          x_valid = 1'b0;
          for (s = 0; s < NCH; s = s + 1) x[s] = 8'h00;
        end
        #1;
        accept = x_valid && x_ready;
        if (y_valid) begin
          if (pi < NPIX) begin
            for (co = 0; co < NCH; co = co + 1)
              if (j*NCH + co < COUT) outb[(j*NCH + co)*NPIX + pi] = y[co];
          end else begin
            extra = extra + 1;
          end
          pi = pi + 1;
        end
        @(negedge clk);
        if (accept) fi = fi + 1;
        cyc = cyc + 1;
      end
      beats1 = obs_beats;
      beats_pass = beats_pass + (beats1 - beats0);
      passes_run  = passes_run + 1;
      pix_total   = pix_total + pi;
      extra_total = extra_total + extra;
      if ((pi != NPIX) || (extra != 0)) begin
        pass_bad = pass_bad + 1;
        $display("TB-ERROR: 趟 j=%0d 产出像素 %0d（期望 %0d）extra=%0d cyc=%0d fi=%0d/%0d",
                 j, pi, NPIX, extra, cyc, fi, NBEAT);
      end
    end

    pix_expect = NB_B * NPIX;

    $display("CIPACK CIN=%0d COUT=%0d H=%0d IW=%0d NB=%0d NPIX=%0d NBEAT=%0d M=%0d ZY=%0d NCIP=%0d DCI=%0d GARB=%0d DW=%0d MODEID=%0d",
             CIN, COUT, H, IW, NB_B, NPIX, NBEAT, MPASS, MZEROY, NCIP, DO_DCI, GARB, DO_DW, modeId);
    $display("CIPACK RTL imgW=%0d", imgW);
    $display("CIPACK BEATS=%0d BEATS_TOTAL=%0d passes_run=%0d pix_total=%0d pix_expect=%0d extra_total=%0d pass_bad=%0d",
             beats_pass, obs_beats, passes_run, pix_total, pix_expect, extra_total, pass_bad);

    $write("Y");
    for (k = 0; k < NBYTE; k = k + 1) $write(" %02x", outb[k]);
    $write("\n");

    if ((passes_run == NB_B) && (pix_total == pix_expect) &&
        (extra_total == 0) && (pass_bad == 0)) begin
      $display("RESULT: PASS");
      $finish;
    end else begin
      $display("RESULT: FAIL passes=%0d/%0d pix=%0d/%0d extra=%0d pass_bad=%0d",
               passes_run, NB_B, pix_total, pix_expect, extra_total, pass_bad);
      $fatal(1, "CiPackTb incomplete");
    end
  end

  initial begin
    #5000000;
    $display("RESULT: FAIL timeout");
    $fatal(1, "CiPackTb timeout");
  end

endmodule
