import spinal.core._

/** 两路 int8 **逐点饱和相加** —— 旁路算子（C3.7，YuNet 的 `Add`：残差加 `x + skip`）。
  *
  * ============================== 冻结行为（"硬件怎么算"的唯一真源） ==============================
  * · `y[ci] = clamp8(x_a[ci] + x_b[ci])`，clamp 到 **[-128, 127]**（**饱和**，**不回绕**）。
  *   ★ "饱和 vs 回绕"是本单元**唯一**的算术自由度，而且它在**真实数据上必然发生**：
  *     `c3_traffic_full.md` §4 的两个 `Add`（残差加）两路都是 int8 激活，`127+127` 这类点
  *     必须落到 **+127**（回绕会给 **-2**，是个只差一个符号位的**静默**错）⇒ 判据里专门有一条
  *     "把 clamp 改成回绕"的负对照（`tools/run_bypass_ab.sh` 负对照 A）。
  *   ★ 中间和用 **9 位二补数**：`int8 + int8 ∈ [-256, 254]`，9 位刚好容得下（不需要更多，
  *     也不做任何 scale/zero-point —— 本单元**无量化**，只有饱和）。
  * · **无量化**：不做 scale / zero-point / 移位。Q 口径在本算子上**不涉及**（`Add` 是
  *   "同口径两数相加"；YuNet 里两路输入同刻度，这也是残差加的前提）。
  *
  * ============================== 接口（★ 双输入；与 Conv3x3Slice **同数据握手**但**非同端口集**） ==============================
  *   ★ **本单元是四类旁路算子里的唯一双输入单元**，接口因此比 MaxPool/Resize 多一路：
  *     x_a(C) + x_a_valid ：A 路，一拍吃**一列**（列内一次给全 C 个通道）
  *     x_b(C) + x_b_valid ：B 路，**与 A 同拍、同列**（本单元**不缓存任何一路**，没有跨拍对齐）
  *     x_ready            ：**一条** ready，同时作用于两路（"两路都到齐才算一拍"）
  *     y(C) + y_valid     ：同拍出**一个输出列**（`y_valid = x_a_valid && x_b_valid && x_ready`）
  *     imgC / imgW        ：只读常量自报（C / WIDTH），装置 time 0 对账（同 MaxPool/Resize 的用途）
  *   ★★ **O1 开口项（承重，别当成已解决）**：描述符格式（C3.2 冻结）**只有一个** `SRC_ADDR`，
  *      而本网的两个 `Add`（`Add_44`/`Add_50`）两路**都来自 DDR**（MaxPool 的输出 + Resize 的输出，
  *      是两个独立单元）⇒ 格式**表达不了第二路源**。已记在 `reports/c3_descriptor_format.md` §7 O1，
  *      属 **C4/M2 的转换器**（spec 修订候选），**本任务不改描述符格式**。
  *      ⇒ 本文件只把"第二路源是谁"**留作开口项**：C3.8 的 `UnitExec` 里 A 路 = `IN_FROM_PREV`/
  *        融合缓冲（片上）、B 路 = `SRC_ADDR`（DDR）是本步 `UnitExec` 的接法**候选**，第二路的
  *        源地址**从哪来**（新增字段 / `SRC_ADDR + IN_BYTES` 约定 / 转换器让它落片上）**未定**。
  *      ⇒ 装置（rtl_test/BypassTb.v）在 `+OP=add` 下把两路**都从同一个向量文件**取（每列 2*C 个
  *        字节 = A 的 C 个通道 + B 的 C 个通道），这是**装置侧的取数约定**，与硬件接口的
  *        "两路同拍列流"一一对应，**不**代表 DDR 侧已经有两路源。
  *   ★ **单边有效的语义（冻结）**：`x_b_valid = 0` 时**一拍都不吃、一颗都不出**（`y_valid = 0`
  *     且 `x_a` 也**不被消费** —— 因为 ready 是共享的、消费条件里含 B 路 valid）。
  *     装置有一条 `+STALLB=1` 的作业专门钉这条（否则"y_valid 只看 A 路"的错**永不显形**：
  *     正常跑两路 valid 总是同拍齐，错误的行为在功能上不可观测）。
  *
  * ============================== 行列约定 / 流时序（★ 下游 C3.8/C3.10 依赖这一节） ==============================
  * 输入流是**行主序的列流**（与 MaxPoolUnit/ResizeUnit 同）：第 n 拍给输入行 `r = n / WIDTH`、
  * 列 `c = n % WIDTH`。本模块**不看行/列**（逐点算子，没有任何几何状态）⇒ 输入拍 ↔ 输出拍
  * **一一对应、同拍**：
  *     `y_valid = x_a_valid && x_b_valid`（`x_ready ≡ 1`），输出顺序 = 输入的**逐拍复刻**。
  *   于是 `(C, W, H)` ⇒ `(C, W, H)`（形状不变，与 `c3_traffic_full.md` §4 的"Add 读 2 / 写 1"一致：
  *   两路读、一路写，**每帧激活 IO = 2 读 + 1 写**）。
  *
  * ★ 速率/时延画像（★ C3.8/C3.10 **别假定单一速率模型** —— **五个单元各不同**，且**没有任何闸门钉住**）：
  *   · Conv3x3Slice：x_ready 占空 1/11（1 拍收列 + 10 拍阵列，~9%）—— 进 ~9% / 出 ~9%（1 列 / 11 拍）；
  *   · MaxPoolUnit ：x_ready ≡ 1（**100% 吃输入**），输出 1 像素 / 4 拍输入（**25%**），输出与凑齐窗口**同拍**；
  *   · ResizeUnit  ：输入占空 **20%**（2W 收 / 10W 一拍周期）、输出占空 **80%**，输出比输入**晚一个输入行对**（≈2W 拍）；
  *   · AddUnit     ：x_ready ≡ 1（100% 吃）、1 列 / 1 拍（100%）、时延 0 拍（组合）—— **要求两路 operand valid 同拍**；
  *   · SigmoidUnit ：x_ready ≡ 1（100% 吃）、1 列 / 1 拍（100%）、时延 0 拍（组合查表）。
  *   ⇒ **Add 与 Sigmoid 都是 1:1（进出同拍、`x_ready ≡ 1`）**；**差别只在 Add 额外要求两路 operand valid 同拍**。
  *   ⚠ Add 的"两路同拍"是**接口契约**：本单元**不**做速率匹配（若 A 路的产出速率 ≠ B 路，
  *     `UnitExec` 必须自己在两路之间做对齐/缓冲，本单元只在"两路 valid 同拍为 1"的那些拍上出数）。
  *   ⚠ 现有闸门（tools/run_bypass_ab.sh）只证**功能值**：不钉时延、也不钉 x_ready 占空。
  *
  * ★ 状态大小：**零寄存器**（纯组合：一个 9 位加法 + 两个比较 + 一个 2:1 选择）⇒ 不计入
  *   S5 面积闸门（C3.13）；它的代价是**两路激活读**（流量侧的 2 读 + 1 写，已计入 C3.1 的
  *   `BYPASS_BYTES=6,945,600`，见 `reports/c3_traffic_full.md` §4）。
  *
  * ★ **仿真覆盖的已知残留风险**（与 rtl_test/BypassTb.v 和 tools/run_bypass_ab.sh 同口径）：
  *   只仿 **C=2**（DUT 端口名 x_a_0/x_a_1/x_b_0/x_b_1 不可参数化，`BP_NCI != 2` 时装置 time 0
  *   `$fatal`）；形状只仿 **W=4,H=4** 与 **W=5,H=3**（5 是非 2 的幂列宽；H=3 是**奇数** ——
  *   逐点算子对 H 的奇偶**没有**要求，装置的"偶数 H"硬约束只对 maxpool/resize 生效，这一档
  *   就是来证明那条放宽**是真的**）。更大 C / 其它 W、H **未被仿真**。
  *   形状参数在本单元里**只喂自报端口**（无列计数器、无 accRow）⇒ 形状覆盖对本单元的**数据通路**
  *   增量很小（真正的覆盖率来自"C 个通道各自独立" + 饱和/边界值：闸门与自检都在向量里注入
  *   `127+127`/`-128+-128` 等角点，并硬断言 `SAT_EVENTS > 0`）。
  */
class AddUnit(val C: Int = 8, val WIDTH: Int = 64) extends Component {
  require(C >= 1, "C 至少 1 个通道")
  require(WIDTH >= 1, "WIDTH 至少 1 列")

  val io = new Bundle {
    // ---- 输入 A：逐列、行主序（列内一次给全 C 个通道）----
    val x_a       = in  Vec (SInt(8 bits), C)
    val x_a_valid = in  Bool()
    // ---- 输入 B：与 A **同拍、同列**的第二路（★ 源见文件头 §O1 开口项）----
    val x_b       = in  Vec (SInt(8 bits), C)
    val x_b_valid = in  Bool()
    // ---- 单条 ready：一把同时作用于两路（本单元不缓存任何一路，无内部节拍）----
    val x_ready   = out Bool()
    // ---- 输出：同拍出一个输出列（C 个通道同时出）----
    val y         = out Vec (SInt(8 bits), C)
    val y_valid   = out Bool()
    // ---- 自报：只读常量（不参与数据通路）----
    val imgC      = out UInt(16 bits)
    val imgW      = out UInt(16 bits)
  }
  noIoPrefix()

  io.imgC := U(C, 16 bits)
  io.imgW := U(WIDTH, 16 bits)

  // ================================ 9 位中间和 + 饱和 ================================
  // 下面五个信号**显式命名**（不是内联表达式）：负对照 A 的靶点要能"把 clamp 关掉"
  // （clampHi/clampLo 恒 0 ⇒ 输出退化成 wrapVal = 低 8 位 = 回绕），见
  // tools/run_bypass_ab.sh 的 mut_make(add-wrap) 与 rtl_test/BypassTb.v 的注释。
  val sum9    = Vec(SInt(9 bits), C)               // 两路 int8 的 9 位二补数和
  val clampHi = Vec(Bool(), C)                     // 和 > +127 ⇒ 饱和到 +127
  val clampLo = Vec(Bool(), C)                     // 和 < -128 ⇒ 饱和到 -128
  val wrapVal = Vec(SInt(8 bits), C)               // 和的最低 8 位（= 回绕值，**只作负对照的对照项**）
  val satVal  = Vec(SInt(8 bits), C)               // 饱和值（clampHi ? +127 : -128）
  for (ci <- 0 until C) {
    sum9(ci)    := io.x_a(ci).resize(9) + io.x_b(ci).resize(9)
    clampHi(ci) := sum9(ci) > S(127, 9 bits)
    clampLo(ci) := sum9(ci) < S(-128, 9 bits)
    // `resize(8)` 对 SInt 就是**截高保留低 8 位**（二补数）≡ Verilog 的 `& 0xFF` ≡ 回绕。
    wrapVal(ci) := sum9(ci).resize(8)
    satVal(ci)  := Mux(clampHi(ci), S(127, 8 bits), S(-128, 8 bits))
    // 唯一输出口：越界就饱和，不越界就原样（= 低 8 位，此时 wrapVal 与和相等）。
    io.y(ci)    := Mux(clampHi(ci) || clampLo(ci), satVal(ci), wrapVal(ci))
  }

  // ================================ 握手（共享 ready；两路都到齐才算一拍） ================================
  // 本单元是纯组合、零状态 ⇒ **从不反压**（x_ready ≡ 1）；但它**要求两路同拍**：
  // 任一路 valid = 0 的这一拍既不出数（y_valid=0）也不消费 A（beat=0 ⇒ 消费条件不成立）。
  io.x_ready := True
  val beat   = io.x_a_valid && io.x_b_valid && io.x_ready
  io.y_valid := beat
}
