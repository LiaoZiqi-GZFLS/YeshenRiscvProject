// dcfifo —— Gray 指针 dual-clock FIFO（1 项/拍稳态吞吐）。
//
// 口径：
//   · 源域写（sclk/srst/sdin/swr/sfull），目的域读（dclk/drst/dout/drd/dempty）。
//   · srst/drst 为**各域同步、高有效**复位；两侧必须来自同一复位源（见 cpu_domain_cdc）。
//   · 指针为 AW+1 位，最高位用于区分绕圈；跨域只同步 Gray 码（每步只变 1 位）。
//   · 存储体为寄存器阵列 + 目的域组合读；指针同步延迟保证“读到的一定是写完成的项”。
//   · 满/空用**当前指针**判定（无组合环）：full = wgray == {~rq2[AW:AW-1], rq2[AW-2:0]}，
//     empty = rgray == rq2_wgray。
module dcfifo #(
    parameter integer WIDTH = 8,
    parameter integer AW    = 4          // 深度 = 2^AW
) (
    input  wire             sclk,
    input  wire             srst,
    input  wire [WIDTH-1:0] sdin,
    input  wire             swr,
    output wire             sfull,

    input  wire             dclk,
    input  wire             drst,
    output wire [WIDTH-1:0] dout,
    input  wire             drd,
    output wire             dempty
);
    localparam integer DEPTH = (1 << AW);

    reg [WIDTH-1:0] mem [0:DEPTH-1];

    reg [AW:0] wbin, wgray;
    reg [AW:0] rbin, rgray;
`ifdef DCFIFO_BAD_SYNC
    // 负对照专用（综合不定义）：跳过指针同步器，模拟"忘了做 CDC"。
    wire [AW:0] wq1_rgray = rgray;
    wire [AW:0] wq2_rgray = rgray;
    wire [AW:0] rq1_wgray = wgray;
    wire [AW:0] rq2_wgray = wgray;
`else
    reg [AW:0] wq1_rgray, wq2_rgray;   // rptr 同步进写域
    reg [AW:0] rq1_wgray, rq2_wgray;   // wptr 同步进读域
`endif

    wire wr_en = swr & ~sfull;
    wire rd_en = drd & ~dempty;

    wire [AW:0] wbin_nxt  = wbin + {{AW{1'b0}}, wr_en};
    wire [AW:0] wgray_nxt = (wbin_nxt >> 1) ^ wbin_nxt;
    wire [AW:0] rbin_nxt  = rbin + {{AW{1'b0}}, rd_en};
    wire [AW:0] rgray_nxt = (rbin_nxt >> 1) ^ rbin_nxt;

    assign sfull  = (wgray == {~wq2_rgray[AW:AW-1], wq2_rgray[AW-2:0]});
    assign dempty = (rgray == rq2_wgray);
`ifdef DCFIFO_BAD_DATA
    // 负对照专用（综合不定义）：翻 1 bit，证明 TB 的数据比对确实会红。
    assign dout   = mem[rbin[AW-1:0]] ^ {{(WIDTH-1){1'b0}}, 1'b1};
`else
    assign dout   = mem[rbin[AW-1:0]];
`endif

    always @(posedge sclk) begin
        if (srst) begin
            wbin      <= 0;
            wgray     <= 0;
`ifndef DCFIFO_BAD_SYNC
            wq1_rgray <= 0;
            wq2_rgray <= 0;
`endif
        end else begin
            if (wr_en) begin
                mem[wbin[AW-1:0]] <= sdin;
                wbin  <= wbin_nxt;
                wgray <= wgray_nxt;
            end
`ifndef DCFIFO_BAD_SYNC
            wq1_rgray <= rgray;
            wq2_rgray <= wq1_rgray;
`endif
        end
    end

    always @(posedge dclk) begin
        if (drst) begin
            rbin      <= 0;
            rgray     <= 0;
`ifndef DCFIFO_BAD_SYNC
            rq1_wgray <= 0;
            rq2_wgray <= 0;
`endif
        end else begin
            if (rd_en) begin
                rbin  <= rbin_nxt;
                rgray <= rgray_nxt;
            end
`ifndef DCFIFO_BAD_SYNC
            rq1_wgray <= wgray;
            rq2_wgray <= rq1_wgray;
`endif
        end
    end
endmodule
