// Behavioral stand-in for the Pango `rd_fram_buf` IP (write 512x256, read 4096x32).
//
// Used only by y1/tools/run_rdbuf_lat_ab.sh. The gates compile `rd_buf.v` WITHOUT
// board/cam/vendor/ip/rd_fram_buf/rd_fram_buf.v, so this module binds by name.
// Address mapping mirrors the IP contract: word `w` of a 256-bit beat lives at
// read address 8*beat + w.
`timescale 1ns/1ps
module rd_fram_buf (
    input  wire [255:0] wr_data,
    input  wire [8:0]   wr_addr,
    input  wire         wr_en,
    input  wire         wr_clk,
    input  wire         wr_rst,
    output reg  [31:0]  rd_data,
    input  wire [11:0]  rd_addr,
    input  wire         rd_clk,
    input  wire         rd_rst
);
    reg [255:0] mem [0:511];
    integer i;
    initial for (i = 0; i < 512; i = i + 1) mem[i] = 256'd0;

    always @(posedge wr_clk) if (wr_en) mem[wr_addr] <= wr_data;

    always @(posedge rd_clk)
        if (rd_rst) rd_data <= 32'd0;
        else        rd_data <= mem[rd_addr[11:3]][rd_addr[2:0]*32 +: 32];
endmodule
