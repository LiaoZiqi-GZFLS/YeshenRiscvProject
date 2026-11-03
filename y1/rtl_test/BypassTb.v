// 旁路算子装置 —— MaxPoolUnit / ResizeUnit / AddUnit / SigmoidUnit 的功能闸门装置
// （gen/MaxPoolUnit*.v / ResizeUnit*.v / AddUnit*.v / SigmoidUnit*.v）。
// 为什么是 .v（不走 SpinalHDL）：本机整套数值闸门都跑 `iverilog -g2012` + `$readmemh` 向量文件，
// 装置必须与 tools/run_linebuffer_ab.sh / run_fusionbuf_ab.sh 那个装置同构，闸门才只有一套口径。
//
// ★ 形状 / 算子靠**编译期宏**传（不要用运行期 plusargs 改形状）：
//     BP_NCI = DUT 的 C        （默认 2；DUT 端口名 x_0/x_1/y_0/y_1 不可参数化 ⇒ **本装置只仿 C=2**，
//                               NCI != 2 时 time 0 直接 $fatal。更大 C 未被本装置仿真，属**已知残留风险**。）
//     BP_NW  = DUT 的 WIDTH    （默认 4；闸门对每个算子各编译两个形状：见 tools/run_bypass_ab.sh）
//     BP_MOD = DUT 的模块名    （默认 MaxPoolUnit；闸门按算子换 -DBP_MOD=<名>）
//     BP_TWO_IN = 双输入档（**只有 AddUnit 用**）：DUT 端口是 x_a/x_b + 两路 valid，本装置据此
//                 换一套例化与一套喂流（每列 2*C 字节 = A 的 C 个通道 + B 的 C 个通道）。
//     BP_NOCLK  = 网表**没有** clk/reset 端口（AddUnit / SigmoidUnit 是**纯组合、零状态**的单元，
//                 SpinalHDL 不为这样的组件发时钟口）⇒ 例化时省掉那两个口。
//                 ⚠ 这四个算子里只有 MaxPool/Resize 有 clk/reset；**不是**"装置忘了接"。
//   ★ **+OP 与 BP_TWO_IN 必须互锁**（两个方向都 time 0 $fatal）：双输入档只认 `+OP=add`，
//     `+OP=add` 也只认双输入档 —— 否则"网表/算子张冠李戴"的静默错判会漏网。
//   四个算子中前三个的端口名/位宽**完全相同**（x(C)/x_valid/x_ready + y(C)/y_valid + imgC/imgW），
//   所以同一份装置源码能同时驱动 MaxPool / Resize / Sigmoid；**AddUnit 多一路输入**（见上）。
//
// 契约（与 tools/run_bypass_ab.sh 头部注释、四个 rtl/*.scala 的文件头同源）：
//   +XFILE=<file>  输入张量的**流顺序**字节：行主序的列流，一拍一列、列内 C 个通道连续
//                  ⇒ 一维下标 = (row*W + col)*C + ci，共 C*W*H 字节
//                  ★ `+OP=add` 时每列 **2*C** 字节：`(row*W+col)*(2C) + (0..C-1 => A, C..2C-1 => B)`
//                    （两路**按列交织** = 唯一的硬件口径"两路同拍同列"；共 2*C*W*H 字节）
//                  ★ `+OP=sigmoid` 时每个字节 = **Q3.4** 的定点 x（见下 +LUTFILE）
//   +YFILE=<file>  期望输出张量的**流顺序**字节（行主序的像素流，一拍一个像素、像素内 C 个通道连续）
//                  maxpool ⇒ C*(W/2)*(H/2)；resize ⇒ C*(2W)*(2H)；add/sigmoid ⇒ C*W*H
//   +OP=maxpool|resize|add|sigmoid  决定期望的输出颗数、输入每列字节数、以及反压特征（见下）
//   +C=<n> +IW=<n> +H=<n>  维度（C/IW 必须 == 网表自报的 imgC/imgW 与本装置的宏，不符 time 0 $fatal；
//                          **H 必须偶数且 <= 64 —— 但只对 maxpool/resize**：那两个单元按"2 行/行对"
//                          工作；add/sigmoid 是**逐点**算子，奇数 H 合法（闸门的 add-w5 档就用 H=3，
//                          专门证明这条放宽是真放宽）。
//   +LUTFILE=<file> （**只有 +OP=sigmoid 用，且必须给**）256 项查表的十六进制文件
//                  （gen/sigmoid_lut.hex，由 tools/bypass_ref.py --genlut 生成）。
//                  本装置**自己 `$readmemh` 载入它**，并**自己**按冻结地址约定算期望
//                  （`exp = lut[x ^ 0x80]`）与 DUT 输出逐字节比 ⇒ 打印 `LUT-XCHK`（期望 0）
//                  与 `LUT-CODES`（本次跑到的**不同码点数**，期望 256 —— 覆盖满 int8 全部码点）。
//                  这条与 +YFILE 的对账**互相独立**：一条走"闸门给的黄金"，一条走"装置自己查表"。
//   +STALLB=1   （**只有 +OP=add 用**）把 B 路的 `x_b_valid` 恒置 0，检查 DUT **一列不吃、一颗不出**
//                  ——这是"y_valid/消费条件同时看两路 valid"的**唯一**判据（正常跑两路 always 同拍齐，
//                  "只看 A 路"的错在别的作业里**永不可观测**）。此档下 `+YFILE` 被忽略（装置只判
//                 "0 列 / 0 颗"），闸门也不比 Y。
//
// ★ 时序（"同拍采"）：四个算子的 y/y_valid 都是**组合**输出（y_valid 由状态寄存器/输入译码出来，
//   y 由当拍的表/加法/窗口组合选出）。装置在 negedge 摆输入、等 #1 让组合通路稳定后**同拍**
//   既判 x_ready（本拍是否吃下这一列）又采 y_valid/y —— 这正是"本拍的输入列与它引发的输出像素
//   在同一拍"的口径（DUT 的寄存器在 posedge 才更新，所以 #1 采到的还是本拍的状态）。
//
// 输出：
//   一行 "Y <hh> <hh> ..."（流顺序，共 NOUTB 个字节）—— 闸门用 grep '^Y ' 收后逐字节对账；
//   一行 "TB-INFO: ... LUT-XCHK=<n> LUT-CODES=<n>"（sigmoid 的两个独立对账计数）；
//   一行 "RESULT: PASS" / "RESULT: FAIL ..." —— FAIL 时 $fatal 让 vvp 退出非 0。
//
// ★ 装置侧的结构判据（防"网表与 +OP 张冠李戴"的静默错判）：
//   · 参数自报：+C/+IW 与网表 imgC/imgW 逐位对（不符 ⇒ time 0 $fatal）；
//   · 双输入互锁：BP_TWO_IN ⟺ +OP=add（不符 ⇒ time 0 $fatal）；
//   · 反压特征：maxpool / add / sigmoid 的 x_ready **恒 1**（都是"从不反压"的单元）、resize 出数相位
//     一定把 x_ready 拉低过 ⇒ 装置统计"运行期间是否见过 x_ready=0"，与 +OP 不符就报红
//     （网表端口同名同宽，光看输出长度有可能撞上，必须另有一条结构特征钉住）；
//   · 输出颗数：期望 NOUTPIX 颗，采集后**再排空 8 拍**，多出来的一律算错（防"多吐"）；
//   · sigmoid：`LUT-XCHK=0` + `LUT-CODES=256` + 逐字节对账数 == 输出字节数（防"对账根本没跑"）。
//
// =============================================================================
// ★★ T-S3a.1：**`+TILED_B` 档** —— 旁路 tiling 的装置（`-DBP_TILED_B` 编出来的**另一个** `BypassTb`）
// -----------------------------------------------------------------------------
// 为什么另起一档、而且要靠**编译期宏**：上面那套装置喂的是**单元列流**（`x/x_valid/x_ready`），
//   而 tiling 的被测对象是 `gen/BypassExec.v`（`BypassExec` 级：自带 `DdrMaster` 主口 + 四个旁路单元）
//   —— 它的激活**由 DDR 取**（这正是 tiling 的要点：按 tile 的输入行跨步发 32 B 对齐窗口读），
//   装置**不喂列**。`BypassExec` 的端口（`go/desc_0..7/busy/done/err` + AXI4 主口 + 布局模式 + 遥测）
//   与 `MaxPoolUnit/...` 的端口**毫无重叠** ⇒ 只能换一套例化 + 换一套驱动（所以用 `ifdef` 换整份
//   模块体，而**不是**像 `+TILED_W` 那样在同一个 DUT 上开一个运行期开关）。
//   ★ **additive**：宏不给时本文件与改动前**逐字节同形** ⇒ `tools/run_bypass_ab.sh` 的 12 个作业
//     一字不变地照跑（它不带 `-DBP_TILED_B`）。
//
// 契约（plusargs；几何/进制字面与 `tools/run_bypass_tile_ab.sh` 同源）：
//   +TILED_B        本档的**开关**（缺 ⇒ time 0 `$fatal`；与 `UnitExecWideTb.v` 的 `+TILED_W` 同手法：
//                   装置"以为在跑 tiling、其实挂错了档"必须**响亮**，不能静默）
//   +OP=maxpool|resize|add|sigmoid   算子（译成 `TYPE`；与 `run_bypass_ab.sh` 的 `+OP` 同名同义）
//   +TYPE=<n>       `TYPE` 的数值形式（`0x10/0x11/0x13/0x14`）；与 `+OP` 给一个即可（两个都给则必须一致）
//   +CIN +COUT      `desc[2]` 的 `C_IN/C_OUT`（**描述符原值**：不合 `BypassExec.geomOk` ⇒ DUT 响亮 err）
//   +W +H           **输出**几何 = `desc[1]` 的 `IMG_W/IMG_H`（与 UnitExecWideTb 同名同义；输入几何由
//                   算子反推：maxpool 输入 `2W×2H`、resize 输入 `W/2×H/2`、add/sigmoid 输入 == 输出）
//   +GROUP +FLAGS +SRC +DST +INB +QSHIFT +LID +SRC2 +SRC2K   描述符其余字段
//                   （缺省：GROUP=1 FLAGS=1 QSHIFT=6 LID=0 SRC2=0 SRC2K=0）
//   ★★ T-S3a.2d：`+SRC2` 现在是**真的**接到 `BypassExec.io.src2` 上（此前本档只解析、没驱动 ⇒
//     `+SRC2` 是空的），并且新增 `+SRC2K` = `w3[31:16]` 的 `SRC2_K`（E1 契约：**非 0** 才会让
//     `BypassExec` 走两趟读 `addTwoSrc`；`SRC2K=0` ⇒ `desc[3]` 与改动前**逐位相同** ⇒ 既有 tile
//     作业一字不变）。`SRC2 == 0 ∧ SRC2K != 0` 是合法组合（第二路源就在 0 地址：本档不判这种"业务
//     上有没有意义"，它只钉硬件通路），闸门总是两个一起给。
//   +SRCPLANAR=1 +DSTPLANAR=1   布局模式两位（`BypassExec.io.src_planar/dst_planar`；缺省 0 = 线性 NHWC）
//   +MEMFILE= / +DUMPFILE= / +dump   转给 `AxiMemModel.v`（预载/落盘/统计，与 UnitExec 的闸门同一套）
//
// 判据（**本档不做数值判据**，与 `+TILED_W` 同一条纪律）：
//   `go` 之后跑完 ⇒ `done` 见过 ∧ `err` 没举过 ∧ `busy` 落 0 ⇒ `RESULT: PASS`；
//   否则 `RESULT: FAIL ...` + `$fatal`（`vvp` 非 0）。逐字节的数值/DST/邻居判据由**闸门**拿
//   **整层黄金**（`tools/bypass_ref.py`，冻结参考）在 `DST` 区对账 —— 装置自己**不**打印 Y。
//   ⚠ T-S3a.1 里 tile 路径**还没实现**（落地在 T-S3a.2）⇒ 真表旁路形状必然 `err`/超时
//     ⇒ 闸门判 `JUDGE-RED`，这正是本片期望的**正对照先红**（退出码 1）。
// =============================================================================
`timescale 1ns/1ps

// ---- 形状 / 算子（编译期宏；默认 = 主功能档 C=2 / WIDTH=4 / MaxPoolUnit / 单输入）----
`ifndef BP_NCI
  `define BP_NCI 2
`endif
`ifndef BP_NW
  `define BP_NW 4
`endif
`ifndef BP_MOD
  `define BP_MOD MaxPoolUnit
`endif

// =============================================================================
// ★★ T-S3a.1：`+TILED_B` 档的**模块体**（`-DBP_TILED_B` 时**替换**下面那套"列流装置"）。
//   被测 = `gen/BypassExec.v`（`BypassExec`：自带 `DdrMaster` 主口 + 四个旁路单元），
//   对手 = `rtl_test/AxiMemModel.v`。装置**一列都不喂**（激活由 DUT 从 DDR 取，这正是 tiling 的要点）。
//   契约/判据见本文件头（`+TILED_B` 那一节）。
// =============================================================================
`ifdef BP_TILED_B
module BypassTb;
  localparam integer MEMSZ   = 2621440;   // 2.5 MB（与 run_tiling2d_wide_ab.sh / UnitExecWideTb 同口径）
  localparam integer TIMEOUT = 4000000;   // 等 done/err 的拍数上限
  localparam integer WD_MAX  = 8000000;   // 全局看门狗（兜底：装置不收敛时不让闸门挂死）

  reg clk = 1'b0;
  reg rst = 1'b1;
  always #5 clk = ~clk;

  reg         go = 1'b0;
  reg  [31:0] desc0 = 0, desc1 = 0, desc2 = 0, desc3 = 0;
  reg  [31:0] desc4 = 0, desc5 = 0, desc6 = 0, desc7 = 0;
  reg         src_planar = 1'b0, dst_planar = 1'b0;
  reg  [27:0] src2 = 28'd0;
  wire        busy, done, err, col_dbg_ok;
  wire [7:0]  col_dbg_0, col_dbg_1, col_dbg_2, col_dbg_3;
  wire [7:0]  col_dbg_4, col_dbg_5, col_dbg_6, col_dbg_7;
  wire [31:0] rd_bytes, wr_bytes;
  wire [1:0]  opMode;

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

  BypassExec dut (
    .go(go),
    .desc_0(desc0), .desc_1(desc1), .desc_2(desc2), .desc_3(desc3),
    .desc_4(desc4), .desc_5(desc5), .desc_6(desc6), .desc_7(desc7),
    .busy(busy), .done(done), .err(err),
    .src_planar(src_planar), .dst_planar(dst_planar), .src2(src2),
    .col_dbg_0(col_dbg_0), .col_dbg_1(col_dbg_1), .col_dbg_2(col_dbg_2), .col_dbg_3(col_dbg_3),
    .col_dbg_4(col_dbg_4), .col_dbg_5(col_dbg_5), .col_dbg_6(col_dbg_6), .col_dbg_7(col_dbg_7),
    .col_dbg_ok(col_dbg_ok),
    .rd_bytes(rd_bytes), .wr_bytes(wr_bytes), .opMode(opMode),
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

  // ---- plusarg 落点 ----
  reg [8*16-1:0] opstr;
  reg [8*8-1:0]  op_lo, op_hi;
  integer CIN, COUT, IW, IH, GROUP, TYPE_, TINT, FLAGS, SRC, DST, INB, QSHIFT, LID, SRC2, SRC2K;
  integer is_maxpool, is_resize, is_add, is_sigmoid, op_known;
  integer got_tiled_b, cyc, i, wd;
  integer ar_bursts, aw_bursts, b_ok;
  reg done_seen, err_seen;
  reg [31:0] rd_peak;

  always @(posedge clk) begin
    if (!rst) begin
      if (axi_ar_valid && axi_ar_ready) ar_bursts = ar_bursts + 1;
      if (axi_aw_valid && axi_aw_ready) aw_bursts = aw_bursts + 1;
      if (axi_b_valid  && axi_b_ready)  b_ok      = b_ok + 1;
      if (rd_bytes > rd_peak) rd_peak = rd_bytes;
      // `done`/`err` 都是**单拍脉冲**（`BypassExec` 的相位 FSM 一拍就走完）⇒ 时钟沿锁存，
      // 免得只靠下面的等待循环采样而漏掉（与 UnitExecWideTb 同一条纪律）。
      if (err)  err_seen  = 1'b1;
      if (done) done_seen = 1'b1;
    end
  end

  initial begin
    go = 1'b0; src2 = 28'd0; src_planar = 1'b0; dst_planar = 1'b0;
    desc0 = 0; desc1 = 0; desc2 = 0; desc3 = 0;
    desc4 = 0; desc5 = 0; desc6 = 0; desc7 = 0;
    done_seen = 1'b0; err_seen = 1'b0; cyc = 0; op_known = 0; TYPE_ = 0;
    ar_bursts = 0; aw_bursts = 0; b_ok = 0; rd_peak = 32'd0;
    opstr = 0;

    // ---- 档位自检：本模块体只在 -DBP_TILED_B 下编出来 ⇒ 运行期也必须给 +TILED_B ----
    got_tiled_b = $test$plusargs("TILED_B");
    $display("TB TILED_B_EN=%0d GOT=%0d", got_tiled_b == 0 ? 0 : 1, got_tiled_b);
    if (got_tiled_b == 0) begin
      $display("TB-ERROR: 本装置以 -DBP_TILED_B 编成 tiling 档（DUT = gen/BypassExec.v，激活由 DDR 取），必须给 +TILED_B");
      $fatal(1, "missing TILED_B");
    end

    // ---- 几何 / 描述符字段 ----
    if (!$value$plusargs("CIN=%d", CIN))   begin $display("TB-ERROR: 缺 +CIN=");  $fatal(1,"CIN"); end
    if (!$value$plusargs("COUT=%d", COUT)) begin $display("TB-ERROR: 缺 +COUT="); $fatal(1,"COUT"); end
    if (!$value$plusargs("W=%d", IW))      begin $display("TB-ERROR: 缺 +W=");    $fatal(1,"W"); end
    if (!$value$plusargs("H=%d", IH))      begin $display("TB-ERROR: 缺 +H=");    $fatal(1,"H"); end
    if (!$value$plusargs("GROUP=%d", GROUP)) GROUP = 1;
    if (!$value$plusargs("FLAGS=%d", FLAGS)) FLAGS = 1;
    if (!$value$plusargs("SRC=%d", SRC))   begin $display("TB-ERROR: 缺 +SRC=");  $fatal(1,"SRC"); end
    if (!$value$plusargs("DST=%d", DST))   begin $display("TB-ERROR: 缺 +DST=");  $fatal(1,"DST"); end
    if (!$value$plusargs("INB=%d", INB))   INB = CIN * IH * IW;
    if (!$value$plusargs("QSHIFT=%d", QSHIFT)) QSHIFT = 6;
    if (!$value$plusargs("LID=%d", LID))   LID = 0;
    if (!$value$plusargs("SRC2=%d", SRC2)) SRC2 = 0;
    if (!$value$plusargs("SRC2K=%d", SRC2K)) SRC2K = 0;
    // ★★ T-S3a.2d：`+SRC2` 驱动 DUT 的第二路源口（此前只解析、没驱动 ⇒ 本档的 Add 通路是死的）。
    src2 = SRC2[27:0];
    src_planar = $test$plusargs("SRCPLANAR");
    dst_planar = $test$plusargs("DSTPLANAR");

    // ---- 算子：`+OP=<名>`（与 run_bypass_ab.sh 同名同义）**或** `+TYPE=<数值>`；两个都给则必须一致 ----
    if ($value$plusargs("OP=%s", opstr)) begin
      // 对齐方式随实现（iverilog 实测右对齐、高字节清零）⇒ 低 8 字节与高 8 字节两种都认（同既有装置）。
      op_lo = opstr[8*8-1:0];
      op_hi = opstr[8*16-1 -: 8*8];
      is_maxpool = (op_lo == "maxpool") || (op_hi == "maxpool");
      is_resize  = (op_lo == "resize")  || (op_hi == "resize");
      is_add     = (op_lo == "add")     || (op_hi == "add");
      is_sigmoid = (op_lo == "sigmoid") || (op_hi == "sigmoid");
      if      (is_maxpool) TYPE_ = 8'h10;
      else if (is_resize)  TYPE_ = 8'h11;
      else if (is_add)     TYPE_ = 8'h13;
      else if (is_sigmoid) TYPE_ = 8'h14;
      else begin
        $display("TB-ERROR: +OP=%0s 不认识（只有 maxpool | resize | add | sigmoid）", opstr);
        $fatal(1, "bad OP");
      end
      op_known = 1;
    end
    if ($value$plusargs("TYPE=%d", TINT)) begin
      if ((TINT != 8'h10) && (TINT != 8'h11) && (TINT != 8'h13) && (TINT != 8'h14)) begin
        $display("TB-ERROR: +TYPE=0x%02x 不是旁路算子（0x10 maxpool / 0x11 resize / 0x13 add / 0x14 sigmoid）", TINT);
        $fatal(1, "bad TYPE");
      end
      if (op_known && (TINT != TYPE_)) begin
        $display("TB-ERROR: +TYPE=0x%02x 与 +OP=%0s（= 0x%02x）不一致（张冠李戴必须响亮）", TINT, opstr, TYPE_);
        $fatal(1, "TYPE/OP mismatch");
      end
      TYPE_ = TINT; op_known = 1;
    end
    if (op_known == 0) begin
      $display("TB-ERROR: 必须给 +OP=maxpool|resize|add|sigmoid（或 +TYPE=<数值>；见文件头）");
      $fatal(1, "no op");
    end

    // ---- 描述符（与 desc_table.pack 的位打包一致）----
    desc0 = (FLAGS << 8) | (TYPE_ & 8'hFF);   // TYPE, FLAGS
    desc1 = IW | (IH << 16);                  // IMG_W, IMG_H（= 输出几何）
    desc2 = CIN | (COUT << 16);               // C_IN, C_OUT（**描述符原值**）
    desc3 = GROUP | (1 << 12) | (SRC2K << 16);  // GROUP, PAD=1, ★★ T-S3a.2d：w3[31:16] = SRC2_K（E1）
    desc4 = SRC; desc5 = DST; desc6 = INB;
    desc7 = QSHIFT | (LID << 8);              // QUANT_SHIFT, LAYER_ID（旁路不用，照打包口径填）
    $display("TB TILED_B: OP=%0s TYPE=0x%02x CIN=%0d COUT=%0d IMG_W=%0d IMG_H=%0d GROUP=%0d SRC=%0d DST=%0d INB=%0d QSHIFT=%0d LID=%0d SRC2=%0d SRC2K=%0d PLANAR=%0d,%0d",
             opstr, TYPE_, CIN, COUT, IW, IH, GROUP, SRC, DST, INB, QSHIFT, LID, SRC2, SRC2K, src_planar, dst_planar);

    // ---- 复位 + 起跑 ----
    repeat (4) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);
    @(negedge clk);
    go = 1'b1;
    @(negedge clk);
    go = 1'b0;

    // ---- 等 done/err：**一列都不喂**（激活由 DUT 自己从 DDR 取，这正是 tiling 的要点）----
    while (!done_seen && !err_seen) begin
      @(posedge clk);
      if (done) done_seen = 1'b1;
      if (err)  err_seen  = 1'b1;
      cyc = cyc + 1;
      if (cyc > TIMEOUT) begin
        $display("RESULT: FAIL timeout(+TILED_B 等 done/err 超 %0d 拍；rd=%0d wr=%0d busy=%0d cyc=%0d)",
                 TIMEOUT, rd_bytes, wr_bytes, busy, cyc);
        $fatal(1, "BypassTb(+TILED_B) timeout");
      end
    end
    repeat (8) @(negedge clk);
    go = 1'b0;

    $display("TB TILED_B RTL: opMode=%0d RD_BYTES=%0d WR_BYTES=%0d RD_PEAK=%0d AR=%0d AW=%0d B=%0d CYCLES=%0d DONE=%0d ERR=%0d BUSY=%0d",
             opMode, rd_bytes, wr_bytes, rd_peak, ar_bursts, aw_bursts, b_ok, cyc, done_seen, err_seen, busy);

    // ---- 判据（**本档不做数值判据**）：跑完 + 无 err + `busy` 落 0 ----
    //   逐字节的 DST/邻居判据由闸门拿整层黄金（tools/bypass_ref.py，冻结）在 DST 区对账。
    if (done_seen && !err_seen && (busy == 0)) begin
      $display("RESULT: PASS");
      $finish;
    end else begin
      $display("RESULT: FAIL tiled_b done=%0d err=%0d busy=%0d rd=%0d wr=%0d cyc=%0d",
               done_seen, err_seen, busy, rd_bytes, wr_bytes, cyc);
      $fatal(1, "BypassTb(+TILED_B) failed");
    end
  end

  // 兜底：装置不收敛时超时判红（非 0 退出），避免闸门挂死。
  initial begin
    for (wd = 0; wd < WD_MAX; wd = wd + 1) @(posedge clk);
    $display("RESULT: FAIL timeout(global watchdog %0d cycles)", WD_MAX);
    $fatal(1, "BypassTb(+TILED_B) global timeout");
  end
endmodule
`else
module BypassTb;

  localparam NCI    = `BP_NCI;             // DUT 的 C（端口名不可参数化 ⇒ 只支持 2）
  localparam NW     = `BP_NW;              // DUT 的 WIDTH
  localparam MAXH   = 64;
  localparam MAXIN  = 2 * NCI * MAXH * NW; // 输入最多 2*C*H*W 字节（双输入的 add 要翻倍）
  localparam MAXOUT = 4 * NCI * MAXH * NW; // 输出最多 4 倍（resize x2 两个方向）

  reg [8*256-1:0] xfile, yfile, lutfile;
  reg [8*16-1:0]  opstr;
  reg [8*8-1:0]   op_lo, op_hi;
  reg [7:0] xm  [0:MAXIN-1];               // 输入：流顺序 [row][col][ci]（add：每列 2*C 字节）
  reg [7:0] ym  [0:MAXOUT-1];              // 期望输出：流顺序 [y][x][ci]
  reg [7:0] got [0:MAXOUT-1];              // DUT 实采输出
  reg [7:0] lut64 [0:255];                 // sigmoid 的表（装置**自己** $readmemh 载入 +LUTFILE）
  reg [7:0] seen  [0:255];                 // sigmoid 的码点覆盖位图（索引 = 输入原始字节）

  integer C, IW, H, NIN, NINB, NCIB, NOUTPIX, NOUTB;
  integer is_maxpool, is_resize, is_add, is_sigmoid, saw_not_ready;
  integer stallb, dummy, lut_bad, lut_checked, lut_codes;
  integer i, n, t, cyc, d, extra, bad, cc, idx;

  reg clk = 1'b0;
  reg rst = 1'b1;
  reg        x_valid = 1'b0;
  reg [7:0]  x0 = 8'h0, x1 = 8'h0;

  wire [7:0]  y0, y1;
  wire        x_rdy, y_vld;
  wire [15:0] imgC_w, imgW_w;

  always #5 clk = ~clk;

`ifdef BP_TWO_IN
  // ---- 双输入档（AddUnit）：第二路 x_b + 它自己的 valid ----
  reg       xb_valid = 1'b0;
  reg [7:0] xb0 = 8'h0, xb1 = 8'h0;
  // "一拍是否被吃下" = **两路 valid 都齐** 才有资格谈消费（本单元的 ready 是两路共享的）。
  wire beat_in = x_valid && xb_valid;
  `BP_MOD dut (
    .x_a_0(x0), .x_a_1(x1), .x_a_valid(x_valid),
    .x_b_0(xb0), .x_b_1(xb1), .x_b_valid(xb_valid),
    .x_ready(x_rdy),
    .y_0(y0), .y_1(y1), .y_valid(y_vld),
    .imgC(imgC_w), .imgW(imgW_w)
    `ifdef BP_NOCLK
    `else
    , .clk(clk), .reset(rst)
    `endif
  );
`else
  wire beat_in = x_valid;
  `BP_MOD dut (
    .x_0(x0), .x_1(x1), .x_valid(x_valid), .x_ready(x_rdy),
    .y_0(y0), .y_1(y1), .y_valid(y_vld),
    .imgC(imgC_w), .imgW(imgW_w)
    // ★★ T-S1：**运行期行宽**（只有带行宽状态的 `MaxPoolUnit`/`ResizeUnit` 有这个口；
    //   `AddUnit`/`SigmoidUnit` 是零几何状态的逐点算子、网表里没有 `rowW`）
    //   ⇒ 由 `-DBP_ROW` 控制是否连它（= `+IW`，与"没有这个口"逐拍同形）。
    `ifdef BP_ROW
    , .rowW(16'(IW))
    `endif
    `ifdef BP_NOCLK
    `else
    , .clk(clk), .reset(rst)
    `endif
  );
`endif

  initial begin
    // ---- 取参数 ----
    if (!$value$plusargs("XFILE=%s", xfile)) begin $display("TB-ERROR: 缺 +XFILE="); $fatal(1, "missing XFILE"); end
    if (!$value$plusargs("YFILE=%s", yfile)) begin $display("TB-ERROR: 缺 +YFILE="); $fatal(1, "missing YFILE"); end
    if (!$value$plusargs("OP=%s", opstr))    begin $display("TB-ERROR: 缺 +OP=maxpool|resize|add|sigmoid"); $fatal(1, "missing OP"); end
    C = 0; IW = 0; H = 0;
    if (!$value$plusargs("C=%d", C))  begin $display("TB-ERROR: 缺 +C=");  $fatal(1, "missing C"); end
    if (!$value$plusargs("IW=%d", IW)) begin $display("TB-ERROR: 缺 +IW="); $fatal(1, "missing IW"); end
    if (!$value$plusargs("H=%d", H))  begin $display("TB-ERROR: 缺 +H=");  $fatal(1, "missing H"); end
    stallb = 0; dummy = $value$plusargs("STALLB=%d", stallb);

    // ---- 算子识别：$value$plusargs 把字符串写进宽寄存器，**对齐方式随实现**（iverilog 实测右对齐、
    //      高字节清零）⇒ 低 8 字节与高 8 字节两种对齐都认，免得换个仿真器就误报"不认识 +OP"。----
    op_lo = opstr[8*8-1:0];
    op_hi = opstr[8*16-1 -: 8*8];
    is_maxpool = (op_lo == "maxpool") || (op_hi == "maxpool");
    is_resize  = (op_lo == "resize")  || (op_hi == "resize");
    is_add     = (op_lo == "add")     || (op_hi == "add");
    is_sigmoid = (op_lo == "sigmoid") || (op_hi == "sigmoid");
    if (!is_maxpool && !is_resize && !is_add && !is_sigmoid) begin
      $display("TB-ERROR: +OP=%0s 不认识（只有 maxpool | resize | add | sigmoid）", opstr);
      $fatal(1, "bad OP");
    end

    // ---- 双输入互锁（两个方向都报红；否则"张冠李戴"会静默）----
`ifdef BP_TWO_IN
    if (!is_add) begin
      $display("TB-ERROR: 本装置以 -DBP_TWO_IN 编成**双输入档**（网表端口 = x_a/x_b + 两路 valid），但 +OP=%0s != add ⇒ 网表/算子张冠李戴", opstr);
      $fatal(1, "two-in netlist needs +OP=add");
    end
`else
    if (is_add) begin
      $display("TB-ERROR: +OP=add 需要 -DBP_TWO_IN 编成双输入档（AddUnit 的端口是 x_a/x_b 两路，单输入档对不上）");
      $fatal(1, "add needs -DBP_TWO_IN");
    end
`endif
    if (stallb != 0 && !is_add) begin
      $display("TB-ERROR: +STALLB=1 只对 +OP=add 有意义（单输入的单元没有第二路 valid）");
      $fatal(1, "stallb needs add");
    end

    // ---- 参数自报对账（time 0；网表是定点生成的，不符必须当场报红）----
    if (imgC_w != C || imgW_w != IW) begin
      $display("TB-ERROR: 网表自报 imgC=%0d imgW=%0d 与 +C=%0d +IW=%0d 不符（网表是定点生成的）",
               imgC_w, imgW_w, C, IW);
      $fatal(1, "self-report mismatch");
    end
    if (C != NCI || IW != NW) begin
      $display("TB-ERROR: +C=%0d +IW=%0d 与本装置的宏 NCI=%0d NW=%0d 不符", C, IW, NCI, NW);
      $fatal(1, "dim mismatch");
    end
    if (NCI != 2) begin
      $display("TB-ERROR: 本装置只仿 C=2（DUT 端口名 x_0/x_1 不可参数化），收到 NCI=%0d", NCI);
      $fatal(1, "unsupported C");
    end
    if (H < 2 || H > MAXH) begin $display("TB-ERROR: H=%0d 越界 [2,%0d]", H, MAXH); $fatal(1, "bad H"); end
    // ★ 偶数 H **只对按行对/窗口工作的两个单元**是硬要求；add/sigmoid 逐点 ⇒ 奇数 H 合法（见文件头）。
    if ((is_maxpool || is_resize) && (H % 2 != 0)) begin
      $display("TB-ERROR: H=%0d 是奇数 —— +OP=%0s 按 2 行/行对工作，H 必须偶数", H, opstr);
      $fatal(1, "odd H");
    end

    // ---- 期望的输出颗数 / 每列输入字节数（按 +OP 定；装置用它决定什么时候收工）----
    NIN = IW * H;
    if (is_maxpool)      NOUTPIX = (IW / 2) * (H / 2);
    else if (is_resize)  NOUTPIX = (2 * IW) * (2 * H);
    else                 NOUTPIX = IW * H;          // add / sigmoid：逐点，一列进 ⇒ 一列出
    NCIB = NCI;                                     // 每列输入字节数
    if (is_add) NCIB = 2 * NCI;                     // 双输入：每列 = A 的 C 个通道 + B 的 C 个通道
    NINB = NIN * NCIB;  NOUTB = NOUTPIX * NCI;
    if (NINB > MAXIN) begin
      $display("TB-ERROR: 输入 %0d 字节超过装置上限 %0d", NINB, MAXIN);
      $fatal(1, "input too big");
    end
    if (NOUTB > MAXOUT) begin
      $display("TB-ERROR: 期望输出 %0d 字节超过装置上限 %0d", NOUTB, MAXOUT);
      $fatal(1, "too big");
    end
    $display("TB-INFO: op=%0s C=%0d W=%0d H=%0d | 输入 %0d 列 x %0d 字节 = %0d 字节 | 期望输出 %0d 像素 = %0d 字节%s",
             opstr, C, IW, H, NIN, NCIB, NINB, NOUTPIX, NOUTB,
             stallb != 0 ? " | STALLB=1（B 路 valid 恒 0，只判 0 列 / 0 颗）" : "");

    for (i = 0; i < MAXIN;  i = i + 1) xm[i]  = 8'h00;
    for (i = 0; i < MAXOUT; i = i + 1) begin ym[i] = 8'h00; got[i] = 8'h00; end
    for (i = 0; i < 256; i = i + 1) begin lut64[i] = 8'h00; seen[i] = 1'b0; end
    $readmemh(xfile, xm);
    // sigmoid：装置**自己**把冻结的表载进来（+LUTFILE），后面逐字节独立对账。
    if (is_sigmoid) begin
      if (!$value$plusargs("LUTFILE=%s", lutfile)) begin
        $display("TB-ERROR: +OP=sigmoid 必须给 +LUTFILE=<gen/sigmoid_lut.hex>（装置要独立载入查表）");
        $fatal(1, "missing LUTFILE");
      end
      $readmemh(lutfile, lut64);
    end
    if (stallb == 0) $readmemh(yfile, ym);

    // ---- 复位 ----
    x_valid = 1'b0; x0 = 8'h00; x1 = 8'h00;
`ifdef BP_TWO_IN
    xb_valid = 1'b0; xb0 = 8'h00; xb1 = 8'h00;
`endif
    repeat (3) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    // ---- 喂 NIN 列（每拍一列；honor x_ready）+ 同拍采 y_valid 的输出像素 ----
    // 拍数上限 20000：本用例最多只要 (8W + 2W) x H/2 拍（Resize）这个量级，20 倍余量足够；
    // 超了说明"喂流没收敛"（多半挂了错网表 / 相位机卡死）⇒ 显式报红，而不是靠下面的超时兜底。
    // +STALLB=1 例外：它**本来就不该**收敛（B 路永远不给数）⇒ 跑满 64 拍就收工，改判"0 列 / 0 颗"。
    i = 0; n = 0; extra = 0; saw_not_ready = 0;
    lut_bad = 0; lut_checked = 0; lut_codes = 0;
    for (cyc = 0; cyc < 20000 && !(i >= NIN && n >= NOUTPIX) && !(stallb != 0 && cyc >= 64); cyc = cyc + 1) begin
      @(negedge clk);
      if (i < NIN) begin
        x_valid = 1'b1;
        x0 = xm[i*NCIB + 0];
        x1 = xm[i*NCIB + 1];
`ifdef BP_TWO_IN
        xb_valid = (stallb != 0) ? 1'b0 : 1'b1;
        xb0 = xm[i*NCIB + NCI + 0];
        xb1 = xm[i*NCIB + NCI + 1];
`endif
      end else begin
        x_valid = 1'b0;                    // 输入喂完了：只看 DUT 还剩几拍出数
        x0 = 8'h00; x1 = 8'h00;
`ifdef BP_TWO_IN
        xb_valid = 1'b0; xb0 = 8'h00; xb1 = 8'h00;
`endif
      end
      #1;                                  // 组合通路稳定（DUT 的寄存器此刻还是本拍的值）
      if (!x_rdy) saw_not_ready = 1;
      if (y_vld) begin
        if (n < NOUTPIX) begin
          got[n*NCI + 0] = y0;
          got[n*NCI + 1] = y1;
          // ---- sigmoid 的**装置侧独立对账**：不靠 +YFILE，装置自己按冻结地址约定查**它自己载入的表**。
          //      地址 = x ^ 0x80（int8 的无符号偏移）；同时统计"见到过哪些码点"（覆盖 256 才算跑满）。----
          //      ★ 这里 `i` **必须还是本拍那一列的列号**（"同拍采"口径）⇒ 自增放在本块**之后**。
          if (is_sigmoid && i < NIN) begin
            for (cc = 0; cc < NCI; cc = cc + 1) begin
              idx = xm[i*NCIB + cc] ^ 8'h80;
              if (seen[xm[i*NCIB + cc]] == 1'b0) begin
                seen[xm[i*NCIB + cc]] = 1'b1;
                lut_codes = lut_codes + 1;
              end
              if ((cc == 0 ? y0 : y1) !== lut64[idx]) lut_bad = lut_bad + 1;
              lut_checked = lut_checked + 1;
            end
          end
        end else begin
          extra = extra + 1;                // 多吐的像素（期望不该有）
        end
        n = n + 1;
      end
      if (beat_in && x_rdy) i = i + 1;      // 手握手：吃下这一列（★ 放在采 y 之后：采 y 认的是本拍列号）
    end

    // ---- 排空：再多看 8 拍，多吐的一律算错（防"输出颗数不对"被"只收前 NOUTPIX 颗"糊住）----
    for (d = 0; d < 8; d = d + 1) begin
      @(negedge clk);
      x_valid = 1'b0; x0 = 8'h00; x1 = 8'h00;
`ifdef BP_TWO_IN
      xb_valid = 1'b0; xb0 = 8'h00; xb1 = 8'h00;
`endif
      #1;
      if (!x_rdy) saw_not_ready = 1;
      if (y_vld) begin extra = extra + 1; n = n + 1; end
    end
    x_valid = 1'b0;
    @(negedge clk);

    // ---- 打印 DUT 的原始输出序列（闸门按这行逐字节对账）----
    $write("Y");
    for (t = 0; t < NOUTB; t = t + 1) $write(" %02x", got[t]);
    $write("\n");
    $display("TB-INFO: 喂入 %0d 列（期望 %0d） 采集 %0d 颗像素（期望 %0d） 多吐 %0d",
             i, NIN, n, NOUTPIX, extra);
    if (is_sigmoid)
      $display("TB-INFO: LUT-XCHK=%0d（装置自己查表对账 %0d 个字节，期望不符 0） LUT-CODES=%0d（覆盖码点，期望 256）",
               lut_bad, lut_checked, lut_codes);

    // ---- 自检 ----
    bad = 0;
    if (stallb != 0) begin
      // 单边停住：DUT 必须**一列不吃、一颗不出**（这是"消费/y_valid 同时看两路 valid"的唯一判据）
      if (i != 0) begin
        $display("TB-ERROR: +STALLB=1（x_b_valid 恒 0）但 DUT 吃下 %0d 列（期望 0）⇒ 消费条件没同时看两路 valid", i);
        bad = bad + 1;
      end
      if (n != 0) begin
        $display("TB-ERROR: +STALLB=1（x_b_valid 恒 0）但 DUT 出 %0d 颗像素（期望 0）⇒ y_valid 没同时看两路 valid", n);
        bad = bad + 1;
      end
    end else begin
      if (i < NIN || n < NOUTPIX) begin
        $display("TB-ERROR: 喂流循环 20000 拍内没收工（喂入 %0d/%0d 列，采集 %0d/%0d 像素）⇒ 多半挂了错网表或相位机卡死",
                 i, NIN, n, NOUTPIX);
        bad = bad + 1;
      end
      for (t = 0; t < NOUTB; t = t + 1)
        if (got[t] !== ym[t]) begin
          bad = bad + 1;
          if (bad <= 8)
            $display("MISMATCH byte%0d (pix=%0d ci=%0d): dut=%02x exp=%02x", t, t / NCI, t % NCI, got[t], ym[t]);
        end
      if (i != NIN) begin
        $display("TB-ERROR: DUT 只吃下 %0d 列（期望 %0d）", i, NIN); bad = bad + 1;
      end
      if (n != NOUTPIX) begin
        $display("TB-ERROR: DUT 出 %0d 颗像素（期望 %0d）", n, NOUTPIX); bad = bad + 1;
      end
      if (extra != 0) begin
        $display("TB-ERROR: DUT 多吐 %0d 颗像素（期望 0）", extra); bad = bad + 1;
      end
      // 反压特征 vs +OP（网表端口同名同宽，必须另有一条结构特征钉住"张冠李戴"）：
      if ((is_maxpool || is_add || is_sigmoid) && saw_not_ready) begin
        $display("TB-ERROR: +OP=%0s 但网表把 x_ready 拉低过 ⇒ 多半挂错了网表（该算子从不反压）", opstr);
        bad = bad + 1;
      end
      if (is_resize && !saw_not_ready) begin
        $display("TB-ERROR: +OP=resize 但网表的 x_ready 恒 1 ⇒ 多半挂错了网表（Resize 出数相位必反压）");
        bad = bad + 1;
      end
      // sigmoid 的两条独立对账：逐字节数 == 输出字节数（防"对账根本没跑"）+ 全码点覆盖。
      if (is_sigmoid) begin
        if (lut_checked != NOUTB) begin
          $display("TB-ERROR: sigmoid 的装置侧查表对账只覆盖 %0d/%0d 个字节（对账没跑满）", lut_checked, NOUTB);
          bad = bad + 1;
        end
        if (lut_bad != 0) begin
          $display("TB-ERROR: sigmoid 装置自算期望（lut[x^0x80]，表来自 +LUTFILE）与 DUT 输出差 %0d 个字节 ⇒ RTL 的表/取址与导出的表不一致", lut_bad);
          bad = bad + 1;
        end
        if (lut_codes != 256) begin
          $display("TB-ERROR: sigmoid 只跑到 %0d 个不同码点（期望 256：int8 全部码点）", lut_codes);
          bad = bad + 1;
        end
      end
    end

    if (bad == 0) begin
      $display("RESULT: PASS");
      $finish;
    end else begin
      $display("RESULT: FAIL bad=%0d", bad);
      $fatal(1, "BypassTb mismatch");
    end
  end

  // 仿真不收敛时的兜底：超时即判红（非 0 退出），避免闸门挂死。
  initial begin
    #2000000;
    $display("RESULT: FAIL timeout");
    $fatal(1, "BypassTb timeout");
  end

endmodule
`endif // BP_TILED_B（未定义 ⇒ 上面那套**列流装置**，与改动前逐字节同形）
