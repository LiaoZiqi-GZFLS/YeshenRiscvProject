// Generator : SpinalHDL v1.15.0    git head : 05a01af3d3345aa0afcaad8e0186dde13a359db2
// Component : NpuAxiLiteCdc

`timescale 1ns/1ps

module NpuAxiLiteCdc (
  input  wire          io_cpuClk,
  input  wire          io_cpuRstn,
  input  wire          io_npuClk,
  input  wire          io_npuRstn,
  input  wire          io_axilite_aw_valid,
  output wire          io_axilite_aw_ready,
  input  wire [31:0]   io_axilite_aw_payload_addr,
  input  wire [2:0]    io_axilite_aw_payload_prot,
  input  wire          io_axilite_w_valid,
  output wire          io_axilite_w_ready,
  input  wire [31:0]   io_axilite_w_payload_data,
  input  wire [3:0]    io_axilite_w_payload_strb,
  output wire          io_axilite_b_valid,
  input  wire          io_axilite_b_ready,
  output wire [1:0]    io_axilite_b_payload_resp,
  input  wire          io_axilite_ar_valid,
  output wire          io_axilite_ar_ready,
  input  wire [31:0]   io_axilite_ar_payload_addr,
  input  wire [2:0]    io_axilite_ar_payload_prot,
  output wire          io_axilite_r_valid,
  input  wire          io_axilite_r_ready,
  output wire [31:0]   io_axilite_r_payload_data,
  output wire [1:0]    io_axilite_r_payload_resp,
  output wire          io_npu_axilite_aw_valid,
  input  wire          io_npu_axilite_aw_ready,
  output wire [31:0]   io_npu_axilite_aw_payload_addr,
  output wire [2:0]    io_npu_axilite_aw_payload_prot,
  output wire          io_npu_axilite_w_valid,
  input  wire          io_npu_axilite_w_ready,
  output wire [31:0]   io_npu_axilite_w_payload_data,
  output wire [3:0]    io_npu_axilite_w_payload_strb,
  input  wire          io_npu_axilite_b_valid,
  output wire          io_npu_axilite_b_ready,
  input  wire [1:0]    io_npu_axilite_b_payload_resp,
  output wire          io_npu_axilite_ar_valid,
  input  wire          io_npu_axilite_ar_ready,
  output wire [31:0]   io_npu_axilite_ar_payload_addr,
  output wire [2:0]    io_npu_axilite_ar_payload_prot,
  input  wire          io_npu_axilite_r_valid,
  output wire          io_npu_axilite_r_ready,
  input  wire [31:0]   io_npu_axilite_r_payload_data,
  input  wire [1:0]    io_npu_axilite_r_payload_resp
);

  wire                awPipe_io_enq_ready;
  wire                awPipe_io_deq_valid;
  wire       [31:0]   awPipe_io_deq_payload_addr;
  wire       [2:0]    awPipe_io_deq_payload_prot;
  wire                wPipe_io_enq_ready;
  wire                wPipe_io_deq_valid;
  wire       [31:0]   wPipe_io_deq_payload_data;
  wire       [3:0]    wPipe_io_deq_payload_strb;
  wire                bPipe_io_enq_ready;
  wire                bPipe_io_deq_valid;
  wire       [1:0]    bPipe_io_deq_payload_resp;
  wire                arPipe_io_enq_ready;
  wire                arPipe_io_deq_valid;
  wire       [31:0]   arPipe_io_deq_payload_addr;
  wire       [2:0]    arPipe_io_deq_payload_prot;
  wire                rPipe_io_enq_ready;
  wire                rPipe_io_deq_valid;
  wire       [31:0]   rPipe_io_deq_payload_data;
  wire       [1:0]    rPipe_io_deq_payload_resp;

  CdcPipeSp awPipe (
    .io_sClk             (io_cpuClk                       ), //i
    .io_sRstn            (io_cpuRstn                      ), //i
    .io_dClk             (io_npuClk                       ), //i
    .io_dRstn            (io_npuRstn                      ), //i
    .io_enq_valid        (io_axilite_aw_valid             ), //i
    .io_enq_ready        (awPipe_io_enq_ready             ), //o
    .io_enq_payload_addr (io_axilite_aw_payload_addr[31:0]), //i
    .io_enq_payload_prot (io_axilite_aw_payload_prot[2:0] ), //i
    .io_deq_valid        (awPipe_io_deq_valid             ), //o
    .io_deq_ready        (io_npu_axilite_aw_ready         ), //i
    .io_deq_payload_addr (awPipe_io_deq_payload_addr[31:0]), //o
    .io_deq_payload_prot (awPipe_io_deq_payload_prot[2:0] )  //o
  );
  CdcPipeSp_1 wPipe (
    .io_sClk             (io_cpuClk                      ), //i
    .io_sRstn            (io_cpuRstn                     ), //i
    .io_dClk             (io_npuClk                      ), //i
    .io_dRstn            (io_npuRstn                     ), //i
    .io_enq_valid        (io_axilite_w_valid             ), //i
    .io_enq_ready        (wPipe_io_enq_ready             ), //o
    .io_enq_payload_data (io_axilite_w_payload_data[31:0]), //i
    .io_enq_payload_strb (io_axilite_w_payload_strb[3:0] ), //i
    .io_deq_valid        (wPipe_io_deq_valid             ), //o
    .io_deq_ready        (io_npu_axilite_w_ready         ), //i
    .io_deq_payload_data (wPipe_io_deq_payload_data[31:0]), //o
    .io_deq_payload_strb (wPipe_io_deq_payload_strb[3:0] )  //o
  );
  CdcPipeSp_2 bPipe (
    .io_sClk             (io_npuClk                         ), //i
    .io_sRstn            (io_npuRstn                        ), //i
    .io_dClk             (io_cpuClk                         ), //i
    .io_dRstn            (io_cpuRstn                        ), //i
    .io_enq_valid        (io_npu_axilite_b_valid            ), //i
    .io_enq_ready        (bPipe_io_enq_ready                ), //o
    .io_enq_payload_resp (io_npu_axilite_b_payload_resp[1:0]), //i
    .io_deq_valid        (bPipe_io_deq_valid                ), //o
    .io_deq_ready        (io_axilite_b_ready                ), //i
    .io_deq_payload_resp (bPipe_io_deq_payload_resp[1:0]    )  //o
  );
  CdcPipeSp arPipe (
    .io_sClk             (io_cpuClk                       ), //i
    .io_sRstn            (io_cpuRstn                      ), //i
    .io_dClk             (io_npuClk                       ), //i
    .io_dRstn            (io_npuRstn                      ), //i
    .io_enq_valid        (io_axilite_ar_valid             ), //i
    .io_enq_ready        (arPipe_io_enq_ready             ), //o
    .io_enq_payload_addr (io_axilite_ar_payload_addr[31:0]), //i
    .io_enq_payload_prot (io_axilite_ar_payload_prot[2:0] ), //i
    .io_deq_valid        (arPipe_io_deq_valid             ), //o
    .io_deq_ready        (io_npu_axilite_ar_ready         ), //i
    .io_deq_payload_addr (arPipe_io_deq_payload_addr[31:0]), //o
    .io_deq_payload_prot (arPipe_io_deq_payload_prot[2:0] )  //o
  );
  CdcPipeSp_4 rPipe (
    .io_sClk             (io_npuClk                          ), //i
    .io_sRstn            (io_npuRstn                         ), //i
    .io_dClk             (io_cpuClk                          ), //i
    .io_dRstn            (io_cpuRstn                         ), //i
    .io_enq_valid        (io_npu_axilite_r_valid             ), //i
    .io_enq_ready        (rPipe_io_enq_ready                 ), //o
    .io_enq_payload_data (io_npu_axilite_r_payload_data[31:0]), //i
    .io_enq_payload_resp (io_npu_axilite_r_payload_resp[1:0] ), //i
    .io_deq_valid        (rPipe_io_deq_valid                 ), //o
    .io_deq_ready        (io_axilite_r_ready                 ), //i
    .io_deq_payload_data (rPipe_io_deq_payload_data[31:0]    ), //o
    .io_deq_payload_resp (rPipe_io_deq_payload_resp[1:0]     )  //o
  );
  assign io_axilite_aw_ready = awPipe_io_enq_ready;
  assign io_npu_axilite_aw_valid = awPipe_io_deq_valid;
  assign io_npu_axilite_aw_payload_addr = awPipe_io_deq_payload_addr;
  assign io_npu_axilite_aw_payload_prot = awPipe_io_deq_payload_prot;
  assign io_axilite_w_ready = wPipe_io_enq_ready;
  assign io_npu_axilite_w_valid = wPipe_io_deq_valid;
  assign io_npu_axilite_w_payload_data = wPipe_io_deq_payload_data;
  assign io_npu_axilite_w_payload_strb = wPipe_io_deq_payload_strb;
  assign io_npu_axilite_b_ready = bPipe_io_enq_ready;
  assign io_axilite_b_valid = bPipe_io_deq_valid;
  assign io_axilite_b_payload_resp = bPipe_io_deq_payload_resp;
  assign io_axilite_ar_ready = arPipe_io_enq_ready;
  assign io_npu_axilite_ar_valid = arPipe_io_deq_valid;
  assign io_npu_axilite_ar_payload_addr = arPipe_io_deq_payload_addr;
  assign io_npu_axilite_ar_payload_prot = arPipe_io_deq_payload_prot;
  assign io_npu_axilite_r_ready = rPipe_io_enq_ready;
  assign io_axilite_r_valid = rPipe_io_deq_valid;
  assign io_axilite_r_payload_data = rPipe_io_deq_payload_data;
  assign io_axilite_r_payload_resp = rPipe_io_deq_payload_resp;

endmodule

module CdcPipeSp_4 (
  input  wire          io_sClk,
  input  wire          io_sRstn,
  input  wire          io_dClk,
  input  wire          io_dRstn,
  input  wire          io_enq_valid,
  output wire          io_enq_ready,
  input  wire [31:0]   io_enq_payload_data,
  input  wire [1:0]    io_enq_payload_resp,
  output wire          io_deq_valid,
  input  wire          io_deq_ready,
  output wire [31:0]   io_deq_payload_data,
  output wire [1:0]    io_deq_payload_resp
);

  (* async_reg = "true" *) reg        [31:0]   sData_data;
  (* async_reg = "true" *) reg        [1:0]    sData_resp;
  (* async_reg = "true" *) reg                 sValid;
  reg                 ackSync1;
  reg                 ackSync2;
  reg                 validSync1;
  reg                 validSync2;
  reg        [31:0]   dData_data;
  reg        [1:0]    dData_resp;
  reg                 dPending;
  (* async_reg = "true" *) reg                 dAck;
  reg                 dMask;
  wire                io_enq_fire;
  wire                when_NpuAxiLiteCdc_l198;
  wire                when_NpuAxiLiteCdc_l201;
  wire                io_deq_fire;

  assign io_enq_ready = ((! sValid) && (! ackSync2));
  assign io_enq_fire = (io_enq_valid && io_enq_ready);
  assign when_NpuAxiLiteCdc_l198 = (validSync2 && (! dPending));
  assign when_NpuAxiLiteCdc_l201 = (! validSync2);
  assign io_deq_valid = (dPending && (! dMask));
  assign io_deq_payload_data = dData_data;
  assign io_deq_payload_resp = dData_resp;
  assign io_deq_fire = (io_deq_valid && io_deq_ready);
  always @(posedge io_sClk or negedge io_sRstn) begin
    if(!io_sRstn) begin
      sValid <= 1'b0;
      ackSync1 <= 1'b0;
      ackSync2 <= 1'b0;
    end else begin
      ackSync1 <= dAck;
      ackSync2 <= ackSync1;
      if(io_enq_fire) begin
        sValid <= 1'b1;
      end else begin
        if(ackSync2) begin
          sValid <= 1'b0;
        end
      end
    end
  end

  always @(posedge io_dClk or negedge io_dRstn) begin
    if(!io_dRstn) begin
      validSync1 <= 1'b0;
      validSync2 <= 1'b0;
      dPending <= 1'b0;
      dAck <= 1'b0;
      dMask <= 1'b0;
    end else begin
      validSync1 <= sValid;
      validSync2 <= validSync1;
      if(when_NpuAxiLiteCdc_l198) begin
        dPending <= 1'b1;
      end else begin
        if(when_NpuAxiLiteCdc_l201) begin
          dPending <= 1'b0;
          dAck <= 1'b0;
          dMask <= 1'b0;
        end
      end
      if(io_deq_fire) begin
        dAck <= 1'b1;
        dMask <= 1'b1;
      end
    end
  end

  always @(posedge io_sClk) begin
    if(io_enq_fire) begin
      sData_data <= io_enq_payload_data;
      sData_resp <= io_enq_payload_resp;
    end
  end

  always @(posedge io_dClk) begin
    if(when_NpuAxiLiteCdc_l198) begin
      dData_data <= sData_data;
      dData_resp <= sData_resp;
    end
  end


endmodule

//CdcPipeSp_3 replaced by CdcPipeSp

module CdcPipeSp_2 (
  input  wire          io_sClk,
  input  wire          io_sRstn,
  input  wire          io_dClk,
  input  wire          io_dRstn,
  input  wire          io_enq_valid,
  output wire          io_enq_ready,
  input  wire [1:0]    io_enq_payload_resp,
  output wire          io_deq_valid,
  input  wire          io_deq_ready,
  output wire [1:0]    io_deq_payload_resp
);

  (* async_reg = "true" *) reg        [1:0]    sData_resp;
  (* async_reg = "true" *) reg                 sValid;
  reg                 ackSync1;
  reg                 ackSync2;
  reg                 validSync1;
  reg                 validSync2;
  reg        [1:0]    dData_resp;
  reg                 dPending;
  (* async_reg = "true" *) reg                 dAck;
  reg                 dMask;
  wire                io_enq_fire;
  wire                when_NpuAxiLiteCdc_l198;
  wire                when_NpuAxiLiteCdc_l201;
  wire                io_deq_fire;

  assign io_enq_ready = ((! sValid) && (! ackSync2));
  assign io_enq_fire = (io_enq_valid && io_enq_ready);
  assign when_NpuAxiLiteCdc_l198 = (validSync2 && (! dPending));
  assign when_NpuAxiLiteCdc_l201 = (! validSync2);
  assign io_deq_valid = (dPending && (! dMask));
  assign io_deq_payload_resp = dData_resp;
  assign io_deq_fire = (io_deq_valid && io_deq_ready);
  always @(posedge io_sClk or negedge io_sRstn) begin
    if(!io_sRstn) begin
      sValid <= 1'b0;
      ackSync1 <= 1'b0;
      ackSync2 <= 1'b0;
    end else begin
      ackSync1 <= dAck;
      ackSync2 <= ackSync1;
      if(io_enq_fire) begin
        sValid <= 1'b1;
      end else begin
        if(ackSync2) begin
          sValid <= 1'b0;
        end
      end
    end
  end

  always @(posedge io_dClk or negedge io_dRstn) begin
    if(!io_dRstn) begin
      validSync1 <= 1'b0;
      validSync2 <= 1'b0;
      dPending <= 1'b0;
      dAck <= 1'b0;
      dMask <= 1'b0;
    end else begin
      validSync1 <= sValid;
      validSync2 <= validSync1;
      if(when_NpuAxiLiteCdc_l198) begin
        dPending <= 1'b1;
      end else begin
        if(when_NpuAxiLiteCdc_l201) begin
          dPending <= 1'b0;
          dAck <= 1'b0;
          dMask <= 1'b0;
        end
      end
      if(io_deq_fire) begin
        dAck <= 1'b1;
        dMask <= 1'b1;
      end
    end
  end

  always @(posedge io_sClk) begin
    if(io_enq_fire) begin
      sData_resp <= io_enq_payload_resp;
    end
  end

  always @(posedge io_dClk) begin
    if(when_NpuAxiLiteCdc_l198) begin
      dData_resp <= sData_resp;
    end
  end


endmodule

module CdcPipeSp_1 (
  input  wire          io_sClk,
  input  wire          io_sRstn,
  input  wire          io_dClk,
  input  wire          io_dRstn,
  input  wire          io_enq_valid,
  output wire          io_enq_ready,
  input  wire [31:0]   io_enq_payload_data,
  input  wire [3:0]    io_enq_payload_strb,
  output wire          io_deq_valid,
  input  wire          io_deq_ready,
  output wire [31:0]   io_deq_payload_data,
  output wire [3:0]    io_deq_payload_strb
);

  (* async_reg = "true" *) reg        [31:0]   sData_data;
  (* async_reg = "true" *) reg        [3:0]    sData_strb;
  (* async_reg = "true" *) reg                 sValid;
  reg                 ackSync1;
  reg                 ackSync2;
  reg                 validSync1;
  reg                 validSync2;
  reg        [31:0]   dData_data;
  reg        [3:0]    dData_strb;
  reg                 dPending;
  (* async_reg = "true" *) reg                 dAck;
  reg                 dMask;
  wire                io_enq_fire;
  wire                when_NpuAxiLiteCdc_l198;
  wire                when_NpuAxiLiteCdc_l201;
  wire                io_deq_fire;

  assign io_enq_ready = ((! sValid) && (! ackSync2));
  assign io_enq_fire = (io_enq_valid && io_enq_ready);
  assign when_NpuAxiLiteCdc_l198 = (validSync2 && (! dPending));
  assign when_NpuAxiLiteCdc_l201 = (! validSync2);
  assign io_deq_valid = (dPending && (! dMask));
  assign io_deq_payload_data = dData_data;
  assign io_deq_payload_strb = dData_strb;
  assign io_deq_fire = (io_deq_valid && io_deq_ready);
  always @(posedge io_sClk or negedge io_sRstn) begin
    if(!io_sRstn) begin
      sValid <= 1'b0;
      ackSync1 <= 1'b0;
      ackSync2 <= 1'b0;
    end else begin
      ackSync1 <= dAck;
      ackSync2 <= ackSync1;
      if(io_enq_fire) begin
        sValid <= 1'b1;
      end else begin
        if(ackSync2) begin
          sValid <= 1'b0;
        end
      end
    end
  end

  always @(posedge io_dClk or negedge io_dRstn) begin
    if(!io_dRstn) begin
      validSync1 <= 1'b0;
      validSync2 <= 1'b0;
      dPending <= 1'b0;
      dAck <= 1'b0;
      dMask <= 1'b0;
    end else begin
      validSync1 <= sValid;
      validSync2 <= validSync1;
      if(when_NpuAxiLiteCdc_l198) begin
        dPending <= 1'b1;
      end else begin
        if(when_NpuAxiLiteCdc_l201) begin
          dPending <= 1'b0;
          dAck <= 1'b0;
          dMask <= 1'b0;
        end
      end
      if(io_deq_fire) begin
        dAck <= 1'b1;
        dMask <= 1'b1;
      end
    end
  end

  always @(posedge io_sClk) begin
    if(io_enq_fire) begin
      sData_data <= io_enq_payload_data;
      sData_strb <= io_enq_payload_strb;
    end
  end

  always @(posedge io_dClk) begin
    if(when_NpuAxiLiteCdc_l198) begin
      dData_data <= sData_data;
      dData_strb <= sData_strb;
    end
  end


endmodule

module CdcPipeSp (
  input  wire          io_sClk,
  input  wire          io_sRstn,
  input  wire          io_dClk,
  input  wire          io_dRstn,
  input  wire          io_enq_valid,
  output wire          io_enq_ready,
  input  wire [31:0]   io_enq_payload_addr,
  input  wire [2:0]    io_enq_payload_prot,
  output wire          io_deq_valid,
  input  wire          io_deq_ready,
  output wire [31:0]   io_deq_payload_addr,
  output wire [2:0]    io_deq_payload_prot
);

  (* async_reg = "true" *) reg        [31:0]   sData_addr;
  (* async_reg = "true" *) reg        [2:0]    sData_prot;
  (* async_reg = "true" *) reg                 sValid;
  reg                 ackSync1;
  reg                 ackSync2;
  reg                 validSync1;
  reg                 validSync2;
  reg        [31:0]   dData_addr;
  reg        [2:0]    dData_prot;
  reg                 dPending;
  (* async_reg = "true" *) reg                 dAck;
  reg                 dMask;
  wire                io_enq_fire;
  wire                when_NpuAxiLiteCdc_l198;
  wire                when_NpuAxiLiteCdc_l201;
  wire                io_deq_fire;

  assign io_enq_ready = ((! sValid) && (! ackSync2));
  assign io_enq_fire = (io_enq_valid && io_enq_ready);
  assign when_NpuAxiLiteCdc_l198 = (validSync2 && (! dPending));
  assign when_NpuAxiLiteCdc_l201 = (! validSync2);
  assign io_deq_valid = (dPending && (! dMask));
  assign io_deq_payload_addr = dData_addr;
  assign io_deq_payload_prot = dData_prot;
  assign io_deq_fire = (io_deq_valid && io_deq_ready);
  always @(posedge io_sClk or negedge io_sRstn) begin
    if(!io_sRstn) begin
      sValid <= 1'b0;
      ackSync1 <= 1'b0;
      ackSync2 <= 1'b0;
    end else begin
      ackSync1 <= dAck;
      ackSync2 <= ackSync1;
      if(io_enq_fire) begin
        sValid <= 1'b1;
      end else begin
        if(ackSync2) begin
          sValid <= 1'b0;
        end
      end
    end
  end

  always @(posedge io_dClk or negedge io_dRstn) begin
    if(!io_dRstn) begin
      validSync1 <= 1'b0;
      validSync2 <= 1'b0;
      dPending <= 1'b0;
      dAck <= 1'b0;
      dMask <= 1'b0;
    end else begin
      validSync1 <= sValid;
      validSync2 <= validSync1;
      if(when_NpuAxiLiteCdc_l198) begin
        dPending <= 1'b1;
      end else begin
        if(when_NpuAxiLiteCdc_l201) begin
          dPending <= 1'b0;
          dAck <= 1'b0;
          dMask <= 1'b0;
        end
      end
      if(io_deq_fire) begin
        dAck <= 1'b1;
        dMask <= 1'b1;
      end
    end
  end

  always @(posedge io_sClk) begin
    if(io_enq_fire) begin
      sData_addr <= io_enq_payload_addr;
      sData_prot <= io_enq_payload_prot;
    end
  end

  always @(posedge io_dClk) begin
    if(when_NpuAxiLiteCdc_l198) begin
      dData_addr <= sData_addr;
      dData_prot <= sData_prot;
    end
  end


endmodule
