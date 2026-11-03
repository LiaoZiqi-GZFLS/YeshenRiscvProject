import spinal.core._

/** 生成 y1/rtl/Conv3x3Slice.scala 的 Verilog（落盘到 args(0)，例如 y1/gen）。
  *
  * 一次生成**三份**网表（GROUP 是展开期参数、掩码是常数，所以每个 group 是一份独立网表）：
  *   Conv3x3Slice.v      —— GROUP = 1（dense，默认/兼容档，也是 md5 指纹的目标）
  *   Conv3x3Slice_g4.v   —— GROUP = 4
  *   Conv3x3Slice_g8.v   —— GROUP = 8（= C_IN = C_OUT ⇒ depthwise，每个 co 只吃 ci == co）
  * 三份网表的**端口同名同宽**（唯一差别是掩码常量），所以装置分不出档位，只能靠网表自报的
  * `grp` 常量输出来断言 +GROUP 对得上（见 rtl/Conv3x3Slice.scala 的 io.grp 与 rtl_test/Conv3x3Tb.v）。
  * 文件名用法与 tools/run_numeric_ab.sh 的 `RTL=` 覆盖一一对应（dense 用默认路径，其余显式传 RTL）；
  * 改这里要同步改 TB 头部注释里的"重新生成"一行。
  *
  * 维度取**判据的定点用例**：tools/run_numeric_ab.sh 的三档都是 C_in=8、C_out=8、W=16，
  * 即 C_IN=8、C_OUT=8、WIDTH=16。H 不是本模块的参数（LineBuffer/切片都不数图高，
  * 图高由驱动方喂几行决定），但 **WIDTH 必须与 +IW 一致**：LineBuffer 按 WIDTH 数行，
  * 网表宽度跟 +IW 不一致时窗口语义整个错位（TB 会显式对不上就报红）。
  *
  * ★ WIDTH 是 **Scala/命令行参数**（不是一个写死的常量）：面积闸门（下一任务）要用 WIDTH=640
  *   的行缓冲重生成一次（同一份源码、只换宽度），所以这里 `runMain SliceGen <outDir> [WIDTH]`，
  *   缺省 WIDTH=16（= 数值判据的定点用例）。GROUP 的三档是**固定**的（1/4/8），不开放命令行。
  *
  * 两个 header 开关**必须**为 false（与 MacArrayGen / LineBufferGen / WeightStoreGen 同因）：
  *   headerWithDate     —— 否则每次生成都写当天日期，md5 每天都变；
  *   headerWithRepoHash —— 否则 header 里嵌当前 repo HEAD，**每提交一次指纹就变一次**。
  * oneFilePerComponent = false —— 单文件产出（切片 + LineBuffer + WeightStore + GroupedMacArray + MacArray
  *   全在一个文件里），这样它既是 check_dangling.py 的输入，也是唯一需要被仿真器看见的文件。
  */
object SliceGen extends App {
  require(args.length >= 1, "usage: runMain SliceGen <outDir> [WIDTH]")
  val outDir = args(0)
  // WIDTH 缺省 16（数值判据的定点用例）；面积闸门会显式传 640 重生成。
  val width: Int = if (args.length >= 2) args(1).toInt else 16
  require(width >= 3, s"WIDTH=$width 太小：3x3 窗口至少要 3 列")

  /** GROUP=1 用 "Conv3x3Slice.v"（默认档），其余带 _g<N> 后缀（与 TB/判据里的路径约定一致）。 */
  def fileNameOf(group: Int): String =
    if (group == 1) "Conv3x3Slice.v" else s"Conv3x3Slice_g$group.v"

  // 三档固定：dense / group=4 / depthwise（= 8）。GROUP 必须整除 8（定点 8x8 阵列）。
  val groups: Seq[Int] = Seq(1, 4, 8)
  val written = scala.collection.mutable.ArrayBuffer.empty[String]
  for (group <- groups) {
    require(8 % group == 0, s"本切片通道数固定 8：GROUP=$group 必须整除 8")
    SpinalConfig(
      headerWithDate      = false,
      headerWithRepoHash  = false,
      // ★ C3.18 R3-4：本代 NPU **一律同步复位**（理由与全套范围见 NpuTopGen.scala 的同一行）。
      defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC),
      oneFilePerComponent = false,
      targetDirectory     = outDir,
      netlistFileName     = fileNameOf(group)
    ).generateVerilog(new Conv3x3Slice(C_IN = 8, C_OUT = 8, GROUP = group, WIDTH = width, SHIFT = 6))
    written += fileNameOf(group)
    println(s"SLICEGEN: C_IN=8 C_OUT=8 GROUP=$group WIDTH=$width SHIFT=6 -> ${fileNameOf(group)}")
  }
  println(s"SLICEGEN: wrote ${written.length} netlists to $outDir: ${written.mkString(", ")}")
  println("SLICEGEN_DONE")
}
