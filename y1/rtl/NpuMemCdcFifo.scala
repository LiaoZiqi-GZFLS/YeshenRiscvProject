import spinal.core._
import spinal.lib._

/** NpuMemCdc 专用：**多未完成跨域 FIFO**（`CdcPipeSp` 的 lanes/depth 包装）。
  *
  * 动机见 `NpuMemCdc.scala` 文件头：旧桥是**单 outstanding + W/R 每拍一次 4 相握手**，
  * 一笔 32 B = 1 次 AR 往返 + 4 次 R 拍往返。本类把「一次一份」换成
  * 「源域环形 FIFO 攒拍 + `lanes` 条独立四相管道轮转并发 + 目的域环形 FIFO」——
  * 稳态吞吐 ≈ `lanes × 单管`，且目的域可背靠背消费。
  *
  * 顺序（in-order）靠两条纪律（与 `src/soc/CDCQueue.scala` 的 `CdcFifo` 同口径）：
  *   ① **不跳道**：轮到的道没空就等，绝不提前用下一道；
  *   ② 每条 `CdcPipeSp` 一次只挂 1 份（其 `enq.ready` 天然如此）⇒ 两域轮转序号始终同步。
  *
  * `CdcPipeSp` 的 `deq.valid` 是**一笔一个脉冲**（`dMask`），本 FIFO 依赖这一点做
  * 「采集一次」判定；`dTaken` 只在本道呈现撤销后清零。
  *
  * 复位：`sRstn`/`dRstn` 低有效，与 `CdcPipeSp` 同极性。
  */
class NpuMemCdcFifo[T <: Data](gen: HardType[T], lanes: Int, depth: Int,
                               defName: String = "", pipeDefName: String = "") extends Component {
  require(lanes >= 1 && isPow2(lanes), "lanes 必须是 2 的幂")
  require(depth >= 1 && isPow2(depth), "depth 必须是 2 的幂")
  if (defName != "") setDefinitionName(defName)

  private val IW = scala.math.max(1, log2Up(depth))
  private val LW = scala.math.max(1, log2Up(lanes))
  private val CW = scala.math.max(1, log2Up(depth + 1))

  val io = new Bundle {
    val sClk  = in Bool()
    val sRstn = in Bool()
    val enq   = slave Stream(gen)
    val dClk  = in Bool()
    val dRstn = in Bool()
    val deq   = master Stream(gen)
  }

  val sCd = ClockDomain(io.sClk, io.sRstn, config = ClockDomainConfig(resetKind = ASYNC, resetActiveLevel = LOW))
  val dCd = ClockDomain(io.dClk, io.dRstn, config = ClockDomainConfig(resetKind = ASYNC, resetActiveLevel = LOW))

  // ---- lanes 条原样的 CdcPipeSp ----
  val pipes = Seq.fill(lanes)(new CdcPipeSp(gen, defName = pipeDefName))
  for (p <- pipes) {
    p.io.sClk := io.sClk; p.io.sRstn := io.sRstn
    p.io.dClk := io.dClk; p.io.dRstn := io.dRstn
  }
  val laneEnqReady   = Vec(pipes.map(_.io.enq.ready))
  val laneDeqValid   = Vec(pipes.map(_.io.deq.valid))
  val laneDeqPayload = Vec(pipes.map(_.io.deq.payload))

  // ================= 源域：环形 FIFO + 轮转派发 =================
  val sMem   = sCd(Vec.fill(depth)(Reg(gen)))
  val sHead  = sCd(RegInit(U(0, IW bits)))
  val sCount = sCd(RegInit(U(0, CW bits)))
  val sLane  = sCd(RegInit(U(0, LW bits)))

  private val sMask = U(depth - 1, CW bits)
  private val lMask = U(lanes - 1, LW bits)
  val sRdIdx = sHead
  val sWrIdx = ((sHead.resize(CW) + sCount) & sMask).resize(IW)

  io.enq.ready := sCount =/= U(depth, CW bits)
  for ((p, i) <- pipes.zipWithIndex) {
    p.io.enq.valid   := (sCount =/= U(0, CW bits)) && (sLane === U(i, LW bits))
    p.io.enq.payload := sMem(sRdIdx)
  }
  val sEnqFire = io.enq.fire
  val sDisFire = (sCount =/= U(0, CW bits)) && laneEnqReady(sLane)

  when(sEnqFire) { sMem(sWrIdx) := io.enq.payload }
  sCount := sCount + Mux(sEnqFire, U(1, CW bits), U(0, CW bits)) -
                    Mux(sDisFire, U(1, CW bits), U(0, CW bits))
  when(sDisFire) { sHead := sHead + 1; sLane := (sLane + 1) & lMask }

  // ================= 目的域：轮转回取 + 环形 FIFO =================
  val dMem   = dCd(Vec.fill(depth)(Reg(gen)))
  val dTail  = dCd(RegInit(U(0, IW bits)))
  val dCount = dCd(RegInit(U(0, CW bits)))
  val dLane  = dCd(RegInit(U(0, LW bits)))
  val dTaken = Vec.fill(lanes)(dCd(RegInit(False)))

  private val dMask = U(depth - 1, CW bits)
  val dRdIdx = dTail
  val dWrIdx = ((dTail.resize(CW) + dCount) & dMask).resize(IW)

  val dCollect = (dCount =/= U(depth, CW bits)) && laneDeqValid(dLane) && !dTaken(dLane)
  for ((p, i) <- pipes.zipWithIndex) {
    p.io.deq.ready := (dLane === U(i, LW bits)) && laneDeqValid(i) &&
                      !dTaken(i) && (dCount =/= U(depth, CW bits))
    when(!p.io.deq.valid) { dTaken(i) := False }
  }
  when(dCollect) {
    dMem(dWrIdx) := laneDeqPayload(dLane)
    dLane := (dLane + 1) & lMask
    dTaken(dLane) := True
  }
  io.deq.valid   := dCount =/= U(0, CW bits)
  io.deq.payload := dMem(dRdIdx)
  val dDeqFire = io.deq.fire
  dCount := dCount + Mux(dCollect, U(1, CW bits), U(0, CW bits)) -
                    Mux(dDeqFire, U(1, CW bits), U(0, CW bits))
  when(dDeqFire) { dTail := dTail + 1 }
}
