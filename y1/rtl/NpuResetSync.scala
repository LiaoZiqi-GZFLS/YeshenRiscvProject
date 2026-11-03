import spinal.core._

// =============================================================================
// NpuResetSync —— **每域各自的复位同步释放器**（异步置位 / 同步释放），并**强制两域释放先后**。
//   用途：Y1「NPU 独立时钟域」plan Task **N5**（spec §3-A(d) / §5-G3 "复位跨域" / §2 复位现状）。
//
// ★★ 本任务（N5）**只交付本模块 + 它的独立两时钟装置**：
//    · **不**动 `board/yeshen_mini_soc.v` 的活复位路径（`glue_rst_sync` / `soc_cpu_reset` 一字不改）；
//    · **不**把 `NpuTop` 换成 `npu_clk`（N5b 的活）；
//    ⇒ 现有闸门与板级行为一字不变。
//
// -----------------------------------------------------------------------------
// ★ 现状对照（spec §2，出处逐条给）：
//   · 今天：`soc_cpu_reset = glue_reset | cpu_reset`，是 `soc_clk`(=cpu_clk) 域 2-FF **同步释放**
//     （`board/yeshen_mini_soc.v:210-215,220,240`：`glue_rst_sync` 2 位左移 + `glue_reset=glue_rst_sync[1]`）。
//     NPU 网表（R3-4 起）用**同步复位**，接 `soc_cpu_reset`。
//   · 本模块把这条路**原样保留在 cpu 侧**（同款 2-FF 同步释放），并**新增** `npu_clk` 域的同步释放；
//     且把两域的**释放先后写死**（见下），使"复位期间 NPU 不出错误事务"成为结构性保证。
//
// -----------------------------------------------------------------------------
// ★★ 复位契约（**逐条写死**）：
//   ① **异步置位**：`asyncRst`（高有效，= 板级 `async_reset` 语义）一抬，两域的复位**立即**生效
//      （两个域的 FF 都是 `ASYNC` 复位，`resetActiveLevel = HIGH`）——不依赖任何时钟。
//   ② **同步释放**：`asyncRst` 落下后，各域**在自己的时钟沿**上逐拍解开（2 位左移，同板级口径）。
//   ③ **释放先后（★ 本模块的核心裁决）**：**cpu 域先释放，npu 域后释放**。
//      实现：npu 域的同步释放**被 cpu 域"已经起来"的电平门住**——
//      cpu 的 `cpuUp = !cpuRstSync[最高位]`（= `io.cpuRstn`，**1 = cpu 已出复位**）经 2-FF 同步进
//      npu 域得 `cpuUp2`；`cpuUp2==0` 时 npu 的移位寄存器**压回全 1（保持复位）**，
//      只有 `cpuUp2==1` 才开始左移解复位。
//      ⇒ `npuRstn` 的释放**必然晚于** `cpuRstn` 的释放（至少晚 2 个 npu 拍 + 相位）。
//   ④ **为什么这个顺序是安全的（复位期间不出错误事务）**：
//      (a) N3/N4 两座异步桥的**每一套状态机复位后都在 IDLE**（`sValid=0 / dPending=0 / dAck=0 / dMask=0`）
//          —— 释放**竞态造不出事务**：没有 valid 就没有请求，桥不转发任何东西。
//      (b) 让 **cpu 域（主机窗从口 + §3.5 内存汇聚点/仲裁）先起来**，保证 NPU 侧一旦有请求，
//          cpu 侧**已经被复位钳在 IDLE 且随后可正常受理**；反过来（npu 先起）会让 NPU 的首笔请求
//          落在一个仍在复位的主机/汇聚点上 —— 这正是要避免的"错误事务"形状。
//      (c) 释放是**同步的**（各域自己的 2-FF）⇒ 不会出现 recovery/removal（异步去沿）导致的
//          状态机"半复位"毛刺。
//      ⇒ 顺序 + 同步释放 + IDLE 起始，三者合起来给出"复位期间无错误事务"。
//      ★ 诚实标注（能证/不能证见 TB + gate）：在**零延迟 RTL 仿真**里，由于桥的两套状态机都复位到 IDLE，
//        **两种释放顺序都不会凭空造出数据错误**；本模块把"顺序"做成**硬契约**（结构性强制 + TB 断言），
//        其价值是**结构性/时序**的（reset tree、recovery/removal 余量、首笔请求落在已就绪的主机侧）。
//
// -----------------------------------------------------------------------------
// ★ 与板级的关系（集成在 N5b，本任务不做）：
//   板级 `glue_rst_sync`（cpu 侧 2-FF）等价于本模块 cpu 侧的移位器；N5b 集成时二选一/对接：
//   可以把板级 `async_reset`（= `async_reset | cpu_reset` 的源）喂本模块 `asyncRst`，
//   再用本模块的 `cpuRstn`/`npuRstn` 替换现路径 —— 但**本任务不改板级**。
// =============================================================================

/** 每域复位同步释放器（异步置位 / 同步释放），并强制 **cpu 先、npu 后** 的释放顺序。
  *
  * @param stages 每域移位器的级数（默认 2，与板级 `glue_rst_sync` 同）。
  */
class NpuResetSync(stages: Int = 2) extends Component {
  setDefinitionName("NpuResetSync")

  require(stages >= 2, "stages 至少 2（同步释放需要 ≥2 级）")

  val io = new Bundle {
    val cpuClk   = in  Bool()
    val npuClk   = in  Bool()
    val asyncRst = in  Bool()   // 高有效：异步置位（板级 async_reset 语义）
    val cpuRstn  = out Bool()   // 低有效：cpu 域，异步置位/同步释放
    val npuRstn  = out Bool()   // 低有效：npu 域，异步置位/同步释放（**晚于 cpu**）
  }

  // 两个域都以 `asyncRst`（高有效）作异步复位；无隐式默认域（顶层无默认域寄存器）。
  val cpuCd = ClockDomain(io.cpuClk, io.asyncRst, config = ClockDomainConfig(resetKind = ASYNC, resetActiveLevel = HIGH))
  val npuCd = ClockDomain(io.npuClk, io.asyncRst, config = ClockDomainConfig(resetKind = ASYNC, resetActiveLevel = HIGH))

  val maxSel = (BigInt(1) << stages) - 1   // stages 位全 1（= 保持复位）

  // ==================== cpu 域：异步置位 / 同步释放（板级口径的等价位）====================
  // 移位器：复位时全 1；释放后每拍左移补 0；最高位为 0 时 cpu 出复位。
  val cpuRstSync = cpuCd(RegInit(U(maxSel, stages bits)))
  cpuRstSync := (cpuRstSync << 1)(stages - 1 downto 0)   // 左移补 0
  io.cpuRstn := !cpuRstSync(stages - 1)

  // ==================== 把"cpu 已出复位"电平同步进 npu 域（2-FF）====================
  // ★ 这一对 FF 是"释放先后"的**承重**：它把 cpu 侧的就绪电平安全地（同步地）带给 npu 侧。
  //   口径：`cpuUp = !cpuRstSync[最高位]` —— **1 = cpu 已出复位**（与 `io.cpuRstn` 同义）。
  crossClockDomain(cpuRstSync)
  val cpuUp1 = npuCd(RegInit(False))
  val cpuUp2 = npuCd(RegInit(False))
  cpuUp1 := !cpuRstSync(stages - 1)    // 1 = cpu 已出复位
  cpuUp2 := cpuUp1

  // ==================== npu 域：异步置位 / 同步释放，被 cpuUp2 门住（★ 顺序强制）====================
  // cpuUp2==0（cpu 还没起来）⇒ 移位器**压回全 1**（npu 保持复位），不前进；
  // cpuUp2==1 ⇒ 才开始左移解复位 ⇒ npu 释放**必然晚于** cpu 释放。
  val npuRstSync = npuCd(RegInit(U(maxSel, stages bits)))
  when(!cpuUp2) {
    npuRstSync := U(maxSel, stages bits)               // 保持复位（未够条件）
  } otherwise {
    npuRstSync := (npuRstSync << 1)(stages - 1 downto 0)
  }
  io.npuRstn := !npuRstSync(stages - 1)
}
