//=============================================================================
// DwLaneTb.v —— NPU v2 切片 B-1：**depthwise lane 打包探针**的数值装置（纯 Verilog）。
//
// 被测 = `gen/DwLane{BEFORE,AFTER2,AFTER1}[*.v]`（`rtl_test/DwLaneProbe.scala`，模块名恒为 DwLaneProbe）。
// 装置口径**逐条沿用** `rtl_test/DwTb.v`（同一个冻结参考 `tools/multipass_ref.py` 的向量/黄金）：
//   · 一趟 = 一个 co-block 的对角趟（dt 的 dw 冻结口径 GROUP=C_in=C_out ⇒ 第 b 个 co-block 只吃第 b 个
//     ci-block）；本装置就是那个"对角趟编排器"；
//   · 喂 H+1 行（第 H 行是全 0 的 pad 行）；只收 H*IW 个有效像素；
//   · 权重瓦片序 = [co-block 外][ci-block 内]，对角趟取 `p = b*NB + b`。
//
// 与 DwTb 的差别（本探针的**唯一**新东西）：`dw_mode` 口（只有 AFTER 档有）——
//   本装置把 `dw_mode = 1` 常举（探针的全部作业都是 dw）。
//
// 判据（数值在 `tools/run_dwlane_ab.sh` 里对；本装置只自检"跑完了 + 协议对"）：
//   0) time 0 对账：`+IW == imgW`（网表宽度钉死）、`+NB <= 8`、`NPIX <= 64*8`。
//   1) 每个对角趟产出**恰好** `NPIX = H*IW` 个像素；趟数**恰好** `NB = ceil(C/8)`；`extra == 0`。
//   2) 自报 `BEATS=<obs_beats>`（= `arr.en` 拍数终值）⇒ 闸门按 `taps·NB·NPIX` 的**预测量**断言
//      （BEFORE 9.00× / AFTER2 2.00× / AFTER1 1.00× 拍/像素/趟）。
//
// 用法（plusarg；`multipass_ref.py` 落的 `x/w/b` 就是这里的 +XFILE/+WFILE/+BFILE）：
//   +XFILE= +WFILE= +BFILE= +CIN= +COUT= +H= +IW= +M= +ZY=
//   stdout：`DWLANE <k>=<v> ...`（自报）+ 一行 `Y <hh> <hh> ...`（COUT*H*IW 字节，[co][y][x]）
//           + 一行 `RESULT: PASS|FAIL`（FAIL ⇒ $fatal ⇒ vvp 非 0）。
//
// 编译口径（同一份 TB，一次只编译一份探针网表）：
//   MODE 0（BEFORE）需要 `-DMODE0`（该档**没有** dw_mode 口）；MODE 1/2 直接编译。
//=============================================================================
`timescale 1ns/1ps

module DwLaneTb;
  localparam NCH   = 8;                    // 硬件切片通道数（dw 的"每趟 8 通道"）
  localparam MAXCB = 8;                    // 块数上限（C <= 64）
  localparam MAXH  = 8;
  localparam MAXIW = 8;                    // 必须 >= +IW（网表 WIDTH=8）
  localparam MAXPIX= 64*MAXH*MAXIW;
  localparam NENT  = NCH * NCH * 9;        // 576
  localparam MAXW  = MAXCB * 8 * NENT;     // 最多 64 趟的权重

  reg [8*256-1:0] xfile, wfile, bfile;

  reg [7:0]  xm  [0:64*MAXH*MAXIW-1];      // 激活 [ci][y][x]
  reg [7:0]  wm  [0:MAXW-1];               // 权重 [pass][co][ci_local][ky][kx]
  reg [31:0] bm  [0:MAXCB*8-1];            // 偏置（累加器单位，int32）
  reg [7:0]  outb[0:MAXPIX-1];             // 收集到的输出 [co][y][x]

  integer CIN, COUT, H, IW, NB_B, NBEAT, NPIX, NBYTE, MAXCYC, NENT_TOT;
  integer MPASS, MZEROY;

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

  DwLaneProbe dut (
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
`ifndef MODE0
    // MODE 1/2：dw 档使能。本装置的全部作业都是 dw ⇒ 恒举 1。
    .dw_mode(1'b1),
`endif
    .clk(clk), .reset(rst)
  );

  integer i, s, j, k, p, co, fi, pi, extra, cyc, row, colc, accept, ci_g;
  integer passes_run, pix_total, pix_expect, extra_total, pass_bad;
  integer beats0, beats1, beats_pass;

  initial begin
    // ---- 参数 ----
    if (!$value$plusargs("XFILE=%s", xfile)) begin $display("TB-ERROR: 缺 +XFILE="); $fatal(1, "missing XFILE"); end
    if (!$value$plusargs("WFILE=%s", wfile)) begin $display("TB-ERROR: 缺 +WFILE="); $fatal(1, "missing WFILE"); end
    if (!$value$plusargs("BFILE=%s", bfile)) begin $display("TB-ERROR: 缺 +BFILE="); $fatal(1, "missing BFILE"); end
    CIN = 0; COUT = 0; H = 0; IW = 0; MPASS = 0; MZEROY = 0;
    if (!$value$plusargs("CIN=%d", CIN))   begin $display("TB-ERROR: 缺 +CIN=");   $fatal(1, "missing CIN");   end
    if (!$value$plusargs("COUT=%d", COUT)) begin $display("TB-ERROR: 缺 +COUT=");  $fatal(1, "missing COUT");  end
    if (!$value$plusargs("H=%d", H))       begin $display("TB-ERROR: 缺 +H=");     $fatal(1, "missing H");     end
    if (!$value$plusargs("IW=%d", IW))     begin $display("TB-ERROR: 缺 +IW=");    $fatal(1, "missing IW");    end
    if (!$value$plusargs("M=%d", MPASS))   begin $display("TB-ERROR: 缺 +M=");     $fatal(1, "missing M");     end
    if (!$value$plusargs("ZY=%d", MZEROY)) begin $display("TB-ERROR: 缺 +ZY=");    $fatal(1, "missing ZY");    end

    if (CIN != COUT) begin
      $display("TB-ERROR: depthwise 要求 +CIN == +COUT（冻结口径 GROUP=C_in=C_out），实得 %0d/%0d", CIN, COUT);
      $fatal(1, "not depthwise");
    end
    if (IW != imgW) begin
      $display("TB-ERROR: +IW=%0d 与网表自报 imgW=%0d 不符", IW, imgW);
      $fatal(1, "IW mismatch");
    end
    if (CIN < 1 || CIN > 64) begin $display("TB-ERROR: CIN=%0d 越界 [1,64]", CIN); $fatal(1, "bad CIN"); end
    if (H < 1 || H > MAXH) begin $display("TB-ERROR: H=%0d 越界 [1,%0d]", H, MAXH); $fatal(1, "bad H"); end

    NB_B  = (CIN + NCH - 1) / NCH;
    NPIX  = H * IW;
    NBEAT = (H + 1) * IW;
    NBYTE = COUT * NPIX;
    NENT_TOT = NB_B * NB_B * NENT;
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

    // ---- 复位 ----
    repeat (3) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    passes_run = 0; pix_total = 0; extra_total = 0; pass_bad = 0;
    beats_pass = 0;

    // ---- ★ 对角趟：b 既是 co-block 也是 ci-block ----
    for (j = 0; j < NB_B; j = j + 1) begin
      p = j * NB_B + j;
      for (k = 0; k < NENT; k = k + 1) begin
        @(negedge clk);
        we = 1'b1; waddr = k[9:0]; wdin = wm[p*NENT + k];
      end
      @(negedge clk);
      we = 1'b0; waddr = 10'd0; wdin = 8'h00;

      for (co = 0; co < NCH; co = co + 1) bias[co] = bm[j*8 + co];

      @(negedge clk); start = 1'b1;
      @(negedge clk); start = 1'b0;
      beats0 = obs_beats;                    // ★ 本趟的 tap-beat 计数（含 `start` 拍的复位）

      fi = 0; pi = 0; extra = 0; cyc = 0;
      while ((pi < NPIX) && (cyc < MAXCYC)) begin
        if (fi < NBEAT) begin
          row  = fi / IW;
          colc = fi % IW;
          x_valid = 1'b1;
          for (s = 0; s < NCH; s = s + 1) begin
            ci_g = j * NCH + s;
            x[s] = ((row < H) && (ci_g < CIN)) ? xm[(ci_g*H + row)*IW + colc] : 8'h00;
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
        $display("TB-ERROR: 对角趟 j=%0d 产出像素 %0d（期望 %0d）extra=%0d cyc=%0d fi=%0d/%0d",
                 j, pi, NPIX, extra, cyc, fi, NBEAT);
      end
    end

    pix_expect = NB_B * NPIX;

    $display("DWLANE CIN=%0d COUT=%0d H=%0d IW=%0d NB=%0d NPIX=%0d NBEAT=%0d M=%0d ZY=%0d MODEID=%0d",
             CIN, COUT, H, IW, NB_B, NPIX, NBEAT, MPASS, MZEROY, modeId);
    $display("DWLANE RTL imgW=%0d", imgW);
    // ★ 拍数"终值 − 首值与"（去掉载权/复位段的观测量）：= Σ_趟 (beats1-beats0)
    $display("DWLANE BEATS=%0d BEATS_TOTAL=%0d passes_run=%0d pix_total=%0d pix_expect=%0d extra_total=%0d pass_bad=%0d",
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
      $fatal(1, "DwLaneTb incomplete");
    end
  end

  // 仿真不收敛时的兜底（超时即判红，避免闸门挂死）
  initial begin
    #5000000;
    $display("RESULT: FAIL timeout");
    $fatal(1, "DwLaneTb timeout");
  end

endmodule
