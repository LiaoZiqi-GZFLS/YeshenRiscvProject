// LineBuffer 行缓冲自检装置 —— 纯 Verilog（不走 SpinalHDL）。
// 为什么是 .v：本机整套数值闸门都跑 `iverilog -g2012` + `$readmemh` 向量文件，
// 装置必须与 tools/run_macarray_ab.sh / run_numeric_ab.sh 那个装置同构，闸门才只有一套口径。
//
// 契约（与 tools/run_linebuffer_ab.sh 头部注释同风格）：
//   +XFILE=<file> 每行一个十六进制字节，**行主序的图像**：[row][col][ci] ⇒ CIN*H*IW 字节
//   +YFILE=<file> 每行一个十六进制字节，**期望的窗口序列**，展平顺序见下 ⇒ (H+1)*IW*CIN*3 字节
//   +CIN=<n>       输入通道数（必须 == 本网表的 C_IN；网表是定点生成的，不符就报错退出）
//   +IW=<n>        图像宽度（必须 == 本网表的 WIDTH，理由同上）
//   +H=<n>         图像高度（本模块**没有** H 输入，H 只决定装置喂几行）
//
// ★ 喂流约定（与 rtl/LineBuffer.scala 的注释、与 tools/run_linebuffer_ab.sh 的 python 期望
//   逐字一致；三处不许各自解释）：
//   - 行主序：en 的每一拍推进一列，IW 列一行，行行相接。喂 **H+1 行**：
//     第 0..H-1 行 = XFILE 的图像，第 H 行 = **全 0 的 pad 行**。
//     为什么多喂一行：窗口比输入行**晚一行**产出（输出行 y 的窗口在第 y+1 行流入时才给出），
//     于是"H 行图像"只能覆盖到输出行 H-2；而输出行 H-1 要的第 H 行必须由**驱动方**喂 0
//     （本模块接口里没有 H，它不可能自己造出下方零填充）。
//   - 第 r 行流入的那一拍，吐出的窗口是**输出行 y = r-1** 的窗口：
//     win(0)=第 y-1 行、win(1)=第 y 行、win(2)=第 y+1=r 行，三行**同一列 col = 本拍列**。
//     r=0 那一拍是**预滚（pre-roll）**：对应输出行 y=-1，不是有效输出行，但它是本接口
//     每拍都吐窗口的必然后果，所以**照样捕获、照样对账**。
//   - 越界行读 0：第 -1 行（第一行之上，hist 复位为 0）与第 H 行（最后一行之下，喂的 pad 行）。
//
// ★ 展平的顺序（TB 打印的 WIN 行 = 闸门 python 期望的顺序，**勿改**）：
//     [发射行 e][列 c][通道 ci][窗口行 r]
//   其中 e = 0..H（H+1 行，e=0 是预滚行、e=1..H 是输出行 0..H-1），
//   c = 0..IW-1，ci = 0..CIN-1，r = 0 上一行 / 1 当前行 / 2 下一行。
//   ⇒ 一维下标 = ((e*IW + c)*CIN + ci)*3 + r，共 (H+1)*IW*CIN*3 个字节。
//
// 输出：
//   一行 "WIN <hh> <hh> ..."（上述展平顺序）—— 闸门用 grep '^WIN ' 收；
//   一行 "RESULT: PASS" / "RESULT: FAIL ..." —— FAIL 时 $fatal 让 vvp 退出非 0。
//
// 时序：DUT 的 win 是**组合**输出。装置在 negedge 打输入（en=1），等 #1 让组合通路稳定后
//   采样 win —— 那一刻 DUT 的列寄存器/历史寄存器还都是**本拍之前**的值（posedge 尚无），
//   正好采到"本拍这一列上读旧历史"的窗口。
`timescale 1ns/1ps

module LineBufferTb;

  // 本装置对着**定点生成**的 gen/LineBuffer.v（C_IN=2、WIDTH=4）写。维度不符必须报红。
  localparam NCI = 2;    // DUT 的 C_IN
  localparam NW  = 4;    // DUT 的 WIDTH
  localparam MAXH = 64;
  localparam MAXWIN = (MAXH + 1) * NW * NCI * 3;

  reg [8*256-1:0] xfile, yfile;
  reg [7:0] xm  [0:NCI*MAXH*NW-1];      // 图像：[row][col][ci]
  reg [7:0] ym  [0:MAXWIN-1];           // 期望窗口序列
  reg [7:0] got [0:MAXWIN-1];           // DUT 实采窗口序列

  integer CIN, IW, H, NBEAT, NWIN;

  reg clk = 1'b0;
  reg rst = 1'b1;
  reg en  = 1'b0;
  reg [7:0] x [0:NCI-1];

  wire [7:0] win [0:NCI*3-1];           // win[ci*3 + r]

  always #5 clk = ~clk;

  LineBuffer dut (
    .x_0(x[0]), .x_1(x[1]),
    .en(en),
    // ★★ T-S1：**运行期行宽**。本闸门的用例就是"网表宽度"这一档（`+IW` == 生成时的 WIDTH）
    //   ⇒ 喂 `IW`（= WIDTH）⇒ 与"没有这个口"逐拍同形。**必须显式驱动**（否则 z 会让列回绕变 x）。
    .rowW(16'(NW)),
    // ★ 本模块新增的 additive 相位复位口（见 rtl/LineBuffer.scala）：本装置只跑一张图、
    //   全程保持 0 ⇒ 与"没有这个口"逐拍同形。**必须显式驱动**，否则它是 z（高阻），
    //   会让 DUT 里 `if (prime)` 变成 x 而污染 col/hist。
    .prime(1'b0),
    // ★ C4a.5b §4.5：零填充码点（pad_val）。本闸门只验证窗口搬运，与真实零码点无关 ⇒ 喂 0
    //   （与旧行为逐拍同形）。**必须显式驱动**（否则 z 会让 hist 清位变 x）。
    .pad_val(8'sd0),
    .win_0_0(win[0]), .win_0_1(win[1]), .win_0_2(win[2]),
    .win_1_0(win[3]), .win_1_1(win[4]), .win_1_2(win[5]),
    .clk(clk), .reset(rst)
  );

  integer i, c, r, row, col, bad, t;

  initial begin
    // ---- 取参数 ----
    if (!$value$plusargs("XFILE=%s", xfile)) begin
      $display("TB-ERROR: 缺 +XFILE="); $fatal(1, "missing XFILE");
    end
    if (!$value$plusargs("YFILE=%s", yfile)) begin
      $display("TB-ERROR: 缺 +YFILE="); $fatal(1, "missing YFILE");
    end
    CIN = 0; IW = 0; H = 0;
    if (!$value$plusargs("CIN=%d", CIN)) begin
      $display("TB-ERROR: 缺 +CIN="); $fatal(1, "missing CIN");
    end
    if (!$value$plusargs("IW=%d", IW)) begin
      $display("TB-ERROR: 缺 +IW="); $fatal(1, "missing IW");
    end
    if (!$value$plusargs("H=%d", H)) begin
      $display("TB-ERROR: 缺 +H="); $fatal(1, "missing H");
    end
    if (CIN != NCI) begin
      $display("TB-ERROR: +CIN=%0d 与本网表的 C_IN=%0d 不符（网表是定点生成的）", CIN, NCI);
      $fatal(1, "CIN mismatch");
    end
    if (IW != NW) begin
      $display("TB-ERROR: +IW=%0d 与本网表的 WIDTH=%0d 不符（网表是定点生成的）", IW, NW);
      $fatal(1, "IW mismatch");
    end
    if (H < 1 || H > MAXH) begin
      $display("TB-ERROR: H=%0d 越界 [1,%0d]", H, MAXH); $fatal(1, "bad H");
    end

    NBEAT = (H + 1) * IW;             // 注意：喂 H+1 行（最后一行是全 0 的 pad 行）
    NWIN  = NBEAT * CIN * 3;
    if (NWIN > MAXWIN) begin
      $display("TB-ERROR: 窗口 %0d 字节超过装置上限 %0d", NWIN, MAXWIN); $fatal(1, "too big");
    end

    for (i = 0; i < NCI*MAXH*NW; i = i + 1) xm[i] = 8'h00;
    for (i = 0; i < MAXWIN; i = i + 1) begin ym[i] = 8'h00; got[i] = 8'h00; end
    $readmemh(xfile, xm);
    $readmemh(yfile, ym);

    for (c = 0; c < NCI; c = c + 1) x[c] = 8'h00;

    // ---- 复位（hist 复位为 0 ⇒ 第一行之上的零填充）----
    repeat (3) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    // ---- 喂 H+1 行 x IW 列，每拍采一个窗口 ----
    // 打输入/采样的口径：先等 negedge（此刻 DUT 的 col/hist 还是**该拍之前**的值），
    // 在这个 negedge 上把本拍输入就位，等 #1 让组合通路稳定后采 win —— 离下一个 posedge
    // 还有 4ns，所以采到的正是"本拍这一列上读旧历史"的窗口（本拍的写要等 posedge 才生效）。
    for (i = 0; i < NBEAT; i = i + 1) begin
      @(negedge clk);
      row = i / IW;
      col = i % IW;
      for (c = 0; c < NCI; c = c + 1)
        x[c] = (row < H) ? xm[(row*IW + col)*NCI + c] : 8'h00;   // 第 H 行 = pad 行 = 全 0
      en = 1'b1;
      #1;
      for (c = 0; c < NCI; c = c + 1)
        for (r = 0; r < 3; r = r + 1)
          got[((i*NCI + c)*3) + r] = win[c*3 + r];
    end
    en = 1'b0;
    @(negedge clk);

    // ---- 打印 DUT 的原始窗口序列（闸门按这行逐字节对账）----
    $write("WIN");
    for (t = 0; t < NWIN; t = t + 1) $write(" %02x", got[t]);
    $write("\n");

    // ---- 自检：DUT 的字节 vs YFILE ----
    bad = 0;
    for (t = 0; t < NWIN; t = t + 1)
      if (got[t] !== ym[t]) begin
        bad = bad + 1;
        if (bad <= 8)
          $display("MISMATCH byte%0d (e=%0d c=%0d ci=%0d r=%0d): dut=%02x exp=%02x",
                   t, t/(IW*CIN*3), (t/(CIN*3)) % IW, (t/3) % CIN, t % 3, got[t], ym[t]);
      end

    if (bad == 0) begin
      $display("RESULT: PASS");
      $finish;
    end else begin
      $display("RESULT: FAIL bad=%0d", bad);
      $fatal(1, "LineBufferTb mismatch");
    end
  end

  // 仿真不收敛时的兜底：超时即判红（非 0 退出），避免闸门挂死。
  initial begin
    #2000000;
    $display("RESULT: FAIL timeout");
    $fatal(1, "LineBufferTb timeout");
  end

endmodule
