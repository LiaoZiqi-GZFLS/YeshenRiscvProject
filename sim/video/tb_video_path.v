//=============================================================================
// tb_video_path: U2 闸门 —— 相机(旁路) -> 裁列 -> 帧存 -> DDR 模型 -> LCD
//
// 判据：LCD DE 期间逐像素比对 RGB565（888 由 {565,低位补 0} 展开，故取高位还原）
//   got = {lcd_r[7:3], lcd_g[7:2], lcd_b[7:3]}   // 5+6+5 = 16 bit
//   exp = {(cx+128)&8'hFF, (cy+EXP_ROW_OFFSET)&8'hFF}
// 图案：vin_pix = {x[7:0], y[7:0]}（x=相机列 0..1279，y=相机行 0..719）
//
// 先红后绿（负对照）：
//   -DROW_OFFSET=0  => DUT 退回厂家默认（显示窗口从行 0 起读），期望仍是行 60
//                      => 必红（mismatches>0），证明闸门真的看行偏移；
//   -DROW_OFFSET=60 => 绿。
//   注：期望行用独立的 EXP_ROW_OFFSET 宏（默认 60）。计划原文让期望也用
//   ROW_OFFSET 宏，那样两边同时变 0，红灯永远点不亮（自相矛盾）。
//
// 预热：仿真从 X/半帧开始，跳过前 2 个显示帧再开始计数（否则首帧必错）。
//=============================================================================
`timescale 1ns/1ps

`ifndef ROW_OFFSET
`define ROW_OFFSET 60
`endif
`ifndef EXP_ROW_OFFSET
`define EXP_ROW_OFFSET 60
`endif
`ifndef LCD_WAIT
`define LCD_WAIT 4000000
`endif

module tb_video_path;
    reg vin_clk=0, ddr_clk=0, lcd_clk=0, rstn=0;
    always #5 vin_clk=~vin_clk;      // 100 MHz
    always #4 ddr_clk=~ddr_clk;      // 125 MHz
    always #9.6295 lcd_clk=~lcd_clk; // 51.923 MHz

    reg vin_de=0, vin_vsync=1;
    reg [15:0] vin_pix=0;

    wire [27:0] awaddr; wire [3:0] awlen; wire awvalid, awready;
    wire [255:0] wdata; wire [31:0] wstrb; wire wvalid, wready, wusero_last;
    wire [27:0] araddr; wire [3:0] arlen; wire arvalid, arready;
    wire [255:0] rdata; wire [3:0] rid; wire rlast, rvalid, rready;
    wire lcd_pclk, lcd_de, lcd_hs, lcd_vs, lcd_pwm;
    wire [7:0] lcd_r, lcd_g, lcd_b;
    wire frame_toggle, wr_bank, cam_init_done, ovl_bank;

    // 本 TB 不经仲裁器：读通道 id 固定（仲裁器 Task 5 才分流）
    wire [3:0] aruser_id = 4'h1;

    video_passthrough #(
        .SIM_BYPASS_CAMERA ( 1           ),
        .ROW_OFFSET        ( `ROW_OFFSET )
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
        .gui_src        (1'b0),
        .gui_bank       (1'b0),          // GPU 双缓冲 bank：U2 恒 bank0
        .frame_rd_toggle(),              // U2 不看
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

    ddr_model ddr (.clk(ddr_clk), .rstn(rstn),
        .awaddr(awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
        .wusero_last(wusero_last),
        .araddr(araddr), .arlen(arlen), .aruser_id(aruser_id), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rid(rid), .rlast(rlast), .rvalid(rvalid), .rready(rready));

    //-------------------------------------------------------------------------
    // 相机激励：每帧 720 行，每行 1280 拍 de=1；行间 40 拍 de=0；
    //           帧前 vin_vsync 低 4 拍。
    //-------------------------------------------------------------------------
    task drive_frame(input integer n);
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

    //-------------------------------------------------------------------------
    // LCD 捕获 + 比对
    //-------------------------------------------------------------------------
    integer cx, cy, errs=0, nchk=0, vs_cnt=0, addr_errs=0, shown=0;
    reg [15:0] got, exp;
    reg [7:0]  ex, ey;
    reg chk_en=0;
    reg vs_d=1;

    always @(posedge lcd_pclk) begin
        vs_d <= lcd_vs;
        if (vs_d && !lcd_vs) begin              // vsync 低脉冲起点 = 帧起点
            vs_cnt <= vs_cnt + 1;
            if (vs_cnt >= 2) chk_en <= 1'b1;    // 跳过前 2 帧预热
        end
        if (lcd_vs == 1'b0) begin
            cx <= 0;
            cy <= 0;
        end else if (lcd_de) begin
            if (chk_en) begin
                got = {lcd_r[7:3], lcd_g[7:2], lcd_b[7:3]};   // 888 -> 565 还原
                ex  = (cx + 128) & 8'hFF;
                ey  = (cy + `EXP_ROW_OFFSET) & 8'hFF;
                exp = {ex, ey};
                nchk = nchk + 1;
                if (got !== exp) begin
                    errs = errs + 1;
                    if (shown < 6) begin
                        shown = shown + 1;
                        $display("VIDEO_PATH: MISMATCH t=%0t x=%0d y=%0d got=%04x exp=%04x rgb=%02x/%02x/%02x",
                                 $time, cx, cy, got, exp, lcd_r, lcd_g, lcd_b);
                    end
                end
            end
            if (cx == 1023) begin cx <= 0; cy <= cy + 1; end
            else             begin cx <= cx + 1; end
        end
    end

    // AXI 地址下界检查（帧存必须在 FB_ADDR_WORD=0x0400_0000 之上）
    always @(posedge ddr_clk) begin
        if (awvalid && awready && (awaddr < 28'h400_0000)) addr_errs = addr_errs + 1;
        if (arvalid && arready && (araddr < 28'h400_0000)) addr_errs = addr_errs + 1;
    end



    initial begin
        repeat (10) @(posedge vin_clk);
        rstn = 1;
        drive_frame(0);        // 第 1 帧
        drive_frame(1);        // 第 2 帧

        repeat (`LCD_WAIT) @(posedge lcd_clk);
        $display("VIDEO_PATH: checked_px=%0d frames=%0d mismatches=%0d addr_errs=%0d (DUT ROW_OFFSET=%0d, EXP=%0d)",
                 nchk, vs_cnt, errs, addr_errs, `ROW_OFFSET, `EXP_ROW_OFFSET);
        if (errs == 0 && addr_errs == 0 && nchk > 500000)
            $display("VIDEO_PATH: PASS");
        else begin
            $display("VIDEO_PATH: FAIL mismatches=%0d addr_errs=%0d checked_px=%0d", errs, addr_errs, nchk);
            $fatal;
        end
        $finish;
    end
endmodule
