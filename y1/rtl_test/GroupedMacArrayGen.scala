import spinal.core._

/** 生成 y1/rtl/GroupedMacArray.scala 的 Verilog（落盘到 args(0)，例如 y1/gen）。
  *
  * 一次生成**四份**网表（group 是展开期参数，掩码是常数，所以每个 group 是一份独立网表）：
  *   GroupedMacArray.v      —— GROUP = 1（dense，数组级闸门的默认/兼容档，也是 md5 指纹的目标）
  *   GroupedMacArray_g2.v   —— GROUP = 2
  *   GroupedMacArray_g4.v   —— GROUP = 4
  *   GroupedMacArray_g8.v   —— GROUP = 8（= C_IN = C_OUT ⇒ depthwise，每个 co 只吃 ci == co）
  * 文件名用法与 tools/run_grouped_ab.sh 的 `dutFile()` 一一对应；改这里要同步改那里。
  *
  * 每个文件里含两个模块（oneFilePerComponent=false ⇒ 层次合并进单文件）：
  *   module GroupedMacArray；以及它内部例化的 module MacArray（**与 gen/MacArray.v 逐字节同体**，
  * 闸门里有一条结构性判据专门对比这两处，用来证明"阵列结构一个字没改"）。
  *
  * 两个 header 开关**必须**为 false（与 MacArrayGen 同因）：
  *   headerWithDate     —— 否则每次生成都写当天日期，md5 每天都变；
  *   headerWithRepoHash —— 否则 header 里嵌当前 repo HEAD，**每提交一次指纹就变一次**。
  */
object GroupedMacArrayGen extends App {
  require(args.length >= 1, "usage: runMain GroupedMacArrayGen <outDir> [group ...]")

  val outDir = args(0)
  val groups: Seq[Int] =
    if (args.length > 1) args.drop(1).map(_.toInt) else Seq(1, 2, 4, 8)

  /** group=1 用 "GroupedMacArray.v"（默认档），其余带 _g<N> 后缀。 */
  def fileNameOf(group: Int): String =
    if (group == 1) "GroupedMacArray.v" else s"GroupedMacArray_g$group.v"

  for (group <- groups) {
    require(8 % group == 0, s"测试通道数固定 8：GROUP=$group 必须整除 8")
    SpinalConfig(
      headerWithDate      = false,
      headerWithRepoHash  = false,
      // ★ C3.18 R3-4：本代 NPU **一律同步复位**（理由与全套范围见 NpuTopGen.scala 的同一行）。
      defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC),
      oneFilePerComponent = false,
      targetDirectory     = outDir,
      netlistFileName     = fileNameOf(group)
    ).generateVerilog(new GroupedMacArray(C_IN = 8, C_OUT = 8, GROUP = group))
    println(s"GROUPEDMACARRAYGEN: group=$group -> ${fileNameOf(group)}")
  }
  println("GROUPEDMACARRAYGEN_DONE")
}
