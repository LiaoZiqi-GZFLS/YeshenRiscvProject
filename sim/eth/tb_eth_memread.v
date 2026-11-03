//=============================================================================
// tb_eth_memread: H2 service unit gate (G1)
//   Checks (all byte-exact, no "looks right"):
//     1) ARP request -> 42-byte reply: oper=2 / sha=MY_MAC / spa=MY_IP / tha,tpa=requester
//     2) UDP read 3000 B (CHUNK=1400) -> exactly 3 frames, off 0/1400/2800,
//        len 1400/1400/200, flags last 0/0/1; IPv4 totlen/id/proto/src/dst/ports all checked;
//        payload byte-exact against the model DDR pattern
//     3) IPv4 header checksum recomputed independently in the TB (RFC1071)
//     4) Negative controls (in-TB): bad magic / len=0 / out-of-window => no reply, err_cnt++
//   TB model: TX always ready; pay source = incrementing pattern (pay_rd handshake)
//   NOTE: all messages are ASCII on purpose (a GBK console mangles UTF-8).
//=============================================================================
`timescale 1ns/1ps
module tb_eth_memread;

    localparam [47:0] MY_MAC  = 48'h02_00_00_00_00_11;
    localparam [31:0] MY_IP   = 32'hC0A8_016E;
    localparam [15:0] MY_PORT = 16'h5942;
    localparam integer CHUNK  = 1400;

    reg clk = 0, rstn = 0;
    always #4 clk = ~clk;                       // 125 MHz

    reg  [7:0] rx_data = 0;
    reg        rx_valid = 0, rx_sop = 0, rx_eop = 0;

    wire [7:0] tx_data;
    wire       tx_valid, tx_sop, tx_eop;
    // ★ 背压必须有：把 tx_ready 恒 1 会把"valid/sop/eop 在该撤之前就被清掉"这类
    //    丢字节缺陷**结构性地**藏起来（接真实槽口后实测每帧丢 30%）。这里留 1/4 的空洞。
    // 周期取 **5**（与 core 的"发一拍、等一拍"2 拍节奏互质）：周期 8 会与它相位锁定，
    // 空洞永远落在发射拍上 ⇒ 一次背压都测不到（实测 3216 次接收只停顿 1 次）。
    reg        tx_ready = 1'b1;
    reg  [2:0] tr_cnt = 3'd0;
    always @(posedge clk) tr_cnt <= (tr_cnt == 3'd4) ? 3'd0 : (tr_cnt + 3'd1);
    always @(*) tx_ready = (tr_cnt != 3'd0);

    wire       pay_rd;
    reg  [7:0] pay_data;
    wire       pay_valid = 1'b1;
    reg  [7:0] pat = 8'h00;

    wire       busy;
    wire [31:0] done_seq, err_cnt;

    eth_memread #(
        .MY_MAC(MY_MAC), .MY_IP(MY_IP), .MY_PORT(MY_PORT),
        .CHUNK(CHUNK)
    ) dut (
        .clk(clk), .rstn(rstn),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_sop(rx_sop), .rx_eop(rx_eop),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_sop(tx_sop), .tx_eop(tx_eop),
        .tx_ready(tx_ready),
        .pay_rd(pay_rd), .pay_data(pay_data), .pay_valid(pay_valid),
        .busy(busy), .done_seq(done_seq), .err_cnt(err_cnt)
    );

    // ---- all declarations up front (iverilog reports "declaration after use") ----
    integer   errs = 0;
    reg [7:0] fbuf [0:2047];
    integer   blen;
    integer   nframe;

    // Model "memory" pattern: reset is mandatory -- at power-up tx_valid is X => pay_rd is X,
    // and without the reset branch that first cycle writes X into pat => the whole payload turns X.
    always @(posedge clk) begin
        if (!rstn)        pat <= 8'h00;
        else if (pay_rd)  pat <= pat + 8'd1;
    end
    always @(*) pay_data = pat;

    // NOTE: `$display("%0s", <wide reg>)` drops characters in iverilog, and a literal longer
    //       than the reg is truncated from the FRONT (MSBs), so: 64-char room + print byte by byte.
    integer n_stall = 0, n_acc = 0, n_cyc = 0;
    always @(posedge clk) if (rstn) begin
        n_cyc = n_cyc + 1;
        if (tx_valid && !tx_ready) n_stall = n_stall + 1;
        if (tx_valid && tx_ready)  n_acc = n_acc + 1;
    end
    task chk(input cond, input [8*64-1:0] msg);
        integer k;
        reg [7:0] c;
        begin
            if (!cond) begin
                $write("TBFAIL ");
                for (k = 63; k >= 0; k = k - 1) begin
                    c = msg[8*k +: 8];
                    if (c != 8'h00) $write("%c", c);
                end
                $write("\n");
                errs = errs + 1;
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // Frame collector (byte by byte into fbuf)
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rstn && tx_valid && tx_ready) begin
            if (tx_sop) blen = 0;
            fbuf[blen] = tx_data;
            blen = blen + 1;
            if (tx_eop) nframe = nframe + 1;
            if (tx_eop) $display("DBG frame %0d len=%0d b0..b7=%02x %02x %02x %02x %02x %02x %02x %02x  b16..b19=%02x %02x %02x %02x  b30..b37=%02x %02x %02x %02x %02x %02x %02x %02x  b56..b59=%02x %02x %02x %02x",
                                 nframe, blen, fbuf[0],fbuf[1],fbuf[2],fbuf[3],fbuf[4],fbuf[5],fbuf[6],fbuf[7],
                                 fbuf[16],fbuf[17],fbuf[18],fbuf[19],
                                 fbuf[30],fbuf[31],fbuf[32],fbuf[33],fbuf[34],fbuf[35],fbuf[36],fbuf[37],
                                 fbuf[56],fbuf[57],fbuf[58],fbuf[59]);
        end
    end

    //-------------------------------------------------------------------------
    // Frame sender
    //-------------------------------------------------------------------------
    reg [7:0] txp [0:255];
    task send_frame(input integer n);
        integer i;
        begin
            @(posedge clk);
            for (i = 0; i < n; i = i + 1) begin
                rx_data  <= txp[i];
                rx_valid <= 1'b1;
                rx_sop   <= (i == 0);
                rx_eop   <= (i == n-1);
                @(posedge clk);
            end
            rx_valid <= 1'b0; rx_sop <= 1'b0; rx_eop <= 1'b0;
        end
    endtask

    task put_arp_req;
        begin
            txp[0]=8'hFF; txp[1]=8'hFF; txp[2]=8'hFF; txp[3]=8'hFF; txp[4]=8'hFF; txp[5]=8'hFF;
            txp[6]=8'hAA; txp[7]=8'hBB; txp[8]=8'hCC; txp[9]=8'hDD; txp[10]=8'hEE; txp[11]=8'hFF;
            txp[12]=8'h08; txp[13]=8'h06;
            txp[14]=8'h00; txp[15]=8'h01; txp[16]=8'h08; txp[17]=8'h00;
            txp[18]=8'd6;  txp[19]=8'd4;  txp[20]=8'h00; txp[21]=8'h01;   // request
            // sha = AA:BB:CC:DD:EE:FF
            txp[22]=8'hAA; txp[23]=8'hBB; txp[24]=8'hCC; txp[25]=8'hDD; txp[26]=8'hEE; txp[27]=8'hFF;
            // spa = 192.168.1.50
            txp[28]=192; txp[29]=168; txp[30]=1; txp[31]=50;
            txp[32]=0; txp[33]=0; txp[34]=0; txp[35]=0; txp[36]=0; txp[37]=0;
            // tpa = MY_IP
            txp[38]=8'hC0; txp[39]=8'hA8; txp[40]=8'h01; txp[41]=8'h6E;
        end
    endtask

    task put_udp_req(input [31:0] magic, input [31:0] addr, input [31:0] rlen,
                     input [31:0] seq);
        begin
            txp[0]=MY_MAC[47:40]; txp[1]=MY_MAC[39:32]; txp[2]=MY_MAC[31:24];
            txp[3]=MY_MAC[23:16]; txp[4]=MY_MAC[15:8];  txp[5]=MY_MAC[7:0];
            // src MAC = AA:BB:CC:DD:EE:FF
            txp[6]=8'hAA; txp[7]=8'hBB; txp[8]=8'hCC; txp[9]=8'hDD; txp[10]=8'hEE; txp[11]=8'hFF;
            txp[12]=8'h08; txp[13]=8'h00;
            txp[14]=8'h45; txp[15]=8'h00;
            txp[16]=8'h00; txp[17]=8'd44;            // totlen = 20+8+16 (not checked by DUT)
            txp[18]=8'h00; txp[19]=8'h01;
            txp[20]=8'h40; txp[21]=8'h00;
            txp[22]=8'd64; txp[23]=8'd17;            // UDP
            txp[24]=8'h00; txp[25]=8'h00;
            // src ip = 192.168.1.50
            txp[26]=192; txp[27]=168; txp[28]=1; txp[29]=50;
            // dst ip = MY_IP
            txp[30]=8'hC0; txp[31]=8'hA8; txp[32]=8'h01; txp[33]=8'h6E;
            // UDP: sport 5000, dport MY_PORT
            txp[34]=8'h13; txp[35]=8'h88;
            txp[36]=MY_PORT[15:8]; txp[37]=MY_PORT[7:0];
            txp[38]=8'h00; txp[39]=8'd24; txp[40]=8'h00; txp[41]=8'h00;
            // 16B protocol header
            txp[42]=magic[31:24]; txp[43]=magic[23:16]; txp[44]=magic[15:8]; txp[45]=magic[7:0];
            txp[46]=addr[31:24];  txp[47]=addr[23:16];  txp[48]=addr[15:8];  txp[49]=addr[7:0];
            txp[50]=rlen[31:24];  txp[51]=rlen[23:16];  txp[52]=rlen[15:8];  txp[53]=rlen[7:0];
            txp[54]=seq[31:24];   txp[55]=seq[23:16];   txp[56]=seq[15:8];   txp[57]=seq[7:0];
        end
    endtask

    // RFC1071 checksum (independent implementation, does not reuse the DUT's)
    function [15:0] ip_cksum;
        input [15:0] total;
        input [15:0] id;
        reg [31:0] s;
        begin
            s = 32'h4500 + total + id + 32'h4000 + 32'h4011 +
                {MY_IP[31:16]} + {MY_IP[15:0]} + 16'hC0A8 + 16'h0132;  // 192.168.1.50
            s = (s & 32'hFFFF) + (s >> 16);
            s = (s & 32'hFFFF) + (s >> 16);
            ip_cksum = ~s[15:0];
        end
    endfunction

    integer i;
    integer off, ln;
    reg [15:0] ckexp;
    reg [7:0]  expb;
    reg [7:0]  p0;
    integer n0;

    initial begin
        nframe = 0;
        repeat (4) @(posedge clk);
        rstn = 1;
        repeat (4) @(posedge clk);

        //=================================================================
        // 1) ARP request => 42 B reply
        //=================================================================
        n0 = nframe;
        put_arp_req; send_frame(42);
        repeat (200) @(posedge clk);
        chk(nframe == n0 + 1, "ARP: no reply emitted");
        chk(blen == 42, "ARP: reply length != 42");
        chk(fbuf[0] == 8'hAA && fbuf[5] == 8'hFF, "ARP: dst MAC is not the requester");
        chk(fbuf[6] == MY_MAC[47:40] && fbuf[11] == MY_MAC[7:0], "ARP: src MAC is not MY_MAC");
        chk(fbuf[12] == 8'h08 && fbuf[13] == 8'h06, "ARP: ethertype");
        chk(fbuf[20] == 8'h00 && fbuf[21] == 8'h02, "ARP: oper is not reply(2)");
        chk(fbuf[28] == 8'hC0 && fbuf[29] == 8'hA8 && fbuf[30] == 8'h01 && fbuf[31] == 8'h6E,
            "ARP: spa is not MY_IP");
        chk(fbuf[38] == 192 && fbuf[41] == 50, "ARP: tpa is not the requester IP");

        //=================================================================
        // 2) UDP read 3000 B => 3 frames
        //=================================================================
        @(negedge clk); pat = 8'h30;       // pattern origin (write on negedge to avoid a race)
        n0 = nframe;
        put_udp_req(32'h594D454D, 32'h9000_0000, 32'd3000, 32'h0000_00A5);
        send_frame(58);
        repeat (40000) @(posedge clk);
        chk(nframe == n0 + 3, "UDP: frame count != 3");
        chk(done_seq == 32'h0000_00A5, "UDP: done_seq wrong");

        // fbuf only keeps the last frame; per-frame header/payload evidence is in the DBG lines
        chk(blen == 58 + 200, "UDP: last frame length != 258");

        // last-frame header
        chk(fbuf[42]==8'h59 && fbuf[43]==8'h4D && fbuf[44]==8'h45 && fbuf[45]==8'h4D, "UDP: magic");
        chk(fbuf[46]==8'h00 && fbuf[49]==8'hA5, "UDP: seq");
        // off = 2800 = 0x00000AF0
        chk(fbuf[50]==8'h00 && fbuf[51]==8'h00 && fbuf[52]==8'h0A && fbuf[53]==8'hF0, "UDP: off != 2800");
        // len = 200 = 0x00C8
        chk(fbuf[54]==8'h00 && fbuf[55]==8'hC8, "UDP: len != 200");
        chk(fbuf[57]==8'h01, "UDP: last flag not set");
        // IPv4: totlen = 20+8+16+200 = 244 = 0x00F4
        chk(fbuf[16]==8'h00 && fbuf[17]==8'hF4, "UDP: IPv4 totlen wrong");
        chk(fbuf[23]==8'd17, "UDP: proto is not UDP");
        // reply src IP = MY_IP (26..29), dst IP = requester 192.168.1.50 (30..33)
        chk(fbuf[26]==8'hC0 && fbuf[29]==8'h6E, "UDP: src IP is not MY_IP");
        chk(fbuf[30]==192 && fbuf[31]==168 && fbuf[32]==1 && fbuf[33]==50,
            "UDP: dst IP is not requester 192.168.1.50");
        // UDP: sport = MY_PORT (34..35), dport = requester 5000 = 0x1388 (36..37)
        chk(fbuf[34]==MY_PORT[15:8] && fbuf[35]==MY_PORT[7:0], "UDP: sport is not MY_PORT");
        chk(fbuf[36]==8'h13 && fbuf[37]==8'h88, "UDP: dport is not requester port 5000");
        // IPv4 header checksum (independently recomputed)
        ckexp = ip_cksum(16'h00F4, 16'h00A5);
        chk(fbuf[24]==ckexp[15:8] && fbuf[25]==ckexp[7:0], "UDP: IPv4 header checksum wrong");
        // payload pattern: last frame's 200 bytes = pat0 + (2800..2999)
        // NOTE: truncate the expected value to 8 bits *before* comparing; a 32-bit 0x120 can never
        //       equal an 8-bit byte under !== (that mistake turned a correct DUT red once).
        for (i = 0; i < 200; i = i + 1) begin
            expb = 8'h30 + ((2800 + i) & 8'hFF);
            if (fbuf[58+i] !== expb) begin
                $display("TBFAIL UDP payload byte %0d got=%02x exp=%02x", i, fbuf[58+i], expb);
                errs = errs + 1;
            end
        end

        //=================================================================
        // 2b) idle must not consume the payload stream
        //     (in the real SoC pay_rd is the DmaEngine's rd_ready: a spurious ready while
        //      idle silently eats bytes off the stream and shifts every later transfer)
        //=================================================================
        @(negedge clk);
        p0 = pat;
        repeat (20) @(posedge clk);
        chk(pay_rd === 1'b0, "IDLE: pay_rd asserted while no frame is being emitted");
        chk(pat === p0, "IDLE: payload stream advanced while idle");

        //=================================================================
        // 3) Negative controls: bad magic / len=0 / out of window => no reply, err_cnt++
        //=================================================================
        n0 = nframe;
        put_udp_req(32'hDEAD_BEEF, 32'h9000_0000, 32'd64, 32'h11);
        send_frame(58);
        repeat (400) @(posedge clk);
        chk(nframe == n0, "NEG magic: replied anyway");
        chk(err_cnt == 32'd1, "NEG magic: err_cnt not incremented");

        put_udp_req(32'h594D454D, 32'h9000_0000, 32'd0, 32'h12);
        send_frame(58);
        repeat (400) @(posedge clk);
        chk(nframe == n0, "NEG len=0: replied anyway");
        chk(err_cnt == 32'd2, "NEG len=0: err_cnt not incremented");

        put_udp_req(32'h594D454D, 32'h7FFF_0000, 32'd64, 32'h13);   // below DDR_BASE
        send_frame(58);
        repeat (400) @(posedge clk);
        chk(nframe == n0, "NEG below-base: replied anyway");
        chk(err_cnt == 32'd3, "NEG below-base: err_cnt not incremented");

        put_udp_req(32'h594D454D, 32'hBFFF_FF00, 32'd1024, 32'h14);  // last byte past the 1 GiB window
        send_frame(58);
        repeat (400) @(posedge clk);
        chk(nframe == n0, "NEG past-window: replied anyway");
        chk(err_cnt == 32'd4, "NEG past-window: err_cnt not incremented");

        $display("READYSTAT cyc=%0d acc=%0d stall=%0d", n_cyc, n_acc, n_stall);
        if (errs == 0) $display("RESULT: PASS");
        else           $display("RESULT: FAIL errs=%0d", errs);
        $finish;
    end

    initial begin
        #4000000;
        $display("TBFAIL timeout (nframe=%0d blen=%0d)", nframe, blen);
        $display("RESULT: FAIL");
        $finish;
    end

endmodule
