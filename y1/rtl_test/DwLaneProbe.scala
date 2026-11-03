import spinal.core._

/** =====================================================================================
  * ★★ NPU v2 切片 B-1：**depthwise 用满 8 条通道**的**独立探针**（不是产品 RTL；本片不改 y1/rtl 下的任何行）。
  * =====================================================================================
  *
  * 为什么有这个文件（本片的问题陈述，逐字见 spec §5 表序 3 / `reports/npu_v2_accounting.md` §P0b-3）：
  *   现宽通路的 dw 走**对角趟**（`UnitExec.isDwW`），而 `Conv3x3Slice` 的 x 操作数是**一条 8 宽广播总线**
  *   （`arrX(ci) = colWin(tapKx)(ci)(tapKy)`，喂给 8 行 co 的同一个值）⇒ 一拍 64 槽里**只有对角 8 槽**有用
  *   （`MacArray` 的行 = co、列 = ci，dw 的权重只在 co==ci 非 0）⇒ 每像素 9 拍、64 槽里 8 个有用（8.10× 浪费）。
  *   要让**每拍 64 条 lane 都有用**，必须把**抽头维度**当内维：lane `(c, k)` 算 `x[c][k]·w[c][k]`
  *   —— 那时 x 不再是广播，而是**逐 lane**的窗口读（本文件要测的正是这条 x 路由的价钱）。
  *
  * 三种被测档（**同一份源码，只差展开期 MODE**；网表各自独立生成，TB 一次只编译一份 ⇒ 模块名可以同名）：
  *   MODE 0 = **BEFORE**（as-built）：广播 x、每像素 9 个 tap-beat（= `Conv3x3Slice` 的现行为）。
  *   MODE 1 = **AFTER2**（tap-inner 打包，P0b 的"保守打包 2 拍/像素/趟"）：每拍 8 个抽头（lane j = 抽头 j），
  *            第 9 抽头在第 2 拍，落在 lane 0（其余 lane 权重置 0）⇒ **2 拍/像素**、无新增乘法器。
  *   MODE 2 = **AFTER1**（tap-inner + **第 9 抽头行**）：8×8 阵列吃抽头 0..7，另加**一行 8 个乘法器**
  *            （`io.x8/io.w8`）吃抽头 8，其积并进同一个 acc ⇒ **1 拍/像素**（= P0b 的"理想式"拍数）。
  *
  * ---------------------------------------------------------------- 关键结构性发现（本探针要证的第一条）
  * **x 路由在 dw 档是"静态重排"，不需要 8×8 交叉开关**：
  *   · 9 个抽头对**同一个像素同一拍**全都已经在 `colWin` 里（`colWin` 只在收列/幻影拍移位；9 个 tap 是
  *     3(cx) × 8(ci) × 3(rr) 个寄存器的**静态**读法：`tap(ky,kx) = colWin(kx)(ci)(ky)`）；
  *   · BEFORE 的读法是"lane = 通道 ci、值 = 每拍动态的 `(kx,ky)`"（动态维度 = 抽头 ⇒ 需要 9 选 1 多路选择器）；
  *   · AFTER 的读法是**把两个下标换过来**："lane = 抽头 j、值 = 该 lane 的**通道 r**"——`(kx_j, ky_j)`
  *     对每个 lane 是**常数** ⇒ lane(r,j) 的 x 就是**某一条寄存器的直连**（`colWin(j%3)(r)(j/3)`），
  *     **一个多路选择器都不需要**。
  *   · 权重同理：dw 的对角零填瓦片里，`mem[r*72 + r*9 + k]` 就是"通道 r 的第 k 个抽头"（`WeightStore` 的
  *     576 个寄存器本来就在片上）⇒ AFTER 档的权重也是**静态寄存器直连**（BEFORE 档才要 9 选 1）。
  *   ⇒ 唯一必需的新逻辑是**"两种模式选一个"的逐 lane 2:1 选择器**（64 lane × x + 64 lane × w）
  *     —— 因为一张网表要同时服务 dense（广播）与 dw（逐 lane）。这就是本探针 dev_map 要测的**增量**。
  *
  * ---------------------------------------------------------------- 口径（与冻结参考对齐，不是"另一条算术路"）
  *   · 窗口/相位/幻影列/预滚行：逐条照抄 `rtl/Conv3x3Slice.scala` 的 `s=1` 口径（`LineBuffer` 也是直接例化
  *     真类，未改一行）；`ps_in` 不接（dw 对角趟 = 每个 co-block 唯一一趟 ⇒ 部分和恒为缓冲上电值 0）。
  *   · 输出：`accTot = arr.p(co) + bias(co)`，`y = clamp( ((accTot·M)>>30) + z_y )`（= 冻结
  *     `quant_ref.requant_int` 的整数同值；探针不做三级流水，那是时序项，与数值无关）。
  *   · 拍数观测口 `obs_beats` = `arr.en` 拍数（上电起累计）—— `mac_account.py` 的
  *     `beats_issued = taps·passes·H·W` 的**实测**对应物（BEFORE 9 / AFTER2 2 / AFTER1 1 拍/像素/趟）。
  *
  * ---------------------------------------------------------------- 负对照的外科锚（`MUTX`）
  * `MUTX = j ≥ 0` ⇒ lane j 的 **x 路由**被改错（`kx` 由 `j%3` 改成 0，`ky` 不变）⇒ 第 j 个抽头的 x 被
  * 换成"同一行的最左列"。这是一条**只动路由、不动算术**的突变（`run_dwlane_ab.sh` 用它做"路由承重"的
  * 负对照，预测值由 python 从冻结向量现算）。
  * ===================================================================================== */
/** `rtl/WeightStore.scala` 的**同一条逻辑**（576 个 int8 寄存器 + 按 (ky,kx) 的 9 选 1 瓦片），
  * 只多一个 **additive 的"dw 静态对角读口"**：`dwTile(r)(j) = mem[r*PER_GROUP*9 + r*9 + j]`
  * （= 对角 entry `(r,r)` 的第 `j` 个抽头 = "通道 r 的第 j 个抽头"权重）。
  *
  * 为什么必须在 WeightStore 这一侧加口（而不是在探针顶层"读它的寄存器"）：SpinalHDL 的分层检查
  * **禁止父组件读子组件的内部信号**（本文件的第一次编译就被这条拦下）⇒ 生产 RTL 里这条改动
  * 也必须是 WeightStore 的一个新读口。`DW=false` 时本类与 `rtl/WeightStore.scala` **逐字同构**
  * （一个端口都不多）⇒ BEFORE 档拿它当"现网表的那一份"。
  *
  * 前提（为什么 `mem[r*72+r*9+j]` 就是"通道 r 的抽头 j"）：宽通路装载器对 dw 的趟瓦片做**跨组零填**
  * （`UnitExec.scala` §C4b-B1c：对角趟上只有 `cl==cil` 非 0）⇒ 这一口的读法**不需要**改 blob/装载器。 */
class DwLaneWeightStore(val DW: Boolean = false) extends Component {
  val C_IN = 8
  val C_OUT = 8
  val PER_GROUP = 8
  val NENTRY = C_OUT * PER_GROUP * 9
  val io = new Bundle {
    val we    = in  Bool()
    val waddr = in  UInt (log2Up(NENTRY) bits)
    val wdin  = in  SInt (8 bits)
    val k     = in  UInt (4 bits)
    val tile  = out Vec (Vec(SInt(8 bits), C_IN), C_OUT)
  }
  noIoPrefix()
  /** ★ additive：dw 静态对角读口（只有 `DW` 档存在）。 */
  val dwTile: Vec[Vec[SInt]] =
    if (DW) { val v = out Vec (Vec(SInt(8 bits), 8), 8); v.setName("dwTile"); v } else null
  val dwTile8: Vec[SInt] =
    if (DW) { val v = out Vec (SInt(8 bits), 8); v.setName("dwTile8"); v } else null

  val mem = Vec(Reg(SInt(8 bits)) init (0), NENTRY)
  val aw = io.waddr.getBitsWidth
  when(io.we) {
    for (i <- 0 until NENTRY) {
      when(io.waddr === U(i, aw bits)) { mem(i) := io.wdin }
    }
  }
  for (co <- 0 until C_OUT) {
    for (ci <- 0 until C_IN) {
      val base = co * PER_GROUP * 9 + ci * 9
      val plane = (0 until 9).map(kk => mem(base + kk))
      var sel: SInt = S(0, 8 bits)
      for (kk <- 8 to 0 by -1) { sel = Mux(io.k === kk, plane(kk), sel) }
      io.tile(co)(ci) := sel
    }
  }
  if (DW) {
    for (r <- 0 until 8) {
      for (j <- 0 until 8) { dwTile(r)(j) := mem(r * PER_GROUP * 9 + r * 9 + j) }
      dwTile8(r) := mem(r * PER_GROUP * 9 + r * 9 + 8)
    }
  }
}

/** 与 `rtl/MacArray.scala` **同一条算术**（对和寄存器 → 平衡树 → int32 累加），只有两处不同：
  *   · `io.x` 从"8 宽广播"变成**逐 lane** `x(co)(ci)`（tap-inner 档的逐 lane 窗口读）；
  *   · `TAP8=true` 时多**一行 8 个乘法器**（`io.x8/io.w8`，第 9 抽头），积并进同一个 `acc`。 */
class DwLaneMacArray(val TAP8: Boolean = false) extends Component {
  val io = new Bundle {
    val x   = in  Vec (Vec(SInt(8 bits), 8), 8)   // x(co)(ci)：逐 lane（dw 档 lane ci = 抽头下标）
    val w   = in  Vec (Vec(SInt(8 bits), 8), 8)   // w(co)(ci)：逐 lane
    val en  = in  Bool()
    val clr = in  Bool()
    val p   = out Vec (SInt(32 bits), 8)
  }
  noIoPrefix()
  /** ★ 只在 `TAP8` 的档里存在（第 9 抽头行）—— additive 口，缺省档一根线都不加。 */
  val ioX8: Vec[SInt] = if (TAP8) { val v = in Vec (SInt(8 bits), 8); v.setName("x8"); v } else null
  val ioW8: Vec[SInt] = if (TAP8) { val v = in Vec (SInt(8 bits), 8); v.setName("w8"); v } else null

  val PSW = 18
  val acc = Vec(Reg(SInt(32 bits)) init (0), 8)
  val ps  = Vec(Vec(Reg(SInt(PSW bits)) init (0), 4), 8)
  val enD = RegNext(io.en) init (False)

  for (co <- 0 until 8) {
    val prod = (0 until 8).map(ci => io.x(co)(ci) * io.w(co)(ci))
    when(io.clr) {
      for (k <- 0 until 4) { ps(co)(k) := S(0, PSW bits) }
    }.elsewhen(io.en) {
      for (k <- 0 until 4) { ps(co)(k) := (prod(2 * k) + prod(2 * k + 1)).resize(PSW) }
    }
    val p01 = ps(co)(0) + ps(co)(1)
    val p23 = ps(co)(2) + ps(co)(3)
    val sum16 = p01 + p23
    /** ★ 第 9 抽头行（`TAP8`）：8 个独立乘法器 + 并进同一个 acc（每行一个加法器）。
      *   `TAP8=false` ⇒ 这一项结构性不存在（`sum16` 直接进 acc）。 */
    val p8   = if (TAP8) ioX8(co) * ioW8(co) else null
    val sum  = (if (TAP8) (sum16 + p8) else sum16).resize(32)
    when(io.clr) {
      acc(co) := 0
    }.elsewhen(enD) {
      acc(co) := (acc(co) + sum).resize(32)
    }
  }
  io.p := acc
}

class DwLaneProbe(val WIDTH: Int = 8, val MODE: Int = 0, val MUTX: Int = -1) extends Component {
  require(WIDTH >= 3, "3x3 窗口至少要 3 列")
  require(MODE == 0 || MODE == 1 || MODE == 2, "MODE ∈ {0,1,2}（见文件头）")
  val C   = 8
  val cw  = (log2Up(WIDTH) max 1)
  /** MODE 0 = as-built（广播 x、9 拍）；MODE 1/2 = tap-inner（逐 lane x + 2:1 模式选择器）。 */
  val DWPACK: Boolean = MODE > 0
  /** 第 9 抽头行（只有 MODE 2 有）。 */
  val TAP8: Boolean   = MODE == 2
  /** dw 档的每像素 tap 拍数：MODE 1 = 2（8 抽头 + 1 抽头），MODE 2 = 1（9 抽头一拍）。 */
  val NDWTAP: Int     = if (MODE == 1) 2 else 1

  val io = new Bundle {
    val we    = in  Bool()
    val waddr = in  UInt (log2Up(C * C * 9) bits)
    val wdin  = in  SInt (8 bits)
    val x       = in  Vec (SInt(8 bits), C)
    val x_valid = in  Bool()
    val x_ready = out Bool()
    val start   = in  Bool()
    val bias    = in  Vec (SInt(32 bits), C)
    val requant_m = in UInt (32 bits)
    val zero_y    = in SInt (8 bits)
    val y       = out Vec (SInt(8 bits), C)
    val y_valid = out Bool()
    /** `arr.en` 拍数（tap-beat 计数；上电起累计）—— 见文件头。 */
    val obs_beats = out UInt(32 bits)
    /** 档位自报（只读常量，供 TB/闸门在 time 0 对账"喂的档 vs 网表档"）。 */
    val modeId  = out UInt(4 bits)
    /** 宽度自报（只读常量；装置在 time 0 与 `+IW` 对账 —— 与 `Conv3x3Slice.imgW` 同一条"宽度钉死"口径）。 */
    val imgW    = out UInt(16 bits)
  }
  noIoPrefix()
  io.modeId := U(MODE, 4 bits)
  io.imgW   := U(WIDTH, 16 bits)
  /** ★ dw 档使能（`DWPACK` 档才有这个口；缺省档一根线都不加）—— 产品 RTL 里它由
    *   `UnitExec.isDwW`（描述符 GROUP==C_in==C_out）驱动，与 slice A 的 `one_x1` 同一套接线方式。 */
  val dw_mode: Bool = if (DWPACK) { val v = in Bool(); v.setName("dw_mode"); v } else null

  // ------------------------------------------------------------------------------------
  // 三个现成部件（**一字未改**：LineBuffer 与 WeightStore 都是 rtl/ 里的真类）
  // ------------------------------------------------------------------------------------
  val lb = LineBuffer(C_IN = C, WIDTH = WIDTH)
  val ws = new DwLaneWeightStore(DW = DWPACK)

  // ------------------------------------------------------------------------------------
  // 行列/像素相位（逐条照抄 Conv3x3Slice 的 s=1 口径；本探针不做 stride/多趟部分和）
  // ------------------------------------------------------------------------------------
  val st        = Reg(UInt(2 bits)) init (0)
  val cConsume  = U(0, 2 bits)
  val cPhantom  = U(1, 2 bits)
  val cPix      = U(2, 2 bits)
  val inConsume = st === cConsume
  val inPhantom = st === cPhantom
  val inPix     = st === cPix
  val col = Reg(UInt(cw bits)) init (0)
  val row = Reg(UInt(16 bits)) init (0)
  val phantomPix = Reg(Bool()) init (False)
  val colLast    = Reg(Bool()) init (False)
  /** 收列拍（列流握手）与 pre-roll 行（row==0 不出像素，与 Conv3x3Slice 的 `rowOut` 同口径）。 */
  val beat  = io.x_valid && inConsume
  val rowOk = row =/= U(0, 16 bits)
  val firstCol = col === U(0, cw bits)
  val colLastC = col === U(WIDTH - 1, cw bits)
  io.x_ready := inConsume
  lb.io.x := io.x
  lb.io.en := beat
  lb.io.rowW := U(WIDTH, 16 bits)
  lb.io.prime := io.start
  lb.io.pad_val := S(0, 8 bits)     // 冻结口径 z_pad = 0（与 run_dw_ab.sh 的装置同）
  ws.io.we    := io.we
  ws.io.waddr := io.waddr
  ws.io.wdin  := io.wdin

  // ---- 列延迟线（3 列 × C 通道 × 3 行；逐条照抄 Conv3x3Slice）----
  val colWin = Vec(Vec(Vec(Reg(SInt(8 bits)) init (0), 3), C), 3)
  when(beat) {
    for (ci <- 0 until C) {
      for (rr <- 0 until 3) {
        colWin(0)(ci)(rr) := Mux(firstCol, S(0, 8 bits), colWin(1)(ci)(rr))
        colWin(1)(ci)(rr) := Mux(firstCol, S(0, 8 bits), colWin(2)(ci)(rr))
        colWin(2)(ci)(rr) := lb.io.win(ci)(rr)
      }
    }
  }
  when(inPhantom) {
    for (ci <- 0 until C) {
      for (rr <- 0 until 3) {
        colWin(0)(ci)(rr) := colWin(1)(ci)(rr)
        colWin(1)(ci)(rr) := colWin(2)(ci)(rr)
        colWin(2)(ci)(rr) := S(0, 8 bits)
      }
    }
  }

  // ------------------------------------------------------------------------------------
  // 像素相位：1..tapMax = tap 拍；tapMax+1 = 排空拍（阵列两级流水的最后一级）；其后空闲拍出数
  // ------------------------------------------------------------------------------------
  val ph = Reg(UInt(4 bits)) init (0)
  /** dw 档的 tap 拍数（运行期：同一张网表 dense 9 拍 / dw `NDWTAP` 拍）。 */
  val tapMax: UInt = if (DWPACK) Mux(dw_mode, U(NDWTAP, 4 bits), U(9, 4 bits)) else U(9, 4 bits)
  val inTap   = inPix && (ph >= U(1, 4 bits)) && (ph <= tapMax)
  val inDrain = inPix && (ph === (tapMax + U(1, 4 bits)).resize(4))
  val enTap   = inTap
  /** MODE 1 的第 2 拍（只花 lane 0 做第 9 抽头；其余 lane 权重置 0）。 */
  val beatB: Bool = if (MODE == 1) (inTap && (ph === U(2, 4 bits)) && dw_mode) else False

  // tap 计数器（喂 dense 操作数：动态 (kx,ky) 与 WeightStore 的 k）
  val tapKx = Reg(UInt(2 bits)) init (0)
  val tapKy = Reg(UInt(2 bits)) init (0)
  val tapK  = Reg(UInt(4 bits)) init (0)
  when(inTap) {
    when(tapKx === U(2, 2 bits)) {
      tapKx := U(0, 2 bits)
      when(tapKy =/= U(2, 2 bits)) { tapKy := (tapKy + 1).resize(2) }
    } .otherwise {
      tapKx := (tapKx + 1).resize(2)
    }
    when(tapK =/= U(8, 4 bits)) { tapK := (tapK + 1).resize(4) }
  }
  when(inConsume || inPhantom) {
    tapKx := U(0, 2 bits); tapKy := U(0, 2 bits); tapK := U(0, 4 bits)
  }
  ws.io.k := tapK

  // ------------------------------------------------------------------------------------
  // x 操作数：dense = 广播（动态抽头，9 选 1）；dw = 逐 lane 静态重排（**零多路选择器**）
  // ------------------------------------------------------------------------------------
  /** dense 档的广播 x（= `Conv3x3Slice.arrX`，逐字同式）。 */
  val arrXDyn = Vec(SInt(8 bits), C)
  for (ci <- 0 until C) { arrXDyn(ci) := colWin(tapKx)(ci)(tapKy) }
  /** dw 档的逐 lane x：lane (r,j) = 通道 r 在抽头 j 的窗口值。
    *   `tap(ky,kx) = colWin(kx)(ci)(ky)`（切片的口径）⇒ lane(r,j) = `colWin(j%3)(r)(j/3)`。
    *   `MUTX == j` ⇒ **外科锚**：把该 lane 的 `kx` 改成 0（路由错、算术不变；见文件头）。 */
  val dwXL: Vec[Vec[SInt]] = if (DWPACK) {
    val v = Vec(Vec(SInt(8 bits), C), C)
    for (r <- 0 until C) {
      for (j <- 0 until C) {
        val kx = if (MUTX == j) 0 else (j % 3)
        val ky = j / 3
        v(r)(j) := colWin(kx)(r)(ky)
      }
    }
    v
  } else null
  /** 第 9 抽头（(ky,kx)=(2,2)）的 x：同样是一条寄存器直连。 */
  val dwXL8: Vec[SInt] = if (DWPACK) {
    val v = Vec(SInt(8 bits), C)
    for (r <- 0 until C) { v(r) := colWin(2)(r)(2) }
    v
  } else null

  // ------------------------------------------------------------------------------------
  // w 操作数：dense = WeightStore 的 9 选 1；dw = 对角零填瓦片的**静态寄存器**（通道 r 的抽头 k）
  // ------------------------------------------------------------------------------------
  /** dw 档的逐 lane 权重 = `mem[r*72 + r*9 + j]`（对角 entry 的第 j 抽头；**静态**下标 ⇒ 零逻辑）。
    *   这条口径成立的结构前提：宽通路装载器对 dw 的趟瓦片做**跨组零填**（`UnitExec` §B1c），
    *   即对角趟上只有 `(cl==cil)` 非 0 ⇒ `mem[r*72+r*9+k]` 就是"通道 r 的第 k 个抽头"。 */
  val dwWL: Vec[Vec[SInt]] = if (DWPACK) {
    val v = Vec(Vec(SInt(8 bits), C), C)
    for (r <- 0 until C) {
      for (j <- 0 until C) { v(r)(j) := ws.dwTile(r)(j) }
    }
    v
  } else null
  val dwWL8: Vec[SInt] = if (DWPACK) {
    val v = Vec(SInt(8 bits), C)
    for (r <- 0 until C) { v(r) := ws.dwTile8(r) }
    v
  } else null

  // ------------------------------------------------------------------------------------
  // 阵列（BEFORE = 真 MacArray；AFTER2/AFTER1 = 逐 lane x 的 DwLaneMacArray）
  // ------------------------------------------------------------------------------------
  val pixelPending = Reg(Bool()) init (False)
  val arrIdleBeat  = inConsume || inPhantom
  when(inDrain)                   { pixelPending := True }
  when(arrIdleBeat && pixelPending) { pixelPending := False }
  val emit = arrIdleBeat && pixelPending

  val pOut: Vec[SInt] = if (MODE == 0) {
    // ---- BEFORE（as-built）：广播 x + WeightStore 瓦片 ----
    val arr = new MacArray
    arr.io.x   := arrXDyn
    arr.io.w   := ws.io.tile
    arr.io.en  := enTap
    arr.io.clr := emit
    arr.io.p
  } else {
    // ---- AFTER2/AFTER1：逐 lane x/w + 逐 lane 模式选择器 ----
    val arr = new DwLaneMacArray(TAP8 = TAP8)
    for (r <- 0 until C) {
      for (j <- 0 until C) {
        /** MODE 1 的第 2 拍：lane 0 换成第 9 抽头；lane j>0 的权重置 0（x 保持不动即可）。 */
        val xDw0 = if (MODE == 1 && j == 0) Mux(beatB, dwXL8(r), dwXL(r)(0)) else dwXL(r)(j)
        val wDw  = if (MODE == 1) {
          if (j == 0) Mux(beatB, dwWL8(r), dwWL(r)(0))
          else        Mux(beatB, S(0, 8 bits), dwWL(r)(j))
        } else dwWL(r)(j)
        arr.io.x(r)(j) := Mux(dw_mode, xDw0, arrXDyn(j))
        arr.io.w(r)(j) := Mux(dw_mode, wDw, ws.io.tile(r)(j))
      }
    }
    if (TAP8) {
      for (r <- 0 until C) { arr.ioX8(r) := dwXL8(r); arr.ioW8(r) := dwWL8(r) }
    }
    arr.io.en  := enTap
    arr.io.clr := emit
    arr.io.p
  }

  /** tap-beat 计数（= `arr.en` 拍数；上电起累计，`start` 不清 ⇒ TB 取差分/终值）。 */
  val beatCnt = Reg(UInt(32 bits)) init (0)
  when(enTap) { beatCnt := beatCnt + 1 }
  io.obs_beats := beatCnt

  // ------------------------------------------------------------------------------------
  // requant：`accTot = acc + bias`；`y = clamp( ((accTot·M)>>30) + z_y )`（冻结式的整数同值）
  // ------------------------------------------------------------------------------------
  val yR = Vec(Reg(SInt(8 bits)) init (0), C)
  val emitD1 = RegNext(emit) init (False)
  for (co <- 0 until C) {
    val accTot = pOut(co).resize(32) + io.bias(co)
    val prod   = accTot.resize(64) * io.requant_m.asSInt
    val valq   = (prod >> 30) + io.zero_y
    val wq     = valq.getWidth
    when(emit) {
      yR(co) := Mux(valq > S(127, wq bits),  S(127, 8 bits),
                Mux(valq < S(-128, wq bits), S(-128, 8 bits), valq.resize(8)))
    }
  }
  io.y       := yR
  io.y_valid := emitD1

  // ------------------------------------------------------------------------------------
  // 调度状态机（逐条照抄 Conv3x3Slice 的 s=1 口径，去掉 stride/多趟）
  // ------------------------------------------------------------------------------------
  when(beat) {
    when(firstCol) {
      col := U(1, cw bits)
    } .elsewhen(!rowOk) {
      // pre-roll 行：只推进列相位（不出像素）
      when(colLastC) { col := U(0, cw bits); row := (row + 1).resize(16) }
        .otherwise { col := (col + 1).resize(cw) }
    } .otherwise {
      st := cPix
      ph := U(1, 4 bits)
      phantomPix := False
      colLast := colLastC
      when(!colLastC) { col := (col + 1).resize(cw) }
    }
  }
  when(inPhantom) {
    st := cPix
    ph := U(1, 4 bits)
    phantomPix := True
  }
  when(inPix) {
    when(ph < tapMax) { ph := (ph + 1).resize(4) }
      .elsewhen(ph === tapMax) { ph := (tapMax + U(1, 4 bits)).resize(4) }
      .otherwise {
        // 排空拍结束：幻影像素 ⇒ 换行；本行最后一列 ⇒ 补幻影拍；否则继续收列
        when(phantomPix) { st := cConsume; col := U(0, cw bits); row := (row + 1).resize(16) }
          .elsewhen(colLast) { st := cPhantom }
          .otherwise { st := cConsume }
      }
  }

  // `start`（= 每趟一拍）：把 per-image 相位清回上电态（与 Conv3x3Slice 的 `prime` 同口径）
  when(io.start) {
    st := U(0, 2 bits); col := U(0, cw bits); row := U(0, 16 bits); ph := U(0, 4 bits)
    phantomPix := False; colLast := False; pixelPending := False
    tapKx := U(0, 2 bits); tapKy := U(0, 2 bits); tapK := U(0, 4 bits)
    for (ci <- 0 until C) {
      for (rr <- 0 until 3) {
        for (cx <- 0 until 3) { colWin(cx)(ci)(rr) := S(0, 8 bits) }
      }
    }
  }
}
