import spinal.core._

/** 一层 3x3 卷积的**权重存储**：整层权重常驻片上，按 (ky,kx) 选出 64 元权重瓦片。
  *
  * ============================== 为什么必须常驻（硬约束） ==============================
  * 阵列 rtl/MacArray.scala 每个**拍**要吃掉一整块 64 字节的权重瓦片 w(co)(ci)（64 MAC/拍）。
  * 而某一层在某个 (ky,kx) 上的瓦片，对**每一个输出像素都是同一块**（权重与像素无关）。
  * 若每个像素都重新取一遍：100 MHz x 64 B/拍 = 6.4 GB/s 的权重带宽 —— 这个板子（无 DDR 权重
  * 通路、片上无这么大缓存）根本建不出来，等于把"权重复用"这件 CNN 加速的**唯一**便宜事丢掉。
  * 所以正确做法只有一个：整层权重**装载一次、常驻片上**，每个像素只做"选 k -> 出瓦片"的
  * 一次多路选择。本模块就是这件事，也是它存在的全部理由。
  * ====================================================================================
  *
  * 接口（冻结，B4 切片依赖）：
  *   we/waddr/wdin —— 装载口：一次性把整层权重写进来；
  *                    waddr 的布局 = GroupMask.weightAddr(co, ci, ky, kx)
  *                                 = co*PER_GROUP*9 + ciLocal(co,ci)*9 + ky*3 + kx
  *                    （即"未落位压缩权重张量" [co][ci_local][ky][kx] 的展平下标；
  *                      与 tools/mac_ref.py 的展平顺序、与 GroupedMacArray.scala 的注释
  *                      **逐字一致**——这条展平顺序是参考与装置之间的接口，改它等于改硬件接口。）
  *   k             —— 当前卷积核位置，k = ky*3 + kx（0..8）。k > 8 时瓦片全 0（见下）。
  *   tile(co)(ci)  —— 本拍的 64 元瓦片：tile(co)(ci) = W(co, ciLocal(co,ci), ky, kx)（同组），
  *                    否则恒 0（组外置 0 就是分组/深度卷积的**唯一**表达方式，见 GroupMask 的长注释：
  *                    掩输入是错的——x 是 8 个 co 共用的总线，掩它会同时打坏别的组）。
  *
  * ★ 分组掩码**不在这里重新推导**：groupOfOut / groupOfIn / ciLocal / participates / weightAddr
  *   全部来自 rtl/GroupMask.scala（B3 冻结的纯映射规则）。本文件只做"地址 -> 寄存器 -> 多路选择"。
  *   注意 participates 是**展开期常量** ⇒ 综合出来的是常数 0（线与），不是运行期比较器。
  *
  * ★ 为什么是"寄存器 + 多路选择"而不是 Mem（本任务明写的实现口径）：
  *   本规模下一层只要 C_OUT*(C_IN/GROUP)*9 个 int8（C_IN=C_OUT=8、GROUP=1 时 576 个），面积可忽略；
  *   而 Mem 那条路在本项目是**走不通**的：SpinalHDL 给"异步读 Mem"打的 ram_style="distributed"
  *   会被 Pango 工具链整个忽略（`W: Sdm-2008: The attribute named ram_style is not legal ... ignore`），
  *   于是没法把它钉在 LUTRAM 上；而 Mem 换成同步读又会多出一级流水（本接口要求 k 当拍出瓦片），
  *   并且会把 576 B 推断成一块 BRAM（DRM 是本项目闸门的稀缺项）。寄存器数组没有这些不确定性：
  *   它就是 576 个 FF + 一个写译码 + 每个参与 entry 一个 9 选 1。
  *
  * 时序：tile 是**组合**输出（与 LineBuffer 的 win 同口径）：k 一变，瓦片当拍跟着变，无输出寄存、
  *       无流水延迟。（装载口是同步写，clk 上升沿生效。）
  */
case class WeightStore(C_IN: Int, C_OUT: Int, GROUP: Int, DW: Boolean = false, DCI: Boolean = false) extends Component {
  require(C_IN >= 1 && C_OUT >= 1, "通道数至少 1")
  require(C_IN % GROUP == 0 && C_OUT % GROUP == 0, "通道数必须能被 group 整除（GroupMask 里还会再校一遍）")

  /** 组映射与权重落位规则（纯函数，常量折叠；不重新推导，直接用 B3 冻结的那一套）。 */
  val mask = GroupMask(C_IN, C_OUT, GROUP)
  /** 每组拥有的输入通道数 = 每个 co 的组内权重个数。 */
  val PER_GROUP: Int = mask.PER_GROUP
  /** 整层权重的条目数 = 压缩张量 [co][ci_local][ky][kx] 的大小。 */
  val NENTRY: Int = C_OUT * PER_GROUP * 9

  val io = new Bundle {
    // 装载口：一次性把整层权重写进来（waddr 布局见类注释 / GroupMask.weightAddr）。
    val we    = in  Bool()
    val waddr = in  UInt (log2Up(NENTRY) bits)
    val wdin  = in  SInt(8 bits)
    // 选择当前卷积核位置 (ky,kx)，k = ky*3 + kx（0..8）。
    val k     = in  UInt (4 bits)
    // 输出：64 元瓦片 w(co)(ci)；组外 (co,ci) 恒 0。
    val tile  = out Vec (Vec(SInt(8 bits), C_IN), C_OUT)
  }
  noIoPrefix()

  // ---- 整层常驻：NENTRY 个 int8 寄存器（装载一次，逐像素复用；见类开头的带宽论证）----
  val mem = Vec(Reg(SInt(8 bits)) init (0), NENTRY)
  // 写：**显式的静态下标译码**（waddr == i），不用 Vec 的动态写。
  // 为什么不用 mem(io.waddr) := ...：SpinalHDL 对 Vec(Reg) 的动态写会生成一条
  // `1 <<< waddr` 的 1024 位桶形移位器（=10 级 x 1024 个 2:1）来当译码器，
  // 面积上比一棵"等值比较"译码树差得多；下一任务的面积闸门（LUT <= 30000）对这点很敏感。
  // 这里的写法生成的就是 576 条 `if(waddr == 10'hXXX) mem_N <= wdin;`，谁都能读、工具也好映射。
  val aw = io.waddr.getBitsWidth
  when(io.we) {
    for (i <- 0 until NENTRY) {
      when(io.waddr === U(i, aw bits)) {
        mem(i) := io.wdin
      }
    }
  }

  // ---- 按 (ky,kx) 选瓦片：每个 (co,ci) 一个 9 选 1，组外直接是常数 0 ----
  for (co <- 0 until C_OUT) {
    for (ci <- 0 until C_IN) {
      // ciLocal 只跟 ci 有关（组内序号），它是**展开期常量** ⇒ 下面全是静态下标。
      val base = co * PER_GROUP * 9 + mask.ciLocal(co, ci) * 9
      // 该 (co,ci) 在 9 个核位置上的 9 个权重寄存器。
      val plane = (0 until 9).map(kk => mem(base + kk))
      // 9 选 1：k 越界（9..15）落到 0 —— 显式给一个确定值，不留未定义。
      var sel: SInt = S(0, 8 bits)
      for (kk <- 8 to 0 by -1) {
        sel = Mux(io.k === kk, plane(kk), sel)
      }
      // participates(co,ci) 是常数 ⇒ 组外的这一支被常量折叠成 8'h0（不是运行期比较器）。
      io.tile(co)(ci) := Mux(mask.participates(co, ci), sel, S(0, 8 bits))
    }
  }

  // ==========================================================================================
  // ★★ NPU v2 切片 B1（2026-10-16）：**dw 静态对角读口**（additive；只有 `DW=true` 时存在）
  // ==========================================================================================
  // 独立探针 `rtl_test/DwLaneProbe.scala` 的 `DwLaneWeightStore` 逐字同构；报告 §Slice B-1 §B1-1 钉死：
  //   `dwTile(r)(j) = mem[r*PER_GROUP*9 + r*9 + j]`（= 对角 entry `(r,r)` 的第 `j` 个抽头
  //   = "通道 r 的第 j 个抽头"的权重）。**静态下标 ⇒ 零多路选择器**（纯寄存器直连）。
  // ★ 前提（实测，报告 §B1-1）：宽通路的装载器对 dw 的趟瓦片做**跨组零填**（`UnitExec` §B1c：
  //   对角趟上只有 `cl==cil` 非 0）⇒ 这一口**不需要**改 blob / 装载器 / 描述符。
  //   8 条 lane 吃抽头 0..7（`dwTile`）、第 9 抽头吃 `dwTile8`（AFTER1 的那一行乘法器）。
  // ★ 为什么必须在**本模块**加口（而不是从外面"读它的寄存器"）：SpinalHDL 的分层检查禁止父组件
  //   读子组件内部信号（探针文件头的第一次编译就被这条拦下）⇒ 生产 RTL 里这条改动也必须是新读口。
  // ★ 行数中性纪律：本节追加在类体最后一条语句之后（上面的写译码 `when_WeightStore_l74*` 的**行号
  //   一根不能动** —— `TILING=false` 的三份冻结网表逐字节不变）；`DW=false`（缺省）⇒ 零端口、零线。
  // ==========================================================================================
  require(!DW || (C_IN == 8 && C_OUT == 8 && GROUP == 1), "dw 对角读口只对 GROUP=1 的 8x8 切片定义")
  /** dw 对角读口（8 lane × 8 抽头；`dwTile(r)(j)` = 通道 r 的抽头 j）。 */
  val dwTile: Vec[Vec[SInt]] = if (DW) { val v = out Vec (Vec(SInt(8 bits), C_IN), C_OUT); v.setName("dwTile"); v } else null
  /** ★ 第 9 抽头（AFTER1）：`dwTile8(r)` = 通道 r 的抽头 8。 */
  val dwTile8: Vec[SInt] = if (DW) { val v = out Vec (SInt(8 bits), C_OUT); v.setName("dwTile8"); v } else null
  if (DW) {
    for (r <- 0 until C_OUT) {
      for (j <- 0 until C_IN) { dwTile(r)(j) := mem(r * PER_GROUP * 9 + mask.ciLocal(r, r) * 9 + j) }
      dwTile8(r) := mem(r * PER_GROUP * 9 + mask.ciLocal(r, r) * 9 + C_IN)   // 第 9 抽头 = 抽头 8
    }
  }

  // ==========================================================================================
  // ★★ NPU v2 切片 C2（2026-10-16）：**c3 ci-inner 运行期读口**（additive；只有 `DCI=true` 时存在）
  // ==========================================================================================
  // 独立探针 `rtl_test/CiPackProbe.scala` 的 `CiPackWeightStore(DCI=true)` 逐字同构；
  // 报告 §Slice C-1 §C1-3 钉死的接口（C2 实现片按此落地，不改设计）：
  //   `c3Tile(r)(j) = mem[r*PER_GROUP*9 + c3_ci*9 + j]`（= 输出通道 r、**ci 拍号** `c3_ci`（运行期
  //   0..3）、抽头 j 的权重）+ `c3Tile8(r) = mem[r*PER_GROUP*9 + c3_ci*9 + 8]`（第 9 抽头）。
  // ★ 前提（与 B1 的 dw 对角口同一论证，C-1 逐行复原）：宽通路装载器把 `(co,ci)` 瓦片按
  //   `ci = ciLocal` 落位、`cil ∈ [C_in,8)` **零填**（`UnitExec` 的零填充相位）⇒ 这一口读的是
  //   576 B 对角瓦片**内部** ⇒ **blob / 装载器 / 描述符 / arena 零改动**。
  // ★ `DCI ⇒ DW`：`c3_ci` 的 4:1 读与 dw 的对角口同处一条"逐 lane"通路（切片侧复用 `x_dw/w_dw/
  //   x8/w8` 四个口），本代两口同生同灭。
  // ★ 行数中性纪律：本节追加在类体最后一条语句之后（上面的写译码/9 选 1/dw 段的**行号一根不动**
  //   —— `TILING=false` 的三份冻结网表逐字节不变）；`DCI=false`（缺省 = 既有全部展开）⇒ 零端口、零线。
  // ==========================================================================================
  require(!DCI || (DW && C_IN == 8 && C_OUT == 8 && GROUP == 1), "c3 ci-inner 读口只对 GROUP=1 的 8x8 dw 档切片定义")
  /** ci 拍号（运行期 0..3；`C_in ≤ 4` 是本片钉死的口径，真表只需 {3,1}）。 */
  val c3_ci: UInt = if (DCI) { val v = in UInt (2 bits); v.setName("c3_ci"); v } else null
  /** c3 逐 lane 读口（8 lane × 8 抽头；`c3Tile(r)(j)` = 通道 r 在 ci 拍号下的抽头 j）。 */
  val c3Tile: Vec[Vec[SInt]] = if (DCI) { val v = out Vec (Vec(SInt(8 bits), C_IN), C_OUT); v.setName("c3Tile"); v } else null
  /** ★ 第 9 抽头：`c3Tile8(r)` = 通道 r 在 ci 拍号下的抽头 8。 */
  val c3Tile8: Vec[SInt] = if (DCI) { val v = out Vec (SInt(8 bits), C_OUT); v.setName("c3Tile8"); v } else null
  if (DCI) {
    for (r <- 0 until C_OUT) {
      for (j <- 0 until C_IN) {
        /** 4:1 读（`c3_ci` 运行期 0..3；展开成 3 条 `Mux` 比较 —— 与探针同一形状，
          *   选择子是**寄存器直连的静态下标条目**，不落动态索引的桶形选择器）。 */
        c3Tile(r)(j) := (1 to 3).foldLeft(mem(r * PER_GROUP * 9 + mask.ciLocal(r, 0) * 9 + j)) { (acc, c) =>
          Mux(c3_ci === U(c, 2 bits), mem(r * PER_GROUP * 9 + mask.ciLocal(r, c) * 9 + j), acc)
        }
      }
      c3Tile8(r) := (1 to 3).foldLeft(mem(r * PER_GROUP * 9 + mask.ciLocal(r, 0) * 9 + C_IN)) { (acc, c) =>
        Mux(c3_ci === U(c, 2 bits), mem(r * PER_GROUP * 9 + mask.ciLocal(r, c) * 9 + C_IN), acc)
      }
    }
  }
}

/* =====================================================================================
  * ★★ 切片 C2（2026-10-16）：`DCI` 参数（c3 ci-inner 运行期读口）—— 设计出处与纪律
  * =====================================================================================
  *
  * 出处：spec §4.6b-②（切片 C-1 钉死的接口）/ `reports/npu_v2_accounting.md` §Slice C-1 §C1-3；
  * 参考实现：`rtl_test/CiPackProbe.scala` 的 `CiPackWeightStore(DCI=true)`（独立探针，已实测
  * ΔLUT +920 / ΔFF 0 / ΔDRM 0 / ΔAPM −4）。本文件只是把那条钉死的读口落进产品 RTL：
  *   · `DCI=false`（缺省 = `WeightStoreGen` / `SliceGen` / 窄通路 / `TILING=false` 的三份冻结
  *     网表 / `MultiPassUnit.v`（`DW=false`））⇒ **零端口、零线**、类体既有语句行号一根不动
  *     （写译码 `when_WeightStore_l74*` 的网表名依赖行号 ⇒ 新增段**只能在类体最后一条语句之后**）；
  *   · `DCI=true`（只由 `MultiPassUnit(DW=true, DCI=true)` = `UnitExec(TILING=true)` 的宽路切片下发）
  *     ⇒ 一个新入端口 `c3_ci`（2 bit）+ 两组组合读出（`c3Tile`/`c3Tile8`），全在 576 个既有
  *     寄存器内部（**blob / 装载器 / 描述符 / arena 零改动**）。
  * ===================================================================================== */
