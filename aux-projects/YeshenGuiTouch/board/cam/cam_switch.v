//=============================================================================
// cam_switch: 双目相机切换的**控制与时序**（不做数据 mux）
//
// ★ 2026-10-27 结构修订（上板实测驱动）：
//   第一版把"两路相机 → 数据 mux + 门控时钟 mux → 单个 cmos_8_16bit"做成一条路。
//   上板结果：**CAM0（不切换）就花——形状/几何正确、颜色错、满屏噪点杂色**；
//   同源旧版（`b1sg`）画面正常。机制：厂家整流级靠 pclk 采样合成 RGB565，采样点必须
//   紧贴引脚；把 mux LUT / 门控时钟插到它前面，在 85k LUT 的整板工程里布线延迟足以
//   把字节配对顶错——而 href/vs 仍对，于是**只毁颜色不毁形状**。
//   （参考工程 cam2lcd_200mini 是 6.5k LUT 的小设计，同结构侥幸能跑。）
//   ⇒ 现在：**每路相机各自一套 `cmos_8_16bit`，各用裸 PCLK**（CAM0 与改动前逐字同构）；
//     本模块只负责 sel 门控、**pixel_clk 的无毛刺 mux**（喂 framebuf 写侧，其后全是 FF）、
//     掐写 wr_ok、事件驱动黑屏。
//
// ★ 时钟 mux 用**硬宏 `GTP_CLKBUFGMUX`**（不是 LUT 门控）：
//   LUT 拼出来的"门控钟"在 PDS 里既不是合法时钟根（`Timing-4121`/`SDC-2030`：建在 LUT 输出
//   脚上的钟会被判非法、随后被优化掉，写侧那一域实际漏约束），也拿不到时钟树的低 skew。
//   该硬宏内部对 SEL 在**两个**输入钟域各做 2FF 同步，切换过程把输出钳在低电平
//   ⇒ 结构上不可能出窄脉冲；输出直接挂在时钟网络上，可作为 `create_clock` 的根（见 fdc）。
//
// 时钟域：
//   clk0/clk1 : 各相机 PCLK（板外，互不相关）—— 本模块不用
//   pix_clk0/1: 两路 cmos 的 pixel_clk（pclk/2），**两路始终在跑**（不受切换复位）
//   pix_clk   : GTP_CLKBUFGMUX 选中的那一路，framebuf 写域
//   soc_clk   : 100 MHz 控制域（sel / 定时器）
//   ddr_clk   : 125 MHz，数"切换后写完几个帧"
//   lcd_clk   : 51.9 MHz，输出级黑屏
//
// 三条承重规则（别"顺手改"）：
//   ① 两路 cmos **永不复位**（只有 SCCB init_done 一门）：pixel_clk 始终在跑。硬宏换源要等
//      **两个**钟各自的沿才完成握手，若某路 pixel_clk 停了，SEL 永远换不过去。
//   ② 换源靠 `GTP_CLKBUFGMUX` 的硬件同步，RTL 里**不要**再自己拼门控（见上面 ★）。
//   ③ 切换期 wr_ok=0（上层同时门控 wr_en 与 wr_fsync）：没有 fsync 就不会翻 bank
//      ⇒ DDR 里不会出现"被当成完整帧"的半帧。
//=============================================================================
module cam_switch #(
    parameter integer SW_RST_CYC  = 100000,      // 1 ms @100 MHz
    parameter integer SETTLE_CYC  = 40000000,    // 400 ms @100 MHz
    parameter integer FRAMES_NEED = 2
)(
    // ---- 相机 PCLK（保留端口，硬宏版本未使用）----
    input  wire        clk0,
    input  wire        clk1,
    // ---- 两路 cmos 的 pixel_clk（pclk/2，始终在跑）----
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
    // ---- 两路 cmos 的复位（只跟各自 init_done，切换不复位）----
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
    // ① 无毛刺 pixel_clk mux：硬宏（内部 SEL 双域 2FF 同步 + 切换期钳低）
    //    sel 先在 soc 域打两拍（慢变控制信号），再交给硬宏
    //-------------------------------------------------------------------------
    reg sel_a, sel_s;
    always @(posedge soc_clk or negedge soc_rstn) begin
        if (!soc_rstn) begin sel_a <= 1'b0; sel_s <= 1'b0; end
        else           begin sel_a <= sel;  sel_s <= sel_a; end
    end

    GTP_CLKBUFGMUX #(
        .TRIGGER_MODE ("NEGEDGE"),
        .SIM_DEVICE   ("LOGOS2")
    ) u_camwr_mux (
        .CLKOUT ( pix_clk ),
        .CLKIN0 ( pix_clk0 ),
        .CLKIN1 ( pix_clk1 ),
        .SEL    ( sel_s    )
    );

    //-------------------------------------------------------------------------
    // ② soc 域：init_done 2FF / sel 边沿 / 切换窗口定时
    //-------------------------------------------------------------------------
    reg id0a, id0b, id1a, id1b;
    always @(posedge soc_clk) begin
        id0a <= init_done_0; id0b <= id0a;
        id1a <= init_done_1; id1b <= id1a;
    end
    assign ready = sel_s ? id1b : id0b;

    reg        sel_d = 1'b0;
    reg [31:0] sw_cnt = 32'd0;
    reg        sw_rst_r = 1'b0;
    always @(posedge soc_clk or negedge soc_rstn) begin
        if (!soc_rstn) begin
            sel_d <= 1'b0; sw_cnt <= 32'd0; sw_rst_r <= 1'b0;
        end else begin
            sel_d <= sel_s;
            if (sel_s != sel_d) begin
                sw_cnt <= SW_RST_CYC;
                sw_rst_r <= 1'b1;
            end else if (sw_cnt != 32'd0) begin
                sw_cnt <= sw_cnt - 32'd1;
                sw_rst_r <= 1'b1;
            end else begin
                sw_rst_r <= 1'b0;
            end
        end
    end

    // 两路 cmos 各自只跟自己的 SCCB 完成（**不**受切换影响，见承重规则①）
    assign rstn0 = id0b;
    assign rstn1 = id1b;

    //-------------------------------------------------------------------------
    // ③ pix 域：wr_ok —— ready 之后、再过第一个 frame_sof 才放行
    //-------------------------------------------------------------------------
    wire pix_rstn = ready & ~sw_rst_r;

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
    // ddr 域：切换后已写满多少个完整帧
    //-------------------------------------------------------------------------
    reg sd0, sd1;
    always @(posedge ddr_clk) begin sd0 <= sel_s; sd1 <= sd0; end

    reg [7:0] fcnt;
    always @(posedge ddr_clk or negedge ddr_rstn) begin
        if (!ddr_rstn)          fcnt <= 8'd0;
        else if (sd0 != sd1)    fcnt <= 8'd0;
        else if (frame_start && fcnt != 8'hFF) fcnt <= fcnt + 8'd1;
    end
    wire frames_ok = (fcnt >= FRAMES_NEED);

    //-------------------------------------------------------------------------
    // 黑屏 FSM（soc 域）+ 跨到 lcd
    //   置黑：sel 变化（立即）/ 复位
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
            if (sel_s != sel_d) begin
                black_r    <= 1'b1;
                settle_cnt <= SETTLE_CYC;
            end else if (black_r) begin
                if (settle_cnt != 32'd0)      settle_cnt <= settle_cnt - 32'd1;
                else if (ready && fo1)        black_r    <= 1'b0;
            end
        end
    end
    assign switch_busy = black_r | sw_rst_r;

    reg b0, b1;
    always @(posedge lcd_clk or negedge lcd_rstn) begin
        if (!lcd_rstn) begin b0 <= 1'b1; b1 <= 1'b1; end
        else begin b0 <= black_r; b1 <= b0; end
    end
    assign black = b1;

endmodule
