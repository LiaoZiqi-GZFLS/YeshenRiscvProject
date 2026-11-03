// ============================================================================
// liteeth_wrap —— LiteEth（主线驱动的 PIO/槽模式 MAC）在**板级的落地层**
//
// 为什么是这一层（2026-10-06，D1 之后）：
//   D1 删掉了厂家的整条 ETH 栈与 EthLoader（那是个**定制的 UDP 回环栈**，写不出 Linux 驱动）。
//   取而代之的是 LiteEth：主线内核 `drivers/net/ethernet/litex/litex_liteeth.c`（v5.15 起）
//   就是它的驱动，而它的 PHY 侧只要 GMII。板上这颗 PHY 是 RGMII，所以本文件把两件事拼起来：
//
//        RGMII 引脚 ──► rgmii_interface（厂家 2_11 栈里的 PHY 层，**只留这一个文件**）
//                       │  RGMII↔GMII：GTP_ODDR/IDDR + IODELAY，已经是板上跑通过的配方
//                       ▼  gmii_txd/tx_en、gmii_rxd/rx_dv/rx_er，全部在 rgmii_clk（125MHz）域
//                     liteeth_mac_top（sim/liteeth_gen 生成，见该脚本文件头）
//                       │  PHY 侧跑 rgmii_clk（clock_pads_rx/tx），
//                       │  数据通路与 CSR/槽内存跑 sys_clk（= soc_clk 100MHz）——
//                       │  两者的 CDC 由 LiteEth 自己那段 ClockDomainCrossing（异步 FIFO）完成，
//                       ▼  所以**下面这个 AXI-Lite→Wishbone 适配器一行 CDC 都不用写**
//                     AXI-Lite 从口 ⇄ NaxMiniGlue.io_ethAxi（CPU 的 pBus 上，三个窗口见下）
//
// 地址窗口（与 NaxMiniGlue 的解码、DTS 的 reg 必须逐字一致）：
//   ［0xF000_3000, +0x100)  "mac"    → wb_csr（32bit **word 寻址**：字节偏移>>2 就是寄存器号）
//   ［0xF000_4000, +0x100)  "mdio"   → **未接**（主线驱动这一版根本不用它；照常应答复 0，
//                                      不能不应答——AXI-Lite 的 CPU 通路是阻塞式的，无人应答就挂死）
//   ［0xF000_8000, +0x2000) "buffer" → 前半 2×0x800 = rx 槽（bus_rx），后半 = tx 槽（bus_tx）
//                                      （`bus_*_adr[11]` 就是槽号；产物里的 decoder0/1 用的正是这一位）
//
// ⚠️ 三条承重约定（都来自实读 RTL / 驱动源码，不是风格）：
//  1) **字节通道**：AXI-Lite 一次 32bit 访问要落到 4 个字节地址上（槽内存是 8bit 从口）。
//     一次读 ⇒ 从 `{addr[11:2],2'b00}` 起读 4 个字节，**按自然字节通道**拼回 rdata；
//     一次写 ⇒ 只在 `wstrb[i]` 的那几拍发 WB。核（NaxRiscv `AxiLite4Bridge`）把
//     `peripheralBus.cmd.address` **原样**（低位不抹）放到 `araddr/awaddr`（实读
//     `rtl/NaxSocMini.v:11159 io_down_ar_payload_addr = a_cmd_address = a_cmd_forked_payload_address | …`，
//     而 `a_cmd_forked_payload_address` 一路就是 LSU 的裸地址），返回数据也**原样**交给核
//     （`io_up_d_payload_data = io_down_r_payload_data`）由核自己按地址取通道。
//     ⇒ 本层必须"对齐到字、字节放自然通道"，这是唯一的正确写法。
//  2) **一次只跑一笔**：`araddr/awaddr` 只在**握手拍**有效，所以地址/数据必须在接受拍锁存；
//     执行期间不再接受新事务（返回 ready=0）。核的 uncache 通路本来就是阻塞式的，够用。
//  3) **未解码窗口也必须应答**（见上 mdio），否则核永久挂死。
//
// ⚠️ 不要在综合时给 `s_arready`/`s_awready` 加"同拍互斥"以外的逻辑：AW 优先、AR 让路
//    （两者同时有效时 AR 等一下），这样不会互相把对方压死（若两个都用对方的 valid 做门，
//    同时来就双双 0 ⇒ 死锁）。
// ============================================================================

module liteeth_wrap (
    input  wire        clk,        // sys_clk（= nax_mini_soc 的 soc_clk，100MHz）
    input  wire        rst,        // 同步、高有效（= nax_mini_soc 的 glue_reset）

    // ---- AXI4-Lite 从口（接 NaxMiniGlue 的 io_ethAxi_*）----
    input  wire [31:0] s_awaddr,
    input  wire [2:0]  s_awprot,
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wvalid,
    output wire        s_wready,
    output wire [1:0]  s_bresp,
    output wire        s_bvalid,
    input  wire        s_bready,
    input  wire [31:0] s_araddr,
    input  wire [2:0]  s_arprot,
    input  wire        s_arvalid,
    output wire        s_arready,
    output wire [31:0] s_rdata,
    output wire [1:0]  s_rresp,
    output wire        s_rvalid,
    input  wire        s_rready,

    // ---- RGMII 引脚（PHY0；引脚号见 constraints/nax_mini.fdc）----
    input  wire        rgmii_rxc,
    input  wire        rgmii_rx_ctl,
    input  wire [3:0]  rgmii_rxd,
    output wire        rgmii_txc,
    output wire        rgmii_tx_ctl,
    output wire [3:0]  rgmii_txd,

    // ---- 中断（→ NaxSocMini 的 peripheral_externalInterrupts_port 位 2 = PLIC 源 2）----
    output wire        irq,

    // ---- ★ H2：以太网读存服务的 Wishbone 主口（tgt: 0=csr 1=rx 2=tx）----
    //   `svc_en=1` 时本模块把 MAC 的三个从口**整组交给**服务，CPU 侧 AXI 从口在此
    //   期间不应答（软件必须先把 netdev 拉下再置位；`svc_on` 只在 CPU 侧空闲时生效）。
    input  wire        svc_en,
    input  wire [1:0]  svc_tgt,
    input  wire [29:0] svc_adr,
    input  wire [31:0] svc_dat_w,
    input  wire [3:0]  svc_sel,
    input  wire        svc_we,
    input  wire        svc_cyc,
    input  wire        svc_stb,
    output wire [31:0] svc_dat_r,
    output wire        svc_ack,

    // ---- ★ 2026-10-07：`rgmii_alive` = "PHY 的 RXC 在跳"（= 灯灭/亮 一眼判时钟）----
    //   为什么引出来：`rgmii_clk` 是本模块**内部**时钟（PHY 的 RXC 过 GTP_CLKBUFG），上层看不见。
    //   而"这个时钟到底有没有在跑"是整条网卡通路的**分水岭**：它死了 ⇒ MAC 的 eth_rx/eth_tx 两个域
    //   全冻住 ⇒ 驱动写进去的 tx 描述符永远排不出去（板上实测 `sram_reader_level` 涨到 2 不回落）。
    //   判据（同 `debug W0` 的 rxcHi/rxcLo）：**两者都为 1 = RXC 采到过高也采到过低 ⇒ 在翻转**。
    //   引到 led[3]：**常亮 = 时钟在跑，常灭 = 时钟钉死**。
    output wire        rgmii_alive
);

    // ========================================================================
    // 1) RGMII ⇄ GMII（厂家 PHY 层，逐字用 2_11 栈里那份，只留这一个文件）
    // ========================================================================
    // ⚠️ 它内部的 TX ODDR 与 RX IDDR 都clock在 `rgmii_clk`（= PHY 的 RXC 过 GTP_CLKBUFG），
    //    所以整条 GMII 都在 125MHz 的 `rgmii_clk` 域 —— 这正是 LiteEth MAC 的 `eth_rx/eth_tx` 域。
    //    厂家那份的 `rst` 与 `rgmii_clk_90p` 两个输入在模块体里**根本没用到**（实读源码），
    //    这里按未用处理（PHY 的复位走 `eth_phy_rstn`，在 nax_mini_soc.v 的独立 POR 里）。
    wire        rgmii_clk;
    wire        gmii_tx_en;
    wire [7:0]  gmii_txd;
    wire        gmii_rx_dv;
    wire [7:0]  gmii_rxd;
    wire        gmii_rx_er;

    // ★★ RGMII **延迟扫描旋钮**（2026-10-07 加，运行期可调）
    //   为什么这么加：这两个延迟用的是 `GTP_IODELAY_E2` + `DELAY_STEP_SEL("PORT")` ⇒ **本就是运行期可编程**。
    //   把它提成寄存器后，"扫几组数值试错"从"每档重出一遍带（~12 分钟）"变成 **一次烧写 + devmem 扫（每条几秒）**。
    //   复位值 = **厂家原常量**（txclk=100 / rx=247）⇒ 默认行为与厂家/eth211 逐字一致，不是一次行为改动。
    //   写成：`0xF000B01C` 写字 = {dly_txclk[15:8], dly_rx[7:0]}；读回同格式（见 dbgWord 的 3'd7 分支）。
    //   ⚠️ 跨到 `rgmii_clk` 域，属**准静态**参数（配好再打流量），不做握手同步。
    reg [7:0] dly_txclk = 8'd100;   // 原 `assign delay_step_c = 8'd100`
    reg [7:0] dly_rx    = 8'd247;   // 原 `assign delay_step_b = 8'd247`

    rgmii_interface u_rgmii (
        .rst                (1'b0),
        .rgmii_clk          (rgmii_clk),
        .rgmii_clk_90p      (1'b0),
        .dly_txclk          (dly_txclk),
        .dly_rx             (dly_rx),
        .mac_tx_data_valid  (gmii_tx_en),
        .mac_tx_data        (gmii_txd),
        .mac_rx_error       (gmii_rx_er),
        .mac_rx_data_valid  (gmii_rx_dv),
        .mac_rx_data        (gmii_rxd),
        .rgmii_rxc          (rgmii_rxc),
        .rgmii_rx_ctl       (rgmii_rx_ctl),
        .rgmii_rxd          (rgmii_rxd),
        .rgmii_txc          (rgmii_txc),
        .rgmii_tx_ctl       (rgmii_tx_ctl),
        .rgmii_txd          (rgmii_txd)
    );

    // ========================================================================
    // 2) LiteEth MAC（生成的 Verilog 黑盒；时钟域规划见文件头）
    // ========================================================================
    wire [29:0] csr_adr;
    wire [31:0] csr_dat_w;
    wire [31:0] csr_dat_r;
    wire [3:0]  csr_sel;
    wire        csr_cyc, csr_stb, csr_we, csr_ack;

    // ⚠️ dw=32（2026-10-07）后槽口是 32bit 数据 + 4bit 字节使能（原来是 8bit + 1bit）
    wire [29:0] rx_adr;
    wire [31:0] rx_dat_w, rx_dat_r;
    wire [3:0]  rx_sel;
    wire        rx_cyc, rx_stb, rx_we, rx_ack, rx_err;

    wire [29:0] tx_adr;
    wire [31:0] tx_dat_w, tx_dat_r;
    wire [3:0]  tx_sel;
    wire        tx_cyc, tx_stb, tx_we, tx_ack, tx_err;

    wire        eth_irq;

    liteeth_mac_top u_mac (
        .clock_pads_rx  (rgmii_clk),
        .clock_pads_tx  (rgmii_clk),
        .clock_pads_gtx (),

        .pads_tx_data   (gmii_txd),
        .pads_tx_en     (gmii_tx_en),
        .pads_rx_data   (gmii_rxd),
        .pads_rx_dv     (gmii_rx_dv),
        .pads_rx_er     (gmii_rx_er),

        .bus_rx_adr     (rx_adr),
        .bus_rx_dat_w   (rx_dat_w),
        .bus_rx_dat_r   (rx_dat_r),
        .bus_rx_sel     (rx_sel),
        .bus_rx_cyc     (rx_cyc),
        .bus_rx_stb     (rx_stb),
        .bus_rx_ack     (rx_ack),
        .bus_rx_we      (rx_we),
        .bus_rx_cti     (3'b000),
        .bus_rx_bte     (2'b00),
        .bus_rx_err     (rx_err),

        .bus_tx_adr     (tx_adr),
        .bus_tx_dat_w   (tx_dat_w),
        .bus_tx_dat_r   (tx_dat_r),
        .bus_tx_sel     (tx_sel),
        .bus_tx_cyc     (tx_cyc),
        .bus_tx_stb     (tx_stb),
        .bus_tx_ack     (tx_ack),
        .bus_tx_we      (tx_we),
        .bus_tx_cti     (3'b000),
        .bus_tx_bte     (2'b00),
        .bus_tx_err     (tx_err),

        .wb_csr_adr     (csr_adr),
        .wb_csr_dat_w   (csr_dat_w),
        .wb_csr_dat_r   (csr_dat_r),
        .wb_csr_sel     (csr_sel),
        .wb_csr_cyc     (csr_cyc),
        .wb_csr_stb     (csr_stb),
        .wb_csr_ack     (csr_ack),
        .wb_csr_we      (csr_we),
        .wb_csr_cti     (3'b000),
        .wb_csr_bte     (2'b00),
        .wb_csr_err     (1'b0),

        .irq            (eth_irq),
        .sys_clk        (clk),
        .sys_rst        (rst)
    );

    assign irq = eth_irq;

    // ========================================================================
    // 3) AXI-Lite → Wishbone 适配器（三个窗口；一次一笔；见文件头三条约定）
    // ========================================================================
    localparam [31:0] CSR_BASE  = 32'hF0003000;   // "mac"    （0x100）
    // ⚠️⚠️ "buffer" 的基址**必须 0x2000 对齐**：它 8 KB，只用一个掩码译码（`addr & 0xFFFFE000`）。
    //   第一版写成 `0xF000_5000`（不是 0x2000 的整数倍）⇒ 掩码只能盖住 0xF0005000..0xF0005FFF，
    //   而**后半（tx 槽，0xF0006000..0xF0006FFF）落进"未解码"⇒ pBus 回 DECERR**
    //   ⇒ CPU 上表现成 `store access fault`（RISC-V 里总线拒绝 = access fault，不是 page fault），
    //   现场：`liteeth_start_xmit → memcpy_toio` 写 `badaddr=0xffff_ffd0_0400_7000`（≈ 物理 0xF0006000）
    //   ⇒ `Kernel panic - not syncing: Fatal exception in interrupt`（2026-10-06 仿真实测抓到）。
    //   改成 0xF000_8000（0x2000 对齐，落点仍在 0xF000_0000–0xF000_FFFF 这 64 KiB 里）。
    //   三处必须同步：本文件 / `src/NaxMiniGlue.scala` 的 ETH_BUF_* / DTS 的 reg 第 3 段。
    localparam [31:0] BUF_BASE  = 32'hF0008000;   // "buffer" （**0x4000 对齐**；前 0x2000 = 4 个 rx 槽，后 0x1000 = 2 个 tx 槽；实用 0x3000）
    // ── 板级只读调试窗口（2026-10-07 移植自兄弟工程 `NaxYeshenLinux/board/liteeth_wrap.v`）──
    //   为什么要有它：上板实测"Linux 起来、eth0 up、配址成功、`tx_packets` 会涨但线上一个包都不走"，
    //   且驱动自己打出 `LITEETH_READER_READY not ready`、MAC 的 `sram_reader_level` 涨到 2 就**再也不回落**。
    //   ⇒ 可疑面收成两个：**① PHY 的 RXC（= `rgmii_clk`）到底有没有在跳；② 时钟在跳但 GMII TX 没被驱动**。
    //   这两个都只能在 FPGA 里看 ⇒ 加一个**纯只读**窗口（写忽略、照回 OKAY）一次问完。
    localparam [31:0] DBG_BASE  = 32'hF000B000;   // "ethdbg"（只读，4 个 32bit 字）
    // "mdio"（0xF0004000）不单独判：既不是 csr 也不是 buf/dbg 就落到"其他"分支，照样回应答。

    // ---- 事务槽 ----
    reg        awWait;                 // AW 已收、W 未到
    reg [31:0] awAddr;
    reg        wrPend;                 // AW+W 齐了，等执行
    reg [31:0] wrData;
    reg [3:0]  wrStrb;
    reg        rdPend;
    reg [31:0] rdAddr;

    // ---- 执行 FSM ----
    localparam F_IDLE = 2'd0, F_EXEC = 2'd1, F_RESP = 2'd2;
    reg [1:0]  fst;
    reg        isWr;
    reg [31:0] addr;
    reg [31:0] wdat;
    reg [3:0]  wstrb;
    reg [31:0] rdat;

    // ---- ★ H2：服务接管（整组二选一，绝不允许双驱动）----
    // 软件契约：先把 netdev 拉下（不再有在飞事务），再置 ETH_EN=1；交还时先清 ETH_EN。
    // `svc_on` 用两级同步只是防亚稳/毛刺，**不**替软件兜"事务在飞时切主"这种错用。
    reg [1:0] svc_en_s;
    always @(posedge clk) begin
        if (rst) svc_en_s <= 2'b00;
        else     svc_en_s <= {svc_en_s[0], svc_en};
    end
    wire svc_on = svc_en_s[1];

    assign s_awready = !svc_on && (fst == F_IDLE) && !awWait && !wrPend;
    assign s_wready  = !svc_on && (fst == F_IDLE) &&  awWait && !wrPend;
    // AR 给 AW 让路（同时有效时 AR 等下一拍）—— 两个 ready 互用对方 valid 做门会双双 0 ⇒ 死锁。
    assign s_arready = !svc_on && (fst == F_IDLE) && !awWait && !wrPend && !rdPend && !s_awvalid;

    assign s_bvalid  = (fst == F_RESP) &&  isWr;
    assign s_rvalid  = (fst == F_RESP) && !isWr;
    assign s_bresp   = 2'b00;          // OKAY（窗口已由 glue 解码，这里不会再出错误地址）
    assign s_rresp   = 2'b00;
    assign s_rdata   = rdat;

    // ---- 窗口判定（用**执行期**锁存的 addr，不用 AXI 的即时地址：后者握手后即失效）----
    wire tgt_csr = ((addr & 32'hFFFFFF00) == CSR_BASE);
    // ★ 2026-10-07（rx 槽 2→4）：槽区变成 rx 0x2000 + tx 0x1000 = 0x3000，故窗口按 **0x4000** 对齐。
    //   ⚠️ 0x4000 的窗口 = 0x8000..0xBFFF，**把 dbg 窗（0xB000）也盖进来了** ⇒
    //      `tgt_buf` 必须显式排除 dbg（否则 dbg 窗口会被当成 rx 槽）。
    wire tgt_dbg = ((addr & 32'hFFFFFF00) == DBG_BASE);
    wire tgt_buf_region = ((addr & 32'hFFFFC000) == BUF_BASE);
    wire tgt_buf = tgt_buf_region & ~tgt_dbg;
    wire tgt_rx  = tgt_buf & ~addr[13];   // rx 槽区 0x8000..0x9FFF（4 × 0x800）
    wire tgt_tx  = tgt_buf &  addr[13];   // tx 槽区 0xA000..0xAFFF（2 × 0x800）
    wire tgt_oth = ~tgt_csr & ~tgt_buf_region & ~tgt_dbg;   // "mdio" 等：应答复 0，不碰任何从口

    wire in_exec = (fst == F_EXEC);
    // ★ dw=32（2026-10-07）后槽口是 **32bit 字寻址 + 4bit 字节使能**（原来是 8bit 字节寻址）：
    //   写：AXI 的 `wstrb` 直接当字节使能 —— AXI 按地址低 2 位把窄写对齐到对应 lane，
    //       与 `wishbone.SRAM` 的 `sel[i] → 内存 lane i`（小端）约定一致 ⇒ 字节序天然正确。
    //   读：整字回，由核自己取字节通道（与旧版"4 拍 8bit 拼一个字"结果相同，但只花 1 笔）。
    // ★ rx 槽 2→4（2026-10-07）后字地址用 **`addr[12:2]`（11 位）**：rx 区 0x800 字、tx 区 0x400 字，
    //   两区基址都在 0x2000 边界 ⇒ 同一套 `addr[12:2]` 对 rx/tx 都成立（黑盒那边 `adr[10:9]` 选槽）。
    wire [29:0] buf_adr = {19'd0, addr[12:2]};

    wire s_csr = svc_on && (svc_tgt == 2'd0);
    wire s_rx  = svc_on && (svc_tgt == 2'd1);
    wire s_tx  = svc_on && (svc_tgt == 2'd2);

    assign csr_adr   = s_csr ? svc_adr : {25'd0, addr[6:2]};      // 字节偏移 >> 2 = CSR 号
    assign csr_dat_w = s_csr ? svc_dat_w : wdat;
    assign csr_sel   = s_csr ? svc_sel : (isWr ? wstrb : 4'hF);
    assign csr_we    = s_csr ? svc_we : isWr;
    assign csr_cyc   = s_csr ? svc_cyc : (in_exec & tgt_csr);
    assign csr_stb   = s_csr ? svc_stb : csr_cyc;

    assign rx_adr    = s_rx ? svc_adr : buf_adr;
    assign rx_dat_w  = s_rx ? svc_dat_w : wdat;
    assign rx_sel    = s_rx ? svc_sel : (isWr ? wstrb : 4'hF);
    assign rx_we     = s_rx ? svc_we : isWr;
    assign rx_cyc    = s_rx ? svc_cyc : (in_exec & tgt_rx);
    assign rx_stb    = s_rx ? svc_stb : rx_cyc;

    assign tx_adr    = s_tx ? svc_adr : buf_adr;
    assign tx_dat_w  = s_tx ? svc_dat_w : wdat;
    assign tx_sel    = s_tx ? svc_sel : (isWr ? wstrb : 4'hF);
    assign tx_we     = s_tx ? svc_we : isWr;
    assign tx_cyc    = s_tx ? svc_cyc : (in_exec & tgt_tx);
    assign tx_stb    = s_tx ? svc_stb : tx_cyc;

    assign svc_dat_r = (svc_tgt == 2'd0) ? csr_dat_r :
                       (svc_tgt == 2'd1) ? rx_dat_r  : tx_dat_r;
    assign svc_ack   = (svc_tgt == 2'd0) ? csr_ack :
                       (svc_tgt == 2'd1) ? rx_ack   : tx_ack;

    wire        buf_ack   = tgt_rx ? rx_ack   : tx_ack;
    wire [31:0] buf_dat_r = tgt_rx ? rx_dat_r : tx_dat_r;

    // ========================================================================
    // 3b) 只读调试观测（移植自兄弟工程）：回答"这条网卡通路上走到哪一步"
    //   四个字（读偏移 0x00/0x04/0x08/0x0C）：
    //     W0 flags+counts = {rxCnt[31:24], txCnt[23:16], csrCnt[15:8], 4'b0,
    //                        rxDvSeen, txEnSeen, rxcHi, rxcLo}
    //        · rxcLo/rxcHi = **RXC（= rgmii_clk 的源）被采到过低/过高** ⇒ 两位都 1 = 时钟在翻转；
    //          只有一位 = 时钟钉死（这就是"整个 MAC 没时钟"的直接证据）
    //        · txEnSeen = GMII `pads_tx_en` 曾经为 1（MAC 真的发过 preamble）
    //        · rxDvSeen = GMII `pads_rx_dv` 曾经为 1（PHY 真的收到过帧）
    //        · csrCnt/txCnt/rxCnt = CSR 事务 / tx 槽字节访问 / rx 槽字节访问的**饱和计数**
    //     W1 = 自由跑的系统时钟计数（读它两次不同 ⇒ 这个窗口本身是活的，排除"读到死值"）
    //     W2 = 最后一次 **CSR 写** {1'b0, addr[5:0], data[23:0], we}（内核写了哪个寄存器、写了什么）
    //     W3 = 最后一次 **CSR 读** {1'b0, addr[5:0], data[23:0], 1'b0}
    //   ⚠️ `rgmii_clk`/`gmii_*` 是**别的时钟域**的信号，这里只在 sys 域做"见过 0/1"的 sticky
    //      （经两级同步）——只用来判"动没动"，不测时序。
    // ========================================================================
    reg [31:0] sysCnt;
    reg [7:0]  csrCnt, txCnt, rxCnt;
    reg        rxcHi, rxcLo, txEnSeen, rxDvSeen;
    reg        s1_rxc, s2_rxc, s1_txen, s2_txen, s1_rxdv, s2_rxdv;
    reg [5:0]  csrWAdr, csrRAdr;
    reg [23:0] csrWDat, csrRDat;
    reg        csrWWe;              // 本拍见到的是"写"（否则读）
    wire       csrHit   = in_exec & tgt_csr & csr_ack;
    wire       dbgTgtRx = in_exec & tgt_rx & buf_ack;
    wire       dbgTgtTx = in_exec & tgt_tx & buf_ack;

    always @(posedge clk) begin
        s1_rxc  <= rgmii_clk;   s2_rxc  <= s1_rxc;
        s1_txen <= gmii_tx_en;  s2_txen <= s1_txen;
        s1_rxdv <= gmii_rx_dv;  s2_rxdv <= s1_rxdv;
        if (rst) begin
            sysCnt <= 32'd0; csrCnt <= 8'd0; txCnt <= 8'd0; rxCnt <= 8'd0;
            rxcHi <= 1'b0; rxcLo <= 1'b0; txEnSeen <= 1'b0; rxDvSeen <= 1'b0;
            csrWAdr <= 6'd0; csrRAdr <= 6'd0; csrWDat <= 24'd0; csrRDat <= 24'd0; csrWWe <= 1'b0;
        end else begin
            sysCnt <= sysCnt + 32'd1;
            if (s2_rxc) rxcHi <= 1'b1; else rxcLo <= 1'b1;
            if (s2_txen) txEnSeen <= 1'b1;
            if (s2_rxdv) rxDvSeen <= 1'b1;
            if (csrHit) begin
                if (csr_we) begin csrWAdr <= addr[7:2]; csrWDat <= csr_dat_w[23:0]; csrWWe <= 1'b1; end
                else        begin csrRAdr <= addr[7:2]; csrRDat <= csr_dat_r[23:0]; csrWWe <= 1'b0; end
                if (csrCnt != 8'hFF) csrCnt <= csrCnt + 8'd1;
            end
            if (dbgTgtTx && txCnt != 8'hFF) txCnt <= txCnt + 8'd1;
            if (dbgTgtRx && rxCnt != 8'hFF) rxCnt <= rxCnt + 8'd1;
        end
    end

    // 「RXC 在跳」：采到过高**也**采到过低 ⇒ 一定翻转过（跨域只做 sticky，不测时序）
    assign rgmii_alive = rxcHi & rxcLo;

    // ========================================================================
    // 3c) GMII 逐字节计数（2026-10-07 加；回答"MAC 到底在干什么"）
    //   为什么加：W0 只说"动过"。要分清两件完全不同的事：
    //     · **MAC 在连续不断地流一个永不结束的帧**（tx_en 一直是 1）⇒ 线上必然一个合法帧都没有；
    //     · **MAC 只发了一帧就停**（计数跳一下然后冻住）⇒ 帧是对的，故障在 PHY/RGMII 那一侧。
    //   GMII 是 1 字节/拍 ⇒ "tx_en 有效的拍数" = **发出的字节数**；`*RunMax` = 见过的最长连续长度
    //   （正常一帧 ≤ ~1518+8；**上万 = 永不结束**）。rx_dv 同理，用来判"PHY 到底有没有把帧送进来"。
    //   ⚠️ 这两个计数器在 `rgmii_clk` 域（GMII 信号就在这域），读回是**直接跨到 sys 域**的，
    //      多比特可能撕裂 ⇒ 判"动没动/量级"够用，**不拿它做精确值**；sticky 的 rxcHi/rxcLo 才是时钟判据。
    //   ⚠️ 不复位：FPGA 配置后全 0 就是基线（本窗口纯观测，不参与功能）。
    // ========================================================================
    reg [15:0] txBytes, rxBytes;
    reg [7:0]  txRun, txRunMax, rxRun, rxRunMax;
    always @(posedge rgmii_clk) begin
        if (gmii_tx_en) begin
            if (txBytes != 16'hFFFF) txBytes <= txBytes + 16'd1;
            if (txRun   != 8'hFF)    txRun   <= txRun   + 8'd1;
            if (txRun > txRunMax)    txRunMax <= txRun;
        end else txRun <= 8'd0;
        if (gmii_rx_dv) begin
            if (rxBytes != 16'hFFFF) rxBytes <= rxBytes + 16'd1;
            if (rxRun   != 8'hFF)    rxRun   <= rxRun   + 8'd1;
            if (rxRun > rxRunMax)    rxRunMax <= rxRun;
        end else rxRun <= 8'd0;
    end

    // W0..W5（窗口 0x100 对齐 ⇒ 用 addr[4:2] 选字）
    wire [31:0] dbgW0 = {rxCnt, txCnt, csrCnt, 4'b0, rxDvSeen, txEnSeen, rxcHi, rxcLo};
    wire [31:0] dbgW4 = {txBytes, rxBytes};                    // 发出的 / 收到的 字节数
    wire [31:0] dbgW5 = {rxRunMax, txRunMax, 16'h0};           // 最长连续长度（上万 ⇒ 永不结束的帧）
    wire [31:0] dbgDly = {16'h0, dly_txclk, dly_rx};   // 0xF000B01C：读回当前的 RGMII 延迟步
    wire [31:0] dbgWord = (addr[4:2] == 3'd0) ? dbgW0 :
                          (addr[4:2] == 3'd1) ? sysCnt :
                          (addr[4:2] == 3'd2) ? {1'b0, csrWAdr, csrWDat, csrWWe} :   // 32b
                          (addr[4:2] == 3'd3) ? {1'b0, csrRAdr, csrRDat, 1'b0} :
                          (addr[4:2] == 3'd4) ? dbgW4 :
                          (addr[4:2] == 3'd7) ? dbgDly :
                                                dbgW5;

    always @(posedge clk) begin
        if (rst) begin
            awWait <= 1'b0; wrPend <= 1'b0; rdPend <= 1'b0;
            awAddr <= 32'd0; wrData <= 32'd0; wrStrb <= 4'd0; rdAddr <= 32'd0;
            fst <= F_IDLE; isWr <= 1'b0; addr <= 32'd0; wdat <= 32'd0; wstrb <= 4'd0;
            rdat <= 32'd0;
        end else begin
            // ---- 接受（只在 F_IDLE；地址/数据必须在握手拍锁存）----
            if ((fst == F_IDLE) && !awWait && !wrPend && s_awvalid && s_awready) begin
                awWait <= 1'b1;
                awAddr <= s_awaddr;
            end
            if ((fst == F_IDLE) && awWait && !wrPend && s_wvalid && s_wready) begin
                wrPend <= 1'b1;
                wrData <= s_wdata;
                wrStrb <= s_wstrb;
                awWait <= 1'b0;
            end
            if ((fst == F_IDLE) && !awWait && !wrPend && !rdPend && s_arvalid && s_arready) begin
                rdPend <= 1'b1;
                rdAddr <= s_araddr;
            end

            case (fst)
                F_IDLE: begin
                    if (rdPend) begin
                        isWr <= 1'b0; addr <= rdAddr;
                        rdPend <= 1'b0; fst <= F_EXEC;
                    end else if (wrPend) begin
                        isWr <= 1'b1; addr <= awAddr; wdat <= wrData; wstrb <= wrStrb;
                        wrPend <= 1'b0; fst <= F_EXEC;
                    end
                end
                F_EXEC: begin
                    if (tgt_csr) begin
                        if (csr_ack) begin
                            rdat <= csr_dat_r;          // 读：字对齐回来，核自己取通道
                            fst  <= F_RESP;
                        end
                    end else if (tgt_dbg) begin
                        // 0xF000B01C（3'd7）**可写**：载入 RGMII 延迟步（其余地址写忽略）
                        if (isWr && (addr[4:2] == 3'd7)) begin
                            dly_rx    <= wdat[7:0];
                            dly_txclk <= wdat[15:8];
                        end
                        rdat <= dbgWord;                // 读：一拍就回（写也照回 OKAY）
                        fst  <= F_RESP;
                    end else if (tgt_oth) begin
                        rdat <= 32'd0;                  // 未接窗口：照样应答，绝不能让核挂死
                        fst  <= F_RESP;
                    end else begin                      // tgt_buf：一次 32bit 字访问（字节使能 = wstrb）
                        if (buf_ack) begin
                            rdat <= buf_dat_r;          // 读：整字回来，核自己取字节通道
                            fst  <= F_RESP;
                        end
                    end
                end
                F_RESP: begin
                    if (isWr ? s_bready : s_rready) fst <= F_IDLE;
                end
                default: fst <= F_IDLE;
            endcase
        end
    end

endmodule
