import spinal.core._

/** 3x3 窗口行缓冲 —— 存 2 行历史 + "一行延迟"的窗口时序（本任务冻结，B4 切片依赖）。
  *
  * 接口（冻结，勿改）：win(ci)(r)，r=0 上一行 / 1 当前行 / 2 下一行，三行**同一列**；
  * x(ci) 是当前列的 C_IN 个通道像素（逐列流入）；en 是本拍 x 有效（列推进）。
  *
  * ★ 行列约定（本文件的中心约定；rtl_test/LineBufferTb.v 与 tools/run_linebuffer_ab.sh
  *   按**同一条**对账，三处不许各自解释）：
  *   - 输入流是**行主序**：en=1 的每一拍推进**一列**，每 WIDTH 列构成一行，行与行连续。
  *     col = 本行内第几列（0..WIDTH-1）。本模块**没有 H 输入**、也**不数行**：
  *     列计数器回绕（col 到 WIDTH-1 后回 0）在语义上就等价于换行。
  *   - 窗口 win(ci)(r) 的列坐标一律是**本拍这一列 col**（不是 col-1、不是 col+1）。
  *
  * ★★ "一行延迟"（one row late）的约定，逐字如下（本任务的时序要点）：
  *   「第 r 行（输入行）正在流入的那一拍，吐出的窗口是**输出行 y = r-1** 的窗口：
  *     win(0) = 第 y-1 行、win(1) = 第 y 行、win(2) = 第 y+1 = r 行（就是本拍正在流入的这一行）。
  *     也就是说窗口比输入行**晚一行**产出 —— 输出行 y 的窗口，在第 y+1 行流入时才给出；
  *     输入行 r=0 那一拍吐出的窗口对应输出行 y=-1，是**预滚（pre-roll）**，不是有效输出行。」
  *   为什么必须晚一行：行主序流里第 y+1 行要"读到第 y+1 行"时才存在，所以输出行 y 的窗口
  *   若要在**同一拍**里凑齐 (y-1, y, y+1) 三行，就只能等到第 y+1 行流入。
  *
  * 硬件上这就是**每列一条 2 级竖直移位寄存器**：
  *   hist(ci)(col)(1) 存第 r-1 行、hist(ci)(col)(0) 存第 r-2 行；
  *   本拍**读旧值**读出来当窗口（读的是寄存器现值，本拍的写在时钟沿才生效 ⇒ read-first）：
  *     win(ci)(0) = hist(ci)(col)(0) = 第 r-2 = y-1 行
  *     win(ci)(1) = hist(ci)(col)(1) = 第 r-1 = y   行
  *     win(ci)(2) = x(ci)           = 第 r   = y+1 行
  *   同一拍把 x 压进 hist(1)、原 hist(1) 挪到 hist(0)。
  *   ⇒ 存的就是 **2 行**历史（WIDTH*C_IN*2 个 8bit 寄存器），**没有**可配置深度；
  *     配上行内正在流入的那一行，任何一拍手上的正好是 3 行。
  *
  * 零填充（后续 3x3 切片依赖；两个方向都**读出 0**）：
  *   - 第一行之上：hist 复位为 0 ⇒ 输出行 y=0 的 win(0)（第 -1 行）扫出来就是 0。
  *   - 最后一行之下：本模块没有 H 输入，无法知道图底在哪 ⇒ 由**驱动方**多流一行全 0 的
  *     pad 行（TB 就是这么喂的：H 行图像 + 1 行全 0）⇒ 输出行 y=H-1 的 win(2)（第 H 行）= 0。
  *     注：正因为 H 不在本模块接口里，"下方零填充"是**流的约定**（第 H 行必须喂 0），
  *     不是本模块能自己造出来的；这条约定写在这里，B4 的切片/调度器按此喂。
  *
  * 时序：win 是**组合**输出（本拍 en 的列立刻可见，无输出寄存器、无 2 拍延迟）；
  *       en=0 时不推进列、不改历史（x 的变化不影响已捕获的窗口语义，因为我们只认 en 拍）。
  *
  * ★★ `prime`（**additive** 口，缺省 0，见 C3.10 前置）：一拍把本模块的 per-image 相位清回**上电态**
  *   —— 列指针 `col` 与两行历史 `hist0/hist1` 全部清 0。为什么需要它：本模块**自己按 WIDTH 数行**
  *   （列回绕即换行）、历史只在**上电复位**时清 0，本身没有"第几张图"的运行期复位口 ⇒ 一个实例
  *   连跑第二张图时列/历史还停在上一次的末尾，窗口相位整个错位。`prime` 就是那条"清相位"的口，
  *   由驱动方（`Conv3x3Slice` / `UnitExec`）在每次 `go` 的起点脉冲一拍。
  *   ★ `prime==0` 时本模块与"没有 prime 口"**逐拍同形**（prime 只是 en 之前的一个更高优先分支）。
  *
  * ★★ T-S1（2026-10-13）：**运行期行宽 `rowW`**（additive 口，见 spec §3.1）。
  *   为什么：真表 `desc.bin` 的 conv 层有 **6 个**输入行宽 `{640,320,160,80,40,20}`（最大 640 = `Conv_0`
  *   的 `IMG_W·s`）—— 若"列回绕 = 换行"的边界钉在**展开期常量 `WIDTH`** 上，一张网表就只能服务一个行宽
  *   ⇒ 单张网表永远跑不完这条链。修法：**分配仍按 `WIDTH`**（`hist0/hist1` 仍是 `WIDTH × C_IN` 个寄存器
  *   = `W_MAX` 口径），**计数/回绕按运行期 `rowW`**（`1 ≤ rowW ≤ WIDTH`，由驱动方在 `go` 那一刻把住）。
  *   ★ `rowW == WIDTH` 时本模块与"没有 rowW 口"**逐拍同形**（既有闸门据此零改动成立）。
  *   ★ 越界（`rowW > WIDTH`）不在本模块兜：列指针仍只有 `log2Up(WIDTH)` 位 ⇒ 由驱动方（`UnitExec`/
  *     `BypassExec` 的 `go` 对账）**响亮 err** 拦住（本模块是纯数据通路，不设运行期 assert）。
  */
case class LineBuffer(C_IN: Int, WIDTH: Int) extends Component {
  require(C_IN >= 1, "C_IN 至少 1 个通道")
  require(WIDTH >= 1, "WIDTH 至少 1 列")

  val io = new Bundle {
    val x     = in  Vec (SInt(8 bits), C_IN)          // 当前列的 C_IN 个通道像素（逐列流入）
    val en    = in  Bool()                            // 本拍 x 有效（列推进）
    /** ★★ T-S1：**运行期行宽**（= 本层输入行宽；`WIDTH` 是分配上限 `W_MAX`）。`rowW == WIDTH` ⇒ 与旧行为同形。 */
    val rowW  = in  UInt(16 bits)
    val prime = in  Bool()                            // ★ additive：本拍清相位到上电态（col + hist0/hist1 = 0）
    /** ★ C4a.5b §4.5（**additive** 口）：零填充码点 = 该层 `z_pad`（= 输入真实 0 的码点 `z_x`）。
      *   `prime` 拍把两行历史清成它（取代硬编码 0）。喂 0 时与旧行为逐拍同形（既有闸门不改）。 */
    val pad_val = in SInt(8 bits)
    val win   = out Vec (Vec(SInt(8 bits), 3), C_IN)  // win(ci)(r)：r=0 上一行 / 1 当前行 / 2 下一行，同一列
  }
  noIoPrefix()

  // 列指针：只在 en 拍推进，到 WIDTH-1 回 0（回绕即换行，见上面的行列约定）。
  // log2Up(WIDTH) max 1：WIDTH=1 时也要 1 位，否则 Vec 索引没有位宽。
  // ★★ T-S1：回绕点从展开期常量 `WIDTH-1` 改成**运行期** `rowW-1`（分配仍按 `WIDTH`）。`rowW==WIDTH` ⇒ 同形。
  val cw  = (log2Up(WIDTH) max 1)
  val col = Reg(UInt(cw bits)) init (0)
  /** ★★ T-S1：运行期回绕点 `rowW - 1`（截到列地址宽度；`rowW ≥ 1` 由驱动方保证）。 */
  val rowWm1 = (io.rowW - U(1, 16 bits)).resize(cw)

  // 2 行历史，按**列**排布（每列一条 2 级竖直移位寄存器）：
  //   hist0(ci)(c) = 第 r-2 行第 c 列、hist1(ci)(c) = 第 r-1 行第 c 列。
  // 复位为 0 ⇒ 第一行之上自动读出零填充。
  // 注：SpinalHDL 的 Vec 字面量只吃一维，二维要嵌套写（hist0(ci)(c)）。
  val hist0 = Vec(Vec(Reg(SInt(8 bits)) init (0), WIDTH), C_IN)
  val hist1 = Vec(Vec(Reg(SInt(8 bits)) init (0), WIDTH), C_IN)

  // 读：组合多路，取本拍列 col 的两级历史（取的是**旧值**，本拍的写在下个时钟沿才生效）。
  for (ci <- 0 until C_IN) {
    io.win(ci)(0) := hist0(ci)(col)
    io.win(ci)(1) := hist1(ci)(col)
    io.win(ci)(2) := io.x(ci)
  }

  // 写：只在 en 拍、且只动**本拍这一列**。写成静态的 when(col === c) 解码而不是
  // hist0(ci)(col) := ... 的动态写，是为了让生成风格可预测（4 路解码，无歧义）。
  // prime（additive 口）：本拍清相位到**上电态**（col 与两行历史全 0，与上面 init 同值）。
  // prime 优先于 en（清相位时不接受新列）；prime==0 时下面的分支与旧行为逐拍同形。
  // ★ C4a.5b §4.5：`prime` 把两行历史清成 `io.pad_val`（该层零填充码点），不再是硬编码 0
  //   ⇒ 输出行 y=0 的 win(0)（第 -1 行）读出的是 `z_pad`。`pad_val==0` 时与旧 init 0 逐拍同形。
  when(io.prime) {
    col := U(0, cw bits)
    for (c <- 0 until WIDTH) {
      for (ci <- 0 until C_IN) {
        hist0(ci)(c) := io.pad_val
        hist1(ci)(c) := io.pad_val
      }
    }
  } elsewhen(io.en) {
    col := Mux(col === rowWm1, U(0, cw bits), (col + 1).resize(cw))
    for (c <- 0 until WIDTH) {
      when(col === U(c, cw bits)) {
        for (ci <- 0 until C_IN) {
          hist0(ci)(c) := hist1(ci)(c)   // 第 r-1 行下沉成"第 r-2 行"
          hist1(ci)(c) := io.x(ci)       // 本拍流入的第 r 行进来
        }
      }
    }
  }
}
