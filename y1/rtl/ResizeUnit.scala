import spinal.core._

/** x2 最近邻上采样单元 —— 旁路算子（C3.6，YuNet 的 `Resize`：上采样 2x、`nearest`）。
  *
  * ============================== 冻结行为（"硬件怎么算"的唯一真源） ==============================
  * · **x2 最近邻**：`out[c][2y+dy][2x+dx] = in[c][y][x]`（dy,dx ∈ {0,1}）。
  *   **无量化、无插值**：输出就是输入像素的**逐位复制**（int8 原样透传，不做任何算术）。
  * · 输入张量 `(C, W, H)` ⇒ 输出 `(C, 2W, 2H)`。`W` 任意（>=1）。
  *   ★ **H 必须偶数**：本单元按**输入行对**（(2t, 2t+1)）为单位攒够两行再出数，
  *     奇数 H 会让最后一行攒了却没配对（输出少一整块）。本模块接口里**没有 H**（与 Conv3x3Slice
  *     同形：按 WIDTH 自己数列、不要 H）⇒ 由**驱动方**保证偶数：装置 rtl_test/BypassTb.v 与参考
  *     tools/bypass_ref.py 都按 `H % 2 == 0` 硬断言，奇数直接报红。
  *     （YuNet 的 Resize 输入高都是偶数，C3.8 的调度器按偶数 H 下发。）
  *   ★ **奇数 W 合法但当前完全"未栅"**：RTL 对任意 `W>=1`（含奇数）都能跑（输出宽 2W 恒为偶数），
  *     但闸门 tools/run_bypass_ab.sh 硬拒奇数 W（`W % 2` ⇒ exit 3），参考的 `resize_mut_col` 突变体
  *     也**要求偶数 W** ⇒ 奇数 W **连正对照都进不去**（本步不加 W=5 跑；要覆盖须先扩闸门/参考）。
  *   ★ **仿真覆盖的已知残留风险**（同 rtl_test/BypassTb.v 与 tools/run_bypass_ab.sh）：
  *     只仿 **C=2**（端口名 x_0/x_1 不可参数化）、列宽只仿 **W∈{4,6}**；更大 C / 其它 W（含奇数）**未被仿真**。
  *
  * ============================== 接口（与 Conv3x3Slice **同数据握手**，非同端口集） ==============================
  *   ★ 与 Conv3x3Slice **同数据握手（x/x_valid/x_ready/y/y_valid 同名同宽）但非同端口集**：
  *     本单元**没有权重口**（we/waddr/wdin 是 conv-only），自报字段是 imgC/imgW 而非 conv 的 grp
  *     ⇒ C3.8 的 UnitExec **必须特判**权重事务（仅 conv）与自报字段（grp vs imgC/imgW）。
  *   x(C) + x_valid/x_ready ：一拍吃**一列**（列内一次给全 C 个通道）
  *   y(C) + y_valid         ：一拍出**一个输出像素**（像素内一次给全 C 个通道）
  *   imgC / imgW            ：只读常量自报（C / WIDTH），装置 time 0 对账（防"定点生成参数不符"静默错判）。
  *
  * ============================== 行列约定 / 流时序（★ 下游 C3.8/C3.10 依赖这一节） ==============================
  * 输入流是**行主序的列流**：第 n 拍给输入行 `r = n / WIDTH`、列 `c = n % WIDTH`（与 MaxPoolUnit 同）。
  * 本模块**按输入行对**工作，一拍一个相位（`stOut` 一位状态）：
  *   相 0（stOut=0，**收列**，`x_ready=1`）：吃 W 列写进 `rb(half)`；`half`=0/1 表示本行对里的第 0/1 行。
  *        收满第一行（half 0→1）后继续收第二行；第二行收满 ⇒ 切相 1。
  *   ⊙ 收列期间 `y_valid=0`（不反压整幅图，只反压"进料"这一半时间）。
  *   相 1（stOut=1，**出像素**，`x_ready=0`）：连出 **8W** 拍 = 输出行 `4t..4t+3`（4 个输出行 x 2W 列）：
  *        行指针 `orow` 数 0..3（本组的第几个输出行），`bankPh = orow(1)` = 0 时复刻输入行 2t（rb(0)）、
  *        = 1 时复刻输入行 2t+1（rb(1)）；行内输出列号 `X = oc`（0..2W-1），`dx = X(0)`，`srcCol = X/2`。
  *        ⇒ `y = rb(bank)(srcCol)`，`bank = bankPh`（**这个相位是内容相关的**：两半读的是不同的行缓冲）。
  *   一个输入行对 = W 拍收 + W 拍收 + 8W 拍出 = 10W 拍，产出 8W 个输出像素（= 4 行 x 2W）。
  * 输出顺序 = 输出张量的**行主序**：Y = 0,1,2,... 逐行，行内 X = 0..2W-1。
  *   （Y=4t+g 落在"输入行对 t"的第 g 个输出行上：g=0,1 复刻输入行 2t、g=2,3 复刻输入行 2t+1。）
  *
  * ★ 速率/时延画像（★ C3.8/C3.10 **别假定单一速率模型** —— **五个单元各不同**，且**没有任何闸门钉住**）：
  *   · Conv3x3Slice：x_ready 占空 1/11（1 拍收列 + 10 拍阵列，~9%）—— 进 ~9% / 出 ~9%（1 列 / 11 拍）；
  *   · MaxPoolUnit ：x_ready ≡ 1（**100% 吃输入**），输出 1 像素 / 4 拍输入（**25%**），输出与凑齐窗口**同拍**；
  *   · ResizeUnit  ：输入占空 **20%**（2W 收 / 10W 一拍周期）、输出占空 **80%**，输出比输入**晚一个输入行对**（≈2W 拍）；
  *   · AddUnit     ：x_ready ≡ 1（100% 吃）、1 列 / 1 拍（100%）、时延 0 拍（组合）—— **要求两路 operand valid 同拍**；
  *   · SigmoidUnit ：x_ready ≡ 1（100% 吃）、1 列 / 1 拍（100%）、时延 0 拍（组合查表）。
  *   ⇒ **Add 与 Sigmoid 都是 1:1（进出同拍、`x_ready ≡ 1`）**；**差别只在 Add 额外要求两路 operand valid 同拍**。
  *   ⚠ 现有闸门（tools/run_bypass_ab.sh）只证**功能值**：不钉时延、也不钉 x_ready 占空
  *     ⇒ 纯时延/占空的回归目前**不可见**（C3.8/C3.10 要自己另设判据，别指望这里）。
  *
  * ★ 状态大小：两个行缓冲 `rb(2)(W x C)` = 2*W*C 个 8bit 寄存器 + 三个小计数器 ⇒ **纯 FF**。
  *   ★ **FF 是本项目稀缺资源**（C3.0：3 行窗口落 FF = 245,760 > 空闲 215,004，而 DRM 余量 +98%）
  *     ⇒ "纯 FF"是**代价**、不是宽慰。真最大层：Resize `[1,16,80,80]` ⇒ 2*W*C = 2,560 个值 =
  *     **20,480 FF**；同层对照 MaxPool `[1,16,320,320]` ⇒ (W/2)*C = 2,560 = **20,480 FF**
  *     ⇒ 计入 **S5 面积闸门（C3.13）**（本步只证功能，不证面积、不证落 DRM）。
  *   ★ 第 2 行缓冲**不是流式必需**（单行流式同样吞吐、只要 W*C）：它存在的理由是让 `bankPh`(dy 相位)
  *     选中**不同的行缓冲**，使 dy 相位成为**内容相关因而可观测** —— 这是**为可测性/可观测性付的代价**，
  *     不是"多余的存储"，也不是单趟流的硬需求（详见下 §"为什么 dy 相位不能省"）。
  *
  * ★ 为什么这张表里 dy 相位不能省（它就是 `bankPh`）：如果只攒一行、把一个输入行复刻成两个输出行
  *   （一个行对的两半都读同一个缓冲），那 dy 就成了**纯延迟相位**、对数据毫无影响 —— 于是"相位反了"
  *   这类错**在功能上不可观测**（判据会退化成橡皮章；纯最近邻 2x 里把 (dy,dx) 字面改写成 (1-dy,1-dx)
  *   本来就跟恒等变换等价）。本模块刻意让 dy 相位选中**不同的行缓冲**，于是相位就是内容相关的，
  *   负对照 B 才抓得住（见 tools/run_bypass_ab.sh 与 rtl_test/BypassTb.v 的注释）。
  */
class ResizeUnit(val C: Int = 8, val WIDTH: Int = 64) extends Component {
  require(C >= 1, "C 至少 1 个通道")
  require(WIDTH >= 1, "WIDTH 至少 1 列")

  val io = new Bundle {
    // ---- 输入像素流：逐列、行主序（列内一次给全 C 个通道）----
    val x       = in  Vec (SInt(8 bits), C)
    val x_valid = in  Bool()
    val x_ready = out Bool()
    // ---- 输出像素流：一拍一个输出像素，C 个通道同时出 ----
    val y       = out Vec (SInt(8 bits), C)
    val y_valid = out Bool()
    // ---- 自报：只读常量（不参与数据通路）----
    val imgC    = out UInt(16 bits)
    val imgW    = out UInt(16 bits)
    /** ★★ T-S1（2026-10-13）：**运行期行宽**（= 本层输入行宽 = `IMG_W/2`；`WIDTH` 是分配上限 `W_MAX`）。
      *   本单元按输入**行对**工作：`col` 回绕 = 换行（数到 `rowW-1`）、输出列号数到 `2·rowW-1`；
      *   两个行缓冲 `rb` 与输出计数位宽仍按 `WIDTH` 分配。`rowW == WIDTH` ⇒ 与旧行为**逐拍同形**；
      *   `1 ≤ rowW ≤ WIDTH` 由驱动方（`BypassExec` 的 `go` 对账）拦住（本单元是纯数据通路）。 */
    val rowW    = in  UInt(16 bits)
  }
  noIoPrefix()

  io.imgC := U(C, 16 bits)
  io.imgW := U(WIDTH, 16 bits)

  val cw  = (log2Up(WIDTH) max 1)         // 输入列号 0..W-1
  val oxw = (log2Up(2 * WIDTH) max 1)     // 行内输出列号 0..2W-1
  val xw  = (log2Up(WIDTH) max 1)         // 源列号 0..W-1
  /** ★★ T-S1：运行期两个回绕点 —— 输入列 `rowW-1`、行内输出列 `2·rowW - 1`。
    *   `rowW == WIDTH` ⇒ 与旧的展开期常量逐值相同（既有闸门零改动）。 */
  val rowWm1 = (io.rowW - U(1, 16 bits)).resize(cw)
  val ocWm1  = ((io.rowW << 1) - U(1, 17 bits)).resize(oxw)

  /** 相位：False = 收列（x_ready=1），True = 出像素（y_valid=1）。 */
  val stOut  = Reg(Bool()) init (False)
  /** 收列相位内的列指针 0..WIDTH-1（回绕即换行）。 */
  val col    = Reg(UInt(cw bits)) init (0)
  /** 本行对里的第几行：False = 第 0 行（写 rb(0)），True = 第 1 行（写 rb(1)）。 */
  val half   = Reg(Bool()) init (False)
  /** 出像素相位内的**行内**输出列号 0..2W-1。 */
  val oc     = Reg(UInt(oxw bits)) init (0)
  /** 出像素相位内"本组第几个输出行"0..3：g=0,1 复刻行对的第 0 行，g=2,3 复刻第 1 行。 */
  val orow   = Reg(UInt(2 bits)) init (0)
  /** 两个行缓冲：rb(bank)(x)(ci)，bank=0 存行对的第 0 行、bank=1 存第 1 行。 */
  val rb     = Vec(Vec(Vec(Reg(SInt(8 bits)) init (0), C), WIDTH), 2)

  // ================================ 握手 ================================
  io.x_ready := !stOut
  val beat   = io.x_valid && io.x_ready

  // ================================ 出像素相位（组合读行缓冲） ================================
  // bankPh（dy 相位）：本拍在复刻行对的**哪一行** —— 输出行 4t/4t+1（g=0,1）复刻第 0 行、
  // 4t+2/4t+3（g=2,3）复刻第 1 行。它就是 orow 的最高位。
  // （输出行内的 dy —— 即 g 的最低位、4t 与 4t+1 谁先 —— 对数据无作用：两行同源，见文件头。）
  val bankPh = orow(1)
  // 行内输出列号 X = oc（0..2W-1）；源列 = X/2（dx = X(0) 这个相位本身不选数据）。
  val srcCol = UInt(xw bits)
  srcCol    := (oc >> 1).resize(xw)
  // 源行手：bankPh ⇒ 读不同的行缓冲（★ 这是该相位唯一的内容作用，也是负对照 B(dy) 的突变点）。
  val bankSel = UInt(1 bits)
  bankSel    := bankPh.asUInt

  for (ci <- 0 until C) {
    io.y(ci) := rb(bankSel)(srcCol)(ci)
  }
  io.y_valid := stOut

  // ================================ 状态推进 ================================
  when(beat) {
    // 收列：按 half 写进对应行缓冲的本列（动态列下标 = 2 路解码，风格与 LineBuffer 一致）。
    for (ci <- 0 until C) {
      when(!half) {
        rb(0)(col)(ci) := io.x(ci)
      } otherwise {
        rb(1)(col)(ci) := io.x(ci)
      }
    }
    when(col === rowWm1) {
      col := U(0, cw bits)
      when(!half) {
        half := True                                   // 第 0 行收满 ⇒ 接着收第 1 行
      } otherwise {
        half  := False                                 // 第 1 行也收满 ⇒ 行对齐备，切出像素相位
        stOut := True
        oc    := U(0, oxw bits)
        orow  := U(0, 2 bits)
      }
    } otherwise {
      col := (col + 1).resize(cw)
    }
  }
  when(stOut) {
    when(oc === ocWm1) {
      oc := U(0, oxw bits)                             // 本输出行出完
      when(orow === U(3, 2 bits)) {
        orow  := U(0, 2 bits)                          // 4 个输出行都出完 ⇒ 回去收下一个行对
        stOut := False
      } otherwise {
        orow := (orow + 1).resize(2)
      }
    } otherwise {
      oc := (oc + 1).resize(oxw)
    }
  }
}
