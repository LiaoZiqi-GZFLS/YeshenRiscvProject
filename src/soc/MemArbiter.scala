import chisel3._
import chisel3.util._
// ⚠️ 与 `src/soc/DDR3Bridge.scala` 同款：`import chisel3.util._` 会把 `circt` 解析到
//    `chisel3.util.circt` ⇒ 必须用 `_root_.` 前缀。
import _root_.circt.stage.{ChiselStage, FirtoolOption}
import chisel3.stage.ChiselGeneratorAnnotation

// ============================================================================
// ★★ Y1-DMA **Phase-1**（2026-10-13）：**真仲裁器**（合并点 §3.5 的主人选择器）
// ============================================================================
// 上游：`docs/superpowers/specs/2026-10-13-y1-soc-dma-engine-design.md`（§3.1 四相、§5 D4、§6 R2）、
//       `docs/superpowers/plans/2026-10-13-y1-soc-dma-engine.md` **Phase 1（T1.1）**。
//
// 本模块是**纯调度逻辑**（不含任何 AXI 通道）：给出一组"类（class）的请求"，选出本拍该授予谁。
// 由调用方（`YeshenSocGlue` §3.5 合并点 / §4 主口 mux）负责：
//   · `req(c)`  = 第 c 类**有在等的请求**（组合）；
//   · `free`    = 总线**空闲**（当前没有一笔事务在飞，`owner === IDLE`）；
//   · `pick`/`pickV` = 本拍授予的类（`pickV = free && 有人请求`）；
//   · 调用方把 `pick` 锁进自己的 `owner` 寄存器并**持有到事务完成**（`rlast` / `b`）。
// ⇒ 本模块**无阻塞**：只要 `free` 一到，`pickV` 就立刻为真（不插空拍、不等固定时隙）。
//
// ---------------------------------------------------------------------------
// 仲裁策略（冻结）：**加权轮转（WRR）+ 老化提升（aging anti-starvation）**
// ---------------------------------------------------------------------------
// ① **配额（优先级的一种量化表达）**：每个类给一个权重 `WEIGHTS(c)`。轮转指针 `turn` 每
//    "服务完一个类的配额"就前进到下一个**权重非零**且**有请求**的类。权重给出稳态配额：
//    例如 `Seq(2,1,1)` ⇒ 持续争用时 CPU 组:NPU:DMA ≈ 2:1:1（= spec §6 R2 要的"优先级/配额"）。
//    ⚠️ **权重 0 = 该类结构性不可达**（既不进轮转、也不参与老化提升）—— 这正是负对照要打的那一处。
// ② **防饿死（老化）**：每个类一个 `age(c)` 计数器：**每当"它想要 + 总线空闲、却没被授予"（= 错过
//    一次授权机会）就 +1**（饱和）；被授予 / 撤销请求则清零。一旦 `age(c) >= AGE_MAX`，该类进入
//    **starving** 集合，**压过配额**直接当选（多个 starving 时取 `age` **最大**者）。
//    ⚠️ 计数口径是**授权机会**（`free && req && !granted`），**不是**每一拍 —— 否则"总线正忙着
//    （free=0）"也会给所有在等的类加计，把刚服务过的类一起推成 starving ⇒ 类号小者靠 tie-break
//    垄断，低优先类反而**真的被饿死**（本轮开发实测到这个反直觉的坑，已改成机会口径）。
//    ⇒ **连续有请求的类，最迟在 `AGE_MAX + 1` 次授权机会内必得一次授予**（有界等待；折算成拍数
//    上界 = `AGE_MAX × 单笔事务上限`）。
// ③ 类内优先级**不在这里**：调用方在一类内部再按固定优先级挑子通道（CPU 组：LSU 写 > LSU 读 >
//    Fetch 读；NPU：写 > 读）。本模块只管"类之间"。
// ④ 单主人不变性：只有一个类有请求时，`pick` 恒指着它、`age` 恒 0 ⇒ 行为与"直接连过去"**逐拍同值**
//    （单主人回归判据钉的就是这条）。
//
// ---------------------------------------------------------------------------
// 加第 6 个主人（Phase-2 的 DMA 引擎）**只是一个参数**
// ---------------------------------------------------------------------------
// 类数 `N`、每类权重 `WEIGHTS`、老化阈值 `AGE_MAX` 都是构造参数：
//   · Phase-1（本相）：`N = 3`，类 = {CPU 组, NPU, DMA 预留}（DMA 的 `req` 暂时钉 0，
//     `WEIGHTS(2) = 1` 已把"它有机会被选中"预置好）；
//   · Phase-2：把 DMA 引擎的请求接到 `req(2)`（或再加一个类 ⇒ `N = 4`），**本模块一字不改**，
//     只在调用方加一个 `req` 连线 + `owner` 多一个状态。
// ============================================================================

class MemArbiter(val N: Int, val WEIGHTS: Seq[Int], val AGE_MAX: Int) extends Module {
  require(N >= 1, s"MemArbiter: N 必须 >= 1（给了 $N）")
  require(WEIGHTS.length == N, s"MemArbiter: WEIGHTS 长度 ${WEIGHTS.length} != N=$N")
  require(WEIGHTS.forall(_ >= 0), s"MemArbiter: WEIGHTS 不许为负：$WEIGHTS")
  require(WEIGHTS.exists(_ > 0), s"MemArbiter: 至少一个类权重 > 0（否则永远不授予）")
  require(AGE_MAX >= 1, s"MemArbiter: AGE_MAX 必须 >= 1（给了 $AGE_MAX）")

  val CW = math.max(1, log2Ceil(N))                       // 类号位宽
  val BW = math.max(1, log2Ceil(WEIGHTS.max + 1))         // 配额计数器位宽
  val AW = math.max(1, log2Ceil(AGE_MAX + 1))             // 老化计数器位宽
  val ACAP = (1 << AW) - 1                                // 老化饱和值（>= AGE_MAX）

  val io = IO(new Bundle {
    val req   = Input(Vec(N, Bool()))   // 第 c 类有在等的请求
    val free  = Input(Bool())           // 总线空闲（可以授予）
    val pick  = Output(UInt(CW.W))      // 本拍选中的类
    val pickV = Output(Bool())          // 本拍确实授予（= free && 有人请求）
    // 只读观察口（只读、不影响功能；给单元装置与 PnR 悬空裁剪用）
    val dbgTurn  = Output(UInt(CW.W))
    val dbgWait  = Output(Vec(N, UInt(AW.W)))
    val dbgStarve = Output(UInt(N.W))
  })

  // ---- 权重 0 的类是**结构性不可达**的（轮转跳过 + 老化不提升）----
  private val wVec   = VecInit(WEIGHTS.map(w => w.U(BW.W)))
  private val wZero  = VecInit(WEIGHTS.map(w => (w == 0).B))
  private val reqE   = VecInit((0 until N).map(c => io.req(c) && !wZero(c)))
  private val anyReq = reqE.asUInt.orR

  // ---- 轮转状态：当前类 + 该类本轮的剩余配额 ----
  private val turn   = RegInit(0.U(CW.W))
  private val budget = RegInit(0.U(BW.W))

  // 本拍"轮到 turn 且它还有配额且它有请求" ⇒ 继续服务 turn（吃一口配额）。
  private val turnReady = reqE(turn) && (budget =/= 0.U)

  // turn 之后（环向）第一个有请求的**可达**类：t = turn + (k+1)，满 N 就减一圈（t < 2N ⇒ 一次减法够）。
  private val afterIdx = VecInit((0 until N).map { k =>
    val t = turn +& (k + 1).U
    Mux(t >= N.U, t - N.U, t)(CW - 1, 0)
  })
  private val afterReq = VecInit(afterIdx.map(i => reqE(i)))
  private val nextIdx  = afterIdx(PriorityEncoder(afterReq))

  private val wrrIdx = Mux(turnReady, turn, nextIdx)

  // ---- 防饿死：老化计数器（**授权机会**口径）+ starving 提升 ----
  private val age = RegInit(VecInit(Seq.fill(N)(0.U(AW.W))))
  private val starveV = VecInit((0 until N).map(c => reqE(c) && (age(c) >= AGE_MAX.U)))
  private val starveAny = starveV.asUInt.orR
  // 多个类同时 starving 时取 `age` **最大**者（tie 取类号小者）—— 取"最久的那个"才是防饿死；
  // 若取类号小者，先被服务的类会在下一段忙碌里重新攒满 age，把低优先类**永久**压在 tie-break 下。
  private val starveIdx = (0 until N).map(c => c.U(CW.W)).reduceLeft { (best, cur) =>
    Mux(starveV(cur) && ((age(cur) > age(best)) || !starveV(best)), cur, best)
  }

  val pickIdx = Mux(starveAny, starveIdx, wrrIdx)

  io.pick    := pickIdx
  io.pickV   := io.free && anyReq
  io.dbgTurn := turn
  io.dbgWait := age
  io.dbgStarve := starveV.asUInt

  // ---- 授出时更新轮转/配额 ----
  private val grant = io.free && anyReq
  when(grant) {
    when(starveAny) {
      // 老化提升：直接服务最老的那个类，并把它的配额清零（下一拍回到 normal 轮转）
      turn   := starveIdx
      budget := 0.U
    }.elsewhen(turnReady) {
      budget := budget - 1.U                      // 继续在同一类里吃配额
    }.otherwise {
      turn   := nextIdx                           // 换类，并装载该类的配额
      budget := wVec(nextIdx) - 1.U
    }
  }

  // ---- 老化计数器：**错过的授权机会**（free && req && !granted）才 +1（饱和）；
  //      被服务 / 撤销请求 ⇒ 清零。（只在 free 的拍上加，见文件头 ② 的⚠️）----
  for (c <- 0 until N) {
    val served = grant && (pickIdx === c.U)
    val missedOpp = io.free && reqE(c) && !served
    when(!reqE(c) || served) {
      age(c) := 0.U
    }.elsewhen(missedOpp) {
      age(c) := Mux(age(c) === ACAP.U, age(c), age(c) + 1.U)
    }
  }
}

object MemArbiter {
  def apply(n: Int, weights: Seq[Int], ageMax: Int): MemArbiter = Module(new MemArbiter(n, weights, ageMax))

  // ===================== 单元装置的网表生成入口 =====================
  // 用法（Windows，与 `sim/ddr3bridge/gen_bridge.sh` 同款）：
  //   java -cp YeshenSocGlue.jar MemArbiter [输出目录]      # 默认 build_memarb/
  //   ⇒ <输出目录>/MemArbiter.v，供 `sim/memarb/run_unit.sh` 用 verilator
  //     `--top-module MemArbiter` 装配单元装置（判据见 sim/memarb/tb_memarb.cpp 头部）。
  // 这里的三个参数**就是**单元装置被测的那份实例（负对照脚本 patch 的正是下面这三行）。
  val GEN_N       = 3
  val GEN_WEIGHTS = Seq(2, 1, 1)
  val GEN_AGE_MAX = 32

  def main(args: Array[String]): Unit = {
    val outDir = if (args.nonEmpty) args(0) else "build_memarb"
    // ⚠️ `-td` 与 `-o` 必须落在不同路径（同 DDR3Bridge.main：同路径会产出 0 字节）。
    val opts = Array(
      "-disable-all-randomization",
      "-strip-debug-info",
      "-strip-fir-debug-info",
      "-O=release",
      "--ignore-read-enable-mem",
      "--lower-memories",
      "--lowering-options=noAlwaysComb, disallowPackedArrays, disallowLocalVariables, disallowMuxInlining, disallowExpressionInliningInPorts",
      s"-o=$outDir/MemArbiter.v"
    )
    println(s"Generating MemArbiter(N=$GEN_N, W=$GEN_WEIGHTS, AGE=$GEN_AGE_MAX) -> $outDir/MemArbiter.v")
    (new ChiselStage).execute(
      Array("--target", "verilog", "-td", s"$outDir/work/"),
      Seq(ChiselGeneratorAnnotation(() => new MemArbiter(GEN_N, GEN_WEIGHTS, GEN_AGE_MAX))) ++
        opts.map(FirtoolOption(_))
    )
    val f = new java.io.File(s"$outDir/MemArbiter.v")
    require(f.isFile && f.length > 0, s"生成失败：$outDir/MemArbiter.v 不存在或是 0 字节")
  }
}
