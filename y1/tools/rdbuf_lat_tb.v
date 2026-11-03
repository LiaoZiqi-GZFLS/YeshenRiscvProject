// Latency-margin TB for board/cam/vendor/tutorial/rd_buf.v
//
// The display side is slaved to the LCD timing (1024x600 @ 51.923 MHz, H_TOTAL 1344,
// V_TOTAL 635 -- the numbers used by board/cam/video_passthrough.v). The DDR side is
// a model: every request returns 64 beats of 256 bit, the first beat LAT ddr_clk
// cycles after the request, subsequent beats BEAT cycles apart.
//
// Every 32-bit word of request #r carries the 16-bit value r (replicated), so the
// displayed word tells us *which request* the panel is showing. Request #k is the
// data for display line k (request 0 is issued at frame sync). Any word whose value
// is not the current display-line index means the read did not land in the line's
// ring slot in time -> exactly the "stale pixel" failure seen as speckle on screen.
`timescale 1ns/1ps
module rdbuf_lat_tb;

    parameter integer LAT    = 0;   // ddr_clk cycles: request -> first data beat
    parameter integer BEAT   = 1;   // ddr_clk cycles between beats (1 = back-to-back)
    parameter integer NFRAME = 3;   // frames to run; frames 0..NFRAME-2 are judged

    // ---------------------------------------------------------------- clocks
    reg ddr_clk  = 0;
    reg vout_clk = 0;
    always #4.0000 ddr_clk  = ~ddr_clk;   // 125.0 MHz  (core_clk)
    always #9.6295 vout_clk = ~vout_clk;  // 51.923 MHz (lcd_clk)

    reg rstn = 0;
    initial #200 rstn = 1;

    // ------------------------------------------------- display timing source
    localparam integer H_TOTAL = 1344;
    localparam integer H_DE0   = 160;
    localparam integer H_DEW   = 1024;
    localparam integer V_TOTAL = 635;
    localparam integer V_DE0   = 23;
    localparam integer V_DEW   = 600;

    integer hc = 0, vc = 0;
    reg de_r = 0, vs_r = 0;
    always @(posedge vout_clk) begin
        if (!rstn) begin
            hc <= 0; vc <= 0;
        end else if (hc == H_TOTAL-1) begin
            hc <= 0;
            vc <= (vc == V_TOTAL-1) ? 0 : vc+1;
        end else begin
            hc <= hc+1;
        end
        de_r <= (hc >= H_DE0) && (hc < H_DE0+H_DEW) &&
                (vc >= V_DE0) && (vc < V_DE0+V_DEW);
        vs_r <= (vc < 3);
    end

    wire [11:0] disp_line = (vc >= V_DE0) ? (vc - V_DE0) : 12'd0;

    // ------------------------------------------------------------------- DUT
    wire        rreq, vout_de;
    wire [31:0] raddr;
    wire [15:0] rlen;
    wire [15:0] vout_data;
    reg         rrdy = 1'b1;
    reg         rdone = 1'b0;
    reg  [255:0] rdata = 256'd0;
    reg         rdata_en = 1'b0;

    rd_buf #(
        .ADDR_WIDTH      (6'd27),
        .ADDR_OFFSET     (32'h0000_0000),
        .H_NUM           (12'd1024),
        .V_NUM           (12'd720),
        .DQ_WIDTH        (12'd32),
        .PIX_WIDTH       (12'd16),
        .ROW_OFFSET      (12'd60)
    ) u_dut (
        .ddr_clk      (ddr_clk),
        .ddr_rstn     (rstn),
        .vout_clk     (vout_clk),
        .rd_fsync     (vs_r),
        .rd_en        (de_r),
        .vout_de      (vout_de),
        .vout_data    (vout_data),
        .init_done    (1'b1),
        .wr_bank      (1'b0),
        .ddr_rreq     (rreq),
        .ddr_raddr    (raddr),
        .ddr_rd_len   (rlen),
        .ddr_rrdy     (rrdy),
        .ddr_rdone    (rdone),
        .ddr_rdata    (rdata),
        .ddr_rdata_en (rdata_en)
    );

    // ------------------------------------------------------ DDR read model
    localparam integer S_IDLE = 0, S_WAIT = 1, S_BEAT = 2, S_TAIL = 3;
    integer st = S_IDLE;
    integer wait_cnt = 0, gap = 0, beat = 0;
    integer req_cnt = 0;       // requests seen so far
    integer drop_cnt = 0;      // requests that arrived while a read was in flight
    reg [15:0] cur = 0;        // request index being served

    always @(posedge ddr_clk) begin
        if (!rstn) begin
            st <= S_IDLE; rdata_en <= 0; rdone <= 0; req_cnt <= 0; drop_cnt <= 0;
        end else begin
            rdata_en <= 1'b0;
            rdone    <= 1'b0;
            case (st)
            S_IDLE: if (rreq) begin
                cur  <= req_cnt[15:0];
                req_cnt <= req_cnt + 1;
                wait_cnt <= LAT;
                st <= S_WAIT;
            end
            S_WAIT: begin
                if (wait_cnt > 0) wait_cnt <= wait_cnt - 1;
                else begin beat <= 0; gap <= 0; st <= S_BEAT; end
            end
            S_BEAT: begin
                if (gap > 0) gap <= gap - 1;
                else begin
                    rdata    <= {16{cur}};    // 256 bit: every 32-bit word = {cur,cur}
                    rdata_en <= 1'b1;
                    if (beat == 63) st <= S_TAIL;
                    else begin beat <= beat + 1; gap <= BEAT - 1; end
                end
            end
            S_TAIL: begin rdone <= 1'b1; st <= S_IDLE; end
            default: st <= S_IDLE;
            endcase
            if (rreq && st != S_IDLE) drop_cnt <= drop_cnt + 1;
        end
    end

    // ------------------------------------------------------------- checker
    // Expected content of display line k of a frame = request (exp_base + k), where
    // exp_base is the first request of that frame. exp1/exp2 pipeline `disp_line` to
    // the vout_de/data stage; `word_in_line` is used to skip the 2 pixels that the
    // vendor pixel-packer sources from the previous word at every line boundary.
    integer mismatch = 0, words = 0, frame = 0, judge = 0, wcnt = 0, shown = 0;
    integer exp1 = 0, exp2 = 0, exp_base = 0, expv = 0;
    reg de_d = 0;

    always @(posedge vout_clk) begin
        de_d <= de_r;
        if (de_r && !de_d) begin
            wcnt <= 0;
            if (frame == 1 && disp_line < 4)
                $display("DE t=%0t line=%0d rd_addr=%0d wr_addr=%0d wr_cnt=%0d",
                         $time, disp_line, u_dut.rd_addr, u_dut.wr_addr, u_dut.wr_cnt);
            if (vc == V_DE0) begin
                frame   <= frame + 1;
                exp_base <= req_cnt - 1;   // vsync read of this frame is request exp_base
            end
        end else if (vout_de) begin
            wcnt <= wcnt + 1;
        end
        exp1 <= disp_line;
        exp2 <= exp1;
        if (!rstn) begin
            judge <= 0; mismatch <= 0; words <= 0;
        end else begin
            // frame 0 is the warm-up frame (post-reset vsync edge is consumed by init)
            judge <= (frame > 1) && (frame < NFRAME);
            expv = (exp_base + exp2) & 16'hFFFF;
            if (vout_de && judge && (wcnt >= 4)) begin
                words <= words + 1;
                if (vout_data !== expv[15:0]) begin
                    mismatch <= mismatch + 1;
                    if (shown < 8) begin
                        shown <= shown + 1;
                        $display("MISMATCH line=%0d w=%0d exp=%0d got=%0d",
                                 exp2, wcnt, expv, vout_data);
                    end
                end
            end
        end
        if (frame == NFRAME) begin
            $display("TB LAT=%0d BEAT=%0d WORDS=%0d MISMATCH=%0d REQ=%0d DROP=%0d",
                     LAT, BEAT, words, mismatch, req_cnt, drop_cnt);
            $finish;
        end
    end

endmodule
