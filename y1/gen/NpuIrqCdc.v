// Generator : SpinalHDL v1.15.0    git head : 05a01af3d3345aa0afcaad8e0186dde13a359db2
// Component : NpuIrqCdc

`timescale 1ns/1ps

module NpuIrqCdc (
  input  wire          io_cpuClk,
  input  wire          io_cpuRstn,
  input  wire          io_npuClk,
  input  wire          io_npuRstn,
  input  wire          io_npuIrq,
  output wire          io_cpuIrq,
  input  wire          io_cpuClearReq,
  output wire          io_npuClearReq
);

  reg                 irqSync1;
  reg                 irqSync2;
  reg                 clrSync1;
  reg                 clrSync2;

  assign io_cpuIrq = irqSync2;
  assign io_npuClearReq = clrSync2;
  always @(posedge io_cpuClk or negedge io_cpuRstn) begin
    if(!io_cpuRstn) begin
      irqSync1 <= 1'b0;
      irqSync2 <= 1'b0;
    end else begin
      irqSync1 <= io_npuIrq;
      irqSync2 <= irqSync1;
    end
  end

  always @(posedge io_npuClk or negedge io_npuRstn) begin
    if(!io_npuRstn) begin
      clrSync1 <= 1'b0;
      clrSync2 <= 1'b0;
    end else begin
      clrSync1 <= io_cpuClearReq;
      clrSync2 <= clrSync1;
    end
  end


endmodule
