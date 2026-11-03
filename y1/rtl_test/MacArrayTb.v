// MacArray 阵列级自检装置 —— 纯 Verilog（不走 SpinalHDL）。
// 为什么是 .v：本机整套数值闸门都跑 `iverilog -g2012` + `$readmemh` 向量文件，
// 装置必须与 tools/run_numeric_ab.sh 那个装置（Conv3x3Tb.v）同构，闸门才只有一套口径。
//
// 契约（与 run_numeric_ab.sh 头部注释的装置契约同风格）：
//   +XFILE=<file>  每行一个十六进制字节，beat-major：[k][ci] ⇒ 每拍 8 字节
//   +WFILE=<file>  同上，**[k][co][ci] ⇒ 每拍 64 字节（权重瓦片 w(co)(ci)，64 个互不相同的权重）**
//   +YFILE=<file>  每行一个十六进制字节，期望 int32 累加和的**小端字节**：[co][byte] ⇒ 恰好 32 字节
//   +K=<n>         喂几拍，默认 1
// 时序：clr 一拍清累加器 → 连续 K 拍 en=1 各喂一组 (x, w 瓦片) → 读 8 个 p。
// 输出：
//   一行  "Y <hh> <hh> ..."（32 个字节，[co][byte] 小端）—— 闸门用 grep '^Y ' 收；
//   一行  "RESULT: PASS" / "RESULT: FAIL ..." —— FAIL 时 $fatal 让 vvp 退出非 0。
//
// ★ 为什么 WFILE 是 64 字节/拍（而不是 8）：本阵列的权重接口是**瓦片** w(co)(ci)，
//   p(co) = Σ_ci x(ci)·w(co)(ci) ⇒ 一拍 64 个**各自独立**的有用 MAC。
//   旧的 8 字节/拍（每输出通道一个标量）实现的是 rank-1 外积 p(co) = w(co)·Σ_ci x(ci)，
//   只有 8/64 个乘法器有用 —— tools/run_macarray_ab.sh 的"无死乘法器"判据就是为此加的：
//   它逐个扰动 64 个槽位，要求对应输出 p(co) 必须变（rank-1 下 56 个槽位扰动不了任何东西）。
`timescale 1ns/1ps

module MacArrayTb;

  localparam NCI = 8;   // 输入通道 / p 的个数（本阵列 = 8）
  localparam NCO = 8;   // 输出通道 = 8
  localparam NBEATMAX = 64;

  reg [8*512-1:0] xfile, wfile, yfile;
  reg [7:0] xm [0:NCI*NBEATMAX-1];
  reg [7:0] wm [0:NCO*NCI*NBEATMAX-1];   // 权重瓦片：每拍 64 字节 [k][co][ci]
  reg [7:0] ym [0:NCO*4-1];              // 期望：8 个 int32 的小端字节，32 个

  reg clk = 1'b0;
  reg rst = 1'b1;
  reg en  = 1'b0;
  reg clr = 1'b0;
  reg [7:0] x [0:NCI-1];
  reg [7:0] w [0:NCO*NCI-1];             // 瓦片展平：w[co*NCI + ci] -> 端口 w_co_ci

  wire [31:0] p [0:NCO-1];
  reg  [31:0] got [0:NCO-1];

  always #5 clk = ~clk;

  MacArray dut (
    .x_0(x[0]), .x_1(x[1]), .x_2(x[2]), .x_3(x[3]),
    .x_4(x[4]), .x_5(x[5]), .x_6(x[6]), .x_7(x[7]),
    .w_0_0(w[0]),   .w_0_1(w[1]),   .w_0_2(w[2]),   .w_0_3(w[3]),
    .w_0_4(w[4]),   .w_0_5(w[5]),   .w_0_6(w[6]),   .w_0_7(w[7]),
    .w_1_0(w[8]),   .w_1_1(w[9]),   .w_1_2(w[10]),  .w_1_3(w[11]),
    .w_1_4(w[12]),  .w_1_5(w[13]),  .w_1_6(w[14]),  .w_1_7(w[15]),
    .w_2_0(w[16]),  .w_2_1(w[17]),  .w_2_2(w[18]),  .w_2_3(w[19]),
    .w_2_4(w[20]),  .w_2_5(w[21]),  .w_2_6(w[22]),  .w_2_7(w[23]),
    .w_3_0(w[24]),  .w_3_1(w[25]),  .w_3_2(w[26]),  .w_3_3(w[27]),
    .w_3_4(w[28]),  .w_3_5(w[29]),  .w_3_6(w[30]),  .w_3_7(w[31]),
    .w_4_0(w[32]),  .w_4_1(w[33]),  .w_4_2(w[34]),  .w_4_3(w[35]),
    .w_4_4(w[36]),  .w_4_5(w[37]),  .w_4_6(w[38]),  .w_4_7(w[39]),
    .w_5_0(w[40]),  .w_5_1(w[41]),  .w_5_2(w[42]),  .w_5_3(w[43]),
    .w_5_4(w[44]),  .w_5_5(w[45]),  .w_5_6(w[46]),  .w_5_7(w[47]),
    .w_6_0(w[48]),  .w_6_1(w[49]),  .w_6_2(w[50]),  .w_6_3(w[51]),
    .w_6_4(w[52]),  .w_6_5(w[53]),  .w_6_6(w[54]),  .w_6_7(w[55]),
    .w_7_0(w[56]),  .w_7_1(w[57]),  .w_7_2(w[58]),  .w_7_3(w[59]),
    .w_7_4(w[60]),  .w_7_5(w[61]),  .w_7_6(w[62]),  .w_7_7(w[63]),
    .en(en), .clr(clr),
    .p_0(p[0]), .p_1(p[1]), .p_2(p[2]), .p_3(p[3]),
    .p_4(p[4]), .p_5(p[5]), .p_6(p[6]), .p_7(p[7]),
    .clk(clk), .reset(rst)
  );

  integer k, i, c, co, b, bad, ign;

  initial begin
    // ---- 取参数 ----
    if (!$value$plusargs("XFILE=%s", xfile)) begin
      $display("TB-ERROR: 缺 +XFILE="); $fatal(1, "missing XFILE");
    end
    if (!$value$plusargs("WFILE=%s", wfile)) begin
      $display("TB-ERROR: 缺 +WFILE="); $fatal(1, "missing WFILE");
    end
    if (!$value$plusargs("YFILE=%s", yfile)) begin
      $display("TB-ERROR: 缺 +YFILE="); $fatal(1, "missing YFILE");
    end
    k = 1;
    ign = $value$plusargs("K=%d", k);
    if (k < 1 || k > NBEATMAX) begin
      $display("TB-ERROR: K=%0d 越界 [1,%0d]", k, NBEATMAX); $fatal(1, "bad K");
    end

    for (i = 0; i < NCI*NBEATMAX; i = i + 1) xm[i] = 8'h00;
    for (i = 0; i < NCO*NCI*NBEATMAX; i = i + 1) wm[i] = 8'h00;
    for (i = 0; i < NCO*4; i = i + 1) ym[i] = 8'h00;
    $readmemh(xfile, xm);
    $readmemh(wfile, wm);
    $readmemh(yfile, ym);

    for (c = 0; c < NCI; c = c + 1) x[c] = 8'h00;
    for (c = 0; c < NCO*NCI; c = c + 1) w[c] = 8'h00;

    // ---- 复位 + 清零 ----
    repeat (3) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);
    clr = 1'b1;
    @(negedge clk);
    clr = 1'b0;

    // ---- 喂 K 拍：第 i 拍用 xm 的第 i 组 8 字节、wm 的第 i 组 64 字节（瓦片）----
    for (i = 0; i < k; i = i + 1) begin
      for (c = 0; c < NCI; c = c + 1) x[c] = xm[i*NCI + c];
      for (c = 0; c < NCO*NCI; c = c + 1) w[c] = wm[i*NCO*NCI + c];
      en = 1'b1;
      @(negedge clk);
    end
    en = 1'b0;
    @(negedge clk);   // 此时累加器已定，且 en=0，p 稳定

    for (co = 0; co < NCO; co = co + 1) got[co] = p[co];

    // ---- 打印 DUT 的原始 int32 累加和（小端字节），闸门按这行逐字节对账 ----
    $write("Y");
    for (co = 0; co < NCO; co = co + 1)
      for (b = 0; b < 4; b = b + 1)
        $write(" %02x", got[co][8*b +: 8]);
    $write("\n");

    // ---- 自检：DUT 的字节 vs YFILE ----
    bad = 0;
    for (co = 0; co < NCO; co = co + 1)
      for (b = 0; b < 4; b = b + 1)
        if (got[co][8*b +: 8] !== ym[co*4 + b]) begin
          bad = bad + 1;
          $display("MISMATCH p_%0d byte%0d: dut=%02x exp=%02x",
                   co, b, got[co][8*b +: 8], ym[co*4 + b]);
        end

    if (bad == 0) begin
      $display("RESULT: PASS");
      $finish;
    end else begin
      $display("RESULT: FAIL bad=%0d", bad);
      $fatal(1, "MacArrayTb mismatch");
    end
  end

  // 仿真不收敛时的兜底：超时即判红（非 0 退出），避免闸门挂死。
  initial begin
    #200000;
    $display("RESULT: FAIL timeout");
    $fatal(1, "MacArrayTb timeout");
  end

endmodule
