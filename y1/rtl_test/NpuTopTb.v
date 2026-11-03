// NpuTopTb.v —— y1「主机寄存器层 + DDR 块拷贝主口」集成体（gen/NpuTop.v）的端到端装置。
// 纯 Verilog（iverilog -g2012），与 rtl_test/HostRegsTb.v / DdrCopyTb.v 同口径：
//   · 主机侧：**手摇的 AxiLite4 主机**（写/读握手代码逐段复用自 HostRegsTb.v，不重造）；
//   · 内存侧：rtl_test/AxiMemModel.v 当 AXI4 从口（预载/导出/统计都在模型里）。
//
// 装置做的事（全部走 DUT 的**真端口**，不 force、不 poke 内部寄存器）—— 模拟一台真实主机：
//   1) 读 ID(0x30) 必须 == 0x594E5031（从口活着的证明）；
//   2) 写 SRC_ADDR/DST_ADDR/IMG_W/IMG_H/C_IN，再回读逐条对账（证明"主机确实把寄存器写进去了"）；
//   3) 采样顶层 irq —— **启动之前必须为 0**（IRQ 纪律之一）；
//   4) 写 CTRL.start（bit0 自清）—— 长度由 DUT 从特征图维度派生，装置不喂长度；
//   5) 轮询 STATUS(0x04)：等 done_sticky(bit0) 或 err(bit1)（带**轮询次数超时** + 全局看门狗）；
//   6) 采样顶层 irq —— **完成后必须为 1**，并统计它保持了多少拍（电平证据）；再写 CTRL.soft_reset
//      确认 IRQ/err 被清（证明不是"卡死在高"，而是"电平 + 显式确认"）；
//   7) 收尾打印事实行（DONE_SEEN/ERR_SEEN/STATUS_*/IRQ_*），最后 `RESULT: PASS|FAIL`；
//      FAIL 时 $fatal ⇒ vvp 非 0 退出。
//
// ★ 装置**不**自己判"拷贝对不对"（字节对账归闸门 python 的活）：它只给"主机看到了什么"的事实，
//   内存字节级的正/负判定由 tools/run_nputop_ab.sh 拿 +DUMPFILE 导出的镜像独立做。
//
// plusargs：
//   +SRC=<dec> +DST=<dec> +IMG_W=<dec> +IMG_H=<dec> +C_IN=<dec>   （十进制）
//   +MEMFILE=<file> +DUMPFILE=<file>                             （转给内存模型，它自己取）
//   +EXPECT_ERR   可选：本次必须由**主机**观察到 err（非法长度负对照用）。
//
// ★ 采样口径（与 HostRegsTb 同）：所有驱动在 negedge、所有握手判据在 posedge 采样。
`timescale 1ns/1ps

module NpuTopTb;

  localparam integer TIMEOUT   = 200000;    // 轮询 STATUS 的次数上限（1 MiB 级拷贝也远够）
  localparam integer WD_MAX    = 3000000;   // 全局看门狗（拍）
  localparam [31:0]  ID_CONST  = 32'h594E5031;   // "YNP1"

  reg clk   = 1'b0;
  reg reset = 1'b1;
  always #5 clk = ~clk;

  // ---- AxiLite4 主机侧信号（复用 HostRegsTb 的握手代码）----
  reg         m_awvalid;  wire        m_awready;
  reg  [31:0] m_awaddr;   reg  [2:0]  m_awprot;
  reg         m_wvalid;   wire        m_wready;
  reg  [31:0] m_wdata;    reg  [3:0]  m_wstrb;
  wire        m_bvalid;   reg         m_bready;   wire [1:0] m_bresp;
  reg         m_arvalid;  wire        m_arready;
  reg  [31:0] m_araddr;   reg  [2:0]  m_arprot;
  wire        m_rvalid;   reg         m_rready;   wire [31:0] m_rdata;  wire [1:0] m_rresp;

  // ---- 顶层 irq（被观测对象）----
  wire irq;

  // ---- AXI4 连线（DUT 主口 <-> AxiMemModel 从口；同名一根线两端）----
  wire        axi_aw_valid,  axi_aw_ready;
  wire [27:0] axi_aw_payload_addr;
  wire [3:0]  axi_aw_payload_id;
  wire [7:0]  axi_aw_payload_len;
  wire [2:0]  axi_aw_payload_size;
  wire [1:0]  axi_aw_payload_burst;
  wire [3:0]  axi_aw_payload_cache;
  wire [2:0]  axi_aw_payload_prot;

  wire        axi_w_valid,   axi_w_ready;
  wire [63:0] axi_w_payload_data;
  wire [7:0]  axi_w_payload_strb;
  wire        axi_w_payload_last;

  wire        axi_b_valid,   axi_b_ready;
  wire [3:0]  axi_b_payload_id;
  wire [1:0]  axi_b_payload_resp;

  wire        axi_ar_valid,  axi_ar_ready;
  wire [27:0] axi_ar_payload_addr;
  wire [3:0]  axi_ar_payload_id;
  wire [7:0]  axi_ar_payload_len;
  wire [2:0]  axi_ar_payload_size;
  wire [1:0]  axi_ar_payload_burst;
  wire [3:0]  axi_ar_payload_cache;
  wire [2:0]  axi_ar_payload_prot;

  wire        axi_r_valid,   axi_r_ready;
  wire [63:0] axi_r_payload_data;
  wire [3:0]  axi_r_payload_id;
  wire [1:0]  axi_r_payload_resp;
  wire        axi_r_payload_last;

  // ---- 被测集成体 ----
  NpuTop dut (
    .axilite_aw_valid(m_awvalid), .axilite_aw_ready(m_awready),
    .axilite_aw_payload_addr(m_awaddr), .axilite_aw_payload_prot(m_awprot),
    .axilite_w_valid(m_wvalid), .axilite_w_ready(m_wready),
    .axilite_w_payload_data(m_wdata), .axilite_w_payload_strb(m_wstrb),
    .axilite_b_valid(m_bvalid), .axilite_b_ready(m_bready), .axilite_b_payload_resp(m_bresp),
    .axilite_ar_valid(m_arvalid), .axilite_ar_ready(m_arready),
    .axilite_ar_payload_addr(m_araddr), .axilite_ar_payload_prot(m_arprot),
    .axilite_r_valid(m_rvalid), .axilite_r_ready(m_rready),
    .axilite_r_payload_data(m_rdata), .axilite_r_payload_resp(m_rresp),
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
    .irq(irq),
    .clk(clk), .reset(reset)
  );

  // ---- 内存模型（MEMSZ 必须与闸门里的 MEMSZ 一致）----
  localparam integer MEMSZ = 786432;   // 768 KiB：容得下 src 区 + dst 区 + 前后邻居
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

  // ---- IRQ 仪器（电平证据）：统计整场仿真里 irq 高了多少拍、起了几次沿 ----
  integer irq_high_cycles;
  integer irq_rises;
  reg     irq_prev = 1'b0;
  always @(posedge clk) begin
    if (!reset) begin
      if (irq) irq_high_cycles = irq_high_cycles + 1;
      if (irq && !irq_prev) irq_rises = irq_rises + 1;
      irq_prev <= irq;
    end
  end

  // ---- 统计 ----
  integer tbfail;

  // ======================= 手摇 AxiLite4 主机（复用 HostRegsTb）=======================
  task fail_timeout(input [8*64-1:0] why);
    begin
      $display("RESULT: FAIL timeout %0s", why);
      $fatal(1, "NpuTopTb timeout");
    end
  endtask

  task axi_write(input [31:0] addr, input [31:0] data);
    integer t; reg ok;
    begin
      @(negedge clk);
      m_awvalid = 1'b1; m_awaddr = addr; m_awprot = 3'b000;
      m_wvalid  = 1'b1; m_wdata  = data; m_wstrb  = 4'hF;
      m_bready  = 1'b0;
      t = 0; ok = 1'b0;
      while (!ok) begin
        @(posedge clk);
        if (m_awready && m_wready) ok = 1'b1;
        else begin t = t + 1; if (t > 200) fail_timeout("aw/w ready"); end
      end
      @(negedge clk);
      m_awvalid = 1'b0; m_wvalid = 1'b0; m_bready = 1'b1;
      t = 0; ok = 1'b0;
      while (!ok) begin
        @(posedge clk);
        if (m_bvalid) ok = 1'b1;
        else begin t = t + 1; if (t > 200) fail_timeout("b valid"); end
      end
      if (m_bresp !== 2'b00) begin
        tbfail = tbfail + 1;
        $display("TBFAIL: write BRESP=%b addr=%08x", m_bresp, addr);
      end
      @(negedge clk);
      m_bready = 1'b0;
    end
  endtask

  task axi_read(input [31:0] addr, output [31:0] data);
    integer t; reg ok;
    begin
      @(negedge clk);
      m_arvalid = 1'b1; m_araddr = addr; m_arprot = 3'b000;
      m_rready  = 1'b0;
      t = 0; ok = 1'b0;
      while (!ok) begin
        @(posedge clk);
        if (m_arready) ok = 1'b1;
        else begin t = t + 1; if (t > 200) fail_timeout("ar ready"); end
      end
      @(negedge clk);
      m_arvalid = 1'b0; m_rready = 1'b1;
      t = 0; ok = 1'b0;
      while (!ok) begin
        @(posedge clk);
        if (m_rvalid) begin data = m_rdata; ok = 1'b1; end
        else begin t = t + 1; if (t > 200) fail_timeout("r valid"); end
      end
      if (m_rresp !== 2'b00) begin
        tbfail = tbfail + 1;
        $display("TBFAIL: read RRESP=%b addr=%08x", m_rresp, addr);
      end
      @(negedge clk);
      m_rready = 1'b0;
    end
  endtask

  // 轮询 STATUS(0x04)，直到 done_sticky(bit0) 或 err(bit1) 抬起来。带次数超时，绝不挂死。
  task poll_status(output dseen, output eseen);
    integer k; reg [31:0] st;
    begin
      dseen = 1'b0; eseen = 1'b0; k = 0;
      while (!dseen && !eseen) begin
        axi_read(32'h00000004, st);
        if ((st & 32'h1) === 32'h1) dseen = 1'b1;
        if ((st & 32'h2) === 32'h2) eseen = 1'b1;
        k = k + 1;
        if (k > TIMEOUT) fail_timeout("poll STATUS");
      end
      $display("STATUS_TERM %08x", st);
    end
  endtask

  // ============================== 主流程 ==============================
  reg [31:0] src_v, dst_v, w_v, h_v, c_v;
  reg [31:0] rv, rb;
  reg        expect_err;
  reg        irq_pre, irq_post, irq_ack;
  reg        done_seen, err_seen;
  integer    i;

  initial begin
    // 初始化主机信号（避免 X 传播）
    m_awvalid = 1'b0; m_awaddr = 32'h0; m_awprot = 3'b0;
    m_wvalid  = 1'b0; m_wdata  = 32'h0; m_wstrb  = 4'h0;
    m_bready  = 1'b0;
    m_arvalid = 1'b0; m_araddr = 32'h0; m_arprot = 3'b0;
    m_rready  = 1'b0;
    tbfail = 0; irq_high_cycles = 0; irq_rises = 0;
    expect_err = 1'b0; done_seen = 1'b0; err_seen = 1'b0;
    irq_pre = 1'b0; irq_post = 1'b0; irq_ack = 1'b0;

    if (!$value$plusargs("SRC=%d",   src_v)) begin $display("TB-ERROR: missing +SRC=");   $fatal(1,"SRC");   end
    if (!$value$plusargs("DST=%d",   dst_v)) begin $display("TB-ERROR: missing +DST=");   $fatal(1,"DST");   end
    if (!$value$plusargs("IMG_W=%d", w_v))   begin $display("TB-ERROR: missing +IMG_W="); $fatal(1,"IMG_W"); end
    if (!$value$plusargs("IMG_H=%d", h_v))   begin $display("TB-ERROR: missing +IMG_H="); $fatal(1,"IMG_H"); end
    if (!$value$plusargs("C_IN=%d",  c_v))   begin $display("TB-ERROR: missing +C_IN=");  $fatal(1,"C_IN");  end
    if ($test$plusargs("EXPECT_ERR")) expect_err = 1'b1;

    $display("TB NPU SRC=%0d DST=%0d IMG_W=%0d IMG_H=%0d C_IN=%0d LEN_EXPECT=%0d EXPECT_ERR=%0d",
             src_v, dst_v, w_v, h_v, c_v, w_v * h_v * c_v, expect_err);

    // 复位（同步端口、高有效；DUT 的这两个寄存器块用异步复位，此处脉冲对两者都适用）
    repeat (4) @(negedge clk);
    reset = 1'b0;
    @(negedge clk);

    // ---- 1) ID 常数（从口活着的证明）----
    axi_read(32'h00000030, rv);
    $display("ID_READ %08x", rv);
    if (rv !== ID_CONST) begin tbfail = tbfail + 1; $display("TBFAIL: ID_READ %08x != %08x", rv, ID_CONST); end

    // ---- 2) 起手 STATUS / CTRL 全 0（未启动、无事件）----
    axi_read(32'h00000004, rv); $display("STATUS_PRE %08x", rv);
    if (rv !== 32'h0) begin tbfail = tbfail + 1; $display("TBFAIL: STATUS_PRE 非 0 = %08x", rv); end
    axi_read(32'h00000000, rv); $display("CTRL_PRE %08x", rv);
    if (rv !== 32'h0) begin tbfail = tbfail + 1; $display("TBFAIL: CTRL_PRE 非 0 = %08x", rv); end

    // ---- 3) IRQ 启动之前必须为 0 ----
    irq_pre = irq;
    $display("PRE_IRQ=%0d", irq_pre);

    // ---- 4) 编程（含回读对账）----
    axi_write(32'h00000020, src_v);   // SRC_ADDR
    axi_write(32'h00000024, dst_v);   // DST_ADDR
    axi_write(32'h00000008, w_v);     // IMG_W
    axi_write(32'h0000000C, h_v);     // IMG_H
    axi_write(32'h00000010, c_v);     // C_IN
    axi_read(32'h00000020, rb); if (rb !== src_v) begin tbfail=tbfail+1; $display("TBFAIL: SRC_ADDR rb=%08x != %08x", rb, src_v); end
    axi_read(32'h00000024, rb); if (rb !== dst_v) begin tbfail=tbfail+1; $display("TBFAIL: DST_ADDR rb=%08x != %08x", rb, dst_v); end
    axi_read(32'h00000008, rb); if (rb !== w_v)   begin tbfail=tbfail+1; $display("TBFAIL: IMG_W rb=%08x != %08x", rb, w_v); end
    axi_read(32'h0000000C, rb); if (rb !== h_v)   begin tbfail=tbfail+1; $display("TBFAIL: IMG_H rb=%08x != %08x", rb, h_v); end
    axi_read(32'h00000010, rb); if (rb !== c_v)   begin tbfail=tbfail+1; $display("TBFAIL: C_IN rb=%08x != %08x", rb, c_v); end
    if (tbfail == 0) $display("RB_OK");

    // ---- 5) 启动（CTRL.bit0，自清；长度由 DUT 从维度派生）----
    axi_write(32'h00000000, 32'h00000001);

    // ---- 6) 轮询 STATUS 等完成 ----
    poll_status(done_seen, err_seen);
    $display("DONE_SEEN=%0d ERR_SEEN=%0d", done_seen, err_seen);

    axi_read(32'h00000004, rv); $display("STATUS_POST %08x", rv);
    axi_read(32'h00000000, rv); $display("CTRL_POST %08x", rv);

    // ---- 7) IRQ 完成后必须为 1；保持 50 拍观察（电平证据）----
    irq_post = irq;
    $display("POST_IRQ=%0d", irq_post);
    repeat (50) @(negedge clk);
    $display("IRQ_HELD_AFTER_50=%0d", irq);

    // ---- 8) 显式确认：写 CTRL.soft_reset，IRQ 必须落下（证明不是卡死在高）----
    axi_write(32'h00000000, 32'h00000002);   // soft_reset = bit1
    repeat (4) @(negedge clk);
    irq_ack = irq;
    $display("IRQ_AFTER_ACK=%0d", irq_ack);
    axi_read(32'h00000004, rv); $display("STATUS_AFTER_ACK %08x", rv);

    $display("IRQ_HIGH_CYCLES=%0d IRQ_RISES=%0d", irq_high_cycles, irq_rises);

    // ---- 判据 ----
    if (irq_pre !== 1'b0) begin tbfail = tbfail + 1; $display("TBFAIL: 启动前 IRQ 就为 1（不该）"); end
    if (irq_post !== 1'b1) begin tbfail = tbfail + 1; $display("TBFAIL: 完成后 IRQ 不是 1（电平没锁住）"); end
    if (irq_ack  !== 1'b0) begin tbfail = tbfail + 1; $display("TBFAIL: soft_reset 后 IRQ 没落下（卡死在高）"); end

    if (expect_err) begin
      if (err_seen && !done_seen && tbfail == 0) begin
        $display("RESULT: PASS");
        $finish;
      end else begin
        $display("RESULT: FAIL 期待 err 且无 done，实际 err=%0d done=%0d tbfail=%0d", err_seen, done_seen, tbfail);
        $fatal(1, "NpuTopTb expected err");
      end
    end else begin
      if (done_seen && !err_seen && tbfail == 0) begin
        $display("RESULT: PASS");
        $finish;
      end else begin
        $display("RESULT: FAIL 期待 done 且无 err，实际 done=%0d err=%0d tbfail=%0d", done_seen, err_seen, tbfail);
        $fatal(1, "NpuTopTb failed");
      end
    end
  end

  // 兜底：仿真不收敛时也报红退出（非 0），别让闸门挂死。
  integer wd;
  initial begin
    for (wd = 0; wd < WD_MAX; wd = wd + 1) @(posedge clk);
    $display("RESULT: FAIL timeout(global watchdog %0d cycles)", WD_MAX);
    $fatal(1, "NpuTopTb global timeout");
  end

endmodule
