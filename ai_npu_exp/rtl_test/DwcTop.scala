import spinal.core._
import spinal.lib._
import wa.xip.axi.StreamDataWidthConvert

/** B9b 判据用的小装置：把流位宽转换器黑盒拉到顶层，给一个真实时钟域 + 一对
  * `slave/master Stream`，好让 `tools/check_dwc_latency.py` 在一个独立、干净的 module 上
  * 数存储级、看位宽方向、看打包顺序。
  *
  * 位宽 / 级数 / 打包顺序**全部从 argv 传进来**（`DwcGen` 尾部），所以正负对照只要换参数重新生成：
  *   正对照：128 1024 8 0   ← 生产配置（= FeatureWidthConvert 的 S/M_DATA_WIDTH）
  *   负对照 A（级数少 1）：128 1024 7 0
  *   负对照 B（打包顺序反）：128 1024 8 1
  *
  * componentName 用 "dwc"，供判据定位。
  */
class DwcTop(sW: Int, mW: Int, stages: Int, reverse: Boolean) extends Component {
    val io = new Bundle {
        val sData = slave Stream UInt(sW bits)
        val mData = master Stream UInt(mW bits)
    }
    noIoPrefix()
    // 黑盒的 aclk/aresetn 由 mapClockDomain(clock = io.aclk, reset = io.aresetn) 自动吃
    // 父组件(this)的时钟域，不用显式连（与 B7/B8 的装置同理）。
    val dwc = new StreamDataWidthConvert(sW, mW, "dwc", stages, reverse)
    dwc.io.sData <> io.sData
    io.mData <> dwc.io.mData
}

object DwcGen extends App {
    val outDir = args(0)
    // args: sW mW stages reverse(0|1)
    val sW = args(1).toInt; val mW = args(2).toInt
    val st = args(3).toInt; val rev = args(4) == "1"
    SpinalConfig(
        headerWithDate = false,
        headerWithRepoHash = false,
        oneFilePerComponent = false,
        targetDirectory = outDir
    ).generateVerilog(new DwcTop(sW, mW, st, rev))
    println(s"DWC_GEN_DONE st=$st reverse=$rev w=$sW/$mW")
}
