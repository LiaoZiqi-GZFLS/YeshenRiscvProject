import spinal.core._

/** =====================================================================================
  * C4a.5a `PartialSumBuf` —— **片上部分和缓冲**（宽层多趟累加的承重件）。
  * =====================================================================================
  *
  * ============================ ★ 冻结数据流（C4a.5 Step 1，逐字；要改走 spec 修订） ============================
  * ```
  * 一个"宽层" = 表里的一组连续 plain 单元（由转换器生成，本任务由 TB 手工给）
  *   第 1 趟：累加器清零（或直接写）；第 k>1 趟：读回部分和 → 加到本轮 acc → 写回
  *   片上部分和缓冲：C_out 行 × 8 B（= 64 B/co-block），RAM 结构（DRM），不得落 FF
  *   注意与 C3 的"输出存储 readAsync 是 LUTRAM"是两回事：这里必须是 block RAM，判据由 dev_map 给
  *   （dev_map 的 DRM 判据属 C4a.5b；本片先把缓冲建出来并保证结构正确）
  * ```
  *
  * ============================ 存储粒度与形状（本文件的中心约定） ============================
  * **一个字 = 一个 co-block 的 C_OUT 行部分和**：`C_OUT` 行 × **`PSW/8` B**（缺省 = 4 B/行、
  * 32 B / co-block）—— 就是上面冻结口径里那句"`C_out` 行 × 8 B"的**收窄落实**（★ §3.7：行宽参数
  * `PSW`，缺省 **32 bit**；64 bit 只是"TILING=false 冻结网表"钉住的档）。行 = **一个输出通道**。
  * **深度 = 一个 co-block 的像素数**：`DEPTH = NCOB * PIXMAX`，字地址 = `cob * PIXMAX + pix`
  *   （`cob` = co-block 下标 0..NCOB-1，`pix` = 该趟内已产出的像素序号 0..PIXMAX-1）。
  *   ★ 为什么按 `cob` 分段而不是全局像素：跨 `co` 趟**各写自己那段 co**（C4a.4 冻结规则），
  *     不同 co-block 的像素部分和**地址不重叠** ⇒ 一个 co-block 的趟跑完后**不需要清缓冲**
  *     （下一个 co-block 的趟 1 读回的是**上电初值 0**）⇒ "第 1 趟清零"完全由**上电初值**承担，
  *     这正是 C4a.5 负对照 B（缓冲初值非 0 ⇒ 必红）能发火的**结构性前提**。
  *
  * ============================ 为什么必须落 block RAM（DRM），而不是 FF / LUTRAM ============================
  * 与 `FusionBuf` **同一套 idiom**（该项目已经吃过教训，见其文件头）：
  *   · **一条 `Mem`**（`Mem(Bits(C_OUT*PSW), DEPTH)`）：地址译码 + **同步读**（`readSync`，输出寄存一拍）
  *     —— 这是块 RAM 的标准形态（"single-port block RAM"）。**逐列移位寄存器 + 组合读**才是 FF 形态
  *     （`LineBuffer` 那样），本模块**故意不照抄**。
  *   · **Pango 工具链忽略 `ram_style`**（`W: Sdm-2008 ... ignore`）⇒ 不可能靠属性把存储"推"进 BRAM：
  *     **映射随结构决定**。所以本文件**不加也不依赖**该属性，结构本身（地址译码 + 同步读 + 无运行期
  *     逐位下标）就是"落 DRM"的**唯一**依据。
  *   · ★ **与 C3 输出存储的对比（任务明写的分歧点）**：`UnitExec.outMem` 用的是 `readAsync`
  *     （**组合读**）⇒ 会落成分布式 RAM / LUTRAM（其文件头已如实记录）。本模块**必须**用 `readSync`
  *     （同步读），否则同样会落 LUTRAM。这条差别是**结构性的**，不是"加点属性"能补的。
  *   · **为什么字是整块 `C_OUT*PSW/8 B` 而不是 4 B 一个口**：一个像素的 8 个 co 部分和**同拍**都要给切片的
  *     `ps_in`（8 个 `PSW` 位入口）⇒ 若把字切成 4 B，一个像素要 **8 次读**（8 个读口，简单 DRM 给不了）。
  *     整块一个字的写法是 **1 写 + 1 读**，正是最简单的块 RAM 形状（与 `FusionBuf` 的"字级 Mem"同理）。
  *
  * ============================ 行宽 64→32 bit（★ §3.7，2026-10-16；原文是"为什么是 8 B 不是 4 B"）============================
  * `MacArray` 的累加器是 int32（单趟），**跨趟**累加是"部分和 + 本轮 acc"。★ 冻结口径原写 8 B（int64），
  * §3.7 把它**收窄到 4 B（32 bit）**并给出**可证界**：`|acc| ≤ max|x|·max|w|·taps ≤ 128·127·576 = 9,363,456 < 2^24`
  * ⇒ 25 bit 有符号就够，32 bit 留 ~2^7 余量（见本文件尾「★★ §3.7」一节）。数值口径**一字未动**：
  * 只是**存储/搬运**的部分和变窄，requant 前的加法与折算逐位同值（界内不丢任何位）。
  * ★ `PSW=64` 这一档仍可达 —— **`TILING=false` 的冻结网表**（`gen/UnitExec*.v`）由 `UnitExec` 显式钉 64。
  *
  * ============================ 初值（`Mem` 无复位；只有上电初值 0） ============================
  * 块 RAM 物理上没有复位端 ⇒ "尚未被写过的槽"读出来必须是 **0**（不是 X、不是旧数据）。
  * 这正是"第 1 趟：累加器清零"的落实（**不落任何 FF，也不占任何清零节拍**）。
  * 闸门负对照 B 就打在 `.init` 这一块上（初值改成非 0 ⇒ 判据必红）。
  *
  * 接口（生产者 = 多趟编排器 `MultiPassUnit`；本模块不自带任何状态机）：
  *   写口 —— `(wr_addr, wr_data, wr_en)`：一趟结束后把"本轮 acc + 读回的部分和"整块写回；
  *   读口 —— `(rd_addr, rd_data)`：**同步读**（第 T 拍给地址，第 T+1 拍出数据）；
  *   自报口 —— `imgC/ncob/pixmax/depth/wordBytes/rowBytes` 常量输出，供装置把"生成参数"钉死
  *             （Y1 的"宽度钉死"教训：`Conv3x3Slice` 的 `grp/imgW` 同因）。
  * ===================================================================================== */
case class PartialSumBuf(val C_OUT: Int = 8, val NCOB: Int = 8, val PIXMAX: Int = 32, val PSW: Int = 32) extends Component {
  require(C_OUT >= 1 && C_OUT <= 64, "C_OUT ∈ [1,64]（8 是硬件切片的通道数；本模块允许更大以便单块覆盖）")
  require(NCOB >= 1, "至少一个 co-block")
  require(PIXMAX >= 1, "至少一个像素"); require(PSW >= 8 && PSW <= 64 && PSW % 8 == 0, "行宽 PSW ∈ [8,64] 且为 8 的倍数（§3.7）")

  /** 行宽（字节）：**每个输出通道一个 `PSW/8` B 的部分和**（★ §3.7：缺省 4 B/32 bit）。 */
  val ROW_BYTES: Int = PSW / 8
  /** 字宽（bit）= C_OUT 行 × PSW bit = 一个 co-block 的 `C_OUT*PSW/8 B`（缺省 C_OUT=8 ⇒ 32 B）。 */
  val WORD_W: Int = C_OUT * PSW
  /** 字数 = co-block 段 × 每段像素数。 */
  val DEPTH: Int = NCOB * PIXMAX
  val aw = (log2Up(DEPTH) max 1)

  val io = new Bundle {
    // ---- 读口：同步读（1 拍延迟），地址 = cob*PIXMAX + pix ----
    val rd_addr = in  UInt (aw bits)
    val rd_data = out Vec (SInt(PSW bits), C_OUT)    // 一个 co-block 的 C_OUT 行部分和（行 = 一个输出通道）
    // ---- 写口：同一时刻只写一个字（= 一个像素的 C_OUT 行）----
    val wr_addr = in  UInt (aw bits)
    val wr_data = in  Vec (SInt(PSW bits), C_OUT)
    val wr_en   = in  Bool()
    // ---- 自报（生成参数钉死；只读常量，不参与数据通路）----
    val imgC      = out UInt (16 bits)   // = C_OUT（行数）
    val ncob      = out UInt (16 bits)   // = NCOB（co-block 段数）
    val pixmax    = out UInt (16 bits)   // = PIXMAX（每段像素数）
    val depth     = out UInt (16 bits)   // = DEPTH（字数）
    val wordBytes = out UInt (16 bits)   // = C_OUT*PSW/8（字宽字节数 = 一个 co-block 的字节数）
    val rowBytes  = out UInt (16 bits)   // = PSW/8（每个输出通道一行的字节数 —— 缺省 4）
  }
  noIoPrefix()

  io.imgC      := U(C_OUT, 16 bits)
  io.ncob      := U(NCOB, 16 bits)
  io.pixmax    := U(PIXMAX, 16 bits)
  io.depth     := U(DEPTH, 16 bits)
  io.wordBytes := U(C_OUT * ROW_BYTES, 16 bits)
  io.rowBytes  := U(ROW_BYTES, 16 bits)

  // ---------------------------------------------------------------- 存储（可寻址 RAM）----
  // 一条 Mem（字 = 一个 co-block 的 C_OUT 行 × PSW/8 B）。**同步读**（块 RAM 的标准形态）。
  // 上电初值 0（`Mem` 无复位）⇒ "第 1 趟累加器清零"由它承担；"尚未写过"的槽读出 0（不是 X）。
  val mem = Mem(Bits(WORD_W bits), DEPTH).init(Seq.fill(DEPTH)(B(0, WORD_W bits)))

  // 打包/拆包用**同一套显式位序**：行 co 落在位 **[co*PSW +: PSW]**（co=0 在最低位）。
  // ★ 不用 `Cat(vec.map(...))`：`Vec.map` 走内部 Seq，实测回来是**倒序**（`FusionBuf` 文件头记过这个坑）。
  val wr_word = Bits(WORD_W bits)
  for (co <- 0 until C_OUT) {
    wr_word(co * PSW + PSW - 1 downto co * PSW) := io.wr_data(co).asBits
  }
  mem.write(io.wr_addr, wr_word, io.wr_en)

  // 同步读出整字，再按**与打包同一套**位序拆回 C_OUT 个 `PSW` 位部分和。
  val rd_word = mem.readSync(io.rd_addr)
  for (co <- 0 until C_OUT) {
    io.rd_data(co) := rd_word(co * PSW + PSW - 1 downto co * PSW).asSInt
  }
}

/** =====================================================================================
  * ★★ §3.7（2026-10-16）：**行宽 64 → 32 bit**（本节的正文在**文件最后一行的后面**追加 ——
  *   理由与 `UnitExec.scala` 文件尾同一套：SpinalHDL 把源码行号编进内部网名（`_zz_*_l####`），
  *   `TILING=false` 的三份冻结网表（`gen/UnitExec.v/_w32/_w640`）要求**逐字节不变** ⇒ 既有行的
  *   行号一个都不能动，新 prose 只能往文件末尾追加。）
  * =====================================================================================
  *
  * 尺寸（本模块，缺省 `C_OUT=8 / NCOB=8 / PIXMAX=1088`）：
  *   · 之前：行宽 64 bit（8 B/行）⇒ `WORD_W = 512 bit`、`DEPTH = 8704` ⇒ 557,056 B ≈ 544 KB；
  *   · 现在：行宽 **32 bit**（4 B/行）⇒ `WORD_W = 256 bit`、`DEPTH` 不变 ⇒ **278,528 B ≈ 272 KB**
  *     （−272 KB / −50%；`dev_map` 的 DRM 读数在 spec §3.7 的判据 ③ 里记账）。
  *
  * 为什么 32 bit 是**可证的**（不是估）：`|acc| ≤ max|x| · max|w| · taps`，`x ∈ [-128,127]`、
  * `w ∈ [-127,127]`（§4.5 对称量化 `z_w ≡ 0`）⇒ `|x·w| ≤ 128×127 = 16,256`；taps 最大 =
  * `(C_in/GROUP)×9 ≤ 64×9 = 576`（dense `C_in=64/GROUP=1`）⇒ `|acc| ≤ 9,363,456 < 2^24`
  * ⇒ **25 bit 有符号就够**，32 bit 留 ~2^7 余量。每个**部分和**都被最终累加值界定（中间量更小）
  * ⇒ 收窄**不动数值口径**。
  *
  * 参数与档位：
  *   · `PSW`（bit，缺省 32）：行宽。`PSW ∈ {24, 32, 64}` 都合法（`{8,16,...,64}` 且 8 的倍数）；
  *   · **`TILING=false` 的冻结网表**由 `UnitExec` 显式传 `PSW=64`（历史档，逐字节冻结）；
  *   · **24 bit 是负对照档**（低于可证界）：`gen/MultiPassUnit_ps24.v` + 最大幅度激励 ⇒ 必红
  *     （闸门 `tools/run_psbound_ab.sh`；本案实测峰值 `|acc| = 9,363,456`）。
  *
  * 自报口随 `PSW` 走：`rowBytes = PSW/8`、`wordBytes = C_OUT*PSW/8`（`depth`/`imgC`/`ncob`/`pixmax` 不变）。
  * ===================================================================================== */
