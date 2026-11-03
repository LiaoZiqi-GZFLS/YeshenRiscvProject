//=============================================================================
// tb_cam_switch: cam_switch 的独立闸门（U5）
//   ★ 2026-10-30：改成"**两路相机与两套前端常开**"，不再有 en0/en1。
//   依据（上板 A/B）：`cmos_8_16bit` 的 `pdata_i/de_i/vs_i` 必须直连引脚、且
//   `GTP_CLKBUFGMUX` 换源要等**两个**输入钟各自的沿 ⇒ 任一路 pixel_clk 停了，
//   SEL 永远换不过去。所以"未选中就整颗复位"这条必须在结构上取消。
//
//   本模块现在只做：sel 同步 / pixel_clk 无毛刺 mux / 掐写 wr_ok / 事件驱动黑屏。
//   TB 验这五件事：
//   ① pixel_clk 换源时不出窄脉冲（最小脉宽 >= 9 ns，含相位扫描段）
//   ② **切换不复位任何一路**：rstn0/rstn1 全程只跟各自 init_done
//   ③ 换源门槛：目标 init_done 没到 / 目标 pixel_clk 不翻 ⇒ **不许换源**（守卫）
//   ④ 掐写：切换期 wr_ok=0，直到稳态且过第一个 frame_sof
//   ⑤ 黑屏：切换期 black=1，直到 ready ∧ frames_ok ∧ settle 到
//=============================================================================
`timescale 1ns/1ps
module tb_cam_switch;
    localparam integer SW_RST_CYC  = 20;   // 仿真缩放（真实 100000）
    localparam integer SETTLE_CYC  = 200;  // 仿真缩放（真实 40000000）
    localparam integer FRAMES_NEED = 2;
    localparam integer ALIVE_EDGES = 8;    // 仿真缩放（真实 32）

    reg clk0 = 0, clk1 = 0, soc_clk = 0, ddr_clk = 0, lcd_clk = 0;
    always #10.0   clk0    = ~clk0;     // 50 MHz
    always #13.33  clk1    = ~clk1;     // 37.5 MHz（与 clk0 非整数比）
    always #5.0    soc_clk = ~soc_clk;  // 100 MHz
    always #4.0    ddr_clk = ~ddr_clk;  // 125 MHz
    always #9.63   lcd_clk = ~lcd_clk;  // 51.9 MHz

    reg soc_rstn = 0, lcd_rstn = 0, ddr_rstn = 0;

    // ---- 相机模型（常开）：两路 pixel_clk 一直跑；init_done 由 TB 按"配置完成"拉起 ----
    //   `pix_dead1` 用来模拟"目标相机掉线/没插"（pixel_clk 不翻）——
    //   换源守卫必须因此拒绝换源，而不是把写域切到一个停摆的钟上。
    reg pix_clk0 = 0, pix_clk1 = 0;
    reg pix_dead1 = 0;
    always @(posedge clk0) pix_clk0 <= ~pix_clk0;
    always @(posedge clk1) if (!pix_dead1) pix_clk1 <= ~pix_clk1;

    reg init_done_0 = 0, init_done_1 = 0;

    reg sel = 0;
    reg frame_sof = 0, frame_start = 0;

    wire ready, switch_busy, rstn0, rstn1, pix_clk, wr_ok, black;

    cam_switch #(
        .SW_RST_CYC(SW_RST_CYC), .SETTLE_CYC(SETTLE_CYC),
        .FRAMES_NEED(FRAMES_NEED), .ALIVE_EDGES(ALIVE_EDGES)
    ) dut (
        .clk0(clk0), .clk1(clk1),
        .pix_clk0(pix_clk0), .pix_clk1(pix_clk1),
        .init_done_0(init_done_0), .init_done_1(init_done_1),
        .soc_clk(soc_clk), .soc_rstn(soc_rstn), .sel(sel),
        .ready(ready), .switch_busy(switch_busy),
        .rstn0(rstn0), .rstn1(rstn1),
        .pix_clk(pix_clk),
        .frame_sof(frame_sof), .wr_ok(wr_ok),
        .ddr_clk(ddr_clk), .ddr_rstn(ddr_rstn), .frame_start(frame_start),
        .lcd_clk(lcd_clk), .lcd_rstn(lcd_rstn), .black(black)
    );

    // ---- 毛刺监控：pix_clk 的高/低脉宽最小值 ----
    realtime t_rise = 0, t_fall = 0;
    realtime min_hi = 1.0e9, min_lo = 1.0e9;
    always @(posedge pix_clk) begin t_rise = $realtime; if (t_fall > 0) begin
        if (($realtime - t_fall) < min_lo) min_lo = $realtime - t_fall; end end
    always @(negedge pix_clk) begin t_fall = $realtime; if (t_rise > 0) begin
        if (($realtime - t_rise) < min_hi) min_hi = $realtime - t_rise; end end

    // ---- "切换期间任何一路被复位" 计数器：必须恒 0 ----
    integer rst_drops = 0;
    reg rstn0_d = 1'b0, rstn1_d = 1'b0;
    always @(posedge soc_clk) begin
        rstn0_d <= rstn0; rstn1_d <= rstn1;
        if (rstn0_d === 1'b1 && rstn0 === 1'b0) rst_drops = rst_drops + 1;
        if (rstn1_d === 1'b1 && rstn1 === 1'b0) rst_drops = rst_drops + 1;
    end

    integer errs = 0;
    task chk(input cond, input [255:0] msg);
        begin if (!cond) begin $display("TBFAIL %0s", msg); errs = errs + 1; end end
    endtask

    // 持续造帧：pix_clk 域一个 sof，ddr 域一个 frame_start
    reg run_frames = 1;
    initial begin
        forever begin
            if (run_frames) begin
                @(posedge pix_clk); frame_sof <= 1'b1;
                @(posedge pix_clk); frame_sof <= 1'b0;
                repeat (3) @(posedge ddr_clk); frame_start <= 1'b1;
                @(posedge ddr_clk); frame_start <= 1'b0;
                repeat (5) @(posedge lcd_clk);
            end else @(posedge soc_clk);
        end
    end

    integer i;
    initial begin
        repeat (4) @(posedge soc_clk);
        soc_rstn = 1; lcd_rstn = 1; ddr_rstn = 1;
        // CAM0 先配置完；CAM1 还没配（模拟上电时第二路 init 慢）
        init_done_0 = 1'b1;

        // ---- ② 上电稳态：CAM0 出图；CAM1 未配好 ⇒ rstn1=0，但它的 pixel_clk 仍在跑 ----
        repeat (SETTLE_CYC + 400) @(posedge soc_clk);
        chk(rstn0 === 1'b1, "CAM0 init_done 后 rstn0 应为 1");
        chk(rstn1 === 1'b0, "CAM1 未 init_done 时 rstn1 应为 0");
        chk(pix_clk === pix_clk0, "稳态时 pix_clk 应来自 CAM0");
        chk(black === 1'b0, "上电后 black 未在 ready+frames+settle 后放行");
        chk(wr_ok === 1'b1, "上电后 wr_ok 未恢复");

        // ---- ③ 守卫（a）：目标还没 init_done ⇒ 不许换源 ----
        @(posedge soc_clk); sel = 1;
        repeat (SETTLE_CYC + 400) @(posedge soc_clk);
        chk(black === 1'b1, "切到未就绪的 CAM1 后 black 应保持 1");
        chk(wr_ok === 1'b0, "切到未就绪的 CAM1 后 wr_ok 应为 0（掐写）");
        chk(pix_clk === pix_clk0, "目标 init_done=0 时**不许**换源");
        chk(rstn0 === 1'b1, "切换过程不得复位 CAM0");

        // ---- ③ 守卫（b）：目标 init_done=1 但 pixel_clk 停摆（掉线）⇒ 仍不许换源 ----
        pix_dead1 = 1'b1; init_done_1 = 1'b1;
        repeat (SETTLE_CYC + 400) @(posedge soc_clk);
        chk(pix_clk === pix_clk0, "目标 pixel_clk 不翻时**不许**换源（掉线守卫）");
        chk(rstn1 === 1'b1, "CAM1 init_done 后 rstn1 应为 1");
        chk(rstn0 === 1'b1, "切换过程不得复位 CAM0");

        // ---- 目标钟恢复 ⇒ 换源 ----
        pix_dead1 = 1'b0;
        repeat (SETTLE_CYC + 400) @(posedge soc_clk);
        chk(pix_clk === pix_clk1, "目标钟恢复后应换源到 CAM1");
        chk(black === 1'b0, "切到 CAM1 后 black 未放行");
        chk(wr_ok === 1'b1, "切到 CAM1 后 wr_ok 未恢复");

        // ---- 切回 CAM0：两路都常开，换源应立即发生，且不得复位任何一路 ----
        @(posedge soc_clk); sel = 0;
        repeat (8) @(posedge soc_clk);
        chk(black === 1'b1, "切回后 black 未立即拉高");
        chk(wr_ok === 1'b0, "切回期 wr_ok 应为 0（掐写）");
        repeat (SETTLE_CYC + 400) @(posedge soc_clk);
        chk(pix_clk === pix_clk0, "切回后 pix_clk 应来自 CAM0");
        chk(black === 1'b0, "切回 CAM0 后 black 未放行");
        chk(wr_ok === 1'b1, "切回 CAM0 后 wr_ok 未恢复");

        // ---- ② 全程没有哪一路被切换复位过 ----
        chk(rst_drops == 0, "切换过程把某一路 cmos 复位了（会停 pixel_clk ⇒ 换源死锁）");
        chk(rstn0 === 1'b1 && rstn1 === 1'b1, "两路都 init_done 后 rstn0/rstn1 应恒 1");

        // ---- ① 相位扫描：在多种相位上反复换源 ----
        //   正常设计（硬宏握手）永远不出窄脉冲；U5 负对照（裸 mux）会在这里被抓到。
        for (i = 0; i < 24; i = i + 1) begin
            #(377.0 + i * 211.0);
            sel = ~sel;
        end

        // 毛刺判据（最后查，覆盖整段运行）
        chk(min_hi > 9.0, "pix_clk 出现窄高脉冲（毛刺）");
        chk(min_lo > 9.0, "pix_clk 出现窄低脉冲（毛刺）");

        if (errs == 0) $display("RESULT: PASS");
        else $display("RESULT: FAIL errs=%0d", errs);
        $finish;
    end

    initial begin
        #30000000;
        $display("TBFAIL 超时");
        $display("RESULT: FAIL");
        $finish;
    end
endmodule
