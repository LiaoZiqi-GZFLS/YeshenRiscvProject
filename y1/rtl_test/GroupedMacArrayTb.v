// GroupedMacArray 自检装置 —— 纯 Verilog（不走 SpinalHDL），与 rtl_test/MacArrayTb.v 同构。
// 为什么是 .v：本机整套数值闸门都跑 `iverilog -g2012` + `$readmemh` 向量文件，装置必须同构，
// 闸门才只有一套口径（这是 B3/B4 沿用的装置契约）。
//
// 契约（+= 与 MacArrayTb.v 的差别只有"权重端口名叫 w_tile"这一处）：
//   +XFILE=<file>  每行一个十六进制字节，beat-major：[k][ci] ⇒ 每拍 8 字节
//                  **一拍给全 8 个输入通道**在同一个 (ky,kx) 的像素（阵列是真瓦片，
//                  一拍就能算完一个 (ky,kx) 的分组卷积；旧版的"逐 ci 串行 one-hot"已废）。
//   +WFILE=<file>  每行一个十六进制字节，beat-major：[k][co][ci] ⇒ 每拍 64 字节（权重瓦片）。
//                  **分组信息全在瓦片上**：与 co 同组的槽给真权重，不同组的槽随便给（会被掩成 0）。
//                  闸门故意给组外槽塞 0x7f 毒值 ⇒ 掩码若被架空，Y 立刻错。
//   +YFILE=<file>  每行一个十六进制字节，期望 int32 累加和的**小端字节**：[co][byte] ⇒ 恰好 32 字节
//   +K=<n>         喂几拍，默认 1（3x3 一层 = 9 拍，每拍一个 (ky,kx) 位置）
//   +GROUP=<n>     仅用于日志与合法性自检（不影响向量读取：四个 group 的 X 文件逐字节相同，
//                  W 文件只有掩码不同）
// 时序：clr 一拍清累加器 → 连续 K 拍 en=1 各喂一组 (x, w 瓦片) → 读 8 个 p。
// 输出：
//   一行  "Y <hh> <hh> ..."（32 个字节，[co][byte] 小端）—— 闸门用 grep '^Y ' 收；
//   一行  "RESULT: PASS" / "RESULT: FAIL ..." —— FAIL 时 $fatal 让 vvp 退出非 0。
`timescale 1ns/1ps

module GroupedMacArrayTb;

  localparam NCI = 8;    // 输入通道（= x 的条数）
  localparam NCO = 8;    // 输出通道（= p 的个数）
  localparam NTILE = 64; // 权重瓦片端口容量 = C_OUT*C_IN，每拍 64 字节
  localparam NBEATMAX = 64;

  reg [8*512-1:0] xfile, wfile, yfile;
  reg [7:0] xm [0:NCI*NBEATMAX-1];
  reg [7:0] wm [0:NTILE*NBEATMAX-1];
  reg [7:0] ym [0:NCO*4-1];          // 期望：8 个 int32 的小端字节，32 个

  reg clk = 1'b0;
  reg rst = 1'b1;
  reg en  = 1'b0;
  reg clr = 1'b0;
  reg [7:0] x [0:NCI-1];
  reg [7:0] w [0:NTILE-1];           // 瓦片展平：w[co*NCI + ci] -> 端口 w_tile_co_ci

  wire [31:0] p [0:NCO-1];
  reg  [31:0] got [0:NCO-1];

  always #5 clk = ~clk;

  GroupedMacArray dut (
    .x_0(x[0]), .x_1(x[1]), .x_2(x[2]), .x_3(x[3]),
    .x_4(x[4]), .x_5(x[5]), .x_6(x[6]), .x_7(x[7]),
    .w_tile_0_0(w[0]),  .w_tile_0_1(w[1]),  .w_tile_0_2(w[2]),  .w_tile_0_3(w[3]),
    .w_tile_0_4(w[4]),  .w_tile_0_5(w[5]),  .w_tile_0_6(w[6]),  .w_tile_0_7(w[7]),
    .w_tile_1_0(w[8]),  .w_tile_1_1(w[9]),  .w_tile_1_2(w[10]), .w_tile_1_3(w[11]),
    .w_tile_1_4(w[12]), .w_tile_1_5(w[13]), .w_tile_1_6(w[14]), .w_tile_1_7(w[15]),
    .w_tile_2_0(w[16]), .w_tile_2_1(w[17]), .w_tile_2_2(w[18]), .w_tile_2_3(w[19]),
    .w_tile_2_4(w[20]), .w_tile_2_5(w[21]), .w_tile_2_6(w[22]), .w_tile_2_7(w[23]),
    .w_tile_3_0(w[24]), .w_tile_3_1(w[25]), .w_tile_3_2(w[26]), .w_tile_3_3(w[27]),
    .w_tile_3_4(w[28]), .w_tile_3_5(w[29]), .w_tile_3_6(w[30]), .w_tile_3_7(w[31]),
    .w_tile_4_0(w[32]), .w_tile_4_1(w[33]), .w_tile_4_2(w[34]), .w_tile_4_3(w[35]),
    .w_tile_4_4(w[36]), .w_tile_4_5(w[37]), .w_tile_4_6(w[38]), .w_tile_4_7(w[39]),
    .w_tile_5_0(w[40]), .w_tile_5_1(w[41]), .w_tile_5_2(w[42]), .w_tile_5_3(w[43]),
    .w_tile_5_4(w[44]), .w_tile_5_5(w[45]), .w_tile_5_6(w[46]), .w_tile_5_7(w[47]),
    .w_tile_6_0(w[48]), .w_tile_6_1(w[49]), .w_tile_6_2(w[50]), .w_tile_6_3(w[51]),
    .w_tile_6_4(w[52]), .w_tile_6_5(w[53]), .w_tile_6_6(w[54]), .w_tile_6_7(w[55]),
    .w_tile_7_0(w[56]), .w_tile_7_1(w[57]), .w_tile_7_2(w[58]), .w_tile_7_3(w[59]),
    .w_tile_7_4(w[60]), .w_tile_7_5(w[61]), .w_tile_7_6(w[62]), .w_tile_7_7(w[63]),
    .en(en), .clr(clr),
    .p_0(p[0]), .p_1(p[1]), .p_2(p[2]), .p_3(p[3]),
    .p_4(p[4]), .p_5(p[5]), .p_6(p[6]), .p_7(p[7]),
    .clk(clk), .reset(rst)
  );

  integer k, i, c, co, b, bad, ign, group;

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
    group = 1;
    ign = $value$plusargs("GROUP=%d", group);
    if (group < 1 || NCI % group != 0 || NCO % group != 0) begin
      $display("TB-ERROR: GROUP=%0d 不能整除 %0d/%0d", group, NCI, NCO); $fatal(1, "bad GROUP");
    end
    $display("TB: group=%0d K=%0d（X 向量与 group 无关；W 瓦片=64 字节/拍，组外槽由闸门塞毒值）",
             group, k);

    for (i = 0; i < NCI*NBEATMAX; i = i + 1) xm[i] = 8'h00;
    for (i = 0; i < NTILE*NBEATMAX; i = i + 1) wm[i] = 8'h00;
    for (i = 0; i < NCO*4; i = i + 1) ym[i] = 8'h00;
    $readmemh(xfile, xm);
    $readmemh(wfile, wm);
    $readmemh(yfile, ym);

    for (c = 0; c < NCI; c = c + 1) x[c] = 8'h00;
    for (c = 0; c < NTILE; c = c + 1) w[c] = 8'h00;

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
      for (c = 0; c < NTILE; c = c + 1) w[c] = wm[i*NTILE + c];
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
      $fatal(1, "GroupedMacArrayTb mismatch");
    end
  end

  // 仿真不收敛时的兜底：超时即判红（非 0 退出），避免闸门挂死。
  initial begin
    #200000;
    $display("RESULT: FAIL timeout");
    $fatal(1, "GroupedMacArrayTb timeout");
  end

endmodule
