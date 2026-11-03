import spinal.core._

/** 生成 y1/rtl/FusionBuf.scala 的 Verilog（落盘到 args(0)，例如 y1/gen）。
  *
  * 用法：`runMain FusionBufGen <outDir> [C] [WIDTH]`
  *   · 只给 `<outDir>`（**闸门的默认档**）：一次生成**两份功能网表**，供双形状闸门各对一份：
  *       FusionBuf.v     —— 形状 1：C=2、WIDTH=4（默认档，也是 md5 指纹的目标）
  *       FusionBuf_w5.v  —— 形状 2：C=2、WIDTH=5（**非 2 的幂列宽**：log2Up(5)=3 ⇒ 列地址 3 位、
  *                          WORDS=15、aw=4，专门覆盖 `log2Up` 寻址与"列数非 2 的幂"这条路）
  *   · 给了 `[C] [WIDTH]`：只生成一份 `FusionBuf.v`（用例档之外的临时核对用；会覆盖默认档）。
  *
  * 两个 header 开关**必须**为 false（与 DdrMasterGen / DescGen / LineBufferGen 同因）：
  *   headerWithDate     —— 否则每次生成都写当天日期，md5 每天都变；
  *   headerWithRepoHash —— 否则 header 里嵌当前 repo HEAD，**每提交一次指纹就变一次**，
  *                         之后所有"我这次改动生效了吗"的 md5 对比全部沦为废话。
  * oneFilePerComponent = false —— 单文件产出，方便喂给 check_dangling.py 与 iverilog
  *   （`FusionBuf` 没有子块 ⇒ 这个开关其实不影响内容，为与既有生成器同一风格仍显式给出）。
  *
  * ★ 这只是**功能**用例档；报告里的**最坏单元**是 C=64、WIDTH=160（3 行 = 30,720 B = 7 个 DRM36K），
  *   由下面的 `FusionBufWorstGen` 单独生成一份用于核对结构（同一份源码、只差展开期常量）。
  *
  * ★ `inlineRom = true`：`FusionBuf` 里的 `Mem` 带**上电初值 0**（闸门负对照 A 要钉"尚未被写过的
  *   窗口位置读出复位值 0"）。SpinalHDL 默认把这个初值写成一个**外部 `.bin` + `$readmemb`**
  *   （生成 `FusionBuf.v_toplevel_mem.bin` 之类），那样 iverilog 在任意 cwd 下跑都要能找到那个
  *   附带文件 —— 没必要。`inlineRom = true` 让初值**内联**成 `initial begin mem[i] = N'b0; ... end`，
  *   于是 `gen/FusionBuf.v` **自包含**（单文件喂 iverilog / check_dangling.py 即可）。
  */
object FusionBufGen extends App {
  require(args.length == 1 || args.length >= 3,
    "usage: runMain FusionBufGen <outDir> [C] [WIDTH]")

  /** 生成一份 FusionBuf 网表：`<outDir>/<fileName>`，展开期常量 C/WIDTH。 */
  def gen(outDir: String, fileName: String, c: Int, w: Int): Unit = {
    SpinalConfig(
      headerWithDate      = false,
      headerWithRepoHash  = false,
      // ★ C3.18 R3-4：本代 NPU **一律同步复位**（理由与全套范围见 NpuTopGen.scala 的同一行）。
      defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC),
      oneFilePerComponent = false,
      inlineRom           = true,
      targetDirectory     = outDir,
      netlistFileName     = fileName
    ).generateVerilog(FusionBuf(C = c, WIDTH = w))
    println(s"FUSIONBUFGEN: C=$c WIDTH=$w -> $outDir/$fileName")
  }

  val outDir = args(0)
  if (args.length >= 3) {
    // 临时档：只生成一份 FusionBuf.v（覆盖默认档）。
    gen(outDir, "FusionBuf.v", args(1).toInt, args(2).toInt)
  } else {
    // 默认档：双形状，供 run_fusionbuf_ab.sh 各对一份（形状 2 = 非 2 的幂列宽）。
    gen(outDir, "FusionBuf.v",    2, 4)
    gen(outDir, "FusionBuf_w5.v", 2, 5)
  }
  println("FUSIONBUFGEN_DONE")
}

/** 生成**报告最坏单元**那一档的 FusionBuf（C=64、WIDTH=160 ⇒ 3 行 = 30,720 B = 7 个 DRM36K）。
  *
  * 用途：证"同一份源码只差展开期常量就能长出最坏档"，并核对它与功能档**同构**（同样只有一条
  * 可寻址 Mem、同样单写口 + 单同步读口、无逐列移位寄存器）。落盘到 `<outDir>/worst/FusionBuf.v`
  * （单独目录，避免与功能档 gen/FusionBuf.v 撞名）。同样 `inlineRom = true`（自包含）。
  */
object FusionBufWorstGen extends App {
  require(args.length >= 1, "usage: runMain FusionBufWorstGen <outDir>")
  SpinalConfig(
    headerWithDate      = false,
    headerWithRepoHash  = false,
    // ★ C3.18 R3-4：本代 NPU **一律同步复位**（理由与全套范围见 NpuTopGen.scala 的同一行）。
    defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC),
    oneFilePerComponent = false,
    inlineRom           = true,
    targetDirectory     = args(0) + "/worst"
  ).generateVerilog(FusionBuf(C = 64, WIDTH = 160))
  println("FUSIONBUFWORSTGEN_DONE")
}
