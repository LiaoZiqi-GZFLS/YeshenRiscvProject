module wr_fram_buf (
    input  [31:0]  wr_data,
    input  [11:0]  wr_addr,
    input          wr_en,
    input          wr_clk,
    input          wr_rst,
    output [255:0] rd_data,
    input  [8:0]   rd_addr,
    input          rd_clk,
    input          rd_rst
);
    reg [31:0] mem [0:4095];
    integer k;
    initial for (k = 0; k < 4096; k = k + 1) mem[k] = 32'd0;
    always @(posedge wr_clk) if (wr_en) mem[wr_addr] <= wr_data;
    assign rd_data = { mem[{rd_addr,3'd7}], mem[{rd_addr,3'd6}],
                       mem[{rd_addr,3'd5}], mem[{rd_addr,3'd4}],
                       mem[{rd_addr,3'd3}], mem[{rd_addr,3'd2}],
                       mem[{rd_addr,3'd1}], mem[{rd_addr,3'd0}] };
endmodule
