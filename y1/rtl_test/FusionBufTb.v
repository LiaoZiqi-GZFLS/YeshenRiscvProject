// FusionBuf 装置 —— 行流式融合缓冲（gen/FusionBuf*.v）的功能闸门装置。
// 为什么是 .v（不走 SpinalHDL）：本机整套数值闸门都跑 `iverilog -g2012` + `$readmemh` 向量文件，
// 装置必须与 tools/run_linebuffer_ab.sh / run_desc_ab.sh 那个装置同构，闸门才只有一套口径。
//
// ★ 形状参数（**编译期宏**，不要用运行期 plusargs 改形状）——
//   本装置对**定点生成**的网表写，列地址位宽/数组尺寸必须逐位对上，所以形状用 `iverilog -D` 传：
//     FB_NCI = DUT 的 C        （默认 2）
//     FB_NW  = DUT 的 WIDTH    （默认 4）
//     FB_CW  = DUT 列地址位宽  （= log2Up(WIDTH) max 1；W=4→2、W=5→3；默认 2）
//   闸门 tools/run_fusionbuf_ab.sh **对两个形状各编译一次装置**：
//     · 形状 1：C=2 / W=4（默认宏）   对 gen/FusionBuf.v
//     · 形状 2：C=2 / W=5（非 2 的幂列宽）对 gen/FusionBuf_w5.v（-DFB_NW=5 -DFB_CW=3）
//   装置只用到前 C 个通道 / 前 WIDTH 列；但 DUT 的端口是大位宽端口（rd_data_0/1 定名），
//   **通道数 C 仍写死为 2**（端口名不可参数化）⇒ 更大 C 未被本装置仿真，属**已知残留风险**。
//
// 契约（与 tools/run_fusionbuf_ab.sh 头部注释同风格）：
//   +XFILE=<file>        H x WIDTH x C 的**图像**字节（一行一 hex，行主序 [row][col][ci]）
//   +STALEFILE=<file>    复位态（尚未写任何东西）读回期望（3*WIDTH*C 字节，全 0）
//   +PARTIALFILE=<file>  只写完**前 2 行**后读回期望（负对照 A：尚未写过的最老槽必须读 0）
//   +WINFILE=<file>      写满 H 行后读回期望
//   +C=<n> +W=<n> +H=<n>   维度（C/W 必须 == 本网表的 C/W，不符则 **time 0 `$fatal`**；H 任意但须 >3）
//   +ADV_EARLY=1         （负对照 B）写完后**多推一次行指针**（"把 wr_row_adv 提前一行"）
//                        ⇒ 窗口内容必须变化（闸门按"提前一行的预测值"精确对账）
//
// ★ 读回展平顺序（**三处一致：本装置 / 闸门 python 模型 / 注释**，勿改）：
//     [rd_row][rd_col][ci]   下标 = (rd_row*WIDTH + rd_col)*C + ci，共 3*WIDTH*C 字节。
//   rd_row 0=最老 / 1=中 / 2=最新（最新 = 最后完成的那一行）；rd_col 0..WIDTH-1；ci 0..C-1。
//
// ★ 相位（同一笔仿真里，一次复位、不中途复位 —— 块 RAM 物理上没有 reset，只有上电初值）：
//   相 0 STALE  ：复位后、**任何写之前**读回 ⇒ "尚未被写过的窗口位置"必须读出**复位值 0**。
//   相 1 PARTIAL：只写前 2 行（<3 行）再读回 ⇒ 最老那一档正好落在**从未写过的物理行槽**，
//                 必须读 0；另两档必须等于第 1/第 2 行的数据（证明这几档不是"整体死了"）。
//   相 2 WIN    ：写完 H 行后读回 ⇒ 正好是最后完成的三行，与 python 环形模型**逐字节**一致。
//
// ★ 时序（= RTL 文件头"消费者契约"在装置侧的体现，三处口径一致）：
//   · 读延迟 1 拍（同步读）：给上 (rd_row, rd_col) 后，下一个 posedge 把 `mem[rd_addr]` 打进
//     输出寄存器，再下一个 negedge 采样即可拿到 —— 即本装置 do_read 的固定两拍节奏。
//   · 写口：negedge 摆好 (wr_col, wr_data, wr_en, wr_row_adv)，紧接的 posedge 落笔（整列一个字）
//     并做行轮转（`wr_row_adv && wr_col==WIDTH-1`）。**该推进拍**的读看的是推进前的 row_ptr
//     ⇒ 与推进同拍发起的读会老一行（本装置每笔读都与写分开摆拍，故不受此边界影响）。
`timescale 1ns/1ps

// ---- 形状参数（编译期宏；默认 = 主功能档 C=2 / WIDTH=4）----
`ifndef FB_NCI
  `define FB_NCI 2
`endif
`ifndef FB_NW
  `define FB_NW 4
`endif
`ifndef FB_CW
  `define FB_CW 2
`endif

module FusionBufTb;

  // 本装置对着**定点生成**的网表写（默认 C=2 / WIDTH=4；形状由上面的编译期宏决定）。维度不符必须报红。
  localparam NCI    = `FB_NCI;               // DUT 的 C
  localparam NW     = `FB_NW;                // DUT 的 WIDTH
  localparam CW     = `FB_CW;                // DUT 列地址位宽 = log2Up(WIDTH) max 1（W=4→2、W=5→3）
  localparam MAXH   = 64;                    // 装置允许的最大行数
  localparam NBYTES = 3 * NW * NCI;          // 每相读回字节数 = 3*W*C

  reg [8*256-1:0] xfile, staleFile, partialFile, winFile;
  reg [7:0] xm        [0:NCI*MAXH*NW-1];     // 图像：[row][col][ci]
  reg [7:0] e_stale   [0:NBYTES-1];          // 期望：复位态
  reg [7:0] e_partial [0:NBYTES-1];          // 期望：只写 2 行
  reg [7:0] e_win     [0:NBYTES-1];          // 期望：写满 H 行
  reg [7:0] g_stage   [0:NBYTES-1];          // 读相暂存
  reg [7:0] g_stale   [0:NBYTES-1];          // DUT 实采
  reg [7:0] g_partial [0:NBYTES-1];
  reg [7:0] g_win     [0:NBYTES-1];

  integer C, W, H, ADV_EARLY, got_arg;

  reg clk = 1'b0;
  reg rst = 1'b1;
  reg        wr_en      = 1'b0;
  reg        wr_row_adv = 1'b0;
  // 列地址用 CW 位（= DUT 的列地址位宽，逐位对上，避免端口位宽失配）。
  reg [CW-1:0] wr_col     = {CW{1'b0}};
  reg [7:0]  wr_data_0  = 8'd0;
  reg [7:0]  wr_data_1  = 8'd0;
  reg [1:0]  rd_row     = 2'd0;
  reg [CW-1:0] rd_col    = {CW{1'b0}};

  wire [7:0]  rd_data_0, rd_data_1;
  wire [15:0] imgC, imgW;

  always #5 clk = ~clk;

  FusionBuf dut (
    .wr_col(wr_col), .wr_data_0(wr_data_0), .wr_data_1(wr_data_1),
    .wr_en(wr_en), .wr_row_adv(wr_row_adv),
    .rd_row(rd_row), .rd_col(rd_col),
    // ★★ T-S1：**运行期行宽**（行槽步长 = `rowW`）。本闸门的两档就是"网表宽度"这一档
    //   （`NW` == 生成时的 WIDTH）⇒ 喂 `NW` ⇒ 与"没有这个口"逐拍同形。**必须显式驱动**
    //   （否则 z 会让写地址/行末判定变 x）。
    .rowW(16'(NW)),
    .rd_data_0(rd_data_0), .rd_data_1(rd_data_1),
    .imgC(imgC), .imgW(imgW),
    .clk(clk), .reset(rst)
  );

  integer i, t, bad, r, cc, rr;

  // 读一拍（同步读，1 拍延迟）：negedge 摆地址 → posedge 落进输出寄存器 → 下个 negedge 采样。
  task do_read(input integer rr_, input integer cc_);
    begin
      @(negedge clk);
      rd_row = rr_[1:0]; rd_col = cc_[CW-1:0];
      @(negedge clk);
      g_stage[(rr_*NW + cc_)*NCI + 0] = rd_data_0;
      g_stage[(rr_*NW + cc_)*NCI + 1] = rd_data_1;
    end
  endtask

  // 写一列（整列一个字）：negedge 摆好，紧接的 posedge 落笔。
  task do_write(input integer rr_, input integer cc_, input integer adv_);
    begin
      @(negedge clk);
      wr_col     = cc_[CW-1:0];
      wr_data_0  = xm[(rr_*NW + cc_)*NCI + 0];
      wr_data_1  = xm[(rr_*NW + cc_)*NCI + 1];
      wr_en      = 1'b1;
      wr_row_adv = (adv_ != 0);
    end
  endtask

  // 读回一整相（3 档 rd_row x WIDTH 列），填进 g_stage。
  task read_phase;
    begin
      for (rr = 0; rr < 3; rr = rr + 1)
        for (cc = 0; cc < NW; cc = cc + 1)
          do_read(rr, cc);
    end
  endtask

  initial begin
    // ---- 取参数 ----
    if (!$value$plusargs("XFILE=%s", xfile))            begin $display("TB-ERROR: 缺 +XFILE=");       $fatal(1, "missing XFILE"); end
    if (!$value$plusargs("STALEFILE=%s", staleFile))     begin $display("TB-ERROR: 缺 +STALEFILE=");   $fatal(1, "missing STALEFILE"); end
    if (!$value$plusargs("PARTIALFILE=%s", partialFile)) begin $display("TB-ERROR: 缺 +PARTIALFILE="); $fatal(1, "missing PARTIALFILE"); end
    if (!$value$plusargs("WINFILE=%s", winFile))         begin $display("TB-ERROR: 缺 +WINFILE=");     $fatal(1, "missing WINFILE"); end
    C = 0; W = 0; H = 0; ADV_EARLY = 0;
    if (!$value$plusargs("C=%d", C)) begin $display("TB-ERROR: 缺 +C="); $fatal(1, "missing C"); end
    if (!$value$plusargs("W=%d", W)) begin $display("TB-ERROR: 缺 +W="); $fatal(1, "missing W"); end
    if (!$value$plusargs("H=%d", H)) begin $display("TB-ERROR: 缺 +H="); $fatal(1, "missing H"); end
    got_arg = $value$plusargs("ADV_EARLY=%d", ADV_EARLY);   // 可选（负对照 B）；返回值丢弃

    // ---- 参数自报对账（time 0，防"生成参数不符"的静默错判）----
    if (imgC != C || imgW != W) begin
      $display("TB-ERROR: 网表自报 imgC=%0d imgW=%0d 与 +C=%0d +W=%0d 不符（网表是定点生成的）", imgC, imgW, C, W);
      $fatal(1, "self-report mismatch");
    end
    if (C != NCI || W != NW) begin
      $display("TB-ERROR: +C=%0d +W=%0d 与本装置的 NCI=%0d NW=%0d 不符", C, W, NCI, NW);
      $fatal(1, "dim mismatch");
    end
    if (H <= 3) begin
      $display("TB-ERROR: +H=%0d 须 > 3（否则'整张 = 一个窗口'，行流式退化成无意义）", H);
      $fatal(1, "degenerate H");
    end
    if (H > MAXH) begin $display("TB-ERROR: +H=%0d 越界 [4,%0d]", H, MAXH); $fatal(1, "bad H"); end

    // ---- 读向量 ----
    for (i = 0; i < NCI*MAXH*NW; i = i + 1) xm[i] = 8'h00;
    for (i = 0; i < NBYTES; i = i + 1) begin
      e_stale[i] = 8'h00; e_partial[i] = 8'h00; e_win[i] = 8'h00;
      g_stage[i] = 8'h00; g_stale[i]   = 8'h00; g_partial[i] = 8'h00; g_win[i] = 8'h00;
    end
    $readmemh(xfile, xm);
    $readmemh(staleFile, e_stale);
    $readmemh(partialFile, e_partial);
    $readmemh(winFile, e_win);

    // ---- 复位 ----
    wr_en = 1'b0; wr_row_adv = 1'b0; wr_col = {CW{1'b0}}; wr_data_0 = 8'd0; wr_data_1 = 8'd0;
    rd_row = 2'd0; rd_col = {CW{1'b0}};
    repeat (3) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    // ---- 相 0：复位态读回（尚未写过任何东西 ⇒ 期望全 0）----
    read_phase;
    for (t = 0; t < NBYTES; t = t + 1) g_stale[t] = g_stage[t];

    // ---- 相 1：只写前 2 行，再读回 ----
    for (r = 0; r < 2; r = r + 1)
      for (cc = 0; cc < NW; cc = cc + 1)
        do_write(r, cc, (cc == NW-1));
    @(negedge clk); wr_en = 1'b0; wr_row_adv = 1'b0;
    read_phase;
    for (t = 0; t < NBYTES; t = t + 1) g_partial[t] = g_stage[t];

    // ---- 相 2：写剩余各行（第 2 .. H-1 行）----
    for (r = 2; r < H; r = r + 1)
      for (cc = 0; cc < NW; cc = cc + 1)
        do_write(r, cc, (cc == NW-1));
    @(negedge clk); wr_en = 1'b0; wr_row_adv = 1'b0;

    // ---- 负对照 B：多推一次行指针（"把 wr_row_adv 提前一行"）----
    // 注：DUT 的行轮转条件是 `wr_row_adv && wr_col==WIDTH-1`（**不要求 wr_en**，见 RTL 注释）⇒
    //     这一拍只推指针、不写数据。指针因此比"写满 H 行"多走一行 ⇒ 窗口整体错一行 ⇒ 必变。
    if (ADV_EARLY == 1) begin
      @(negedge clk); wr_col = NW-1; wr_en = 1'b0; wr_row_adv = 1'b1;
      @(negedge clk); wr_row_adv = 1'b0;
    end

    // ---- 相 3：写满后读回 ----
    read_phase;
    for (t = 0; t < NBYTES; t = t + 1) g_win[t] = g_stage[t];

    // ---- 打印三行（闸门按行 grep 后逐字节对账）----
    $write("STALE");
    for (t = 0; t < NBYTES; t = t + 1) $write(" %02x", g_stale[t]);
    $write("\n");
    $write("PARTIAL");
    for (t = 0; t < NBYTES; t = t + 1) $write(" %02x", g_partial[t]);
    $write("\n");
    $write("WIN");
    for (t = 0; t < NBYTES; t = t + 1) $write(" %02x", g_win[t]);
    $write("\n");

    // ---- 自检：三相对 3 份期望逐个字节比（`!==` ⇒ X 也算不符）----
    bad = 0;
    for (t = 0; t < NBYTES; t = t + 1) if (g_stale[t]   !== e_stale[t])   bad = bad + 1;
    for (t = 0; t < NBYTES; t = t + 1) if (g_partial[t] !== e_partial[t]) bad = bad + 1;
    for (t = 0; t < NBYTES; t = t + 1) if (g_win[t]     !== e_win[t])     bad = bad + 1;
    if (bad == 0) begin
      $display("RESULT: PASS");
      $finish;
    end else begin
      $display("RESULT: FAIL bad=%0d", bad);
      $fatal(1, "FusionBufTb mismatch");
    end
  end

  // 仿真不收敛时的兜底：超时即判红（非 0 退出），避免闸门挂死。
  initial begin
    #2000000;
    $display("RESULT: FAIL timeout");
    $fatal(1, "FusionBufTb timeout");
  end

endmodule
