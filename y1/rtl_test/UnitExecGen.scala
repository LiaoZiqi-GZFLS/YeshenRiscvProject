import spinal.core._

/** 生成 y1/rtl/UnitExec.scala 的 Verilog（落盘到 args(0)，例如 y1/gen）。
  *
  * 用法：`runMain UnitExecGen <outDir>`（**无形状参数**：S2 的几何是本任务的**定点用例**，
  * 写死在这里 —— `C = 8`（= DdrMaster 一拍字节数）、`WIDTH = 64`（行宽，与描述符 `IMG_W` 对账）。
  *
  * 两个 header 开关**必须**为 false（与 SliceGen / FusionBufGen / DdrMasterGen / DescGen 同因）：
  *   headerWithDate     —— 否则每次生成都写当天日期，md5 每天都变；
  *   headerWithRepoHash —— 否则 header 里嵌当前 repo HEAD，**每提交一次指纹就变一次**，
  *                         之后所有"我这次改动生效了吗"的 md5 对比全部沦为废话。
  * oneFilePerComponent = false —— 单文件产出：`UnitExec` 连同它例化的
  *   `DdrMaster` / `Conv3x3Slice`（+ GroupedMacArray / WeightStore / LineBuffer / MacArray）/ `FusionBuf`
  *   全落进 `gen/UnitExec.v`。这样 check_dangling.py 只喂一个文件就既看到定义又看到例化，
  *   iverilog 也只编译这一个网表文件（否则会和 gen/FusionBuf.v / gen/Conv3x3Slice.v 撞重名 module）。
  * inlineRom = true —— `FusionBuf` 里的 `Mem` 带上电初值 0；内联成 `initial begin mem[i]=0; ... end`
  *   让 `gen/UnitExec.v` **自包含**（否则会另发一个 `.bin`，vvp 在工作目录里找不到就读全 X，
  *   而"未写过位置读 0"正是 FusionBuf 的契约之一）。与 FusionBufGen 同一口径。
  *
  * ★ C3.9b：`UnitExec` 现在**例化两个** `Conv3x3Slice`（头 `conv` + 尾 `convT`），
  *   尾切片有**自己的**权重装载口（`we_t/waddr_t/wdin_t`）。`oneFilePerComponent=false` 意味着网表里
  *   仍然只有**一个** `module Conv3x3Slice`（两次例化共用）⇒ `>>> SHIFT` 那 8 处**不会翻倍**，
  *   `run_unitexec_ab.sh` 的 shift 突变（期望恰好 8 处命中）与 `run_fuse_head_ab.sh` 的 `midWrEn` 突变
  *   （期望恰好 1 处命中）都**一字不变**地成立。
  */
object UnitExecGen extends App {
  require(args.length >= 1, "usage: runMain UnitExecGen <outDir>")

  // ★ A-1a：主网表（既有几何 C=8/WIDTH=64/IMG_H_MAX=4，S2/头/融合对的闸门用它）。
  //   ★ A-3：`L_MAX` 由 **4 → 8**（与 `LayerSched.L_MAX` 同一个设计参数；链长直方图 {2:15,4:2,6:1,8:1}
  //     ⇒ `L_MAX=8` 才覆盖 33/33 条融合边）。两份 `UnitExec` 网表都按 8 片生成。
  SpinalConfig(
    headerWithDate      = false,
    headerWithRepoHash  = false,
    // ★ C3.18 R3-4：本代 NPU **一律同步复位**（理由与全套范围见 NpuTopGen.scala 的同一行）。
    defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC),
    oneFilePerComponent = false,
    inlineRom           = true,
    targetDirectory     = args(0),
    netlistFileName     = "UnitExec.v"
  ).generateVerilog(new UnitExec(C = 8, WIDTH = 64, IMG_H_MAX = 4, L_MAX = 8))
  println("UNITEXECGEN: C=8 WIDTH=64 IMG_H_MAX=4 L_MAX=8 -> " + args(0) + "/UnitExec.v")

  // ★ A-1a：**链闸门专用**的第二份网表（WIDTH=32, IMG_H_MAX=8, L_MAX=8）——
  //   `run_chain_ab.sh` 在小几何 `(C=8, W=32, H=8)` 上跑链（与 run_sched_ab.sh 的 WIDTH=32 同口径）。
  //   两份网表各自自包含（`oneFilePerComponent=false`）；既有闸门只看 `UnitExec.v`（不受影响）。
  SpinalConfig(
    headerWithDate      = false,
    headerWithRepoHash  = false,
    // ★ C3.18 R3-4：本代 NPU **一律同步复位**（理由与全套范围见 NpuTopGen.scala 的同一行）。
    defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC),
    oneFilePerComponent = false,
    inlineRom           = true,
    targetDirectory     = args(0),
    netlistFileName     = "UnitExec_w32.v"
  ).generateVerilog(new UnitExec(C = 8, WIDTH = 32, IMG_H_MAX = 8, L_MAX = 8))
  println("UNITEXECGEN: C=8 WIDTH=32 IMG_H_MAX=8 L_MAX=8 -> " + args(0) + "/UnitExec_w32.v")

  // ★★ C4b-D1b：**真行宽带闸门专用**的第三份网表（WIDTH=640 = 真网 `Conv_0` 的输入行宽，
  //   IMG_H_MAX=4, L_MAX=8）—— `run_stride_exec_ab.sh` 的 `s2_real640` 用例用它把 **stride>=2
  //   在集成 `UnitExec` 上**跑到**真 640 列行宽**（输出 `IMG 4×320`，横向抽稀 640→320 整段为真）。
  //   与主网表**同源同参**（只换 WIDTH）⇒ 既有闸门只看 `UnitExec.v`/`UnitExec_w32.v`（不受影响）。
  SpinalConfig(
    headerWithDate      = false,
    headerWithRepoHash  = false,
    defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC),
    oneFilePerComponent = false,
    inlineRom           = true,
    targetDirectory     = args(0),
    netlistFileName     = "UnitExec_w640.v"
  ).generateVerilog(new UnitExec(C = 8, WIDTH = 640, IMG_H_MAX = 4, L_MAX = 8))
  println("UNITEXECGEN: C=8 WIDTH=640 IMG_H_MAX=4 L_MAX=8 -> " + args(0) + "/UnitExec_w640.v")

  // ★★ T-S2R：**2-D tile 循环**专用网表（`TILING=true`，`WIDTH=34 = W_TILE(32)+2`、`IMG_H_MAX=32 = H_TILE`、
  //   `L_MAX=8`）—— 闸门 `run_tiling2d_rtl_ab.sh` 用它把"整层 tile 拼接 == 整层"逐字节证死。
  //   `TILING=false` 的既有三份网表由上面的 `SpinalConfig` 生成 ⇒ 与本份**互不影响**。
  SpinalConfig(
    headerWithDate      = false,
    headerWithRepoHash  = false,
    defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC),
    oneFilePerComponent = false,
    inlineRom           = true,
    targetDirectory     = args(0),
    netlistFileName     = "UnitExec_tiled.v"
  ).generateVerilog(new UnitExec(C = 8, WIDTH = 34, IMG_H_MAX = 32, L_MAX = 8, TILING = true))
  println("UNITEXECGEN: C=8 WIDTH=34 IMG_H_MAX=32 L_MAX=8 TILING=true -> " + args(0) + "/UnitExec_tiled.v")

  println("UNITEXECGEN_DONE")
}
