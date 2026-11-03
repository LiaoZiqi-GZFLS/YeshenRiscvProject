//=============================================================================
// Conv3x3Tb.v —— 3x3 int8 卷积切片（rtl/Conv3x3Slice.scala）的整层数值装置（纯 Verilog）。
// 与 rtl_test/LineBufferTb.v / WeightStoreTb.v 同构：同一套 iverilog + $readmemh 口径。
//
// 契约（tools/run_numeric_ab.sh 头部冻结，逐字遵守）：
//   +XFILE=<file>  每行一个十六进制字节，X 展平 [ci][y][x]                 ⇒ CIN*H*IW 字节
//   +WFILE=<file>  每行一个十六进制字节，W 展平 [co][ci_local][ky][kx]      ⇒ COUT*(CIN/GROUP)*9 字节
//   +CIN= +COUT= +H= +IW= +GROUP=    维度（+IW 是**图宽**，故意不叫 +W，免得与权值文件撞名）
//   stdout：一行 "Y <hh> <hh> ..."（Y 展平 [co][y][x] ⇒ COUT*H*IW 字节）+ 一行 RESULT: PASS/FAIL；
//           FAIL 时 $fatal ⇒ vvp 退出非 0。
//   度量：3x3 / padding=1 / stride=1 / int32 累加 / max(-128, min(127, acc>>>6))（算术右移）。
//
// ★★ 两条接口陷阱就实现本文件里（下面标了"陷阱 1"/"陷阱 2"）：
//
//   【陷阱 1】喂 H+1 行：第 0..H-1 行 = XFILE 的图像，第 H 行 = **全 0 的 pad 行**。
//     切片与 LineBuffer 的接口里**都没有 H**，它们不可能自己造出"图底之下的零填充"；
//     输出行 H-1 要的第 H 行只能由**驱动方**喂 0。少喂这一行 ⇒ 只有最后一行输出错。
//     实现在下面 "★陷阱 1" 那三行：`row = fi/IW`、`x[ci] = (row < H) ? ... : 8'h00`、
//     以及 NBEAT = (H+1)*IW（喂流长度按 H+1 行算）。
//
//   【陷阱 2】预滚发射行不是有效输出行：LineBuffer 的窗口**比输入行晚一行**产出
//     （输出行 y 的窗口在输入行 y+1 流入那一拍才给出），于是输入行 r=0 那一拍吐的是
//     **输出行 y=-1** 的窗口 —— 那是预滚，不是输出。切片内部按 "row>=1 才出像素" 把整整
//     一行丢掉；本装置喂满 (H+1)*IW 列、只收 H*IW 个输出像素（NPIX = H*IW），
//     并把第 k 个收到的像素写进 yb[co*NPIX + k]（k 顺序就是 (y,x) 行主序）。
//     若把发射行 0 也当输出行收：Y 会整体错位一行，而且**长度仍然对得上**
//     （一样是 COUT*H*IW 字节）—— 只有逐字节对账才抓得到，所以这里必须按契约跳过。
//     实现在下面 "★陷阱 2" 那三行：NPIX = H*IW（而不是 (H+1)*IW）、pi 只数有效像素。
//
// ★ 网表**不在本文件里**：tools/run_numeric_ab.sh 把本装置与设备网表**一起**交给 iverilog
//   （`iverilog -g2012 -o dut_sim.vvp "$tb" "$rtl"`，而且 cwd 是 mktemp 出来的临时目录 ⇒
//   $rtl 必须是**绝对路径**）。网表文件含 5 个模块：
//     Conv3x3Slice / GroupedMacArray / WeightStore / LineBuffer / MacArray（oneFilePerComponent=false）。
//   重新生成（数值判据用 WIDTH=16）：`printf 'Test/runMain SliceGen <abs gen> 16\\nexit\\n' | bash sbt.sh`，产出三份：
//     GROUP=1 → gen/Conv3x3Slice.v（dense，判据的默认 RTL）；
//     GROUP=4 → gen/Conv3x3Slice_g4.v；GROUP=8（depthwise）→ gen/Conv3x3Slice_g8.v。
//
// ★ 档位自报（本装置怎么认网表）：三份变体的端口**同名同宽**，唯一差别是权重掩码常量，
//   装置自己分不出手里的网表是哪一档。所以 Conv3x3Slice 有一个只读常量输出 `grp` = GROUP，
//   本装置拿它与 +GROUP 对账 ⇒ 拿错档位的网表会**当场** $fatal 报红（而不是靠数值对账事后发现）。
//
// ★ 宽度自报（同一招治"宽度钉死"）：LineBuffer 按生成时的 WIDTH 数行，网表宽度与 +IW 不符时
//   窗口语义整个错位 —— 这种错的 Y **长度照样对得上**（只是数值大范围不对），靠事后 MISMATCH
//   才发现又晚又像"数值 bug"。所以切片另有一个只读常量输出 `imgW` = WIDTH（生成该网表时的行宽），
//   本装置在 time 0 拿它与 +IW 对账 ⇒ 用错了宽度的网表**立即** $fatal 报红，并指名要按请求宽度重生成。
//=============================================================================
`timescale 1ns/1ps

module Conv3x3Tb;
  // 三份网表共用同一套通道/宽度：C_IN=8、C_OUT=8、WIDTH=16（定点生成，装置对不上就报红）。
  // GROUP 不在装置里写死：由网表的 `grp` 常量与 +GROUP 对账（见上面"档位自报"）。
  localparam NCI  = 8;
  localparam NCO  = 8;
  localparam NIW  = 16;                    // 装置侧数组维度上限；真实宽度由网表自报的 imgW 对账
  localparam MAXH = 64;
  localparam MAXENT = NCO * NCI * 9;        // 权重条目上限（GROUP=1 时 576）

  reg [8*256-1:0] xfile, wfile;
  reg [7:0] xm [0:NCI*MAXH*NIW-1];          // X 原样：[ci][y][x]
  reg [7:0] wm [0:MAXENT-1];                // W 原样：[co][ci_local][ky][kx]
  reg [7:0] yb [0:NCO*MAXH*NIW-1];          // 收到的 Y：[co][y][x]

  integer CIN, COUT, H, IW, GROUP, NENT, NBEAT, NPIX, NBYTE, MAXCYC;

  reg clk = 1'b0;
  reg rst = 1'b1;
  reg        we     = 1'b0;
  reg [9:0]  waddr  = 10'd0;
  reg [7:0]  wdin   = 8'h00;
  reg [7:0]  x [0:NCI-1];
  reg        x_valid = 1'b0;
  wire       x_ready;
  wire [7:0] y [0:NCO-1];
  wire       y_valid;
  wire [3:0] grp;                          // 网表自报的档位（常量 = GROUP），用于 +GROUP 对账
  wire [15:0] imgW;                        // 网表自报的宽度（常量 = WIDTH），用于 +IW 对账

  always #5 clk = ~clk;

  Conv3x3Slice dut (
    .we(we),
    .waddr(waddr),
    .wdin(wdin),
    .x_0(x[0]), .x_1(x[1]), .x_2(x[2]), .x_3(x[3]),
    .x_4(x[4]), .x_5(x[5]), .x_6(x[6]), .x_7(x[7]),
    .x_valid(x_valid),
    .x_ready(x_ready),
    // ★ 新增的 additive 相位复位口（见 rtl/Conv3x3Slice.scala）：本装置只跑一张图、全程 0
    //   ⇒ 与"没有这个口"逐拍同形。**必须显式驱动**（否则 z 会让 `if (prime)` 变 x）。
    .prime(1'b0),
    // ★ C4a.5b §4.5：零填充码点。本闸门的黄金是 `mac_ref` 口径（pad = 字节 0）⇒ 喂 0
    //   （与旧行为逐字节同形）。**必须显式驱动**（否则 z 会让 colWin 清位变 x）。
    .pad_val(8'sd0),
    // ★★ C4b-D1：卷积步长（描述符 `w3[11:8]`）。本闸门的黄金是 **stride=1** 的 `mac_ref` 口径
    //   ⇒ 喂 1（与"没有这个口"逐拍同形）。**必须显式驱动**（否则 z 会让相位计数器变 x）。
    .stride(4'd1),
    // ★★ T-S1：**运行期行宽**。本闸门的用例就是"网表宽度"这一档（time 0 已对账 `+IW == imgW`）
    //   ⇒ 喂 `IW`（= 生成时的 WIDTH）⇒ 与"没有这个口"逐拍同形。**必须显式驱动**（否则 z 会让
    //   列回绕/行末列号变 x）。`16'(IW)` 是 SystemVerilog 的**定宽**转换（避免端口位宽告警）。
    .rowW(16'(IW)),
    .y_0(y[0]), .y_1(y[1]), .y_2(y[2]), .y_3(y[3]),
    .y_4(y[4]), .y_5(y[5]), .y_6(y[6]), .y_7(y[7]),
    .y_valid(y_valid),
    // ★ C4a.5a：切片新增的"多趟累加 + §4.4 requant"五个口。本装置跑的是**单趟整数卷积**
    //   （`mac_ref` 口径：`y = clamp(acc >>> 6)`），所以按**单位元**驱动：
    //     · ps_in = 0（无部分和载入 ⇒ 等价"第 1 趟"，累加器清零靠上电初值）；
    //     · bias  = 0（mac_ref 口径没有偏置）；
    //     · M = 2^24（单位乘子 ⇒ `((acc·2^24)>>24)>>6 == acc>>6`，与旧网表逐字节同形）；
    //     · z_y = 0。
    //   **必须显式驱动**（否则 z 会让乘法/加法变成 x）。这样本判据的黄金（纯 >>6）一字不改地继续成立；
    //   多趟累加 + 真乘子的判据是 `rtl_test/MultiPassTb.v` + `tools/run_multipass_ab.sh`。
    .requant_m(32'd16777216),
    .zero_y(8'sd0),
    .ps_in_0(64'sd0), .ps_in_1(64'sd0), .ps_in_2(64'sd0), .ps_in_3(64'sd0),
    .ps_in_4(64'sd0), .ps_in_5(64'sd0), .ps_in_6(64'sd0), .ps_in_7(64'sd0),
    .bias_0(32'sd0), .bias_1(32'sd0), .bias_2(32'sd0), .bias_3(32'sd0),
    .bias_4(32'sd0), .bias_5(32'sd0), .bias_6(32'sd0), .bias_7(32'sd0),
    .grp(grp),
    .imgW(imgW),
    .clk(clk),
    .reset(rst)
  );

  integer i, ci, co, fi, cyc, accept, pi, t, row, colc, extra, done;

  initial begin
    // ---- 参数 ----
    if (!$value$plusargs("XFILE=%s", xfile)) begin $display("TB-ERROR: 缺 +XFILE="); $fatal(1, "missing XFILE"); end
    if (!$value$plusargs("WFILE=%s", wfile)) begin $display("TB-ERROR: 缺 +WFILE="); $fatal(1, "missing WFILE"); end
    CIN = 0; COUT = 0; H = 0; IW = 0; GROUP = 0;
    if (!$value$plusargs("CIN=%d",   CIN))   begin $display("TB-ERROR: 缺 +CIN=");   $fatal(1, "missing CIN");   end
    if (!$value$plusargs("COUT=%d",  COUT))  begin $display("TB-ERROR: 缺 +COUT=");  $fatal(1, "missing COUT");  end
    if (!$value$plusargs("H=%d",     H))     begin $display("TB-ERROR: 缺 +H=");     $fatal(1, "missing H");     end
    if (!$value$plusargs("IW=%d",    IW))    begin $display("TB-ERROR: 缺 +IW=");    $fatal(1, "missing IW");    end
    if (!$value$plusargs("GROUP=%d", GROUP)) begin $display("TB-ERROR: 缺 +GROUP="); $fatal(1, "missing GROUP"); end

    if (CIN != NCI || COUT != NCO) begin
      $display("TB-ERROR: +CIN=%0d/+COUT=%0d 与本网表的 %0d/%0d 不符（网表定点生成）", CIN, COUT, NCI, NCO);
      $fatal(1, "dim mismatch");
    end
    // 宽度对账：+IW 必须与本网表自报的 imgW（= 生成该网表时的 WIDTH）一致。
    // LineBuffer 按 WIDTH 数行，宽度不符时窗口语义整个错位，而 Y 的长度照样对得上
    // ⇒ 只会以"大范围 MISMATCH"的形式暴露，像数值 bug。这里在 time 0 直接判红并指名重生成。
    if (IW != imgW) begin
      $display("TB-ERROR: +IW=%0d 与本网表自报的 imgW=%0d 不符 ⇒ 该网表是按 WIDTH=%0d 生成的；请用 WIDTH=%0d 重新生成后再跑数值判据（SliceGen <outDir> %0d）", IW, imgW, imgW, IW, IW);
      $fatal(1, "IW mismatch");
    end
    // 档位对账：+GROUP 必须与本网表自报的 grp（= 生成该网表时的 GROUP）一致。
    // 三份变体端口同名同宽，装置分不出手里是哪一档 ⇒ 只能由网表把档位报出来对。
    if (GROUP != grp) begin
      $display("TB-ERROR: +GROUP=%0d 与本网表自报的 grp=%0d 不符 ⇒ 拿错 GROUP 变体的网表了", GROUP, grp);
      $fatal(1, "GROUP mismatch");
    end
    if (H < 1 || H > MAXH) begin $display("TB-ERROR: H=%0d 越界 [1,%0d]", H, MAXH); $fatal(1, "bad H"); end

    NENT  = COUT * (CIN / GROUP) * 9;     // 权重条目数 = WFILE 的字节数（weightAddr 的展平顺序）
    NBEAT = (H + 1) * IW;                 // ★陷阱 1：喂 H+1 行（第 H 行是全 0 的 pad 行）
    NPIX  = H * IW;                       // ★陷阱 2：只收 H*IW 个有效输出像素（预滚行 r=0 不出像素）
    NBYTE = NCO * NPIX;
    MAXCYC = NBEAT * 16 + 4096;
    if (NENT < 1 || NENT > MAXENT) begin $display("TB-ERROR: NENT=%0d 越界 [1,%0d]", NENT, MAXENT); $fatal(1, "bad NENT"); end

    for (i = 0; i < NCI*MAXH*NIW; i = i + 1) xm[i] = 8'h00;
    for (i = 0; i < MAXENT; i = i + 1)       wm[i] = 8'h00;
    for (i = 0; i < NCO*MAXH*NIW; i = i + 1) yb[i] = 8'h00;
    // 显式给范围：XFILE 必须**恰好**是 CIN*H*IW 个字节、WFILE 必须**恰好**是 NENT 个字节。
    $readmemh(xfile, xm, 0, NCI*H*IW-1);
    $readmemh(wfile, wm, 0, NENT-1);

    for (ci = 0; ci < NCI; ci = ci + 1) x[ci] = 8'h00;

    // ---- 复位（LineBuffer 的 hist 复位为 0 ⇒ 第一行之上的零填充由此得到）----
    repeat (3) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    // ---- 装载整层权重：一拍一个字节，地址线性 0..NENT-1 ----
    // 地址线性推进就是在写 GroupMask.weightAddr 的展平顺序（本装置不重排、不解释）。
    for (i = 0; i < NENT; i = i + 1) begin
      @(negedge clk);
      we = 1'b1; waddr = i[9:0]; wdin = wm[i];
    end
    @(negedge clk);
    we = 1'b0; waddr = 10'd0; wdin = 8'h00;

    // ---- 喂流 + 收像素 ----
    // 打输入/采样的口径与 LineBufferTb 完全一致：在 negedge 上把本拍输入就位，等 #1 让组合
    // 通路稳定后采样（此时 DUT 的列/历史寄存器还是**本拍之前**的值 ⇒ 正好是"本拍读旧历史"）。
    fi = 0; pi = 0; extra = 0; done = 0;
    for (cyc = 0; (cyc < MAXCYC) && (done == 0); cyc = cyc + 1) begin
      if (fi < NBEAT) begin
        row  = fi / IW;                    // ★陷阱 1：行 0..H-1 是图像、行 H 是 pad 行
        colc = fi % IW;
        x_valid = 1'b1;
        for (ci = 0; ci < NCI; ci = ci + 1)
          x[ci] = (row < H) ? xm[(ci*H + row)*IW + colc] : 8'h00;   // ★陷阱 1：pad 行整行喂 0
      end else begin
        x_valid = 1'b0;
        for (ci = 0; ci < NCI; ci = ci + 1) x[ci] = 8'h00;
      end
      #1;
      accept = x_valid && x_ready;
      if (y_valid) begin
        if (pi >= NPIX) extra = extra + 1;                    // 多出来的像素 = 协议错
        else for (co = 0; co < NCO; co = co + 1) yb[co*NPIX + pi] = y[co];   // [co][y][x]：pi 就是 y*IW+x
        pi = pi + 1;                                          // ★陷阱 2：只数有效像素
      end
      @(negedge clk);
      if (accept) fi = fi + 1;
      if (pi >= NPIX) done = 1;
    end

    // ---- 打印 Y（[co][y][x] 展平；闸门用 grep '^Y ' 收）----
    $write("Y");
    for (t = 0; t < NBYTE; t = t + 1) $write(" %02x", yb[t]);
    $write("\n");

    // ---- 自检（完整性；数值正确性由闸门的 Python 参考逐字节判）----
    if (pi == NPIX && fi == NBEAT && extra == 0) begin
      $display("RESULT: PASS");
      $finish;
    end else begin
      $display("RESULT: FAIL pix=%0d/%0d beat=%0d/%0d extra=%0d", pi, NPIX, fi, NBEAT, extra);
      $fatal(1, "Conv3x3Tb incomplete");
    end
  end

  // 仿真不收敛时的兜底：超时即判红（非 0 退出），避免闸门挂死。
  initial begin
    #20000000;
    $display("RESULT: FAIL timeout");
    $fatal(1, "Conv3x3Tb timeout");
  end

endmodule
