import chisel3._
import chisel3.util._

// ===================== GPIO 寄存器地址 =====================
object GPIORegs {
  val DATA_IN    = 0x00.U(5.W)  // 数据输入寄存器
  val DATA_OUT   = 0x04.U(5.W)  // 数据输出寄存器
  val DIRECTION  = 0x08.U(5.W)  // 方向寄存器（0=输入，1=输出）
  val INT_ENABLE = 0x0C.U(5.W)  // 中断使能寄存器
  val INT_STATUS = 0x10.U(5.W)  // 中断状态寄存器
  val INT_TYPE   = 0x14.U(5.W)  // 中断类型寄存器（0=电平，1=边沿）
  val INT_POLARITY = 0x18.U(5.W) // 中断极性寄存器（0=低电平/下降沿，1=高电平/上升沿）
}

// ===================== GPIO 接口 =====================
class GPIOIO extends Bundle {
  // AXI-Lite 接口
  val axi = new AXILiteIO
  
  // GPIO 物理接口（分离输入输出）
  val gpio_out = Output(UInt(32.W))  // GPIO 输出
  val gpio_in = Input(UInt(32.W))    // GPIO 输入
  val gpio_dir = Output(UInt(32.W)) // GPIO 方向（0=输入，1=输出）
  
  // 中断输出
  val interrupt = Output(Bool())
}

// ===================== GPIO 控制器 =====================
class GPIOController extends Module {
  val io = IO(new GPIOIO)
  
  // 寄存器定义
  val dataInReg = RegInit(0.U(32.W))
  val dataOutReg = RegInit(0.U(32.W))
  val directionReg = RegInit(0.U(32.W))
  val intEnableReg = RegInit(0.U(32.W))
  val intStatusReg = RegInit(0.U(32.W))
  val intTypeReg = RegInit(0.U(32.W))
  val intPolarityReg = RegInit(0.U(32.W))
  
  // 输入采样
  val pinIn = Wire(UInt(32.W))
  pinIn := io.gpio_in
  
  // 输出驱动
  val pinOut = Wire(UInt(32.W))
  pinOut := dataOutReg
  
  // 三态控制
  val pinOe = Wire(UInt(32.W))
  pinOe := directionReg
  
  // 数据输入寄存器更新
  dataInReg := pinIn
  
  // GPIO 输出和方向
  io.gpio_out := pinOut
  io.gpio_dir := pinOe
  
  // 中断检测
  val intDetect = Wire(Vec(32, Bool()))
  
  // 边沿检测寄存器
  val prevDataIn = RegNext(dataInReg, 0.U)
  
  // 使用 Mux 进行中断检测
  for (i <- 0 until 32) {
    intDetect(i) := Mux(intTypeReg(i),
      // 边沿触发
      Mux(intPolarityReg(i),
        dataInReg(i) && !prevDataIn(i),  // 上升沿
        !dataInReg(i) && prevDataIn(i)   // 下降沿
      ),
      // 电平触发
      Mux(intPolarityReg(i),
        dataInReg(i),  // 高电平
        !dataInReg(i)  // 低电平
      )
    )
  }
  
  // 中断状态寄存器更新
  intStatusReg := intStatusReg | intDetect.asUInt
  
  // 中断输出
  io.interrupt := (intStatusReg & intEnableReg).orR
  
  // AXI-Lite 写逻辑
  // ⚠️ T4 修：原来用"1 拍即落"的 `awReady`/`wReady`，而 **SoC 的 MMIO FSM 是 sAW→sW→sB 三拍**
  //    （AW 与 W 分两拍到）⇒ `awReady && wReady` 永不同拍 ⇒ `bValid` 永不拉 ⇒ FSM 卡在 sB
  //    ⇒ 整条 ROB 阻塞（实测：固件在第一次 GPIO 写上挂死、之后一个写回都没有）。
  //    改成 **sticky pend**（与 `CLINT.scala` 同一套写法），并把 `awready/wready` 做成
  //    "上一次还没被 B 消化就不收新的"（`!bValid`）。**UART 是同款缺陷，同修**。
  private val awReady = RegInit(false.B)
  private val wReady = RegInit(false.B)
  val bValid = RegInit(false.B)
  val bResp = RegInit(0.U(2.W))

  // ⚠️ T4 修：原来只有 **4 位**，而 GPIO 寄存器图到 0x18（INT_STATUS=0x10 / INT_TYPE=0x14 /
  //    INT_POLARITY=0x18）⇒ 那些偏移会被**静默截断**成 0x0/0x4/0x8（= DATA_IN/DATA_OUT/DIRECTION）
  //    ⇒ "配边沿模式 + W1C 清中断"根本做不到（而它正是 D1=B 的前提）。UART 的 `BAUD_DIV=0x10`
  //    与新增的 `INT_STATUS=0x14` 同病，一并加宽。
  val awAddr = RegInit(0.U(5.W))
  val wData = RegInit(0.U(32.W))
  val wStrb = RegInit(0.U(4.W))

  // 写地址/数据通道：**锁存到被消费**（sticky），不依赖"同拍"
  when(io.axi.awvalid && io.axi.awready) {
    awReady := true.B
    awAddr := io.axi.awaddr
  }
  when(io.axi.wvalid && io.axi.wready) {
    wReady := true.B
    wData := io.axi.wdata
    wStrb := io.axi.wstrb
  }

  // 写操作执行
  when(awReady && wReady) {
    switch(awAddr) {
      is(GPIORegs.DATA_OUT) {
        dataOutReg := wData
      }
      is(GPIORegs.DIRECTION) {
        directionReg := wData
      }
      is(GPIORegs.INT_ENABLE) {
        intEnableReg := wData
      }
      is(GPIORegs.INT_STATUS) {
        // 写 1 清除中断状态
        intStatusReg := intStatusReg & ~wData
      }
      is(GPIORegs.INT_TYPE) {
        intTypeReg := wData
      }
      is(GPIORegs.INT_POLARITY) {
        intPolarityReg := wData
      }
    }
    bValid := true.B
    bResp := 0.U  // OKAY
    // 消费掉 sticky pend（与 CLINT 同款）
    awReady := false.B
    wReady  := false.B
  }
  
  // 写响应通道
  when(io.axi.bready && bValid) {
    bValid := false.B
  }
  
  // AXI-Lite 读逻辑
  // ⚠️ 相位必须与 CLINT/PLIC 完全一致（`CLINT.scala:78-80`、`PLIC.scala:156-159`）：SoC 用
  //    `periphRvalid`（AR 拍置位 ⇒ sR 拍被采样）接管整条 R 通道，等价于要求从方
  //    "**AR 拍就把译码结果锁进 rdata**"。旧实现是"AR 拍只锁地址、**再下一拍**才写 `rData`"
  //    ⇒ SoC 在 sR 拍采到的是**本外设上一次读事务**留下的值（没读过就是复位值 0）
  //    ⇒ "写寄存器后紧接着回读"会拿到旧值。实测装置：SoC 级 `M1_SOC_PERIPHRD=1`
  //    （修复前签名：第一次读 UART/GPIO 都拿 0，第二次读才拿到正确值）。
  private val rValid = RegInit(false.B)
  private val rData = RegInit(0.U(32.W))
  private val rResp = RegInit(0.U(2.W))

  io.axi.arready := true.B
  when(io.axi.arvalid && io.axi.arready) {
    rData := MuxLookup(io.axi.araddr, 0.U(32.W))(Seq(
      GPIORegs.DATA_IN      -> dataInReg,
      GPIORegs.DATA_OUT     -> dataOutReg,
      GPIORegs.DIRECTION    -> directionReg,
      GPIORegs.INT_ENABLE   -> intEnableReg,
      GPIORegs.INT_STATUS   -> intStatusReg,
      GPIORegs.INT_TYPE     -> intTypeReg,
      GPIORegs.INT_POLARITY -> intPolarityReg
    ))
    rValid := true.B
    rResp := 0.U  // OKAY
  }.elsewhen(io.axi.rready) {
    rValid := false.B
  }
  
  // 连接输出
  // ⚠️ T4：`awready/wready` 不再直接用两个 1 拍标志，而是"上一次事务还没被 B 消化就不收新的"
  //    —— SoC 侧对 AW/W 是**各来一拍**（sAW→sW），必须能把它们分别留住（见上面的 sticky 说明）。
  io.axi.awready := !bValid
  io.axi.wready  := !bValid
  io.axi.bresp := bResp
  io.axi.bvalid := bValid
  io.axi.rdata := rData
  io.axi.rresp := rResp
  io.axi.rvalid := rValid
  
  // GPIO 引脚连接
  // 注意：实际的三态控制需要在顶层模块中处理
  // 这里只是示例，实际实现需要根据具体 FPGA 平台调整
}
