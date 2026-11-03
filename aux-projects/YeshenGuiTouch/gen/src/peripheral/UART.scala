import chisel3._
import chisel3.util._

// ===================== UART 寄存器地址 =====================
object UARTRegs {
  val TX_DATA  = 0x00.U(5.W)  // 发送数据寄存器
  val RX_DATA  = 0x04.U(5.W)  // 接收数据寄存器
  val STATUS   = 0x08.U(5.W)  // 状态寄存器
  val CONTROL  = 0x0C.U(5.W)  // 控制寄存器
  val BAUD_DIV = 0x10.U(5.W)  // 波特率分频寄存器
  // T4（D1=B）：sticky RX pending 的 W1C 出口。**必须避开 0x10（BAUD_DIV 占了）** ⇒ 取 0x14。
  // bit0 = RX pending：写 1 清（W1C，与 GPIO 的 `INT_STATUS` 同构）。读 RX_DATA 也会清它。
  val INT_STATUS = 0x14.U(5.W)
}

// ===================== UART 状态寄存器位定义 =====================
object UARTStatus {
  val TX_BUSY     = 0  // 发送忙标志
  val RX_READY    = 1  // 接收数据就绪标志
  val TX_FULL     = 2  // 发送 FIFO 满
  val RX_EMPTY    = 3  // 接收 FIFO 空
  val FRAME_ERROR = 4  // 帧错误
  val PARITY_ERROR = 5 // 奇偶校验错误
  val OVERFLOW    = 6  // 溢出错误
}

// ===================== UART 控制寄存器位定义 =====================
object UARTControl {
  val TX_ENABLE   = 0  // 发送使能
  val RX_ENABLE   = 1  // 接收使能
  val TX_INT_EN   = 2  // 发送中断使能
  val RX_INT_EN   = 3  // 接收中断使能
  val PARITY_EN   = 4  // 奇偶校验使能
  val PARITY_TYPE = 5  // 奇偶校验类型（0=偶校验，1=奇校验）
  val STOP_BITS   = 6  // 停止位数量（0=1位，1=2位）
}

// ===================== UART 接口 =====================
class UARTIO extends Bundle {
  // AXI-Lite 接口
  val axi = new AXILiteIO
  
  // UART 物理接口
  val txd = Output(Bool())  // 发送数据线
  val rxd = Input(Bool())   // 接收数据线
  
  // 中断输出
  val interrupt = Output(Bool())
}

// ===================== AXI-Lite 接口定义 =====================
class AXILiteIO extends Bundle {
  // 写地址通道
  val awaddr  = Input(UInt(5.W))
  val awvalid = Input(Bool())
  val awready = Output(Bool())
  
  // 写数据通道
  val wdata   = Input(UInt(32.W))
  val wstrb   = Input(UInt(4.W))
  val wvalid  = Input(Bool())
  val wready  = Output(Bool())
  
  // 写响应通道
  val bresp   = Output(UInt(2.W))
  val bvalid  = Output(Bool())
  val bready  = Input(Bool())
  
  // 读地址通道
  val araddr  = Input(UInt(5.W))
  val arvalid = Input(Bool())
  val arready = Output(Bool())
  
  // 读数据通道
  val rdata   = Output(UInt(32.W))
  val rresp   = Output(UInt(2.W))
  val rvalid  = Output(Bool())
  val rready  = Input(Bool())
}

// ===================== UART 发送器 =====================
// ⚠️ 位时钟约定（2026-09-24 修）：**一个位 = 4 个 `baudTick`**，与 `UARTRx` 的 4× 过采样同一网格。
//    修之前 TX 是"1 个 baudTick 进一位"而 RX 是"4 个 baudTick 采一次" ⇒ 同一分频下 TX 比 RX 快 4 倍，
//    根本收不回来（单元级回环实测 0/10）。
// ⚠️ 校验位槽（2026-10-07 修）：`parityEn=false`（8N1）时 **必须跳过 `sParity`**。
//    原来不管 LCR 怎么写都恒发一个校验位 ⇒ 一帧 = 11 位（start+8data+parity+stop）：
//      · 多 10% 线上时间；
//      · 更糟：对端按 8N1 收时，**停止位位置上读到的是校验位**，校验位=0 的字节（如 'H'=0x48）
//        就被对端判成帧错（USB 桥通常仍交出字节，所以启动日志"看起来"是好的 ⇒ 掩盖了这个缺陷）。
class UARTTx extends Module {
  val io = IO(new Bundle {
    val data      = Input(UInt(8.W))
    val start     = Input(Bool())
    val baudTick  = Input(Bool())
    val enable    = Input(Bool())
    val parityEn  = Input(Bool())    // 0 = 8N1：跳过校验位槽
    val busy      = Output(Bool())
    val txd       = Output(Bool())
  })
  
  // 状态机状态
  val sIdle :: sStart :: sData :: sParity :: sStop :: Nil = Enum(5)
  val state = RegInit(sIdle)
  
  // 数据寄存器
  val dataReg = RegInit(0.U(8.W))
  val bitIndex = RegInit(0.U(3.W))
  val parityBit = RegInit(false.B)
  
  // 位时钟：baudTick 的 4 分频（自由跑，不跟帧对齐；帧首靠下面的 `pend` 对齐到位边界）
  // ⚠️ `bitTick` 必须是**单拍脉冲**：`sub === 3` 本身是**电平**，而 sub 只按 baudTick 递增
  //    ⇒ 它会在整个 baudTick 周期里一直是 3，FSM 就每拍进一位（实测：一帧 11 拍就发完了）。
  //    必须与 baudTick 相与。
  val sub = RegInit(0.U(2.W))
  val bitTick = io.baudTick && (sub === 3.U)
  when(io.baudTick) { sub := sub + 1.U }
  
  // ⚠️ 两个承重细节（都是实测缺陷的修法）：
  //  ① **请求先落 pending，再在"位边界"起步**：原来直接在 `io.start` 那一拍进 sStart，而帧首是异步
  //     落在 baudTick 网格上的 ⇒ start bit 会被截成 1..P 拍（实测同一分频下量到 55/9/9），
  //     任何对端（含本模块自己的 RX）都会错位。
  //  ② 顺带修掉"TX 发的是上一笔写入的字节"：`pend` 让 `io.data` 的采样至少晚一个位边界
  //     （`UARTController` 里 `txDataReg := wData` 与 `txStart := true` 同拍），那时寄存器已经落定。
  //     本模块无 FIFO：忙时再写会**覆盖** pending 槽（最后一笔生效）。
  val pend = RegInit(false.B)
  when(io.start && io.enable) { pend := true.B }
  
  // 默认输出
  io.txd := true.B
  io.busy := state =/= sIdle || pend   // 含"已请求但还没到边界"的等待期 ⇒ 轮询驱动不会丢帧
  
  switch(state) {
    is(sIdle) {
      io.txd := true.B
      when(pend && bitTick) {
        dataReg := io.data
        bitIndex := 0.U
        parityBit := false.B
        pend := false.B
        state := sStart
      }
    }
    is(sStart) {
      io.txd := false.B
      when(bitTick) {
        state := sData
      }
    }
    is(sData) {
      io.txd := dataReg(bitIndex)
      when(bitTick) {
        parityBit := parityBit ^ dataReg(bitIndex)
        when(bitIndex === 7.U) {
          state := Mux(io.parityEn, sParity, sStop)   // 8N1 ⇒ 没有校验位槽，直接进停止位
        }.otherwise {
          bitIndex := bitIndex + 1.U
        }
      }
    }
    is(sParity) {
      io.txd := parityBit
      when(bitTick) {
        state := sStop
      }
    }
    is(sStop) {
      io.txd := true.B
      when(bitTick) {
        state := sIdle
      }
    }
  }
}

// ===================== UART 接收器 =====================
// ⚠️⚠️ 采样栅格（2026-10-07 修，**板级实测缺陷**）：原来"起始位采样后只隔 **3** 个 baudTick
//    就开始采数据位"（应为 4 = 一位），且 `sParity` 槽**恒走**（本口是 8N1，没有校验位）
//    ⇒ 停止位采样点比位中心晚 3/4 位，正好落到**下一字节的起始位里** ⇒ 判帧错 ⇒ 整字节丢弃。
//    实测症状：**孤立字节收得下、背靠背突发全灭** —— 板上 10 个 'q' 间隔 100ms 发 = 10/10 回显；
//    连发 10 个 = 0/10、30 个 = 0/30；登录时 `root\r` 这种多字节输入必然全丢 ⇒ "控制台只能读不能打字"。
//    两条修法（缺一不可）：
//      ① `sStart` 校验通过后把 `sampleCount` 预置回 **1**（而不是让它停在 2）⇒ 第一个数据位正好
//         在起始位采样后 **4** 个 baudTick 采，数据位落在位中心附近；
//      ② `parityEn=false` 时 `sData` 直接进 `sStop`，省掉校验位槽 ⇒ 停止位采样点落回停止位内。
//    单元装置：`sim/uartrx/`（4 个相位 × 单字节/5 字节/16 字节背靠背），修前 8/12 条红、修后全绿。
class UARTRx extends Module {
  val io = IO(new Bundle {
    val rxd       = Input(Bool())
    val baudTick  = Input(Bool())
    val enable    = Input(Bool())
    val parityEn  = Input(Bool())    // 0 = 8N1：跳过校验位槽
    val data      = Output(UInt(8.W))
    val valid     = Output(Bool())
    val frameError = Output(Bool())
  })
  
  // 状态机状态
  val sIdle :: sStart :: sData :: sParity :: sStop :: Nil = Enum(5)
  val state = RegInit(sIdle)
  
  // 数据寄存器
  val dataReg = RegInit(0.U(8.W))
  val bitIndex = RegInit(0.U(3.W))
  val parityBit = RegInit(false.B)
  val sampleCount = RegInit(0.U(2.W))
  
  // 输出寄存器
  val dataOut = RegInit(0.U(8.W))
  val validOut = RegInit(false.B)
  val frameErrorOut = RegInit(false.B)
  
  // 默认输出
  io.data := dataOut
  io.valid := validOut
  io.frameError := frameErrorOut
  
  // 清除有效信号
  when(validOut) {
    validOut := false.B
  }
  
  switch(state) {
    is(sIdle) {
      frameErrorOut := false.B
      when(!io.rxd && io.enable) {
        sampleCount := 0.U
        state := sStart
      }
    }
    is(sStart) {
      when(io.baudTick) {
        sampleCount := sampleCount + 1.U
        when(sampleCount === 1.U) {
          when(!io.rxd) {
            bitIndex := 0.U
            parityBit := false.B
            // ★ 起始位采样点≈位中心；数据位必须**再走 4 个 baudTick（= 一位）**才采。
            //   预置回 1（盖掉上面那句 +1）⇒ `sData` 里下一次 `sampleCount===0` 正好落在 4 拍后。
            sampleCount := 1.U
            state := sData
          }.otherwise {
            state := sIdle
          }
        }
      }
    }
    is(sData) {
      when(io.baudTick) {
        sampleCount := sampleCount + 1.U
        when(sampleCount === 0.U) {
          dataReg := Cat(io.rxd, dataReg(7, 1))
          parityBit := parityBit ^ io.rxd
          when(bitIndex === 7.U) {
            state := Mux(io.parityEn, sParity, sStop)   // 8N1 ⇒ 省掉校验位槽，停止位才采得准
          }.otherwise {
            bitIndex := bitIndex + 1.U
          }
        }
      }
    }
    is(sParity) {
      when(io.baudTick) {
        sampleCount := sampleCount + 1.U
        when(sampleCount === 0.U) {
          state := sStop
        }
      }
    }
    is(sStop) {
      when(io.baudTick) {
        sampleCount := sampleCount + 1.U
        when(sampleCount === 0.U) {
          when(io.rxd) {
            dataOut := dataReg
            validOut := true.B
          }.otherwise {
            frameErrorOut := true.B
          }
          state := sIdle
        }
      }
    }
  }
}

// ===================== UART 控制器顶层 =====================
class UARTController extends Module {
  val io = IO(new UARTIO)
  
  // 寄存器定义
  val txDataReg = RegInit(0.U(32.W))
  val rxDataReg = RegInit(0.U(32.W))
  val statusReg = RegInit(0.U(32.W))
  val controlReg = RegInit(0.U(32.W))
  val baudDivReg = RegInit(0.U(32.W))
  
  // 波特率发生器
  val baudCounter = RegInit(0.U(16.W))
  val baudTick = baudCounter === 0.U
  
  when(baudCounter === 0.U) {
    baudCounter := baudDivReg(15, 0)
  }.otherwise {
    baudCounter := baudCounter - 1.U
  }
  
  // UART 发送器
  val tx = Module(new UARTTx)
  tx.io.data := txDataReg(7, 0)
  tx.io.baudTick := baudTick
  tx.io.enable := controlReg(UARTControl.TX_ENABLE)
  tx.io.parityEn := controlReg(UARTControl.PARITY_EN)
  
  // UART 接收器
  val rx = Module(new UARTRx)
  rx.io.rxd := io.rxd
  rx.io.baudTick := baudTick
  rx.io.enable := controlReg(UARTControl.RX_ENABLE)
  rx.io.parityEn := controlReg(UARTControl.PARITY_EN)
  
  // 状态寄存器更新
  statusReg := Cat(
    0.U(25.W),                    // 保留位
    statusReg(6),                  // 溢出错误
    statusReg(5),                  // 奇偶校验错误
    rx.io.frameError,              // 帧错误
    statusReg(3),                  // 接收 FIFO 空
    statusReg(2),                  // 发送 FIFO 满
    rx.io.valid,                   // 接收数据就绪
    tx.io.busy                     // 发送忙
  )
  
  // 接收数据锁存
  when(rx.io.valid) {
    rxDataReg := Cat(0.U(24.W), rx.io.data)
  }
  
  // ===================== T4（D1=B）：sticky RX pending =====================
  // 为什么需要它（spec §3.3 的 D1 决策）：`rx.io.valid` 只有**一拍**，且 UART 没有任何可清的
  // 状态寄存器（读 `RX_DATA` 不清位），而"数据已收到"这件事一旦没被记下就**无法从任何寄存器
  // 重建**（`rxDataReg` 会被下一个字节覆盖）⇒ 若驱动还没开中断，那个字节就永久丢了，
  // 8250 驱动不会重试（症状：控制台偶发打不进字）。
  // ⚠️ **置位只看 `rx.io.valid`，不看 `RX_INT_EN`** —— 这正是 B 相对 A 的全部区别：
  //    字节到了就先记下，等驱动开中断时照样能看见。
  // 清位有两条路径：① 读 `RX_DATA`（数据被取走 ⇒ 事件已服务）；② 对 `INT_STATUS` 写 1（W1C）。
  // ⚠️ 优先级：**置位优先于清位** —— 同一拍"读走旧字节 + 收到新字节"时，新字节必须仍算 pending。
  private val rxPend = RegInit(false.B)

  // 发送启动信号
  val txStart = WireDefault(false.B)
  
  // 中断生成
  val txInt = controlReg(UARTControl.TX_INT_EN) && !tx.io.busy
  // T4：源线改用 sticky `rxPend`（原来是 `rx.io.valid` 的单拍脉冲 ⇒ 会丢事件）
  val rxInt = controlReg(UARTControl.RX_INT_EN) && rxPend
  io.interrupt := txInt || rxInt
  
  // AXI-Lite 写逻辑
  val awReady = RegInit(false.B)
  val wReady = RegInit(false.B)
  val bValid = RegInit(false.B)
  val bResp = RegInit(0.U(2.W))
  
  // ⚠️ T4 修（与 GPIO 同款缺陷）：原来只有 **4 位**，而 `BAUD_DIV=0x10` 与新增的
  //    `INT_STATUS=0x14` 都 >= 0x10 ⇒ 会被**静默截断**（写 BAUD_DIV 实际写到 TX_DATA）⇒ 加宽到 5 位。
  val awAddr = RegInit(0.U(5.W))
  val wData = RegInit(0.U(32.W))
  val wStrb = RegInit(0.U(4.W))
  
  // ⚠️ T4 修：原来用"1 拍即落"的 `awReady`/`wReady`，而 **SoC 的 MMIO FSM 是 sAW→sW→sB 三拍**
  //    ⇒ `awReady && wReady` 永不同拍 ⇒ `bValid` 永不拉 ⇒ FSM 卡在 sB ⇒ ROB 阻塞。
  //    改成 **sticky pend**（与 CLINT/PLIC 同一套写法）。
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
      is(UARTRegs.TX_DATA) {
        txDataReg := wData
        txStart := true.B
      }
      is(UARTRegs.CONTROL) {
        controlReg := wData
      }
      is(UARTRegs.BAUD_DIV) {
        baudDivReg := wData
      }
    }
    bValid := true.B
    bResp := 0.U  // OKAY
    // 消费掉 sticky pend（与 CLINT/PLIC 同款）
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
      UARTRegs.TX_DATA    -> txDataReg,
      UARTRegs.RX_DATA    -> rxDataReg,
      UARTRegs.STATUS     -> statusReg,
      UARTRegs.CONTROL    -> controlReg,
      UARTRegs.BAUD_DIV   -> baudDivReg,
      // T4（D1=B）：bit0 = sticky RX pending（只读；写 1 才是清它，见下面的 W1C）
      UARTRegs.INT_STATUS -> Cat(0.U(31.W), rxPend)
    ))
    rValid := true.B
    rResp := 0.U  // OKAY
  }.elsewhen(io.axi.rready) {
    rValid := false.B
  }

  // ===================== T4：rxPend 的单点赋值（优先级显式）=====================
  // 放在两个译码块**之后**，用它们的完成条件做"清位"判据：
  //   ① 读 `RX_DATA` ⇒ 数据被取走
  //   ② 对 `INT_STATUS` 写 1（W1C，与 `GPIO.scala:128-131` 同构）
  // ⚠️ 置位（`rx.io.valid`）**优先**：同拍"读走旧字节 + 收到新字节"时新字节仍算 pending。
  // `araddr` 直接用**输入**（不再是锁存寄存器）：译码与"读走字节"都发生在 AR 握手那一拍，
  // 与上面 `rData` 的锁存同拍 ⇒ 清位判据与数据来源天然对齐（MMIO 只抬 1 拍 arvalid ⇒ 只清一次）。
  private val uartRxDataRead = io.axi.arvalid && io.axi.arready && (io.axi.araddr === UARTRegs.RX_DATA)
  private val uartRxW1c      = awReady && wReady && (awAddr === UARTRegs.INT_STATUS) && wData(0)
  when(rx.io.valid) {
    rxPend := true.B
  }.elsewhen(uartRxDataRead || uartRxW1c) {
    rxPend := false.B
  }
  
  // 连接输出
  // ⚠️ T4：不是直接用两个 1 拍标志，而是"上一次事务还没被 B 消化就不收新的"
  io.axi.awready := !bValid
  io.axi.wready  := !bValid
  io.axi.bresp := bResp
  io.axi.bvalid := bValid
  io.axi.rdata := rData
  io.axi.rresp := rResp
  io.axi.rvalid := rValid
  
  io.txd := tx.io.txd
  
  // 发送启动
  tx.io.start := txStart
}
