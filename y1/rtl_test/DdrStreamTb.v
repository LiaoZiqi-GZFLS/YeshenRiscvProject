// DdrStreamTb.v —— y1 AXI 主口（gen/DdrMaster.v）**三种模式**的装置（C3.3 新增），纯 Verilog（iverilog -g2012）。
//
// 契约（与 rtl/DdrMaster.scala 头部 C3.3 那两节逐条对应）：
//   +MODE=<0|1|2>   0=COPY（块拷贝）1=RD（只读 ⇒ 把块缓冲推给 rd_stream）2=WR（只写 ⇐ wr_stream）
//   +SRC=<dec> +DST=<dec> +LEN=<dec>   与 DdrCopyTb 同口径；装置**不替 DUT 校验**（非对齐/非 32 倍数
//                    也照喂，由 DUT 自己去发现并报 err —— 负对照要的正是这个行为）。
//   +STREAMIN=<file>   WR 模式：喂给 wr_stream 的字节（$readmemh，一行一个十六进制字节，与 MEMFILE
//                      同格式）。第 i 拍 = 第 i*8..i*8+7 个字节，小端。
//   +STREAMOUT=<file>  RD 模式：把 rd_stream 上**实际收到**的字节按同一格式落盘（i*8+j 个字节 =
//                      第 i 拍的 data[8j+7:8j]）—— 闸门拿它和预载的源区**逐字节**对账。
//   +MEMFILE= +DUMPFILE=  转给 AxiMemModel（模型自己取）。
//   +EXPECT_ERR        可选：断言"本次必须报 err 且**一个字节都不搬、流上一个拍都没有**"。
//
// 装置做四件事（全部走 DUT 的**真端口**，不 force、不 poke 内部寄存器）：
//   ① 复位后给 start 一拍脉冲（`src/dst/len/mode` 与 start **同拍**有效），等 done 或 err（拍数超时
//      + 全局看门狗 ⇒ 挂死也报红）；
//   ② 逐笔打印 `ARB <addr> arlen=<n>` / `AWB <addr> awlen=<n>`（地址序列与突发长度的**运行期**事实；
//      判据由闸门（Python）独立算黄金序列来对）；
//   ③ **结构性断言**（这些是"模式划分"的硬条款，全部按运行期计数执行）：
//        · `MODE_LEAK_BAD=0`：RD 模式不许出现 AW/W（`aw_bursts`/`wr_beats`/`wr_bytes` 必须 0）；
//          WR 模式不许出现 AR/R；COPY 模式不许出现任何流活动（`rd_valid`/`wr_ready` 一拍都不许举）；
//        · `ORPHAN_W=0`：任何一拍举 W 之前必须有一笔**已被收下**的 AW 还挂着（`YeshenSocGlue.scala:764`
//          那条 ★ 约束的运行期版本）；WR 模式下这条同样要成立；
//        · `WLAST_BAD=0` / `WBURST_BAD=0`：每笔写突发的拍数必须**恰好等于该笔 AW 声明的长度**
//          （`awlen+1`），且末拍 `wlast=1`、其余拍 0 —— 这条正是"尾块缩短突发"在写侧的判据；
//        · `RBEAT_BAD=0`：每笔读突发的拍数必须恰好等于该笔 AR 声明的长度（尾块缩短在读侧的判据）；
//        · `RDWR_OVERLAP=0` / `ARAW_OVERLAP=0`：R 与 W、AR 与 AW 都绝不同拍（单 outstanding 的硬条款）。
//   ④ 收尾打印计数与**唯一的一行** `CYC=<n> RD_BYTES=<n> WR_BYTES=<n> ERR=<b>`，最后
//      `RESULT: PASS|FAIL`；FAIL 时 $fatal ⇒ vvp 非零退出。
//
// ★ 与 rtl_test/DdrCopyTb.v / DdrReadTb.v / DdrWriteTb.v 同口径：驱动在 negedge、握手判据在 posedge
//   采样，避免同沿竞争。流侧**故意加确定性背压**（rd_ready 每 4 拍掐 1 拍、wr_valid 每 4 拍空 1 拍），
//   这样"等对流 ready / valid 才推进"这条路径真的被走到，而不是一路全速通过。
`timescale 1ns/1ps

module DdrStreamTb;

  localparam integer MEMSZ   = 8192;      // 8 KiB 建模内存；本装置只做短搬运（搬移量 << 8 KiB）；与闸门里的 MEMSZ 一致
  localparam integer TIMEOUT = 40000;     // 等 done/err 的最长时钟拍数
  localparam integer WD_MAX  = 300000;    // 全局看门狗（拍）
  localparam integer MAXB    = 1024;      // 流的最大拍数（1 KiB / 8 = 128 拍 << 1024）

  reg clk   = 1'b0;
  reg reset = 1'b1;
  always #5 clk = ~clk;

  // ---- DUT 控制 / 状态 ----
  reg         start;
  reg  [1:0]  mode_v;
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

  // ---- 流（C3.3）----
  wire        rd_valid;
  reg         rd_ready;
  wire [63:0] rd_data;
  reg         wr_valid;
  wire        wr_ready;
  reg  [63:0] wr_data;

  // ---- 被测主口 ----
  DdrMaster dut (
    .start(start), .src(src), .dst(dst), .len(length), .mode(mode_v),
    .sg_valid(1'b0), .sg_flush(1'b0), .sg_addr(28'd0), .sg_beatsM1(4'd0),
        .busy(busy), .done(done), .err(err), .cyc(cyc),
    .rd_bytes(rd_bytes), .wr_bytes(wr_bytes),
    .rd_valid(rd_valid), .rd_ready(rd_ready), .rd_data(rd_data),
    .wr_valid(wr_valid), .wr_ready(wr_ready), .wr_data(wr_data),
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
  AxiMemModel #(.MEMSZ(MEMSZ), .ADDR_W(28)) mem0 (
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

  // ===========================================================================
  // 流：字节数组 + 小端装配 + 确定性背压
  // ===========================================================================
  reg [7:0] sin  [0:MAXB*8-1];   // WR：喂进去的字节（$readmemh 自 +STREAMIN）
  reg [7:0] sout [0:MAXB*8-1];   // RD：收下来的字节（落 +STREAMOUT）
  integer   sin_n;               // 实际读进多少字节（闸门会与 LEN 对账）

  /** 第 i 拍的 64 bit（小端：pack[8j+7:8j] = sin[i*8+j]）。纯组合函数。 */
  function [63:0] pack_beat;
    input integer i;
    begin
      pack_beat = { sin[i*8+7], sin[i*8+6], sin[i*8+5], sin[i*8+4],
                    sin[i*8+3], sin[i*8+2], sin[i*8+1], sin[i*8+0] };
    end
  endfunction

  integer gapcnt;                 // 0..3 自由跑，用来产生确定性的背压/空拍
  integer wr_idx;                 // 已经喂进去几拍
  integer exp_beats;              // WR 模式总共要喂几拍 = LEN/8
  integer sout_n;                 // 已经收下来几拍

  always @(negedge clk) begin
    if (!reset) begin
      gapcnt   <= (gapcnt == 3) ? 0 : (gapcnt + 1);
      rd_ready <= (gapcnt != 1);                                   // RD 背压：4 拍掐 1 拍
      wr_valid <= (mode_v == 2) && (wr_idx < exp_beats) && (gapcnt != 3);  // WR 空拍：4 拍空 1 拍
      wr_data  <= pack_beat(wr_idx);
    end
  end

  always @(posedge clk) begin
    if (!reset) begin
      if (wr_valid && wr_ready) wr_idx <= wr_idx + 1;
      if (rd_valid && rd_ready) begin
        sout[sout_n*8+0] <= rd_data[7:0];
        sout[sout_n*8+1] <= rd_data[15:8];
        sout[sout_n*8+2] <= rd_data[23:16];
        sout[sout_n*8+3] <= rd_data[31:24];
        sout[sout_n*8+4] <= rd_data[39:32];
        sout[sout_n*8+5] <= rd_data[47:40];
        sout[sout_n*8+6] <= rd_data[55:48];
        sout[sout_n*8+7] <= rd_data[63:56];
        sout_n <= sout_n + 1;
      end
    end
  end

  // ===========================================================================
  // AXI 观察器 / 结构性断言（全部是运行期计数，判据在收口处一并判）
  // ===========================================================================
  integer ar_bursts, aw_bursts, b_ok, rd_beats, wr_beats;
  integer rdwr_overlap, araw_overlap;
  integer orphan_w, wlast_bad, wburst_bad, rbeat_bad, mode_leak_bad;
  integer aw_lead, aw_lead_max;
  integer rbeats_cur, wbeats_cur;
  integer arlen_cur, awlen_cur;
  // L2b：多 outstanding AR ⇒ 按队列存每笔 AR 的声明长度，R 按序取头对账。
  reg [7:0] arlen_q [0:7];
  integer arq_wp, arq_rp, arq_cnt;
  reg     aw_open;
  reg     stream_bad;             // 非对应模式下 rd_valid / wr_ready 竟然举了

  always @(posedge clk) begin
    if (!reset) begin
      // ---- AR：地址/长度事实 + 本笔拍数必须等于声明的长度 ----
      if (axi_ar_valid && axi_ar_ready) begin
        $display("ARB %08x arlen=%0d", axi_ar_payload_addr, axi_ar_payload_len);
        ar_bursts = ar_bursts + 1;
        arlen_q[arq_wp] = axi_ar_payload_len; arq_wp = (arq_wp + 1) % 8; arq_cnt = arq_cnt + 1;
      end
      if (axi_r_valid && axi_r_ready) begin
        rd_beats   = rd_beats + 1;
        rbeats_cur = rbeats_cur + 1;
        if (axi_r_payload_last !== (rbeats_cur == arlen_q[arq_rp] + 1)) begin
          $display("TBFAIL: R 末拍与 AR 声明长度不符 beat=%0d arlen=%0d last=%0d",
                   rbeats_cur, arlen_q[arq_rp], axi_r_payload_last);
          rbeat_bad = rbeat_bad + 1;
        end
        if (axi_r_payload_last) begin
          arq_rp = (arq_rp + 1) % 8; arq_cnt = arq_cnt - 1; rbeats_cur = 0;
        end
      end
      // ---- AW / W / B ----
      if (axi_aw_valid && axi_aw_ready) begin
        $display("AWB %08x awlen=%0d", axi_aw_payload_addr, axi_aw_payload_len);
        aw_bursts = aw_bursts + 1;
        aw_open   = 1'b1;
        awlen_cur = axi_aw_payload_len;
        wbeats_cur = 0;
        aw_lead    = aw_bursts - ar_bursts;          // 累计 AW - 累计 AR
        if (aw_lead > aw_lead_max) aw_lead_max = aw_lead;
      end
      if (axi_w_valid) begin
        if (!aw_open) begin
          $display("TBFAIL: 出现 orphan W（没有任何已成交的 AW 挂着）");
          orphan_w = orphan_w + 1;
        end
        if (axi_w_valid && axi_w_ready) begin
          wr_beats   = wr_beats + 1;
          wbeats_cur = wbeats_cur + 1;
          if (axi_w_payload_last !== (wbeats_cur == awlen_cur + 1)) begin
            $display("TBFAIL: W 末拍与 AW 声明长度不符 beat=%0d awlen=%0d last=%0d",
                     wbeats_cur, awlen_cur, axi_w_payload_last);
            wlast_bad = wlast_bad + 1;
          end
        end
      end
      if (axi_b_valid && axi_b_ready) begin
        b_ok    = b_ok + 1;
        aw_open = 1'b0;
        if (wbeats_cur != awlen_cur + 1) begin
          $display("TBFAIL: 一笔写突发只发了 %0d 拍，AW 声明 %0d 拍", wbeats_cur, awlen_cur + 1);
          wburst_bad = wburst_bad + 1;
        end
        wbeats_cur = 0;
      end
      // ---- 单 outstanding 的两条不重叠 ----
      if ((axi_ar_valid && axi_ar_ready) && (axi_aw_valid && axi_aw_ready)) araw_overlap = araw_overlap + 1;
      if ((axi_r_valid  && axi_r_ready)  && (axi_w_valid  && axi_w_ready))  rdwr_overlap = rdwr_overlap + 1;
      // ---- 模式越界：非对应模式的通道/流不许动 ----
      if (mode_v == 2'd1 && (axi_aw_valid || axi_w_valid)) mode_leak_bad = mode_leak_bad + 1;
      if (mode_v == 2'd2 && (axi_ar_valid || axi_r_ready))  mode_leak_bad = mode_leak_bad + 1;
      if (mode_v != 2'd1 && rd_valid)  stream_bad = 1'b1;
      if (mode_v != 2'd2 && wr_ready)  stream_bad = 1'b1;
    end
  end

  // ---- 等 done 或 err，带超时 ----
  integer timeout_cnt;
  reg     done_seen, err_seen;
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
            $fatal(1, "DdrStreamTb timeout");
          end
        end
      end
    end
  endtask

  integer i, fd;
  integer mode_in, src_in, dst_in, len_in;
  reg [8*256-1:0] streamin_f, streamout_f;
  reg        expect_err;
  integer    tbfail;

  initial begin
    start = 1'b0; mode_v = 2'd0; src = 28'd0; dst = 28'd0; length = 32'd0;
    rd_ready = 1'b0; wr_valid = 1'b0; wr_data = 64'd0;
    gapcnt = 0; wr_idx = 0; sout_n = 0; exp_beats = 0; sin_n = 0;
    for (i = 0; i < MAXB*8; i = i + 1) begin sin[i] = 8'h00; sout[i] = 8'h00; end
    tbfail = 0; timeout_cnt = 0;
    ar_bursts = 0; aw_bursts = 0; b_ok = 0; rd_beats = 0; wr_beats = 0;
    rdwr_overlap = 0; araw_overlap = 0; orphan_w = 0; wlast_bad = 0;
    wburst_bad = 0; rbeat_bad = 0; mode_leak_bad = 0; stream_bad = 1'b0;
    aw_lead = 0; aw_lead_max = 0; rbeats_cur = 0; wbeats_cur = 0;
    arlen_cur = 0; awlen_cur = 0; aw_open = 1'b0;
    arq_wp = 0; arq_rp = 0; arq_cnt = 0;
    done_seen = 1'b0; err_seen = 1'b0; expect_err = 1'b0;

    if (!$value$plusargs("MODE=%d", mode_in)) begin $display("TB-ERROR: missing +MODE="); $fatal(1,"missing MODE"); end
    if (!$value$plusargs("SRC=%d",  src_in))  begin $display("TB-ERROR: missing +SRC=");  $fatal(1,"missing SRC");  end
    if (!$value$plusargs("DST=%d",  dst_in))  begin $display("TB-ERROR: missing +DST=");  $fatal(1,"missing DST");  end
    if (!$value$plusargs("LEN=%d",  len_in))  begin $display("TB-ERROR: missing +LEN=");  $fatal(1,"missing LEN");  end
    if ($test$plusargs("EXPECT_ERR")) expect_err = 1'b1;

    if (mode_in < 0 || mode_in > 2) begin $display("TB-ERROR: +MODE=%0d 非法", mode_in); $fatal(1,"bad MODE"); end
    mode_v = mode_in[1:0];
    src    = src_in[27:0];
    dst    = dst_in[27:0];
    length = len_in;
    exp_beats = len_in / 8;                    // WR 模式要喂进来的拍数（= 总线上要读回的拍数）

    // WR 模式的喂数据源：**只读字节形式**，与 MEMFILE 同格式
    if ($value$plusargs("STREAMIN=%s", streamin_f)) begin
      if (mode_v == 2'd2) begin
        $readmemh(streamin_f, sin);
        $display("TB STREAMIN %0s", streamin_f);
      end
    end

    $display("TB STREAM MODE=%0d SRC=%0d DST=%0d LEN=%0d EXPECT_ERR=%0d", mode_v, src, dst, length, expect_err);

    // 复位（同步、高有效；片上口径）
    repeat (4) @(negedge clk);
    reset = 1'b0;
    @(negedge clk);

    // start 一拍脉冲（mode/src/dst/len 与 start 同拍有效）
    @(negedge clk); start = 1'b1;
    @(negedge clk); start = 1'b0;

    wait_op;
    repeat (4) @(negedge clk);   // 让监视器与流侧收尾

    // ---- RD：把收下来的字节落盘（判据在闸门里做，装置只给事实）----
    if (mode_v == 2'd1 && !err_seen) begin
      if (!$value$plusargs("STREAMOUT=%s", streamout_f)) begin
        $display("TB-ERROR: RD 模式必须给 +STREAMOUT="); $fatal(1, "missing STREAMOUT");
      end
      fd = $fopen(streamout_f, "w");
      if (fd == 0) begin $display("TB-ERROR: 打不开 +STREAMOUT=%0s", streamout_f); $fatal(1,"open STREAMOUT"); end
      for (i = 0; i < length; i = i + 1) $fdisplay(fd, "%02x", sout[i]);
      $fclose(fd);
      $display("TB STREAMOUT %0s (%0d bytes)", streamout_f, length);
    end

    $display("STREAM_RD_BEATS=%0d STREAM_WR_BEATS=%0d", sout_n, wr_idx);
    $display("AR_BURSTS=%0d AW_BURSTS=%0d B_OK=%0d RD_BEATS=%0d WR_BEATS=%0d",
             ar_bursts, aw_bursts, b_ok, rd_beats, wr_beats);
    $display("ORPHAN_W=%0d WLAST_BAD=%0d WBURST_BAD=%0d RBEAT_BAD=%0d", orphan_w, wlast_bad, wburst_bad, rbeat_bad);
    $display("RDWR_OVERLAP=%0d ARAW_OVERLAP=%0d AW_LEAD_MAX=%0d MODE_LEAK_BAD=%0d STREAM_IDLE_BAD=%0d",
             rdwr_overlap, araw_overlap, aw_lead_max, mode_leak_bad, stream_bad);
    $display("CYC=%0d RD_BYTES=%0d WR_BYTES=%0d ERR=%0d", cyc, rd_bytes, wr_bytes, err_seen);
    $display("DONE_SEEN=%0d", done_seen);

    if (expect_err) begin
      // 非法入参：必须 err、必须 done=0，而且**一个字节都没搬、流上一个拍都没有**
      if (err_seen && !done_seen && ar_bursts == 0 && aw_bursts == 0 && b_ok == 0 &&
          rd_bytes == 0 && wr_bytes == 0 && rd_beats == 0 && wr_beats == 0 &&
          sout_n == 0 && wr_idx == 0 && !stream_bad && mode_leak_bad == 0) begin
        $display("RESULT: PASS");
        $finish;
      end else begin
        $display("RESULT: FAIL 期待 err 且零搬运，实际 err=%0d done=%0d ar=%0d aw=%0d rdb=%0d wrb=%0d",
                 err_seen, done_seen, ar_bursts, aw_bursts, rd_bytes, wr_bytes);
        $fatal(1, "DdrStreamTb expected err with zero movement");
      end
    end else begin
      // ---- 结构性判据（不分模式）----
      if (orphan_w  != 0)    begin tbfail = tbfail + 1; end
      if (wlast_bad != 0)    begin tbfail = tbfail + 1; end
      if (wburst_bad != 0)   begin tbfail = tbfail + 1; end
      if (rbeat_bad != 0)    begin tbfail = tbfail + 1; end
      if (rdwr_overlap != 0) begin tbfail = tbfail + 1; $display("TBFAIL: R 与 W 同一拍"); end
      if (araw_overlap != 0) begin tbfail = tbfail + 1; $display("TBFAIL: AR 与 AW 同一拍"); end
      if (mode_leak_bad != 0) begin tbfail = tbfail + 1; $display("TBFAIL: 模式越界（RD 发了 AW/W 或 WR 发了 AR/R）"); end
      if (stream_bad)        begin tbfail = tbfail + 1; $display("TBFAIL: 非对应模式下流口竟然举了 valid/ready"); end
      if (length % 32 != 0)  begin tbfail = tbfail + 1; $display("TBFAIL: 用例 LEN=%0d 不是 32 的整数倍（用例设计错误）", length); end

      // ---- 分数：总拍数必须恰好 = LEN/8（每拍 8 B），且各模式只看自己那一侧 ----
      // （COPY 两侧都查；RD 只查读、WR 只查写 —— 在各自的分支里查）

      if (mode_v == 2'd0) begin
        // COPY：两边都有，字节数 = LEN，AR/AW 各 = 块数
        if (rd_beats * 8 != length) begin tbfail = tbfail + 1; $display("TBFAIL: COPY R 拍数=%0d 期望=%0d", rd_beats, length/8); end
        if (wr_beats * 8 != length) begin tbfail = tbfail + 1; $display("TBFAIL: COPY W 拍数=%0d 期望=%0d", wr_beats, length/8); end
        if (rd_bytes != length) begin tbfail = tbfail + 1; $display("TBFAIL: COPY RD_BYTES=%0d != %0d", rd_bytes, length); end
        if (wr_bytes != length) begin tbfail = tbfail + 1; $display("TBFAIL: COPY WR_BYTES=%0d != %0d", wr_bytes, length); end
        if (ar_bursts != aw_bursts) begin tbfail = tbfail + 1; $display("TBFAIL: COPY AR/AW 笔数不等 %0d/%0d", ar_bursts, aw_bursts); end
        if (b_ok != aw_bursts) begin tbfail = tbfail + 1; $display("TBFAIL: COPY B 响应数=%0d != AW=%0d", b_ok, aw_bursts); end
        if (sout_n != 0) begin tbfail = tbfail + 1; $display("TBFAIL: COPY 模式下 rd_stream 竟然推了 %0d 拍", sout_n); end
        if (wr_idx != 0) begin tbfail = tbfail + 1; $display("TBFAIL: COPY 模式下 wr_stream 竟然被取了 %0d 拍", wr_idx); end
      end else if (mode_v == 2'd1) begin
        // RD：只有读。wr_bytes 恒 0；AW/B 一笔都没有（**结构性**：AR 只从 CHK/WNEXT 进，RD 到不了 WR）。
        if (rd_beats * 8 != length) begin tbfail = tbfail + 1; $display("TBFAIL: RD R 拍数=%0d 期望=%0d", rd_beats, length/8); end
        if (rd_bytes != length) begin tbfail = tbfail + 1; $display("TBFAIL: RD RD_BYTES=%0d != %0d", rd_bytes, length); end
        if (wr_bytes != 0) begin tbfail = tbfail + 1; $display("TBFAIL: RD WR_BYTES=%0d != 0", wr_bytes); end
        if (aw_bursts != 0 || b_ok != 0) begin tbfail = tbfail + 1; $display("TBFAIL: RD 模式竟然发了 AW/B（%0d/%0d）", aw_bursts, b_ok); end
        if (sout_n * 8 != length) begin tbfail = tbfail + 1; $display("TBFAIL: RD 推出拍数=%0d 期望=%0d", sout_n, length/8); end
        if (wr_idx != 0) begin tbfail = tbfail + 1; $display("TBFAIL: RD 模式下 wr_stream 竟然被取了 %0d 拍", wr_idx); end
      end else begin
        // WR：只有写。rd_bytes 恒 0；AR 一笔都没有。
        if (wr_beats * 8 != length) begin tbfail = tbfail + 1; $display("TBFAIL: WR W 拍数=%0d 期望=%0d", wr_beats, length/8); end
        if (wr_bytes != length) begin tbfail = tbfail + 1; $display("TBFAIL: WR WR_BYTES=%0d != %0d", wr_bytes, length); end
        if (rd_bytes != 0) begin tbfail = tbfail + 1; $display("TBFAIL: WR RD_BYTES=%0d != 0", rd_bytes); end
        if (ar_bursts != 0) begin tbfail = tbfail + 1; $display("TBFAIL: WR 模式竟然发了 AR（%0d 笔）", ar_bursts); end
        if (b_ok != aw_bursts) begin tbfail = tbfail + 1; $display("TBFAIL: WR B 响应数=%0d != AW=%0d", b_ok, aw_bursts); end
        if (wr_idx != exp_beats) begin tbfail = tbfail + 1; $display("TBFAIL: WR 取走拍数=%0d 期望=%0d", wr_idx, exp_beats); end
        if (sout_n != 0) begin tbfail = tbfail + 1; $display("TBFAIL: WR 模式下 rd_stream 竟然推了 %0d 拍", sout_n); end
      end

      if (done_seen && !err_seen && tbfail == 0) begin
        $display("RESULT: PASS");
        $finish;
      end else begin
        $display("RESULT: FAIL done=%0d err=%0d tbfail=%0d", done_seen, err_seen, tbfail);
        $fatal(1, "DdrStreamTb failed");
      end
    end
  end

  // 兜底：仿真不收敛时也报红退出，别让闸门挂死。
  integer wd;
  initial begin
    for (wd = 0; wd < WD_MAX; wd = wd + 1) @(posedge clk);
    $display("RESULT: FAIL timeout(global watchdog %0d cycles)", WD_MAX);
    $fatal(1, "DdrStreamTb global timeout");
  end

endmodule
