//=============================================================================
// ddr_arbiter_2to1: DDR3Bridge（ID=0）与视频 fram_buf（ID=1）的 256-bit
//                   简化 AXI 2:1 仲裁
//
// DDR IP 侧契约（与 rtl/DDR3Bridge.v / 厂家 fram_buf 一致）：
//   - AW/W/AR 各一条，无 B 通道；R 带 rid（读命令 aruser_id 直通）
//   - 写完成由 axi_wusero_last 反馈（最后一拍之后一拍置 1，单拍脉冲）
//   - AR ID 由主设备指定：桥固定 0，视频固定 1
//
// 本模块：
//   - 写通道：AW+W 成对串行，一次只放行一笔 burst（视频优先，桥其次）
//     视频侧授予只看 awvalid：厂家 wr_ctrl 是 `axi_wvalid = axi_wready`
//     （wvalid 由本模块的 wready 派生），仲裁若同时要求 wvalid 会死锁；
//     桥侧仍要求 awvalid && wvalid（桥有独立的数据缓冲）
//   - 写数据：W 数据/字节使能按 wsel 组合选择（AW 握手后 wsel 稳定），
//     源在握手后一拍换下一拍数据，寄存器打一拍会永远晚一拍
//   - 写完成路由：厂家 wr_ctrl 的 cmd_cnt 只在 `wlast && wvalid && wready`
//     **同拍**递减（wvalid=wready），即 IP 的 wusero_last 与最后一拍 W 同拍。
//     故回送属主必须"当拍优先用 wsel"，last_sel 只兜底晚一拍的 IP 行为。
//     （旧版只用 last_sel：同拍时它还是上一笔的属主 ⇒ 桥写后第一笔视频写
//      丢 wlast ⇒ 厂家行内突发记账错位 ⇒ 屏幕成块错位/随 CPU 流量闪动。）
//   - 桥侧用户口**没有 WVALID**：DDR3Bridge 的写数据由内部 wCdc FIFO 常备，
//     `io_ddrWReady` 高即采样（rtl/DDR3Bridge.v `wTake = io_ddrWReady & deq_valid`）。
//     板级把 b_wvalid 接成**桥的 awvalid**（只表示"有写在手"）；AW 握手后它必落，
//     因此绝不能拿它逐拍门控 W —— m_wvalid 必须整 burst 保持 1（旧直连 IP 的等价行为）。
//   - 读通道：**多未完成**（桥 ≤ BN 笔、视频 ≤ VN 笔在飞；AR 一拍一笔交给 IP，
//     R 按 rid 分流：1=视频，其它=桥）。同一属主的 AR 按序发出、IP 按序回 R ⇒
//     每个口看到的 R 与自己的 AR 同序（与单笔时逐字节同义）。
//     ★ 为什么必须放开：桥内 DEPTH=4 的多未完成（DMA-P0）在旧版被这一级
//       **结构性压成 1** ⇒ NPU 的 8×32B gather 批每批只能一笔一笔往返
//       （板级实测 ≈1.4 µs/32B，输入取数 ~22 MB/s）。`BN=1` 可复现旧行为（负对照）。
//   - 公平：两方都有 AR 请求时轮转（`rr`）；视频 VN=1 ⇒ 视频侧未完成语义与旧版一致，
//     且视频 AR 最多压桥一个 AR 发放槽，不会被桥饿死。
//   - 复位：同步低有效 rstn
//=============================================================================
`timescale 1ns/1ps
module ddr_arbiter_2to1 #(parameter AW=28, parameter BN=4, parameter VN=1)(
    input  wire clk, rstn,
    // ---- 桥侧（ID=0） ----
    input  wire [AW-1:0] b_awaddr, input wire [3:0] b_awlen,
    input  wire b_awvalid, output wire b_awready,
    input  wire [255:0] b_wdata, input wire [31:0] b_wstrb,
    input  wire b_wvalid, output wire b_wready,
    input  wire [AW-1:0] b_araddr, input wire [3:0] b_arlen,
    input  wire b_arvalid, output wire b_arready,
    output wire [255:0] b_rdata, output wire [3:0] b_rid,
    output wire b_rlast, output wire b_rvalid, input wire b_rready,
    // ---- 视频侧（ID=1） ----
    input  wire [AW-1:0] v_awaddr, input wire [3:0] v_awlen,
    input  wire v_awvalid, output wire v_awready,
    input  wire [255:0] v_wdata, input wire [31:0] v_wstrb,
    input  wire v_wvalid, output wire v_wready,
    input  wire [AW-1:0] v_araddr, input wire [3:0] v_arlen,
    input  wire v_arvalid, output wire v_arready,
    output wire [255:0] v_rdata, output wire [3:0] v_rid,
    output wire v_rlast, output wire v_rvalid, input wire v_rready,
    // ---- DDR IP 简化口 ----
    output reg  [AW-1:0] m_awaddr, output reg [3:0] m_awlen,
    output reg  m_awvalid, input wire m_awready,
    output reg  [255:0] m_wdata, output reg [31:0] m_wstrb,
    output reg  m_wvalid, input wire m_wready,
    input  wire m_wusero_last,
    output wire [AW-1:0] m_araddr, output wire [3:0] m_arlen,
    output wire [3:0] m_aruser_id,
    output wire m_arvalid, input wire m_arready,
    input  wire [255:0] m_rdata, input wire [3:0] m_rid,
    input  wire m_rlast, input wire m_rvalid, output wire m_rready,
    output wire b_wlast, output wire v_wlast,
    output reg  [31:0] dbg_v_ar_wait
);
    //=========================================================================
    // 写通道：W_IDLE -> W_AW -> W_DATA -> W_IDLE（一次一笔 burst）
    //=========================================================================
    localparam [1:0] W_IDLE = 2'd0, W_AW = 2'd1, W_DATA = 2'd2;

    reg [1:0] wst;
    reg       wsel;        // 当前 burst 属主：0=桥，1=视频
    reg [3:0] wleft;       // 本 burst 剩余拍数（当前拍之后还要发的拍数）
    reg       last_sel;    // 最后一拍 W 的属主（用于 wusero_last 回送）

    always @(posedge clk) begin
        if (!rstn) begin
            wst       <= W_IDLE;
            wsel      <= 1'b0;
            wleft     <= 4'd0;
            last_sel  <= 1'b0;
            m_awvalid <= 1'b0;
            m_awaddr  <= {AW{1'b0}};
            m_awlen   <= 4'd0;
            m_wvalid  <= 1'b0;
        end else begin
            case (wst)
            W_IDLE: begin
                // 视频优先（厂家 fram_buf 的 axi_wvalid = axi_wready，
                // 此处不能等 wvalid，否则死锁）；桥侧要求 awvalid && wvalid
                if (v_awvalid) begin
                    wsel      <= 1'b1;
                    m_awaddr  <= v_awaddr;
                    m_awlen   <= v_awlen;
                    m_awvalid <= 1'b1;
                    wst       <= W_AW;
                end else if (b_awvalid && b_wvalid) begin
                    wsel      <= 1'b0;
                    m_awaddr  <= b_awaddr;
                    m_awlen   <= b_awlen;
                    m_awvalid <= 1'b1;
                    wst       <= W_AW;
                end
            end
            W_AW: if (m_awready) begin
                m_awvalid <= 1'b0;
                m_wvalid  <= 1'b1;      // 两侧数据都常备，整 burst 保持
                wleft     <= wsel ? v_awlen : b_awlen;
                wst       <= W_DATA;
            end
            W_DATA: if (m_wready) begin
                if (wleft == 4'd0) begin
                    last_sel <= wsel;
                    m_wvalid <= 1'b0;
                    wst      <= W_IDLE;
                end else begin
                    wleft <= wleft - 4'd1;
                end
            end
            default: wst <= W_IDLE;
            endcase
        end
    end

    // W 数据直接来自被授予的源：AW 握手后 wsel 保持稳定，源按 AXI 规则
    // 在每拍握手后才换下一拍数据，组合选择才能跟上背靠背 beat
    always @(*) begin
        m_wdata = wsel ? v_wdata : b_wdata;
        m_wstrb = wsel ? v_wstrb : b_wstrb;
    end

    assign b_awready = (wst == W_AW) && (wsel == 1'b0) && m_awready;
    assign v_awready = (wst == W_AW) && (wsel == 1'b1) && m_awready;
    assign b_wready  = (wst == W_DATA) && (wsel == 1'b0) && m_wready;
    assign v_wready  = (wst == W_DATA) && (wsel == 1'b1) && m_wready;

    // 写完成只回送给该笔 burst 的属主：
    //   同拍（厂家 IP 的真实行为）-> 当拍 wsel 就是属主；
    //   晚一拍/更晚 -> burst 已结束，用 last_sel 兜底。
    wire wowner_now = (wst == W_DATA) ? wsel : last_sel;
    assign b_wlast = m_wusero_last && !wowner_now;
    assign v_wlast = m_wusero_last &&  wowner_now;

    //=========================================================================
    // 读通道：多未完成（AR 握手寄存器 + 每主方未完成计数 + 轮转仲裁）
    //   每拍最多把**一笔** AR 交给 IP（ar_hold 是握手寄存器，等 m_arready）；
    //   未完成数 = 已递交 IP 的 AR − 已回来的 rlast（按 rid 记到各自名下）。
    //   桥/视频的 AR 按各自的到达顺序发出 ⇒ IP 按序回 R 时每个口都保序。
    //=========================================================================
    reg        ar_hold;          // 1 = 握手寄存器里有一笔尚未被 IP 收下的 AR
    reg [AW-1:0] ar_haddr;
    reg [3:0]    ar_hlen;
    reg          ar_hid;         // 0=桥 1=视频
    reg [2:0]    b_out, v_out;   // 在飞笔数（0..BN / 0..VN）；BN=4 时 3 位够
    reg          rr;             // 0=视频优先 / 1=桥优先（两方都有请求时轮转）

    wire hold_free = !ar_hold;
    wire b_can = hold_free && (b_out < BN);
    wire v_can = hold_free && (v_out < VN);
    wire b_pend = b_arvalid && b_can;
    wire v_pend = v_arvalid && v_can;
    wire sel_v = v_pend && (!b_pend || !rr);
    wire sel_b = b_pend && !sel_v;

    assign b_arready = sel_b;
    assign v_arready = sel_v;

    assign m_arvalid = ar_hold;
    assign m_araddr  = ar_haddr;
    assign m_arlen   = ar_hlen;
    assign m_aruser_id = ar_hid ? 4'h1 : 4'h0;

    wire ar_fire  = m_arvalid && m_arready;
    wire rl_fire  = m_rvalid && m_rlast && m_rready;
    wire b_inc = ar_fire && !ar_hid;
    wire v_inc = ar_fire &&  ar_hid;
    wire b_dec = rl_fire && (m_rid != 4'h1);
    wire v_dec = rl_fire && (m_rid == 4'h1);

    always @(posedge clk) begin
        if (!rstn) begin
            ar_hold       <= 1'b0;
            ar_haddr      <= {AW{1'b0}};
            ar_hlen       <= 4'd0;
            ar_hid        <= 1'b0;
            b_out         <= 3'd0;
            v_out         <= 3'd0;
            rr            <= 1'b0;
            dbg_v_ar_wait <= 32'd0;
        end else begin
            // 视频读请求挂起拍数（饱和/回绕均可，这里自然回绕）
            if (v_arvalid && !v_arready)
                dbg_v_ar_wait <= dbg_v_ar_wait + 32'd1;

            // AR 握手 → 握手寄存器（一次一笔；与"IP 收下"同一拍不会冲突：
            // 两者都要求 hold_free）
            if (sel_b) begin
                ar_hold  <= 1'b1;
                ar_haddr <= b_araddr;
                ar_hlen  <= b_arlen;
                ar_hid   <= 1'b0;
                rr       <= 1'b1;
            end else if (sel_v) begin
                ar_hold  <= 1'b1;
                ar_haddr <= v_araddr;
                ar_hlen  <= v_arlen;
                ar_hid   <= 1'b1;
                rr       <= 1'b0;
            end
            // IP 收下 ⇒ 释放握手寄存器（下一拍可再接一笔）
            if (ar_fire) ar_hold <= 1'b0;

            // 未完成计数：同拍"收一笔 + 回一笔"自然抵消
            b_out <= b_out + (b_inc ? 3'd1 : 3'd0) - (b_dec ? 3'd1 : 3'd0);
            v_out <= v_out + (v_inc ? 3'd1 : 3'd0) - (v_dec ? 3'd1 : 3'd0);
        end
    end

    // R 通道按 rid 分流：1=视频，其它=桥；rready 也按 rid 选择
    assign m_rready = (m_rid == 4'h1) ? v_rready : b_rready;
    assign b_rvalid = m_rvalid && (m_rid != 4'h1);
    assign v_rvalid = m_rvalid && (m_rid == 4'h1);
    assign b_rdata  = m_rdata;
    assign v_rdata  = m_rdata;
    assign b_rid    = m_rid;
    assign v_rid    = m_rid;
    assign b_rlast  = m_rlast;
    assign v_rlast  = m_rlast;
endmodule
