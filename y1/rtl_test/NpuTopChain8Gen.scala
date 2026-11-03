import spinal.core._

/** 生成 **L_MAX=8 的 NpuTop 验证网表**（落盘到 args(0)，例如 `y1/gen_chain8`）。
  *
  * 为什么与板级分开：板级 `NpuTop` 取 `LMax = 2`（真表已 de-fuse，链长恒 1；L=2 是
  * `UnitExec` 链结构的最小合法值）。而 `run_nputop_sched_ab.sh` 的 W2 作业是
  * `chainLen = 8` 的**顶层链集成**判据，必须吃 L=8 的展开网表。两者共用同一个
  * `NpuTop(LMax)` 参数化实现，板级网表 `gen/NpuTop.v` 与验证网表 `gen_chain8/NpuTop.v`
  * **分别生成、分别编译**（同名 module 不能进同一次 iverilog 调用）。
  *
  * 生成命令（在 `y1/` 下）：
  *   `printf 'Test/runMain NpuTopChain8Gen D:/code/PDS/VexiiYeshenLinux/y1/gen_chain8\nexit\n' | bash sbt.sh`
  */
object NpuTopChain8Gen extends App {
  require(args.length >= 1, "usage: runMain NpuTopChain8Gen <outDir>")
  SpinalConfig(
    headerWithDate      = false,
    headerWithRepoHash  = false,
    defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC),
    oneFilePerComponent = false,
    inlineRom           = true,
    targetDirectory     = args(0)
  ).generateVerilog(NpuTop(LMax = 8))
  println("NPUTOPCHAIN8GEN_DONE")
}
