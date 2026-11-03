// =============================================================================
// NpuAxiLiteCdcTb.v —— **NpuAxiLiteCdc（cpu_clk ⇄ npu_clk 的 AXI4-Lite 异步桥）的独立两时钟装置**。
//   对应 Y1「NPU 独立时钟域」plan Task **N3** / spec §3-A(a) / §5-G2。**纯 Verilog**，走 iverilog -g2012。
//
// ★ 本装置**不碰** SoC 活路径：只有 DUT（`NpuAxiLiteCdc` 网表）+ 本文件里的两个模型 ——
//   cpu_clk（100 MHz）侧的**手摇 AXI4-Lite 主机**，npu_clk（37 MHz，与 100 非整数比 2.7027…）侧的
//   **简单 AXI4-Lite 寄存器从口**。glue / NpuTop / 板级**一律不在场**（RTL 集成是 N3 之后的事）。
//
// -----------------------------------------------------------------------------
// 装置结构：
//   · 两根独立时钟：cpu_clk = 100.000 MHz（半周期 5.000 ns）、npu_clk = 37.000 MHz（半周期 13.514 ns）。
//     `+SAME_CLK` 把 npu_clk 并到 cpu_clk（**相位/频率零差异**）⇒ 用来把"CDC 问题"与"AXI 协议问题"
//     分开：同钟下若还红，那是桥的 AXI 语义坏了，与跨域无关。
//     ★ 相位（"两种时钟相位"）：`+PHASE_INV` 让 npu_clk 初值取 1（= 相对 0 相位平移半个 npu 周期）；
//       `+PHASE_DLY_PS=<ps>` 让 npu_clk 晚这么多 ps 起振（任意亚周期相位）。两者可叠加。
//   · 主机（cpu 域）：stim 文件逐条执行（`0 <addr> <data> <strb>` 写 / `1 <addr>` 读），**单笔未完成**
//     （与 glue 汇聚点同口径：一笔写完/读完才发下一笔）。`+WAITMAX=<n>` 在**每次**举 valid 之前、
//     以及举 BREADY/RREADY 之前插入 0..n 拍**确定性伪随机**空闲（LFSR）⇒ 变长反压覆盖。
//     所有驱动在 negedge、所有握手判据在 posedge 采样（与 HostRegsTb / NpuTwoClockTb 同口径）。
//   · 从口（npu 域）：32 个 32bit 寄存器（窗内偏移 0x00..0x7C；**逐字节**按 wstrb 合并：
//     byte i = wstrb[i] ? wdata[i] : 原值）。
//     窗内偏移 ≥ 0x80 的访问：读恒返回 `32'hBAD00000 ^ addr`（**整根 32bit 地址**的指纹 —— 地址
//     只要错一位就变），写被忽略（仍以 OKAY 应答）。地址口径 = `0xF000_C000 | off`（glue 的 NPU 窗
//     基址），从口只看低 14 位 ⇒ 地址高位也必须**原样跨域**才对得上。
//     AW 与 W 是**两条独立通道**：从口各记一个 flag，两件到齐才提交 —— 这正好压住"桥把 AW/W 串错
//     顺序也不会丢"这一条。提交后延迟 `LAT`（npu 拍）才举 BVALID；`LAT` 在 `LATMIN..LATMAX` 之间
//     **逐笔轮转**（±1 递增回绕）⇒ **变长响应延迟**覆盖（含 LATMIN==LATMAX 的恒值档）。
//     读同理（AR → 延迟 → RVALID）。从口**不**在 B/R 未消费前收下一笔（single-outstanding）。
//
// -----------------------------------------------------------------------------
// plusargs：
//   +STIMFILE=<file>   激励文件（必需）
//   +LATMIN= +LATMAX=  从口响应延迟（npu 拍）区间，默认 1 / 7（逐笔轮转；LATMIN==LATMAX 即恒值档）
//   +WAITMAX=          主机侧反压注入上限（0 = 全程背靠背），默认 0
//   +SAME_CLK          把 npu_clk 并到 cpu_clk（100/100 ⇒ 与跨域无关的 AXI 协议对照）
//   +PHASE_INV         npu_clk 初值取 1（相对 0 相位平移半个 npu 周期）
//   +PHASE_DLY_PS=     npu_clk 起振延迟（ps；与 +PHASE_INV 可叠加，覆盖任意亚周期相位）
//   +SEED=             主机侧伪随机反压序列的种子（默认 0x12345678；同一 plusargs ⇒ 逐字节可复现）
// 输出事实行（闸门按行对账，不盲信本装置的 PASS）：
//   CFG / STIM / NPU_W / NPU_R / HOST_R / COUNTS / TBFAIL / RESULT: PASS|FAIL
//   `NPU_W`/`NPU_R` 在 **npu 域**打印（= 桥那侧真收到了什么），`HOST_R` 在 **cpu 域**打印
//   （= 主机经桥看到了什么）。前两者与 stim 逐元素对账 ⇒"无丢失/无重复/无乱序"；
//   `HOST_R` 与闸门 python 的黄金逐字节对账 ⇒ 字节级正确。
//
// ★ 复位口径（本装置专属，不是整机口径）：两域复位**同时**释放（`cpu_rstn = npu_rstn = ~reset`）。
//   桥的两个状态机复位后都处于 IDLE ⇒ 释放竞态造不出事务；**整机**的"按域同步释放"是 N5 的活。
// =============================================================================
`timescale 1ns/1ps

module NpuAxiLiteCdcTb;

  // ---- 用例常量 ----
  localparam integer MAXSTIM       = 1024;      // stim 条数上限
  localparam integer TIMEOUT       = 4000;      // 单次等待的最长 cpu 拍数（超时即响亮报红）
  localparam integer SIM_LIMIT_NS  = 4000000;   // 全局看门狗（ns）
  localparam [31:0]  NPU_BASE      = 32'hF000C000;  // NPU 寄存器窗基址（与 glue 同）
  localparam integer NREG          = 32;        // 从口寄存器个数（窗内偏移 0x00..0x7C）

  // ===========================================================================
  // 两根独立时钟 + 相位控制
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
  // DUT：AXI4-Lite 异步桥（cpu_clk 从口 ⇄ npu_clk 主口）
  // ===========================================================================
  // ---- cpu_clk 侧（从口；端口名沿用 NpuTop.axilite_*）----
  reg         s_awvalid;  wire        s_awready;
  reg  [31:0] s_awaddr;   reg  [2:0]  s_awprot;
  reg         s_wvalid;   wire        s_wready;
  reg  [31:0] s_wdata;    reg  [3:0]  s_wstrb;
  wire        s_bvalid;   reg         s_bready;   wire [1:0]  s_bresp;
  reg         s_arvalid;  wire        s_arready;
  reg  [31:0] s_araddr;   reg  [2:0]  s_arprot;
  wire        s_rvalid;   reg         s_rready;   wire [31:0] s_rdata;  wire [1:0] s_rresp;

  // ---- npu_clk 侧（主口；接下面的寄存器从口模型）----
  wire        m_awvalid;  reg         m_awready;
  wire [31:0] m_awaddr;   wire [2:0]  m_awprot;
  wire        m_wvalid;   reg         m_wready;
  wire [31:0] m_wdata;    wire [3:0]  m_wstrb;
  reg         m_bvalid;   wire        m_bready;   reg  [1:0]  m_bresp;
  wire        m_arvalid;  reg         m_arready;
  wire [31:0] m_araddr;   wire [2:0]  m_arprot;
  reg         m_rvalid;   wire        m_rready;   reg  [31:0] m_rdata;  reg  [1:0] m_rresp;

  NpuAxiLiteCdc dut (
    .io_cpuClk                   (cpu_clk),
    .io_cpuRstn                  (cpu_rstn),
    .io_npuClk                   (npu_clk),
    .io_npuRstn                  (npu_rstn),

    .io_axilite_aw_valid         (s_awvalid),
    .io_axilite_aw_ready         (s_awready),
    .io_axilite_aw_payload_addr  (s_awaddr),
    .io_axilite_aw_payload_prot  (s_awprot),
    .io_axilite_w_valid          (s_wvalid),
    .io_axilite_w_ready          (s_wready),
    .io_axilite_w_payload_data   (s_wdata),
    .io_axilite_w_payload_strb   (s_wstrb),
    .io_axilite_b_valid          (s_bvalid),
    .io_axilite_b_ready          (s_bready),
    .io_axilite_b_payload_resp   (s_bresp),
    .io_axilite_ar_valid         (s_arvalid),
    .io_axilite_ar_ready         (s_arready),
    .io_axilite_ar_payload_addr  (s_araddr),
    .io_axilite_ar_payload_prot  (s_arprot),
    .io_axilite_r_valid          (s_rvalid),
    .io_axilite_r_ready          (s_rready),
    .io_axilite_r_payload_data   (s_rdata),
    .io_axilite_r_payload_resp   (s_rresp),

    .io_npu_axilite_aw_valid         (m_awvalid),
    .io_npu_axilite_aw_ready         (m_awready),
    .io_npu_axilite_aw_payload_addr  (m_awaddr),
    .io_npu_axilite_aw_payload_prot  (m_awprot),
    .io_npu_axilite_w_valid          (m_wvalid),
    .io_npu_axilite_w_ready          (m_wready),
    .io_npu_axilite_w_payload_data   (m_wdata),
    .io_npu_axilite_w_payload_strb   (m_wstrb),
    .io_npu_axilite_b_valid          (m_bvalid),
    .io_npu_axilite_b_ready          (m_bready),
    .io_npu_axilite_b_payload_resp   (m_bresp),
    .io_npu_axilite_ar_valid         (m_arvalid),
    .io_npu_axilite_ar_ready         (m_arready),
    .io_npu_axilite_ar_payload_addr  (m_araddr),
    .io_npu_axilite_ar_payload_prot  (m_arprot),
    .io_npu_axilite_r_valid          (m_rvalid),
    .io_npu_axilite_r_ready          (m_rready),
    .io_npu_axilite_r_payload_data   (m_rdata),
    .io_npu_axilite_r_payload_resp   (m_rresp)
  );

  // ===========================================================================
  // npu 域：AXI4-Lite 寄存器从口模型（**语义写死在这里**，闸门 python 按同一口径算黄金）
  //   窗内偏移 = addr[13:0]；< 0x80 ⇒ 32 个 32bit 寄存器（**逐字节**按 wstrb 合并）；
  //   ≥ 0x80 ⇒ 读回 `32'hBAD00000 ^ addr`（整根 32bit 地址的指纹），写忽略（仍 OKAY）。
  // ===========================================================================
  reg [31:0] rf [0:NREG-1];

  // 写通道
  reg        w_aw_got;  reg [31:0] w_awaddr;
  reg        w_w_got;   reg [31:0] w_wdata;  reg [3:0] w_wstrb;
  reg [31:0] w_lat;                            // 本笔剩余响应延迟（npu 拍）
  reg        w_busy;                           // 本笔在飞（从提交到 B 被消费）
  reg        w_bvalid;  reg [1:0] w_bresp;     // 举着 BVALID
  reg [31:0] w_lat_sel;                        // LATMIN..LATMAX 轮转游标
  // 读通道
  reg        r_hold;    reg [31:0] r_araddr;  reg [31:0] r_lat;
  reg        r_valid;   reg [31:0] r_data;    reg [1:0] r_resp;
  reg [31:0] r_lat_sel;
  // 统计
  integer    npu_wr_cnt, npu_rd_cnt, npu_wr_seq, npu_rd_seq;
  integer    latmin, latmax;
  reg [31:0] latmin_r, latmax_r;               // 上面两个的 32bit 视图（从口比较用）

  assign m_awready = !w_aw_got && !w_busy;
  assign m_wready  = !w_w_got  && !w_busy;
  assign m_arready = !r_hold && !r_valid;
  assign m_bvalid  = w_bvalid;
  assign m_bresp   = w_bresp;
  assign m_rvalid  = r_valid;
  assign m_rdata   = r_data;
  assign m_rresp   = r_resp;

  integer k;
  initial begin
    for (k = 0; k < NREG; k = k + 1) rf[k] = 32'h0;
  end

  // 逐字节合并后的整字（组合；只在提交那一拍被采用）
  reg [31:0] w_merged;
  always @(*) begin
    w_merged = rf[w_awaddr[6:2]];
    if (w_wstrb[0]) w_merged[7:0]   = w_wdata[7:0];
    if (w_wstrb[1]) w_merged[15:8]  = w_wdata[15:8];
    if (w_wstrb[2]) w_merged[23:16] = w_wdata[23:16];
    if (w_wstrb[3]) w_merged[31:24] = w_wdata[31:24];
  end

  always @(posedge npu_clk) begin
    if (!npu_rstn) begin
      w_aw_got <= 1'b0; w_w_got <= 1'b0; w_busy <= 1'b0; w_bvalid <= 1'b0;
      w_lat <= 32'h0; w_bresp <= 2'b00; w_lat_sel <= latmin_r;
      r_hold <= 1'b0; r_valid <= 1'b0; r_data <= 32'h0; r_resp <= 2'b00;
      r_lat <= 32'h0; r_lat_sel <= latmin_r;
      npu_wr_cnt <= 0; npu_rd_cnt <= 0; npu_wr_seq <= 0; npu_rd_seq <= 0;
    end else begin
      // ---------------- 写：先各自收下 AW / W（两通道独立）----------------
      if (m_awvalid && m_awready) begin w_awaddr <= m_awaddr; w_aw_got <= 1'b1; end
      if (m_wvalid  && m_wready ) begin w_wdata <= m_wdata; w_wstrb <= m_wstrb; w_w_got <= 1'b1; end

      if (w_busy) begin
        if (!w_bvalid) begin
          if (w_lat == 32'h0) w_bvalid <= 1'b1;
          else                w_lat    <= w_lat - 32'h1;
        end else if (m_bready) begin
          w_bvalid <= 1'b0;
          w_busy   <= 1'b0;
        end
      end else if (w_aw_got && w_w_got) begin
        // 两件到齐 ⇒ 提交（窗内逐字节合并；窗外忽略），并起本笔延迟。
        //   合并结果**组合算好、提交只发一条整字 NBA**（比"同一存储字上多条分片 NBA"更可移植；
        //   两种写法在本机上经独立小程序核对过，逐字节结果一致 —— 合并语义：byte i 取 wstrb[i]）。
        if (w_awaddr[13:0] < 14'h0080) rf[w_awaddr[6:2]] <= w_merged;
        $display("NPU_W %0d %08x %08x %01x", npu_wr_seq, w_awaddr, w_wdata, w_wstrb);
        npu_wr_seq = npu_wr_seq + 1;
        npu_wr_cnt = npu_wr_cnt + 1;
        w_aw_got <= 1'b0; w_w_got <= 1'b0;
        w_busy   <= 1'b1; w_lat   <= w_lat_sel;
        w_lat_sel <= (w_lat_sel >= latmax_r) ? latmin_r : (w_lat_sel + 32'h1);
      end

      // ---------------- 读：AR → 延迟 → RVALID ----------------
      if (m_arvalid && m_arready) begin
        r_araddr <= m_araddr; r_hold <= 1'b1; r_lat <= r_lat_sel;
        r_lat_sel <= (r_lat_sel >= latmax_r) ? latmin_r : (r_lat_sel + 32'h1);
        $display("NPU_R %0d %08x", npu_rd_seq, m_araddr);
        npu_rd_seq = npu_rd_seq + 1;
        npu_rd_cnt = npu_rd_cnt + 1;
      end
      if (r_hold) begin
        if (r_lat == 32'h0) begin
          r_data  <= (r_araddr[13:0] < 14'h0080) ? rf[r_araddr[6:2]]
                                                 : (32'hBAD00000 ^ r_araddr);
          r_resp  <= 2'b00;
          r_valid <= 1'b1;
          r_hold  <= 1'b0;
        end else begin
          r_lat <= r_lat - 32'h1;
        end
      end
      if (r_valid && m_rready) r_valid <= 1'b0;
    end
  end

  // ===========================================================================
  // cpu 域：手摇 AXI4-Lite 主机（驱动在 negedge、判据在 posedge；带确定性反压注入）
  // ===========================================================================
  reg [31:0] rdata_c;
  integer    host_wr_cnt, host_rd_cnt;
  integer    lfsr;
  integer    tbfail;
  integer    waitmax;

  function integer rnd;                       // 0..maxv-1（确定性 LFSR，种子由 +SEED 给）
    input integer maxv;
    begin
      if (maxv <= 0) rnd = 0;
      else begin
        lfsr = (lfsr * 1103515245 + 12345) & 32'h7FFFFFFF;
        rnd  = lfsr % maxv;
      end
    end
  endfunction

  task fail_timeout(input [8*64-1:0] why);
    begin
      $display("RESULT: FAIL timeout %0s", why);
      $finish;
    end
  endtask

  // 写：AW/W 同举 → 等**两条通道各自** ready → 撤 → 举 BREADY → 等 BVALID
  task axi_write(input [31:0] addr, input [31:0] data, input [3:0] strb);
    integer t; reg ok;
    begin
      repeat (rnd(waitmax + 1)) @(negedge cpu_clk);
      @(negedge cpu_clk);
      s_awvalid = 1'b1; s_awaddr = addr; s_awprot = 3'b000;
      s_wvalid  = 1'b1; s_wdata  = data; s_wstrb  = strb;
      s_bready  = 1'b0;
      t = 0; ok = 1'b0;
      while (!ok) begin
        @(posedge cpu_clk);
        if (s_awready && s_wready) ok = 1'b1;
        else begin t = t + 1; if (t > TIMEOUT) fail_timeout("aw/w ready"); end
      end
      @(negedge cpu_clk);
      s_awvalid = 1'b0; s_wvalid = 1'b0;
      repeat (rnd(waitmax + 1)) @(negedge cpu_clk);
      s_bready = 1'b1;
      t = 0; ok = 1'b0;
      while (!ok) begin
        @(posedge cpu_clk);
        if (s_bvalid) ok = 1'b1;
        else begin t = t + 1; if (t > TIMEOUT) fail_timeout("b valid"); end
      end
      if (s_bresp !== 2'b00) begin
        tbfail = tbfail + 1;
        $display("TBFAIL: BRESP=%b addr=%08x", s_bresp, addr);
      end
      @(negedge cpu_clk);
      s_bready = 1'b0;
      host_wr_cnt = host_wr_cnt + 1;
    end
  endtask

  // 读：AR → 等 ARREADY → 撤 → 举 RREADY → 等 RVALID
  task axi_read(input [31:0] addr);
    integer t; reg ok;
    begin
      repeat (rnd(waitmax + 1)) @(negedge cpu_clk);
      @(negedge cpu_clk);
      s_arvalid = 1'b1; s_araddr = addr; s_arprot = 3'b000;
      s_rready  = 1'b0;
      t = 0; ok = 1'b0;
      while (!ok) begin
        @(posedge cpu_clk);
        if (s_arready) ok = 1'b1;
        else begin t = t + 1; if (t > TIMEOUT) fail_timeout("ar ready"); end
      end
      @(negedge cpu_clk);
      s_arvalid = 1'b0;
      repeat (rnd(waitmax + 1)) @(negedge cpu_clk);
      s_rready = 1'b1;
      t = 0; ok = 1'b0;
      while (!ok) begin
        @(posedge cpu_clk);
        if (s_rvalid) begin rdata_c = s_rdata; ok = 1'b1; end
        else begin t = t + 1; if (t > TIMEOUT) fail_timeout("r valid"); end
      end
      if (s_rresp !== 2'b00) begin
        tbfail = tbfail + 1;
        $display("TBFAIL: RRESP=%b addr=%08x", s_rresp, addr);
      end
      @(negedge cpu_clk);
      s_rready = 1'b0;
      $display("HOST_R %0d %08x %08x", host_rd_cnt, addr, rdata_c);
      host_rd_cnt = host_rd_cnt + 1;
    end
  endtask

  // ===========================================================================
  // stim 文件 + 主流程
  // ===========================================================================
  reg  [8*256-1:0] stimfile, line;
  integer          fd, code, nstim, i;
  reg  [31:0]      st_addr [0:MAXSTIM-1];
  reg  [31:0]      st_data [0:MAXSTIM-1];
  reg  [3:0]       st_strb [0:MAXSTIM-1];
  reg              st_isw  [0:MAXSTIM-1];
  reg  [31:0]      a1, a2, a3, a4, s3, s4;
  integer          nw_stim, nr_stim, seed;

  initial begin
    // ---- 初始化主机驱动（避免 X 传播）----
    s_awvalid = 1'b0; s_awaddr = 32'h0; s_awprot = 3'b0;
    s_wvalid  = 1'b0; s_wdata  = 32'h0; s_wstrb  = 4'h0;
    s_bready  = 1'b0;
    s_arvalid = 1'b0; s_araddr = 32'h0; s_arprot = 3'b0;
    s_rready  = 1'b0;
    tbfail = 0; host_wr_cnt = 0; host_rd_cnt = 0;
    nstim = 0; nw_stim = 0; nr_stim = 0;
    lfsr = 32'h12345678; latmin = 1; latmax = 7; waitmax = 0;

    if ($test$plusargs("SAME_CLK"))  same_clk  = 1'b1;
    if ($test$plusargs("PHASE_INV")) phase_inv = 1'b1;
    if ($value$plusargs("PHASE_DLY_PS=%d", phase_dly_ps)) ; else phase_dly_ps = 0;
    if ($value$plusargs("LATMIN=%d", latmin)) ; else latmin = 1;
    if ($value$plusargs("LATMAX=%d", latmax)) ; else latmax = 7;
    if ($value$plusargs("WAITMAX=%d", waitmax)) ; else waitmax = 0;
    if ($value$plusargs("SEED=%d", seed)) ; else seed = 32'h12345678;
    lfsr = seed;
    if (latmax < latmin) begin
      $display("TB-ERROR: LATMAX(%0d) < LATMIN(%0d)", latmax, latmin);
      $display("RESULT: FAIL bad plusargs");
      $finish;
    end
    latmin_r = latmin; latmax_r = latmax;   // 从口的 32bit 视图（初值；parse 之后立即生效）
    if (!$value$plusargs("STIMFILE=%s", stimfile)) begin
      $display("TB-ERROR: 缺 +STIMFILE=");
      $display("RESULT: FAIL no stimfile");
      $finish;
    end

    // ---- 读 stim（`0 <addr> <data> <strb>` 写 / `1 <addr>` 读）----
    fd = $fopen(stimfile, "r");
    if (fd == 0) begin
      $display("TB-ERROR: 打不开 stim 文件 %0s", stimfile);
      $display("RESULT: FAIL cannot open stimfile");
      $finish;
    end
    code = $fgets(line, fd);
    while (code != 0) begin
      a1 = 32'h0; a2 = 32'h0; a3 = 32'h0; a4 = 32'h0;
      if ($sscanf(line, "%h %h %h %h", a1, a2, a3, a4) == 4) begin
        if (nstim >= MAXSTIM) begin
          $display("TB-ERROR: stim 条数超过 %0d", MAXSTIM);
          $display("RESULT: FAIL too many stim");
          $finish;
        end
        st_isw[nstim]  = 1'b1;                  // 0 = 写
        st_addr[nstim] = a2; st_data[nstim] = a3; st_strb[nstim] = a4[3:0];
        nstim = nstim + 1; nw_stim = nw_stim + 1;
      end else if ($sscanf(line, "%h %h %h %h", a1, a2, s3, s4) == 2) begin
        if (nstim >= MAXSTIM) begin
          $display("TB-ERROR: stim 条数超过 %0d", MAXSTIM);
          $display("RESULT: FAIL too many stim");
          $finish;
        end
        st_isw[nstim]  = 1'b0;                  // 1 = 读
        st_addr[nstim] = a2; st_data[nstim] = 32'h0; st_strb[nstim] = 4'h0;
        nstim = nstim + 1; nr_stim = nr_stim + 1;
      end
      code = $fgets(line, fd);
    end
    $fclose(fd);

    $display("CFG same_clk=%0d npu_clk=%0s latmin=%0d latmax=%0d waitmax=%0d phase_inv=%0d phase_dly_ps=%0d seed=%0d",
             same_clk, same_clk ? "100.000MHz(via cpu_clk)" : "37.000MHz",
             latmin, latmax, waitmax, phase_inv, phase_dly_ps, seed);
    $display("STIM n=%0d nw=%0d nr=%0d", nstim, nw_stim, nr_stim);
    if (nstim == 0) begin
      $display("RESULT: FAIL empty stim");
      $finish;
    end

    // ---- 复位：两域同时释放（口径见文件头）----
    repeat (4) @(negedge cpu_clk);
    reset = 1'b0;
    @(negedge cpu_clk);

    // ---- 逐条执行 ----
    for (i = 0; i < nstim; i = i + 1) begin
      if (st_isw[i]) axi_write(st_addr[i], st_data[i], st_strb[i]);
      else           axi_read(st_addr[i]);
    end

    repeat (8) @(negedge cpu_clk);
    $display("COUNTS host_wr=%0d host_rd=%0d npu_wr=%0d npu_rd=%0d",
             host_wr_cnt, host_rd_cnt, npu_wr_cnt, npu_rd_cnt);

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
