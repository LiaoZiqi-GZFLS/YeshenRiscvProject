// gpu_mem.v —— GPU 共用读引擎 + 写合并引擎（64-bit AXI4 主口）。
//
// 契约（与 glue 的 io.dmaMem 同形，见 YeshenSocGlue.scala §3.5）：
//   · 同一时刻只有读或写一类在飞；上层（gpu_cmd）串行保证，本模块不做并发。
//   · 读：一次 burst，rd_beats = beat 数-1（≤15 ⇒ 最多 16 拍 = 128 B）；rlast 必须
//     恰好回到第 (rd_beats+1) 拍才释放（**不能**靠 rready 自释放）。
//   · 写：流式 64-bit 字，地址在 32 B 内递增；凑满 16 拍或收到 wr_flush 发一次 burst。
//     合并窗口内地址必须连续（上层按行/按块产出保证）；越界回绕由上层负责。
//
// ★ 总线粒度：DDR 用户口是 **256-bit / 32 B 每拍**（`io_ddrAwAddr` 是 32-bit 字地址，
//   低 5 位由 IP 按 32 B 块吃掉）。实测（gpu9 + gpudiag）：8 B 对齐但不 32 B 对齐的
//   burst 会被整段**下移**到 32 B 块首（dx=40 落到 x=32、dx=8 落到 x=0；FILL 因为
//   行首天然对齐所以一直是好的）。因此本模块对外仍是 8 B 粒度，对内做转换：
//     · 写：burst 基址向下取 32 B，前面补 pad=(addr[4:3]) 个 strb=0 的空拍；
//     · 读：从 32 B 基址取，多取 pad 拍并在交付前丢掉。
//   上层（gpu_2d）仍可传任意 8 B 对齐地址。
module gpu_mem (
    input  wire        clk,
    input  wire        rst,

    // 读请求
    input  wire        rd_req,
    input  wire [31:0] rd_addr,
    input  wire [7:0]  rd_beats,     // beat 数-1
    output wire        rd_busy,
    output reg  [63:0] rd_data,
    output reg         rd_valid,
    output reg         rd_last,

    // 写流
    input  wire        wr_valid,
    input  wire [31:0] wr_addr,
    input  wire [63:0] wr_data,
    input  wire [7:0]  wr_strb,
    output wire        wr_ready,
    input  wire        wr_flush,

    // AXI4 主口（64-bit）
    output reg  [31:0] m_araddr,
    output reg  [7:0]  m_arlen,
    output reg  [2:0]  m_arsize,
    output reg  [1:0]  m_arburst,
    output reg         m_arvalid,
    input  wire        m_arready,
    input  wire [63:0] m_rdata,
    input  wire [1:0]  m_rresp,
    input  wire        m_rlast,
    input  wire        m_rvalid,
    output wire        m_rready,

    output reg  [31:0] m_awaddr,
    output reg  [7:0]  m_awlen,
    output reg  [2:0]  m_awsize,
    output reg  [1:0]  m_awburst,
    output reg         m_awvalid,
    input  wire        m_awready,
    output reg  [63:0] m_wdata,
    output reg  [7:0]  m_wstrb,
    output reg         m_wlast,
    output reg         m_wvalid,
    input  wire        m_wready,
    input  wire [1:0]  m_bresp,
    input  wire        m_bvalid,
    output wire        m_bready,

    // 调试（单元 TB 用；综合时被优化掉，不占资源）
    output wire [1:0]  dbg_wrs,
    output wire [4:0]  dbg_wcnt,
    output wire [1:0]  dbg_rds,
    output wire        wr_idle,       // 写侧完全空闲（无缓冲、无 burst 在飞）

    // 上板边界探针：最近一次读 burst 的 AR 地址 / 收到几拍 / 前 4 拍的低 16 位
    output wire [31:0] dbg_rd_ar,
    output wire [7:0]  dbg_rd_cnt,
    output wire [7:0]  dbg_rd_len,
    output wire [31:0] dbg_rd_b01,
    output wire [31:0] dbg_rd_b23
);

  assign m_arsize  = 3'd3;          // 8 B/beat
  assign m_arburst = 2'd1;          // INCR
  assign m_awsize  = 3'd3;
  assign m_awburst = 2'd1;

  // =====================================================================
  // 读引擎
  // =====================================================================
  localparam RD_IDLE = 2'd0, RD_AR = 2'd1, RD_DATA = 2'd2;
  reg [1:0]  rds;
  reg [7:0]  rd_left;               // 还没收到的总线 beat 数（不含当前在途）
  reg [1:0]  rd_skip;               // 32 B 对齐后前导要丢掉的拍数

  assign rd_busy = (rds != RD_IDLE);
  // ⚠️ 读口**常 ready**：本工程的简化 AXI 桥（MemArbiter/DDR3Bridge）不会在 rready=0 时
  //    保持 rvalid，数据可能在 AR 握手的同一拍/下一拍就到。若 rready 由状态派生
  //    （rds==RD_DATA），早到的头几拍会被直接丢掉 —— 上板实测 BLIT 的源少 2 拍
  //    （dst[0]=src[8]、尾部空），而仿真里的 AXI RAM 模型会等 rready，所以闸门全绿。
  assign m_rready = 1'b1;

  // 上板探针：AR 地址 / 请求拍数 / 实收拍数 / 前 4 拍低 16 位
  reg [31:0] dbg_ar_q;
  reg [7:0]  dbg_len_q, dbg_cnt_q;
  reg [15:0] dbg_b0, dbg_b1, dbg_b2, dbg_b3;
  assign dbg_rd_ar  = dbg_ar_q;
  assign dbg_rd_len = dbg_len_q;
  assign dbg_rd_cnt = dbg_cnt_q;
  assign dbg_rd_b01 = {dbg_b1, dbg_b0};
  assign dbg_rd_b23 = {dbg_b3, dbg_b2};

  always @(posedge clk) begin
    if (rst) begin
      rds <= RD_IDLE;
      m_arvalid <= 1'b0;
      rd_valid <= 1'b0;
      rd_last <= 1'b0;
      rd_left <= 8'd0;
      rd_skip <= 2'd0;
      dbg_ar_q <= 32'd0; dbg_len_q <= 8'd0; dbg_cnt_q <= 8'd0;
      dbg_b0 <= 16'd0; dbg_b1 <= 16'd0; dbg_b2 <= 16'd0; dbg_b3 <= 16'd0;
    end else begin
      rd_valid <= 1'b0;
      rd_last  <= 1'b0;
      case (rds)
        RD_IDLE: if (rd_req) begin
          // 32 B 对齐取数，前 pad 拍丢弃（见文件头 ★）
          m_araddr  <= {rd_addr[31:5], 5'b000};
          m_arlen   <= rd_beats + {6'd0, rd_addr[4:3]};
          m_arvalid <= 1'b1;
          rd_left   <= rd_beats + {6'd0, rd_addr[4:3]};
          rd_skip   <= rd_addr[4:3];
          rds       <= RD_AR;
          dbg_ar_q  <= {rd_addr[31:5], 5'b000};
          dbg_len_q <= rd_beats + {6'd0, rd_addr[4:3]};
          dbg_cnt_q <= 8'd0;
        end
        RD_AR: if (m_arvalid && m_arready) begin
          m_arvalid <= 1'b0;
          rds       <= RD_DATA;
        end
        RD_DATA: ;   // 数据拍统一在下面的 if 里处理（不能落到 default 回 IDLE）
        default: rds <= RD_IDLE;
      endcase
      // 数据拍：**不按状态门控**——AR 之后随时可能来（含与 AR 握手同拍的首拍）
      if (m_rvalid && (rds != RD_IDLE)) begin
        if (rd_skip != 2'd0) begin
          rd_skip <= rd_skip - 2'd1;
        end else begin
          rd_data  <= m_rdata;
          rd_valid <= 1'b1;
          rd_last  <= (rd_left == 8'd0);
          // 探针：只记最近一次 burst **交付**的前 4 拍
          dbg_cnt_q <= dbg_cnt_q + 8'd1;
          case (dbg_cnt_q)
            8'd0: dbg_b0 <= m_rdata[15:0];
            8'd1: dbg_b1 <= m_rdata[15:0];
            8'd2: dbg_b2 <= m_rdata[15:0];
            8'd3: dbg_b3 <= m_rdata[15:0];
            default: ;
          endcase
        end
        if (rd_left == 8'd0) rds <= RD_IDLE;
        else rd_left <= rd_left - 8'd1;
      end
    end
  end

  // =====================================================================
  // 写合并引擎
  // =====================================================================
  // 缓冲 16 拍 ×（64 bit 数据 + 8 bit strb）
  reg [63:0] wbuf_d [0:15];
  reg [7:0]  wbuf_s [0:15];
  reg [4:0]  wcnt;                  // 0..16
  reg [31:0] wbase;                 // 缓冲里第一拍的地址

  localparam WR_IDLE = 2'd0, WR_AW = 2'd1, WR_W = 2'd2, WR_B = 2'd3;
  reg [1:0]  wrs;
  reg [4:0]  wsent;                 // 已发的总线 beat 数（AW 握手时已发 0 ⇒ 1）
  reg [1:0]  wpad;                  // 32 B 对齐时前补的空拍数
  reg [4:0]  wtotal;                // 本次 burst 的总 beat 数（wpad + wcnt）

  wire wr_ready_raw = (wrs == WR_IDLE) && (wcnt < 5'd16) && !wr_flush;

  // `WSTALL`（**仅仿真**，run_3d_stall.sh 用 -DWSTALL 打开）：把 wr_ready 按 4 拍给 3 拍
  // 掐掉，制造真实背压。收发两侧看同一个 wr_ready，所以"保持到 ready"的生产者不会重复交付。
  // ⚠️ 只在 TB 侧把 ready 挡给生产者是不行的 —— gpu_mem 内部仍按自己的 ready 收数。
`ifdef WSTALL
  reg [2:0] wst = 3'd0;
  always @(posedge clk) wst <= wst + 3'd1;
  assign wr_ready = wr_ready_raw & (wst[1:0] != 2'b00);
`else
  assign wr_ready = wr_ready_raw;
`endif

  always @(posedge clk) begin
    if (rst) begin
      wcnt <= 5'd0;
      wrs  <= WR_IDLE;
      m_awvalid <= 1'b0;
      m_wvalid  <= 1'b0;
      m_wlast   <= 1'b0;
      wsent     <= 5'd0;
    end else begin
      // ---- 接收 ----
      if (wr_valid && wr_ready) begin
        if (wcnt == 5'd0) wbase <= wr_addr;
        wbuf_d[wcnt[3:0]] <= wr_data;
        wbuf_s[wcnt[3:0]] <= wr_strb;
        wcnt <= wcnt + 5'd1;
      end

      // ---- 发送 FSM ----
      case (wrs)
        WR_IDLE: if ((wcnt != 5'd0) && (wr_flush || (wcnt == 5'd16))) begin
          // 32 B 对齐：基址下取，前面补 pad 个 strb=0 的空拍（见文件头 ★）
          m_awaddr  <= {wbase[31:5], 5'b000};
          // ⚠️ 必须在 5 位里减：直接写 wcnt[3:0]-1 会被 8 位 LHS 扩宽后算成 0xFF
          m_awlen   <= wcnt + {3'd0, wbase[4:3]} - 5'd1;
          wpad      <= wbase[4:3];
          wtotal    <= wcnt + {3'd0, wbase[4:3]};
          m_awvalid <= 1'b1;
          wrs       <= WR_AW;
        end
        WR_AW: if (m_awvalid && m_awready) begin
          m_awvalid <= 1'b0;
          m_wvalid  <= 1'b1;
          m_wdata   <= (wpad != 2'd0) ? 64'd0     : wbuf_d[0];
          m_wstrb   <= (wpad != 2'd0) ? 8'd0      : wbuf_s[0];
          m_wlast   <= (wtotal == 5'd1);
          wsent     <= 5'd1;
          wrs       <= WR_W;
        end
        WR_W: if (m_wvalid && m_wready) begin
          if (wsent == wtotal) begin             // 刚发完的是最后一拍
            m_wvalid <= 1'b0;
            m_wlast  <= 1'b0;
            wrs      <= WR_B;
          end else begin
            m_wdata <= (wsent < {3'd0, wpad}) ? 64'd0
                                              : wbuf_d[wsent[3:0] - wpad];
            m_wstrb <= (wsent < {3'd0, wpad}) ? 8'd0
                                              : wbuf_s[wsent[3:0] - wpad];
            m_wlast <= ((wsent + 5'd1) == wtotal);
            wsent   <= wsent + 5'd1;
          end
        end
        WR_B: if (m_bvalid && m_bready) begin
          wcnt <= 5'd0;
          wrs  <= WR_IDLE;
        end
        default: wrs <= WR_IDLE;
      endcase
    end
  end

  assign m_bready = (wrs == WR_B);
  assign dbg_wrs  = wrs;
  assign dbg_wcnt = wcnt;
  assign dbg_rds  = rds;
  assign wr_idle  = (wrs == WR_IDLE) && (wcnt == 5'd0);

  // 上一笔写还没发完时，接收端必须停住（wr_ready 已覆盖）；这里只防"没 flush 就攒满"
  // —— 攒满 16 拍自动发，见 WR_IDLE 分支。

endmodule
