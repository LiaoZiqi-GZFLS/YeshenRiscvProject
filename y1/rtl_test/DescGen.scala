import spinal.core._

/** 生成 y1/rtl/DescFetch.scala 的 Verilog（落盘到 args(0)，例如 y1/gen）。
  *
  * 两个 header 开关**必须**为 false（与 DdrMasterGen / NpuTopGen / HostRegsGen 同因）：
  *   headerWithDate     —— 否则每次生成都写当天日期，md5 每天都变；
  *   headerWithRepoHash —— 否则 header 里嵌当前 repo HEAD，**每提交一次指纹就变一次**，
  *                         之后所有"我这次改动生效了吗"的 md5 对比全部沦为废话。
  * oneFilePerComponent = false —— **关键**：`DescFetch` 内部例化了 `DdrMaster`，
  *   单文件产出 ⇒ gen/DescFetch.v 里同时有 `DescFetch` 与 `DdrMaster` 两个 module，
  *   iverilog 只编译这一个网表文件（不会与 gen/DdrMaster.v 撞重名 module），
  *   check_dangling.py 也只喂一个文件就既看到定义又看到例化。
  *
  * 形状参数用默认的 DdrMasterConfig()（DescFetch 内部固定用它）。
  */
object DescGen extends App {
  require(args.length >= 1, "usage: runMain DescGen <outDir>")
  SpinalConfig(
    headerWithDate      = false,
    headerWithRepoHash  = false,
    // ★ C3.18 R3-4：本代 NPU **一律同步复位**（理由与全套范围见 NpuTopGen.scala 的同一行）。
    defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC),
    oneFilePerComponent = false,
    targetDirectory     = args(0)
  ).generateVerilog(DescFetch())
  println("DESCGEN_DONE")
}
