// =============================================================================
// NpuIrqCdcTb.v —— **NpuIrqCdc（IRQ 电平 npu_clk → cpu_clk 的 2-FF 同步器）的独立两时钟装置**。
//   对应 Y1「NPU 独立时钟域」plan Task **N5** / spec §3-A(c) / §5-G3。纯 Verilog，iverilog -g2012。
//
// ★ 本装置**不碰** SoC 活路径：只有 DUT（`NpuIrqCdc` 网表）+ 本文件里的两个"驱动器"——
//   npu_clk（37 MHz，与 100 非整数比 2.7027…）侧的 **IRQ 电平源**（模拟 NpuTop.irqR 的保持电平），
//   cpu_clk（100 MHz）侧的 **清申请电平源**（反向口的通用手段，见 RTL 文件头④）。
//   glue / NpuTop / PLIC / 板级**一律不在场**（RTL 集成是 N5b 的活）。
//
// -----------------------------------------------------------------------------
// 装置结构：
//   · 两根独立时钟：cpu_clk = 100.000 MHz（半周期 5.000 ns）、npu_clk = 37.000 MHz（半周期 13.514 ns）。
//     `+SAME_CLK` 把 npu_clk 并到 cpu_clk（分离"跨域问题"与"普通逻辑问题"）；
//     `+PHASE_INV` npu_clk 初值取 1（半周期相移）；`+PHASE_DLY_PS=<ps>` 让它晚起振（任意亚周期相位）。
//   · **相位扫描（"在多个相位上置起/清除"）**：IRQ 源（npu 域）每段**保持 ≥ 40 ns**（≥4 个 cpu 周期，
//     保证每一次跳变都被 2-FF 可靠带过），段长用**确定性 LFSR**在 40.00..60.00 ns 之间取值
//     ⇒ 跳变时刻对 cpu_clk 的相位**逐段不同**（覆盖 ~200 个亚周期相位）。反向口同理。
//   · **判据（本装置自判 + 闸门 python 独立复判）**：
//       ① **有界延迟**：每个 `cpuIrq` 跳变都必须由**同向**的 `npuIrq` 跳变在 `[LATMIN,LATMAX]` ns 内触发
//          （2-FF ⇒ 约 2 个 cpu 周期；`LATMIN>0` 就把"组合直通/少一级同步"挡在外面）。
//       ② **无伪跳变**：cpuIrq 升时 npuIrq 必须为 1、降时必须为 0（配对）；否则 `SPURIOUS`。
//       ③ **电平保持**：源保持多久，cpuIrq 就保持多久 —— 由①②在每段上覆盖（源未撤时 cpuIrq 不得自行落）。
//       ④ **同步性**：`cpuIrq` 只允许在 `cpu_clk==1` 时改变（`ASYNC_CNT` 必须为 0）—— 把"未同步的
//          组合跨域（亚稳态/毛刺类）"挡在外面。
//       ⑤ **反向口**：`cpuClearReq` → `npuClearReq` 同款有界延迟 + 同步性检查（`REV_ASYNC_CNT==0`）。
//   输出事实行：CFG / NTOG / 每次跳变 `NIRQ t val`、`CIRQ t val`、`NIRQC t val`、`CIRC t val` /
//               `STATS lat_viol=.. spurious=.. async=.. rev_async=.. latmax_ps=..` / TBFAIL / RESULT: PASS|FAIL
//
// ★ 复位口径（本装置专属）：两域复位**同时**释放（装置起手先拉低两复位数拍）。
//   两个同步器的 FF 复位后都是 0 ⇒ cpuIrq=0 / npuClearReq=0，不会凭空造"伪 IRQ"。
// =============================================================================
`timescale 1ns/1ps

module NpuIrqCdcTb;

  localparam integer NTOG          = 120;        // IRQ 源跳变次数（段数 = NTOG）
  localparam integer SIM_LIMIT_NS  = 400000;     // 全局看门狗（ns）

  // ===========================================================================
  // 两根独立时钟 + 相位控制（与 N3/N4 装置逐字同口径）
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

  reg  reset   = 1'b1;                          // 高有效总复位（TB 起手保持）
  wire cpu_rstn = ~reset;
  wire npu_rstn = ~reset;

  // ===========================================================================
  // DUT
  // ===========================================================================
  wire npu_irq;                                 // npu 域：源保持电平（模拟 NpuTop.irqR）
  wire cpu_irq;                                 // cpu 域：同步副本 → PLIC 源 3
  reg  cpu_clear_req;                           // cpu 域：反向口源电平
  wire npu_clear_req;                           // npu 域：同步副本

  NpuIrqCdc dut (
    .io_cpuClk      (cpu_clk),
    .io_cpuRstn     (cpu_rstn),
    .io_npuClk      (npu_clk),
    .io_npuRstn     (npu_rstn),
    .io_npuIrq      (npu_irq),
    .io_cpuIrq      (cpu_irq),
    .io_cpuClearReq (cpu_clear_req),
    .io_npuClearReq (npu_clear_req)
  );

  // ===========================================================================
  // 相位扫描驱动：IRQ 源（npu 域）+ 反向口源（cpu 域）
  //   段长 = 40.00..60.00 ns 的确定性伪随机（LFSR）⇒ 跳变时刻对目的钟的相位逐段不同。
  // ===========================================================================
  reg [31:0] lfsr;
  function integer rnd;                          // 0..maxv-1（确定性 LFSR）
    input integer maxv;
    begin
      if (maxv <= 0) rnd = 0;
      else begin
        lfsr = (lfsr * 1103515245 + 12345) & 32'h7FFFFFFF;
        rnd  = lfsr % maxv;
      end
    end
  endfunction

  reg [63:0] npu_irq_r;
  reg [63:0] cpu_clr_r;
  assign npu_irq = npu_irq_r[0];
  assign cpu_clear_req = cpu_clr_r[0];

  integer tbfail;
  real    latmax_ps;                             // 观测到的最大延迟（ps，诊断用）
  reg     src_done;                              // 源驱动跑完标志

  // ---- 源驱动 ----
  //   段长 80.00..99.99 ns：必须 **> 反向口的最坏延迟（2 个 npu 周期 ≈ 54 ns）**
  //   （正向延迟 ≤ 2 个 cpu 周期 = 20 ns，就更小于它）⇒ 每次跳变都被两个同步器 1:1 带过、
  //   配对判据无歧义；同时段长对目的钟非整数倍 ⇒ 跳变相位逐段不同。
  integer k;
  initial begin
    npu_irq_r = 64'h0;
    cpu_clr_r = 64'h0;
    src_done = 1'b0;
    lfsr = 32'h0BADC0DE;
    // 等复位释放
    @(posedge cpu_rstn);
    repeat (4) @(posedge cpu_clk);
    for (k = 0; k < NTOG; k = k + 1) begin
      #( (80.0 + (rnd(2000))/100.0) );
      npu_irq_r[0] = ~npu_irq_r[0];
      cpu_clr_r[0] = ~cpu_clr_r[0];
    end
    // 收尾：留一段稳定，再让判据跑完
    @(posedge cpu_clk);
    src_done = 1'b1;
  end

  // ===========================================================================
  // 监视器：每次跳变打一行事实 + 立即自判（有界延迟 / 配对 / 同步性）
  // ===========================================================================
  real t_npu_rise, t_npu_fall;
  real t_revc_rise, t_revc_fall;
  integer lat_viol, spurious, async_cnt, rev_async_cnt, rev_lat_viol, rev_spurious;
  real LATMIN_NS, LATMAX_NS, LATMAX_REV_NS;
  reg  npu_lvl, cpu_lvl, revc_lvl, cpuc_lvl;

  // ---- npu 源跳变时间 ----
  always @(posedge npu_irq) begin t_npu_rise = $realtime; npu_lvl = 1'b1; end
  always @(negedge npu_irq) begin t_npu_fall = $realtime; npu_lvl = 1'b0; end
  // ---- 反向口源跳变时间（cpu 域）----
  always @(posedge cpu_clear_req) begin t_revc_rise = $realtime; cpuc_lvl = 1'b1; end
  always @(negedge cpu_clear_req) begin t_revc_fall = $realtime; cpuc_lvl = 1'b0; end

  // ---- 正向 cpuIrq 判据 ----
  always @(cpu_irq) begin
    real lat;
    if (cpu_rstn === 1'b1) begin
      $display("CIRQ %0.3f %0d", $realtime, cpu_irq);
      if (cpu_irq === 1'b1) begin
        if (npu_lvl !== 1'b1) spurious = spurious + 1;
        lat = $realtime - t_npu_rise;
        if (lat < LATMIN_NS || lat > LATMAX_NS) lat_viol = lat_viol + 1;
        if (lat > latmax_ps/1000.0) latmax_ps = lat*1000.0;
      end else begin
        if (npu_lvl !== 1'b0) spurious = spurious + 1;
        lat = $realtime - t_npu_fall;
        if (lat < LATMIN_NS || lat > LATMAX_NS) lat_viol = lat_viol + 1;
      end
    end
    // 同步性：cpuIrq 只允许在 cpu_clk==1 时改变（posedge 已把 clk 拉高）
    if (cpu_rstn === 1'b1 && cpu_clk !== 1'b1) async_cnt = async_cnt + 1;
  end
  always @(npu_irq) $display("NIRQ %0.3f %0d", $realtime, npu_irq);

  // ---- 反向 npuClearReq 判据 ----
  always @(npu_clear_req) begin
    real lat;
    if (npu_rstn === 1'b1) begin
      $display("NIRQC %0.3f %0d", $realtime, npu_clear_req);
      if (npu_clear_req === 1'b1) begin
        if (cpuc_lvl !== 1'b1) rev_spurious = rev_spurious + 1;
        lat = $realtime - t_revc_rise;
        if (lat < LATMIN_NS || lat > LATMAX_REV_NS) rev_lat_viol = rev_lat_viol + 1;
      end else begin
        if (cpuc_lvl !== 1'b0) rev_spurious = rev_spurious + 1;
        lat = $realtime - t_revc_fall;
        if (lat < LATMIN_NS || lat > LATMAX_REV_NS) rev_lat_viol = rev_lat_viol + 1;
      end
    end
    if (npu_rstn === 1'b1 && npu_clk !== 1'b1) rev_async_cnt = rev_async_cnt + 1;
  end
  always @(cpu_clear_req) $display("CIRC %0.3f %0d", $realtime, cpu_clear_req);

  // ===========================================================================
  // 主流程
  // ===========================================================================
  integer seed;
  initial begin
    npu_lvl = 1'b0; cpu_lvl = 1'b0; revc_lvl = 1'b0; cpuc_lvl = 1'b0;
    tbfail = 0; lat_viol = 0; spurious = 0; async_cnt = 0; rev_async_cnt = 0;
    rev_lat_viol = 0; rev_spurious = 0; latmax_ps = 0.0;
    // 正向：目的 = cpu（2 个 cpu 周期 = 20 ns）；反向：目的 = npu（2 个 npu 周期 ≈ 54 ns）
    LATMIN_NS = 5.0; LATMAX_NS = 32.0; LATMAX_REV_NS = 60.0;

    if ($test$plusargs("SAME_CLK"))  same_clk  = 1'b1;
    if ($test$plusargs("PHASE_INV")) phase_inv = 1'b1;
    if ($value$plusargs("PHASE_DLY_PS=%d", phase_dly_ps)) ; else phase_dly_ps = 0;
    if ($value$plusargs("SEED=%d", seed)) ; else seed = 32'h0BADC0DE;
    // 说明：源段长的 LFSR 初值固定在驱动块里（域无关）；SEED 只影响相位起振（+PHASE_DLY_PS）。

    $display("CFG same_clk=%0d npu_clk=%0s phase_inv=%0d phase_dly_ps=%0d latmin_ns=%0.3f latmax_ns=%0.3f latmax_rev_ns=%0.3f",
             same_clk, same_clk ? "100.000MHz(via cpu_clk)" : "37.000MHz",
             phase_inv, phase_dly_ps, LATMIN_NS, LATMAX_NS, LATMAX_REV_NS);

    // ---- 复位：两域同时释放（口径见文件头）----
    repeat (6) @(negedge cpu_clk);
    reset = 1'b0;

    // ---- 等源驱动跑完 ----
    wait (src_done == 1'b1);
    // 再留一段观察窗（确保最后一段的 cpuIrq/npuClearReq 已跟上）
    repeat (16) @(posedge cpu_clk);

    $display("NTOG %0d", NTOG);
    $display("STATS lat_viol=%0d spurious=%0d async=%0d rev_async=%0d rev_lat_viol=%0d rev_spurious=%0d",
             lat_viol, spurious, async_cnt, rev_async_cnt, rev_lat_viol, rev_spurious);
    $display("STATS latmax_ps=%0.1f", latmax_ps);

    if (lat_viol == 0 && spurious == 0 && async_cnt == 0 &&
        rev_async_cnt == 0 && rev_lat_viol == 0 && rev_spurious == 0)
      $display("RESULT: PASS");
    else
      $display("RESULT: FAIL lat_viol=%0d spurious=%0d async=%0d rev_async=%0d rev_lat_viol=%0d rev_spurious=%0d",
               lat_viol, spurious, async_cnt, rev_async_cnt, rev_lat_viol, rev_spurious);
    $finish;
  end

  // 兜底看门狗
  initial begin
    #SIM_LIMIT_NS;
    $display("RESULT: FAIL timeout(global watchdog %0d ns)", SIM_LIMIT_NS);
    $finish;
  end

endmodule
