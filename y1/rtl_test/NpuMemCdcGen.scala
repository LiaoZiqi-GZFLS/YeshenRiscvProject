import spinal.core._

/** 生成 y1/rtl/NpuMemCdc.scala 的 Verilog（落盘到 args(0)，例如 y1/gen）。
  *
  * 用法：`runMain NpuMemCdcGen <outDir>`
  *
  * 两个 header 开关**必须**为 false（与 NpuAxiLiteCdcGen / HostRegsGen / NpuTopGen 同因）：
  *   headerWithDate     —— 否则每次生成都写当天日期，md5 每天都变；
  *   headerWithRepoHash —— 否则 header 里嵌当前 repo HEAD，**每提交一次指纹就变一次**。
  * oneFilePerComponent = false —— 单文件产出：`NpuMemCdc` 连同它例化的 5 条 `NpuMemCdcFifo`
  *   （每条内含 4 条 `CdcPipeSp`；awPipe/wPipe/arPipe/bPipe/rPipe 载荷类型不同 ⇒ 展开成多份同族模块）
  *   全落进 `gen/NpuMemCdc.v`，喂给 check_dangling.py / iverilog 都只要一个文件。
  *   `CdcPipeSp` 类本身**复用于** `y1/rtl/NpuAxiLiteCdc.scala`（N3）—— 单例真源；
  *   两份网表各自单文件落盘，因此不会互相撞重名 module（NpuMemCdc.v 里没有 NpuAxiLiteCdc）。
  *
  * ★ 复位：**本模块不自带寄存器**（顶层全是组合搬运），两个域的寄存器都在 5 份 `CdcPipeSp`
  *   内部（各自 `resetKind = ASYNC, resetActiveLevel = LOW`）—— 与 `CDCPipe` / N3 同姿。
  *   因此这里**不**设 `defaultConfigForClockDomains`：NpuMemCdc 没有寄存器落在隐式默认域上，
  *   默认域的 clk/reset 端口会因无负载被自动剪掉 —— 装置按下面的端口表接线即可。
  */
object NpuMemCdcGen extends App {
  require(args.length >= 1, "usage: runMain NpuMemCdcGen <outDir>")
  SpinalConfig(
    headerWithDate      = false,
    headerWithRepoHash  = false,
    oneFilePerComponent = false,
    targetDirectory     = args(0)
  ).generateVerilog(new NpuMemCdc(addrW = 28, dataW = 64, idW = 4))
  println("NPUMEMCDCGEN_DONE")
}
