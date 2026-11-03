//=============================================================================
// UnitExecWideTb.v —— C4a.5b **宽层多趟通路（UnitExec 级）**的数值装置。
//
// 被测行为：`gen/UnitExec.v` 的 `WIDERUN` 通路（`rtl/UnitExec.scala`）—— 一个**宽层**
// （`C_in>8 || C_out>8`）经**权置信箱**把 §4.4 的 `M`、§4.5 的 `z_pad/z_y/bias_adj` 按 `LAYER_ID`
// 灌进片上参数表 ⇒ `UnitExec` 自己驱动 `ceil(C_in/8)×ceil(C_out/8)` 趟（跨 `ci` 趟在片上部分和里累加、
// **只在末趟做唯一一次 requant**）⇒ pad 行/列用 `z_pad` ⇒ 输出落 `DST`（DDR）。
//
// 本装置**不**做 RD（宽层的激活由 `wide_x` 列流喂）：因此：
//   · `wide_x` 每拍一列 8 通道；**趟序 = co-block 外、ci-block 内**；每趟只喂 `H` 行（`H*W` 列）；
//   · **第 `H` 行的下边填充行由 DUT 自己合成（= `z_pad`）** —— 装置不喂。
//   · 装置在 `wide_x_ready` 的拍上把 XFILE 的下一列摆上（`+XFILE` = `NCOL*8` 个字节）。
//
// 契约（plusarg）：
//   +CIN +COUT +GROUP +H +W +TYPE +FLAGS +SRC +DST +INB +QSHIFT +LID +M +ZPAD +ZY +NCOL +NCI +NCO
//   +WFILE=<wRam 字节（趟序，每趟 576）>  +XFILE=<wide_x 列流>  +BFILE=<bias_adj 字（NCO*8 行 int32）>
//   +MEMFILE= / +DUMPFILE=（转给 AxiMemModel）
// ★★ C4b-D1b：`+STRIDE=<1..15>`（**缺省 1 ⇒ 与 C4a.5b 逐字节同形**）= 卷积步长。
//   它只改描述符 `w3[11:8]` 的 `STRIDE` 域（`desc3`）——由 `UnitExec` 译出后**接给宽/窄两条通路的切片**
//   （见 `rtl/UnitExec.scala` 的 `strideEff` 一节的接线证据）。
//   ★ 几何口径（与 DUT 的 `inWOk`/`inRows` 同式，**必须一致**）：
//     · `+H`/`+W` 仍是**输出**几何（= 描述符 `IMG_H`/`IMG_W`）；
//     · DUT 每趟喂 `inRows = IMG_H·STRIDE` 个**真行**（本装置因此必须供 `NCOL = 趟数 × IMG_H·s × 网表 WIDTH` 列）；
//     · 网表行宽 `WIDTH` 必须落在 `[IMG_W·s-s+1, IMG_W·s]`（`s=1` ⇒ 退化成 `IMG_W == WIDTH`）。
// ★ C4b-B1b：`+WBASE=<addr>` 打开**权重段从 DDR 装载**（= `wgt_dma_addr`；0/缺省 = 关，与 C4a
//   逐字节同形）、`+WEXP=<n>` = 期望"从 DDR 读回的权重字节数"（关 DMA 时 0；开 DMA 时 = 段长）、
//   `+DUMPW=<file>` 帧后把 `wRam` 全量（36864 B，一字节一行十六进制）导出（白盒观察，零面积）。
//   ★★ T-S3d（2026-10-15）：`+WBASE × +TILED_W` 的两处判据增补 ——
//     · `+TMT=<n>`（缺省 4000000 ⇒ 与既有各闸门逐字节同形）= 等 done/err 的拍数上限
//       （**只给负对照把"挂住"压成短跑**：正向作业仍用缺省值）；
//     · 装载相位的**心跳签名** `DBG-PHASE`（每 50000 拍一行：`state/wSt/wlRun/wlCnt/dstate/rd_valid/rd_ready`）
//       —— 旧装置只在 gather 态（`wxSt==2 && wxK==0`）打印 ⇒ **装载相位挂住时一行都没有**
//       （这正是 spec §3.5 那档"无 done 无 err"看不出机理的原因）；
//     · tiled 判据补一条：`+WBASE` 打开时 `rd_peak` 必须 == `+WEXP=`（权重段的 RD 长度）
//       —— 直接抓"只读了一块 128 B 就挂"这类账不平（既有 tiled 档 `+WEXP=0` ⇒ 判据恒真、逐字节同形）。
//  stdout：`TB WIDE: ...` 自报 + `RESULT: PASS|FAIL`（FAIL ⇒ $fatal ⇒ vvp 非 0）。
//
// ★ 与既有 `UnitExecTb.v` 同款接线（DUT + AxiMemModel），但**只跑宽层**：本装置不驱动
//   `desc` 的链语义（`chain_len=1`），也不做 RD 相位。
//=============================================================================
`timescale 1ns/1ps

module UnitExecWideTb;
  localparam integer MEMSZ   = 2621440;
  localparam integer TIMEOUT = 4000000;
  localparam integer WD_MAX  = 24000000;
  localparam integer MAXW    = 8 * 8 * 576;   // wRam 上限（8 co-block × 8 ci-block × 576）
  localparam integer MAXCOL  = 8 * 8 * 256;   // x 列流上限（n_co*n_ci*H*W，H*W<=256）

  reg clk = 1'b0;
  reg rst = 1'b1;
  always #5 clk = ~clk;

  reg         go;
  reg  [31:0] desc0, desc1, desc2, desc3, desc4, desc5, desc6, desc7;
  reg  [15:0] wgt_base;
  reg  [31:0] wbase_dma;      // ★ C4b-B1b：`+WBASE=`（权重段在 DDR 的起点；0 = DMA 关）
  reg  [31:0] wexp_bytes;     // ★ C4b-B1b：`+WEXP=`（期望从 DDR 读回的权重字节数）
  reg  [23:0] wgt_addr;
  reg  [7:0]  wgt_data;
  reg         wgt_we;
  reg  [15:0] chain_in;
`ifdef UE_CGEOM
  // ★★ A'-2（2026-10-15）：**逐片几何入参的默认驱动** = 链描述符译码（全部槽同值 ⇒ "同型链"，
  //   与 chainLen==1/同型链的既有作业语义逐字一致）。
  //   ★ 为什么包在 `ifdef 里：本装置一份源码、**两族网表公用** —— `gen/UnitExec.v` / `_w32` / `_w640`
  //     （TILING=false）**没有**这些端口，`gen/UnitExec_tiled.v`（TILING=true）才有 ⇒ 只有编译
  //     **tiled** 网表的闸门给 `-DUE_CGEOM`（chain_wide / tiling2d_wide / tiling2d_rtl / wgtblob_tiled
  //     四个；其余 12 个闸门编译 TILING=false 网表 ⇒ 本块整体裁掉 = 与 A'-2 之前逐字节同形）。
  //   ★ 驱动是**组合**的（真源 = `desc0..desc7`）⇒ 作业中途改描述符自动跟随。
  reg  [15:0] cge_cin  [0:7];
  reg  [15:0] cge_cout [0:7];
  reg  [7:0]  cge_grp  [0:7];
  reg  [7:0]  cge_qsh  [0:7];
  reg  [7:0]  cge_lid  [0:7];
  reg         cge_dw   [0:7];
  reg         cge_x1   [0:7];
  integer     cge_i;
`endif
  reg  [7:0]  wide_x [0:7];
  reg         wide_x_valid;
  wire        wide_x_ready, wide_on;
  wire [15:0] wide_passes;
  wire [31:0] rtl_m;
  wire [7:0]  rtl_zpad, rtl_zy, rtl_layer;
  wire [31:0] wgt_bytes;
`ifdef UE_X1OBS
  // ★★ NPU v2 §4.6-5（slice A，2026-10-16）：**1×1 跳拍**的 tap-beat 观测口（`UnitExec.x1_beats`）。
  //   和上面的 `UE_CGEOM` 同一套手法：本装置一份源码、两族网表公用 —— 只有 `TILING=true` 的网表
  //   （`gen/UnitExec_tiled.v`）**才有**这个口 ⇒ 只有编译 tiled 网表、并且**要读这个数**的闸门
  //   （`run_x1skip_ab.sh`）给 `-DUE_X1OBS`；其余闸门（含全部 TILING=false 的 12 个）整体裁掉 ⇒ 逐字节同形。
  wire [31:0] x1_beats;
`endif
`ifdef UE_GBYTE
  // ★★ B1（2026-10-20）：**tileBuf 输入复用**的读计数口（`UnitExec.gather_bytes`）—— 同一套 ifdef 手法：
  //   只有 `TILING=true` 的网表有该端口，只有 `tools/run_b1_tilebuf_ab.sh` 给 `-DUE_GBYTE`。
  //   口径：本次 run 里 gather **首次交付**的输入字节数（唯一列字节 × 本 ci-block 的有效平面数；
  //   不含 32 B band 重取放大、不含 tile halo 去重 —— 见 `rtl/UnitExec.scala` 的「B1」一节）。
  wire [31:0] gather_bytes;
  // ★★ B2（2026-10-20）：**取数口径**（AR/band）的读计数口（`UnitExec.gather_fetch_bytes`）——
  //   与 `gather_bytes`（交付口径）**并存**：每完成一笔 32 B band FETCH +32（`wxOrphan` 的排空残留不数）。
  //   ★ B2 的 halo 判据只能挂在这个口上：交付口径在 B2 之后**不变**（halo 列仍交给 mpu，只是不 fetch）。
  wire [31:0] gather_fetch_bytes;
`endif
  wire        busy, done, err;
  wire [15:0] imgC, imgW;
  wire [19:0] row_w;      // ★★ T-S1：DUT 的**运行期行宽**（`go` 拍闩存的 `IMG_W·s`）观察口
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
    // ★ C4b-B1b：DMA 主路径开关（`+WBASE=0`/缺省 = **关** ⇒ 与 C3/C4a 逐字节同形）
    .wgt_dma_addr(wbase_dma[27:0]), .wgt_bytes(wgt_bytes),
    .wgt_sel(3'd0), .wgt_addr(wgt_addr), .wgt_data(wgt_data), .wgt_we(wgt_we),
    .wide_x_0(wide_x[0]), .wide_x_1(wide_x[1]), .wide_x_2(wide_x[2]), .wide_x_3(wide_x[3]),
    .wide_x_4(wide_x[4]), .wide_x_5(wide_x[5]), .wide_x_6(wide_x[6]), .wide_x_7(wide_x[7]),
    .wide_x_valid(wide_x_valid), .wide_x_ready(wide_x_ready),
    .busy(busy), .done(done), .err(err),
    .imgC(imgC), .imgW(imgW), .grp(grp), .shift(shift), .maxPix(maxPix),
    .row_w(row_w),      // ★★ T-S1：运行期行宽（观察口；见 rtl/UnitExec.scala 的「运行期行宽」一节）
    .chain_len(chain_in), .chain_len_rep(chain_rep), .lmax(lmax),
`ifdef UE_CGEOM
    // ★★ A'-2：逐片几何（每片自己的 = 描述符译码 ⇒ 同型链；见文件头 `UE_CGEOM` 一节）
    .chain_cin_0(cge_cin[0]), .chain_cin_1(cge_cin[1]), .chain_cin_2(cge_cin[2]), .chain_cin_3(cge_cin[3]),
    .chain_cin_4(cge_cin[4]), .chain_cin_5(cge_cin[5]), .chain_cin_6(cge_cin[6]), .chain_cin_7(cge_cin[7]),
    .chain_cout_0(cge_cout[0]), .chain_cout_1(cge_cout[1]), .chain_cout_2(cge_cout[2]), .chain_cout_3(cge_cout[3]),
    .chain_cout_4(cge_cout[4]), .chain_cout_5(cge_cout[5]), .chain_cout_6(cge_cout[6]), .chain_cout_7(cge_cout[7]),
    .chain_grp_0(cge_grp[0]), .chain_grp_1(cge_grp[1]), .chain_grp_2(cge_grp[2]), .chain_grp_3(cge_grp[3]),
    .chain_grp_4(cge_grp[4]), .chain_grp_5(cge_grp[5]), .chain_grp_6(cge_grp[6]), .chain_grp_7(cge_grp[7]),
    .chain_qsh_0(cge_qsh[0]), .chain_qsh_1(cge_qsh[1]), .chain_qsh_2(cge_qsh[2]), .chain_qsh_3(cge_qsh[3]),
    .chain_qsh_4(cge_qsh[4]), .chain_qsh_5(cge_qsh[5]), .chain_qsh_6(cge_qsh[6]), .chain_qsh_7(cge_qsh[7]),
    .chain_lid_0(cge_lid[0]), .chain_lid_1(cge_lid[1]), .chain_lid_2(cge_lid[2]), .chain_lid_3(cge_lid[3]),
    .chain_lid_4(cge_lid[4]), .chain_lid_5(cge_lid[5]), .chain_lid_6(cge_lid[6]), .chain_lid_7(cge_lid[7]),
    .chain_dw_0(cge_dw[0]), .chain_dw_1(cge_dw[1]), .chain_dw_2(cge_dw[2]), .chain_dw_3(cge_dw[3]),
    .chain_dw_4(cge_dw[4]), .chain_dw_5(cge_dw[5]), .chain_dw_6(cge_dw[6]), .chain_dw_7(cge_dw[7]),
    .chain_1x1_0(cge_x1[0]), .chain_1x1_1(cge_x1[1]), .chain_1x1_2(cge_x1[2]), .chain_1x1_3(cge_x1[3]),
    .chain_1x1_4(cge_x1[4]), .chain_1x1_5(cge_x1[5]), .chain_1x1_6(cge_x1[6]), .chain_1x1_7(cge_x1[7]),
`endif
    .wide_on(wide_on), .wide_passes(wide_passes),
`ifdef UE_X1OBS
    // ★★ NPU v2 §4.6-5（slice A）：1×1 跳拍的 tap-beat 计数（`TILING=true` 网表才有的口）
    .x1_beats(x1_beats),
`endif
`ifdef UE_GBYTE
    // ★★ B1：tileBuf 输入复用的读计数（`TILING=true` 网表才有的口）
    .gather_bytes(gather_bytes),
    // ★★ B2：取数口径（32 B band FETCH 字节）—— `TILING=true` 网表才有的口
    .gather_fetch_bytes(gather_fetch_bytes),
`endif
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

`ifdef UE_CGEOM
  // ★★ A'-2：逐片几何入参的组合驱动（真源 = 描述符 8 字；槽 0 == 描述符 ⇒ `UnitExec` 的
  //   "槽 0 == 链描述符" 断言在**所有**既有作业上天然成立；异型链（chainLen≥2 且逐片不同）在
  //   本装置上会被引擎互锁响亮拦下 —— 这正是 `run_chain_wide_ab.sh` 的"先红"期望）。
  always @(*) begin
    for (cge_i = 0; cge_i < 8; cge_i = cge_i + 1) begin
      cge_cin[cge_i]  = desc2[15:0];
      cge_cout[cge_i] = desc2[31:16];
      cge_grp[cge_i]  = desc3[7:0];
      cge_qsh[cge_i]  = desc7[7:0];
      cge_lid[cge_i]  = desc7[15:8];
      cge_dw[cge_i]   = (desc0[7:0] == 8'h03);
      cge_x1[cge_i]   = (desc0[7:0] == 8'h02);
    end
  end
`endif

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

`ifdef UE_GBYTE
  // ★★ B2（2026-10-20）：G7 的 CYC 标定 —— `WIDERUN` **喂列相位**（`wSt==3`）的拍数。
  //   判读（map §4 G7，先写死）：同一作业 `b2_hit=1` 比 `=0` 少 **≥15%** ⇒ 帧被冷突发限住（R4 成立）；
  //   两者持平（±5%）⇒ 帧被"每交付列"限住（R3 成立）。本装置只出数，不在这里判（判据在闸门脚本里）。
  //   ★ 状态码引用的是**已生成网表**的枚举：`UnitExecPhase_WIDERUN = 4'd7`（`gen/UnitExec_tiled.v`
  //     的 localparam 表），`wSt==3'd3` = 本趟喂列相位。
  integer cyc_wr;
  initial cyc_wr = 0;
  // ★ G2-P0（2026-10-22，仅装置）：宽路**分相拍数** —— 用同一作业在 `+RDLAT=0/640` 两档下的
  //   差值判定 gather 的耗时到底在"等数据"还是"在喂列/写回"。`cyc_fetch` = wxSt==FETCH（等 band）。
  integer cyc_fetch, cyc_emit, cyc_decide, cyc_wtld, cyc_wtst;
  initial begin cyc_fetch = 0; cyc_emit = 0; cyc_decide = 0; cyc_wtld = 0; cyc_wtst = 0; end
  always @(posedge clk) if (!rst && dut.wtOn) begin
    if (dut.wtSt == 2'd1) cyc_wtld = cyc_wtld + 1;
    if (dut.wtSt == 2'd2) cyc_wtst = cyc_wtst + 1;
  end
  always @(posedge clk) if (!rst) begin
    if ((dut.state == 4'd7) && (dut.wSt == 3'd3)) begin
      if (dut.wxSt == 2'd2) cyc_fetch  = cyc_fetch + 1;
      if (dut.wxSt == 2'd3) cyc_emit   = cyc_emit + 1;
      if (dut.wxSt == 2'd1) cyc_decide = cyc_decide + 1;
    end
  end
  always @(posedge clk) begin
    if (!rst && (dut.state == 4'd7) && (dut.wSt == 3'd3)) cyc_wr = cyc_wr + 1;
  end
  // ★ W-attrib（2026-10-23，仅装置）：喂列相位的**三态**计数 —— 分清"算得慢"还是"等 gather"。
  integer cyc_col_ok, cyc_no_valid, cyc_mpu_busy;
  initial begin cyc_col_ok = 0; cyc_no_valid = 0; cyc_mpu_busy = 0; end
  always @(posedge clk) if (!rst && (dut.state == 4'd7) && (dut.wSt == 3'd3)) begin
    if (dut.mpu_x_valid && dut.mpu_x_ready) cyc_col_ok    = cyc_col_ok + 1;
    else if (!dut.mpu_x_valid)                 cyc_no_valid  = cyc_no_valid + 1;
    else                                          cyc_mpu_busy  = cyc_mpu_busy + 1;
  end
`endif

  reg [8*256-1:0] xfile, wfile, bfile;
  reg [8*256-1:0] wdumpf;      // ★ C4b-B1b：`+DUMPW=`（wRam 白盒导出）
  reg [8*256-1:0] bdumpf;      // ★★ C4b-B2：`+DUMPB=`（`biasReg`（参数表装载后的**在片寄存器**）白盒导出）
  reg [7:0]  wm [0:MAXW-1];
  reg [7:0]  xm [0:MAXCOL*8-1];
  reg [31:0] bm [0:8*8-1];

  integer CIN, COUT, H, W, GROUP, TYPE_, FLAGS, SRC, DST, INB, QSHIFT, LID, MPASS, MZPAD, MZY, NCOL, NCI, NCO;
  integer CHAINLEN;            // ★★ T-S3f：`+CHAINLEN=`（缺省 1 ⇒ 旧行为）
  integer STRIDE;              // ★★ C4b-D1b：卷积步长（`+STRIDE=`，缺省 1 = C4a.5b 行为）
  integer fdw, j;              // ★ C4b-B1b：wRam 白盒导出的文件句柄 / 数组下标
  integer fdb;                 // ★★ C4b-B2：`+DUMPB=` 的文件句柄
  integer i, k, lane, cob, co, nfed, accept, cyc, timeout_cnt;
  integer TMT;                       // ★★ T-S3d：等 done/err 的拍数上限（`+TMT=`，缺省 = TIMEOUT）
  integer NW, NENT;
  // ★★ B1（2026-10-20）：输入读计数判据的 plusarg/结果（`+GEXP=<n>`；缺省 -1 = 不判）。
  //   `gb_ok` 缺省 1 ⇒ 没给 `+GEXP=`（或没开 `-DUE_GBYTE`）时判据与既有各闸门**逐字同形**。
  integer GEXP; reg gb_ok;
  // ★★ B2（2026-10-20）：**取数口径**判据的 plusarg/结果（`+FEXP=<n>`；缺省 -1 = 不判；`fb_ok` 缺省 1）。
  //   与 `+GEXP` 同一手法 ⇒ 既有闸门（不给 `+FEXP`）的判据**一字不变**。
  integer FEXP; reg fb_ok;
  // ★★ T-S2b：`+TILED_W` 模式 —— 跑 `gen/UnitExec_tiled.v`（`TILING=true`）的**宽路 tile 循环**：
  //   激活由 **DDR 平面行跨步 halo gather** 取（不用 `wide_x` 列流）⇒ 本装置**不喂列**、只打开
  //   `XDMA_EN`（信箱区域 7）并等 done/err；数值由闸门拿整层黄金逐字节对账（装置不做字节数判据）。
  reg tiled_w_en; integer tiled_wi; integer got_tiled_w;
  reg done_seen, err_seen;
  reg [31:0] rd_peak;
  integer ar_bursts, aw_bursts, b_ok;

  always @(posedge clk) begin
    if (!rst) begin
      if (axi_ar_valid && axi_ar_ready) ar_bursts = ar_bursts + 1;
      if (axi_aw_valid && axi_aw_ready) aw_bursts = aw_bursts + 1;
      if (axi_b_valid  && axi_b_ready)  b_ok      = b_ok + 1;
      if (rd_bytes > rd_peak) rd_peak = rd_bytes;
      // ★ C4b-B1b：`err` 是**单拍脉冲**（进门那一拍就落），喂列循环的采样点可能错过它 ⇒
      //   在时钟沿上锁存"看见过 err"（老装置只靠循环里采样，`+CIN=3` 这类**进门即 err** 的用例会漏）。
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
    for (i = 0; i < MAXCOL*8; i = i + 1) xm[i] = 8'h00;
    for (i = 0; i < 8*8; i = i + 1) bm[i] = 32'd0;
    mid_rd_row = 2'd0; mid_rd_col = 6'd0;
    done_seen = 1'b0; err_seen = 1'b0; timeout_cnt = 0; rd_peak = 32'd0;
    ar_bursts = 0; aw_bursts = 0; b_ok = 0; nfed = 0; cyc = 0;
    tiled_w_en = 1'b0; got_tiled_w = 0;

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
    // ★★ C4b-D1b：卷积步长（缺省 1 ⇒ `desc3` 的 `STRIDE=1`，与 C4a.5b **逐字节同形**）
    if (!$value$plusargs("STRIDE=%d", STRIDE)) STRIDE = 1;
    if (STRIDE < 1 || STRIDE > 15) begin $display("TB-ERROR: +STRIDE=%0d 越界 [1,15]", STRIDE); $fatal(1,"STRIDE"); end
    if (!$value$plusargs("XFILE=%s", xfile)) begin $display("TB-ERROR: 缺 +XFILE="); $fatal(1,"XFILE"); end
    if (!$value$plusargs("WFILE=%s", wfile)) begin $display("TB-ERROR: 缺 +WFILE="); $fatal(1,"WFILE"); end
    if (!$value$plusargs("BFILE=%s", bfile)) begin $display("TB-ERROR: 缺 +BFILE="); $fatal(1,"BFILE"); end
    // ★ C4b-B1b：DMA 主路径（缺省关）+ 期望的 DDR 权重读字节数 + wRam 导出（缺省不导）
    if (!$value$plusargs("WBASE=%d", wbase_dma)) wbase_dma = 32'd0;
    if (!$value$plusargs("WEXP=%d", wexp_bytes))  wexp_bytes = 32'd0;
    // ★★ T-S2b：宽路 tile 循环模式（缺省关 ⇒ 与既有宽层闸门逐字节同形）
    got_tiled_w = $test$plusargs("TILED_W");
    if (got_tiled_w) tiled_w_en = 1'b1;
    // ★★ T-S3f：`+CHAINLEN=<n>`（缺省 1 ⇒ 与既有各闸门逐字节同形）= DUT 的 `io.chain_len`。
    //   链描述符 = 链首的 8 个字 + 链尾的 DST；`n ≥ 2` 即"一条 head middle* tail 链"。
    //   ★ T-S3f 起手（先红）：宽路的四条判据都带 `chain_len==1` ⇒ 当前网表对 `n≥2` **响亮 err + 零搬运**。
    if (!$value$plusargs("CHAINLEN=%d", CHAINLEN)) CHAINLEN = 1;
    chain_in = CHAINLEN[15:0];
    // ★★ T-S3d：等 done/err 的拍数上限（缺省 = TIMEOUT ⇒ 既有闸门逐字节同形）
    if (!$value$plusargs("TMT=%d", TMT)) TMT = TIMEOUT;
    // ★★ B1：输入读计数判据（缺省 `gb_ok=1` ⇒ 既有各闸门逐字同形）
    GEXP = -1; gb_ok = 1'b1;
    // ★★ B2：取数口径判据（缺省 `fb_ok=1` ⇒ 既有各闸门逐字同形）
    FEXP = -1; fb_ok = 1'b1;
    $display("TB TILED_W_EN=%0d GOT=%0d", tiled_w_en, got_tiled_w);

    NENT = 8 * 8 * 9;              // 每趟 576
    NW   = NCI * NCO * NENT;
    if (NW > MAXW)   begin $display("TB-ERROR: wRam 需要 %0d > %0d", NW, MAXW); $fatal(1,"wRam ovf"); end
    // ★★ T-S2b：tiled_w 模式**不喂列流**（激活由 DDR gather 取）⇒ NCOL 与列缓冲无关，跳过该越界检查。
    if (!tiled_w_en && (NCOL*8 > MAXCOL*8)) begin $display("TB-ERROR: x 列流 %0d 越界", NCOL); $fatal(1,"x ovf"); end
    $readmemh(xfile, xm, 0, (tiled_w_en ? 0 : (NCOL*8 - 1)));
    $readmemh(wfile, wm, 0, NW - 1);
    $readmemh(bfile, bm, 0, NCO*8 - 1);

    // ---- 描述符（与 desc_table.pack 的位打包一致）----
    desc0 = (FLAGS << 8) | TYPE_;            // TYPE, FLAGS
    desc1 = W | (H << 16);                   // IMG_W, IMG_H
    desc2 = CIN | (COUT << 16);              // C_IN, C_OUT
    desc3 = GROUP | ((STRIDE & 15) << 8) | (1 << 12);  // GROUP, ★C4b-D1b STRIDE, PAD=1
    desc4 = SRC;  desc5 = DST;  desc6 = INB;
    desc7 = QSHIFT | (LID << 8);             // QUANT_SHIFT, LAYER_ID
    $display("TB WIDE: CIN=%0d COUT=%0d H=%0d W=%0d GROUP=%0d STRIDE=%0d TYPE=%0d FLAGS=%0d SRC=%0d DST=%0d INB=%0d QSHIFT=%0d LID=%0d M=%0d ZPAD=%0d ZY=%0d NCOL=%0d NCI=%0d NCO=%0d",
             CIN, COUT, H, W, GROUP, STRIDE, TYPE_, FLAGS, SRC, DST, INB, QSHIFT, LID, MPASS, MZPAD, MZY, NCOL, NCI, NCO);

    repeat (4) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    // ---- 信箱：区域 1 = 趟瓦片 RAM（按趟序逐字节）----
    for (i = 0; i < NW; i = i + 1) wgt_write(24'h100000 + i[15:0], wm[i]);
    // ---- 区域 2 = M（4 字节小端，道 0..3）；区域 3 = z_pad；区域 4 = z_y ----
    for (lane = 0; lane < 4; lane = lane + 1)
      wgt_write(24'h200000 | (LID[7:0] << 8) | lane[1:0], MPASS[8*lane +: 8]);
    wgt_write(24'h300000 | (LID[7:0] << 8), MZPAD[7:0]);
    wgt_write(24'h400000 | (LID[7:0] << 8), MZY[7:0]);
    // ---- 区域 5 = bias_adj：`[LAYER_ID][co-block][co]` 每字 4 道（0..3）----
    for (cob = 0; cob < NCO; cob = cob + 1)
      for (co = 0; co < 8; co = co + 1)
        for (lane = 0; lane < 4; lane = lane + 1)
          wgt_write(24'h500000 | (LID[7:0] << 8) | (cob[2:0] << 5) | (co[2:0] << 2) | lane[1:0],
                    bm[cob*8 + co][8*lane +: 8]);
    // ★★ T-S2b：区域 7 = `XDMA_EN`（低 2 位 == 0 的那一拍 bit0=1）⇒ 宽路 tile 的激活走 DDR gather。
    if (tiled_w_en) wgt_write(24'h700000, 8'h01);

    // ---- 起跑 ----
    repeat (2) @(negedge clk);
    @(negedge clk); go = 1'b1;
    @(negedge clk); go = 1'b0;

    // ---- 喂 `wide_x` 列流（只喂前 H 行；pad 行由 DUT 合成）----
    //   ★★ T-S2b：`tiled_w_en` ⇒ **不喂**（激活由 DDR gather 取），只等 done/err。
    while (!done_seen && !err_seen) begin
      if (!tiled_w_en && (nfed < NCOL)) begin
        for (k = 0; k < 8; k = k + 1) wide_x[k] = xm[nfed*8 + k];
        wide_x_valid = 1'b1;
      end else wide_x_valid = 1'b0;
      #1;
      accept = wide_x_valid && wide_x_ready;
      @(negedge clk);
      if (accept) nfed = nfed + 1;
      @(posedge clk);
      if (done) done_seen = 1'b1;
      else if (err) err_seen = 1'b1;
      cyc = cyc + 1;
      if (tiled_w_en && (dut.wxSt == 2 && dut.wxK == 0 && cyc > 200 && cyc < 6000))
        $display("DBG-STALL cyc=%0d wSt=%0d wRow=%0d wCol=%0d wxSt=%0d wxK=%0d fPl=%0d fAdr=%0d needB=%0d bandV=%0d dstate=%0d",
                 cyc, dut.wSt, dut.wRow, dut.wCol, dut.wxSt, dut.wxK, dut.wxFPl, dut.wxFAdrR,
                 dut.wxNeedB, dut.wxBandV, dut.ddrMaster_1.state);
      // ★★ T-S3d：**装载相位 / 全局心跳**（每 50000 拍一行）。旧装置只在 gather 态打印
      //   ⇒ "权重 blob 装载挂住"那一档（`wgtrun` 里 `rd_ready` 恒 0）**一行日志都没有**，
      //   这正是 spec §3.5 看不出机理的原因。本行把 `state/wSt/wlRun/wlCnt/dstate/rd_valid/rd_ready` 亮出来。
      if (tiled_w_en && !done_seen && !err_seen && (cyc % 50000 == 0))
        $display("DBG-PHASE cyc=%0d state=%0d wSt=%0d wlRun=%0d wlCnt=%0d dstate=%0d rd_valid=%0d rd_ready=%0d busy=%0d",
                 cyc, dut.state, dut.wSt, dut.wlRun, dut.wlCnt, dut.ddrMaster_1.state,
                 dut.ddrMaster_1_rd_valid, dut.ddrMaster_1_rd_ready, dut.ddrMaster_1_busy);
      if (cyc > TMT) begin
        $display("RESULT: FAIL timeout(宽层多趟等 done/err 超 %0d 拍；nfed=%0d/%0d)", TMT, nfed, NCOL);
        $fatal(1, "UnitExecWideTb timeout");
      end
    end
    wide_x_valid = 1'b0;
    repeat (4) @(negedge clk);

    $display("TB WIDE RTL: imgC=%0d imgW=%0d RTL_MAXPIX=%0d WIDE_ON=%0d WIDE_PASSES=%0d RTL_M=%0d RTL_ZPAD=%0d RTL_ZY=%0d RTL_LAYER=%0d",
             imgC, imgW, maxPix, wide_on, wide_passes, rtl_m, $signed(rtl_zpad), $signed(rtl_zy), rtl_layer);
    // ★★ T-S1：**运行期行宽**（= `IMG_W·s`，`go` 拍闩存）。一张网表跑 6 个行宽的层时，
    //   本行会打印出 6 个**不同**的值 —— "运行期闩存真的在跑"的直接证据（负对照把闩存钉成常量后，
    //   这一路也跟着钉住 ⇒ 与 `+W`（输出宽）不再自洽，见 run_roww_ab.sh）。
    $display("TB WIDE ROW: RTL_ROW_W=%0d (输入行宽 = IMG_W·STRIDE)", row_w);
    // ★★ C4b-B2：`go` → `done/err` 的**拍数**（装载与计算重叠纪律的**受控实验**观察量：
    //   同一单元 `+WBASE` 开/关两跑的差值 = 串行装载的**代价**；详见 `tools/run_paramdel_ab.sh`）。
    $display("CYCLES=%0d", cyc);
    // G2-P0：分相拍数（fetch=等 band / emit=喂列 / decide=判 band；wr=写相位）
    // ★ 2026-10-25：逐相位计数器已随 RTL 侧探针移除（G2 之后），这里改成**可选**打印，
    //   否则整个 wide 闸门会因层次引用缺失而编译失败（继承债）。要复测相位请先在 RTL 里恢复
    //   `cycFetch/cycEmit/...` 并加 `-DUE_PHASE`。
`ifdef UE_PHASE
    $display("PHASE fetch=%0d emit=%0d decide=%0d wr=%0d AR=%0d", cyc_fetch, cyc_emit, cyc_decide, cyc_wr, ar_bursts);
    $display("PHASE2 wt_load=%0d wt_stream=%0d", cyc_wtld, cyc_wtst);
    $display("PHASE3 col_ok=%0d no_valid=%0d mpu_busy=%0d", cyc_col_ok, cyc_no_valid, cyc_mpu_busy);
`endif
`ifdef UE_X1OBS
    // ★★ NPU v2 §4.6-5（slice A）：**tap-beat 实测**（= `arr.en` 拍数；上电起累计）。
    //   它是 `mac_account.py` 的 `beats_issued = taps·passes·H·W` 的实测面：
    //   同一作业/同一权重/同一几何，TYPE=1（3×3 ⇒ 9 拍/像素/趟）对 TYPE=2（1×1 ⇒ 1 拍/像素/趟）⇒ 9.00×。
    $display("X1_BEATS=%0d", x1_beats);
`endif
    $display("DONE_SEEN=%0d ERR_SEEN=%0d NFED=%0d/%0d RD_PEAK=%0d RD_BYTES=%0d WGT_BYTES=%0d WR_BYTES=%0d AR=%0d AW=%0d B=%0d WBASE=%0d",
             done_seen, err_seen, nfed, NCOL, rd_peak, rd_bytes, wgt_bytes, wr_bytes,
             ar_bursts, aw_bursts, b_ok, wbase_dma);

    // ★★ B1（2026-10-20）：**输入读计数**判据 —— `gather_bytes` 与 `+GEXP=` 逐值对账。
    //   `+GEXP=` 缺省 ⇒ `GEXP=-1` ⇒ `gb_ok` 保持 1（既有闸门一字不变）。
    //   ★ 这条判据是**可归因的**：网表一行突变把 `b1_play` 打平（= 旧行为"每个 co-block 都重读"）⇒
    //     数值**仍然**逐字节对（重读得到的是同一份输入），只有本计数翻 `nCo` 倍 ⇒ 红点唯一。
`ifdef UE_GBYTE
    if ($value$plusargs("GEXP=%d", GEXP)) gb_ok = (gather_bytes == GEXP);
    $display("GATHER_BYTES=%0d GEXP=%0d GB_OK=%0d", gather_bytes, GEXP, gb_ok);
`else
    $display("GATHER_BYTES=NA GEXP=-1（本编译没开 -DUE_GBYTE：不判）");
`endif
`ifdef UE_GBYTE
    // ★★ B2（2026-10-20）：**取数口径**判据（`+FEXP=`；缺省不判 ⇒ 既有判据逐字同形）+ G7 的 CYC 出数。
    //   ★ 本块**不改**上面那条既有 PASS 判据的任何一行：只在它之前对 FEXP 单独发火（负对照 = `b2_hit:=0`）。
    if ($value$plusargs("FEXP=%d", FEXP)) fb_ok = (gather_fetch_bytes == FEXP);
    $display("GATHER_FETCH_BYTES=%0d FEXP=%0d FB_OK=%0d CYC_WR=%0d", gather_fetch_bytes, FEXP, fb_ok, cyc_wr);
    if (!fb_ok) begin
      $display("RESULT: FAIL tiled_w=%0d 取数口径 gather_fetch_bytes=%0d != FEXP=%0d（b2_hit 没生效？）",
               tiled_w_en, gather_fetch_bytes, FEXP);
      $fatal(1, "FEXP mismatch");
    end
`else
    $display("GATHER_FETCH_BYTES=NA FEXP=-1（本编译没开 -DUE_GBYTE：不判）");
`endif

    // ★ C4b-B1b：白盒导出 `wRam`（**判据 ①** 的观察口；与 `WeightStore` 的 `tile` 口同一套"零面积"口径）
    if ($value$plusargs("DUMPW=%s", wdumpf)) begin
      fdw = $fopen(wdumpf, "w");
      if (fdw == 0) begin $display("TB-ERROR: 打不开 +DUMPW=%0s", wdumpf); $fatal(1,"DUMPW"); end
      for (j = 0; j < MAXW; j = j + 1) $fwrite(fdw, "%02x\n", dut.wRam[j]);
      $fclose(fdw);
      $display("WRAM_DUMPED %0s (%0d bytes)", wdumpf, MAXW);
    end

    // ★★ C4b-B2：白盒导出 `biasReg`（= §4.5 的 `bias_adj` **在片寄存器**，参数**投递之后**的值）。
    //   为什么这是"逐单元、逐字等值"判据的观察面（而不是靠输出反推）：
    //     `biasReg` 是 `biasMem` 经 `LAYER_ID` 装载器取回的对象本身 ⇒ 把它与 `wgt_index.json` 的
    //     `centering[].bias_adj` **逐字**对账，就**直接**证了"投递值 == 单一真源"（M/z_pad/z_y 由既有
    //     `RTL_M/RTL_ZPAD/RTL_ZY` 自报口承担）；输出逐字节对账是**另一条独立**的证据。
    //   零面积：纯层级引用（与 `+DUMPW` 同一手法），**不进网表**。
    if ($value$plusargs("DUMPB=%s", bdumpf)) begin
      fdb = $fopen(bdumpf, "w");
      if (fdb == 0) begin $display("TB-ERROR: 打不开 +DUMPB=%0s", bdumpf); $fatal(1,"DUMPB"); end
      $fwrite(fdb, "%08x\n", dut.biasReg_0);  $fwrite(fdb, "%08x\n", dut.biasReg_1);
      $fwrite(fdb, "%08x\n", dut.biasReg_2);  $fwrite(fdb, "%08x\n", dut.biasReg_3);
      $fwrite(fdb, "%08x\n", dut.biasReg_4);  $fwrite(fdb, "%08x\n", dut.biasReg_5);
      $fwrite(fdb, "%08x\n", dut.biasReg_6);  $fwrite(fdb, "%08x\n", dut.biasReg_7);
      $fwrite(fdb, "%08x\n", dut.biasReg_8);  $fwrite(fdb, "%08x\n", dut.biasReg_9);
      $fwrite(fdb, "%08x\n", dut.biasReg_10); $fwrite(fdb, "%08x\n", dut.biasReg_11);
      $fwrite(fdb, "%08x\n", dut.biasReg_12); $fwrite(fdb, "%08x\n", dut.biasReg_13);
      $fwrite(fdb, "%08x\n", dut.biasReg_14); $fwrite(fdb, "%08x\n", dut.biasReg_15);
      $fwrite(fdb, "%08x\n", dut.biasReg_16); $fwrite(fdb, "%08x\n", dut.biasReg_17);
      $fwrite(fdb, "%08x\n", dut.biasReg_18); $fwrite(fdb, "%08x\n", dut.biasReg_19);
      $fwrite(fdb, "%08x\n", dut.biasReg_20); $fwrite(fdb, "%08x\n", dut.biasReg_21);
      $fwrite(fdb, "%08x\n", dut.biasReg_22); $fwrite(fdb, "%08x\n", dut.biasReg_23);
      $fwrite(fdb, "%08x\n", dut.biasReg_24); $fwrite(fdb, "%08x\n", dut.biasReg_25);
      $fwrite(fdb, "%08x\n", dut.biasReg_26); $fwrite(fdb, "%08x\n", dut.biasReg_27);
      $fwrite(fdb, "%08x\n", dut.biasReg_28); $fwrite(fdb, "%08x\n", dut.biasReg_29);
      $fwrite(fdb, "%08x\n", dut.biasReg_30); $fwrite(fdb, "%08x\n", dut.biasReg_31);
      $fwrite(fdb, "%08x\n", dut.biasReg_32); $fwrite(fdb, "%08x\n", dut.biasReg_33);
      $fwrite(fdb, "%08x\n", dut.biasReg_34); $fwrite(fdb, "%08x\n", dut.biasReg_35);
      $fwrite(fdb, "%08x\n", dut.biasReg_36); $fwrite(fdb, "%08x\n", dut.biasReg_37);
      $fwrite(fdb, "%08x\n", dut.biasReg_38); $fwrite(fdb, "%08x\n", dut.biasReg_39);
      $fwrite(fdb, "%08x\n", dut.biasReg_40); $fwrite(fdb, "%08x\n", dut.biasReg_41);
      $fwrite(fdb, "%08x\n", dut.biasReg_42); $fwrite(fdb, "%08x\n", dut.biasReg_43);
      $fwrite(fdb, "%08x\n", dut.biasReg_44); $fwrite(fdb, "%08x\n", dut.biasReg_45);
      $fwrite(fdb, "%08x\n", dut.biasReg_46); $fwrite(fdb, "%08x\n", dut.biasReg_47);
      $fwrite(fdb, "%08x\n", dut.biasReg_48); $fwrite(fdb, "%08x\n", dut.biasReg_49);
      $fwrite(fdb, "%08x\n", dut.biasReg_50); $fwrite(fdb, "%08x\n", dut.biasReg_51);
      $fwrite(fdb, "%08x\n", dut.biasReg_52); $fwrite(fdb, "%08x\n", dut.biasReg_53);
      $fwrite(fdb, "%08x\n", dut.biasReg_54); $fwrite(fdb, "%08x\n", dut.biasReg_55);
      $fwrite(fdb, "%08x\n", dut.biasReg_56); $fwrite(fdb, "%08x\n", dut.biasReg_57);
      $fwrite(fdb, "%08x\n", dut.biasReg_58); $fwrite(fdb, "%08x\n", dut.biasReg_59);
      $fwrite(fdb, "%08x\n", dut.biasReg_60); $fwrite(fdb, "%08x\n", dut.biasReg_61);
      $fwrite(fdb, "%08x\n", dut.biasReg_62); $fwrite(fdb, "%08x\n", dut.biasReg_63);
      $fclose(fdb);
      $display("BIAS_DUMPED %0s (64 words)", bdumpf);
    end

    // 通过条件：帧正常收工 + 列流喂完 + WR 字节/突发数对 + **从 DDR 读回的权重字节数 == `+WEXP=`**
    //   （`+WBASE=0` ⇒ `+WEXP=0` ⇒ 与旧口径"宽层一字节都不读 DDR"逐字同形）
    //   ★★ T-S2b：`tiled_w_en` ⇒ 判据改成**跑完 + 无 err + busy 落 0**（数值/流量由闸门拿整层黄金
    //     逐字节对账；tile 的 RD/WR 都是"每窗口行/每 tile 行一笔"，不是"一笔搬运"的简单口径）。
    //   ★★ T-S3d：再补一条 —— `+WBASE` 打开时 `rd_peak` 必须 == `+WEXP=`（权重段的 RD 长度）。
    //     为什么必需：本缺陷的症状就是"只读了一块 128 B 就挂住"——"收工 + busy=0"能抓它（挂住 ⇒ 超时），
    //     但**"读了几字节"是独立的账**：装载少读/多读也要当场红。既有 tiled 档不传 `+WBASE`/`+WEXP=`
    //     （都取 0）⇒ 本项恒真 ⇒ 逐字节同形。
    if (tiled_w_en && done_seen && !err_seen && (busy == 0) && ((wbase_dma == 32'd0) || (rd_peak == wexp_bytes)) && gb_ok) begin
      $display("TILED_W RD_BYTES=%0d WR_BYTES=%0d AR=%0d AW=%0d B=%0d WBASE=%0d WEXP=%0d", rd_peak, wr_bytes, ar_bursts, aw_bursts, b_ok, wbase_dma, wexp_bytes);
      $display("RESULT: PASS");
      $finish;
    end else if (!tiled_w_en && done_seen && !err_seen && (nfed == NCOL) && (wr_bytes == COUT*H*W) &&
        (aw_bursts == ((COUT*H*W)/128)) && (b_ok == ((COUT*H*W)/128)) && (rd_peak == wexp_bytes)) begin
      $display("RESULT: PASS");
      $finish;
    end else begin
      $display("RESULT: FAIL tiled_w=%0d done=%0d err=%0d busy=%0d nfed=%0d/%0d wr=%0d(期望 %0d) aw=%0d b=%0d rd_peak=%0d(期望 %0d)",
               tiled_w_en, done_seen, err_seen, busy, nfed, NCOL, wr_bytes, COUT*H*W, aw_bursts, b_ok, rd_peak, wexp_bytes);
      $fatal(1, "UnitExecWideTb failed");
    end
  end

  integer wd;
  initial begin
    for (wd = 0; wd < WD_MAX; wd = wd + 1) @(posedge clk);
    $display("RESULT: FAIL timeout(global watchdog %0d cycles)", WD_MAX);
    $fatal(1, "UnitExecWideTb global timeout");
  end
endmodule
