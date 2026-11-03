import spinal.core._

// =============================================================================
// NpuIrqCdc —— **NPU 中断（IRQ）电平的跨域同步器**：`npu_clk` 域产生、`cpu_clk` 域稳定观测。
//   用途：Y1「NPU 独立时钟域」plan Task **N5**（spec §3-A(c) / §5-G3 "IRQ 跨域"）。
//
// ★★ 本任务（N5）**只交付本模块 + 它的独立两时钟装置**：
//    · **不**把本模块接进 `src/YeshenSocGlue.scala` 的活路径（集成是 N5b 的活）；
//    · **不**把 `NpuTop` 换成 `npu_clk`（域切换要等 N3+N4+N5 都建好，见 N5b）；
//    · **不**动 `src/soc/CDCQueue.scala`（只读复用它的"2 级同步器"纪律，见下）。
//    ⇒ 现有闸门（含 N1 的"先红"两时钟装置、N3/N4 两座桥）行为一字不变。
//
// -----------------------------------------------------------------------------
// ★ 为什么**不用** 4 相位握手（与 N3/N4 的 `CdcPipeSp` 不同）：
//   N3/N4 跨的是**载荷总线**（AXI-Lite/AXI4 的地址/数据/响应），必须"每笔一刀、不丢不重" ⇒ 要握手。
//   本模块跨的是 **IRQ 电平**（spec §2：NPU 的 `irq` 是**保持电平**，只由主机写 `CTRL.soft_reset` 清源，
//   见 `YeshenSocGlue.scala:324-326` / `y1/gen/NpuTop.v:763-786`）⇒ **电平语义不需要握手**：
//   只要目的域把源域的这个电平**同步地采稳**即可。**2 级同步器**（2-FF）就是那个纪律
//   （与 `CDCPipe` 每方向的 `validSync1/2`、`ackSync1/2` 同一条 2 级同步器纪律）。
//
//   ★ 电平语义为什么"2-FF 就够"（且比握手更合适）：
//     · 源（npu_clk）的 `irqR` 一旦置 1 **一直保持**，直到主机写 `CTRL.soft_reset` 才落 0
//       ⇒ 它**永远不会短于一个 npu 周期**，因此目的域绝不会"采不到"（不像单拍脉冲会漏）。
//     · 2-FF 把源域的异步电平在目的域**同步地**带回：`cpuIrq` 只可能在 `cpu_clk` 上升沿改变，
//       亚稳态被第一级 FF 吸收、第二级 FF 给出干净电平 ⇒ 任何频率比下**有界延迟**（≤ 2 cpu 拍 + 相位）后
//       稳定等于源电平，且**不会出现毛刺**。
//     · 反向（清）不需要另造握手：见下"清路径"。
//
// -----------------------------------------------------------------------------
// ★★ IRQ 契约（**必须逐条写死，语义不得变**）：
//   ① **谁置起**：`npu_clk` 域里的 `NpuTop.irqR`（`y1/gen/NpuTop.v:763-786`）—— 事件
//      （`DdrMaster.done|err`、`LayerSched.frameDone|err`）上升沿把它**锁成保持电平**（初值 0）。
//      本模块**只搬运**，不产生、不解释、不清任何事件。
//   ② **谁清除**：**只有主机**（CPU）—— 主机写 NPU 寄存器窗的 `CTRL.soft_reset` 位。
//   ③ **清走哪条路**（★ 关键，避免"又造一条反向 CDC"）：`CTRL.soft_reset` 是一次**寄存器写**，
//      它从 `cpu_clk` 侧经 **N3 的 AXI4-Lite 异步桥（`NpuAxiLiteCdc`）** 跨到 `npu_clk` 域，
//      在 NPU 的 `HostRegs` 里落成 `soft_reset` 脉冲 ⇒ **`irqR` 在 `npu_clk` 域被清 0**。
//      之后 `irqR` 的**下降**照常经本模块的 2-FF 同步回 `cpu_clk` ⇒ `cpuIrq` 落 0。
//      ⇒ **反向（cpu→npu）的清不走本模块的 `cpuClearReq` 口**；本模块只提供那条口作为
//        "**若将来还需要一条纯电平的反向跨域**"的**通用手段**（见 ④），当前设计**不用**它。
//   ④ **反向口（可选手段）**：`cpuClearReq`(cpu_clk) → 2-FF → `npuClearReq`(npu_clk)。
//      口径：`cpuClearReq` 是 **cpu_clk 域的保持电平**（若要用，需主机侧自己做成脉冲/一次性）；
//      本模块把它**同步地带到 npu_clk 域**，供 npu 侧消费。**集成时**该口**悬空不用**
//      （因为③已经给了清路径）——因此它是"备选手段"，不是活路径。
//   ⑤ **电平保持语义**：`cpuIrq` = 源电平的同步副本 ⇒ 源保持多久，`cpuIrq` 就保持多久，
//      **绝不会**被本模块自己清掉（模块内没有任何"清 IRQ"的逻辑）。PLIC（源 3）按电平锁存成
//      pending、读 claim 清 pending，与"电平保持"天然适配（`YeshenSocGlue.scala:322-326`）。
//
// -----------------------------------------------------------------------------
// ★ 复位口径：`cpuRstn` / `npuRstn` 是**各自域的低有效复位**（与 N3/N4 的 `cpuRstn`/`npuRstn` 同极性）。
//   两域各自的同步释放由 N5 的 `NpuResetSync` 提供（本装置里两域复位同时释放即可，见 TB 文件头）。
//   复位后两个同步器的所有 FF 都是 0 ⇒ `cpuIrq=0`、`npuClearReq=0`，不会凭空造出一个"伪 IRQ"。
//
// ★ 集成接线清单（本任务**不做**，写死在此免歧义）：N5b 把 glue.io_npuIrq 改为接本模块的
//   `cpuIrq`（cpu_clk 侧），把 `NpuTop.irq` 接本模块的 `npuIrq`（npu_clk 侧）；
//   时钟/复位用同一套（cpuClk/cpuRstn = glue 的时钟与复位；npuClk/npuRstn = npu 域的时钟与复位）。
//
// ★ `npu_clk_alive` 脚手架（board/pll_50m.v / yeshen_mini_soc.v【10】）：本模块（连同 NpuResetSync）
//   在**集成后**自带 `npu_clk` 域寄存器（`irqSync*` 在 cpu 域、`clrSync*`/`npuRstSync`/`cpuUp*` 在 npu 域）
//   ⇒ 本身就是**真实的 `npu_clk` 负载**。但**本任务（N5）不集成**（不接活路径），所以那只
//   `npu_clk_alive_r` 翻转寄存器**照旧保留未动**（N5b 集成后可删；本任务不改 board/**）。
// =============================================================================

/** NPU IRQ 电平跨域同步器：`npu_clk`（保持电平）→ `cpu_clk`（同步副本），2-FF；另设一条可选反向电平口。
  */
class NpuIrqCdc extends Component {
  setDefinitionName("NpuIrqCdc")

  val io = new Bundle {
    // 两个独立时钟 + **低有效**各域复位（与 N3/N4 同极性）
    val cpuClk  = in Bool()
    val cpuRstn = in Bool()
    val npuClk  = in Bool()
    val npuRstn = in Bool()

    // ---- 正向（npu_clk → cpu_clk）：IRQ 电平 ----
    val npuIrq = in  Bool()    // npu_clk 域：NPU 的保持电平（NpuTop.irq）
    val cpuIrq = out Bool()    // cpu_clk 域：同步副本 → PLIC 源 3

    // ---- 反向（cpu_clk → npu_clk）：可选电平口（当前设计不用；清走 N3 寄存器写，见文件头③④）----
    val cpuClearReq = in  Bool()  // cpu_clk 域：保持电平（若用需主机侧自己做成一次性）
    val npuClearReq = out Bool()  // npu_clk 域：同步副本
  }

  val cpuCd = ClockDomain(io.cpuClk, io.cpuRstn, config = ClockDomainConfig(resetKind = ASYNC, resetActiveLevel = LOW))
  val npuCd = ClockDomain(io.npuClk, io.npuRstn, config = ClockDomainConfig(resetKind = ASYNC, resetActiveLevel = LOW))

  // ==================== 正向：npu_clk → cpu_clk（2-FF 电平同步）====================
  // 两个 FF 都在**目的域**（cpu）里；第一级吸收亚稳态，第二级给出干净电平。
  // ★ 这一对 FF 是**承重**的：少一级（或直接组合透传）就不是"跨域同步器"了。
  crossClockDomain(io.npuIrq)          // 标为设计意图（PhaseCheckCrossClock），不进网表语义
  val irqSync1 = cpuCd(RegInit(False))
  val irqSync2 = cpuCd(RegInit(False))
  irqSync1 := io.npuIrq
  irqSync2 := irqSync1
  io.cpuIrq := irqSync2

  // ==================== 反向：cpu_clk → npu_clk（同款 2-FF，可选手段）====================
  crossClockDomain(io.cpuClearReq)
  val clrSync1 = npuCd(RegInit(False))
  val clrSync2 = npuCd(RegInit(False))
  clrSync1 := io.cpuClearReq
  clrSync2 := clrSync1
  io.npuClearReq := clrSync2
}
