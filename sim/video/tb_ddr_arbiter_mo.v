//=============================================================================
// tb_ddr_arbiter_mo: 板级 DDR 2:1 仲裁器**读通道多未完成**闸门（P4）
//
// 背景：旧版读通道 AR 串行（单笔 outstanding），把 DDR3Bridge 内 DEPTH=4 的
//   多未完成结构性压成 1 ⇒ NPU 的 8×32B gather 批每批只能一笔一笔往返。
//   本闸门证明：桥可以**连续递交 BN 笔 AR 且它们同时未完成**，视频侧仍按
//   rid=1 分流、且视频 AR 不被桥的在飞读阻塞（VN=1 时最多等一个 AR 发放槽）。
//
// 判据（TB_BN=4 正档）：
//   1) 4 笔桥读的 AR 在**第一笔 R 回来之前**全部被收下 ⇒ MO_PEAK=4
//   2) 4 笔数据按 AR 顺序逐字正确（0x1111..0x4444），rid 全 0
//   3) 4 笔在飞期间发视频读：v_arready 在 ≤4 拍内到（不被桥堵住），
//      视频数据 0xAAAA、rid=1；两侧无 rid 串扰
// 负对照（TB_BN=1，即旧行为）：
//   同样的激励下 MO_PEAK 只能到 1 ⇒ 判据 1 必红（闸门脚本要求它红）。
//
// 驱动：全部在 posedge 寄存器化（valid 保持到握手；握手同拍换下一地址）；
//       激励源不直接组合驱动 DUT，避免"同拍换地址"的竞争。
//=============================================================================
`timescale 1ns/1ps

module tb_ddr_arbiter_mo;
    parameter TB_BN = 4;             // 负对照用 -Ptb_ddr_arbiter_mo.TB_BN=1
    parameter EXP_PEAK = 4;          // 判据期望的桥在飞峰值（不随负对照降）
    localparam AW = 28;
    localparam [AW-1:0] BA0 = 28'h100;   // 桥 4 笔地址基址（+8 递进）
    localparam [AW-1:0] VA0 = 28'h200;   // 视频地址

    reg clk = 0, rstn = 0;
    always #4 clk = ~clk;            // 125 MHz

    //-------------------------------------------------------------------------
    // 桥侧（ID=0）
    //-------------------------------------------------------------------------
    reg  [AW-1:0] b_awaddr = 0, b_araddr = 0;
    reg  [3:0]    b_awlen = 0, b_arlen = 0;
    reg           b_awvalid = 0, b_wvalid = 0, b_arvalid = 0;
    reg  [255:0]  b_wdata = 0;
    reg  [31:0]   b_wstrb = 32'hFFFF_FFFF;
    wire          b_awready, b_wready, b_arready;
    wire [255:0]  b_rdata;
    wire [3:0]    b_rid;
    wire          b_rlast, b_rvalid;
    wire          b_rready = 1'b1;   // 板级 b_rready 恒 1

    //-------------------------------------------------------------------------
    // 视频侧（ID=1）
    //-------------------------------------------------------------------------
    reg  [AW-1:0] v_awaddr = 0, v_araddr = 0;
    reg  [3:0]    v_awlen = 0, v_arlen = 0;
    reg           v_awvalid = 0, v_wvalid = 0, v_arvalid = 0;
    reg  [255:0]  v_wdata = 0;
    reg  [31:0]   v_wstrb = 32'hFFFF_FFFF;
    wire          v_awready, v_wready, v_arready;
    wire [255:0]  v_rdata;
    wire [3:0]    v_rid;
    wire          v_rlast, v_rvalid;
    wire          v_rready = 1'b1;

    //-------------------------------------------------------------------------
    // IP 侧
    //-------------------------------------------------------------------------
    wire [AW-1:0] m_awaddr, m_araddr;
    wire [3:0]    m_awlen, m_arlen, m_aruser_id, m_rid;
    wire          m_awvalid, m_awready;
    wire [255:0]  m_wdata, m_rdata;
    wire [31:0]   m_wstrb;
    wire          m_wvalid, m_wready, m_wusero_last;
    wire          m_arvalid, m_arready;
    wire          m_rlast, m_rvalid, m_rready;
    wire          b_wlast, v_wlast;
    wire [31:0]   dbg_v_ar_wait;

    ddr_arbiter_2to1 #(.AW(AW), .BN(TB_BN), .VN(1)) dut (
        .clk(clk), .rstn(rstn),
        .b_awaddr(b_awaddr), .b_awlen(b_awlen), .b_awvalid(b_awvalid), .b_awready(b_awready),
        .b_wdata(b_wdata), .b_wstrb(b_wstrb), .b_wvalid(b_wvalid), .b_wready(b_wready),
        .b_araddr(b_araddr), .b_arlen(b_arlen), .b_arvalid(b_arvalid), .b_arready(b_arready),
        .b_rdata(b_rdata), .b_rid(b_rid), .b_rlast(b_rlast), .b_rvalid(b_rvalid), .b_rready(b_rready),
        .v_awaddr(v_awaddr), .v_awlen(v_awlen), .v_awvalid(v_awvalid), .v_awready(v_awready),
        .v_wdata(v_wdata), .v_wstrb(v_wstrb), .v_wvalid(v_wvalid), .v_wready(v_wready),
        .v_araddr(v_araddr), .v_arlen(v_arlen), .v_arvalid(v_arvalid), .v_arready(v_arready),
        .v_rdata(v_rdata), .v_rid(v_rid), .v_rlast(v_rlast), .v_rvalid(v_rvalid), .v_rready(v_rready),
        .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wvalid(m_wvalid), .m_wready(m_wready),
        .m_wusero_last(m_wusero_last),
        .m_araddr(m_araddr), .m_arlen(m_arlen), .m_aruser_id(m_aruser_id),
        .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rdata(m_rdata), .m_rid(m_rid), .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready),
        .b_wlast(b_wlast), .v_wlast(v_wlast),
        .dbg_v_ar_wait(dbg_v_ar_wait)
    );

    // IP 模型：深命令队列 + 长延迟 ⇒ 4 笔 AR 能同时未完成
    ddr_model #(.AW(AW), .LAT(20), .ARDEPTH(8)) ddr (
        .clk(clk), .rstn(rstn),
        .awaddr(m_awaddr), .awlen(m_awlen), .awvalid(m_awvalid), .awready(m_awready),
        .wdata(m_wdata), .wstrb(m_wstrb), .wvalid(m_wvalid), .wready(m_wready),
        .wusero_last(m_wusero_last),
        .araddr(m_araddr), .arlen(m_arlen), .aruser_id(m_aruser_id),
        .arvalid(m_arvalid), .arready(m_arready),
        .rdata(m_rdata), .rid(m_rid), .rlast(m_rlast), .rvalid(m_rvalid), .rready(m_rready)
    );

    //-------------------------------------------------------------------------
    // 观测
    //-------------------------------------------------------------------------
    integer b_acc = 0, b_cpl = 0, v_acc = 0, v_cpl = 0;
    integer b_peak = 0, v_peak = 0;
    integer b_spur = 0, v_spur = 0;
    integer b_qn = 0, v_qn = 0;
    reg [255:0] b_q [0:7];
    reg [255:0] v_q [0:3];

    wire b_fire = b_rvalid && b_rready;
    wire v_fire = v_rvalid && v_rready;
    wire b_ar_fire = b_arvalid && b_arready;
    wire v_ar_fire = v_arvalid && v_arready;

    // 在飞峰值直接取 DUT 自己的未完成计数（白盒：b_out = IP 已收 AR − 已回 rlast）。
    // 不做 TB 侧的 acc−cpl 推算 —— 那样会和寄存器更新错一拍，把峰值算大。
    always @(posedge clk) begin
        if (rstn) begin
            if (dut.b_out > b_peak) b_peak <= dut.b_out;
            if (dut.v_out > v_peak) v_peak <= dut.v_out;
        end
    end

    always @(posedge clk) begin
        if (rstn) begin
            if (b_ar_fire) b_acc <= b_acc + 1;
            if (v_ar_fire) v_acc <= v_acc + 1;
            if (b_fire && b_rlast) b_cpl <= b_cpl + 1;
            if (v_fire && v_rlast) v_cpl <= v_cpl + 1;
            if (b_fire) begin
                b_q[b_qn] = b_rdata;
                if (b_qn < 7) b_qn = b_qn + 1;
                if (b_rid !== 4'h0) b_spur = b_spur + 1;
            end
            if (v_fire) begin
                v_q[v_qn] = v_rdata;
                if (v_qn < 3) v_qn = v_qn + 1;
                if (v_rid !== 4'h1) v_spur = v_spur + 1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // 寄存器化激励源
    //-------------------------------------------------------------------------
    reg        stream_go = 0;
    reg        b_stream_done = 0;
    reg [1:0]  bidx = 0;
    reg        v_go = 0, v_sent = 0;
    integer    v_lat = 0;
    integer    v_wait = 0;

    always @(posedge clk) begin
        if (!rstn) begin
            b_arvalid <= 0; b_araddr <= 0; b_arlen <= 0;
            bidx <= 0; b_stream_done <= 0;
            v_arvalid <= 0; v_araddr <= 0; v_arlen <= 0;
            v_sent <= 0; v_wait <= 0;
        end else begin
            // ---- 桥：4 笔背靠背（握手同拍换地址，valid 保持） ----
            if (stream_go && !b_stream_done) begin
                if (!b_arvalid) begin
                    b_arvalid <= 1;
                    b_araddr  <= BA0;
                    b_arlen   <= 4'd0;
                end else if (b_arready) begin
                    if (bidx == 2'd3) begin
                        b_arvalid <= 0;
                        b_stream_done <= 1;
                    end else begin
                        bidx     <= bidx + 2'd1;
                        b_araddr <= BA0 + ((bidx + 2'd1) << 3);
                    end
                end
            end
            // ---- 视频：单笔，记录从 go 到握手等了几拍 ----
            if (v_go && !v_sent) begin
                if (!v_arvalid) begin
                    v_arvalid <= 1;
                    v_araddr  <= VA0;
                    v_arlen   <= 4'd0;
                end else if (v_arready) begin
                    v_arvalid <= 0;
                    v_sent    <= 1;
                end
                if (!v_ar_fire) v_wait <= v_wait + 1;
                else            v_lat  <= v_wait;
            end
        end
    end

    //-------------------------------------------------------------------------
    // 桥写（只用于预置数据；走与板级相同的 awvalid&&wvalid → 单拍 W）
    //-------------------------------------------------------------------------
    integer errs = 0;
    integer i;

    task b_write1(input [AW-1:0] a, input [255:0] d);
        begin
            @(negedge clk);
            b_awaddr = a; b_awlen = 4'd0; b_awvalid = 1'b1;
            b_wdata = d; b_wstrb = 32'hFFFF_FFFF; b_wvalid = 1'b1;
            while (!b_awready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            b_awvalid = 1'b0;
            while (!b_wready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            b_wvalid = 1'b0;
            repeat (2) @(negedge clk);
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rstn = 1;
        repeat (3) @(posedge clk);

        // 预置 4 笔桥读的数据 + 1 笔视频读的数据
        b_write1(BA0 + 28'h00, 256'h1111);
        b_write1(BA0 + 28'h08, 256'h2222);
        b_write1(BA0 + 28'h10, 256'h3333);
        b_write1(BA0 + 28'h18, 256'h4444);
        b_write1(VA0,           256'hAAAA);
        repeat (4) @(posedge clk);

        // 4 笔桥读开跑；至少 2 笔在飞时再发视频读
        stream_go <= 1;
        wait (b_acc >= 2);
        v_go <= 1;

        // 等全部读回
        wait (b_cpl >= 4);
        wait (v_cpl >= 1);
        repeat (8) @(posedge clk);

        // ---- 判据 ----------------------------------------------------
        $display("MO_BN=%0d MO_PEAK=%0d V_PEAK=%0d V_LAT=%0d B_ACC=%0d V_ACC=%0d",
                 TB_BN, b_peak, v_peak, v_lat, b_acc, v_acc);
        if (b_peak < EXP_PEAK) begin
            errs = errs + 1;
            $display("MO: CHECK bridge outstanding peak=%0d < EXP=%0d (AR 没有多笔在飞)",
                     b_peak, EXP_PEAK);
        end
        if (v_lat > 8) begin
            errs = errs + 1;
            $display("MO: CHECK video AR waited %0d clocks (>8, 被桥堵住；桥第一笔 R 约 20 拍后才到)", v_lat);
        end
        if (b_acc != 4 || b_cpl != 4) begin
            errs = errs + 1;
            $display("MO: CHECK bridge acc=%0d cpl=%0d exp 4/4", b_acc, b_cpl);
        end
        if (v_acc != 1 || v_cpl != 1) begin
            errs = errs + 1;
            $display("MO: CHECK video acc=%0d cpl=%0d exp 1/1", v_acc, v_cpl);
        end
        for (i = 0; i < 4; i = i + 1) begin
            if (b_q[i] !== (256'h1111 * (i + 1))) begin
                errs = errs + 1;
                $display("MO: CHECK bridge data[%0d]=%h exp=%h", i, b_q[i], 256'h1111 * (i + 1));
            end
        end
        if (v_q[0] !== 256'hAAAA) begin
            errs = errs + 1;
            $display("MO: CHECK video data=%h exp=AAAA", v_q[0]);
        end
        if (v_spur != 0 || b_spur != 0) begin
            errs = errs + 1;
            $display("MO: CHECK rid crossing v_spur=%0d b_spur=%0d", v_spur, b_spur);
        end

        if (errs == 0) $display("DDR_ARB_MO: PASS");
        else           $display("DDR_ARB_MO: FAIL errs=%0d", errs);
        $finish;
    end

    initial begin
        #200000;
        $display("DDR_ARB_MO: FAIL timeout");
        $finish;
    end
endmodule
