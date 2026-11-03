//=============================================================================
// video_passthrough: CAM0/CAM1 1280x720 RGB565 -> 帧存(DDR) -> 1024x600 LCD 直通
//
// 组装层，全部功能块来自厂家 cam2lcd_200mini（板级验收）复制件：
//   camera(camera.v) -> cmos_8_16bit 整流级 -> 写侧居中裁列(128..1151)
//     -> fram_buf(H_NUM=1024,V_NUM=720, 双 bank) -> 简化 AXI -> DDR
//     -> rd_buf(ROW_OFFSET=60) -> sync_vg(1024x600@51.923MHz) -> LCD 三拍寄存器
//
// 双目（cam_switch）：两路 camera 各带 SCCB，cam_switch 做无毛刺时钟 mux、
//   切换期掐写（wr_ok 同时门控 wr_en/wr_fsync）与输出级黑屏（black）。
//
// 与厂家 top 的差异（仅这三处，其余逐块复制，不"顺手优化"）：
//   1) 写侧裁列改为居中：列 128..1151（厂家是行首 0..1023）；
//   2) 显示窗口从第 ROW_OFFSET(=60) 行起读 600 行（rd_buf 新增参数）；
//   3) 本层不接 DDR IP/TMDS/HDMI/UART/LED，只暴露简化 AXI 给仲裁器（Task 5）。
//      厂家 fram_buf 无 ADDR_OFFSET 口（内部固定 0），帧存偏移在 AXI 边界统一
//      加 FB_ADDR_WORD（默认 0x0400_0000 字 = DDR 字节 0x1000_0000）。
//
// 叠加引擎（overlay.v，Task 3）：CPU 写 box 表 -> commit -> vsync 切 bank；
// 像素在 565->888 之前叠加 2 px 绿色边框（0x07E0），ovl_en=0 时纯旁路。
//=============================================================================
`timescale 1ns/1ps

module video_passthrough #(
    parameter SIM_BYPASS_CAMERA = 0,
    parameter [27:0] FB_ADDR_WORD = 28'h400_0000,
    parameter [27:0] GUI_BASE_WORD = 28'h480_0000,   // 0x9200_0000 的 32-bit 字地址
    parameter integer ROW_OFFSET  = 60
)(
    input  wire        sys_clk,
    input  wire        cam_rstn,
    input  wire        ddr_clk,
    input  wire        ddr_rstn,
    input  wire        lcd_clk,
    input  wire        lcd_rstn,
    input  wire        ddr_init_done,
    input  wire        camera_clk_0,
    input  wire [7:0]  camera_data_0,
    input  wire        camera_href_0,
    input  wire        camera_vsync_0,
    output wire        SCL_0,
    output wire        SDA_0,
    output wire        cam_rst_0,
    input  wire        camera_clk_1,
    input  wire [7:0]  camera_data_1,
    input  wire        camera_href_1,
    input  wire        camera_vsync_1,
    output wire        SCL_1,
    output wire        SDA_1,
    output wire        cam_rst_1,
    input  wire        vin_clk,
    input  wire        vin_de,
    input  wire        vin_vsync,
    input  wire [15:0] vin_pix,
    output wire [27:0] ddr_awaddr,
    output wire [3:0]  ddr_awlen,
    output wire        ddr_awvalid,
    input  wire        ddr_awready,
    output wire [255:0] ddr_wdata,
    output wire [31:0] ddr_wstrb,
    output wire        ddr_wvalid,
    input  wire        ddr_wready,
    input  wire        ddr_wusero_last,
    output wire [27:0] ddr_araddr,
    output wire [3:0]  ddr_arlen,
    output wire        ddr_arvalid,
    input  wire        ddr_arready,
    input  wire [255:0] ddr_rdata,
    input  wire [3:0]  ddr_rid,
    input  wire        ddr_rlast,
    input  wire        ddr_rvalid,
    output wire        ddr_rready,
    output wire        lcd_pclk,
    output wire        lcd_de,
    output wire        lcd_hs,
    output wire        lcd_vs,
    output wire        lcd_pwm,
    output wire [7:0]  lcd_r,
    output wire [7:0]  lcd_g,
    output wire [7:0]  lcd_b,
    output wire        frame_toggle,
    output wire        wr_bank,
    output wire        cam_init_done,
    input  wire        soc_clk,        // 100 MHz：切换控制域
    input  wire        soc_rstn,       // 低有效
    input  wire        cam_sel,        // 0=cam0
    output wire        cam_ready,      // 所选相机 init_done
    output wire        switch_busy,    // 切换/黑屏进行中
    input  wire        gui_src,        // LCD 读源：0=相机 bank，1=GUI 帧存（soc_clk 域）
    input  wire        gui_bank,       // GUI 帧存 bank：0=0x9200_0000 / 1=**0x9280_0000**（soc_clk 域）
    //   ⚠️ bank 偏移是 32-bit **字地址 bit21**（下方 ar_gui = GUI_BASE_WORD + {bank,21'd0}）
    //      ⇒ 2^21 字 = 8 MiB。写成 0x9220_0000（2 MiB）是错的（2026-11-01 板上实测确认）。
    output wire        frame_rd_toggle,// 读帧起点翻转（ddr_clk 域，每帧一次；给 GPU 做 vsync）
    input  wire        ovl_wr_clk,
    input  wire        ovl_wr_rstn,
    input  wire        ovl_wr_en,
    input  wire [4:0]  ovl_wr_addr,
    input  wire [31:0] ovl_wr_data,
    input  wire        ovl_commit,
    input  wire        ovl_en,
    input  wire [7:0]  ovl_count,
    output wire        ovl_active_bank
);
    localparam MEM_ROW_WIDTH    = 15;
    localparam MEM_COLUMN_WIDTH = 10;
    localparam MEM_BANK_WIDTH   = 3;
    localparam MEM_DQ_WIDTH     = 32;
    localparam CTRL_ADDR_WIDTH  = MEM_ROW_WIDTH + MEM_BANK_WIDTH + MEM_COLUMN_WIDTH;

    //-------------------------------------------------------------------------
    // 写侧前端：相机像素流（两种来源二选一）
    //   cam_pixel_clk : 写时钟（厂家 cmos_8_16bit 的 pclk/2）
    //   cam_de        : 逐拍有效的行包络（每行 1280 拍，含待裁掉的列）
    //   cam_data16    : RGB565
    //   cam_fsync     : 帧同步（上升沿 = 帧起点）
    //-------------------------------------------------------------------------
    wire        cam_pixel_clk;
    wire        cam_de;
    wire [15:0] cam_data16;
    wire        cam_fsync;

    //-------------------------------------------------------------------------
    // 写侧列裁切：相机列 128..1151 -> 存 1024 列（居中；全 720 行）
    //   注：行宽仍是 1024，帧存步长(H_NUM)两侧一致，故垂直裁切无需改账本。
    //-------------------------------------------------------------------------
    reg [11:0] col_cnt;
    always @(posedge cam_pixel_clk or negedge cam_rstn) begin
        if (!cam_rstn)          col_cnt <= 12'd0;
        else if (!cam_de)       col_cnt <= 12'd0;
        else if (col_cnt < 12'd1280) col_cnt <= col_cnt + 12'd1;
    end
    wire cam_de_crop = cam_de && (col_cnt >= 12'd128) && (col_cnt < 12'd1152);

    //-------------------------------------------------------------------------
    // 双目共享线（两个 generate 分支各驱动一份，保证旁路档也不悬空）
    //   注：cam_pixel_clk_i / cam_de16 / cam_data16_i / frame_sof 已在 g_camera
    //       内声明，这里**不得**重复声明（同作用域重名会编译失败）。
    //-------------------------------------------------------------------------
    wire        cam_wr_ok;      // pix 域：1 = 允许写
    wire        cam_black;      // lcd 域：1 = 黑屏
    wire        cam_sw_busy;    // soc 域
    wire        cam_rdy_w;      // soc 域
    wire        cam_rstn_0;     // cam0 的 cmos 复位（= init_done_0，切换不复位）
    wire        cam_rstn_1;     // cam1 的 cmos 复位（= init_done_1）
    // ★ 2026-10-30：取消 `cam_en_0/1`。两路相机模块**常开**（只有各自 SCCB 的
    //   init_done 能复位），理由见 cam_switch.v 头注释：硬宏换源要求两路 pixel_clk
    //   始终在跑；而相机侧任何"未选中就复位"都会连带停掉那一路的 pixel_clk。

    //-------------------------------------------------------------------------
    // 帧状态（ddr_clk 域）：与 wr_buf 内部 rd_frame_cnt 同源同深度
    //   （wr_fsync -> ddr_clk 3FF 上升沿），每帧一次
    //   注：cam_switch 要读 frame_start_ddr，故本段必须在 generate 之前
    //       （否则前向引用会成为隐式悬空 wire）。逻辑原样，仅上移。
    //-------------------------------------------------------------------------
    // ★ 必须与真正送进 fram_buf 的 `wr_fsync = cam_fsync & cam_wr_ok` **同口径**：
    //   否则"上电后第一次 fsync 落在 wr_ok 还是 0 的那一拍"会让本计数比真实写 bank
    //   多翻一次 ⇒ STATUS[1] 与 wr_buf 内部 bank 永久错开 1 ⇒ 软件/y1cam 取到"正在写"
    //   的那个 bank（大片未写、看起来像黑屏）。2026-10-28 实测踩过。
    wire cam_fsync_w = cam_fsync & cam_wr_ok;
    reg cam_fs_d1, cam_fs_d2, cam_fs_d3;
    always @(posedge ddr_clk) begin
        cam_fs_d1 <= cam_fsync_w;
        cam_fs_d2 <= cam_fs_d1;
        cam_fs_d3 <= cam_fs_d2;
    end
    wire frame_start_ddr = ~cam_fs_d3 & cam_fs_d2;

    reg [7:0] frame_cnt;
    reg       frame_tog;
    always @(posedge ddr_clk) begin
        if (!ddr_rstn) begin
            frame_cnt <= 8'd0;
            frame_tog <= 1'b0;
        end else if (frame_start_ddr) begin
            frame_cnt <= frame_cnt + 8'd1;
            frame_tog <= ~frame_tog;
        end
    end
    assign frame_toggle = frame_tog;
    assign wr_bank      = frame_cnt[0];

generate
if (SIM_BYPASS_CAMERA) begin : g_bypass
    // 仿真旁路：vin_* 直接进写侧（不带相机/SCCB/cmos 整流级）
    assign cam_pixel_clk = vin_clk;
    assign cam_de        = vin_de;
    assign cam_data16    = vin_pix;
    assign cam_fsync     = vin_vsync;
    assign cam_init_done = cam_rstn;
    assign SCL_0         = 1'b1;
    assign SDA_0         = 1'b1;
    assign cam_rst_0     = 1'b1;

    // 双目前端全部旁路：新线也必须驱动，否则仿真档悬空（行为不定）
    assign cam_rstn_0     = cam_rstn;
    assign cam_rstn_1     = cam_rstn;
    assign cam_wr_ok      = 1'b1;
    assign cam_black      = 1'b0;
    assign cam_sw_busy    = 1'b0;
    assign cam_rdy_w      = cam_rstn;
    assign SCL_1          = 1'b1;
    assign SDA_1          = 1'b1;
    assign cam_rst_1      = 1'b1;
end else begin : g_camera
    wire        cam_init_done_1;
    wire        cam_vsync_n_1;
    wire        cam_init_done_0;
    wire        cam_vsync_n;      // camera.v 归一化后的 vsync（数据路径不用）

    // cam_switch 实例会先引用这些线，声明统一提前（避免被当成隐式 1-bit net）
    wire        cam_pixel_clk_i;   // pclk/2（cmos_8_16bit 在首个 vs 上升后启动）
    wire        cam_de16;
    wire [15:0] cam_data16_i;
    wire        frame_sof;         // 裁列后包络的帧起脉冲（pix_clk 域）

    //---------------------------------------------------------------
    // camera: 厂家引擎（PWDN/RESET 延时 + 248 条 720p SCCB 配置表）
    //---------------------------------------------------------------
    camera camera_inst0(
        /*input   wire            */.clk           ( sys_clk             )  ,
        /*input   wire            */.rst_n         ( cam_rstn            )  ,   // ★ 常开：只跟 SCCB init_done
        /*output  wire            */.SCL           ( SCL_0               )  ,
        /*output  wire            */.SDA           ( SDA_0               )  ,
        /*input   wire            */.camera_clk    ( camera_clk_0        )  ,
        /*input   wire    [7:0]   */.camera_data   ( camera_data_0       )  ,
        /*input   wire            */.camera_herf   ( camera_href_0       )  ,
        /*input   wire            */.camera_vsync  ( camera_vsync_0      )  ,
        /*input   wire            */.ddr_init      ( ddr_init_done       )  ,
        /*output  wire            */.camera_rstn   ( cam_rst_0           )  ,
        /*output  wire            */.camera_pwnd   ()                    ,
        /*output  wire            */.init_done     ( cam_init_done_0     )  ,
        /*output  wire    [15:0]  */.wf_wr_data    ()                    ,
        /*output  wire            */.wf_wr_en      ()                    ,
        /*output  wire            */.vs            ( cam_vsync_n         )  ,
        /*output  wire            */.hs            ()                    ,
        /*output  wire            */.sop           ()                    ,
        /*output  wire            */.eop           ()
    );

    //---------------------------------------------------------------
    // camera 1（第二路）：照 camera_inst0 逐行复制，换 _1 后缀
    //---------------------------------------------------------------
    camera camera_inst1(
        /*input   wire            */.clk           ( sys_clk             )  ,
        /*input   wire            */.rst_n         ( cam_rstn            )  ,   // ★ 常开

        /*output  wire            */.SCL           ( SCL_1               )  ,
        /*output  wire            */.SDA           ( SDA_1               )  ,
        /*input   wire            */.camera_clk    ( camera_clk_1        )  ,
        /*input   wire    [7:0]   */.camera_data   ( camera_data_1       )  ,
        /*input   wire            */.camera_herf   ( camera_href_1       )  ,
        /*input   wire            */.camera_vsync  ( camera_vsync_1      )  ,
        /*input   wire            */.ddr_init      ( ddr_init_done       )  ,
        /*output  wire            */.camera_rstn   ( cam_rst_1           )  ,
        /*output  wire            */.camera_pwnd   ()                    ,
        /*output  wire            */.init_done     ( cam_init_done_1     )  ,
        /*output  wire    [15:0]  */.wf_wr_data    ()                    ,
        /*output  wire            */.wf_wr_en      ()                    ,
        /*output  wire            */.vs            ( cam_vsync_n_1       )  ,
        /*output  wire            */.hs            ()                    ,
        /*output  wire            */.sop           ()                    ,
        /*output  wire            */.eop           ()
    );

    //---------------------------------------------------------------
    // 两路采集前端：**各自独立、引脚直连**（机制与证据见下面 2026-10-30 的定案段）
    //   ★ 2026-10-27 结构修订：第一版把"数据 mux + 门控时钟 mux"插在 `cmos_8_16bit` 前面，
    //   85k LUT 的整板工程里布线延迟把字节配对顶错（形状对、颜色错、满屏噪点）
    //   ⇒ mux 一律挪到拼字级**之后**。
    //---------------------------------------------------------------
    // ★★ 2026-10-30 定案（上板对照实验）：`cmos_8_16bit` 的 `pdata_i/de_i/vs_i`
    //    **必须直连引脚**，中间**不许**插任何寄存器/组合门。
    //    证据链（同一块板、同一颗传感器、同一场景，隔夜可重复）：
    //      · `ff5c236` = `pdata_i` 直连引脚 + PCLK 过 GTP_CLKBUFG ⇒ **画面干净**
    //        （这一版就是台账里的 "Cam 正常版" 比特流 `5df46d6b`，10-30 复烧确认干净）；
    //      · `6626771` 为"每路一套 cmos"在 `pdata_i` 前加了 `cam_d_d0`（pclk 负边沿寄存级）
    //        ⇒ 花屏（色偏 + 满屏杂色，单比特脉冲 3.5%）；
    //      · `3f699ed` 把 GTP_CLKBUFG 加回来**但没拆那一级** ⇒ 仍然花屏（同样 3.52%）。
    //    ⇒ 机制（以厂家 `cmos_8_16bit.v` 源码为准，**它没有 IDDR**）：
    //      模块在 pclk **正沿**执行 `pdata_i_reg <= pdata_i`，再 `{pdata_i_reg, pdata_i}`
    //      两拍拼成一个 RGB565 字。若 `pdata_i` 前面插一级**负沿**寄存器，正沿看到的
    //      永远是"上一次负沿采到的那个字节" ⇒ 整个数据流**晚一个字节**，拼字就变成
    //      {byte[n], byte[n-1]} 而不是 {byte[n+1], byte[n]} ⇒ **只毁颜色不毁形状**
    //      （亮度由两字节的高位共同决定，仍基本对；色度全错）。
    //    ⚠️ 别再"为了时序干净"往这里加寄存器；要动就必须先重跑这条 A/B。
    wire        pix_clk_0, pix_clk_1;
    wire        de16_0, de16_1;
    wire [15:0] dat16_0, dat16_1;
    wire        cam_clk0_buf, cam_clk1_buf;

    // ★ 2026-10-29：两路 PCLK 都**显式过全局时钟缓冲**再喂整流级。
    //   理由：负沿/正沿的采样点都锚在这条钟上，钟若走局部布线则各 FF 的插入延迟不一致。
    //   `ff5c236` 用这一条把"只毁颜色不毁形状"治好过（= `camgood`），值得保留；
    //   但**它不是这次花屏的真因**（真因是拼字级前那一级寄存器，见上面定案段）。
    GTP_CLKBUFG u_cambuf0 (.CLKIN(camera_clk_0), .CLKOUT(cam_clk0_buf));
    GTP_CLKBUFG u_cambuf1 (.CLKIN(camera_clk_1), .CLKOUT(cam_clk1_buf));

    cmos_8_16bit u_cmos16_0 (
        .pclk      ( cam_clk0_buf ),     // 经全局时钟缓冲（不再是裸引脚）
        .rst_n     ( cam_rstn_0   ),
        .pdata_i   ( camera_data_0 ),    // ★ 直连引脚（见上面的 A/B 定案）
        .de_i      ( camera_href_0 ),
        .vs_i      ( camera_vsync_0),
        .pixel_clk ( pix_clk_0    ),
        .de_o      ( de16_0       ),
        .pdata_o   ( dat16_0      )
    );

    cmos_8_16bit u_cmos16_1 (
        .pclk      ( cam_clk1_buf ),
        .rst_n     ( cam_rstn_1   ),
        .pdata_i   ( camera_data_1 ),    // ★ 直连引脚
        .de_i      ( camera_href_1 ),
        .vs_i      ( camera_vsync_1),
        .pixel_clk ( pix_clk_1    ),
        .de_o      ( de16_1       ),
        .pdata_o   ( dat16_1      )
    );

    //---------------------------------------------------------------
    // 双目切换控制（cam_switch）：sel 门控 / pixel_clk 无毛刺 mux / 掐写（wr_ok）/
    //   事件驱动黑屏。**不做数据 mux、不做时钟门控进两套 cmos**；两路 cmos 常开，只由
    //   各自 SCCB 的 init_done 复位（切换过程不复位，pixel_clk 才不会停）。
    //---------------------------------------------------------------
    cam_switch #(
        .SW_RST_CYC  (100000),
        .SETTLE_CYC  (40000000),
        .FRAMES_NEED (2)
    ) u_camsw (
        .clk0(camera_clk_0), .clk1(camera_clk_1),
        .pix_clk0(pix_clk_0), .pix_clk1(pix_clk_1),
        .init_done_0(cam_init_done_0), .init_done_1(cam_init_done_1),
        .soc_clk(soc_clk), .soc_rstn(soc_rstn), .sel(cam_sel),
        .ready(cam_rdy_w), .switch_busy(cam_sw_busy),
        .rstn0(cam_rstn_0), .rstn1(cam_rstn_1),
        .pix_clk(cam_pixel_clk_i),
        .frame_sof(frame_sof), .wr_ok(cam_wr_ok),
        .ddr_clk(ddr_clk), .ddr_rstn(ddr_rstn), .frame_start(frame_start_ddr),
        .lcd_clk(lcd_clk), .lcd_rstn(lcd_rstn), .black(cam_black)
    );

    //---------------------------------------------------------------
    // 数据/href/vs 的 mux：位于**两套拼字级之后**，纯数据路径
    //   （sel 只在黑屏/掐写窗口内变化 ⇒ 切换瞬态的错位不会显示）
    //---------------------------------------------------------------
    assign cam_de16     = cam_sel ? de16_1   : de16_0;
    assign cam_data16_i = cam_sel ? dat16_1  : dat16_0;

    //---------------------------------------------------------------
    // 帧同步：取"有效-消隐间隙"的一次性 sof（厂家根因修复，别改成数行）
    //   相机垂直消隐 ~26ms 远大于行间隙；包络持续 BLANK_TH 拍低电平即判帧尾，
    //   相位自对齐，且不会与第 720 行的 drain 抢跑。
    //---------------------------------------------------------------
    localparam [16:0] BLANK_TH = 17'd60000;  // ~1.16ms @51.9MHz pixel_clk
    reg [16:0] blank_cnt = 17'd0;
    reg        sof1 = 1'b0;
    always @(posedge cam_pixel_clk_i or negedge cam_rstn) begin
        if (!cam_rstn) begin
            blank_cnt <= 17'd0;
            sof1      <= 1'b0;
        end else if (cam_de_crop) begin
            blank_cnt <= 17'd0;
            sof1      <= 1'b0;
        end else if (blank_cnt <= BLANK_TH) begin
            blank_cnt <= blank_cnt + 17'd1;
            sof1      <= (blank_cnt == BLANK_TH);
        end else begin
            sof1      <= 1'b0;
        end
    end

    reg        de_d = 1'b0;
    reg [4:0]  sof_sh = 5'd0;      // 展宽 5 拍，供 ddr_clk 3FF 采样
    always @(posedge cam_pixel_clk_i or negedge cam_rstn) begin
        if (!cam_rstn) begin
            de_d   <= 1'b0;
            sof_sh <= 5'd0;
        end else begin
            de_d   <= cam_de_crop;
            sof_sh <= {sof_sh[3:0], sof1};
        end
    end
    assign frame_sof = |sof_sh;

    assign cam_pixel_clk = cam_pixel_clk_i;
    assign cam_de        = cam_de16;
    assign cam_data16    = cam_data16_i;
    assign cam_fsync     = frame_sof;
    assign cam_init_done = cam_init_done_0;
end
endgenerate

    //-------------------------------------------------------------------------
    // sync_vg: 1024x600 时序 @ lcd_clk（面板验收过的数字）
    //-------------------------------------------------------------------------
    wire vs_reg, hs_reg, de_reg;
    sync_vg #(
        .X_BITS ( 4'd12 ),
        .Y_BITS ( 4'd12 ),
        .V_TOTAL( 12'd635 ),
        .V_FP   ( 12'd12  ),
        .V_BP   ( 12'd20  ),
        .V_SYNC ( 12'd3   ),
        .V_ACT  ( 12'd600 ),
        .H_TOTAL( 12'd1344),
        .H_FP   ( 12'd160 ),
        .H_BP   ( 12'd140 ),
        .H_SYNC ( 12'd20  ),
        .H_ACT  ( 12'd1024)
    ) u_vg (
        .clk    ( lcd_clk ),
        .rstn   ( lcd_rstn ),
        .vs_out ( vs_reg  ),
        .hs_out ( hs_reg  ),
        .de_out ( de_reg  ),
        .de_re  (         ),
        .x_act  (         ),
        .y_act  (         )
    );

    //-------------------------------------------------------------------------
    // fram_buf: 厂家教程族（行结构寻址 + 双 bank + 首帧门控）
    //   vin  : cam_pixel_clk 域（裁列后的 1024x720 流）
    //   vout : lcd_clk 域
    //   ddr  : ddr_clk 域（简化 AXI 直出）
    //-------------------------------------------------------------------------
    wire [CTRL_ADDR_WIDTH-1:0] axi_awaddr;
    wire [3:0]                 axi_awid;
    wire [3:0]                 axi_awlen;
    wire [2:0]                 axi_awsize;
    wire [1:0]                 axi_awburst;
    wire                       axi_awvalid;
    wire [MEM_DQ_WIDTH*8-1:0]  axi_wdata;
    wire [MEM_DQ_WIDTH-1:0]    axi_wstrb;
    wire                       axi_wvalid;
    wire [CTRL_ADDR_WIDTH-1:0] axi_araddr;
    wire [3:0]                 axi_arid;
    wire [3:0]                 axi_arlen;
    wire [2:0]                 axi_arsize;
    wire [1:0]                 axi_arburst;
    wire                       axi_arvalid;
    wire                       axi_rready;

    wire vs_out_r, hs_out_r, de_o;
    wire [15:0] rgb565;
    wire        fb_init_done;

    fram_buf #(
        .MEM_ROW_WIDTH    ( MEM_ROW_WIDTH    ),
        .MEM_COLUMN_WIDTH ( MEM_COLUMN_WIDTH ),
        .MEM_BANK_WIDTH   ( MEM_BANK_WIDTH   ),
        .MEM_DQ_WIDTH     ( MEM_DQ_WIDTH     ),
        .H_NUM            ( 12'd1024         ),
        .V_NUM            ( 12'd720          ),
        .PIX_WIDTH        ( 16               ),
        .ROW_OFFSET       ( ROW_OFFSET       )
    ) u_fram (
        .ddr_clk       ( ddr_clk        ),
        .ddr_rstn      ( ddr_rstn       ),
        .vin_clk       ( cam_pixel_clk  ),
        .wr_fsync      ( cam_fsync   & cam_wr_ok ),
        .wr_en         ( cam_de_crop & cam_wr_ok ),
        .wr_data       ( cam_data16     ),
        .vout_clk      ( lcd_clk        ),
        .rd_fsync      ( vs_reg         ),
        .rd_en         ( de_reg         ),
        .vout_de       ( de_o           ),
        .vout_data     ( rgb565         ),
        .init_done     ( fb_init_done   ),
        .axi_awaddr    ( axi_awaddr     ),
        .axi_awid      ( axi_awid       ),
        .axi_awlen     ( axi_awlen      ),
        .axi_awsize    ( axi_awsize     ),
        .axi_awburst   ( axi_awburst    ),
        .axi_awready   ( ddr_awready    ),
        .axi_awvalid   ( axi_awvalid    ),
        .axi_wdata     ( axi_wdata      ),
        .axi_wstrb     ( axi_wstrb      ),
        .axi_wlast     ( ddr_wusero_last),
        .axi_wvalid    ( axi_wvalid     ),
        .axi_wready    ( ddr_wready     ),
        .axi_bid       ( 4'd0           ),
        .axi_araddr    ( axi_araddr     ),
        .axi_arid      ( axi_arid       ),
        .axi_arlen     ( axi_arlen      ),
        .axi_arsize    ( axi_arsize     ),
        .axi_arburst   ( axi_arburst    ),
        .axi_arvalid   ( axi_arvalid    ),
        .axi_arready   ( ddr_arready    ),
        .axi_rready    ( axi_rready     ),
        .axi_rdata     ( ddr_rdata      ),
        .axi_rvalid    ( ddr_rvalid     ),
        .axi_rlast     ( ddr_rlast      ),
        .axi_rid       ( ddr_rid        )
    );

    //-------------------------------------------------------------------------
    // LCD 读源选择（GUI 第二帧存）：gui_src=1 时读 GUI_BASE_WORD 区
    //
    //   ★ 换源只在**读帧首**生效，且必须与 rd_buf 内部的复位同拍：
    //     rd_buf 用 ddr_clk 对 rd_fsync(=vs_reg) 打三拍，取 `~d3 & d2` 作为 wr_rst
    //     把 wr_cnt 复位到 ROW_OFFSET 起点。这里在**同一个源、同一个钟**上复刻同一条
    //     三拍链，于是"选择位切换"与"行指针复位"落在同一拍 —— 一帧之内地址绝不会
    //     前半帧读相机 bank、后半帧读 GUI（那会显示成上下两幅图撕裂）。
    //     厂家 RTL 零改动，mux 全部做在本组装层。
    //
    //   地址口径：相机侧 axi_araddr = {bank, wr_cnt}，bank 在 bit22（fram_buf 的
    //   LINE_ADDR_WIDTH=22）⇒ 低 22 位是 bank 内 32-bit 字偏移，直接搬到 GUI 基址上。
    //-------------------------------------------------------------------------
    reg        gui_s1, gui_s2;              // soc_clk -> ddr_clk 2FF
    reg        gbk_s1, gbk_s2;              // 同上：gui_bank
    reg        gui_fs1, gui_fs2, gui_fs3;   // vs_reg -> ddr_clk 3FF（与 rd_buf 同构）
    reg        gui_sel_ddr, gui_bank_ddr;

    always @(posedge ddr_clk) begin
        gui_s1  <= gui_src;
        gui_s2  <= gui_s1;
        gbk_s1  <= gui_bank;
        gbk_s2  <= gbk_s1;
        gui_fs1 <= vs_reg;
        gui_fs2 <= gui_fs1;
        gui_fs3 <= gui_fs2;
    end
    wire rd_frame_rst = ~gui_fs3 & gui_fs2;   // = rd_buf 内部 wr_rst

    always @(posedge ddr_clk) begin
        if (!ddr_rstn) begin
            gui_sel_ddr  <= 1'b0;
            gui_bank_ddr <= 1'b0;
        end else if (rd_frame_rst) gui_sel_ddr <= gui_s2;
        // 与读源同一拍锁存 ⇒ 帧内 bank 不变（单行形态保留：U8 负对照的突变锚点）
        if (ddr_rstn && rd_frame_rst) gui_bank_ddr <= gbk_s2;
    end

    // 读帧起点翻转（ddr_clk 域）：GPU 侧 2FF + 边沿检测得到 vsync 脉冲。
    // 用"翻转"而不是单拍脉冲跨域 —— 单拍 8 ns 脉冲在 100 MHz 域会被 2FF 漏采。
    reg rd_tog;
    always @(posedge ddr_clk) begin
        if (!ddr_rstn)     rd_tog <= 1'b0;
        else if (rd_frame_rst) rd_tog <= ~rd_tog;
    end
    assign frame_rd_toggle = rd_tog;

    // LCD 域一份（只用于 cam_black 掩码：GUI 画面不该被相机切换的黑屏窗吃掉）
    reg        gui_l1, gui_l2, vs_d1;
    reg        gui_sel_lcd;
    always @(posedge lcd_clk or negedge lcd_rstn) begin
        if (!lcd_rstn) begin
            gui_l1 <= 1'b0; gui_l2 <= 1'b0; vs_d1 <= 1'b0; gui_sel_lcd <= 1'b0;
        end else begin
            gui_l1 <= gui_src;
            gui_l2 <= gui_l1;
            vs_d1  <= vs_reg;
            if (vs_reg && !vs_d1) gui_sel_lcd <= gui_l2;
        end
    end
    wire lcd_black = cam_black & ~gui_sel_lcd;

    //-------------------------------------------------------------------------
    // 显示坐标（lcd_clk 域）：与 de_o/rgb565 同拍；帧首（vs_reg 高）清零
    //   1024x600，x 0..1023 / y 0..599，供 overlay 做屏幕坐标比较
    //-------------------------------------------------------------------------
    reg [10:0] ovl_x;
    reg [9:0]  ovl_y;
    always @(posedge lcd_clk or negedge lcd_rstn) begin
        if (!lcd_rstn) begin
            ovl_x <= 11'd0;
            ovl_y <= 10'd0;
        end else if (vs_reg) begin
            ovl_x <= 11'd0;
            ovl_y <= 10'd0;
        end else if (de_o) begin
            if (ovl_x == 11'd1023) begin
                ovl_x <= 11'd0;
                ovl_y <= ovl_y + 10'd1;
            end else begin
                ovl_x <= ovl_x + 11'd1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // 简化 AXI 出层：帧存统一加 DDR 字地址偏移（fram_buf 内部固定 0）
    //   读地址按 gui_sel_ddr 二选一（写地址恒为相机 bank）
    //-------------------------------------------------------------------------
    wire [27:0] ar_cam = axi_araddr + FB_ADDR_WORD;
    // bank 偏移 = 2 MiB = 32-bit 字地址的 bit21 ⇒ {gui_bank_ddr, 21'd0}
    wire [27:0] ar_gui = GUI_BASE_WORD + {gui_bank_ddr, 21'd0} + {6'd0, axi_araddr[21:0]};

    assign ddr_awaddr  = axi_awaddr + FB_ADDR_WORD;
    assign ddr_awlen   = axi_awlen;
    assign ddr_awvalid = axi_awvalid;
    assign ddr_wdata   = axi_wdata;
    assign ddr_wstrb   = axi_wstrb;
    assign ddr_wvalid  = axi_wvalid;
    assign ddr_araddr  = gui_sel_ddr ? ar_gui : ar_cam;
    assign ddr_arlen   = axi_arlen;
    assign ddr_arvalid = axi_arvalid;
    assign ddr_rready  = axi_rready;

    //-------------------------------------------------------------------------
    // 帧状态（ddr_clk 域）已上移到 generate 之前（cam_switch 需要
    // frame_start_ddr），见文件前部"双目共享线"一节。
    //-------------------------------------------------------------------------

    // 叠加引擎：写口在 soc_clk 域（video_regs，Task 4），显示在 lcd_clk 域
    wire [15:0] pix_ovl;

    overlay u_overlay (
        .lcd_clk    ( lcd_clk        ),
        .lcd_rstn   ( lcd_rstn       ),
        .pix_x      ( ovl_x          ),
        .pix_y      ( ovl_y          ),
        .pix_de     ( de_o           ),
        .pix_in     ( rgb565         ),
        .pix_out    ( pix_ovl        ),
        .vsync      ( vs_reg         ),
        .hs         ( hs_reg         ),
        .wr_clk     ( ovl_wr_clk     ),
        .wr_rstn    ( ovl_wr_rstn    ),
        .wr_en      ( ovl_wr_en      ),
        .wr_addr    ( ovl_wr_addr    ),
        .wr_data    ( ovl_wr_data    ),
        .commit     ( ovl_commit     ),
        .ovl_en     ( ovl_en         ),
        .ovl_count  ( ovl_count      ),
        .active_bank( ovl_active_bank)
    );

    //-------------------------------------------------------------------------
    // LCD 输出级（厂家原样）：时序+数据一起在 lcd_clk 打一拍，面板在
    // lcd_pclk 上升沿（= lcd_clk 下降沿）采样，留半周期余量；HS/VS 低有效。
    //   数据源 pix_ovl 已含 overlay 叠加（RGB565）
    //-------------------------------------------------------------------------
    reg        vs_r, hs_r, de_r;
    reg [7:0]  r_r, g_r, b_r;
    always @(posedge lcd_clk or negedge lcd_rstn) begin
        if (!lcd_rstn) begin
            vs_r <= 1'b0; hs_r <= 1'b0; de_r <= 1'b0;
            r_r <= 8'd0; g_r <= 8'd0; b_r <= 8'd0;
        end else begin
            vs_r <= vs_reg;
            hs_r <= hs_reg;
            de_r <= de_o & ~lcd_black;
            r_r  <= lcd_black ? 8'd0 : {pix_ovl[15:11], 3'd0};
            g_r  <= lcd_black ? 8'd0 : {pix_ovl[10:5],  2'd0};
            b_r  <= lcd_black ? 8'd0 : {pix_ovl[4:0],   3'd0};
        end
    end

    assign lcd_pclk = ~lcd_clk;
    assign lcd_vs   = ~vs_r;
    assign lcd_hs   = ~hs_r;
    assign lcd_de   = de_r;
    assign lcd_pwm  = 1'b1;
    assign lcd_r    = r_r;
    assign lcd_g    = g_r;
    assign lcd_b    = b_r;

    // 双目切换状态出层（soc 域）：给 video_regs 的 CAM_CTRL 只读位
    assign cam_ready   = cam_rdy_w;
    assign switch_busy = cam_sw_busy;

endmodule
