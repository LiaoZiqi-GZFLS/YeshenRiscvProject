// ============================================================================
// nax_mini_board_top —— 盘古100K200K MINI（PG2L200H / FBB676 / speedgrade -6）板级顶层
//
// 结构（spec §4.1）：PLL + nax_mini_soc（= NaxSocMini + NaxMiniGlue）+ DDR3Bridge + 紫光 DDR3 IP
//
//   clk_in 27MHz ─► pll_100m_125m ─► cpu_clk 100MHz ─► nax_mini_soc.soc_clk
//                                                   └► DDR3Bridge.clock（AXI 从口侧）
//   ref_clk_p/n 125MHz ─► GTP_INBUFGDS ─► u_ddr3.ref_clk
//   ref_clk_p/n 125MHz ─► u_ddr3 ─► core_clk 125MHz ─► DDR3Bridge.io_ddr_clk
//   nax_mini_soc.mem_*（64bit AXI4 主）─► DDR3Bridge.io_axi_*（64bit 从）
//   DDR3Bridge.io_ddr*（256bit 简化 AXI 主）─► u_ddr3 的 axi_* 用户口
//
// 端口名与 `constraints/nax_mini.fdc` **逐字对齐**（86 个端口，86 条 PAP_IO_LOC）：
//   clk_in / rst_board_n / key1 / uart_txd / uart_rxd / led[3:0] /
//   sd_sck / sd_mosi / sd_cs_n / sd_miso / ref_clk_p / ref_clk_n / mem_*（71）
//   ⇒ 对账依据：把 fdc 里未注释的 PAP_IO_LOC 全抽出来排序，与 `sed -n '/^module/,/^);/p'`
//     的本文件端口表逐条比对（dev_map 会以 "对象找不到" 的形式兜底）。
//
// ---------------------------------------------------------------------------
// 【1】★ DDR 侧的 125MHz 域时钟取 **DDR3 IP 自己的 core_clk 输出**，不是 PLL 的第二路输出
//
//   依据（逐条）：
//   (a) **IP 的用户口（axi_awvalid/wdata/rvalid…）是 IP 内部 core_clk 域同步的**，我们这侧的
//       驱动/采样必须与**同一个** core_clk 同步。用板级 PLL 另出的 125MHz（与 ref_clk 那颗
//       125MHz 振荡器**不同源**，频率差最多 ±100ppm）去采样 IP 用户口，等于在 IP 用户口上做
//       **跨异步域采样**：IP 的 R 通道没有 rready（一拍收不下就丢，见 DDR3Bridge.scala 文件头
//       约束 1/4），一次亚稳采样就是丢一个 256bit beat ⇒ 板上表现为"偶尔挂死"。
//   (b) **官方 200H 4_10 demo（本板唯一硬件验证过的同族工程）就是这么接的**：
//       `HDMI_IN_DDR3_HDMI_OUT_top.v:294` `.core_clk(core_clk)` + `:164`
//       `.ddr_clk(core_clk)`（DDR 侧用户逻辑跑在 IP 输出上），其 fdc 把该时钟约束为
//       `create_generated_clock -name {ddrphy_sysclk} … ddrphy_gpll/clkout0`。
//   (c) **YeshenCore/NaxYeshenSoC 的 `soc_ddr_top.v` / `nax_board_top.v` 同样是
//       `.io_ddr_clk(core_clk)`**（core_clk = `ddr3_test` 的输出）—— 本任务书要求"沿用既有实践"。
//   ⇒ 故 fdc 里那个 125MHz 域叫 **core_clk**，且它是 `create_generated_clock`（由 ref_clk 派生），
//   不是板级 PLL 的 `create_clock`。
//
//   `pll_100m_125m` 仍按 plan Task 14 Step 3 出第二路 125MHz（`clkout1`），但**板上不接**
//   （P2/P3 若需要一个与 DDR 无关的 125MHz 时才有用；接上去就会与 (a) 冲突）。
//
// 【2】★ 125MHz 差分参考时钟走显式 `GTP_INBUFGDS`
//   官方 4_10 demo（`GTP_INBUFGDS #(.IOSTANDARD("DEFAULT"), .TERM_DIFF("ON"))`，L277-284）与
//   DDR3 IP example_design（`test_ddr.v:307-312` 的 `GTP_INBUFDS`）都显式插了差分输入缓冲，
//   再把单端结果接 `ddr3_test.ref_clk`。fdc 里 ref_clk_p/ref_clk_n 是 **HSTL15D_I（差分）**，
//   不插缓冲就会让 N2 成为"配了差分标准却悬空的输入脚"。本层照官方 4_10 写法。
//
// 【3】★ 复位链：`ddr_init_done && pll_lock_100m` 之后才放 SoC（= `soc_ddr_top.v` 既有实践）
//   · `u_ddr3.resetn` 直接吃**原始按键** `rst_board_n`（C22/KEY0，低有效）—— 与既有
//     `soc_ddr_top.v` 的 `.resetn(rst_board)` 同构（实测官方 4_10 用 `if (~rst_in)` ⇒ 低有效）。
//   · `soc_resetn` 是 cpu_clk 域的两级同步器输出：`ddr_init_done && pll_lock_100m` 之前恒 0
//     （异步置位由"寄存器上电为 0"天然满足），之后跟随按钮（1 = 运行）。
//     ⚠️ 这里的 lock 是**板级 PLL 的** lock（`pll_lock_100m`），不是 `ddr3_test.pll_lock`
//        那个**输出** —— 两者同名不同源，**不能接成同一根 wire**（PDS 会报
//        `DRC-1021: Net ... has multiple drivers`；实测踩过一次）。
//   · `nax_mini_soc.async_reset` 是**异步高有效**（见其文件头★复位语义），故取 `~soc_resetn`。
//   · `DDR3Bridge.reset` 是 Chisel 隐式复位（**高有效**），同取 `~soc_resetn`；桥内部对 CDC 的
//     低有效端已做取反（DDR3Bridge.scala 约束 5），板级不必再管。
//
// 【4】装载 strap：`key1`（C23/KEY1，上电默认高）直接进 `u_soc.load_mode`。
//   口径与 YeshenCore 一致（`.io_loadMode(btn_key[0])`）：**未按下（高）= 装载模式**，
//   装载器当主人期间 CPU 被扣在复位（`u_soc.cpu_reset` 在 nax_mini_soc 内部 OR 进 asyncReset）。
//
// 【5】P1 不引 GPIO 引脚（fdc 无 gpio_*）：`gpio_in` 拉 0，`gpio_out/gpio_dir` 悬空；
//   `tracer_valid/tracer_payload`（NaxSocMini 的 CsrTracer，可悬空）同样不引到引脚。
// ============================================================================

module nax_mini_board_top (
    // ---- 系统 ----
    input  wire        clk_in,          // 板载 27MHz 有源晶振（D18，官方 4_10 sys_clk）
    input  wire        rst_board_n,     // KEY0（C22），**低有效**原始按键
    input  wire        key1,            // KEY1（C23），装载 strap：高 = 装载模式（上电默认高）

    // ---- 串口（控制台 ttyS0）----
    output wire        uart_txd,        // C24
    input  wire        uart_rxd,        // B24

    // ---- 板载 LED（fdc 只约束 led[0..3]；led[4..7] 在 fdc 里是注释段）----
    output wire [3:0]  led,

    // ---- TF 卡（SPI 模式；**J25** 3/4/5/6，固定 3.3V）----
    // 权威 = tf_test_200mini 的 TF-J25 段（该工程上板实测 TF-OK）；旧 J10 映射已更正
    output wire        sd_sck,          // J25-3  V14
    output wire        sd_mosi,         // J25-4  U14
    input  wire        sd_miso,         // J25-5  T18
    output wire        sd_cs_n,         // J25-6  T17

    // ---- 以太网 PHY0（RGMII；引脚=官方 mini-base 管脚映射表逐格）----
    input  wire        eth_rgmii_rxc,    // D19  PHY0_RXC
    input  wire        eth_rgmii_rx_ctl, // H16  PHY0_RXCTL
    input  wire [3:0]  eth_rgmii_rxd,    // B19/A19/E16/D16 = PHY0_RXD3..0
    output wire        eth_rgmii_txc,    // G16  PHY0_TXC
    output wire        eth_rgmii_tx_ctl, // D20  PHY0_TXCTL
    output wire [3:0]  eth_rgmii_txd,    // D21/C21/B21/E20 = PHY0_TXD3..0
    output wire        eth_phy_rstn,     // G25

    // ---- DDR3 125MHz 差分参考时钟（N3/N2，GCLK_125M_P/N）----
    input  wire        ref_clk_p,
    input  wire        ref_clk_n,

    // ---- DDR3 物理接口（71 脚，逐条对齐 constraints/nax_mini.fdc）----
    output wire        mem_cs_n,
    output wire        mem_rst_n,
    output wire        mem_ck,
    output wire        mem_ck_n,
    output wire        mem_cke,
    output wire        mem_ras_n,
    output wire        mem_cas_n,
    output wire        mem_we_n,
    output wire        mem_odt,
    output wire [14:0] mem_a,
    output wire [2:0]  mem_ba,
    inout  wire [3:0]  mem_dqs,
    inout  wire [3:0]  mem_dqs_n,
    inout  wire [31:0] mem_dq,
    output wire [3:0]  mem_dm
);

    // ========================================================================
    // 时钟与复位
    // ========================================================================
    wire        cpu_clk;            // PLL clkout0 = 100MHz（SoC + fabric + 外设 + 桥的 AXI 侧）
    wire        core_clk;           // DDR3 IP 输出 = 125MHz（桥的 DDR 侧；见文件头【1】）
    wire        pll_clk_125m_unused;// PLL clkout1 = 126.5625MHz（本版不接，见文件头【1】）
    wire        pll_lock_100m;      // **板级 PLL** 的 lock（复位链用它，见文件头【3】）
    wire        ddr_init_done;      // DDR3 IP 的输出
    wire        ref_clk;            // GTP_INBUFGDS 之后的单端 125MHz → u_ddr3.ref_clk
    //
    // ⚠️ 板级 PLL 的 lock 与 DDR3 IP 的 `pll_lock` **输出**是两个不同的信号，必须分开命名：
    //    写成同一个 wire 会被 PDS 判 **DRC-1021: Net ... has multiple drivers**
    //    （实测踩过：`Net led[0] has multiple drivers`，两个驱动源就是
    //     `u_pll/u_gpll.LOCK` 与 `u_ddr3/…/N115.Z`）。`ddr3_test` 的 `pll_lock` 只是它内部
    //     PHY 的锁定指示，板级复位链**只用板级 PLL 的 lock**（口径同既有
    //    `soc_ddr_top.v` 的 `!ddr_init_done || !pll_lock_80m`），故那个输出**不接**。
    // 复位同步（cpu_clk 域；口径照 YeshenCore/NaxYeshenSoC 的 soc_ddr_top.v）
    reg         rst_sync1, rst_sync2;
    reg         soc_resetn;         // 1 = 运行（SoC 已放行）
    always @(posedge cpu_clk) begin
        if (!ddr_init_done || !pll_lock_100m) begin
            rst_sync1  <= 1'b0;
            rst_sync2  <= 1'b0;
            soc_resetn <= 1'b0;
        end else begin
            rst_sync1  <= rst_board_n;
            rst_sync2  <= rst_sync1;
            soc_resetn <= rst_sync2;
        end
    end
    wire soc_async_reset = ~soc_resetn;   // 异步高有效（nax_mini_soc.async_reset 语义）

    // ========================================================================
    // ★ 2026-10-03：DDR3 IP 的 `resetn` 必须由 **POR 计数器**驱动，**不能直接接原始按键**
    // ========================================================================
    // 依据（与已知-good 配置对齐）：官方 4_10 与 YeshenCore/verilog_soc/soc_ddr_top.v L435-438 都是
    //     reg [15:0] ddr_por_cnt;
    //     always @(posedge free_clk) if (ddr_por_cnt != 16'h2710) ddr_por_cnt <= ddr_por_cnt + 1'b1;
    //     wire ddr_rstn = (ddr_por_cnt == 16'h2710) & rst_board;
    // 即让 DDR IP 在上电后**看到一个约 0.37ms@27MHz 的复位脉冲**（PHY 校准/内部状态机需要它）。
    // 我们原来写 `.resetn(rst_board_n)`：按键上电即高 ⇒ **等于没有复位脉冲** ⇒ 实测板上
    // `ddr_init_done` 恒 0（丝印 LED2 不亮）、SoC 被自己的复位门控扣住 ⇒ 串口 0 字节。
    // ⚠️ 只对齐这一条已知差异；DDR 的 71 个引脚已与"本板跑通过那版 FDC"逐格核对（71/71 一致）。
    reg  [15:0] ddr_por_cnt;
    always @(posedge clk_in)      // clk_in = 板载 27MHz（与参考实现的 free_clk 同源同频）
        if (ddr_por_cnt != 16'h2710) ddr_por_cnt <= ddr_por_cnt + 1'b1;
    wire ddr_rstn = (ddr_por_cnt == 16'h2710) & rst_board_n;   // 两者都"高=放开"

    // ============================================================================
    // ★ 2026-10-03 上板诊断件：**clk_in 域的读数**（SoC 被 `soc_resetn` 扣住时唯一能说话的出口）
    // ============================================================================
    // 背景：上板实测本设计 `ddr_init_done=0` ⇒ `soc_resetn=0` ⇒ glue（含控制台与两个加载器）
    //       **全在复位** ⇒ COM7 一个字都没有，只能靠 LED 推断（链条长：led[1]→C18→丝印 LED2→极性）。
    // 这里用 **`clk_in`（27MHz 板载晶振，不受 `soc_resetn` 影响）** 把三个关键状态直接打进
    // `uart_txd`：SoC 未放行时**夺线**，放行后让位给 SoC 的控制台。115200 8N1（234 拍/位 @27MHz）。
    //   ~55ms 一帧 8 字节：  R  D  <ddr>  P  <pll>  C  <core>  \n        (<> 里是 '0'/'1')
    //   · `<ddr>` = `ddr_init_done`（DDR IP 的 PHY 校准完成）
    //   · `<pll>` = `pll_lock_100m`（板级 PLL 锁定；它也是 `soc_resetn` 的另一半条件）
    //   · `<core>` = `core_clk`（DDR IP 输出 125MHz）**本帧周期内是否翻转过**
    //        ⇒ 用来把"ref_clk 没到 / PHY PLL 没锁（core 不动）"与"PHY 校准没完成（core 在动但 ddr=0）"分开
    //   ⚠️ 这是**诊断件**：交付定稿时可删本块并把 `.uart_txd()` 直接接回 `uart_txd`（一行）。
    wire        soc_uart_txd;
    reg  [15:0] rp_baud;
    reg  [3:0]  rp_bit;
    reg  [9:0]  rp_sh;
    reg         rp_busy;
    reg  [20:0] rp_gap;
    reg  [20:0] rp_lim = 21'd2_000_000;   // 本字节发射前的等待上限：帧间长、字节间短
    reg  [2:0]  rp_byte;
    reg         rp_ck1, rp_ck2, rp_ck3, rp_ck_seen;
    reg  [7:0]  rp_data;
    always @(*) begin
        case (rp_byte)
            3'd0:    rp_data = "R";
            3'd1:    rp_data = "D";
            3'd2:    rp_data = 8'h30 + {7'b0, ddr_init_done};
            3'd3:    rp_data = "P";
            3'd4:    rp_data = 8'h30 + {7'b0, pll_lock_100m};
            3'd5:    rp_data = "C";
            3'd6:    rp_data = 8'h30 + {7'b0, rp_ck_seen};
            default: rp_data = 8'h0A;               // '\n'
        endcase
    end
    always @(posedge clk_in) begin
        rp_ck1 <= core_clk; rp_ck2 <= rp_ck1; rp_ck3 <= rp_ck2;   // 两级同步后看沿
        if (rp_ck3 != rp_ck2) rp_ck_seen <= 1'b1;
        if (rp_busy) begin
            if (rp_baud == 16'd233) begin              // 一位 = 234 拍 @27MHz ≈ 115200
                rp_baud <= 16'd0;
                if (rp_bit == 4'd9) begin              // 一字节发完（start + 8 data + stop）
                    rp_busy <= 1'b0; rp_bit <= 4'd0; rp_gap <= 21'd0;
                    if (rp_byte == 3'd7) begin         // 帧尾 ⇒ 长间隔 + 清 core_clk 观测
                        rp_byte <= 3'd0; rp_ck_seen <= 1'b0; rp_lim <= 21'd2_000_000;
                    end else begin                     // ⚠️ 必须回 idle 才装载下一字节（每字节都要重装 rp_sh）
                        rp_byte <= rp_byte + 3'd1;       rp_lim <= 21'd240;
                    end
                end else begin
                    rp_bit <= rp_bit + 4'd1;
                    rp_sh  <= {1'b0, rp_sh[9:1]};
                end
            end else rp_baud <= rp_baud + 16'd1;
        end else if (rp_gap >= rp_lim) begin           // 等够了就装载并开始本字节
            rp_gap  <= 21'd0;
            rp_sh   <= {1'b1, rp_data, 1'b0};          // stop | data | start（LSB 先出）
            rp_baud <= 16'd0; rp_bit <= 4'd0; rp_busy <= 1'b1;
        end else rp_gap <= rp_gap + 21'd1;
    end
    wire rp_txd = rp_busy ? rp_sh[0] : 1'b1;           // 空闲高
    // SoC 放行前由诊断件夺线：glue 在复位时它的 uart_txd 恒 0（线上是持续 break，一个字节都读不到）
    assign uart_txd = soc_resetn ? soc_uart_txd : rp_txd;

    // ============================================================================
    // PLL：27MHz → clkout0 100MHz（cpu_clk）
    // ============================================================================
    // clkout1 按 plan Task 14 Step 3 保留；**本版不接**（理由见文件头【1】）。
    pll_100m_125m u_pll (
        .clkout0 (cpu_clk),
        .clkout1 (pll_clk_125m_unused),
        .clkin1  (clk_in),
        .lock    (pll_lock_100m)
    );

    // ========================================================================
    // 125MHz 差分参考时钟输入缓冲（照官方 4_10 demo；见文件头【2】）
    // ========================================================================
    GTP_INBUFGDS #(
        .IOSTANDARD ("DEFAULT"),
        .TERM_DIFF  ("ON")
    ) u_refclk_buf (
        .O  (ref_clk),
        .I  (ref_clk_p),
        .IB (ref_clk_n)
    );

    // ========================================================================
    // SoC：NaxSocMini（黑盒） + NaxMiniGlue 的组装层（board/nax_mini_soc.v）
    // ========================================================================
    // mem_* 是 **64bit AXI4 主口**（id 4bit），逐条对应 DDR3Bridge.io_axi_*（见下面例化的注释）
    wire        mem_ar_arvalid, mem_ar_arready;
    wire [3:0]  mem_ar_arid;
    wire [31:0] mem_ar_araddr;
    wire [7:0]  mem_ar_arlen;
    wire [2:0]  mem_ar_arsize;
    wire [1:0]  mem_ar_arburst;
    wire [2:0]  mem_ar_arlock;
    wire [3:0]  mem_ar_arcache;
    wire [2:0]  mem_ar_arprot;
    wire        mem_r_rvalid, mem_r_rready;
    wire [3:0]  mem_r_rid;
    wire [63:0] mem_r_rdata;
    wire [1:0]  mem_r_rresp;
    wire        mem_r_rlast;
    wire        mem_aw_awvalid, mem_aw_awready;
    wire [3:0]  mem_aw_awid;
    wire [31:0] mem_aw_awaddr;
    wire [7:0]  mem_aw_awlen;
    wire [2:0]  mem_aw_awsize;
    wire [1:0]  mem_aw_awburst;
    wire [1:0]  mem_aw_awlock;
    wire [3:0]  mem_aw_awcache;
    wire [2:0]  mem_aw_awprot;
    wire        mem_w_wvalid, mem_w_wready;
    wire [3:0]  mem_w_wid;
    wire [63:0] mem_w_wdata;
    wire [7:0]  mem_w_wstrb;
    wire        mem_w_wlast;
    wire        mem_b_bvalid, mem_b_bready;
    wire [3:0]  mem_b_bid;
    wire [1:0]  mem_b_bresp;

    wire        load_active;
    wire        cpu_reset;

    nax_mini_soc u_soc (
        .soc_clk     (cpu_clk),
        .async_reset (soc_async_reset),

        // ---- 内存主口（64bit AXI4）→ 直接引给下面 DDR3Bridge 的从口 ----
        .mem_ar_arid    (mem_ar_arid),
        .mem_ar_araddr  (mem_ar_araddr),
        .mem_ar_arlen   (mem_ar_arlen),
        .mem_ar_arsize  (mem_ar_arsize),
        .mem_ar_arburst (mem_ar_arburst),
        .mem_ar_arlock  (mem_ar_arlock),
        .mem_ar_arcache (mem_ar_arcache),
        .mem_ar_arprot  (mem_ar_arprot),
        .mem_ar_arvalid (mem_ar_arvalid),
        .mem_ar_arready (mem_ar_arready),
        .mem_r_rid      (mem_r_rid),
        .mem_r_rdata    (mem_r_rdata),
        .mem_r_rresp    (mem_r_rresp),
        .mem_r_rlast    (mem_r_rlast),
        .mem_r_rvalid   (mem_r_rvalid),
        .mem_r_rready   (mem_r_rready),
        .mem_aw_awid    (mem_aw_awid),
        .mem_aw_awaddr  (mem_aw_awaddr),
        .mem_aw_awlen   (mem_aw_awlen),
        .mem_aw_awsize  (mem_aw_awsize),
        .mem_aw_awburst (mem_aw_awburst),
        .mem_aw_awlock  (mem_aw_awlock),
        .mem_aw_awcache (mem_aw_awcache),
        .mem_aw_awprot  (mem_aw_awprot),
        .mem_aw_awvalid (mem_aw_awvalid),
        .mem_aw_awready (mem_aw_awready),
        .mem_w_wid      (mem_w_wid),
        .mem_w_wdata    (mem_w_wdata),
        .mem_w_wstrb    (mem_w_wstrb),
        .mem_w_wlast    (mem_w_wlast),
        .mem_w_wvalid   (mem_w_wvalid),
        .mem_w_wready   (mem_w_wready),
        .mem_b_bid      (mem_b_bid),
        .mem_b_bresp    (mem_b_bresp),
        .mem_b_bvalid   (mem_b_bvalid),
        .mem_b_bready   (mem_b_bready),

        // ---- 控制台 / GPIO ----
        .uart_txd   (soc_uart_txd),
        .uart_rxd   (uart_rxd),
        .gpio_in    (8'h00),        // P1 不引 GPIO 引脚（见文件头【5】）
        .gpio_out   (),
        .gpio_dir   (),

        // ---- 装载链 ----
        .load_mode   (key1),        // 见文件头【4】
        .load_active (load_active),
        .sd_sck      (sd_sck),
        .sd_mosi     (sd_mosi),
        .sd_miso     (sd_miso),
        .sd_cs_n     (sd_cs_n),
        .cpu_reset   (cpu_reset),

        // ---- 以太网装载器：RGMII pads（观察量不引到引脚）----
        .eth_rgmii_rxc    (eth_rgmii_rxc),
        .eth_rgmii_rx_ctl (eth_rgmii_rx_ctl),
        .eth_rgmii_rxd    (eth_rgmii_rxd),
        .eth_rgmii_txc    (eth_rgmii_txc),
        .eth_rgmii_tx_ctl (eth_rgmii_tx_ctl),
        .eth_rgmii_txd    (eth_rgmii_txd),
        .eth_phy_rstn     (eth_phy_rstn),
        .eth_released     (),
        .eth_rx_bytes     (),
        .eth_wr_bytes     (),

        // ---- CsrTracer：不引到引脚（可悬空）----
        .tracer_valid   (),
        .tracer_payload ()
    );

    // ========================================================================
    // DDR3 IP 用户口线（网名与 u_ddr3 例化里的 axi_* 同名，便于与既有工程对照）
    // ⚠️ 必须在 DDR3Bridge 例化**之前**声明：Verilog 里未声明标识符出现在例化端口上会被
    //    隐式声明成 1bit wire，之后再写 [27:0] 的显式声明就是重复声明（编译期报错）。
    // ========================================================================
    wire [27:0]  ddr_axi_awaddr;
    wire [3:0]   ddr_axi_awlen;
    wire         ddr_axi_awvalid;
    wire         ddr_axi_awready;
    wire [255:0] ddr_axi_wdata;
    wire [31:0]  ddr_axi_wstrb;
    wire         ddr_axi_wready;
    wire [27:0]  ddr_axi_araddr;
    wire [3:0]   ddr_axi_arlen;
    wire         ddr_axi_arvalid;
    wire         ddr_axi_arready;
    wire [255:0] ddr_axi_rdata;
    wire         ddr_axi_rvalid;
    wire         ddr_axi_rlast;

    // ========================================================================
    // 内存桥：nax_mini_soc.mem_*（64bit AXI4 主）→ DDR3Bridge（64bit AXI4 从）
    // ========================================================================
    // 端口名逐字取自 `rtl/DDR3Bridge.v` 的模块头（`sed -n '/^module DDR3Bridge/,/^);/p'`）：
    //   io_axi_ar_arid/araddr/arlen/arsize/arburst/arlock(2bit)/arcache/arprot/arvalid/arready
    //   io_axi_r_rid/rdata(64)/rresp/rlast/rvalid/rready
    //   io_axi_aw_awid/awaddr/awlen/awsize/awburst/awlock(2bit)/awcache/awprot/awvalid/awready
    //   io_axi_w_wid/wdata(64)/wstrb(8)/wlast/wvalid/wready
    //   io_axi_b_bid/bresp/bvalid/bready
    //   io_ddrClk 侧：io_ddr_clk / io_ddr_rstn / io_ddrAwAddr(28)/AwLen(4)/AwValid/AwReady /
    //               io_ddrWData(256)/WStrb(32)/WReady / io_ddrArAddr/AwLen/ArValid/ArReady /
    //               io_ddrRData(256)/RValid/RLast
    // 与 `board/nax_mini_soc.v` 的 mem_* 是**一一同名**（只差 mem_ / io_axi_ 前缀），位宽逐条相同。
    DDR3Bridge u_bridge (
        .clock       (cpu_clk),
        .reset       (soc_async_reset),      // 高有效（Chisel 隐式复位）
        .io_ddr_clk  (core_clk),             // ★ IP 输出的 125MHz（见文件头【1】）
        .io_ddr_rstn (ddr_init_done),        // 高有效：1 = DDR 初始化完成 = 可跑

        // ---- AXI4 从口（64bit）----
        .io_axi_ar_arid    (mem_ar_arid),
        .io_axi_ar_araddr  (mem_ar_araddr),
        .io_axi_ar_arlen   (mem_ar_arlen),
        .io_axi_ar_arsize  (mem_ar_arsize),
        .io_axi_ar_arburst (mem_ar_arburst),
        .io_axi_ar_arlock  (mem_ar_arlock),
        .io_axi_ar_arcache (mem_ar_arcache),
        .io_axi_ar_arprot  (mem_ar_arprot),
        .io_axi_ar_arvalid (mem_ar_arvalid),
        .io_axi_ar_arready (mem_ar_arready),
        .io_axi_r_rid      (mem_r_rid),
        .io_axi_r_rdata    (mem_r_rdata),
        .io_axi_r_rresp    (mem_r_rresp),
        .io_axi_r_rlast    (mem_r_rlast),
        .io_axi_r_rvalid   (mem_r_rvalid),
        .io_axi_r_rready   (mem_r_rready),
        .io_axi_aw_awid    (mem_aw_awid),
        .io_axi_aw_awaddr  (mem_aw_awaddr),
        .io_axi_aw_awlen   (mem_aw_awlen),
        .io_axi_aw_awsize  (mem_aw_awsize),
        .io_axi_aw_awburst (mem_aw_awburst),
        .io_axi_aw_awlock  (mem_aw_awlock),
        .io_axi_aw_awcache (mem_aw_awcache),
        .io_axi_aw_awprot  (mem_aw_awprot),
        .io_axi_aw_awvalid (mem_aw_awvalid),
        .io_axi_aw_awready (mem_aw_awready),
        .io_axi_w_wid      (mem_w_wid),
        .io_axi_w_wdata    (mem_w_wdata),
        .io_axi_w_wstrb    (mem_w_wstrb),
        .io_axi_w_wlast    (mem_w_wlast),
        .io_axi_w_wvalid   (mem_w_wvalid),
        .io_axi_w_wready   (mem_w_wready),
        .io_axi_b_bid      (mem_b_bid),
        .io_axi_b_bresp    (mem_b_bresp),
        .io_axi_b_bvalid   (mem_b_bvalid),
        .io_axi_b_bready   (mem_b_bready),

        // ---- DDR 侧简化 AXI（256bit）→ 下面 u_ddr3 的 axi_* ----
        .io_ddrAwAddr  (ddr_axi_awaddr),
        .io_ddrAwLen   (ddr_axi_awlen),
        .io_ddrAwValid (ddr_axi_awvalid),
        .io_ddrAwReady (ddr_axi_awready),
        .io_ddrWData   (ddr_axi_wdata),
        .io_ddrWStrb   (ddr_axi_wstrb),
        .io_ddrWReady  (ddr_axi_wready),
        .io_ddrArAddr  (ddr_axi_araddr),
        .io_ddrArLen   (ddr_axi_arlen),
        .io_ddrArValid (ddr_axi_arvalid),
        .io_ddrArReady (ddr_axi_arready),
        .io_ddrRData   (ddr_axi_rdata),
        .io_ddrRValid  (ddr_axi_rvalid),
        .io_ddrRLast   (ddr_axi_rlast)
    );

    // DDR3 IP 用户口线在**上面**（DDR3Bridge 例化之前）声明，见那段注释。

    // ========================================================================
    // 紫光同创 DDR3 IP（黑盒）
    // ========================================================================
    // 【端口契约】逐字取自 `third_party/ddr3_ip/ddr3_test/ddr3_test.v` 的模块头（IP 生成物）
    // 与 `example_design/rtl/test_ddr.v` 的例化（L746-860）、官方 4_10 demo（L288-...）：
    //   参数：MEM_ROW_WIDTH=15 / MEM_COLUMN_WIDTH=10 / MEM_BANK_WIDTH=3 / MEM_DQ_WIDTH=32 /
    //         MEM_DM_WIDTH=4 / MEM_DQS_WIDTH=4 / CTRL_ADDR_WIDTH=28
    //   用户口：axi_awaddr[27:0] axi_awuser_ap axi_awuser_id[3:0] axi_awlen[3:0] axi_awready
    //           axi_awvalid / axi_wdata[255:0] axi_wstrb[31:0] axi_wready axi_wusero_id[3:0]
    //           axi_wusero_last / axi_araddr[27:0] axi_aruser_ap axi_aruser_id[3:0]
    //           axi_arlen[3:0] axi_arready axi_arvalid / axi_rdata[255:0] axi_rid[3:0]
    //           axi_rlast axi_rvalid
    //   ⚠ 简化 AXI 特性（见 DDR3Bridge.scala 文件头）：W 通道无 wvalid（wready 高即采样）、
    //      R 通道无 rready；`axi_wstrb` 是 **32bit 逐字节掩码**、`axi_wdata` 是 **256bit**。
    //   debug/校准口一律照既有工程置常量（不接 UART 调试）。
    ddr3_test #(
        .MEM_ROW_WIDTH    (15),
        .MEM_COLUMN_WIDTH (10),
        .MEM_BANK_WIDTH   (3),
        .MEM_DQ_WIDTH     (32),
        .MEM_DM_WIDTH     (4),
        .MEM_DQS_WIDTH    (4),
        .CTRL_ADDR_WIDTH  (28)
    ) u_ddr3 (
        .ref_clk        (ref_clk),
        .resetn         (ddr_rstn),           // ★ POR 计数器（见上方"★ 2026-10-03"段），不是原始按键
        .core_clk       (core_clk),
        .pll_lock       (),                   // IP 内部 PHY 的锁定指示：板级不用（见上面⚠️）
        .phy_pll_lock   (),
        .gpll_lock      (),
        .rst_gpll_lock  (),
        .ddrphy_cpd_lock(),
        .ddr_init_done  (ddr_init_done),

        // 简化 AXI 写通道
        .axi_awaddr     (ddr_axi_awaddr),
        .axi_awuser_ap  (1'b0),
        .axi_awuser_id  (4'h0),
        .axi_awlen      (ddr_axi_awlen),
        .axi_awready    (ddr_axi_awready),
        .axi_awvalid    (ddr_axi_awvalid),

        .axi_wdata      (ddr_axi_wdata),
        .axi_wstrb      (ddr_axi_wstrb),
        .axi_wready     (ddr_axi_wready),
        .axi_wusero_id  (),
        .axi_wusero_last(),

        // 简化 AXI 读通道
        .axi_araddr     (ddr_axi_araddr),
        .axi_aruser_ap  (1'b0),
        .axi_aruser_id  (4'h0),
        .axi_arlen      (ddr_axi_arlen),
        .axi_arready    (ddr_axi_arready),
        .axi_arvalid    (ddr_axi_arvalid),

        .axi_rdata      (ddr_axi_rdata),
        .axi_rid        (),
        .axi_rlast      (ddr_axi_rlast),
        .axi_rvalid     (ddr_axi_rvalid),

        // APB 配置（不使用）
        .apb_clk        (1'b0),
        .apb_rst_n      (1'b0),
        .apb_sel        (1'b0),
        .apb_enable     (1'b0),
        .apb_addr       (8'd0),
        .apb_write      (1'b0),
        .apb_ready      (),
        .apb_wdata      (16'd0),
        .apb_rdata      (),

        // DDR3 物理接口
        .mem_cs_n       (mem_cs_n),
        .mem_rst_n      (mem_rst_n),
        .mem_ck         (mem_ck),
        .mem_ck_n       (mem_ck_n),
        .mem_cke        (mem_cke),
        .mem_ras_n      (mem_ras_n),
        .mem_cas_n      (mem_cas_n),
        .mem_we_n       (mem_we_n),
        .mem_odt        (mem_odt),
        .mem_a          (mem_a),
        .mem_ba         (mem_ba),
        .mem_dqs        (mem_dqs),
        .mem_dqs_n      (mem_dqs_n),
        .mem_dq         (mem_dq),
        .mem_dm         (mem_dm),

        // Debug 控制（不使用，恒无效）
        .dbg_gate_start    (1'b0),
        .dbg_cpd_start     (1'b0),
        .dbg_ddrphy_rst_n  (1'b1),
        .dbg_gpll_scan_rst (1'b0),

        .samp_position_dyn_adj   (1'b0),
        .init_samp_position_even (32'd0),
        .init_samp_position_odd  (32'd0),
        .wrcal_position_dyn_adj  (1'b0),
        .init_wrcal_position     (32'd0),
        .force_read_clk_ctrl     (1'b0),
        .init_slip_step          (16'd0),
        .init_read_clk_ctrl      (12'd0),

        .debug_calib_ctrl     (),
        .dbg_slice_status     (),
        .dbg_slice_state      (),
        .debug_data           (),
        .dbg_dll_upd_state    (),
        .debug_gpll_dps_phase (),
        .dbg_rst_dps_state    (),
        .dbg_tran_err_rst_cnt (),
        .dbg_ddrphy_init_fail (),
        .debug_cpd_offset_adj (1'b0),
        .debug_cpd_offset_dir (1'b0),
        .debug_cpd_offset     (10'd0),
        .debug_dps_cnt_dir0   (),
        .debug_dps_cnt_dir1   (),
        .ck_dly_en            (1'b0),
        .init_ck_dly_step     (8'd0),
        .ck_dly_set_bin       (),
        .align_error          (),
        .debug_rst_state      (),
        .debug_cpd_state      ()
    );

    // ========================================================================
    // LED（口径：plan Task 14 Step 2 的草稿）
    // ========================================================================
    assign led[0] = pll_lock_100m;    // 板级 PLL 锁定
    assign led[1] = ddr_init_done;    // DDR 初始化完成
    assign led[2] = load_active;      // 装载器当主人（CPU 被扣复位）
    assign led[3] = uart_txd;         // 串口线上有活动（空闲=高=常亮）

endmodule
