// DmaEngineTb.v —— y1 **多通道 DMA 引擎**（gen/DmaEngine.v）的单元装置，纯 Verilog（iverilog -g2012）。
//
// 契约（与 rtl/DmaEngine.scala 文件头 §2/§3 的表逐条对应）：
//   +JOB=<0..6>   0=单笔 COPY（DDR→DDR）/ 1=RD（DDR→外设缓冲）/ 2=WR（外设缓冲→DDR）
//                 3=非法入参 err / 4=同一通道背靠背 N 笔 / 5=两通道并发 / 6=abort（+ 同通道再跑一笔）
//   +CH= +SRC= +DST= +LEN= +MODE=     参与 JOB 0..4/6 的用例（装置**不替 DUT 校验**）
//   +SRC1= +DST1= +LEN1=              JOB 5 的通道 1 用例
//   +N=                               JOB 4 笔数（默认 6）
//   +ABORT_AFTER=<clk 拍>             JOB 6：start 之后这么多拍发 abort
//   +EXPECT_ERR +CODE=<n>             JOB 3：必须 err 且零搬运、err_code 必须 == CODE
//   +STREAMIN= +STREAMOUT=            WR 喂数据 / RD 收数据（$readmemh 一行一字节）
//   +MEMFILE= +DUMPFILE= +dump        转给 AxiMemModel
//
// 装置走 DUT 的**真端口**（AXI-Lite CSR + AXI4 主口），不 force、不 poke 内部。
// 结构性断言（运行期计数）与 DdrStreamTb 同口径；其中 `ARAW_OVERLAP=0` / `RDWR_OVERLAP=0`
// 钉的是本引擎仲裁器的**设计事实**（grant 持有到 `rlast`/`B` ⇒ 任一时刻只有一笔事务在飞）。
`timescale 1ns/1ps

module DmaEngineTb;

  localparam integer MEMSZ   = 65536;
  localparam integer TIMEOUT = 200000;    // 等一次完成的最多轮询次数
  localparam integer WD_MAX  = 4000000;   // 全局看门狗（拍）
  localparam integer MAXB    = 4096;

  reg clk   = 1'b0;
  reg reset = 1'b1;
  always #5 clk = ~clk;

  // ===================== DUT =====================
  reg         axilite_aw_valid, axilite_w_valid, axilite_b_ready;
  reg  [31:0] axilite_aw_payload_addr, axilite_w_payload_data;
  reg  [2:0]  axilite_aw_payload_prot;
  reg  [3:0]  axilite_w_payload_strb;
  wire        axilite_aw_ready, axilite_w_ready, axilite_b_valid;
  wire [1:0]  axilite_b_payload_resp;
  reg         axilite_ar_valid, axilite_r_ready;
  reg  [31:0] axilite_ar_payload_addr;
  reg  [2:0]  axilite_ar_payload_prot;
  wire        axilite_ar_ready, axilite_r_valid;
  wire [31:0] axilite_r_payload_data;
  wire [1:0]  axilite_r_payload_resp;

  wire        axi_aw_valid, axi_aw_ready;
  wire [29:0] axi_aw_payload_addr;
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
  wire [29:0] axi_ar_payload_addr;
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

  wire        rd_valid_0, rd_valid_1, wr_ready_0, wr_ready_1;
  wire [63:0] rd_data_0, rd_data_1;
  reg         rd_ready_0, rd_ready_1, wr_valid_0, wr_valid_1;
  reg  [63:0] wr_data_0, wr_data_1;

  DmaEngine dut (
    .axilite_aw_valid(axilite_aw_valid), .axilite_aw_ready(axilite_aw_ready),
    .axilite_aw_payload_addr(axilite_aw_payload_addr), .axilite_aw_payload_prot(axilite_aw_payload_prot),
    .axilite_w_valid(axilite_w_valid), .axilite_w_ready(axilite_w_ready),
    .axilite_w_payload_data(axilite_w_payload_data), .axilite_w_payload_strb(axilite_w_payload_strb),
    .axilite_b_valid(axilite_b_valid), .axilite_b_ready(axilite_b_ready),
    .axilite_b_payload_resp(axilite_b_payload_resp),
    .axilite_ar_valid(axilite_ar_valid), .axilite_ar_ready(axilite_ar_ready),
    .axilite_ar_payload_addr(axilite_ar_payload_addr), .axilite_ar_payload_prot(axilite_ar_payload_prot),
    .axilite_r_valid(axilite_r_valid), .axilite_r_ready(axilite_r_ready),
    .axilite_r_payload_data(axilite_r_payload_data), .axilite_r_payload_resp(axilite_r_payload_resp),
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
    .rd_valid_0(rd_valid_0), .rd_ready_0(rd_ready_0), .rd_data_0(rd_data_0),
    .rd_valid_1(rd_valid_1), .rd_ready_1(rd_ready_1), .rd_data_1(rd_data_1),
    .wr_valid_0(wr_valid_0), .wr_ready_0(wr_ready_0), .wr_data_0(wr_data_0),
    .wr_valid_1(wr_valid_1), .wr_ready_1(wr_ready_1), .wr_data_1(wr_data_1),
    // H2 job port: unused here => tie 0 explicitly (floating X poisons JOB_CH CSR start)
    .job_valid(1'b0), .job_addr(30'd0), .job_len(32'd0),
    .clk(clk), .reset(reset)
  );

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

  // ===================== AXI-Lite 主机 =====================
  integer awd, wd;
  task axil_write(input [31:0] a, input [31:0] d);
    begin
      awd = 0; wd = 0;
      @(negedge clk);
      axilite_aw_valid = 1'b1; axilite_aw_payload_addr = a; axilite_aw_payload_prot = 3'b000;
      axilite_w_valid  = 1'b1; axilite_w_payload_data  = d; axilite_w_payload_strb = 4'hF;
      while (!(awd && wd)) begin
        @(posedge clk);
        if (axilite_aw_valid && axilite_aw_ready) awd = 1;
        if (axilite_w_valid  && axilite_w_ready ) wd  = 1;
      end
      @(negedge clk);
      axilite_aw_valid = 1'b0; axilite_w_valid = 1'b0;
      while (!axilite_b_valid) @(posedge clk);
      axilite_b_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      axilite_b_ready = 1'b0;
      if (axilite_b_payload_resp !== 2'b00) $display("TBFAIL: AXI-Lite 写响应非 OKAY resp=%0d", axilite_b_payload_resp);
    end
  endtask

  task axil_read(input [31:0] a, output [31:0] d);
    begin
      @(negedge clk);
      axilite_ar_valid = 1'b1; axilite_ar_payload_addr = a; axilite_ar_payload_prot = 3'b000;
      while (!(axilite_ar_valid && axilite_ar_ready)) @(posedge clk);
      @(negedge clk);
      axilite_ar_valid = 1'b0;
      while (!axilite_r_valid) @(posedge clk);
      d = axilite_r_payload_data;
      axilite_r_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      axilite_r_ready = 1'b0;
    end
  endtask

  // ===================== CSR 偏移 =====================
  function [31:0] ch_a; input integer c; input integer off; begin ch_a = c * 64 + off; end endfunction
  localparam integer O_CTRL = 0, O_STAT = 4, O_SRC = 8, O_DST = 12, O_LEN = 16, O_MODE = 20,
                     O_BYTE = 24, O_CYC = 28, O_CODE = 32, O_ID = 36;
  localparam integer A_GBL_ID = 128, A_GBL_NCH = 132, A_GBL_BUSY = 136, A_GBL_DONE = 140, A_GBL_ERR = 144;

  // 读一个通道的全部寄存器 -> 全局变量（供论断使用）
  reg [31:0] g_ctrl, g_stat, g_code, g_bytes, g_cyc, g_id;
  task ch_rd(input integer c);
    begin
      axil_read(ch_a(c, O_CTRL), g_ctrl);
      axil_read(ch_a(c, O_STAT), g_stat);
      axil_read(ch_a(c, O_CODE), g_code);
      axil_read(ch_a(c, O_BYTE), g_bytes);
      axil_read(ch_a(c, O_CYC ), g_cyc);
      axil_read(ch_a(c, O_ID  ), g_id);
      $display("CHSN %0d CTRL=%08x STAT=%08x CODE=%0d BYTES=%0d CYCLES=%0d ID=%08x BUSY=%0d DONE=%0d ERR=%0d ABRT=%0d",
               c, g_ctrl, g_stat, g_code, g_bytes, g_cyc, g_id,
               g_ctrl[8], g_stat[0], g_stat[1], g_stat[2]);
    end
  endtask

  task ch_prog(input integer c, input [31:0] s, input [31:0] dd, input [31:0] l, input [31:0] m);
    begin
      axil_write(ch_a(c, O_SRC),  s);
      axil_write(ch_a(c, O_DST),  dd);
      axil_write(ch_a(c, O_LEN),  l);
      axil_write(ch_a(c, O_MODE), m);
    end
  endtask
  task ch_start(input integer c); begin axil_write(ch_a(c, O_CTRL), 32'h1); end endtask
  task ch_abort(input integer c); begin axil_write(ch_a(c, O_CTRL), 32'h2); end endtask
  task ch_clear(input integer c); begin axil_write(ch_a(c, O_STAT), 32'h7); end endtask

  // 轮询直到某通道终止（done/err/aborted）
  task ch_wait(input integer c);
    integer k;
    begin
      k = 0;
      axil_read(ch_a(c, O_STAT), g_stat);
      while (!(g_stat[0] || g_stat[1] || g_stat[2])) begin
        k = k + 1;
        if (k > TIMEOUT) begin
          $display("RESULT: FAIL timeout 等 CH%0d", c);
          $fatal(1, "DmaEngineTb timeout");
        end
        axil_read(ch_a(c, O_STAT), g_stat);
      end
    end
  endtask

  // ===================== 流模型（每通道一份） =====================
  reg [7:0] sin [0:MAXB*8-1];
  reg [7:0] sout[0:MAXB*8-1];
  integer gapcnt, sout_n, wr_idx, exp_beats;
  integer job_i, ch_i, mode_i, n_i, abort_after, len0, len1;
  reg     is_rd0, is_wr0, is_rd1, is_wr1;

  function [63:0] pack_beat; input integer i;
    begin pack_beat = { sin[i*8+7], sin[i*8+6], sin[i*8+5], sin[i*8+4],
                        sin[i*8+3], sin[i*8+2], sin[i*8+1], sin[i*8+0] }; end
  endfunction

  always @(negedge clk) begin
    if (!reset) begin
      gapcnt     <= (gapcnt == 3) ? 0 : (gapcnt + 1);
      rd_ready_0 <= is_rd0 && (gapcnt != 1);
      rd_ready_1 <= is_rd1 && (gapcnt != 1);
      wr_valid_0 <= is_wr0 && (wr_idx < exp_beats) && (gapcnt != 3);
      wr_valid_1 <= is_wr1 && (wr_idx < exp_beats) && (gapcnt != 3);
      wr_data_0  <= pack_beat(wr_idx);
      wr_data_1  <= pack_beat(wr_idx);
    end else begin
      rd_ready_0 <= 1'b0; rd_ready_1 <= 1'b0; wr_valid_0 <= 1'b0; wr_valid_1 <= 1'b0;
    end
  end

  always @(posedge clk) begin
    if (!reset) begin
      if (wr_valid_0 && wr_ready_0) wr_idx <= wr_idx + 1;
      if (wr_valid_1 && wr_ready_1) wr_idx <= wr_idx + 1;
      if (rd_valid_0 && rd_ready_0) begin
        sout[sout_n*8+0] <= rd_data_0[7:0];   sout[sout_n*8+1] <= rd_data_0[15:8];
        sout[sout_n*8+2] <= rd_data_0[23:16]; sout[sout_n*8+3] <= rd_data_0[31:24];
        sout[sout_n*8+4] <= rd_data_0[39:32]; sout[sout_n*8+5] <= rd_data_0[47:40];
        sout[sout_n*8+6] <= rd_data_0[55:48]; sout[sout_n*8+7] <= rd_data_0[63:56];
        sout_n <= sout_n + 1;
      end
    end
  end

  // ===================== AXI4 结构性断言 =====================
  integer ar_bursts, aw_bursts, b_ok, rd_beats, wr_beats;
  integer rdwr_overlap, araw_overlap, orphan_w, wlast_bad, wburst_bad, rbeat_bad, stream_bad, mode_leak_bad;
  integer rbeats_cur, wbeats_cur, arlen_cur, awlen_cur;
  // L2b：多 outstanding AR ⇒ 按队列存每笔 AR 的声明长度，R 按序取头对账。
  reg [7:0] arlen_q [0:7];
  integer arq_wp, arq_rp, arq_cnt;
  reg     aw_open;

  always @(posedge clk) begin
    if (!reset) begin
      if (axi_ar_valid && axi_ar_ready) begin
        $display("ARB %08x arlen=%0d", axi_ar_payload_addr, axi_ar_payload_len);
        ar_bursts = ar_bursts + 1;
        arlen_q[arq_wp] = axi_ar_payload_len; arq_wp = (arq_wp + 1) % 8; arq_cnt = arq_cnt + 1;
      end
      if (axi_r_valid && axi_r_ready) begin
        rd_beats = rd_beats + 1; rbeats_cur = rbeats_cur + 1;
        if (axi_r_payload_last !== (rbeats_cur == arlen_q[arq_rp] + 1)) begin
          $display("TBFAIL: R 末拍与 AR 声明长度不符 beat=%0d arlen=%0d last=%0d",
                   rbeats_cur, arlen_q[arq_rp], axi_r_payload_last);
          rbeat_bad = rbeat_bad + 1;
        end
        if (axi_r_payload_last) begin
          arq_rp = (arq_rp + 1) % 8; arq_cnt = arq_cnt - 1; rbeats_cur = 0;
        end
      end
      if (axi_aw_valid && axi_aw_ready) begin
        $display("AWB %08x awlen=%0d", axi_aw_payload_addr, axi_aw_payload_len);
        aw_bursts = aw_bursts + 1; aw_open = 1'b1; awlen_cur = axi_aw_payload_len; wbeats_cur = 0;
      end
      if (axi_w_valid) begin
        if (!aw_open) begin $display("TBFAIL: 出现 orphan W"); orphan_w = orphan_w + 1; end
        if (axi_w_valid && axi_w_ready) begin
          wr_beats = wr_beats + 1; wbeats_cur = wbeats_cur + 1;
          if (axi_w_payload_last !== (wbeats_cur == awlen_cur + 1)) begin
            $display("TBFAIL: W 末拍与 AW 声明长度不符 beat=%0d awlen=%0d", wbeats_cur, awlen_cur);
            wlast_bad = wlast_bad + 1;
          end
        end
      end
      if (axi_b_valid && axi_b_ready) begin
        b_ok = b_ok + 1; aw_open = 1'b0;
        if (wbeats_cur != awlen_cur + 1) begin
          $display("TBFAIL: 一笔写突发只发了 %0d 拍，AW 声明 %0d 拍", wbeats_cur, awlen_cur + 1);
          wburst_bad = wburst_bad + 1;
        end
        wbeats_cur = 0;
      end
      if ((axi_ar_valid && axi_ar_ready) && (axi_aw_valid && axi_aw_ready)) araw_overlap = araw_overlap + 1;
      if ((axi_r_valid  && axi_r_ready)  && (axi_w_valid  && axi_w_ready))  rdwr_overlap = rdwr_overlap + 1;
      if (mode_i == 1 && (axi_aw_valid || axi_w_valid)) mode_leak_bad = mode_leak_bad + 1;
      if (mode_i == 2 && (axi_ar_valid || axi_r_ready))  mode_leak_bad = mode_leak_bad + 1;
      if (mode_i != 1 && (rd_valid_0 || rd_valid_1)) stream_bad = stream_bad + 1;
      if (mode_i != 2 && (wr_ready_0 || wr_ready_1)) stream_bad = stream_bad + 1;
    end
  end

  // ===================== 主流程 =====================
  integer i, fd, tmo, both_seen, tbfail, len_tot;
  integer src0, dst0, src1, dst1, code_exp, len_i;
  reg [31:0] v;
  reg [8*256-1:0] streamin_f, streamout_f;
  reg expect_err;

  initial begin
    axilite_aw_valid = 1'b0; axilite_w_valid = 1'b0; axilite_b_ready = 1'b0;
    axilite_ar_valid = 1'b0; axilite_r_ready = 1'b0;
    axilite_aw_payload_addr = 32'd0; axilite_w_payload_data = 32'd0;
    axilite_aw_payload_prot = 3'd0;  axilite_w_payload_strb = 4'hF;
    axilite_ar_payload_addr = 32'd0; axilite_ar_payload_prot = 3'd0;
    gapcnt = 0; sout_n = 0; wr_idx = 0; exp_beats = 0;
    for (i = 0; i < MAXB*8; i = i + 1) begin sin[i] = 8'h00; sout[i] = 8'h00; end
    ar_bursts = 0; aw_bursts = 0; b_ok = 0; rd_beats = 0; wr_beats = 0;
    rdwr_overlap = 0; araw_overlap = 0; orphan_w = 0; wlast_bad = 0; wburst_bad = 0;
    rbeat_bad = 0; stream_bad = 0; mode_leak_bad = 0;
    rbeats_cur = 0; wbeats_cur = 0; arlen_cur = 0; awlen_cur = 0; aw_open = 1'b0;
    arq_wp = 0; arq_rp = 0; arq_cnt = 0;
    tbfail = 0; both_seen = 0; expect_err = 1'b0; code_exp = 0; abort_after = 200;

    if (!$value$plusargs("JOB=%d", job_i)) job_i = 0;
    if (!$value$plusargs("CH=%d", ch_i))   ch_i = 0;
    if (!$value$plusargs("SRC=%d", src0))  src0 = 1024;
    if (!$value$plusargs("DST=%d", dst0))  dst0 = 16384;
    if (!$value$plusargs("LEN=%d", len0))  len0 = 32;
    if (!$value$plusargs("MODE=%d", mode_i)) mode_i = 0;
    if (!$value$plusargs("SRC1=%d", src1)) src1 = 6144;
    if (!$value$plusargs("DST1=%d", dst1)) dst1 = 28672;
    if (!$value$plusargs("LEN1=%d", len1)) len1 = 32;
    if (!$value$plusargs("N=%d", n_i))     n_i = 6;
    if ($value$plusargs("ABORT_AFTER=%d", abort_after)) begin end
    if ($test$plusargs("EXPECT_ERR")) expect_err = 1'b1;
    if (!$value$plusargs("CODE=%d", code_exp)) code_exp = 0;

    is_rd0 = 1'b0; is_wr0 = 1'b0; is_rd1 = 1'b0; is_wr1 = 1'b0;
    if (job_i == 1) begin is_rd0 = (ch_i == 0); is_rd1 = (ch_i == 1); exp_beats = len0 / 8; end
    if (job_i == 2) begin
      is_wr0 = (ch_i == 0); is_wr1 = (ch_i == 1); exp_beats = len0 / 8;
      if ($value$plusargs("STREAMIN=%s", streamin_f)) begin $readmemh(streamin_f, sin); $display("TB STREAMIN %0s", streamin_f); end
    end

    $display("TB DMAENG JOB=%0d CH=%0d SRC=%0d DST=%0d LEN=%0d MODE=%0d N=%0d ABORT_AFTER=%0d EXPECT_ERR=%0d CODE=%0d",
             job_i, ch_i, src0, dst0, len0, mode_i, n_i, abort_after, expect_err, code_exp);

    repeat (4) @(negedge clk);
    reset = 1'b0;
    @(negedge clk);

    // ---- 全局寄存器自检 ----
    axil_read(A_GBL_ID, v);
    if (v !== 32'h59444D41) begin $display("TBFAIL: GBL_ID=%08x != 59444D41", v); tbfail = tbfail + 1; end
    axil_read(A_GBL_NCH, v);
    if (v !== 32'd2) begin $display("TBFAIL: GBL_NCH=%0d != 2", v); tbfail = tbfail + 1; end
    $display("GBL ID=%08x NCH=%0d", 32'h59444D41, v);

    // ---- 通道 ID 自检 ----
    axil_read(ch_a(0, O_ID), v);
    if (v !== 32'h444D4100) begin $display("TBFAIL: CH0_ID=%08x", v); tbfail = tbfail + 1; end
    axil_read(ch_a(1, O_ID), v);
    if (v !== 32'h444D4101) begin $display("TBFAIL: CH1_ID=%08x", v); tbfail = tbfail + 1; end

    // ================= JOB 0/1/2/3：单通道一笔 =================
    if (job_i <= 3) begin
      ch_clear(ch_i);
      ch_prog(ch_i, src0, dst0, len0, mode_i);
      ch_start(ch_i);
      ch_wait(ch_i);
      repeat (8) @(negedge clk);
      ch_rd(ch_i);
      if (job_i == 3) begin
        if (g_stat[1] !== 1'b1) begin $display("TBFAIL: 非法入参没有 err"); tbfail = tbfail + 1; end
        if (g_stat[0] !== 1'b0) begin $display("TBFAIL: 非法入参竟然 done"); tbfail = tbfail + 1; end
        if (g_bytes !== 32'd0)  begin $display("TBFAIL: 非法入参搬了 %0d 字节", g_bytes); tbfail = tbfail + 1; end
        if (g_code !== code_exp) begin $display("TBFAIL: err_code=%0d 期望 %0d", g_code, code_exp); tbfail = tbfail + 1; end
      end else begin
        if (g_stat[0] !== 1'b1) begin $display("TBFAIL: 没 done"); tbfail = tbfail + 1; end
        if (g_stat[1] !== 1'b0) begin $display("TBFAIL: 意外的 err code=%0d", g_code); tbfail = tbfail + 1; end
        if (g_bytes !== len0)   begin $display("TBFAIL: BYTES=%0d != LEN=%0d", g_bytes, len0); tbfail = tbfail + 1; end
        if (g_cyc == 32'd0)     begin $display("TBFAIL: CYCLES=0（自报拍数没走）"); tbfail = tbfail + 1; end
      end
    end

    // ================= JOB 4：背靠背 N 笔 =================
    if (job_i == 4) begin
      for (i = 0; i < n_i; i = i + 1) begin
        len_i = 32 * (i + 1);
        ch_clear(ch_i);
        ch_prog(ch_i, src0 + i*256, dst0 + i*256, len_i, 0);
        ch_start(ch_i);
        ch_wait(ch_i);
        axil_read(ch_a(ch_i, O_BYTE), v);
        $display("B2B %0d SRC=%0d DST=%0d LEN=%0d BYTES=%0d", i, src0 + i*256, dst0 + i*256, len_i, v);
        if (v !== len_i) begin $display("TBFAIL: B2B %0d BYTES=%0d != %0d", i, v, len_i); tbfail = tbfail + 1; end
        axil_read(ch_a(1 - ch_i, O_STAT), v);
        if (v[0] || v[1]) begin $display("TBFAIL: B2B %0d 另一通道状态被污染 STAT=%08x", i, v); tbfail = tbfail + 1; end
      end
      repeat (8) @(negedge clk);
      ch_rd(ch_i);
    end

    // ================= JOB 5：两通道并发 =================
    if (job_i == 5) begin
      integer done0, done1;
      ch_clear(0); ch_clear(1);
      ch_prog(0, src0, dst0, len0, 0);
      ch_prog(1, src1, dst1, len1, 0);
      ch_start(0);
      ch_start(1);
      done0 = 0; done1 = 0; tmo = 0;
      while (!(done0 && done1)) begin
        axil_read(ch_a(0, O_STAT), v); if (v[0] || v[1]) done0 = 1;
        axil_read(ch_a(1, O_STAT), v); if (v[0] || v[1]) done1 = 1;
        axil_read(A_GBL_BUSY, v);
        if ((v & 32'h3) == 32'h3) both_seen = both_seen + 1;
        tmo = tmo + 1;
        if (tmo > TIMEOUT) begin $display("RESULT: FAIL timeout 并发作业"); $fatal(1, "conc timeout"); end
      end
      repeat (8) @(negedge clk);
      $display("CONC BOTH_BUSY_SAMPLES=%0d", both_seen);
      if (both_seen < 3) begin $display("TBFAIL: 两通道从未同时忙 both_seen=%0d", both_seen); tbfail = tbfail + 1; end
      ch_rd(0);
      if (g_stat[0] !== 1'b1 || g_bytes !== len0 || g_stat[1] !== 1'b0) begin
        $display("TBFAIL: CH0 并发结果不对 done=%0d err=%0d bytes=%0d(期望 %0d)", g_stat[0], g_stat[1], g_bytes, len0);
        tbfail = tbfail + 1;
      end
      ch_rd(1);
      if (g_stat[0] !== 1'b1 || g_bytes !== len1 || g_stat[1] !== 1'b0) begin
        $display("TBFAIL: CH1 并发结果不对 done=%0d err=%0d bytes=%0d(期望 %0d)", g_stat[0], g_stat[1], g_bytes, len1);
        tbfail = tbfail + 1;
      end
    end

    // ================= JOB 6：abort + 同通道再跑一笔 =================
    if (job_i == 6) begin
      ch_clear(ch_i);
      ch_prog(ch_i, src0, dst0, len0, 0);
      ch_start(ch_i);
      repeat (abort_after) @(posedge clk);
      ch_abort(ch_i);
      ch_wait(ch_i);
      axil_read(ch_a(ch_i, O_STAT), v);
      axil_read(ch_a(ch_i, O_BYTE), g_bytes);
      axil_read(ch_a(ch_i, O_CYC ), g_cyc);
      axil_read(ch_a(ch_i, O_CODE), g_code);
      $display("ABORT STAT=%08x BYTES=%0d CYCLES=%0d CODE=%0d", v, g_bytes, g_cyc, g_code);
      if (v[2] !== 1'b1) begin $display("TBFAIL: abort 后 ABRT 未置位"); tbfail = tbfail + 1; end
      if (v[0] !== 1'b0) begin $display("TBFAIL: abort 后 done_sticky 置了"); tbfail = tbfail + 1; end
      if (v[1] !== 1'b0) begin $display("TBFAIL: abort 后 err_sticky 置了"); tbfail = tbfail + 1; end
      if (g_code !== 32'd6) begin $display("TBFAIL: abort 的 err_code=%0d != 6", g_code); tbfail = tbfail + 1; end
      if (g_bytes > len0) begin $display("TBFAIL: abort BYTES=%0d > LEN=%0d", g_bytes, len0); tbfail = tbfail + 1; end
      if ((g_bytes % 128) != 0) begin $display("TBFAIL: abort BYTES=%0d 不是 128 的整数倍（未在块边界停下）", g_bytes); tbfail = tbfail + 1; end
      axil_read(ch_a(ch_i, O_CTRL), v);
      if (v[8] !== 1'b0) begin $display("TBFAIL: abort 后 BUSY 仍为 1"); tbfail = tbfail + 1; end
      // 同通道再跑一笔（新窗口）⇒ 证通道可用、无残留拍串台
      ch_clear(ch_i);
      ch_prog(ch_i, src0, dst0 + 32768, 128, 0);
      ch_start(ch_i);
      ch_wait(ch_i);
      axil_read(ch_a(ch_i, O_BYTE), v);
      $display("ABORT_RERUN BYTES=%0d", v);
      if (v !== 32'd128) begin $display("TBFAIL: abort 后再跑一笔 BYTES=%0d != 128", v); tbfail = tbfail + 1; end
      repeat (8) @(negedge clk);
      ch_rd(ch_i);
    end

    // ================= RD：把收下来的字节落盘 =================
    if (job_i == 1) begin
      if (!$value$plusargs("STREAMOUT=%s", streamout_f)) begin
        $display("TB-ERROR: RD 作业必须给 +STREAMOUT="); $fatal(1, "missing STREAMOUT");
      end
      fd = $fopen(streamout_f, "w");
      if (fd == 0) begin $display("TB-ERROR: 打不开 +STREAMOUT=%0s", streamout_f); $fatal(1, "open"); end
      for (i = 0; i < len0; i = i + 1) $fdisplay(fd, "%02x", sout[i]);
      $fclose(fd);
      $display("TB STREAMOUT %0s (%0d bytes)", streamout_f, len0);
    end

    // ================= 收尾：全局寄存器 =================
    axil_read(A_GBL_BUSY, v); $display("GBL BUSY=%08x", v);
    axil_read(A_GBL_DONE, v); $display("GBL DONE=%08x", v);
    axil_read(A_GBL_ERR,  v); $display("GBL ERR=%08x", v);

    $display("STREAM_RD_BEATS=%0d STREAM_WR_BEATS=%0d", sout_n, wr_idx);
    $display("AR_BURSTS=%0d AW_BURSTS=%0d B_OK=%0d RD_BEATS=%0d WR_BEATS=%0d",
             ar_bursts, aw_bursts, b_ok, rd_beats, wr_beats);
    $display("ORPHAN_W=%0d WLAST_BAD=%0d WBURST_BAD=%0d RBEAT_BAD=%0d", orphan_w, wlast_bad, wburst_bad, rbeat_bad);
    $display("RDWR_OVERLAP=%0d ARAW_OVERLAP=%0d MODE_LEAK_BAD=%0d STREAM_IDLE_BAD=%0d",
             rdwr_overlap, araw_overlap, mode_leak_bad, stream_bad);

    // ================= 结构性判据（不分 job）=================
    if (orphan_w != 0)    tbfail = tbfail + 1;
    if (wlast_bad != 0)   tbfail = tbfail + 1;
    if (wburst_bad != 0)  tbfail = tbfail + 1;
    if (rbeat_bad != 0)   tbfail = tbfail + 1;
    if (rdwr_overlap != 0) begin tbfail = tbfail + 1; $display("TBFAIL: R 与 W 同一拍"); end
    if (araw_overlap != 0) begin tbfail = tbfail + 1; $display("TBFAIL: AR 与 AW 同一拍"); end
    if (mode_leak_bad != 0) begin tbfail = tbfail + 1; $display("TBFAIL: 模式越界"); end
    if (stream_bad != 0) begin tbfail = tbfail + 1; $display("TBFAIL: 非对应模式下流口动了"); end

    if (job_i == 1) begin
      if (aw_bursts != 0 || b_ok != 0) begin tbfail = tbfail + 1; $display("TBFAIL: RD 竟然发了 AW/B"); end
      if (rd_beats * 8 != len0) begin tbfail = tbfail + 1; $display("TBFAIL: RD R 拍数=%0d 期望 %0d", rd_beats*8, len0); end
      if (sout_n * 8 != len0) begin tbfail = tbfail + 1; $display("TBFAIL: RD 推出拍数=%0d", sout_n*8); end
    end
    if (job_i == 2) begin
      if (ar_bursts != 0) begin tbfail = tbfail + 1; $display("TBFAIL: WR 竟然发了 AR"); end
      if (b_ok != aw_bursts) begin tbfail = tbfail + 1; $display("TBFAIL: WR B=%0d != AW=%0d", b_ok, aw_bursts); end
      if (wr_idx != exp_beats) begin tbfail = tbfail + 1; $display("TBFAIL: WR 取走拍数=%0d 期望 %0d", wr_idx, exp_beats); end
      if (sout_n != 0) begin tbfail = tbfail + 1; $display("TBFAIL: WR 模式下 rd_stream 动了"); end
    end
    if (job_i == 3) begin
      if (ar_bursts != 0 || aw_bursts != 0 || b_ok != 0 || rd_beats != 0 || wr_beats != 0 ||
          sout_n != 0 || wr_idx != 0) begin
        tbfail = tbfail + 1;
        $display("TBFAIL: 非法入参竟然动了总线 ar=%0d aw=%0d rdb=%0d wrb=%0d", ar_bursts, aw_bursts, rd_beats, wr_beats);
      end
    end
    if (job_i == 5) begin
      len_tot = len0 + len1;
      if (rd_beats * 8 != len_tot) begin tbfail = tbfail + 1; $display("TBFAIL: 并发 R 拍数=%0d 期望 %0d", rd_beats*8, len_tot); end
      if (wr_beats * 8 != len_tot) begin tbfail = tbfail + 1; $display("TBFAIL: 并发 W 拍数=%0d 期望 %0d", wr_beats*8, len_tot); end
    end

    if (tbfail == 0) begin
      $display("RESULT: PASS");
      $finish;
    end else begin
      $display("RESULT: FAIL tbfail=%0d", tbfail);
      $fatal(1, "DmaEngineTb failed");
    end
  end

  integer wdc;
  initial begin
    for (wdc = 0; wdc < WD_MAX; wdc = wdc + 1) @(posedge clk);
    $display("RESULT: FAIL timeout(global watchdog %0d cycles)", WD_MAX);
    $fatal(1, "DmaEngineTb global timeout");
  end

endmodule
