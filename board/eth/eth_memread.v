//=============================================================================
// eth_memread: 以太网"硬件读存"服务的**纯逻辑核心**（请求解析 + 回包组帧）
//
// 设计：docs/superpowers/specs/2026-10-28-eth-memread-service-design.md
//
// 边界（承重，别混）：
//   · **不碰** PHY/RGMII/前导/FCS —— 仍由 liteeth 负责（本模块只填 tx 槽的整帧字节）；
//   · **不碰** DDR —— 载荷逐字节来自 DmaEngine 的 rd_stream（ready/valid 语义，pay_rd 即 ready）。
//   本模块只做：① 从 RX 整帧字节流认出 ARP 请求 / UDP 读请求；② 生成回包整帧字节流。
//
// 协议（回包，一帧一片）：
//   14 Eth + 20 IPv4 + 8 UDP + 16 协议头 + chunk 字节
//   协议头 = 'YMEM' | seq(u32) | off(u32) | len(u16) | flags(u16: bit0=last)
//   IPv4 头校验和真算（帧首 10 拍串行累加，早于第 24 字节就绪）；UDP 校验和填 0（IPv4 允许）。
//
// 判据口径：magic 不符 / len=0 / len>LEN_MAX / 越界 ⇒ **不回包**（只加 err_cnt）。
//=============================================================================
`timescale 1ns/1ps

module eth_memread #(
    parameter [47:0] MY_MAC  = 48'h02_00_00_00_00_11,
    parameter [31:0] MY_IP   = 32'hC0A8_016E,     // 192.168.1.110
    parameter [15:0] MY_PORT = 16'h5942,
    parameter [31:0] DDR_BASE= 32'h8000_0000,     // CPU 物理基址（phys → 偏移）
    // DDR3Bridge 只取 addr[29:2]（bit31/30 丢弃）⇒ 透传窗 = 1 GiB。
    // 真实 DRAM 可能更小；越界读数返回垃圾由主机侧自担（本模块只挡"低于基址/超窗"）。
    parameter [31:0] DDR_SIZE= 32'h4000_0000,
    parameter [15:0] CHUNK   = 16'd1400,          // 每帧载荷上限（≤ MTU-58）
    parameter [31:0] LEN_MAX = 32'h0010_0000      // 单请求上限 1 MiB
)(
    input  wire        clk,
    input  wire        rstn,

    // ---- RX：整帧字节流（liteeth rx 槽）----
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    input  wire        rx_sop,
    input  wire        rx_eop,

    // ---- TX：整帧字节流（liteeth tx 槽）----
    output reg  [7:0]  tx_data,
    output reg         tx_valid,
    output reg         tx_sop,
    output reg         tx_eop,
    input  wire        tx_ready,

    // ---- 载荷：DmaEngine rd_stream（pay_rd = ready）----
    output wire        pay_rd,
    input  wire [7:0]  pay_data,
    input  wire        pay_valid,

    // ---- 状态 ----
    output wire        busy,
    output reg  [31:0] done_seq,
    output reg  [31:0] err_cnt,

    // ---- 受理的作业（给外部的 DMA 启动器用；与内部 job_start 同拍）----
    output wire        o_go,        // 单拍：已受理一个合法请求（此时 o_addr/o_len/o_seq 有效）
    output wire [31:0] o_addr,      // 请求里的 CPU 物理地址（未做 DDR_BASE 折算）
    output wire [31:0] o_len,
    output wire [31:0] o_seq
);

    localparam [31:0] MAGIC = 32'h594D_454D;      // 线上字节序 'Y','M','E','M'
    localparam [15:0] ET_ARP  = 16'h0806;
    localparam [15:0] ET_IPV4 = 16'h0800;
    localparam [15:0] HDR_BYTES = 16'd58;         // 14+20+8+16
    localparam [15:0] ARP_BYTES = 16'd42;

    //-------------------------------------------------------------------------
    // ① RX 收集（按帧内位置，不整帧缓存）
    //-------------------------------------------------------------------------
    reg [11:0] rx_pos;
    reg        rx_done;                          // eop 后一拍：受理判定
    wire [11:0] pos_now = rx_sop ? 12'd0 : rx_pos;
    reg [7:0] et0,et1, sm0,sm1,sm2,sm3,sm4,sm5;
    reg [7:0] ip0,ip1,ip2,ip3, sp0,sp1;   // 源 IP / 源端口
    reg [7:0] dp0,dp1,dp2,dp3;            // **目的 IP**（受理要拿它比 MY_IP）
    reg [7:0] tp0,tp1;                    // **目的端口**
    reg [7:0] m0,m1,m2,m3, a0,a1,a2,a3, l0,l1,l2,l3, q0,q1,q2,q3;
    reg [7:0] ao0,ao1, at0,at1,at2,at3;
    reg [7:0] ap0,ap1,ap2,ap3;            // ARP 的发送方 IP（位于 28..31，与 IPv4 的 26..29 不同！）
    reg       proto_udp;

    reg [47:0] s_mac;
    reg [31:0] s_ip;
    reg [15:0] s_port;

    wire [31:0] rx_magic = {m0,m1,m2,m3};
    wire [31:0] rx_addr  = {a0,a1,a2,a3};
    wire [31:0] rx_len   = {l0,l1,l2,l3};
    wire [31:0] rx_seq   = {q0,q1,q2,q3};
    wire        rx_len_ok = (rx_len != 32'd0) && (rx_len <= LEN_MAX);
    // 判的是"末字节不越窗"：offset + len <= DDR_SIZE（用 33 位防回绕）
    wire [32:0] rx_end    = {1'b0,(rx_addr - DDR_BASE)} + {1'b0,rx_len};
    wire        rx_rng_ok = (rx_addr >= DDR_BASE) && (rx_end <= {1'b0,DDR_SIZE});

    //-------------------------------------------------------------------------
    // ② 任务锁存
    //-------------------------------------------------------------------------
    reg        job_start, arp_start;
    reg [31:0] j_len, j_seq, j_addr;
    reg [31:0] off_cur;
    reg        kind;                              // 0=UDP 回包  1=ARP 应答

    wire [15:0] chunk_len = ((j_len - off_cur) > CHUNK) ? CHUNK : (j_len - off_cur);
    wire        is_last   = ((off_cur + chunk_len) >= j_len);
    wire [15:0] udp_len   = 16'd24 + chunk_len;   // 8 + 16 + chunk
    wire [15:0] ip_totlen = 16'd20 + udp_len;
    wire [15:0] fr_len    = (kind == 1'b1) ? ARP_BYTES : (HDR_BYTES + chunk_len);

    //-------------------------------------------------------------------------
    // ③ 本帧第 idx 个字节（组合）
    //-------------------------------------------------------------------------
    reg [15:0] idx;                               // 帧内'下一个待发字节号'（1-based；0=空闲）
    wire [15:0] bidx = idx - 16'd1;                // 真正要发的字节下标（0-based）
    reg [15:0] ipck;                              // IPv4 头校验和（帧首 10 拍算出）
    reg [7:0]  by;
    always @(*) begin
        by = 8'h00;
        if (kind == 1'b1) begin
            case (bidx)
                16'd0: by=s_mac[47:40];  16'd1: by=s_mac[39:32];  16'd2: by=s_mac[31:24];
                16'd3: by=s_mac[23:16];  16'd4: by=s_mac[15:8];   16'd5: by=s_mac[7:0];
                16'd6: by=MY_MAC[47:40]; 16'd7: by=MY_MAC[39:32]; 16'd8: by=MY_MAC[31:24];
                16'd9: by=MY_MAC[23:16]; 16'd10:by=MY_MAC[15:8];  16'd11:by=MY_MAC[7:0];
                16'd12:by=8'h08;         16'd13:by=8'h06;
                16'd14:by=8'h00;         16'd15:by=8'h01;
                16'd16:by=8'h08;         16'd17:by=8'h00;
                16'd18:by=8'd6;          16'd19:by=8'd4;
                16'd20:by=8'h00;         16'd21:by=8'h02;
                16'd22:by=MY_MAC[47:40]; 16'd23:by=MY_MAC[39:32]; 16'd24:by=MY_MAC[31:24];
                16'd25:by=MY_MAC[23:16]; 16'd26:by=MY_MAC[15:8];  16'd27:by=MY_MAC[7:0];
                16'd28:by=MY_IP[31:24];  16'd29:by=MY_IP[23:16];
                16'd30:by=MY_IP[15:8];   16'd31:by=MY_IP[7:0];
                16'd32:by=s_mac[47:40];  16'd33:by=s_mac[39:32];  16'd34:by=s_mac[31:24];
                16'd35:by=s_mac[23:16];  16'd36:by=s_mac[15:8];   16'd37:by=s_mac[7:0];
                16'd38:by=s_ip[31:24];   16'd39:by=s_ip[23:16];
                16'd40:by=s_ip[15:8];    16'd41:by=s_ip[7:0];
                default: by = 8'h00;
            endcase
        end else begin
            case (bidx)
                16'd0: by=s_mac[47:40];  16'd1: by=s_mac[39:32];  16'd2: by=s_mac[31:24];
                16'd3: by=s_mac[23:16];  16'd4: by=s_mac[15:8];   16'd5: by=s_mac[7:0];
                16'd6: by=MY_MAC[47:40]; 16'd7: by=MY_MAC[39:32]; 16'd8: by=MY_MAC[31:24];
                16'd9: by=MY_MAC[23:16]; 16'd10:by=MY_MAC[15:8];  16'd11:by=MY_MAC[7:0];
                16'd12:by=8'h08;         16'd13:by=8'h00;
                16'd14:by=8'h45;                     16'd15:by=8'h00;
                16'd16:by=ip_totlen[15:8];           16'd17:by=ip_totlen[7:0];
                16'd18:by=j_seq[15:8];               16'd19:by=j_seq[7:0];
                16'd20:by=8'h40;                     16'd21:by=8'h00;
                16'd22:by=8'd64;                     16'd23:by=8'd17;
                16'd24:by=ipck[15:8];                16'd25:by=ipck[7:0];
                16'd26:by=MY_IP[31:24]; 16'd27:by=MY_IP[23:16];
                16'd28:by=MY_IP[15:8];  16'd29:by=MY_IP[7:0];
                16'd30:by=s_ip[31:24];  16'd31:by=s_ip[23:16];
                16'd32:by=s_ip[15:8];   16'd33:by=s_ip[7:0];
                16'd34:by=MY_PORT[15:8]; 16'd35:by=MY_PORT[7:0];
                16'd36:by=s_port[15:8];  16'd37:by=s_port[7:0];
                16'd38:by=udp_len[15:8]; 16'd39:by=udp_len[7:0];
                16'd40:by=8'h00;         16'd41:by=8'h00;
                16'd42:by=8'h59; 16'd43:by=8'h4D; 16'd44:by=8'h45; 16'd45:by=8'h4D;
                16'd46:by=j_seq[31:24]; 16'd47:by=j_seq[23:16];
                16'd48:by=j_seq[15:8];  16'd49:by=j_seq[7:0];
                16'd50:by=off_cur[31:24];16'd51:by=off_cur[23:16];
                16'd52:by=off_cur[15:8]; 16'd53:by=off_cur[7:0];
                16'd54:by=chunk_len[15:8];16'd55:by=chunk_len[7:0];
                16'd56:by=8'h00;         16'd57:by=is_last ? 8'h01 : 8'h00;
                default: by = 8'h00;
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // ④ IPv4 头校验和：帧首 10 拍串行累加（第 24 字节之前就绪）
    //-------------------------------------------------------------------------
    reg [19:0] ck_sum;
    reg [3:0]  ck_i;
    reg        ck_done;

    reg [15:0] ck_w;
    always @(*) begin
        case (ck_i)
            4'd0: ck_w = 16'h4500;
            4'd1: ck_w = ip_totlen;
            4'd2: ck_w = j_seq[15:0];
            4'd3: ck_w = 16'h4000;
            4'd4: ck_w = 16'h4011;                  // ttl=64 proto=17
            4'd5: ck_w = MY_IP[31:16];
            4'd6: ck_w = MY_IP[15:0];
            4'd7: ck_w = s_ip[31:16];
            4'd8: ck_w = s_ip[15:0];
            default: ck_w = 16'h0000;
        endcase
    end

    //-------------------------------------------------------------------------
    // ⑤ 流式发字节
    //-------------------------------------------------------------------------
    // ⚠️ 必须带 `idx != 0`：空闲时 idx=0 ⇒ bidx=0xFFFF ≥ HDR_BYTES 会把 pay_rd 拉高，
    //    真接上 DmaEngine 时会白白吞掉流上的字节（仿真里表现为图案整体错位）。
    wire pay_phase = (kind == 1'b0) && (idx != 16'd0) && (bidx >= HDR_BYTES);
    assign pay_rd  = pay_phase && pay_valid && !tx_valid;
    assign busy    = (idx != 16'd0) || tx_valid;
    assign o_go    = job_start;
    assign o_addr  = j_addr;
    assign o_len   = j_len;
    assign o_seq   = j_seq;

    wire [7:0] emit_data = pay_phase ? pay_data : by;
    wire       emit_ok   = pay_phase ? pay_valid : 1'b1;

    always @(posedge clk) begin
        if (!rstn) begin
            rx_pos <= 12'd0; tx_data <= 8'd0; tx_valid <= 1'b0; tx_sop <= 1'b0;
            tx_eop <= 1'b0; idx <= 16'd0; kind <= 1'b0; off_cur <= 32'd0;
            job_start <= 1'b0; arp_start <= 1'b0; j_len <= 32'd0; j_seq <= 32'd0;
            j_addr <= 32'd0;
            s_mac <= 48'd0; s_ip <= 32'd0; s_port <= 16'd0; rx_done <= 1'b0;
            done_seq <= 32'd0; err_cnt <= 32'd0;
            ck_sum <= 20'd0; ck_i <= 4'd0; ipck <= 16'd0; ck_done <= 1'b0;
        end else begin
            // ⚠️ 只有被接收（tx_ready）才能撤 valid/sop/eop：否则 tx_ready=0 的那拍
            //    会把已经装上总线的字节**丢掉**（G1 的 tx_ready 恒 1 抓不到；接上真实
            //     槽口背压后实测每 4 字节丢 1~2 个）。
            if (tx_ready) begin
                tx_valid <= 1'b0;
                tx_sop   <= 1'b0;
                tx_eop   <= 1'b0;
            end

            //-----------------------------------------------------------------
            // RX 解析
            //-----------------------------------------------------------------
            if (rx_valid) begin
                // ⚠️ 位置必须用**组合**当前值：rx_pos 是寄存器，sop 那一拍它还是上一帧的
                //    旧值 ⇒ 若直接 case(rx_pos)，第二个包起所有字节会整体错一位（实测）。
                rx_pos <= pos_now + 12'd1;
                case (pos_now)
                    12'd6:  sm0 <= rx_data;  12'd7:  sm1 <= rx_data;
                    12'd8:  sm2 <= rx_data;  12'd9:  sm3 <= rx_data;
                    12'd10: sm4 <= rx_data;  12'd11: sm5 <= rx_data;
                    12'd12: et0 <= rx_data;  12'd13: et1 <= rx_data;
                    12'd20: ao0 <= rx_data;  12'd21: ao1 <= rx_data;
                    12'd23: proto_udp <= (rx_data == 8'd17);
                    12'd26: ip0 <= rx_data;  12'd27: ip1 <= rx_data;
                    12'd28: begin ip2 <= rx_data; ap0 <= rx_data; end
                    12'd29: begin ip3 <= rx_data; ap1 <= rx_data; end
                    12'd30: begin ap2 <= rx_data; dp0 <= rx_data; end
                    12'd31: begin ap3 <= rx_data; dp1 <= rx_data; end
                    12'd34: sp0 <= rx_data;  12'd35: sp1 <= rx_data;
                    12'd36: tp0 <= rx_data;  12'd37: tp1 <= rx_data;
                    12'd32: dp2 <= rx_data;  12'd33: dp3 <= rx_data;
                    12'd38: at0 <= rx_data;  12'd39: at1 <= rx_data;
                    12'd40: at2 <= rx_data;  12'd41: at3 <= rx_data;
                    12'd42: m0 <= rx_data;   12'd43: m1 <= rx_data;
                    12'd44: m2 <= rx_data;   12'd45: m3 <= rx_data;
                    12'd46: a0 <= rx_data;   12'd47: a1 <= rx_data;
                    12'd48: a2 <= rx_data;   12'd49: a3 <= rx_data;
                    12'd50: l0 <= rx_data;   12'd51: l1 <= rx_data;
                    12'd52: l2 <= rx_data;   12'd53: l3 <= rx_data;
                    12'd54: q0 <= rx_data;   12'd55: q1 <= rx_data;
                    12'd56: q2 <= rx_data;   12'd57: q3 <= rx_data;
                    default: ;
                endcase
                // ⚠️ 受理要**延后一拍**：eop 那一拍最后 1 个字节（本例 pos 57 = seq 末字节）
                //    还在总线上，寄存器尚未更新 ⇒ 当拍判定会拿到旧的 seq/len（实测抓过）。
                if (rx_eop) rx_done <= 1'b1;
            end

            // ---- eop 后一拍：此时所有字段都已在寄存器里 ----
            if (rx_done) begin
                rx_done <= 1'b0;
                if (idx == 16'd0) begin            // 只在发包空闲时受理
                    s_mac  <= {sm0,sm1,sm2,sm3,sm4,sm5};
                    // 源 IP 的字节位置随帧型不同：ARP 在 28..31，IPv4 在 26..29
                    s_ip   <= ({et0,et1} == ET_ARP) ? {ap0,ap1,ap2,ap3}
                                                    : {ip0,ip1,ip2,ip3};
                    s_port <= {sp0,sp1};
                    if ({et0,et1} == ET_ARP && {at0,at1,at2,at3} == MY_IP &&
                        {ao0,ao1} == 16'h0001) begin
                        arp_start <= 1'b1;
                    end
                    if ({et0,et1} == ET_IPV4 && proto_udp &&
                        {dp0,dp1,dp2,dp3} == MY_IP && {tp0,tp1} == MY_PORT) begin
                        if (rx_magic == MAGIC && rx_len_ok && rx_rng_ok) begin
                            j_len <= rx_len; j_seq <= rx_seq; j_addr <= rx_addr;
                            job_start <= 1'b1;
                        end else begin
                            err_cnt <= err_cnt + 32'd1;
                        end
                    end
                end
            end

            //-----------------------------------------------------------------
            // 发包
            //-----------------------------------------------------------------
            if (idx == 16'd0 && !tx_valid) begin
                // 空闲：接任务（job 优先于 arp）
                if (job_start) begin
                    job_start <= 1'b0; kind <= 1'b0; off_cur <= 32'd0; idx <= 16'd1;
                    ck_sum <= 20'd0; ck_i <= 4'd0; ck_done <= 1'b0;
                end else if (arp_start) begin
                    arp_start <= 1'b0; kind <= 1'b1; idx <= 16'd1;
                end
            end else if (!tx_valid) begin
                // ---- IP 校验和（kind=UDP 且未完成）：10 拍累加 ----
                if (kind == 1'b0 && !ck_done) begin
                    if (ck_i < 4'd10) begin
                        ck_sum <= ck_sum + {4'd0, ck_w};
                        ck_i   <= ck_i + 4'd1;
                        if (ck_i == 4'd9) begin
                            ipck    <= ~(ck_sum[15:0] + {4'd0,ck_w} + ck_sum[19:16]);
                            ck_done <= 1'b1;
                        end
                    end
                end
                // ---- 送一个字节 ----
                if (emit_ok) begin
                    tx_data  <= emit_data;
                    tx_valid <= 1'b1;
                    tx_sop   <= (bidx == 16'd0);
                    tx_eop   <= (idx == fr_len);
                end
            end

            // ---- 字节被接收（tx_ready）----
            if (tx_valid && tx_ready) begin
                if (idx == fr_len) begin
                    if (kind == 1'b1) begin
                        idx <= 16'd0;                       // ARP 完
                    end else if (is_last) begin
                        done_seq <= j_seq; idx <= 16'd0;     // 本次请求完
                    end else begin
                        off_cur <= off_cur + {16'd0, chunk_len};
                        idx <= 16'd1;                        // 直接开始下一片
                        ck_sum <= 20'd0; ck_i <= 4'd0; ck_done <= 1'b0;
                    end
                end else begin
                    idx <= idx + 16'd1;
                end
            end
        end
    end

endmodule
