import spinal.core._

/** 生成 `rtl_test/DwLaneProbe.scala` 的 Verilog（NPU v2 切片 B-1 的独立探针网表）。
  *
  * 用法：`runMain DwLaneGen <outDir> <MODE> [WIDTH] [MUTX] [fileName]`
  *   MODE  0 = BEFORE（as-built：广播 x、9 拍/像素）      -> `DwLaneBefore.v`
  *   MODE  1 = AFTER2（tap-inner 2 拍/像素，无新乘法器）  -> `DwLaneAfter2.v`
  *   MODE  2 = AFTER1（tap-inner + 第 9 抽头行，1 拍/像素）-> `DwLaneAfter1.v`
  *   MUTX ≥ 0 = **外科锚**：lane MUTX 的 x 路由改错（见 `DwLaneProbe` 文件头）
  *              -> `DwLaneAfter1Mut<N>.v`（同名模块 `DwLaneProbe`，TB 一次只编译一份）
  *   三条档的**模块名都是 `DwLaneProbe`** ⇒ 与 SliceGen 的 `Conv3x3Slice{,_g4,_g8}` 同一约定：
  *   一份网表一次仿真，闸门按"哪一档"分别喂给同一个 TB。
  *
  * 两个 header 开关必须为 false（与 MacArrayGen / MultiPassGen / SliceGen 同因：否则 md5 每天/每提交都变）；
  * `oneFilePerComponent = false` ⇒ DwLaneProbe 连同 LineBuffer / WeightStore / MacArray 全落进一个文件
  * （check_dangling.py 与 iverilog 都只看这一个文件）。
  */
object DwLaneGen extends App {
  require(args.length >= 2, "usage: runMain DwLaneGen <outDir> <MODE> [WIDTH] [MUTX] [fileName]")
  val outDir = args(0)
  val mode: Int = args(1).toInt
  val width: Int = if (args.length >= 3) args(2).toInt else 8
  val mutx: Int = if (args.length >= 4) args(3).toInt else -1
  val fileName: String =
    if (args.length >= 5) args(4)
    else mode match {
      case 0 => "DwLaneBefore.v"
      case 1 => "DwLaneAfter2.v"
      case 2 => if (mutx >= 0) s"DwLaneAfter1Mut$mutx.v" else "DwLaneAfter1.v"
      case _ => "DwLaneProbe.v"
    }
  require(width >= 3, s"WIDTH=$width 太小：3x3 窗口至少要 3 列")
  require(mode == 0 || mode == 1 || mode == 2, "MODE ∈ {0,1,2}")

  SpinalConfig(
    headerWithDate      = false,
    headerWithRepoHash  = false,
    // 与 NpuTopGen / MultiPassGen 同：本代 NPU 一律同步复位。
    defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC),
    oneFilePerComponent = false,
    targetDirectory     = outDir,
    netlistFileName     = fileName
  ).generateVerilog(new DwLaneProbe(WIDTH = width, MODE = mode, MUTX = mutx))
  println(s"DWLANEGEN: MODE=$mode WIDTH=$width MUTX=$mutx -> $outDir/$fileName")
  println("DWLANEGEN_DONE")
}
