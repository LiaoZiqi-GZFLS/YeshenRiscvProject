import chisel3._
import chisel3.util._

// ===================== CLINT-Lite（SiFive 布局）=====================
// ⚠️ 本文件从 `NaxYeshenSoC/src/peripheral/CLINT.scala` 复制后**就地改造**（VexiiRiscv 迁移）：
//    新核（VexiiRiscv）**没有**内置 CLINT/PLIC ⇒ 时基与中断由本模块 + PlicAlite 提供。
//
// 与原版的差异（只有这三处，寄存器偏移**一字未动**）：
//   ① **本模块 OWN 时基**：内部 64bit 自由运行 `mtime`（每拍 +1，soc_clk = 100MHz），
//      经 `rdtime_o` 导出给核的 `PrivilegedPlugin_logic_rdtime`。原来"mtime 由核导出"的
//      `mtime_i` 输入**删除**（新核不导出 mtime，只吃 rdtime）。
//   ② 新增 **MSWI**（machine software interrupt）寄存器：偏移 `0x0000`，bit0 经 `msip_o` 输出。
//   ③ `mtip_o = (mtime >= mtimecmp)` 组合电平，语义不变；`mtimecmp` 复位全 1（不变）。
//
// 偏移与 Linux `timer-clint.c` / OpenSBI 的硬编码**逐字一致**：
//   MSIP=+0x0000、MTIMECMP=+0x4000、MTIME=+0xBFF8。
// 地址宽 16 位（UART/GPIO 的 AXILiteIO 只有 5 位，放不下 0xBFF8）。
class ClintAXILiteIO extends Bundle {
  val awaddr  = Input(UInt(16.W))
  val awvalid = Input(Bool())
  val awready = Output(Bool())
  val wdata   = Input(UInt(32.W))
  val wstrb   = Input(UInt(4.W))
  val wvalid  = Input(Bool())
  val wready  = Output(Bool())
  val bresp   = Output(UInt(2.W))
  val bvalid  = Output(Bool())
  val bready  = Input(Bool())
  val araddr  = Input(UInt(16.W))
  val arvalid = Input(Bool())
  val arready = Output(Bool())
  val rdata   = Output(UInt(32.W))
  val rresp   = Output(UInt(2.W))
  val rvalid  = Output(Bool())
  val rready  = Input(Bool())
}

class ClintAliteIO extends Bundle {
  val axi      = new ClintAXILiteIO
  val rdtime_o = Output(UInt(64.W))   // 自由运行 mtime ⇒ 核的 rdtime（rdtime/rdcycle 时基）
  val mtip_o   = Output(Bool())       // mtime >= mtimecmp（组合电平）⇒ M-timer 中断
  val msip_o   = Output(Bool())       // MSWI 寄存器 bit0 ⇒ M-software 中断
}

class ClintAlite extends Module {
  override def desiredName: String = "ClintAlite"
  val io = IO(new ClintAliteIO)

  private val MSIP        = 0x0000.U(16.W)
  private val MTIMECMP_LO = 0x4000.U(16.W)
  private val MTIMECMP_HI = 0x4004.U(16.W)
  private val MTIME_LO    = 0xBFF8.U(16.W)
  private val MTIME_HI    = 0xBFFC.U(16.W)

  private val cmpLo = RegInit("hffffffff".U(32.W))
  private val cmpHi = RegInit("hffffffff".U(32.W))
  private val msip  = RegInit(0.U(32.W))

  // ===================== 自有 64bit 自由运行时基（@100MHz，每拍 +1）=====================
  private val mtime = RegInit(0.U(64.W))
  mtime := mtime + 1.U

  io.rdtime_o := mtime
  io.mtip_o   := mtime >= Cat(cmpHi, cmpLo)
  io.msip_o   := msip(0)

  // ===================== 写通道 =====================
  // AW/W 可能同拍（单元 tb）也可能分拍（SoC 的 MMIO FSM 是 sAW→sW），用两个 pend 位解耦。
  private val bValid = RegInit(false.B)
  private val awPend = RegInit(false.B)
  private val awReg  = RegInit(0.U(16.W))
  private val wPend  = RegInit(false.B)
  private val wData  = RegInit(0.U(32.W))

  io.axi.awready := !bValid
  io.axi.wready  := !bValid
  io.axi.bresp   := 0.U     // OKAY（MMIO.scala 不看 bresp，留作将来给 PLIC/桥做错误应答）
  io.axi.bvalid  := bValid

  when(io.axi.awvalid && io.axi.awready) { awPend := true.B; awReg := io.axi.awaddr }
  when(io.axi.wvalid  && io.axi.wready)  { wPend  := true.B; wData := io.axi.wdata  }

  when(awPend && wPend) {
    switch(awReg) {
      is(MSIP)        { msip  := wData }
      is(MTIMECMP_LO) { cmpLo := wData }
      is(MTIMECMP_HI) { cmpHi := wData }
      // mtime 只读；窗口内其它偏移一律忽略，但**照样应答**（否则一次误访问会把 MMIO FSM 卡死）
    }
    awPend := false.B
    wPend  := false.B
    bValid := true.B
  }
  when(io.axi.bready && bValid) { bValid := false.B }

  // ===================== 读通道 =====================
  // ⚠️ 与 CLINT/UART/GPIO/PLIC 同一相位：AR 拍锁存解码数据 ⇒ 下一拍 rvalid 采样 rdata。
  private val rValid = RegInit(false.B)
  private val rData  = RegInit(0.U(32.W))
  io.axi.arready := true.B
  io.axi.rvalid  := rValid
  io.axi.rdata   := rData
  io.axi.rresp   := 0.U

  when(io.axi.arvalid && io.axi.arready) {
    rData := MuxLookup(io.axi.araddr, 0.U(32.W))(Seq(
      MSIP        -> msip,
      MTIMECMP_LO -> cmpLo,
      MTIMECMP_HI -> cmpHi,
      MTIME_LO    -> mtime(31, 0),
      MTIME_HI    -> mtime(63, 32)
    ))
    rValid := true.B
  }.elsewhen(io.axi.rready) {
    rValid := false.B
  }
}
