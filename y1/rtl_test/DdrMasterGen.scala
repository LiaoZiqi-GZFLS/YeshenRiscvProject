import spinal.core._

/** 生成 y1/rtl/DdrMaster.scala 的 Verilog（落盘到 args(0)，例如 y1/gen）。
  *
  * 两个 header 开关**必须**为 false（与 MacArrayGen / LineBufferGen / WeightStoreGen / HostRegsGen 同因）：
  *   headerWithDate     —— 否则每次生成都写当天日期，md5 每天都变；
  *   headerWithRepoHash —— 否则 header 里嵌当前 repo HEAD，**每提交一次指纹就变一次**，
  *                         之后所有"我这次改动生效了吗"的 md5 对比全部沦为废话。
  * oneFilePerComponent = false —— 单文件产出，方便喂给 check_dangling.py 与 iverilog。
  *
  * 形状参数用默认的 DdrMasterConfig()（ADDR_W=28 / DATA_W=64 / ID_W=4 / CHUNK_BYTES=128）：
  * 这三条正是 P1/P3 钉死的形状，闸门与内存模型都按这一份写，不另开变体。
  */
object DdrMasterGen extends App {
  require(args.length >= 1, "usage: runMain DdrMasterGen <outDir>")
  SpinalConfig(
    headerWithDate      = false,
    headerWithRepoHash  = false,
    // ★ C3.18 R3-4：本代 NPU **一律同步复位**（理由与全套范围见 NpuTopGen.scala 的同一行）。
    defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC),
    oneFilePerComponent = false,
    targetDirectory     = args(0)
  ).generateVerilog(new DdrMaster(DdrMasterConfig()))
  // ★ L2b 负对照档：rqDepth=1（结构性退化为逐块串行；闸门断言 outstanding 峰值回到 1）。
  SpinalConfig(
    headerWithDate      = false,
    headerWithRepoHash  = false,
    defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC),
    oneFilePerComponent = false,
    targetDirectory     = args(0),
    netlistFileName     = "DdrMaster_q1.v"
  ).generateVerilog(new DdrMaster(DdrMasterConfig(), rqDepth = 1))
  println("DDRMASTERGEN: q1 -> " + args(0) + "/DdrMaster_q1.v")
  println("DDRMASTERGEN_DONE")
}
