import spinal.core._

/** =====================================================================================
  * ★★ NPU v2 切片 C-1：**dense ci-inner（ci 进拍、tap 进 lane）**的**独立探针**
  * （不是产品 RTL；本片不改 `y1/rtl` 下的任何行）。
  * =====================================================================================
  *
  * 为什么有这个文件（问题陈述：spec §5 表序 4 / `reports/npu_v2_accounting.md` §P0b-4 的残差 1.502M 拍）：
  *   A+B1 之后剩下的残差里 **1,363,200 拍（90.7%）在 dense 单元**（`Conv_0` 1,228,800 + 六片 `1→1 3×3`
  *   134,400）。它们的现拍序是 **tap-major**：`Conv3x3Slice` 每像素跑 9 个 tap 拍
  *   （`arrX(ci) = colWin(tapKx)(ci)(tapKy)`，ci 是 lane、tap 是拍）。`C_in=3` 时 8 条 ci lane 只有
  *   3 条有用（`Conv_0`）；`C_in=C_out=1` 时一拍 64 槽只有 9 个有用乘。⇒ 浪费**在拍序上**。
  *
  * 本探针要证的那一条（与 B-1 的 dw tap-inner **同一个结构**，只把"通道"换成"ci"）：
  *   把拍轴与 lane 轴**换过来** —— **一拍吃一个 ci 的全部 9 个抽头**（lane j = 抽头 j，第 9 抽头吃
  *   `x8/w8` 行；B1 AFTER1 的那一行乘法器**直接复用**），像素相位从 9 拍缩到 `C_in` 拍
  *   （`Conv_0`：3 拍；`C_in=1` 的六片：**1 拍**）。数值逐字节不变（整数加法重排；requant 一次）。
  *   · x 操作数：lane j 的 `(kx,ky)` **静态**（`colWin(kx_j)(ci_b)(ky_j)`），只有 **ci 索引**是运行期
  *     （= 拍号 − 1）⇒ 逐 lane 一条 **4:1 读**（`C_in ≤ 4`，真表只需 3 / 1）+ 与 dw 档的 **2:1 选**。
  *   · w 操作数：`WeightStore` 新读口 `c3Tile(r)(j) = mem[r*72 + ci_b*9 + j]` —— **同一个 576 B 对角
  *     零填瓦片内部**（`Conv_0` 的 ci∈[3,8) 由装载器零填）⇒ **blob / 装载器 / 描述符零改动**
  *     （与 B1 的 `dwTile` 同一论证，见 `rtl/UnitExec.scala` §C4b-B1c 文件头）。
  *   ⇒ 唯一新增的硬件 = "三种来源选一个"的逐 lane 选择器（dense 广播 / dw 对角 / **c3 ci-inner**）
  *     + `WeightStore` 的 c3 读口 + 一个 ci 拍计数器。这就是本探针 dev_map 要测的**增量**。
  *
  * ---------------------------------------------------------------- 档位（同一份源码，只差展开期 DCI）
  * `DCI=false`（缺省）= **B1 落地后的切片当量**（dense 广播 + dw 逐 lane AFTER1）——基线档，
  *   结构与 `rtl_test/DwLaneProbe.scala` MODE 2 同价（dev_map 应落在 4,501 LUT 附近 ⇒ 交叉锚）。
  * `DCI=true`          = 基线 + **c3 ci-inner**（多 `dci_mode`/`c3_cin` 两个 additive 入 + c3 读口）。
  * `MUTX=j ≥ 0`        = **外科锚**：c3 读口里 lane j 的 `kx` 由 `j%3` 改成 0（只动 c3 路由、不动算术）。
  *
  * ---------------------------------------------------------------- 口径（与冻结参考对齐）
  *   · 窗口/相位/幻影列/预滚行：逐条照抄 `rtl/Conv3x3Slice.scala` 的 `s=1` 口径（`LineBuffer` 是直接例化
  *     真类，未改一行）；`ps_in` 不接（本探针每趟 = 一个 co-block 的唯一趟；真表这些单元 nCi==1）。
  *   · 输出：`accTot = arr.p(co) + bias(co)`；`y = clamp( ((accTot·M)>>30) + z_y )`（= 冻结
  *     `quant_ref.requant_int` 的整数同值；探针不做三级流水，那是时序项，与数值无关）。
  *   · 拍数观测口 `obs_beats` = `arr.en` 拍数（上电起累计）—— `mac_account.py` 的
  *     `beats_issued = taps·passes·H·W` 的**实测**对应物（Base 9 / DCI `C_in` 拍/像素/趟）。
  *   · `laneSel = dw_mode || dci_mode` —— 驱动 `MacArray` 的操作数选择与第 9 抽头行的并入
  *     （与产品 `MacArray.dw_mode` 同一语义：dense 广播时 p8 记 0，所以 Base 档的 dense 作业逐位同形）。
  * ===================================================================================== */
/** `rtl/WeightStore.scala` 的同一条逻辑（576 个 int8 寄存器 + 按 (ky,kx) 的 9 选 1 瓦片），
  * 两个 additive 读口：
  *   · **dw 对角读口**（B1，与产品 `WeightStore` 的 `DW=true` 档逐字同构）：`dwTile(r)(j) = mem[r*72+r*9+j]`；
  *   · **c3 ci-inner 读口**（本片）：`c3Tile(r)(j) = mem[r*72 + c3_ci*9 + j]`（`c3_ci` = 运行期 ci 拍号，
  *     0..3 —— 只覆盖 `C_in ≤ 4`，真表只需要 {3, 1}）+ `c3Tile8(r)`。
  * 前提（与 B1 同一实测结论）：宽通路装载器把 `(co,ci)` 瓦片按 **ci = ciLocal** 落位、`cil ∈ [C_in,8)`
  * 零填（`UnitExec.scala` §C4b-B1c）⇒ 这两条读口**不需要**改 blob / 装载器 / 描述符。 */
class CiPackWeightStore(val DCI: Boolean = false) extends Component {
  val C_IN  = 8
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
  /** dw 对角读口（= B1 落地后的产品口；本探针的**基线**就带它）。 */
  val dwTile: Vec[Vec[SInt]] = { val v = out Vec (Vec(SInt(8 bits), 8), 8); v.setName("dwTile"); v }
  val dwTile8: Vec[SInt] = { val v = out Vec (SInt(8 bits), 8); v.setName("dwTile8"); v }
  /** ★ 本片：c3 ci-inner 读口（只有 `DCI=true` 的展开里存在；组件级 additive 口，同产品 `WeightStore` 的
    * `dwTile` 手法）。 */
  val c3_ci: UInt = if (DCI) { val v = in UInt (2 bits); v.setName("c3_ci"); v } else null
  val c3Tile: Vec[Vec[SInt]] = if (DCI) { val v = out Vec (Vec(SInt(8 bits), 8), 8); v.setName("c3Tile"); v } else null
  val c3Tile8: Vec[SInt] = if (DCI) { val v = out Vec (SInt(8 bits), 8); v.setName("c3Tile8"); v } else null

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
  for (r <- 0 until 8) {
    for (j <- 0 until 8) { dwTile(r)(j) := mem(r * PER_GROUP * 9 + r * 9 + j) }
    dwTile8(r) := mem(r * PER_GROUP * 9 + r * 9 + 8)
  }
  if (DCI) {
    for (r <- 0 until 8) {
      for (j <- 0 until 8) {
        /** 4:1 读（`c3_ci` 运行期 0..3）。`C_in ≤ 4` 是本片钉死的口径（真表 {3,1}）。 */
        val e = (1 to 3).foldLeft(mem(r * PER_GROUP * 9 + j)) { (acc, c) =>
          Mux(c3_ci === U(c, 2 bits), mem(r * PER_GROUP * 9 + c * 9 + j), acc)
        }
        c3Tile(r)(j) := e
      }
      val e8 = (1 to 3).foldLeft(mem(r * PER_GROUP * 9 + 8)) { (acc, c) =>
        Mux(c3_ci === U(c, 2 bits), mem(r * PER_GROUP * 9 + c * 9 + 8), acc)
      }
      c3Tile8(r) := e8
    }
  }
}

/** 与 `rtl/MacArray.scala`（`DW=true` 档）**同一条算术**：逐 lane x/w + 第 9 抽头行并进同一个 acc，
  * `dw_mode` 选"逐 lane 还是广播"、并门 `p8`（`dw_mode=0` ⇒ p8 记 0 ⇒ **dense 档逐位同形**）。 */
class CiPackMacArray extends Component {
  val io = new Bundle {
    val x   = in  Vec (Vec(SInt(8 bits), 8), 8)
    val w   = in  Vec (Vec(SInt(8 bits), 8), 8)
    val x8  = in  Vec (SInt(8 bits), 8)
    val w8  = in  Vec (SInt(8 bits), 8)
    val dw_mode = in Bool()
    val en  = in  Bool()
    val clr = in  Bool()
    val p   = out Vec (SInt(32 bits), 8)
  }
  noIoPrefix()
  val PSW = 18
  val acc = Vec(Reg(SInt(32 bits)) init (0), 8)
  val ps  = Vec(Vec(Reg(SInt(PSW bits)) init (0), 4), 8)
  val enD = RegNext(io.en) init (False)

  for (co <- 0 until 8) {
    val prod = (0 until 8).map(ci => io.x(co)(ci) * io.w(co)(ci))
    val p8   = io.x8(co) * io.w8(co)
    /** ★★ C-1 实测发现（探针 per-tap 实验）：**第 9 抽头行的积必须进 A 级寄存器**。
      *   B 级（`enD` 拍）的 `sum = (p01+p23) + p8` 里，`p01/p23` 来自**上一拍 `en` 锁存的 `ps`**，
      *   而 `p8` 是**本拍输入**的组合积 —— 单拍静态档（AFTER1 的 dw：`x8/w8` 是常数）两者同值、
      *   看不出来；**多拍档（c3 ci-inner，每拍换 ci）就会错位**：`ps(k)` 会配上 `p8(k+1)`，
      *   末拍的 `p8` 落空（实测：tap-8 单抽头作业在 DCI 档输出 0、Base 档输出正确值）。
      *   ⇒ 与 `ps` 同一条纪律：`p8r` 在 `en` 拍锁存、`clr` 清零（A 级），B 级读 `p8r`。
      *   ★ dw（静态 `x8/w8`）档数值**逐位不变**（p8r 每拍同值）。 */
    val p8r = Reg(SInt(PSW bits)) init (0)
    when(io.clr) {
      for (k <- 0 until 4) { ps(co)(k) := S(0, PSW bits) }
      p8r := S(0, PSW bits)
    }.elsewhen(io.en) {
      for (k <- 0 until 4) { ps(co)(k) := (prod(2 * k) + prod(2 * k + 1)).resize(PSW) }
      p8r := p8.resize(PSW)
    }
    val p01 = ps(co)(0) + ps(co)(1)
    val p23 = ps(co)(2) + ps(co)(3)
    /** ★ 与产品 `MacArray` 同式：`dw_mode=0` ⇒ 加 0（逐位同形）。本片一网表两模式（dense / dw+c3）。 */
    val sum = (p01 + p23 + Mux(io.dw_mode, p8r.resize(20), S(0, 20 bits))).resize(32)
    when(io.clr) {
      acc(co) := 0
    }.elsewhen(enD) {
      acc(co) := (acc(co) + sum).resize(32)
    }
  }
  io.p := acc
}

class CiPackProbe(val WIDTH: Int = 8, val DCI: Boolean = false, val MUTX: Int = -1) extends Component {
  require(WIDTH >= 3, "3x3 窗口至少要 3 列")
  val C   = 8
  val cw  = (log2Up(WIDTH) max 1)

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
    val zero_y    = in  SInt (8 bits)
    val y       = out Vec (SInt(8 bits), C)
    val y_valid = out Bool()
    /** `arr.en` 拍数（tap-beat 计数；上电起累计）。 */
    val obs_beats = out UInt(32 bits)
    /** 档位自报：0 = Base（B1 当量）、1 = DCI。 */
    val modeId  = out UInt(4 bits)
    val imgW    = out UInt(16 bits)
    /** dw 档使能（= B1 落地后的产品口；两档都有）。 */
    val dw_mode = in Bool()
  }
  noIoPrefix()
  /** ★ 本片：c3 ci-inner 档使能（只有 `DCI=true` 的展开里有，组件级 additive 口同产品 `MacArray` 手法）；
    * `c3_cin` = 本单元的 `C_in`（1..4）。 */
  val dci_mode: Bool = if (DCI) { val v = in Bool(); v.setName("dci_mode"); v } else null
  val c3_cin: UInt = if (DCI) { val v = in UInt (4 bits); v.setName("c3_cin"); v } else null
  io.modeId := U(if (DCI) 1 else 0, 4 bits)
  io.imgW   := U(WIDTH, 16 bits)

  // 三个现成部件（LineBuffer 是 rtl/ 里的真类；WeightStore/MacArray 是上面同构的探针当量）
  val lb = LineBuffer(C_IN = C, WIDTH = WIDTH)
  val ws = new CiPackWeightStore(DCI = DCI)

  // 行列/像素相位（逐条照抄 Conv3x3Slice 的 s=1 口径）
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
  val beat  = io.x_valid && inConsume
  val rowOk = row =/= U(0, 16 bits)
  val firstCol = col === U(0, cw bits)
  val colLastC = col === U(WIDTH - 1, cw bits)
  io.x_ready := inConsume
  lb.io.x := io.x
  lb.io.en := beat
  lb.io.rowW := U(WIDTH, 16 bits)
  lb.io.prime := io.start
  lb.io.pad_val := S(0, 8 bits)     // 冻结口径 z_pad = 0（与 run_dw_ab/run_dwlane_ab 的装置同）
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
  // 像素相位：1..tapMax = tap 拍；tapMax+1 = 排空拍；其后空闲拍出数
  //   · Base / dw 档：tapMax = 9（B1/dense 原行为）；
  //   · ★ c3 档：tapMax = `c3_cin`（1..4）—— **ci 进拍、tap 进 lane**，像素相位 9 → C_in 拍。
  // ------------------------------------------------------------------------------------
  val ph = Reg(UInt(4 bits)) init (0)
  val laneSel: Bool = if (DCI) (io.dw_mode || dci_mode) else io.dw_mode
  /** dw 档 = B1 AFTER1 的地板：**1 抽头拍/像素/趟**（第 9 抽头由 `x8/w8` 行吃）。 */
  val tapMaxDw: UInt = Mux(io.dw_mode, U(1, 4 bits), U(9, 4 bits))
  val tapMax: UInt =
    if (DCI) Mux(dci_mode, c3_cin.resize(4), tapMaxDw) else tapMaxDw
  val inTap   = inPix && (ph >= U(1, 4 bits)) && (ph <= tapMax)
  val inDrain = inPix && (ph === (tapMax + U(1, 4 bits)).resize(4))
  val enTap   = inTap
  /** c3 档的**当前 ci 拍号**（= ph − 1，0..C_in−1）。 */
  val c3ci: UInt = (ph - U(1, 4 bits)).resize(2)
  if (DCI) { ws.c3_ci := c3ci }

  // tap 计数器（喂 dense 广播操作数：动态 (kx,ky) 与 WeightStore 的 k）
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
  // x 操作数：dense = 广播（动态抽头，9 选 1）；dw = 逐 lane 静态重排；★ c3 = 逐 lane 静态抽头 + ci 拍号
  // ------------------------------------------------------------------------------------
  val arrXDyn = Vec(SInt(8 bits), C)
  for (ci <- 0 until C) { arrXDyn(ci) := colWin(tapKx)(ci)(tapKy) }
  /** dw 档的逐 lane x：lane (r,j) = 通道 r 在抽头 j 的窗口值 = `colWin(j%3)(r)(j/3)`（静态寄存器直连）。 */
  val dwXL: Vec[Vec[SInt]] = {
    val v = Vec(Vec(SInt(8 bits), C), C)
    for (r <- 0 until C) {
      for (j <- 0 until C) { v(r)(j) := colWin(j % 3)(r)(j / 3) }
    }
    v
  }
  val dwXL8: Vec[SInt] = {
    val v = Vec(SInt(8 bits), C)
    for (r <- 0 until C) { v(r) := colWin(2)(r)(2) }
    v
  }
  /** ★ c3 档的逐 lane x：lane (r,j) = **同一个像素**在抽头 j、**当前 ci 拍号**的窗口值。
    *   与 dw 的唯一差别 = ci 索引是 `c3ci`（运行期）而不是行号 r（静态）⇒ 一条 4:1 读。
    *   `MUTX == j` ⇒ **外科锚**：把该 lane 的 `kx` 改成 0（路由错、算术不变）。 */
  val c3XL: Vec[SInt] = if (DCI) {
    val v = Vec(SInt(8 bits), C)
    for (j <- 0 until C) {
      val kx = if (MUTX == j) 0 else (j % 3)
      val ky = j / 3
      v(j) := (1 to 3).foldLeft(colWin(kx)(U(0, 3 bits))(ky)) { (acc, c) =>
        Mux(c3ci === U(c, 2 bits), colWin(kx)(U(c, 3 bits))(ky), acc)
      }
    }
    v
  } else null
  val c3XL8: SInt = if (DCI) {
    (1 to 3).foldLeft(colWin(2)(U(0, 3 bits))(2)) { (acc, c) =>
      Mux(c3ci === U(c, 2 bits), colWin(2)(U(c, 3 bits))(2), acc)
    }
  } else null

  // w 操作数：dense = WeightStore 9 选 1；dw = 对角静态；★ c3 = c3Tile 静态抽头 + ci 拍号
  val c3WL: Vec[Vec[SInt]] = if (DCI) {
    val v = Vec(Vec(SInt(8 bits), C), C)
    for (r <- 0 until C) {
      for (j <- 0 until C) { v(r)(j) := ws.c3Tile(r)(j) }
    }
    v
  } else null
  val c3WL8: Vec[SInt] = if (DCI) {
    val v = Vec(SInt(8 bits), C)
    for (r <- 0 until C) { v(r) := ws.c3Tile8(r) }
    v
  } else null

  // ------------------------------------------------------------------------------------
  // 阵列（逐 lane x/w + 第 9 抽头行；`laneSel = dw_mode || dci_mode` 驱动选择与 p8 门）
  // ------------------------------------------------------------------------------------
  val pixelPending = Reg(Bool()) init (False)
  val arrIdleBeat  = inConsume || inPhantom
  when(inDrain)                   { pixelPending := True }
  when(arrIdleBeat && pixelPending) { pixelPending := False }
  val emit = arrIdleBeat && pixelPending

  val arr = new CiPackMacArray
  for (r <- 0 until C) {
    for (j <- 0 until C) {
      /** dw 档 = 对角读；★ c3 档 = 同像素跨 ci 的静态抽头读。两档互斥（dci_mode 选）。 */
      val xLane = if (DCI) Mux(dci_mode, c3XL(j), dwXL(r)(j)) else dwXL(r)(j)
      val wLane = if (DCI) Mux(dci_mode, c3WL(r)(j), ws.dwTile(r)(j)) else ws.dwTile(r)(j)
      arr.io.x(r)(j) := Mux(laneSel, xLane, arrXDyn(j))
      arr.io.w(r)(j) := Mux(laneSel, wLane, ws.io.tile(r)(j))
    }
    val x8l = if (DCI) Mux(dci_mode, c3XL8, dwXL8(r)) else dwXL8(r)
    val w8l = if (DCI) Mux(dci_mode, ws.c3Tile8(r), ws.dwTile8(r)) else ws.dwTile8(r)
    arr.io.x8(r) := x8l
    arr.io.w8(r) := w8l
  }
  arr.io.dw_mode := laneSel
  arr.io.en  := enTap
  arr.io.clr := emit

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
    val accTot = arr.io.p(co).resize(32) + io.bias(co)
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
  // 调度状态机（逐条照抄 Conv3x3Slice 的 s=1 口径，去掉 stride/多趟部分和）
  // ------------------------------------------------------------------------------------
  when(beat) {
    when(firstCol) {
      col := U(1, cw bits)
    } .elsewhen(!rowOk) {
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
