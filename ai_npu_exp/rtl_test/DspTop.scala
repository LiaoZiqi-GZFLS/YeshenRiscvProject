import spinal.core._
import wa.xip.math.DSP

/** B7 判据用的小装置：只是把 MAC 的 DSP 黑盒拉到顶层，给一个真实时钟域，
  * 好让 tools/check_dsp_latency.py 能在一个独立、干净的 module DSP 上数流水级。
  *
  * 级数由构造参数传入（DspTop(stages) → DSP(..., stages)），所以负对照只要换个数字
  * 重新生成即可，不需要改源码常量。默认（GenNpu 里）走 6 级。
  */
class DspTop(stages: Int) extends Component {
    val io = new Bundle {
        val a = in UInt (8 bits)
        val d = in UInt (8 bits)
        val b = in UInt (8 bits)
        val p = out UInt (32 bits)
    }
    noIoPrefix()
    // DSP 的 IO 是类字段（a/d/b/p/CLK），不是 io Bundle；签名 = (componentName, clockDomain2X, stages)。
    // clockDomain2X 只在 Config.dsp2x=true 时用（此处 false，传 null 即可）。
    // 不显式接 CLK：mapClockDomain(clock = CLK) 会让黑盒 CLK 自动吃父组件(this)的时钟域。
    val m = new DSP("dsp_macro_0", null, stages)
    m.a <> io.a
    m.d <> io.d
    m.b <> io.b
    io.p <> m.p
}

object DspGen extends App {
    val outDir = args(0)
    val stages = args(1).toInt
    SpinalConfig(
        headerWithDate = false,
        headerWithRepoHash = false,
        oneFilePerComponent = false,
        targetDirectory = outDir
    ).generateVerilog(new DspTop(stages))
    println("DSPGEN_DONE stages=" + stages)
}
