import chisel3._
import circt.stage.ChiselStage
import chisel3.stage.ChiselGeneratorAnnotation

// ============================================================================
// `YeshenSocGlue` 的 RTL 生成入口（产物 `rtl/YeshenSocGlue.v`，供板级顶层与
// `rtl/vexiiriscv/VexiiRiscv.v` 组装，两者都进 PDS 工程）。
//
// 用法（Windows 上必须打 assembly jar 再跑：`scala-cli run` 会撞 CreateProcess error 206
// "命令行过长"）：
//   SC="/c/Users/Ziqi/AppData/Local/Coursier/data/bin/scala-cli.bat"
//   "$SC" --power package src --assembly -o YeshenSocGlue.jar --main-class YeshenSocGlueMain -f
//   java -jar YeshenSocGlue.jar      # 产出 rtl/YeshenSocGlue.v
//
// 写法与 firtool 选项**逐字照抄** `src/NaxMiniGlueMain.scala`（同一套 Chisel 6.7.0 / firtool，
// PDS 已验证过的那一组；其中 `disallowLocalVariables` / `disallowPackedArrays` /
// `disable-all-randomization` 正是本任务要求的那三条）。
// ============================================================================

private object YeshenSocFirtool {
  def opts(out: String) = Array(
    "-disable-all-randomization",
    "-strip-debug-info",
    "-strip-fir-debug-info",
    "-O=release",
    "--ignore-read-enable-mem",
    "--lower-memories",
    "--lowering-options=noAlwaysComb, disallowPackedArrays, disallowLocalVariables, disallowMuxInlining, disallowExpressionInliningInPorts",
    s"-o=$out"
  )
}

object YeshenSocGlueMain extends App {
  println("Generating YeshenSocGlue...")
  (new ChiselStage).execute(
    Array("--target", "verilog", "-td", "build_glue/"),
    Seq(ChiselGeneratorAnnotation(() => new YeshenSocGlue)) ++
      YeshenSocFirtool.opts("rtl/YeshenSocGlue.v").map(circt.stage.FirtoolOption(_))
  )
}
