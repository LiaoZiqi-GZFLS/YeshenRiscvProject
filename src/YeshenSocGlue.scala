import chisel3._
import chisel3.util._

// ============================================================================
// YeshenSocGlue —— 本项目自研的胶合块（P1 的「外设端 + 装载链 + 内存主口汇聚」）
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
//
// ⚠️⚠️ 2026-10-07（VexiiRiscv 迁移）：上游从 `rtl/NaxSocMini.v` 换成 `rtl/vexiiriscv/VexiiRiscv.v`，
//   后者暴露**三个** AXI4 主口（FetchL1 只读 64bit / LsuL1 全功能 64bit / LsuCacheless 单拍 32bit），
//   且**全无 id 通道**（旧 mBus 的 awid/arid/bid/rid/awallStrb 都没了），aw/ar 反而**多了** cache/prot。
//   ⇒ 本模块的改动只落在三处，`§1–§4` 的胶合主体**逐字保留**：
//     · 端口层：移除 `pBus`/`cpuMem` 两个从口，改为 IO 之后的**内部线网**；
//       新增 `cpuFetch`/`cpuLsu`/`cpuIo`（从口）与 `rdtime`/`intMTime`/`intMSoft`/`intMExt`/`intSExt`/
//       `ethIrq`（时基/中断）。
//     · 适配层 C1（§3.5）：`cpuFetch`+`cpuLsu` ⇒ `cpuMem`（单 outstanding 仲裁，反"假装接受"）。
//     · 适配层 C2（§2c）：`cpuIo`（单拍 32bit）⇒ `pBus`（AXI4-Lite）。
//   另外：新核**没有内置** CLINT/PLIC ⇒ 由本模块内置（§2b 实例 + §3 解码），见 `ClintAlite`/`PlicAlite`。
//
// ⚠️⚠️ 2026-10-08（Y1-C2.2 NPU 并入）：把 Y1 自研小型 YuNet CNN 加速器（`y1/gen/NpuTop.v`）接进 SoC：
//     · 内存主口：新增输入 `npuMem`（`Flipped(new NpuAxi64)`，形状逐条取自 `NpuTop.v` 模块头）⇒
//       **汇入 §3.5 的同一个汇聚点**（`cpuMem` ← cpuFetch/cpuLsu/npuMem 三主），**不另造第二套仲裁**；
//       与 CPU 组之间由 §3.5 的**真仲裁器**（`MemArbiter`）按配额/优先级出授予（见 §3.5 的 ★ 仲裁面）。
//     · 寄存器窗：新增主口 `npuAxi`（`VexiiAxiLite32`，非 Flipped）⇒ §3 解码 `0xF000_C000`（16 KiB）。
//     · 中断：新增输入 `npuIrq` ⇒ PLIC **源 3**（见 PlicAlite）。
// ============================================================================

// ===================== 地址常量（与 spec §4.3 对齐）=====================
// ⚠️ 改这里的任何一个数都必须同步三处：DTS / OpenSBI `platform.c` / TF 卡装载表
//    （Task 9 的地址对账脚本守这条）。
object YeshenMap {
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
  // ⚠️⚠️ `buffer` 基址**必须按窗口大小对齐**（只用一个掩码译码）。
  //   2026-10-07：rx 槽 2→4 ⇒ 槽区 = rx 0x2000 + tx 0x1000 = **0x3000**，
  //   故窗口按 **0x4000** 对齐（`0xFFFF_C000`），覆盖 0x8000..0xBFFF。
  //   （dbg 窗在 0xB000，被这个掩码一并盖住 —— 它有自己的 `ETH_DBG_MASK` 译码，
  //     且 `board/liteeth_wrap.v` 内部把 `tgt_buf` 显式排除了 dbg，两边都自洽。）
  //   第一版写成 0xF000_5000（不是 0x2000 的整数倍）⇒ 掩码只盖住前 4 KB，**后 4 KB（tx 槽）
  //   落进"未解码"⇒ pBus 回 DECERR ⇒ CPU 上 `store access fault` ⇒ 内核 panic**。
  //   实测现场：`liteeth_start_xmit → memcpy_toio` 写物理 0xF0006000 挂掉（2026-10-06 仿真）。
  //   三处必须同步：本文件 / `board/liteeth_wrap.v` 的 localparam / DTS 的 reg 第 3 段。
  val ETH_BUF_BASE  = 0xF0008000L
  val ETH_MAC_MASK  = 0xFFFF_FF00L
  val ETH_MDIO_MASK = 0xFFFF_FF00L
  val ETH_BUF_MASK  = 0xFFFF_C000L
  // 只读调试观测窗口（2026-10-07，`board/liteeth_wrap.v` 的 `DBG_BASE`，移植自兄弟工程）：
  // 上板"eth0 起来、tx_packets 会涨但一个包不走、驱动打 `LITEETH_READER_READY not ready`"时，
  // 用它一次问完 **RXC 有没有在跳 / 内核有没写槽 / MAC 有没有发(tx_en) / PHY 有没收(rx_dv) / CSR 通不通**。
  // ⚠️ 这里**必须**加：否则 pBus 不把它路由给网口 ⇒ 读 0xF000B000 落到默认分支（读到 0/DECERR），
  //    窗口看着"存在"其实永远读不到（兄弟工程同一处也是这么加的）。
  val ETH_DBG_BASE  = 0xF000B000L
  val ETH_DBG_MASK  = 0xFFFF_FF00L
  // LiteEth 的中断位号（板级把 eth_irq 接到 ext_int 的**位 2** ⇒ PLIC 源 2）
  val ETH_IRQ_BIT = 2

  // ---- NPU（Y1 自研小型 YuNet CNN 加速器；2026-10-08 C2.2 并入）----
  // 寄存器窗（AxiLite4，16 KiB）：形态与 console/gpio/eth 一样由本模块解码、按窗口选通，
  // 下游是 `NpuTop` 的 `axilite_*` 从口。
  // ⚠️ 窗口选址（0xF000_x000 空间的空闲段盘点，逐条算过，不要随手改）：
  //   · 0x1000 控制台 / 0x2000 GPIO / 0x3000 ETH mac / 0x4000 ETH mdio
  //   · 0x8000–0xBFFF 被 **ETH buffer** 的 16 KiB 窗占住（`ETH_BUF_MASK = 0xFFFF_C000`，
  //     基址 0x8000）⇒ **0x9000 / 0xA000 落在 ETH buffer 窗内、不是空闲**（写错会静默进网口槽）。
  //   · 空闲段只有两处：**0x5000–0x7FFF** 与 **0xC000–0xFFFF**。
  //   ⇒ 取 0xC000（按 16 KiB 对齐，掩码 0xFFFF_C000 ⇒ 覆盖 0xC000–0xFFFF，恰好一段空闲区，不越界）。
  val NPU_BASE = 0xF000C000L
  val NPU_MASK = 0xFFFF_C000L
  // NPU 中断在 PLIC 上的源号（板级把 NpuTop.irq 接到本模块 `io.npuIrq` ⇒ PLIC **源 3**）。
  // ⚠️ 与 DTS 的 `interrupts = <3>` 必须一致（源 1=控制台、源 2=LiteEth、源 3=NPU）。
  val NPU_IRQ_BIT = 3

  // ---- DMA（Y1 通用 DMA 引擎；2026-10-13 DMA Phase-2b 并入）----
  // 寄存器窗（AxiLite4，**256 B**：2 通道×0x40 + 全局 0x80..0x93，见 `y1/rtl/DmaEngine.scala` §2）。
  // 形态与 NPU 窗一样由本模块解码、按窗口选通，下游是 `DmaEngine` 的 `axilite_*` 从口。
  // ⚠️ 窗口选址（0xF000_x000 空间的空闲段，逐条算过，不要随手改）：
  //   · 0x1000 控制台 / 0x2000 GPIO / 0x3000 ETH mac / 0x4000 ETH mdio（各 256 B 或 4 KB 页）
  //   · 0x8000–0xBFFF 被 **ETH buffer**（`ETH_BUF_MASK = 0xFFFF_C000`）占住；
  //   · 0xC000–0xFFFF 被 **NPU**（`NPU_MASK = 0xFFFF_C000`，16 KiB）占住；
  //   ⇒ 空闲段只剩 **0x5000–0x7FFF**（12 KiB）。取 **0x6000**：256 B 对齐，掩码 0xFFFF_FF00
  //     覆盖 0x6000–0x60FF，落在空闲段**正中**。**刻意避开 0x5000 与 0x7000** —— 这两个地址是既有
  //     装置（`sim/glue_pbus/tb_pbus.cpp` / `tb_npu_pbus.cpp`）用来探"未译码洞"的探针
  //     （0x5000 在 mdio 与 buf 之间、0x7000 在 buf 窗前），占了它们会把既有判据从绿变红。
  val DMA_BASE = 0xF0006000L
  val DMA_MASK = 0xFFFF_FF00L
  // DMA 中断在 PLIC 上的源号（板级把 `DmaEngine.irq` 接到本模块 `io.dmaIrq` ⇒ PLIC **源 4**）。
  // ⚠️ 与 DTS 的 `interrupts = <4>` 必须一致（源 1=控制台、源 2=LiteEth、源 3=NPU、源 4=DMA）。
  val DMA_IRQ_BIT = 4

  // ---- VIDEO（摄像头/叠加寄存器窗；2026-10-19）----
  // 0x5000–0x7FFF 空闲，但 0x5000/0x7000 是既有未译码洞探针（tb_pbus/tb_npu_pbus）
  // ⇒ 取 0x7400，1 KiB（掩码 0xFFFF_FC00），两端都避开探针。
  val VIDEO_BASE = 0xF0007400L
  val VIDEO_MASK = 0xFFFF_FC00L

  // ---- GPU（2026-10-31 GPU P1）----
  // spec 定案：CSR = 0xF000_5000、4 KiB（掩码 0xFFFF_F000）。
  val GPU_BASE = 0xF0005000L
  val GPU_MASK = 0xFFFF_F000L

  // ---- CLINT / PLIC（2026-10-07 VexiiRiscv 迁移）----
  // 新核没有内置 CLINT/PLIC ⇒ 改由本胶合块的两个外设实例提供（见 §2b/§3）。
  // 基址与板级 DTS / OpenSBI `platform.c` 的硬编码**逐字一致，不要改**：
  //   CLINT = 0xF001_0000（SiFive 布局：msip +0x0000 / mtimecmp +0x4000 / mtime +0xBFF8）
  //   PLIC  = 0xF0C0_0000（PLIC 1.0.0 布局，context base +0x200000）
  // 掩码取"该模块最大需要的偏移宽度"（与其它外设同款"页级/窗口级"表达）：
  //   CLINT 最大偏移 0xBFFC ⇒ 需 16 位偏移 ⇒ 64KB 窗口（掩码 0xFFFF_0000）；
  //   PLIC  最大偏移 0x201004 ⇒ 需 22 位偏移 ⇒ 4MB 窗口（掩码 0xFFC0_0000）。
  val CLINT_BASE = 0xF0010000L
  val CLINT_MASK = 0xFFFF_0000L
  val PLIC_BASE  = 0xF0C00000L
  val PLIC_MASK  = 0xFFC0_0000L
}

// ===================== 与 VexiiRiscv 三个 AXI4 主口逐字对应的端口 bundle =====================
// 方向以「CPU 自己」为视角（它驱动 = Output）⇒ 本模块用 `Flipped(...)` 接回来。
// 名字/位宽逐条取自 `rtl/vexiiriscv/VexiiRiscv.v` 的模块头（实测 dump，不是猜）。
// ⚠️ 新核与旧 NaxSocMini 的**关键差异（本 bundle 已照实修正）**：
//    · 全 AXI **没有任何 id 通道**（awid/arid/bid/rid 一气儿全无）⇒ 不再有 `awid`/`awallStrb`；
//    · `aw/ar` **带** `cache[3:0]` / `prot[2:0]`（旧模板没有）；
//    · 数据通道 **64bit**（`wdata`/`rdata` = 64、`wstrb` = 8bit）。

// LsuL1Axi4Plugin_logic_axi_*：AXI4 全功能、addr32、data64、无 id、带 cache/prot
class VexiiAxi64 extends Bundle {
  val awvalid = Output(Bool())
  val awready = Input(Bool())
  val awaddr  = Output(UInt(32.W))
  val awlen   = Output(UInt(8.W))
  val awsize  = Output(UInt(3.W))
  val awburst = Output(UInt(2.W))
  val awcache = Output(UInt(4.W))
  val awprot  = Output(UInt(3.W))

  val wvalid  = Output(Bool())
  val wready  = Input(Bool())
  val wdata   = Output(UInt(64.W))
  val wstrb   = Output(UInt(8.W))
  val wlast   = Output(Bool())

  val bvalid  = Input(Bool())
  val bready  = Output(Bool())
  val bresp   = Input(UInt(2.W))

  val arvalid = Output(Bool())
  val arready = Input(Bool())
  val araddr  = Output(UInt(32.W))
  val arlen   = Output(UInt(8.W))
  val arsize  = Output(UInt(3.W))
  val arburst = Output(UInt(2.W))
  val arcache = Output(UInt(4.W))
  val arprot  = Output(UInt(3.W))

  val rvalid  = Input(Bool())
  val rready  = Output(Bool())
  val rdata   = Input(UInt(64.W))
  val rresp   = Input(UInt(2.W))
  val rlast   = Input(Bool())
}

// FetchL1Axi4Plugin_logic_axi_*：AXI4 **只读**、addr32、data64、无 id、带 cache/prot
class VexiiAxiReadOnly64 extends Bundle {
  val arvalid = Output(Bool())
  val arready = Input(Bool())
  val araddr  = Output(UInt(32.W))
  val arlen   = Output(UInt(8.W))
  val arsize  = Output(UInt(3.W))
  val arburst = Output(UInt(2.W))
  val arcache = Output(UInt(4.W))
  val arprot  = Output(UInt(3.W))

  val rvalid  = Input(Bool())
  val rready  = Output(Bool())
  val rdata   = Input(UInt(64.W))
  val rresp   = Input(UInt(2.W))
  val rlast   = Input(Bool())
}

// LsuCachelessAxi4Plugin_logic_axi_*：AXI4 **单拍**（无 len / 无 burst）、addr32、data32、
// w 带 `last`、b/r 带 `resp`；aw/ar 带 size/cache/prot。
class VexiiAxi32 extends Bundle {
  val awvalid = Output(Bool())
  val awready = Input(Bool())
  val awaddr  = Output(UInt(32.W))
  val awsize  = Output(UInt(3.W))
  val awcache = Output(UInt(4.W))
  val awprot  = Output(UInt(3.W))

  val wvalid  = Output(Bool())
  val wready  = Input(Bool())
  val wdata   = Output(UInt(32.W))
  val wstrb   = Output(UInt(4.W))
  val wlast   = Output(Bool())

  val bvalid  = Input(Bool())
  val bready  = Output(Bool())
  val bresp   = Input(UInt(2.W))

  val arvalid = Output(Bool())
  val arready = Input(Bool())
  val araddr  = Output(UInt(32.W))
  val arsize  = Output(UInt(3.W))
  val arcache = Output(UInt(4.W))
  val arprot  = Output(UInt(3.W))

  val rvalid  = Input(Bool())
  val rready  = Output(Bool())
  val rdata   = Input(UInt(32.W))
  val rresp   = Input(UInt(2.W))
  val rlast   = Input(Bool())
}

class VexiiAxiLite32 extends Bundle {
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

// ===================== NPU 内存主口 bundle（2026-10-08 C2.2）=====================
// 方向以「NPU 自己」为视角（它驱动 = Output）⇒ 本模块用 `Flipped(...)` 接回来（与 cpuLsu 同款）。
// 形状 = SpinalHDL 生成的 `NpuTop.axi_*`（`y1/gen/NpuTop.v` 模块头，`DdrMasterConfig(ADDR_W=28,
// DATA_W=64, ID_W=4)`）。**逐条**取自网表头，不是猜：
//   · addr **28bit**（不是 32）：NPU 主口只覆盖低 28 位字节地址（`{base[27:5],5'h0}` ⇒ 32B 对齐）；
//   · aw/ar 带 **id 4bit**（`useId=true`）、带 cache[3:0] / prot[2:0]；
//   · **无** awlock/arlock（SpinalHDL `useLock=false` 生成时该通道被剪掉）；
//   · w **无** wid；b/r 带 id 4bit。
// 与胶合内 `AXIIO64`（io.mem）的差异及收敛见 §3.5 的"NPU 适配"注释（零扩展 addr、恒定 id/lock）。
class NpuAxi64(val ADDR_W: Int = 28) extends Bundle {
  // AW
  val awvalid = Output(Bool())
  val awready = Input(Bool())
  val awaddr  = Output(UInt(ADDR_W.W))
  val awid    = Output(UInt(4.W))
  val awlen   = Output(UInt(8.W))
  val awsize  = Output(UInt(3.W))
  val awburst = Output(UInt(2.W))
  val awcache = Output(UInt(4.W))
  val awprot  = Output(UInt(3.W))
  // W（无 wid）
  val wvalid  = Output(Bool())
  val wready  = Input(Bool())
  val wdata   = Output(UInt(64.W))
  val wstrb   = Output(UInt(8.W))
  val wlast   = Output(Bool())
  // B
  val bvalid  = Input(Bool())
  val bready  = Output(Bool())
  val bid     = Input(UInt(4.W))
  val bresp   = Input(UInt(2.W))
  // AR
  val arvalid = Output(Bool())
  val arready = Input(Bool())
  val araddr  = Output(UInt(ADDR_W.W))
  val arid    = Output(UInt(4.W))
  val arlen   = Output(UInt(8.W))
  val arsize  = Output(UInt(3.W))
  val arburst = Output(UInt(2.W))
  val arcache = Output(UInt(4.W))
  val arprot  = Output(UInt(3.W))
  // R
  val rvalid  = Input(Bool())
  val rready  = Output(Bool())
  val rdata   = Input(UInt(64.W))
  val rid     = Input(UInt(4.W))
  val rresp   = Input(UInt(2.W))
  val rlast   = Input(Bool())
}

// ===================== 胶合块 =====================
class YeshenSocGlue extends Module {
  override def desiredName = "YeshenSocGlue"

  val io = IO(new Bundle {
    // ---- 上游 CPU 的三个 AXI4 主口（本模块是从方 ⇒ Flipped）----
    val cpuFetch = Flipped(new VexiiAxiReadOnly64)  // FetchL1：I$ 重填（只读，64bit）
    val cpuLsu   = Flipped(new VexiiAxi64)          // LsuL1：D$ 重填/回写（全功能，64bit）
    val cpuIo    = Flipped(new VexiiAxi32)          // LsuCacheless：uncache MMIO（单拍，32bit）

    // ---- CPU 的时基/中断输入（本模块驱动）----
    val rdtime   = Output(UInt(64.W))   // ← CLINT mtime
    val intMTime = Output(Bool())       // ← CLINT mtip（M-timer）
    val intMSoft = Output(Bool())       // ← CLINT msip（M-software）
    val intMExt  = Output(Bool())       // ← PLIC ctx0 meip（M-external）
    val intSExt  = Output(Bool())       // ← PLIC ctx1 seip（S-external）

    // ---- LiteEth 网卡中断输入 ----
    // 板级从 `liteeth_wrap` 取 `eth_irq` 送进来 ⇒ 本模块内部 PLIC **源 2**。
    // ⚠️ 方向：板级是"产生方"，本模块是"消费方" ⇒ 这里是 **Input**（不是 Output）。
    val ethIrq = Input(Bool())

    // ---- NPU 中断输入（2026-10-08 C2.2；PLIC **源 3**）----
    // 板级把 `NpuTop.irq` 送进来 ⇒ 本模块内部 PLIC 源 3。方向与 ethIrq 同款：板级产生、本模块消费。
    // ⚠️ NPU 的 irq 是**保持电平**（完成/done 或 err 抬起，直到主机写 `CTRL.soft_reset` 清源）
    //    ⇒ 天然适配 PLIC 的"电平锁存成 pending + 读 claim 清源"网关（见 PlicAlite 文件头 ②）。
    val npuIrq = Input(Bool())

    // ---- DMA 中断输入（2026-10-13 DMA Phase-2b；PLIC **源 4**）----
    // 板级把 `DmaEngine.irq`（= `GBL_DONE|GBL_ERR` 的线或，电平保持）送进来 ⇒ 本模块内部 PLIC 源 4。
    // 方向与 ethIrq/npuIrq 同款：板级产生、本模块消费。中断是**电平保持**，主机写该通道 `CH_STATUS`
    // 的 w1c（bit0/1/2）清源 ⇒ 天然适配 PLIC 的"电平锁存成 pending + 读 claim 清源"网关。
    val dmaIrq = Input(Bool())

    // ---- GT911 电容触摸中断输入（2026-10-30 从 YeshenGuiTouch 搬入；PLIC **源 5**）----
    // 板级把 `ctp_irq`（= `ctp_int` 经 2FF 后**反相**，高有效）送进来 ⇒ 本模块内部 PLIC 源 5。
    // 方向同 ethIrq/npuIrq/dmaIrq：板级产生、本模块消费。GT911 的 INT 是脉冲式电平
    // （读 0x814E 后拉低）⇒ 天然适配"电平锁存成 pending + 读 claim 清源"网关。
    val ctpIrq = Input(Bool())

    // ---- NPU 内存主口（2026-10-08 C2.2）----
    // 形态与 `cpuLsu` 一样是"上游主口"（NPU 驱动、本模块作从方）⇒ Flipped。
    // 与 CPU 三条主口平级，**汇入同一个 §3.5 汇聚点**（不另造第二套仲裁），见 §3.5 的 NPU 适配注释。
    val npuMem = Flipped(new NpuAxi64)

    // ---- DMA 内存主口（2026-10-13 DMA Phase-2b）----
    // 形状与 `npuMem` **逐字相同**（28/64/4，带 id/cache/prot、无 lock）⇒ 复用同一个 `NpuAxi64` bundle
    // （Flipped ⇒ 本模块作从方）。汇入 §3.5 的**同一个**汇聚点（第 6 个主人），见那里的 DMA 适配注释。
    // ★ H2：DMA 主口放宽到 **30bit** 字节地址（1 GiB DDR 偏移）——相机帧存 0x9000_0000 在 28bit 之外。
    val dmaMem = Flipped(new NpuAxi64(30))

    // ---- 下游：内存主口（sim: tb 内存模型；板上: DDR3Bridge.axi）----
    // ⚠️ Task 17：`AXIIO`（32bit 数据）→ **`AXIIO64`**（64bit 数据 / 8bit wstrb，id 仍 4bit）。
    //    `AXIIO64` 定义在 `src/soc/DDR3Bridge.scala`（V1 的 64bit 从口形状）⇒ 两边**同一个类型**，
    //    板级装配时 `io_mem_*` 与 DDR3Bridge 的 `io_axi_*` 位宽逐条相等，**没有任何桥**。
    val mem = new AXIIO64

    // ---- 外设引脚 ----
    val uart_txd = Output(Bool())
    val uart_rxd = Input(Bool())
    val gpio_in  = Input(UInt(13.W))   // 0..7 = 板载 LED 观测位/输入；8..12 = CTP 四线 + KEY3（2026-10-30）
    val gpio_out = Output(UInt(13.W))
    val gpio_dir = Output(UInt(13.W))
    val irq      = Output(Bool())      // 控制台中断 ⇒ 板级接 externalInterrupts[CONSOLE_IRQ_BIT]

    // ---- LiteEth 网卡（2026-10-06）----
    // 形态与 console/gpio 完全一样：**本模块解码、按窗口选通**，下游是板级 `liteeth_wrap.v`
    // 里的 AXI-Lite→Wishbone 适配器（它再往 LiteEth MAC 的 CSR/槽 Wishbone 从口走）。
    // 三个窗口见 `YeshenMap` 的 ETH_*；IRQ 不走这里（板级直接从 liteeth_wrap 取 eth_irq 进 PLIC）。
    // ⚠️ **不加 `Flipped`**：本模块对它是**主方**（与 `pBus`/`cpuMem` 相反——那两路本模块是从方）。
    val ethAxi = new VexiiAxiLite32

    // ---- NPU 寄存器窗从口（2026-10-08 C2.2；窗口 `YeshenMap.NPU_BASE`）----
    // 形态与 `ethAxi` **逐字同款**：`VexiiAxiLite32`、**不加 Flipped**（本模块是主方），
    // 由 §3 的解码器按 `NPU_MASK` 选通后把**窗内相对偏移**（低 14 位，16 KiB 窗）给它
    // —— HostRegs 是基址 0 的从口，见 §3 的接线注释。
    val npuAxi = new VexiiAxiLite32

    // ---- DMA 寄存器窗从口（2026-10-13 DMA Phase-2b；窗口 `YeshenMap.DMA_BASE`）----
    // 形态与 `npuAxi` **逐字同款**：`VexiiAxiLite32`、**不加 Flipped**（本模块是主方），
    // 由 §3 的解码器按 `DMA_MASK` 选通后把**窗内相对偏移**（低 8 位，256 B 窗）给它
    // —— `DmaEngine` 的 `axilite` 是基址 0 的 `AxiLite4SlaveFactory` 从口，见 §3 的接线注释。
    val dmaAxi = new VexiiAxiLite32

    // ---- VIDEO 寄存器窗从口（形态与 npuAxi/dmaAxi 逐字同款；本模块是主方）----
    val videoAxi = new VexiiAxiLite32

    // ---- GPU（2026-10-31 GPU P1）----
    // gpuAxi：CSR 窗从口（0xF000_5000，4 KiB；本模块是主方，下游 = 板级 gpu_top 的 AXI-Lite 从口）
    // gpuMem：**第 4 个内存主口**（32-bit addr / 64-bit data，与 cpuMem 同形）⇒ 接 MemArbiter 第 4 组
    val gpuAxi = new VexiiAxiLite32
    val gpuMem = Flipped(new VexiiAxi64)

    // ---- 装载链（板上 strap + TF 卡引脚 + 装载期的 CPU 复位）----
    val loadMode   = Input(Bool())     // 板上接 KEY1：1 = 装载模式
    // ★ Y1-Boot：上电选择窗口的超时拍数（板级 100_000_000 = 1.0 s @100 MHz；装置可喂小值）
    val bootTimeout = Input(UInt(32.W))
    val loadActive = Output(Bool())    // 1 = 装载器正在当主人（CPU 被扣复位；观察/MUX 选择用）
    val sd_sck     = Output(Bool())
    val sd_mosi    = Output(Bool())
    val sd_miso    = Input(Bool())
    val sd_cs_n    = Output(Bool())
    val cpuReset   = Output(Bool())    // 1 = CPU 扣在复位（板级顶层 OR 进 NaxSocMini.asyncReset）

    // ---- ★ DMA 装载通路（Y1-DMA Phase-2c）：SD 装载器当**第一个真客户**去喂引擎 ----
    // `sdDmaMode=1` ⇒ 装载器不再自己举 AXI 写突发，改为：① 用**同一个** `io.dmaAxi` 主口编程引擎
    // 通道 0 的 CSR（装载期 CPU 被扣复位、pBus 结构性静默 ⇒ 这根主口交给装载器，见 §3 的选通）；
    // ② 把 32B 组拆成 4 拍 64bit 从 `dmaWr_*` 推给引擎的 `wr_stream`（板级接 `DmaEngine.wr_*_0`）。
    // ⚠️ 通道号分配（§4.4 的客户顺序 + 相机留口）：**ch0 = SD 装载器**、**ch1 = 网络（待接）**、
    //    ch2/ch3 = 相机留口（`DmaEngine.NCH` 上限 4；本相不动引擎）。
    val sdDmaMode  = Input(Bool())
    val dmaWrValid = Output(Bool())            // → DmaEngine.wr_valid_0
    val dmaWrData  = Output(UInt(64.W))        // → DmaEngine.wr_data_0
    val dmaWrReady = Input(Bool())             // ← DmaEngine.wr_ready_0

    // 诊断（SD 通路调试用）：SD 装载器的 io.state / io.errCode —— 板级把它塞进反向信道那条 NXB 帧，
    // 主机侧用 tshark 就能读（控制台在 loadActive=1 时是静默的，LED 又只能看 1 位）。
    val sd_state     = Output(UInt(4.W))
    val sd_err       = Output(UInt(4.W))
    val sd_dbg       = Output(UInt(32.W))
    val sd_dbg2      = Output(UInt(32.W))     // 诊断 2：SD 装载器的 AXI 突发通路（见 SdLoader 末尾位域）
  })

  // ------------------------------------------------------------------------
  // 内部线网：替代被移除的 `pBus` / `cpuMem` 端口
  // ------------------------------------------------------------------------
  // 方向以「上游 CPU」为视角（它驱动 = Output）⇒ 本模块作为从方，用 `Flipped(...)` 接出来。
  // 记忆点：这与旧模板里 `io.pBus` / `io.cpuMem` 那两个端口的**方向/视角逐字相同** ⇒ 下面
  // §1–§4 那 ~600 行胶合主体**一个字都不用改**（对 `pBus`/`cpuMem` 的读写语义完全不变）。
  // 这两个线网由新增的适配层（C1：§3.5 / C2：§2c）驱动/读取。
  private val cpuMem = Wire(Flipped(new VexiiAxi64))       // ← C1 汇聚 cpuFetch + cpuLsu
  private val pBus   = Wire(Flipped(new VexiiAxiLite32))   // ← C2 汇聚 cpuIo（单拍 32bit）

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
  // ★ 2026-10-25：改回 115200（54）。216（28.9k）是当年的速率实验，代价是 **SD 失败后**线路交给
  //   串口装载器时与 SD 报文器 / 内核 console（都 115200）不同档 ⇒ 无卡时串口是一片解不出的码。
  private val uartLoader = Module(new UartLoader(baudDiv = 54))    // 16*54 拍 @100MHz = 115.7 kbaud
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

  // ★ Y1-Boot：上电 1s 窗口的装载计划选择（UART：L=Linux / C=CoreMark，超时默认 Linux）。
  //   窗口内 CPU 仍扣复位、控制台 TX 归它发提示；选择定了且提示发完才放 SD 装载器。
  private val bootSel = Module(new BootSel())
  bootSel.io.active  := loadModeLatch
  bootSel.io.timeout := io.bootTimeout
  bootSel.io.rxd     := io.uart_rxd
  private val bootWait = loadModeLatch && !bootSel.io.lineFree

  private val sdDone     = sdLoader.io.released || sdLoader.io.state === 4.U
  private val sdEnable   = loadModeLatch && bootSel.io.lineFree && !sdDone
  // 串口回退：SD 失败后才上（原 ETH 那一级已随 D1 删除）
  private val uartEnable = loadModeLatch && sdLoader.io.state === 4.U && !uartLoader.io.released

  sdLoader.io.active   := sdEnable
  sdLoader.io.hdrSel   := bootSel.io.sel
  uartLoader.io.active := uartEnable

  // ★ Phase-2c：装载器 ↔ DMA 引擎的客户接线
  //   · `dmaMode`：strap（板上恒 1 = 走引擎；装置里可来回切，用来做"同一镜像两条通路逐字节相同"的 D3 判据）
  //   · 喂流：装载器的 `dbAct` 小 FSM 只在 `active && dmaMode` 时举 valid（见 `SdLoader` 的同名注释）
  sdLoader.io.dmaMode    := io.sdDmaMode
  sdLoader.io.dmaWrReady := io.dmaWrReady
  io.dmaWrValid          := sdLoader.io.dmaWrValid
  io.dmaWrData           := sdLoader.io.dmaWrData
  //   · CSR：装载器当主人时把 `io.dmaAxi`（同一根窗主口）让给它，见下面 §3 的 `io.dmaAxi` 选通。

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
  private val loadActive = bootWait || sdEnable || uartEnable
  io.loadActive := loadActive
  // 装载期把 CPU 扣在复位：装载器与 CPU 时间上互斥 ⇒ 内存主口只需选通（spec §4.1）。
  // ⚠️ 板级顶层把它 OR 进 `NaxSocMini.asyncReset`；**不要**把它接进本模块的 `reset`。
  io.cpuReset := loadActive

  // ========================================================================
  // 2) 外设：ns16550a 控制台 + GPIO + （新核缺的）CLINT / PLIC
  // ========================================================================
  // 控制台在装载期被扣复位（YeshenCore SoC.scala:369 同款）：装载器接管了同一根物理线，
  // 让 16550 停在复位态可以避免半截帧留下的脏字节。
  private val console = withReset(reset.asBool || loadActive) { Module(new Uart16550) }
  private val gpio    = Module(new GPIOController)
  // 2b) 新核（VexiiRiscv）**没有内置** CLINT / PLIC ⇒ 由本模块顶上：
  //   CLINT（ClintAlite）：自有 64bit 时基 + msip/mtimecmp ⇒ rdtime / mtip / msip；
  //   PLIC （PlicAlite） ：源1=控制台、源2=LiteEth、源3=NPU ⇒ meip / seip。
  //   两者在 pBus 上的解码见 §3。
  private val clint   = Module(new ClintAlite)
  private val plic    = Module(new PlicAlite)

  console.io.rxd := io.uart_rxd
  // 装载期控制台 TX 归装载器（否则两个主方往同一根线上灌字）；RX 两边都接（谁在用谁解释）。
  // 四级优先（高→低）：上电选择器提示（bootSel）→ SD 诊断报文器 → UART 装载器 → 16550 控制台。
  io.uart_txd := Mux(bootSel.io.owner, bootSel.io.txd,
                   Mux(sdReport.io.owner, sdReport.io.txd,
                     Mux(loadActive, uartLoader.io.txd, console.io.txd)))
  io.irq      := console.io.irq

  // ---- CLINT / PLIC 的时基与中断输出（⇒ 核的 rdtime / int_m_timer / int_m_software /
  //      int_m_external / int_s_external）----
  io.rdtime   := clint.io.rdtime_o
  io.intMTime := clint.io.mtip_o
  io.intMSoft := clint.io.msip_o
  io.intMExt  := plic.io.meip_o
  io.intSExt  := plic.io.seip_o
  // PLIC 源 1 = 控制台（`console.io.irq`）；源 2 = LiteEth（板级 eth_irq）；源 3 = NPU（板级 npu_irq）。
  // ⚠️ 源号必须与 DTS 的 `interrupts = <1>` / `<2>` / `<3>` 一致（控制台在前、eth 次之、NPU 最后）。
  plic.io.consoleIrq := console.io.irq
  plic.io.ethIrq     := io.ethIrq
  plic.io.npuIrq     := io.npuIrq
  plic.io.dmaIrq     := io.dmaIrq
  plic.io.ctpIrq     := io.ctpIrq    // 源 5：GT911（DTS `interrupts = <5>`）

  gpio.io.gpio_in := io.gpio_in.pad(32)   // 板上引 13 位 ⇒ 高 19 位恒 0
  io.gpio_out := gpio.io.gpio_out(12, 0)
  io.gpio_dir := gpio.io.gpio_dir(12, 0)
  // GPIO 的 `interrupt` 在 P1 不接线（只拿它的输出寄存器点灯/看状态）⇒ 留空，firtool 会剪掉。

  // ========================================================================
  // 2c) 外设主口汇聚（C2）：`cpuIo`（LsuCacheless，单拍 32bit）⇒ `pBus`（AXI4-Lite 32bit）
  // ========================================================================
  // LsuCachelessAxi4Plugin 是**单拍**通道：每笔写 = 1 拍 AW + 1 拍 W(+wlast) + 1 拍 B，
  // 每笔读 = 1 拍 AR + 1 拍 R(+rlast=T)。**没有 len/burst** ⇒ 无需任何突发处理，直通即可。
  //
  // ⚠️【纪律①在这里的落点：不得在"响应路由"之前消费掉一拍】
  //    pBus 的 `awaddr/araddr` 只在下游 `awready/arready` 握手拍保证有效 —— §3 的解码器正是在
  //    该握手拍把"这笔该由谁应答"锁存进 `rSel/wSel`（见 §3 的长注释）。这里把地址负载**直通**
  //    `pBus`，**不插入任何寄存器/缓冲**：地址相位与下游握手相位**逐拍一致** ⇒ 锁存点绝不会错。
  //    响应（B/R）也**直通**回 `cpuIo`：从方的 `bvalid/rvalid` 只在其自身握手成立后才 fire，
  //    因此一拍 W 绝不会在"对应的 B 已被路由"之前被吃掉；`w.last` 的单拍语义原样保留（见下，
  //    pBus 是 AXI4-Lite，无 wlast 概念，单拍天然成立）。
  pBus.awvalid  := io.cpuIo.awvalid
  pBus.awaddr   := io.cpuIo.awaddr
  pBus.awprot   := io.cpuIo.awprot                 // prot 直取（awsize/awcache 对本层无用）
  io.cpuIo.awready := pBus.awready

  pBus.wvalid   := io.cpuIo.wvalid                 // 单拍 ⇒ wlast 恒 1，AXI4-Lite 无该通道，直接丢弃
  pBus.wdata    := io.cpuIo.wdata
  pBus.wstrb    := io.cpuIo.wstrb
  io.cpuIo.wready := pBus.wready

  pBus.bready   := io.cpuIo.bready
  io.cpuIo.bvalid := pBus.bvalid
  io.cpuIo.bresp  := pBus.bresp

  pBus.arvalid  := io.cpuIo.arvalid
  pBus.araddr   := io.cpuIo.araddr
  pBus.arprot   := io.cpuIo.arprot                 // prot 直取（arsize/arcache 对本层无用）
  io.cpuIo.arready := pBus.arready

  pBus.rready   := io.cpuIo.rready
  io.cpuIo.rvalid := pBus.rvalid
  io.cpuIo.rdata  := pBus.rdata
  io.cpuIo.rresp  := pBus.rresp
  io.cpuIo.rlast  := true.B                        // 单拍 ⇒ R 的最后一拍恒真

  // ========================================================================
  // 3) 外设解码（pBus, AXI4-Lite）
  // ========================================================================
  // 与 `NaxYeshenSoC/src/NaxSoC.scala:385-560` 同一套写法：读用读地址、写用写地址，**不合并**。
  private val pR = pBus.araddr
  private val pW = pBus.awaddr

  private val isConsR = (pR & YeshenMap.CONSOLE_MASK.U) === YeshenMap.CONSOLE_BASE.U
  private val isGpioR = (pR & YeshenMap.GPIO_MASK.U)    === YeshenMap.GPIO_BASE.U
  private val isConsW = (pW & YeshenMap.CONSOLE_MASK.U) === YeshenMap.CONSOLE_BASE.U
  private val isGpioW = (pW & YeshenMap.GPIO_MASK.U)    === YeshenMap.GPIO_BASE.U
  // LiteEth：三个窗口**合并**成一个选通（细分交给 liteeth_wrap 的适配器，见那里的文件头）。
  // ⚠️ 这里必须用**各自**的掩码：mac/mdio 各 0x100、buffer 0x2000（0x5000+0x2000 = 0x7000，
  //    仍在 pBus 的 16 KiB 外设区 0xF000_0000–0xF000_FFFF 里）。
  private val isEthR = ((pR & YeshenMap.ETH_MAC_MASK.U)  === YeshenMap.ETH_MAC_BASE.U)  ||
                       ((pR & YeshenMap.ETH_MDIO_MASK.U) === YeshenMap.ETH_MDIO_BASE.U) ||
                       ((pR & YeshenMap.ETH_BUF_MASK.U)  === YeshenMap.ETH_BUF_BASE.U)  ||
                       ((pR & YeshenMap.ETH_DBG_MASK.U)  === YeshenMap.ETH_DBG_BASE.U)
  private val isEthW = ((pW & YeshenMap.ETH_MAC_MASK.U)  === YeshenMap.ETH_MAC_BASE.U)  ||
                       ((pW & YeshenMap.ETH_MDIO_MASK.U) === YeshenMap.ETH_MDIO_BASE.U) ||
                       ((pW & YeshenMap.ETH_BUF_MASK.U)  === YeshenMap.ETH_BUF_BASE.U)  ||
                       ((pW & YeshenMap.ETH_DBG_MASK.U)  === YeshenMap.ETH_DBG_BASE.U)

  // CLINT / PLIC（新核缺的外设；基址/掩码见 YeshenMap）：同款"读用读地址、写用写地址，不合并"。
  // ⚠️ 两个掩码与 §2b 实例的端口宽度对齐：CLINT 16 位偏移、PLIC 22 位偏移。
  private val isClintR = (pR & YeshenMap.CLINT_MASK.U) === YeshenMap.CLINT_BASE.U
  private val isClintW = (pW & YeshenMap.CLINT_MASK.U) === YeshenMap.CLINT_BASE.U
  private val isPlicR  = (pR & YeshenMap.PLIC_MASK.U)  === YeshenMap.PLIC_BASE.U
  private val isPlicW  = (pW & YeshenMap.PLIC_MASK.U)  === YeshenMap.PLIC_BASE.U

  // NPU 寄存器窗（2026-10-08 C2.2；16 KiB 窗 @ 0xF000_C000，见 `YeshenMap.NPU_*` 的选址注释）。
  // 同款"读用读地址、写用写地址，不合并"；与 `isEth*` 一样是**单个窗口一个掩码**（NPU 内部再取低偏移）。
  private val isNpuR = (pR & YeshenMap.NPU_MASK.U) === YeshenMap.NPU_BASE.U
  private val isNpuW = (pW & YeshenMap.NPU_MASK.U) === YeshenMap.NPU_BASE.U

  // DMA 寄存器窗（2026-10-13 DMA Phase-2b；**256 B** 窗 @ 0xF000_6000，见 `YeshenMap.DMA_*` 的选址注释）。
  // 同款"读用读地址、写用写地址，不合并"；单个窗口一个掩码（`DMA_MASK = 0xFFFF_FF00`）。
  private val isDmaR = (pR & YeshenMap.DMA_MASK.U) === YeshenMap.DMA_BASE.U
  private val isDmaW = (pW & YeshenMap.DMA_MASK.U) === YeshenMap.DMA_BASE.U

  // VIDEO 寄存器窗（2026-10-19 V1-T6；**1 KiB** 窗 @ 0xF000_7400，见 `YeshenMap.VIDEO_*` 的选址注释）。
  // 同款"读用读地址、写用写地址，不合并"；单个窗口一个掩码（`VIDEO_MASK = 0xFFFF_FC00`）。
  private val isVideoR = (pR & YeshenMap.VIDEO_MASK.U) === YeshenMap.VIDEO_BASE.U
  private val isVideoW = (pW & YeshenMap.VIDEO_MASK.U) === YeshenMap.VIDEO_BASE.U

  // GPU 寄存器窗（2026-10-31；**4 KiB** 窗 @ 0xF000_5000，掩码 0xFFFF_F000）。
  private val isGpuR = (pR & YeshenMap.GPU_MASK.U) === YeshenMap.GPU_BASE.U
  private val isGpuW = (pW & YeshenMap.GPU_MASK.U) === YeshenMap.GPU_BASE.U

  // 两个外设都是"8 个 32bit 寄存器"（偏移低 5 位），与复制进来的源码逐字一致。
  console.io.axi.awaddr  := pW(4, 0)
  console.io.axi.awvalid := pBus.awvalid && isConsW
  console.io.axi.wdata   := pBus.wdata
  console.io.axi.wstrb   := pBus.wstrb
  console.io.axi.wvalid  := pBus.wvalid && isConsW
  console.io.axi.bready  := pBus.bready
  console.io.axi.araddr  := pR(4, 0)
  console.io.axi.arvalid := pBus.arvalid && isConsR
  console.io.axi.rready  := pBus.rready

  gpio.io.axi.awaddr  := pW(4, 0)
  gpio.io.axi.awvalid := pBus.awvalid && isGpioW
  gpio.io.axi.wdata   := pBus.wdata
  gpio.io.axi.wstrb   := pBus.wstrb
  gpio.io.axi.wvalid  := pBus.wvalid && isGpioW
  gpio.io.axi.bready  := pBus.bready
  gpio.io.axi.araddr  := pR(4, 0)
  gpio.io.axi.arvalid := pBus.arvalid && isGpioR
  gpio.io.axi.rready  := pBus.rready

  // LiteEth：地址**整根**给它（三个窗口由它自己再分），valid 按合并后的窗口选通。
  io.ethAxi.awaddr  := pW
  io.ethAxi.awprot  := pBus.awprot
  io.ethAxi.awvalid := pBus.awvalid && isEthW
  io.ethAxi.wdata   := pBus.wdata
  io.ethAxi.wstrb   := pBus.wstrb
  io.ethAxi.wvalid  := pBus.wvalid && isEthW
  io.ethAxi.bready  := pBus.bready
  io.ethAxi.araddr  := pR
  io.ethAxi.arprot  := pBus.arprot
  io.ethAxi.arvalid := pBus.arvalid && isEthR
  io.ethAxi.rready  := pBus.rready

  // CLINT / PLIC：把**相对偏移**喂给各自实例（宽度对齐：CLINT 16 位 / PLIC 22 位）。
  clint.io.axi.awaddr  := pW(15, 0)
  clint.io.axi.awvalid := pBus.awvalid && isClintW
  clint.io.axi.wdata   := pBus.wdata
  clint.io.axi.wstrb   := pBus.wstrb
  clint.io.axi.wvalid  := pBus.wvalid && isClintW
  clint.io.axi.bready  := pBus.bready
  clint.io.axi.araddr  := pR(15, 0)
  clint.io.axi.arvalid := pBus.arvalid && isClintR
  clint.io.axi.rready  := pBus.rready

  plic.io.axi.awaddr  := pW(21, 0)
  plic.io.axi.awvalid := pBus.awvalid && isPlicW
  plic.io.axi.wdata   := pBus.wdata
  plic.io.axi.wstrb   := pBus.wstrb
  plic.io.axi.wvalid  := pBus.wvalid && isPlicW
  plic.io.axi.bready  := pBus.bready
  plic.io.axi.araddr  := pR(21, 0)
  plic.io.axi.arvalid := pBus.arvalid && isPlicR
  plic.io.axi.rready  := pBus.rready

  // NPU 寄存器窗：与 console/gpio/CLINT/PLIC 同款——给它**窗内相对偏移**（低 14 位 = 16 KiB 窗），
  // ⚠️ 复用件的硬要求：`NpuTop` 的 HostRegs 是**基址 0** 的 `AxiLite4SlaveFactory` 从口
  //    （`addr & ~3` 直接对 0x00..0x38），它**不知道** SoC 基址 ⇒ 必须喂窗内偏移；直给整根
  //    SoC 地址（0xF000_C038）会永不命中（读回 0 / 写被静默丢弃）。16 KiB 窗 ⇒ 14 位偏移
  //    （`NPU_MASK = 0xFFFF_C000` 只比到 bit14）。valid 按 16 KiB 窗口选通。`wstrb` 4bit /
  //    `data` 32bit / 带 `prot`，与 `VexiiAxiLite32` 逐条对齐。
  io.npuAxi.awaddr  := pW(13, 0)
  io.npuAxi.awprot  := pBus.awprot
  io.npuAxi.awvalid := pBus.awvalid && isNpuW
  io.npuAxi.wdata   := pBus.wdata
  io.npuAxi.wstrb   := pBus.wstrb
  io.npuAxi.wvalid  := pBus.wvalid && isNpuW
  io.npuAxi.bready  := pBus.bready
  io.npuAxi.araddr  := pR(13, 0)
  io.npuAxi.arprot  := pBus.arprot
  io.npuAxi.arvalid := pBus.arvalid && isNpuR
  io.npuAxi.rready  := pBus.rready

  // DMA 寄存器窗：与 NPU 同款——给它**窗内相对偏移**（低 8 位 = 256 B 窗）。
  // ⚠️ `DmaEngine` 的 `axilite` 是**基址 0** 的 `AxiLite4SlaveFactory` 从口（CSR 偏移 0x00..0x93 在窗内）
  //    ⇒ 必须喂窗内偏移；直给整根 SoC 地址（0xF000_5004）会永不命中。256 B 窗 ⇒ 8 位偏移
  //    （`DMA_MASK = 0xFFFF_FF00` 只比到 bit8）。valid 按 256 B 窗口选通。
  // ★★ Phase-2c：这根窗主口有**两个主人**，按时间互斥选通（与 §4 的 `memSel` 同一条纪律）：
  //    · 平时 = CPU 的 pBus（`selDma` 窗口解码路）；
  //    · **装载期**（`sdEnable` 且 strap `sdDmaMode=1`）= SD 装载器的 CSR 小主口
  //      —— 此刻 CPU 被扣复位（`io.cpuReset`）⇒ pBus 结构性静默，两方**不可能同时在飞**。
  //    ⚠️ 选通必须带 `sdEnable`（不是只看 strap）：否则非装载期装载器的恒 0 valid 会把 CPU 的窗读**闷死**。
  private val sdDmaCsr = sdEnable && io.sdDmaMode
  io.dmaAxi.awaddr  := Mux(sdDmaCsr, sdLoader.io.dmaCsrAwAddr, pW(7, 0))
  io.dmaAxi.awprot  := Mux(sdDmaCsr, 0.U(3.W), pBus.awprot)
  io.dmaAxi.awvalid := Mux(sdDmaCsr, sdLoader.io.dmaCsrAwValid, pBus.awvalid && isDmaW)
  io.dmaAxi.wdata   := Mux(sdDmaCsr, sdLoader.io.dmaCsrWData, pBus.wdata)
  io.dmaAxi.wstrb   := Mux(sdDmaCsr, 15.U(4.W), pBus.wstrb)
  io.dmaAxi.wvalid  := Mux(sdDmaCsr, sdLoader.io.dmaCsrWValid, pBus.wvalid && isDmaW)
  io.dmaAxi.bready  := Mux(sdDmaCsr, sdLoader.io.dmaCsrBReady, pBus.bready)
  io.dmaAxi.araddr  := Mux(sdDmaCsr, sdLoader.io.dmaCsrArAddr, pR(7, 0))
  io.dmaAxi.arprot  := Mux(sdDmaCsr, 0.U(3.W), pBus.arprot)
  io.dmaAxi.arvalid := Mux(sdDmaCsr, sdLoader.io.dmaCsrArValid, pBus.arvalid && isDmaR)
  io.dmaAxi.rready  := Mux(sdDmaCsr, sdLoader.io.dmaCsrRReady, pBus.rready)
  // 回程只给当拍被授权的那一方（未授权方的 ready 恒 0 ⇒ 不会误吞响应）
  sdLoader.io.dmaCsrAwReady := io.dmaAxi.awready && sdDmaCsr
  sdLoader.io.dmaCsrWReady  := io.dmaAxi.wready  && sdDmaCsr
  sdLoader.io.dmaCsrBValid  := io.dmaAxi.bvalid  && sdDmaCsr
  sdLoader.io.dmaCsrBResp   := io.dmaAxi.bresp
  sdLoader.io.dmaCsrArReady := io.dmaAxi.arready && sdDmaCsr
  sdLoader.io.dmaCsrRValid  := io.dmaAxi.rvalid  && sdDmaCsr
  sdLoader.io.dmaCsrRData   := io.dmaAxi.rdata
  sdLoader.io.dmaCsrRResp   := io.dmaAxi.rresp

  // VIDEO 寄存器窗：与 NPU 同款——给它**窗内相对偏移**（低 10 位 = 1 KiB 窗）。
  // ⚠️ 下游 `board/cam/video_regs.v` 是**窗内偏移**从口（`s_awaddr[11:0]`/`s_araddr[11:0]`，
  //    寄存器偏移 0x000..0x08F）⇒ 必须喂窗内偏移；直给整根 SoC 地址（0xF000_7404）会永不命中。
  //    1 KiB 窗 ⇒ 10 位偏移（`VIDEO_MASK = 0xFFFF_FC00` 只比到 bit10）。valid 按 1 KiB 窗口选通。
  io.videoAxi.awaddr  := pW(9, 0)
  io.videoAxi.awprot  := pBus.awprot
  io.videoAxi.awvalid := pBus.awvalid && isVideoW
  io.videoAxi.wdata   := pBus.wdata
  io.videoAxi.wstrb   := pBus.wstrb
  io.videoAxi.wvalid  := pBus.wvalid && isVideoW
  io.videoAxi.bready  := pBus.bready
  io.videoAxi.araddr  := pR(9, 0)
  io.videoAxi.arprot  := pBus.arprot
  io.videoAxi.arvalid := pBus.arvalid && isVideoR
  io.videoAxi.rready  := pBus.rready

  // GPU：地址整根给窗内 12 位（4 KiB），valid 按 isGpu 选通。
  io.gpuAxi.awaddr  := pW(11, 0)
  io.gpuAxi.awprot  := pBus.awprot
  io.gpuAxi.awvalid := pBus.awvalid && isGpuW
  io.gpuAxi.wdata   := pBus.wdata
  io.gpuAxi.wstrb   := pBus.wstrb
  io.gpuAxi.wvalid  := pBus.wvalid && isGpuW
  io.gpuAxi.bready  := pBus.bready
  io.gpuAxi.araddr  := pR(11, 0)
  io.gpuAxi.arprot  := pBus.arprot
  io.gpuAxi.arvalid := pBus.arvalid && isGpuR
  io.gpuAxi.rready  := pBus.rready

  // ⚠️【纪律①：响应来源必须在握手拍锁存】——照抄 `NaxYeshenSoC/src/NaxSoC.scala:463-465`：
  //    AXI-Lite 的地址负载**只在 `arready/awready` 握手拍保证有效**（SpinalHDL 的 Stream 语义：
  //    fire 之后对端即可更换 payload）⇒ 必须把"这一笔该由谁应答"在握手拍锁存成寄存器。
  //    踩过的症状：核写外设寄存器后读回时挂死（响应被路由到默认分支）。
  // ⚠️ 位宽：窗口数到 8（VIDEO）⇒ 选择码必须 **4 位**（3 位装不下 8.U）。
  private val selNone  = 0.U(4.W)
  private val selCons  = 1.U(4.W)
  private val selGpio  = 2.U(4.W)
  private val selEth   = 3.U(4.W)
  private val selClint = 4.U(4.W)
  private val selPlic  = 5.U(4.W)
  private val selNpu   = 6.U(4.W)   // 2026-10-08 C2.2：NPU 寄存器窗（0xF000_C000）
  private val selDma   = 7.U(4.W)   // 2026-10-13 DMA Phase-2b：DMA 寄存器窗（0xF000_6000）
  private val selVideo = 8.U(4.W)   // 2026-10-19 V1-T6：VIDEO 寄存器窗（0xF000_7400）
  private val selGpu   = 9.U(4.W)   // 2026-10-31 GPU P1：GPU 寄存器窗（0xF000_5000）

  private val rLive = MuxCase(selNone, Seq(isConsR -> selCons, isGpioR -> selGpio, isEthR -> selEth,
                                           isClintR -> selClint, isPlicR -> selPlic, isNpuR -> selNpu,
                                           isDmaR -> selDma, isVideoR -> selVideo,
                                           isGpuR -> selGpu))
  private val wLive = MuxCase(selNone, Seq(isConsW -> selCons, isGpioW -> selGpio, isEthW -> selEth,
                                           isClintW -> selClint, isPlicW -> selPlic, isNpuW -> selNpu,
                                           isDmaW -> selDma, isVideoW -> selVideo,
                                           isGpuW -> selGpu))

  private val rSel = RegInit(selNone)
  private val wSel = RegInit(selNone)
  when(pBus.arvalid && pBus.arready) { rSel := rLive }
  when(pBus.rvalid && pBus.rready)   { rSel := selNone }
  when(pBus.awvalid && pBus.awready) { wSel := wLive }
  when(pBus.bvalid && pBus.bready)   { wSel := selNone }
  // ⚠️ 上面两对的顺序（先锁存、后清零）依赖"**pBus 主方不流水**"这一前提：NaxRiscv 的 uncache
  //    通路是**阻塞式**（一笔 R 收完才发下一笔 AR），所以"同拍 AR 握手 + 末拍 R fire"不会发生。
  //    若将来换成会这样流水的主方，这两处的优先级要显式写清（同拍清零会把新事务的响应
  //    路由到默认分支 ⇒ 挂死）。

  // 未解码的 uncache 访问：先接受命令、下一拍以 **DECERR** 应答（spec：其余地址给错误响应）。
  // ⚠️ 必须应答而不是放行 —— NaxRiscv 的 uncache 通路是**阻塞式**（等到 rsp 才放行），
  //    无人应答就是永久挂死（与 NaxYeshenSoC 同款，彼处回 OKAY，本处回 DECERR）。
  private val undecRPend = RegInit(false.B)
  private val undecWPend = RegInit(false.B)

  pBus.arready := MuxCase(true.B, Seq(
    isConsR  -> console.io.axi.arready,
    isGpioR  -> gpio.io.axi.arready,
    isEthR   -> io.ethAxi.arready,
    isClintR -> clint.io.axi.arready,
    isPlicR  -> plic.io.axi.arready,
    isNpuR   -> io.npuAxi.arready,
    isDmaR   -> io.dmaAxi.arready,
    isVideoR -> io.videoAxi.arready,
    isGpuR   -> io.gpuAxi.arready
  ))
  pBus.awready := MuxCase(true.B, Seq(
    isConsW  -> console.io.axi.awready,
    isGpioW  -> gpio.io.axi.awready,
    isEthW   -> io.ethAxi.awready,
    isClintW -> clint.io.axi.awready,
    isPlicW  -> plic.io.axi.awready,
    isNpuW   -> io.npuAxi.awready,
    isDmaW   -> io.dmaAxi.awready,
    isVideoW -> io.videoAxi.awready,
    isGpuW   -> io.gpuAxi.awready
  ))
  pBus.wready := MuxCase(true.B, Seq(
    isConsW  -> console.io.axi.wready,
    isGpioW  -> gpio.io.axi.wready,
    isEthW   -> io.ethAxi.wready,
    isClintW -> clint.io.axi.wready,
    isPlicW  -> plic.io.axi.wready,
    isNpuW   -> io.npuAxi.wready,
    isDmaW   -> io.dmaAxi.wready,
    isVideoW -> io.videoAxi.wready,
    isGpuW   -> io.gpuAxi.wready
  ))

  pBus.rvalid := MuxLookup(rSel, undecRPend)(Seq(
    selCons  -> console.io.axi.rvalid,
    selGpio  -> gpio.io.axi.rvalid,
    selEth   -> io.ethAxi.rvalid,
    selClint -> clint.io.axi.rvalid,
    selPlic  -> plic.io.axi.rvalid,
    selNpu   -> io.npuAxi.rvalid,
    selDma   -> io.dmaAxi.rvalid,
    selVideo -> io.videoAxi.rvalid,
    selGpu   -> io.gpuAxi.rvalid
  ))
  pBus.rdata := MuxLookup(rSel, 0.U)(Seq(
    selCons  -> console.io.axi.rdata,
    selGpio  -> gpio.io.axi.rdata,
    selEth   -> io.ethAxi.rdata,
    selClint -> clint.io.axi.rdata,
    selPlic  -> plic.io.axi.rdata,
    selNpu   -> io.npuAxi.rdata,
    selDma   -> io.dmaAxi.rdata,
    selVideo -> io.videoAxi.rdata,
    selGpu   -> io.gpuAxi.rdata
  ))
  pBus.rresp := MuxLookup(rSel, "b11".U)(Seq(   // 默认分支 = 未解码 ⇒ DECERR
    selCons  -> console.io.axi.rresp,
    selGpio  -> gpio.io.axi.rresp,
    selEth   -> io.ethAxi.rresp,
    selClint -> clint.io.axi.rresp,
    selPlic  -> plic.io.axi.rresp,
    selNpu   -> io.npuAxi.rresp,
    selDma   -> io.dmaAxi.rresp,
    selVideo -> io.videoAxi.rresp,
    selGpu   -> io.gpuAxi.rresp
  ))
  pBus.bvalid := MuxLookup(wSel, undecWPend)(Seq(
    selCons  -> console.io.axi.bvalid,
    selGpio  -> gpio.io.axi.bvalid,
    selEth   -> io.ethAxi.bvalid,
    selClint -> clint.io.axi.bvalid,
    selPlic  -> plic.io.axi.bvalid,
    selNpu   -> io.npuAxi.bvalid,
    selDma   -> io.dmaAxi.bvalid,
    selVideo -> io.videoAxi.bvalid,
    selGpu   -> io.gpuAxi.bvalid
  ))
  pBus.bresp := MuxLookup(wSel, "b11".U)(Seq(   // 默认分支 = 未解码 ⇒ DECERR
    selCons  -> console.io.axi.bresp,
    selGpio  -> gpio.io.axi.bresp,
    selEth   -> io.ethAxi.bresp,
    selClint -> clint.io.axi.bresp,
    selPlic  -> plic.io.axi.bresp,
    selNpu   -> io.npuAxi.bresp,
    selDma   -> io.dmaAxi.bresp,
    selVideo -> io.videoAxi.bresp,
    selGpu   -> io.gpuAxi.bresp
  ))

  when(pBus.arvalid && pBus.arready && rLive === selNone) { undecRPend := true.B }
  when(pBus.rvalid && pBus.rready)                        { undecRPend := false.B }
  when(pBus.awvalid && pBus.awready && wLive === selNone) { undecWPend := true.B }
  when(pBus.bvalid && pBus.bready)                        { undecWPend := false.B }

  // ========================================================================
  // 3.5) 内存主口汇聚（C1 + 2026-10-08 NPU）：`cpuFetch` + `cpuLsu` + `npuMem` ⇒ `cpuMem`
  // ========================================================================
  // 新核暴露**三个** AXI4 主口（FetchL1 只读 / LsuL1 全功能 / LsuCacheless 单拍），下游
  // `DDR3Bridge` 只有**一个**单 outstanding 的从口。NPU（Y1 自研 CNN 加速器）也是同一根
  // 内存主口的**第四个主方**（它是一个 DDR 块搬运引擎，读写都要走桥）⇒ 这里把它与 CPU 的
  // 前两个内存主口**合并进同一个** `cpuMem`（`LsuCacheless` 走外设那条路，见 §2c）。
  //  **不另造第二套仲裁**：NPU 只是这个汇聚点上的一个新 `owner`，纪律一字不放松。
  //
  // 仲裁纪律（与 §4 模板里 `memRdBusy` 的"反假装接受"同源，见 `src/NaxMiniGlue.scala:406-484`）：
  //  · **同一时刻只有一个主方**：用 `owner` 登记当前被授予的主方，**持有授权**直到
  //    读突发收完（`r.last` fire）或写完成（`b` fire）；★ L2b：读主人可连发多笔 AR ⇒ 保持到**末笔** `rlast`（`rdOut` 计数），写仍一笔一授权。
  //  · ⚠️**绝不**用"掩掉自己的 valid、却把下游 ready 直通给主方"来表达背压 —— 主方的
  //    `Axi4Bridge` 判据是 `valid && ready`，那样写会让主方以为命令**已成交**且**永不重发**。
  //    这里只用**标准 AXI 背压**：不该收的那一拍，**既不向主方回告 ready**（主方保持 valid+payload），
  //    **又不向下游摆 valid**（从方看不到"假装的一拍"）。两个半门**必须成对**。
  //  · CPU 组内：读：LSU 优先、退到 Fetch；写：**只可能**来自 LSU（Fetch 只读）。
  //  · NPU：读写都可能有（DdrMaster 是"先读一段、再写一段"的块搬运）⇒ 单独两个 owner 态。
  //
  // ★ 仲裁面（**Y1-DMA Phase-1 换成真仲裁器**；2026-10-13）：
  //   改前是"CPU 组 vs NPU 两方轮转"（`npuTurn` 一位 + 组内固定优先级）。本轮把**主人选择**
  //   整段交给 `src/soc/MemArbiter.scala` 的**真仲裁器**（纯调度逻辑，见该文件头）：
  //     · **类**（class）是仲裁单元：类 0 = CPU 组（`cpuLsu`/`cpuFetch`），类 1 = NPU，
  //       类 2 = **DMA（Phase-2 预留，本相 `req` 钉 0、但配额位已预置）**；
  //     · **配额**：`ARB_WEIGHTS`（加权轮转）—— 持续争用时按权重比出授予（默认 2:1:1 =
  //       spec §6 R2 要的"CPU 组 > NPU > DMA"）；
  //     · **防饿死**：老化提升（授权机会口径，`ARB_AGE_MAX`）—— 低优先类不会无界等待。
  //     · **类内固定优先级原样保留**（CPU 组：LSU 写 > LSU 读 > Fetch 读；NPU：写 > 读）。
  //   ⇒ 加 Phase-2 的第 6 个主人（DMA 引擎）= 把它的 `awvalid/arvalid` 接到 `dmaPend`、
  //     并加两个 owner 态（`OWN_DMA_*`，本相已留好）——**仲裁器一字不改**（`MemArbiter` 的 N/权重都是参数）。
  //   ⚠️ 纪律：**同一时刻只有一个主方在飞**；读主人可有多笔 AR 在飞（保持到末笔 `rlast`，L2b），
  //     写仍是一笔一授权；读写的两个半门成对（见 §4 的 【纪律②】注释）、NPU 的 28→32bit 零扩展与 id 丢弃照旧。
  //
  // ⚠️ **owner 位宽由 3 位加宽到 4 位**（Phase-2 要 8 个态：IDLE + (CPU/NPU/DMA) × (读/写) + 1 备用）。
  //    3 位本来也正好够 8 个态，但 4 位留出"多通道 DMA"的余地，且比较式更直白。

  // ★ 仲裁参数（本相冻结）—— 负对照 `sim/glue_pbus/negctl_memmerge.sh` 打的就是 `ARB_WEIGHTS` 那一行。
  private val ARB_WEIGHTS = Seq(2, 1, 1, 1)   // 类 0 CPU 组 / 类 1 NPU / 类 2 DMA / 类 3 GPU（2026-10-31）
  private val ARB_AGE_MAX = 32             // 老化阈值（"错过多少次授权机会"后强制当选）

  private val OWN_IDLE     = 0.U(4.W)
  private val OWN_FETCH_RD = 1.U(4.W)
  private val OWN_LSU_RD   = 2.U(4.W)
  private val OWN_LSU_WR   = 3.U(4.W)
  private val OWN_NPU_RD   = 4.U(4.W)
  private val OWN_NPU_WR   = 5.U(4.W)
  private val OWN_DMA_RD   = 6.U(4.W)      // Phase-2：DMA 引擎读
  private val OWN_DMA_WR   = 7.U(4.W)      // Phase-2：DMA 引擎写
  private val OWN_GPU_RD   = 8.U(4.W)      // 2026-10-31 GPU P1：GPU 读
  private val OWN_GPU_WR   = 9.U(4.W)      // 2026-10-31 GPU P1：GPU 写
  private val owner = RegInit(OWN_IDLE)

  private val fetchRd = owner === OWN_FETCH_RD
  private val lsuRd   = owner === OWN_LSU_RD
  private val lsuWr   = owner === OWN_LSU_WR
  private val npuRd   = owner === OWN_NPU_RD
  private val npuWr   = owner === OWN_NPU_WR
  private val dmaRd   = owner === OWN_DMA_RD
  private val dmaWr   = owner === OWN_DMA_WR
  private val gpuRd   = owner === OWN_GPU_RD
  private val gpuWr   = owner === OWN_GPU_WR
  /** L2b：当前读主人**已发 AR、尚未收 rlast**的笔数（0..4）。
    * CPU/DMA 的通道仍是单笔在飞 ⇒ 恒 0/1；NPU 的块槽预取会在授权期内连发 2..4 笔 AR，
    * 因此**授权必须保持到末笔 rlast**（旧纪律"首笔 rlast 即释放"只对单笔主人等价）。 */
  private val rdOut   = RegInit(0.U(4.W))

  // ---- 真仲裁器实例（合并点的主人选择器）----
  private val arb = Module(new MemArbiter(4, ARB_WEIGHTS, ARB_AGE_MAX))
  private val cpuPend = io.cpuLsu.awvalid || io.cpuLsu.arvalid || io.cpuFetch.arvalid
  private val npuPend = io.npuMem.awvalid || io.npuMem.arvalid
  private val dmaPend = io.dmaMem.awvalid || io.dmaMem.arvalid   // 第 6 个主人（DMA 引擎）
  private val gpuPend = io.gpuMem.awvalid || io.gpuMem.arvalid   // 第 7 个主人（GPU，2026-10-31）
  arb.io.req(0) := cpuPend
  arb.io.req(1) := npuPend
  arb.io.req(2) := dmaPend
  arb.io.req(3) := gpuPend
  arb.io.free   := (owner === OWN_IDLE)    // 非阻塞：当前主人一释放就立刻再仲裁

  // 授权：IDLE 且仲裁器给出 `pickV` 时，按**类**登记 owner；类内保持原固定优先级。
  when((owner === OWN_IDLE) && arb.io.pickV) {
    rdOut := 0.U                              // 新授权从零开始计在飞读
    switch(arb.io.pick) {
      is(0.U) {   // CPU 组：LSU 写 > LSU 读 > Fetch 读（与改前逐字同姿）
        when(io.cpuLsu.awvalid)        { owner := OWN_LSU_WR }
        .elsewhen(io.cpuLsu.arvalid)   { owner := OWN_LSU_RD }
        .otherwise                     { owner := OWN_FETCH_RD }   // 类 0 有请求 ⇒ 必是 Fetch
      }
      is(1.U) {   // NPU：写 > 读
        when(io.npuMem.awvalid)  { owner := OWN_NPU_WR }
        .otherwise               { owner := OWN_NPU_RD }
      }
      is(2.U) {   // DMA（Phase-2b）：写 > 读（照抄 NPU 分支）
        when(io.dmaMem.awvalid)  { owner := OWN_DMA_WR }
        .otherwise               { owner := OWN_DMA_RD }
      }
      is(3.U) {   // GPU（2026-10-31）：写 > 读
        when(io.gpuMem.awvalid)  { owner := OWN_GPU_WR }
        .otherwise               { owner := OWN_GPU_RD }
      }
    }
  }
  // 持有授权直到事务真正完成（读末拍 / 写响应）。各态互斥，后写的 when 覆盖前者的默认优先级即可。
  // ★ L2b：读主人可能在同一授权期内连发多笔 AR（NPU 块槽预取）⇒ 只有**末笔 rlast**才释放；
  //   同拍"收末拍 + 又发新 AR"时净在飞数不变（inc/dec 同拍抵消），授权继续持有。
  private val rdOwner = fetchRd || lsuRd || npuRd || dmaRd || gpuRd
  private val arFire  = cpuMem.arvalid && cpuMem.arready
  private val rlastFire = cpuMem.rvalid && cpuMem.rready && cpuMem.rlast
  when(rdOwner && arFire && !rlastFire) { rdOut := rdOut + 1.U }
  when(rdOwner && rlastFire && !arFire) { rdOut := rdOut - 1.U }
  when(rdOwner && rlastFire && !arFire && (rdOut === 1.U)) { owner := OWN_IDLE }
  when(lsuWr   && cpuMem.bvalid && cpuMem.bready)                 { owner := OWN_IDLE }
  when(npuWr   && cpuMem.bvalid && cpuMem.bready)                 { owner := OWN_IDLE }
  when(dmaWr   && cpuMem.bvalid && cpuMem.bready)                 { owner := OWN_IDLE }
  when(gpuWr   && cpuMem.bvalid && cpuMem.bready)                 { owner := OWN_IDLE }

  // ---- AR 通道：Fetch / LSU / NPU 读 ----
  // ⚠️ NPU 的 addr 是 **28bit**（`NpuAxi64`）、`cpuMem`（`VexiiAxi64`）是 **32bit** ⇒ **高位零扩展**
  //    `Cat(0.U(4.W), io.npuMem.araddr)`（NPU 地址本就是 32B 对齐的字节地址，零扩展不改变含义）。
  //    这是本处唯一的"形状折算"；NPU 的 id（`arid`）在单 outstanding 汇聚里**丢弃**（NPU 自己恒发 0）。
  private val npuArAddr32 = Cat(0.U(4.W), io.npuMem.araddr)
  private val npuAwAddr32 = Cat(0.U(4.W), io.npuMem.awaddr)
  // DMA 主口与 NPU 同形（28bit addr / 4bit id）⇒ 同一套"28→32 零扩展 + id 丢弃"（见上条注释）。
  private val dmaArAddr32 = Cat(0.U(2.W), io.dmaMem.araddr)
  private val dmaAwAddr32 = Cat(0.U(2.W), io.dmaMem.awaddr)
  cpuMem.arvalid := Mux(fetchRd, io.cpuFetch.arvalid, Mux(lsuRd, io.cpuLsu.arvalid,
                        Mux(npuRd, io.npuMem.arvalid, Mux(dmaRd, io.dmaMem.arvalid,
                        Mux(gpuRd, io.gpuMem.arvalid, false.B)))))
  cpuMem.araddr  := Mux(fetchRd, io.cpuFetch.araddr,  Mux(lsuRd, io.cpuLsu.araddr,
                        Mux(npuRd, npuArAddr32, Mux(dmaRd, dmaArAddr32, io.gpuMem.araddr))))
  cpuMem.arlen   := Mux(fetchRd, io.cpuFetch.arlen,   Mux(lsuRd, io.cpuLsu.arlen,   Mux(npuRd, io.npuMem.arlen,   Mux(dmaRd, io.dmaMem.arlen,   io.gpuMem.arlen))))
  cpuMem.arsize  := Mux(fetchRd, io.cpuFetch.arsize,  Mux(lsuRd, io.cpuLsu.arsize,  Mux(npuRd, io.npuMem.arsize,  Mux(dmaRd, io.dmaMem.arsize,  io.gpuMem.arsize))))
  cpuMem.arburst := Mux(fetchRd, io.cpuFetch.arburst, Mux(lsuRd, io.cpuLsu.arburst, Mux(npuRd, io.npuMem.arburst, Mux(dmaRd, io.dmaMem.arburst, io.gpuMem.arburst))))
  cpuMem.arcache := Mux(fetchRd, io.cpuFetch.arcache, Mux(lsuRd, io.cpuLsu.arcache, Mux(npuRd, io.npuMem.arcache, Mux(dmaRd, io.dmaMem.arcache, io.gpuMem.arcache))))
  cpuMem.arprot  := Mux(fetchRd, io.cpuFetch.arprot,  Mux(lsuRd, io.cpuLsu.arprot,  Mux(npuRd, io.npuMem.arprot,  Mux(dmaRd, io.dmaMem.arprot,  io.gpuMem.arprot))))
  io.cpuFetch.arready := cpuMem.arready && fetchRd     // ←【反假装接受】非授权拍回告 ready=0
  io.cpuLsu.arready   := cpuMem.arready && lsuRd
  io.npuMem.arready   := cpuMem.arready && npuRd
  io.dmaMem.arready   := cpuMem.arready && dmaRd
  io.gpuMem.arready   := cpuMem.arready && gpuRd

  // ---- AW/W/B 通道：LSU 写 或 NPU 写 ----
  // ⚠️ 与 CPU 那条通道**逐条同姿**：`awvalid`/`wvalid` 只在被授权时摆；`awready`/`wready` 只在被
  //    授权时回告 ⇒ 未授权的写方保持 valid+payload（标准背压）。**W 与 AW 同门**（见 §4 的 ★ 注释：
  //    核的 `Axi4Bridge` 里 W 与 AW 不是握手依赖 ⇒ 只修 `awready` 会退化成"AW 压住、W 照发"）。
  cpuMem.awvalid := Mux(lsuWr, io.cpuLsu.awvalid,
                     Mux(npuWr, io.npuMem.awvalid && npuWr,
                     Mux(dmaWr, io.dmaMem.awvalid && dmaWr, io.gpuMem.awvalid && gpuWr)))
  cpuMem.awaddr  := Mux(lsuWr, io.cpuLsu.awaddr,  Mux(npuWr, npuAwAddr32,
                     Mux(dmaWr, dmaAwAddr32, io.gpuMem.awaddr)))
  cpuMem.awlen   := Mux(lsuWr, io.cpuLsu.awlen,   Mux(npuWr, io.npuMem.awlen,   Mux(dmaWr, io.dmaMem.awlen,   io.gpuMem.awlen)))
  cpuMem.awsize  := Mux(lsuWr, io.cpuLsu.awsize,  Mux(npuWr, io.npuMem.awsize,  Mux(dmaWr, io.dmaMem.awsize,  io.gpuMem.awsize)))
  cpuMem.awburst := Mux(lsuWr, io.cpuLsu.awburst, Mux(npuWr, io.npuMem.awburst, Mux(dmaWr, io.dmaMem.awburst, io.gpuMem.awburst)))
  cpuMem.awcache := Mux(lsuWr, io.cpuLsu.awcache, Mux(npuWr, io.npuMem.awcache, Mux(dmaWr, io.dmaMem.awcache, io.gpuMem.awcache)))
  cpuMem.awprot  := Mux(lsuWr, io.cpuLsu.awprot,  Mux(npuWr, io.npuMem.awprot,  Mux(dmaWr, io.dmaMem.awprot,  io.gpuMem.awprot)))
  cpuMem.wvalid  := Mux(lsuWr, io.cpuLsu.wvalid,
                     Mux(npuWr, io.npuMem.wvalid && npuWr,
                     Mux(dmaWr, io.dmaMem.wvalid && dmaWr, io.gpuMem.wvalid && gpuWr)))
  cpuMem.wdata   := Mux(lsuWr, io.cpuLsu.wdata,   Mux(npuWr, io.npuMem.wdata,   Mux(dmaWr, io.dmaMem.wdata,   io.gpuMem.wdata)))
  cpuMem.wstrb   := Mux(lsuWr, io.cpuLsu.wstrb,   Mux(npuWr, io.npuMem.wstrb,   Mux(dmaWr, io.dmaMem.wstrb,   io.gpuMem.wstrb)))
  cpuMem.wlast   := Mux(lsuWr, io.cpuLsu.wlast,   Mux(npuWr, io.npuMem.wlast,   Mux(dmaWr, io.dmaMem.wlast,   io.gpuMem.wlast)))
  io.cpuLsu.awready := cpuMem.awready && lsuWr         // W 与 AW 同门（见 §4 的"两个半门"注释）
  io.cpuLsu.wready  := cpuMem.wready  && lsuWr
  io.cpuLsu.bvalid  := cpuMem.bvalid && lsuWr
  io.cpuLsu.bresp   := cpuMem.bresp
  io.npuMem.awready := cpuMem.awready && npuWr
  io.npuMem.wready  := cpuMem.wready  && npuWr
  io.npuMem.bvalid  := cpuMem.bvalid && npuWr
  io.npuMem.bresp   := cpuMem.bresp
  io.npuMem.bid     := 0.U                              // 单 outstanding ⇒ 回程 id 恒定 0（NPU 不校验 id）
  io.dmaMem.awready := cpuMem.awready && dmaWr
  io.dmaMem.wready  := cpuMem.wready  && dmaWr
  io.dmaMem.bvalid  := cpuMem.bvalid && dmaWr
  io.dmaMem.bresp   := cpuMem.bresp
  io.dmaMem.bid     := 0.U                              // 单 outstanding ⇒ 回程 id 恒定 0（DMA 不校验 id）
  io.gpuMem.awready := cpuMem.awready && gpuWr
  io.gpuMem.wready  := cpuMem.wready  && gpuWr
  io.gpuMem.bvalid  := cpuMem.bvalid && gpuWr
  io.gpuMem.bresp   := cpuMem.bresp
  cpuMem.bready  := Mux(lsuWr, io.cpuLsu.bready, Mux(npuWr, io.npuMem.bready,
                    Mux(dmaWr, io.dmaMem.bready, Mux(gpuWr, io.gpuMem.bready, false.B))))

  // ---- R 通道：按 owner 把读数据送回被授予的主方 ----
  io.cpuFetch.rvalid := cpuMem.rvalid && fetchRd
  io.cpuFetch.rdata  := cpuMem.rdata
  io.cpuFetch.rresp  := cpuMem.rresp
  io.cpuFetch.rlast  := cpuMem.rlast
  io.cpuLsu.rvalid   := cpuMem.rvalid && lsuRd
  io.cpuLsu.rdata    := cpuMem.rdata
  io.cpuLsu.rresp    := cpuMem.rresp
  io.cpuLsu.rlast    := cpuMem.rlast
  io.npuMem.rvalid   := cpuMem.rvalid && npuRd
  io.npuMem.rdata    := cpuMem.rdata
  io.npuMem.rresp    := cpuMem.rresp
  io.npuMem.rlast    := cpuMem.rlast
  io.npuMem.rid      := 0.U                              // 单 outstanding ⇒ 回程 id 恒定 0
  io.dmaMem.rvalid   := cpuMem.rvalid && dmaRd
  io.dmaMem.rdata    := cpuMem.rdata
  io.dmaMem.rresp    := cpuMem.rresp
  io.dmaMem.rlast    := cpuMem.rlast
  io.dmaMem.rid      := 0.U                              // 单 outstanding ⇒ 回程 id 恒定 0
  io.gpuMem.rvalid   := cpuMem.rvalid && gpuRd
  io.gpuMem.rdata    := cpuMem.rdata
  io.gpuMem.rresp    := cpuMem.rresp
  io.gpuMem.rlast    := cpuMem.rlast
  cpuMem.rready   := Mux(fetchRd, io.cpuFetch.rready, Mux(lsuRd, io.cpuLsu.rready,
                     Mux(npuRd, io.npuMem.rready, Mux(dmaRd, io.dmaMem.rready,
                     Mux(gpuRd, io.gpuMem.rready, false.B)))))

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

  // ---- 分支 A：CPU 的 LsuL1（**无 id** / 有 cache+prot / **64bit data**）⇒ AXIIO64 ----
  private val cpuAxi = Wire(new AXIIO64)
  cpuAxi.aw.awid    := 0.U                   // 新核**无 id 通道** ⇒ 恒 0
  cpuAxi.aw.awaddr  := cpuMem.awaddr
  cpuAxi.aw.awlen   := cpuMem.awlen
  cpuAxi.aw.awsize  := cpuMem.awsize
  cpuAxi.aw.awburst := cpuMem.awburst
  cpuAxi.aw.awlock  := 0.U
  cpuAxi.aw.awcache := cpuMem.awcache        // 新核带 cache（旧模板没有）
  cpuAxi.aw.awprot  := cpuMem.awprot         // 新核带 prot（旧模板没有）
  cpuAxi.aw.awvalid := cpuMem.awvalid && !memRdBusy   // ←【纪律②】读在飞时不放行 AW
  cpuAxi.w.wid      := 0.U
  cpuAxi.w.wdata    := cpuMem.wdata
  cpuAxi.w.wstrb    := cpuMem.wstrb
  cpuAxi.w.wlast    := cpuMem.wlast
  // ⚠️ W 与 AW **完全对称**：两个半门必须同时加，缺一个就退化成"假装接受"。
  //    本模块对 `io.mem` 是**主方**（W 的 valid 是输出、ready 是输入），所以"这一拍不收 W"只能
  //    由"**不摆 valid** + **不向核回告 ready**"这**两件事一起**表达：
  //      · 掩 `wvalid`（不给从方看到本拍有数据）—— 只掩它会被核当成"已成交"⇒ 丢数据；
  //      · 低 `wready`（不给核回告"收下了"）—— 只低它则从方仍会把这一拍收走（`io.mem.w.wvalid`
  //        还是 1，从方 `wready` 也是 1 ⇒ 握手成立），核以为没成交、稍后**重发同一拍** ⇒ 该拍
  //        要么丢、要么被写到下一笔突发上。实测就是这个半吊子形态：`cyc=49080 memRdBusy=1` 时
  //        "从方看到的 `wready`"仍是 tb 驱动的 1，`[AXI-WARN]` 照丢 2 拍。
  cpuAxi.w.wvalid   := cpuMem.wvalid && !memRdBusy
  cpuAxi.b.bready   := cpuMem.bready
  cpuAxi.ar.arid    := 0.U                   // 新核**无 id 通道** ⇒ 恒 0
  cpuAxi.ar.araddr  := cpuMem.araddr
  cpuAxi.ar.arlen   := cpuMem.arlen
  cpuAxi.ar.arsize  := cpuMem.arsize
  cpuAxi.ar.arburst := cpuMem.arburst
  cpuAxi.ar.arlock  := 0.U
  cpuAxi.ar.arcache := cpuMem.arcache        // 新核带 cache
  cpuAxi.ar.arprot  := cpuMem.arprot         // 新核带 prot
  cpuAxi.ar.arvalid := cpuMem.arvalid
  cpuAxi.r.rready   := cpuMem.rready

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

  cpuMem.awready := cpuAxi.aw.awready
  cpuMem.wready  := cpuAxi.w.wready
  cpuMem.bresp   := cpuAxi.b.bresp
  cpuMem.bvalid  := cpuAxi.b.bvalid
  cpuMem.arready := cpuAxi.ar.arready
  cpuMem.rdata   := cpuAxi.r.rdata
  cpuMem.rresp   := cpuAxi.r.rresp
  cpuMem.rlast   := cpuAxi.r.rlast
  cpuMem.rvalid  := cpuAxi.r.rvalid
  // 新核无 bid/rid 通道 ⇒ 不再回送 id（旧模板的 `cpuMem.bid/rid` 两行已删）。

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
  //
  // ★★ Y1-DMA Phase-2c 补充（**这条选通的语义变了**，不是风格）：DMA 模式下**装载器不再是内存主人**
  //    —— 它把字节流喂给引擎，由**引擎**过 §3.5（第 6 个主人）去打 `io.mem`。若这里仍用"装载器在跑"
  //    当选择条件，引擎的流量会被选通挡掉（`loaderAxi` 分支在 DMA 模式下恒 0）⇒ 一笔都搬不出去。
  //    ⇒ 选通条件收紧为：
  //      · UART 后备装载器**永远直写**（它没有喂引擎这条路）⇒ 恒走装载器分支；
  //      · SD 装载器：`sdDmaMode=0` ⇒ 直写（装载器分支，**与 Phase-2b 逐位相同**）；
  //                    `sdDmaMode=1` ⇒ 喂引擎（走 `cpuAxi` 分支，即 §3.5 的 DMA 类）。
  //    ⚠️ `sdDmaMode=0` 时 `memSel = uartEnable || sdEnable = loadActive` ⇒ 与 Phase-2b **逐位同值**
  //       （既有装置/判据不受影响）。
  private val memSel = uartEnable || (sdEnable && !io.sdDmaMode)

  // ★★ Y1-DMA Phase-2b 决策（Task item 5）：**保留这个一热选通**，不改成 MemArbiter。**逐条理由**：
  //   ① DMA 引擎接在 **§3.5 那个汇聚点**（第 6 个主人，CPU 组/NPU 之间真仲裁），**不接在这条最终
  //      主口上** ⇒ 本处的两个分支（装载器 / `cpuAxi`=CPU 组含 DMA/NPU）**一字未变**；DMA 的流量
  //      走的是 `cpuAxi` 分支内部（§3.5→§4），与本选通无关。
  //   ② 本选通的分支是**时间互斥**的：`memSel = loadActive`，而装载期板级把 CPU 扣在复位
  //      （`io.cpuReset` ⇒ 板级 OR 进核复位）⇒ CPU 组结构性地不发命令；装载器加载期只写、读通道
  //      恒空闲。⇒ 一次只有一方驱动 `io.mem` ⇒ 一热选通**足够**（与 Phase-1 的口径一致）。
  //   ③ 把它也换成 MemArbiter 需要一个**能同时驱动装载器与 CPU 组**的装置才判得出（现有 harness
  //      的 loader 是 tf 卡 SPI 时序，代价大、收益 0）—— 属于"另一相"，本相**不做**。
  //   **守卫（能翻红的检查，见下）**：把互斥这一条**钉成断言**（不是注释）：装载器当主人时，CPU 组
  //   的任一命令 valid 都不许抬起。若将来有人把 `memSel` 改错（或让两方同时驱动），这条断言在
  //   `--assert` 下会**响亮失败**（本仓的 glue 装置已按 `--assert` 编译，见 run_dma_pbus_unit.sh）。
  // ★★ Phase-2c 更新（**推翻上面理由①的一部分**，如实记）：`sdDmaMode=1` 时装载器**不再是**
  //   `io.mem` 的主人（引擎才是，经 §3.5），故 `memSel` 不再等于 `loadActive`（见下面的收紧式）。
  //   守卫仍然成立且**范围正确**：`memSel=1` 现在只可能在"UART 后备直写"或"SD 直写(sdDmaMode=0)"
  //   这两种情况下出现 —— 两种情况下 CPU 都必须静默（板级扣复位）。
  when(memSel) {
    assert(!(io.cpuFetch.arvalid || io.cpuLsu.awvalid || io.cpuLsu.arvalid),
      "memSel: loader owns io.mem => CPU group must NOT issue (loader/CPU must stay time-exclusive)")
  }
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
