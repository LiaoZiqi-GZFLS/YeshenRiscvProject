import spinal.core._

/** 生成 y1/rtl/LayerSched.scala 的 Verilog（落盘到 args(0)，例如 y1/gen）。
  *
  * 用法：`runMain LayerSchedGen <outDir>`（**无形状参数**：形状写死在这里 ——
  * `C = 8`（= DdrMaster 一拍字节数）、`WIDTH = 34`（= **2-D tile 的物理行宽 `W_MAX`** =
  * `W_TILE(32) + 2`（halo 列））、`IMG_H_MAX = 32`（= `H_TILE`，也 = 输出存储的行数上限
  * ⇒ `maxPix = WIDTH*IMG_H_MAX = 1088`）。
  *
  * ★★ Y1-frame（真几何，2026-10-13）：`WIDTH` 从 C3 的**定点用例值 32 改到 640**。
  *   根因（F1 板级实测）：真帧 `desc[0]` = `Conv_0`（`IMG_W=320, STRIDE=2`）⇒ `UnitExec.inWOk`
  *   要求 `WIDTH ∈ [IMG_W·s − s + 1, IMG_W·s] = [639, 640]`；`WIDTH=32` 被**响亮 err**（零搬运）。
  *   真表（`gen/desc.bin`，67 载荷项）的 conv 类输入行宽 = `IMG_W·s` ∈ {640, 320, 160, 80, 40, 20}
  *   ⇒ **单张网表只能满足一个输入行宽**（`inWOk` 对 `s=1` 层退化成 `IMG_W==WIDTH`）。
  *   报告：`y1/reports/c4b_frame.md`（`WIDTH=640` 满足 `desc[0]`、但 `dev_map` 装不下）。
  *
  * ★★ T-S1（2026-10-14）：`inWOk` 从**编译期等式**改成**运行期界限** `1 ≤ rowW = IMG_W·s ≤ W_MAX`
  *   ⇒ 一张网表重放**全部 6 个行宽**（`y1/reports/c4b_roww.md`）。**分配仍按 `WIDTH`**。
  *
  * ★★ T-S2（2026-10-14，本片）：**把 `WIDTH`/`IMG_H_MAX` 收窄成 2-D tile 的物理尺寸**，
  *   使"随行宽×行数放大的片上缓冲"装进 PG2L200H。**尺寸由 `dev_map` 仲裁**（spec §4.1/§6-R4）：
  *     · `W_MAX=66`（tile 64×32，spec §4.1 推荐）⇒ nputop `dev_map` **失败**：`Adm-4088 ×195`
  *       （DRM 不够，`wOutMem_*` / `mpu/psb/mem_*` 从 DRM 掉进 LUTRAM）⇒ **不采用**；
  *     · `W_MAX=34 / IMG_H_MAX=32`（tile **32×32**，spec 点名的回落档）⇒ nputop `dev_map`
  *       **成功、`Adm-4088 = 0`**（DRM 319/415 = 77%，LUT 62%、APM 74%）⇒ **采用**。
  *   详见 `y1/reports/c4b_tiling_s2.md` §3。
  *
  *   `IMG_H_MAX`: C3/Y1-frame 的 16/8 受 `PartialSumBuf` 的 **16-bit `depth` 自报口**约束
  *   （`DEPTH = NCOB·PIXMAX = 8·(WIDTH·IMG_H_MAX)` ⇒ `WIDTH·IMG_H_MAX ≤ 8191`）。本片
  *   `34·32 = 1088` 远在限内；真正的夹逼是**器件 DRM**（dev_map 仲裁，见上）。
  *
  * 两个 header 开关**必须**为 false（与 SliceGen / FusionBufGen / DdrMasterGen / DescGen / UnitExecGen 同因）：
  *   headerWithDate     —— 否则每次生成都写当天日期，md5 每天都变；
  *   headerWithRepoHash —— 否则 header 里嵌当前 repo HEAD，**每提交一次指纹就变一次**，
  *                         之后所有"我这次改动生效了吗"的 md5 对比全部沦为废话。
  * oneFilePerComponent = false —— 单文件产出：`LayerSched` 连同它例化的
  *   `DescFetch`（+ 其内部 `DdrMaster`）、`UnitExec`（+ Conv3x3Slice / GroupedMacArray /
  *   WeightStore / LineBuffer / MacArray / FusionBuf）与 `BypassExec`（+ 四个旁路单元）全落进
  *   `gen/LayerSched.v`。
  *   这样 check_dangling.py 只喂一个文件就既看到定义又看到例化，iverilog 也只编译这一个网表文件
  *   （否则会和 gen/DescFetch.v / gen/UnitExec.v 撞重名 module）。
  *   ★ `UnitExec` 在本网表里是**按 WIDTH=32 展开**的（与 `gen/UnitExec.v` 的 WIDTH=64 是两份不同的
  *     例化）——两个闸门各自编译各自的网表文件，互不干扰。
  *   ★ A-3：**显式**给 `L_MAX = 8`（本代提交值；`LayerSched`/`UnitExec` 两个默认也都是 8，此处再钉一次
  *     是为了让"生成期切片上限"这个旋钮在生成器里**看得见、改得动**）。
  * inlineRom = true —— `FusionBuf` / 输出存储 / Sigmoid 的 LUT `Mem` 带上电初值，内联成 `initial` 块 ⇒ 网表自包含。
  */
object LayerSchedGen extends App {
  require(args.length >= 1, "usage: runMain LayerSchedGen <outDir>")

  SpinalConfig(
    headerWithDate      = false,
    headerWithRepoHash  = false,
    // ★ C3.18 R3-4：本代 NPU **一律同步复位**（理由与全套范围见 NpuTopGen.scala 的同一行）。
    defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC),
    oneFilePerComponent = false,
    inlineRom           = true,
    targetDirectory     = args(0),
    netlistFileName     = "LayerSched.v"
  ).generateVerilog(new LayerSched(C = 8, WIDTH = 34, IMG_H_MAX = 32, L_MAX = 8))
  println("LAYERSCHEDGEN: C=8 WIDTH=34 IMG_H_MAX=32 L_MAX=8 GROUP=1 SHIFT=6 -> " + args(0) + "/LayerSched.v")
  println("LAYERSCHEDGEN_DONE")
}
