import spinal.core._

/** 生成 y1/rtl/BypassExec.scala 的 Verilog `gen/BypassExec.v`（★ C4b-B4）。
  *
  * 为什么需要一份**独立**网表：`BypassExec` 此前只作为 `LayerSched`/`NpuTop` 的**内联子模块**
  * 出现在 `gen/LayerSched.v` / `gen/NpuTop.v` 里（没有自己的文件），而 B4 的布局适配（消费者侧
  * 的 strided read / 平面散射）需要一条**聚焦在 `BypassExec` 口径**的判据线
  * （`rtl_test/LayoutAdaptTb.v` + `tools/run_layoutadapt_ab.sh`）——与 `MultiPassGen`/`DwGen`
  * 给 `MultiPassUnit` 单出一份网表**同因**。
  *
  * 用法：`runMain BypassExecGen <outDir> [C] [WIDTH] [IMG_H_MAX] [NAME]`
  *   缺省 `C=8 / WIDTH=80 / IMG_H_MAX=40`：`WIDTH=80` 对应真网 `MaxPool_25`（`IMG_W=IMG_H=40`
  *   ⇒ 输入宽 = 80）的**行宽**；`IMG_H_MAX=40` ⇒ `MAXPIX = 3200`（够装 `outPix = 1600`）。
  *   ★★ T-S3a.2b：第 5 个参数 `NAME`（缺省 `BypassExec.v`）—— 闸门要一份**与板级同参**的
  *     `WIDTH=34 / IMG_H_MAX=32` 网表（`GEN_W34_NAME = gen/BypassExec_w34.v`，`MAXPIX = 1088`）
  *     ⇒ 本生成器**可以产第二份**文件（`... 8 34 32 BypassExec_w34.v`），两份互不覆盖。
  *     ⚠ 这不是"第二张网表"（spec §7 待裁决 1 否掉了编译期开关）：`WIDTH/IMG_H_MAX` 只是**分配**
  *     口径（`outMem` 的行数上限），两条路径（整层 / tile）在**同一份**网表里由运行期二选一。
  *
  * 两个 header 开关**必须**为 false（与 BypassGen/MultiPassGen/SliceGen 同因：`headerWithDate`
  *   会让 md5 每天变、`headerWithRepoHash` 会让它每提交一次就变）；
  * `oneFilePerComponent=false` ⇒ 单文件产出（`BypassExec` + 它例化的 `DdrMaster` 与四个单元、
  *   `MaxPoolUnit/ResizeUnit/AddUnit/SigmoidUnit` 全落一个文件）；`inlineRom=true` ⇒ 各 `Mem`
  *   的上电初值内联（`gen/BypassExec.v` 自包含，`vvp` 在工作目录里不会去找 `.bin`）。
  */
object BypassExecGen extends App {
  require(args.length >= 1, "usage: runMain BypassExecGen <outDir> [C] [WIDTH] [IMG_H_MAX] [NAME]")
  val outDir = args(0)
  val c:     Int = if (args.length >= 2) args(1).toInt else 8
  val width: Int = if (args.length >= 3) args(2).toInt else 80
  val hmax:  Int = if (args.length >= 4) args(3).toInt else 40
  /** ★★ T-S3a.2b：产出文件名（缺省 `BypassExec.v`；闸门要的板级同参档传 `BypassExec_w34.v`）。 */
  val name: String = if (args.length >= 5) args(4) else "BypassExec.v"

  SpinalConfig(
    headerWithDate      = false,
    headerWithRepoHash  = false,
    // ★ C3.18 R3-4：本代 NPU **一律同步复位**（理由与全套范围见 NpuTopGen.scala 的同一行）。
    defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC),
    oneFilePerComponent = false,
    inlineRom           = true,
    targetDirectory     = outDir,
    netlistFileName     = name
  ).generateVerilog(new BypassExec(C = c, WIDTH = width, IMG_H_MAX = hmax))
  println(s"BYPASSEXECGEN: C=$c WIDTH=$width IMG_H_MAX=$hmax -> $outDir/$name")
  println("BYPASSEXECGEN_DONE")
}
