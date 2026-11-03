// DdrCopyTb.v —— y1 AXI **块拷贝**主口（gen/DdrMaster.v）的装置，纯 Verilog（iverilog -g2012）。
//
// 契约（与 rtl/DdrMaster.scala 头部的"一次 start 恒等于块拷贝"逐字一致）：
//   +SRC=<dec> +DST=<dec>     源 / 目标字节地址。**装置不替 DUT 校验对齐** —— 故意让非对齐地址
//                             也能喂进来，由 DUT 自己去发现并报 err（负对照要的正是这个行为）。
//   +LEN=<dec>                字节数。同上，装置不替 DUT 校验"128 的整数倍"。
//   +MEMFILE=<file>           转给 AxiMemModel 的预载文件（$readmemh 一行一个字节）—— 模型自己取。
//   +DUMPFILE=<file>          转给 AxiMemModel 的导出文件（仿真结束时写回）—— 模型自己取。
//   +EXPECT_ERR               可选：断言"本次必须报 err"，用于负对照。给了它，装置把"报 err"当 PASS。
//
// 装置做的事（全部走 DUT 的**真端口**，不 force、不 poke 内部寄存器）：
//   1) 复位后给 start 一拍脉冲，等 done 或 err（带**拍数超时** + **全局看门狗** ⇒ 挂死也报红，
//      绝不静默挂住）；
//   2) 逐笔打印读/写地址与突发长度：`ARB <addr> arlen=<n>` / `AWB <addr> awlen=<n>`
//      —— 地址序列（是否恰好 +128 递进）与突发长度的**运行期**断言由闸门（Python）做；
//      装置只给事实，不自己下"对/错"的结论（口径与 DdrReadTb/DdrWriteTb 相同）。
//   3) 结构性断言"**读写不重叠**"（本契约的硬条款，桥的 wrState/rdState 互斥）：
//        · `RDWR_OVERLAP`：同一拍同时举 R 与 W 数据 ⇒ 必须 0；
//        · `ARAW_OVERLAP`：同一拍同时举 AR 与 AW ⇒ 必须 0；
//        · `AW_LEAD_MAX` ：累计 AW 数任何时刻都不得超过累计 AR 数（= 写相位绝不领先读相位）⇒ 必须 0；
//        · `WLAST_BAD`   ：每笔写突发的第 16 拍必须 wlast=1、其余拍 0 ⇒ 必须 0。
//   4) 收尾打印 `CHUNKS`/`AR_BURSTS`/`AW_BURSTS`/`B_OK`/`RD_BEATS`/`WR_BEATS` 与**唯一的一行**
//      `CYC=<n> RD_BYTES=<n> WR_BYTES=<n> ERR=<b>`（闸门据此算 J2 的主口开销），最后
//      `RESULT: PASS|FAIL`，FAIL 时 $fatal ⇒ vvp 非 0 退出。
//
// ★ 与 rtl_test/DdrReadTb.v / DdrWriteTb.v 同口径：驱动在 negedge、握手判据在 posedge 采样，
//   避免同沿竞争。
`timescale 1ns/1ps

module DdrCopyTb;

  localparam integer TIMEOUT = 500000;    // 等 done/err 的最长时钟拍数（1 MiB 拷贝 ≈ 303k 拍）
  localparam integer WD_MAX  = 3000000;   // 全局看门狗（拍）
  localparam integer CHUNK   = 128;       // 块缓冲字节数（= 一笔突发 16 拍 x 8B）
  localparam integer BEATS   = 16;        // 一块 = 16 拍

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
  AxiMemModel #(.MEMSZ(2621440), .ADDR_W(28)) mem0 (
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
  integer    timeout_cnt;
  integer    ar_bursts, aw_bursts, b_ok, rd_beats, wr_beats;
  integer    rdwr_overlap, araw_overlap, aw_lead_max;
  integer    aw_lead, wbeats_cur, wlast_bad;
  reg [31:0] prev_rd, cur_rd;
  reg [27:0] src_v, dst_v;
  reg [31:0] len_v;
  reg        expect_err;
  reg        done_seen, err_seen;

  // ---- AR/AW 观察器：地址序列 + 突发长度 + 响应数 + 结构不变量（运行期断言）----
  always @(posedge clk) begin
    if (!reset) begin
      if (axi_ar_valid && axi_ar_ready) begin
        $display("ARB %08x arlen=%0d", axi_ar_payload_addr, axi_ar_payload_len);
        ar_bursts = ar_bursts + 1;
      end
      if (axi_aw_valid && axi_aw_ready) begin
        $display("AWB %08x awlen=%0d", axi_aw_payload_addr, axi_aw_payload_len);
        aw_bursts = aw_bursts + 1;
        aw_lead   = aw_bursts - ar_bursts;          // 累计 AW - 累计 AR：拷贝里必须恒 <= 0
        if (aw_lead > aw_lead_max) aw_lead_max = aw_lead;
      end
      if (axi_b_valid && axi_b_ready) begin
        $display("BOK %08x", axi_aw_payload_addr);
        b_ok = b_ok + 1;
        if (wbeats_cur != BEATS) begin
          $display("TBFAIL: 一笔写突发只发了 %0d 拍（期望 %0d）", wbeats_cur, BEATS);
          tbfail = tbfail + 1;
        end
        wbeats_cur = 0;
      end
      if (axi_r_valid && axi_r_ready) rd_beats = rd_beats + 1;
      if (axi_w_valid && axi_w_ready) begin
        wr_beats   = wr_beats + 1;
        wbeats_cur = wbeats_cur + 1;
        if (axi_w_payload_last !== (wbeats_cur == BEATS)) begin
          $display("TBFAIL: wlast 与块内拍号不符 beat=%0d last=%0d", wbeats_cur, axi_w_payload_last);
          wlast_bad = wlast_bad + 1;
        end
      end
      // 读写不重叠（本契约的硬条款）
      if ((axi_ar_valid && axi_ar_ready) && (axi_aw_valid && axi_aw_ready)) araw_overlap = araw_overlap + 1;
      if ((axi_r_valid  && axi_r_ready)  && (axi_w_valid  && axi_w_ready))  rdwr_overlap = rdwr_overlap + 1;
    end
  end

  // ---- 块缓冲抓取（rd_bytes 每拍 +8；走到 128 的整数倍 = 刚才那一块 16 拍已全部落进缓冲）----
  // 本装置不打印 RDBLK（读侧逐块对账归 DdrReadTb 管）；这里保留一个计数，用于交叉对账
  // "块缓冲被恰好覆盖 len/128 次"，防的是"多读/漏读一块"这类只在块粒度上看得见的缺陷。
  integer nchunk;
  always @(negedge clk) begin
    if (!reset) begin
      cur_rd = rd_bytes;
      if (cur_rd != prev_rd && cur_rd != 32'd0 && (cur_rd % CHUNK) == 0) nchunk = nchunk + 1;
      prev_rd = cur_rd;
    end
  end

  // ---- 等 done 或 err，带超时 ----
  task wait_op;
    begin
      while (!done_seen && !err_seen) begin
        @(posedge clk);
        if (done)      done_seen = 1'b1;
        else if (err)  err_seen  = 1'b1;
        else begin
          timeout_cnt = timeout_cnt + 1;
          if (timeout_cnt > TIMEOUT) begin
            $display("RESULT: FAIL timeout");
            $fatal(1, "DdrCopyTb timeout");
          end
        end
      end
    end
  endtask

  initial begin
    start = 1'b0; src = 28'd0; dst = 28'd0; length = 32'd0;
    tbfail = 0; timeout_cnt = 0; nchunk = 0;
    ar_bursts = 0; aw_bursts = 0; b_ok = 0; rd_beats = 0; wr_beats = 0;
    rdwr_overlap = 0; araw_overlap = 0; aw_lead_max = 0; aw_lead = 0;
    wbeats_cur = 0; wlast_bad = 0;
    prev_rd = 32'd0; done_seen = 1'b0; err_seen = 1'b0; expect_err = 1'b0;

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
    $display("TB COPY SRC=%0d DST=%0d LEN=%0d EXPECT_ERR=%0d", src, dst, length, expect_err);

    // 复位（同步、高有效；片上口径）
    repeat (4) @(negedge clk);
    reset = 1'b0;
    @(negedge clk);

    // start 一拍脉冲
    @(negedge clk); start = 1'b1;
    @(negedge clk); start = 1'b0;

    wait_op;
    repeat (2) @(negedge clk);   // 让监视器收尾

    // ---- 结构不变量 ----
    if (rdwr_overlap != 0) begin tbfail = tbfail + 1; $display("TBFAIL: R 与 W 同一拍（读写重叠）"); end
    if (araw_overlap != 0) begin tbfail = tbfail + 1; $display("TBFAIL: AR 与 AW 同一拍"); end
    if (aw_lead_max > 0)   begin tbfail = tbfail + 1; $display("TBFAIL: AW 领先 AR（写相位抢在读相位前）max=%0d", aw_lead_max); end
    if (wlast_bad   != 0)  begin tbfail = tbfail + 1; end

    $display("CHUNKS=%0d", nchunk);
    $display("AR_BURSTS=%0d AW_BURSTS=%0d B_OK=%0d", ar_bursts, aw_bursts, b_ok);
    $display("RD_BEATS=%0d WR_BEATS=%0d", rd_beats, wr_beats);
    $display("RDWR_OVERLAP=%0d ARAW_OVERLAP=%0d AW_LEAD_MAX=%0d WLAST_BAD=%0d",
             rdwr_overlap, araw_overlap, aw_lead_max, wlast_bad);
    $display("CYC=%0d RD_BYTES=%0d WR_BYTES=%0d ERR=%0d", cyc, rd_bytes, wr_bytes, err_seen);
    $display("DONE_SEEN=%0d", done_seen);

    if (expect_err) begin
      // 非法入参：必须 err、必须 done=0，而且**一个字节都没搬**
      if (err_seen && !done_seen && ar_bursts == 0 && aw_bursts == 0 && b_ok == 0 &&
          rd_bytes == 0 && wr_bytes == 0 && nchunk == 0) begin
        $display("RESULT: PASS");
        $finish;
      end else begin
        $display("RESULT: FAIL 期待 err 且零搬运，实际 err=%0d done=%0d ar=%0d aw=%0d rdb=%0d wrb=%0d",
                 err_seen, done_seen, ar_bursts, aw_bursts, rd_bytes, wr_bytes);
        $fatal(1, "DdrCopyTb expected err with zero movement");
      end
    end else begin
      // 正常拷贝：done 且无 err、每一块都读到/写到（块数 = LEN/128）、字节计数 = LEN
      if (length % CHUNK != 0) begin
        $display("TBFAIL: 装置的 LEN=%0d 不是 128 的整数倍（本用例设计错误）", length);
        tbfail = tbfail + 1;
      end else begin
        if (ar_bursts != length / CHUNK) begin tbfail = tbfail + 1; $display("TBFAIL: AR 突发数=%0d 期望=%0d", ar_bursts, length / CHUNK); end
        if (aw_bursts != length / CHUNK) begin tbfail = tbfail + 1; $display("TBFAIL: AW 突发数=%0d 期望=%0d", aw_bursts, length / CHUNK); end
        if (b_ok      != aw_bursts)      begin tbfail = tbfail + 1; $display("TBFAIL: B 响应数=%0d != AW 数=%0d", b_ok, aw_bursts); end
        if (nchunk    != length / CHUNK) begin tbfail = tbfail + 1; $display("TBFAIL: 块抓取数=%0d 期望=%0d", nchunk, length / CHUNK); end
        if (rd_beats != length / 8)      begin tbfail = tbfail + 1; $display("TBFAIL: R 拍数=%0d 期望=%0d", rd_beats, length / 8); end
        if (wr_beats != length / 8)      begin tbfail = tbfail + 1; $display("TBFAIL: W 拍数=%0d 期望=%0d", wr_beats, length / 8); end
      end
      if (rd_bytes != length) begin tbfail = tbfail + 1; $display("TBFAIL: RD_BYTES=%0d != %0d", rd_bytes, length); end
      if (wr_bytes != length) begin tbfail = tbfail + 1; $display("TBFAIL: WR_BYTES=%0d != %0d", wr_bytes, length); end
      if (done_seen && !err_seen && tbfail == 0) begin
        $display("RESULT: PASS");
        $finish;
      end else begin
        $display("RESULT: FAIL done=%0d err=%0d tbfail=%0d", done_seen, err_seen, tbfail);
        $fatal(1, "DdrCopyTb failed");
      end
    end
  end

  // 兜底：仿真不收敛时也报红退出，别让闸门挂死。
  integer wd;
  initial begin
    for (wd = 0; wd < WD_MAX; wd = wd + 1) @(posedge clk);
    $display("RESULT: FAIL timeout(global watchdog %0d cycles)", WD_MAX);
    $fatal(1, "DdrCopyTb global timeout");
  end

endmodule
