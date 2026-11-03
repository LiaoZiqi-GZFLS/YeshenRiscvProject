// DdrReadTb.v —— y1 AXI 主口（gen/DdrMaster.v）**读相位**的装置，纯 Verilog（iverilog -g2012）。
//
// ★ 契约变化（C2.1c）：主口现在**没有**"纯读"这个操作了 —— 一次 `start` 恒等于"把 src 上的
//   len 字节块拷到 dst"（每块 128 B：先整块读进块缓冲、再把该块整块写出去）。所以本装置
//   如实驱动**一笔完整拷贝**（+SRC/+DST/+LEN 三个都要），而它盯的仍然是**读相位**的证据：
//     · 每块读回块缓冲的 128 个字节（`RDBLK`）是否逐字节等于内存里那一段；
//     · AR 的地址序列（是否恰好 +128 递进）与每笔 arlen 是否恒 15。
//   原先那句"写半边一个字都不动"（`WRIDLE_OK`）在新契约下**不再成立**（拷贝必然要写），
//   已替换为**等价强度的新判据**：**读写不重叠** ——
//     · `RDWR_OVERLAP`：同一拍同时举 R 与 W 数据 ⇒ 必须 0；
//     · `ARAW_OVERLAP`：同一拍同时举 AR 与 AW ⇒ 必须 0；
//     · `AW_LEAD_MAX` ：累计 AW 数任何时刻不得超过累计 AR 数（写相位绝不领先读相位）⇒ 必须 0。
//   这三条管的是同一件事（读相位与写相位在时间上被切开），而且比"写半边从不举手"更贴近桥的
//   真实约束（`DDR3Bridge` 的 `wrState`/`rdState` 互斥）。
//
// 契约（与 tools/run_ddrread_ab.sh 头部注释逐字一致）：
//   +SRC=<dec>        源地址（十进制字节地址）。**装置不校验对齐** —— 故意让非对齐地址也能喂进来，
//                     由 DUT 自己去发现并报 err（负对照要的正是这个行为）。
//   +DST=<dec>       目标地址（新契约要求；装置同样不校验）。
//   +LEN=<dec>        传输字节数（十进制）。装置同样不校验"128 的整数倍"。
//   +MEMFILE=<file>   转给 AxiMemModel 的预载文件（$readmemh 一行一个字节）—— 模型自己取这个 plusarg。
//   +DUMPFILE=<file>  转给 AxiMemModel 的导出文件（仿真结束时写回）—— 模型自己取这个 plusarg。
//   +EXPECT_ERR       可选：断言"本次必须报 err"，用于负对照。给了它，装置把"报 err"当 PASS。
//
// 装置做的事：
//   1) 复位后给 start 一拍脉冲，等 done 或 err（带拍数超时 ⇒ 握手挂死也报红，不静默挂住）；
//   2) 块缓冲是"每块被覆盖一次"的：装置在**每块最后一拍落下后的半拍**（negedge）看见
//      rd_bytes 走到 128 的整数倍，就把当拍的块缓冲整块抓下来，打印一行
//      `RDBLK <hh> <hh> ...`（128 个十六进制字节，地址升序）——每块一行，闸门按行拼接后对账；
//   3) 收尾打印 `CHUNKS=<n>`、`BURSTS=<n>`、`CYC=<n> RD_BYTES=<n> WR_BYTES=<n> ERR=<b>` 与
//      `RDWR_OVERLAP=`/`ARAW_OVERLAP=`/`AW_LEAD_MAX=`，最后 `RESULT: PASS|FAIL`，
//      FAIL 时 $fatal ⇒ vvp 非 0 退出。
//
// ★ 与 rtl_test/HostRegsTb.v 同口径：驱动在 negedge、握手判据在 posedge 采样，避免同沿竞争。
`timescale 1ns/1ps

module DdrReadTb;

  localparam integer TIMEOUT = 20000;   // 等 done/err 的最长时钟拍数
  localparam integer CHUNK   = 128;     // 块缓冲字节数（= 一笔突发 16 拍 x 8B）

  reg clk   = 1'b0;
  reg reset = 1'b1;
  always #5 clk = ~clk;

  // ---- DUT 控制 / 状态 ----
  reg         start;
  reg  [27:0] src, dst;
  reg  [31:0] length;
  wire        busy, done, err;
  wire [31:0] cyc, rd_bytes, wr_bytes;
  wire [7:0]  buf_dout [0:127];

  // ---- AXI 连线（DUT 主口 <-> AxiMemModel 从口；一根线两端）----
  wire        axi_aw_valid, axi_aw_ready;
  wire [27:0] axi_aw_payload_addr;
  wire [3:0]  axi_aw_payload_id;
  wire [7:0]  axi_aw_payload_len;
  wire [2:0]  axi_aw_payload_size;
  wire [1:0]  axi_aw_payload_burst;
  wire [3:0]  axi_aw_payload_cache;
  wire [2:0]  axi_aw_payload_prot;

  wire        axi_w_valid, axi_w_ready;
  wire [63:0] axi_w_payload_data;
  wire [7:0]  axi_w_payload_strb;
  wire        axi_w_payload_last;

  wire        axi_b_valid, axi_b_ready;
  wire [3:0]  axi_b_payload_id;
  wire [1:0]  axi_b_payload_resp;

  wire        axi_ar_valid, axi_ar_ready;
  wire [27:0] axi_ar_payload_addr;
  wire [3:0]  axi_ar_payload_id;
  wire [7:0]  axi_ar_payload_len;
  wire [2:0]  axi_ar_payload_size;
  wire [1:0]  axi_ar_payload_burst;
  wire [3:0]  axi_ar_payload_cache;
  wire [2:0]  axi_ar_payload_prot;

  wire        axi_r_valid, axi_r_ready;
  wire [63:0] axi_r_payload_data;
  wire [3:0]  axi_r_payload_id;
  wire [1:0]  axi_r_payload_resp;
  wire        axi_r_payload_last;

  // ---- 被测主口 ----
  DdrMaster dut (
    .start(start), .src(src), .dst(dst), .len(length),
    .sg_valid(1'b0), .sg_flush(1'b0), .sg_addr(28'd0), .sg_beatsM1(4'd0),
        .busy(busy), .done(done), .err(err), .cyc(cyc),
    .rd_bytes(rd_bytes), .wr_bytes(wr_bytes),
    .buf_dout_0(buf_dout[0]),     .buf_dout_1(buf_dout[1]),     .buf_dout_2(buf_dout[2]),     .buf_dout_3(buf_dout[3]),
    .buf_dout_4(buf_dout[4]),     .buf_dout_5(buf_dout[5]),     .buf_dout_6(buf_dout[6]),     .buf_dout_7(buf_dout[7]),
    .buf_dout_8(buf_dout[8]),     .buf_dout_9(buf_dout[9]),     .buf_dout_10(buf_dout[10]),   .buf_dout_11(buf_dout[11]),
    .buf_dout_12(buf_dout[12]),   .buf_dout_13(buf_dout[13]),   .buf_dout_14(buf_dout[14]),   .buf_dout_15(buf_dout[15]),
    .buf_dout_16(buf_dout[16]),   .buf_dout_17(buf_dout[17]),   .buf_dout_18(buf_dout[18]),   .buf_dout_19(buf_dout[19]),
    .buf_dout_20(buf_dout[20]),   .buf_dout_21(buf_dout[21]),   .buf_dout_22(buf_dout[22]),   .buf_dout_23(buf_dout[23]),
    .buf_dout_24(buf_dout[24]),   .buf_dout_25(buf_dout[25]),   .buf_dout_26(buf_dout[26]),   .buf_dout_27(buf_dout[27]),
    .buf_dout_28(buf_dout[28]),   .buf_dout_29(buf_dout[29]),   .buf_dout_30(buf_dout[30]),   .buf_dout_31(buf_dout[31]),
    .buf_dout_32(buf_dout[32]),   .buf_dout_33(buf_dout[33]),   .buf_dout_34(buf_dout[34]),   .buf_dout_35(buf_dout[35]),
    .buf_dout_36(buf_dout[36]),   .buf_dout_37(buf_dout[37]),   .buf_dout_38(buf_dout[38]),   .buf_dout_39(buf_dout[39]),
    .buf_dout_40(buf_dout[40]),   .buf_dout_41(buf_dout[41]),   .buf_dout_42(buf_dout[42]),   .buf_dout_43(buf_dout[43]),
    .buf_dout_44(buf_dout[44]),   .buf_dout_45(buf_dout[45]),   .buf_dout_46(buf_dout[46]),   .buf_dout_47(buf_dout[47]),
    .buf_dout_48(buf_dout[48]),   .buf_dout_49(buf_dout[49]),   .buf_dout_50(buf_dout[50]),   .buf_dout_51(buf_dout[51]),
    .buf_dout_52(buf_dout[52]),   .buf_dout_53(buf_dout[53]),   .buf_dout_54(buf_dout[54]),   .buf_dout_55(buf_dout[55]),
    .buf_dout_56(buf_dout[56]),   .buf_dout_57(buf_dout[57]),   .buf_dout_58(buf_dout[58]),   .buf_dout_59(buf_dout[59]),
    .buf_dout_60(buf_dout[60]),   .buf_dout_61(buf_dout[61]),   .buf_dout_62(buf_dout[62]),   .buf_dout_63(buf_dout[63]),
    .buf_dout_64(buf_dout[64]),   .buf_dout_65(buf_dout[65]),   .buf_dout_66(buf_dout[66]),   .buf_dout_67(buf_dout[67]),
    .buf_dout_68(buf_dout[68]),   .buf_dout_69(buf_dout[69]),   .buf_dout_70(buf_dout[70]),   .buf_dout_71(buf_dout[71]),
    .buf_dout_72(buf_dout[72]),   .buf_dout_73(buf_dout[73]),   .buf_dout_74(buf_dout[74]),   .buf_dout_75(buf_dout[75]),
    .buf_dout_76(buf_dout[76]),   .buf_dout_77(buf_dout[77]),   .buf_dout_78(buf_dout[78]),   .buf_dout_79(buf_dout[79]),
    .buf_dout_80(buf_dout[80]),   .buf_dout_81(buf_dout[81]),   .buf_dout_82(buf_dout[82]),   .buf_dout_83(buf_dout[83]),
    .buf_dout_84(buf_dout[84]),   .buf_dout_85(buf_dout[85]),   .buf_dout_86(buf_dout[86]),   .buf_dout_87(buf_dout[87]),
    .buf_dout_88(buf_dout[88]),   .buf_dout_89(buf_dout[89]),   .buf_dout_90(buf_dout[90]),   .buf_dout_91(buf_dout[91]),
    .buf_dout_92(buf_dout[92]),   .buf_dout_93(buf_dout[93]),   .buf_dout_94(buf_dout[94]),   .buf_dout_95(buf_dout[95]),
    .buf_dout_96(buf_dout[96]),   .buf_dout_97(buf_dout[97]),   .buf_dout_98(buf_dout[98]),   .buf_dout_99(buf_dout[99]),
    .buf_dout_100(buf_dout[100]), .buf_dout_101(buf_dout[101]), .buf_dout_102(buf_dout[102]), .buf_dout_103(buf_dout[103]),
    .buf_dout_104(buf_dout[104]), .buf_dout_105(buf_dout[105]), .buf_dout_106(buf_dout[106]), .buf_dout_107(buf_dout[107]),
    .buf_dout_108(buf_dout[108]), .buf_dout_109(buf_dout[109]), .buf_dout_110(buf_dout[110]), .buf_dout_111(buf_dout[111]),
    .buf_dout_112(buf_dout[112]), .buf_dout_113(buf_dout[113]), .buf_dout_114(buf_dout[114]), .buf_dout_115(buf_dout[115]),
    .buf_dout_116(buf_dout[116]), .buf_dout_117(buf_dout[117]), .buf_dout_118(buf_dout[118]), .buf_dout_119(buf_dout[119]),
    .buf_dout_120(buf_dout[120]), .buf_dout_121(buf_dout[121]), .buf_dout_122(buf_dout[122]), .buf_dout_123(buf_dout[123]),
    .buf_dout_124(buf_dout[124]), .buf_dout_125(buf_dout[125]), .buf_dout_126(buf_dout[126]), .buf_dout_127(buf_dout[127]),

    .axi_aw_valid(axi_aw_valid), .axi_aw_ready(axi_aw_ready),
    .axi_aw_payload_addr(axi_aw_payload_addr), .axi_aw_payload_id(axi_aw_payload_id),
    .axi_aw_payload_len(axi_aw_payload_len), .axi_aw_payload_size(axi_aw_payload_size),
    .axi_aw_payload_burst(axi_aw_payload_burst), .axi_aw_payload_cache(axi_aw_payload_cache),
    .axi_aw_payload_prot(axi_aw_payload_prot),
    .axi_w_valid(axi_w_valid), .axi_w_ready(axi_w_ready),
    .axi_w_payload_data(axi_w_payload_data), .axi_w_payload_strb(axi_w_payload_strb),
    .axi_w_payload_last(axi_w_payload_last),
    .axi_b_valid(axi_b_valid), .axi_b_ready(axi_b_ready),
    .axi_b_payload_id(axi_b_payload_id), .axi_b_payload_resp(axi_b_payload_resp),
    .axi_ar_valid(axi_ar_valid), .axi_ar_ready(axi_ar_ready),
    .axi_ar_payload_addr(axi_ar_payload_addr), .axi_ar_payload_id(axi_ar_payload_id),
    .axi_ar_payload_len(axi_ar_payload_len), .axi_ar_payload_size(axi_ar_payload_size),
    .axi_ar_payload_burst(axi_ar_payload_burst), .axi_ar_payload_cache(axi_ar_payload_cache),
    .axi_ar_payload_prot(axi_ar_payload_prot),
    .axi_r_valid(axi_r_valid), .axi_r_ready(axi_r_ready),
    .axi_r_payload_data(axi_r_payload_data), .axi_r_payload_id(axi_r_payload_id),
    .axi_r_payload_resp(axi_r_payload_resp), .axi_r_payload_last(axi_r_payload_last),
    .clk(clk), .reset(reset),
    .wstrb(8'hFF)   // T-S2b: 写字节掩码（旧装置恒全字节有效）
  );

  // ---- 内存模型（预载/导出/统计都在模型里，plusarg 由它自己取）----
  AxiMemModel #(.MEMSZ(8192), .ADDR_W(28)) mem0 (
    .clk(clk), .reset(reset),
    .axi_aw_valid(axi_aw_valid), .axi_aw_ready(axi_aw_ready),
    .axi_aw_payload_addr(axi_aw_payload_addr), .axi_aw_payload_id(axi_aw_payload_id),
    .axi_aw_payload_len(axi_aw_payload_len), .axi_aw_payload_size(axi_aw_payload_size),
    .axi_aw_payload_burst(axi_aw_payload_burst), .axi_aw_payload_cache(axi_aw_payload_cache),
    .axi_aw_payload_prot(axi_aw_payload_prot),
    .axi_w_valid(axi_w_valid), .axi_w_ready(axi_w_ready),
    .axi_w_payload_data(axi_w_payload_data), .axi_w_payload_strb(axi_w_payload_strb),
    .axi_w_payload_last(axi_w_payload_last),
    .axi_b_valid(axi_b_valid), .axi_b_ready(axi_b_ready),
    .axi_b_payload_id(axi_b_payload_id), .axi_b_payload_resp(axi_b_payload_resp),
    .axi_ar_valid(axi_ar_valid), .axi_ar_ready(axi_ar_ready),
    .axi_ar_payload_addr(axi_ar_payload_addr), .axi_ar_payload_id(axi_ar_payload_id),
    .axi_ar_payload_len(axi_ar_payload_len), .axi_ar_payload_size(axi_ar_payload_size),
    .axi_ar_payload_burst(axi_ar_payload_burst), .axi_ar_payload_cache(axi_ar_payload_cache),
    .axi_ar_payload_prot(axi_ar_payload_prot),
    .axi_r_valid(axi_r_valid), .axi_r_ready(axi_r_ready),
    .axi_r_payload_data(axi_r_payload_data), .axi_r_payload_id(axi_r_payload_id),
    .axi_r_payload_resp(axi_r_payload_resp), .axi_r_payload_last(axi_r_payload_last)
  );

  // ---- 状态 ----
  integer    tbfail;
  integer    nchunk;
  integer    nburst;
  integer    nburst_w;
  integer    timeout_cnt;
  integer    mk;
  integer    rdwr_overlap, araw_overlap, aw_lead_max, aw_lead;
  reg [31:0] prev_rd, cur_rd;
  reg [27:0] src_v, dst_v;
  reg [31:0] len_v;
  reg        expect_err;
  reg        done_seen, err_seen;

  task fail_timeout;
    input [8*64-1:0] why;
    begin
      $display("RESULT: FAIL timeout %0s", why);
      $fatal(1, "DdrReadTb timeout");
    end
  endtask

  // ---- 每笔 AR 打一行：地址 + arlen；每笔 AW 只计数（本装置的判据是"读侧"，但读写不重叠要 AW 数）----
  // 为什么必须有这条：预载模式 `byte[i] = (i*131+7)&0xFF` 的周期是 256 B，而块是 128 B ⇒
  // **第 k 块与第 k+2 块逐字节相同**。于是"只读前两块、后面重复读前两块"这种地址递进错误
  // 会恰好躲过 RDBLK 的字节对账。把 AR 的地址序列（与 arlen）单独打出来，闸门就能对
  // "地址确实按 +128 递进"和"每笔 arlen 都是 15"做**运行期**断言（P3 的静态检查在 gen 上另有其一）。
  always @(posedge clk) begin
    if (!reset && axi_ar_valid && axi_ar_ready) begin
      $display("ARB %08x arlen=%0d", axi_ar_payload_addr, axi_ar_payload_len);
      nburst = nburst + 1;
    end
    if (!reset && axi_aw_valid && axi_aw_ready) begin
      nburst_w = nburst_w + 1;
      aw_lead  = nburst_w - nburst;
      if (aw_lead > aw_lead_max) aw_lead_max = aw_lead;   // 写相位绝不领先读相位
    end
    if (!reset && (axi_ar_valid && axi_ar_ready) && (axi_aw_valid && axi_aw_ready)) araw_overlap = araw_overlap + 1;
    if (!reset && (axi_r_valid && axi_r_ready) && (axi_w_valid && axi_w_ready)) rdwr_overlap = rdwr_overlap + 1;
  end

  // ---- 块抓取：rd_bytes 每拍 +8；走到 128 的整数倍 = 刚才那一块 16 拍已全部落进缓冲 ----
  // 此刻取 buf_dout 是安全的：主口要到至少 1 拍之后才可能写下一块（NEXT -> AR -> 模型 1 拍读延迟）。
  always @(negedge clk) begin
    if (!reset) begin
      cur_rd = rd_bytes;
      if (cur_rd != prev_rd && cur_rd != 32'd0 && (cur_rd % CHUNK) == 0) begin
        $write("RDBLK");
        for (mk = 0; mk < CHUNK; mk = mk + 1) $write(" %02x", buf_dout[mk]);
        $write("\n");
        nchunk = nchunk + 1;
      end
      prev_rd = cur_rd;
    end
  end

  initial begin
    start = 1'b0; src = 28'd0; dst = 28'd0; length = 32'd0;
    tbfail = 0; nchunk = 0; nburst = 0; nburst_w = 0; timeout_cnt = 0; prev_rd = 32'd0;
    rdwr_overlap = 0; araw_overlap = 0; aw_lead_max = 0; aw_lead = 0;
    expect_err = 1'b0; done_seen = 1'b0; err_seen = 1'b0;

    if (!$value$plusargs("SRC=%d", src_v)) begin
      $display("TB-ERROR: missing +SRC="); $fatal(1, "missing SRC");
    end
    if (!$value$plusargs("DST=%d", dst_v)) begin
      $display("TB-ERROR: missing +DST="); $fatal(1, "missing DST");
    end
    if (!$value$plusargs("LEN=%d", len_v)) begin
      $display("TB-ERROR: missing +LEN="); $fatal(1, "missing LEN");
    end
    if ($test$plusargs("EXPECT_ERR")) expect_err = 1'b1;

    src    = src_v[27:0];
    dst    = dst_v[27:0];
    length = len_v;
    $display("TB SRC=%0d DST=%0d LEN=%0d EXPECT_ERR=%0d", src, dst, length, expect_err);

    // 复位（同步、高有效；片上口径）
    repeat (4) @(negedge clk);
    reset = 1'b0;
    @(negedge clk);

    // start 一拍脉冲
    @(negedge clk); start = 1'b1;
    @(negedge clk); start = 1'b0;

    // 等 done 或 err，带超时
    while (!done_seen && !err_seen) begin
      @(posedge clk);
      if (done)      done_seen = 1'b1;
      else if (err)  err_seen  = 1'b1;
      else begin
        timeout_cnt = timeout_cnt + 1;
        if (timeout_cnt > TIMEOUT) fail_timeout("done/err");
      end
    end

    // 再走两拍，让块抓取监视器把最后一块打完（最后一块在 done 之前就落好了）
    repeat (2) @(negedge clk);

    // ---- 读写不重叠（替代旧的 "WRIDLE_OK"：拷贝必然要写，所以判据从"写半边不举手"
    //      收紧/换成"读相位与写相位在时间上被切开" —— 见文件头）----
    if (rdwr_overlap != 0) begin tbfail = tbfail + 1; $display("TBFAIL: R 与 W 同一拍（读写重叠）"); end
    if (araw_overlap != 0) begin tbfail = tbfail + 1; $display("TBFAIL: AR 与 AW 同一拍"); end
    if (aw_lead_max > 0)   begin tbfail = tbfail + 1; $display("TBFAIL: AW 领先 AR max=%0d", aw_lead_max); end
    if (tbfail == 0) $display("RDWR_EXCL_OK");

    $display("CHUNKS=%0d", nchunk);
    $display("BURSTS=%0d", nburst);
    $display("WR_BURSTS=%0d", nburst_w);
    $display("RDWR_OVERLAP=%0d ARAW_OVERLAP=%0d AW_LEAD_MAX=%0d", rdwr_overlap, araw_overlap, aw_lead_max);
    $display("CYC=%0d RD_BYTES=%0d WR_BYTES=%0d ERR=%0d", cyc, rd_bytes, wr_bytes, err_seen);
    $display("DONE_SEEN=%0d", done_seen);

    if (expect_err) begin
      if (err_seen && !done_seen) begin
        $display("RESULT: PASS");
        $finish;
      end else begin
        $display("RESULT: FAIL 期待 err，实际 done=%0d err=%0d", done_seen, err_seen);
        $fatal(1, "DdrReadTb expected err");
      end
    end else begin
      if (done_seen && !err_seen && tbfail == 0) begin
        $display("RESULT: PASS");
        $finish;
      end else begin
        $display("RESULT: FAIL done=%0d err=%0d tbfail=%0d", done_seen, err_seen, tbfail);
        $fatal(1, "DdrReadTb failed");
      end
    end
  end

  // 兜底：仿真不收敛时也报红退出，别让闸门挂死。
  initial begin
    #20000000;
    $display("RESULT: FAIL timeout(global)");
    $fatal(1, "DdrReadTb global timeout");
  end

endmodule
