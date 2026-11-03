// =============================================================================
// NpuResetSyncTb.v —— **NpuResetSync（每域复位同步释放器，强制 cpu 先 / npu 后）的独立两时钟装置**。
//   对应 Y1「NPU 独立时钟域」plan Task **N5** / spec §3-A(d) / §5-G3。纯 Verilog，iverilog -g2012。
//
// ★ 本装置**不碰** SoC 活路径：DUT = `NpuResetSync` 网表，另接 **N3 的活网表 `NpuAxiLiteCdc`**
//   （cpu_clk 从口 ⇄ npu_clk 主口，**既有资产、一字不改**）作为"被复位的 AXI-Lite 桥"。
//   glue / NpuTop / 板级**一律不在场**（RTL 集成是 N5b 的活）。
//
// -----------------------------------------------------------------------------
// 装置结构（两根独立时钟 cpu 100 / npu 37，非整数比）：
//   asyncRst（高有效，异步置位）先保持一段，再在某时刻落下（**异步置位/同步释放**的考验点）：
//     · cpu 侧：`cpuRstn` 经 NpuResetSync 的 2 位移位器 **同步释放**；
//     · npu 侧：`npuRstn` 被"cpu 已出复位"电平门住 ⇒ **必须晚于 `cpuRstn` 释放**（核心契约）。
//   NpuAxiLiteCdc 的两个复位口就接这两个 `*Rstn`（与集成时的接法同形）。
//   · **主机 stub**（cpu 侧，桥的从口驱动方）：等 `cpuRstn` 起来后再稳一段，才发 NW 笔写 + NR 笔读
//     （单 outstanding；用来证明复位后桥仍**功能正确**，也给"伪事务"做参照）。
//   · **NPU 侧从口模型**（npu 侧，桥的主口应答方）：单 outstanding 的寄存器从口；**外加一个危险行为模型**
//     —— 它在"r的复位释放那一刻"若发现 **cpu 侧还没起来（cpuRstn==0）**，就吐一个**伪 BVALID**
//     （模拟"NPU 先于主机起来 ⇒ 首笔响应落在一个仍在复位的主机上"这条 G3 要挡住的危害）。
//
// -----------------------------------------------------------------------------
// 判据（本装置自判 + 闸门 python 复判）：
//   ① **顺序**：`t_npu_rel > t_cpu_rel`（npu 释放**严格晚于** cpu）—— `ORDER_OK/ORDER_BAD`。
//   ② **无伪事务**：cpu 侧 `s_bvalid` **在主机尚无在飞请求时**出现 ⇒ `SPURIOUS++`（应 =0）。
//      另：npu 侧 `m_awvalid/m_wvalid/m_arvalid` 在主机尚无在飞请求时出现 ⇒ 同为伪（应 =0）。
//   ③ **功能仍对**：复位后 NW 笔写 + NR 笔读全部 OKAY、逐元素对账（`COUNTS` / `HOSTR`）。
//   输出事实行：CFG / ORDER t_cpu_rel=.. t_npu_rel=.. delta_ns=.. / HOSTW / NPUW / HOSTR / NPUR /
//               SPURIOUS n=.. / COUNTS / TBFAIL / RESULT: PASS|FAIL
//
// ★ 复位顺序"为什么安全"（能证/不能证，见 RTL 文件头②③④与闸门说明）：在**零延迟 RTL 仿真**里，
//   N3 桥的两套状态机复位后都在 IDLE ⇒ 两种顺序都不会凭空造数据错。本装置的"伪事务"由**危险行为模型**
//   在"npu 先起"时给出 ⇒ 把"顺序"这条**硬契约**做成可观测的**事务级红灯**（反向顺序必红）。
// =============================================================================
`timescale 1ns/1ps

module NpuResetSyncTb;

  localparam integer NW        = 24;             // 复位后合法写笔数
  localparam integer NR        = 12;             // 复位后合法读笔数
  localparam [31:0]  BASE      = 32'hF000C000;   // NPU 寄存器窗基址
  localparam integer NREG      = 32;
  localparam real    RST_DROP_NS = 200.0;        // asyncRst 落下时刻（ns）
  localparam integer SIM_LIMIT_NS = 200000;

  // ===========================================================================
  // 两根独立时钟 + 相位控制
  // ===========================================================================
  reg cpu_clk = 1'b0;
  always #5.0 cpu_clk = ~cpu_clk;               // 100.000 MHz

  reg  same_clk    = 1'b0;
  reg  phase_inv   = 1'b0;
  integer phase_dly_ps = 0;
  reg  npu_clk_i   = 1'b0;
  initial begin
    if (phase_inv) npu_clk_i = 1'b1;
    if (phase_dly_ps > 0) #(phase_dly_ps / 1000.0);
    forever #13.514 npu_clk_i = ~npu_clk_i;     // 37.000 MHz
  end
  wire npu_clk = same_clk ? cpu_clk : npu_clk_i;

  // ===========================================================================
  // DUT：复位同步释放器
  // ===========================================================================
  reg  asyncRst = 1'b1;
  wire cpu_rstn, npu_rstn;
  NpuResetSync dut (
    .io_cpuClk   (cpu_clk),
    .io_npuClk   (npu_clk),
    .io_asyncRst (asyncRst),
    .io_cpuRstn  (cpu_rstn),
    .io_npuRstn  (npu_rstn)
  );

  // ===========================================================================
  // 被复位对象：N3 的 AXI4-Lite 异步桥（既有网表）
  // ===========================================================================
  reg         s_awvalid;  wire s_awready;  reg [31:0] s_awaddr;
  reg         s_wvalid;   wire s_wready;   reg [31:0] s_wdata; reg [3:0] s_wstrb;
  wire        s_bvalid;   reg  s_bready;   wire [1:0]  s_bresp;
  reg         s_arvalid;  wire s_arready;  reg [31:0] s_araddr;
  wire        s_rvalid;   reg  s_rready;   wire [31:0] s_rdata; wire [1:0] s_rresp;

  wire        m_awvalid;  reg  m_awready;  wire [31:0] m_awaddr;
  wire        m_wvalid;   reg  m_wready;   wire [31:0] m_wdata; wire [3:0] m_wstrb;
  reg         m_bvalid;   wire m_bready;   reg  [1:0]  m_bresp;
  wire        m_arvalid;  reg  m_arready;  wire [31:0] m_araddr;
  reg         m_rvalid;   wire m_rready;   reg  [31:0] m_rdata; reg [1:0] m_rresp;

  NpuAxiLiteCdc bridge (
    .io_cpuClk  (cpu_clk), .io_cpuRstn (cpu_rstn),
    .io_npuClk  (npu_clk), .io_npuRstn (npu_rstn),

    .io_axilite_aw_valid        (s_awvalid),
    .io_axilite_aw_ready        (s_awready),
    .io_axilite_aw_payload_addr (s_awaddr),
    .io_axilite_aw_payload_prot (3'b000),
    .io_axilite_w_valid         (s_wvalid),
    .io_axilite_w_ready         (s_wready),
    .io_axilite_w_payload_data  (s_wdata),
    .io_axilite_w_payload_strb  (s_wstrb),
    .io_axilite_b_valid         (s_bvalid),
    .io_axilite_b_ready         (s_bready),
    .io_axilite_b_payload_resp  (s_bresp),
    .io_axilite_ar_valid        (s_arvalid),
    .io_axilite_ar_ready        (s_arready),
    .io_axilite_ar_payload_addr (s_araddr),
    .io_axilite_ar_payload_prot (3'b000),
    .io_axilite_r_valid         (s_rvalid),
    .io_axilite_r_ready         (s_rready),
    .io_axilite_r_payload_data  (s_rdata),
    .io_axilite_r_payload_resp  (s_rresp),

    .io_npu_axilite_aw_valid        (m_awvalid),
    .io_npu_axilite_aw_ready        (m_awready),
    .io_npu_axilite_aw_payload_addr (m_awaddr),
    .io_npu_axilite_aw_payload_prot (),
    .io_npu_axilite_w_valid         (m_wvalid),
    .io_npu_axilite_w_ready         (m_wready),
    .io_npu_axilite_w_payload_data  (m_wdata),
    .io_npu_axilite_w_payload_strb  (m_wstrb),
    .io_npu_axilite_b_valid         (m_bvalid),
    .io_npu_axilite_b_ready         (m_bready),
    .io_npu_axilite_b_payload_resp  (m_bresp),
    .io_npu_axilite_ar_valid        (m_arvalid),
    .io_npu_axilite_ar_ready        (m_arready),
    .io_npu_axilite_ar_payload_addr (m_araddr),
    .io_npu_axilite_ar_payload_prot (),
    .io_npu_axilite_r_valid         (m_rvalid),
    .io_npu_axilite_r_ready         (m_rready),
    .io_npu_axilite_r_payload_data  (m_rdata),
    .io_npu_axilite_r_payload_resp  (m_rresp)
  );

  // ===========================================================================
  // NPU 侧从口模型（npu 域）+ 危险行为模型
  // ===========================================================================
  reg [31:0] rf [0:NREG-1];
  reg        aw_got, w_got, busy, bvalid;
  reg [31:0] awaddr, wdata;  reg [3:0] wstrb;
  reg        ar_hold, rvalid;  reg [31:0] araddr, rdata;
  reg        hazard;                       // npu 先于主机释放 ⇒ 吐伪 B
  reg        haz_seen;                     // "释放那一刻 cpu 还没起来" 的锁存
  integer    npu_wr_seq, npu_rd_seq;
  integer    k;

  // 危险检测：npu 复位**释放的那一刻**若 cpu 侧还没起来（cpu_rstn==0）⇒ 记一笔
  always @(posedge npu_rstn) if (cpu_rstn === 1'b0) haz_seen <= 1'b1;

  assign m_awready = !aw_got && !busy;
  assign m_wready  = !w_got  && !busy;
  assign m_arready = !ar_hold && !rvalid;
  assign m_bvalid  = bvalid;
  assign m_bresp   = 2'b00;
  assign m_rvalid  = rvalid;
  assign m_rdata   = rdata;
  assign m_rresp   = 2'b00;

  reg [31:0] w_merged;
  always @(*) begin
    w_merged = rf[awaddr[6:2]];
    if (wstrb[0]) w_merged[7:0]   = wdata[7:0];
    if (wstrb[1]) w_merged[15:8]  = wdata[15:8];
    if (wstrb[2]) w_merged[23:16] = wdata[23:16];
    if (wstrb[3]) w_merged[31:24] = wdata[31:24];
  end

  // npuRstn 的上升沿（上升沿检测用寄存器）
  always @(posedge npu_clk) begin
    if (!npu_rstn) begin
      aw_got <= 0; w_got <= 0; busy <= 0; bvalid <= 0;
      ar_hold <= 0; rvalid <= 0; hazard <= 0;
      npu_wr_seq <= 0; npu_rd_seq <= 0;
      for (k = 0; k < NREG; k = k + 1) rf[k] <= 32'h0;
    end else begin
      // ---- 危险行为模型：本域刚出复位、而 cpu 侧还没起来 ⇒ 起一笔"无请求"的伪响应 ----
      if (!hazard && haz_seen) begin
        hazard <= 1'b1;
        busy   <= 1'b1;                        // 借 busy 通道吐一个伪 B（下拍 bvalid=1）
        $display("HAZARD npu released before cpu (t=%0.3f ns)", $realtime);
      end

      if (m_awvalid && m_awready) begin awaddr <= m_awaddr; aw_got <= 1'b1; end
      if (m_wvalid  && m_wready ) begin wdata  <= m_wdata;  wstrb  <= m_wstrb; w_got <= 1'b1; end

      if (busy) begin
        if (!bvalid) bvalid <= 1'b1;                        // 举 B
        else if (m_bready) begin bvalid <= 1'b0; busy <= 1'b0; end
      end else if (aw_got && w_got) begin
        if (awaddr[13:0] < 14'h0080) rf[awaddr[6:2]] <= w_merged;
        $display("NPUW %0d %08x %08x %01x", npu_wr_seq, awaddr, wdata, wstrb);
        npu_wr_seq <= npu_wr_seq + 1;
        aw_got <= 1'b0; w_got <= 1'b0; busy <= 1'b1;
      end

      if (m_arvalid && m_arready) begin
        araddr <= m_araddr; ar_hold <= 1'b1;
        $display("NPUR %0d %08x", npu_rd_seq, m_araddr);
        npu_rd_seq <= npu_rd_seq + 1;
      end
      if (ar_hold) begin
        rdata <= (araddr[13:0] < 14'h0080) ? rf[araddr[6:2]] : (32'hBAD00000 ^ araddr);
        rvalid <= 1'b1; ar_hold <= 1'b0;
      end
      if (rvalid && m_rready) rvalid <= 1'b0;
    end
  end

  // ===========================================================================
  // cpu 域：主机 stub（驱动在 negedge、判据在 posedge）
  // ===========================================================================
  integer host_wr_cnt, host_rd_cnt;
  integer tbfail;
  reg     host_outstanding;               // 有在飞的写请求（用于"伪 B"判据）
  reg [31:0] rdata_c;

  task fail_to(input [8*64-1:0] why);
    begin $display("RESULT: FAIL timeout %0s", why); $finish; end
  endtask

  task axi_write(input [31:0] addr, input [31:0] data, input [3:0] strb);
    integer t; reg ok;
    begin
      @(negedge cpu_clk);
      s_awvalid=1'b1; s_awaddr=addr; s_wvalid=1'b1; s_wdata=data; s_wstrb=strb; s_bready=1'b0;
      host_outstanding = 1'b1;
      t=0; ok=1'b0;
      while (!ok) begin
        @(posedge cpu_clk);
        if (s_awready && s_wready) ok=1'b1;
        else begin t=t+1; if (t>4000) fail_to("aw/w ready"); end
      end
      @(negedge cpu_clk); s_awvalid=1'b0; s_wvalid=1'b0;
      s_bready=1'b1;
      t=0; ok=1'b0;
      while (!ok) begin
        @(posedge cpu_clk);
        if (s_bvalid) ok=1'b1;
        else begin t=t+1; if (t>4000) fail_to("b valid"); end
      end
      if (s_bresp !== 2'b00) begin tbfail=tbfail+1; $display("TBFAIL: BRESP=%b addr=%08x", s_bresp, addr); end
      @(negedge cpu_clk); s_bready=1'b0; host_outstanding=1'b0;
      host_wr_cnt = host_wr_cnt + 1;
    end
  endtask

  task axi_read(input [31:0] addr);
    integer t; reg ok;
    begin
      @(negedge cpu_clk);
      s_arvalid=1'b1; s_araddr=addr; s_rready=1'b0;
      host_outstanding = 1'b1;
      t=0; ok=1'b0;
      while (!ok) begin
        @(posedge cpu_clk);
        if (s_arready) ok=1'b1;
        else begin t=t+1; if (t>4000) fail_to("ar ready"); end
      end
      @(negedge cpu_clk); s_arvalid=1'b0;
      s_rready=1'b1;
      t=0; ok=1'b0;
      while (!ok) begin
        @(posedge cpu_clk);
        if (s_rvalid) begin rdata_c=s_rdata; ok=1'b1; end
        else begin t=t+1; if (t>4000) fail_to("r valid"); end
      end
      if (s_rresp !== 2'b00) begin tbfail=tbfail+1; $display("TBFAIL: RRESP=%b addr=%08x", s_rresp, addr); end
      @(negedge cpu_clk); s_rready=1'b0; host_outstanding=1'b0;
      $display("HOSTR %0d %08x %08x", host_rd_cnt, addr, rdata_c);
      host_rd_cnt = host_rd_cnt + 1;
    end
  endtask

  // ---- 顺序 / 伪事务 观测 ----
  real t_cpu_rel, t_npu_rel;
  integer spurious;
  reg cpu_rel_seen, npu_rel_seen;
  real t_now;

  initial begin t_cpu_rel = -1.0; t_npu_rel = -1.0; end
  always @(posedge cpu_rstn) begin t_cpu_rel = $realtime; cpu_rel_seen = 1'b1; end
  always @(posedge npu_rstn) begin t_npu_rel = $realtime; npu_rel_seen = 1'b1; end

  // 伪事务：cpu 侧 B 在主机无在飞请求时出现（cpu 域，posedge 采样）
  always @(posedge cpu_clk) begin
    if (cpu_rstn === 1'b1 && s_bvalid === 1'b1 && host_outstanding === 1'b0) begin
      spurious = spurious + 1;
    end
    // npu 侧请求在主机无在飞请求时出现（桥自己不该凭空发请求）
    if (cpu_rstn === 1'b1 && host_outstanding === 1'b0 &&
        (m_awvalid === 1'b1 || m_wvalid === 1'b1 || m_arvalid === 1'b1)) begin
      spurious = spurious + 1;
    end
  end

  // ===========================================================================
  // 主流程
  // ===========================================================================
  integer i, seed;
  integer latmin;
  initial begin
    s_awvalid=0; s_awaddr=0; s_wvalid=0; s_wdata=0; s_wstrb=0; s_bready=0;
    s_arvalid=0; s_araddr=0; s_rready=0;
    host_wr_cnt=0; host_rd_cnt=0; tbfail=0; spurious=0;
    host_outstanding=0; cpu_rel_seen=0; npu_rel_seen=0;
    haz_seen = 1'b0;

    if ($test$plusargs("SAME_CLK"))  same_clk  = 1'b1;
    if ($test$plusargs("PHASE_INV")) phase_inv = 1'b1;
    if ($value$plusargs("PHASE_DLY_PS=%d", phase_dly_ps)) ; else phase_dly_ps = 0;

    $display("CFG same_clk=%0d npu_clk=%0s phase_inv=%0d phase_dly_ps=%0d rst_drop_ns=%0.1f NW=%0d NR=%0d",
             same_clk, same_clk ? "100.000MHz(via cpu_clk)" : "37.000MHz",
             phase_inv, phase_dly_ps, RST_DROP_NS, NW, NR);

    // ---- 异步置位保持，再在某时刻落下（同步释放考验点）----
    #(RST_DROP_NS);
    asyncRst = 1'b0;

    // ---- 等两域释放都被观测到，再判顺序 ----
    wait (cpu_rel_seen == 1'b1 && npu_rel_seen == 1'b1);
    // 顺序判据
    $display("ORDER t_cpu_rel=%0.3f t_npu_rel=%0.3f delta_ns=%0.3f",
             t_cpu_rel, t_npu_rel, (t_npu_rel - t_cpu_rel));
    if (!(t_npu_rel > t_cpu_rel))
      $display("ORDER_BAD: npu 释放不晚于 cpu（t_npu=%0.3f <= t_cpu=%0.3f）", t_npu_rel, t_cpu_rel);

    // ---- 主机：cpu 起来后再稳一段，才发合法事务 ----
    wait (cpu_rstn == 1'b1);
    repeat (30) @(posedge cpu_clk);

    for (i = 0; i < NW; i = i + 1) axi_write(BASE + 4*i, 32'hA5A50000 + i, 4'hF);
    for (i = 0; i < NR; i = i + 1) axi_read (BASE + 4*i);

    repeat (20) @(negedge cpu_clk);
    $display("SPURIOUS n=%0d", spurious);
    $display("COUNTS host_wr=%0d host_rd=%0d npu_wr=%0d npu_rd=%0d", host_wr_cnt, host_rd_cnt, npu_wr_seq, npu_rd_seq);

    if (tbfail == 0 && spurious == 0 && host_wr_cnt == NW && host_rd_cnt == NR &&
        npu_wr_seq == NW && npu_rd_seq == NR && (t_npu_rel > t_cpu_rel))
      $display("RESULT: PASS");
    else
      $display("RESULT: FAIL tbfail=%0d spurious=%0d host_wr=%0d host_rd=%0d npu_wr=%0d npu_rd=%0d order=%s",
               tbfail, spurious, host_wr_cnt, host_rd_cnt, npu_wr_seq, npu_rd_seq,
               (t_npu_rel > t_cpu_rel) ? "OK" : "BAD");
    $finish;
  end

  initial begin
    #SIM_LIMIT_NS;
    $display("RESULT: FAIL timeout(global watchdog %0d ns)", SIM_LIMIT_NS);
    $finish;
  end

endmodule
