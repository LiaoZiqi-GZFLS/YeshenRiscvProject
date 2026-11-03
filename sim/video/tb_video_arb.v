//=============================================================================
// tb_video_arb: U1c 闸门 —— **视频帧存 + 桥侧 CPU 流量并发**穿同一颗 2:1 仲裁器
//
// 为什么需要：U2（视频路径）把 video_passthrough 直接接 ddr_model，不经过仲裁器；
//   U1（仲裁器）只测单拍写/读，没有持续的视频 burst 并发。厂家的 `wr_ctrl` 对
//   W 通道的时序假设（wvalid=wready、wlast 同拍、整 burst 的地址/数据配对）与
//   仲裁器的 W 通道一旦错位，表现就是**帧存内容花/闪**（本次现场症状）。
//
// 判据：
//   1) LCD DE 期间逐像素 == {x+128, y+ROW_OFFSET}（与 U2 同图案、同口径）
//      ⇒ 视频写→帧存→LCD 读整链在**并发桥流量**下仍逐像素正确；
//   2) 桥侧 200 笔 32B 写 + 逐笔读回，数据必须与写入模式**逐字节相同**
//      （写/读都被视频 burst 打断过）；
//   3) 桥侧地址不许落进帧存窗口（< 0x400_0000 只允许专用 scratch 段），
//      防止本闸门自己踩帧存造成假红。
// 负对照（脚本跑）：
//   -Ptb_video_arb.TB_BN=1 不影响本判据（视频单笔）；真正的负对照是
//   `-DTB_NEG_NOARB=1`：把视频直连 ddr_model（绕过仲裁器）——用来证明
//   "判据本身能红"不是靠仲裁器缺席，而是靠激励；见 run_video_gates.sh。
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

module tb_video_arb;
    reg vin_clk=0, ddr_clk=0, lcd_clk=0, rstn=0;
    always #5 vin_clk=~vin_clk;      // 100 MHz
    always #4 ddr_clk=~ddr_clk;      // 125 MHz
    always #9.6295 lcd_clk=~lcd_clk; // 51.923 MHz

    reg vin_de=0, vin_vsync=1;
    reg [15:0] vin_pix=0;

    // 视频侧（→ 仲裁器 v_*）
    wire [27:0] v_awaddr; wire [3:0] v_awlen; wire v_awvalid, v_awready;
    wire [255:0] v_wdata; wire [31:0] v_wstrb; wire v_wvalid, v_wready, v_wlast;
    wire [27:0] v_araddr; wire [3:0] v_arlen; wire v_arvalid, v_arready;
    wire [255:0] v_rdata; wire [3:0] v_rid; wire v_rlast, v_rvalid, v_rready;
    // 桥侧（TB 驱动）
    reg  [27:0] b_awaddr=0, b_araddr=0;
    reg  [3:0]  b_awlen=0, b_arlen=0;
    reg         b_awvalid=0, b_wvalid=0, b_arvalid=0;
    reg  [255:0] b_wdata=0;
    reg  [31:0] b_wstrb=32'hFFFF_FFFF;
    wire        b_awready, b_wready, b_arready, b_wlast;
    wire [255:0] b_rdata;
    wire [3:0]  b_rid;
    wire        b_rlast, b_rvalid;
    wire        b_rready = 1'b1;     // 板级恒 1
    // IP 侧
    wire [27:0] m_awaddr, m_araddr;
    wire [3:0]  m_awlen, m_arlen, m_aruser_id, m_rid;
    wire        m_awvalid, m_awready;
    wire [255:0] m_wdata, m_rdata;
    wire [31:0] m_wstrb;
    wire        m_wvalid, m_wready, m_wusero_last;
    wire        m_arvalid, m_arready;
    wire        m_rlast, m_rvalid, m_rready;
    wire [31:0] dbg_v_ar_wait;

    wire lcd_pclk, lcd_de, lcd_hs, lcd_vs, lcd_pwm;
    wire [7:0] lcd_r, lcd_g, lcd_b;
    wire frame_toggle, wr_bank, cam_init_done, ovl_bank;

    video_passthrough #(
        .SIM_BYPASS_CAMERA ( 1           ),
        .ROW_OFFSET        ( `ROW_OFFSET )
    ) dut (
        .sys_clk(vin_clk), .cam_rstn(rstn), .ddr_clk(ddr_clk), .ddr_rstn(rstn),
        .lcd_clk(lcd_clk), .lcd_rstn(rstn), .ddr_init_done(rstn),
        .camera_clk_0(1'b0), .camera_data_0(8'd0), .camera_href_0(1'b0),
        .camera_vsync_0(1'b0), .SCL_0(), .SDA_0(), .cam_rst_0(),
        .soc_clk(1'b0), .soc_rstn(1'b0), .cam_sel(1'b0), .cam_ready(), .switch_busy(),
        .gui_src(1'b0),
        .vin_clk(vin_clk), .vin_de(vin_de), .vin_vsync(vin_vsync), .vin_pix(vin_pix),
        .ddr_awaddr(v_awaddr), .ddr_awlen(v_awlen), .ddr_awvalid(v_awvalid), .ddr_awready(v_awready),
        .ddr_wdata(v_wdata), .ddr_wstrb(v_wstrb), .ddr_wvalid(v_wvalid), .ddr_wready(v_wready),
        .ddr_wusero_last(v_wlast),
        .ddr_araddr(v_araddr), .ddr_arlen(v_arlen), .ddr_arvalid(v_arvalid), .ddr_arready(v_arready),
        .ddr_rdata(v_rdata), .ddr_rid(v_rid), .ddr_rlast(v_rlast), .ddr_rvalid(v_rvalid), .ddr_rready(v_rready),
        .lcd_pclk(lcd_pclk), .lcd_de(lcd_de), .lcd_hs(lcd_hs), .lcd_vs(lcd_vs), .lcd_pwm(lcd_pwm),
        .lcd_r(lcd_r), .lcd_g(lcd_g), .lcd_b(lcd_b),
        .frame_toggle(frame_toggle), .wr_bank(wr_bank), .cam_init_done(cam_init_done),
        .ovl_wr_clk(vin_clk), .ovl_wr_rstn(rstn), .ovl_wr_en(1'b0), .ovl_wr_addr(5'd0),
        .ovl_wr_data(32'd0), .ovl_commit(1'b0), .ovl_en(1'b0), .ovl_count(8'd0),
        .ovl_active_bank(ovl_bank)
    );

    ddr_arbiter_2to1 #(.AW(28), .BN(4), .VN(1)) arb (
        .clk(ddr_clk), .rstn(rstn),
        .b_awaddr(b_awaddr), .b_awlen(b_awlen), .b_awvalid(b_awvalid), .b_awready(b_awready),
        .b_wdata(b_wdata), .b_wstrb(b_wstrb), .b_wvalid(b_wvalid), .b_wready(b_wready),
        .b_araddr(b_araddr), .b_arlen(b_arlen), .b_arvalid(b_arvalid), .b_arready(b_arready),
        .b_rdata(b_rdata), .b_rid(b_rid), .b_rlast(b_rlast), .b_rvalid(b_rvalid), .b_rready(b_rready),
        .v_awaddr(v_awaddr), .v_awlen(v_awlen), .v_awvalid(v_awvalid), .v_awready(v_awready),
        .v_wdata(v_wdata), .v_wstrb(v_wstrb), .v_wvalid(v_wvalid), .v_wready(v_wready),
        .v_araddr(v_araddr), .v_arlen(v_arlen), .v_arvalid(v_arvalid), .v_arready(v_arready),
        .v_rdata(v_rdata), .v_rid(v_rid), .v_rlast(v_rlast), .v_rvalid(v_rvalid), .v_rready(v_rready),
        .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wvalid(m_wvalid), .m_wready(m_wready),
        .m_wusero_last(m_wusero_last),
        .m_araddr(m_araddr), .m_arlen(m_arlen), .m_aruser_id(m_aruser_id),
        .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rdata(m_rdata), .m_rid(m_rid), .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready),
        .b_wlast(b_wlast), .v_wlast(v_wlast),
        .dbg_v_ar_wait(dbg_v_ar_wait)
    );

    ddr_model #(.AW(28), .LAT(8), .ARDEPTH(4)) ddr (.clk(ddr_clk), .rstn(rstn),
        .awaddr(m_awaddr), .awlen(m_awlen), .awvalid(m_awvalid), .awready(m_awready),
        .wdata(m_wdata), .wstrb(m_wstrb), .wvalid(m_wvalid), .wready(m_wready),
        .wusero_last(m_wusero_last),
        .araddr(m_araddr), .arlen(m_arlen), .aruser_id(m_aruser_id),
        .arvalid(m_arvalid), .arready(m_arready),
        .rdata(m_rdata), .rid(m_rid), .rlast(m_rlast), .rvalid(m_rvalid), .rready(m_rready));

    //-------------------------------------------------------------------------
    // 相机激励（与 U2 同图案）
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

    //-------------------------------------------------------------------------
    // 桥侧流量：200 笔 32B 写 + 逐笔读回（scratch 段，避开帧存窗口）
    //   地址 0x0030_0000 + seq*8（32B 对齐）；模型 mem 索引 addr[22:3]，
    //   该段与帧存（0x400_0000 起的 alias 0..0x8B400）不重叠。
    //-------------------------------------------------------------------------
    localparam [27:0] SCRATCH = 28'h0030_0000;
    integer b_errs = 0, b_done = 0;
    integer s, k;
    reg [255:0] b_exp;

    task b_write32(input [27:0] a, input [255:0] d0);
        begin
            @(negedge ddr_clk);
            b_awaddr = a; b_awlen = 4'd3; b_awvalid = 1'b1;
            b_wdata  = d0; b_wstrb = 32'hFFFF_FFFF; b_wvalid = 1'b1;
            while (!b_awready) @(negedge ddr_clk);
            @(posedge ddr_clk);
            @(negedge ddr_clk);
            b_awvalid = 1'b0;
            b_wvalid  = 1'b0;              // 板级语义：b_wvalid == awvalid
            for (k=0; k<4; k=k+1) begin
                while (!b_wready) @(negedge ddr_clk);
                @(posedge ddr_clk);
                @(negedge ddr_clk);
                if (k != 3) b_wdata = d0 + (k + 1);
            end
        end
    endtask

    task b_read32(input [27:0] a, output [255:0] d0);
        begin
            @(negedge ddr_clk);
            b_araddr = a; b_arlen = 4'd3; b_arvalid = 1'b1;
            while (!b_arready) @(negedge ddr_clk);
            @(posedge ddr_clk);
            @(negedge ddr_clk);
            b_arvalid = 1'b0;
            for (k=0; k<4; k=k+1) begin
                while (!b_rvalid) @(negedge ddr_clk);
                if (k == 0) d0 = b_rdata;
                @(posedge ddr_clk);
                @(negedge ddr_clk);
            end
        end
    endtask

    initial begin : bridge_traffic
        integer i;
        reg [255:0] got;
        wait (rstn);
        repeat (50) @(negedge ddr_clk);
        for (i=0; i<200; i=i+1) begin
            b_exp = {8{i[7:0]}};                 // 简而可判的模式
            b_write32(SCRATCH + (i << 3), b_exp);
            b_read32 (SCRATCH + (i << 3), got);
            if (got !== b_exp) begin
                if (b_errs < 5)
                    $display("VIDEO_ARB: BRIDGE MISMATCH i=%0d got=%h exp=%h", i, got, b_exp);
                b_errs = b_errs + 1;
            end
        end
        b_done = 1;
    end

    //-------------------------------------------------------------------------
    // LCD 捕获 + 比对（同 U2）
    //-------------------------------------------------------------------------
    integer cx, cy, errs=0, nchk=0, vs_cnt=0, shown=0;
    reg [15:0] got_px, exp_px;
    reg [7:0]  ex, ey;
    reg chk_en=0;
    reg vs_d=1;

    always @(posedge lcd_pclk) begin
        vs_d <= lcd_vs;
        if (vs_d && !lcd_vs) begin
            vs_cnt <= vs_cnt + 1;
            if (vs_cnt >= 2) chk_en <= 1'b1;
        end
        if (lcd_vs == 1'b0) begin
            cx <= 0;
            cy <= 0;
        end else if (lcd_de) begin
            if (chk_en) begin
                got_px = {lcd_r[7:3], lcd_g[7:2], lcd_b[7:3]};
                ex  = (cx + 128) & 8'hFF;
                ey  = (cy + `EXP_ROW_OFFSET) & 8'hFF;
                exp_px = {ex, ey};
                nchk = nchk + 1;
                if (got_px !== exp_px) begin
                    errs = errs + 1;
                    if (shown < 6) begin
                        shown = shown + 1;
                        $display("VIDEO_ARB: LCD MISMATCH t=%0t x=%0d y=%0d got=%04x exp=%04x rgb=%02x/%02x/%02x",
                                 $time, cx, cy, got_px, exp_px, lcd_r, lcd_g, lcd_b);
                    end
                end
            end
            if (cx == 1023) begin cx <= 0; cy <= cy + 1; end
            else             begin cx <= cx + 1; end
        end
    end

    // 视频 AR / R 末拍计数（判重复读或丢 rlast）
    integer v_ar_cnt = 0, v_rl_cnt = 0, b_ar_cnt = 0, b_rl_cnt = 0, v_rd_cnt=0;
    always @(posedge ddr_clk) begin
        if (v_arvalid && v_arready) v_ar_cnt <= v_ar_cnt + 1;
        if (v_rvalid && v_rready && v_rlast) v_rl_cnt <= v_rl_cnt + 1;
        if (b_arvalid && b_arready) b_ar_cnt <= b_ar_cnt + 1;
        if (b_rvalid && b_rready && b_rlast) b_rl_cnt <= b_rl_cnt + 1;
        if (v_rvalid && v_rready) v_rd_cnt <= v_rd_cnt + 1;
    end

    // 视频写 burst 完成脉冲 / 帧翻转计数（判"厂家 wr_ctrl 是否被卡死"）
    integer v_wl_cnt = 0, ft_cnt = 0;
    reg ft_d = 0;
    always @(posedge ddr_clk) begin
        if (v_wlast) v_wl_cnt <= v_wl_cnt + 1;
        ft_d <= frame_toggle;
        if (frame_toggle & ~ft_d) ft_cnt <= ft_cnt + 1;
    end

    // 桥地址不许落进帧存窗口下界（scratch 除外）
    integer addr_errs = 0;
    always @(posedge ddr_clk) begin
        if (b_awvalid && b_awready && (b_awaddr < 28'h400_0000) &&
            !(b_awaddr >= SCRATCH && b_awaddr < SCRATCH + 28'h4000)) addr_errs = addr_errs + 1;
        if (b_arvalid && b_arready && (b_araddr < 28'h400_0000) &&
            !(b_araddr >= SCRATCH && b_araddr < SCRATCH + 28'h4000)) addr_errs = addr_errs + 1;
    end

    initial begin
        repeat (10) @(posedge vin_clk);
        rstn = 1;
        drive_frame;
        drive_frame;

        repeat (`LCD_WAIT) @(posedge lcd_clk);
        begin : scan_mem
            integer j, x0, x1;
            x0 = 0; x1 = 0;
            for (j = 0; j < 20'hB400; j = j + 1) if ((^ddr.mem[20'h80000 + j]) === 1'bx) x0 = x0 + 1;
            for (j = 0; j < 20'hB400; j = j + 1) if ((^ddr.mem[j]) === 1'bx) x1 = x1 + 1;
            $display("VIDEO_ARB: bank0_x=%0d/46144 bank1_x=%0d/46144", x0, x1);
        end
        $display("VIDEO_ARB: ar_hold=%b m_arvalid=%b m_arready=%b qcnt=%0d b_out=%0d v_out=%0d rbusy=%b q_wr=%0d q_rd=%0d",
                 arb.ar_hold, m_arvalid, m_arready, ddr.q_cnt, arb.b_out, arb.v_out,
                 ddr.rbusy, ddr.q_wr, ddr.q_rd);
        $display("VIDEO_ARB: v_ar=%0d v_rlast=%0d v_rbeats=%0d | b_ar=%0d b_rlast=%0d",
                 v_ar_cnt, v_rl_cnt, v_rd_cnt, b_ar_cnt, b_rl_cnt);
        $display("VIDEO_ARB: checked_px=%0d frames=%0d lcd_errs=%0d bridge_errs=%0d bridge_done=%0d addr_errs=%0d v_wlast=%0d frame_toggles=%0d",
                 nchk, vs_cnt, errs, b_errs, b_done, addr_errs, v_wl_cnt, ft_cnt);
        if (errs == 0 && b_errs == 0 && b_done == 1 && addr_errs == 0 && nchk > 500000)
            $display("VIDEO_ARB: PASS");
        else begin
            $display("VIDEO_ARB: FAIL lcd=%0d bridge=%0d done=%0d addr=%0d px=%0d",
                     errs, b_errs, b_done, addr_errs, nchk);
            $fatal;
        end
        $finish;
    end
endmodule
