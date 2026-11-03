//=============================================================================
// tb_eth_service: unit gate for board/eth/eth_service.v
//
// Models (all deliberately dumb, but with the real handshakes):
//   * LiteEth slot port: one WB slave multiplexed by tgt (0=csr 1=rx 2=tx),
//     32-bit word addressed, ack one cycle after cyc&stb.
//   * csr: WRITER_SLOT/LENGTH/EV_PENDING(w1c) + READER_READY/SLOT/LENGTH/START;
//     writing START snapshots txmem[slot] -> captured frame list.
//   * DmaEngine job port: accept (addr,len), stream 8 bytes/beat from a model DDR
//     whose byte value is (addr*7 + 0x31) & 0xFF, then pulse job_done.
//
// Judges
//   [1] 300 B read at 0x9000_0007 (UNALIGNED: exercises head skip + tail drain):
//       exactly 1 frame, 358 B, header off=0 len=300 last=1, payload byte-exact
//       against the model DDR, and the job issued as (0x10000000, 320).
//   [2] 2000 B read at 0x9000_0000: exactly 2 frames (1458 + 658), off 0/1400,
//       len 1400/600, last 0/1, payload byte-exact for both.
//   [3] service returns to idle (busy=0) and n_req counts both requests.
//=============================================================================
`timescale 1ns/1ps
module tb_eth_service;

    localparam [31:0] DDR_BASE = 32'h8000_0000;

    reg clk = 0, rstn = 0, en = 0;
    always #5 clk = ~clk;                    // 100 MHz

    // ---------------- DUT ----------------
    wire [1:0]  wb_tgt;
    wire [29:0] wb_adr;
    wire [31:0] wb_dat_w;
    wire [3:0]  wb_sel;
    wire        wb_we, wb_cyc, wb_stb;
    reg  [31:0] wb_dat_r;
    reg         wb_ack;

    wire        job_valid, job_ready;
    wire [29:0] job_addr;
    wire [31:0] job_len;
    reg         job_done = 0, job_err = 0;
    reg  [63:0] dma_rd_data = 0;
    reg         dma_rd_valid = 0;
    wire        dma_rd_ready;

    wire [31:0] n_req, n_frame, n_err;
    wire        busy;

    eth_service #(.DDR_BASE(DDR_BASE), .POLL_GAP(6'd7)) dut (
        .clk(clk), .rstn(rstn), .en(en),
        .wb_tgt(wb_tgt), .wb_adr(wb_adr), .wb_dat_w(wb_dat_w), .wb_sel(wb_sel),
        .wb_we(wb_we), .wb_cyc(wb_cyc), .wb_stb(wb_stb),
        .wb_dat_r(wb_dat_r), .wb_ack(wb_ack),
        .job_valid(job_valid), .job_ready(job_ready), .job_addr(job_addr),
        .job_len(job_len), .job_done(job_done), .job_err(job_err),
        .dma_rd_data(dma_rd_data), .dma_rd_valid(dma_rd_valid), .dma_rd_ready(dma_rd_ready),
        .n_req(n_req), .n_frame(n_frame), .n_err(n_err), .busy(busy)
    );

    // ---------------- WB slave model ----------------
    reg [31:0] rxmem [0:2047];
    reg [31:0] txmem [0:1023];
    reg [31:0] csr_wslot, csr_wlen, csr_pend, csr_rready;
    reg [31:0] csr_rslot, csr_rlen;

    reg        wb_pending;
    reg [1:0]  wb_tgt_q;
    reg [29:0] wb_adr_q;
    reg [31:0] wb_dw_q;
    reg [3:0]  wb_sel_q;
    reg        wb_we_q;

    // captured frames
    reg [7:0]  capf [0:16383];
    integer    cap_off [0:7];
    integer    cap_len [0:7];
    integer    cap_n;
    integer    wb_ops;

    integer k;
    reg [31:0] rdv;

    // Read data must be valid **during** the ack cycle (the DUT latches wb_dat_r on
    // the ack edge). Registering it here shifts every read by one transaction.
    always @(*) begin
        case (wb_tgt_q)
        2'd0: case (wb_adr_q)
              30'd0:  wb_dat_r = csr_wslot;
              30'd1:  wb_dat_r = csr_wlen;
              30'd4:  wb_dat_r = csr_pend;
              30'd7:  wb_dat_r = csr_rready;
              default: wb_dat_r = 32'd0;
              endcase
        2'd1: wb_dat_r = rxmem[wb_adr_q[10:0]];
        2'd2: wb_dat_r = txmem[wb_adr_q[9:0]];
        default: wb_dat_r = 32'd0;
        endcase
    end

    always @(posedge clk) begin
        if (!rstn) begin
            wb_ack <= 0; wb_pending <= 0;
            cap_n <= 0; wb_ops <= 0;
            cap_off[0] <= 0;
        end else begin
            wb_ack <= 0;
            if (wb_cyc && wb_stb && !wb_pending && !wb_ack) begin
                wb_pending <= 1;
                wb_tgt_q <= wb_tgt; wb_adr_q <= wb_adr; wb_dw_q <= wb_dat_w;
                wb_sel_q <= wb_sel; wb_we_q <= wb_we;
            end else if (wb_pending) begin
                wb_pending <= 0;
                wb_ack <= 1;
                wb_ops <= wb_ops + 1;
                // ---- writes ----
                if (wb_we_q) begin
                    case (wb_tgt_q)
                    2'd0: case (wb_adr_q)
                          30'd4:  csr_pend <= csr_pend & ~wb_dw_q;      // w1c
                          30'd6: begin                                  // READER_START
                              csr_rslot <= csr_rslot;                    // (set below)
                              cap_len[cap_n] <= csr_rlen[11:0];
                              cap_off[cap_n+1] <= cap_off[cap_n] + csr_rlen[11:0];
                              for (k = 0; k < 2048; k = k + 1)
                                  if (k < csr_rlen)
                                      capf[cap_off[cap_n] + k] <=
                                          txmem[{csr_rslot[0], 9'd0} + (k >> 2)][8*(k%4) +: 8];
                              cap_n <= cap_n + 1;
                          $display("CAP#%0d rslot=%0d rlen=%0d b42..45=%02x %02x %02x %02x b50..57=%02x %02x %02x %02x %02x %02x %02x %02x b58..61=%02x %02x %02x %02x",
                                   cap_n, csr_rslot, csr_rlen,
                                   45,4,0,0, 0,0,0,0, 0,0,0,0,
                                   0,0,0,0);
                          end
                          30'd9:  csr_rslot <= wb_dw_q;               // READER_SLOT
                          30'd10: csr_rlen  <= wb_dw_q;               // READER_LENGTH
                          default: ;
                          endcase
                    2'd1: begin end
                    2'd2: begin                                       // byte-enabled store
                        if (wb_sel_q[0]) txmem[wb_adr_q[9:0]][ 7: 0] <= wb_dw_q[ 7: 0];
                        if (wb_sel_q[1]) txmem[wb_adr_q[9:0]][15: 8] <= wb_dw_q[15: 8];
                        if (wb_sel_q[2]) txmem[wb_adr_q[9:0]][23:16] <= wb_dw_q[23:16];
                        if (wb_sel_q[3]) txmem[wb_adr_q[9:0]][31:24] <= wb_dw_q[31:24];
                    end
                    default: ;
                    endcase
                end
            end
        end
    end

    // ---------------- DMA model ----------------
    reg        d_busy;
    reg [9:0]  d_gap;                 // 每拍之间故意留 400 拍空洞（>255）：模拟板上 DDR 取数间隙
    reg [29:0] d_addr;
    reg [31:0] d_len, d_sent;
    reg [29:0] d_addr_cap;
    reg [31:0] d_len_cap;
    integer    n_jobs;

    assign job_ready = !d_busy;

    function [7:0] ddr_byte(input [31:0] a);
        ddr_byte = (a * 7 + 32'h31) & 32'hFF;
    endfunction

    always @(posedge clk) begin
        if (!rstn) begin
            d_busy <= 0; d_sent <= 0; d_len <= 0; d_addr <= 0;
            dma_rd_valid <= 0; dma_rd_data <= 0; job_done <= 0; job_err <= 0; d_gap <= 0;
            n_jobs <= 0; d_addr_cap <= 0; d_len_cap <= 0;
        end else begin
            job_done <= 0; job_err <= 0;
            if (job_valid && job_ready) begin
                d_busy <= 1; d_addr <= job_addr; d_len <= job_len; d_sent <= 0;
                d_addr_cap <= job_addr; d_len_cap <= job_len; n_jobs <= n_jobs + 1;
            end
            // 标准的 ready/valid 源：**一拍只呈现一个 beat**，被接收后才推进并撤 valid。
            // （旧写法让 valid 常亮、数据晚一拍更新 ⇒ 连续的 ready 会重复采到同一个 beat。）
            if (d_busy) begin
                if (d_gap != 10'd0) d_gap <= d_gap - 10'd1;
                if (!dma_rd_valid && d_gap == 10'd0) begin
                    if (d_sent < d_len) begin
                        dma_rd_valid <= 1;
                        dma_rd_data[ 7: 0] <= ddr_byte(d_addr + d_sent + 0);
                        dma_rd_data[15: 8] <= ddr_byte(d_addr + d_sent + 1);
                        dma_rd_data[23:16] <= ddr_byte(d_addr + d_sent + 2);
                        dma_rd_data[31:24] <= ddr_byte(d_addr + d_sent + 3);
                        dma_rd_data[39:32] <= ddr_byte(d_addr + d_sent + 4);
                        dma_rd_data[47:40] <= ddr_byte(d_addr + d_sent + 5);
                        dma_rd_data[55:48] <= ddr_byte(d_addr + d_sent + 6);
                        dma_rd_data[63:56] <= ddr_byte(d_addr + d_sent + 7);
                    end else begin
                        d_busy <= 0; job_done <= 1;
                    end
                end else if (dma_rd_valid && dma_rd_ready) begin
                    // 必须同拍 valid&&ready：否则"空洞期间"ready 还高，d_sent 会空跳（丢拍）
                    dma_rd_valid <= 0;
                    d_sent <= d_sent + 8;
                    d_gap  <= 10'd400;
                end
            end else begin
                dma_rd_valid <= 0;
            end
        end
    end

    // ---------------- checks ----------------
    integer errs = 0;
    task chk(input cond, input [8*72-1:0] msg);
        integer i; reg [7:0] c;
        begin
            if (!cond) begin
                $write("TBFAIL ");
                for (i = 71; i >= 0; i = i - 1) begin
                    c = msg[8*i +: 8];
                    if (c != 8'h00) $write("%c", c);
                end
                $write("\n");
                errs = errs + 1;
            end
        end
    endtask

    integer f, b, i, off, len, exp_job_addr, exp_job_len;
    reg [7:0] expb;

    task put_req(input [31:0] addr, input [31:0] rlen, input [31:0] seq);
        begin
            // 58-byte UDP read request in rx slot 0 (word = 4 wire bytes, LSB = first)
            rxmem[0]  = 32'h0000_0002;                                   // 02 00 00 00
            rxmem[1]  = 32'hBBAA_1100;                                   // 00 11 AA BB
            rxmem[2]  = 32'hFFEE_DDCC;                                   // CC DD EE FF
            rxmem[3]  = 32'h0045_0008;                                   // 08 00 45 00
            rxmem[4]  = 32'h0100_2C00;                                   // 00 2C 00 01
            rxmem[5]  = 32'h1140_0040;                                   // 40 00 40 11
            rxmem[6]  = 32'hA8C0_0000;                                   // 00 00 C0 A8
            rxmem[7]  = 32'hA8C0_3201;                                   // 01 32 C0 A8
            rxmem[8]  = 32'h8813_6E01;                                   // 01 6E 13 88
            rxmem[9]  = 32'h1800_4259;                                   // 59 42 00 18
            rxmem[10] = 32'h4D59_0000;                                   // 00 00 59 4D
            // ⚠️ 协议头的 32bit 字段是**大端**（与 G1 的 TB 同口径）：MSB 先上线
            rxmem[11] = {addr[23:16], addr[31:24], 8'h4D, 8'h45};        // 45 4D a31..a24
            rxmem[12] = {rlen[23:16], rlen[31:24], addr[7:0], addr[15:8]};
            rxmem[13] = {seq[23:16],  seq[31:24],  rlen[7:0], rlen[15:8]};
            rxmem[14] = {16'h0,       seq[7:0],    seq[15:8]};
            csr_wslot = 32'd0;
            csr_wlen  = 32'd58;
            csr_pend  = 32'd1;
        end
    endtask

    always @(posedge clk) csr_rready <= 32'd1;

    task wait_frames(input integer want, input integer maxcyc);
        integer c;
        begin
            c = 0;
            while ((cap_n < want) && (c < maxcyc)) begin
                @(posedge clk); c = c + 1;
            end
        end
    endtask


    // 每收完一帧打一行（判据的书面证据）
    integer cn = 0;
    always @(posedge clk) if (rstn && (cn < cap_n)) begin
        cn = cn + 1;
        $display("FRM#%0d len=%0d hdr42..49=%02x %02x %02x %02x %02x %02x %02x %02x off/len/last=%02x %02x %02x %02x %02x %02x %02x %02x  pay0=%02x",
                 cn-1, cap_len[cn-1],
                 capf[cap_off[cn-1]+42], capf[cap_off[cn-1]+43], capf[cap_off[cn-1]+44], capf[cap_off[cn-1]+45],
                 capf[cap_off[cn-1]+46], capf[cap_off[cn-1]+47], capf[cap_off[cn-1]+48], capf[cap_off[cn-1]+49],
                 capf[cap_off[cn-1]+50], capf[cap_off[cn-1]+51], capf[cap_off[cn-1]+52], capf[cap_off[cn-1]+53],
                 capf[cap_off[cn-1]+54], capf[cap_off[cn-1]+55], capf[cap_off[cn-1]+56], capf[cap_off[cn-1]+57],
                 capf[cap_off[cn-1]+58]);
    end
    initial begin
        for (i = 0; i < 2048; i = i + 1) rxmem[i] = 32'd0;
        for (i = 0; i < 1024; i = i + 1) txmem[i] = 32'd0;
        csr_wslot = 0; csr_wlen = 0; csr_pend = 0; csr_rslot = 0; csr_rlen = 0;
        repeat (4) @(posedge clk);
        rstn = 1;
        repeat (4) @(posedge clk);
        en = 1;

        //=================================================================
        // [1] 300 B at 0x9000_0007 (unaligned)
        //=================================================================
        put_req(32'h9000_0007, 32'd300, 32'h0000_0042);
        wait_frames(1, 60000);
        chk(cap_n == 1, "[1] expected exactly 1 reply frame");
        chk(cap_len[0] == 358, "[1] frame length != 358");
        chk(n_jobs == 1, "[1] exactly one DMA job");
        chk(d_addr_cap == 30'h1000_0000, "[1] job address must be aligned 0x10000000");
        chk(d_len_cap  == 32'd320, "[1] job length must be 320 (7+300 rounded up)");
        // header
        chk(capf[cap_off[0]+42] == 8'h59 && capf[cap_off[0]+45] == 8'h4D, "[1] magic");
        chk(capf[cap_off[0]+50] == 0 && capf[cap_off[0]+53] == 0, "[1] off must be 0");
        chk(capf[cap_off[0]+54] == 8'h01 && capf[cap_off[0]+55] == 8'h2C, "[1] len must be 300");
        chk(capf[cap_off[0]+57] == 8'h01, "[1] last flag");
        // payload = DDR bytes starting at phys 0x9000_0007
        for (i = 0; i < 300; i = i + 1) begin
            expb = ddr_byte(32'h1000_0007 + i);
            if (capf[cap_off[0] + 58 + i] !== expb) begin
                $display("TBFAIL [1] payload %0d got=%02x exp=%02x", i,
                         capf[cap_off[0]+58+i], expb);
                errs = errs + 1;
            end
        end

        //=================================================================
        // [2] 2000 B at 0x9000_0000 (aligned, two frames)
        //=================================================================
        put_req(32'h9000_0000, 32'd2000, 32'h0000_0043);
        wait_frames(3, 400000);   // 250 拍 x 400 空洞
        chk(cap_n == 3, "[2] expected 2 more frames (total 3)");
        chk(cap_len[1] == 1458 && cap_len[2] == 658, "[2] frame lengths 1458/658");
        for (f = 1; f <= 2; f = f + 1) begin
            off = (f == 1) ? 0 : 1400;
            len = (f == 1) ? 1400 : 600;
            chk(capf[cap_off[f]+50] == off[31:24] && capf[cap_off[f]+53] == off[7:0],
                "[2] frame offset");
            chk(capf[cap_off[f]+54] == len[15:8] && capf[cap_off[f]+55] == len[7:0],
                "[2] frame len");
            chk(capf[cap_off[f]+57] == ((f == 2) ? 8'h01 : 8'h00), "[2] last flag");
            for (i = 0; i < len; i = i + 1) begin
                expb = ddr_byte(32'h1000_0000 + off + i);
                if (capf[cap_off[f] + 58 + i] !== expb) begin
                    $display("TBFAIL [2] frame %0d payload %0d got=%02x exp=%02x", f, i,
                             capf[cap_off[f]+58+i], expb);
                    errs = errs + 1;
                end
            end
        end
        chk(n_jobs == 2, "[2] exactly two DMA jobs");

        //=================================================================
        // [2b] 4096 B at 0x9000_0100 -> 3 frames (tx slot rotation 0/1/0)
        //=================================================================
        put_req(32'h9000_0100, 32'd4096, 32'h0000_0044);
        wait_frames(6, 900000);
        chk(cap_n == 6, "[2b] expected 3 more frames (total 6)");
        for (f = 3; f <= 5; f = f + 1) begin
            off = (f - 3) * 1400;
            len = (f < 5) ? 1400 : (4096 - 2800);
            chk(capf[cap_off[f]+50] == off[31:24] && capf[cap_off[f]+53] == off[7:0],
                "[2b] frame offset");
            chk(capf[cap_off[f]+57] == ((f == 5) ? 8'h01 : 8'h00), "[2b] last flag");
            for (i = 0; i < len; i = i + 1) begin
                expb = ddr_byte(32'h1000_0100 + off + i);
                if (capf[cap_off[f] + 58 + i] !== expb) begin
                    $display("TBFAIL [2b] frame %0d payload %0d got=%02x exp=%02x", f, i,
                             capf[cap_off[f]+58+i], expb);
                    errs = errs + 1;
                end
            end
        end
        chk(n_jobs == 3, "[2b] exactly three DMA jobs");

        //=================================================================
        // [3] back to idle
        //=================================================================
        repeat (400) @(posedge clk);
        repeat (40000) @(posedge clk);         // 尾部 drain 也带 400 拍空洞
        chk(busy == 1'b0, "[3] service must return to idle");
        chk(n_req == 32'd3, "[3] n_req must count all three requests");

        if (errs == 0) $display("RESULT: PASS");
        else           $display("RESULT: FAIL errs=%0d", errs);
        $finish;
    end

    initial begin
        #20000000;
        $display("TBFAIL timeout (cap_n=%0d busy=%0d)", cap_n, busy);
        $display("RESULT: FAIL");
        $finish;
    end

endmodule
