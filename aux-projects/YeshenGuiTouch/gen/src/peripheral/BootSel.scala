import chisel3._
import chisel3.util._

// ===================== 上电装载计划选择器（Linux / CoreMark 裸核）=====================
// 在 `active`（板级 loadMode strap 锁存）期间：
//   · **TX 提示**：115200（位周期 = 868 拍 @100 MHz，与 SdUartReport/UART 控制台同档），
//     发一条 `\r\n[Y1] L=Linux C=CoreMark > `；
//   · **RX**：8N1、LSB 先（与 UartLoader 同款采样：起点中点复核 + 每 bit 中点采样）；
//     `C/c` ⇒ sel=1（CoreMark 计划），`L/l` ⇒ sel=0（Linux 计划），其它字节忽略；
//   · **超时**：`io.timeout` 拍（板级 = 1.0 s = 100_000_000 拍）⇒ sel=0（默认 Linux）。
// 输出：
//   · `done`  —— 选择已定（字节或超时），此后保持不变；
//   · `lineFree` = done && !txBusy —— 提示发完且选择已定 ⇒ glue 此时才放 sdEnable/放 CPU 复位，
//     避免"提示还没发完、SD 报文就抢同一根 TX"；
//   · `owner/txd` —— 占用控制台 TX（glue 的 uart_txd 三选一最高优先级）。
class BootSelIO extends Bundle {
  val active  = Input(Bool())
  val timeout = Input(UInt(32.W))
  val rxd     = Input(Bool())
  val sel     = Output(Bool())     // 0 = Linux, 1 = CoreMark
  val done    = Output(Bool())
  val owner   = Output(Bool())
  val txd     = Output(Bool())
  val lineFree = Output(Bool())
}

class BootSel(bitPeriod: Int = 868) extends Module {
  require(bitPeriod >= 16, "bitPeriod 必须 >= 16（采样点要有余量）")
  val io = IO(new BootSelIO)

  // 提示串（**不要加中文/非 ASCII**：串口终端按字节显示）
  private def ch(c: Char) = c.toInt.U(8.W)
  private val msg = VecInit(Seq(
    '\r', '\n', '[', 'Y', '1', ']', ' ', 'L', '=', 'L', 'i', 'n', 'u', 'x', ' ',
    'C', '=', 'C', 'o', 'r', 'e', 'M', 'a', 'r', 'k', ' ', '>', ' '
  ).map(ch))
  private val msgLen = msg.length

  // ===================== 选择状态 =====================
  private val selR  = RegInit(false.B)
  private val doneR = RegInit(false.B)
  private val tmo   = RegInit(0.U(32.W))
  when(io.active && !doneR) {
    when(tmo === io.timeout) { doneR := true.B; selR := false.B }
    .otherwise               { tmo := tmo + 1.U }
  }

  // ===================== RX（8N1）=====================
  private val rxIdle :: rxStart :: rxData :: rxStop :: Nil = Enum(4)
  private val rxState = RegInit(rxIdle)
  private val rxCnt   = RegInit(0.U(log2Ceil(bitPeriod + 1).W))
  private val rxShift = RegInit(0.U(8.W))
  private val rxBit   = RegInit(0.U(3.W))
  private val rxByteVld = RegInit(false.B)
  rxByteVld := false.B
  switch(rxState) {
    is(rxIdle) {
      when(io.active && !doneR && !io.rxd) { rxState := rxStart; rxCnt := 0.U }
    }
    is(rxStart) {
      when(rxCnt === (bitPeriod / 2 - 1).U) {
        when(!io.rxd) { rxState := rxData; rxCnt := 0.U; rxBit := 0.U }
        .otherwise    { rxState := rxIdle }
      }.otherwise { rxCnt := rxCnt + 1.U }
    }
    is(rxData) {
      when(rxCnt === (bitPeriod - 1).U) {
        // LSB 先：新位进最高位、整体右移
        rxShift := Cat(io.rxd, rxShift(7, 1))
        rxCnt := 0.U
        when(rxBit === 7.U) { rxState := rxStop }.otherwise { rxBit := rxBit + 1.U }
      }.otherwise { rxCnt := rxCnt + 1.U }
    }
    is(rxStop) {
      when(rxCnt === (bitPeriod - 1).U) {
        rxByteVld := true.B
        rxState   := rxIdle
      }.otherwise { rxCnt := rxCnt + 1.U }
    }
  }
  when(rxByteVld && !doneR) {
    when(rxShift === "h43".U || rxShift === "h63".U) { selR := true.B;  doneR := true.B }  // 'C' / 'c'
    .elsewhen(rxShift === "h4c".U || rxShift === "h6c".U) { selR := false.B; doneR := true.B }  // 'L' / 'l'
  }

  // ===================== TX（8N1，发提示串）=====================
  private val txIdle :: txStart :: txData :: txStop :: txGap :: Nil = Enum(5)
  private val txState = RegInit(txIdle)
  private val txCnt   = RegInit(0.U(log2Ceil(bitPeriod + 1).W))
  private val txShift = RegInit(0.U(8.W))
  private val txBit   = RegInit(0.U(3.W))
  private val txIdx   = RegInit(0.U(log2Ceil(msgLen).W))
  private val msgSent = RegInit(false.B)
  private val txdR    = RegInit(true.B)
  io.txd := txdR
  private val txBusy = txState =/= txIdle

  switch(txState) {
    is(txIdle) {
      when(io.active && !msgSent) {
        txShift := msg(0.U); txIdx := 0.U; txCnt := 0.U; txBit := 0.U
        txdR := false.B; txState := txStart
      }
    }
    is(txStart) {
      txdR := false.B
      when(txCnt === (bitPeriod - 1).U) {
        txCnt := 0.U; txBit := 0.U; txShift := txShift(7, 1); txdR := txShift(0)
        txState := txData
      }.otherwise { txCnt := txCnt + 1.U }
    }
    is(txData) {
      when(txCnt === (bitPeriod - 1).U) {
        txCnt := 0.U
        when(txBit === 7.U) { txdR := true.B; txState := txStop }
        .otherwise {
          txBit := txBit + 1.U
          txShift := txShift(7, 1)
          txdR := txShift(0)
        }
      }.otherwise { txCnt := txCnt + 1.U }
    }
    is(txStop) {
      txdR := true.B
      when(txCnt === (bitPeriod - 1).U) {
        txCnt := 0.U
        when(txIdx === (msgLen - 1).U) { msgSent := true.B; txState := txIdle }
        .otherwise { txIdx := txIdx + 1.U; txShift := 0.U; txState := txGap }
      }.otherwise { txCnt := txCnt + 1.U }
    }
    is(txGap) {
      txdR := true.B
      when(txCnt === (bitPeriod - 1).U) {
        txCnt := 0.U; txBit := 0.U; txShift := msg(txIdx); txdR := false.B
        txState := txStart
      }.otherwise { txCnt := txCnt + 1.U }
    }
  }

  io.sel      := selR
  io.done     := doneR
  io.owner    := io.active && !(doneR && !txBusy)
  io.lineFree := doneR && !txBusy
}
