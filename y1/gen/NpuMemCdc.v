// Generator : SpinalHDL v1.15.0    git head : 05a01af3d3345aa0afcaad8e0186dde13a359db2
// Component : NpuMemCdc

`timescale 1ns/1ps

module NpuMemCdc (
  input  wire          cpuClk,
  input  wire          cpuRstn,
  input  wire          npuClk,
  input  wire          npuRstn,
  input  wire          npuMem_aw_valid,
  output wire          npuMem_aw_ready,
  input  wire [31:0]   npuMem_aw_payload_addr,
  input  wire [3:0]    npuMem_aw_payload_id,
  input  wire [7:0]    npuMem_aw_payload_len,
  input  wire [2:0]    npuMem_aw_payload_size,
  input  wire [1:0]    npuMem_aw_payload_burst,
  input  wire [3:0]    npuMem_aw_payload_cache,
  input  wire [2:0]    npuMem_aw_payload_prot,
  input  wire          npuMem_w_valid,
  output wire          npuMem_w_ready,
  input  wire [63:0]   npuMem_w_payload_data,
  input  wire [7:0]    npuMem_w_payload_strb,
  input  wire          npuMem_w_payload_last,
  output wire          npuMem_b_valid,
  input  wire          npuMem_b_ready,
  output wire [3:0]    npuMem_b_payload_id,
  output wire [1:0]    npuMem_b_payload_resp,
  input  wire          npuMem_ar_valid,
  output wire          npuMem_ar_ready,
  input  wire [31:0]   npuMem_ar_payload_addr,
  input  wire [3:0]    npuMem_ar_payload_id,
  input  wire [7:0]    npuMem_ar_payload_len,
  input  wire [2:0]    npuMem_ar_payload_size,
  input  wire [1:0]    npuMem_ar_payload_burst,
  input  wire [3:0]    npuMem_ar_payload_cache,
  input  wire [2:0]    npuMem_ar_payload_prot,
  output wire          npuMem_r_valid,
  input  wire          npuMem_r_ready,
  output wire [63:0]   npuMem_r_payload_data,
  output wire [3:0]    npuMem_r_payload_id,
  output wire [1:0]    npuMem_r_payload_resp,
  output wire          npuMem_r_payload_last,
  output wire          cpuMem_aw_valid,
  input  wire          cpuMem_aw_ready,
  output wire [31:0]   cpuMem_aw_payload_addr,
  output wire [3:0]    cpuMem_aw_payload_id,
  output wire [7:0]    cpuMem_aw_payload_len,
  output wire [2:0]    cpuMem_aw_payload_size,
  output wire [1:0]    cpuMem_aw_payload_burst,
  output wire [3:0]    cpuMem_aw_payload_cache,
  output wire [2:0]    cpuMem_aw_payload_prot,
  output wire          cpuMem_w_valid,
  input  wire          cpuMem_w_ready,
  output wire [63:0]   cpuMem_w_payload_data,
  output wire [7:0]    cpuMem_w_payload_strb,
  output wire          cpuMem_w_payload_last,
  input  wire          cpuMem_b_valid,
  output wire          cpuMem_b_ready,
  input  wire [3:0]    cpuMem_b_payload_id,
  input  wire [1:0]    cpuMem_b_payload_resp,
  output wire          cpuMem_ar_valid,
  input  wire          cpuMem_ar_ready,
  output wire [31:0]   cpuMem_ar_payload_addr,
  output wire [3:0]    cpuMem_ar_payload_id,
  output wire [7:0]    cpuMem_ar_payload_len,
  output wire [2:0]    cpuMem_ar_payload_size,
  output wire [1:0]    cpuMem_ar_payload_burst,
  output wire [3:0]    cpuMem_ar_payload_cache,
  output wire [2:0]    cpuMem_ar_payload_prot,
  input  wire          cpuMem_r_valid,
  output wire          cpuMem_r_ready,
  input  wire [63:0]   cpuMem_r_payload_data,
  input  wire [3:0]    cpuMem_r_payload_id,
  input  wire [1:0]    cpuMem_r_payload_resp,
  input  wire          cpuMem_r_payload_last
);

  wire                awPipe_io_enq_ready;
  wire                awPipe_io_deq_valid;
  wire       [31:0]   awPipe_io_deq_payload_addr;
  wire       [3:0]    awPipe_io_deq_payload_id;
  wire       [7:0]    awPipe_io_deq_payload_len;
  wire       [2:0]    awPipe_io_deq_payload_size;
  wire       [1:0]    awPipe_io_deq_payload_burst;
  wire       [3:0]    awPipe_io_deq_payload_cache;
  wire       [2:0]    awPipe_io_deq_payload_prot;
  wire                wPipe_io_enq_ready;
  wire                wPipe_io_deq_valid;
  wire       [63:0]   wPipe_io_deq_payload_data;
  wire       [7:0]    wPipe_io_deq_payload_strb;
  wire                wPipe_io_deq_payload_last;
  wire                bPipe_io_enq_ready;
  wire                bPipe_io_deq_valid;
  wire       [3:0]    bPipe_io_deq_payload_id;
  wire       [1:0]    bPipe_io_deq_payload_resp;
  wire                arPipe_io_enq_ready;
  wire                arPipe_io_deq_valid;
  wire       [31:0]   arPipe_io_deq_payload_addr;
  wire       [3:0]    arPipe_io_deq_payload_id;
  wire       [7:0]    arPipe_io_deq_payload_len;
  wire       [2:0]    arPipe_io_deq_payload_size;
  wire       [1:0]    arPipe_io_deq_payload_burst;
  wire       [3:0]    arPipe_io_deq_payload_cache;
  wire       [2:0]    arPipe_io_deq_payload_prot;
  wire                rPipe_io_enq_ready;
  wire                rPipe_io_deq_valid;
  wire       [63:0]   rPipe_io_deq_payload_data;
  wire       [3:0]    rPipe_io_deq_payload_id;
  wire       [1:0]    rPipe_io_deq_payload_resp;
  wire                rPipe_io_deq_payload_last;

  NpuMemCdcFifoAddr awPipe (
    .io_sClk              (npuClk                          ), //i
    .io_sRstn             (npuRstn                         ), //i
    .io_enq_valid         (npuMem_aw_valid                 ), //i
    .io_enq_ready         (awPipe_io_enq_ready             ), //o
    .io_enq_payload_addr  (npuMem_aw_payload_addr[31:0]    ), //i
    .io_enq_payload_id    (npuMem_aw_payload_id[3:0]       ), //i
    .io_enq_payload_len   (npuMem_aw_payload_len[7:0]      ), //i
    .io_enq_payload_size  (npuMem_aw_payload_size[2:0]     ), //i
    .io_enq_payload_burst (npuMem_aw_payload_burst[1:0]    ), //i
    .io_enq_payload_cache (npuMem_aw_payload_cache[3:0]    ), //i
    .io_enq_payload_prot  (npuMem_aw_payload_prot[2:0]     ), //i
    .io_dClk              (cpuClk                          ), //i
    .io_dRstn             (cpuRstn                         ), //i
    .io_deq_valid         (awPipe_io_deq_valid             ), //o
    .io_deq_ready         (cpuMem_aw_ready                 ), //i
    .io_deq_payload_addr  (awPipe_io_deq_payload_addr[31:0]), //o
    .io_deq_payload_id    (awPipe_io_deq_payload_id[3:0]   ), //o
    .io_deq_payload_len   (awPipe_io_deq_payload_len[7:0]  ), //o
    .io_deq_payload_size  (awPipe_io_deq_payload_size[2:0] ), //o
    .io_deq_payload_burst (awPipe_io_deq_payload_burst[1:0]), //o
    .io_deq_payload_cache (awPipe_io_deq_payload_cache[3:0]), //o
    .io_deq_payload_prot  (awPipe_io_deq_payload_prot[2:0] )  //o
  );
  NpuMemCdcFifoW wPipe (
    .io_sClk             (npuClk                         ), //i
    .io_sRstn            (npuRstn                        ), //i
    .io_enq_valid        (npuMem_w_valid                 ), //i
    .io_enq_ready        (wPipe_io_enq_ready             ), //o
    .io_enq_payload_data (npuMem_w_payload_data[63:0]    ), //i
    .io_enq_payload_strb (npuMem_w_payload_strb[7:0]     ), //i
    .io_enq_payload_last (npuMem_w_payload_last          ), //i
    .io_dClk             (cpuClk                         ), //i
    .io_dRstn            (cpuRstn                        ), //i
    .io_deq_valid        (wPipe_io_deq_valid             ), //o
    .io_deq_ready        (cpuMem_w_ready                 ), //i
    .io_deq_payload_data (wPipe_io_deq_payload_data[63:0]), //o
    .io_deq_payload_strb (wPipe_io_deq_payload_strb[7:0] ), //o
    .io_deq_payload_last (wPipe_io_deq_payload_last      )  //o
  );
  NpuMemCdcFifoB bPipe (
    .io_sClk             (cpuClk                        ), //i
    .io_sRstn            (cpuRstn                       ), //i
    .io_enq_valid        (cpuMem_b_valid                ), //i
    .io_enq_ready        (bPipe_io_enq_ready            ), //o
    .io_enq_payload_id   (cpuMem_b_payload_id[3:0]      ), //i
    .io_enq_payload_resp (cpuMem_b_payload_resp[1:0]    ), //i
    .io_dClk             (npuClk                        ), //i
    .io_dRstn            (npuRstn                       ), //i
    .io_deq_valid        (bPipe_io_deq_valid            ), //o
    .io_deq_ready        (npuMem_b_ready                ), //i
    .io_deq_payload_id   (bPipe_io_deq_payload_id[3:0]  ), //o
    .io_deq_payload_resp (bPipe_io_deq_payload_resp[1:0])  //o
  );
  NpuMemCdcFifoAddr arPipe (
    .io_sClk              (npuClk                          ), //i
    .io_sRstn             (npuRstn                         ), //i
    .io_enq_valid         (npuMem_ar_valid                 ), //i
    .io_enq_ready         (arPipe_io_enq_ready             ), //o
    .io_enq_payload_addr  (npuMem_ar_payload_addr[31:0]    ), //i
    .io_enq_payload_id    (npuMem_ar_payload_id[3:0]       ), //i
    .io_enq_payload_len   (npuMem_ar_payload_len[7:0]      ), //i
    .io_enq_payload_size  (npuMem_ar_payload_size[2:0]     ), //i
    .io_enq_payload_burst (npuMem_ar_payload_burst[1:0]    ), //i
    .io_enq_payload_cache (npuMem_ar_payload_cache[3:0]    ), //i
    .io_enq_payload_prot  (npuMem_ar_payload_prot[2:0]     ), //i
    .io_dClk              (cpuClk                          ), //i
    .io_dRstn             (cpuRstn                         ), //i
    .io_deq_valid         (arPipe_io_deq_valid             ), //o
    .io_deq_ready         (cpuMem_ar_ready                 ), //i
    .io_deq_payload_addr  (arPipe_io_deq_payload_addr[31:0]), //o
    .io_deq_payload_id    (arPipe_io_deq_payload_id[3:0]   ), //o
    .io_deq_payload_len   (arPipe_io_deq_payload_len[7:0]  ), //o
    .io_deq_payload_size  (arPipe_io_deq_payload_size[2:0] ), //o
    .io_deq_payload_burst (arPipe_io_deq_payload_burst[1:0]), //o
    .io_deq_payload_cache (arPipe_io_deq_payload_cache[3:0]), //o
    .io_deq_payload_prot  (arPipe_io_deq_payload_prot[2:0] )  //o
  );
  NpuMemCdcFifoR rPipe (
    .io_sClk             (cpuClk                         ), //i
    .io_sRstn            (cpuRstn                        ), //i
    .io_enq_valid        (cpuMem_r_valid                 ), //i
    .io_enq_ready        (rPipe_io_enq_ready             ), //o
    .io_enq_payload_data (cpuMem_r_payload_data[63:0]    ), //i
    .io_enq_payload_id   (cpuMem_r_payload_id[3:0]       ), //i
    .io_enq_payload_resp (cpuMem_r_payload_resp[1:0]     ), //i
    .io_enq_payload_last (cpuMem_r_payload_last          ), //i
    .io_dClk             (npuClk                         ), //i
    .io_dRstn            (npuRstn                        ), //i
    .io_deq_valid        (rPipe_io_deq_valid             ), //o
    .io_deq_ready        (npuMem_r_ready                 ), //i
    .io_deq_payload_data (rPipe_io_deq_payload_data[63:0]), //o
    .io_deq_payload_id   (rPipe_io_deq_payload_id[3:0]   ), //o
    .io_deq_payload_resp (rPipe_io_deq_payload_resp[1:0] ), //o
    .io_deq_payload_last (rPipe_io_deq_payload_last      )  //o
  );
  assign npuMem_aw_ready = awPipe_io_enq_ready;
  assign npuMem_w_ready = wPipe_io_enq_ready;
  assign npuMem_b_valid = bPipe_io_deq_valid;
  assign npuMem_b_payload_id = bPipe_io_deq_payload_id;
  assign npuMem_b_payload_resp = bPipe_io_deq_payload_resp;
  assign npuMem_ar_ready = arPipe_io_enq_ready;
  assign npuMem_r_valid = rPipe_io_deq_valid;
  assign npuMem_r_payload_data = rPipe_io_deq_payload_data;
  assign npuMem_r_payload_id = rPipe_io_deq_payload_id;
  assign npuMem_r_payload_resp = rPipe_io_deq_payload_resp;
  assign npuMem_r_payload_last = rPipe_io_deq_payload_last;
  assign cpuMem_aw_valid = awPipe_io_deq_valid;
  assign cpuMem_aw_payload_addr = awPipe_io_deq_payload_addr;
  assign cpuMem_aw_payload_id = awPipe_io_deq_payload_id;
  assign cpuMem_aw_payload_len = awPipe_io_deq_payload_len;
  assign cpuMem_aw_payload_size = awPipe_io_deq_payload_size;
  assign cpuMem_aw_payload_burst = awPipe_io_deq_payload_burst;
  assign cpuMem_aw_payload_cache = awPipe_io_deq_payload_cache;
  assign cpuMem_aw_payload_prot = awPipe_io_deq_payload_prot;
  assign cpuMem_w_valid = wPipe_io_deq_valid;
  assign cpuMem_w_payload_data = wPipe_io_deq_payload_data;
  assign cpuMem_w_payload_strb = wPipe_io_deq_payload_strb;
  assign cpuMem_w_payload_last = wPipe_io_deq_payload_last;
  assign cpuMem_b_ready = bPipe_io_enq_ready;
  assign cpuMem_ar_valid = arPipe_io_deq_valid;
  assign cpuMem_ar_payload_addr = arPipe_io_deq_payload_addr;
  assign cpuMem_ar_payload_id = arPipe_io_deq_payload_id;
  assign cpuMem_ar_payload_len = arPipe_io_deq_payload_len;
  assign cpuMem_ar_payload_size = arPipe_io_deq_payload_size;
  assign cpuMem_ar_payload_burst = arPipe_io_deq_payload_burst;
  assign cpuMem_ar_payload_cache = arPipe_io_deq_payload_cache;
  assign cpuMem_ar_payload_prot = arPipe_io_deq_payload_prot;
  assign cpuMem_r_ready = rPipe_io_enq_ready;

endmodule

module NpuMemCdcFifoR (
  input  wire          io_sClk,
  input  wire          io_sRstn,
  input  wire          io_enq_valid,
  output wire          io_enq_ready,
  input  wire [63:0]   io_enq_payload_data,
  input  wire [3:0]    io_enq_payload_id,
  input  wire [1:0]    io_enq_payload_resp,
  input  wire          io_enq_payload_last,
  input  wire          io_dClk,
  input  wire          io_dRstn,
  output wire          io_deq_valid,
  input  wire          io_deq_ready,
  output wire [63:0]   io_deq_payload_data,
  output wire [3:0]    io_deq_payload_id,
  output wire [1:0]    io_deq_payload_resp,
  output wire          io_deq_payload_last
);

  wire                pipes_0_io_enq_valid;
  wire                pipes_0_io_deq_ready;
  wire                pipes_1_io_enq_valid;
  wire                pipes_1_io_deq_ready;
  wire                pipes_2_io_enq_valid;
  wire                pipes_2_io_deq_ready;
  wire                pipes_3_io_enq_valid;
  wire                pipes_3_io_deq_ready;
  wire                pipes_0_io_enq_ready;
  wire                pipes_0_io_deq_valid;
  wire       [63:0]   pipes_0_io_deq_payload_data;
  wire       [3:0]    pipes_0_io_deq_payload_id;
  wire       [1:0]    pipes_0_io_deq_payload_resp;
  wire                pipes_0_io_deq_payload_last;
  wire                pipes_1_io_enq_ready;
  wire                pipes_1_io_deq_valid;
  wire       [63:0]   pipes_1_io_deq_payload_data;
  wire       [3:0]    pipes_1_io_deq_payload_id;
  wire       [1:0]    pipes_1_io_deq_payload_resp;
  wire                pipes_1_io_deq_payload_last;
  wire                pipes_2_io_enq_ready;
  wire                pipes_2_io_deq_valid;
  wire       [63:0]   pipes_2_io_deq_payload_data;
  wire       [3:0]    pipes_2_io_deq_payload_id;
  wire       [1:0]    pipes_2_io_deq_payload_resp;
  wire                pipes_2_io_deq_payload_last;
  wire                pipes_3_io_enq_ready;
  wire                pipes_3_io_deq_valid;
  wire       [63:0]   pipes_3_io_deq_payload_data;
  wire       [3:0]    pipes_3_io_deq_payload_id;
  wire       [1:0]    pipes_3_io_deq_payload_resp;
  wire                pipes_3_io_deq_payload_last;
  wire       [3:0]    _zz_sWrIdx;
  wire       [3:0]    _zz_sWrIdx_1;
  wire       [3:0]    _zz_sWrIdx_2;
  reg        [63:0]   _zz__zz_io_enq_payload_data;
  reg        [3:0]    _zz__zz_io_enq_payload_id;
  reg        [1:0]    _zz__zz_io_enq_payload_resp;
  reg                 _zz__zz_io_enq_payload_last;
  reg                 _zz_sDisFire;
  wire       [3:0]    _zz_sCount;
  wire       [1:0]    _zz_sLane;
  wire       [3:0]    _zz_dWrIdx;
  wire       [3:0]    _zz_dWrIdx_1;
  wire       [3:0]    _zz_dWrIdx_2;
  reg                 _zz_dCollect;
  reg                 _zz_dCollect_1;
  reg        [63:0]   _zz__zz_dMem_0_data;
  reg        [3:0]    _zz__zz_dMem_0_id;
  reg        [1:0]    _zz__zz_dMem_0_resp;
  reg                 _zz__zz_dMem_0_last;
  wire       [1:0]    _zz_dLane;
  reg        [63:0]   _zz_io_deq_payload_data;
  reg        [3:0]    _zz_io_deq_payload_id;
  reg        [1:0]    _zz_io_deq_payload_resp;
  reg                 _zz_io_deq_payload_last;
  wire       [3:0]    _zz_dCount;
  reg        [63:0]   sMem_0_data;
  reg        [3:0]    sMem_0_id;
  reg        [1:0]    sMem_0_resp;
  reg                 sMem_0_last;
  reg        [63:0]   sMem_1_data;
  reg        [3:0]    sMem_1_id;
  reg        [1:0]    sMem_1_resp;
  reg                 sMem_1_last;
  reg        [63:0]   sMem_2_data;
  reg        [3:0]    sMem_2_id;
  reg        [1:0]    sMem_2_resp;
  reg                 sMem_2_last;
  reg        [63:0]   sMem_3_data;
  reg        [3:0]    sMem_3_id;
  reg        [1:0]    sMem_3_resp;
  reg                 sMem_3_last;
  reg        [63:0]   sMem_4_data;
  reg        [3:0]    sMem_4_id;
  reg        [1:0]    sMem_4_resp;
  reg                 sMem_4_last;
  reg        [63:0]   sMem_5_data;
  reg        [3:0]    sMem_5_id;
  reg        [1:0]    sMem_5_resp;
  reg                 sMem_5_last;
  reg        [63:0]   sMem_6_data;
  reg        [3:0]    sMem_6_id;
  reg        [1:0]    sMem_6_resp;
  reg                 sMem_6_last;
  reg        [63:0]   sMem_7_data;
  reg        [3:0]    sMem_7_id;
  reg        [1:0]    sMem_7_resp;
  reg                 sMem_7_last;
  reg        [2:0]    sHead;
  reg        [3:0]    sCount;
  reg        [1:0]    sLane;
  wire       [3:0]    sMask;
  wire       [1:0]    lMask;
  wire       [2:0]    sWrIdx;
  wire       [63:0]   _zz_io_enq_payload_data;
  wire       [3:0]    _zz_io_enq_payload_id;
  wire       [1:0]    _zz_io_enq_payload_resp;
  wire                _zz_io_enq_payload_last;
  wire                sEnqFire;
  wire                sDisFire;
  wire       [7:0]    _zz_1;
  wire                _zz_2;
  wire                _zz_3;
  wire                _zz_4;
  wire                _zz_5;
  wire                _zz_6;
  wire                _zz_7;
  wire                _zz_8;
  wire                _zz_9;
  reg        [63:0]   dMem_0_data;
  reg        [3:0]    dMem_0_id;
  reg        [1:0]    dMem_0_resp;
  reg                 dMem_0_last;
  reg        [63:0]   dMem_1_data;
  reg        [3:0]    dMem_1_id;
  reg        [1:0]    dMem_1_resp;
  reg                 dMem_1_last;
  reg        [63:0]   dMem_2_data;
  reg        [3:0]    dMem_2_id;
  reg        [1:0]    dMem_2_resp;
  reg                 dMem_2_last;
  reg        [63:0]   dMem_3_data;
  reg        [3:0]    dMem_3_id;
  reg        [1:0]    dMem_3_resp;
  reg                 dMem_3_last;
  reg        [63:0]   dMem_4_data;
  reg        [3:0]    dMem_4_id;
  reg        [1:0]    dMem_4_resp;
  reg                 dMem_4_last;
  reg        [63:0]   dMem_5_data;
  reg        [3:0]    dMem_5_id;
  reg        [1:0]    dMem_5_resp;
  reg                 dMem_5_last;
  reg        [63:0]   dMem_6_data;
  reg        [3:0]    dMem_6_id;
  reg        [1:0]    dMem_6_resp;
  reg                 dMem_6_last;
  reg        [63:0]   dMem_7_data;
  reg        [3:0]    dMem_7_id;
  reg        [1:0]    dMem_7_resp;
  reg                 dMem_7_last;
  reg        [2:0]    dTail;
  reg        [3:0]    dCount;
  reg        [1:0]    dLane;
  reg                 dTaken_0;
  reg                 dTaken_1;
  reg                 dTaken_2;
  reg                 dTaken_3;
  wire       [3:0]    dMask;
  wire       [2:0]    dWrIdx;
  wire       [3:0]    _zz_10;
  wire                dCollect;
  wire                when_NpuMemCdcFifo_l91;
  wire                when_NpuMemCdcFifo_l91_1;
  wire                when_NpuMemCdcFifo_l91_2;
  wire                when_NpuMemCdcFifo_l91_3;
  wire       [7:0]    _zz_11;
  wire                _zz_12;
  wire                _zz_13;
  wire                _zz_14;
  wire                _zz_15;
  wire                _zz_16;
  wire                _zz_17;
  wire                _zz_18;
  wire                _zz_19;
  wire       [63:0]   _zz_dMem_0_data;
  wire       [3:0]    _zz_dMem_0_id;
  wire       [1:0]    _zz_dMem_0_resp;
  wire                _zz_dMem_0_last;
  wire                dDeqFire;

  assign _zz_sWrIdx = (_zz_sWrIdx_1 & sMask);
  assign _zz_sWrIdx_1 = (_zz_sWrIdx_2 + sCount);
  assign _zz_sWrIdx_2 = {1'd0, sHead};
  assign _zz_sCount = (sCount + (sEnqFire ? 4'b0001 : 4'b0000));
  assign _zz_sLane = (sLane + 2'b01);
  assign _zz_dWrIdx = (_zz_dWrIdx_1 & dMask);
  assign _zz_dWrIdx_1 = (_zz_dWrIdx_2 + dCount);
  assign _zz_dWrIdx_2 = {1'd0, dTail};
  assign _zz_dLane = (dLane + 2'b01);
  assign _zz_dCount = (dCount + (dCollect ? 4'b0001 : 4'b0000));
  NpuMemCdcFifoPipeR pipes_0 (
    .io_sClk             (io_sClk                          ), //i
    .io_sRstn            (io_sRstn                         ), //i
    .io_dClk             (io_dClk                          ), //i
    .io_dRstn            (io_dRstn                         ), //i
    .io_enq_valid        (pipes_0_io_enq_valid             ), //i
    .io_enq_ready        (pipes_0_io_enq_ready             ), //o
    .io_enq_payload_data (_zz_io_enq_payload_data[63:0]    ), //i
    .io_enq_payload_id   (_zz_io_enq_payload_id[3:0]       ), //i
    .io_enq_payload_resp (_zz_io_enq_payload_resp[1:0]     ), //i
    .io_enq_payload_last (_zz_io_enq_payload_last          ), //i
    .io_deq_valid        (pipes_0_io_deq_valid             ), //o
    .io_deq_ready        (pipes_0_io_deq_ready             ), //i
    .io_deq_payload_data (pipes_0_io_deq_payload_data[63:0]), //o
    .io_deq_payload_id   (pipes_0_io_deq_payload_id[3:0]   ), //o
    .io_deq_payload_resp (pipes_0_io_deq_payload_resp[1:0] ), //o
    .io_deq_payload_last (pipes_0_io_deq_payload_last      )  //o
  );
  NpuMemCdcFifoPipeR pipes_1 (
    .io_sClk             (io_sClk                          ), //i
    .io_sRstn            (io_sRstn                         ), //i
    .io_dClk             (io_dClk                          ), //i
    .io_dRstn            (io_dRstn                         ), //i
    .io_enq_valid        (pipes_1_io_enq_valid             ), //i
    .io_enq_ready        (pipes_1_io_enq_ready             ), //o
    .io_enq_payload_data (_zz_io_enq_payload_data[63:0]    ), //i
    .io_enq_payload_id   (_zz_io_enq_payload_id[3:0]       ), //i
    .io_enq_payload_resp (_zz_io_enq_payload_resp[1:0]     ), //i
    .io_enq_payload_last (_zz_io_enq_payload_last          ), //i
    .io_deq_valid        (pipes_1_io_deq_valid             ), //o
    .io_deq_ready        (pipes_1_io_deq_ready             ), //i
    .io_deq_payload_data (pipes_1_io_deq_payload_data[63:0]), //o
    .io_deq_payload_id   (pipes_1_io_deq_payload_id[3:0]   ), //o
    .io_deq_payload_resp (pipes_1_io_deq_payload_resp[1:0] ), //o
    .io_deq_payload_last (pipes_1_io_deq_payload_last      )  //o
  );
  NpuMemCdcFifoPipeR pipes_2 (
    .io_sClk             (io_sClk                          ), //i
    .io_sRstn            (io_sRstn                         ), //i
    .io_dClk             (io_dClk                          ), //i
    .io_dRstn            (io_dRstn                         ), //i
    .io_enq_valid        (pipes_2_io_enq_valid             ), //i
    .io_enq_ready        (pipes_2_io_enq_ready             ), //o
    .io_enq_payload_data (_zz_io_enq_payload_data[63:0]    ), //i
    .io_enq_payload_id   (_zz_io_enq_payload_id[3:0]       ), //i
    .io_enq_payload_resp (_zz_io_enq_payload_resp[1:0]     ), //i
    .io_enq_payload_last (_zz_io_enq_payload_last          ), //i
    .io_deq_valid        (pipes_2_io_deq_valid             ), //o
    .io_deq_ready        (pipes_2_io_deq_ready             ), //i
    .io_deq_payload_data (pipes_2_io_deq_payload_data[63:0]), //o
    .io_deq_payload_id   (pipes_2_io_deq_payload_id[3:0]   ), //o
    .io_deq_payload_resp (pipes_2_io_deq_payload_resp[1:0] ), //o
    .io_deq_payload_last (pipes_2_io_deq_payload_last      )  //o
  );
  NpuMemCdcFifoPipeR pipes_3 (
    .io_sClk             (io_sClk                          ), //i
    .io_sRstn            (io_sRstn                         ), //i
    .io_dClk             (io_dClk                          ), //i
    .io_dRstn            (io_dRstn                         ), //i
    .io_enq_valid        (pipes_3_io_enq_valid             ), //i
    .io_enq_ready        (pipes_3_io_enq_ready             ), //o
    .io_enq_payload_data (_zz_io_enq_payload_data[63:0]    ), //i
    .io_enq_payload_id   (_zz_io_enq_payload_id[3:0]       ), //i
    .io_enq_payload_resp (_zz_io_enq_payload_resp[1:0]     ), //i
    .io_enq_payload_last (_zz_io_enq_payload_last          ), //i
    .io_deq_valid        (pipes_3_io_deq_valid             ), //o
    .io_deq_ready        (pipes_3_io_deq_ready             ), //i
    .io_deq_payload_data (pipes_3_io_deq_payload_data[63:0]), //o
    .io_deq_payload_id   (pipes_3_io_deq_payload_id[3:0]   ), //o
    .io_deq_payload_resp (pipes_3_io_deq_payload_resp[1:0] ), //o
    .io_deq_payload_last (pipes_3_io_deq_payload_last      )  //o
  );
  always @(*) begin
    case(sHead)
      3'b000 : begin
        _zz__zz_io_enq_payload_data = sMem_0_data;
        _zz__zz_io_enq_payload_id = sMem_0_id;
        _zz__zz_io_enq_payload_resp = sMem_0_resp;
        _zz__zz_io_enq_payload_last = sMem_0_last;
      end
      3'b001 : begin
        _zz__zz_io_enq_payload_data = sMem_1_data;
        _zz__zz_io_enq_payload_id = sMem_1_id;
        _zz__zz_io_enq_payload_resp = sMem_1_resp;
        _zz__zz_io_enq_payload_last = sMem_1_last;
      end
      3'b010 : begin
        _zz__zz_io_enq_payload_data = sMem_2_data;
        _zz__zz_io_enq_payload_id = sMem_2_id;
        _zz__zz_io_enq_payload_resp = sMem_2_resp;
        _zz__zz_io_enq_payload_last = sMem_2_last;
      end
      3'b011 : begin
        _zz__zz_io_enq_payload_data = sMem_3_data;
        _zz__zz_io_enq_payload_id = sMem_3_id;
        _zz__zz_io_enq_payload_resp = sMem_3_resp;
        _zz__zz_io_enq_payload_last = sMem_3_last;
      end
      3'b100 : begin
        _zz__zz_io_enq_payload_data = sMem_4_data;
        _zz__zz_io_enq_payload_id = sMem_4_id;
        _zz__zz_io_enq_payload_resp = sMem_4_resp;
        _zz__zz_io_enq_payload_last = sMem_4_last;
      end
      3'b101 : begin
        _zz__zz_io_enq_payload_data = sMem_5_data;
        _zz__zz_io_enq_payload_id = sMem_5_id;
        _zz__zz_io_enq_payload_resp = sMem_5_resp;
        _zz__zz_io_enq_payload_last = sMem_5_last;
      end
      3'b110 : begin
        _zz__zz_io_enq_payload_data = sMem_6_data;
        _zz__zz_io_enq_payload_id = sMem_6_id;
        _zz__zz_io_enq_payload_resp = sMem_6_resp;
        _zz__zz_io_enq_payload_last = sMem_6_last;
      end
      default : begin
        _zz__zz_io_enq_payload_data = sMem_7_data;
        _zz__zz_io_enq_payload_id = sMem_7_id;
        _zz__zz_io_enq_payload_resp = sMem_7_resp;
        _zz__zz_io_enq_payload_last = sMem_7_last;
      end
    endcase
  end

  always @(*) begin
    case(sLane)
      2'b00 : _zz_sDisFire = pipes_0_io_enq_ready;
      2'b01 : _zz_sDisFire = pipes_1_io_enq_ready;
      2'b10 : _zz_sDisFire = pipes_2_io_enq_ready;
      default : _zz_sDisFire = pipes_3_io_enq_ready;
    endcase
  end

  always @(*) begin
    case(dLane)
      2'b00 : begin
        _zz_dCollect = pipes_0_io_deq_valid;
        _zz_dCollect_1 = dTaken_0;
        _zz__zz_dMem_0_data = pipes_0_io_deq_payload_data;
        _zz__zz_dMem_0_id = pipes_0_io_deq_payload_id;
        _zz__zz_dMem_0_resp = pipes_0_io_deq_payload_resp;
        _zz__zz_dMem_0_last = pipes_0_io_deq_payload_last;
      end
      2'b01 : begin
        _zz_dCollect = pipes_1_io_deq_valid;
        _zz_dCollect_1 = dTaken_1;
        _zz__zz_dMem_0_data = pipes_1_io_deq_payload_data;
        _zz__zz_dMem_0_id = pipes_1_io_deq_payload_id;
        _zz__zz_dMem_0_resp = pipes_1_io_deq_payload_resp;
        _zz__zz_dMem_0_last = pipes_1_io_deq_payload_last;
      end
      2'b10 : begin
        _zz_dCollect = pipes_2_io_deq_valid;
        _zz_dCollect_1 = dTaken_2;
        _zz__zz_dMem_0_data = pipes_2_io_deq_payload_data;
        _zz__zz_dMem_0_id = pipes_2_io_deq_payload_id;
        _zz__zz_dMem_0_resp = pipes_2_io_deq_payload_resp;
        _zz__zz_dMem_0_last = pipes_2_io_deq_payload_last;
      end
      default : begin
        _zz_dCollect = pipes_3_io_deq_valid;
        _zz_dCollect_1 = dTaken_3;
        _zz__zz_dMem_0_data = pipes_3_io_deq_payload_data;
        _zz__zz_dMem_0_id = pipes_3_io_deq_payload_id;
        _zz__zz_dMem_0_resp = pipes_3_io_deq_payload_resp;
        _zz__zz_dMem_0_last = pipes_3_io_deq_payload_last;
      end
    endcase
  end

  always @(*) begin
    case(dTail)
      3'b000 : begin
        _zz_io_deq_payload_data = dMem_0_data;
        _zz_io_deq_payload_id = dMem_0_id;
        _zz_io_deq_payload_resp = dMem_0_resp;
        _zz_io_deq_payload_last = dMem_0_last;
      end
      3'b001 : begin
        _zz_io_deq_payload_data = dMem_1_data;
        _zz_io_deq_payload_id = dMem_1_id;
        _zz_io_deq_payload_resp = dMem_1_resp;
        _zz_io_deq_payload_last = dMem_1_last;
      end
      3'b010 : begin
        _zz_io_deq_payload_data = dMem_2_data;
        _zz_io_deq_payload_id = dMem_2_id;
        _zz_io_deq_payload_resp = dMem_2_resp;
        _zz_io_deq_payload_last = dMem_2_last;
      end
      3'b011 : begin
        _zz_io_deq_payload_data = dMem_3_data;
        _zz_io_deq_payload_id = dMem_3_id;
        _zz_io_deq_payload_resp = dMem_3_resp;
        _zz_io_deq_payload_last = dMem_3_last;
      end
      3'b100 : begin
        _zz_io_deq_payload_data = dMem_4_data;
        _zz_io_deq_payload_id = dMem_4_id;
        _zz_io_deq_payload_resp = dMem_4_resp;
        _zz_io_deq_payload_last = dMem_4_last;
      end
      3'b101 : begin
        _zz_io_deq_payload_data = dMem_5_data;
        _zz_io_deq_payload_id = dMem_5_id;
        _zz_io_deq_payload_resp = dMem_5_resp;
        _zz_io_deq_payload_last = dMem_5_last;
      end
      3'b110 : begin
        _zz_io_deq_payload_data = dMem_6_data;
        _zz_io_deq_payload_id = dMem_6_id;
        _zz_io_deq_payload_resp = dMem_6_resp;
        _zz_io_deq_payload_last = dMem_6_last;
      end
      default : begin
        _zz_io_deq_payload_data = dMem_7_data;
        _zz_io_deq_payload_id = dMem_7_id;
        _zz_io_deq_payload_resp = dMem_7_resp;
        _zz_io_deq_payload_last = dMem_7_last;
      end
    endcase
  end

  assign sMask = 4'b0111;
  assign lMask = 2'b11;
  assign sWrIdx = _zz_sWrIdx[2:0];
  assign io_enq_ready = (sCount != 4'b1000);
  assign pipes_0_io_enq_valid = ((sCount != 4'b0000) && (sLane == 2'b00));
  assign _zz_io_enq_payload_data = _zz__zz_io_enq_payload_data;
  assign _zz_io_enq_payload_id = _zz__zz_io_enq_payload_id;
  assign _zz_io_enq_payload_resp = _zz__zz_io_enq_payload_resp;
  assign _zz_io_enq_payload_last = _zz__zz_io_enq_payload_last;
  assign pipes_1_io_enq_valid = ((sCount != 4'b0000) && (sLane == 2'b01));
  assign pipes_2_io_enq_valid = ((sCount != 4'b0000) && (sLane == 2'b10));
  assign pipes_3_io_enq_valid = ((sCount != 4'b0000) && (sLane == 2'b11));
  assign sEnqFire = (io_enq_valid && io_enq_ready);
  assign sDisFire = ((sCount != 4'b0000) && _zz_sDisFire);
  assign _zz_1 = ({7'd0,1'b1} <<< sWrIdx);
  assign _zz_2 = _zz_1[0];
  assign _zz_3 = _zz_1[1];
  assign _zz_4 = _zz_1[2];
  assign _zz_5 = _zz_1[3];
  assign _zz_6 = _zz_1[4];
  assign _zz_7 = _zz_1[5];
  assign _zz_8 = _zz_1[6];
  assign _zz_9 = _zz_1[7];
  assign dMask = 4'b0111;
  assign dWrIdx = _zz_dWrIdx[2:0];
  assign _zz_10 = ({3'd0,1'b1} <<< dLane);
  assign dCollect = (((dCount != 4'b1000) && _zz_dCollect) && (! _zz_dCollect_1));
  assign pipes_0_io_deq_ready = ((((dLane == 2'b00) && pipes_0_io_deq_valid) && (! dTaken_0)) && (dCount != 4'b1000));
  assign when_NpuMemCdcFifo_l91 = (! pipes_0_io_deq_valid);
  assign pipes_1_io_deq_ready = ((((dLane == 2'b01) && pipes_1_io_deq_valid) && (! dTaken_1)) && (dCount != 4'b1000));
  assign when_NpuMemCdcFifo_l91_1 = (! pipes_1_io_deq_valid);
  assign pipes_2_io_deq_ready = ((((dLane == 2'b10) && pipes_2_io_deq_valid) && (! dTaken_2)) && (dCount != 4'b1000));
  assign when_NpuMemCdcFifo_l91_2 = (! pipes_2_io_deq_valid);
  assign pipes_3_io_deq_ready = ((((dLane == 2'b11) && pipes_3_io_deq_valid) && (! dTaken_3)) && (dCount != 4'b1000));
  assign when_NpuMemCdcFifo_l91_3 = (! pipes_3_io_deq_valid);
  assign _zz_11 = ({7'd0,1'b1} <<< dWrIdx);
  assign _zz_12 = _zz_11[0];
  assign _zz_13 = _zz_11[1];
  assign _zz_14 = _zz_11[2];
  assign _zz_15 = _zz_11[3];
  assign _zz_16 = _zz_11[4];
  assign _zz_17 = _zz_11[5];
  assign _zz_18 = _zz_11[6];
  assign _zz_19 = _zz_11[7];
  assign _zz_dMem_0_data = _zz__zz_dMem_0_data;
  assign _zz_dMem_0_id = _zz__zz_dMem_0_id;
  assign _zz_dMem_0_resp = _zz__zz_dMem_0_resp;
  assign _zz_dMem_0_last = _zz__zz_dMem_0_last;
  assign io_deq_valid = (dCount != 4'b0000);
  assign io_deq_payload_data = _zz_io_deq_payload_data;
  assign io_deq_payload_id = _zz_io_deq_payload_id;
  assign io_deq_payload_resp = _zz_io_deq_payload_resp;
  assign io_deq_payload_last = _zz_io_deq_payload_last;
  assign dDeqFire = (io_deq_valid && io_deq_ready);
  always @(posedge io_sClk or negedge io_sRstn) begin
    if(!io_sRstn) begin
      sHead <= 3'b000;
      sCount <= 4'b0000;
      sLane <= 2'b00;
    end else begin
      sCount <= (_zz_sCount - (sDisFire ? 4'b0001 : 4'b0000));
      if(sDisFire) begin
        sHead <= (sHead + 3'b001);
        sLane <= (_zz_sLane & lMask);
      end
    end
  end

  always @(posedge io_sClk) begin
    if(sEnqFire) begin
      if(_zz_2) begin
        sMem_0_data <= io_enq_payload_data;
      end
      if(_zz_3) begin
        sMem_1_data <= io_enq_payload_data;
      end
      if(_zz_4) begin
        sMem_2_data <= io_enq_payload_data;
      end
      if(_zz_5) begin
        sMem_3_data <= io_enq_payload_data;
      end
      if(_zz_6) begin
        sMem_4_data <= io_enq_payload_data;
      end
      if(_zz_7) begin
        sMem_5_data <= io_enq_payload_data;
      end
      if(_zz_8) begin
        sMem_6_data <= io_enq_payload_data;
      end
      if(_zz_9) begin
        sMem_7_data <= io_enq_payload_data;
      end
      if(_zz_2) begin
        sMem_0_id <= io_enq_payload_id;
      end
      if(_zz_3) begin
        sMem_1_id <= io_enq_payload_id;
      end
      if(_zz_4) begin
        sMem_2_id <= io_enq_payload_id;
      end
      if(_zz_5) begin
        sMem_3_id <= io_enq_payload_id;
      end
      if(_zz_6) begin
        sMem_4_id <= io_enq_payload_id;
      end
      if(_zz_7) begin
        sMem_5_id <= io_enq_payload_id;
      end
      if(_zz_8) begin
        sMem_6_id <= io_enq_payload_id;
      end
      if(_zz_9) begin
        sMem_7_id <= io_enq_payload_id;
      end
      if(_zz_2) begin
        sMem_0_resp <= io_enq_payload_resp;
      end
      if(_zz_3) begin
        sMem_1_resp <= io_enq_payload_resp;
      end
      if(_zz_4) begin
        sMem_2_resp <= io_enq_payload_resp;
      end
      if(_zz_5) begin
        sMem_3_resp <= io_enq_payload_resp;
      end
      if(_zz_6) begin
        sMem_4_resp <= io_enq_payload_resp;
      end
      if(_zz_7) begin
        sMem_5_resp <= io_enq_payload_resp;
      end
      if(_zz_8) begin
        sMem_6_resp <= io_enq_payload_resp;
      end
      if(_zz_9) begin
        sMem_7_resp <= io_enq_payload_resp;
      end
      if(_zz_2) begin
        sMem_0_last <= io_enq_payload_last;
      end
      if(_zz_3) begin
        sMem_1_last <= io_enq_payload_last;
      end
      if(_zz_4) begin
        sMem_2_last <= io_enq_payload_last;
      end
      if(_zz_5) begin
        sMem_3_last <= io_enq_payload_last;
      end
      if(_zz_6) begin
        sMem_4_last <= io_enq_payload_last;
      end
      if(_zz_7) begin
        sMem_5_last <= io_enq_payload_last;
      end
      if(_zz_8) begin
        sMem_6_last <= io_enq_payload_last;
      end
      if(_zz_9) begin
        sMem_7_last <= io_enq_payload_last;
      end
    end
  end

  always @(posedge io_dClk or negedge io_dRstn) begin
    if(!io_dRstn) begin
      dTail <= 3'b000;
      dCount <= 4'b0000;
      dLane <= 2'b00;
      dTaken_0 <= 1'b0;
      dTaken_1 <= 1'b0;
      dTaken_2 <= 1'b0;
      dTaken_3 <= 1'b0;
    end else begin
      if(when_NpuMemCdcFifo_l91) begin
        dTaken_0 <= 1'b0;
      end
      if(when_NpuMemCdcFifo_l91_1) begin
        dTaken_1 <= 1'b0;
      end
      if(when_NpuMemCdcFifo_l91_2) begin
        dTaken_2 <= 1'b0;
      end
      if(when_NpuMemCdcFifo_l91_3) begin
        dTaken_3 <= 1'b0;
      end
      if(dCollect) begin
        dLane <= (_zz_dLane & lMask);
        if(_zz_10[0]) begin
          dTaken_0 <= 1'b1;
        end
        if(_zz_10[1]) begin
          dTaken_1 <= 1'b1;
        end
        if(_zz_10[2]) begin
          dTaken_2 <= 1'b1;
        end
        if(_zz_10[3]) begin
          dTaken_3 <= 1'b1;
        end
      end
      dCount <= (_zz_dCount - (dDeqFire ? 4'b0001 : 4'b0000));
      if(dDeqFire) begin
        dTail <= (dTail + 3'b001);
      end
    end
  end

  always @(posedge io_dClk) begin
    if(dCollect) begin
      if(_zz_12) begin
        dMem_0_data <= _zz_dMem_0_data;
      end
      if(_zz_13) begin
        dMem_1_data <= _zz_dMem_0_data;
      end
      if(_zz_14) begin
        dMem_2_data <= _zz_dMem_0_data;
      end
      if(_zz_15) begin
        dMem_3_data <= _zz_dMem_0_data;
      end
      if(_zz_16) begin
        dMem_4_data <= _zz_dMem_0_data;
      end
      if(_zz_17) begin
        dMem_5_data <= _zz_dMem_0_data;
      end
      if(_zz_18) begin
        dMem_6_data <= _zz_dMem_0_data;
      end
      if(_zz_19) begin
        dMem_7_data <= _zz_dMem_0_data;
      end
      if(_zz_12) begin
        dMem_0_id <= _zz_dMem_0_id;
      end
      if(_zz_13) begin
        dMem_1_id <= _zz_dMem_0_id;
      end
      if(_zz_14) begin
        dMem_2_id <= _zz_dMem_0_id;
      end
      if(_zz_15) begin
        dMem_3_id <= _zz_dMem_0_id;
      end
      if(_zz_16) begin
        dMem_4_id <= _zz_dMem_0_id;
      end
      if(_zz_17) begin
        dMem_5_id <= _zz_dMem_0_id;
      end
      if(_zz_18) begin
        dMem_6_id <= _zz_dMem_0_id;
      end
      if(_zz_19) begin
        dMem_7_id <= _zz_dMem_0_id;
      end
      if(_zz_12) begin
        dMem_0_resp <= _zz_dMem_0_resp;
      end
      if(_zz_13) begin
        dMem_1_resp <= _zz_dMem_0_resp;
      end
      if(_zz_14) begin
        dMem_2_resp <= _zz_dMem_0_resp;
      end
      if(_zz_15) begin
        dMem_3_resp <= _zz_dMem_0_resp;
      end
      if(_zz_16) begin
        dMem_4_resp <= _zz_dMem_0_resp;
      end
      if(_zz_17) begin
        dMem_5_resp <= _zz_dMem_0_resp;
      end
      if(_zz_18) begin
        dMem_6_resp <= _zz_dMem_0_resp;
      end
      if(_zz_19) begin
        dMem_7_resp <= _zz_dMem_0_resp;
      end
      if(_zz_12) begin
        dMem_0_last <= _zz_dMem_0_last;
      end
      if(_zz_13) begin
        dMem_1_last <= _zz_dMem_0_last;
      end
      if(_zz_14) begin
        dMem_2_last <= _zz_dMem_0_last;
      end
      if(_zz_15) begin
        dMem_3_last <= _zz_dMem_0_last;
      end
      if(_zz_16) begin
        dMem_4_last <= _zz_dMem_0_last;
      end
      if(_zz_17) begin
        dMem_5_last <= _zz_dMem_0_last;
      end
      if(_zz_18) begin
        dMem_6_last <= _zz_dMem_0_last;
      end
      if(_zz_19) begin
        dMem_7_last <= _zz_dMem_0_last;
      end
    end
  end


endmodule

//NpuMemCdcFifoAddr replaced by NpuMemCdcFifoAddr

module NpuMemCdcFifoB (
  input  wire          io_sClk,
  input  wire          io_sRstn,
  input  wire          io_enq_valid,
  output wire          io_enq_ready,
  input  wire [3:0]    io_enq_payload_id,
  input  wire [1:0]    io_enq_payload_resp,
  input  wire          io_dClk,
  input  wire          io_dRstn,
  output wire          io_deq_valid,
  input  wire          io_deq_ready,
  output wire [3:0]    io_deq_payload_id,
  output wire [1:0]    io_deq_payload_resp
);

  wire                pipes_0_io_enq_valid;
  wire                pipes_0_io_deq_ready;
  wire                pipes_1_io_enq_valid;
  wire                pipes_1_io_deq_ready;
  wire                pipes_2_io_enq_valid;
  wire                pipes_2_io_deq_ready;
  wire                pipes_3_io_enq_valid;
  wire                pipes_3_io_deq_ready;
  wire                pipes_0_io_enq_ready;
  wire                pipes_0_io_deq_valid;
  wire       [3:0]    pipes_0_io_deq_payload_id;
  wire       [1:0]    pipes_0_io_deq_payload_resp;
  wire                pipes_1_io_enq_ready;
  wire                pipes_1_io_deq_valid;
  wire       [3:0]    pipes_1_io_deq_payload_id;
  wire       [1:0]    pipes_1_io_deq_payload_resp;
  wire                pipes_2_io_enq_ready;
  wire                pipes_2_io_deq_valid;
  wire       [3:0]    pipes_2_io_deq_payload_id;
  wire       [1:0]    pipes_2_io_deq_payload_resp;
  wire                pipes_3_io_enq_ready;
  wire                pipes_3_io_deq_valid;
  wire       [3:0]    pipes_3_io_deq_payload_id;
  wire       [1:0]    pipes_3_io_deq_payload_resp;
  wire       [3:0]    _zz_sWrIdx;
  wire       [3:0]    _zz_sWrIdx_1;
  wire       [3:0]    _zz_sWrIdx_2;
  reg        [3:0]    _zz__zz_io_enq_payload_id;
  reg        [1:0]    _zz__zz_io_enq_payload_resp;
  reg                 _zz_sDisFire;
  wire       [3:0]    _zz_sCount;
  wire       [1:0]    _zz_sLane;
  wire       [3:0]    _zz_dWrIdx;
  wire       [3:0]    _zz_dWrIdx_1;
  wire       [3:0]    _zz_dWrIdx_2;
  reg                 _zz_dCollect;
  reg                 _zz_dCollect_1;
  reg        [3:0]    _zz__zz_dMem_0_id;
  reg        [1:0]    _zz__zz_dMem_0_resp;
  wire       [1:0]    _zz_dLane;
  reg        [3:0]    _zz_io_deq_payload_id;
  reg        [1:0]    _zz_io_deq_payload_resp;
  wire       [3:0]    _zz_dCount;
  reg        [3:0]    sMem_0_id;
  reg        [1:0]    sMem_0_resp;
  reg        [3:0]    sMem_1_id;
  reg        [1:0]    sMem_1_resp;
  reg        [3:0]    sMem_2_id;
  reg        [1:0]    sMem_2_resp;
  reg        [3:0]    sMem_3_id;
  reg        [1:0]    sMem_3_resp;
  reg        [3:0]    sMem_4_id;
  reg        [1:0]    sMem_4_resp;
  reg        [3:0]    sMem_5_id;
  reg        [1:0]    sMem_5_resp;
  reg        [3:0]    sMem_6_id;
  reg        [1:0]    sMem_6_resp;
  reg        [3:0]    sMem_7_id;
  reg        [1:0]    sMem_7_resp;
  reg        [2:0]    sHead;
  reg        [3:0]    sCount;
  reg        [1:0]    sLane;
  wire       [3:0]    sMask;
  wire       [1:0]    lMask;
  wire       [2:0]    sWrIdx;
  wire       [3:0]    _zz_io_enq_payload_id;
  wire       [1:0]    _zz_io_enq_payload_resp;
  wire                sEnqFire;
  wire                sDisFire;
  wire       [7:0]    _zz_1;
  wire                _zz_2;
  wire                _zz_3;
  wire                _zz_4;
  wire                _zz_5;
  wire                _zz_6;
  wire                _zz_7;
  wire                _zz_8;
  wire                _zz_9;
  reg        [3:0]    dMem_0_id;
  reg        [1:0]    dMem_0_resp;
  reg        [3:0]    dMem_1_id;
  reg        [1:0]    dMem_1_resp;
  reg        [3:0]    dMem_2_id;
  reg        [1:0]    dMem_2_resp;
  reg        [3:0]    dMem_3_id;
  reg        [1:0]    dMem_3_resp;
  reg        [3:0]    dMem_4_id;
  reg        [1:0]    dMem_4_resp;
  reg        [3:0]    dMem_5_id;
  reg        [1:0]    dMem_5_resp;
  reg        [3:0]    dMem_6_id;
  reg        [1:0]    dMem_6_resp;
  reg        [3:0]    dMem_7_id;
  reg        [1:0]    dMem_7_resp;
  reg        [2:0]    dTail;
  reg        [3:0]    dCount;
  reg        [1:0]    dLane;
  reg                 dTaken_0;
  reg                 dTaken_1;
  reg                 dTaken_2;
  reg                 dTaken_3;
  wire       [3:0]    dMask;
  wire       [2:0]    dWrIdx;
  wire       [3:0]    _zz_10;
  wire                dCollect;
  wire                when_NpuMemCdcFifo_l91;
  wire                when_NpuMemCdcFifo_l91_1;
  wire                when_NpuMemCdcFifo_l91_2;
  wire                when_NpuMemCdcFifo_l91_3;
  wire       [7:0]    _zz_11;
  wire                _zz_12;
  wire                _zz_13;
  wire                _zz_14;
  wire                _zz_15;
  wire                _zz_16;
  wire                _zz_17;
  wire                _zz_18;
  wire                _zz_19;
  wire       [3:0]    _zz_dMem_0_id;
  wire       [1:0]    _zz_dMem_0_resp;
  wire                dDeqFire;

  assign _zz_sWrIdx = (_zz_sWrIdx_1 & sMask);
  assign _zz_sWrIdx_1 = (_zz_sWrIdx_2 + sCount);
  assign _zz_sWrIdx_2 = {1'd0, sHead};
  assign _zz_sCount = (sCount + (sEnqFire ? 4'b0001 : 4'b0000));
  assign _zz_sLane = (sLane + 2'b01);
  assign _zz_dWrIdx = (_zz_dWrIdx_1 & dMask);
  assign _zz_dWrIdx_1 = (_zz_dWrIdx_2 + dCount);
  assign _zz_dWrIdx_2 = {1'd0, dTail};
  assign _zz_dLane = (dLane + 2'b01);
  assign _zz_dCount = (dCount + (dCollect ? 4'b0001 : 4'b0000));
  NpuMemCdcFifoPipeB pipes_0 (
    .io_sClk             (io_sClk                         ), //i
    .io_sRstn            (io_sRstn                        ), //i
    .io_dClk             (io_dClk                         ), //i
    .io_dRstn            (io_dRstn                        ), //i
    .io_enq_valid        (pipes_0_io_enq_valid            ), //i
    .io_enq_ready        (pipes_0_io_enq_ready            ), //o
    .io_enq_payload_id   (_zz_io_enq_payload_id[3:0]      ), //i
    .io_enq_payload_resp (_zz_io_enq_payload_resp[1:0]    ), //i
    .io_deq_valid        (pipes_0_io_deq_valid            ), //o
    .io_deq_ready        (pipes_0_io_deq_ready            ), //i
    .io_deq_payload_id   (pipes_0_io_deq_payload_id[3:0]  ), //o
    .io_deq_payload_resp (pipes_0_io_deq_payload_resp[1:0])  //o
  );
  NpuMemCdcFifoPipeB pipes_1 (
    .io_sClk             (io_sClk                         ), //i
    .io_sRstn            (io_sRstn                        ), //i
    .io_dClk             (io_dClk                         ), //i
    .io_dRstn            (io_dRstn                        ), //i
    .io_enq_valid        (pipes_1_io_enq_valid            ), //i
    .io_enq_ready        (pipes_1_io_enq_ready            ), //o
    .io_enq_payload_id   (_zz_io_enq_payload_id[3:0]      ), //i
    .io_enq_payload_resp (_zz_io_enq_payload_resp[1:0]    ), //i
    .io_deq_valid        (pipes_1_io_deq_valid            ), //o
    .io_deq_ready        (pipes_1_io_deq_ready            ), //i
    .io_deq_payload_id   (pipes_1_io_deq_payload_id[3:0]  ), //o
    .io_deq_payload_resp (pipes_1_io_deq_payload_resp[1:0])  //o
  );
  NpuMemCdcFifoPipeB pipes_2 (
    .io_sClk             (io_sClk                         ), //i
    .io_sRstn            (io_sRstn                        ), //i
    .io_dClk             (io_dClk                         ), //i
    .io_dRstn            (io_dRstn                        ), //i
    .io_enq_valid        (pipes_2_io_enq_valid            ), //i
    .io_enq_ready        (pipes_2_io_enq_ready            ), //o
    .io_enq_payload_id   (_zz_io_enq_payload_id[3:0]      ), //i
    .io_enq_payload_resp (_zz_io_enq_payload_resp[1:0]    ), //i
    .io_deq_valid        (pipes_2_io_deq_valid            ), //o
    .io_deq_ready        (pipes_2_io_deq_ready            ), //i
    .io_deq_payload_id   (pipes_2_io_deq_payload_id[3:0]  ), //o
    .io_deq_payload_resp (pipes_2_io_deq_payload_resp[1:0])  //o
  );
  NpuMemCdcFifoPipeB pipes_3 (
    .io_sClk             (io_sClk                         ), //i
    .io_sRstn            (io_sRstn                        ), //i
    .io_dClk             (io_dClk                         ), //i
    .io_dRstn            (io_dRstn                        ), //i
    .io_enq_valid        (pipes_3_io_enq_valid            ), //i
    .io_enq_ready        (pipes_3_io_enq_ready            ), //o
    .io_enq_payload_id   (_zz_io_enq_payload_id[3:0]      ), //i
    .io_enq_payload_resp (_zz_io_enq_payload_resp[1:0]    ), //i
    .io_deq_valid        (pipes_3_io_deq_valid            ), //o
    .io_deq_ready        (pipes_3_io_deq_ready            ), //i
    .io_deq_payload_id   (pipes_3_io_deq_payload_id[3:0]  ), //o
    .io_deq_payload_resp (pipes_3_io_deq_payload_resp[1:0])  //o
  );
  always @(*) begin
    case(sHead)
      3'b000 : begin
        _zz__zz_io_enq_payload_id = sMem_0_id;
        _zz__zz_io_enq_payload_resp = sMem_0_resp;
      end
      3'b001 : begin
        _zz__zz_io_enq_payload_id = sMem_1_id;
        _zz__zz_io_enq_payload_resp = sMem_1_resp;
      end
      3'b010 : begin
        _zz__zz_io_enq_payload_id = sMem_2_id;
        _zz__zz_io_enq_payload_resp = sMem_2_resp;
      end
      3'b011 : begin
        _zz__zz_io_enq_payload_id = sMem_3_id;
        _zz__zz_io_enq_payload_resp = sMem_3_resp;
      end
      3'b100 : begin
        _zz__zz_io_enq_payload_id = sMem_4_id;
        _zz__zz_io_enq_payload_resp = sMem_4_resp;
      end
      3'b101 : begin
        _zz__zz_io_enq_payload_id = sMem_5_id;
        _zz__zz_io_enq_payload_resp = sMem_5_resp;
      end
      3'b110 : begin
        _zz__zz_io_enq_payload_id = sMem_6_id;
        _zz__zz_io_enq_payload_resp = sMem_6_resp;
      end
      default : begin
        _zz__zz_io_enq_payload_id = sMem_7_id;
        _zz__zz_io_enq_payload_resp = sMem_7_resp;
      end
    endcase
  end

  always @(*) begin
    case(sLane)
      2'b00 : _zz_sDisFire = pipes_0_io_enq_ready;
      2'b01 : _zz_sDisFire = pipes_1_io_enq_ready;
      2'b10 : _zz_sDisFire = pipes_2_io_enq_ready;
      default : _zz_sDisFire = pipes_3_io_enq_ready;
    endcase
  end

  always @(*) begin
    case(dLane)
      2'b00 : begin
        _zz_dCollect = pipes_0_io_deq_valid;
        _zz_dCollect_1 = dTaken_0;
        _zz__zz_dMem_0_id = pipes_0_io_deq_payload_id;
        _zz__zz_dMem_0_resp = pipes_0_io_deq_payload_resp;
      end
      2'b01 : begin
        _zz_dCollect = pipes_1_io_deq_valid;
        _zz_dCollect_1 = dTaken_1;
        _zz__zz_dMem_0_id = pipes_1_io_deq_payload_id;
        _zz__zz_dMem_0_resp = pipes_1_io_deq_payload_resp;
      end
      2'b10 : begin
        _zz_dCollect = pipes_2_io_deq_valid;
        _zz_dCollect_1 = dTaken_2;
        _zz__zz_dMem_0_id = pipes_2_io_deq_payload_id;
        _zz__zz_dMem_0_resp = pipes_2_io_deq_payload_resp;
      end
      default : begin
        _zz_dCollect = pipes_3_io_deq_valid;
        _zz_dCollect_1 = dTaken_3;
        _zz__zz_dMem_0_id = pipes_3_io_deq_payload_id;
        _zz__zz_dMem_0_resp = pipes_3_io_deq_payload_resp;
      end
    endcase
  end

  always @(*) begin
    case(dTail)
      3'b000 : begin
        _zz_io_deq_payload_id = dMem_0_id;
        _zz_io_deq_payload_resp = dMem_0_resp;
      end
      3'b001 : begin
        _zz_io_deq_payload_id = dMem_1_id;
        _zz_io_deq_payload_resp = dMem_1_resp;
      end
      3'b010 : begin
        _zz_io_deq_payload_id = dMem_2_id;
        _zz_io_deq_payload_resp = dMem_2_resp;
      end
      3'b011 : begin
        _zz_io_deq_payload_id = dMem_3_id;
        _zz_io_deq_payload_resp = dMem_3_resp;
      end
      3'b100 : begin
        _zz_io_deq_payload_id = dMem_4_id;
        _zz_io_deq_payload_resp = dMem_4_resp;
      end
      3'b101 : begin
        _zz_io_deq_payload_id = dMem_5_id;
        _zz_io_deq_payload_resp = dMem_5_resp;
      end
      3'b110 : begin
        _zz_io_deq_payload_id = dMem_6_id;
        _zz_io_deq_payload_resp = dMem_6_resp;
      end
      default : begin
        _zz_io_deq_payload_id = dMem_7_id;
        _zz_io_deq_payload_resp = dMem_7_resp;
      end
    endcase
  end

  assign sMask = 4'b0111;
  assign lMask = 2'b11;
  assign sWrIdx = _zz_sWrIdx[2:0];
  assign io_enq_ready = (sCount != 4'b1000);
  assign pipes_0_io_enq_valid = ((sCount != 4'b0000) && (sLane == 2'b00));
  assign _zz_io_enq_payload_id = _zz__zz_io_enq_payload_id;
  assign _zz_io_enq_payload_resp = _zz__zz_io_enq_payload_resp;
  assign pipes_1_io_enq_valid = ((sCount != 4'b0000) && (sLane == 2'b01));
  assign pipes_2_io_enq_valid = ((sCount != 4'b0000) && (sLane == 2'b10));
  assign pipes_3_io_enq_valid = ((sCount != 4'b0000) && (sLane == 2'b11));
  assign sEnqFire = (io_enq_valid && io_enq_ready);
  assign sDisFire = ((sCount != 4'b0000) && _zz_sDisFire);
  assign _zz_1 = ({7'd0,1'b1} <<< sWrIdx);
  assign _zz_2 = _zz_1[0];
  assign _zz_3 = _zz_1[1];
  assign _zz_4 = _zz_1[2];
  assign _zz_5 = _zz_1[3];
  assign _zz_6 = _zz_1[4];
  assign _zz_7 = _zz_1[5];
  assign _zz_8 = _zz_1[6];
  assign _zz_9 = _zz_1[7];
  assign dMask = 4'b0111;
  assign dWrIdx = _zz_dWrIdx[2:0];
  assign _zz_10 = ({3'd0,1'b1} <<< dLane);
  assign dCollect = (((dCount != 4'b1000) && _zz_dCollect) && (! _zz_dCollect_1));
  assign pipes_0_io_deq_ready = ((((dLane == 2'b00) && pipes_0_io_deq_valid) && (! dTaken_0)) && (dCount != 4'b1000));
  assign when_NpuMemCdcFifo_l91 = (! pipes_0_io_deq_valid);
  assign pipes_1_io_deq_ready = ((((dLane == 2'b01) && pipes_1_io_deq_valid) && (! dTaken_1)) && (dCount != 4'b1000));
  assign when_NpuMemCdcFifo_l91_1 = (! pipes_1_io_deq_valid);
  assign pipes_2_io_deq_ready = ((((dLane == 2'b10) && pipes_2_io_deq_valid) && (! dTaken_2)) && (dCount != 4'b1000));
  assign when_NpuMemCdcFifo_l91_2 = (! pipes_2_io_deq_valid);
  assign pipes_3_io_deq_ready = ((((dLane == 2'b11) && pipes_3_io_deq_valid) && (! dTaken_3)) && (dCount != 4'b1000));
  assign when_NpuMemCdcFifo_l91_3 = (! pipes_3_io_deq_valid);
  assign _zz_11 = ({7'd0,1'b1} <<< dWrIdx);
  assign _zz_12 = _zz_11[0];
  assign _zz_13 = _zz_11[1];
  assign _zz_14 = _zz_11[2];
  assign _zz_15 = _zz_11[3];
  assign _zz_16 = _zz_11[4];
  assign _zz_17 = _zz_11[5];
  assign _zz_18 = _zz_11[6];
  assign _zz_19 = _zz_11[7];
  assign _zz_dMem_0_id = _zz__zz_dMem_0_id;
  assign _zz_dMem_0_resp = _zz__zz_dMem_0_resp;
  assign io_deq_valid = (dCount != 4'b0000);
  assign io_deq_payload_id = _zz_io_deq_payload_id;
  assign io_deq_payload_resp = _zz_io_deq_payload_resp;
  assign dDeqFire = (io_deq_valid && io_deq_ready);
  always @(posedge io_sClk or negedge io_sRstn) begin
    if(!io_sRstn) begin
      sHead <= 3'b000;
      sCount <= 4'b0000;
      sLane <= 2'b00;
    end else begin
      sCount <= (_zz_sCount - (sDisFire ? 4'b0001 : 4'b0000));
      if(sDisFire) begin
        sHead <= (sHead + 3'b001);
        sLane <= (_zz_sLane & lMask);
      end
    end
  end

  always @(posedge io_sClk) begin
    if(sEnqFire) begin
      if(_zz_2) begin
        sMem_0_id <= io_enq_payload_id;
      end
      if(_zz_3) begin
        sMem_1_id <= io_enq_payload_id;
      end
      if(_zz_4) begin
        sMem_2_id <= io_enq_payload_id;
      end
      if(_zz_5) begin
        sMem_3_id <= io_enq_payload_id;
      end
      if(_zz_6) begin
        sMem_4_id <= io_enq_payload_id;
      end
      if(_zz_7) begin
        sMem_5_id <= io_enq_payload_id;
      end
      if(_zz_8) begin
        sMem_6_id <= io_enq_payload_id;
      end
      if(_zz_9) begin
        sMem_7_id <= io_enq_payload_id;
      end
      if(_zz_2) begin
        sMem_0_resp <= io_enq_payload_resp;
      end
      if(_zz_3) begin
        sMem_1_resp <= io_enq_payload_resp;
      end
      if(_zz_4) begin
        sMem_2_resp <= io_enq_payload_resp;
      end
      if(_zz_5) begin
        sMem_3_resp <= io_enq_payload_resp;
      end
      if(_zz_6) begin
        sMem_4_resp <= io_enq_payload_resp;
      end
      if(_zz_7) begin
        sMem_5_resp <= io_enq_payload_resp;
      end
      if(_zz_8) begin
        sMem_6_resp <= io_enq_payload_resp;
      end
      if(_zz_9) begin
        sMem_7_resp <= io_enq_payload_resp;
      end
    end
  end

  always @(posedge io_dClk or negedge io_dRstn) begin
    if(!io_dRstn) begin
      dTail <= 3'b000;
      dCount <= 4'b0000;
      dLane <= 2'b00;
      dTaken_0 <= 1'b0;
      dTaken_1 <= 1'b0;
      dTaken_2 <= 1'b0;
      dTaken_3 <= 1'b0;
    end else begin
      if(when_NpuMemCdcFifo_l91) begin
        dTaken_0 <= 1'b0;
      end
      if(when_NpuMemCdcFifo_l91_1) begin
        dTaken_1 <= 1'b0;
      end
      if(when_NpuMemCdcFifo_l91_2) begin
        dTaken_2 <= 1'b0;
      end
      if(when_NpuMemCdcFifo_l91_3) begin
        dTaken_3 <= 1'b0;
      end
      if(dCollect) begin
        dLane <= (_zz_dLane & lMask);
        if(_zz_10[0]) begin
          dTaken_0 <= 1'b1;
        end
        if(_zz_10[1]) begin
          dTaken_1 <= 1'b1;
        end
        if(_zz_10[2]) begin
          dTaken_2 <= 1'b1;
        end
        if(_zz_10[3]) begin
          dTaken_3 <= 1'b1;
        end
      end
      dCount <= (_zz_dCount - (dDeqFire ? 4'b0001 : 4'b0000));
      if(dDeqFire) begin
        dTail <= (dTail + 3'b001);
      end
    end
  end

  always @(posedge io_dClk) begin
    if(dCollect) begin
      if(_zz_12) begin
        dMem_0_id <= _zz_dMem_0_id;
      end
      if(_zz_13) begin
        dMem_1_id <= _zz_dMem_0_id;
      end
      if(_zz_14) begin
        dMem_2_id <= _zz_dMem_0_id;
      end
      if(_zz_15) begin
        dMem_3_id <= _zz_dMem_0_id;
      end
      if(_zz_16) begin
        dMem_4_id <= _zz_dMem_0_id;
      end
      if(_zz_17) begin
        dMem_5_id <= _zz_dMem_0_id;
      end
      if(_zz_18) begin
        dMem_6_id <= _zz_dMem_0_id;
      end
      if(_zz_19) begin
        dMem_7_id <= _zz_dMem_0_id;
      end
      if(_zz_12) begin
        dMem_0_resp <= _zz_dMem_0_resp;
      end
      if(_zz_13) begin
        dMem_1_resp <= _zz_dMem_0_resp;
      end
      if(_zz_14) begin
        dMem_2_resp <= _zz_dMem_0_resp;
      end
      if(_zz_15) begin
        dMem_3_resp <= _zz_dMem_0_resp;
      end
      if(_zz_16) begin
        dMem_4_resp <= _zz_dMem_0_resp;
      end
      if(_zz_17) begin
        dMem_5_resp <= _zz_dMem_0_resp;
      end
      if(_zz_18) begin
        dMem_6_resp <= _zz_dMem_0_resp;
      end
      if(_zz_19) begin
        dMem_7_resp <= _zz_dMem_0_resp;
      end
    end
  end


endmodule

module NpuMemCdcFifoW (
  input  wire          io_sClk,
  input  wire          io_sRstn,
  input  wire          io_enq_valid,
  output wire          io_enq_ready,
  input  wire [63:0]   io_enq_payload_data,
  input  wire [7:0]    io_enq_payload_strb,
  input  wire          io_enq_payload_last,
  input  wire          io_dClk,
  input  wire          io_dRstn,
  output wire          io_deq_valid,
  input  wire          io_deq_ready,
  output wire [63:0]   io_deq_payload_data,
  output wire [7:0]    io_deq_payload_strb,
  output wire          io_deq_payload_last
);

  wire                pipes_0_io_enq_valid;
  wire                pipes_0_io_deq_ready;
  wire                pipes_1_io_enq_valid;
  wire                pipes_1_io_deq_ready;
  wire                pipes_2_io_enq_valid;
  wire                pipes_2_io_deq_ready;
  wire                pipes_3_io_enq_valid;
  wire                pipes_3_io_deq_ready;
  wire                pipes_0_io_enq_ready;
  wire                pipes_0_io_deq_valid;
  wire       [63:0]   pipes_0_io_deq_payload_data;
  wire       [7:0]    pipes_0_io_deq_payload_strb;
  wire                pipes_0_io_deq_payload_last;
  wire                pipes_1_io_enq_ready;
  wire                pipes_1_io_deq_valid;
  wire       [63:0]   pipes_1_io_deq_payload_data;
  wire       [7:0]    pipes_1_io_deq_payload_strb;
  wire                pipes_1_io_deq_payload_last;
  wire                pipes_2_io_enq_ready;
  wire                pipes_2_io_deq_valid;
  wire       [63:0]   pipes_2_io_deq_payload_data;
  wire       [7:0]    pipes_2_io_deq_payload_strb;
  wire                pipes_2_io_deq_payload_last;
  wire                pipes_3_io_enq_ready;
  wire                pipes_3_io_deq_valid;
  wire       [63:0]   pipes_3_io_deq_payload_data;
  wire       [7:0]    pipes_3_io_deq_payload_strb;
  wire                pipes_3_io_deq_payload_last;
  wire       [3:0]    _zz_sWrIdx;
  wire       [3:0]    _zz_sWrIdx_1;
  wire       [3:0]    _zz_sWrIdx_2;
  reg        [63:0]   _zz__zz_io_enq_payload_data;
  reg        [7:0]    _zz__zz_io_enq_payload_strb;
  reg                 _zz__zz_io_enq_payload_last;
  reg                 _zz_sDisFire;
  wire       [3:0]    _zz_sCount;
  wire       [1:0]    _zz_sLane;
  wire       [3:0]    _zz_dWrIdx;
  wire       [3:0]    _zz_dWrIdx_1;
  wire       [3:0]    _zz_dWrIdx_2;
  reg                 _zz_dCollect;
  reg                 _zz_dCollect_1;
  reg        [63:0]   _zz__zz_dMem_0_data;
  reg        [7:0]    _zz__zz_dMem_0_strb;
  reg                 _zz__zz_dMem_0_last;
  wire       [1:0]    _zz_dLane;
  reg        [63:0]   _zz_io_deq_payload_data;
  reg        [7:0]    _zz_io_deq_payload_strb;
  reg                 _zz_io_deq_payload_last;
  wire       [3:0]    _zz_dCount;
  reg        [63:0]   sMem_0_data;
  reg        [7:0]    sMem_0_strb;
  reg                 sMem_0_last;
  reg        [63:0]   sMem_1_data;
  reg        [7:0]    sMem_1_strb;
  reg                 sMem_1_last;
  reg        [63:0]   sMem_2_data;
  reg        [7:0]    sMem_2_strb;
  reg                 sMem_2_last;
  reg        [63:0]   sMem_3_data;
  reg        [7:0]    sMem_3_strb;
  reg                 sMem_3_last;
  reg        [63:0]   sMem_4_data;
  reg        [7:0]    sMem_4_strb;
  reg                 sMem_4_last;
  reg        [63:0]   sMem_5_data;
  reg        [7:0]    sMem_5_strb;
  reg                 sMem_5_last;
  reg        [63:0]   sMem_6_data;
  reg        [7:0]    sMem_6_strb;
  reg                 sMem_6_last;
  reg        [63:0]   sMem_7_data;
  reg        [7:0]    sMem_7_strb;
  reg                 sMem_7_last;
  reg        [2:0]    sHead;
  reg        [3:0]    sCount;
  reg        [1:0]    sLane;
  wire       [3:0]    sMask;
  wire       [1:0]    lMask;
  wire       [2:0]    sWrIdx;
  wire       [63:0]   _zz_io_enq_payload_data;
  wire       [7:0]    _zz_io_enq_payload_strb;
  wire                _zz_io_enq_payload_last;
  wire                sEnqFire;
  wire                sDisFire;
  wire       [7:0]    _zz_1;
  wire                _zz_2;
  wire                _zz_3;
  wire                _zz_4;
  wire                _zz_5;
  wire                _zz_6;
  wire                _zz_7;
  wire                _zz_8;
  wire                _zz_9;
  reg        [63:0]   dMem_0_data;
  reg        [7:0]    dMem_0_strb;
  reg                 dMem_0_last;
  reg        [63:0]   dMem_1_data;
  reg        [7:0]    dMem_1_strb;
  reg                 dMem_1_last;
  reg        [63:0]   dMem_2_data;
  reg        [7:0]    dMem_2_strb;
  reg                 dMem_2_last;
  reg        [63:0]   dMem_3_data;
  reg        [7:0]    dMem_3_strb;
  reg                 dMem_3_last;
  reg        [63:0]   dMem_4_data;
  reg        [7:0]    dMem_4_strb;
  reg                 dMem_4_last;
  reg        [63:0]   dMem_5_data;
  reg        [7:0]    dMem_5_strb;
  reg                 dMem_5_last;
  reg        [63:0]   dMem_6_data;
  reg        [7:0]    dMem_6_strb;
  reg                 dMem_6_last;
  reg        [63:0]   dMem_7_data;
  reg        [7:0]    dMem_7_strb;
  reg                 dMem_7_last;
  reg        [2:0]    dTail;
  reg        [3:0]    dCount;
  reg        [1:0]    dLane;
  reg                 dTaken_0;
  reg                 dTaken_1;
  reg                 dTaken_2;
  reg                 dTaken_3;
  wire       [3:0]    dMask;
  wire       [2:0]    dWrIdx;
  wire       [3:0]    _zz_10;
  wire                dCollect;
  wire                when_NpuMemCdcFifo_l91;
  wire                when_NpuMemCdcFifo_l91_1;
  wire                when_NpuMemCdcFifo_l91_2;
  wire                when_NpuMemCdcFifo_l91_3;
  wire       [7:0]    _zz_11;
  wire                _zz_12;
  wire                _zz_13;
  wire                _zz_14;
  wire                _zz_15;
  wire                _zz_16;
  wire                _zz_17;
  wire                _zz_18;
  wire                _zz_19;
  wire       [63:0]   _zz_dMem_0_data;
  wire       [7:0]    _zz_dMem_0_strb;
  wire                _zz_dMem_0_last;
  wire                dDeqFire;

  assign _zz_sWrIdx = (_zz_sWrIdx_1 & sMask);
  assign _zz_sWrIdx_1 = (_zz_sWrIdx_2 + sCount);
  assign _zz_sWrIdx_2 = {1'd0, sHead};
  assign _zz_sCount = (sCount + (sEnqFire ? 4'b0001 : 4'b0000));
  assign _zz_sLane = (sLane + 2'b01);
  assign _zz_dWrIdx = (_zz_dWrIdx_1 & dMask);
  assign _zz_dWrIdx_1 = (_zz_dWrIdx_2 + dCount);
  assign _zz_dWrIdx_2 = {1'd0, dTail};
  assign _zz_dLane = (dLane + 2'b01);
  assign _zz_dCount = (dCount + (dCollect ? 4'b0001 : 4'b0000));
  NpuMemCdcFifoPipeW pipes_0 (
    .io_sClk             (io_sClk                          ), //i
    .io_sRstn            (io_sRstn                         ), //i
    .io_dClk             (io_dClk                          ), //i
    .io_dRstn            (io_dRstn                         ), //i
    .io_enq_valid        (pipes_0_io_enq_valid             ), //i
    .io_enq_ready        (pipes_0_io_enq_ready             ), //o
    .io_enq_payload_data (_zz_io_enq_payload_data[63:0]    ), //i
    .io_enq_payload_strb (_zz_io_enq_payload_strb[7:0]     ), //i
    .io_enq_payload_last (_zz_io_enq_payload_last          ), //i
    .io_deq_valid        (pipes_0_io_deq_valid             ), //o
    .io_deq_ready        (pipes_0_io_deq_ready             ), //i
    .io_deq_payload_data (pipes_0_io_deq_payload_data[63:0]), //o
    .io_deq_payload_strb (pipes_0_io_deq_payload_strb[7:0] ), //o
    .io_deq_payload_last (pipes_0_io_deq_payload_last      )  //o
  );
  NpuMemCdcFifoPipeW pipes_1 (
    .io_sClk             (io_sClk                          ), //i
    .io_sRstn            (io_sRstn                         ), //i
    .io_dClk             (io_dClk                          ), //i
    .io_dRstn            (io_dRstn                         ), //i
    .io_enq_valid        (pipes_1_io_enq_valid             ), //i
    .io_enq_ready        (pipes_1_io_enq_ready             ), //o
    .io_enq_payload_data (_zz_io_enq_payload_data[63:0]    ), //i
    .io_enq_payload_strb (_zz_io_enq_payload_strb[7:0]     ), //i
    .io_enq_payload_last (_zz_io_enq_payload_last          ), //i
    .io_deq_valid        (pipes_1_io_deq_valid             ), //o
    .io_deq_ready        (pipes_1_io_deq_ready             ), //i
    .io_deq_payload_data (pipes_1_io_deq_payload_data[63:0]), //o
    .io_deq_payload_strb (pipes_1_io_deq_payload_strb[7:0] ), //o
    .io_deq_payload_last (pipes_1_io_deq_payload_last      )  //o
  );
  NpuMemCdcFifoPipeW pipes_2 (
    .io_sClk             (io_sClk                          ), //i
    .io_sRstn            (io_sRstn                         ), //i
    .io_dClk             (io_dClk                          ), //i
    .io_dRstn            (io_dRstn                         ), //i
    .io_enq_valid        (pipes_2_io_enq_valid             ), //i
    .io_enq_ready        (pipes_2_io_enq_ready             ), //o
    .io_enq_payload_data (_zz_io_enq_payload_data[63:0]    ), //i
    .io_enq_payload_strb (_zz_io_enq_payload_strb[7:0]     ), //i
    .io_enq_payload_last (_zz_io_enq_payload_last          ), //i
    .io_deq_valid        (pipes_2_io_deq_valid             ), //o
    .io_deq_ready        (pipes_2_io_deq_ready             ), //i
    .io_deq_payload_data (pipes_2_io_deq_payload_data[63:0]), //o
    .io_deq_payload_strb (pipes_2_io_deq_payload_strb[7:0] ), //o
    .io_deq_payload_last (pipes_2_io_deq_payload_last      )  //o
  );
  NpuMemCdcFifoPipeW pipes_3 (
    .io_sClk             (io_sClk                          ), //i
    .io_sRstn            (io_sRstn                         ), //i
    .io_dClk             (io_dClk                          ), //i
    .io_dRstn            (io_dRstn                         ), //i
    .io_enq_valid        (pipes_3_io_enq_valid             ), //i
    .io_enq_ready        (pipes_3_io_enq_ready             ), //o
    .io_enq_payload_data (_zz_io_enq_payload_data[63:0]    ), //i
    .io_enq_payload_strb (_zz_io_enq_payload_strb[7:0]     ), //i
    .io_enq_payload_last (_zz_io_enq_payload_last          ), //i
    .io_deq_valid        (pipes_3_io_deq_valid             ), //o
    .io_deq_ready        (pipes_3_io_deq_ready             ), //i
    .io_deq_payload_data (pipes_3_io_deq_payload_data[63:0]), //o
    .io_deq_payload_strb (pipes_3_io_deq_payload_strb[7:0] ), //o
    .io_deq_payload_last (pipes_3_io_deq_payload_last      )  //o
  );
  always @(*) begin
    case(sHead)
      3'b000 : begin
        _zz__zz_io_enq_payload_data = sMem_0_data;
        _zz__zz_io_enq_payload_strb = sMem_0_strb;
        _zz__zz_io_enq_payload_last = sMem_0_last;
      end
      3'b001 : begin
        _zz__zz_io_enq_payload_data = sMem_1_data;
        _zz__zz_io_enq_payload_strb = sMem_1_strb;
        _zz__zz_io_enq_payload_last = sMem_1_last;
      end
      3'b010 : begin
        _zz__zz_io_enq_payload_data = sMem_2_data;
        _zz__zz_io_enq_payload_strb = sMem_2_strb;
        _zz__zz_io_enq_payload_last = sMem_2_last;
      end
      3'b011 : begin
        _zz__zz_io_enq_payload_data = sMem_3_data;
        _zz__zz_io_enq_payload_strb = sMem_3_strb;
        _zz__zz_io_enq_payload_last = sMem_3_last;
      end
      3'b100 : begin
        _zz__zz_io_enq_payload_data = sMem_4_data;
        _zz__zz_io_enq_payload_strb = sMem_4_strb;
        _zz__zz_io_enq_payload_last = sMem_4_last;
      end
      3'b101 : begin
        _zz__zz_io_enq_payload_data = sMem_5_data;
        _zz__zz_io_enq_payload_strb = sMem_5_strb;
        _zz__zz_io_enq_payload_last = sMem_5_last;
      end
      3'b110 : begin
        _zz__zz_io_enq_payload_data = sMem_6_data;
        _zz__zz_io_enq_payload_strb = sMem_6_strb;
        _zz__zz_io_enq_payload_last = sMem_6_last;
      end
      default : begin
        _zz__zz_io_enq_payload_data = sMem_7_data;
        _zz__zz_io_enq_payload_strb = sMem_7_strb;
        _zz__zz_io_enq_payload_last = sMem_7_last;
      end
    endcase
  end

  always @(*) begin
    case(sLane)
      2'b00 : _zz_sDisFire = pipes_0_io_enq_ready;
      2'b01 : _zz_sDisFire = pipes_1_io_enq_ready;
      2'b10 : _zz_sDisFire = pipes_2_io_enq_ready;
      default : _zz_sDisFire = pipes_3_io_enq_ready;
    endcase
  end

  always @(*) begin
    case(dLane)
      2'b00 : begin
        _zz_dCollect = pipes_0_io_deq_valid;
        _zz_dCollect_1 = dTaken_0;
        _zz__zz_dMem_0_data = pipes_0_io_deq_payload_data;
        _zz__zz_dMem_0_strb = pipes_0_io_deq_payload_strb;
        _zz__zz_dMem_0_last = pipes_0_io_deq_payload_last;
      end
      2'b01 : begin
        _zz_dCollect = pipes_1_io_deq_valid;
        _zz_dCollect_1 = dTaken_1;
        _zz__zz_dMem_0_data = pipes_1_io_deq_payload_data;
        _zz__zz_dMem_0_strb = pipes_1_io_deq_payload_strb;
        _zz__zz_dMem_0_last = pipes_1_io_deq_payload_last;
      end
      2'b10 : begin
        _zz_dCollect = pipes_2_io_deq_valid;
        _zz_dCollect_1 = dTaken_2;
        _zz__zz_dMem_0_data = pipes_2_io_deq_payload_data;
        _zz__zz_dMem_0_strb = pipes_2_io_deq_payload_strb;
        _zz__zz_dMem_0_last = pipes_2_io_deq_payload_last;
      end
      default : begin
        _zz_dCollect = pipes_3_io_deq_valid;
        _zz_dCollect_1 = dTaken_3;
        _zz__zz_dMem_0_data = pipes_3_io_deq_payload_data;
        _zz__zz_dMem_0_strb = pipes_3_io_deq_payload_strb;
        _zz__zz_dMem_0_last = pipes_3_io_deq_payload_last;
      end
    endcase
  end

  always @(*) begin
    case(dTail)
      3'b000 : begin
        _zz_io_deq_payload_data = dMem_0_data;
        _zz_io_deq_payload_strb = dMem_0_strb;
        _zz_io_deq_payload_last = dMem_0_last;
      end
      3'b001 : begin
        _zz_io_deq_payload_data = dMem_1_data;
        _zz_io_deq_payload_strb = dMem_1_strb;
        _zz_io_deq_payload_last = dMem_1_last;
      end
      3'b010 : begin
        _zz_io_deq_payload_data = dMem_2_data;
        _zz_io_deq_payload_strb = dMem_2_strb;
        _zz_io_deq_payload_last = dMem_2_last;
      end
      3'b011 : begin
        _zz_io_deq_payload_data = dMem_3_data;
        _zz_io_deq_payload_strb = dMem_3_strb;
        _zz_io_deq_payload_last = dMem_3_last;
      end
      3'b100 : begin
        _zz_io_deq_payload_data = dMem_4_data;
        _zz_io_deq_payload_strb = dMem_4_strb;
        _zz_io_deq_payload_last = dMem_4_last;
      end
      3'b101 : begin
        _zz_io_deq_payload_data = dMem_5_data;
        _zz_io_deq_payload_strb = dMem_5_strb;
        _zz_io_deq_payload_last = dMem_5_last;
      end
      3'b110 : begin
        _zz_io_deq_payload_data = dMem_6_data;
        _zz_io_deq_payload_strb = dMem_6_strb;
        _zz_io_deq_payload_last = dMem_6_last;
      end
      default : begin
        _zz_io_deq_payload_data = dMem_7_data;
        _zz_io_deq_payload_strb = dMem_7_strb;
        _zz_io_deq_payload_last = dMem_7_last;
      end
    endcase
  end

  assign sMask = 4'b0111;
  assign lMask = 2'b11;
  assign sWrIdx = _zz_sWrIdx[2:0];
  assign io_enq_ready = (sCount != 4'b1000);
  assign pipes_0_io_enq_valid = ((sCount != 4'b0000) && (sLane == 2'b00));
  assign _zz_io_enq_payload_data = _zz__zz_io_enq_payload_data;
  assign _zz_io_enq_payload_strb = _zz__zz_io_enq_payload_strb;
  assign _zz_io_enq_payload_last = _zz__zz_io_enq_payload_last;
  assign pipes_1_io_enq_valid = ((sCount != 4'b0000) && (sLane == 2'b01));
  assign pipes_2_io_enq_valid = ((sCount != 4'b0000) && (sLane == 2'b10));
  assign pipes_3_io_enq_valid = ((sCount != 4'b0000) && (sLane == 2'b11));
  assign sEnqFire = (io_enq_valid && io_enq_ready);
  assign sDisFire = ((sCount != 4'b0000) && _zz_sDisFire);
  assign _zz_1 = ({7'd0,1'b1} <<< sWrIdx);
  assign _zz_2 = _zz_1[0];
  assign _zz_3 = _zz_1[1];
  assign _zz_4 = _zz_1[2];
  assign _zz_5 = _zz_1[3];
  assign _zz_6 = _zz_1[4];
  assign _zz_7 = _zz_1[5];
  assign _zz_8 = _zz_1[6];
  assign _zz_9 = _zz_1[7];
  assign dMask = 4'b0111;
  assign dWrIdx = _zz_dWrIdx[2:0];
  assign _zz_10 = ({3'd0,1'b1} <<< dLane);
  assign dCollect = (((dCount != 4'b1000) && _zz_dCollect) && (! _zz_dCollect_1));
  assign pipes_0_io_deq_ready = ((((dLane == 2'b00) && pipes_0_io_deq_valid) && (! dTaken_0)) && (dCount != 4'b1000));
  assign when_NpuMemCdcFifo_l91 = (! pipes_0_io_deq_valid);
  assign pipes_1_io_deq_ready = ((((dLane == 2'b01) && pipes_1_io_deq_valid) && (! dTaken_1)) && (dCount != 4'b1000));
  assign when_NpuMemCdcFifo_l91_1 = (! pipes_1_io_deq_valid);
  assign pipes_2_io_deq_ready = ((((dLane == 2'b10) && pipes_2_io_deq_valid) && (! dTaken_2)) && (dCount != 4'b1000));
  assign when_NpuMemCdcFifo_l91_2 = (! pipes_2_io_deq_valid);
  assign pipes_3_io_deq_ready = ((((dLane == 2'b11) && pipes_3_io_deq_valid) && (! dTaken_3)) && (dCount != 4'b1000));
  assign when_NpuMemCdcFifo_l91_3 = (! pipes_3_io_deq_valid);
  assign _zz_11 = ({7'd0,1'b1} <<< dWrIdx);
  assign _zz_12 = _zz_11[0];
  assign _zz_13 = _zz_11[1];
  assign _zz_14 = _zz_11[2];
  assign _zz_15 = _zz_11[3];
  assign _zz_16 = _zz_11[4];
  assign _zz_17 = _zz_11[5];
  assign _zz_18 = _zz_11[6];
  assign _zz_19 = _zz_11[7];
  assign _zz_dMem_0_data = _zz__zz_dMem_0_data;
  assign _zz_dMem_0_strb = _zz__zz_dMem_0_strb;
  assign _zz_dMem_0_last = _zz__zz_dMem_0_last;
  assign io_deq_valid = (dCount != 4'b0000);
  assign io_deq_payload_data = _zz_io_deq_payload_data;
  assign io_deq_payload_strb = _zz_io_deq_payload_strb;
  assign io_deq_payload_last = _zz_io_deq_payload_last;
  assign dDeqFire = (io_deq_valid && io_deq_ready);
  always @(posedge io_sClk or negedge io_sRstn) begin
    if(!io_sRstn) begin
      sHead <= 3'b000;
      sCount <= 4'b0000;
      sLane <= 2'b00;
    end else begin
      sCount <= (_zz_sCount - (sDisFire ? 4'b0001 : 4'b0000));
      if(sDisFire) begin
        sHead <= (sHead + 3'b001);
        sLane <= (_zz_sLane & lMask);
      end
    end
  end

  always @(posedge io_sClk) begin
    if(sEnqFire) begin
      if(_zz_2) begin
        sMem_0_data <= io_enq_payload_data;
      end
      if(_zz_3) begin
        sMem_1_data <= io_enq_payload_data;
      end
      if(_zz_4) begin
        sMem_2_data <= io_enq_payload_data;
      end
      if(_zz_5) begin
        sMem_3_data <= io_enq_payload_data;
      end
      if(_zz_6) begin
        sMem_4_data <= io_enq_payload_data;
      end
      if(_zz_7) begin
        sMem_5_data <= io_enq_payload_data;
      end
      if(_zz_8) begin
        sMem_6_data <= io_enq_payload_data;
      end
      if(_zz_9) begin
        sMem_7_data <= io_enq_payload_data;
      end
      if(_zz_2) begin
        sMem_0_strb <= io_enq_payload_strb;
      end
      if(_zz_3) begin
        sMem_1_strb <= io_enq_payload_strb;
      end
      if(_zz_4) begin
        sMem_2_strb <= io_enq_payload_strb;
      end
      if(_zz_5) begin
        sMem_3_strb <= io_enq_payload_strb;
      end
      if(_zz_6) begin
        sMem_4_strb <= io_enq_payload_strb;
      end
      if(_zz_7) begin
        sMem_5_strb <= io_enq_payload_strb;
      end
      if(_zz_8) begin
        sMem_6_strb <= io_enq_payload_strb;
      end
      if(_zz_9) begin
        sMem_7_strb <= io_enq_payload_strb;
      end
      if(_zz_2) begin
        sMem_0_last <= io_enq_payload_last;
      end
      if(_zz_3) begin
        sMem_1_last <= io_enq_payload_last;
      end
      if(_zz_4) begin
        sMem_2_last <= io_enq_payload_last;
      end
      if(_zz_5) begin
        sMem_3_last <= io_enq_payload_last;
      end
      if(_zz_6) begin
        sMem_4_last <= io_enq_payload_last;
      end
      if(_zz_7) begin
        sMem_5_last <= io_enq_payload_last;
      end
      if(_zz_8) begin
        sMem_6_last <= io_enq_payload_last;
      end
      if(_zz_9) begin
        sMem_7_last <= io_enq_payload_last;
      end
    end
  end

  always @(posedge io_dClk or negedge io_dRstn) begin
    if(!io_dRstn) begin
      dTail <= 3'b000;
      dCount <= 4'b0000;
      dLane <= 2'b00;
      dTaken_0 <= 1'b0;
      dTaken_1 <= 1'b0;
      dTaken_2 <= 1'b0;
      dTaken_3 <= 1'b0;
    end else begin
      if(when_NpuMemCdcFifo_l91) begin
        dTaken_0 <= 1'b0;
      end
      if(when_NpuMemCdcFifo_l91_1) begin
        dTaken_1 <= 1'b0;
      end
      if(when_NpuMemCdcFifo_l91_2) begin
        dTaken_2 <= 1'b0;
      end
      if(when_NpuMemCdcFifo_l91_3) begin
        dTaken_3 <= 1'b0;
      end
      if(dCollect) begin
        dLane <= (_zz_dLane & lMask);
        if(_zz_10[0]) begin
          dTaken_0 <= 1'b1;
        end
        if(_zz_10[1]) begin
          dTaken_1 <= 1'b1;
        end
        if(_zz_10[2]) begin
          dTaken_2 <= 1'b1;
        end
        if(_zz_10[3]) begin
          dTaken_3 <= 1'b1;
        end
      end
      dCount <= (_zz_dCount - (dDeqFire ? 4'b0001 : 4'b0000));
      if(dDeqFire) begin
        dTail <= (dTail + 3'b001);
      end
    end
  end

  always @(posedge io_dClk) begin
    if(dCollect) begin
      if(_zz_12) begin
        dMem_0_data <= _zz_dMem_0_data;
      end
      if(_zz_13) begin
        dMem_1_data <= _zz_dMem_0_data;
      end
      if(_zz_14) begin
        dMem_2_data <= _zz_dMem_0_data;
      end
      if(_zz_15) begin
        dMem_3_data <= _zz_dMem_0_data;
      end
      if(_zz_16) begin
        dMem_4_data <= _zz_dMem_0_data;
      end
      if(_zz_17) begin
        dMem_5_data <= _zz_dMem_0_data;
      end
      if(_zz_18) begin
        dMem_6_data <= _zz_dMem_0_data;
      end
      if(_zz_19) begin
        dMem_7_data <= _zz_dMem_0_data;
      end
      if(_zz_12) begin
        dMem_0_strb <= _zz_dMem_0_strb;
      end
      if(_zz_13) begin
        dMem_1_strb <= _zz_dMem_0_strb;
      end
      if(_zz_14) begin
        dMem_2_strb <= _zz_dMem_0_strb;
      end
      if(_zz_15) begin
        dMem_3_strb <= _zz_dMem_0_strb;
      end
      if(_zz_16) begin
        dMem_4_strb <= _zz_dMem_0_strb;
      end
      if(_zz_17) begin
        dMem_5_strb <= _zz_dMem_0_strb;
      end
      if(_zz_18) begin
        dMem_6_strb <= _zz_dMem_0_strb;
      end
      if(_zz_19) begin
        dMem_7_strb <= _zz_dMem_0_strb;
      end
      if(_zz_12) begin
        dMem_0_last <= _zz_dMem_0_last;
      end
      if(_zz_13) begin
        dMem_1_last <= _zz_dMem_0_last;
      end
      if(_zz_14) begin
        dMem_2_last <= _zz_dMem_0_last;
      end
      if(_zz_15) begin
        dMem_3_last <= _zz_dMem_0_last;
      end
      if(_zz_16) begin
        dMem_4_last <= _zz_dMem_0_last;
      end
      if(_zz_17) begin
        dMem_5_last <= _zz_dMem_0_last;
      end
      if(_zz_18) begin
        dMem_6_last <= _zz_dMem_0_last;
      end
      if(_zz_19) begin
        dMem_7_last <= _zz_dMem_0_last;
      end
    end
  end


endmodule

module NpuMemCdcFifoAddr (
  input  wire          io_sClk,
  input  wire          io_sRstn,
  input  wire          io_enq_valid,
  output wire          io_enq_ready,
  input  wire [31:0]   io_enq_payload_addr,
  input  wire [3:0]    io_enq_payload_id,
  input  wire [7:0]    io_enq_payload_len,
  input  wire [2:0]    io_enq_payload_size,
  input  wire [1:0]    io_enq_payload_burst,
  input  wire [3:0]    io_enq_payload_cache,
  input  wire [2:0]    io_enq_payload_prot,
  input  wire          io_dClk,
  input  wire          io_dRstn,
  output wire          io_deq_valid,
  input  wire          io_deq_ready,
  output wire [31:0]   io_deq_payload_addr,
  output wire [3:0]    io_deq_payload_id,
  output wire [7:0]    io_deq_payload_len,
  output wire [2:0]    io_deq_payload_size,
  output wire [1:0]    io_deq_payload_burst,
  output wire [3:0]    io_deq_payload_cache,
  output wire [2:0]    io_deq_payload_prot
);

  wire                pipes_0_io_enq_valid;
  wire                pipes_0_io_deq_ready;
  wire                pipes_1_io_enq_valid;
  wire                pipes_1_io_deq_ready;
  wire                pipes_2_io_enq_valid;
  wire                pipes_2_io_deq_ready;
  wire                pipes_3_io_enq_valid;
  wire                pipes_3_io_deq_ready;
  wire                pipes_0_io_enq_ready;
  wire                pipes_0_io_deq_valid;
  wire       [31:0]   pipes_0_io_deq_payload_addr;
  wire       [3:0]    pipes_0_io_deq_payload_id;
  wire       [7:0]    pipes_0_io_deq_payload_len;
  wire       [2:0]    pipes_0_io_deq_payload_size;
  wire       [1:0]    pipes_0_io_deq_payload_burst;
  wire       [3:0]    pipes_0_io_deq_payload_cache;
  wire       [2:0]    pipes_0_io_deq_payload_prot;
  wire                pipes_1_io_enq_ready;
  wire                pipes_1_io_deq_valid;
  wire       [31:0]   pipes_1_io_deq_payload_addr;
  wire       [3:0]    pipes_1_io_deq_payload_id;
  wire       [7:0]    pipes_1_io_deq_payload_len;
  wire       [2:0]    pipes_1_io_deq_payload_size;
  wire       [1:0]    pipes_1_io_deq_payload_burst;
  wire       [3:0]    pipes_1_io_deq_payload_cache;
  wire       [2:0]    pipes_1_io_deq_payload_prot;
  wire                pipes_2_io_enq_ready;
  wire                pipes_2_io_deq_valid;
  wire       [31:0]   pipes_2_io_deq_payload_addr;
  wire       [3:0]    pipes_2_io_deq_payload_id;
  wire       [7:0]    pipes_2_io_deq_payload_len;
  wire       [2:0]    pipes_2_io_deq_payload_size;
  wire       [1:0]    pipes_2_io_deq_payload_burst;
  wire       [3:0]    pipes_2_io_deq_payload_cache;
  wire       [2:0]    pipes_2_io_deq_payload_prot;
  wire                pipes_3_io_enq_ready;
  wire                pipes_3_io_deq_valid;
  wire       [31:0]   pipes_3_io_deq_payload_addr;
  wire       [3:0]    pipes_3_io_deq_payload_id;
  wire       [7:0]    pipes_3_io_deq_payload_len;
  wire       [2:0]    pipes_3_io_deq_payload_size;
  wire       [1:0]    pipes_3_io_deq_payload_burst;
  wire       [3:0]    pipes_3_io_deq_payload_cache;
  wire       [2:0]    pipes_3_io_deq_payload_prot;
  wire       [3:0]    _zz_sWrIdx;
  wire       [3:0]    _zz_sWrIdx_1;
  wire       [3:0]    _zz_sWrIdx_2;
  reg        [31:0]   _zz__zz_io_enq_payload_addr;
  reg        [3:0]    _zz__zz_io_enq_payload_id;
  reg        [7:0]    _zz__zz_io_enq_payload_len;
  reg        [2:0]    _zz__zz_io_enq_payload_size;
  reg        [1:0]    _zz__zz_io_enq_payload_burst;
  reg        [3:0]    _zz__zz_io_enq_payload_cache;
  reg        [2:0]    _zz__zz_io_enq_payload_prot;
  reg                 _zz_sDisFire;
  wire       [3:0]    _zz_sCount;
  wire       [1:0]    _zz_sLane;
  wire       [3:0]    _zz_dWrIdx;
  wire       [3:0]    _zz_dWrIdx_1;
  wire       [3:0]    _zz_dWrIdx_2;
  reg                 _zz_dCollect;
  reg                 _zz_dCollect_1;
  reg        [31:0]   _zz__zz_dMem_0_addr;
  reg        [3:0]    _zz__zz_dMem_0_id;
  reg        [7:0]    _zz__zz_dMem_0_len;
  reg        [2:0]    _zz__zz_dMem_0_size;
  reg        [1:0]    _zz__zz_dMem_0_burst;
  reg        [3:0]    _zz__zz_dMem_0_cache;
  reg        [2:0]    _zz__zz_dMem_0_prot;
  wire       [1:0]    _zz_dLane;
  reg        [31:0]   _zz_io_deq_payload_addr;
  reg        [3:0]    _zz_io_deq_payload_id;
  reg        [7:0]    _zz_io_deq_payload_len;
  reg        [2:0]    _zz_io_deq_payload_size;
  reg        [1:0]    _zz_io_deq_payload_burst;
  reg        [3:0]    _zz_io_deq_payload_cache;
  reg        [2:0]    _zz_io_deq_payload_prot;
  wire       [3:0]    _zz_dCount;
  reg        [31:0]   sMem_0_addr;
  reg        [3:0]    sMem_0_id;
  reg        [7:0]    sMem_0_len;
  reg        [2:0]    sMem_0_size;
  reg        [1:0]    sMem_0_burst;
  reg        [3:0]    sMem_0_cache;
  reg        [2:0]    sMem_0_prot;
  reg        [31:0]   sMem_1_addr;
  reg        [3:0]    sMem_1_id;
  reg        [7:0]    sMem_1_len;
  reg        [2:0]    sMem_1_size;
  reg        [1:0]    sMem_1_burst;
  reg        [3:0]    sMem_1_cache;
  reg        [2:0]    sMem_1_prot;
  reg        [31:0]   sMem_2_addr;
  reg        [3:0]    sMem_2_id;
  reg        [7:0]    sMem_2_len;
  reg        [2:0]    sMem_2_size;
  reg        [1:0]    sMem_2_burst;
  reg        [3:0]    sMem_2_cache;
  reg        [2:0]    sMem_2_prot;
  reg        [31:0]   sMem_3_addr;
  reg        [3:0]    sMem_3_id;
  reg        [7:0]    sMem_3_len;
  reg        [2:0]    sMem_3_size;
  reg        [1:0]    sMem_3_burst;
  reg        [3:0]    sMem_3_cache;
  reg        [2:0]    sMem_3_prot;
  reg        [31:0]   sMem_4_addr;
  reg        [3:0]    sMem_4_id;
  reg        [7:0]    sMem_4_len;
  reg        [2:0]    sMem_4_size;
  reg        [1:0]    sMem_4_burst;
  reg        [3:0]    sMem_4_cache;
  reg        [2:0]    sMem_4_prot;
  reg        [31:0]   sMem_5_addr;
  reg        [3:0]    sMem_5_id;
  reg        [7:0]    sMem_5_len;
  reg        [2:0]    sMem_5_size;
  reg        [1:0]    sMem_5_burst;
  reg        [3:0]    sMem_5_cache;
  reg        [2:0]    sMem_5_prot;
  reg        [31:0]   sMem_6_addr;
  reg        [3:0]    sMem_6_id;
  reg        [7:0]    sMem_6_len;
  reg        [2:0]    sMem_6_size;
  reg        [1:0]    sMem_6_burst;
  reg        [3:0]    sMem_6_cache;
  reg        [2:0]    sMem_6_prot;
  reg        [31:0]   sMem_7_addr;
  reg        [3:0]    sMem_7_id;
  reg        [7:0]    sMem_7_len;
  reg        [2:0]    sMem_7_size;
  reg        [1:0]    sMem_7_burst;
  reg        [3:0]    sMem_7_cache;
  reg        [2:0]    sMem_7_prot;
  reg        [2:0]    sHead;
  reg        [3:0]    sCount;
  reg        [1:0]    sLane;
  wire       [3:0]    sMask;
  wire       [1:0]    lMask;
  wire       [2:0]    sWrIdx;
  wire       [31:0]   _zz_io_enq_payload_addr;
  wire       [3:0]    _zz_io_enq_payload_id;
  wire       [7:0]    _zz_io_enq_payload_len;
  wire       [2:0]    _zz_io_enq_payload_size;
  wire       [1:0]    _zz_io_enq_payload_burst;
  wire       [3:0]    _zz_io_enq_payload_cache;
  wire       [2:0]    _zz_io_enq_payload_prot;
  wire                sEnqFire;
  wire                sDisFire;
  wire       [7:0]    _zz_1;
  wire                _zz_2;
  wire                _zz_3;
  wire                _zz_4;
  wire                _zz_5;
  wire                _zz_6;
  wire                _zz_7;
  wire                _zz_8;
  wire                _zz_9;
  reg        [31:0]   dMem_0_addr;
  reg        [3:0]    dMem_0_id;
  reg        [7:0]    dMem_0_len;
  reg        [2:0]    dMem_0_size;
  reg        [1:0]    dMem_0_burst;
  reg        [3:0]    dMem_0_cache;
  reg        [2:0]    dMem_0_prot;
  reg        [31:0]   dMem_1_addr;
  reg        [3:0]    dMem_1_id;
  reg        [7:0]    dMem_1_len;
  reg        [2:0]    dMem_1_size;
  reg        [1:0]    dMem_1_burst;
  reg        [3:0]    dMem_1_cache;
  reg        [2:0]    dMem_1_prot;
  reg        [31:0]   dMem_2_addr;
  reg        [3:0]    dMem_2_id;
  reg        [7:0]    dMem_2_len;
  reg        [2:0]    dMem_2_size;
  reg        [1:0]    dMem_2_burst;
  reg        [3:0]    dMem_2_cache;
  reg        [2:0]    dMem_2_prot;
  reg        [31:0]   dMem_3_addr;
  reg        [3:0]    dMem_3_id;
  reg        [7:0]    dMem_3_len;
  reg        [2:0]    dMem_3_size;
  reg        [1:0]    dMem_3_burst;
  reg        [3:0]    dMem_3_cache;
  reg        [2:0]    dMem_3_prot;
  reg        [31:0]   dMem_4_addr;
  reg        [3:0]    dMem_4_id;
  reg        [7:0]    dMem_4_len;
  reg        [2:0]    dMem_4_size;
  reg        [1:0]    dMem_4_burst;
  reg        [3:0]    dMem_4_cache;
  reg        [2:0]    dMem_4_prot;
  reg        [31:0]   dMem_5_addr;
  reg        [3:0]    dMem_5_id;
  reg        [7:0]    dMem_5_len;
  reg        [2:0]    dMem_5_size;
  reg        [1:0]    dMem_5_burst;
  reg        [3:0]    dMem_5_cache;
  reg        [2:0]    dMem_5_prot;
  reg        [31:0]   dMem_6_addr;
  reg        [3:0]    dMem_6_id;
  reg        [7:0]    dMem_6_len;
  reg        [2:0]    dMem_6_size;
  reg        [1:0]    dMem_6_burst;
  reg        [3:0]    dMem_6_cache;
  reg        [2:0]    dMem_6_prot;
  reg        [31:0]   dMem_7_addr;
  reg        [3:0]    dMem_7_id;
  reg        [7:0]    dMem_7_len;
  reg        [2:0]    dMem_7_size;
  reg        [1:0]    dMem_7_burst;
  reg        [3:0]    dMem_7_cache;
  reg        [2:0]    dMem_7_prot;
  reg        [2:0]    dTail;
  reg        [3:0]    dCount;
  reg        [1:0]    dLane;
  reg                 dTaken_0;
  reg                 dTaken_1;
  reg                 dTaken_2;
  reg                 dTaken_3;
  wire       [3:0]    dMask;
  wire       [2:0]    dWrIdx;
  wire       [3:0]    _zz_10;
  wire                dCollect;
  wire                when_NpuMemCdcFifo_l91;
  wire                when_NpuMemCdcFifo_l91_1;
  wire                when_NpuMemCdcFifo_l91_2;
  wire                when_NpuMemCdcFifo_l91_3;
  wire       [7:0]    _zz_11;
  wire                _zz_12;
  wire                _zz_13;
  wire                _zz_14;
  wire                _zz_15;
  wire                _zz_16;
  wire                _zz_17;
  wire                _zz_18;
  wire                _zz_19;
  wire       [31:0]   _zz_dMem_0_addr;
  wire       [3:0]    _zz_dMem_0_id;
  wire       [7:0]    _zz_dMem_0_len;
  wire       [2:0]    _zz_dMem_0_size;
  wire       [1:0]    _zz_dMem_0_burst;
  wire       [3:0]    _zz_dMem_0_cache;
  wire       [2:0]    _zz_dMem_0_prot;
  wire                dDeqFire;

  assign _zz_sWrIdx = (_zz_sWrIdx_1 & sMask);
  assign _zz_sWrIdx_1 = (_zz_sWrIdx_2 + sCount);
  assign _zz_sWrIdx_2 = {1'd0, sHead};
  assign _zz_sCount = (sCount + (sEnqFire ? 4'b0001 : 4'b0000));
  assign _zz_sLane = (sLane + 2'b01);
  assign _zz_dWrIdx = (_zz_dWrIdx_1 & dMask);
  assign _zz_dWrIdx_1 = (_zz_dWrIdx_2 + dCount);
  assign _zz_dWrIdx_2 = {1'd0, dTail};
  assign _zz_dLane = (dLane + 2'b01);
  assign _zz_dCount = (dCount + (dCollect ? 4'b0001 : 4'b0000));
  NpuMemCdcFifoPipeAddr pipes_0 (
    .io_sClk              (io_sClk                          ), //i
    .io_sRstn             (io_sRstn                         ), //i
    .io_dClk              (io_dClk                          ), //i
    .io_dRstn             (io_dRstn                         ), //i
    .io_enq_valid         (pipes_0_io_enq_valid             ), //i
    .io_enq_ready         (pipes_0_io_enq_ready             ), //o
    .io_enq_payload_addr  (_zz_io_enq_payload_addr[31:0]    ), //i
    .io_enq_payload_id    (_zz_io_enq_payload_id[3:0]       ), //i
    .io_enq_payload_len   (_zz_io_enq_payload_len[7:0]      ), //i
    .io_enq_payload_size  (_zz_io_enq_payload_size[2:0]     ), //i
    .io_enq_payload_burst (_zz_io_enq_payload_burst[1:0]    ), //i
    .io_enq_payload_cache (_zz_io_enq_payload_cache[3:0]    ), //i
    .io_enq_payload_prot  (_zz_io_enq_payload_prot[2:0]     ), //i
    .io_deq_valid         (pipes_0_io_deq_valid             ), //o
    .io_deq_ready         (pipes_0_io_deq_ready             ), //i
    .io_deq_payload_addr  (pipes_0_io_deq_payload_addr[31:0]), //o
    .io_deq_payload_id    (pipes_0_io_deq_payload_id[3:0]   ), //o
    .io_deq_payload_len   (pipes_0_io_deq_payload_len[7:0]  ), //o
    .io_deq_payload_size  (pipes_0_io_deq_payload_size[2:0] ), //o
    .io_deq_payload_burst (pipes_0_io_deq_payload_burst[1:0]), //o
    .io_deq_payload_cache (pipes_0_io_deq_payload_cache[3:0]), //o
    .io_deq_payload_prot  (pipes_0_io_deq_payload_prot[2:0] )  //o
  );
  NpuMemCdcFifoPipeAddr pipes_1 (
    .io_sClk              (io_sClk                          ), //i
    .io_sRstn             (io_sRstn                         ), //i
    .io_dClk              (io_dClk                          ), //i
    .io_dRstn             (io_dRstn                         ), //i
    .io_enq_valid         (pipes_1_io_enq_valid             ), //i
    .io_enq_ready         (pipes_1_io_enq_ready             ), //o
    .io_enq_payload_addr  (_zz_io_enq_payload_addr[31:0]    ), //i
    .io_enq_payload_id    (_zz_io_enq_payload_id[3:0]       ), //i
    .io_enq_payload_len   (_zz_io_enq_payload_len[7:0]      ), //i
    .io_enq_payload_size  (_zz_io_enq_payload_size[2:0]     ), //i
    .io_enq_payload_burst (_zz_io_enq_payload_burst[1:0]    ), //i
    .io_enq_payload_cache (_zz_io_enq_payload_cache[3:0]    ), //i
    .io_enq_payload_prot  (_zz_io_enq_payload_prot[2:0]     ), //i
    .io_deq_valid         (pipes_1_io_deq_valid             ), //o
    .io_deq_ready         (pipes_1_io_deq_ready             ), //i
    .io_deq_payload_addr  (pipes_1_io_deq_payload_addr[31:0]), //o
    .io_deq_payload_id    (pipes_1_io_deq_payload_id[3:0]   ), //o
    .io_deq_payload_len   (pipes_1_io_deq_payload_len[7:0]  ), //o
    .io_deq_payload_size  (pipes_1_io_deq_payload_size[2:0] ), //o
    .io_deq_payload_burst (pipes_1_io_deq_payload_burst[1:0]), //o
    .io_deq_payload_cache (pipes_1_io_deq_payload_cache[3:0]), //o
    .io_deq_payload_prot  (pipes_1_io_deq_payload_prot[2:0] )  //o
  );
  NpuMemCdcFifoPipeAddr pipes_2 (
    .io_sClk              (io_sClk                          ), //i
    .io_sRstn             (io_sRstn                         ), //i
    .io_dClk              (io_dClk                          ), //i
    .io_dRstn             (io_dRstn                         ), //i
    .io_enq_valid         (pipes_2_io_enq_valid             ), //i
    .io_enq_ready         (pipes_2_io_enq_ready             ), //o
    .io_enq_payload_addr  (_zz_io_enq_payload_addr[31:0]    ), //i
    .io_enq_payload_id    (_zz_io_enq_payload_id[3:0]       ), //i
    .io_enq_payload_len   (_zz_io_enq_payload_len[7:0]      ), //i
    .io_enq_payload_size  (_zz_io_enq_payload_size[2:0]     ), //i
    .io_enq_payload_burst (_zz_io_enq_payload_burst[1:0]    ), //i
    .io_enq_payload_cache (_zz_io_enq_payload_cache[3:0]    ), //i
    .io_enq_payload_prot  (_zz_io_enq_payload_prot[2:0]     ), //i
    .io_deq_valid         (pipes_2_io_deq_valid             ), //o
    .io_deq_ready         (pipes_2_io_deq_ready             ), //i
    .io_deq_payload_addr  (pipes_2_io_deq_payload_addr[31:0]), //o
    .io_deq_payload_id    (pipes_2_io_deq_payload_id[3:0]   ), //o
    .io_deq_payload_len   (pipes_2_io_deq_payload_len[7:0]  ), //o
    .io_deq_payload_size  (pipes_2_io_deq_payload_size[2:0] ), //o
    .io_deq_payload_burst (pipes_2_io_deq_payload_burst[1:0]), //o
    .io_deq_payload_cache (pipes_2_io_deq_payload_cache[3:0]), //o
    .io_deq_payload_prot  (pipes_2_io_deq_payload_prot[2:0] )  //o
  );
  NpuMemCdcFifoPipeAddr pipes_3 (
    .io_sClk              (io_sClk                          ), //i
    .io_sRstn             (io_sRstn                         ), //i
    .io_dClk              (io_dClk                          ), //i
    .io_dRstn             (io_dRstn                         ), //i
    .io_enq_valid         (pipes_3_io_enq_valid             ), //i
    .io_enq_ready         (pipes_3_io_enq_ready             ), //o
    .io_enq_payload_addr  (_zz_io_enq_payload_addr[31:0]    ), //i
    .io_enq_payload_id    (_zz_io_enq_payload_id[3:0]       ), //i
    .io_enq_payload_len   (_zz_io_enq_payload_len[7:0]      ), //i
    .io_enq_payload_size  (_zz_io_enq_payload_size[2:0]     ), //i
    .io_enq_payload_burst (_zz_io_enq_payload_burst[1:0]    ), //i
    .io_enq_payload_cache (_zz_io_enq_payload_cache[3:0]    ), //i
    .io_enq_payload_prot  (_zz_io_enq_payload_prot[2:0]     ), //i
    .io_deq_valid         (pipes_3_io_deq_valid             ), //o
    .io_deq_ready         (pipes_3_io_deq_ready             ), //i
    .io_deq_payload_addr  (pipes_3_io_deq_payload_addr[31:0]), //o
    .io_deq_payload_id    (pipes_3_io_deq_payload_id[3:0]   ), //o
    .io_deq_payload_len   (pipes_3_io_deq_payload_len[7:0]  ), //o
    .io_deq_payload_size  (pipes_3_io_deq_payload_size[2:0] ), //o
    .io_deq_payload_burst (pipes_3_io_deq_payload_burst[1:0]), //o
    .io_deq_payload_cache (pipes_3_io_deq_payload_cache[3:0]), //o
    .io_deq_payload_prot  (pipes_3_io_deq_payload_prot[2:0] )  //o
  );
  always @(*) begin
    case(sHead)
      3'b000 : begin
        _zz__zz_io_enq_payload_addr = sMem_0_addr;
        _zz__zz_io_enq_payload_id = sMem_0_id;
        _zz__zz_io_enq_payload_len = sMem_0_len;
        _zz__zz_io_enq_payload_size = sMem_0_size;
        _zz__zz_io_enq_payload_burst = sMem_0_burst;
        _zz__zz_io_enq_payload_cache = sMem_0_cache;
        _zz__zz_io_enq_payload_prot = sMem_0_prot;
      end
      3'b001 : begin
        _zz__zz_io_enq_payload_addr = sMem_1_addr;
        _zz__zz_io_enq_payload_id = sMem_1_id;
        _zz__zz_io_enq_payload_len = sMem_1_len;
        _zz__zz_io_enq_payload_size = sMem_1_size;
        _zz__zz_io_enq_payload_burst = sMem_1_burst;
        _zz__zz_io_enq_payload_cache = sMem_1_cache;
        _zz__zz_io_enq_payload_prot = sMem_1_prot;
      end
      3'b010 : begin
        _zz__zz_io_enq_payload_addr = sMem_2_addr;
        _zz__zz_io_enq_payload_id = sMem_2_id;
        _zz__zz_io_enq_payload_len = sMem_2_len;
        _zz__zz_io_enq_payload_size = sMem_2_size;
        _zz__zz_io_enq_payload_burst = sMem_2_burst;
        _zz__zz_io_enq_payload_cache = sMem_2_cache;
        _zz__zz_io_enq_payload_prot = sMem_2_prot;
      end
      3'b011 : begin
        _zz__zz_io_enq_payload_addr = sMem_3_addr;
        _zz__zz_io_enq_payload_id = sMem_3_id;
        _zz__zz_io_enq_payload_len = sMem_3_len;
        _zz__zz_io_enq_payload_size = sMem_3_size;
        _zz__zz_io_enq_payload_burst = sMem_3_burst;
        _zz__zz_io_enq_payload_cache = sMem_3_cache;
        _zz__zz_io_enq_payload_prot = sMem_3_prot;
      end
      3'b100 : begin
        _zz__zz_io_enq_payload_addr = sMem_4_addr;
        _zz__zz_io_enq_payload_id = sMem_4_id;
        _zz__zz_io_enq_payload_len = sMem_4_len;
        _zz__zz_io_enq_payload_size = sMem_4_size;
        _zz__zz_io_enq_payload_burst = sMem_4_burst;
        _zz__zz_io_enq_payload_cache = sMem_4_cache;
        _zz__zz_io_enq_payload_prot = sMem_4_prot;
      end
      3'b101 : begin
        _zz__zz_io_enq_payload_addr = sMem_5_addr;
        _zz__zz_io_enq_payload_id = sMem_5_id;
        _zz__zz_io_enq_payload_len = sMem_5_len;
        _zz__zz_io_enq_payload_size = sMem_5_size;
        _zz__zz_io_enq_payload_burst = sMem_5_burst;
        _zz__zz_io_enq_payload_cache = sMem_5_cache;
        _zz__zz_io_enq_payload_prot = sMem_5_prot;
      end
      3'b110 : begin
        _zz__zz_io_enq_payload_addr = sMem_6_addr;
        _zz__zz_io_enq_payload_id = sMem_6_id;
        _zz__zz_io_enq_payload_len = sMem_6_len;
        _zz__zz_io_enq_payload_size = sMem_6_size;
        _zz__zz_io_enq_payload_burst = sMem_6_burst;
        _zz__zz_io_enq_payload_cache = sMem_6_cache;
        _zz__zz_io_enq_payload_prot = sMem_6_prot;
      end
      default : begin
        _zz__zz_io_enq_payload_addr = sMem_7_addr;
        _zz__zz_io_enq_payload_id = sMem_7_id;
        _zz__zz_io_enq_payload_len = sMem_7_len;
        _zz__zz_io_enq_payload_size = sMem_7_size;
        _zz__zz_io_enq_payload_burst = sMem_7_burst;
        _zz__zz_io_enq_payload_cache = sMem_7_cache;
        _zz__zz_io_enq_payload_prot = sMem_7_prot;
      end
    endcase
  end

  always @(*) begin
    case(sLane)
      2'b00 : _zz_sDisFire = pipes_0_io_enq_ready;
      2'b01 : _zz_sDisFire = pipes_1_io_enq_ready;
      2'b10 : _zz_sDisFire = pipes_2_io_enq_ready;
      default : _zz_sDisFire = pipes_3_io_enq_ready;
    endcase
  end

  always @(*) begin
    case(dLane)
      2'b00 : begin
        _zz_dCollect = pipes_0_io_deq_valid;
        _zz_dCollect_1 = dTaken_0;
        _zz__zz_dMem_0_addr = pipes_0_io_deq_payload_addr;
        _zz__zz_dMem_0_id = pipes_0_io_deq_payload_id;
        _zz__zz_dMem_0_len = pipes_0_io_deq_payload_len;
        _zz__zz_dMem_0_size = pipes_0_io_deq_payload_size;
        _zz__zz_dMem_0_burst = pipes_0_io_deq_payload_burst;
        _zz__zz_dMem_0_cache = pipes_0_io_deq_payload_cache;
        _zz__zz_dMem_0_prot = pipes_0_io_deq_payload_prot;
      end
      2'b01 : begin
        _zz_dCollect = pipes_1_io_deq_valid;
        _zz_dCollect_1 = dTaken_1;
        _zz__zz_dMem_0_addr = pipes_1_io_deq_payload_addr;
        _zz__zz_dMem_0_id = pipes_1_io_deq_payload_id;
        _zz__zz_dMem_0_len = pipes_1_io_deq_payload_len;
        _zz__zz_dMem_0_size = pipes_1_io_deq_payload_size;
        _zz__zz_dMem_0_burst = pipes_1_io_deq_payload_burst;
        _zz__zz_dMem_0_cache = pipes_1_io_deq_payload_cache;
        _zz__zz_dMem_0_prot = pipes_1_io_deq_payload_prot;
      end
      2'b10 : begin
        _zz_dCollect = pipes_2_io_deq_valid;
        _zz_dCollect_1 = dTaken_2;
        _zz__zz_dMem_0_addr = pipes_2_io_deq_payload_addr;
        _zz__zz_dMem_0_id = pipes_2_io_deq_payload_id;
        _zz__zz_dMem_0_len = pipes_2_io_deq_payload_len;
        _zz__zz_dMem_0_size = pipes_2_io_deq_payload_size;
        _zz__zz_dMem_0_burst = pipes_2_io_deq_payload_burst;
        _zz__zz_dMem_0_cache = pipes_2_io_deq_payload_cache;
        _zz__zz_dMem_0_prot = pipes_2_io_deq_payload_prot;
      end
      default : begin
        _zz_dCollect = pipes_3_io_deq_valid;
        _zz_dCollect_1 = dTaken_3;
        _zz__zz_dMem_0_addr = pipes_3_io_deq_payload_addr;
        _zz__zz_dMem_0_id = pipes_3_io_deq_payload_id;
        _zz__zz_dMem_0_len = pipes_3_io_deq_payload_len;
        _zz__zz_dMem_0_size = pipes_3_io_deq_payload_size;
        _zz__zz_dMem_0_burst = pipes_3_io_deq_payload_burst;
        _zz__zz_dMem_0_cache = pipes_3_io_deq_payload_cache;
        _zz__zz_dMem_0_prot = pipes_3_io_deq_payload_prot;
      end
    endcase
  end

  always @(*) begin
    case(dTail)
      3'b000 : begin
        _zz_io_deq_payload_addr = dMem_0_addr;
        _zz_io_deq_payload_id = dMem_0_id;
        _zz_io_deq_payload_len = dMem_0_len;
        _zz_io_deq_payload_size = dMem_0_size;
        _zz_io_deq_payload_burst = dMem_0_burst;
        _zz_io_deq_payload_cache = dMem_0_cache;
        _zz_io_deq_payload_prot = dMem_0_prot;
      end
      3'b001 : begin
        _zz_io_deq_payload_addr = dMem_1_addr;
        _zz_io_deq_payload_id = dMem_1_id;
        _zz_io_deq_payload_len = dMem_1_len;
        _zz_io_deq_payload_size = dMem_1_size;
        _zz_io_deq_payload_burst = dMem_1_burst;
        _zz_io_deq_payload_cache = dMem_1_cache;
        _zz_io_deq_payload_prot = dMem_1_prot;
      end
      3'b010 : begin
        _zz_io_deq_payload_addr = dMem_2_addr;
        _zz_io_deq_payload_id = dMem_2_id;
        _zz_io_deq_payload_len = dMem_2_len;
        _zz_io_deq_payload_size = dMem_2_size;
        _zz_io_deq_payload_burst = dMem_2_burst;
        _zz_io_deq_payload_cache = dMem_2_cache;
        _zz_io_deq_payload_prot = dMem_2_prot;
      end
      3'b011 : begin
        _zz_io_deq_payload_addr = dMem_3_addr;
        _zz_io_deq_payload_id = dMem_3_id;
        _zz_io_deq_payload_len = dMem_3_len;
        _zz_io_deq_payload_size = dMem_3_size;
        _zz_io_deq_payload_burst = dMem_3_burst;
        _zz_io_deq_payload_cache = dMem_3_cache;
        _zz_io_deq_payload_prot = dMem_3_prot;
      end
      3'b100 : begin
        _zz_io_deq_payload_addr = dMem_4_addr;
        _zz_io_deq_payload_id = dMem_4_id;
        _zz_io_deq_payload_len = dMem_4_len;
        _zz_io_deq_payload_size = dMem_4_size;
        _zz_io_deq_payload_burst = dMem_4_burst;
        _zz_io_deq_payload_cache = dMem_4_cache;
        _zz_io_deq_payload_prot = dMem_4_prot;
      end
      3'b101 : begin
        _zz_io_deq_payload_addr = dMem_5_addr;
        _zz_io_deq_payload_id = dMem_5_id;
        _zz_io_deq_payload_len = dMem_5_len;
        _zz_io_deq_payload_size = dMem_5_size;
        _zz_io_deq_payload_burst = dMem_5_burst;
        _zz_io_deq_payload_cache = dMem_5_cache;
        _zz_io_deq_payload_prot = dMem_5_prot;
      end
      3'b110 : begin
        _zz_io_deq_payload_addr = dMem_6_addr;
        _zz_io_deq_payload_id = dMem_6_id;
        _zz_io_deq_payload_len = dMem_6_len;
        _zz_io_deq_payload_size = dMem_6_size;
        _zz_io_deq_payload_burst = dMem_6_burst;
        _zz_io_deq_payload_cache = dMem_6_cache;
        _zz_io_deq_payload_prot = dMem_6_prot;
      end
      default : begin
        _zz_io_deq_payload_addr = dMem_7_addr;
        _zz_io_deq_payload_id = dMem_7_id;
        _zz_io_deq_payload_len = dMem_7_len;
        _zz_io_deq_payload_size = dMem_7_size;
        _zz_io_deq_payload_burst = dMem_7_burst;
        _zz_io_deq_payload_cache = dMem_7_cache;
        _zz_io_deq_payload_prot = dMem_7_prot;
      end
    endcase
  end

  assign sMask = 4'b0111;
  assign lMask = 2'b11;
  assign sWrIdx = _zz_sWrIdx[2:0];
  assign io_enq_ready = (sCount != 4'b1000);
  assign pipes_0_io_enq_valid = ((sCount != 4'b0000) && (sLane == 2'b00));
  assign _zz_io_enq_payload_addr = _zz__zz_io_enq_payload_addr;
  assign _zz_io_enq_payload_id = _zz__zz_io_enq_payload_id;
  assign _zz_io_enq_payload_len = _zz__zz_io_enq_payload_len;
  assign _zz_io_enq_payload_size = _zz__zz_io_enq_payload_size;
  assign _zz_io_enq_payload_burst = _zz__zz_io_enq_payload_burst;
  assign _zz_io_enq_payload_cache = _zz__zz_io_enq_payload_cache;
  assign _zz_io_enq_payload_prot = _zz__zz_io_enq_payload_prot;
  assign pipes_1_io_enq_valid = ((sCount != 4'b0000) && (sLane == 2'b01));
  assign pipes_2_io_enq_valid = ((sCount != 4'b0000) && (sLane == 2'b10));
  assign pipes_3_io_enq_valid = ((sCount != 4'b0000) && (sLane == 2'b11));
  assign sEnqFire = (io_enq_valid && io_enq_ready);
  assign sDisFire = ((sCount != 4'b0000) && _zz_sDisFire);
  assign _zz_1 = ({7'd0,1'b1} <<< sWrIdx);
  assign _zz_2 = _zz_1[0];
  assign _zz_3 = _zz_1[1];
  assign _zz_4 = _zz_1[2];
  assign _zz_5 = _zz_1[3];
  assign _zz_6 = _zz_1[4];
  assign _zz_7 = _zz_1[5];
  assign _zz_8 = _zz_1[6];
  assign _zz_9 = _zz_1[7];
  assign dMask = 4'b0111;
  assign dWrIdx = _zz_dWrIdx[2:0];
  assign _zz_10 = ({3'd0,1'b1} <<< dLane);
  assign dCollect = (((dCount != 4'b1000) && _zz_dCollect) && (! _zz_dCollect_1));
  assign pipes_0_io_deq_ready = ((((dLane == 2'b00) && pipes_0_io_deq_valid) && (! dTaken_0)) && (dCount != 4'b1000));
  assign when_NpuMemCdcFifo_l91 = (! pipes_0_io_deq_valid);
  assign pipes_1_io_deq_ready = ((((dLane == 2'b01) && pipes_1_io_deq_valid) && (! dTaken_1)) && (dCount != 4'b1000));
  assign when_NpuMemCdcFifo_l91_1 = (! pipes_1_io_deq_valid);
  assign pipes_2_io_deq_ready = ((((dLane == 2'b10) && pipes_2_io_deq_valid) && (! dTaken_2)) && (dCount != 4'b1000));
  assign when_NpuMemCdcFifo_l91_2 = (! pipes_2_io_deq_valid);
  assign pipes_3_io_deq_ready = ((((dLane == 2'b11) && pipes_3_io_deq_valid) && (! dTaken_3)) && (dCount != 4'b1000));
  assign when_NpuMemCdcFifo_l91_3 = (! pipes_3_io_deq_valid);
  assign _zz_11 = ({7'd0,1'b1} <<< dWrIdx);
  assign _zz_12 = _zz_11[0];
  assign _zz_13 = _zz_11[1];
  assign _zz_14 = _zz_11[2];
  assign _zz_15 = _zz_11[3];
  assign _zz_16 = _zz_11[4];
  assign _zz_17 = _zz_11[5];
  assign _zz_18 = _zz_11[6];
  assign _zz_19 = _zz_11[7];
  assign _zz_dMem_0_addr = _zz__zz_dMem_0_addr;
  assign _zz_dMem_0_id = _zz__zz_dMem_0_id;
  assign _zz_dMem_0_len = _zz__zz_dMem_0_len;
  assign _zz_dMem_0_size = _zz__zz_dMem_0_size;
  assign _zz_dMem_0_burst = _zz__zz_dMem_0_burst;
  assign _zz_dMem_0_cache = _zz__zz_dMem_0_cache;
  assign _zz_dMem_0_prot = _zz__zz_dMem_0_prot;
  assign io_deq_valid = (dCount != 4'b0000);
  assign io_deq_payload_addr = _zz_io_deq_payload_addr;
  assign io_deq_payload_id = _zz_io_deq_payload_id;
  assign io_deq_payload_len = _zz_io_deq_payload_len;
  assign io_deq_payload_size = _zz_io_deq_payload_size;
  assign io_deq_payload_burst = _zz_io_deq_payload_burst;
  assign io_deq_payload_cache = _zz_io_deq_payload_cache;
  assign io_deq_payload_prot = _zz_io_deq_payload_prot;
  assign dDeqFire = (io_deq_valid && io_deq_ready);
  always @(posedge io_sClk or negedge io_sRstn) begin
    if(!io_sRstn) begin
      sHead <= 3'b000;
      sCount <= 4'b0000;
      sLane <= 2'b00;
    end else begin
      sCount <= (_zz_sCount - (sDisFire ? 4'b0001 : 4'b0000));
      if(sDisFire) begin
        sHead <= (sHead + 3'b001);
        sLane <= (_zz_sLane & lMask);
      end
    end
  end

  always @(posedge io_sClk) begin
    if(sEnqFire) begin
      if(_zz_2) begin
        sMem_0_addr <= io_enq_payload_addr;
      end
      if(_zz_3) begin
        sMem_1_addr <= io_enq_payload_addr;
      end
      if(_zz_4) begin
        sMem_2_addr <= io_enq_payload_addr;
      end
      if(_zz_5) begin
        sMem_3_addr <= io_enq_payload_addr;
      end
      if(_zz_6) begin
        sMem_4_addr <= io_enq_payload_addr;
      end
      if(_zz_7) begin
        sMem_5_addr <= io_enq_payload_addr;
      end
      if(_zz_8) begin
        sMem_6_addr <= io_enq_payload_addr;
      end
      if(_zz_9) begin
        sMem_7_addr <= io_enq_payload_addr;
      end
      if(_zz_2) begin
        sMem_0_id <= io_enq_payload_id;
      end
      if(_zz_3) begin
        sMem_1_id <= io_enq_payload_id;
      end
      if(_zz_4) begin
        sMem_2_id <= io_enq_payload_id;
      end
      if(_zz_5) begin
        sMem_3_id <= io_enq_payload_id;
      end
      if(_zz_6) begin
        sMem_4_id <= io_enq_payload_id;
      end
      if(_zz_7) begin
        sMem_5_id <= io_enq_payload_id;
      end
      if(_zz_8) begin
        sMem_6_id <= io_enq_payload_id;
      end
      if(_zz_9) begin
        sMem_7_id <= io_enq_payload_id;
      end
      if(_zz_2) begin
        sMem_0_len <= io_enq_payload_len;
      end
      if(_zz_3) begin
        sMem_1_len <= io_enq_payload_len;
      end
      if(_zz_4) begin
        sMem_2_len <= io_enq_payload_len;
      end
      if(_zz_5) begin
        sMem_3_len <= io_enq_payload_len;
      end
      if(_zz_6) begin
        sMem_4_len <= io_enq_payload_len;
      end
      if(_zz_7) begin
        sMem_5_len <= io_enq_payload_len;
      end
      if(_zz_8) begin
        sMem_6_len <= io_enq_payload_len;
      end
      if(_zz_9) begin
        sMem_7_len <= io_enq_payload_len;
      end
      if(_zz_2) begin
        sMem_0_size <= io_enq_payload_size;
      end
      if(_zz_3) begin
        sMem_1_size <= io_enq_payload_size;
      end
      if(_zz_4) begin
        sMem_2_size <= io_enq_payload_size;
      end
      if(_zz_5) begin
        sMem_3_size <= io_enq_payload_size;
      end
      if(_zz_6) begin
        sMem_4_size <= io_enq_payload_size;
      end
      if(_zz_7) begin
        sMem_5_size <= io_enq_payload_size;
      end
      if(_zz_8) begin
        sMem_6_size <= io_enq_payload_size;
      end
      if(_zz_9) begin
        sMem_7_size <= io_enq_payload_size;
      end
      if(_zz_2) begin
        sMem_0_burst <= io_enq_payload_burst;
      end
      if(_zz_3) begin
        sMem_1_burst <= io_enq_payload_burst;
      end
      if(_zz_4) begin
        sMem_2_burst <= io_enq_payload_burst;
      end
      if(_zz_5) begin
        sMem_3_burst <= io_enq_payload_burst;
      end
      if(_zz_6) begin
        sMem_4_burst <= io_enq_payload_burst;
      end
      if(_zz_7) begin
        sMem_5_burst <= io_enq_payload_burst;
      end
      if(_zz_8) begin
        sMem_6_burst <= io_enq_payload_burst;
      end
      if(_zz_9) begin
        sMem_7_burst <= io_enq_payload_burst;
      end
      if(_zz_2) begin
        sMem_0_cache <= io_enq_payload_cache;
      end
      if(_zz_3) begin
        sMem_1_cache <= io_enq_payload_cache;
      end
      if(_zz_4) begin
        sMem_2_cache <= io_enq_payload_cache;
      end
      if(_zz_5) begin
        sMem_3_cache <= io_enq_payload_cache;
      end
      if(_zz_6) begin
        sMem_4_cache <= io_enq_payload_cache;
      end
      if(_zz_7) begin
        sMem_5_cache <= io_enq_payload_cache;
      end
      if(_zz_8) begin
        sMem_6_cache <= io_enq_payload_cache;
      end
      if(_zz_9) begin
        sMem_7_cache <= io_enq_payload_cache;
      end
      if(_zz_2) begin
        sMem_0_prot <= io_enq_payload_prot;
      end
      if(_zz_3) begin
        sMem_1_prot <= io_enq_payload_prot;
      end
      if(_zz_4) begin
        sMem_2_prot <= io_enq_payload_prot;
      end
      if(_zz_5) begin
        sMem_3_prot <= io_enq_payload_prot;
      end
      if(_zz_6) begin
        sMem_4_prot <= io_enq_payload_prot;
      end
      if(_zz_7) begin
        sMem_5_prot <= io_enq_payload_prot;
      end
      if(_zz_8) begin
        sMem_6_prot <= io_enq_payload_prot;
      end
      if(_zz_9) begin
        sMem_7_prot <= io_enq_payload_prot;
      end
    end
  end

  always @(posedge io_dClk or negedge io_dRstn) begin
    if(!io_dRstn) begin
      dTail <= 3'b000;
      dCount <= 4'b0000;
      dLane <= 2'b00;
      dTaken_0 <= 1'b0;
      dTaken_1 <= 1'b0;
      dTaken_2 <= 1'b0;
      dTaken_3 <= 1'b0;
    end else begin
      if(when_NpuMemCdcFifo_l91) begin
        dTaken_0 <= 1'b0;
      end
      if(when_NpuMemCdcFifo_l91_1) begin
        dTaken_1 <= 1'b0;
      end
      if(when_NpuMemCdcFifo_l91_2) begin
        dTaken_2 <= 1'b0;
      end
      if(when_NpuMemCdcFifo_l91_3) begin
        dTaken_3 <= 1'b0;
      end
      if(dCollect) begin
        dLane <= (_zz_dLane & lMask);
        if(_zz_10[0]) begin
          dTaken_0 <= 1'b1;
        end
        if(_zz_10[1]) begin
          dTaken_1 <= 1'b1;
        end
        if(_zz_10[2]) begin
          dTaken_2 <= 1'b1;
        end
        if(_zz_10[3]) begin
          dTaken_3 <= 1'b1;
        end
      end
      dCount <= (_zz_dCount - (dDeqFire ? 4'b0001 : 4'b0000));
      if(dDeqFire) begin
        dTail <= (dTail + 3'b001);
      end
    end
  end

  always @(posedge io_dClk) begin
    if(dCollect) begin
      if(_zz_12) begin
        dMem_0_addr <= _zz_dMem_0_addr;
      end
      if(_zz_13) begin
        dMem_1_addr <= _zz_dMem_0_addr;
      end
      if(_zz_14) begin
        dMem_2_addr <= _zz_dMem_0_addr;
      end
      if(_zz_15) begin
        dMem_3_addr <= _zz_dMem_0_addr;
      end
      if(_zz_16) begin
        dMem_4_addr <= _zz_dMem_0_addr;
      end
      if(_zz_17) begin
        dMem_5_addr <= _zz_dMem_0_addr;
      end
      if(_zz_18) begin
        dMem_6_addr <= _zz_dMem_0_addr;
      end
      if(_zz_19) begin
        dMem_7_addr <= _zz_dMem_0_addr;
      end
      if(_zz_12) begin
        dMem_0_id <= _zz_dMem_0_id;
      end
      if(_zz_13) begin
        dMem_1_id <= _zz_dMem_0_id;
      end
      if(_zz_14) begin
        dMem_2_id <= _zz_dMem_0_id;
      end
      if(_zz_15) begin
        dMem_3_id <= _zz_dMem_0_id;
      end
      if(_zz_16) begin
        dMem_4_id <= _zz_dMem_0_id;
      end
      if(_zz_17) begin
        dMem_5_id <= _zz_dMem_0_id;
      end
      if(_zz_18) begin
        dMem_6_id <= _zz_dMem_0_id;
      end
      if(_zz_19) begin
        dMem_7_id <= _zz_dMem_0_id;
      end
      if(_zz_12) begin
        dMem_0_len <= _zz_dMem_0_len;
      end
      if(_zz_13) begin
        dMem_1_len <= _zz_dMem_0_len;
      end
      if(_zz_14) begin
        dMem_2_len <= _zz_dMem_0_len;
      end
      if(_zz_15) begin
        dMem_3_len <= _zz_dMem_0_len;
      end
      if(_zz_16) begin
        dMem_4_len <= _zz_dMem_0_len;
      end
      if(_zz_17) begin
        dMem_5_len <= _zz_dMem_0_len;
      end
      if(_zz_18) begin
        dMem_6_len <= _zz_dMem_0_len;
      end
      if(_zz_19) begin
        dMem_7_len <= _zz_dMem_0_len;
      end
      if(_zz_12) begin
        dMem_0_size <= _zz_dMem_0_size;
      end
      if(_zz_13) begin
        dMem_1_size <= _zz_dMem_0_size;
      end
      if(_zz_14) begin
        dMem_2_size <= _zz_dMem_0_size;
      end
      if(_zz_15) begin
        dMem_3_size <= _zz_dMem_0_size;
      end
      if(_zz_16) begin
        dMem_4_size <= _zz_dMem_0_size;
      end
      if(_zz_17) begin
        dMem_5_size <= _zz_dMem_0_size;
      end
      if(_zz_18) begin
        dMem_6_size <= _zz_dMem_0_size;
      end
      if(_zz_19) begin
        dMem_7_size <= _zz_dMem_0_size;
      end
      if(_zz_12) begin
        dMem_0_burst <= _zz_dMem_0_burst;
      end
      if(_zz_13) begin
        dMem_1_burst <= _zz_dMem_0_burst;
      end
      if(_zz_14) begin
        dMem_2_burst <= _zz_dMem_0_burst;
      end
      if(_zz_15) begin
        dMem_3_burst <= _zz_dMem_0_burst;
      end
      if(_zz_16) begin
        dMem_4_burst <= _zz_dMem_0_burst;
      end
      if(_zz_17) begin
        dMem_5_burst <= _zz_dMem_0_burst;
      end
      if(_zz_18) begin
        dMem_6_burst <= _zz_dMem_0_burst;
      end
      if(_zz_19) begin
        dMem_7_burst <= _zz_dMem_0_burst;
      end
      if(_zz_12) begin
        dMem_0_cache <= _zz_dMem_0_cache;
      end
      if(_zz_13) begin
        dMem_1_cache <= _zz_dMem_0_cache;
      end
      if(_zz_14) begin
        dMem_2_cache <= _zz_dMem_0_cache;
      end
      if(_zz_15) begin
        dMem_3_cache <= _zz_dMem_0_cache;
      end
      if(_zz_16) begin
        dMem_4_cache <= _zz_dMem_0_cache;
      end
      if(_zz_17) begin
        dMem_5_cache <= _zz_dMem_0_cache;
      end
      if(_zz_18) begin
        dMem_6_cache <= _zz_dMem_0_cache;
      end
      if(_zz_19) begin
        dMem_7_cache <= _zz_dMem_0_cache;
      end
      if(_zz_12) begin
        dMem_0_prot <= _zz_dMem_0_prot;
      end
      if(_zz_13) begin
        dMem_1_prot <= _zz_dMem_0_prot;
      end
      if(_zz_14) begin
        dMem_2_prot <= _zz_dMem_0_prot;
      end
      if(_zz_15) begin
        dMem_3_prot <= _zz_dMem_0_prot;
      end
      if(_zz_16) begin
        dMem_4_prot <= _zz_dMem_0_prot;
      end
      if(_zz_17) begin
        dMem_5_prot <= _zz_dMem_0_prot;
      end
      if(_zz_18) begin
        dMem_6_prot <= _zz_dMem_0_prot;
      end
      if(_zz_19) begin
        dMem_7_prot <= _zz_dMem_0_prot;
      end
    end
  end


endmodule

//NpuMemCdcFifoPipeR replaced by NpuMemCdcFifoPipeR

//NpuMemCdcFifoPipeR replaced by NpuMemCdcFifoPipeR

//NpuMemCdcFifoPipeR replaced by NpuMemCdcFifoPipeR

module NpuMemCdcFifoPipeR (
  input  wire          io_sClk,
  input  wire          io_sRstn,
  input  wire          io_dClk,
  input  wire          io_dRstn,
  input  wire          io_enq_valid,
  output wire          io_enq_ready,
  input  wire [63:0]   io_enq_payload_data,
  input  wire [3:0]    io_enq_payload_id,
  input  wire [1:0]    io_enq_payload_resp,
  input  wire          io_enq_payload_last,
  output wire          io_deq_valid,
  input  wire          io_deq_ready,
  output wire [63:0]   io_deq_payload_data,
  output wire [3:0]    io_deq_payload_id,
  output wire [1:0]    io_deq_payload_resp,
  output wire          io_deq_payload_last
);

  (* async_reg = "true" *) reg        [63:0]   sData_data;
  (* async_reg = "true" *) reg        [3:0]    sData_id;
  (* async_reg = "true" *) reg        [1:0]    sData_resp;
  (* async_reg = "true" *) reg                 sData_last;
  (* async_reg = "true" *) reg                 sValid;
  reg                 ackSync1;
  reg                 ackSync2;
  reg                 validSync1;
  reg                 validSync2;
  reg        [63:0]   dData_data;
  reg        [3:0]    dData_id;
  reg        [1:0]    dData_resp;
  reg                 dData_last;
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
  assign io_deq_payload_id = dData_id;
  assign io_deq_payload_resp = dData_resp;
  assign io_deq_payload_last = dData_last;
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
      sData_id <= io_enq_payload_id;
      sData_resp <= io_enq_payload_resp;
      sData_last <= io_enq_payload_last;
    end
  end

  always @(posedge io_dClk) begin
    if(when_NpuAxiLiteCdc_l198) begin
      dData_data <= sData_data;
      dData_id <= sData_id;
      dData_resp <= sData_resp;
      dData_last <= sData_last;
    end
  end


endmodule

//NpuMemCdcFifoPipeAddr replaced by NpuMemCdcFifoPipeAddr

//NpuMemCdcFifoPipeAddr replaced by NpuMemCdcFifoPipeAddr

//NpuMemCdcFifoPipeAddr replaced by NpuMemCdcFifoPipeAddr

//NpuMemCdcFifoPipeAddr replaced by NpuMemCdcFifoPipeAddr

//NpuMemCdcFifoPipeB replaced by NpuMemCdcFifoPipeB

//NpuMemCdcFifoPipeB replaced by NpuMemCdcFifoPipeB

//NpuMemCdcFifoPipeB replaced by NpuMemCdcFifoPipeB

module NpuMemCdcFifoPipeB (
  input  wire          io_sClk,
  input  wire          io_sRstn,
  input  wire          io_dClk,
  input  wire          io_dRstn,
  input  wire          io_enq_valid,
  output wire          io_enq_ready,
  input  wire [3:0]    io_enq_payload_id,
  input  wire [1:0]    io_enq_payload_resp,
  output wire          io_deq_valid,
  input  wire          io_deq_ready,
  output wire [3:0]    io_deq_payload_id,
  output wire [1:0]    io_deq_payload_resp
);

  (* async_reg = "true" *) reg        [3:0]    sData_id;
  (* async_reg = "true" *) reg        [1:0]    sData_resp;
  (* async_reg = "true" *) reg                 sValid;
  reg                 ackSync1;
  reg                 ackSync2;
  reg                 validSync1;
  reg                 validSync2;
  reg        [3:0]    dData_id;
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
  assign io_deq_payload_id = dData_id;
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
      sData_id <= io_enq_payload_id;
      sData_resp <= io_enq_payload_resp;
    end
  end

  always @(posedge io_dClk) begin
    if(when_NpuAxiLiteCdc_l198) begin
      dData_id <= sData_id;
      dData_resp <= sData_resp;
    end
  end


endmodule

//NpuMemCdcFifoPipeW replaced by NpuMemCdcFifoPipeW

//NpuMemCdcFifoPipeW replaced by NpuMemCdcFifoPipeW

//NpuMemCdcFifoPipeW replaced by NpuMemCdcFifoPipeW

module NpuMemCdcFifoPipeW (
  input  wire          io_sClk,
  input  wire          io_sRstn,
  input  wire          io_dClk,
  input  wire          io_dRstn,
  input  wire          io_enq_valid,
  output wire          io_enq_ready,
  input  wire [63:0]   io_enq_payload_data,
  input  wire [7:0]    io_enq_payload_strb,
  input  wire          io_enq_payload_last,
  output wire          io_deq_valid,
  input  wire          io_deq_ready,
  output wire [63:0]   io_deq_payload_data,
  output wire [7:0]    io_deq_payload_strb,
  output wire          io_deq_payload_last
);

  (* async_reg = "true" *) reg        [63:0]   sData_data;
  (* async_reg = "true" *) reg        [7:0]    sData_strb;
  (* async_reg = "true" *) reg                 sData_last;
  (* async_reg = "true" *) reg                 sValid;
  reg                 ackSync1;
  reg                 ackSync2;
  reg                 validSync1;
  reg                 validSync2;
  reg        [63:0]   dData_data;
  reg        [7:0]    dData_strb;
  reg                 dData_last;
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
  assign io_deq_payload_last = dData_last;
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
      sData_last <= io_enq_payload_last;
    end
  end

  always @(posedge io_dClk) begin
    if(when_NpuAxiLiteCdc_l198) begin
      dData_data <= sData_data;
      dData_strb <= sData_strb;
      dData_last <= sData_last;
    end
  end


endmodule

//NpuMemCdcFifoPipeAddr replaced by NpuMemCdcFifoPipeAddr

//NpuMemCdcFifoPipeAddr replaced by NpuMemCdcFifoPipeAddr

//NpuMemCdcFifoPipeAddr replaced by NpuMemCdcFifoPipeAddr

module NpuMemCdcFifoPipeAddr (
  input  wire          io_sClk,
  input  wire          io_sRstn,
  input  wire          io_dClk,
  input  wire          io_dRstn,
  input  wire          io_enq_valid,
  output wire          io_enq_ready,
  input  wire [31:0]   io_enq_payload_addr,
  input  wire [3:0]    io_enq_payload_id,
  input  wire [7:0]    io_enq_payload_len,
  input  wire [2:0]    io_enq_payload_size,
  input  wire [1:0]    io_enq_payload_burst,
  input  wire [3:0]    io_enq_payload_cache,
  input  wire [2:0]    io_enq_payload_prot,
  output wire          io_deq_valid,
  input  wire          io_deq_ready,
  output wire [31:0]   io_deq_payload_addr,
  output wire [3:0]    io_deq_payload_id,
  output wire [7:0]    io_deq_payload_len,
  output wire [2:0]    io_deq_payload_size,
  output wire [1:0]    io_deq_payload_burst,
  output wire [3:0]    io_deq_payload_cache,
  output wire [2:0]    io_deq_payload_prot
);

  (* async_reg = "true" *) reg        [31:0]   sData_addr;
  (* async_reg = "true" *) reg        [3:0]    sData_id;
  (* async_reg = "true" *) reg        [7:0]    sData_len;
  (* async_reg = "true" *) reg        [2:0]    sData_size;
  (* async_reg = "true" *) reg        [1:0]    sData_burst;
  (* async_reg = "true" *) reg        [3:0]    sData_cache;
  (* async_reg = "true" *) reg        [2:0]    sData_prot;
  (* async_reg = "true" *) reg                 sValid;
  reg                 ackSync1;
  reg                 ackSync2;
  reg                 validSync1;
  reg                 validSync2;
  reg        [31:0]   dData_addr;
  reg        [3:0]    dData_id;
  reg        [7:0]    dData_len;
  reg        [2:0]    dData_size;
  reg        [1:0]    dData_burst;
  reg        [3:0]    dData_cache;
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
  assign io_deq_payload_id = dData_id;
  assign io_deq_payload_len = dData_len;
  assign io_deq_payload_size = dData_size;
  assign io_deq_payload_burst = dData_burst;
  assign io_deq_payload_cache = dData_cache;
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
      sData_id <= io_enq_payload_id;
      sData_len <= io_enq_payload_len;
      sData_size <= io_enq_payload_size;
      sData_burst <= io_enq_payload_burst;
      sData_cache <= io_enq_payload_cache;
      sData_prot <= io_enq_payload_prot;
    end
  end

  always @(posedge io_dClk) begin
    if(when_NpuAxiLiteCdc_l198) begin
      dData_addr <= sData_addr;
      dData_id <= sData_id;
      dData_len <= sData_len;
      dData_size <= sData_size;
      dData_burst <= sData_burst;
      dData_cache <= sData_cache;
      dData_prot <= sData_prot;
    end
  end


endmodule
