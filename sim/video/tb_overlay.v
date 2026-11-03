//=============================================================================
// tb_overlay: U3 闸门 —— 16 框 2 px 边框叠加引擎（单时钟、无 AxiLite）
//
// 检查项：
//   1) box0 = (100,100)-(199,199)，commit -> vsync 切换 bank
//   2) 4 条边各取点 -> 0x07E0
//   3) 框内非边框（含贴边的内圈 102/197）-> 原值 0x1234
//   4) 框外 -> 原值
//   5) ovl_en=0 旁路 -> 原值
//   6) 无 commit 的第二个 vsync 不切 bank（框仍在）
//   7) 双 bank：新一组 box 写 shadow bank + commit -> 旧框消失、新框出现
//
// 先红后绿（负对照）：把 overlay.v 里边框厚度 16'd2 改成 16'd3，
//   第 3 组内圈点 (102,150)/(197,150)/(150,102)/(150,197) 会误判为边框
//   => OVERLAY: FAIL；还原后 => OVERLAY: PASS。
//
// 注：commit 跨到 lcd 域要 3FF + 挂起位，故 commit 后等 8 拍再打 vsync
//     （计划原文 commit 与 vsync 只隔 1 拍，CDC 没走完，bank 切不过去）。
//=============================================================================
`timescale 1ns/1ps

module tb_overlay;
    reg clk = 0, rstn = 0;
    always #9.6295 clk = ~clk;            // 51.923 MHz（lcd_clk）

    reg [10:0] x = 0;
    reg [9:0]  y = 0;
    reg        de = 1;
    reg [15:0] pin = 16'h1234;
    wire [15:0] pout;
    reg vsync = 0, hs = 0;
    reg wr_en = 0, commit = 0, en = 1;
    reg [4:0]  wa = 0;
    reg [31:0] wd = 0;
    reg [7:0]  cnt = 1;
    wire ab;

    overlay dut (
        .lcd_clk(clk), .lcd_rstn(rstn),
        .pix_x(x), .pix_y(y), .pix_de(de), .pix_in(pin), .pix_out(pout),
        .vsync(vsync), .hs(hs),
        .wr_clk(clk), .wr_rstn(rstn),
        .wr_en(wr_en), .wr_addr(wa), .wr_data(wd),
        .commit(commit), .ovl_en(en), .ovl_count(cnt),
        .active_bank(ab)
    );

    //-------------------------------------------------------------------------
    // 激励任务（negedge 驱动，避开 DUT posedge 采样竞争）
    //-------------------------------------------------------------------------
    task wr(input [4:0] a, input [31:0] d);
        begin
            @(negedge clk); wr_en = 1; wa = a; wd = d;
            @(negedge clk); wr_en = 0;
        end
    endtask

    task do_commit;
        begin
            @(negedge clk); commit = 1;
            @(negedge clk); commit = 0;
            repeat (8) @(posedge clk);        // commit toggle -> lcd 域 3FF + 挂起
        end
    endtask

    task pulse_vs;
        begin
            @(negedge clk); vsync = 1;
            @(negedge clk); vsync = 0;
            @(posedge clk);                   // vs_rise 已在 lcd 域看到
        end
    endtask

    task pulse_hs;
        begin
            @(negedge clk); hs = 1;
            @(negedge clk); hs = 0;
        end
    endtask

    task prefetch;                            // hs 上升沿 + 等 32 拍预取 + 拆表
        begin
            pulse_hs;
            repeat (60) @(posedge clk);
        end
    endtask

    //-------------------------------------------------------------------------
    // 单点检查
    //-------------------------------------------------------------------------
    integer errs = 0;
    task chk(input [10:0] xx, input [9:0] yy, input [15:0] exp, input [127:0] tag);
        reg [15:0] o;
        begin
            x = xx; y = yy; de = 1; #1 o = pout;
            if (o !== exp) begin
                errs = errs + 1;
                $display("OVERLAY: MISMATCH %0s at (%0d,%0d) got=%04x exp=%04x",
                         tag, xx, yy, o, exp);
            end
        end
    endtask

    localparam [15:0] GRN = 16'h07E0;
    localparam [15:0] RAW = 16'h1234;

    initial begin
        repeat (5) @(posedge clk);
        rstn = 1;
        repeat (2) @(posedge clk);

        // ---- 1) box0 = (100,100)-(199,199) 写入 shadow bank，commit 切换 ----
        wr(5'd0, {16'd100, 16'd100});
        wr(5'd1, {16'd199, 16'd199});
        do_commit;
        pulse_vs;
        prefetch;
        if (ab !== 1'b1) begin
            errs = errs + 1;
            $display("OVERLAY: MISMATCH bank not switched (ab=%0b exp=1)", ab);
        end

        // ---- 2) 四条边（2 px 边框） ----
        chk(11'd100, 10'd150, GRN, "left  ");
        chk(11'd199, 10'd150, GRN, "right ");
        chk(11'd150, 10'd100, GRN, "top   ");
        chk(11'd150, 10'd199, GRN, "bottom");

        // ---- 3) 框内非边框：心部 + 紧贴边框的内圈（2 px 边界之外） ----
        chk(11'd150, 10'd150, RAW, "center");
        chk(11'd102, 10'd150, RAW, "innerL");
        chk(11'd197, 10'd150, RAW, "innerR");
        chk(11'd150, 10'd102, RAW, "innerT");
        chk(11'd150, 10'd197, RAW, "innerB");

        // ---- 4) 框外 ----
        chk(11'd99,  10'd150, RAW, "outL  ");
        chk(11'd200, 10'd150, RAW, "outR  ");
        chk(11'd150, 10'd99,  RAW, "outT  ");
        chk(11'd150, 10'd200, RAW, "outB  ");

        // ---- 5) ovl_en=0 旁路 ----
        en = 0;
        chk(11'd100, 10'd150, RAW, "bypass");
        en = 1;

        // ---- 6) 没有 commit 的 vsync 不切 bank（框仍在） ----
        pulse_vs;
        prefetch;
        if (ab !== 1'b1) begin
            errs = errs + 1;
            $display("OVERLAY: MISMATCH bank flipped without commit (ab=%0b)", ab);
        end
        chk(11'd100, 10'd150, GRN, "keep  ");

        // ---- 7) 双 bank：新 box0 写 shadow bank，commit 后旧框消失 ----
        wr(5'd0, {16'd200, 16'd300});
        wr(5'd1, {16'd299, 16'd399});
        do_commit;
        pulse_vs;
        prefetch;
        if (ab !== 1'b0) begin
            errs = errs + 1;
            $display("OVERLAY: MISMATCH second swap (ab=%0b exp=0)", ab);
        end
        chk(11'd200, 10'd350, GRN, "newL  ");
        chk(11'd299, 10'd350, GRN, "newR  ");
        chk(11'd250, 10'd300, GRN, "newT  ");
        chk(11'd250, 10'd399, GRN, "newB  ");
        chk(11'd250, 10'd350, RAW, "newIn ");
        chk(11'd100, 10'd150, RAW, "oldGone");

        if (errs == 0) $display("OVERLAY: PASS");
        else begin
            $display("OVERLAY: FAIL errs=%0d", errs);
            $fatal;
        end
        $finish;
    end
endmodule
