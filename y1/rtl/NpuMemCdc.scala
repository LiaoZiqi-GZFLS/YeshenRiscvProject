import spinal.core._
import spinal.lib._
import spinal.lib.bus.amba4.axi._

// =============================================================================
// NpuMemCdc —— **NPU 内存主口（AXI4，addr 28b / data 64b / id 4b）的异步（CDC）桥**：
//   `npu_clk` 侧是 AXI4 **从口**（接 NpuTop.axi_* 那个内存主口），
//   `cpu_clk` 侧是 AXI4 **主口**（喂 glue 的 §3.5 汇聚点 `io.npuMem_*`，**汇聚点/仲裁一字不改**）。
//   用途：Y1「NPU 独立时钟域」plan Task **N4**（spec §3-A(b) / §4.4 / §5-G2）。
//
// ★★ 2026-10-17（L2a）**burst FIFO 版**：旧版 5 条 `CdcPipeSp` 是单 outstanding、W/R 每拍一次
//   4 相握手（一笔 32 B = 1 次 AR + 4 次 R 拍往返）。本版把 5 条通道换成 `NpuMemCdcFifo`
//   （源/目的环形 FIFO + 4 条 `CdcPipeSp` 轮转并发）；AXI 端口一字不变，但 4 拍可同时在飞、
//   AR/AW 描述子可排队。**下面关于「单 outstanding / beat 级 4 相」的段落是旧版设计记录**，
//   保留作演进依据；当前实现的判据以 `run_mem_cdc_ab.sh` 为准。
//
// ★★ 本任务（N4）**只交付这座桥本身 + 它的独立两时钟装置**：
//    · **不**把桥接进 `src/YeshenSocGlue.scala` 的活路径（那是 N4 之后的集成步）；
//    · **不**把 `NpuTop` 换成 `npu_clk`（域切换要等 N3+N4+N5 都建好）；
//    · **不**动 `src/soc/CDCQueue.scala`（只读复用它的纪律，见下）。
//    ⇒ 现有闸门行为一字不变。
//
// -----------------------------------------------------------------------------
// 为什么存在（一句话）：`NpuTop` 要移进独立 `npu_clk`（N2b：第二颗 GTP_GPLL 出精确 50.000MHz），
// 而 glue 的 §3.5 内存主口汇聚点**全程留在 `cpu_clk`**（spec §3-A）⇒ NPU 的 DDR 块搬运主口
// 这条路必须跨域，且**桥放在汇聚点之前**（桥产出一个 `cpu_clk` 的 AXI4 主口，原样喂现有汇聚点）。
//
// -----------------------------------------------------------------------------
// ★ 复用而非新造：跨域机制**逐条照抄**仓里唯一被验证过的 CDC 原语 ——
//   `src/soc/CDCQueue.scala` 的 `class CDCPipe[T]`（**单字 4 相电平握手 + 每方向 2 级同步器**）。
//   本文件**不重写**这套握手，而是**直接复用 N3（commit 4b05a2f）落盘的 SpinalHDL 移植**
//   `y1/rtl/NpuAxiLiteCdc.scala` 里的 `class CdcPipeSp[T]`（它逐行对照过 CDCPipe，且带 N3 当场
//   抓到的 `dMask`「一笔事务 = 一个 valid 脉冲」修正）。**同一个 `CdcPipeSp` 类，单例真源**。
//
// -----------------------------------------------------------------------------
// ★★ 本桥的核心设计裁决：**burst 描述子一次跨 + 数据按拍「单拍一手握」跨**（beat-serialized）。
//
//   任务书允许两条路：完整 burst 级异步 FIFO，或**把一笔 AXI 突发在远侧表达成一串「单拍握手」**。
//   本桥选**后者**，理由与正确性论证如下（**显式声明：本桥把每个数据拍当成一次 4 相握手来跨**）：
//
//   ① **AW / AR 描述子整条跨一次**（一条 `CdcPipeSp`，载荷含 addr/id/len/size/burst/cache/prot）
//      ⇒ 远侧（`cpu_clk`）看到的主口**仍是原突发的形状**（`awlen/arlen` 原值、地址原值），
//      即"一笔 128B 的 16 拍突发"到 `cpu_clk` 侧**还是**一笔 16 拍突发、`wlast/rlast` 落在原位置。
//      ⇒ **glue 汇聚点 / `DDR3Bridge` 看到的 burst 结构一个字没变**（这正是"桥放汇聚点之前、
//      汇聚点不改"的落点）。
//   ② **W 的每个数据拍**、**R 的每个数据拍**、以及 **B 响应**，各自是一次 `CdcPipeSp` 事务
//      （一拍 = 一次 4 相握手）。也就是：一笔 16 拍写突发在 CDC 上 = 1 次 AW 握手 + 16 次 W 握手；
//      一笔 16 拍读突发 = 1 次 AR 握手 + 16 次 R 握手。**没有任何 beat 级 FIFO**。
//
//   为什么"单拍一手握"在**本场景**下是**充分**的（不是偷懒）：
//     · NPU 内存主口（`DdrMaster`）是**单 outstanding**、**有界突发（arlen/awlen <= 15，<= 16 拍）**
//       、相位不重叠（先整块读、R 收完才写）—— 见 `rtl/DdrMaster.scala` 头部 P2/P3 与
//       "一次 start 恒等于块拷贝"。任务书明确要求"复用这条单 outstanding 纪律，让 CDC 保持简单"。
//     · 一条 `CdcPipeSp` 的 `enq.ready` 只在"整轮四相握完"后才回 1 ⇒ **同一通道里每一刻最多
//       一个 beat 在飞**、一个 beat 落定（远侧消费 `deq.fire`）之前源侧**不可能**塞进下一个 beat。
//       于是"握手 per beat"在时间上天然把突发**串行化**成一条 beat 流 —— **顺序保持、不丢、不重**。
//     · 为什么**不**要 beat 级 FIFO：突发 <= 16 拍 x 64b，抓一条 16 深异步 FIFO 只为省几十拍
//       延迟，面积/验证成本远高于收益；而且本桥的吞吐瓶颈在**跨域握手往返**，不在拍级带宽。
//       （未来若要跑满带宽，可把 W/R 换成异步 FIFO —— 接口形状不变，是本文件的局部替换。）
//
//   ★ 正确性论证（"无丢失 / 无重复"，沿 `CDCPipe` 的四相同）：
//     源域（npu）侧 `io.npuMem.{aw,w,ar}.valid` 经 `enq` 进各自管道：`enq.fire`（= valid && ready）
//     那拍锁存载荷并置 `sValid`，**保持**到 ack 电平同步回来（`ackSync2`）才清 ⇒ 源侧不会在目的
//     侧还没看见之前改数据/撤 valid（`enq.ready = !sValid && !ackSync2` 结构性保证）。
//     目的域（cpu）侧只在 `validSync2 && !dPending` 那拍锁存，且 `dMask` 把 `deq.valid` 收敛成
//     "**一笔 = 一个脉冲**"，`dAck` 要等源撤 req（`!validSync2`）才落 ⇒ 目的侧不会把同一 beat
//     消费两次。两条合起来：**任何时钟频率比下都不丢拍、不重复**（与 `CDCPipe` 同）。
//
// -----------------------------------------------------------------------------
// ★ 五条通道的映射（与 N3 同姿，5 条单向管道；方向由"谁是主"定）：
//   方向 **npu_clk 从口 → cpu_clk 主口（请求）**：
//     · `awPipe`  AW{addr[27:0], id[3:0], len[7:0], size[2:0], burst[1:0], cache[3:0], prot[2:0]}
//     · `wPipe`   W {data[63:0], strb[7:0], last}      ← ★ wstrb / wlast 必须跟着数据一起跨
//     · `arPipe`  AR{addr, id, len, size, burst, cache, prot}
//   方向 **cpu_clk 主口 → npu_clk 从口（响应）**：
//     · `bPipe`   B {id[3:0], resp[1:0]}
//     · `rPipe`   R {data[63:0], id[3:0], resp[1:0], last}  ← ★ rid/rresp/rlast 必须跟着数据一起跨
//   跨过的**只有**这 5 条管道里的那些位：全部是各自域的**寄存器输出**（源域 `sData/sValid`，目的域
//   `dData/dPending/dAck/dMask`），没有第二条组合路径。`wstrb`/`wlast`/`rlast`/`bresp`/`rresp`
//   原样透传（不解释、不修改）；本桥**不产生**任何响应，也**不做**地址基址剥离/拼接、**不做** id
//   重排 —— 它只搬运。
//
//   ★ **单笔未完成（single-outstanding）**：本桥**依赖** NPU 内存主口天然的单 outstanding
//     （见上"为什么充分"）。桥内 AW/W/AR 三管道各自独立 ⇒ 它们的跨域先后**可以任意**；远侧从口
//     （不论独立装置里的 `AxiMemModel`，还是板上的 §3.5 汇聚点 + `DDR3Bridge`）按 AXI 规矩对
//     "W 先到、AW 后到"做**标准背压**（`awready` 在 sWrIdle、`wready` 在 sWrAgg，二者互斥）
//     ⇒ 结构上不会出现"AW 没被收下、W 却被吃掉"的孤儿写。这是**依赖既有从口的纪律**，不是本桥
//     自己加的门 —— 与 N3 的口径（"AW/W 两条独立管道，先后任意，从口自己配对"）**逐字一致**。
//
// -----------------------------------------------------------------------------
// ★ 复位口径（本任务只管"桥自己的两个域"；**整机跨域复位释放顺序是 N5 的活**）：
//   `cpuRstn` / `npuRstn` 是**各自域的低有效复位**（与 `CDCPipe` 的 `sRstn`/`dRstn` **同极性**，
//   也与 N3 的 NpuAxiLiteCdc **同口径**）。内部每份 `CdcPipeSp` 用 `resetKind = ASYNC,
//   resetActiveLevel = LOW`。本装置里两域复位**同时**释放：桥的五套状态机复位后都在 IDLE
//   （`sValid=0 / dPending=0 / dAck=0 / dMask=0`）⇒ 释放竞态造不出事务。整机"N5"另定。
//
// -----------------------------------------------------------------------------
// ★ 接口命名：`npu_clk` 侧从口端口名**逐字沿用** `NpuTop.axi_*`（`board/yeshen_mini_soc.v:794-`
//   的冻结端口表）：addr 28b / data 64b / id 4b / len 8b / size 3b / burst 2b / cache 4b / prot 3b，
//   W 无 id（SpinalHDL 1.15.0 的 `Axi4W.id` 为 null）；`cpu_clk` 侧主口端口名沿用 glue 的
//   `io.npuMem_*`（同形，但 addr 在 glue 里是 32b —— **集成时** glue 侧把 28b 零扩展成 32b，
//   见 `src/YeshenSocGlue.scala:813-817` 的 `Cat(0.U(4.W), ...)`）。本桥两侧都用 **28b** 以匹配
//   `NpuTop`/`AxiMemModel`；整机 28→32 的零扩展留在集成步做（与 N3 把"窗内偏移 vs 整根地址"
//   的口径写死在注释里同姿）。
//
// ★ **留给集成步的接线清单**（本任务**不做**，只把口径写死在这里，免歧义）：
//     NpuTop.axi_*            →  本桥 npuMem_*（npu_clk；同名前缀）
//     本桥 cpuMem_*           →  glue.io_npuMem_*（cpu_clk；addr 由 28b 零扩展成 32b，
//                                id → glue 单 outstanding 里丢弃，与现状一致）
//     时钟：本桥 cpuClk/cpuRstn = glue 的时钟与复位；npuClk/npuRstn = N2b 的 npu_clk 与该域自己的
//           低有效复位（释放顺序由 N5 定）。
// =============================================================================

/** AW / AR 同形的地址描述子载荷（一条突发跨一次）。字段顺序/位宽逐条对齐 `Axi4Aw`（无 lock/region/qos）。 */
class MemCdcAddrPayload(val addrW: Int, val idW: Int) extends Bundle {
  val addr  = UInt(addrW bits)
  val id    = UInt(idW bits)
  val len   = UInt(8 bits)
  val size  = UInt(3 bits)
  val burst = Bits(2 bits)
  val cache = Bits(4 bits)
  val prot  = Bits(3 bits)
}

/** W 数据拍载荷（每拍一次握手）：data + **wstrb** + **wlast** 一起跨。 */
class MemCdcWPayload(val dataW: Int) extends Bundle {
  val data = Bits(dataW bits)
  val strb = Bits((dataW / 8) bits)
  val last = Bool()
}

/** B 写响应载荷：id（bid）+ resp（bresp）一起跨。 */
class MemCdcBPayload(val idW: Int) extends Bundle {
  val id   = UInt(idW bits)
  val resp = Bits(2 bits)
}

/** R 读数据拍载荷（每拍一次握手）：data + id（rid）+ resp（rresp）+ **rlast** 一起跨。 */
class MemCdcRPayload(val dataW: Int, val idW: Int) extends Bundle {
  val data = Bits(dataW bits)
  val id   = UInt(idW bits)
  val resp = Bits(2 bits)
  val last = Bool()
}

/** NPU 内存主口 AXI4 异步桥：`npu_clk` 从口 ⇄ `cpu_clk` 主口（5 条 `NpuMemCdcFifo`，每条 = 环形 FIFO + 4 条 `CdcPipeSp` 并发；见文件头）。
  *
  * @param addrW 地址宽度（默认 28，与 `NpuTop.axi_*` / `AxiMemModel` 同）。
  * @param dataW 数据宽度（默认 64，与 `AXIIO64` 同）。
  * @param idW   id 宽度（默认 4，与 `AXIIO64` 同）。
  */
class NpuMemCdc(addrW: Int = 28, dataW: Int = 64, idW: Int = 4) extends Component {
  setDefinitionName("NpuMemCdc")

  val strbW = dataW / 8

  val axiCfg = Axi4Config(
    addrW, dataW, idWidth = idW,
    useId = true, useLen = true, useLock = false, useRegion = false, useQos = false,
    awUserWidth = 0, arUserWidth = 0, wUserWidth = 0, bUserWidth = 0, rUserWidth = 0
  )

  val io = new Bundle {
    // 两个独立时钟 + **低有效**各域复位（极性见文件头"复位口径"）
    val cpuClk  = in Bool()
    val cpuRstn = in Bool()
    val npuClk  = in Bool()
    val npuRstn = in Bool()

    // ---- AXI4 **从口**（npu_clk 侧；端口名沿用 NpuTop.axi_*）----
    val npuMem = slave(Axi4(axiCfg))
    // ---- AXI4 **主口**（cpu_clk 侧；接 glue.io_npuMem_* / 独立装置里的 AxiMemModel）----
    val cpuMem = master(Axi4(axiCfg))
  }
  noIoPrefix()

  // ---------------- 5 条 burst FIFO（实例名即闸门负对照的突变锚点，见 run_mem_cdc_ab.sh）----------------
  //   请求向（npu → cpu）：AW / W / AR     响应向（cpu → npu）：B / R
  //   ★ 2026-10-17（L2a）：由「单 outstanding 的 5 条 CdcPipeSp」换成「5 条 NpuMemCdcFifo」：
  //     每条 = 源/目的环形 FIFO + `lanes=4` 条 CdcPipeSp 轮转并发。AXI 端口形状不变；
  //     W/R 的**每个数据拍不再各付一次跨域往返**，AR/AW 描述子也可排队（多笔在飞）。
  //   ★ 给每种载荷一个唯一定义名，避免与 N3（NpuAxiLiteCdc）以及 SoC 的 CdcFifo 撞名；
  //     aw/ar 载荷同形（MemCdcAddrPayload）⇒ 同名同 layout 自动去重，共用一份。
  //   ★ lanes=4/depth=8（全部通道）是面积与吞吐的折中：一条 32 B 读 = 4 拍，4 道正好让
  //     这 4 拍同时在飞；depth≥lanes 即不限制并发，8 足够容纳多笔在飞，且比 depth=16 少
  //     一半 FIFO 寄存器阵列与 mux LUT（2026-10-17 面积优化；未单独做 depth 8/16 的 A/B）。
  val awPipe = new NpuMemCdcFifo(new MemCdcAddrPayload(addrW, idW), lanes = 4, depth = 8,
                                  defName = "NpuMemCdcFifoAddr", pipeDefName = "NpuMemCdcFifoPipeAddr")
  val wPipe  = new NpuMemCdcFifo(new MemCdcWPayload(dataW),         lanes = 4, depth = 8,
                                  defName = "NpuMemCdcFifoW",    pipeDefName = "NpuMemCdcFifoPipeW")
  val bPipe  = new NpuMemCdcFifo(new MemCdcBPayload(idW),           lanes = 4, depth = 8,
                                  defName = "NpuMemCdcFifoB",    pipeDefName = "NpuMemCdcFifoPipeB")
  val arPipe = new NpuMemCdcFifo(new MemCdcAddrPayload(addrW, idW), lanes = 4, depth = 8,
                                  defName = "NpuMemCdcFifoAddr", pipeDefName = "NpuMemCdcFifoPipeAddr")
  val rPipe  = new NpuMemCdcFifo(new MemCdcRPayload(dataW, idW),    lanes = 4, depth = 8,
                                  defName = "NpuMemCdcFifoR",    pipeDefName = "NpuMemCdcFifoPipeR")

  // 请求向：源 = npu_clk，目的 = cpu_clk
  for (p <- Seq(awPipe, wPipe, arPipe)) {
    p.io.sClk := io.npuClk; p.io.sRstn := io.npuRstn
    p.io.dClk := io.cpuClk; p.io.dRstn := io.cpuRstn
  }
  // 响应向：源 = cpu_clk，目的 = npu_clk
  for (p <- Seq(bPipe, rPipe)) {
    p.io.sClk := io.cpuClk; p.io.sRstn := io.cpuRstn
    p.io.dClk := io.npuClk; p.io.dRstn := io.npuRstn
  }

  // ===========================================================================
  // npu_clk 侧（从口）：AXI 从口 ⇄ 各管道 `enq`/`deq`（**纯组合搬运**，本组件顶层无寄存器）
  // ===========================================================================
  // ---- AW：npu 从口（输入）→ awPipe.enq；awPipe.enq.ready → npu 从口 ready ----
  awPipe.io.enq.valid        := io.npuMem.aw.valid
  awPipe.io.enq.payload.addr  := io.npuMem.aw.payload.addr
  awPipe.io.enq.payload.id    := io.npuMem.aw.payload.id
  awPipe.io.enq.payload.len   := io.npuMem.aw.payload.len
  awPipe.io.enq.payload.size  := io.npuMem.aw.payload.size
  awPipe.io.enq.payload.burst := io.npuMem.aw.payload.burst
  awPipe.io.enq.payload.cache := io.npuMem.aw.payload.cache
  awPipe.io.enq.payload.prot  := io.npuMem.aw.payload.prot
  io.npuMem.aw.ready          := awPipe.io.enq.ready

  // ---- W：每拍一次握手；data + wstrb + wlast 一起跨 ----
  wPipe.io.enq.valid         := io.npuMem.w.valid
  wPipe.io.enq.payload.data  := io.npuMem.w.payload.data
  wPipe.io.enq.payload.strb  := io.npuMem.w.payload.strb
  wPipe.io.enq.payload.last  := io.npuMem.w.payload.last
  io.npuMem.w.ready          := wPipe.io.enq.ready

  // ---- B：bPipe.deq（npu 侧）→ npu 从口（输出）----
  io.npuMem.b.valid        := bPipe.io.deq.valid
  io.npuMem.b.payload.id   := bPipe.io.deq.payload.id
  io.npuMem.b.payload.resp := bPipe.io.deq.payload.resp
  bPipe.io.deq.ready       := io.npuMem.b.ready

  // ---- AR：npu 从口（输入）→ arPipe.enq ----
  arPipe.io.enq.valid        := io.npuMem.ar.valid
  arPipe.io.enq.payload.addr  := io.npuMem.ar.payload.addr
  arPipe.io.enq.payload.id    := io.npuMem.ar.payload.id
  arPipe.io.enq.payload.len   := io.npuMem.ar.payload.len
  arPipe.io.enq.payload.size  := io.npuMem.ar.payload.size
  arPipe.io.enq.payload.burst := io.npuMem.ar.payload.burst
  arPipe.io.enq.payload.cache := io.npuMem.ar.payload.cache
  arPipe.io.enq.payload.prot  := io.npuMem.ar.payload.prot
  io.npuMem.ar.ready          := arPipe.io.enq.ready

  // ---- R：每拍一次握手；data + rid + rresp + rlast 一起跨 ----
  io.npuMem.r.valid        := rPipe.io.deq.valid
  io.npuMem.r.payload.data := rPipe.io.deq.payload.data
  io.npuMem.r.payload.id   := rPipe.io.deq.payload.id
  io.npuMem.r.payload.resp := rPipe.io.deq.payload.resp
  io.npuMem.r.payload.last := rPipe.io.deq.payload.last
  rPipe.io.deq.ready       := io.npuMem.r.ready

  // ===========================================================================
  // cpu_clk 侧（主口）：各管道 `deq`/`enq` ⇄ AXI 主口
  // ===========================================================================
  // ---- AW：awPipe.deq → cpu 主口（输出）；cpu 主口 ready → awPipe.deq.ready ----
  io.cpuMem.aw.valid        := awPipe.io.deq.valid
  io.cpuMem.aw.payload.addr  := awPipe.io.deq.payload.addr
  io.cpuMem.aw.payload.id    := awPipe.io.deq.payload.id
  io.cpuMem.aw.payload.len   := awPipe.io.deq.payload.len
  io.cpuMem.aw.payload.size  := awPipe.io.deq.payload.size
  io.cpuMem.aw.payload.burst := awPipe.io.deq.payload.burst
  io.cpuMem.aw.payload.cache := awPipe.io.deq.payload.cache
  io.cpuMem.aw.payload.prot  := awPipe.io.deq.payload.prot
  awPipe.io.deq.ready        := io.cpuMem.aw.ready

  // ---- W：cpu 主口（输出）⇐ wPipe.deq（每拍一次握手）----
  io.cpuMem.w.valid        := wPipe.io.deq.valid
  io.cpuMem.w.payload.data := wPipe.io.deq.payload.data
  io.cpuMem.w.payload.strb := wPipe.io.deq.payload.strb
  io.cpuMem.w.payload.last := wPipe.io.deq.payload.last
  wPipe.io.deq.ready       := io.cpuMem.w.ready

  // ---- B：cpu 主口（输入）→ bPipe.enq（响应向源在 cpu 侧）----
  bPipe.io.enq.valid        := io.cpuMem.b.valid
  bPipe.io.enq.payload.id   := io.cpuMem.b.payload.id
  bPipe.io.enq.payload.resp := io.cpuMem.b.payload.resp
  io.cpuMem.b.ready         := bPipe.io.enq.ready

  // ---- AR：arPipe.deq → cpu 主口（输出）----
  io.cpuMem.ar.valid        := arPipe.io.deq.valid
  io.cpuMem.ar.payload.addr  := arPipe.io.deq.payload.addr
  io.cpuMem.ar.payload.id    := arPipe.io.deq.payload.id
  io.cpuMem.ar.payload.len   := arPipe.io.deq.payload.len
  io.cpuMem.ar.payload.size  := arPipe.io.deq.payload.size
  io.cpuMem.ar.payload.burst := arPipe.io.deq.payload.burst
  io.cpuMem.ar.payload.cache := arPipe.io.deq.payload.cache
  io.cpuMem.ar.payload.prot  := arPipe.io.deq.payload.prot
  arPipe.io.deq.ready        := io.cpuMem.ar.ready

  // ---- R：cpu 主口（输入）→ rPipe.enq（响应向源在 cpu 侧，每拍一次握手）----
  rPipe.io.enq.valid        := io.cpuMem.r.valid
  rPipe.io.enq.payload.data := io.cpuMem.r.payload.data
  rPipe.io.enq.payload.id   := io.cpuMem.r.payload.id
  rPipe.io.enq.payload.resp := io.cpuMem.r.payload.resp
  rPipe.io.enq.payload.last := io.cpuMem.r.payload.last
  io.cpuMem.r.ready         := rPipe.io.enq.ready
}
