//=============================================================================
// video_regs: VIDEO 1 KiB CSR 窗（soc_clk 域，窗内偏移 0x000~0x0FF）
//
// 寄存器映射（窗内偏移；窗口基址由胶合块解码，本模块只见低 12 位）：
//   0x000 STATUS        RO  [0] init_done；[1] 写 bank；[31:8] 24-bit 帧序号
//   0x004 DBG           RO  [15:0] 视频读请求等待计数（vid_stall 2FF）
//   0x008 OVERLAY_CTRL  RW  [0] 使能；[1] commit（写 1 触发一拍）；[15:8] 框数
//   0x00C CAM_CTRL      RW  [0] cam_sel（0=cam0；与按键同源，软件写优先）
//                       RO  [1] ready（所选相机 init_done）；[2] busy（切换/黑屏进行中）
//   0x010..0x08F BOX[16] RW 每框 8 B：word0={x1,y1} word1={x2,y2}
//                ★ 位序以 overlay.v 为准：**高 16 位 = x、低 16 位 = y**（2026-10-26 定案；
//                  此前这里写"小端（x1 在低 16）"与 overlay 实现相反，y1cam 按旧注释打包
//                  ⇒ 每个框被沿对角线转置，表现为"检测对、框位置完全不对"。）
//   0x090 VERSION       RO  0x0001_0001
//   0x094 ETH_CTRL      RW  [0] eth_en（H2 读存服务独占）
//   0x098 RST_CTRL      RW  [0] rst_req（写 1 = 请求整片 SoC 复位；由 `rst_ctrl`
//                           产生 20 ms 的 sys_rstn 兑现，**且这个位自己也被那次复位清掉**）
//   0x09C GUI_CTRL      RW  [0] gui_src（0 = LCD 读相机 bank；1 = 读 GUI 帧存
//                           0x9200_0000）。换源在**读帧首**才生效（见 video_passthrough）
//                       RW  [1] gui_bank（GUI 帧存 bank：0 = 0x9200_0000，1 = **0x9280_0000**；
//                            字地址 bit21 = 8 MiB，不是 0x9220_0000）。
//                           与 gui_src 一样在**读帧首**锁存（2026-10-31 GPU 双缓冲）。
//
// 帧事件跨域（frame_toggle 在 ddr_clk 域，每帧翻转）：
//   frame_toggle 2FF（ft1/ft2）+ 1 拍延迟（ft3）做边沿检测 -> 每帧 seq+1，
//   同时把 wr_bank（2FF 后的 wb2）快照进 bank_r；init_done 同样 2FF。
//
// AXI4-Lite 从口：单 outstanding，AW/W 可同拍也可分离；两者都到齐后下一拍
//   执行写并回 bvalid（bresp=00）；读同理（rresp=00）。
//   ovl_wr_en / ovl_commit 都是单拍脉冲。
//   WSTRB 忽略：软件整字写，且 overlay 写口无字节使能。
//=============================================================================
`timescale 1ns/1ps

module video_regs (
    input  wire        clk,        // soc_clk
    input  wire        rstn,       // 同步低有效（异步复位端）

    // AXI4-Lite 从口（窗内偏移）
    input  wire [11:0] s_awaddr,
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wvalid,
    output wire        s_wready,
    output reg         s_bvalid,
    input  wire        s_bready,
    output wire [1:0]  s_bresp,
    input  wire [11:0] s_araddr,
    input  wire        s_arvalid,
    output wire        s_arready,
    output reg  [31:0] s_rdata,
    output reg         s_rvalid,
    input  wire        s_rready,
    output wire [1:0]  s_rresp,

    // 异步帧状态（ddr_clk 域）
    input  wire        frame_toggle,   // 每帧翻转
    input  wire        wr_bank,        // 本帧写 bank
    input  wire        init_done,      // 相机初始化完成
    input  wire [15:0] vid_stall,      // 视频读请求等待计数

    // 相机切换（soc_clk 域）
    input  wire        cam_sel_toggle, // soc_clk：按键翻转（单拍）
    input  wire        cam_rdy,        // 所选相机 init_done
    input  wire        cam_busy,       // 切换/黑屏进行中
    output wire        cam_sel,        // 当前相机（0=cam0）

    // 软复位请求（soc_clk 域，电平，只由 rstn 清）—— 见文件头 0x098
    output wire        rst_req,

    // 读源选择（soc_clk 域，电平）—— 见文件头 0x09C
    output wire        gui_src,
    output wire        gui_bank,

    // overlay 写口（overlay.wr_clk = soc_clk，同域）
    output reg         ovl_wr_en,
    output reg  [4:0]  ovl_wr_addr,    // {box[3:0], word}
    output reg  [31:0] ovl_wr_data,
    output reg         ovl_commit,     // 单拍脉冲
    output reg         ovl_en,
    output reg  [7:0]  ovl_count,

    // H2：以太网读存服务独占开关（1 = 服务接管 MAC 槽；软件须先把 netdev 拉下）
    output reg         eth_en
);

    localparam [11:0] A_STATUS = 12'h000;
    localparam [11:0] A_DBG    = 12'h004;
    localparam [11:0] A_CTRL   = 12'h008;
    localparam [11:0] A_BOX0   = 12'h010;
    localparam [11:0] A_BOXE   = 12'h090;   // 开区间上界
    localparam [11:0] A_VER    = 12'h090;
    localparam [11:0] A_CAMCTRL = 12'h00C;
    localparam [11:0] A_ETHCTRL = 12'h094;   // H2：bit0 = eth_en
    localparam [11:0] A_RSTCTRL = 12'h098;   // 软复位请求（bit0 = rst_req）
    localparam [11:0] A_GUICTRL = 12'h09C;   // 读源选择（bit0 = gui_src）

    assign s_bresp = 2'b00;
    assign s_rresp = 2'b00;

    //-------------------------------------------------------------------------
    // 帧事件/状态跨域：2FF 采样 + 1 拍延迟做边沿
    //-------------------------------------------------------------------------
    reg        ft1, ft2, ft3;
    reg        wb1, wb2;
    reg        id1, id2;
    reg [15:0] st1, st2;

    always @(posedge clk) begin
        if (!rstn) begin
            ft1 <= 1'b0; ft2 <= 1'b0; ft3 <= 1'b0;
            wb1 <= 1'b0; wb2 <= 1'b0;
            id1 <= 1'b0; id2 <= 1'b0;
            st1 <= 16'd0; st2 <= 16'd0;
        end else begin
            ft1 <= frame_toggle; ft2 <= ft1; ft3 <= ft2;
            wb1 <= wr_bank;      wb2 <= wb1;
            id1 <= init_done;    id2 <= id1;
            st1 <= vid_stall;    st2 <= st1;
        end
    end

    wire ft_edge = ft2 ^ ft3;

    reg [23:0] seq;
    reg        bank_r;
    always @(posedge clk) begin
        if (!rstn) begin
            seq    <= 24'd0;
            bank_r <= 1'b0;
        end else if (ft_edge) begin
            seq    <= seq + 24'd1;
            bank_r <= wb2;                 // 写 bank 快照
        end
    end

    //-------------------------------------------------------------------------
    // AXI4-Lite 写通道：AW/W 各自独立捕获，两旗都到齐后一拍执行
    //-------------------------------------------------------------------------
    reg        aw_pend, w_pend;
    reg [11:0] awaddr_q;
    reg [31:0] wdata_q;

    assign s_awready = rstn & ~aw_pend & ~s_bvalid;
    assign s_wready  = rstn & ~w_pend  & ~s_bvalid;

    wire aw_fire = s_awvalid & s_awready;
    wire w_fire  = s_wvalid  & s_wready;
    wire wr_go   = aw_pend & w_pend;       // 前几拍捕获完成

    //-------------------------------------------------------------------------
    // AXI4-Lite 读通道
    //-------------------------------------------------------------------------
    reg        ar_pend;
    reg [11:0] araddr_q;

    assign s_arready = rstn & ~ar_pend & ~s_rvalid;

    wire ar_fire = s_arvalid & s_arready;

    //-------------------------------------------------------------------------
    // CSR 存储
    //-------------------------------------------------------------------------
    reg [31:0] box_shadow [0:31];          // 写镜像（读回用）
    integer    i;

    reg  cam_sel_r;                        // CAM_CTRL[0]（软件写 / 按键翻转共用）
    assign cam_sel = cam_sel_r;

    // RST_CTRL[0]：**电平**、只有 `rstn` 能清。
    //   ★ 承重：rstn = soc_resetn，而 soc_resetn 已被 `sys_rstn` 相与 ⇒ 这次复位
    //     一定把本位置 0 ⇒ 请求不可能"挂住不撤" ⇒ 结构上没有重启自锁。
    reg  rst_req_r;
    assign rst_req = rst_req_r;

    // GUI_CTRL[0]/[1]：电平，普通可写位。
    reg  gui_src_r;
    reg  gui_bank_r;
    assign gui_src  = gui_src_r;
    assign gui_bank = gui_bank_r;

    always @(posedge clk) begin
        if (!rstn) begin
            aw_pend     <= 1'b0;
            w_pend      <= 1'b0;
            awaddr_q    <= 12'd0;
            wdata_q     <= 32'd0;
            s_bvalid    <= 1'b0;
            ar_pend     <= 1'b0;
            araddr_q    <= 12'd0;
            s_rvalid    <= 1'b0;
            s_rdata     <= 32'd0;
            ovl_wr_en   <= 1'b0;
            ovl_wr_addr <= 5'd0;
            ovl_wr_data <= 32'd0;
            ovl_commit  <= 1'b0;
            ovl_en      <= 1'b0;
            ovl_count   <= 8'd0;
            cam_sel_r   <= 1'b0;
            eth_en      <= 1'b0;
            rst_req_r   <= 1'b0;
            gui_src_r   <= 1'b0;
            gui_bank_r  <= 1'b0;
            for (i = 0; i < 32; i = i + 1) box_shadow[i] <= 32'd0;
        end else begin
            // ---- 写通道捕获 ----
            if (aw_fire) begin
                aw_pend  <= 1'b1;
                awaddr_q <= s_awaddr;
            end
            if (w_fire) begin
                w_pend  <= 1'b1;
                wdata_q <= s_wdata;
            end

            // ---- 默认：两个脉冲都只维持一拍 ----
            ovl_wr_en  <= 1'b0;
            ovl_commit <= 1'b0;

            // ---- 按键翻转（软件写优先：同一拍两者都发生时，下面 wr_go 分支的赋值覆盖这里）----
            if (cam_sel_toggle) cam_sel_r <= ~cam_sel_r;

            // ---- 一次写：地址/数据均已捕获 ----
            if (wr_go) begin
                aw_pend  <= 1'b0;
                w_pend   <= 1'b0;
                s_bvalid <= 1'b1;

                if (awaddr_q == A_CTRL) begin
                    // OVERLAY_CTRL：[0] 使能 [1] commit [15:8] 框数
                    ovl_en     <= wdata_q[0];
                    ovl_count  <= wdata_q[15:8];
                    ovl_commit <= wdata_q[1];
                end else if (awaddr_q == A_CAMCTRL) begin
                    // CAM_CTRL[0]：0=cam0 1=cam1（与按键同源，软件优先）
                    cam_sel_r <= wdata_q[0];
                end else if (awaddr_q == A_ETHCTRL) begin
                    eth_en   <= wdata_q[0];
                end else if (awaddr_q == A_RSTCTRL) begin
                    rst_req_r <= wdata_q[0];   // 写 0 可撤销；写 1 由复位自身清
                end else if (awaddr_q == A_GUICTRL) begin
                    gui_src_r  <= wdata_q[0];
                    gui_bank_r <= wdata_q[1];
                end else if (awaddr_q >= A_BOX0 && awaddr_q < A_BOXE) begin
                    // BOX k：box = addr[6:3]-2，word = addr[2]
                    ovl_wr_en   <= 1'b1;
                    ovl_wr_addr <= {awaddr_q[6:3] - 4'd2, awaddr_q[2]};
                    ovl_wr_data <= wdata_q;
                    box_shadow[{awaddr_q[6:3] - 4'd2, awaddr_q[2]}] <= wdata_q;
                end
                // 其余偏移：吞掉写，回 OKAY
            end

            if (s_bvalid && s_bready) s_bvalid <= 1'b0;

            // ---- 读通道 ----
            if (ar_fire) begin
                ar_pend  <= 1'b1;
                araddr_q <= s_araddr;
            end

            if (ar_pend) begin
                ar_pend  <= 1'b0;
                s_rvalid <= 1'b1;
                if (araddr_q >= A_BOX0 && araddr_q < A_BOXE) begin
                    s_rdata <= box_shadow[{araddr_q[6:3] - 4'd2, araddr_q[2]}];
                end else begin
                    case (araddr_q)
                        A_STATUS: s_rdata <= {seq, 6'd0, bank_r, id2};
                        A_DBG:    s_rdata <= {16'd0, st2};
                        A_CTRL:   s_rdata <= {16'd0, ovl_count, 7'd0, ovl_en};
                        A_CAMCTRL: s_rdata <= {29'd0, cam_busy, cam_rdy, cam_sel_r};
                        A_ETHCTRL: s_rdata <= {31'd0, eth_en};
                        A_RSTCTRL: s_rdata <= {31'd0, rst_req_r};
                        A_GUICTRL: s_rdata <= {30'd0, gui_bank_r, gui_src_r};
                        A_VER:    s_rdata <= 32'h0001_0001;
                        default:  s_rdata <= 32'd0;
                    endcase
                end
            end

            if (s_rvalid && s_rready) s_rvalid <= 1'b0;
        end
    end

endmodule
