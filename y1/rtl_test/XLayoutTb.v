//=============================================================================
// XLayoutTb.v —— ★★ C4b-B3：**输入布局契约**（DDR 的通道平面张量 → NPU 读到的 ci-block 列流）
//
// 被测行为（`gen/UnitExec.v` 的 `WIDERUN` + 本任务新增的 **DDR gather**）：
//   `XDMA_EN = 1`（信箱区域 7 道 0）⇒ 宽层的激活**不再由装置喂 `wide_x`**，而是本单元自己从
//   `SRC_ADDR` 的**通道平面（NCHW）**张量 gather 成行主序列流（一拍一列 = 一个像素的 8 个通道）。
//   ⇒ 本装置**只**往内存镜像里写"宿主的那张图"（`+XIN` 的字节落在 `+SRC`），其余全由 DUT 读。
//
// 判据（闸门 `tools/run_inlayout_ab.sh` 收口）：
//   1) **正对照（逐字节、逐列逐通道）**：`+XDUMP` 导出的"被 DUT 收下的列流" == 参考的
//      `x.hex`（= 冻结布局的预期列流）；`DST` 区 == `gold.hex`（数值端到端）；
//      `RD_PEAK == +XEXP`（gather 从 DDR 读回的字节数 == Σ_趟(有效平面数 × H*W)）。
//   2) **负对照（必须发火）**：`+XIN` 换成**通道序反**的图（`xin_bad.hex`）⇒ 列流 != 预期、
//      DST != 黄金（布局写错 ⇒ 必红）。
//
// 本装置**不驱动** `wide_x`（XDMA 通路的列来源在 DUT 内部）⇒ `wide_x_valid` 恒 0
//   （若 DUT 误走外部端口，列流会全 0 ⇒ 判据当场红 —— 这也是一条结构性判据）。
//
// 契约（plusarg）：
//   +CIN +COUT +GROUP +H +W +TYPE +FLAGS +SRC +DST +INB +QSHIFT +LID +M +ZPAD +ZY +NCOL +NCI +NCO
//   +WFILE=<wRam 字节（趟序，每趟 576）>  +BFILE=<bias_adj 字（NCO*8 行 int32）>
//   +XIN=<宿主写的图（C_IN*H*W 字节，通道平面）>  +XDUMP=<被收下的列流导出>  +XEXP=<期望 RD 字节>
//   +MEMFILE= / +DUMPFILE=（转给 AxiMemModel）
//  stdout：`TB XLAY: ...` 自报 + `RESULT: PASS|FAIL`（FAIL ⇒ $fatal ⇒ vvp 非 0）。
//=============================================================================
`timescale 1ns/1ps

module XLayoutTb;
  localparam integer MEMSZ   = 2621440;
  localparam integer TIMEOUT = 4000000;
  localparam integer WD_MAX  = 8000000;
  localparam integer MAXW    = 8 * 8 * 576;   // wRam 上限（8 co-block × 8 ci-block × 576）
  localparam integer MAXCOL  = 8 * 8 * 256;   // 列流上限（n_co*n_ci*H*W，H*W<=256）

  reg clk = 1'b0;
  reg rst = 1'b1;
  always #5 clk = ~clk;

  reg         go;
  reg  [31:0] desc0, desc1, desc2, desc3, desc4, desc5, desc6, desc7;
  reg  [15:0] wgt_base;
  reg  [31:0] wbase_dma;
  reg  [31:0] wexp_bytes;
  reg  [23:0] wgt_addr;
  reg  [7:0]  wgt_data;
  reg         wgt_we;
  reg  [15:0] chain_in;
  reg  [7:0]  wide_x [0:7];
  reg         wide_x_valid;
  wire        wide_x_ready, wide_on;
  wire [15:0] wide_passes;
  wire [31:0] rtl_m;
  wire [7:0]  rtl_zpad, rtl_zy, rtl_layer;
  wire [31:0] wgt_bytes;
  wire        busy, done, err;
  wire [15:0] imgC, imgW;
  wire [3:0]  grp;
  wire [7:0]  shift;
  wire [15:0] maxPix;
  wire [15:0] chain_rep, lmax;
  wire [31:0] rd_bytes, wr_bytes;
  reg  [1:0]  mid_rd_row;  reg [5:0] mid_rd_col;
  wire [7:0]  mid_rd_data_0, mid_rd_data_1, mid_rd_data_2, mid_rd_data_3;
  wire [7:0]  mid_rd_data_4, mid_rd_data_5, mid_rd_data_6, mid_rd_data_7;
  wire        head_mode;  wire [15:0] mid_rows;
  wire        tail_mode;  wire [15:0] tail_rows;
  // ★★ C4b-B3：列流观察口（DUT 收下的列 + 成交指示）
  wire [7:0]  x_dbg_0, x_dbg_1, x_dbg_2, x_dbg_3;
  wire [7:0]  x_dbg_4, x_dbg_5, x_dbg_6, x_dbg_7;
  wire        x_dbg_ok;

  wire        axi_aw_valid, axi_aw_ready;
  wire [27:0] axi_aw_payload_addr;  wire [3:0] axi_aw_payload_id;
  wire [7:0]  axi_aw_payload_len;   wire [2:0] axi_aw_payload_size;
  wire [1:0]  axi_aw_payload_burst; wire [3:0] axi_aw_payload_cache; wire [2:0] axi_aw_payload_prot;
  wire        axi_w_valid, axi_w_ready;
  wire [63:0] axi_w_payload_data;   wire [7:0] axi_w_payload_strb;  wire axi_w_payload_last;
  wire        axi_b_valid, axi_b_ready;
  wire [3:0]  axi_b_payload_id;     wire [1:0] axi_b_payload_resp;
  wire        axi_ar_valid, axi_ar_ready;
  wire [27:0] axi_ar_payload_addr;  wire [3:0] axi_ar_payload_id;
  wire [7:0]  axi_ar_payload_len;   wire [2:0] axi_ar_payload_size;
  wire [1:0]  axi_ar_payload_burst; wire [3:0] axi_ar_payload_cache; wire [2:0] axi_ar_payload_prot;
  wire        axi_r_valid, axi_r_ready;
  wire [63:0] axi_r_payload_data;   wire [3:0] axi_r_payload_id;
  wire [1:0]  axi_r_payload_resp;   wire axi_r_payload_last;

  UnitExec dut (
    .go(go),
    .desc_0(desc0), .desc_1(desc1), .desc_2(desc2), .desc_3(desc3),
    .desc_4(desc4), .desc_5(desc5), .desc_6(desc6), .desc_7(desc7),
    .wgt_base(wgt_base),
    .wgt_dma_addr(wbase_dma[27:0]), .wgt_bytes(wgt_bytes),
    .wgt_sel(3'd0), .wgt_addr(wgt_addr), .wgt_data(wgt_data), .wgt_we(wgt_we),
    .wide_x_0(wide_x[0]), .wide_x_1(wide_x[1]), .wide_x_2(wide_x[2]), .wide_x_3(wide_x[3]),
    .wide_x_4(wide_x[4]), .wide_x_5(wide_x[5]), .wide_x_6(wide_x[6]), .wide_x_7(wide_x[7]),
    .wide_x_valid(wide_x_valid), .wide_x_ready(wide_x_ready),
    .x_dbg_0(x_dbg_0), .x_dbg_1(x_dbg_1), .x_dbg_2(x_dbg_2), .x_dbg_3(x_dbg_3),
    .x_dbg_4(x_dbg_4), .x_dbg_5(x_dbg_5), .x_dbg_6(x_dbg_6), .x_dbg_7(x_dbg_7),
    .x_dbg_ok(x_dbg_ok),
    .busy(busy), .done(done), .err(err),
    .imgC(imgC), .imgW(imgW), .grp(grp), .shift(shift), .maxPix(maxPix),
    .chain_len(chain_in), .chain_len_rep(chain_rep), .lmax(lmax),
    .wide_on(wide_on), .wide_passes(wide_passes),
    .rtl_m(rtl_m), .rtl_zpad(rtl_zpad), .rtl_zy(rtl_zy), .rtl_layer(rtl_layer),
    .rd_bytes(rd_bytes), .wr_bytes(wr_bytes),
    .mid_rd_row(mid_rd_row), .mid_rd_col(mid_rd_col),
    .mid_rd_data_0(mid_rd_data_0), .mid_rd_data_1(mid_rd_data_1),
    .mid_rd_data_2(mid_rd_data_2), .mid_rd_data_3(mid_rd_data_3),
    .mid_rd_data_4(mid_rd_data_4), .mid_rd_data_5(mid_rd_data_5),
    .mid_rd_data_6(mid_rd_data_6), .mid_rd_data_7(mid_rd_data_7),
    .head_mode(head_mode), .mid_rows(mid_rows),
    .tail_mode(tail_mode), .tail_rows(tail_rows),
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

  reg [8*256-1:0] wfile, bfile, xinf, xdumpf;
  reg [7:0]  wm [0:MAXW-1];
  reg [7:0]  xin [0:MAXCOL*8-1];
  reg [31:0] bm [0:8*8-1];

  integer CIN, COUT, H, W, GROUP, TYPE_, FLAGS, SRC, DST, INB, QSHIFT, LID, MPASS, MZPAD, MZY, NCOL, NCI, NCO;
  integer XEXP;              // 期望 gather 从 DDR 读回的字节数
  integer i, k, lane, cob, co, nfed, cyc, timeout_cnt, xdumpN;
  integer NW, NENT;
  integer fdx;
  reg done_seen, err_seen;
  reg [31:0] rd_peak;
  integer ar_bursts, aw_bursts, b_ok;

  always @(posedge clk) begin
    if (!rst) begin
      if (axi_ar_valid && axi_ar_ready) ar_bursts = ar_bursts + 1;
      if (axi_aw_valid && axi_aw_ready) aw_bursts = aw_bursts + 1;
      if (axi_b_valid  && axi_b_ready)  b_ok      = b_ok + 1;
      if (rd_bytes > rd_peak) rd_peak = rd_bytes;
      if (err) err_seen = 1'b1;
    end
  end

  task wgt_write(input [23:0] a, input [7:0] d);
  begin
    @(negedge clk); wgt_addr = a; wgt_data = d; wgt_we = 1'b1;
    @(negedge clk); wgt_we = 1'b0; wgt_data = 8'h00; wgt_addr = 24'd0;
  end
  endtask

  initial begin
    go = 1'b0; wgt_base = 16'd0; wgt_addr = 24'd0; wgt_data = 8'd0; wgt_we = 1'b0;
    desc0 = 0; desc1 = 0; desc2 = 0; desc3 = 0; desc4 = 0; desc5 = 0; desc6 = 0; desc7 = 0;
    chain_in = 16'd1; wide_x_valid = 1'b0;
    for (i = 0; i < 8; i = i + 1) wide_x[i] = 8'h00;
    for (i = 0; i < MAXW; i = i + 1) wm[i] = 8'h00;
    for (i = 0; i < MAXCOL*8; i = i + 1) xin[i] = 8'h00;
    for (i = 0; i < 8*8; i = i + 1) bm[i] = 32'd0;
    mid_rd_row = 2'd0; mid_rd_col = 6'd0;
    done_seen = 1'b0; err_seen = 1'b0; timeout_cnt = 0; rd_peak = 32'd0;
    ar_bursts = 0; aw_bursts = 0; b_ok = 0; nfed = 0; cyc = 0; xdumpN = 0;
    wbase_dma = 32'd0; wexp_bytes = 32'd0;

    if (!$value$plusargs("CIN=%d", CIN))   begin $display("TB-ERROR: 缺 +CIN=");   $fatal(1,"CIN"); end
    if (!$value$plusargs("COUT=%d", COUT)) begin $display("TB-ERROR: 缺 +COUT=");  $fatal(1,"COUT"); end
    if (!$value$plusargs("H=%d", H))       begin $display("TB-ERROR: 缺 +H=");     $fatal(1,"H"); end
    if (!$value$plusargs("W=%d", W))       begin $display("TB-ERROR: 缺 +W=");     $fatal(1,"W"); end
    if (!$value$plusargs("GROUP=%d", GROUP)) GROUP = 1;
    if (!$value$plusargs("TYPE=%d", TYPE_)) TYPE_ = 1;
    if (!$value$plusargs("FLAGS=%d", FLAGS)) FLAGS = 1;
    if (!$value$plusargs("SRC=%d", SRC))   begin $display("TB-ERROR: 缺 +SRC=");   $fatal(1,"SRC"); end
    if (!$value$plusargs("DST=%d", DST))   begin $display("TB-ERROR: 缺 +DST=");   $fatal(1,"DST"); end
    if (!$value$plusargs("INB=%d", INB))   INB = CIN*H*W;
    if (!$value$plusargs("QSHIFT=%d", QSHIFT)) QSHIFT = 6;
    if (!$value$plusargs("LID=%d", LID))   LID = 0;
    if (!$value$plusargs("M=%d", MPASS))   begin $display("TB-ERROR: 缺 +M=");     $fatal(1,"M"); end
    if (!$value$plusargs("ZPAD=%d", MZPAD)) begin $display("TB-ERROR: 缺 +ZPAD="); $fatal(1,"ZPAD"); end
    if (!$value$plusargs("ZY=%d", MZY))    begin $display("TB-ERROR: 缺 +ZY=");    $fatal(1,"ZY"); end
    if (!$value$plusargs("NCOL=%d", NCOL)) begin $display("TB-ERROR: 缺 +NCOL=");  $fatal(1,"NCOL"); end
    if (!$value$plusargs("NCI=%d", NCI))   NCI = 1;
    if (!$value$plusargs("NCO=%d", NCO))   NCO = 1;
    if (!$value$plusargs("XEXP=%d", XEXP)) begin $display("TB-ERROR: 缺 +XEXP=");  $fatal(1,"XEXP"); end
    if (!$value$plusargs("WFILE=%s", wfile)) begin $display("TB-ERROR: 缺 +WFILE="); $fatal(1,"WFILE"); end
    if (!$value$plusargs("BFILE=%s", bfile)) begin $display("TB-ERROR: 缺 +BFILE="); $fatal(1,"BFILE"); end
    if (!$value$plusargs("XIN=%s", xinf))   begin $display("TB-ERROR: 缺 +XIN=");   $fatal(1,"XIN"); end
    if (!$value$plusargs("XDUMP=%s", xdumpf)) begin $display("TB-ERROR: 缺 +XDUMP="); $fatal(1,"XDUMP"); end

    NENT = 8 * 8 * 9;              // 每趟 576
    NW   = NCI * NCO * NENT;
    if (NW > MAXW)   begin $display("TB-ERROR: wRam 需要 %0d > %0d", NW, MAXW); $fatal(1,"wRam ovf"); end
    if (NCOL > MAXCOL) begin $display("TB-ERROR: 列流 %0d 越界", NCOL); $fatal(1,"x ovf"); end
    $readmemh(xinf, xin, 0, CIN*H*W - 1);      // ★ 宿主的那张图（通道平面）
    $readmemh(wfile, wm, 0, NW - 1);
    $readmemh(bfile, bm, 0, NCO*8 - 1);        // `bias_adj`（每行 8 个十六进制数字 = int32）

    // ---- 描述符（与 desc_table.pack 的位打包一致）----
    desc0 = (FLAGS << 8) | TYPE_;
    desc1 = W | (H << 16);
    desc2 = CIN | (COUT << 16);
    desc3 = GROUP | (1 << 8) | (1 << 12);
    desc4 = SRC;  desc5 = DST;  desc6 = INB;
    desc7 = QSHIFT | (LID << 8);
    $display("TB XLAY: CIN=%0d COUT=%0d H=%0d W=%0d GROUP=%0d SRC=%0d DST=%0d INB=%0d LID=%0d M=%0d ZPAD=%0d ZY=%0d NCOL=%0d NCI=%0d NCO=%0d XEXP=%0d",
             CIN, COUT, H, W, GROUP, SRC, DST, INB, LID, MPASS, MZPAD, MZY, NCOL, NCI, NCO, XEXP);

    repeat (4) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    // ---- 信箱：区域 1 = 趟瓦片 RAM；区域 2/3/4 = M/z_pad/z_y；区域 5 = bias_adj ----
    for (i = 0; i < NW; i = i + 1) wgt_write(24'h100000 + i[15:0], wm[i]);
    for (lane = 0; lane < 4; lane = lane + 1)
      wgt_write(24'h200000 | (LID[7:0] << 8) | lane[1:0], MPASS[8*lane +: 8]);
    wgt_write(24'h300000 | (LID[7:0] << 8), MZPAD[7:0]);
    wgt_write(24'h400000 | (LID[7:0] << 8), MZY[7:0]);
    for (cob = 0; cob < NCO; cob = cob + 1)
      for (co = 0; co < 8; co = co + 1)
        for (lane = 0; lane < 4; lane = lane + 1)
          wgt_write(24'h500000 | (LID[7:0] << 8) | (cob[2:0] << 5) | (co[2:0] << 2) | lane[1:0],
                    bm[cob*8 + co][8*lane +: 8]);
    // ★★ C4b-B3：区域 7 道 0 = `XDMA_EN = 1` ⇒ 激活由**本单元从 DDR gather**
    wgt_write(24'h700000, 8'h01);
    $display("TB XLAY: XDMA_EN programmed (region 7 lane 0 = 1)");

    // ---- 起跑 ----
    repeat (2) @(negedge clk);
    @(negedge clk); go = 1'b1;
    @(negedge clk); go = 1'b0;

    // ---- 打开列流导出文件 ----
    fdx = $fopen(xdumpf, "w");
    if (fdx == 0) begin $display("TB-ERROR: 打不开 +XDUMP=%0s", xdumpf); $fatal(1,"XDUMP"); end

    // ---- 观察：**本装置不喂 `wide_x`**（XDMA 通路的列在 DUT 内部）；只采样"被收下的列" ----
    while (!done_seen && !err_seen) begin
      wide_x_valid = 1'b0;
      @(negedge clk);
      if (x_dbg_ok) begin
        $fwrite(fdx, "%02x%02x%02x%02x%02x%02x%02x%02x\n",
                x_dbg_0, x_dbg_1, x_dbg_2, x_dbg_3, x_dbg_4, x_dbg_5, x_dbg_6, x_dbg_7);
        xdumpN = xdumpN + 1;
      end
      @(posedge clk);
      if (done) done_seen = 1'b1;
      else if (err) err_seen = 1'b1;
      cyc = cyc + 1;
      if (cyc > TIMEOUT) begin
        $display("RESULT: FAIL timeout(宽层 gather 等 done/err 超 %0d 拍；xdumpN=%0d/%0d)", TIMEOUT, xdumpN, NCOL);
        $fatal(1, "XLayoutTb timeout");
      end
    end
    wide_x_valid = 1'b0;
    repeat (4) @(negedge clk);
    $fclose(fdx);

    $display("TB XLAY RTL: imgC=%0d imgW=%0d WIDE_ON=%0d WIDE_PASSES=%0d RTL_M=%0d RTL_ZPAD=%0d RTL_ZY=%0d RTL_LAYER=%0d",
             imgC, imgW, wide_on, wide_passes, rtl_m, $signed(rtl_zpad), $signed(rtl_zy), rtl_layer);
    $display("CYCLES=%0d", cyc);
    $display("DONE_SEEN=%0d ERR_SEEN=%0d XDUMPN=%0d/%0d RD_PEAK=%0d RD_BYTES=%0d WGT_BYTES=%0d WR_BYTES=%0d AR=%0d AW=%0d B=%0d",
             done_seen, err_seen, xdumpN, NCOL, rd_peak, rd_bytes, wgt_bytes, wr_bytes,
             ar_bursts, aw_bursts, b_ok);

    // 通过条件：帧正常收工 + 收下的列数 == NCOL + WR/AW/B 对 + **gather 的突发数 == +XEXP/32**
    //   ★ 从 DDR **读回的总字节数**由内存模型独立给出（`MEM rd=`，见闸门）—— `DUT.rd_bytes` 是
    //     `DdrMaster` 的**每笔 start** 计数（CHK 里回零）⇒ 多笔突发的场景下它只反映最后一笔，
    //     不能当"总读字节"用（这是既有口径，不是本任务引入的）。
    if (done_seen && !err_seen && (xdumpN == NCOL) && (wr_bytes == COUT*H*W) &&
        (aw_bursts == ((COUT*H*W)/128)) && (b_ok == ((COUT*H*W)/128)) &&
        (ar_bursts == (XEXP/32))) begin
      $display("RESULT: PASS");
      $finish;
    end else begin
      $display("RESULT: FAIL done=%0d err=%0d xdumpN=%0d/%0d wr=%0d(期望 %0d) aw=%0d b=%0d ar=%0d(期望 %0d)",
               done_seen, err_seen, xdumpN, NCOL, wr_bytes, COUT*H*W, aw_bursts, b_ok, ar_bursts, XEXP/32);
      $fatal(1, "XLayoutTb failed");
    end
  end

  integer wd;
  initial begin
    for (wd = 0; wd < WD_MAX; wd = wd + 1) @(posedge clk);
    $display("RESULT: FAIL timeout(global watchdog %0d cycles)", WD_MAX);
    $fatal(1, "XLayoutTb global timeout");
  end
endmodule
