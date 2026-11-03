// AxiMemModel.v —— 行为级 AXI4 内存模型（纯 Verilog，单一 clk，同步高有效 reset）。
//
// 用途：给 y1 的 AXI 主口（先是 rtl/DdrMaster.scala 的读路径，后续还有写路径/块拷贝）
// 当对手。它**故意只认桥允许的那一小块协议子集**，并且把"不合规"做成**响亮 $fatal**：
//   · 数据 64 bit / wstrb 8 bit / id 4 bit —— 与 SoC 的 `AXIIO64` 同形；
//   · 突发长度 **最多 16 拍**（arlen/awlen <= 15）；
//   · 首址必须 **32 B 对齐**（低 5 位为 0）；
//   · 每笔突发的字节数必须是 **8 的整数倍**；
//   · 访问区间必须落在**已建模的内存**里（否则越界读出的是"看似正常"的数据 —— 这正是
//     src/soc/DDR3Bridge.scala 那种"静默搬错"的温床，所以这里一律 fatal，不返回 0）。
//
// 为什么不能只靠主口的自己的闸门：主口"少读/读偏"可能依然打印出**格式正确**的块，
// 只有把"内存里到底有什么"独立建模、再字节级对账，才能证伪"根本没读对"。
//
// 激励 / 观察接口（全是 plusarg，装置侧不写死路径）：
//   +MEMFILE=<file>  预载：$readmemh 格式，**一行一个十六进制字节**（"00".."ff"），第 i 行 -> mem[i]。
//   +DUMPFILE=<file> 导出：仿真结束时按同一格式把整个内存写回（用于闸门逐字节对账）。
//   +dump            可选，出现即触发导出（等价于给了 DUMPFILE）。
//   末尾固定打印：`MEM rd=<bytes> wr=<bytes> bursts=<n> maxburst=<n>`
//   —— 闸门拿它和主口自报的 rd_bytes 交叉对账（两处独立计数，一起对得上才算数）。
//
// 读通道时序（1 拍读延迟，够紧也够确定）：
//   arvalid & arready（AR 一拍握手，同时做全部合规检查）-> 下一拍起 rvalid 抬高，
//   连出 (arlen+1) 拍，每拍 8 B、按 **小端** 拼成 64 bit；最后一拍 rlast=1。
//   r 仅在 rvalid&rready 时推进；中间不给背压也不丢拍。
//
// 写通道：同为"先做合规检查再动内存"，wstrb 逐位掩码；写完整笔突发后出 B 响应。
//   （本任务主口把写半边钉死 ⇒ 这几条通道不会动，但模型本身要能当后面写任务的对手。）
`timescale 1ns/1ps

module AxiMemModel #(
  parameter integer MEMSZ  = 8192,
  parameter integer ADDR_W = 28
) (
  input  wire                clk,
  input  wire                reset,

  // ---------------- AW ----------------
  input  wire                axi_aw_valid,
  output wire                axi_aw_ready,
  input  wire [ADDR_W-1:0]   axi_aw_payload_addr,
  input  wire [3:0]          axi_aw_payload_id,
  input  wire [7:0]          axi_aw_payload_len,
  input  wire [2:0]          axi_aw_payload_size,
  input  wire [1:0]          axi_aw_payload_burst,
  input  wire [3:0]          axi_aw_payload_cache,
  input  wire [2:0]          axi_aw_payload_prot,
  // ---------------- W ----------------
  input  wire                axi_w_valid,
  output wire                axi_w_ready,
  input  wire [63:0]         axi_w_payload_data,
  input  wire [7:0]          axi_w_payload_strb,
  input  wire                axi_w_payload_last,
  // ---------------- B ----------------
  output wire                axi_b_valid,
  input  wire                axi_b_ready,
  output wire [3:0]          axi_b_payload_id,
  output wire [1:0]          axi_b_payload_resp,
  // ---------------- AR ----------------
  input  wire                axi_ar_valid,
  output wire                axi_ar_ready,
  input  wire [ADDR_W-1:0]   axi_ar_payload_addr,
  input  wire [3:0]          axi_ar_payload_id,
  input  wire [7:0]          axi_ar_payload_len,
  input  wire [2:0]          axi_ar_payload_size,
  input  wire [1:0]          axi_ar_payload_burst,
  input  wire [3:0]          axi_ar_payload_cache,
  input  wire [2:0]          axi_ar_payload_prot,
  // ---------------- R ----------------
  output wire                axi_r_valid,
  input  wire                axi_r_ready,
  output wire [63:0]         axi_r_payload_data,
  output wire [3:0]          axi_r_payload_id,
  output wire [1:0]          axi_r_payload_resp,
  output wire                axi_r_payload_last
);

  // ---------------------------------------------------------------------------
  // 内存本体与统计
  // ---------------------------------------------------------------------------
  reg [7:0] mem [0:MEMSZ-1];

  reg  [31:0] rd_bytes;
  reg  [31:0] wr_bytes;
  reg  [31:0] bursts;
  integer     maxburst;

  // ---------------------------------------------------------------------------
  // 合规检查（唯一的出口就是 $fatal —— 违规主口必须炸，不许静默通过）
  // ---------------------------------------------------------------------------
  task check_burst;
    input  [8*8-1:0]   ch;       // "AR" / "AW"
    input  [7:0]       blen;
    input  [ADDR_W-1:0] baddr;
    input  [2:0]       bsize;
    output [31:0]      nbytes;
    reg    [8:0]       beats;
    begin
      beats  = {1'b0, blen} + 9'd1;
      // 注意：Verilog 里 `a << b` 的结果宽度 = a 的宽度 ⇒ 先补宽到 32 位再移位，否则大步长会截断。
      nbytes = {23'd0, beats} << bsize;
      if (beats > 9'd16)
        $fatal(1, "AXI-MEM VIOLATION: %0s burst %0d beats > 16 (len=%0d)", ch, beats, blen);
      if (baddr[4:0] != 5'd0)
        $fatal(1, "AXI-MEM VIOLATION: %0s address %08x not 32B aligned (low5=%02x)", ch, baddr, baddr[4:0]);
      if ((nbytes % 32'd8) != 0)
        $fatal(1, "AXI-MEM VIOLATION: %0s burst %0d bytes not a multiple of 8 (size=%0d)", ch, nbytes, bsize);
      if (({{(32-ADDR_W){1'b0}}, baddr} + nbytes) > MEMSZ)
        $fatal(1, "AXI-MEM OUT-OF-RANGE: %0s addr=%08x bytes=%0d beyond modelled memory %0d", ch, baddr, nbytes, MEMSZ);
    end
  endtask

  // ---------------------------------------------------------------------------
  // 读引擎
  // ---------------------------------------------------------------------------
  localparam RS_IDLE = 1'b0, RS_DATA = 1'b1;
  reg              rs;
  reg [ADDR_W-1:0] r_addr;
  reg [8:0]        r_left;      // 还剩几拍
  reg [3:0]        r_id;

  // ★ 2026-10-18 L2b：**读侧支持最多 4 笔在飞 AR**（背靠背 AR 进小队列；R 按序回）。
  //   单笔主口的 R 延迟与旧模型**逐拍相同**：AR 握手这一拍直接装 r_* 寄存器，下一拍 rvalid 抬高；
  //   只有"流进行中又来 AR"才进队列。队列满（4）时 arready 拉低。
  //   另加 `out_rd/maxout_rd` 统计（AR 握手 − rlast 握手），最终 `MEM ... maxout=N` 供闸门取证。
  localparam AQ = 4;
  reg [ADDR_W-1:0] aq_addr [0:AQ-1];
  reg [8:0]        aq_left [0:AQ-1];
  reg [3:0]        aq_id   [0:AQ-1];
  reg [1:0]        aq_wp, aq_rp;
  reg [2:0]        aq_cnt;          // 已排队（不含当前流）
  reg [2:0]        out_rd, maxout_rd;

  // ★ G2-c（2026-10-23，**仅装置**）：读首拍延迟旋钮 `+RDLAT=<拍>`（默认 0 ⇒ 与旧模型逐拍相同）。
  //   为什么要：旧模型 AR 握手后**下一拍**就给 rvalid（延迟 1 拍），预取/多 band 在飞毫无收益，
  //   闸门测不出结构差异（G2-P0 只能用一次性外挂模型）。这里给每个被接收的 AR 记一个"到期时刻"
  //   （按 AR 接收起算），到期前不出 rvalid、到期后照旧逐拍回；多笔在飞时各自的到期时刻重叠，
  //   与真实 DDR 的流水行为同形。**只改 TB，不影响任何 RTL/网表**。
  integer RDLAT;
  initial begin
    RDLAT = 0;
    if (!$value$plusargs("RDLAT=%d", RDLAT)) RDLAT = 0;
    if (RDLAT < 0) RDLAT = 0;
    $display("MEM NOTE: RDLAT=%0d", RDLAT);
  end
  reg [15:0] r_wait;                 // 当前流首拍前还要等几拍
  reg [15:0] aq_wait [0:AQ-1];       // 每笔排队 burst 的剩余等拍（自 AR 接收起算）
  integer    wi;

  wire ar_fire = axi_ar_valid && axi_ar_ready;
  wire r_fire  = (rs == RS_DATA) && (r_wait == 16'd0) && axi_r_ready;
  wire r_last_fire = r_fire && (r_left == 9'd1);
  // 本拍 AR 直接成为当前流：空闲，或正好接在当前流末拍之后且队列空。
  wire ar_direct = (rs == RS_IDLE) || (rs == RS_DATA && r_left == 9'd1 && aq_cnt == 3'd0);

  // 小端：低地址在低字节。
  wire [63:0] r_data_now = {
    mem[r_addr + 7], mem[r_addr + 6], mem[r_addr + 5], mem[r_addr + 4],
    mem[r_addr + 3], mem[r_addr + 2], mem[r_addr + 1], mem[r_addr]
  };

  assign axi_ar_ready       = (aq_cnt < AQ);
  assign axi_r_valid        = (rs == RS_DATA) && (r_wait == 16'd0);
  assign axi_r_payload_data = r_data_now;
  assign axi_r_payload_id   = r_id;
  assign axi_r_payload_resp = 2'b00;                 // OKAY
  assign axi_r_payload_last = (r_left == 9'd1);

  // ---------------------------------------------------------------------------
  // 写引擎
  // ---------------------------------------------------------------------------
  localparam WS_IDLE = 2'd0, WS_DATA = 2'd1, WS_RESP = 2'd2;
  reg              [1:0] ws;
  reg [ADDR_W-1:0] w_addr;
  reg [8:0]        w_left;
  reg [3:0]        w_id;

  assign axi_aw_ready       = (ws == WS_IDLE);
  assign axi_w_ready        = (ws == WS_DATA);
  assign axi_b_valid        = (ws == WS_RESP);
  assign axi_b_payload_id   = w_id;
  assign axi_b_payload_resp = 2'b00;                 // OKAY

  integer bi;              // 写数据的字节下标 0..7
  reg [31:0] nby;          // check_burst 的出口（读/写各自一份）

  // ---------------------------------------------------------------------------
  // 主时序
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (reset) begin
      rs       <= RS_IDLE;
      ws       <= WS_IDLE;
      r_addr   <= {ADDR_W{1'b0}};
      r_left   <= 9'd0;
      r_id     <= 4'd0;
      w_addr   <= {ADDR_W{1'b0}};
      w_left   <= 9'd0;
      w_id     <= 4'd0;
      rd_bytes <= 32'd0;
      wr_bytes <= 32'd0;
      bursts   <= 32'd0;
      maxburst <= 0;
      aq_wp    <= 2'd0;
      aq_rp    <= 2'd0;
      aq_cnt   <= 3'd0;
      out_rd   <= 3'd0;
      maxout_rd <= 3'd0;
      r_wait   <= 16'd0;
      for (wi = 0; wi < AQ; wi = wi + 1) aq_wait[wi] <= 16'd0;
    end else begin
      // ---------------- G2-c：所有"到期时刻"逐拍逼近（先减，后由本拍 AR 装载覆盖）----------------
      for (wi = 0; wi < AQ; wi = wi + 1)
        if (aq_wait[wi] != 16'd0) aq_wait[wi] <= aq_wait[wi] - 16'd1;
      if (r_wait != 16'd0) r_wait <= r_wait - 16'd1;
      // ---------------- AR：一拍握手即完成全部合规检查；直装当前流或进队列 ----------------
      if (ar_fire) begin
        check_burst("AR", axi_ar_payload_len, axi_ar_payload_addr, axi_ar_payload_size, nby);
        rd_bytes <= rd_bytes + nby;
        bursts   <= bursts + 32'd1;
        if (({1'b0, axi_ar_payload_len} + 1) > maxburst)
          maxburst <= {1'b0, axi_ar_payload_len} + 1;
        if (ar_direct) begin
          r_addr <= axi_ar_payload_addr;
          r_left <= {1'b0, axi_ar_payload_len} + 9'd1;
          r_id   <= axi_ar_payload_id;
          r_wait <= RDLAT[15:0];
          rs     <= RS_DATA;
        end else begin
          aq_addr[aq_wp] <= axi_ar_payload_addr;
          aq_left[aq_wp] <= {1'b0, axi_ar_payload_len} + 9'd1;
          aq_id[aq_wp]   <= axi_ar_payload_id;
          aq_wait[aq_wp] <= RDLAT[15:0];
          aq_wp          <= aq_wp + 2'd1;
        end
      end

      // ---------------- R：逐拍推进；末拍时若队列非空则无气泡接下一笔 ----------------
      if (r_fire) begin
        if (r_left == 9'd1) begin
          if (aq_cnt != 3'd0) begin
            r_addr <= aq_addr[aq_rp];
            r_left <= aq_left[aq_rp];
            r_id   <= aq_id[aq_rp];
            r_wait <= aq_wait[aq_rp];
            aq_rp  <= aq_rp + 2'd1;
            // rs 保持 RS_DATA（背靠背、无气泡）
          end else if (!(ar_fire && ar_direct)) begin
            rs <= RS_IDLE;
          end
        end else begin
          r_addr <= r_addr + 8;
          r_left <= r_left - 9'd1;
        end
      end

      // ---------------- AR 队列计数 / 在飞峰值 ----------------
      aq_cnt <= aq_cnt
              + ((ar_fire && !ar_direct) ? 3'd1 : 3'd0)
              - ((r_last_fire && aq_cnt != 3'd0) ? 3'd1 : 3'd0);
      out_rd <= out_rd + (ar_fire ? 3'd1 : 3'd0) - (r_last_fire ? 3'd1 : 3'd0);
      if (ar_fire && (out_rd + 3'd1) > maxout_rd) maxout_rd <= out_rd + 3'd1;

      // ---------------- AW ----------------
      if (axi_aw_valid && axi_aw_ready) begin
        check_burst("AW", axi_aw_payload_len, axi_aw_payload_addr, axi_aw_payload_size, nby);
        w_addr <= axi_aw_payload_addr;
        w_left <= {1'b0, axi_aw_payload_len} + 9'd1;
        w_id   <= axi_aw_payload_id;
        ws     <= WS_DATA;
        bursts <= bursts + 32'd1;
        if (({1'b0, axi_aw_payload_len} + 1) > maxburst)
          maxburst <= {1'b0, axi_aw_payload_len} + 1;
      end

      // ---------------- W：wstrb 逐位掩码写入 ----------------
      if (ws == WS_DATA && axi_w_valid && axi_w_ready) begin
        for (bi = 0; bi < 8; bi = bi + 1) begin
          if (axi_w_payload_strb[bi]) mem[w_addr + bi] <= axi_w_payload_data[bi*8 +: 8];
        end
        wr_bytes <= wr_bytes + $countones(axi_w_payload_strb);
        if (w_left == 9'd1) begin
          ws <= WS_RESP;
        end else begin
          w_addr <= w_addr + 8;
          w_left <= w_left - 9'd1;
        end
      end

      // ---------------- B ----------------
      if (ws == WS_RESP && axi_b_ready) begin
        ws <= WS_IDLE;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // 预载 / 导出 / 统计
  // ---------------------------------------------------------------------------
  integer     i, fd;
  reg [8*256-1:0] memfile, dumpfile;
  reg         do_load, do_dump;

  initial begin
    do_load  = 1'b0;
    do_dump  = 1'b0;
    memfile  = 0;
    dumpfile = 0;

    // 先整体清零：MEMFILE 行数不足时（或干脆没给）剩下的格子是确定的 0，不是 X。
    for (i = 0; i < MEMSZ; i = i + 1) mem[i] = 8'h00;

    if ($value$plusargs("MEMFILE=%s", memfile)) begin
      $readmemh(memfile, mem);
      do_load = 1'b1;
      $display("MEM LOADED %0s (%0d bytes modelled)", memfile, MEMSZ);
    end else begin
      $display("MEM NOTE: no +MEMFILE= => memory stays all-zero");
    end

    if ($test$plusargs("dump")) do_dump = 1'b1;
    if ($value$plusargs("DUMPFILE=%s", dumpfile)) do_dump = 1'b1;
  end

  final begin
    if (do_dump) begin
      fd = $fopen(dumpfile, "w");
      if (fd == 0) begin
        $display("MEM-ERROR: cannot open +DUMPFILE=%0s", dumpfile);
      end else begin
        for (i = 0; i < MEMSZ; i = i + 1) $fdisplay(fd, "%02x", mem[i]);
        $fclose(fd);
        $display("MEM DUMPED %0s (%0d bytes)", dumpfile, MEMSZ);
      end
    end
    $display("MEM rd=%0d wr=%0d bursts=%0d maxburst=%0d", rd_bytes, wr_bytes, bursts, maxburst);
    $display("MAXOUT_MODEL=%0d", maxout_rd);
  end

endmodule
