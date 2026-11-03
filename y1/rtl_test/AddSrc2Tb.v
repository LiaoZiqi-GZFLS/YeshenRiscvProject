//=============================================================================
// AddSrc2Tb.v —— ★★ C4b-E1：`Add` 的**第二路源**（表内偏移 `k` ⇒ `SRC2 = DST_ADDR[idx-k]`）聚焦装置。
//
// 被测行为（`gen/BypassExec.v` 新增的 `src2` 口 + `w3[31:16] = SRC2_K`，spec §4.6）：
//   `SRC2_K != 0`（且是 Add）⇒ 本模块走**两趟读**：A 趟读 `SRC_ADDR`（落片上），B 趟读 `src2`（逐列与 A
//   饱和相加）⇒ 输出 = `clamp8(A + B)`。本装置**只**把 A/B（以及"错 k"缓冲 C）写进内存镜像
//   （`+MEMFILE=`），其余全由 DUT 自己搬；`src2` 由 `+SRC2=` 直接给（在真系统里那是 `LayerSched` 的
//   **表内 DST 历史**算出来的，见 `LayerSched.scala` 与 `reports`）。
//
// 判据（闸门 `tools/run_addsrc2_ab.sh` 收口；本装置**自检并报错**）：
//   1) **逐列逐通道**：DUT 的 `col_dbg_0..7`（`col_dbg_ok` 采样）== B 的列流（`+COLFILE`，逐字节）
//      ⇒ `COL_MISMATCH=0`，并报**首个坏列**（可定位）；
//   2) **数值端到端**：DUT 在 AXI W 通道上**实际写出去**的字节 在 `DST` 区 == 黄金（`+GOLDFILE`）
//      ⇒ `DST_MISMATCH=0`，并报**首个坏字节**（可定位）；
//   3) **流量**：`rd_bytes == 2*C*NPIX`（A+B 两趟各一趟）、`wr_bytes == C*OUTPIX`；
//   4) **退化守卫**：`COL_N == NPIX`、`DONE/ERR` 各一次、`op == 2`（add）。
//
// 契约（plusarg）：
//   +S0..+S7 = 8 个描述符字（**真表** `gen/desc.bin` 的逐字拷贝，仅 C_IN/C_OUT 投影到 8、地址重定位）
//   +C +NPIX +OUTPIX +SRC +SRC2 +DST +COLFILE +GOLDFILE +COLOUTFILE +MEMFILE +DUMPFILE
//  stdout：`TB ADDS2: ...` 自报 + `RESULT: PASS|FAIL`（FAIL ⇒ $fatal ⇒ vvp 非 0）。
//=============================================================================
`timescale 1ns/1ps

module AddSrc2Tb;
  localparam integer MEMSZ   = 524288;     // 0x80000（= add_src2_ref.py 的 MEMSZ）
  localparam integer TIMEOUT = 900000;
  localparam integer MAXNPIX = 8192;
  localparam integer MAXCOLB = MAXNPIX*8;
  localparam integer MAXG    = MAXNPIX*8;

  reg clk = 1'b0;
  reg rst = 1'b1;
  always #5 clk = ~clk;

  reg         go;
  reg  [31:0] dw0, dw1, dw2, dw3, dw4, dw5, dw6, dw7;
  reg  [27:0] src2;
  wire        busy, done, err;
  wire [7:0]  cd0, cd1, cd2, cd3, cd4, cd5, cd6, cd7;
  wire        cdok;
  wire [31:0] rdb, wrb;
  wire [1:0]  opm;

  wire        axi_aw_valid, axi_aw_ready, axi_w_valid, axi_w_ready;
  wire [27:0] axi_aw_payload_addr;
  wire [3:0]  axi_aw_payload_id;
  wire [7:0]  axi_aw_payload_len;
  wire [2:0]  axi_aw_payload_size;
  wire [1:0]  axi_aw_payload_burst;
  wire [3:0]  axi_aw_payload_cache;
  wire [2:0]  axi_aw_payload_prot;
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

  BypassExec dut (
    .go(go),
    .desc_0(dw0), .desc_1(dw1), .desc_2(dw2), .desc_3(dw3),
    .desc_4(dw4), .desc_5(dw5), .desc_6(dw6), .desc_7(dw7),
    .busy(busy), .done(done), .err(err),
    .src_planar(1'b0), .dst_planar(1'b0), .src2(src2),
    .col_dbg_0(cd0), .col_dbg_1(cd1), .col_dbg_2(cd2), .col_dbg_3(cd3),
    .col_dbg_4(cd4), .col_dbg_5(cd5), .col_dbg_6(cd6), .col_dbg_7(cd7),
    .col_dbg_ok(cdok),
    .rd_bytes(rdb), .wr_bytes(wrb), .opMode(opm),
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

  reg [8*256-1:0] colf, goldf, coloutf, memf, dumpf;
  reg [7:0] expcol [0:MAXCOLB-1];
  reg [7:0] gotcol [0:MAXCOLB-1];
  reg [7:0] expgold[0:MAXG-1];
  reg [7:0] dstimg [0:MAXG-1];
  integer fdo;

  integer C_, NPIX_, OUTPIX_, SRC_, SRC2_, DST_;
  integer i, k, ncol, colmis, colfirst, gmis, gfirst;
  integer cyc, timeout_cnt, ar_bursts, aw_bursts, w_beats, b_ok;
  reg done_seen, err_seen;
  reg [27:0] awaddr;
  integer bi;

  always @(posedge clk) begin
    if (!rst) begin
      if (axi_ar_valid && axi_ar_ready) ar_bursts = ar_bursts + 1;
      if (axi_aw_valid && axi_aw_ready) begin
        aw_bursts = aw_bursts + 1; awaddr = axi_aw_payload_addr; bi = 0;
      end
      if (axi_w_valid && axi_w_ready) begin
        for (k = 0; k < 8; k = k + 1) begin
          if ((awaddr + bi*8 + k) >= DST_ && (awaddr + bi*8 + k) < DST_ + C_*OUTPIX_)
            dstimg[awaddr + bi*8 + k - DST_] = axi_w_payload_data[k*8 +: 8];
        end
        w_beats = w_beats + 1;
        bi = bi + 1;
        if (axi_w_payload_last) begin bi = 0; awaddr = awaddr + 28'd32; end
      end
      if (axi_b_valid && axi_b_ready) b_ok = b_ok + 1;
      if (cdok && ncol < MAXNPIX) begin
        gotcol[ncol*8+0] = cd0; gotcol[ncol*8+1] = cd1;
        gotcol[ncol*8+2] = cd2; gotcol[ncol*8+3] = cd3;
        gotcol[ncol*8+4] = cd4; gotcol[ncol*8+5] = cd5;
        gotcol[ncol*8+6] = cd6; gotcol[ncol*8+7] = cd7;
        ncol = ncol + 1;
      end
      if (done) done_seen = 1'b1;
      if (err)  err_seen  = 1'b1;
    end
  end

  initial begin
    go = 1'b0; src2 = 0;
    dw0 = 0; dw1 = 0; dw2 = 0; dw3 = 0; dw4 = 0; dw5 = 0; dw6 = 0; dw7 = 0;
    ncol = 0; colmis = 0; colfirst = -1; gmis = 0; gfirst = -1;
    cyc = 0; timeout_cnt = 0; ar_bursts = 0; aw_bursts = 0; w_beats = 0; b_ok = 0;
    done_seen = 1'b0; err_seen = 1'b0; awaddr = 0; bi = 0;
    for (i = 0; i < MAXCOLB; i = i + 1) begin expcol[i] = 8'h00; gotcol[i] = 8'h00; end
    for (i = 0; i < MAXG; i = i + 1) begin expgold[i] = 8'h00; dstimg[i] = 8'h00; end

    if (!$value$plusargs("S0=%h", dw0)) begin $display("TB-ERROR: 缺 +S0"); $fatal(1); end
    if (!$value$plusargs("S1=%h", dw1)) dw1 = 0;
    if (!$value$plusargs("S2=%h", dw2)) dw2 = 0;
    if (!$value$plusargs("S3=%h", dw3)) dw3 = 0;
    if (!$value$plusargs("S4=%h", dw4)) dw4 = 0;
    if (!$value$plusargs("S5=%h", dw5)) dw5 = 0;
    if (!$value$plusargs("S6=%h", dw6)) dw6 = 0;
    if (!$value$plusargs("S7=%h", dw7)) dw7 = 0;
    if (!$value$plusargs("C=%d", C_)) begin $display("TB-ERROR: 缺 +C"); $fatal(1); end
    if (!$value$plusargs("NPIX=%d", NPIX_)) begin $display("TB-ERROR: 缺 +NPIX"); $fatal(1); end
    if (!$value$plusargs("OUTPIX=%d", OUTPIX_)) OUTPIX_ = NPIX_;
    if (!$value$plusargs("SRC=%d", SRC_)) SRC_ = dw4;
    if (!$value$plusargs("SRC2=%d", SRC2_)) begin $display("TB-ERROR: 缺 +SRC2"); $fatal(1); end
    if (!$value$plusargs("DST=%d", DST_)) DST_ = dw5;
    if (!$value$plusargs("COLFILE=%s", colf)) begin $display("TB-ERROR: 缺 +COLFILE"); $fatal(1); end
    if (!$value$plusargs("GOLDFILE=%s", goldf)) begin $display("TB-ERROR: 缺 +GOLDFILE"); $fatal(1); end
    if (!$value$plusargs("COLOUTFILE=%s", coloutf)) begin $display("TB-ERROR: 缺 +COLOUTFILE"); $fatal(1); end
    if (!$value$plusargs("MEMFILE=%s", memf)) begin $display("TB-ERROR: 缺 +MEMFILE"); $fatal(1); end
    if (!$value$plusargs("DUMPFILE=%s", dumpf)) dumpf = "";

    // 内存镜像由 AxiMemModel 自己按 `+MEMFILE=` 预载（见其文件头）⇒ 本装置只喂列流/黄金。
    $readmemh(colf, expcol, 0, C_*NPIX_-1);
    $readmemh(goldf, expgold, 0, C_*OUTPIX_-1);
    src2 = SRC2_[27:0];
    $display("TB ADDS2: desc=%08x %08x %08x %08x %08x %08x %08x %08x C=%0d NPIX=%0d SRC=%0d SRC2=%0d DST=%0d",
             dw0, dw1, dw2, dw3, dw4, dw5, dw6, dw7, C_, NPIX_, SRC_, SRC2_, DST_);

    repeat (10) @(negedge clk);
    rst = 1'b0;
    repeat (4) @(negedge clk);
    @(negedge clk); go = 1'b1;
    @(negedge clk); go = 1'b0;

    while (!done_seen && !err_seen && timeout_cnt < TIMEOUT) begin
      @(negedge clk); timeout_cnt = timeout_cnt + 1;
    end

    for (i = 0; i < NPIX_*C_; i = i + 1) begin
      if (gotcol[i] !== expcol[i]) begin
        colmis = colmis + 1;
        if (colfirst < 0) colfirst = i / C_;
      end
    end
    for (i = 0; i < C_*OUTPIX_; i = i + 1) begin
      if (dstimg[i] !== expgold[i]) begin
        gmis = gmis + 1;
        if (gfirst < 0) gfirst = i;
      end
    end

    fdo = $fopen(coloutf, "w");
    if (fdo != 0) begin
      for (i = 0; i < ncol; i = i + 1)
        $fwrite(fdo, "%02x%02x%02x%02x%02x%02x%02x%02x\n",
                gotcol[i*8+0], gotcol[i*8+1], gotcol[i*8+2], gotcol[i*8+3],
                gotcol[i*8+4], gotcol[i*8+5], gotcol[i*8+6], gotcol[i*8+7]);
      $fclose(fdo);
    end

    $display("TB ADDS2: col_dumped=%0d rd_bytes=%0d wr_bytes=%0d AR=%0d AW=%0d Wbeats=%0d B=%0d",
             ncol, rdb, wrb, ar_bursts, aw_bursts, w_beats, b_ok);
    $display("TB ADDS2: COL_N=%0d/%0d COL_MISMATCH=%0d COL_FIRST_BAD=%0d DST_MISMATCH=%0d DST_FIRST_BAD=%0d done=%0d err=%0d op=%0d cyc=%0d",
             ncol, NPIX_, colmis, colfirst, gmis, gfirst, done_seen, err_seen, opm, timeout_cnt);

    if (timeout_cnt >= TIMEOUT) begin
      $display("TB-ERROR: 超时（%0d 拍）", TIMEOUT); $display("RESULT: FAIL"); $fatal(1);
    end else if (err_seen) begin
      $display("TB-ERROR: DUT 报 err"); $display("RESULT: FAIL"); $fatal(1);
    end else if (opm != 2'd2) begin
      $display("TB-ERROR: opMode=%0d != 2(add)", opm); $display("RESULT: FAIL"); $fatal(1);
    end else if (ncol != NPIX_) begin
      $display("TB-ERROR: 收下的列数 %0d != %0d", ncol, NPIX_); $display("RESULT: FAIL"); $fatal(1);
    end else if (colmis != 0) begin
      $display("TB-ERROR: 列流对不上（首坏列 %0d）", colfirst); $display("RESULT: FAIL"); $fatal(1);
    end else if (gmis != 0) begin
      $display("TB-ERROR: DST 对不上（首坏字节 %0d）", gfirst); $display("RESULT: FAIL"); $fatal(1);
    end else begin
      // 流量由 AxiMemModel 的独立计数（`MEM rd=/wr=`）在闸门侧对账（`DdrMaster.rd_r` 每笔 start 会清零
      // ⇒ 两趟读只反映后一趟；模型的总线计数才是权威的"两路读+一路写"）。
      $display("TB ADDS2: RESULT: PASS");
      $display("RESULT: PASS");
    end
    $finish;
  end
endmodule
