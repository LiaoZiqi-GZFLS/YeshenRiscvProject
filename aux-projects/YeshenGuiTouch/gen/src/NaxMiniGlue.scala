import chisel3._
import chisel3.util._

// ============================================================================
// NaxMiniGlue —— 本项目自研的胶合块（P1 的「外设端 + 装载链 + 内存主口汇聚」）
//
// 上游：`rtl/NaxSocMini.v`（NaxRiscv 官方 `NaxGen` 产出的社区 fabric，零改动入库）
//   mBus_* : AXI4 主（**64bit data**/32bit addr，awid=arid=bid=rid=2bit，**有 awallStrb、没有 prot**）
//   pBus_* : AXI4-Lite 主（32bit，带 3bit awprot/arprot）
//   CLINT(0xF001_0000)/PLIC(0xF0C0_0000) 在 NaxSoc 内部消化、**不出端口**
// 本模块对这台上游呈现两个**从口**（`pBus` / `cpuMem`），对下游呈现一个**主口**（`mem`）：
// `mem` 的形状 = `src/soc/DDR3Bridge.scala` 的 `AXIIO64`（4bit id / **64bit data**）
// ⇒ 与 `DDR3Bridge`（`Flipped(new AXIIO64)`）**零胶合直连**。
//
// ⚠️ 2026-09-30（Task 17）**整条内存通路原生 64bit**（上位 spec：`docs/superpowers/specs/
//    2026-09-29-native-64bit-design.md` 方案 N）：
//      `io_cpuMem`（对齐 `rtl/NaxSocMini.v` 的 `mBus_*`：`wdata[63:0]`/`wstrb[7:0]`/`rdata[63:0]`，
//      其余同）→ 装载选通 → `io.mem`（`AXIIO64`）**全 64bit**。
//    **本模块里没有、也不许有任何降位宽桥**：交付路径唯一那次宽度转换已经下沉到
//    `DDR3Bridge` 内部的 32B 聚合（它的 DDR 侧协议一字未改，见该文件头）。
//    32bit 版的旧网表留档在 `rtl32/NaxSocMini.v`（标明"已被 T12/T13 证伪，只作对照"）。
//
// 三件事：
//  1) **外设解码**：pBus 上 `0xF000_1000` → ns16550a、`0xF000_2000` → GPIO，其余 → DECERR。
//     ⚠️ 两条承重纪律，照抄 `NaxYeshenSoC/src/NaxSoC.scala` 的踩坑结论（落点见下文各自的注释）：
//       ① 响应来源必须在**握手拍锁存**（`NaxSoC.scala:463-465`）
//       ② 读写**互斥**（`NaxSoC.scala:359-361`：单 outstanding 的桥，读突发中插 AW 会搅乱状态机）
//  2) **装载链**：`SdLoader`（TF 卡）为主、`UartLoader`（串口）为后备，都是 AXI 主方、直写内存；
//     装载期 `cpuReset` 扣住 CPU ⇒ 装载器与 CPU 在**时间上互斥** ⇒ 本任务**不需要仲裁器**，
//     一个装载选通多路器即可（spec §4.1）。
//  3) **内存主口汇聚点**（spec §9-1 给 P2 预留的形状）：`io.mem` ← 选通(装载器, CPU)。
//     P2 接 Gemmini 时**只替换这一处的实现**（换成真仲裁器），别处都不动。
//
// ⚠️ 本模块自己的 `clock` / `reset`（Chisel 生成顶层的两个端口）**只接板级复位**，
//    **不要** OR 上 `io.cpuReset`：装载器必须能被复位释放才能干活（`cpuReset` 只进 NaxSocMini）。
// ============================================================================

// ===================== 地址常量（与 spec §4.3 对齐）=====================
// ⚠️ 改这里的任何一个数都必须同步三处：DTS / OpenSBI `platform.c` / TF 卡装载表
//    （Task 9 的地址对账脚本守这条）。
object NaxMiniMap {
  val CONSOLE_BASE = 0xF0001000L   // ns16550a（DTS 声明 reg-shift=2 / reg-io-width=4 ⇒ 每寄存器 4B）
  val GPIO_BASE    = 0xF0002000L
  // 4KB 页级掩码：两个外设各占一页（与 NaxYeshenSoC 的 UART_MASK/GPIO_MASK 同款）
  val CONSOLE_MASK = 0xFFFF_F000L
  val GPIO_MASK    = 0xFFFF_F000L
  // 控制台中断在 `peripheral_externalInterrupts_port[31:0]` 上占的位号（板级顶层按它接线）。
  // ⚠️ DTS 里 PLIC 的源号必须与板级实际选用的位号一致（Task 8/9 用探针实测确认后对账）。
  val CONSOLE_IRQ_BIT = 1

  // ---- LiteEth（网卡）三个窗口（2026-10-06）----
  // 与 `board/liteeth_wrap.v` 的 localparam、以及 DTS 的 `reg` 三元组**必须逐字一致**。
  // 「mac」= 17 个 32bit CSR（字节偏移>>2 就是寄存器号）；「buffer」= 2×0x800 rx 槽 + 2×0x800 tx 槽；
  // 「mdio」主线驱动这一版不用（但窗口必须存在且应答复 0，见 liteeth_wrap.v 文件头）。
  val ETH_MAC_BASE  = 0xF0003000L
  val ETH_MDIO_BASE = 0xF0004000L
  // ⚠️⚠️ `buffer` 基址**必须 0x2000 对齐**（它 8 KB，只用一个掩码 `0xFFFF_E000` 译码）。
  //   第一版写成 0xF000_5000（不是 0x2000 的整数倍）⇒ 掩码只盖住前 4 KB，**后 4 KB（tx 槽）
  //   落进"未解码"⇒ pBus 回 DECERR ⇒ CPU 上 `store access fault` ⇒ 内核 panic**。
  //   实测现场：`liteeth_start_xmit → memcpy_toio` 写物理 0xF0006000 挂掉（2026-10-06 仿真）。
  //   三处必须同步：本文件 / `board/liteeth_wrap.v` 的 localparam / DTS 的 reg 第 3 段。
  val ETH_BUF_BASE  = 0xF0008000L
  val ETH_MAC_MASK  = 0xFFFF_FF00L
  val ETH_MDIO_MASK = 0xFFFF_FF00L
  val ETH_BUF_MASK  = 0xFFFF_E000L
  // LiteEth 的中断位号（板级 nax_mini_soc.v 把 eth_irq 接到 ext_int 的**位 2** ⇒ PLIC 源 2）
  val ETH_IRQ_BIT = 2
}

// ===================== 与 NaxSocMini 逐字对应的端口 bundle =====================
// 方向以「NaxSocMini 自己」为视角（它驱动 = Output）⇒ 本模块用 `Flipped(...)` 接回来。
// 名字/位宽逐条取自 `rtl/NaxSocMini.v` 的模块头（实测 dump，不是猜）。
// ⚠️ Task 17：数据通道 32 → **64bit**（`wdata`/`rdata` = 64、`wstrb` = 8bit）。地址/`len`/`size`/
//    `burst`/id（2bit）/`awallStrb` **一律不变**，端口名也因此**逐字不变**（宽度是唯一差异）。

class NaxMiniAxi64 extends Bundle {
  val awvalid = Output(Bool())
  val awready = Input(Bool())
  val awaddr  = Output(UInt(32.W))
  val awid    = Output(UInt(2.W))
  val awlen   = Output(UInt(8.W))
  val awsize  = Output(UInt(3.W))
  val awburst = Output(UInt(2.W))
  // ⚠️ NaxSocMini 的 mBus **没有 awprot/awcache/awlock**，但多一条 `awallStrb`
  //    （SpinalHDL 的"整笔突发的 strobe 全 1"提示位）。本模块**不消费**它（真值是 `wstrb`），
  //    留在 bundle 里只是为了让 Task 8 的 Verilog 组装能与 NaxSocMini 的端口名逐字对齐。
  val awallStrb = Output(Bool())

  val wvalid  = Output(Bool())
  val wready  = Input(Bool())
  val wdata   = Output(UInt(64.W))
  val wstrb   = Output(UInt(8.W))
  val wlast   = Output(Bool())

  val bvalid  = Input(Bool())
  val bready  = Output(Bool())
  val bid     = Input(UInt(2.W))
  val bresp   = Input(UInt(2.W))

  val arvalid = Output(Bool())
  val arready = Input(Bool())
  val araddr  = Output(UInt(32.W))
  val arid    = Output(UInt(2.W))
  val arlen   = Output(UInt(8.W))
  val arsize  = Output(UInt(3.W))
  val arburst = Output(UInt(2.W))

  val rvalid  = Input(Bool())
  val rready  = Output(Bool())
  val rdata   = Input(UInt(64.W))
  val rid     = Input(UInt(2.W))
  val rresp   = Input(UInt(2.W))
  val rlast   = Input(Bool())
}

class NaxMiniAxiLite32 extends Bundle {
  val awvalid = Output(Bool())
  val awready = Input(Bool())
  val awaddr  = Output(UInt(32.W))
  val awprot  = Output(UInt(3.W))

  val wvalid = Output(Bool())
  val wready = Input(Bool())
  val wdata  = Output(UInt(32.W))
  val wstrb  = Output(UInt(4.W))

  val bvalid = Input(Bool())
  val bready = Output(Bool())
  val bresp  = Input(UInt(2.W))

  val arvalid = Output(Bool())
  val arready = Input(Bool())
  val araddr  = Output(UInt(32.W))
  val arprot  = Output(UInt(3.W))

  val rvalid = Input(Bool())
  val rready = Output(Bool())
  val rdata  = Input(UInt(32.W))
  val rresp  = Input(UInt(2.W))
}

// ===================== 胶合块 =====================
class NaxMiniGlue extends Module {
  override def desiredName = "NaxMiniGlue"

  val io = IO(new Bundle {
    // ---- 上游 NaxSocMini 的两个从口 ----
    val pBus   = Flipped(new NaxMiniAxiLite32)  // AXI4-Lite：uncache MMIO（外设）—— **仍 32bit**（spec §6 不做）
    val cpuMem = Flipped(new NaxMiniAxi64)      // AXI4：I$ 重填 / D$ 重填与回写（内存）—— **64bit**

    // ---- 下游：内存主口（sim: tb 内存模型；板上: DDR3Bridge.axi）----
    // ⚠️ Task 17：`AXIIO`（32bit 数据）→ **`AXIIO64`**（64bit 数据 / 8bit wstrb，id 仍 4bit）。
    //    `AXIIO64` 定义在 `src/soc/DDR3Bridge.scala`（V1 的 64bit 从口形状）⇒ 两边**同一个类型**，
    //    板级装配时 `io_mem_*` 与 DDR3Bridge 的 `io_axi_*` 位宽逐条相等，**没有任何桥**。
    val mem = new AXIIO64

    // ---- 外设引脚 ----
    val uart_txd = Output(Bool())
    val uart_rxd = Input(Bool())
    val gpio_in  = Input(UInt(8.W))    // 板上只引 8 位（高 24 位恒空 0）
    val gpio_out = Output(UInt(8.W))
    val gpio_dir = Output(UInt(8.W))
    val irq      = Output(Bool())      // 控制台中断 ⇒ 板级接 externalInterrupts[CONSOLE_IRQ_BIT]

    // ---- LiteEth 网卡（2026-10-06）----
    // 形态与 console/gpio 完全一样：**本模块解码、按窗口选通**，下游是板级 `liteeth_wrap.v`
    // 里的 AXI-Lite→Wishbone 适配器（它再往 LiteEth MAC 的 CSR/槽 Wishbone 从口走）。
    // 三个窗口见 `NaxMiniMap` 的 ETH_*；IRQ 不走这里（板级直接从 liteeth_wrap 取 eth_irq 进 PLIC）。
    // ⚠️ **不加 `Flipped`**：本模块对它是**主方**（与 `pBus`/`cpuMem` 相反——那两路本模块是从方）。
    val ethAxi = new NaxMiniAxiLite32

    // ---- 装载链（板上 strap + TF 卡引脚 + 装载期的 CPU 复位）----
    val loadMode   = Input(Bool())     // 板上接 KEY1：1 = 装载模式
    val loadActive = Output(Bool())    // 1 = 装载器正在当主人（CPU 被扣复位；观察/MUX 选择用）
    val sd_sck     = Output(Bool())
    val sd_mosi    = Output(Bool())
    val sd_miso    = Input(Bool())
    val sd_cs_n    = Output(Bool())
    val cpuReset   = Output(Bool())    // 1 = CPU 扣在复位（板级顶层 OR 进 NaxSocMini.asyncReset）

    // 诊断（SD 通路调试用）：SD 装载器的 io.state / io.errCode —— 板级把它塞进反向信道那条 NXB 帧，
    // 主机侧用 tshark 就能读（控制台在 loadActive=1 时是静默的，LED 又只能看 1 位）。
    val sd_state     = Output(UInt(4.W))
    val sd_err       = Output(UInt(4.W))
    val sd_dbg       = Output(UInt(32.W))
    val sd_dbg2      = Output(UInt(32.W))     // 诊断 2：SD 装载器的 AXI 突发通路（见 SdLoader 末尾位域）
  })

  // ========================================================================
  // 1) 装载链：TF 卡为主、串口为后备（谁在跑谁就独占内存主口）
  // ========================================================================
  // 优先级照抄 `YeshenCore/src/SoC/SoC.scala:233-249`：
  //   `loadMode=1` 且 TF 通路**没结束** ⇒ 先试 TF（卡上块 0 = 装载表，见 `SdLoader.scala` 文件头）；
  //   卡不在 / 装载表坏（`state=4`）才退到串口装载器。
  //   ⚠️ 「SD 没失败就不许串口抢线」是回退的关键：否则串口装载器会一边发 banner 一边跟 SD 抢 AXI 写。
  //   （YeshenCore 上"是否先试 TF"由 KEY2=`sdMode` 选；P1 只有 KEY1 一根 strap ⇒ 恒用
  //     "TF 优先、串口回退"这一档，即 YeshenCore 里 `sdMode=1` 的行为。）
  private val sdLoader   = Module(new SdLoader)
  // 串口装载器速率：位周期 = 16*baudDiv 拍。本板 soc_clk = 100MHz（Task 14 的 PLL）⇒ 115.7kbaud，
  // 与固件/内核的 `console=115200` 同档（与 YeshenCore 取值一致）。⚠️ soc_clk 改了这里要一起改。
  // ★ 2026-10-25：改回 115200（54）。原 216（28.9k）是当年的"速率实验"，代价是 **SD 失败后**
  //   线路交给串口装载器时波特率与 SD 报文器/内核控制台（115200）不一致 ⇒ 无卡时光看串口是一片
  //   0x00/0xFF 垃圾，判不了状态，只能重烧去试。现在三处同档：无卡/坏卡时会在 115200 上反复看到
  //   `YSLD`（= 串口装载器在等灌数据）⇒ 一眼判定是卡的问题。
  private val uartLoader = Module(new UartLoader(baudDiv = 54))   // 16*54 拍 @100MHz = 115.7 kbaud
  uartLoader.io.rxd := io.uart_rxd
  // ★★ 2026-10-06 上板定案的修复：`loadMode`（C23/KEY1）必须**上电采样一次并锁存**。
  //   下面那句老注释写的本来就是这个口径，但代码一直把 `io.loadMode` **实时**接进三个 enable ⇒
  //   C23 只要在装载过程中抖一下/漂一下，`sdEnable` 立刻掉 ⇒ `SdLoader.io.active = 0`
  //   ⇒ `sd.dReady = 0` ⇒ **SdSpi 卡在 pData、载荷永远读不完**。
  //   板上实测签名（完全吻合）：`ph=pData`、`misoHi=1`、`errCode=0`、而 `dbg2` 显示
  //   **一个 AXI 突发都没发**（`awSeen/wSeen/bSeen=0`、`wState=wIdle`、`grp/bCur=0`）——
  //   排除法只剩 `active=0` 一种可能。
  //   锁存语义用"见过高就保持"：按钮常态为高 ⇒ 复位后立刻锁 1（正常装载）；
  //   上电时按住 KEY1（低）= 非装载模式（与"上电那一刻采样"逐拍同义），
  //   而且**之后按 KEY1 不会再中途打断装载**。
  private val loadModeLatch = RegInit(false.B)
  when(io.loadMode) { loadModeLatch := true.B }

  private val sdDone     = sdLoader.io.released || sdLoader.io.state === 4.U
  private val sdEnable   = loadModeLatch && !sdDone
  // 串口回退：SD 失败后才上（原 ETH 那一级已随 D1 删除）
  private val uartEnable = loadModeLatch && sdLoader.io.state === 4.U && !uartLoader.io.released

  sdLoader.io.active   := sdEnable
  uartLoader.io.active := uartEnable

  sdLoader.io.sdMiso := io.sd_miso
  io.sd_sck  := sdLoader.io.sdSck
  io.sd_mosi := sdLoader.io.sdMosi
  io.sd_cs_n := sdLoader.io.sdCsN
  // 诊断观测（只读，不影响功能）：SD 装载器状态/错误码 ⇒ 板级 → 反向信道
  io.sd_state := sdLoader.io.state
  io.sd_err   := sdLoader.io.errCode
  io.sd_dbg   := sdLoader.io.dbg
  io.sd_dbg2  := sdLoader.io.dbg2

  // ---- SD 板级诊断的 **UART 出口**（2026-10-06，D1 之后）----
  // D1 删掉了 EthLoader 与厂家 eth 栈 ⇒ 原来那条第 16 字节反向 'NXB' 帧没了；而这块板子上
  // **`tf_test_200mini` 参照工程本来就是只用 UART 报文做诊断**。于是把同一组诊断字改走控制台线：
  // 每 100ms 一行 `"SDR " + 18hex + CRLF`（波特 115200，与内核 `console=115200` 同档 ⇒ **Linux
  // 起来之前就能读**）。夺线规则见 `SdUartReport` 文件头：SD 当主人时占线，SD 失败后再多占 50ms
  // 把终态那一行发完（否则会被紧随其后的 UART 装载器 banner 抢掉）。
  private val sdReport = Module(new SdUartReport)
  sdReport.io.enable := sdEnable
  sdReport.io.state  := sdLoader.io.state
  sdReport.io.err    := sdLoader.io.errCode
  sdReport.io.dbg    := sdLoader.io.dbg
  sdReport.io.dbg2   := sdLoader.io.dbg2

  // ⚠️ `loadMode` 直接来自板上按键（异步于 soc_clk），这里刻意不做同步：
  //    它只在"上电那一刻"被采样（YeshenCore 同款），且 SD/串口两个装载器各自都有超时兜底。
  private val loadActive = sdEnable || uartEnable
  io.loadActive := loadActive
  // 装载期把 CPU 扣在复位：装载器与 CPU 时间上互斥 ⇒ 内存主口只需选通（spec §4.1）。
  // ⚠️ 板级顶层把它 OR 进 `NaxSocMini.asyncReset`；**不要**把它接进本模块的 `reset`。
  io.cpuReset := loadActive

  // ========================================================================
  // 2) 外设：ns16550a 控制台 + GPIO
  // ========================================================================
  // 控制台在装载期被扣复位（YeshenCore SoC.scala:369 同款）：装载器接管了同一根物理线，
  // 让 16550 停在复位态可以避免半截帧留下的脏字节。
  private val console = withReset(reset.asBool || loadActive) { Module(new Uart16550) }
  private val gpio    = Module(new GPIOController)

  console.io.rxd := io.uart_rxd
  // 装载期控制台 TX 归装载器（否则两个主方往同一根线上灌字）；RX 两边都接（谁在用谁解释）。
  // 三级优先（高→低）：SD 诊断报文器（SD 在跑 / 刚失败那 50ms）→ UART 装载器 → 16550 控制台。
  io.uart_txd := Mux(sdReport.io.owner, sdReport.io.txd,
                   Mux(loadActive, uartLoader.io.txd, console.io.txd))
  io.irq      := console.io.irq

  gpio.io.gpio_in := io.gpio_in.pad(32)   // 板上只引 8 位 ⇒ 高 24 位恒 0
  io.gpio_out := gpio.io.gpio_out(7, 0)
  io.gpio_dir := gpio.io.gpio_dir(7, 0)
  // GPIO 的 `interrupt` 在 P1 不接线（只拿它的输出寄存器点灯/看状态）⇒ 留空，firtool 会剪掉。

  // ========================================================================
  // 3) 外设解码（pBus, AXI4-Lite）
  // ========================================================================
  // 与 `NaxYeshenSoC/src/NaxSoC.scala:385-560` 同一套写法：读用读地址、写用写地址，**不合并**。
  private val pR = io.pBus.araddr
  private val pW = io.pBus.awaddr

  private val isConsR = (pR & NaxMiniMap.CONSOLE_MASK.U) === NaxMiniMap.CONSOLE_BASE.U
  private val isGpioR = (pR & NaxMiniMap.GPIO_MASK.U)    === NaxMiniMap.GPIO_BASE.U
  private val isConsW = (pW & NaxMiniMap.CONSOLE_MASK.U) === NaxMiniMap.CONSOLE_BASE.U
  private val isGpioW = (pW & NaxMiniMap.GPIO_MASK.U)    === NaxMiniMap.GPIO_BASE.U
  // LiteEth：三个窗口**合并**成一个选通（细分交给 liteeth_wrap 的适配器，见那里的文件头）。
  // ⚠️ 这里必须用**各自**的掩码：mac/mdio 各 0x100、buffer 0x2000（0x5000+0x2000 = 0x7000，
  //    仍在 pBus 的 16 KiB 外设区 0xF000_0000–0xF000_FFFF 里）。
  private val isEthR = ((pR & NaxMiniMap.ETH_MAC_MASK.U)  === NaxMiniMap.ETH_MAC_BASE.U)  ||
                       ((pR & NaxMiniMap.ETH_MDIO_MASK.U) === NaxMiniMap.ETH_MDIO_BASE.U) ||
                       ((pR & NaxMiniMap.ETH_BUF_MASK.U)  === NaxMiniMap.ETH_BUF_BASE.U)
  private val isEthW = ((pW & NaxMiniMap.ETH_MAC_MASK.U)  === NaxMiniMap.ETH_MAC_BASE.U)  ||
                       ((pW & NaxMiniMap.ETH_MDIO_MASK.U) === NaxMiniMap.ETH_MDIO_BASE.U) ||
                       ((pW & NaxMiniMap.ETH_BUF_MASK.U)  === NaxMiniMap.ETH_BUF_BASE.U)

  // 两个外设都是"8 个 32bit 寄存器"（偏移低 5 位），与复制进来的源码逐字一致。
  console.io.axi.awaddr  := pW(4, 0)
  console.io.axi.awvalid := io.pBus.awvalid && isConsW
  console.io.axi.wdata   := io.pBus.wdata
  console.io.axi.wstrb   := io.pBus.wstrb
  console.io.axi.wvalid  := io.pBus.wvalid && isConsW
  console.io.axi.bready  := io.pBus.bready
  console.io.axi.araddr  := pR(4, 0)
  console.io.axi.arvalid := io.pBus.arvalid && isConsR
  console.io.axi.rready  := io.pBus.rready

  gpio.io.axi.awaddr  := pW(4, 0)
  gpio.io.axi.awvalid := io.pBus.awvalid && isGpioW
  gpio.io.axi.wdata   := io.pBus.wdata
  gpio.io.axi.wstrb   := io.pBus.wstrb
  gpio.io.axi.wvalid  := io.pBus.wvalid && isGpioW
  gpio.io.axi.bready  := io.pBus.bready
  gpio.io.axi.araddr  := pR(4, 0)
  gpio.io.axi.arvalid := io.pBus.arvalid && isGpioR
  gpio.io.axi.rready  := io.pBus.rready

  // LiteEth：地址**整根**给它（三个窗口由它自己再分），valid 按合并后的窗口选通。
  io.ethAxi.awaddr  := pW
  io.ethAxi.awprot  := io.pBus.awprot
  io.ethAxi.awvalid := io.pBus.awvalid && isEthW
  io.ethAxi.wdata   := io.pBus.wdata
  io.ethAxi.wstrb   := io.pBus.wstrb
  io.ethAxi.wvalid  := io.pBus.wvalid && isEthW
  io.ethAxi.bready  := io.pBus.bready
  io.ethAxi.araddr  := pR
  io.ethAxi.arprot  := io.pBus.arprot
  io.ethAxi.arvalid := io.pBus.arvalid && isEthR
  io.ethAxi.rready  := io.pBus.rready

  // ⚠️【纪律①：响应来源必须在握手拍锁存】——照抄 `NaxYeshenSoC/src/NaxSoC.scala:463-465`：
  //    AXI-Lite 的地址负载**只在 `arready/awready` 握手拍保证有效**（SpinalHDL 的 Stream 语义：
  //    fire 之后对端即可更换 payload）⇒ 必须把"这一笔该由谁应答"在握手拍锁存成寄存器。
  //    踩过的症状：核写外设寄存器后读回时挂死（响应被路由到默认分支）。
  private val selNone = 0.U(2.W)
  private val selCons = 1.U(2.W)
  private val selGpio = 2.U(2.W)
  private val selEth  = 3.U(2.W)

  private val rLive = MuxCase(selNone, Seq(isConsR -> selCons, isGpioR -> selGpio, isEthR -> selEth))
  private val wLive = MuxCase(selNone, Seq(isConsW -> selCons, isGpioW -> selGpio, isEthW -> selEth))

  private val rSel = RegInit(selNone)
  private val wSel = RegInit(selNone)
  when(io.pBus.arvalid && io.pBus.arready) { rSel := rLive }
  when(io.pBus.rvalid && io.pBus.rready)   { rSel := selNone }
  when(io.pBus.awvalid && io.pBus.awready) { wSel := wLive }
  when(io.pBus.bvalid && io.pBus.bready)   { wSel := selNone }
  // ⚠️ 上面两对的顺序（先锁存、后清零）依赖"**pBus 主方不流水**"这一前提：NaxRiscv 的 uncache
  //    通路是**阻塞式**（一笔 R 收完才发下一笔 AR），所以"同拍 AR 握手 + 末拍 R fire"不会发生。
  //    若将来换成会这样流水的主方，这两处的优先级要显式写清（同拍清零会把新事务的响应
  //    路由到默认分支 ⇒ 挂死）。

  // 未解码的 uncache 访问：先接受命令、下一拍以 **DECERR** 应答（spec：其余地址给错误响应）。
  // ⚠️ 必须应答而不是放行 —— NaxRiscv 的 uncache 通路是**阻塞式**（等到 rsp 才放行），
  //    无人应答就是永久挂死（与 NaxYeshenSoC 同款，彼处回 OKAY，本处回 DECERR）。
  private val undecRPend = RegInit(false.B)
  private val undecWPend = RegInit(false.B)

  io.pBus.arready := MuxCase(true.B, Seq(
    isConsR -> console.io.axi.arready,
    isGpioR -> gpio.io.axi.arready,
    isEthR  -> io.ethAxi.arready
  ))
  io.pBus.awready := MuxCase(true.B, Seq(
    isConsW -> console.io.axi.awready,
    isGpioW -> gpio.io.axi.awready,
    isEthW  -> io.ethAxi.awready
  ))
  io.pBus.wready := MuxCase(true.B, Seq(
    isConsW -> console.io.axi.wready,
    isGpioW -> gpio.io.axi.wready,
    isEthW  -> io.ethAxi.wready
  ))

  io.pBus.rvalid := MuxLookup(rSel, undecRPend)(Seq(
    selCons -> console.io.axi.rvalid,
    selGpio -> gpio.io.axi.rvalid,
    selEth  -> io.ethAxi.rvalid
  ))
  io.pBus.rdata := MuxLookup(rSel, 0.U)(Seq(
    selCons -> console.io.axi.rdata,
    selGpio -> gpio.io.axi.rdata,
    selEth  -> io.ethAxi.rdata
  ))
  io.pBus.rresp := MuxLookup(rSel, "b11".U)(Seq(   // 默认分支 = 未解码 ⇒ DECERR
    selCons -> console.io.axi.rresp,
    selGpio -> gpio.io.axi.rresp,
    selEth  -> io.ethAxi.rresp
  ))
  io.pBus.bvalid := MuxLookup(wSel, undecWPend)(Seq(
    selCons -> console.io.axi.bvalid,
    selGpio -> gpio.io.axi.bvalid,
    selEth  -> io.ethAxi.bvalid
  ))
  io.pBus.bresp := MuxLookup(wSel, "b11".U)(Seq(   // 默认分支 = 未解码 ⇒ DECERR
    selCons -> console.io.axi.bresp,
    selGpio -> gpio.io.axi.bresp,
    selEth  -> io.ethAxi.bresp
  ))

  when(io.pBus.arvalid && io.pBus.arready && rLive === selNone) { undecRPend := true.B }
  when(io.pBus.rvalid && io.pBus.rready)                        { undecRPend := false.B }
  when(io.pBus.awvalid && io.pBus.awready && wLive === selNone) { undecWPend := true.B }
  when(io.pBus.bvalid && io.pBus.bready)                        { undecWPend := false.B }

  // ========================================================================
  // 4) 内存主口汇聚（spec §9-1 的汇聚点）
  // ========================================================================
  // ⚠️【纪律②：读写必须互斥】——照抄 `NaxYeshenSoC/src/NaxSoC.scala:359-361`：
  //    下游桥 `DDR3Bridge` 是**单 outstanding**：它的 `awready` 只看自己的写状态机
  //    （`wrState === sWrIdle`，见 `src/soc/DDR3Bridge.scala:123`），**不看读状态机** ⇒
  //    一笔读突发在飞（AR 已握手、R 还没收完，`rdState === sRdData`）期间若插进一笔 AW，
  //    读写两条状态机会同时对 DDR3 IP 发起访问（读数据还在 R 通道上往回搬）⇒ 搅乱状态机。
  //    所以这里在**发出 AW 之前**先看"下游有没有读在飞"，有就不放行。
  //    （NaxYeshenSoC 的判据是 `(qV === 0.U) && !pendV`，同一个意思：读没落地完不许插写。）
  private val memRdBusy = RegInit(false.B)
  when(io.mem.ar.arvalid && io.mem.ar.arready) { memRdBusy := true.B }
  .elsewhen(io.mem.r.rvalid && io.mem.r.rready && io.mem.r.rlast) { memRdBusy := false.B }
  // ⚠️⚠️【纪律②的**表达方式**修正，2026-09-30（M2-b Gate 2 第三轮）】——互斥必须由 **ready 回告**
  //    （"我这一拍收不下"）表达，**不能**靠"掩掉自己的 valid、却把下游 ready 直通给核"。
  //    踩过的症状（实测根因，见 `docs/M2-Gate2-2026-09-30.md` §14）：本模块把 AW 的 valid 掩成 0，
  //    而 `awready` 是**恒 1 的直通** ⇒ 核的 `Axi4Bridge` 判据 `a_cmdFork_fire = valid && ready`
  //    仍然成立（`rtl/NaxSocMini.v:11133/11154`）⇒ 这笔 A 命令被核当成**已成交**
  //    （`a_buffered_fork2_logic_linkEnable_0 <= 0`，:11240）⇒ **核永不重发**；
  //    而下游 `aw_q` 空、W 照发 ⇒ 从方永不成突发 ⇒ 永不发 B ⇒ D$ 写回槽（其退路①
  //    `!coherency_release` 在单主设备构建里结构性恒假）**永久冻结**，前端被 halt。
  //    ⇒ 正确写法：读在飞时把 `awready`（以及 `wready`，见下）**拉低**，核就会**保持**
  //    该笔命令的 valid+payload 直到我们真的收下（AXI 的标准背压），不会再出现"假装接受"。
  //    （`memRdBusy` 的原意一字未改：下游 `DDR3Bridge` 单 outstanding、读写互斥；这里改的是
  //     "怎么表达互斥"，不是取消互斥。装载期 `loadActive=1` 时下游 AR 恒 0 ⇒ `memRdBusy` 恒 0
  //     ⇒ 两个 ready 与本改动**逐位同值**，装载语义不变。）

  // ---- 分支 A：CPU 的 mBus（2bit id / awallStrb / 无 prot / **64bit data**）⇒ AXIIO64 ----
  private val cpuAxi = Wire(new AXIIO64)
  cpuAxi.aw.awid    := io.cpuMem.awid.pad(4)   // id 零扩展（DDR3Bridge 原样回送：bid/rid）
  cpuAxi.aw.awaddr  := io.cpuMem.awaddr
  cpuAxi.aw.awlen   := io.cpuMem.awlen
  cpuAxi.aw.awsize  := io.cpuMem.awsize
  cpuAxi.aw.awburst := io.cpuMem.awburst
  cpuAxi.aw.awlock  := 0.U
  cpuAxi.aw.awcache := 0.U
  cpuAxi.aw.awprot  := 0.U
  cpuAxi.aw.awvalid := io.cpuMem.awvalid && !memRdBusy   // ←【纪律②】读在飞时不放行 AW
  cpuAxi.w.wid      := 0.U
  cpuAxi.w.wdata    := io.cpuMem.wdata
  cpuAxi.w.wstrb    := io.cpuMem.wstrb
  cpuAxi.w.wlast    := io.cpuMem.wlast
  // ⚠️ W 与 AW **完全对称**：两个半门必须同时加，缺一个就退化成"假装接受"。
  //    本模块对 `io.mem` 是**主方**（W 的 valid 是输出、ready 是输入），所以"这一拍不收 W"只能
  //    由"**不摆 valid** + **不向核回告 ready**"这**两件事一起**表达：
  //      · 掩 `wvalid`（不给从方看到本拍有数据）—— 只掩它会被核当成"已成交"⇒ 丢数据；
  //      · 低 `wready`（不给核回告"收下了"）—— 只低它则从方仍会把这一拍收走（`io.mem.w.wvalid`
  //        还是 1，从方 `wready` 也是 1 ⇒ 握手成立），核以为没成交、稍后**重发同一拍** ⇒ 该拍
  //        要么丢、要么被写到下一笔突发上。实测就是这个半吊子形态：`cyc=49080 memRdBusy=1` 时
  //        "从方看到的 `wready`"仍是 tb 驱动的 1，`[AXI-WARN]` 照丢 2 拍。
  cpuAxi.w.wvalid   := io.cpuMem.wvalid && !memRdBusy
  cpuAxi.b.bready   := io.cpuMem.bready
  cpuAxi.ar.arid    := io.cpuMem.arid.pad(4)
  cpuAxi.ar.araddr  := io.cpuMem.araddr
  cpuAxi.ar.arlen   := io.cpuMem.arlen
  cpuAxi.ar.arsize  := io.cpuMem.arsize
  cpuAxi.ar.arburst := io.cpuMem.arburst
  cpuAxi.ar.arlock  := 0.U
  cpuAxi.ar.arcache := 0.U
  cpuAxi.ar.arprot  := 0.U
  cpuAxi.ar.arvalid := io.cpuMem.arvalid
  cpuAxi.r.rready   := io.cpuMem.rready

  // 回程（分支看到的信号）：就绪/响应**扇出**给两个主方（选通只在"载荷"上做，见下面的汇聚点）。
  // ⚠️【互斥的四个半门（与 `cpuAxi.aw.awvalid`、`cpuAxi.w.wvalid` 成对）】——读在飞（`memRdBusy=1`）时，
  //    我们**拒绝**收下写命令：`awready`/`wready` 拉低（对核）**且** `awvalid`/`wvalid` 拉低（对从方）。
  //    核侧因此保持 valid+payload 不变，等 `memRdBusy` 退掉再一起成交 ⇒ 既不丢 AW，也不丢 W 拍。
  // ★ W 必须与 AW 同门（不能只修 awready）：本核 `Axi4Bridge` 的 W 与 AW **不是**握手依赖 ——
  //    `rtl/NaxSocMini.v:15628 io_down_w_valid = a_data_buffer_valid`（A 命令 fork 出来的数据缓冲，
  //    其 ready 只看 `io_down_w_ready`），与 `io_down_aw_ready` **无关**；
  //    W 的放行条件只由 `a_data_buffer_ready = io_down_w_ready` 决定（:15629）。
  //    ⇒ "AW 被拒 ⇒ 核不会发 W" **不成立**（已在 RTL 上逐行核实）：只修 `awready` 会退化成
  //    "AW 压住、W 照发"⇒ 从方 `aw_q` 空时把 W 拍当 orphan 丢掉（本工程的 tb 内存模型正是这么做的：
  //    `sim/tb_naxmini.cpp` 的 `aw_q.empty()` 分支 `aw_orphan_w++`）⇒ 写数据丢失 + `wlast_mismatch`。
  //    板上下游 `DDR3Bridge` 是 `axi.w.wready := wrState === sWrAgg`（`src/soc/DDR3Bridge.scala:192`）
  //    ⇒ AW 未收下时它本来就不收 W（W 被核侧压住、不会丢）；本门让**仿真与板**这两条路同形，
  //    并且是协议上唯一自洽的写法：既然我们拒绝了这笔写命令，就不该同时消费它的数据。
  //    （不会与 AW 相互死锁：`io_down_aw_valid` 只由 `a_cmd_buffered_valid` 决定，
  //     不看 `io_down_w_ready`；`memRdBusy` 只由**读**清除，而读的 AR 通路我们一个字没动。）
  cpuAxi.aw.awready := io.mem.aw.awready && !memRdBusy
  cpuAxi.w.wready   := io.mem.w.wready   && !memRdBusy
  cpuAxi.b.bvalid   := io.mem.b.bvalid
  cpuAxi.b.bid      := io.mem.b.bid
  cpuAxi.b.bresp    := io.mem.b.bresp
  cpuAxi.ar.arready := io.mem.ar.arready
  cpuAxi.r.rvalid   := io.mem.r.rvalid
  cpuAxi.r.rdata    := io.mem.r.rdata
  cpuAxi.r.rid      := io.mem.r.rid
  cpuAxi.r.rresp    := io.mem.r.rresp
  cpuAxi.r.rlast    := io.mem.r.rlast

  io.cpuMem.awready := cpuAxi.aw.awready
  io.cpuMem.wready  := cpuAxi.w.wready
  io.cpuMem.bid     := cpuAxi.b.bid(1, 0)   // 桥原样回送 4bit id；按 mBus 宽度取低 2 位
  io.cpuMem.bresp   := cpuAxi.b.bresp
  io.cpuMem.bvalid  := cpuAxi.b.bvalid
  io.cpuMem.arready := cpuAxi.ar.arready
  io.cpuMem.rdata   := cpuAxi.r.rdata
  io.cpuMem.rid     := cpuAxi.r.rid(1, 0)
  io.cpuMem.rresp   := cpuAxi.r.rresp
  io.cpuMem.rlast   := cpuAxi.r.rlast
  io.cpuMem.rvalid  := cpuAxi.r.rvalid
  // `io.cpuMem.awallStrb` 不消费（真值是 `wstrb`；它只是"strobe 全 1"的提示位）。

  // ---- 分支 B：装载器（只写：无 id / 无 burst 描述 / 无 prot）⇒ AXIIO64 ----
  // 两个装载器的 AXI 端口同形（`awaddr/awlen/awvalid` + `wdata/wstrb/wlast/wvalid` + `bvalid/bready`），
  // 与 YeshenCore 一样在 SoC 侧按 `sdEnable` 选通（它们互斥，见上面的回退逻辑）。
  // ⚠️ Task 17：两个装载器的主口已改 64bit（每 32B 组 4 拍）⇒ 与 `AXIIO64` **同宽直连**，无扩展。
  // 两路（TF → UART）：D1 起 ETH 装载器已删除，只留 SD 与串口两条回退，
  // 内层保持原来的 SD/UART 两路（互斥关系不变）。
  private val loadAwAddr  = Mux(sdEnable, sdLoader.io.awaddr,  uartLoader.io.awaddr)
  private val loadAwLen   = Mux(sdEnable, sdLoader.io.awlen,   uartLoader.io.awlen)
  private val loadAwValid = Mux(sdEnable, sdLoader.io.awvalid, uartLoader.io.awvalid)
  private val loadWData   = Mux(sdEnable, sdLoader.io.wdata,   uartLoader.io.wdata)
  private val loadWStrb   = Mux(sdEnable, sdLoader.io.wstrb,   uartLoader.io.wstrb)
  private val loadWLast   = Mux(sdEnable, sdLoader.io.wlast,   uartLoader.io.wlast)
  private val loadWValid  = Mux(sdEnable, sdLoader.io.wvalid,  uartLoader.io.wvalid)
  private val loadBReady  = Mux(sdEnable, sdLoader.io.bready,  uartLoader.io.bready)

  private val loaderAxi = Wire(new AXIIO64)
  loaderAxi.aw.awid    := 0.U
  loaderAxi.aw.awaddr  := loadAwAddr
  loaderAxi.aw.awlen   := loadAwLen
  loaderAxi.aw.awsize  := 3.U     // 8 字节/拍（Task 17：64bit 数据总线）
  loaderAxi.aw.awburst := 1.U     // INCR
  loaderAxi.aw.awlock  := 0.U
  loaderAxi.aw.awcache := 0.U
  loaderAxi.aw.awprot  := 0.U
  loaderAxi.aw.awvalid := loadAwValid
  loaderAxi.w.wid      := 0.U
  loaderAxi.w.wdata    := loadWData
  loaderAxi.w.wstrb    := loadWStrb
  loaderAxi.w.wlast    := loadWLast
  loaderAxi.w.wvalid   := loadWValid
  loaderAxi.b.bready   := loadBReady
  // 装载器只写不读（`SdSpi` 从卡上读、写 DDR）：读通道恒空闲
  loaderAxi.ar.arid    := 0.U
  loaderAxi.ar.araddr  := 0.U
  loaderAxi.ar.arlen   := 0.U
  loaderAxi.ar.arsize  := 3.U
  loaderAxi.ar.arburst := 1.U
  loaderAxi.ar.arlock  := 0.U
  loaderAxi.ar.arcache := 0.U
  loaderAxi.ar.arprot  := 0.U
  loaderAxi.ar.arvalid := false.B
  loaderAxi.r.rready   := false.B
  // "回程"字段（从 master 视角是 Input）：本来就是要扇出的信号，这里显式接上——`Wire` 的
  // 每个字段都必须被初始化（Chisel 的 "sink not fully initialized" 检查），而且这样
  // `loaderAxi` 就是一个**完整的 AXIIO64 分支**，P2 换成仲裁器时形状不用改。
  loaderAxi.aw.awready := io.mem.aw.awready
  loaderAxi.w.wready   := io.mem.w.wready
  loaderAxi.b.bvalid   := io.mem.b.bvalid
  loaderAxi.b.bid      := io.mem.b.bid
  loaderAxi.b.bresp    := io.mem.b.bresp
  loaderAxi.ar.arready := io.mem.ar.arready
  loaderAxi.r.rvalid   := io.mem.r.rvalid
  loaderAxi.r.rdata    := io.mem.r.rdata
  loaderAxi.r.rid      := io.mem.r.rid
  loaderAxi.r.rresp    := io.mem.r.rresp
  loaderAxi.r.rlast    := io.mem.r.rlast

  // 装载器的 ready/bvalid 也扇出（谁 active 谁在跑；非主人那个的 active=0 ⇒ 它不驱动总线）
  sdLoader.io.awready   := io.mem.aw.awready
  sdLoader.io.wready    := io.mem.w.wready
  sdLoader.io.bvalid    := io.mem.b.bvalid
  uartLoader.io.awready := io.mem.aw.awready
  uartLoader.io.wready  := io.mem.w.wready
  uartLoader.io.bvalid  := io.mem.b.bvalid

  // ---- ★ 汇聚点：内存主口 ← 选通(装载器, CPU) ----
  // 这是 spec §9-1 要求的**唯一**一处内存主口汇聚：
  //   P1（这里）：装载器与 CPU 时间上互斥（装载期 CPU 被扣复位）⇒ 一个选通多路器就够，无仲裁器；
  //   P2（Gemmini）：把这一段整体换成**仲裁器**（CPU / 装载器 / Gemmini 三主），
  //                 `io.mem` 的形状与 `cpuMem`/装载器侧都不必动 ⇒ 别处代码零改动。
  // 说明：形状上等价于 `io.mem <> Mux(loadActive, loaderAxi, cpuAxi)`，但这里**逐字段**写：
  //   ① `<>` 是**按方向**连线的，而 `Mux` 出来的聚合体会把 `mem.*ready/valid/bresp` 这些
  //      "回程"信号的方向搞反；② 装载器分支的读通道本来就是"恒空闲"。逐字段写清最不容易错。
  private val memSel = loadActive
  io.mem.aw.awid    := Mux(memSel, loaderAxi.aw.awid,    cpuAxi.aw.awid)
  io.mem.aw.awaddr  := Mux(memSel, loaderAxi.aw.awaddr,  cpuAxi.aw.awaddr)
  io.mem.aw.awlen   := Mux(memSel, loaderAxi.aw.awlen,   cpuAxi.aw.awlen)
  io.mem.aw.awsize  := Mux(memSel, loaderAxi.aw.awsize,  cpuAxi.aw.awsize)
  io.mem.aw.awburst := Mux(memSel, loaderAxi.aw.awburst, cpuAxi.aw.awburst)
  io.mem.aw.awlock  := Mux(memSel, loaderAxi.aw.awlock,  cpuAxi.aw.awlock)
  io.mem.aw.awcache := Mux(memSel, loaderAxi.aw.awcache, cpuAxi.aw.awcache)
  io.mem.aw.awprot  := Mux(memSel, loaderAxi.aw.awprot,  cpuAxi.aw.awprot)
  io.mem.aw.awvalid := Mux(memSel, loaderAxi.aw.awvalid, cpuAxi.aw.awvalid)

  io.mem.w.wid    := Mux(memSel, loaderAxi.w.wid,    cpuAxi.w.wid)
  io.mem.w.wdata  := Mux(memSel, loaderAxi.w.wdata,  cpuAxi.w.wdata)
  io.mem.w.wstrb  := Mux(memSel, loaderAxi.w.wstrb,  cpuAxi.w.wstrb)
  io.mem.w.wlast  := Mux(memSel, loaderAxi.w.wlast,  cpuAxi.w.wlast)
  io.mem.w.wvalid := Mux(memSel, loaderAxi.w.wvalid, cpuAxi.w.wvalid)

  io.mem.b.bready := Mux(memSel, loaderAxi.b.bready, cpuAxi.b.bready)

  io.mem.ar.arid    := Mux(memSel, loaderAxi.ar.arid,    cpuAxi.ar.arid)
  io.mem.ar.araddr  := Mux(memSel, loaderAxi.ar.araddr,  cpuAxi.ar.araddr)
  io.mem.ar.arlen   := Mux(memSel, loaderAxi.ar.arlen,   cpuAxi.ar.arlen)
  io.mem.ar.arsize  := Mux(memSel, loaderAxi.ar.arsize,  cpuAxi.ar.arsize)
  io.mem.ar.arburst := Mux(memSel, loaderAxi.ar.arburst, cpuAxi.ar.arburst)
  io.mem.ar.arlock  := Mux(memSel, loaderAxi.ar.arlock,  cpuAxi.ar.arlock)
  io.mem.ar.arcache := Mux(memSel, loaderAxi.ar.arcache, cpuAxi.ar.arcache)
  io.mem.ar.arprot  := Mux(memSel, loaderAxi.ar.arprot,  cpuAxi.ar.arprot)
  io.mem.ar.arvalid := Mux(memSel, loaderAxi.ar.arvalid, cpuAxi.ar.arvalid)

  io.mem.r.rready := Mux(memSel, loaderAxi.r.rready, cpuAxi.r.rready)
}
