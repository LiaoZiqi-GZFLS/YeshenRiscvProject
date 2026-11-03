import spinal.core._

/** 生成 y1/rtl/MacArray.scala 的 Verilog（落盘到 args(0)，例如 y1/gen）。
  *
  * 两个 header 开关**必须**为 false：
  *   headerWithDate     —— 否则每次生成都写当天日期，md5 每天都变；
  *   headerWithRepoHash —— 否则 header 里嵌当前 repo HEAD，**每提交一次指纹就变一次**，
  *                         之后所有"我这次改动生效了吗"的 md5 对比全部沦为废话。
  * oneFilePerComponent = false —— 单文件产出，方便喂给 check_dangling.py 与 iverilog。
  */
object MacArrayGen extends App {
  require(args.length >= 1, "usage: runMain MacArrayGen <outDir>")
  SpinalConfig(
    headerWithDate      = false,
    headerWithRepoHash  = false,
    // ★ C3.18 R3-4：本代 NPU **一律同步复位**（理由与全套范围见 NpuTopGen.scala 的同一行）。
    defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC),
    oneFilePerComponent = false,
    targetDirectory     = args(0)
  ).generateVerilog(new MacArray)
  println("MACARRAYGEN_DONE")
}
