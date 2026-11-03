import spinal.core._

/** 生成 y1/rtl/DmaEngine.scala 的 Verilog（落盘到 args(0)，例如 y1/gen）。
  *
  * 两个 header 开关**必须**为 false（与 DdrMasterGen / MacArrayGen / HostRegsGen 同因）：
  *   headerWithDate     —— 否则每次生成都写当天日期，md5 每天都变；
  *   headerWithRepoHash —— 否则 header 里嵌当前 repo HEAD，**每提交一次指纹就变一次**。
  * oneFilePerComponent = false —— 单文件产出（含子模块 `DmaDdrMaster`，即每个通道那台
  *   `DdrMaster` 的**改名实例**），方便喂给 check_dangling.py 与 iverilog。
  *   ★ 子模块名为 `DmaDdrMaster` 而非 `DdrMaster`：**这是 Phase-2b fix 的承重点** —— `DmaEngine.v`
  *     与 `NpuTop.v` 同处一个板级设计，若两边的内联子模块都叫 `DdrMaster`，PDS compile 报
  *     `E: Verilog-4146: Duplicate module name 'DdrMaster'`。改名口径见 `y1/rtl/DmaEngine.scala`
  *     的 `eng` 定义处（`defName = "DmaDdrMaster"`）与 `DdrMaster.scala` 的类头。判据：
  *     `y1/tools/check_dup_modules.py`。
  *
  * ★ resetKind = SYNC：与 `DdrMasterGen` **同一条**（本代 NPU/引擎一律同步复位）。
  *   这一点在本文件里是**承重**的：`DmaEngine` 给每个通道造了一个**同频、复位 = 系统复位 || 通道 abort 复位**
  *   的 `ClockDomain`（见 DmaEngine.scala §B），子域的 config 直接抄 `ClockDomain.current.config`
  *   ⇒ 这里若不设 SYNC，子域就会继承默认的 ASYNC 复位，`DdrMaster` 的 `Reg init` 语义会变。
  *
  * 形状用 `DmaEngineConfig()` 默认：NCH=2 / ADDR_W=28 / DATA_W=64 / ID_W=4 / CHUNK_BYTES=128。
  * 闸门（y1/rtl_test/DmaEngineTb.v + y1/tools/run_dmaeng_ab.sh）按这一份写。
  */
object DmaEngineGen extends App {
  require(args.length >= 1, "usage: runMain DmaEngineGen <outDir>")
  SpinalConfig(
    headerWithDate     = false,
    headerWithRepoHash = false,
    defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC),
    oneFilePerComponent = false,
    targetDirectory    = args(0)
  ).generateVerilog(new DmaEngine(DmaEngineConfig(ADDR_W = 30)))
  println("DMAENGINEGEN_DONE")
}
