//=============================================================================
// DwTb.v —— y1 C4a.6 **depthwise（`0x03`）单元**的数值装置（纯 Verilog）。
//
// 被测行为（`rtl/MultiPassUnit.scala` ⇒ `gen/DwUnit.v`）：
//   depthwise 冻结口径 = `GROUP = C_in = C_out`；`C≤8` 一趟；`C>8` 拆趟（每趟 8 通道）。
//   本装置就是那个"**对角趟编排器**"：
//     NB = ceil(C/8)（= co-block 数 = ci-block 数）
//     for b = 0..NB-1:                       ← **对角趟**：第 b 个 co-block 只吃第 b 个 ci-block
//       预载第 b 趟的权重瓦片（真表瓦片序 = [co-block 外][ci-block 内]，故瓦片下标 = b*NB + b）
//       脉冲 `start`（复位切片相位 + 部分和读地址回本段像素 0）
//       喂第 b 个 ci 块的 8 个通道（行主序、末尾多喂一行全 0 pad 行）
//       **这一趟就是该 co-block 的成品**（对角趟 ⇒ 该 co-block 只有这一趟）⇒ 收集
//   ⇒ 输出布局 = [co][y][x]（co 全局 0..C_out-1），与 `multipass_ref.py` 的黄金同序。
//
// ★ 与 C4a.5a 的 `MultiPassTb.v` 的关系（"同一套算术，不另起一条路"）
//   两者驱动**同一个网表**（`DwGen` 出的 `gen/DwUnit.v` 与 `MultiPassGen` 出的 `gen/MultiPassUnit.v`
//   **逐字节相同**；`run_dw_ab.sh` 用 md5 断言这一条）。差别只在**趟调度**：
//     · `MultiPassTb` = **一般趟**（co-block × ci-block 全组合，跨 ci 趟累加）；
//     · 本装置        = **对角趟**（只跑 co-block == ci-block）。
//   跨块的趟其权重瓦片按冻结掩码规则**全 0** ⇒ 贡献恰 0 ⇒ 两者对同一输入必须**逐字节相同**
//   （闸门对每个形状都断言 `DwTb.Y == MultiPassTb.Y`）。这条断言就是判据 3。
//
// 判据（数值逐字节在 `tools/run_dw_ab.sh` 里对；本装置只自检"跑完了 + 协议对"）：
//   0) **生成参数钉死**（time 0，对不上就 $fatal）：`+IW` == 网表自报 `imgW`；`imgC/psRows == 8`；
//      `psRowBytes == +ROWB`（★ §3.7：部分和行宽；**缺省 4 B/32 bit**）；`psWordBytes == 8*ROWB`；`psDepth == ncob*pixMax`；
//      `H*IW <= pixMax`；`NB <= ncob`。★ 另加 depthwise 专属：**`+CIN == +COUT`**（否则不是 depthwise）。
//   1) 每个对角趟产出**恰好** `NPIX = H*IW` 个像素；趟数**恰好** `NB = ceil(C/8)`。
//   2) 无"多出来的像素"（`extra == 0`）。
//
// 用法（plusarg；`multipass_ref.py` 落盘的 `x/w/b` 就是这里的 +XFILE/+WFILE/+BFILE）：
//   +XFILE= +WFILE= +BFILE= +CIN= +COUT= +H= +IW= +M= +ZY=
//     XFILE：`[ci][y][x]`，CIN*H*IW 行、每行一个十六进制字节；
//     WFILE：`[pass][co][ci_local][ky][kx]`，passes*576 行（pass 序 = co-block 外、ci-block 内）；
//     BFILE：`[co-block][co_local]`，n_co*8 行、每行 8 个十六进制数字（累加器单位的 int32）；
//   stdout：`DW <k>=<v> ...`（自报）+ 一行 `Y <hh> <hh> ...`（COUT*H*IW 字节，[co][y][x]）
//           + 一行 `RESULT: PASS|FAIL`（FAIL ⇒ $fatal ⇒ vvp 非 0）。
//
// ★ 与 `Conv3x3Tb.v` / `MultiPassTb.v` 的两条接口陷阱**同源**（同一个 `Conv3x3Slice` 在下面）：
//   喂 H+1 行（第 H 行是全 0 的 pad 行）；只收 H*IW 个有效像素（预滚行不出像素）。
//=============================================================================
`timescale 1ns/1ps

module DwTb;
  localparam NCH   = 8;                    // 硬件切片通道数（depthwise 的"每趟 8 通道"）
  localparam MAXCB = 8;                    // 块数上限（C <= 64）
  localparam MAXH  = 8;
  localparam MAXIW = 8;                    // 必须 >= +IW（网表 WIDTH=8）
  localparam MAXPIX= 32;                   // = 网表 PIXMAX
  localparam NENT  = NCH * NCH * 9;        // 576（一般瓦片；depthwise 只用其对角块）
  localparam MAXW  = MAXCB * 8 * NENT;     // 最多 64 趟的权重

  reg [8*256-1:0] xfile, wfile, bfile;

  reg [7:0]  xm  [0:64*MAXH*MAXIW-1];      // 激活 [ci][y][x]
  reg [7:0]  wm  [0:MAXW-1];               // 权重 [pass][co][ci_local][ky][kx]
  reg [31:0] bm  [0:MAXCB*8-1];            // 偏置（累加器单位，int32）
  reg [7:0]  outb[0:64*MAXH*MAXIW-1];      // 收集到的输出 [co][y][x]

  integer CIN, COUT, H, IW, NB_B, NBEAT, NPIX, NBYTE, MAXCYC, NENT_TOT;
  integer MPASS, MZEROY, ROWB;   // ★ §3.7：ROWB = 部分和行宽（字节，缺省 4）

  reg clk = 1'b0;
  reg rst = 1'b1;
  reg        we    = 1'b0;
  reg [9:0]  waddr = 10'd0;
  reg [7:0]  wdin  = 8'h00;
  reg [7:0]  x     [0:NCH-1];
  reg        x_valid = 1'b0;
  wire       x_ready;
  reg        start = 1'b0;
  reg [2:0]  cob   = 3'd0;
  reg [31:0] requant_m = 32'd0;
  reg [7:0]  zero_y = 8'h00;
  reg [31:0] bias  [0:NCH-1];
  wire [7:0] y     [0:NCH-1];
  wire       y_valid;
  wire [15:0] imgC, imgW, pixMax, ncob, psRows, psRowBytes, psWordBytes, psDepth;
  wire [31:0] pixCount;
  wire [7:0]  obsRdAddr, obsWrAddr;

  always #5 clk = ~clk;

  MultiPassUnit dut (
    .we(we), .waddr(waddr), .wdin(wdin),
    .x_0(x[0]), .x_1(x[1]), .x_2(x[2]), .x_3(x[3]),
    .x_4(x[4]), .x_5(x[5]), .x_6(x[6]), .x_7(x[7]),
    .x_valid(x_valid), .x_ready(x_ready),
    .start(start), .cob(cob), .requant_m(requant_m), .zero_y(zero_y),
    // ★ C4a.5b §4.5：零填充码点。本闸门冻结口径是 `z_x = z_w = 0`（无中心化）⇒ 喂 0（旧行为）。
    .pad_val(8'sd0),
    // ★★ C4b-D1：卷积步长（描述符 `w3[11:8]`）。本闸门冻结口径是 stride=1
    //   ⇒ 喂 1（与没有这个口逐拍同形）。**必须显式驱动**（否则 z 会让相位计数器变 x）。
    .stride(4'd1),
    // ★★ T-S1：**运行期行宽**。本闸门的用例就是"网表宽度"这一档（time 0 已对账 `+IW == imgW`）
    //   ⇒ 喂 `IW`（= 生成时的 WIDTH）⇒ 与"没有这个口"逐字节同形。**必须显式驱动**（否则 z 会让
    //   列回绕/行末列号变 x）。`16'(IW)` 是 SystemVerilog 的**定宽**转换。
    .rowW(16'(IW)),
    .bias_0(bias[0]), .bias_1(bias[1]), .bias_2(bias[2]), .bias_3(bias[3]),
    .bias_4(bias[4]), .bias_5(bias[5]), .bias_6(bias[6]), .bias_7(bias[7]),
    .y_0(y[0]), .y_1(y[1]), .y_2(y[2]), .y_3(y[3]),
    .y_4(y[4]), .y_5(y[5]), .y_6(y[6]), .y_7(y[7]),
    .y_valid(y_valid),
    .imgC(imgC), .imgW(imgW), .pixMax(pixMax), .ncob(ncob),
    .psRows(psRows), .psRowBytes(psRowBytes), .psWordBytes(psWordBytes), .psDepth(psDepth),
    .pixCount(pixCount), .obsRdAddr(obsRdAddr), .obsWrAddr(obsWrAddr),
    .clk(clk), .reset(rst)
  );

  integer i, s, j, k, p, co, fi, pi, extra, cyc, row, colc, accept, ci_g;
  integer passes_run, pix_total, pix_expect, extra_total, pass_bad;

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
    ROWB = 4;                                                  // ★ §3.7：缺省行宽 = 4 B（32 bit）
    if ($value$plusargs("ROWB=%d", ROWB)) begin end            // 覆盖口（24-bit 档 = 3）

    // ---- ★ depthwise 专属：C_in == C_out（冻结口径 `GROUP = C_in = C_out` 的必要条件）----
    if (CIN != COUT) begin
      $display("TB-ERROR: depthwise 要求 +CIN == +COUT（冻结口径 GROUP=C_in=C_out），实得 %0d/%0d", CIN, COUT);
      $fatal(1, "not depthwise");
    end
    // ---- 生成参数钉死（对不上立即 fatal；Y1 的"宽度钉死"教训）----
    if (IW != imgW) begin
      $display("TB-ERROR: +IW=%0d 与网表自报 imgW=%0d 不符 ⇒ 该网表是按 WIDTH=%0d 生成的", IW, imgW, imgW);
      $fatal(1, "IW mismatch");
    end
    if (imgC != NCH || psRows != NCH) begin
      $display("TB-ERROR: 切片通道数不符（imgC=%0d psRows=%0d，期望 %0d）", imgC, psRows, NCH);
      $fatal(1, "C mismatch");
    end
    if (psRowBytes != ROWB) begin
      $display("TB-ERROR: 部分和缓冲行宽 psRowBytes=%0d != +ROWB=%0d（★ §3.7：缺省 4 B = 32 bit 档）", psRowBytes, ROWB);
      $fatal(1, "rowBytes mismatch");
    end
    if (psWordBytes != NCH * ROWB) begin
      $display("TB-ERROR: 部分和缓冲字宽 psWordBytes=%0d != %0d（一个 co-block 的字节数）", psWordBytes, NCH * ROWB);
      $fatal(1, "wordBytes mismatch");
    end
    if (psDepth != ncob * pixMax) begin
      $display("TB-ERROR: 部分和缓冲字数 psDepth=%0d != ncob*pixMax=%0d", psDepth, ncob * pixMax);
      $fatal(1, "depth mismatch");
    end
    if (CIN < 1 || CIN > 64) begin $display("TB-ERROR: CIN=%0d 越界 [1,64]", CIN); $fatal(1, "bad CIN"); end
    if (H < 1 || H > MAXH) begin $display("TB-ERROR: H=%0d 越界 [1,%0d]", H, MAXH); $fatal(1, "bad H"); end

    NB_B  = (CIN + NCH - 1) / NCH;         // ★ depthwise 的趟数 = ceil(C/8)（对角趟）
    NPIX  = H * IW;
    NBEAT = (H + 1) * IW;
    NBYTE = COUT * NPIX;
    NENT_TOT = NB_B * NB_B * NENT;         // 真表瓦片序的长度（[co-block][ci-block]），只用对角块
    MAXCYC = 512;
    if (NPIX > pixMax)  begin $display("TB-ERROR: H*IW=%0d > pixMax=%0d", NPIX, pixMax); $fatal(1, "npix>pixMax"); end
    if (NB_B > ncob)    begin $display("TB-ERROR: 趟数 %0d > ncob=%0d", NB_B, ncob); $fatal(1, "nb>ncob"); end
    if (NENT_TOT > MAXW)begin $display("TB-ERROR: 权重条目 %0d > %0d", NENT_TOT, MAXW); $fatal(1, "wgt overflow"); end
    if (NPIX > MAXPIX)  begin $display("TB-ERROR: H*IW=%0d > %0d", NPIX, MAXPIX); $fatal(1, "npix overflow"); end

    for (k = 0; k < 64*MAXH*MAXIW; k = k + 1) begin xm[k] = 8'h00; outb[k] = 8'h00; end
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

    // ---- ★ 对角趟：b 既是 co-block 也是 ci-block ----
    for (j = 0; j < NB_B; j = j + 1) begin
      p = j * NB_B + j;                    // 真表瓦片序 = [co-block 外][ci-block 内]
      // 该趟的权重瓦片（地址 = [co][ci_local][ky][kx]，576 项）
      for (k = 0; k < NENT; k = k + 1) begin
        @(negedge clk);
        we = 1'b1; waddr = k[9:0]; wdin = wm[p*NENT + k];
      end
      @(negedge clk);
      we = 1'b0; waddr = 10'd0; wdin = 8'h00;

      cob = j[2:0];
      // ★ 偏置：对角趟是**该 co-block 唯一的趟** ⇒ 直接带上本块的偏置。
      //   （一般趟里偏置折进 `i==0` 那一趟；对 depthwise 而言 `i==0` 与 `i==j` 对 co-block j 的
      //    贡献相同 —— 因为 `i!=j` 的趟瓦片全 0、部分和恰 0 ⇒ 整数加法下两者等价。闸门用
      //    `DwTb.Y == MultiPassTb.Y` 逐字节断言这条等价。）
      for (co = 0; co < NCH; co = co + 1) bias[co] = bm[j*8 + co];

      // 趟起点：prime 切片 + 部分和读地址回本段像素 0
      @(negedge clk); start = 1'b1;
      @(negedge clk); start = 1'b0;

      fi = 0; pi = 0; extra = 0; cyc = 0;
      while ((pi < NPIX) && (cyc < MAXCYC)) begin
        if (fi < NBEAT) begin
          row  = fi / IW;                  // 行 0..H-1 是图像、行 H 是全 0 的 pad 行
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
          if (pi < NPIX) begin           // 对角趟 ⇒ 本趟的料**就是**该 co-block 的成品
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

    // ---- 自报 + 输出 ----
    $display("DW CIN=%0d COUT=%0d H=%0d IW=%0d NB=%0d NPIX=%0d NBEAT=%0d M=%0d ZY=%0d SCHEME=diag",
             CIN, COUT, H, IW, NB_B, NPIX, NBEAT, MPASS, MZEROY);
    $display("DW RTL imgC=%0d imgW=%0d pixMax=%0d ncob=%0d psRows=%0d psRowBytes=%0d psWordBytes=%0d psDepth=%0d",
             imgC, imgW, pixMax, ncob, psRows, psRowBytes, psWordBytes, psDepth);
    $display("DW passes_run=%0d pix_total=%0d pix_expect=%0d extra_total=%0d pass_bad=%0d",
             passes_run, pix_total, pix_expect, extra_total, pass_bad);

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
      $fatal(1, "DwTb incomplete");
    end
  end

  // 仿真不收敛时的兜底（超时即判红，避免闸门挂死）
  initial begin
    #200000000;
    $display("RESULT: FAIL timeout");
    $fatal(1, "DwTb timeout");
  end

endmodule
