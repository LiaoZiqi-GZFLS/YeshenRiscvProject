import spinal.core._

/** 生成 y1/rtl/NpuResetSync.scala 的 Verilog（落盘到 args(0)，例如 y1/gen）。
  *
  * 用法：`runMain NpuResetSyncGen <outDir>`
  *
  * 两个 header 开关**必须**为 false（与 NpuIrqCdcGen / NpuAxiLiteCdcGen 同因）。
  * oneFilePerComponent = false —— 单文件产出 `gen/NpuResetSync.v`。
  *
  * ★ 复位：**本模块自带两域 ClockDomain（`resetKind = ASYNC, resetActiveLevel = HIGH`）**
  *   —— 因为 `asyncRst` 是**高有效**异步置位（板级 `async_reset` 语义）。因此这里**不**设
  *   `defaultConfigForClockDomains`：NpuResetSync 没有寄存器落在隐式默认域上。
  */
object NpuResetSyncGen extends App {
  require(args.length >= 1, "usage: runMain NpuResetSyncGen <outDir>")
  SpinalConfig(
    headerWithDate      = false,
    headerWithRepoHash  = false,
    oneFilePerComponent = false,
    targetDirectory     = args(0)
  ).generateVerilog(new NpuResetSync(stages = 2))
  println("NPURESETSYNCGEN_DONE")
}
