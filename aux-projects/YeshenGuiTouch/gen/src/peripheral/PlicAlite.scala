import chisel3._
import chisel3.util._

// ===================== PLIC-Lite（sifive,plic-1.0.0 最小子集）=====================
// ⚠️ 本文件从 `NaxYeshenSoC/src/peripheral/PLIC.scala` 复制后**就地改造**（VexiiRiscv 迁移）：
//    新核**没有**内置 PLIC ⇒ 本模块把外设中断汇聚成 M/S 两条 external 线（intMExt/intSExt）。
//
// 与原版的差异（寄存器偏移/claim-complete 语义**一字未动**）：
//   ① `NDEV = 4`：**源 1 = 控制台**（`Uart16550.io.irq`，Linux DTS `interrupts = <1>`）、
//      **源 2 = LiteEth**（板级 `eth_irq`，DTS `interrupts = <2>`）、
//      **源 3 = NPU**（Y1 自研 CNN 加速器的 `irq`，DTS `interrupts = <3>`；2026-10-08 C2.2 加入）、
//      **源 4 = DMA**（Y1 通用 DMA 引擎的 `irq` = `GBL_DONE|GBL_ERR` 线或，DTS `interrupts = <4>`；
//      Y1-DMA Phase-2b 加入）。原版的 legacy UART / GPIO 两源去掉。
//   ② 输入改名：`consoleIrq`（源 1）+ `ethIrq`（源 2）+ `npuIrq`（源 3）+ `dmaIrq`（源 4）；
//      去掉 `uartIrq`/`gpioIrq`。
//   ③ 上下文不变：ctx0 = M-hart0（→ mip.MEIP）/ ctx1 = S-hart0（→ mip.SEIP）。
//
// 设计见 docs/superpowers/specs/2026-09-17-riscv-plic-design.md：
//   §3.1 寄存器图 —— 偏移已对到**第一手源码**（Linux drivers/irqchip/irq-sifive-plic.c:42-60 与
//        OpenSBI lib/utils/irqchip/plic.c:20-26，逐字一致）⇒ **不要改这些数**，改了就不兼容。
//   §3.3 网关 + D1=B（源侧用 sticky；PLIC 侧只锁存电平为 pending）
//   §3.5 地址：本模块看到的是**相对偏移**（SoC 侧已减掉基址 0xF0C0_0000），
//        故地址位宽取 22 位 —— 最大偏移 0x201004 放不进 CLINT 那样的 16 位。
// 源 id：1 = ns16550a 控制台，2 = LiteEth，3 = NPU，4 = DMA；id 0 保留（"无中断"）。
// 上下文：ctx0 = M-hart0（→ mip.MEIP）/ ctx1 = S-hart0（→ mip.SEIP）。
//
// ⚠️ 关键语义（三条，都与"静默失败"有关）：
//   ① `pending` 是**只读**的，**唯一**的清源手段是"读 claim/complete"。
//   ② 网关按"源电平 → 锁存 pending"实现：源拉高即置位。因此**源不能是持续电平**
//      （否则 claim 后下一拍被重新置起 ⇒ 中断风暴）—— 16550 的 `irq` 是"收到数据 或 THR 空"，
//      内核会清 IER/读 RBR；LiteEth 的 `eth_irq` 是 MAC 的中断电平，驱动会读 CSR 清源。
//   ③ 窗口内**未实现的偏移**一律"忽略但照样应答"（照 `ClintAlite` 的同款处理）：
//      否则一次误访问会把 MMIO FSM 卡死。
class PlicAXILiteIO extends Bundle {
  val awaddr  = Input(UInt(22.W))
  val awvalid = Input(Bool())
  val awready = Output(Bool())
  val wdata   = Input(UInt(32.W))
  val wstrb   = Input(UInt(4.W))
  val wvalid  = Input(Bool())
  val wready  = Output(Bool())
  val bresp   = Output(UInt(2.W))
  val bvalid  = Output(Bool())
  val bready  = Input(Bool())
  val araddr  = Input(UInt(22.W))
  val arvalid = Input(Bool())
  val arready = Output(Bool())
  val rdata   = Output(UInt(32.W))
  val rresp   = Output(UInt(2.W))
  val rvalid  = Output(Bool())
  val rready  = Input(Bool())
}

class PlicAliteIO extends Bundle {
  // ⚠️ 不显式声明 clock/reset：与 CLINT/UART/GPIO **同款写法**，用 SoC 的隐式 clock/reset。
  val axi        = new PlicAXILiteIO
  // 源线（"事件已发生"的电平语义；网关负责锁存成 pending）
  val consoleIrq = Input(Bool())   // 源 1：ns16550a 控制台（`Uart16550.io.irq`）
  val ethIrq     = Input(Bool())   // 源 2：LiteEth（板级 `eth_irq`）
  val npuIrq     = Input(Bool())   // 源 3：NPU（`NpuTop.irq`，电平保持，软复位清源）
  val dmaIrq     = Input(Bool())   // 源 4：DMA（`DmaEngine.irq` = GBL_DONE|GBL_ERR，电平保持，w1c CH_STATUS 清源）
  val ctpIrq     = Input(Bool())   // 源 5：CTP_INT（GT911，active-low 经板级反相后的电平）
  // 两个上下文的 target 线
  val meip_o     = Output(Bool())  // ctx0 → 核 `int_m_external`
  val seip_o     = Output(Bool())  // ctx1 → 核 `int_s_external`
}

class PlicAlite extends Module {
  override def desiredName: String = "PlicAlite"
  val io = IO(new PlicAliteIO)

  private val NDEV = 5   // 源 id 1..5（1=ns16550a 控制台 / 2=LiteEth / 3=NPU / 4=DMA / 5=CTP_INT）
  private val NCTX = 2   // ctx0=M / ctx1=S

  // ---- 偏移（PLIC 1.0.0 规范，已对到 Linux/OpenSBI 源码）----
  private val PRIORITY_BASE  = 0x0000
  private val PENDING_BASE   = 0x1000
  private val ENABLE_BASE    = 0x2000
  private val ENABLE_STRIDE  = 0x0080
  private val CONTEXT_BASE   = 0x200000
  private val CONTEXT_STRIDE = 0x1000
  private val CONTEXT_THRESH = 0x0000
  private val CONTEXT_CLAIM  = 0x0004

  private def offAddr(x: Int): UInt = x.U(22.W)
  private def enableAddr(c: Int): UInt  = (ENABLE_BASE + c * ENABLE_STRIDE).U(22.W)
  private def threshAddr(c: Int): UInt  = (CONTEXT_BASE + c * CONTEXT_STRIDE + CONTEXT_THRESH).U(22.W)
  private def claimAddr(c: Int): UInt   = (CONTEXT_BASE + c * CONTEXT_STRIDE + CONTEXT_CLAIM).U(22.W)
  private def priorityAddr(i: Int): UInt = (PRIORITY_BASE + i * 4).U(22.W)

  // ===================== 寄存器 =====================
  private val priority = RegInit(VecInit(Seq.fill(NDEV + 1)(0.U(32.W))))          // [0] 保留
  private val enable   = RegInit(VecInit(Seq.fill(NCTX)(0.U((NDEV + 1).W))))      // bit(i) = 源 i
  private val thresh   = RegInit(VecInit(Seq.fill(NCTX)(0.U(32.W))))

  // ===================== 网关：pending（唯一清源手段 = 读 claim）=====================
  private val pending = RegInit(VecInit(Seq.fill(NDEV + 1)(false.B)))             // [0] 恒 false

  private val srcIn = Wire(Vec(NDEV + 1, Bool()))
  srcIn(0) := false.B
  srcIn(1) := io.consoleIrq
  srcIn(2) := io.ethIrq
  srcIn(3) := io.npuIrq
  srcIn(4) := io.dmaIrq
  srcIn(5) := io.ctpIrq

  // 源线是"事件已发生"的电平 ⇒ 只锁存、不做边沿检测（边沿由源侧/驱动读 CSR 保证）。
  for (i <- 1 to NDEV) {
    when(srcIn(i)) { pending(i) := true.B }
  }
  pending(0) := false.B

  // ===================== target 线 =====================
  // line[ctx] = OR_i ( pending[i] && enable[ctx][i] && priority[i] > threshold[ctx] )
  private val line = Wire(Vec(NCTX, Bool()))
  for (c <- 0 until NCTX) {
    line(c) := (1 to NDEV).map { i =>
      pending(i) && enable(c)(i) && priority(i) > thresh(c)
    }.reduce(_ || _)
  }
  io.meip_o := line(0)
  io.seip_o := line(1)

  // ===================== 写通道 =====================
  // AW/W 可能同拍（单元 tb）也可能分拍（SoC 的 MMIO FSM 是 sAW→sW）⇒ 两个 pend 位解耦（照 CLINT）。
  private val bValid = RegInit(false.B)
  private val awPend = RegInit(false.B)
  private val awReg  = RegInit(0.U(22.W))
  private val wPend  = RegInit(false.B)
  private val wData  = RegInit(0.U(32.W))

  io.axi.awready := !bValid
  io.axi.wready  := !bValid
  io.axi.bresp   := 0.U     // OKAY
  io.axi.bvalid  := bValid

  when(io.axi.awvalid && io.axi.awready) { awPend := true.B; awReg := io.axi.awaddr }
  when(io.axi.wvalid  && io.axi.wready)  { wPend  := true.B; wData := io.axi.wdata  }

  when(awPend && wPend) {
    for (i <- 1 to NDEV) {
      when(awReg === priorityAddr(i)) { priority(i) := wData }
    }
    for (c <- 0 until NCTX) {
      when(awReg === enableAddr(c)) { enable(c) := wData(NDEV, 0) }
      when(awReg === threshAddr(c)) { thresh(c) := wData }
      // claim/complete 的**写** = complete：单 hart 下无副作用（只做记录；
      // 真正的"处理中掩蔽"靠 threshold）—— spec §3.1。
    }
    // 窗口内未实现的偏移：忽略，但**照样应答**（否则 MMIO FSM 会被卡死）
    awPend := false.B
    wPend  := false.B
    bValid := true.B
  }
  when(io.axi.bready && bValid) { bValid := false.B }

  // ===================== claim 候选（组合）=====================
  // 选"已使能 ∧ pending ∧ priority > threshold"的源；**优先级高者胜，并列取 id 小者**
  // （PLIC 1.0.0 对并列未作规定，实现自由）；没有候选则返回 0。
  // ⚠️ 不要用 Scala 的 `Range.exists` 把 Chisel 的 Bool 当 Scala Boolean —— 编译不过。
  // ⚠️ 这里**必须按 NDEV 泛化**：改成"遍历源、取优先级最高、并列保留 id 小者"：
  //    顺序 when + 严格 `>` 覆盖 ⇒ 后面的源只有**优先级更高**才顶掉前面的，并列自然保留小 id。
  private val claimCand = Wire(Vec(NCTX, UInt(3.W)))
  private val claimFire = Wire(Vec(NCTX, Bool()))
  for (c <- 0 until NCTX) {
    // 可达 OH（下标 i-1 ↔ 源 i）：pending ∧ enable ∧ priority > threshold
    val reachOH = VecInit((1 to NDEV).map { i =>
      pending(i) && enable(c)(i) && (priority(i) > thresh(c))
    }).asUInt
    // 排序键 = Cat(priority, ~id)：优先级大者胜；并列时 id 小者胜（~id 更大）。
    // ⚠️ 必须用"一次归约"而不是"顺序 when 逐源覆盖"：后者里 `when(reach && cand === 0.U)` 会读
    //    同一个 when 链正在赋值的 Wire ⇒ FIRRTL 报 **combinational cycle**（实测 elaboration 失败）。
    val keys = VecInit((1 to NDEV).map { i =>
      Mux(reachOH(i - 1), Cat(priority(i), (~i.U(3.W)).asUInt), 0.U(35.W))
    })
    val maxKey = keys.reduceTree((a, b) => Mux(a >= b, a, b))
    val winOH  = VecInit((1 to NDEV).map(i => reachOH(i - 1) && keys(i - 1) === maxKey)).asUInt
    claimCand(c) := Mux1H(winOH, VecInit((1 to NDEV).map(i => i.U(3.W))))
    claimFire(c) := claimCand(c) =/= 0.U
  }

  // ===================== 读通道 =====================
  // ⚠️ 相位必须是："AR 拍锁存 ⇒ 下一拍 rvalid+rdata"（照 `ClintAlite`）。
  private val rValid = RegInit(false.B)
  private val rData  = RegInit(0.U(32.W))
  io.axi.arready := true.B
  io.axi.rvalid  := rValid
  io.axi.rdata   := rData
  io.axi.rresp   := 0.U

  when(io.axi.arvalid && io.axi.arready) {
    rData := MuxCase(0.U(32.W), Seq(
      (io.axi.araddr === offAddr(PENDING_BASE)) -> Cat(0.U((32 - (NDEV + 1)).W), pending.asUInt),
      (io.axi.araddr === priorityAddr(1))       -> priority(1),
      (io.axi.araddr === priorityAddr(2))       -> priority(2),
      (io.axi.araddr === priorityAddr(3))       -> priority(3),
      (io.axi.araddr === priorityAddr(4))       -> priority(4),
      (io.axi.araddr === priorityAddr(5))       -> priority(5),
      (io.axi.araddr === enableAddr(0))         -> enable(0),
      (io.axi.araddr === enableAddr(1))         -> enable(1),
      (io.axi.araddr === threshAddr(0))         -> thresh(0),
      (io.axi.araddr === threshAddr(1))         -> thresh(1),
      (io.axi.araddr === claimAddr(0))          -> claimCand(0),
      (io.axi.araddr === claimAddr(1))          -> claimCand(1)
    ))
    rValid := true.B
    // ★ claim 的副作用：读走即清该源的 pending。放在网关置位**之后** ⇒ 同拍时清位优先
    //   （源仍拉高则会下一拍重新置起 —— 那正是"电平源自风暴"的形态，见文件头 ②）。
    //   ⚠️ 索引必须用 `claimCand(c)` 的**整宽**（3 bit）：NDEV 加到 4 后源号 4 = 3'b100，
    //     原来切成低 2 位会把 id 4 清成 pending(0)（恒 false）⇒ 源 4 的 pending **永远清不掉**。
    when(io.axi.araddr === claimAddr(0) && claimFire(0)) { pending(claimCand(0)) := false.B }
    when(io.axi.araddr === claimAddr(1) && claimFire(1)) { pending(claimCand(1)) := false.B }
  }.elsewhen(io.axi.rready) {
    rValid := false.B
  }

  // ===================== 协议断言（把不变量钉住，不靠注释）=====================
  for (c <- 0 until NCTX) {
    when(claimFire(c)) {
      assert(pending(claimCand(c)),
        "PLIC: claim must return a source that is actually pending")
    }
  }
  assert(!pending(0), "PLIC: source id 0 is reserved and must never be pending")
  when(io.axi.bvalid) { assert(bValid, "PLIC: bvalid must come from the registered bValid") }
}
