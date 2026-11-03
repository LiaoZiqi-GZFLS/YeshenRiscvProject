// ============================================================================
// yeshen_mini_soc —— VexiiRiscv(SpinalHDL 生成的 RV32 Linux 核网表) + YeshenSocGlue
//                    (Chisel/firtool 生成的胶合块) 的**板级组装层**
//
// 由 sibling 工程 NaxYeshenLinux 的 `board/nax_mini_soc.v` 改核而来：
//   NaxSocMini + NaxMiniGlue  ⇒  VexiiRiscv + YeshenSocGlue
// 本文件**外部端口与 nax_mini_soc 逐字相同**（名字/位宽/方向全同），所以
//   `board/yeshen_mini_board_top.v`（PLL + 本层 + DDR3Bridge + DDR3 IP）与
//   `constraints/yeshen_mini.fdc` 只需把模块名/实例名换掉，**引脚映射一格不动**。
//
// ---------------------------------------------------------------------------
// 【1】上游核：`rtl/vexiiriscv/VexiiRiscv.v`（模块 `VexiiRiscv`，2MB 网表）
//   单 `clk` + `reset`（**同步、高有效**）。它对外只有**三条 AXI 主口** + 五个
//   privileged 输入（rdtime + 4 个中断）：
//     · `FetchL1Axi4Plugin_logic_axi_{ar,r}_*`         : AXI4 只读，addr32/data64
//     · `LsuL1Axi4Plugin_logic_axi_{aw,w,b,ar,r}_*`    : 全 AXI4，data64，wstrb8
//     · `LsuCachelessAxi4Plugin_logic_axi_{aw,w,b,ar,r}_*`: **单拍** AXI4，data32，
//                                                          **无 len/burst**
//     · `PrivilegedPlugin_logic_rdtime[63:0]` / `..._int_m_timer` /
//       `..._int_m_software` / `..._int_m_external` / `..._int_s_external`
//   端口名逐字取自 `sed -n '/^module VexiiRiscv/,/^);/p' rtl/vexiiriscv/VexiiRiscv.v`。
//
// 【2】下游胶合块：`rtl/YeshenSocGlue.v`（模块 `YeshenSocGlue`，131KB）
//   单 `clock` + `reset`（**同步、高有效**，Chisel 默认语义）。它自带 PLIC / CLINT /
//   UART16550 / GPIO / SD 装载器 / UART 装载器（子模块全在同文件内，无外部黑盒）。
//   端口名逐字取自 `grep -n '^module YeshenSocGlue' -A 130 rtl/YeshenSocGlue.v`。
//
// ---------------------------------------------------------------------------
// 【3】三条 AXI 总线：**直通**（signal-name-for-signal-name，一根中间逻辑都不加）
//     VexiiRiscv.FetchL1Axi4              ⇄  YeshenSocGlue.io_cpuFetch_*
//     VexiiRiscv.LsuL1Axi4               ⇄  YeshenSocGlue.io_cpuLsu_*
//     VexiiRiscv.LsuCachelessAxi4        ⇄  YeshenSocGlue.io_cpuIo_*
//   两侧名字与位宽逐条对齐（见下面例化处的成对连接）：
//     · cpuFetch : ar{addr,len,size,burst,cache,prot} + r{data,resp,last}（无 id）
//     · cpuLsu   : aw{addr,len,size,burst,cache,prot} + w{data,strb,last} +
//                  b{resp} + ar{...} + r{data,resp,last}（无 id）
//     · cpuIo    : aw{addr,size,cache,prot} + w{data,strb,last} + b{resp} +
//                  ar{addr,size,cache,prot} + r{data,resp,last}（**无 len/burst**）
//   胶合块内部把这三条主口做成仲裁 / 解码（外设窗口 + 内存口），CPU 侧不需要知道。
//
// 【4】CLINT / PLIC：胶合块**自带**，核只用它的 privileged 输入
//     glue.io_rdtime   [63:0]  →  CPU.PrivilegedPlugin_logic_rdtime
//     glue.io_intMTime         →  CPU..._harts_0_int_m_timer     (mtip / CLINT)
//     glue.io_intMSoft         →  CPU..._harts_0_int_m_software  (msip / CLINT)
//     glue.io_intMExt          →  CPU..._harts_0_int_m_external  (meip / PLIC)
//     glue.io_intSExt          →  CPU..._harts_0_int_s_external  (seip / PLIC)
//   ★ 中断位号（写 DTS 时必须一致）：胶合块的 PlicAlite 只有**两个源**（实读
//     `rtl/YeshenSocGlue.v:4169-4172`）：
//       源 1 = 控制台 UART 中断（`_console_io_irq`，`pending_1`）
//       源 2 = LiteEth 网卡中断（`io_ethIrq`，`pending_2`）
//     ⇒ DTS 里 ttyS0 用 `interrupts = <1>`、网卡用 `interrupts = <2>`（PLIC 源号）。
//     核侧的中断输入由胶合块算好后给出（本层不再拼 `externalInterrupts` 向量）。
//
// 【5】以太网：LiteEth 落地层在**本层内部**例化（与 template 同构）
//     `board/liteeth_wrap.v` 提供 AXI4-Lite 从口（接 glue.io_ethAxi_*）+ RGMII PHY 引脚，
//     并产出一根 `irq` → 本层送给 **glue.io_ethIrq**（= PLIC 源 2，见【4】）。
//     ⚠️ 与 template 的差别只有一处：template 把 eth_irq 拼进 NaxSocMini 的
//        externalInterrupts 向量；这里 eth_irq 直接进胶合块的 PLIC（io_ethIrq）。
//
// ---------------------------------------------------------------------------
// 【6】★ 复位语义（与 template 完全一致，务必遵守）
//   · 本层对外仍是 **异步、高有效** 的 `async_reset`（board top 给 `~soc_resetn`）。
//   · `VexiiRiscv.reset` 需要**同步、高有效** ⇒ 用下面的 2-FF「异步置位 / 同步释放」
//     把 `async_reset` 同步成 `glue_reset`，再把 `glue_reset | cpu_reset` 喂给核
//     （`cpu_reset` = 胶合块的 `io_cpuReset`，装载器当主人期间扣住核）。
//   · `YeshenSocGlue.reset` **只吃 `glue_reset`，不吃 `cpu_reset`**：
//     装载器（SD / UART / LiteEth）必须在核被扣复位时**继续运行**，否则装载本身跑不起来
//     （这正是 template 文件头 ★装载期扣 CPU 复位 那段的规则）。
//   · 极性均为高有效；置位沿异步（上电即复位，不用等时钟），释放沿对齐 soc_clk。
//
// 【7】★ 内存通路：**原生 64bit**（与 template / DDR3Bridge.io_axi_* 一致）
//   本层 `mem_*` = glue 的 `io_mem_*`（AXIIO64：id 4bit / data 64bit），直接引到顶层；
//   board top 原样接到 `DDR3Bridge` 的 64bit AXI4 从口。唯一一次 64↔256 的聚合在桥内。
//   本层**不加任何降位宽桥**。
//
// 【8】★ pBus 探针：本设计（VexiiRiscv + YeshenSocGlue）**没有 pBus / cpuMem / mBus**
//   —— 核与外设之间的三条 AXI 已经在上面逐条对接。template 的 `NAXMINI_DBG_PBUS`
//   观测组（原本挂在 NaxSocMini↔NaxMiniGlue 的 pBus 上）在本层**无对象可观测**，
//   但为保持"外部端口逐字相同"的契约，端口组仍按同一 `ifdef` 保留（默认不定义），
//   实际驱动恒 0（见文件末 `ifdef` 段）。它不影响任何功能。
//
// 【9】★ NPU：Y1 自研小型 YuNet CNN 加速器（`y1/gen/NpuTop.v`，SpinalHDL 生成；2026-10-08 C2.2）
//   · 寄存器窗从口（AxiLite4）← glue 的 `io_npuAxi_*`（窗 `0xF000_C000`，16 KiB；胶合块解码）。
//   · 内存主口（AXI4，addr 28bit / data 64bit / id 4bit）→ glue 的 `io_npuMem_*`，**汇入胶合块
//     §3.5 的同一个汇聚点**（与 CPU 三条主口共享单 outstanding 仲裁 + 组间轮转），不另造仲裁器。
//   · 中断 `irq`（电平保持，主机写 `CTRL.soft_reset` 清源）→ glue 的 `io_npuIrq` = PLIC **源 3**
//     ⇒ DTS 里 NPU 设备用 `interrupts = <3>`（源 1=控制台、源 2=LiteEth、源 3=NPU）。
//   · 复位：**C3.18 Round3（R3-4）起 NPU 网表是同步复位**（`always @(posedge clk)`，
//     生成器统一 `ClockDomainConfig(resetKind = SYNC)`）——本层仍旧给它 `soc_cpu_reset`
//     （= `glue_reset | cpu_reset`），但该信号**本身就是 `soc_clk` 域的同步量**
//     （`glue_rst_sync` 2 拍同步器 + `loadActive` 胶合 FF）⇒ 接到同步复位口**不产生 CDC**、
//     也不丢任何"异步 assert"性质（见下 `glue_rst_sync` 一段）。改同步的收益（板级实测）：
//     原先 NPU 14 个异步 always 块把 `soc_cpu_reset` 灌成扇出 8.8 万+ 的网、并造出 9,947 个
//     recovery 违例端点（WNS −1.431）；同步后该族变成普通同步检查，复位网变成普通高扇出数据网
//     （可交由 ADS/PDS 自动 fanout 缓冲）。端口名逐字取自
//     `sed -n '/^module NpuTop/,/^);/p' y1/gen/NpuTop.v`（端口集未变，只是复位语义变了）。
//   · 观测/引脚：**不接**任何 LED/引脚（本任务范围）。
//
// 【10】★ N2 / N2b / N5b（2026-10-11，Y1「NPU 独立时钟域」）：`npu_clk` 输入 + **NpuTop 搬进该域**
//   · `npu_clk` = NPU 独立时钟域时钟（**56.250MHz**，T-18c 起；N2b–t18b 期为 50.000MHz）—— **N2b 起由第二颗独立板级 PLL**
//     （`board/pll_50m.v` 的一颗 GTP_GPLL，VCO=675MHz、RATIO0=13.5）经 BUFG 生成；
//     N2（commit 3f5f791）曾是 `cpu_clk ÷ 2`（相位耦合的回退，已被用户弃用）。
//     为什么不是复用 PLL 的 clkout1 见 `board/pll_100m_125m.v` 的【N2 追加】段
//     —— 单 VCO 下 clkout1 只能整数分频，算术上做不出精确 50.000。
//   · **N5b 起 `NpuTop` 整块搬进 `npu_clk`**（`.clk(npu_clk)`）—— 这就是 spec §3-A 的落点：
//     NPU 的时序不再封顶 `cpu_clk`。NPU 的三个对外接口在 **glue 边界**做 CDC（见【11】），
//     glue 的 pBus 译码 / §3.5 汇聚点在 **cpu_clk 全程不变**。
//   · **N2/N2b 的 `npu_clk_alive` 脚手架已删**（`npu_clk_alive_r` 1bit 翻转寄存器 + 该端口 +
//     板级诊断那一字节）：NPU 域本身就给了 `npu_clk` 一个**真实的大负载**（`NpuTop` + 桥的
//     npu 侧 + NpuResetSync 的 npu 域），不再需要"喂活"防悬空清理。
//   ⚠️ 本层端口表因此比 `nax_mini_soc` **多一个**（`npu_clk`）；
//     板级顶层 `yeshen_mini_board_top` 的端口表与 `constraints/yeshen_mini.fdc` **一格未动**。
//
// 【11】★ N5b（2026-10-11，Y1「NPU 独立时钟域」Task N5b）：三处 CDC 桥 + 复位同步器的**板级集成**
//   由 glue（cpu_clk）到 `NpuTop`（npu_clk）的三条路各插一座 N3/N4/N5 已单测过的异步桥
//   （**在 Verilog 层例化其网表**，glue 的 Chisel **不改**）：
//     (a) **主机寄存器窗**（AXI4-Lite）：glue.io_npuAxi_*（cpu 主）→ `NpuAxiLiteCdc` cpu 从口；
//         桥 npu 主口 → `NpuTop.axilite_*`。5 条 4 相握手管道（aw/w/b/ar/r）；载荷即端口名。
//     (b) **内存主口**（AXI4 addr28/data64/id4）：`NpuTop.axi_*` → `NpuMemCdc` npu 从口；
//         桥 cpu 主口 → glue.io_npuMem_*（**喂进 §3.5 那个汇聚点，汇聚点一字未改**）。
//         burst 描述子一次跨、数据按拍"单拍一手握"跨（beat-serialized）。
//     (c) **IRQ**（npu 电平 → cpu 电平）：`NpuTop.irq` → `NpuIrqCdc` 2-FF 电平同步 → glue.io_npuIrq
//         （= PLIC 源 3）。电平保持语义不变（清走 CTRL.soft_reset，经 (a) 的寄存器写跨到 npu 域）。
//     (d) **复位**：`NpuResetSync`（异步置位 / 同步释放）产两域低有效复位，**cpu 先、npu 后**释放
//         （npu 释放被 cpu 的"已就绪"电平经 2-FF 门住）⇒ 复位期间 NPU 不出错误事务。
//         `NpuTop.reset` = `~npuRstn`（npu 域同步、高有效，与 NPU 网表的同步复位口同语义）。
//   · 时钟域账：glue / CPU / DDR3Bridge / §3.5 汇聚点 / 三条 CPU 主口 = `cpu_clk`；
//     `NpuTop` + 三座桥的 npu 侧 + NpuResetSync 的 npu 域 = `npu_clk`。两域异步（fdc 已声明）。
//   · 载荷位宽逐条对齐（glue 端口表实测）：io_npuMem_awaddr 是 **28bit**（与 NpuTop.axi_*、
//     桥的 cpuMem_* 同宽，**无需零扩展**）；io_npuAxi_* 与 NpuTop.axilite_* 同为 32bit。
//
// 【12】★ DMA：Y1 通用 DMA 引擎（`y1/gen/DmaEngine.v`，SpinalHDL 生成；2026-10-13 DMA Phase-2b）
//   · 寄存器窗从口（AxiLite4）← glue 的 `io_dmaAxi_*`（窗 `0xF000_6000`，**256 B**；胶合块解码）。
//   · 内存主口（AXI4，addr 28bit / data 64bit / id 4bit）→ glue 的 `io_dmaMem_*`，**汇入胶合块
//     §3.5 那个汇聚点**（第 6 个主人；与 NPU 同形 ⇒ 28→32 零扩展 + id 丢弃在胶合里做）。
//   · 中断 `irq`（电平保持 = GBL_DONE|GBL_ERR，主机写该通道 CH_STATUS 的 w1c 清源）
//     → glue.io_dmaIrq = PLIC **源 4**。
//   ★ 与 NPU 的关键不同：DMA 引擎**整块跑 `cpu_clk`（soc_clk）**（spec §4.2 的裁决：主口归 cpu_clk，
//     到 DDR 无 CDC）⇒ 三条接口**都不需要异步桥**，直连胶合块即可。端口名逐字取自
//     `sed -n '/^module DmaEngine/,/^);/p' y1/gen/DmaEngine.v`（实测 dump，不是猜）。
//   · 每通道流口（RD 推出 / WR 填入）本层暂时 **结构化空闲**（rd_ready=0 / wr_valid=0）——
//     Phase-2c 接第一个真客户（SD 装载器 / 网络槽）时换成客户的字节流。
// ============================================================================
module yeshen_mini_soc (
    input  wire        soc_clk,
    input  wire        cpu_clk,         // 独立 CPU 时钟域（与 soc_clk 异步；2026-10-18 clock split）
    input  wire        async_reset,     // 异步、高有效（与 template / board top 同语义）

    // ---- ★ N2/N5b：NPU 独立时钟域（56.25MHz，T-18c 起；第二颗板级 PLL 出；见文件头【10】/【11】）----
    input  wire        npu_clk,         // NpuTop 的时钟 + 三座桥/reset sync 的 npu 域时钟

    // ---- 内存主口：AXI4 master，**64bit data**/32bit addr、id 4bit（= YeshenSocGlue.io_mem）----
    // 名字逐字对应 glue 的 `io_mem_*`（只把 `io_` 换成 `mem_`）⇒ 一眼可对账。
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
    input  wire [12:0] gpio_in,
    output wire [12:0] gpio_out,
    output wire [12:0] gpio_dir,
    input  wire        ctpIrq,          // CTP_INT（板级 2FF+反相）⇒ PLIC 源 5

    // ---- 装载链（板上 strap + TF 卡引脚 + 装载期 CPU 复位）----
    input  wire        load_mode,       // 1 = 装载模式（CPU 被扣复位）
    output wire        load_active,
    output wire        sd_sck,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output wire        sd_cs_n,
    output wire        cpu_reset,       // 1 = CPU 扣在复位（已 OR 进 VexiiRiscv.reset）

    // ---- 以太网：RGMII 直连板载 PHY0（LiteEth 落地层在本层内部）----
    // 引脚与官方 `mini-base管脚映射.xlsx` 逐格核对（PHY0_*）：
    //   RXC=D19 / RXCTL=H16 / RXD3..0=B19,A19,E16,D16
    //   TXC=G16 / TXCTL=D20 / TXD3..0=D21,C21,B21,E20 / phy_rstn=G25
    input  wire        eth_rgmii_rxc,
    input  wire        eth_rgmii_rx_ctl,
    input  wire [3:0]  eth_rgmii_rxd,
    output wire        eth_rgmii_txc,
    output wire        eth_rgmii_tx_ctl,
    output wire [3:0]  eth_rgmii_txd,
    output wire        eth_phy_rstn,
    // ★ 2026-10-07：`eth_rgmii_alive` = "网口 PHY 的 RXC 在跳"（灯亮 = 时钟在跑）。
    //   `rgmii_clk` 是 `u_liteeth` 内部时钟，上层看不见 ⇒ 由 wrap 引出这个 1 位判据给板级 LED。
    output wire        eth_rgmii_alive,
    output wire        eth_released,    // 观察：恒 0（LiteEth 的计数在 MAC 的 CSR 里）
    output wire [31:0] eth_rx_bytes,    // 观察：恒 0
    output wire [31:0] eth_wr_bytes,    // 观察：恒 0

    // ---- 观测：template 的 CsrTracer（VexiiRiscv 无此口）⇒ 恒 0 ----
    output wire        tracer_valid,
    output wire [7:0]  tracer_payload,

    // ---- ★ V1（2026-10-20）：VIDEO CSR 窗从口（AxiLite4 32/32）← glue.io_videoAxi_* ----
    // 窗 `0xF000_7400`（1 KiB）由胶合块解码（Task 6）；胶合块已把窗内偏移放在低 10 位，
    // 故高 22 位恒 0（`assign io_videoAxi_* = {22'h0, io_cpuIo_*addr[9:0]}`，实读胶合块）。
    // 端口名/位宽与 `io_videoAxi_*` **逐条同名同宽**（只去掉 io_ 前缀），方向翻转照 AXI 语义。
    // 接收方 = 板级顶层例化的 `video_regs u_video_regs`（与 LiteEth/NPU/DMA 窗同款做法）。
    output wire        video_awvalid,
    input  wire        video_awready,
    output wire [31:0] video_awaddr,
    output wire [2:0]  video_awprot,
    output wire        video_wvalid,
    input  wire        video_wready,
    output wire [31:0] video_wdata,
    output wire [3:0]  video_wstrb,
    input  wire        video_bvalid,
    output wire        video_bready,
    input  wire [1:0]  video_bresp,
    output wire        video_arvalid,
    input  wire        video_arready,
    output wire [31:0] video_araddr,
    output wire [2:0]  video_arprot,
    input  wire        video_rvalid,
    output wire        video_rready,
    input  wire [31:0] video_rdata,
    input  wire [1:0]  video_rresp

    // ================= ★ 观测端口组：pBus 事务级探针（保留契约，本设计恒 0）=================
    // 详见文件头【8】：VexiiRiscv + YeshenSocGlue 之间没有 pBus，本组端口只为保持
    // 与 `nax_mini_soc` 的外部端口逐字相同而保留（默认 `ifdef` 不定义 ⇒ 顶层端口表干净）。
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
    // 复位：异步置位 / 同步释放（见文件头【6】）
    // ========================================================================
    reg [1:0] glue_rst_sync;
    always @(posedge soc_clk or posedge async_reset) begin
        if (async_reset) glue_rst_sync <= 2'b11;
        else             glue_rst_sync <= {glue_rst_sync[0], 1'b0};
    end
    wire glue_reset = glue_rst_sync[1];      // 同步、高有效（Chisel reset 语义）

    // 核需要**同步**复位：同步板级复位 OR 装载期 cpu_reset（见文件头【6】）。
    // 注：`cpu_reset` 是本模块的**输出端口**（wire），由下面胶合块的 io_cpuReset 驱动，
    //     此处不再另声明同名 wire（否则 Verilator 报 Duplicate declaration）。
    wire        soc_cpu_reset = glue_reset | cpu_reset;

    // ========================================================================
    // ★ N5b：N2/N2b 的 `npu_clk_alive` 脚手架（1bit 翻转寄存器 + 回读端口 + 板级诊断字节）
    //   **已删除** —— NpuTop 现在整块跑 `npu_clk`（+ 三座桥的 npu 侧 + NpuResetSync 的 npu 域）
    //   ⇒ `npu_clk` 有了**真实的大功能负载**，不再需要"喂活"来防悬空清理（见文件头【10】）。
    // ========================================================================

    // ========================================================================
    // 三条 AXI 总线的中间网（名字 = CPU 侧口径；两端逐条对接，见文件头【3】）
    // ========================================================================
    // ---- cpuFetch（AXI4 只读，addr32 / data64）----
    wire        fetch_ar_valid, fetch_ar_ready;
    wire [31:0] fetch_ar_addr;
    wire [7:0]  fetch_ar_len;
    wire [2:0]  fetch_ar_size;
    wire [1:0]  fetch_ar_burst;
    wire [3:0]  fetch_ar_cache;
    wire [2:0]  fetch_ar_prot;
    wire        fetch_r_valid, fetch_r_ready;
    wire [63:0] fetch_r_data;
    wire [1:0]  fetch_r_resp;
    wire        fetch_r_last;

    // ---- cpuLsu（全 AXI4，data64 / wstrb8）----
    wire        lsu_aw_valid, lsu_aw_ready;
    wire [31:0] lsu_aw_addr;
    wire [7:0]  lsu_aw_len;
    wire [2:0]  lsu_aw_size;
    wire [1:0]  lsu_aw_burst;
    wire [3:0]  lsu_aw_cache;
    wire [2:0]  lsu_aw_prot;
    wire        lsu_w_valid, lsu_w_ready;
    wire [63:0] lsu_w_data;
    wire [7:0]  lsu_w_strb;
    wire        lsu_w_last;
    wire        lsu_b_valid, lsu_b_ready;
    wire [1:0]  lsu_b_resp;
    wire        lsu_ar_valid, lsu_ar_ready;
    wire [31:0] lsu_ar_addr;
    wire [7:0]  lsu_ar_len;
    wire [2:0]  lsu_ar_size;
    wire [1:0]  lsu_ar_burst;
    wire [3:0]  lsu_ar_cache;
    wire [2:0]  lsu_ar_prot;
    wire        lsu_r_valid, lsu_r_ready;
    wire [63:0] lsu_r_data;
    wire [1:0]  lsu_r_resp;
    wire        lsu_r_last;

    // ---- cpuIo（LsuCacheless，单拍 AXI4，data32，**无 len/burst**）----
    wire        cpuio_aw_valid, cpuio_aw_ready;
    wire [31:0] cpuio_aw_addr;
    wire [2:0]  cpuio_aw_size;
    wire [3:0]  cpuio_aw_cache;
    wire [2:0]  cpuio_aw_prot;
    wire        cpuio_w_valid, cpuio_w_ready;
    wire [31:0] cpuio_w_data;
    wire [3:0]  cpuio_w_strb;
    wire        cpuio_w_last;
    wire        cpuio_b_valid, cpuio_b_ready;
    wire [1:0]  cpuio_b_resp;
    wire        cpuio_ar_valid, cpuio_ar_ready;
    wire [31:0] cpuio_ar_addr;
    wire [2:0]  cpuio_ar_size;
    wire [3:0]  cpuio_ar_cache;
    wire [2:0]  cpuio_ar_prot;
    wire        cpuio_r_valid, cpuio_r_ready;
    wire [31:0] cpuio_r_data;
    wire [1:0]  cpuio_r_resp;
    wire        cpuio_r_last;

    // ---- CPU 侧（cpu_clk 域）AXI 网：经三座 AXI4 CDC 桥接进上面的 soc 域网 ----
    wire        cfetch_ar_valid, cfetch_ar_ready;
    wire [31:0] cfetch_ar_addr;
    wire [7:0]  cfetch_ar_len;
    wire [2:0]  cfetch_ar_size;
    wire [1:0]  cfetch_ar_burst;
    wire [3:0]  cfetch_ar_cache;
    wire [2:0]  cfetch_ar_prot;
    wire        cfetch_r_valid, cfetch_r_ready;
    wire [63:0] cfetch_r_data;
    wire [1:0]  cfetch_r_resp;
    wire        cfetch_r_last;

    wire        clsu_aw_valid, clsu_aw_ready;
    wire [31:0] clsu_aw_addr;
    wire [7:0]  clsu_aw_len;
    wire [2:0]  clsu_aw_size;
    wire [1:0]  clsu_aw_burst;
    wire [3:0]  clsu_aw_cache;
    wire [2:0]  clsu_aw_prot;
    wire        clsu_w_valid, clsu_w_ready;
    wire [63:0] clsu_w_data;
    wire [7:0]  clsu_w_strb;
    wire        clsu_w_last;
    wire        clsu_b_valid, clsu_b_ready;
    wire [1:0]  clsu_b_resp;
    wire        clsu_ar_valid, clsu_ar_ready;
    wire [31:0] clsu_ar_addr;
    wire [7:0]  clsu_ar_len;
    wire [2:0]  clsu_ar_size;
    wire [1:0]  clsu_ar_burst;
    wire [3:0]  clsu_ar_cache;
    wire [2:0]  clsu_ar_prot;
    wire        clsu_r_valid, clsu_r_ready;
    wire [63:0] clsu_r_data;
    wire [1:0]  clsu_r_resp;
    wire        clsu_r_last;

    wire        cio_aw_valid, cio_aw_ready;
    wire [31:0] cio_aw_addr;
    wire [2:0]  cio_aw_size;
    wire [3:0]  cio_aw_cache;
    wire [2:0]  cio_aw_prot;
    wire        cio_w_valid, cio_w_ready;
    wire [31:0] cio_w_data;
    wire [3:0]  cio_w_strb;
    wire        cio_w_last;
    wire        cio_b_valid, cio_b_ready;
    wire [1:0]  cio_b_resp;
    wire        cio_ar_valid, cio_ar_ready;
    wire [31:0] cio_ar_addr;
    wire [2:0]  cio_ar_size;
    wire [3:0]  cio_ar_cache;
    wire [2:0]  cio_ar_prot;
    wire        cio_r_valid, cio_r_ready;
    wire [31:0] cio_r_data;
    wire [1:0]  cio_r_resp;
    wire        cio_r_last;

    // ---- CPU 域复位 / 时基 / 中断 ----
    wire        cpu_rst;
    wire        bridge_rst_s;
    wire [63:0] rdtime_cpu;
    wire        int_m_timer_cpu, int_m_soft_cpu, int_m_ext_cpu, int_s_ext_cpu;

    // ---- CLINT / PLIC privileged 输入（胶合块 → 核，见文件头【4】）----
    wire [63:0] rdtime;
    wire        int_m_timer, int_m_soft, int_m_ext, int_s_ext;
    wire        eth_irq;
    wire        npu_irq;        // NPU 中断（npu_clk 域电平，NpuTop.irq）—— 见文件头【9】/【11】
    wire        npu_irq_cpu;    // 经 NpuIrqCdc 同步到 cpu_clk 域后 → glue.io_npuIrq（PLIC 源 3）

    // ========================================================================
    // CPU 独立时钟域：复位 / rdtime / 中断 CDC + 三座 AXI4 异步桥
    //   源侧 = cpu_clk（VexiiRiscv），目的侧 = soc_clk（YeshenSocGlue）。
    //   两侧 FIFO 复位都源于 soc_cpu_reset（= glue_reset | cpu_reset），
    //   保证 CPU 被扣住或整板复位时不会留下半笔事务。
    // ========================================================================
    cpu_domain_cdc u_cpu_cdc (
        .soc_clk            (soc_clk),
        .soc_rst            (soc_cpu_reset),
        .cpu_clk            (cpu_clk),
        .rdtime_soc         (rdtime),
        .int_m_timer_soc    (int_m_timer),
        .int_m_soft_soc     (int_m_soft),
        .int_m_ext_soc      (int_m_ext),
        .int_s_ext_soc      (int_s_ext),
        .cpu_rst            (cpu_rst),
        .rdtime_cpu         (rdtime_cpu),
        .int_m_timer_cpu    (int_m_timer_cpu),
        .int_m_soft_cpu     (int_m_soft_cpu),
        .int_m_ext_cpu      (int_m_ext_cpu),
        .int_s_ext_cpu      (int_s_ext_cpu),
        .bridge_rst_s       (bridge_rst_s)
    );

    axi4_cdc_fetch u_cdc_fetch (
        .sclk (cpu_clk), .srst (cpu_rst),
        .dclk (soc_clk), .drst (bridge_rst_s),

        .s_arvalid (cfetch_ar_valid), .s_arready (cfetch_ar_ready),
        .s_araddr  (cfetch_ar_addr),  .s_arlen   (cfetch_ar_len),
        .s_arsize  (cfetch_ar_size),  .s_arburst (cfetch_ar_burst),
        .s_arcache (cfetch_ar_cache), .s_arprot  (cfetch_ar_prot),
        .s_rvalid  (cfetch_r_valid),  .s_rready  (cfetch_r_ready),
        .s_rdata   (cfetch_r_data),   .s_rresp   (cfetch_r_resp),
        .s_rlast   (cfetch_r_last),

        .d_arvalid (fetch_ar_valid),  .d_arready (fetch_ar_ready),
        .d_araddr  (fetch_ar_addr),   .d_arlen   (fetch_ar_len),
        .d_arsize  (fetch_ar_size),   .d_arburst (fetch_ar_burst),
        .d_arcache (fetch_ar_cache),  .d_arprot  (fetch_ar_prot),
        .d_rvalid  (fetch_r_valid),   .d_rready  (fetch_r_ready),
        .d_rdata   (fetch_r_data),    .d_rresp   (fetch_r_resp),
        .d_rlast   (fetch_r_last)
    );

    axi4_cdc_lsu u_cdc_lsu (
        .sclk (cpu_clk), .srst (cpu_rst),
        .dclk (soc_clk), .drst (bridge_rst_s),

        .s_awvalid (clsu_aw_valid), .s_awready (clsu_aw_ready),
        .s_awaddr  (clsu_aw_addr),  .s_awlen   (clsu_aw_len),
        .s_awsize  (clsu_aw_size),  .s_awburst (clsu_aw_burst),
        .s_awcache (clsu_aw_cache), .s_awprot  (clsu_aw_prot),
        .s_wvalid  (clsu_w_valid),  .s_wready  (clsu_w_ready),
        .s_wdata   (clsu_w_data),   .s_wstrb   (clsu_w_strb),
        .s_wlast   (clsu_w_last),
        .s_bvalid  (clsu_b_valid),  .s_bready  (clsu_b_ready),
        .s_bresp   (clsu_b_resp),
        .s_arvalid (clsu_ar_valid), .s_arready (clsu_ar_ready),
        .s_araddr  (clsu_ar_addr),  .s_arlen   (clsu_ar_len),
        .s_arsize  (clsu_ar_size),  .s_arburst (clsu_ar_burst),
        .s_arcache (clsu_ar_cache), .s_arprot  (clsu_ar_prot),
        .s_rvalid  (clsu_r_valid),  .s_rready  (clsu_r_ready),
        .s_rdata   (clsu_r_data),   .s_rresp   (clsu_r_resp),
        .s_rlast   (clsu_r_last),

        .d_awvalid (lsu_aw_valid),  .d_awready (lsu_aw_ready),
        .d_awaddr  (lsu_aw_addr),   .d_awlen   (lsu_aw_len),
        .d_awsize  (lsu_aw_size),   .d_awburst (lsu_aw_burst),
        .d_awcache (lsu_aw_cache),  .d_awprot  (lsu_aw_prot),
        .d_wvalid  (lsu_w_valid),   .d_wready  (lsu_w_ready),
        .d_wdata   (lsu_w_data),    .d_wstrb   (lsu_w_strb),
        .d_wlast   (lsu_w_last),
        .d_bvalid  (lsu_b_valid),   .d_bready  (lsu_b_ready),
        .d_bresp   (lsu_b_resp),
        .d_arvalid (lsu_ar_valid),  .d_arready (lsu_ar_ready),
        .d_araddr  (lsu_ar_addr),   .d_arlen   (lsu_ar_len),
        .d_arsize  (lsu_ar_size),   .d_arburst (lsu_ar_burst),
        .d_arcache (lsu_ar_cache),  .d_arprot  (lsu_ar_prot),
        .d_rvalid  (lsu_r_valid),   .d_rready  (lsu_r_ready),
        .d_rdata   (lsu_r_data),    .d_rresp   (lsu_r_resp),
        .d_rlast   (lsu_r_last)
    );

    axi4_cdc_io u_cdc_io (
        .sclk (cpu_clk), .srst (cpu_rst),
        .dclk (soc_clk), .drst (bridge_rst_s),

        .s_awvalid (cio_aw_valid), .s_awready (cio_aw_ready),
        .s_awaddr  (cio_aw_addr),  .s_awsize  (cio_aw_size),
        .s_awcache (cio_aw_cache), .s_awprot  (cio_aw_prot),
        .s_wvalid  (cio_w_valid),  .s_wready  (cio_w_ready),
        .s_wdata   (cio_w_data),   .s_wstrb   (cio_w_strb),
        .s_wlast   (cio_w_last),
        .s_bvalid  (cio_b_valid),  .s_bready  (cio_b_ready),
        .s_bresp   (cio_b_resp),
        .s_arvalid (cio_ar_valid), .s_arready (cio_ar_ready),
        .s_araddr  (cio_ar_addr),  .s_arsize  (cio_ar_size),
        .s_arcache (cio_ar_cache), .s_arprot  (cio_ar_prot),
        .s_rvalid  (cio_r_valid),  .s_rready  (cio_r_ready),
        .s_rdata   (cio_r_data),   .s_rresp   (cio_r_resp),
        .s_rlast   (cio_r_last),

        .d_awvalid (cpuio_aw_valid), .d_awready (cpuio_aw_ready),
        .d_awaddr  (cpuio_aw_addr),  .d_awsize  (cpuio_aw_size),
        .d_awcache (cpuio_aw_cache), .d_awprot  (cpuio_aw_prot),
        .d_wvalid  (cpuio_w_valid),  .d_wready  (cpuio_w_ready),
        .d_wdata   (cpuio_w_data),   .d_wstrb   (cpuio_w_strb),
        .d_wlast   (cpuio_w_last),
        .d_bvalid  (cpuio_b_valid),  .d_bready  (cpuio_b_ready),
        .d_bresp   (cpuio_b_resp),
        .d_arvalid (cpuio_ar_valid), .d_arready (cpuio_ar_ready),
        .d_araddr  (cpuio_ar_addr),  .d_arsize  (cpuio_ar_size),
        .d_arcache (cpuio_ar_cache), .d_arprot  (cpuio_ar_prot),
        .d_rvalid  (cpuio_r_valid),  .d_rready  (cpuio_r_ready),
        .d_rdata   (cpuio_r_data),   .d_rresp   (cpuio_r_resp),
        .d_rlast   (cpuio_r_last)
    );

    // ========================================================================
    // ★ V1：VIDEO CSR 窗从口的中间网（glue.io_videoAxi_* ↔ 本层 video_* 端口）
    //   形态与 `ethAxi_*` 逐字同款（AxiLite4 32/32）；名字 = glue 端口去掉 `io_` 前缀。
    //   ⚠️ 必须**在胶合块例化之前**声明：未声明标识符出现在例化端口上会被隐式声明成
    //      1bit wire，之后再补 [31:0] 显式声明就是重复声明（编译期报错）。
    // ========================================================================
    wire        videoAxi_awvalid, videoAxi_awready;
    wire [31:0] videoAxi_awaddr;
    wire [2:0]  videoAxi_awprot;
    wire        videoAxi_wvalid, videoAxi_wready;
    wire [31:0] videoAxi_wdata;
    wire [3:0]  videoAxi_wstrb;
    wire        videoAxi_bvalid, videoAxi_bready;
    wire [1:0]  videoAxi_bresp;
    wire        videoAxi_arvalid, videoAxi_arready;
    wire [31:0] videoAxi_araddr;
    wire [2:0]  videoAxi_arprot;
    wire        videoAxi_rvalid, videoAxi_rready;
    wire [31:0] videoAxi_rdata;
    wire [1:0]  videoAxi_rresp;

    // ========================================================================
    // 胶合块：YeshenSocGlue（自带 PLIC / CLINT / UART / GPIO / SD / UART 装载器）
    //   reset 只吃 glue_reset（**不含** cpu_reset，见文件头【6】）
    // ========================================================================
    YeshenSocGlue u_glue (
        .clock          (soc_clk),
        .reset          (glue_reset),

        // ---- 上游从口：三条 CPU AXI 主口 ----
        // (1) Fetch（与 VexiiRiscv.FetchL1Axi4Plugin_logic_axi_* 逐条对接）
        .io_cpuFetch_arvalid (fetch_ar_valid),
        .io_cpuFetch_arready (fetch_ar_ready),
        .io_cpuFetch_araddr  (fetch_ar_addr),
        .io_cpuFetch_arlen   (fetch_ar_len),
        .io_cpuFetch_arsize  (fetch_ar_size),
        .io_cpuFetch_arburst (fetch_ar_burst),
        .io_cpuFetch_arcache (fetch_ar_cache),
        .io_cpuFetch_arprot  (fetch_ar_prot),
        .io_cpuFetch_rvalid  (fetch_r_valid),
        .io_cpuFetch_rready  (fetch_r_ready),
        .io_cpuFetch_rdata   (fetch_r_data),
        .io_cpuFetch_rresp   (fetch_r_resp),
        .io_cpuFetch_rlast   (fetch_r_last),

        // (2) Lsu（与 VexiiRiscv.LsuL1Axi4Plugin_logic_axi_* 逐条对接）
        .io_cpuLsu_awvalid (lsu_aw_valid),
        .io_cpuLsu_awready (lsu_aw_ready),
        .io_cpuLsu_awaddr  (lsu_aw_addr),
        .io_cpuLsu_awlen   (lsu_aw_len),
        .io_cpuLsu_awsize  (lsu_aw_size),
        .io_cpuLsu_awburst (lsu_aw_burst),
        .io_cpuLsu_awcache (lsu_aw_cache),
        .io_cpuLsu_awprot  (lsu_aw_prot),
        .io_cpuLsu_wvalid  (lsu_w_valid),
        .io_cpuLsu_wready  (lsu_w_ready),
        .io_cpuLsu_wdata   (lsu_w_data),
        .io_cpuLsu_wstrb   (lsu_w_strb),
        .io_cpuLsu_wlast   (lsu_w_last),
        .io_cpuLsu_bvalid  (lsu_b_valid),
        .io_cpuLsu_bready  (lsu_b_ready),
        .io_cpuLsu_bresp   (lsu_b_resp),
        .io_cpuLsu_arvalid (lsu_ar_valid),
        .io_cpuLsu_arready (lsu_ar_ready),
        .io_cpuLsu_araddr  (lsu_ar_addr),
        .io_cpuLsu_arlen   (lsu_ar_len),
        .io_cpuLsu_arsize  (lsu_ar_size),
        .io_cpuLsu_arburst (lsu_ar_burst),
        .io_cpuLsu_arcache (lsu_ar_cache),
        .io_cpuLsu_arprot  (lsu_ar_prot),
        .io_cpuLsu_rvalid  (lsu_r_valid),
        .io_cpuLsu_rready  (lsu_r_ready),
        .io_cpuLsu_rdata   (lsu_r_data),
        .io_cpuLsu_rresp   (lsu_r_resp),
        .io_cpuLsu_rlast   (lsu_r_last),

        // (3) Io / LsuCacheless（与 VexiiRiscv.LsuCachelessAxi4Plugin_logic_axi_* 对接；
        //     **无 len/burst**，data32）
        .io_cpuIo_awvalid (cpuio_aw_valid),
        .io_cpuIo_awready (cpuio_aw_ready),
        .io_cpuIo_awaddr  (cpuio_aw_addr),
        .io_cpuIo_awsize  (cpuio_aw_size),
        .io_cpuIo_awcache (cpuio_aw_cache),
        .io_cpuIo_awprot  (cpuio_aw_prot),
        .io_cpuIo_wvalid  (cpuio_w_valid),
        .io_cpuIo_wready  (cpuio_w_ready),
        .io_cpuIo_wdata   (cpuio_w_data),
        .io_cpuIo_wstrb   (cpuio_w_strb),
        .io_cpuIo_wlast   (cpuio_w_last),
        .io_cpuIo_bvalid  (cpuio_b_valid),
        .io_cpuIo_bready  (cpuio_b_ready),
        .io_cpuIo_bresp   (cpuio_b_resp),
        .io_cpuIo_arvalid (cpuio_ar_valid),
        .io_cpuIo_arready (cpuio_ar_ready),
        .io_cpuIo_araddr  (cpuio_ar_addr),
        .io_cpuIo_arsize  (cpuio_ar_size),
        .io_cpuIo_arcache (cpuio_ar_cache),
        .io_cpuIo_arprot  (cpuio_ar_prot),
        .io_cpuIo_rvalid  (cpuio_r_valid),
        .io_cpuIo_rready  (cpuio_r_ready),
        .io_cpuIo_rdata   (cpuio_r_data),
        .io_cpuIo_rresp   (cpuio_r_resp),
        .io_cpuIo_rlast   (cpuio_r_last),

        // ---- CLINT / PLIC 输出 → 核（见文件头【4】）----
        .io_rdtime  (rdtime),
        .io_intMTime(int_m_timer),
        .io_intMSoft(int_m_soft),
        .io_intMExt (int_m_ext),
        .io_intSExt (int_s_ext),

        // ---- LiteEth 中断（PLIC 源 2）----
        .io_ethIrq  (eth_irq),

        // ---- NPU 中断（PLIC 源 3；2026-10-08 C2.2）----
        //   ★ N5b：接 **NpuIrqCdc 的 cpu 侧同步副本**（npu_clk 域电平 → cpu_clk 域 2-FF，见【11】）。
        .io_npuIrq  (npu_irq_cpu),

        // ---- DMA 中断输入（2026-10-13 DMA Phase-2b；PLIC 源 4）----
        // 形态与 npuIrq 同款：板级产生（DmaEngine.irq）、本模块消费。★ 与 NPU 的不同：DMA 引擎
        // **整块跑 cpu_clk**（见【12】）⇒ 中断是 **cpu_clk 域电平，无需 CDC**，直连即可。
        .io_dmaIrq  (dma_irq),

        // ---- 下游主口：内存（直接引到顶层；板上接 DDR3Bridge 的 64bit 从口）----
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
        .io_ctpIrq     (ctpIrq),    // Phase R touch: PLIC 源 5
        .io_irq        (),          // 控制台 IRQ 已由胶合块内部接入 PLIC（源 1）；此输出冗余

        // ---- 装载链 ----
        .io_loadMode   (load_mode),
        .io_bootTimeout(32'd100000000),   // 1.0 s @100 MHz 的上电计划选择窗口
        .io_loadActive (load_active),
        .io_sd_sck     (sd_sck),
        .io_sd_mosi    (sd_mosi),
        .io_sd_miso    (sd_miso),
        .io_sd_cs_n    (sd_cs_n),
        .io_cpuReset   (cpu_reset),

        // ---- ★ DMA 装载通路（Y1-DMA Phase-2c）：SD 装载器当 DMA 引擎的第一个真客户 ----
        // `sd_dma_mode` 板上**恒 1**（= 装载器喂引擎，新通路）；置 0 则退回 Phase-2b 的
        // "装载器直写 DDR" 老通路（`sd_dma_mode` 存在只为让装置能在同一份镜像上跑两条通路做 D3 比对）。
        // 喂流 → 引擎 `wr_*_0`（通道 0 = SD 装载器；通道 1 = 网络留口）。
        .io_sdDmaMode  (sd_dma_mode),
        .io_dmaWrValid (sdDma_wr_valid),
        .io_dmaWrData  (sdDma_wr_data),
        .io_dmaWrReady (sdDma_wr_ready),

        // ---- LiteEth 网卡从口（转给下面的 liteeth_wrap）----
        .io_ethAxi_awvalid (ethAxi_awvalid),
        .io_ethAxi_awready (ethAxi_awready),
        .io_ethAxi_awaddr  (ethAxi_awaddr),
        .io_ethAxi_awprot  (ethAxi_awprot),
        .io_ethAxi_wvalid  (ethAxi_wvalid),
        .io_ethAxi_wready  (ethAxi_wready),
        .io_ethAxi_wdata   (ethAxi_wdata),
        .io_ethAxi_wstrb   (ethAxi_wstrb),
        .io_ethAxi_bvalid  (ethAxi_bvalid),
        .io_ethAxi_bready  (ethAxi_bready),
        .io_ethAxi_bresp   (ethAxi_bresp),
        .io_ethAxi_arvalid (ethAxi_arvalid),
        .io_ethAxi_arready (ethAxi_arready),
        .io_ethAxi_araddr  (ethAxi_araddr),
        .io_ethAxi_arprot  (ethAxi_arprot),
        .io_ethAxi_rvalid  (ethAxi_rvalid),
        .io_ethAxi_rready  (ethAxi_rready),
        .io_ethAxi_rdata   (ethAxi_rdata),
        .io_ethAxi_rresp   (ethAxi_rresp),

        // ---- NPU 寄存器窗从口（本模块主方 → NpuTop.axilite_*；2026-10-08 C2.2）----
        // 与 LiteEth 同款：胶合块解码 0xF000_C000（16 KiB）后把地址整根交给 NPU。
        .io_npuAxi_awvalid (npuAxi_awvalid),
        .io_npuAxi_awready (npuAxi_awready),
        .io_npuAxi_awaddr  (npuAxi_awaddr),
        .io_npuAxi_awprot  (npuAxi_awprot),
        .io_npuAxi_wvalid  (npuAxi_wvalid),
        .io_npuAxi_wready  (npuAxi_wready),
        .io_npuAxi_wdata   (npuAxi_wdata),
        .io_npuAxi_wstrb   (npuAxi_wstrb),
        .io_npuAxi_bvalid  (npuAxi_bvalid),
        .io_npuAxi_bready  (npuAxi_bready),
        .io_npuAxi_bresp   (npuAxi_bresp),
        .io_npuAxi_arvalid (npuAxi_arvalid),
        .io_npuAxi_arready (npuAxi_arready),
        .io_npuAxi_araddr  (npuAxi_araddr),
        .io_npuAxi_arprot  (npuAxi_arprot),
        .io_npuAxi_rvalid  (npuAxi_rvalid),
        .io_npuAxi_rready  (npuAxi_rready),
        .io_npuAxi_rdata   (npuAxi_rdata),
        .io_npuAxi_rresp   (npuAxi_rresp),

        // ---- NPU 内存主口（NpuTop.axi_* → 本模块从方；2026-10-08 C2.2）----
        // 汇入胶合块 §3.5 的同一汇聚点（与 CPU 三条主口共享单 outstanding 仲裁 + 轮转）。
        .io_npuMem_awvalid (npuMem_awvalid),
        .io_npuMem_awready (npuMem_awready),
        .io_npuMem_awaddr  (npuMem_awaddr),
        .io_npuMem_awid    (npuMem_awid),
        .io_npuMem_awlen   (npuMem_awlen),
        .io_npuMem_awsize  (npuMem_awsize),
        .io_npuMem_awburst (npuMem_awburst),
        .io_npuMem_awcache (npuMem_awcache),
        .io_npuMem_awprot  (npuMem_awprot),
        .io_npuMem_wvalid  (npuMem_wvalid),
        .io_npuMem_wready  (npuMem_wready),
        .io_npuMem_wdata   (npuMem_wdata),
        .io_npuMem_wstrb   (npuMem_wstrb),
        .io_npuMem_wlast   (npuMem_wlast),
        .io_npuMem_bvalid  (npuMem_bvalid),
        .io_npuMem_bready  (npuMem_bready),
        .io_npuMem_bid     (npuMem_bid),
        .io_npuMem_bresp   (npuMem_bresp),
        .io_npuMem_arvalid (npuMem_arvalid),
        .io_npuMem_arready (npuMem_arready),
        .io_npuMem_araddr  (npuMem_araddr),
        .io_npuMem_arid    (npuMem_arid),
        .io_npuMem_arlen   (npuMem_arlen),
        .io_npuMem_arsize  (npuMem_arsize),
        .io_npuMem_arburst (npuMem_arburst),
        .io_npuMem_arcache (npuMem_arcache),
        .io_npuMem_arprot  (npuMem_arprot),
        .io_npuMem_rvalid  (npuMem_rvalid),
        .io_npuMem_rready  (npuMem_rready),
        .io_npuMem_rdata   (npuMem_rdata),
        .io_npuMem_rid     (npuMem_rid),
        .io_npuMem_rresp   (npuMem_rresp),
        .io_npuMem_rlast   (npuMem_rlast),

        // ---- DMA 寄存器窗从口（本模块主方 → DmaEngine.axilite_*；2026-10-13 DMA P2b）----
        // 形态与 `io_npuAxi_*` 逐字同款（AxiLite4 32/32）；窗 0xF000_6000（256 B）由胶合块解码。
        .io_dmaAxi_awvalid (dmaAxi_awvalid),
        .io_dmaAxi_awready (dmaAxi_awready),
        .io_dmaAxi_awaddr  (dmaAxi_awaddr),
        .io_dmaAxi_awprot  (dmaAxi_awprot),
        .io_dmaAxi_wvalid  (dmaAxi_wvalid),
        .io_dmaAxi_wready  (dmaAxi_wready),
        .io_dmaAxi_wdata   (dmaAxi_wdata),
        .io_dmaAxi_wstrb   (dmaAxi_wstrb),
        .io_dmaAxi_bvalid  (dmaAxi_bvalid),
        .io_dmaAxi_bready  (dmaAxi_bready),
        .io_dmaAxi_bresp   (dmaAxi_bresp),
        .io_dmaAxi_arvalid (dmaAxi_arvalid),
        .io_dmaAxi_arready (dmaAxi_arready),
        .io_dmaAxi_araddr  (dmaAxi_araddr),
        .io_dmaAxi_arprot  (dmaAxi_arprot),
        .io_dmaAxi_rvalid  (dmaAxi_rvalid),
        .io_dmaAxi_rready  (dmaAxi_rready),
        .io_dmaAxi_rdata   (dmaAxi_rdata),
        .io_dmaAxi_rresp   (dmaAxi_rresp),

        // ---- ★ V1：VIDEO CSR 窗从口（0xF000_7400，1 KiB；胶合块解码，Task 6）----
        // 与 `io_npuAxi_*` / `io_dmaAxi_*` 同形（AxiLite4 32/32）；胶合块把窗内偏移放在
        // 低 10 位、高 22 位补 0（实读 `assign io_videoAxi_awaddr = {22'h0, ...addr[9:0]}`）。
        // 本层只把 20 根信号原样引到板级顶层（接收方 = `video_regs u_video_regs`）。
        .io_videoAxi_awvalid (videoAxi_awvalid),
        .io_videoAxi_awready (videoAxi_awready),
        .io_videoAxi_awaddr  (videoAxi_awaddr),
        .io_videoAxi_awprot  (videoAxi_awprot),
        .io_videoAxi_wvalid  (videoAxi_wvalid),
        .io_videoAxi_wready  (videoAxi_wready),
        .io_videoAxi_wdata   (videoAxi_wdata),
        .io_videoAxi_wstrb   (videoAxi_wstrb),
        .io_videoAxi_bvalid  (videoAxi_bvalid),
        .io_videoAxi_bready  (videoAxi_bready),
        .io_videoAxi_bresp   (videoAxi_bresp),
        .io_videoAxi_arvalid (videoAxi_arvalid),
        .io_videoAxi_arready (videoAxi_arready),
        .io_videoAxi_araddr  (videoAxi_araddr),
        .io_videoAxi_arprot  (videoAxi_arprot),
        .io_videoAxi_rvalid  (videoAxi_rvalid),
        .io_videoAxi_rready  (videoAxi_rready),
        .io_videoAxi_rdata   (videoAxi_rdata),
        .io_videoAxi_rresp   (videoAxi_rresp),

        // ---- DMA 内存主口（DmaEngine.axi_* → 本模块从方；2026-10-13 DMA P2b）----
        // 形状与 `io_npuMem_*` 逐字相同（28/64/4，带 id/cache/prot、无 lock）⇒ 汇入 §3.5 汇聚点。
        .io_dmaMem_awvalid (dmaMem_awvalid),
        .io_dmaMem_awready (dmaMem_awready),
        .io_dmaMem_awaddr  (dmaMem_awaddr),
        .io_dmaMem_awid    (dmaMem_awid),
        .io_dmaMem_awlen   (dmaMem_awlen),
        .io_dmaMem_awsize  (dmaMem_awsize),
        .io_dmaMem_awburst (dmaMem_awburst),
        .io_dmaMem_awcache (dmaMem_awcache),
        .io_dmaMem_awprot  (dmaMem_awprot),
        .io_dmaMem_wvalid  (dmaMem_wvalid),
        .io_dmaMem_wready  (dmaMem_wready),
        .io_dmaMem_wdata   (dmaMem_wdata),
        .io_dmaMem_wstrb   (dmaMem_wstrb),
        .io_dmaMem_wlast   (dmaMem_wlast),
        .io_dmaMem_bvalid  (dmaMem_bvalid),
        .io_dmaMem_bready  (dmaMem_bready),
        .io_dmaMem_bid     (dmaMem_bid),
        .io_dmaMem_bresp   (dmaMem_bresp),
        .io_dmaMem_arvalid (dmaMem_arvalid),
        .io_dmaMem_arready (dmaMem_arready),
        .io_dmaMem_araddr  (dmaMem_araddr),
        .io_dmaMem_arid    (dmaMem_arid),
        .io_dmaMem_arlen   (dmaMem_arlen),
        .io_dmaMem_arsize  (dmaMem_arsize),
        .io_dmaMem_arburst (dmaMem_arburst),
        .io_dmaMem_arcache (dmaMem_arcache),
        .io_dmaMem_arprot  (dmaMem_arprot),
        .io_dmaMem_rvalid  (dmaMem_rvalid),
        .io_dmaMem_rready  (dmaMem_rready),
        .io_dmaMem_rdata   (dmaMem_rdata),
        .io_dmaMem_rid     (dmaMem_rid),
        .io_dmaMem_rresp   (dmaMem_rresp),
        .io_dmaMem_rlast   (dmaMem_rlast),

        // SD 诊断（本层顶层无对应端口；观测用，悬空）
        .io_sd_state     (),
        .io_sd_err       (),
        .io_sd_dbg       (),
        .io_sd_dbg2      ()
    );

    // ========================================================================
    // 上游核：VexiiRiscv（黑盒网表；单 clk + 同步 reset）
    // ========================================================================
    VexiiRiscv u_cpu (
        .clk   (cpu_clk),
        .reset (cpu_rst),     // = glue_reset | cpu_reset（同步、高有效，见文件头【6】）

        // ---- Fetch（→ glue.io_cpuFetch_*）----
        .FetchL1Axi4Plugin_logic_axi_ar_valid        (cfetch_ar_valid),
        .FetchL1Axi4Plugin_logic_axi_ar_ready        (cfetch_ar_ready),
        .FetchL1Axi4Plugin_logic_axi_ar_payload_addr (cfetch_ar_addr),
        .FetchL1Axi4Plugin_logic_axi_ar_payload_len  (cfetch_ar_len),
        .FetchL1Axi4Plugin_logic_axi_ar_payload_size (cfetch_ar_size),
        .FetchL1Axi4Plugin_logic_axi_ar_payload_burst(cfetch_ar_burst),
        .FetchL1Axi4Plugin_logic_axi_ar_payload_cache(cfetch_ar_cache),
        .FetchL1Axi4Plugin_logic_axi_ar_payload_prot (cfetch_ar_prot),
        .FetchL1Axi4Plugin_logic_axi_r_valid         (cfetch_r_valid),
        .FetchL1Axi4Plugin_logic_axi_r_ready         (cfetch_r_ready),
        .FetchL1Axi4Plugin_logic_axi_r_payload_data  (cfetch_r_data),
        .FetchL1Axi4Plugin_logic_axi_r_payload_resp  (cfetch_r_resp),
        .FetchL1Axi4Plugin_logic_axi_r_payload_last  (cfetch_r_last),

        // ---- Lsu（→ glue.io_cpuLsu_*）----
        .LsuL1Axi4Plugin_logic_axi_aw_valid        (clsu_aw_valid),
        .LsuL1Axi4Plugin_logic_axi_aw_ready        (clsu_aw_ready),
        .LsuL1Axi4Plugin_logic_axi_aw_payload_addr (clsu_aw_addr),
        .LsuL1Axi4Plugin_logic_axi_aw_payload_len  (clsu_aw_len),
        .LsuL1Axi4Plugin_logic_axi_aw_payload_size (clsu_aw_size),
        .LsuL1Axi4Plugin_logic_axi_aw_payload_burst(clsu_aw_burst),
        .LsuL1Axi4Plugin_logic_axi_aw_payload_cache(clsu_aw_cache),
        .LsuL1Axi4Plugin_logic_axi_aw_payload_prot (clsu_aw_prot),
        .LsuL1Axi4Plugin_logic_axi_w_valid         (clsu_w_valid),
        .LsuL1Axi4Plugin_logic_axi_w_ready         (clsu_w_ready),
        .LsuL1Axi4Plugin_logic_axi_w_payload_data  (clsu_w_data),
        .LsuL1Axi4Plugin_logic_axi_w_payload_strb  (clsu_w_strb),
        .LsuL1Axi4Plugin_logic_axi_w_payload_last  (clsu_w_last),
        .LsuL1Axi4Plugin_logic_axi_b_valid         (clsu_b_valid),
        .LsuL1Axi4Plugin_logic_axi_b_ready         (clsu_b_ready),
        .LsuL1Axi4Plugin_logic_axi_b_payload_resp  (clsu_b_resp),
        .LsuL1Axi4Plugin_logic_axi_ar_valid        (clsu_ar_valid),
        .LsuL1Axi4Plugin_logic_axi_ar_ready        (clsu_ar_ready),
        .LsuL1Axi4Plugin_logic_axi_ar_payload_addr (clsu_ar_addr),
        .LsuL1Axi4Plugin_logic_axi_ar_payload_len  (clsu_ar_len),
        .LsuL1Axi4Plugin_logic_axi_ar_payload_size (clsu_ar_size),
        .LsuL1Axi4Plugin_logic_axi_ar_payload_burst(clsu_ar_burst),
        .LsuL1Axi4Plugin_logic_axi_ar_payload_cache(clsu_ar_cache),
        .LsuL1Axi4Plugin_logic_axi_ar_payload_prot (clsu_ar_prot),
        .LsuL1Axi4Plugin_logic_axi_r_valid         (clsu_r_valid),
        .LsuL1Axi4Plugin_logic_axi_r_ready         (clsu_r_ready),
        .LsuL1Axi4Plugin_logic_axi_r_payload_data  (clsu_r_data),
        .LsuL1Axi4Plugin_logic_axi_r_payload_resp  (clsu_r_resp),
        .LsuL1Axi4Plugin_logic_axi_r_payload_last  (clsu_r_last),

        // ---- LsuCacheless / Io（→ glue.io_cpuIo_*；无 len/burst，data32）----
        .LsuCachelessAxi4Plugin_logic_axi_aw_valid        (cio_aw_valid),
        .LsuCachelessAxi4Plugin_logic_axi_aw_ready        (cio_aw_ready),
        .LsuCachelessAxi4Plugin_logic_axi_aw_payload_addr (cio_aw_addr),
        .LsuCachelessAxi4Plugin_logic_axi_aw_payload_size (cio_aw_size),
        .LsuCachelessAxi4Plugin_logic_axi_aw_payload_cache(cio_aw_cache),
        .LsuCachelessAxi4Plugin_logic_axi_aw_payload_prot (cio_aw_prot),
        .LsuCachelessAxi4Plugin_logic_axi_w_valid         (cio_w_valid),
        .LsuCachelessAxi4Plugin_logic_axi_w_ready         (cio_w_ready),
        .LsuCachelessAxi4Plugin_logic_axi_w_payload_data  (cio_w_data),
        .LsuCachelessAxi4Plugin_logic_axi_w_payload_strb  (cio_w_strb),
        .LsuCachelessAxi4Plugin_logic_axi_w_payload_last  (cio_w_last),
        .LsuCachelessAxi4Plugin_logic_axi_b_valid         (cio_b_valid),
        .LsuCachelessAxi4Plugin_logic_axi_b_ready         (cio_b_ready),
        .LsuCachelessAxi4Plugin_logic_axi_b_payload_resp  (cio_b_resp),
        .LsuCachelessAxi4Plugin_logic_axi_ar_valid        (cio_ar_valid),
        .LsuCachelessAxi4Plugin_logic_axi_ar_ready        (cio_ar_ready),
        .LsuCachelessAxi4Plugin_logic_axi_ar_payload_addr (cio_ar_addr),
        .LsuCachelessAxi4Plugin_logic_axi_ar_payload_size (cio_ar_size),
        .LsuCachelessAxi4Plugin_logic_axi_ar_payload_cache(cio_ar_cache),
        .LsuCachelessAxi4Plugin_logic_axi_ar_payload_prot (cio_ar_prot),
        .LsuCachelessAxi4Plugin_logic_axi_r_valid         (cio_r_valid),
        .LsuCachelessAxi4Plugin_logic_axi_r_ready         (cio_r_ready),
        .LsuCachelessAxi4Plugin_logic_axi_r_payload_data  (cio_r_data),
        .LsuCachelessAxi4Plugin_logic_axi_r_payload_resp  (cio_r_resp),
        .LsuCachelessAxi4Plugin_logic_axi_r_payload_last  (cio_r_last),

        // ---- privileged：CLINT / PLIC（胶合块输出，见文件头【4】）----
        .PrivilegedPlugin_logic_rdtime                          (rdtime_cpu),
        .PrivilegedPlugin_logic_harts_0_int_m_timer             (int_m_timer_cpu),
        .PrivilegedPlugin_logic_harts_0_int_m_software          (int_m_soft_cpu),
        .PrivilegedPlugin_logic_harts_0_int_m_external          (int_m_ext_cpu),
        .PrivilegedPlugin_logic_harts_0_int_s_external          (int_s_ext_cpu)
    );

    // ========================================================================
    // 以太网：LiteEth 落地层（AXI-Lite 从口 ← glue 的三个窗口；RGMII → 板载 PHY0）
    //   时钟域：sys（soc_clk 100MHz，CSR/槽）+ rgmii_clk（125MHz，PHY）。
    //           CDC 在 LiteEth MAC 内部（async FIFO），见 board/liteeth_wrap.v 文件头。
    //   中断：eth_irq → 胶合块 PLIC **源 2**（见文件头【4】）。
    // ========================================================================
    wire        ethAxi_awvalid, ethAxi_awready;
    wire [31:0] ethAxi_awaddr;
    wire [2:0]  ethAxi_awprot;
    wire        ethAxi_wvalid, ethAxi_wready;
    wire [31:0] ethAxi_wdata;
    wire [3:0]  ethAxi_wstrb;
    wire        ethAxi_bvalid, ethAxi_bready;
    wire [1:0]  ethAxi_bresp;
    wire        ethAxi_arvalid, ethAxi_arready;
    wire [31:0] ethAxi_araddr;
    wire [2:0]  ethAxi_arprot;
    wire        ethAxi_rvalid, ethAxi_rready;
    wire [31:0] ethAxi_rdata;
    wire [1:0]  ethAxi_rresp;

    liteeth_wrap u_liteeth (
        .clk (soc_clk),
        .rst (glue_reset),

        .s_awaddr  (ethAxi_awaddr),
        .s_awprot  (ethAxi_awprot),
        .s_awvalid (ethAxi_awvalid),
        .s_awready (ethAxi_awready),
        .s_wdata   (ethAxi_wdata),
        .s_wstrb   (ethAxi_wstrb),
        .s_wvalid  (ethAxi_wvalid),
        .s_wready  (ethAxi_wready),
        .s_bresp   (ethAxi_bresp),
        .s_bvalid  (ethAxi_bvalid),
        .s_bready  (ethAxi_bready),
        .s_araddr  (ethAxi_araddr),
        .s_arprot  (ethAxi_arprot),
        .s_arvalid (ethAxi_arvalid),
        .s_arready (ethAxi_arready),
        .s_rdata   (ethAxi_rdata),
        .s_rresp   (ethAxi_rresp),
        .s_rvalid  (ethAxi_rvalid),
        .s_rready  (ethAxi_rready),

        .rgmii_rxc     (eth_rgmii_rxc),
        .rgmii_rx_ctl  (eth_rgmii_rx_ctl),
        .rgmii_rxd     (eth_rgmii_rxd),
        .rgmii_txc     (eth_rgmii_txc),
        .rgmii_tx_ctl  (eth_rgmii_tx_ctl),
        .rgmii_txd     (eth_rgmii_txd),

        .irq (eth_irq),

        .rgmii_alive (eth_rgmii_alive)
    );

    assign eth_released = 1'b0;
    assign eth_rx_bytes = 32'd0;
    assign eth_wr_bytes = 32'd0;

    // ========================================================================
    // NPU：Y1 自研小型 YuNet CNN 加速器（`y1/gen/NpuTop.v`，SpinalHDL 生成；2026-10-08 C2.2）
    //   ★ N5b：NpuTop **整块跑 `npu_clk`**（56.25MHz 独立域，T-18c 起），三个接口各经一座异步桥跨到 cpu 域
    //     （桥的网表在 Verilog 层例化，glue 的 Chisel 不改）：
    //     (a) 寄存器窗从口（AxiLite4）← `NpuAxiLiteCdc` 的 npu 主口；桥 cpu 从口 ← glue.io_npuAxi_*
    //     (b) 内存主口（AXI4）→ `NpuMemCdc` npu 从口；桥 cpu 主口 → glue.io_npuMem_*（汇入 §3.5 汇聚点）
    //     (c) 中断（npu 电平）→ `NpuIrqCdc`（2-FF）→ glue.io_npuIrq（= PLIC 源 3）
    //   复位：`NpuResetSync`（异步置位/同步释放，cpu 先 npu 后）产 npu 域复位；`NpuTop.reset = ~npuRstn`。
    //   端口名逐字取自 `sed -n '/^module NpuTop/,/^);/p' y1/gen/NpuTop.v`（实测 dump，不是猜）。
    //   完整 CDC 接线与理由见文件头【9】【11】。
    // ========================================================================

    // ---- 复位同步器（NpuResetSync）：异步置位 / 同步释放；**cpu 先释放、npu 后释放** ----
    //   `io_asyncRst` = 板级异步高有效 `async_reset` **OR** 装载期 `cpu_reset`（沿用旧口径：装载期
    //   把 NPU 也扣住；`cpu_reset` 是 cpu 域电平，作**异步置位源**合规 —— 释放仍由同步器对齐）。
    //   两域低有效复位供：三座桥的 cpu/npu 侧、NpuTop（取反成高有效同步复位）。
    wire npu_dom_cpu_rstn;    // 低有效，cpu 域
    wire npu_dom_npu_rstn;    // 低有效，npu 域（**晚于 cpu 释放**）
    NpuResetSync u_npu_rst_sync (
        .io_cpuClk   (soc_clk),
        .io_npuClk   (npu_clk),
        .io_asyncRst (async_reset | cpu_reset),
        .io_cpuRstn  (npu_dom_cpu_rstn),
        .io_npuRstn  (npu_dom_npu_rstn)
    );
    // NPU 网表（R3-4 起）是**同步、高有效**复位口 ⇒ 取反 npu 域低有效复位。
    wire npu_reset = ~npu_dom_npu_rstn;

    // ---- 内存主口：**cpu 侧网**（`NpuMemCdc` 的 cpu 主口 → glue.io_npuMem_*，见下方桥的例化）----
    //   addr 28bit / data 64bit / id 4bit；aw/ar 带 cache[3:0]+prot[2:0]、**无 lock**；w **无 id**。
    wire        npuMem_awvalid, npuMem_awready;
    wire [27:0] npuMem_awaddr;
    wire [3:0]  npuMem_awid;
    wire [7:0]  npuMem_awlen;
    wire [2:0]  npuMem_awsize;
    wire [1:0]  npuMem_awburst;
    wire [3:0]  npuMem_awcache;
    wire [2:0]  npuMem_awprot;
    wire        npuMem_wvalid, npuMem_wready;
    wire [63:0] npuMem_wdata;
    wire [7:0]  npuMem_wstrb;
    wire        npuMem_wlast;
    wire        npuMem_bvalid, npuMem_bready;
    wire [3:0]  npuMem_bid;
    wire [1:0]  npuMem_bresp;
    wire        npuMem_arvalid, npuMem_arready;
    wire [27:0] npuMem_araddr;
    wire [3:0]  npuMem_arid;
    wire [7:0]  npuMem_arlen;
    wire [2:0]  npuMem_arsize;
    wire [1:0]  npuMem_arburst;
    wire [3:0]  npuMem_arcache;
    wire [2:0]  npuMem_arprot;
    wire        npuMem_rvalid, npuMem_rready;
    wire [63:0] npuMem_rdata;
    wire [3:0]  npuMem_rid;
    wire [1:0]  npuMem_rresp;
    wire        npuMem_rlast;

    // ---- 内存主口：**npu 侧网**（NpuTop.axi_* ↔ `NpuMemCdc` 的 npu 从口）----
    wire        npuMem2_awvalid, npuMem2_awready;
    wire [27:0] npuMem2_awaddr;
    wire [3:0]  npuMem2_awid;
    wire [7:0]  npuMem2_awlen;
    wire [2:0]  npuMem2_awsize;
    wire [1:0]  npuMem2_awburst;
    wire [3:0]  npuMem2_awcache;
    wire [2:0]  npuMem2_awprot;
    wire        npuMem2_wvalid, npuMem2_wready;
    wire [63:0] npuMem2_wdata;
    wire [7:0]  npuMem2_wstrb;
    wire        npuMem2_wlast;
    wire        npuMem2_bvalid, npuMem2_bready;
    wire [3:0]  npuMem2_bid;
    wire [1:0]  npuMem2_bresp;
    wire        npuMem2_arvalid, npuMem2_arready;
    wire [27:0] npuMem2_araddr;
    wire [3:0]  npuMem2_arid;
    wire [7:0]  npuMem2_arlen;
    wire [2:0]  npuMem2_arsize;
    wire [1:0]  npuMem2_arburst;
    wire [3:0]  npuMem2_arcache;
    wire [2:0]  npuMem2_arprot;
    wire        npuMem2_rvalid, npuMem2_rready;
    wire [63:0] npuMem2_rdata;
    wire [3:0]  npuMem2_rid;
    wire [1:0]  npuMem2_rresp;
    wire        npuMem2_rlast;

    // ---- 寄存器窗从口：**cpu 侧网**（glue.io_npuAxi_* 主 → `NpuAxiLiteCdc` cpu 从口）----
    wire        npuAxi_awvalid, npuAxi_awready;
    wire [31:0] npuAxi_awaddr;
    wire [2:0]  npuAxi_awprot;
    wire        npuAxi_wvalid, npuAxi_wready;
    wire [31:0] npuAxi_wdata;
    wire [3:0]  npuAxi_wstrb;
    wire        npuAxi_bvalid, npuAxi_bready;
    wire [1:0]  npuAxi_bresp;
    wire        npuAxi_arvalid, npuAxi_arready;
    wire [31:0] npuAxi_araddr;
    wire [2:0]  npuAxi_arprot;
    wire        npuAxi_rvalid, npuAxi_rready;
    wire [31:0] npuAxi_rdata;
    wire [1:0]  npuAxi_rresp;

    // ---- 寄存器窗从口：**npu 侧网**（`NpuAxiLiteCdc` npu 主口 → NpuTop.axilite_*）----
    wire        npuAxi2_awvalid, npuAxi2_awready;
    wire [31:0] npuAxi2_awaddr;
    wire [2:0]  npuAxi2_awprot;
    wire        npuAxi2_wvalid, npuAxi2_wready;
    wire [31:0] npuAxi2_wdata;
    wire [3:0]  npuAxi2_wstrb;
    wire        npuAxi2_bvalid, npuAxi2_bready;
    wire [1:0]  npuAxi2_bresp;
    wire        npuAxi2_arvalid, npuAxi2_arready;
    wire [31:0] npuAxi2_araddr;
    wire [2:0]  npuAxi2_arprot;
    wire        npuAxi2_rvalid, npuAxi2_rready;
    wire [31:0] npuAxi2_rdata;
    wire [1:0]  npuAxi2_rresp;

    // ========================================================================
    // 【12】★ DMA：Y1 通用 DMA 引擎（`y1/gen/DmaEngine.v`，SpinalHDL 生成；2026-10-13 DMA P2b）
    //   · 寄存器窗从口（AxiLite4）← glue 的 `io_dmaAxi_*`（窗 `0xF000_6000`，256 B；胶合块解码）。
    //   · 内存主口（AXI4，addr 28bit / data 64bit / id 4bit）→ glue 的 `io_dmaMem_*`，**汇入胶合块
    //     §3.5 那个汇聚点**（第 6 个主人；与 NPU 同形 ⇒ 28→32 零扩展 + id 丢弃在胶合里做）。
    //   · 中断 `irq`（电平保持 = GBL_DONE|GBL_ERR，主机写该通道 CH_STATUS w1c 清源）→ glue.io_dmaIrq
    //     = PLIC **源 4**。
    //   ★ 与 NPU 的关键不同：DMA 引擎**整块跑 `cpu_clk`（soc_clk）**（spec §4.2 的裁决：主口归
    //     cpu_clk，到 DDR 无 CDC）⇒ 三条接口都**不需要异步桥**，直连胶合块即可；复位取
    //     `glue_reset`（同步、高有效，与胶合块同域同语义）。
    //   端口名逐字取自 `sed -n '/^module DmaEngine/,/^);/p' y1/gen/DmaEngine.v`（实测 dump，不是猜）。
    // ========================================================================
    wire        dma_irq;
    // ---- ★ Phase-2c：SD 装载器 → DMA 引擎通道 0 的"喂流"（板级恒走引擎通路：`sd_dma_mode = 1`）----
    wire        sd_dma_mode   = 1'b1;
    wire        sdDma_wr_valid;
    wire [63:0] sdDma_wr_data;
    wire        sdDma_wr_ready;
    // ---- 寄存器窗从口：cpu 侧网（glue.io_dmaAxi_* 主 → DmaEngine.axilite_*）----
    wire        dmaAxi_awvalid, dmaAxi_awready;
    wire [31:0] dmaAxi_awaddr;
    wire [2:0]  dmaAxi_awprot;
    wire        dmaAxi_wvalid, dmaAxi_wready;
    wire [31:0] dmaAxi_wdata;
    wire [3:0]  dmaAxi_wstrb;
    wire        dmaAxi_bvalid, dmaAxi_bready;
    wire [1:0]  dmaAxi_bresp;
    wire        dmaAxi_arvalid, dmaAxi_arready;
    wire [31:0] dmaAxi_araddr;
    wire [2:0]  dmaAxi_arprot;
    wire        dmaAxi_rvalid, dmaAxi_rready;
    wire [31:0] dmaAxi_rdata;
    wire [1:0]  dmaAxi_rresp;
    // ---- 内存主口（DmaEngine.axi_* → glue.io_dmaMem_*，喂 §3.5 汇聚点）----
    wire        dmaMem_awvalid, dmaMem_awready;
    wire [27:0] dmaMem_awaddr;
    wire [3:0]  dmaMem_awid;
    wire [7:0]  dmaMem_awlen;
    wire [2:0]  dmaMem_awsize;
    wire [1:0]  dmaMem_awburst;
    wire [3:0]  dmaMem_awcache;
    wire [2:0]  dmaMem_awprot;
    wire        dmaMem_wvalid, dmaMem_wready;
    wire [63:0] dmaMem_wdata;
    wire [7:0]  dmaMem_wstrb;
    wire        dmaMem_wlast;
    wire        dmaMem_bvalid, dmaMem_bready;
    wire [3:0]  dmaMem_bid;
    wire [1:0]  dmaMem_bresp;
    wire        dmaMem_arvalid, dmaMem_arready;
    wire [27:0] dmaMem_araddr;
    wire [3:0]  dmaMem_arid;
    wire [7:0]  dmaMem_arlen;
    wire [2:0]  dmaMem_arsize;
    wire [1:0]  dmaMem_arburst;
    wire [3:0]  dmaMem_arcache;
    wire [2:0]  dmaMem_arprot;
    wire        dmaMem_rvalid, dmaMem_rready;
    wire [63:0] dmaMem_rdata;
    wire [3:0]  dmaMem_rid;
    wire [1:0]  dmaMem_rresp;
    wire        dmaMem_rlast;

    // ---- DMA 引擎本体（cpu_clk 域；端口名逐字取自 y1/gen/DmaEngine.v）----
    DmaEngine u_dma (
        .clk    (soc_clk),
        .reset  (glue_reset),          // 同步、高有效（与胶合块同域同语义）
        .irq    (dma_irq),             // → glue.io_dmaIrq（PLIC 源 4）

        // --- AxiLite4 CSR 从口（← glue.io_dmaAxi_*）---
        .axilite_aw_valid        (dmaAxi_awvalid),
        .axilite_aw_ready        (dmaAxi_awready),
        .axilite_aw_payload_addr (dmaAxi_awaddr),
        .axilite_aw_payload_prot (dmaAxi_awprot),
        .axilite_w_valid         (dmaAxi_wvalid),
        .axilite_w_ready         (dmaAxi_wready),
        .axilite_w_payload_data  (dmaAxi_wdata),
        .axilite_w_payload_strb  (dmaAxi_wstrb),
        .axilite_b_valid         (dmaAxi_bvalid),
        .axilite_b_ready         (dmaAxi_bready),
        .axilite_b_payload_resp  (dmaAxi_bresp),
        .axilite_ar_valid        (dmaAxi_arvalid),
        .axilite_ar_ready        (dmaAxi_arready),
        .axilite_ar_payload_addr (dmaAxi_araddr),
        .axilite_ar_payload_prot (dmaAxi_arprot),
        .axilite_r_valid         (dmaAxi_rvalid),
        .axilite_r_ready         (dmaAxi_rready),
        .axilite_r_payload_data  (dmaAxi_rdata),
        .axilite_r_payload_resp  (dmaAxi_rresp),

        // --- AXI4 内存主口（→ glue.io_dmaMem_*）---
        .axi_aw_valid         (dmaMem_awvalid),
        .axi_aw_ready         (dmaMem_awready),
        .axi_aw_payload_addr  (dmaMem_awaddr),
        .axi_aw_payload_id    (dmaMem_awid),
        .axi_aw_payload_len   (dmaMem_awlen),
        .axi_aw_payload_size  (dmaMem_awsize),
        .axi_aw_payload_burst (dmaMem_awburst),
        .axi_aw_payload_cache (dmaMem_awcache),
        .axi_aw_payload_prot  (dmaMem_awprot),
        .axi_w_valid          (dmaMem_wvalid),
        .axi_w_ready          (dmaMem_wready),
        .axi_w_payload_data   (dmaMem_wdata),
        .axi_w_payload_strb   (dmaMem_wstrb),
        .axi_w_payload_last   (dmaMem_wlast),
        .axi_b_valid          (dmaMem_bvalid),
        .axi_b_ready          (dmaMem_bready),
        .axi_b_payload_id     (dmaMem_bid),
        .axi_b_payload_resp   (dmaMem_bresp),
        .axi_ar_valid         (dmaMem_arvalid),
        .axi_ar_ready         (dmaMem_arready),
        .axi_ar_payload_addr  (dmaMem_araddr),
        .axi_ar_payload_id    (dmaMem_arid),
        .axi_ar_payload_len   (dmaMem_arlen),
        .axi_ar_payload_size  (dmaMem_arsize),
        .axi_ar_payload_burst (dmaMem_arburst),
        .axi_ar_payload_cache (dmaMem_arcache),
        .axi_ar_payload_prot  (dmaMem_arprot),
        .axi_r_valid          (dmaMem_rvalid),
        .axi_r_ready          (dmaMem_rready),
        .axi_r_payload_data   (dmaMem_rdata),
        .axi_r_payload_id     (dmaMem_rid),
        .axi_r_payload_resp   (dmaMem_rresp),
        .axi_r_payload_last   (dmaMem_rlast),

        // --- 每通道流口（★ Phase-2c：通道 0 = SD 装载器（WR 模式喂流）；通道 1 = 网络留口）---
        .rd_valid_0 (),
        .rd_valid_1 (),
        .rd_ready_0 (1'b0),
        .rd_ready_1 (1'b0),
        .rd_data_0  (),
        .rd_data_1  (),
        .wr_valid_0 (sdDma_wr_valid),   // ← glue.io_dmaWrValid（SdLoader 的 DMA 喂流）
        .wr_valid_1 (1'b0),             // 通道 1（网络 rx 槽→DDR）本相未接
        .wr_ready_0 (sdDma_wr_ready),   // → glue.io_dmaWrReady
        .wr_ready_1 (),
        .wr_data_0  (sdDma_wr_data),    // ← glue.io_dmaWrData
        .wr_data_1  (64'b0)
    );

    // ========================================================================
    // (a) 主机寄存器窗 AXI4-Lite 异步桥（cpu_clk 从口 ⇄ npu_clk 主口）
    //     cpu 从口 ← glue.io_npuAxi_*（现有 npuAxi_*）；npu 主口 → NpuTop.axilite_*（npuAxi2_*）。
    //   端口名逐字取自 `y1/gen/NpuAxiLiteCdc.v`（SpinalHDL 产物）。
    // ========================================================================
    NpuAxiLiteCdc u_npu_axilite_cdc (
        .io_cpuClk  (soc_clk),
        .io_cpuRstn (npu_dom_cpu_rstn),
        .io_npuClk  (npu_clk),
        .io_npuRstn (npu_dom_npu_rstn),
        // ---- cpu 侧从口（← glue.io_npuAxi_*）----
        .io_axilite_aw_valid        (npuAxi_awvalid),
        .io_axilite_aw_ready        (npuAxi_awready),
        .io_axilite_aw_payload_addr (npuAxi_awaddr),
        .io_axilite_aw_payload_prot (npuAxi_awprot),
        .io_axilite_w_valid         (npuAxi_wvalid),
        .io_axilite_w_ready         (npuAxi_wready),
        .io_axilite_w_payload_data  (npuAxi_wdata),
        .io_axilite_w_payload_strb  (npuAxi_wstrb),
        .io_axilite_b_valid         (npuAxi_bvalid),
        .io_axilite_b_ready         (npuAxi_bready),
        .io_axilite_b_payload_resp  (npuAxi_bresp),
        .io_axilite_ar_valid        (npuAxi_arvalid),
        .io_axilite_ar_ready        (npuAxi_arready),
        .io_axilite_ar_payload_addr (npuAxi_araddr),
        .io_axilite_ar_payload_prot (npuAxi_arprot),
        .io_axilite_r_valid         (npuAxi_rvalid),
        .io_axilite_r_ready         (npuAxi_rready),
        .io_axilite_r_payload_data  (npuAxi_rdata),
        .io_axilite_r_payload_resp  (npuAxi_rresp),
        // ---- npu 侧主口（→ NpuTop.axilite_*）----
        .io_npu_axilite_aw_valid        (npuAxi2_awvalid),
        .io_npu_axilite_aw_ready        (npuAxi2_awready),
        .io_npu_axilite_aw_payload_addr (npuAxi2_awaddr),
        .io_npu_axilite_aw_payload_prot (npuAxi2_awprot),
        .io_npu_axilite_w_valid         (npuAxi2_wvalid),
        .io_npu_axilite_w_ready         (npuAxi2_wready),
        .io_npu_axilite_w_payload_data  (npuAxi2_wdata),
        .io_npu_axilite_w_payload_strb  (npuAxi2_wstrb),
        .io_npu_axilite_b_valid         (npuAxi2_bvalid),
        .io_npu_axilite_b_ready         (npuAxi2_bready),
        .io_npu_axilite_b_payload_resp  (npuAxi2_bresp),
        .io_npu_axilite_ar_valid        (npuAxi2_arvalid),
        .io_npu_axilite_ar_ready        (npuAxi2_arready),
        .io_npu_axilite_ar_payload_addr (npuAxi2_araddr),
        .io_npu_axilite_ar_payload_prot (npuAxi2_arprot),
        .io_npu_axilite_r_valid         (npuAxi2_rvalid),
        .io_npu_axilite_r_ready         (npuAxi2_rready),
        .io_npu_axilite_r_payload_data  (npuAxi2_rdata),
        .io_npu_axilite_r_payload_resp  (npuAxi2_rresp)
    );

    // ========================================================================
    // (b) 内存主口 AXI4 异步桥（beat-serialized；npu_clk 从口 ⇄ cpu_clk 主口）
    //     npu 从口 ← NpuTop.axi_*（npuMem2_*）；cpu 主口 → glue.io_npuMem_*（npuMem_*，喂 §3.5 汇聚点）。
    //   端口名逐字取自 `y1/gen/NpuMemCdc.v`。
    // ========================================================================
    NpuMemCdc u_npu_mem_cdc (
        .cpuClk  (soc_clk),
        .cpuRstn (npu_dom_cpu_rstn),
        .npuClk  (npu_clk),
        .npuRstn (npu_dom_npu_rstn),
        // ---- npu 侧从口（← NpuTop.axi_*）----
        .npuMem_aw_valid        (npuMem2_awvalid),
        .npuMem_aw_ready        (npuMem2_awready),
        .npuMem_aw_payload_addr (npuMem2_awaddr),
        .npuMem_aw_payload_id   (npuMem2_awid),
        .npuMem_aw_payload_len  (npuMem2_awlen),
        .npuMem_aw_payload_size (npuMem2_awsize),
        .npuMem_aw_payload_burst(npuMem2_awburst),
        .npuMem_aw_payload_cache(npuMem2_awcache),
        .npuMem_aw_payload_prot (npuMem2_awprot),
        .npuMem_w_valid         (npuMem2_wvalid),
        .npuMem_w_ready         (npuMem2_wready),
        .npuMem_w_payload_data  (npuMem2_wdata),
        .npuMem_w_payload_strb  (npuMem2_wstrb),
        .npuMem_w_payload_last  (npuMem2_wlast),
        .npuMem_b_valid         (npuMem2_bvalid),
        .npuMem_b_ready         (npuMem2_bready),
        .npuMem_b_payload_id    (npuMem2_bid),
        .npuMem_b_payload_resp  (npuMem2_bresp),
        .npuMem_ar_valid        (npuMem2_arvalid),
        .npuMem_ar_ready        (npuMem2_arready),
        .npuMem_ar_payload_addr (npuMem2_araddr),
        .npuMem_ar_payload_id   (npuMem2_arid),
        .npuMem_ar_payload_len  (npuMem2_arlen),
        .npuMem_ar_payload_size (npuMem2_arsize),
        .npuMem_ar_payload_burst(npuMem2_arburst),
        .npuMem_ar_payload_cache(npuMem2_arcache),
        .npuMem_ar_payload_prot (npuMem2_arprot),
        .npuMem_r_valid         (npuMem2_rvalid),
        .npuMem_r_ready         (npuMem2_rready),
        .npuMem_r_payload_data  (npuMem2_rdata),
        .npuMem_r_payload_id    (npuMem2_rid),
        .npuMem_r_payload_resp  (npuMem2_rresp),
        .npuMem_r_payload_last  (npuMem2_rlast),
        // ---- cpu 侧主口（→ glue.io_npuMem_*）----
        .cpuMem_aw_valid        (npuMem_awvalid),
        .cpuMem_aw_ready        (npuMem_awready),
        .cpuMem_aw_payload_addr (npuMem_awaddr),
        .cpuMem_aw_payload_id   (npuMem_awid),
        .cpuMem_aw_payload_len  (npuMem_awlen),
        .cpuMem_aw_payload_size (npuMem_awsize),
        .cpuMem_aw_payload_burst(npuMem_awburst),
        .cpuMem_aw_payload_cache(npuMem_awcache),
        .cpuMem_aw_payload_prot (npuMem_awprot),
        .cpuMem_w_valid         (npuMem_wvalid),
        .cpuMem_w_ready         (npuMem_wready),
        .cpuMem_w_payload_data  (npuMem_wdata),
        .cpuMem_w_payload_strb  (npuMem_wstrb),
        .cpuMem_w_payload_last  (npuMem_wlast),
        .cpuMem_b_valid         (npuMem_bvalid),
        .cpuMem_b_ready         (npuMem_bready),
        .cpuMem_b_payload_id    (npuMem_bid),
        .cpuMem_b_payload_resp  (npuMem_bresp),
        .cpuMem_ar_valid        (npuMem_arvalid),
        .cpuMem_ar_ready        (npuMem_arready),
        .cpuMem_ar_payload_addr (npuMem_araddr),
        .cpuMem_ar_payload_id   (npuMem_arid),
        .cpuMem_ar_payload_len  (npuMem_arlen),
        .cpuMem_ar_payload_size (npuMem_arsize),
        .cpuMem_ar_payload_burst(npuMem_arburst),
        .cpuMem_ar_payload_cache(npuMem_arcache),
        .cpuMem_ar_payload_prot (npuMem_arprot),
        .cpuMem_r_valid         (npuMem_rvalid),
        .cpuMem_r_ready         (npuMem_rready),
        .cpuMem_r_payload_data  (npuMem_rdata),
        .cpuMem_r_payload_id    (npuMem_rid),
        .cpuMem_r_payload_resp  (npuMem_rresp),
        .cpuMem_r_payload_last  (npuMem_rlast)
    );

    // ========================================================================
    // (c) IRQ 电平跨域（npu_clk 保持电平 → cpu_clk 域 2-FF 同步）
    //     NpuTop.irq（npu_irq）→ io_cpuIrq（npu_irq_cpu）→ glue.io_npuIrq（PLIC 源 3）。
    //     反向口不用：清走 CTRL.soft_reset（一次寄存器写，经 (a) 的 AXI4-Lite 桥跨到 npu 域）。
    //   端口名逐字取自 `y1/gen/NpuIrqCdc.v`。
    // ========================================================================
    NpuIrqCdc u_npu_irq_cdc (
        .io_cpuClk      (soc_clk),
        .io_cpuRstn     (npu_dom_cpu_rstn),
        .io_npuClk      (npu_clk),
        .io_npuRstn     (npu_dom_npu_rstn),
        .io_npuIrq      (npu_irq),
        .io_cpuIrq      (npu_irq_cpu),
        .io_cpuClearReq (1'b0),   // 未用：反向清不走此口（见上）
        .io_npuClearReq ()        // 未用（悬空）
    );

    // ========================================================================
    // NpuTop：**跑 npu_clk**（见文件头【10】/【11】）；端口表逐字取自 y1/gen/NpuTop.v
    // ========================================================================
    NpuTop u_npu (
        .clk   (npu_clk),         // ★ N5b：NPU 整块在 npu_clk（56.25MHz 独立域，T-18c 起，见文件头【10】/【11】）
        .reset (npu_reset),       // npu 域同步释放（cpu 先/npu 后）；高有效、同步（与 NPU 网表同语义）

        // --- AxiLite4 从口（← NpuAxiLiteCdc 的 npu 主口，`npuAxi2_*`）---
        .axilite_aw_valid        (npuAxi2_awvalid),
        .axilite_aw_ready        (npuAxi2_awready),
        .axilite_aw_payload_addr (npuAxi2_awaddr),
        .axilite_aw_payload_prot (npuAxi2_awprot),
        .axilite_w_valid         (npuAxi2_wvalid),
        .axilite_w_ready         (npuAxi2_wready),
        .axilite_w_payload_data  (npuAxi2_wdata),
        .axilite_w_payload_strb  (npuAxi2_wstrb),
        .axilite_b_valid         (npuAxi2_bvalid),
        .axilite_b_ready         (npuAxi2_bready),
        .axilite_b_payload_resp  (npuAxi2_bresp),
        .axilite_ar_valid        (npuAxi2_arvalid),
        .axilite_ar_ready        (npuAxi2_arready),
        .axilite_ar_payload_addr (npuAxi2_araddr),
        .axilite_ar_payload_prot (npuAxi2_arprot),
        .axilite_r_valid         (npuAxi2_rvalid),
        .axilite_r_ready         (npuAxi2_rready),
        .axilite_r_payload_data  (npuAxi2_rdata),
        .axilite_r_payload_resp  (npuAxi2_rresp),

        // --- AXI4 内存主口（→ NpuMemCdc 的 npu 从口，`npuMem2_*`）---
        .axi_aw_valid         (npuMem2_awvalid),
        .axi_aw_ready         (npuMem2_awready),
        .axi_aw_payload_addr  (npuMem2_awaddr),
        .axi_aw_payload_id    (npuMem2_awid),
        .axi_aw_payload_len   (npuMem2_awlen),
        .axi_aw_payload_size  (npuMem2_awsize),
        .axi_aw_payload_burst (npuMem2_awburst),
        .axi_aw_payload_cache (npuMem2_awcache),
        .axi_aw_payload_prot  (npuMem2_awprot),
        .axi_w_valid          (npuMem2_wvalid),
        .axi_w_ready          (npuMem2_wready),
        .axi_w_payload_data   (npuMem2_wdata),
        .axi_w_payload_strb   (npuMem2_wstrb),
        .axi_w_payload_last   (npuMem2_wlast),
        .axi_b_valid          (npuMem2_bvalid),
        .axi_b_ready          (npuMem2_bready),
        .axi_b_payload_id     (npuMem2_bid),
        .axi_b_payload_resp   (npuMem2_bresp),
        .axi_ar_valid         (npuMem2_arvalid),
        .axi_ar_ready         (npuMem2_arready),
        .axi_ar_payload_addr  (npuMem2_araddr),
        .axi_ar_payload_id    (npuMem2_arid),
        .axi_ar_payload_len   (npuMem2_arlen),
        .axi_ar_payload_size  (npuMem2_arsize),
        .axi_ar_payload_burst (npuMem2_arburst),
        .axi_ar_payload_cache (npuMem2_arcache),
        .axi_ar_payload_prot  (npuMem2_arprot),
        .axi_r_valid          (npuMem2_rvalid),
        .axi_r_ready          (npuMem2_rready),
        .axi_r_payload_data   (npuMem2_rdata),
        .axi_r_payload_id     (npuMem2_rid),
        .axi_r_payload_resp   (npuMem2_rresp),
        .axi_r_payload_last   (npuMem2_rlast),

        .irq (npu_irq)
    );

    // ---- 观测：template 的 CsrTracer（VexiiRiscv 无此口）⇒ 恒 0 ----
    assign tracer_valid   = 1'b0;
    assign tracer_payload = 8'd0;

    // ---- ★ V1：VIDEO CSR 窗从口出层（glue.io_videoAxi_* ↔ 本层 video_* 端口）----
    //   纯直通（一根中间逻辑都不加）：胶合块就是这个窗的**主方**，本层只是把 20 根信号
    //   原样搬到板级顶层（接收方 = `video_regs u_video_regs`，1 KiB 窗内偏移）。
    assign video_awvalid = videoAxi_awvalid;
    assign video_awaddr  = videoAxi_awaddr;
    assign video_awprot  = videoAxi_awprot;
    assign video_wvalid  = videoAxi_wvalid;
    assign video_wdata   = videoAxi_wdata;
    assign video_wstrb   = videoAxi_wstrb;
    assign video_bready  = videoAxi_bready;
    assign video_arvalid = videoAxi_arvalid;
    assign video_araddr  = videoAxi_araddr;
    assign video_arprot  = videoAxi_arprot;
    assign video_rready  = videoAxi_rready;
    assign videoAxi_awready = video_awready;
    assign videoAxi_wready  = video_wready;
    assign videoAxi_bvalid  = video_bvalid;
    assign videoAxi_bresp   = video_bresp;
    assign videoAxi_arready = video_arready;
    assign videoAxi_rvalid  = video_rvalid;
    assign videoAxi_rdata   = video_rdata;
    assign videoAxi_rresp   = video_rresp;

    // ---- PHY 复位 = **独立上电复位（POR）** ----
    // ⚠️ 不接任何 PLL lock：PHY 的 `rgmii_rxc` 正是 RGMII 相关 PLL 的输入 ⇒ 闭环。
    //    也不恒 1：PHY 拿不到复位脉冲 ⇒ 上电要等很久、且收不到包。
    //    ~10.5ms 复位脉冲 = 20bit @100MHz（PHY 要求 ≥10ms）。
    reg [19:0] phy_por_cnt = 20'd0;
    always @(posedge soc_clk)
        if (phy_por_cnt != 20'hF_FFFF) phy_por_cnt <= phy_por_cnt + 20'd1;
    assign eth_phy_rstn = (phy_por_cnt == 20'hF_FFFF);

    // ========================================================================
    // ★ pBus 探针（保留契约，本设计恒 0；见文件头【8】）
    // ========================================================================
`ifdef NAXMINI_DBG_PBUS
    assign dbg_pbus_awvalid = 1'b0;
    assign dbg_pbus_awready = 1'b0;
    assign dbg_pbus_awaddr  = 32'd0;
    assign dbg_pbus_awprot  = 3'd0;
    assign dbg_pbus_wvalid  = 1'b0;
    assign dbg_pbus_wready  = 1'b0;
    assign dbg_pbus_wdata   = 32'd0;
    assign dbg_pbus_wstrb   = 4'd0;
    assign dbg_pbus_bvalid  = 1'b0;
    assign dbg_pbus_bready  = 1'b0;
    assign dbg_pbus_bresp   = 2'd0;
    assign dbg_pbus_arvalid = 1'b0;
    assign dbg_pbus_arready = 1'b0;
    assign dbg_pbus_araddr  = 32'd0;
    assign dbg_pbus_arprot  = 3'd0;
    assign dbg_pbus_rvalid  = 1'b0;
    assign dbg_pbus_rready  = 1'b0;
    assign dbg_pbus_rdata   = 32'd0;
    assign dbg_pbus_rresp   = 2'd0;
`endif

endmodule
