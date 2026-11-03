import chisel3._
import chisel3.util._

// ===================== TF 卡装载器（板级第二步：卡上的镜像 → DDR）=====================
// 与 `UartLoader` 同一个理由把职责放在硬件里（见 `UartLoader.scala` 文件头：本核 Dcache 写回式且
// 没有软件可见的冲刷手段，CPU 复位就从 DDR 取指 ⇒ 装载必须由硬件直达 DDR）。
// 本模块把 `SdSpi`（只读通路）和"搬运到 DDR"接起来：**上电读卡，不依赖主机**。
//
// 卡上的布局（**块 0 = 装载表**，大端；因为 `SdSpi` 一个字里第 0 个字节在最高字节）：
//   off 0  : 'Y','S','L','D'            （魔数）
//   off 4  : u32 entry 数（1..8）
//   off 8+12*i : u32 目标 DDR 字节地址（**必须 32B 对齐**）、u32 起始块号、u32 块数
//   off 128+4*i: u32 第 i 段的 **CRC32**（zlib 口径；覆盖该段补齐后的 `块数*512` 字节）
//   off 160    : u32 块 0 前 160 字节的 **CRC32**（保护表项本身）
//   块 0 之后的块由 `sim/mk_sd_image.py` 排布（它按 `--entry 目标地址=文件` 的顺序往后排）。
// 例：fw → 0x1C00_0000、内核 → 0x1040_0000，与 UART 装载器的目标地址一致。
//
// ★ 2026-10-25：两级 CRC32（**流式**，不多读一个字节）——
//   · **段 CRC**：抓"卡→装载器"短排线（J25）上的误码与多块错位。卡自己的每块 CRC16 本模块不校验
//     （`SdSpi` 只把 2 字节吃掉），所以整段校验是**唯一**能把"装进去但内容坏"变成"响亮失败"的东西。
//   · **块 0 头 CRC**：段 CRC 抓不到**表项被翻一位**（数据本身没错，只是被写到错的目标地址）——
//     那种情况会"CRC 全对却起不来"，所以表项必须自己带校验。
//   · 口径 = zlib/`crc32`：反射多项式 0xEDB88320，初值/终值都取反，按**卡上的字节顺序**（每字节 LSB 先）。
//
// ⚠️ 三条承重约束（都不是风格）：
//  1. **AXI 写只发 4 拍(32B) 突发**（`awlen=3`）：与 `DDR3Bridge` 的"每笔 AW = 1 个 32B DDR beat"
//     一对一（桥按 `awlen` 分组：`awlen=3` ⇒ 1 组）。目标地址按 32B 对齐累加，表项没对齐直接报错。
//     ⚠️ 2026-09-30（Task 17）**AXI 主口 32bit → 64bit**：每 32B 组的拍数 8 → **4**、`wstrb` 4 → 8bit。
//     `SdSpi` 仍按 **32bit/字** 交数据（它的字节引擎与 AXI 宽度无关，一行未改）⇒ 本模块在**发射时**
//     把 8 个 32bit 字按 `Cat(wBuf(2n+1), wBuf(2n))` 两两拼成 4 拍 64bit：
//     低半 = 早到的那个字、高半 = 后到的那个字 —— 与 32bit 时代"第 2n 拍写低 4 字节、第 2n+1 拍
//     写高 4 字节"**逐字节同义**（内存里的字节线性顺序一字不变）。
//  2. **一波在飞 / 缓冲已满时不许收新字**（`dReady` 门控）：缓冲只有 8 个 32bit 字（= 32B），不等
//     突发回来就继续收会把这一波的字盖掉。`SdSpi` 侧被 dReady 节流（数据相本来就有 dValid/dReady 握手）。
//  3. **非装载模式（`active = 0`）不驱动 AXI**（全 0，见文件末尾断言）；SPI 引脚停在"CS 高、SCK 低"
//     的空闲态（`SdSpi` 自己保证）⇒ 卡永远不选中。仿真侧 `active` 恒 0 ⇒ 对既有行为零影响。
//
// 失败时**不放 CPU 复位**（`released` 保持 0），错误码留在 `io.errCode`：与其让 CPU 去跑一段没装好
// 的 DDR，不如停在原地（板上可用 LED 看错误码）。
//   errCode：1 = SD 通路报错（编码见 `SdSpi.scala` 文件头）
//            2 = 块 0 的魔数不对（卡里没有装载表）
//            3 = 表项数不在 1..8
//            4 = 表项非法（块数为 0 或目标地址没 32B 对齐）
//            5 = DMA 引擎报错（`CH_STATUS` 的 err/aborted 位，或 CSR 事务响应非 OKAY）★ Phase-2c
//            6 = DMA 引擎超时（轮询 `CH_STATUS` 的 done 位超限）★ Phase-2c
//            7 = 块 0 表头 CRC32 不匹配（表项/CRC 字段本身坏了 ⇒ 不敢按它搬）★ 2026-10-25
//            8 = 某一段的数据 CRC32 不匹配（卡→装载器传输有误码/错块）★ 2026-10-25
class SdLoaderIO extends Bundle {
  val active   = Input(Bool())       // strap：1 = 本装载器接管（CPU 扣复位中）
  // ★ Y1-Boot：装载头 LBA 的运行期选择（0 = Linux 计划在块 0；1 = CoreMark 计划在 coreHdrLba）
  val hdrSel   = Input(Bool())
  val released = Output(Bool())      // 1 = 装载完成（SoC 据此放 CPU 复位、交还 AXI 写通道）
  val state    = Output(UInt(4.W))   // 0=idle 1=读表 2=搬运 3=完成 4=失败（波形观察用）
  val errCode  = Output(UInt(4.W))
  // 诊断（SD 通路调试）：**直通 `SdSpi.io.dbg`**（本模块自己不再编码，避免又一处口径漂移）。
  //   位域见 `SdSpi.scala` 末尾：{misoHi, sckCnt[11:0], lastRx[7:0], errCode[3:0], ph[3:0], st[2:0]}
  //   详细码含义见 SdSpi.scala 文件头：1=CMD0 2=CMD8 3=ACMD41 4=CMD58 5=CMD17 6=token
  val dbg      = Output(UInt(32.W))
  // 诊断 2（AXI 突发通路）：板级"pData 卡死"时用来判是**突发发不出去**还是**回不来**。
  //   位域见文件末尾 `io.dbg2` 赋值处。
  val dbg2     = Output(UInt(32.W))
  // SPI 物理引脚（板级引到 **J25** 3/4/5/6 = V14/U14/T18/T17；权威 = tf_test_200mini 的 TF-J25 段）
  val sdSck  = Output(Bool())
  val sdMosi = Output(Bool())
  val sdCsN  = Output(Bool())
  val sdMiso = Input(Bool())
  // AXI 写主方（只写，与 `UartLoaderIO` 同形 ⇒ SoC 侧是同一段接管逻辑）
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

  // ===================== ★ Y1-DMA Phase-2c：DMA 引擎客户端口 =====================
  // **本装载器成为通用 DMA 引擎的第一个真客户**（spec §4.4 的顺序①、plan T2.2 的 D3）。
  // `dmaMode = 1` ⇒ 装载器**不再自己举 AXI 写突发**，改为：
  //   ① 用下面这个小 AXI4-Lite **主口**编程引擎通道 0 的 CSR（DST/LEN/MODE=2(WR)/start）并轮询 `CH_STATUS`；
  //   ② 把原本要发成 32B 写突发的 4 拍 64bit 字节流，改从 `dmaWr_valid/dmaWr_data` **推给引擎**
  //      （引擎侧 `wr_stream` ⇒ `DdrMaster` 的 `WSTR` 态 ⇒ 由引擎过 §3.5 落地到 DDR）。
  // ⚠️ **地址口径（同一份镜像逐字节相同的承重前提）**：引擎主口是 **28bit**（`DmaEngineConfig.ADDR_W`），
  //    而 DDR3Bridge 取的是 `awaddr(29,2)`（bit31/30 被丢弃）⇒ 板级 DDR 基址 `0x8000_0000`
  //    在整条 DDR 通路里是**纯别名**。于是"卡上表的 32bit 目标地址"直接写进 `CH_DST`、
  //    由引擎截到 28bit，落到的 DDR 字节与直写通路（32bit 地址原样过桥）**逐字节相同** ——
  //    与 NPU 既有约定一致（`y1/reports/c4b_input_layout.md`：NPU 地址 = 物理 − 0x8000_0000）。
  val dmaMode = Input(Bool())                 // strap：1 = 喂引擎（0 = 既有直写通路，逐字不动）
  // ---- AXI4-Lite CSR 主口（地址 = **DMA 窗内相对偏移**；glue 把它送到引擎基址 0 的从口）----
  val dmaCsrAwAddr  = Output(UInt(8.W))
  val dmaCsrAwValid = Output(Bool())
  val dmaCsrAwReady = Input(Bool())
  val dmaCsrWData   = Output(UInt(32.W))
  val dmaCsrWValid  = Output(Bool())
  val dmaCsrWReady  = Input(Bool())
  val dmaCsrBValid  = Input(Bool())
  val dmaCsrBReady  = Output(Bool())
  val dmaCsrBResp   = Input(UInt(2.W))
  val dmaCsrArAddr  = Output(UInt(8.W))
  val dmaCsrArValid = Output(Bool())
  val dmaCsrArReady = Input(Bool())
  val dmaCsrRValid  = Input(Bool())
  val dmaCsrRReady  = Output(Bool())
  val dmaCsrRData   = Input(UInt(32.W))
  val dmaCsrRResp   = Input(UInt(2.W))
  // ---- 流口：32B 组拆 4 拍 64bit 喂引擎通道 0 的 `wr_valid/wr_data/wr_ready` ----
  // 引擎只在 `WSTR` 态举 `wr_ready`（每块 128B = 16 拍），其余时刻结构性不接收 ⇒ 天然背压。
  val dmaWrValid = Output(Bool())
  val dmaWrData  = Output(UInt(64.W))
  val dmaWrReady = Input(Bool())
}

class SdLoader(hdrLba: Int = 0, coreHdrLba: Int = 32768) extends Module {
  val io = IO(new SdLoaderIO)

  // ===================== 写缓冲：8 个 32bit 字（= 1 波 32B 突发，发射时拼成 4 拍 64bit）=====
  private val wBuf      = RegInit(VecInit.fill(8)(0.U(32.W)))
  private val wCnt      = RegInit(0.U(3.W))     // 本波已收**32bit 字**数 0..7（`SdSpi` 的口是 32bit）
  private val wBase     = RegInit(0.U(32.W))    // 本波首址（32B 对齐，逐波 +32）
  private val grp       = RegInit(0.U(5.W))     // 本块已发波数 0..16
  private val groupFull = RegInit(false.B)      // 缓冲已有 8 个 32bit 字（= 32B）、等发波
  private val wIdle :: wAw :: wW :: wB :: Nil = Enum(4)
  private val wState = RegInit(wIdle)
  private val wIdx   = RegInit(0.U(2.W))        // 本波已发的 **64bit 拍**号 0..3
  private val wGo    = WireDefault(false.B)
  private val wBusy  = wState =/= wIdle

  // ---- ★ Phase-2c：`dmaMode` 下的"喂引擎"小 FSM（与上面的 `wState` **平行**，两者按 `dmaMode` 互斥）----
  // 语义与 AXI 侧的 `wAw/wW/wB` 逐拍同源：把缓冲里的同一份 4 拍 64bit 字节流推给引擎，
  // 只是"目的地"从 AXI 写通道换成引擎的 `wr_stream`（背压由 `wr_ready` 表达）。
  private val dbAct = RegInit(false.B)          // 1 = 正在推本组（4 拍）
  private val dbIdx = RegInit(0.U(2.W))         // 本组已推的 64bit 拍号 0..3
  private val dgrp  = RegInit(0.U(5.W))         // 本块已推给引擎的 32B 组数 0..16

  // ===================== ★ 2026-10-25：段/表头 **流式 CRC32**（不多读一个字节）=====================
  // 口径 = zlib/`crc32`：反射多项式 0xEDB88320、初值/终值都取反、**按卡上的字节顺序**（每字节 LSB 先）。
  // 吞吐：**1 拍 1 bit**（一个字 32 拍）。数据相 SCK=25MHz（divFast=1）时一个字要 128 拍才来一个
  //   ⇒ 4 倍余量；即使 divFast=0（50MHz）也还有 2 倍。`dReady` 额外按 `!crcBusy` 门控 ⇒
  //   结构上不可能在算旧字时丢新字（不是靠时序凑）。
  // 两级各有分工（缺一不可）：
  //   · **表头 CRC**（块 0 的字节 0..159）：抓**表项被翻一位**。段 CRC 抓不到这种错 ——
  //     数据本身没错、只是被写到错的目标地址，会"CRC 全对却起不来"。
  //   · **段 CRC**（每表项一个，覆盖补齐后的 `块数*512` 字节）：抓短排线上的误码与多块错位。
  //     `SdSpi` 不校验卡自己每块的 CRC16（只吃掉 2 字节），所以这是整段唯一的完整性判据。
  private val CRCPOLY = 0xEDB88320L.U(32.W)
  private val crcR    = RegInit(0xFFFFFFFFL.U(32.W))
  private val crcWord = RegInit(0.U(32.W))         // 正在算的那个字（`SdSpi` 首字节在最高字节）
  private val crcBits = RegInit(32.U(6.W))         // 本字已算 bit 数；32 = 空闲
  private val crcBusy = crcBits =/= 32.U
  // 第 i 个 bit 在字里的位置：文件里第 k 个字节的 bit0 落在 `31-8k` ⇒ `31-8*(i>>3)-(7-(i&7))`
  //   = `24 - i + 2*(i&7)`。中间值会为负、UInt 自然回卷，但真值恒在 0..31（32 个 i 已穷举核对）。
  private val crcPos  = 24.U - crcBits + (crcBits(2, 0) << 1)
  private val crcNext = Mux(crcR(0) ^ crcWord(crcPos(4, 0)), (crcR >> 1) ^ CRCPOLY, crcR >> 1)
  private val crcFinal = crcR ^ 0xFFFFFFFFL.U(32.W)

  // ===================== SPI 只读通路 =====================
  private val sd      = Module(new SdSpi(divFast = 3, divSlow = 499))
  // ⚠️ 数据相 SCK = 100MHz/(2*(divFast+1))：
  //   · `divFast=3` ⇒ **12.5MHz**；`divSlow=499` ⇒ 初始化 100kHz（≤400kHz 的硬约束）。
  //   · **25MHz（divFast=1）在这块板上不成立**（2026-10-26 上板实测，同一张卡同一排线）：
  //     初始化全过，但第一条 CMD17 拿不到数据令牌（`SdSpi.err=6`、`lastRx=0x00`）；
  //     0x00 是 MISO 浮空时的默认电平 ⇒ 说明命令在 25MHz 下没被卡认可、而 R1 判据把浮空 0x00
  //     当成了"就绪"。同一张卡换 5MHz 的旧比特流（divFast=9）**完整启动 8/8** ⇒ 变量只有 SCK 速率。
  //   · 12.5MHz 的采样余量 = 40ns（卡 tODLY ≤14ns、排线再吃几 ns），是 25MHz 的两倍；
  //     20,910 块数据约 **7.2s**（5MHz 17.4s、25MHz 3.4s）。要再快先量眼图/换线，别直接跳 25MHz。
  private val sdStart = RegInit(false.B)
  private val sdlLba  = RegInit(0.U(32.W))
  sd.io.start  := sdStart
  sd.io.lba    := sdlLba
  // 约束 2：缓冲满、一波在飞、或 CRC 引擎还没算完上一个字 ⇒ 不收新字
  //   （DMA 模式另有"本组正在推给引擎"这一条件）。`!crcBusy` 是**结构保证**：CRC 引擎单字要 32 拍，
  //   数据相 25MHz 下两个字间隔 128 拍 —— 正常永不触发；它只用来把"万一触发"变成等待而不是丢字。
  sd.io.dReady := io.active && !groupFull && !wBusy && !dbAct && !crcBusy
  io.sdSck  := sd.io.sck
  io.sdMosi := sd.io.mosi
  io.sdCsN  := sd.io.csN
  sd.io.miso := io.sdMiso

  // "块 0 = 'YSLD' 魔数"（`SdSpi` 一个字里第 0 个字节在最高字节 ⇒ 按 MSB 先拼就是大端）
  private def ascii4(a: Int, b: Int, c: Int, d: Int): UInt =
    Cat(a.U(8.W), b.U(8.W), c.U(8.W), d.U(8.W))
  private val MAGIC = ascii4('Y', 'S', 'L', 'D')

  private val lIdle :: lHdrReq :: lHdrRd :: lParse :: lCopyReq :: lCopyRd :: lWr :: lDPoll :: lDone :: lFail :: Nil = Enum(10)
  private val st = RegInit(lIdle)

  private val hdrBuf  = Reg(Vec(32, UInt(32.W)))   // 块 0 的前 128 字节（表项最多用到 26 字）
  private val entCrc  = Reg(Vec(8, UInt(32.W)))    // 块 0 的字节 128+4i：第 i 段的 CRC32（卡上带来的）
  private val hdrCrcStored = RegInit(0.U(32.W))    // 块 0 的字节 160..163：表头 CRC32（卡上带来的）
  private val hdrCrcR      = RegInit(0.U(32.W))    // 表头 CRC32（本模块自己对字节 0..159 算的）
  private val hIdx    = RegInit(0.U(8.W))
  private val hdrMode = RegInit(false.B)

  // 16 项（不是 8）：索引用的是 4 位的 `eCur`，表长与索引位宽对齐才不会踩 Chisel 的
  // "Dynamic index is too wide" 警告；表项数本身由块 0 的检查卡在 1..8。
  private val entDst = RegInit(VecInit.fill(16)(0.U(32.W)))
  private val entLba = RegInit(VecInit.fill(16)(0.U(32.W)))
  private val entN   = RegInit(VecInit.fill(16)(0.U(16.W)))
  private val nEnt   = RegInit(0.U(4.W))
  private val eCur   = RegInit(0.U(4.W))
  // ★ CMD18：一次事务读**整段**（表头阶段仍按 1 块走 CMD17）
  //   注：必须放在 `entN`/`eCur`/`hdrMode` 声明**之后** —— 否则踩 Chisel 的前向引用
  //   （实测报 `SdLoader.entN() is null` / `node is null`）。
  sd.io.nblk := Mux(hdrMode, 1.U, entN(eCur))

  private val errR = RegInit(0.U(4.W))
  private val relR = RegInit(false.B)

  io.awaddr  := Mux(io.active, wBase, 0.U)
  io.awlen   := 3.U                          // ⚠️ 固定 4 拍（约束 1；64bit ⇒ 4×8B = 32B）
  // ★ Phase-2c：`dmaMode=1` ⇒ **不驱动 AXI 写通道**（字节流改走 `dmaWr_*` 喂引擎）。
  io.awvalid := io.active && !io.dmaMode && (wState === wAw)
  // 64bit 一拍 = 缓冲里的**两个字**（低半 = 早到的，高半 = 后到的）⇒ 与 32bit 时代的字节序逐字节同义
  io.wdata   := Cat(wBuf((wIdx << 1) + 1.U), wBuf(wIdx << 1))
  io.wstrb   := 255.U                        // 块数据总是整 8 字节有效（512B 按 32B 对齐搬运）
  io.wlast   := wIdx === 3.U
  io.wvalid  := io.active && !io.dmaMode && (wState === wW)
  io.bready  := io.active && !io.dmaMode && (wState === wB)

  // ---- ★ Phase-2c：DMA 模式的喂流（与上面 AXI 侧**同一个字节源**：`wBuf` 的 4 拍 64bit）----
  io.dmaWrValid := io.active && io.dmaMode && dbAct
  io.dmaWrData  := Cat(wBuf((dbIdx << 1) + 1.U), wBuf(dbIdx << 1))   // 与 `io.wdata` 同构
  when(dbAct && io.dmaWrReady) {
    // ★ CMD18：块内 16 组（16×32B = 512B）后回卷 —— 一次事务跨多块，没有"每块重建"的机会
    when(dbIdx === 3.U) { dbAct := false.B; dgrp := Mux(dgrp === 15.U, 0.U, dgrp + 1.U) }
    .otherwise          { dbIdx := dbIdx + 1.U }
  }

  switch(wState) {
    is(wIdle) { when(wGo) { wState := wAw; wIdx := 0.U } }
    is(wAw)   { when(io.awready) { wState := wW } }
    is(wW)    {
      when(io.wready) {
        when(wIdx === 3.U) { wState := wB }.otherwise { wIdx := wIdx + 1.U }
      }
    }
    is(wB)    {
      when(io.bvalid) {
        wState := wIdle
        wBase  := wBase + 32.U
        grp    := Mux(grp === 15.U, 0.U, grp + 1.U)   // ★ 同上：块边界靠回卷，而不是回 lCopyReq
      }
    }
  }

  // ===================== 收字（两条路径：读表 / 搬运）=====================
  when(sd.io.dValid && sd.io.dReady) {
    when(hdrMode) {
      // 表只在前 128 字节里 ⇒ 只存前 32 字（`hIdx(6,5)===0` 即 hIdx<32），其余照收不存
      when(hIdx(6, 5) === 0.U) { hdrBuf(hIdx(4, 0)) := sd.io.dData }
      // 块 0 的字节 128+4i = 第 i 段的 CRC32（8 个），字节 160..163 = 表头 CRC
      when(hIdx >= 32.U && hIdx < 40.U) { entCrc(hIdx(2, 0)) := sd.io.dData }
      when(hIdx === 40.U)              { hdrCrcStored := sd.io.dData }
      hIdx := hIdx + 1.U
    }.otherwise {
      // ⚠️⚠️ 必须**字节反转**：`SdSpi` 交的 32bit 字是"第 0 个字节在最高字节"（见 SdSpi 文件头），
      //   而 AXI/内存的字节序是**小端**（`UartLoader` 装字就是 `rxb << (byte*8)`：byte k → bits[8k+7:8k]，
      //   那条路板上已验证能 boot）。这两个约定一颠倒，每 4 字节组在内存里就**反序**⇒镜像整体错乱。
      //   2026-10-05 由新建的单元装置（sim/sdloader/）首次抓出：修前 DDR[0..3] = 文件字节 [3,2,1,0]。
      //   注：`hdrBuf` **不能**反（表的解析按大端拼字，MAGIC='YSLD' 正靠这个大端约定）。
      wBuf(wCnt) := Cat(sd.io.dData(7, 0), sd.io.dData(15, 8), sd.io.dData(23, 16), sd.io.dData(31, 24))
      when(wCnt === 7.U) { groupFull := true.B; wCnt := 0.U }
      .otherwise { wCnt := wCnt + 1.U }
    }
  }

  // ---- CRC 引擎：每收到一个字（表/数据都算）落后 32 拍把它算完；表头 CRC 在字节 160 处快照 ----
  // ⚠️ 顺序：先算旧字、再锁新字 ⇒ 同一拍两者都发生也不会把新字当成旧字的一部分
  //    （正常不会同拍：`dReady` 被 `!crcBusy` 门控）。
  when(crcBusy) { crcR := crcNext; crcBits := crcBits + 1.U }
  when(sd.io.dValid && sd.io.dReady) { crcWord := sd.io.dData; crcBits := 0.U }
  // 表头 CRC 的取值点：第 40 个字（块 0 的字节 160..163）到货那一拍，`crcR` 恰好是前 160 字节的结果
  // （此时 `crcBits` 仍是旧值 32 = 空闲 ⇒ 不含这个字本身）。
  when(hdrMode && hIdx === 40.U && !crcBusy) { hdrCrcR := crcFinal }

  // 缓冲满 + 突发空闲 ⇒ 发这一波。
  // ⚠️ 条件**不能**带 `st === lWr`：收字发生在 `lCopyRd`（读块），而 `lWr` 要等读块结束才进；
  //    若发波要等 `lWr`，读侧就会因为 dReady 被 groupFull 拉低而卡住 ⇒ 死锁（实测：state 停在 2、
  //    零 AW、40M 拍无进展）。所以发波与读块**并行**，`lWr` 只负责等本块 16 波发完。
  // ★ Phase-2c：两条通路按 `dmaMode` **互斥**（`groupFull` 被清的地方各只有一处能命中）。
  when(!io.dmaMode && !hdrMode && groupFull && wState === wIdle) {   // 通路 A：直写 AXI（逐字未改）
    wGo := true.B
    groupFull := false.B
  }
  when(io.dmaMode && io.active && !dbAct && !hdrMode && groupFull) {  // 通路 B：喂引擎 `wr_stream`
    dbAct := true.B
    dbIdx := 0.U
    groupFull := false.B
  }

  // ===================== 表项合法性（先判后搬，避免搬一半才发现表坏了）=====================
  private val nE     = hdrBuf(1)(3, 0)
  private val badEnt = (0 until 8).map { i =>
    (i.U < nE) && ((hdrBuf(4 + 3 * i) === 0.U) || (hdrBuf(2 + 3 * i)(4, 0) =/= 0.U))
  }.reduce(_ || _)

  // ===================== ★ Phase-2c：DMA 模式的「编程 + 等完成」顺序器 =====================
  // 每**表项**一次（进 `lCopyReq` 时主 FSM 抬 `dGo`）：写 CH_DST/CH_LEN/CH_MODE=2(WR)/CH_CTRL.start，
  // 然后轮询 CH_STATUS 直到 done / err。写序列与轮询共用一套 AXI4-Lite 事务握手。
  // ⚠️ 两条硬纪律：
  //   ① **AW/AR 收下即撤**（`dAw`/`dAr`）：否则同一笔地址会被从方当成**两笔**接受（AXI 的 valid
  //      只需一拍就可成交，持续举着 = 又发了一笔）；
  //   ② 顺序器与"喂流"**并行**：开始推拍时 CSR 可能还在写 —— 但引擎的 `wr_ready` 只在 `launch`
  //      之后（`DdrMaster` 的 `WSTR` 态）才举 ⇒ 结构性地不会吞掉"启动前"的拍。
  private val dIdle :: dWr :: dWait :: dPoll :: Nil = Enum(4)
  private val dSt    = RegInit(dIdle)
  private val dPh    = RegInit(0.U(1.W))       // 0 = AW/W（或 AR）相位，1 = B（或 R）相位
  private val dWIdx  = RegInit(0.U(2.W))       // 写序列相位 0=DST 1=LEN 2=MODE 3=START
  private val dAw    = RegInit(false.B)        // AW 已成交（收下即撤）
  private val dWc    = RegInit(false.B)        // W  已成交
  private val dAr    = RegInit(false.B)        // AR 已成交
  private val dFinR  = RegInit(false.B)        // 粘滞：本项**完成**（引擎 done）
  private val dBadR  = RegInit(false.B)        // 粘滞：本项**失败**（引擎 err/aborted / 响应非 OKAY / 超时）
  private val dBadTo = RegInit(false.B)        // 失败原因：1 = 超时（⇒ errCode 6）
  private val dTo    = RegInit(0.U(20.W))      // 单笔事务超时计数
  private val dPollN = RegInit(0.U(20.W))      // 轮询次数（引擎迟迟不 done ⇒ 超时）
  private val dGo    = WireDefault(false.B)    // 主 FSM 抬一拍 ⇒ 启动本项的"编程 + 轮询"
  private val dPollGo= WireDefault(false.B)    // 主 FSM 在 `lDPoll` 抬 ⇒ 本项数据**已喂完**，可以开始轮询了
  // ⚠️ 为什么需要 `dWait`（这是本相实测踩到的一个真坑）：轮询**不能**与"喂流"同时开始 ——
  //    SPI 读块是**百万拍量级**（卡慢），而引擎的搬运要等最后一批拍喂完才可能 done。若轮询从
  //    "写完 start" 就开始，它的次数预算会被缓慢的 SPI 流**吃干**（实测：第三个表项 `errCode=6`
  //    超时，而数据其实都写对了）。⇒ 顺序器写完 4 个寄存器后停在 `dWait`，等主 FSM 走到
  //    `lDPoll`（= 本表项字节全部推完）才 `dPollGo` ⇒ 轮询预算只需覆盖"引擎收尾"（几百拍量级）。

  private val TMO = 0x80000.U(20.W)            // 单笔事务 = 52 万拍（5.2 ms @100MHz）绰绰有余
  private val PTO = 0x80000.U(20.W)            // 轮询上限 = 52 万次（远超"最后一拍之后"的收尾）

  private val dWAddr = MuxCase(0x0C.U(8.W), Seq(
    (dWIdx === 0.U) -> 0x0C.U(8.W),            // CH_DST
    (dWIdx === 1.U) -> 0x10.U(8.W),            // CH_LEN
    (dWIdx === 2.U) -> 0x14.U(8.W),            // CH_MODE
    (dWIdx === 3.U) -> 0x00.U(8.W)))           // CH_CTRL
  private val dWData = MuxCase(0.U(32.W), Seq(
    (dWIdx === 0.U) -> entDst(eCur),           // 目标地址（引擎截 28bit；见 IO 注释的别名论证）
    (dWIdx === 1.U) -> (entN(eCur) << 9),      // 字节数 = 块数 × 512（32B 的整数倍、非 0）
    (dWIdx === 2.U) -> 2.U(32.W),              // CH_MODE = 2（WR：只写，从 wr_stream 灌）
    (dWIdx === 3.U) -> 1.U(32.W)))             // CH_CTRL bit0 = start

  private val dOwn = io.active && io.dmaMode
  io.dmaCsrAwAddr  := dWAddr
  io.dmaCsrAwValid := dOwn && (dSt === dWr)   && (dPh === 0.U) && !dAw
  io.dmaCsrWData   := dWData
  io.dmaCsrWValid  := dOwn && (dSt === dWr)   && (dPh === 0.U) && !dWc
  io.dmaCsrBReady  := dOwn && (dSt === dWr)   && (dPh === 1.U)
  io.dmaCsrArAddr  := 0x04.U                   // CH_STATUS
  io.dmaCsrArValid := dOwn && (dSt === dPoll) && (dPh === 0.U) && !dAr
  io.dmaCsrRReady  := dOwn && (dSt === dPoll) && (dPh === 1.U)

  when(dSt === dWr || dSt === dPoll) { dTo := dTo + 1.U }  // 事务超时计数；dWait 不计（等主 FSM，久是正常的）
  when(dGo) {
    dSt := dWr; dPh := 0.U; dWIdx := 0.U
    dAw := false.B; dWc := false.B; dAr := false.B
    dFinR := false.B; dBadR := false.B; dBadTo := false.B
    dTo := 0.U; dPollN := 0.U
  }.otherwise {
    switch(dSt) {
      is(dWr) {
        when(dPh === 0.U) {
          val awHit = dAw || io.dmaCsrAwReady
          val wHit  = dWc || io.dmaCsrWReady
          when(io.dmaCsrAwReady && !dAw) { dAw := true.B }
          when(io.dmaCsrWReady  && !dWc) { dWc := true.B }
          when(awHit && wHit) { dPh := 1.U; dTo := 0.U }
          .elsewhen(dTo === TMO) { dBadR := true.B; dBadTo := true.B; dSt := dIdle }
        }.otherwise {
          when(io.dmaCsrBValid) {
            when(io.dmaCsrBResp =/= 0.U) { dBadR := true.B; dSt := dIdle }        // CSR 响应非 OKAY
            .elsewhen(dWIdx === 3.U) {
              dWIdx := 0.U; dPh := 0.U; dAr := false.B; dSt := dWait; dTo := 0.U  // 写完 start ⇒ **等**喂完再轮询
            }.otherwise {
              dWIdx := dWIdx + 1.U; dPh := 0.U
              dAw := false.B; dWc := false.B; dTo := 0.U                         // 下一笔写
            }
          }.elsewhen(dTo === TMO) { dBadR := true.B; dBadTo := true.B; dSt := dIdle }
        }
      }
      is(dWait) {
        // 等主 FSM 说"本表项的字节都喂完了"（`lDPoll`）——再开始轮询；见 `dPollGo` 的注释。
        when(dPollGo) { dSt := dPoll; dPh := 0.U; dAr := false.B; dTo := 0.U; dPollN := 0.U }
      }
      is(dPoll) {
        when(dPh === 0.U) {
          when(io.dmaCsrArReady) { dAr := true.B; dPh := 1.U; dTo := 0.U }
          .elsewhen(dTo === TMO) { dBadR := true.B; dBadTo := true.B; dSt := dIdle }
        }.otherwise {
          when(io.dmaCsrRValid) {
            dPh := 0.U; dAr := false.B; dTo := 0.U
            dPollN := dPollN + 1.U
            when(io.dmaCsrRResp =/= 0.U)                      { dBadR := true.B; dSt := dIdle }
            .elsewhen(io.dmaCsrRData(0))                      { dFinR := true.B; dSt := dIdle }
            .elsewhen(io.dmaCsrRData(1) || io.dmaCsrRData(2)) { dBadR := true.B; dSt := dIdle }
            .elsewhen(dPollN === PTO)                         { dBadR := true.B; dBadTo := true.B; dSt := dIdle }
          }.elsewhen(dTo === TMO) { dBadR := true.B; dBadTo := true.B; dSt := dIdle }
        }
      }
    }
  }

  // ===================== 主状态机 =====================
  sdStart := false.B                       // 默认：脉冲只维持一拍
  switch(st) {
    is(lIdle) {
      when(io.active) {
        // ★ Y1-Boot：0 = Linux 计划（块 0，兼容既有卡）；1 = CoreMark 计划（固定 LBA）
        sdlLba  := Mux(io.hdrSel, coreHdrLba.U(32.W), hdrLba.U(32.W))
        hdrMode := true.B
        hIdx    := 0.U
        errR    := 0.U
        relR    := false.B
        crcR    := 0xFFFFFFFFL.U(32.W)      // 表头 CRC 从初值起算
        crcBits := 32.U                     // 丢掉上一次残留的在算字
        sdStart := true.B
        st      := lHdrRd
      }
    }

    is(lHdrRd) {
      when(sd.io.err =/= 0.U) { errR := 1.U; st := lFail }
      // ⚠️ 要等**最后一个字的 CRC 算完**再解析（`crcBusy` 在 `done` 之后还会延续 ~32 拍）；
      //    本状态会一直停在这里直到引擎空闲，不会漏。
      .elsewhen(sd.io.done && !crcBusy) { hdrMode := false.B; st := lParse }
    }

    is(lParse) {
      st := lFail
      when(hdrBuf(0) =/= MAGIC) { errR := 2.U }
      .elsewhen(hdrBuf(1) < 1.U || hdrBuf(1) > 8.U) { errR := 3.U }
      // 表头自校验：段 CRC 抓不到"目标地址/块号被翻一位"（数据本身没错、只是搬去错的地方）
      .elsewhen(hdrCrcR =/= hdrCrcStored) { errR := 7.U }
      .elsewhen(badEnt) { errR := 4.U }
      .otherwise {
        nEnt := nE
        for (i <- 0 until 8) {
          entDst(i) := hdrBuf(2 + 3 * i)
          entLba(i) := hdrBuf(3 + 3 * i)
          entN(i)   := hdrBuf(4 + 3 * i)(15, 0)
        }
        for (i <- 8 until 16) { entDst(i) := 0.U; entLba(i) := 0.U; entN(i) := 0.U }
        eCur := 0.U
        st   := lCopyReq
      }
    }

    is(lCopyReq) {
      sdlLba  := entLba(eCur)
      // 本块 16 波 32B 的参数在这里复位：发波与读块**并行**（见上面发波条件的注释），
      // 所以计数必须在读块**开始前**清零，不能等读完再清（那时已经发出去几波了）。
      wBase := entDst(eCur)
      grp   := 0.U
      dgrp  := 0.U
      wCnt  := 0.U
      // 每段起点复位 CRC（跨块累加；`crcBits := 32` 同时中止表头末字的残算）
      crcR := 0xFFFFFFFFL.U(32.W); crcBits := 32.U
      // ★ Phase-2c：DMA 模式下**每表项一次**编程引擎 CSR（整项的 DST/LEN 一次写全，之后只喂流）
      when(io.dmaMode) { dGo := true.B }
      sdStart := true.B
      st      := lCopyRd
    }

    is(lCopyRd) {
      when(sd.io.err =/= 0.U) { errR := 1.U; st := lFail }
      .elsewhen(sd.io.done) { st := lWr }
    }

    is(lWr) {
      // ★ CMD18 后这里等的是**整段**的尾巴：最后一批突发已落地（通路 A）/ 最后一次喂流已收下（通路 B），
      //   且 CRC 引擎把最后一个字算完（`done` 只看 SPI 侧，比它早）。
      val drained = Mux(io.dmaMode, !dbAct && !groupFull, wState === wIdle && !groupFull)
      when(drained && !crcBusy) {
        // ★ 段尾：整段 CRC 对不上就**不放 CPU**（`lFail`），绝不把坏镜像当成"装完了"
        when(crcFinal =/= entCrc(eCur)) { errR := 8.U; st := lFail }
        .elsewhen(io.dmaMode) { st := lDPoll }   // ★ 本项数据已喂完 ⇒ 等引擎把这一项写完
        .elsewhen(eCur + 1.U === nEnt) { st := lDone }
        .otherwise { eCur := eCur + 1.U; st := lCopyReq }
      }
    }

    // ★ Phase-2c：DMA 模式的"等引擎完成"（`dFinR`/`dBadR` 是顺序器的粘滞结果标志）
    is(lDPoll) {
      dPollGo := true.B                       // 本表项字节已喂完 ⇒ 允许顺序器开始轮询引擎
      when(dBadR) { errR := Mux(dBadTo, 6.U, 5.U); st := lFail }
      .elsewhen(dFinR) {
        when(eCur + 1.U === nEnt) { st := lDone }
        .otherwise { eCur := eCur + 1.U; st := lCopyReq }
      }
    }

    is(lDone) { relR := true.B }

    is(lFail) { }                          // 停住：不放 CPU，错误码留在 io.errCode
  }

  // ===================== 输出 =====================
  io.released := relR
  io.errCode  := errR
  io.dbg      := sd.io.dbg
  // 诊断 2：一次加载里**有没有发生过** AW/W/B 握手（sticky）——把"突发发不出去"与"发出去但回不来"分开。
  //   ⚠️ 必须放在输出赋值**之后**（读 `io.awvalid` 等已连接的端口；放前面会踩 Chisel 的"未完全初始化"）。
  private val awSeen = RegInit(false.B)
  private val wSeen  = RegInit(false.B)
  private val bSeen  = RegInit(false.B)
  when(io.awvalid && io.awready) { awSeen := true.B }
  when(io.wvalid && io.wready)   { wSeen  := true.B }
  when(io.bvalid)                { bSeen  := true.B }
  // 位域：{wState(2), groupFull, awSeen, wSeen, bSeen, grp(5), wIdx(2), 本段块数(16), 3'h0} = 32bit
  io.dbg2 := Cat(wState, groupFull, awSeen, wSeen, bSeen, grp, wIdx, entN(eCur), 0.U(3.W))
  io.state := MuxLookup(st, 0.U)(Seq(
    lHdrReq -> 1.U, lHdrRd -> 1.U, lParse -> 1.U,
    lCopyReq -> 2.U, lCopyRd -> 2.U, lWr -> 2.U, lDPoll -> 2.U,
    lDone -> 3.U, lFail -> 4.U
  ))

  // 约束 3：非装载模式下不驱动 AXI（SPI 引脚停在空闲态由 SdSpi 自己保证）
  // ⚠️ 这里**不能**把 `!relR` 也写进断言：装载完成后 SoC 会把 `active` 拉低（交还总线），
  //    而 `released` 要一直保持 1（CPU 靠它放复位）⇒ 那样断言会在成功的那一刻自己踩自己。
  when(!io.active) {
    assert(!io.awvalid && !io.wvalid && !io.bready,
      "SdLoader: must not drive the AXI write channels while inactive")
    // ★ Phase-2c：DMA 客户端口（CSR 主口 + 喂流）同受这条纪律约束（`dOwn`/`io.dmaWrValid` 都带 `io.active`）
    assert(!io.dmaCsrAwValid && !io.dmaCsrWValid && !io.dmaCsrArValid && !io.dmaWrValid,
      "SdLoader: must not drive the DMA engine ports while inactive")
  }
}
