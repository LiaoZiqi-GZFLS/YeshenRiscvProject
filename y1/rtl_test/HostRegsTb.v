// HostRegs 主机寄存器层自检装置 —— 纯 Verilog（与 rtl_test/WeightStoreTb.v / LineBufferTb.v 同构，
// 走 iverilog -g2012 那一套，不走 SpinalHDL 仿真后端）。
//
// 契约（与 tools/run_hostregs_ab.sh 头部注释逐字一致）：
//   +VECFILE=<file>  每行一对十六进制「地址 值」：`<addr_hex> <value_hex>`。
//                    地址口径 **不是**寄存器内部地址，而是 AXI 字节地址（表里的偏移直接就是地址，
//                    例如 IMG_W 写 "00000008"）。装置按文件顺序：先逐条写，再逐条回读。
//
// 装置做的事（四段）：
//   1) RO-前：任何写之前读一次 ID(0x30)，必须 == 0x594E5031；
//   2) 写：按向量表逐条 AxiLite4 写；
//   3) 读：按**同一顺序**逐条 AxiLite4 读，逐条打印 `READ <addr> <value>`
//          （闸门按 addr 逐元素对账；装置自己不拿期望文件，期望在闸门里）；
//   4) RO-后：写之后 ID 仍是常数；再查未映射读=0 / 未映射写被忽略；最后查状态位
//          （busy/done/err 是**输入**，这里驱动它们，证明 RO 位真的接在网络上、不是死线）。
//   末尾打印 `RESULT: PASS` / `RESULT: FAIL ...`；FAIL 时 $fatal ⇒ vvp 非 0 退出。
//
// ★ 手摇的 AxiLite4 **主机**（本仓没有可用的 SpinalHDL 仿真后端，主机必须自己写）：
//   写：举 AWVALID+AWADDR 与 WVALID+WDATA+WSTRB；等 AWREADY && WREADY；收起 AW/W，举 BREADY；
//       等 BVALID；采 BRESP；收起 BREADY。
//   读：举 ARVALID+ARADDR；等 ARREADY；收起 AR，举 RREADY；等 RVALID；采 RDATA/RRESP；收起 RREADY。
//   每个等待都带超时计数（TIMEOUT 拍）：握不上手就 $fatal 报红，**绝不挂死**。
//
// ★ 采样口径：所有驱动都在 negedge，所有握手判据都在 posedge 采样（避免同沿竞争）。
`timescale 1ns/1ps

module HostRegsTb;

  localparam integer TIMEOUT = 200;              // 单次等待的最长时钟拍数
  localparam [31:0]  ID_CONST = 32'h594E5031;    // "YNP1"
  localparam integer MAXVEC  = 256;              // 向量条数上限

  reg clk = 1'b0;
  reg reset = 1'b1;

  // ---- AxiLite4 主机侧信号 ----
  reg         m_awvalid;
  wire        m_awready;
  reg  [31:0] m_awaddr;
  reg  [2:0]  m_awprot;
  reg         m_wvalid;
  wire        m_wready;
  reg  [31:0] m_wdata;
  reg  [3:0]  m_wstrb;
  wire        m_bvalid;
  reg         m_bready;
  wire [1:0]  m_bresp;
  reg         m_arvalid;
  wire        m_arready;
  reg  [31:0] m_araddr;
  reg  [2:0]  m_arprot;
  wire        m_rvalid;
  reg         m_rready;
  wire [31:0] m_rdata;
  wire [1:0]  m_rresp;

  // ---- 调度器侧状态输入（本装置主动驱动：默认 0，LIVE 段再拉高）----
  reg sched_busy = 1'b0;
  reg sched_done = 1'b0;
  reg sched_err  = 1'b0;
  reg [23:0] sched_unit_index = 24'h00ABCD;   // ★ 逐单元遥测：STATUS[31:8]

  // ---- DUT 导出的寄存器字段（观测用；不参与对账）----
  wire        o_start, o_soft_reset, o_busy, o_done, o_done_sticky, o_err;
  wire        o_kernel_stride, o_kernel_pad;
  wire [31:0] o_img_w, o_img_h, o_c_in, o_c_out, o_group, o_src_addr, o_dst_addr, o_quant_shift, o_layer_id;
  // ★ C3.12：新增两个 RW 档的导出（DESC_ADDR/DESC_COUNT）——本装置只引出来观测，AxiLite 侧才是对账口径。
  wire [31:0] o_desc_addr, o_desc_count;
  // ★ C3.16：权重信箱的四个导出（观测用；AxiLite 侧才是回读对账口径，这里是"端口真的接在网络上"的证据）。
  wire [31:0] o_wgt_sel, o_wgt_addr;
  wire [7:0]  o_wgt_data;
  wire        o_wgt_we;

  HostRegs dut (
    .axilite_aw_valid(m_awvalid), .axilite_aw_ready(m_awready),
    .axilite_aw_payload_addr(m_awaddr), .axilite_aw_payload_prot(m_awprot),
    .axilite_w_valid(m_wvalid), .axilite_w_ready(m_wready),
    .axilite_w_payload_data(m_wdata), .axilite_w_payload_strb(m_wstrb),
    .axilite_b_valid(m_bvalid), .axilite_b_ready(m_bready), .axilite_b_payload_resp(m_bresp),
    .axilite_ar_valid(m_arvalid), .axilite_ar_ready(m_arready),
    .axilite_ar_payload_addr(m_araddr), .axilite_ar_payload_prot(m_arprot),
    .axilite_r_valid(m_rvalid), .axilite_r_ready(m_rready),
    .axilite_r_payload_data(m_rdata), .axilite_r_payload_resp(m_rresp),
    .sched_busy(sched_busy), .sched_done(sched_done), .sched_err(sched_err),
    .sched_unitIndex(sched_unit_index),
    .start(o_start), .soft_reset(o_soft_reset), .busy(o_busy), .done(o_done),
    .done_sticky(o_done_sticky), .err(o_err),
    .img_w(o_img_w), .img_h(o_img_h), .c_in(o_c_in), .c_out(o_c_out), .group_1(o_group),
    .kernel_stride(o_kernel_stride), .kernel_pad(o_kernel_pad),
    .src_addr(o_src_addr), .dst_addr(o_dst_addr), .quant_shift(o_quant_shift), .layer_id(o_layer_id),
    .desc_addr(o_desc_addr), .desc_count(o_desc_count),
    .wgt_sel(o_wgt_sel), .wgt_addr(o_wgt_addr), .wgt_data(o_wgt_data), .wgt_we(o_wgt_we),
    .clk(clk), .reset(reset)
  );

  always #5 clk = ~clk;

  // ★ C3.16：`WGT_WE` 是**自清单拍**（同 CTRL.start）⇒ 整场仿真里它高电平的**拍数**是一个可判的常量：
  //   穷举向量里 0x48 写的是模式 0xA5A50012（bit0=0 ⇒ 不发火），后面 4d) 段**显式**写一次 1
  //   ⇒ 期望 `WGT_WE_PULSES == 1`（既证明"写 1 会发火"，又证明"发完自己就落回 0"）。
  integer wgt_we_pulses;
  always @(posedge clk) if (!reset && o_wgt_we) wgt_we_pulses = wgt_we_pulses + 1;

  // ---- 向量与统计 ----
  reg [8*256-1:0] vecfile, line;
  integer         fd, code, nvec, i, tbfail;
  reg [31:0]      vec_addr [0:MAXVEC-1];
  reg [31:0]      vec_data [0:MAXVEC-1];
  reg [31:0]      va, vv, rv;

  // 超时即报红（非 0 退出），绝不让闸门挂死。
  task fail_timeout(input [8*64-1:0] why);
    begin
      $display("RESULT: FAIL timeout %0s", why);
      $fatal(1, "HostRegsTb timeout");
    end
  endtask

  // ---- 手摇 AxiLite4 写：AW+W 同举，等双 READY，再 BREADY/BVALID ----
  task axi_write(input [31:0] addr, input [31:0] data);
    integer t;
    reg     ok;
    begin
      @(negedge clk);
      m_awvalid = 1'b1; m_awaddr = addr; m_awprot = 3'b000;
      m_wvalid  = 1'b1; m_wdata  = data; m_wstrb  = 4'hF;
      m_bready  = 1'b0;
      t = 0; ok = 1'b0;
      while (!ok) begin
        @(posedge clk);
        if (m_awready && m_wready) ok = 1'b1;
        else begin t = t + 1; if (t > TIMEOUT) fail_timeout("aw/w ready"); end
      end
      @(negedge clk);
      m_awvalid = 1'b0; m_wvalid = 1'b0; m_bready = 1'b1;
      t = 0; ok = 1'b0;
      while (!ok) begin
        @(posedge clk);
        if (m_bvalid) ok = 1'b1;
        else begin t = t + 1; if (t > TIMEOUT) fail_timeout("b valid"); end
      end
      if (m_bresp !== 2'b00) begin
        tbfail = tbfail + 1;
        $display("TBFAIL: write BRESP=%b addr=%08x", m_bresp, addr);
      end
      @(negedge clk);
      m_bready = 1'b0;
    end
  endtask

  // ---- 手摇 AxiLite4 读：AR，等 ARREADY，再 RREADY/RVALID，采 RDATA ----
  task axi_read(input [31:0] addr, output [31:0] data);
    integer t;
    reg     ok;
    begin
      @(negedge clk);
      m_arvalid = 1'b1; m_araddr = addr; m_arprot = 3'b000;
      m_rready  = 1'b0;
      t = 0; ok = 1'b0;
      while (!ok) begin
        @(posedge clk);
        if (m_arready) ok = 1'b1;
        else begin t = t + 1; if (t > TIMEOUT) fail_timeout("ar ready"); end
      end
      @(negedge clk);
      m_arvalid = 1'b0; m_rready = 1'b1;
      t = 0; ok = 1'b0;
      while (!ok) begin
        @(posedge clk);
        if (m_rvalid) begin data = m_rdata; ok = 1'b1; end
        else begin t = t + 1; if (t > TIMEOUT) fail_timeout("r valid"); end
      end
      if (m_rresp !== 2'b00) begin
        tbfail = tbfail + 1;
        $display("TBFAIL: read RRESP=%b addr=%08x", m_rresp, addr);
      end
      @(negedge clk);
      m_rready = 1'b0;
    end
  endtask

  initial begin
    // ---- 初始化主机信号（避免 X 传播）----
    m_awvalid = 1'b0; m_awaddr = 32'h0; m_awprot = 3'b0;
    m_wvalid  = 1'b0; m_wdata  = 32'h0; m_wstrb  = 4'h0;
    m_bready  = 1'b0;
    m_arvalid = 1'b0; m_araddr = 32'h0; m_arprot = 3'b0;
    m_rready  = 1'b0;
    tbfail    = 0;
    nvec      = 0;
    wgt_we_pulses = 0;

    // ---- 取向量文件 ----
    if (!$value$plusargs("VECFILE=%s", vecfile)) begin
      $display("TB-ERROR: 缺 +VECFILE="); $fatal(1, "missing VECFILE");
    end

    // ---- 复位（同步、高有效；片上口径）----
    repeat (4) @(negedge clk);
    reset = 1'b0;
    @(negedge clk);

    // ---- 读向量（每行 `<addr_hex> <value_hex>`；非两token的行跳过）----
    fd = $fopen(vecfile, "r");
    if (fd == 0) begin
      $display("TB-ERROR: 打不开向量文件 %0s", vecfile); $fatal(1, "open vecfile");
    end
    code = $fgets(line, fd);
    while (code != 0) begin
      if ($sscanf(line, "%h %h", va, vv) == 2) begin
        if (nvec >= MAXVEC) begin
          $display("TB-ERROR: 向量条数超过 %0d", MAXVEC); $fatal(1, "too many vec");
        end
        vec_addr[nvec] = va;
        vec_data[nvec] = vv;
        nvec = nvec + 1;
      end
      code = $fgets(line, fd);
    end
    $fclose(fd);
    $display("NVEC %0d", nvec);
    if (nvec == 0) begin
      $display("TB-ERROR: 向量表为空"); $fatal(1, "empty vecfile");
    end

    // ================= 1) RO-前：写之前 ID 已是常数 =================
    axi_read(32'h00000030, rv);
    $display("PRE_ID %08x", rv);
    if (rv !== ID_CONST) begin
      tbfail = tbfail + 1;
      $display("TBFAIL: PRE_ID %08x != %08x", rv, ID_CONST);
    end else begin
      $display("RO_BEFORE_OK");
    end

    // ================= 2) 写：逐条 =================
    for (i = 0; i < nvec; i = i + 1) axi_write(vec_addr[i], vec_data[i]);

    // ================= 3) 读：同序逐条回读，打印 READ 行 =================
    for (i = 0; i < nvec; i = i + 1) begin
      axi_read(vec_addr[i], rv);
      $display("READ %08x %08x", vec_addr[i], rv);
    end

    // ================= 4a) RO-后：写之后 ID 仍是常数 =================
    axi_read(32'h00000030, rv);
    $display("POST_ID %08x", rv);
    if (rv !== ID_CONST) begin
      tbfail = tbfail + 1;
      $display("TBFAIL: POST_ID %08x != %08x", rv, ID_CONST);
    end else begin
      $display("RO_AFTER_OK");
    end

    // ================= 4b) 未映射：读回 0；写被忽略 =================
    // ★ C3.16：表尾现在是 WGT_WE(0x48) ⇒ 未映射探针从 0x3C 挪到 **0x4C**（表尾下一个字）
    //   与 0x100。表 = 0x00..0x48 ⇒ 0x4C 是**紧邻表尾**的第一个未映射字（最容易被漏译的边界）。
    //   （0x3C/0x40/0x44 现在是 WGT_SEL/WGT_ADDR/WGT_DATA —— 它们已映射，拿它们当"未映射"探针是错的。）
    axi_read(32'h0000004C, rv);
    $display("UNMAPPED %08x %08x", 32'h0000004C, rv);
    if (rv !== 32'h0) begin tbfail = tbfail + 1; $display("TBFAIL: unmapped read 0x4C = %08x", rv); end
    axi_read(32'h00000100, rv);
    $display("UNMAPPED %08x %08x", 32'h00000100, rv);
    if (rv !== 32'h0) begin tbfail = tbfail + 1; $display("TBFAIL: unmapped read 0x100 = %08x", rv); end
    axi_write(32'h0000004C, 32'hDEADBEEF);      // 未映射写：必须被忽略
    axi_read(32'h0000004C, rv);
    $display("UNMAPPED %08x %08x", 32'h0000004C, rv);
    if (rv !== 32'h0) begin tbfail = tbfail + 1; $display("TBFAIL: unmapped write landed 0x4C = %08x", rv); end
    axi_read(32'h00000030, rv);                 // 紧邻的 ID 必须不受未映射写影响
    if (rv !== ID_CONST) begin tbfail = tbfail + 1; $display("TBFAIL: ID disturbed by unmapped write = %08x", rv); end
    else begin $display("UNMAPPED_OK"); end

    // ================= 4c) 状态位 LIVE：证明 RO 位接在网络上 =================
    // CTRL.bit8/bit9 是 busy/done 的**电平**（不是粘滞）；STATUS.bit0 才是 done 的粘滞位。
    sched_busy = 1'b1;
    sched_done = 1'b1;
    repeat (2) @(negedge clk);
    axi_read(32'h00000000, rv);
    $display("LIVE_CTRL_BUSY %08x", rv);
    if ((rv & 32'h00000100) === 32'h0) begin tbfail = tbfail + 1; $display("TBFAIL: CTRL.bit8 busy 未反映"); end
    if ((rv & 32'h00000200) === 32'h0) begin tbfail = tbfail + 1; $display("TBFAIL: CTRL.bit9 done(电平) 未反映"); end
    axi_read(32'h00000004, rv);
    $display("LIVE_STATUS_DONE %08x", rv);
    if ((rv & 32'h00000001) === 32'h0) begin tbfail = tbfail + 1; $display("TBFAIL: STATUS.done_sticky 未置位"); end
    if ((rv >> 8) !== sched_unit_index) begin tbfail = tbfail + 1; $display("TBFAIL: STATUS[31:8] 单元数 %06x != %06x", rv[31:8], sched_unit_index); end

    sched_done = 1'b0;                          // done 落下
    repeat (2) @(negedge clk);
    axi_read(32'h00000000, rv);
    $display("LIVE_CTRL_DONELOW %08x", rv);
    if ((rv & 32'h00000200) !== 32'h0) begin tbfail = tbfail + 1; $display("TBFAIL: CTRL.bit9 落下后仍为 1"); end
    axi_read(32'h00000004, rv);
    $display("LIVE_STATUS_STICKY %08x", rv);
    if ((rv & 32'h00000001) === 32'h0) begin tbfail = tbfail + 1; $display("TBFAIL: STATUS.done_sticky 未粘住"); end

    axi_write(32'h00000004, 32'h00000001);      // 写 1 清 done_sticky
    repeat (3) @(negedge clk);
    axi_read(32'h00000004, rv);
    $display("LIVE_STATUS_CLR %08x", rv);
    if ((rv & 32'h00000001) !== 32'h0) begin tbfail = tbfail + 1; $display("TBFAIL: STATUS.done_sticky 写1未清"); end

    sched_err = 1'b1;
    sched_unit_index = 24'h000045;              // ★ 遥测是**活**的（不是常量）
    repeat (2) @(negedge clk);
    axi_read(32'h00000004, rv);
    $display("LIVE_STATUS_ERR %08x", rv);
    if ((rv & 32'h00000002) === 32'h0) begin tbfail = tbfail + 1; $display("TBFAIL: STATUS.err 未反映"); end
    if ((rv >> 8) !== 24'h000045) begin tbfail = tbfail + 1; $display("TBFAIL: STATUS[31:8] 跟随失败 %06x", rv[31:8]); end
    sched_err  = 1'b0;
    sched_busy = 1'b0;
    if (tbfail == 0) $display("LIVE_OK");

    // ================= 4d) ★ C3.16 权重信箱 LIVE：写进去 → 端口上真的看得见；WE 是自清单拍 =================
    //   (i) 三个存储档回读（矢量的穷举段已对账过一遍，这里再走一次"语义值"：负数 int8 的载荷）；
    //   (ii) `WGT_WE` 写 1 ⇒ 导出端口**恰好高 1 拍**（`WGT_WE_PULSES==1`，见文件上方计数器），
    //        且随后自己落回 0（自清）。这两条一起证明"写使能不是死线、也不是常 1"。
    axi_write(32'h0000003C, 32'h00000005);      // WGT_SEL  = 5
    axi_write(32'h00000040, 32'h00000123);      // WGT_ADDR = 0x123
    axi_write(32'h00000044, 32'hFFFFFF9C);      // WGT_DATA = 0xFFFFFF9C（低 8 位 0x9C = int8 -100）
    repeat (2) @(negedge clk);
    $display("WGT_EXPORT_SEL %08x", o_wgt_sel);
    $display("WGT_EXPORT_ADDR %08x", o_wgt_addr);
    $display("WGT_EXPORT_DATA %02x", o_wgt_data);
    if (o_wgt_sel  !== 32'h00000005) begin tbfail = tbfail + 1; $display("TBFAIL: WGT_SEL 导出 = %08x != 5", o_wgt_sel); end
    if (o_wgt_addr !== 32'h00000123) begin tbfail = tbfail + 1; $display("TBFAIL: WGT_ADDR 导出 = %08x != 0x123", o_wgt_addr); end
    if (o_wgt_data !== 8'h9C) begin tbfail = tbfail + 1; $display("TBFAIL: WGT_DATA 导出（低 8 位）= %02x != 9c", o_wgt_data); end
    if (o_wgt_we   !== 1'b0) begin tbfail = tbfail + 1; $display("TBFAIL: 未写 WE 时 o_wgt_we = %0d", o_wgt_we); end
    axi_read(32'h0000003C, rv); if (rv !== 32'h00000005) begin tbfail=tbfail+1; $display("TBFAIL: RB WGT_SEL=%08x", rv); end
    axi_read(32'h00000040, rv); if (rv !== 32'h00000123) begin tbfail=tbfail+1; $display("TBFAIL: RB WGT_ADDR=%08x", rv); end
    axi_read(32'h00000044, rv); if (rv !== 32'hFFFFFF9C) begin tbfail=tbfail+1; $display("TBFAIL: RB WGT_DATA=%08x", rv); end
    axi_write(32'h00000048, 32'h00000001);      // WGT_WE = 1（自清单拍）
    repeat (4) @(negedge clk);
    $display("WGT_WE_PULSES %0d", wgt_we_pulses);
    $display("WGT_WE_NOW %0d", o_wgt_we);
    axi_read(32'h00000048, rv);
    $display("WGT_RB_WE %08x", rv);
    if (wgt_we_pulses !== 1) begin tbfail = tbfail + 1; $display("TBFAIL: WGT_WE 脉冲数 = %0d != 1（自清单拍不成立）", wgt_we_pulses); end
    if (o_wgt_we !== 1'b0) begin tbfail = tbfail + 1; $display("TBFAIL: WGT_WE 自清失败（仍是 %0d）", o_wgt_we); end
    if (rv !== 32'h0) begin tbfail = tbfail + 1; $display("TBFAIL: WGT_WE 回读 = %08x != 0（只写档）", rv); end
    if (tbfail == 0) $display("WGT_OK");

    // ================= 汇总 =================
    if (tbfail == 0) begin
      $display("RESULT: PASS");
      $finish;
    end else begin
      $display("RESULT: FAIL tbmiss=%0d", tbfail);
      $fatal(1, "HostRegsTb self-check failed");
    end
  end

  // 仿真不收敛的兜底：超时即判红（非 0 退出），避免闸门挂死。
  initial begin
    #2000000;
    $display("RESULT: FAIL timeout(global)");
    $fatal(1, "HostRegsTb global timeout");
  end

endmodule
