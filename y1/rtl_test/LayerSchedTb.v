//=============================================================================
// LayerSchedTb.v —— C3.10a `LayerSched`（gen/LayerSched.v）的**帧级**装置（纯 Verilog + AxiMemModel）。
//
// 干什么：预载激活 + 整表（描述符表在 DDR 里）+ 带外预载各切片权重 -> 给一次 `go` ->
//   调度器自己走表（每项 `DescFetch` 取 32 B -> `DescWords` 译码 -> **按 TYPE + ★A-1b `FLAGS[1:0]` 分派**：
//   conv 项交 `UnitExec`（C3.10a/A-1b：`plain 0b01` 单切片；`head 0b00` 就**向前扫链**到 `tail 0b11`，
//   把整条链**塌缩成一次 `go`**（`chainLen` = 跑长，独立入参））、旁路项 maxpool/resize/add/sigmoid 交
//   `BypassExec`（C3.10b））-> 帧末抬**一次** `frameDone` -> 转储内存，闸门拿 Python 黄金逐字节对账。
//   ★ A-1b：`middle`(0b10)/`tail`(0b11) 作为一次分派的起点（无前驱）、`head` 后面不是 middle/tail
//     （含撞上哨兵）、链长 > `L_MAX`、保留位非 0 ⇒ 都是**响亮 err + 零设备搬运**（闸门有负对照）。
//
// ★ 本装置是"IRQ 纪律"的判官（本片最吃重的判据）：
//   调度器的 `frameDone` 是**原始单拍脉冲**（交给 NpuTop 锁成保持电平）。本装置：
//     · 对 `frameDone` 的**上升沿计数** -> `IRQ_RISES`；
//     · 上升沿那一刻 `unitIndex != DESC_COUNT`（= 还有单元没跑完）计一次 `IRQ_INTRA_FRAME`
//       （"帧内中断"）；⇒ 正对照要求 `IRQ_RISES==1 && IRQ_INTRA_FRAME==0`（唯一一次上升沿在**末单元
//       done 之后**：那一刻 `unitIndex==DESC_COUNT`）；
//     · 把 `frameDone` 锁存成 `irq_latch`（模拟 NpuTop 的保持电平）-> 收尾再等 50 拍查它还举着
//       （`IRQ_HELD_AFTER_50`）。
//
// 契约（plusarg；装置不写死任何地址/几何）：
//   +MEMFILE=<file>   $readmemh 一行一个十六进制字节 —— 整片内存镜像（表 + 激活 + 背景模式），
//                     AxiMemModel 自己取；描述符表落在 +DESC_ADDR 起的连续 32 B x DESC_COUNT 上。
//   +DUMPFILE=<file>  仿真结束时回写整片镜像（闸门逐字节对账）。
//   +DESC_ADDR=<dec>  描述符表基址（32 B 对齐）。
//   +DESC_COUNT=<dec> 载荷项数（**不含**哨兵；哨兵必须落在下标 DESC_COUNT）。
//   +D0..+D7=<dec>    第 0 项描述符的 8 个 32-bit 小端字（time-0 几何/QUANT_SHIFT 对账用）。
//   +E0..+E7=<dec>    第 1 项描述符的 8 个 32-bit 小端字（同上）。
//   +F0..+F7=<dec>    第 2 项描述符（**可选**；给了 +F0= 就认它。C3.10b 的三单元链用）。
//                     不给 ⇒ HAS_F=0，本作业只按两项（C3.10a 的 conv-only 作业）对账。
//   ★A-1b +G0..+G7=<dec> 第 3 项描述符（**可选**；per-operator 编码下 B 作业有 4 个载荷项）。
//   +WGTFILE=<file>   头切片（`conv`）整层权重（每行一字节；NENTRY=C_OUT*(C_IN/GROUP)*9=576）。
//   +WGTFILE_T=<file> 尾切片（`convT`）整层权重（融合对用；不给则保持 0）。
//   ★ A-1b / C3.16：链上第 2/3 片（`conv2`/`conv3`）的权重经**同一套权重信箱**装载
//     （`wgt_sel=2/3`；改用 `+WGTFILE2=` / `+WGTFILE3=`；不给则保持 0）—— 本闸门的链都是 2 片，用不到。
//   +CTRL=<dec>       起跑控制（非 0 = 脉冲一次 `go`）。默认 1。
//   +EXPECT_ERR       可选：本次必须报 err（负对照用）。
//   ★C3.11b +SKIP_DESC_CHK 可选：**跳过** time-0 的 `chk_desc` 几何对账。只给"逐项字段规则"的负作业用
//                     （那些表故意带非法字段，几何对账不是被测对象）；**既有作业一律不给** ⇒ 默认行为
//                     逐字不变。网表自报行仍然照打、闸门照对。
//   ★C3.11b +TIMEOUT=<n> 可选：等帧末的最长拍数（默认 = `TIMEOUT` localparam，既有作业一字不变）。
//                     只给"突变控制"用：摘掉被测判据后那些作业会挂住 ⇒ 靠它快速收口成 `RESULT: FAIL`。
//
// ★ time-0 几何对账（"宽度钉死"教训）：装置把**每一项**描述符与「本网表 + 本项算子」逐项对账
//   （`chk_desc` task），不符立即 `$fatal`，绝不让"宽度/档位不符"退化成事后的大范围 MISMATCH：
//     · conv 项（0x01/0x02/0x03）：`IMG_W == 网表自报 imgW`（`Conv3x3Slice` 按展开期 WIDTH 数行）、
//       `GROUP == grp`、`QUANT_SHIFT == shift`、`IMG_W*IMG_H <= maxPix`、`IN_BYTES` 是 128 的倍数；
//     · 旁路项（0x10/0x11/0x13/0x14）：`IMG_W/IMG_H` 是**输出**几何（与 WIDTH 无关）⇒ 只查
//       `IN_BYTES` 是 32 的倍数（输入宽是否 == WIDTH 由 `BypassExec` 自己在 `go` 那一刻响亮对账）；
//     · 公共：`C_IN == C_OUT == 网表自报 imgC`。
//   ★ C3.10a 版曾要求"描述符1 的几何与描述符0 逐字段相等"，那只对**单几何的 conv 链**成立；
//     C3.10b 的多单元链每项几何不同（旁路项的 IMG_W 是输出宽）⇒ 改成上面这套**逐项**判据。
//
// ★ 结构性观察（闸门交叉对账用）：按 `arlen` 把 AR 突发分成 32 B（arlen==3，= 取表）与 128 B（arlen==15，
//   = 单元激活读），AW 同理 —— "表自身的 DMA 读开销"因此被**显式计入**（spec R4）。
//
// 时序口径与 rtl_test/UnitExecTb.v / DescTb.v 同：驱动在 negedge 摆、握手在 posedge 采、$finish 让模型转储。
//=============================================================================
`timescale 1ns/1ps

module LayerSchedTb;

  localparam integer MEMSZ   = 2621440;   // 2.5 MiB（与闸门一致）
  localparam integer TIMEOUT = 4000000;   // 等 frameDone/err 的最长拍数
  localparam integer WD_MAX  = 12000000;  // 全局看门狗
  localparam integer MAXWGT  = 4096;      // 权重条目上限（dense 8x8 = 576）★A'-2：真表宽 run 的首片
                                          //   `N = C_OUT*(C_IN/GROUP)*9` 可达 2304（run[4..11] 的 Conv_6：16×16×9）
                                          //   ⇒ 上限抬到 4096（既有作业的 NENTRY ≤ 1024，行为逐字不变）

  reg clk = 1'b0;
  reg rst = 1'b1;
  always #5 clk = ~clk;

  // ---- DUT 控制 ----
  reg         go;
  reg  [27:0] desc_addr;
  reg  [31:0] desc_count;
  // ★ C3.16：权重装载 = **一套"权重信箱"**（`wgt_sel` 选切片 / `wgt_addr` 条目下标 /
  //   `wgt_data` int8 载荷 / `wgt_we` 单拍写使能）—— 取代旧的四套口（`we`/`we_t`/`we2`/`we3`）。
  reg  [2:0]  wgt_sel;
  reg  [9:0]  wgt_addr;
  reg  [7:0]  wgt_data;
  reg         wgt_we;

  // ---- DUT 观察 ----
  wire        busy, err, frameDone;
  wire [31:0] unitIndex;
  wire [15:0] imgC, imgW, maxPix;
  wire [3:0]  grp;
  wire [7:0]  shift;
  wire [31:0] rd_bytes, wr_bytes;

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
    .rd_bytes(rd_bytes), .wr_bytes(wr_bytes),
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

  // ---- 权重向量 + 描述符字段 ----
  reg [8*256-1:0] wgtfile, wgtfile_t;
  reg [8*256-1:0] wgtfile2, wgtfile3;   // ★ A-1b：链上第 2/3 片的权重（可选）
  reg [7:0] wm [0:MAXWGT-1];
  reg [7:0] wm_t [0:MAXWGT-1];
  reg [7:0] wm2 [0:MAXWGT-1];
  reg [7:0] wm3 [0:MAXWGT-1];
  reg        has_wgt_t;
  reg        has_wgt2, has_wgt3;

  reg [31:0] d0, d1, d2, d3, d4, d5, d6, d7;   // 第 0 项描述符
  reg [31:0] e0, e1, e2, e3, e4, e5, e6, e7;   // 第 1 项描述符
  reg [31:0] f0, f1, f2, f3, f4, f5, f6, f7;   // 第 2 项描述符（可选；C3.10b 的三单元链用）
  // ★ A-1b：第 3 项描述符（可选；per-operator 编码下 B 作业是 4 载荷：plain+head+tail+旁路）
  reg [31:0] g0, g1, g2, g3, g4, g5, g6, g7;
  reg        has_g;
  reg        has_f;

  integer IMG_W, IMG_H, C_IN, C_OUT, GROUP, IN_BYTES, Q_SHIFT, NENTRY;
  integer gi;                     // ★★ A'-2：`+GEOMDUMP` 的循环下标
  integer IMG_W2, IMG_H2, C_IN2, C_OUT2, GROUP2, IN_BYTES2, Q_SHIFT2;
  integer DESC_ADDR_I, DESC_COUNT_I;

  integer i, timeout_cnt, ctrl, got_ctrl;
  integer timeout_lim;
  reg     done_seen, err_seen, expect_err;
  reg     skip_desc_chk;   // ★ C3.11b：跳过一次 time-0 几何对账（只给"故意非法"的字段规则负作业用）
  integer irq_rises, irq_intra, irq_last_idx;
  reg     irq_latch, frame_done_seen, prev_fd, rx_done;

  // ---- AXI 突发观察（按 arlen 分档：32 B = 取表；128 B = 单元激活）----
  integer ar_n32, ar_n128, ar_total, aw_n128, aw_total, b_ok;

  always @(posedge clk) begin
    if (!rst) begin
      if (axi_ar_valid && axi_ar_ready) begin
        ar_total = ar_total + 1;
        if (axi_ar_payload_len == 8'd3)       ar_n32  = ar_n32 + 1;   // 4 拍 = 32 B（取表）
        else if (axi_ar_payload_len == 8'd15) ar_n128 = ar_n128 + 1;  // 16 拍 = 128 B（激活读）
      end
      if (axi_aw_valid && axi_aw_ready) begin
        aw_total = aw_total + 1;
        if (axi_aw_payload_len == 8'd15) aw_n128 = aw_n128 + 1;
      end
      if (axi_b_valid && axi_b_ready) b_ok = b_ok + 1;
      // ---- ★ IRQ 纪律：上升沿计数 + 帧内判定 + 锁存 ----
      if (frameDone && !prev_fd) begin
        irq_rises = irq_rises + 1;
        irq_last_idx = unitIndex;
        if (unitIndex != DESC_COUNT_I) irq_intra = irq_intra + 1;   // 还有单元没跑完 ⇒ 帧内中断
      end
      if (frameDone) begin irq_latch = 1'b1; frame_done_seen = 1'b1; end
      prev_fd = frameDone;
    end
  end

  // ---- ★ 逐项描述符对账（C3.10b：多单元链里每项几何可以不同 ⇒ 不能拿"desc1 == desc0"一把扫）----
  //   · **conv 项**（0x01/0x02/0x03）：`IMG_W` 必须 == 网表自报 `imgW`（`Conv3x3Slice` 按展开期
  //     WIDTH 数行 ⇒ 宽度钉死）、`GROUP`/`QUANT_SHIFT` 也必须与网表一致、输出像素 <= `maxPix`；
  //   · **旁路项**（0x10/0x11/0x13/0x14）：`IMG_W/IMG_H` 是**输出**几何（与 WIDTH 无关），
  //     输入宽度是否等于 WIDTH 由 `BypassExec` 自己在 `go` 那一刻响亮对账 ⇒ 装置不重复判；
  //   · 公共：`C_IN == C_OUT == 网表 C`（本任务所有单元都是 8 通道）、`IN_BYTES` 32 B 对齐且 > 0；
  //     conv 项额外要求 `IN_BYTES` 是 128 的整数倍（与 C3.10a 同口径）。
  task chk_desc;
    input integer idx;
    input [31:0] w0, w1, w2, w3, w4, w5, w6, w7;
    integer t, iw, ih, ci, co, gr, ib, qs;
    begin
      t  = w0 & 32'hFF;
      iw = w1 & 32'hFFFF;  ih = w1 >> 16;
      ci = w2 & 32'hFFFF;  co = w2 >> 16;
      gr = w3 & 32'hFF;    ib = w6;  qs = w7 & 32'hFF;
      if (t == 8'h01 || t == 8'h02 || t == 8'h03) begin
        // ★★ T-S2：判据从"编译期等式 IMG_W == imgW"改成**运行期界限** IMG_W <= imgW（= W_MAX）。
        //   理由与 rtl/UnitExec.scala 的 `inWOk` 同一真源：T-S1 起 `rowW := IMG_W·s` 是**运行期**量，
        //   界线是 `1 <= rowW <= W_MAX`（= 网表自报的 `imgW`）。装置只知道 `IMG_W`（不知道 `s`），
        //   所以这里判"不超过分配上限"这一必要条；`IMG_W·s <= W_MAX` 由 RTL 在 `go` 那一刻响亮把住。
        //   `s = 1` 时两者逐字同值 ⇒ 旧口径是本条的一个特例。
        if (iw > imgW) begin
          $display("TB-ERROR: desc%0d(conv) IMG_W=%0d > 网表自报 W_MAX=imgW=%0d（行宽超出分配上限）",
                   idx, iw, imgW);
          $fatal(1, "IMG_W exceeds imgW"); end
        if (gr != grp) begin
          $display("TB-ERROR: desc%0d(conv) GROUP=%0d != 网表自报 grp=%0d", idx, gr, grp);
          $fatal(1, "GROUP vs grp mismatch"); end
        if (qs != shift) begin
          $display("TB-ERROR: desc%0d(conv) QUANT_SHIFT=%0d != 网表展开期 SHIFT=%0d", idx, qs, shift);
          $fatal(1, "Q_SHIFT vs shift mismatch"); end
        if (iw * ih > maxPix) begin
          $display("TB-ERROR: desc%0d conv IMG_W*IMG_H=%0d > 网表自报 maxPix=%0d", idx, iw * ih, maxPix);
          $fatal(1, "pixels exceed maxPix"); end
        if (ib <= 0 || (ib % 128) != 0) begin
          $display("TB-ERROR: desc%0d(conv) IN_BYTES=%0d 不是 128 的正整数倍", idx, ib);
          $fatal(1, "IN_BYTES not mult 128"); end
      end else begin
        if (ib <= 0 || (ib % 32) != 0) begin
          $display("TB-ERROR: desc%0d(bypass) IN_BYTES=%0d 不是 32 的正整数倍", idx, ib);
          $fatal(1, "IN_BYTES not mult 32"); end
      end
      if (ci != imgC || co != imgC) begin
        $display("TB-ERROR: desc%0d C_IN/C_OUT=%0d/%0d != 网表自报 imgC=%0d", idx, ci, co, imgC);
        $fatal(1, "C dim mismatch"); end
    end
  endtask

  initial begin
    // ---- 默认 ----
    go = 1'b0; desc_addr = 28'd0; desc_count = 32'd0;
    wgt_sel = 3'd0; wgt_addr = 10'd0; wgt_data = 8'd0; wgt_we = 1'b0;
    d0 = 0; d1 = 0; d2 = 0; d3 = 0; d4 = 0; d5 = 0; d6 = 0; d7 = 0;
    e0 = 0; e1 = 0; e2 = 0; e3 = 0; e4 = 0; e5 = 0; e6 = 0; e7 = 0;
    f0 = 0; f1 = 0; f2 = 0; f3 = 0; f4 = 0; f5 = 0; f6 = 0; f7 = 0;
    g0 = 0; g1 = 0; g2 = 0; g3 = 0; g4 = 0; g5 = 0; g6 = 0; g7 = 0;
    has_f = 1'b0; has_g = 1'b0;
    timeout_cnt = 0; ctrl = 1; got_ctrl = 0;
    // ★ C3.11b：`+TIMEOUT=<n>`（可选）只给"突变控制"用 —— 那些作业在摘掉被测判据后会**挂住**
    //   （永远等不到 err/frameDone），本装置要能快速收口 ⇒ 让它打出 `RESULT: FAIL timeout` 即算红。
    //   不给 ⇒ 逐字沿用 `TIMEOUT`（既有作业的等待口径**一字未变**）。
    timeout_lim = TIMEOUT;
    if ($value$plusargs("TIMEOUT=%d", timeout_lim)) begin
      if (timeout_lim < 2000) timeout_lim = 2000;
    end
    done_seen = 1'b0; err_seen = 1'b0; expect_err = 1'b0;
    skip_desc_chk = 1'b0;
    irq_rises = 0; irq_intra = 0; irq_last_idx = -1;
    irq_latch = 1'b0; frame_done_seen = 1'b0; prev_fd = 1'b0; rx_done = 1'b0;
    ar_n32 = 0; ar_n128 = 0; ar_total = 0; aw_n128 = 0; aw_total = 0; b_ok = 0;
    has_wgt_t = 1'b0;
    has_wgt2 = 1'b0; has_wgt3 = 1'b0;
    for (i = 0; i < MAXWGT; i = i + 1) wm[i] = 8'h00;
    for (i = 0; i < MAXWGT; i = i + 1) wm_t[i] = 8'h00;
    for (i = 0; i < MAXWGT; i = i + 1) wm2[i] = 8'h00;
    for (i = 0; i < MAXWGT; i = i + 1) wm3[i] = 8'h00;

    if (!$value$plusargs("DESC_ADDR=%d", DESC_ADDR_I)) begin
      $display("TB-ERROR: 缺 +DESC_ADDR="); $fatal(1, "missing DESC_ADDR"); end
    if (!$value$plusargs("DESC_COUNT=%d", DESC_COUNT_I)) begin
      $display("TB-ERROR: 缺 +DESC_COUNT="); $fatal(1, "missing DESC_COUNT"); end
    if (!$value$plusargs("D0=%d", d0)) begin $display("TB-ERROR: 缺 +D0="); $fatal(1, "missing D0"); end
    if (!$value$plusargs("D1=%d", d1)) begin $display("TB-ERROR: 缺 +D1="); $fatal(1, "missing D1"); end
    if (!$value$plusargs("D2=%d", d2)) begin $display("TB-ERROR: 缺 +D2="); $fatal(1, "missing D2"); end
    if (!$value$plusargs("D3=%d", d3)) begin $display("TB-ERROR: 缺 +D3="); $fatal(1, "missing D3"); end
    if (!$value$plusargs("D4=%d", d4)) begin $display("TB-ERROR: 缺 +D4="); $fatal(1, "missing D4"); end
    if (!$value$plusargs("D5=%d", d5)) begin $display("TB-ERROR: 缺 +D5="); $fatal(1, "missing D5"); end
    if (!$value$plusargs("D6=%d", d6)) begin $display("TB-ERROR: 缺 +D6="); $fatal(1, "missing D6"); end
    if (!$value$plusargs("D7=%d", d7)) begin $display("TB-ERROR: 缺 +D7="); $fatal(1, "missing D7"); end
    if (!$value$plusargs("E0=%d", e0)) begin $display("TB-ERROR: 缺 +E0="); $fatal(1, "missing E0"); end
    if (!$value$plusargs("E1=%d", e1)) begin $display("TB-ERROR: 缺 +E1="); $fatal(1, "missing E1"); end
    if (!$value$plusargs("E2=%d", e2)) begin $display("TB-ERROR: 缺 +E2="); $fatal(1, "missing E2"); end
    if (!$value$plusargs("E3=%d", e3)) begin $display("TB-ERROR: 缺 +E3="); $fatal(1, "missing E3"); end
    if (!$value$plusargs("E4=%d", e4)) begin $display("TB-ERROR: 缺 +E4="); $fatal(1, "missing E4"); end
    if (!$value$plusargs("E5=%d", e5)) begin $display("TB-ERROR: 缺 +E5="); $fatal(1, "missing E5"); end
    if (!$value$plusargs("E6=%d", e6)) begin $display("TB-ERROR: 缺 +E6="); $fatal(1, "missing E6"); end
    if (!$value$plusargs("E7=%d", e7)) begin $display("TB-ERROR: 缺 +E7="); $fatal(1, "missing E7"); end
    // 第 2 项描述符（可选；C3.10b 的三单元链才有）
    if ($test$plusargs("F0")) begin
      has_f = 1'b1;
      if (!$value$plusargs("F0=%d", f0)) begin $display("TB-ERROR: 缺 +F0="); $fatal(1, "missing F0"); end
      if (!$value$plusargs("F1=%d", f1)) begin $display("TB-ERROR: 缺 +F1="); $fatal(1, "missing F1"); end
      if (!$value$plusargs("F2=%d", f2)) begin $display("TB-ERROR: 缺 +F2="); $fatal(1, "missing F2"); end
      if (!$value$plusargs("F3=%d", f3)) begin $display("TB-ERROR: 缺 +F3="); $fatal(1, "missing F3"); end
      if (!$value$plusargs("F4=%d", f4)) begin $display("TB-ERROR: 缺 +F4="); $fatal(1, "missing F4"); end
      if (!$value$plusargs("F5=%d", f5)) begin $display("TB-ERROR: 缺 +F5="); $fatal(1, "missing F5"); end
      if (!$value$plusargs("F6=%d", f6)) begin $display("TB-ERROR: 缺 +F6="); $fatal(1, "missing F6"); end
      if (!$value$plusargs("F7=%d", f7)) begin $display("TB-ERROR: 缺 +F7="); $fatal(1, "missing F7"); end
    end
    // ★ A-1b：第 3 项描述符（可选；`+G0..+G7`）
    if ($test$plusargs("G0")) begin
      has_g = 1'b1;
      if (!$value$plusargs("G0=%d", g0)) begin $display("TB-ERROR: 缺 +G0="); $fatal(1, "missing G0"); end
      if (!$value$plusargs("G1=%d", g1)) begin $display("TB-ERROR: 缺 +G1="); $fatal(1, "missing G1"); end
      if (!$value$plusargs("G2=%d", g2)) begin $display("TB-ERROR: 缺 +G2="); $fatal(1, "missing G2"); end
      if (!$value$plusargs("G3=%d", g3)) begin $display("TB-ERROR: 缺 +G3="); $fatal(1, "missing G3"); end
      if (!$value$plusargs("G4=%d", g4)) begin $display("TB-ERROR: 缺 +G4="); $fatal(1, "missing G4"); end
      if (!$value$plusargs("G5=%d", g5)) begin $display("TB-ERROR: 缺 +G5="); $fatal(1, "missing G5"); end
      if (!$value$plusargs("G6=%d", g6)) begin $display("TB-ERROR: 缺 +G6="); $fatal(1, "missing G6"); end
      if (!$value$plusargs("G7=%d", g7)) begin $display("TB-ERROR: 缺 +G7="); $fatal(1, "missing G7"); end
    end
    if (!$value$plusargs("WGTFILE=%s", wgtfile)) begin
      $display("TB-ERROR: 缺 +WGTFILE="); $fatal(1, "missing WGTFILE"); end
    if ($test$plusargs("EXPECT_ERR")) expect_err = 1'b1;
    // ★ C3.11b：`+SKIP_DESC_CHK` —— 跳过 time-0 的**几何**对账（`chk_desc`）。
    //   只给"逐项字段规则"的负作业用：那些表**故意**带一个非法字段（`IN_BYTES=0` 之类），
    //   而 `chk_desc` 本来就是"几何/档位对账"（不是被测对象）⇒ 让它先 $fatal 会把被测的
    //   RTL 判据挡在门外。**正对照与所有既有作业一律不给这个开关**（默认 0 ⇒ 行为逐字不变）。
    //   注意：网表自报行（RTL_IMGW/RTL_IMGC/RTL_GRP/RTL_SHIFT/RTL_MAXPIX）仍然照打、闸门照对。
    if ($test$plusargs("SKIP_DESC_CHK")) skip_desc_chk = 1'b1;
    desc_addr  = DESC_ADDR_I[27:0];
    desc_count = DESC_COUNT_I;

    // ---- 从描述符解字段（与 desc_table 的位打包逐字段一致）----
    IMG_W  = d1[15:0];  IMG_H  = d1[31:16];  C_IN  = d2[15:0];  C_OUT  = d2[31:16];
    GROUP  = d3[7:0];   IN_BYTES = d6;       Q_SHIFT = d7[7:0];
    IMG_W2 = e1[15:0];  IMG_H2 = e1[31:16];  C_IN2 = e2[15:0];  C_OUT2 = e2[31:16];
    GROUP2 = e3[7:0];   IN_BYTES2 = e6;      Q_SHIFT2 = e7[7:0];

    $display("TB SCHED: DESC_ADDR=%0d DESC_COUNT=%0d EXPECT_ERR=%0d HAS_F=%0d HAS_G=%0d",
             DESC_ADDR_I, DESC_COUNT_I, expect_err, has_f, has_g);
    $display("TB SCHED: D0 TYPE=0x%02x FLAGS=0x%02x SRC=%0d DST=%0d IN_BYTES=%0d",
             d0[7:0], d0[15:8], d4, d5, IN_BYTES);
    $display("TB SCHED: E0 TYPE=0x%02x FLAGS=0x%02x SRC=%0d DST=%0d IN_BYTES=%0d",
             e0[7:0], e0[15:8], e4, e5, IN_BYTES2);
    if (has_f) begin
      $display("TB SCHED: F0 TYPE=0x%02x FLAGS=0x%02x SRC=%0d DST=%0d IN_BYTES=%0d",
               f0[7:0], f0[15:8], f4, f5, f6);
    end
    if (has_g) begin
      $display("TB SCHED: G0 TYPE=0x%02x FLAGS=0x%02x SRC=%0d DST=%0d IN_BYTES=%0d",
               g0[7:0], g0[15:8], g4, g5, g6);
    end

    // ---- ★ time-0 几何对账：**逐项**描述符必须与「本网表 + 本项算子」自洽（宽度钉死）----
    //   ★ C3.10a 版曾要求"描述符1 的几何与描述符0 逐字段相等" —— 那条**只对单几何的 conv 链成立**
    //     （C3.10b 的多单元链每项几何不同：conv 项 IMG_W 必须 == 网表 WIDTH，旁路项 IMG_W 是**输出**
    //     几何、与 WIDTH 无关）。所以改成**逐项**判据（对 conv 项仍保留"IMG_W == 网表 WIDTH"这条钉死）。
    $display("TB SCHED: RTL_IMGW=%0d RTL_IMGC=%0d RTL_GRP=%0d RTL_SHIFT=%0d RTL_MAXPIX=%0d",
             imgW, imgC, grp, shift, maxPix);
    if (!skip_desc_chk) begin
      chk_desc(0, d0, d1, d2, d3, d4, d5, d6, d7);
      chk_desc(1, e0, e1, e2, e3, e4, e5, e6, e7);
      if (has_f) chk_desc(2, f0, f1, f2, f3, f4, f5, f6, f7);
      if (has_g) chk_desc(3, g0, g1, g2, g3, g4, g5, g6, g7);
    end else begin
      $display("TB SCHED: SKIP_DESC_CHK=1（本作业的表**故意非法** ⇒ 跳过 time-0 几何对账；字段规则由 DUT 判）");
    end

    NENTRY = C_OUT * (C_IN / GROUP) * 9;
    if (NENTRY < 1 || NENTRY > MAXWGT) begin
      $display("TB-ERROR: NENTRY=%0d 越界", NENTRY); $fatal(1, "bad NENTRY"); end
    $readmemh(wgtfile, wm, 0, NENTRY - 1);
    if ($value$plusargs("WGTFILE_T=%s", wgtfile_t)) begin
      has_wgt_t = 1'b1;
      $readmemh(wgtfile_t, wm_t, 0, NENTRY - 1);
    end
    // ★ A-1b：链上第 2/3 片的权重（可选；本闸门的链都是 2 片 ⇒ 不给 ⇒ 恒 0）
    if ($value$plusargs("WGTFILE2=%s", wgtfile2)) begin
      has_wgt2 = 1'b1;
      $readmemh(wgtfile2, wm2, 0, NENTRY - 1);
    end
    if ($value$plusargs("WGTFILE3=%s", wgtfile3)) begin
      has_wgt3 = 1'b1;
      $readmemh(wgtfile3, wm3, 0, NENTRY - 1);
    end
    $display("TB SCHED: NENTRY=%0d HAS_WGT_T=%0d HAS_WGT2=%0d HAS_WGT3=%0d", NENTRY, has_wgt_t, has_wgt2, has_wgt3);

    // ---- 复位 ----
    repeat (4) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    // ---- 带外预载各切片权重（★ C3.16：**一套权重信箱**；`wgt_sel` 选切片，一拍一字节）----
    //   切片 0（`conv`）：`+WGTFILE=` 的向量落这里（与旧 `we/waddr/wdin` 那条通路逐拍同形）。
    wgt_sel = 3'd0;
    for (i = 0; i < NENTRY; i = i + 1) begin
      @(negedge clk); wgt_we = 1'b1; wgt_addr = i[9:0]; wgt_data = wm[i];
    end
    @(negedge clk); wgt_we = 1'b0; wgt_addr = 10'd0; wgt_data = 8'h00;
    //   切片 1（`convT` = 融合对的尾）：`+WGTFILE_T=`
    if (has_wgt_t) begin
      wgt_sel = 3'd1;
      for (i = 0; i < NENTRY; i = i + 1) begin
        @(negedge clk); wgt_we = 1'b1; wgt_addr = i[9:0]; wgt_data = wm_t[i];
      end
      @(negedge clk); wgt_we = 1'b0; wgt_addr = 10'd0; wgt_data = 8'h00;
    end
    // ★ A-1b：链上第 2/3 片（切片 2/3）；只在给了 `+WGTFILE2/3=` 时才跑
    if (has_wgt2) begin
      wgt_sel = 3'd2;
      for (i = 0; i < NENTRY; i = i + 1) begin
        @(negedge clk); wgt_we = 1'b1; wgt_addr = i[9:0]; wgt_data = wm2[i];
      end
      @(negedge clk); wgt_we = 1'b0; wgt_addr = 10'd0; wgt_data = 8'h00;
    end
    if (has_wgt3) begin
      wgt_sel = 3'd3;
      for (i = 0; i < NENTRY; i = i + 1) begin
        @(negedge clk); wgt_we = 1'b1; wgt_addr = i[9:0]; wgt_data = wm3[i];
      end
      @(negedge clk); wgt_we = 1'b0; wgt_addr = 10'd0; wgt_data = 8'h00;
    end
    wgt_sel = 3'd0;

    // ---- 起跑：一次 go 脉冲 ----
    ctrl = 1; got_ctrl = $value$plusargs("CTRL=%d", ctrl);
    if (got_ctrl && ctrl == 0) begin $display("TB-ERROR: +CTRL=0 本闸门不用"); $fatal(1, "CTRL=0"); end
    repeat (2) @(negedge clk);
    @(negedge clk); go = 1'b1;
    @(negedge clk); go = 1'b0;

    // ---- 等"真正的帧末"（frameDone 且 unitIndex == DESC_COUNT）或 err（带超时）----
    //   ★ 刻意**不是**"见到第一个 frameDone 就走"：负对照 A（网表突变让 frameDone 每单元都抬）下，
    //     装置要**跑完整帧**才能把帧内的那些多余上升沿都数进来（IRQ_INTRA_FRAME 才是真的 > 0）。
    rx_done = 1'b0;
    while (!rx_done) begin
      @(posedge clk);
      if (err) begin
        err_seen = 1'b1; rx_done = 1'b1;
      end else if (frameDone && (unitIndex == DESC_COUNT_I)) begin
        frame_done_seen = 1'b1; done_seen = 1'b1; rx_done = 1'b1;
      end else begin
        timeout_cnt = timeout_cnt + 1;
        if (timeout_cnt > timeout_lim) begin
          $display("RESULT: FAIL timeout(等帧末 frameDone/err 超 %0d 拍)", timeout_lim);
          $fatal(1, "LayerSchedTb timeout");
        end
      end
    end
    repeat (4) @(negedge clk);

    // ---- IRQ 保持电平检查：锁存后再等 50 拍 ----
    for (i = 0; i < 50; i = i + 1) @(posedge clk);
    $display("IRQ_RISES=%0d", irq_rises);
    $display("IRQ_INTRA_FRAME=%0d", irq_intra);
    $display("IRQ_LAST_UNITIDX=%0d", irq_last_idx);
    $display("IRQ_AT_FRAME_END=%0d", (irq_rises == 1 && irq_intra == 0) ? 1 : 0);
    $display("IRQ_HELD_AFTER_50=%0d", irq_latch);
    $display("UNIT_INDEX_FINAL=%0d", unitIndex);
    $display("DONE_SEEN=%0d ERR_SEEN=%0d BUSY=%0d", done_seen, err_seen, busy);
    $display("AR_BURSTS n32=%0d n128=%0d total=%0d", ar_n32, ar_n128, ar_total);
    $display("AW_BURSTS n128=%0d total=%0d B_OK=%0d", aw_n128, aw_total, b_ok);
    $display("RD_BYTES=%0d WR_BYTES=%0d", rd_bytes, wr_bytes);

    // =====================================================================================
    // ★★ A'-2（`+GEOMDUMP` 可选）：**逐片几何 / 逐成员段长基址 / 帧级推进** 的白盒回读。
    //   手法 = 纯**层级引用**（与 `UnitExecWideTb` 的 `+DUMPW`/`+DUMPB` 同一套：零面积、不进网表）。
    //   打印三组：
    //     ① `TB GEOM SLOT=k ...`  = `LayerSched` 的**逐片几何锁存**（来自运表时逐条取回的描述符）；
    //     ② `TB GEOM UE_SLOT=k ...` / `TB GEOM UE_SEG=k LEN=.. BASE=..` = `UnitExec` **收到并锁存**的逐片几何
    //        与它片上推导的段长/基址；
    //     ③ `TB GEOM SCHED ADVP=.. PTR=.. UE_END=.. GATE=..` = 帧级推进量、帧指针、段末、几何门失败码。
    //   `+GEOMDUMP` 不给 ⇒ 本块一行不打（既有各作业 stdout 逐字节不变）。
    // =====================================================================================
    if ($test$plusargs("GEOMDUMP")) begin
      for (gi = 0; gi < 8; gi = gi + 1) begin
        case (gi)
          0: $display("TB GEOM SLOT=0 CIN=%0d COUT=%0d GRP=%0d QSH=%0d LID=%0d DW=%0d X1=%0d", dut.chainCinR_0, dut.chainCoutR_0, dut.chainGrpR_0, dut.chainQshR_0, dut.chainLidR_0, dut.chainDwR_0, dut.chainX1R_0);
          1: $display("TB GEOM SLOT=1 CIN=%0d COUT=%0d GRP=%0d QSH=%0d LID=%0d DW=%0d X1=%0d", dut.chainCinR_1, dut.chainCoutR_1, dut.chainGrpR_1, dut.chainQshR_1, dut.chainLidR_1, dut.chainDwR_1, dut.chainX1R_1);
          2: $display("TB GEOM SLOT=2 CIN=%0d COUT=%0d GRP=%0d QSH=%0d LID=%0d DW=%0d X1=%0d", dut.chainCinR_2, dut.chainCoutR_2, dut.chainGrpR_2, dut.chainQshR_2, dut.chainLidR_2, dut.chainDwR_2, dut.chainX1R_2);
          3: $display("TB GEOM SLOT=3 CIN=%0d COUT=%0d GRP=%0d QSH=%0d LID=%0d DW=%0d X1=%0d", dut.chainCinR_3, dut.chainCoutR_3, dut.chainGrpR_3, dut.chainQshR_3, dut.chainLidR_3, dut.chainDwR_3, dut.chainX1R_3);
          4: $display("TB GEOM SLOT=4 CIN=%0d COUT=%0d GRP=%0d QSH=%0d LID=%0d DW=%0d X1=%0d", dut.chainCinR_4, dut.chainCoutR_4, dut.chainGrpR_4, dut.chainQshR_4, dut.chainLidR_4, dut.chainDwR_4, dut.chainX1R_4);
          5: $display("TB GEOM SLOT=5 CIN=%0d COUT=%0d GRP=%0d QSH=%0d LID=%0d DW=%0d X1=%0d", dut.chainCinR_5, dut.chainCoutR_5, dut.chainGrpR_5, dut.chainQshR_5, dut.chainLidR_5, dut.chainDwR_5, dut.chainX1R_5);
          6: $display("TB GEOM SLOT=6 CIN=%0d COUT=%0d GRP=%0d QSH=%0d LID=%0d DW=%0d X1=%0d", dut.chainCinR_6, dut.chainCoutR_6, dut.chainGrpR_6, dut.chainQshR_6, dut.chainLidR_6, dut.chainDwR_6, dut.chainX1R_6);
          7: $display("TB GEOM SLOT=7 CIN=%0d COUT=%0d GRP=%0d QSH=%0d LID=%0d DW=%0d X1=%0d", dut.chainCinR_7, dut.chainCoutR_7, dut.chainGrpR_7, dut.chainQshR_7, dut.chainLidR_7, dut.chainDwR_7, dut.chainX1R_7);
        endcase
      end
      for (gi = 0; gi < 8; gi = gi + 1) begin
        case (gi)
          0: $display("TB GEOM UE_SLOT=0 CIN=%0d COUT=%0d GRP=%0d QSH=%0d LID=%0d DW=%0d X1=%0d", dut.unitExec_1.chainCinR_0, dut.unitExec_1.chainCoutR_0, dut.unitExec_1.chainGrpR_0, dut.unitExec_1.chainQshR_0, dut.unitExec_1.chainLidR_0, dut.unitExec_1.chainDwR_0, dut.unitExec_1.chainX1R_0);
          1: $display("TB GEOM UE_SLOT=1 CIN=%0d COUT=%0d GRP=%0d QSH=%0d LID=%0d DW=%0d X1=%0d", dut.unitExec_1.chainCinR_1, dut.unitExec_1.chainCoutR_1, dut.unitExec_1.chainGrpR_1, dut.unitExec_1.chainQshR_1, dut.unitExec_1.chainLidR_1, dut.unitExec_1.chainDwR_1, dut.unitExec_1.chainX1R_1);
          2: $display("TB GEOM UE_SLOT=2 CIN=%0d COUT=%0d GRP=%0d QSH=%0d LID=%0d DW=%0d X1=%0d", dut.unitExec_1.chainCinR_2, dut.unitExec_1.chainCoutR_2, dut.unitExec_1.chainGrpR_2, dut.unitExec_1.chainQshR_2, dut.unitExec_1.chainLidR_2, dut.unitExec_1.chainDwR_2, dut.unitExec_1.chainX1R_2);
          3: $display("TB GEOM UE_SLOT=3 CIN=%0d COUT=%0d GRP=%0d QSH=%0d LID=%0d DW=%0d X1=%0d", dut.unitExec_1.chainCinR_3, dut.unitExec_1.chainCoutR_3, dut.unitExec_1.chainGrpR_3, dut.unitExec_1.chainQshR_3, dut.unitExec_1.chainLidR_3, dut.unitExec_1.chainDwR_3, dut.unitExec_1.chainX1R_3);
          4: $display("TB GEOM UE_SLOT=4 CIN=%0d COUT=%0d GRP=%0d QSH=%0d LID=%0d DW=%0d X1=%0d", dut.unitExec_1.chainCinR_4, dut.unitExec_1.chainCoutR_4, dut.unitExec_1.chainGrpR_4, dut.unitExec_1.chainQshR_4, dut.unitExec_1.chainLidR_4, dut.unitExec_1.chainDwR_4, dut.unitExec_1.chainX1R_4);
          5: $display("TB GEOM UE_SLOT=5 CIN=%0d COUT=%0d GRP=%0d QSH=%0d LID=%0d DW=%0d X1=%0d", dut.unitExec_1.chainCinR_5, dut.unitExec_1.chainCoutR_5, dut.unitExec_1.chainGrpR_5, dut.unitExec_1.chainQshR_5, dut.unitExec_1.chainLidR_5, dut.unitExec_1.chainDwR_5, dut.unitExec_1.chainX1R_5);
          6: $display("TB GEOM UE_SLOT=6 CIN=%0d COUT=%0d GRP=%0d QSH=%0d LID=%0d DW=%0d X1=%0d", dut.unitExec_1.chainCinR_6, dut.unitExec_1.chainCoutR_6, dut.unitExec_1.chainGrpR_6, dut.unitExec_1.chainQshR_6, dut.unitExec_1.chainLidR_6, dut.unitExec_1.chainDwR_6, dut.unitExec_1.chainX1R_6);
          7: $display("TB GEOM UE_SLOT=7 CIN=%0d COUT=%0d GRP=%0d QSH=%0d LID=%0d DW=%0d X1=%0d", dut.unitExec_1.chainCinR_7, dut.unitExec_1.chainCoutR_7, dut.unitExec_1.chainGrpR_7, dut.unitExec_1.chainQshR_7, dut.unitExec_1.chainLidR_7, dut.unitExec_1.chainDwR_7, dut.unitExec_1.chainX1R_7);
        endcase
      end
      for (gi = 0; gi < 8; gi = gi + 1) begin
        case (gi)
          0: $display("TB GEOM UE_SEG=0 LEN=%0d BASE=%0d", dut.unitExec_1.chainSegLenR_0, dut.unitExec_1.chainSegBaseR_0);
          1: $display("TB GEOM UE_SEG=1 LEN=%0d BASE=%0d", dut.unitExec_1.chainSegLenR_1, dut.unitExec_1.chainSegBaseR_1);
          2: $display("TB GEOM UE_SEG=2 LEN=%0d BASE=%0d", dut.unitExec_1.chainSegLenR_2, dut.unitExec_1.chainSegBaseR_2);
          3: $display("TB GEOM UE_SEG=3 LEN=%0d BASE=%0d", dut.unitExec_1.chainSegLenR_3, dut.unitExec_1.chainSegBaseR_3);
          4: $display("TB GEOM UE_SEG=4 LEN=%0d BASE=%0d", dut.unitExec_1.chainSegLenR_4, dut.unitExec_1.chainSegBaseR_4);
          5: $display("TB GEOM UE_SEG=5 LEN=%0d BASE=%0d", dut.unitExec_1.chainSegLenR_5, dut.unitExec_1.chainSegBaseR_5);
          6: $display("TB GEOM UE_SEG=6 LEN=%0d BASE=%0d", dut.unitExec_1.chainSegLenR_6, dut.unitExec_1.chainSegBaseR_6);
          7: $display("TB GEOM UE_SEG=7 LEN=%0d BASE=%0d", dut.unitExec_1.chainSegLenR_7, dut.unitExec_1.chainSegBaseR_7);
        endcase
      end
      $display("TB GEOM SCHED ADVP=%0d PTR=%0d UE_END=%0d GATE=%0d",
               dut.nWgtAdvR, dut.wgtPtrR, dut.unitExec_1.chainSegEndR, dut.unitExec_1.chainGateFailR);
    end
    
    // ---- 判定 ----
    if (expect_err) begin
      if (err_seen && !frame_done_seen && irq_rises == 0) begin
        $display("RESULT: PASS");
        $finish;
      end else begin
        $display("RESULT: FAIL 期待 err 且无 frameDone，实际 ERR=%0d FRAMEDONE=%0d IRQ_RISES=%0d",
                 err_seen, frame_done_seen, irq_rises);
        $fatal(1, "LayerSchedTb expected err");
      end
    end else begin
      if (frame_done_seen && !err_seen && unitIndex == DESC_COUNT_I &&
          irq_rises == 1 && irq_intra == 0 && irq_latch == 1'b1) begin
        $display("RESULT: PASS");
        $finish;
      end else begin
        $display("RESULT: FAIL FRAMEDONE=%0d ERR=%0d UNIT_INDEX=%0d(期望 %0d) IRQ_RISES=%0d IRQ_INTRA=%0d IRQ_HELD=%0d",
                 frame_done_seen, err_seen, unitIndex, DESC_COUNT_I, irq_rises, irq_intra, irq_latch);
        $fatal(1, "LayerSchedTb failed");
      end
    end
  end

  // 兜底：仿真不收敛时也报红退出。
  integer wd;
  initial begin
    for (wd = 0; wd < WD_MAX; wd = wd + 1) @(posedge clk);
    $display("RESULT: FAIL timeout(global watchdog %0d cycles)", WD_MAX);
    $fatal(1, "LayerSchedTb global timeout");
  end

endmodule
