// DescTb.v —— y1 C3.4 的装置：`DescFetch`（gen/DescFetch.v，含内部 DdrMaster）取一个 32 B 描述符。
// 纯 Verilog（iverilog -g2012）。
//
// 契约（与 rtl/DescFetch.scala 头部那几节逐条对应）：
//   +MEMFILE=<file>    $readmemh 一行一个十六进制字节 —— **整张描述符表**（由 desc_table.py
//                      --emit-hex 落盘）预载在 +DESC_ADDR 起的连续 32 B x N 上（模型自己取这份文件）。
//   +DESC_ADDR=<dec>   描述符地址（**十进制**；必须 32 B 对齐 —— 不对齐时 DUT 必须报 err）。
//                      装置**不替 DUT 校验**（非对齐也照喂，由 DUT 的入参校验去发现）。
//   +DUMPFILE=<file>   （可选）转给 AxiMemModel，仿真结束时回写整片镜像。
//   +EXPECT_ERR        断言"本次必须 err 且**一笔 AR 都没有、一个字都没收到**"。
//   +REFETCH=<dec>     （可选）**再取表作业**：第一次取表**彻底**完成（`busy` 首次落 0）后，再发**第二**个
//                      `go`（指向这个地址；必须与 +DESC_ADDR **不同**）⇒ **一笔仿真内走两次取表**，
//                      把"重入守卫 / 新 `go` 清 `validR` / DONE→IDLE 再武装"全部走一遍。装置自己查：
//                      ① `words_valid` 先落 0 再起（新 `go` 确实清了 `validR`）；② 第二项的 8 个字
//                      由第二段 `R2WORDS` 行打出（闸门对第二项的黄金期望逐字对账）；③ `AR_COUNT==2`
//                      且 `RD_BEATS==8`（两笔各一笔 32 B = 4 拍）；④ `busy` 收尾回 0。
//                      **时序口径（I2 判据的命门）**：第二个 `go` 必须落在 `busy` **首次落 0 的那一拍**
//                      （**同拍**），**不许**先空等若干 idle 拍。那正是 I1 修的死区：`busyR` 在 DONE 落 0、
//                      比内部 `DdrMaster` 回 IDLE 早一拍；若 `io.busy` 只出 `busyR`，这一拍上 IDLE 态的
//                      `io.go && !ddrMaster.io.busy` 守卫仍为假 ⇒ 本拍脉冲被**静默吞掉**（`go` 是单拍脉冲、
//                      无重试路径）⇒ 第二笔取表永不发生。于是回退 I1 后本作业**必然**发火（超时 ⇒
//                      `RESULT: FAIL` ⇒ `$fatal` ⇒ vvp 非零 ⇒ 闸门红），而不是"恒绿"。
//
// 装置做四件事（全走 DUT 的真端口，不 force、不 poke 内部寄存器）：
//   ① 复位后给 `go` **一拍脉冲**（descAddr 与 go 同拍有效），等 `words_valid` 或 `err`
//      （拍数超时 + 全局看门狗 ⇒ 挂死也报红）；
//   ② 打印 8 个字（`WORDS W0=... W7=...`）与 DescDefs 译出的 17 个字段（`FIELDS ...`）——
//      装置只给**事实**，判据（与 desc_table.py 的期望逐字/逐字段对账）在闸门里做；
//   ③ **结构性断言**（DescFetch = 纯 RD 主口，全部按运行期计数执行）：
//        · `AR_COUNT==1`：一个描述符**恰好一笔** AR（不许拆分/重发）；
//        · `AR_ADDR==DESC_ADDR` 且 `AR_BEATS==4`（`arlen==3`）：**一笔 32 B = 4 拍**，
//          地址就是给定的 descAddr（这两条一起钉住"从哪儿取、取多少"）；
//        · `RD_BEATS==4`：读回**恰好 4 拍** 8 字节；
//        · `WRITE_CHAN_BAD==0`：awvalid/wvalid/bready **一拍都不许举**（RD 模式结构上到不了写相位）；
//        · `WORDS_VALID==1 && ERR==0`（正向）/ `WORDS_VALID==0 && ERR==1 && AR_COUNT==0`（负对照）。
//   ④ 收尾打印计数与**唯一的一行** `RESULT: PASS|FAIL`；FAIL 时 $fatal ⇒ vvp 非零退出。
//
// ★ 与 rtl_test/DdrStreamTb.v 同口径：驱动在 negedge、握手判据在 posedge 采样，避免同沿竞争。
`timescale 1ns/1ps

module DescTb;

  localparam integer MEMSZ   = 8192;      // 8 KiB 建模内存（闸门里的 MEMSZ 必须一致）
  localparam integer TIMEOUT = 20000;     // 等 words_valid/err 的最长时钟拍数
  localparam integer WD_MAX  = 400000;    // 全局看门狗（拍）

  reg clk   = 1'b0;
  reg reset = 1'b1;
  always #5 clk = ~clk;

  // ---- DUT 控制 ----
  reg         go;
  reg  [27:0] desc_addr;

  // ---- DUT 观察（8 个字 + 17 个译码字段 + 状态）----
  wire [31:0] words_0, words_1, words_2, words_3, words_4, words_5, words_6, words_7;
  wire        words_valid, busy, err;
  wire [7:0]  d_tpe, d_flags, d_group, d_qshift, d_layer;
  wire [15:0] d_img_w, d_img_h, d_c_in, d_c_out;
  wire [3:0]  d_stride, d_pad;
  wire [31:0] d_src_a, d_dst_a, d_in_bytes;
  wire        d_sentinel, d_head, d_tail;

  // ---- AXI 连线（DUT 主口 <-> AxiMemModel 从口；一根线两端）----
  wire        ddr_aw_valid, ddr_aw_ready;
  wire [27:0] ddr_aw_payload_addr;
  wire [3:0]  ddr_aw_payload_id;
  wire [7:0]  ddr_aw_payload_len;
  wire [2:0]  ddr_aw_payload_size;
  wire [1:0]  ddr_aw_payload_burst;
  wire [3:0]  ddr_aw_payload_cache;
  wire [2:0]  ddr_aw_payload_prot;

  wire        ddr_w_valid, ddr_w_ready;
  wire [63:0] ddr_w_payload_data;
  wire [7:0]  ddr_w_payload_strb;
  wire        ddr_w_payload_last;

  wire        ddr_b_valid, ddr_b_ready;
  wire [3:0]  ddr_b_payload_id;
  wire [1:0]  ddr_b_payload_resp;

  wire        ddr_ar_valid, ddr_ar_ready;
  wire [27:0] ddr_ar_payload_addr;
  wire [3:0]  ddr_ar_payload_id;
  wire [7:0]  ddr_ar_payload_len;
  wire [2:0]  ddr_ar_payload_size;
  wire [1:0]  ddr_ar_payload_burst;
  wire [3:0]  ddr_ar_payload_cache;
  wire [2:0]  ddr_ar_payload_prot;

  wire        ddr_r_valid, ddr_r_ready;
  wire [63:0] ddr_r_payload_data;
  wire [3:0]  ddr_r_payload_id;
  wire [1:0]  ddr_r_payload_resp;
  wire        ddr_r_payload_last;

  // ---- 被测取表器 ----
  DescFetch dut (
    .go(go), .descAddr(desc_addr),
    .words_0(words_0), .words_1(words_1), .words_2(words_2), .words_3(words_3),
    .words_4(words_4), .words_5(words_5), .words_6(words_6), .words_7(words_7),
    .words_valid(words_valid), .busy(busy), .err(err),
    .tpe(d_tpe), .flags(d_flags), .imgW(d_img_w), .imgH(d_img_h),
    .cIn(d_c_in), .cOut(d_c_out), .group_1(d_group), .stride(d_stride), .pad(d_pad),
    .srcA(d_src_a), .dstA(d_dst_a), .inBytes(d_in_bytes),
    .qShift(d_qshift), .layerId(d_layer), .isSentinel(d_sentinel), .head(d_head), .tail(d_tail),
    .ddr_aw_valid(ddr_aw_valid), .ddr_aw_ready(ddr_aw_ready),
    .ddr_aw_payload_addr(ddr_aw_payload_addr), .ddr_aw_payload_id(ddr_aw_payload_id),
    .ddr_aw_payload_len(ddr_aw_payload_len), .ddr_aw_payload_size(ddr_aw_payload_size),
    .ddr_aw_payload_burst(ddr_aw_payload_burst), .ddr_aw_payload_cache(ddr_aw_payload_cache),
    .ddr_aw_payload_prot(ddr_aw_payload_prot),
    .ddr_w_valid(ddr_w_valid), .ddr_w_ready(ddr_w_ready),
    .ddr_w_payload_data(ddr_w_payload_data), .ddr_w_payload_strb(ddr_w_payload_strb),
    .ddr_w_payload_last(ddr_w_payload_last),
    .ddr_b_valid(ddr_b_valid), .ddr_b_ready(ddr_b_ready),
    .ddr_b_payload_id(ddr_b_payload_id), .ddr_b_payload_resp(ddr_b_payload_resp),
    .ddr_ar_valid(ddr_ar_valid), .ddr_ar_ready(ddr_ar_ready),
    .ddr_ar_payload_addr(ddr_ar_payload_addr), .ddr_ar_payload_id(ddr_ar_payload_id),
    .ddr_ar_payload_len(ddr_ar_payload_len), .ddr_ar_payload_size(ddr_ar_payload_size),
    .ddr_ar_payload_burst(ddr_ar_payload_burst), .ddr_ar_payload_cache(ddr_ar_payload_cache),
    .ddr_ar_payload_prot(ddr_ar_payload_prot),
    .ddr_r_valid(ddr_r_valid), .ddr_r_ready(ddr_r_ready),
    .ddr_r_payload_data(ddr_r_payload_data), .ddr_r_payload_id(ddr_r_payload_id),
    .ddr_r_payload_resp(ddr_r_payload_resp), .ddr_r_payload_last(ddr_r_payload_last),
    .clk(clk), .reset(reset)
  );

  // ---- 内存模型（预载/导出/统计都在模型里，plusarg 由它自己取）----
  AxiMemModel #(.MEMSZ(MEMSZ), .ADDR_W(28)) mem0 (
    .clk(clk), .reset(reset),
    .axi_aw_valid(ddr_aw_valid), .axi_aw_ready(ddr_aw_ready),
    .axi_aw_payload_addr(ddr_aw_payload_addr), .axi_aw_payload_id(ddr_aw_payload_id),
    .axi_aw_payload_len(ddr_aw_payload_len), .axi_aw_payload_size(ddr_aw_payload_size),
    .axi_aw_payload_burst(ddr_aw_payload_burst), .axi_aw_payload_cache(ddr_aw_payload_cache),
    .axi_aw_payload_prot(ddr_aw_payload_prot),
    .axi_w_valid(ddr_w_valid), .axi_w_ready(ddr_w_ready),
    .axi_w_payload_data(ddr_w_payload_data), .axi_w_payload_strb(ddr_w_payload_strb),
    .axi_w_payload_last(ddr_w_payload_last),
    .axi_b_valid(ddr_b_valid), .axi_b_ready(ddr_b_ready),
    .axi_b_payload_id(ddr_b_payload_id), .axi_b_payload_resp(ddr_b_payload_resp),
    .axi_ar_valid(ddr_ar_valid), .axi_ar_ready(ddr_ar_ready),
    .axi_ar_payload_addr(ddr_ar_payload_addr), .axi_ar_payload_id(ddr_ar_payload_id),
    .axi_ar_payload_len(ddr_ar_payload_len), .axi_ar_payload_size(ddr_ar_payload_size),
    .axi_ar_payload_burst(ddr_ar_payload_burst), .axi_ar_payload_cache(ddr_ar_payload_cache),
    .axi_ar_payload_prot(ddr_ar_payload_prot),
    .axi_r_valid(ddr_r_valid), .axi_r_ready(ddr_r_ready),
    .axi_r_payload_data(ddr_r_payload_data), .axi_r_payload_id(ddr_r_payload_id),
    .axi_r_payload_resp(ddr_r_payload_resp), .axi_r_payload_last(ddr_r_payload_last)
  );

  // ===========================================================================
  // AXI 观察器 / 结构性断言（全部是运行期计数，判据在收尾处一并判）
  // ===========================================================================
  integer ar_count, rd_beats, aw_count, wr_beats, b_count;
  integer ar_addr_first, arlen_first;
  integer write_chan_bad, ar_extra_bad;
  reg     busy_seen;

  always @(posedge clk) begin
    if (!reset) begin
      if (ddr_ar_valid && ddr_ar_ready) begin
        $display("ARB %08x arlen=%0d", ddr_ar_payload_addr, ddr_ar_payload_len);
        if (ar_count == 0) begin
          ar_addr_first = ddr_ar_payload_addr;
          arlen_first   = ddr_ar_payload_len;
        end else begin
          ar_extra_bad = ar_extra_bad + 1;    // 一个描述符只该有一笔 AR
        end
        ar_count = ar_count + 1;
      end
      if (ddr_r_valid && ddr_r_ready) rd_beats = rd_beats + 1;
      // RD 模式：写通道三根（AW/W/B）一拍都不许举
      if (ddr_aw_valid || ddr_w_valid || ddr_b_ready) write_chan_bad = write_chan_bad + 1;
      if (ddr_aw_valid && ddr_aw_ready) aw_count = aw_count + 1;
      if (ddr_w_valid  && ddr_w_ready)  wr_beats = wr_beats + 1;
      if (ddr_b_valid  && ddr_b_ready)  b_count  = b_count + 1;
      if (busy) busy_seen = 1'b1;
    end
  end

  // ---- 等 words_valid 或 err，带超时 ----
  integer timeout_cnt;
  reg     words_valid_seen, err_seen;
  integer i, tbfail;
  integer addr_in;
  reg     expect_err;
  reg     refetch_en;
  integer refetch_addr_in;
  reg  [27:0] refetch_addr;
  reg  [27:0] first_addr;
  reg     valid_dip_seen, words_valid2_seen, err2_seen;
  integer busy_wait_cnt;
  integer want_ar, want_rd;
  reg     busy_final;
  task wait_op;
    begin
      while (!words_valid_seen && !err_seen) begin
        @(posedge clk);
        if (words_valid)   words_valid_seen = 1'b1;
        else if (err)      err_seen         = 1'b1;
        else begin
          timeout_cnt = timeout_cnt + 1;
          if (timeout_cnt > TIMEOUT) begin
            $display("RESULT: FAIL timeout");
            $fatal(1, "DescTb timeout");
          end
        end
      end
    end
  endtask

  // ---- 等 busy 落 0（= 取表**彻底**完成；含内部 DdrMaster 的在途相位）----
  // M3：装置必须断言 busy 收尾回归 0；也是 I2 再取表作业"上一笔彻底完成后才发第二个 go"的前提。
  task wait_not_busy;
    begin
      busy_wait_cnt = 0;
      while (busy) begin
        @(posedge clk);
        busy_wait_cnt = busy_wait_cnt + 1;
        if (busy_wait_cnt > TIMEOUT) begin
          $display("RESULT: FAIL busy 不落回 0（取表未彻底完成）");
          $fatal(1, "busy stuck high");
        end
      end
    end
  endtask

  // ---- 打印**当前**取表结果的事实：8 个字 + 17 个译码字段（判据在闸门里做）----
  // 再取表作业必须**在第一个 go 之前**把第一项打出来（第二项一起来 wReg/字段 就被覆盖了）。
  task print_facts;
    begin
      $display("WORDS W0=%08x W1=%08x W2=%08x W3=%08x W4=%08x W5=%08x W6=%08x W7=%08x",
               words_0, words_1, words_2, words_3, words_4, words_5, words_6, words_7);
      // 字段名逐字用 `DescDefs.DescWords` 的**访问器名**（TPE/IMGW/CIN/...）：闸门据此把 RTL 译出的
      // 字段映射到 `desc_table.unpack` 的字段名（TYPE/IMG_W/C_IN/...）——映射表在闸门里显式写着。
      $display("FIELDS TPE=0x%02x FLAGS=0x%02x IMGW=%0d IMGH=%0d CIN=%0d COUT=%0d GROUP=%0d",
               d_tpe, d_flags, d_img_w, d_img_h, d_c_in, d_c_out, d_group);
      $display("FIELDS2 STRIDE=%0d PAD=%0d SRCA=0x%08x DSTA=0x%08x INBYTES=%0d QSHIFT=%0d LAYERID=%0d",
               d_stride, d_pad, d_src_a, d_dst_a, d_in_bytes, d_qshift, d_layer);
      $display("FIELDS3 ISSENTINEL=%0d HEAD=%0d TAIL=%0d",
               d_sentinel, d_head, d_tail);
    end
  endtask

  initial begin
    go = 1'b0; desc_addr = 28'd0; refetch_addr = 28'd0; first_addr = 28'd0;
    tbfail = 0; timeout_cnt = 0; expect_err = 1'b0; addr_in = 0;
    refetch_en = 1'b0; refetch_addr_in = 0;
    ar_count = 0; rd_beats = 0; aw_count = 0; wr_beats = 0; b_count = 0;
    ar_addr_first = 0; arlen_first = -1;
    write_chan_bad = 0; ar_extra_bad = 0;
    busy_seen = 1'b0; words_valid_seen = 1'b0; err_seen = 1'b0;
    valid_dip_seen = 1'b0; words_valid2_seen = 1'b0; err2_seen = 1'b0;
    busy_wait_cnt = 0; want_ar = 1; want_rd = 4; busy_final = 1'b0;

    if (!$value$plusargs("DESC_ADDR=%d", addr_in)) begin
      $display("TB-ERROR: missing +DESC_ADDR=<dec>");
      $fatal(1, "missing DESC_ADDR");
    end
    desc_addr  = addr_in[27:0];
    first_addr = desc_addr;
    if ($value$plusargs("REFETCH=%d", refetch_addr_in)) begin
      refetch_en   = 1'b1;
      refetch_addr = refetch_addr_in[27:0];
    end
    if ($test$plusargs("EXPECT_ERR")) expect_err = 1'b1;
    if (!$test$plusargs("MEMFILE"))
      $display("TB NOTE: 没给 +MEMFILE= ⇒ 内存全 0（只有负对照才该这样）");

    $display("TB DESC DESC_ADDR=%0d EXPECT_ERR=%0d REFETCH=%0d MEMSZ=%0d",
             desc_addr, expect_err, refetch_en, MEMSZ);
    if (refetch_en && refetch_addr == desc_addr) begin
      $display("TB-ERROR: +REFETCH 与 +DESC_ADDR 相同（再取表作业必须换地址）");
      $fatal(1, "refetch addr equals desc addr");
    end

    // 复位（同步、高有效；片上口径）
    repeat (4) @(negedge clk);
    reset = 1'b0;
    @(negedge clk);

    // 第一次 go 一拍脉冲（descAddr 与 go 同拍有效）
    @(negedge clk); go = 1'b1;
    @(negedge clk); go = 1'b0;

    // ---- 取表（第一次；再取表作业时，第二个 go 的时序见下）----
    if (refetch_en) begin
      // =====================================================================
      // I2 再取表作业：第二个 `go` **必须落在 `busy` 首次落 0 的那一拍**（同拍）
      // ---------------------------------------------------------------------
      // 死区（= I1 修的就是它）：`busyR` 在 DONE 落 0，比内部 `DdrMaster` 回 IDLE 早一拍。
      // 若 `io.busy` 只出 `busyR`，则"busy 首落 0"的那一拍上 IDLE 态的
      //       `io.go && !ddrMaster.io.busy`
      // 守卫仍为假 ⇒ 本拍的 `go` 被**静默吞掉**（`go` 是单拍脉冲、没有重试路径）⇒ 第二笔取表
      // 永不发生 ⇒ 下面的等待必然超时 ⇒ 本作业红。**这就是让判据真能钉住 I1 的地方**：
      // 只要判据在这拍发 go，回退 I1（`io.busy := busyR`）就必然把它抓住。
      //   观察口径：DUT 在 posedge 更新 `busy`，装置在 negedge 读到的就是**本拍**的稳定值；
      //   "上一拍还在忙、这一拍已闲" ⇒ 这一个 negedge 就是 busy 首落 0 的那一拍。`go` 也在**同一
      //   negedge** 拉高 ⇒ 下一个 posedge 被 DUT 采样，正好落在死区那一拍上（不早不晚）。
      //   先等 busy 抬起（第一次取表确实在途），再等它首落 0；**绝不**先空等 idle 拍。
      // =====================================================================
      busy_wait_cnt = 0;
      while (!busy) begin                        // 等第一次取表确实在途（有界，防挂死）
        @(negedge clk);
        busy_wait_cnt = busy_wait_cnt + 1;
        if (busy_wait_cnt > TIMEOUT) begin
          $display("RESULT: FAIL 再取表作业：第一次取表 busy 一直没抬起");
          $fatal(1, "refetch: first busy never rose");
        end
      end
      busy_wait_cnt = 0;
      while (busy) begin                         // ★ 站在 busy **首落 0** 的那一拍（有界）
        @(negedge clk);
        busy_wait_cnt = busy_wait_cnt + 1;
        if (busy_wait_cnt > TIMEOUT) begin
          $display("RESULT: FAIL 再取表作业：第一次取表 busy 不落 0（取表未彻底完成）");
          $fatal(1, "refetch: first busy stuck high");
        end
      end
      // 此刻第一项已收齐（busy 落 0 = 整条取表通路回 IDLE）：先把第一项的事实打出来
      // —— 第二个 go 还没发，wReg/译码字段仍是第一项的（第二项一起来就被覆盖）。
      print_facts;

      // ★ 与 busy 首落 0 **同拍**发第二个 go（先不改 descAddr 之外的任何东西、不插延时）
      desc_addr = refetch_addr;
      go = 1'b1;
      @(negedge clk); go = 1'b0;

      valid_dip_seen = 1'b0; words_valid2_seen = 1'b0; err2_seen = 1'b0; timeout_cnt = 0;
      while (!words_valid2_seen && !err2_seen) begin
        @(posedge clk);
        if (!words_valid) valid_dip_seen = 1'b1;                  // 新 go ⇒ validR 必须被清（M3）
        if (valid_dip_seen && words_valid) words_valid2_seen = 1'b1;   // 先落 0 再起
        else if (err) err2_seen = 1'b1;
        else begin
          timeout_cnt = timeout_cnt + 1;
          if (timeout_cnt > TIMEOUT) begin
            $display("RESULT: FAIL refetch timeout（第二个 go 在 busy 首落 0 的那一拍发出，却未被受理 ⇒ busy 比内部主口早落：I1 的 OR 没了）");
            $fatal(1, "refetch timeout");
          end
        end
      end
      wait_not_busy;
      busy_final = busy;
      repeat (2) @(negedge clk);
      $display("R2WORDS W0=%08x W1=%08x W2=%08x W3=%08x W4=%08x W5=%08x W6=%08x W7=%08x",
               words_0, words_1, words_2, words_3, words_4, words_5, words_6, words_7);
      $display("R2STAT WORDS_VALID=%0d ERR=%0d VALID_DIP=%0d BUSY_FINAL=%0d AR_COUNT=%0d RD_BEATS=%0d",
               words_valid, err2_seen, valid_dip_seen, busy_final, ar_count, rd_beats);
    end else begin
      wait_op;
      wait_not_busy;             // M3：busy 收尾必须回 0（取表彻底完成）
      busy_final = busy;
      repeat (2) @(negedge clk); // 让监视器收尾
      print_facts;
    end

    // ---- 收尾计数（两种作业都在这里；判据在闸门里做，装置只给事实）----
    $display("TBSTAT WORDS_VALID=%0d ERR=%0d BUSY_SEEN=%0d BUSY_FINAL=%0d AR_COUNT=%0d RD_BEATS=%0d",
             words_valid, err_seen, busy_seen, busy_final, ar_count, rd_beats);
    $display("TBSTAT2 AR_ADDR=0x%08x ARLEN=%0d AW_COUNT=%0d W_BEATS=%0d B_COUNT=%0d",
             ar_addr_first, arlen_first, aw_count, wr_beats, b_count);
    $display("TBSTAT3 WRITE_CHAN_BAD=%0d AR_EXTRA_BAD=%0d", write_chan_bad, ar_extra_bad);

    // ---- 判定 ----
    if (expect_err) begin
      // 非法入参（descAddr 非 32 B 对齐）：必须 err、必须 words_valid=0、**一笔 AR 都没有**
      if (err_seen && !words_valid && ar_count == 0 && rd_beats == 0 &&
          aw_count == 0 && wr_beats == 0 && b_count == 0 && write_chan_bad == 0) begin
        $display("RESULT: PASS");
        $finish;
      end else begin
        $display("RESULT: FAIL 期待 err 且零搬运，实际 ERR=%0d WORDS_VALID=%0d AR=%0d RD_BEATS=%0d",
                 err_seen, words_valid, ar_count, rd_beats);
        $fatal(1, "DescTb expected err with zero movement");
      end
    end else begin
      // 结构性判据（一个 32 B 描述符 = 一笔 AR = 4 拍 = 4 拍 R；再取表作业则是两笔/8 拍）
      want_ar = refetch_en ? 2 : 1;
      want_rd = refetch_en ? 8 : 4;
      if (ar_count != want_ar) begin tbfail = tbfail + 1; $display("TBFAIL: AR_COUNT=%0d != %0d", ar_count, want_ar); end
      if (arlen_first != 3)   begin tbfail = tbfail + 1; $display("TBFAIL: ARLEN=%0d != 3（4 拍 = 32 B）", arlen_first); end
      if (ar_addr_first != first_addr) begin
        tbfail = tbfail + 1;
        $display("TBFAIL: AR_ADDR=%08x != 首个 DESC_ADDR=%08x", ar_addr_first, first_addr);
      end
      if (rd_beats != want_rd) begin tbfail = tbfail + 1; $display("TBFAIL: RD_BEATS=%0d != %0d", rd_beats, want_rd); end
      if (write_chan_bad != 0) begin tbfail = tbfail + 1; $display("TBFAIL: 写通道竟然举了 %0d 拍（RD 模式结构上到不了写相位）", write_chan_bad); end
      if (!busy_seen)         begin tbfail = tbfail + 1; $display("TBFAIL: busy 一拍都没抬过"); end
      if (busy_final)         begin tbfail = tbfail + 1; $display("TBFAIL: busy 收尾没回到 0"); end
      if (!words_valid)       begin tbfail = tbfail + 1; $display("TBFAIL: words_valid 没抬（ERR=%0d）", err_seen); end
      if (err_seen || err2_seen) begin tbfail = tbfail + 1; $display("TBFAIL: 正向用例竟然 err"); end
      if (refetch_en) begin
        if (!valid_dip_seen)      begin tbfail = tbfail + 1; $display("TBFAIL: 新 go 后 words_valid 没先落 0（validR 没被清）"); end
        if (ar_extra_bad != 1)    begin tbfail = tbfail + 1; $display("TBFAIL: AR_EXTRA_BAD=%0d != 1（两笔取表应恰好两笔 AR）", ar_extra_bad); end
      end else begin
        if (ar_extra_bad != 0)    begin tbfail = tbfail + 1; $display("TBFAIL: AR_EXTRA_BAD=%0d != 0", ar_extra_bad); end
      end

      if (words_valid && !err_seen && tbfail == 0) begin
        $display("RESULT: PASS");
        $finish;
      end else begin
        $display("RESULT: FAIL words_valid=%0d err=%0d tbfail=%0d", words_valid, err_seen, tbfail);
        $fatal(1, "DescTb failed");
      end
    end
  end

  // 兜底：仿真不收敛时也报红退出，别让闸门挂死。
  integer wd;
  initial begin
    for (wd = 0; wd < WD_MAX; wd = wd + 1) @(posedge clk);
    $display("RESULT: FAIL timeout(global watchdog %0d cycles)", WD_MAX);
    $fatal(1, "DescTb global timeout");
  end

endmodule
