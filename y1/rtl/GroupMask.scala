import spinal.core._

/** 分组 / 深度卷积的**纯映射规则**（无状态、无硬件逻辑，只在展开期算常量）。
  *
  * ============================ 设计契约（B3 冻结，B4 依赖） ============================
  * 组映射（与 tools/mac_ref.py 的 `g = (co * GROUP) / C_out` 逐字一致）：
  *   groupOfOut(co) = (co * GROUP) / C_OUT        —— 输出通道 co 属于哪一组
  *   groupOfIn (ci) = (ci * GROUP) / C_IN         —— 输入通道 ci 属于哪一组
  *   GROUP = 1  —— dense：每个 co 看到全部 C_IN 个 ci；
  *   GROUP = G  —— co 只看组 (co*G)/C_OUT 的 C_IN/G 个通道；要求 C_IN % G == 0 且 C_OUT % G == 0；
  *   depthwise  —— G = C_IN = C_OUT；此时每个 co 恰好看一个 ci（ci == co）。
  *   ci_local 是**组内**序号，跑 0 .. C_IN/G - 1。
  *
  * 为什么是"掩权重"而不是"掩输入"（本任务最要命的一条）：
  *   阵列里 x 是 8 个输出通道**共用**的一条总线，p(co) = Σ_ci x(ci)·w(co)。
  *   若靠屏蔽 x 来表达分组（把组外的 x(ci) 清 0），那会把**别的组**的输出通道一起弄错 ——
  *   x 是共用的，屏蔽它对所有 co 同时生效，而不同组需要的屏蔽不一样。
  *   所以分组信息只能落进**权重**：w'(co,ci) = W(co, ci_local) 当 ci 与 co 同组，否则 0。
  *   此时 p(co) = Σ_ci x(ci)·w'(co,ci) = Σ_{ci ∈ group(co)} x(ci)·W(co, ci_local)
  *   —— 正好是分组卷积，且**阵列结构一个字都不改**（掩 0 是常数折叠出来的线与门）。
  *
  * weightAddr：未落位的分组权重张量的展平地址，与 tools/mac_ref.py 的
  *   `W[co][ci_local][ky][kx] ⇒ co*(C_in/GROUP)*9 + ci_local*9 + ky*3 + kx`
  * 完全一致（该展平顺序是参考与装置之间的接口，改它就等于改硬件接口）。
  * ================================================================================
  */
case class GroupMask(C_IN: Int, C_OUT: Int, GROUP: Int) extends Area {
  require(C_IN % GROUP == 0 && C_OUT % GROUP == 0, "通道数必须能被 group 整除")

  /** 每组拥有多少输入通道（同时也是每个 co 的组内权重个数）= C_IN / GROUP。 */
  val PER_GROUP: Int = C_IN / GROUP

  /** 输出通道 co 属于哪一组。 */
  def groupOfOut(co: Int): Int = (co * GROUP) / C_OUT

  /** 输入通道 ci 属于哪一组。 */
  def groupOfIn(ci: Int): Int = (ci * GROUP) / C_IN

  /** co 是否吃 ci：同组即参与。展开期常量（不是运行期比较）⇒ 综合出的是常数，不是比较器。 */
  def participates(co: Int, ci: Int): Bool = Bool(groupOfOut(co) == groupOfIn(ci))

  /** ci 在 co 所属组内的序号（0 .. PER_GROUP-1）。 */
  def ciLocal(co: Int, ci: Int): Int = ci - groupOfIn(ci) * PER_GROUP

  /** 未落位分组权重张量 [co][ci_local][ky][kx] 的展平地址。 */
  def weightAddr(co: Int, ci: Int, ky: Int, kx: Int): Int =
    co * PER_GROUP * 9 + ciLocal(co, ci) * 9 + ky * 3 + kx
}
