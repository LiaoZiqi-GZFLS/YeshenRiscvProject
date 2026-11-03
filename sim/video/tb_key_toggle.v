//=============================================================================
// tb_key_toggle: KEY 电平消抖 + 单次脉冲（U6）
//   ① 抖动 100 拍不触发；② 稳定按满 CNT_MAX 拍恰好 1 个脉冲；
//   ③ 一直按住不再发第二个；④ 松开再按可再触发
//=============================================================================
`timescale 1ns/1ps
module tb_key_toggle;
    localparam integer CNT_MAX = 20;

    reg clk = 0, rstn = 0, key_n = 1;
    wire pulse;
    always #5.0 clk = ~clk;

    key_toggle #(.CNT_MAX(CNT_MAX)) dut (
        .clk(clk), .rstn(rstn), .key_n(key_n), .pulse(pulse)
    );

    integer errs = 0, npulse = 0;
    always @(posedge clk) if (pulse) npulse = npulse + 1;
    task chk(input cond, input [255:0] msg);
        begin if (!cond) begin $display("TBFAIL %0s", msg); errs = errs + 1; end end
    endtask

    integer i;
    initial begin
        repeat (3) @(posedge clk); rstn = 1;
        // ① 抖动：反复按 1~2 拍
        for (i = 0; i < 6; i = i + 1) begin
            key_n = 0; repeat (2) @(posedge clk);
            key_n = 1; repeat (2) @(posedge clk);
        end
        chk(npulse == 0, "抖动期间不应触发");

        // ② 稳定按住
        key_n = 0;
        repeat (CNT_MAX + 5) @(posedge clk);
        chk(npulse == 1, "按住满阈值后应恰好 1 个脉冲");

        // ③ 继续按住
        repeat (CNT_MAX * 3) @(posedge clk);
        chk(npulse == 1, "一直按住不应重复触发");

        // ④ 松开再按
        key_n = 1; repeat (5) @(posedge clk);
        key_n = 0; repeat (CNT_MAX + 5) @(posedge clk);
        chk(npulse == 2, "松开再按应再触发一次");

        if (errs == 0) $display("RESULT: PASS");
        else $display("RESULT: FAIL errs=%0d", errs);
        $finish;
    end
endmodule
