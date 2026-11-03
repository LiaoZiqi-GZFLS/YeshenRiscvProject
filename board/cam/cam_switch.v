//=============================================================================
// cam_switch: 双目相机切换的**控制与时序**（不做数据 mux）
//
// ★★ 2026-10-29 架构修订（上板实测驱动）：**同一时刻只让一路相机出图**。
//
//   证据链（均为上板实测）：
//     · 两路都跑 ⇒ 画面花（形状对、颜色错、满屏杂色），CAM0/CAM1 一样坏；
//     · 帧存两个 bank 抓出来一样坏 ⇒ 不是读错 bank；
//     · 停掉 NPU/CPU 负载重抓，坏点率不变 ⇒ 不是 DDR 争用；
//     · 坏点逐帧换位置、多为单比特翻转（3% 量级）⇒ 采样点被顶出余量，不是映射错；
//     · **把 CAM1 整颗按住复位（212d3a2 诊断版），CAM0 立刻干净** —— 网表和布局
//       一字未改，只是第二路不再活动 ⇒ 是"第二路的活动"把第一路的采样点带出余量。
//
//   ★ 2026-10-30 更正（上板 A/B 推翻上面那条"第二路活动"的归因）：
//     `212d3a2` 那次"按住 CAM1 ⇒ CAM0 干净"只是**相关不是因果**——那版同时给
//     `cmos_8_16bit.pdata_i` 前面插了 `cam_d_d0` 负边沿寄存级（`6626771`），而
//     `camgood`(`5df46d6b`, = `ff5c236` 直连引脚) 在同板同场景下画面干净。
//     真正的根因是**输入 DDR 原语前多了一级寄存器**，与"两路是否同时活动"无关。
//     ⇒ 由此取消 `en0/en1`：两路相机 + 两套前端**常开**，切换只动下游。
//
//   ⚠️ 常开带来两条硬约束（别"顺手改"回去）：
//     · `GTP_CLKBUFGMUX` 靠"两个钟各自的沿"完成握手 ⇒ 任一路 `pixel_clk` 停了，
//       SEL 永远换不过去（输出被钳低 ⇒ 黑屏死锁）⇒ **绝不能在切换时复位某一路**。
//     · `cmos_8_16bit` 的 `pdata_i/de_i/vs_i` 必须直连引脚，前面不许有任何逻辑。
//
//   切换只有两段：① 请求 → 等目标 init_done + pixel_clk 翻转够数（守卫）→ 翻 mux；
//   ② 保持 SW_RST_CYC 让硬宏交接 → 回稳态。过程 wr_ok=0、black=1。
//   守卫的现价值是**掉线保护**：目标没插/没配好/时钟停 ⇒ 不换源，而不是切到死钟上。
//
// 时钟域：
//   clk0/clk1 : 各相机 PCLK（板外，互不相关）—— 本模块不用
//   pix_clk0/1: 两路 cmos 的 pixel_clk（pclk/2）；**两路始终在跑**
//   pix_clk   : GTP_CLKBUFGMUX 选中的那一路，framebuf 写域
//   soc_clk   : 100 MHz 控制域（sel / 切换 FSM）
//   ddr_clk   : 125 MHz，数"换源后写完几个帧"
//   lcd_clk   : 51.9 MHz，输出级黑屏
//
// 三条承重规则（别"顺手改"）：
//   ① 换源前，**目标路的 pixel_clk 必须真的在翻**（pix_tgt 翻转计数 + init_done 双条件）；
//      否则硬宏握手完不成，输出锁死为 0 ⇒ 黑屏。
//   ② 换源后要**保持一个 SW_RST_CYC 窗口**，别让硬宏在交接途中失去旧钟。
//   ③ 切换期 wr_ok=0（上层同时门控 wr_en 与 wr_fsync）：没有 fsync 就不会翻 bank
//      ⇒ DDR 里不会出现"被当成完整帧"的半帧。
//=============================================================================
module cam_switch #(
    parameter integer SW_RST_CYC  = 100000,      // 1 ms @100 MHz：换源后的交接保持窗口
    parameter integer SETTLE_CYC  = 40000000,    // 400 ms @100 MHz：新相机 AEC/AWB 收敛
    parameter integer FRAMES_NEED = 2,           // 换源后至少写满几帧才放行
    parameter integer ALIVE_EDGES = 32           // 判定"目标 pixel_clk 已在跑"的翻转数
)(
    // ---- 相机 PCLK（保留端口，硬宏版本未使用）----
    input  wire        clk0,
    input  wire        clk1,
    // ---- 两路 cmos 的 pixel_clk（pclk/2；只有 en 为 1 的那一路在跑）----
    input  wire        pix_clk0,
    input  wire        pix_clk1,
    input  wire        init_done_0,
    input  wire        init_done_1,
    // ---- 控制（soc_clk）----
    input  wire        soc_clk,
    input  wire        soc_rstn,
    input  wire        sel,           // 0 = cam0
    output wire        ready,         // 所选相机的 init_done（已同步）
    output wire        switch_busy,   // 黑屏或切换窗口内为 1
    // ---- 两路 cmos 的复位（只跟各自 init_done；**切换绝不复位**）----
    output wire        rstn0,
    output wire        rstn1,
    // ---- 无毛刺 pixel_clk mux（送 framebuf 写侧）----
    output wire        pix_clk,
    // ---- pix 域（= pix_clk）----
    input  wire        frame_sof,     // 裁列后包络的帧起脉冲
    output wire        wr_ok,         // 0 = 掐写
    // ---- DDR 帧事件 ----
    input  wire        ddr_clk,
    input  wire        ddr_rstn,
    input  wire        frame_start,   // 每帧一次
    // ---- 显示 ----
    input  wire        lcd_clk,
    input  wire        lcd_rstn,
    output wire        black         // 1 = 黑屏
);

    //-------------------------------------------------------------------------
    // ① sel 同步（soc 域） + 无毛刺 pixel_clk mux（硬宏）
    //-------------------------------------------------------------------------
    reg sel_a, sel_s;
    always @(posedge soc_clk or negedge soc_rstn) begin
        if (!soc_rstn) begin sel_a <= 1'b0; sel_s <= 1'b0; end
        else           begin sel_a <= sel;  sel_s <= sel_a; end
    end

    // mux 的 SEL 用 mux_sel_r（比 sel_s 慢：要等目标钟活、并保持到旧路关掉之后）
    reg mux_sel_r;

    GTP_CLKBUFGMUX #(
        .TRIGGER_MODE ("NEGEDGE"),
        .SIM_DEVICE   ("LOGOS2")
    ) u_camwr_mux (
        .CLKOUT ( pix_clk ),
        .CLKIN0 ( pix_clk0 ),
        .CLKIN1 ( pix_clk1 ),
        .SEL    ( mux_sel_r )
    );

    //-------------------------------------------------------------------------
    // ② init_done 2FF / ready / cmos 复位
    //-------------------------------------------------------------------------
    reg id0a, id0b, id1a, id1b;
    always @(posedge soc_clk) begin
        id0a <= init_done_0; id0b <= id0a;
        id1a <= init_done_1; id1b <= id1a;
    end
    assign ready = sel_s ? id1b : id0b;

    // 两路 cmos 各自只跟自己的 SCCB 完成（**切换绝不复位**：常开是硬宏握手的前提）
    assign rstn0 = id0b;
    assign rstn1 = id1b;

    //-------------------------------------------------------------------------
    // ③ 切换 FSM（**两路常开，没有 en**）
    //    S_RUN   : 稳态
    //    S_WAIT  : 已请求换源，等 init_done + 目标 pixel_clk 翻转够数（守卫）
    //    S_FLIP  : 已翻 mux，保持 SW_RST_CYC 让硬宏交接
    //    ★ 2026-10-30：删掉 en0/en1。理由（上板 A/B + 硬宏契约）：
    //      ① `GTP_CLKBUFGMUX` 换源要等**两个**输入钟各自的沿才完成握手 ⇒ 任一路
    //         `pixel_clk` 停了，SEL 永远换不过去（"未选中就整颗复位"会直接死锁）；
    //      ② 相机侧 `cmos_8_16bit` 的输入必须直连引脚，前面的任何门控都会毁颜色；
    //      ③ 两路常开还顺带换来"换源不带起振等待"——切换只剩掐写→翻钟→计数→放行。
    //    代价：两颗相机 + 两套前端始终在跑（板上本来就是这样供电的）。
    //-------------------------------------------------------------------------
    localparam S_RUN   = 3'd0;
    localparam S_WAIT  = 3'd1;
    localparam S_FLIP  = 3'd2;

    reg [2:0]  st;
    reg [31:0] tmr;
    reg [7:0]  alive;

    wire id_tgt = sel_s ? id1b : id0b;

    // sel 在 S_WAIT 期间被改主意：清零翻转计数，且当拍不许换源
    //   （否则可能拿"上一路"的沿去确认"这一路"，把 mux 换到一个不跑的钟上）
    reg sel_d;
    always @(posedge soc_clk or negedge soc_rstn) begin
        if (!soc_rstn) sel_d <= 1'b0;
        else           sel_d <= sel_s;
    end
    wire sel_chg = (sel_s != sel_d);

    // 目标路 pixel_clk 的翻转检测（soc_clk 域采样；翻转计数 = 那个钟真的在跑）
    wire pix_tgt = sel_s ? pix_clk1 : pix_clk0;
    reg q0, q1, q2;
    always @(posedge soc_clk) begin q0 <= pix_tgt; q1 <= q0; q2 <= q1; end
    wire tgt_edge = q1 ^ q2;

    always @(posedge soc_clk or negedge soc_rstn) begin
        if (!soc_rstn) begin
            st <= S_RUN; tmr <= 32'd0; alive <= 8'd0;
            mux_sel_r <= 1'b0;
        end else begin
            case (st)
            S_RUN: begin
                if (sel_s != mux_sel_r) begin
                    alive <= 8'd0;
                    st    <= S_WAIT;
                end
            end
            S_WAIT: begin
                // 守卫：目标 init_done 到齐 + 它的 pixel_clk 真的在翻，才准换源。
                //   （两路常开时这条几乎瞬间满足；它的价值是**掉线保护**：相机没插 /
                //     没配好 / 时钟停了，宁可不换源，也不把写域切到一个停摆的钟上。）
                if (sel_chg) alive <= 8'd0;
                else if (tgt_edge && alive != 8'hFF) alive <= alive + 8'd1;
                if (!sel_chg && id_tgt && alive >= ALIVE_EDGES) begin
                    mux_sel_r <= sel_s;
                    tmr       <= SW_RST_CYC;
                    st        <= S_FLIP;
                end
            end
            S_FLIP: begin
                if (tmr != 32'd0) tmr <= tmr - 32'd1;
                else              st  <= S_RUN;
            end
            default: st <= S_RUN;
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // ④ pix 域：wr_ok —— 稳态且 ready 之后、再过第一个 frame_sof 才放行
    //-------------------------------------------------------------------------
    wire pix_rstn = ready & (st == S_RUN);

    reg w0, w1, wr_ok_r;
    always @(posedge pix_clk or negedge pix_rstn) begin
        if (!pix_rstn) begin
            w0 <= 1'b0; w1 <= 1'b0; wr_ok_r <= 1'b0;
        end else begin
            w0 <= 1'b1;
            w1 <= w0;
            if (!w1)            wr_ok_r <= 1'b0;
            else if (frame_sof) wr_ok_r <= 1'b1;
        end
    end
    assign wr_ok = wr_ok_r;

    //-------------------------------------------------------------------------
    // ⑤ ddr 域：换源后已写满多少个完整帧（跟 mux_sel_r 同口径）
    //-------------------------------------------------------------------------
    reg ms0, ms1;
    always @(posedge ddr_clk) begin ms0 <= mux_sel_r; ms1 <= ms0; end

    reg [7:0] fcnt;
    always @(posedge ddr_clk or negedge ddr_rstn) begin
        if (!ddr_rstn)          fcnt <= 8'd0;
        else if (ms0 != ms1)    fcnt <= 8'd0;
        else if (frame_start && fcnt != 8'hFF) fcnt <= fcnt + 8'd1;
    end
    wire frames_ok = (fcnt >= FRAMES_NEED);

    //-------------------------------------------------------------------------
    // ⑥ 黑屏 FSM（soc 域）+ 跨到 lcd
    //   置黑：sel 变了 / 切换中 / 复位
    //   放行：ready ∧ frames_ok ∧ SETTLE_CYC 到
    //-------------------------------------------------------------------------
    reg fo0, fo1;
    reg [31:0] settle_cnt;
    reg        black_r;
    always @(posedge soc_clk or negedge soc_rstn) begin
        if (!soc_rstn) begin
            fo0 <= 1'b0; fo1 <= 1'b0; settle_cnt <= SETTLE_CYC; black_r <= 1'b1;
        end else begin
            fo0 <= frames_ok; fo1 <= fo0;
            if (sel_s != mux_sel_r || st != S_RUN) begin
                black_r    <= 1'b1;
                settle_cnt <= SETTLE_CYC;
            end else if (black_r) begin
                if (settle_cnt != 32'd0)      settle_cnt <= settle_cnt - 32'd1;
                else if (ready && fo1)        black_r    <= 1'b0;
            end
        end
    end
    assign switch_busy = black_r | (st != S_RUN);

    reg b0, b1;
    always @(posedge lcd_clk or negedge lcd_rstn) begin
        if (!lcd_rstn) begin b0 <= 1'b1; b1 <= 1'b1; end
        else begin b0 <= black_r; b1 <= b0; end
    end
    assign black = b1;

endmodule
