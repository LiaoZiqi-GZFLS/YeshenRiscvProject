import spinal.core._
import wa.xip.math.{AddSub, AddSubConfig}

/** B9b 判据用的小装置：把加/减法器黑盒拉到顶层，给一个真实时钟域，
  * 好让 `tools/check_addsub_latency.py` 在一个独立、干净的 module 上数流水级、看加/减。
  *
  * 位宽 / 符号性 / 级数 / 加还是减**全部从 argv 传进来**（`AddSubGen` 尾部），所以正负对照
  * 只要换参数重新生成即可，不必改源码常量。装置里常用的两个真实配置就是调用点的配置：
  *   LeakyRelu.scala:27   16 8 16 s u 1 sub   ("leakySubZ3"，唯一的 Subtract)
  *   Add.scala:147        64 64 64 s s 5 add  ("addAdd64_64"，2 + 3 = 5 级)
  *
  * componentName 用 "addsub"（小写），这样 check_addsub_latency.py 的
  * `module\s+(AddSub|addsub\w*)` 能直接命中。
  * 走的是**类构造器**而不是 `object AddSub.apply`：apply 的签名（含 PIPELINE_STAGE/ADD_MODE）
  * 已经能覆盖全部 7 个调用点，用构造器只是省掉 RESOURCES_TYPE 这个对本装置无意义的参数。
  */
class AddSubTop(aW: Int, bW: Int, sW: Int, aSigned: Boolean, bSigned: Boolean, stages: Int, subtract: Boolean) extends Component {
    val io = new Bundle {
        val A = if (aSigned) in SInt (aW bits) else in UInt (aW bits)
        val B = if (bSigned) in SInt (bW bits) else in UInt (bW bits)
        val S = if (aSigned || bSigned) out SInt (sW bits) else out UInt (sW bits)
    }
    noIoPrefix()
    // AddSub 的 IO 是 io Bundle（A/B/S/CLK）；CLK 由 mapClockDomain(clockDomain, io.CLK) 自动吃
    // 父组件(this)的时钟域，不用显式连（与 B7 的 DspTop 同理）。
    val m = new AddSub(aW, bW, sW,
        if (aSigned) AddSubConfig.signed else AddSubConfig.unsigned,
        if (bSigned) AddSubConfig.signed else AddSubConfig.unsigned,
        this.clockDomain, "addsub", stages,
        if (subtract) AddSubConfig.subtract else AddSubConfig.add)
    m.io.A <> io.A
    m.io.B <> io.B
    io.S <> m.io.S
}

object AddSubGen extends App {
    val outDir = args(0)
    // args: aW bW sW aType(s|u) bType(s|u) stages op(add|sub)
    val aW = args(1).toInt; val bW = args(2).toInt; val sW = args(3).toInt
    val asg = args(4) == "s"; val bsg = args(5) == "s"
    val st = args(6).toInt; val sub = args(7) == "sub"
    SpinalConfig(
        headerWithDate = false,
        headerWithRepoHash = false,
        oneFilePerComponent = false,
        targetDirectory = outDir
    ).generateVerilog(new AddSubTop(aW, bW, sW, asg, bsg, st, sub))
    println(s"ADDSUBGEN_DONE st=$st op=${if (sub) "sub" else "add"} w=$aW/$bW/$sW")
}
