import spinal.core._

/** =====================================================================================
  * C4a.5a `MultiPassUnit` —— **宽层多趟累加的单元级数据通路**（`Conv3x3Slice` + `PartialSumBuf` + 编排）。
  * =====================================================================================
  *
  * ★ 冻结数据流（C4a.5 Step 1，逐字；与 `PartialSumBuf.scala` / `Conv3x3Slice.scala` 文件头同一份）：
  * ```
  * 一个"宽层" = 表里的一组连续 plain 单元（由转换器生成，本任务由 TB 手工给）
  *   第 1 趟：累加器清零（或直接写）；第 k>1 趟：读回部分和 → 加到本轮 acc → 写回
  *   片上部分和缓冲：C_out 行 × 8 B（= 64 B/co-block），RAM 结构（DRM），不得落 FF
  *   注意与 C3 的"输出存储 readAsync 是 LUTRAM"是两回事：这里必须是 block RAM，判据由 dev_map 给
  *   （dev_map 的 DRM 判据属 C4a.5b；本片先把缓冲建出来并保证结构正确）
  * ```
  * ★★ §3.7：上面框里的"8 B"已收窄为 `PSW`（缺省 **4 B/32 bit**，可证界 `9,363,456 < 2^24`；见文件尾）。本片是 **C4a.5a（数据通路半边）**：把"一条 `ci` 趟"跑成 `Conv3x3Slice` 的一次流式通过，把部分和
  * 落在 `PartialSumBuf`（`readSync` + 上电初值 0 ⇒ DRM），把 `ci` 趟**串起来**（第 k>1 趟读回 → 加 → 写回）。
  * ★ **本片不做**（C4a.5b）：把这条流接进 `UnitExec`/`NpuTop`、`LayerSched` 分派、以及 DRM 的 `dev_map`
  *   判据。`M`（每层 Q24 乘子）在本片是**端口**（TB 直接喂），到 C4a.5b 才由权重信箱按 `LAYER_ID` 装载。
  *
  * ================================ 一趟 = 一次流式通过（本单元的分工） ================================
  * 单元**不含"趟"的状态机**：趟的切分由驱动方（本任务：TB 手工给；C4a.5b：`UnitExec` 编排）给出——
  * 每个 `ci` 趟做三件事：
  *   1. 预载该趟的权重瓦片（`Wt[8co, 8ci, 3, 3]`：SKIP 通道与跨组位置填**真实零码 z_w**，见 C4a.4 冻结规则）；
  *   2. 脉冲一拍 `io.start`：给 `Conv3x3Slice` 的 `prime`（per-image 相位复位）+ 把本单元的**读地址
  *      指回本段（co-block）的像素 0**；
  *   3. 把该趟的输入流（该 `ci` 块的 8 个通道，行主序、含驱动方多喂的一行全 0 pad）喂进 `x/x_valid`。
  *   `ci` 趟之间的**累加**是结构性的：切片输出 `ps_out = 本轮 acc + ps_in + bias`，本单元把它**当拍写回**
  *   缓冲的**同一个像素槽**；而 `ps_in` 来自缓冲的**同步读**（一个像素的 8 个 co 行一次读出）。
  *   ⇒ 一个像素在一次 pass 内只被写一次、读一次；`start` 把读地址复位 ⇒ 第 1 趟读到的就是**上电初值 0**。
  *
  * ---- 读地址怎么"抢在切片出数之前"（本单元唯一的时序技巧）----
  * `PartialSumBuf` 是**同步读**（第 T 拍给地址、第 T+1 拍出数据），而 `Conv3x3Slice` 在**出数那一拍**
  * （`y_valid`，像素节拍 11 拍）就要用 `ps_in`。于是本单元把读地址**提前**摆好：
  *   · `start` 拍 ⇒ 读地址 = 本段像素 0；
  *   · 每次 `y_valid` ⇒ 读地址 = 本段**下一个**像素（`y_valid` 间隔 11 拍 ⇒ 地址在整段间隔里稳定）。
  * ⇒ 处理像素 p 时读地址早已是 p（且**每一个像素只发一次读地址**），读回的必然是"本趟之前"那一次写进去的值
  *   （读-旧语义；见 `FusionBuf`/`PartialSumBuf` 文件头）。★ 这一条**不依赖**"同址读写同拍读旧值"那条与
  *   器件相关的性质：我们在**前一个像素**的写作之前就把地址摆好了。
  *
  * ================================ 地址分段：co-block 之间不互相踩 ================================
  * 字地址 = `cob * PIXMAX + pix`（`io.cob` = 当前 co-block 下标，由驱动方给）。跨 `co` 趟各写自己那段 co
  * （C4a.4 冻结规则）⇒ 不同 co-block 的部分和**地址不重叠** ⇒ 一个 co-block 跑完**不需要清缓冲**，
  * 下一个 co-block 的第 1 趟读回的是**上电初值 0**。这正是"第 1 趟累加器清零"的落点，也是 C4a.5 负对照 B
  * （缓冲初值非 0 ⇒ 判据必红）能发火的结构性前提。
  *
  * ================================ 输出 ================================
  * `io.y/y_valid` **直通** `Conv3x3Slice` 的 `y/y_valid`（**每一趟都出**）。不是最后一趟的那些料是
  * "只累加了一半"的中间值，**由驱动方丢弃**（本任务：TB 只在最后一趟收集；C4a.5b：`UnitExec` 同理）。
  * 这样做的理由：requant 在切片里是**组合**的，加一个"最后一趟才出料"的门会把它变成又一路状态；
  * 而"第 k>1 趟读出的是全部 `ci` 的部分和"这件事本身已经由**缓冲的写回**保证了 —— 出料门是纯装饰。
  * ★★ C4a-R2 更新：requant 现在在切片里是**三级流水**（`Conv3x3Slice` 文件头"★★ C4a-R2"）⇒
  *   `y/y_valid` 比"出数拍"晚 3 拍；而 `ps_out` 的写回契约挂在切片的 **`ps_valid`**（= 出数拍本身）上
  *   ⇒ 本单元的写回/读地址推进相位**逐拍未变**（见类体里 `psb.io.wr_en := sl.io.ps_valid` 那一行）。
  *   出料门仍是**纯装饰**这条口径不变（`y_valid` 只是相位后移，不筛趟）。
  *
  * 自报口：`imgC/imgW/pixMax/ncob` 钉死生成参数；`psDepth/psWordBytes/psRowBytes/psRows` 把
  * 部分和缓冲的形状（C_out 行 × PSW/8 B、字 = 一个 co-block）报出来，供装置在 time 0 对账。
  * ===================================================================================== */
class MultiPassUnit(val WIDTH: Int = 8, val PIXMAX: Int = 32, val NCOB: Int = 8, val PSW: Int = 32, val X1: Boolean = false, val DW: Boolean = false, val DCI: Boolean = false) extends Component {
  /** 硬件切片固定 8x8（更宽的层靠多趟复用，见 `Conv3x3Slice` 的 require）。 */
  val C   = 8
  /** requant 右移（冻结 6；`Conv3x3Slice` 展开期 require 会再钉一次）。 */
  val SHIFT = 6
  require(WIDTH >= 3, "3x3 窗口至少要 3 列")
  require(PIXMAX >= 1 && NCOB >= 1, "PIXMAX/NCOB 至少 1")
  require(PIXMAX <= 65535 && NCOB <= 65535, "自报口是 16 位"); require(PSW >= 8 && PSW <= 64 && PSW % 8 == 0, "行宽 PSW ∈ [8,64] 且为 8 的倍数（§3.7）")

  val cw  = (log2Up(WIDTH) max 1)
  val paw = (log2Up(NCOB * PIXMAX) max 1)
  val pw  = (log2Up(PIXMAX) max 1)
  val cbw = (log2Up(NCOB) max 1)

  val io = new Bundle {
    // ---- 权重装载（直通切片；每趟之前由驱动方预载该趟的瓦片）----
    val we    = in  Bool()
    val waddr = in  UInt (log2Up(C * (C) * 9) bits)
    val wdin  = in  SInt (8 bits)
    // ---- 输入流（直通切片；行主序、每拍一列 C 个通道）----
    val x       = in  Vec (SInt(8 bits), C)
    val x_valid = in  Bool()
    val x_ready = out Bool()
    // ---- 趟控制 ----
    /** 一拍脉冲（每趟一次）：复位切片相位（`prime`）+ 把部分和读地址指回本段像素 0。 */
    val start = in  Bool()
    /** 当前 co-block 下标（部分和缓冲的分段基址 = `cob*PIXMAX`）。 */
    val cob   = in  UInt (cbw bits)
    /** 每层 Q24 乘子 `M`（C4a.5b 由权重信箱装载；本片由驱动方直接喂）。 */
    val requant_m = in UInt (32 bits)
    /** 输出张量的 zero-point `z_y`。 */
    val zero_y = in SInt (8 bits)
    /** ★ C4a.5b §4.5：零填充码点（该层 `z_pad` = `z_x`）—— 直通切片（上/左/右填充都读它）。
      *   喂 0 ⇒ 与 C4a.5a 逐字节同形（既有闸门不改）。 */
    val pad_val = in SInt (8 bits)
    /** ★★ C4b-D1：**卷积步长**（描述符 `w3[11:8]`；字段 `0` 视作 `1`）—— 直通切片。
      *   宽层"一层的几何"（输入 `H×W`、输出 `Ho×Wo`）由**驱动方**给（每趟喂 `H_in+1` 行 × `W` 列）；
      *   本单元只把步长转给切片 ⇒ **每一趟**（`ci` 块）按**同一个**步长抽稀 —— 这是多趟累加成立的前提
      *   （各趟的像素序必须逐位相同，部分和才能按同一 `pixIdx` 跨趟相加）。喂 1 ⇒ 与改动前逐字节同形。 */
    val stride = in UInt (4 bits)
    /** ★★ T-S1（2026-10-13）：**运行期行宽**（= 本层输入行宽；`WIDTH` 是分配上限 `W_MAX`）—— 直通切片。
      *   驱动方（`UnitExec`）在每层 `go` 那一刻给出；`rowW == WIDTH` ⇒ 与旧行为逐字节同形。 */
    val rowW   = in UInt (16 bits)
    /** ★★ T-S2b：**部分和清零门**（一趟开始时，"读回的部分和"是否当作 0）。
      *   `False`（= 除宽路 tile 循环外的**全部**调用方）⇒ `ps_in` 直通缓冲的同步读
      *     ⇒ 与改动前**逐字节/逐拍同形**；
      *   `True` ⇒ `ps_in ≡ 0`，即"本趟从零开始累加"。
      *   为什么需要它：**tile 循环**下每个 tile 都要把 `ceil(C_in/8)×ceil(C_out/8)` 趟重跑一遍，
      *   而部分和缓冲的地址只按 `(co-block, 像素)` 分段 —— 第 2 个 tile 的第 1 趟若照旧读回，
      *   读到的是**上一个 tile 的残值**。驱动方（`UnitExec`）在"某 co-block 的第 1 趟"
      *   （dense: `ci==0`；depthwise: 唯一的对角趟）举起本门 ⇒ 累加器清零语义与"上电初值 0"
      *   在**数值上完全一致**（第 1 趟 = 0 + 本轮 acc + bias）。 */
    val ps_clr = in Bool()
    /** 累加器单位的偏置（**只在该层第 1 趟非 0**；其余趟必须给 0）。 */
    val bias = in Vec (SInt(32 bits), C)
    // ---- 输出（直通切片；每一趟都出，非最后一趟的料由驱动方丢弃）----
    val y       = out Vec (SInt(8 bits), C)
    val y_valid = out Bool()
    // ---- 自报（生成参数钉死）----
    val imgC       = out UInt (16 bits)
    val imgW       = out UInt (16 bits)
    val pixMax     = out UInt (16 bits)
    val ncob       = out UInt (16 bits)
    // ---- 自报（部分和缓冲的形状：C_out 行 × PSW/8 B、字 = 一个 co-block 共 C*PSW/8 B；缺省 32 bit）----
    val psRows     = out UInt (16 bits)   // = C（输出通道行数）
    val psRowBytes = out UInt (16 bits)   // = PSW/8（每行的字节数；★ §3.7 缺省 4）
    val psWordBytes= out UInt (16 bits)   // = C*PSW/8（一个 co-block 的字宽，字节；缺省 32）
    val psDepth    = out UInt (16 bits)   // = NCOB*PIXMAX（字数）
    // ---- 观察（不参与数据通路）----
    val pixCount  = out UInt (32 bits)    // 本趟已产出的像素数（`start` 复位）
    val obsRdAddr = out UInt (paw bits)   // 部分和读地址（观察/对账）
    val obsWrAddr = out UInt (paw bits)   // 部分和写地址（观察/对账）
  }
  noIoPrefix()

  // ---------------------------------------------------------------------------
  // 两个部件（都**一字未改**，只接线）：8x8 切片 + 部分和缓冲
  // ---------------------------------------------------------------------------
  val sl  = new Conv3x3Slice(C_IN = C, C_OUT = C, GROUP = 1, WIDTH = WIDTH, SHIFT = SHIFT, PSW = PSW, X1SKIP = X1, DWSKIP = DW, DCI = DCI)   // ★ §3.7：`PSW` 逐参数下发；★ slice A：`X1SKIP` 同；★ slice B1：`DWSKIP` 同；★ slice C2：`DCI` 同
  val psb = PartialSumBuf(C_OUT = C, NCOB = NCOB, PIXMAX = PIXMAX, PSW = PSW)

  // 自报（常量输出）
  io.imgC        := U(C, 16 bits)
  io.imgW        := U(WIDTH, 16 bits)
  io.pixMax      := U(PIXMAX, 16 bits)
  io.ncob        := U(NCOB, 16 bits)
  io.psRows      := U(C, 16 bits)
  io.psRowBytes  := U(PSW / 8, 16 bits)
  io.psWordBytes := U(C * PSW / 8, 16 bits)
  io.psDepth     := U(NCOB * PIXMAX, 16 bits)

  // 权重/输入直通
  sl.io.we    := io.we
  sl.io.waddr := io.waddr
  sl.io.wdin  := io.wdin
  sl.io.x       := io.x
  sl.io.x_valid := io.x_valid
  io.x_ready := sl.io.x_ready
  sl.io.prime   := io.start        // 每趟一拍：把切片（+其 LineBuffer）的 per-image 相位清回上电态
  sl.io.pad_val := io.pad_val      // ★ C4a.5b §4.5：零填充码点（喂 0 ⇒ 旧行为）
  sl.io.stride  := io.stride       // ★★ C4b-D1：步长直通（喂 0/1 ⇒ 与改动前逐字节同形）
  sl.io.rowW    := io.rowW         // ★★ T-S1：运行期行宽直通（分配仍按 WIDTH；喂 WIDTH ⇒ 逐字节同形）
  sl.io.bias      := io.bias
  sl.io.requant_m := io.requant_m
  sl.io.zero_y    := io.zero_y

  // ---------------------------------------------------------------------------
  // 部分和缓冲的读写（"读回 → 加到本轮 acc（在切片里） → 写回"的落实）
  // ---------------------------------------------------------------------------
  /** 本段的字基址 = `cob * PIXMAX`。 */
  val base = (io.cob.resize(paw) * U(PIXMAX, paw bits)).resize(paw)

  val pixIdx = Reg(UInt(32 bits)) init (0)          // 本趟已产出的像素数（`start` 复位）
  val rdAddr = Reg(UInt(paw bits)) init (0)         // 读地址：**提前一拍**摆好（见文件头）

  // 读：一个像素的 8 行一次读出（同步读，1 拍延迟）⇒ 切片在出数那一拍手上就有 `ps_in`
  psb.io.rd_addr := rdAddr
  // ★★ T-S2b：`ps_clr`（tile 循环的"第 1 趟"）⇒ `ps_in ≡ 0`（= 累加器清零）；否则直通缓冲。
  sl.io.ps_in    := Mux(io.ps_clr, Vec((0 until C).map(_ => S(0, PSW bits))), psb.io.rd_data)

  // 写：切片的**出数脉冲**（`ps_valid`）那一拍把 `ps_out = 本轮 acc + ps_in + bias` 写回**同一像素槽**
  //   ★★ C4a-R2：这里由 `sl.io.y_valid` 改成 `sl.io.ps_valid` —— `Conv3x3Slice` 的 requant 改成
  //     三级流水后，`y_valid` 比"出数拍"晚 3 拍，而 `ps_out` 仍只在**出数拍**成立（见切片文件头
  //     "★★ C4a-R2"）。`ps_valid` 就是那个**未延迟**的出数脉冲 ⇒ 本单元写回/读地址推进的相位
  //     **与改动前逐拍相同**（`ps_valid` 与被替换掉的旧 `y_valid` 是同一个信号）。
  psb.io.wr_addr := (base + pixIdx(pw - 1 downto 0).resize(paw)).resize(paw)
  psb.io.wr_en   := sl.io.ps_valid
  for (co <- 0 until C) { psb.io.wr_data(co) := sl.io.ps_out(co) }

  when(io.start) {
    // 趟起点：读地址回到本段像素 0（第 1 趟读到的是**上电初值 0** ⇒ "累加器清零"）
    pixIdx := U(0, 32 bits)
    rdAddr := base
  } .elsewhen(sl.io.ps_valid) {
    // 出完一个像素 ⇒ 读地址指向下一个像素（在它被处理之前就摆好；像素节拍 11 拍 ⇒ 地址稳定）
    pixIdx := pixIdx + 1
    rdAddr := (base + (pixIdx + 1)(pw - 1 downto 0).resize(paw)).resize(paw)
  }

  // 出料直通（每一趟都出；非最后一趟的料由驱动方丢弃）
  //   ★★ C4a-R2：`y/y_valid` 是切片 requant **三级流水之后**的出料（比"出数拍"晚 3 拍）；
  //     本单元只直通，不改相位。驱动方（TB / `UnitExec`）按 `y_valid` 认像素 ⇒ 逐字节不变。
  io.y       := sl.io.y
  io.y_valid := sl.io.y_valid

  // 观察口
  io.pixCount  := pixIdx
  io.obsRdAddr := rdAddr
  io.obsWrAddr := psb.io.wr_addr

  // ===========================================================================
  // ★★ NPU v2 §4.6-5（slice A，2026-10-16）：**1×1 只发 1 个 tap-beat** —— 本单元只做**转发**
  // ===========================================================================
  // 口径与理由（逐字与 `Conv3x3Slice.scala` 文件尾「slice A」一节同一份，此处不重复）：
  //   · `one_x1`（入）—— 驱动方（`UnitExec`）按**描述符 TYPE `0x02`** 给：本趟是不是 1×1 卷积；
  //     它被直通给切片的同名口（切片的相位推进在 ph==1 时直接跳到 ph=10 ⇒ 像素相位 = 1 抽头）。
  //     `one_x1=0` ⇒ 本单元与改动前**逐拍/逐字节同形**（既有闸门就是这么喂的）。
  //   · `obs_beats`（出）—— 切片 `obs_beats` 的直通 = **tap-beat 计数**（`arr.en` 拍数；上电起累计）。
  //     供 TB/闸门**实测** `beats_issued = taps·passes·H·W` 这条账（`run_x1skip_ab.sh` 断言预测值）。
  //   · **只在 `X1=true` 的展开里存在**（`X1` 缺省 false ⇒ `gen/MultiPassUnit.v` / `gen/DwUnit.v`
  //     的独立展开**一个端口都不加**，逐字节不变）；`UnitExec(TILING=true)` 显式传 `X1 = TILING`。
  //   · 行数中性：本节追加在类体最后一条语句之后 ⇒ 既有语句行号一根没动（`PSW` 那节的同款理由）。
  // ===========================================================================
  val one_x1: Bool = if (X1) { val v = in Bool(); v.setName("one_x1"); v } else null
  val obs_beats: UInt = if (X1) { val v = out UInt(32 bits); v.setName("obs_beats"); v } else null
  if (X1) {
    sl.one_x1   := one_x1
    obs_beats   := sl.obs_beats
  }

  // ===========================================================================
  // ★★ NPU v2 切片 B1（2026-10-16）：**depthwise 用满 8 条通道**（AFTER1）—— 本单元只做**转发**
  // ===========================================================================
  // 口径与理由（逐字与 `Conv3x3Slice.scala` 文件尾「slice B1」一节同一份，此处不重复）：
  //   · `dw_mode`（入）—— 驱动方（`UnitExec`）按 `isDwW`（描述符 `GROUP==C_in==C_out`）在 `go` 那
  //     一拍锁存后给；它被直通给切片的同名口（切片的相位推进在 dw 档 ph==1 时直接跳到 ph=10 ⇒
  //     像素相位 = 1 抽头；逐 lane 的 x/w 由切片的 dw 块静态直连）。`dw_mode=0` ⇒ 逐拍/逐字节同形。
  //   · `obs_beats`（出，复用 slice A 的口）—— 切片 `obs_beats` 的直通 = **tap-beat 计数**（`arr.en`
  //     拍数）。dw 档实测 **1 拍/像素/趟**（dense 仍 9 拍）—— 闸门按预测量断言（报告 §Slice B-1 的
  //     9.00× 是探针读数；本单元在 `UnitExec(TILING=true)` 上是它的**集成**面）。
  //   · **只在 `DW=true`（本代 = `TILING=true`）的展开里存在**（`DW` 缺省 false ⇒ `gen/MultiPassUnit.v`
  //     / `gen/DwUnit.v` 的独立展开**一个端口都不加**，逐字节不变；`TILING=false` 的 `UnitExec`
  //     同样不 elaborate 本节 ⇒ 三份冻结网表逐字节不变）。
  //   · 行数中性：本节追加在类体最后一条语句之后 ⇒ 既有语句行号一根没动。
  // ===========================================================================
  val dw_mode: Bool = if (DW) { val v = in Bool(); v.setName("dw_mode"); v } else null
  if (DW) {
    require(X1, "DW 依赖 X1 的 `obs_beats` 口（本代两个口同生同灭，见报告 §Slice B-1）")
    sl.dw_mode := dw_mode
  }

  // ===========================================================================
  // ★★ NPU v2 切片 C2（2026-10-16）：**dense ci-inner（DCI）** —— 本单元只做**转发**
  // ===========================================================================
  // 口径与理由（逐字与 `Conv3x3Slice.scala` 文件尾「切片 C2」一节同一份，此处不重复）：
  //   · `dci_mode`（入）—— 驱动方（`UnitExec`）按 `isDciW`（宽路 ∧ dense(GROUP==1) ∧
  //     `0 < C_in ≤ 4`（⇒ nCi==1）；与切片 C-1 钉死的判据逐字同式）在 `go` 那拍锁存后给；
  //   · `c3_cin`（入，4 bit）—— 该层 `C_in`（同拍锁存；真表 ∈ {3,1}）；切片用它做相位跳拍的长度
  //     （`ph === c3_cin ⇒ ph := 10`，像素相位 9 → `C_in` 拍）；
  //   · 两口被直通给切片的同名口（逐 lane 的 x/w 来源选择与 c3 读口都在切片/`WeightStore` 里）。
  //     `dci_mode=0` ⇒ 本单元与改动前**逐拍/逐字节同形**（既有闸门就是这么喂的）。
  //   · **只在 `DCI=true`（本代 = `DW=true`）的展开里存在**（`DCI` 缺省 false ⇒ `gen/MultiPassUnit.v`
  //     / `gen/DwUnit.v` 的独立展开**一个端口都不加**，逐字节不变；`TILING=false` 的 `UnitExec`
  //     同样不 elaborate 本节 ⇒ 三份冻结网表逐字节不变）。
  //   · 行数中性：本节追加在类体最后一条语句之后 ⇒ 既有语句行号一根没动。
  // ===========================================================================
  val dci_mode: Bool = if (DCI) { val v = in Bool(); v.setName("dci_mode"); v } else null
  val c3_cin: UInt = if (DCI) { val v = in UInt (4 bits); v.setName("c3_cin"); v } else null
  if (DCI) {
    require(DW, "DCI 依赖 DW 的逐 lane 口与 `obs_beats`（本代两个档同生同灭，见报告 §Slice C-1）")
    sl.dci_mode := dci_mode
    sl.c3_cin := c3_cin
  }
}

/* =====================================================================================
  * ★★ §3.7（2026-10-16）：**部分和行宽 64 → 32 bit**（追加在**文件最后一行之后** ——
  *   `UnitExec.scala` 文件尾同一套理由：SpinalHDL 把源码行号编进内部网名（`_zz_*_l####`），
  *   而 `TILING=false` 的三份冻结网表（`gen/UnitExec.v/_w32/_w640`）要求**逐字节不变** ⇒
  *   既有行的行号一个都不能动，新 prose 只能追加。）
  * =====================================================================================
  *
  * 本单元只是**转发**：`PSW`（bit，缺省 32）逐参数下发给 `Conv3x3Slice`（`ps_in/ps_out` 宽度）
  * 与 `PartialSumBuf`（行宽），并把自报口改成随 `PSW` 走（`psRowBytes = PSW/8`、
  * `psWordBytes = C*PSW/8`）。数值口径一字未动：`ps_out = 本轮 acc + ps_in + bias` 的**加法与
  * requant 折算逐位同值**（界内不丢位）；变的只是"存多少位"。
  *
  * 尺寸（缺省 `C=8 / NCOB=8 / PIXMAX=1088`）：行宽 64→32 bit ⇒ `WORD_W` 512→256 bit、
  * `DEPTH` 不变 ⇒ **557,056 B → 278,528 B**（约 −272 KB / −50%）。
  *
  * 可证界（spec §3.7）：`|acc| ≤ 128·127·576 = 9,363,456 < 2^24` ⇒ 25 bit 有符号够、32 bit 有余量。
  *   · **正对照**：`tools/run_psbound_ab.sh` 用"满幅度激励"（`x=-128`、`w=127`、576 taps）跑
  *     缺省 32 bit 网表 ⇒ 逐字节 == 冻结参考（`tiling_ref.conv_tiled`）；实测峰值 `|acc| = 9,363,456`；
  *   · **负对照**：同激励跑 24 bit 档（`PSW=24`，**低于可证界**）⇒ 必红（`MISMATCH > 0`）。
  *   · `TILING=false` 的三份冻结网表由 `UnitExec` 显式钉 `PSW=64`（历史档，逐字节冻结）。
  * ===================================================================================== */

/* =====================================================================================
  * ★★ 切片 C2（2026-10-16）：`DCI` 参数（dense ci-inner 的转发档）—— 设计出处与纪律
  * =====================================================================================
  *
  * 出处：spec §4.6b-②（切片 C-1 钉死的接口）/ `reports/npu_v2_accounting.md` §Slice C-1 §C1-3。
  * 本单元只是**转发** `dci_mode`/`c3_cin` 给内层 `Conv3x3Slice`（同 `one_x1`/`dw_mode` 的手法）：
  *   · `DCI=false`（缺省 = `MultiPassGen` / `DwGen` / `TILING=false` 的 `UnitExec`）⇒
  *     **零端口、零线**、类体既有语句行号一根不动（新增段只能在类体最后一条语句之后）；
  *   · `DCI=true`（只由 `UnitExec(TILING=true)` 下发 = 本代 `UnitExec_tiled.v` / `LayerSched` /
  *     `NpuTop`）⇒ 两个入端口 + 两行直通。
  * 数值口径一字未动：DCI 的拍序重排（ci 进拍、tap 进 lane）全在切片与 `WeightStore` 里，本单元
  * 不参与任何算术；`ps_out/ps_valid`、部分和缓冲、收料门、趟循环全部沿用。
  * ===================================================================================== */
