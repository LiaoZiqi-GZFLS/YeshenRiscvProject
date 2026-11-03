module wr_fram_buf (
    input  [31:0]  wr_data,
    input  [11:0]  wr_addr,
    input          wr_en,
    input          wr_clk,
    input          wr_rst,
    output reg [255:0] rd_data,
    input  [8:0]   rd_addr,
    input          rd_clk,
    input          rd_rst
);
    // SYNC-read model (latency 1): matches the real Pango BRAM primitive
    // with OUTPUT_REG=0 / FAB_REG=0 (ip/wr_fram_buf config).
    reg [31:0] mem [0:4095];
    integer k;
    initial begin
        for (k = 0; k < 4096; k = k + 1) mem[k] = 32'd0;
        rd_data = 256'd0;
    end
    always @(posedge wr_clk) if (wr_en) mem[wr_addr] <= wr_data;
    always @(posedge rd_clk)
        rd_data <= { mem[{rd_addr,3'd7}], mem[{rd_addr,3'd6}],
                     mem[{rd_addr,3'd5}], mem[{rd_addr,3'd4}],
                     mem[{rd_addr,3'd3}], mem[{rd_addr,3'd2}],
                     mem[{rd_addr,3'd1}], mem[{rd_addr,3'd0}] };
endmodule
