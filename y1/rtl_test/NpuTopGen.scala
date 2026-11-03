import spinal.core._

/** 生成 y1/rtl/NpuTop.scala 的 Verilog（落盘到 args(0)，例如 y1/gen）。
  *
  * 两个 header 开关**必须**为 false（与 MacArrayGen / LineBufferGen / WeightStoreGen /
  * HostRegsGen / DdrMasterGen 同因）：
  *   headerWithDate     —— 否则每次生成都写当天日期，md5 每天都变；
  *   headerWithRepoHash —— 否则 header 里嵌当前 repo HEAD，**每提交一次指纹就变一次**，
  *                         之后所有"我这次改动生效了吗"的 md5 对比全部沦为废话。
  * oneFilePerComponent = false —— 单文件产出：NpuTop 连同它例化的 HostRegs / DdrMaster /
  *   LayerSched（+ DescFetch/UnitExec/BypassExec/Conv3x3Slice/GroupedMacArray/WeightStore/
  *   LineBuffer/MacArray/FusionBuf/四个旁路单元）一起落进 gen/NpuTop.v（所有 module 同文件），
  *   这样 check_dangling.py 只喂一个文件就既看到定义又看到例化，iverilog 也只编译这一个网表文件
  *   （否则会和 gen/HostRegs.v / gen/DdrMaster.v / gen/LayerSched.v 撞重名 module）。
  * inlineRom = true —— ★ C3.12 新增：NpuTop 现在例化了 LayerSched（其下有 FusionBuf 行窗 RAM /
  *   WeightStore / LineBuffer / Sigmoid 的 LUT 等 `Mem`）⇒ 必须把 ROM 初值**内联**成 `initial`
  *   块，网表才自包含（否则会外链一份 .bin/.hex，单文件 iverilog 编译就会读不到初值）。
  *   与 LayerSchedGen / UnitExecGen 同口径；HostRegs/DdrMaster 两模块本身无 Mem ⇒ 该开关对它们
  *   生成的 Verilog 一字不改（C2 闸门仍吃同一份 gen/NpuTop.v）。
  *
  * ★★ C3.18 Round3 R3-4：**本代 NPU 一律同步复位**（`defaultConfigForClockDomains =
  *   ClockDomainConfig(resetKind = SYNC)`）。
  *
  *   为什么改（板级实测，不是风格偏好）：SpinalHDL 的**默认是异步复位**，而本仓所有 NPU 生成器
  *   都吃默认值 ⇒ 板级网表里 NPU 是 **14 个异步 always 块 vs 7 个同步**，而 CPU 是 5/50、胶合是
  *   0/14。后果有两处、都在 `NpuTop` 里量出来：
  *     · `u_soc/soc_cpu_reset` 这张网被 NPU 灌成**扇出 88,571 个负载**（R1 实测；R2 档实测 103,380），
  *       布线扇出 57,202、该网自身布线 5.93 ns —— 异步复位网**不能**被 fanout guide / 自动缓冲
  *       处理（本仓既有结论：`fanout guide 对异步复位网无效`），只能原样拖着走；
  *     · **9,947 个 recovery 端点违例**（WNS −1.431，TNS −3,952）—— 异步复位的"恢复/移除"检查
  *       要求 CD 小于一个周期，而这张网自身的延迟就吃掉 5.93 ns，几乎不可能满足。
  *
  *   为什么**可以**改成同步（关键的自证，不是"应该没事"）：板级 `board/yeshen_mini_soc.v:205-215`
  *   里 `soc_cpu_reset` **本身就是在 `soc_clk` 上产生的同步量**：`glue_rst_sync` 是一个 2 拍 FF
  *   同步器，`loadActive` 也来自 `soc_clk` 域的胶合 FF。也就是说这条复位**在原点上就是同步的**，
  *   把它接到 NPU 的同步复位口**不产生任何 CDC**，也不会丢掉任何"异步 assert"性质（板级复位
  *   本来就没有异步 assert 的承诺）。改成同步后：9,947 个 recovery 端点变成普通同步检查（恢复
  *   时间在时钟沿处天然满足，该族直接消失），而复位网变成一张**普通高扇出数据网** ——
  *   可以交给 ADS/PDS 的自动 fanout 缓冲/复制处理。
  *
  *   范围（**全套一致，故意不留分叉**）：本目录下**每一个**会产出"闸门会编译的网表"的生成器
  *   （MacArray / Slice / LineBuffer / WeightStore / GroupedMacArray / FusionBuf / UnitExec /
  *   LayerSched / NpuTop / HostRegs / DdrMaster / Desc / Bypass）都加了同一行 ⇒ 板级网表与
  *   单元闸门网表**同一复位风格**，不会出现"单元闸门测的是异步、板上跑的是同步"这种暗分叉。
  *   注意 `DdrMaster` / `DescFetch` / 旁路单元 / `HostRegs` 也在范围内（它们在 NPU 层次里，
  *   板级同样是同步复位）—— 这也让 `desc/bypass/hostregs/ddr*` 那几个闸门网表与板级一致。
  *
  *   具体拼写是**对着钉住的 SpinalHDL 1.15.0 jar 核过的**（不是照记忆写）：
  *   `javap spinal/core/ClockDomainConfig.class` ⇒ 构造参数 `(clockEdge, resetKind, resetActiveLevel,
  *   softResetActiveLevel, clockEnableActiveLevel)`；`ClockDomainConfig$.$lessinit$greater$default$2()`
  *   的字节码是 `getstatic spinal/core/ASYNC$.MODULE$` ⇒ 默认确实是 ASYNC；而 `ResetKind` 这个
  *   名字在 jar 里**只有 trait 本身**（`spinal/core/ResetKind.class`，无 `ResetKind$` 伴生对象）
  *   ⇒ **`ResetKind.SYNC` 这种写法在 1.15.0 里并不存在**，对象就是顶层 `spinal.core.SYNC`
  *   （`spinal/core/SYNC$.class implements spinal.core.ResetKind`），经 `import spinal.core._` 后
  *   直接写 `SYNC`。下面这一行即为该拼写。
  */
object NpuTopGen extends App {
  require(args.length >= 1, "usage: runMain NpuTopGen <outDir>")
  SpinalConfig(
    headerWithDate      = false,
    headerWithRepoHash  = false,
    // ★ C3.18 R3-4：本代 NPU **一律同步复位**（理由、范围与 API 拼写核对见上面类注释）。
    defaultConfigForClockDomains = ClockDomainConfig(resetKind = SYNC),
    oneFilePerComponent = false,
    inlineRom           = true,
    targetDirectory     = args(0)
  ).generateVerilog(NpuTop())
  println("NPUTOPGEN_DONE")
}
