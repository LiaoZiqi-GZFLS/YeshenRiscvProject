// Generator : SpinalHDL v1.15.0    git head : 05a01af3d3345aa0afcaad8e0186dde13a359db2
// Component : NpuResetSync

`timescale 1ns/1ps

module NpuResetSync (
  input  wire          io_cpuClk,
  input  wire          io_npuClk,
  input  wire          io_asyncRst,
  output wire          io_cpuRstn,
  output wire          io_npuRstn
);

  wire       [2:0]    _zz_cpuRstSync;
  wire       [2:0]    _zz_npuRstSync;
  (* async_reg = "true" *) reg        [1:0]    cpuRstSync;
  reg                 cpuUp1;
  reg                 cpuUp2;
  reg        [1:0]    npuRstSync;
  wire                when_NpuResetSync_l93;

  assign _zz_cpuRstSync = ({1'd0,cpuRstSync} <<< 1'd1);
  assign _zz_npuRstSync = ({1'd0,npuRstSync} <<< 1'd1);
  assign io_cpuRstn = (! cpuRstSync[1]);
  assign when_NpuResetSync_l93 = (! cpuUp2);
  assign io_npuRstn = (! npuRstSync[1]);
  always @(posedge io_cpuClk or posedge io_asyncRst) begin
    if(io_asyncRst) begin
      cpuRstSync <= 2'b11;
    end else begin
      cpuRstSync <= _zz_cpuRstSync[1 : 0];
    end
  end

  always @(posedge io_npuClk or posedge io_asyncRst) begin
    if(io_asyncRst) begin
      cpuUp1 <= 1'b0;
      cpuUp2 <= 1'b0;
      npuRstSync <= 2'b11;
    end else begin
      cpuUp1 <= (! cpuRstSync[1]);
      cpuUp2 <= cpuUp1;
      if(when_NpuResetSync_l93) begin
        npuRstSync <= 2'b11;
      end else begin
        npuRstSync <= _zz_npuRstSync[1 : 0];
      end
    end
  end


endmodule
