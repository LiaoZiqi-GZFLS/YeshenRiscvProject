//=============================================================================
// tb_video_regs: U4 闸门 —— VIDEO 1 KiB CSR 窗（video_regs）单时钟 100 MHz
//
// 检查项：
//   1) 复位值：STATUS/CTRL/DBG 全 0（VERSION 为常量 0x0001_0001）
//   2) CTRL 写 0x0000_2103（en=1, count=0x21, commit=1）：
//      ovl_en=1、ovl_count=0x21、ovl_commit 恰好一拍；读回 = 0x0000_2101
//      （注：计划原文写 0x2101，但按映射 [1]=commit，0x2101 的 bit1=0，
//        触发不了 commit；故写 0x2103，en/count 位段与原文一致。
//        commit 是写触发位、不存储，读回自然为 0x2101）
//   3) VERSION 读回 0x0001_0001
//   4) frame_toggle 翻转 3 次（间隔 ≥4 拍）-> STATUS[31:8]=3；
//      wr_bank=1 -> STATUS[1]=1；init_done=1 -> STATUS[0]=1
//   5) BOX2 word0（0x020）写 {16'd10,16'd20}：ovl_wr_en 恰好一拍、
//      ovl_wr_addr=4（box2 word0）、ovl_wr_data 正确；读回等于写入值。
//      边界 0x088（box15 word0 -> addr=30）同口径（覆盖 0x080 段回绕）
//   6) DBG：vid_stall=0x1234 经 2FF -> 读回 0x0000_1234
//   7) CAM_CTRL（0x00C）：复位 sel=0；写 1 后 sel=1；
//      ready/busy 跟随 cam_rdy/cam_busy；按键单拍翻转 sel
//   8) RST_CTRL（0x098）：写 1 → rst_req=1；写 0 可撤销；
//      **rstn 压低后 rst_req 必须归 0**（reboot 不自锁的寄存器级证明）
//
// 负对照：把 EXP_CNT 改成 8'h22（见 localparam 锚点），CTRL 读回必 FAIL。
//=============================================================================
`timescale 1ns/1ps

module tb_video_regs;
    reg clk = 0, rstn = 0;
    always #5 clk = ~clk;                     // 100 MHz

    // AXI4-Lite 从口
    reg  [11:0] awaddr = 0, araddr = 0;
    reg         awvalid = 0, wvalid = 0, arvalid = 0;
    reg         bready = 1, rready = 1;
    reg  [31:0] wdata = 0;
    reg  [3:0]  wstrb = 4'hF;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [31:0] rdata;
    wire [1:0]  bresp, rresp;

    // 异步帧状态 / 视频计数器
    reg         ftoggle = 0;
    reg         wb = 0;
    reg         idone = 0;
    reg  [15:0] stall = 0;

    // 相机切换（soc_clk）
    reg         cam_tgl = 0, cam_rdy = 0, cam_busy = 0;
    wire        cam_sel_o;

    // overlay 写口
    wire        wr_en, commit, oen;
    wire [4:0]  wa;
    wire [31:0] wd;
    wire [7:0]  cnt;

    // 软复位请求（RST_CTRL[0]）
    wire        rst_req;

    // 读源选择（GUI_CTRL[0]）与 GUI 帧存 bank（GUI_CTRL[1]）
    wire        gui_src;
    wire        gui_bank;

    video_regs dut (
        .clk(clk), .rstn(rstn),
        .s_awaddr(awaddr), .s_awvalid(awvalid), .s_awready(awready),
        .s_wdata(wdata), .s_wstrb(wstrb), .s_wvalid(wvalid), .s_wready(wready),
        .s_bvalid(bvalid), .s_bready(bready), .s_bresp(bresp),
        .s_araddr(araddr), .s_arvalid(arvalid), .s_arready(arready),
        .s_rdata(rdata), .s_rvalid(rvalid), .s_rready(rready), .s_rresp(rresp),
        .frame_toggle(ftoggle), .wr_bank(wb), .init_done(idone), .vid_stall(stall),
        .cam_sel_toggle(cam_tgl), .cam_rdy(cam_rdy), .cam_busy(cam_busy), .cam_sel(cam_sel_o),
        .ovl_wr_en(wr_en), .ovl_wr_addr(wa), .ovl_wr_data(wd),
        .ovl_commit(commit), .ovl_en(oen), .ovl_count(cnt),
        .rst_req(rst_req),
        .gui_src(gui_src),
        .gui_bank(gui_bank)
    );

    //-------------------------------------------------------------------------
    // 脉冲监视：commit / box 写各应恰好一拍
    //-------------------------------------------------------------------------
    integer    commit_pulses = 0;
    integer    box_pulses = 0;
    reg [4:0]  cap_addr = 0;
    reg [31:0] cap_data = 0;
    always @(posedge clk) begin
        if (commit) commit_pulses <= commit_pulses + 1;
        if (wr_en) begin
            box_pulses <= box_pulses + 1;
            cap_addr   <= wa;
            cap_data   <= wd;
        end
    end

    //-------------------------------------------------------------------------
    // AXI4-Lite 主：negedge 驱动，避开 DUT posedge 采样竞争
    //-------------------------------------------------------------------------
    task axi_wr(input [11:0] a, input [31:0] d);
        begin
            @(negedge clk);
            awaddr = a; wdata = d; awvalid = 1; wvalid = 1;
            @(posedge clk);                    // 空闲时 awready/wready 同拍为 1
            @(negedge clk);
            awvalid = 0; wvalid = 0;
            while (!bvalid) @(negedge clk);
            @(negedge clk);                    // 等 bvalid 被 bready 清掉
        end
    endtask

    task axi_rd(input [11:0] a, output [31:0] d);
        begin
            @(negedge clk);
            araddr = a; arvalid = 1;
            @(posedge clk);                    // ar 握手
            @(negedge clk);
            arvalid = 0;
            while (!rvalid) @(negedge clk);
            d = rdata;
            @(negedge clk);                    // 等 rvalid 被 rready 清掉
        end
    endtask

    integer errs = 0;
    task fail(input [255:0] msg);
        begin
            errs = errs + 1;
            $display("VIDEO_REGS: MISMATCH %0s", msg);
        end
    endtask

    localparam [7:0] EXP_CNT = 8'h21;          // 负对照锚点：改成 8'h22 必 FAIL

    reg [31:0] d;
    initial begin
        repeat (5) @(posedge clk);
        rstn = 1;
        repeat (2) @(posedge clk);

        // ---- 1) 复位值 ----
        axi_rd(12'h000, d);
        if (d !== 32'h0000_0000) begin
            errs = errs + 1;
            $display("VIDEO_REGS: MISMATCH STATUS reset got=%08x exp=00000000", d);
        end
        axi_rd(12'h008, d);
        if (d !== 32'h0000_0000) begin
            errs = errs + 1;
            $display("VIDEO_REGS: MISMATCH CTRL reset got=%08x exp=00000000", d);
        end

        // ---- 2) CTRL = en + count=0x21 + commit ----
        axi_wr(12'h008, 32'h0000_2103);
        if (oen !== 1'b1) begin
            errs = errs + 1;
            $display("VIDEO_REGS: MISMATCH ovl_en got=%0b exp=1", oen);
        end
        if (cnt !== EXP_CNT) begin
            errs = errs + 1;
            $display("VIDEO_REGS: MISMATCH ovl_count got=%02x exp=%02x", cnt, EXP_CNT);
        end
        if (commit_pulses !== 1) begin
            errs = errs + 1;
            $display("VIDEO_REGS: MISMATCH ovl_commit pulses=%0d exp=1", commit_pulses);
        end
        if (commit !== 1'b0 || wr_en !== 1'b0) begin
            errs = errs + 1;
            $display("VIDEO_REGS: MISMATCH CTRL write left commit=%0b wr_en=%0b", commit, wr_en);
        end

        axi_rd(12'h008, d);
        if (d !== 32'h0000_2101) begin
            errs = errs + 1;
            $display("VIDEO_REGS: MISMATCH CTRL readback got=%08x exp=00002101", d);
        end

        // ---- 3) VERSION ----
        axi_rd(12'h090, d);
        if (d !== 32'h0001_0001) begin
            errs = errs + 1;
            $display("VIDEO_REGS: MISMATCH VERSION got=%08x exp=00010001", d);
        end

        // ---- 4) 帧事件 3 次（wr_bank=1, init_done=1） ----
        wb = 1; idone = 1;
        repeat (3) @(posedge clk);
        repeat (3) begin
            @(negedge clk); ftoggle = ~ftoggle;
            repeat (6) @(posedge clk);         // 2FF + 边沿拍，留足 ≥4 拍
        end
        repeat (2) @(posedge clk);             // seq 落地
        axi_rd(12'h000, d);
        if (d[31:8] !== 24'd3) begin
            errs = errs + 1;
            $display("VIDEO_REGS: MISMATCH STATUS seq got=%0d exp=3", d[31:8]);
        end
        if (d[1] !== 1'b1) begin
            errs = errs + 1;
            $display("VIDEO_REGS: MISMATCH STATUS wr_bank got=%0b exp=1", d[1]);
        end
        if (d[0] !== 1'b1) begin
            errs = errs + 1;
            $display("VIDEO_REGS: MISMATCH STATUS init_done got=%0b exp=1", d[0]);
        end
        if (d[7:2] !== 6'd0) begin
            errs = errs + 1;
            $display("VIDEO_REGS: MISMATCH STATUS reserved got=%02x exp=00", d[7:2]);
        end

        // ---- 5) BOX2 word0（0x020）= {x1=10, y1=20} ----
        axi_wr(12'h020, {16'd10, 16'd20});
        if (box_pulses !== 1) begin
            errs = errs + 1;
            $display("VIDEO_REGS: MISMATCH box wr pulses=%0d exp=1", box_pulses);
        end
        if (cap_addr !== 5'd4) begin
            errs = errs + 1;
            $display("VIDEO_REGS: MISMATCH ovl_wr_addr got=%0d exp=4 (box2 word0)", cap_addr);
        end
        if (cap_data !== 32'h000A_0014) begin
            errs = errs + 1;
            $display("VIDEO_REGS: MISMATCH ovl_wr_data got=%08x exp=000a0014", cap_data);
        end
        if (wr_en !== 1'b0) begin
            errs = errs + 1;
            $display("VIDEO_REGS: MISMATCH ovl_wr_en not a 1-cycle pulse");
        end
        axi_rd(12'h020, d);
        if (d !== 32'h000A_0014) begin
            errs = errs + 1;
            $display("VIDEO_REGS: MISMATCH BOX2 readback got=%08x exp=000a0014", d);
        end

        // 边界：0x088 -> box15 word0（addr=30），覆盖 offset[6:3] 4-bit 回绕
        axi_wr(12'h088, 32'hDEAD_BEEF);
        if (box_pulses !== 2 || cap_addr !== 5'd30) begin
            errs = errs + 1;
            $display("VIDEO_REGS: MISMATCH box15 wr pulses=%0d addr=%0d exp=2/30",
                     box_pulses, cap_addr);
        end
        axi_rd(12'h088, d);
        if (d !== 32'hDEAD_BEEF) begin
            errs = errs + 1;
            $display("VIDEO_REGS: MISMATCH BOX15 readback got=%08x exp=deadbeef", d);
        end

        // ---- 6) DBG：vid_stall 2FF ----
        @(negedge clk); stall = 16'h1234;
        repeat (3) @(posedge clk);
        axi_rd(12'h004, d);
        if (d !== 32'h0000_1234) begin
            errs = errs + 1;
            $display("VIDEO_REGS: MISMATCH DBG got=%08x exp=00001234", d);
        end

        // ---- 7) CAM_CTRL (0x00C)：RW[0] sel / RO[1] ready / RO[2] busy ----
        axi_rd(12'h00C, d);
        if (d[0] !== 1'b0) fail("CAM_CTRL 复位 sel 应为 0");
        axi_wr(12'h00C, 32'h0000_0001);
        axi_rd(12'h00C, d);
        if (d[0] !== 1'b1) fail("CAM_CTRL 写 1 后 sel 应为 1");

        cam_rdy = 1'b1; cam_busy = 1'b1;
        repeat (4) @(posedge clk);
        axi_rd(12'h00C, d);
        if (d[1] !== 1'b1) fail("CAM_CTRL.ready 未跟随 cam_rdy");
        if (d[2] !== 1'b1) fail("CAM_CTRL.busy 未跟随 cam_busy");
        cam_rdy = 1'b0; cam_busy = 1'b0;

        // 按键翻转（单拍脉冲；negedge 驱动，避开 DUT posedge 采样竞争）
        @(negedge clk); cam_tgl = 1'b1;
        @(negedge clk); cam_tgl = 1'b0;
        repeat (4) @(posedge clk);
        axi_rd(12'h00C, d);
        if (d[0] !== 1'b0) fail("按键翻转后 sel 应为 0");

        // ---- 8) RST_CTRL (0x098)：写 1 → rst_req=1；**被同一次复位清掉** ----
        //   ★ 这条是"reboot 不会自锁成无限重启环"的寄存器级证明：
        //     复位端 rstn 一低，请求位必须归 0（否则 rst_ctrl 会永远看到请求）。
        axi_rd(12'h098, d);
        if (d !== 32'h0000_0000) fail("RST_CTRL 复位值应为 0");
        axi_wr(12'h098, 32'h0000_0001);
        if (rst_req !== 1'b1) fail("RST_CTRL 写 1 后 rst_req 应为 1");
        axi_rd(12'h098, d);
        if (d !== 32'h0000_0001) fail("RST_CTRL 读回应为 1");
        // 软件可撤销（写 0）
        axi_wr(12'h098, 32'h0000_0000);
        if (rst_req !== 1'b0) fail("RST_CTRL 写 0 后 rst_req 应为 0");
        // 再置 1，然后压复位 ≥1 拍 ⇒ 必须自己归 0
        axi_wr(12'h098, 32'h0000_0001);
        if (rst_req !== 1'b1) fail("RST_CTRL 二次写 1 后 rst_req 应为 1");
        @(negedge clk); rstn = 1'b0;
        repeat (3) @(posedge clk);
        if (rst_req !== 1'b0) fail("复位后 rst_req 必须为 0（否则 reboot 自锁）");
        @(negedge clk); rstn = 1'b1;
        repeat (3) @(posedge clk);
        axi_rd(12'h098, d);
        if (d !== 32'h0000_0000) fail("复位后 RST_CTRL 读回应为 0");
        if (rst_req !== 1'b0) fail("复位释放后 rst_req 应保持 0（不得自激）");

        // ---- 9) GUI_CTRL (0x09C)：读源 bit0 + GUI 帧存 bank bit1（普通 RW，复位清 0）----
        axi_rd(12'h09C, d);
        if (d !== 32'h0000_0000) fail("GUI_CTRL 复位值应为 0");
        if (gui_src !== 1'b0)  fail("GUI_CTRL 复位后 gui_src 应为 0");
        if (gui_bank !== 1'b0) fail("GUI_CTRL 复位后 gui_bank 应为 0");
        axi_wr(12'h09C, 32'h0000_0001);
        if (gui_src !== 1'b1)  fail("GUI_CTRL 写 1 后 gui_src 应为 1");
        if (gui_bank !== 1'b0) fail("GUI_CTRL 写 1 后 gui_bank 应保持 0");
        axi_rd(12'h09C, d);
        if (d !== 32'h0000_0001) fail("GUI_CTRL 读回应为 1");
        // bit1 单独：bank=1 而读源仍=0（换 bank 不该顺带换源）
        axi_wr(12'h09C, 32'h0000_0002);
        if (gui_src !== 1'b0)  fail("GUI_CTRL 写 bit1 后 gui_src 应仍为 0");
        if (gui_bank !== 1'b1) fail("GUI_CTRL 写 bit1 后 gui_bank 应为 1");
        axi_rd(12'h09C, d);
        if (d !== 32'h0000_0002) fail("GUI_CTRL 读回应为 2（bit1）");
        // 两位同时
        axi_wr(12'h09C, 32'h0000_0003);
        axi_rd(12'h09C, d);
        if (d !== 32'h0000_0003) fail("GUI_CTRL 读回应为 3（bit1:0）");
        // 高位忽略：只有 bit[1:0] 有意义
        axi_wr(12'h09C, 32'hFFFF_FFFC);
        if (gui_src !== 1'b0)  fail("GUI_CTRL 写 bit0=0 后 gui_src 应为 0");
        if (gui_bank !== 1'b0) fail("GUI_CTRL 写 bit1=0 后 gui_bank 应为 0");
        axi_rd(12'h09C, d);
        if (d !== 32'h0000_0000) fail("GUI_CTRL 读回应只回 bit[1:0]");
        // 复位清 0
        axi_wr(12'h09C, 32'h0000_0003);
        @(negedge clk); rstn = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk); rstn = 1'b1;
        repeat (3) @(posedge clk);
        if (gui_src !== 1'b0)  fail("复位后 gui_src 必须为 0");
        if (gui_bank !== 1'b0) fail("复位后 gui_bank 必须为 0");

        if (errs == 0) $display("VIDEO_REGS: PASS");
        else begin
            $display("VIDEO_REGS: FAIL errs=%0d", errs);
            $fatal;
        end
        $finish;
    end
endmodule
