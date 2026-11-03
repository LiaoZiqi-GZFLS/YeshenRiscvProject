import spinal.core._

/** 生成 y1/rtl/ 四个旁路算子（MaxPoolUnit / ResizeUnit / AddUnit / SigmoidUnit）的 Verilog
  * （落盘到 args(0)，例如 y1/gen）。
  *
  * 用法：`runMain BypassGen <outDir> [C] [W]`
  *   · 只给 `<outDir>`（**闸门的默认档**）：一次生成**八个功能网表**，供 4 算子 x 2 形状的闸门各对一份：
  *       MaxPoolUnit.v      / ResizeUnit.v       —— 形状 1：C=2、W=4（默认档，也是 md5 指纹目标）
  *       MaxPoolUnit_w6.v   / ResizeUnit_w6.v    —— 形状 2：C=2、W=6（**非 2 的幂列宽**：
  *                                                  log2Up(6)=3 ⇒ 列地址/源列号 3 位、
  *                                                  MaxPool 的 accRow 有 3 项、Resize 的输出计数
  *                                                  要数到 24（4W=24），覆盖"列数非 2 的幂"这条路）
  *       AddUnit.v          / SigmoidUnit.v      —— 形状 1：C=2、W=4（C3.7 新增的两个算子）
  *       AddUnit_w5.v       / SigmoidUnit_w6.v   —— 形状 2：C=2；Add 用 **W=5**（非 2 的幂，且闸门
  *                                                  那一档用**奇数 H=3** —— 这两个算子是逐点的、没有
  *                                                  "行对/列配对"结构 ⇒ 奇数 H 合法，装置的偶数 H
  *                                                  硬约束**只对 MaxPool/Resize 生效**，这一档就是
  *                                                  用来证明那个放宽是**真的**放宽）、
  *                                                  Sigmoid 用 W=6（覆盖非 2 的幂列宽下的列计数）
  *   · 给了 `[C] [W]`：只生成两份 `MaxPoolUnit.v` / `ResizeUnit.v`（用例档之外的临时核对用；会覆盖默认档）。
  *
  * ★ C3.7 的两个新算子**没有内部状态**（只喂 imgC/imgW 自报端口）⇒ 形状参数对它们的数据通路
  *   没有影响；保留"两个形状"是为了与 MaxPool/Resize 同一套闸门结构、并顺带把自报端口钉两遍。
  *
  * 两个 header 开关**必须**为 false（与 LineBufferGen / FusionBufGen / DescGen 同因）：
  *   headerWithDate     —— 否则每次生成都写当天日期，md5 每天都变；
  *   headerWithRepoHash —— 否则 header 里嵌当前 repo HEAD，**每提交一次指纹就变一次**，
  *                         之后所有"我这次改动生效了吗"的 md5 对比全部沦为废话。
  * oneFilePerComponent = false —— 单文件产出，方便喂给 check_dangling.py 与 iverilog。
  *
  * 两个形状的 W 都取**偶数**：MaxPoolUnit 的 `require(W % 2 == 0)` 会当场拒绝奇数（这是刻意的：
  * 2x2/stride2 的列配对在奇数 W 上会跨行错位），ResizeUnit 本身对 W 无奇偶要求（形状 2 的 W=6
  * 只是不巧也是偶数；Resize 的突变体预测需要偶数 W，见 tools/bypass_ref.py）。
  */
object BypassGen extends App {
  require(args.length == 1 || args.length >= 3,
    "usage: runMain BypassGen <outDir> [C] [W]")

  /** 生成一份网表：`<outDir>/<fileName>`，展开期常量由调用方给。 */
  def gen(outDir: String, fileName: String, comp: => Component): Unit = {
    SpinalConfig(
      headerWithDate      = false,
      headerWithRepoHash  = false,
      // ★ C3.18 R3-4：本代 NPU **一律同步复位**（理由与全套范围见 NpuTopGen.scala 的同一行）。
      defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC),
      oneFilePerComponent = false,
      targetDirectory     = outDir,
      netlistFileName     = fileName
    ).generateVerilog(comp)
    println(s"BYPASSGEN: $fileName")
  }

  val outDir = args(0)
  if (args.length >= 3) {
    val c = args(1).toInt
    val w = args(2).toInt
    gen(outDir, "MaxPoolUnit.v", new MaxPoolUnit(C = c, WIDTH = w))
    gen(outDir, "ResizeUnit.v",  new ResizeUnit(C = c, WIDTH = w))
  } else {
    gen(outDir, "MaxPoolUnit.v",    new MaxPoolUnit(C = 2, WIDTH = 4))
    gen(outDir, "MaxPoolUnit_w6.v", new MaxPoolUnit(C = 2, WIDTH = 6))
    gen(outDir, "ResizeUnit.v",     new ResizeUnit(C = 2, WIDTH = 4))
    gen(outDir, "ResizeUnit_w6.v",  new ResizeUnit(C = 2, WIDTH = 6))
    // ---- C3.7：Add（双输入饱和加）与 Sigmoid（Q3.4 -> Q0.7 查表）----
    gen(outDir, "AddUnit.v",        new AddUnit(C = 2, WIDTH = 4))
    gen(outDir, "AddUnit_w5.v",     new AddUnit(C = 2, WIDTH = 5))
    gen(outDir, "SigmoidUnit.v",    new SigmoidUnit(C = 2, WIDTH = 4))
    gen(outDir, "SigmoidUnit_w6.v", new SigmoidUnit(C = 2, WIDTH = 6))
  }
  println("BYPASSGEN_DONE")
}
