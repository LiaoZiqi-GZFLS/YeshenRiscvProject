import chisel3._
import circt.stage.ChiselStage
import chisel3.stage.ChiselGeneratorAnnotation

// ============================================================================
// `NaxMiniGlue` 的 RTL 生成入口（产物 `rtl/NaxMiniGlue.v`，供 Task 8 的
// `board/nax_mini_soc.v` 与 `rtl/NaxSocMini.v` 组装，两者都进 PDS 工程）。
//
// 用法（Windows 上必须打 assembly jar 再跑：`scala-cli run` 会撞 CreateProcess error 206
// "命令行过长"）：
//   cd /d/code/PDS
//   SC="/c/Users/Ziqi/AppData/Local/Coursier/data/bin/scala-cli.bat"
//   "$SC" --power package NaxYeshenLinux/src --assembly -o NaxYeshenLinux/NaxMiniGlue.jar \
//        --main-class NaxMiniGlueMain -f
//   cd NaxYeshenLinux && java -jar NaxMiniGlue.jar      # 产出 rtl/NaxMiniGlue.v
//
// 为什么不用 `ChiselStage.emitSystemVerilogFile`：它把产物固定命名为 `<模块名>.sv`，
// 而本工程的交付名是 `rtl/NaxMiniGlue.v`（plan Task 8 按这个名字组装/约束）。
// 这里走 `ChiselStage.execute` + firtool 的 `-o=`，与 `NaxYeshenSoC/src/NaxMain.scala`
// 同一套写法（同一个 Chisel 6.7.0 / firtool），firtool 选项也照抄它（PDS 已验证过的那一组；
// 其中 `disallowLocalVariables` / `disallowPackedArrays` / `disable-all-randomization`
// 正是本任务要求的那三条）。
// ============================================================================

private object NaxMiniFirtool {
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

object NaxMiniGlueMain extends App {
  println("Generating NaxMiniGlue...")
  (new ChiselStage).execute(
    Array("--target", "verilog", "-td", "build_glue/"),
    Seq(ChiselGeneratorAnnotation(() => new NaxMiniGlue)) ++
      NaxMiniFirtool.opts("rtl/NaxMiniGlue.v").map(circt.stage.FirtoolOption(_))
  )
}
