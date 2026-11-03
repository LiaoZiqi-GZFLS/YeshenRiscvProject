import spinal.core._

/** 定点 sigmoid：int8 **Q3.4** 输入（步长 1/16）⇒ int8 **Q0.7** 输出（步长 1/128），**256 项查表**。
  * —— 旁路算子（C3.7，YuNet 的 `Sigmoid`，6 个：两个分类头 + 四个框回归头）。
  *
  * ============================== 冻结行为（"硬件怎么算"的唯一真源） ==============================
  * · 表：`lut[k] = floor(127 * sigmoid((k-128) / 16) + 0.5)`，`k = 0..255`；
  *   地址 `k = x + 128`（int8 的 `x` ⇒ 无符号偏移；硬件里就是**翻转符号位** `x ^ 0x80`）。
  *   `out = lut[x + 128]`，即 **`out = round(127 * sigmoid(x/16))`**（四舍五入取最近；`.5` 向上，
  *   见下 §"取整方向"）。
  * · **口径换算**：输入 `x` 是 **Q3.4**（定点，1 个整数位 + 4 个小数位 ⇒ 步长 1/16，
  *   取值范围 [-8, 7.9375]，落 int8 的 [-128,127]）；输出是 **Q0.7**（步长 1/128，值域 [0,1)，
  *   即 sigmoid 的 (0,1) **用 7 位小数表示**）⇒ `127 * sigmoid(·) ∈ [0, 127]`，
  *   **永不越界、永不为负**（所以本单元**没有**饱和逻辑：它是"表本身就是 int8"的算子）。
  * · ★★ **"Q3.4 / Q0.7" 是本计划的冻结选择，不是 spec / 不是 YuNet 的实测刻度**
  *   （plan 总约定第 4 条 + C3.13 缺口清单）。yuNet 实际的 sigmoid 缩放/零点由 **C4/M2 的量化
  *   参数**决定 ⇒ **记为 C4 开口项**（与 R6 同档：`desc_table.py` 的 `QUANT_SHIFT` 也是占位口径，
  *   见 `reports/c3_descriptor_format.md` §7 O4）。换刻度 = 换这张表（一个生成期常量），
  *   数据通路**不变** —— 这正是"查表"这个选择的余量所在。
  *
  * ============================== 表**住在哪**、以及它凭什么可信（★ 本任务的核心） ==============================
  * 表 = 一条 **`Mem(SInt(8 bits), 256)`**（`lut`，**只读**，无写口）；`y = lut.readAsync(idx)`
  * （组合读）。**Mem 带生成期初值**（`.init(...)`）= "上电即为表"，不需要运行期加载状态机
  * ⇒ **可综合**（256 x 8bit ROM：ROM_DISTRIBUTED 或一块 BRAM 都行；面积计入 S5 闸门 C3.13）。
  * ★ **实现选择（诚实记录 —— 任务允许两种做法，本条说明实际选了哪种）**：
  *   实测 SpinalHDL 1.15 对 `Mem(SInt(8), 256).init(256 项)` 的产物**不是** 256 个硬编码常量，而是
  *     `initial begin $readmemb("SigmoidUnit.v_toplevel_lut.bin", lut); end`
  *   即**表在运行期从一个生成出来的初值文件载入**（`gen/<网表名>.v_toplevel_lut.bin`，256 行、
  *   每行 8 个二进制字符；它是 `gen/` 下的生成物、不入库）。**这正是计划里"表要落成文件、
  *   由 `$readmemh` 载入、好复核"的那条路**，只是载入者是 **RTL 自己**、格式是二进制（`$readmemb`）。
  *   ⇒ 于是三份拷贝互相钉住：
  *     ① **RTL 的表**  = `gen/<网表>.v_toplevel_lut.bin`（RTL 运行期真的在读它）
  *     ② **导出的表**  = `gen/sigmoid_lut.hex`（`tools/bypass_ref.py --genlut=` 按同一条公式写的十六进制）
  *     ③ **装置自算**  = `rtl_test/BypassTb.v` 用 `+LUTFILE=` `$readmemh` 载入 ② 后**自己**查表算期望
  *   对账（都在 `tools/run_bypass_ab.sh` 里，且都拿"计算值"比"外部冻结量"，不是恒等式）：
  *     · `--lutbin=①` 与 `--lutfile=②` 各自与**冻结公式**在 **256 个码点上逐项**比（各打印一个 `*_OK=1`）；
  *     · ② 重生成两次 ⇒ md5 必须一致且与 gen/ 里那份**逐字节相同**（确定性）；
  *     · 装置侧 ③ 与 DUT 输出**逐字节**比（打印 `LUT-XCHK=0`）且要求**跑满 256 个码点**（打印 `LUT-CODES=256`）；
  *     · 闸门侧还有一条**全码点正对照**：把 256 个码点（扫一遍）喂进去，DUT 输出与 ② 的查表结果 MISMATCH=0。
  *   ⚠ 任一侧改坏都会发火（负对照 B 就是"取址错了"：装置侧 `LUT-XCHK=254`、闸门侧 MISMATCH=254）。
  *   ⚠ **运行期依赖**：`$readmemb` 的路径是**相对**的 ⇒ 跑仿真时那个 .bin 必须躺在 vvp 的 CWD 里
  *     （闸门会把它拷进工作目录；缺了它 vvp 只发 warning、`lut` 全 X ⇒ 输出全错）。
  * · **取整方向**（冻结）：`floor(v + 0.5)`，`v = 127 * sigmoid(x/16) >= 0` ⇒ 即"四舍五入、
  *   `.5` 向上"（**不是** Python `round()` 的银行家舍入！`bypass_ref.sigmoid_lut()` 与
  *   `SigmoidUnit.lutInit` 都写 `floor(v+0.5)`）。`x = 0 ⇒ v = 63.5 ⇒ 64` 是**表中点**，
  *   两个自检都硬断言它（plan Step 2）。
  *
  * ============================== 接口（与 MaxPoolUnit/ResizeUnit/Conv3x3Slice **同数据握手**，非同端口集） ==============================
  *   x(C) + x_valid/x_ready ：一拍吃**一列**（列内一次给全 C 个通道）
  *   y(C) + y_valid         ：**同拍**出**一个输出列**（查表是组合读，没有输出寄存器）
  *   imgC / imgW            ：只读常量自报（C / WIDTH），装置 time 0 对账（同 MaxPool/Resize 的用途）
  *   ⚠ 本单元**没有权重口**（conv-only）⇒ C3.8 的 `UnitExec` 仍须特判（同 MaxPool/Resize 的注释）。
  *
  * ============================== 行列约定 / 流时序 ==============================
  * 输入流是**行主序的列流**（与其它三个旁路单元同）：第 n 拍给输入行 `r = n / WIDTH`、
  * 列 `c = n % WIDTH`。本单元**不看行/列**（逐点、无几何状态）：
  *     `y_valid = x_valid`（`x_ready ≡ 1`），输出顺序 = 输入的**逐拍复刻**，形状 `(C,W,H)` 不变。
  *   与 `c3_traffic_full.md` §4 的 "Sigmoid 读 1 / 写 1" 一致。
  *   ⚠ 唯一与"几何"沾边的地方：`c3_traffic_full.md` 记 Sigmoid 的头张量是 **3 维 `[1,6400,1]`**
  *   （不是 4 维）⇒ 本单元只按"列流"吃，**秩/形状的解释权在描述符侧的几何解释**（O3 开口项）。
  *
  * ★ 速率/时延画像（★ C3.8/C3.10 **别假定单一速率模型** —— **五个单元各不同**，且**没有任何闸门钉住**）：
  *   · Conv3x3Slice：x_ready 占空 1/11（1 拍收列 + 10 拍阵列，~9%）—— 进 ~9% / 出 ~9%（1 列 / 11 拍）；
  *   · MaxPoolUnit ：x_ready ≡ 1（**100% 吃输入**），输出 1 像素 / 4 拍输入（**25%**），输出与凑齐窗口**同拍**；
  *   · ResizeUnit  ：输入占空 **20%**（2W 收 / 10W 一拍周期）、输出占空 **80%**，输出比输入**晚一个输入行对**（≈2W 拍）；
  *   · AddUnit     ：x_ready ≡ 1（100% 吃）、1 列 / 1 拍（100%）、时延 0 拍（组合）—— **要求两路 operand valid 同拍**；
  *   · SigmoidUnit ：x_ready ≡ 1（100% 吃）、1 列 / 1 拍（100%）、时延 0 拍（组合查表）。
  *   ⇒ **Add 与 Sigmoid 都是 1:1（进出同拍、`x_ready ≡ 1`）**；**差别只在 Add 额外要求两路 operand valid 同拍**。
  *   ⚠ 现有闸门只证**功能值**：不钉时延、也不钉 x_ready 占空、更不钉"表落 ROM 还是 LUT"。
  *
  * ★ 状态大小：**零寄存器 + 一条 256 x 8bit ROM**（`Mem`，无写口）⇒ 面积是"一块 256x8 ROM"，
  *   计入 S5 面积闸门（C3.13）；数据通路本身**零 FF**。
  *   （若综合器把这条异步读 ROM 落成 **LUTRAM/分布式 RAM**，代价 ≈ 256x8 的 LUT 资源；
  *   这是**留给 S5 的开口项**，本任务只证功能。）
  *
  * ★ **仿真覆盖的已知残留风险**（与 rtl_test/BypassTb.v 和 tools/run_bypass_ab.sh 同口径）：
  *   只仿 **C=2**（DUT 端口名不可参数化，`BP_NCI != 2` 时装置 time 0 `$fatal`）；列宽只仿
  *   **W∈{4,6}**（其中 W=4/H=32 那一档 C*W*H 恰好 256 ⇒ **每个码点恰好过一次**；W=6/H=32 是
  *   384 字节、仍覆盖满 256 个码点）。更大 C / 其它 W **未被仿真**。**但码点覆盖是穷举的**：装置的
  *   sigmoid 作业把 **256 个码点全部**喂一遍（装置打印 `LUT-CODES=256`，闸门硬判它 == 256），
  *   负对照（地址取反）也在全码点上比。
  */
object SigmoidUnit {
  /** 表深：256（int8 的全部码点）。 */
  val LUT_DEPTH = 256

  /** **冻结公式**（Scala 侧；与 `tools/bypass_ref.py::sigmoid_lut()` 必须逐项相等）：
    *   `lut[x + 128] = floor(127 * sigmoid(x / 16) + 0.5)`，`x = -128..127`。
    */
  def lutFormula(x: Int): Int =
    Math.floor(127.0 / (1.0 + Math.exp(-(x.toDouble) / 16.0)) + 0.5).toInt

  /** 256 项初值（索引 = 无符号地址 = x + 128；值 ∈ [0,127] ⇒ int8 正数，无需二补数处理）。
    * ⚠ SpinalHDL 会把它们写进 `gen/<网表名>.v_toplevel_lut.bin` 并由生成的
    *   `initial $readmemb(...)` 载回（见文件头 §"表住在哪"）——**不是**硬编码在 Verilog 里的常量。
    */
  def lutInit: Seq[SInt] = (-128 to 127).map(x => S(lutFormula(x), 8 bits))
}

class SigmoidUnit(val C: Int = 8, val WIDTH: Int = 64) extends Component {
  require(C >= 1, "C 至少 1 个通道")
  require(WIDTH >= 1, "WIDTH 至少 1 列")

  val io = new Bundle {
    // ---- 输入像素流：逐列、行主序（列内一次给全 C 个通道）；每个字节 = Q3.4 的 x ----
    val x       = in  Vec (SInt(8 bits), C)
    val x_valid = in  Bool()
    val x_ready = out Bool()
    // ---- 输出像素流：同拍一个输出列；每个字节 = Q0.7 的 sigmoid ----
    val y       = out Vec (SInt(8 bits), C)
    val y_valid = out Bool()
    // ---- 自报：只读常量（不参与数据通路）----
    val imgC    = out UInt(16 bits)
    val imgW    = out UInt(16 bits)
  }
  noIoPrefix()

  io.imgC := U(C, 16 bits)
  io.imgW := U(WIDTH, 16 bits)

  // ================================ 256 项表（ROM：可综合的 Mem + 生成期初值） ================================
  // 只读、无写口；初值 = 上电即表（见文件头 §"表住在哪"）。
  val lut = Mem(SInt(8 bits), SigmoidUnit.LUT_DEPTH).init(SigmoidUnit.lutInit)

  // 查表地址**显式命名**（不是内联表达式）：负对照 B 的靶点要能把它改成"取相反数的地址"
  // （`idx := 0 - idx` ⇒ 读到 `lut[-x + 128]` = `round(127*sigmoid(-x/16))`），见
  // tools/run_bypass_ab.sh 的 mut_make(sigmoid-invert) 与 rtl_test/BypassTb.v 的注释。
  val lutIdx = Vec(UInt(8 bits), C)
  for (ci <- 0 until C) {
    // int8 x ↦ 无符号地址 x + 128：翻转符号位即可（x = -128 ↦ 0，x = 0 ↦ 128，x = 127 ↦ 255）。
    lutIdx(ci) := io.x(ci).asUInt ^ U(0x80, 8 bits)
    io.y(ci)   := lut.readAsync(lutIdx(ci))
  }

  // ================================ 握手 ================================
  // 纯组合查表、零状态 ⇒ **从不反压**（x_ready ≡ 1），输出与输入的**同拍**（无输出寄存器）。
  io.x_ready := True
  io.y_valid := io.x_valid && io.x_ready
}
