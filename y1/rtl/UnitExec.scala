import spinal.core._
import spinal.lib._
import spinal.lib.bus.amba4.axi._

/** 主相位 FSM 的状态（生成 Verilog 里就是一个 `UnitExecPhase` 型寄存器）。 */
object UnitExecPhase extends SpinalEnum {
  val IDLE, RDSTART, RDRUN, WRWAIT, WRSTART, WRRUN, DONE = newElement()
  /** ★ C4a.5b：**宽层多趟**通路（`C_in>8 || C_out>8`）—— 不走 DDR 读，由 `wide_x` 列流喂、本单元驱动 `MultiPassUnit`. */
  val WIDERUN = newElement()
  /** ★ C4b-B1：**权重段从 DDR 批量装载**（DMA 主路径）—— 举一笔 RD（`WGTLD`）、把段内字节逐拍灌进各切片
    * 的 `WeightStore`（`WGTRUN`）。两态都在**激活相位之前**（见文件头「C4b-B1」一节）。 */
  val WGTLD, WGTRUN = newElement()
}

/** 消费侧（`FusionBuf` -> `Conv3x3Slice` 的列进料）子状态机。 */
object UnitExecCons extends SpinalEnum {
  val WAIT, ADDR, PRES, CDONE = newElement()
}

/** =====================================================================================
  * C3.8 `UnitExec` —— 走表把**一个单元**跑完的第一条端到端通路（S2：不融合的 3x3 dense conv）
  * =====================================================================================
  *
  * `SRC_ADDR` 的激活 -> 片上 3 行窗口 -> `Conv3x3Slice` -> `DST_ADDR`。三块现成部件**一个字都没改**：
  *   · `rtl/DdrMaster.scala`  —— RD 模式把 DDR 读成 8 B/拍的流；WR 模式把 8 B/拍的流写回 DDR。
  *                               **本单元只实例化一个 DdrMaster**，先用 `mode=RD` 读激活、再用
  *                               `mode=WR` 写结果（两次 `start` 串行；同一 AXI 口复用）。
  *   · `rtl/FusionBuf.scala`  —— 本单元的**输入 3 行窗口**（字 = 一列 C 个通道）。
  *   · `rtl/Conv3x3Slice.scala` —— 从窗口按列吃、一拍出一个像素的 C_OUT 个通道。
  *
  * ================================ 数据流（本任务冻结；S3/S4 在这之上加分支） ================================
  *   1. `DdrMaster(mode=RD, src=d.srcA, len=d.w6)` 逐块读激活；RD 流的每一拍 = 8 B **正好 = 一个像素的
  *      C 个通道**（本单元 `C = 8 = DATA_W/8`，见下面 require）⇒ 一边从 `rd_valid/rd_ready` 收拍、
  *      一边把它当**一列**写进 `FusionBuf`（`wr_col` 0..WIDTH-1、`wr_row_adv` 在行末那拍）；
  *   2. 读满 `IMG_H` 行之后，**驱动方再补一行全 0 的 pad 行**写进 `FusionBuf` —— 这就是 `Conv3x3Slice`
  *      文件头里那条"下边零填充由驱动方多喂一行"的**流约定**在 `FusionBuf` 上的落实（`Conv3x3Slice`
  *      接口里**没有 H**、`FusionBuf` 里也没有 ⇒ 只能由本单元造）。于是窗口里共 `IMG_H+1` 行；
  *   3. `Conv3x3Slice` 从 `FusionBuf` 按列读（`x(ci) = fb.rd_data(ci)`，`x_valid` 由"该行已写完"门控），
  *      一拍收一列；它自带 `LineBuffer` + 列延迟线，**自己按 WIDTH 数行**（所以本单元喂满 `IMG_H+1` 行、
  *      第 0 行是预滚、第 `IMG_H` 行是 pad 行 ⇒ 出 `IMG_H` 行输出像素）；
  *   4. `y_valid` 时把 `y`（C_OUT 个通道）按产出序号写进一个**片上输出存储**，整张出齐后再按一拍 8 B
  *      喂 `DdrMaster(mode=WR, dst=d.dstA)`。**S2 的判据是数值**（`MISMATCH=0`），不是性能；所以这一档
  *      允许"整行行锁步"（生产侧写一行、消费侧把这一行读完、再写下一行）+ "整张输出先落片上再流出去" ——
  *      两者都见下"窗口读时序"与"输出侧"。
  *
  * ================================ DDR 张量布局（本任务冻结；由 TB/参考逐字节对账） ================================
  *   ★ **激活与输出都是 NHWC（channel-last）= `[y][x][c]`**。
  *   为什么必须这样：`DdrMaster` 的 RD/WR 流一拍就是 **8 B**，而本单元 `C = 8` ⇒ 一拍正好是一个
  *   像素的全部通道。要让"一拍一列"直接落进 `FusionBuf`（其字 = 一列 C 个通道）／直接从输出存储
  *   喂 `wr_data`（其小端口径也是"字节 j = 通道 j"），DDR 上单个像素的 C 个通道**必须连续**。
  *   若用通道主序 `[c][y][x]`，一个像素的 8 个通道相隔 `H*W` 字节，RD 的连续字节流凑不出一列
  *   ⇒ 那需要一个转置引擎，**本任务（S2）不做**。所以 `y1/tools/conv_unit_ref.py` 把 `mac_ref` 的
  *   `[c][y][x]` 张量**纯置换**成 NHWC 再落盘（同一套 mac_ref 算术，只换布局）。
  *   字节口径：RD 拍 `rd_data[8j+7:8j]` = 块缓冲第 j 字节 = **较低地址**那个字节；通道 ci 落
  *   `rd_data[8*ci+7 : 8*ci]`（ci=0 在最低 8 位），与 `FusionBuf` 的打包位序（ci 落 `[ci*8 +: 8]`）
  *   **同一套**。输出侧同理：`y(co)` 落输出字的 `[co*8 +: 8]`，`wr_data` 小端直接吃。
  *
  * ================================ 权重：**带外预载**（本任务明确记录的口径缺口） ================================
  *   描述符里**没有权重指针**（`DescWords` 只有 `srcA/dstA/inBytes/...`，见 `reports/c3_descriptor_format.md`
  *   §O1 与 `reports/c3_bypass.md` §5）⇒ 本单元**不解释任何权重地址**：`we/waddr/wdin` 是**直通**口，
  *   由 TB/主机在 `go` 之前**带外预载**整层权重（`Conv3x3Slice` 把它转进常驻的 `WeightStore`）。
  *   本单元**不做**"权重从 DDR 搬运"（那是 C4/M2 的转换器项：描述符格式要么补字段、要么约定）。
  *   `wgt_base` 这一路入参**保留但不参与寻址**（S2 恒 0；见 §O1）。权重布局 = `GroupMask.weightAddr`
  *   = `[co][ci_local][ky][kx]`，条目数 `NENTRY = C_OUT*(C_IN/GROUP)*9`（dense/GROUP=1 时 576）。
  *
  * ================================ 窗口读时序：**行锁步** + `FusionBuf` 消费者契约 ================================
  *   `FusionBuf` 的消费者契约（其文件头）有四条：读延迟 1 拍、同址读写同拍读旧值、**推进边界差一拍**、
  *   `rd_row=0` 只在**行间**有效。本单元**不碰这三条边界的任何一条**，用的是**行锁步**：
  *     · 生产侧写**整一行**（`wr_col` 0..WIDTH-1，行末拉 `wr_row_adv`），然后**停住**；
  *     · 消费侧把这一行读完（WIDTH 列），再放行生产侧写下一行；
  *   ⇒ 任何时刻最多只有**一行在飞**：消费侧读第 L 行时，生产侧**尚未**开始写第 L+1 行。
  *   于是读永远发生在**两个"行推进"之间**，且读的物理槽（`rd_row=2` -> 最后完成的那一行）与
  *   生产侧**不同址**（生产侧此刻不写任何东西）⇒ 契约 (2) 的"同址读旧值/写透"根本不会被触发。
  *   ★ 为什么 `rd_row` 恒取 **2**：`FusionBuf` 的 `phys(rd_row)=(row_ptr+rd_row) mod 3`，而
  *     `row_ptr` = **下一次写入的行槽**。行锁步下"生产侧刚写完第 L 行"时 `row_ptr=(L+1) mod 3`
  *     ⇒ `rd_row=2` 给出 `phys=(L+1+2) mod 3 = L mod 3` = **第 L 行**（它正是刚写完、且是"最新"的那行）。
  *     （`rd_row=0` 会落到 `(L+1) mod 3` = 第 L-2 行；`rd_row=1` 落到第 L-1 行。三者都能用，但
  *      只有 `rd_row=2` 与"最新完成的行"同义 ⇒ 与生产侧的行号一一对应，最不容易错位。）
  *   ★ 为什么是"行锁步"而不是"让 Ring 自己流动"：本用例 `IMG_H = 4 > ROWS_LIVE = 3`，整张图**塞不进**
  *     3 行环窗；而行锁步让"在飞的永远只有一行"，完全绕开"环窗被当前写行就地覆盖"这唯一的坑。
  *     代价是吞吐（生产侧要等消费侧）—— **S2 的判据是数值不是性能**，这个代价是明写的、可接受的。
  *   ★ 消费侧的读延迟（契约 (1)，同步读 1 拍）在下面 `ADDR -> PRES` 那两拍起伏里落实：`ccol` 是 Reg、
  *     在整个 `ADDR/PRES` 期间不变 ⇒ 地址稳定固定，`fb.rd_data` 在进入 `PRES` 之前一个时钟沿就已
  *     锁存好；`PRES` 里 `x_valid` 一直举到被 `x_ready` 吃掉（`x_ready` 占空 1/11，见速率画像）。
  *
  * ================================ 输出侧：**整个输出先落片上，再一次性流出去** ================================
  *   本单元只有**一个** `DdrMaster`（= 一个 AXI 主口，与 `NpuTop` 的接线一致）⇒ **RD 相位与 WR 相位
  *   在时间上必须串行**（同一个主口不能同时读和写）。而 `Conv3x3Slice` 在 RD/消费相位里就把整张输出
  *   算完了 —— 所以输出必须先**整张**落在片上，WR 相位才有东西可发。
  *   · 为什么不是"`FusionBuf` 的第二块 `Mem`"：`FusionBuf` 的形状是 **3 行环窗**（`3*WIDTH` 个字），
  *     而本用例的输出是 `IMG_H*IMG_W = 4*64 = 256` 个字 > `3*WIDTH = 192` —— **装不下**（3 行环窗
  *     对"整张输出"这个用途太小）。所以本单元用一个**专用输出存储** `outMem`（`Mem(Bits(C*8), MAXPIX)`，
  *     `MAXPIX` 是展开期上限，TB 断言 `IMG_H*IMG_W <= MAXPIX`）：`y_valid` 时按**产出序号** `pixIdx`
  *     写一字（一字 = 一个像素的 C 个通道，位序同 `wr_data` 小端），WR 相位再按**读序号** `ri` 顺序
  *     读出（异步读，一拍一字）。
  *   · 这是 S2 明写的简化（**判据是数值不是性能**）：真实设计应让输出边产边流（要求主口 RD/WR 交叠，
  *     或双缓冲），这是 C3.9/C3.13 的事。本任务只证"数值对不对"。
  *   · 输出**顺序**天然是 `Conv3x3Slice` 的出料顺序 = `[y][x]` 行主序；一拍一个像素 ⇒ WR 流就是
  *     NHWC 的 `[y][x][co]`（与输入同一套布局）。
  *
  * ================================ 尺寸约束（TB 会断言） ================================
  *   · `C = 8`（= `DdrMaster.DATA_W/8`）：这是"一拍一列"成立的前提（否则一列要拆几拍）。
  *   · `d.w6 % 128 == 0`：S2/S3/S4 的几何都取整块（`DdrMaster` 的 32 B 通用粒度路径由 C3.3 提供，
  *     本任务先走全块以减少混淆）。TB 在 time 0 对 `+D6=` 断言。
  *   · 描述符的 `IMG_W` **必须** == 生成本网表时的 `WIDTH`（`FusionBuf`/`Conv3x3Slice` 都按展开期
  *     常量数行/寻址）。本单元**不**用运行期 `IMG_W` 去数行（那样宽度不符会**静默**错位）；它把
  *     网表的 `imgW` **自报**出去，让 TB 在 time 0 与描述符对账（"宽度钉死"教训：
  *     `Conv3x3Slice` 的 `imgW`/`grp` 就是为这件事暴露的）。
  *
  * ================================ `QUANT_SHIFT` 契约（★ 响亮失败，不是静默错值） ================================
  *   本单元的 requant 右移是 `Conv3x3Slice` 的**展开期常量** `SHIFT`（档位常量），**不是**运行期量；
  *   描述符的 `w7[7:0] = QUANT_SHIFT` 在本档**结构上是死的** —— 若只把它当"占位字段"读掉不用，
  *   一张写着 `QUANT_SHIFT≠6` 的表就会拿到**按 >>6 算出来的数**（静默错值：数值大范围偏、但长度、
  *   地址、突发全对）。所以本单元在 `go` 那一刻**对账**：`dw.qShift =/= U(SHIFT,8)` ⇒ 走**响亮 `err`**
  *   且**零搬运**（与"入参非法"同一条路径的形状：一个 AR/AW 都不发）。
  *   ★ 口径（写给 C4/M2）：**在"按层运行期 requant"出现之前，描述符的 `QUANT_SHIFT` 必须等于本网表
  *     被展开时用的 `SHIFT`**；两者是同一个自由度的两个副本，本单元只接受"副本一致"的表。
  *     真正的按层 requant（`SHIFT` 变成运行期端口）是 C4/M2 的量化器项——那时这条对账才该拆掉。
  *   ★ 负对照的分工（闸门里两条都要有，不能只留一条）：
  *     · 描述符侧 `+D7=5`（表不对）⇒ **err + 零搬运**（本对账抓，抓的是"表与网表不符"）；
  *     · 网表侧 `(arr_p_i >>> 3'd6) -> 3'd5`（表对、网表被改）⇒ 自报口仍是常量 6 ⇒ 只能由**数值**抓
  *       (`MISMATCH>0`)。两者抓的是**不同**的东西，缺哪个都会留一条静默通路。
  *
  * ================================ 输出存储的尺寸与初值 ================================
  *   `outMem = Mem(Bits(C*8), MAXPIX)`，`MAXPIX = WIDTH * IMG_H_MAX`（**由生成本网表的几何推出**，
  *   `IMG_H_MAX` 是本任务定点用例的 `H`，见类参数；16 位运行时 `IMG_H` 由 TB 在 time 0 断言
  *   `IMG_H*IMG_W <= maxPix`）。旧版把 `MAXPIX` 写成常量 1024 = 几何的 4 倍 ⇒ 白占 4 倍存储，
  *   所以现在**钉在几何上**并把 `maxPix` 自报出去（与 `imgW`/`imgC`/`grp` 同一套"钉死"纪律）。
  *   `outMem` 另有**上电初值 0**（`Mem` 物理上没有复位；不给初值的话"没写过就读"是 **X**，
  *   一旦某条流水线路径被跳过，WR 相位就会把 X 写回 DDR —— 那是**不可诊断**的坏）。
  *   ★ 面积诚实记录（S5/C3.13 项）：Pango **忽略 `ram_style`**（映射由结构决定），而 `readAsync`
  *     是**组合读** ⇒ 这个输出存储会被落成**分布式 RAM / LUTRAM**（不是 `GTP_DRM36K`）。真要大图时
  *     应当改成 `readSync` + **预取一拍**（把读出打成流水），或者更根本地——**输出边产边流**（RD/WR
  *     交叠或双缓冲），那时这个"整张输出先落片上"的存储整个消失。本任务（S2）只要数值，故留原样 + 记录。
  *
  * ================================ ★ C3.9a 头分支（融合对的头：输出进片上中间缓冲，不落 DDR） ================================
  *   本切片只做**头**这一半：`FLAGS.bit0 == OUT_TO_DDR == 0` ⇒ 本单元是融合对的**头**，卷积输出**不落 DDR**，
  *   而是按"一拍一个输出像素 = 一列（C 个通道）"写进**第二个 `FusionBuf`**（`fbMid`，与输入窗 `fb` **不同的实例**）。
  *   于是**融合对的中间张量落在片上**（行流式 3 行环窗），下一单元（尾，`IN_FROM_PREV`）从它的消费口取。
  *   ★ 本切片**只做头**：尾/消费侧与融合对是**下一片**（C3.9b），本文件此刻**不**从 `fbMid` 消费去算任何东西。
  *
  *   数据流（头，`bit0==0`）：
  *     RD 相位照旧（`DdrMaster(mode=RD)` -> `fb` 输入窗 -> `Conv3x3Slice`），但**没有 WR 相位**：
  *     `Conv3x3Slice.y/y_valid`（= 输出流，一拍一个输出像素、顺序 [y][x] 行主序）驱动 `fbMid` 的**生产口**：
  *       · `wr_data = y`（C_OUT = C 个通道，一拍写一列）；`wr_en = y_valid && isHead`；
  *       · `wr_col = ocol`（输出行内列 0..WIDTH-1，随每次 `y_valid` 推进）；
  *       · `wr_row_adv = y_valid && isHead && (ocol == WIDTH-1)`（**每个输出行末一拍**推进行指针）。
  *     ⇒ 输出 `IMG_H` 行写进 `fbMid` 后，`midRows == IMG_H`（自报口）。
  *
  *   ★ **结构性无 DDR 写**（不是 TB 的约定）：头模式下 `WRSTART`/`WRRUN` 两态**进不去**
  *     （`WRWAIT` 里 `when(isHead){ DONE } otherwise { WRSTART }`）⇒ `ddrMaster.io.start` 在本次运行里**只会**
  *     以 `mode=RD` 发一次，`wr_valid`（=`state===WRRUN && ...`）恒 0 ⇒ 一个 AW/W 都不发。
  *     所以 `wr_bytes == 0`、`AW_BURSTS == 0` 是**数据通路**的结果，不是闸门的口径。
  *     （同理 `outMem` 的写使能带上 `!isHead` ⇒ 头模式下连**片上输出存储**都不落，输出"改道"进 `fbMid`。）
  *   ★ **S2（`bit0==1`）逐字节不变**：`isHead` 为假时 `fbMid.wr_en` 恒 0（中间缓冲**未动**、全为初值 0）、
  *     `outMem.write` 的使能退化成 `y_valid`（与旧版**同一件事**）、`WRWAIT` 走 `otherwise` 分支（= 旧版）
  *     ⇒ `run_unitexec_ab.sh` 的 S2 数值对账一字不变。
  *   ★ **观察口（仅观察，不参与数据通路）**：`io.mid_rd_row/io.mid_rd_col`（输入）与 `io.mid_rd_data`（输出）
  *     直连 `fbMid` 的消费口（同步读、1 拍延迟，见 `FusionBuf` 消费者契约），供 TB 把中间张量**读回**逐字节对账；
  *     `io.head_mode`（本次运行的头判定）与 `io.mid_rows`（已推进行指针次数）是给 TB/闸门的**自报**，只观察、不被本单元消费。
  *   ★ **3 行环窗的读回口径**：`fbMid` 是 `FusionBuf`（3 行环窗、`3*WIDTH` 字），本用例 `IMG_H=4 > 3`
  *     ⇒ 写完 4 行后环里只剩**最后 3 行**（逻辑行由 `row_ptr = IMG_H mod 3` 起、按 `rd_row` 轮转；闸门按此口径算 golden）。
  *     这不是缺陷：融合对的中间张量本就是"行流式窗口"，尾单元边跑边取；本切片只证"头把输出流**正确写进**了它"。
  *
  * ================================ ★ C3.9b 尾分支 + 融合对（1x1 -> 3x3，S3） ================================
  *   本切片把 C3.9a 的**头**补上另一半：**尾**（`FLAGS.bit1 == IN_FROM_PREV == 1`）与**融合对**。
  *
  *   ---- 一个 `go` 里的三个档（由描述符 `FLAGS` 的两位组合决定；`head = bit0==0`、`tail = bit1==1`）----
  *     · `bit0=1, bit1=0`（S2，不融合）      ：`conv` 读 DDR(`srcA`)、写 `outMem` -> DDR(`dstA`)；一个 WR 相位。
  *                                            **逐字节不变**（见下"S2/头档不变"）。
  *     · `bit0=0, bit1=0`（C3.9a 头，单飞）  ：`conv` 读 DDR(`srcA`)、写 `fbMid`；**无 WR 相位**。逐字节不变。
  *     · `bit0=0, bit1=1`（★ 融合对，本片）  ：**一个 `go` 同时跑两个 `Conv3x3Slice`**（交错调度，见下）：
  *           头 = `conv`（输入来自 DDR 的输入窗 `fb`）→ 输出按列写 `fbMid`（中间张量，**零 DDR**）；
  *           尾 = `convT`（本片**新增的第二个切片实例**）→ 输入取 `fbMid` 的**消费口**，输出写 `outMemT` -> DDR(`dstA`)。
  *           ⇒ 一个 RD（头输入）+ 一个 WR（尾输出）；中间张量**结构性不落 DDR**（`fbMid` 的写口只在片上，
  *             尾的读口来自 `fbMid` 的消费口 ⇒ 尾**没有 RD 相位**（`RDSTART/RDRUN` 只发一笔、长度 = 头的输入字节数）。
  *     · `bit0=1, bit1=1`（★ 退化档，**只**用作闸门的负对照）：头**既**落 DDR(`outMem`) **又**照旧喂 `fbMid`
  *           （这样尾才有数据可吃）；尾照常跑、写 `outMemT`。⇒ 两个 WR 相位、DDR 写字节 = 头的 `IMG_H*IMG_W*C`
  *           + 尾的 `IMG_H*IMG_W*C`（**变大**）。这正是"把 `FLAGS.bit0` 强行置 1（头单元也落 DDR）"的语义。
  *
  *   ---- ★ 交错调度：3 行环窗上的行锁步（本片的**核心约束**）----
  *   `fbMid` 是 3 行环窗（`3*WIDTH` 字），而中间张量有 `IMG_H` 行（本用例 `IMG_H=4 > 3`）⇒ 整张塞不进。
  *   照抄输入窗 `fb` 的**行锁步**纪律（见上"窗口读时序"），把两条锁步**首尾相扣**：
  *     · **头** 写 `fbMid` 第 `r` 行（`r = 0..IMG_H-1`，一拍一列、行末那拍拉 `wr_row_adv`）—— 这在**尾**这边
  *       等价的"生产口"，其**消费口**就是尾的列进料。写第 `r` 行会**就地覆盖**第 `r-3` 行（环窗只有 3 格）
  *       ⇒ 头写第 `r` 行**必须等尾读完第 `r-1` 行**（更紧的充分条件）：
  *         `headMayFeedRow(k) = (k == 0) || (tailDone >= k-1)`，其中 k 是 `conv` 正在吃的**输入行**，
  *         它产出的是 `fbMid` 第 `k-1` 行（`Conv3x3Slice` 的"晚一行"约定，见其文件头）。
  *       ⇒ 一旦 `fbMid` 满，头**在输入行边界上停住**（不再向 `conv` 发 `x_valid`，`fb` 的生产也随之停：
  *         `mayWrite = cdone >= pwant` 自然把 DDR 读也压住）。这就是任务要的"头被 stall、尾消费后再 resume"。
  *     · **尾** 读 `fbMid` 第 `t` 行（`rd_row=2`，同步读 1 拍）—— 与 `fb` 的读**同一套**：读**刚写完**的那一行。
  *       尾可以读第 `t` 行 <=> 头**已整行写完**第 `t` 行（`midDone > t`）。由上面那条锁步，两个条件互补、不重叠。
  *     · **下边零填充**：`Conv3x3Slice` 的**上边**零填充由它自己的 `LineBuffer` 零初值造；**下边**要驱动方
  *       **多喂一行全 0**（其文件头明写）。⇒ 头的 `IMG_H` 行真中间行写完之后，本单元**注入一行全 0** 进 `fbMid`
  *       （`pad` 子状态，逐列写 0、行末拉 `wr_row_adv`；与输入路径的 pad 行**同一机制**），供尾算最后一行输出。
  *   ⇒ **占用性自证（不是注释，是可推的）**：尾算输出第 `y` 行时（中间第 `y+1` 行正在流入）手上要
  *     中间第 `y-1/y/y+1` 三行；行锁步保证这三行**同时有效**且**都不是头正在写的格**（`rd_row=2` 映射到
  *     `row_ptr-1`）。`3` 格环窗**恰好**够（这就是 `FusionBuf` 的 3 行深度的来源），**不需要**加大缓冲。
  *
  *   ---- `FLAGS` 的两条**结构性**断言（不是 TB 约定）----
  *     · **尾无 DDR 读**：`RDSTART/RDRUN` 在本次运行里**只发一笔**（头输入），尾的列进料从 `fbMid` 的
  *       `rd_data` 取 ⇒ 字节计数里**没有**"中间张量读回"那 `IMG_H*IMG_W*C` 字节。
  *     · **头在融合对里无 DDR 写**：`bit0=0` 时 `outMem` 的写使能带 `!isHead`（C3.9a 已有）⇒ 头一个字节
  *       都不写 DDR；`bit0=1` 的退化档才打开这条通路（负对照）。
  *
  *   ---- 两个切片的**权重**（各 576 B，带外预载）----
  *   头/尾是**两个不同的 `Conv3x3Slice` 实例**，各有自己的 `WeightStore` ⇒ ★ **C3.16 起由一套"权重信箱"**
  *   （`wgt_sel/wgt_addr/wgt_data/wgt_we`）分别装载：`wgt_sel` 选切片（0/1/2/…/L_MAX-1），
  *   `wgt_we` 只对选中的那一片生效 ⇒ **每一片各自独立可写**（旧的四套口 `we/we_t/we2/we3` 在
  *   `L_MAX>4` 时会把切片 4..7 别名到第 4 套，C3.16 已把这条限制去掉）。
  *   ★ 本片的**测试实现**（闸门口径，不是 RTL 的断言）：头用**只有中心抽头**的权重（`pad=1/stride=1`
  *     ⇒ 功能上就是 1x1 conv，`(C,W,H)` 形状不变）；尾用普通 3x3 权重。RTL **不**假定任何权重取值。
  *
  *   ---- S2/头档不变（回归纪律）----
  *     · `bit1=0` 时：尾子 FSM 停在 `WAIT`、pad 子状态不发火、`outMemT` 不写、`wrTotal` 里**没有**尾那一份
  *       ⇒ 与 C3.9a/S2 逐字节同形。
  *     · `midWrEn = (conv_y_valid && isHead)` 这一行的**字面**保持不动（C3.9a 闸门的红证据突变就认它）；
  *       `fbMid` 的实际写使能是 `midWrEn || (y_valid && hasTail)`（`midWrEn` 被真的用到 ⇒ 那行 `assign` 照样落网表;
  *       ★ A-1b：`hasTail` = `chainLen ≥ 2`，见下"★ A-1b"一节）。
  *
  * ================================ 与 C3.9/C3.10 的接口说明 ================================
  *   · S3（融合）要加两个分支：头单元"输出不落 DDR、喂下一单元的 FusionBuf"、尾单元"输入取上一单元
  *     的输出"。本单元把"输入来源"与"输出去向"都收敛在 RD/WR 两个分支里（`RDSTART`/`WRSTART`），
  *     S3 在这两处加肘即可，**不改**本文件已冻结的端口与数据通路宽度。
  *     ★ C3.9a 已把**头**这一半落地（`fbMid` + `isHead` 分支，见上节）；**尾**（`IN_FROM_PREV`）仍是下一片。
  *   · S4（LayerSched）按 `go`（单拍）进、等 `done`（单拍）或 `err`（单拍）出；本单元的 `busy` 覆盖
  *     整个在途相位（含 DdrMaster 的收尾），保证"`busy==0` 时下一次 `go` 必被受理"。
  *   · ★ **每次 `go` 的 per-run 复位**（见下"per-run 复位"一节）：`go` 时把本单元**所有** per-run 寄存器
  *     （生产侧列/行指针、消费侧子 FSM 与行列计数、`pixIdx`/`ri`、`mMode/mSrc/mDst/mLen`）复位到
  *     "刚上电"的值 ⇒ 旧的"一次 `go` 之后第二次 `go` 因为 `cdone==IMG_H+1 && pixIdx==pixTotal` 已经成立
  *     而**立刻跳进 WRWAIT 挂死**"这件事不复存在。
  *   · ★ **下游 conv 流水线的相位复位**（`conv.io.prime := runStart`，同一拍脉冲）：`Conv3x3Slice`
  *     （+ 其 `LineBuffer`）的"第几张图"相位（它按 WIDTH 自己数行、只把 `row==0` 当预滚行，历史只在
  *     上电清 0）是本文件**之外**的在途状态。光清本文件自己的寄存器只能消灭"挂死"，**数值仍不对**
  *     （第二次 `go` 会多出一整行像素 ⇒ `pixIdx` 越过 `pixTotal`）。所以 `go` 那一拍同时脉冲
  *     `conv.io.prime`，把 `st/col/row/ph/phantomPix/colLast/colWin` 与 `LineBuffer.col/hist0/hist1`
  *     清回上电态 ⇒ 第二次 `go` 的输入流与"上电后的第一列"逐拍同形、输出与第一张**逐字节相同**。
  *     ⇒ **C3.10（LayerSched 帧内连跑）的前置项由此关闭**（装置侧由 `+GO2` 连跑判据钉死）。
  *
  * ================================ ★ A-1a：L 切片片上融合链（本片；把融合对推广到 L 切片）========================
  *   ★★ **A-1b 已把 `chainLen` 从"`FLAGS[4:2]` 译码"改成"独立入参 `io.chain_len`"**（见下"★ A-1b"一节）：
  *      本节剩下的**结构/数据流/行锁步/实例计数**全部照旧，只有"链长从哪来"这一处变了。
  *   上面 C3.9b 的"融合对"是 **L=2** 的特例。本片把它推广成 **L 切片链**（`L_MAX` 是**生成期参数**，
  *   ★ A-3 起取 **8**）：一个 `go` 里串起 `chainLen ≤ L_MAX` 个 `Conv3x3Slice`，中间张量**全部留在片上**。
  *
  *   ---- 结构（L_MAX 个切片 + L_MAX+1 个行缓冲）----
  *     · 切片：`conv`(idx0) / `convT`(idx1) / `conv2`(idx2) / `conv3`(idx3) / `conv4`(idx4) … `conv7`(idx7)，
  *       **各带自己的 `WeightStore`**；装载口 = ★ **C3.16 的一套"权重信箱"**（`wgt_sel/wgt_addr/wgt_data/wgt_we`，
  *      带外预载）⇒ 每个切片各有一个 `sel===i` 比较，**只有被选中的那一片**收到写使能
  *       ⇒ **`L_MAX` 片各自独立可写**（旧的"4 套口 + 切片 4..7 共用第 4 套"在 C3.16 里已删除；
  *       那条限制曾让 `L_MAX=8` 的链"每片一份独立权重"无法由硬件表达 —— 现已关闭，见 `c3_area.md` §10.8）。
  *     · 行缓冲（`FusionBuf`，3 行环窗、字 = 一列 C 通道）：**`L_MAX+1` 个**，索引 `0..L_MAX`：
  *         - `bufs(0)` = 链的**输入窗**（`fb`，由 DDR 喂，含驱动方多喂的 1 行全 0 pad）；
  *         - `bufs(b)`（`1 ≤ b ≤ L-1`）= 切片 `b-1` 与切片 `b` 之间的**片上中间**；
  *         - `bufs(L_MAX)`（`fbOut`）= **通用末级行缓冲**（为把计数钉成常量 `L_MAX+1` 而例化）。
  *           本任务实现的默认通路把**最后一个活跃切片**直接写**片上输出存储**（`outMem`/`outMemT`）→ DDR，
  *           所以 `fbOut` 在默认通路里**空闲**（`wr_en=0`）——这是**明写的**如实记录（见 §实例计数）。
  *     · **零 DDR 中间**（结构性）：中间缓冲的写口只被切片输出/pad 注入驱动、读口只被下一切片消费；
  *       从任何中间缓冲到 DDR 写口**没有路径**（DDR 写口只吃 `outMem`/`outMemT`）。
  *
  *   ---- 数据流规则（`L = chainLen`，0 基）----
  *     · 切片 `i` 读 `bufs(i)` 的消费口；写 `bufs(i+1)` 的生产口 —— 当 `i < L-1`（它是"头"）。
  *     · **最后一个**切片（`i = L-1`）写**输出存储**（`outMemT`）→ DDR。
  *     · `L=2` 退化成 C3.9b 的融合对（切片0→fbMid、切片1→outMemT）；`L=1` 退化成 S2/头档。
  *     · 额外（**只作负对照**）：`FLAGS.bit0=1`（`!isHead`）时切片0**也**写 `outMem` → 它的中间张量**落 DDR**
  *       （= "把一个中间张量踢去 DDR" 的负对照，闸门 `run_chain_ab.sh` 用它取证 `wr` 变大 + 诱饵区被写）。
  *       ★ A-1b 下这条**只能**由"闸门直接把链描述符的 `bit0` 置 1"表达（per-operator 编码里 `bit0=1`
  *         的条目是 `plain`/`tail`，**不是** head ⇒ 调度器**不会**把这种表当链跑）。
  *
  *   ---- ★ A-1b：chainLen 改为**独立入参**（`FLAGS[4:2]` 作废）----
  *     A-1a 把链长编码在 `FLAGS[4:2]` 里（`CHAIN_LEN_M1`）；A-1b 按**用户批准的 per-operator 链式编码**
  *     把 `FLAGS[4:2]` **整段收回保留（必须为 0）**，链长改由调度器（`LayerSched`）作为**独立入参**
  *     `io.chain_len` 给出。理由：per-operator 编码下**一个描述符 = 一个算子**，"这是一条 4 切片链"
  *     这件事是**调度器扫表后才知道**的（`FLAGS` 只表达"本算子相对前后邻居的 I/O 归属"），
  *     再也塞不进单项描述符的保留位。
  *
  *     · `io.chain_len ∈ [1, L_MAX]`：本单元这次要跑的切片数（1 = 不融合的单切片档）。
  *     · `FLAGS` 的**两位语义**（`DescFlags`，本文件只读不写）：
  *         bit0 = `OUT_TO_DDR`：**0 ⇒ 切片0 的输出留在片上**（进 `bufs(1)`，不落 `outMem`）。
  *         bit1 = `IN_FROM_PREV`：per-operator 编码里表达"本算子的输入取**上一个算子**的片上输出"，
  *                               即"本描述符是链里的中/尾节点"。
  *       ★ **本单元拿到的是整条链的"链描述符"**（见下）：它的 `FLAGS` 取**链首那个条目**的
  *         ⇒ 链里 `bit0=0`（头在片上）；`bit1` 在链里恒 0（头不是"取上一个"），所以本单元**不**用
  *         `bit1` 判"有没有尾" —— 那件事由 `chain_len ≥ 2` 直接给出（`hasTail`）。
  *     · `FLAGS[7:2]` **保留 = 0**：非 0 ⇒ `go` 那一刻**响亮 `err` + 零搬运**。
  *     · `chain_len == 0` 或 `> L_MAX` ⇒ 同样**响亮 `err` + 零搬运**（"链长与生成参数不符"）。
  *
  *   ---- ★ A-1b：本单元的入参口径 = **"链描述符"**（`io.desc`）----
  *     一个 `description` 一项 = 一个算子；**一条链**（head + middle* + tail）由**多个相邻条目**表达，
  *     调度器把整条链**塌缩成一次 `go`**，并把**链描述符**喂给本单元：
  *       · `SRC_ADDR` = **链首（head）条目**的 `SRC_ADDR`；
  *       · `DST_ADDR` = **链尾（tail）条目**的 `DST_ADDR`（★ 由调度器替换 w5 得到）；
  *       · 几何/`QUANT_SHIFT`/`FLAGS` = **链首条目**的（同一条链上各切片的 `C/W/H/GROUP/QUANT_SHIFT`
  *         必须相同 —— 这正是"融合"的含义；`TYPE` 与**权重**可以逐片不同，本单元各切片各有自己的
  *         `WeightStore`，装载口是那**一套权重信箱**（`wgt_sel` 逐片选，见文件头"权重"一节））。
  *     ⇒ 本单元**只**看见"一个 go + 一条链描述符 + 一个链长"，它不知道链上有几个 head/middle/tail
  *       条目、也不知道它们的地址 —— 那些是 `LayerSched` 的事（扫表 + 塌缩，见 `LayerSched.scala`）。
  *
  *   ---- ★ 交错行锁步（本片的**核心约束**；占用性自证见下，这是最risky的一段）----
  *   每个中间缓冲只有 **3 格**（`FusionBuf` 的 3 行环窗）。中间张量有 `IMG_H` 行（本用例 `IMG_H=4 > 3`）⇒
  *   整张塞不进。照抄 C3.9b 的**行锁步**并**沿整条链逐对首尾相扣**：
  *     记 `wrote(b)` = 已写进 `bufs(b)` 的行数（含注入的 pad 行）、`read(b)` = 切片 `b` 已从 `bufs(b)` 消费的行数。
  *       ① 切片 `i` 消费 `bufs(i)` 第 `t` 行 ⇒ 需 `wrote(i) > t`（该行已整行写完）。
  *       ② 切片 `i` 写 `bufs(i+1)` 第 `r` 行（= 消费输入第 `r+1` 行时产出）⇒ 需 `read(i+1) ≥ r`：
  *          写第 `r` 行会**就地覆盖**第 `r-3` 行；而 `bufs(i+1)` 的消费者要用第 `r-3` 行算输出行 `r-4/r-3/r-2`
  *          （输出行 `r-2` 在消费输入行 `r-1` 时产出）⇒ 消费者至少已消费到第 `r-1` 行 ⇒ `read(i+1) ≥ r`。**充分**。
  *       **占用性（可推，不是注释）**：由 ①`read ≤ wrote`、②`wrote ≤ read+1` ⇒ **`wrote - read ∈ {0,1}`**：
  *       生产者最多领先消费者 **1 行** ⇒ 环里同时只有 `t-2,t-1,t`（**恰好 3 行**，正是 `FusionBuf` 的 3 格深度），
  *       **不需要**加大缓冲。两条件互补（①由写门控、②由读门控），且**链无环**（`buf0→s0→buf1→s1→…→outMemT`）
  *       ⇒ 无循环依赖 ⇒ **无死锁、无饥饿**：任一时刻生产者与消费者各至少有一条可行进。
  *       （与 C3.9b 完全同形：那里是 `headRowGate`(②) 与 `midRows>tRow`(①) 两条门。）
  *       **pad 行**：中间缓冲 `bufs(b)`（`1 ≤ b ≤ L-1`）在切片 `b-1` 写完 `IMG_H` 行真行、且切片 `b`
  *       已读完这 `IMG_H` 行后，注入**一行全 0**（`Conv3x3Slice` 的下边零填充由驱动方多喂一行的约定）——
  *       门 `wrote(b)==IMG_H && read(b)≥IMG_H` 与 C3.9b 的 `midRows==imgH && tailDone>=imgH` 同形。
  *
  *   ---- 每切片 `prime` ----
  *     `runStart` 那一拍对**每个**切片脉冲 `io.prime`（把 `Conv3x3Slice` + `LineBuffer` 的 per-image 相位清回上电态）。
  *
  *   ---- 实例计数（`L_MAX=8`，A-3 面积实测口径；`L_MAX=4` 时逐项减半）----
  *     8 x `Conv3x3Slice`（各含 1 x `WeightStore`）、9 x `FusionBuf`（= `L_MAX+1`）、2 x `Mem`（`outMem`/`outMemT`）。
  *     ★ C3.16：权重信箱**只多 8 个 `sel===i` 比较器**（一个切片一个），端口从 12 根降到 4 根。`WeightStore`
  *     的写口形状（`we/waddr/wdin`）**一字未动**（"整层常驻 + 静态下标译码"那套照旧）。
  *     文本口径（`gen/UnitExec.v`，`oneFilePerComponent=false`）：模块 `Conv3x3Slice`/`FusionBuf`/`WeightStore`
  *     各只有 1 份**定义**，但**例化点**分别是 8 / 9 / 1（`WeightStore` 在 `Conv3x3Slice` 里被例化 1 次 ⇒
  *     **展开后** `WeightStore` 实为 8 个）。`arr_p >>> 3'd6` 仍**恰好 8 处**（单份 `Conv3x3Slice` 定义）。
  *
  * ================================ ★★ C4b-B1：**权重段从 DDR 批量装载**（DMA 主路径） ================================
  * ★ 冻结数据流（本任务 Step 1；要改走 spec 修订）：
  * ```
  * 每个单元（一次 go）开跑**之前**，NPU 用自己的 DdrMaster（mode=RD）从 DDR 读**本单元的权重段**，
  * 逐字节灌进各切片的 WeightStore；段起点 = 主机编程的 WGT_BLOB_BASE + 表序前缀和 Σ_{j<i} N_j，
  * 段长 = chainLen * N_i，N_i = C_out*(C_in/GROUP)*9（dense/GROUP=1 时 576 = NENTRY）。
  * 信箱（区域 0）保留为**调试/覆盖**口；DMA 关掉（WGT_BLOB_BASE==0）时行为与 C3/C4a 逐字节相同。
  * ```
  * ---- 逐条落实 ----
  *  · **触发 = 现成的 `go`**：`IDLE` 里 `io.go` 那一刻判定（`dmaEn` 为真时先走 `WGTLD -> WGTRUN`），
  *    装载跑完再进 `RDSTART` 读激活 ⇒ 与"每个单元开跑之前先装自己的权重"逐字对应。
  *  · **地址 = 前缀和 + 基址**：本单元**不**维护前缀和（那是"表序隐含"的记账，住在走表的调度器
  *    `LayerSched` 里）——它从 `io.wgt_dma_addr` 收到**本单元权重段的绝对起点**（= base + Σ_{j<i} N_j），
  *    在 `runStart` 那一拍**寄存**（`wgtBaseR`，与 C4a-R2 的"描述符寄存化"同一套 idiom：切断
  *    "调度器组合量 -> DdrMaster 地址"这条长路）。
  *  · **段长由几何导出**：`N_i = C_out*(C_in/GROUP)*9`。本单元的**窄通路**要求描述符几何与本网表的
  *    展开期几何**逐项相等**（`dmaGeomOk`：`C_in==C && C_out==C && GROUP==group && !depthwise`）⇒
  *    那时 `N_i` 恰好 == 本切片 WeightStore 的条目数 `NENTRY = C*(C/GROUP)*9`（dense = 576，**展开期常量**
  *    ⇒ 装载路径里**没有**运行期除法/乘法，只有"片内地址 == NENTRY-1"这一个常数比较）。
  *    几何不符（宽层/深度卷积/`GROUP` 不符）⇒ **响亮 `err` + 零搬运**（见下"边界"）。
  *  · **片内分配**：一次 RD 读 `chainLen * NENTRY` 字节（**一笔连续读**），装载器按 `wlSlice/wlAddr`
  *    把前 `NENTRY` 字节灌进切片 0、再 `NENTRY` 灌进切片 1 …… ⇒ 链上第 k 片拿到 blob 里第 k 段，
  *    与"表序 == blob 序"的契约（spec §4.2）逐字对应。
  *  · **字节精确（判据 ② 的根据）**：`require(NENTRY % 8 == 0)`（一拍 8 B ⇒ 装载**以整拍收尾**，
  *    绝不"多读一截"）+ `require(NENTRY % 32 == 0)`（DdrMaster 的 RD 粒度 = 32 B）⇒ 段长既是一拍的
  *    整数倍、又是 32 B 的整数倍 ⇒ **读回来的字节数恰好 == 段长**（整帧 Σ 起来恰好 == blob 大小）。
  *    装载器**只**在 `rd_valid` 那一拍收新拍（`wlTake`），一拍 8 道逐拍吃掉 ⇒ 每拍恰好消耗一次、
  *    一拍不多读一个字节（"多读/少读"由 `run_wgtdma_ab.sh` 的网表突变负对照钉住）。
  *  · **与激活相位的复用**：**同一个** `DdrMaster`（不建第二个内存主口）—— 权重 RD（`WGTLD/WGTRUN`）
  *    与激活 RD（`RDSTART/RDRUN`）、输出 WR（`WRSTART/WRRUN`）在时间上串行（本单元本来就"一个主口"）。
  *    ★ 诚实记录（吞吐）：装载一拍一字节（`WeightStore` 的写口冻结为 `SInt(8)`）⇒ 576 B 段 ≈ 576~648 拍；
  *      本片**不**与计算重叠（"装载/计算重叠纪律"是 **B2** 的事），帧时账先按"串行"记。
  *  · **边界（本版**只**做窄通路，其余响亮拦住）**：
  *      - **宽层**（`C_in>8 || C_out>8`：权重段要按"趟瓦片"展开进 `wRam`，与 blob 的密集段**不同构**）
  *        在 `dmaEn` 为真时 ⇒ **响亮 `err`**（不静默落到"信箱没装 -> 算出来是垃圾"）；
  *      - `GROUP != 本网表的 GROUP`、`depthwise`（blob 里 `C_in/GROUP == 1` 的段长与密集布局不同构）、
  *        `C_in/C_out != C` ⇒ 同上**响亮 `err`**；
  *      - 段尾越出 28 bit DDR 窗 ⇒ 同上（`dmaWinOk`；否则主口地址会**静默回绕**）。
  *    ⚠ 因此 **C4b 的真表**（每个 conv 单元的 `C_in`/`C_out` 都 > 8）在本版**还不能**整帧走 DMA 主路径
  *      （B1 只覆盖"段长能装进切片 WeightStore"的窄单元；宽层的"趟瓦片展开"归 B2+）。报告如实记录。
  *  · **信箱仍是通路**：区域 0 的写口与 DMA 的写口**或**在一起（`we = 信箱 || DMA`）；两者地址/数据
  *    用同一个 `Mux(wlWr, ...)` 选（DMA 优先）。⇒ ① `WGT_BLOB_BASE != 0` 时 DMA 是**主路径**、
  *    信箱是**覆盖**口（主机在装载之后逐字节改某一项仍然生效，见闸门的覆盖作业）；
  *    ② `WGT_BLOB_BASE == 0` 时 DMA 整条不动 ⇒ 既有 C3/C4a 闸门**逐字节不变**。
  *  · **自报口**：`io.wgt_bytes` = 本次 `go` **真正写进 WeightStore 的字节数**（装载器的逐字节计数；
  *    没走 DMA 的 run 恒 0）⇒ 闸门可以拿它与"内存模型数出来的读字节"**两处独立对账**。
  *
  * ================================ ★★ C4b-B1b：**宽层走同一套 DMA 装载**（落点换到趟瓦片 `wRam`） ================================
  * ★ 冻结数据流（= B1 的同一句话，只是"落进哪里"不同）：
  * ```
  * 每个单元（一次 go）开跑之前，NPU 用自己的 DdrMaster（mode=RD）从 DDR 读**本单元的权重段**
  * （起点 = WGT_BLOB_BASE + 表序前缀和 Σ_{j<i} N_j、段长 = N_i = C_out*(C_in/GROUP)*9），
  *   窄层 ⇒ 逐字节灌进各切片的 WeightStore（B1；段长 == NENTRY ⇒ 片内条目数）；
  *   宽层 ⇒ 逐字节灌进**趟瓦片 RAM `wRam`**（B1b；段长 == nCi*nCo*576 ⇒ 一趟 576 B 的趟序展开）。
  * 信箱（区域 0 = 切片 WeightStore、区域 1 = 趟瓦片）保留为**调试/覆盖**口；
  * DMA 关掉（WGT_BLOB_BASE==0）时行为与 C3/C4a 逐字节相同。
  * ```
  * ---- 宽层的"趟瓦片展开"：**blob 序 → 趟序**的映射（本片的中心口径）----
  *   · **blob 段**（DDR 里那 `N_i` 字节，`wgt_index.json` 的 `offset/bytes`）：密集 `[co][ci][tap]`，
  *     `tap = ky*3+kx`（1×1 的其余 8 个抽头是 0），段内下标 `k = co*(C_in*9) + ci*9 + tap`；
  *   · **趟瓦片**（`wRam`，`MultiPassUnit` 每趟读一段 576 B）：第 `p = cob*nCi + cib` 趟在
  *     `wRam[p*576 + e]`，段内 `e = cl*72 + cil*9 + tap`（`cl = co%8`、`cil = ci%8`，
  *     正是 `Conv3x3Slice` 的 `weightAddr = co*(C_IN/GROUP)*9 + ciLocal*9 + tap`，`GROUP=1, C_IN=8`）：
  *     ```
  *     wRam[(cob*nCi + cib)*576 + cl*72 + cil*9 + tap] == blob[ΣN_{j<i} + ((cob*8+cl)*C_in + cib*8+cil)*9 + tap]
  *     ```
  *   · 读法（与"表序 == blob 序"同源）：blob 是按 **co 行 × ci 列** 的 9 字节"行"排的主序；
  *     `wRam` 把同一批行**按 (co-block, ci-block) 分块、块内行主序**重排 —— 即"8×8 块划分"这一步
  *     **从主机（信箱区域的逐字节灌）搬到了 NPU 自己**（装载器按计数器算落点，不做除法）。
  *   · 边界（**只做"可无损展开"的宽层**，其余在 `dmaEn` 下**响亮 err + 零搬运**）：
  *     `C_in%8==0 && C_out%8==0`（趟瓦片无"跳过通道"补位 ⇒ `nCi*nCo*576 == 段长` ⇒ **写满**整段、
  *     `wRam` 段内不留上一层旧值）、`GROUP==1`、非 depthwise、段长 `%32==0`（DdrMaster 的 RD 粒度 ⇒
  *     读回字节数**恰好** == 段长）、段尾在 28 bit DDR 窗内。⚠ 真表里 `C_in%8!=0`（如 `Conv_0`，432 B）
  *     或段起点非 32 B 对齐的单元仍**响亮 err**（报告如实记录；真帧要全覆盖需重排 blob 或放宽主口粒度）。
  *   · **字节精确（判据 ② 的根据）**：段长 `%32==0` ⇒ 一笔 RD 读回**恰好** `N_i` 字节；装载器逐字节
  *     计数（`wlCnt`）也恰好 `N_i`（宽通路的每个字节都落在 `wRam` 里、**没有**被丢弃的"段外道"）。
  *
  * ================================ ★★ C4b-B1c：**几何覆盖**（`C_in<8` / `C_out<8` / depthwise） ================================
  * ★ 冻结数据流（= B1/B1b 的同一句话；只放宽"哪些几何能装"）：
  * ```
  * 每个单元（一次 go）开跑前，NPU 从 DDR 读本单元的权重段（起点 = WGT_BLOB_BASE + 表序前缀和，
  * 段长 = N_i = C_out*(C_in/GROUP)*9），展开成 MultiPassUnit 每趟读的 8×8 趟瓦片写进 `wRam`：
  *   wRam[(cob*nCi + cib)*576 + cl*72 + cil*9 + tap]
  *     == blob[off + (co*cig + ciLocal)*9 + tap]   当且仅当 groupOfOut(co) == groupOfIn(ci)
  *     == 0                                        否则（跨组位置 / 跳过通道 / 空行 / 非对角趟）
  * 其中 co = cob*8+cl、ci = cib*8+cil、cig = C_in/GROUP、`ci = gco*cig + ciLocal`。
  * ```
  * B0 实测：真表 53 个 conv 单元里只有 **14** 个满足 B1b 的几何前提（`C_in%8==0 && C_out%8==0 &&
  * `GROUP==1` && 非 depthwise）。其余 39 个**不是算不了**（算的通路早就支持：`3c16o1g` 见 C4a.5a、
  * depthwise 见 C4a.6），而是**装载器太窄**。本片把装载器放宽到真表的全部几何：
  *   · **`C_in<8`**（如 `Conv_0`：`C_in=3`）⇒ 瓦片里 `cil ∈ [3,8)` 是"跳过通道"，**零填补**；
  *   · **`C_out<8`**（如 `Conv_54/60/72`：`C_out ∈ {1,4,10}`）⇒ 瓦片里 `cl ∈ [co_t,8)` 是空行，零填补；
  *   · **depthwise**（`GROUP=C_in=C_out`）⇒ `cig=1`、`ci=co` ⇒ 实字节落**对角位置**（`cl==cil`），
  *     跨组位置与**非对角趟**整趟 0 —— 与 `GroupMask.weightAddr` / `multipass_ref.weight_tiles()` 同源。
  * ---- 三处改动（都在装载器一侧；**不动**计算侧语义） ----
  *   1. **段长/落点按 GROUP 派生**：`cig = Mux(GROUP==1, C_in, 1)`（真表 `GROUP ∈ {1, C_in}`
  *      ⇒ 一次 2 选 1、**不做除法**；其余 `GROUP` 由 `grpOkW` 在 `go` 那一刻**响亮拦住**）；
  *      落点 `ci = gco*cig + ciLocal`（`gco = Mux(GROUP==1, 0, co)`）—— `GROUP=1` 退化成 B1b 原式
  *      **逐字节不变**，depthwise 退化成 `ci = co`。
  *   2. **RD 长度 = `ceil32(N_i)`**：B0 的 blob 每段都是 32 B 对齐、`aligned_bytes = ceil32(N_i)`
  *      （`DdrMaster` 的 `len%32==0`/`src%32==0` 契约**未放宽**）。多读的 ≤31 字节是**转换器补的 0**，
  *      装载器**不写**它们（写入字节数另存一个寄存器 `wgtWrLenR`）⇒ 判据②的分工：
  *      `MEM rd == ceil32(bytes)`、`WGT_BYTES == bytes`（`bytes%32==0` 时两者相等 ⇒ 既有 14 个几何不变）。
  *   3. **零填充相位**（`WGTLD` 里的新子相位）：需要补零的几何先花 `Z = nCi*nCo*576` 拍把
  *      `wRam[0,Z)` 逐字节写 0，再发 RD。为什么必须显式写：`wRam` 是**跨层常驻**的 Mem —— 那些
  *      "没有 blob 字节对应"的位置（跳过通道 / 空行 / 跨组 / 非对角趟）会**留上一层的旧权重**。
  *      ★ `wzNeed` 为假的几何（`C_in%8==0 && C_out%8==0 && GROUP==1`，即 B1b 已覆盖的 14 个）
  *      **一拍不加**（`wzGo` 恒 0）⇒ 既有闸门逐字节、逐拍不变。
  *      ★ 代价（明写）：补零是**一拍一字节**的线性扫描 ⇒ 最坏（depthwise `C=64`）`Z=36864` 拍；
  *      与"装载不与计算重叠"（B2 项）同为**吞吐**代价，判据是数值/字节不是性能。
  *   ★ **装载器前提 vs 计算侧前提（本片把它俩解耦）**：`wgtLoadOk` = `grpOkW && 段长!=0 && chainLen==1
  *      && 段尾在 28 bit DDR 窗内`（装载器只看这四条）；`wideGeomOk` 是**计算侧**的前提。B1c 时它还含
  *      `C_out%8==0`（宽 WR 相位按**整 co-block** 出料）；**★★ C4b-C1 起这条已放开** —— 末 co-block
  *      允许是**部分尾块**（WR 相位按 `C_out*H*W` 出料），`wideGeomOk` 只剩"可寻址"边界
  *      （`0 < C_out ≤ 8*NCOB_MAX`）。⇒ 真表 `C_out ∈ {1,4,10}` 的单元现在**能装、也能端到端算对**
  *      （闸门 `run_unitexec_wide_ab.sh` 的尾块用例）；只有 genuinely 不支持的几何才 `WGTRUN` 收工那一拍
  *      **响亮 err**。装载器自己的前提不合时更早就在 `IDLE` 拦住（那时**零搬运**，与 B1/B1b 同形）。
  *   ★ **诚实边界（本片未做）**：
  *     · ★★ **C4b-C2 已改**：depthwise 的**对角趟调度**（`isDwW` ⇒ 每个 co-block 只跑 `(b,b)` 一趟、
  *       收料门 `wCi==wCob`、偏置每趟都带）**已接进集成宽通路**（`run_dw_wide_ab.sh` 判据①：17 个真
  *       宽层 depthwise 端到端逐字节 == 冻结黄金）。★ 但**注意口径**：改动前的一般趟（`wCi==nCi-1`）
  *       在 depthwise 上**也是逐字节正确的**（装载器把非对角趟整趟零填 ⇒ 贡献恰 0 ⇒ 一般趟 == 对角趟，
  *       C4a.6 的单元级等价）；对角趟改的是**结构/吞吐**（`nCi*nCo` 趟 → `nCo` 趟、列流少喂 `nCi` 倍）。
  *     · `GROUP ∉ {1, C_in==C_out}`（真表**没有**这样的 conv 单元）⇒ 响亮 err + 零搬运。
  *     · ★★ C4b-C3 **已改**：`C ∈ {1,4}`（真表 9 个：`C=1` 的 6 个 conv3x3 + depthwise `C=4` 的 3 个）
  *       现在按**几何**路由进**宽通路**（窄通路 `WeightStore` 是 8x8 固定形状、根本装不下它们）——
  *       `isWide = !narrowShape`，`narrowShape` = `C_in==C_out==8 ∧ GROUP==1 ∧ 非 depthwise`
  *       （与 `dmaGeomOk` 同式）。门 `run_nonwide_wide_ab.sh` 把这 9 个真单元端到端逐字节证死。
  *     · ★★ **C4b-B2 已改**：**参数表下标越界**（`LAYER_ID ≥ PN_LAYERS`）此前只在**宽通路**被
  *       `wideGeomOk` 挡住，**窄通路（信箱 / 窄 DMA）漏了这条** ⇒ 会静默回绕读到别的层的
  *       `M`/`z_pad`/`z_y`/`bias_adj`。现由 `lidOk`（`go` 那一刻、三通路共用）**响亮 err + 零搬运**。
  *       ⇒ **参数投递的唯一真源**：`y1/gen/wgt_index.json` 的 `requant_mult`(M) + `centering`(z_pad/z_y/bias_adj)，
  *       经**既有权重信箱**按 `LAYER_ID` 投递（spec §4.4/§4.5；区域 2/3/4/5）。门 = `run_paramdel_ab.sh`。
  * ===================================================================================== */
class UnitExec(val C: Int = 8, val WIDTH: Int = 64, val IMG_H_MAX: Int = 4, val L_MAX: Int = 8,
               /** ★★ T-S2R：**2-D tile 循环开关**（编译期）。`false`（默认）⇒ 本文件**逐字节不变**
                 *   （既有 `gen/UnitExec*.v` 与全部既有闸门零改动）；`true` ⇒ 本单元把"整层"改按
                 *   `W_TILE×H_TILE` 的 2-D tile 循环跑：每个输出 tile 的**输入窗口**按 T-S0 钉死的 halo
                 *   规则（左闭右开感受野）由**行跨步窗口读** gather 进来，跑完一层 tile，把 tile 的输出
                 *   写回 DDR 的 tile 位置。tile 尺寸 = `WT = (WIDTH-2)/s`（行）× `HT = IMG_H_MAX`（列）。
                 *   ★ 本档只覆盖**窄通路**（`C_in==C_out==8 ∧ GROUP==1 ∧ 非 DW`）、`chainLen==1`、
                 *     `!isHead`、`s ∈ {1,2}`；其余几何由 `go` 那一刻**响亮 err + 零搬运**拦住。
                 *   ★ 描述符格式**一字未动**（tiling 落在本单元内部；`dw` 仍是全层几何）。 */
               val TILING: Boolean = false) extends Component {
  /** 本任务固定 dense（GROUP=1）；分组/深度卷积是 `Conv3x3Slice` 的其它档位（见 SliceGen）。 */
  val GROUP: Int = 1; val chain_cin: Vec[UInt] = if (TILING) { val v = in Vec (UInt(16 bits), L_MAX); v.setName("chain_cin"); v } else null; val chain_cout: Vec[UInt] = if (TILING) { val v = in Vec (UInt(16 bits), L_MAX); v.setName("chain_cout"); v } else null; val chain_grp: Vec[UInt] = if (TILING) { val v = in Vec (UInt(8 bits), L_MAX); v.setName("chain_grp"); v } else null; val chain_qsh: Vec[UInt] = if (TILING) { val v = in Vec (UInt(8 bits), L_MAX); v.setName("chain_qsh"); v } else null; val chain_lid: Vec[UInt] = if (TILING) { val v = in Vec (UInt(8 bits), L_MAX); v.setName("chain_lid"); v } else null; val chain_dw: Vec[Bool] = if (TILING) { val v = in Vec (Bool(), L_MAX); v.setName("chain_dw"); v } else null; val chain_1x1: Vec[Bool] = if (TILING) { val v = in Vec (Bool(), L_MAX); v.setName("chain_1x1"); v } else null; // ★★ A'-2：逐片几何入参（`TILING=true` 才创建；落在**既有行**上是行数中性要求；完整口径见文件尾「A'-2」一节）
  /** requant 右移，与 `tools/mac_ref.py` / `conv_unit_ref.py` 的夹具口径同值（负对照 A 就动它）。 */
  val SHIFT: Int = 6

  val ddrCfg = DdrMasterConfig()
  require(C == ddrCfg.DATA_W / 8,
    "C 必须等于 DdrMaster 一拍字节数（DATA_W/8=8）：一拍 = 一个像素的 C 个通道是'一拍一列'的前提")
  require(WIDTH >= 3, "3x3 窗口至少要 3 列")
  require(C == 8, "本任务的 UnitExec 固定一块 8x8 阵列（C_IN = C_OUT = 8）")
  require(L_MAX >= 2 && L_MAX <= 8,
    "本实现的链结构（sliceRest 非空 + 链首/尾）要求 L_MAX ∈ [2,8]；1 会在空序列 reduce 处展开失败")

  /** 列地址位宽（与 FusionBuf / Conv3x3Slice 同口径）。 */
  val cw = (log2Up(WIDTH) max 1)
  /** 权重条目数 = C_OUT*(C_IN/GROUP)*9（dense 时 576）⇒ 装载口地址位宽。 */
  val NENTRY = C * (C / GROUP) * 9
  val waBits = log2Up(NENTRY)
  // ===================== ★ C4a.5b：信箱区域 + 宽层多趟（新增；见文件头"C4a.5b"一节） =====================
  /** 信箱地址总位宽（`WGT_ADDR`）。高 4 位是**区域**，低 20 位是区域内下标（见文件头寄存器/偏移语义）。 */
  val MAILBOX_AW = 24
  /** 区域码 = `WGT_ADDR[23:20]`。 */
  val RGN_WGT   = 0x0   // 权重：切片 `WGT_SEL` 的 WeightStore 条目 `WGT_ADDR[9:0]`（**旧语义不变**）
  val RGN_WRAM  = 0x1   // 宽层权重的**趟瓦片 RAM**（按 (co-block,ci-block) 趟序）：字节下标 `WGT_ADDR[15:0]`
  val RGN_M     = 0x2   // §4.4 每层 Q24 乘子 M：`[15:8]=LAYER_ID`，`[1:0]=字节道`（小端 4 字节）
  val RGN_ZPAD  = 0x3   // §4.5 每层 pad 码点 z_pad：`[15:8]=LAYER_ID`（单字节）
  val RGN_ZY    = 0x4   // §4.5 每层输出零码点 z_y：`[15:8]=LAYER_ID`（单字节）
  val RGN_BIAS  = 0x5   // §4.5 每层每 co-block 的 8 个 bias_adj：`[15:8]=LAYER_ID [7:5]=co-block [4:0]=字节道(0..31)`
  /** ★★ C4b-B3：**宽层激活的来源开关**（`XDMA_EN`）：道 0 的 bit0。
    *   `0`（**上电值**）= 宽层激活由**外部 `wide_x` 端口**喂（= C4a.5b 的既有行为，既有闸门逐字节不变）；
    *   `1` = 本单元**自己从 DDR gather**（`SRC_ADDR` 的通道平面张量 → 行主序列流；见本文件「C4b-B3」一节）。
    *   走**既有权重信箱**（与 B1 的 `WGT_BLOB_BASE`(区域 6)、B2 的 `M/z_pad/z_y/bias_adj`(区域 2..5) 同一手法）
    *   ⇒ **描述符格式与寄存器契约零改动**。 */
  val RGN_XDMA  = 0x7
  /** 参数表的层数（`LAYER_ID` 8 位 ⇒ 硬件只支持 [0,PN_LAYERS-1]；越界 ⇒ `go` 那一刻响亮 `err`）。
    *   ★★ C4b-B2：这条"越界 ⇒ 响亮 err"的**唯一实现点**是下面的 `lidOk`（`go` 那一刻，三条通路共用）。
    *   此前宽通路由 `wideGeomOk` 里那一项挡住，而**窄通路（信箱 / 窄 DMA）没有这一项** ⇒ `LAYER_ID ≥ 64`
    *   会静默读**别的层**的参数（`mzRam`/`biasMem` 下标回绕）。`lidOk` 把它收敛到一处。 */
  val PN_LAYERS = 64
  /** 宽层权重趟瓦片 RAM 的字节数 = `max co-block × max ci-block × 每趟 576`（= 8*8*576 = 36864）。 */
  val WGT_RAM_BYTES = 8 * 8 * NENTRY
  /** 趟瓦片 RAM 的字节地址位宽（★ C4b-B1b：宽通路的落点算到这一宽度上）。 */
  val wRamAw = log2Up(WGT_RAM_BYTES)
  /** 宽层部分和缓冲的 co-block 段数上限（= 输出通道 / 8 的上限）。 */
  val NCOB_MAX = 8
  /** 宽层输出存储的**每 co-block** 像素数上限 = `MAXPIX`（= WIDTH*IMG_H_MAX）。 */
  val PIXW = WIDTH * IMG_H_MAX
  /** ★ C3.16：权重信箱的**切片下标位宽**（`log2Up(L_MAX)`；L_MAX=8 ⇒ 3 位）。 */
  val selBits = log2Up(L_MAX) max 1
  /** 输出存储的字数上限（一字 = 一个像素的 C 个通道）= **本网表被展开时的几何** `WIDTH * IMG_H_MAX`。 */
  val MAXPIX = WIDTH * IMG_H_MAX

  // ===================== ★★ C4b-B1：权重段从 DDR 批量装载（DMA 主路径；见文件头） =====================
  /** 本单元**每片**要装载的权重段字节数 = 该切片 WeightStore 的条目数（`C*(C/GROUP)*9`；dense = 576）。
    * 口径：装载路径**要求**描述符几何与本网表的展开期几何逐项相等（`dmaGeomOk`）⇒ 那时
    * `N_i = C_out*(C_in/GROUP)*9` 恰好 == 本值 ⇒ "段长由几何导出"与"片内条目数"是同一个数。 */
  val WGT_SEG: Int = NENTRY
  require(WGT_SEG % 8 == 0,
    "权重段长必须是 8 的整数倍：一拍 RD 给 8 B，装载以整拍收尾 ⇒ 绝不「多读一截」（判据 ② 的根据）")
  require(WGT_SEG % 32 == 0,
    "权重段长必须是 32 的整数倍：DdrMaster 的 RD 粒度 = 32 B（CHK 硬校验），否则那笔 RD 会被响亮拒绝")
  /** DDR 窗的字节上界 = `2^ADDR_W`（与 `DdrMaster.ADDR_W = 28`、`LayerSched.DDR_BYTES` 同源）。 */
  val DDR_BYTES: BigInt = BigInt(1) << ddrCfg.ADDR_W

  // ---- per-run 锁存：本单元权重段的**起点 + 段长**（`runStart` 那一拍从入参寄存，见文件头）----
  val wgtBaseR = Reg(UInt(ddrCfg.ADDR_W bits)) init 0
  val wgtLenR  = Reg(UInt(32 bits)) init 0
  // ---- 装载器（`WGTRUN` 期间推进；`wlRun` 是本路径的"在飞"位，与主 FSM 的 state 解耦 ⇒
  //      写口译码可以在组件体里**建在 state 之前**）----
  val wlRun   = Reg(Bool()) init False
  /** 已装载字节数（**逐字节**计数；= 自报口 `io.wgt_bytes` 的寄存源）。 */
  val wlCnt   = Reg(UInt(32 bits)) init 0
  val wlSlice = Reg(UInt(selBits bits)) init 0
  val wlAddr  = Reg(UInt(waBits bits)) init 0
  /** 手上有没有一拍（8 B）还没写完。 */
  val wlV     = Reg(Bool()) init False
  val wlIdx   = Reg(UInt(3 bits)) init 0
  val wlHold  = Vec(Reg(Bits(8 bits)) init B(0, 8 bits), ddrCfg.DATA_W / 8)
  // ---- ★★ C4b-B1b：**宽通路**的落点（见文件头「C4b-B1b」一节；落点表达式在装载器本体之后）----
  /** 本次 `go` 的 DMA 装载走**宽通路**（落 `wRam` 的趟瓦片，而非各切片的 `WeightStore`）。 */
  val wlWideR = Reg(Bool()) init False
  /** blob 序（`[co][ci][tap]`，`tap` 最快）里"当前字节"的坐标：`tap` = 0..8、`ci`/`co` 从 0 数起。 */
  val wlTap   = Reg(UInt(4 bits))  init 0
  val wlCi    = Reg(UInt(16 bits)) init 0
  val wlCo    = Reg(UInt(16 bits)) init 0
  // ---- ★★ C4b-B1c：几何覆盖（`C_in<8` / `C_out<8` / depthwise）的两件新事 ----
  /** ★★ C4b-B1c：本次 `go` **真正要写的字节数**（= 真实段长 `N_i`；窄通路 = `wgtLenR`）。
    *   与 `wgtLenR`（**RD 长度**）分开：B0 的 32 B 对齐下宽层 RD 长度是 `ceil32(N_i)`，
    *   多读的补位字节**不写** ⇒ 判据② 的分工是 `MEM rd == ceil32(bytes)`、`WGT_BYTES == bytes`。 */
  val wgtWrLenR = Reg(UInt(32 bits)) init 0
  /** ★★ C4b-B1c：**零填充相位**的字节计数器（`[0, Z)`，`Z = nCi*nCo*576`）。 */
  val wzCnt = Reg(UInt(32 bits)) init 0
  /** ★★ C4b-B1c：零填充相位在飞（`WGTLD` 里先把它跑完再发 RD；不补零的单位恒 0 ⇒ 零开销）。 */
  val wzGo  = Reg(Bool()) init False

  val io = new Bundle {
    // ---- 单元控制 ----
    val go   = in Bool()
    /** 描述符的 8 个 32-bit 小端字（`DescWords(w0..w7)`；`w0` 是**最低地址**那个字，与 DescFetch 同形）。
      * ★ A-1b：这里喂的是**链描述符**（链首的字 + 链尾的 `DST_ADDR`；见文件头"链描述符"一节）。 */
    val desc = in Vec (Bits(32 bits), 8)
    /** ★ A-1b：**链长**（本次 `go` 要跑的切片数，1..L_MAX）—— 由调度器作为**独立入参**给出
      *   （A-1a 的 `FLAGS[4:2]` 编码作废；见文件头）。`0` 或 `> L_MAX` ⇒ `go` 那一刻响亮 `err`。 */
    val chain_len = in UInt (16 bits)
    /** 带外：本单元权重在 WeightStore 的基址。**S2 保留、不参与寻址**（C4 开口项，见文件头）。 */
    val wgt_base = in UInt (16 bits)
    /** ★ C4b-B1：**本单元权重段在 DDR 的绝对起点**（= 主机编程的 `WGT_BLOB_BASE` + 表序前缀和
      *   `Σ_{j<i} N_j`，由走表的 `LayerSched` 记账后送进来；见文件头「C4b-B1」一节）。
      *   `0` ⇒ **DMA 主路径关闭**（与 C3/C4a 的"信箱带外预载"行为**逐字节相同**）；
      *   非 0 ⇒ 本单元开跑前先用 RD 把 `chainLen*NENTRY` 字节灌进各切片的 `WeightStore`。 */
    val wgt_dma_addr = in UInt (ddrCfg.ADDR_W bits)
    // ---- 权重装载口（★ C3.16：**一套权重信箱**，直通各 `Conv3x3Slice` -> `WeightStore`）----
    //   带外预载，必须在 go 之前做完。★ A-1a/A-3 之前这里是**四套**装载口（`we`/`we_t`/`we2`/`we3`）
    //   ⇒ `L_MAX>4` 时切片 4..7 只能**共用**第 4 套（"切片 4..7 别名切片 3"这条限制）。
    //   C3.16 把它换成**一套信箱**：`wgt_sel` 选切片、`wgt_addr`/`wgt_data` 是载荷、`wgt_we` 是写使能。
    //   展开期对每个切片各做一个 `sel === i` 比较 ⇒ **只有被选中的那一个切片**收到 `we=1`
    //   ⇒ `L_MAX` 个 `WeightStore` 各自独立可写（切片数不再受装载口数限制）。
    //   为什么译码落在这里（而不是调用方 `LayerSched`）：切片**住在**本模块里，比较器与它驱动的那片
    //   `WeightStore` 写口**同一处**出现，位宽/切片数由 `L_MAX` 一处派生；调用方只搬 4 根线。
    val wgt_sel  = in UInt (selBits bits)
    /** ★ C4a.5b：`wgt_addr` 由"单切片条目下标（10 位）"**扩宽为信箱全地址（24 位）** ——
      *   高 4 位是**区域**（见文件头寄存器/偏移语义），低 20 位是区域内下标。旧的窄通路（区域 0，
      *   条目下标 < 1024）**逐字节不变**：既有装置驱动的低 10 位落到区域 0 ⇒ 与旧行为同形。 */
    val wgt_addr = in UInt (MAILBOX_AW bits)
    val wgt_data = in SInt (8 bits)
    val wgt_we   = in Bool()
    // ---- ★ C4a.5b：宽层多趟通路的**激活列流**（8 通道/拍，行主序）----
    //   宽层（C_in>8 或 C_out>8）的激活由调用方（主机/DMA）按**趟序**（co-block 外、ci-block 内）
    //   流进来；本单元给每趟合成**一行 `z_pad` 的下边填充行**（见文件头 §4.5 一节）。
    //   ★ 口径（明写）：DDR→"ci-block 平面布局"的 gather 是 C4b（G6）项；本片只证"参数经信箱 +
    //     多趟累加 + 单次 requant + pad=z_pad"这条**已接线**的通路逐字节对。
    val wide_x       = in  Vec (SInt(8 bits), C)
    val wide_x_valid = in  Bool()
    val wide_x_ready = out Bool()
    /** ★★ C4b-B3：**观察口** —— 本拍喂给 `mpu` 的激活列（= 外部 `wide_x` 或 DDR gather，二选一）
      *   与该列**被收下**的指示。仅观察（供"NPU 读到的列 == 冻结布局"逐字节判据）；无逻辑。
      *   `x_dbg_ok` = 本拍确实**成交了一列**（`valid && ready`） ⇒ 装置只在它为 1 的拍采样 `x_dbg`。 */
    val x_dbg        = out Vec (SInt(8 bits), C)
    val x_dbg_ok     = out Bool()
    // ---- 状态 ----
    val busy = out Bool()
    val done = out Bool()          // 单拍脉冲（整单元跑完）
    val err  = out Bool()          // 单拍脉冲（透传 DdrMaster.err / 描述符对账 ⇒ 一个字节都不搬）
    // ---- 自报（几何钉死：TB 在 time 0 与描述符/装置参数对账）----
    val imgC  = out UInt (16 bits) // = C
    /** ★★ T-S1：`imgW` 现在是**分配口径** `W_MAX`（= 生成本网表时的 `WIDTH`），**不再是"本次运行的行宽"**
      *   —— 运行期行宽 = 下面 `row_w` 那个口（= `IMG_W·s` 的上界）。两条对账的**分工**（明写）：
      *     · `imgW`（常量）：TB 在 time 0 钉"网表是按哪个 `W_MAX` 生成的"；
      *     · `row_w`（运行期）：跑起来之后本层**实际用的行宽**，`1 ≤ row_w ≤ imgW` 由 `go` 的界限对账拦住。 */
    val imgW  = out UInt (16 bits) // = WIDTH（生成该网表时的**分配**行宽 = W_MAX）
    /** ★★ T-S1：**运行期行宽** `rowW`（= 本层 `IMG_W·s` 的上界口径）—— `go` 那一刻闩存，观察/对账用。
      *   一张 `W_MAX=640` 的网表跑 6 个不同行宽的层时，本口会报出**6 个不同值** ⇒
      *   "运行期闩存真的在跑"的**直接证据**（负对照把闩存钉成常量 ⇒ 这一路也一起钉住）。 */
    val row_w = out UInt (20 bits)
    val grp   = out UInt (4 bits)  // = GROUP
    val shift = out UInt (8 bits)  // = SHIFT（负对照 A 的靶子，方便报告如实记录）
    val maxPix = out UInt (16 bits) // = MAXPIX = WIDTH*IMG_H_MAX（输出存储字数上限，几何钉死）
    /** ★ A-1b：链长的**回读口**（= 上面那个 `io.chain_len` 入参）。
      *   A-1a 的"自报链长"是**纯组合译码**出来的（译自 `FLAGS[4:2]`）；A-1b 里链长**是入参**
      *   ⇒ 这一路退化成"把我收到的链长回读出来"，用途只剩**观察/对账**（TB/闸门据此确认
      *   "调度器确实把链长接到了本单元"，且 netlist 端口没有悬空/常 0）。 */
    val chain_len_rep = out UInt (16 bits)
    /** ★ A-1a：本网表的**生成期上限** `L_MAX`（常量）；观察/对账（TB 在 time 0 与期望对账）。 */
    val lmax  = out UInt (16 bits)
    // ---- ★ C4a.5b 自报/观察（宽层多趟 + 信箱参数；**只观察/对账**，不参与数据通路）----
    /** 本次 `go` 走的是**宽层多趟**通路（`C_in>8 || C_out>8`）。 */
    val wide_on     = out Bool()
    /** 宽层趟数 = `ceil(C_in/8) × ceil(C_out/8)`（窄通路恒 1）。 */
    val wide_passes = out UInt (16 bits)
    /** 按 `LAYER_ID` 从参数表读出的 **M**（§4.4；窄通路未装载时 = 2^24 单位乘子）。 */
    val rtl_m       = out UInt (32 bits)
    /** 按 `LAYER_ID` 读出的 **z_pad**（§4.5）。 */
    val rtl_zpad    = out SInt (8 bits)
    /** 按 `LAYER_ID` 读出的 **z_y**（§4.5）。 */
    val rtl_zy      = out SInt (8 bits)
    /** 参数表**层下标**（= 描述符 `w7[15:8]` 的 `LAYER_ID`）；与信箱写入用的下标**同一真源**。 */
    val rtl_layer   = out UInt (8 bits)
    /** ★ C4b-B1：本次 `go` **真正写进 `WeightStore` 的权重字节数**（装载器逐字节计数；未走 DMA 恒 0）。
      *   与"内存模型数出来的读字节"是**两处独立计数**（闸门必须一起对上才算数）。 */
    val wgt_bytes   = out UInt (32 bits)
    // ---- 观察（供 TB 与内存模型交叉对账）----
    val rd_bytes = out UInt (32 bits)
    val wr_bytes = out UInt (32 bits)
    // ---- 观察（C3.9a 头分支：中间 FusionBuf 的消费口引出，**仅观察**；不参与数据通路）----
    val mid_rd_row  = in  UInt (2 bits)          // 观察口：中间缓冲读行（0=最老 / 1=中 / 2=最新）
    val mid_rd_col  = in  UInt (cw bits)         // 观察口：中间缓冲读列（同 FusionBuf 列地址位宽）
    val mid_rd_data = out Vec (SInt(8 bits), C)  // 观察口：中间缓冲读出的一列（C 个通道；同步读、1 拍延迟）
    val head_mode   = out Bool ()                // 本次运行的 OUT_TO_DDR 判定（1=头 / 0=落 DDR）；观察/对账
    val mid_rows    = out UInt (16 bits)         // 中间缓冲 `bufs(1)` 已推进行指针次数（自报口）
    // ---- ★ C3.9b 尾分支的观察口（**仅观察**；不参与数据通路，也无回写）----
    val tail_mode   = out Bool ()                // ★ A-1b：本次运行"有没有尾在跑"（= chainLen≥2）；观察/对账
    val tail_rows   = out UInt (16 bits)         // 切片1(`convT`) 已从 `bufs(1)` 读完的中间行数（含注入的 pad 行）
    // ---- AXI4 主口（与 DdrMaster.io.axi 同形）----
    val ddr = master(Axi4(Axi4Config(
      ddrCfg.ADDR_W, ddrCfg.DATA_W,
      idWidth = ddrCfg.ID_W,
      useId = true, useLen = true,
      useLock = false, useRegion = false, useQos = false,
      awUserWidth = 0, arUserWidth = 0, wUserWidth = 0, bUserWidth = 0, rUserWidth = 0
    )))
  }
  noIoPrefix()

  // ---------------------------------------------------------------------------
  // 被接方与描述符译码
  // ---------------------------------------------------------------------------
  val ddrMaster = new DdrMaster(ddrCfg, rqDepth = (if (TILING) 8 else 4))   // P3: tiled gather 8 slots ⇒ 8 项一批一波（原 4 槽两波）；TILING=false 冻结
  io.ddr <> ddrMaster.io.axi

  // ---- L_MAX 个切片实例（各带自己的 WeightStore；装载口 = ★C3.16 的一套权重信箱）----
  //   ★ 切片0 必须**叫 `conv`**：`run_fuse_head_ab.sh` 的外科式突变按逐字行
  //     `assign midWrEn = (conv_y_valid && isHead);` 抓它（见下 midWrEn）。
  val conv  = new Conv3x3Slice(C_IN = C, C_OUT = C, GROUP = GROUP, WIDTH = WIDTH, SHIFT = SHIFT, PSW = if (TILING) 32 else 64)
  val sliceRest = (1 until L_MAX).map(_ =>
    new Conv3x3Slice(C_IN = C, C_OUT = C, GROUP = GROUP, WIDTH = WIDTH, SHIFT = SHIFT, PSW = if (TILING) 32 else 64))
  val slices: Seq[Conv3x3Slice] = conv +: sliceRest

  // ---- L_MAX+1 个行缓冲（FusionBuf，3 行环窗、字 = 一列 C 通道），索引 0..L_MAX ----
  //   bufs(0) = 输入窗 `fb`（DDR 喂）；bufs(b)（1..L-1）= 片中间；bufs(L_MAX) = 通用末级（默认空闲）。
  val fb = FusionBuf(C = C, WIDTH = WIDTH)
  val bufRest = (1 to L_MAX).map(_ => FusionBuf(C = C, WIDTH = WIDTH))
  val bufs: Seq[FusionBuf] = fb +: bufRest

  // DescWords 必须在组件体里一次性建好（其方法是组合节点；见 DescDefs 的文件头）。
  // ★ C4a.5b：**上移到参数块之前** —— 下面的参数表按 `dw.layerId`（`LAYER_ID`）索引。
  val dw = DescWords(io.desc(0), io.desc(1), io.desc(2), io.desc(3),
                     io.desc(4), io.desc(5), io.desc(6), io.desc(7))

  // ===========================================================================
  // ★★ C4b-D1：**卷积步长 + 输入几何**（描述符 `w3[11:8]` 的 `STRIDE`；**格式一字未改**）
  // ===========================================================================
  //   `STRIDE` 此前被 `DescWords` 译码后**未使用**（真实网 layer 0 `Conv_0` 是 stride=2 ⇒ 真帧起步就错）。
  //   本块把"步长 → 输入几何"这条推导航收敛到**一处**（窄/宽通路、喂列、收料、报账全消费这几个量）：
  //     · `strideEff`：字段 `0` 视作 `1`（旧表/旧装置把该字段留 0 ⇒ 与 C4a 逐字节同形）；
  //     · `inRows`   ：输入**行数** = `IMG_H · s`。为什么是这个式：ONNX 的
  //                    `Ho = floor((H_in + 2·pad - K)/s) + 1` 在 `pad=1,K=3` 下**不能唯一反解** `H_in`
  //                    （`H_in ∈ [Ho·s - s + 1, Ho·s]`）——本单元取**上界** `H_in = Ho·s`；
  //                    真网 `Conv_0`（640×640 → 320×320, s=2）**恰落在上界**（320·2 = 640）。
  //                    `s=1` ⇒ `inRows == IMG_H`（与改动前**逐字同值**）。
  //     · `inWOk`    ：★ T-S1 起是**运行期界限**：本层输入宽 `inWMax = IMG_W·s` 必须落在 `[1, W_MAX]`
  //                    （`W_MAX` = 展开期 `WIDTH` = **分配**口径）—— 这个值就是 `rowW`（`go` 拍闩存）。
  //                    改动前它是编译期等式 `WIDTH ∈ [IMG_W·s-s+1, IMG_W·s]`（`s=1` ⇒ `IMG_W==WIDTH`）；
  //                    那要求"一张网表一个行宽"，真表 6 个行宽跑不动 ⇒ 见下面「运行期行宽」一节。
  //     · 喂列口径 = `inRows` 真行 + **1 行下边零填充行**（`inRows+1` 行 × `rowW` 列）。
  //   ★ 已知边界（报告里明写；真帧不受影响）：若某层 `H_in < Ho·s`（同一 `Ho` 的另一个解），
  //     驱动方须**自己多喂**那几行真实数据；本单元按上界口径喂满 ⇒ 少 1 行时最后一行输出会用到 pad。
  val strideEff = Mux(dw.stride === U(0, 4 bits), U(1, 4 bits), dw.stride)
  /** 输入行数 = `IMG_H · s`（上界口径；`s=1` ⇒ `IMG_H`）。 */
  val inRows   = (dw.imgH.resize(20) * strideEff.resize(20)).resize(16)
  /** 一趟要喂的行数 = `inRows` 真行 + 1 行 pad（`s=1` ⇒ `IMG_H+1`，与改动前同值）。 */
  val inRowsP1 = (inRows + U(1, 16 bits)).resize(16)
  /** `WIDTH` ∈ `[IMG_W·s-s+1, IMG_W·s]`（`s=1` ⇒ 单点 `IMG_W`）。 */
  val inWMin   = ((dw.imgW.resize(20) * strideEff.resize(20)) - strideEff.resize(20) + U(1, 20 bits))
  val inWMax   = (dw.imgW.resize(20) * strideEff.resize(20))
  // ===========================================================================
  // ★★ T-S1（2026-10-13）：**运行期行宽 `rowW`** —— 把"编译期等式"改成"运行期界限"（spec §3.1）
  // ===========================================================================
  //   动因（实测）：真表 `desc.bin` 的 conv 层输入行宽有 **6 个** `{640,320,160,80,40,20}`
  //   （最大 640 = `Conv_0` 的 `IMG_W=320 × s=2`）。改动前的 `inWOk` 是**编译期等式**：
  //       `WIDTH ∈ [IMG_W·s-s+1, IMG_W·s]`
  //   ⇒ 一张 `WIDTH=640` 的网表**只能**服务 `Conv_0` 那一层（其余 5 个行宽全被 `go` 那一刻拦死）。
  //   修法（本块 + 下面所有"计数/寻址"点）：
  //     · **`rowW` := `inWMax`（= `IMG_W·s`），在 `go` 那一拍闩存**（见 `IDLE` 态的第一条赋值）；
  //     · 界限改成**运行期**：`1 ≤ rowW ≤ W_MAX`（`W_MAX` = 展开期 `WIDTH` = **分配**口径）
  //       —— 即本式。不合 ⇒ `go` 那一刻**响亮 err + 零搬运**（绝不静默算错）；
  //     · 此后**一切用于计数/寻址的行宽都是 `rowW`**（列回绕、行步长、行序、平面步长…），
  //       **所有存储的分配仍按 `WIDTH`（= `W_MAX`）** ⇒ S1 不省面积（那是 S2 的 tile 循环）。
  //   ★ 为什么"上界口径"就够：`inWMin = inWMax - s + 1` 那一段（`H_in < H_o·s` 的另一个解）由
  //     驱动方按上界喂满；本单元只认上界（与 `inRows = IMG_H·s` 同一口径，见上面 C4b-D1 一节）。
  //   ★ 既有行为不变：`s=1` 且 `WIDTH == IMG_W` ⇒ `rowW = WIDTH` ⇒ 与改动前**逐字同值**。
  /** ★★ T-S1：**运行期界限**（取代改动前的编译期等式）。`go` 那一刻不合 ⇒ 响亮 err、零搬运。 */
  val inWOk    = (inWMax >= U(1, 20 bits)) && (inWMax <= U(WIDTH, 20 bits))
  /** ★ C4b-D1：`s > 1` 的**多片链**不在本版几何推导范围内（中间张量的 H/W 逐片变）⇒ `go` 那一刻
    *   **响亮 err + 零搬运**（不静默）。单单元（`chainLen == 1`，含真网所有 stride=2 单元）不受影响。 */
  val strideChainOk = (strideEff === U(1, 4 bits)) || (io.chain_len === U(1, 16 bits))

  // ===========================================================================
  // ★ C4a.5b：§4.4/§4.5 参数（M / z_pad / z_y / bias_adj）走**既有权重信箱**、按 `LAYER_ID` 投递
  // ===========================================================================
  // 信箱区域（`WGT_ADDR[23:20]`；低 20 位是区域内下标）。**旧的窄通路 = 区域 0**（条目下标 < 1024 ⇒
  // 高 4 位为 0）⇒ 逐字节不变。新区域把 §4.4 的 `M`、§4.5 的 `z_pad/z_y/bias_adj` 灌进下面两张表。
  /** 参数表（`M`/`z_pad`/`z_y`）的每层字节步长：`M`(4) + `z_pad`(1) + `z_y`(1) + 2 保留 = 8。 */
  val PSTRIDE = 8
  /** 信箱区域码（`WGT_ADDR[23:20]`）。 */
  val rgn = io.wgt_addr(MAILBOX_AW - 1 downto MAILBOX_AW - 4)
  /** 区域内**层下标**（`WGT_ADDR[15:8]`）—— 与描述符 `w7[15:8]` 的 `LAYER_ID` **同一真源**。 */
  val rgnLid = io.wgt_addr(15 downto 8)
  // ---- 表 1：`M` / `z_pad` / `z_y`（字节寻址；每层 8 字节）----
  //   ★ **初值 = 单位元**（`M = 2^24`、`z_pad = z_y = 0`）⇒ **不写信箱参数的既有 C3 闸门**走到的
  //     就是"与 C3 逐字节同形"的旧行为（`((acc·2^24)>>24)>>6 == acc>>6`、pad = 0、z_y = 0）。
  val mzRam = Mem(Bits(8 bits), PN_LAYERS * PSTRIDE).init(
    Seq.tabulate(PN_LAYERS * PSTRIDE)(i => if (i % PSTRIDE == 3) B(1, 8 bits) else B(0, 8 bits)))
  // ---- 表 2：`bias_adj`（**字**寻址：`[LAYER_ID][co-block][co]` ⇒ 32 位；每层 64 字）----
  val biasMem = Mem(Bits(32 bits), PN_LAYERS * NCOB_MAX * 8).init(Seq.fill(PN_LAYERS * NCOB_MAX * 8)(B(0, 32 bits)))
  // 信箱写入（逐字节）：`M` 走 `[1:0]` 字节道；`z_pad`/`z_y` 固定偏移 4/5。**按 `LAYER_ID` 索引**。
  val mzBase  = (rgnLid.resize(16) * U(PSTRIDE, 16 bits)).resize(16)
  val mzOff   = Mux(rgn === U(RGN_M, 4 bits),    mzBase + io.wgt_addr(1 downto 0).resize(16),
                Mux(rgn === U(RGN_ZPAD, 4 bits), mzBase + U(4, 16 bits),
                                                 mzBase + U(5, 16 bits)))
  val isMzWr  = io.wgt_we && ((rgn === U(RGN_M, 4 bits)) || (rgn === U(RGN_ZPAD, 4 bits)) || (rgn === U(RGN_ZY, 4 bits)))
  mzRam.write(mzOff.resize(log2Up(PN_LAYERS * PSTRIDE) bits), io.wgt_data.asBits, isMzWr)
  // `bias_adj` 的 32 位按**4 个字节道**（`WGT_ADDR[1:0]`）逐字节灌入；第 3 道那拍整字提交。
  //   口径（明写）：主机对每个 `(LAYER_ID, co-block, co)` 词按道 0→1→2→3 顺序写 4 拍。
  val bCob    = io.wgt_addr(7 downto 5)              // co-block
  val bCo     = io.wgt_addr(4 downto 2)              // co（组内 0..7）
  val bLane   = io.wgt_addr(1 downto 0)              // 字节道
  val bAcc    = Vec(Reg(Bits(8 bits)) init (B(0, 8 bits)), 4)
  val bWrIdx  = (rgnLid.resize(12) @@ bCob).resize(12)     // = LAYER_ID*8 + cob（字下标的高 11 位）
  val bWrWord = (bWrIdx @@ bCo).resize(log2Up(PN_LAYERS * NCOB_MAX * 8) bits)   // 字下标 = lid*64 + cob*8 + co
  val isBWr   = io.wgt_we && (rgn === U(RGN_BIAS, 4 bits))
  when(isBWr) {
    switch(bLane) {
      for (l <- 0 until 4) { is(U(l, 2 bits)) { bAcc(l) := io.wgt_data.asBits } }
    }
  }
  // ★★ C4a.5b **缺陷修-1**：提交字里**第 3 道必须取当拍数据**，不能取 `bAcc(3)`。
  //   为什么：`bAcc(3)` 是在**同一拍**（`bLane == 3` 那一拍）才被赋值的寄存器 —— Verilog 非阻塞语义下
  //   `biasMem.write` 读到的是它的**旧值**（= **上一个词**的第 3 道字节）。于是每个 `bias_adj` 词的
  //   **最高字节整体迟了一个词**、并且串进下一个词：提交值 = `(prev_a3 << 24) | (v & 0x00FFFFFF)`。
  //   · 对"最高字节恒 0"的值（`0 ≤ v < 2^23`）两种取法**结果相同** ⇒ 小值/正偏置上完全看不出问题
  //     （这正是既有 `run_multipass_ab.sh` 的 TB 直接喂 `+BFILE` 不经信箱、以及早期小偏置探针都能过的原因）；
  //   · 而 `bias_adj` 是**累加器单位的有符号量**，真层 `Conv_0` 就有负值（高字节 = `0xFF`）⇒ 被污染的词
  //     变成 `0x00FFFFxx`（**正巨值**）+ 下一词变成 `0xFFxxxxxx`（**负巨值**）⇒ 输出在这两个 co 上
  //     分别饱和到 **+127 / -128**。这与闸门实测的"`Conv_0` 只坏 co 5/6/10/11（其余 12 个 co 逐字节全对）、
  //     合成层坏 co 1/2/3/6"**逐一对应**（见 `c4a_wide` 的预测/实测对照）。
  //   修法：第 3 道直接从 `io.wgt_data` 取（同拍数据），低 3 道仍取 `bAcc(0..2)`（它们在道 0/1/2 那三拍
  //   已经落寄存器 ⇒ 读到的正是本词的值）。主持久化顺序 `道 0→1→2→3、第 3 道整字提交`（文件头写明的口径）
  //   **不变**。
  val bWrWordData = Cat(Mux(bLane === U(3, 2 bits), io.wgt_data.asBits, bAcc(3)),
                        bAcc(2), bAcc(1), bAcc(0))
  biasMem.write(bWrWord, bWrWordData, isBWr && (bLane === U(3, 2 bits)))
  // ---- 宽层权重的**趟瓦片 RAM**（按趟序的字节流；每趟 576 字节 = `[co_local][ci_local][ky][kx]`）----
  val wRam = Mem(Bits(8 bits), WGT_RAM_BYTES).init(Seq.fill(WGT_RAM_BYTES)(B(0, 8 bits)))
  // ★★ C4b-B1b：写口有**两条**通路 —— 主机信箱（区域 1，**调试/覆盖**口）与 DMA 装载器（**主路径**）。
  //   `wRam.write` 落在下面「C4b-B1b：宽通路的落点」那一节（那里 `wlWr`/`wlByte`/`wlWideDest` 都在
  //   作用域里；与各切片 `WeightStore` 写口同一套"DMA 优先"的仲裁口径）。

  // ---- 当前层参数（由 `LAYER_ID` 索引查表）----
  /** 描述符的 `LAYER_ID`（= 参数表下标；与信箱写入用的下标**同一真源**）。 */
  val layerIdx = dw.layerId
  /** ★★ C4b-B2：**参数表下标越界保护**（`LAYER_ID` == 参数表下标）。
    *   参数表深度 = `PN_LAYERS`（64）⇒ `LAYER_ID ≥ 64` 时 `mzBase = lid*8`（`mzRam` 只有 512 B）与
    *   `biasMem` 下标 `lid*64`（只有 4096 字）都会**回绕**⇒ **静默读到别的层**的 `M`/`z_pad`/`z_y`/`bias_adj`。
    *   本行把这条口径收敛到**唯一一处**（`go` 那一刻），三条通路（窄信箱 / 窄 DMA / 宽多趟）**共用**：
    *   越界 ⇒ **响亮 err + 零搬运**（绝不静默错值）。
    *   ★ 与 `wideGeomOk` 里那条 `layerIdx < PN_LAYERS` **逐字同式**（单一真源）—— 窄通路此前**缺**这一条。
    *   ★ 真表对账：53 个**有权重**的单元 `layer_id ≤ 60 < 64`（`≥64` 的三个是 `Sigmoid_109/117/125`，
    *     旁路算子、不进本单元的参数表）⇒ 对真帧**零影响**（既有闸门用的 `LID ≤ 8` 亦恒真）。 */
  val lidOk = layerIdx < U(PN_LAYERS, 8 bits)
  /** §4.4 每层 Q24 乘子；未装载时表里是 2^24（单位乘子 ⇒ 与 C3 同形）。 */
  val mzAw  = log2Up(PN_LAYERS * PSTRIDE)
  val mzBaseRd = ((layerIdx.resize(16) * U(PSTRIDE, 16 bits)) + U(0, 16 bits)).resize(mzAw bits)
  def mzRd(off: Int): Bits = mzRam.readAsync((mzBaseRd + U(off, mzAw bits)).resize(mzAw bits))
  // ★★ C4a-R2（2026-10-11）：参数表读出**寄存化**（表 1：`M` / `z_pad` / `z_y`）。
  //   为什么（板级 PnR 实测）：`mzRam` 是 LUTRAM（`readAsync` ⇒ 组合读 + 一族读出 mux）。它的
  //   读出网在 seed_0 的 `..._rtr` 里就是最坏 `cpu_clk` 路径上的两段：`ram64x1B/DO`（布线 0.973）
  //   → `mzRam_mux_b_126_..._perm/L7`（**net fanout=47**，布线 **2.239**）→ 直接落在
  //   `sliceRest_1/N349_m1` 的 APM 输入锥上。**一层的 `M/z_pad/z_y` 在整层内恒定** ⇒ 读出一拍寄存
  //   **不改变任何数值**（`go` 之后进入数据通路前的建码远早于第一次 requant），只是把乘法器输入
  //   从"LUTRAM 读出 + 47 扇出的 mux"换成"寄存器"。寄存器初值 = 表初值（单位元）⇒ 上电即等价。
  //   ★ `resetKind=SYNC`（R3-4）：寄存与表初值同相，无异步边沿问题。
  val mRRaw    = Cat(mzRd(3), mzRd(2), mzRd(1), mzRd(0))
  val zpadRRaw = mzRd(4)
  val zyRRaw   = mzRd(5)
  /** §4.4 每层 Q24 乘子（寄存；初值 = 2^24 单位乘子 ⇒ 不写信箱时与 C3 逐字节同形）。 */
  val mR    = RegNext(mRRaw)    init (B(16777216, 32 bits)); val mRB1 = (if (TILING) (0 until L_MAX).map(_ => RegNext(mR) init (B(16777216, 32 bits))) else Nil); val mRBm = (if (TILING) RegNext(mR) init (B(16777216, 32 bits)) else mR); // ★★ Y1-Timing：追加在行尾（行数中性）——requant M 的逐消费者再寄存（机理解释与实测见文件尾「Y1-Timing」节）
  /** §4.5 零填充码点（= 输入真实 0 的码点 `z_x`；寄存，初值 0）。 */
  val zpadR = RegNext(zpadRRaw) init (B(0, 8 bits))
  /** §4.5 输出零码点 `z_y`（寄存，初值 0）。 */
  val zyR   = RegNext(zyRRaw)   init (B(0, 8 bits))
  /** §4.5 每 (co-block, co) 的 `bias_adj`（字）；由装载器（`readSync`）在 `runStart` 后逐字读入。 */
  val biasReg = Vec(Reg(Bits(32 bits)) init B(0, 32 bits), NCOB_MAX * 8)
  // ★★ T-S1：**运行期行宽**（= `IMG_W·s` 的上界口径 = `inWMax`）—— `go` 那一刻闩存（见 `IDLE` 态），
  //   此后**一切计数/寻址**用它；**存储分配仍按展开期 `WIDTH`（= `W_MAX`）**。初值 1 只是"闩存前的
  //   占位"（子 FSM 只在 `go` 之后启动 ⇒ 这个值在语义上永远不会被读到；写成 1 而不是 0 是为了
  //   让"未闩存"时的回绕点 `rowW-1` 也是一个合法列号，避免任何 X/越界读的想象空间）。
  //   ★ 位置：**必须**在切片接线（`slices(i).io.rowW := rowW`，见下面 `for (i <- 0 until L_MAX)`）
  //     之前声明 —— Scala 的 class 体是**顺序求值**，前置引用会得到 `null`（SpinalHDL 报 `:= null`）。
  val rowW  = Reg(UInt(20 bits)) init (U(1, 20 bits))

  // ===========================================================================
  // ★★ T-S2R：**2-D tile 循环**的几何（只 `TILING=true` 的网表里有非平凡行为）
  // ===========================================================================
  //   口径（逐字，见 `reports/c4b_tiling_s2.md` §4.2 与 `reports/c4b_tiling2d.md` §1）：
  //     · tile 输出尺寸 = `WT = (WIDTH-2)/s`（列）× `HT = IMG_H_MAX`（行）—— `WIDTH-2` 是"物理行宽减
  //       左右各 1 列 halo"；`s=1` ⇒ `WT=WIDTH-2`，`s=2` ⇒ `WT=(WIDTH-2)/2`（`nCol=s·tw+2 ≤ WIDTH`）。
  //     · tile 网格：`oy0=ty·HT`、`ox0=tx·WT`、`oy1=min(oy0+HT, Ho)`、`ox1=min(ox0+WT, Wo)`；
  //       `th=oy1-oy0`、`tw=ox1-ox0`。
  //     · 输入窗口（**左闭右开精确感受野**，T-S0 钉死）：喂料起点 `Fy=s·(oy0-1)`、`Fx=s·(ox0-1)`，
  //       喂 `nRow=s·th+2` 行、`nCol=s·tw+2` 列。切片自身的上/左/右零填充落在被丢弃的那一圈
  //       （q=0 / j=0 / j=tw+1），保留 `q∈[1,th] × j∈[1,tw]`：
  //       切片输出第 `q` 行 ↔ 全局输出行 `oy0-1+q`、第 `j` 列 ↔ 全局输出列 `ox0-1+j`。
  //     · 越界的**真行/真列**由 gather 代以该算子的 pad 值（`z_pad`）。
  //   ★ `TILING=false` ⇒ 下面这些寄存器/组合量**不落任何数据通路**（只有 `isTiling` 恒假的死逻辑），
  //     既有网表逐字节不变。
  /** 编译期上限：`s=1` 时的 tile 输出宽 = `WIDTH-2`；tile 输出高 = `IMG_H_MAX`。 */
  val WT1 = WIDTH - 2
  val HT_TILE = IMG_H_MAX
  /** ★ 本档的 tile 循环**只在**窄通路 + 单单元 + 非头 + `s∈{1,2}` 上生效（`go` 那一刻判定）。 */
  val tilingShapeOk = if (TILING) (dw.cIn === U(C, 16 bits)) && (dw.cOut === U(C, 16 bits)) &&
                      (dw.group === U(GROUP, 8 bits)) && (dw.tpe =/= U(DescType.DW, 8 bits)) else False
  /** tile 网格的分辨率（运行期闩存）：层几何（`Wo/Ho`）+ 输入平面（`s·Wo × s·Ho`）+ tile 宽。 */
  val tS    = Reg(UInt(4 bits))  init (U(1, 4 bits))
  val tWo   = Reg(UInt(16 bits)) init (U(0, 16 bits))
  val tHo   = Reg(UInt(16 bits)) init (U(0, 16 bits))
  val tInWi = Reg(UInt(24 bits)) init (U(0, 24 bits))
  val tInHi = Reg(UInt(24 bits)) init (U(0, 24 bits))
  val tWT   = Reg(UInt(16 bits)) init (U(0, 16 bits))
  val tNtx  = Reg(UInt(16 bits)) init (U(0, 16 bits))
  val tNty  = Reg(UInt(16 bits)) init (U(0, 16 bits))
  /** 当前 tile 序号（`tTx` 列 / `tTy` 行）—— tile 循环的**唯一状态**；其余几何都是它的组合函数。 */
  val tTx   = Reg(UInt(16 bits)) init (U(0, 16 bits))
  val tTy   = Reg(UInt(16 bits)) init (U(0, 16 bits))
  /** tile 原点（全局输出坐标）与 tile 尺寸。 */
  val tOx0  = (tTx.resize(24) * tWT.resize(24)).resize(24)
  val tOy0  = (tTy.resize(24) * U(HT_TILE, 24 bits)).resize(24)
  val tTw   = Mux((tWo.resize(24) - tOx0) > tWT.resize(24), tWT.resize(24), (tWo.resize(24) - tOx0)).resize(16)
  val tTh   = Mux((tHo.resize(24) - tOy0) > U(HT_TILE, 24 bits), U(HT_TILE, 24 bits), (tHo.resize(24) - tOy0)).resize(16)
  /** 窗口起点（signed：`ox0=0` ⇒ `Fx=-s`，是 pad 环）。 */
  val tFx   = ((tOx0.resize(26).asSInt * tS.resize(26).asSInt) - tS.resize(26).asSInt).resize(26)
  val tFy   = ((tOy0.resize(26).asSInt * tS.resize(26).asSInt) - tS.resize(26).asSInt).resize(26)
  /** 窗口尺寸：`nCol = s·tw+2`、`nRow = s·th+2`。 */
  val tNCol = ((tS.resize(20) * tTw.resize(20)) + U(2, 20 bits)).resize(16)
  val tNRow = ((tS.resize(20) * tTh.resize(20)) + U(2, 20 bits)).resize(16)
  /** 切片**每行**出多少个像素 = `floor((nCol-1)/s)+1`（`s=1` ⇒ `nCol`；`s=2` ⇒ `nCol/2`）。 */
  val tOutPerRow = Mux(tS === U(1, 4 bits), tNCol,
                       (((tNCol.resize(20) - U(1, 20 bits)) >> 1).resize(16) + U(1, 16 bits)))
  /** 本 tile 的**输入平面高**（= `s·Ho`）与每行字节数（= `tInWi·C`）—— 行跨步窗口读的 pitch。 */
  val tRowBytes = (tInWi.resize(32) * U(C, 32 bits)).resize(32)
  /** 窗口里**落在输入平面内**的全局列区间 `[WinLo, WinHi)`（越界处 = pad）。 */
  val tFxEnd   = (tFx + tNCol.resize(26).asSInt).resize(26)
  val tWinLo   = Mux(tFx < S(0, 26 bits), U(0, 24 bits), tFx.resize(24).asUInt)
  val tWinHi   = Mux(tFxEnd > tInWi.resize(26).asSInt, tInWi,
                     Mux(tFxEnd < S(0, 26 bits), U(0, 24 bits), tFxEnd.resize(24).asUInt))
  /** 行跨步窗口读的**32 B 对齐**字节区间：像素列 `[tALo, tAHi)`（= 4 像素 = 32 B 粒度）。 */
  val tALo     = tWinLo & U(0xFFFFFC, 24 bits)                                   // 下对齐到 4 像素
  val tAHi     = ((tWinHi + U(3, 24 bits)) & U(0xFFFFFC, 24 bits)).resize(24)     // 上对齐到 4 像素
  /** 窗口里"是不是有真数据可读"（空 ⇒ 整行 pad、不发 RD）。 */
  val tWinHasData = tWinHi > tWinLo
  /** ★ tile WR 相位的行序号（0..tTh-1）；每 tile 回零。 */
  val tWrQ = Reg(UInt(16 bits)) init (U(0, 16 bits))
  /** tile 宽的**两个编译期候选**（`s=1` ⇒ `WIDTH-2`；`s=2` ⇒ `(WIDTH-2)/2`）与 go 那一刻的选择。 */
  val TWT1 = WIDTH - 2
  val TWT2 = (WIDTH - 2) / 2
  val tWTC = Mux(strideEff === U(2, 4 bits), U(TWT2, 16 bits), U(TWT1, 16 bits))

  /** `bias_adj` 装载器：把 `[LAYER_ID][cob][co]` 的 `n_co*8` 个字读进 `biasReg`（`readSync` 1 拍延迟）。 */
  val ldIdx  = Reg(UInt(10 bits)) init 0
  val ldBusy = Reg(Bool()) init False
  val ldEnd  = Reg(UInt(10 bits)) init 0
  val ldWord = biasMem.readSync(((layerIdx.resize(12) @@ U(0, 6 bits)).resize(12) + ldIdx.resize(12)).resize(log2Up(PN_LAYERS * NCOB_MAX * 8) bits))
  val ldIdxD = RegNext(ldIdx) init 0
  val ldV    = RegNext(ldBusy) init False

  // ===========================================================================
  // ★★ C4b-B1：**权重段从 DDR 批量装载**（DMA 主路径）—— 装载器本体 + 写口译码
  //   （文件头「C4b-B1」一节有完整口径；这里只重复三条最容易被读错的）
  //   · 段长 = `chainLen * NENTRY`（描述符几何**必须**与本网表展开期几何逐项相等 ⇒ `N_i == NENTRY`）；
  //   · 一笔连续 RD，按 `wlSlice/wlAddr` 逐字节灌：前 NENTRY 字节 -> 切片 0、再 NENTRY -> 切片 1 …；
  //   · 只在 `rd_valid` 那一拍**收**新拍（`wlTake`）、**段内**的字节逐拍落进 WeightStore ⇒ **读回的字节数恰好 == 段长**（判据 ② 的根据）。
  // ===========================================================================
  /** 本单元（一条链）要装载的总字节数 = `chainLen * NENTRY`（`chainLen ≤ 8`、`NENTRY` 是常量 ⇒ 小乘法）。 */
  val wgtLen = (io.chain_len.resize(32) * U(WGT_SEG, 32 bits)).resize(32)
  /** ★★ C4b-B1c：**每组的输入通道数** `cig = C_in/GROUP`（= blob 段长 `C_out*cig*9` 里的那个因子）。
    *   真表的 `GROUP ∈ {1, C_in}`（后者 = depthwise）⇒ 一次 2 选 1 覆盖两种几何，**不做除法**；
    *   其余 `GROUP` 由 `grpOkW` 在 `go` 那一刻**响亮拦住**（见下）。 */
  val cgW = Mux(dw.group === U(1, 8 bits), dw.cIn, U(1, 16 bits))
  /** ★★ C4b-B1c：`GROUP` 是否属于装载器认得的两种几何（`1` 或 depthwise `GROUP==C_in==C_out`）。 */
  val grpOkW = (dw.group === U(1, 8 bits)) || ((dw.group === dw.cIn) && (dw.cIn === dw.cOut))
  /** ★★ C4b-B1c：**宽层**权重段字节数 `N_i = C_out*(C_in/GROUP)*9`（= `wgt_index.json` 的 `bytes`）。
    *   `GROUP=1` ⇒ `C_out*C_in*9`（B1b 原式）；depthwise ⇒ `C_out*9`（每组只有一个输入通道）。
    *   与转换器 `y1_convert.py` 的 `n_i = co_*cg_*9` 同式。宽层恒 `chainLen==1` ⇒ 不乘链长。 */
  val wgtWideLen = (dw.cOut.resize(32) * cgW.resize(32) * U(9, 32 bits)).resize(32)
  /** ★★ C4b-B1c：宽层的 **RD 长度** = `ceil32(N_i)`（= B0 的 32 B 对齐 blob 里该段的 `aligned_bytes`）。
    *   `N_i%32!=0` 的单位（如真表 `Conv_0`：`N_i=432` → `448`）只有读整 32 B 才满足 DdrMaster 的 RD
    *   粒度（`len%32==0`，C3.3 契约，**未放宽**）；多读的那 ≤31 字节是**转换器补的 0**（B0），
    *   装载器**不写它们** ⇒ 写入字节数仍恰是 `N_i`（`wgtWrLenR`；判据②的分工）。 */
  val wgtWideRdLen = (((wgtWideLen + U(31, 32 bits)) >> 5) << 5).resize(32)
  /** ★★ C4b-B1b：**ci 方向的趟数** `nCi = ceil(C_in/8)`（边界 `C_in%8==0` 时 = `C_in/8`）。
    *   ★ 位置说明：本量原先只建在下面「宽层多趟编排」一节（那里的注释仍在）；B1b 把它**上移**到装载器
    *   之前 —— 落点 `pass = cob*nCi + cib` 要用它，两处必须是**同一真源**（`wPassIdx` 也用同一个 `nCi`）。 */
  val nCi = ((dw.cIn  + U(7, 16 bits)) >> 3).resize(16)
  /** ★★ C4b-B1c：**co 方向的趟数** `nCo = ceil(C_out/8)`。
    *   ★ 位置说明：B1b 时它只建在下面「宽层多趟编排」一节；B1c 的**零填充相位长度** `Z = nCi*nCo*576`
    *   要用它 ⇒ **上移到这里**，与 `nCi` 同一处真源（下面的旧定义已删）。 */
  val nCo = ((dw.cOut + U(7, 16 bits)) >> 3).resize(16)
  /** DMA 主路径的**开跑判定**（`IDLE`/`go` 那一刻组合判定，见文件头）：
    *  · `dmaEn`     —— 主机编程的段基址非 0（**0 = 未编程 ⇒ 关掉**，走旧信箱通路）；
    *  · `dmaGeomOk` —— 描述符几何与本网表展开期几何**逐项相等**（否则"段长 = 片内条目数"不成立）；
    *  · `dmaWinOk`  —— 段尾落在 28 bit DDR 窗内（否则主口地址**静默回绕**）。 */
  val dmaEn      = io.wgt_dma_addr =/= U(0, ddrCfg.ADDR_W bits)
  val dmaGeomOk  = (dw.cIn === U(C, 16 bits)) && (dw.cOut === U(C, 16 bits)) &&
                   (dw.group === U(GROUP, 8 bits)) && (dw.tpe =/= U(DescType.DW, 8 bits))
  val dmaWinOk   = (io.wgt_dma_addr.resize(33) + wgtLen.resize(33)).resize(33) <= U(DDR_BYTES, 33 bits)
  /** ★★ C4b-B1c：宽层的"段尾不越 28 bit DDR 窗"—— 用 **RD 长度** `ceil32(N_i)` 判（不是 `N_i`）。 */
  val dmaWinOkW  = (io.wgt_dma_addr.resize(33) + wgtWideRdLen.resize(33)).resize(33) <= U(DDR_BYTES, 33 bits)
  /** ★★ C4b-B1c：零填充相位的**长度** `Z = nCi*nCo*576`（= 本单元会读到的趟瓦片区间）。 */
  val wzEnd = (nCi.resize(32) * nCo.resize(32) * U(WGT_SEG, 32 bits)).resize(32)
  /** ★★ C4b-B1c：本单元**是否需要零填充** —— 真表的 padded 几何三类：
    *   · `C_in%8!=0`（如 `Conv_0`：3 输入通道 ⇒ 瓦片里 `cil ∈ [3,8)` 是"跳过通道"）；
    *   · `C_out%8!=0`（如 `Conv_54/60/72...`：`co_t<8` ⇒ 瓦片里 `cl ∈ [co_t,8)` 是空行）；
    *   · `GROUP!=1`（depthwise：跨组位置 + **非对角趟**整趟为 0）。
    *   `C_in%8==0 && C_out%8==0 && GROUP==1`（真表 14 个已覆盖几何）⇒ 不补零 ⇒ **一拍不加**。 */
  val wzNeedW = (dw.cIn(2 downto 0) =/= U(0, 3 bits)) || (dw.cOut(2 downto 0) =/= U(0, 3 bits)) ||
                (dw.group =/= U(1, 8 bits))
  /** 本拍写的是手上这一拍的**最后一道**（此刻可以同时把下一拍要进来）。 */
  val wlLastOfBeat = wlV && (wlIdx === U(ddrCfg.DATA_W / 8 - 1, 3 bits))
  /** **收拍**：只在"手上没有拍"或"正写最后一道"时向 DdrMaster 举 `rd_ready`（且必须真的有拍）。
    *   ★ 与"写不写"**解耦**：主口给了多少拍就收多少拍（`wlDone` 要求主口回 IDLE 才收工）——
    *     于是"表层把段长写大了 32 B"这种账不平**不会把主口挂住**，而是**多读出 32 B**
    *     （内存模型的计数看得见、设备侧 `wgt_bytes` 看不见 ⇒ 两处独立计数各抓各的）。 */
  val wlTake = wlRun && (!wlV || wlLastOfBeat) && ddrMaster.io.rd_valid
  /** 本拍吃掉一道：手上有拍、或本拍刚接到一拍。 */
  val wlConsume = wlRun && (wlV || wlTake)
  /** **落字节**：只有段内的字节才写进 WeightStore（段外的道只被丢弃，不写、也不推进片内地址）。
    *   ★★ C4b-B1c：上界用 **`wgtWrLenR`（真实段长 `N_i`）**而不是 RD 长度 —— 宽层的 RD 长度是
    *   `ceil32(N_i)`，多读的补位字节（转换器补的 0）**不写**（否则会写脏瓦片区间之外）。 */
  val wlWr = wlConsume && (wlCnt < wgtWrLenR)
  /** 本拍要写的字节：手上有拍 ⇒ 拍内第 `wlIdx` 道；手上没有 ⇒ 本拍刚接到的拍的第 0 道。 */
  val wlByte = Mux(wlV, wlHold(wlIdx), ddrMaster.io.rd_data(7 downto 0))
  /** 装载收工：段内字节全写完、且主口彻底回 IDLE（`rd_bytes` 到此为止）。 */
  val wlDone = wlRun && (wlCnt === wgtWrLenR) && !ddrMaster.io.busy
  /** ★★ C4b-B1c：宽通路的 `ci` 进位（下一行是不是本 co 的最后一行 / 下一行的 `ci` 是多少）。
    *   上界改成 **`cig-1`**（`GROUP=1` ⇒ `C_in-1`，与 B1b 逐字同；depthwise ⇒ `cig=1` ⇒ 恒为最后一行）。 */
  val wlCiLast = wlCi === (cgW - U(1, 16 bits))
  val wlCiNext = Mux(wlCiLast, U(0, 16 bits), (wlCi + 1).resize(16))

  // 注：`ddrMaster.io.rd_ready` 的**唯一**赋值点在生产侧逻辑那一段里（`wlTake || 激活读`；
  //     两条通路在时间上互斥：装载相位在 `WGTRUN`、激活读相位在 `RDRUN`）。
  when(wlWr) {
    wlCnt := wlCnt + 1
    when(wlWideR) {
      // ★★ C4b-B1b：宽通路 —— 指针按 **blob 序**（`[co][ci][tap]`，`tap` 最快）前进一格，
      //   落点由 `(co, ci, tap)` 算出（见下「宽通路的落点」）。这里有两条"进位链"：
      //     · `tap` 9 进制（0..8）⇒ 一行（一个 `(co,ci)`，9 字节）走完；
      //     · `ci` 每到 `dw.cIn` 回绕 ⇒ `co` +1。
      //   ★ 落点是 `(co, ci)` 的**函数**（不是"顺着走"的累加量）：blob 按 `co` 行主序扫，而趟瓦片是
      //     8×8 分块 ⇒ **同一个瓦片会被扫回来 8 次**（每个 `cl` 一次）⇒ 不能用"基址 += 576"那类累加。
      when(wlTap === U(8, 4 bits)) {
        wlTap := U(0, 4 bits)
        when(wlCiLast) {
          wlCi := U(0, 16 bits)
          when(wlCo === (dw.cOut - U(1, 16 bits))) { wlCo := U(0, 16 bits) }
            .otherwise { wlCo := (wlCo + 1).resize(16) }
        } otherwise { wlCi := wlCiNext }
      } otherwise { wlTap := (wlTap + 1).resize(4) }
    } otherwise {
      // 片内地址线性推进；写满 NENTRY ⇒ 换下一片（链上第 k 片拿 blob 里第 k 段）
      when(wlAddr === U(WGT_SEG - 1, waBits bits)) {
        wlAddr  := U(0, waBits bits)
        wlSlice := (wlSlice + 1).resize(selBits)
      } otherwise {
        wlAddr := (wlAddr + 1).resize(waBits)
      }
    }
  }
  when(wlTake) {                        // 接到新拍：整拍落进 wlHold
    for (j <- 0 until ddrCfg.DATA_W / 8) { wlHold(j) := ddrMaster.io.rd_data(j * 8 + 7 downto j * 8) }
    wlV   := True
    // ★ 下一道是谁，取决于本拍**手上有没有旧拍**（两档各吃掉一个字节，绝不重吃、绝不漏吃）：
    //   · `!wlV`（手上空着）：本拍吃掉的就是**新拍的第 0 道**（来自 `rd_data[7:0]`）⇒ 下一道 = 1；
    //   · `wlV`（正吃旧拍的第 7 道，见 `wlLastOfBeat`）：本拍吃的是**旧拍的第 7 道** ⇒
    //     下一道必须回到**新拍的第 0 道**（= 0）。★ 这一档若写成 1，就**整整漏掉每一拍的第 0 道**
    //     （实测：72 拍只写 509 字节 ⇒ 越攒越少、最后等不到第 576 字节而挂住）。
    wlIdx := Mux(wlV, U(0, 3 bits), U(1, 3 bits))
  } elsewhen(wlConsume && wlV) {        // 没接新拍 ⇒ 手上这一拍往前走一道
    when(wlLastOfBeat) { wlV := False; wlIdx := U(0, 3 bits) } otherwise { wlIdx := (wlIdx + 1).resize(3) }
  }
  // 收工（段内字节全写完 + 主口回 IDLE）⇒ 落下 `wlRun`，主 FSM 的 `WGTRUN` 据此进 `RDSTART`。
  //   ★ 本行在 FSM 之前 ⇒ `WGTLD` 那一拍的 `wlRun := True`（FSM 里，声明更靠后）优先级更高；
  //     两者也不冲突：`wlDone` 要求 `wlRun` 已为真，而 `WGTLD` 那一刻 `wlRun` 还是 0。
  when(wlDone) { wlRun := False }

  // ===========================================================================
  // ★★ C4b-B1b/B1c：**宽通路的落点**（同一个装载器，只换"落进哪个地址"；见文件头「C4b-B1b/B1c」）
  // ===========================================================================
  //   装载器永远按 **DDR 里的顺序**吃字节（blob 序 = `[co][ciLocal][tap]`，`ciLocal` 是**组内**下标）。
  //   落点（与 `multipass_ref.weight_tiles()` 的冻结口径逐字同源）：
  //     dest(co, ciLocal, tap) = pass*576 + cl*72 + cil*9 + tap，  pass = cob*nCi + cib
  //   其中 `cob = co/8`、`cl = co%8`、`cib = ci/8`、`cil = ci%8`，而 `ci`（全局输入通道）由
  //     `ci = gco*cig + ciLocal` 给出（`cig = C_in/GROUP`、`gco = co / (C_out/GROUP)`）。
  //   ★ 真表的两种几何（`grpOkW`）把它简化成一次**乘 0 或乘 1**：
  //     · `GROUP=1`（`cog=C_out`, `cig=C_in`）：`gco = 0` ⇒ `ci = ciLocal`（B1b 原式，逐字节不变）；
  //     · depthwise（`cog=cig=1`、`ciLocal` 恒 0）：`gco = co` ⇒ `ci = co` ⇒ 落点 = **对角位置**
  //       `cl == cil`（跨组位置由零填充相位补 0；非对角趟整趟 0）。
  //   ⇒ 一趟瓦片 = blob 里 8 条（`cl = 0..7`）**跨步 `C_in*9`** 的 72 字节行按 (co-block, ci-block) 重排。
  //   ★ 代价（明写）：`pass` 里有一个 `*(runtime nCi)`（与宽通路的 `wPassIdx = wCob*nCi + wCi`
  //     同一个量级），`ci` 里有一个 `*(runtime cig)`（乘 0 / 乘 1），其余是常数乘（576/72/9）。
  //     **不做除法**、不查表。
  /** ★★ C4b-B1c：当前字节的**组号** `gco`（`GROUP=1` ⇒ 恒 0；depthwise ⇒ `= co`）。 */
  val wlG      = Mux(dw.group === U(1, 8 bits), U(0, 16 bits), wlCo)
  /** ★★ C4b-B1c：当前字节的**全局输入通道号** `ci = gco*cig + ciLocal`。 */
  val wlCiReal = (wlG * cgW + wlCi).resize(16)
  /** 当前字节的**趟号** `pass = cob*nCi + cib`（`nCi` 是运行期量 ⇒ 一次乘法）。 */
  val wlWidePass = ((wlCo(15 downto 3).resize(16) * nCi) + wlCiReal(15 downto 3).resize(16)).resize(16)
  /** 宽通路的 `wRam` 字节落点（`wlWideR = 0` 时该表达式不被任何写口使用）。 */
  val wlWideDest = (wlWidePass * U(576, wRamAw bits) + wlCo(2 downto 0).resize(wRamAw) * U(72, wRamAw bits) +
                    wlCiReal(2 downto 0).resize(wRamAw) * U(9, wRamAw bits) +
                    wlTap.resize(wRamAw)).resize(wRamAw)
  /** 本拍由 **DMA 装载器**写 `wRam`（宽通路）。 */
  val wlWrWide = wlWr && wlWideR
  /** ★★ C4b-B1c：本拍由**零填充相位**写 `wRam`（把 `[0, Z)` 逐字节清 0；`wzGo=0` 时恒假）。 */
  val wlZeroWr = wzGo
  // 写口：主机信箱（区域 1，调试/覆盖口）／DMA 装载器（宽通路）／零填充相位 —— 三路仲裁，
  //   优先级 `零填充 > DMA > 信箱`（与各切片 `WeightStore` 的写口同一套"DMA 优先"口径）。
  //   ⇒ ① `WGT_BLOB_BASE != 0` 的宽层：DMA 是**主路径**、信箱是覆盖口（帧后改某一字节仍生效）；
  //      ② `WGT_BLOB_BASE == 0`（或窄层）时 `wlWrWide`/`wlZeroWr` 恒假 ⇒ 这一路**一字不动**
  //         （既有闸门逐字节不变）。
  wRam.write(Mux(wlZeroWr, wzCnt(wRamAw - 1 downto 0),
                 Mux(wlWrWide, wlWideDest, io.wgt_addr(15 downto 0))),
             Mux(wlZeroWr, B(0, 8 bits), Mux(wlWrWide, wlByte, io.wgt_data.asBits)),
             Mux(wlZeroWr, True, Mux(wlWrWide, True, io.wgt_we && (rgn === U(RGN_WRAM, 4 bits)))))

  // ---- ★ C3.16：权重信箱**扇出到全部 L_MAX 个切片**（每个切片一个 `sel===i` 比较）----
  //   地址与载荷全广播（同一份 `wgt_addr`/`wgt_data` 送到每一片），**只有** `we` 带一个相等的比较
  //   ⇒ 任一时刻最多一个切片的 `WeightStore` 被写。`i ≥ selBits` 不可能（`selBits = log2Up(L_MAX)`）
  //   ⇒ 每个切片都能被选中（`L_MAX=8` 时 8 片全部可达；旧的四套口在 i≥4 处 alias 到第 4 套）。
  //   ★ C4a.5b：只认**区域 0**（`rgn === 0`）⇒ 参数区域（1..5）的写不会误伤任何 `WeightStore`。
  //   ★ C4b-B1：写口现在是**两条通路或在一起** ——
  //     · 主机信箱（区域 0，`wgt_sel` 选片）—— **调试/覆盖**口；
  //     · DMA 装载器（`wlWr`，`wlSlice` 选片）—— **主路径**（`WGT_BLOB_BASE != 0` 时）。
  //   地址/载荷由 `Mux(wlWr, ...)` 选（DMA 优先）。两路同一拍落在**不同切片**上时各写各的；
  //   落在**同一片**上时 DMA 胜（那时主机写的是"同一个字节写同一个位置" ⇒ 可观测上无害，见文件头）。
  for (i <- 0 until L_MAX) {
    val mbWe = io.wgt_we && (rgn === U(RGN_WGT, 4 bits)) && (io.wgt_sel === U(i, selBits bits))
    val dmWe = wlWr && (wlSlice === U(i, selBits bits))
    slices(i).io.we    := mbWe || dmWe
    slices(i).io.waddr := Mux(wlWr, wlAddr, io.wgt_addr(waBits - 1 downto 0))
    slices(i).io.wdin  := Mux(wlWr, wlByte.asSInt, io.wgt_data)
    // ---- ★ C4a.5a/5b：`Conv3x3Slice` 的多趟累加口 + §4.5 零填充码点 ----
    //   ★ C4a.5b：`M`/`z_y`/`pad_val` 现在**由参数表按 `LAYER_ID` 给出**（§4.4/§4.5 的投递落点）。
    //     窄通路（`ps_in = bias = 0`、单趟）在**不写信箱参数**时读到单位元 ⇒ 与 C3 逐字节同形
    //     （见 `mzRam` 的初值与 `mR/zpadR/zyR` 的复位值）。
    slices(i).io.requant_m := (if (TILING) mRB1(i).asUInt else mR.asUInt) // §4.4 每层 Q24 乘子（默认 2^24）；★ Y1-Timing：TILING 档换逐片再寄存的本地副本
    slices(i).io.zero_y    := zyR.asSInt                      // §4.5 每层 z_y（默认 0）
    slices(i).io.pad_val   := zpadR.asSInt                    // §4.5 零填充码点（默认 0）
    slices(i).io.stride    := strideEff                      // ★★ C4b-D1：描述符 `STRIDE`（0 视作 1 ⇒ 旧行为）
    slices(i).io.rowW      := rowW.resize(16)                 // ★★ T-S1：运行期行宽（additive 16 位口；分配仍按 WIDTH；喂 WIDTH ⇒ 同形）
    for (co <- 0 until C) {
      slices(i).io.ps_in(co) := S(0, (if (TILING) 32 else 64) bits)   // 窄通路无部分和载入（等价"第 1 趟"；★ §3.7 宽度随 `PSW`）
      slices(i).io.bias(co)  := biasReg(co).asSInt               // §4.5 每层每通道 bias_adj（默认 0）
    }
  }

  // DescWords 已在上面（参数块之前）一次性建好（`val dw`）。

  // ---------------------------------------------------------------------------
  // ★ A-1b：链长**是入参**（不再译自 `FLAGS[4:2]`）+ 两位 FLAGS 的 per-operator 语义
  // ---------------------------------------------------------------------------
  /** 头分支判定：`FLAGS.bit0 == OUT_TO_DDR == 0` ⇒ **切片0 的输出留在片上**（不落 `outMem`/DDR）。
    * ★ A-1b：链描述符取**链首条目**的 FLAGS ⇒ 一条链上恒为 1（头在片上）。 */
  val isHead = dw.head
  /** 本拍 `FLAGS[1:0]`（per-operator 编码：`00` head / `01` plain / `10` middle / `11` tail）。 */
  val flagsLo = dw.flags(1 downto 0)
  /** `FLAGS[7:2]` 保留位（A-1b：**必须为 0**；非 0 ⇒ `go` 那一刻响亮 `err` + 零搬运）。 */
  val flagsReserved = dw.flags(7 downto 2) =/= U(0, 6 bits)
  /** ★ A-1b：链长 = **调度器给的独立入参**。 */
  val chainLen = io.chain_len
  /** 本次 `go` 有没有"尾"（= 链里最后一片落 DDR）——A-1a 译自 `FLAGS.bit1`，A-1b 直接由链长给出：
    *   `chainLen ≥ 2` ⟺ 链里除了链首还有下游切片 ⇒ 末切片写 `outMemT` -> DDR。
    *   （链描述符的 FLAGS 取链首条目 ⇒ `bit1=0`，所以"有没有尾"**只能**从链长来，这正是 A-1b 的改动点。） */
  val hasTail = chainLen >= U(2, 16 bits)
  /** 链合法性（`go` 那一刻对账，不合 ⇒ **响亮 err + 零搬运**）：
    *   · `chainLen ∈ [1, L_MAX]`（链长不得越过本网表的切片数 —— "链长与生成参数不符"的响亮失败）；
    *   · `FLAGS[7:2] == 0`（保留位，A-1b 明写；非 0 ⇒ err）。
    *   ★ 本单元**不**校验 `FLAGS[1:0]` 与链长的组合是否"表上合法"（head+middle*+tail 的结构检查
    *     是调度器 `LayerSched` 的职责，它扫得见表）；本单元只认"链长 + 链描述符"这两个入参。
    *     于是"把链首的 `bit0` 强行置 1"这种**退化档**（`!isHead && chainLen≥2`：切片0 的中间也落 DDR）
    *     在这里是**可运行**的 —— 它正是 `run_chain_ab.sh`/`run_fuse_ab.sh` 的负对照装置面。 */
  val chainOk = (chainLen =/= U(0, 16 bits)) && (chainLen <= U(L_MAX, 16 bits)) && !flagsReserved &&
                strideChainOk   // ★ C4b-D1：`stride > 1` 只支持单单元（多片链的中间几何逐片变，本版不推）

  // 自报（常量）
  io.imgC  := U(C, 16 bits)
  io.imgW  := U(WIDTH, 16 bits)
  io.grp   := U(GROUP, 4 bits)
  io.shift := U(SHIFT, 8 bits)
  io.maxPix := U(MAXPIX, 16 bits)
  io.chain_len_rep := chainLen
  io.lmax    := U(L_MAX, 16 bits)

  // ---------------------------------------------------------------------------
  // 全部寄存器先声明（Scala 的 class 体是**顺序求值**：任何在工作里被引用的 val 必须在前面已建好）
  // ---------------------------------------------------------------------------
  val state = Reg(UnitExecPhase()) init UnitExecPhase.IDLE
  val doneR = Reg(Bool()) init False
  val errR  = Reg(Bool()) init False
  /** ★★ T-S1：**行宽口径统一在一处** —— `rowWUse`：
    *   · `state === IDLE`（= `go` 那一刻**同一拍**）：用**描述符现算**的 `inWMax`
    *     （`rowW` 寄存器此刻还是上一次的值、本拍才被闩上）⇒ `go` 那一刻的 `32 B 粒度`对账用的是**本次**几何；
    *   · 其余时刻（子 FSM 已在跑）：用**闩存的** `rowW` —— 这就是"此后所有寻址/计数都用运行期行宽"。
    *   `s=1` 且 `WIDTH == IMG_W` ⇒ 两者恒相等 ⇒ 与改动前**逐字同值**。 */
  val rowWUse = Mux(state === UnitExecPhase.IDLE, inWMax, rowW).resize(32)
  /** ★★ T-S1：运行期**行末列号** `rowW - 1`（列回绕点；`rowW == WIDTH` ⇒ 与旧的展开期常量同值）。 */
  val rowWm1  = (rowW - U(1, 20 bits)).resize(cw)
  /** ★★ T-S1：运行期行宽的**观察口**（零逻辑：只是把闩存值引出去；见 `io.row_w` 的注释）。 */
  io.row_w := rowW

  val mMode = Reg(UInt(2 bits)) init (1)
  val mSrc  = Reg(UInt(ddrCfg.ADDR_W bits)) init (0)
  val mDst  = Reg(UInt(ddrCfg.ADDR_W bits)) init (0)
  val mLen  = Reg(UInt(32 bits)) init (0)

  // 输入生产侧：pwant = 下一个要写进 `bufs(0)` 的行号（0..IMG_H）；pcol = 该行内的列。
  val pwant = Reg(UInt(16 bits)) init (0)
  val pcol  = Reg(UInt(cw bits)) init (0)

  // 每切片消费侧：cRow/cCol = 正在读的行/列；cst = 子 FSM；cdone = 已读完的行数（= read(i)）。
  val cRow  = Vec.fill(L_MAX)(Reg(UInt(16 bits)) init (0))
  val cCol  = Vec.fill(L_MAX)(Reg(UInt(cw bits)) init (0))
  val cst   = Vec.fill(L_MAX)(Reg(UnitExecCons()) init (UnitExecCons.WAIT))
  val cdone = Vec.fill(L_MAX)(Reg(UInt(16 bits)) init (0))

  // 每切片输出侧：ocol(i) = 输出**行内列**（0..WIDTH-1；行末那拍拉目标缓冲的 wr_row_adv）。
  val ocol = Vec.fill(L_MAX)(Reg(UInt(cw bits)) init (0))
  // ★ C3.18 R3-6：每切片一份的 `prime` **寄存器化副本**（见下"每切片相位复位"一节；把
  //   原来那一张扇出 17,617 的 `runStart` 广播拆成 8 张片内网）。
  val primeR = Vec.fill(L_MAX)(Reg(Bool()) init (False))
  // 每缓冲写进度：wroteB(b) = 已写进 `bufs(b)` 的行数（b=1..L_MAX-1；含注入的 pad 行）。wrote(0)=pwant。
  val wroteB = Vec.fill(L_MAX)(Reg(UInt(16 bits)) init (0))
  // 每缓冲 pad 注入子状态（中间缓冲 b=1..L_MAX-1 的下边零填充行）。
  val padGo   = Vec.fill(L_MAX)(Reg(Bool()) init False)
  val padCol  = Vec.fill(L_MAX)(Reg(UInt(cw bits)) init (0))
  val padDone = Vec.fill(L_MAX)(Reg(Bool()) init False)

  // 输出侧：pixIdx = 切片0 已产出的像素数（`outMem` 的写序号）；pixIdxT = **末切片**已产出的像素数
  //   （`outMemT` 的写序号）；ri = WR 相位的读序号。
  val pixIdx  = Reg(UInt(32 bits)) init (0)
  val pixIdxT = Reg(UInt(32 bits)) init (0)
  val ri      = Reg(UInt(32 bits)) init (0)
  // per-run 锁存（观察/对账；不参与数据通路）
  val headR   = Reg(Bool()) init False
  val tailR   = Reg(Bool()) init False
  val chainR  = Reg(UInt(16 bits)) init (1)

  // ---------------------------------------------------------------------------
  // 长度：RD 用描述符的 w6（`IN_BYTES`）；WR 用几何算 `IMG_W*IMG_H*C_OUT`（S2 二者相等）。
  // ---------------------------------------------------------------------------
  val rdLen = dw.inBytes
  // ★ C4b-D1：步长/输入几何已在上面的「C4b-D1」块里算好（`strideEff`/`inRows`/`inRowsP1`/`inWOk`）。
  /** 输出像素数（= 描述符 `IMG_H × IMG_W` —— `_geom` 取的就是**输出**张量的几何 ⇒ 与步长无关）。 */
  val pixTotal = (dw.imgH * dw.imgW).resize(32)
  val hWords  = Mux(isHead, U(0, 32 bits), pixTotal)
  //   ★ A-1b：第二项由 `hasTail`（= `chainLen ≥ 2`）给，**不再**用 `FLAGS.bit1`（见上面 decode 一节）。
  val nImg    = Mux(isHead, U(0, 32 bits), U(1, 32 bits)) + Mux(hasTail, U(1, 32 bits), U(0, 32 bits))
  val wrTotal = pixTotal * nImg
  val wrLen = (wrTotal * U(C, 32 bits)).resize(32)
  val hPlus1 = inRowsP1    // ★ C4b-D1：= `IMG_H·s + 1`（`s=1` ⇒ `IMG_H+1`，与改动前同值）

  /** 描述符入参对账（**在发第一个 AR 之前**）：QUANT_SHIFT 必须 == 本网表展开期的 SHIFT。 */
  val qShiftOk = dw.qShift === U(SHIFT, 8 bits)

  // ---------------------------------------------------------------------------
  // 生产侧（DDR -> bufs(0)）：★ T-S2R 起有**两条路** ——
  //   · 非 tiling（`tilingR=0`，既有窄通路）：整层一笔 RD + 行锁步（**逐字节不变**）；
  //   · tiling（`tilingR=1`）：**每窗口行一笔 32 B 对齐的行跨步窗口读**（见下面"tile 生产者"）。
  //   `TILING=false`（既有网表）⇒ `tilingShapeOk` 恒假 ⇒ `tilingR` 恒 0 ⇒ 下面那条路**从不激活**。
  // ---------------------------------------------------------------------------
  val inRun    = state === UnitExecPhase.RDRUN
  val beatNow  = ddrMaster.io.rd_valid && ddrMaster.io.rd_ready
  /** ★★ T-S2R：本层是否走 **tile 循环**（`go` 那一刻闩存；`TILING=false` ⇒ 恒 0 ⇒ 既有行为）。 */
  val tilingR  = Reg(Bool()) init False
  /** ★★ T-S2R：**go 那一刻**判定"本层能不能走 tile 循环"（`TILING` + 窄通路 + 单单元 + 非头 +
    *   `s∈{1,2}` + `IMG_W%4==0`（WR/行读的 32 B 对齐；`tInWi%4==0` 与 `tTw%4==0` 的充分条件））。 */
  val tilingS  = (strideEff === U(1, 4 bits)) || (strideEff === U(2, 4 bits))
  val tilingOkC = tilingShapeOk && tilingS && (chainLen === U(1, 16 bits)) && !isHead &&
                  (dw.imgW(1 downto 0) === U(0, 2 bits)) && (dw.imgW =/= U(0, 16 bits)) && (dw.imgH =/= U(0, 16 bits))
  // ---- 非 tiling：既有的"整层一笔 RD + 行锁步" ----
  val rowIsDdr = pwant < inRows
  /** 允许写第 pwant 行 <=> 切片0 已读完 0..pwant-1 行（对 bufs(0) 的行锁步）。 */
  val mayWrite = inRun && (pwant <= inRows) && (cdone(0) >= pwant)
  val wrNow    = mayWrite && Mux(rowIsDdr, beatNow, True)

  // ===========================================================================
  // ★★ T-S2R：**tile 生产者** —— 窗口行 `pwant` × 窗口列 `pcol`（行跨步窗口读 + pad 合成）
  // ===========================================================================
  //   逐窗口行（`pwant = 0..tNRow-1`）：
  //     · 全局输入行 `iy = Fy + pwant`；`iy ∉ [0, tInHi)` 或窗口无真数据 ⇒ **整行 pad**（不发 RD）；
  //     · 否则发**一笔 32 B 对齐的行跨步窗口读**：`src = srcA + iy·tRowBytes + aLo·C`、
  //       `len = (aHi-aLo)·C`（一个像素一拍、共 `aHi-aLo` 拍）；
  //     · 逐窗口列 `pcol = 0..tNCol-1`：全局列 `g = Fx + pcol`。
  //          - `g ∉ [WinLo, WinHi)` ⇒ 写**列 pad**（`z_pad`），不吃拍；
  //          - `g ∈ [WinLo, WinHi)` ⇒ 先丢**前缀拍**（`tBcol < g`），再把该拍（= 全局列 `g` 的像素）
  //            写进 `bufs(0)`；
  //       → 全部列写完后再把**后缀拍**排空（`tBcol → aHi`），等主口回 IDLE 才换下一行。
  //   行锁步：起第 `pwant` 行 <=> 切片0 已读完 0..pwant-1 行（`cdone(0) >= pwant`）。
  //   ★ `tilingR=0` ⇒ 本子 FSM 停在 0、所有驱动为假 ⇒ 上面那条既有路**逐字节不受影响**。
  val tPSt   = Reg(UInt(3 bits)) init 0     // 0=DECIDE / 1=EMIT / 2=DRAIN / 3=ROWDONE / 4=PADROW
  val tBcol  = Reg(UInt(24 bits)) init 0    // 下一拍要收的**全局列**
  val tRowIY   = (tFy + pwant.asSInt.resize(26)).resize(26)   // 本窗口行的全局输入行
  val tRowReal = (tRowIY >= S(0, 26 bits)) && (tRowIY < tInHi.resize(26).asSInt) && tWinHasData
  /** 行跨步窗口读的字节起址/长度（该窗口行恒定）。 */
  val tRowBase = (dw.srcA.resize(33) + (tRowIY.resize(32).asUInt * tRowBytes).resize(33) +
                  (tALo << 3).resize(33)).resize(32)
  val tRowLen  = ((tAHi - tALo) << 3).resize(32)
  /** 当前窗口列对应的全局列 `g`（signed）。
    *   ★ 必须 `pcol.resize(26).asSInt`（**先零扩再当有符号**）：`pcol` 是 `cw` 位 UInt，直接 `.asSInt`
    *     会把第 5 位当符号位 ⇒ `pcol ≥ 2^(cw-1)` 时变成负数（实测 `pcol=32 → -32`，把窗口右沿的
    *     2 列判成 pad ⇒ tile 每行最后 2 列错）。 */
  val tGCol   = (tFx + pcol.resize(26).asSInt).resize(26)
  val tGInWin = (tGCol >= tWinLo.resize(26).asSInt) && (tGCol < tWinHi.resize(26).asSInt)
  val tRowDone = tilingR && inRun && (tPSt === U(3, 3 bits))
  /** ★ 收拍三态**都必须**带上 `rd_valid`：`tBcol` 是"已收的拍数"，若在拍没到时也自增，
    *   计数就会与主口实际推的拍数**脱节** ⇒ 提前停手 ⇒ 主口永远 `!done`、整帧挂死（实测）。 */
  val tProdTake = tilingR && inRun && (tPSt === U(1, 3 bits)) && tGInWin &&
                  (tBcol === tGCol.resize(24).asUInt) && ddrMaster.io.rd_valid
  val tProdDiscard = tilingR && inRun && (tPSt === U(1, 3 bits)) && tGInWin &&
                  (tBcol < tGCol.resize(24).asUInt) && ddrMaster.io.rd_valid
  val tDrainBeat = tilingR && inRun && (tPSt === U(2, 3 bits)) && ddrMaster.io.rd_valid
  val tRdReady = tProdDiscard || tProdTake || tDrainBeat
  /** tile 生产者向 bufs(0) 的写（pad 列 OR 真列）。 */
  val tProdWrEn = tilingR && inRun && (
      ((tPSt === U(1, 3 bits)) && (!tGInWin || tProdTake)) ||
      (tPSt === U(4, 3 bits)))
  val tProdWrPad = (tPSt === U(4, 3 bits)) || ((tPSt === U(1, 3 bits)) && !tGInWin)
  val tProdWrAdv = tProdWrEn && (pcol === (tNCol.resize(cw) - U(1, cw bits)))
  /** 本拍给本窗口行**发起一笔行跨步窗口读**（主口空闲 + 行锁步满足 + 本行是真行）。 */
  val tRowStartNow = tilingR && inRun && (tPSt === U(0, 3 bits)) && tRowReal && (cdone(0) >= pwant) &&
                     (pwant =/= tNRow) && (!ddrMaster.io.busy)
  when(tilingR && inRun) {
    switch(tPSt) {
      is(U(0, 3 bits)) {                                    // DECIDE
        when(cdone(0) >= pwant) {
          when(pwant === tNRow) { tPSt := U(0, 3 bits) }     // 全部窗口行已喂完（runDone 收工）
            .elsewhen(tRowReal && !ddrMaster.io.busy) { tPSt := U(1, 3 bits); tBcol := tALo; pcol := U(0, cw bits) }
            .elsewhen(!tRowReal) { tPSt := U(4, 3 bits); pcol := U(0, cw bits) }
        }
      }
      is(U(1, 3 bits)) {                                    // EMIT 窗口列
        when(pcol === tNCol.resize(cw)) { tPSt := U(2, 3 bits) }
          .otherwise {
            when(tProdDiscard) { tBcol := (tBcol + 1).resize(24) }
              .elsewhen(tProdTake) { tBcol := (tBcol + 1).resize(24); pcol := (pcol + 1).resize(cw) }
              .elsewhen(!tGInWin) { pcol := (pcol + 1).resize(cw) }
          }
      }
      is(U(2, 3 bits)) {                                    // DRAIN：把本行 RD 的**余拍排空** → 等主口回 IDLE
        //   ★ 判据用 `!busy`（不是拍数）：`DdrMaster` 的 `done` 之后才回 IDLE ⇒ 这里只在**主口彻底空闲**
        //     才换行；`rd_ready` 由 `tDrainBeat`（`rd_valid` 门控）给 ⇒ 余拍一定被收干净、计数不脱节。
        when(!ddrMaster.io.busy) { tPSt := U(3, 3 bits) }
      }
      is(U(3, 3 bits)) {                                    // ROWDONE
        tPSt := U(0, 3 bits); pwant := (pwant + 1).resize(16); pcol := U(0, cw bits)
      }
      is(U(4, 3 bits)) {                                    // PADROW：整行 pad（不吃拍）
        when(pcol === tNCol.resize(cw)) { tPSt := U(3, 3 bits) }
          .otherwise { pcol := (pcol + 1).resize(cw) }
      }
      default { }
    }
  }

  // ---------------------------------------------------------------------------
  // 输出存储（Cat 的**第一个元素落最低位** ⇒ co=0 在 [7:0]，与 wr_data 小端口径一致）
  // ---------------------------------------------------------------------------
  val yWord = Cat((0 until C).map(co => conv.io.y(co).asBits))
  val outMem  = Mem(Bits(C * 8 bits), MAXPIX).init(Seq.fill(MAXPIX)(B(0, C * 8 bits)))
  val riW = log2Up(MAXPIX)
  //   ★ 头模式（`isHead`）下切片0 的输出**改道**进中间缓冲、**不落**这个片上输出存储（`!isHead` 挡住）。
  //     退化档/退化链（`bit0=1`）下 `!isHead` 为真 ⇒ 切片0 的中间张量**落 DDR**（负对照要的就是"中间落 DDR"）。
  //   ★★ T-S2R：tiling 下只**保留** `q∈[1,th] × j∈[1,tw]` 的像素（其余 = 被丢弃的 halo 环），
  //     且按 **tile 内局部序** `(q-1)·tw + (j-1)` 存（WR 相位按行写回 DDR 的 tile 位置）。
  val oColT  = Reg(UInt(16 bits)) init 0     // 本输出行内的切片像素序号（0..tOutPerRow-1）
  val oRowT  = Reg(UInt(16 bits)) init 0     // 输出行序号（0..tNRow-2）
  val tPixIdx= Reg(UInt(32 bits)) init 0     // tile 内**保留像素**计数（收工判据）
  val tKeep  = (oRowT >= U(1, 16 bits)) && (oRowT <= tTh) && (oColT >= U(1, 16 bits)) && (oColT <= tTw)
  val tOutIdx = (((oRowT - U(1, 16 bits)) * tTw) + (oColT - U(1, 16 bits))).resize(riW)
  outMem.write(Mux(tilingR, tOutIdx, pixIdx(riW - 1 downto 0)), yWord,
               conv.io.y_valid && !isHead && Mux(tilingR, tKeep, True))
  when(conv.io.y_valid && tilingR) {           // 切片输出流：行内列号推进、行末回绕
    tPixIdx := tPixIdx + Mux(tKeep, U(1, 32 bits), U(0, 32 bits))
    when(oColT === (tOutPerRow - U(1, 16 bits))) { oColT := U(0, 16 bits); oRowT := (oRowT + 1).resize(16) }
      .otherwise { oColT := (oColT + 1).resize(16) }
  }

  // ---- 末切片 -> `outMemT`：末切片随 `chainLen` 变（chainLen==2 -> 切片1；==3 -> 切片2；==4 -> 切片3）----
  def yWordOf(i: Int): Bits = Cat((0 until C).map(co => slices(i).io.y(co).asBits))
  def outTCond(i: Int): Bool = chainLen === U(i + 1, 16 bits)
  // 以 chainLen==2（切片1）为默认；更高 chainLen 覆盖（chainLen 是单值 ⇒ 只有一个条件为真）。
  var outTSel: Bits = yWordOf(if (L_MAX >= 2) 1 else 0)
  var outTEn:  Bool = if (L_MAX >= 2) slices(1).io.y_valid else False
  for (i <- 2 until L_MAX) {
    outTSel = Mux(outTCond(i), yWordOf(i), outTSel)
    outTEn  = Mux(outTCond(i), slices(i).io.y_valid, outTEn)
  }
  val outMemT = Mem(Bits(C * 8 bits), MAXPIX).init(Seq.fill(MAXPIX)(B(0, C * 8 bits)))
  outMemT.write(pixIdxT(riW - 1 downto 0), outTSel, outTEn)

  // WR 相位的读出：先流切片0 那张（若头落 DDR），再流末切片那张。
  val idxH = Mux(ri < hWords, ri(riW - 1 downto 0), U(0, riW bits))
  val idxT = Mux(ri < hWords, U(0, riW bits), (ri - hWords)(riW - 1 downto 0))
  val rdWord = Mux(ri < hWords, outMem.readAsync(idxH), outMemT.readAsync(idxT))

  // ===========================================================================
  // ★★ C4a.5b：**宽层多趟编排**（`C_in>8 || C_out>8`）—— 本单元驱动 `MultiPassUnit`
  // ===========================================================================
  // 数据流（逐字沿用 C4a.5a 的冻结口径，见 `MultiPassUnit.scala` / `PartialSumBuf.scala` 文件头）：
  //   for co-block j = 0..n_co-1:                // n_co = ceil(C_out/8)
  //     for ci-block i = 0..n_ci-1:              // n_ci = ceil(C_in/8)
  //       ① 预载该趟的权重瓦片（`[8co][8ci][ky][kx]`，SKIP 通道/跨组位置填真零码 z_w = 0）
  //          源 = **趟瓦片 RAM `wRam`**（主机经信箱**区域 1**按趟序灌入）
  //       ② 脉冲 `mpu.start`（复位切片相位 + 把部分和读地址指回本段像素 0）
  //       ③ 喂 `(H+1)×W` 列：前 `H` 行来自 `wide_x` 列流，**第 H 行由本单元合成 = `z_pad`**（§4.5）；
  //       ④ `i == n_ci-1` 的 `mpu.y` 才是该 co-block 的成品 ⇒ 收进 `wOutMem[pix*NCOB + cob]`；
  //          其余趟的 `y` 是"只累加了一半"的中间值 ⇒ **丢弃**（与 C4a.5a 的 TB 同口径）。
  //   ⇒ 跨 `ci` 趟的累加在 `MultiPassUnit` 内部的 `PartialSumBuf`（块 RAM、**上电初值 0**）里自然成立；
  //     **唯一一次 requant**（§4.4 的 `((acc·M)>>24)>>6 + z_y`）由切片的出料口做，`M/z_y` 来自参数表。
  //   ⇒ 参数（`M / z_pad / z_y / bias_adj`）**全部经信箱按 `LAYER_ID` 投递**（见上面参数块）。
  //   ★ 口径（明写）："DDR → ci-block 平面布局"的 **gather** 与"权重 blob 从 DDR"是 **C4b（G6）** 项；
  //     本片把"参数经信箱 + 多趟累加 + 单次 requant + pad=z_pad"这条**已接线**的通路逐字节证掉。
  //   ★★ C4b-B1c：`nCo = ceil(C_out/8)` 已**上移**到装载器一节（零填充相位 `Z = nCi*nCo*576` 要用它）。
  /** ★★ C4b-C3：**窄通路可表示的几何** —— 与窄通路的 DMA 前提 `dmaGeomOk` **逐项同式**
    *   （`C_in==C==8 ∧ C_out==C==8 ∧ GROUP==1 ∧ 非 depthwise`）⇒ 单一真源，路由与窄通路绝不走岔。 */
  val narrowShape = (dw.cIn === U(C, 16 bits)) && (dw.cOut === U(C, 16 bits)) &&
                    (dw.group === U(GROUP, 8 bits)) && (dw.tpe =/= U(DescType.DW, 8 bits))
  /** 宽层判定（★ C4b-C3 起**按几何**收紧，不再只按"通道数 > 8"）：
    *   **只有** `C_in==8 ∧ C_out==8 ∧ GROUP==1 ∧ 非 depthwise`（= 窄通路能表示的那个形状）走**窄通路**；
    *   其余一律走**宽通路** —— 含 `C_in<8`（真表 `C=1` / `Conv_0` 的 3 通道：靠 B1c 的**零填补**）、
    *   `C_out<8`（真表 `C=1/4`：靠 C1 的**部分 co-block 尾块**）、depthwise（靠 C2 的**对角趟**）。
    *   ★ 为什么必须这样分：窄通路 `WeightStore` 是 **8x8 固定形状**（`NENTRY = C*(C/GROUP)*9`）⇒
    *     `C ∈ {1,4}` 的层**根本装不进去**（§11.7-3）；而宽通路这三条几何 B1c/C1/C2 都已端到端逐字节证死。
    *   ★ 真不支持 / 越界的几何（`GROUP ∉ {1,C_in==C_out}`、`C_in==0`、`IMG_W!=WIDTH`、
    *     `C_out==0`、`C_out>8*NCOB_MAX`、链长≠1、`H*W%8!=0`）仍由 `wgtLoadOk`/`wideGeomOk`/
    *     `dmaGeomOk` 在 `go` 那一刻**响亮 err + 零搬运**（绝不静默算错）。 */
  val isWide = !narrowShape
  /** ★★ C4b-C2：**depthwise**（真表 `0x03`，冻结口径 `GROUP == C_in == C_out`，且 `GROUP > 1`）。
    *   与之**同一真源**的是装载器前提 `grpOkW` 的 depthwise 分支（本行与它取同式）；
    *   `GROUP==1`（dense）⇒ 本行假 ⇒ 宽通路**逐字节不变**（见下方"宽层多趟编排"与 FSM）。
    *   ★ 为什么 depthwise 的趟调度必须是**对角**（`MultiPassUnit`/`DwUnit` 的冻结口径，C4a.6）：
    *   `cig = C_in/GROUP = 1` ⇒ 每组只有一个输入通道 ⇒ 全局 `ci = co` ⇒ 第 `b` 个 co-block 的
    *   非零权重只落在第 `b` 个 ci 的瓦片上（`cl == cil`）。**非对角趟的瓦片整趟为 0**（零填充相位补的 0）
    *   ⇒ 它们对部分和的贡献恰为 0。于是"**对角趟**（co-block b 只吃 ci-block b，一趟即成品）"
    *   与"一般趟（全组合跨趟累加，末趟收集）"在整数加法下**逐字节等价**（C4a.6 已在单元级证死；
    *   本片把它接到集成宽通路上）。★ 对角趟的**代价/收益**：趟数 `nCo` 而非 `nCo*nCi`
    *   （`C=64` ⇒ 8 趟 vs 64 趟）、输入列流少喂 `nCi` 倍；**判据是数值/字节与结构，不是性能**。 */
  val isDwW = (dw.group =/= U(0, 8 bits)) && (dw.group === dw.cIn) && (dw.cIn === dw.cOut)
  /** ★★ C4b-C1：宽层几何合法 —— `IMG_W == WIDTH`、`LAYER_ID < PN_LAYERS`、`chainLen==1`、
    *   `H*W % 8 == 0`（8 B 拼装），以及"输出通道数可寻址"：**`0 < C_out ≤ 8*NCOB_MAX`**。
    *   ★ 与 C4a.5b/B1c 的差别（本任务）：**不再要求 `C_out % 8 == 0`** —— 末 co-block 允许是
    *     **部分尾块**；WR 相位按 `C_out*H*W` 出料 ⇒ 只写前 `C_out` 行（见下方"宽层输出行数"）。
    *   ★ **仍是响亮 err**（`go` 那一刻 `err` + 零搬运）的两条边界（"真不支持"的几何，绝不静默）：
    *     · `C_out == 0` —— 没有输出通道；
    *     · `C_out > 8*NCOB_MAX` —— 输出存储 `wOutMem` 按 `PIXW*NCOB_MAX` 字分配，越界的 co-block
    *       会**地址回绕**踩到别的 co-block（静默错值）⇒ 必须拦住。
    *   ★ **`LAYER_ID == 表下标`**：参数表按 `LAYER_ID` 索引 ⇒ 越界会让"读到的参数"落到**别的层**
    *     （静默错值）⇒ 本行在 `go` 那一刻**响亮拦住**（`err` + 零搬运）。 */
  val pixPer     = (dw.imgH * dw.imgW).resize(32)
  /** 宽层逐字节拼拍的**像素组数** = `H*W/8`（`wideGeomOk` 保证 `H*W % 8 == 0`）。 */
  val pixGrp     = (pixPer >> 3).resize(16)
  /** ★★ C4b-D1 + T-S1：**输入平面**的像素数 = `inRows × rowW`（B3 的 DDR gather 按**输入**张量寻址：
    *   每换一个通道平面步进"一个输入平面"的字节数、每 `32` 个输入像素一笔 32 B RD）。
    *   ★ T-S1：行宽从展开期常量 `WIDTH` 换成**运行期** `rowWUse`（= `go` 那拍用 `inWMax`、其后用闩存的 `rowW`）
    *     ⇒ 同一张网表按**本层真实的输入平面**寻址（改动前只有 `WIDTH` 一种行宽可用）。
    *   `s = 1` 且 `WIDTH == IMG_W` ⇒ 本量 == `pixPer`（与改动前**逐字同值**）。 */
  val inPix      = (inRows.resize(32) * rowWUse).resize(32)
  val wideGeomOk = (dw.cOut =/= U(0, 16 bits)) && (nCo <= U(NCOB_MAX, 16 bits)) &&
                   inWOk &&   // ★ C4b-D1：`IMG_W` 与 `s` 反推出的输入宽区间必须覆盖本网表行宽（`s=1` ⇒ 退化成 `IMG_W==WIDTH`）
                   (layerIdx < U(PN_LAYERS, 8 bits)) && (chainLen === U(1, 16 bits)) &&
                   (pixPer(2 downto 0) === U(0, 3 bits))   // ★ 缺陷修-2：8 B 拼装要求 H*W % 8 == 0
  /** ★★ C4b-B1b：宽层走 **DMA 主路径**的合法性（缺一 ⇒ `go` 那一刻**响亮 err + 零搬运**）：
    *   · `wideGeomOk` —— 宽通路本来就要的几何（`IMG_W==WIDTH`、`LAYER_ID<PN_LAYERS`、`chainLen==1`、
    *     `H*W%8==0`、`0 < C_out ≤ 8*NCOB_MAX`；★★ C4b-C1 起**不再含 `C_out%8==0`**）；
    *   · `GROUP==1` / 非 depthwise —— 段长公式 `C_out*(C_in/GROUP)*9` 与 blob 的密集 `[co][ci][tap]` 成立的前提；
    *   · `C_in%8==0` —— 趟瓦片**没有**"跳过通道"补位 ⇒ `nCi*nCo*576 == 段长`（装载**写满**整段、
    *     wRam 段内不留上一层的旧值；见文件头「C4b-B1b」的映射式）；
    *   · 段长 `%32==0` + 段尾在 28 bit DDR 窗内 —— DdrMaster 的 RD 契约（`len%32==0` 且 `src%32==0`，
    *     否则那笔 RD 被**响亮拒绝**）；两者成立 ⇒ 读回字节数**恰好** == 段长（判据 ② 的根据）。 */
  /** ★★ C4b-B1c：**装载器自己**的几何前提（"我能不能把这单元的段正确展开成趟瓦片"）：
    *   · `grpOkW` —— `GROUP ∈ {1, C_in==C_out}`（映射式 `ci = gco*cig + ciLocal` 成立的前提）；
    *   · `C_in != 0 && C_out != 0` 且 `N_i != 0`；
    *   · `chainLen == 1`（宽通路是**单单元**；多切片链的趟瓦片展开不在本版）；
    *   · **段尾在 28 bit DDR 窗内**（用 RD 长度 `ceil32(N_i)` 判）。
    *   ★ 与"宽层多趟"的**计算侧**前提 `wideGeomOk`（`IMG_W==WIDTH`、`LAYER_ID<PN_LAYERS`、`H*W%8==0`、
    *     `0 < C_out ≤ 8*NCOB_MAX`）**解耦**：装载器只看自己这四条 ⇒ 真表 `C_out ∈ {1,4,10}` 的单元也能把
    *     权重**正确装进来**（判据①/② 可判），**计算侧**不支持时由 `WGTRUN` 收工那一拍 `wideGeomOk`
    *     **响亮 err**（见 FSM）。★ C4b-C1 起"部分尾块"已被计算侧支持 ⇒ 这条 err 只留给**真不支持**的几何。
    *   ★ 为什么解耦（而不是把 `wideGeomOk` 并进来）：本任务的对象是**装载器**（"blob → 趟瓦片"这一步）；
    *     把它与"能不能算"混在一个闸里，正是 B0 §10 把 `C_in%8!=0` 误当成"对齐问题"的同一个坑。
    *   ★ `isWide` 这一项在 `dmaWide` 里**不可省**（`wideGeomOk` 对窄层也成立 ⇒ 少了它窄层会误进宽通路，
    *     实测指纹：`run_wgtdma_ab.sh` 的 J1 挂住 —— `busy=1 unitIndex=0`）。 */
  val wgtLoadOk  = grpOkW && (dw.cIn =/= U(0, 16 bits)) && (dw.cOut =/= U(0, 16 bits)) &&
                   (wgtWideLen =/= U(0, 32 bits)) && (chainLen === U(1, 16 bits)) && dmaWinOkW
  /** 本次 `go` **确实**走宽层 DMA（= 主机编程了基址 + 本单元是宽层 + **装载器前提全合法**）⇒ 装载器落 `wRam`。 */
  val dmaWide    = dmaEn && isWide && wgtLoadOk
  /** ★★ C4b-C1：宽层输出的**有效 co 行数** = `C_out`（**不是** `nCo*8`）。
    *   · `C_out % 8 == 0` ⇒ 本量 == `nCo*8`，与改动前**逐字节同形**；
    *   · `C_out % 8 != 0` ⇒ 末 co-block 是**部分尾块**（只有 `C_out - 8*floor(C_out/8)` 行有效）。
    *   WR 相位按本量算**总字节/总字数** ⇒ 逐字节拼拍指针走到 `co == C_out` 就**自然截止**：
    *   出料的字节序是 `[co-block][cl][pixel]`（见下方"缺陷修-2"），在 `co = cob*8+cl` 上**单调**，
    *   总字节数又能被"整拍 8 B"整除（`H*W%8==0`）⇒ 截断点**恰好**落在 `co == C_out` 的行边界上，
    *   **绝不写/读 `C_out` 之后**（既不越段，也不回绕）。
    *   ★ 本量是"部分尾块"这条路的**唯一真源**（`wideWrBytes`/`wideWrWords` 都从它派生）：
    *     负对照（把本量换成旧的 `nCo*8`）就是"强制尾块写满 8 行"，闸门据此定点发火。 */
  val wideCoRows  = dw.cOut
  /** 宽层输出字节 = `C_out*H*W`（`H*W%8==0` ⇒ 也是整「拍」(8 B) 的整数倍 ⇒ 无半拍）。 */
  val wideWrBytes = (wideCoRows.resize(32) * pixPer).resize(32)
  val wideWrWords = (wideCoRows.resize(32) * pixGrp.resize(32)).resize(32)
  val pixAw  = log2Up(PIXW)                       // 每 co-block 像素数地址宽
  val woAw   = log2Up(PIXW * NCOB_MAX)            // 宽层输出存储字地址宽
  val bIdxW  = log2Up(NCOB_MAX * 8)               // `bias_adj` 平铺下标宽
  // 部件：冻结的 `MultiPassUnit`（含它自己的 `Conv3x3Slice` + `PartialSumBuf`）+ 宽层输出存储。
  val mpu     = new MultiPassUnit(WIDTH = WIDTH,
    // ★★ T-S2b：tile 循环下每一趟要把**整个窗口**（`tNRow×tNCol` 输出像素）都出一遍 ⇒ 部分和缓冲
    //   的像素下标上限必须装得下 `(tNRow-1)·tOutPerRow ≤ (IMG_H_MAX+1)·WIDTH`。
    //   `TILING=false` 的既有网表**逐字节不变**（`PIXW` 原值；★ §3.7 的 `PSW` 同此口径：64）。
    PIXMAX = if (TILING) PIXW + WIDTH else PIXW, NCOB = NCOB_MAX, PSW = if (TILING) 32 else 64, X1 = TILING, DW = TILING, DCI = TILING)   // ★★ NPU v2 §4.6-5（slice A）：`X1=TILING` ⇒ 只有 TILING=true 的展开里才有 1×1 跳拍口（`TILING=false` 逐字节不变）；★ slice B1：`DW=TILING` 同；★ slice C2：`DCI=TILING` 同
  val wOutMem = Mem(Bits(C * 8 bits), PIXW * NCOB_MAX).init(Seq.fill(PIXW * NCOB_MAX)(B(0, C * 8 bits)))
  val wOutMem2 = Mem(Bits(C * 8 bits), PIXW * NCOB_MAX).init(Seq.fill(PIXW * NCOB_MAX)(B(0, C * 8 bits)))   // ★★ W3：第二读口（与 wOutMem 同内容、同拍双写）⇒ 装载 2 像素/拍
  val wideR   = Reg(Bool()) init False   // 本次 `go` 是否宽层（与几何一起锁存，供 WR 相位用）
  // ---- 宽层子 FSM（只在 `WIDERUN` 态里推进）----
  val wSt   = Reg(UInt(3 bits))  init 0    // 0 起 / 1 载权 / 2 start / 3 喂列 / 4 换趟 / 5 收工
  /** ★★ C4a-R2：本趟**已出的像素数**（按 `mpu.y_valid` 计）——= **当前 `y` 的像素号**
    *   （`y_valid` 有效那一拍 `wEmitCnt` 就是它的下标）。用来做收料写地址与本趟收工判定：
    *   `MultiPassUnit.pixCount` 随"出数拍"走、**不随 requant 三级流水延迟**，两者会错 3 拍
    *   （见下面"宽层收料"一节的注释）。在每次 `start`（`wSt==2`）复位。 */
  val wEmitCnt = Reg(UInt(32 bits)) init 0
  val wCi   = Reg(UInt(8 bits))  init 0    // 当前 ci-block
  val wCob  = Reg(UInt(4 bits))  init 0    // 当前 co-block
  val wK    = Reg(UInt(10 bits)) init 0    // 权重拍（0..575）
  val wRow  = Reg(UInt(16 bits)) init 0    // 趟内已喂行
  val wCol  = Reg(UInt(cw bits)) init 0    // 趟内行内列
  // ---- 喂列（前 H 行来自 `wide_x`；第 H 行由本单元合成 `z_pad`）----
  val wFeedSt  = wSt === U(3, 3 bits)
  val wInPad   = (wRow >= inRows)                                  // ★ C4b-D1：第 `inRows` 行 = 合成 pad 行（`s=1` ⇒ 第 imgH 行，同改动前）
  /** 趟内行列指针推进条件（★ 缺陷修-3）：
    *   · 真行（`wRow < H`）：本列来自 `wide_x` ⇒ 必须**真的有一列**（`io.wide_x_valid`）才算推进；
    *   · pad 行（`wRow == H`，列由本单元合成 `z_pad`）：**只按切片收列（`x_ready`）推进**，
    *     **不能**再要求 `io.wide_x_valid`。
    *   为什么（这条是"co-block ≥ 1 的像素 0 全错"的根因）：主机列流 `wide_x` 共 `NCOL = n_co*n_ci*H*W` 列，
    *   恰好在本趟真行末尾用尽（`nfed == NCOL` ⇒ `io.wide_x_valid` 落 0）。旧式把 pad 行的推进也挂在
    *   `io.wide_x_valid` 上 ⇒ pad 行的 `wRow` **永远停在 `H`** ⇒ `mpu.io.x_valid`（=`wRow === imgH`）
    *   **一直举着** ⇒ 切片被**多喂**列：越过 pad 行、内部行号走到 `H` 之后，**继续产出多余像素**
    *   （`mpu.pixCount` 越过 `H*W`）。那些多余像素会（a）按 `pixCount[pixAw-1:0]` **回绕**写到
    *   `wOutMem[pix 0]`（**覆盖本 co-block 的像素 0**），并（b）按 `base+pixIdx[7:0]` 回绕写回
    *   `PartialSumBuf` 的像素 0 槽。实测签名：n_ci==1 且 n_co≥2 时**只有 co-block ≥1 的
    *   `[co][y=0][x=0]` 一个字节错**（≈ 被多算/漏算一个偏置的整像素）。
    *   ⇒ 改成"pad 行满 `W` 列即停"：`wRow` 走到 `H+1` ⇒ `mpu.io.x_valid` 自然落 0，多余像素不再产生。
    *   ★★ C4a-R2：上文的"回绕"分析针对**切片内部**的 `mpu.pixCount`/`PartialSumBuf`；本单元收料
    *   侧的保险项随之改成 `wEmitCnt < H*W`（见"宽层收料"一节）。 */
  // ===========================================================================
  // ★★ C4b-B3：**DDR → ci-block 行主序列流 的 gather**（宽层激活的真源；见 reports/c4b_input_layout.md）
  // ===========================================================================
  // 冻结的输入布局契约（**通道平面 / NCHW**）：DDR 上激活张量的元素 `(c, p)`（`p = y*IMG_W + x`）
  // 落在 `SRC_ADDR + c*HW + p`（`HW = IMG_H*IMG_W`）。本块把 ci-block 的 8 个平面 gather 成
  // **行主序列流**（一拍一列 = 一个像素的 8 个通道）—— 正是 `mpu.io.x` 要的形状
  // （与外部 `wide_x` 端口**同一形状**）⇒ **没有第二条算术路径**（本块只搬字节、不改数值）。
  //
  // 每 32 像素一组（`H*W % 32 == 0` 由 `xgGeomOk` 在 `go` 那一刻响亮拦住）：
  //   · FETCH：对 plane `cl = 0..Npl-1` 各发**一笔 32 B RD**（`SRC + (ci*8+cl)*HW + 32*g`，4 拍），
  //     第 `w` 拍灌进 `xbuf(cl*4 + w)`（= 该平面 32 个像素的字节）；
  //   · DRAIN：第 `j` 列（像素 `32g+j`）的第 `cl` 个通道 = `xbuf(cl*4 + j/8)` 的第 `j%8` 个字节。
  //   · `C_in % 8 != 0`（真表 `Conv_0` 的 `C_in = 3`）⇒ 缺的平面**每趟清一次 0**，
  //     与 B1c 的权重零填充**同一口径**（零激活 × 零权重 = 0 贡献；且**不发起**那些平面的 RD
  //     ⇒ 读地址绝不越出张量）。
  // 为什么 gather 落在**本单元**（而不是 `LayerSched`）：宽层多趟的趟编排（`wCob/wCi`）、
  // `mpu.io.start` 相位、喂列握手全在**这里**；且 `DdrMaster` 在 `WIDERUN` 相位**本来就空闲**
  // （宽通路不读 DDR）⇒ 复用同一个主口，不需要第四路子主口、也不改 AXI 复用结构。
  // ★ 与既有行为的关系：`XDMA_EN = 0`（上电值）⇒ 列来源仍是外部端口、主口**一字节都不读**
  //   ⇒ 既有宽层闸门（`RD_PEAK == 0`）逐字节不变。
  val xDmaOnR = Reg(Bool()) init False
  when(io.wgt_we && (rgn === U(RGN_XDMA, 4 bits)) && (io.wgt_addr(1 downto 0) === U(0, 2 bits))) {
    xDmaOnR := io.wgt_data(0)
  }
  /** 本趟 ci-block 的**有效平面数** `Npl = min(8, C_in - ci*8)`（≥1：`C_IN == 0` 已被几何拦住）。 */
  val xgRem   = (dw.cIn.resize(24) - (wCi.resize(24) << 3)).resize(24)
  val xgNPl   = Mux(xgRem >= U(8, 24 bits), U(8, 4 bits), xgRem.resize(4 bits))
  /** 本趟的组数 = `H*W/32`（几何前提 `H*W % 32 == 0` 在 `go` 那一刻拦住）。 */
  val xgGNum  = (inPix >> 5).resize(16)   // ★ C4b-D1：输入平面的 32 B 组数（= 输入 H*W/32）
  val xgSt = Reg(UInt(2 bits)) init 0        // 0 = IDLE / 1 = FETCH（逐平面一笔 RD）/ 2 = DRAIN（逐列）
  val xgK  = Reg(Bool()) init False          // FETCH 内：`False` = 本平面要发起 / `True` = 正在收
  val xgPl = Reg(UInt(3 bits)) init 0        // 本组正在收的平面
  val xgb  = Reg(UInt(2 bits)) init 0        // 本平面已收的拍（0..3）
  val xgG  = Reg(UInt(16 bits)) init 0       // 组序（0..H*W/32-1）
  val xgJ  = Reg(UInt(5 bits)) init 0        // DRAIN 内的列序（0..31）
  val xbuf = Vec.fill(32)(Reg(Bits(C * 8 bits)) init B(0, C * 8 bits))
  // ---- 地址：**零乘法器**（只有移位与加法）----
  //   `xgPlane0` = **本趟 ci 的第 0 个平面**的地址（本趟内恒定；每趟按 `wCi` 递推，`wCi == 0` ⇒ 回 `SRC_ADDR`）。
  //     ★ 它是**寄存器**且是**本趟的唯一基址**：组边界（+32）与换平面（+HW）都从它递推
  //       —— 不能用"由 `wCi` 现算"的组合量（`wCi` 在整个 ci 趟里不变，但它算出来的是**下一个** ci 的基址，
  //         会在换组时把基址多加一份 `8*HW`；实测签名：`n_ci≥2` 的层每趟**只有第 0 组对**、其后全错）。
  //   `xgAddrR`  = 本组当前平面的 32 B 突发地址；组首 = `xgPlane0 + 32*g`，换平面 += `HW`。
  val xgSrcA32 = dw.srcA                                    // 已是 32 位（描述符 w4）
  val xgPlane0 = Reg(UInt(32 bits)) init 0
  val xgAddrR  = Reg(UInt(32 bits)) init 0
  val xgTripBase = Mux(wCi === U(0, 8 bits), xgSrcA32, (xgPlane0 + (inPix << 3)).resize(32))  // ★ C4b-D1：8 个平面 × 输入平面字节
  /** 本拍要发起一笔 32 B RD（FETCH 的进入条件：主口空闲）。 */
  val xgStartPulse = (xgSt === U(1, 2 bits)) && (xgK === False) && (!ddrMaster.io.busy)
  /** 本平面字节的落点下标 = `xgPl*4 + xgb`（硬连线左移 2 位 + 拍号）。 */
  val xgWrIdx = ((xgPl @@ U(0, 2 bits)) + xgb.resize(5)).resize(5)
  /** DRAIN 的列来源：第 `cl` 个通道 = `xbuf(cl*4 + xgJ/8)` 的第 `xgJ%8` 个字节。 */
  val xgJw = xgJ(4 downto 3)
  val xgJb = xgJ(2 downto 0)
  val xgData = Vec((0 until C).map(cl =>
    Vec((0 until 8).map(k => xbuf((U(cl * 4, 5 bits) + xgJw.resize(5)).resize(5))(k * 8 + 7 downto k * 8)))(xgJb).asSInt))
  /** 本拍给出的列有效（DRAIN 相位）；被收下 = 与 `mpu` 的列握手成交。 */
  val xgValid = (xgSt === U(2, 2 bits))
  // ★ C4b-D1：真行的上界 = `inRows`（`s=1` ⇒ `IMG_H`，同改动前）
  val xgRdy   = wFeedSt && (wRow < inRows) && mpu.io.x_ready
  val xgTake  = (xgSt === U(1, 2 bits)) && (xgK === True)   // 本拍要从主口收 RD 拍
  /** 一趟（一个 ci-block 的喂列相位）开始 = `wSt == 2`（与 `mpu.start` **同一拍**；见宽层子 FSM）。 */
  val xgTripGo = (state === UnitExecPhase.WIDERUN) && (wSt === U(2, 3 bits))
  when(xgTripGo) {
    xgSt := U(1, 2 bits); xgK := False; xgPl := U(0, 3 bits); xgb := U(0, 2 bits)
    xgG  := U(0, 16 bits); xgJ := U(0, 5 bits)
    xgPlane0 := xgTripBase                                   // 本趟平面 0 的地址
    xgAddrR  := xgTripBase                                   // 组 0 的突发地址
    for (i <- 0 until 32) { xbuf(i) := B(0, C * 8 bits) }   // 缺通道的平面在本趟**保持 0**
  } otherwise {
    switch(xgSt) {
      is(U(1, 2 bits)) {                                    // FETCH：逐平面一笔 32 B RD
        when(xgK === False) {
          when(!ddrMaster.io.busy) { xgK := True }          // 本拍 `xgStartPulse` 举 start
        } otherwise {
          when(ddrMaster.io.rd_valid) {
            xbuf(xgWrIdx) := ddrMaster.io.rd_data.asBits
            xgb := (xgb + 1).resize(2)
          }
          when(ddrMaster.io.done) {
            xgb := U(0, 2 bits)
            when(xgPl === (xgNPl - U(1, 4 bits)).resize(3)) {
              xgSt := U(2, 2 bits); xgJ := U(0, 5 bits)      // 8（或 Npl）个平面收齐 ⇒ 逐列 drain
            } otherwise { xgPl := (xgPl + 1).resize(3); xgK := False; xgAddrR := (xgAddrR + inPix).resize(32) }  // ★ C4b-D1
          }
        }
      }
      is(U(2, 2 bits)) {                                    // DRAIN：一拍一列，直到被 mpu 收下
        when(xgValid && xgRdy) {
          when(xgJ === U(31, 5 bits)) {
            xgJ := U(0, 5 bits)
            when(xgG === (xgGNum - U(1, 16 bits))) { xgSt := U(0, 2 bits) }   // 本趟喂完
              .otherwise {
                xgG := (xgG + 1).resize(16); xgPl := U(0, 3 bits)
                xgK := False; xgSt := U(1, 2 bits)
                // 下一组的**平面 0** 地址 = 本趟基址（= `xgPlane0` 寄存器，本趟内恒定）+ 32
                xgAddrR := (xgPlane0 + ((xgG + U(1, 16 bits)) << 5)).resize(32)
              }
          } otherwise { xgJ := (xgJ + 1).resize(5) }
        }
      }
      default { }
    }
  }
  /** ★ 列的来源二选一：`XDMA_EN = 0` ⇒ **外部端口**（既有行为）；`= 1` ⇒ **DDR gather**。 */
  val xSrcCol = Vec((0 until C).map(cl => Mux(xDmaOnR, xgData(cl), io.wide_x(cl))))
  val xSrcVal = Mux(xDmaOnR, xgValid, io.wide_x_valid)
  val wXCol    = Vec((0 until C).map(co => Mux(wInPad, zpadR.asSInt, xSrcCol(co))))
  /** 趟内行列指针推进条件（★ 缺陷修-3 + ★★ C4b-B3：真行的推进条件改用**列来源的真实 valid**）：
    *   · 真行（`wRow < H`）：本列来自列来源（外部 `wide_x` 或 DDR gather）⇒ 必须**真的有一列**
    *     （`xSrcVal`）才算推进；· pad 行（`wRow == H`，列由本单元合成 `z_pad`）：**只按切片收列
    *     （`x_ready`）推进**，**不能**再要求 `xSrcVal`（理由见下面那段 ★ 缺陷修-3 的注释）。
    *   `XDMA_EN = 0` ⇒ `xSrcVal == io.wide_x_valid` ⇒ 与 C4a.5b **逐字同形**。 */
  val wAdvance = wFeedSt && mpu.io.x_ready && (wRow <= inRows) &&
                 Mux(wRow < inRows, xSrcVal, True)
  // ★ C4b-B3 观察口（零逻辑：只是把上面的组合量引出去；见 io.x_dbg 的注释）。
  for (cl <- 0 until C) { io.x_dbg(cl) := xSrcCol(cl) }
  io.x_dbg_ok := xSrcVal && xgRdy

  // ===========================================================================
  // ★★ T-S2b：**宽路 2-D tile 循环** —— 平面（NCHW）行跨步 halo gather + 每 tile 多趟重跑
  //   口径（逐字沿用 §4.2 / T-S0 的 halo 规则）：窗口行 `r`（全局 `iy=tFy+r`）、列 `j`（全局 `g=tFx+j`）；
  //     喂列与窄通路**同序**（行主序：切片第 `q` 行 ↔ `oy0-1+q`、第 `j` 列 ↔ `ox0-1+j`）⇒ 只留 `q∈[1,tTh]×j∈[1,tTw]`。
  //     · 输入是**通道平面**（元素 `(c,p)` 落 `SRC + c·HW + p`）⇒ gather 把 **Npl 个平面**同一像素的
  //       字节**拼成一列**（= `mpu.io.x` 的形状）。窗口行的一段是**行跨步**（pitch=`inWi`）⇒ 按"32 列一
  //       band"逐 band 读：绝对字节 `gAbs = plane0 + iy·inWi + g`；band 基址 `wxBB = gAbs & ~31`（32 对齐）；
  //         band 内字节下标 `wxIdx = gAbs[4:0]`；对每个平面 `pl` 读 32 B @ `(gAbs + pl·HW) & ~31`。
  //         ⇒ 一列 = `xwBuf(pl, plIdx/8)` 的第 `plIdx%8` 个字节（与既有 `xbuf` 同一布局）。
  //       ★★ T-S3b：**每平面各记 band**（`wxBndB(pl)` + 本平面 `plIdx`）：平面 `pl` 地址 = `gAbs + pl·HW`，
  //         其 32 B band 基址 = 该地址 `& ~31`（仍对齐 ⇒ 突发合法）；`HW%32≠0` 时各平面边界**不重合**
  //         （真表 20×20：HW=400，偶/奇平面相位 0/16）⇒ 去掉 `HW%32==0` 前提；只重取真变了的平面。
  //     · 每 tile 重跑 `nCi·nCo` 趟（dense）/ `nCo` 趟（depthwise 对角）；`ps_clr` 在"某 co-block 第 1 趟"
  //       举起。收料/写回：只留 `q∈[1,tTh]×j∈[1,tTw]` 存 `wOutMem`；每 (co, tile 行) 一笔 32 B 对齐 burst。
  //   ★ `TILING=false` / 非宽层 ⇒ `tilingWideC` 恒假 ⇒ `tilingW` 恒 0 ⇒ 本块**全部死逻辑**。
  /** 本层走**宽路 tile 循环**（`go` 那一刻闩存）。 */
  val tilingW  = Reg(Bool()) init False
  /** 输入平面（`inHi × inWi`）的**字节数** `HW`（每平面 band 基址 = `(gAbs + pl·HW) & ~31`）。 */
  val tInPixW  = if (TILING) RegNext((tInHi.resize(34) * tInWi.resize(34)).resize(34), U(0, 34 bits)) else (tInHi.resize(34) * tInWi.resize(34)).resize(34)   // ★ 2026-10-24 提频：仅 TILING 寄存一拍（tInHi/tInWi 整个 unit 内不变）⇒ npu 头号路径第一级乘法移出组合链；窄路表达式逐字不变
  val tHW32    = ((strideEff.resize(20) * strideEff.resize(20)).resize(34) *
                  (dw.imgH.resize(34) * dw.imgW.resize(34)).resize(34)).resize(34)
  /** **go 那一刻**判定：TILING + 宽通路（`!narrowShape`）+ 单单元 + 非头 + `s∈{1,2}` +
    *   激活走 DDR gather（`XDMA_EN=1`）+ 输出通道可寻址 + `IMG_W/H≠0` + `H·W%8==0`（★ T-S3b 去 `HW%32==0`）。 */
  val tilingWideC = if (TILING) isWide && (chainLen === U(1, 16 bits)) && !isHead &&
                    ((strideEff === U(1, 4 bits)) || (strideEff === U(2, 4 bits))) &&
                    (dw.cOut =/= U(0, 16 bits)) && (nCo <= U(NCOB_MAX, 16 bits)) &&
                    (layerIdx < U(PN_LAYERS, 8 bits)) && (pixPer(2 downto 0) === U(0, 3 bits)) &&
                    (dw.imgW =/= U(0, 16 bits)) && (dw.imgH =/= U(0, 16 bits)) &&
                    xDmaOnR
                   else False
  /** 本趟有效平面数 `Npl = min(8, C_in - ci·8)`（≥1）。 */
  val wxNPl = {
    val rem = (dw.cIn.resize(24) - (wCi.resize(24) << 3)).resize(24)
    Mux(rem >= U(8, 24 bits), U(8, 4 bits), rem.resize(4 bits))
  }
  /** band 缓冲：8 平面 × 4 字 × 8 B = 256 B（与既有 `xbuf` 同形同布局）。 */
  val xwBuf = Vec.fill(32)(Reg(Bits(C * 8 bits)) init B(0, C * 8 bits)); val wxPreP = if (TILING) (0 until 8).map(p => RegNext((tInPixW.resize(35) * U(p, 35 bits)).resize(35), U(0, 35 bits))) else Nil; val (tFxg, tFyg, tWinLog, tWinHig, tInWig, tInHig) = if (TILING) (RegNext(tFx) init S(0, 26 bits), RegNext(tFy) init S(0, 26 bits), RegNext(tWinLo) init U(0, 24 bits), RegNext(tWinHi) init U(0, 24 bits), RegNext(tInWi) init U(0, 24 bits), RegNext(tInHi) init U(0, 24 bits)) else (tFx, tFy, tWinLo, tWinHi, tInWi, tInHi)   // ★ 2026-10-29 提频（行数中性，保 TILING=false 网表冻结）：wxPreP = `tInPixW·p` 预先乘好寄存（强度消减，wxPBB/wxPIDX 退化成加+掩码）；tFxg..= gather 侧的 tile 几何整组寄存一拍（循环不变量，换 tile 后 ≥577 拍才进喂列相位）
  // ---- gather 状态（只在 `WIDERUN` 的喂列相位里跑；`tilingW=0` ⇒ 恒 IDLE）----
  val wxSt    = Reg(UInt(2 bits))  init 0        // 0=IDLE / 1=DECIDE / 2=FETCH / 3=EMIT
  val wxBBR   = Reg(UInt(32 bits)) init 0        // 已装好的 band 基址
  val wxBandV = Reg(Bool())        init False    // 已装好的 band 是否有效
  val wxFPl   = Reg(UInt(3 bits))  init 0        // FETCH：平面序
  val wxFBe   = Reg(UInt(2 bits))  init 0        // FETCH：band 内拍序
  val wxK     = Reg(Bool())        init False    // FETCH：本平面的 RD 在飞
  val wxOrphan= Reg(Bool())        init False    // FETCH：进来时主口已在忙（残留一笔）⇒ 排空后重取本 band
  val wxFAdrR = Reg(UInt(32 bits)) init 0        // FETCH：本平面本 band 的突发地址（寄存；DdrMaster 的 CHK 在 start 下一拍读）
  // ★★ B3b：SG 批式子相位。`wxSgDrn`=进门先排空残留一笔；`wxSgRd`=RD 收流中；`wxSgGo`=start(mode=3) 一拍脉冲。
  //   `wxSgScan` 扫 0..7 找 `wxPNE` 的平面入队（一拍一项，`sg_ready` 反压）；`wxSgEnq`=已入队项数；
  //   `wxSgPl(item)`=项→平面序（RD 收流按项落 `xwBuf`）；`wxSgMask/BB`=本批已入队平面的 band 账本快照
  //   （**快照而非末拍重算**：趟若在收流中被打断，重启后账本仍记的是 xwBuf 里真正装着的那条 band）。
  val wxSgDrn  = if (TILING) Reg(Bool()) init False else null
  val wxSgRd   = if (TILING) Reg(Bool()) init False else null
  val wxSgGo   = if (TILING) Reg(Bool()) init False else null
  val wxSgScan = if (TILING) Reg(UInt(4 bits)) init 0 else null
  val wxSgEnq  = if (TILING) Reg(UInt(4 bits)) init 0 else null
  val wxSgPl   = if (TILING) Vec((0 until 8).map(_ => Reg(UInt(3 bits)) init 0)) else null
  val wxSgMask = if (TILING) Reg(Bits(8 bits)) init B(0, 8 bits) else null
  val wxSgBB   = if (TILING) Vec((0 until 8).map(_ => Reg(UInt(32 bits)) init 0)) else null
  /** 窗口行的全局输入行（signed）与该行是否落在输入平面内。 */
  val wxIY     = (tFyg + wRow.resize(26).asSInt).resize(26)
  val wxRowOk  = (wxIY >= S(0, 26 bits)) && (wxIY < tInHig.resize(26).asSInt)
  /** 窗口列的全局输入列（signed）与该列是否落在输入平面内。 */
  val wxG      = (tFxg + wCol.resize(26).asSInt).resize(26)
  val wxInWin  = (wxG >= tWinLog.resize(26).asSInt) && (wxG < tWinHig.resize(26).asSInt)
  /** 本列的绝对字节地址（以本趟 plane 0 为基）与它的 band 基址/band 内下标。 */
  val wxPl0    = (dw.srcA.resize(35) + (wCi.resize(35) * (tInPixW.resize(35) << 3)).resize(35)).resize(34)
  val wxRowBas = (wxPl0.resize(35) + (wxIY.resize(35).asUInt * tInWig.resize(35))).resize(32)
  val wxGAbs   = (wxRowBas.resize(35) + wxG.resize(35).asUInt).resize(32)
  val wxBB     = wxGAbs & U(0xFFFFFFE0L, 32 bits)
  val wxIdx    = wxGAbs(4 downto 0)
  val wxIdxW   = wxIdx(4 downto 3)
  val wxIdxB   = wxIdx(2 downto 0)
  // ★★ T-S3b：**每平面** band 账本（`wxBndB(pl)` = 该平面已装 band 基址 `& ~31`、`wxBndV(pl)` = 有效位）
  //   ＋平面 `pl` 自己的 band 内下标 `wxPIDX(pl)` 与"本列要重取 / 当前平面跳过"。只 `TILING=true` 落硬件。
  val wxBndV = if (TILING) (0 until 8).map(_ => Reg(Bool()) init False) else Nil
  val wxBndB = if (TILING) (0 until 8).map(_ => Reg(UInt(32 bits)) init 0) else Nil
  val wxPBB  = if (TILING) (0 until 8).map(p => ((wxGAbs.resize(35) + wxPreP(p)).resize(32)) & U(0xFFFFFFE0L, 32 bits)) else Nil
  val wxPIDX = if (TILING) (0 until 8).map(p => (wxGAbs.resize(35) + wxPreP(p)).resize(32)(4 downto 0)) else Nil
  /** 本列真的要用平面 `p`（真行 ∧ 在窗口内 ∧ `p<Npl`）。 */
  val wxUse  = if (TILING) (0 until 8).map(p => wxRowOk && wxInWin && (U(p, 4 bits) < wxNPl)) else Nil
  val wxPNE  = if (TILING) (0 until 8).map(p => wxUse(p) && !(wxBndV(p) && (wxPBB(p) === wxBndB(p)))) else Nil
  /** `wxPNE/wxPBB` 的动态索引版（扫平面用；扫完（8）时索引不合法但 `sg_valid` 已被 `<8` 门掉）。 */
  val wxPNEV = if (TILING) Vec(wxPNE) else null
  val wxPBBV = if (TILING) Vec(wxPBB) else null
  val wxSkipNow = if (TILING) (0 until 8).map(p => (!wxPNE(p)) && (wxFPl === U(p, 3 bits))).reduce(_ || _) else null
  /** 本列要先 fetch 一个新 band（真行 ∧ 在窗口内 ∧ band 未装）。 */
  val wxNeedB  = if (TILING) wxPNE.reduce(_ || _) else (wxRowOk && wxInWin && !(wxBandV && (wxBB === wxBBR)))
  /** 本列是**列 pad**（整行越界 或 列越界）。 */
  val wxPad    = !(wxRowOk && wxInWin)
  /** gather 给出的**列**（`mpu.io.x` 的形状：一拍一列 C 个字节；pad 列 = `z_pad`）。 */
  val wxWord = if (TILING) Vec((0 until C).map(cl => xwBuf((cl * 4 + wxPIDX(cl)(4 downto 3)).resize(5)))) else Vec((0 until C).map(cl => xwBuf((cl * 4 + wxIdxW).resize(5))))
  val wxCol  = if (TILING) Vec((0 until C).map(cl =>
    Mux(wxPad, zpadR.asSInt, Vec((0 until 8).map(b => wxWord(cl)(b * 8 + 7 downto b * 8)))(wxPIDX(cl)(2 downto 0)).asSInt)))
   else Vec((0 until C).map(cl =>
    Mux(wxPad, zpadR.asSInt, Vec((0 until 8).map(b => wxWord(cl)(b * 8 + 7 downto b * 8)))(wxIdxB).asSInt)))
  /** 本趟**总出数** = `出数行数 × tOutPerRow`；★ T-S2b-i：出数**行数**按步长抽稀相位算 = `tTh+1`（`s=1` ⇒ `≡ tNRow-1` 逐字同值；`s=2` ⇒ 旧式 `tNRow-1` **多算一倍** ⇒ `wSt==3` 收工判据永不命中 ⇒ `s2_3x16` 挂死：`wEmitCnt` 饱和 561 而 `wxPixTot`=1105）。只在 `TILING=true` 生效，`else` 分支逐字是旧式 ⇒ `TILING=false` 网表逐字节不变。 */
  val wxPixTot = if (TILING) (((tTh + U(1, 16 bits)).resize(32) * tOutPerRow.resize(32)).resize(32)) else ((tNRow - U(1, 16 bits)).resize(32) * tOutPerRow.resize(32)).resize(32); val (tTwG, tThG, tOutPerRowG, wxPixTotG) = if (TILING) { val twG = RegNext(tTw) init (U(0, 16 bits)); val thG = RegNext(tTh) init (U(0, 16 bits)); val ncG = ((tS.resize(20) * twG.resize(20)) + U(2, 20 bits)).resize(16); val oprM = Mux(tS === U(1, 4 bits), ncG, (((ncG.resize(20) - U(1, 20 bits)) >> 1).resize(16) + U(1, 16 bits))); val oprG = RegNext(oprM) init (U(0, 16 bits)); val pxG = RegNext(((thG + U(1, 16 bits)).resize(32) * oprG.resize(32)).resize(32)) init (U(0, 32 bits)); (twG, thG, oprG, pxG) } else (tTw, tTh, tOutPerRow, wxPixTot) // ★ 2026-10-18 npu 时序：tile 几何 3 级寄存（换 tile 后 ≥577 拍才用写口）⇒ 从 wOutMem WEA 锥上摘掉 tOutPerRow/wxPixTot 乘链；本行与下面 11 行**行数中性**，TILING=false 网表 md5 冻结
  /** 本 tile **保留**像素计数与出数行列指针（每趟复位；收料判据用）。 */
  val oColW   = Reg(UInt(16 bits)) init 0
  val oRowW   = Reg(UInt(16 bits)) init 0
  val tPixKW  = Reg(UInt(32 bits)) init 0
  val tKeepW  = (oRowW >= U(1, 16 bits)) && (oRowW <= tThG) && (oColW >= U(1, 16 bits)) && (oColW <= tTwG)
  val tOutIdxW= (((oRowW - U(1, 16 bits)) * tTwG) + (oColW - U(1, 16 bits))).resize(pixAw)
  when(mpu.io.y_valid && tilingW) {
    tPixKW := tPixKW + Mux(tKeepW, U(1, 32 bits), U(0, 32 bits))
    when(oColW === (tOutPerRowG - U(1, 16 bits))) { oColW := U(0, 16 bits); oRowW := (oRowW + 1).resize(16) }
      .otherwise { oColW := (oColW + 1).resize(16) }
  }
  // ---- tile WR（每 (co, tile 行) 一笔 32 B 对齐 + 掩码 burst）----
  val wtSt    = Reg(UInt(2 bits))  init 0    // 0=IDLE / 1=LOAD / 2=STREAM / 3=NEXT
  val wtQ     = Reg(UInt(16 bits)) init 0; val wtLdQ  = Reg(UInt(16 bits)) init 0    // tile 行
  val wtCo    = Reg(UInt(16 bits)) init 0; val wtLdCo = Reg(UInt(16 bits)) init 0    // 输出通道
  val wtK     = Reg(UInt(6 bits))  init 0    // LOAD：行内像素序
  val wtLdS   = Reg(Bool())        init False// LOAD：0=发地址 / 1=落字节
  val wtWB    = Reg(UInt(4 bits))  init 0    // STREAM：拍序
  val wtSS    = Reg(UInt(2 bits))  init 0    // STREAM：0=start / 1=喂拍 / 2=等 done
  val wtRdD   = Reg(Bits(8 bits))  init 0    // LOAD：上一拍读回的字节
  val wtRowB  = Vec.fill(32)(Reg(Bits(8 bits)) init 0); val wtRowB2 = Vec.fill(32)(Reg(Bits(8 bits)) init 0)   // 本行（本 co）的 `tTw` 个字节
  val wtRdy   = Reg(Bool())        init False
  val wtPack  = Reg(Bits(64 bits)) init 0
  val wtStrb  = Reg(Bits(8 bits))  init 0
  /** 本 tile 的 WR **全部落地**（= 主 FSM 在 `WRRUN` 里据此推进 tile 网格 / 收工）。 */
  val wtTileDone = Reg(Bool()) init False; val wtBank = Reg(Bool()) init False; val wtLdBank = Reg(Bool()) init False; val wtPfRun = Reg(Bool()) init False; val wtPfRdy = Reg(Bool()) init False
  /** 本 (co, tile 行) 段的几何：绝对字节起点 / 段在 burst 内的偏移 / burst 长度（32 的整数倍）。 */
  val wtHWo   = (tHo.resize(34) * tWo.resize(34)).resize(34)
  val wtRowOf = ((wtCo.resize(34) * wtHWo) +
                 ((tOy0.resize(34) + wtQ.resize(34)) * tWo.resize(34)) +
                 tOx0.resize(34)).resize(34)
  val wtAbs   = (dw.dstA.resize(35) + wtRowOf.resize(35)).resize(35)
  val wtS0    = wtAbs(4 downto 0)
  val wtLen   = ((((wtS0.resize(20) + tTw.resize(20)) + U(31, 20 bits)) >> 5) << 5).resize(32)
  val wtDst   = (wtAbs & U(0xFFFFFFE0L, 35 bits)).resize(ddrCfg.ADDR_W)
  /** LOAD 相：读 `wOutMem[(wtQ·tTw + 2·wtK)·NCOB + cob]`（**一对**像素；W3 起 2 像素/拍）。 */
  val wtCob   = (wtLdCo >> 3).resize(log2Up(NCOB_MAX) max 1 bits)
  val wtCl    = wtLdCo.resize(3)
  val wtIdxX  = ((wtLdQ.resize(pixAw) * tTw.resize(pixAw)) + ((wtK << 1).resize(pixAw))).resize(pixAw)
  val wtRdAdr = (wtIdxX * U(NCOB_MAX, pixAw bits) + wtCob.resize(pixAw bits)).resize(woAw)
  val wtRdWrd = wOutMem.readSync(wtRdAdr)
  val wtRdWrd2 = wOutMem2.readSync((wtRdAdr + U(NCOB_MAX, woAw bits)).resize(woAw))   // ★ W3：同拍取同 cob 的**下一像素**
  /** 本拍要输出的 burst 数据/掩码（`pack`/`strb` 从 `wtPack`/`wtStrb` 寄存，见驱动器）。 */
  val wtPackR = Reg(Bits(64 bits)) init 0
  val wtStrbR = Reg(Bits(8 bits))  init 0
  val wBiasIdx = (wCob.resize(bIdxW) * U(8, bIdxW bits)).resize(bIdxW)
  // ===========================================================================
  // ★★ C4a-R3a（2026-10-11）：宽层**控制馈线寄存化**（把 `wCob` 从切片输入锥上摘下来）
  // ===========================================================================
  // 板级 PnR 实测（R2 之后的新最坏 `cpu_clk` 路径，seed_0 的 `..._rtr`）：
  //   Startpoint : `.../unitExec_1/wCob[2]/opit_0_L6Q_perm/CLK`
  //   Endpoint   : `.../unitExec_1/mpu/sl/N1035_m4/gopapm/Z[9]`   Slack −3.787 ns
  //   即：**`wCob` 组合地喂进 `MultiPassUnit` 的切片 APM 乘法 cascade**。逐级回查网表，这条锥只有一条：
  //     `wCob` → `wBiasIdx = wCob*8` → `biasReg[wBiasIdx+co]`（**64 项寄存器阵列的组合读 mux**）
  //       → `mpu.io.bias` → 切片 `accTot = acc + ps_in + bias` → requant 的 `aHiS * M`
  //       （4 级 APM，就是那个 `..._m4/gopapm/Z`）→ 第 1 级流水寄存器 `pHiR`。
  //   为什么可以打一拍（**逐字节不变**的结构性理由）：
  //     · 一趟的几何（co-block / ci-block / 该趟的 `bias_adj` 词）在**整趟内恒定** —— `wCob`/`wCi` 只在
  //       `wSt==4`（换趟）那一拍变，之后还有 576 拍载权 + 1 拍 `start` + `(H+1)*W` 拍喂列**才**用到它；
  //       ⇒ 寄存后的值在**第一次真正使用之前 ≥577 拍**就已稳定（这里比 R2 的 `mR` 还宽裕）。
  //     · `biasReg` 由装载器在 `!ldBusy` **之前**就全部取完（宽层子 FSM 的入口门就是 `when(!ldBusy)`）
  //       ⇒ 寄存的是"终值"，不是半途值。
  //     · `bias` 只在该层第 1 趟（`ci==0`）非 0（C4a.4 冻结）——这一条**保留在寄存器的 D 端**，
  //       语义与改动前一字不差（`wCi` 同拍稳定 ⇒ 寄存后也一样）。
  //   与 R2（`mR`/`zpadR`/`zyR` 的 `RegNext`）**同一套 idiom**：一层/一趟内恒定的控制量读出一拍寄存。
  //   ★ 本片**不**动 `mpu.we/waddr/wdin`（权重瓦片）：那条路的 `wRam` 是 LUTRAM 组合读，但它落在
  //     `WeightStore` 的**写口**、只在载权相 `wSt==1` 有效；乘法器的权重侧吃的是 `WeightStore` 的
  //     **读口**（地址 = 切片自己的 `ky/kx/ci` 计数器，与 `wCob` 无关）⇒ **不在**这条 APM 锥上。
  //   ★ 本片**不**加 FSM 拍数：上面两条（"≥577 拍才用"、"装载器先取完"）已经保证寄存值就位 ⇒
  //     宽层子 FSM 的相位（`wSt` 序列）、`start` 相位、喂列节拍、收料判据**全部一字未改**。
  /** `wCob` 的寄存副本（喂 `mpu.io.cob` ⇒ 部分和缓冲的分段基址 `cob*PIXMAX` 不再由组合量给）。 */
  val wCobP = RegNext(wCob) init (U(0, 4 bits))
  /** 本趟的 `bias_adj` 词（寄存；`ci==0` 门留在 D 端）—— 切片 `bias` 输入由**寄存器**驱动。 */
  val wBiasR = Vec(Reg(Bits(32 bits)) init (B(0, 32 bits)), C)
  for (co <- 0 until C) {
    // `bias_adj` **只在该层第 1 趟（ci=0）非 0**（C4a.4 冻结：bias 折进第 1 趟）
    //   ★★ C4b-C2：**depthwise 走对角趟** ⇒ 第 `b` 个 co-block 的唯一一趟是 `(b,b)`（`ci==b`），
    //     也就是"该 co-block 的第 1 趟"。若仍按 `wCi==0` 门，则 `b>0` 的 co-block 拿到 **bias=0**
    //     （`DwTb` 的口径是"对角趟直接带上本块偏置"）。⇒ 门改成 `(wCi==0) || isDwW`：
    //     depthwise 的每一趟（= 每个 co-block 的唯一一趟）都带本块偏置，其余几何**逐字不变**。
    wBiasR(co) := Mux((wCi === U(0, 8 bits)) || isDwW,
                      biasReg((wBiasIdx + U(co, bIdxW bits)).resize(bIdxW bits)), B(0, 32 bits))
  }
  mpu.io.x        := wXCol
  mpu.io.x_valid  := wFeedSt && Mux(wRow < inRows, xSrcVal, wRow === inRows)
  val wXReadyBase = xgRdy
  io.wide_x_ready := wXReadyBase
  mpu.io.cob      := wCobP.resize(log2Up(NCOB_MAX) max 1 bits)
  mpu.io.requant_m := (if (TILING) mRBm.asUInt else mR.asUInt) // ★ Y1-Timing：TILING 档换宽通路本地副本（§4.4 每层 Q24 乘子）
  mpu.io.zero_y    := zyR.asSInt
  mpu.io.pad_val   := zpadR.asSInt
  mpu.io.stride    := strideEff            // ★★ C4b-D1：宽层多趟的步长（= 描述符 `STRIDE`；每趟同一个值）
  mpu.io.rowW      := rowW.resize(16)      // ★★ T-S1：宽层多趟的运行期行宽（additive 16 位口；直通 `mpu` 的切片；分配仍按 WIDTH）
  for (co <- 0 until C) {
    // ★★ C4a-R3a：切片 `bias` 输入 = **寄存器**（原来这里是 `Mux(wCi==0, biasReg[wBiasIdx+co], 0)` 的组合读）
    mpu.io.bias(co) := wBiasR(co).asSInt
  }
  // 权重装载（每趟）：`mpu.we/waddr/wdin` 从 `wRam` 的趟序字节流取（趟序 = co-block 外、ci-block 内）
  val wPassIdx = (wCob.resize(16) * nCi + wCi.resize(16)).resize(16)
  // ★★ C4a-R3b（2026-10-11）：`wRam` 由 `readAsync`（**组合读** ⇒ LUTRAM，36 KB！）改 `readSync`
  //   （**同步读** ⇒ block RAM 形态）。`wRam` 是 C4a.5b 新增的三条 `readAsync` `Mem` 里最大的那条
  //   （`8*8*576 = 36,864 B`），dev_map 实测 `Distributed RAM +9,088（≈72 KB）` 的头号嫌疑。
  //   读出**晚一拍** ⇒ 把"载权相"的**写口整体打一拍**：地址相（`wK`）照旧逐拍 0..575 推进
  //   （FSM 的 `wSt` 序列**一字未改**），写口用**上一拍**的 `(we, 条目下标)` 配**本拍**读出的字节。
  //   ⇒ 每一道写的仍然是 `wRam[趟基 + wK] → WeightStore[wK]`（地址/数据/顺序逐字节不变），
  //     只是整条写序列**整体平移 1 拍**：第 1 道落在载权第 2 拍、**最后一道（`wK==575`）落在
  //     `start` 那一拍**（该拍 `WeightStore` 只被写、权重还没被乘法器用 —— 切片此刻 `ky/kx/ci`
  //     计数器为 0，且 `Prime` 只清相位、不动 `WeightStore`）⇒ 数值无影响。
  //   ★ 为什么不需要改 FSM：写序列"平移 1 拍"后仍**恰好 576 道、每道一次**（`wWtIdxR` 在载权相
  //     就是 0..574，`start` 那拍是 575；再往后 `we` 落 0）⇒ 无重写、无漏写、无越界。
  val wWtLoad = wSt === U(1, 3 bits)
  val wWtWeR  = RegNext(wWtLoad) init False
  val wWtIdxR = RegNext(wK) init (U(0, log2Up(C * C * 9) bits))
  val wWtDatR = wRam.readSync((wPassIdx * U(C * C * 9, 16 bits) + wK.resize(16)).resize(log2Up(WGT_RAM_BYTES) bits))
  mpu.io.we    := wWtWeR
  mpu.io.waddr := wWtIdxR.resize(log2Up(C * C * 9) bits)
  mpu.io.wdin  := wWtDatR.asSInt
  mpu.io.start := wSt === U(2, 3 bits)
  // 收料：只收 `i == n_ci-1` 那一趟的成品（像素序 = **本单元自己数的、随 `y_valid` 走的像素号**）
  //   ★ 缺陷修-3（保险）：还要求"本拍在本趟的喂列窗口内"（`wFeedSt && wEmitCnt < H*W`）——
  //     这样"趟外的多余像素"（即使被别的原因造出来）也**绝不会**按回绕地址写进 `wOutMem`。
  //   ★★ C4a-R2（2026-10-11）：像素号从 `mpu.pixCount` 改成**本单元随 `y_valid` 走**的 `wEmitCnt`。
  //     为什么必须改：切片 requant 三级流水后 `y_valid` 比"出数拍"晚 3 拍，而 `mpu.pixCount`
  //     （随 `ps_valid`/出数拍走）**不延迟** ⇒ 两者会错 3 个像素：写地址会指到 3 个像素之后、
  //     本趟最后 3 个像素还没收就换趟（实测 `run_unitexec_wide_ab.sh` 的 `MISMATCH=139`）。
  //     `wEmitCnt` = 本趟 `y_valid` 的计数 = **当前 `y` 的像素号**（与数据同相）⇒ 逐字节回到旧口径。
  val mpuYWord = Cat((0 until C).map(co => mpu.io.y(co).asBits))
  val wOutAddr = Mux(tilingW,
      (tOutIdxW.resize(pixAw) * U(NCOB_MAX, pixAw bits) + wCob.resize(pixAw bits)).resize(woAw),
      (wEmitCnt(pixAw - 1 downto 0) * U(NCOB_MAX, pixAw bits) + wCob.resize(pixAw bits)).resize(woAw))
  /** ★★ C4b-C2：**收料趟门**（= "本拍是不是该 co-block 的成品趟"）。
    *   · dense（`GROUP==1`，`isDwW=0`）：一般趟 —— 该 co-block 的**末 ci 趟**（`wCi == nCi-1`）
    *     才是成品（跨 ci 趟在部分和里累加完）⇒ **逐字节沿用 C1**；
    *   · depthwise（`isDwW=1`）：**对角趟** —— 该 co-block 只跑 `(wCob, wCob)` 一趟
    *     （`wCi == wCob`）⇒ **收在这些对角趟上**（`DwUnit`/`MultiPassUnit` 的冻结口径）。
    *   ★ 本量是负对照的**唯一真源**：把它退回 `wCi == nCi-1`（= 改动前的收料门）⇒ 对角循环下
    *     只有末 co-block（`wCob==nCo-1`）收得到料 ⇒ `wOutMem` 前 `nCo-1` 个 co-block 全是预载值 ⇒ 红。
    *   ★ 为什么"收料门按 `wCi==wCob`"这一条**必须**配对角循环：对角循环下 `wCi` 恒 `==wCob`；
    *     若循环一般化而门仍按 `nCi-1`，depthwise 会**只收最后一块**（见负对照）。 */
  val wCollectCiOk = Mux(isDwW, wCi === wCob.resize(8), wCi === (nCi - U(1, 16 bits)).resize(8))
  val wCollect = mpu.io.y_valid && wideR && wFeedSt && Mux(tilingW, wEmitCnt < wxPixTotG, wEmitCnt < pixPer) &&
                 wCollectCiOk && Mux(tilingW, tKeepW, True)
  wOutMem.write(wOutAddr, mpuYWord, wCollect); wOutMem2.write(wOutAddr, mpuYWord, wCollect)   // ★ W3：双写
  //   ★★ C4a-R2：`wEmitCnt` 就是"当前 `y` 的像素号"（`y_valid` 那一拍它正指向该像素）——
  //     它随 `y_valid` 走 ⇒ 与数据**同相**；每趟由 `starts`（`wSt==2`，同时是 `mpu.start` 脉冲）复位。
  when(mpu.io.y_valid) { wEmitCnt := wEmitCnt + 1 }
  // ---- ★★ C4a.5b **缺陷修-2**：宽层 WR 相位按 **[co][y][x]（通道平面）逐字节重排**成 8 B 一拍 ----
  //   `wOutMem` 的字 = **一个像素的 C 个通道**（写口按像素序写入，见上"宽层收料"）。而本通路的冻结
  //   输出口径（`tools/wide_exec_ref.py` 的 `gold.hex`，与 `MultiPassTb` 的 `Y` 行同序）是**通道平面**
  //   `[co][y][x]`：字节序 = `[co-block][cl][pixel]`（`co = cob*8 + cl`；`pixel = y*W + x`）。
  //   ⇒ "整字直推"给出的是 `[co-block][pixel][cl]`（**通道交错**的逐像素序），与黄金差一个
  //     **8 × 像素数 的转置** —— 这就是原实现里那句"`[co-block][pixel]` == `[co][y][x]`"的推导错误
  //     （两者只在"每块 8 通道 × 像素数"的**块边**上重合，块内是转置）。
  //   ⇒ 本实现**逐字节**取：地址 = `pix*NCOB_MAX + cob`、取字内**第 `cl` 个字节**，8 个**连续像素**
  //     （拍内道 = `pix%8`）凑成一拍 ⇒ 拍序 = `[co-block][cl][pixel/8]`，正是 `[co][y][x]`。
  //   ★ 代价（明写）：逐字节读 ⇒ 一拍要 8 个取字节拍（`wFill` 每拍取 1 B、填满才举 `wr_valid`），
  //     WR 相位比"一整字一拍"慢 8×。本通路的判据是**数值**不是吞吐，且本设计本来就"整张输出先落片上
  //     再流出去"（见文件头"输出侧"）；真实设计应"边产边流 + 通道平面写"（C4b/G6 项）。
  //   ★ 口径约束：整块 `8 B` 的拼装要求 `H*W % 8 == 0`（否则块内道会跨 `cl` 边界）—— 该约束由
  //     `wideGeomOk` 在 `go` 那一刻**响亮拦住**（不合 ⇒ `err` + 零搬运）。
  val wRdCob  = Reg(UInt(4 bits))  init 0     // 当前 co-block
  val wRdCl   = Reg(UInt(3 bits))  init 0     // 块内通道 `cl`（0..7）⇒ 全局 `co = wRdCob*8 + cl`
  val wRdPixG = Reg(UInt(16 bits)) init 0     // 当前**像素组**下标（0..H*W/8-1；一组 = 一拍的 8 个像素）
  val wRdLane = Reg(UInt(3 bits))  init 0     // 拍内字节道（= 组内像素序 0..7）
  val wPack   = Reg(Bits(C * 8 bits)) init 0  // 拼装中的一拍（8 B；道 j = 第 (base+j) 个像素）
  val wBeatRdy= Reg(Bool()) init False        // 一拍已拼满 ⇒ 举 `wr_valid`、等 `wr_ready`
  /** 当前要取的**像素**下标 = 组基 + 道（★ 必须把 `wRdLane` 加进来：一拍要 8 个**不同**像素）。 */
  val wAddrPix = (wRdPixG.resize(pixAw) * U(C, pixAw bits) + wRdLane.resize(pixAw)).resize(pixAw)
  val wideRdAddr = (wAddrPix * U(NCOB_MAX, pixAw bits) + wRdCob.resize(pixAw bits)).resize(woAw)
  // ===========================================================================
  // ★★ C4a-R3b（2026-10-11）：`wOutMem` 由 `readAsync`（**组合读** ⇒ LUTRAM）改 `readSync`
  //   （**同步读** ⇒ block RAM 形态，与 `PartialSumBuf`/`FusionBuf` 同一套 idiom）。
  //   为什么（板级 dev_map 实测）：C4a.5b 新增的三条 `readAsync` `Mem` 让 `Distributed RAM`
  //   （`LUTs as dram`）**1,767 → 10,855（+9,088 ≈ 72 KB）**，LUT 46%→68%、APM 63%→72%，
  //   而 `cpu_clk` 的最坏路径 59% 是**布线**（拥塞驱动）。`wOutMem` 是其中 16 KB 的那一条
  //   （`PIXW*NCOB_MAX = 2048` 字 × 8 B），与 `wRam`（36 KB）同属"宽层多趟"通路的承重存储
  //   ⇒ 二者必须落 **DRM**（`ram_style` 属性 PDS 忽略，**结构**才是唯一判据）。
  //   代价（同步读 ⇒ 读出**晚一拍**）：把宽层 WR 相位拆成两级 ——
  //     · **给地址相**（本拍）：地址由当前指针（`wRdCob/wRdCl/wRdPixG/wRdLane`）组合给出，
  //       与旧写法**同一表达式**；指针推进/换组/环回也**逐字保留**（只是多了一个"本拍是否取字节"
  //       的门 `wFetch`，见下）；
  //     · **落字节相**（下一拍）：用**寄存的**指针（`wRdLaneD/wRdClD` = 上一拍的指针值，与上一拍
  //       给出的地址**严格配套**）把读到的字节写进 `wPack`。
  //   ⇒ 每道字节仍然"取一次、落一次、位置不变"，拍序与旧写法**逐字节同序**（只是每拍多 1 个
  //     气泡拍：`wBeatEndD` 那一拍不给新地址，避免把下一拍的字节提前落进**还在飞**的 `wPack`）。
  //   ★ 为什么 `wFetch` 要带 `!wBeatEndD`：`wBeatEndD` = "本拍落的就是一拍的最后一道" ⇒ 若此时
  //     还给新地址，下一拍就会把**下一条拍**的第 0 道写进**尚未发走**的 `wPack`（背压下必错）。
  // ===========================================================================
  val wideRdWord = wOutMem.readSync(wideRdAddr)
  /** 与"上一拍给出去的地址"配套的寄存器（= 上一拍的指针值；`readSync` 读出晚一拍）。 */
  val wRdLaneD = RegNext(wRdLane) init (U(0, 3 bits))
  val wRdClD   = RegNext(wRdCl)   init (U(0, 3 bits))
  /** 上一拍确实取了一道字节 ⇒ 本拍必须把它落进 `wPack`（组合读时代的"同拍落"变成"下一拍落"）。 */
  val wFetchR  = Reg(Bool()) init False
  /** 字内**第 `wRdClD` 个通道**的字节（= 像素 `wRdPix` 的通道 `cl` 码点；与上一拍地址配套）。 */
  val wideRdByte: Bits = (0 until C).map(k =>
    Mux(wRdClD === U(k, 3 bits), wideRdWord(k * 8 + 7 downto k * 8), B(0, 8 bits))).reduce(_ | _)
  // 两个通路之和：`wideR=0` 时退化回旧值（逐字同形）
  val wrTotalEff = Mux(wideR, wideWrWords, wrTotal)
  val wrLenEff   = Mux(wideR, wideWrBytes, wrLen)
  val wrDataEff  = Mux(wideR, wPack, rdWord)
  /** 宽层：只在"一拍已拼满"时举 `wr_valid`（窄通路恒 `True` ⇒ 旧表达式逐字同形）。 */
  val wrValidEff = (state === UnitExecPhase.WRRUN) && (ri < wrTotalEff) && Mux(wideR, wBeatRdy, True)
  /** 本拍要落的字节是不是"一拍的最后一道"（`lane == C-1`）⇒ 落完这一拍就满。 */
  val wBeatEndD  = wFetchR && (wRdLaneD === U(C - 1, 3 bits))
  /** 给地址相的门（旧 `wFill` 逐项保留 + 新增 `!wBeatEndD`）：只在"没攒满、且没在收口"的拍上取新字节。 */
  val wFetch = wideR && (state === UnitExecPhase.WRRUN) && !tilingW && (!wBeatRdy) && (!wBeatEndD) && (ri < wrTotalEff)
  when(wFetch) {
    when(wRdLane === U(C - 1, 3 bits)) {
      wRdLane := U(0, 3 bits)
      when(wRdPixG === (pixGrp - U(1, 16 bits))) {
        wRdPixG := U(0, 16 bits)
        when(wRdCl === U(C - 1, 3 bits)) { wRdCl := U(0, 3 bits); wRdCob := (wRdCob + 1).resize(4) }
          .otherwise { wRdCl := (wRdCl + 1).resize(3) }
      } .otherwise { wRdPixG := (wRdPixG + 1).resize(16) }
    } .otherwise { wRdLane := (wRdLane + 1).resize(3) }
  }
  // 落字节相（下一拍）：用**寄存的**指针取字节；一拍的最后一道落完 ⇒ 举 `wBeatRdy`（此刻 `wPack` 才满）。
  when(wFetchR) {
    for (k <- 0 until C) { when(wRdLaneD === U(k, 3 bits)) { wPack(k * 8 + 7 downto k * 8) := wideRdByte } }
    when(wBeatEndD) { wBeatRdy := True }
  }
  wFetchR := wFetch   // 取字节有效位打一拍（与"落字节相"对齐）
  when(wBeatRdy && (state === UnitExecPhase.WRRUN) && ddrMaster.io.wr_ready) { wBeatRdy := False }


  // ---------------------------------------------------------------------------
  // 主相位 FSM
  // ---------------------------------------------------------------------------
  //   ★ 收工条件（头 + 链 + 尾都收工）：
  //     · 所有**活跃**切片都读完 IMG_H+1 行（`cdone(i)==hPlus1`；`i < chainLen`）；
  //     · 所有**活跃**中间缓冲的 pad 行都注入完（`padDone(b)`；`b < chainLen`）；
  //     · 切片0 出齐 `pixTotal` 个像素（`pixIdx`）；
  //     · `chainLen ≥ 2` 时末切片也出齐 `pixTotal` 个像素（`pixIdxT`）。
  //   `chainLen==1` 时后两条退化成 S2/头档的旧条件（逐字同形）。
  val consOk = (0 until L_MAX).map(i => (!(chainLen > U(i, 16 bits))) || (cdone(i) === Mux(tilingR, tNRow, hPlus1))).reduce(_ && _)
  val padsOk = (1 until L_MAX).map(b => (!(chainLen > U(b, 16 bits))) || padDone(b)).reduce(_ && _)
  val outTOk = (chainLen <= U(1, 16 bits)) || (pixIdxT === pixTotal)
  /** ★★ T-S2R：tiling 下收工判据 = tile 内**保留像素**数到齐（= `th·tw`）；非 tiling = 整层 `pixTotal`。 */
  val pixDoneEff = Mux(tilingR, tPixIdx === (tTh.resize(32) * tTw.resize(32)).resize(32), pixIdx === pixTotal)
  val runDone = consOk && padsOk && pixDoneEff && outTOk

  doneR := False
  errR  := False

  ddrMaster.io.start    := False
  ddrMaster.io.mode     := mMode
  ddrMaster.io.sg_valid := False   // ★ B3b：SG 队默认不使能（宽路 gather 在 fetch 时覆盖）
  ddrMaster.io.sg_addr  := U(0, ddrCfg.ADDR_W bits)
  ddrMaster.io.sg_beatsM1 := U(0, 4 bits)
  ddrMaster.io.sg_flush := False
  ddrMaster.io.src      := mSrc
  ddrMaster.io.dst      := mDst
  ddrMaster.io.len      := mLen

  switch(state) {
    is(UnitExecPhase.IDLE) {
      // 描述符检查时刻：QUANT_SHIFT / 链长 / 参数表下标（LAYER_ID） / 宽层几何，任一不符 ⇒ **响亮 err、零搬运**。
      when(io.go) {
        // ★★ T-S1：**闩存运行期行宽**（= `IMG_W·s` 的上界口径 = `inWMax`）—— 这是**唯一**的闩存点；
        //   此后所有计数/寻址都用 `rowW`（见上面「运行期行宽」一节）。界限 `1 ≤ rowW ≤ W_MAX` 由
        //   下面三条分支里的 `inWOk`（宽层 `wideGeomOk` / 窄层直查）当场把住 ⇒ 不合即响亮 err。
        //   ★ 本行是"负对照把 rowW 钉成常量"的**唯一靶点**（一行一刀，见 `run_roww_ab.sh`）。
        rowW := inWMax.resize(20)
        // ★★ T-S2R：**tile 几何闩存**（只在 `TILING=true` 的网表里非平凡；非 tiling ⇒ 死逻辑，行为不变）。
        tilingR := tilingOkC
        tS    := strideEff
        tWo   := dw.imgW
        tHo   := dw.imgH
        tInWi := (strideEff.resize(24) * dw.imgW.resize(24)).resize(24)
        tInHi := (strideEff.resize(24) * dw.imgH.resize(24)).resize(24)
        tWT   := tWTC
        tNtx  := Mux(strideEff === U(2, 4 bits), (dw.imgW + U(TWT2 - 1, 16 bits)) / U(TWT2, 16 bits),
                                                 (dw.imgW + U(TWT1 - 1, 16 bits)) / U(TWT1, 16 bits))
        tNty  := ((dw.imgH + U(HT_TILE - 1, 16 bits)) / U(HT_TILE, 16 bits)).resize(16)
        tTx   := U(0, 16 bits); tTy := U(0, 16 bits); tWrQ := U(0, 16 bits)
        // ★★ T-S2b：**宽路 tile 循环**闩存（`tilingWideC` 只可能对宽层成立 ⇒ 与 `tilingOkC` 互斥）。
        tilingW := tilingWideC
        when(if (TILING) !((qShiftOk && chainOk) && lidOk && chainGeomOk) else !((qShiftOk && chainOk) && lidOk)) {
          errR  := True
        } elsewhen (if (TILING) tilingWideC else False) {
          // ★★ T-S2b：**宽路 tile 循环** —— 只接受 `tilingWideC` 的几何；不合则**响亮 err + 零搬运**
          //   （落到下面的 `isWide` 分支 ⇒ 更宽的层被 `wideGeomOk` 拦住）。
          //   ★ 与窄通路同一条纪律：权重若走 **DMA 主路径**（`dmaEn`）必须**先装载**再开算
          //     （`WGTLD -> WGTRUN -> WIDERUN`；`WGTRUN` 收工那一拍进 `WIDERUN`，那时 `tilingW` 已闩 1
          //     ⇒ 直接走 tile 相位）。**装载器前提**照旧只看 `wgtLoadOk`（与 B1b/B1c 同式）。
          when(dmaEn) {
            when(wgtLoadOk) { state := UnitExecPhase.WGTLD } otherwise { errR := True }
          } otherwise {
            state := UnitExecPhase.WIDERUN
          }
        } elsewhen (if (TILING) tilingOkC else False) {
          // ★★ T-S2R：tile 循环网表 —— 只接受 `tilingOkC` 的几何；不合则**响亮 err + 零搬运**
          //   （落到下面的 `inWOk`/`wideGeomOk` 分支 ⇒ 更宽的层被 `inWOk` 拦住）。
          //   ★ 权重若走 **DMA 主路径**（`dmaEn`）：必须**先装载**再开算（`WGTLD -> WGTRUN -> RDSTART`；
          //     `WGTRUN` 收工那一拍进 `RDSTART`，那时 `tilingR` 已闩 1 ⇒ 直接走 tile 相位）。
          //     若让 tile 分支抢在 `dmaEn` 之前，`RDSTART` 会在**装载之前**起跑 ⇒ 权重要么是上一层的、
          //     要么是 0。实测签名（`run_wgtdma_ab` 的 J1）：少装恰一段 576 B（`WGT_BYTES 2304 -> 1728`）。
          //   ★ 这里用**装载器自己的前提** `dmaGeomOk && dmaWinOk`，**不**并 `inWOk`：`inWOk` 的界是
          //     "整层行宽 ≤ `W_MAX`"，而 tiling 的**行宽是窗口宽** `tNCol ≤ WIDTH`（恒成立：
          //     `tNCol = s·tw+2 ≤ s·TWT+2 = WIDTH`）⇒ 整层行宽可以远大于 `W_MAX`（这正是 tiling 的意义）。
          when(dmaEn) {
            when(dmaGeomOk && dmaWinOk) { state := UnitExecPhase.WGTLD } otherwise { errR := True }
          } otherwise {
            state := UnitExecPhase.RDSTART
          }
        } elsewhen(dmaEn) {
          // ★★ C4b-B1/B1b：**DMA 主路径已打开**（主机编程的 `WGT_BLOB_BASE != 0`）
          //   ⇒ 本单元开跑前先用 RD 把自己那一段权重从 DDR 灌进去，**装载收工后**才进计算相位：
          //     · 窄层 ⇒ `WGTLD -> WGTRUN -> RDSTART`（段 = `chainLen*NENTRY` 字节，逐字节灌各切片 `WeightStore`）；
          //     · 宽层 ⇒ `WGTLD -> WGTRUN -> WIDERUN`（段 = `C_out*C_in*9` 字节，逐字节灌趟瓦片 `wRam`）；
          //   两条路**同一个装载器、同一个主口**（`wlWideR` 只换落点，见文件头「C4b-B1b」）。
          //   ★ **全有或全无**：几何/契约不合（宽窄都不是 / 非 `{1, depthwise}` 的 `GROUP` / 段长 0 /
          //     链长 ≠1 / 段尾越窗）⇒ **响亮 err + 零搬运**（绝不允许"blob 没装成、权重还是
          //     信箱里的旧值"这种静默错值；见文件头「C4b-B1」的"边界"与「C4b-B1b/B1c」的边界）。
          //   ★★ C4b-B1c：宽层这里只看**装载器前提** `wgtLoadOk`（不再并 `wideGeomOk`）——
          //     装载器能装的几何（含 `C_in%8!=0` / `C_out%8!=0` / depthwise）就在这一步放行；
          //     **计算侧**不支持时由 `WGTRUN` 收工那一拍 `wideGeomOk` 响亮 err（见下）。
          when(isWide) {
            when(wgtLoadOk) { state := UnitExecPhase.WGTLD } otherwise { errR := True }
          } otherwise {
            when(dmaGeomOk && dmaWinOk && inWOk) { state := UnitExecPhase.WGTLD } otherwise { errR := True }
          }
        } elsewhen(isWide) {
          // ★ C4a.5b：宽层（`C_in>8 || C_out>8`）走多趟通路（参数已经信箱按 `LAYER_ID` 就位）
          //   ★★ C4b-B3：`XDMA_EN`（信箱区域 7）打开时，宽层的激活由**本单元从 DDR gather**
          //   ⇒ 多一条几何前提 `H*W % 32 == 0`（32 B 突发的粒度 + 平面步长 `HW` 的 32 B 对齐）。
          //   不合 ⇒ `go` 那一刻**响亮 err + 零搬运**（绝不静默读错地址）。`XDMA_EN=0` ⇒ 该子句恒真。
          when(wideGeomOk && (!xDmaOnR || (inPix(4 downto 0) === U(0, 5 bits)))) {   // ★ C4b-D1：32 B 粒度按**输入**平面
            state := UnitExecPhase.WIDERUN
          } otherwise { errR := True }
        } otherwise {
          // ★ C4b-D1：窄通路也要求"本网表行宽 = 输入宽"（`s=1` ⇒ 退化成 `IMG_W==WIDTH`，与既有装置
          //   time-0 对账同式 ⇒ 既有闸门不受影响；`s>1` 时这是唯一的几何拦阻）。不合 ⇒ 响亮 err、零搬运。
          when(inWOk) { state := UnitExecPhase.RDSTART } otherwise { errR := True }
        }
      }
    }
    // ★★ C4b-B1/B1c：WGTLD —— 先（宽通路若有需要）把趟瓦片区间**清 0**，再给权重段举**一笔 RD**
    is(UnitExecPhase.WGTLD) {
      // ★★ C4b-B1c：**零填充相位**（`wzGo` 在 `runStart` 就举起，且**只**在宽通路需要补零的几何上为真）。
      //   目的：`[0, Z)` 里那些**没有 blob 字节对应**的位置（跳过的输入通道 / `C_out` 之外的空行 /
      //   depthwise 的跨组位置与非对角趟）必须显式写 0 —— `wRam` 是**跨层常驻**的 Mem（不是上电初值
      //   就能保证），不写 0 就会留上一层的旧权重。写完才发 RD（`wzGo := False`）。
      //   ★ 优先级：本态的 `wlRun := True` 在 `otherwise` 分支里 ⇒ 清 0 期间 `wlRun` 仍为 0
      //     （没有 `rd_ready`、主口也没 `start`）⇒ **一拍不多读**。
      when(wzGo) {
        when(wzCnt === (wzEnd - U(1, 32 bits))) { wzGo := False; wzCnt := U(0, 32 bits) }
          .otherwise { wzCnt := (wzCnt + 1).resize(32) }
      } otherwise {
      ddrMaster.io.start := True
      mMode := U(1, 2 bits)                 // RD（只读，推 `rd_stream`）
      mSrc  := wgtBaseR                     // 本单元权重段起点（= base + Σ_{j<i} N_j，已寄存）
      mDst  := U(0, ddrCfg.ADDR_W bits)     // RD 模式 dst 不参与
      mLen  := wgtLenR                      // 窄 = chainLen*NENTRY；宽 = ceil32(N_i)（32 B 整数倍 ⇒ CHK 必过）
      wlRun := True
      wlCnt := U(0, 32 bits)
      wlSlice := U(0, selBits bits)
      wlAddr  := U(0, waBits bits)
      wlV     := False
      wlIdx   := U(0, 3 bits)
      // ★★ C4b-B1b：宽通路的指针/基址一并回零（窄通路不用它们；`wlWideR=0` ⇒ 下面三行是死赋值）
      wlTap   := U(0, 4 bits)
      wlCi    := U(0, 16 bits)
      wlCo    := U(0, 16 bits)
      state := UnitExecPhase.WGTRUN
      }
    }
    // ★★ C4b-B1：WGTRUN —— 逐字节把段内字节写进**落点**（`wlWr`/`wlTake` 在组件体里）
    //   ★ C4b-B1b：落点按 `wlWideR` 分叉 —— 窄 = 各切片的 `WeightStore`；宽 = 趟瓦片 `wRam`。
    //   ★★ C4b-B1c：装载收工后，若**计算侧**几何不支持（`wideGeomOk` 假）⇒ **响亮 err**（绝不静默算错）。
    //     ★ C4b-C1：`C_out%8!=0`（部分尾块）**已不再是**这里的 err —— 宽 WR 相位按 `C_out*H*W` 出料、只写有效行
    //     ⇒ 真表 `C_out ∈ {1,4,10}` 的 9 个 dense 单元现在端到端可跑 ⇒ 这里留的 err 只给**真不支持**的几何：
    //     `C_out==0` / `C_out > 8*NCOB_MAX` / `LAYER_ID` 越界 / 链长≠1 / `H*W%8!=0`（装载器前提不合更早拦住、零搬运）。
    //   ★★ T-S3d 缺陷修-①：**tiled 宽路**（`tilingW`）必须豁免 `inWOk`（"整层行宽 ≤ W_MAX"正是 tile 绕开的前提）—— 详见文件尾「T-S3d」。
    is(UnitExecPhase.WGTRUN) {
      when(!wlRun) {
        when(if (TILING) (wlWideR && !wideGeomOk && !tilingW) else (wlWideR && !wideGeomOk)) { errR := True; state := UnitExecPhase.IDLE }
          .otherwise { state := Mux(wlWideR, UnitExecPhase.WIDERUN, UnitExecPhase.RDSTART) }
      }
    }
    // RD：读激活（dst 在 RD 模式不参与）
    is(UnitExecPhase.RDSTART) {
      when(tilingR) {
        // ★★ T-S2R：tile 循环 —— 每个 tile 的 RD 由**生产者按窗口行**逐行发起（见"tile 生产者"），
        //   这里只做**每 tile 的相位复位**（行宽 = tile 窗口宽、喂行数、各子计数回零、脉冲 prime）。
        rowW   := tNCol.resize(20)
        pwant  := U(0, 16 bits)
        pcol   := U(0, cw bits)
        tPSt   := U(0, 3 bits)
        tBcol  := U(0, 24 bits)
        oColT  := U(0, 16 bits)
        oRowT  := U(0, 16 bits)
        tPixIdx:= U(0, 32 bits)
        tWrQ   := U(0, 16 bits)
        for (i <- 0 until L_MAX) {
          cRow(i) := U(0, 16 bits); cCol(i) := U(0, cw bits)
          cst(i)  := UnitExecCons.WAIT; cdone(i) := U(0, 16 bits); ocol(i) := U(0, cw bits)
        }
        for (b <- 1 until L_MAX) {
          wroteB(b) := U(0, 16 bits); padGo(b) := False; padCol(b) := U(0, cw bits); padDone(b) := False
        }
        state := UnitExecPhase.RDRUN
      } otherwise {
      ddrMaster.io.start := True
      mMode := U(1, 2 bits)
      mSrc  := dw.srcA.resize(ddrCfg.ADDR_W)
      mDst  := dw.dstA.resize(ddrCfg.ADDR_W)
      mLen  := rdLen
      state := UnitExecPhase.RDRUN
      }
    }
    // RDRUN：所有生产/消费/出料子 FSM 都在这里跑。整条链收工 ⇒ 去等主口回 IDLE。
    is(UnitExecPhase.RDRUN) {
      when(runDone) { state := UnitExecPhase.WRWAIT }
    }
    // ★★ C4a.5b WIDERUN：宽层多趟子 FSM（见上面"宽层多趟编排"一节）
    is(UnitExecPhase.WIDERUN) {
      when(!ldBusy) {                       // 先等 `bias_adj` 装载器取完（8*n_co 字）
        switch(wSt) {
          is(U(0, 3 bits)) { wSt := U(1, 3 bits) }        // 起趟：进入载权
          is(U(1, 3 bits)) {                              // 载权 576 拍（本趟瓦片）
            when(wK === U(C * C * 9 - 1, 10 bits)) { wK := U(0, 10 bits); wSt := U(2, 3 bits) }
              .otherwise { wK := (wK + 1).resize(10) }
          }
          is(U(2, 3 bits)) {                              // `mpu.start` 脉冲 + 复位行/列
            wSt := U(3, 3 bits); wRow := U(0, 16 bits); wCol := U(0, cw bits)
            wEmitCnt := U(0, 32 bits)                     // ★ C4a-R2：本趟像素号回零
            // ★★ T-S2b：tile 循环 —— 本趟的 gather/WR 指针与"保留像素"计数器复位。
            when(tilingW) {
              wxSt := U(1, 2 bits); wxBandV := False; wxOrphan := False
              if (TILING) {
                wxSgDrn := False; wxSgRd := False; wxSgGo := False
                wxSgEnq := U(0, 4 bits); wxSgScan := U(0, 4 bits); wxSgMask := B(0, 8 bits)
                ddrMaster.io.sg_flush := True        // 清掉上一趟收工时"半批未 start"的残留
              }
              oColW := U(0, 16 bits); oRowW := U(0, 16 bits); tPixKW := U(0, 32 bits)
              // ★ 运行期行宽 = **窗口宽**（切片的列回绕/行末列号按它；整层平面寻址另用 `tInPixW`）。
              rowW := tNCol.resize(20)
            }
          }
          is(U(3, 3 bits)) {                              // 喂列（前 H 行来自 `wide_x`，第 H 行 = `z_pad`）
            when(tilingW) {
              // ★★ T-S2b：tile 循环的喂列**由 gather 驱动**（`wxSt==3` 交付一列、收下才推进）
              //   ⇒ 这里**不**用既有的行列推进（它与"窗口行/列"的语义不同）。
              when(mpu.io.y_valid && (wEmitCnt === (wxPixTotG - U(1, 32 bits)))) { wSt := U(4, 3 bits) }
            } otherwise {
              when(wAdvance) {
                when(wCol === rowWm1) { wCol := U(0, cw bits); wRow := (wRow + 1).resize(16) }
                  .otherwise { wCol := (wCol + 1).resize(cw) }
              }
              // ★★ C4a-R2：本趟收工 = **最后一个像素的 `y` 已经出现**（`y_valid` + `wEmitCnt == H*W-1`），
              //   而不是旧的"`pixCount` 追上 H*W"——后者比数据早 3 拍，会把最后 3 个像素丢掉
              //   （实测 `MISMATCH=139`）。改成随 `y_valid` 走的判据后，本趟所有像素都真的收进 `wOutMem`。
              when(mpu.io.y_valid && (wEmitCnt === (pixPer - U(1, 32 bits)))) { wSt := U(4, 3 bits) }
            }
          }
          is(U(4, 3 bits)) {                              // 换趟
            // ★★ C4b-C2：**depthwise 走对角趟** —— 下一趟恒为 `(wCob+1, wCi=wCob+1)`（一趟即成品）；
            //   跑完末 co-block ⇒ 收工。dense（`isDwW=0`）**逐字沿用 C1**（ci 先跑完、再换 co-block）。
            when(isDwW) {
              when(wCob === (nCo - U(1, 16 bits)).resize(4)) { wSt := U(5, 3 bits) }
                .otherwise { wCob := (wCob + 1).resize(4); wCi := (wCob + 1).resize(8); wSt := U(1, 3 bits) }
            } otherwise {
              when(wCi === (nCi - U(1, 16 bits)).resize(8)) {
                wCi := U(0, 8 bits)
                when(wCob === (nCo - U(1, 16 bits)).resize(4)) { wSt := U(5, 3 bits) }
                  .otherwise { wCob := (wCob + 1).resize(4); wSt := U(1, 3 bits) }
              } otherwise {
                wCi := (wCi + 1).resize(8); wSt := U(1, 3 bits)
              }
            }
          }
          is(U(5, 3 bits)) { state := UnitExecPhase.WRWAIT }   // 全部趟跑完
          default { wSt := U(0, 3 bits) }
        }
      }
    }
    // WRWAIT：等内部主口彻底回 IDLE；`wrTotal==0`（头档）直接 DONE（无 WR 相位）。
    is(UnitExecPhase.WRWAIT) {
      when(!ddrMaster.io.busy) {
        when(wrTotalEff === U(0, 32 bits)) { state := UnitExecPhase.DONE } otherwise { state := UnitExecPhase.WRSTART }
      }
    }
    is(UnitExecPhase.WRSTART) {
      when(tilingW) {
        // ★★ T-S2b：宽路 tile 的 WR —— **每 (co, tile 行) 一笔 32 B 对齐 + 掩码 burst**
        //   （见下面"宽路 tile WR"小 FSM）；这里只做**本 tile 的 WR 相位复位**。
        //   ★ 前置：本 tile 的**保留像素必须到齐**（`tPixKW == tTh·tTw`）；否则**响亮 err**（绝不静默短写）。
        when(tPixKW =/= (tTh.resize(32) * tTw.resize(32)).resize(32)) {
          errR := True; state := UnitExecPhase.IDLE
        } otherwise {
          wtSt := U(1, 2 bits); wtQ := U(0, 16 bits); wtCo := U(0, 16 bits)
          wtK := U(0, 6 bits); wtLdS := False; wtWB := U(0, 4 bits); wtSS := U(0, 2 bits)
          wtRdy := False; wtLdQ := U(0, 16 bits); wtLdCo := U(0, 16 bits); wtLdBank := False; wtBank := False; wtPfRun := True; wtPfRdy := False
          state := UnitExecPhase.WRRUN
        }
      } elsewhen(tilingR) {
        // ★★ T-S2R：tile 输出**每行一笔 WR**（`th` 笔）—— 写到 DDR 的 `DST + ((oy0+q)·Wo + ox0)·C`。
        ddrMaster.io.start := True
        mMode := U(2, 2 bits)
        mSrc  := dw.srcA.resize(ddrCfg.ADDR_W)
        mDst  := (dw.dstA.resize(34) + (((tOy0.resize(34) + tWrQ.resize(34)) * tWo.resize(34) +
                                          tOx0.resize(34)) << 3).resize(34)).resize(ddrCfg.ADDR_W)
        mLen  := (tTw.resize(32) * U(C, 32 bits)).resize(32)
        ri    := 0
        state := UnitExecPhase.WRRUN
      } otherwise {
      ddrMaster.io.start := True
      mMode := U(2, 2 bits)
      mSrc  := dw.srcA.resize(ddrCfg.ADDR_W)
      mDst  := dw.dstA.resize(ddrCfg.ADDR_W)
      mLen  := wrLenEff
      ri    := 0
      // ★ 缺陷修-2：宽层逐字节拼装的读指针/道/拼装拍全部回零
      wRdCob := U(0, 4 bits); wRdCl := U(0, 3 bits); wRdPixG := U(0, 16 bits)
      wRdLane := U(0, 3 bits); wBeatRdy := False; wPack := B(0, C * 8 bits)
      // ★★ C4a-R3b：同步读的"落字节相"流水寄存器一并回零（多趟 `go` 连跑时相位与首次同形）
      wRdLaneD := U(0, 3 bits); wRdClD := U(0, 3 bits); wFetchR := False
      state := UnitExecPhase.WRRUN
      }
    }
    is(UnitExecPhase.WRRUN) {
      when(tilingW) {
        // ★★ T-S2b：宽路 tile 的 WR 由下面"宽路 tile WR"小 FSM 推进；本 tile 写完后**推进 tile 网格**
        //   并把趟循环与 gather 复位（下一 tile 从 `WIDERUN` 的 `wSt=0` 重新起趟）。
        when(wtTileDone) {
          wtTileDone := False
          wSt := U(0, 3 bits); wCob := U(0, 4 bits); wCi := U(0, 8 bits)
          when(tTx === (tNtx - U(1, 16 bits))) {
            tTx := U(0, 16 bits)
            when(tTy === (tNty - U(1, 16 bits))) { state := UnitExecPhase.DONE }
              .otherwise { tTy := (tTy + 1).resize(16); state := UnitExecPhase.WIDERUN }
          }.otherwise { tTx := (tTx + 1).resize(16); state := UnitExecPhase.WIDERUN }
        }
      } elsewhen(tilingR) {
        when(ddrMaster.io.done) {
          when(tWrQ === (tTh - U(1, 16 bits))) {          // 本 tile 全部行写完 ⇒ 推进 tile 网格
            tWrQ := U(0, 16 bits)
            when(tTx === (tNtx - U(1, 16 bits))) {
              tTx := U(0, 16 bits)
              when(tTy === (tNty - U(1, 16 bits))) { state := UnitExecPhase.DONE }
                .otherwise { tTy := (tTy + 1).resize(16); state := UnitExecPhase.RDSTART }
            }.otherwise { tTx := (tTx + 1).resize(16); state := UnitExecPhase.RDSTART }
          }.otherwise { tWrQ := (tWrQ + 1).resize(16); state := UnitExecPhase.WRSTART }
        }
      } otherwise {
      when(ddrMaster.io.done) { state := UnitExecPhase.DONE }
      }
    }
    is(UnitExecPhase.DONE) {
      doneR := True
      state := UnitExecPhase.IDLE
    }
  }

  // err：透传（单拍脉冲）+ 立刻放弃本次执行（回 IDLE；后续可重试）。
  when(ddrMaster.io.err) {
    errR  := True
    state := UnitExecPhase.IDLE
  }

  // ---------------------------------------------------------------------------
  // ★★ T-S2R：**tile 生产者的行跨步窗口读**主口驱动
  //   写在主 FSM 之后 ⇒ 覆盖 `RDSTART` 的默认值（tiling 下 `RDSTART` 本就不发 RD）。
  //   一笔 = 该窗口行的 32 B 对齐字节区间：`src = srcA + iy·(inWi·C) + aLo·C`、`len = (aHi-aLo)·C`。
  //   ★ 行 RD 的 `src/len` **必须寄存**（`tRowSrcR/tRowLenR`）：`DdrMaster` 的 `CHK` 在 `start` 的**下一拍**
  //     才读 `io.src/io.len`，纯组合的"一拍脉冲"到那一拍已经变回 FSM 的默认（`mSrc=0/mLen=0`）
  //     ⇒ `len==0` 会被 `CHK` 响亮拒绝（err）。寄存后 `src/len` 在整笔搬运期间保持稳定。
  //   ★ 只在 `RDRUN` 相位接管（WR 相位的 `len`/`dst` 由 `WRSTART` 的 tile 分支给）。
  //   ★ `tilingR=0` ⇒ 恒不触发 ⇒ 既有 RD 相位**逐字节不受影响**。
  // ---------------------------------------------------------------------------
  val tRowSrcR = Reg(UInt(32 bits)) init 0
  val tRowLenR = Reg(UInt(32 bits)) init 0
  when(tRowStartNow) { tRowSrcR := tRowBase; tRowLenR := tRowLen }
  when(tilingR && inRun) {
    ddrMaster.io.start := tRowStartNow
    ddrMaster.io.mode  := U(1, 2 bits)                        // RD（只读）
    ddrMaster.io.src   := Mux(tRowStartNow, tRowBase.resize(ddrCfg.ADDR_W), tRowSrcR.resize(ddrCfg.ADDR_W))
    ddrMaster.io.dst   := U(0, ddrCfg.ADDR_W bits)
    ddrMaster.io.len   := Mux(tRowStartNow, tRowLen, tRowLenR)
  }

  // ---------------------------------------------------------------------------
  // ★★ C4b-B3：**DDR gather 主口驱动**（写在主 FSM 之后 ⇒ 覆盖 `WIDERUN` 相位的默认值）
  //   只在 `WIDERUN && XDMA_EN` 时接管：一笔 32 B RD（`src = SRC + (ci*8+pl)*HW + 32*g`）。
  //   ★ 与既有权重 DMA（`WGTLD/WGTRUN`）、激活 RD（`RDSTART`）**时间互斥**（主 FSM 相位）
  //     ⇒ 同一处 `when` 覆盖既有的 `mMode/mSrc/mDst/mLen`，不需要仲裁器。
  // ---------------------------------------------------------------------------
  when((state === UnitExecPhase.WIDERUN) && xDmaOnR && !tilingW) {
    ddrMaster.io.start := xgStartPulse
    ddrMaster.io.mode  := U(1, 2 bits)                       // RD（只读，推 `rd_stream`）
    ddrMaster.io.src   := xgAddrR.resize(ddrCfg.ADDR_W)      // 本平面本组的 32 B 突发地址
    ddrMaster.io.dst   := U(0, ddrCfg.ADDR_W bits)           // RD 模式 dst 不参与
    ddrMaster.io.len   := U(32, 32 bits)                     // 一笔 32 B（= 32 像素的一个平面）
  }

  // ===========================================================================
  // ★★ T-S2b：**宽路 tile 循环**的 gather / 喂列 / 写回（写在最外层 ⇒ 覆盖上面所有默认驱动）
  // ===========================================================================
  //   · gather：`WIDERUN` 的喂列相位里，按"32 列一个 band"把 **Npl 个平面**的同一像素拼成一列；
  //     窗口行/列越界 ⇒ `z_pad` 列（不吃 RD）。
  //   · 喂列：`mpu.io.x/x_valid` 改由 gather 交付；`wCol/wRow` 由 gather 的"收下"事件推进。
  //   · 写回：`WRRUN` 相位的"宽路 tile WR"小 FSM —— 每 (co, tile 行) 一笔 32 B 对齐 + `wstrb` 掩码
  //     burst（段 = `tTw` 字节）。
  //   ★ T-S2b-i：gather 门**必须含** `wSt==3`（缺陷：起趟那拍 gather 还在空转、`switch(wxSt)` 用**上一趟的** `wRow` 跑 DECIDE ⇒ `wxSt` 提前进 EMIT ⇒ 新一趟第 0 列**没取 band** 就读 `xwBuf` 残留 ⇒ 保留首像素 `(oy0,ox0)` 错 1 个 halo 采样）；★ `tilingW=0` ⇒ 下面每一处 `when` 都恒假 ⇒ 既有行为**逐字节不变**。
  // ---------------------------------------------------------------------------
  val wxRun  = if (TILING) ((state === UnitExecPhase.WIDERUN) && tilingW && (wSt === U(3, 3 bits))) else ((state === UnitExecPhase.WIDERUN) && tilingW)
  val wxFeed = wxRun && wFeedSt
  when(wxRun) {
    // ★★ B3b：tile 宽路 gather 改**批式** —— `wxSgGo` 一拍 ⇒ `start(mode=3)` 跑整批；
    //   非 TILING 仍是既有的逐平面 `start(mode=1)`（逐字不变）。
    ddrMaster.io.start := (if (TILING) wxSgGo else ((wxSt === U(2, 2 bits)) && !wxK && !ddrMaster.io.busy))
    // ★★ B3b：mode 必须**保持到 CHK 采样那一拍**（CHK 在 start 下一拍才读 io.mode）⇒ 用 `wxSgRd`
    //   （整批收流期间为 1），不能用一拍脉冲 `wxSgGo`（实测：否则 CHK 读回 1 ⇒ 退化成 QRUN 单笔）。
    ddrMaster.io.mode  := (if (TILING) Mux(wxSgRd, U(3, 2 bits), U(1, 2 bits)) else U(1, 2 bits))
    ddrMaster.io.src   := (if (TILING) (wxFAdrR & U(0xFFFFFFE0L, 32 bits)) else wxFAdrR).resize(ddrCfg.ADDR_W)
    ddrMaster.io.dst   := U(0, ddrCfg.ADDR_W bits)
    ddrMaster.io.len   := U(32, 32 bits)
    if (TILING) {
      // 入队扫平面：一拍一项；`sg_ready` 未举 ⇒ 保持（天然反压）。扫完（8）⇒ 下一拍发 start。
      ddrMaster.io.sg_valid    := (wxSt === U(2, 2 bits)) && !wxSgDrn && !wxSgRd &&
                                  (wxSgScan < U(8, 4 bits)) && wxPNEV(wxSgScan(2 downto 0))
      ddrMaster.io.sg_addr     := wxPBBV(wxSgScan(2 downto 0)).resize(ddrCfg.ADDR_W)
      ddrMaster.io.sg_beatsM1  := U(3, 4 bits)
    }
  }
  when(wxRun) {
    if (TILING) { wxSgGo := False }                     // start(mode=3) 只准一拍
    switch(wxSt) {
      is(U(0, 2 bits)) { wxSt := U(1, 2 bits) }
      is(U(1, 2 bits)) {                                  // DECIDE
        when(wxNeedB) {
          wxSt := U(2, 2 bits); wxFPl := U(0, 3 bits); wxFBe := U(0, 2 bits); wxK := False
          wxOrphan := (if (TILING) ddrMaster.io.busy else False)
          wxFAdrR := (if (TILING) wxGAbs else wxBB); wxBBR := wxBB
          if (TILING) {
            // ★★ B3b：进门若主口还忙（残留一笔）⇒ 先排空（`wxSgDrn`），清全账后重新扫平面入队
            wxSgDrn := ddrMaster.io.busy; wxSgRd := False; wxSgGo := False
            wxSgEnq := U(0, 4 bits); wxSgScan := U(0, 4 bits); wxSgMask := B(0, 8 bits)
          }
        } otherwise { wxSt := U(3, 2 bits) }
      }
      is(U(2, 2 bits)) {                                  // FETCH
        if (TILING) {                                     // ★★ B3b：批式 —— 排空 / 入队扫描 / RD 收流
          when(wxSgDrn) {
            wxK := True
            when(ddrMaster.io.done) {                     // 残留排空：丢弃、清全账
              wxSgDrn := False; wxK := False; wxOrphan := False
              wxFPl := U(0, 3 bits); wxFBe := U(0, 2 bits)
              wxSgEnq := U(0, 4 bits); wxSgScan := U(0, 4 bits); wxSgMask := B(0, 8 bits)
              for (p <- 0 until 8) { wxBndV(p) := False }
            }
          } elsewhen(!wxSgRd) {                           // 入队扫描：一拍一项（`sg_ready` 反压）
            when(wxSgScan === U(8, 4 bits)) {
              when(wxSgEnq =/= U(0, 4 bits)) { wxSgRd := True; wxK := True; wxSgGo := True }
                .otherwise { wxSt := U(3, 2 bits) }
            } otherwise {
              when(wxPNEV(wxSgScan(2 downto 0))) {
                when(ddrMaster.io.sg_ready) {
                  wxSgPl(wxSgEnq(2 downto 0)) := wxSgScan(2 downto 0)
                  wxSgMask(wxSgScan(2 downto 0)) := True
                  wxSgBB(wxSgScan(2 downto 0)) := wxPBBV(wxSgScan(2 downto 0))
                  wxSgEnq := (wxSgEnq + 1).resize(4)
                  wxSgScan := (wxSgScan + 1).resize(4)
                }
              } otherwise { wxSgScan := (wxSgScan + 1).resize(4) }
            }
          } otherwise {                                   // RD：4 拍一项，按项序落 `xwBuf`
            when(ddrMaster.io.rd_valid) {
              xwBuf(((wxSgPl(wxFPl).resize(5) << 2) + wxFBe.resize(5)).resize(5)) := ddrMaster.io.rd_data.asBits
              wxFBe := (wxFBe + 1).resize(2)
              when(wxFBe === U(3, 2 bits)) { wxFPl := (wxFPl + 1).resize(3) }
            }
            when(ddrMaster.io.done) {
              // 整批回收：按**入队时的 band 快照**落每平面账本（不是末拍重算 ⇒ 趟被打断也自洽）
              for (p <- 0 until 8) { when(wxSgMask(p)) { wxBndV(p) := True; wxBndB(p) := wxSgBB(p) } }
              wxBandV := True
              wxSgRd := False; wxSgGo := False; wxK := False; wxSgMask := B(0, 8 bits)
              wxFPl := U(0, 3 bits); wxFBe := U(0, 2 bits)
              wxSt := U(1, 2 bits)
            }
          }
        } else {
          when(!wxK) {
            wxK := True
            when(ddrMaster.io.busy) { wxOrphan := True }
          } otherwise {
            when(ddrMaster.io.rd_valid) {
              xwBuf(((wxFPl.resize(5) << 2) + wxFBe.resize(5)).resize(5)) := ddrMaster.io.rd_data.asBits
              wxFBe := (wxFBe + 1).resize(2)
            }
            when(ddrMaster.io.done) {
              wxFBe := U(0, 2 bits); wxK := False
              when(wxOrphan) {                            // 残留一笔已排空 ⇒ 丢弃、清全账、从 plane 0 重取本窗口
                wxOrphan := False; wxFPl := U(0, 3 bits); wxFAdrR := wxBB
              } otherwise {
                when(wxFPl === U(7, 3 bits)) { wxBandV := True; wxSt := U(1, 2 bits) }
                  .otherwise { wxFPl := (wxFPl + 1).resize(3); wxFAdrR := (wxFAdrR + tInPixW).resize(32) }
              }
            }
          }
        }
      }
      is(U(3, 2 bits)) {                                  // EMIT：本列交给 mpu（收下才推进）
        when(mpu.io.x_ready) {
          wxSt := U(1, 2 bits)
          when(wCol === (tNCol.resize(cw) - U(1, cw bits))) {
            wCol := U(0, cw bits); wRow := (wRow + 1).resize(16); wxBandV := False
          } otherwise { wCol := (wCol + 1).resize(cw) }
        }
      }
      default { }
    }
  }
  // ---- 喂列：`mpu.io.x/x_valid` 由 gather 交付（`tilingW=0` ⇒ 死逻辑）----
  when(tilingW) {
    for (cl <- 0 until C) { mpu.io.x(cl) := wxCol(cl) }
    mpu.io.x_valid := wxFeed && (wxSt === U(3, 2 bits)) && (wRow < tNRow)
  }
  when(tilingW) { io.wide_x_ready := wxFeed && (wxSt === U(3, 2 bits)) }
  // ---- 部分和清零门：dense 的 `ci==0` 趟 / depthwise 的（唯一）对角趟 ⇒ 累加器从 0 起 ----
  mpu.io.ps_clr := tilingW && Mux(isDwW, True, wCi === U(0, 8 bits))

  // ---- 宽路 tile WR：每 (co, tile 行) 一笔 32 B 对齐 + `wstrb` 掩码 burst ----
  val wtOn   = (state === UnitExecPhase.WRRUN) && tilingW
  /** 本 (co, tile 行) 段的**拍数** = `len/8`（4 或 8）。 */
  val wtNB   = (wtLen >> 3).resize(4)
  /** LOAD：从 `wOutMem` 取出的字节（`readSync` 晚一拍 ⇒ 与上一拍给出的地址配套）。 */
  val wtByte = Vec((0 until C).map(k =>
    Mux(wtCl === U(k, 3 bits), wtRdWrd(k * 8 + 7 downto k * 8), B(0, 8 bits)))).reduce(_ | _)
  val wtByte2 = Vec((0 until C).map(k =>
    Mux(wtCl === U(k, 3 bits), wtRdWrd2(k * 8 + 7 downto k * 8), B(0, 8 bits)))).reduce(_ | _)
  /** 段内字节 `wtWB*8 + l`（共 64 B 的上界）相对**段起点**的有符号下标；`k ∈ [0,tTw)` 才是真数据。 */
  val wtRowS = (wtWB.resize(6) @@ U(0, 3 bits))
  val wtKk   = (0 until 8).map(l => ((((wtRowS.resize(7) + U(l, 7 bits)).resize(7)).asSInt - wtS0.resize(7).asSInt).resize(7)))
  val wtIn   = wtKk.map(k => (k >= S(0, 7 bits)) && (k < tTw.resize(7).asSInt))
  when(wtOn) {
    // ★★ W2（2026-10-23）：**预取引擎** —— `wtPfRun` 期间把下一段逐像素填进 `wtLdBank` 那一片
    //   （`wtRowB`/`wtRowB2` 双体）。地址/数据仍错一拍（`readSync`），但每拍一个像素。
    //   它**独立于 STREAM 跑**：STREAM 段 s 的同时预取 s+1 ⇒ 稳态每段 = max(33, STREAM) 而不是两者相加。
    val wtNPr = ((tTw + U(1, 16 bits)) >> 1).resize(6)          // 像素对数 = ceil(tTw/2)
    when(wtPfRun) {
      when(!wtLdS) { wtLdS := True; wtK := U(1, 6 bits) }
        .otherwise {
          val wtPA = (((wtK - 1).resize(6) << 1).resize(6))
          val wtPB = (wtPA + U(1, 6 bits))
          when(wtLdBank) { wtRowB2(wtPA.resize(5)) := wtByte; when(wtPB < tTw.resize(6)) { wtRowB2(wtPB.resize(5)) := wtByte2 } }
            .otherwise { wtRowB(wtPA.resize(5)) := wtByte; when(wtPB < tTw.resize(6)) { wtRowB(wtPB.resize(5)) := wtByte2 } }
          when(wtK === wtNPr) { wtLdS := False; wtPfRun := False; wtPfRdy := True }
            .otherwise { wtK := (wtK + 1).resize(6) }
        }
    }
    val wtLdLast  = (wtLdCo === (wideCoRows.resize(16) - U(1, 16 bits))) && (wtLdQ === (tTh - U(1, 16 bits)))
    val wtCurLast = (wtCo === (wideCoRows.resize(16) - U(1, 16 bits))) && (wtQ === (tTh - U(1, 16 bits)))
    switch(wtSt) {
      is(U(1, 2 bits)) {                                  // WAIT-PF：等（下一）段预取就绪 ⇒ 立刻开 STREAM
        when(wtPfRdy) {
          wtPfRdy := False; wtCo := wtLdCo; wtQ := wtLdQ; wtBank := wtLdBank
          wtSS := U(0, 2 bits); wtWB := U(0, 4 bits); wtRdy := False; wtSt := U(2, 2 bits)
          when(!wtLdLast) {                                // 再下一段立刻起预取（与本段 STREAM 重叠）
            when(wtLdCo === (wideCoRows.resize(16) - U(1, 16 bits))) { wtLdCo := U(0, 16 bits); wtLdQ := (wtLdQ + 1).resize(16) }
              .otherwise { wtLdCo := (wtLdCo + 1).resize(16) }
            wtLdBank := !wtLdBank; wtK := U(0, 6 bits); wtLdS := False; wtPfRun := True
          }
        }
      }
      is(U(2, 2 bits)) {                                  // STREAM（预取同时在填另一体）
        switch(wtSS) {
          is(U(0, 2 bits)) { wtSS := U(1, 2 bits) }        // 本拍举本笔的 `start`（见下面的主口驱动）
          is(U(1, 2 bits)) {                              // 攒一拍（8 B + 8 bit 掩码）；攒满 ⇒ `wtRdy`
            wtPack := Cat((0 until 8).map(l => Mux(wtIn(l), Mux(wtBank, wtRowB2(wtKk(l).asUInt.resize(5)), wtRowB(wtKk(l).asUInt.resize(5))), B(0, 8 bits))))
            wtStrb := Cat((0 until 8).map(l => Mux(wtIn(l), True, False)))
            when(!wtRdy) { wtRdy := True }
              .otherwise {
                when(ddrMaster.io.wr_ready) {
                  wtRdy := False
                  when(wtWB === (wtNB - U(1, 4 bits))) { wtSS := U(2, 2 bits) }
                    .otherwise { wtWB := (wtWB + 1).resize(4) }
                }
              }
          }
          is(U(2, 2 bits)) {                              // 等本笔出现（AW/W/B 全落地）
            when(ddrMaster.io.done) {
              wtRdy := False
              when(wtCurLast) { wtTileDone := True; wtSt := U(0, 2 bits) }
                .otherwise { wtSt := U(1, 2 bits) }        // 下一段多半已预取好 ⇒ 一两拍后直接开 STREAM
            }
          }
          default { }
        }
      }
      default { }
    }
  }
  // 写口：**无条件**覆盖（`tilingW=0` ⇒ 取回既有表达式 ⇒ 逐字节同形）
  // 主口（本笔 burst）：`start` 在 `wtSS==0` 那一拍脉冲；几何在整笔期间恒定
  when(wtOn) {
    ddrMaster.io.start := (wtSS === U(0, 2 bits))
    ddrMaster.io.mode  := U(2, 2 bits)
    ddrMaster.io.src   := dw.srcA.resize(ddrCfg.ADDR_W)
    ddrMaster.io.dst   := wtDst
    ddrMaster.io.len   := wtLen
  }


  // ---------------------------------------------------------------------------
  // 生产侧逻辑：DDR(RD) -> bufs(0)（整行写；行锁步见文件头）
  // ---------------------------------------------------------------------------
  // ★ C4b-B1：`rd_ready` 是**两条通路或在一起** —— DMA 装载（`WGTRUN` 相位）与激活读（`RDRUN`
  //   相位）。两者在时间上互斥（主 FSM 相位）⇒ 一个 `||` 就够（★ T-S3d 缺陷修-②：`tilingW` 支也要并 `wlTake`，
  //   否则权重 blob 装载挂住 —— 详见文件尾「T-S3d」；`TILING=false` 走本行 else 支 = 原文、网表逐字节不变）。
  ddrMaster.io.rd_ready := Mux(tilingW,
      (if (TILING) (wlTake || (((wxSt === U(2, 2 bits)) && (wxK || wxSgDrn)) && ddrMaster.io.rd_valid)) else (((wxSt === U(2, 2 bits)) && wxK) && ddrMaster.io.rd_valid)),
      wlTake || (mayWrite && rowIsDdr) || xgTake || tRdReady)
  for (ci <- 0 until C) {
    // ★ C4a.5b §4.5：**下边零填充行**（驱动方多喂的那一行）的码点 = 该层 `z_pad`（旧的硬编码 0）
    //   ★★ T-S2R：tiling 下越界的真列取 `z_pad`（`tProdWrPad`）；窗口内真列取主口那一拍。
    val beatByte = ddrMaster.io.rd_data((ci * 8 + 7) downto (ci * 8)).asSInt
    bufs(0).io.wr_data(ci) := Mux(tilingR, Mux(tProdWrPad, zpadR.asSInt, beatByte),
                                  Mux(rowIsDdr, beatByte, zpadR.asSInt))
  }
  bufs(0).io.wr_col     := pcol
  bufs(0).io.wr_en      := Mux(tilingR, tProdWrEn, wrNow)
  bufs(0).io.wr_row_adv := Mux(tilingR, tProdWrAdv, wrNow && (pcol === rowWm1))

  when(wrNow && !tilingR) {
    when(pcol === rowWm1) {
      pcol  := U(0, cw bits)
      pwant := pwant + 1
    } otherwise {
      pcol := (pcol + 1).resize(cw)
    }
  }

  // ---------------------------------------------------------------------------
  // ★ A-1a：每切片消费侧（读 `bufs(i)` 的消费口 -> 切片列进料）+ 生产侧（切片输出 -> 目标）
  // ---------------------------------------------------------------------------
  // 切片0 的中间写使能**保持 C3.9a/C3.9b 的逐字形状**（`run_fuse_head_ab.sh` 的外科式突变按此行抓它）：
  //   ★ A-1b：这一行**一字不动**（"忽略 OUT_TO_DDR" 的红证据仍按它抓）；链里"有没有下游"改用 `hasTail`。
  val midWrEn     = conv.io.y_valid && isHead
  val midWrEnMore = conv.io.y_valid && hasTail

  for (i <- 0 until L_MAX) {
    val sl  = slices(i)
    val rdY = bufs(i).io.rd_data
    sl.io.x := rdY
    sl.io.x_valid := False
    // ★★ T-S1：每个行缓冲的运行期行宽（行槽步长 = `rowW`；分配仍按 `WIDTH`）。
    bufs(i).io.rowW := rowW.resize(16)

    // 读地址：切片 i 读 `bufs(i)` 的**最新完成行**（rd_row=2，行锁步下与"正在读的行"同义）。
    //   ★ 观察口：`bufs(1)`（C3.9a 的 `fbMid`）在**跑完（IDLE）**才交回 `io.mid_rd_*`（既有闸门在此读回）。
    if (i == 1) {
      bufs(i).io.rd_row := Mux(state =/= UnitExecPhase.IDLE, U(2, 2 bits), io.mid_rd_row)
      bufs(i).io.rd_col := Mux(state =/= UnitExecPhase.IDLE, cCol(i), io.mid_rd_col)
    } else {
      bufs(i).io.rd_row := U(2, 2 bits)
      bufs(i).io.rd_col := cCol(i)
    }

    val active = chainLen > U(i, 16 bits)
    val wrote: UInt = if (i == 0) pwant else wroteB(i)

    // 行锁步门（见文件头"交错行锁步"）：切片 i 消费输入第 `k` 行会产出**输出第 `k-1` 行**；
    //   若它要写某个中间缓冲，则写该行需 `read(i+1) ≥ k-1`（对缓冲 i+1 的消费者让位）。否则恒真。
    //   ★ A-1b：`i==0` 这一档的"缓冲 1 有没有消费者"由 `hasTail`（= `chainLen ≥ 2`）给
    //     （A-1a 用的是 `FLAGS.bit1`；链描述符取链首的 FLAGS ⇒ bit1 恒 0，不能再用）。
    val gate: Bool = if (i == 0) {
      !hasTail || (cRow(i) === U(0, 16 bits)) || (cdone(1) >= (cRow(i) - U(1, 16 bits)))
    } else if (i < L_MAX - 1) {
      val wb = chainLen > U(i + 1, 16 bits)
      val g  = (cRow(i) === U(0, 16 bits)) || (cdone(i + 1) >= (cRow(i) - U(1, 16 bits)))
      (!wb) || g
    } else {
      True
    }

    switch(cst(i)) {
      is(UnitExecCons.WAIT) {
        when(inRun && active && (wrote > cRow(i)) && gate) { cst(i) := UnitExecCons.ADDR }
      }
      is(UnitExecCons.ADDR) {
        when(inRun) { cst(i) := UnitExecCons.PRES }
      }
      is(UnitExecCons.PRES) {
        sl.io.x_valid := True
        when(sl.io.x_ready) {
          when(cCol(i) === rowWm1) {
            cCol(i) := U(0, cw bits)
            cRow(i) := cRow(i) + 1
            cdone(i) := cdone(i) + 1
            when(cRow(i) === Mux(tilingR, (tNRow - U(1, 16 bits)), inRows)) { cst(i) := UnitExecCons.CDONE } otherwise { cst(i) := UnitExecCons.WAIT }
          } otherwise {
            cCol(i) := (cCol(i) + 1).resize(cw)
            cst(i)  := UnitExecCons.ADDR
          }
        }
      }
      is(UnitExecCons.CDONE) { }
    }

    // 输出行内列推进（一拍一个输出像素）
    when(sl.io.y_valid) {
      ocol(i) := Mux(ocol(i) === rowWm1, U(0, cw bits), (ocol(i) + 1).resize(cw))
    }
  }

  // ---------------------------------------------------------------------------
  // ★ A-1a：中间缓冲的**生产口**（切片 b-1 的输出 OR 该缓冲的 pad 注入）
  // ---------------------------------------------------------------------------
  for (b <- 1 until L_MAX) {
    val buf   = bufs(b)
    val srcY  = slices(b - 1).io.y
    // 切片 b-1 写 `bufs(b)`（真行）的使能：b==1 用 C3.9a/C3.9b 的逐字口 `midWrEn` **加上**
    //   "链里有下游"那一项（A-1b：`midWrEnMore = y_valid && hasTail`）；b>=2 用"该切片不是末切片"。
    //   ⇒ S2(`chainLen=1`,`bit0=1`) 两项都为假 ⇒ `bufs(1)` 未动（逐字同旧）；头档(`chainLen=1`,`bit0=0`)
    //     由 `midWrEn` 打开；链(`chainLen≥2`) 由任一项打开（头在片上 或 退化档 bit0=1）。
    val wrReal: Bool = if (b == 1) (midWrEn || midWrEnMore)
                       else (slices(b - 1).io.y_valid && (chainLen > U(b, 16 bits)))
    val padBeat = padGo(b)
    for (ci <- 0 until C) {
      buf.io.wr_data(ci) := Mux(padBeat, zpadR.asSInt, srcY(ci))   // ★ C4a.5b §4.5：pad 码点 = `z_pad`
    }
    buf.io.wr_col := Mux(padBeat, padCol(b), ocol(b - 1))
    buf.io.wr_en  := wrReal || padBeat
    val realRowAdv = wrReal && (ocol(b - 1) === rowWm1)
    val padRowAdv  = padBeat && (padCol(b) === rowWm1)
    buf.io.wr_row_adv := realRowAdv || padRowAdv
    when(realRowAdv || padRowAdv) { wroteB(b) := wroteB(b) + 1 }
  }

  // pad 注入子 FSM（中间缓冲 b=1..L_MAX-1 的"下边零填充"行）：切片 b-1 写完 IMG_H 行真行、
  //   且切片 b 读完这 IMG_H 行 ⇒ 注入一行全 0（与输入路径的 pad 行同一机制）。
  for (b <- 1 until L_MAX) {
    val padStart = (chainLen > U(b, 16 bits)) && (!padDone(b)) && (!padGo(b)) &&
                   (wroteB(b) === inRows) && (cdone(b) >= inRows)
    when(padStart) { padGo(b) := True; padCol(b) := U(0, cw bits) }
    when(padGo(b)) {
      when(padCol(b) === rowWm1) {
        padGo(b)   := False
        padDone(b) := True
      } otherwise {
        padCol(b) := (padCol(b) + 1).resize(cw)
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 输出计数 + WR 相位（与 C3.9b 同形：切片0 的 `pixIdx`、末切片的 `pixIdxT`）
  // ---------------------------------------------------------------------------
  when(conv.io.y_valid) { pixIdx := pixIdx + 1 }
  when(outTEn)          { pixIdxT := pixIdxT + 1 }

  // WR 相位：窄通路 = 既有的 `wrTotal`/`rdWord`；★ C4a.5b 宽层 = `wideWrWords`/`wPack`（见上"宽层"一节）
  //   `wrTotalEff`/`wrLenEff`/`wrDataEff`/`wrValidEff` 已在上面"宽层"一节里定义
  //   （两通路之和；`wideR=0` 退化回旧表达式）。
  //   ★ 宽层的"逐字节拼拍"推进全在 `wFill`（上面）里 ⇒ 这里**只**计总字数（长度门）；两条通路同形。
  //   ★★ T-S2R：tiling 下 WR 相位**每 tile 行一笔**：`ri` 在**本行内** 0..tTw-1，读 `outMem[tWrQ·tTw + ri]`。
  val tWrIdx   = ((tWrQ.resize(riW) * tTw.resize(riW)) + ri.resize(riW)).resize(riW)
  val wrValidT = (state === UnitExecPhase.WRRUN) && (ri < tTw.resize(32))
  ddrMaster.io.wr_valid := Mux(tilingR, wrValidT, wrValidEff)
  ddrMaster.io.wr_data  := Mux(tilingR, outMem.readAsync(tWrIdx), wrDataEff)
  ddrMaster.io.wstrb    := B(0xFF, 8 bits)   // ★★ T-S2b：默认"全字节有效"（tile 宽写另有覆盖，见下）
  when(tilingW) {
    ddrMaster.io.wr_valid := wtOn && (wtSS === U(1, 2 bits)) && wtRdy
    ddrMaster.io.wr_data  := wtPack
    ddrMaster.io.wstrb    := wtStrb
  }
  when(ddrMaster.io.wr_valid && ddrMaster.io.wr_ready) { ri := ri + 1 }

  // `bufs(1)` 的其余观察/自报口（不参与数据通路）
  io.mid_rd_data := bufs(1).io.rd_data
  io.head_mode   := headR
  io.mid_rows    := wroteB(1)
  io.tail_mode   := tailR
  io.tail_rows   := cdone(1)

  // 其余缓冲（`bufs(0)` 的生产口已由上面驱动；`bufs(L_MAX)` 通用末级本默认通路空闲）：
  //   `bufs(L_MAX)` 的消费口钉 0；其生产口钉空闲（wr_en=0）。
  if (L_MAX >= 1) {
    bufs(L_MAX).io.rd_row := U(0, 2 bits)
    bufs(L_MAX).io.rd_col := U(0, cw bits)
    bufs(L_MAX).io.rowW   := rowW.resize(16)  // ★★ T-S1：运行期行宽（additive 16 位口；本缓冲空闲，只是把口接上）
    for (ci <- 0 until C) { bufs(L_MAX).io.wr_data(ci) := S(0, 8 bits) }
    bufs(L_MAX).io.wr_col     := U(0, cw bits)
    bufs(L_MAX).io.wr_en      := False
    bufs(L_MAX).io.wr_row_adv := False
  }

  // ---------------------------------------------------------------------------
  // ★ per-run 复位（每次 `go`；C3.10 连跑的前置项）+ 每切片相位复位（prime）
  // ---------------------------------------------------------------------------
  val runStart = (state === UnitExecPhase.IDLE) && io.go && qShiftOk && chainOk && lidOk
  when(runStart) {
    pwant  := U(0, 16 bits)
    pcol   := U(0, cw bits)
    pixIdx := U(0, 32 bits)
    pixIdxT:= U(0, 32 bits)
    ri     := U(0, 32 bits)
    // ★ C4a.5b：锁存本次是否宽层 + 复位宽层子 FSM；并启动 `bias_adj` 装载器（按 `LAYER_ID`）
    wideR  := isWide
    wSt    := U(0, 3 bits)
    wEmitCnt := U(0, 32 bits)      // ★ C4a-R2：宽层"随 y_valid 走的像素号"（另见 `wSt==2` 的每趟复位）
    wCi    := U(0, 8 bits)
    wCob   := U(0, 4 bits)
    wK     := U(0, 10 bits)
    wRow   := U(0, 16 bits)
    wCol   := U(0, cw bits)
    ldBusy := True
    ldIdx  := U(0, 10 bits)
    ldEnd  := (nCo.resize(10) * U(8, 10 bits)).resize(10)
    mMode  := U(1, 2 bits)
    mSrc   := U(0, ddrCfg.ADDR_W bits)
    mDst   := U(0, ddrCfg.ADDR_W bits)
    mLen   := U(0, 32 bits)
    headR  := isHead
    // ★★ C4b-B1：**权重段的起点/段长在 `go` 这一拍寄存**（切断"调度器组合量 -> 主口地址/长度"这条长路，
    //   与 C4a-R2 的"描述符寄存化"同一套 idiom）；装载器指针一并回零（没走 DMA 的 run 里 wlRun 恒 0，
    //   ⇒ `wlWr`/`wlTake` 恒假、写口只吃信箱 —— 既有闸门逐字节不变）。
    wgtBaseR := io.wgt_dma_addr
    // ★★ C4b-B1b/B1c：长度按通路选 ——
    //   · `wgtLenR`（**RD 长度**，喂 `mLen`）：窄 = `chainLen*NENTRY`；宽 = `ceil32(N_i)`（B0 的对齐段长，
    //     32 B 整数倍 ⇒ DdrMaster 的 `len%32` 契约必过；`N_i%32==0` 时两者相等 ⇒ 既有宽单元逐字节不变）；
    //   · `wgtWrLenR`（**写入字节数**）：窄 = `wgtLenR`；宽 = `N_i`（多读的补位 0 **不写**）。
    wgtLenR  := Mux(dmaWide, (if (TILING) segLenC(0) else wgtWideRdLen), wgtLen)
    wgtWrLenR:= Mux(dmaWide, wgtWideLen, wgtLen)
    // ★★ C4b-B1c：零填充相位的计数器/在飞位（`wzGo` 只在"宽通路 + 需要补零"时为真 ⇒ 其余 run 零开销）
    wzCnt    := U(0, 32 bits)
    wzGo     := dmaWide && wzNeedW
    wlRun    := False
    wlCnt    := U(0, 32 bits)
    wlSlice  := U(0, selBits bits)
    wlAddr   := U(0, waBits bits)
    wlV      := False
    wlIdx    := U(0, 3 bits)
    // ★★ C4b-B1b：宽通路的落点状态（`dmaWide` 为假时 `wlWideR=0` ⇒ 这三个指针与基址**不进**任何写口）
    wlWideR  := dmaWide
    wlTap    := U(0, 4 bits)
    wlCi     := U(0, 16 bits)
    wlCo     := U(0, 16 bits)
    //   ★ A-1b：`tail_mode` = "本次运行**有没有尾在跑**" —— A-1a 锁的是 `FLAGS.bit1`，A-1b 改成
    //     `hasTail`（= `chainLen ≥ 2`），因为链描述符的 FLAGS 取链首条目 ⇒ bit1 恒 0。
    tailR  := hasTail
    chainR := chainLen
    for (i <- 0 until L_MAX) {
      cRow(i) := U(0, 16 bits)
      cCol(i) := U(0, cw bits)
      cst(i)  := UnitExecCons.WAIT
      cdone(i):= U(0, 16 bits)
      ocol(i) := U(0, cw bits)
    }
    for (b <- 1 until L_MAX) {
      wroteB(b)  := U(0, 16 bits)
      padGo(b)   := False
      padCol(b)  := U(0, cw bits)
      padDone(b) := False
    }
  }

  // 每切片相位复位（additive 口）：把每个 `Conv3x3Slice`（+ 其 `LineBuffer`）的 per-image 相位清回上电态。
  // ★★ C3.18 R3-6：**每切片一份寄存器化副本**，不再让一张 `runStart` 网直接扇出到 8 个切片的 `prime` 口。
  //   实测证据（板级 device_map `device_map_high_fanout_singnal.db`，R1/R2 同一份网表）：第 3 大扇出网是
  //     `u_soc/u_npu/layerSched_1/unitExec_1/N3598 [5]`，driver `unitExec_1/N2672/gateop`，**扇出 17,617**。
  //   定名（按综合网表 `.vm` 的 driver LUT 与源行回查）：该 LUT 的源位置就是本文件 `runStart` 所在那条
  //   IDLE/`go` 判定（`when_UnitExec` 的 IDLE 分支），其负载在本单元内是**全部 per-run 寄存器**
  //   （`cRow_*`／`cCol_*`／`cst_*`／`cdone_*`／`ocol_*`／`wroteB_*`／`pad*_*`／`pwant`／`pcol`／
  //   `pixIdx(T)`／`ri`／`mMode/mSrc/mDst/mLen`／`headR/tailR/chainR`），在片内则是 `Conv3x3Slice` 的
  //   `colWin` + 其 `LineBuffer` 的 `hist0/hist1/col` 清位 ⇒ **就是 `runStart` 本身**
  //   （另一候选 `sl.io.x_valid` 扇出只有 1/片，实测不是它；见报告）。
  //   做法：`runStart` 只驱动 8 个 FF 的 D 端（扇出 8），每个 FF 的 Q 只喂**自己那一片**的 `prime`：
  //   片内 ~620 个负载聚在一个切片例化里，由本地布线/缓冲消化 ⇒ 单网扇出降两个数量级。
  //   ★ 代价（明写）：per-image 相位清**晚 1 拍**（本单元自己的 per-run 复位仍在 `runStart` 当拍）。
  //   ★ 安全性（可推，不是"应该没事"）：`runStart` 那一拍本单元已回 IDLE、`cst(i)` 已被复位成 WAIT；
  //     切片要到 `cst(i) == PRES` 才会看到 `x_valid`，而 `cst(i)` 离开 WAIT 还要求 `inRun`
  //     （主 FSM 需 IDLE→RDSTART→RDRUN，≥2 拍）**且**生产者已写出第一列（DDR 读延迟，几十拍）
  //     ⇒ 第一拍 `x_valid` 不早于 `runStart`+4 拍；prime 晚 1 拍仍有 ≥3 拍余量。
  //     逐字节证据：`run_unitexec_ab.sh` 的"第二次 `go` 连跑须与第一次逐字节相同"判据，加上
  //     `run_chain/run_fuse/run_fuse_head/run_sched/run_nputop_sched` 的多单元帧判据，全部 MISMATCH=0。
  //   ★★ T-S2R：tiling 下**每个 tile 起始**（`RDSTART` 那一拍）也要脉冲一次 —— 切片的 `LineBuffer`
  //     相位在整层内是连续的（见 `Conv3x3Slice.scala`「prime」），换 tile 必须清回上电态。
  for (i <- 0 until L_MAX) { primeR(i) := runStart || (tilingR && (state === UnitExecPhase.RDSTART)) }
  for (i <- 0 until L_MAX) { slices(i).io.prime := primeR(i) }

  // ---------------------------------------------------------------------------
  // ★ C4a.5b：`bias_adj` 装载器（`readSync` 1 拍延迟）+ 宽层自报
  // ---------------------------------------------------------------------------
  when(ldBusy) {
    ldIdx := (ldIdx + 1).resize(10)
    when(ldIdx === ldEnd) { ldBusy := False }
  }
  // `readSync` 的输出在下一拍到达 ⇒ 用**延迟一拍**的下标与有效位对齐后提交
  when(ldV && (ldIdxD < ldEnd)) { biasReg(ldIdxD.resize(bIdxW bits)) := ldWord }

  io.wide_on     := wideR
  // ★★ C4b-C2：趟数自报 —— dense = `nCi*nCo`（一般趟，逐字沿用 C1）；depthwise = `nCo`（**对角趟**，
  //   实测趟数 `nCo` 而非 `nCo*nCi`；`C=64` ⇒ 8 趟 vs 64 趟）。
  io.wide_passes := Mux(isDwW, nCo, (nCi * nCo)).resize(16)
  io.rtl_m       := mR.asUInt
  io.rtl_zpad    := zpadR.asSInt
  io.rtl_zy      := zyR.asSInt
  io.rtl_layer   := layerIdx
  /** ★ C4b-B1：装载器逐字节计数（本次 `go` 真正写进 WeightStore 的权重字节数；未走 DMA 恒 0）。 */
  io.wgt_bytes   := wlCnt

  // ---------------------------------------------------------------------------
  // 状态 / 观察
  // ---------------------------------------------------------------------------
  io.busy     := (state =/= UnitExecPhase.IDLE)
  io.done     := doneR
  io.err      := errR
  io.rd_bytes := ddrMaster.io.rd_bytes
  io.wr_bytes := ddrMaster.io.wr_bytes

  // ===========================================================================
  // ★★ A'-2（2026-10-15）：**逐片几何入参 + 逐成员权重段基址**（只在 `TILING=true` 的网表里存在）
  //   口径 = A'-1（`docs/superpowers/plans/2026-10-14-y1-frame-runnable.md` 的 Task A'-1）。
  //   ★ 位置（类体**末尾**、全部既有语句之后）是**行数中性**纪律的一部分：SpinalHDL
  //   把源码行号编进内部网名（`_zz_*` / `when_*`），而 `TILING=false` 的三份网表（`gen/UnitExec.v` /
  //   `_w32` / `_w640`）必须**逐字节不变**（冻结证书）⇒ 旧语句的行号一根都不能动。
  //   本节在 `TILING=false` 下**不 elaborate**（连一根线都不加）；端口本体在类体开头的
  //   `GROUP` 那一行创建（落在**既有行**上 = 行数中性；组件级入参是**具名成员**
  //   ⇒ 调用方 `LayerSched` 能按成员名驱动：`unitExec.chain_cin(k) := …`）。
  // ===========================================================================
  /** ★★ A'-2：逐成员段长 `len(k) = ceil32(N_k)`，`N_k = C_out(k)·(C_in(k)/GROUP(k))·9`
    *   （A'-1.2 的冻结式）。`GROUP ∈ {1, C_in}`（depthwise 是后者）⇒ 2 选 1，**不做除法**；
    *   其余 GROUP 由 `grpOkW` 拦。与装载器的 `wgtWideLen`/`wgtWideRdLen` **同式**（`C_out*cgW*9` + `ceil32`）
    *   —— A'-1.2 的口径：段长是**逐成员**量，而装载器今天只跑 `chainLen==1`（`wgtLoadOk`）
    *   ⇒ `len(0)` 就是它的段长（见上面 `wgtLenR` 那一行）。 */
  def segLenC(k: Int): UInt = {
    val cg = Mux(chain_grp(k) === U(1, 8 bits), chain_cin(k), U(1, 16 bits))
    val n  = ((chain_cout(k).resize(32) * cg.resize(32)).resize(32) * U(9, 32 bits)).resize(32)
    (((n + U(31, 32 bits)) >> 5) << 5).resize(32)
  }
  /** ★★ A'-2：逐成员**基址** `base(0) = io.wgt_dma_addr`（口径不变）、
    *   `base(k+1) = base(k) + len(k)` ⇒ `base(k)` **片上推导**，不需要任何新外部编程
    *   （`WGT_BLOB_BASE`（邮箱区域 6）仍是唯一的外部编程点）。 */
  def segBaseC(k: Int): UInt = (0 until k).map(j => segLenC(j)).foldLeft(io.wgt_dma_addr.resize(32)) {
    (a, l) => (a + l).resize(32)
  }
  /** ★ 槽 0 与**链描述符**冗余 ⇒ 断言相等（A'-1.1）：两条来源（链描述符 vs 逐片端口）
    *   绝不静默分叉。★ 比的是**端口**（不是 `chainCinR(0)` 寄存器 —— 它在 `go` 那一拍还是上一次的值）。 */
  def slot0Ok: Bool = (chain_cin(0) === dw.cIn) && (chain_cout(0) === dw.cOut) &&
                      (chain_grp(0) === dw.group) && (chain_qsh(0) === dw.qShift) &&
                      (chain_lid(0) === dw.layerId) &&
                      (chain_dw(0) === (dw.tpe === U(DescType.DW, 8 bits))) &&
                      (chain_1x1(0) === (dw.tpe === U(DescType.CONV1, 8 bits)))
  /** ★★ A'-2 的**引擎互锁**（临时；宽链引擎落地时删）：宽链引擎**尚未实现** ⇒ 链上非首片的
    *   `(C_IN, C_OUT, GROUP, QUANT_SHIFT)` 必须与**链首**相等，否则本单元算出来的只有链首的几何
    *   ⇒ **静默错值**。这四条正是旧 `LayerSched.geomEq` 里被本片放开的那四个字段（空间几何
    *   `IMG_W/IMG_H/STRIDE/PAD` 的相等仍在 `LayerSched` 的“可链谓词”里）⇒ 行为对既有链路**不变**：
    *   旧口径下这类链本来就被 `LayerSched` 响亮拦下（只是从“扫链相位”挪到“`go` 相位”）。 */
  def engEq: Bool = (1 until L_MAX).map(k =>
    (!(chainLen > U(k, 16 bits))) || ((chain_cin(k) === chain_cin(0)) && (chain_cout(k) === chain_cout(0)) &&
      (chain_grp(k) === chain_grp(0)) && (chain_qsh(k) === chain_qsh(0)))).reduce(_ && _)
  /** 几何门总判据（`go` 那一刻；`false` ⇒ 与 `!qShiftOk` 同一条响亮 err + 零搬运）。 */
  def chainGeomOk: Bool = slot0Ok && engEq
  if (TILING) {
    // ---- 在片锁存（`go` 那一拍；供引擎与判据回读 —— 判据面 = 层级引用，见 `rtl_test/LayerSchedTb.v`）----
    val chainCinR  = Vec.fill(L_MAX)(Reg(UInt(16 bits)) init 0); chainCinR.setName("chainCinR")
    val chainCoutR = Vec.fill(L_MAX)(Reg(UInt(16 bits)) init 0); chainCoutR.setName("chainCoutR")
    val chainGrpR  = Vec.fill(L_MAX)(Reg(UInt(8 bits))  init 0); chainGrpR.setName("chainGrpR")
    val chainQshR  = Vec.fill(L_MAX)(Reg(UInt(8 bits))  init 0); chainQshR.setName("chainQshR")
    val chainLidR  = Vec.fill(L_MAX)(Reg(UInt(8 bits))  init 0); chainLidR.setName("chainLidR")
    val chainDwR   = Vec.fill(L_MAX)(Reg(Bool())        init False); chainDwR.setName("chainDwR")
    val chainX1R   = Vec.fill(L_MAX)(Reg(Bool())        init False); chainX1R.setName("chainX1R")
    val chainSegLenR  = Vec.fill(L_MAX)(Reg(UInt(32 bits)) init 0); chainSegLenR.setName("chainSegLenR")
    val chainSegBaseR = Vec.fill(L_MAX)(Reg(UInt(ddrCfg.ADDR_W bits)) init 0); chainSegBaseR.setName("chainSegBaseR")
    /** 本条链的**段末** = `base(chainLen)` = `Σ_k len(k)`（帧级记账的交叉对账面）。 */
    val chainSegEndR  = Reg(UInt(32 bits)) init 0; chainSegEndR.setName("chainSegEndR")
    /** 几何门失败码（观察/判据用；`0` = 过、1` = 槽 0 与描述符不一致、2` = 引擎互锁）。 */
    val chainGateFailR = Reg(UInt(2 bits)) init 0; chainGateFailR.setName("chainGateFailR")

    // ---- ★★ A'-2 的**观察口**（纯多路选择，无新存储；判据面）----
    //   `chain_rep_sel` 选槽（0..7）⇒ 读出该槽**收到的几何** + 片上推导的**段长/基址**；
    //   `sel == 8` ⇒ 段末 `Σ_k len(k)`。`chain_rep_gate` 恒 = 几何门失败码（01/2）。
    //   为什么需要它：这些寄存器在本片里**没有功能读者**（引擎还没落地）
    //   ⇒ SpinalHDL 会把它们作为**死代码剪掉**（实测：无本口时网表里一个寄存器都不在）。
    //   本口就是那个读者（也是 TB/闸门的回读面）。 */
    val chain_rep_sel  = in  UInt (4 bits); chain_rep_sel.setName("chain_rep_sel")
    val chain_rep_cin  = out UInt (16 bits); chain_rep_cin.setName("chain_rep_cin")
    val chain_rep_cout = out UInt (16 bits); chain_rep_cout.setName("chain_rep_cout")
    val chain_rep_grp  = out UInt (8 bits); chain_rep_grp.setName("chain_rep_grp")
    val chain_rep_qsh  = out UInt (8 bits); chain_rep_qsh.setName("chain_rep_qsh")
    val chain_rep_lid  = out UInt (8 bits); chain_rep_lid.setName("chain_rep_lid")
    val chain_rep_dw   = out Bool (); chain_rep_dw.setName("chain_rep_dw")
    val chain_rep_x1   = out Bool (); chain_rep_x1.setName("chain_rep_x1")
    val chain_rep_len  = out UInt (32 bits); chain_rep_len.setName("chain_rep_len")
    val chain_rep_base = out UInt (ddrCfg.ADDR_W bits); chain_rep_base.setName("chain_rep_base")
    val chain_rep_end  = out UInt (32 bits); chain_rep_end.setName("chain_rep_end")
    val chain_rep_gate = out UInt (2 bits); chain_rep_gate.setName("chain_rep_gate")
    val repSlotW   = log2Up(L_MAX) max 1
    val repSlot    = chain_rep_sel(repSlotW - 1 downto 0)
    val repIsSlot  = chain_rep_sel < U(L_MAX, 4 bits)
    chain_rep_cin  := Mux(repIsSlot, chainCinR(repSlot),   U(0, 16 bits))
    chain_rep_cout := Mux(repIsSlot, chainCoutR(repSlot),  U(0, 16 bits))
    chain_rep_grp  := Mux(repIsSlot, chainGrpR(repSlot),   U(0, 8 bits))
    chain_rep_qsh  := Mux(repIsSlot, chainQshR(repSlot),   U(0, 8 bits))
    chain_rep_lid  := Mux(repIsSlot, chainLidR(repSlot),   U(0, 8 bits))
    chain_rep_dw   := Mux(repIsSlot, chainDwR(repSlot),    False)
    chain_rep_x1   := Mux(repIsSlot, chainX1R(repSlot),    False)
    chain_rep_len  := Mux(repIsSlot, chainSegLenR(repSlot), U(0, 32 bits))
    chain_rep_base := Mux(repIsSlot, chainSegBaseR(repSlot), U(0, ddrCfg.ADDR_W bits))
    chain_rep_end  := Mux(repIsSlot, U(0, 32 bits), chainSegEndR)
    chain_rep_gate := chainGateFailR

    when((state === UnitExecPhase.IDLE) && io.go) {
      for (k <- 0 until L_MAX) {
        chainCinR(k)      := chain_cin(k)
        chainCoutR(k)     := chain_cout(k)
        chainGrpR(k)      := chain_grp(k)
        chainQshR(k)      := chain_qsh(k)
        chainLidR(k)      := chain_lid(k)
        chainDwR(k)       := chain_dw(k)
        chainX1R(k)       := chain_1x1(k)
        chainSegLenR(k)   := segLenC(k)
        chainSegBaseR(k)  := segBaseC(k).resize(ddrCfg.ADDR_W)
      }
      chainSegEndR := (0 until L_MAX).map(k => Mux(chainLen > U(k, 16 bits), segLenC(k), U(0, 32 bits)))
        .reduce((a, b) => (a.resize(33) + b.resize(33)).resize(32))
      chainGateFailR := Mux(!slot0Ok, U(1, 2 bits), Mux(!engEq, U(2, 2 bits), U(0, 2 bits)))
    }
  }

  // ===========================================================================
  // ★★ NPU v2 §4.6-5（slice A，2026-10-16）：**1×1 只发 1 个 tap-beat**（宽通路的驱动 + 观测）
  // ===========================================================================
  // 位置与纪律：本节追加在类体**全部既有语句之后**（与上面 A'-2 一节同一套行数中性纪律）——
  //   `TILING=false` 不 elaborate（一根线一个端口都不加）⇒ 三份冻结网表（`gen/UnitExec.v` /
  //   `_w32` / `_w640`）逐字节不变；`TILING=true`（= `gen/UnitExec_tiled.v` / `LayerSched` / `NpuTop`
  //   的展开）才落硬件。
  //
  // 1×1 的真源 = **描述符 TYPE `0x02`**（`DescType.CONV1`）——为什么不是 `chain_1x1` 位：
  //   · `chain_1x1` 是 `LayerSched` 从**同一件事**派生出来的副本（`chainX1R(k) := (tpe == CONV1)`，
  //     见 `LayerSched.scala` 那一路），它存在的意义是**逐片**几何（链的 k 号成员）；而本单元今天
  //     只跑 `chainLen==1` 的宽层（`wideGeomOk` 的既有前提）⇒ 链首 == 本单元，且 `slot0Ok`
  //     **已断言** `chain_1x1(0) === (dw.tpe == U(DescType.CONV1))`（两条来源在能跑到这里的 run 上
  //     是同一件事）。`dw.tpe` 是**运行期权威字段**（描述符第 0 字的低 8 位，`go` 那一刻已锁存），
  //     不依赖任何外部接线 ⇒ 选它做真源、把"1×1 才跳拍"这条口径钉在**被执行的描述符本身**上。
  //   · 副作用（**明写**）：`chain_1x1(1..7)` 在 `chainLen≥2` 时**不**参与本判断；宽链今天仍然
  //     `go` 那一刻响亮 err（`chainLen==1` 前提）⇒ 不存在"链中片被静默按链首 TYPE 跳拍"的通路。
  //     宽链引擎落地时（T-S3f）应把真源改成**逐片**（`chainX1R(k)`），那时本节的两行要跟着改。
  //
  // 停点/时序（逐条对着 `dw.tpe` 的取值域看，不靠"应该没事"）：
  //   · `x1W` 只在 `IDLE ∧ go` 那一拍更新 ⇒ 整次 run 恒定；窄通路 run（`mpu` 空闲）也照写，
  //     但 `mpu` 不在跑 ⇒ 无效果（**不**给窄通路接线：本代真表 26 个 1×1 单元全是宽层，
  //     `narrowShape ⇒ C_in==C_out==8` 一个都不是 1×1 —— 闸门 `run_x1skip_ab.sh` 的 [0] 节
  //     从 `gen/wgt_index.json` 断言这条；窄通路的 TYPE=0x02 只出现在 C3 老夹具里，且那里的
  //     "1×1"是**中心抽头**的 3×3 测试实现 ⇒ 绝不能跳拍，否则夹具数值会变）。
  //   · `tilingW`（宽路 tile 循环）与普通宽路**共用**这个 `mpu` ⇒ 两种行进路径自动都拿到跳拍。
  //
  // `x1_beats`（出）= `mpu.obs_beats` 的直通：**tap-beat 计数**（上电起累计，见 `Conv3x3Slice`
  //   文件尾）。它是 P0b 那条账 `beats_issued = taps·passes·H·W` 的实测面：同一作业、同一权重、
  //   同一几何，TYPE=1（9 拍/像素/趟）对 TYPE=2（1 拍/像素/趟）⇒ **9.00×**（闸门按预测值断言）。
  // ===========================================================================
  if (TILING) {
    /** 本次 run 的"1×1 跳拍"开关（`go` 那一拍从描述符 TYPE 锁存）。 */
    val x1W = Reg(Bool()) init False
    when((state === UnitExecPhase.IDLE) && io.go) { x1W := (dw.tpe === U(DescType.CONV1, 8 bits)) }
    mpu.one_x1 := x1W
    val x1Beats = out UInt(32 bits); x1Beats.setName("x1_beats")
    x1Beats := mpu.obs_beats
  }

  // ===========================================================================
  // ★★ NPU v2 切片 B1（2026-10-16）：**dw 逐 lane x 档**（AFTER1）的驱动 —— 一行接线
  // ===========================================================================
  // 位置与纪律：本节追加在类体**全部既有语句之后**（与上面 slice A 一节同一套行数中性纪律）——
  //   `TILING=false` 不 elaborate（一根线一个端口都不加）⇒ 三份冻结网表（`gen/UnitExec.v` /
  //   `_w32` / `_w640`）逐字节不变；`TILING=true`（= `gen/UnitExec_tiled.v` / `LayerSched` /
  //   `NpuTop` 的展开）才落硬件（`DW = TILING` 已在 `mpu` 的例化行上）。
  //
  // 真源 = **`isDwW`**（`(GROUP != 0) && (GROUP == C_in) && (C_in == C_out)`，本文件早已有之、
  //   且与装载器零填前提 `grpOkW` 的 depthwise 分支**取同式**）—— 描述符字段 ⇒ 运行期权威。
  //   锁存口径**逐字照抄 `x1W`**：只在 `IDLE ∧ go` 那一拍更新 ⇒ 整次 run 恒定（`io.desc` 只在
  //   `go` 那一刻被保证有效；dense/窄通路 run 也照写 `dwW=0` ⇒ 无效果）。
  // 拍数（实测面 = `x1_beats` 口 = `mpu.obs_beats`）：dw 档 **1 拍/像素/趟**（dense 仍 9 拍）⇒
  //   `mac_account.py` 的 dw 类 `beats_issued = taps·passes·H·W` 从 9× 收到 1×（闸门按预测量断言）。
  // 代价（B-1 探针 dev_map 实测，只摊在**这一个**切片实例上）：+317 LUT / +8 APM / DRM 0。
  // ===========================================================================
  if (TILING) {
    /** 本次 run 的"dw 打包"开关：`go` 那一拍从描述符几何锁存（与 `x1W` 同一套写法）。 */
    val dwW = Reg(Bool()) init False
    when((state === UnitExecPhase.IDLE) && io.go) { dwW := isDwW }
    mpu.dw_mode := dwW
  }

  // ===========================================================================
  // ★★ NPU v2 切片 C2（2026-10-16）：**dense ci-inner（DCI）**的驱动 —— 一行接线 + 一个闩存
  // ===========================================================================
  // 位置与纪律：本节追加在类体**全部既有语句之后**（与上面 slice A / B1 两节同一套行数中性纪律）——
  //   `TILING=false` 不 elaborate（一根线一个端口都不加）⇒ 三份冻结网表（`gen/UnitExec.v` /
  //   `_w32` / `_w640`）逐字节不变；`TILING=true`（= `gen/UnitExec_tiled.v` / `LayerSched` /
  //   `NpuTop` 的展开）才落硬件（`DCI = TILING` 已在 `mpu` 的例化行上）。
  //
  // 真源（切片 C-1 钉死、本片**逐字复用**）：`isDciW = 宽路 ∧ dense(GROUP==1) ∧ nCi==1 ∧
  //   0 < C_in ≤ 4`。在本单元的既有信号上逐项落实：
  //   · 宽路 —— 本节只接 `mpu`（宽通路）；窄通路（`C_in==C_out==8 ∧ GROUP==1`）`C_in=8 > 4`
  //     ⇒ 真表里**没有任何窄层**满足本判据（`run_dci_ab.sh` 的前置项现场重扫这条）；
  //   · dense —— `dw.group === 1`（**不是** `=/= 0`：真表 dw 的 GROUP 字段 = C_in（4..64），
  //     `=/= 0` 会把 dw C=4 的单位误纳进来；这一条是 C-1 探针口径的逐字翻译）；
  //   · nCi==1 ∧ 0<C_in≤4 —— `0 < C_in ≤ 4` 蕴含 `nCi = ceil(C_in/8) == 1`，写成一条界即可
  //     （两条等价，C-1 的判据文本同时列了两者）；
  //   · `c3_cin` = 本层 `C_in`（4 bit；同拍闩存 —— `io.desc` 只在 `go` 那一刻被保证有效）。
  // 锁存口径逐字照抄 `x1W`/`dwW`：只在 `IDLE ∧ go` 那一拍更新 ⇒ 整次 run 恒定；dense 的其它几何
  //   （C_in>4）与 dw 档都照写 `dciW=0` ⇒ 无效果（与改动前逐拍同形）。
  // 拍数（实测面 = `x1_beats` 口 = `mpu.obs_beats`）：DCI 档 **C_in 拍/像素/趟**（dense 其它档
  //   仍 9 拍）⇒ 真表 `Conv_0`（C_in=3）9→3 拍 = **3.00×**、真表 `1→1`（C_in=1）9→1 = **9.00×**
  //   （闸门 `tools/run_dci_ab.sh` 在产品网表上按预测量断言）。
  // 代价（C-1 探针 dev_map 实测，含 p8 的 A 级寄存纪律）：+1,072 LUT/切片当量；集成 Δ 由本片
  //   `dev_map` 重测（探针 ≠ 集成，B1 前例 3.57×）。
  // ===========================================================================
  if (TILING) {
    /** 本次 run 的"ci-inner 打包"开关：`go` 那一拍从描述符几何锁存（与 `x1W`/`dwW` 同一套写法）。 */
    val dciW = Reg(Bool()) init False
    /** 本层的 `C_in`（切片 DCI 相位跳拍的长度；同拍闩存）。 */
    val c3CinR = Reg(UInt(4 bits)) init (0)
    when((state === UnitExecPhase.IDLE) && io.go) {
      dciW   := (dw.group === U(1, 8 bits)) && (dw.cIn =/= U(0, 16 bits)) && (dw.cIn <= U(4, 16 bits))
      c3CinR := dw.cIn(3 downto 0)
    }
    mpu.dci_mode := dciW
    mpu.c3_cin := c3CinR
  }

  // ===========================================================================
  // ★★ Y1-Timing（2026-10-16，npu_clk 追钟轮）：**requant M 的逐消费者再寄存**（fanout 广播一刀切）
  // ===========================================================================
  // 位置与纪律：声明与覆盖都落在**既有行**（行数中性，见本文件三条带 ★ 标记的行）——
  //   `TILING=false` 不 elaborate（一根线一根寄存器都不加；`slices(i).io.requant_m := mR.asUInt` 的
  //   原表达式逐字保留在 else 支）⇒ 三份冻结网表逐字节不变；`TILING=true`（板级展开）才落硬件。
  //
  // 实测锚（`sim/reglogs/pds_pnr_c4a_b1_p10.000/prj_tasks/pnr_1/place_route/report_timing/yeshen_mini_board_top.rtr`，
  //   `YESHENMINI_SYNTH_MODE=speed` 档，`npu_clk` 20 ns 约束）：最坏三条 setup 路径**全部**是
  //     `mzRam_{2,4}/QB（tco 1.644）→ net rtl_m（fanout=216，布线 6.5–8.8 ns）→ sliceRest_N/mpu 的
  //      APM 级联（33×32 乘，逻辑 4.8 ns）→ pLoR/pHiR 寄存器`
  //   到达 21.094 / 21.050 / 19.951 ns（布线占 63–65%），即"高扇出广播"这一味的**复发**（项目史 R3-6 同因）。
  //   根因：C4a-R2 在 mzRam 读出后落的 `mR` 一级寄存，在本代 PDS 流程里被挪掉/并入 DRAM 输出
  //   （B1 轮 rtr 的 startpoint 直接是 DRAM 输出 QB）⇒ 一张整层恒定的裸网直落 9 个消费者的乘法器输入锥。
  //   **不是逻辑深度、不是布线拥塞主导，是单网扇出+跨片距离。**
  // 修法（v1，最小）：`mR` 之后加**逐消费者副本**（9 份 32 bit）——`TILING=true` 的展开里落 288 FF。
  //   ★ 实测发现（本片，写进账）：PDS 前端的 redundant-instance 消除会把 **D 端同网的同钟寄存器合并成
  //   一个**（报文：`Removed inst mRB1_1..7/mRBm that is redundant to mRB1_0[31:0]`）⇒ 实际生效结构 =
  //   **mR 之后再压一级寄存**（单份），broadcast 网从"DRAM 输出直落乘法器"变成"寄存器输出直落乘法器"。
  //   同一片试过 v2（把副本放进 `Conv3x3Slice` 内部、D = 各实例自己的输入网），dev_map 实测**同样被合并**
  //   （`Removed ... mpu/sl/mMul redundant to conv/mMul`）⇒ 收益相同、diff 更大，**不保留**（v1 是定稿）。
  // 数值（逐字同 R2 的论证，只是再晚一拍）：`M` 在一层内**恒定**（只在 `go`/层边界随 `layerIdx`/信箱
  //   更新），一层的**首次 requant** 远在 `go` 之后 ≥13 拍（收列+9 tap+出数）⇒ 再迟一拍不改变任何
  //   一次乘法的输入值；寄存器初值 = 表初值（`2^24` 单位乘子）= `mR` 的复位值 ⇒ 上电即等价。
  // 代价（dev_map 实测 `y1/pds/devmap_c4a_t1.log` vs C2 基线）：**LUT 126,222（−6）/ FF 149,369（+1）/
  //   APM 542（0）/ DRM 247.5（0）**——合并后净价签≈0（288 份本要 +288 FF，被合并吃回）。
  // 实测（本轮 PnR，`sim/reglogs/pds_pnr_c4a_t18b_p10.000`，18.4 ns 约束）：**All Constraints Met**，
  //   `npu_clk` estimated **56.2683 MHz**（17.7720 ns，slack +0.628）——追钟目标 ≥54.18 MHz **达标**。
  // ===========================================================================

  // ===========================================================================
  // ★★ B1（2026-10-20）：**宽层 tile 输入跨 co-block 复用**（tileBuf 填充 / 重放 / 趟序重排 / 计数）
  // ===========================================================================
  // 位置与纪律（与上面 A'-2 / slice A / B1 / C2 / Y1-Timing 各节同一套）：本节追加在类体**最后一条
  //   语句之后** ⇒ 既有语句的行号一根没动；`TILING=false` 不 elaborate（一根线、一个寄存器、一个端口
  //   都不加）⇒ 三份冻结网表（`gen/UnitExec.v` / `_w32` / `_w640`）**逐字节不变**（判据见
  //   `tools/run_b1_tilebuf_ab.sh` 的 [0] 节：与"改动前的源码现生成"逐字节对账）。
  //
  // 治的是什么（map §1/§2/§6.3 的 B1）：宽层 dense 的趟序是"co-block 外、ci-block 内"⇒ **每个
  //   co-block 都把同一个 ci-block 的输入从 DDR 重读一遍**（`nCo` 倍）。本节的改法（三条，全部落在
  //   **宽路 tile + dense + s==1 + XDMA_EN=1** 这一档）：
  //   ① **趟序重排**：dense 的换趟分支（`wSt==4`）改成"**ci-block 外、co-block 内**"（本节对该分支
  //      **后写覆盖**；depthwise 的对角趟、`s==2` 与所有非 tile 通路**原样不动**）。
  //      数值不变的依据（可推，不是"应该没事"）：每个 co-block 的累加**仍按 ci 升序**（cib=0 → nCi-1），
  //      部分和按 `cob` 分段（`PartialSumBuf` 的 `cob*PIXMAX`，`NCOB=8` 段地址互不重叠）⇒ 同一个
  //      co-block 的整数累加**顺序逐位不变**；`ps_clr`（`wCi==0`）在 ci-outer 下正好是**每个 co-block
  //      的第 1 趟** ⇒ "每段只清零一次、其余趟读回累加"的语义一字没变（收料门 `wCi==nCi-1` 同理）。
  //   ② **tileBuf**（8 ch × 一列一拍 × `WIDTH` 列 × (`IMG_H_MAX`+2) 行 = 34×34 字 × 8 B = **9,248 B**）：
  //      每个 ci-block 的**第一个 co-block**（填充趟）把 gather 交付的每一列**同时**写进 tileBuf；
  //      其后同一 ci-block 的其它 co-block（重放趟）从 tileBuf 逐列重放。
  //      ★ 记的是 gather **最终交给 `mpu` 的那一列**（含 `z_pad` 列，见 `wxCol`）⇒ 重放与填充
  //        **逐字节同源**，不需要第二套 pad / band / 平面索引逻辑。
  //   ③ **AR 抑制**：重放趟把 gather 按在 `wxSt=0`（IDLE）⇒ 该趟**一笔 AR 都不发**
  //      （`ddrMaster.io.start` 的 gather 驱动只有 `wxSt==2`，`rd_ready` 的 tiled 支同此）⇒ 一个
  //      ci-block 的输入只从 DDR 读**一次**，而不是 `nCo` 次。
  //   ④ **观察口 `gather_bytes`**（`TILING=true` 才有的输出端口，与 `x1_beats`/`chain_rep_*` 同一手法）：
  //      本次 run 里 gather **首次交付**的输入字节数 = Σ(填充趟交付的列数 × 本 ci-block 的有效平面数
  //      `wxNPl`)。填充趟只发生在每个 ci-block 的首个 co-block 上 ⇒ 该计数**与 `nCo` 无关**。
  //      ★ 口径（明写，map §3.4 的三条放大里只含第 1 条）：它数的是**唯一列字节** —— **不含**
  //        32 B band 的重取放大（B3 的账）、**不含** tile halo 的去重（B2 的账）⇒ `Conv_15`
  //        （160²、32 ch、34² 窗口 × 25 tile）上 = `nominal × 34²·25/160²` = nominal × 1.1289。
  //      ★ 负对照（旧行为"每个 co-block 都重读"）= 网表一行突变把 `b1_play` 打平成 0（见闸门 [2]）
  //        ⇒ 本计数 ×`nCo`（`Conv_15`：×8），而**数值仍然逐字节对**（重读得到的是同一份输入）。
  // ===========================================================================
  if (TILING) {
    /** tileBuf 的字数 = `WIDTH`(列) × (`2·IMG_H_MAX`+2)(行) = 34×66 = **2,244 字 × 8 B = 17,952 B**。
      * ★ 为什么是 `2·IMG_H_MAX+2`（不是 `IMG_H_MAX+2`）：`s=1` 的满 tile 窗口高 = `HT+2`（34），而 `s=2`
      *   的窗口 = 34×66（B2a，`tNCol=2·16+2`）⇒ 取两者的大者。上界写死：本缓冲 **≥ tNRow_max·WIDTH**，
      *   `b1Addr = wRow·WIDTH+wCol` 在 `wRow=65,wCol=33` 时 = 2,243 < 2,244 ⇒ 不越界（map §3.4 R-d）。 */
    val b1Depth = WIDTH * (2 * IMG_H_MAX + 2)
    val b1Aw    = log2Up(b1Depth)
    /** 8 通道 × 一列（= `mpu.io.x` 的一拍）一字；上电清 0（与 `wOutMem`/`outMem` 同一套"未写不读"保险）。 */
    val b1Buf = Mem(Bits(C * 8 bits), b1Depth).init(Seq.fill(b1Depth)(B(0, C * 8 bits)))
    /** 本层能不能吃这条复用：tile 宽路 ∧ dense（B2a 起**不再限 `s==1`**：缓冲已容下 34×66 的 s=2 窗口）。 */
    val b1Use = Bool(); b1Use.setName("b1_use")
    b1Use := tilingW && !isDwW
    /** 本趟是**重放趟**（本 ci-block 已填充过）—— ci-outer 之后它 ⟺ 当前 co-block 下标 ≠ 0。
      * ★ `b1_fill` 写成 `b1_use && !b1_play`（而不是另写一条 `wCob==0`）：两者**同义**，
      *   但这样"负对照把 `b1_play` 打平成 0"一处突变就同时把**重放关掉**（回到旧行为）并把
      *   **填充扩到每一趟**（计数 ×`nCo`）⇒ 红点唯一且可归因（见 `tools/run_b1_tilebuf_ab.sh` [4]）。 */
    val b1Play = Bool(); b1Play.setName("b1_play")
    b1Play := b1Use && (wCob =/= U(0, 4 bits))
    /** 本趟是**填充趟**（本 ci-block 的第一个 co-block）。 */
    val b1Fill = Bool(); b1Fill.setName("b1_fill")
    b1Fill := b1Use && (!b1Play)
    /** 趟内列坐标 → tileBuf 字地址（行主序；**行跨步 = `WIDTH`** 常数乘 ⇒ 不用运行期 `tNCol`）。 */
    val b1Addr = (wRow.resize(b1Aw) * U(WIDTH, b1Aw bits) + wCol.resize(b1Aw)).resize(b1Aw)
    /** 末行之后（gather 的尾排空拍里 `wRow` 会越过 `tNRow`）把地址钳到 0 ⇒ **绝不越界读**。 */
    val b1AddrS = Mux(wRow < tNRow, b1Addr, U(0, b1Aw bits))
    /** **填充**：gather 在本拍把一列交给 `mpu`（= `wxSt==EMIT ∧ x_ready`）⇒ 同一列写进 tileBuf。
      * 数据源就是 `wxCol`（= 本拍 `mpu.io.x` 看到的**同一组字节**；pad 列 = `z_pad`）。 */
    val b1Acc = b1Fill && wxRun && (wxSt === U(3, 2 bits)) && (wRow < tNRow) && mpu.io.x_ready
    // ---- 重放：tileBuf 的同步读（1 拍延迟）+ "DECIDE 直跳 EMIT"（跳过 FETCH）----
    //   ★ 为什么**不**另立喂列 FSM（第一版这么写过，实测挂死）：gather 的 EMIT 分支
    //     （`when(wxRun){ switch(wxSt){ is(3){ when(mpu.io.x_ready){ 推进 wCol/wRow }}}}`）是
    //     `wRow/wCol` 推进的**唯一真源**，而它在 `x_ready` 上推进、**不看** `x_valid`。另立一套
    //     推进 ⇒ 同一个 `x_ready` 被两处消费（列号走得比数据快一倍 ⇒ 每行丢一半列、末行之后
    //     `wRow` 还会无限自增）；而且 `wxSt=0` 在 gather 的 FSM 里只是**过路态**（`is(0){wxSt:=1}`），
    //     压不住它。⇒ 本档只做两件事：**把 DECIDE 的后继改成 EMIT**（不 fetch、不写 `xwBuf`）、
    //     **把列数据换成 tileBuf 的读出**；位置推进/握手/趟收工全部**沿用既有那一条路**。
    //   ★ 时序：DECIDE 那一拍地址 = 当前 `(wRow,wCol)` ⇒ 下一拍（EMIT）读出的正是该列 ⇒ 与 gather
    //     自己的 DECIDE→EMIT 逐拍同形（每 2 拍一列，而切片 `x_ready` 的最快节拍是 1/3 ⇒ 不降吞吐）。
    //   ★ AR 抑制的落点：`ddrMaster.io.start` 的 gather 支 = `wxSt==2 ∧ …`；重放趟 `wxSt` **永不**为 2
    //     ⇒ 一笔 AR 都不发（`rd_ready` 的 tiled 支同此）。
    val b1Dat  = b1Buf.readSync(b1AddrS)
    /** 本拍读回的**列**（第 k 个字节 = 通道 k；与 `wxCol` 的位序同一套）。 */
    val b1Word = Vec((0 until C).map(k => b1Dat(k * 8 + 7 downto k * 8).asSInt))
    when((state === UnitExecPhase.WIDERUN) && (wSt === U(3, 3 bits)) && b1Play) {
      when(wxSt === U(1, 2 bits)) { wxSt := U(3, 2 bits) }
      for (k <- 0 until C) { mpu.io.x(k) := b1Word(k) }
    }
    /** **趟序重排**（后写覆盖 `wSt==4` 的 dense 分支）：ci-block 外、co-block 内。
      * ★ 第一版只写了 `wCob`/`wSt`、没写 `wCi` ⇒ **既有分支的 `wCi := wCi+1` 照样生效**
      *   （SpinalHDL 的"后写覆盖"只覆盖**被赋过的**寄存器）⇒ 实测趟序变成 (0,0)→(1,1)（两条分支的
      *   赋值拼在一起）⇒ 每个 ci-block 只跑一趟、第二趟还是重放。⇒ 这里把 `wCi` 显式写回自身。 */
    when((state === UnitExecPhase.WIDERUN) && (wSt === U(4, 3 bits)) && b1Use && !ldBusy) {
      wCi := wCi
      when(wCob === (nCo - U(1, 16 bits)).resize(4)) {
        wCob := U(0, 4 bits)
        when(wCi === (nCi - U(1, 16 bits)).resize(8)) { wSt := U(5, 3 bits) }
          .otherwise { wCi := (wCi + 1).resize(8); wSt := U(1, 3 bits) }
      } otherwise { wCob := (wCob + 1).resize(4); wSt := U(1, 3 bits) }
    }
    /** `gather_bytes`：填充趟每交付一列，记**本 ci-block 的有效平面数** `wxNPl` 字节。 */
    val b1Bytes = Reg(UInt(32 bits)) init 0
    when(runStart) { b1Bytes := U(0, 32 bits) }
    when(b1Acc) { b1Bytes := b1Bytes + wxNPl.resize(32) }
    val b1BytesOut = out UInt (32 bits); b1BytesOut.setName("gather_bytes")
    b1BytesOut := b1Bytes

    // =========================================================================
    // ★★ B2b（map §3.2）：**逐 ci 的 2 列 halo shadow**（dense + dw 共用；544 字 × 8 B = 4,352 B）
    //   治的是 tile halo 里**唯一有 AR 价值**的那半边：列。相邻 tile 的窗口步长 = `s·32`、窗宽 = `s·tw+2`
    //   ⇒ `s=1` 满 tile 时重叠 2 列 ⇒ 每个 tile 的前 2 列 = 左邻 tile 刚交付过的**同一批字节**（同一批全局
    //   列、同一个 `ty` ⇒ 同一个 `wRow`）。把它们按 `(ci, 列∈{后 2 列}, 窗口行)` 存下来，下个 tile 的同 ci
    //   填充趟直接从 shadow 交付（**不 fetch**、不发 AR），交付列数不变（B1 的"喂列契约"不动）。
    //   · 槽号 = `wCi[2:0]`：dense 的填充趟是 `(cib, cob=0)`（`wCi=cib`）、dw 是对角趟（`wCi==wCob`）
    //     ⇒ 一个下标两档通用；`C_in%8!=0` 的末块只占自己的槽（不会把零 lane 写进别人的槽）。
    //     `nCi > NCOB_MAX` 时槽会别名 ⇒ **整层关掉**（宁可多读，不静默错值）。
    //   · ★ 铁律（map §3.4 R-a）：**只跳"格"（DECIDE→EMIT），绝不跳 band**。`wxBndV/wxBndB` 的粘性账本
    //     （只在 orphan 清，`:2336`）**一个字节都不动** —— 它描述的是 `xwBuf` 里**实际装着的** band；
    //     跳格不改变 `xwBuf` 内容 ⇒ 下一格按地址比较仍然自洽。FETCH 路径一行不改。
    //   · ★ 只开 `s=1`：`s=2` 的列重叠是 4 列（且 `tWT2=16`）⇒「前 2 列 = 邻 tile 后 2 列」不成立；
    //     `Conv_0` 那一档交给 B2a（tileBuf 扩展），它的 235,200 B halo 留着。
    //   · ★ 不做行 halo（map §3.3）：要改 tile 遍历次序或 8× 缓冲，取数口径只值 4.8%。
    // =========================================================================
    /** shadow 槽宽 = `2 列 × (IMG_H_MAX+2) 行`；`NCOB_MAX` 个 ci 槽 ⇒ 8×68 = 544 字 = **4,352 B**。 */
    val b2ColW  = 2 * (IMG_H_MAX + 2)
    val b2Depth = NCOB_MAX * b2ColW
    val b2Aw    = log2Up(b2Depth)
    val b2Halo  = Mem(Bits(C * 8 bits), b2Depth).init(Seq.fill(b2Depth)(B(0, C * 8 bits)))
    /** 本趟能不能用/填 shadow：tile 宽路 ∧ `s==1` ∧ (dense 填充趟 ∨ depthwise 对角趟) ∧ `nCi ≤ 槽数`。 */
    val b2Fill = Bool(); b2Fill.setName("b2_fill")
    b2Fill := tilingW && (tS === U(1, 4 bits)) && (b1Fill || isDwW) && (nCi <= U(NCOB_MAX, 16 bits))
    /** 本格**命中** shadow：填充趟 ∧ 不是本 tile 行的首 tile ∧ 窗口前 2 列 ∧ 尾排空拍不收（R-c）。 */
    val b2Hit = Bool(); b2Hit.setName("b2_hit")
    b2Hit := b2Fill && (tTx =/= U(0, 16 bits)) && (wCol < U(2, cw bits)) && (wRow < tNRow)
    /** 写地址：`wCi·68 + (wCol-(tNCol-2))·34 + wRow`（填充趟的**最后 2 列**；差值恒 0/1）。 */
    val b2WC   = (wCol.resize(20) + U(2, 20 bits) - tNCol.resize(20)).resize(b2Aw)
    val b2WAdr = (wCi(2 downto 0).resize(b2Aw) * U(b2ColW, b2Aw bits) +
                  b2WC * U(IMG_H_MAX + 2, b2Aw bits) + wRow.resize(b2Aw)).resize(b2Aw)
    /** 读地址：`wCi·68 + wCol·34 + wRow`（填充趟的**最前 2 列**）；尾排空拍/非本档钳 0（同 `b1AddrS`）。 */
    val b2RAdr = (wCi(2 downto 0).resize(b2Aw) * U(b2ColW, b2Aw bits) +
                  wCol.resize(b2Aw) * U(IMG_H_MAX + 2, b2Aw bits) + wRow.resize(b2Aw)).resize(b2Aw)
    val b2RAdrS = Mux(b2Fill && (wRow < tNRow), b2RAdr, U(0, b2Aw bits))
    /** 填充：与 `b1Acc` **同一组交付列**（`wxCol` = 本拍 `mpu.io.x` 的同一组字节；pad 列 = `z_pad`）。
      * ★★ B3b-2：**写口只认填充趟**（dense：`wCob==0`；dw：每个对角趟各写自己的槽）。
      *   `b2Fill` 的 dense 支是 `b1Fill`；`b1_play` 被外力打平（B1 负对照）时 `b1Fill` 在**重放趟也真**
      *   ⇒ shadow 会被重放趟的列重写；实测该路径在接缝列写出错值（c64_40 突变档 MISMATCH=3515 全落
      *   在第二 tile 前 2 列、co-block≥1）。shadow 只是"左邻 tile 后 2 列"的缓存 ⇒ 填充趟写一次即定值。 */
    val b2Acc = b2Fill && wxRun && (wxSt === U(3, 2 bits)) && (wRow < tNRow) && mpu.io.x_ready
    /** ★★ B3b-2：写口两条纪律 ——
      *   ① 只认填充趟（dense `wCob==0`；dw 每对角趟各写自己的槽）；
      *   ② **最后一个 tile 不写**（`tTx == tNtx-1`）：它没有右邻 tile，而它的"后 2 列"是自己的右边界，
      *      会把左邻 tile 存下的 halo 覆盖掉。正常模式（重放趟不用 shadow）里这条被"读完才写"掩盖；
      *      `b1_play` 被打平（B1 负对照）后重放趟要读 shadow ⇒ 实测接缝列全错（c64_40 突变 MISMATCH=3515）。 */
    val b2Wr  = b2Acc && (wCol.resize(20) >= (tNCol.resize(20) - U(2, 20 bits))) &&
                (isDwW || (wCob === U(0, 4 bits))) &&
                (tTx =/= (tNtx - U(1, 16 bits)))
    b2Halo.write(b2WAdr, Cat((0 until C).map(k => wxCol(k).asBits)), b2Wr)
    /** 读：同步读（1 拍延迟）+ 与 B1 重放**同一招**（DECIDE 直跳 EMIT、列数据换成 shadow 读出）。
      * ★ 时序同 `:3050-3053`：DECIDE 那一拍地址 = 当前 `(wRow,wCol)` ⇒ 下一拍（EMIT）读出的正是该列。
      * ★ 与 `b1Play` 的重放覆盖**互斥**：`b2Fill` 的 dense 支是 `b1Fill`（`= b1Use ∧ ¬b1Play`），
      *   dw 支 `isDwW` 时 `b1Use` 恒 0 ⇒ 两者永不重叠；本块写在 B1 块**之后** ⇒ 覆盖顺序也无歧义。 */
    val b2Dat  = b2Halo.readSync(b2RAdrS)
    val b2Word = Vec((0 until C).map(k => b2Dat(k * 8 + 7 downto k * 8).asSInt))
    when((state === UnitExecPhase.WIDERUN) && (wSt === U(3, 3 bits)) && b2Fill && b2Hit) {
      when(wxSt === U(1, 2 bits)) { wxSt := U(3, 2 bits) }
      for (k <- 0 until C) { mpu.io.x(k) := b2Word(k) }
    }
    /** tileBuf 的写数据 = 本拍**真正交给 `mpu` 的列**：命中 shadow 的列写 shadow 读出值。
      * ★ 2026-10-20 实测缺陷：原先写 `wxCol`（gather 的原始列）而 `mpu` 拿到的是 shadow 值
      *   ⇒ 填充趟的 tileBuf 在 halo 列上是 gather 残留 ⇒ **重放趟**（co-block≥1）读回后
      *   接缝输出列全错（c16_40x40：MISMATCH=610 全落在 ox=32/33、通道 8–15）。
      *   非命中列 `b2Hit=0` ⇒ 逐字仍是 `wxCol`（B1 行为不变）。 */
    b1Buf.write(b1AddrS, Cat((0 until C).map(k => Mux(b2Hit, b2Word(k), wxCol(k)).asBits)), b1Acc)
    /** **取数口径**计数器（B2 起，与 `gather_bytes` 的交付口径并存）：每个 32 B band **FETCH 完成** +32。
      * ★ 只数真数据拍：`wxOrphan` 那一笔是排空残留（不装 `xwBuf`）⇒ 不数；`wxSkipNow` 的跳过拍没有
      *   `done` ⇒ 天然不数。b2_hit 打平时本计数回到 B1 之后的口径（见 `run_b2_halo_ab.sh` 的负对照）。
      * ★ 只数**窗口行**（`wRow < tNRow`）：`wRow = tNRow` 是 gather 在收工那一拍对"尾排"的预取
      *   （数据不交付、也不进 `wxBuf` 的有效窗口），实测每个 ci-block 恰好 1 个 band。它既非交付列、
      *   也不是 B2 的对象，混进来会让判据出现 32·nCi 的系统偏差 ⇒ 本口径**明确排除**（尾排预取的
      *   带宽代价记在 e2e 的 DDR 账上，不在本闸门）。 */
    val b2FB = Reg(UInt(32 bits)) init 0
    when(runStart) { b2FB := U(0, 32 bits) }
    if (TILING) {
      // ★★ B3b：整批 done 一次结账 ⇒ 加 32×本批项数（排空残留不数；仍只数窗口行）
      when(wxRun && (wxSt === U(2, 2 bits)) && wxSgRd && ddrMaster.io.done && !wxOrphan && (wRow < tNRow)) {
        b2FB := b2FB + ((wxSgEnq.resize(32) << 5).resize(32))
      }
    } else {
      when(wxRun && (wxSt === U(2, 2 bits)) && wxK && ddrMaster.io.done && !wxOrphan && (wRow < tNRow)) {
        b2FB := b2FB + U(32, 32 bits)
      }
    }
    val b2FBOut = out UInt (32 bits); b2FBOut.setName("gather_fetch_bytes")
    b2FBOut := b2FB
  }
}


// =============================================================================
// ★★ T-S3d（2026-10-15）：`权重 blob（+WBASE）× tiled 宽路（+TILED_W/XDMA_EN）` 的挂住 —— 修法与证据
// =============================================================================
// 症状（spec §3.5 的受控子实验，本任务先复现）：`rtl_test/UnitExecWideTb.v` + `gen/UnitExec_tiled.v`、
//   形状 `64→64 40×40`、`+TILED_W +WBASE` ⇒ **4M 拍不收工、无 `done` 无 `err`**，内存模型
//   `MEM rd=128 bursts=1`（只发了一笔 128 B 权重突发）。`+WBASE` 关掉（权重走信箱区域 1）⇒ `RESULT: PASS`。
//
// 三臂二分（同一 netlist `gen/UnitExec_tiled.v`、同一装置、同一 `mem.hex`，只差两个开关）：
//   ① `+WBASE`、无 `+TILED_W`：装载器**把整段 36864 B 全部读完**（`MEM rd=36864 bursts=288`、
//      `WGT_BYTES=36864`）⇒ **blob 装载本身没坏**；其后 `err=1` 是**非 tiled** 模式下的既有几何拦阻
//      （该网表 `WIDTH=34` 而本形状整层行宽 40 ⇒ `inWOk` 假、`go` 那拍响亮 err）——与本缺陷无关。
//   ② `+TILED_W`、无 `+WBASE`：`RESULT: PASS`（既有 `run_tiling2d_wide_ab.sh` 覆盖的那一档）。
//   ③ 两者都有：挂住（= 症状）。⇒ 是**组合**不是某一侧。
//
// 根因（**两处**，都在 RTL；串行叠加，所以受控实验必须**两处一起修**才看得到收工）：
//   ① `rd_ready` 的 `tilingW` 支漏了装载器：`tilingW` 在 `go` 那拍就闩存，而权重装载相位
//      （`WGTLD/WGTRUN`）在 `WIDERUN` **之前**跑（`dmaEn && tilingWideC` 时 `go` 直接进 `WGTLD`）
//      ⇒ 装载期间 `tilingW` 已是 1，而旧支只认 gather（`wxSt==2 && wxK`，装载相位恒 0）
//      ⇒ `rd_ready` **恒 0** ⇒ `DdrMaster` 推完第一块 128 B 就永久停在 `RDSTR` 等握手（无 done/err）。
//      ★ 机理上"只在组合里发作"：②档里装载相位**根本不出现**（`dmaEn=0` ⇒ `go` 直接进 `WIDERUN`），
//      而 `wgtdma` 系列闸门用的又是 `TILING=false` 网表（`tilingW` 恒 0 ⇒ 旧支根本进不去）。
//   ② `WGTRUN` 收工那一拍的 `wlWideR && !wideGeomOk`：`wideGeomOk` 含 `inWOk`（**整层**行宽 ≤ `W_MAX`），
//      而 tile 的意义正是绕过它 ⇒ 装载装对了也会被 `inWOk` **响亮 err**（实测 `state 9 -> 0`、
//      `wlCnt=36864` 而 `wr=0`）。修 = tiled 宽路（`tilingW`）豁免该项。
//      ★ 为什么①修好后才发现：①把两块之后的握手掐死，②的 err 根本走不到。
//
// 受控实验（判据，**不是猜**）：把①②各自**一行网表补丁**打进 `gen/UnitExec_tiled.v` 的临时副本
//   （①`(tilingW ? ((wlTake || ((wxSt == 2'b10) && wxK)) && rd_valid) : …)`；②`when_UnitExec_l2079`
//   追加 `&& (! tilingW)`）⇒ `64→64 40×40` 与 `64→16 8×32` **两档都收工**（`done=1 err=0 busy=0`），
//   且 `DST` 区与**冻结参考**（`tools/tiling_ref.py` 的 `conv_tiled` + `tools/multipass_ref.py` 的
//   `weight_tiles`/`bias_of`，与 `run_tiling2d_wide_ab.sh` 同一黄金）**逐字节相等**（`MISMATCH=0`）。
//   ★ 权重 blob 的**源**就是冻结参考同一份 `wq`（密集 `[co][ci][tap]`）—— 装载器的重排映射
//   （`run_wgtdma_wide_ab.sh` 的 `dest(co,ci,tap)` 口径）与 `weight_tiles()` 的趟序**同源**，
//   闸门 `run_wgtblob_tiled_ab.sh` 里另做一次逐字节互证。
//
// 回归面：`TILING=false` 的三份网表**逐字节不变**（本文件的两处改动全部包在 `if (TILING)` 里 /
//   `TILING=false` 分支是原文，且**行数中性** —— SpinalHDL 会把源码行号编进 `_zz_when_*` 标识符，
//   所以注释也必须不增删行；本节的说明因此挂在**文件尾**）。既有闸门见 `run_wgtblob_tiled_ab.sh` 的尾部回归清单。

/* =====================================================================================
  * ★★ §3.7（2026-10-16）：**部分和行宽 64 → 32 bit**（本文件只做"档位钉死"这一件事）
  * =====================================================================================
  *
  * 本单元例化的 `Conv3x3Slice`×`L_MAX`（窄通路）与 `MultiPassUnit`（宽通路，其内又是
  * `Conv3x3Slice` + `PartialSumBuf`）都带 `PSW`（部分和/`ps_in`/`ps_out` 位宽）。这里的钉法是：
  *
  *   `PSW = if (TILING) 32 else 64`
  *
  * 两条理由（缺一不可）：
  *   · **`TILING=true`（板级：`LayerSched` → `NpuTop`）⇒ 32** —— 这是 spec §3.7 的交付：把
  *     `PartialSumBuf` 的存储从 512 bit/字压到 256 bit/字（缺省深度 8704 ⇒ 557,056 B → 278,528 B），
  *     给宽链的"忠实镜像"腾 DRM（B3：需 221 KB vs 余量 ~178 KB）。可证界见
  *     `PartialSumBuf.scala`/`MultiPassUnit.scala` 文件尾：`|acc| ≤ 9,363,456 < 2^24`。
  *   · **`TILING=false`（三份冻结网表 `gen/UnitExec.v/_w32/_w640`）⇒ 64** —— 这三份是**历史冻结
  *     锚**（`run_wgtdma_*` / `run_stride_exec_ab` / `run_unitexec_wide` / `run_dw_wide` / `run_chain_ab`
  *     等闸门按 md5 与逐字节行为对它们设判据）。把 `PSW=64` 显式钉住，它们的展开与改动前**逐字节**相同。
  *   · ★ 同一 elaboration 里**不允许混宽**：SpinalHDL 每个参数组合发一个 `module Conv3x3Slice`，
  *     混宽会撞重名 ⇒ 窄通路的 `slices(i)` 与 `mpu` 必须同 `PSW`（上面两处因此都用同一个式子）。
  *
  * 本单元**不动**的：`MacArray`/`arr` 的 int32 累加、requant 三级流水、`outMem`/`wOutMem` 的字宽、
  * 描述符格式、`bias` 的 int32。`run_psbound_ab.sh` 是本条的判据（32 bit 满幅度逐字节 + 24 bit 必红）。
  * ===================================================================================== */
