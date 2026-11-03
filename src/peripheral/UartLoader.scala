import chisel3._
import chisel3.util._

// ===================== 串口装载器（板级第一步：把镜像灌进 DDR）=====================
// 为什么是**硬件**而不是"boot ROM + 软件 loader"（2026-09-22 定案，见 docs/交接文档.md §5.13.4）：
//   CPU 复位就从 DDR 取指，而软件 loader 的 store 会进**写回式 Dcache**（miss 走 `sRefill`、
//   写分配），它把固件写进 0x1C00_0000 之后 DDR 里其实还是空的；而本核**没有软件可见的
//   Dcache 冲刷手段**——CACOP 通路存在，但"本核的 RISC-V 解码器不产生 CACOP"（preLSU.scala:707
//   的注释 + tb 全文零命中），也没有 flush CSR，`fence.i` 只清 ICache（Frontend 的 `icacheFlush`）。
//   ⇒ 软件装载器要么改 Dcache RTL（加整片回写/失效），要么用"抖动驱逐"这种**无法在系统内自证**
//   的技巧。把职责放到 SoC 里最干净：CPU 扣在复位，装载器自己当 AXI 写主方，字节直达 DDR。
//
// 帧协议（走控制台那根物理线，8N1，位周期 = `16*BaudDiv` 拍，与 `Uart16550` 同一约定）：
//   `W` + addr[4B 大端] + len[4B 大端] + data[len] + xor8
//        → 写内存。**除帧末校验字节外，每收 1 字节都回 0x06**（见约束 2；含帧头字节 ⇒ 主机
//          "收一字节发一字节"的限速逻辑统一），帧末回 `K`（校验通过）/`E`（错，可整帧重发）
//   `J` → 回 `K` 后把 CPU 放复位（之后本模块不再驱动任何线，SoC 把线交还 UART/CPU）
//   `?` → 回 `Y`（探活）
// 上电后反复发 "YSLD\n" 直到收到第一个命令字节：主机（尤其 COM 口刚打开时）总能对齐到
// "装载器已就绪"的时刻。
//
// ⚠️ 三条承重约束（都来自读码/实测，不是风格）：
//  1) **写事务按 4 拍(32B) 突发发**：装载器凑满 4 个 64bit beat 才递交一笔 AW（`awlen=3`），
//     与 `DDR3Bridge` 的"每笔 DDR 事务 = 1 个 32B beat"正好一对一（桥现在按 `awlen` 分组，
//     `awlen=3` ⇒ 1 组；见 DDR3Bridge.scala 文件头约束 1）。故帧地址按 32B 对齐累加，
//     帧尾不足 32B 用 `wstrb=0` 补齐。**帧地址必须 32B 对齐**（`W` 帧头处有断言守着）。
//     ⚠️ 2026-09-30（Task 17）**AXI 主口 32bit → 64bit**：每 32B 组的拍数 8 → **4**、
//     `wstrb` 4 → 8bit、缓冲 8×32bit → **4×64bit**。**帧数据按字节线性落地的语义一字不变**
//     （小端：第 k 个字节放 `8*k` 位上，与 32bit 时代"每字 4 字节、`8*wrByte`"同一条规则，
//     只是"字"从 4 字节变成 8 字节）。
//  2) **每字节 ACK 是必需的**：控制台 UART 侧只有 1 字节接收寄存器、**无 FIFO**（`rxHaveReg`），
//     主机不限速就丢字节。凑满一波时 ACK 推迟到该波完成之后再发（`ackPend`）——主机在等 ACK，
//     ⇒ 突发期间不会来新字节。
//  3) 非装载模式（`active = 0`）下**一行都不驱动**（全部输出恒 0，见文件末尾断言）⇒ 对既有仿真零影响。
class UartLoaderIO extends Bundle {
  // [临时·定位用] 状态引出（装载期间由 SoC 接到 gpio_out，tb 直接读）；定位完删除。
  val active   = Input(Bool())   // strap：1 = 装载模式（板级默认 1）
  val rxd      = Input(Bool())   // 与控制台同一根物理 RX
  val txd      = Output(Bool())
  val released = Output(Bool())  // 1 = 收到过 `J`（SoC 据此放 CPU 复位、把线交还 UART/CPU）
  // AXI 写主方（只写）
  // ⚠️ Task 17：交付路径原生 64bit ⇒ 主口 dataWidth = **64**、`wstrb` = **8bit**（每 32B 组 = 4 拍）。
  //    宽度是**硬编码**（本模块只服务本 SoC 这一条路径，不做参数化；32bit 版在 git 历史里）。
  val awaddr  = Output(UInt(32.W))
  val awlen   = Output(UInt(8.W))
  val awvalid = Output(Bool())
  val awready = Input(Bool())
  val wdata   = Output(UInt(64.W))
  val wstrb   = Output(UInt(8.W))
  val wlast   = Output(Bool())
  val wvalid  = Output(Bool())
  val wready  = Input(Bool())
  val bvalid  = Input(Bool())
  val bready  = Output(Bool())
}

class UartLoader(baudDiv: Int = 5) extends Module {
  require(baudDiv >= 2, "BaudDiv 太小：位周期 = 16*BaudDiv 拍")
  private val bitPeriod = 16 * baudDiv
  private val cntW = log2Ceil(bitPeriod + 1)
  val io = IO(new UartLoaderIO)

  // ===================== 接收（8N1：起点沿 → 中点复核 → 8 位 LSB 先 → 停止位）=====================
  private val rxIdle :: rxStart :: rxData :: rxStop :: Nil = Enum(4)
  private val rxState = RegInit(rxIdle)
  private val rxCnt   = RegInit(0.U(cntW.W))
  private val rxShift = RegInit(0.U(8.W))
  private val rxBit   = RegInit(0.U(3.W))
  private val rxByte  = RegInit(0.U(8.W))
  private val rxValid = RegInit(false.B)
  private val rxByteVld = RegInit(false.B)   // 捕获完成拍置起，**下一拍**才作为 rxValid 送出

  rxValid := rxByteVld
  rxByteVld := false.B
  switch(rxState) {
    is(rxIdle) {
      when(!io.rxd) { rxState := rxStart; rxCnt := 0.U }
    }
    is(rxStart) {
      when(rxCnt === (bitPeriod / 2 - 1).U) {
        when(!io.rxd) { rxState := rxData; rxCnt := 0.U; rxBit := 0.U }
        .otherwise     { rxState := rxIdle }        // 毛刺
      }.otherwise { rxCnt := rxCnt + 1.U }
    }
    is(rxData) {
      when(rxCnt === (bitPeriod - 1).U) {
        // ⚠️ 方向：线上是 **LSB 先**，新位进**最高位**、整体右移 ⇒ 8 拍后 bit0 恰是首位的 bit0。
        //    （实测对账：这样读 'W'=0x57 得到 0x57；写成左移 `Cat(rxShift(6,0), rxd)` 会得到
        //      位反转的 0xEA —— 我第一版"修方向"就是改错成左移，靠引出 `rxShift` 才看清。）
        rxShift := Cat(io.rxd, rxShift(7, 1))
        rxCnt := 0.U
        when(rxBit === 7.U) { rxState := rxStop }.otherwise { rxBit := rxBit + 1.U }
      }.otherwise { rxCnt := rxCnt + 1.U }
    }
    is(rxStop) {
      when(rxCnt === (bitPeriod - 1).U) {
        rxByte    := rxShift        // 本拍末落地
        rxByteVld := true.B         // ⇒ 下一拍 rxValid 才有效（与 rxByte 配对）
        rxState   := rxIdle
      }.otherwise { rxCnt := rxCnt + 1.U }
    }
  }

  // ===================== 发送（8N1；`txStart`/`txChar` 一拍握手，`txBusy` 为高时忽略请求）=====
  private val txIdle :: txStart :: txData :: txStop :: Nil = Enum(4)
  private val txState = RegInit(txIdle)
  private val txCnt   = RegInit(0.U(cntW.W))
  private val txShift = RegInit(0.U(8.W))
  private val txBit   = RegInit(0.U(3.W))
  // ⚠️ `txChar` 必须是**组合 wire**而不是寄存器：`sendByte` 与 TX FSM 的 `txShift := txChar`
  //    在同一拍，若 txChar 是 Reg 就会把**上一字节**发出去（实测症状：整帧错位、
  //    `stop_err=1`、解出 'V' 而不是 'Y'）。
  private val txChar  = WireDefault(0.U(8.W))
  private val txReq   = WireDefault(false.B)
  // 字节之间留 **1 位周期**的空闲：UART 允许多字节背靠背，但接收侧（含 tb 的 `UartDecoder`）
  // 往往要求一个空闲间隙才重新对齐起点。实测背靠背会让解码器在首字节后失步（stop_err=1、
  // 后续字节全解不出）——而既有用例只发 1 字节 ⇒ 这条缺陷在此之前从未暴露。
  private val txGapCnt = RegInit(0.U(cntW.W))
  // ⚠️ **sendByte 绝不能"忙就丢"**：第一个命令字节到达时 banner 往往还在发（或正在间隙里），
  //    丢掉的恰好是那条 ACK ⇒ 主机会永远等下去（实测症状：`acks=0`、banner 停在 3 字节后）。
  //    所以做一个 1 深队列：忙时把字节挂起（`txPend`），TX 空了再发；`txBusy` 必须把 pending 算进去，
  //    否则 banner 会在挂起期间继续往里塞（后来的覆盖先前的——只有 banner 与 ACK 会撞，而 banner
  //    在收到第一个字节后就停了，所以覆盖是无害的）。
  private val txPend     = RegInit(false.B)
  private val txPendData = RegInit(0.U(8.W))
  private val txBusy  = txState =/= txIdle || txGapCnt =/= 0.U || txPend

  switch(txState) {
    is(txIdle) {
      when(txPend && txGapCnt === 0.U) { txState := txStart; txCnt := 0.U; txShift := txPendData; txPend := false.B }
    }
    is(txStart) {
      when(txCnt === (bitPeriod - 1).U) { txState := txData; txCnt := 0.U; txBit := 0.U }
      .otherwise { txCnt := txCnt + 1.U }
    }
    is(txData) {
      when(txCnt === (bitPeriod - 1).U) {
        txShift := Cat(0.U(1.W), txShift(7, 1))
        txCnt := 0.U
        when(txBit === 7.U) { txState := txStop }.otherwise { txBit := txBit + 1.U }
      }.otherwise { txCnt := txCnt + 1.U }
    }
    is(txStop) {
      when(txCnt === (bitPeriod - 1).U) { txState := txIdle; txGapCnt := bitPeriod.U }.otherwise { txCnt := txCnt + 1.U }
    }
  }
  io.txd := MuxLookup(txState, 1.U(1.W))(Seq(txStart -> 0.U, txData -> txShift(0), txStop -> 1.U))
  when(txGapCnt =/= 0.U) { txGapCnt := txGapCnt - 1.U }
  // pending 装载：只要没人"正在发"（txState 空闲）且不在间隙里，就挂起；FSM 在进 txStart 那拍清掉。
  // ⚠️ 装载**无条件**：`txGapCnt` 是"何时能发"（由 FSM 消费时判），不是"能不能收"。第一版把间隙
  //    也写进装载条件 ⇒ 命令字节恰好在 banner 的间隙里到达时，那条 ACK 又被丢掉（主机死等）。
  when(txReq) { txPend := true.B; txPendData := txChar }

  /** 发一个字节（只在空闲时才真正发出）。 */
  private def sendByte(c: UInt): Unit = { txReq := true.B; txChar := c }

  // ===================== 写缓冲：4 个 64bit 字 = 一波 32B 突发 =====================
  private val wrBuf  = RegInit(VecInit.fill(4)(0.U(64.W)))
  private val wrStrb = RegInit(VecInit.fill(4)(0.U(8.W)))
  private val wrWord = RegInit(0.U(2.W))    // 正在填的字号 0..3
  private val wrByte = RegInit(0.U(3.W))    // 字内字节 0..7
  private val wrBase = RegInit(0.U(32.W))   // 本波基址（32B 对齐，逐波 +32）

  private val wIdle :: wAw :: wW :: wB :: Nil = Enum(4)
  private val wState = RegInit(wIdle)
  private val wIdx   = RegInit(0.U(2.W))
  private val wNeed  = RegInit(4.U(3.W))    // 本波要发的字数（1..4；4 需要 3 位）
  private val wGo    = WireDefault(false.B)

  io.awaddr  := wrBase
  io.awlen   := 3.U                          // ⚠️ 固定 4 拍（约束 1；64bit ⇒ 4×8B = 32B）
  io.awvalid := wState === wAw
  io.wdata   := wrBuf(wIdx)
  io.wstrb   := wrStrb(wIdx)
  io.wlast   := wIdx === wNeed - 1.U
  io.wvalid  := wState === wW
  io.bready  := wState === wB
  private val wBusy = wState =/= wIdle

  switch(wState) {
    is(wIdle) { when(wGo) { wState := wAw; wIdx := 0.U } }
    is(wAw)   { when(io.awready) { wState := wW } }
    is(wW)    {
      when(io.wready) {
        when(wIdx === wNeed - 1.U) { wState := wB }.otherwise { wIdx := wIdx + 1.U }
      }
    }
    is(wB)    {
      when(io.bvalid) {
        wState := wIdle
        wrBase := wrBase + 32.U
        wrWord := 0.U
        wrByte := 0.U
        for (i <- 0 until 4) { wrStrb(i) := 0.U; wrBuf(i) := 0.U }   // 缓冲与 strobe 一并清零：
        // 装字用的是 `wrBuf | (byte << 8*wrByte)`，不清就会把上一波的残留字节 OR 进下一波
        // （实测第二笔突发首字写成 0x223777B7，而期望 0x00300313）。
      }
    }
  }

  // ===================== 协议 =====================
  private val pBanner :: pCmd :: pAddr :: pLen :: pData :: pTail :: pXor :: pJmp :: Nil = Enum(8)
  // 直接从 pCmd 起步：第一版从 pBanner 起步，而那一支把收到的字节当唤醒信号直接丢掉
  // ⇒ 帧头 W 被吞、主机永远等不到 ACK（实测 pState 从 0 跳到 1 但 txPend 仍为 0）。
  private val pState   = RegInit(pCmd)
  private val hdrAddr  = RegInit(0.U(32.W))
  private val hdrLen   = RegInit(0.U(32.W))
  private val left     = RegInit(0.U(32.W))
  private val xorAcc   = RegInit(0.U(8.W))
  private val hdrCnt   = RegInit(0.U(3.W))
  private val seenCmd  = RegInit(false.B)
  private val bannerTx = RegInit(false.B)     // 本拍是否要发 banner 字节（用 TX 空闲做节流）
  private val ackPend  = RegInit(false.B)     // 攒满一波时被推迟的 ACK
  private val kSent    = RegInit(false.B)
  private val releasedReg = RegInit(false.B)
  io.released := releasedReg

  private val BANNER = VecInit("YSLD\n".map(_.toInt.U(8.W)))
  private val bannerIdx = RegInit(0.U(3.W))

  // 推迟的 ACK：等这一波发完再回（主机在等它，所以突发期间不会有新字节）
  when(ackPend && !wBusy && pState =/= pJmp) { sendByte(0x06.U); ackPend := false.B }

  private val take = rxValid && !wBusy && !ackPend   // 一波在飞或 ACK 未回时不消费
  private val rxb  = rxByte

  when(take) {
    switch(pState) {
      is(pBanner) { pState := pCmd }   // 永不进入（pState 初值就是 pCmd，见其 RegInit 注释）
      is(pCmd) {
        seenCmd := true.B                 // 第一个被处理的字节就停 banner
        when(rxb === 'W'.U) { hdrCnt := 0.U; hdrAddr := 0.U; hdrLen := 0.U; wrBase := hdrAddr; wrWord := 0.U; wrByte := 0.U; sendByte(0x06.U); pState := pAddr }
        .elsewhen(rxb === 'J'.U) { kSent := false.B; pState := pJmp }
        .elsewhen(rxb === '?'.U) { sendByte('Y'.U) }
      }
      is(pAddr) {
        hdrAddr := Cat(hdrAddr(23, 0), rxb)
        sendByte(0x06.U)
        when(hdrCnt === 3.U) { hdrCnt := 0.U; pState := pLen }.otherwise { hdrCnt := hdrCnt + 1.U }
      }
      is(pLen) {
        hdrLen := Cat(hdrLen(23, 0), rxb)
        sendByte(0x06.U)
        when(hdrCnt === 3.U) {
          hdrCnt := 0.U
          // ⚠️ 必须用**本拍算出来**的新长度判下一状态：直接写 `Mux(left === 0.U, ...)` 读的是旧 `left`
          //    （=0）⇒ 永远跳 pXor、根本不进数据相（实测 wrWord/wState 全程 0、len 字节被当校验字节回 E）。
          val newLeft = Cat(hdrLen(23, 0), rxb)
          left := newLeft
          xorAcc := 0.U
          wrBase := hdrAddr
          wrWord := 0.U
          wrByte := 0.U
          pState := Mux(newLeft === 0.U, pXor, pData)
        }.otherwise { hdrCnt := hdrCnt + 1.U }
      }
      is(pData) {
        // ⚠️ 帧里的数据是**小端**：每 8 个字节拼一个 64bit 字，第 k 个字节放到 `8*k` 位上
        //    （64bit 下 `wrByte` 走 0..7）。32bit 时代是"每 4 字节一个字、字节放到 `8*wrByte`"，
        //    两条规则**逐字节同义**（内存里的字节线性顺序不变），只是字数从 8 个变 4 个。
        //    写成 `Cat(wrBuf(wrWord)(63,8), rxb)` 会把已收字节逐次挤出去 ⇒ 每字只剩最后一个字节
        //    （32bit 时代实测：`0x200022B7` 被写成 `0x00000020`，`mem[]` 因此逐字不等）。
        wrBuf(wrWord)  := wrBuf(wrWord) | (Cat(0.U(56.W), rxb) << (wrByte << 3))
        wrStrb(wrWord) := wrStrb(wrWord) | (1.U(8.W) << wrByte)
        xorAcc := xorAcc ^ rxb
        left := left - 1.U
        when(wrByte === 7.U) {
          wrByte := 0.U
          when(wrWord === 3.U) {
            // 攒满 4 个 64bit 字（= 32B）：发这一波，ACK 推迟到波完成
            wNeed := 4.U; wGo := true.B; ackPend := true.B
          }.otherwise { wrWord := wrWord + 1.U; sendByte(0x06.U) }
        }.otherwise { wrByte := wrByte + 1.U; sendByte(0x06.U) }
        when(left === 1.U) { pState := pTail }     // 本帧最后一字节：去补尾/校验
      }
      is(pTail) { }     // 见 when(take) 之外的独立块（它的推进由"突发完成"驱动）
      // 帧尾/放行的无条件块见 `when(take)` 之后。
      is(pXor) {
        sendByte(Mux(rxb === xorAcc, 'K'.U, 'E'.U))
        pState := pCmd
      }
      is(pJmp) { }      // 见 when(take) 之外的独立块（它的推进不由收字节驱动）
    }
  }

  // banner：未收到第一个命令字节前，反复发 "YSLD\n"（用 TX 空闲节流，天然限速）
  // ===================== 帧尾/放行：与收字节无关，必须在 when(take) 之外 =====================
  // ⚠️ 这两块的推进由"突发完成 / 发送完成"驱动；若写在 when(take) 里，就只能靠"恰好又来一个字节"
  //    才前进 ⇒ 实测帧尾永久停在 pTail（各信号全空闲却不变状态）、K 永不回、CPU 永不放行。
  when(pState === pTail) {
    when(!wBusy && !ackPend) {
      when(wrWord =/= 0.U || wrByte =/= 0.U) {
        wNeed := 4.U      // 残波也补齐 4 拍（与 DDR3Bridge 的"每笔 AW = 1 个 32B beat"一对一）
        wGo := true.B     // 不置 ackPend：残波不对应任何字节
      }.otherwise { pState := pXor }
    }
  }
  when(pState === pJmp) {
    when(!kSent && !txBusy) { sendByte('K'.U); kSent := true.B }
    .elsewhen(kSent && !txBusy) { releasedReg := true.B }
  }

  // banner 只在**本装载器当主人**时发：SoC 侧 TF 卡优先，装载器非主人时控制台 TX 也不归它驱动，
  // 再发就是往别人的线上灌字（板上会看到一段莫名其妙的 "YSLD" 混在 TF 装载期间）。
  when(io.active && !seenCmd && !txBusy) {
    sendByte(BANNER(bannerIdx))
    bannerIdx := Mux(bannerIdx === 4.U, 0.U, bannerIdx + 1.U)
  }


  // ===================== 断言 =====================
  // 约束 1：帧地址必须 32B 对齐（否则"按 32B 累加"的假设不成立）
  when(take && pState === pLen && hdrCnt === 3.U) {
    assert(Cat(hdrLen(23, 0), rxb) === 0.U || hdrAddr(4, 0) === 0.U,
      "UartLoader: W-frame base address must be 32B aligned (DDR3Bridge aggregates exactly 4 W beats per AW)")
  }
  // 约束 3：非装载模式一行都不驱动
  // ⚠️ 断言里**不能**带 `!releasedReg`：2026-09-23 起 SoC 会用 `active` 表示"本装载器当前是主人"
  //    （TF 卡优先、串口装载器是回退），收到 `J` 帧放行后 `active` 就被拉低，而 `released` 必须
  //    保持 1（CPU 靠它放复位）⇒ 带上它就等于"成功的那一刻自己踩自己"（实测 $stop）。
  when(!io.active) {
    assert(!io.awvalid && !io.wvalid && !io.bready,
      "UartLoader: must not drive the bus while inactive")
  }
}
