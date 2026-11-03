import spinal.core._
import spinal.lib._
import spinal.lib.bus.amba4.axi._
import spinal.lib.bus.amba4.axilite._

// ============================================================================
// ★★ Y1-DMA **Phase-2a**（2026-10-13）：**多通道通用 DMA 引擎**（独立 RTL，不入胶合）
// ============================================================================
// 上游：`docs/superpowers/specs/2026-10-13-y1-soc-dma-engine-design.md`（§2 家底、§3.1 裁决=C、
//       §4 六条裁决项、§5 D1/D2/D6、§6 R2）、
//       `docs/superpowers/plans/2026-10-13-y1-soc-dma-engine.md` **Phase 2（T2.1 引擎）**、
//       `y1/reports/dma_phase1.md` §7（给 Phase-2 的接口单）。
//
// **本相只做"引擎这一半"**：一个多通道引擎（CSR + AXI4 主口），**不接进胶合**（那是 Phase-2b/2c）。
// 第一个真客户（SD 装载器 / 网络槽）也在 2b/2c。
//
// ---------------------------------------------------------------------------
// 0) 为什么放在 `y1/rtl/`（而不是 plan 里写的 `src/peripheral/`）
// ---------------------------------------------------------------------------
// 三条硬理由（都是"能不能复用"的问题，不是偏好）：
//   ① **每个通道的搬运数据通路就是 `DdrMaster` 的实例** —— 而 `DdrMaster` 是 **SpinalHDL**
//      （`y1/rtl/DdrMaster.scala`）。Chisel 无法实例化 SpinalHDL 组件 ⇒ 引擎本身必须是 SpinalHDL，
//      必须住 `y1/rtl/`。这正是任务里"prefer generalising this over inventing a new shape"的字面落实：
//      32 B 粒度契约、尾块缩短突发、COPY/RD/WR 三模式、err 语义**全部继承**自那个已验收的件。
//   ② **判据装置也在 y1**：`y1/rtl_test/AxiMemModel.v`（行为级 AXI4 内存模型：逐字节 + 不合规突发
//      `$fatal` + `MEM rd/wr/bursts` 独立计数）与 15 个 `run_*_ab.sh` 全在 y1 这套流程里。
//   ③ **2b 的接法本来就是"板级兄弟"**：`NpuTop` 也是 SpinalHDL，胶合块（Chisel）只暴露一根
//      AXI 主口 `npuMem`，真正的 NPU 在 `board/yeshen_mini_soc.v` 里当兄弟例化。DMA 引擎同理：
//      2b 在胶合里加一根主口 + `dmaPend`（Phase-1 报告 §7 已把接口单写好），引擎在板级例化。
//      ⇒ 引擎**不进** `src/`（不进 glue jar），与本相"不入胶合"的范围一致。
//
// ---------------------------------------------------------------------------
// 1) 结构：**N 个独立通道 = N 个 `DdrMaster` 实例 + 一个事务级轮转 AXI4 仲裁器**
// ---------------------------------------------------------------------------
// §4.3 的裁决原文是"推荐 1 个（串行）；多通道 = C"。fabric 侧 Phase-0/1 已经把承重项做完了
// （`DDR3Bridge` 多未完成、§3.5 真仲裁），所以本相**不取 1**、取 **NCH = 2**（可参数化 1..4）：
//   · 每个通道是一台**完整的独立引擎**（自己的块缓冲、自己的 FSM、自己的 rd/wr 流口、自己的 CSR）；
//   · 唯一共享的资源是 **AXI4 主口**，由一个**事务级轮转仲裁器**（grant 从命令被接收持有到
//     `rlast`/`B`）分时；两个通道可以**同时在飞**（都 busy），授予在事务边界交替 ⇒ 可观测的并发。
//   · **逐通道独立记账**：`bytes_moved` / `cycles` / `err_code` / `done` / `abort` 全在通道自己的
//     寄存器里；没有任何一条路径把 A 通道的计数写进 B 通道的寄存器（负对照打的就是这一处）。
//   · `NCH = 1` 是退化情形：仲裁器恒选通道 0，逐拍等价于"直连"（单通道不变性）。
//
// 为什么仲裁器**不是** `MemArbiter`：那是 §3.5 胶合块里的**类间（CPU/NPU/DMA）**仲裁器（Chisel），
// 管的是"谁当主人"；这里是**同一个主人内部**的通道间仲裁，级别不同、语言不同。两者**同构**：
// 都是"请求 + 空闲 + 授予，调用方持有到事务完成"（见 `src/soc/MemArbiter.scala` 文件头）。
//
// ---------------------------------------------------------------------------
// 2) CSR 表（**形状沿用 `DdrMaster` + `HostRegs` 的寄存器惯用法**；§4.1/§4.6 的裁决）
// ---------------------------------------------------------------------------
// 窗口：256 B（`NCH = 2`）。每通道 0x40，全局寄存器跟在通道块之后（`G_BASE = NCH*0x40`）。
//
//   每通道 c（基址 = c*0x40）：
//     0x00 CH_CTRL    W: bit0 start（**自清单拍**）bit1 abort（**自清单拍**）
//                     R: bit8 busy(RO) / bit9 done_sticky(RO)
//     0x04 CH_STATUS  R: bit0 done_sticky / bit1 err_sticky / bit2 aborted
//                     W: bit0..2 = write-1-to-clear（自清单拍）
//     0x08 CH_SRC     RW  源地址（低 5 位必须为 0 ⇒ 32 B 对齐）
//     0x0C CH_DST     RW  目标地址（同上）
//     0x10 CH_LEN     RW  字节数（必须 32 的正整数倍）
//     0x14 CH_MODE    RW  bit1:0 = 0 COPY / 1 RD（只读 ⇒ 推流）/ 2 WR（只写 ⇐ 拉流）/ 3 **非法**
//     0x18 CH_BYTES   RO  `bytes_moved`（§4.6 对账口；busy 时给**实时值**，完成后给**终值**）
//     0x1C CH_CYCLES  RO  `cycles`（同上口径）
//     0x20 CH_ERRCODE RO  `err_code`（1=len 非 32 倍数 / 2=len=0 / 3=src 未对齐 / 4=dst 未对齐 /
//                          5=mode 非法 / 6=已 abort）
//     0x24 CH_ID      RO  通道常数 0x444D4100|c（"DMA\0"+c）
//     0x28..0x3C      保留（读 0、写忽略）
//   全局（基址 = NCH*0x40，即 NCH=2 时 0x80）：
//     0x00 GBL_ID     RO 0x59444D41（"YDMA"）
//     0x04 GBL_NCH    RO 通道数
//     0x08 GBL_BUSY   RO 忙向量（bit c）
//     0x0C GBL_DONE   RO done_sticky 向量（bit c）—— 2b 的 PLIC 源 4 从这里取一个线或即可
//     0x10 GBL_ERR    RO err_sticky 向量（bit c）
//
// **语义口径（冻结）**：
//   · `start` 写 1 ⇒ 下一拍把 `SRC/DST/LEN/MODE` 快照进通道影子寄存器（此后主机改 CSR **不影响**
//     在飞的这一笔），同时**清空本通道上一次的操作记录**（done/err/aborted/bytes/cycles/err_code）
//     ⇒ "一次 start = 一条操作记录"。
//   · **合法性只由 `DdrMaster` 判**（`CHK` 态：src/dst 低 5 位为 0、`len % 32 == 0 && len != 0`
//     ⇒ 否则 err 一拍、一字节不搬）。本模块**不重复设卡**，只把同一条谓词**解码成 `err_code`**
//     （读的不是"另立一套判据"，而是同一个影子寄存器上的同一条比较）；`mode == 3` 是**本模块**
//     加的第二个卡点（`DdrMaster` 对 mode==3 静默等价 COPY，是个 footgun ⇒ 引擎层响亮拒绝、码 5）。
//     ⚠️ 这个"只解码不设卡"是**有意**的：合法性只有一个权威站点（`DdrMaster.CHK`），
//       负对照"静默收下非法 len"变异的是那个站点，一旦它被关掉，本模块**不会**替它兜住
//       ⇒ 判据必红（见 `y1/tools/negctl_dmaeng_ab.sh` 的 NC2）。
//   · `err_code` 在 `err_sticky` 或 `aborted` 置位时有效。
//   · 32 B 粒度契约（`DdrMaster` 的 P3）在引擎层**逐字继承**：AR/AW 驱动的地址低 5 位由构造为 0、
//     `arlen/awlen <= 15`，不合规的主口由 `AxiMemModel` **响亮 $fatal**。
//
// ---------------------------------------------------------------------------
// 3) abort（§4.6 的"保守第一版"）—— **在安全边界上生效**
// ---------------------------------------------------------------------------
// `abort` 写 1 ⇒ 本通道**不再被仲裁器授予**（`req` 被掩掉），并等当前**在飞的那一笔 AXI 事务**落地
// （读等 `rlast`、写等 `B`；这一步是自然排空，不需要强推，因为授予本来就持有到事务完成），
// 然后**把该通道的 `DdrMaster` 用自己的（同频不同复位）`ClockDomain` 复位 RST_CYCLES 拍**
// ⇒ 通道回 IDLE、`busy` 落 0、`aborted` 置位、`err_code=6`，并**能立刻接受下一次 start**。
//   · **为什么必须"等排空再复位"**：若在读突发中途把 `DdrMaster` 复位，它的 `r.ready` 会在
//     `rvalid` 还在的拍落 0 ⇒ 内存模型停在中途、残留拍随后被**下一次**搬运当成自己的数据
//     （静默搬错）。所以 abort 语义明确写成"**当前事务排空后**在通道边界停下"，
//     `bytes_moved` = 该时刻**真正到位**的字节数（COPY/WR = 已写出的字节，RD = 已推流的字节）。
//   · 复位用的是**通道自己的 ClockDomain**（时钟 = 本模块时钟，复位 = 系统复位 OR 通道 abort 复位）
//     ⇒ 同频、无需 CDC；不碰系统复位、不碰别的通道。
//
// ---------------------------------------------------------------------------
// 4) 描述符环（§4.1 的"可选升级"、§3.1 的 "B 形态"）—— **本相明确不做**
// ---------------------------------------------------------------------------
// **不做，且不装作做了**。理由：spec §3 的推荐是"先 A、把 B 写成升级路径"，而 §3.1 的裁决是把
// **承重项**（DDR 桥多未完成 + §3.5 真仲裁）先做掉 —— 那两件 Phase-0/1 已完成；到本相为止，
// 引擎的**程序模型**仍是 §4.1 的"A 的 CSR 形状 + 一个'链指针'寄存器（环留接口）"。
// 环（`{src,dst,len,flags,next}`、完成位、中断）自带一套**所有权/一致性纪律**（与 NPU 的
// `LayerSched`/描述符纪律要分清），且需要 `DescFetch` 式的 DDR 取表通路 —— 那是**下一个独立档**。
// ⇒ 本相的 CSR-only 通路是一条**完整、可判**的交付（D1 三向背靠背逐字节 + D2 对账 + 负对照），
//   描述符环在 §"Phase-2b" 里作为**待接项**列出（接口留口：`CH_MODE` 之上还有 2 bit 未用，
//   `CH_CTRL` 的 bit2..7 未用 —— 环的"链模式 / 链指针"可以落在那里而不动既有字段）。
// ============================================================================
class DmaEngine(cfg: DmaEngineConfig) extends Component {

  val NCH = cfg.NCH
  require(NCH >= 1 && NCH <= 4, s"DmaEngine: NCH 必须落在 1..4（给了 $NCH）")
  val CW = scala.math.max(1, log2Up(NCH))    // 通道号位宽
  /** 通道复位保持拍数（abort 用；>1 是给同频同步复位留出确定边沿）。 */
  val RST_CYCLES = 2
  val CH_STRIDE  = 0x40
  val G_BASE     = NCH * CH_STRIDE
  /** per-channel register 偏移（与 §2 的 CSR 表一一对应）。 */
  private val OFF_CTRL = 0x00
  private val OFF_STAT = 0x04
  private val OFF_SRC  = 0x08
  private val OFF_DST  = 0x0C
  private val OFF_LEN  = 0x10
  private val OFF_MODE = 0x14
  private val OFF_BYTE = 0x18
  private val OFF_CYC  = 0x1C
  private val OFF_ERR  = 0x20
  private val OFF_ID   = 0x24

  val dmCfg  = DdrMasterConfig(cfg.ADDR_W, cfg.DATA_W, cfg.ID_W, cfg.CHUNK_BYTES)
  val axiCfg = Axi4Config(cfg.ADDR_W, cfg.DATA_W, idWidth = cfg.ID_W,
    useId = true, useLen = true, useLock = false, useRegion = false, useQos = false,
    awUserWidth = 0, arUserWidth = 0, wUserWidth = 0, bUserWidth = 0, rUserWidth = 0)

  val io = new Bundle {
    val axilite  = slave(AxiLite4(32, 32))
    val axi      = master(Axi4(axiCfg))
    // ---- 每通道的流口（RD 模式推出 / WR 模式填入；与 DdrMaster 同形，逐通道一份）----
    val rd_valid = out Vec (Bool(), NCH)
    val rd_ready = in  Vec (Bool(), NCH)
    val rd_data  = out Vec (Bits(cfg.DATA_W bits), NCH)
    val wr_valid = in  Vec (Bool(), NCH)
    val wr_ready = out Vec (Bool(), NCH)
    val wr_data  = in  Vec (Bits(cfg.DATA_W bits), NCH)
    // ---- ★ Phase-2b：完成/错误中断（给板级 PLIC 源 4）----
    // 语义：`GBL_DONE`/`GBL_ERR` 两个向量的**线或**（任一通道 done_sticky 或 err_sticky 抬起）。
    // 这是**电平**保持信号 —— 唯一清源手段是主机写该通道 `CH_STATUS` 的 w1c（bit0/1/2），
    // 与 `PlicAlite` 的"源电平 → 锁存 pending + 读 claim 清源"网关天然适配。
    val irq = out Bool()
    // ---- ★ H2（eth_memread 服务）：**硬件作业口**，直连专用通道 `cfg.JOB_CH` ----
    // 语义与 CSR 的 start 逐条等价（快照 addr/len → 清记录 → launch），但它把 mode 钉成
    // **RD（mem→stream 推流）**、dst 钉 0，且不需要主机写 CSR。`job_ready` 高且 `job_valid`
    // 高的那一拍受理；`job_done`/`job_err` 是该通道完成的**单拍脉冲**（不是 sticky）。
    // 与 CSR 通路**互斥使用**：主机不要对 JOB_CH 写 start（本口只覆盖启动那一步的记录清除）。
    val job_valid = in  Bool()
    val job_ready = out Bool()
    val job_addr  = in  UInt(cfg.ADDR_W bits)      // DDR 字节偏移，32 B 对齐
    val job_len   = in  UInt(32 bits)              // 32 的正整数倍
    val job_done  = out Bool()
    val job_err   = out Bool()
  }
  noIoPrefix()

  // ==========================================================================
  // A) CSR 寄存器（每通道一份；`HostRegs.scala` 的惯用法：RW 整 32 位存储、
  //    自清单拍用 "bus.write 之后 when(x){x:=False}"、RO 用 bus.read(纯表达式)）
  // ==========================================================================
  val bus = AxiLite4SlaveFactory(io.axilite)

  val srcR   = Vec(Reg(UInt(32 bits)) init 0, NCH)
  val dstR   = Vec(Reg(UInt(32 bits)) init 0, NCH)
  val lenR   = Vec(Reg(UInt(32 bits)) init 0, NCH)
  val modeR  = Vec(Reg(UInt(32 bits)) init 0, NCH)
  val startP = Vec(RegInit(False), NCH)      // start：自清单拍
  val abortP = Vec(RegInit(False), NCH)      // abort：自清单拍
  val clrP   = Vec(RegInit(False), NCH)      // STATUS w1c：自清单拍

  // 影子（start 时快照 ⇒ 在飞期间主机改 CSR 不影响本次搬运）
  val srcSh    = Vec(Reg(UInt(cfg.ADDR_W bits)) init 0, NCH)
  val dstSh    = Vec(Reg(UInt(cfg.ADDR_W bits)) init 0, NCH)
  val lenSh    = Vec(Reg(UInt(32 bits)) init 0, NCH)
  val modeSh   = Vec(Reg(UInt(2 bits)) init 0, NCH)
  val modeBadSh= Vec(RegInit(False), NCH)
  val launch   = Vec(RegInit(False), NCH)    // startP 延后一拍（给影子寄存器让路）

  // 操作记录 / 粘滞位
  val doneSticky = Vec(RegInit(False), NCH)
  val errSticky  = Vec(RegInit(False), NCH)
  val aborted    = Vec(RegInit(False), NCH)
  val errCodeR   = Vec(Reg(UInt(8 bits)) init 0, NCH)
  val bytesR     = Vec(Reg(UInt(32 bits)) init 0, NCH)
  val cycR       = Vec(Reg(UInt(32 bits)) init 0, NCH)

  // abort 排空 + 通道复位
  val chAbortPnd = Vec(RegInit(False), NCH)
  val chRst      = Vec(RegInit(False), NCH)
  val chRstCnt   = Vec(Reg(UInt(3 bits)) init 0, NCH)

  // ==========================================================================
  // B) 每通道 = 自己的（同频、复位 = 系统复位 || chRst）ClockDomain + 一台 DdrMaster
  //    ★ 同频不同复位 ⇒ 无 CDC；只把 `chRst(c)` 那一位并进该通道的复位。
  // ==========================================================================
  val chCd = Array.tabulate(NCH) { c =>
    ClockDomain(
      clock  = ClockDomain.current.readClockWire,
      reset  = ClockDomain.current.readResetWire || chRst(c),
      config = ClockDomain.current.config
    )
  }
  val eng = Array.tabulate(NCH)(c => chCd(c)(new DdrMaster(dmCfg, defName = "DmaDdrMaster", rqDepth = 1)))  // L2b：本模块的通道间仲裁器是**事务级单笔**语义（授予持有到 rlast/B）⇒ 通道必须保持"同一时刻至多一笔 AR 在飞"，故 rqDepth=1（块槽预取只给直连 NpuTop 的 DdrMaster）。DMA-fix：子模块改名 DmaDdrMaster ⇒ 与 NpuTop.v 内联的 module DdrMaster 不撞名。只换落盘名/队列深度，端口不动；判据 y1/tools/check_dup_modules.py。
  /** 每通道"忙"（`launch` 补上 start 与 CHK 之间那一拍）。 */
  val chBusy = (0 until NCH).map(c => launch(c) || eng(c).io.busy)

  // ---- 硬件作业口（只服务 `cfg.JOB_CH` 这一个通道）----
  require(cfg.JOB_CH >= 0 && cfg.JOB_CH < NCH, s"DmaEngine: JOB_CH 必须落在 0..${NCH-1}")
  private val jobReadyC = !chBusy(cfg.JOB_CH) && !chRst(cfg.JOB_CH) && !chAbortPnd(cfg.JOB_CH)
  io.job_ready := jobReadyC
  private val jobFire = io.job_valid && jobReadyC

  // ==========================================================================
  // C) AXI4 仲裁器（通道间；**事务级轮转**：持有到 rlast/B）
  //    `req(c)` = 该通道要发命令（arvalid || awvalid）且没在 abort/reset；
  //    `inFlight` = 有一笔事务从"命令被接收"到"rlast/B"之间在飞。
  // ==========================================================================
  val selR      = Reg(UInt(CW bits)) init 0
  val lastR     = Reg(UInt(CW bits)) init 0
  val inFlightR = RegInit(False)

  val reqC   = (0 until NCH).map(c =>
    (eng(c).io.axi.ar.valid || eng(c).io.axi.aw.valid) && !chAbortPnd(c) && !chRst(c))
  val anyReq = reqC.reduce(_ || _)

  // 轮转：从 `last` 的**下一个**通道起环向找第一个有请求的通道（k = 1..NCH）。
  // 全用 Scala `Seq` + 平衡 Mux（不建 Vec ⇒ 不需要"用硬件下标索引 Vec"）。
  def reqAt(i: UInt): Bool =
    (0 until NCH).foldLeft(False: Bool)((acc, c) => Mux(i === U(c, CW bits), reqC(c), acc))
  def rrIdx(k: Int): UInt = {
    val t = lastR + U(k, CW + 1 bits)
    Mux(t >= U(NCH, CW + 1 bits), t - U(NCH, CW + 1 bits), t)(CW - 1 downto 0)
  }
  val pickIdx = (1 to NCH).foldRight(rrIdx(NCH)) { (k, acc) =>
    val i = rrIdx(k)
    Mux(reqAt(i), i, acc)
  }
  val selNow = Mux(inFlightR, selR, pickIdx)

  /** 从各通道里按 `selNow` 取同一个信号（NCH<=4 ⇒ 平衡 Mux 树）。 */
  def chMux[T <: Data](f: DdrMaster => T): T = {
    val items = eng.map(f).toSeq
    def rec(lo: Int, hi: Int): T = {
      if (hi - lo == 1) items(lo)
      else {
        val mid = (lo + hi) / 2
        Mux(selNow < U(mid, CW bits), rec(lo, mid), rec(mid, hi))
      }
    }
    rec(0, NCH)
  }

  // ---- 下行（引擎 -> 内存）：valid/payload 按 selNow 选；命令 valid 还要求 anyReq
  //      （否则被 abort/reset 掩掉请求的那台引擎可能被"默认项"选中 ⇒ 抢到总线）----
  io.axi.ar.valid          := chMux(_.io.axi.ar.valid) && anyReq
  io.axi.ar.payload.addr   := chMux(_.io.axi.ar.payload.addr)
  io.axi.ar.payload.len    := chMux(_.io.axi.ar.payload.len)
  io.axi.ar.payload.size   := chMux(_.io.axi.ar.payload.size)
  io.axi.ar.payload.burst  := chMux(_.io.axi.ar.payload.burst)
  io.axi.ar.payload.id     := chMux(_.io.axi.ar.payload.id)
  io.axi.ar.payload.cache  := chMux(_.io.axi.ar.payload.cache)
  io.axi.ar.payload.prot   := chMux(_.io.axi.ar.payload.prot)

  io.axi.aw.valid          := chMux(_.io.axi.aw.valid) && anyReq
  io.axi.aw.payload.addr   := chMux(_.io.axi.aw.payload.addr)
  io.axi.aw.payload.len    := chMux(_.io.axi.aw.payload.len)
  io.axi.aw.payload.size   := chMux(_.io.axi.aw.payload.size)
  io.axi.aw.payload.burst  := chMux(_.io.axi.aw.payload.burst)
  io.axi.aw.payload.id     := chMux(_.io.axi.aw.payload.id)
  io.axi.aw.payload.cache  := chMux(_.io.axi.aw.payload.cache)
  io.axi.aw.payload.prot   := chMux(_.io.axi.aw.payload.prot)

  io.axi.w.valid           := chMux(_.io.axi.w.valid)
  io.axi.w.payload.data    := chMux(_.io.axi.w.payload.data)
  io.axi.w.payload.strb    := chMux(_.io.axi.w.payload.strb)
  io.axi.w.payload.last    := chMux(_.io.axi.w.payload.last)

  // ---- 上行（内存 -> 引擎）：ready 按 selNow 选；r/b 广播但**只给当拍被授权的通道**
  //      ★ 关键：`ar/aw/w.ready` **必须**按"本拍总线上呈现的是不是它"加门（`isSel`）。
  //        `DdrMaster` 的 AR 态只判 `arready`（单主人语境下 arready ⇒ 握手，因为 arvalid 是它自己举的），
  //        所以若把 ready 广播给所有通道，**没被选中的通道也会以为自己那笔被收下了**
  //        ⇒ 它会跳进 R 态、把别人的 R 拍当成自己的（实测踩到：两通道并发时 B 通道永远抢不到，
  //        A 通道读完一块就再也不发 AW）。加上 `anyReq` 是因为 `pickIdx` 在没有请求时会退回
  //        `lastR`（一个可能正被 abort/reset 掩掉请求的通道），那时任何通道都不该看到 ready。
  //      未被授权的通道本来就不在 R/W 相位（`r.ready`/`b.ready` 恒 0）⇒ 不会误吞数据。----
  for (c <- 0 until NCH) {
    val selC  = inFlightR && (selR === U(c, CW bits))
    val isCmd = anyReq && (selNow === U(c, CW bits))   // 命令相位：本拍总线上呈现的是它（且真有人请求）
    val isDat = selNow === U(c, CW bits)               // 数据相位：W 的呈现不带 anyReq 门，所以 ready 也不带
    eng(c).io.axi.r.valid   := io.axi.r.valid && selC
    eng(c).io.axi.r.payload := io.axi.r.payload
    eng(c).io.axi.b.valid   := io.axi.b.valid && selC
    eng(c).io.axi.b.payload := io.axi.b.payload
    eng(c).io.axi.ar.ready  := io.axi.ar.ready && isCmd
    eng(c).io.axi.aw.ready  := io.axi.aw.ready && isCmd
    eng(c).io.axi.w.ready   := io.axi.w.ready  && isDat
  }
  io.axi.r.ready := chMux(_.io.axi.r.ready) && inFlightR
  io.axi.b.ready := chMux(_.io.axi.b.ready) && inFlightR

  // ★ 通道域与本域**同频**（只差一个复位项）⇒ 通道 io 上的每一根线都是**有意的同频跨域**。
  //   标 `crossClockDomain` 只为让 SpinalHDL 的 `PhaseCheckCrossClock` 放行：这是**元数据**
  //   （声明设计意图），不进网表语义 —— PDS 只看到线，两个域用的是**同一根 clock**。
  //   为什么必须这么写：SpinalHDL 给"新 ClockDomain"的时钟建了自己的 clock wire 实例，
  //   于是它把 `clk -> clk` 这种同频连线判成"跨域"（见 `NpuAxiLiteCdc.scala` 的同一手法）。
  for (c <- 0 until NCH) {
    eng(c).io.flattenForeach(bt => crossClockDomain(bt))
  }

  // ---- 授予状态机 ----
  val cmdFire   = (io.axi.ar.valid && io.axi.ar.ready) || (io.axi.aw.valid && io.axi.aw.ready)
  val setIF     = !inFlightR && anyReq && cmdFire
  val rlastFire = io.axi.r.valid && io.axi.r.ready && io.axi.r.payload.last
  val bFire     = io.axi.b.valid && io.axi.b.ready
  val clrIF     = inFlightR && (rlastFire || bFire)
  when(!inFlightR && anyReq) { selR := pickIdx }
  when(setIF)                { inFlightR := True; selR := pickIdx; lastR := pickIdx }
  when(clrIF)                { inFlightR := False }

  // ==========================================================================
  // D) 每通道：CSR 接线 + 影子/启动 + err_code 解码 + 记录 + abort 排空
  // ==========================================================================
  for (c <- 0 until NCH) {
    val base = c * CH_STRIDE

    // ---- D.1 CSR ----
    bus.readAndWrite(srcR(c),  base + OFF_SRC)
    bus.readAndWrite(dstR(c),  base + OFF_DST)
    bus.readAndWrite(lenR(c),  base + OFF_LEN)
    bus.readAndWrite(modeR(c), base + OFF_MODE)
    bus.write(startP(c), base + OFF_CTRL, 0)
    bus.write(abortP(c), base + OFF_CTRL, 1)
    bus.write(clrP(c),   base + OFF_STAT, 0)
    when(startP(c)) { startP(c) := False }     // 自清单拍（写在 bus.write 之后 ⇒ 本拍起效、下拍落 0）
    when(abortP(c)) { abortP(c) := False }
    when(clrP(c))   { clrP(c)   := False }

    // ---- D.2 影子 + 启动 ----
    // 两个启动源：CSR `start`（主机）与硬件作业口 `jobFire`（只在 JOB_CH 上存在）。
    // 二者共用同一套影子快照/记录清除 ⇒ 语义逐条同义（job 把 mode 钉成 RD、dst 钉 0）。
    val fireC  = if (c == cfg.JOB_CH) jobFire else False
    when(startP(c) || fireC) {
      srcSh(c)     := Mux(fireC, io.job_addr, srcR(c)(cfg.ADDR_W - 1 downto 0))
      dstSh(c)     := Mux(fireC, U(0, cfg.ADDR_W bits), dstR(c)(cfg.ADDR_W - 1 downto 0))
      lenSh(c)     := Mux(fireC, io.job_len, lenR(c))
      modeSh(c)    := Mux(fireC, U(1, 2 bits), modeR(c)(1 downto 0))   // 1 = RD（mem→stream）
      modeBadSh(c) := !fireC && (modeR(c)(1 downto 0) === U(3, 2 bits))
      launch(c)    := True
    }.otherwise {
      launch(c) := False
    }

    eng(c).io.src      := srcSh(c)
    eng(c).io.dst      := dstSh(c)
    eng(c).io.len      := lenSh(c)
    eng(c).io.mode     := modeSh(c)
    eng(c).io.sg_valid := False            // ★ B3b：DMA 引擎通道不用 SG-RD
    eng(c).io.sg_flush := False
    eng(c).io.sg_addr  := U(0, dmCfg.ADDR_W bits)
    eng(c).io.sg_beatsM1 := U(0, 4 bits)
    // mode==3 由**本模块**拒（DdrMaster 对它静默等价 COPY；见文件头 §2）
    eng(c).io.start    := launch(c) && !modeBadSh(c)
    // 流口直连（RD 推出 / WR 填入）；不用的模式里 DdrMaster 结构性地不举 valid/ready
    eng(c).io.rd_ready := io.rd_ready(c)
    eng(c).io.wr_valid := io.wr_valid(c)
    eng(c).io.wr_data  := io.wr_data(c)
    // ★★ T-S2b：写字节掩码（DMA 引擎是全字节写 ⇒ 恒 8'hFF，与改动前逐拍同形）
    eng(c).io.wstrb    := B(0xFF, cfg.DATA_W / 8 bits)
    io.rd_valid(c)     := eng(c).io.rd_valid
    io.rd_data(c)      := eng(c).io.rd_data
    io.wr_ready(c)     := eng(c).io.wr_ready

    // ---- D.3 err_code 解码（与 DdrMaster.CHK **同一条谓词**，只解码不设卡）----
    val lenMul  = lenSh(c)(4 downto 0) === 0        // == len % 32 == 0
    val lenNonZ = lenSh(c) =/= 0
    val srcAl   = srcSh(c)(4 downto 0) === 0
    val dstAl   = dstSh(c)(4 downto 0) === 0
    val modeBad = modeSh(c) === U(3, 2 bits)
    val codeC   = Mux(modeBad,  U(5, 8 bits),
                  Mux(!lenMul,  U(1, 8 bits),
                  Mux(!lenNonZ, U(2, 8 bits),
                  Mux(!srcAl,   U(3, 8 bits),
                  Mux(!dstAl,   U(4, 8 bits), U(0, 8 bits))))))
    val errInj    = launch(c) && modeBadSh(c)       // 本模块拒的 mode==3（1 拍脉冲）
    val errPulse  = eng(c).io.err || errInj
    // COPY/WR ⇒ 写出的字节；RD ⇒ 推流的字节（结构性：另一侧恒 0）
    val liveBytes = Mux(modeSh(c) === U(1, 2 bits), eng(c).io.rd_bytes, eng(c).io.wr_bytes)
    val busyC     = chBusy(c)

    // ---- D.4 记录：start 清记录（先写）⇒ 完成/错误 置位（后写）⇒ w1c 最高优先（最后写）----
    when(launch(c)) {
      doneSticky(c) := False
      errSticky(c)  := False
      aborted(c)    := False
      errCodeR(c)   := 0
      bytesR(c)     := 0
      cycR(c)       := 0
    }
    when(errPulse) {
      errSticky(c) := True
      errCodeR(c)  := Mux(errInj, U(5, 8 bits), codeC)
      bytesR(c)    := liveBytes
      cycR(c)      := eng(c).io.cyc
    }
    when(eng(c).io.done) {
      doneSticky(c) := True
      bytesR(c)     := liveBytes
      cycR(c)       := eng(c).io.cyc
    }

    // ---- D.5 abort：排空在飞事务 -> 通道复位 -> aborted ----
    when(abortP(c)) { chAbortPnd(c) := True }
    val drainOk = !(inFlightR && (selR === U(c, CW bits)))
    when(chAbortPnd(c) && drainOk) {
      when(chRstCnt(c) === 0 && !chRst(c)) {
        chRst(c)    := True
        chRstCnt(c) := U(RST_CYCLES, 3 bits)
        bytesR(c)   := liveBytes              // 在复位吃掉计数器**之前**记下来
        cycR(c)     := eng(c).io.cyc
        errCodeR(c) := U(6, 8 bits)           // 6 = ABORTED
      }.otherwise {
        when(chRst(c)) {
          chRstCnt(c) := chRstCnt(c) - 1
          when(chRstCnt(c) === 1) {
            chRst(c)      := False
            chAbortPnd(c) := False
            aborted(c)    := True
          }
        }
      }
    }

    // ---- D.6 w1c（最后写 ⇒ 压过上面的置位）----
    when(clrP(c)) {
      doneSticky(c) := False
      errSticky(c)  := False
      aborted(c)    := False
    }

    // ---- D.7 RO 读口 ----
    bus.read(Cat(B(0, 22 bits), doneSticky(c).asBits, busyC.asBits, B(0, 8 bits)), base + OFF_CTRL)
    bus.read(Cat(B(0, 29 bits), aborted(c).asBits, errSticky(c).asBits, doneSticky(c).asBits), base + OFF_STAT)
    bus.read(Mux(eng(c).io.busy, liveBytes, bytesR(c)),        base + OFF_BYTE)
    bus.read(Mux(eng(c).io.busy, eng(c).io.cyc, cycR(c)),      base + OFF_CYC)
    bus.read(errCodeR(c).resize(32),                           base + OFF_ERR)
    bus.read(U(0x444D4100L + c, 32 bits),                      base + OFF_ID)
  }

  // ==========================================================================
  // E) 全局寄存器（给 2b 的 PLIC 源 4 / 台账留口）
  // ==========================================================================
  bus.read(U(0x59444D41L, 32 bits), G_BASE + 0x00)
  bus.read(U(NCH, 32 bits),         G_BASE + 0x04)
  // 位向量：`Cat` 的第一个元素是 LSB ⇒ bit(c) = 第 c 通道
  bus.read(Cat((0 until NCH).map(c => chBusy(c).asBits)).resize(32),       G_BASE + 0x08)
  bus.read(Cat((0 until NCH).map(c => doneSticky(c).asBits)).resize(32),   G_BASE + 0x0C)
  bus.read(Cat((0 until NCH).map(c => errSticky(c).asBits)).resize(32),    G_BASE + 0x10)

  // ★ Phase-2b：中断线 = `GBL_DONE` | `GBL_ERR` 的逐通道 OR（见 io.irq 注释）。
  io.irq := (0 until NCH).map(c => doneSticky(c) || errSticky(c)).reduce(_ || _)

  // ---- 硬件作业口的完成/错误（单拍脉冲，不是 sticky；sticky 仍在 JOB_CH 的 CSR 里）----
  io.job_done := eng(cfg.JOB_CH).io.done
  io.job_err  := eng(cfg.JOB_CH).io.err || (launch(cfg.JOB_CH) && modeBadSh(cfg.JOB_CH))
}

/** 形状参数（接口冻结，与 `DdrMaster` 对齐；`NCH` 是本相新增的唯一自由度）。 */
case class DmaEngineConfig(
  NCH:         Int = 2,
  ADDR_W:      Int = 28,
  DATA_W:      Int = 64,
  ID_W:        Int = 4,
  CHUNK_BYTES: Int = 128,
  /** H2：硬件作业口绑定的通道号（`io.job_*`）；该通道的 CSR start 与作业口互斥使用。 */
  JOB_CH:      Int = 1
)
