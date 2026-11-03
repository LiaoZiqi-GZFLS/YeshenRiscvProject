//=============================================================================
// tb_gui_src: U8 闸门 —— LCD 读源选择（GUI 第二帧存）
//
// 被测行为（video_passthrough，参数全用默认值）：
//   gui_src=0 → DDR 读地址 = FB_ADDR_WORD(0x400_0000) + axi_araddr   （相机 bank）
//   gui_src=1 → DDR 读地址 = GUI_BASE_WORD(0x480_0000) + axi_araddr[21:0]
//   换源只在**读帧首**生效（与 rd_buf 内部 wr_cnt 复位同拍）。
//
// 装置：极简只读 DDR 应答器，按地址区域回常量像素（不做存储）：
//   相机区（< 0x480_0000）→ 每个 32-bit 字 = {16'h1080,16'h1080}
//   GUI 区（[0x480_0000, 0x490_0000)）→ 每个 32-bit 字 = {16'h2A55,16'h2A55}
//   其余地址 = 未知区（记账）
//   ⇒ 屏幕内容直接就是"读的是哪个源"的证据（565 直通，overlay 关闭）。
//
// 判据（全部要 0）：
//   J1 unknown_ar   —— 读地址落在两个已知区之外（含默认 GUI 基址被改错）
//   J2 mixed_frame  —— 同一帧内读源发生切换（AR 区域变化时距上一笔 AR < 10000
//                      ddr 拍；行间空隙 3237 拍、场消隐 ~113000 拍，判据有 3x 余量）
//   J3 aw_in_gui    —— 写地址落进 GUI 区（相机写绝不许碰 GUI 帧存）
//   J4 屏幕内容     —— 三档各 N 帧，逐像素 == 该档期望常量
//   且每档都要真的看到该档的 AR（cam_ar>0 / gui_ar>0），否则"没切换"也算过。
//
// 负对照（run 脚本自动生成坏副本）：把 `else if (rd_frame_rst) gui_sel_ddr <= gui_s2;`
//   改成 `else gui_sel_ddr <= gui_s2;`（立刻跟随）⇒ J2 必须发火。
//=============================================================================
`timescale 1ns/1ps

module tb_gui_src;
    reg vin_clk=0, ddr_clk=0, lcd_clk=0, rstn=0;
    always #5 vin_clk=~vin_clk;       // 100 MHz
    always #4 ddr_clk=~ddr_clk;       // 125 MHz
    always #9.6295 lcd_clk=~lcd_clk;  // 51.923 MHz

    reg vin_de=0, vin_vsync=1;
    reg [15:0] vin_pix=0;
    reg gui_src=0;
    reg gui_bank=0;                  // 2026-10-31 GPU 双缓冲：GUI 帧存 bank
    wire rd_tog;                     // 读帧起点翻转（本 TB 只观察）

    // 应答器驱动的那几根由下面的 always 块驱动 ⇒ reg；其余是 DUT 输出 ⇒ wire
    wire [27:0] awaddr; wire [3:0] awlen; wire awvalid;
    reg         awready=1;
    wire [255:0] wdata; wire [31:0] wstrb; wire wvalid;
    reg         wready=0;
    wire        wusero_last;
    wire [27:0] araddr; wire [3:0] arlen; wire arvalid;
    reg         arready=1;
    reg  [255:0] rdata=0; reg [3:0] rid=0; reg rlast=0, rvalid=0;
    wire        rready;
    wire lcd_pclk, lcd_de, lcd_hs, lcd_vs, lcd_pwm;
    wire [7:0] lcd_r, lcd_g, lcd_b;
    wire frame_toggle, wr_bank, cam_init_done, ovl_bank;

    // ★ 不给 GUI_BASE_WORD 传参：用 RTL 默认值（本闸门同时钉住这个常量）
    video_passthrough #(
        .SIM_BYPASS_CAMERA ( 1 ),
        .ROW_OFFSET        ( 60 )
    ) dut (
        .sys_clk(vin_clk), .cam_rstn(rstn), .ddr_clk(ddr_clk), .ddr_rstn(rstn),
        .lcd_clk(lcd_clk), .lcd_rstn(rstn), .ddr_init_done(rstn),
        .camera_clk_0(1'b0), .camera_data_0(8'd0), .camera_href_0(1'b0),
        .camera_vsync_0(1'b0), .SCL_0(), .SDA_0(), .cam_rst_0(),
        .camera_clk_1   (1'b0),
        .camera_data_1  (8'h00),
        .camera_href_1  (1'b0),
        .camera_vsync_1 (1'b0),
        .SCL_1          (),
        .SDA_1          (),
        .cam_rst_1      (),
        .soc_clk        (1'b0),
        .soc_rstn       (1'b0),
        .cam_sel        (1'b0),
        .cam_ready      (),
        .switch_busy    (),
        .gui_src        (gui_src),
        .gui_bank       (gui_bank),      // 2026-10-31 GPU 双缓冲：本 TB 显式驱动 bank
        .frame_rd_toggle(rd_tog),        // 读帧起点翻转（本 TB 只观察，不判）
        .vin_clk(vin_clk), .vin_de(vin_de), .vin_vsync(vin_vsync), .vin_pix(vin_pix),
        .ddr_awaddr(awaddr), .ddr_awlen(awlen), .ddr_awvalid(awvalid), .ddr_awready(awready),
        .ddr_wdata(wdata), .ddr_wstrb(wstrb), .ddr_wvalid(wvalid), .ddr_wready(wready),
        .ddr_wusero_last(wusero_last),
        .ddr_araddr(araddr), .ddr_arlen(arlen), .ddr_arvalid(arvalid), .ddr_arready(arready),
        .ddr_rdata(rdata), .ddr_rid(rid), .ddr_rlast(rlast), .ddr_rvalid(rvalid), .ddr_rready(rready),
        .lcd_pclk(lcd_pclk), .lcd_de(lcd_de), .lcd_hs(lcd_hs), .lcd_vs(lcd_vs), .lcd_pwm(lcd_pwm),
        .lcd_r(lcd_r), .lcd_g(lcd_g), .lcd_b(lcd_b),
        .frame_toggle(frame_toggle), .wr_bank(wr_bank), .cam_init_done(cam_init_done),
        .ovl_wr_clk(vin_clk), .ovl_wr_rstn(rstn), .ovl_wr_en(1'b0), .ovl_wr_addr(5'd0),
        .ovl_wr_data(32'd0), .ovl_commit(1'b0), .ovl_en(1'b0), .ovl_count(8'd0),
        .ovl_active_bank(ovl_bank)
    );

    //-------------------------------------------------------------------------
    // 极简只读应答器（单未完成；读延迟与 ddr_model 相同，保证 rd_cmd_done 单拍）
    //-------------------------------------------------------------------------
    localparam [15:0] PIX_CAM  = 16'h1080;
    localparam [15:0] PIX_GUI  = 16'h2A55;
    localparam [15:0] PIX_GUI1 = 16'h3C3C;   // bank1 专有像素（证明确实换了 bank）
    localparam [27:0] CAM_LO  = 28'h400_0000;
    localparam [27:0] GUI_LO  = 28'h480_0000;
    localparam [27:0] GUI_HI  = 28'h490_0000;
    localparam [27:0] GUI1_LO = 28'h4A0_0000;   // GUI_LO + 2 MiB（gui_bank=1）
    localparam [27:0] GUI1_HI = 28'h4B0_0000;

    reg [3:0]  wleft; reg [27:0] waddr_q;
    reg [3:0]  rleft; reg [4:0] rdelay;
    reg rbusy=0;
    reg [15:0] rd_pix;

    assign wusero_last = wvalid && wready && (wleft == 4'd0);

    always @(posedge ddr_clk) begin
        if (!rstn) begin
            awready<=1; wready<=0; wleft<=0; waddr_q<=0;
            arready<=1; rvalid<=0; rlast<=0; rdata<=0; rid<=0;
            rleft<=0; rdelay<=0; rbusy<=0; rd_pix<=0;
        end else begin
            if (rvalid && rready) rvalid <= 1'b0;

            // ---- 写通道：收下并丢弃 ----
            if (awvalid && awready) begin
                awready <= 1'b0; waddr_q <= awaddr; wleft <= awlen; wready <= 1'b1;
            end
            if (wvalid && wready) begin
                if (wleft == 4'd0) begin wready <= 1'b0; awready <= 1'b1; end
                else wleft <= wleft - 4'd1;
            end

            // ---- 读通道 ----
            if (rbusy) begin
                if (rdelay > 0) rdelay <= rdelay - 5'd1;
                else begin
                    rvalid <= 1'b1;
                    rdata  <= {8{rd_pix, rd_pix}};
                    rid    <= 4'd1;
                    rlast  <= (rleft == 4'd0);
                    if (rleft == 4'd0) begin rbusy <= 1'b0; arready <= 1'b1; end
                    else rleft <= rleft - 4'd1;
                end
            end else if (arvalid && arready) begin
                arready <= 1'b0;
                rd_pix  <= (araddr >= GUI1_LO) ? PIX_GUI1 :
                           ((araddr >= GUI_LO) ? PIX_GUI : PIX_CAM);
                rleft   <= arlen;
                rdelay  <= 5'd8;
                rbusy   <= 1'b1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // 地址记账（ddr 域）
    //-------------------------------------------------------------------------
    integer ar_cam=0, ar_gui=0, ar_gui1=0, ar_unknown=0, aw_gui=0, mixed_frame=0;
    integer since_ar=0;
    // 区域码：0=相机 1=GUI bank0 2=GUI bank1 3=未知
    reg [1:0] prv_reg=2'd3, reg_now=2'd3;
    reg       prv_valid=1'b0;

    always @(posedge ddr_clk) begin
        if (!rstn) begin
            since_ar <= 0;
        end else begin
            since_ar <= since_ar + 1;
            if (awvalid && awready && (awaddr >= GUI_LO))
                aw_gui <= aw_gui + 1;

            if (arvalid && arready) begin
                since_ar <= 0;
                if (araddr >= GUI1_LO && araddr < GUI1_HI) begin
                    ar_gui1 <= ar_gui1 + 1;
                    reg_now  = 2'd2;
                end else if (araddr >= GUI_LO && araddr < GUI_HI) begin
                    ar_gui <= ar_gui + 1;
                    reg_now = 2'd1;
                end else if (araddr >= CAM_LO && araddr < GUI_LO) begin
                    ar_cam <= ar_cam + 1;
                    reg_now = 2'd0;
                end else begin
                    ar_unknown <= ar_unknown + 1;
                    reg_now = 2'd3;
                end
                // 帧内跨区（含 bank0 <-> bank1）都算混用
                if (prv_valid && prv_reg != 2'd3 && reg_now != 2'd3 &&
                    prv_reg != reg_now && since_ar < 10000)
                    mixed_frame <= mixed_frame + 1;
                prv_reg   <= reg_now;
                prv_valid <= 1'b1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // 屏幕内容记账（lcd 域）
    //-------------------------------------------------------------------------
    integer vs_cnt=0, bad_px=0, good_px=0;
    reg [15:0] exp_pix=0;
    reg chk_en=0;
    reg vs_d=1;
    reg [15:0] got;

    always @(posedge lcd_pclk) begin
        vs_d <= lcd_vs;
        if (vs_d && !lcd_vs) vs_cnt <= vs_cnt + 1;
        if (lcd_de && chk_en) begin
            got = {lcd_r[7:3], lcd_g[7:2], lcd_b[7:3]};
            if (got === exp_pix) good_px <= good_px + 1;
            else bad_px <= bad_px + 1;
        end
    end

    //-------------------------------------------------------------------------
    // 相机激励（只为让写侧有真实帧；读侧不依赖它）
    //-------------------------------------------------------------------------
    task drive_frame;
        integer x, y;
        begin
            vin_vsync = 0;
            repeat (4) @(posedge vin_clk);
            vin_vsync = 1;
            repeat (4) @(posedge vin_clk);
            for (y=0; y<720; y=y+1) begin
                for (x=0; x<1280; x=x+1) begin
                    vin_pix = {x[7:0], y[7:0]};
                    vin_de  = 1;
                    @(posedge vin_clk);
                end
                vin_de = 0;
                repeat (40) @(posedge vin_clk);
            end
            vin_de = 0;
        end
    endtask

    // 一档：立刻改源（故意落在帧中途）→ 等 SETTLE 帧 → 记 NCHK 帧
    //   `-DFAST`：只跑**一次**换源且不等待（负对照用；坏 DUT 当场就会跨区读）
`ifdef FAST
    localparam integer SETTLE = 0;
    localparam integer NCHK   = 1;
`else
    localparam integer SETTLE = 2;
    localparam integer NCHK   = 1;
`endif

    integer phase_errs=0;

    task run_phase(input src, input bank, input [15:0] px, input integer is_gui);
        integer f0, c0, g0, g10;
        begin
            gui_src  = src;                      // 不挑时刻：就是要"帧中途改"
            gui_bank = bank;
            f0 = vs_cnt;
            while (vs_cnt < f0 + SETTLE) @(posedge lcd_clk);
            exp_pix = px; chk_en = 1'b1;
            bad_px  = 0; good_px = 0;
            c0 = ar_cam; g0 = ar_gui; g10 = ar_gui1;
            while (vs_cnt < f0 + SETTLE + NCHK) @(posedge lcd_clk);
            chk_en = 1'b0;
            $display("GUI_SRC: phase src=%0d bank=%0d exp=%04x good=%0d bad=%0d dARcam=%0d dARgui=%0d dARgui1=%0d",
                     src, bank, px, good_px, bad_px, ar_cam-c0, ar_gui-g0, ar_gui1-g10);
            if (bad_px != 0) begin
                $display("GUI_SRC: PHASE FAIL src=%0d bank=%0d bad_px=%0d", src, bank, bad_px);
                phase_errs = 1;
            end
            if (is_gui && bank && (ar_gui1 - g10) == 0) begin
                $display("GUI_SRC: PHASE FAIL src=1 bank=1 没有走进 GUI bank1 区");
                phase_errs = 1;
            end
            if (is_gui && !bank && (ar_gui - g0) == 0) begin
                $display("GUI_SRC: PHASE FAIL src=1 bank=0 没有走进 GUI bank0 区");
                phase_errs = 1;
            end
            if (!is_gui && (ar_cam - c0) == 0) begin
                $display("GUI_SRC: PHASE FAIL src=0 没有走进相机区");
                phase_errs = 1;
            end
        end
    endtask

    initial begin
        repeat (10) @(posedge vin_clk);
        rstn = 1;
        drive_frame;              // 第 1 帧
        drive_frame;              // 第 2 帧

        run_phase(1'b0, 1'b0, PIX_CAM, 1'b0);
        run_phase(1'b1, 1'b0, PIX_GUI, 1'b1);
        run_phase(1'b1, 1'b1, PIX_GUI1, 1'b1);   // 2026-10-31 GUI 双缓冲：换 bank
`ifndef FAST
        run_phase(1'b0, 1'b0, PIX_CAM, 1'b0);    // 切回去：证选择位不是"粘住"
`endif

        $display("GUI_SRC: ar_cam=%0d ar_gui=%0d ar_gui1=%0d ar_unknown=%0d aw_gui=%0d mixed_frame=%0d frames=%0d",
                 ar_cam, ar_gui, ar_gui1, ar_unknown, aw_gui, mixed_frame, vs_cnt);
        if (phase_errs != 0 || ar_unknown != 0 || aw_gui != 0 || mixed_frame != 0 ||
            ar_cam == 0 || ar_gui == 0 || ar_gui1 == 0)
            phase_errs = 1;

        if (phase_errs == 0)
            $display("GUI_SRC: PASS");
        else begin
            $display("GUI_SRC: FAIL unknown=%0d aw_gui=%0d mixed=%0d cam=%0d gui=%0d",
                     ar_unknown, aw_gui, mixed_frame, ar_cam, ar_gui);
            $fatal;
        end
        $finish;
    end

    initial begin
        #500_000_000;
        $display("GUI_SRC: TIMEOUT");
        $fatal;
    end
endmodule
