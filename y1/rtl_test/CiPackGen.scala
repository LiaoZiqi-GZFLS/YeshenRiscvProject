import spinal.core._

/** 生成 `rtl_test/CiPackProbe.scala` 的 Verilog（NPU v2 切片 C-1 的独立探针网表）。
  *
  * 用法：`runMain CiPackGen <outDir> <DCI:0|1> [MUTX] [fileName]`
  *   DCI 0 = Base（B1 当量：dense 广播 + dw 逐 lane AFTER1）        -> `CiPackBase.v`
  *   DCI 1 = Base + **c3 ci-inner**（本片被测的增量）               -> `CiPackDci.v`
  *   MUTX ≥ 0 = **外科锚**：c3 读口里 lane MUTX 的 kx 改错（只动路由）-> `CiPackDciMut<N>.v`
  *   三档的**模块名都是 `CiPackProbe`**（与 DwLaneGen / SliceGen 同一约定：一次只编译一份）。
  *
  * 两个 header 开关必须为 false（与 MacArrayGen / MultiPassGen / SliceGen / DwLaneGen 同因）；
  * `oneFilePerComponent = false` ⇒ 探针连同 LineBuffer 全落进一个文件（check_dangling 只看这一个）。
  */
object CiPackGen extends App {
  require(args.length >= 2, "usage: runMain CiPackGen <outDir> <DCI:0|1> [MUTX] [fileName]")
  val outDir = args(0)
  val dci: Boolean = args(1).toInt != 0
  val mutx: Int = if (args.length >= 3) args(2).toInt else -1
  val fileName: String =
    if (args.length >= 4) args(3)
    else if (!dci) "CiPackBase.v"
    else if (mutx >= 0) s"CiPackDciMut$mutx.v"
    else "CiPackDci.v"
  require(mutx < 0 || dci, "MUTX 只对 DCI 档有意义")

  SpinalConfig(
    headerWithDate      = false,
    headerWithRepoHash  = false,
    // 与 NpuTopGen / MultiPassGen / DwLaneGen 同：本代 NPU 一律同步复位。
    defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC),
    oneFilePerComponent = false,
    targetDirectory     = outDir,
    netlistFileName     = fileName
  ).generateVerilog(new CiPackProbe(WIDTH = 8, DCI = dci, MUTX = mutx))
  println(s"CIPACKGEN: DCI=${if (dci) 1 else 0} MUTX=$mutx -> $outDir/$fileName")
  println("CIPACKGEN_DONE")
}
