// ============================================================================================
// eth_mac_wrapper.v -- thin wrapper around the vendor UDP/IP/ARP/MAC stack
// (`third_party/eth_stack_2_11/source/*`), exposing a byte-stream receive port plus the RGMII pads.
//
// Deliberately NOT the vendor demo (`ethernet_test.v`): `arp_req` is tied low so only the ARP
// *responder* stays live (the host resolves our MAC by asking, which is all a loader needs).
// The only TX is the periodic reverse-channel status frame (see the FSM at the end of this file);
// it is sent to the **broadcast** L2 address that `arp_cache` emits when un-primed, so no ARP is
// ever required for the board to send.
//
// ⚠️ The RGMII delay recipe from the working experiment MUST be preserved (see
//    docs/superpowers/specs/2026-10-04-eth-loader-design.md §2):
//      * TX clock instance : DELAY_SEL = 1'b0  + TDELAY_EN = "TRUE"   (1'b1 is rejected by DRC-0034)
//      * RX instances      : DELAY_SEL = 1'b1  + TDELAY_EN = "FALSE"  (vendor original)
//
// Clocks: the stack runs entirely in the RX domain.  `o_rx_clk` (= rgmii_clk, the PLL output
// derived from rgmii_rxc) must be used to clock the consumer's write side; the consumer is
// responsible for crossing into soc_clk.
// ============================================================================================
module eth_mac_wrapper #(
    parameter [47:0] LOCAL_MAC = 48'ha0_b1_c2_d3_e1_e1,
    parameter [31:0] LOCAL_IP  = 32'hC0_A8_01_0B,   // 192.168.1.11 (vendor top's effective value)
    parameter [15:0] LOCL_PORT = 16'h1F90            // 8080
)(
    // ---- RGMII pads (physical) ----
    input  wire        rgmii_rxc,
    input  wire        rgmii_rx_ctl,
    input  wire [3:0]  rgmii_rxd,
    output wire        rgmii_txc,
    output wire        rgmii_tx_ctl,
    output wire [3:0]  rgmii_txd,
    // ⚠️ PHY 复位**不在这里驱动**：由 `board/nax_mini_soc.v` 用**独立 POR**（soc_clk 计 ~10ms）驱动该 pad。
    //    2026-10-05 实测：`= rstn`（PLL lock）能起但**闭环**（链路一掉就得给 PHY 断电）；
    //    `= 1'b1` 则 PHY 拿不到复位脉冲、上电要等 ~1.5min 且收不到 UDP；**POR 版实测 ping ≤5s 就通** ✓。

    // ---- received UDP payload stream (RX domain) ----
    output wire        o_rx_clk,     // = rgmii_clk
    output wire        o_pll_lock,   // = ref_clock lock (= rstn of the whole stack)
    output wire        o_rx_valid,
    output wire [7:0]  o_rx_data,
    output wire [15:0] o_rx_len,

    // ---- 反向信道输入：EthLoader 已收到的**数据字节数**（与本书栈同域 = rgmii_clk）----
    // 周期回发给主机（spec §4.3 第 1 段）：`'N','X','B',1 | w0(u32 BE) | w1(u32 BE)`。
    input  wire [31:0] rxBytesIn,
    // ---- 诊断（SD 通路调试）：两个 32 位 dbg ----
    //   w1 = sdDbgIn  = SdSpi  {misoHi, sckCnt[11:0], lastRx[7:0], errCode[3:0], ph[3:0], st[2:0]}
    //   w0 = sdDbg2In = SdLoader 的 AXI 突发通路 {wState,groupFull,awSeen,wSeen,bSeen,grp,wIdx,bCur}
    //   ⚠️ w0 位置原来发的是 `rxBytesIn`（只调 SD 时它恒 0）⇒ 本版把它**改用**为 sdDbg2In，帧长不变。
    input  wire [31:0] sdDbgIn,
    input  wire [31:0] sdDbg2In,
    // ---- 诊断 3：`{23'h0, load_mode, sd_state(4), sd_err(4)}` —— 用来区分"active 掉了"的两种原因 ----
    input  wire [31:0] sdStIn
);
    wire rstn;            // PLL lock -> stack reset (active low internally)
    wire rgmii_clk;       // main RX-derived clock
    wire rgmii_clk_90p;

    wire        mac_rx_data_valid;
    wire [7:0]  mac_rx_data;
    wire        mac_data_valid;
    wire [7:0]  mac_tx_data;
    wire        arp_found, mac_not_exist, mac_send_end;

    ref_clock ref_clock (
        .clkout0 (rgmii_clk_90p),
        .lock    (rstn),
        .clkin1  (rgmii_rxc)
    );

    // 反向信道 TX 的线与寄存器（声明必须在例化之前；FSM 在文件末）
    // ⚠️⚠️ 2026-10-05 实测教训（两条，都走了弯路）：
    //   ① **绝不能让板子周期性 `arp_req`**：上一版每 33ms 重试一次，结果板子 ① 对宿主的 ARP
    //      request **不再应答**、② `arp_found` 永远不置位（于是无限重试）。对照实验（决定性）：
    //      `eth_por.sbit`（arp_req 恒 0）**板子应答 ARP/ping ✓**；eth_bm（每 33ms）**0 应答 + 238 请求**。
    //      根因：厂家 `arp_tx` 的**同一个 FSM 既发我方请求、又发"收到别人请求要回的应答"**
    //      （`arp_tx.v:90-98`，IDLE 里 `arp_request_req` 优先）⇒ 持续的 `arp_req` 把应答路径饿死。
    //   ② **根本不需要 ARP**（这是正解）：`arp_cache.v:52/56` 在缓存未命中时把 `dest_mac_addr`
    //      输出成 **广播 `ff_ff_ff_ff_ff_ff`**，而 `mac_not_exist` **不在任何发送路径上**
    //      （grep 全栈只见于 arp_cache 输出 + 厂家 demo 的状态机）⇒ 板子**不发 ARP 也能发包**，
    //      帧是"L2 广播 + L3 单播 192.168.1.105" ⇒ 主机绑 `192.168.1.105:8080` 就能收到。
    //   ⇒ 最终形态：`arp_req` **恒 0**（保住 eth_por 那条已验证健康的配置），FSM 直接周期性发状态帧。
    //   `udp_tx.v` 的喂字节协议（照抄）：拉 `app_data_request`（电平）→ 等 `udp_send_ack`(=ip_send_ready)
    //   → 头部阶段用 **`app_data_in_valid` 当启动 tick**（`udp_tx.v:142`），随后**每拍喂一个载荷字节**
    //   （payload 经 8 级 `udp_shift_register` 延迟 8 拍对齐；长度 = `app_data_length + 8`）。
    reg  [1:0]  txSt    = TX_IDLE;
    reg  [21:0] txCnt   = 22'd0;
    reg  [3:0]  txIdx   = 4'd0;
    reg  [7:0]  txDatR  = 8'd0;
    reg  [15:0] txLenR  = 16'd0;
    reg         txReqR  = 1'b0;
    reg         txValR  = 1'b0;
    wire        txAck;
    wire [7:0]  txAppDat = txDatR;
    wire        txAppVal = txValR;
    wire [15:0] txAppLen = txLenR;   // ⚠️ 原先**漏声明** ⇒ 被当成 1 位隐式线网 ⇒ app_data_length 恒 0（发包长度错）
    wire        txAppReq = txReqR;
    // localparam 也必须在例化前（Verilog 里前面用不到的可以放后面，但放在这里最清楚）
    localparam TX_IDLE  = 2'd0,
               TX_REQ   = 2'd1,
               TX_BYTES = 2'd2,
               TX_DONE  = 2'd3;

    udp_ip_mac_top #(
        .LOCAL_MAC (LOCAL_MAC),
        .LOCAL_IP  (LOCAL_IP),
        .LOCL_PORT (LOCL_PORT),
        .DEST_MAC  (48'hFF_FF_FF_FF_FF_FF),
        .DEST_IP   (32'hC0_A8_01_69),
        .DEST_PORT (16'h1F90)
    ) u_stack (
        .rgmii_clk          (rgmii_clk),
        .rstn               (rstn),

        .app_data_in_valid  (txAppVal),      // 反向信道：周期回发状态帧（见文件末 TX FSM）
        .app_data_in        (txAppDat),
        .app_data_length    (txAppLen),
        .app_data_request   (txAppReq),
        .udp_send_ack       (txAck),

        .arp_req            (1'b0),          // ⚠️ 恒 0：板子**绝不主动发 ARP**；发包走缓存默认的**广播** dest_mac
        .arp_found          (arp_found),
        .mac_not_exist      (mac_not_exist),
        .mac_send_end       (mac_send_end),

        .udp_rec_rdata      (o_rx_data),
        .udp_rec_data_length(o_rx_len),
        .udp_rec_data_valid (o_rx_valid),

        .mac_data_valid     (mac_data_valid),
        .mac_tx_data        (mac_tx_data),

        .rx_en              (mac_rx_data_valid),
        .mac_rx_datain      (mac_rx_data)
    );

    rgmii_interface u_phy (
        .rst               (~rstn),
        .rgmii_clk         (rgmii_clk),
        .rgmii_clk_90p     (),

        .mac_tx_data_valid (mac_data_valid),
        .mac_tx_data       (mac_tx_data),

        .mac_rx_error      (),
        .mac_rx_data_valid (mac_rx_data_valid),
        .mac_rx_data       (mac_rx_data),

        .rgmii_rxc         (rgmii_clk_90p),
        .rgmii_rx_ctl      (rgmii_rx_ctl),
        .rgmii_rxd         (rgmii_rxd),

        .rgmii_txc         (rgmii_txc),
        .rgmii_tx_ctl      (rgmii_tx_ctl),
        .rgmii_txd         (rgmii_txd)
    );

    assign o_rx_clk   = rgmii_clk;
    assign o_pll_lock = rstn;

    // ============================================================================================
    // 反向信道（spec §4.3 第 1 段）：周期性把 `rxBytesIn` 回发给主机
    //   `'N','X','B',0x01 | rxBytes(u32 BE)`（8B 载荷）。
    //   发送侧用法照抄厂家 demo（`eth_udp_test.v`）：拉 `app_data_request`（**电平**）+
    //   `app_data_length`，等栈用 `udp_send_ack` 来要字节时逐拍喂入（栈把字节收进它的移位 RAM）。
    //   ⚠️ `ip_layer` 发送时用的是 **ARP 缓存里的** `dest_mac_addr`（`udp_ip_mac_top.v:144`
    //      把 `arp_dest_mac_addr` 连给 ip_layer；`DEST_MAC` 参数其实**没被用到**）。
    //      ⇒ 必须先把宿主 MAC 写进缓存。**方式 = 启动时发一条 ARP 请求，宿主应答**
    //      ⇒ `arp_rx` 置 `arp_found` 一拍 ⇒ `arp_cache` 锁存宿主 MAC（`arp_rec_source_mac_addr`）。
    //      ❌ **只发一次，绝不周期重试**（上一版每 33ms 重试把厂家栈的 ARP 应答路径饿死，
    //         见寄存器声明处的实测教训；对照：eth_por.sbit 的 arp_req 恒 0 ⇒ 应答正常）。
    //   ⚠️ 全部在 rx 域（rgmii_clk）——与 `EthLoader` 的 rx 域**同一个时钟**，故 `rxBytesIn` 直连无 CDC。
    // ============================================================================================
    always @(posedge rgmii_clk) begin
        if (!rstn) begin
            txSt <= TX_IDLE; txCnt <= 22'd0; txIdx <= 4'd0; txDatR <= 8'd0; txLenR <= 16'd0;
            txReqR <= 1'b0; txValR <= 1'b0;
        end else begin
            txValR <= 1'b0;
            case (txSt)
              TX_IDLE: begin
                  // 每 ~21ms 回发一帧（rx 域 = rgmii_clk ≈125MHz ⇒ 2^21 拍 ≈ 16.8ms）
                  if (txCnt == 22'h1F_FFFF) begin
                      txCnt <= 22'd0; txLenR <= 16'd16; txReqR <= 1'b1; txSt <= TX_REQ;
                  end else txCnt <= txCnt + 22'd1;
              end
              TX_REQ:  begin if (txAck) begin txIdx <= 4'd0; txSt <= TX_BYTES; end end
              TX_BYTES: begin
                  txValR <= 1'b1;               // app_data_in_valid：头部阶段的启动 tick + 载荷逐拍喂字节
                  // 16B 帧：'NXB' 0x01 | sdDbg2(4) | sdDbg(4) | sdSt(4)
                  txDatR <= (txIdx == 4'd0) ? 8'h4E : (txIdx == 4'd1) ? 8'h58 :   // 'N','X'
                            (txIdx == 4'd2) ? 8'h42 : (txIdx == 4'd3) ? 8'h01 :   // 'B',0x01
                            (txIdx == 4'd4) ? sdDbg2In[31:24] : (txIdx == 4'd5) ? sdDbg2In[23:16] :
                            (txIdx == 4'd6) ? sdDbg2In[15:8]  : (txIdx == 4'd7) ? sdDbg2In[7:0]  :
                            (txIdx == 4'd8) ? sdDbgIn[31:24]  : (txIdx == 4'd9) ? sdDbgIn[23:16]  :
                            (txIdx == 4'd10) ? sdDbgIn[15:8]  : (txIdx == 4'd11) ? sdDbgIn[7:0]    :
                            (txIdx == 4'd12) ? sdStIn[31:24]  : (txIdx == 4'd13) ? sdStIn[23:16]  :
                            (txIdx == 4'd14) ? sdStIn[15:8]   : sdStIn[7:0];
                  if (txIdx == 4'd15) begin txReqR <= 1'b0; txSt <= TX_DONE; end
                  else txIdx <= txIdx + 4'd1;
              end
              TX_DONE: begin if (mac_send_end) txSt <= TX_IDLE; end
              default: txSt <= TX_IDLE;
            endcase
        end
    end
endmodule
