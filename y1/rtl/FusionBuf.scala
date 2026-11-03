import spinal.core._

/** 行流式融合缓冲 —— 3 行环形窗口，**落可寻址 RAM 结构**（不是 LineBuffer 的逐列移位寄存器）。
  *
  * ============================== 为什么存在 / 为什么必须落 RAM（C3.0 §4 的承重约束） ==============================
  * `y1/reports/c3_fusion_buffer.md` 判定 `fuse_both`（33 对融合）的中间张量**必须行流式**：
  * 最坏单元（Conv_15 -> Conv_16，mid=202）整块 C=64,H=160,W=160 = 1,638,400 B = **356 个 DRM36K**
  * ⇒ 单张仅余 +8.8%，且 C0.2 的常驻模型要 `CHIP_BUFFERS=2` ⇒ `2x356=712 > 空闲 390.5` ⇒ **不能双缓冲**；
  * 而只留一个 **3 行窗口** 只要 `3*64*160 = 30,720 B = 7 块 DRM`，余量 +98.2% ⇒ 行流式可行。
  *
  * 但同一份 3 行窗口若按现有 `y1/rtl/LineBuffer.scala` 的写法（**每列一条竖直移位寄存器 + 组合读**）
  * 会落成 `30,720 x 8 = 245,760 个 FF` > 空闲 `215,004` ⇒ **装不下**。
  * 且已知 **Pango 工具链忽略 `ram_style`**（`W: Sdm-2008: The attribute named ram_style is not legal
  * ... ignore`）⇒ **不可能靠属性**把存储"推"进 BRAM：映射**随结构决定**。
  * 所以本模块的存储**必须**写成**可寻址 RAM**（地址译码 + 读写端口 + **同步读**），才会被推断成
  * `GTP_DRM36K`。（"到底有没有真的落 DRM"由后续 S5 面积闸门**实测**，本任务只证**功能**。）
  * ★ 本文件**故意不照抄** `LineBuffer`：LineBuffer 是"每列一条 2 级竖直移位寄存器 + 组合读 +
  *   `when(col===c)` 列译码写"——那是 **FF 结构**；本模块是**一条 `Mem`**（地址=(行,列)，字=一列的 C 个
  *   通道），结构上与 LineBuffer 完全不同。
  *
  * ============================== 存储粒度：**字级** Mem（不是位级） ==============================
  * 两种"可寻址 RAM"写法：
  *   (a) 位级 `Mem(SInt(8), 3*WIDTH*C)`，地址 `= row*(WIDTH*C) + col*C + ci`。
  *       ★ 致命伤：生产口一次给**一整列 C 个通道**，位级 Mem 一列要拆成 **C 次写**（C 个不同地址）
  *         ⇒ 要么需要 C 个写口（简单 DRM 给不了），要么串成 C 拍（吞吐对不上）；
  *         读侧同理——"某行某列的 C 个通道"要 C 次读才凑得齐，**做不到一拍出一整列**。
  *   (b) 字级 `Mem(Bits(C*8), 3*WIDTH)`（**本模块采用**）：一个字 = 一个 (row,col) 上的 C 个通道。
  *       写口一次写一整列（`wr_data.asBits` 就是一个字）；读口**同步读一次出一整列**（`asTypeOf` 拆回
  *       C 个通道）⇒ **单写口 + 单读口**，正是最简单的块 RAM 形状（"简单双口 / 单口 block RAM"）。
  *       而且**零运行期下标**：整列作为一个字写下去，不需要"一列 C 次、每次按 ci 译码"的**桶形移位器**
  *       （这是本项目 `WeightStore` 咬过的坑：`Vec(Reg)` 的动态写会生成 `1 <<< idx` 的移位器）。
  * ⇒ 选 (b)：结构最简（1 写 1 读）、读写都**一拍一列**、无动态下标、无移位器。
  *
  * ★ 关于 `ram_style`：本模块**不加也不依赖**该属性（PDS 忽略它）。能落 DRM 的根据是**结构**：
  *   一条深度 `3*WIDTH`、带地址译码、**同步读**（`readSync`，输出寄存一拍）的 `Mem` ⇒ 标准
  *   "single-port block RAM"形状（同步读是块 RAM 的标准形态；纯**异步读**的 Mem 拿不到 block 标签、
  *   更容易落成分布式 RAM）。
  *
  * ============================== 环形行指针与坐标约定（本文件的中心约定；TB 与 python 模型逐字沿用） ==============================
  * 物理存储 = **3 个行槽**（0/1/2），`WORDS = 3*WIDTH` 个字，字地址 `= 行槽*WIDTH + 列`。
  * `row_ptr ∈ {0,1,2}` = **下一次写入的行槽**（也就是"当前正在写的行"的槽）。
  *   写：地址 `= row_ptr*WIDTH + wr_col`；**写完一整行**（`wr_col` 到 `WIDTH-1` 且 `wr_row_adv`）
  *   ⇒ `row_ptr := (row_ptr+1) mod 3`。于是逻辑行 `r`（0..H-1）落在物理槽 `r mod 3`。
  * 读：`rd_row ∈ {0,1,2}`，**0 = 最老 / 1 = 中 / 2 = 最新**；"最新" = **最后完成的那一行**。
  *   物理槽：`phys(rd_row) = (row_ptr + rd_row) mod 3`。
  *   mod 3 用"按位加得到 0..4、`>=3` 则减 3"的显式缩减（合法输入下数值只有 0..4，一次比较足够，不进除法器）。
  *
  * ★ 读可见性（**精确不变式** —— 取代旧注释里"任何时刻读出的正好是最后完成的三行"那句**过强**的话）：
  *   设"当前正在写的行"是逻辑行 R（`row_ptr = R mod 3`）。
  *     · R **尚未开始写**（生产口正在**行间空闲**）时，rd_row=0/1/2 正好给出**最后完成的三行**
  *       `R-3, R-2, R-1`（= `phys = (R+rd_row) mod 3`）。
  *     · R **一旦开始写**（`wr_col` 从 0 起），`phys(0) = R mod 3` 就是 **R 正在写的那一格**
  *       ⇒ 该时刻 `rd_row=0` 读到的是**写了一半的 R**（已写列是 R 的数据、未写列还是旧行 R-3 的残留），
  *       **不是 R-3**。
  *     ⇒ 只有 `rd_row=1`（→ R-2）与 `rd_row=2`（→ R-1）在"R 写到一半"时**仍保证读到已整行完成的行**；
  *       `rd_row=0` 只在**行间**（R 未开始写；或 R 已被整行写完、其槽已不是 row_ptr）时才有效。
  *   （为何与 `LineBuffer` 不同：LineBuffer 是逐列移位 + 组合读，每列都能**无条件**看到"最后完成的 3 行"；
  *     RAM 环窗没有这个特权 —— 最老那一格会被当前写行**就地覆盖**。）
  *
  * 复位：`Mem` **没有复位**（块 RAM 物理上没有），只有**上电初值 0**（下面的 `.init`）。所以任何
  *       "尚未被写过的窗口位置"读出来是 **0**（不是 X、不是旧行数据）——这正是闸门负对照 A 要钉的东西，
  *       也证明**环形行指针没有把旧行当新行**。
  *
  * ============================== 消费者契约（C3.8 `UnitExec` / C3.9 融合对**必须**按此对接） ==============================
  * 下面四条是本模块**对外行为**的一部分（不是实现细节）。C3.8/C3.9 不得各自另立一套环窗口径 ——
  * 否则最容易踩的就是第 (3) 条"推进边界差一拍"的 off-by-one。
  *
  * (1) **读延迟 = 1 拍（同步读）**。第 T 拍给上 `(rd_row, rd_col)` 后，**第 T+1 拍**（其后第一个 posedge
  *     之后）`rd_data` 才有效，且对应该 T 拍采样的地址。连续读时每拍推进地址即可流水出数据；
  *     不要期望"同拍组合数据"（这点与 LineBuffer 的**组合** `win` 不同 —— 本模块是 RAM，同步读才是
  *     块 RAM 的标准形态）。
  *
  * (2) **同址"读写同拍"读到旧值**（read-old / 写后不透明）。本站 RTL 里写是 `mem[wr_addr] <= wr_word`、
  *     读是 `mem_spinal_port1 <= mem[rd_addr]`，两条非阻塞赋值在同一 posedge 采样**边沿前**的存储
  *     ⇒ 若某 T 拍 `rd_addr == wr_addr`，则 T+1 拍读出的是该地址**被写之前**的内容。
  *     ★ 但这只是**本站行为的性质，不是可移植契约**：Pango `GTP_DRM36K` 的同步读在"读写同址"时可能是
  *     **写透（write-through）**。故消费侧**必须避免**对"本拍正在写的那一格"发起读（即别用 rd_row=0
  *     去读正在写的 R，见 (3)/(4)），从而根本不依赖这条与器件相关的差异。
  *
  * (3) **指针推进边界（差一拍的坑）**。`wr_row_adv && wr_col==WIDTH-1` 那一拍（正在写完某行 R-1）
  *     `row_ptr` **尚未**翻转 —— 它在该拍末尾的 posedge 才 `+1`。所以**与该推进脉冲同拍**发出的读
  *     看到的是**推进前**（老一行）的窗口：同拍 `rd_row=2` 拿到的是 **R-2**（不是 R-1），
  *     **下一拍**再发 `rd_row=2` 才是 **R-1**（新完成的那行）。消费侧要么把读**推迟一拍**，
  *     要么在采样地址时按"本拍是否在推进"自行补偿。
  *
  * (4) **消费侧如何知道哪些行已完成**。本模块**不另开** `rd_rows_valid` 之类的端口（C3.5 端口已冻结，
  *     C3.8/C3.9 按原端口 `wr_col/wr_data/wr_en/wr_row_adv` 与 `rd_row/rd_col/rd_data` 对接）。
  *     完成度信息由**生产侧自己的节拍**给出：读口与写口通常由**同一单元**驱动（`wr_col/wr_row_adv`
  *     就在它手里）⇒ 它能自己记 `row_ptr` 与"已整行写完到第几行"。**安全用法**：
  *       · `rd_row=1,2` 任何时候都对应**已整行完成**的 R-2 / R-1；
  *       · `rd_row=0` 只在**行间**（生产口未开始写 R）时使用；需要"三行同时有效"的窗口就在行间发起。
  *
  * 接口（本任务冻结，未来的 `Conv3x3Slice` 消费口按此对接）：
  *   生产口 —— 写 (row, col) 一列的 C 个通道；row 由内部 3 行指针轮转，外部只推进 `wr_col`
  *             （`wr_row_adv` 在写完一整行那一拍拉高）；
  *   消费口 —— 读 (rd_row, rd_col) 一列的 C 个通道（row 0=最老），正好喂 3x3 切片的
  *             `x: Vec(SInt(8), C_IN)`（一列 C 个通道 / 拍）；
  *   自报口 —— `imgC/imgW` 常量输出，供装置把"生成参数"钉死（防"生成参数不符"的静默错判，
  *             Y1 的"宽度钉死"教训：`Conv3x3Slice` 的 `grp/imgW` 同因）。
  *
  * 接口（本任务冻结，未来的 `Conv3x3Slice` 消费口按此对接）：
  *   生产口 —— 写 (row, col) 一列的 C 个通道；row 由内部 3 行指针轮转，外部只推进 `wr_col`
  *             （`wr_row_adv` 在写完一整行那一拍拉高）；
  *   消费口 —— 读 (rd_row, rd_col) 一列的 C 个通道（row 0=最老），正好喂 3x3 切片的
  *             `x: Vec(SInt(8), C_IN)`（一列 C 个通道 / 拍）；
  *   自报口 —— `imgC/imgW` 常量输出，供装置把"生成参数"钉死（防"生成参数不符"的静默错判，
  *             Y1 的"宽度钉死"教训：`Conv3x3Slice` 的 `grp/imgW` 同因）。
  *
  * ★★ T-S1（2026-10-13）：**运行期行宽 `rowW`**（additive 口，见 spec §3.1）——
  *   行槽**步长**从展开期常量 `WIDTH` 改成运行期 `rowW`：字地址 = `行槽*rowW + 列`。
  *   **分配仍按 `WIDTH`**（`Mem` 仍是 `3*WIDTH` 个字 = `W_MAX` 口径）⇒ `rowW ≤ WIDTH` 时地址完全在分配内；
  *   `rowW == WIDTH` ⇒ **逐字节同形**（既有闸门零改动）。行末判定也随之为 `wr_col == rowW-1`。
  *   越界（`rowW > WIDTH`）由驱动方（`UnitExec`/`BypassExec` 的 `go` 对账）拦住 —— 本模块是纯数据通路。
  */
case class FusionBuf(val C: Int = 8, val WIDTH: Int = 64) extends Component {
  require(C >= 1, "C 至少 1 个通道")
  require(C <= 512, "C 过大（字宽 C*8 会失控；本任务最坏 C=64）")
  require(WIDTH >= 1, "WIDTH 至少 1 列")

  val cw    = (log2Up(WIDTH) max 1)   // 列地址位宽（WIDTH=1 时也要 1 位，否则 Vec/索引没有位宽）
  val WORDS = 3 * WIDTH               // 物理字数 = 3 行 x WIDTH 列
  val aw    = (log2Up(WORDS) max 2)   // 字地址位宽（WORDS>=3 ⇒ 至少 2 位）

  val io = new Bundle {
    // ---- 生产口：写入 (row, col) 一列的 C 个通道（row 由内部 3 行指针轮转）----
    val wr_col     = in  UInt(cw bits)
    val wr_data    = in  Vec(SInt(8 bits), C)
    val wr_en      = in  Bool()
    val wr_row_adv = in  Bool()               // 写完一整行 ⇒ 行轮转（wr_col 到 WIDTH-1 那一拍拉高）
    /** ★★ T-S1：**运行期行宽**（= 本层行宽；`WIDTH` 是分配上限 `W_MAX`）—— 行槽步长 `rowW`、
      *   行末判定 `wr_col == rowW-1`。`rowW == WIDTH` ⇒ 与旧行为逐字节同形。 */
    val rowW       = in  UInt(16 bits)
    // ---- 消费口：读 (rd_row, rd_col) 一列的 C 个通道；rd_row 0=最老 / 1=中 / 2=最新 ----
    // ★ rd_row 是 2 位，但**合法域只有 0..2**（见文件头"消费者契约"(4)）。值 3 是越界值：
    //   rd_sum = row_ptr + rd_row 会到 5，一次"减 3"后仍落在 0..2（5-3=2 ≤ 2）⇒ 不产生越界地址，
    //   且因 3 mod 3 = 0 而**等价于 rd_row=0**。但它不属于契约，消费侧不要用它（详见下方 rd_sum 注释）。
    val rd_row     = in  UInt(2 bits)
    val rd_col     = in  UInt(cw bits)
    val rd_data    = out Vec(SInt(8 bits), C)
    // ---- 自报（供装置钉死参数，防"生成参数不符"的静默错判）----
    val imgC       = out UInt(16 bits)        // = C
    val imgW       = out UInt(16 bits)        // = WIDTH
  }
  noIoPrefix()

  // 自报：常量输出（综合成一条 wire 赋值，不落任何逻辑）。
  io.imgC := U(C, 16 bits)
  io.imgW := U(WIDTH, 16 bits)

  // ---------------------------------------------------------------- 存储（可寻址 RAM）----
  // 一条 Mem：字 = 一列的 C 个通道（见文件头"存储粒度"）。用**同步读**（块 RAM 的标准形态）。
  // 上电初值 0（Mem 无复位）⇒ "尚未被写过"的槽读出 0。
  val mem = Mem(Bits(C * 8 bits), WORDS).init(Seq.fill(WORDS)(B(0, C * 8 bits)))

  // 列的打包/拆包（读写用**同一套**显式位序，与 Mem 内部扁平化顺序无关，自洽即可）：
  //   ★ 位序**显式**定义并两侧共用：通道 ci 落在位 **[ci*8 +: 8]**（ci=0 在最低 8 位）。
  //   不用 `Cat(vec.map(...))`：SpinalHDL 的 `Vec.map` 走的是内部 Seq，实测回来是**倒序**
  //   （`Cat` 生成的是 `{wr_data_1, wr_data_0}`），配上手写的拆包就**把通道 0/1 对调了**
  //   （本闸门第一版实测 PARTIAL 读到 `c1 c0 c5 c4...` 而期望 `c0 c1 c4 c5...` ⇒ 正是这个坑）。
  //   显式切片两侧共用 ⇒ 位序不可能再漂。
  val wr_word = Bits(C * 8 bits)
  for (ci <- 0 until C) {
    wr_word(ci * 8 + 7 downto ci * 8) := io.wr_data(ci).asBits
  }

  // ---------------------------------------------------------------- 写 ----
  // 环形行指针 = 当前写入的行槽（= 下一次写入的行槽）。
  val row_ptr = Reg(UInt(2 bits)) init (0)

  // ★★ T-S1：行槽**步长** = 运行期 `rowW`（分配仍是 `3*WIDTH` 个字）；`rowW == WIDTH` ⇒ 与旧表达式同值。
  val rowWaw  = io.rowW.resize(aw)                          // 运行期行宽（字地址口径）
  val rowWm1  = (io.rowW - U(1, 16 bits)).resize(cw)        // 运行期行末列号 = `rowW-1`

  // 写地址：row_ptr*rowW + wr_col（整列一个字，无运行期下标）。
  val wr_addr = (row_ptr.resize(aw) * rowWaw + io.wr_col.resize(aw)).resize(aw)
  mem.write(wr_addr, wr_word, io.wr_en)

  // 写完一整行（wr_col 到 rowW-1 且 wr_row_adv）⇒ row_ptr += 1 (mod 3)。
  // 注：本拍的写用的是**旧** row_ptr（Reg 非阻塞），所以"行末那一拍"照旧写在本行槽里。
  when(io.wr_row_adv && io.wr_col === rowWm1) {
    row_ptr := Mux(row_ptr === U(2, 2 bits), U(0, 2 bits), (row_ptr + 1).resize(2))
  }

  // ---------------------------------------------------------------- 读（同步，1 拍延迟）----
  // phys(rd_row) = (row_ptr + rd_row) mod 3（见文件头坐标约定）。
  // ★ 位宽：先把两个操作数各自 resize 到 3 位**再加**。SpinalHDL 的 `a + b` 位宽是 max(位宽)
  //   （不是 a+b），若直接写 `(row_ptr + io.rd_row).resize(3)`，加法会先在 **2 位**里做、
  //   2+2=4 被截成 0（本例实测：生成的 `_zz_rd_sum` 是 `wire [1:0]`）⇒ 环号算错。
  //   两个操作数都 resize 到 3 位后相加，位宽才是 3，mod 3 缩减才成立。
  // 合法域 rd_row∈{0,1,2} 时 rd_sum ∈ 0..4；越界值 rd_row=3 时最多 5，但下面的**单次** `-3` 缩减
  // 对 0..5 都成立（5-3=2 仍 ≤ 2，不会越出 2 位），且 3 mod 3 = 0 ⇒ 与 rd_row=0 同址（越界、非契约）。
  val rd_sum  = row_ptr.resize(3) + io.rd_row.resize(3)                           // 合法输入 0..4
  val rd_phys = Mux(rd_sum >= U(3, 3 bits), (rd_sum - U(3, 3 bits)).resize(2), rd_sum.resize(2))
  // ★★ T-S1：行槽步长 = 运行期 `rowW`（与写口同一表达式）；`rowW == WIDTH` ⇒ 与旧门表逐字节同形。
  val rd_addr = (rd_phys.resize(aw) * rowWaw + io.rd_col.resize(aw)).resize(aw)
  // 同步读出整列一个字，再按**与打包同一套**位序（通道 ci 在位 [ci*8 +: 8]）拆回 C 个 int8 通道。
  val rd_word = mem.readSync(rd_addr)
  for (ci <- 0 until C) {
    io.rd_data(ci) := rd_word((ci * 8 + 7) downto (ci * 8)).asSInt
  }
}
