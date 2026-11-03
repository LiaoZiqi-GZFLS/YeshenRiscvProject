import spinal.core._

/** 3x3 int8 卷积切片 —— LineBuffer + WeightStore + GroupedMacArray 的合成与调度（本任务交付物）。
  *
  * 三档配置**同一份源码**、只差展开期常量 GROUP（=1 dense / =4 group=4 / =8 depthwise，见 SliceGen）：
  *   数据通路完全一样，只有喂进阵列的权重瓦片掩码不同（分组信息 100% 落在权重掩码上，
  *   见 GroupedMacArray / GroupMask 的长注释）。所以三份网表**端口同名同宽**，装置只能靠
  *   网表的 `grp` 自报（见 io 里的 grp）来断言"喂进来的 +GROUP 与本网表档位一致"。
  *
  * 三个现成的部件（**一个字都没改**，只把它们接起来）：
  *   rtl/LineBuffer.scala      —— 3x3 窗口行缓冲（按列流进、存 2 行历史、"晚一行"出窗、零填充）
  *   rtl/WeightStore.scala     —— 整层权重常驻，k = ky*3+kx 选 64 元瓦片
  *   rtl/GroupedMacArray.scala —— 逐 entry 掩码后进 8x8 阵列（dense 时掩码恒真）
  * 本文件只做**调度**：把窗口凑成 9 个 (ky,kx) 拍、按拍喂阵列、收 p 做 requant + clamp。
  * 没有 DDR / AXI / 指令译码 / 主机寄存器 —— 这一层是纯数据通路 + 一个小状态机。
  *
  * ==================== ★★ C4a.6：depthwise（`0x03`）口径（本片新增；要改走 spec 修订） ====================
  * 冻结口径（逐字，写进文件头）：
  * ```
  * depthwise = GROUP = C_in = C_out；C≤8 一趟；C>8 拆趟（每趟 8 通道）
  * ```
  * 逐句落实：
  *   · **`GROUP == C_IN == C_OUT`**：本切片的 GROUP 展开期常量取这个值时就是**深度卷积档** ——
  *     由 `GroupMask` 的冻结映射 `groupOfOut(co)=(co*GROUP)/C_OUT`、`groupOfIn(ci)=(ci*GROUP)/C_IN`
  *     自动给出：每组恰一个 `co` 与一个 `ci`，`participates(co,ci) = (co == ci)` ⇒ 每个输出通道
  *     只吃**自己那一个**输入通道。**掩码一个字都不改**（`GroupedMacArray` 的常数折叠）。
  *     本切片固定 8x8 ⇒ 这一档就是 **`GROUP == C_IN == C_OUT == 8`**（= 既有掩码支持的 depthwise 档，
  *     由 `SliceGen` 出 `Conv3x3Slice_g8.v`，B3/B4 已数值对账）。
  *   · **`C ≤ 8` 一趟**：真表的 depthwise 层 `C ∈ {4,10,16,32,64}`。`C ≤ 8`（如 `C=4`）**一趟**跑完；
  *     不足 8 的通道由**驱动方补到 8**（补位通道的权重置 0 ⇒ 贡献恰 0，见 C4a.4 冻结规则），
  *     多出来的 `co` 行输出是**弃料**（驱动方只收前 `C` 个通道）。
  *   · **`C > 8` 拆趟（每趟 8 通道）**：本切片只覆盖 8 通道块 ⇒ 更宽的 depthwise 走 **C4a.5 的多趟通路**
  *     （`rtl/MultiPassUnit.scala` + `rtl/PartialSumBuf.scala`，见那两个文件头）。depthwise 的**趟调度
  *     是"对角趟"**：第 `b` 个 co-block 只需要第 `b` 个 ci-block（`co` 与 `ci` 同块才同组）
  *     ⇒ 趟数 = `ceil(C/8)`（不是 `ceil(C_in/8)×ceil(C_out/8)`）。跨块的趟其权重瓦片全 0、
  *     贡献恰 0 —— 于是"对角趟"与 C4a.5 的**一般趟调度**给出**同一套算术、同一份输出**
  *     （C4a.6 的判据里对同一输入逐字节断言这一条）。
  *   · **与 C4a.5 共用同一套算术**（**不另起一套**）：depthwise 的多趟就是 `MultiPassUnit` 本体
  *     （`DwGen` 出的网表与 `MultiPassGen` 的**逐字节相同** ⇒ 结构性证明"没有第二条算术通路"），
  *     requant / 部分和 / pad 码点 / 每层乘子全部沿用 C4a.5a/b 的口子，本切片不再加任何新逻辑。
  *   · **本切片在 C4a.6 的实际改动**：只有这一节口径说明 + 下面的展开期常量 `IS_DEPTHWISE`
  *     （供生成器/装置**自证档位**用；**不产生任何硬件**）。depthwise 的掩码/位宽/时序在 C4a.4、
  *     C4a.5a 的改造里**已经就位**，本任务不重复实现。
  *
  * ============================== ★★ C4a.5a：多趟累加 + §4.4 requant（本片新增） ==============================
  * ★ 冻结数据流（C4a.5 Step 1，逐字；要改走 spec 修订）：
  * ```
  * 一个"宽层" = 表里的一组连续 plain 单元（由转换器生成，本任务由 TB 手工给）
  *   第 1 趟：累加器清零（或直接写）；第 k>1 趟：读回部分和 → 加到本轮 acc → 写回
  *   片上部分和缓冲：C_out 行 × 8 B（= 64 B/co-block），RAM 结构（DRM），不得落 FF
  *   注意与 C3 的"输出存储 readAsync 是 LUTRAM"是两回事：这里必须是 block RAM，判据由 dev_map 给
  *   （dev_map 的 DRM 判据属 C4a.5b；本片先把缓冲建出来并保证结构正确）
  * ```
  * ★★ §3.7：上面框里的"8 B"已收窄为 `PSW`（缺省 **4 B/32 bit**，可证界 `9,363,456 < 2^24`；见文件尾）。本片（C4a.5a）**只做数据通路**：`Conv3x3Slice` 加**部分和载入/写回**口 + 加 §4.4 的乘子 requant；
  * 片上部分和缓冲在 `rtl/PartialSumBuf.scala`（`C_out` 行 × `PSW/8` B、**同步读**、**上电初值 0** ⇒ DRM）；
  * 多趟的**编排**（谁在第几趟、读到哪）在 `rtl/MultiPassUnit.scala`（单元级）。把这条流接进
  * `UnitExec`/`NpuTop`、以及 DRM 的 `dev_map` 判据是 **C4a.5b**（本片**不**做）。
  *
  * ---- (a) 部分和载入/写回（本文件新增的三条数据通路口；★ §3.7 宽度 = `PSW`，缺省 32 bit）----
  *   · `ps_in(co)`   —— **本趟开始前**从部分和缓冲读回的累加值（`PSW` 位、有符号）。第 1 趟读到的是缓冲的
  *                      **上电初值 0**（这就是冻结口径里的"累加器清零"：不占任何节拍、不落 FF）。
  *   · `ps_out(co)`  —— `= 本轮 int32 acc + ps_in + bias`（`PSW` 位），由编排器**写回**缓冲。
  *                      ⇒ "第 k>1 趟：读回部分和 → 加到本轮 acc → 写回"逐字落实。
  *   · `bias(co)`    —— **累加器单位**的偏置（int32；`round(bias/(s_x·s_w))`，C4a.4 把它折进**第 1 趟**）。
  *                      由编排器只在该层第 1 趟给非 0；其余趟给 0。★ 这一口是**为了对齐 C4a.4 的
  *                      整层黄金**（`conv_tiled` 把 bias 折进 `i==0` 那一趟）而加的，本任务明写的
  *                      requant 公式里没有它，但"acc"本来就含 bias（见 `quant_ref` 的累加段）。
  * ---- (b) §4.4 requant：把纯 `>>SHIFT(=6)` 换成 `((acc·M) >> REQUANT_Q) >> SHIFT`，再 `+ z_y`、clamp ----
  *   · `requant_m`（**每层** Q24 乘子，32 位无符号）与 `zero_y`（输出张量 zero-point，int8）都是
  *     **入参口**。★ `M` 在 C4a.5b 由**权重信箱按 LAYER_ID 装载**（描述符 8 字零改动）；
  *     本片先把它开成端口（TB 直接喂），**不**在本文件里做任何"按层选存"。
  *   · `REQUANT_Q = 24`（与 `quant_ref.REQUANT_Q` 同值，冻结）；`SHIFT = 6` 仍是**展开期常量**，
  *     并由 `require(SHIFT == 6, ...)`（= `quant_ptq.require_shift` 的 RTL 同义项）在**展开期**钉死。
  *   · ★ 与 `quant_ref.requant_int` 的关系：那处的 `>>SHIFT` 在乘法**之后**（`((v·M)>>24)>>6`），
  *     **不是** `>> (SHIFT + z_out)`。本文件逐字照此（先乘、再两个移位、最后加 z_y）。
  *   · ★ **additive / 向后兼容**：`M = 2^24`（单位乘子）时 `((acc·2^24)>>24)>>6 == acc>>6`，且
  *     `ps_in = bias = z_y = 0` ⇒ 本文件**与 C3 逐字节同形**。C3 的既有闸门（`run_unitexec_ab.sh`
  *     / `run_chain_ab.sh` / `run_fuse_ab.sh` / `run_numeric_ab.sh` …）就是靠"编排器喂单位乘子 +
  *     全 0"来保住的（`UnitExec.scala` / `rtl_test/Conv3x3Tb.v` 各一行；见那两处的 ★ 注释）。
  *
  * ============================== ★★ C4b-D1：步长 `stride`（本片新增；要改走 spec 修订） ==============================
  * 冻结口径（逐字）：`stride ∈ [1,15]`（描述符 `w3[11:8]`；字段 `0` 视作 `1`）。输出按步长**抽稀**：
  *   `Conv(stride=s, pads=1)` 的输出 `(y,x)` 的窗口中心 = 输入 `(s·y, s·x)`；
  *   本模块"收完第 `c` 列"手上正好是**中心为第 `c-1` 列**的窗口（列延迟线，"晚一列"）
  *   ⇒ **目标列 `c ≡ 1 (mod s)`、目标行 `r ≡ 1 (mod s)`**（`r` = 正在流入的输入行号）。
  * 逐句落实（落实点全在本文件的下面的两个模 `s` 计数器上）：
  *   · **输入流一个字节都不跳**：行缓冲照旧收满每行 `WIDTH` 列（3 个 tap 恒为**相邻**三列），
  *     相邻输出像素的窗口在输入空间里**仍重叠**（窗口 = 中心 ±1）。抽稀的只是**像素相位**。
  *   · **非目标列/行**：只推进（`S_CONSUME` 连跑 `s` 拍），不进像素相位、不出像素
  *     ⇒ 输出像素数 = `floor((W-1)/s)+1` × `floor((H-1)/s)+1` —— 与 ONNX 的
  *     `Ho = floor((H+2·pad-K)/s)+1`（`pad=1,K=3`）**同式**。
  *   · **右边零填充**：幻影列（列 `W`）是目标列 ⟺ `(W-1) mod s == 0`；否则最后一列的像素算完
  *     直接换行（不补幻影拍）。`s=1` ⇒ 恒补（= 旧行为）。
  *   · **相位实现**：两个 4 位模 `s` 计数器（`dm` 列 / `rm` 行），**没有除法、没有运行时取模**：
  *     每行第 0 列把 `dm` 清 0；目标列 ⟺ `dm === 0`。行相位 `rm(1) = 0`、每换行 `+1 mod s`；
  *     输出行 ⟺ `rm === 0`。`s = 1` 时两者恒 0 ⇒ 三条收列分支退化成**旧的两条**（逐拍同形）。
  *   · **加法/乘法/权重/requant 一字未改**：本模块**没有第二条算术通路** —— 抽稀只改"什么时候进
  *     像素相位"，9 个 tap 的选择、MAC、requant、部分和写回全部沿用。
  *   · 与 `MultiPassUnit`/`UnitExec` 的分工：本口由驱动方按**描述符 `STRIDE`** 喂（`UnitExec`
  *     直接接 `dw.stride`；`MultiPassUnit` 直通）；本模块**不解释**输入图高/宽 ——
  *     "喂几行几列"（含下边的 pad 行）是**流的约定**（与"下边零填充"同一条口径，见下）。
  *
  * ============================== 坐标与时间约定（本文件全部推导航于此） ==============================
  * LineBuffer 的约定（见其文件头，逐字沿用，**不另起一套**）：
  *   输入行 r 正在流入的那一拍，win(ci)(rr) 是**输出行 y = r-1** 的窗口：
  *     rr=0 → 第 y-1 = r-2 行、rr=1 → 第 y = r-1 行、rr=2 → 第 y+1 = r 行，三行**同一列 col**。
  *   输入行 r=0 那一拍是**预滚（pre-roll）**：对应输出行 y=-1，不是有效输出行。
  *
  * 一列窗口凑不出 3x3：输出像素 (y,x) 要 (y+ky-1, x+kx-1)，kx 要跨**三列**。
  * 所以本切片在 LineBuffer 之后再挂一条**列延迟线** colWin(cx)(ci)(rr)（cx=0 最老）：
  *   在输入行 r、列 c 的 en 拍末尾（时钟沿后）：
  *     colWin(0) = 第 c-2 列的窗口、colWin(1) = 第 c-1 列、colWin(2) = 第 c 列
  *   于是**本拍结束时手上正好有输出像素 (y=r-1, x=c-1) 的全部 9 个 tap**：
  *     tap(ky,kx) = colWin(kx)(ci)(ky)  —— kx 选列（0=最老=c-2=x-1、2=最新=c=x+1），ky 选行。
  *   行号**不需要再补**：ky 用的就是 LineBuffer 的 rr（它已经含"晚一行"）。
  *
  * 为什么是"列延迟"而不是"提前读"：行主序流里第 c+1 列要等它流进来才存在（跟行的道理一样），
  * 所以输出像素只能**晚一列**产出（x = c-1 = 队列正中那一列），本模块不做任何"预读"。
  *
  * ============================== 四个方向的零填充（出处各不相同，别混为一谈） ==============================
  *   上边（行 -1）：LineBuffer 的 hist 复位为 0 ⇒ 自动读到 0。**本模块不用管**。
  *   下边（行 H）  ：LineBuffer 接口里**没有 H**，它造不出来 ⇒ 由**驱动方多喂一行全 0 的 pad 行**
  *                  （rtl_test/Conv3x3Tb.v 就是这么喂的）。**这是流的约定，不是模块行为**。
  *   左边（列 -1）：colWin 的**最老两级**在每行第 0 列（firstCol）被显式清 0
  *                  ⇒ 输出 x=0 的 kx=0 tap（列 -1）读到 0。
  *   右边（列 W）  ：列 W-1 是最后一条流进来的列，列 W **永远不会被喂** ⇒ 本模块在行末自己插一个
  *                  **幻影拍（phantom）**：把 colWin 再左移一格、最新一格填 0（等价于"零列 W 流入"），
  *                  然后照常算一个像素 —— 那正是输出像素 x=W-1。
  *                  ★ 为什么不能靠驱动方"多喂一列 0"：多喂一列会让 LineBuffer 的列计数器提前回绕
  *                    （它按 WIDTH 数行），第二行起整幅图的行列就都错位。右边填充必须由本模块造。
  *
  * ============================== 时序 ==============================
  * 每个输出像素 = 1 拍收列（consume）+ 10 拍像素相位（ph=1..9 喂 9 个 tap，ph=10 相位收尾）。
  *   - ph=1..9：arr.en=1，ws.k = 0..8（即 ky*3+kx），arr.x(ci) = colWin(kx)(ci)(ky)；
  *   - ph=10  ：相位结束，进 S_CONSUME（或行末先插幻影拍）—— 阵列在这一拍**无事**（en=0/clr=0）。
  * ★ C3.18 R3-2 后 clr 与出数的位置（**本文件唯一的时序改动**，见"★ R3-2"一节）：
  *   累加器**读出 + requant + y_valid + clr** 都在**紧随 ph=10 之后的那个 S_CONSUME 拍**上，
  *   由 `pixelPending` 门控（只出一次）。为什么：`MacArray` 现在两级流水，第 9 个 tap 的贡献要到
  *   ph=10 拍末尾才落进 acc ⇒ ph=10 拍 acc 还不完整，下一拍（S_CONSUME）才是完整和。
  *   于是"clr 与 en 分拍"这条 MacArray 契约**仍然成立**（clr 在收列拍，那时 en=0；下一个像素的
  *   第一个 tap 在再下一拍），而像素节拍**仍是 11 拍** ⇒ 输入像素速率仍是 1/11 拍，零吞吐代价。
  *   （另一条候选是"把节拍拉到 12 拍"，会掉 8.3% 卷积吞吐 —— 本实现**不采用**。）
  * 输入流被本模块**反压**：一列只在 S_CONSUME 拍被吃（x_ready=1），其余 10 拍阵列忙，
  * 所以输入像素速率 = 1 / 11 拍。
  *
  * 输出顺序：本模块**一拍出一个像素的全部 C_OUT 个通道**（8 个累加器同时算完，天然并出）。
  * 一维 [co][y][x] 的展平由驱动方做（单趟数据通路不缓存整幅图，做不到 co-major 输出）。
  *
  * ====== ★★ C4a-R2（2026-10-11）：§4.4 requant 三级流水（板级 100 MHz 时序收敛） ======
  * 板级 PnR（`sim/reglogs/pds_pnr_c4a_c4a_p10.000` seed_0 的 `..._rtr`）实测最坏 `cpu_clk` 路径
  * 就是本模块的 requant：`.../mzRam_mux_b → N349_m1..m4（4 级 APM cascade，逻辑 6.34 ns）→
  * N569 加法器 → N574_mux64/mux65 钳位 mux → UnitExec/outMemT DI`（到达 24.396 ns / slack −11.393，
  * 布线占 59%）。修法 = 把"一次 64×32 乘法 + 后处理"的三段各自寄存（**见类体里"requant 三级流水"一节
  * 的完整恒等式证明**）：`AH·M` / `AL·M` / `(AL·M>>30)+(AH·M<<2)+z_y+clamp`。
  *   · **数值逐位等价**（精确整数恒等式；`z_y`、钳位、`resize(8)` 一字未改）；
  *   · **吞吐不变**（像素节拍仍 11 拍），只是 `y/y_valid` 相对"出数拍"**整体晚 3 拍**；
  *   · `ps_out` 的写回契约**改挂新的 `ps_valid` 口**（= 原"出数脉冲"，不随流水延迟）——
  *     `MultiPassUnit` 据此写回部分和（旧代码用的是 `y_valid`，那时两者是同一个信号）。
  *   · 对既有闸门：全部是标志驱动的流式握手（`y_valid` 认像素）+ 逐字节内存对账 ⇒ **不改数值**。
  *
  * 预滚行 r=0 **整行不出像素**（对应输出行 -1）：本模块按"收满 WIDTH 列 = 一行"自己数行，
  * 不需要 H，也不需要驱动方告诉它哪一行是预滚。
  *
  * ============================== `prime`（additive 口，C3.10 前置） ==============================
  * 本切片**自己按 WIDTH 数行**（`row` 从 0 起、只把 `row==0` 当预滚行），`LineBuffer` 的列指针与
  * 两行历史**只在复位时清 0** —— 三者都没有"第几张图"的运行期复位口。于是同一个实例连跑第二张图时，
  * 相位停在上一次的末尾，窗口整个错位（表现为**多出一整行像素**）。`prime` 就是那条复位口：
  * 脉冲一拍，把本切片的 per-image 相位（`st/col/row/ph/phantomPix/colLast/colWin`）与下游 `LineBuffer`
  * 的相位（`col/hist0/hist1`）全部清回**上电态** ⇒ 下一次收列等价于"上电后的第一列"。
  *   · 由 `UnitExec` 在每次 `go` 的起点脉冲（`conv.io.prime := runStart`）。
  *   · **additive**：`prime==0` 时与"没有这个口"逐拍同形（它只是所有调度分支之上的一个更高优先分支）。
  */
class Conv3x3Slice(val C_IN: Int = 8, val C_OUT: Int = 8, val GROUP: Int = 1,
                   val WIDTH: Int = 16, val SHIFT: Int = 6, val PSW: Int = 64, val X1SKIP: Boolean = false, val DWSKIP: Boolean = false, val DCI: Boolean = false) extends Component {
  require(C_IN == 8 && C_OUT == 8, "本切片固定一块 8x8 阵列（更宽的层靠多趟复用，不在这里）")
  require(WIDTH >= 3, "3x3 窗口至少要 3 列"); require(PSW >= 8 && PSW <= 64 && PSW % 8 == 0, "部分和行宽 PSW ∈ [8,64] 且为 8 的倍数（★ §3.7）")
  require(C_IN % GROUP == 0 && C_OUT % GROUP == 0, "通道数必须能被 group 整除")
  require(SHIFT >= 0 && SHIFT <= 31, "右移位数必须在 [0,31]")
  // ★ C4a.5a §4.4：requant 右移在本代**冻结为 6**（`quant_ptq.require_shift` 的 RTL 同义项）。
  //   它与每层乘子的 Q 格式 `2^(SHIFT+REQUANT_Q)` 是同一个自由度的两个副本（见 quant_ref 文件头）；
  //   展开期就钉死，免得"换了个 SHIFT 却没换网表"变成静默错值。
  require(SHIFT == 6, "§4.4 冻结：本代 requant 右移必须为 SHIFT=6（require_shift 同义）")

  /** ★ C4a.5a：每层 Q24 乘子的 Q 格式小数位（与 `quant_ref.REQUANT_Q` 同值，冻结）。 */
  val REQUANT_Q: Int = 24

  /** 每组拥有的输入通道数（= 每个 co 的组内权重个数），与 GroupMask 同一套规则。 */
  val PER_GROUP: Int = C_IN / GROUP
  /** ★ C4a.6：**depthwise 口径**的展开期判定（`GROUP == C_IN == C_OUT`，见文件头 C4a.6 一节）。
    *   纯 Scala 常量、不产生任何硬件；供生成器与装置**自证档位**（`GROUP=8` 的网表就是这个档；
    *   更宽的 `C` 由 `MultiPassUnit` 的多趟覆盖）。 */
  val IS_DEPTHWISE: Boolean = (GROUP == C_IN && GROUP == C_OUT)
  /** 整层权重的条目数（压缩张量 [co][ci_local][ky][kx] 的大小）= 装载地址空间。 */
  val NENTRY: Int = C_OUT * PER_GROUP * 9
  // ★ C4a.6：depthwise 口径（`GROUP == C_IN == C_OUT`）的展开期自检 —— 每组恰一个输入通道
  //   （`participates(co,ci) = (co == ci)`）。纯 Scala 断言（不落硬件），把文件头 C4a.6 一节的
  //   口径钉成**可执行的契约**（接错参数当场响亮报错）。★ 必须放在 `IS_DEPTHWISE`/`PER_GROUP`
  //   的**声明之后**：Scala 的构造体按源码顺序求值，写在声明之前会读到未初始化值（= 静默失效）。
  require(!IS_DEPTHWISE || PER_GROUP == 1, "depthwise 口径（GROUP==C_IN==C_OUT）：每组必须恰一个输入通道")

  val io = new Bundle {
    // ---- 权重装载口：直通 WeightStore（布局 = GroupMask.weightAddr）----
    val we    = in  Bool()
    val waddr = in  UInt (log2Up(NENTRY) bits)
    val wdin  = in  SInt (8 bits)
    // ---- 输入像素流：逐列、行主序（列内一次给全 C_IN 个通道）----
    val x       = in  Vec (SInt(8 bits), C_IN)   // 本列的 C_IN 个通道像素
    val x_valid = in  Bool()                     // 驱动方：当前 x 是一列新像素
    val x_ready = out Bool()                     // 本切片：本拍吃掉这一列
    // ---- ★ additive 相位复位口（缺省 0）：一拍把本切片的 per-image 相位 + 下游 LineBuffer 清回上电态。
    //      每次 `go` 的起点脉冲一次 ⇒ 同一个实例可连续跑多张图（C3.10 前置）。prime==0 时逐拍同形。
    val prime   = in  Bool()
    /** ★ C4a.5b §4.5：零填充码点（该层 `z_pad` = 输入真实 0 的码点 `z_x`）。上/左/右三个方向的
      *   填充都读它（取代硬编码 0）；`prime` 拍把列延迟线清成它。喂 0 ⇒ 与 C3 逐字节同形。 */
    val pad_val = in  SInt(8 bits)
    /** ★★ C4b-D1：**卷积步长**（描述符 `w3[11:8]`；字段 `0` 视作 `1` —— 旧表/旧装置把该字段留 0
      *   ⇒ 与 C4a 逐字节同形）。输出按步长**抽稀**：每 `stride` 个输入行/列出一个输出像素
      *   （见文件头 ★★ C4b-D1 一节）。`stride == 1` 时本口对本模块**逐拍同形**（无行为差异）。 */
    val stride = in UInt (4 bits)
    /** ★★ T-S1（2026-10-13）：**运行期行宽**（= 本层输入行宽；`WIDTH` 是分配上限 `W_MAX`）。
      *   本模块"按行宽自己数行"（列回绕即换行）⇒ 回绕点 / 行末列 / 幻影列的判据全部改用它；
      *   下游 `LineBuffer` 的列回绕也随此口。`rowW == WIDTH` ⇒ 与旧行为**逐拍同形**；
      *   `1 ≤ rowW ≤ WIDTH` 由驱动方（`UnitExec`/`BypassExec` 的 `go` 对账）拦住。 */
    val rowW   = in UInt (16 bits)
    // ---- 输出像素：一拍一个像素，C_OUT 个通道同时出 ----
    //   ★★ C4a-R2：`y/y_valid` 是 **requant 三级流水之后**的出料 ⇒ 相对"出数拍"整体**晚 3 拍**
    //     （数值逐字节不变；见文件头"★★ C4a-R2"一节）。
    val y       = out Vec (SInt(8 bits), C_OUT)
    val y_valid = out Bool()
    /** ★★ C4a-R2：`ps_out` 的**写回有效**（= `y/ps_out` 的原相位"出数脉冲"本身，**不随流水延迟**）。
      *   契约明写：`ps_out` 在 `ps_valid` 那一拍成立；`y` 在 `y_valid` 那一拍成立（= `ps_valid` 之后 3 拍）。
      *   编排器（`MultiPassUnit`）用 `ps_valid` 写回部分和（旧代码用的是 `y_valid`，两者曾是同一个信号）。 */
    val ps_valid = out Bool()
    // ---- ★ C4a.5a：多趟累加的部分和载入/写回（见文件头"(a) 部分和载入/写回"；★ §3.7 宽度 = `PSW`）----
    val ps_in   = in  Vec (SInt(PSW bits), C_OUT) // 本趟开始前从片上部分和缓冲读回的值（第 1 趟 = 上电初值 0）
    val ps_out  = out Vec (SInt(PSW bits), C_OUT) // = 本轮 acc + ps_in + bias（编排器在 `ps_valid` 拍写回）
    val bias    = in  Vec (SInt(32 bits), C_OUT)  // 累加器单位的偏置（只在第 1 趟非 0）
    // ---- ★ C4a.5a §4.4 requant：`((acc·M) >> REQUANT_Q) >> SHIFT + z_y` ----
    val requant_m = in  UInt (32 bits)            // 每层 Q24 乘子（C4a.5b 由权重信箱装载）
    val zero_y    = in  SInt (8 bits)             // 输出张量的 zero-point z_y
    // ---- 档位自报：只读常量 = GROUP。**不参与数据通路**，只给装置做"网表档位 vs +GROUP"对账：
    //      三份变体的端口同名同宽，装置自己分不出是哪一档，只能由网表把它报出来。
    val grp     = out UInt(4 bits)
    // ---- 宽度自报：只读常量 = WIDTH（生成该网表时用的行宽）。**不参与数据通路**，只给装置做
    //      "网表宽度 vs +IW"对账：LineBuffer 按 WIDTH 数行，网表宽度与装置喂的列数不符时窗口
    //      语义整个错位 —— 这种错**会产出长度对得上、数值大范围错的 Y**（不是缺数据），
    //      靠事后 MISMATCH 才发现既晚又像"数值 bug"。所以让网表把宽度报出来，装置在 time 0
    //      就对账，不符立即 fatal（生成时换过宽度却没重生成，这里当场报红）。
    val imgW    = out UInt(16 bits)
  }
  noIoPrefix()

  // ================================ 三个现成的部件（原样例化） ================================
  val lb  = LineBuffer(C_IN = C_IN, WIDTH = WIDTH)
  val ws  = WeightStore(C_IN = C_IN, C_OUT = C_OUT, GROUP = GROUP, DW = DWSKIP, DCI = DCI)   // ★ slice B1/C2：`DW=DWSKIP`（dw 对角读口）/ `DCI`（c3 ci-inner 读口）
  // 注：LineBuffer / WeightStore 是 case class（不用 new），GroupedMacArray 是普通 class（要 new）。
  val arr = new GroupedMacArray(C_IN = C_IN, C_OUT = C_OUT, GROUP = GROUP, DW = DWSKIP)   // ★ slice B1：`DW=DWSKIP` 同

  // 档位自报：常量输出（综合成一条 wire 赋值，不落任何逻辑）。装置据此拒绝错档网表。
  io.grp := U(GROUP, 4 bits)
  // 宽度自报：同 grp，常量输出。装置据此在 time 0 拒绝宽度不符的网表（防"宽度钉死"静默错判）。
  io.imgW := U(WIDTH, 16 bits)

  // ================================ 自己的行列/相位计数 ================================
  // 列宽：WIDTH=1 时也要 1 位，否则 Vec 索引没有位宽（与 LineBuffer 同口径）。
  // ★★ T-S1：`cw` 仍是**展开期**（= 分配按 `WIDTH`）；运行期回绕点另由 `rowWm1` 给。
  val cw = (log2Up(WIDTH) max 1)
  /** ★★ T-S1：运行期回绕点 `rowW - 1`（= 本行最后一列；`rowW == WIDTH` ⇒ 与旧常量同值）。 */
  val rowWm1 = (io.rowW - U(1, 16 bits)).resize(cw)
  // 状态：收列 → （行末的）幻影拍 → 像素相位。
  val st        = Reg(UInt(2 bits))  init (0)
  val cConsume  = U(0, 2 bits)
  val cPhantom  = U(1, 2 bits)
  val cPix      = U(2, 2 bits)
  val inConsume = st === cConsume
  val inPhantom = st === cPhantom
  val inPix     = st === cPix

  /** 刚收完（或正在收）的输入列，0..WIDTH-1；与 LineBuffer 内部的列计数器同步（同一条 en）。 */
  val col = Reg(UInt(cw bits)) init (0)
  /** 输入行号，从 0 起。0 就是预滚行（输出行 -1）—— 只用来决定"出不出像素"。 */
  val row = Reg(UInt(16 bits)) init (0)
  /** 像素相位：1..9 = 9 个 (ky,kx) tap；10 = 出数 + clr。 */
  val ph  = Reg(UInt(4 bits))  init (0)
  /** 本像素是不是行末插的幻影像素（零列 W）—— 决定它结束后换行。 */
  val phantomPix = Reg(Bool()) init (False)
  /** 刚起算的这个像素是不是**本行最后一列**（x=WIDTH-2）—— 它算完还要补一个幻影像素（x=WIDTH-1）。 */
  val colLast    = Reg(Bool()) init (False)

  val phZero = ph === U(0, 4 bits)
  val phTen  = ph === U(10, 4 bits)
  val rowOk  = row =/= U(0, 16 bits)      // row>=1 ⇒ 当前像素属于有效输出行 y=row-1
  val firstCol = col === U(0, cw bits)

  // ===========================================================================
  // ★★ C4b-D1：**步长（抽稀）** —— 输出只在每隔 `stride` 个输入行/列上产生
  // ===========================================================================
  // 语义（与 ONNX 的 `Conv(stride=s, pads=1)` 逐字对应；见文件头 D1 一节）：
  //   输入流**照旧逐列收满**（行缓冲/列延迟线一个字节都没跳过 —— 3 个 tap 恒为**相邻**三列），
  //   只是**像素相位**被抽稀：
  //     · 输出像素 (y,x) 的窗口中心落在输入列 `s·x`、输入行 `s·y`；
  //       而本模块"收完第 c 列"手上正好是中心为第 `c-1` 列的窗口 ⇒ **目标列 c ≡ 1 (mod s)**；
  //       同理"第 r 行流入"手上是中心为第 `r-1` 行的窗口 ⇒ **目标行 r ≡ 1 (mod s)**。
  //     · 非目标列/行：**照收列、照攒历史**，只是不进像素相位（`S_CONSUME` 连跑若干拍）。
  //   ⇒ 相位用两个模 `s` 计数器（不是除法、不是运行时取模）：
  //     `dm` = 已收列号 mod s（每行第 0 列清 0）⇒ 目标列 ⟺ `dm === 0`；
  //     `rm` = (已收行号-1) mod s（行进到第 1 行时归 0）⇒ 输出行 ⟺ `rm === 0`。
  //   ★ `s = 1`：两个计数器恒为 0 ⇒ `rowOut ≡ rowOk`、目标列 = 所有 `col ≠ 0`
  //     ⇒ 与"没有步长"**逐拍同形**（dm/rm/phantomNeed 三个新寄存器不影响任何数据通路信号）。
  //   ★ 幻影列（右边的零填充列 W）：它是目标列 ⟺ `(W-1) mod s == 0`。
  //     实现上就是"收列 `W-1` 时算出的下一个 `dm` 是否 0"（`phantomNext`）——
  //     `s=1` 时恒 1（= 旧行为：幻影拍恒发）。
  /** 有效步长（描述符字段 `0` 视作 `1` ⇒ 旧表/旧装置逐字节同形）。 */
  val effS   = Mux(io.stride === U(0, 4 bits), U(1, 4 bits), io.stride)
  /** `s - 1`（模计数器的回绕点）。 */
  val effSm1 = (effS - U(1, 4 bits)).resize(4)
  val dm     = Reg(UInt(4 bits)) init (0)
  val rm     = Reg(UInt(4 bits)) init (0)
  val dmNext = Mux(dm === effSm1, U(0, 4 bits), (dm + 1).resize(4))
  val rmNext = Mux(rm === effSm1, U(0, 4 bits), (rm + 1).resize(4))
  /** 换行时的行相位更新：`row==0 → row 1` 那一次归 0（`rm(1)=0`）。 */
  val rmOnRowAdv = Mux(row === U(0, 16 bits), U(0, 4 bits), rmNext)
  /** 收列 `W-1` 那一刻的"下一个 `dm`"= 幻影列（列 `W`）的 `dm` ⇒ 幻影是不是目标列。 */
  val phantomNext = dmNext === U(0, 4 bits)
  /** 本行本次行末是否需要补幻影拍（在进像素相位那一拍锁存；`s=1` 恒 1）。 */
  val phantomNeed = Reg(Bool()) init (False)
  /** 本行是否出像素（行相位）。 */
  val rowOut = rowOk && (rm === U(0, 4 bits))

  // ================================ 输入流的反压握手 ================================
  // 一列只吃一拍（S_CONSUME），吃下去的同时 LineBuffer 推进一列（en=1）。
  // en 与 win 同拍：win 是组合输出、读的是**旧**历史（写在下个时钟沿生效）⇒ 当拍锁进 colWin 正确。
  val beat = io.x_valid && inConsume
  io.x_ready := inConsume
  lb.io.x  := io.x
  lb.io.en := beat
  lb.io.rowW := io.rowW        // ★★ T-S1：运行期行宽直通下游 LineBuffer（列回绕/换行按它；分配仍按 WIDTH）
  lb.io.prime := io.prime     // ★ 相位复位口直通下游 LineBuffer（见文件头 prime 一节）
  lb.io.pad_val := io.pad_val // ★ C4a.5b §4.5：上边零填充的码点（LineBuffer 的 hist 由 0 改 z_pad）

  // ================================ 权重装载直通 ================================
  ws.io.we    := io.we
  ws.io.waddr := io.waddr
  ws.io.wdin  := io.wdin

  // ================================ 列延迟线（3 列 x C_IN x 3 行） ================================
  // colWin(cx)(ci)(rr)：cx=0 最老（列 c-2），cx=2 最新（列 c）；rr 与 LineBuffer 的 win 同行义。
  // 上/左边的零填充就在这两条 when 里：每行第一列清掉最老两级；幻影拍左移一格并填 0。
  val colWin = Vec(Vec(Vec(Reg(SInt(8 bits)) init (0), 3), C_IN), 3)
  when(beat) {
    for (ci <- 0 until C_IN) {
      for (rr <- 0 until 3) {
        // 每行第一列：最老两级清成**零填充码点** `pad_val`（列 -2 / -1 的填充，见文件头"左边"）。
        colWin(0)(ci)(rr) := Mux(firstCol, io.pad_val, colWin(1)(ci)(rr))
        colWin(1)(ci)(rr) := Mux(firstCol, io.pad_val, colWin(2)(ci)(rr))
        colWin(2)(ci)(rr) := lb.io.win(ci)(rr)
      }
    }
  }
  when(inPhantom) {
    for (ci <- 0 until C_IN) {
      for (rr <- 0 until 3) {
        // 幻影拍：等价于"全 `pad_val` 的列 W 流入"（右边零填充，见文件头"右边"）。
        colWin(0)(ci)(rr) := colWin(1)(ci)(rr)
        colWin(1)(ci)(rr) := colWin(2)(ci)(rr)
        colWin(2)(ci)(rr) := io.pad_val
      }
    }
  }

  val one_x1: Bool = if (X1SKIP) { val v = in Bool(); v.setName("one_x1"); v } else null
  // ★★ S4-C（2026-10-17）：one_x1 的**单拍中心采样**。真表 26 个 1×1 全部走宽路 + 1-tap 跳过；
  //   1-tap 跳过的唯一一拍原本是 (tapKx,tapKy)=(0,0) = 窗口**左上** (y-1,x-1)，而 ONNX/黄金的
  //   1×1 是**居中**的 ⇒ 26 个 1×1 整体偏移 (-1,-1)（仿 0/1.6M、板 0/6400 逐字节证据见
  //   reports/npu_v2_board_frame.md §15.7）。修法：像素起点在 one_x1 时把采样窗置到**中心**
  //   (1,1)，权重槽仍用 tapK=0（blob 布局不变）。3×3 路径（one_x1=0）逐字不变。
  // ================================ 9 个 tap 的选择（★ C3.18 R3-3：改**寄存计数器**） ================================
  // ph=1..9 → tap 序号 t=0..8 → ky=t/3、kx=t%3。
  // ★ 旧写法是 9 路优先级译码 `when(ph === t+1) { kxSel := ...; kySel := ... }`：它把这 2 级 LUT
  //   摆在**每一个乘数输入锥的头部**，并在网表里长出一族高扇出译码网（板级 device_map 实测
  //   `when_Conv3x3Slice_l197_*` 单网扇出 514..576 —— 就是这个译码结果在驱动
  //   `colWin(kx)(ci)(ky)` 的 3x3 选择器，8 通道 x 3x3 = 72 个 8 位 2:1 = 576 个选择端）。
  // ★ 现在改成**三个寄存计数器**（kx、ky 给列/行选择，k 给 WeightStore 的瓦片选择），值序列与旧译码
  //   **逐拍完全相同**（ph=1..9 分别是 (kx,ky) = (0,0)(1,0)(2,0)(0,1)(1,1)(2,1)(0,2)(1,2)(2,2)、k = 0..8），
  //   只是把"从 ph 译出 (kx,ky)"的组合逻辑换成"像素起点置 0、每个 tap 拍走一格"的计数：
  //   选择端直接由 FF 输出 ⇒ 乘数输入锥头部不再有 LUT，也没有那条高扇出译码网。
  // ★ 零延迟变化：拍数、状态机、进出料时序一字不动（只换了"选择端从哪来"）。
  // ★ 饱和语义：ph=9 那拍把 (2,2) 推进到 (0,2)（k 停在 8），此后 ph=10 不再推进——
  //   那一拍 arr.en=0（瓦片/tap 都不参与运算），所以停在哪个值都不影响数据通路。
  val tapKx = Reg(UInt(2 bits)) init (0)
  val tapKy = Reg(UInt(2 bits)) init (0)
  val tapK  = Reg(UInt(4 bits)) init (0)          // = ky*3+kx，给 WeightStore 的 k
  when(inPix && !phZero && !phTen) {              // ph=1..9：本拍用完就推进一格（准备下一拍）
    when(tapKx === U(2, 2 bits)) {
      tapKx := U(0, 2 bits)
      when(tapKy =/= U(2, 2 bits)) { tapKy := (tapKy + 1).resize(2) }
    } .otherwise {
      tapKx := (tapKx + 1).resize(2)
    }
    when(tapK =/= U(8, 4 bits)) { tapK := (tapK + 1).resize(4) }
  }
  when(inConsume || inPhantom) {                  // 像素起点（收列拍 / 幻影拍）：第一个 tap 是 (0,0)/k=0
    // ★ S4-C：one_x1 ⇒ 单拍采样窗口中心 (1,1)（权重槽仍 tapK=0）；3×3 保持 (0,0)。
    tapKx := (if (X1SKIP) Mux(one_x1, U(1, 2 bits), U(0, 2 bits)) else U(0, 2 bits))
    tapKy := (if (X1SKIP) Mux(one_x1, U(1, 2 bits), U(0, 2 bits)) else U(0, 2 bits))
    tapK  := U(0, 4 bits)
  }
  ws.io.k := tapK                                 // WeightStore 的 k = ky*3+kx（0..8）

  // tap(ky,kx)(ci) = colWin(kx)(ci)(ky)：kx 选列（动态下标 = 3 选 1），ky 选行（3 选 1）。
  // 选择端现在直接来自上面三个寄存器（见 R3-3），乘法器输入锥的头部再无译码 LUT。
  val arrX = Vec(SInt(8 bits), C_IN)
  for (ci <- 0 until C_IN) {
    arrX(ci) := colWin(tapKx)(ci)(tapKy)
  }
  arr.io.w_tile := ws.io.tile
  arr.io.x      := arrX
  arr.io.en     := inPix && !phZero && !phTen   // ph=1..9 才累加

  // ================================ requant：>>>SHIFT + clamp 到 int8 ================================
  // 契约（tools/mac_ref.py）：y = max(-128, min(127, acc >> 6))，>> 必须是**算术**右移。
  // SpinalHDL 里 SInt 的 `>>` 就是算术右移（网表上是带符号操作数的移位）—— 生成后须核对。
  // 注意位宽：SpinalHDL 的 SInt `>>` 是**算术**右移、并且会把结果位宽收到「够放得下」的位数
  // （32 位移 6 位 ⇒ 26 位）；这里显式 resize 回 32 位再比常量，免得常量越界。
  //
  // ★★ C3.18 R3-2：**出数与 clr 从 `ph=10` 挪到紧随其后的"阵列空闲拍"**（`pixelPending` 门控）。
  //   为什么必须挪：MacArray 现在是**两级流水**（A 级寄存对和、B 级平衡树+累加，见其文件头）⇒
  //   第 9 个 tap 在 ph=9 喂进去、它的贡献要到 **ph=10 拍末尾**才落进 `acc` ⇒ **ph=10 拍 `acc`
  //   还不是本像素的完整和**，完整和要到 ph=10 之后那一拍才稳定。
  //   于是把「读 p + requant + 置 y_valid + clr 累加器」整体挪到 ph=10 之后的**阵列空闲拍**：
  //     · 那一拍阵列空闲（`arr.en=0`，其 clr 由这里驱动），`acc` 已是完整和 ⇒ requant 取到的
  //       正是本像素的和；
  //     · `clr` 仍在**下一个像素第一个 tap 之前**（clr 在收列/幻影拍；ph=1 在再下一拍）⇒ MacArray
  //       的 "clr 与 en 必须分拍" 契约不破，且不会吞掉任何 tap；
  //     · 像素节拍仍是 **1 收列 + 10 ph = 11 拍** ⇒ **零吞吐代价**（不选"12 拍"那一档，见
  //       R3-2 的两个候选；这里取的是零代价那个）。
  //   `pixelPending`：一个像素的相位跑完（ph=10）就置位，在**紧随的第一个阵列空闲拍**出数并清除。
  //   ★ "阵列空闲拍" = S_CONSUME **或** S_PHANTOM：ph=10 之后的下一拍由状态机决定 ——
  //     普通像素进 S_CONSUME（下一列流入那拍），**行末最后一列（colLast）进 S_PHANTOM**
  //     （右边零填充用的幻影拍，那一拍不收列）。两条都必须能出数，否则行末那个像素（x=W-2）
  //     会被吞掉（相位标志被幻影像素的相位覆盖），后面整行像素按序错位。
  //     幻影拍与收列拍一样对阵列是空闲的（`arr.en=0`、`arr.clr` 由这里驱动）⇒ 在幻影拍出数安全。
  //   ⇒ 即使收列被反压（x_valid 迟迟不来、S_CONSUME 停很多拍），该像素也只出**一次**。
  //   对下游（`UnitExec` 的 `pixIdx`/`outMem`/行锁步门、`Conv3x3Tb` 的 `pi`/`extra`）而言：
  //   出数**顺序与个数逐位不变**，只是每像素的 `y_valid` 从"ph=10 拍"平移到"紧随的阵列空闲拍"。
  val pixelPending = Reg(Bool()) init (False)
  val arrIdleBeat  = inConsume || inPhantom           // 阵列空闲拍：收列拍 或 幻影拍
  when(inPix && phTen)                { pixelPending := True }     // 相位跑完 → 待出数
  when(arrIdleBeat && pixelPending)   { pixelPending := False }    // 阵列空闲拍出数（只出一次）

  // ★★ C4a-R2：`emitPulse` = "出数脉冲"（**未延迟**：阵列空闲拍 + `pixelPending`）。
  //   `arr.clr` 与 `ps_out/ps_valid` 用它（原相位）；`y/y_valid` 走下面的三级流水（3 拍后）。
  val emitPulse = arrIdleBeat && pixelPending
  io.ps_valid := emitPulse
  arr.io.clr  := emitPulse                      // 与出数同拍清累加器（acc 当拍仍是完整和）

  // ===========================================================================
  // ★★ C4a-R2：§4.4 requant 的**三级流水**（板级时序收敛；数值**逐位等价**）
  // ===========================================================================
  // 板级 PnR（`sim/reglogs/pds_pnr_c4a_c4a_p10.000`，seed_0 的 `..._rtr`）实测最坏 `cpu_clk` 路径：
  //   `layerSched/chainLenR → BypassExec → UnitExec/mzRam(LUTRAM 组合读 + 读 mux，fanout 47) →
  //    sliceRest_N/N349_m1..m4（**4 级 APM cascade**，逻辑 6.34 ns）→ N569 加法器 →
  //    N574_mux64/mux65 钳位 mux → UnitExec/outMemT DI`：数据到达 24.396 ns、slack −11.393 ns。
  // 本条把这条组合链切成**三级寄存器**，每级只留"半个乘法 + 一点后处理"：
  //   · 第 1 级（出数拍）：`AH·M`（64 位积）与 `AL` 落寄存器；
  //   · 第 2 级（+1 拍）：`AL·M`（65 位积）落寄存器；
  //   · 第 3 级（+2 拍）：`shf = (AL·M >> 30) + (AH·M << 2)`（= 精确的 `floor(prod/2^30)`）+ `z_y` + 钳位。
  //
  // ---- 为什么**逐位等价**（精确整数恒等式，不是近似）----
  //   令 A = `accTot`（`PSW` 位有符号；★ §3.7：按第 32 位切，`AH` = 高半**有符号**、`AL` = 低 32 位**无符号**），M = `requant_m.asSInt`（32 位有符号，**与旧写法同一读法**）。
  //   把 A 按 32 位切成 A = AH·2^32 + AL：AL = A[31:0]（按**无符号**读，∈ [0,2^32)）、
  //   AH = A[63:32]（按**有符号**读）。则
  //       prod = A·M = AH·M·2^32 + AL·M
  //   而 AH·M·2^32 / 2^30 = AH·M·4 是**整数** ⇒ 由 floor 的平移性质
  //       floor(prod / 2^30) = floor(AL·M / 2^30) + AH·M·4。
  //   旧写法 `((prod >> 24) >> 6)` = floor(prod/2^24) 再 floor(/2^6) = floor(prod/2^30)（嵌套 floor 恒等）
  //   ⇒ 两种写法给出**完全相同的整数**（`z_y` 的加法、±127/−128 的钳位、`resize(8)` 逐字相同）。
  //   位宽上无溢出：|AL·M| ≤ (2^32−1)·2^31 < 2^63、|AH·M| < 2^63 ⇒ 65/64 位产品线装得下。
  //
  // ---- 对外时序（明写）----
  //   `y_valid` 相对"出数拍"晚 **3 拍**（三级流水），像素节拍仍是 11 拍 ⇒ **吞吐一字不变**，
  //   只是每个像素的出料相位整体后移 3 拍。`ps_out`/`ps_valid` 是**另一条**契约（原相位）。
  //   所有消费者（`UnitExec` / `MultiPassUnit`）都是标志驱动的流式握手 ⇒ 顺序/个数/数值不变。
  val RQ: Int = REQUANT_Q + SHIFT                  // = 30（旧 `((prod >> 24) >> 6)` 的等效单次右移）
  require(RQ >= 1 && RQ < 32, "requant 等效右移必须落在 (0,32)：32−RQ 是 AH·M 左移的位数")
  /** 出数拍（未延迟）与它的 1/2/3 拍延迟（三级流水的写使能 / `y_valid`）。 */
  val emitD1 = RegNext(emitPulse) init (False)
  val emitD2 = RegNext(emitD1)    init (False)
  val emitD3 = RegNext(emitD2)    init (False)
  /** 第 1 级寄存：`AH·M`（64 位）与 `AL`（32 位，无符号）。 */
  val pHiR = Vec(Reg(SInt(64 bits)) init (0), C_OUT)
  val aLoR = Vec(Reg(UInt(32 bits)) init (0), C_OUT)
  /** 第 2 级寄存：`AL·M`（65 位）。 */
  val pLoR = Vec(Reg(SInt(65 bits)) init (0), C_OUT)
  /** 第 3 级寄存：钳位后的 int8 出料（`io.y` 就是它）。 */
  val yR   = Vec(Reg(SInt(8 bits)) init (0), C_OUT)
  for (co <- 0 until C_OUT) {
    // ★ C4a.5a 累加：`acc_total = 本轮 int32 acc（符号扩展到 PSW 位） + 读回的部分和 + 偏置`。
    //   · 第 1 趟：`ps_in` 是部分和缓冲的**上电初值 0** ⇒ 这就是冻结口径的"累加器清零"；
    //   · 第 k>1 趟：`ps_in` 是前面所有 `ci` 趟的部分和 ⇒ 逐字落实"读回部分和 → 加到本轮 acc"；
    //   · 写回 `ps_out` 由编排器在 `ps_valid` 拍落到 `PartialSumBuf`（★ §3.7：`PSW==64` 时下面四行**逐字**同旧）
    val accTot = arr.io.p(co).resize(PSW) + io.ps_in(co) + io.bias(co).resize(PSW)
    io.ps_out(co) := (if (PSW == 64) accTot else accTot.resize(PSW))   // PSW=64 ⇒ 原文（隐式截断同旧）
    // ---- 第 1 级（出数拍）：AH·M 与 AL 落寄存器 ----
    val aHiS = (if (PSW == 64) accTot else accTot.resize(PSW).resize(64))(63 downto 32)  // = A >> 32（有符号高半）
    val aLoU = (if (PSW == 64) accTot else accTot.resize(PSW).resize(64))(31 downto 0).asUInt  // 低半**无符号**读
    when(emitPulse) {
      pHiR(co) := aHiS * io.requant_m.asSInt
      aLoR(co) := aLoU
    }
    // ---- 第 2 级（出数拍 +1）：AL·M 落寄存器 ----
    when(emitD1) {
      pLoR(co) := aLoR(co).resize(33).asSInt * io.requant_m.asSInt   // 33 位**零扩** ⇒ 恒非负
    }
    // ---- 第 3 级（出数拍 +2）：`floor(prod/2^30)` + z_y + 钳位 ----
    val shf  = (pLoR(co) >> RQ) + (pHiR(co) << (32 - RQ))
    val valq = shf + io.zero_y
    val wq: Int = valq.getWidth
    when(emitD2) {
      yR(co) := Mux(valq > S(127, wq bits),  S(127, 8 bits),
                Mux(valq < S(-128, wq bits), S(-128, 8 bits), valq.resize(8)))
    }
  }
  io.y       := yR
  io.y_valid := emitD3

  // ================================ 调度状态机 ================================
  // ★★ C4b-D1：收列分支按步长抽稀（三条分支；`s=1` ⇒ 第 1 条只多清一个恒 0 的 `dm`，
  //   第 2 条只在预滚行/被跳过的行上走 —— 与旧的两分支**逐拍同形**）。
  when(beat) {
    when(firstCol) {
      // 每行第 0 列：列相位归 0（x = -1，不出像素 —— 与旧版同形）。
      dm := U(0, 4 bits)
      col := U(1, cw bits)
    } .elsewhen(!rowOut) {
      // 预滚行 / 步长跳过的行：只推进（仍维护列相位与行相位）。
      dm := dmNext
      when(col === rowWm1) {
        col := U(0, cw bits)
        row := (row + 1).resize(16)
        rm  := rmOnRowAdv
      } .otherwise {
        col := (col + 1).resize(cw)
      }
    } .otherwise {
      dm := dmNext
      when(dm === U(0, 4 bits)) {
        // 目标列 ⇒ 进像素相位（窗口中心 = 本列 - 1 = s·x）。
        st := cPix
        ph := U(1, 4 bits)
        phantomPix := False
        colLast := (col === rowWm1)
        phantomNeed := phantomNext
        // c=W-1 是本行最后一列：它的像素算完之后按 `phantomNeed` 决定补幻影还是换行，
        // 所以列号先不推进（留到幻影/换行那一刻）。
        when(col =/= rowWm1) {
          col := (col + 1).resize(cw)
        }
      } .otherwise {
        // 非目标列（被步长跳过的列）：直接跳过，不进像素相位。
        when(col === rowWm1) {
          // 行末：若幻影列是目标列 ⇒ 补幻影拍（右边零填充那一列）；否则直接换行。
          when(phantomNext) {
            st := cPhantom
          } .otherwise {
            col := U(0, cw bits)
            row := (row + 1).resize(16)
            rm  := rmOnRowAdv
          }
        } .otherwise {
          col := (col + 1).resize(cw)
        }
      }
    }
  }

  when(inPhantom) {
    // 幻影拍只做列延迟线的左移+填 0（在 when(inPhantom) 里已写），这里只管推进状态。
    st := cPix
    ph := U(1, 4 bits)
    phantomPix := True
  }

  when(inPix) {
    when(phTen) {
      when(phantomPix) {
        // 幻影像素结束 ⇒ 本行彻底结束：换行。
        st := cConsume
        col := U(0, cw bits)
        row := (row + 1).resize(16)
        rm  := rmOnRowAdv
      } .elsewhen(colLast) {
        // 本行最后一列的像素结束 ⇒ 需要右边零填充就补幻影拍，否则直接换行（★ C4b-D1：
        // `s=1` 时 `phantomNeed` 恒真 ⇒ 与旧版"总是补幻影"逐拍同形）。
        when(phantomNeed) {
          st := cPhantom
        } .otherwise {
          st := cConsume
          col := U(0, cw bits)
          row := (row + 1).resize(16)
          rm  := rmOnRowAdv
        }
      } .otherwise {
        st := cConsume
      }
    } .otherwise {
      ph := (ph + 1).resize(4)
    }
  }

  // ================================ ★ prime：一拍清相位回到"刚上电" ================================
  // 放在**所有调度分支之后** ⇒ 优先级最高（SpinalHDL 对同一信号的多次赋值按出现顺序取最后者）。
  // 清的就是上面那些 per-image 寄存器：状态机 `st`、列 `col`、行 `row`、像素相位 `ph`、
  // 幻影标志 `phantomPix`/`colLast`、列延迟线 `colWin`，以及 ★R3-2/R3-3 新增的
  // `pixelPending`（待出数标志）与三个 tap 计数器 `tapKx/tapKy/tapK`。值与各寄存器 `init(0)`
  // 逐项相同 ⇒ 下一拍收列时与"上电后的第一列"逐拍同形。下游 `LineBuffer` 由 `lb.io.prime`
  // 同步清（上面已接）。
  when(io.prime) {
    st           := U(0, 2 bits)
    col          := U(0, cw bits)
    row          := U(0, 16 bits)
    ph           := U(0, 4 bits)
    phantomPix   := False
    colLast      := False
    pixelPending := False
    tapKx        := U(0, 2 bits)
    tapKy        := U(0, 2 bits)
    tapK         := U(0, 4 bits)
    dm           := U(0, 4 bits)   // ★ C4b-D1：列相位 / 行相位 / 幻影目标标志一并回上电态
    rm           := U(0, 4 bits)
    phantomNeed  := False
    for (ci <- 0 until C_IN) {
      for (rr <- 0 until 3) {
        for (cx <- 0 until 3) {
          colWin(cx)(ci)(rr) := io.pad_val   // ★ C4a.5b §4.5：清成零填充码点（旧的硬编码 0）
        }
      }
    }
  }

  // ===========================================================================
  // ★★ NPU v2 §4.6-5（slice A，2026-10-16）：**1×1 只发 1 个 tap-beat**（"跳拍"读法①）
  // ===========================================================================
  // 背景（spec §4.5-① / §4.6-5；价签见 `reports/npu_v2_accounting.md` §P0b-2）：
  //   本切片**恒跑 9 个 tap 相位**（ph=1..9），1×1 卷积的其余 8 个抽头权重恒 0 ⇒ 白烧 9.49× 拍。
  //   真 blob 的 26 个 1×1 单元（`gen/wgt_blob.bin`，42,697 个非零权重字节）**全部落在每
  //   `(co,ci)` 9 槽的第 0 槽**（`(ky,kx)=(0,0)`；`CHECK cf_a_1x1_nonzero_only_slot0`），而本切片的
  //   拍序是 `ph=1 → tapK=0`（**先发槽 0**）⇒ 跳过 ph=2..9 去掉的**恰是 8 个零权重拍**：
  //   **数值逐字节不变、零权重布局改动**（这就是"跳拍"读法①；不搬槽、不改 blob、不改装载映射）。
  //
  // 怎么跳（**只动相位计数器，一条 late-override，零新增数据通路**）：
  //   本文件的相位推进在 `when(inPix){ when(phTen){…} otherwise { ph := ph+1 } }`；本节在**类体末尾**
  //   追加一条**后写覆盖**：`one_x1=1 ∧ ph==1` ⇒ `ph := 10`（SpinalHDL 对同一 Reg 的多次赋值按出现
  //   顺序取最后者）⇒ 像素相位从"ph=1..9 + ph=10"缩成"ph=1 + ph=10"。
  //   · 数据面**一字未动**：ph=1 那一拍的 `tapKx/tapKy/tapK = 0` ⇒ `arrX(ci)=colWin(0)(ci)(0)`、
  //     `ws.k=0` —— 与改动前的第一个抽头**同一拍、同一选择**（colWin 只在收列/幻影拍移位，相位期内
  //     恒定）⇒ 槽 0 的数据/权重取法与旧版**逐位相同**；
  //   · 出数与后处理**一字未动**：`ph=10 → pixelPending → 阵列空闲拍出数（emitPulse）`这条链原样：
  //     `accTot = acc + ps_in + bias`（**每像素每趟一次**）、`ps_valid` 写回（一次）、
  //     三级流水 requant（一次）全部保持 —— 跳掉的相位既不吃 bias 也不吃 ps/requant；
  //   · MacArray 契约不破：唯一一个 tap-beat 在 ph=1（`arr.en=1`），ph=10 与出数拍 `arr.en=0`，
  //     `clr` 仍在出数拍 ⇒ "clr 与 en 分拍"照旧（且第 9 抽头"落进 acc 再出数"的两级流水余量在
  //     1 抽头档下更宽裕：tap 在 ph=1 喂、出数最早在 2 拍之后）。
  //   · `prime` 优先级不动：本节带 `!io.prime` 守卫 ⇒ 相位复位口径与旧版一致（prime 恒赢）。
  //
  // 1×1 的真源（**为什么是口、不是本模块自己判**）：本切片**不解释描述符**（文件头口径：RTL 不假设
  //   任何权重取值）。"这是不是 1×1"由**驱动方**给 `one_x1`（本口只在 `X1SKIP=true` 的展开里存在）：
  //   `UnitExec` 用**描述符 TYPE `0x02`**（`DescType.CONV1`，`go` 那一拍闩存）驱动它 —— 理由见
  //   `UnitExec.scala` 文件尾「slice A」一节（宽通路 chainLen==1 下 `slot0Ok` 已断言
  //   `chain_1x1(0) === (dw.tpe == 0x02)`，两条来源在那里是**同一件事**；TYPE 是运行期的权威字段）。
  //
  // 观测口 `obs_beats`：**tap-beat 计数**（`arr.en` 拍数，上电起累计；`X1SKIP` 才存在）。它就是
  //   `mac_account.py` 的 `beats_issued = taps·passes·H·W` 的**实测**对应物：同一作业 1×1（1 拍/像素/
  //   趟）对 3×3（9 拍/像素/趟）= **9.00×**（闸门 `run_x1skip_ab.sh` 断言预测值，不是"看着像"）。
  //
  // ★ 行数中性纪律（`TILING=false` 三网表逐字节冻结）：本节**追加在类体最后一条语句之后** ⇒
  //   既有语句的行号一根没动；`X1SKIP=false`（缺省 = `SliceGen` / 窄通路 / `TILING=false` 的
  //   `UnitExec`）连**一根线、一个端口**都不加。`PSW` 那一节的同款理由见文件尾。
  // ===========================================================================
  val obs_beats: UInt = if (X1SKIP) { val v = out UInt(32 bits); v.setName("obs_beats"); v } else null
  if (X1SKIP) {
    /** tap-beat 计数（= `arr.en` 拍数；上电初值 0、运行期不清零 ⇒ TB 读到的是"本次仿真累计发出拍"）。 */
    val beatCnt = Reg(UInt(32 bits)) init 0
    when(inPix && !phZero && !phTen) { beatCnt := beatCnt + 1 }   // = `arr.io.en` 的判据（见上面那一行）
    obs_beats := beatCnt
    /** 1×1 跳拍：ph=1 直接跳到 ph=10（`!io.prime` ⇒ 相位复位口的优先级不变）。 */
    when(inPix && one_x1 && (ph === U(1, 4 bits)) && !io.prime) { ph := U(10, 4 bits) }
  }

  // =================================================================================================
  // ★★ NPU v2 切片 B1（2026-10-16）：**depthwise 用满 8 条通道**（AFTER1 档）
  // =================================================================================================
  // 出处：spec §4.6a（钉死的接口）/ `reports/npu_v2_accounting.md` §Slice B-1（实测价签）。
  // 参考实现（算术逐字同源）：`rtl_test/DwLaneProbe.scala` 的 **AFTER1 档** + 装置 `rtl_test/DwLaneTb.v`
  // （六形状 C∈{4,8,10,16,32,64} 逐字节 == 冻结黄金、拍比 9.00×）。
  //
  // ---- 要治的浪费（现 dw 路径）----
  // 现 dw 走**对角趟**（`UnitExec.isDwW`），但 x 是**一条 8 宽广播**（`arrX(ci)=colWin(tapKx)(ci)(tapKy)`）
  // 而 dw 的权重只在 `co==ci` 非 0 ⇒ **一拍 64 槽里只有对角 8 槽有用**、每像素 **9 拍**（8.10× 浪费，
  // 占全帧 issued 17.8%；A 之后占剩余拍的 57.7%）。
  //
  // ---- 结构发现（本档的全部理由）----
  // 把**抽头当内维**：lane `(r,j)` 算 `x[r][j]·w[r][j]`。**不需要 8×8 交叉开关** —— 因为 9 个抽头对
  // **同一个像素同一拍就全在** `colWin` 里（窗口是寄存器），dw 档的 x 就是**某几条寄存器的直连**：
  //     `xLane(r,j) = colWin(j%3)(r)(j/3)`     （kx=j%3、ky=j/3 对每个 lane 是**常数**）
  // （切片口径 `tap(ky,kx) = colWin(kx)(ci)(ky)`，见文件头"坐标与时间约定"；`tapK` 的计数序
  //  `k = ky*3+kx` ⇒ 抽头 j 就是第 j 个 tap 拍读的那个值，见下面 `tapK` 一节）。
  // w 同理：dw 的对角零填瓦片里 `mem[r*72 + r*9 + j]` 就是"通道 r 的抽头 j"（`WeightStore` 的
  // **新增 dw 对角读口**；576 个寄存器本来就在片上）⇒ dw 档的权重也是**静态寄存器直连**。
  // ⇒ 一张网表要同时服务 dense（广播 + 9 选 1 瓦片）与 dw（逐 lane）⇒ 只有**逐 lane 的 2:1 选择器**
  //   是新的（在 `MacArray` 的乘法器输入锥上，`dw_mode` 选来源；这也是 spec §7-R6 的时序项）。
  //
  // ---- 拍数与相位（本档唯一的调度改动）----
  // dw 档 **1 拍/像素/趟**（AFTER1 档 = 加第 9 抽头行；不加就是 AFTER2 的 2 拍，见报告 §B1-2）：
  //   `dw_mode=1 ∧ ph==1 ⇒ ph := 10`（**与 1×1 跳拍逐字同一条 late-override**）⇒ 像素相位从
  //   "ph=1..9 + ph=10" 缩成 "ph=1 + ph=10"。
  //   · ph=1 那一拍 `tapKx/tapKy/tapK = 0`；9 个抽头的 x/w 由**静态直连**给出（与 ph 无关）⇒
  //     8 条 lane 吃抽头 0..7、`x8/w8` 吃抽头 8（(ky,kx)=(2,2) = `colWin(2)(r)(2)`）—— **一拍全吃完**；
  //   · 出数与后处理**一字未动**：`ph=10 → pixelPending → 阵列空闲拍出数（emitPulse）` 这条链原样
  //     （`accTot = acc + ps_in + bias` 每像素每趟一次、`ps_valid` 写回一次、三级流水 requant 一次）；
  //   · MacArray 契约不破：唯一一个 tap-beat 在 ph=1（`arr.en=1`），ph=10 与出数拍 `arr.en=0`、
  //     `clr` 在出数拍（收列/幻影拍）⇒ "clr 与 en 分拍"照旧；像素节拍 11 → **3 拍**
  //     （1 收列 + 1 tap + 1 排空）—— 喂列/收料都按 `x_ready`/`ps_valid` 自同步（`MultiPassUnit`
  //     的"读地址提前一拍摆好"仍成立：相邻出数拍间隔 3 拍 ≥ 同步读的 1 拍）。
  //   · `obs_beats`（= `arr.en` 拍数）**自动**跟着变：`beatCnt` 的判据 `inPix && !phZero && !phTen`
  //     在 dw 档恰是 ph=1 那一拍 ⇒ **实测 1 拍/像素/趟**（dense 仍 9 拍；TB 自报对账，见闸门）。
  //   · `prime` 优先级不动：本节带 `!io.prime` 守卫 ⇒ 相位复位口径与旧版一致（prime 恒赢）。
  //
  // ---- 为什么 dw 的真源是口、不是本模块自己判 ----
  // 本切片**不解释描述符**（文件头口径：RTL 不假设任何权重取值）。"这是不是 dw"由**驱动方**给
  // `dw_mode`（`UnitExec` 用 `isDwW` = 描述符 `GROUP==C_in==C_out` 在 `go` 那一拍锁存；与装载器
  // 零填前提 `grpOkW` 取同式）—— 本口只在 `DWSKIP=true` 的展开里存在（同 `one_x1` 的接线法）。
  // ★ 前提（实测，报告 §B1-1）：装载器对 dw 的趟瓦片做**跨组零填** ⇒ 对角 entry 就是真权重，
  //   **blob / 装载器 / 描述符 / 趟循环 / 收料门 / `ps_clr` / 宽链一条都不用改**。
  //
  // ★ 行数中性纪律（`TILING=false` 三网表逐字节冻结）：本节**追加在类体最后一条语句之后** ⇒ 既有
  //   语句的行号一根没动；`DWSKIP=false`（缺省 = `SliceGen` / 窄通路 / `TILING=false` 的 `UnitExec`
  //   / 独立 `MultiPassUnit`|`DwUnit`）连**一根线、一个端口**都不加。
  // =================================================================================================
  val dw_mode: Bool = if (DWSKIP) { val v = in Bool(); v.setName("dw_mode"); v } else null
  if (DWSKIP) {
    require(X1SKIP, "DWSKIP 依赖 X1SKIP 的 `beatCnt/obs_beats`（本代两个口同生同灭，见报告 §Slice B-1）")
    /** dw 跳拍：ph=1 直接跳到 ph=10（1 拍/像素/趟；与 1×1 跳拍**同一条 late-override 写法**）。 */
    when(inPix && dw_mode && (ph === U(1, 4 bits)) && !io.prime) { ph := U(10, 4 bits) }
    /** dw 档的逐 lane x（静态寄存器直连；`dw_mode=0` 时阵列走广播，这两组线不被吃）。 */
    for (r <- 0 until C_IN) {
      for (j <- 0 until C_IN) { arr.x_dw(r)(j) := colWin(j % 3)(r)(j / 3) }
      arr.x8(r) := colWin(2)(r)(2)          // 第 9 抽头：(ky,kx)=(2,2)
      arr.w8(r) := ws.dwTile8(r)
      for (j <- 0 until C_IN) { arr.w_dw(r)(j) := ws.dwTile(r)(j) }
    }
    arr.dw_mode := dw_mode
  }

  // =================================================================================================
  // ★★ NPU v2 切片 C2（2026-10-16）：**dense ci-inner（DCI）** —— ci 进拍、tap 进 lane
  // =================================================================================================
  // 出处：spec §4.6b-②（切片 C-1 钉死的接口）/ `reports/npu_v2_accounting.md` §Slice C-1 §C1-3；
  // 参考实现 = `rtl_test/CiPackProbe.scala`（DCI 档，独立探针**已实测**：真表 `Conv_0` 拍比 3.00×、
  // 真表 `1→1` 9.00×、两档逐字节 == 黄金）；本段按那条钉死的接口**逐字落地**，不改设计。
  //
  // ---- 要治的浪费（现拍序）----
  // 现 dense 拍序是 **tap-major**：`arrX(ci) = colWin(tapKx)(ci)(tapKy)`，每像素恒 9 个 tap 拍、
  // ci 是 lane。`C_in=3`（真表 `Conv_0`）时 8 条 ci lane 只有 3 条有用；`C_in=C_out=1`（真表六片
  // `1→1 3×3`）一拍 64 槽只有 9 个有用乘 —— 浪费在**拍序**上（C-1 逐层对账：这两块 = 1,300,837.5 拍）。
  //
  // ---- 本段的换法（与 B1 的 dw tap-inner 同一结构，只把"通道"换成"ci"）----
  // 一拍吃一个 ci 的**全部 9 个抽头**：lane j = 抽头 j（`kx=j%3`、`ky=j/3` 静态），第 9 抽头复用
  // B1 AFTER1 的 `x8/w8` 行；像素相位从 9 拍缩到 `C_in` 拍。x 操作数 = `colWin(kx)(c3ci)(ky)`
  // （只有 **ci 索引**是运行期 = 拍号 − 1 ⇒ 逐 lane 一条 4:1 读）；w 操作数 = `WeightStore` 的
  // **新 c3 读口**（576 B 瓦片内部 ⇒ blob/装载器/描述符零改动，见 `WeightStore.scala` 文件尾）。
  // 数值逐字节不变：整数加法重排（每个 ci 拍 9 个抽头并进同一 `acc`）、requant/bias/ps/出料一字未动。
  //
  // ---- 为什么 DCI 的真源是口、不是本模块自己判 ----
  // 本切片**不解释描述符**（文件头口径）。"这是不是 ci-inner 档"由驱动方给 `dci_mode`
  // （`UnitExec` 用 `isDciW` = 宽路 ∧ dense(GROUP==1) ∧ `0 < C_in ≤ 4`（⇒ nCi==1）在 `go` 那拍锁存
  // —— 与 C-1 钉死的判据**逐字同式**）+ `c3_cin`（= 该层 `C_in`，同拍锁存）。真表 7 个单元
  // （`Conv_0` 3→16 + 六片 `1→1`）全部落在 `C_in ∈ {3,1}`。
  //
  // ★ 行数中性纪律（`TILING=false` 三网表逐字节冻结）：本节**追加在类体最后一条语句之后**
  //   （`DWSKIP` 块之后、类右括号之前）⇒ 既有语句行号一根没动；`DCI=false`（缺省 = `SliceGen` /
  //   窄通路 / `TILING=false` 的 `UnitExec` / `MultiPassUnit.v` 独立展开）连一根线、一个端口都不加。
  // ★ `DCI ⇒ DWSKIP`：逐 lane 通路（`x_dw/w_dw/x8/w8` 与 `laneSel`）就是 B1 已落地的那四个口，
  //   本节只在其上补一个"来源三选一"的逐 lane 选择器（dense 广播 / dw 对角 / **c3 ci-inner**）。
  // =================================================================================================
  val dci_mode: Bool = if (DCI) { val v = in Bool(); v.setName("dci_mode"); v } else null
  val c3_cin: UInt = if (DCI) { val v = in UInt (4 bits); v.setName("c3_cin"); v } else null
  if (DCI) {
    require(DWSKIP, "DCI 复用 dw 档的逐 lane 口（x_dw/w_dw/x8/w8 与 laneSel），本代两口同生同灭")
    require(X1SKIP, "DCI 复用 X1SKIP 的 `obs_beats` 观测口（拍比实测的判据面），本代两口同生同灭")
    /** 当前 ci 拍号（= ph − 1，0..C_in−1；`C_in ≤ 4` 是本片钉死的口径，真表只需 {3,1}）。 */
    val c3ci: UInt = (ph - U(1, 4 bits)).resize(2)
    /** c3 档的逐 lane x 取数：lane j 的 `(kx,ky)` 静态、**ci 索引 = 当前拍号**（4:1 读，
      *   展开成 3 条 `Mux` 比较 —— 与探针同一形状，选择子是寄存器直连的静态下标条目）。 */
    def c3x(kx: Int, ky: Int): SInt =
      (1 to 3).foldLeft(colWin(kx)(U(0, 3 bits))(ky)) { (acc, c) =>
        Mux(c3ci === U(c, 2 bits), colWin(kx)(U(c, 3 bits))(ky), acc)
      }
    /** **条件覆盖**（`dci_mode=0` 时上面 dw 块的逐 lane 直连逐位原样保留 —— 与探针的
      *   `Mux(dci_mode, c3, dw)` 同义，但把选择器摆进"只有 c3 档"的分支里）。
      *   `laneSel = dw_mode || dci_mode`：`dci_mode=1` ⇒ 阵列的逐 lane 门（口名 `dw_mode`）= 1。 */
    when(dci_mode) {
      for (r <- 0 until C_IN) {
        for (j <- 0 until C_IN) {
          arr.x_dw(r)(j) := c3x(j % 3, j / 3)
          arr.w_dw(r)(j) := ws.c3Tile(r)(j)
        }
        arr.x8(r) := c3x(2, 2)
        arr.w8(r) := ws.c3Tile8(r)
      }
      arr.dw_mode := True
    }
    ws.c3_ci := c3ci
    /** DCI 跳拍：`ph === c3_cin` 直接跳到 ph=10（像素相位 9 → `C_in` 拍；`C_in=1` ⇒ 与 1×1 跳拍
      *   同一条 late-override、同一拍形）。`!io.prime` ⇒ 相位复位口的优先级不变（prime 恒赢）。
      *   数据面/出数与后处理一字未动（tap 拍数由 `arr.en` 判据自动跟随；`obs_beats` 自动实测）。 */
    when(inPix && dci_mode && (ph === c3_cin) && !io.prime) { ph := U(10, 4 bits) }
  }
}

/* =====================================================================================
  * ★★ §3.7（2026-10-16）：**部分和通路宽度参数化 `PSW`**（追加在**文件最后一行之后** ——
  *   `UnitExec.scala` 文件尾同一套理由：SpinalHDL 把源码行号编进内部网名（`when_Conv3x3Slice_l####`），
  *   而 `TILING=false` 的三份冻结网表（`gen/UnitExec.v/_w32/_w640`）要求**逐字节不变** ⇒
  *   既有行的行号一个都不能动，新 prose 只能追加。）
  * =====================================================================================
  *
  * `PSW`（bit）是**部分和载入/写回**（`ps_in/ps_out`）与内部累加 `acc_total` 的宽度：
  *   · **缺省 64**（本文件独立例化时 = 历史档，逐字节不变；`SliceGen` 的单切片网表不受影响）；
  *   · `MultiPassUnit` 按自己的 `PSW`（缺省 **32**）显式下发；`TILING=false` 的 `UnitExec` 钉 64；
  *   · `PSW==64` ⇒ 本文件的累加/requant 段**逐字**是改动前的实现（下面四行里的 `if (PSW == 64)` 分支）；
  *   · `PSW<64` ⇒ 同一条**流水恒等式**：把 `A` 看成 `A_PSW` 的符号扩展（`A = AH·2^32 + AL`，
  *     `AH = A>>32`、`AL = A mod 2^32`），仍按 `floor(A·M/2^30) = floor(AL·M/2^30) + AH·M·4` 折算
  *     ⇒ requant 数值**逐位同值**（只是当 `|acc|` 真的超过窄宽度时，回绕会在这里被"看得见"）。
  *
  * 可证界（spec §3.7）：`|acc| ≤ 128·127·576 = 9,363,456 < 2^24` ⇒ 25 bit 有符号够、32 bit 有余量；
  * `tools/run_psbound_ab.sh` 用满幅度激励在 32 bit 上逐字节对冻结果（实测峰值 `|acc| = 9,363,456`），
  * 并在 24 bit（**低于可证界**）上实证必红。
  *
  * 本切片的**其它宽度口径**（`arr` 的 int32 累加器、requant 的 64 位积、`y` 的 int8）**一字未动**。
  * ===================================================================================== */
