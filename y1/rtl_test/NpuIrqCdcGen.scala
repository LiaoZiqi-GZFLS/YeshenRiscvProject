import spinal.core._

/** 生成 y1/rtl/NpuIrqCdc.scala 的 Verilog（落盘到 args(0)，例如 y1/gen）。
  *
  * 用法：`runMain NpuIrqCdcGen <outDir>`
  *
  * 两个 header 开关**必须**为 false（与 NpuAxiLiteCdcGen / NpuMemCdcGen / HostRegsGen 同因）：
  *   headerWithDate     —— 否则每次生成都写当天日期，md5 每天都变；
  *   headerWithRepoHash —— 否则 header 里嵌当前 repo HEAD，每提交一次指纹就变一次。
  * oneFilePerComponent = false —— 单文件产出 `gen/NpuIrqCdc.v`，喂 check_dangling.py / iverilog 只要一个文件。
  *
  * ★ 复位：**本模块自带两域 ClockDomain（`resetKind = ASYNC, resetActiveLevel = LOW`）**
  *   —— 与 N3/N4 的 `CdcPipeSp` 同姿。因此这里**不**设 `defaultConfigForClockDomains`：
  *   NpuIrqCdc 没有寄存器落在隐式默认域上，默认域端口会因无负载被自动剪掉。
  */
object NpuIrqCdcGen extends App {
  require(args.length >= 1, "usage: runMain NpuIrqCdcGen <outDir>")
  SpinalConfig(
    headerWithDate      = false,
    headerWithRepoHash  = false,
    oneFilePerComponent = false,
    targetDirectory     = args(0)
  ).generateVerilog(new NpuIrqCdc)
  println("NPUIRQCDCGEN_DONE")
}
