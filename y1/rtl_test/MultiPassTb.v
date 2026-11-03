//=============================================================================
// MultiPassTb.v —— C4a.5a **多趟累加**（rtl/MultiPassUnit.scala ⇒ gen/MultiPassUnit.v）的数值装置。
//
// 被测行为：一个"宽层"（C_in > 8 或 C_out > 8）被拆成 `ceil(C_in/8) × ceil(C_out/8)` 趟
// （C4a.4 冻结规则）。**本装置就是那个"编排器"**（C4a.5b 里换成 `UnitExec`）：
//   for co-block j = 0..n_co-1:
//     for ci-block i = 0..n_ci-1:            ← 跨 ci 趟**累加**（片上部分和，int64）
//       预载该趟的权重瓦片（SKIP 通道 / 跨组位置填真实零码 z_w = 0）
//       脉冲 `start`（复位切片相位 + 把部分和读地址指回本段像素 0）
//       把该趟的输入流（该 ci 块的 8 个通道，行主序、末尾多喂一行全 0 pad）喂进 `x/x_valid`
//       **最后一趟**（i == n_ci-1）的 `y/y_valid` 才是该 co-block 的成品 ⇒ 收集；
//       其余趟的 `y` 是"只累加了一半"的中间值 ⇒ 丢弃。
//   ⇒ 输出布局 = [co][y][x]（co 全局 0..C_out-1），与 `multipass_ref.py` 的黄金同序。
//
// 判据（数值在 `tools/run_multipass_ab.sh` 里逐字节对；本装置只自检"跑完了"）：
//   0) **生成参数钉死**（time 0，对不上就 $fatal）：`+IW` == 网表自报 `imgW`；`imgC/psRows == 8`；
//      `psRowBytes == +ROWB`（★ §3.7：部分和行宽；**缺省 4 B/32 bit**，"C_out 行 × PSW/8 B"）；
//      `psWordBytes == 8*ROWB`（一个 co-block 的字宽）；`psDepth == ncob*pixMax`（部分和缓冲的字数）；
//      `H*IW <= pixMax`；`n_co <= ncob`。`+ROWB=3` 是 24 bit 负对照档（`run_psbound_ab.sh`）。
//   0b) **实测峰值 |acc|**（★ §3.7，`run_psbound_ab.sh` 的判据）：随出数拍采 `sl_ps_out`（= 写回缓冲
//      的那个值）逐通道还原二补数后取上界 ⇒ stdout 的 `MP PEAKABS=<n>`（缺省 32 bit 档应达 9,363,456）。
//   1) 每个 pass 产出**恰好** `NPIX = H*IW` 个像素（少一个 ⇒ 相位/复位错；多一个 ⇒ 越界）；
//      `+DROPCI=i` 时该 ci 趟**整趟不喂**（负对照 A1：漏一趟），这个 pass 产出 0 个像素。
//   2) 无 "多出来的像素"（`extra == 0`）：一个 pass 里 y_valid 多于 NPIX 就是协议错。
//
// 用法（plusarg；`multipass_ref.py` 落盘的 `x/w/b` 就是这里的 +XFILE/+WFILE/+BFILE）：
//   +XFILE= +WFILE= +BFILE= +CIN= +COUT= +H= +IW= +M= +ZY= [+DROPCI=i] [+ROWB=n]
//     XFILE：`[ci][y][x]`，CIN*H*IW 行、每行一个十六进制字节；
//     WFILE：`[pass][co][ci_local][ky][kx]`，passes*576 行（pass 序 = co-block 外、ci-block 内）；
//     BFILE：`[co-block][co_local]`，n_co*8 行、每行 8 个十六进制数字（累加器单位的 int32）；
//   stdout：`MP <k>=<v> ...`（自报）+ 一行 `Y <hh> <hh> ...`（COUT*H*IW 字节，[co][y][x]）
//           + 一行 `RESULT: PASS|FAIL`（FAIL ⇒ $fatal ⇒ vvp 非 0）。
//
// ★ 与 `Conv3x3Tb.v` 的两条接口陷阱**同源**（同一个 `Conv3x3Slice` 在下面）：
//   喂 H+1 行（第 H 行是全 0 的 pad 行）；只收 H*IW 个有效像素（预滚行不出像素）。
//=============================================================================
`timescale 1ns/1ps

module MultiPassTb;
  localparam NCH   = 8;                    // 硬件切片通道数
  localparam MAXCB = 8;                    // co-block 数上限（C_out <= 64）
  localparam MAXH  = 8;
  localparam MAXIW = 640;                  // 必须 >= +IW（★ C4b-D1：真网 Conv_0 的输入行宽 = 640）
  localparam MAXPIX= 8*640;                // 本装置自己的像素数组上限（网表的 PIXMAX 用自报口 pixMax 对账）
  localparam NENT  = NCH * NCH * 9;        // 576
  localparam MAXW  = MAXCB * 8 * NENT;     // 最多 64 趟的权重

  reg [8*256-1:0] xfile, wfile, bfile;

  reg [7:0]  xm  [0:64*MAXH*MAXIW-1];      // 激活 [ci][y][x]
  reg [7:0]  wm  [0:MAXW-1];               // 权重 [pass][co][ci_local][ky][kx]
  reg [31:0] bm  [0:MAXCB*8-1];            // 偏置（累加器单位，int32）
  reg [7:0]  outb[0:64*MAXH*MAXIW-1];      // 收集到的输出 [co][y][x]

  integer CIN, COUT, H, IW, NCI_B, NCO_B, NBEAT, NPIX, NBYTE, MAXCYC, NENT_TOT;
  integer MPASS, MZEROY, DROPCI, HAVE_DROP, ROWB;   // ★ §3.7：ROWB = 部分和行宽（字节，缺省 4）
  // ★★ C4b-D1：`+STRIDE=`（缺省 1 ⇒ 与改动前逐字节同形）与 `+PADV=`（下边 pad 行的码点，
  //   缺省 0；真网 Conv_0 的 `z_pad = -128` ⇒ 由供料侧给）。`HO/WO` 是**输出**几何：
  //   `HO = (H-1)/s + 1`、`WO = (IW-1)/s + 1`（`s=1` ⇒ `HO=H`、`WO=IW`，与改动前同值）。
  integer STRIDE, PADV, HO, WO, PADV_B;

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
    //   ★★ C4b-D1：改成 `+PADV`（缺省 0 ⇒ 与旧行为**逐字节同形**）—— 真网 `Conv_0` 的零填充码点
    //   是 `z_pad = -128`，pad 行码点与切片的 pad 码点**必须同一份**（否则 v1 判据必红）。
    .pad_val(PADV_B[7:0]),
    // ★★ C4b-D1：卷积步长（描述符 `w3[11:8]`）。`+STRIDE` 缺省 1 ⇒ 与改动前逐拍同形。
    //   **必须显式驱动**（否则 z 会让相位计数器变 x）。
    .stride(STRIDE[3:0]),
    // ★★ T-S1：**运行期行宽**。本闸门的用例就是"网表宽度"这一档（time 0 已对账 `+IW == imgW`）
    //   ⇒ 喂 `IW`（= 生成时的 WIDTH）⇒ 与"没有这个口"逐字节同形。**必须显式驱动**
    //   （否则 z 会让列回绕/行末列号变 x）。`16'(IW)` 是 SystemVerilog 的**定宽**转换。
    .rowW(16'(IW)),
    // ★★ T-S2b：部分和清零门（本闸门是单层整层多趟 ⇒ 靠"上电初值 0"清累加器 ⇒ 喂 0，
    //   与改动前逐字节同形）。
    .ps_clr(1'b0),
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

  // =============================================================================
  // ★★ §3.7：**实测峰值 |acc|**（负对照/可证界的量具；`run_psbound_ab.sh` 吃这一行）
  //   采点 = 切片"出数拍"（`dut.sl_ps_valid`）那一拍的各通道 `ps_out` = 本轮 acc + 读回部分和 + bias
  //   —— 它正是**写回 `PartialSumBuf` 的那个值**，也正是"行宽收窄"会截断/回绕的那个值。
  //   宽度取**运行期自报**（`psRowBytes*8`：缺省 32 bit；24 bit 档 = 24）⇒ 本装置不假设档位。
  //   逐通道还原二补数（`pbSgn` 复制符号位）后取 |·| 的上界 ⇒ `MP PEAKABS=<n>`。
  // =============================================================================
  reg [511:0] psProbe;
  reg [63:0]  peakAbs, pbV, pbTwo, pbMask;
  reg         pbSgn;
  integer     pbK, pbNb;
  assign psProbe = {dut.sl_ps_out_7, dut.sl_ps_out_6, dut.sl_ps_out_5, dut.sl_ps_out_4,
                    dut.sl_ps_out_3, dut.sl_ps_out_2, dut.sl_ps_out_1, dut.sl_ps_out_0};
  always @(negedge clk) begin
    if (dut.sl_ps_valid && (psRowBytes != 0)) begin
      pbNb   = psRowBytes * 8;
      pbTwo  = 64'd1 << pbNb;
      pbMask = pbTwo - 64'd1;
      for (pbK = 0; pbK < NCH; pbK = pbK + 1) begin
        pbV   = (psProbe >> (pbK * pbNb)) & pbMask;       // 通道 pbK 的原始位型（低位对齐）
        pbSgn = (pbV >> (pbNb - 1)) & 1'b1;               // 该档的符号位
        if (pbSgn) pbV = pbV - pbTwo;                     // 二补数还原（有符号）
        if (pbV[63]) pbV = -pbV;                          // |acc|
        if (pbV > peakAbs) peakAbs = pbV;
      end
    end
  end

  integer i, s, j, k, p, co, fi, pi, extra, cyc, row, colc, accept, ci_g;
  integer passes_run, pix_total, pix_expect, extra_total, pass_bad;

  initial begin
    // ---- 参数 ----
    if (!$value$plusargs("XFILE=%s", xfile)) begin $display("TB-ERROR: 缺 +XFILE="); $fatal(1, "missing XFILE"); end
    if (!$value$plusargs("WFILE=%s", wfile)) begin $display("TB-ERROR: 缺 +WFILE="); $fatal(1, "missing WFILE"); end
    if (!$value$plusargs("BFILE=%s", bfile)) begin $display("TB-ERROR: 缺 +BFILE="); $fatal(1, "missing BFILE"); end
    CIN = 0; COUT = 0; H = 0; IW = 0; MPASS = 0; MZEROY = 0; DROPCI = -1;
    if (!$value$plusargs("CIN=%d", CIN))   begin $display("TB-ERROR: 缺 +CIN=");   $fatal(1, "missing CIN");   end
    if (!$value$plusargs("COUT=%d", COUT)) begin $display("TB-ERROR: 缺 +COUT=");  $fatal(1, "missing COUT");  end
    if (!$value$plusargs("H=%d", H))       begin $display("TB-ERROR: 缺 +H=");     $fatal(1, "missing H");     end
    if (!$value$plusargs("IW=%d", IW))     begin $display("TB-ERROR: 缺 +IW=");    $fatal(1, "missing IW");    end
    if (!$value$plusargs("M=%d", MPASS))   begin $display("TB-ERROR: 缺 +M=");     $fatal(1, "missing M");     end
    if (!$value$plusargs("ZY=%d", MZEROY)) begin $display("TB-ERROR: 缺 +ZY=");    $fatal(1, "missing ZY");    end
    if (!$value$plusargs("STRIDE=%d", STRIDE)) STRIDE = 1;      // ★ C4b-D1（缺省 1 = 旧行为）
    if (!$value$plusargs("PADV=%d", PADV)) PADV = 0;            // ★ C4b-D1：pad 行码点（缺省 0 = 旧行为）
    if ($value$plusargs("DROPCI=%d", DROPCI)) HAVE_DROP = 1; else HAVE_DROP = 0;
    ROWB = 4;                                                  // ★ §3.7：缺省行宽 = 4 B（32 bit）
    if ($value$plusargs("ROWB=%d", ROWB)) begin end            // 24-bit 负对照档用 +ROWB=3
    if (STRIDE < 1 || STRIDE > 15) begin $display("TB-ERROR: +STRIDE=%0d 越界 [1,15]", STRIDE); $fatal(1, "bad STRIDE"); end
    PADV_B = PADV & 8'hFF;

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
    if (COUT < 1 || COUT > 64) begin $display("TB-ERROR: COUT=%0d 越界 [1,64]", COUT); $fatal(1, "bad COUT"); end
    if (H < 1 || H > MAXH) begin $display("TB-ERROR: H=%0d 越界 [1,%0d]", H, MAXH); $fatal(1, "bad H"); end

    NCI_B = (CIN + NCH - 1) / NCH;
    NCO_B = (COUT + NCH - 1) / NCH;
    // ★ C4b-D1：输出几何（`s=1` ⇒ HO=H、WO=IW、NPIX=H*IW —— 与改动前**逐字同值**）
    HO    = (H - 1) / STRIDE + 1;
    WO    = (IW - 1) / STRIDE + 1;
    NPIX  = HO * WO;
    NBEAT = (H + 1) * IW;      // 喂 H 行真行 + 1 行 pad 行（列数恒 IW）
    NBYTE = COUT * NPIX;
    NENT_TOT = NCI_B * NCO_B * NENT;
    MAXCYC = 20 * NBEAT + 4096;   // ★ C4b-D1：步长会拉长趟（非目标列照收但不进像素相位）
    if (NPIX > pixMax)  begin $display("TB-ERROR: HO*WO=%0d > pixMax=%0d", NPIX, pixMax); $fatal(1, "npix>pixMax"); end
    if (NCO_B > ncob)   begin $display("TB-ERROR: n_co=%0d > ncob=%0d", NCO_B, ncob); $fatal(1, "nco>ncob"); end
    if (NENT_TOT > MAXW)begin $display("TB-ERROR: 权重条目 %0d > %0d", NENT_TOT, MAXW); $fatal(1, "wgt overflow"); end
    if (NPIX > MAXPIX)  begin $display("TB-ERROR: HO*WO=%0d > 本装置上限 %0d", NPIX, MAXPIX); $fatal(1, "npix overflow"); end

    HAVE_DROP = HAVE_DROP && (DROPCI >= 0) && (DROPCI < NCI_B);

    for (k = 0; k < 64*MAXH*MAXIW; k = k + 1) begin xm[k] = 8'h00; outb[k] = 8'h00; end
    for (k = 0; k < MAXW; k = k + 1) wm[k] = 8'h00;
    for (k = 0; k < MAXCB*8; k = k + 1) bm[k] = 32'd0;
    for (k = 0; k < NCH; k = k + 1) begin x[k] = 8'h00; bias[k] = 32'd0; end

    $readmemh(xfile, xm, 0, CIN * H * IW - 1);
    $readmemh(wfile, wm, 0, NENT_TOT - 1);
    $readmemh(bfile, bm, 0, NCO_B * 8 - 1);

    requant_m = MPASS[31:0];
    zero_y    = MZEROY[7:0];

    // ---- 复位 ----
    peakAbs = 64'd0;                                           // ★ §3.7 峰值 |acc| 量具清零
    repeat (3) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    passes_run = 0; pix_total = 0; extra_total = 0; pass_bad = 0;

    // ---- 多趟：co-block 外、ci-block 内 ----
    for (j = 0; j < NCO_B; j = j + 1) begin
      for (i = 0; i < NCI_B; i = i + 1) begin
        p = j * NCI_B + i;
        // 该趟的权重瓦片（地址 = [co][ci_local][ky][kx]，576 项）
        for (k = 0; k < NENT; k = k + 1) begin
          @(negedge clk);
          we = 1'b1; waddr = k[9:0]; wdin = wm[p*NENT + k];
        end
        @(negedge clk);
        we = 1'b0; waddr = 10'd0; wdin = 8'h00;

        cob = j[2:0];
        for (co = 0; co < NCH; co = co + 1)
          bias[co] = (i == 0) ? bm[j*8 + co] : 32'd0;      // 偏置**只折进第 1 趟**（C4a.4 冻结规则）

        // 趟起点：prime 切片 + 部分和读地址回本段像素 0
        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;

        if (HAVE_DROP && i == DROPCI) begin
          // 负对照 A1：本 ci 趟**整趟不喂**（漏一趟）⇒ 该趟不产出像素、不写回部分和
          passes_run = passes_run + 1;
        end else begin
          fi = 0; pi = 0; extra = 0; cyc = 0;
          while ((pi < NPIX) && (cyc < MAXCYC)) begin
            if (fi < NBEAT) begin
              row  = fi / IW;                    // 行 0..H-1 是图像、行 H 是全 0 的 pad 行
              colc = fi % IW;
              x_valid = 1'b1;
              for (s = 0; s < NCH; s = s + 1) begin
                ci_g = i * NCH + s;
                // ★ C4b-D1：pad 行（row == H）整行填 `PADV`（= 该层 z_pad）；缺通道仍填 0（权重为 0 ⇒ 贡献 0）
                x[s] = (row < H) ? ((ci_g < CIN) ? xm[(ci_g*H + row)*IW + colc] : 8'h00) : PADV_B[7:0];
              end
            end else begin
              x_valid = 1'b0;
              for (s = 0; s < NCH; s = s + 1) x[s] = 8'h00;
            end
            #1;
            accept = x_valid && x_ready;
            if (y_valid) begin
              if (i == NCI_B - 1) begin                 // 只收最后一趟的料（前面的是半成品）
                if (pi < NPIX) begin
                  for (co = 0; co < NCH; co = co + 1)
                    if (j*NCH + co < COUT) outb[(j*NCH + co)*NPIX + pi] = y[co];
                end else begin
                  extra = extra + 1;
                end
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
            $display("TB-ERROR: pass j=%0d i=%0d 产出像素 %0d（期望 %0d）extra=%0d cyc=%0d fi=%0d/%0d",
                     j, i, pi, NPIX, extra, cyc, fi, NBEAT);
          end
        end
      end
    end

    pix_expect = (NCI_B - (HAVE_DROP ? 1 : 0)) * NCO_B * NPIX;

    // ---- 自报 + 输出 ----
    $display("MP CIN=%0d COUT=%0d H=%0d IW=%0d NCI=%0d NCO=%0d NPIX=%0d NBEAT=%0d M=%0d ZY=%0d DROPCI=%0d STRIDE=%0d PADV=%0d HO=%0d WO=%0d",
             CIN, COUT, H, IW, NCI_B, NCO_B, NPIX, NBEAT, MPASS, MZEROY, HAVE_DROP ? DROPCI : -1, STRIDE, PADV, HO, WO);
    $display("MP RTL imgC=%0d imgW=%0d pixMax=%0d ncob=%0d psRows=%0d psRowBytes=%0d psWordBytes=%0d psDepth=%0d",
             imgC, imgW, pixMax, ncob, psRows, psRowBytes, psWordBytes, psDepth);
    $display("MP PEAKABS=%0d ROWB=%0d", peakAbs, ROWB);        // ★ §3.7：本跑实测的峰值 |acc|
    $display("MP passes_run=%0d pix_total=%0d pix_expect=%0d extra_total=%0d pass_bad=%0d",
             passes_run, pix_total, pix_expect, extra_total, pass_bad);

    $write("Y");
    for (k = 0; k < NBYTE; k = k + 1) $write(" %02x", outb[k]);
    $write("\n");

    if ((passes_run == NCI_B * NCO_B) && (pix_total == pix_expect) &&
        (extra_total == 0) && (pass_bad == 0)) begin
      $display("RESULT: PASS");
      $finish;
    end else begin
      $display("RESULT: FAIL passes=%0d/%0d pix=%0d/%0d extra=%0d pass_bad=%0d",
               passes_run, NCI_B*NCO_B, pix_total, pix_expect, extra_total, pass_bad);
      $fatal(1, "MultiPassTb incomplete");
    end
  end

  // 仿真不收敛时的兜底（超时即判红，避免闸门挂死）
  initial begin
    #200000000;
    $display("RESULT: FAIL timeout");
    $fatal(1, "MultiPassTb timeout");
  end

endmodule
