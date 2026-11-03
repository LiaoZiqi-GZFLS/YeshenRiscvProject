//=============================================================================
// stub_rd_fram_buf: rd_fram_buf 的行为模型（仅仿真；厂家 IP 依赖 GTP_DRM18K_E1
// 原语，iverilog 无法细化）。与 ip/rd_fram_buf 的对外形态逐位一致：
//   宽口写 512 x 256bit，窄口读 4096 x 32bit，同一块 16 KiB 存储
//   宽字 w 的 8 个窄字 = mem[8w+7 : 8w]（低位在低地址，同厂家 stub_rambuf*.v）
//   读延迟 1 拍（IP: OUTPUT_REG=0 / FAB_REG=0）
//=============================================================================
`timescale 1ns/1ps
module rd_fram_buf (
    input  [255:0] wr_data,
    input  [8:0]   wr_addr,
    input          wr_en,
    input          wr_clk,
    input          wr_rst,
    output reg [31:0] rd_data,
    input  [11:0]  rd_addr,
    input          rd_clk,
    input          rd_rst
);
    reg [31:0] mem [0:4095];
    integer k, b;
    initial begin
        for (k = 0; k < 4096; k = k + 1) mem[k] = 32'd0;
        rd_data = 32'd0;
    end
    always @(posedge wr_clk) begin
        if (wr_en)
            for (b = 0; b < 8; b = b + 1)
                mem[wr_addr*8 + b] <= wr_data[32*b +: 32];
    end
    always @(posedge rd_clk) begin
        if (rd_rst) rd_data <= 32'd0;
        else        rd_data <= mem[rd_addr];
    end
endmodule
