// tb_axi_cdc —— 三座 AXI4 CDC 桥的两时钟功能闸门（iverilog）。
//
// 口径：
//   · sclk = 100MHz（10.000ns），dclk = 108MHz（9.259ns）—— 非整数比，真实跨域。
//   · 目的侧 ready 由 LFSR 随机拉低（压 FIFO 满/空）；主机侧 B/R ready 在等待窗口内置 1。
//   · LSU：32 笔单拍写 → 32 笔单拍读回，逐字节比对；
//         再发 1 笔 8-beat 读（AR len=7），比对 8 拍数据与 rlast。
//   · IO ：16 笔 32-bit 单拍写 → 读回比对。
//   · Fetch：2 笔 8-beat 读（AR len=7），比对预置数据与 rlast。
//   · 任一 mismatch / timeout → $display("FAIL ...") + $finish(1)。
`timescale 1ns/1ps

module tb_axi_cdc;
    reg sclk = 1'b0;
    reg dclk = 1'b0;
    always #5.000 sclk = ~sclk;          // 100 MHz
`ifdef FAST_DCLK
    always #1.250 dclk = ~dclk;          // 400 MHz，负对照加速暴露无同步器
`else
    always #4.630 dclk = ~dclk;          // 108 MHz
`endif

    reg srst = 1'b1;
    reg drst = 1'b1;
    initial begin
        #50 srst = 1'b0;
        #3   drst = 1'b0;
    end

    // 目的侧随机 ready（~7/8 概率为 1）
    reg [15:0] lfsr = 16'hACE1;
    always @(posedge dclk) lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    wire d_rdy = lfsr[0] | lfsr[2] | lfsr[5];

    integer errors = 0;
    integer i;
    reg [63:0] rdq [0:15];

    // =====================================================================
    // LSU bridge
    // =====================================================================
    reg         l_awvalid; reg  [31:0] l_awaddr; reg [7:0] l_awlen;
    reg  [2:0]  l_awsize;  reg  [1:0]  l_awburst; reg [3:0] l_awcache; reg [2:0] l_awprot;
    wire        l_awready;
    reg         l_wvalid;  reg  [63:0] l_wdata; reg [7:0] l_wstrb; reg l_wlast;
    wire        l_wready;
    wire        l_bvalid;  reg         l_bready; wire [1:0] l_bresp;
    reg         l_arvalid; reg  [31:0] l_araddr; reg [7:0] l_arlen;
    reg  [2:0]  l_arsize;  reg  [1:0]  l_arburst; reg [3:0] l_arcache; reg [2:0] l_arprot;
    wire        l_arready;
    wire        l_rvalid;  reg         l_rready; wire [63:0] l_rdata; wire [1:0] l_rresp; wire l_rlast;

    wire        dl_awvalid; reg        dl_awready; wire [31:0] dl_awaddr; wire [7:0] dl_awlen;
    wire [2:0]  dl_awsize;  wire [1:0] dl_awburst; wire [3:0] dl_awcache; wire [2:0] dl_awprot;
    wire        dl_wvalid;  reg        dl_wready;  wire [63:0] dl_wdata; wire [7:0] dl_wstrb; wire dl_wlast;
    reg         dl_bvalid;  wire       dl_bready;  reg  [1:0]  dl_bresp;
    wire        dl_arvalid; reg        dl_arready; wire [31:0] dl_araddr; wire [7:0] dl_arlen;
    wire [2:0]  dl_arsize;  wire [1:0] dl_arburst; wire [3:0] dl_arcache; wire [2:0] dl_arprot;
    reg         dl_rvalid;  wire       dl_rready;  reg  [63:0] dl_rdata; reg [1:0] dl_rresp; reg dl_rlast;

    axi4_cdc_lsu u_lsu (
        .sclk(sclk), .srst(srst), .dclk(dclk), .drst(drst),
        .s_awvalid(l_awvalid), .s_awready(l_awready), .s_awaddr(l_awaddr),
        .s_awlen(l_awlen), .s_awsize(l_awsize), .s_awburst(l_awburst),
        .s_awcache(l_awcache), .s_awprot(l_awprot),
        .s_wvalid(l_wvalid), .s_wready(l_wready), .s_wdata(l_wdata),
        .s_wstrb(l_wstrb), .s_wlast(l_wlast),
        .s_bvalid(l_bvalid), .s_bready(l_bready), .s_bresp(l_bresp),
        .s_arvalid(l_arvalid), .s_arready(l_arready), .s_araddr(l_araddr),
        .s_arlen(l_arlen), .s_arsize(l_arsize), .s_arburst(l_arburst),
        .s_arcache(l_arcache), .s_arprot(l_arprot),
        .s_rvalid(l_rvalid), .s_rready(l_rready), .s_rdata(l_rdata),
        .s_rresp(l_rresp), .s_rlast(l_rlast),
        .d_awvalid(dl_awvalid), .d_awready(dl_awready), .d_awaddr(dl_awaddr),
        .d_awlen(dl_awlen), .d_awsize(dl_awsize), .d_awburst(dl_awburst),
        .d_awcache(dl_awcache), .d_awprot(dl_awprot),
        .d_wvalid(dl_wvalid), .d_wready(dl_wready), .d_wdata(dl_wdata),
        .d_wstrb(dl_wstrb), .d_wlast(dl_wlast),
        .d_bvalid(dl_bvalid), .d_bready(dl_bready), .d_bresp(dl_bresp),
        .d_arvalid(dl_arvalid), .d_arready(dl_arready), .d_araddr(dl_araddr),
        .d_arlen(dl_arlen), .d_arsize(dl_arsize), .d_arburst(dl_arburst),
        .d_arcache(dl_arcache), .d_arprot(dl_arprot),
        .d_rvalid(dl_rvalid), .d_rready(dl_rready), .d_rdata(dl_rdata),
        .d_rresp(dl_rresp), .d_rlast(dl_rlast)
    );

    // LSU 目的侧从机 + 64-bit 内存
    reg [63:0] lmem [0:255];
    reg        law_pending, lw_pending;
    reg [31:0] law_addr_q;
    reg [63:0] lw_data_q;
    reg        lr_busy;
    reg [31:0] lr_addr_q;
    reg [7:0]  lr_len_q, lr_beat;
    assign dl_awready = d_rdy & ~law_pending;
    assign dl_arready = d_rdy & ~lr_busy;
    assign dl_wready  = d_rdy & ~lw_pending;

    always @(posedge dclk) begin
        if (drst) begin
            law_pending <= 0; lw_pending <= 0; law_addr_q <= 0; lw_data_q <= 0;
            dl_bvalid <= 0; dl_bresp <= 0;
            lr_busy <= 0; lr_addr_q <= 0; lr_len_q <= 0; lr_beat <= 0;
            dl_rvalid <= 0; dl_rdata <= 0; dl_rresp <= 0; dl_rlast <= 0;
        end else begin
            if (dl_awvalid && dl_awready) begin
                law_pending <= 1; law_addr_q <= dl_awaddr;
            end
            if (dl_wvalid && dl_wready) begin
                lw_pending <= 1; lw_data_q <= dl_wdata;
            end
            if (law_pending && lw_pending && !dl_bvalid) begin
                lmem[law_addr_q[9:3]] <= lw_data_q;
                law_pending <= 0; lw_pending <= 0;
                dl_bvalid <= 1; dl_bresp <= 2'b00;
            end
            if (dl_bvalid && dl_bready) dl_bvalid <= 0;

            if (dl_arvalid && dl_arready) begin
                lr_busy <= 1; lr_addr_q <= dl_araddr; lr_len_q <= dl_arlen; lr_beat <= 0;
            end
            if (lr_busy && !dl_rvalid) begin
                dl_rvalid <= 1;
                dl_rdata  <= lmem[lr_addr_q[9:3] + lr_beat];
                dl_rresp  <= 2'b00;
                dl_rlast  <= (lr_beat == lr_len_q);
            end
            if (dl_rvalid && dl_rready) begin
                if (lr_beat == lr_len_q) begin
                    lr_busy <= 0; dl_rvalid <= 0; dl_rlast <= 0;
                end else begin
                    lr_beat <= lr_beat + 1;
                    dl_rdata <= lmem[lr_addr_q[9:3] + lr_beat + 1];
                    dl_rlast <= ((lr_beat + 1) == lr_len_q);
                end
            end
        end
    end

    // =====================================================================
    // IO bridge (32-bit, single beat)
    // =====================================================================
    reg         io_awvalid; reg [31:0] io_awaddr; reg [2:0] io_awsize; reg [3:0] io_awcache; reg [2:0] io_awprot;
    wire        io_awready;
    reg         io_wvalid;  reg [31:0] io_wdata;  reg [3:0] io_wstrb; reg io_wlast;
    wire        io_wready;
    wire        io_bvalid;  reg        io_bready; wire [1:0] io_bresp;
    reg         io_arvalid; reg [31:0] io_araddr; reg [2:0] io_arsize; reg [3:0] io_arcache; reg [2:0] io_arprot;
    wire        io_arready;
    wire        io_rvalid;  reg        io_rready; wire [31:0] io_rdata; wire [1:0] io_rresp; wire io_rlast;

    wire        dio_awvalid; reg        dio_awready; wire [31:0] dio_awaddr; wire [2:0] dio_awsize; wire [3:0] dio_awcache; wire [2:0] dio_awprot;
    wire        dio_wvalid;  reg        dio_wready;  wire [31:0] dio_wdata;  wire [3:0] dio_wstrb; wire dio_wlast;
    reg         dio_bvalid;  wire       dio_bready;  reg  [1:0]  dio_bresp;
    wire        dio_arvalid; reg        dio_arready; wire [31:0] dio_araddr; wire [2:0] dio_arsize; wire [3:0] dio_arcache; wire [2:0] dio_arprot;
    reg         dio_rvalid;  wire       dio_rready;  reg  [31:0] dio_rdata;  reg [1:0] dio_rresp; reg dio_rlast;

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
        .d_awvalid(dio_awvalid), .d_awready(dio_awready), .d_awaddr(dio_awaddr),
        .d_awsize(dio_awsize), .d_awcache(dio_awcache), .d_awprot(dio_awprot),
        .d_wvalid(dio_wvalid), .d_wready(dio_wready), .d_wdata(dio_wdata),
        .d_wstrb(dio_wstrb), .d_wlast(dio_wlast),
        .d_bvalid(dio_bvalid), .d_bready(dio_bready), .d_bresp(dio_bresp),
        .d_arvalid(dio_arvalid), .d_arready(dio_arready), .d_araddr(dio_araddr),
        .d_arsize(dio_arsize), .d_arcache(dio_arcache), .d_arprot(dio_arprot),
        .d_rvalid(dio_rvalid), .d_rready(dio_rready), .d_rdata(dio_rdata),
        .d_rresp(dio_rresp), .d_rlast(dio_rlast)
    );

    reg [31:0] iomem [0:255];
    reg        ioaw_pending, iow_pending;
    reg [31:0] ioaw_addr_q, iow_data_q;
    reg        ior_busy;
    reg [31:0] ior_addr_q;
    assign dio_awready = d_rdy & ~ioaw_pending;
    assign dio_wready  = d_rdy & ~iow_pending;
    assign dio_arready = d_rdy & ~ior_busy;
    always @(posedge dclk) begin
        if (drst) begin
            ioaw_pending <= 0; iow_pending <= 0; ioaw_addr_q <= 0; iow_data_q <= 0;
            dio_bvalid <= 0; dio_bresp <= 0;
            ior_busy <= 0; ior_addr_q <= 0; dio_rvalid <= 0; dio_rdata <= 0; dio_rresp <= 0; dio_rlast <= 0;
        end else begin
            if (dio_awvalid && dio_awready) begin ioaw_pending <= 1; ioaw_addr_q <= dio_awaddr; end
            if (dio_wvalid && dio_wready) begin iow_pending <= 1; iow_data_q <= dio_wdata; end
            if (ioaw_pending && iow_pending && !dio_bvalid) begin
                iomem[ioaw_addr_q[9:2]] <= iow_data_q;
                ioaw_pending <= 0; iow_pending <= 0; dio_bvalid <= 1; dio_bresp <= 2'b00;
            end
            if (dio_bvalid && dio_bready) dio_bvalid <= 0;
            if (dio_arvalid && dio_arready) begin ior_busy <= 1; ior_addr_q <= dio_araddr; end
            if (ior_busy && !dio_rvalid) begin
                dio_rvalid <= 1; dio_rdata <= iomem[ior_addr_q[9:2]]; dio_rresp <= 2'b00; dio_rlast <= 1;
            end
            if (dio_rvalid && dio_rready) begin ior_busy <= 0; dio_rvalid <= 0; end
        end
    end

    // =====================================================================
    // Fetch bridge (64-bit, bursts)
    // =====================================================================
    reg         f_arvalid; reg [31:0] f_araddr; reg [7:0] f_arlen; reg [2:0] f_arsize; reg [1:0] f_arburst; reg [3:0] f_arcache; reg [2:0] f_arprot;
    wire        f_arready;
    wire        f_rvalid;  reg        f_rready; wire [63:0] f_rdata; wire [1:0] f_rresp; wire f_rlast;
    wire        df_arvalid; reg        df_arready; wire [31:0] df_araddr; wire [7:0] df_arlen; wire [2:0] df_arsize; wire [1:0] df_arburst; wire [3:0] df_arcache; wire [2:0] df_arprot;
    reg         df_rvalid;  wire       df_rready;  reg [63:0] df_rdata; reg [1:0] df_rresp; reg df_rlast;

    axi4_cdc_fetch u_fetch (
        .sclk(sclk), .srst(srst), .dclk(dclk), .drst(drst),
        .s_arvalid(f_arvalid), .s_arready(f_arready), .s_araddr(f_araddr),
        .s_arlen(f_arlen), .s_arsize(f_arsize), .s_arburst(f_arburst),
        .s_arcache(f_arcache), .s_arprot(f_arprot),
        .s_rvalid(f_rvalid), .s_rready(f_rready), .s_rdata(f_rdata),
        .s_rresp(f_rresp), .s_rlast(f_rlast),
        .d_arvalid(df_arvalid), .d_arready(df_arready), .d_araddr(df_araddr),
        .d_arlen(df_arlen), .d_arsize(df_arsize), .d_arburst(df_arburst),
        .d_arcache(df_arcache), .d_arprot(df_arprot),
        .d_rvalid(df_rvalid), .d_rready(df_rready), .d_rdata(df_rdata),
        .d_rresp(df_rresp), .d_rlast(df_rlast)
    );

    reg [63:0] fmem [0:255];
    reg        fr_busy;
    reg [31:0] fr_addr_q;
    reg [7:0]  fr_len_q, fr_beat;
    assign df_arready = d_rdy & ~fr_busy;
    always @(posedge dclk) begin
        if (drst) begin
            fr_busy <= 0; fr_addr_q <= 0; fr_len_q <= 0; fr_beat <= 0;
            df_rvalid <= 0; df_rdata <= 0; df_rresp <= 0; df_rlast <= 0;
        end else begin
            if (df_arvalid && df_arready) begin fr_busy <= 1; fr_addr_q <= df_araddr; fr_len_q <= df_arlen; fr_beat <= 0; end
            if (fr_busy && !df_rvalid) begin
                df_rvalid <= 1; df_rdata <= fmem[fr_addr_q[9:3] + fr_beat];
                df_rresp <= 2'b00; df_rlast <= (fr_beat == fr_len_q);
            end
            if (df_rvalid && df_rready) begin
                if (fr_beat == fr_len_q) begin fr_busy <= 0; df_rvalid <= 0; df_rlast <= 0; end
                else begin
                    fr_beat <= fr_beat + 1;
                    df_rdata <= fmem[fr_addr_q[9:3] + fr_beat + 1];
                    df_rlast <= ((fr_beat + 1) == fr_len_q);
                end
            end
        end
    end

    // =====================================================================
    // 主机侧任务（negdege 驱动 / posedge 采样）
    // =====================================================================
    task lsu_write(input [31:0] a, input [63:0] d);
        reg aw_done, w_done;
        begin
            @(negedge sclk);
            l_awvalid = 1; l_awaddr = a; l_awlen = 0; l_awsize = 3; l_awburst = 1; l_awcache = 0; l_awprot = 0;
            l_wvalid = 1; l_wdata = d; l_wstrb = 8'hFF; l_wlast = 1;
            aw_done = 0; w_done = 0;
            while (!(aw_done && w_done)) begin
                @(posedge sclk);
                if (l_awready) aw_done = 1;
                if (l_wready)  w_done  = 1;
            end
            @(negedge sclk); l_awvalid = 0; l_wvalid = 0;
            l_bready = 1;
            @(posedge sclk);
            while (!l_bvalid) @(posedge sclk);
            @(negedge sclk); l_bready = 0;
        end
    endtask

    task lsu_rd(input [31:0] a, input [7:0] len, input integer n);
        integer k; reg done;
        begin
            @(negedge sclk);
            l_arvalid = 1; l_araddr = a; l_arlen = len; l_arsize = 3; l_arburst = 1; l_arcache = 0; l_arprot = 0;
            done = 0;
            while (!done) begin
                @(posedge sclk);
                if (l_arready) done = 1;
            end
            @(negedge sclk); l_arvalid = 0; l_rready = 1;
            for (k = 0; k < n; k = k + 1) begin
                @(posedge sclk);
                while (!l_rvalid) @(posedge sclk);
                rdq[k] = l_rdata;
                if (k == n-1 && !l_rlast) begin
                    $display("FAIL LSU rlast missing at beat %0d", k); errors = errors + 1;
                end
            end
            @(negedge sclk); l_rready = 0;
        end
    endtask

    task io_write(input [31:0] a, input [31:0] d);
        reg aw_done, w_done;
        begin
            @(negedge sclk);
            io_awvalid = 1; io_awaddr = a; io_awsize = 2; io_awcache = 0; io_awprot = 0;
            io_wvalid = 1; io_wdata = d; io_wstrb = 4'hF; io_wlast = 1;
            aw_done = 0; w_done = 0;
            while (!(aw_done && w_done)) begin
                @(posedge sclk);
                if (io_awready) aw_done = 1;
                if (io_wready)  w_done  = 1;
            end
            @(negedge sclk); io_awvalid = 0; io_wvalid = 0;
            io_bready = 1;
            @(posedge sclk);
            while (!io_bvalid) @(posedge sclk);
            @(negedge sclk); io_bready = 0;
        end
    endtask

    task io_read(input [31:0] a, output [31:0] d);
        reg done;
        begin
            @(negedge sclk);
            io_arvalid = 1; io_araddr = a; io_arsize = 2; io_arcache = 0; io_arprot = 0;
            done = 0;
            while (!done) begin @(posedge sclk); if (io_arready) done = 1; end
            @(negedge sclk); io_arvalid = 0; io_rready = 1;
            @(posedge sclk);
            while (!io_rvalid) @(posedge sclk);
            d = io_rdata;
            @(negedge sclk); io_rready = 0;
        end
    endtask

    task fetch_burst(input [31:0] a, input [7:0] len, input integer n);
        integer k; reg done;
        begin
            @(negedge sclk);
            f_arvalid = 1; f_araddr = a; f_arlen = len; f_arsize = 3; f_arburst = 1; f_arcache = 0; f_arprot = 0;
            done = 0;
            while (!done) begin @(posedge sclk); if (f_arready) done = 1; end
            @(negedge sclk); f_arvalid = 0; f_rready = 1;
            for (k = 0; k < n; k = k + 1) begin
                @(posedge sclk);
                while (!f_rvalid) @(posedge sclk);
                rdq[k] = f_rdata;
                if (k == n-1 && !f_rlast) begin
                    $display("FAIL FETCH rlast missing at beat %0d", k); errors = errors + 1;
                end
            end
            @(negedge sclk); f_rready = 0;
        end
    endtask

    // =====================================================================
    // 主测试
    // =====================================================================
    reg [31:0] iord;
    integer k;

    initial begin
        l_awvalid = 0; l_wvalid = 0; l_bready = 0; l_arvalid = 0; l_rready = 0;
        io_awvalid = 0; io_wvalid = 0; io_bready = 0; io_arvalid = 0; io_rready = 0;
        f_arvalid = 0; f_rready = 0;
        for (k = 0; k < 256; k = k + 1) begin lmem[k] = 64'h0; iomem[k] = 32'h0; fmem[k] = 64'h0; end
        for (k = 0; k < 32; k = k + 1) lmem[k] = 64'h1000_0000_0000_0000 + k;

        @(negedge srst);
        repeat (5) @(posedge sclk);

        // ---- LSU 单拍写/读 ----
        for (k = 0; k < 32; k = k + 1)
            lsu_write(k*8, 64'hA000_0000_0000_0000 + (k * 64'h0101_0101));
        for (k = 0; k < 32; k = k + 1) begin
            lsu_rd(k*8, 0, 1);
            if (rdq[0] !== (64'hA000_0000_0000_0000 + (k * 64'h0101_0101))) begin
                $display("FAIL LSU rd[%0d] got %h", k, rdq[0]); errors = errors + 1;
            end
        end
        $display("LSU single-beat R/W done (%0d errors)", errors);

        // ---- LSU 8-beat 读（先直接预置从机内存，避免被上面的写覆盖）----
        for (k = 0; k < 8; k = k + 1) lmem[k] = 64'h1000_0000_0000_0000 + k;
        lsu_rd(0, 7, 8);
        for (k = 0; k < 8; k = k + 1)
            if (rdq[k] !== (64'h1000_0000_0000_0000 + k)) begin
                $display("FAIL LSU burst[%0d] got %h", k, rdq[k]); errors = errors + 1;
            end
        $display("LSU 8-beat read done (%0d errors)", errors);

        // ---- IO 单拍写/读 ----
        for (k = 0; k < 16; k = k + 1) io_write(k*4, 32'hB000_0000 + k*16'h0101);
        for (k = 0; k < 16; k = k + 1) begin
            io_read(k*4, iord);
            if (iord !== (32'hB000_0000 + k*16'h0101)) begin
                $display("FAIL IO rd[%0d] got %h", k, iord); errors = errors + 1;
            end
        end
        $display("IO R/W done (%0d errors)", errors);

        // ---- Fetch 8-beat 突发 ----
        for (k = 0; k < 8; k = k + 1) fmem[k] = 64'hC000_0000_0000_0000 + k;
        fetch_burst(0, 7, 8);
        for (k = 0; k < 8; k = k + 1)
            if (rdq[k] !== (64'hC000_0000_0000_0000 + k)) begin
                $display("FAIL FETCH[%0d] got %h", k, rdq[k]); errors = errors + 1;
            end
        $display("FETCH burst done (%0d errors)", errors);

        if (errors == 0) $display("PASS tb_axi_cdc");
        else             $display("FAIL tb_axi_cdc errors=%0d", errors);
        $finish;
    end

    // 全局 timeout
    initial begin
        #200000;
        $display("FAIL tb_axi_cdc timeout");
        $finish;
    end
endmodule
