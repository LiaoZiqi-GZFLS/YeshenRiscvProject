// tb_axi_cdc_stream —— IO 桥持续流压力闸门：64 笔背靠背读 + 64 笔背靠背写。
// 目的：把 AR/R/W/B FIFO 灌满（旧 tb_axi_cdc 每次等 B/R，占用很低）。
`timescale 1ns/1ps
module tb_axi_cdc_stream;
    reg sclk = 0, dclk = 0;
    always #5.000 sclk = ~sclk;
    always #4.630 dclk = ~dclk;
    reg srst = 1, drst = 1;
    initial begin #50 srst = 0; #3 drst = 0; end

    reg [15:0] lfsr = 16'h1234;
    always @(posedge dclk) lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
    wire d_rdy = lfsr[0] | lfsr[2] | lfsr[5];

    // source side
    reg         io_awvalid, io_wvalid, io_bready, io_arvalid, io_rready;
    reg  [31:0] io_awaddr, io_wdata, io_araddr;
    reg  [2:0]  io_awsize, io_arsize;
    reg  [3:0]  io_awcache, io_arcache, io_wstrb;
    reg  [2:0]  io_awprot, io_arprot;
    reg         io_wlast;
    wire        io_awready, io_wready, io_bvalid, io_arready, io_rvalid, io_rlast;
    wire [31:0] io_rdata; wire [1:0] io_bresp, io_rresp;

    // dest side
    wire        d_awvalid, d_wvalid, d_bready, d_arvalid, d_rready;
    wire [31:0] d_awaddr, d_wdata, d_araddr;
    wire [2:0]  d_awsize, d_arsize, d_awprot, d_arprot;
    wire [3:0]  d_awcache, d_arcache, d_wstrb;
    wire        d_wlast;
    wire        d_awready, d_wready, d_arready;
    reg         d_bvalid, d_rvalid, d_rlast;
    reg  [31:0] d_rdata; reg [1:0] d_bresp, d_rresp;

    axi4_cdc_io u_io (
        .sclk(sclk), .srst(srst), .dclk(dclk), .drst(drst),
        .s_awvalid(io_awvalid), .s_awready(io_awready), .s_awaddr(io_awaddr),
        .s_awsize(io_awsize), .s_awcache(io_awcache), .s_awprot(io_awprot),
        .s_wvalid(io_wvalid), .s_wready(io_wready), .s_wdata(io_wdata),
        .s_wstrb(io_wstrb), .s_wlast(io_wlast),
        .s_bvalid(io_bvalid), .s_bready(io_bready), .s_bresp(io_bresp),
        .s_arvalid(io_arvalid), .s_arready(io_arready), .s_araddr(io_araddr),
        .s_arsize(io_arsize), .s_arcache(io_arcache), .s_arprot(io_arprot),
        .s_rvalid(io_rvalid), .s_rready(io_rready), .s_rdata(io_rdata),
        .s_rresp(io_rresp), .s_rlast(io_rlast),
        .d_awvalid(d_awvalid), .d_awready(d_awready), .d_awaddr(d_awaddr),
        .d_awsize(d_awsize), .d_awcache(d_awcache), .d_awprot(d_awprot),
        .d_wvalid(d_wvalid), .d_wready(d_wready), .d_wdata(d_wdata),
        .d_wstrb(d_wstrb), .d_wlast(d_wlast),
        .d_bvalid(d_bvalid), .d_bready(d_bready), .d_bresp(d_bresp),
        .d_arvalid(d_arvalid), .d_arready(d_arready), .d_araddr(d_araddr),
        .d_arsize(d_arsize), .d_arcache(d_arcache), .d_arprot(d_arprot),
        .d_rvalid(d_rvalid), .d_rready(d_rready), .d_rdata(d_rdata),
        .d_rresp(d_rresp), .d_rlast(d_rlast)
    );

    // 从机内存 + 单笔读写模型
    reg [31:0] mem [0:255];
    reg        aw_pending, w_pending, r_busy;
    reg [31:0] aw_addr_q, w_data_q, ar_addr_q;
    reg [3:0]  w_strb_q;
    assign d_awready = d_rdy & ~aw_pending;
    assign d_wready  = d_rdy & ~w_pending;
    assign d_arready = d_rdy & ~r_busy;

    always @(posedge dclk) begin
        if (drst) begin
            aw_pending <= 0; w_pending <= 0; r_busy <= 0;
            d_bvalid <= 0; d_bresp <= 0;
            d_rvalid <= 0; d_rdata <= 0; d_rresp <= 0; d_rlast <= 0;
        end else begin
            if (d_awvalid && d_awready) begin aw_pending <= 1; aw_addr_q <= d_awaddr; end
            if (d_wvalid && d_wready) begin w_pending <= 1; w_data_q <= d_wdata; w_strb_q <= d_wstrb; end
            if (aw_pending && w_pending && !d_bvalid) begin
                mem[aw_addr_q[9:2]] <= w_data_q;
                aw_pending <= 0; w_pending <= 0; d_bvalid <= 1; d_bresp <= 2'b00;
            end
            if (d_bvalid && d_bready) d_bvalid <= 0;
            if (d_arvalid && d_arready) begin r_busy <= 1; ar_addr_q <= d_araddr; end
            if (r_busy && !d_rvalid) begin
                d_rvalid <= 1; d_rdata <= mem[ar_addr_q[9:2]]; d_rresp <= 2'b00; d_rlast <= 1;
            end
            if (d_rvalid && d_rready) begin r_busy <= 0; d_rvalid <= 0; d_rlast <= 0; end
        end
    end

    integer errors = 0;
    integer k;
    reg [31:0] exp_data [0:63];

    task io_ar_stream(input [31:0] base, input integer n);
        integer i; reg done;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(negedge sclk);
                io_arvalid = 1; io_araddr = base + i*4; io_arsize = 2; io_arcache = 0; io_arprot = 0;
                done = 0;
                while (!done) begin @(posedge sclk); if (io_arready) done = 1; end
                @(negedge sclk); io_arvalid = 0;
            end
        end
    endtask

    task io_r_collect(input integer n);
        integer i;
        begin
            io_rready = 1;
            for (i = 0; i < n; i = i + 1) begin
                @(posedge sclk);
                while (!io_rvalid) @(posedge sclk);
                if (io_rdata !== exp_data[i]) begin
                    $display("FAIL stream rd[%0d] got %h exp %h", i, io_rdata, exp_data[i]);
                    errors = errors + 1;
                end
            end
            @(negedge sclk); io_rready = 0;
        end
    endtask

    task io_rd_one(input [31:0] a, input integer idx);
        reg done;
        begin
            @(negedge sclk);
            io_arvalid = 1; io_araddr = a; io_arsize = 2; io_arcache = 0; io_arprot = 0;
            done = 0;
            while (!done) begin @(posedge sclk); if (io_arready) done = 1; end
            @(negedge sclk); io_arvalid = 0; io_rready = 1;
            @(posedge sclk);
            while (!io_rvalid) @(posedge sclk);
            if (io_rdata !== exp_data[idx]) begin
                $display("FAIL serial rd[%0d] got %h exp %h", idx, io_rdata, exp_data[idx]);
                errors = errors + 1;
            end
            @(negedge sclk); io_rready = 0;
        end
    endtask

    task io_aw_w_stream(input [31:0] base, input integer n);
        integer i; reg ad, wd;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(negedge sclk);
                io_awvalid = 1; io_awaddr = base + i*4; io_awsize = 2; io_awcache = 0; io_awprot = 0;
                io_wvalid = 1; io_wdata = 32'hE0000000 + i; io_wstrb = 4'hF; io_wlast = 1;
                ad = 0; wd = 0;
                while (!(ad && wd)) begin
                    @(posedge sclk);
                    if (io_awready) ad = 1;
                    if (io_wready)  wd = 1;
                end
                @(negedge sclk); io_awvalid = 0; io_wvalid = 0;
            end
        end
    endtask

    integer bcount;
    always @(posedge sclk) if (!srst && io_bvalid && io_bready) bcount = bcount + 1;

    initial begin
        io_awvalid = 0; io_wvalid = 0; io_bready = 1; io_arvalid = 0; io_rready = 0;
        bcount = 0;
        for (k = 0; k < 256; k = k + 1) mem[k] = 32'h0;
        for (k = 0; k < 64; k = k + 1) begin
            mem[192 + k] = 32'hD0000000 + k;   // 读地址 0x300..0x3FC
            exp_data[k] = 32'hD0000000 + k;
        end
        @(negedge srst);
        repeat (10) @(posedge sclk);

        // 64 笔背靠背写（B 通道持续排空）
        io_aw_w_stream(32'h00000200, 64);
        repeat (20) @(posedge sclk);
        $display("stream writes done, bcount=%0d (expect 64)", bcount);
        if (bcount != 64) begin $display("FAIL stream write B count"); errors = errors + 1; end

        // 64 笔单 outstanding 读（与 CPU MMIO 的真实姿态一致）
        for (k = 0; k < 64; k = k + 1) io_rd_one(32'h00000300 + k*4, k);
        $display("serial reads done");

        if (errors == 0) $display("PASS tb_axi_cdc_stream");
        else             $display("FAIL tb_axi_cdc_stream errors=%0d", errors);
        $finish;
    end

    initial begin #500000; $display("FAIL tb_axi_cdc_stream timeout"); $finish; end
endmodule
