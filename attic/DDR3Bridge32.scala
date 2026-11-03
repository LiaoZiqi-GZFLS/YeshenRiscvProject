// ============================================================================
// 归档（留档，不参与编译）：`DDR3Bridge` 的 **32bit AXI 从口**版本。
//   * 冻结于 2026-09-30（T16-V1：把交付路径内存口改成原生 64bit 之前的那一份），
//     与当时的 `src/soc/DDR3Bridge.scala` **逐字节相同**。
//   * 被替换的原因：T12/T13 已证取指字错位的真因是内存口 32bit（上游 TL hub 64bit→32bit 的
//     WidthAdapter）；交付改为原生 64bit，唯一那次宽度转换下沉到本桥内部的 32B 聚合。
//   * 本目录（`attic/`）在 `src/` 之外 ⇒ scala-cli 不会编译它（不会与 64bit 版同时进编译）。
//   * 它的单元装置判据（32bit 阳性）见 `docs/探针记录.md` 的「Task 16 V1」一节：
//     同一份 `sim/ddr3bridge/tb_ddrbridge.cpp`（`-DAXI_W=32`）7 个用例全绿；
//     配套 64bit 版用 `-DAXI_W=64`，判据相同。
// ============================================================================
import chisel3._
import chisel3.util._
// ⚠️ `import chisel3.util._` 会把名字 `circt` 解析到 `chisel3.util.circt` ⇒ 必须用 `_root_.` 前缀
//    （`NaxMiniGlueMain.scala` 只 import `chisel3._`，所以它那边的 `circt.stage` 没有这个问题）
import _root_.circt.stage.{ChiselStage, FirtoolOption}
import chisel3.stage.ChiselGeneratorAnnotation

// ===================== AXI4 → DDR3 简化 AXI 异步桥 =====================
// CPU 侧 (axi_clk 域, 80MHz): 完整 AXI4 slave (32bit 数据, 字节地址)
// DDR 侧 (ddr_clk 域, 125MHz): 紫光同创 DDR3 IP 简化 AXI (256bit 数据, word地址)
//
// 简化 AXI 协议特性（紫光同创 DDR3 IP 用户接口）:
// - W 通道无 wvalid，wready 高即采样 → 数据必须始终有效
// - AW 握手后连续发 awlen+1 个 256bit beat
//
// 设计约束:
// 1. **一笔 DDR 事务只发 1 个 256bit beat**（`ddrAwLen`/`ddrArLen` 恒 0）。理由：DDR3 IP 的 W 通道
//    没有 wvalid（wready 高即采样），而两个 beat 之间必须过一次跨域握手（`wPipe`），无法保证背靠背
//    连续；R 通道同理没有 rready，多 beat 突发会顶掉 CDC 管道。所以一笔 AXI 突发被拆成
//    `groups = ceil((awlen+1)/8)` 笔单 beat 的 DDR 事务，**每笔的地址递进 8 个 32bit 字（=32B）**。
//    例：Dcache 64B 行回写 = 16 拍 AXI = 2 笔 DDR 事务；ICache/Dcache 行填充 = arlen 15 = 2 笔。
//    ⚠️ 2026-09-22：原实现把"每笔 AW 恰好 1 个 DDR beat"写死（不看 awlen、固定攒 8 拍、`ddrAwLen := 0`
//    且不做地址递进）⇒ 64B 行回写只有前 32B 落地、64B 行填充永远等不到第二个 beat（板级挂死）。
// 2. 突发首地址 32 字节对齐；AXI 的 len 上限 255 ⇒ 最多 32 组
// 3. 单 outstanding 事务
// 4. **CDC 管道的 `deq.valid` 是电平，不是"新数据"脉冲**：一份数据挂上管道后要等源域看到 ack 才撤 req，
//    期间 valid 一直为高 ⇒ 同一条管上连续取多份的多 beat 事务，必须用"本次呈现已取用"标志
//    （取用置 1、valid 落清零）来区分新旧呈现，否则状态机回到等待态会**再取一次同一份**
//    （实测：64B 回写的后 32B 写成了前 32B 的内容）。见 ddr_clk 域的 `*ItemTaken`。
// 5. **axi 侧的 CDC 端复位是低有效**（`CDCPipe` 内部用 `!io.sRstn`）：本模块隐式 `reset` 是高有效，
//    必须写 `!reset.asBool`；写成 `reset.asBool` 会让 axi 侧那几个端**在系统离开复位后永久停在复位**
//    （整块桥死掉，实测症状：16 拍 AXI 写全部被 sClk 侧收下、DDR 侧一笔事务都没有）。ddr 侧接的
//    `io.ddr_rstn` 板级给的是 `ddr_init_done`（1 = 初始化完成 = 可跑），对低有效口恰好正确。
//
// 跨时钟域 (CDCPipe 4相电平握手):
// - AW 命令: axi_clk → ddr_clk
// - 写数据 256bit: axi_clk → ddr_clk (axi 域聚合 8×32bit)
// - AR 命令: axi_clk → ddr_clk
// - 读数据 256bit: ddr_clk → axi_clk (axi 域拆分 8×32bit)
// - 写完成 token: ddr_clk → axi_clk (生成 B 响应)
class DDR3Bridge extends Module {
  val io = IO(new Bundle {
    val ddr_clk  = Input(Clock())
    val ddr_rstn = Input(Bool())

    // SoC 侧: AXI4 slave（本模块时钟域）
    val axi = Flipped(new AXIIO)

    // DDR3 IP 侧: 简化 AXI master（ddr_clk 域）
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
  })

  // ==================== 跨域管道 ====================
  class AwCmd extends Bundle {
    val addr   = UInt(28.W)  // 首 beat 的 word 地址（32bit 字地址）
    // 本笔 AXI AW 要拆成几个 32B DDR beat：`ceil((awlen+1)/8)` = `awlen(7,3) + 1`。
    // 6 bit ⇒ 覆盖 AXI 的 awlen 上限（255 ⇒ 32 组）。
    val groups = UInt(6.W)
  }
  class WrData extends Bundle {
    val data = UInt(256.W)
    val strb = UInt(32.W)
  }
  class ArCmd extends Bundle {
    val addr  = UInt(28.W)
    // 本笔 AR 要拆成几个 32B DDR beat：`ceil((arlen+1)/8)` = `arlen(7,3) + 1`。
    val beats = UInt(6.W)
  }

  val awPipe = Module(new CDCPipe(new AwCmd))
  val wPipe  = Module(new CDCPipe(new WrData))
  val arPipe = Module(new CDCPipe(new ArCmd))
  val rPipe  = Module(new CDCPipe(UInt(256.W)))
  val donePipe = Module(new CDCPipe(UInt(1.W)))

  // 连接时钟
  // ⚠️ 复位极性（2026-09-22 实测）：`CDCPipe` 的 `sRstn`/`dRstn` 是**低有效**（内部用
  //    `withClockAndReset(..., !io.sRstn)`），而本模块隐式复位 `reset` 是**高有效**。
  //    原写法 `sRstn := reset.asBool` / `dRstn := reset.asBool` 把高有效信号灌进低有效口 ⇒
  //    **系统一离开复位，这两个端口的 CDC 就永久处在复位里**（`sValid` 恒 0 / `dPending` 恒 0），
  //    于是 AW/W/AR 一个都过不去、R/B 也一个都回不来 —— 整块桥在板上是死的。
  //    ddr 侧的 `io.ddr_rstn` 是**高有效**（板级接 `ddr_init_done`，1 = DDR 初始化完成 = 可跑），
  //    而低有效口正好要它取反 ⇒ `dRstn := io.ddr_rstn` 这一侧本来就是对的，只有 axi 侧要取反。
  //    证据：`sim/tb_ddr.cpp`（本模块此前**零仿真覆盖**）修复前 aw/ar 恒 0、修后全绿。
  awPipe.io.sClk := clock; awPipe.io.sRstn := !reset.asBool
  awPipe.io.dClk := io.ddr_clk; awPipe.io.dRstn := io.ddr_rstn
  wPipe.io.sClk := clock; wPipe.io.sRstn := !reset.asBool
  wPipe.io.dClk := io.ddr_clk; wPipe.io.dRstn := io.ddr_rstn
  arPipe.io.sClk := clock; arPipe.io.sRstn := !reset.asBool
  arPipe.io.dClk := io.ddr_clk; arPipe.io.dRstn := io.ddr_rstn
  rPipe.io.sClk := io.ddr_clk; rPipe.io.sRstn := io.ddr_rstn
  rPipe.io.dClk := clock; rPipe.io.dRstn := !reset.asBool
  donePipe.io.sClk := io.ddr_clk; donePipe.io.sRstn := io.ddr_rstn
  donePipe.io.dClk := clock; donePipe.io.dRstn := !reset.asBool

  // ==================== axi_clk 域: AXI4 slave ====================
  val axi = io.axi

  // ---- 写路径（一笔 AW → `groups` 个 32B beat） ----
  // sWrAgg：按"本组还差几拍"收 W；sWrEmit：把缓冲作为一个 32B DDR beat 发射；sWrWait：等 B（**只在末组之后**）。
  val sWrIdle :: sWrAgg :: sWrEmit :: sWrWait :: Nil = Enum(4)
  val wrState = RegInit(sWrIdle)

  val wrAwId    = Reg(UInt(4.W))
  val wrLeft    = Reg(UInt(9.W))   // 本笔 AW **剩余**的 AXI 拍数（含本组未收的）
  val wrFill    = Reg(UInt(4.W))   // 本组已收 32bit 数（0..8）

  val wrBuf    = Reg(Vec(8, UInt(32.W)))
  val wrStrbBuf = Reg(Vec(8, UInt(4.W)))

  axi.aw.awready := wrState === sWrIdle
  axi.w.wready := wrState === sWrAgg
  axi.b.bvalid := wrState === sWrWait && donePipe.io.deq.valid
  axi.b.bid := wrAwId
  axi.b.bresp := 0.U
  donePipe.io.deq.ready := wrState === sWrWait && axi.b.bready

  // 发射 256bit（缓冲满时，恰好 1 个 DDR beat）
  val wrEmit = Wire(new WrData)
  wrEmit.data := Cat(wrBuf(7), wrBuf(6), wrBuf(5), wrBuf(4), wrBuf(3), wrBuf(2), wrBuf(1), wrBuf(0))
  wrEmit.strb := Cat(wrStrbBuf(7), wrStrbBuf(6), wrStrbBuf(5), wrStrbBuf(4), wrStrbBuf(3), wrStrbBuf(2), wrStrbBuf(1), wrStrbBuf(0))
  wPipe.io.enq.bits := wrEmit
  wPipe.io.enq.valid := wrState === sWrEmit

  awPipe.io.enq.bits.addr := axi.aw.awaddr(29, 2)
  // `ceil((awlen+1)/8)` = `awlen(7,3) + 1`（**不是** `ceil(awlen/8)`：awlen=0 单拍也要 1 组）
  awPipe.io.enq.bits.groups := axi.aw.awlen(7, 3) + 1.U
  awPipe.io.enq.valid := wrState === sWrIdle && axi.aw.awvalid

  switch(wrState) {
    is(sWrIdle) {
      when(axi.aw.awvalid && axi.aw.awready) {
        wrAwId := axi.aw.awid
        wrLeft := axi.aw.awlen + 1.U
        wrFill := 0.U
        for (i <- 0 until 8) { wrStrbBuf(i) := 0.U }   // 新事务：strobes 清零（数据由 strb 表达）
        wrState := sWrAgg
      }
    }
    is(sWrAgg) {
      when(axi.w.wvalid && axi.w.wready) {
        wrBuf(wrFill) := axi.w.wdata
        wrStrbBuf(wrFill) := axi.w.wstrb
        wrFill := wrFill + 1.U
        wrLeft := wrLeft - 1.U
        // 本组收满（8 拍）或本笔收完 ⇒ 发射这一组
        when(wrFill === 7.U || wrLeft === 1.U) { wrState := sWrEmit }
      }
    }
    is(sWrEmit) {
      when(wPipe.io.enq.ready) {
        when(wrLeft === 0.U) {
          wrState := sWrWait
        }.otherwise {
          wrFill := 0.U
          for (i <- 0 until 8) { wrStrbBuf(i) := 0.U }  // 下一组：strobes 清零（残组未用 lane 不下发）
          wrState := sWrAgg
        }
      }
    }
    is(sWrWait) {
      when(donePipe.io.deq.valid && axi.b.bready) {
        wrState := sWrIdle
      }
    }
  }

  // ---- 读路径（一笔 AR → `beats` 个 32B beat） ----
  val sRdIdle :: sRdData :: Nil = Enum(2)
  val rdState = RegInit(sRdIdle)

  val rdArId   = Reg(UInt(4.W))
  val rdArLen  = Reg(UInt(8.W))
  val rdBuf    = Reg(UInt(256.W))
  val rdOffset = Reg(UInt(3.W))
  val rdBeatCnt = Reg(UInt(8.W))

  axi.ar.arready := rdState === sRdIdle
  axi.r.rvalid := rdState === sRdData && (rdOffset =/= 0.U || rPipe.io.deq.valid)
  axi.r.rid := rdArId
  axi.r.rresp := 0.U
  // ⚠️ 偏移 0 的那一拍必须**组合地**取管道里的新数据：`rdBuf` 在**同一拍**才被加载
  //    （寄存器更新落在下一拍），若只看 rdBuf，这一拍会送出**上一组**的第 0 个字
  //    （实测：64B 读的第 0/8 拍各错一个字；单拍读更是整拍都是旧值）。
  private val rdChunk = Mux(rdOffset === 0.U && rPipe.io.deq.valid, rPipe.io.deq.bits, rdBuf)
  axi.r.rdata := (rdChunk >> (rdOffset * 32.U))(31, 0)
  axi.r.rlast := rdState === sRdData && rdBeatCnt === rdArLen

  arPipe.io.enq.bits.addr := axi.ar.araddr(29, 2)
  arPipe.io.enq.bits.beats := axi.ar.arlen(7, 3) + 1.U
  arPipe.io.enq.valid := rdState === sRdIdle && axi.ar.arvalid

  // 读侧**不需要**"已取用"标志（与写侧的 `wItemTaken` 对照）：这里只在 `rdOffset === 0` 取一次，
  // 而两次"偏移 0"之间隔着整组 8 拍；且下一份 rPipe 数据的产生被 `io.ddrArValid && rPipe.io.enq.ready`
  // 卡住（必须先等上一份呈现撤干净、再发 AR、再等 DDR 读延迟）⇒ 回到偏移 0 时管道**必然是空的**，
  // 不可能把上一份呈现当成新数据取用。
  rPipe.io.deq.ready := rdState === sRdData && rdOffset === 0.U && axi.r.rvalid && axi.r.rready

  switch(rdState) {
    is(sRdIdle) {
      when(axi.ar.arvalid && axi.ar.arready) {
        rdArId := axi.ar.arid
        rdArLen := axi.ar.arlen
        rdOffset := 0.U
        rdBeatCnt := 0.U
        rdState := sRdData
      }
    }
    is(sRdData) {
      when(rdOffset === 0.U && rPipe.io.deq.valid && axi.r.rvalid && axi.r.rready) {
        rdBuf := rPipe.io.deq.bits
      }
      when(axi.r.rvalid && axi.r.rready) {
        when(rdOffset === 7.U) {
          rdOffset := 0.U
        }.otherwise {
          rdOffset := rdOffset + 1.U
        }
        rdBeatCnt := rdBeatCnt + 1.U
        when(rdBeatCnt === rdArLen) {
          rdState := sRdIdle
        }
      }
    }
  }

  // ==================== ddr_clk 域: 简化 AXI master ====================
  val ddrAwAddr = withClockAndReset(io.ddr_clk, !io.ddr_rstn) { Reg(UInt(28.W)) }
  // 0=idle(等 AW + 本笔首组 W) 1=aw 2=wdata 3=done 4=等下一组 W
  val ddrWrState = withClockAndReset(io.ddr_clk, !io.ddr_rstn) { RegInit(0.U(3.W)) }
  val ddrWrLeft = withClockAndReset(io.ddr_clk, !io.ddr_rstn) { Reg(UInt(6.W)) }  // 本笔 AW 还剩几组

  val ddrArAddr = withClockAndReset(io.ddr_clk, !io.ddr_rstn) { Reg(UInt(28.W)) }
  val ddrRdState = withClockAndReset(io.ddr_clk, !io.ddr_rstn) { RegInit(0.U(2.W)) }
  // 0=idle, 1=ar, 2=rdata
  val ddrRdLeft = withClockAndReset(io.ddr_clk, !io.ddr_rstn) { Reg(UInt(6.W)) }  // 本笔 AR 还剩几拍

  // 写数据寄存器（AW 前预取，保证 W 通道始终有效）
  val wDataReg = withClockAndReset(io.ddr_clk, !io.ddr_rstn) { Reg(new WrData) }

  // 队列 deq 侧（ddr 域）
  val awDeqBits = withClockAndReset(io.ddr_clk, !io.ddr_rstn) { Reg(new AwCmd) }
  val awDeqValid = withClockAndReset(io.ddr_clk, !io.ddr_rstn) { RegInit(false.B) }
  val awDeqReady = Wire(Bool())
  awPipe.io.deq.ready := awDeqReady

  val wDeqBits = withClockAndReset(io.ddr_clk, !io.ddr_rstn) { Reg(new WrData) }
  val wDeqValid = withClockAndReset(io.ddr_clk, !io.ddr_rstn) { RegInit(false.B) }
  val wDeqReady = Wire(Bool())
  wPipe.io.deq.ready := wDeqReady

  val arDeqBits = withClockAndReset(io.ddr_clk, !io.ddr_rstn) { Reg(new ArCmd) }
  val arDeqValid = withClockAndReset(io.ddr_clk, !io.ddr_rstn) { RegInit(false.B) }
  val arDeqReady = Wire(Bool())
  arPipe.io.deq.ready := arDeqReady

  // ---- "这一份呈现有没有被取用过"（见文件头约束 4）----
  // `CDCPipe` 的 `deq.valid` 是**电平**：数据挂上管道后，要等源域看到 ack 才撤 req，
  // 期间 valid 一直是高 ⇒ "valid 为高"≠"来了一份新数据"。同一条管上连续取多份（多 beat 事务）
  // 时，若只用 valid 判定，状态机回到等待态会**重复取到同一份**（实测：64B 回写把后 32B 写成了
  // 前 32B 的内容）。所以每个消费者各带一个"本次呈现已取用"标志，取用置 1、呈现撤销（valid 落）清零。
  val awItemTaken = withClockAndReset(io.ddr_clk, !io.ddr_rstn) { RegInit(false.B) }
  val wItemTaken  = withClockAndReset(io.ddr_clk, !io.ddr_rstn) { RegInit(false.B) }
  val arItemTaken = withClockAndReset(io.ddr_clk, !io.ddr_rstn) { RegInit(false.B) }

  // 写状态机：一笔 AXI AW = `groups` 笔单 beat DDR 事务（每笔地址 +8 字，B 只在末组之后回）
  io.ddrAwAddr := ddrAwAddr
  io.ddrAwLen := 0.U          // 单 beat（理由见文件头约束 1）
  io.ddrAwValid := ddrWrState === 1.U
  io.ddrWData := wDataReg.data
  io.ddrWStrb := wDataReg.strb

  val ddrAwFire = io.ddrAwValid && io.ddrAwReady

  withClockAndReset(io.ddr_clk, !io.ddr_rstn) {
    // 呈现撤销（源域看到 ack 后撤 req）⇒ 允许取下一份
    when(!awPipe.io.deq.valid) { awItemTaken := false.B }
    when(!wPipe.io.deq.valid)  { wItemTaken  := false.B }
    when(!arPipe.io.deq.valid) { arItemTaken := false.B }

    awDeqReady := ddrWrState === 0.U && !awItemTaken
    // 只在"能收下这一组"时取 WrData（idle 起步 / 上一组已 beat 完成）
    wDeqReady := (ddrWrState === 0.U || ddrWrState === 4.U) && !wItemTaken
    arDeqReady := ddrRdState === 0.U && !arItemTaken

    when(awPipe.io.deq.valid && awDeqReady) {
      awDeqBits := awPipe.io.deq.bits
      awDeqValid := true.B
      awItemTaken := true.B
    }

    when(wPipe.io.deq.valid && wDeqReady) {
      wDeqBits := wPipe.io.deq.bits
      wDeqValid := true.B
      wItemTaken := true.B
    }

    when(arPipe.io.deq.valid && arDeqReady) {
      arDeqBits := arPipe.io.deq.bits
      arDeqValid := true.B
      arItemTaken := true.B
    }

    switch(ddrWrState) {
      is(0.U) {
        // 等命令和数据同时就绪；两者都在这里被"用掉"（AW 命令描述整笔，W 只是首组）
        when(awDeqValid && wDeqValid) {
          ddrAwAddr := awDeqBits.addr
          ddrWrLeft := awDeqBits.groups
          wDataReg := wDeqBits
          awDeqValid := false.B
          wDeqValid := false.B
          ddrWrState := 1.U
        }
      }
      is(1.U) {
        when(ddrAwFire) {
          ddrWrState := 2.U
        }
      }
      is(2.U) {
        // 单 beat：等 wready 采样后本组完成
        when(io.ddrWReady) {
          when(ddrWrLeft === 1.U) {
            ddrWrState := 3.U
          }.otherwise {
            ddrWrLeft := ddrWrLeft - 1.U
            ddrAwAddr := ddrAwAddr + 8.U   // 下一组：下一个 32B
            ddrWrState := 4.U
          }
        }
      }
      is(4.U) {
        // 等下一组 W 数据（由 sClk 侧在本组 beat 发完后才推进）
        when(wDeqValid) {
          wDataReg := wDeqBits
          wDeqValid := false.B
          ddrWrState := 1.U
        }
      }
      is(3.U) {
        // done token 发出后回 idle
        when(donePipe.io.enq.ready) {
          ddrWrState := 0.U
        }
      }
    }
  }

  // 写完成 token
  val wrDonePulse = withClockAndReset(io.ddr_clk, !io.ddr_rstn) { Wire(Bool()) }
  wrDonePulse := ddrWrState === 3.U
  donePipe.io.enq.valid := wrDonePulse
  donePipe.io.enq.bits := 0.U

  // 读状态机：一笔 AXI AR = `beats` 笔单 beat DDR 事务（每笔地址 +8 字）
  // ⚠️ AR 必须**等 rPipe 空闲**才发：DDR3 IP 的 R 通道没有 rready，beat 回来时管道必须收得下，
  //    否则那一拍直接丢（多 beat 事务下 = 行的后半段永远是旧值，且不会报错）。dClk 是管道的
  //    唯一生产者，所以"发 AR 前 enq.ready 为高"就保证 beat 回来时管道仍空。
  io.ddrArAddr := ddrArAddr
  io.ddrArLen := 0.U           // 单 beat（理由见文件头约束 1）
  io.ddrArValid := ddrRdState === 1.U && rPipe.io.enq.ready

  val ddrArFire = io.ddrArValid && io.ddrArReady

  val rEnqValid = withClockAndReset(io.ddr_clk, !io.ddr_rstn) { Wire(Bool()) }
  rEnqValid := ddrRdState === 2.U && io.ddrRValid
  rPipe.io.enq.valid := rEnqValid
  rPipe.io.enq.bits := io.ddrRData

  withClockAndReset(io.ddr_clk, !io.ddr_rstn) {
    arDeqReady := ddrRdState === 0.U

    when(arPipe.io.deq.valid && arDeqReady) {
      arDeqBits := arPipe.io.deq.bits
      arDeqValid := true.B
    }

    switch(ddrRdState) {
      is(0.U) {
        when(arDeqValid) {
          ddrArAddr := arDeqBits.addr
          ddrRdLeft := arDeqBits.beats
          arDeqValid := false.B
          ddrRdState := 1.U
        }
      }
      is(1.U) {
        when(ddrArFire) {
          ddrRdState := 2.U
        }
      }
      is(2.U) {
        // 单 beat: rvalid（len=0 时同时是 rlast）即完成
        when(io.ddrRValid && io.ddrRLast) {
          when(ddrRdLeft === 1.U) {
            ddrRdState := 0.U
          }.otherwise {
            ddrRdLeft := ddrRdLeft - 1.U
            ddrArAddr := ddrArAddr + 8.U   // 下一拍：下一个 32B
            ddrRdState := 1.U
          }
        }
      }
    }
  }

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
    //    若 `-o` 与它同名同路径，产物会是 **0 字节**（实测：`rtl/NaxMiniGlue.v` 100KB 而
    //    `build_glue/NaxMiniGlue.v` 0 字节，就是这个机制）。这里 `-td` 用 `<outDir>/work/`。
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
