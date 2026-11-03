import spinal.core._

/** 生成 y1/rtl/NpuAxiLiteCdc.scala 的 Verilog（落盘到 args(0)，例如 y1/gen）。
  *
  * 用法：`runMain NpuAxiLiteCdcGen <outDir>`
  *
  * 两个 header 开关**必须**为 false（与 HostRegsGen / NpuTopGen / UnitExecGen 同因）：
  *   headerWithDate     —— 否则每次生成都写当天日期，md5 每天都变；
  *   headerWithRepoHash —— 否则 header 里嵌当前 repo HEAD，**每提交一次指纹就变一次**，
  *                         之后所有"我这次改动生效了吗"的 md5 对比全部沦为废话。
  * oneFilePerComponent = false —— 单文件产出：`NpuAxiLiteCdc` 连同它例化的 5 份 `CdcPipeSp`
  *   全落进 `gen/NpuAxiLiteCdc.v`，喂给 check_dangling.py / iverilog 都只要一个文件
  *   （否则 5 份 CdcPipeSp 会各自落盘并与别的网表撞重名 module）。
  *
  * ★ 复位：**本模块自带两域 ClockDomain（`resetKind = ASYNC, resetActiveLevel = LOW`）**
  *   —— 与 `src/soc/CDCQueue.scala` 的 `CDCPipe`（异步、低有效）同姿，见 RTL 文件头"复位口径"。
  *   因此这里**不**设 `defaultConfigForClockDomains`（它管的是隐式默认域）：
  *   NpuAxiLiteCdc 没有任何寄存器落在隐式默认域上（全在两个显式域里），
  *   默认域的 clk/reset 端口会因无负载被自动剪掉 —— 装置按下面的端口表接线即可。
  */
object NpuAxiLiteCdcGen extends App {
  require(args.length >= 1, "usage: runMain NpuAxiLiteCdcGen <outDir>")
  SpinalConfig(
    headerWithDate      = false,
    headerWithRepoHash  = false,
    oneFilePerComponent = false,
    targetDirectory     = args(0)
  ).generateVerilog(new NpuAxiLiteCdc(addrW = 32))
  println("NPUAXILITECDCGEN_DONE")
}
