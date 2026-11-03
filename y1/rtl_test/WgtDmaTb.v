//=============================================================================
// WgtDmaTb.v —— ★ C4b-B1「权重段从 DDR 批量装载（DMA 主路径）」的装置（纯 Verilog + AxiMemModel）。
//
// 干什么：把**描述符表 + 权重 blob 镜像**都放进 DDR，给 `LayerSched` 一次 `go` ⇒ 调度器自己走表，
//   每个单元开跑前**用自己的 DdrMaster**把该单元的权重段读进各切片的 `WeightStore`
//   （起点 = 主机编程的 `WGT_BLOB_BASE` + 表序前缀和 Σ_{j<i} N_j，见 rtl/{UnitExec,LayerSched}.scala 文件头），
//   帧末抬一次 `frameDone` ⇒ 本装置把每片 `WeightStore` 的**全部 576 个条目读回来**，
//   与 `+EXPBYTES`（闸门按 blob 布局算出来的"各片应有的那一段"）逐字节对账。
//
// 契约（plusarg；装置不写死任何地址/几何）：
//   +MEMFILE= / +DUMPFILE= / +dump   整片内存镜像（表 + blob + 激活 + 背景），AxiMemModel 自己取。
//   +DESC_ADDR=<dec> +DESC_COUNT=<dec>   描述符表基址（32 B 对齐）/ 载荷项数（不含表尾哨兵）。
//   +WBASE=<dec>     ★ 主机编程的 `WGT_BLOB_BASE`（经**既有权重信箱的区域 6**、4 个字节道小端写入）：
//                    非 0 ⇒ DMA 主路径打开（本装置的判据主体）；**0 ⇒ 不编程**（DMA 关闭 ⇒ 走旧信箱通路）。
//   +EXPBYTES=<file> 每行一个十六进制字节：**各片应有的内容**，按片序拼在一起（片 i 的 576 字节在
//                    偏移 i*576 上）。闸门按 blob 布局（`wgt_index` 算术）算出这个文件。
//   +EXPN=<n>        只对账**前 n 片**（n ≤ 8；0 ⇒ 不做 store 对账，例如 err 作业/纯流量作业）。
//   +EXPB=<dec>      ★ 帧内**真正装载的权重字节数**期望值（对账 `LayerSched.wgt_bytes`；-1 ⇒ 不查）。
//   +WGTFILE=<file>  可选：帧**之前**经**权重信箱**（区域 0、`wgt_sel=0`）逐字节预载切片 0 的 576 字节
//                    —— 这就是 C3/C4a 的旧通路（`+WBASE=0` 时它是唯一的装载者）。
//   +OVRFILE=<file>  可选：**覆盖**作业 —— 等本帧的 DMA 装载收工（`unitExec_1.wlRun` 落 0）之后，
//                    再经权重信箱把这份向量（576 字节）推进切片 0（证明"装载完之后信箱仍可改"）。
//   +EXPECT_ERR      可选：本次必须**响亮 err 且零设备搬运**（不识 store）。
//   +TIMEOUT=<n>     可选：等 frameDone/err 的最长拍数（默认 TIMEOUT）。
//
// ★ 白盒观察（**零面积**）：`WeightStore` 的内容通过它**既有的** `tile` 端口读回（一拍出 64 字节、
//   由 `k = ky*3+kx` 选面）—— 与 `rtl_test/WeightStoreTb.v` 用的是**同一个**端口口径：
//     展平地址 `weightAddr = co*72 + ci*9 + k`（dense/GROUP=1，`GroupMask.weightAddr`）
//     ⇒ 扫 k = 0..8、每次读 64 个 (co,ci) 就能**恰好一次覆盖全部 576 个条目**。
//   k 由 `force <slice>.tapK = k` 给定（装置此刻已 IDLE ⇒ 只观察、不扰动数据通路），
//   读的是 `dut.unitExec_1.<slice>.ws_tile_<co>_<ci>`（`Conv3x3Slice` 内的 net 名，由生成器产出）。
//   ★ 为什么不加"读回端口"：本代 CLMA 已 ~91% 满，而一个 576:1 的重读 mux ×8 片 ≈ 万级 LUT ——
//     白盒观察把这块面积**整块省掉**（与既有 `WeightStoreTb` 的"扁平瓦片观察"同一路子）。
//   ⚠ 代价（明写）：网表里若改了实例名/信号名，本装置**编译期**就报错（响亮，不是静默错读）。
//
// 时序口径与 rtl_test/LayerSchedTb.v 同：驱动在 negedge 摆、握手在 posedge 采、$finish 让模型转储。
//=============================================================================
`timescale 1ns/1ps

module WgtDmaTb;

  localparam integer MEMSZ   = 2621440;   // 2.5 MiB（与闸门/既有装置一致）
  localparam integer TIMEOUT = 4000000;   // 等 frameDone/err 的最长拍数
  localparam integer WD_MAX  = 12000000;  // 全局看门狗
  localparam integer NSLICE  = 8;         // L_MAX（本网表的切片实例数）
  localparam integer NSEG    = 576;       // 每片 WeightStore 条目数（dense 8x8：8*8*9）
  localparam integer NCOTAP  = 72;        // 每个 co 的条目数（8 ci * 9 tap）
  localparam integer MAXEXP  = 8192;      // +EXPBYTES 上限（够装不下的大作业只取需要的段）
  localparam integer MAXWGT  = 1024;      // 信箱预载向量上限

  reg clk = 1'b0;
  reg rst = 1'b1;
  always #5 clk = ~clk;

  // ---- DUT 控制 ----
  reg         go;
  reg  [27:0] desc_addr;
  reg  [31:0] desc_count;
  reg  [2:0]  wgt_sel;
  reg  [23:0] wgt_addr;
  reg  [7:0]  wgt_data;
  reg         wgt_we;

  // ---- DUT 观察 ----
  wire        busy, err, frameDone;
  wire [31:0] unitIndex;
  wire [15:0] imgC, imgW, maxPix;
  wire [3:0]  grp;
  wire [7:0]  shift;
  wire [31:0] rd_bytes, wr_bytes;
  wire [31:0] wgt_bytes;      // ★ C4b-B1：帧内真正装载的权重字节数（未走 DMA 恒 0）

  // ---- AXI 连线 ----
  wire        axi_aw_valid, axi_aw_ready;
  wire [27:0] axi_aw_payload_addr;
  wire [3:0]  axi_aw_payload_id;
  wire [7:0]  axi_aw_payload_len;
  wire [2:0]  axi_aw_payload_size;
  wire [1:0]  axi_aw_payload_burst;
  wire [3:0]  axi_aw_payload_cache;
  wire [2:0]  axi_aw_payload_prot;
  wire        axi_w_valid, axi_w_ready;
  wire [63:0] axi_w_payload_data;
  wire [7:0]  axi_w_payload_strb;
  wire        axi_w_payload_last;
  wire        axi_b_valid, axi_b_ready;
  wire [3:0]  axi_b_payload_id;
  wire [1:0]  axi_b_payload_resp;
  wire        axi_ar_valid, axi_ar_ready;
  wire [27:0] axi_ar_payload_addr;
  wire [3:0]  axi_ar_payload_id;
  wire [7:0]  axi_ar_payload_len;
  wire [2:0]  axi_ar_payload_size;
  wire [1:0]  axi_ar_payload_burst;
  wire [3:0]  axi_ar_payload_cache;
  wire [2:0]  axi_ar_payload_prot;
  wire        axi_r_valid, axi_r_ready;
  wire [63:0] axi_r_payload_data;
  wire [3:0]  axi_r_payload_id;
  wire [1:0]  axi_r_payload_resp;
  wire        axi_r_payload_last;

  LayerSched dut (
    .go(go), .descAddr(desc_addr), .descCount(desc_count),
    .busy(busy), .err(err), .unitIndex(unitIndex), .frameDone(frameDone),
    .wgt_sel(wgt_sel), .wgt_addr(wgt_addr), .wgt_data(wgt_data), .wgt_we(wgt_we),
    .imgC(imgC), .imgW(imgW), .grp(grp), .shift(shift), .maxPix(maxPix),
    .rd_bytes(rd_bytes), .wr_bytes(wr_bytes), .wgt_bytes(wgt_bytes),
    .ddr_aw_valid(axi_aw_valid), .ddr_aw_ready(axi_aw_ready),
    .ddr_aw_payload_addr(axi_aw_payload_addr), .ddr_aw_payload_id(axi_aw_payload_id),
    .ddr_aw_payload_len(axi_aw_payload_len), .ddr_aw_payload_size(axi_aw_payload_size),
    .ddr_aw_payload_burst(axi_aw_payload_burst), .ddr_aw_payload_cache(axi_aw_payload_cache),
    .ddr_aw_payload_prot(axi_aw_payload_prot),
    .ddr_w_valid(axi_w_valid), .ddr_w_ready(axi_w_ready),
    .ddr_w_payload_data(axi_w_payload_data), .ddr_w_payload_strb(axi_w_payload_strb),
    .ddr_w_payload_last(axi_w_payload_last),
    .ddr_b_valid(axi_b_valid), .ddr_b_ready(axi_b_ready),
    .ddr_b_payload_id(axi_b_payload_id), .ddr_b_payload_resp(axi_b_payload_resp),
    .ddr_ar_valid(axi_ar_valid), .ddr_ar_ready(axi_ar_ready),
    .ddr_ar_payload_addr(axi_ar_payload_addr), .ddr_ar_payload_id(axi_ar_payload_id),
    .ddr_ar_payload_len(axi_ar_payload_len), .ddr_ar_payload_size(axi_ar_payload_size),
    .ddr_ar_payload_burst(axi_ar_payload_burst), .ddr_ar_payload_cache(axi_ar_payload_cache),
    .ddr_ar_payload_prot(axi_ar_payload_prot),
    .ddr_r_valid(axi_r_valid), .ddr_r_ready(axi_r_ready),
    .ddr_r_payload_data(axi_r_payload_data), .ddr_r_payload_id(axi_r_payload_id),
    .ddr_r_payload_resp(axi_r_payload_resp), .ddr_r_payload_last(axi_r_payload_last),
    .clk(clk), .reset(rst)
  );

  AxiMemModel #(.MEMSZ(MEMSZ), .ADDR_W(28)) mem0 (
    .clk(clk), .reset(rst),
    .axi_aw_valid(axi_aw_valid), .axi_aw_ready(axi_aw_ready),
    .axi_aw_payload_addr(axi_aw_payload_addr), .axi_aw_payload_id(axi_aw_payload_id),
    .axi_aw_payload_len(axi_aw_payload_len), .axi_aw_payload_size(axi_aw_payload_size),
    .axi_aw_payload_burst(axi_aw_payload_burst), .axi_aw_payload_cache(axi_aw_payload_cache),
    .axi_aw_payload_prot(axi_aw_payload_prot),
    .axi_w_valid(axi_w_valid), .axi_w_ready(axi_w_ready),
    .axi_w_payload_data(axi_w_payload_data), .axi_w_payload_strb(axi_w_payload_strb),
    .axi_w_payload_last(axi_w_payload_last),
    .axi_b_valid(axi_b_valid), .axi_b_ready(axi_b_ready),
    .axi_b_payload_id(axi_b_payload_id), .axi_b_payload_resp(axi_b_payload_resp),
    .axi_ar_valid(axi_ar_valid), .axi_ar_ready(axi_ar_ready),
    .axi_ar_payload_addr(axi_ar_payload_addr), .axi_ar_payload_id(axi_ar_payload_id),
    .axi_ar_payload_len(axi_ar_payload_len), .axi_ar_payload_size(axi_ar_payload_size),
    .axi_ar_payload_burst(axi_ar_payload_burst), .axi_ar_payload_cache(axi_ar_payload_cache),
    .axi_ar_payload_prot(axi_ar_payload_prot),
    .axi_r_valid(axi_r_valid), .axi_r_ready(axi_r_ready),
    .axi_r_payload_data(axi_r_payload_data), .axi_r_payload_id(axi_r_payload_id),
    .axi_r_payload_resp(axi_r_payload_resp), .axi_r_payload_last(axi_r_payload_last)
  );

  // ---------------------------------------------------------------------------
  // 白盒观察：WeightStore 的**既有** tile 端口（一拍 64 字节；k 选面）
  //   片序 = UnitExec 的切片实例名：`conv`(0) / `sliceRest_0`(1) / … / `sliceRest_6`(7)
  //   tile 名 = `ws_tile_<co>_<ci>`（`Conv3x3Slice` 里 `ws` 实例的 64 个输出）
  // ---------------------------------------------------------------------------
  function [7:0] tile_of;
    input [2:0] sel;    // 片
    input [5:0] idx;    // co*8 + ci
    begin
      tile_of = 8'hxx;
      case (sel)
        3'd0: begin
          case (idx)
            6'd0: tile_of = dut.unitExec_1.conv.ws_tile_0_0;
            6'd1: tile_of = dut.unitExec_1.conv.ws_tile_0_1;
            6'd2: tile_of = dut.unitExec_1.conv.ws_tile_0_2;
            6'd3: tile_of = dut.unitExec_1.conv.ws_tile_0_3;
            6'd4: tile_of = dut.unitExec_1.conv.ws_tile_0_4;
            6'd5: tile_of = dut.unitExec_1.conv.ws_tile_0_5;
            6'd6: tile_of = dut.unitExec_1.conv.ws_tile_0_6;
            6'd7: tile_of = dut.unitExec_1.conv.ws_tile_0_7;
            6'd8: tile_of = dut.unitExec_1.conv.ws_tile_1_0;
            6'd9: tile_of = dut.unitExec_1.conv.ws_tile_1_1;
            6'd10: tile_of = dut.unitExec_1.conv.ws_tile_1_2;
            6'd11: tile_of = dut.unitExec_1.conv.ws_tile_1_3;
            6'd12: tile_of = dut.unitExec_1.conv.ws_tile_1_4;
            6'd13: tile_of = dut.unitExec_1.conv.ws_tile_1_5;
            6'd14: tile_of = dut.unitExec_1.conv.ws_tile_1_6;
            6'd15: tile_of = dut.unitExec_1.conv.ws_tile_1_7;
            6'd16: tile_of = dut.unitExec_1.conv.ws_tile_2_0;
            6'd17: tile_of = dut.unitExec_1.conv.ws_tile_2_1;
            6'd18: tile_of = dut.unitExec_1.conv.ws_tile_2_2;
            6'd19: tile_of = dut.unitExec_1.conv.ws_tile_2_3;
            6'd20: tile_of = dut.unitExec_1.conv.ws_tile_2_4;
            6'd21: tile_of = dut.unitExec_1.conv.ws_tile_2_5;
            6'd22: tile_of = dut.unitExec_1.conv.ws_tile_2_6;
            6'd23: tile_of = dut.unitExec_1.conv.ws_tile_2_7;
            6'd24: tile_of = dut.unitExec_1.conv.ws_tile_3_0;
            6'd25: tile_of = dut.unitExec_1.conv.ws_tile_3_1;
            6'd26: tile_of = dut.unitExec_1.conv.ws_tile_3_2;
            6'd27: tile_of = dut.unitExec_1.conv.ws_tile_3_3;
            6'd28: tile_of = dut.unitExec_1.conv.ws_tile_3_4;
            6'd29: tile_of = dut.unitExec_1.conv.ws_tile_3_5;
            6'd30: tile_of = dut.unitExec_1.conv.ws_tile_3_6;
            6'd31: tile_of = dut.unitExec_1.conv.ws_tile_3_7;
            6'd32: tile_of = dut.unitExec_1.conv.ws_tile_4_0;
            6'd33: tile_of = dut.unitExec_1.conv.ws_tile_4_1;
            6'd34: tile_of = dut.unitExec_1.conv.ws_tile_4_2;
            6'd35: tile_of = dut.unitExec_1.conv.ws_tile_4_3;
            6'd36: tile_of = dut.unitExec_1.conv.ws_tile_4_4;
            6'd37: tile_of = dut.unitExec_1.conv.ws_tile_4_5;
            6'd38: tile_of = dut.unitExec_1.conv.ws_tile_4_6;
            6'd39: tile_of = dut.unitExec_1.conv.ws_tile_4_7;
            6'd40: tile_of = dut.unitExec_1.conv.ws_tile_5_0;
            6'd41: tile_of = dut.unitExec_1.conv.ws_tile_5_1;
            6'd42: tile_of = dut.unitExec_1.conv.ws_tile_5_2;
            6'd43: tile_of = dut.unitExec_1.conv.ws_tile_5_3;
            6'd44: tile_of = dut.unitExec_1.conv.ws_tile_5_4;
            6'd45: tile_of = dut.unitExec_1.conv.ws_tile_5_5;
            6'd46: tile_of = dut.unitExec_1.conv.ws_tile_5_6;
            6'd47: tile_of = dut.unitExec_1.conv.ws_tile_5_7;
            6'd48: tile_of = dut.unitExec_1.conv.ws_tile_6_0;
            6'd49: tile_of = dut.unitExec_1.conv.ws_tile_6_1;
            6'd50: tile_of = dut.unitExec_1.conv.ws_tile_6_2;
            6'd51: tile_of = dut.unitExec_1.conv.ws_tile_6_3;
            6'd52: tile_of = dut.unitExec_1.conv.ws_tile_6_4;
            6'd53: tile_of = dut.unitExec_1.conv.ws_tile_6_5;
            6'd54: tile_of = dut.unitExec_1.conv.ws_tile_6_6;
            6'd55: tile_of = dut.unitExec_1.conv.ws_tile_6_7;
            6'd56: tile_of = dut.unitExec_1.conv.ws_tile_7_0;
            6'd57: tile_of = dut.unitExec_1.conv.ws_tile_7_1;
            6'd58: tile_of = dut.unitExec_1.conv.ws_tile_7_2;
            6'd59: tile_of = dut.unitExec_1.conv.ws_tile_7_3;
            6'd60: tile_of = dut.unitExec_1.conv.ws_tile_7_4;
            6'd61: tile_of = dut.unitExec_1.conv.ws_tile_7_5;
            6'd62: tile_of = dut.unitExec_1.conv.ws_tile_7_6;
            6'd63: tile_of = dut.unitExec_1.conv.ws_tile_7_7;
          endcase
        end
        3'd1: begin
          case (idx)
            6'd0: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_0_0;
            6'd1: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_0_1;
            6'd2: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_0_2;
            6'd3: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_0_3;
            6'd4: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_0_4;
            6'd5: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_0_5;
            6'd6: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_0_6;
            6'd7: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_0_7;
            6'd8: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_1_0;
            6'd9: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_1_1;
            6'd10: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_1_2;
            6'd11: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_1_3;
            6'd12: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_1_4;
            6'd13: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_1_5;
            6'd14: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_1_6;
            6'd15: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_1_7;
            6'd16: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_2_0;
            6'd17: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_2_1;
            6'd18: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_2_2;
            6'd19: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_2_3;
            6'd20: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_2_4;
            6'd21: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_2_5;
            6'd22: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_2_6;
            6'd23: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_2_7;
            6'd24: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_3_0;
            6'd25: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_3_1;
            6'd26: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_3_2;
            6'd27: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_3_3;
            6'd28: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_3_4;
            6'd29: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_3_5;
            6'd30: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_3_6;
            6'd31: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_3_7;
            6'd32: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_4_0;
            6'd33: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_4_1;
            6'd34: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_4_2;
            6'd35: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_4_3;
            6'd36: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_4_4;
            6'd37: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_4_5;
            6'd38: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_4_6;
            6'd39: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_4_7;
            6'd40: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_5_0;
            6'd41: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_5_1;
            6'd42: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_5_2;
            6'd43: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_5_3;
            6'd44: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_5_4;
            6'd45: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_5_5;
            6'd46: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_5_6;
            6'd47: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_5_7;
            6'd48: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_6_0;
            6'd49: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_6_1;
            6'd50: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_6_2;
            6'd51: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_6_3;
            6'd52: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_6_4;
            6'd53: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_6_5;
            6'd54: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_6_6;
            6'd55: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_6_7;
            6'd56: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_7_0;
            6'd57: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_7_1;
            6'd58: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_7_2;
            6'd59: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_7_3;
            6'd60: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_7_4;
            6'd61: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_7_5;
            6'd62: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_7_6;
            6'd63: tile_of = dut.unitExec_1.sliceRest_0.ws_tile_7_7;
          endcase
        end
        3'd2: begin
          case (idx)
            6'd0: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_0_0;
            6'd1: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_0_1;
            6'd2: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_0_2;
            6'd3: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_0_3;
            6'd4: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_0_4;
            6'd5: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_0_5;
            6'd6: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_0_6;
            6'd7: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_0_7;
            6'd8: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_1_0;
            6'd9: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_1_1;
            6'd10: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_1_2;
            6'd11: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_1_3;
            6'd12: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_1_4;
            6'd13: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_1_5;
            6'd14: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_1_6;
            6'd15: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_1_7;
            6'd16: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_2_0;
            6'd17: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_2_1;
            6'd18: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_2_2;
            6'd19: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_2_3;
            6'd20: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_2_4;
            6'd21: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_2_5;
            6'd22: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_2_6;
            6'd23: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_2_7;
            6'd24: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_3_0;
            6'd25: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_3_1;
            6'd26: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_3_2;
            6'd27: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_3_3;
            6'd28: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_3_4;
            6'd29: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_3_5;
            6'd30: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_3_6;
            6'd31: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_3_7;
            6'd32: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_4_0;
            6'd33: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_4_1;
            6'd34: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_4_2;
            6'd35: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_4_3;
            6'd36: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_4_4;
            6'd37: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_4_5;
            6'd38: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_4_6;
            6'd39: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_4_7;
            6'd40: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_5_0;
            6'd41: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_5_1;
            6'd42: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_5_2;
            6'd43: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_5_3;
            6'd44: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_5_4;
            6'd45: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_5_5;
            6'd46: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_5_6;
            6'd47: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_5_7;
            6'd48: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_6_0;
            6'd49: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_6_1;
            6'd50: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_6_2;
            6'd51: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_6_3;
            6'd52: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_6_4;
            6'd53: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_6_5;
            6'd54: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_6_6;
            6'd55: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_6_7;
            6'd56: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_7_0;
            6'd57: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_7_1;
            6'd58: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_7_2;
            6'd59: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_7_3;
            6'd60: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_7_4;
            6'd61: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_7_5;
            6'd62: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_7_6;
            6'd63: tile_of = dut.unitExec_1.sliceRest_1.ws_tile_7_7;
          endcase
        end
        3'd3: begin
          case (idx)
            6'd0: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_0_0;
            6'd1: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_0_1;
            6'd2: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_0_2;
            6'd3: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_0_3;
            6'd4: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_0_4;
            6'd5: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_0_5;
            6'd6: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_0_6;
            6'd7: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_0_7;
            6'd8: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_1_0;
            6'd9: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_1_1;
            6'd10: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_1_2;
            6'd11: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_1_3;
            6'd12: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_1_4;
            6'd13: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_1_5;
            6'd14: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_1_6;
            6'd15: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_1_7;
            6'd16: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_2_0;
            6'd17: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_2_1;
            6'd18: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_2_2;
            6'd19: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_2_3;
            6'd20: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_2_4;
            6'd21: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_2_5;
            6'd22: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_2_6;
            6'd23: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_2_7;
            6'd24: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_3_0;
            6'd25: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_3_1;
            6'd26: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_3_2;
            6'd27: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_3_3;
            6'd28: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_3_4;
            6'd29: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_3_5;
            6'd30: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_3_6;
            6'd31: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_3_7;
            6'd32: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_4_0;
            6'd33: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_4_1;
            6'd34: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_4_2;
            6'd35: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_4_3;
            6'd36: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_4_4;
            6'd37: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_4_5;
            6'd38: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_4_6;
            6'd39: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_4_7;
            6'd40: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_5_0;
            6'd41: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_5_1;
            6'd42: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_5_2;
            6'd43: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_5_3;
            6'd44: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_5_4;
            6'd45: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_5_5;
            6'd46: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_5_6;
            6'd47: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_5_7;
            6'd48: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_6_0;
            6'd49: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_6_1;
            6'd50: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_6_2;
            6'd51: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_6_3;
            6'd52: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_6_4;
            6'd53: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_6_5;
            6'd54: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_6_6;
            6'd55: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_6_7;
            6'd56: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_7_0;
            6'd57: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_7_1;
            6'd58: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_7_2;
            6'd59: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_7_3;
            6'd60: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_7_4;
            6'd61: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_7_5;
            6'd62: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_7_6;
            6'd63: tile_of = dut.unitExec_1.sliceRest_2.ws_tile_7_7;
          endcase
        end
        3'd4: begin
          case (idx)
            6'd0: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_0_0;
            6'd1: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_0_1;
            6'd2: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_0_2;
            6'd3: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_0_3;
            6'd4: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_0_4;
            6'd5: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_0_5;
            6'd6: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_0_6;
            6'd7: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_0_7;
            6'd8: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_1_0;
            6'd9: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_1_1;
            6'd10: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_1_2;
            6'd11: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_1_3;
            6'd12: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_1_4;
            6'd13: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_1_5;
            6'd14: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_1_6;
            6'd15: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_1_7;
            6'd16: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_2_0;
            6'd17: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_2_1;
            6'd18: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_2_2;
            6'd19: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_2_3;
            6'd20: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_2_4;
            6'd21: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_2_5;
            6'd22: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_2_6;
            6'd23: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_2_7;
            6'd24: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_3_0;
            6'd25: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_3_1;
            6'd26: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_3_2;
            6'd27: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_3_3;
            6'd28: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_3_4;
            6'd29: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_3_5;
            6'd30: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_3_6;
            6'd31: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_3_7;
            6'd32: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_4_0;
            6'd33: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_4_1;
            6'd34: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_4_2;
            6'd35: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_4_3;
            6'd36: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_4_4;
            6'd37: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_4_5;
            6'd38: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_4_6;
            6'd39: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_4_7;
            6'd40: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_5_0;
            6'd41: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_5_1;
            6'd42: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_5_2;
            6'd43: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_5_3;
            6'd44: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_5_4;
            6'd45: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_5_5;
            6'd46: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_5_6;
            6'd47: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_5_7;
            6'd48: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_6_0;
            6'd49: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_6_1;
            6'd50: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_6_2;
            6'd51: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_6_3;
            6'd52: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_6_4;
            6'd53: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_6_5;
            6'd54: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_6_6;
            6'd55: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_6_7;
            6'd56: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_7_0;
            6'd57: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_7_1;
            6'd58: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_7_2;
            6'd59: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_7_3;
            6'd60: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_7_4;
            6'd61: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_7_5;
            6'd62: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_7_6;
            6'd63: tile_of = dut.unitExec_1.sliceRest_3.ws_tile_7_7;
          endcase
        end
        3'd5: begin
          case (idx)
            6'd0: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_0_0;
            6'd1: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_0_1;
            6'd2: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_0_2;
            6'd3: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_0_3;
            6'd4: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_0_4;
            6'd5: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_0_5;
            6'd6: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_0_6;
            6'd7: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_0_7;
            6'd8: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_1_0;
            6'd9: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_1_1;
            6'd10: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_1_2;
            6'd11: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_1_3;
            6'd12: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_1_4;
            6'd13: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_1_5;
            6'd14: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_1_6;
            6'd15: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_1_7;
            6'd16: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_2_0;
            6'd17: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_2_1;
            6'd18: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_2_2;
            6'd19: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_2_3;
            6'd20: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_2_4;
            6'd21: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_2_5;
            6'd22: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_2_6;
            6'd23: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_2_7;
            6'd24: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_3_0;
            6'd25: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_3_1;
            6'd26: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_3_2;
            6'd27: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_3_3;
            6'd28: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_3_4;
            6'd29: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_3_5;
            6'd30: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_3_6;
            6'd31: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_3_7;
            6'd32: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_4_0;
            6'd33: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_4_1;
            6'd34: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_4_2;
            6'd35: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_4_3;
            6'd36: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_4_4;
            6'd37: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_4_5;
            6'd38: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_4_6;
            6'd39: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_4_7;
            6'd40: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_5_0;
            6'd41: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_5_1;
            6'd42: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_5_2;
            6'd43: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_5_3;
            6'd44: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_5_4;
            6'd45: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_5_5;
            6'd46: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_5_6;
            6'd47: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_5_7;
            6'd48: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_6_0;
            6'd49: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_6_1;
            6'd50: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_6_2;
            6'd51: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_6_3;
            6'd52: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_6_4;
            6'd53: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_6_5;
            6'd54: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_6_6;
            6'd55: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_6_7;
            6'd56: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_7_0;
            6'd57: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_7_1;
            6'd58: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_7_2;
            6'd59: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_7_3;
            6'd60: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_7_4;
            6'd61: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_7_5;
            6'd62: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_7_6;
            6'd63: tile_of = dut.unitExec_1.sliceRest_4.ws_tile_7_7;
          endcase
        end
        3'd6: begin
          case (idx)
            6'd0: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_0_0;
            6'd1: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_0_1;
            6'd2: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_0_2;
            6'd3: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_0_3;
            6'd4: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_0_4;
            6'd5: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_0_5;
            6'd6: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_0_6;
            6'd7: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_0_7;
            6'd8: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_1_0;
            6'd9: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_1_1;
            6'd10: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_1_2;
            6'd11: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_1_3;
            6'd12: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_1_4;
            6'd13: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_1_5;
            6'd14: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_1_6;
            6'd15: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_1_7;
            6'd16: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_2_0;
            6'd17: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_2_1;
            6'd18: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_2_2;
            6'd19: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_2_3;
            6'd20: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_2_4;
            6'd21: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_2_5;
            6'd22: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_2_6;
            6'd23: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_2_7;
            6'd24: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_3_0;
            6'd25: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_3_1;
            6'd26: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_3_2;
            6'd27: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_3_3;
            6'd28: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_3_4;
            6'd29: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_3_5;
            6'd30: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_3_6;
            6'd31: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_3_7;
            6'd32: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_4_0;
            6'd33: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_4_1;
            6'd34: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_4_2;
            6'd35: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_4_3;
            6'd36: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_4_4;
            6'd37: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_4_5;
            6'd38: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_4_6;
            6'd39: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_4_7;
            6'd40: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_5_0;
            6'd41: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_5_1;
            6'd42: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_5_2;
            6'd43: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_5_3;
            6'd44: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_5_4;
            6'd45: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_5_5;
            6'd46: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_5_6;
            6'd47: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_5_7;
            6'd48: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_6_0;
            6'd49: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_6_1;
            6'd50: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_6_2;
            6'd51: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_6_3;
            6'd52: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_6_4;
            6'd53: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_6_5;
            6'd54: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_6_6;
            6'd55: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_6_7;
            6'd56: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_7_0;
            6'd57: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_7_1;
            6'd58: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_7_2;
            6'd59: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_7_3;
            6'd60: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_7_4;
            6'd61: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_7_5;
            6'd62: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_7_6;
            6'd63: tile_of = dut.unitExec_1.sliceRest_5.ws_tile_7_7;
          endcase
        end
        3'd7: begin
          case (idx)
            6'd0: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_0_0;
            6'd1: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_0_1;
            6'd2: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_0_2;
            6'd3: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_0_3;
            6'd4: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_0_4;
            6'd5: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_0_5;
            6'd6: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_0_6;
            6'd7: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_0_7;
            6'd8: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_1_0;
            6'd9: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_1_1;
            6'd10: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_1_2;
            6'd11: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_1_3;
            6'd12: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_1_4;
            6'd13: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_1_5;
            6'd14: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_1_6;
            6'd15: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_1_7;
            6'd16: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_2_0;
            6'd17: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_2_1;
            6'd18: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_2_2;
            6'd19: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_2_3;
            6'd20: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_2_4;
            6'd21: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_2_5;
            6'd22: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_2_6;
            6'd23: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_2_7;
            6'd24: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_3_0;
            6'd25: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_3_1;
            6'd26: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_3_2;
            6'd27: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_3_3;
            6'd28: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_3_4;
            6'd29: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_3_5;
            6'd30: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_3_6;
            6'd31: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_3_7;
            6'd32: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_4_0;
            6'd33: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_4_1;
            6'd34: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_4_2;
            6'd35: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_4_3;
            6'd36: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_4_4;
            6'd37: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_4_5;
            6'd38: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_4_6;
            6'd39: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_4_7;
            6'd40: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_5_0;
            6'd41: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_5_1;
            6'd42: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_5_2;
            6'd43: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_5_3;
            6'd44: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_5_4;
            6'd45: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_5_5;
            6'd46: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_5_6;
            6'd47: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_5_7;
            6'd48: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_6_0;
            6'd49: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_6_1;
            6'd50: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_6_2;
            6'd51: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_6_3;
            6'd52: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_6_4;
            6'd53: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_6_5;
            6'd54: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_6_6;
            6'd55: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_6_7;
            6'd56: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_7_0;
            6'd57: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_7_1;
            6'd58: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_7_2;
            6'd59: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_7_3;
            6'd60: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_7_4;
            6'd61: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_7_5;
            6'd62: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_7_6;
            6'd63: tile_of = dut.unitExec_1.sliceRest_6.ws_tile_7_7;
          endcase
        end
        default: tile_of = 8'hxx;
      endcase
    end
  endfunction

  // k 的强驱动/释放（片内 `tapK` 是 WeightStore 的 `k` 端口的唯一来源）
  task force_k;
    input [2:0] sel;
    input [3:0] k;
    begin
      case (sel)
        3'd0: force dut.unitExec_1.conv.tapK          = k;
        3'd1: force dut.unitExec_1.sliceRest_0.tapK   = k;
        3'd2: force dut.unitExec_1.sliceRest_1.tapK   = k;
        3'd3: force dut.unitExec_1.sliceRest_2.tapK   = k;
        3'd4: force dut.unitExec_1.sliceRest_3.tapK   = k;
        3'd5: force dut.unitExec_1.sliceRest_4.tapK   = k;
        3'd6: force dut.unitExec_1.sliceRest_5.tapK   = k;
        3'd7: force dut.unitExec_1.sliceRest_6.tapK   = k;
        default: ;
      endcase
    end
  endtask

  task release_k;
    input [2:0] sel;
    begin
      case (sel)
        3'd0: release dut.unitExec_1.conv.tapK;
        3'd1: release dut.unitExec_1.sliceRest_0.tapK;
        3'd2: release dut.unitExec_1.sliceRest_1.tapK;
        3'd3: release dut.unitExec_1.sliceRest_2.tapK;
        3'd4: release dut.unitExec_1.sliceRest_3.tapK;
        3'd5: release dut.unitExec_1.sliceRest_4.tapK;
        3'd6: release dut.unitExec_1.sliceRest_5.tapK;
        3'd7: release dut.unitExec_1.sliceRest_6.tapK;
        default: ;
      endcase
    end
  endtask

  // ---------------------------------------------------------------------------
  // 向量 / 期望 / 回读缓冲
  // ---------------------------------------------------------------------------
  reg [8*256-1:0] expfile, wgtfile, ovrfile;
  reg [8*256-1:0] memfile_dummy;
  reg [7:0] got [0:NSLICE*NSEG-1];     // 回读的各片内容（片 i 的 addr 在 i*NSEG+addr）
  reg [7:0] expb[0:MAXEXP-1];          // 期望内容（片序拼接）
  reg [7:0] wm  [0:MAXWGT-1];          // 信箱向量
  reg [7:0] ovm [0:MAXWGT-1];          // 覆盖向量

  integer i, j, timeout_cnt, timeout_lim;
  integer ctrl, got_ctrl;
  integer expn, expb_expected, ovr_en, has_wgt, expect_err;
  integer ovr_wait;
  reg     done_seen, err_seen, prev_fd, fd_seen;
  integer ar_total, aw_total, b_ok, ar_n32, ar_n128, aw_n128, wd;
  integer total_mis;
  integer DESC_ADDR_I, DESC_COUNT_I, WBASE_I, EXPB_I, EXPN_I;
  wire [7:0] tile_val_unused;

  // ---- AXI 突发观察（按 arlen 分档：32 B = 取表；其余 = 单元读）----
  always @(posedge clk) begin
    if (!rst) begin
      if (axi_ar_valid && axi_ar_ready) begin
        ar_total = ar_total + 1;
        if (axi_ar_payload_len == 8'd3)       ar_n32  = ar_n32 + 1;
        else if (axi_ar_payload_len == 8'd15) ar_n128 = ar_n128 + 1;
      end
      if (axi_aw_valid && axi_aw_ready) begin
        aw_total = aw_total + 1;
        if (axi_aw_payload_len == 8'd15) aw_n128 = aw_n128 + 1;
      end
      if (axi_b_valid && axi_b_ready) b_ok = b_ok + 1;
      if (frameDone && !prev_fd) fd_seen = 1'b1;
      prev_fd = frameDone;
    end
  end

  // 回读一整片（force k 扫 0..8；每次采 64 个 (co,ci)）
  task readback_slice;
    input [2:0] sel;
    integer k, co, ci, a, ix;
    begin
      for (k = 0; k < 9; k = k + 1) begin
        force_k(sel, k);
        #1;
        for (co = 0; co < 8; co = co + 1) begin
          for (ci = 0; ci < 8; ci = ci + 1) begin
            ix = co*8 + ci;
            a  = co*NCOTAP + ci*9 + k;      // weightAddr = co*72 + ci*9 + k
            got[sel*NSEG + a] = tile_of(sel, ix[5:0]);
          end
        end
      end
      release_k(sel);
      #1;
    end
  endtask

  // 与期望逐字节对账（前 n 片）；打印每片 MISMATCH + 第一处不符（供闸门定位到"哪个单元/哪个偏移"）
  task compare_slices;
    input integer n;
    integer s, a, m, fs, fa, dv, ev;
    begin
      total_mis = 0;
      for (s = 0; s < n; s = s + 1) begin
        m = 0; fs = -1; fa = -1;
        for (a = 0; a < NSEG; a = a + 1) begin
          dv = got[s*NSEG + a];
          ev = expb[s*NSEG + a];
          if (dv !== ev) begin
            m = m + 1;
            if (fa < 0) begin
              fs = s; fa = a;
              $display("STORE_FIRST slice=%0d addr=%0d dut=%02x exp=%02x", s, a, dv[7:0], ev[7:0]);
            end
          end
        end
        $display("STORE_MISMATCH%0d=%0d", s, m);
        total_mis = total_mis + m;
      end
    end
  endtask

  initial begin
    // ---- 默认 ----
    go = 1'b0; desc_addr = 28'd0; desc_count = 32'd0;
    wgt_sel = 3'd0; wgt_addr = 24'd0; wgt_data = 8'd0; wgt_we = 1'b0;
    timeout_cnt = 0; timeout_lim = TIMEOUT; ctrl = 1; got_ctrl = 0;
    done_seen = 1'b0; err_seen = 1'b0; prev_fd = 1'b0; fd_seen = 1'b0;
    ar_total = 0; aw_total = 0; b_ok = 0; ar_n32 = 0; ar_n128 = 0; aw_n128 = 0;
    expn = 0; expb_expected = -1; ovr_en = 0; has_wgt = 0; expect_err = 0;
    total_mis = 0;
    for (i = 0; i < MAXEXP; i = i + 1) expb[i] = 8'h00;
    for (i = 0; i < MAXWGT; i = i + 1) begin wm[i] = 8'h00; ovm[i] = 8'h00; end
    for (i = 0; i < NSLICE*NSEG; i = i + 1) got[i] = 8'h00;

    if (!$value$plusargs("DESC_ADDR=%d", DESC_ADDR_I)) begin
      $display("TB-ERROR: 缺 +DESC_ADDR="); $fatal(1, "missing DESC_ADDR"); end
    if (!$value$plusargs("DESC_COUNT=%d", DESC_COUNT_I)) begin
      $display("TB-ERROR: 缺 +DESC_COUNT="); $fatal(1, "missing DESC_COUNT"); end
    if (!$value$plusargs("WBASE=%d", WBASE_I)) begin
      WBASE_I = 0; end
    if ($value$plusargs("EXPN=%d", EXPN_I)) begin
      expn = EXPN_I;
      if (expn > 0) begin
        if (!$value$plusargs("EXPBYTES=%s", expfile)) begin
          $display("TB-ERROR: +EXPN=%0d 但缺 +EXPBYTES=", expn); $fatal(1, "missing EXPBYTES"); end
        $readmemh(expfile, expb, 0, expn*NSEG-1);
      end
    end
    if ($value$plusargs("EXPB=%d", EXPB_I)) expb_expected = EXPB_I;
    if ($value$plusargs("TIMEOUT=%d", timeout_lim)) begin
      if (timeout_lim < 2000) timeout_lim = 2000;
    end
    if ($test$plusargs("EXPECT_ERR")) expect_err = 1;
    if ($value$plusargs("WGTFILE=%s", wgtfile)) begin
      has_wgt = 1;
      $readmemh(wgtfile, wm, 0, NSEG-1);
    end
    if ($value$plusargs("OVRFILE=%s", ovrfile)) begin
      ovr_en = 1;
      $readmemh(ovrfile, ovm, 0, NSEG-1);
    end
    desc_addr  = DESC_ADDR_I[27:0];
    desc_count = DESC_COUNT_I;

    $display("TB WGTDMA: DESC_ADDR=%0d DESC_COUNT=%0d WBASE=%0d EXPN=%0d EXPB=%0d OVR=%0d WGT=%0d EXPECT_ERR=%0d",
             DESC_ADDR_I, DESC_COUNT_I, WBASE_I, expn, expb_expected, ovr_en, has_wgt, expect_err);
    $display("TB WGTDMA: RTL_IMGW=%0d RTL_IMGC=%0d RTL_GRP=%0d RTL_SHIFT=%0d RTL_MAXPIX=%0d",
             imgW, imgC, grp, shift, maxPix);
    if (imgC != 8 || grp != 1) begin
      $display("TB-ERROR: 本装置对着 dense 8x8 网表（imgC=8/grp=1），得到 %0d/%0d", imgC, grp);
      $fatal(1, "netlist shape mismatch");
    end
    if (expn > NSLICE) begin
      $display("TB-ERROR: +EXPN=%0d > 片数 %0d", expn, NSLICE); $fatal(1, "EXPN too big");
    end
    if (expn*NSEG > MAXEXP) begin
      $display("TB-ERROR: +EXPN=%0d 需要 %0d 字节 > MAXEXP=%0d", expn, expn*NSEG, MAXEXP);
      $fatal(1, "EXPBYTES too big"); end

    // ---- 复位 ----
    repeat (4) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    // ---- ★ C4b-B1：主机编程 `WGT_BLOB_BASE`（经权重信箱**区域 6**，4 个字节道小端）----
    //   非 0 ⇒ DMA 主路径打开；0 ⇒ 一个字节都不写（`UnitExec.dmaEn` 为假 ⇒ 旧信箱通路）。
    if (WBASE_I != 0) begin
      for (i = 0; i < 4; i = i + 1) begin
        @(negedge clk);
        wgt_we   = 1'b1;
        wgt_addr = 24'h600000 | i[23:0];     // 区域 6 + 道 i
        wgt_data = (WBASE_I >> (8*i)) & 32'hFF;
      end
      @(negedge clk);
      wgt_we = 1'b0; wgt_addr = 24'd0; wgt_data = 8'h00;
    end

    // ---- 可选：帧**之前**经信箱（区域 0、切片 0）预载 576 字节（C3/C4a 的旧通路）----
    if (has_wgt) begin
      wgt_sel = 3'd0;
      for (i = 0; i < NSEG; i = i + 1) begin
        @(negedge clk);
        wgt_we = 1'b1; wgt_addr = i[23:0]; wgt_data = wm[i];
      end
      @(negedge clk);
      wgt_we = 1'b0; wgt_addr = 24'd0; wgt_data = 8'h00;
    end

    // ---- 起跑：CTRL 一拍脉冲 ----
    ctrl = 1; got_ctrl = $value$plusargs("CTRL=%d", ctrl);
    repeat (2) @(negedge clk);
    @(negedge clk); go = 1'b1;
    @(negedge clk); go = 1'b0;

    // ---- 可选：覆盖作业（等本帧 DMA 装载**收工**后经信箱改切片 0）----
    if (ovr_en) begin
      ovr_wait = 0;
      while (dut.unitExec_1.wlRun !== 1'b1) begin
        @(posedge clk); ovr_wait = ovr_wait + 1;
        if (ovr_wait > 200000) begin
          $display("RESULT: FAIL 覆盖作业等不到 DMA 装载起跑（wlRun）"); $fatal(1, "no dma load"); end
      end
      while (dut.unitExec_1.wlRun !== 1'b0) begin
        @(posedge clk); ovr_wait = ovr_wait + 1;
        if (ovr_wait > 200000) begin
          $display("RESULT: FAIL 覆盖作业等不到 DMA 装载收工（wlRun）"); $fatal(1, "dma load stuck"); end
      end
      $display("TB WGTDMA: OVR_PUSH_AT=%0d（DMA 装载已收工，其后经信箱改切片 0）", ovr_wait);
      wgt_sel = 3'd0;
      for (i = 0; i < NSEG; i = i + 1) begin
        @(negedge clk);
        wgt_we = 1'b1; wgt_addr = i[23:0]; wgt_data = ovm[i];
      end
      @(negedge clk);
      wgt_we = 1'b0; wgt_addr = 24'd0; wgt_data = 8'h00;
    end

    // ---- 等 frameDone / err（带超时）----
    while (!fd_seen && !err_seen) begin
      @(posedge clk);
      if (err)     err_seen = 1'b1;
      else begin
        timeout_cnt = timeout_cnt + 1;
        if (timeout_cnt > timeout_lim) begin
          $display("RESULT: FAIL timeout(等 frameDone/err 超 %0d 拍；busy=%0d unitIndex=%0d)",
                   timeout_lim, busy, unitIndex);
          $fatal(1, "WgtDmaTb timeout");
        end
      end
    end
    repeat (4) @(negedge clk);

    $display("FRAME_DONE=%0d ERR_SEEN=%0d UNIT_INDEX=%0d WGT_BYTES=%0d",
             fd_seen, err_seen, unitIndex, wgt_bytes);
    $display("AR_TOTAL=%0d AR_N32=%0d AR_N128=%0d AW_TOTAL=%0d AW_N128=%0d B_OK=%0d",
             ar_total, ar_n32, ar_n128, aw_total, aw_n128, b_ok);

    // ---- err 作业：必须响亮 err 且**零设备搬运** ----
    if (expect_err) begin
      if (err_seen && !fd_seen && aw_total == 0 && b_ok == 0 && wr_bytes == 0 && wgt_bytes == 0) begin
        $display("ERRLESS_OK: 响亮 err + 零设备搬运（AW=0 B=0 wr_bytes=0 wgt_bytes=0）");
        $display("RESULT: PASS");
        $finish;
      end else begin
        $display("RESULT: FAIL 期待 err+零搬运，实际 err=%0d frameDone=%0d aw=%0d b=%0d wrb=%0d wgtb=%0d",
                 err_seen, fd_seen, aw_total, b_ok, wr_bytes, wgt_bytes);
        $fatal(1, "WgtDmaTb expected err with zero movement");
      end
    end

    // ---- 判据 ①：把各片 `WeightStore` 读回来逐字节对账 ----
    if (expn > 0) begin
      for (i = 0; i < NSLICE; i = i + 1) readback_slice(i[2:0]);
      compare_slices(expn);
      $display("STORE_TOTAL_MISMATCH=%0d（前 %0d 片，每片 %0d 字节）", total_mis, expn, NSEG);
    end

    // ---- 判据 ②：帧内真正装载的权重字节数 ----
    if (expb_expected >= 0) begin
      $display("WGT_BYTES_CHK got=%0d exp=%0d", wgt_bytes, expb_expected);
    end

    if (err_seen) begin
      $display("RESULT: FAIL 本帧报了 err（不该报的作业）"); $fatal(1, "unexpected err");
    end
    if (expn > 0 && total_mis != 0) begin
      $display("RESULT: FAIL store 对账不符（%0d 字节）", total_mis);
      $fatal(1, "store mismatch");
    end
    if (expb_expected >= 0 && wgt_bytes != expb_expected) begin
      $display("RESULT: FAIL 装载字节数 %0d != 期望 %0d", wgt_bytes, expb_expected);
      $fatal(1, "wgt bytes mismatch");
    end
    $display("RESULT: PASS");
    $finish;
  end

  // 兜底：仿真不收敛时也报红退出，别让闸门挂死。
  initial begin
    for (wd = 0; wd < WD_MAX; wd = wd + 1) @(posedge clk);
    $display("RESULT: FAIL timeout(global watchdog %0d cycles)", WD_MAX);
    $fatal(1, "WgtDmaTb global timeout");
  end

endmodule
