import spinal.core._
import spinal.lib._
import spinal.lib.bus.amba4.axilite._
import spinal.lib.bus.amba4.axi._

/** NpuTop —— 把**主机寄存器层**（HostRegs）、**DDR 块拷贝主口**（DdrMaster）与 **层调度器**
  * （LayerSched，C3.12）接成一体，使"主机经 AxiLite4 编程一次任务、硬件自己跑完并把完成/出错
  * 事件通知主机"这条端到端通路成立。任务有两档（见下"start 契约"）：旧的块拷贝，或走描述符表的
  * 层调度。
  *
  * 本文件只做**接线与派生**，不改任何被接方的语义：
  *   · 主机侧   ：AxiLite4 从口原样透传到 HostRegs.io.axilite（顶层 axilite）。
  *   · 内存侧   ：顶层对外**只有一个** Axi4 主口；内部两路主口（DdrMaster 与 LayerSched）
  *                做结构性 2:1 复用（见下"Axi 主口口径"）。
  *   · 事件侧   ：{DdrMaster, LayerSched}.busy/done/err -> HostRegs.sched_busy/sched_done/sched_err；
  *                {DdrMaster.done|err, LayerSched.frameDone|err} -> 顶层 irq（见下"中断口径"）。
  *
  * ★ ★ 本文件在 C3.12 之前的三段口径（长度派生 / 非法长度 -> STATUS.err / 中断保持电平）**逐字未动**，
  *   下面逐条仍有效；C3.12 只**增补**了两件事：① 调度器接线；② 顶层单主口内部 2:1 复用 +
  *   `CTRL.start` 二选一契约。SoC 胶合（`src/YeshenSocGlue.scala`）/ 板级 / 地址台账**一字不改**
  *   （对外端口集不变 ⇒ 台账无改动即正向证据）。
  *
  * ★ ★ C3.16 增补（第二处"补通路"）：**权重不再被钉成常量**。C3.12 里 LayerSched 的四个权重装载口
  *   在本层一律接 0（"对外端口集不含权重口"的冻结口径）⇒ conv 在顶层只能跑出**零张量**、板级综合还会把
  *   整条卷积数据通路**常量折叠**掉。C3.16 把 `HostRegs` 新加的**寄存器信箱**（WGT_SEL/WGT_ADDR/
  *   WGT_DATA/WGT_WE）直连到 `LayerSched` 的信箱口 ⇒ 主机经**同一条** AxiLite 寄存器窗就能逐字节
  *   预载任意切片的权重。对外端口集**仍然不变**（信箱整个在 NPU 内部；SoC 胶合 / 板级 / 地址台账
  *   一字未动）⇒ 这一档是"补一条已有寄存器窗内的真通路"，不是改接口。
  *
  * ★ ★ C3.17 增补（Round1 时序收敛）：**把遗留的长度派生从 DdrMaster 的 CE 路径上摘下来**。
  *   板级 PnR 的头号违例（`NpuTop` 的 `IMG_W*IMG_H*C_IN` 96 bit 乘积 + `lenOk`）原本是**组合**地
  *   接到 `DdrMaster.io.len`，其 28 级逻辑直插 `DdrMaster` 的 CHK 比较 / `rbase`/`wbase` 时钟使能。
  *   C3.17 只把这条链**拆成三级寄存流水**（级1 `IMG_W*IMG_H` / 级2 `*C_IN` / 级3 `lenOk ? ... : 0`），
  *   并让 `DdrMaster` 只看到**已寄存的** `len`。**值语义逐字不变**（同样的长度、同样的"非法 -> 0 ->
  *   主口 err"），对外端口集/SoC 胶合/板级/台账**一字不改**。主机视角的差别只有"`len` 晚 3 拍"，
  *   对"先写维寄存器、后写 start"的主机完全透明（详见下面"派生长度"那段）。C3 调度器一路不受影响
  *   （其长度取自描述符，根本不过这条链）。
  *
  * ---------------------------------------------------------------------------
  * ★ C3.12 start 契约（本集成的第二核心；写死在这里，两路二选一）：
  *     CTRL.start 是一根**自清单拍**（HostRegs 的 start_r）。本块在那一拍按 `DESC_COUNT` 分流：
  *       · `DESC_COUNT == 0`  ⇒ 旧 C2 块拷贝语义：只放行 `ddrMaster.io.start`，LayerSched 保持在 IDLE；
  *       · `DESC_COUNT != 0`  ⇒ 层调度语义：只放行 `layerSched.io.go`，DdrMaster 保持在 IDLE。
  *     选哪种由 `schedSel = (DESC_COUNT != 0)` 决定；`axiMuxSel` 是**寄存器**、只在 start 那拍采样
  *     ⇒ 一次调用中途不会换马。DESC_COUNT 复位 0 ⇒ **不写 DESC_COUNT 的既有主机**（含 C2 闸门）
  *     走块拷贝，契约对 C2 逐字向后兼容。
  *
  * ★ C3.12 Axi 主口口径（为什么对外仍是**一个**主口）：
  *   本块内部有两路 AXI4 主口（DdrMaster 的块拷贝主口、LayerSched 的调度器主口），但顶层对外
  *   **只保留 `io.axi` 一个**（与 C2 逐字段同形）。理由与做法：
  *     · SoC 胶合（C2.2）把 NPU 当**一个** AXI 主口并进 merger ⇒ 若这里改成两个对外主口，
  *       胶合/板级/台账全要改，且会破坏 C2 的集成契约。所以**内部**复用、对外不变。
  *     · 复用是**结构性的**：输出侧按 `axiMuxSel` 二选一，输入侧（ready/r/b）广播给两路；
  *       未被选中的那一路整次调用停在 IDLE（`valid` 恒 0），因此"看到"握手也发不出任何东西。
  *     · 两路引擎的 go/start 是**组合采样**、状态机是寄存器 ⇒ 它们发首笔事务至少要过 1 拍，
  *       而 `axiMuxSel` 在 start 那拍就更新 ⇒ 选择在首笔事务之前就位，绝不会把一笔突发劈给两路。
  *
  * ---------------------------------------------------------------------------
  * ★ 长度口径（本集成契约的核心；寄存器表里**没有**长度寄存器）：
  *      len_bytes = IMG_W x IMG_H x C_IN        // int8：元素数 == 字节数
  *   一次"层"的缓冲区大小**就是**它的特征图大小 —— 所以长度由特征图维度派生，而不是再加
  *   一个寄存器（那样会在表和语义之间制造第二个真源）。NpuTop 算这个乘积三通道乘积：
  *      prod = IMG_W * IMG_H * C_IN           （96 bit：32*32 -> 64，再 *32 -> 96）
  *   并只在**合法**时把它驱动到 DdrMaster.len：
  *      lenOk = (prod != 0) && (prod % 128 == 0) && (prod 落在 32 位内)
  *   ★ C3.17：`prod`/`lenOk` 从头到尾**组合**曾是板级头号违例（28 级 / 11.4 ns），现改为
  *     **三级寄存流水**（`whReg -> prodReg -> lenReg`），`DdrMaster` 只看到寄存的 `lenReg`。
  *     **值语义不变**（同前一行那块注释逐字为证）。
  *   不合法（含**溢出**这一档：prod >= 2^32，此时若只截低 32 位可能恰好又是个 128 的倍数而
  *   **静默搬错**）时驱动 len = 0。主口在 CHK 态对 len 有硬校验
  *   （`len % 128 == 0 && len != 0`，见 rtl/DdrMaster.scala），len = 0 **必然**让它
  *   "一拍 err 且一个字节都不搬"。于是非法长度**不需要** NpuTop 另造一条 err 通路：
  *   主口的 err 就是这一档的 err（下一段说它怎么到主机）。
  *
  * ★ 非法长度如何到达主机的 STATUS.err（本契约要求明说）：
  *   DdrMaster.err 是**单拍脉冲**（CHK 态发现非法 -> err_r 抬一拍 -> 回 IDLE）。单拍脉冲对
  *   一个**轮询 AxiLite 寄存器**的主机是不可靠的：AxiLite 读本身要好几拍，脉冲会被整个漏掉。
  *   所以 NpuTop 把 err **锁成粘滞电平** errSticky（err 上升沿置 1，主机写 CTRL.soft_reset 清 0），
  *   再把 errSticky 喂给 HostRegs.sched_err -> STATUS.bit1。于是 STATUS.err 在整个轮询窗口里
  *   都读得到，主机**必然**能观察到"这次调用是非法长度"。（被接的 HostRegs 表是冻结的，其中
  *   STATUS 没有 err 清除位，所以清 err 的口径与清 IRQ 的口径统一取 CTRL.soft_reset。）
  *
  * ★ 中断口径（irq = done | err | frameDone 的**保持电平**）：
  *   DdrMaster.done / err 与 LayerSched.frameDone / err 都是**单拍脉冲**；本 SoC 的 PLIC 是
  *   **电平敏感**，单拍脉冲会漏。所以 NpuTop 把事件锁成一拍都不短的**保持电平** irqR：
  *     · 事件来（done/err/frameDone）⇒ irqR 置 1，并**保持**（不自己在下一拍掉），直到主机显式确认；
  *     · 主机写 CTRL.soft_reset（HostRegs 里是自清位）⇒ irqR 清 0。
  *   即：irq 是"电平 + 显式确认"的语义 —— 对电平敏感的 PLIC 来说，事件一旦发生，中断线就会
  *   一直举着直到主机清掉，绝不会出现"脉冲太短、PLIC 没采到"的丢中断。irqR 初值为 0，
  *   复位后 / 未启动任何操作前**恒为 0**（不会卡在高）。
  *   ★ 调度器一路只接 `frameDone`（**整帧唯一的一次**，S4 纪律）⇒ 帧内中断计数结构性地为 0；
  *     绝不可能"三个单元各一次中断"。
  *
  * ★ start 的单拍脉冲够不够（明说结论）：
  *   HostRegs.start 是自清单拍（写 1 起效、下一拍自动落 0）。DdrMaster 的 IDLE 态对
  *   `io.start` 是**组合采样**（`when(io.start) { state := CHK }`），LayerSched 的 IDLE 态对
  *   `io.go` 同样组合采样（`when(io.go) { ... }`）；同一 clk 域、IDLE 态下一拍脉冲必然被采到。
  *   所以 NpuTop **不需要**给 start/go 再加一级锁存，直接按契约分发给两路之一即可
  *   （闸门里块拷贝与调度器两档、正/负用例都跑通即为证）。
  */
case class NpuTop(LMax: Int = 2) extends Component {

  /** 与 DdrMaster 同源的一份形状参数：顶层 AXI4 主口与子模块都用它，保证位宽逐条一致。
   *  （下面 Axi4Config 的构造与 rtl/DdrMaster.scala 里 axiCfg 的构造逐参数同形；若哪天
   *   DdrMaster 改了形状而这里没同步，`io.axi <> ddrMaster.io.axi` 会在展开期因类型不符
   *   **响亮报错**，不会静默接错。）*/
  val ddrCfg = DdrMasterConfig()

  val io = new Bundle {
    // 主机侧：AxiLite4 从口（透传给 HostRegs）。
    val axilite = slave(AxiLite4(32, 32))
    // 内存侧：AXI4 主口（透传给 DdrMaster）。
    val axi = master(Axi4(Axi4Config(
      ddrCfg.ADDR_W, ddrCfg.DATA_W,
      idWidth     = ddrCfg.ID_W,
      useId       = true,
      useLen      = true,
      useLock     = false,
      useRegion   = false,
      useQos      = false,
      awUserWidth = 0, arUserWidth = 0, wUserWidth = 0, bUserWidth = 0, rUserWidth = 0
    )))
    // 中断线：保持电平（见文件头"中断口径"）。
    val irq = out Bool()
  }
  noIoPrefix()

  // ---------------------------------------------------------------------------
  // 三个被接方
  // ---------------------------------------------------------------------------
  val hostRegs  = HostRegs()
  val ddrMaster = new DdrMaster(ddrCfg)
  /** ★ C3.12：层调度器（走 DDR 里的描述符表 ⇒ conv/旁路单元）。几何与 `LayerSchedGen` 的
    *   用例**逐参同形**：`C = 8`（= DdrMaster 一拍字节数）、`WIDTH = 34`（= **2-D tile 的物理
    *   行宽 `W_MAX` = `W_TILE(32) + 2` halo 列）、`IMG_H_MAX = 32`（= `H_TILE`，`maxPix = 1088`）。
    *   ★★ Y1-frame（真几何，2026-10-13）：`WIDTH` 从 C3 的定点值 **32 改到 640** —— F1 板级实测
    *   真帧 `desc[0]`（`Conv_0`, `IMG_W=320, s=2`）要求 `WIDTH ∈ [639,640]`。真表其余层行宽更小
    *   （320/160/80/40/20）⇒ 单张网表只能过 `desc[0]`；`IMG_H_MAX` 16→8 受 `PartialSumBuf`
    *   16-bit `depth` 自报口硬约束（`NCOB·WIDTH·IMG_H_MAX ≤ 65535` ⇒ ≤12）与器件 RAM 上限
    *   （整图输出 `MAXPIX ≥ 102400` ⇒ `wOutMem ≥ 6.5 MB` 装不下）双重夹逼（详见 `c4b_frame.md`）。
    *   ★★ T-S1（2026-10-14）：`inWOk` 改成**运行期界限** `1 ≤ rowW = IMG_W·s ≤ W_MAX`
    *   ⇒ 一张网表重放真表 6 个输入行宽（`reports/c4b_roww.md`）。
    *   ★★ T-S2（2026-10-14，本片）：**几何收窄到 2-D tile 的物理尺寸，以 `dev_map` 为仲裁**
    *   （spec §4.1/§6-R4）：`WIDTH=66/IMG_H_MAX=32`（tile 64×32）⇒ nputop `dev_map` **失败**
    *   （`Adm-4088 ×195`）；`WIDTH=34/IMG_H_MAX=32`（tile **32×32**）⇒ **`Adm-4088 = 0`**
    *   （DRM 319/415）。见 `y1/reports/c4b_tiling_s2.md` §3。
    *   若这里与 `LayerSchedGen` 的形状漂开，**不会**静默接错（展开期的 require 会响亮报错），
    *   但两个闸门各自编译各自的网表文件 ⇒ 形状必须由本行与 `LayerSchedGen` 同时钉住。 */
  // ★ 2026-10-17（资源/性能）：板级 NpuTop 取 **L_MAX=2** —— RTL 链结构的最小合法值（L=1 会在
  //   sliceRest 空序列的 reduce 处展开失败）。真表已 de-fuse（全 plain，chain_len=1），L=8 时
  //   8 套链切片只有 slice0 被用，其余 6 套是**死逻辑**；L=2 保留链首+尾的最小链形态，删掉
  //   6 套切片（dev_map 实测 APM 542→260，−282 = 6×47）。链功能仍由 L=8 验证网表承载
  //   （gen_chain8/NpuTop.v，仅 run_nputop_sched_ab.sh 的 W2 用），不进板级。
  val layerSched = new LayerSched(C = 8, WIDTH = 34, IMG_H_MAX = 32, L_MAX = LMax)

  // 主机侧从口原样透传到 HostRegs（顶层 axilite）。
  io.axilite <> hostRegs.io.axilite

  // ---------------------------------------------------------------------------
  // ★ CTRL.start 契约（二选一，写死在这里，见文件头"start 契约"）：
  //     DESC_COUNT == 0  ⇒  **旧的 C2 块拷贝语义**（DdrMaster 跑 IMG_W*IMG_H*C_IN 的整块拷贝）；
  //     DESC_COUNT != 0  ⇒  **层调度器语义**（LayerSched 从 DESC_ADDR 走 DESC_COUNT 项描述符表）。
  //   两者共用同一根 `CTRL.start`（HostRegs 里的自清单拍）；本块在 start 那一拍按
  //   `hostRegs.io.desc_count` 的**当前值**把脉冲分给对应的引擎（另一个**不放行**）。
  //   `axiMuxSel` 是**寄存器**：只在 start 那拍采样一次 ⇒ 一次调用中途不会换马（结构性）。
  //   DESC_COUNT 的复位值是 0 ⇒ **未写 DESC_COUNT 的既有主机**（含 C2 闸门）走的仍是块拷贝，
  //   契约因此对 C2 逐字向后兼容（`run_nputop_ab.sh` 不改即过）。
  // ---------------------------------------------------------------------------
  val schedSel  = hostRegs.io.desc_count =/= U(0, 32 bits)
  val axiMuxSel = Reg(Bool()) init False
  when(hostRegs.io.start) { axiMuxSel := schedSel }

  // ---------------------------------------------------------------------------
  // ★ AXI 主口口径（本集成的关键结构决定；见文件头"Axi 主口口径"）：
  //   本块**对外只有一个 AXI4 主口**（`io.axi`，与 C2 逐字段同形），但内部有**两路**主口：
  //     · `ddrMaster.io.axi` —— C2 的块拷贝主口；
  //     · `layerSched.io.ddr` —— 调度器主口（它自己内部再复用 DescFetch/UnitExec/BypassExec）。
  //   两路**在时间上互斥**（CTRL.start 契约保证：一次调用要么走块拷贝、要么走调度器），
  //   所以这里做一个**结构性 2:1 复用**（不是 TB 的约定）：输出侧按 `axiMuxSel` 二选一，
  //   输入侧（ready/r/b）广播给两路；未被选中的那一路在整次调用里 `valid` 恒 0（它停在 IDLE）。
  //   切换选择**只在 CTRL.start 那拍更新**（`axiMuxSel` 是寄存器）⇒ 一次调用中途不会换马，
  //   绝不会把一笔突发劈给两个主口；而两路引擎看到 go/start 后至少要过一拍才发首笔
  //   （状态机是寄存器：IDLE -(+1 拍)-> 发射态）⇒ `axiMuxSel` 在首笔事务之前就位。
  // ---------------------------------------------------------------------------
  val copyAxi  = ddrMaster.io.axi
  val schedAxi = layerSched.io.ddr
  io.axi.aw.valid := Mux(axiMuxSel, schedAxi.aw.valid, copyAxi.aw.valid)
  io.axi.ar.valid := Mux(axiMuxSel, schedAxi.ar.valid, copyAxi.ar.valid)
  io.axi.w.valid  := Mux(axiMuxSel, schedAxi.w.valid,  copyAxi.w.valid)
  io.axi.r.ready  := Mux(axiMuxSel, schedAxi.r.ready,  copyAxi.r.ready)
  io.axi.b.ready  := Mux(axiMuxSel, schedAxi.b.ready,  copyAxi.b.ready)
  when(axiMuxSel) {
    io.axi.aw.payload := schedAxi.aw.payload
    io.axi.ar.payload := schedAxi.ar.payload
    io.axi.w.payload  := schedAxi.w.payload
  } otherwise {
    io.axi.aw.payload := copyAxi.aw.payload
    io.axi.ar.payload := copyAxi.ar.payload
    io.axi.w.payload  := copyAxi.w.payload
  }
  // 输入侧广播：同一拍只有一路在跑，另一路的 valid 恒 0 ⇒ 它"看到"握手也发不出任何东西。
  for (m <- Seq(copyAxi, schedAxi)) {
    m.aw.ready  := io.axi.aw.ready
    m.ar.ready  := io.axi.ar.ready
    m.w.ready   := io.axi.w.ready
    m.r.valid   := io.axi.r.valid
    m.r.payload := io.axi.r.payload
    m.b.valid   := io.axi.b.valid
    m.b.payload := io.axi.b.payload
  }

  // ---------------------------------------------------------------------------
  // ★ C3.17 派生长度 = IMG_W * IMG_H * C_IN（**值语义与 C2/C3.12 逐字相同**，只把组合链
  //   拆成三级寄存器流水；Round1 时序收敛）：
  //
  //   板级 PnR 的头号违例原本就是这一块（`report_timing`：`u_npu/N418_*` 4 个 APM 串行 ->
  //   95 位进位链 -> `prod` -> `ddrMaster_4/state_reg -> rbase/wbase/CE`，28 级 / 11.39 ns 逻辑、
  //   WNS −8.157）。根因：C2 起这条 96 bit 乘积 + `lenOk` 是**纯组合**地接到 `DdrMaster.io.len`，
  //   于是「配置寄存器 -> 乘积 -> len 合法性 -> CHK 比较 -> rbase/wbase 时钟使能」全在一条组合路上。
  //
  //   重排（三级，每级都短）：
  //     级1 whReg   = IMG_W * IMG_H        （32x32 -> 64）
  //     级2 prodReg = whReg * C_IN         （64x32 -> 96）
  //     级3 lenReg  = lenOk ? prodReg[31:0] : 0   （合法才驱动，否则 0 <=> 主口 CHK 必 err）
  //     ⇒ 逻辑深度被拆成「一个乘法/一级」，且 `DdrMaster` 只看到**已寄存的** `len`
  //       （配置寄存器到 CHK/CE 之间**再无组合通路**）。
  //
  //   为什么主机视角行为不变（明说，别让它成暗坑）：
  //     · 主机先在 AxiLite 上把 IMG_W/IMG_H/C_IN 写进寄存器，**再**写 `CTRL.start`
  //       （start 是**另一笔**事务，写完至少还要过若干拍）；`DdrMaster` 又是在 start 之后
  //       才进 CHK 态 ⇒ 三级流水的输出远在 CHK 采样之前就稳定。
  //     · 唯一的外部可观测差别：`len` 相对三个维寄存器晚 3 拍。对「先写寄存器、后写 start」
  //       的主机透明（闸门 TB `NpuTopTb.v`：三个维寄存器写入与 start 之间隔着 5 写 + 6 读
  //       事务，≫3 拍）。对 C3 调度器一路**无关**（那条路长度取自描述符，不走这里）。
  //     · 非法长度（含溢出）语义不变：`lenReg` 仍写 0 ⇒ 主口 CHK 一拍 err、零搬运。
  //   ★ 三个流水寄存器都用**无复位**的 `RegNext`（不带 init）：① 不改变「复位后 len=0」的
  //     可观测行为（配置寄存器复位后恒 0 ⇒ 级3 在 3 拍内即为 0）；② **不把新寄存器挂到复位网**上
  //     （板级 `soc_cpu_reset` fanout 已经极大，见 Round1 item 2 的复位树结论）。
  // ---------------------------------------------------------------------------
  val whReg   = RegNext(hostRegs.io.img_w * hostRegs.io.img_h)   // 级1（≤ 一个 32x32 乘法）
  val prodReg = RegNext(whReg * hostRegs.io.c_in)                // 级2（≤ 一个 64x32 乘法）：96 bit
  val nonzero = prodReg =/= 0                                    // 非 0
  val mult128 = prodReg(6 downto 0) === 0                        // 低 7 位为 0 <=> 是 128 的整数倍
  val fits32  = prodReg(95 downto 32) === 0                      // 落在 32 位内（挡溢出后静默搬错）
  val lenOk   = nonzero && mult128 && fits32
  val lenReg  = RegNext(Mux(lenOk, prodReg.resize(32), U(0, 32 bits)))  // 级3：已寄存的 len
  ddrMaster.io.len := lenReg

  // ---------------------------------------------------------------------------
  // 地址 / 启动（start 单拍脉冲直接透传即可，理由见文件头；★C3.12：按契约分给两路之一）
  // ---------------------------------------------------------------------------
  ddrMaster.io.src   := hostRegs.io.src_addr.resize(ddrCfg.ADDR_W)
  ddrMaster.io.dst   := hostRegs.io.dst_addr.resize(ddrCfg.ADDR_W)
  ddrMaster.io.start := hostRegs.io.start && !schedSel

  // C3.3 新增入参：C2 拷贝路径**不用** RD/WR 流式语义（那两路留给后续调度器任务），
  // 这里一律钉成 COPY 口径（mode=0，流向信号静默）。SpinalHDL 会拒绝悬空的组件输入
  // （不像手写 Verilog 里悬空 = z），所以这四条**必须**显式驱动。
  ddrMaster.io.mode     := U(0, 2 bits)   // COPY（RD/WR 语义留给调度器任务）
  ddrMaster.io.sg_valid := False           // ★ B3b：顶层 COPY 不用 SG-RD（NPU 内联的 UnitExec 自带实例）
  ddrMaster.io.sg_addr  := U(0, ddrCfg.ADDR_W bits)
  ddrMaster.io.sg_flush := False
  ddrMaster.io.sg_beatsM1 := U(0, 4 bits)
  ddrMaster.io.rd_ready := False
  ddrMaster.io.wr_valid := False
  ddrMaster.io.wr_data  := B(0, 64 bits)
  // ★★ T-S2b：写字节掩码（COPY 模式恒"全字节有效"⇒ 与改动前同形）
  ddrMaster.io.wstrb    := B(0xFF, 8 bits)

  // ---------------------------------------------------------------------------
  // ★ C3.12：调度器接线
  //   · descAddr/descCount 来自 HostRegs 的两个新 RW 档（desc_addr 是 32 位存储 ⇒ 截到 28 位主口宽度，
  //     与 `ddrMaster.io.src := src_addr.resize(28)` 同一手法：越窗地址由 LayerSched 的逐项字段校验
  //     响亮拦下，绝不会在这里静默截断 —— 见 LayerSched 文件头规则 (3)）；
  //   · go = CTRL.start 且走调度器分支（另一个分支下它恒 0，停在 IDLE）；
  //   · ★ C3.16：权重走**寄存器信箱**（HostRegs 的 WGT_SEL/WGT_ADDR/WGT_DATA/WGT_WE）直连调度器。
  //     口径（这一档补的是什么，明写）：C3.12 时本代 NPU 的对外端口集**不含**权重口 ⇒ 这里把四个
  //     装载口钉 0 ⇒ conv 累加恒 0 ⇒ 顶层跑出的是**零张量**，且板级 `dev_map` 会把整条卷积数据通路
  //     **常量折叠**掉（实测板级 Δ 只有 +647 LUT，见 `reports/c3_area.md` §10.3）。现在权重口**不再**是
  //     常量：它由主机经 AxiLite 寄存器窗逐字节写入 ⇒ 数据通路必须在网表里**留得住**，
  //     conv 也就能在顶层算出**真实张量**（数值证据见 `tools/run_nputop_sched_ab.sh` 的作业 W1/W2）。
  //   · 位宽裁剪（与 `ddrMaster.io.src := src_addr.resize(28)` 同一手法）：寄存器是**整 32 位存储**
  //     ⇒ 这里显式截到 `LayerSched`/`UnitExec` 的端口形状（切片下标 `log2Up(L_MAX)`、权重下标
  //     `log2Up(NENTRY)`）。越界编程（`wgt_sel ≥ L_MAX` / `wgt_addr ≥ NENTRY`）是**主机侧**的错：
  //     前者截断后落到另一个合法切片、后者截断后写到另一个合法条目 —— 都不会静默改到**数据通路**
  //     以外的东西，也不会误伤别的张量（权重只影响"算出来的数"，不影响地址/长度/突发）。
  // ---------------------------------------------------------------------------
  layerSched.io.descAddr  := hostRegs.io.desc_addr.resize(layerSched.ddrCfg.ADDR_W)
  layerSched.io.descCount := hostRegs.io.desc_count
  layerSched.io.go        := hostRegs.io.start && schedSel
  layerSched.io.wgt_sel   := hostRegs.io.wgt_sel.resize(layerSched.io.wgt_sel.getBitsWidth bits)
  layerSched.io.wgt_addr  := hostRegs.io.wgt_addr.resize(layerSched.io.wgt_addr.getBitsWidth bits)
  layerSched.io.wgt_data  := hostRegs.io.wgt_data
  layerSched.io.wgt_we    := hostRegs.io.wgt_we

  // ---------------------------------------------------------------------------
  // 事件锁存 + 中断（**口径与 C2 逐字相同**，只是事件源多了调度器一路）：
  //   errSticky —— err（块拷贝的 *或* 调度器的）的粘滞电平（喂 sched_err -> STATUS.bit1）；
  //   irqR      —— (done | err | frameDone) 的保持电平（顶层 irq，供电平敏感的 PLIC）。
  //   ★ 调度器一路只接 `frameDone`（**整帧唯一的一次**单拍脉冲）⇒ 帧内绝不抬中断（S4 纪律）；
  //     `layerSched.err` 与块拷贝 err 同口径，既进 errSticky 又抬 irqR。
  //   两者同口径：事件置 1，主机写 CTRL.soft_reset 清 0（清优先级更高，符合 w1c 习惯）。
  // ---------------------------------------------------------------------------
  val errSticky = Reg(Bool()) init False
  val irqR      = Reg(Bool()) init False

  when(ddrMaster.io.err || layerSched.io.err) { errSticky := True }
  when(ddrMaster.io.done || ddrMaster.io.err ||
       layerSched.io.frameDone || layerSched.io.err) { irqR := True }
  when(hostRegs.io.soft_reset)                { errSticky := False; irqR := False }

  // busy/done/err 三个状态输入按既有 C2 姿态合成（两路"或"；一次调用只有一路活跃）。
  hostRegs.io.sched_busy := ddrMaster.io.busy || layerSched.io.busy
  hostRegs.io.sched_done := ddrMaster.io.done || layerSched.io.frameDone
  hostRegs.io.sched_err  := errSticky
  // ★ 逐单元遥测（只读）：STATUS[31:8] = 已消费条目数（真表 67 项 ⇒ 0..67）
  hostRegs.io.sched_unitIndex := layerSched.io.unitIndex.resize(24)

  io.irq := irqR
}
