`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: Meyesemi
// Engineer: Nill
// 
// Create Date: 07/03/23 19:13:35
// Design Name: 
// Module Name: wr_buf
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////
`define UD #1
module wr_buf #(
    parameter                     ADDR_WIDTH      = 6'd27,
    parameter                     ADDR_OFFSET     = 32'h0000_0000,
    parameter                     H_NUM           = 12'd1920,
    parameter                     V_NUM           = 12'd1080,
    parameter                     DQ_WIDTH        = 12'd32,
    parameter                     LEN_WIDTH       = 12'd16,
    parameter                     PIX_WIDTH       = 12'd24,
    parameter                     LINE_ADDR_WIDTH = 16'd19,
    parameter                     FRAME_CNT_WIDTH = 16'd8
) (                               
    input                         ddr_clk,
    input                         ddr_rstn,
                                  
    input                         wr_clk,
    input                         wr_fsync,
    input                         wr_en,
    input  [PIX_WIDTH- 1'b1 : 0]  wr_data,
    
    input                         rd_bac,
    output                        ddr_wreq,
    output [ADDR_WIDTH- 1'b1 : 0] ddr_waddr,
    output [LEN_WIDTH- 1'b1 : 0]  ddr_wr_len,
    input                         ddr_wrdy,
    input                         ddr_wdone,
    output [8*DQ_WIDTH- 1'b1 : 0] ddr_wdata,
    input                         ddr_wdata_req,
    
    output [FRAME_CNT_WIDTH-1 :0] frame_wcnt,
    output                        frame_wirq
);
    localparam RAM_WIDTH      = 16'd32;
    localparam DDR_DATA_WIDTH = DQ_WIDTH * 8;
    localparam WR_LINE_NUM    = H_NUM*PIX_WIDTH/RAM_WIDTH;
    localparam RD_LINE_NUM    = WR_LINE_NUM*RAM_WIDTH/DDR_DATA_WIDTH;
    localparam DDR_ADDR_OFFSET= RD_LINE_NUM*DDR_DATA_WIDTH/DQ_WIDTH;
    
    //===========================================================================
    reg       wr_fsync_1d;
    reg       wr_en_1d;
    wire      wr_rst;
    reg       wr_enable=0;
    
    reg       ddr_rstn_1d,ddr_rstn_2d;
    
    always @(posedge wr_clk)
    begin
        wr_fsync_1d <= wr_fsync;
        wr_en_1d <= wr_en;
        ddr_rstn_1d <= ddr_rstn;
        ddr_rstn_2d <= ddr_rstn_1d;
        
        if(~wr_fsync_1d & wr_fsync && ddr_rstn_2d) 
            wr_enable <= 1'b1;
        else 
            wr_enable <= wr_enable;
    end 
    
    assign wr_rst = (~wr_fsync_1d & wr_fsync) | (~ddr_rstn_2d);
    
    //===========================================================================
    reg      rd_fsync_1d,rd_fsync_2d,rd_fsync_3d;
    wire     rd_rst;
    always @(posedge ddr_clk)
    begin
        rd_fsync_1d <= wr_fsync;
        rd_fsync_2d <= rd_fsync_1d;
        rd_fsync_3d <= rd_fsync_2d;
    end 
    
    assign rd_rst = (~rd_fsync_3d && rd_fsync_2d) | (~ddr_rstn);

    //===========================================================================
    // wr_addr control
    reg [11:0]                 x_cnt;
    reg [11:0]                 y_cnt;
    reg [31 : 0]  write_data;
    reg [PIX_WIDTH- 1'b1 : 0]  wr_data_1d;
    reg                        write_en;
    reg [11:0]                 wr_addr=0;
    
generate
    if(PIX_WIDTH == 6'd24)
    begin
        always @(posedge wr_clk)
        begin
            wr_data_1d <= wr_data;
            
            write_en <= (x_cnt[1:0] != 0);
            
            if(x_cnt[1:0] == 2'd1)
                write_data <= {wr_data[7:0],wr_data_1d};
            else if(x_cnt[1:0] == 2'd2)
                write_data <= {wr_data[15:0],wr_data_1d[PIX_WIDTH-1'b1:8]};
            else if(x_cnt[1:0] == 2'd3)
                write_data <= {wr_data,wr_data_1d[PIX_WIDTH-1'b1:16]};
            else
                write_data <= write_data;
        end 
    end
    else if(PIX_WIDTH == 6'd16)
    begin
        always @(posedge wr_clk)
        begin
            wr_data_1d <= wr_data;
            
            write_en <= x_cnt[0];
            if(x_cnt[0])
                write_data <= {wr_data,wr_data_1d};
            else
                write_data <= write_data;
        end 
    end
    else
    begin
        always @(posedge wr_clk)
        begin
            write_data <= wr_data;
            write_en <= wr_en;
        end 
    end
endgenerate

    // OUR COPY: exact-length line discipline.
    // rd_pulse now requires x_cnt==H_NUM (full line), and any line whose
    // envelope ends BEFORE H_NUM pixels (sensor line glitch -- telemetry pL
    // showed 52us/104us instability) is DISCARDED by rolling wr_addr back to
    // the line base. Without this a short line both drains a half-filled
    // buffer into DDR and leaves wr_addr mid-line => every later line in the
    // frame is horizontally shifted (screen jitter + channel-shifted colors).
    reg [11:0] line_base;
    always @(posedge wr_clk)
    begin
        if(wr_rst) begin
            wr_addr   <= 12'd0;
            line_base <= 12'd0;
        end
        else if(wr_en & ~wr_en_1d)                       // line rise: snapshot base
            line_base <= wr_addr;
        else if(~wr_en & wr_en_1d & (x_cnt < H_NUM))     // SHORT line: discard whole line
            wr_addr <= line_base;
        else if(write_en & wr_enable)
            wr_addr <= wr_addr + 12'd1;
        else
            wr_addr <= wr_addr;
    end

    always @(posedge wr_clk)
    begin 
        if(wr_rst)
            x_cnt <= 12'd0;
        else if(wr_en & wr_enable)
            x_cnt <= x_cnt + 1'b1;
        else
            x_cnt <= 12'd0;
    end 
    
    always @(posedge wr_clk)
    begin 
        if(wr_rst)
            y_cnt <= 12'd0;
        else if(~wr_en_1d & wr_en & wr_enable)
            y_cnt <= y_cnt + 1'b1;
        else
            y_cnt <= y_cnt;
    end 
    
    reg rd_pulse;
    always @(posedge wr_clk)
    begin
        if(x_cnt >= H_NUM  & wr_enable)   // EXACT full line only (was >H_NUM-20:
            rd_pulse <= 1'b1;             // let 1005..1023-px short lines drain)
        else
            rd_pulse <= 1'b0; 
    end 
    
    reg  [8:0] rd_addr=0;
    wire [255:0] rd_wdata;
    reg  [255:0] rd_wdata_1d=0;
    wr_fram_buf wr_fram_buf (
        .wr_data            (  write_data     ),// input [31:0]               
        .wr_addr            (  wr_addr        ),// input [11:0]               
        .wr_en              (  write_en       ),// input                      
        .wr_clk             (  wr_clk         ),// input                      
        .wr_rst             (  ~ddr_rstn_2d   ),// input    
                          
        .rd_addr            (  rd_addr        ),// input [8:0]                
        .rd_data            (  rd_wdata       ),// output [255:0]             
        .rd_clk             (  ddr_clk        ),// input                      
        .rd_rst             (  ~ddr_rstn      ) // input                      
    );
    
    reg rd_pulse_1d,rd_pulse_2d,rd_pulse_3d;
    always @(posedge ddr_clk)
    begin 
        rd_pulse_1d <= rd_pulse;
        rd_pulse_2d <= rd_pulse_1d;
        rd_pulse_3d <= rd_pulse_2d;
    end 
    
    wire rd_trig;
    assign rd_trig = ~rd_pulse_3d && rd_pulse_2d;
    
    reg ddr_wr_req=0;
    reg ddr_wr_req_1d;
    assign ddr_wreq =ddr_wr_req;
    
    always @(posedge ddr_clk)
    begin 
        ddr_wr_req_1d <= ddr_wr_req;
        
        if(rd_trig)
            ddr_wr_req <= 1'b1;
        else if(ddr_wdata_req)
            ddr_wr_req <= 1'b0;
        else
            ddr_wr_req <= ddr_wr_req;
    end 
    
    reg  rd_en_1d;
    reg  ddr_wdata_req_1d;
    always @(posedge ddr_clk)
    begin
        ddr_wdata_req_1d <= ddr_wdata_req;
        rd_en_1d <= ~ddr_wr_req_1d & ddr_wr_req;
    end 
    
    always @(posedge ddr_clk)
    begin
        if(ddr_wdata_req_1d | rd_en_1d)
            rd_wdata_1d <= rd_wdata;
        else 
            rd_wdata_1d <= rd_wdata_1d;
    end 
    
    reg line_flag=0;
    always@(posedge ddr_clk)
    begin
        if(rd_rst)
            // KEEP 1'b0 (original vendor value): the +1 residue left by the
            // first trig (no -1 on it) is REQUIRED -- it positions every later
            // trig's -1 exactly ON the line base so rd_wdata_1d (sync-RAM
            // first-beat bridge) ships mem[base], not mem[base-1]. Setting 1'b1
            // made -1 land at base-1 -> beat0 = prev-line tail 16px + tail of
            // this line lost (board: green strip at left edge, no green at
            // right; tb content model reproduces).
            line_flag <= 1'b0;
        else if(rd_trig)
            line_flag <= 1'b1;
        else
            line_flag <= line_flag;
    end 
    
    always @(posedge ddr_clk)
    begin 
        if(rd_rst)
            rd_addr <= 1'b0;
        else if(~ddr_wr_req_1d & ddr_wr_req)
            rd_addr <= rd_addr + 1'b1;
        else if(ddr_wdata_req)
            rd_addr <= rd_addr + 1'b1;
        else if(rd_trig & line_flag)
            rd_addr <= rd_addr - 1'b1;
        else
            rd_addr <= rd_addr;
    end 
    
    reg [FRAME_CNT_WIDTH - 1'b1 :0] rd_frame_cnt=1;
    always @(posedge ddr_clk)
    begin 
        if(~ddr_rstn)
            rd_frame_cnt <= 'd0;
        else if(~rd_fsync_3d && rd_fsync_2d)
            rd_frame_cnt <= rd_frame_cnt + 1'b1;
        else
            rd_frame_cnt <= rd_frame_cnt;
    end 

    reg [LINE_ADDR_WIDTH - 1'b1 :0] rd_cnt;
    always @(posedge ddr_clk)
    begin 
        if(rd_rst)
            rd_cnt <= 9'd0;
        else if(ddr_wdone)
            rd_cnt <= rd_cnt + DDR_ADDR_OFFSET;
        else
            rd_cnt <= rd_cnt;
    end 
    
    reg wirq_en=0;
    always @(posedge ddr_clk)
    begin
        if (~rd_fsync_2d && rd_fsync_3d)
            wirq_en <= 1'b1;
        else
            wirq_en <= wirq_en;
    end 
    
    assign ddr_wdata = (~ddr_wdata_req_1d & ddr_wdata_req) ? rd_wdata_1d : rd_wdata;
    assign ddr_waddr = {rd_frame_cnt[0],rd_cnt} + ADDR_OFFSET;
    assign ddr_wr_len = RD_LINE_NUM;
    assign frame_wcnt = rd_frame_cnt;
    assign frame_wirq = wirq_en && rd_fsync_3d;
    
endmodule
