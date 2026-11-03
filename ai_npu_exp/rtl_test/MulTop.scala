import spinal.core._
import wa.xip.math.{Mul, MulConfig}

/** B8 判据用的小装置：把乘法器放到顶层，给它一个真实时钟域，好让
  * `tools/check_mul.py` 在一个独立、干净的 module 上数流水级、看位段。
  *
  * 位宽 / 符号性 / 级数 / 位段**全部从 argv 传进来**（MulGen 尾部），所以正负对照只要换参数
  * 重新生成即可，不必改源码常量。用于对照的两个真实配置就是调用点的配置：
  *   Quan.scala:99   48 32 32 s 8 79 48   (product[79:48])
  *   Concat.scala:114 32 32 33 s 6 63 31  (product[63:31])
  * 另加 LeakyRelu 的「完整乘积」一路：16 16 32 s 3 31 0。
  *
  * 末参 genTclScript = false ⇒ 这个装置不会写任何 tcl（否则会在 port/verilog/tcl 下留垃圾）。
  * componentName 用 "mul"（而不是任务书示例的 "m0"），这样 check_mul.py 的
  * `module\s+(Mul|mul\w*)` 能直接命中，无需放宽正则。
  */
class MulTop(aW: Int, bW: Int, pW: Int, signed: Boolean, stages: Int, msb: Int, lsb: Int) extends Component {
    val io = new Bundle {
        val A = if (signed) in SInt (aW bits) else in UInt (aW bits)
        val B = in UInt (bW bits)
        val P = if (signed) out SInt (pW bits) else out UInt (pW bits)
    }
    noIoPrefix()
    // Mul 的 IO 是 io Bundle（A/B/P/CLK）；CLK 由 mapClockDomain 自动吃父组件(this)的时钟域，
    // 不用显式连。走的是「带位段」的重载 2，位段原样透传（重载 1 的语义 == 位段 [P_WIDTH-1:0]）。
    val m = Mul(aW, bW, pW,
        if (signed) MulConfig.signed else MulConfig.unsigned, MulConfig.unsigned,
        stages, MulConfig.dsp, this.clockDomain, "mul", msb, lsb, false)
    m.io.A <> io.A
    m.io.B <> io.B
    io.P <> m.io.P
}

object MulGen extends App {
    val outDir = args(0)
    // args: aW bW pW signed stages msb lsb
    val aW = args(1).toInt; val bW = args(2).toInt; val pW = args(3).toInt
    val sg = args(4) == "s"; val st = args(5).toInt; val msb = args(6).toInt; val lsb = args(7).toInt
    SpinalConfig(
        headerWithDate = false,
        headerWithRepoHash = false,
        oneFilePerComponent = false,
        targetDirectory = outDir
    ).generateVerilog(new MulTop(aW, bW, pW, sg, st, msb, lsb))
    println(s"MULGEN_DONE st=$st slice=[$msb:$lsb]")
}
