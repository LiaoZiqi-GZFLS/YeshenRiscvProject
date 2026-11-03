import chisel3._
import chisel3.util._
// ⚠️ `import chisel3.util._` 会把名字 `circt` 解析到 `chisel3.util.circt` ⇒ 必须用 `_root_.` 前缀
//    （`NaxMiniGlueMain.scala` 只 import `chisel3._`，所以它那边的 `circt.stage` 没有这个问题）
import _root_.circt.stage.{ChiselStage, FirtoolOption}
import chisel3.stage.ChiselGeneratorAnnotation

// ===================== AXI4 → DDR3 简化 AXI 异步桥 =====================
// CPU 侧 (axi_clk 域, 100MHz): 完整 AXI4 slave（**64bit 数据**, 字节地址）
// DDR 侧 (ddr_clk 域, 125MHz): 紫光同创 DDR3 IP 简化 AXI（256bit 数据, word 地址）
//
// ============================================================================
// ★★ Y1-DMA **Phase-0**（2026-10-13）：**把 DDR 桥放开成多未完成**（spec §3.1 的承重前提）
// ============================================================================
// 【本轮要放开的两条现状限制】（T0.1 冻结红线 —— 它们是**改前**的实测事实，不是建议）
//   L1 **单 outstanding 事务**：改前 `axi.aw.awready := wrState === sWrIdle`、
//      `axi.ar.arready := rdState === sRdIdle`，而写状态机只在收到 **B 响应**之后才回 `sWrIdle`
//      ⇒ **AXI 侧一笔没回完就不收下一笔**（= 单 outstanding）。读侧同构（R 拍全部发完才回 Idle）。
//   L2 **每笔 AXI 突发被拆成 `ceil((awlen+1)/GRP_BEATS)` 笔单 beat 的 DDR 事务**：理由见下面
//      "简化 AXI 协议特性"——DDR 侧 W 通道**没有 wvalid**（wready 高即采样 ⇒ 数据必须始终有效），
//      且跨域原语 `CDCPipe` 是**电平式四相握手**（一次一份、往返 ≥6 dClk + 4 sClk，无法背靠背）
//      ⇒ 改前每条通道只能"一次一份"，笔与笔之间必须走完一次完整握手。
//
// 【★ 本轮两条**不变**的红线（改前改后逐条成立，判据都钉在闸门上）】
//   R1 **DDR IP 的对外端口一字不改**：`io_ddrAwAddr/ddrAwLen/ddrAwValid/ddrAwReady`、
//      `io_ddrWData/ddrWStrb/ddrWReady`、`io_ddrArAddr/ddrArLen/ddrArValid/ddrArReady`、
//      `io_ddrRData/ddrRValid/ddrRLast`（名字、方向、位宽全部原样）。板级 `board/yeshen_mini_board_top.v`
//      与紫光 DDR3 IP 的装配**不用动**。
//   R2 **地址语义一字不改**：① 每笔 AXI 突发首址 **32 B 对齐**（`awaddr(29,2)` = 32bit **字**地址，
//      低 3 位为 0）；② 每笔 DDR 事务的地址递进 = **+8 个 32bit 字 = 32 B**（DDR 侧地址单位是
//      **32bit 字**，一笔 256bit 事务 = 8 字）；③ 一笔 DDR 事务只发 **1 个 256bit beat**
//      （`ddrAwLen/ddrArLen` 恒 0）。⚠️ `+8` 这个数**不随 AXI 从口位宽变**；spec §2 表里写的 `+4`
//      是**单位笔误**（+4 字 = 16 B ⇒ 第 2 笔与第 1 笔半重叠、末 16 B 永远收不到数据），
//      NC3 会把 `+ 8.U` 打成 `+ 4.U` 并翻红。证据另见 Pango 官方 example design
//      `YeshenCore/ddr3_ref/HDMI_DDR3_OV5640_100H/ipcore/ddr3_test/example_design/rtl/test_wr_ctrl_v1_0.v`：
//      `init_addr <= init_addr + 8` 每 `axi_wready`（= 一个 256bit beat）。
//
// 【★ 本轮怎么做（T0.2）】
//   每条通道（AW/W/AR/R，+ 写完成 token）换成 `CdcFifo`（`src/soc/CDCQueue.scala`）：
//     **源域队列攒拍 + `LANES` 条 `CDCPipe` 轮转并走 + 目的域队列收拍**（顺序不变），
//     `CDCPipe` 本身**一字未改**。于是"电平握手一次一份"变成"FIFO 攒拍 + 独立发单 beat"：
//     · 目的域（ddr 域）攒着多份 ⇒ DDR 侧可以**背靠背**发单 beat 事务，不必等上一次握手撤干净；
//     · 源域（axi 域）攒着多份 ⇒ AXI 侧可以**先收下**后续的 AW/AR/W，不等 B/R 回来。
//   多未完成的**容量**由 `DEPTH` 定（= 每侧队列深度），并由 AXI 口的**信用计数**兜住：
//     `axi.aw.awready := awQ 有位置 && outW < DEPTH`（`outW` = AW 已收 − B 已回）；
//     `axi.ar.arready := 拆分器空闲 && rdQ 有位置 && outR < DEPTH`（`outR` = AR 已收 − rlast 已回）。
//     ⇒ **未完成数 ≤ DEPTH 是可证的**（不是"看起来能到 2"）。
//
// 【★ 分组语义（GRP_BEATS）现在落在哪 —— 契约等价、逐条可查】`
//   `GRP_BYTES = 32` / `GRP_BEATS = 4`（64bit 从口 ⇒ 每 32 B 组 4 拍）**不变**，只是**归属侧**换了：
//   · **axi 侧**：按 `GRP_BEATS` 拍聚合成一个 32 B 组（残组：末组未用 lane 的 `wstrb` **必须清零**，
//     否则残组 padding 会写脏邻居 —— 判据仍钉着）；读侧把一个 256bit 字切成 4 个 64bit 拍回给 AXI。
//   · **ddr 侧**：不再需要 `groups` 计数（`AwCmd.groups` 取消），因为 axi 侧**按 beat** 推命令：
//     每个 32 B 组各推 1 条 `AwBeat{addr}` + 1 份 `WBeat{data,strb,id,last}`，
//     ddr 侧只需"队列非空就发一笔单 beat 事务、`wready` 高就取下一份 W"，**地址逐 beat 已算好**。
//   · AXI 侧看到的仍是**完整突发**：`wlast` 在每笔末拍、B 每笔恰一次且回带本笔 `awid`、
//     `rlast` 落在每笔末拍、`rid` = 本笔 `arid`（与改前逐条相同，既有 8 条单元用例原样守）。
//   ⇒ `wlast`/`rlast`/B 次数/B id 回带的判据**一条没松**。
//
// 【简化 AXI 协议特性（紫光同创 DDR3 IP 用户接口，**不变**）】
// - W 通道无 wvalid，wready 高即采样 → 数据必须始终有效
//   ⇒ 本设计用一条**不变式**兜住：**ddr 侧 AW 队列占用 ≤ W 队列占用**（两条队列同刻同序推入，
//     AW 每发一笔 −1、W 每 `wready` −1，且 `wready` 只在"IP 还有 AW 没配到 W"时才算 ⇒ 差永不反向）
//     ⇒ "AW 队列非空"必然蕴含"这份 W 数据已在 ddr 域"，IP 采样那一拍数据一定是对的。
// - AW 握手后连续发 awlen+1 个 256bit beat：本设计恒 `awlen = 0`（单 beat），见 R2-③。
//
// 【历史上踩过的两个真坑 —— 本设计用**结构**消掉，不用 flag 兜】
//   坑 1（约束 4 原文）：`CDCPipe.deq.valid` 是**电平**不是"新数据"脉冲 ⇒ 同一条管上连续取多份时
//     必须用"本次呈现已取用"标志，否则会**再取一次同一份**（实测 64 B 回写的后 32 B 写成前 32 B）。
//   坑 2（约束 4 补充）：64bit 从口把一组缩到 4 拍，比 CDC 呈现撤销的四相往返还短 ⇒ 读侧也必须加
//     这个标志，否则 64 B 读的第 5..8 拍整段是第 1..4 拍的旧数据、后续 AR 被 `enq.ready` 卡死。
//   ⇒ 现在这两个标志都**搬进 `CdcFifo` 内部**（每条道一个 `dTaken`，取用置 1、`valid` 落清零），
//     而且对外的 `deq` 是**真 FIFO 口**（`valid`/`bits` 稳定、`ready` 弹出）⇒ `DDR3Bridge` 里
//     **不再有** `wItemTaken`/`rItemTaken`/`rFresh` 这类标志，"取到旧呈现"在结构上不可能。
//
// 【约束 5（不变）：axi 侧的 CDC 端复位是**低有效**】
//   `CDCPipe`/`CdcFifo` 内部用 `!io.sRstn`，而本模块隐式 `reset` 是**高有效** ⇒ axi 侧必须写
//   `!reset.asBool`；写成 `reset.asBool` 会让 axi 侧那几个端**在系统离开复位后永久停在复位**
//   （整块桥死掉）。ddr 侧接的 `io.ddr_rstn` 板级给的是 `ddr_init_done`（1 = 初始化完成 = 可跑），
//   对低有效口恰好正确。
//
// 【★ Phase-0 新增的两个**只读观察口**（`io.dbgOutW`/`io.dbgOutR`/`io.dbgMaxOutW`/`io.dbgMaxOutR`）】
//   用途：把"未完成 > 1"变成**装置自报**的证据（plan T0.3）。它们**只读、不参与任何功能**；
//   板级 `board/yeshen_mini_board_top.v` 用**具名端口**例化 ⇒ 新增的输出口不接即可（不接线合法），
//   所以板级与 DDR IP 的装配**仍然一字不改**。`outW` = AW 已收 − B 已回（写未完成笔数），
//   `outR` = AR 已收 − rlast 已回（读未完成笔数），各带一个高水位。
//
// 【改动影响面】本文件 + `src/soc/CDCQueue.scala`（新增 `CdcFifo`）。RTL 一变 ⇒ 重跑 PnR
//   （命令记在 `y1/reports/dma_phase0.md`）；`third_party/**`（含 DDR IP）与冻结工具**未动**。
//
// ===================== AXI4 从口（64bit 数据）=====================
// `src/config/AXIPackage.scala` 的 `AXIIO` 把数据通道写死成 32bit，而 V1 只动本文件 ⇒ 这里局部
// 定义 64bit 的数据通道 bundle：字段名/方向与 `AXIW`/`AXIR` **逐条一致**（Verilog 端口名不变：
// `io_axi_w_wdata` / `io_axi_r_rdata` …），其余通道（`AXIAR`/`AXIAW`/`AXIB`）与宽度无关，直接复用。
// 32bit 版留档在 `attic/DDR3Bridge32.scala`（在 `src/` 之外 ⇒ 不会与 64bit 版同时进编译）。
class AXIW64 extends Bundle {
  val wid    = Output(UInt(4.W))
  val wdata  = Output(UInt(64.W))
  val wstrb  = Output(UInt(8.W))
  val wlast  = Output(Bool())
  val wvalid = Output(Bool())
  val wready = Input(Bool())
}
class AXIR64 extends Bundle {
  val rid    = Input(UInt(4.W))
  val rdata  = Input(UInt(64.W))
  val rresp  = Input(UInt(2.W))
  val rlast  = Input(Bool())
  val rvalid = Input(Bool())
  val rready = Output(Bool())
}
class AXIIO64 extends Bundle {
  val ar = new AXIAR
  val r  = new AXIR64
  val aw = new AXIAW
  val w  = new AXIW64
  val b  = new AXIB
}

class DDR3Bridge extends Module {
  val io = IO(new Bundle {
    val ddr_clk  = Input(Clock())
    val ddr_rstn = Input(Bool())

    // SoC 侧: AXI4 slave（本模块时钟域）
    val axi = Flipped(new AXIIO64)

    // DDR3 IP 侧: 简化 AXI master（ddr_clk 域）—— **R1：端口一字不改**
    val ddrAwAddr  = Output(UInt(28.W))
    val ddrAwLen   = Output(UInt(4.W))
    val ddrAwValid = Output(Bool())
    val ddrAwReady = Input(Bool())

    val ddrWData  = Output(UInt(256.W))
    val ddrWStrb  = Output(UInt(32.W))
    val ddrWReady = Input(Bool())

    val ddrArAddr  = Output(UInt(28.W))
    val ddrArLen   = Output(UInt(4.W))
    val ddrArValid = Output(Bool())
    val ddrArReady = Input(Bool())

    val ddrRData  = Input(UInt(256.W))
    val ddrRValid = Input(Bool())
    val ddrRLast  = Input(Bool())

    // ★ Phase-0 观察口（只读；板级不接）。见文件头。
    val dbgOutW    = Output(UInt(3.W))   // 写未完成笔数（AW 已收 − B 已回）
    val dbgOutR    = Output(UInt(3.W))   // 读未完成笔数（AR 已收 − rlast 已回）
    val dbgMaxOutW = Output(UInt(3.W))   // 上面这条的高水位
    val dbgMaxOutR = Output(UInt(3.W))
  })

  // ==================== 宽度映射（V1：AXI 从口 64bit，DDR 侧一字不改）====================
  private val AXI_BYTES = 8                        // 每 AXI 拍 8 字节（64bit 从口）
  private val AXI_BITS  = AXI_BYTES * 8            // 64：一拍的数据位宽
  private val GRP_BYTES = 32                       // 一笔 DDR 事务 = 256bit = 32B（**不变**）
  private val GRP_BEATS = GRP_BYTES / AXI_BYTES    // 每 32B 组的 AXI 拍数 = **4**（32bit 时代是 8）

  // ==================== Phase-0 多未完成档位 ====================
  // `LANES` = 每条通道并走的 `CDCPipe` 条数（吞吐档）；`DEPTH` = 每条通道源/目的域队列深度，
  // 同时就是**未完成容量**（`outW/outR ≤ DEPTH` 由 AXI 口的信用计数保证）。
  // ⚠️ 两者都置 1 ⇒ **逐字退化回改前的单未完成形态** —— 负对照 NC6 就把这两行打成 1。
  private val LANES = 4
  private val DEPTH = 4

  // ==================== 跨域管道（每条通道一个 CdcFifo）====================
  // axi 域 → ddr 域：AW 单 beat 命令、W 单 beat 数据（含 id/last 标签，供 B 回带）、AR 单 beat 命令
  class AwBeat extends Bundle { val addr = UInt(28.W) }          // 本 beat 的 word 地址（32B 对齐）
  class WBeat extends Bundle {
    val data = UInt(256.W)
    val strb = UInt(32.W)
    val id   = UInt(4.W)     // 本 beat 所属 AXI 突发的 awid（B 回带用）
    val last = Bool()        // 本 beat 是否是所属 AXI 突发的末 beat（B 的触发条件）
  }
  class ArBeat extends Bundle { val addr = UInt(28.W) }

  val awCdc   = Module(new CdcFifo(new AwBeat,  LANES, DEPTH))
  val wCdc    = Module(new CdcFifo(new WBeat,   LANES, DEPTH))
  val arCdc   = Module(new CdcFifo(new ArBeat,  LANES, DEPTH))
  val rCdc    = Module(new CdcFifo(UInt(256.W), LANES, DEPTH))
  val doneCdc = Module(new CdcFifo(UInt(4.W),   LANES, DEPTH))   // ddr → axi：写完成 token（带 awid）

  private def cdcA2D[T <: Data](f: CdcFifo[T]): Unit = {
    f.io.sClk := clock; f.io.sRstn := !reset.asBool
    f.io.dClk := io.ddr_clk; f.io.dRstn := io.ddr_rstn
  }
  private def cdcD2A[T <: Data](f: CdcFifo[T]): Unit = {
    f.io.sClk := io.ddr_clk; f.io.sRstn := io.ddr_rstn
    f.io.dClk := clock; f.io.dRstn := !reset.asBool
  }
  cdcA2D(awCdc); cdcA2D(wCdc); cdcA2D(arCdc)
  cdcD2A(rCdc); cdcD2A(doneCdc)

  // ==================== axi_clk 域: AXI4 slave ====================
  val axi = io.axi

  // ------------------------------------------------------------------
  // ---- 写路径（axi 域）：AW 入队（多未完成）→ 按 32B 组聚合 W → 逐 beat 推入 CDC ----
  // ------------------------------------------------------------------
  class AwCmd extends Bundle {                       // 一笔 AXI 写突发的书签
    val addr = UInt(28.W)                            // 首组首址（word 地址）
    val len  = UInt(8.W)                             // awlen（拍数 − 1）
    val id   = UInt(4.W)
  }
  val awQ = Module(new Queue(new AwCmd, DEPTH * 2))   // AXI 侧多未完成：先收下，慢慢聚合

  // 未完成笔数（AXI 侧口径）：AW 已收 − B 已回
  val outW = RegInit(0.U(3.W))
  val maxOutW = RegInit(0.U(3.W))
  val awAcc  = awQ.io.enq.fire
  val bFire  = axi.b.bvalid && axi.b.bready
  outW := outW + Mux(awAcc, 1.U, 0.U) - Mux(bFire, 1.U, 0.U)
  when(outW > maxOutW) { maxOutW := outW }

  awQ.io.enq.valid := axi.aw.awvalid && (outW < DEPTH.U)
  awQ.io.enq.bits.addr := axi.aw.awaddr(29, 2)
  awQ.io.enq.bits.len  := axi.aw.awlen
  awQ.io.enq.bits.id   := axi.aw.awid
  // ★ 多未完成：只要队列有位置且未完成笔数未到 DEPTH 就收（**不再等 B**，这是 L1 的解药）。
  // ⚠️ 信用必须**同时**掐住 `enq.valid` 与 `awready`：只掐 `awready` 的话，主方把 `awvalid`
  //    挂高时内部队列会**每拍都推进**（信用形同虚设，`outW` 会绕圈），
  //    实测症状 = 后续 AW 命令带着重复的 `id/addr` 进了流水线（B 回带全成同一个 id）。
  axi.aw.awready := awQ.io.enq.ready && (outW < DEPTH.U)

  // 聚合引擎：一次处理 `awQ` 头部那一笔（W 通道严格按 AW 顺序，所以必须是单头串行）
  val wqValid   = RegInit(false.B)
  val wqId      = Reg(UInt(4.W))
  val wqAddr    = Reg(UInt(28.W))                                    // 本组首址（word 地址）
  val wqLeft    = Reg(UInt(9.W))                                     // 本笔还剩几拍 AXI 数据
  val wqGrpLeft = Reg(UInt(7.W))                                     // 本笔还剩几组（地址 +8 字/组）
  val wrFill    = Reg(UInt(log2Ceil(GRP_BEATS + 1).W))               // 本组已收拍数
  val wrBuf     = Reg(Vec(GRP_BEATS, UInt(AXI_BITS.W)))              // 4 × 64bit
  val wrStrb    = Reg(Vec(GRP_BEATS, UInt(AXI_BYTES.W)))             // 4 × 8bit 逐字节掩码
  val wrAgg     = RegInit(true.B)                                    // true=收 W 拍；false=等 CDC 收下这一组

  val wLoad = !wqValid && awQ.io.deq.valid
  awQ.io.deq.ready := wLoad
  when(wLoad) {
    wqValid   := true.B
    wqId      := awQ.io.deq.bits.id
    wqAddr    := awQ.io.deq.bits.addr
    wqLeft    := awQ.io.deq.bits.len + 1.U
    wqGrpLeft := awQ.io.deq.bits.len(7, 2) + 1.U   // `ceil((awlen+1)/4)` = `awlen(7,2) + 1`
    wrFill    := 0.U
    wrAgg     := true.B
    for (i <- 0 until GRP_BEATS) { wrStrb(i) := 0.U }   // 新组：strobes 清零（残组未用 lane 不下发）
  }

  axi.w.wready := wqValid && wrAgg
  when(wqValid && wrAgg && axi.w.wvalid) {
    wrBuf(wrFill)  := axi.w.wdata
    wrStrb(wrFill) := axi.w.wstrb
    wrFill := wrFill + 1.U
    wqLeft := wqLeft - 1.U
    // 本组收满（GRP_BEATS 拍）或本笔收完 ⇒ 这一组可以推送
    when(wrFill === (GRP_BEATS - 1).U || wqLeft === 1.U) { wrAgg := false.B }
  }

  // 发射：本组 4×64bit 聚合成 256bit（beat 0 落最低 64bit）
  val wBeatOut = Wire(new WBeat)
  wBeatOut.data := Cat((0 until GRP_BEATS).reverse.map(i => wrBuf(i)))
  wBeatOut.strb := Cat((0 until GRP_BEATS).reverse.map(i => wrStrb(i)))
  wBeatOut.id   := wqId
  wBeatOut.last := (wqGrpLeft === 1.U)
  val awBeatOut = Wire(new AwBeat)
  awBeatOut.addr := wqAddr

  // AW 命令与 W 数据**必须同刻成对推入**（ddr 侧靠"两队列同占"的不变式兜 W 数据有效性）
  private val wPushOk = wqValid && !wrAgg && awCdc.io.enq.ready && wCdc.io.enq.ready
  awCdc.io.enq.valid := wPushOk
  wCdc.io.enq.valid  := wPushOk
  awCdc.io.enq.bits  := awBeatOut
  wCdc.io.enq.bits   := wBeatOut

  when(wPushOk) {
    wrFill := 0.U
    for (i <- 0 until GRP_BEATS) { wrStrb(i) := 0.U }
    wrAgg := true.B
    when(wqGrpLeft === 1.U) {
      wqValid := false.B                      // 本笔推完；下一拍从 awQ 取下一笔
      wqAddr  := 0.U
    } .otherwise {
      wqAddr    := wqAddr + 8.U               // ★ R2-②：下一组 = **8 个 32bit 字 = 32 B**（不随从口位宽变）
      wqGrpLeft := wqGrpLeft - 1.U
    }
  }

  // B 响应：ddr 侧在"本笔末 beat 被 IP 取走"时推一个带 awid 的 token 过来，**按序**逐笔回
  axi.b.bvalid := doneCdc.io.deq.valid
  axi.b.bid    := doneCdc.io.deq.bits
  axi.b.bresp  := 0.U
  doneCdc.io.deq.ready := axi.b.bready

  // ------------------------------------------------------------------
  // ---- 读路径（axi 域）：AR 入队（多未完成）→ 拆成单 beat AR 命令推入 CDC ----
  // ------------------------------------------------------------------
  class RdBurst extends Bundle { val id = UInt(4.W); val len = UInt(8.W) }
  val rdQ = Module(new Queue(new RdBurst, DEPTH * 2))   // AXI 侧多未完成：AR 先收下，数据慢慢回

  val outR = RegInit(0.U(3.W))
  val maxOutR = RegInit(0.U(3.W))

  val arSplit   = RegInit(false.B)          // 正在把一笔 AR 拆成单 beat 命令
  val arAddr    = Reg(UInt(28.W))
  val arGrpLeft = Reg(UInt(7.W))

  private val arReady = !arSplit && rdQ.io.enq.ready && (outR < DEPTH.U)
  axi.ar.arready := arReady
  rdQ.io.enq.valid := arReady && axi.ar.arvalid
  rdQ.io.enq.bits.id  := axi.ar.arid
  rdQ.io.enq.bits.len := axi.ar.arlen
  when(rdQ.io.enq.fire) {
    arAddr    := axi.ar.araddr(29, 2)
    arGrpLeft := axi.ar.arlen(7, 2) + 1.U            // `ceil((arlen+1)/4)` 笔单 beat DDR 读事务
    arSplit   := true.B
  }

  arCdc.io.enq.valid := arSplit
  arCdc.io.enq.bits.addr := arAddr
  when(arSplit && arCdc.io.enq.ready) {
    when(arGrpLeft === 1.U) { arSplit := false.B }
    .otherwise { arAddr := arAddr + 8.U; arGrpLeft := arGrpLeft - 1.U }   // ★ R2-②
  }

  // R 数据回吐：把 ddr 侧回来的 256bit 字切成 4×64bit 拍，按 AR 顺序逐笔发
  val rdOffset  = RegInit(0.U(log2Ceil(GRP_BEATS).W))   // 当前 256bit 字内已发出的拍
  val rdBeatCnt = RegInit(0.U(8.W))                     // 本笔已发出的拍
  val rdBuf     = Reg(UInt(256.W))

  private val rdNew = rdOffset === 0.U
  axi.r.rid    := rdQ.io.deq.bits.id
  axi.r.rresp  := 0.U
  // 真 FIFO 口（`valid`/`bits` 稳定）⇒ 偏移 0 直接组合取新字，**不需要**改前的 rFresh 标志
  axi.r.rvalid := rdQ.io.deq.valid && (rdOffset =/= 0.U || rCdc.io.deq.valid)
  axi.r.rlast  := rdBeatCnt === rdQ.io.deq.bits.len
  axi.r.rdata  := (Mux(rdNew, rCdc.io.deq.bits, rdBuf) >> (rdOffset * AXI_BITS.U))((AXI_BITS - 1), 0)
  rCdc.io.deq.ready := rdNew && axi.r.rvalid && axi.r.rready
  when(rdNew && axi.r.rvalid && axi.r.rready) { rdBuf := rCdc.io.deq.bits }

  private val rFire = axi.r.rvalid && axi.r.rready
  rdQ.io.deq.ready := false.B
  when(rFire) {
    when(rdBeatCnt === rdQ.io.deq.bits.len) {     // 本笔最后一拍
      rdQ.io.deq.ready := true.B
      rdOffset  := 0.U
      rdBeatCnt := 0.U
    } .otherwise {
      rdBeatCnt := rdBeatCnt + 1.U
      when(rdOffset === (GRP_BEATS - 1).U) { rdOffset := 0.U } .otherwise { rdOffset := rdOffset + 1.U }
    }
  }

  val arAcc   = axi.ar.arvalid && axi.ar.arready
  val rlFire  = axi.r.rvalid && axi.r.rready && axi.r.rlast
  outR := outR + Mux(arAcc, 1.U, 0.U) - Mux(rlFire, 1.U, 0.U)
  when(outR > maxOutR) { maxOutR := outR }

  io.dbgOutW    := outW
  io.dbgOutR    := outR
  io.dbgMaxOutW := maxOutW
  io.dbgMaxOutR := maxOutR

  // ==================== ddr_clk 域: 简化 AXI master ====================
  // ---- 写：AW 队列非空就发一笔单 beat 事务（不变式：AW 队列占用 ≤ W 队列占用 ⇒ W 数据必已在）----
  io.ddrAwAddr  := awCdc.io.deq.bits.addr
  io.ddrAwLen   := 0.U          // ★ R2-③：一笔 DDR 事务只发 1 个 256bit beat
  io.ddrAwValid := awCdc.io.deq.valid
  awCdc.io.deq.ready := awCdc.io.deq.valid && io.ddrAwReady
  private val ddrAwFire = io.ddrAwValid && io.ddrAwReady

  // "IP 还有几笔 AW 没配到 W"（≡ 模型侧 AW 队列长度）—— W 通道没有 wvalid，靠它兜住时序
  val ipWrPend = withClockAndReset(io.ddr_clk, !io.ddr_rstn) { RegInit(0.U(4.W)) }
  private val wTake = io.ddrWReady && wCdc.io.deq.valid && (ipWrPend =/= 0.U)
  wCdc.io.deq.ready := wTake
  io.ddrWData := wCdc.io.deq.bits.data
  io.ddrWStrb := wCdc.io.deq.bits.strb
  ipWrPend := ipWrPend + Mux(ddrAwFire, 1.U, 0.U) - Mux(wTake, 1.U, 0.U)

  // 写完成 token：本笔末 beat 被 IP 取走 ⇒ 带 awid 过桥（axi 侧据此回 B，**按序恰一次**）
  doneCdc.io.enq.valid := wTake && wCdc.io.deq.bits.last
  doneCdc.io.enq.bits  := wCdc.io.deq.bits.id

  // ---- 读：AR 队列非空 + "R 一定收得下" 才发 ----
  // ⚠️ DDR3 IP 的 R 通道**没有 rready**（一拍收不下就丢）⇒ 用信用兜：在飞的 AR 数 + ddr 侧 R 队列
  //    占用 ≤ DEPTH，保证每一拍回来的 R 都有地方落（多了就是静默丢数据 + 后续全错）。
  val inflightR = withClockAndReset(io.ddr_clk, !io.ddr_rstn) { RegInit(0.U(4.W)) }
  private val rFree = DEPTH.U - rCdc.io.sOcc
  private val arGo  = arCdc.io.deq.valid && (inflightR < rFree)
  io.ddrArAddr  := arCdc.io.deq.bits.addr
  io.ddrArLen   := 0.U          // ★ R2-③
  io.ddrArValid := arGo
  arCdc.io.deq.ready := arGo && io.ddrArReady
  private val ddrArFire = io.ddrArValid && io.ddrArReady

  rCdc.io.enq.valid := io.ddrRValid
  rCdc.io.enq.bits  := io.ddrRData
  private val rBeat = io.ddrRValid && rCdc.io.enq.ready
  inflightR := inflightR + Mux(ddrArFire, 1.U, 0.U) - Mux(rBeat, 1.U, 0.U)

  dontTouch(io.ddrAwAddr)
  dontTouch(io.ddrArAddr)
}

object DDR3Bridge {
  def apply() = Module(new DDR3Bridge)

  // ===================== V1 单元测试的网表生成入口 =====================
  // 用法（Windows）：java -cp NaxMiniGlue.jar DDR3Bridge [输出目录]
  //   ⇒ <输出目录>/DDR3Bridge.v（默认 build_ddr/），供 `sim/ddr3bridge/run_unit.sh` 用
  //     verilator `--top-module DDR3Bridge` 装配 AXI 级单元装置
  //     （装置源码 `sim/ddr3bridge/tb_ddrbridge.cpp`；判据见其文件头）。
  // firtool 选项与 `src/NaxMiniGlueMain.scala` 完全一致（PDS 已验证过的那一组）。
  // 注意：这个入口只依赖本模块，**不改变任何 RTL**（`object` 里的 main 不进网表）。
  def main(args: Array[String]): Unit = {
    val outDir = if (args.nonEmpty) args(0) else "build_ddr"
    // ⚠️ `-td` 与 `-o` **必须落在不同路径**：firtool 会在 `-td` 里先建一个默认名的空占位文件，
    //    若 `-o` 与它同名同路径，产物会是 **0 字节**。这里 `-td` 用 `<outDir>/work/`。
    val opts = Array(
      "-disable-all-randomization",
      "-strip-debug-info",
      "-strip-fir-debug-info",
      "-O=release",
      "--ignore-read-enable-mem",
      "--lower-memories",
      "--lowering-options=noAlwaysComb, disallowPackedArrays, disallowLocalVariables, disallowMuxInlining, disallowExpressionInliningInPorts",
      s"-o=$outDir/DDR3Bridge.v"
    )
    println(s"Generating DDR3Bridge (unit-test netlist) -> $outDir/DDR3Bridge.v")
    (new ChiselStage).execute(
      Array("--target", "verilog", "-td", s"$outDir/work/"),
      Seq(ChiselGeneratorAnnotation(() => new DDR3Bridge)) ++
        opts.map(FirtoolOption(_))
    )
    val f = new java.io.File(s"$outDir/DDR3Bridge.v")
    require(f.isFile && f.length > 0, s"生成失败：$outDir/DDR3Bridge.v 不存在或是 0 字节")
  }
}
