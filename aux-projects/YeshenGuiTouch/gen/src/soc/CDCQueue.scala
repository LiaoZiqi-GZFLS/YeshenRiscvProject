import chisel3._
import chisel3.util._

// ===================== 单向跨域传输（4相电平握手） =====================
// 源域(sClk) → 目的域(dClk)，2 级同步器 + 电平握手
// req(电平) / ack(电平) 协议: 任何时钟频率比都不会丢失握手
//
// 源域: enq.fire 后 sValid=1 并保持，直到 ack 同步回来才清 0
// 目的域: 同步 sValid，锁存数据，deq.fire 后 dAck=1 并保持，
//         直到 req 下降沿（validSync 变 0）才清 dAck
class CDCPipe[T <: Data](gen: T) extends Module {
  val io = IO(new Bundle {
    val sClk  = Input(Clock())
    val sRstn = Input(Bool())
    val enq   = Flipped(Decoupled(gen.cloneType))

    val dClk  = Input(Clock())
    val dRstn = Input(Bool())
    val deq   = Decoupled(gen.cloneType)
  })

  // ack 电平输出（跨域到源域，必须先定义供源域引用）
  val dAckOut = IO(Output(Bool()))

  // ==================== 源域 (sClk) ====================
  val sData  = withClockAndReset(io.sClk, !io.sRstn) { Reg(gen.cloneType) }
  val sValid = withClockAndReset(io.sClk, !io.sRstn) { RegInit(false.B) }
  val ackSync1 = withClockAndReset(io.sClk, !io.sRstn) { RegInit(false.B) }
  val ackSync2 = withClockAndReset(io.sClk, !io.sRstn) { RegInit(false.B) }

  ackSync1 := dAckOut   // 目的域 ack 电平（跨域，由下面同步器采样）
  ackSync2 := ackSync1

  io.enq.ready := !sValid && !ackSync2
  when(io.enq.fire) {
    sData := io.enq.bits
    sValid := true.B
  }.elsewhen(ackSync2) {
    // ack 电平同步回来 → 清除 req；等待 ack 也清除后才允许新事务
    sValid := false.B
  }

  // ==================== 目的域 (dClk) ====================
  val validSync1 = withClockAndReset(io.dClk, !io.dRstn) { RegInit(false.B) }
  val validSync2 = withClockAndReset(io.dClk, !io.dRstn) { RegInit(false.B) }
  val dData    = withClockAndReset(io.dClk, !io.dRstn) { Reg(gen.cloneType) }
  val dPending = withClockAndReset(io.dClk, !io.dRstn) { RegInit(false.B) }
  val dAck     = withClockAndReset(io.dClk, !io.dRstn) { RegInit(false.B) }

  validSync1 := sValid
  validSync2 := validSync1

  // 数据在 req 上升沿锁存（dPending 未置位时）
  when(validSync2 && !dPending) {
    dData := sData
    dPending := true.B
  }.elsewhen(!validSync2) {
    // req 已清除 → 复位 pending 和 ack
    dPending := false.B
    dAck := false.B
  }

  io.deq.valid := dPending
  io.deq.bits := dData

  // ack: deq.fire 后置位并保持电平，直到 req 下降沿
  when(io.deq.fire) {
    dAck := true.B
  }

  dAckOut := dAck
}

// ===================== 多未完成跨域 FIFO（Y1-DMA Phase-0）=====================
// 为什么需要它（★ Phase-0 承重件，spec §3.1 / plan T0.2）：
//   `CDCPipe` 是**电平式四相握手**，**一次只搬一份**：一份数据从 `enq.fire` 到"源域看到 ack 撤
//   req、目的域 `dPending` 落回、`enq.ready` 重新拉高"要走完一个完整往返（实测 ≥ 6 个 dClk
//   + 4 个 sClk）⇒ 用它做每条通道的唯一通路时，**桥的吞吐被钉死在"32 B / 一次往返"**，
//   而且**每笔都必须等上一笔撤干净**（= 单未完成）。
//
// 本模块把"一次一份"换成"**FIFO 攒拍 + 多道并走**"，**`CDCPipe` 一字未改**：
//   · 源域一个同步环形 FIFO（`depth` 深）攒拍（`io.enq` 不再被握手往返卡住）；
//   · 中间 **`lanes` 条独立的 `CDCPipe`**，派发按**轮转顺序**（第 i 个字走第 i mod lanes 条）；
//   · 目的域一个同步环形 FIFO（`depth` 深）收拍，按**同一轮转顺序**取回；
//   ⇒ 稳态吞吐 ≈ `lanes` × 单条 `CDCPipe`，且目的域**攒着多份**可以独立地背靠背消费。
//
// ⚠️ 顺序（in-order）靠两条纪律，不是靠运气：
//   ① **不跳道**：第 L 道没空（`enq.ready` 低）就**等**，绝不许提前用第 L+1 道 —— 否则目的域
//      按轮转取回时就会把第 L+1 个字当成第 L 个（顺序错乱且不会报错）；
//   ② 每条 `CDCPipe` 一次只挂 1 份（`CDCPipe` 的 `enq.ready` 天然如此），所以"轮转序号
//      源域/目的域各自 +1"始终同步，不需要把序号跨域传过去。
//
// `lanes = 1 && depth = 1` ⇒ **逐字退化成现状的单未完成形态**（负对照 NC6 就把这两档打成 1）。
//
// 复位极性沿用 `CDCPipe` 的约定：`sRstn`/`dRstn` **低有效**（内部 `!io.xxxRstn`），
// 所以调用方（`DDR3Bridge`）在 axi 侧必须传 `!reset.asBool`，ddr 侧传 `io.ddr_rstn`。
class CdcFifo[T <: Data](gen: T, lanes: Int, depth: Int) extends Module {
  require(lanes >= 1 && isPow2(lanes), "lanes 必须是 2 的幂（轮转派发要按位取模）")
  require(depth >= 1 && isPow2(depth), "depth 必须是 2 的幂（环形队列要按掩码取模）")

  private val IW = math.max(1, log2Ceil(depth))      // 环形队列下标位宽
  private val LW = math.max(1, log2Ceil(lanes))      // 轮转道号位宽
  private val CW = math.max(1, log2Ceil(depth + 1))  // 占用计数位宽（0..depth）

  val io = IO(new Bundle {
    val sClk  = Input(Clock())
    val sRstn = Input(Bool())
    val enq   = Flipped(Decoupled(gen.cloneType))
    val sOcc  = Output(UInt(CW.W))                    // 源域队列占用（观察量）

    val dClk  = Input(Clock())
    val dRstn = Input(Bool())
    val deq   = Decoupled(gen.cloneType)
    val dOcc  = Output(UInt(CW.W))                    // 目的域队列占用（观察量）
  })

  // ---------- 中间：`lanes` 条原样的 `CDCPipe` ----------
  val pipes = Seq.fill(lanes)(Module(new CDCPipe(gen.cloneType)))
  for (p <- pipes) {
    p.io.sClk := io.sClk; p.io.sRstn := io.sRstn
    p.io.dClk := io.dClk; p.io.dRstn := io.dRstn
  }
  private val laneEnqReady = VecInit(pipes.map(_.io.enq.ready))
  private val laneDeqValid = VecInit(pipes.map(_.io.deq.valid))
  private val laneDeqBits  = VecInit(pipes.map(_.io.deq.bits))

  // ---------- 源域：环形 FIFO + 轮转派发 ----------
  val sMem   = withClockAndReset(io.sClk, !io.sRstn) { Reg(Vec(depth, gen.cloneType)) }
  val sHead  = withClockAndReset(io.sClk, !io.sRstn) { RegInit(0.U(IW.W)) }
  val sCount = withClockAndReset(io.sClk, !io.sRstn) { RegInit(0.U(CW.W)) }
  val sLane  = withClockAndReset(io.sClk, !io.sRstn) { RegInit(0.U(LW.W)) }

  private val sMask = (depth - 1).U
  private val lMask = (lanes - 1).U                                   // 道号取模掩码（lanes=1 时恒 0）
  private val sRdIdx = (sHead & sMask)(IW - 1, 0)                       // 出队下标 = head
  private val sWrIdx = ((sHead + sCount) & sMask)(IW - 1, 0)            // 入队下标 = head + 占用

  io.enq.ready := sCount =/= depth.U
  for ((p, i) <- pipes.zipWithIndex) {
    p.io.enq.valid := (sCount =/= 0.U) && (sLane === i.U)               // ★ 不跳道：只喂轮到的这一条
    p.io.enq.bits  := sMem(sRdIdx)
  }
  private val sEnqFire = io.enq.fire
  private val sDisFire = (sCount =/= 0.U) && laneEnqReady(sLane)

  when(sEnqFire) { sMem(sWrIdx) := io.enq.bits }
  sCount := sCount + Mux(sEnqFire, 1.U, 0.U) - Mux(sDisFire, 1.U, 0.U)
  // ⚠️ 道号必须**按 `lanes` 取模**：`LW` 在 `lanes=1` 时只能给 1 位，直接 `+1` 会走到 1 ⇒
  //    没有任何一条道命中 `sLane === i.U` ⇒ 源队列永不排空 = **挂死**。
  //    （这是 NC6 负对照当场抓出来的：把 LANES/DEPTH 打成 1 时旧写法在第一笔就卡死。）
  when(sDisFire) { sHead := sHead + 1.U; sLane := (sLane + 1.U) & lMask }
  io.sOcc := sCount

  // ---------- 目的域：轮转回取 + 环形 FIFO ----------
  val dMem   = withClockAndReset(io.dClk, !io.dRstn) { Reg(Vec(depth, gen.cloneType)) }
  val dTail  = withClockAndReset(io.dClk, !io.dRstn) { RegInit(0.U(IW.W)) }
  val dCount = withClockAndReset(io.dClk, !io.dRstn) { RegInit(0.U(CW.W)) }
  val dLane  = withClockAndReset(io.dClk, !io.dRstn) { RegInit(0.U(LW.W)) }
  // `deq.valid` 是**电平**（见 `DDR3Bridge` 文件头约束 4）⇒ 每条道各带一个"本份已取用"标志
  val dTaken = withClockAndReset(io.dClk, !io.dRstn) { RegInit(VecInit(Seq.fill(lanes)(false.B))) }

  private val dMask = (depth - 1).U
  private val dRdIdx = (dTail & dMask)(IW - 1, 0)
  private val dWrIdx = ((dTail + dCount) & dMask)(IW - 1, 0)

  private val dCollect = (dCount =/= depth.U) && laneDeqValid(dLane) && !dTaken(dLane)
  for ((p, i) <- pipes.zipWithIndex) {
    // 只放轮到的这一条；且必须有两件事同时成立：本份没取过 + 目的队列收得下
    p.io.deq.ready := (dLane === i.U) && laneDeqValid(i) && !dTaken(i) && (dCount =/= depth.U)
    when(!p.io.deq.valid) { dTaken(i) := false.B }                      // 呈现撤销 ⇒ 允许取下一份
  }
  when(dCollect) {
    dMem(dWrIdx) := laneDeqBits(dLane)
    dLane := (dLane + 1.U) & lMask                                     // 同源域：道号按 lanes 取模
    dTaken(dLane) := true.B
  }
  io.deq.valid := dCount =/= 0.U
  io.deq.bits := dMem(dRdIdx)
  private val dDeqFire = io.deq.fire
  dCount := dCount + Mux(dCollect, 1.U, 0.U) - Mux(dDeqFire, 1.U, 0.U)
  when(dDeqFire) { dTail := dTail + 1.U }
  io.dOcc := dCount
}
