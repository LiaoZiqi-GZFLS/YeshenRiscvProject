import spinal.core._

/** 生成 y1/rtl 的 **depthwise（`0x03`）单元**网表 `gen/DwUnit.v`（C4a.6）。
  *
  * ============================ 冻结口径（C4a.6 Step 1，逐字；要改走 spec 修订） ============================
  * ```
  * depthwise = GROUP = C_in = C_out；C≤8 一趟；C>8 拆趟（每趟 8 通道）
  * ```
  *
  * ============================ 为什么 depthwise 单元 = `MultiPassUnit` ============================
  * `C > 8` 的 depthwise 走 **C4a.5 的多趟通路**（`rtl/MultiPassUnit.scala` + `rtl/PartialSumBuf.scala`）；
  * `C ≤ 8`（如真表的 `C=4`）是**同一通路的一趟**（`ceil(4/8) = 1` 个 co-block × 1 个 ci-block）。
  * 于是本生成器**逐字复用** `MultiPassUnit`（不新写一行算术）—— 出来的网表与 `MultiPassGen` 的
  * `gen/MultiPassUnit.v` **逐字节相同**（同参数、同源码；`run_dw_ab.sh` 用 md5 对这条做**结构性断言**
  * ⇒ "没有第二条算术通路"不是口号而是可判的指纹）。
  *
  * depthwise 与一般宽层在**数据通路**上无差别，差别只在**趟调度**（由装置/驱动方给）：
  *   · depthwise 的趟是**对角趟**：第 `b` 个 co-block 只吃第 `b` 个 ci-block（`GROUP == C_IN == C_OUT`
  *     ⇒ `co` 与 `ci` 同块才同组）；趟数 = `ceil(C/8)`（不是 `ceil(C_in/8)×ceil(C_out/8)`）。
  *   · 跨块的趟其权重瓦片**全 0**（掩码规则给出）⇒ 贡献恰 0 ⇒ **对角趟与一般趟给出同一份输出**
  *     （`run_dw_ab.sh` 对同一输入逐字节断言这一条 = "与 C4a.5 共用同一套算术"）。
  *
  * 用法：`runMain DwGen <outDir> [WIDTH] [PIXMAX] [NCOB]`
  *   缺省 `WIDTH=8 / PIXMAX=32 / NCOB=8` —— 与 `MultiPassGen` 缺省**一致**（否则 md5 结构性断言不成立）。
  *
  * 两个 header 开关**必须**为 false（与 MultiPassGen / SliceGen / UnitExecGen 同因：
  * `headerWithDate` 会让 md5 每天变、`headerWithRepoHash` 会让它每提交一次就变）；
  * `oneFilePerComponent=false` ⇒ 单文件产出（`MultiPassUnit` + `Conv3x3Slice` + `PartialSumBuf` … 在一个
  * 文件里），`inlineRom=true` ⇒ 部分和缓冲的上电初值 0 内联（`gen/DwUnit.v` 自包含）。
  */
object DwGen extends App {
  require(args.length >= 1, "usage: runMain DwGen <outDir> [WIDTH] [PIXMAX] [NCOB]")
  val outDir = args(0)
  val width:  Int = if (args.length >= 2) args(1).toInt else 8
  val pixmax: Int = if (args.length >= 3) args(2).toInt else 32
  val ncob:   Int = if (args.length >= 4) args(3).toInt else 8
  require(width >= 3, s"WIDTH=$width 太小：3x3 窗口至少要 3 列")

  // ★ 缺省参数必须与 MultiPassGen 一致 —— `run_dw_ab.sh` 用它做"同一份算术"的 md5 结构性断言。
  SpinalConfig(
    headerWithDate      = false,
    headerWithRepoHash  = false,
    // ★ C3.18 R3-4：本代 NPU **一律同步复位**（理由与全套范围见 NpuTopGen.scala 的同一行）。
    defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC),
    oneFilePerComponent = false,
    inlineRom           = true,
    targetDirectory     = outDir,
    netlistFileName     = "DwUnit.v"
  ).generateVerilog(new MultiPassUnit(WIDTH = width, PIXMAX = pixmax, NCOB = ncob))
  println(s"DWGEN: depthwise == MultiPassUnit (diagonal passes, GROUP=C_IN=C_OUT) WIDTH=$width PIXMAX=$pixmax NCOB=$ncob -> $outDir/DwUnit.v")
  println("DWGEN_DONE")
}
