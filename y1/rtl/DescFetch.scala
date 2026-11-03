import spinal.core._
import spinal.lib._
import spinal.lib.bus.amba4.axi._

/** 取表 FSM 的状态（显式枚举，生成 Verilog 里就是一个 `DescFetchState` 型寄存器）。
  *
  *   IDLE    —— 等 `go`（**单拍脉冲**语义，与 `DdrMaster.start` 同口径）；
  *   START   —— 把 `ddrMaster.start` 举**一拍**（RD 模式、src=dst=descAddr、len=32）；
  *   COLLECT —— 等 `rd_valid` 成交 4 拍，逐拍把 8 字节拼成 2 个 32-bit 字；`err` 也在这里被抓；
  *   DONE    —— `words_valid` 置位（保持到下一次 `go`）、`busy` 落 0，回 IDLE。
  */
object DescFetchState extends SpinalEnum {
  val IDLE, START, COLLECT, DONE = newElement()
}

/** DescFetch —— 用 `DdrMaster(RD)` 从 DDR 里**取一个 32 B 描述符**（8 个 32-bit 小端字），
  * 并用 `DescDefs.DescWords` 把它**纯组合**译成 14 个字段（S1 的 RTL 半：主机写表 → NPU 读回）。
  *
  * ---------------------------------------------------------------------------
  * ★ 取表口径（本文件的核心契约）
  *   · **32 B = 8 个 32-bit 小端字**；一笔 `DdrMaster(mode=1, src=descAddr, len=32)`：
  *     分块 = 4 拍 x 8 B（`beats = min(16, 32/8) = 4`、`arlen=3`）；地址 32 B 对齐由 CHK 校验。
  *   · 小端拼字（与块缓冲/RD 流的字节口径同源：`rd_data[7:0]` = **最低地址**那个字节）：
  *       `word(2k)   = rd_data[31:0]`（第 k 拍的低 4 字节 = 地址 descAddr+8k+0..3）
  *       `word(2k+1) = rd_data[63:32]`（第 k 拍的高 4 字节 = 地址 descAddr+8k+4..7）
  *     与 `desc_table.pack` 的 `struct.pack("<8I")` **逐字节同源** ⇒ 闸门可逐字对账。
  *   · `err` **透传** `DdrMaster.err`（入参非法 ⇒ CHK 一拍 err、一个字节都不搬）：
  *     `descAddr` 未 32 B 对齐时 `words_valid` 保持 0（负对照 B 钉的就是这两条）。
  *
  * ★ 为什么 `dst` 也接 `descAddr`（不是 0）：`DdrMaster` 的 CHK 对 `src` **和** `dst` 都做
  *   32 B 对齐校验（RD 模式下 `dst` 本来不参与搬运）。把 `dst` 也接成 `descAddr` ⇒ 描述符地址的
  *   对齐性由被复用的那一份入参校验兜住，本文件**不需要**再写第二条 err 通路（单一真源）。
  *
  * ★ 为什么译码字段也从这个模块出（而不是只出 8 个字）：`DescDefs.DescWords` 是"位打包的 RTL 真源"，
  *   它必须**活在网表里**（否则就是死代码，"逐字段一致"无处可证）。本模块把 `words` 与 17 个译码
  *   字段一起驱动出去 ⇒ 闸门可以拿 `word(i)` 对 `desc_table.pack` 的期望**逐字**对账、再拿
  *   `tpe/flags/...` 对 `desc_table.unpack` 的字段**逐字段**对账（两处独立实现互相钉死）。
  *
  * ★ 端口语义细说：
  *   · `go`       —— **单拍脉冲**（与 `DdrMaster.start` 同口径；IDLE 态采样）。树内调用方
  *                   （C3.10 的 LayerSched）**只在 `busy==0` 时脉冲一次**；本模块内部还串了
  *                   `!ddrMaster.busy`，免得上一笔搬运还没彻底回 IDLE 就被重入（重入会让本
  *                   FSM 卡在 COLLECT）。
  *                   ⚠ 契约的**方向**：因为 `busy` 已覆盖内部主口的在途相位（见下），
  *                   "在 `busy==0` 时脉冲的 `go`" **必然**被本模块受理 —— 不存在"`busy` 已落 0
  *                   但内部主口还忙、于是 `go` 被 `!ddrMaster.busy` 静默吞掉"的死区。
  *   · `words_valid` —— **电平**：4 拍收齐后置 1、**保持**到下一次 `go`（= "结果就绪"，
  *                   同时也是完成指示；主机不必去数拍）。`err` 时它保持 0。
  *   · `busy`     —— `go` 起、到取表**彻底完成**（内部 `DdrMaster` 也回 IDLE）之间恒为 1：
  *                   `busyR` **或** `ddrMaster.io.busy`。**不是**只到 `words_valid` 置位为止
  *                   （DONE 之后内部主口还要走 `WNEXT -> DONE -> IDLE`，`busyR` 先落 0）。
  *   · `err`      —— 直接透传 `DdrMaster.err`（**单拍脉冲**，与上游同形；C3.11 负责锁成电平）。
  *   · `words(i)` —— 8 个 32-bit 字；`words(0)` 是**最低地址**那个字（小端）。
  *   · `ddr`      —— AXI4 主口（与 `DdrMaster.io.axi` **同形**；本模块把它原样透传给它内部那份
  *                   `DdrMaster`）。
  *
  * ★ 与 `DdrMaster` 同形的那份配置（`DdrMasterConfig()`）：本模块**不**另开形状变体，
  *   `io.ddr` 的 `Axi4Config` 逐参数照抄 `DdrMaster.axiCfg`；哪天 DdrMaster 改了形状而这里没同步，
  *   `io.ddr <> ddrMaster.io.axi` 会在展开期因类型不符**响亮报错**，不会静默接错。
  */
case class DescFetch() extends Component {

  /** 与 `DdrMaster` 同源的一份形状参数（顶层主口与内部实例都用它）。 */
  val ddrCfg = DdrMasterConfig()

  val io = new Bundle {
    val go        = in  Bool()
    /** 描述符地址（**必须 32 B 对齐**；对齐性由内部 `DdrMaster` 的 CHK 校验并报 err）。 */
    val descAddr  = in  UInt(28 bits)
    /** 8 个 32-bit 小端字（`words(0)` = 最低地址那个字）。 */
    val words     = out Vec(Bits(32 bits), 8)
    /** 结果就绪（电平，保持到下一次 `go`；`err` 时保持 0）。 */
    val words_valid = out Bool()
    /** 取表在途（= 本 FSM 的 `busyR` **或** 内部 `DdrMaster.busy`；见文件头契约）。 */
    val busy      = out Bool()
    /** 透传 `DdrMaster.err`（单拍脉冲）。 */
    val err       = out Bool()

    // ---- DescDefs.DescWords 译出的 17 个字段（与 desc_table.unpack 逐字段对账用）----
    val tpe        = out UInt(8 bits)
    val flags      = out UInt(8 bits)
    val imgW       = out UInt(16 bits)
    val imgH       = out UInt(16 bits)
    val cIn        = out UInt(16 bits)
    val cOut       = out UInt(16 bits)
    val group      = out UInt(8 bits)
    val stride     = out UInt(4 bits)
    val pad        = out UInt(4 bits)
    val srcA       = out UInt(32 bits)
    val dstA       = out UInt(32 bits)
    val inBytes    = out UInt(32 bits)
    val qShift     = out UInt(8 bits)
    val layerId    = out UInt(8 bits)
    val isSentinel = out Bool()
    val head       = out Bool()
    val tail       = out Bool()

    /** AXI4 主口（与 `DdrMaster.io.axi` 同形）。 */
    val ddr = master(Axi4(Axi4Config(
      ddrCfg.ADDR_W, ddrCfg.DATA_W,
      idWidth     = ddrCfg.ID_W,
      useId       = true,
      useLen      = true,
      useLock     = false,
      useRegion   = false,
      useQos      = false,
      awUserWidth = 0, arUserWidth = 0, wUserWidth = 0, bUserWidth = 0, rUserWidth = 0
    )))
  }
  noIoPrefix()

  // ---------------------------------------------------------------------------
  // 内部 DdrMaster（RD 模式）—— 本模块把 AXI 主口原样透传出去
  // ---------------------------------------------------------------------------
  val ddrMaster = new DdrMaster(ddrCfg)
  io.ddr <> ddrMaster.io.axi

  // 常量入参（见文件头）：RD、src=dst=descAddr、len=32（= 一个描述符）。
  // `len = 32` 过 CHK 的 `len % 32 == 0 && len != 0`；`src/dst` 的对齐校验就是描述符地址的校验。
  ddrMaster.io.src      := io.descAddr
  ddrMaster.io.dst      := io.descAddr
  ddrMaster.io.len      := U(32, 32 bits)
  ddrMaster.io.mode     := U(1, 2 bits)   // 1 = RD（只读；dst 不参与）
  ddrMaster.io.sg_valid := False           // ★ B3b：本模块不用 SG-RD
  ddrMaster.io.sg_addr  := U(0, ddrCfg.ADDR_W bits)
  ddrMaster.io.sg_flush := False
  ddrMaster.io.sg_beatsM1 := U(0, 4 bits)
  ddrMaster.io.wr_valid := False          // 树内 Scala 调用方必须显式驱动（SpinalHDL 拒绝悬空输入）
  ddrMaster.io.wr_data  := B(0, ddrCfg.DATA_W bits)
  // ★★ T-S2b：写字节掩码（本模块只读，恒"全字节有效"⇒ 与改动前同形）
  ddrMaster.io.wstrb    := B(0xFF, ddrCfg.DATA_W / 8 bits)

  // ---------------------------------------------------------------------------
  // 取表 FSM 的寄存器
  // ---------------------------------------------------------------------------
  val state   = Reg(DescFetchState()) init DescFetchState.IDLE
  /** 本拍是第几拍 0..3（4 拍 = 32 B）。 */
  val beatIdx = Reg(UInt(2 bits)) init 0
  /** 8 个 32-bit 字。写它是**静态下标解码**（`when(beatIdx === k)` 各一条），
    * 不用 `wReg(dynIdx) := ...` —— 后者会生成一把 4 路的动态写译码，且与项目口径不符。 */
  val wReg    = Vec(Reg(Bits(32 bits)) init B(0, 32 bits), 8)
  val busyR   = Reg(Bool()) init False
  val validR  = Reg(Bool()) init False

  // 默认值（写在 switch 之前 ⇒ 被 switch 内的赋值覆盖；这就是"一拍脉冲/电平"的实现口径）
  ddrMaster.io.start    := False
  ddrMaster.io.rd_ready := False

  switch(state) {
    // ---------------- IDLE：等 go（单拍脉冲；再串一道 !busy 防重入）----------------
    is(DescFetchState.IDLE) {
      when(io.go && !ddrMaster.io.busy) {
        state   := DescFetchState.START
        busyR   := True
        validR  := False        // 新的一次取表：先把"结果就绪"清掉
        beatIdx := 0
      }
    }

    // ---------------- START：start 举一拍（下一拍起 DdrMaster 进 CHK）----------------
    is(DescFetchState.START) {
      ddrMaster.io.start := True
      state := DescFetchState.COLLECT
    }

    // ---------------- COLLECT：收 4 拍，逐拍拼 2 个字；err 也在这里抓 ----------------
    is(DescFetchState.COLLECT) {
      ddrMaster.io.rd_ready := True          // 本态全程收（无背压）⇒ 有 valid 就是成交
      when(ddrMaster.io.err) {               // 入参非法：一拍 err、一个字节都不搬 ⇒ 回 IDLE
        state := DescFetchState.IDLE
        busyR := False
      }
      when(ddrMaster.io.rd_valid) {
        // 静态下标解码：本拍就是第 k 拍 ⇒ 写 word(2k)/word(2k+1)（小端：低 4 字节在前）
        for (k <- 0 until 4) {
          when(beatIdx === U(k, 2 bits)) {
            wReg(2 * k)     := ddrMaster.io.rd_data(31 downto 0)
            wReg(2 * k + 1) := ddrMaster.io.rd_data(63 downto 32)
          }
        }
        when(beatIdx === U(3, 2 bits)) {
          state := DescFetchState.DONE
        } otherwise {
          beatIdx := beatIdx + 1
        }
      }
    }

    // ---------------- DONE：结果就绪（电平），回 IDLE ----------------
    is(DescFetchState.DONE) {
      validR := True
      busyR  := False
      state  := DescFetchState.IDLE
    }
  }

  // ---------------------------------------------------------------------------
  // 输出：8 个字 + 17 个译码字段（全是连续表达式 ⇒ 落成 assign，time-0 就有定值）
  // ---------------------------------------------------------------------------
  for (i <- 0 until 8) {
    io.words(i) := wReg(i)
  }

  val dw = DescWords(wReg(0), wReg(1), wReg(2), wReg(3), wReg(4), wReg(5), wReg(6), wReg(7))
  io.tpe        := dw.tpe
  io.flags      := dw.flags
  io.imgW       := dw.imgW
  io.imgH       := dw.imgH
  io.cIn        := dw.cIn
  io.cOut       := dw.cOut
  io.group      := dw.group
  io.stride     := dw.stride
  io.pad        := dw.pad
  io.srcA       := dw.srcA
  io.dstA       := dw.dstA
  io.inBytes    := dw.inBytes
  io.qShift     := dw.qShift
  io.layerId    := dw.layerId
  io.isSentinel := dw.isSentinel
  io.head       := dw.head
  io.tail       := dw.tail

  io.words_valid := validR
  // ★ I1：`busy` 必须覆盖**内部主口的在途相位** —— `busyR` 在 DONE 就落 0（比内部 `DdrMaster`
  //   回 IDLE **早一拍**：DONE 之后主口还要 WNEXT -> DONE -> IDLE）。若只出 `busyR`，就存在
  //   "io.busy==0 但 ddrMaster.busy==1" 的一拍窗口：调用方按契约在 `busy==0` 时脉冲的 `go`
  //   会撞上 IDLE 态的 `io.go && !ddrMaster.io.busy` 守卫而被**静默吞掉**（且没有重试路径）。
  //   取 `busyR || ddrMaster.io.busy` ⇒ `busy==0` 时 `ddrMaster.busy` 必为 0 ⇒ 该脉冲必被受理；
  //   两个都回 IDLE 才会落 0 ⇒ 无死锁（`busyR` 只在 IDLE/COLLECT-err/DONE 三处落 0）。
  io.busy       := busyR || ddrMaster.io.busy
  io.err        := ddrMaster.io.err
}
