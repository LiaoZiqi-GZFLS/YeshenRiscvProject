import spinal.core._

/** 分组 / 深度卷积包装器：按 (co, ci) **逐 entry** 屏蔽权重瓦片后，喂进原封不动的 8x8 MAC 阵列。
  *
  * 结构上只做两件事，x 通路是一根直连的线（一个门都不加）：
  *   1) 权重瓦片 w_tile(co)(ci) 就是阵列的权重输入形状（64 个 entry，见 MacArray.scala）；
  *   2) 逐 entry 屏蔽：ci 与 co 不同组 ⇒ 该 entry 恒 0（见 GroupMask：这是**唯一**表达分组的方式）。
  * 于是 arr.io.w(co)(ci) = Mux(participates(co, ci), w_tile(co)(ci), 0)，
  * 阵列拿到的瓦片就只含 co 自己那一组的权重，组外一律 0。**MacArray.scala 一个字不改。**
  *
  * ============================ 为什么这里不再需要"逐 ci 串行化"（B3 的旧写法已废） ============================
  * 旧版 MacArray 的权重接口是**每输出通道一个标量**（w(co)），一拍算的是 rank-1 外积
  * p(co) = w(co)·Σ_ci x(ci)：一个标量表达不了 p(co) = Σ_{ci∈group(co)} x(ci)·W(co,ci_local)
  * 里的每个 ci 各一个权重，于是只能**把 ci 串行化**（一拍喂一个 ci，x 只在该位置有值，
  * 用 ci_sel 一个 3 位选择器选槽），C_IN 拍才算完一个 (ky,kx)。那是**缺陷的补丁**，不是分组的要求。
  * 现在阵列吃真瓦片 w(co)(ci)：分组只需要**逐 entry 掩码**，一拍就能算完一个 (ky,kx) 的
  * 分组卷积（C_IN 拍 → 1 拍），`ci_sel` 与 w_raw 的串行化选择器**整个删掉**。
  *
  * 分组信息 100% 落在**权重掩码**上（掩输入对共享总线必然错：屏蔽 x 会同时打坏别的组的 co）。
  * 所以："同一组 X 向量" 在 group=1/2/4/8 四个配置下**逐字节相同**，只有权重瓦片的掩码不同
  * —— 这正是本任务负对照能用"同一套向量"的原因。
  *
  * 权重装入：w_tile(co)(ci) 的槽位就是"阵列的瓦片槽位"（GROUP>1 时组外槽位是被屏蔽的死槽，
  * 装什么都行）。调用方按 GroupMask.weightAddr(co, ci, ky, kx)（未落位压缩权重张量的展平地址）
  * 取权重、搬到槽 (co, ci) 即可；组映射本身仍由 GroupMask 的 groupOfOut/groupOfIn 给。
  *
  * 参数化说明：本模块 C_IN = C_OUT = 8（一块 8x8 阵列）。更宽的层（如 YuNet 的 64 通道 depthwise）
  * 用**多趟**（每趟只覆盖 8 个输入通道 × 8 个输出通道的块）复用这同一块阵列 ——
  * 那是 B4 的调度问题，**不是**本模块的结构问题（GROUP 只影响组映射与掩码常量）。
  * ==========================================================================================
  */
class GroupedMacArray(val C_IN: Int, val C_OUT: Int, val GROUP: Int, val DW: Boolean = false) extends Component {
  require(C_IN == 8 && C_OUT == 8,
    "阵列固定 8x8（本包装器一次只驱动这一块）；更宽的层靠多趟复用，见类注释")
  require(GROUP >= 1 && C_IN % GROUP == 0 && C_OUT % GROUP == 0,
    "GROUP 必须 >=1 且整除通道数（GroupMask 里还会再校一遍）")
  // ★★ NPU v2 切片 B1：dw 档是**逐 lane 直通**（掩码不参与）⇒ 只对 `GROUP=1`（掩码恒真）定义
  //   ——dw 走宽通路的那个切片恒 `GROUP=1`（跨组零填由装载器表达，见 WeightStore 的 dw 一节）。
  require(!DW || GROUP == 1, "dw 逐 lane 直通口只对 GROUP=1（掩码恒真）定义")

  /** 组映射与权重落位规则（纯函数；B4 直接用同一套算权重地址 / 分趟）。 */
  val mask = GroupMask(C_IN, C_OUT, GROUP)
  /** 每组拥有的输入通道数 = 每个 co 的组内权重个数。 */
  val PER_GROUP: Int = mask.PER_GROUP

  /** 供调用方算地址（与 GroupMask 同一套规则，薄封装）。 */
  def groupOfOut(co: Int): Int = mask.groupOfOut(co)
  def groupOfIn(ci: Int): Int = mask.groupOfIn(ci)
  def weightAddr(co: Int, ci: Int, ky: Int, kx: Int): Int = mask.weightAddr(co, ci, ky, kx)

  val io = new Bundle {
    /** 权重瓦片（与阵列同形，逐 entry 一个）：w_tile(co)(ci)。
      * 只有 participates(co, ci) 为真的 entry 会进阵列，其余被掩成 0（值任意）。 */
    val w_tile = in Vec (Vec(SInt(8 bits), C_IN), C_OUT)
    /** 共享输入向量（直连阵列）：一拍给全 8 个输入通道在同一个 (ky,kx) 的像素。 */
    val x = in Vec (SInt(8 bits), C_IN)
    val en = in Bool()
    val clr = in Bool()
    val p = out Vec (SInt(32 bits), C_OUT)
  }
  noIoPrefix()

  // ★★ NPU v2 切片 B1（2026-10-16）：dw 档的 additive 口（只有 `DW=true` 时存在）——
  //   逐 lane 直通阵列（x/w 的来源由 `dw_mode` 在阵列里二选一）；**掩码不参与 dw**：
  //   dw 的"哪些 entry 参与"由**装载器的跨组零填**表达（= 组外 entry 恒 0），
  //   而本档只对 `GROUP=1`（掩码恒真）定义（见上面的 require）。`DW=false` ⇒ 零端口。
  /** dw 档使能。 */
  val dw_mode: Bool = if (DW) { val v = in Bool(); v.setName("dw_mode"); v } else null
  /** dw 档逐 lane x（`x_dw(co)(ci)` = 通道 co 的抽头 ci）。 */
  val x_dw: Vec[Vec[SInt]] = if (DW) { val v = in Vec (Vec(SInt(8 bits), C_IN), C_OUT); v.setName("x_dw"); v } else null
  /** dw 档逐 lane w（`w_dw(co)(ci)` = 通道 co 的抽头 ci 权重）。 */
  val w_dw: Vec[Vec[SInt]] = if (DW) { val v = in Vec (Vec(SInt(8 bits), C_IN), C_OUT); v.setName("w_dw"); v } else null
  /** ★ B1 AFTER1：第 9 抽头行（8 个乘法器）。 */
  val x8: Vec[SInt] = if (DW) { val v = in Vec (SInt(8 bits), C_OUT); v.setName("x8"); v } else null
  val w8: Vec[SInt] = if (DW) { val v = in Vec (SInt(8 bits), C_OUT); v.setName("w8"); v } else null

  val arr = new MacArray(DW = DW)
  arr.io.x := io.x // 输入直通：分组表达不碰 x（掩权重而非掩输入）
  arr.io.en := io.en
  arr.io.clr := io.clr

  for (co <- 0 until C_OUT) {
    for (ci <- 0 until C_IN) {
      // participates(co, ci) 是**展开期常量**，所以这是常数折叠出来的线与门，不是运行期比较器。
      arr.io.w(co)(ci) := Mux(mask.participates(co, ci), io.w_tile(co)(ci), S(0, 8 bits))
    }
  }

  // ---- ★★ B1：dw 档的逐 lane 直通（`DW=false` ⇒ 这几行结构性不存在）----
  if (DW) {
    arr.dw_mode := dw_mode
    for (co <- 0 until C_OUT) {
      for (ci <- 0 until C_IN) { arr.x_dw(co)(ci) := x_dw(co)(ci); arr.w_dw(co)(ci) := w_dw(co)(ci) }
      arr.x8(co) := x8(co)
      arr.w8(co) := w8(co)
    }
  }

  io.p := arr.io.p
}
