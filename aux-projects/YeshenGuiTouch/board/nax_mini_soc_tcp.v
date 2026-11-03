// ============================================================================
// nax_mini_soc —— NaxSocMini(SpinalHDL 生成) + NaxMiniGlue(Chisel 生成) 的组装层
//
// Task 8 交付物。sim 与板上都用这一份；差别只在 `mem_*` 往上一级接谁
// （仿真：sim/tb_naxmini.cpp 的内存模型；板上：src/soc/DDR3Bridge.scala 的 AXI 从口）。
//
// 端口名**全部逐字取自实测 dump**（不是猜）：
//   sed -n '/^module NaxSocMini/,/^);/p'   rtl/NaxSocMini.v
//   sed -n '/^module NaxMiniGlue/,/^);/p'  rtl/NaxMiniGlue.v
// 逐条对照结果：
//   NaxSocMini.mBus_*  (64bit, id 2bit, 有 awallStrb, 无 prot)  == NaxMiniGlue.io_cpuMem_*
//   NaxSocMini.pBus_*  (AXI4-Lite, 32bit, 带 3bit awprot/arprot) == NaxMiniGlue.io_pBus_*
//   两份模块头在这两组上**位宽与名字逐条一致**（见 src/NaxMiniGlue.scala 的 bundle 注释）。
//
// ⚠️ 2026-09-30（Task 17）**SoC 侧整条内存通路原生 64bit**（上位 spec：
//   `docs/superpowers/specs/2026-09-29-native-64bit-design.md` 方案 N）：
//   `NaxSocMini.mBus_*`（`--litedram-width 64` 生成的网表）→ glue 的 `io_cpuMem`（64bit）
//   → 装载选通 → glue 的 `io_mem`（64bit，`AXIIO64`）→ 本层顶层 `mem_*`（64bit）。
//   变的只有三根数据线的位宽：`wdata 31:0 → 63:0`、`wstrb 3:0 → 7:0`、`rdata 31:0 → 63:0`
//   （地址/len/size/burst/id/awallStrb 与 pBus 全部不变）。**本层不加任何降位宽桥**：
//   唯一那次 64↔256 的转换在 `DDR3Bridge` 内部的 32B 聚合里（板上由本层 `mem_*` 接过去）。
//   32bit 版旧网表留档在 `rtl32/NaxSocMini.v`（已被 T12/T13 证伪，只作对照）。
//
// ---------------------------------------------------------------------------
// ★ 中断位号（Task 9 对 DTS 时必须一致）：控制台中断接在
//     NaxSocMini.peripheral_externalInterrupts_port 的 **位 1**（不是位 0）。
//   依据（`NaxRiscv/src/main/scala/naxriscv/platform/litex/NaxSoc.scala:140-146`）：
//       for (i <- 0 to 31) yield (i != 0) generate new Area { plic.createInterruptSlave(i); flag := port(i) }
//   ⇒ **port 的位号 N 就是 PLIC 的源号 N，且位 0 根本没有被 generate 出来**（悬空）。
//   生成产物里同一条事实：`rtl/NaxSocMini.v:4394` `…toPlic_1_node_flag = peripheral_externalInterrupts_port[1]`
//   接进 `TilelinkPlic.io_sources[0]`，而 `io_sources` 是 31 位（源 1..31），**位 0 无人消费**。
//   ⇒ 若照字面把 io_irq 接到位 0，控制台中断会**静默丢失**（DTS 对不上、Linux 只能轮询）。
//   故取位 1 = PLIC 源 1（SiFive 映射：寄存器在 0xF0C0_0000 + 4*1）。该位号与
//   `src/NaxMiniGlue.scala` 的 `NaxMiniMap.CONSOLE_IRQ_BIT = 1` 一致。
//   本探针（sim/probe_console.S）走**纯轮询 THRE**，不依赖中断 ⇒ V1 结论不受此位号影响；
//   但 Task 9 写 DTS 的 `interrupts = <1>` 时必须用它。
//
// ---------------------------------------------------------------------------
// ★ 复位语义（SpinalHDL `asyncReset` vs Chisel `reset`）—— 两者**不一致**，已按语义正确处理：
//   · NaxSocMini.asyncReset：**异步**、高有效（产物 `rtl/NaxSocMini.v:60120`
//     `always @(posedge socClk or posedge asyncReset)`，用于复位控制器的 BufferCC 同步链）。
//   · NaxMiniGlue.reset：**同步**、高有效（产物 `rtl/NaxMiniGlue.v` 全程 `always @(posedge clock)`
//     + `if (reset)`，**没有任何** posedge/negedge reset 敏感项；Chisel 默认同步复位）。
//   极性相同（都是高有效），但**同步性不同**。把 asyncReset 直接接到 glue.reset 的后果是
//   "复位释放沿不与 soc_clk 对齐"（教科书式的 reset-removal 亚稳场景）⇒ 不用直连，
//   而在本层加一个**异步置位 / 同步释放**的复位同步器（下面 glue_rst_sync，2 个触发器），
//   从**同一个** async_reset 源派生 glue 的同步复位。这样：
//     · 置位沿仍是异步的（不用等时钟，与 NaxSocMini 一致）；
//     · 释放沿对齐 soc_clk，glue 内部所有触发器同拍出复位；
//     · NaxSocMini 本身继续吃原始 async_reset（它内部自带同步释放链，本来就这么设计）。
//
// ---------------------------------------------------------------------------
// ★ 装载期扣 CPU 复位：glue 的 `io_cpuReset`（= loadActive）OR 进 NaxSocMini.asyncReset。
//   这与 `src/NaxMiniGlue.scala:178` 的注释一致（"板级顶层把它 OR 进 NaxSocMini.asyncReset；
//   **不要**把它接进本模块的 reset"——本层严格遵守：cpu_reset 不参与 glue_reset）。
//   相位安全：`loadMode` 只在上电那一刻被采样、`loadActive` 形态上稳定，其释放沿即使异步
//   落在 soc_clk 附近也由 NaxSocMini 内部的 BufferCC 链同步释放。
// ============================================================================
module nax_mini_soc (
    input  wire        soc_clk,
    input  wire        async_reset,     // 异步、高有效（与 NaxSocMini.asyncReset 同语义）

    // ---- 内存主口：AXI4 master，**64bit data**/32bit addr、id 4bit（= NaxMiniGlue.io_mem / AXIIO64）----
    // 名字逐字对应 glue 的 `io_mem_*`，只是把 `io_` 换成 `mem_` ⇒ 一眼可对账。
    // Task 17：数据 3 根线 32→64bit（`wdata`/`wstrb`/`rdata`），其余与 32bit 时代逐字相同。
    output wire [3:0]  mem_ar_arid,
    output wire [31:0] mem_ar_araddr,
    output wire [7:0]  mem_ar_arlen,
    output wire [2:0]  mem_ar_arsize,
    output wire [1:0]  mem_ar_arburst,
    output wire [2:0]  mem_ar_arlock,
    output wire [3:0]  mem_ar_arcache,
    output wire [2:0]  mem_ar_arprot,
    output wire        mem_ar_arvalid,
    input  wire        mem_ar_arready,
    input  wire [3:0]  mem_r_rid,
    input  wire [63:0] mem_r_rdata,
    input  wire [1:0]  mem_r_rresp,
    input  wire        mem_r_rlast,
    input  wire        mem_r_rvalid,
    output wire        mem_r_rready,
    output wire [3:0]  mem_aw_awid,
    output wire [31:0] mem_aw_awaddr,
    output wire [7:0]  mem_aw_awlen,
    output wire [2:0]  mem_aw_awsize,
    output wire [1:0]  mem_aw_awburst,
    output wire [1:0]  mem_aw_awlock,
    output wire [3:0]  mem_aw_awcache,
    output wire [2:0]  mem_aw_awprot,
    output wire        mem_aw_awvalid,
    input  wire        mem_aw_awready,
    output wire [3:0]  mem_w_wid,
    output wire [63:0] mem_w_wdata,
    output wire [7:0]  mem_w_wstrb,
    output wire        mem_w_wlast,
    output wire        mem_w_wvalid,
    input  wire        mem_w_wready,
    input  wire [3:0]  mem_b_bid,
    input  wire [1:0]  mem_b_bresp,
    input  wire        mem_b_bvalid,
    output wire        mem_b_bready,

    // ---- 外设（控制台 / GPIO）----
    output wire        uart_txd,
    input  wire        uart_rxd,        // tb 拉空闲高
    input  wire [7:0]  gpio_in,
    output wire [7:0]  gpio_out,
    output wire [7:0]  gpio_dir,

    // ---- 装载链（板上 strap + TF 卡引脚 + 装载期 CPU 复位）----
    input  wire        load_mode,       // 1 = 装载模式（CPU 被扣复位）
    output wire        load_active,
    output wire        sd_sck,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output wire        sd_cs_n,
    output wire        cpu_reset,       // 1 = CPU 扣在复位（已 OR 进 NaxSocMini.asyncReset）

    // ---- 以太网装载器（第三装载器）：RGMII 直连板载 PHY0 ----
    // 引脚与官方 `mini-base管脚映射.xlsx` 逐格核对（PHY0_*）：
    //   RXC=D19 / RXCTL=H16 / RXD3..0=B19,A19,E16,D16
    //   TXC=G16 / TXCTL=D20 / TXD3..0=D21,C21,B21,E20 / phy_rstn=G25
    // ⚠️ 见 docs/superpowers/specs/2026-10-04-eth-loader-design.md：厂家栈必须带
    //    TXC `DELAY_SEL=1'b0`+`TDELAY_EN="TRUE"` / RX 原样（`DELAY_SEL=1'b1`）这组配方。
    input  wire        eth_rgmii_rxc,
    input  wire        eth_rgmii_rx_ctl,
    input  wire [3:0]  eth_rgmii_rxd,
    output wire        eth_rgmii_txc,
    output wire        eth_rgmii_tx_ctl,
    output wire [3:0]  eth_rgmii_txd,
    output wire        eth_phy_rstn,
    output wire        eth_released,    // 观察：ETH 装载完成（已放核）
    output wire [31:0] eth_rx_bytes,    // 观察：RX 域收到的数据字节数
    output wire [31:0] eth_wr_bytes,    // 观察：已写进 DDR 的数据字节数

    // ---- 观测：NaxSocMini 的 CsrTracer（可悬空）----
    output wire        tracer_valid,
    output wire [7:0]  tracer_payload

    // ================= ★ 观测端口组：pBus 事务级探针（Task 8 Step A）=================
    // 目的：pBus（NaxSocMini ↔ NaxMiniGlue）**完全在模块内部**，tb 在顶层看不见任何一笔
    //   MMIO 事务 ⇒ 之前只能靠"线上有没有出字节"这类现象反推。这里把每一根 pBus 线引到顶层，
    //   让装置能逐笔打印 AW/W/B/AR/R（含 addr/data/strb/resp/tvalid/tready/拍数）。
    // 性质：**纯观测**，一根都不参与功能（glue 的 io_pBus_* 本来就是最终连线，这里只是"多分一根给示波器"）。
    //   不消耗任何逻辑（Verilator 里是直连；综合时悬空即被优化掉）⇒ 板上顶层可整组悬空。
    //
    // ★ Task 9 Step 0：**整组用 `ifdef NAXMINI_DBG_PBUS` 关起来，默认不定义 ⇒ 顶层端口表干净**。
    //   理由：Task 14 的板级顶层与 `constraints/nax_mini.fdc` 不能被这 19 根观测线污染
    //   要复现 Task 8 的 pBus 逐笔探针时，编译命令行加 `-DNAXMINI_DBG_PBUS`
    //   （⚠️ 对 **Verilog** 是 `-D`，**不是** `-CFLAGS -D`——后者只作用于 C++ 侧）；
    //   tb 侧的 `TB_PEEK_CODE` 是另一回事（那是 C++ 宏，用 `-CFLAGS "-DTB_PEEK_CODE=1"`），
    //   两者需成对打开才能看到 pBus 事务。
    //   ⚠️ 坑（Task 9 实测）：`//` 注释**首个词**不能是 "Verilator"——verilator 会把这种注释
    //   当自己的 metacomment / pragma 去解析（把整行重排成 `/*verilator ...*/`）⇒ 报
    //   `syntax error, unexpected '/'`。所以这句注释的句子结构刻意避开该词打头。
`ifdef NAXMINI_DBG_PBUS
    ,
    output wire        dbg_pbus_awvalid,
    output wire        dbg_pbus_awready,
    output wire [31:0] dbg_pbus_awaddr,
    output wire [2:0]  dbg_pbus_awprot,
    output wire        dbg_pbus_wvalid,
    output wire        dbg_pbus_wready,
    output wire [31:0] dbg_pbus_wdata,
    output wire [3:0]  dbg_pbus_wstrb,
    output wire        dbg_pbus_bvalid,
    output wire        dbg_pbus_bready,
    output wire [1:0]  dbg_pbus_bresp,
    output wire        dbg_pbus_arvalid,
    output wire        dbg_pbus_arready,
    output wire [31:0] dbg_pbus_araddr,
    output wire [2:0]  dbg_pbus_arprot,
    output wire        dbg_pbus_rvalid,
    output wire        dbg_pbus_rready,
    output wire [31:0] dbg_pbus_rdata,
    output wire [1:0]  dbg_pbus_rresp
`endif
);

    // ========================================================================
    // 复位：异步置位 / 同步释放（见文件头★复位语义）
    // ========================================================================
    reg [1:0] glue_rst_sync;
    always @(posedge soc_clk or posedge async_reset) begin
        if (async_reset) glue_rst_sync <= 2'b11;
        else             glue_rst_sync <= {glue_rst_sync[0], 1'b0};
    end
    wire glue_reset = glue_rst_sync[1];      // 同步、高有效（Chisel reset 语义）

    // ========================================================================
    // 胶合块
    // ========================================================================
    wire        glue_irq;

    NaxMiniGlue u_glue (
        .clock          (soc_clk),
        .reset          (glue_reset),

        // ---- 上游从口 1：pBus（AXI4-Lite）← NaxSocMini ----
        .io_pBus_awvalid (pbus_awvalid),
        .io_pBus_awready (pbus_awready),
        .io_pBus_awaddr  (pbus_awaddr),
        .io_pBus_awprot  (pbus_awprot),
        .io_pBus_wvalid  (pbus_wvalid),
        .io_pBus_wready  (pbus_wready),
        .io_pBus_wdata   (pbus_wdata),
        .io_pBus_wstrb   (pbus_wstrb),
        .io_pBus_bvalid  (pbus_bvalid),
        .io_pBus_bready  (pbus_bready),
        .io_pBus_bresp   (pbus_bresp),
        .io_pBus_arvalid (pbus_arvalid),
        .io_pBus_arready (pbus_arready),
        .io_pBus_araddr  (pbus_araddr),
        .io_pBus_arprot  (pbus_arprot),
        .io_pBus_rvalid  (pbus_rvalid),
        .io_pBus_rready  (pbus_rready),
        .io_pBus_rdata   (pbus_rdata),
        .io_pBus_rresp   (pbus_rresp),

        // ---- 上游从口 2：cpuMem（AXI4）← NaxSocMini.mBus ----
        .io_cpuMem_awvalid   (mbus_awvalid),
        .io_cpuMem_awready   (mbus_awready),
        .io_cpuMem_awaddr    (mbus_awaddr),
        .io_cpuMem_awid      (mbus_awid),
        .io_cpuMem_awlen     (mbus_awlen),
        .io_cpuMem_awsize    (mbus_awsize),
        .io_cpuMem_awburst   (mbus_awburst),
        .io_cpuMem_awallStrb (mbus_awallStrb),
        .io_cpuMem_wvalid    (mbus_wvalid),
        .io_cpuMem_wready    (mbus_wready),
        .io_cpuMem_wdata     (mbus_wdata),
        .io_cpuMem_wstrb     (mbus_wstrb),
        .io_cpuMem_wlast     (mbus_wlast),
        .io_cpuMem_bvalid    (mbus_bvalid),
        .io_cpuMem_bready    (mbus_bready),
        .io_cpuMem_bid       (mbus_bid),
        .io_cpuMem_bresp     (mbus_bresp),
        .io_cpuMem_arvalid   (mbus_arvalid),
        .io_cpuMem_arready   (mbus_arready),
        .io_cpuMem_araddr    (mbus_araddr),
        .io_cpuMem_arid      (mbus_arid),
        .io_cpuMem_arlen     (mbus_arlen),
        .io_cpuMem_arsize    (mbus_arsize),
        .io_cpuMem_arburst   (mbus_arburst),
        .io_cpuMem_rvalid    (mbus_rvalid),
        .io_cpuMem_rready    (mbus_rready),
        .io_cpuMem_rdata     (mbus_rdata),
        .io_cpuMem_rid       (mbus_rid),
        .io_cpuMem_rresp     (mbus_rresp),
        .io_cpuMem_rlast     (mbus_rlast),

        // ---- 下游主口：内存（直接引到顶层；sim 接 tb 内存模型 / 板上接 DDR3Bridge）----
        .io_mem_ar_arid    (mem_ar_arid),
        .io_mem_ar_araddr  (mem_ar_araddr),
        .io_mem_ar_arlen   (mem_ar_arlen),
        .io_mem_ar_arsize  (mem_ar_arsize),
        .io_mem_ar_arburst (mem_ar_arburst),
        .io_mem_ar_arlock  (mem_ar_arlock),
        .io_mem_ar_arcache (mem_ar_arcache),
        .io_mem_ar_arprot  (mem_ar_arprot),
        .io_mem_ar_arvalid (mem_ar_arvalid),
        .io_mem_ar_arready (mem_ar_arready),
        .io_mem_r_rid      (mem_r_rid),
        .io_mem_r_rdata    (mem_r_rdata),
        .io_mem_r_rresp    (mem_r_rresp),
        .io_mem_r_rlast    (mem_r_rlast),
        .io_mem_r_rvalid   (mem_r_rvalid),
        .io_mem_r_rready   (mem_r_rready),
        .io_mem_aw_awid    (mem_aw_awid),
        .io_mem_aw_awaddr  (mem_aw_awaddr),
        .io_mem_aw_awlen   (mem_aw_awlen),
        .io_mem_aw_awsize  (mem_aw_awsize),
        .io_mem_aw_awburst (mem_aw_awburst),
        .io_mem_aw_awlock  (mem_aw_awlock),
        .io_mem_aw_awcache (mem_aw_awcache),
        .io_mem_aw_awprot  (mem_aw_awprot),
        .io_mem_aw_awvalid (mem_aw_awvalid),
        .io_mem_aw_awready (mem_aw_awready),
        .io_mem_w_wid      (mem_w_wid),
        .io_mem_w_wdata    (mem_w_wdata),
        .io_mem_w_wstrb    (mem_w_wstrb),
        .io_mem_w_wlast    (mem_w_wlast),
        .io_mem_w_wvalid   (mem_w_wvalid),
        .io_mem_w_wready   (mem_w_wready),
        .io_mem_b_bid      (mem_b_bid),
        .io_mem_b_bresp    (mem_b_bresp),
        .io_mem_b_bvalid   (mem_b_bvalid),
        .io_mem_b_bready   (mem_b_bready),

        // ---- 外设引脚 ----
        .io_uart_txd   (uart_txd),
        .io_uart_rxd   (uart_rxd),
        .io_gpio_in    (gpio_in),
        .io_gpio_out   (gpio_out),
        .io_gpio_dir   (gpio_dir),
        .io_irq        (glue_irq),

        // ---- 装载链 ----
        .io_loadMode   (load_mode),
        .io_loadActive (load_active),
        .io_sd_sck     (sd_sck),
        .io_sd_mosi    (sd_mosi),
        .io_sd_miso    (sd_miso),
        .io_sd_cs_n    (sd_cs_n),
        .io_cpuReset   (cpu_reset),

        // ---- 以太网装载器的字节流（RX 域）----
        .io_eth_rxClk    (eth_rx_clk),
        .io_eth_pllLock  (eth_pll_lock),
        // UDP 侧改吃 stream_group_mux 的双源输出（UDP 组 + TCP shim 组二选一）
        .io_eth_udpValid (eth_mux_valid),
        .io_eth_udpData  (eth_mux_data),
        .io_eth_udpLen   (eth_mux_len),
        .io_eth_released (eth_released),
        .io_eth_rxBytes  (eth_rx_bytes),
        .io_eth_wrBytes  (eth_wr_bytes),
        .io_sd_state     (eth_sd_state),
        .io_sd_err       (eth_sd_err),
        .io_sd_dbg       (eth_sd_dbg)
    );

    // ========================================================================
    // 以太网装载器：厂家 UDP/IP/MAC 栈（第三方独立副本）+ 薄包装
    //   `third_party/eth_stack_2_11/eth_mac_wrapper.v`（栈 + rgmii_interface + ref_clock PLL）
    // 时钟：栈全部跑在 **RX 域**（`eth_rx_clk` = PHY 的 RXC 经 PLL）；`pll_lock` 低 = 栈在复位。
    // ========================================================================
    wire        eth_rx_clk;
    wire        eth_pll_lock;
    wire        eth_udp_valid;
    wire [7:0]  eth_udp_data;
    wire [15:0] eth_udp_len;
    wire [3:0]  eth_sd_state;    // 诊断：SD 装载器 io.state（经反向信道回发）
    wire [3:0]  eth_sd_err;      // 诊断：SD 装载器 io.errCode
    wire [31:0] eth_sd_dbg;      // 诊断：SD 装载器 io.dbg（原始响应 R1/R7 + 错误码 + FSM + hIdx）

    // ---- TCP branch (eth_tcp_glue): RX fork in, framed TX out, shim groups ----
    wire eth_ft_valid;  wire [7:0] eth_ft_data;
    wire eth_ttx_valid; wire [7:0] eth_ttx_data;
    wire eth_sh_valid;  wire [7:0] eth_sh_data; wire [15:0] eth_sh_len; wire eth_sh_err;
    wire eth_mux_valid; wire [7:0] eth_mux_data; wire [15:0] eth_mux_len;
    // shim 熔断位：后续接诊断（eth_sh_err 只接到此处，暂无消费者）

    eth_mac_wrapper_tcp u_eth_mac (
        .rgmii_rxc    (eth_rgmii_rxc),
        .rgmii_rx_ctl (eth_rgmii_rx_ctl),
        .rgmii_rxd    (eth_rgmii_rxd),
        .rgmii_txc    (eth_rgmii_txc),
        .rgmii_tx_ctl (eth_rgmii_tx_ctl),
        .rgmii_txd    (eth_rgmii_txd),
        .o_rx_clk     (eth_rx_clk),
        .o_pll_lock   (eth_pll_lock),
        .o_rx_valid   (eth_udp_valid),
        .o_rx_data    (eth_udp_data),
        .o_rx_len     (eth_udp_len),
        // 反向信道（spec §4.3）：把 EthLoader 的"已收数据字节数"递给 wrapper 周期回发。
        // 与 glue 的 rx 域同一个时钟（都来自 PHY 的 RXC 经 PLL）⇒ 直连、无 CDC。
        .rxBytesIn    (eth_rx_bytes),
        // TCP 分支线：RX 原始 GMII 分叉出去，TCP 分支帧化 TX 仲裁回灌
        .o_fork_rx_valid(eth_ft_valid),
        .o_fork_rx_data (eth_ft_data),
        .i_tcp_tx_valid (eth_ttx_valid),
        .i_tcp_tx_data  (eth_ttx_data),
        // 诊断（SD 通路调试）：把 SD 装载器 state/errCode 一起挂在同一帧尾部回发
        .sdDbgIn      (eth_sd_dbg)
    );

    // ---- TCP 分支例化（wrapper 分叉 RX 进、帧化 TX 出；shim 组 + 双源 mux）----
    eth_tcp_wrapper u_eth_tcp (
        .eth_clk(eth_rx_clk), .pll_lock(eth_pll_lock), .soc_clk(soc_clk),
        .fork_rx_valid(eth_ft_valid), .fork_rx_data(eth_ft_data),
        .tcp_tx_valid(eth_ttx_valid), .tcp_tx_data(eth_ttx_data),
        .shim_valid(eth_sh_valid), .shim_data(eth_sh_data),
        .shim_len(eth_sh_len), .shim_err(eth_sh_err),
        .wrBytes(eth_wr_bytes)
    );
    stream_group_mux u_eth_mux (
        .clk(eth_rx_clk), .rst(~eth_pll_lock),
        .u_valid(eth_udp_valid), .u_data(eth_udp_data), .u_len(eth_udp_len),
        .t_valid(eth_sh_valid), .t_data(eth_sh_data), .t_len(eth_sh_len),
        .m_valid(eth_mux_valid), .m_data(eth_mux_data), .m_len(eth_mux_len)
    );

    // ---- PHY 复位 = **独立上电复位（POR）** ----
    // ⚠️ 不接 `eth_pll_lock`：那只 PLL 的输入正是 PHY 的 `rgmii_rxc` ⇒ 闭环，链路一掉 PHY 就永久复位
    //    （只能给 PHY 断电）。也不恒 1：PHY 拿不到复位脉冲 ⇒ 上电要等 ~1.5min、且收不到 UDP。
    //    POR 版 2026-10-05 实测 **ping ≤5s 就通** ✓（~10.5ms 复位脉冲 = 20bit @100MHz，PHY 要求 ≥10ms）。
    reg [19:0] phy_por_cnt = 20'd0;
    always @(posedge soc_clk)
        if (phy_por_cnt != 20'hF_FFFF) phy_por_cnt <= phy_por_cnt + 20'd1;
    assign eth_phy_rstn = (phy_por_cnt == 20'hF_FFFF);

    // ========================================================================
    // 上游 fabric
    // ========================================================================
    // 控制台中断 ⇒ externalInterrupts **位 1**（= PLIC 源 1；位 0 在 NaxSoc 里根本没接到 PLIC，
    // 见文件头★中断位号）。其余 30 位恒 0。
    wire [31:0] ext_int = {30'b0, glue_irq, 1'b0};

    // 装载期把 CPU 扣在复位（OR 进 asyncReset；**不**进 glue_reset，见文件头★）
    wire soc_async_reset = async_reset | cpu_reset;

    // ---- mBus / pBus 中间线（位宽逐字对照 dump；Task 17 起 mBus 数据三根线是 64bit）----
    wire        mbus_awvalid, mbus_awready;
    wire [31:0] mbus_awaddr;
    wire [1:0]  mbus_awid;
    wire [7:0]  mbus_awlen;
    wire [2:0]  mbus_awsize;
    wire [1:0]  mbus_awburst;
    wire        mbus_awallStrb;
    wire        mbus_wvalid, mbus_wready;
    wire [63:0] mbus_wdata;
    wire [7:0]  mbus_wstrb;
    wire        mbus_wlast;
    wire        mbus_bvalid, mbus_bready;
    wire [1:0]  mbus_bid, mbus_bresp;
    wire        mbus_arvalid, mbus_arready;
    wire [31:0] mbus_araddr;
    wire [1:0]  mbus_arid;
    wire [7:0]  mbus_arlen;
    wire [2:0]  mbus_arsize;
    wire [1:0]  mbus_arburst;
    wire        mbus_rvalid, mbus_rready;
    wire [63:0] mbus_rdata;
    wire [1:0]  mbus_rid, mbus_rresp;
    wire        mbus_rlast;

    wire        pbus_awvalid, pbus_awready;
    wire [31:0] pbus_awaddr;
    wire [2:0]  pbus_awprot;
    wire        pbus_wvalid, pbus_wready;
    wire [31:0] pbus_wdata;
    wire [3:0]  pbus_wstrb;
    wire        pbus_bvalid, pbus_bready;
    wire [1:0]  pbus_bresp;
    wire        pbus_arvalid, pbus_arready;
    wire [31:0] pbus_araddr;
    wire [2:0]  pbus_arprot;
    wire        pbus_rvalid, pbus_rready;
    wire [31:0] pbus_rdata;
    wire [1:0]  pbus_rresp;

    NaxSocMini u_soc (
        .socClk     (soc_clk),
        .asyncReset (soc_async_reset),
        .peripheral_externalInterrupts_port (ext_int),

        // ---- mBus（AXI4 主）→ 胶合块的 cpuMem 从口 ----
        .mBus_awvalid   (mbus_awvalid),
        .mBus_awready   (mbus_awready),
        .mBus_awaddr    (mbus_awaddr),
        .mBus_awid      (mbus_awid),
        .mBus_awlen     (mbus_awlen),
        .mBus_awsize    (mbus_awsize),
        .mBus_awburst   (mbus_awburst),
        .mBus_awallStrb (mbus_awallStrb),
        .mBus_wvalid    (mbus_wvalid),
        .mBus_wready    (mbus_wready),
        .mBus_wdata     (mbus_wdata),
        .mBus_wstrb     (mbus_wstrb),
        .mBus_wlast     (mbus_wlast),
        .mBus_bvalid    (mbus_bvalid),
        .mBus_bready    (mbus_bready),
        .mBus_bid       (mbus_bid),
        .mBus_bresp     (mbus_bresp),
        .mBus_arvalid   (mbus_arvalid),
        .mBus_arready   (mbus_arready),
        .mBus_araddr    (mbus_araddr),
        .mBus_arid      (mbus_arid),
        .mBus_arlen     (mbus_arlen),
        .mBus_arsize    (mbus_arsize),
        .mBus_arburst   (mbus_arburst),
        .mBus_rvalid    (mbus_rvalid),
        .mBus_rready    (mbus_rready),
        .mBus_rdata     (mbus_rdata),
        .mBus_rid       (mbus_rid),
        .mBus_rresp     (mbus_rresp),
        .mBus_rlast     (mbus_rlast),

        // ---- pBus（AXI4-Lite 主）→ 胶合块的 pBus 从口 ----
        .pBus_awvalid   (pbus_awvalid),
        .pBus_awready   (pbus_awready),
        .pBus_awaddr    (pbus_awaddr),
        .pBus_awprot    (pbus_awprot),
        .pBus_wvalid    (pbus_wvalid),
        .pBus_wready    (pbus_wready),
        .pBus_wdata     (pbus_wdata),
        .pBus_wstrb     (pbus_wstrb),
        .pBus_bvalid    (pbus_bvalid),
        .pBus_bready    (pbus_bready),
        .pBus_bresp     (pbus_bresp),
        .pBus_arvalid   (pbus_arvalid),
        .pBus_arready   (pbus_arready),
        .pBus_araddr    (pbus_araddr),
        .pBus_arprot    (pbus_arprot),
        .pBus_rvalid    (pbus_rvalid),
        .pBus_rready    (pbus_rready),
        .pBus_rdata     (pbus_rdata),
        .pBus_rresp     (pbus_rresp),

        // ---- 观测（可悬空）----
        .patcher_tracer_valid   (tracer_valid),
        .patcher_tracer_payload (tracer_payload)
    );

    // ========================================================================
    // ★ 观测端口组接线（纯直连，见文件头/端口处的说明）
    // ★ Task 9 Step 0：与端口组同一个 `ifdef`；默认不定义 ⇒ 这 19 根线在顶层完全不存在。
    // ========================================================================
`ifdef NAXMINI_DBG_PBUS
    assign dbg_pbus_awvalid = pbus_awvalid;
    assign dbg_pbus_awready = pbus_awready;
    assign dbg_pbus_awaddr  = pbus_awaddr;
    assign dbg_pbus_awprot  = pbus_awprot;
    assign dbg_pbus_wvalid  = pbus_wvalid;
    assign dbg_pbus_wready  = pbus_wready;
    assign dbg_pbus_wdata   = pbus_wdata;
    assign dbg_pbus_wstrb   = pbus_wstrb;
    assign dbg_pbus_bvalid  = pbus_bvalid;
    assign dbg_pbus_bready  = pbus_bready;
    assign dbg_pbus_bresp   = pbus_bresp;
    assign dbg_pbus_arvalid = pbus_arvalid;
    assign dbg_pbus_arready = pbus_arready;
    assign dbg_pbus_araddr  = pbus_araddr;
    assign dbg_pbus_arprot  = pbus_arprot;
    assign dbg_pbus_rvalid  = pbus_rvalid;
    assign dbg_pbus_rready  = pbus_rready;
    assign dbg_pbus_rdata   = pbus_rdata;
    assign dbg_pbus_rresp   = pbus_rresp;
`endif

endmodule
