//=============================================================================
// LayoutAdaptTb.v —— ★★ C4b-B4：**conv 平面 ↔ 旁路 NHWC 的布局适配**（消费者侧 strided read）
//
// 被测行为（`gen/BypassExec.v` 新增的 `src_planar`/`dst_planar` 两条线）：
//   · `+SPLANAR=1`：源张量在 DDR 上是**通道平面**（conv 写的形状，`off(c,p)=c*Npix+p`）⇒ 本模块的
//     RD 通路按步长 `Npix` gather 成 NHWC 列流（一拍一列 = 一个像素的 C 个通道），再喂给单元；
//   · `+DPLANAR=1`：目标按**平面**写（平面 `c` = 第 `c` 道）⇒ 下一个消费者（conv 宽通路）读到平面。
//   ⇒ 本装置**只**把"那张平面张量"写进内存镜像（`+MEMFILE=`），其余全由 DUT 自己搬。
//
// 判据（闸门 `tools/run_layoutadapt_ab.sh` 收口；本装置**自检并报错**）：
//   1) **逐列逐通道**：DUT 收下的每一列（`col_dbg_0..7`，`col_dbg_ok` 采样）== 参考的 `colb.hex`
//      （一拍一列、列内 C 道）⇒ `COL_MISMATCH=0`，并把**首个坏列**报出来（可定位）；
//   2) **数值端到端**：DUT 在 AXI W 通道上**实际写出去的字节**（按 `awaddr + 8*beat` 重建）在 `DST`
//      区 == `goldb.hex`（平面序）⇒ `DST_MISMATCH=0`，并报**首个坏字节**；
//      ★ 这条**不看内存模型**（独立观察路径：看的是主口真实发出的写数据）；
//   3) **两处独立计数**：`rd_bytes == C*NPIX`（每 32 像素一组 × C 个平面 × 32 B）、
//      `wr_bytes == C*OUTPIX`；突发数 `AR == rd_bytes/32`、`AW == wr_bytes/32`（一笔不多不少）；
//   4) **退化守卫**：`COL_N == NPIX`（收下的列数 == 输入像素数）、`DONE/ERR` 各一次。
//
// 契约（plusarg）：
//   +S0..+S7 = 8 个描述符字（**真表** `gen/desc.bin` 的逐字拷贝，仅 C_IN/C_OUT 投影到 8、地址重定位）
//   +SPLANAR +DPLANAR +C +NPIX +OUTPIX +SRC +DST
//   +COLFILE=<期望列流（逐字节）>  +GOLDFILE=<期望 DST（逐字节、平面序）>
//   +COLOUTFILE=<DUT 收下的列流导出>  +MEMFILE= / +DUMPFILE=（转给 AxiMemModel）
//  stdout：`TB LADAPT: ...` 自报 + `RESULT: PASS|FAIL`（FAIL ⇒ $fatal ⇒ vvp 非 0）。
//=============================================================================
`timescale 1ns/1ps

module LayoutAdaptTb;
  localparam integer MEMSZ   = 2097152;
  localparam integer TIMEOUT = 900000;
  localparam integer MAXNPIX = 8192;       // 列数上限（本闸门的用例都落在这以内）
  localparam integer MAXCOLB = MAXNPIX*8;  // 列流字节上限
  localparam integer MAXG    = 65536;      // 期望 DST 字节上限

  reg clk = 1'b0;
  reg rst = 1'b1;
  always #5 clk = ~clk;

  reg         go;
  reg  [31:0] dw0, dw1, dw2, dw3, dw4, dw5, dw6, dw7;
  reg         sp, dp;
  wire        busy, done, err;
  wire [7:0]  cd0, cd1, cd2, cd3, cd4, cd5, cd6, cd7;
  wire        cdok;
  wire [31:0] rdb, wrb;
  wire [1:0]  opm;

  // AXI 主口
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
    .src_planar(sp), .dst_planar(dp),
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

  reg [8*256-1:0] colf, goldf, coloutf;
  reg [7:0] expcol [0:MAXCOLB-1];
  reg [7:0] gotcol [0:MAXCOLB-1];
  reg [7:0] expgold[0:MAXG-1];
  reg [7:0] dstimg [0:MAXG-1];
  integer fdo;

  integer C_, NPIX_, OUTPIX_, SRC_, DST_;
  integer i, k, ncol, colmis, colfirst, gmis, gfirst;
  integer cyc, timeout_cnt, aw_bursts, ar_bursts, w_beats, b_ok;
  reg done_seen, err_seen;
  reg [27:0] awaddr;
  integer bi;

  // AXI 写观察：把主口**真实发出的 W 拍**按 `awaddr + 8*bi` 落进 `dstimg`（块边界用 `wlast` 复位）
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
      // 列流捕获（`col_dbg_ok` = 本拍确实成交了一列）
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
    go = 1'b0; sp = 1'b0; dp = 1'b0;
    dw0 = 0; dw1 = 0; dw2 = 0; dw3 = 0; dw4 = 0; dw5 = 0; dw6 = 0; dw7 = 0;
    ncol = 0; colmis = 0; colfirst = -1; gmis = 0; gfirst = -1;
    cyc = 0; timeout_cnt = 0; aw_bursts = 0; ar_bursts = 0; w_beats = 0; b_ok = 0;
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
    if (!$value$plusargs("SPLANAR=%d", sp)) sp = 1'b0;
    if (!$value$plusargs("DPLANAR=%d", dp)) dp = 1'b0;
    if (!$value$plusargs("C=%d", C_)) begin $display("TB-ERROR: 缺 +C"); $fatal(1); end
    if (!$value$plusargs("NPIX=%d", NPIX_)) begin $display("TB-ERROR: 缺 +NPIX"); $fatal(1); end
    if (!$value$plusargs("OUTPIX=%d", OUTPIX_)) begin $display("TB-ERROR: 缺 +OUTPIX"); $fatal(1); end
    if (!$value$plusargs("SRC=%d", SRC_)) SRC_ = dw4;
    if (!$value$plusargs("DST=%d", DST_)) DST_ = dw5;
    if (!$value$plusargs("COLFILE=%s", colf)) begin $display("TB-ERROR: 缺 +COLFILE"); $fatal(1); end
    if (!$value$plusargs("GOLDFILE=%s", goldf)) begin $display("TB-ERROR: 缺 +GOLDFILE"); $fatal(1); end
    if (!$value$plusargs("COLOUTFILE=%s", coloutf)) begin $display("TB-ERROR: 缺 +COLOUTFILE"); $fatal(1); end
    $readmemh(colf, expcol, 0, C_*NPIX_-1);
    $readmemh(goldf, expgold, 0, C_*OUTPIX_-1);
    $display("TB LADAPT: desc=%08x %08x %08x %08x %08x %08x %08x %08x SPLANAR=%0d DPLANAR=%0d C=%0d NPIX=%0d OUTPIX=%0d SRC=%0d DST=%0d", dw0, dw1, dw2, dw3, dw4, dw5, dw6, dw7, sp, dp, C_, NPIX_, OUTPIX_, SRC_, DST_);

    repeat (10) @(negedge clk);
    rst = 1'b0;
    repeat (4) @(negedge clk);
    @(negedge clk); go = 1'b1;
    @(negedge clk); go = 1'b0;

    while (!done_seen && !err_seen && timeout_cnt < TIMEOUT) begin
      @(negedge clk); timeout_cnt = timeout_cnt + 1;
    end

    // 逐列逐通道对账
    for (i = 0; i < NPIX_*C_; i = i + 1) begin
      if (gotcol[i] !== expcol[i]) begin
        colmis = colmis + 1;
        if (colfirst < 0) colfirst = i / C_;
      end
    end
    // 数值端到端（主口真实写出的字节，按平面序）
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

    $display("TB LADAPT: col_dumped=%0d rd_bytes=%0d wr_bytes=%0d(逐笔事务计数) AR=%0d AW=%0d Wbeats=%0d(exp %0d) B=%0d", ncol, rdb, wrb, ar_bursts, aw_bursts, w_beats, C_*OUTPIX_/8, b_ok);
    $display("TB LADAPT: COL_N=%0d/%0d COL_MISMATCH=%0d COL_FIRST_BAD=%0d DST_MISMATCH=%0d DST_FIRST_BAD=%0d done=%0d err=%0d op=%0d cyc=%0d", ncol, NPIX_, colmis, colfirst, gmis, gfirst, done_seen, err_seen, opm, timeout_cnt);

    if (timeout_cnt >= TIMEOUT) begin
      $display("TB-ERROR: 超时（%0d 拍）", TIMEOUT); $display("RESULT: FAIL"); $fatal(1);
    end else if (err_seen) begin
      $display("TB-ERROR: DUT 报 err"); $display("RESULT: FAIL"); $fatal(1);
    end else if (colmis != 0) begin
      $display("TB-ERROR: 列流对不上（首坏列 %0d）", colfirst); $display("RESULT: FAIL"); $fatal(1);
    end else if (gmis != 0) begin
      $display("TB-ERROR: DST 对不上（首坏字节 %0d）", gfirst); $display("RESULT: FAIL"); $fatal(1);
    end else if (ncol != NPIX_) begin
      $display("TB-ERROR: 收下的列数 %0d != %0d", ncol, NPIX_); $display("RESULT: FAIL"); $fatal(1);
    end else if (ar_bursts != (sp ? C_*NPIX_/32 : C_*NPIX_/128) || w_beats != C_*OUTPIX_/8) begin
      $display("TB-ERROR: 突发计数不符 AR=%0d(exp %0d) Wbeats=%0d(exp %0d)", ar_bursts, (sp ? C_*NPIX_/32 : C_*NPIX_/128), w_beats, C_*OUTPIX_/8);
      $display("RESULT: FAIL"); $fatal(1);
    end else begin
      $display("TB LADAPT: RESULT: PASS");
      $display("RESULT: PASS");
    end
    $finish;
  end
endmodule
