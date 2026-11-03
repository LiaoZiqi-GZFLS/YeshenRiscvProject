import spinal.core._

/** 8x8 int8 MAC 阵列 —— 新切片设计的面积主项。
  *
  * 语义（本任务冻结，B3/B4 依赖）：
  *   - 一拍里 x(ci) 是 8 个**输入通道**在同一个 (ky,kx) 位置的像素；
  *     w(co)(ci) 是**权重瓦片**：第 co 个输出通道在第 ci 个输入通道上的权重，
  *     64 个权重**互不相同**（不是"每输出通道一个标量"）。
  *   - en  为真时本拍参与累加；clr 清零全部 8 个累加器（像素 / 层边界）。
  *   - p(co) = sum_ci( sig8(x(ci)) * sig8(w(co)(ci)) )，signed int8 x signed int8 -> int32，
  *     符号扩展后**全程 int32 累加**，绝不先截到 16 位。
  *   - 这里**不做** requant / clamp —— 那是 slice 的事，阵列层对账比的是原始 int32 和。
  *   - p 是寄存器输出：一次调用者喂一个 (ky,kx)，3x3 卷积连续喂 9 拍后读 p。
  *
  * ★ 为什么必须是瓦片而不是 8 个标量（本文件修掉的正是这个缺陷）：
  *   若 w 只有 8 个标量（w(co)），阵列算的是 rank-1 外积 p(co) = w(co) * Σ_ci x(ci)，
  *   8 个 co 各 1 个权重被乘到 8 条 x 上 —— 64 个乘法器里只有 8 个在做**独立**的有用功，
  *   等效吞吐 8 MAC/拍而不是 64 MAC/拍（对 344 M-MAC/帧 的预算 = 430 ms/帧 ≈ 2.3 fps，
  *   达不到 ≥10 fps）。真瓦片下 p(co) = Σ_ci x(ci)·w(co)(ci)，64 个乘法器各有一个
  *   **独立的权重操作数**，一拍 64 个有用 MAC。
  *   这条性质靠 tools/run_macarray_ab.sh 的两条判据把住（自动化，不是靠读网表）：
  *     ① 无死乘法器（64 槽逐槽扰动，对应输出必须动）；
  *     ② 结构判据（网表里 64 个乘法器、每个输出行 8 个**互不相同**的 w 操作数）。
  *
  * 深度卷积 / 分组卷积不改本结构：靠按 entry 屏蔽"哪些 (co,ci) 参与"（见 GroupedMacArray）。
  *
  * ====================== ★ C3.18 Round3 R3-1/R3-2：位宽 + 两级流水（时序收敛） ======================
  *
  * 【R3-1 自然位宽】旧写法是
  *     val prod = (0 until 8).map(ci => (io.x(ci) * io.w(co)(ci)).resize(32))
  *     val sum  = prod.reduce(_ + _)
  * 即**每个乘积先扩到 32 位再求和** ⇒ 8 路和树里每一级都是 **33 位**加法器。板级综合实测：
  * 本阵列的"乘积-求和/累加"逻辑占了整个 SoC **10,623 个加法器进位单元里的 7,552 个（71%）
  * ≈ 1,888 CLMS**，而器件正处于 CLMS 89% / CLMA 90% —— 这就是压在残余违例背后的**拥塞引擎**。
  * 现在改成**乘积保持自然位宽**（8x8 → 16 位），只在**累加**处才扩到 32 位：
  *     prod(ci) = io.x(ci) * io.w(co)(ci)          // SInt(16)，不 resize
  *     ps(k)    = prod(2k) + prod(2k+1)            // 对和，寄存器，SInt(18)
  *     sum      = (ps0+ps1) + (ps2+ps3)            // 平衡两级树，SInt(20)
  *     acc(co)  = acc(co) + sum.resize(32)         // **累加仍然是 int32**
  * **位宽界（可推，不是估计）**：|x|,|w| <= 128 ⇒ |prod| <= 128*128 = 16384 ⇒ 一个对和
  * <= 32768、8 个乘积之和 <= 131,072。两的补码下：SInt(18) 覆盖 ±131,072、SInt(20) 覆盖
  * ±524,288 ⇒ **任何中间节点都不可能溢出**，一路到 acc 全是精确整数和。**逐位等价（bit-exact）**，
  * 且**零延迟代价**（级数、拍数、状态机全不变）。
  *
  * 【R3-2 两级流水】旧写法在**一拍**里做 8 个顺序 32 位加法（R1 的 `.rtr` 实测最坏锥：端点
  * `.../sliceRest_3/arr/arr/acc_4[28]/.../CIN`，**12 级 / 逻辑 6.684 ns + 布线 6.155 ns**，
  * slack −3.196）。现在拆成**两级寄存器**：
  *   · A 级：一拍把 8 个乘积折成 **4 个对和** `ps(k) <= prod(2k)+prod(2k+1)`（8 co × 4 × 18 位
  *     FF），A 级组合深度 = 1 个乘法器 + 1 个加法器；
  *   · B 级：**平衡 2 级树**（p01/p23 然后相加）+ 与 acc 的累加，B 级组合深度 = 3 个加法器。
  *   预期 5 级 ≈ 5 ns（A） + 3 级 ≈ 2.6 ns（B），对 10 ns 周期两级都留足余量。
  *
  * 【★ 对外时序契约（明写；Conv3x3Slice 按此重排）】流水使 `p` 的可读时刻**晚一拍**：
  *   · `ps` 只在 `en` 拍更新（`en=0` 时保持）⇒ 第 j 个 tap 的对和在**下一拍**可见；
  *   · `acc` 只在 **`enD`（= 上一拍的 `en`）** 为真时累加 ⇒ 第 j 个 tap 的贡献在 **j+1 拍末尾**落进 acc。
  *   ⇒ 最后一拍 `en` 之后的那一拍，`acc` 才是完整和（旧版是"最后一拍 `en` 当拍"）。
  *   `clr` 优先级仍高于累加（`clr` 当拍清 0、不累加），所以 `clr` 与 `en` 仍要**分拍**（旧契约不变）——
  *   只多一条：`clr` 若紧贴在最后一个 `en` 拍之后，被吞掉的是**上一拍**的贡献（旧版吞的是当拍）。
  *   `Conv3x3Slice` 的 clr 落在收列拍（其前一拍 `en=0`）⇒ 这条新边角**不会**被触发。
  * ============================================================================================
  */
class MacArray(val DW: Boolean = false) extends Component {
  val io = new Bundle {
    val x   = in  Vec (SInt(8 bits), 8)                 // 8 个输入通道在同一 (ky,kx) 的像素
    val w   = in  Vec (Vec(SInt(8 bits), 8), 8)         // 权重瓦片：w(co)(ci)，64 个互不相同的权重
    val en  = in  Bool()
    val clr = in  Bool()
    val p   = out Vec (SInt(32 bits), 8)
  }
  noIoPrefix()

  // ==========================================================================================
  // ★★ NPU v2 切片 B1（2026-10-16）：**depthwise 用满 8 条通道**（AFTER1 档）的 additive 口
  // ==========================================================================================
  // 独立探针 `rtl_test/DwLaneProbe.scala`（AFTER1 档）+ 报告 `reports/npu_v2_accounting.md`
  // §Slice B-1 钉死的接口。为什么这套口长这样（三条结构事实）：
  //   · dw 的浪费 = "x 是**一条 8 宽广播**（`arrX(ci)=colWin(kx)(ci)(ky)`）⇒ 一拍 64 槽只有对角 8 槽有用"
  //     ⇒ 每像素 9 拍。把**抽头当内维**（lane `(co,ci)` 算 `x[co][ci]·w[co][ci]`，ci 下标 = 抽头下标）
  //     就能一拍吃 8 个抽头 —— 而**不需要 8×8 交叉开关**：9 个抽头对同一像素**同一拍全在**
  //     `colWin`/`WeightStore` 里（都是寄存器）⇒ dw 档的 x/w 是**静态寄存器直连**（零多路选择器）。
  //   · 第 9 抽头（AFTER1 的地板档）由下面的**第 9 条乘法器行**（`x8/w8`）吃 ⇒ **1 拍/像素/趟**
  //     （不加这一行就是 AFTER2 的 2 拍，见报告 §B1-2 的取舍表）。
  //   · 唯一要加的是"一张网表同时服务 dense 的广播与 dw 的逐 lane"⇒ **逐 lane 2:1 选择器**
  //     （`dw_mode` 选 x/w 的来源，见下面 `prod` 那一行）。这就是本口在 dev_map 上的全部增量。
  // ★ 只在 `DW=true` 的展开里存在（`UnitExec(TILING=true)` 的宽路切片）⇒ `DW=false`（缺省 = 既有
  //   全部网表：SliceGen/MacArrayGen/TILING=false 的三份冻结 UnitExec）**一个端口、一根线都不加**；
  //   `dw_mode=0` 时操作数仍是原来的广播 `x` + 瓦片 `w` ⇒ 同一份网表里 dense 作业**逐位同形**。
  /** dw 档使能（`DW` 档才有这个口）。 */
  val dw_mode: Bool = if (DW) { val v = in Bool(); v.setName("dw_mode"); v } else null
  /** dw 档的**逐 lane** x：`x_dw(co)(ci)` = 通道 `co` 的第 `ci` 个抽头（= `colWin(ci%3)(co)(ci/3)`）。 */
  val x_dw: Vec[Vec[SInt]] = if (DW) { val v = in Vec (Vec(SInt(8 bits), 8), 8); v.setName("x_dw"); v } else null
  /** dw 档的**逐 lane** w：`w_dw(co)(ci)` = 通道 `co` 的第 `ci` 个抽头权重（WeightStore 的对角读口）。 */
  val w_dw: Vec[Vec[SInt]] = if (DW) { val v = in Vec (Vec(SInt(8 bits), 8), 8); v.setName("w_dw"); v } else null
  /** ★ 第 9 抽头行（AFTER1）：8 个独立乘法器 + 每行一个加法器（积并进同一个 `acc`）。 */
  val x8: Vec[SInt] = if (DW) { val v = in Vec (SInt(8 bits), 8); v.setName("x8"); v } else null
  val w8: Vec[SInt] = if (DW) { val v = in Vec (SInt(8 bits), 8); v.setName("w8"); v } else null

  /** 对和寄存器位宽：|prod| <= 16384 ⇒ 对和 <= 32768 ⇒ 18 位有符号（±131,072）overflow 无门。 */
  val PSW = 18

  // A 级：8 个输出通道 × 4 个对和寄存器；B 级：8 个 int32 累加器（寄存器输出）。
  val acc = Vec(Reg(SInt(32 bits)) init (0), 8)
  val ps  = Vec(Vec(Reg(SInt(PSW bits)) init (0), 4), 8)
  /** A 级的写使能延时一拍 ⇒ B 级的累加使能（见类注释"对外时序契约"）。 */
  val enD = RegNext(io.en) init (False)

  for (co <- 0 until 8) {
    // 每个 co 一拍算 8 个乘积（8 输入通道 x 这个输出通道的 8 个**各自独立**的权重）——
    // **保持自然位宽 16 位**（R3-1：不先 resize 到 32），一排 8 个乘法器，全阵列 64 个，个个有用。
    // 注：prod 只是纯组合中间量、不需要可索引，故用 Scala Seq 而不是 Vec。
    val prod = (0 until 8).map(ci =>
      // ★★ B1：dw 档 ⇒ 逐 lane 的来源（2:1；`dw_mode=0` 时**逐位**是右边的原式）。
      (if (DW) Mux(dw_mode, x_dw(co)(ci), io.x(ci)) else io.x(ci)) *
      (if (DW) Mux(dw_mode, w_dw(co)(ci), io.w(co)(ci)) else io.w(co)(ci)))

    // ---- A 级：把 8 个乘积折成 4 个对和（寄存器，只在 en 拍更新；clr 优先）----
    //   ★★ 切片 C2（2026-10-16）：第 9 抽头行的积 `p8r` 与 `ps` **同纪律进 A 级寄存器**
    //     （`clr` 清零 / `en` 锁存；理由与实测证据见文件尾「切片 C2」一节 + `tools/run_dci_ab.sh`）。
    val p8r = if (DW) Reg(SInt(PSW bits)) init (0) else null
    when(io.clr) {
      for (k <- 0 until 4) { ps(co)(k) := S(0, PSW bits) }
      if (DW) { p8r := S(0, PSW bits) }
    }.elsewhen(io.en) {
      for (k <- 0 until 4) { ps(co)(k) := (prod(2 * k) + prod(2 * k + 1)).resize(PSW) }
      if (DW) { p8r := (x8(co) * w8(co)).resize(PSW) }
    }

    // ---- B 级：平衡两级树（深度固定 2）+ 与 int32 累加器的累加（深度 3 总）----
    val p01 = ps(co)(0) + ps(co)(1)                       // SInt(19)
    val p23 = ps(co)(2) + ps(co)(3)                       // SInt(19)
    /** ★ B1 AFTER1 + ★★ C2：第 9 抽头行的积**只从 A 级寄存器 `p8r` 来**（SInt(PSW=18)，与 `ps` 同拍），
      *   **只在 `dw_mode=1` 时并进**（否则加 0 ⇒ 逐位同形）。旧版这里是**组合**积 `x8·w8`（本拍输入）——
      *   与 B 级读的**上一拍** `ps` 错配：静态档（dw）两者同值看不出来，**多拍档（DCI，每拍换 ci）
      *   会静默错值**（实测 tap-8 单抽头作业输出 0；见 `tools/run_dci_ab.sh` 的受控 A/B）。
      *   位宽界：`|p01+p23| ≤ 131,072`、`|p8r| ≤ 16,384` ⇒ 和 ≤ 147,456 < 2^18 ⇒ 无溢出（SInt(20) 有余）。 */
    val sum = (if (DW) (p01 + p23 + Mux(dw_mode, p8r, S(0, PSW bits)).resize(20))
               else (p01 + p23)).resize(32)               // SInt(20) → 32（符号扩展，精确）
    when(io.clr) {
      acc(co) := 0
    }.elsewhen(enD) {
      acc(co) := (acc(co) + sum).resize(32)
    }
  }
  io.p := acc
}

/* =====================================================================================
  * ★★ 切片 C2（2026-10-16）：**第 9 抽头积进 A 级寄存器**（`p8r`）—— 多拍档（DCI）的正确性前提
  * =====================================================================================
  *
  * 出处：spec §4.6b-② 的"★★ 一处正确性补丁"（切片 C-1 的独立探针实测发现）；闸门/受控 A/B =
  * `tools/run_dci_ab.sh`（正对照 + 掐掉 `p8r` 的临时网表副本 + tap-8 单抽头作业）。
  *
  * 缺陷（**只在多拍档可见**）：B 级的和树里，`p01/p23` 来自**上一拍 `en` 锁存**的 `ps`，
  * 而旧版的第 9 抽头积 `p8 = x8·w8` 是**本拍输入**的**组合**积，在 **`enD`（= 上一拍 en）** 那一拍
  * 并进 `acc` ⇒ 错位：`ps(k)` 会配上 `p8(k+1)`，末拍的 `p8` 落空。
  *   · 单拍静态档（AFTER1 的 dw：`x8/w8` 是常数）⇒ `p8r` 与组合积**逐位同值**、看不出错位；
  *   · 多拍档（C2 的 DCI：每拍换 ci）⇒ 实测 tap-8 单抽头作业输出 **0**（Base 档正确）。
  *
  * 修法（本文件唯一的改动）：A 级加一个 `p8r`（`SInt(PSW=18)`），与 `ps` 同一条 when：
  * `clr` 清零 / `en` 锁存 `(x8·w8).resize(PSW)`；B 级改成读 `p8r`。数值纪律：
  *   · dw（静态 x8/w8）⇒ `p8r` 每拍同值 ⇒ **逐字节不变**（`run_dwpack_ab.sh` / `run_dw_ab.sh` 复证）；
  *   · dense（`dw_mode=0`）⇒ `Mux` 取 0 ⇒ 与旧版**逐位同形**（`dw_mode` 门的语义一字未改）；
  *   · 位宽：`|x8·w8| ≤ 16,384` ⇒ SInt(18) 无溢出，与对和同界。
  *
  * 行数/冻结纪律：本改动只落在 `if (DW)` 的条件分支与 A 级寄存器上 ⇒ `DW=false`（缺省 = 既有全部
  * 网表：SliceGen/MacArrayGen/MultiPassUnit/MultiPassGen/TILING=false 的三份冻结 UnitExec）的
  * **展开结果一字不差**（本文件的类体不产生行号命名的网表中间量；实测三份冻结网表 md5 不变）。
  * ===================================================================================== */
