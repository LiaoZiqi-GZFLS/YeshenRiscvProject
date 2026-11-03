//=============================================================================
// UnitExecTb.v —— C3.8 `UnitExec`（gen/UnitExec.v）的整单元数值装置（纯 Verilog + AxiMemModel）。
//
// 干什么：把"一个不融合的 3x3 dense conv 单元"从 DDR 跑一遍 ——
//   预载激活进 src 区 -> 带外预载整层权重 -> 给一个描述符 -> `+CTRL=1` 起跑 -> 等 done/err -> 转储内存。
//   闸门（tools/run_unitexec_ab.sh）拿 +DUMPFILE 的镜像与 Python 黄金（tools/conv_unit_ref.py）逐字节对账。
//
// 契约（plusarg；装置不写死任何地址/几何）：
//   +WGTFILE=<file>   整层权重：**每行一个十六进制字节**，NENTRY = C_OUT*(C_IN/GROUP)*9 行
//                     （dense/GROUP=1 时 576），展平顺序 = GroupMask.weightAddr = [co][ci_local][ky][kx]。
//                     经 ★ C3.16 的**权重信箱**（`wgt_sel/wgt_addr/wgt_data/wgt_we`）一拍一字节预载
//                     （切片由 `wgt_sel` 选、地址线性 0..NENTRY-1）—— 这就是"带外预载权重"在装置侧的落实
//                     （描述符里**没有**权重指针，见 rtl/UnitExec.scala 文件头）。plusarg 口径与旧的四套
//                     装载口**完全一致**（`+WGTFILE=`→切片0 / `+WGTFILE_T=`→切片1 / `+WGTFILE2/3=`→切片2/3）。
//   +D0=..+D7=<dec>   描述符的 8 个 32-bit 小端字（十进制；与 desc_table.pack 的位打包逐字段一致）。
//                     装置从中解出 IMG_W/IMG_H/C_IN/C_OUT/GROUP/IN_BYTES/QUANT_SHIFT 做 time-0 对账。
//                     ★ C3.9a：`FLAGS.bit0`（= desc0[8]）也在此解出（`HEAD_DESC`）—— 0 ⇒ 头档
//                     （**无 DDR 写**：`wr_bytes`/`AW` 应为 0）。判据口径**由描述符自己**给出，不是 TB 的约定。
//   +MIDREAD +MIDFILE=<file>  可选：跑完（DUT 回 IDLE）后把**中间 FusionBuf** 的 3 行环窗读回、逐字节写
//                     MIDFILE（展平 [rd_row][rd_col][ci]，同步读 1 拍）。**仅观察**，不改任何判据。
//   +CTRL=<dec>       起跑控制（非 0 = 脉冲一次 `go`）。默认 1。
//   +EXPECT_ERR       可选：本次必须报 err（负对照用；给了它，"报 err 且零搬运"算 PASS）。
//   +MEMFILE= / +DUMPFILE=  转给 AxiMemModel（模型自己取；预载/导出/统计都在模型里）。
//
// ★ 连跑（第二次 `go`）—— C3.10 前置项的装置侧落实（`+GO2` + `+D0B=..+D7B=`）：
//   `+GO2` 时，装置在**第一次跑完且 `busy` 落 0 之后**改挂第二套描述符（`+D0B..+D7B`），再脉冲一次
//   `go`（**同一个 DUT 实例**，这就是 LayerSched 连跑的形状）。判据（全部一起成立才算 PASS）：
//     · `GO_COUNT=2`、`RUN1_DONE=1`、`RUN2_DONE=1`、`RUN2_ERR=0`、`RUN2_BUSY_AFTER=0`（第二次**跑完**且
//       `busy` 回到 0 —— 这正是"第二次 `go` 挂死"会打红的那几条）；
//     · 字节计数：`rd_peak == IN_BYTES`（每笔搬运的口径不变）而 `AR/AW/B_OK` 与内存模型的
//       `MEM rd/wr/bursts` = **两次之和**（两笔搬运各一次 ⇒ 独立计数两处都必须翻倍）；
//     · 数值：闸门对**两段 dst 区**分别与各自的黄金逐字节对账（`MISMATCH=0`）；源码区与邻居仍未被改。
//   ⚠️ 第二套描述符必须与第一套**几何一致**（IMG_W/C_IN/C_OUT/GROUP/SHIFT 逐条相等；装置在 time 0 里
//      同样对账），只允许地址（`D4/D5`）/张量大小不同。
//
// ★ time-0 几何对账（"宽度钉死"教训：网表按展开期常量数行/寻址，喂进来的几何不符会**静默**错位）：
//   装置把描述符里的 IMG_W / C_IN / GROUP 与**网表自报**的 imgW / imgC / grp 当场对账，不符立即
//   `$fatal`（并指名"该网表是按什么生成的"），绝不让"宽度/档位不符"退化成事后的大范围 MISMATCH。
//   · `IN_BYTES % 128 == 0 且 != 0`：S2 的尺寸约束（本任务先走整块；32 B 通用粒度是 C3.3 的能力）。
//   · QUANT_SHIFT **在装置侧不对账**（只打印 `SHIFT_DESC` 与 `RTL_SHIFT` 两个事实）：requant 的右移
//     在本档是 `Conv3x3Slice` 的展开期常量，而**描述符的 QUANT_SHIFT 由 RTL 自己响亮拒绝**
//     （`rtl/UnitExec.scala` 在 `go` 那一刻对账 ⇒ 不符 ⇒ `err` + 零搬运）。装置侧留着"文字"不管，
//     是为了让两条负对照各管各的：表侧 `+D7=5` ⇒ 由 **RTL 的 err** 抓（零搬运）；网表侧
//     `>>> 3'd6 -> 3'd5`（表对、网表被改）⇒ 自报常量仍是 6 ⇒ 只能由**数值**（MISMATCH>0）抓。
//     正向侧"两者都 == 6"由闸门交叉对账（见 run_unitexec_ab.sh）。
//
// ★ 时序口径与 rtl_test/DdrCopyTb.v 同：驱动在 negedge 摆、握手在 posedge 采、$finish 让模型转储。
//
// ★★ A-1b（本片）：`chainLen` 从"`FLAGS[4:2]` 译码"改成 **`UnitExec` 的独立入参**（`.chain_len`）。
//   装置新增 **`+CHAINLEN=<n>`**（默认 1）：链长由**装置**给出（这正是 `LayerSched` 扫链后做的事）。
//   于是本装置喂给 DUT 的 `desc0..desc7` 是**链描述符**：
//     · `SRC_ADDR`/几何/`QUANT_SHIFT`/`FLAGS` = **链首条目**的；`DST_ADDR` = **链尾条目**的；
//     · `FLAGS[7:2]` 必须为 0（保留位；非 0 ⇒ RTL 响亮 err）。
//   `+D0` 的 `FLAGS.bit0`（`desc0[8]`）仍是**头判定**（`HEAD_DESC`）：0 ⇒ 切片0 的输出**留在片上**。
//   `+D0` 的 `FLAGS.bit1`（`desc0[9]`）在 A-1b 里**不再**被装置当判据（per-operator 编码里它属于
//   "tail 条目"，而链描述符取的是链首 ⇒ 恒 0）；装置的 `TAIL_DESC` 自报改成
//   **"这条运行的末片落 DDR（= `chainLen ≥ 2`）"** —— 与 `UnitExec.tail_mode`（同一个事实）对齐。
//   判据分支由 (HEAD_DESC, CHAINLEN) 统一算 `WR_MULT = (!head) + (chainLen≥2)`（= 写几张输出图）：
//     · `chainLen=1, bit0=0` 头档（无 WR）：`WR_MULT=0`；· `chainLen=1, bit0=1` plain/S2：`=1`；
//     · `chainLen≥2, bit0=0` **链**（末片落 DDR）：`=1`；· `chainLen≥2, bit0=1` **退化档**（切片0 的
//       中间**也**落 DDR，只作闸门负对照）：`=2`。判据：`rd==IN_BYTES`、`wr==WR_MULT*输出字节`、
//       `AR==IN_BYTES/128`、`AW==B_OK==WR_MULT*输出字节/128`。
//   观察口 `chain_len_rep` = 网表把收到的 `chain_len` 回读出来（闸门据此确认端口真的接上了）。
//=============================================================================
`timescale 1ns/1ps

module UnitExecTb;

  localparam integer MEMSZ   = 2621440;   // 2.5 MiB（够放 src/dst 两区 + 前后邻居；与闸门一致）
  localparam integer TIMEOUT = 2000000;   // 等 done/err 的最长拍数
  localparam integer WD_MAX  = 6000000;   // 全局看门狗
  localparam integer MAXWGT  = 1024;      // 权重条目上限（dense 8x8 = 576）

  reg clk = 1'b0;
  reg rst = 1'b1;
  always #5 clk = ~clk;

  // ---- DUT 控制 ----
  reg         go;
  reg  [31:0] desc0, desc1, desc2, desc3, desc4, desc5, desc6, desc7;
  reg  [31:0] desc0b, desc1b, desc2b, desc3b, desc4b, desc5b, desc6b, desc7b;  // 第二次 go 的描述符
  reg  [15:0] wgt_base;
  // ★ C3.16：权重装载 = **一套"权重信箱"**（`wgt_sel` 选切片 / `wgt_addr` 条目下标 /
  //   `wgt_data` int8 载荷 / `wgt_we` 单拍写使能）—— 取代旧的四套口（`we`/`we_t`/`we2`/`we3`）。
  //   plusarg 口径**不变**（`+WGTFILE=` 切片0 / `+WGTFILE_T=` 切片1 / `+WGTFILE2=` 切片2 /
  //   `+WGTFILE3=` 切片3），因此各闸门脚本**一行都不用改**。
  reg  [2:0]  wgt_sel;
  reg  [9:0]  wgt_addr;
  reg  [7:0]  wgt_data;
  reg         wgt_we;
  // ★ C4a.5b：宽层多趟通路的激活列流（本闸门只跑窄层 ⇒ 全程钉 0/0）；加上新增的自报口。
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
  reg  [15:0] chain_in;           // ★ A-1b：链长**入参**（driven by +CHAINLEN=）
`ifdef UE_CGEOM
  // ★★ A'-2（2026-10-15）：**逐片几何入参的默认驱动** = 链描述符译码（全部槽同值 ⇒ "同型链"）。
  //   ★ 本装置一份源码、**两族网表公用**：`gen/UnitExec.v` / `_w32` / `_w640`（TILING=false）
  //     **没有**这些端口，`gen/UnitExec_tiled.v`（TILING=true，`run_tiling2d_rtl_ab.sh` 用的那份）才有
  //     ⇒ 只有编译 **tiled** 网表的编译行给 `-DUE_CGEOM`；不给 ⇒ 本块整体裁掉（既有作业逐字节同形）
  //     —— 见下方实例化里的连接与 `always @(*)` 驱动，以及四个闸门的编译行。
  //   ★ 组合驱动（真源 = `desc0..desc7`）⇒ 第二次 `go` 的 `desc* := desc*b` 自动跟随。
  reg  [15:0] cge_cin  [0:7];
  reg  [15:0] cge_cout [0:7];
  reg  [7:0]  cge_grp  [0:7];
  reg  [7:0]  cge_qsh  [0:7];
  reg  [7:0]  cge_lid  [0:7];
  reg         cge_dw   [0:7];
  reg         cge_x1   [0:7];
  integer     cge_i;
`endif
  wire [15:0] chain_rep, lmax;    // ★ A-1b：网表把链长回读出来 / 生成期上限 L_MAX
  wire [31:0] rd_bytes, wr_bytes;

  // ---- C3.9a 观察口：中间 FusionBuf 的消费口（仅观察；本网表 C=8 / WIDTH=64 ⇒ 列地址 6 位）----
  reg  [1:0]  mid_rd_row;
  reg  [5:0]  mid_rd_col;
  wire [7:0]  mid_rd_data_0, mid_rd_data_1, mid_rd_data_2, mid_rd_data_3;
  wire [7:0]  mid_rd_data_4, mid_rd_data_5, mid_rd_data_6, mid_rd_data_7;
  wire        head_mode;         // 本次运行的 OUT_TO_DDR 判定（1=头 / 0=落 DDR）
  wire [15:0] mid_rows;          // 中间缓冲已推进行指针次数（= 写进中间缓冲的输出行数）
  wire        tail_mode;         // ★ C3.9b：本次运行的 IN_FROM_PREV 判定（1=尾在跑）
  wire [15:0] tail_rows;         // ★ C3.9b：尾已从中间缓冲读完的中间行数（含注入的 pad 行）

  // ---- AXI 连线（DUT 主口 <-> AxiMemModel 从口；一根线两端）----
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

  UnitExec dut (
    .go(go),
    .desc_0(desc0), .desc_1(desc1), .desc_2(desc2), .desc_3(desc3),
    .desc_4(desc4), .desc_5(desc5), .desc_6(desc6), .desc_7(desc7),
    .wgt_base(wgt_base),
    // ★ C4b-B1：DMA 主路径**关**（基址 0）= 与 C3/C4a 逐字节同形；装载字节数只观察
    .wgt_dma_addr(28'd0), .wgt_bytes(wgt_bytes),
    .wgt_sel(wgt_sel), .wgt_addr(wgt_addr), .wgt_data(wgt_data), .wgt_we(wgt_we),
    // ★ C4a.5b：宽层激活列流（钉 0）+ 新增自报口
    .wide_x_0(wide_x[0]), .wide_x_1(wide_x[1]), .wide_x_2(wide_x[2]), .wide_x_3(wide_x[3]),
    .wide_x_4(wide_x[4]), .wide_x_5(wide_x[5]), .wide_x_6(wide_x[6]), .wide_x_7(wide_x[7]),
    .wide_x_valid(wide_x_valid), .wide_x_ready(wide_x_ready),
    .wide_on(wide_on), .wide_passes(wide_passes),
    .rtl_m(rtl_m), .rtl_zpad(rtl_zpad), .rtl_zy(rtl_zy), .rtl_layer(rtl_layer),
    .busy(busy), .done(done), .err(err),
    .imgC(imgC), .imgW(imgW), .grp(grp), .shift(shift), .maxPix(maxPix),
    .chain_len(chain_in), .chain_len_rep(chain_rep), .lmax(lmax),
`ifdef UE_CGEOM
    // ★★ A'-2：逐片几何（每片自己的 = 描述符译码 ⇒ 同型链；见 `chain_in` 旁的 `UE_CGEOM` 一节）
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
  // ★★ A'-2：逐片几何入参的组合驱动（真源 = 描述符 8 字 `desc0..desc7`；槽 0 == 描述符 ⇒
  //   `UnitExec` 的 "槽 0 == 链描述符" 断言在既有作业上天然成立；异型链（chainLen≥2 且逐片不同）
  //   在本装置上会被引擎互锁响亮拦下 —— 这是"引擎未落地"的诚实形状）。
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

  // ---- 权重向量 + 描述符字段 ----
  reg [8*256-1:0] wgtfile;
  reg [7:0] wm [0:MAXWGT-1];
  // ★ C3.9b：尾切片（convT）的权重（`+WGTFILE_T=` 可选；不给 ⇒ 尾不装载、WeightStore 保持初值 0）
  reg [8*256-1:0] wgtfile_t;
  reg [7:0] wm_t [0:MAXWGT-1];
  reg        has_wgt_t;
  // ★ A-1a：切片 2/3 的权重（`+WGTFILE2=` / `+WGTFILE3=` 可选；不给 ⇒ 该切片 WeightStore 保持初值 0）
  reg [8*256-1:0] wgtfile2, wgtfile3;
  reg [7:0] wm2 [0:MAXWGT-1];
  reg [7:0] wm3 [0:MAXWGT-1];
  reg        has_wgt2, has_wgt3;
  integer IMG_W, IMG_H, C_IN, C_OUT, GROUP, IN_BYTES, Q_SHIFT, NENTRY;
  integer CHAINLEN;                   // ★ A-1b：`+CHAINLEN=`（链长入参；默认 1）
  integer WR_MULT, got_cl;            // ★ A-1b：WR_MULT = 本运行写几张输出图 = (!head)+(chainLen≥2)

  integer i, timeout_cnt, ar_bursts, aw_bursts, b_ok;
  integer ctrl, got_ctrl;
  reg     done_seen, err_seen, expect_err;
  reg [31:0] rd_peak;                 // DdrMaster 的 rd_bytes 在每个 CHK 会被清零 ⇒ 取峰值
  // ★★ T-S2R：`+TILED` 模式 —— 本网表（`gen/UnitExec_tiled.v`）跑 **2-D tile 循环**：
  //   描述符的 `IMG_W/IMG_H` 是**整层**几何（可与网表 `WIDTH=34` 不等），按 `W_TILE=(WIDTH-2)/s` 切 tile。
  //   ⇒ time-0 的 `IMG_W==imgW` / `IMG_W·IMG_H ≤ maxPix` 两条**不再适用**（跳过），判据改成
  //   "跑完 + 无 err + busy 落 0"（数值由闸门用 Python 整层黄金逐字节对账）。
  reg     tiled_en, got_tiled;
  integer tiled_i;

  // ---- 连跑（+GO2）专用 ----
  integer IMG_W_B, IMG_H_B, C_IN_B, C_OUT_B, GROUP_B, IN_BYTES_B, Q_SHIFT_B;
  integer go_count, timeout2_cnt, busy2_cnt;
  reg     go2_en, done2_seen, err2_seen, busy_at_go2;

  // ---- C3.9a 头分支（观察）：+MIDREAD 时把中间缓冲读回写 +MIDFILE=（仅观察，不改任何判据）----
  //   head_desc 由**描述符自己的** FLAGS.bit0（= desc0[8]）解出：0 ⇒ 头（无 DDR 写）。
  reg [8*256-1:0] midfile;
  reg     midread_en, head_desc, tail_desc;
  integer midf, mr, mc;

  // 运行期结构观察（不是判据主体；给闸门交叉对账用）
  always @(posedge clk) begin
    if (!rst) begin
      if (axi_ar_valid && axi_ar_ready) ar_bursts = ar_bursts + 1;
      if (axi_aw_valid && axi_aw_ready) aw_bursts = aw_bursts + 1;
      if (axi_b_valid  && axi_b_ready)  b_ok      = b_ok + 1;
      // ★ RD 相位与 WR 相位用的是**同一个** DdrMaster，而它在每次 CHK 会把 rd_r/wr_r 清零
      //   ⇒ 收尾时读到的 rd_bytes 只是**最后一次搬运**的计数（WR ⇒ 0）。所以 RD 侧用**峰值**观察。
      if (rd_bytes > rd_peak) rd_peak = rd_bytes;
    end
  end

  initial begin
    // ---- 默认 / 取参数 ----
    go = 1'b0; wgt_base = 16'd0;
    wgt_sel = 3'd0; wgt_addr = 10'd0; wgt_data = 8'd0; wgt_we = 1'b0;
    wide_x_valid = 1'b0;
    for (i = 0; i < 8; i = i + 1) wide_x[i] = 8'h00;
    desc0 = 32'd0; desc1 = 32'd0; desc2 = 32'd0; desc3 = 32'd0;
    desc4 = 32'd0; desc5 = 32'd0; desc6 = 32'd0; desc7 = 32'd0;
    timeout_cnt = 0; ar_bursts = 0; aw_bursts = 0; b_ok = 0;
    done_seen = 1'b0; err_seen = 1'b0; expect_err = 1'b0;
    ctrl = 1; got_ctrl = 0; rd_peak = 32'd0;
    desc0b = 32'd0; desc1b = 32'd0; desc2b = 32'd0; desc3b = 32'd0;
    desc4b = 32'd0; desc5b = 32'd0; desc6b = 32'd0; desc7b = 32'd0;
    go_count = 0; go2_en = 1'b0; done2_seen = 1'b0; err2_seen = 1'b0;
    timeout2_cnt = 0; busy2_cnt = 0; busy_at_go2 = 1'b0;
    tiled_en = 1'b0; got_tiled = $value$plusargs("TILED=%d", tiled_i);
    if (got_tiled && tiled_i != 0) tiled_en = 1'b1;
    mid_rd_row = 2'd0; mid_rd_col = 6'd0;
    midread_en = 1'b0; head_desc = 1'b0; tail_desc = 1'b0; midf = 0;
    chain_in = 16'd1; CHAINLEN = 1; WR_MULT = 1; got_cl = 0;
    has_wgt_t = 1'b0;
    has_wgt2 = 1'b0; has_wgt3 = 1'b0;
    for (i = 0; i < MAXWGT; i = i + 1) wm[i] = 8'h00;
    for (i = 0; i < MAXWGT; i = i + 1) wm_t[i] = 8'h00;
    for (i = 0; i < MAXWGT; i = i + 1) wm2[i] = 8'h00;
    for (i = 0; i < MAXWGT; i = i + 1) wm3[i] = 8'h00;

    if (!$value$plusargs("WGTFILE=%s", wgtfile)) begin
      $display("TB-ERROR: 缺 +WGTFILE="); $fatal(1, "missing WGTFILE");
    end
    if (!$value$plusargs("D0=%d", desc0)) begin $display("TB-ERROR: 缺 +D0="); $fatal(1, "missing D0"); end
    if (!$value$plusargs("D1=%d", desc1)) begin $display("TB-ERROR: 缺 +D1="); $fatal(1, "missing D1"); end
    if (!$value$plusargs("D2=%d", desc2)) begin $display("TB-ERROR: 缺 +D2="); $fatal(1, "missing D2"); end
    if (!$value$plusargs("D3=%d", desc3)) begin $display("TB-ERROR: 缺 +D3="); $fatal(1, "missing D3"); end
    if (!$value$plusargs("D4=%d", desc4)) begin $display("TB-ERROR: 缺 +D4="); $fatal(1, "missing D4"); end
    if (!$value$plusargs("D5=%d", desc5)) begin $display("TB-ERROR: 缺 +D5="); $fatal(1, "missing D5"); end
    if (!$value$plusargs("D6=%d", desc6)) begin $display("TB-ERROR: 缺 +D6="); $fatal(1, "missing D6"); end
    if (!$value$plusargs("D7=%d", desc7)) begin $display("TB-ERROR: 缺 +D7="); $fatal(1, "missing D7"); end
    if ($test$plusargs("EXPECT_ERR")) expect_err = 1'b1;
    // ★ A-1b：链长入参（`+CHAINLEN=<n>`；默认 1）。这就是 `LayerSched` 扫链后递给 `UnitExec` 的那个量。
    got_cl = $value$plusargs("CHAINLEN=%d", CHAINLEN);
    if (got_cl == 0) CHAINLEN = 1;
    chain_in = CHAINLEN[15:0];

    // ---- 从描述符解字段（与 desc_table 的位打包逐字段一致）----
    IMG_W    = desc1[15:0];
    IMG_H    = desc1[31:16];
    C_IN     = desc2[15:0];
    C_OUT    = desc2[31:16];
    GROUP    = desc3[7:0];
    IN_BYTES = desc6;
    Q_SHIFT  = desc7[7:0];

    $display("TB UNITEXEC: IMG_W=%0d IMG_H=%0d C_IN=%0d C_OUT=%0d GROUP=%0d IN_BYTES=%0d QUANT_SHIFT=%0d",
             IMG_W, IMG_H, C_IN, C_OUT, GROUP, IN_BYTES, Q_SHIFT);
    $display("TB UNITEXEC: SRC=%0d DST=%0d TYPE=0x%02x FLAGS=0x%02x",
             desc4, desc5, desc0[7:0], desc0[15:8]);

    // ---- ★ A-1b：头判定（`FLAGS.bit0 == OUT_TO_DDR`；0 ⇒ 切片0 的输出**留在片上**）----
    //   `tail_desc` 的**语义**在 A-1b 改了（见文件头）：= "这条运行的**末片落 DDR**（= `chainLen ≥ 2`）"，
    //   与 `UnitExec.tail_mode`（同一个事实，另一个独立出口）对齐；不再是 `desc0[9]`。
    //   ⇒ `WR_MULT` = 本运行写几张输出图 = (!head) + (chainLen≥2)：0/1/1/2 四档与四个判据分支一一对应。
    head_desc = (desc0[8] == 1'b0);
    tail_desc = (CHAINLEN >= 2);
    WR_MULT   = ((head_desc == 1'b0) ? 1 : 0) + ((CHAINLEN >= 2) ? 1 : 0);
    midread_en = 1'b0;
    if ($test$plusargs("MIDREAD")) begin
      midread_en = 1'b1;
      if (!$value$plusargs("MIDFILE=%s", midfile)) begin
        $display("TB-ERROR: +MIDREAD 但缺 +MIDFILE="); $fatal(1, "missing MIDFILE");
      end
    end
    // ★ 保持 C3.9a 闸门 grep 的**逐字**行形（`HEAD_DESC=.. MIDREAD=..`）；尾判定另起一行（C3.9b 的闸门才 grep 它）。
    $display("TB UNITEXEC: HEAD_DESC=%0d MIDREAD=%0d", head_desc, midread_en);
    $display("TB UNITEXEC: TAIL_DESC=%0d", tail_desc);
    // ★ A-1a：链长（网表自报的 chain_len + 生成期上限 lmax）；观察/对账（在收尾处打印，避开 time-0 组合传播竞态）。

    // ---- 尺寸/几何 time-0 对账（不符立刻红，绝不放它退化成事后的大范围 MISMATCH）----
    if (IN_BYTES <= 0 || (IN_BYTES % 128) != 0) begin
      $display("TB-ERROR: IN_BYTES=%0d 不是 128 的正整数倍（S2 的尺寸约束；见 rtl/UnitExec.scala 文件头）", IN_BYTES);
      $fatal(1, "IN_BYTES not multiple of 128");
    end
    if (!tiled_en) begin
      if (IMG_W != imgW) begin
        $display("TB-ERROR: 描述符 IMG_W=%0d 与网表自报 imgW=%0d 不符 ⇒ 该网表是按 WIDTH=%0d 生成的；请用 IMG_W=%0d 的几何重生成/改表（宽度钉死）",
                 IMG_W, imgW, imgW, IMG_W);
        $fatal(1, "IMG_W vs imgW mismatch");
      end
    end
    if (C_IN != imgC) begin
      $display("TB-ERROR: 描述符 C_IN=%0d 与网表自报 imgC=%0d 不符 ⇒ 该网表固定 8x8 阵列", C_IN, imgC);
      $fatal(1, "C_IN vs imgC mismatch");
    end
    if (GROUP != grp) begin
      $display("TB-ERROR: 描述符 GROUP=%0d 与网表自报 grp=%0d 不符（本网表是 dense 档）", GROUP, grp);
      $fatal(1, "GROUP vs grp mismatch");
    end
    if (C_IN != 8 || C_OUT != 8) begin
      $display("TB-ERROR: 本任务的 UnitExec 固定 C_IN=C_OUT=8，得到 %0d/%0d", C_IN, C_OUT);
      $fatal(1, "C dim mismatch");
    end
    // ★★ T-S2R：tiled 模式下网表是 `W_TILE=(WIDTH-2)/s` 宽的 tile 网表 ⇒ 只对账"tile 能装进分配"。
    if (tiled_en) begin
      $display("TB UNITEXEC: TILED netl_RTL_IMGW=%0d 描述符 IMG_W=%0d IMG_H=%0d（tile 循环；time-0 不做 IMG_W==imgW 对账）",
               imgW, IMG_W, IMG_H);
    end

    NENTRY = C_OUT * (C_IN / GROUP) * 9;
    if (NENTRY < 1 || NENTRY > MAXWGT) begin
      $display("TB-ERROR: NENTRY=%0d 越界 [1,%0d]", NENTRY, MAXWGT); $fatal(1, "bad NENTRY");
    end
    // 输出存储的字数上限：**由网表自报**（`maxPix` = 本网表展开时的 WIDTH*IMG_H_MAX，见
    // rtl/UnitExec.scala 文件头"输出存储的尺寸与初值"）。超了写指针会回绕 ⇒ 静默改写前面的像素，
    // 所以这里用**运行期 IMG_H*IMG_W 与自报上限**对账（而不是写死一个常量）。
    if (!tiled_en) begin
      if (IMG_W * IMG_H > maxPix) begin
        $display("TB-ERROR: IMG_W*IMG_H=%0d > 网表自报输出存储上限 maxPix=%0d（该网表按 IMG_H_MAX=%0d 生成）",
                 IMG_W * IMG_H, maxPix, maxPix / IMG_W);
        $fatal(1, "pixels exceed maxPix");
      end
    end
    $readmemh(wgtfile, wm, 0, NENTRY - 1);
    // ★ C3.9b：尾切片的权重（可选）。给了 `+WGTFILE_T=` 才装载；不给 ⇒ 尾的 WeightStore 保持 0
    //   （S2/头档里尾不跑，装不装都不影响判据 ⇒ 既有闸门无需改动）。
    if ($value$plusargs("WGTFILE_T=%s", wgtfile_t)) begin
      has_wgt_t = 1'b1;
      $readmemh(wgtfile_t, wm_t, 0, NENTRY - 1);
    end
    // ★ A-1a：切片 2/3 的权重（可选）
    if ($value$plusargs("WGTFILE2=%s", wgtfile2)) begin
      has_wgt2 = 1'b1;
      $readmemh(wgtfile2, wm2, 0, NENTRY - 1);
    end
    if ($value$plusargs("WGTFILE3=%s", wgtfile3)) begin
      has_wgt3 = 1'b1;
      $readmemh(wgtfile3, wm3, 0, NENTRY - 1);
    end
    $display("TB UNITEXEC: NENTRY=%0d (权重 %0d 字节) HAS_WGT_T=%0d HAS_WGT2=%0d HAS_WGT3=%0d", NENTRY, NENTRY, has_wgt_t, has_wgt2, has_wgt3);
    $display("TB UNITEXEC: RTL_SHIFT=%0d RTL_GRP=%0d RTL_IMGW=%0d RTL_IMGC=%0d RTL_MAXPIX=%0d",
             shift, grp, imgW, imgC, maxPix);

    // ---- 连跑（+GO2）：第二套描述符的取参与 time-0 几何对账（几何必须与第一套逐条一致）----
    go2_en = 1'b0;
    if ($test$plusargs("GO2")) begin
      if (!$value$plusargs("D0B=%d", desc0b)) begin $display("TB-ERROR: +GO2 但缺 +D0B="); $fatal(1, "missing D0B"); end
      if (!$value$plusargs("D1B=%d", desc1b)) begin $display("TB-ERROR: +GO2 但缺 +D1B="); $fatal(1, "missing D1B"); end
      if (!$value$plusargs("D2B=%d", desc2b)) begin $display("TB-ERROR: +GO2 但缺 +D2B="); $fatal(1, "missing D2B"); end
      if (!$value$plusargs("D3B=%d", desc3b)) begin $display("TB-ERROR: +GO2 但缺 +D3B="); $fatal(1, "missing D3B"); end
      if (!$value$plusargs("D4B=%d", desc4b)) begin $display("TB-ERROR: +GO2 但缺 +D4B="); $fatal(1, "missing D4B"); end
      if (!$value$plusargs("D5B=%d", desc5b)) begin $display("TB-ERROR: +GO2 但缺 +D5B="); $fatal(1, "missing D5B"); end
      if (!$value$plusargs("D6B=%d", desc6b)) begin $display("TB-ERROR: +GO2 但缺 +D6B="); $fatal(1, "missing D6B"); end
      if (!$value$plusargs("D7B=%d", desc7b)) begin $display("TB-ERROR: +GO2 但缺 +D7B="); $fatal(1, "missing D7B"); end
      IMG_W_B    = desc1b[15:0];
      IMG_H_B    = desc1b[31:16];
      C_IN_B     = desc2b[15:0];
      C_OUT_B    = desc2b[31:16];
      GROUP_B    = desc3b[7:0];
      IN_BYTES_B = desc6b;
      Q_SHIFT_B  = desc7b[7:0];
      $display("TB UNITEXEC2: IMG_W=%0d IMG_H=%0d C_IN=%0d C_OUT=%0d GROUP=%0d IN_BYTES=%0d QUANT_SHIFT=%0d",
               IMG_W_B, IMG_H_B, C_IN_B, C_OUT_B, GROUP_B, IN_BYTES_B, Q_SHIFT_B);
      $display("TB UNITEXEC2: SRC=%0d DST=%0d", desc4b, desc5b);
      if (IMG_W_B != IMG_W || C_IN_B != C_IN || C_OUT_B != C_OUT || GROUP_B != GROUP ||
          IN_BYTES_B != IN_BYTES || Q_SHIFT_B != Q_SHIFT) begin
        $display("TB-ERROR: 第二套描述符的几何/长度与第一套不符（连跑只允许换地址/张量大小）");
        $fatal(1, "run2 descriptor geometry mismatch");
      end
      if (IMG_W_B * IMG_H_B > maxPix) begin
        $display("TB-ERROR: 第二套 IMG_W*IMG_H=%0d > maxPix=%0d", IMG_W_B * IMG_H_B, maxPix);
        $fatal(1, "run2 pixels exceed maxPix");
      end
      go2_en = 1'b1;
    end

    // ---- 复位 ----
    repeat (4) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    // ---- 带外预载整层权重（★ C3.16：**一套权重信箱**；一拍一字节，地址线性 0..NENTRY-1）----
    //   口径与旧的四套装载口**逐拍同形**：`wgt_sel` 选切片、`wgt_we`/`wgt_addr`/`wgt_data` 一拍一写。
    //   切片 0（`conv`）—— 与旧 `we/waddr/wdin` 那条通路逐字节相同（`+WGTFILE=` 的向量落这里）。
    wgt_sel = 3'd0;
    for (i = 0; i < NENTRY; i = i + 1) begin
      @(negedge clk);
      wgt_we = 1'b1; wgt_addr = i[9:0]; wgt_data = wm[i];
    end
    @(negedge clk);
    wgt_we = 1'b0; wgt_addr = 10'd0; wgt_data = 8'h00;
    // ★ C3.9b：尾切片（切片 1 = `convT`）的带外预载（`+WGTFILE_T=`）
    if (has_wgt_t) begin
      wgt_sel = 3'd1;
      for (i = 0; i < NENTRY; i = i + 1) begin
        @(negedge clk);
        wgt_we = 1'b1; wgt_addr = i[9:0]; wgt_data = wm_t[i];
      end
      @(negedge clk);
      wgt_we = 1'b0; wgt_addr = 10'd0; wgt_data = 8'h00;
    end
    // ★ A-1a：切片 2/3 的带外预载（`+WGTFILE2=` / `+WGTFILE3=`）
    if (has_wgt2) begin
      wgt_sel = 3'd2;
      for (i = 0; i < NENTRY; i = i + 1) begin
        @(negedge clk);
        wgt_we = 1'b1; wgt_addr = i[9:0]; wgt_data = wm2[i];
      end
      @(negedge clk);
      wgt_we = 1'b0; wgt_addr = 10'd0; wgt_data = 8'h00;
    end
    if (has_wgt3) begin
      wgt_sel = 3'd3;
      for (i = 0; i < NENTRY; i = i + 1) begin
        @(negedge clk);
        wgt_we = 1'b1; wgt_addr = i[9:0]; wgt_data = wm3[i];
      end
      @(negedge clk);
      wgt_we = 1'b0; wgt_addr = 10'd0; wgt_data = 8'h00;
    end
    wgt_sel = 3'd0;

    // ---- 起跑：CTRL 一拍脉冲（默认 1；+CTRL=0 显式挡住 —— 本闸门不做"不给 start"的观察）----
    ctrl = 1; got_ctrl = $value$plusargs("CTRL=%d", ctrl);
    if (got_ctrl && ctrl == 0) begin
      $display("TB-ERROR: +CTRL=0（不给 start）本闸门不用"); $fatal(1, "CTRL=0");
    end
    repeat (2) @(negedge clk);
    @(negedge clk); go = 1'b1; go_count = 1;
    @(negedge clk); go = 1'b0;

    // ---- 等 done / err（带超时）----
    while (!done_seen && !err_seen) begin
      @(posedge clk);
      if (done)     done_seen = 1'b1;
      else if (err) err_seen  = 1'b1;
      else begin
        timeout_cnt = timeout_cnt + 1;
        if (timeout_cnt > TIMEOUT) begin
          $display("RESULT: FAIL timeout(第 %0d 次 go 等 done/err 超 %0d 拍)", go_count, TIMEOUT);
          $fatal(1, "UnitExecTb timeout");
        end
      end
    end
    repeat (4) @(negedge clk);   // 让 AXI 观察器收尾

    // ---- 连跑（+GO2）：等 busy 落 0 ⇒ 换第二套描述符 ⇒ 再脉冲一次 go ----
    //   这一步就是 C3.10（LayerSched 把同一个实例按描述符连跑）的形状：第二次 go 必须**被受理并跑完**。
    busy_at_go2 = busy;
    if (go2_en) begin
      busy2_cnt = 0;
      while (busy) begin
        @(posedge clk);
        busy2_cnt = busy2_cnt + 1;
        if (busy2_cnt > TIMEOUT) begin
          $display("RESULT: FAIL timeout(等第一次 go 之后 busy 落 0 超 %0d 拍) ⇒ 第二次 go 根本没法受理", TIMEOUT);
          $fatal(1, "UnitExecTb busy never deasserts");
        end
      end
      @(negedge clk);
      desc0 = desc0b; desc1 = desc1b; desc2 = desc2b; desc3 = desc3b;
      desc4 = desc4b; desc5 = desc5b; desc6 = desc6b; desc7 = desc7b;
      @(negedge clk); go = 1'b1; go_count = 2;
      @(negedge clk); go = 1'b0;
      while (!done2_seen && !err2_seen) begin
        @(posedge clk);
        if (done)     done2_seen = 1'b1;
        else if (err) err2_seen  = 1'b1;
        else begin
          timeout2_cnt = timeout2_cnt + 1;
          if (timeout2_cnt > TIMEOUT) begin
            $display("RESULT: FAIL timeout(第 2 次 go 等 done/err 超 %0d 拍；busy=%0d)", TIMEOUT, busy);
            $fatal(1, "UnitExecTb run2 timeout");
          end
        end
      end
      repeat (4) @(negedge clk);
      $display("RUN2_DONE=%0d RUN2_ERR=%0d RUN2_BUSY_AFTER=%0d RUN2_CYCLES=%0d",
               done2_seen, err2_seen, busy, timeout2_cnt);
    end

    $display("DONE_SEEN=%0d ERR_SEEN=%0d BUSY=%0d GO_COUNT=%0d BUSY_AT_GO2=%0d",
             done_seen, err_seen, busy, go_count, busy_at_go2);
    $display("RD_BYTES_PEAK=%0d WR_BYTES=%0d", rd_peak, wr_bytes);
    $display("AR_BURSTS=%0d AW_BURSTS=%0d B_OK=%0d", ar_bursts, aw_bursts, b_ok);

    // ---- C3.9a：把**中间 FusionBuf** 读回、逐字节写 +MIDFILE=（仅观察；同步读 1 拍）----
    //   展平顺序（与 FusionBuf 消费者契约 / FusionBufTb 同口径）：[rd_row][rd_col][ci] = (rd_row*IMG_W + rd_col)*8 + ci。
    //   读 rd_row=0/1/2 三档（3 行环窗）⇒ 3*IMG_W*8 字节。DUT 此刻已 IDLE，读是纯观察、无回写。
    if (midread_en) begin
      midf = $fopen(midfile, "w");
      if (midf == 0) begin
        $display("TB-ERROR: 打不开 +MIDFILE=%0s", midfile); $fatal(1, "cannot open MIDFILE");
      end
      for (mr = 0; mr < 3; mr = mr + 1) begin
        for (mc = 0; mc < IMG_W; mc = mc + 1) begin
          @(negedge clk); mid_rd_row = mr[1:0]; mid_rd_col = mc[5:0];
          @(negedge clk);
          $fwrite(midf, "%02x\n", mid_rd_data_0);
          $fwrite(midf, "%02x\n", mid_rd_data_1);
          $fwrite(midf, "%02x\n", mid_rd_data_2);
          $fwrite(midf, "%02x\n", mid_rd_data_3);
          $fwrite(midf, "%02x\n", mid_rd_data_4);
          $fwrite(midf, "%02x\n", mid_rd_data_5);
          $fwrite(midf, "%02x\n", mid_rd_data_6);
          $fwrite(midf, "%02x\n", mid_rd_data_7);
        end
      end
      @(negedge clk); mid_rd_row = 2'd0; mid_rd_col = 6'd0;
      $fclose(midf);
      $display("MIDDUMP rows=3 cols=%0d bytes=%0d file=%0s", IMG_W, 3 * IMG_W * 8, midfile);
    end
    $display("HEAD_MODE=%0d MID_ROWS=%0d", head_mode, mid_rows);
    // ★ C3.9b：尾分支的自报（另起一行，保持上面那行的**逐字**行形不动，C3.9a 闸门在 grep 它）。
    $display("TAIL_MODE=%0d TAIL_ROWS=%0d", tail_mode, tail_rows);
    // ★ A-1a：链长自报（另起一行；避开 time-0 组合传播竞态 —— 此处网表已稳定）。
    // ★ A-1b：链长回读（网表把收到的 `io.chain_len` 回读出来）+ 生成期上限 `lmax`；观察/对账
    //   （在收尾处打印，避开 time-0 组合传播竞态）。`CHAIN_LEN_REP != CHAIN_LEN` ⇒ 端口没接上。
    $display("CHAIN_LEN=%0d CHAIN_LEN_REP=%0d LMAX=%0d", CHAINLEN, chain_rep, lmax);

    if (go2_en) begin
      // ---- 连跑判据：两次都跑完、无 err、busy 落 0、各计数 == 两次之和 ----
      //   `rd_peak` 是**每笔搬运**的口径（DdrMaster 在每次 CHK 清零）⇒ 仍是 IN_BYTES；
      //   `wr_bytes` 是**最后一笔**的口径 ⇒ 仍是 IMG_W*IMG_H*C_OUT；
      //   而 AR/AW/B 与内存模型的 bursts 是**累加**的 ⇒ 必须是两次之和（两处独立计数一起对）。
      if (done_seen && done2_seen && !err_seen && !err2_seen && busy == 0 &&
          rd_peak == IN_BYTES && wr_bytes == (IMG_W * IMG_H * C_OUT) &&
          ar_bursts == 2 * (IN_BYTES / 128) && aw_bursts == 2 * (IN_BYTES / 128) &&
          b_ok == 2 * (IN_BYTES / 128)) begin
        $display("RESULT: PASS");
        $finish;
      end else begin
        $display("RESULT: FAIL 连跑 done1=%0d done2=%0d err1=%0d err2=%0d busy=%0d rd_peak=%0d wr_bytes=%0d ar=%0d(期望 %0d) aw=%0d b=%0d",
                 done_seen, done2_seen, err_seen, err2_seen, busy, rd_peak, wr_bytes,
                 ar_bursts, 2 * (IN_BYTES / 128), aw_bursts, b_ok);
        $fatal(1, "UnitExecTb two-go failed");
      end
    end else if (expect_err) begin
      if (err_seen && !done_seen && ar_bursts == 0 && aw_bursts == 0 &&
          rd_peak == 0 && wr_bytes == 0) begin
        $display("RESULT: PASS");
        $finish;
      end else begin
        $display("RESULT: FAIL 期待 err 且零搬运，实际 err=%0d done=%0d ar=%0d aw=%0d rdb=%0d wrb=%0d",
                 err_seen, done_seen, ar_bursts, aw_bursts, rd_peak, wr_bytes);
        $fatal(1, "UnitExecTb expected err with zero movement");
      end
    end else if (tiled_en) begin
      // ★★ T-S2R：tiled 模式判据 = **跑完 + 无 err + busy 落 0**（数值/流量由闸门与整层黄金逐字节对账；
      //   tiled 的 RD/WR 都是**每行一笔**，字节数不是"一笔搬运"的简单口径 ⇒ 不在装置里判字节数）。
      $display("TILED_RD_BYTES=%0d TILED_WR_BYTES=%0d TILED_AR=%0d TILED_AW=%0d TILED_B=%0d",
               rd_peak, wr_bytes, ar_bursts, aw_bursts, b_ok);
      if (done_seen && !err_seen && busy == 0) begin
        $display("RESULT: PASS");
        $finish;
      end else begin
        $display("RESULT: FAIL tiled done=%0d err=%0d busy=%0d rd=%0d wr=%0d ar=%0d aw=%0d",
                 done_seen, err_seen, busy, rd_peak, wr_bytes, ar_bursts, aw_bursts);
        $fatal(1, "UnitExecTb tiled failed");
      end
    end else begin
      //   0 = 头档（`chainLen=1, bit0=0`）：**无 WR 相位**（结构上 `WRSTART/WRRUN` 进不去）；
      //   1 = plain/S2（`chainLen=1, bit0=1`）**或链**（`chainLen≥2, bit0=0`：末片落 DDR）；
      //   2 = **退化档**（`chainLen≥2, bit0=1`：切片0 的中间**也**落 DDR —— 只作闸门负对照）。
      //   RD 恒**只有一笔**（= 链首/单片的输入；中间张量结构性**零 DDR 读**）。
      //   （数值与诱饵区由**闸门**用 Python 黄金与内存转储逐字节对账；TB 只管结构计数。）
      if (done_seen && !err_seen && rd_peak == IN_BYTES &&
          wr_bytes == (WR_MULT * IMG_W * IMG_H * C_OUT) &&
          ar_bursts == (IN_BYTES / 128) &&
          aw_bursts == ((WR_MULT * IMG_W * IMG_H * C_OUT) / 128) &&
          b_ok == ((WR_MULT * IMG_W * IMG_H * C_OUT) / 128)) begin
        $display("RESULT: PASS");
        $finish;
      end else begin
        $display("RESULT: FAIL chainLen=%0d head=%0d WR_MULT=%0d done=%0d err=%0d rd_peak=%0d(期望 %0d) wr_bytes=%0d(期望 %0d) ar=%0d(期望 %0d) aw=%0d b=%0d",
                 CHAINLEN, head_desc, WR_MULT, done_seen, err_seen, rd_peak, IN_BYTES,
                 wr_bytes, WR_MULT * IMG_W * IMG_H * C_OUT, ar_bursts, IN_BYTES / 128, aw_bursts, b_ok);
        $fatal(1, "UnitExecTb failed");
      end
    end
  end

  // 兜底：仿真不收敛时也报红退出，别让闸门挂死。
  integer wd;
  initial begin
    for (wd = 0; wd < WD_MAX; wd = wd + 1) @(posedge clk);
    $display("RESULT: FAIL timeout(global watchdog %0d cycles)", WD_MAX);
    $fatal(1, "UnitExecTb global timeout");
  end

endmodule
