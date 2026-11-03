package wa

import conv.dataGenerate.GenerateMatrixPort
import spinal.core._
import spinal.lib._
import wa.xip.memory.xpm.{FifoSync, XPM_FIFO_SYNC_CONFIG}

object WaStreamFifo {
    def apply[T <: Data](dataType: T, depth: Int) = new WaStreamFifo(dataType, depth)

    def apply[T <: Data](dataType: T, depth: Int, mCount: UInt, sCount: UInt, sReady: Bool, mReady: Bool): WaStreamFifo[T] = {
        val tt = new WaStreamFifo(dataType, depth, true)
        sCount <> tt.sCount
        mCount <> tt.mCount
        sReady <> tt.sReady
        mReady <> tt.mReady
        tt
    }
}

class WaStreamFifo[T <: Data](dataType: HardType[T], depth: Int, flag: Boolean = false) extends StreamFifo[T](dataType: HardType[T], depth: Int) {
    val almost_full = out Bool()
    when(io.availability <= 1) {
        almost_full.set()
    } otherwise {
        almost_full.clear()
    }
    noIoPrefix()
    val sCount = if (flag) in UInt (log2Up(depth) bits) else null
    val mCount = if (flag) in UInt (log2Up(depth) bits) else null
    val sReady = if (flag) out Bool() else null
    val mReady = if (flag) out Bool() else null
    if (flag) {
        when(io.availability >= sCount) {
            sReady := True
        } otherwise {
            sReady := False
        }
        when(io.availability >= mCount) {
            mReady := True
        } otherwise {
            mReady := False

        }
    }
}

case class WaXpmSyncFifo(config: XPM_FIFO_SYNC_CONFIG) extends Component {

    val sCount = in UInt (config.WR_DATA_COUNT_WIDTH bits)
    val mCount = in UInt (config.RD_DATA_COUNT_WIDTH bits)
    val sReady = out (Reg(Bool()))
    val mReady = out (Reg(Bool()))
    val dataIn = slave Flow(UInt(config.WRITE_DATA_WIDTH bits))
    val rd_en = in Bool()
    val dout = out UInt (config.READ_DATA_WIDTH bits)

    // Pango 化：不再用 Xilinx xpm_fifo_sync，改用可综合的 SpinalHDL StreamFifo。
    // 对外 IO（名字/方向/位宽）与原来完全一致，ConvCompute.scala 无需改动。
    // 位宽检查：StreamFifo 只有一个数据宽度，写读不同宽的原语口无法保真 ⇒ 宁可响亮失败。
    require(config.WRITE_DATA_WIDTH == config.READ_DATA_WIDTH,
        "Pango 化后的 WaXpmSyncFifo 只支持写读同宽（StreamFifo 无位宽转换）")
    val fifo = StreamFifo(UInt(config.WRITE_DATA_WIDTH bits), config.FIFO_WRITE_DEPTH)
    // 资源属性（B5 的教训）：SpinalHDL 1.15.0 只给"异步读"的 Mem 打 ram_style = "distributed"，
    // 同步读的**什么都不打**。这里 9 个 FIFO × 2048×128bit ≈ 2.25Mbit，绝不能被推断成 LUTRAM，
    // 所以照上游对 BRAM 存储器的写法显式请求 block（shape/Add.scala 等对 StreamFifo 内部 Mem 同样处理）。
    fifo.logic.ram.addAttribute("ram_style = \"block\"")
    fifo.io.push.valid := RegNext(dataIn.fire) // 与原实现一致的 1 拍写延迟
    fifo.io.push.payload := RegNext(dataIn.payload)
    fifo.io.pop.ready := rd_en // rd_en 推读（原 XPM 的 fwft 读模式）
    dout := fifo.io.pop.payload

    when(fifo.io.occupancy + sCount < config.FIFO_WRITE_DEPTH - 10) {
        sReady.set()
    } otherwise {
        sReady.clear()
    }
    when(fifo.io.occupancy >= mCount) {
        mReady.set()
    } otherwise {
        mReady.clear()
    }

}
