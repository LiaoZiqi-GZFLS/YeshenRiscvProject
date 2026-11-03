//=============================================================================
// eth_service: H2 "hardware memory read over Ethernet" board glue (soc_clk only)
//
//   MAC slots (LiteEth Wishbone: csr / rx / tx)  <-- this module is the only
//   master while en=1; en=0 leaves every WB output idle and the CPU owns them.
//
//   (1) WB engine      one transaction at a time (cyc/stb -> wait ack -> dat_r)
//   (2) RX frame read  WRITER_EV_PENDING -> SLOT/LENGTH -> 4 B per WB read ->
//                      byte stream into eth_memread (sop/eop on first/last byte)
//   (3) TX frame write  eth_memread bytes -> 32-bit words (tail uses byte enables)
//                      -> READER_READY -> READER_SLOT -> READER_LENGTH -> START
//   (4) DMA reader      job_* launch from o_go, 64->8 byte FIFO, head skip
//                      (addr&31), exactly len delivered, tail drained to job_done
//
// Slot port facts were read out of liteeth_wrap.v / liteeth_mac_top.v / the kernel
// driver (spec section 9.2) -- do not "fix" them by intuition:
//   * 32-bit WORD addressed + 4-bit byte enables. rx = words 0..0x7FF (4 slots x
//     0x800 B, slot = word addr bit10:9), tx = words 0..0x3FF (2 slots, bit9).
//   * CSRs are in the mac window at BYTE offsets 0x00/0x04/0x10/0x18/0x1C/0x24/0x28
//     => word addresses 0/1/4/6/7/9/10.
//   * DmaEngine CHK wants src 32B aligned and len % 32 == 0, so the job is
//     (addr & ~31, ((addr&31)+len+31) & ~31) and the gearbox trims both ends.
//
// One request at a time: no polling until the whole reply sequence has been sent.
//=============================================================================
`timescale 1ns/1ps

module eth_service #(
    parameter [31:0] DDR_BASE   = 32'h8000_0000,
    parameter [5:0]  POLL_GAP   = 6'd31,     // idle: probe WRITER_EV_PENDING every N cycles
    parameter [1:0]  TX_SLOTS   = 2'd2       // MAC 的 tx 槽数（DTS: tx-slots=2）
)(
    input  wire        clk,
    input  wire        rstn,
    input  wire        en,                   // 1 = service owns the MAC slots

    // ---- MAC Wishbone master (tgt: 0=csr 1=rx 2=tx) ----
    output reg  [1:0]  wb_tgt,
    output reg  [29:0] wb_adr,
    output reg  [31:0] wb_dat_w,
    output reg  [3:0]  wb_sel,
    output reg         wb_we,
    output reg         wb_cyc,
    output reg         wb_stb,
    input  wire [31:0] wb_dat_r,
    input  wire        wb_ack,

    // ---- DmaEngine hardware job port (JOB_CH = 1) ----
    output reg         job_valid,
    input  wire        job_ready,
    output reg  [29:0] job_addr,
    output reg  [31:0] job_len,
    input  wire        job_done,
    input  wire        job_err,
    input  wire [63:0] dma_rd_data,
    input  wire        dma_rd_valid,
    output wire        dma_rd_ready,

    // ---- status ----
    output reg  [31:0] n_req,
    output reg  [31:0] n_frame,
    output reg  [31:0] n_err,
    output wire        busy
);

    //-------------------------------------------------------------------------
    // Core
    //-------------------------------------------------------------------------
    wire [7:0]  rx_data;
    wire        rx_valid, rx_sop, rx_eop;
    wire [7:0]  tx_data;
    wire        tx_valid, tx_sop, tx_eop;
    reg         tx_ready;
    wire        pay_rd, pay_valid;
    wire [7:0]  pay_data;
    wire        core_busy;
    wire [31:0] done_seq, core_err;
    wire        o_go;
    wire [31:0] o_addr, o_len, o_seq;

    eth_memread #(.DDR_BASE(DDR_BASE)) u_core (
        .clk(clk), .rstn(rstn),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_sop(rx_sop), .rx_eop(rx_eop),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_sop(tx_sop), .tx_eop(tx_eop),
        .tx_ready(tx_ready),
        .pay_rd(pay_rd), .pay_data(pay_data), .pay_valid(pay_valid),
        .busy(core_busy), .done_seq(done_seq), .err_cnt(core_err),
        .o_go(o_go), .o_addr(o_addr), .o_len(o_len), .o_seq(o_seq)
    );

    //-------------------------------------------------------------------------
    // (4) DMA reader / byte gearbox
    //-------------------------------------------------------------------------
    reg        d_run;
    reg [4:0]  d_skip;
    reg [31:0] d_left;
    reg [31:0] j_addr_r, j_len_r;
    reg        j_pend;
    reg [7:0]  q [0:15];
    reg [4:0]  q_wp, q_rp;
    wire [4:0] q_cnt   = q_wp - q_rp;
    wire       q_empty = (q_wp == q_rp);

    assign dma_rd_ready = d_run && (q_cnt <= 5'd8);
    // ⚠️ 不能挂 `d_run`：job_done 之后 FIFO 里可能还压着 tail 前要交付的字节，
    //    挂上 d_run 会让 core 永远等不到最后几个字节（实测：d_left=10 q_cnt=15 死等）。
    assign pay_valid    = (d_skip == 5'd0) && (d_left != 32'd0) && !q_empty;
    assign pay_data     = q[q_rp[3:0]];

    always @(posedge clk) begin
        if (!rstn) begin
            q_wp <= 5'd0; q_rp <= 5'd0;
            d_run <= 1'b0; d_skip <= 5'd0; d_left <= 32'd0;
            j_pend <= 1'b0; j_addr_r <= 32'd0; j_len_r <= 32'd0;
            job_valid <= 1'b0; job_addr <= 30'd0; job_len <= 32'd0;
            n_req <= 32'd0; n_err <= 32'd0;
        end else begin
            if (o_go) begin
                j_pend <= 1'b1; j_addr_r <= o_addr; j_len_r <= o_len;
                n_req <= n_req + 32'd1;
            end
            if (!job_valid && j_pend && !d_run) begin
                // ⚠️ 掩码必须写 32 位：`30'h3FF_FFE0` 这个"8 位十六进制塞进 30bit"的
                //    字面量在 iverilog 里会算成 0x0FFF_FFE0 ⇒ job_addr 恒 0（实测踩过）。
                job_addr  <= (j_addr_r - DDR_BASE) & 32'h3FFF_FFE0;
                job_len   <= (((j_addr_r - DDR_BASE) & 32'd31) + j_len_r + 32'd31) & 32'hFFFF_FFE0;
                d_skip    <= (j_addr_r - DDR_BASE) & 32'd31;
                d_left    <= j_len_r;
                job_valid <= 1'b1;
                j_pend    <= 1'b0;
            end
            if (job_valid && job_ready) begin job_valid <= 1'b0; d_run <= 1'b1; end
            if (job_done || job_err) d_run <= 1'b0;
            if (core_err != 32'd0) n_err <= core_err;

            if (dma_rd_valid && dma_rd_ready) begin
                q[q_wp[3:0]]        <= dma_rd_data[ 7: 0];
                q[q_wp[3:0] + 4'd1] <= dma_rd_data[15: 8];
                q[q_wp[3:0] + 4'd2] <= dma_rd_data[23:16];
                q[q_wp[3:0] + 4'd3] <= dma_rd_data[31:24];
                q[q_wp[3:0] + 4'd4] <= dma_rd_data[39:32];
                q[q_wp[3:0] + 4'd5] <= dma_rd_data[47:40];
                q[q_wp[3:0] + 4'd6] <= dma_rd_data[55:48];
                q[q_wp[3:0] + 4'd7] <= dma_rd_data[63:56];
                q_wp <= q_wp + 5'd8;
            end
            if (!q_empty) begin
                if (d_skip != 5'd0) begin
                    q_rp <= q_rp + 5'd1; d_skip <= d_skip - 5'd1;
                end else if (d_left != 32'd0) begin
                    if (pay_rd) begin q_rp <= q_rp + 5'd1; d_left <= d_left - 32'd1; end
                end else begin
                    q_rp <= q_rp + 5'd1;
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // (1) WB engine
    //-------------------------------------------------------------------------
    reg        wb_busy;
    reg [31:0] wb_rd;
    reg        wb_dn;                  // 1-cycle: transaction just completed
    reg [1:0]  wb_kind;                // which slave the in-flight/just-done op hit

    reg        wb_s;                   // combinational start strobe from the FSM
    reg [1:0]  wb_s_tgt;
    reg [29:0] wb_s_adr;
    reg [31:0] wb_s_dw;
    reg [3:0]  wb_s_sel;
    reg        wb_s_we;

    // ⚠️ `!wb_dn` 是承重的：ack 那一拍 wb_busy 已经落 0，若此时还举 start，
    //    会**立刻再发一笔同一个地址**（实测症状＝同一字重复喂进 core）。
    wire wb_ready = !wb_busy && !wb_dn;

    always @(posedge clk) begin
        if (!rstn) begin
            wb_tgt <= 2'd0; wb_adr <= 30'd0; wb_dat_w <= 32'd0; wb_sel <= 4'd0;
            wb_we <= 1'b0; wb_cyc <= 1'b0; wb_stb <= 1'b0;
            wb_busy <= 1'b0; wb_rd <= 32'd0; wb_dn <= 1'b0; wb_kind <= 2'd0;
        end else begin
            wb_dn <= 1'b0;
            if (!wb_busy) begin
                if (wb_s) begin
                    wb_tgt <= wb_s_tgt; wb_adr <= wb_s_adr; wb_dat_w <= wb_s_dw;
                    wb_sel <= wb_s_sel; wb_we <= wb_s_we;
                    wb_cyc <= 1'b1; wb_stb <= 1'b1; wb_busy <= 1'b1;
                end
            end else if (wb_ack) begin
                wb_cyc <= 1'b0; wb_stb <= 1'b0; wb_busy <= 1'b0;
                wb_rd <= wb_dat_r; wb_dn <= 1'b1; wb_kind <= wb_tgt;
            end
        end
    end

    //-------------------------------------------------------------------------
    // (2)(3) Sequencer
    //-------------------------------------------------------------------------
    localparam [3:0] S_IDLE  = 4'd0,
                     R_POLL  = 4'd11,   // 读 WRITER_EV_PENDING
                     R_SLOT  = 4'd1,
                     R_LEN   = 4'd2,
                     R_DATA  = 4'd3,
                     R_CLR   = 4'd4,
                     T_WAIT  = 4'd5,
                     T_FLUSH = 4'd6,
                     T_READY = 4'd7,
                     T_SLOT  = 4'd8,
                     T_LEN   = 4'd9,
                     T_GO    = 4'd10;

    localparam [29:0] A_W_SLOT = 30'd0,  A_W_LEN = 30'd1,  A_W_EV  = 30'd4,
                      A_R_START= 30'd6,  A_R_RDY = 30'd7,  A_R_SLOT= 30'd9,
                      A_R_LEN  = 30'd10;

    reg [3:0]  st;
    reg [5:0]  poll_cnt;

    // RX side
    reg [1:0]  rx_slot;
    reg [11:0] rx_len;
    reg [12:0] rx_word;
    reg [11:0] rx_fed;
    reg [31:0] rx_buf;
    reg        rx_buf_v;
    reg [1:0]  rx_lane;

    // TX side
    reg [1:0]  tx_slot;
    reg [31:0] tx_word;
    reg [2:0]  tx_lane;
    reg [11:0] tx_bytes;
    reg [11:0] tx_len_l;
    reg [12:0] tx_widx;
    reg        tx_final;
    reg        tx_wr;

    wire [3:0]  tx_sel_m = (tx_lane == 3'd4) ? 4'hF : ((4'h1 << tx_lane) - 4'h1);
    // ⚠️ 槽跨度是 0x800 **字节 = 512 字** ⇒ 槽基址 = slot << 9（写 <<7 会落到半个槽，
    //    只有 slot 0 恰好对；实测症状＝第 2 帧读回全 0）。
    wire [29:0] rx_adr_m = {19'd0, rx_slot, 9'd0} + {17'd0, rx_word};
    wire [29:0] tx_adr_m = {19'd0, tx_slot, 9'd0} + {17'd0, tx_widx};

    // ---- combinational WB start (exactly one source per cycle) ----
    always @(*) begin
        wb_s = 1'b0; wb_s_tgt = 2'd0; wb_s_adr = 30'd0;
        wb_s_dw = 32'd0; wb_s_sel = 4'hF; wb_s_we = 1'b0;
        if (en && wb_ready) begin
            case (st)
            R_POLL:  begin wb_s = 1; wb_s_tgt = 2'd0; wb_s_adr = A_W_EV;   end
            R_SLOT:  begin wb_s = 1; wb_s_tgt = 2'd0; wb_s_adr = A_W_SLOT; end
            R_LEN:   begin wb_s = 1; wb_s_tgt = 2'd0; wb_s_adr = A_W_LEN;  end
            R_DATA:  if (!rx_buf_v) begin wb_s = 1; wb_s_tgt = 2'd1; wb_s_adr = rx_adr_m; end
            R_CLR:   begin wb_s = 1; wb_s_tgt = 2'd0; wb_s_adr = A_W_EV;
                           wb_s_dw = 32'd1; wb_s_we = 1'b1; end
            T_FLUSH: begin wb_s = 1; wb_s_tgt = 2'd2; wb_s_adr = tx_adr_m;
                           wb_s_dw = tx_word; wb_s_sel = tx_sel_m; wb_s_we = 1'b1; end
            T_READY: begin wb_s = 1; wb_s_tgt = 2'd0; wb_s_adr = A_R_RDY; end
            T_SLOT:  begin wb_s = 1; wb_s_tgt = 2'd0; wb_s_adr = A_R_SLOT;
                           wb_s_dw = {30'd0, tx_slot}; wb_s_we = 1'b1; end
            T_LEN:   begin wb_s = 1; wb_s_tgt = 2'd0; wb_s_adr = A_R_LEN;
                           wb_s_dw = {20'd0, tx_len_l}; wb_s_we = 1'b1; end
            T_GO:    begin wb_s = 1; wb_s_tgt = 2'd0; wb_s_adr = A_R_START;
                           wb_s_dw = 32'd1; wb_s_we = 1'b1; end
            default: ;
            endcase
        end
    end

    // ---- TX byte accept: the core holds its byte until we take it ----
    always @(*) tx_ready = en && (st == T_WAIT) && !tx_wr && (tx_lane != 3'd4) && !tx_final;

    always @(posedge clk) begin
        if (!rstn) begin
            st <= S_IDLE; poll_cnt <= 6'd0;
            rx_slot <= 2'd0; rx_len <= 12'd0; rx_word <= 13'd0; rx_fed <= 12'd0;
            rx_buf <= 32'd0; rx_buf_v <= 1'b0; rx_lane <= 2'd0;
            tx_slot <= 2'd0; tx_word <= 32'd0; tx_lane <= 3'd0; tx_bytes <= 12'd0;
            tx_len_l <= 12'd0; tx_widx <= 13'd0; tx_final <= 1'b0; tx_wr <= 1'b0;
            n_frame <= 32'd0;
        end else begin
            tx_wr <= 1'b0;

            // ---- TX packer ----
            if (tx_valid && tx_ready) begin
                tx_word[8*tx_lane +: 8] <= tx_data;
                tx_lane  <= tx_lane + 3'd1;
                tx_bytes <= tx_bytes + 12'd1;
                if (tx_eop) tx_final <= 1'b1;
            end

            case (st)
            //-------------------------------------------------------------------
            S_IDLE: begin
                tx_lane <= 3'd0; tx_bytes <= 12'd0; tx_word <= 32'd0;
                tx_final <= 1'b0; tx_widx <= 13'd0; rx_buf_v <= 1'b0;
                tx_slot <= 2'd0;
                if (!en) poll_cnt <= 6'd0;
                else if (poll_cnt != POLL_GAP) poll_cnt <= poll_cnt + 6'd1;
                else if (core_busy || d_run || wb_busy) poll_cnt <= 6'd0;
                else begin poll_cnt <= 6'd0; st <= R_POLL; end
            end
            //---------------- RX: request frame ---------------------------------
            // ⚠️ 必须看 pending，不能拿 WRITER_LENGTH!=0 当"有包"：长度寄存器是**保持**的，
            //    否则每次轮询都会把上一帧重新处理一遍（实测：服务永不空闲）。
            R_POLL: begin
                if (wb_dn) st <= wb_rd[0] ? R_SLOT : S_IDLE;
            end
            R_SLOT: begin
                if (wb_dn) begin rx_slot <= wb_rd[1:0]; st <= R_LEN; end
            end
            R_LEN: begin
                if (wb_dn) begin
                    if (wb_rd == 32'd0 || wb_rd > 32'd2048) st <= S_IDLE;
                    else begin
                        rx_len   <= wb_rd[11:0];
                        rx_word  <= 13'd0;
                        rx_fed   <= 12'd0;
                        rx_buf_v <= 1'b0;
                        st <= R_DATA;
                    end
                end
            end
            R_DATA: begin
                if (wb_dn && wb_kind == 2'd1) begin
                    rx_buf   <= wb_rd;
                    rx_buf_v <= 1'b1;
                    rx_word  <= rx_word + 13'd1;
                    rx_lane  <= 2'd0;
                end else if (rx_buf_v) begin
                    if (rx_fed == rx_len || rx_lane == 2'd3) rx_buf_v <= 1'b0;
                    if (rx_fed == rx_len) st <= R_CLR;
                    else begin
                        rx_lane <= rx_lane + 2'd1;
                        rx_fed  <= rx_fed + 12'd1;
                    end
                end
            end
            R_CLR: begin
                if (wb_dn) begin
                    n_frame <= n_frame + 32'd1;
                    st <= T_WAIT;                       // tx_slot 不变：本帧可能已经写了几笔
                end
            end
            //---------------- TX: reply frames ----------------------------------
            T_WAIT: begin
                if ((tx_lane == 3'd4) && !tx_wr) begin
                    st <= T_FLUSH;
                end else if (tx_final && !tx_wr) begin
                    st <= (tx_lane == 3'd0) ? T_READY : T_FLUSH;
                end else if (!tx_valid && !core_busy) begin
                    // ⚠️ 判"这条请求已发完"只能看 core 的 busy，**不能**用"tx_valid 低了多少拍"的
                    //    定时器：板上 DDR 取数在帧中途会有 >2.55 µs 的间隙（实测 4 KiB 读只走
                    //    656 B 就被 255 拍超时弃帧 ⇒ core 卡在半帧、DMA 永远 busy、整条死锁）。
                    st <= S_IDLE;
                end
            end
            T_FLUSH: begin
                if (wb_dn) begin
                    tx_wr    <= 1'b1;
                    tx_widx  <= tx_widx + 13'd1;
                    tx_word  <= 32'd0;
                    tx_lane  <= 3'd0;
                    tx_bytes <= tx_final ? 12'd0 : tx_bytes;
                    if (tx_final) begin
                        tx_len_l <= tx_bytes;
                        tx_final <= 1'b0;
                        st <= T_READY;
                    end else begin
                        st <= T_WAIT;
                    end
                end
            end
            T_READY: begin
                if (wb_dn && wb_rd[0]) st <= T_SLOT;
            end
            T_SLOT: begin
                if (wb_dn) st <= T_LEN;
            end
            T_LEN: begin
                if (wb_dn) st <= T_GO;
            end
            T_GO: begin
                if (wb_dn) begin
                    tx_bytes <= 12'd0;
                    tx_widx  <= 13'd0;                  // 下一帧从槽内第 0 字开始写
                    // ⚠️ 只能绕 **tx 槽数**（2）：槽跨度 = slot<<9 字；写到 slot=2 会落到
                    //    地址 1024 字（被 MAC 的 bit9 解码别名回槽 0），而 READER_SLOT 却写 2
                    //    ⇒ 第 3 帧起读错槽（实测：4 KiB 读第 3 帧必坏）。
                    tx_slot  <= (tx_slot + 2'd1 == TX_SLOTS) ? 2'd0 : (tx_slot + 2'd1);
                    st <= T_WAIT;
                end
            end
            default: st <= S_IDLE;
            endcase
        end
    end

    // ---- RX byte stream to the core (one byte per cycle, no backpressure) ----
    assign rx_data  = rx_buf[8*rx_lane +: 8];
    assign rx_valid = en && (st == R_DATA) && rx_buf_v && (rx_fed != rx_len);
    assign rx_sop   = (rx_fed == 12'd0);
    assign rx_eop   = (rx_fed == (rx_len - 12'd1));

    assign busy = core_busy || d_run || (st != S_IDLE);

endmodule
