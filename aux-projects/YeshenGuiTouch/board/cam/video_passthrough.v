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
// 与厂家 top 的差异（其余逐块复制，不"顺手优化"）：
//   1) 写侧裁列改为居中：列 128..1151（厂家是行首 0..1023）；
//   2) 显示窗口从第 ROW_OFFSET(=60) 行起读 600 行（rd_buf 新增参数）；
//   3) 本层不接 DDR IP/TMDS/HDMI/UART/LED，只暴露简化 AXI 给仲裁器（Task 5）。
//      厂家 fram_buf 无 ADDR_OFFSET 口（内部固定 0），帧存偏移在 AXI 边界统一
//      加 FB_ADDR_WORD（默认 0x0400_0000 字 = DDR 字节 0x1000_0000）。
//   4) Phase R：GUI 模式（GUI_CTRL[0]）经 2FF 进 cam 像素域，掐掉相机写
//      （wr_fsync/wr_en）并把读 bank 切到 GUI_CTRL[1]（fram_buf/rd_buf）。
//      GUI 模式下同时屏蔽 cam_switch 的切换黑屏（black 经 2FF 进 lcd 域后
//      AND ~gui_mode）：冻结后 frame_start 被掐，black 可能永远不清，GUI
//      即使读对 bank 也会被刷黑。相机模式的黑屏行为逐拍不变。
//
// 叠加引擎（overlay.v，Task 3）：CPU 写 box 表 -> commit -> vsync 切 bank；
// 像素在 565->888 之前叠加 2 px 绿色边框（0x07E0），ovl_en=0 时纯旁路。
//=============================================================================
`timescale 1ns/1ps

module video_passthrough #(
    parameter SIM_BYPASS_CAMERA = 0,
    parameter [27:0] FB_ADDR_WORD = 28'h400_0000,
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
    input  wire        gui_mode,       // GUI_CTRL[0]（soc_clk）：1 = 冻结相机写、LCD 读 GUI bank
    input  wire        gui_bank,       // GUI_CTRL[1]（soc_clk）：GUI 模式读 bank
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
    // GUI 冻结：soc_clk -> cam 像素/写域 2FF（gui_mode 是慢变电平，2FF 足够）
    //   freeze 只在写侧用：wr_fsync/wr_en 都被它掐掉，相机不再推进帧存 bank；
    //   帧计数（cam_fsync_w/frame_toggle）用同一口径，STATUS 帧号也随之停住。
    //-------------------------------------------------------------------------
    reg gui_mode_p1, gui_mode_p2;
    always @(posedge cam_pixel_clk or negedge cam_rstn) begin
        if (!cam_rstn) begin
            gui_mode_p1 <= 1'b0;
            gui_mode_p2 <= 1'b0;
        end else begin
            gui_mode_p1 <= gui_mode;
            gui_mode_p2 <= gui_mode_p1;
        end
    end
    wire cam_gui_freeze = gui_mode_p2;

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

    // 送进 fram_buf 的写使能（与相机切换 wr_ok 串联；GUI 模式下恒 0）
    wire cam_wr_fsync = cam_fsync & cam_wr_ok & ~cam_gui_freeze;
    wire cam_wr_en    = cam_de_crop & cam_wr_ok & ~cam_gui_freeze;

    //-------------------------------------------------------------------------
    // 帧状态（ddr_clk 域）：与 wr_buf 内部 rd_frame_cnt 同源同深度
    //   （wr_fsync -> ddr_clk 3FF 上升沿），每帧一次
    //   注：cam_switch 要读 frame_start_ddr，故本段必须在 generate 之前
    //       （否则前向引用会成为隐式悬空 wire）。逻辑原样，仅上移。
    //-------------------------------------------------------------------------
    // ★ 必须与真正送进 fram_buf 的 `wr_fsync`（= cam_wr_fsync）**同口径**：
    //   否则"上电后第一次 fsync 落在 wr_ok 还是 0 的那一拍"会让本计数比真实写 bank
    //   多翻一次 ⇒ STATUS[1] 与 wr_buf 内部 bank 永久错开 1 ⇒ 软件/y1cam 取到"正在写"
    //   的那个 bank（大片未写、看起来像黑屏）。2026-10-28 实测踩过。
    //   GUI 冻结（cam_gui_freeze）也必须同口径：冻结期间 STATUS 帧号/写 bank 一起停住，
    //   解除冻结后两者仍与 wr_buf 内部计数逐帧对齐。
    wire cam_fsync_w = cam_wr_fsync;
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

    //-------------------------------------------------------------------------
    // GUI 模式 / 读 bank：soc_clk -> ddr_clk 2FF
    //   两 bit 走同一组 2FF（同一拍写入的位保持成组；rd_buf 在 LCD 帧首锁存）
    //-------------------------------------------------------------------------
    reg gui_mode_d1, gui_mode_d2;
    reg gui_bank_d1, gui_bank_d2;
    always @(posedge ddr_clk or negedge ddr_rstn) begin
        if (!ddr_rstn) begin
            gui_mode_d1 <= 1'b0; gui_mode_d2 <= 1'b0;
            gui_bank_d1 <= 1'b0; gui_bank_d2 <= 1'b0;
        end else begin
            gui_mode_d1 <= gui_mode; gui_mode_d2 <= gui_mode_d1;
            gui_bank_d1 <= gui_bank; gui_bank_d2 <= gui_bank_d1;
        end
    end

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
        /*input   wire            */.rst_n         ( cam_rstn            )  ,
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
        /*input   wire            */.rst_n         ( 1'b0                )  ,   // ★ 诊断：CAM1 整颗保持复位（单变量二分）

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
    // 两路采集前端：**各自裸 PCLK + 各自负边沿采样**（CAM0 与改动前逐字同构）
    //   ★ 2026-10-27 结构修订（上板实测驱动）：`cmos_8_16bit` 内部用 GTP_IDDR_E1
    //   在 pclk 的两沿各取一字节合成 RGB565 ⇒ 采样点必须紧贴引脚。第一版把
    //   "数据 mux + 门控时钟 mux" 插在它前面，85k LUT 的整板工程里布线延迟把字节配对
    //   顶错（形状对、颜色错、满屏噪点）。⇒ mux 一律挪到 IDDR **之后**。
    //---------------------------------------------------------------
    reg [7:0] cam_d_d0; reg cam_href_d0, cam_vsync_d0;
    always @(negedge camera_clk_0 or negedge cam_rstn) begin
        if (!cam_rstn) begin
            cam_d_d0 <= 8'd0; cam_href_d0 <= 1'b0; cam_vsync_d0 <= 1'b0;
        end else begin
            cam_d_d0 <= camera_data_0; cam_href_d0 <= camera_href_0; cam_vsync_d0 <= camera_vsync_0;
        end
    end

    reg [7:0] cam_d_d1; reg cam_href_d1, cam_vsync_d1;
    always @(negedge camera_clk_1 or negedge cam_rstn) begin
        if (!cam_rstn) begin
            cam_d_d1 <= 8'd0; cam_href_d1 <= 1'b0; cam_vsync_d1 <= 1'b0;
        end else begin
            cam_d_d1 <= camera_data_1; cam_href_d1 <= camera_href_1; cam_vsync_d1 <= camera_vsync_1;
        end
    end

    wire        pix_clk_0, pix_clk_1;
    wire        de16_0, de16_1;
    wire [15:0] dat16_0, dat16_1;

    cmos_8_16bit u_cmos16_0 (
        .pclk      ( camera_clk_0 ),     // 裸引脚直达 IDDR（改动前的形态）
        .rst_n     ( cam_rstn_0   ),
        .pdata_i   ( cam_d_d0     ),
        .de_i      ( cam_href_d0  ),
        .vs_i      ( cam_vsync_d0 ),
        .pixel_clk ( pix_clk_0    ),
        .de_o      ( de16_0       ),
        .pdata_o   ( dat16_0      )
    );

    cmos_8_16bit u_cmos16_1 (
        .pclk      ( camera_clk_1 ),
        .rst_n     ( cam_rstn_1   ),
        .pdata_i   ( cam_d_d1     ),
        .de_i      ( cam_href_d1  ),
        .vs_i      ( cam_vsync_d1 ),
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
    // 数据/href/vs 的 mux：位于**两套 IDDR 之后**，纯数据路径
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
        .wr_fsync      ( cam_wr_fsync   ),   // = cam_fsync & cam_wr_ok & ~gui_mode_sync
        .wr_en         ( cam_wr_en      ),   // = cam_de_crop & cam_wr_ok & ~gui_mode_sync
        .wr_data       ( cam_data16     ),
        .gui_mode      ( gui_mode_d2    ),   // ddr_clk 域：GUI 模式读 bank 选择
        .gui_bank      ( gui_bank_d2    ),
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
    //-------------------------------------------------------------------------
    assign ddr_awaddr  = axi_awaddr + FB_ADDR_WORD;
    assign ddr_awlen   = axi_awlen;
    assign ddr_awvalid = axi_awvalid;
    assign ddr_wdata   = axi_wdata;
    assign ddr_wstrb   = axi_wstrb;
    assign ddr_wvalid  = axi_wvalid;
    assign ddr_araddr  = axi_araddr + FB_ADDR_WORD;
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
    // GUI 模式屏蔽相机切换黑屏（Phase R 修订）
    //   cam_switch 的 black 在 LCD 域、复位初值 1，只在"相机 ready + 写完 n 帧"
    //   后清除；GUI 模式冻结相机写后 frame_start 被掐，black 可能永远不清 ⇒
    //   即使 LCD 已读 GUI bank 也会被整屏刷黑。⇒ GUI 模式下不采纳该黑屏；
    //   相机模式保持原行为（含切换瞬态黑屏）。gui_mode 是 soc_clk 慢变电平，
    //   2FF 进 lcd_clk；黑屏与像素在同一级寄存器生效，无组合毛刺。
    //-------------------------------------------------------------------------
    reg gui_mode_l1, gui_mode_l2;
    always @(posedge lcd_clk or negedge lcd_rstn) begin
        if (!lcd_rstn) begin
            gui_mode_l1 <= 1'b0;
            gui_mode_l2 <= 1'b0;
        end else begin
            gui_mode_l1 <= gui_mode;
            gui_mode_l2 <= gui_mode_l1;
        end
    end
    wire lcd_black = cam_black & ~gui_mode_l2;

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
