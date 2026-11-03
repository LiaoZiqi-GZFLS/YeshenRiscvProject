//=============================================================================
// tb_rst_ctrl: U7 闸门 —— 软件软复位控制器（rst_ctrl）
//
// 只验三件事，但都要能翻红：
//   ① 无请求时 sys_rstn 恒 1（上电不得把 SoC 扣住）
//   ② 一个请求 → 恰好一次复位，低电平宽度 = HOLD_CYC 个 clk（±1 拍）
//   ③ **请求挂住不放时只复位一次**（不自激）—— 这是"无限重启环"的守卫
// 另外验：请求回落后能重新武装（第二次请求仍然生效）。
//
// 负对照（run_video_gates.sh 里 sed 掉 `&& !req_ack`）：
//   挂住不放那一条必须翻红（会反复复位）。
//=============================================================================
`timescale 1ns/1ps

module tb_rst_ctrl;
    localparam integer HOLD = 20;          // 仿真缩放（真实 540000 = 20 ms @27 MHz）

    reg clk = 0;
    always #18.518 clk = ~clk;             // 27 MHz

    reg  req = 0;
    wire rsn;

    rst_ctrl #(.HOLD_CYC(HOLD)) dut (
        .clk(clk), .rst_req(req), .sys_rstn(rsn)
    );

    // ---- 复位窗统计：次数 + 每次的低电平宽度（拍）----
    integer    n_fall = 0, n_rise = 0;
    integer    cyc_low = 0;
    integer    w_min = 1 << 30, w_max = 0;
    // ⚠️ 上升沿只在**出现过下降沿之后**才计数：`hold` 没有复位端，t=0 时它从 X 落到 0
    //    会让 rsn 出现一次 X→1，不设这个门就会凭空多算一次复位窗。
    always @(negedge rsn) begin n_fall = n_fall + 1; cyc_low = 0; end
    always @(posedge clk) if (!rsn) cyc_low = cyc_low + 1;
    always @(posedge rsn) if (n_fall > 0) begin
        n_rise = n_rise + 1;
        if (cyc_low < w_min) w_min = cyc_low;
        if (cyc_low > w_max) w_max = cyc_low;
    end

    integer errs = 0;
    task chk(input cond, input [255:0] msg);
        begin if (!cond) begin $display("TBFAIL %0s", msg); errs = errs + 1; end end
    endtask

    integer i;
    initial begin
        // ---- ① 上电：无请求，不得扣复位 ----
        repeat (60) @(posedge clk);
        chk(rsn === 1'b1, "上电无请求时 sys_rstn 应为 1");
        chk(n_fall == 0,  "上电后不应出现复位窗");

        // ---- ② 一次请求 = 一次复位，宽度 = HOLD ----
        @(negedge clk); req = 1'b1;
        repeat (2) @(negedge clk); req = 1'b0;
        wait (n_rise >= 1);
        repeat (4) @(posedge clk);
        chk(n_fall == 1, "一次请求应恰好产生一次复位");
        // 计数在 posedge 上读 rsn 的**旧值**，与 DUT 的 NBA 差一拍 ⇒ 容忍 ±2
        chk(w_min >= HOLD - 1 && w_max <= HOLD + 2,
            "复位窗宽度应 ≈ HOLD_CYC 拍");
        chk(rsn === 1'b1, "复位窗结束后 sys_rstn 应回到 1");

        // ---- ③ 请求回落后重新武装：第二次请求必须再生效 ----
        @(negedge clk); req = 1'b1;
        repeat (2) @(negedge clk); req = 1'b0;
        wait (n_rise >= 2);
        repeat (4) @(posedge clk);
        chk(n_fall == 2, "请求回落后的第二次请求应再次复位");
        chk(rsn === 1'b1, "第二次复位窗结束后 sys_rstn 应回到 1");

        // ---- ④ 请求挂住不放：只复位一次（不自激）----
        //   模拟"源寄存器没被复位清掉"的病态输入。正确实现：req_ack 咬住 ⇒ 不再触发。
        @(negedge clk); req = 1'b1;
        wait (n_rise >= 3);
        repeat (6 * HOLD + 40) @(posedge clk);   // 足够跑出好几轮复位窗
        chk(n_fall == 3, "请求挂住不放时**不得**反复复位（否则无限重启环）");
        chk(rsn === 1'b1, "挂住请求时 sys_rstn 应停在 1");
        @(negedge clk); req = 1'b0;
        repeat (10) @(posedge clk);

        // ---- ⑤ 撤销挂住后再请求：仍能复位（重新武装没被卡死）----
        @(negedge clk); req = 1'b1;
        wait (n_rise >= 4);
        repeat (4) @(posedge clk);
        chk(n_fall == 4, "长时间挂住后撤销，再请求应仍能复位");
        @(negedge clk); req = 1'b0;
        repeat (10) @(posedge clk);
        chk(rsn === 1'b1, "收尾应为运行态");

        $display("RST_CTRL: falls=%0d rises=%0d width=[%0d,%0d] HOLD=%0d",
                 n_fall, n_rise, w_min, w_max, HOLD);
        if (errs == 0) $display("RESULT: PASS");
        else           $display("RESULT: FAIL errs=%0d", errs);
        $finish;
    end

    initial begin
        #200000;
        $display("TBFAIL 超时");
        $display("RESULT: FAIL");
        $finish;
    end
endmodule
