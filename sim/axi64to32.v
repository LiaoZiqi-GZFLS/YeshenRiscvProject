// ============================================================================
// axi64to32 —— **仿真装置专用** 的 AXI4 位宽拆位桥（64bit 主口 → 32bit 从口）
//
// 为什么需要它（Task 13 的装置约束，不是设计选择）：
//   · 核的取指/数据 mem 口在 64bit 生成（rtl64/NaxSocMini.v）下是 **64bit AXI**；
//   · 但 NaxMiniGlue（Chisel 生成产物，已归档）的 cpuMem 从口**硬编码 32bit**，
//     sim/tb_naxmini.cpp（已归档，且**没有** AXI_DATA_BYTES 宏）的内存模型也只有 32bit。
//   ⇒ 想用"判据装置（uart_txd 线上解码 + 16550）"跑 64bit 网表，就**必须**在这两者之间
//     放一个位宽桥。桥放在**仿真装置**里（sim/），不改任何交付件。
//
// 语义（**逐字节确定性**，可离线验算）：
//   设上游突发 size=S、len=L、起始地址 A（AXI 要求 A 按 1<<S 对齐），每拍字节数 W=1<<S。
//   本桥只改"每拍几个字节"，不改字节流的**绝对地址顺序**：
//     S == 3（整行 8B/beat）：下游 size=2、len=2L+1（每拍 4B），
//        第 j 个下游 beat 地址 a_j = A + 4j，取值 = (上游当前 beat 的 64bit 字 >> (8*(a_j%8)))
//        ⇒ j 偶 = 低半，j 奇 = 高半；**低半永远在前**（顺序由地址决定，不由状态机决定）。
//     S <= 2（窄传输）：下游 size=S（**不变**）、len=L（不变）、地址 a_j = A + W*j（不变），
//        取值 = (该 64bit 字 >> (8*(a_j%8)))、strb = (上游 strb >> (a_j%8)) & 0xF。
//        （窄拍在 64bit 总线上的字节车道 = 地址 % 8，落到 32bit 侧后车道 = 地址 % 4，
//          所以右移 a_j%8 位即得 —— 对 size=1/2 的多拍窄突发同样成立。）
//   读方向反向拼装：第 j 个下游 beat 的 32bit 数据按 a_j[2] 放回上游 64bit 字的
//        [32*a_j[2] +: 32]（低/高半由**地址位 2** 决定，同样不依赖状态机推断）。
//
// 性质：
//   · 合法 AXI4 背压（u_*ready 由寄存器驱动，不从 valid 组合出来）；
//   · 读：**一次只接收一笔 AR**（ar_live 期间 u_arready=0，master 必须保持 arvalid，符合 AXI）；
//   · 写：一次只接收一笔 AW，W 拍拆完才允许下一笔；B 直通；
//   · id 通道 2bit 直通；burst 固定 INCR（核实测只发 burst=1）；
//   · 越界/非法配置用 $display 打 ERROR（宁可留证据，不静默出错）。
//
// 与"上游那个出问题的 64→32"（32bit 生成里 hub 后的 TileLink WidthAdapter_1 + 32bit
//   Axi4Bridge）**不是**同一段逻辑：这里是 AXI 层、纯字节拆装、地址驱动，无 beat 配对状态。
// ============================================================================
module axi64to32 (
    input  wire        clk,
    input  wire        reset,        // 同步、高有效

    // ---- 上游：核的 mBus（AXI4 64bit）----
    input  wire        u_awvalid,
    output wire        u_awready,
    input  wire [31:0] u_awaddr,
    input  wire [7:0]  u_awlen,
    input  wire [2:0]  u_awsize,
    input  wire [1:0]  u_awburst,
    input  wire [1:0]  u_awid,
    input  wire        u_wvalid,
    output wire        u_wready,
    input  wire [63:0] u_wdata,
    input  wire [7:0]  u_wstrb,
    input  wire        u_wlast,
    output wire        u_bvalid,
    input  wire        u_bready,
    output wire [1:0]  u_bid,
    output wire [1:0]  u_bresp,
    input  wire        u_arvalid,
    output wire        u_arready,
    input  wire [31:0] u_araddr,
    input  wire [7:0]  u_arlen,
    input  wire [2:0]  u_arsize,
    input  wire [1:0]  u_arburst,
    input  wire [1:0]  u_arid,
    output wire        u_rvalid,
    input  wire        u_rready,
    output wire [63:0] u_rdata,
    output wire [1:0]  u_rid,
    output wire [1:0]  u_rresp,
    output wire        u_rlast,

    // ---- 下游：32bit AXI4（→ NaxMiniGlue.io_cpuMem / tb 内存模型）----
    output wire        d_awvalid,
    input  wire        d_awready,
    output wire [31:0] d_awaddr,
    output wire [7:0]  d_awlen,
    output wire [2:0]  d_awsize,
    output wire [1:0]  d_awburst,
    output wire [1:0]  d_awid,
    output wire        d_wvalid,
    input  wire        d_wready,
    output wire [31:0] d_wdata,
    output wire [3:0]  d_wstrb,
    output wire        d_wlast,
    input  wire        d_bvalid,
    output wire        d_bready,
    input  wire [1:0]  d_bid,
    input  wire [1:0]  d_bresp,
    output wire        d_arvalid,
    input  wire        d_arready,
    output wire [31:0] d_araddr,
    output wire [7:0]  d_arlen,
    output wire [2:0]  d_arsize,
    output wire [1:0]  d_arburst,
    output wire [1:0]  d_arid,
    input  wire        d_rvalid,
    output wire        d_rready,
    input  wire [31:0] d_rdata,
    input  wire [1:0]  d_rid,
    input  wire [1:0]  d_rresp,
    input  wire        d_rlast
);

    // ====================== 写方向：AW/W → 拆分 ======================
    reg        aw_live;      // 已接收 AW、尚未收到 B
    reg        aw_pend;      // 待向下游发 AW（**只发一次**）
    reg [31:0] aw_addr;
    reg [7:0]  aw_len;
    reg [2:0]  aw_size;
    reg [1:0]  aw_id;
    reg        aw_full;      // size==3 ⇒ 每拍拆 2 拍
    reg [31:0] aw_cur;       // 当前上游 beat 的地址
    reg [8:0]  w_left;       // 本写突发**下游**剩余 beat 数
    reg        w_state;      // 0=等上游 W beat，1=发下游 beat
    reg [1:0]  w_sub;        // 当前上游 beat 内已发出的下游 beat 数
    reg [63:0] w_data;
    reg [7:0]  w_strb;
    reg        w_last;

    localparam W_IDLE = 1'b0, W_EMIT = 1'b1;

    wire [8:0] aw_ubytes = aw_full ? 9'd8 : (9'd1 << aw_size);   // 上游每拍字节数
    wire [1:0] w_sub_max = aw_full ? 2'd1 : 2'd0;                // 每上游拍要发几个下游拍
    wire [31:0] w_beat_addr = aw_full ? (aw_cur + {28'd0, w_sub, 2'd0}) : aw_cur;
    wire [2:0]  w_sh = w_beat_addr[2:0];

    assign d_awvalid = aw_pend;
    assign d_awaddr  = aw_addr;
    assign d_awlen   = aw_full ? {aw_len, 1'b1} : aw_len;        // 2*(len+1)-1
    assign d_awsize  = aw_full ? 3'd2 : aw_size;
    assign d_awburst = 2'b01;
    assign d_awid    = aw_id;

    assign d_wvalid  = (w_state == W_EMIT);
    assign d_wdata   = w_data >> {w_sh, 3'b000};                 // >> (8 * (addr%8))
    assign d_wstrb   = (w_strb >> w_sh) & 4'hF;
    assign d_wlast   = w_last && (w_sub == w_sub_max);
    assign u_wready  = aw_live && (w_state == W_IDLE) && (w_left != 9'd0);
    assign u_awready = ~aw_live;

    // B 直通
    assign u_bvalid = d_bvalid;
    assign d_bready = u_bready;
    assign u_bid    = d_bid;
    assign u_bresp  = d_bresp;

    // ====================== 读方向：AR → 拆分，R → 拼回 ======================
    reg        ar_live;      // 已接收 AR、突发未读完
    reg        ar_pend;      // 待向下游发 AR
    reg [31:0] ar_addr;
    reg [7:0]  ar_len;
    reg [2:0]  ar_size;
    reg [1:0]  ar_id;
    reg        ar_full;
    reg [8:0]  rd_left;      // 下游剩余 beat 数
    reg [8:0]  rd_idx;       // 已收到的下游 beat 序号
    reg [31:0] rd_base;      // 上游突发起始地址
    reg [8:0]  rd_ubytes;
    reg        rd_lo_valid;  // 已缓存"低半"下游拍
    reg [31:0] rd_lo;
    reg        rd_out_valid;
    reg [63:0] rd_out;
    reg        rd_out_last;
    reg [1:0]  rd_out_resp;

    wire [31:0] rd_beat_addr = rd_base + (ar_full ? {rd_idx, 2'd0} : (rd_ubytes * rd_idx));
    wire [2:0]  rd_sh = rd_beat_addr[2:0];

    assign u_arready = ~ar_live;
    assign d_arvalid = ar_pend;
    assign d_araddr  = ar_addr;
    assign d_arlen   = ar_full ? {ar_len, 1'b1} : ar_len;
    assign d_arsize  = ar_full ? 3'd2 : ar_size;
    assign d_arburst = 2'b01;
    assign d_arid    = ar_id;

    assign u_rvalid = rd_out_valid;
    assign u_rdata  = rd_out;
    assign u_rlast  = rd_out_last;
    assign u_rid    = ar_id;
    assign u_rresp  = rd_out_resp;
    assign d_rready = ar_live && !ar_pend && !rd_out_valid && (rd_left != 9'd0);

    // 非法配置留证据（跨 4B/8B 边界、len 溢出）
    always @(posedge clk) begin
        if (!reset) begin
            if (u_awvalid && u_awready && (u_awsize == 3'd3) && (u_awaddr[2:0] != 3'd0))
                $display("[AXI64TO32-ERROR] %0t size=3 但 awaddr[2:0]!=0 (addr=%08X)", $time, u_awaddr);
            if (u_arvalid && u_arready && (u_arsize == 3'd3) && (u_araddr[2:0] != 3'd0))
                $display("[AXI64TO32-ERROR] %0t size=3 但 araddr[2:0]!=0 (addr=%08X)", $time, u_araddr);
            if (u_arvalid && u_arready && (u_arsize == 3'd3) && (u_arlen[7] != 1'b0))
                $display("[AXI64TO32-ERROR] %0t 读突发 len=%0d 拆位后超过 256 拍", $time, u_arlen);
            if (u_awvalid && u_awready && (u_awsize == 3'd3) && (u_awlen[7] != 1'b0))
                $display("[AXI64TO32-ERROR] %0t 写突发 len=%0d 拆位后超过 256 拍", $time, u_awlen);
            if (u_arvalid && u_arready && (u_arburst != 2'b01))
                $display("[AXI64TO32-ERROR] %0t 只支持 INCR 突发 (arburst=%b)", $time, u_arburst);
            if (u_awvalid && u_awready && (u_awburst != 2'b01))
                $display("[AXI64TO32-ERROR] %0t 只支持 INCR 突发 (awburst=%b)", $time, u_awburst);
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            aw_live <= 1'b0; aw_pend <= 1'b0; aw_full <= 1'b0; w_left <= 9'd0; w_state <= W_IDLE;
            w_sub <= 2'd0; w_data <= 64'd0; w_strb <= 8'd0; w_last <= 1'b0;
            aw_addr <= 32'd0; aw_len <= 8'd0; aw_size <= 3'd0; aw_id <= 2'd0; aw_cur <= 32'd0;
            ar_live <= 1'b0; ar_pend <= 1'b0; ar_full <= 1'b0;
            ar_addr <= 32'd0; ar_len <= 8'd0; ar_size <= 3'd0; ar_id <= 2'd0;
            rd_left <= 9'd0; rd_idx <= 9'd0; rd_base <= 32'd0; rd_ubytes <= 9'd0;
            rd_lo_valid <= 1'b0; rd_lo <= 32'd0;
            rd_out_valid <= 1'b0; rd_out <= 64'd0; rd_out_last <= 1'b0; rd_out_resp <= 2'd0;
        end else begin
            // ---------- 写 ----------
            if (u_awvalid && u_awready) begin
                aw_live <= 1'b1;
                aw_pend <= 1'b1;
                aw_addr <= u_awaddr;
                aw_len  <= u_awlen;
                aw_size <= u_awsize;
                aw_id   <= u_awid;
                aw_full <= (u_awsize == 3'd3);
                aw_cur  <= u_awaddr;
                // 下游总拍数 = 上游拍数 × 每拍拆分份数
                w_left  <= (u_awsize == 3'd3) ? {u_awlen, 1'b0} + 9'd2 : {1'b0, u_awlen} + 9'd1;
                w_sub   <= 2'd0;
            end
            if (w_state == W_IDLE) begin
                if (u_wvalid && u_wready) begin
                    w_data <= u_wdata; w_strb <= u_wstrb; w_last <= u_wlast;
                    w_sub  <= 2'd0;
                    w_state <= W_EMIT;
                end
            end else begin
                if (d_wvalid && d_wready) begin
                    w_left <= w_left - 9'd1;
                    if (w_sub == w_sub_max) begin
                        w_sub   <= 2'd0;
                        w_state <= W_IDLE;
                        aw_cur  <= aw_cur + aw_ubytes;
                    end else begin
                        w_sub <= w_sub + 2'd1;
                    end
                end
            end
            if (d_awvalid && d_awready) aw_pend <= 1'b0;
            if (d_bvalid && d_bready) aw_live <= 1'b0;

            // ---------- 读 AR ----------
            if (u_arvalid && u_arready) begin
                ar_live <= 1'b1;
                ar_pend <= 1'b1;
                ar_addr <= u_araddr;
                ar_len  <= u_arlen;
                ar_size <= u_arsize;
                ar_id   <= u_arid;
                ar_full <= (u_arsize == 3'd3);
                rd_base <= u_araddr;
                rd_ubytes <= (u_arsize == 3'd3) ? 9'd8 : (9'd1 << u_arsize);
                rd_left <= (u_arsize == 3'd3) ? {u_arlen, 1'b0} + 9'd2 : {1'b0, u_arlen} + 9'd1;
                rd_idx  <= 9'd0;
                rd_lo_valid <= 1'b0;
            end
            if (d_arvalid && d_arready) ar_pend <= 1'b0;

            // ---------- 读数据：下游 32bit 拍 → 上游 64bit 拍 ----------
            if (d_rvalid && d_rready) begin
                rd_left <= rd_left - 9'd1;
                rd_idx  <= rd_idx + 9'd1;
                if (ar_full && !rd_lo_valid) begin
                    // 低半先到（地址位 2 == 0），缓存
                    rd_lo <= d_rdata;
                    rd_lo_valid <= 1'b1;
                    rd_out_resp <= d_rresp;
                end else begin
                    rd_out_valid <= 1'b1;
                    rd_out_last  <= (rd_left == 9'd1);
                    rd_out_resp  <= d_rresp;
                    if (rd_lo_valid)
                        rd_out <= rd_sh[2] ? {d_rdata, rd_lo} : {rd_lo, d_rdata};
                    else
                        rd_out <= rd_sh[2] ? {d_rdata, 32'h0} : {32'h0, d_rdata};
                    rd_lo_valid <= 1'b0;
                end
            end
            if (rd_out_valid && u_rready) begin
                rd_out_valid <= 1'b0;
                if (rd_out_last) ar_live <= 1'b0;
            end
        end
    end

endmodule
