// DdrWriteTb.v —— y1 AXI 主口（gen/DdrMaster.v）**写相位**的装置，纯 Verilog（iverilog -g2012）。
//
// ★ 契约变化（C2.1c）：主口现在**没有"纯写"这个操作**了 —— 一次 `start` 恒等于"把 src 上的
//   len 字节块拷到 dst"（每块 128 B：先整块读进块缓冲、再把该块整块写出去）。所以本装置不再
//   有"先用一笔读把块缓冲灌好、再发两笔纯写"这种写法（`src=0` 的纯写在契约里已非法），
//   改为发**两笔完整拷贝**：SRC1->DST，紧接着 SRC2->DST2。它盯的仍然全是**写相位**的证据：
//     · AW 的地址序列（是否恰好 +128 递进）与每笔 awlen 是否恒 15；
//     · 写下去的字节（内存镜像逐字节对账，含"写区之外一个字节都没动"）；
//     · **背靠背**：第二笔与第一笔之间只差 DUT 结构性的一拍 IDLE（单 outstanding 下的极限），
//       第二笔必须真的落地（旧装置的这条检查一字未减：那时是"同一份缓冲写到两个目标"，
//       现在是"两笔拷贝各写各的目标"，抓的仍是"第二笔被吞掉"这个经典缺陷）；
//     · **W 必须与 AW 同门**（新增的运行期断言，旧装置靠"纯写相位 + 缓冲预置"间接表达）：
//       `ORPHAN_W=0` —— 任何一拍举 W 之前都必须有一笔已被收下的 AW 还挂着（`src/YeshenSocGlue.scala:764`
//       那条 ★ 约束的运行期版本）；每笔写突发恰好 16 拍且末拍 wlast=1（`WLAST_BAD=0`）。
//       （旧装置用"读相位里 aw_bursts 必须仍是 0"来表达"写请求只在写相位发"，新契约下读相位
//        必然属于同一次拷贝、必然紧接着写相位，所以换成上面这条**更直接**的 AW/W 同门断言。）
//
// 装置做三件事，全部走 DUT 的**真端口**（不 force、不 poke 内部寄存器）：
//   ① 一笔完整拷贝 SRC1 -> DST（+SRC1 +DST +LEN）；
//   ② 紧接着一笔完整拷贝 SRC2 -> DST2（+SRC2 +DST2 +LEN），两笔之间只差结构性的一拍 IDLE；
//   ③ 全程打印 AW/B 事实 + 计数，供闸门做**独立**判据（不盲信装置的 PASS）。
//
// 端口表（与 rtl/DdrMaster.scala 冻结一致，和 DdrCopyTb.v 逐字相同）：
//   +SRC1=<dec> +DST=<dec> +LEN=<dec>     第 1 笔拷贝（源/目标/字节数）
//   +SRC2=<dec> +DST2=<dec>              第 2 笔拷贝（背靠背；长度同 +LEN）
//   +MEMFILE=<file>                       Transparent 给 AxiMemModel 的预载文件（模型自己取）。
//   +DUMPFILE=<file>                      仿真结束时回写内存镜像（模型自己取）——闸门在此做逐字节对账。
//   +EXPECT_ERR                           可选：断言"本次必须报 err"（本装置暂用不到，留接口）。
//
// 装置输出（闸门据此做**独立**交叉对账）：
//   `AWB <addr> awlen=<n>`   每一笔 AW 握手打一行（写地址序列 + 突发长度的**运行期**断言）。
//   `BOK <addr>`             每一笔 B 响应打一行。
//   `RDCHK1=`/`WRCHK1=`/`WRCHK2=`  各笔的完成计数。
//   `AW_BURSTS=<n>` `B_OK=<n>` `RD_BYTES1=` `WR_BYTES1=` `WR_BYTES2=` `ORPHAN_W=` `WLAST_BAD=`
//   `RESULT: PASS|FAIL`（FAIL 时 $fatal ⇒ vvp 非 0）。
//
// ★ 与 rtl_test/DdrReadTb.v / DdrCopyTb.v 同口径：驱动在 negedge、握手判据在 posedge 采样。
`timescale 1ns/1ps

module DdrWriteTb;

  localparam integer TIMEOUT = 40000;   // 单笔拷贝等 done/err 的最长时钟拍数
  localparam integer CHUNK   = 128;     // 块缓冲字节数（= 一笔突发 16 拍 x 8B）
  localparam integer BEATS   = 16;      // 一块 = 16 拍

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
  integer    timeout_cnt;
  integer    aw_bursts;      // AW 握手次数（= 写突发数）
  integer    b_ok;           // B 响应次数
  integer    ar_bursts;      // AR 握手次数（信息用：两笔拷贝各 chunks 笔）
  integer    orphan_w;       // 举 W 时没有"已被收下的 AW"挂着的拍数（必须 0）
  integer    wlast_bad;      // wlast 与块内拍号不符的次数（必须 0）
  integer    wbeats_cur;     // 当前这一笔写突发已经发了几拍
  reg        aw_open;        // 有一笔已被收下的 AW 还没等到 B
  reg        done_seen, err_seen;
  reg        op2_err, op3_err;
  reg [31:0] rd_after_op1, wr_after_op1, wr_after_op2;

  // ---- AW / B / W 观察器：写地址序列 + 突发长度 + 响应数 + W-AW 同门（运行期断言）----
  always @(posedge clk) begin
    if (!reset) begin
      if (axi_ar_valid && axi_ar_ready) ar_bursts = ar_bursts + 1;
      if (axi_aw_valid && axi_aw_ready) begin
        $display("AWB %08x awlen=%0d", axi_aw_payload_addr, axi_aw_payload_len);
        aw_bursts = aw_bursts + 1;
        aw_open   = 1'b1;
      end
      if (axi_b_valid && axi_b_ready) begin
        $display("BOK %08x", axi_aw_payload_addr);
        b_ok    = b_ok + 1;
        aw_open = 1'b0;
        if (wbeats_cur != BEATS) begin
          $display("TBFAIL: 一笔写突发只发了 %0d 拍（期望 %0d）", wbeats_cur, BEATS);
          tbfail = tbfail + 1;
        end
        wbeats_cur = 0;
      end
      if (axi_w_valid) begin
        // ★ W 必须与 AW 同门：举 W 之前必须有一笔已被收下的 AW 还挂着
        if (!aw_open) begin
          $display("TBFAIL: 出现 orphan W（没有任何已成交的 AW 挂着）");
          orphan_w = orphan_w + 1;
        end
        if (axi_w_valid && axi_w_ready) begin
          wbeats_cur = wbeats_cur + 1;
          if (axi_w_payload_last !== (wbeats_cur == BEATS)) begin
            $display("TBFAIL: wlast 与块内拍号不符 beat=%0d last=%0d", wbeats_cur, axi_w_payload_last);
            wlast_bad = wlast_bad + 1;
          end
        end
      end
    end
  end

  // ---- 等一笔拷贝结束（done 或 err），带超时 ----
  task wait_op;
    begin
      while (!done_seen && !err_seen) begin
        @(posedge clk);
        if (done)       done_seen = 1'b1;
        else if (err)   err_seen  = 1'b1;
        else begin
          timeout_cnt = timeout_cnt + 1;
          if (timeout_cnt > TIMEOUT) begin
            $display("RESULT: FAIL timeout");
            $fatal(1, "DdrWriteTb timeout");
          end
        end
      end
    end
  endtask

  // ---- 起一笔拷贝并等它结束 ----
  task do_op;
    input [27:0] s;
    input [27:0] d;
    input [31:0] l;
    begin
      done_seen = 1'b0;
      err_seen  = 1'b0;
      @(negedge clk); start = 1'b1; src = s; dst = d; length = l;
      @(negedge clk); start = 1'b0;
      wait_op;
    end
  endtask

  integer k;
  reg [27:0] src1_v, src2_v, dst_v, dst2_v;
  reg [31:0] len_v, exp_wr, exp_chunks;

  initial begin
    start = 1'b0; src = 28'd0; dst = 28'd0; length = 32'd0;
    tbfail = 0; timeout_cnt = 0; aw_bursts = 0; b_ok = 0; ar_bursts = 0;
    orphan_w = 0; wlast_bad = 0; wbeats_cur = 0; aw_open = 1'b0;
    done_seen = 1'b0; err_seen = 1'b0; op2_err = 1'b0; op3_err = 1'b0;
    rd_after_op1 = 32'd0; wr_after_op1 = 32'd0; wr_after_op2 = 32'd0;

    if (!$value$plusargs("SRC1=%d", src1_v)) begin $display("TB-ERROR: missing +SRC1"); $fatal(1,"missing SRC1"); end
    if (!$value$plusargs("DST=%d",  dst_v))  begin $display("TB-ERROR: missing +DST");  $fatal(1,"missing DST");  end
    if (!$value$plusargs("LEN=%d",  len_v))  begin $display("TB-ERROR: missing +LEN");  $fatal(1,"missing LEN");  end
    if (!$value$plusargs("SRC2=%d", src2_v)) begin $display("TB-ERROR: missing +SRC2"); $fatal(1,"missing SRC2"); end
    if (!$value$plusargs("DST2=%d", dst2_v)) begin $display("TB-ERROR: missing +DST2"); $fatal(1,"missing DST2"); end

    $display("TB SRC1=%0d DST=%0d LEN=%0d SRC2=%0d DST2=%0d", src1_v, dst_v, len_v, src2_v, dst2_v);
    exp_wr      = len_v;            // 单笔拷贝写出去的字节数
    exp_chunks  = len_v / CHUNK;

    // 复位（同步、高有效；片上口径）
    repeat (4) @(negedge clk);
    reset = 1'b0;
    @(negedge clk);

    // ================= 第 1 笔：完整拷贝 SRC1 -> DST =================
    do_op(src1_v[27:0], dst_v[27:0], len_v);
    if (err_seen) begin tbfail = tbfail + 1; $display("TBFAIL: 第 1 笔拷贝意外报 err"); end
    if (!done_seen) begin tbfail = tbfail + 1; $display("TBFAIL: 第 1 笔拷贝没有 done"); end
    rd_after_op1 = rd_bytes;        // rd_bytes/wr_bytes 是**每笔**计数器（CHK 里清零）⇒ 必须当场取
    wr_after_op1 = wr_bytes;
    $display("RDCHK1=1 err=%0d done=%0d rd_bytes=%0d wr_bytes=%0d", err_seen, done_seen, rd_after_op1, wr_after_op1);

    // ================= 第 2 笔：**背靠背**再拷一笔 SRC2 -> DST2 =================
    // 与第 1 笔之间只差 DUT 结构性的一拍 IDLE（单 outstanding 下不存在零拍间隔）
    done_seen = 1'b0; err_seen = 1'b0;
    @(negedge clk); src = src2_v[27:0]; dst = dst2_v[27:0]; start = 1'b1;
    while (!busy) @(negedge clk);   // 等第 2 笔真的起来（进 CHK 后 busy=1）
    start = 1'b0;
    wait_op;
    wr_after_op2 = wr_bytes;
    if (err_seen || !done_seen) begin op3_err = 1'b1; $display("TBFAIL: 第 2 笔拷贝（背靠背）err=%0d done=%0d", err_seen, done_seen); end

    @(negedge clk);

    // ================= 收口断言 =================
    if (op2_err) tbfail = tbfail + 1;
    if (op3_err) tbfail = tbfail + 1;
    if (aw_bursts != 2 * exp_chunks) begin
      tbfail = tbfail + 1;
      $display("TBFAIL: AW 突发数=%0d 期望=%0d", aw_bursts, 2 * exp_chunks);
    end
    if (ar_bursts != 2 * exp_chunks) begin
      tbfail = tbfail + 1;
      $display("TBFAIL: AR 突发数=%0d 期望=%0d", ar_bursts, 2 * exp_chunks);
    end
    if (b_ok != aw_bursts) begin tbfail = tbfail + 1; $display("TBFAIL: B 响应数=%0d != AW 数=%0d", b_ok, aw_bursts); end
    if (rd_after_op1 != exp_wr) begin tbfail = tbfail + 1; $display("TBFAIL: 第 1 笔 rd_bytes=%0d != %0d", rd_after_op1, exp_wr); end
    if (wr_after_op1 != exp_wr) begin tbfail = tbfail + 1; $display("TBFAIL: 第 1 笔 wr_bytes=%0d != %0d", wr_after_op1, exp_wr); end
    if (wr_after_op2 != exp_wr) begin tbfail = tbfail + 1; $display("TBFAIL: 第 2 笔 wr_bytes=%0d != %0d", wr_after_op2, exp_wr); end
    if (orphan_w  != 0) begin tbfail = tbfail + 1; $display("TBFAIL: orphan W = %0d（W 与 AW 不同门）", orphan_w); end
    if (wlast_bad != 0) begin tbfail = tbfail + 1; $display("TBFAIL: wlast 不符 = %0d", wlast_bad); end

    $display("AW_BURSTS=%0d", aw_bursts);
    $display("AR_BURSTS=%0d", ar_bursts);
    $display("B_OK=%0d", b_ok);
    $display("RD_BYTES1=%0d", rd_after_op1);
    $display("WR_BYTES1=%0d", wr_after_op1);
    $display("WR_BYTES2=%0d", wr_after_op2);
    $display("ORPHAN_W=%0d WLAST_BAD=%0d", orphan_w, wlast_bad);
    $display("ERR=%0d", (op2_err|op3_err));

    if (tbfail == 0) begin
      $display("RESULT: PASS");
      $finish;
    end else begin
      $display("RESULT: FAIL tbfail=%0d", tbfail);
      $fatal(1, "DdrWriteTb failed");
    end
  end

  // 兜底：仿真不收敛时也报红退出，别让闸门挂死。
  initial begin
    #50000000;
    $display("RESULT: FAIL timeout(global)");
    $fatal(1, "DdrWriteTb global timeout");
  end

endmodule
