// gpu_csr.v —— GPU 寄存器窗（AXI4-Lite 从口，窗内 12 位偏移）。
// 寄存器口径见 rtl/gpu/gpu_regs.vh 与 spec §4.1。
//
// 约定：
//   · 单拍读写（与 gpio/console 同款）：写要 awvalid && wvalid 同时有效才应答。
//   · CMD_DATA 写：把字推进 FIFO，不触发；CMD_PUSH 写：推进并触发。
//   · FLIP 写 1：pending=1，等 vsync 到来时清 pending 并翻转 flip_toggle（帧起点生效）。
//   · 未实现的窗内偏移：读回 0、写忽略（窗外译码在 glue，见 T5）。
module gpu_csr (
    input  wire        clk,
    input  wire        rst,

    // AXI4-Lite 从口（12 位偏移）
    input  wire [11:0] s_awaddr,
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wvalid,
    output wire        s_wready,
    output reg         s_bvalid,
    input  wire        s_bready,
    input  wire [11:0] s_araddr,
    input  wire        s_arvalid,
    output wire        s_arready,
    output reg  [31:0] s_rdata,
    output reg         s_rvalid,
    input  wire        s_rready,

    // 命令 FIFO 接口
    output wire [31:0] cmd_word,
    output wire        cmd_wr,
    output wire        cmd_push,
    input  wire [4:0]  cmd_used,
    input  wire        cmd_busy,
    input  wire [15:0] seq_done,
    input  wire [7:0]  last_op,
    input  wire [15:0] last_cycles,

    // 显示
    output reg         flip_toggle,
    input  wire        vsync,

    // 3D 引擎 FSM 状态（只读；上板定位 3D 挂死用）
    input  wire [7:0]  dbg_st3d,
    // gpu_mem 写侧状态 {wrs[1:0], wcnt[4:0], 1'b0}（只读；上板定位挂死用）
    input  wire [7:0]  dbg_mem,

    // 读路径边界探针（只读；上板定位读拍丢失用）
    input  wire [31:0] dbg_rd_ar,
    input  wire [7:0]  dbg_rd_cnt,
    input  wire [7:0]  dbg_rd_len,
    input  wire [31:0] dbg_rd_b01,
    input  wire [31:0] dbg_rd_b23
);

  localparam [11:0] R_ID = 12'h000, R_STATUS = 12'h004, R_IRQ_EN = 12'h008,
                    R_IRQ_CLR = 12'h00C, R_CMD_DATA = 12'h010, R_CMD_PUSH = 12'h014,
                    R_SEQ_DONE = 12'h018, R_FIFO_FREE = 12'h01C,
                    R_SC0 = 12'h020, R_SC1 = 12'h024, R_FLIP = 12'h028, R_DBG = 12'h02C,
                    R_DBG2 = 12'h030, R_DBG3 = 12'h034, R_DBG4 = 12'h038, R_DBG5 = 12'h03C;

  localparam [31:0] ID_MAGIC = 32'h5947_5055;   // "YGPU"

  reg [31:0] sc0, sc1;
  reg [1:0]  irq_en;
  reg        flip_pending;

  // ---- 写通道 ----
  assign s_awready = s_wvalid & (~s_bvalid | s_bready);
  assign s_wready  = s_awvalid & (~s_bvalid | s_bready);

  wire wr_hit = s_awvalid & s_wvalid & s_awready & s_wready;
  reg  [11:0] waddr_q;

  assign cmd_word = s_wdata;
  assign cmd_wr   = wr_hit & ((s_awaddr == R_CMD_DATA) | (s_awaddr == R_CMD_PUSH));
  assign cmd_push = wr_hit & (s_awaddr == R_CMD_PUSH);

  always @(posedge clk) begin
    if (rst) begin
      s_bvalid     <= 1'b0;
      sc0          <= 32'h0000_0000;
      sc1          <= 32'h0258_0400;   // 1024 x 600（右下开区间）
      irq_en       <= 2'b00;
      flip_pending <= 1'b0;
      flip_toggle  <= 1'b0;
    end else begin
      if (wr_hit) begin
        case (s_awaddr)
          R_SC0: sc0 <= s_wdata;
          R_SC1: sc1 <= s_wdata;
          R_IRQ_EN: irq_en <= s_wdata[1:0];
          R_FLIP: if (s_wdata[0]) flip_pending <= 1'b1;
          default: ;
        endcase
        s_bvalid <= 1'b1;
      end else if (s_bvalid && s_bready) begin
        s_bvalid <= 1'b0;
      end
      if (flip_pending && vsync) begin
        flip_pending <= 1'b0;
        flip_toggle  <= ~flip_toggle;
      end
    end
  end

  // ---- 读通道 ----
  reg [31:0] rdata_q;
  assign s_arready = ~s_rvalid | s_rready;

  always @(posedge clk) begin
    if (rst) begin
      s_rvalid <= 1'b0;
      s_rdata  <= 32'd0;
    end else begin
      if (s_arvalid && s_arready) begin
        case (s_araddr)
          R_ID:        rdata_q = ID_MAGIC;
          R_STATUS: begin
            // 位序按 spec §4.1：[0]busy [7:4]fifo_used [8]err [15:9]errcode
            // [16]flip_pending（FLIP 已受理、等 vsync） [17]**flip_toggle 回读**（当前生效的显示 bank）
            rdata_q = 32'd0;
            rdata_q[0]    = (cmd_busy || (cmd_used != 5'd0));
            rdata_q[7:4]  = cmd_used[3:0];
            rdata_q[16]   = flip_pending;
            rdata_q[17]   = flip_toggle;
          end
          R_IRQ_EN:    rdata_q = {30'd0, irq_en};
          R_SEQ_DONE:  rdata_q = {16'd0, seq_done};
          R_FIFO_FREE: rdata_q = {27'd0, (5'd16 - cmd_used)};
          R_SC0:       rdata_q = sc0;
          R_SC1:       rdata_q = sc1;
          R_FLIP:      rdata_q = {31'd0, flip_pending};
          R_DBG:       rdata_q = {last_op, dbg_st3d, last_cycles};   // [23:16] = gpu_3d FSM 状态
          R_DBG2:      rdata_q = dbg_rd_ar;
          R_DBG3:      rdata_q = {dbg_mem, dbg_rd_len, dbg_rd_cnt, 8'hA5};
          R_DBG4:      rdata_q = dbg_rd_b01;
          R_DBG5:      rdata_q = dbg_rd_b23;
          default:     rdata_q = 32'd0;
        endcase
        s_rdata  <= rdata_q;
        s_rvalid <= 1'b1;
      end else if (s_rvalid && s_rready) begin
        s_rvalid <= 1'b0;
      end
    end
  end

endmodule
