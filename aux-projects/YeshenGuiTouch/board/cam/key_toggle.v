//=============================================================================
// key_toggle: 按键电平消抖 + 单次脉冲（soc_clk 域）
//
// ★ 必须按**电平持续计数**，不能只在"刚变低"那一拍计数：
//   早期版本用 `k2_sync == 2'b10` 触发计数，下一拍电平变 2'b00 就清零，
//   计数器永远到不了阈值 ⇒ 按键完全无效（cam2lcd_200mini 踩过）。
//=============================================================================
module key_toggle #(
    parameter integer CNT_W   = 21,
    parameter [CNT_W-1:0] CNT_MAX = 21'd1_900_000   // 19 ms @100 MHz
)(
    input  wire clk,
    input  wire rstn,
    input  wire key_n,     // 低有效
    output reg  pulse      // 单拍脉冲
);
    reg k1, k2;
    reg [CNT_W-1:0] cnt;
    reg fired;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            k1 <= 1'b1; k2 <= 1'b1; cnt <= {CNT_W{1'b0}}; fired <= 1'b0; pulse <= 1'b0;
        end else begin
            k1 <= key_n;
            k2 <= k1;
            pulse <= 1'b0;
            if (!k2) begin
                if (!fired) begin
                    if (cnt == CNT_MAX) begin
                        pulse <= 1'b1;
                        fired <= 1'b1;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end
            end else begin
                cnt   <= {CNT_W{1'b0}};
                fired <= 1'b0;
            end
        end
    end
endmodule
