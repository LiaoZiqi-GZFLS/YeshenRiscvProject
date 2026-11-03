//=============================================================================
// overlay: 16 框 × 2 px 绿色边框叠加（双 bank box 表，vsync 原子切换）
//
// 数据流：
//   CPU(soc_clk) 写 box 表 -> shadow bank（= ~active_bank）
//   commit 脉冲 -> toggle 同步到 lcd_clk -> 在 vsync 上升沿翻转 active_bank
//   每行 hs 上升沿：32 拍把 active bank 的 32 word 预取到 bq[0:31]
//   预取完成下一拍：拆成 bx1/by1/bx2/by2 四个 16 项数组（避免变量位选择）
//   每像素：16 框组合比较，命中边框 -> 0x07E0；否则 pix_in（旁路）
//
// box 表布局（每框 2 word，屏幕坐标）：
//   word0 = {x1[15:0], y1[15:0]}   word1 = {x2[15:0], y2[15:0]}
//   wr_addr = {box[3:0], word[0]}
//   box_mem 下标 = {bank[0], wr_addr[4:0]}  -> 64 × 32 bit
//
// 边框判据（2 px，含两端）：框内且
//   (x < x1+2) || (x+2 > x2) || (y < y1+2) || (y+2 > y2)
//=============================================================================
`timescale 1ns/1ps

module overlay #(parameter MAXBOX=16)(
    input  wire        lcd_clk,
    input  wire        lcd_rstn,
    input  wire [10:0] pix_x,
    input  wire [9:0]  pix_y,
    input  wire        pix_de,
    input  wire [15:0] pix_in,
    output wire [15:0] pix_out,
    input  wire        vsync,        // VS 脉冲（上升沿用于 commit 切换）
    input  wire        hs,           // HS 脉冲（上升沿触发行首预取）
    input  wire        wr_clk,
    input  wire        wr_rstn,
    input  wire        wr_en,
    input  wire [4:0]  wr_addr,      // {box[3:0], word}
    input  wire [31:0] wr_data,
    input  wire        commit,
    input  wire        ovl_en,
    input  wire [7:0]  ovl_count,
    output reg         active_bank
);
    localparam [5:0] LD_LAST = (2*MAXBOX - 1);   // 预取最后一拍（MAXBOX=16 -> 31）

    //-------------------------------------------------------------------------
    // box 表：真双时钟（写 wr_clk / 读 lcd_clk 异步读）
    //-------------------------------------------------------------------------
    reg [31:0] box_mem [0:63];

    // 写 bank = ~active_bank（active_bank 在 lcd 域，2FF 同步到 wr_clk）
    reg ab_w1, ab_w2;
    always @(posedge wr_clk or negedge wr_rstn) begin
        if (!wr_rstn) begin
            ab_w1 <= 1'b0;
            ab_w2 <= 1'b0;
        end else begin
            ab_w1 <= active_bank;
            ab_w2 <= ab_w1;
        end
    end
    wire wr_bank = ~ab_w2;

    always @(posedge wr_clk) begin
        if (wr_en) box_mem[{wr_bank, wr_addr}] <= wr_data;
    end

    //-------------------------------------------------------------------------
    // commit：wr_clk 域 toggle -> lcd 域 3FF 边沿 -> 挂起，vsync 上升沿消费
    //   （用 toggle 而不是电平，保证一次 commit 只切一次 bank）
    //-------------------------------------------------------------------------
    reg commit_tog, commit_d;
    always @(posedge wr_clk or negedge wr_rstn) begin
        if (!wr_rstn) begin
            commit_tog <= 1'b0;
            commit_d   <= 1'b0;
        end else begin
            commit_d <= commit;
            if (commit & ~commit_d) commit_tog <= ~commit_tog;   // 只认上升沿（脉冲/电平都只切一次）
        end
    end

    reg ct1, ct2, ct3;
    always @(posedge lcd_clk or negedge lcd_rstn) begin
        if (!lcd_rstn) begin
            ct1 <= 1'b0;
            ct2 <= 1'b0;
            ct3 <= 1'b0;
        end else begin
            ct1 <= commit_tog;
            ct2 <= ct1;
            ct3 <= ct2;
        end
    end
    wire commit_ev = ct2 ^ ct3;

    reg vs_d;
    always @(posedge lcd_clk or negedge lcd_rstn) begin
        if (!lcd_rstn) vs_d <= 1'b0;
        else           vs_d <= vsync;
    end
    wire vs_rise = vsync & ~vs_d;

    reg pend;
    always @(posedge lcd_clk or negedge lcd_rstn) begin
        if (!lcd_rstn) begin
            pend        <= 1'b0;
            active_bank <= 1'b0;
        end else if (vs_rise && (pend || commit_ev)) begin
            pend        <= 1'b0;
            active_bank <= ~active_bank;
        end else if (commit_ev) begin
            pend        <= 1'b1;
        end
    end

    //-------------------------------------------------------------------------
    // 行首预取：hs 上升沿起 32 拍，把 active bank 的 32 word 读进 bq
    //-------------------------------------------------------------------------
    reg [31:0] bq [0:31];
    reg [5:0]  ld_idx;
    reg        ld_run, hs_d, ld_last_d;
    always @(posedge lcd_clk or negedge lcd_rstn) begin
        if (!lcd_rstn) begin
            ld_run    <= 1'b0;
            ld_idx    <= 6'd0;
            hs_d      <= 1'b0;
            ld_last_d <= 1'b0;
        end else begin
            hs_d      <= hs;
            ld_last_d <= ld_run && (ld_idx == LD_LAST);
            if (hs && !hs_d) begin
                ld_run <= 1'b1;
                ld_idx <= 6'd0;
            end else if (ld_run) begin
                bq[ld_idx[4:0]] <= box_mem[{active_bank, ld_idx[4:0]}];
                if (ld_idx == LD_LAST) ld_run <= 1'b0;
                else                   ld_idx <= ld_idx + 6'd1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // 预取完成（bq[31] 落地的下一拍）拆成 4 个定长数组：
    //   不用 bq[{k,1'b0}] 这类变量位选择（部分综合器不接受）
    //-------------------------------------------------------------------------
    reg [15:0] bx1 [0:MAXBOX-1];
    reg [15:0] by1 [0:MAXBOX-1];
    reg [15:0] bx2 [0:MAXBOX-1];
    reg [15:0] by2 [0:MAXBOX-1];
    integer j;
    always @(posedge lcd_clk or negedge lcd_rstn) begin
        if (!lcd_rstn) begin
            for (j=0; j<MAXBOX; j=j+1) begin
                bx1[j] <= 16'd0;
                by1[j] <= 16'd0;
                bx2[j] <= 16'd0;
                by2[j] <= 16'd0;
            end
        end else if (ld_last_d) begin
            for (j=0; j<MAXBOX; j=j+1) begin
                bx1[j] <= bq[2*j][31:16];
                by1[j] <= bq[2*j][15:0];
                bx2[j] <= bq[2*j+1][31:16];
                by2[j] <= bq[2*j+1][15:0];
            end
        end
    end

    //-------------------------------------------------------------------------
    // 每像素：16 框边框比较（组合）
    //-------------------------------------------------------------------------
    integer k;
    reg hit;
    always @(*) begin
        hit = 1'b0;
        for (k=0; k<MAXBOX; k=k+1) begin
            if (k < ovl_count) begin
                if (pix_x >= bx1[k] && pix_x <= bx2[k] &&
                    pix_y >= by1[k] && pix_y <= by2[k]) begin
                    if (pix_x < bx1[k] + 16'd2 ||
                        pix_x + 16'd2 > bx2[k] ||
                        pix_y < by1[k] + 16'd2 ||
                        pix_y + 16'd2 > by2[k]) hit = 1'b1;
                end
            end
        end
    end

    assign pix_out = (ovl_en && pix_de && hit) ? 16'h07E0 : pix_in;

endmodule
