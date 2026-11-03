//=============================================================================
// tb_ddr_arbiter: U1 闸门 —— 桥(DDR3Bridge, ID=0) vs 视频(fram_buf, ID=1)
//                 的 256-bit 简化 AXI 2:1 仲裁
//
// 检查项：
//   1) 桥写 0x100=0x1111、视频写 0x200=0x2222；桥读 0x100、视频读 0x200，
//      数据与 RID 都对（b_rid=0 / v_rid=1，R 通道按 rid 分流）
//   2) 视频 4 拍 burst（awlen=3）写 0x300 起，数据 0x3333+i；
//      桥逐拍读 0x300/0x308/0x310/0x318（地址每 256-bit beat +8）
//   3) v_wlast / b_wlast 脉冲计数：每笔写完成恰好一次（归属正确）
//   4) 可选：桥读在途时视频 AR 挂起，dbg_v_ar_wait 必须增长
//   5) RID 分流监视：v_rvalid 只允许带 rid=1，b_rvalid 只允许带 rid!=1
//      （负对照把 v_rvalid 改成 m_rvalid 时，这里会抓到桥读数据串到视频侧）
//
// 先红后绿（负对照）：
//   把 `assign v_rvalid = m_rvalid && (m_rid == 4'h1);` 改成
//   `assign v_rvalid = m_rvalid;`，桥读期间 v_rvalid 会带 rid=0 冒出来
//   => v_spur>0 => `DDR_ARB: FAIL`；还原后 PASS。
//
// 驱动约定：源保持 valid 直到握手（AW 到 awready、每个 W 到 wready、
//   AR 到 arready、R 到 rready），全部在 negedge 更新、posedge 采样。
//=============================================================================
`timescale 1ns/1ps

module tb_ddr_arbiter;
    reg clk = 0, rstn = 0;
    always #4 clk = ~clk;               // 125 MHz

    localparam AW = 28;

    //-------------------------------------------------------------------------
    // 桥侧（ID=0）：单拍写、单拍读
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
    reg           b_rready = 1;

    //-------------------------------------------------------------------------
    // 视频侧（ID=1）：可多拍 burst
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
    reg           v_rready = 1;

    //-------------------------------------------------------------------------
    // DDR IP 简化口
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

    ddr_arbiter_2to1 #(.AW(AW)) dut (
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

    ddr_model #(.AW(AW)) ddr (
        .clk(clk), .rstn(rstn),
        .awaddr(m_awaddr), .awlen(m_awlen), .awvalid(m_awvalid), .awready(m_awready),
        .wdata(m_wdata), .wstrb(m_wstrb), .wvalid(m_wvalid), .wready(m_wready),
        .wusero_last(m_wusero_last),
        .araddr(m_araddr), .arlen(m_arlen), .aruser_id(m_aruser_id),
        .arvalid(m_arvalid), .arready(m_arready),
        .rdata(m_rdata), .rid(m_rid), .rlast(m_rlast), .rvalid(m_rvalid), .rready(m_rready)
    );

    //-------------------------------------------------------------------------
    // 观测：wlast 计数 + RID 分流监视
    //-------------------------------------------------------------------------
    integer b_wl_cnt = 0, v_wl_cnt = 0;
    integer v_spur = 0, b_spur = 0;
    always @(posedge clk) begin
        if (rstn) begin
            if (b_wlast) b_wl_cnt <= b_wl_cnt + 1;
            if (v_wlast) v_wl_cnt <= v_wl_cnt + 1;
            // 视频口只允许收 rid=1；桥口只允许收 rid!=1
            if (v_rvalid && (v_rid !== 4'h1)) v_spur <= v_spur + 1;
            if (b_rvalid && (b_rid === 4'h1)) b_spur <= b_spur + 1;
        end
    end

    integer errs = 0;
    reg [255:0] got;
    reg [3:0]   got_id;
    reg [31:0]  dbg_t0;
    integer i, k;

    //-------------------------------------------------------------------------
    // 激励任务：全部保持 valid 直到握手，negedge 更新、posedge 采样
    //-------------------------------------------------------------------------
    task b_write(input [AW-1:0] a, input [255:0] d);
        begin
            @(negedge clk);
            b_awaddr = a; b_awlen = 4'd0; b_awvalid = 1'b1;
            b_wdata  = d; b_wstrb = 32'hFFFF_FFFF; b_wvalid = 1'b1;
            while (!b_awready) @(negedge clk);
            @(posedge clk);                     // AW 握手
            @(negedge clk);
            b_awvalid = 1'b0;
            while (!b_wready) @(negedge clk);
            @(posedge clk);                     // 唯一一拍 W 握手
            @(negedge clk);
            b_wvalid = 1'b0;
        end
    endtask

    task v_write_burst(input [AW-1:0] a, input [3:0] len, input [255:0] d0);
        begin
            @(negedge clk);
            v_awaddr = a; v_awlen = len; v_awvalid = 1'b1;
            v_wdata  = d0; v_wstrb = 32'hFFFF_FFFF; v_wvalid = 1'b1;
            while (!v_awready) @(negedge clk);
            @(posedge clk);                     // AW 握手
            @(negedge clk);
            v_awvalid = 1'b0;
            for (i = 0; i <= len; i = i + 1) begin
                while (!v_wready) @(negedge clk);
                @(posedge clk);                 // 第 i 拍 W 握手
                @(negedge clk);
                if (i == len) begin
                    v_wvalid = 1'b0;
                end else begin
                    v_wdata = d0 + (i + 1);     // 提前摆好下一拍
                end
            end
        end
    endtask

    // 桥侧**真实契约**的 burst：板级把 b_wvalid 接成桥的 awvalid（DDR3Bridge
    // 用户口没有 WVALID，写数据由内部 wCdc FIFO 常备）⇒ AW 握手后 b_wvalid 必落。
    // 仲裁器必须整 burst 保持 m_wvalid；若拿 b_wvalid 逐拍门控会永远等不到数据。
    task b_write_nowv(input [AW-1:0] a, input [3:0] len, input [255:0] d0);
        begin
            @(negedge clk);
            b_awaddr = a; b_awlen = len; b_awvalid = 1'b1;
            b_wdata  = d0; b_wstrb = 32'hFFFF_FFFF; b_wvalid = 1'b1;
            while (!b_awready) @(negedge clk);
            @(posedge clk);                     // AW 握手
            @(negedge clk);
            b_awvalid = 1'b0;
            b_wvalid  = 1'b0;                   // 板级语义：b_wvalid == awvalid
            for (i = 0; i <= len; i = i + 1) begin
                while (!b_wready) @(negedge clk);
                @(posedge clk);                 // 第 i 拍 W 握手（m_wvalid 由仲裁器保持）
                @(negedge clk);
                if (i != len) b_wdata = d0 + (i + 1);
            end
        end
    endtask

    task b_read(input [AW-1:0] a, output [255:0] d, output [3:0] id);
        begin
            @(negedge clk);
            b_araddr = a; b_arlen = 4'd0; b_arvalid = 1'b1;
            while (!b_arready) @(negedge clk);
            @(posedge clk);                     // AR 握手
            @(negedge clk);
            b_arvalid = 1'b0;
            while (!b_rvalid) @(negedge clk);
            d  = b_rdata;
            id = b_rid;
            @(posedge clk);                     // R 握手（rready 恒 1）
            @(negedge clk);
        end
    endtask

    task v_read(input [AW-1:0] a, output [255:0] d, output [3:0] id);
        begin
            @(negedge clk);
            v_araddr = a; v_arlen = 4'd0; v_arvalid = 1'b1;
            while (!v_arready) @(negedge clk);
            @(posedge clk);                     // AR 握手
            @(negedge clk);
            v_arvalid = 1'b0;
            while (!v_rvalid) @(negedge clk);
            d  = v_rdata;
            id = v_rid;
            @(posedge clk);                     // R 握手（rready 恒 1）
            @(negedge clk);
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    initial begin
        repeat (5) @(posedge clk);
        rstn = 1;
        repeat (3) @(posedge clk);

        //---- 1) 基础写 + RID 分流读 -------------------------------------
        b_write(28'h100, 256'h1111);
        v_write_burst(28'h200, 4'd0, 256'h2222);
        repeat (8) @(negedge clk);
        if (b_wl_cnt !== 1) begin
            errs = errs + 1;
            $display("DDR_ARB: CHECK b_wl_cnt=%0d exp=1", b_wl_cnt);
        end
        if (v_wl_cnt !== 1) begin
            errs = errs + 1;
            $display("DDR_ARB: CHECK v_wl_cnt=%0d exp=1", v_wl_cnt);
        end

        b_read(28'h100, got, got_id);
        if (got !== 256'h1111) begin
            errs = errs + 1;
            $display("DDR_ARB: CHECK bridge rd 0x100 got=%h exp=1111", got);
        end
        if (got_id !== 4'h0) begin
            errs = errs + 1;
            $display("DDR_ARB: CHECK bridge rid=%0d exp=0", got_id);
        end

        v_read(28'h200, got, got_id);
        if (got !== 256'h2222) begin
            errs = errs + 1;
            $display("DDR_ARB: CHECK video rd 0x200 got=%h exp=2222", got);
        end
        if (got_id !== 4'h1) begin
            errs = errs + 1;
            $display("DDR_ARB: CHECK video rid=%0d exp=1", got_id);
        end

        //---- 2) 视频 4 拍 burst（len=3），桥逐拍读回 -------------------
        v_write_burst(28'h300, 4'd3, 256'h3333);
        repeat (8) @(negedge clk);
        if (v_wl_cnt !== 2) begin
            errs = errs + 1;
            $display("DDR_ARB: CHECK v_wl_cnt=%0d exp=2 (burst)", v_wl_cnt);
        end
        for (k = 0; k < 4; k = k + 1) begin
            b_read(28'h300 + (k * 8), got, got_id);
            if (got !== (256'h3333 + k)) begin
                errs = errs + 1;
                $display("DDR_ARB: CHECK burst beat %0d addr=%h got=%h exp=%h",
                         k, 28'h300 + (k * 8), got, 256'h3333 + k);
            end
            if (got_id !== 4'h0) begin
                errs = errs + 1;
                $display("DDR_ARB: CHECK burst rid=%0d exp=0", got_id);
            end
        end

        //---- 2b) 桥侧 W 空拍 burst：数据必须逐拍正确、wlast 只一次 ----
        b_write_nowv(28'h400, 4'd3, 256'h4444);
        repeat (8) @(negedge clk);
        if (b_wl_cnt !== 2) begin
            errs = errs + 1;
            $display("DDR_ARB: CHECK b_wl_cnt=%0d exp=2 (nowv burst)", b_wl_cnt);
        end
        if (v_wl_cnt !== 2) begin
            errs = errs + 1;
            $display("DDR_ARB: CHECK v_wl_cnt=%0d exp=2 (gap burst cross)", v_wl_cnt);
        end
        for (k = 0; k < 4; k = k + 1) begin
            b_read(28'h400 + (k * 8), got, got_id);
            if (got !== (256'h4444 + k)) begin
                errs = errs + 1;
                $display("DDR_ARB: CHECK nowv beat %0d addr=%h got=%h exp=%h",
                         k, 28'h400 + (k * 8), got, 256'h4444 + k);
            end
        end

        //---- 3) 可选：桥读在途时视频 AR 挂起，等待计数应增长 ---------
        @(negedge clk);
        b_araddr = 28'h100; b_arlen = 4'd0; b_arvalid = 1'b1;
        while (!b_arready) @(negedge clk);
        @(posedge clk);                         // 桥 AR 握手
        @(negedge clk);
        b_arvalid = 1'b0;

        @(negedge clk);
        v_araddr = 28'h200; v_arlen = 4'd0; v_arvalid = 1'b1;
        dbg_t0 = dbg_v_ar_wait;
        repeat (4) @(negedge clk);
        if (dbg_v_ar_wait <= dbg_t0) begin
            errs = errs + 1;
            $display("DDR_ARB: CHECK dbg_v_ar_wait stuck at %0d", dbg_v_ar_wait);
        end

        while (!b_rvalid) @(negedge clk);
        if (b_rdata !== 256'h1111) begin
            errs = errs + 1;
            $display("DDR_ARB: CHECK in-flight bridge rd got=%h exp=1111", b_rdata);
        end
        @(posedge clk);
        @(negedge clk);

        while (!v_arready) @(negedge clk);
        @(posedge clk);                         // 视频 AR 握手（桥读让出后）
        @(negedge clk);
        v_arvalid = 1'b0;
        while (!v_rvalid) @(negedge clk);
        if (v_rdata !== 256'h2222) begin
            errs = errs + 1;
            $display("DDR_ARB: CHECK pending video rd got=%h exp=2222", v_rdata);
        end
        if (v_rid !== 4'h1) begin
            errs = errs + 1;
            $display("DDR_ARB: CHECK pending video rid=%0d exp=1", v_rid);
        end
        @(posedge clk);
        @(negedge clk);

        repeat (4) @(negedge clk);

        //---- 判定 -------------------------------------------------------
        if ((errs == 0) && (v_spur == 0) && (b_spur == 0) &&
            (b_wl_cnt == 2) && (v_wl_cnt == 2))
            $display("DDR_ARB: PASS");
        else
            $display("DDR_ARB: FAIL errs=%0d v_spur=%0d b_spur=%0d b_wl=%0d v_wl=%0d",
                     errs, v_spur, b_spur, b_wl_cnt, v_wl_cnt);
        $finish;
    end

    // 看门狗：任何握手挂死都不能让闸门静默通过
    initial begin
        #200000;
        $display("DDR_ARB: FAIL timeout");
        $finish;
    end
endmodule
