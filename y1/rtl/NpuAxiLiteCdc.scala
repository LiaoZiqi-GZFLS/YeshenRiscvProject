import spinal.core._
import spinal.lib._

// =============================================================================
// NpuAxiLiteCdc —— **AXI4-Lite 主机寄存器窗的异步（CDC）桥**：`cpu_clk` 侧是 AXI4-Lite **从口**，
// `npu_clk` 侧是 AXI4-Lite **主口**。用途：Y1「NPU 独立时钟域」plan Task **N3**（spec §3-A(a) / §5-G2）。
//
// ★★ 本任务（N3）**只交付这座桥本身 + 它的独立两时钟装置**：
//    · **不**把桥接进 `src/YeshenSocGlue.scala` 的活路径（那是 N3 之后的集成步）；
//    · **不**把 `NpuTop` 换成 `npu_clk`（域切换要等 N3+N4+N5 都建好）。
//    ⇒ 现有闸门（含 N1 的"先红"两时钟装置）行为一字不变。
//
// -----------------------------------------------------------------------------
// 为什么存在（一句话）：`NpuTop` 要移进独立 `npu_clk`（N2b：第二颗 GTP_GPLL 出精确 50.000MHz），
// 而 glue 的 pBus 译码 / 汇聚点**全程留在 `cpu_clk`**（spec §3-A）⇒ 主机寄存器窗这条路必须跨域。
//
// -----------------------------------------------------------------------------
// ★ 复用而非新造：跨域机制**逐条照抄**仓里唯一被验证过的 CDC 原语 ——
//   `src/soc/CDCQueue.scala` 的 `class CDCPipe[T]`（**单字 4 相电平握手 + 每方向 2 级同步器**）。
//   本文件把它按 SpinalHDL 逐行重写为 `CdcPipeSp`（见下，逐句对照写在它的注释里），
//   不引入任何新的握手/同步结构（spec §6-R1 的处置口径）。
//
//   | CDCPipe (Chisel, src/soc/CDCQueue.scala)        | CdcPipeSp (本文件)                       |
//   |------------------------------------------------|-----------------------------------------|
//   | `io.sClk/sRstn/dClk/dRstn` 显式时钟/复位端口       | 同名同义（**低有效**复位，见"复位口径"）    |
//   | `enq: Flipped(Decoupled)` = valid 入 / ready 出   | `io.enq  = slave  Stream`（同姿态）        |
//   | `deq: Decoupled` = valid 出 / ready 入            | `io.deq  = master Stream`（同姿态）        |
//   | `ackSync1 := dAckOut; ackSync2 := ackSync1`      | `ackSync1 := dAck; ackSync2 := ackSync1` |
//   | `validSync1 := sValid; validSync2 := validSync1` | 逐字同                                     |
//   | `enq.ready := !sValid && !ackSync2`             | 逐字同                                     |
//   | `when(enq.fire){sData:=..;sValid:=1}.elsewhen(ackSync2){sValid:=0}` | 逐字同            |
//   | `when(v2 && !dPending){dData:=sData;dPending:=1}.elsewhen(!v2){dPending:=0;dAck:=0}` | 逐字同 |
//   | `when(deq.fire){dAck:=1}`                        | 逐字同                                     |
//   差别只有两处，且都是"落盘需要"：① 用 SpinalHDL 的 `ClockDomain` 显式建两域（Chisel 版用
//   `withClockAndReset`）；② 源/目的域的寄存器都直接按名引用（Chisel 版把 `dAckOut` 拉成端口，
//   仅为层次边界，语义等价 —— 这里同一 Component 内直接引用寄存器输出，跨域读的**仍是寄存器 Q**）。
//
//   四相握手的**正确性论证**（与 CDCPipe 同）：源域 `sValid`/`sData` 在 `enq.fire` 那拍锁存后
//   **一直保持**，直到 ack 电平同步回来（`ackSync2`）才落 0；目的域只在 `validSync2` 稳定为 1 且
//   `!dPending` 时锁存数据，并且 `dAck` 要等 `!validSync2`（即源已撤 req）才落 0。⇒ 任何频率比
//   下**都不会丢拍/重复**：源不会在目的还没看见之前改数据（`enq.ready` 要求 `!sValid && !ackSync2`，
//   而 `ackSync2` 只有目的把 `dAck` 放掉才落），目的也不会在源撤 req 之前二次锁存（`dPending`）。
//
// -----------------------------------------------------------------------------
// ★ AXI4-Lite 通道映射（**5 条单向管道，各一条 4 相握手**；与 `DDR3Bridge` 的 5 条 CDCPipe 同姿）：
//
//   方向 cpu_clk → npu_clk（请求）：
//     · `awPipe`  AW{addr[31:0], prot[2:0]}
//     · `wPipe`   W {data[31:0], strb[3:0]}       ← ★ 逐字节写使能必须跟着数据一起跨（否则字节语义错）
//     · `arPipe`  AR{addr[31:0], prot[2:0]}
//   方向 npu_clk → cpu_clk（响应）：
//     · `bPipe`   B {resp[1:0]}
//     · `rPipe`   R {data[31:0], resp[1:0]}
//
//   跨过的**只有**这 5 条管道里的那些位：全部是各自域的**寄存器输出**（源域 `sData`/`sValid`，
//   目的域 `dData`/`dPending`/`dAck`），没有第二条组合路径。`wstrb`/`bresp`/`rresp` 原样透传
//   （不解释、不修改）：`wstrb` 4 bit 跟着 W 一起跨；`bresp`/`rresp` 跟着 B/R 一起跨；
//   本桥**不产生**任何响应（`OKAY`/`SLVERR` 由 NPU 从口决定，桥只搬运）。
//
//   ★ **单笔未完成（single-outstanding）**：AXI4-Lite 本身允许一笔写 + 一笔读同时在路上，
//     同一通道内不允许叠加。本桥**天然**满足：`CDCPipe` 的 `enq.ready` 只在"整轮四相握完"后才
//     为 1 ⇒ 同一通道的第二笔 AW/W/AR 会被**背压**在 host 侧（host 必须等 ready）⇒ 桥内每一刻
//     最多一笔请求在飞。AW 与 W 是**两条独立管道**，因此它们的跨域先后可以任意（AXI4-Lite 允许
//     从口以任意顺序收下 AW/W），NPU 侧从口自己配对（本桥不做配对、不做空洞检查）。
//     ★ 已知边界（写明，不掩盖）：本桥**不**给 host 做 AXI 乱序/多笔在飞的排序保证 ——
//       glue 的 pBus 汇聚点本就是 single-outstanding（spec §2/§3-A），host 不会叠加多笔。
//
// -----------------------------------------------------------------------------
// ★ 复位口径（本任务只管"桥自己的两个域"；**整机跨域复位释放顺序是 N5 的活**）：
//   `cpuRstn` / `npuRstn` 是**各自域的低有效复位**（与 `CDCPipe` 的 `sRstn`/`dRstn` **同极性**，
//   见 DDR3Bridge 那段"复位极性踩坑"注释：高有效信号直灌低有效口 = 桥在板上是死的）。
//   内部两个 `ClockDomain` 用 `resetKind = ASYNC, resetActiveLevel = LOW`（与 CDCPipe 的异步复位同姿）。
//   本装置里两域复位**同时**释放：桥的两套状态机复位后都处于 IDLE（`sValid=0 / dPending=0 / dAck=0`）
//   ⇒ 释放竞态不可能凭空造出一笔事务。NPU 整机接入时的"按域同步释放"由 N5 定。
//
// -----------------------------------------------------------------------------
// ★ 接口命名：`cpu_clk` 侧的从口端口名**逐字沿用** `NpuTop.axilite_*`（`board/yeshen_mini_soc.v:717-731`
//   的冻结端口表）⇒ 将来集成时是把 glue 的 `io_npuAxi_*` 接本桥的 `axilite_*`，再把本桥的
//   `npu_axilite_*` 接 `NpuTop.axilite_*`，**端口形状零改动**。addr 32 bit / data 32 bit / strb 4 bit /
//   prot 3 bit / resp 2 bit（`VexiiAxiLite32` 与 `AxiLite4` 同形）。
//
// ★ **留给集成步（N3 集成 / N4+N5 之后）的接线清单**（本任务**不做**，只把口径写死在这里，免歧义）：
//     glue.io_npuAxi.awvalid/wvalid/arvalid/bready/rready  →  本桥 axilite_*.valid/ready（同名直连）
//     glue.io_npuAxi.awaddr/araddr（glue 现在发的是**窗内偏移 pW(13,0)/pR(13,0)**
//       —— 见 `src/YeshenSocGlue.scala:626/633`）           →  本桥 axilite_*_payload_addr（零扩展成 32bit）
//         ⚠ 两种口径都对（NpuTop 的 HostRegs 只认 addr & ~3，窗内 0 基址）：要么喂**窗内偏移**，
//           要么喂**整根地址**（`0xF000_C000 | off`，此时有效门控仍由 glue 的 `isNpuW/isNpuR` 给）。
//           **别混用**：本桥**不做**基址剥离/拼接，它只搬运。
//     glue.io_npuAxi.wdata/wstrb                          →  本桥 axilite_w_payload_*
//     本桥 npu_axilite_*                                   →  NpuTop.axilite_*（同名前缀替换）
//     时钟：本桥 cpuClk/cpuRstn = glue 的时钟与复位；npuClk/npuRstn = N2b 的 npu_clk 与
//           **该域自己的**复位（低有效；释放顺序由 N5 定）。
//     单笔未完成：glue 的 pBus 汇聚点本就是 single-outstanding（spec §2/§3-A），与本桥口径一致。
// =============================================================================

/** AXI4-Lite 地址类载荷（AW / AR 同形）。 */
class AxiLiteAddrPayload(val addrW: Int) extends Bundle {
  val addr = UInt(addrW bits)
  val prot = UInt(3 bits)
}

/** AXI4-Lite 写数据载荷（W）。 */
class AxiLiteWrDataPayload extends Bundle {
  val data = Bits(32 bits)
  val strb = Bits(4 bits)
}

/** AXI4-Lite 写响应载荷（B）。 */
class AxiLiteBRespPayload extends Bundle {
  val resp = Bits(2 bits)
}

/** AXI4-Lite 读响应载荷（R）。 */
class AxiLiteRdDataPayload extends Bundle {
  val data = Bits(32 bits)
  val resp = Bits(2 bits)
}

/** 单字 4 相电平握手跨域管道 —— `src/soc/CDCQueue.scala` 的 `CDCPipe[T]` 的 SpinalHDL 逐行移植。
  *
  * 语义（与 CDCPipe 逐字一致，见文件头对照表）：
  *   · 源域（`sClk`）：`enq.fire` 后把 `sData` 锁存、`sValid` 举 1 并**保持**，直到 `ackSync2`（目的域
  *     `dAck` 经 2 级同步器回采）为 1 才清 0；`enq.ready = !sValid && !ackSync2`。
  *   · 目的域（`dClk`）：`sValid` 经 2 级同步器得 `validSync2`；`validSync2 && !dPending` 那拍锁存
  *     `dData` 并置 `dPending`；`deq.fire` 后置 `dAck`（保持）；`!validSync2`（源已撤 req）那拍清
  *     `dPending` 与 `dAck`。
  *   · 2 级同步器是**每方向各一组**（`ackSync1/2` 在 `sClk`，`validSync1/2` 在 `dClk`）。
  *     四相电平握手 ⇒ **任何时钟频率比**都不会丢拍/重复（不依赖"快慢"或"整数比"）。
  *   · ★ 与 `CDCPipe` 的**唯一**差别见下面 `dMask` 那一段（AXI 要"一笔 = 一个 valid 脉冲"）。
  */
class CdcPipeSp[T <: Data](gen: HardType[T], defName: String = "") extends Component {
  // ★ N5b（集成）：本类被 N3（NpuAxiLiteCdc）与 N4（NpuMemCdc）**共享**。两份网表各自单文件落盘时
  //   不会撞名；但 N5b 把两座桥**放进同一个设计**（板级 SoC / 两时钟 TB）时，SpinalHDL 默认按类名
  //   `CdcPipeSp` 命名子模块 ⇒ 两份网表里的 `CdcPipeSp`/`CdcPipeSp_1`… 会**同名不同端口** ⇒
  //   iverilog/PDS 报 "already declared"。
  //   ⇒ 把定义名参数化：**空串 = 保持 SpinalHDL 自动命名**（N3 原样不动，网表逐字节不变）；
  //     N4 传**每种载荷一个唯一名**（见 NpuMemCdc.scala 的 `defName = "NpuMemCdcPipe…"`）⇒ 两座桥的
  //     子模块名**全局唯一**。★ 注意：显式定义名必须**每种 loadout 唯一**（同名不同 layout 会被
  //     SpinalHDL 断言拒绝；同名同 layout 自动去重，如 aw/ar 共用 Addr 载荷）。
  if (defName != "") setDefinitionName(defName)
  val io = new Bundle {
    val sClk  = in Bool()
    val sRstn = in Bool()          // 低有效（与 CDCPipe 的 sRstn 同极性）
    val dClk  = in Bool()
    val dRstn = in Bool()          // 低有效
    val enq   = slave Stream(gen)  // 源域：valid/payload 入、ready 出
    val deq   = master Stream(gen) // 目的域：valid/payload 出、ready 入
  }

  val sCd = ClockDomain(io.sClk, io.sRstn, config = ClockDomainConfig(resetKind = ASYNC, resetActiveLevel = LOW))
  val dCd = ClockDomain(io.dClk, io.dRstn, config = ClockDomainConfig(resetKind = ASYNC, resetActiveLevel = LOW))

  // ==================== 寄存器（先声明两边，再写逻辑：四相握手两域互指，Scala `val` 有初始化顺序）
  // ---- 源域（sClk）----
  val sData    = sCd(Reg(gen))
  val sValid   = sCd(RegInit(False))
  val ackSync1 = sCd(RegInit(False))
  val ackSync2 = sCd(RegInit(False))
  // ---- 目的域（dClk）----
  val validSync1 = dCd(RegInit(False))
  val validSync2 = dCd(RegInit(False))
  val dData      = dCd(Reg(gen))
  val dPending   = dCd(RegInit(False))
  val dAck       = dCd(RegInit(False))
  // ★ AXI 需要、`CDCPipe` 不提供的一格：**"一笔事务 = 一个 valid 脉冲"**。
  //   `CDCPipe` 的 `deq.valid` 在握手后**仍然举着**（电平要一直保持到源撤 req），这对
  //   `DDR3Bridge` 那种"状态机自己配对请求/响应"的消费者无所谓，但 AXI 的**从口/主口**
  //   会把同一个 still-valid 电平当成**第二笔**（重复消费 R / 重复提交 AW）。
  //   ⇒ 目的域多一个 `dMask`：握手那拍置 1 把 `deq.valid` 掩掉，直到本轮四相走完
  //   （`!validSync2`，与 `dPending/dAck` 同时清）才放行下一笔。
  //   ★ 这不是"另造原语"：握手、同步器、ack 路径**一字未动**，只是在 deq 侧加了一个
  //     "已被消费" 的可观测掩码（`dMask` 只由 `io.deq.fire` 置、由 `!validSync2` 清）。
  val dMask      = dCd(RegInit(False))

  // ==================== 源域逻辑 ====================
  // ★ 三处**有意的跨域采样点**：`dAck`（目的→源）与 `sValid`/`sData`（源→目的）。
  //   标 `crossClockDomain` 只为**告诉 SpinalHDL 的 PhaseCheckCrossClock 这几条是设计意图**
  //   （否则它会报 CLOCK CROSSING VIOLATION）；这是元数据、不进网表语义（PDS 只看到线）。
  crossClockDomain(dAck)
  crossClockDomain(sValid)
  crossClockDomain(sData)

  ackSync1 := dAck                       // 目的域 ack 电平（跨域采样：读的是目的域寄存器 Q）
  ackSync2 := ackSync1

  io.enq.ready := !sValid && !ackSync2
  when(io.enq.fire) {
    sData := io.enq.payload
    sValid := True
  }.elsewhen(ackSync2) {
    sValid := False                     // ack 同步回来 ⇒ 清 req；等 ack 也清零后才允许新事务
  }

  // ==================== 目的域逻辑 ====================
  validSync1 := sValid                  // 源域 req 电平（跨域采样：读的是源域寄存器 Q）
  validSync2 := validSync1

  when(validSync2 && !dPending) {       // req 上升沿后锁存数据（只在 !dPending 时）
    dData := sData
    dPending := True
  }.elsewhen(!validSync2) {             // req 已清 ⇒ 复位 pending / ack / 消费掩码
    dPending := False
    dAck := False
    dMask := False
  }

  io.deq.valid := dPending && !dMask     // ★ 一次性脉冲（见上 dMask 注释）
  io.deq.payload := dData
  when(io.deq.fire) {                   // deq.fire 后置 ack 并保持，直到 req 下降沿
    dAck := True
    dMask := True                       // 且把 deq.valid 掩掉 ⇒ 同一笔不会被消费两次
  }
}

/** AXI4-Lite 异步桥：`cpu_clk` 从口 ⇄ `npu_clk` 主口（5 条 `CdcPipeSp`，见文件头）。
  *
  * @param addrW AXI4-Lite 地址宽度（默认 32，与 `VexiiAxiLite32`/`AxiLite4` 同）。
  */
class NpuAxiLiteCdc(addrW: Int = 32) extends Component {
  setDefinitionName("NpuAxiLiteCdc")

  val io = new Bundle {
    // 两个独立时钟 + **低有效**各域复位（极性见文件头"复位口径"）
    val cpuClk  = in Bool()
    val cpuRstn = in Bool()
    val npuClk  = in Bool()
    val npuRstn = in Bool()

    // ---- AXI4-Lite **从口**（cpu_clk 侧；端口名沿用 NpuTop.axilite_*）----
    val axilite_aw = slave Stream(new AxiLiteAddrPayload(addrW))
    val axilite_w  = slave Stream(new AxiLiteWrDataPayload)
    val axilite_b  = master Stream(new AxiLiteBRespPayload)
    val axilite_ar = slave Stream(new AxiLiteAddrPayload(addrW))
    val axilite_r  = master Stream(new AxiLiteRdDataPayload)

    // ---- AXI4-Lite **主口**（npu_clk 侧；接 NpuTop.axilite_*）----
    val npu_axilite_aw = master Stream(new AxiLiteAddrPayload(addrW))
    val npu_axilite_w  = master Stream(new AxiLiteWrDataPayload)
    val npu_axilite_b  = slave Stream(new AxiLiteBRespPayload)
    val npu_axilite_ar = master Stream(new AxiLiteAddrPayload(addrW))
    val npu_axilite_r  = slave Stream(new AxiLiteRdDataPayload)
  }

  // ---------------- 5 条管道（实例名即闸门负对照的突变锚点，见 run_axilite_cdc_ab.sh）----------------
  val awPipe = new CdcPipeSp(new AxiLiteAddrPayload(addrW))   // cpu → npu
  val wPipe  = new CdcPipeSp(new AxiLiteWrDataPayload)        // cpu → npu
  val bPipe  = new CdcPipeSp(new AxiLiteBRespPayload)         // npu → cpu
  val arPipe = new CdcPipeSp(new AxiLiteAddrPayload(addrW))   // cpu → npu
  val rPipe  = new CdcPipeSp(new AxiLiteRdDataPayload)        // npu → cpu

  // 请求向：源 = cpu_clk，目的 = npu_clk
  for (p <- Seq(awPipe, wPipe, arPipe)) {
    p.io.sClk := io.cpuClk; p.io.sRstn := io.cpuRstn
    p.io.dClk := io.npuClk; p.io.dRstn := io.npuRstn
  }
  // 响应向：源 = npu_clk，目的 = cpu_clk
  for (p <- Seq(bPipe, rPipe)) {
    p.io.sClk := io.npuClk; p.io.sRstn := io.npuRstn
    p.io.dClk := io.cpuClk; p.io.dRstn := io.cpuRstn
  }

  // ---- AW：cpu 侧从口 → 管道 → npu 侧主口 ----
  awPipe.io.enq << io.axilite_aw
  io.npu_axilite_aw << awPipe.io.deq

  // ---- W：data + **strb** 一起跨 ----
  wPipe.io.enq << io.axilite_w
  io.npu_axilite_w << wPipe.io.deq

  // ---- B：npu 侧从口（来自 NpuTop）→ 管道 → cpu 侧主口 ----
  bPipe.io.enq << io.npu_axilite_b
  io.axilite_b << bPipe.io.deq

  // ---- AR ----
  arPipe.io.enq << io.axilite_ar
  io.npu_axilite_ar << arPipe.io.deq

  // ---- R：data + resp 一起跨 ----
  rPipe.io.enq << io.npu_axilite_r
  io.axilite_r << rPipe.io.deq
}
