name := "y1_npu"

version := "0.1"

scalaVersion := "2.12.18"

fork := true

Compile / scalaSource := baseDirectory.value / "rtl"
Test    / scalaSource := baseDirectory.value / "rtl_test"

libraryDependencies ++= Seq(
  "com.github.spinalhdl" % "spinalhdl-core_2.12" % "1.15.0",
  "com.github.spinalhdl" % "spinalhdl-lib_2.12"  % "1.15.0",
  compilerPlugin("com.github.spinalhdl" % "spinalhdl-idsl-plugin_2.12" % "1.15.0"),
  "com.google.code.gson" % "gson" % "2.7"
)
