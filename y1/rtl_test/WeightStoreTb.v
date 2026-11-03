// WeightStore 权重存储自检装置 —— 纯 Verilog（与 rtl_test/LineBufferTb.v 同构，不走 SpinalHDL）。
// 为什么是 .v：本机整套数值闸门都跑 `iverilog -g2012` + `$readmemh` 向量文件，装置必须与
// tools/run_linebuffer_ab.sh / run_macarray_ab.sh 那个装置同一套口径。
//
// 契约（与 tools/run_weightstore_ab.sh 头部注释逐字一致）：
//   +WLOAD=<file>    每行一个十六进制字节，**整层权重**，展平顺序 = GroupMask.weightAddr 的顺序
//                    [co][ci_local][ky][kx] ⇒ co*PER_GROUP*9 + ci_local*9 + k，共
//                    COUT*(CIN/GROUP)*9 字节（WLOAD 就是这个"未落位压缩张量"的原样文件）
//   +TILEFILE=<file> 每行一个十六进制字节，**期望的 9 块瓦片**，展平顺序 [k][co][ci] ⇒ 9*COUT*CIN 字节
//   +CIN=<n> +COUT=<n> +GROUP=<n>   维度。CIN/COUT 必须 == 本网表的 8/8（网表是定点生成的，
//                    不符就报错退出）；GROUP 必须是 8 的约数，它只用来算 WLOAD 的长度（掩码规则
//                    本装置**不重算**：期望瓦片由闸门的 python 独立算好，喂进来对账）。
//
// 装置做的事（三步）：
//   1) 装载：把 WLOAD 的 N 个字节按地址 0..N-1 **一拍一个**写进存储（就是"整层常驻"那一次装载，
//      之后每像素只做选 k —— 见 rtl/WeightStore.scala 开头的带宽论证）；
//   2) 采样：k 从 0 到 8 逐个选，采 DUT 的 64 个 tile 端口（tile 是**组合**输出，k 当拍生效）；
//   3) 对账：装置自比 TILEFILE（打印一行 "TILE <k> <hh> ..." 逐 k 供闸门按字节对账，
//      外加装置自己的 RESULT: PASS|FAIL；FAIL 时 $fatal 让 vvp 退出非 0）。
//
// 输出：
//   9 行 "TILE <k> <hh> ..."（每行 64 个字节，顺序 [co][ci]），k = 0..8 依次；
//   一行 "RESULT: PASS" / "RESULT: FAIL ..." —— FAIL 时 $fatal ⇒ vvp 非 0。
`timescale 1ns/1ps

module WeightStoreTb;

  // 本装置对着**定点生成**的 gen/WeightStore*.v 写（C_IN = C_OUT = 8，GROUP 由 +GROUP= 给）。
  localparam NCI = 8;                       // DUT 的 C_IN
  localparam NCO = 8;                       // DUT 的 C_OUT
  localparam MAXENT  = NCO * NCI * 9;        // 权重条目上限（GROUP=1 时 576）
  localparam NTILE   = 9 * NCO * NCI;        // 9 块瓦片的字节数（顺序 [k][co][ci]）

  reg [8*256-1:0] wload, tfile;
  reg [7:0] wm  [0:MAXENT-1];                // 整层权重（压缩张量，weightAddr 顺序）
  reg [7:0] tm  [0:NTILE-1];                 // 期望瓦片（闸门 python 现算，本装置不重算掩码）
  reg [7:0] got [0:NTILE-1];                 // DUT 实采瓦片

  integer CIN, COUT, GROUP, NENT;

  reg        clk = 1'b0;
  reg        rst = 1'b1;
  reg        we   = 1'b0;
  reg [9:0]  waddr = 10'd0;                  // 各档 waddr 位宽不同（10/8/7），取最宽那一档接
  reg [7:0]  wdin  = 8'h00;
  reg [3:0]  k     = 4'd0;

  wire [7:0] tile [0:NCO*NCI-1];             // tile[co*NCI + ci]

  always #5 clk = ~clk;

  WeightStore dut (
    .we(we),
    .waddr(waddr),
    .wdin(wdin),
    .k(k),
    .tile_0_0(tile[0]),  .tile_0_1(tile[1]),  .tile_0_2(tile[2]),  .tile_0_3(tile[3]),
    .tile_0_4(tile[4]),  .tile_0_5(tile[5]),  .tile_0_6(tile[6]),  .tile_0_7(tile[7]),
    .tile_1_0(tile[8]),  .tile_1_1(tile[9]),  .tile_1_2(tile[10]), .tile_1_3(tile[11]),
    .tile_1_4(tile[12]), .tile_1_5(tile[13]), .tile_1_6(tile[14]), .tile_1_7(tile[15]),
    .tile_2_0(tile[16]), .tile_2_1(tile[17]), .tile_2_2(tile[18]), .tile_2_3(tile[19]),
    .tile_2_4(tile[20]), .tile_2_5(tile[21]), .tile_2_6(tile[22]), .tile_2_7(tile[23]),
    .tile_3_0(tile[24]), .tile_3_1(tile[25]), .tile_3_2(tile[26]), .tile_3_3(tile[27]),
    .tile_3_4(tile[28]), .tile_3_5(tile[29]), .tile_3_6(tile[30]), .tile_3_7(tile[31]),
    .tile_4_0(tile[32]), .tile_4_1(tile[33]), .tile_4_2(tile[34]), .tile_4_3(tile[35]),
    .tile_4_4(tile[36]), .tile_4_5(tile[37]), .tile_4_6(tile[38]), .tile_4_7(tile[39]),
    .tile_5_0(tile[40]), .tile_5_1(tile[41]), .tile_5_2(tile[42]), .tile_5_3(tile[43]),
    .tile_5_4(tile[44]), .tile_5_5(tile[45]), .tile_5_6(tile[46]), .tile_5_7(tile[47]),
    .tile_6_0(tile[48]), .tile_6_1(tile[49]), .tile_6_2(tile[50]), .tile_6_3(tile[51]),
    .tile_6_4(tile[52]), .tile_6_5(tile[53]), .tile_6_6(tile[54]), .tile_6_7(tile[55]),
    .tile_7_0(tile[56]), .tile_7_1(tile[57]), .tile_7_2(tile[58]), .tile_7_3(tile[59]),
    .tile_7_4(tile[60]), .tile_7_5(tile[61]), .tile_7_6(tile[62]), .tile_7_7(tile[63]),
    .clk(clk),
    .reset(rst)
  );

  integer i, kk, co, ci, bad, t;

  initial begin
    // ---- 取参数 ----
    if (!$value$plusargs("WLOAD=%s", wload)) begin
      $display("TB-ERROR: 缺 +WLOAD="); $fatal(1, "missing WLOAD");
    end
    if (!$value$plusargs("TILEFILE=%s", tfile)) begin
      $display("TB-ERROR: 缺 +TILEFILE="); $fatal(1, "missing TILEFILE");
    end
    CIN = 0; COUT = 0; GROUP = 0;
    if (!$value$plusargs("CIN=%d", CIN))   begin $display("TB-ERROR: 缺 +CIN=");   $fatal(1, "missing CIN");   end
    if (!$value$plusargs("COUT=%d", COUT)) begin $display("TB-ERROR: 缺 +COUT=");  $fatal(1, "missing COUT");  end
    if (!$value$plusargs("GROUP=%d", GROUP)) begin $display("TB-ERROR: 缺 +GROUP="); $fatal(1, "missing GROUP"); end
    if (CIN != NCI || COUT != NCO) begin
      $display("TB-ERROR: +CIN=%0d/+COUT=%0d 与本网表的 %0d/%0d 不符（网表是定点生成的）", CIN, COUT, NCI, NCO);
      $fatal(1, "dim mismatch");
    end
    if (GROUP < 1 || (NCI % GROUP) != 0) begin
      $display("TB-ERROR: GROUP=%0d 必须 >=1 且整除 %0d", GROUP, NCI);
      $fatal(1, "bad GROUP");
    end
    NENT = COUT * (CIN / GROUP) * 9;               // 压缩权重张量的字节数 = WLOAD 的长度
    if (NENT < 1 || NENT > MAXENT) begin
      $display("TB-ERROR: NENT=%0d 越界 [1,%0d]", NENT, MAXENT);
      $fatal(1, "bad NENT");
    end

    for (i = 0; i < MAXENT; i = i + 1) wm[i] = 8'h00;
    for (i = 0; i < NTILE;  i = i + 1) begin tm[i] = 8'h00; got[i] = 8'h00; end
    // 显式给范围：WLOAD 必须**恰好**是 NENT 个字节、TILEFILE 必须**恰好**是 NTILE 个字节，
    // 多一个少一个都由 iverilog 的 "Not enough words" 警告/闸门的字节数自检当场暴露。
    $readmemh(wload, wm, 0, NENT-1);
    $readmemh(tfile, tm, 0, NTILE-1);

    // ---- 复位 ----
    repeat (3) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    // ---- 1) 装载整层权重：一拍一个字节，地址线性 0..NENT-1 ----
    // 地址线性推进就是在写 weightAddr 的展平顺序：本装置不重排、不解释，WLOAD 与 DUT 的地址口径
    // 必须逐字一致（这正是"权重布局与 GroupMask.weightAddr 一致"这条契约的装置侧表达）。
    for (i = 0; i < NENT; i = i + 1) begin
      @(negedge clk);
      we    = 1'b1;
      waddr = i[9:0];
      wdin  = wm[i];
    end
    @(negedge clk);
    we = 1'b0; waddr = 10'd0; wdin = 8'h00;    // 装载只做一次；之后每像素只选 k
    @(negedge clk);

    // ---- 2) 采样 9 块瓦片（tile 是组合输出：negedge 后打 k，等 #1 采）----
    for (kk = 0; kk < 9; kk = kk + 1) begin
      @(negedge clk);
      k = kk[3:0];
      #1;
      $write("TILE %0d", kk);
      for (co = 0; co < NCO; co = co + 1)
        for (ci = 0; ci < NCI; ci = ci + 1) begin
          got[(kk*NCO + co)*NCI + ci] = tile[co*NCI + ci];
          $write(" %02x", tile[co*NCI + ci]);
        end
      $write("\n");
    end

    // ---- 3) 自检：DUT 的瓦片字节 vs TILEFILE ----
    bad = 0;
    for (t = 0; t < NTILE; t = t + 1)
      if (got[t] !== tm[t]) begin
        bad = bad + 1;
        if (bad <= 8)
          $display("MISMATCH byte%0d (k=%0d co=%0d ci=%0d): dut=%02x exp=%02x",
                   t, t/(NCO*NCI), (t/NCI) % NCO, t % NCI, got[t], tm[t]);
      end

    if (bad == 0) begin
      $display("RESULT: PASS");
      $finish;
    end else begin
      $display("RESULT: FAIL bad=%0d", bad);
      $fatal(1, "WeightStoreTb mismatch");
    end
  end

  // 仿真不收敛时的兜底：超时即判红（非 0 退出），避免闸门挂死。
  initial begin
    #2000000;
    $display("RESULT: FAIL timeout");
    $fatal(1, "WeightStoreTb timeout");
  end

endmodule
