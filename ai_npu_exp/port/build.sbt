name := "ai_npu_exp_m0"

version := "0.1"

scalaVersion := "2.12.18"

fork := true

Compile / scalaSource := baseDirectory.value / ".." / "rtl_src"
Test    / scalaSource := baseDirectory.value / ".." / "rtl_test"
Compile / unmanagedSourceDirectories += baseDirectory.value / ".." / "rtl_gen"

libraryDependencies ++= Seq(
  "com.github.spinalhdl" % "spinalhdl-core_2.12" % "1.15.0",
  "com.github.spinalhdl" % "spinalhdl-lib_2.12"  % "1.15.0",
  compilerPlugin("com.github.spinalhdl" % "spinalhdl-idsl-plugin_2.12" % "1.15.0"),
  "com.google.code.gson" % "gson" % "2.7"
)
