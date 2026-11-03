// =============================================================================
// NpuMemCdcTb.v —— **NpuMemCdc（cpu_clk ⇄ npu_clk 的 AXI4 内存主口异步桥）的独立两时钟装置**。
//   对应 Y1「NPU 独立时钟域」plan Task **N4** / spec §3-A(b) / §4.4 / §5-G2。纯 Verilog，iverilog -g2012。
//
// ★ 本装置**不碰** SoC 活路径：只有 DUT（`NpuMemCdc` 网表）+ 本文件里的两个模型 ——
//   · **npu_clk 侧**：一台**手摇 AXI4 主口**（模拟 NPU 内存主口 `DdrMaster` 的对外形状：单 outstanding、
//     有界突发 <= 16 拍、32B 对齐、先 AW 后 W / 先 AR 后 R）。它按 stim 脚本逐条执行
//     **块拷贝 / 带状写（含部分 wstrb）/ 回读** 三类作业，并被 `MM_*` 观察器抓下每一笔事实。
//   · **cpu_clk 侧**：`rtl_test/AxiMemModel.v`（行为级 AXI4 内存模型，**既有资产、一字不改**）
//     —— 它自己校验"突发 <= 16 拍 / 首址 32B 对齐 / 字节数 8 的倍数 / 不越界"，违规一律 `$fatal`。
//   两者中间夹一台 **停滞注入器（stall shim）**：把 DUT 的 cpu 侧主口到内存模型的请求握手
//   （aw/ar/w 的 valid）按**确定性伪随机**节流 ⇒ **变长从口延迟**（G2 要的那一维）。
//   glue / NpuTop / 板级 / DDR3Bridge **一律不在场**（RTL 集成是 N4 之后的事）。
//
// -----------------------------------------------------------------------------
// 装置结构：
//   · 两根独立时钟：cpu_clk = 100.000 MHz（半周期 5.000 ns）、npu_clk = 37.000 MHz（半周期 13.514 ns）。
//     `+SAME_CLK` 把 npu_clk 并到 cpu_clk（相位/频率零差异）⇒ 分离"CDC 问题"与"AXI 协议问题"。
//     `+PHASE_INV` 让 npu_clk 初值取 1（半周期相移）；`+PHASE_DLY_PS=<ps>` 让它晚这么多 ps 起振。
//   · **npu 侧主口**（本文件）：stim 逐条执行，**单 outstanding**（一笔写完/读完才发下一笔）；
//     AW 与 W 分两步举（先 AW 等 awready、再逐拍 W —— 与 `DdrMaster` 的纪律 (a) 同姿），
//     读是先 AR 等 arready、再逐拍收 R。驱动在 negedge、判据在 posedge 采样（与 N3 / DdrCopyTb 同口径）。
//   · **cpu 侧 stall shim**：`+STALLMAX=n` 时，对 aw/ar/w 的**请求握手**做 0..n 拍的确定性伪随机停滞
//     （LFSR，种子 +SEED）；idle 一拍就随机关一下 ⇒ 从口延迟**变长**，压 CDC 的背压通路。
//     响应（b/r）**原样透传**（变长靠"推迟请求被受理"实现，不需要缓冲响应）。★ 两个半门成对：
//       `mem.valid = dut.valid && grant` 且 `dut.ready = mem.ready && grant`（缺一即错拍）。
//
// -----------------------------------------------------------------------------
// stim 契约（+STIMFILE=<file>，每行 7 个十六进制字段）：
//   `<op> <addr> <dst> <bytes> <bpb> <strb> <pat>`
//     op=0 WRITE：在 [addr, addr+bytes) 上按 `pbyte()` 模式、以 `strb` 逐字节写；分 `bytes/(bpb*8)` 笔突发
//     op=1 READ ：读 [addr, addr+bytes)，逐拍把数据打成 `RD` 事实行（闸门按顺序对黄金）
//     op=2 COPY ：把 [addr, addr+bytes) 读进块缓冲、再整块写到 [dst, dst+bytes)（整字 strb=FF）
//   约束（装置自检 + 闸门同口径）：addr/dst 32B 对齐；`bytes` 是 `bpb*8` 的整数倍；bpb∈1..16；
//   区间落在已建模内存内且不越界；id 取 `job_idx & 4'hF`（**测 id 过桥**：B/R 回来的 id 必须相等）。
//
// 输出事实行（闸门按行对账，不盲信本装置的 PASS）：
//   CFG / STIM / AWB <addr> awlen=<n> / ARB <addr> arlen=<n> / BOK <addr> <bid> / BAD <why> /
//   RD <addr> <k> <data> / WBEAT <addr> <k> / COUNTS awb= arb= bok= wbeats= rbeats= /
//   TBFAIL <why> / RESULT: PASS|FAIL ；内存模型另打 `MEM rd= wr= bursts= maxburst=`。
//
// ★ 复位口径（本装置专属，不是整机口径）：两域复位**同时**释放（cpuRstn = npuRstn = ~reset）。
//   AxiMemModel 收 `reset`（同步高有效）。桥的五套状态机复位后都在 IDLE ⇒ 释放竞态造不出事务。
//   整机"按域同步释放"是 N5 的活。
// =============================================================================
`timescale 1ns/1ps

module NpuMemCdcTb;

  localparam integer MAXJOB      = 512;         // stim 作业数上限
  localparam integer TIMEOUT     = 40000;       // 单次等待的最长 npu/cpu 拍数（超时即响亮报红）
  localparam integer SIM_LIMIT_NS= 6000000;     // 全局看门狗（ns）
  localparam integer MEMSZ       = 32768;       // 内存模型字节数（须与 AxiMemModel 例化一致）
  localparam integer BUFSZ       = 1024;        // 块缓冲拍数（字节 8192；装置上限见下）

  // ===========================================================================
  // 两根独立时钟 + 相位控制（与 N3 装置逐字同口径）
  // ===========================================================================
  reg cpu_clk = 1'b0;
  always #5.0 cpu_clk = ~cpu_clk;               // 周期 10.0 ns ⇒ 100.000 MHz

  reg  same_clk    = 1'b0;
  reg  phase_inv   = 1'b0;
  integer phase_dly_ps = 0;
  reg  npu_clk_i   = 1'b0;
  initial begin
    if (phase_inv) npu_clk_i = 1'b1;
    if (phase_dly_ps > 0) #(phase_dly_ps / 1000.0);
    forever #13.514 npu_clk_i = ~npu_clk_i;     // 周期 27.028 ns ⇒ 37.000 MHz（100/37 = 2.7027…）
  end
  wire npu_clk = same_clk ? cpu_clk : npu_clk_i;

  reg  reset   = 1'b1;                          // 高有效总复位
  wire cpu_rstn = ~reset;
  wire npu_rstn = ~reset;

  // ===========================================================================
  // npu_clk 侧：手摇 AXI4 主口（驱动）
  // ===========================================================================
  reg         m_awvalid;  wire        m_awready;
  reg  [27:0] m_awaddr;   reg  [3:0]  m_awid;   reg [7:0] m_awlen; reg [2:0] m_awsize;
  reg  [1:0]  m_awburst;  reg  [3:0]  m_awcache; reg [2:0] m_awprot;
  reg         m_wvalid;   wire        m_wready;
  reg  [63:0] m_wdata;    reg  [7:0]  m_wstrb;  reg       m_wlast;
  wire        m_bvalid;   reg         m_bready;  wire [3:0] m_bid;  wire [1:0] m_bresp;
  reg         m_arvalid;  wire        m_arready;
  reg  [27:0] m_araddr;   reg  [3:0]  m_arid;   reg [7:0] m_arlen; reg [2:0] m_arsize;
  reg  [1:0]  m_arburst;  reg  [3:0]  m_arcache; reg [2:0] m_arprot;
  wire        m_rvalid;   reg         m_rready;  wire [63:0] m_rdata; wire [3:0] m_rid;
  wire [1:0]  m_rresp;    wire        m_rlast;

  // ===========================================================================
  // DUT：AXI4 内存主口异步桥（npu_clk 从口 ⇄ cpu_clk 主口）
  // ===========================================================================
  wire        c_awvalid;  wire        c_awready;
  wire [27:0] c_awaddr;   wire [3:0]  c_awid;  wire [7:0] c_awlen; wire [2:0] c_awsize;
  wire [1:0]  c_awburst;  wire [3:0]  c_awcache; wire [2:0] c_awprot;
  wire        c_wvalid;   wire        c_wready;
  wire [63:0] c_wdata;    wire [7:0]  c_wstrb;  wire      c_wlast;
  wire        c_bvalid;   wire        c_bready;
  wire        c_arvalid;  wire        c_arready;
  wire [27:0] c_araddr;   wire [3:0]  c_arid;  wire [7:0] c_arlen; wire [2:0] c_arsize;
  wire [1:0]  c_arburst;  wire [3:0]  c_arcache; wire [2:0] c_arprot;
  wire        c_rvalid;   wire        c_rready;

  // 内存模型侧的全部连线（**先声明后用**；响应载荷原样透传到 DUT 的 cpu 侧主口）
  wire        mem_aw_ready, mem_w_ready, mem_ar_ready;
  wire        mem_b_valid, mem_r_valid;
  wire        mem_b_ready, mem_r_ready;
  wire [63:0] mem_r_data;
  wire [3:0]  mem_b_id, mem_r_id;
  wire [1:0]  mem_b_resp, mem_r_resp;
  wire        mem_r_last;

  NpuMemCdc dut (
    .cpuClk (cpu_clk),
    .cpuRstn(cpu_rstn),
    .npuClk (npu_clk),
    .npuRstn(npu_rstn),

    .npuMem_aw_valid        (m_awvalid), .npuMem_aw_ready       (m_awready),
    .npuMem_aw_payload_addr (m_awaddr),  .npuMem_aw_payload_id   (m_awid),
    .npuMem_aw_payload_len  (m_awlen),   .npuMem_aw_payload_size (m_awsize),
    .npuMem_aw_payload_burst(m_awburst), .npuMem_aw_payload_cache(m_awcache),
    .npuMem_aw_payload_prot (m_awprot),
    .npuMem_w_valid         (m_wvalid),  .npuMem_w_ready        (m_wready),
    .npuMem_w_payload_data  (m_wdata),   .npuMem_w_payload_strb (m_wstrb),
    .npuMem_w_payload_last  (m_wlast),
    .npuMem_b_valid         (m_bvalid),  .npuMem_b_ready        (m_bready),
    .npuMem_b_payload_id    (m_bid),     .npuMem_b_payload_resp (m_bresp),
    .npuMem_ar_valid        (m_arvalid), .npuMem_ar_ready       (m_arready),
    .npuMem_ar_payload_addr (m_araddr),  .npuMem_ar_payload_id   (m_arid),
    .npuMem_ar_payload_len  (m_arlen),   .npuMem_ar_payload_size (m_arsize),
    .npuMem_ar_payload_burst(m_arburst), .npuMem_ar_payload_cache(m_arcache),
    .npuMem_ar_payload_prot (m_arprot),
    .npuMem_r_valid         (m_rvalid),  .npuMem_r_ready        (m_rready),
    .npuMem_r_payload_data  (m_rdata),   .npuMem_r_payload_id   (m_rid),
    .npuMem_r_payload_resp  (m_rresp),   .npuMem_r_payload_last (m_rlast),

    .cpuMem_aw_valid        (c_awvalid), .cpuMem_aw_ready       (c_awready),
    .cpuMem_aw_payload_addr (c_awaddr),  .cpuMem_aw_payload_id   (c_awid),
    .cpuMem_aw_payload_len  (c_awlen),   .cpuMem_aw_payload_size (c_awsize),
    .cpuMem_aw_payload_burst(c_awburst), .cpuMem_aw_payload_cache(c_awcache),
    .cpuMem_aw_payload_prot (c_awprot),
    .cpuMem_w_valid         (c_wvalid),  .cpuMem_w_ready        (c_wready),
    .cpuMem_w_payload_data  (c_wdata),   .cpuMem_w_payload_strb (c_wstrb),
    .cpuMem_w_payload_last  (c_wlast),
    .cpuMem_b_valid         (c_bvalid),  .cpuMem_b_ready        (c_bready),
    .cpuMem_b_payload_id    (mem_b_id),  .cpuMem_b_payload_resp (mem_b_resp),
    .cpuMem_ar_valid        (c_arvalid), .cpuMem_ar_ready       (c_arready),
    .cpuMem_ar_payload_addr (c_araddr),  .cpuMem_ar_payload_id   (c_arid),
    .cpuMem_ar_payload_len  (c_arlen),   .cpuMem_ar_payload_size (c_arsize),
    .cpuMem_ar_payload_burst(c_arburst), .cpuMem_ar_payload_cache(c_arcache),
    .cpuMem_ar_payload_prot (c_arprot),
    .cpuMem_r_valid         (c_rvalid),  .cpuMem_r_ready        (c_rready),
    .cpuMem_r_payload_data  (mem_r_data), .cpuMem_r_payload_id  (mem_r_id),
    .cpuMem_r_payload_resp  (mem_r_resp), .cpuMem_r_payload_last(mem_r_last)
  );

  // ===========================================================================
  // cpu_clk 侧：停滞注入器（stall shim）—— 请求握手确定性伪随机节流
  // ===========================================================================
  reg  [15:0] s_aw, s_ar, s_w;
  reg  [31:0] lfsr_aw, lfsr_ar, lfsr_w;
  integer     stallmax;
  reg  [31:0] seed_init;

  wire g_aw = (s_aw == 16'd0);       // 1 = 本拍放行
  wire g_ar = (s_ar == 16'd0);
  wire g_w  = (s_w  == 16'd0);

  // 内存模型侧：请求握手经 stall shim 节流（响应原样透传，见上）
  wire        mem_aw_valid = c_awvalid && g_aw;
  wire        mem_w_valid  = c_wvalid  && g_w;
  wire        mem_ar_valid = c_arvalid && g_ar;

  assign c_awready = mem_aw_ready && g_aw;
  assign c_wready  = mem_w_ready  && g_w;
  assign c_arready = mem_ar_ready && g_ar;

  // 响应向：原样透传（不需要缓冲）
  assign c_bvalid = mem_b_valid;
  assign mem_b_ready = c_bready;
  assign c_rvalid = mem_r_valid;
  assign mem_r_ready = c_rready;

  always @(posedge cpu_clk) begin
    if (!cpu_rstn) begin
      s_aw <= 16'd0; s_ar <= 16'd0; s_w <= 16'd0;
      lfsr_aw <= seed_init ^ 32'hA5A5_1001;
      lfsr_ar <= seed_init ^ 32'h5A5A_2002;
      lfsr_w  <= seed_init ^ 32'h3C3C_3003;
    end else begin
      if (s_aw > 16'd0) s_aw <= s_aw - 16'd1;
      else begin lfsr_aw <= (lfsr_aw * 32'd1103515245 + 32'd12345); s_aw <= lfsr_aw % (stallmax + 1); end
      if (s_ar > 16'd0) s_ar <= s_ar - 16'd1;
      else begin lfsr_ar <= (lfsr_ar * 32'd1103515245 + 32'd12345); s_ar <= lfsr_ar % (stallmax + 1); end
      if (s_w  > 16'd0) s_w  <= s_w  - 16'd1;
      else begin lfsr_w  <= (lfsr_w  * 32'd1103515245 + 32'd12345); s_w  <= lfsr_w  % (stallmax + 1); end
    end
  end

  // ===========================================================================
  // cpu_clk 侧：AXI4 内存模型（既有资产；预载/导出/统计/合规 $fatal 都在它里面）
  // ===========================================================================
  AxiMemModel #(.MEMSZ(MEMSZ), .ADDR_W(28)) mem0 (
    .clk(cpu_clk), .reset(reset),
    .axi_aw_valid(mem_aw_valid), .axi_aw_ready(mem_aw_ready),
    .axi_aw_payload_addr(c_awaddr), .axi_aw_payload_id(c_awid),
    .axi_aw_payload_len(c_awlen), .axi_aw_payload_size(c_awsize),
    .axi_aw_payload_burst(c_awburst), .axi_aw_payload_cache(c_awcache),
    .axi_aw_payload_prot(c_awprot),
    .axi_w_valid(mem_w_valid), .axi_w_ready(mem_w_ready),
    .axi_w_payload_data(c_wdata), .axi_w_payload_strb(c_wstrb),
    .axi_w_payload_last(c_wlast),
    .axi_b_valid(mem_b_valid), .axi_b_ready(mem_b_ready),
    .axi_b_payload_id(mem_b_id), .axi_b_payload_resp(mem_b_resp),
    .axi_ar_valid(mem_ar_valid), .axi_ar_ready(mem_ar_ready),
    .axi_ar_payload_addr(c_araddr), .axi_ar_payload_id(c_arid),
    .axi_ar_payload_len(c_arlen), .axi_ar_payload_size(c_arsize),
    .axi_ar_payload_burst(c_arburst), .axi_ar_payload_cache(c_arcache),
    .axi_ar_payload_prot(c_arprot),
    .axi_r_valid(mem_r_valid), .axi_r_ready(mem_r_ready),
    .axi_r_payload_data(mem_r_data), .axi_r_payload_id(mem_r_id),
    .axi_r_payload_resp(mem_r_resp), .axi_r_payload_last(mem_r_last)
  );

  // ===========================================================================
  // 块缓冲 + 计数 + 事实
  // ===========================================================================
  reg [63:0] blkbuf [0:BUFSZ-1];
  integer    awb, arb, bok, wbeats, rbeats, tbfail;
  integer    tmo;

  // 模式函数（**唯一的真源**；闸门 python 按同一公式独立算黄金）
  //   pbyte(a,k,j,pat) = pat ^ a[7:0] ^ a[15:8] ^ (k*8'h11) ^ (j*8'h59)
  function [7:0] pbyte;
    input [27:0] a; input [7:0] k; input [7:0] j; input [7:0] pat;
    begin
      pbyte = pat ^ a[7:0] ^ a[15:8] ^ (k * 8'h11) ^ (j * 8'h59);
    end
  endfunction

  task fail_timeout(input [8*64-1:0] why);
    begin
      $display("TBFAIL: timeout %0s", why);
      $display("RESULT: FAIL timeout");
      $finish;
    end
  endtask

  // ---- 写一笔突发（AW -> W 逐拍 -> B），data 由 pbyte 模式生成 ----
  task wr_pat_burst(input [27:0] a, input [7:0] beats, input [7:0] strb, input [7:0] pat,
                    input [3:0] idv);
    integer k, j, t; reg ok; reg [63:0] d;
    begin
      @(negedge npu_clk);
      m_awvalid=1; m_awaddr=a; m_awid=idv; m_awlen=beats-8'd1; m_awsize=3'd3;
      m_awburst=2'b01; m_awcache=4'h0; m_awprot=3'h0;
      t=0; ok=0;
      while(!ok) begin @(posedge npu_clk); if(m_awready) ok=1;
        else begin t=t+1; if(t>TIMEOUT) fail_timeout("WR awready"); end end
      awb = awb + 1; $display("AWB %08x awlen=%0d", a, beats-8'd1);
      @(negedge npu_clk); m_awvalid=0;
      for (k=0;k<beats;k=k+1) begin
        d = 64'h0;
        for (j=0;j<8;j=j+1) d[j*8 +: 8] = pbyte(a + k*8, k[7:0], j[7:0], pat);
        @(negedge npu_clk);
        m_wvalid=1; m_wdata=d; m_wstrb=strb; m_wlast=(k==beats-1);
        t=0; ok=0;
        while(!ok) begin @(posedge npu_clk); if(m_wready) ok=1;
          else begin t=t+1; if(t>TIMEOUT) fail_timeout("WR wready"); end end
        wbeats = wbeats + 1; $display("WBEAT %08x %0d", a, k);
        @(negedge npu_clk); m_wvalid=0;
      end
      @(negedge npu_clk); m_bready=1;
      t=0; ok=0;
      while(!ok) begin @(posedge npu_clk); if(m_bvalid) ok=1;
        else begin t=t+1; if(t>TIMEOUT) fail_timeout("WR bvalid"); end end
      if (m_bid !== idv) begin tbfail=tbfail+1; $display("BAD BID got=%0d want=%0d addr=%08x", m_bid, idv, a); end
      if (m_bresp !== 2'b00) begin tbfail=tbfail+1; $display("BAD BRESP=%b addr=%08x", m_bresp, a); end
      bok = bok + 1; $display("BOK %08x %0d", a, m_bid);
      @(negedge npu_clk); m_bready=0;
    end
  endtask

  // ---- 写一笔突发（AW -> W 逐拍 -> B），data 取自块缓冲 blkbuf[base..] ----
  task wr_buf_burst(input [27:0] a, input [7:0] beats, input integer base, input [3:0] idv);
    integer k, t; reg ok;
    begin
      @(negedge npu_clk);
      m_awvalid=1; m_awaddr=a; m_awid=idv; m_awlen=beats-8'd1; m_awsize=3'd3;
      m_awburst=2'b01; m_awcache=4'h0; m_awprot=3'h0;
      t=0; ok=0;
      while(!ok) begin @(posedge npu_clk); if(m_awready) ok=1;
        else begin t=t+1; if(t>TIMEOUT) fail_timeout("BUF awready"); end end
      awb = awb + 1; $display("AWB %08x awlen=%0d", a, beats-8'd1);
      @(negedge npu_clk); m_awvalid=0;
      for (k=0;k<beats;k=k+1) begin
        @(negedge npu_clk);
        m_wvalid=1; m_wdata=blkbuf[base+k]; m_wstrb=8'hFF; m_wlast=(k==beats-1);
        t=0; ok=0;
        while(!ok) begin @(posedge npu_clk); if(m_wready) ok=1;
          else begin t=t+1; if(t>TIMEOUT) fail_timeout("BUF wready"); end end
        wbeats = wbeats + 1; $display("WBEAT %08x %0d", a, k);
        @(negedge npu_clk); m_wvalid=0;
      end
      @(negedge npu_clk); m_bready=1;
      t=0; ok=0;
      while(!ok) begin @(posedge npu_clk); if(m_bvalid) ok=1;
        else begin t=t+1; if(t>TIMEOUT) fail_timeout("BUF bvalid"); end end
      if (m_bid !== idv) begin tbfail=tbfail+1; $display("BAD BID got=%0d want=%0d addr=%08x", m_bid, idv, a); end
      if (m_bresp !== 2'b00) begin tbfail=tbfail+1; $display("BAD BRESP=%b addr=%08x", m_bresp, a); end
      bok = bok + 1; $display("BOK %08x %0d", a, m_bid);
      @(negedge npu_clk); m_bready=0;
    end
  endtask

  // ---- 读一笔突发（AR -> R 逐拍），数据落 blkbuf[base+k]，逐拍打 RD 事实行 ----
  task rd_burst(input [27:0] a, input [7:0] beats, input integer base, input [3:0] idv);
    integer k, t; reg ok;
    begin
      @(negedge npu_clk);
      m_arvalid=1; m_araddr=a; m_arid=idv; m_arlen=beats-8'd1; m_arsize=3'd3;
      m_arburst=2'b01; m_arcache=4'h0; m_arprot=3'h0;
      t=0; ok=0;
      while(!ok) begin @(posedge npu_clk); if(m_arready) ok=1;
        else begin t=t+1; if(t>TIMEOUT) fail_timeout("RD arready"); end end
      arb = arb + 1; $display("ARB %08x arlen=%0d", a, beats-8'd1);
      @(negedge npu_clk); m_arvalid=0;
      @(negedge npu_clk); m_rready=1;
      k=0;
      while (k < beats) begin
        @(posedge npu_clk);
        if (m_rvalid && m_rready) begin
          blkbuf[base+k] = m_rdata;
          if (m_rid !== idv) begin tbfail=tbfail+1; $display("BAD RID got=%0d want=%0d addr=%08x", m_rid, idv, a); end
          if (m_rresp !== 2'b00) begin tbfail=tbfail+1; $display("BAD RRESP=%b addr=%08x", m_rresp, a); end
          // rlast 必须恰好落在本笔最后一拍（RLAST 是本桥的承重载荷之一）
          if (m_rlast !== (k==(beats-1))) begin tbfail=tbfail+1; $display("BAD RLAST=%b k=%0d beats=%0d addr=%08x", m_rlast, k, beats, a); end
          $display("RD %08x %0d %016x", a, k, m_rdata);
          rbeats = rbeats + 1;
          k = k + 1;
        end else begin
          t=t+1; if(t>TIMEOUT) fail_timeout("RD rvalid"); end
      end
      @(negedge npu_clk); m_rready=0;
    end
  endtask

  // ===========================================================================
  // stim 文件 + 主流程
  // ===========================================================================
  reg  [8*256-1:0] stimfile, line;
  integer          fd, code, i, b, njob, seed;
  reg  [31:0]      j_op [0:MAXJOB-1], j_addr [0:MAXJOB-1], j_dst [0:MAXJOB-1];
  reg  [31:0]      j_bytes [0:MAXJOB-1], j_bpb [0:MAXJOB-1], j_strb [0:MAXJOB-1], j_pat [0:MAXJOB-1];
  reg  [31:0]      f0, f1, f2, f3, f4, f5, f6;
  integer          nburst, bstep, base;

  initial begin
    // ---- 初始化所有驱动（防 X 传播）----
    m_awvalid=0; m_awaddr=0; m_awid=0; m_awlen=0; m_awsize=3; m_awburst=2'b01; m_awcache=0; m_awprot=0;
    m_wvalid=0;  m_wdata=0;  m_wstrb=0;  m_wlast=0;
    m_bready=0;
    m_arvalid=0; m_araddr=0; m_arid=0; m_arlen=0; m_arsize=3; m_arburst=2'b01; m_arcache=0; m_arprot=0;
    m_rready=0;
    awb=0; arb=0; bok=0; wbeats=0; rbeats=0; tbfail=0;
    njob=0; stallmax=0; seed=32'h12345678; seed_init=32'h12345678;
    for (i=0;i<BUFSZ;i=i+1) blkbuf[i]=64'h0;

    if ($test$plusargs("SAME_CLK"))  same_clk  = 1'b1;
    if ($test$plusargs("PHASE_INV")) phase_inv = 1'b1;
    if ($value$plusargs("PHASE_DLY_PS=%d", phase_dly_ps)) ; else phase_dly_ps = 0;
    if ($value$plusargs("STALLMAX=%d", stallmax)) ; else stallmax = 0;
    if ($value$plusargs("SEED=%d", seed)) ; else seed = 32'h12345678;
    seed_init = seed;
    if (stallmax < 0) stallmax = 0;

    if (!$value$plusargs("STIMFILE=%s", stimfile)) begin
      $display("TB-ERROR: 缺 +STIMFILE="); $display("RESULT: FAIL no stimfile"); $finish;
    end
    fd = $fopen(stimfile, "r");
    if (fd == 0) begin
      $display("TB-ERROR: 打不开 stim 文件 %0s", stimfile); $display("RESULT: FAIL cannot open stimfile"); $finish;
    end
    code = $fgets(line, fd);
    while (code != 0) begin
      f0=0; f1=0; f2=0; f3=0; f4=0; f5=0; f6=0;
      if ($sscanf(line, "%h %h %h %h %h %h %h", f0, f1, f2, f3, f4, f5, f6) == 7) begin
        if (njob >= MAXJOB) begin
          $display("TB-ERROR: 作业数超过 %0d", MAXJOB); $display("RESULT: FAIL too many jobs"); $finish;
        end
        j_op[njob]=f0; j_addr[njob]=f1; j_dst[njob]=f2; j_bytes[njob]=f3;
        j_bpb[njob]=f4; j_strb[njob]=f5; j_pat[njob]=f6;
        // 装置侧自检（与闸门同口径；不合法就响亮报红，不许静默）
        if (j_op[njob] > 2) begin $display("TB-ERROR: 非法 op=%0d", j_op[njob]); $display("RESULT: FAIL bad op"); $finish; end
        if (j_bpb[njob] < 1 || j_bpb[njob] > 16) begin $display("TB-ERROR: bpb 越界 %0d", j_bpb[njob]); $display("RESULT: FAIL bad bpb"); $finish; end
        if ((j_bytes[njob] % (j_bpb[njob]*8)) != 0) begin $display("TB-ERROR: bytes 不是 bpb*8 的整数倍"); $display("RESULT: FAIL bad bytes"); $finish; end
        if ((j_bytes[njob]/8) > BUFSZ) begin $display("TB-ERROR: 作业字节数超过块缓冲"); $display("RESULT: FAIL too big"); $finish; end
        njob = njob + 1;
      end
      code = $fgets(line, fd);
    end
    $fclose(fd);

    $display("CFG same_clk=%0d npu_clk=%0s stallmax=%0d phase_inv=%0d phase_dly_ps=%0d seed=%0d",
             same_clk, same_clk ? "100.000MHz(via cpu_clk)" : "37.000MHz",
             stallmax, phase_inv, phase_dly_ps, seed);
    $display("STIM n=%0d", njob);
    if (njob == 0) begin $display("RESULT: FAIL empty stim"); $finish; end

    // ---- 复位：两域同时释放 ----
    repeat (8) @(negedge cpu_clk);
    reset = 1'b0;
    repeat (2) @(negedge cpu_clk);

    // ---- 逐条执行 ----
    for (i=0;i<njob;i=i+1) begin
      bstep = j_bpb[i]*8;
      nburst = j_bytes[i] / bstep;
      base = 0;
      if (j_op[i] == 0) begin
        // WRITE：只写，逐笔突发
        for (b=0;b<nburst;b=b+1)
          wr_pat_burst(j_addr[i] + b*bstep, j_bpb[i][7:0], j_strb[i][7:0], j_pat[i][7:0], i[3:0]);
      end else if (j_op[i] == 1) begin
        // READ：只读，逐笔突发（数据落 blkbuf，逐拍打 RD）
        for (b=0;b<nburst;b=b+1) begin
          rd_burst(j_addr[i] + b*bstep, j_bpb[i][7:0], b*j_bpb[i], i[3:0]);
        end
      end else begin
        // COPY：先把整块读进 blkbuf，再把 blkbuf 整块写出去
        for (b=0;b<nburst;b=b+1)
          rd_burst(j_addr[i] + b*bstep, j_bpb[i][7:0], b*j_bpb[i], i[3:0]);
        for (b=0;b<nburst;b=b+1)
          wr_buf_burst(j_dst[i] + b*bstep, j_bpb[i][7:0], b*j_bpb[i], i[3:0]);
      end
    end

    repeat (8) @(negedge npu_clk);
    $display("COUNTS awb=%0d arb=%0d bok=%0d wbeats=%0d rbeats=%0d", awb, arb, bok, wbeats, rbeats);
    if (tbfail == 0) $display("RESULT: PASS");
    else             $display("RESULT: FAIL tbfail=%0d", tbfail);
    $finish;
  end

  // 兜底：不收敛也停在确定时刻并报红
  initial begin
    #SIM_LIMIT_NS;
    $display("RESULT: FAIL timeout(global watchdog %0d ns)", SIM_LIMIT_NS);
    $finish;
  end

endmodule
