import config.Config
import conv.compute.ConvConfig
import shape.ShapeConfig
import spinal.core._

/** M0 生成入口：产出 Npu 的 Verilog。
  * 参数 1 = 输出目录（绝对路径）；系统 CWD 是 ai_npu_exp/port，所以必须显式传绝对路径。
  * 确定性判据（B5–B8 靠它判断改动是否真的生效）要求头里既不写日期、也不写仓库 HEAD：
  *   headerWithDate     = false  ⇒ 去掉 "// Date : ..."
  *   headerWithRepoHash = false  ⇒ 去掉 "// Git hash : <HEAD>"（否则每次 commit 后 md5 都变，
  *                                  判据会退化成永真、负对照做不出来）
  */
object GenNpu extends App {
    require(args.nonEmpty, "usage: GenNpu <absolute-output-dir>")
    val outDir = args(0)
    val clockCfg = ClockDomainConfig(resetKind = SYNC, resetActiveLevel = HIGH)
    SpinalConfig(
        headerWithDate = false,
        headerWithRepoHash = false,
        oneFilePerComponent = false,
        defaultConfigForClockDomains = clockCfg,
        targetDirectory = outDir
    ).generateVerilog(new Npu(
        ConvConfig(8, 16, 16, 12, 4096, 512, 10, 10, 2048),
        ShapeConfig(8, 16, 640, 12, 2048)
    ))
    println("GENNPU_DONE -> " + outDir)
}
