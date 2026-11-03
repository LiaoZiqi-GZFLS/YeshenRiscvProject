import chisel3._
import chisel3.util._

// ===================== SD 装载器的 UART 诊断报文器（TX-only）=====================
// 为什么需要它（2026-10-06，D1 之后）：原先 SD 的板级诊断靠**以太网反向信道**（厂家 eth 栈里那个
// 周期回发的 'NXB' 帧）。D1 把 EthLoader 与厂家栈整体删除后那条通道没了；而**板级参照工程
// `tf_test_200mini` 本来就是只用 UART 报文做诊断**（每 1s 一行，失败自动重试 ⇒ 报文是"活线探针"）。
// 于是把诊断改走 UART —— 它还有一个额外好处：**在 Linux 起来之前就能看**。
//
// 夺线逻辑（这条线是共享的，必须精确）：
//   `io.uart_txd = Mux(owner, 本模块, Mux(loadActive, uartLoader.txd, console.txd))`
//   · `owner` = `enable`（SD 正在当主人）**或** 终态后的 `graceCycles` 窗口。
//   · 为什么要有宽限期：SD 一失败 `sdEnable` 就落，紧接着 `loadActive` 会落到 UART 装载器
//     （ETH 那一级已删除）⇒ 若立刻交还，最后一行（`state=4` 的终态）会被抢掉 ⇒ 读数时看不到真正的结论。
//   · 为什么 `enable` 还要**去抖**：`enable` 是 `sdLoader.state` 的组合函数，而 SD 一旦"抖一下状态"
//     就变成 `owner` 的翻转 ⇒ **两个源在 MHz 级交替驱动同一根线** ⇒ 线上是高频垃圾、115200 一个字都解不出。
//     去抖 = 连续 N 拍都为高才算数（真装载是 ms 级，抖是拍级，两者差 3 个数量级，非常好分）。
//
// 报文格式（固定宽度、可逐字解析；**头部自带身份**，避免和别的波特/别的设备混淆）：
//     "SDR " + 18 个 ASCII hex + "\r\n"        （共 24 字节；波特 115200，见 baudDiv）
//     hex[0:2] = {state(4), errCode(4)}        ← SdLoader
//     hex[2:10]= dbg(32)                      ← SdSpi {misoHi,sckCnt(12),lastRx(8),errCode(4),ph(4),st(3)}
//     hex[10:18]=dbg2(32)                     ← SdLoader AXI 突发通路
//   ⚠️ 主机侧**必须按 115200 读**：装载器（UART 装载器）自己的 TX 是 28.9k（baudDiv=216），
//      两档不同 —— 见 `docs/SD装载器-bring-up-2026-10-06.md`。
//
// ⚠️⚠️ **一帧的 24 个字节必须背靠背发**（2026-10-07 修）：
//   第一版在 `stop` 结束后一律回 `idle`、只能靠下一个 `go`（100 ms 一次）再启动下一字节
//   ⇒ 实测**每 100 ms 只出一个字节**（仿真里 'S' 在 cyc=10,009,095、'D' 在 cyc=20,009,095），
//   一帧要 2.4 s 才发完，诊断完全没法读（而且中途会被别的源穿插）。
//   现在：非末字节时 `stop → start` 直通并把下一字节装进移位寄存器；只有末字节才回 `idle`。
class SdUartReport(baudDiv: Int = 868, graceCycles: Int = 5000000, debounceN: Int = 16) extends Module {
  require(baudDiv >= 16, "baudDiv 必须 >= 16（否则一位小于 16 拍，采样点没有余量）")
  require(debounceN >= 4, "debounceN 太小起不到去抖作用")
  val io = IO(new Bundle {
    val enable = Input(Bool())        // 1 = SD 装载器正在当主人
    val state  = Input(UInt(4.W))     // SdLoader.io.state
    val err    = Input(UInt(4.W))     // SdLoader.io.errCode
    val dbg    = Input(UInt(32.W))    // SdSpi.io.dbg
    val dbg2   = Input(UInt(32.W))    // SdLoader.io.dbg2
    val owner  = Output(Bool())       // 1 = 本模块占用 uart_txd
    val txd    = Output(Bool())
  })

  // ---- 去抖：连续 debounceN 拍都为高才算"真主人"（挡掉 state 抖动引起的夺线翻转）----
  private val dbgReg = RegInit(0.U(debounceN.W))
  dbgReg := Cat(dbgReg(debounceN - 2, 0), io.enable)
  private val enableStable = dbgReg.andR

  // ---- 宽限期：enable 落下后再占 line 一段时间，保证终态那一行发得出去 ----
  // ⚠️ 宽限**不能太长**：SD 失败 ⇒ `sdEnable` 落 ⇒ `loadActive` 立刻落到 UART 装载器
  //    （要发它的 "YSLD" banner）。宽限期内 line 归本模块 ⇒ banner 会被吃掉。
  //    50ms（5e6 拍）足够：一帧 = 24B × 10bit × 868 ≈ 208k 拍 ≈ 2.1ms，留 24 倍余量。
  private val grace = RegInit(0.U(28.W))
  when(enableStable) { grace := graceCycles.U }
  .elsewhen(grace =/= 0.U) { grace := grace - 1.U }

  // ---- 帧载荷：'S','D','R',' ' + 18 个 hex 字符 + CR + LF = 24 字节 ----
  // 18 个 nibble 的来源（MSB 先）：{state(4), err(4), dbg(32), dbg2(32)} = 72 bit
  // ⚠️ Chisel 的 `String.U` **只吃数字字面量**（"1A"/"h1A" 这类），写 `"S".U` 会在精化期直接报
  //    `Invalid base S`。字符一律走 `Char` 字面量（`'S'.U`）或直接写数值。
  private val payload = Cat(io.state, io.err, io.dbg, io.dbg2)   // 72 bit
  private def hexChar(nib: UInt): UInt =
    Mux(nib < 10.U, nib + '0'.U(8.W), nib - 10.U + 'A'.U(8.W))
  private val hexBytes = VecInit((0 until 18).map { i =>
    hexChar(payload(71 - 4 * i, 68 - 4 * i))
  })
  // 第 idx 字节（0..23；越界给 0）
  private def byteOf(idx: UInt): UInt = {
    val v = Wire(UInt(8.W))
    v := MuxLookup(idx, 0.U)(Seq(
      0.U  -> 'S'.U(8.W), 1.U -> 'D'.U(8.W), 2.U -> 'R'.U(8.W), 3.U -> 32.U(8.W),  // 'S','D','R',' '
      22.U -> 13.U(8.W), 23.U -> 10.U(8.W)                                        // CR, LF
    ) ++ (0 until 18).map(i => (4 + i).U -> hexBytes(i)))
    v
  }
  private val LAST = 23.U(5.W)

  // ---- 行周期：~100ms 启动一帧；`enable` 落沿**立刻补发一帧**（保证 state=4 的终态行发得出去）----
  private val PERIOD = 10000000               // 10e6 拍 = 100ms @100MHz
  private val period = RegInit(0.U(24.W))
  private val enableFall = RegNext(enableStable, false.B) && !enableStable
  private val go = WireDefault(false.B)
  when(enableFall) { period := 0.U }
  .elsewhen(period === (PERIOD - 1).U) { period := 0.U }
  .otherwise { period := period + 1.U }
  when(period === (PERIOD - 1).U || enableFall) { go := true.B }

  // ---- 字节层：start(0) + 8 data(LSB 先) + stop(1)，每 bit baudDiv 拍 ----
  private val idle :: start :: data :: stop :: Nil = Enum(4)
  private val st   = RegInit(idle)
  private val div  = RegInit(0.U(10.W))
  private val bitn = RegInit(0.U(4.W))
  private val sh   = RegInit(0.U(8.W))
  private val txdR = RegInit(true.B)
  private val byteSel = RegInit(0.U(5.W))
  private val selNext = Mux(byteSel === LAST, 0.U(5.W), byteSel + 1.U(5.W))
  private val isLast  = byteSel === LAST

  // ---- 夺线（必须在 `st` 之后算，因为它含 `frameBusy`）----
  // ⚠️ `frameBusy` 也并进 owner：**一帧发出去的过程中不许交还 line**。
  //    否则 `enable` 只要在帧中途抖一下，`owner` 就翻转 ⇒ 两个源在帧内交替驱动同一根线
  //    ⇒ 解出一串垃圾（这正是 2026-10-07 板级看到"高频垃圾"的机理）。帧只有 2.1ms，
  //    钉住它的代价可以忽略。
  private val frameBusy = st =/= idle
  private val owner = enableStable || frameBusy || (grace =/= 0.U)
  io.owner := owner

  switch(st) {
    is(idle) {
      txdR := true.B
      // 一帧的起点：装第 0 字节
      when(go && owner) { sh := byteOf(0.U); byteSel := 0.U; st := start; div := 0.U }
    }
    is(start) {
      txdR := false.B
      when(div === (baudDiv - 1).U) { div := 0.U; st := data; bitn := 0.U }
      .otherwise { div := div + 1.U }
    }
    is(data) {
      txdR := sh(0)                          // LSB 先
      when(div === (baudDiv - 1).U) {
        div := 0.U
        when(bitn === 7.U) { st := stop } .otherwise { bitn := bitn + 1.U; sh := sh >> 1 }
      }.otherwise { div := div + 1.U }
    }
    is(stop) {
      txdR := true.B
      when(div === (baudDiv - 1).U) {
        div := 0.U
        when(isLast) {
          byteSel := 0.U
          st := idle                          // 整帧发完，交还 line（等下一个 go）
        }.otherwise {
          sh := byteOf(selNext)               // ★ 背靠背：直接装下一字节继续发
          byteSel := selNext
          st := start
        }
      }.otherwise { div := div + 1.U }
    }
  }
  io.txd := txdR
}
