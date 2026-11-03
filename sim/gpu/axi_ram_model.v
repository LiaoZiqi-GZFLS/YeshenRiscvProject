// axi_ram_model.v —— 最小 AXI4 从模型（64-bit），给 GPU 单元 TB 用。
// 只实现 GPU 需要的形状：AR burst 读、AW+W burst 写、B 响应。
// 地址按 8 B 字索引（addr[AW+2:3]），TB 可直接读 mem[] 做逐字节核对。
module axi_ram_model #(
    parameter AW = 16,           // 2^AW 个 8 B 字
    parameter INIT_FILE = "",    // 非空则 $readmemh 预载
    // NO_HOLD=1 模拟**板级简化 AXI 从方**：不看 rready、逐拍推进（主方没接住就丢），
    // 用来离线复现"板上读 burst 丢头几拍"的现象。
    parameter NO_HOLD = 0,
    // TRUNC32=1 模拟**板级 DDR 用户口**：数据口 256 bit = 32 B/拍，地址低 5 位被吃掉，
    // 突发的起始地址按 32 B 块向下取整（板级实测：dx=40 落到 32、dx=8 落到 0）。
    // 8 B 粒度但非 32 B 对齐的突发会在这一模式下整段下移 —— 正是 gpu10 修的那个缺陷。
    parameter TRUNC32 = 0,
    // RLAT=AR 握手后到首拍 R 的等待拍数（默认 0 = 原行为）。板级 DDR 有几十~几百 ns 的
    // 读延迟，把它拉开才能覆盖"读在飞时被别的动作插进来"的时序包络。
    parameter RLAT = 0
) (
    input  wire        clk,
    input  wire        rst,

    input  wire [31:0] araddr,
    input  wire [7:0]  arlen,
    input  wire        arvalid,
    output wire        arready,
    output reg  [63:0] rdata,
    output reg         rlast,
    output reg         rvalid,
    input  wire        rready,

    input  wire [31:0] awaddr,
    input  wire [7:0]  awlen,
    input  wire        awvalid,
    output wire        awready,
    input  wire [63:0] wdata,
    input  wire [7:0]  wstrb,
    input  wire        wlast,
    input  wire        wvalid,
    output wire        wready,
    output reg  [1:0]  bresp,
    output reg         bvalid,
    input  wire        bready,

    output reg  [31:0] aw_count,
    output reg  [31:0] w_count,
    output reg  [31:0] ar_count,

    // 调试读口（TB 用：组合读出任意 8 B 字）
    input  wire [AW-1:0] dbg_idx,
    output wire [63:0]   dbg_word,
    output wire          dbg_bvalid,
    output wire          dbg_wactive,
    output wire [7:0]    dbg_wleft
);

  assign dbg_word = mem[dbg_idx];
  assign dbg_bvalid = bvalid;
  assign dbg_wactive = w_active;
  assign dbg_wleft = w_left;

  localparam N = (1 << AW);
  reg [63:0] mem [0:N-1];

  integer i;
  initial begin
    for (i = 0; i < N; i = i + 1) mem[i] = 64'd0;
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end

  // ---------------- 读 ----------------
  reg        r_active;
  reg [AW-1:0] r_idx;
  reg [7:0]  r_left;
  reg [7:0]  r_lat;

  assign arready = !r_active && !rvalid;

  always @(posedge clk) begin
    if (rst) begin
      r_active <= 1'b0;
      rvalid   <= 1'b0;
      rlast    <= 1'b0;
      ar_count <= 32'd0;
      r_lat    <= 8'd0;
    end else begin
      if (arvalid && arready) begin
        r_idx    <= (TRUNC32 != 0) ? {araddr[AW+2:5], 2'b00} : araddr[AW+2:3];
        r_left   <= arlen;
        r_active <= 1'b1;
        ar_count <= ar_count + 32'd1;
        r_lat    <= RLAT[7:0];
      end else if (r_lat != 8'd0) begin
        r_lat <= r_lat - 8'd1;
      end
      if (NO_HOLD != 0) begin
        // 简化从方：拍不看 rready，逐拍推进
        if (r_active && r_lat == 8'd0) begin
          rdata  <= mem[r_idx];
          rvalid <= 1'b1;
          rlast  <= (r_left == 8'd0);
          r_idx  <= r_idx + 1'b1;
          if (r_left == 8'd0) r_active <= 1'b0;
          else r_left <= r_left - 8'd1;
        end else begin
          rvalid <= 1'b0;
          rlast  <= 1'b0;
        end
      end else if (r_active && r_lat == 8'd0 && (!rvalid || (rvalid && rready))) begin
        rdata  <= mem[r_idx];
        rvalid <= 1'b1;
        rlast  <= (r_left == 8'd0);
        r_idx  <= r_idx + 1'b1;
        if (r_left == 8'd0) begin
          r_active <= 1'b0;
        end else begin
          r_left <= r_left - 8'd1;
        end
      end else if (rvalid && rready) begin
        rvalid <= 1'b0;
        rlast  <= 1'b0;
      end
    end
  end

  // ---------------- 写 ----------------
  reg        w_active;
  reg [AW-1:0] w_idx;
  reg [7:0]  w_left;

  assign awready = !w_active;
  assign wready  = w_active && !bvalid;

  always @(posedge clk) begin
    if (rst) begin
      w_active <= 1'b0;
      bvalid   <= 1'b0;
      bresp    <= 2'b00;
      aw_count <= 32'd0;
      w_count  <= 32'd0;
    end else begin
      if (awvalid && awready) begin
        w_idx    <= (TRUNC32 != 0) ? {awaddr[AW+2:5], 2'b00} : awaddr[AW+2:3];
        w_left   <= awlen;
        w_active <= 1'b1;
        aw_count <= aw_count + 32'd1;
      end
      if (wvalid && wready) begin
        if (wstrb[0]) mem[w_idx][7:0]   <= wdata[7:0];
        if (wstrb[1]) mem[w_idx][15:8]  <= wdata[15:8];
        if (wstrb[2]) mem[w_idx][23:16] <= wdata[23:16];
        if (wstrb[3]) mem[w_idx][31:24] <= wdata[31:24];
        if (wstrb[4]) mem[w_idx][39:32] <= wdata[39:32];
        if (wstrb[5]) mem[w_idx][47:40] <= wdata[47:40];
        if (wstrb[6]) mem[w_idx][55:48] <= wdata[55:48];
        if (wstrb[7]) mem[w_idx][63:56] <= wdata[63:56];
        w_idx   <= w_idx + 1'b1;
        w_count <= w_count + 32'd1;
        if (w_left == 8'd0) begin
          w_active <= 1'b0;
          bvalid   <= 1'b1;
        end else begin
          w_left <= w_left - 8'd1;
        end
      end
      if (bvalid && bready) bvalid <= 1'b0;
    end
  end

endmodule
