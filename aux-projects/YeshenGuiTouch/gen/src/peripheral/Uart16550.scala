import chisel3._
import chisel3.util._

// ===================== ns16550a 子集（M4 控制台）=====================
// 只实现 OpenSBI/Linux 真正会碰的那部分（spec §5）：无 FIFO（1 级）、无 modem 状态、无中断接线。
// 寻址由 DT 声明 `reg-shift=2` / `reg-io-width=4` ⇒ **每寄存器 4 字节、全部 32 位访问**，
// 低 8 位有效（上游依据：`lib/utils/serial/uart8250.c:54` `num << dev->reg_shift`、`:61` `readl`）。
//
// ⚠️ 共享引擎的契约（2026-09-24 统一）：`UARTTx` 与 `UARTRx` 都是"**一个位 = 4 个 `baudTick`**"。
//    历史上 `UARTTx` 是"1 tick 一位"而 `UARTRx` 是"4 tick 采一位"，本模块只能靠**两个不同周期的 tick**
//    硬凑出两侧都 = 16*bdiv（`txTick` = rxTick 再 4 分频）。那两个缺陷已在 `UART.scala` 里修掉
//    （TX 位周期改 4 tick + 帧首对齐到位边界 + 不再发上一笔数据），所以这条 workaround 已删除：
//    两侧都接 `rxTick`（周期 4*bdiv 拍）⇒ **位周期 = 16*bdiv**，仍符合 16550 契约。
//
// ⚠️ `THRE` 与 `TEMT` 同源（都取 `!tx.busy`）：只有 1 级缓冲，两者天然等价（简化，见 spec §5.2）。
object Uart16550Regs {
  val RBR_THR_DLL = 0.U(3.W)   // 0x00
  val IER_DLM     = 1.U(3.W)   // 0x04
  val IIR_FCR     = 2.U(3.W)   // 0x08
  val LCR         = 3.U(3.W)   // 0x0C
  val MCR         = 4.U(3.W)   // 0x10
  val LSR         = 5.U(3.W)   // 0x14
  val MSR         = 6.U(3.W)   // 0x18
  val SCR         = 7.U(3.W)   // 0x1C
}

class Uart16550IO extends Bundle {
  val axi = new AXILiteIO          // 复用 UART.scala 里的定义；本模块只用 araddr/awaddr 的 (4,2)
  val txd = Output(Bool())
  val rxd = Input(Bool())
  val irq = Output(Bool())         // M4 不接线（spec §5.3）：SoC 侧悬空，M5 接 PLIC 第 3 源
}

class Uart16550 extends Module {
  override def desiredName = "Uart16550"

  val io = IO(new Uart16550IO)

  // ---- 配置寄存器 ----
  private val ierReg = RegInit(0.U(8.W))
  private val fcrReg = RegInit(0.U(8.W))
  private val lcrReg = RegInit(0.U(8.W))
  private val mcrReg = RegInit(0.U(8.W))
  private val scrReg = RegInit(0.U(8.W))
  private val dllReg = RegInit(0.U(8.W))
  private val dlmReg = RegInit(0.U(8.W))

  // ---- 数据/状态 ----
  private val txDataReg = RegInit(0.U(8.W))

  private val dlab = lcrReg(7)

  // ---- 分频（spec §5.4）：bdiv = DLL | (DLM << 8)，位周期 = 16*bdiv 拍 ----
  private val bdiv      = Cat(dlmReg, dllReg)
  private val rxTickDiv = Mux(bdiv === 0.U, 0.U(32.W), (bdiv.pad(32) << 2) - 1.U)   // 周期 = 4*bdiv 拍
  private val rxCounter = RegInit(0.U(32.W))
  private val rxTick    = rxCounter === 0.U
  when(rxCounter === 0.U) { rxCounter := rxTickDiv }.otherwise { rxCounter := rxCounter - 1.U }

  // ---- ★ 发送 FIFO（16 深 × 8 位）------------------------------------------------
  // 为什么必须有它（2026-10-02 定案）：本模块对外按 **16550A** 上报 —— IIR[7:6] 跟随 FCR[0]，
  //   而 8250 的端口表按 `PORT_16550A` 给 `fifo_size=16` / `tx_loadsz=16`（`8250_port.c:1328,1331`）。
  //   于是 Linux 的 `serial8250_tx_chars()` 会**一次盲写 16 字节、并不逐字节等 THRE**；
  //   而发送侧原来只有 **1 级** holding（写 THR 就是覆盖 `txDataReg`）⇒ 后 15 个字节被吞掉
  //   ⇒ **用户态 tty 输出成片丢字**（rcS 横幅/getty 提示全糊）。
  //   内核自己的 printk 之所以看起来是好的：它走 `serial8250_console_putchar()`，**逐字节等 THRE**。
  // ⇒ 补齐 16 深 FIFO 后，那 16 笔写全部落得下。**深度必须 ≥ `tx_loadsz`(16)**，否则仍旧丢。
  // RX 侧**不动**：驱动读 RX 时每字节都会重读 `LSR.DR`（`8250_port.c:1782` 的 do-while）
  //   ⇒ 1 级也安全，不做 FIFO 以免碰掉这里"置位优先"的既有规则。
  private val FifoDepth : Int = 16
  private val txFifo  = Reg(Vec(FifoDepth, UInt(8.W)))       // 不用 Mem：深度小，避免读延时
  private val txWrPtr = RegInit(0.U(4.W))
  private val txRdPtr = RegInit(0.U(4.W))
  private val txCount = RegInit(0.U(5.W))                    // 0..16
  private val txFull  = txCount === FifoDepth.U
  private val txPush     = WireDefault(false.B)              // 写 THR：本拍要入队
  private val txPop      = WireDefault(false.B)              // 本拍把 FIFO 头交给移位器
  private val fcrTxClear = WireDefault(false.B)              // FCR.bit2：清发送 FIFO（自清）

  // ---- 发送/接收引擎（复用既有模块）----
  // 两侧都接 `rxTick`（周期 4*bdiv 拍）：TX 内部的 4 分频给出 16*bdiv，RX 的 4× 过采样也给出 16*bdiv。
  // ⚠️ 历史上这里为 `UARTTx` 的两个固有缺陷做了 workaround（`start` 要晚一拍、要在 tick 边界启动，
  //    否则起始格短到 1 拍 ⇒ 写 'Y'=0x59 被解成 0x2C）：**两条现在都已在 `UARTTx` 内部修掉**
  //    （内部 `pend` 在位边界起步，那时 `txDataReg` 也已落定）⇒ 直接给组合脉冲即可。
  private val txStart = WireDefault(false.B)          // 装载器把 FIFO 头交给 `UARTTx` 的那一拍（组合）
  private val tx = Module(new UARTTx)
  tx.io.data     := txDataReg
  tx.io.start    := txStart
  tx.io.baudTick := rxTick
  tx.io.enable   := true.B
  // ★ 本模块**只做 8N1**：`lcrReg` 只用来认 DLAB / 字长，校验位（LCR.bit3）不实现。
  //   ⇒ 两侧都必须拿掉校验位槽，否则一帧 11 位（见 `UART.scala` 头部 2026-10-07 那条）。
  tx.io.parityEn := false.B
  private val txBusy = tx.io.busy
  io.txd := tx.io.txd

  private val rx = Module(new UARTRx)
  rx.io.rxd      := io.rxd
  rx.io.baudTick := rxTick
  rx.io.enable   := true.B
  rx.io.parityEn := false.B

  // ---- ★ 接收 FIFO（16 深 × 8 位）-------------------------------------------------
  // 为什么必须有它（2026-10-07 板级定案）：本模块对外按 **16550A** 上报，驱动的端口表
  //   `PORT_16550A{fifo_size=16, tx_loadsz=16}` ⇒ 内核**按"有 16 深 RX FIFO"来写它的取数节奏**；
  //   而这里原来只有 **1 级** `rxHaveReg`。实测签名（板级，240 字符）：
  //     · 背靠背发 40 字符：**只保住 82.5%–85%**（丢的位置是散的）；
  //     · **每个字符间隔 20 ms 发同样 40 个：100% 全保住**。
  //   ⇒ 丢的原因不是波特/采样（RTL 侧已由 sim/uartrx 证明背靠背能收），而是"**到达的那一拍正好压在
  //     8250 中断服务程序从断点返回到读 RBR 的窗口里**"：1 级寄存器被**覆盖**，第一个字节就没了。
  //     按 87 µs/字节、约 10 µs 的 ISR 延迟估，丢 ~12% —— 与实测吻合。
  //   ⇒ 16 深 FIFO 让"来晚一点"的字节先排队，下一个 ISR 一次抽干（驱动 `serial8250_rx_chars`
  //     本来就是 `while (LSR.DR)` 循环最多 16 字节）⇒ 不再丢。
  //   ⚠️ 旧注释说"RX 不动：驱动读 RX 每字节都会重读 LSR.DR ⇒ 1 级也安全" —— **已被上面实测推翻**：
  //     那句只对"每字节都等软件来取且软件一定来得及"成立，而我们这条是**软件 ISR 抽，
  //     硬件只留 1 格**，时间上必然有窗口。
  private val RxFifoDepth : Int = 16
  private val rxFifo   = Reg(Vec(RxFifoDepth, UInt(8.W)))
  private val rxWrPtr  = RegInit(0.U(4.W))
  private val rxRdPtr  = RegInit(0.U(4.W))
  private val rxCount  = RegInit(0.U(5.W))                 // 0..16
  private val rxFull   = rxCount === RxFifoDepth.U
  private val rxOverrun = RegInit(false.B)                 // LSR.bit1 (OE)：满时丢一个字节 ⇒ 置位

  private val rbrRead    = WireDefault(false.B)
  private val lsrRead    = WireDefault(false.B)
  private val fcrRxClear = WireDefault(false.B)
  private val rxPush = rx.io.valid && !rxFull && !fcrRxClear
  private val rxPop  = rbrRead && rxCount =/= 0.U && !fcrRxClear
  when(fcrRxClear) {                                       // FCR.bit1 优先：清空接收 FIFO
    rxCount := 0.U
    rxWrPtr := 0.U
    rxRdPtr := 0.U
  }.otherwise {
    rxCount := rxCount + rxPush.asUInt - rxPop.asUInt
  }
  when(rxPush) { rxFifo(rxWrPtr) := rx.io.data; rxWrPtr := rxWrPtr + 1.U }
  when(rxPop)  { rxRdPtr := rxRdPtr + 1.U }
  // 溢出：FIFO 满时到的新字节**丢**并置 OE（不是覆盖老字节 —— 覆盖会让"丢一个"变成"丢最早那个"，
  // 顺序错乱更难查）；OE 在读 LSR 时清（真 16550 口径）。
  when(fcrRxClear) { rxOverrun := false.B }
  .elsewhen(rx.io.valid && rxFull) { rxOverrun := true.B }
  .elsewhen(lsrRead) { rxOverrun := false.B }
  private val rxNotEmpty = rxCount =/= 0.U                 // = LSR.DR

  // ---- 写通道（sticky AW/W；SoC 的 MMIO FSM 是 sAW→sW→sB 分拍发）----
  private val awReady = RegInit(false.B)
  private val wReady  = RegInit(false.B)
  private val bValid  = RegInit(false.B)
  private val awAddr  = RegInit(0.U(5.W))
  private val wData   = RegInit(0.U(32.W))

  when(io.axi.awvalid && io.axi.awready) { awReady := true.B; awAddr := io.axi.awaddr }
  when(io.axi.wvalid && io.axi.wready)   { wReady := true.B;  wData  := io.axi.wdata }

  when(awReady && wReady) {
    switch(awAddr(4, 2)) {
      is(Uart16550Regs.RBR_THR_DLL) {
        when(dlab) { dllReg := wData(7, 0) }
        .otherwise { txPush := true.B }              // ★ 写 THR 只入 FIFO；start 由下面的装载器给
      }
      is(Uart16550Regs.IER_DLM) {
        when(dlab) { dlmReg := wData(7, 0) }.otherwise { ierReg := wData(7, 0) }
      }
      is(Uart16550Regs.IIR_FCR) {
        // FCR：bit0 FIFO 使能（只记录，IIR 的 bit7:6 跟随）、bit1 清 RX、bit2 清 TX、bit7:6 触发级
        fcrReg := wData(7, 0)
        when(wData(1)) { fcrRxClear := true.B }
        when(wData(2)) { fcrTxClear := true.B }      // ★ 清发送 FIFO（以前是空操作；现在真做）
      }
      is(Uart16550Regs.LCR) { lcrReg := wData(7, 0) }
      is(Uart16550Regs.MCR) { mcrReg := wData(7, 0) }
      is(Uart16550Regs.LSR) { }        // 只读
      is(Uart16550Regs.MSR) { }        // 只读
      is(Uart16550Regs.SCR) { scrReg := wData(7, 0) }
    }
    bValid := true.B
    awReady := false.B
    wReady  := false.B
  }
  when(io.axi.bready && bValid) { bValid := false.B }

  // ---- 读通道（相位与 CLINT/PLIC 一致：AR 拍译码进 rData ⇒ 见 spec §5.10 的承重规则）----
  private val rValid = RegInit(false.B)
  private val rData  = RegInit(0.U(32.W))

  // ⚠️ `THRE`/`TEMT` 必须把"**已写入但还没进移位器**"的挂起字节也算进去（`txPend`）：
  //    写 THR 之后，`UARTTx` 内部要等到下一个位边界才起步（最多一个位周期），而它内部 `pend`
  //    要到下一拍才置起来 ⇒ 存在**一拍**窗口 `tx.busy` 还是 0。若这拍 `THRE` 读 1，软件会以为
  //    发送器空闲（OpenSBI 的 `putc` 正是轮询 THRE）⇒ 提前收工/丢字节。
  //    实测症状（当年这条 workaround 的由来）：SoC 级 `M1_SOC_CONSOLE=1` 的程序轮询 LSR 立刻通过、
  //    整帧根本没发出来（`n=0`、`min_low=INT_MAX`）。真实 16550 的 THRE 是"保持寄存器空"，同理应为 0。
  //    这里的 `txPend` 只负责盖住那一拍：置位在写执行，清位在 TX 自己报忙之后。
  private val txPend = RegInit(false.B)
  when(txStart) { txPend := true.B }.elsewhen(txBusy) { txPend := false.B }
  private val txIdle = !txBusy && !txPend      // 移位路径空闲（含"写后一拍"那个覆盖窗）

  // ---- 发送 FIFO 装载器 / 出入队（放这里：装载器要用 `txIdle`）----
  // `txStart` 现在只由装载器产生；FIFO 满时不再入队（THRE 语义下不该发生，兜底而已）。
  txPop := txIdle && txCount =/= 0.U           // 把头字节交给 `UARTTx`
  private val doPush = txPush && (!txFull || txPop)
  when(fcrTxClear) {                           // FCR.bit2 优先
    txCount := 0.U; txWrPtr := 0.U; txRdPtr := 0.U
  }.elsewhen(doPush && !txPop) {               // 同拍 push+pop ⇒ 计数不变（下面两条都不命中）
    txCount := txCount + 1.U
  }.elsewhen(!doPush && txPop) {
    txCount := txCount - 1.U
  }
  when(doPush) { txFifo(txWrPtr) := wData(7, 0); txWrPtr := txWrPtr + 1.U }
  when(txPop)  { txDataReg := txFifo(txRdPtr); txRdPtr := txRdPtr + 1.U; txStart := true.B }

  // LSR：THRE = **发送 FIFO 空**（16550 口径，也是"驱动一次盲写 16 字节不会溢出"的前提）；
  //      TEMT = FIFO 空 **且** 移位器也空。
  // ⚠️ 不要改成"FIFO 未满"：驱动每收到 THRE 就盲写 `tx_loadsz`=16 字节，若"未满"就报 THRE，
  //    那么 FIFO 只空出 1 个位置时也会被再塞 16 字节 ⇒ **又丢字**（这正是本次要修的缺陷本身）。
  private val thre = txCount === 0.U
  private val temt = txIdle && thre
  // [6]=TEMT [5]=THRE [1]=OE(溢出) [0]=DR（DR = 接收 FIFO 非空）
  private val lsr = Cat(0.U(1.W), temt, thre, 0.U(3.W), rxOverrun, rxNotEmpty)

  private val rxPending = ierReg(0) && rxNotEmpty
  // THRE 中断（IER.bit1）：**发送 FIFO 空**时挂起 —— 与 LSR.THRE 同一个条件（真实 16550 亦如此）。
  // Linux 的 `serial8250_tx_chars` 在发送队列排空时会 `serial8250_stop_tx` 关掉 THREI ⇒ 不会中断风暴。
  // 为什么必须有它（任务 #81）：Linux 的 8250 驱动发送是**中断驱动**的 —— `serial8250_start_tx` 打开 THREI 后
  // 等"THR 空"中断来推下一批字节；我们原来只有"收到数据"这一种中断 ⇒ 交互式 `ttyS0` 会在写完第一字节后停住。
  // 注意 `earlycon`（#79 验收走的路）是**纯轮询**、且 `init_port` 只保留 `IER.UUE`(bit6) ⇒ 这里对它零影响。
  private val threPending = ierReg(1) && thre
  private val irqPending  = rxPending || threPending
  // IIR 优先级按 16550：收到数据(010=0x04) > THR 空(001=0x02)（识别码数值越小优先级越高）。
  private val iirPendingCode = Mux(rxPending, "b010".U(3.W), Mux(threPending, "b001".U(3.W), 0.U(3.W)))
  private val iir = Cat(Mux(fcrReg(0), "b11".U(2.W), 0.U(2.W)),  // [7:6] FIFO 使能位（跟随 FCR）
                        0.U(2.W),                                  // [5:4] 保留
                        iirPendingCode,                            // [3:1] 识别位（010=收到数据 / 001=THR 空）
                        Mux(irqPending, 0.U(1.W), 1.U(1.W)))       // [0] 0=有 pending

  io.axi.arready := true.B
  when(io.axi.arvalid && io.axi.arready) {
    switch(io.axi.araddr(4, 2)) {
      is(Uart16550Regs.RBR_THR_DLL) {
        when(dlab) { rData := Cat(0.U(24.W), dllReg) }
        .otherwise {                                  // ★ 取 FIFO 头（rxPop 同拍推进读指针）
          rData := Cat(0.U(24.W), rxFifo(rxRdPtr))
          rbrRead := true.B
        }
      }
      is(Uart16550Regs.IER_DLM) { rData := Cat(0.U(24.W), Mux(dlab, dlmReg, ierReg)) }
      is(Uart16550Regs.IIR_FCR) { rData := Cat(0.U(24.W), iir) }
      is(Uart16550Regs.LCR)     { rData := Cat(0.U(24.W), lcrReg) }
      is(Uart16550Regs.MCR)     { rData := Cat(0.U(24.W), mcrReg) }
      is(Uart16550Regs.LSR)     { rData := Cat(0.U(24.W), lsr); lsrRead := true.B }
      is(Uart16550Regs.MSR)     { rData := 0.U(32.W) }
      is(Uart16550Regs.SCR)     { rData := Cat(0.U(24.W), scrReg) }
    }
    rValid := true.B
  }.elsewhen(io.axi.rready) { rValid := false.B }

  io.axi.bresp := 0.U(2.W)
  io.axi.bvalid := bValid
  io.axi.rdata  := rData
  io.axi.rresp  := 0.U(2.W)
  io.axi.rvalid := rValid
  // awready/wready：上一次事务没被 B 消化就不再收新的（与 UART/GPIO 同款）
  io.axi.awready := !bValid
  io.axi.wready  := !bValid

  // 中断线 = 收到数据 或 THR 空（后者仅在软件把 IER.bit1 打开时有效 ⇒ 现代码/固件的轮询路径不受影响）。
  io.irq := irqPending
}
