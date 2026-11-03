import spinal.core._

/** 描述符 **TYPE 码**（**冻结**）。
  *
  * 真源 = `y1/tools/desc_table.py` 的模块 docstring（那 16 行位表）+ `y1/reports/c3_descriptor_format.md` §1；
  * 本对象是它在 RTL 侧的**逐字**副本（C3.4）。两处必须逐字相同：要改 ⇒ 走 spec 修订
  * （`docs/superpowers/specs/2026-10-09-y1-c3-scheduler-design.md` §3 + R3），并同步
  * `desc_table.py`（Python 真源）+ 本文件 + `reports/c3_descriptor_format.md`，再重跑
  * `tools/run_desc_ab.sh` 的交叉对账闸门。
  */
object DescType {
  val CONV3    = 0x01
  val CONV1    = 0x02
  val DW       = 0x03
  val MAXPOOL  = 0x10
  val RESIZE   = 0x11
  val CONCAT   = 0x12
  val ADD      = 0x13
  val SIGMOID  = 0x14
  val SENTINEL = 0xFF

  /** ★ C4a.6：**卷积类 TYPE** —— 本代**可执行**的三种卷积算子（conv3x3 `0x01` / conv1x1 `0x02` /
    *   depthwise `0x03`）的单一真源（RTL 侧的**语义**副本，与 `desc_table.VALID_TYPES` /
    *   `TYPE_DEPTHWISE` 同源；要改走 spec 修订）。
    *
    *   `DW`（`0x03`）的语义 = **分组卷积的特例 `GROUP == C_IN == C_OUT`**（见 `rtl/GroupMask.scala`
    *   的冻结映射与 `rtl/Conv3x3Slice.scala` 的 C4a.6 口径）：每个输出通道 `co` 恰好看一个输入通道
    *   `ci == co`。对调度器（`LayerSched`）而言它与 conv 走**同一条**分派与链路（`FLAGS` 四态、
    *   几何对账 `geomEq`、链长 `≤ L_MAX`、一个 `go` 一次），差别只在：
    *     · **权重掩码**（`Conv3x3Slice` 的 `GROUP` 展开期常量；`GROUP == C_IN == C_OUT == 8` 即
    *       "既有掩码支持的 depthwise 档"）；
    *     · `C > 8` 时的**多趟**（走 C4a.5 的多趟通路 —— 见 `Conv3x3Slice` 文件头 C4a.6 一节）。
    *   ⇒ 本方法把"哪些 TYPE 属于卷积类"这件事**收敛到一处**，`LayerSched.isConv` 逐字消费它
    *   （避免"补了 `0x03` 却漏了 `geomEq`/链扫描那一处"这类半接线的静默缺口）。 */
  def isConvClass(t: Int): Boolean = t == CONV3 || t == CONV1 || t == DW
}

/** 描述符 **FLAGS 位号**（注意：这里是**位号**，不是掩码；真源同上）。
  *
  *   bit0 = OUT_TO_DDR   ：1 ⇒ 输出落 DDR；0 ⇒ 输出留给下一单元（**融合单元的头**）。
  *   bit1 = IN_FROM_PREV ：1 ⇒ 输入取上一单元输出（**融合单元的尾**）。
  *   bits[7:2] 保留 = 0  ：**不由本文件强制**（读侧校验归 `validate` 规则 (2) / C3.11）。
  */
object DescFlags {
  val OUT_TO_DDR   = 0
  val IN_FROM_PREV = 1
}

/** 8 个 32-bit **小端字** → 14 个字段的**纯组合译码**（C3.4 的 RTL 侧单一真源）。
  *
  * 冻结的位打包（逐字取自 `desc_table.py` 的模块 docstring；**与 Python 侧同一组向量交叉对账**）：
  * {{{
  *   w0 : [7:0]=TYPE  [15:8]=FLAGS  [31:16]=0
  *   w1 : [15:0]=IMG_W [31:16]=IMG_H
  *   w2 : [15:0]=C_IN  [31:16]=C_OUT
  *   w3 : [7:0]=GROUP  [11:8]=STRIDE [15:12]=PAD [31:16]=**SRC2_K**（★ E1 2026-10-13，见 `src2k`）
  *   w4 : [31:0]=SRC_ADDR
  *   w5 : [31:0]=DST_ADDR
  *   w6 : [31:0]=IN_BYTES
  *   w7 : [7:0]=QUANT_SHIFT [15:8]=LAYER_ID [31:16]=0
  * }}}
  *
  * ★★★ 全部是**纯表达式**（`Cat` / 位切片），**不得**改用多语句赋值来构造只读字。
  *   这是 `HostRegs.scala` 已经吃过的坑（那儿的 ★ 注释逐字记着）：多语句赋值会让 SpinalHDL
  *   落成一个敏感表为空的 `always @(*)` 块，Verilog 语义下该块几乎不执行 ⇒ iverilog 里这个字
  *   从头到尾停在 **X**、译出来的字段全是 X。写成连续表达式 ⇒ 落成 `assign`，time-0 就有定值。
  *   （本 case class 的每个成员都是"切片 + 拼接"的表达式，没有一处赋值语句。）
  *
  * ★ 用法与边界：本类的**方法会创建组合节点**（切片本身就是一个运算符节点）⇒ 只能在
  *   **SpinalHDL 的组件构造上下文里**调用（即 `Component` 体内、且不要在 `when` 块里建，
  *   否则节点会被放进那个作用域、条件不成立时驱动 X）。`DescFetch` 就是在组件体里一次性建好。
  *
  * ★ 保留位（`w0[31:16]` / `w7[31:16]`）：`pack` 恒写 0、读侧本文件**只译字段、不校验**；
  *   ⚠ ★ E1（2026-10-13）：`w3[31:16]` **不再是保留位** —— 它承担 `SRC2_K`（见 `src2k` 与 spec §4.6）。
  *   它的合法性（`0..D`、仅 `Add` 可用）由**调度器/转换器**管，不归本文件。
  *
  * @param w0..w7 描述符的 8 个 32-bit 字（`word(i)` = 表内第 i 个 32-bit 字；小端 =
  *               `word(i)` 的第 0 字节在地址 `descAddr + 4*i` 上）。
  */
case class DescWords(w0: Bits, w1: Bits, w2: Bits, w3: Bits,
                     w4: Bits, w5: Bits, w6: Bits, w7: Bits) {
  // 位宽自检（纯 Scala，构造期即查 ⇒ 接错宽度的字当场响亮报错，不会静默切错）
  require(w0.getWidth == 32 && w1.getWidth == 32 && w2.getWidth == 32 && w3.getWidth == 32 &&
          w4.getWidth == 32 && w5.getWidth == 32 && w6.getWidth == 32 && w7.getWidth == 32,
          "DescWords：8 个字必须都是 32 bit（冻结位打包）")

  // ---- w0 ----
  /** TYPE（8 bit）：见 `DescType`（`0x01` conv3x3 / `0x02` conv1x1 / **`0x03` depthwise** / 旁路 / `0xFF` 哨兵）。 */
  def tpe:    UInt = w0(7 downto 0).asUInt
  /** FLAGS（整 8 bit 透传；位号见 `DescFlags`）。 */
  def flags:  UInt = w0(15 downto 8).asUInt
  // ---- w1 ----
  /** 输出图宽（w1[15:0]）。 */
  def imgW:   UInt = w1(15 downto 0).asUInt
  /** 输出图高（w1[31:16]）。 */
  def imgH:   UInt = w1(31 downto 16).asUInt
  // ---- w2 ----
  /** 输入通道（w2[15:0]）。 */
  def cIn:    UInt = w2(15 downto 0).asUInt
  /** 输出通道（w2[31:16]）。 */
  def cOut:   UInt = w2(31 downto 16).asUInt
  // ---- w3 ----
  /** 卷积分组（w3[7:0]）。 */
  def group:  UInt = w3(7 downto 0).asUInt
  /** 步长（w3[11:8]，4 bit）。 */
  def stride: UInt = w3(11 downto 8).asUInt
  /** 填充（w3[15:12]，4 bit）。 */
  def pad:    UInt = w3(15 downto 12).asUInt
  /** ★★★ E1（2026-10-13）：`w3[31:16]` 的**保留位**改承担**表内偏移**语义（见 spec §4.6）。
    *
    *   `SRC2_K` = 无符号 16 位小整数 = **`Add` 第二路源 = 表序下行 `k` 位那条描述符的 `DST_ADDR`**
    *   （`SRC2_ADDR = DST_ADDR[idx - k]`，`idx` = 本条目表序）。
    *   · `0` ⇒ **没有第二路源**（缺省；**所有非 `Add` 条目恒为 0**）；
    *   · `k > 0` ⇒ 仅对 `Add` 有意义（非 `Add` 带 `k != 0` ⇒ 表非法，RTL 在分派前响亮 `err`）；
    *   · `Add` 带 `k == 0` ⇒ 保留 C3.7 的**列交织**旧约定（已定义的兼容行为，不是错误）。
    *
    *   ★ 为什么选这段位而不是 `FLAGS[7:2]`：后者被冻结的 `desc_table.validate` 规则 (2) 与 RTL 的
    *   `flagsReserved` 双重强制为 0，碰它要动两处**冻结校验**；`w3[31:16]` **不在**任何冻结校验里
    *   （`pack` 恒写 0、`validate` 不看、RTL 不查），是**真正闲置**的保留段。
    *   ★ `pack` 不搬运它（不是 14 字段之一）⇒ 由**转换器在 `pack_table` 之后按字偏移 OR 进去**
    *   （`y1_convert.py` 的 `apply_src2_k`）；8 字格式与 `FIELD_ORDER`/往返**一字未改**。 */
  def src2k:  UInt = w3(31 downto 16).asUInt
  // ---- w4 / w5 / w6（整字） ----
  /** 源地址（输入特征 DDR 地址）。 */
  def srcA:    UInt = w4.asUInt
  /** 目标地址（输出特征 DDR 地址）。 */
  def dstA:    UInt = w5.asUInt
  /** 搬运字节数上界（32 B 粒度；RTL 侧规则 (3) 的区间上界口径见报告 §7 开口项 O2）。 */
  def inBytes: UInt = w6.asUInt
  // ---- w7 ----
  /** 重量化算术右移（w7[7:0]）。 */
  def qShift:  UInt = w7(7 downto 0).asUInt
  /** 层号（w7[15:8]），遥测身份。 */
  def layerId: UInt = w7(15 downto 8).asUInt

  // ---- FLAGS 的两个语义位（融合单元判定）----
  /** 表尾哨兵：`TYPE == 0xFF`。 */
  def isSentinel: Bool = tpe === U(DescType.SENTINEL, 8 bits)
  /** 融合单元的头：`OUT_TO_DDR == 0`（输出留给下一单元，不落 DDR）。 */
  def head: Bool = flags(DescFlags.OUT_TO_DDR) === False
  /** 融合单元的尾：`IN_FROM_PREV == 1`（输入取上一单元输出）。 */
  def tail: Bool = flags(DescFlags.IN_FROM_PREV)
}
