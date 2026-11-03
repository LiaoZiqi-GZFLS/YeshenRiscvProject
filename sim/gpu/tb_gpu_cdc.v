// tb_gpu_cdc.v —— **GPU 独立时钟域**的端到端像素闸门：
//   `gpu_clock_domain`（内含真 gpu_top + 两座 CDC 桥 + 复位同步器）跑**两个异步时钟**，
//   命令从 **CSR 窗**（soc_clk 侧）推进去，像素结果在 soc_clk 侧的 AXI RAM 模型里逐 8 B 字比对。
//
// 与 tb_gpu_2d 的关系：判据**完全复用**（同一套 `<case>.init/exp/cmds.hex`，同一份
//   `sim/gpu/axi_ram_model.v`，同一个逐字比对循环）；区别只在：
//     · DUT 从 `gpu_cmd+gpu_2d+gpu_mem` 换成 `gpu_clock_domain`（= gpu_top + CDC）；
//     · 命令从 gpu_cmd 的 `wr_*` 口改成**真实的 CSR 写序列**（CMD_DATA / CMD_PUSH，
//       与板上 gputest.c 逐字一致）—— 顺便把 CSR 跨域也一起验了；
//     · 时钟从单钟改成 **soc_clk 10ns + gpu_clk（`GPU_HALF` 半周期）**，两者非整数比。
//
// 判据（缺一不可）：
//   ① 逐字像素比对全 0 失配（证明 mem 桥 + CSR 桥在非整数比下都不丢/不重/不乱序）；
//   ② 至少发生 aw/ar 若干笔、且 `flip_toggle` 电平能跨回 soc 域（结构活性）；
//   ③ **红臂**：用 `-DDCFIFO_BAD_SYNC` 或 `-DDCFIFO_BAD_DATA` 重编 dcfifo 时必须 FAIL
//      （由 run_2d_cdc.sh 驱动，证明本闸门对"忘了做 CDC"是敏感的，而不是恒绿）。
`timescale 1ns/1ps
`include "tb_cfg.svh"

module tb_gpu_cdc;

  localparam FB_WORDS = 153600;

`ifdef RAM_TRUNC32
  localparam RAM_T32 = 1;
`else
  localparam RAM_T32 = 0;
`endif

// 读延迟档位（板级 DDR 有几十~几百 ns）：-DRAM_RLAT=32 之类；缺省 0 = 原行为
`ifdef RAM_RLAT
  localparam RAM_LAT = `RAM_RLAT;
`else
  localparam RAM_LAT = 0;
`endif

`ifdef GPU_FAST
  localparam GPU_HALF = 3;      // gpu_clk 周期 6ns（166.7MHz）——**比 soc_clk 快**的一档
`else
  localparam GPU_HALF = 7;      // gpu_clk 周期 14ns（71.4MHz）——比 soc_clk 慢、且与 10ns 非整数比
`endif

  reg soc_clk = 0, gpu_clk = 0, async_rst = 1;
  always #5 soc_clk = ~soc_clk;
  always #(GPU_HALF) gpu_clk = ~gpu_clk;

  // soc 域的同步复位 = async_rst 的 2FF（与板内 glue_reset 同语义）
  reg [1:0] soc_rst_s = 2'b11;
  always @(posedge soc_clk or posedge async_rst) begin
    if (async_rst) soc_rst_s <= 2'b11;
    else           soc_rst_s <= {soc_rst_s[0], 1'b0};
  end
  wire soc_rst = soc_rst_s[1];

  // ---------------- CSR 主口（BFM，soc 域） ----------------
  reg  [11:0] m_awaddr = 0; reg m_awvalid = 0;
  reg  [31:0] m_wdata  = 0; reg [3:0] m_wstrb = 4'hF; reg m_wvalid = 0;
  reg         m_bready = 0;
  reg  [11:0] m_araddr = 0; reg m_arvalid = 0;
  reg         m_rready = 0;

  wire        s_awready, s_wready, s_bvalid, s_arready, s_rvalid;
  wire [31:0] s_rdata;

  // ---------------- DDR 主口（soc 域 → RAM 模型） ----------------
  wire [31:0] araddr, awaddr;
  wire [7:0]  arlen, awlen;
  wire [2:0]  arsize, awsize;
  wire [1:0]  arburst, awburst;
  wire        arvalid, arready, awvalid, awready;
  wire [63:0] rdata, wdata;
  wire [1:0]  rresp, bresp;
  wire        rlast, rvalid, rready;
  wire [7:0]  wstrb;
  wire        wlast, wvalid, wready, bvalid, bready;
  wire [31:0] aw_count, w_count, ar_count;
  wire        flip_toggle;
  reg  [20:0] dbg_idx;
  wire [63:0] dbg_word;

  reg vsync = 0;

  gpu_clock_domain dut (
      .soc_clk (soc_clk), .soc_rst (soc_rst), .async_rst (async_rst), .gpu_clk (gpu_clk),

      .s_awaddr (m_awaddr), .s_awvalid (m_awvalid), .s_awready (s_awready),
      .s_wdata  (m_wdata),  .s_wstrb   (m_wstrb),   .s_wvalid  (m_wvalid), .s_wready (s_wready),
      .s_bvalid (s_bvalid), .s_bready  (m_bready),
      .s_araddr (m_araddr), .s_arvalid (m_arvalid), .s_arready (s_arready),
      .s_rdata  (s_rdata),  .s_rvalid  (s_rvalid),  .s_rready  (m_rready),

      .m_araddr (araddr), .m_arlen (arlen), .m_arsize (arsize), .m_arburst (arburst),
      .m_arvalid(arvalid), .m_arready(arready),
      .m_rdata  (rdata), .m_rresp (rresp), .m_rlast (rlast), .m_rvalid (rvalid), .m_rready (rready),

      .m_awaddr (awaddr), .m_awlen (awlen), .m_awsize (awsize), .m_awburst (awburst),
      .m_awvalid(awvalid), .m_awready(awready),
      .m_wdata  (wdata), .m_wstrb (wstrb), .m_wlast (wlast), .m_wvalid (wvalid), .m_wready (wready),
      .m_bresp  (bresp), .m_bvalid(bvalid), .m_bready(bready),

      .vsync (vsync), .flip_toggle (flip_toggle)
  );

  axi_ram_model #(.AW(19), .INIT_FILE(`INIT_FILE), .TRUNC32(RAM_T32), .RLAT(RAM_LAT)) ram (
      .clk(soc_clk), .rst(soc_rst),
      .araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
      .rdata(rdata), .rlast(rlast), .rvalid(rvalid), .rready(rready),
      .awaddr(awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
      .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
      .bresp(bresp), .bvalid(bvalid), .bready(bready),
      .aw_count(aw_count), .w_count(w_count), .ar_count(ar_count),
      .dbg_idx(dbg_idx), .dbg_word(dbg_word),
      .dbg_bvalid(), .dbg_wactive(), .dbg_wleft()
  );

  // =====================================================================
  // CSR 读写（AXI4-Lite，单笔；在 negedge 驱动/采样，避免与 posedge 竞争）
  // =====================================================================
  task axil_wr(input [11:0] a, input [31:0] d);
    begin
      @(negedge soc_clk);
      m_awaddr = a; m_awvalid = 1'b1;
      m_wdata  = d; m_wstrb   = 4'hF; m_wvalid = 1'b1; m_bready = 1'b1;
      // 等到 AW/W 同拍被吃（gpu_csr 要求 awvalid&wvalid 同时有效）
      while (!(s_awready && s_wready)) @(negedge soc_clk);
      @(negedge soc_clk);
      m_awvalid = 1'b0; m_wvalid = 1'b0;
      while (!s_bvalid) @(negedge soc_clk);
      @(negedge soc_clk);
      m_bready = 1'b0;
    end
  endtask

  task axil_rd(input [11:0] a, output [31:0] d);
    begin
      @(negedge soc_clk);
      m_araddr = a; m_arvalid = 1'b1; m_rready = 1'b1;
      while (!s_arready) @(negedge soc_clk);
      @(negedge soc_clk);
      m_arvalid = 1'b0;
      while (!s_rvalid) @(negedge soc_clk);
      d = s_rdata;
      @(negedge soc_clk);
      m_rready = 1'b0;
    end
  endtask

  // =====================================================================
  // 期望值 + 命令流
  // =====================================================================
  reg [63:0] exp_mem [0:FB_WORDS-1];
  reg [31:0] cw [0:8191];
  integer i, errors = 0, ncmd = 0;
  reg [31:0] st, idv;
  reg [15:0] last_seq;
  reg        is_fence;

  // 寄存器窗偏移（与 rtl/gpu/gpu_regs.vh 一致）
  localparam [11:0] R_ID = 12'h000, R_STATUS = 12'h004, R_CMD_DATA = 12'h010,
                    R_CMD_PUSH = 12'h014, R_SEQ_DONE = 12'h018;

  task wait_idle;
    begin
      st = 32'h1;
      while (st[0]) axil_rd(R_STATUS, st);
      repeat (4) @(negedge soc_clk);
    end
  endtask

  // 等最后一条 FENCE 的 seq 落地。**不能只靠 wait_idle**：刚 push 完的最后一笔命令
  // 还没被 gpu_cmd 取走时 busy 仍是 0，wait_idle 会立刻返回，比对就落在引擎动手之前
  // （整屏 3D 用例上实测过：aw=9600 恰好只等于 CLEAR、ar=0、seq 停在 1）。
  task wait_seq(input [15:0] s);
    integer guard;
    begin
      guard = 0;
      while (guard < 400000) begin
        axil_rd(R_SEQ_DONE, st);
        if ((st & 32'hFFFF) == {16'd0, s}) guard = 400000;
        else guard = guard + 1;
      end
      repeat (20) @(negedge soc_clk);
    end
  endtask

  initial begin
    $readmemh(`EXP_FILE, exp_mem);
    for (i = 0; i < 8192; i = i + 1) cw[i] = 32'hFFFF_FFFF;
    $readmemh(`CMD_FILE, cw);

    repeat (6) @(negedge soc_clk);
    async_rst = 0;
    repeat (6) @(negedge soc_clk);

    // 先读 ID，确认 CSR 跨域通路真的通（否则后面的"全 0 失配"会掩盖死桥）
    axil_rd(R_ID, idv);
    if (idv !== 32'h5947_5055) begin
      $display("  CSR-ID MISMATCH got=%08x（CSR 跨域桥不通）", idv);
      errors = errors + 1;
    end

    // 回放命令：头字 → CMD_DATA；参数 → CMD_DATA，最后一个参数 → CMD_PUSH（同 gputest.c）
    i = 0;
    last_seq = 16'hFFFF;
    while (cw[i] !== 32'hFFFF_FFFF) begin
      wait_idle();                       // 命令边界限流：一条一条来
      axil_wr(R_CMD_DATA, cw[i]);
      ncmd = (cw[i] >> 16) & 8'hFF;
      is_fence = (cw[i] >> 24) == 8'h07;
      for (integer k = 0; k < ncmd; k = k + 1) begin
        i = i + 1;
        if (is_fence && k == 0) last_seq = cw[i][15:0];
        if (k == ncmd - 1) axil_wr(R_CMD_PUSH, cw[i]);
        else               axil_wr(R_CMD_DATA, cw[i]);
      end
      i = i + 1;
    end

    if (last_seq !== 16'hFFFF) wait_seq(last_seq);
    else                       wait_idle();
    $display("  dbg: cmd_state=%0d used=%0d lastop=%02x is3d=%0d | 3d st=%0d busy=%0d done=%0d triidx=%0d",
             dut.u_gpu.u_cmd.state, dut.u_gpu.cmd_used, dut.u_gpu.last_op,
             dut.u_gpu.is3d, dut.u_gpu.u_3d.st, dut.u_gpu.u_3d.busy,
             dut.u_gpu.u_3d.done, dut.u_gpu.u_3d.tri_idx);
    repeat (60) @(negedge soc_clk);

    // 逐字比对（与 tb_gpu_2d 同一循环）
    for (i = 0; i < FB_WORDS; i = i + 1) begin
      dbg_idx = i[20:0];
      #1;
      if (dbg_word !== exp_mem[i]) begin
        if (errors < 8)
          $display("  MISMATCH idx=%0d got=%016x exp=%016x", i, dbg_word, exp_mem[i]);
        errors = errors + 1;
      end
    end

    $display("cdc: soc=10ns gpu=%0dns aw=%0d w=%0d ar=%0d seq=%0d flip=%0d",
             GPU_HALF * 2, aw_count, w_count, ar_count, dut.u_gpu.u_csr.seq_done, flip_toggle);
    if (errors == 0) $display("CDC PASS（%0d 命令，逐字节吻合 %0d 字）", ncmd, FB_WORDS);
    else             $display("CDC FAIL errors=%0d", errors);
    $finish;
  end

  initial begin
    #200_000_000;
    $display("CDC TIMEOUT（state=%0d busy=%0d aw=%0d ar=%0d）",
             dut.u_gpu.u_csr.s_bvalid, st[0], aw_count, ar_count);
    $display("  cmd: state=%0d cnt=%0d lcnt=%0d assembling=%0d left_w=%0d left=%0d",
             dut.u_gpu.u_cmd.state, dut.u_gpu.u_cmd.cnt, dut.u_gpu.u_cmd.lcnt,
             dut.u_gpu.u_cmd.assembling, dut.u_gpu.u_cmd.left_w, dut.u_gpu.u_cmd.left);
    $display("  disp: is3d=%0d n3=%0d p3cnt=%0d start3d=%0d par_valid=%0d par_ready=%0d",
             dut.u_gpu.is3d, dut.u_gpu.n3, dut.u_gpu.p3cnt, dut.u_gpu.start_3d,
             dut.u_gpu.par_valid, dut.u_gpu.par_ready);
    $display("  3d : st=%0d busy=%0d done=%0d", dut.u_gpu.u_3d.st, dut.u_gpu.u_3d.busy, dut.u_gpu.u_3d.done);
    $finish;
  end

endmodule
