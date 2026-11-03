import spinal.core._

/** 生成 y1/rtl/MultiPassUnit.scala（+ 其例化的 `Conv3x3Slice` / `PartialSumBuf` / …）的 Verilog。
  *
  * 用法：`runMain MultiPassGen <outDir> [WIDTH] [PIXMAX] [NCOB] [PSW]`
  *   缺省 `WIDTH=8 / PIXMAX=32 / NCOB=8 / PSW=32` —— 正好覆盖 C4a.4 真表里**最宽**的形状
  *   （`C_in=64 / C_out=64` ⇒ 8 个 `ci` 块 × 8 个 `co` 块；`H=4,W=8` ⇒ 每段 32 个像素）。
  *   ★★ §3.7：`PSW` = 部分和行宽（bit，缺省 **32**；可证界 `9,363,456 < 2^24`）。
  *   `PSW=24` 是 **负对照档**（低于可证界）⇒ `tools/run_psbound_ab.sh` 用它证"这条界真在起作用"。
  *   `tools/run_multipass_ab.sh` 吃的就是这份网表；它按 plusarg 给 `+IW`/`+ROWB` 对账（宽度钉死）。
  *
  * 两个 header 开关**必须**为 false（与 SliceGen / FusionBufGen / UnitExecGen 同因）：
  *   headerWithDate     —— 否则每次生成都写当天日期，md5 每天都变；
  *   headerWithRepoHash —— 否则 header 里嵌当前 repo HEAD，每提交一次指纹就变一次。
  * oneFilePerComponent = false —— 单文件产出：`MultiPassUnit` 连同它例化的
  *   `Conv3x3Slice`（+ GroupedMacArray / WeightStore / LineBuffer / MacArray）与 `PartialSumBuf`
  *   全落进 `gen/MultiPassUnit.v`。这样 check_dangling.py 只喂一个文件就既看到定义又看到例化，
  *   iverilog 也只编译这一个网表文件（否则会和 gen/Conv3x3Slice.v 撞重名 module）。
  * inlineRom = true —— `PartialSumBuf` 里的 `Mem` 带上电初值 0；内联成 `initial begin mem[i]=0; ... end`
  *   让 `gen/MultiPassUnit.v` **自包含**（否则会另发一个 `.bin`，vvp 在工作目录里找不到就读全 X，
  *   而"第 1 趟读到的是上电初值 0"正是多趟累加的**结构性前提**，见 `PartialSumBuf.scala` 文件头）。
  *   ★ 这一条也是本项目既有的"负对照 B（缓冲初值非 0 ⇒ 必红）"能**外科式**地打在初值块上的原因。
  */
object MultiPassGen extends App {
  require(args.length >= 1, "usage: runMain MultiPassGen <outDir> [WIDTH] [PIXMAX] [NCOB] [PSW]")
  val outDir = args(0)
  val width:  Int = if (args.length >= 2) args(1).toInt else 8
  val pixmax: Int = if (args.length >= 3) args(2).toInt else 32
  val ncob:   Int = if (args.length >= 4) args(3).toInt else 8
  val psw:    Int = if (args.length >= 5) args(4).toInt else 32
  require(width >= 3, s"WIDTH=$width 太小：3x3 窗口至少要 3 列")

  SpinalConfig(
    headerWithDate      = false,
    headerWithRepoHash  = false,
    // ★ C3.18 R3-4：本代 NPU **一律同步复位**（理由与全套范围见 NpuTopGen.scala 的同一行）。
    defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC),
    oneFilePerComponent = false,
    inlineRom           = true,
    targetDirectory     = outDir,
    netlistFileName     = "MultiPassUnit.v"
  ).generateVerilog(new MultiPassUnit(WIDTH = width, PIXMAX = pixmax, NCOB = ncob, PSW = psw))
  println(s"MULTIPASSGEN: WIDTH=$width PIXMAX=$pixmax NCOB=$ncob PSW=$psw -> $outDir/MultiPassUnit.v")
  println("MULTIPASSGEN_DONE")
}
