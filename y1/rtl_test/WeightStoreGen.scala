import spinal.core._

/** 生成 y1/rtl/WeightStore.scala 的 Verilog（落盘到 args(0)，例如 y1/gen）。
  *
  * 一次生成**三份**网表（GROUP 是展开期参数、掩码是常数，所以每个 group 是一份独立网表）：
  *   WeightStore.v      —— GROUP = 1（dense：瓦片 = 原样权重，md5 指纹的目标档）
  *   WeightStore_g4.v   —— GROUP = 4（每 co 只看 2 个 ci，即 PER_GROUP=2）
  *   WeightStore_g8.v   —— GROUP = 8（= C_IN = C_OUT ⇒ depthwise，每个 co 只吃 ci == co）
  * 文件名与 tools/run_weightstore_ab.sh 的 dutFile() 一一对应；改这里要同步改那里。
  * 为什么要有 g4/g8：分组掩码是**常数折叠**出来的，单看 dense 那一份网表证明不了"掩码真的活着"；
  * 闸门的负对照就是"dense 期望 vs 分组装置必须对不上"，没有分组网表这一发就无从谈起。
  *
  * 两个 header 开关**必须**为 false（与 LineBufferGen / GroupedMacArrayGen 同因）：
  *   headerWithDate     —— 否则每次生成都写当天日期，md5 每天都变；
  *   headerWithRepoHash —— 否则 header 里嵌当前 repo HEAD，**每提交一次指纹就变一次**，
  *                         之后所有"我这次改动生效了吗"的 md5 对比全部沦为废话。
  * oneFilePerComponent = false —— 单文件产出，方便喂给 check_dangling.py 与 iverilog。
  */
object WeightStoreGen extends App {
  require(args.length >= 1, "usage: runMain WeightStoreGen <outDir> [group ...]")

  val outDir = args(0)
  val groups: Seq[Int] =
    if (args.length > 1) args.drop(1).map(_.toInt) else Seq(1, 4, 8)

  /** group=1 用 "WeightStore.v"（默认档），其余带 _g<N> 后缀。 */
  def fileNameOf(group: Int): String =
    if (group == 1) "WeightStore.v" else s"WeightStore_g$group.v"

  for (group <- groups) {
    require(8 % group == 0, s"本切片的通道数固定 8：GROUP=$group 必须整除 8")
    SpinalConfig(
      headerWithDate      = false,
      headerWithRepoHash  = false,
      // ★ C3.18 R3-4：本代 NPU **一律同步复位**（理由与全套范围见 NpuTopGen.scala 的同一行）。
      defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC),
      oneFilePerComponent = false,
      targetDirectory     = outDir,
      netlistFileName     = fileNameOf(group)
    ).generateVerilog(WeightStore(C_IN = 8, C_OUT = 8, GROUP = group))
    println(s"WEIGHTSTOREGEN: group=$group -> ${fileNameOf(group)}")
  }
  println("WEIGHTSTOREGEN_DONE")
}
