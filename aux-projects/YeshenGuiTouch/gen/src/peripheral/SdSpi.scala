import chisel3._
import chisel3.util._

// ===================== SD 卡（SPI 模式）只读通路：SPI 主控 + 初始化 + 单块读 =====================
// 用途（板级第二步）：把系统镜像从 TF 卡读进 DDR，替代"UART 灌几十 MB 要一个多小时"。
// 本模块是**只读**最小通路：实现 SD SPI 模式必需的 `CMD0 → CMD8 → CMD55+ACMD41(轮询) → CMD58`，
// 之后可反复 `CMD17` 读 512B 块（`inited` 一旦置起就不再重做初始化）。
//
// 设计要点（每一条都对应 SPI 模式 SD 的硬性约定，不是风格）：
//  1. **SCK 由系统时钟分频**，一个字节 = 8 个 SCK 周期 = `8*2*(div+1)` 个系统时钟。
//     初始化必须 ≤400kHz ⇒ `divSlow`（默认 127 ⇒ 100MHz/256 ≈ 390.6kHz）；数据传输用 `divFast`
//     （默认 1 ⇒ 100MHz/4 = 25MHz）。mode 0（CPOL=0/CPHA=0）：前半周期 SCK 低并把本位放到 MOSI，
//     后半周期 SCK 高，**在后半周期最后一拍采 MISO**（卡在 SCK 下降沿换数据 ⇒ 留了约 `div+1` 拍建立时间）。
//  2. **CRC 只在 CMD0/CMD8 被卡校验**：CMD0 送 0x95、CMD8 送 0x87，其余命令送 0xFF。
//  3. **响应**：R1 一字节（bit7=0 才算有效）；R3/R7 = R1 + 4 字节（CMD8/CMD58 要读）；CMD17 的数据前有
//     令牌 0xFE，之后 512B + 2B CRC（CRC 不校验，本模块只吃掉不发断言）。
//  4. **寻址**：CMD58 的 OCR bit30 (CCS)=1 表示 SDHC/SDXC ⇒ CMD17 参数就是块号；=0（SDSC，≤2GB）
//     则要用字节地址（块号 << 9）。本模块用 `sdhc` 自动折算。
//  5. **每条等待路径都必须有超时**：卡不回话（没插卡/接线错/CRC 被拒）是最常见的故障，
//     没有超时的实现会在板上永久挂住。超时按**相位**给不同错误码，见 `io.err` 说明。
//  6. **上电要 74+ 个 SCK（CS 高、MOSI 高）**：`pWarm` 发 10 字节 0xFF（=80 拍）后才拉低 CS 发 CMD0。
//  7. **只支持 SDv2 及以后的卡**：CMD8 必须回 R7 且回显 0x1AA；SDv1 卡（CMD8 回 0x05）会以 err=2 落败
//     —— 这是刻意的，不做 HCS 之外的兼容分支（板子上用的是现代 TF 卡）。
//
// `io.err` 编码（0 = 无错）：
//   1 = CMD0 等 R1 超时（没插卡 / 卡不认 SPI 模式）
//   2 = CMD8 的 R7 对不上（回显不是 0x1AA，含"卡根本不回"）
//   3 = CMD55/ACMD41 超时（卡进了 idle 却不出来 / 卡不回话）
//   4 = CMD58 的 R1 非 0
//   5 = CMD17/CMD18 的 R1 非 0（读命令被拒）
//   6 = 数据令牌超时（R1 回 0 了但卡迟迟不给 0xFE）
//   7 = CMD12（停止多块读）的 R1 非 0 / 不来 ★ 2026-10-26
//
// ★ 多块读（CMD18）：`nblk > 1` 时走 **一条 CMD18 + 连续 nblk 块 + 一条 CMD12**。
//   动机（板上实测）：卡对**每条 CMD17** 的读延迟约 **590 µs**（与 SCK 无关；5 MHz/12.5 MHz 两臂
//   解出同一常量），20,910 块就是 ~12 s —— 这才是装载时间的大头，不是 SCK。多块读把每条命令
//   摊到一整段（最多 3,574 块），只留一个"段内每块 token 间隙"。
class SdSpiIO extends Bundle {
  // ---- 请求接口（系统时钟域）----
  val start = Input(Bool())          // **单拍脉冲**：发起一次"确保初始化 + 读 `nblk` 个连续块"
  val lba   = Input(UInt(32.W))      // 起始块号（SDHC/SDXC）；SDSC 时模块内部折算成字节地址
  val nblk  = Input(UInt(16.W))      // 连续块数（1 ⇒ 仍走 CMD17，逐块语义与旧版**逐位相同**）
  val busy  = Output(Bool())
  val done  = Output(Bool())         // 单拍脉冲：本次成功（512B 已全部交出）
  val err   = Output(UInt(4.W))      // 见文件头
  // 诊断（SD 调试）：⚠️ 必须是 **32 位**——板侧只有这一条 32bit 回发通道，写 20 位会被截断
  // （`{sckCnt[0], lastRx, errCode, ph, st}` 只剩 SCK 计数的**最低位**，等于没法判"有没有打时钟"，
  //  2026-10-06 上板实测中过这个坑）。位域见文件末尾 `io.dbg` 赋值处。
  val dbg   = Output(UInt(32.W))
  // ---- 512B 数据输出（32bit/拍，MSB 先：第 0 个字节在 dData 的最高字节）----
  val dValid = Output(Bool())
  val dReady = Input(Bool())
  val dData  = Output(UInt(32.W))
  val dLast  = Output(Bool())        // 与第 127 个字同拍
  // ---- SPI 物理引脚（板级引到 40Pin 的 J10）----
  val sck   = Output(Bool())
  val mosi  = Output(Bool())
  val csN   = Output(Bool())
  val miso  = Input(Bool())
  // ---- 状态 ----
  val inited = Output(Bool())        // 初始化已完成（可反复 start 读块）
  val sdhc   = Output(Bool())        // OCR.CCS = 1（块寻址）
}

class SdSpi(divFast: Int = 1, divSlow: Int = 127, toMax: Int = 20000000) extends Module {
  require(divFast >= 0 && divFast <= 255, "divFast 必须在 0..255")
  require(divSlow >= divFast, "divSlow 必须 >= divFast（初始化不能快于数据传输）")
  require(toMax > 0 && toMax < (1 << 25), "toMax 必须在 1..2^25-1（tout 是 25 位）")
  val io = IO(new SdSpiIO)

  // ===================== 第一层：字节引擎 =====================
  // 契约：`want` 为真且引擎空闲时自动开始下一个字节；`spiDone` 那拍 `spiRx` 是本字节收到的值。
  // 三态（eIdle→eBits→eDone→eIdle）里 eDone 是**独立一拍**，让上层有稳定的时机读 `spiRx`
  // 并决定下一个字节（也保证每个字节之间 SCK 至少低两拍）。
  val eIdle :: eBits :: eDone :: Nil = Enum(3)
  val eSt   = RegInit(eIdle)
  val eDiv  = RegInit(divSlow.U)          // 当前分频（慢=初始化 / 快=数据）
  val eT    = RegInit(0.U(10.W))          // 相位计数 t：0 .. 2*(div+1)-1
  val eBit  = RegInit(7.U(3.W))           // 当前位（MSB 先）
  val eSh   = RegInit(0.U(8.W))           // 发送移位
  val eRx   = RegInit(0.U(8.W))           // 接收移位
  val eSck  = RegInit(false.B)
  val eMosi = RegInit(true.B)             // 空闲时 MOSI 拉高（SD 要求）
  // 诊断：整次事务里采到的 MISO 有没有**高过**。板侧最有用的一位：
  //   MISO 恒低 = 卡根本没在驱动（无卡/未选中/未供电/线断），与"卡回了但对不上"区分开。
  // ⚠️ 必须在字节引擎**之前**声明（引擎里那句 `misoHi := misoHi | io.miso` 要用它）。
  val misoHi = RegInit(false.B)

  // ⚠️ 必须用 `+&`：`eDiv` 是 7 位，`eDiv + 1.U` 会在 127+1 处**截断成 0**（Chisel 的 `+`
  // 结果位宽 = 操作数最大位宽），SCK 就会一进 eBits 就恒高。这个坑在波形上是
  // "SCK 只上升一次、之后再也不动"，且一个字节变成 8× 长。
  private val eHalf   = eDiv +& 1.U       // 8 位：1..256
  private val ePeriod = eHalf << 1        // 9 位：2..512

  val want   = Wire(Bool())
  val txByte = Wire(UInt(8.W))

  switch(eSt) {
    is(eIdle) {
      eSck := false.B
      eMosi := true.B
      eT := 0.U
      when(want) {
        eSh := txByte
        eRx := 0.U
        eBit := 7.U
        eSt := eBits
      }
    }
    is(eBits) {
      eMosi := eSh(7)
      eSck := eT >= eHalf                   // 前半周期低、后半周期高
      // ★ 采样点对齐 tf_test：它在 `!hi`（SCK 刚变高）那一支里采 MISO。本实现里 SCK 在
      //   `eT === eHalf + 1` 起为高 ⇒ 在 `eT === eHalf`（上升沿**前**那一拍）取 MISO 与之等价
      //   （卡在上一个下降沿就换好了数据）。原先放在高相位**末尾**：100kHz 下也在数据眼内，
      //   但它离"下一个下降沿换数据"只隔 2 拍、余量最差，且与已验收的参考不一致。
      when(eT === eHalf) {
        eRx := Cat(eRx(6, 0), io.miso)
        misoHi := misoHi | io.miso          // 诊断：这次事务里卡**有没有**驱动高过
      }
      when(eT === ePeriod - 1.U) {          // 高相位末尾：收尾并移出下一位
        eT := 0.U
        when(eBit === 0.U) { eSt := eDone }
        // ⚠️ 发送是 **MSB 先**（`eMosi := eSh(7)`）⇒ 必须**左移**把下一位送进第 7 位；
        // 右移会让第 7 位永远是 0（整字节 MOSI 恒 0）。
        .otherwise { eBit := eBit - 1.U; eSh := eSh << 1 }
      }.otherwise { eT := eT + 1.U }
    }
    is(eDone) {
      eSck := false.B
      eMosi := true.B
      eSt := eIdle
    }
  }

  val spiDone = eSt === eDone
  val spiRx   = eRx
  io.sck  := eSck
  io.mosi := eMosi

  // ===================== 第二层：命令/响应序列 =====================
  // ⚠️ 新相位一律**追加在末尾**：不移动已有相位的编码（网表里是一堆 `ph == N` 比较）。
  //   ★ 2026-10-26 追加 CMD18 多块读的 6 个相位（pCmd18/pTokM/pDataM/pCrcM/pStop/pStopR1）。
  val pIdle :: pWarm :: pCmd0 :: pCmd8 :: pCmd55 :: pAcmd41 :: pCmd58 :: pReady :: pCmd17 :: pTok :: pData :: pCrc :: pDone :: pFail :: pGap :: pCmd18 :: pTokM :: pDataM :: pCrcM :: pStop :: pStopR1 :: Nil = Enum(21)
  val sSend :: sWait :: sRead :: sAct :: sTok :: Nil = Enum(5)

  val ph = RegInit(pIdle)
  val st = RegInit(sAct)

  // 16 项而不是 6 项：索引是 4 位的 `bc`，Vec 大小与索引位宽对齐才不会触发 Chisel 的
  // "Dynamic index is too wide" 警告（超范围项永不使用）
  val cmdBuf = RegInit(VecInit(Seq.fill(16)(0xFF.U(8.W))))
  val cmdLen = RegInit(0.U(4.W))          // 本相位要发的字节数
  val bc     = RegInit(0.U(4.W))          // 已发到第几个
  val isFill = RegInit(false.B)           // 本相位发的是全 0xFF 填充（暖机/CRC 尾）
  val waitR1 = RegInit(false.B)           // 本相位发完是否等一个 R1
  val rspLen = RegInit(0.U(3.W))          // R1 之后还要读几字节（0 或 4）
  val rspIdx = RegInit(0.U(3.W))
  val rspAcc = RegInit(0.U(32.W))         // R3/R7 的 4 字节
  val r1     = RegInit(0xFF.U(8.W))
  // R1 的"接受规则"（照抄已验收的 tf_test_200mini）：它按命令只认特定值，而**不是**任何 bit7==0 的字节。
  // 理由（上板实测）：模块无卡/未应答时 MISO 会恒为 0x00（tf_test README 明写"resp=00 属浮空默认态"），
  // 原来的"只认 bit7==0"会把这种 0x00 当成 R1 ⇒ 后面 4 字节 R7 跟着错位 ⇒ 报"CMD8 R7 对不上"。
  val r1Mask = RegInit(0xFF.U(8.W))
  val r1Val  = RegInit(0x00.U(8.W))
  val lastRx = RegInit(0xFF.U(8.W))          // 等待期最后收到的字节（诊断：看卡到底回了什么）
  // 诊断：**实际发出的 SCK 上升沿数**（12 位，失败后冻结）。用来判"我们到底有没有在打时钟"。
  val sckCnt = RegInit(0.U(12.W))
  val eSckD  = RegNext(eSck, false.B)
  // ★ 对齐 tf_test 的"失败自动重试"：**初始化阶段**失败不算终点（tf_test 每 250ms 重来一轮、
  //   它的 UART 报文因此是"活线探针"）。这里给有限次：重试用尽才把 err 交给上层 ⇒ SD→ETH→UART
  //   的三级回退语义不变（无限重试会把整机启动挂死在这条路上）。
  val initRetry = RegInit(0.U(4.W))
  val MAX_INIT_RETRY = 8
  val tout   = RegInit(0.U(25.W))
  val retry  = RegInit(0.U(9.W))          // ACMD41 轮询次数（9 位，上限照 tf_test = 499 轮）
  val lbaR   = RegInit(0.U(32.W))
  // ---- ★ CMD18：本次事务的块数（start 时锁存）与"还剩几块" ----
  val nblkR    = RegInit(1.U(16.W))
  val blkLeftR = RegInit(0.U(16.W))       // 当前块之后还有几块（0 ⇒ 本块读完就 CMD12）

  val errCode = RegInit(0.U(4.W))
  val initedR = RegInit(false.B)
  val sdhcR   = RegInit(false.B)
  val busyR   = RegInit(false.B)
  val doneR   = RegInit(false.B)

  // 数据通路
  val dataWord   = RegInit(0.U(32.W))
  val byteInWord = RegInit(0.U(2.W))
  val wordIdx    = RegInit(0.U(8.W))
  val wordV      = RegInit(false.B)
  val wordLast   = RegInit(false.B)

  // ★ 命令间的 `pGap` 目标相位（`startCmd` 暂存，`pGap` 发完 gap 字节后落过去）
  val nxPh = RegInit(pIdle)

  // ---- 相位进入的公共动作 ----
  // ★★ 2026-10-06 上板定案的修复：**命令之间必须给一整字节的 CS 高电平，并且这期间要打 8 个 SCK**。
  //
  // 板上证据（同板同卡、同四脚；已验收参考 tf_test 出 `TF-OK r0=01 r8=01AA`，我们只到 CMD0）：
  //   我们回发的诊断字 `sdDbg=0xB207F903` ⇒ `misoHi=1`（卡这次**在**驱动）、`errCode=2`（CMD8 拿不到 R1）、
  //   `lastRx=0x7F`（卡全程只回 0xFF 填充）。⇒ **卡认了 CMD0、不认 CMD8**。
  //
  // 逐行对照 tf_test 的 `sd_spi_init.v` 后找到根因：它的 `ST_R1` 收到应答后拉高 CS 进 `ST_GAP`，
  //   而它的 FSM **只在"一个字节发完"时推进**（`if (bpend && byt_done)`），且 `ST_GAP` 的 `need_byte=1`
  //   ⇒ ST_GAP **整整持续一个 0xFF 字节**：@27MHz 135×2 = **10µs**，期间 CS 高、**SCK 走满 8 拍**。
  //   我们原先在 `startCmd` 里把 `csGap` 置 2（@100MHz = **20ns**）且用 `~(|csGap)` 把 `want` 门掉
  //   ⇒ 那段里 **CS 只高 20ns、一个时钟都没有** ⇒ 卡根本认不出新命令帧。
  //   这**完全解释**了现象：CMD0 前面有 80 拍暖机（CS 高、含时钟）所以第一条命令被认到；
  //   之后每条命令的 CS 帧都短到卡认不出 ⇒ 卡全程只回填充 ⇒ 我们等 R1 超时。
  //
  // ⇒ 现在统一走 `pGap`：**先发一个 0xFF 字节（CS 高、SCK 照走）**，再由它落到目标相位发 6 字节命令。
  //   （与 tf_test 的 ST_GAP 逐拍同义；100kHz 下一字节 = 80µs，比它的 10µs 余量更大。）
  def startCmd(next: UInt, cmd: Int, arg: UInt, crc: Int, rlen: Int): Unit = {
    val a = arg.pad(32)
    nxPh := next                 // 目标相位：pGap 负责在 gap 字节之后落过去
    ph := pGap
    st := sSend
    isFill := true.B             // gap 字节 = 0xFF
    cmdBuf(0) := (0x40 | cmd).U(8.W)
    cmdBuf(1) := a(31, 24)
    cmdBuf(2) := a(23, 16)
    cmdBuf(3) := a(15, 8)
    cmdBuf(4) := a(7, 0)
    cmdBuf(5) := crc.U(8.W)
    cmdLen := 1.U                // 本次只发 gap 这一个字节；6 字节命令由 pGap 落到 nxPh 后再发
    bc := 0.U
    waitR1 := false.B            // gap 字节不等应答
    // 本命令"什么算有效 R1"（tf_test 口径）：
    //   CMD0/CMD8  —— 卡在 idle ⇒ **必须恰好 0x01**；
    //   CMD55      —— 0x00 或 0x01；
    //   ACMD41     —— ★ **0x00(就绪) 或 0x01(还在初始化) 都算"有效应答"**。这一条是 2026-10-06 上板
    //                 定案的第二处修复：原先把它归进"必须 0x00"，于是卡回 0x01（正常 busy）时被当成
    //                 "根本没应答" ⇒ 继续灌 0xFF ⇒ 超时（板上实测 `errCode=3`、`lastRx=0xFF`）⇒
    //                 **永远进不了"重发 CMD55+ACMD41"那条路**。tf_test 的 step3 正是 `0x00 或 0x01` 都接、
    //                 0x01 时重来一轮。
    //   CMD58/CMD17 —— 必须 0x00。
    val (m, v) = cmd match {
      case 0 | 8   => (0xFF, 0x01)
      case 55 | 41 => (0xFE, 0x00)
      case _       => (0xFF, 0x00)
    }
    r1Mask := m.U(8.W)
    r1Val  := v.U(8.W)
    rspLen := rlen.U
    rspIdx := 0.U
    rspAcc := 0.U
    tout := 0.U
  }

  // `startFill`：只发 n 字节 0xFF（暖机 / 数据后的 CRC 两字节），不等任何响应
  def startFill(next: UInt, n: Int): Unit = {
    ph := next
    st := sSend
    isFill := true.B
    cmdLen := n.U
    bc := 0.U
    waitR1 := false.B
    rspLen := 0.U
    tout := 0.U
  }

  // 超时错误码按相位区分（便于板上故障定位，见文件头）
  val timeoutCode = MuxLookup(ph, 1.U)(Seq(
    pCmd8   -> 2.U,
    pCmd55  -> 3.U,
    pAcmd41 -> 3.U,
    pCmd58  -> 4.U,
    pCmd17  -> 5.U,
    pTok    -> 6.U,
    pCmd18  -> 5.U,                            // ★ CMD18 被拒与 CMD17 同码（都是"读命令不认"）
    pTokM   -> 6.U,
    pCrcM   -> 6.U,
    pStop   -> 7.U,                            // ★ CMD12 阶段超时（停止多块读）
    pStopR1 -> 7.U
  ))

  // ---- 通用字节发射（组合）----
  want := false.B
  txByte := 0xFF.U
  when(st === sSend) {
    want := true.B
    txByte := Mux(isFill, 0xFF.U(8.W), cmdBuf(bc))
  }.elsewhen(st === sWait || st === sRead || st === sTok) {
    want := true.B
    txByte := 0xFF.U
  }
  when(ph === pData || ph === pDataM) {      // 背压：一个 32bit 字没被取走就不再收字节（多块同理）
    want := !wordV
    txByte := 0xFF.U
  }

  tout := 0.U                                 // 默认：不在等待态就清计时器

  // ---- 通用推进：命令字节发完 ----
  when(st === sSend && spiDone) {
    when(bc === cmdLen - 1.U) {
      st := Mux(waitR1, sWait, sAct)
      bc := 0.U
      tout := 0.U
    }.otherwise { bc := bc + 1.U }
  }

  // ---- 通用推进：等 R1（bit7=0 才算数）----
  // ⚠️ 超时计数**每拍**都走（不是每个字节走一次）：卡一个字节要 256 拍，按字节计的话
  // `toMax` 要乘 256 才等价，实际就等于永远不超时。
  when(st === sWait) {
    when(spiDone) { lastRx := spiRx }
    // ⚠️ 接受规则按命令走（见 r1Mask/r1Val 注释）：**不能**只判 bit7==0，否则浮空的 0x00 会被当 R1。
    when(spiDone && (spiRx & r1Mask) === r1Val) {
      r1 := spiRx
      st := Mux(rspLen === 0.U, sAct, sRead)
      rspIdx := 0.U
      rspAcc := 0.U
    }.elsewhen(tout === toMax.U) { errCode := timeoutCode; ph := pFail }
    .otherwise { tout := tout + 1.U }
  }

  // ---- 通用推进：读 R3/R7 的 4 字节（先收到的是最高字节）----
  when(st === sRead) {
    when(spiDone) {
      rspAcc := Cat(rspAcc(23, 0), spiRx)
      when(rspIdx === rspLen - 1.U) { st := sAct }
      .otherwise { rspIdx := rspIdx + 1.U }
    }.elsewhen(tout === toMax.U) { errCode := timeoutCode; ph := pFail }
    .otherwise { tout := tout + 1.U }
  }

  // ===================== 相位机 =====================
  switch(ph) {
    is(pIdle) { st := sAct }

    // 74+ 拍暖机（CS 高、MOSI 高），然后 CMD0
    is(pWarm) {
      when(st === sAct) { startCmd(pCmd0, 0, 0.U, 0x95, 0) }
    }

    // ★ 命令间 gap（= tf_test 的 ST_GAP）：刚发完**一个 0xFF 字节**（CS 高、SCK 照走），
    //   现在把真正的 6 字节命令铺出去（CS 低），落到 `startCmd` 暂存的目标相位。
    is(pGap) {
      when(st === sAct) {
        ph := nxPh
        st := sSend
        isFill := false.B
        cmdLen := 6.U
        bc := 0.U
        waitR1 := true.B
        tout := 0.U
      }
    }

    // CMD0（GO_IDLE_STATE，CRC7=0x95）→ CMD8
    is(pCmd0) {
      when(st === sAct) { startCmd(pCmd8, 8, 0x1AA.U, 0x87, 4) }
    }

    // CMD8（SEND_IF_COND，arg=0x1AA，CRC7=0x87）→ R7 必须回显 0x1AA
    is(pCmd8) {
      when(st === sAct) {
        when(rspAcc(11, 0) === 0x1AA.U) { startCmd(pCmd55, 55, 0.U, 0xFF, 0) }
        .otherwise { errCode := 2.U; ph := pFail }
      }
    }

    // CMD55（APP_CMD）→ ACMD41
    is(pCmd55) {
      when(st === sAct) { startCmd(pAcmd41, 41, 0x40000000.U, 0xFF, 0) }
    }

    // ACMD41（SD_SEND_OP_COND，HCS=1）：R1=0 表示卡出 idle（可用了）；R1=1 继续轮询
    is(pAcmd41) {
      when(st === sAct) {
        when(r1 === 0.U) { startCmd(pCmd58, 58, 0.U, 0xFF, 4) }
        .elsewhen(retry === 499.U) { errCode := 3.U; ph := pFail }
        .otherwise { retry := retry + 1.U; startCmd(pCmd55, 55, 0.U, 0xFF, 0) }
      }
    }

    // CMD58（READ_OCR）→ R3：取 OCR.CCS 判定寻址方式，随后立刻读第一块
    is(pCmd58) {
      when(st === sAct) {
        when(r1 === 0.U) {
          // ⚠️ `sdhcR` 是寄存器，本拍赋值下一拍才可见；首块 CMD17 的地址折算必须用
          //    刚采到的 `ccs` 本体。用旧值会退回 SDSC 口径（lba<<9）——头块在 LBA 0 时
          //    碰巧同址而潜伏，头块在非零 LBA（CoreMark 计划 @32768）就指错块。
          val ccs = rspAcc(30)
          sdhcR := ccs
          initedR := true.B
          // 卡已出 idle ⇒ 从这里起可以提速（初始化阶段必须 ≤400kHz，数据阶段才允许 12.5MHz）；
          // 首次读块与初始化在同一次事务里，所以提速点必须在这里，不能只放在 pIdle。
          eDiv := divFast.U
          // ★ 首条读命令也要按 nblk 选 CMD17/CMD18（初始化与首块在同一次事务里）
          when(nblkR > 1.U) { startCmd(pCmd18, 18, Mux(ccs, lbaR, lbaR << 9), 0xFF, 0) }
          .otherwise        { startCmd(pCmd17, 17, Mux(ccs, lbaR, lbaR << 9), 0xFF, 0) }
        }.otherwise { errCode := 4.U; ph := pFail }
      }
    }

    is(pReady) { st := sAct }

    // CMD17（READ_SINGLE_BLOCK）→ 等数据令牌
    is(pCmd17) {
      when(st === sAct) {
        when(r1 === 0.U) { ph := pTok; st := sTok; tout := 0.U }
        .otherwise { errCode := 5.U; ph := pFail }
      }
    }

    // 等数据令牌 0xFE
    is(pTok) {
      when(st === sTok) {
        when(spiDone && spiRx === 0xFE.U) {
          ph := pData
          st := sAct
          dataWord := 0.U
          byteInWord := 0.U
          wordIdx := 0.U
          wordV := false.B
          wordLast := false.B
        }.elsewhen(tout === toMax.U) { errCode := 6.U; ph := pFail }
        .otherwise { tout := tout + 1.U }
      }
    }

    // 512B 数据：4 字节拼一个 32bit 字（MSB 先），每字等一次 dValid/dReady
    is(pData) {
      when(spiDone) {
        dataWord := Cat(dataWord(23, 0), spiRx)
        when(byteInWord === 3.U) {
          byteInWord := 0.U
          wordV := true.B
          wordLast := wordIdx === 127.U
          wordIdx := wordIdx + 1.U
        }.otherwise { byteInWord := byteInWord + 1.U }
      }
      when(wordV && io.dReady) {
        wordV := false.B
        when(wordLast) { startFill(pCrc, 2) }
      }
    }

    // 数据后的 2 字节 CRC（只吃掉，不校验）→ 收工
    is(pCrc) {
      when(st === sAct) { doneR := true.B; ph := pDone }
    }

    is(pDone) {
      doneR := false.B
      busyR := false.B
      st := sAct
      ph := pReady
    }

    // ===================== ★ CMD18 多块读（nblk > 1）=====================
    // 一条 CMD18 → 连续 nblk 块（每块：0xFE 令牌 + 512B + 2B CRC16）→ CMD12 收尾。
    // 与单块路径（pCmd17/pTok/pData/pCrc）**并存**：nblk==1 时那份代码路径逐位不变，
    // 这样"多块"是纯增量，出问题能立刻退回单块。
    is(pCmd18) {
      when(st === sAct) {
        when(r1 === 0.U) {
          blkLeftR := nblkR - 1.U
          ph := pTokM; st := sTok; tout := 0.U
        }.otherwise { errCode := 5.U; ph := pFail }
      }
    }

    // 等下一块的令牌（段内第 2..N 块从这里进）
    is(pTokM) {
      when(st === sTok) {
        when(spiDone && spiRx === 0xFE.U) {
          ph := pDataM; st := sAct
          dataWord := 0.U; byteInWord := 0.U; wordIdx := 0.U; wordV := false.B; wordLast := false.B
        }.elsewhen(tout === toMax.U) { errCode := 6.U; ph := pFail }
        .otherwise { tout := tout + 1.U }
      }
    }

    // 512B：与 pData 同构，只是块尾去 pCrcM（每块 2 字节 CRC 后继续/收尾）
    is(pDataM) {
      when(spiDone) {
        dataWord := Cat(dataWord(23, 0), spiRx)
        when(byteInWord === 3.U) {
          byteInWord := 0.U
          wordV := true.B
          wordLast := wordIdx === 127.U
          wordIdx := wordIdx + 1.U
        }.otherwise { byteInWord := byteInWord + 1.U }
      }
      when(wordV && io.dReady) {
        wordV := false.B
        when(wordLast) { startFill(pCrcM, 2) }
      }
    }

    // 每块之后吃掉 2 字节 CRC；还有块 ⇒ 直接等下一个令牌；否则 CMD12 收尾
    is(pCrcM) {
      when(st === sAct) {
        when(blkLeftR === 0.U) { startCmd(pStopR1, 12, 0.U, 0xFF, 0) }
        .otherwise { blkLeftR := blkLeftR - 1.U; ph := pTokM; st := sTok; tout := 0.U }
      }
    }

    // CMD12（STOP_TRANSMISSION）的 R1 = 0x00 才算干净收尾
    is(pStopR1) {
      when(st === sAct) {
        when(r1 === 0.U) { doneR := true.B; ph := pDone }
        .otherwise { errCode := 7.U; ph := pFail }
      }
    }

    is(pFail) {
      when(!initedR && initRetry =/= MAX_INIT_RETRY.U) {
        // ★ tf_test 口径：初始化失败不是终点——整条链**重来**（重新暖机 ⇒ CMD0 ⇒ …）。
        //   必须把分频退回慢档（可能刚从 pCmd58 提到 divFast）并清掉错误码，
        //   否则"重试"会在 5MHz 的暖机上跑、且上位会读到上一次的 err。
        initRetry := initRetry + 1.U
        errCode := 0.U
        busyR   := true.B
        eDiv    := divSlow.U
        startFill(pWarm, 10)
      }.otherwise {
        busyR := false.B
        st := sAct
        ph := pIdle
      }
    }
  }

  // ---- 发起一次事务（pIdle / pReady 都可）----
  when((ph === pIdle || ph === pReady) && io.start) {
    errCode := 0.U
    doneR := false.B
    busyR := true.B
    retry := 0.U
    initRetry := 0.U
    misoHi := false.B
    lbaR := io.lba
    nblkR := Mux(io.nblk === 0.U, 1.U, io.nblk)   // 0 当成 1（调用方不该传 0）
    when(initedR) {
      eDiv := divFast.U
      when(io.nblk > 1.U) { startCmd(pCmd18, 18, Mux(sdhcR, io.lba, io.lba << 9), 0xFF, 0) }
      .otherwise          { startCmd(pCmd17, 17, Mux(sdhcR, io.lba, io.lba << 9), 0xFF, 0) }
    }.otherwise {
      eDiv := divSlow.U
      startFill(pWarm, 10)
    }
  }

  // ===================== 输出 =====================
  // CS（低有效）：空闲/暖机/命令间 gap/失败时拉高，其余全程拉低。
  // （ACMD41 的 CMD55+CMD41 现在各自独立成帧；tf_test 也是每条命令独立成帧。）
  io.csN := ph === pIdle || ph === pReady || ph === pWarm || ph === pFail || ph === pGap
  io.busy := busyR
  io.done := doneR
  // ★★ 2026-10-06 上板定案的修复：`io.err` 必须**只在"终态"对外可见**。
  //   引入 `initRetry` 之后，`pFail` 的"重试那一支"会在**一拍的窗口内**让 `errCode` 非零
  //   （sWait 里置位 → 下一拍 `pFail` 清零），而 `SdLoader` 的 `lHdrRd`/`lCopyRd` 是
  //   **连续采样** `sd.io.err` 的 ⇒ 这 1 拍毛刺会被当成致命错误 ⇒ `lFail` ⇒ `active=0`
  //   ⇒ **SdSpi 当场冻在 pData、载荷永远读不完**。
  //   板上实测签名（完全吻合）：`ph=pData`、`errCode=0`、`dbg2` 显示一个 AXI 突发都没发、
  //   而新加的 `sdSt` 诊断直读出 `load_mode=1 / sd_state=4(lFail) / sd_err=1`。
  //   ⇒ 用 `busyR` 门控：事务进行中（含全部重试）对外恒 0；只有重试用尽、`busyR` 落下后才交出 err。
  io.err := Mux(busyR, 0.U, errCode)
  when(eSck && !eSckD) { sckCnt := sckCnt + 1.U }
  // 诊断 32 位：{misoHi, SCK 上升沿数[11:0], 最后收到的字节[7:0], errCode[3:0], 相位 ph[3:0], 字节态 st[2:0]}
  io.dbg := Cat(misoHi, sckCnt, lastRx, errCode, ph, st)
  io.inited := initedR
  io.sdhc := sdhcR
  io.dValid := wordV
  io.dData := dataWord
  io.dLast := wordLast
}
