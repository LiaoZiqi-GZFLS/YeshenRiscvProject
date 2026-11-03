// gpu_top.v —— GPU 顶层：CSR + 命令 FIFO + 2D 引擎 + 3D 引擎 + 共用读写引擎。
//
// 对外两口：
//   · s_*：AXI4-Lite 从口（CPU 访问 0xF000_5000 寄存器窗，窗内 12 位偏移）；
//   · m_*：AXI4 64-bit 主口（读/写 DDR，接 glue 的 MemArbiter 第 4 组）。
// 显示侧：vsync 由 video_passthrough 在读帧起点给出；flip_toggle 接 video 的 gui_bank。
//
// 命令分发：op 0x01..0x07 → u_2d；0x10(CLEAR3D)/0x11(DRAW_TRIS)/0x12(COMPOSITE3D) → u_3d。
// 参数流按 `is3d` 选通到对应引擎的收集器（同一时刻只有一个引擎有活 ⇒ mem 口用 mux）。
// gpu_mem 契约：同一时刻只有读或写一类在飞——由各引擎内部串行保证。
module gpu_top (
    input  wire        clk,
    input  wire        rst,

    // AXI4-Lite 从口（CPU 侧，窗内偏移 12 位）
    input  wire [11:0] s_awaddr,
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wvalid,
    output wire        s_wready,
    output wire        s_bvalid,
    input  wire        s_bready,
    input  wire [11:0] s_araddr,
    input  wire        s_arvalid,
    output wire        s_arready,
    output wire [31:0] s_rdata,
    output wire        s_rvalid,
    input  wire        s_rready,

    // AXI4 64-bit 主口（DDR）
    output wire [31:0] m_araddr,
    output wire [7:0]  m_arlen,
    output wire [2:0]  m_arsize,
    output wire [1:0]  m_arburst,
    output wire        m_arvalid,
    input  wire        m_arready,
    input  wire [63:0] m_rdata,
    input  wire [1:0]  m_rresp,
    input  wire        m_rlast,
    input  wire        m_rvalid,
    output wire        m_rready,

    output wire [31:0] m_awaddr,
    output wire [7:0]  m_awlen,
    output wire [2:0]  m_awsize,
    output wire [1:0]  m_awburst,
    output wire        m_awvalid,
    input  wire        m_awready,
    output wire [63:0] m_wdata,
    output wire [7:0]  m_wstrb,
    output wire        m_wlast,
    output wire        m_wvalid,
    input  wire        m_wready,
    input  wire [1:0]  m_bresp,
    input  wire        m_bvalid,
    output wire        m_bready,

    // 显示
    input  wire        vsync,        // 读帧起点（video_passthrough）
    output wire        flip_toggle   // 接 video 的 gui_bank：0=bank0(0x9200_0000) 1=bank1(**0x9280_0000**)
);

  // ---- CSR ↔ CMD ----
  wire [31:0] cmd_word;
  wire        cmd_wr, cmd_push;
  wire [4:0]  cmd_used;
  wire        cmd_busy;
  wire [15:0] seq_done;
  wire [7:0]  last_op;
  wire [15:0] last_cycles;

  // ---- CMD ↔ 引擎 ----
  wire        cmd_start;
  wire [7:0]  cmd_op, cmd_nwords;
  wire [15:0] cmd_flags;
  wire [31:0] par_data;
  wire        par_valid;
  wire        par_ready;          // 选通后的 ready（回 gpu_cmd）
  wire        cmd_done;           // 选通后的 done（回 gpu_cmd）

  wire        par_ready_2d, par_ready_3d;
  wire        par_valid_2d = par_valid && !is3d;
  wire        cmd_done_2d, done_3d, busy_3d;
  reg         start_3d;
  reg         is3d;               // 当前命令是不是 3D（cmd_start 时锁存）
  reg  [7:0]  op3, n3, p3cnt;
  reg  [31:0] p3 [0:7];

  wire par_ready_3d_w = is3d && (p3cnt < n3) && !start_3d;
  assign par_ready_3d = par_ready_3d_w;
  assign par_ready    = is3d ? par_ready_3d : par_ready_2d;
  assign cmd_done     = is3d ? done_3d : cmd_done_2d;

  // ★ 2026-11-01 修：`cmd_start` 必须按 op **分派**，不能同时喂给两个引擎。
  //   原来 u_2d 也收到 3D 命令的 cmd_start，于是它进入"等参数"状态，而参数被
  //   `par_valid_2d = par_valid && !is3d` 挡在门外 ⇒ **2D 引擎永久挂住**，之后每条
  //   2D 命令都不再回 cmd_done；表现是 `gpu_cmd` 停在 S_DONE、FIFO 里后续命令永不启动
  //   （上板：CLEAR3D 之后那条 FENCE 卡死，DRAW_TRIS 排在后面一动不动）。
  wire cmd_is3d = (cmd_op == 8'h10) || (cmd_op == 8'h11) || (cmd_op == 8'h12);
  wire start_2d = cmd_start && !cmd_is3d;

  always @(posedge clk) begin
    if (rst) begin
      is3d <= 1'b0; start_3d <= 1'b0; p3cnt <= 8'd0; op3 <= 8'd0; n3 <= 8'd0;
    end else begin
      start_3d <= 1'b0;
      if (cmd_start) begin
        is3d  <= cmd_is3d;
        op3   <= cmd_op;
        n3    <= cmd_nwords;
        p3cnt <= 8'd0;
      end else if (is3d && par_valid && par_ready_3d_w) begin
        p3[p3cnt[2:0]] <= par_data;
        p3cnt <= p3cnt + 8'd1;
        if (p3cnt + 8'd1 == n3) start_3d <= 1'b1;
      end
    end
  end

  // ---- 共用 MEM 口（引擎 → gpu_mem）----
  wire        wr_valid, wr_flush, wr_idle;
  wire [31:0] wr_addr;
  wire [63:0] wr_data;
  wire [7:0]  wr_strb;
  wire        wr_ready;

  wire        rd_req, rd_busy;
  wire [31:0] rd_addr;
  wire [7:0]  rd_beats;
  wire [63:0] rd_data;
  wire        rd_valid, rd_last;

  // 2D 侧
  wire        wr_valid_2d, wr_flush_2d;
  wire [31:0] wr_addr_2d;
  wire [63:0] wr_data_2d;
  wire [7:0]  wr_strb_2d;
  wire        rd_req_2d;
  wire [31:0] rd_addr_2d;
  wire [7:0]  rd_beats_2d;

  // 3D 侧
  wire        wr_valid_3d, wr_flush_3d;
  wire [31:0] wr_addr_3d;
  wire [63:0] wr_data_3d;
  wire [7:0]  wr_strb_3d;
  wire        rd_req_3d;
  wire [31:0] rd_addr_3d;
  wire [7:0]  rd_beats_3d;
  wire [7:0]  dbg_state_3d;
  wire [1:0]  dbg_wrs;
  wire [4:0]  dbg_wcnt;
  wire [1:0]  dbg_rds;

  assign wr_valid = is3d ? wr_valid_3d : wr_valid_2d;
  assign wr_flush = is3d ? wr_flush_3d : wr_flush_2d;
  assign wr_addr  = is3d ? wr_addr_3d  : wr_addr_2d;
  assign wr_data  = is3d ? wr_data_3d  : wr_data_2d;
  assign wr_strb  = is3d ? wr_strb_3d  : wr_strb_2d;
  assign rd_req   = is3d ? rd_req_3d   : rd_req_2d;
  assign rd_addr  = is3d ? rd_addr_3d  : rd_addr_2d;
  assign rd_beats = is3d ? rd_beats_3d : rd_beats_2d;

  // 读路径边界探针（上板用，CSR 0x030..0x03C 只读）
  wire [31:0] dbg_rd_ar;
  wire [7:0]  dbg_rd_cnt, dbg_rd_len;
  wire [31:0] dbg_rd_b01, dbg_rd_b23;

  gpu_csr u_csr (
      .clk(clk), .rst(rst),
      .s_awaddr(s_awaddr), .s_awvalid(s_awvalid), .s_awready(s_awready),
      .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wvalid(s_wvalid), .s_wready(s_wready),
      .s_bvalid(s_bvalid), .s_bready(s_bready),
      .s_araddr(s_araddr), .s_arvalid(s_arvalid), .s_arready(s_arready),
      .s_rdata(s_rdata), .s_rvalid(s_rvalid), .s_rready(s_rready),
      .cmd_word(cmd_word), .cmd_wr(cmd_wr), .cmd_push(cmd_push),
      .cmd_used(cmd_used), .cmd_busy(cmd_busy), .seq_done(seq_done),
      .last_op(last_op), .last_cycles(last_cycles),
      .flip_toggle(flip_toggle), .vsync(vsync),
      .dbg_st3d(dbg_state_3d), .dbg_mem({dbg_wrs, dbg_wcnt, 1'b0}),
      .dbg_rd_ar(dbg_rd_ar), .dbg_rd_cnt(dbg_rd_cnt), .dbg_rd_len(dbg_rd_len),
      .dbg_rd_b01(dbg_rd_b01), .dbg_rd_b23(dbg_rd_b23)
  );

  gpu_cmd u_cmd (
      .clk(clk), .rst(rst),
      .wr_word(cmd_word), .wr_en(cmd_wr), .wr_push(cmd_push),
      .used(cmd_used), .busy(cmd_busy),
      .cmd_start(cmd_start), .cmd_op(cmd_op), .cmd_nwords(cmd_nwords), .cmd_flags(cmd_flags),
      .par_data(par_data), .par_valid(par_valid), .par_ready(par_ready),
      .cmd_done(cmd_done),
      .seq_done(seq_done), .last_op(last_op), .last_cycles(last_cycles),
      .dbg_state(), .dbg_left()
  );

  gpu_2d u_2d (
      .clk(clk), .rst(rst),
      .cmd_start(start_2d), .cmd_op(cmd_op), .cmd_nwords(cmd_nwords), .cmd_flags(cmd_flags),
      .par_data(par_data), .par_valid(par_valid_2d), .par_ready(par_ready_2d),
      .cmd_done(cmd_done_2d),
      .wr_valid(wr_valid_2d), .wr_addr(wr_addr_2d), .wr_data(wr_data_2d), .wr_strb(wr_strb_2d),
      .wr_ready(wr_ready), .wr_flush(wr_flush_2d), .wr_idle(wr_idle),
      .rd_req(rd_req_2d), .rd_addr(rd_addr_2d), .rd_beats(rd_beats_2d), .rd_busy(rd_busy),
      .rd_data(rd_data), .rd_valid(rd_valid), .rd_last(rd_last),
      .dbg_state(), .dbg_px(), .dbg_npx(), .dbg_nflush(),
      .dbg_brow(), .dbg_bcx(), .dbg_bcxe(), .dbg_cpx()
  );

  gpu_3d u_3d (
      .clk(clk), .rst(rst),
      .start(start_3d), .op(op3),
      .p0(p3[0]), .p1(p3[1]), .p2(p3[2]), .p3(p3[3]),
      .p4(p3[4]), .p5(p3[5]), .p6(p3[6]), .p7(p3[7]),
      .busy(busy_3d), .done(done_3d),
      .rd_req(rd_req_3d), .rd_addr(rd_addr_3d), .rd_beats(rd_beats_3d),
      .rd_busy(rd_busy), .rd_data(rd_data), .rd_valid(rd_valid), .rd_last(rd_last),
      .wr_valid(wr_valid_3d), .wr_addr(wr_addr_3d), .wr_data(wr_data_3d), .wr_strb(wr_strb_3d),
      .wr_ready(wr_ready), .wr_flush(wr_flush_3d), .wr_idle(wr_idle),
      .dbg_state(dbg_state_3d)
  );

  gpu_mem u_mem (
      .clk(clk), .rst(rst),
      .rd_req(rd_req), .rd_addr(rd_addr), .rd_beats(rd_beats), .rd_busy(rd_busy),
      .rd_data(rd_data), .rd_valid(rd_valid), .rd_last(rd_last),
      .wr_valid(wr_valid), .wr_addr(wr_addr), .wr_data(wr_data), .wr_strb(wr_strb),
      .wr_ready(wr_ready), .wr_flush(wr_flush),
      .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize), .m_arburst(m_arburst),
      .m_arvalid(m_arvalid), .m_arready(m_arready),
      .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready),
      .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize), .m_awburst(m_awburst),
      .m_awvalid(m_awvalid), .m_awready(m_awready),
      .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid), .m_wready(m_wready),
      .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
      .dbg_wrs(dbg_wrs), .dbg_wcnt(dbg_wcnt), .dbg_rds(dbg_rds), .wr_idle(wr_idle),
      .dbg_rd_ar(dbg_rd_ar), .dbg_rd_cnt(dbg_rd_cnt), .dbg_rd_len(dbg_rd_len),
      .dbg_rd_b01(dbg_rd_b01), .dbg_rd_b23(dbg_rd_b23)
  );

endmodule
