import spinal.core._
import spinal.lib._
import spinal.lib.bus.amba4.axi._

/** bypass-exec 的相位 FSM（生成 Verilog 里就是一个 `BypassPhase` 型寄存器）。
  *
  *   IDLE     —— 等 `go`（单拍脉冲语义，与 `UnitExec` / `DescFetch` 同口径）；
  *   RDSTART  —— 把 `DdrMaster.start` 举一拍（mode=RD、src=SRC_ADDR、len=输入字节数）；
  *   RDRUN    —— 边收 RD 流（一拍 = 一个输入列 = C 个通道）边喂单元；单元产出逐拍收进片上输出存储；
  *               「输入喂完（`inCol==inBeats`）且单元吐完（`pixIdx==outPix`）」才离开本态；
  *   WRWAIT   —— 等内部主口彻底回 IDLE（RD 收尾）；
  *   WRSTART  —— 把 `DdrMaster.start` 举一拍（mode=WR、dst=DST_ADDR、len=输出字节数）；
  *   WRRUN    —— 把片上输出存储按读序号顺序喂给 `DdrMaster.wr_*`；
  *   DONE     —— `done` 举一拍，回 IDLE。
  */
object BypassPhase extends SpinalEnum {
  val IDLE, RDSTART, RDRUN, RDBSTART, RDBRUN, WRWAIT, WRSTART, WRRUN, DONE = newElement()
  /** ★★ T-S3a.2b：**空间 tile 循环**的三个相位（只在本层判"走 tile"时进入；见文件头 §T-S3a.2b）：
    *   `TILEGO` —— 一个 tile 的**起点**（闩存本 tile 的几何；1 拍）；
    *   `TILERD` —— 本 tile 的**行跨步窗口读 + 喂单元 + 收输出**（内部子相位 `tRdSt`）；
    *   `TILEWR` —— 本 tile 的**逐 (平面, 输出行) 掩码行写回**（内部子相位 `tWrSt`）。 */
  val TILEGO, TILERD, TILEWR = newElement()
}

/** =====================================================================================
  * C3.10b `BypassExec` —— **旁路算子的 DDR↔单元 流式执行包装**（`MaxPool`/`Resize`/`Add`/`Sigmoid`）
  * =====================================================================================
  *
  * 为什么需要这一层：四个旁路单元（`rtl/MaxPoolUnit.scala` / `ResizeUnit.scala` / `AddUnit.scala` /
  * `SigmoidUnit.scala`）都是**纯流式单元**（`x(C)/x_valid/x_ready` + `y(C)/y_valid`），**没有 DDR 端口**；
  * 而 `LayerSched` 的描述符语义是「本单元把 `SRC_ADDR` 的张量搬到 `DST_ADDR`」。本模块就是这两者之间
  * 的那层适配：**DDR → 单元列流 → DDR**，并把 AXI 主口**复用一个** `DdrMaster`（先 RD、后 WR，
  * 与 `UnitExec` 完全同一套做法：`mode` 位 + 两次串行 `start`）。
  *
  * ---------------------------------- 一拍 = 一个输入列（本模块的全部基础） ----------------------------------
  * `DdrMaster` 的 RD 流一拍就是 **8 B**（`DATA_W/8`），而本模块 `C == 8` ⇒ **一拍正好 = 一个像素的
  * C 个通道**（NHWC：像素的通道在 DDR 上连续）。于是「喂单元」就是把 RD 流**逐拍**交给单元的 `x` 口，
  * 位序与 `FusionBuf`/`UnitExec` 同一套（通道 ci 落 `rd_data[8*ci+7 : 8*ci]`）。
  *   · `rd_ready := 本拍还想喂更多 && 该单元的 x_ready` ⇒ RD 流被单元**反压**（Resize 在输出相位
  *     `x_ready=0` 的那 8W 拍里，RD 流原地停住 —— 这正是"尊重 x_ready"的落实）；
  *   · `x_valid := 本拍还想喂更多 && rd_valid` ⇒ 一拍只吃一次，绝不丢拍/重吃。
  *
  * ---------------------------------- 输出侧：整张输出先落片上，再一次性流出去 ----------------------------------
  * 与 `UnitExec` 同一条纪律（同一个理由）：本模块只有**一个** `DdrMaster` ⇒ RD/WR 两相位在时间上
  * 必须串行；而单元是"边吃边吐"的 ⇒ 输出先按产出序号 `pixIdx` 写进片上 `outMem`（一字 = 一个像素的
  * C 个通道），等输入喂完、单元吐完（`pixIdx == outPix`）再切 WR 相位把整张流出去。
  *   · 输出**顺序**天然是单元的出料顺序 = 输出张量的行主序（NHWC）⇒ WR 流就是 `[y][x][c]`，
  *     与输入同一套布局（`conv_unit_ref`/`bypass_ref` 的流顺序口径）。
  *   · `outMem` 有上电初值 0（`Mem` 无复位；不给初值 ⇒ "没写过就读"是 X，一旦某条路径被跳过就会把 X
  *     写回 DDR）。尺寸 = `WIDTH * IMG_H_MAX`（与 `UnitExec` 同一个口径），`go` 时对账 `outPix <= MAXPIX`。
  *
  * ---------------------------------- 四个算子各不相同的「几何/长度」口径 ----------------------------------
  * 描述符的 `IMG_W/IMG_H` 按 `reports/c3_descriptor_format.md` §4.4 是**输出**张量的几何 ⇒ 输入几何
  * 由算子的语义反推（都在本模块里显式算，**不**依赖 `IN_BYTES` —— 那个字段对 MaxPool/Resize/Add
  * 是 `max(Σ读,写)` 的**上界**，见 §7 开口项 O2）：
  *   · `maxpool`(2x2/s2)：输入 `(2*IMG_W) x (2*IMG_H)`、输出 `IMG_W x IMG_H` ⇒ 输入列数 = `4*outPix`；
  *   · `resize`(x2 最近邻)：输入 `(IMG_W/2) x (IMG_H/2)`、输出 `IMG_W x IMG_H` ⇒ 输入列数 = `outPix/4`；
  *   · `add` / `sigmoid`：输入 `IMG_W x IMG_H`、输出同形状 ⇒ 输入列数 = `outPix`。
  * **行宽（★ T-S1：运行期，不再是编译期钉死）**：`MaxPoolUnit`/`ResizeUnit` 是**按行宽数列**的
  * （`MaxPoolUnit` 的列对、`ResizeUnit` 的输入行对）⇒ 本模块在 `go` 那一刻对账**运行期行宽**
  * `rowW = inW32`（= 输入宽）落在 `1 ≤ rowW ≤ W_MAX`（带行宽状态的两个单元；`W_MAX` = 展开期
  * `WIDTH` = **分配**口径）、且 `maxpool` 的行宽为**偶数**；两个逐点算子（`add`/`sigmoid`，零几何状态）
  * 只要求 `rowW ≥ 1`（真表 `Sigmoid` 头 `IMG_W=6400` 就是这么过的）。不合（或 `outPix > MAXPIX`、
  * 或 `rdLen/wrLen` 不是 32 的倍数）⇒ **响亮 `err` 且零搬运**（与 `UnitExec` 的 `QUANT_SHIFT` 对账同形：
  * 不发 `start` ⇒ 一个 AR/AW 都不发）。`rowW == WIDTH` ⇒ 与改动前**逐字节同形**。
  * 另：`resize` 要求 `IMG_W/IMG_H` 均为偶数（否则 `>>1` 会静默错位）⇒ 同一条对账里查。
  *
  * ---------------------------------- ★ `Add` 的两路操作数（= 描述符开口项 O1 的处置） ----------------------------------
  * `AddUnit` 是**双输入**单元（`x_a`/`x_b` 各一路 valid、**共享**一条 `x_ready`、**不缓存任何一路**
  * ⇒ 要求两路 valid **同拍**），而冻结的描述符格式（C3.2）只有**一个** `SRC_ADDR`
  * （`reports/c3_descriptor_format.md` §7 开口项 O1）。本模块**不发明格式字段**，而是把第二路源
  * 表达成 **`SRC_ADDR` 那个 RD 流内部的偏移**：
  *     DDR 上按**列交织**存放两路 —— 第 i 列 = `A 的 C 个通道` 紧跟 `B 的 C 个通道`
  *     （地址 `SRC_ADDR + i*2C + [0..C-1]` = A、`+ [C..2C-1]` = B）。
  * 这与 `tools/bypass_ref.py` 的 `interleave_add()` 是**同一个装置侧约定**（也解释了为什么 `IN_BYTES`
  * 对 Add 是 `2*C*W*H`）。包装侧的落实只有**一级 1 拍缓冲**：偶拍（`inCol(0)==0`）把 A 列锁进 `aReg`，
  * 奇拍把 `x_a := aReg`（上一拍锁下的 A）、`x_b := 本拍 RD 字节`，两路 valid 同拍举起 ⇒ `AddUnit` 当拍出数。
  *   · 两路**速率天然相等**（同一条 RD 流交织），所以"速率对齐"就是这一级寄存器，**不需要** FIFO；
  *   · `x_ready ≡ 1`（`AddUnit` 纯组合）⇒ 偶拍也必须照收（否则 A 会丢）⇒ 本模块对 Add 的 `rd_ready` 恒 1。
  * ⇒ 这是**约定**（"第二路 = 同一 RD 流里 `+C` 字节那个偏移"），不是新字段；真要进 C4/M2 的转换器时
  *   仍须走 spec 修订（O1 保持开口）。
  *
  * ---------------------------------- 与 `LayerSched` 的接口 ----------------------------------
  * `LayerSched` 在 `TYPE ∈ {0x10,0x11,0x13,0x14}` 时按"一个单元一次 `go`"的纪律起本模块，
  * 并等 `done`（单拍）/ `err`（单拍）；`busy` 覆盖整段在途相位（含 `DdrMaster` 收尾）⇒ `busy==0`
  * 时下一次 `go` 必被受理。AXI 主口由 `LayerSched` 与 `DescFetch`/`UnitExec` **按时序相位复用**
  * （取表相位 / conv 相位 / 旁路相位三者在时间上互斥）。
  *
  * ★ 可重入性（与 `UnitExec` 的 per-run 复位同一件事）：本模块自己的 per-run 寄存器（`inCol`/`pixIdx`/`ri`/
  *   `mMode/mSrc/mDst/mLen`）在 `go` 被受理那一拍**全部清回上电值**。四个旁路单元**没有** `prime` 口
  *   （它们不是本任务的改动范围）—— 但它们**跑满一整张图（输入列数 = `WIDTH * inH`，`inH` 为偶数）之后
  *   内部相位恰好回到上电值**（列指针回绕到 0、行奇偶翻转偶数次 ⇒ 回到初始相位；`accRow`/`rb`/`regA`
  *   的值都被本次运行写过之后才被读）⇒ 同实例连跑多张图的数值与第一张**逐字节相同**。
  *   ⚠ 残留：若上一张图**中途被 err 打断**，这些单元的相位会停在中间（没有复位口可清）⇒ 后续复跑
  *     同一算子会错。本片（S4 正向用例）不发生；记为开口项（真正需要时给四个单元加 additive `prime` 口，
  *     与 `Conv3x3Slice` 同一手法）。
  *
  * ---------------------------------- ★★ C3.18 R4：喂料长度「寄存 + 粘滞末端」（ResizeUnit 的 CE 锥） ----------------------------------
  * 板级实测（R3，`cpu_clk` 100 MHz）**唯一一组** Setup 违例的**终点**是 ResizeUnit 的两个行缓冲的时钟使能：
  *   `u_soc/u_npu/layerSched_1/bypassExec_1/rz/rb_1_28_{0,3,5}[7]/opit_0/CE`，
  *   10 级逻辑 / 4.007 ns 逻辑 + 5.782 ns 布线 / slack −0.435（`report_timing/yeshen_mini_board_top.rtr`）；
  *   686 个违例端点里的**全部前 3 名**都是这一族（`ResizeUnit` 的 `rb` 是 4096 个 FF ⇒ 该族的端点数其实远大于 3）。
  *
  * 那 10 级**逐级**是（`.rtr` 的元素清单）：
  *   1. `layerSched_1/N290_3_muxf7`（描述符字读出 mux，扇出 102）
  *   2. `bypassExec_1/inH32_6[25]_1_muxf7`（`Mux(isRz, imgH>>1, imgH)` 之类）
  *   3. `bypassExec_1/N408/gopapm` → `inCols`（**一个 APM 乘法器**：`inW32 * inH32`）
  *   4. `bypassExec_1/N468[4]` → `inBeats`（`Mux(isAdd, inCols+inCols, inCols)`）
  *   5..8. `bypassExec_1/N507.lt_{3,7,11,15}`（**32 位比较器 `inCol < inBeats` 的进位链**）
  *   9..10. `rz/N3541_2` → `rz/N5687`（ResizeUnit 内部把 `x_valid` 与 `!half`/列 one-hot 合起来）
  * ⇒ **10 级里 8 级在 `BypassExec`、2 级在 `ResizeUnit`**；`ResizeUnit` 内部那 2 级已经是
  *   「`x_valid` ∧ 本地相位」的 1~2 个 LUT6，本身**没有**可摘的东西（见下 §"为什么没动 ResizeUnit"）。
  *   根因是**喂料长度 bookkeeping 被组合地摆在运行期**：`inBeats` 是描述符的乘法结果，而
  *   `inCol < inBeats` 要每拍评一次，于是「描述符寄存器 → 乘法 → 比较 → `x_valid` → `CE`」全在一条锥上。
  *
  * **本片的改动（两件事，都在本模块）**：
  *   (1) **长度几何寄存**：`inBeats`（`inBeatsR`，锁存**原值**，不带减法器）与 `outPix`（`outPixR`）
  *       在 `RDSTART` **与 `mSrc/mDst/mLen` 同一拍**锁存，运行期（`RDRUN/WRRUN`）只用寄存器副本
  *       ⇒ 乘法器与描述符 mux 从运行锥里彻底消失。**依据与既有的 `mLen := rdLen` 完全同源**：
  *       `LayerSched` 在整段运行期间把该项描述符组合地举在 `io.desc` 上（`descFetch.io.words`
  *       在取表相位结束后不再改），`RDSTART` 那一拍 `io.desc` 必须合法 —— 否则连 `mSrc/mLen`
  *       都是错的（既有契约，非新增假设）。捕捉路径 = 「mux → 乘法 → 寄存器」（一拍内，无减法器）。
  *   (2) **喂料末端粘滞位**：`moreIn = !inTail`，其中 `inTail` 是「`inCol` 已追平 `inBeats`」的
  *       **寄存副本**（见下证明）⇒ `x_valid`（⇒ 行缓冲 `CE`）锥里**不再有 32 位比较器**。
  *       置位条件写在**两个寄存器之间**：`feedBeat && (inCol + 1 == inBeatsR)`（自增器本来就有）。
  *
  * **等价性证明（`inTail ⇔ inCol == inBeats`，逐拍）**：`inCol` 只在 `feedBeat = rd_valid && rd_ready`
  *   这一拍 `+1`，而 `rd_ready = inFeed && unitReady`、`inFeed = inRdRun && !inTail`：
  *     · 起点：`runStart`（`IDLE && go && geomOk`）同一拍把 `inCol := 0`、`inTail := False`；
  *       `geomOk` 要求 `rdLen ≠ 0` ⇒ `inBeats ≥ 1` ⇒ 起点 `inCol(=0) < inBeats`、`inTail = 0` 一致；
  *     · 归纳：只要 `inCol < inBeats` 且 `inTail = 0`，就允许接受拍 ⇒ `inCol` 只能一步步走到 `inBeats`；
  *       把 `inCol` 从 `inBeats-1` 推到 `inBeats` 的那一拍正好命中 `inCol + 1 == inBeatsR` ⇒ 置位；
  *     · 置位后 `inFeed = 0` ⇒ `rd_ready = 0` ⇒ 不再接受拍 ⇒ `inCol` 永久停在 `inBeats`（不会越过）。
  *   ⇒ `inTail` 与 `inCol == inBeats` 在**每一拍**都相同。因此 `moreIn`、`drained`、`wr_valid` 的
  *   取值序列逐位不变 ⇒ **`x_valid` 的逐拍波形不变**（这是关键）⇒ `ResizeUnit` 内部相位
  *   （`stOut`/`col`/`half`/`oc`/`orow`）推进的**时序一字不改**：2W 收 / 8W 出的节奏、每列一拍的
  *   `x_ready` 占空、以及整段搬运的拍数都不变（闸门 `run_bypass_ab.sh`（Resize 逐点 + 两个相位突变体）、
  *   `run_sched_ab.sh`（含 resize 旁路链）、`run_nputop_sched_ab.sh`（整 NPU 调度的 resize 档）
  *   即为此提供逐字节证据；任何"多吃一拍/少喂一拍"都会当场改变输出与 `rd_bytes/wr_bytes`）。
  *
  * **为什么没动 `ResizeUnit`**（三个候选都试过论证，只有第三个是真收益、但代价是改变契约）：
  *   · 「CE 浅 + 数据 mux」（把 `x_valid` 从 `CE` 挪到 `D = Mux(beat, x, Q)`）：**不降深度**
  *     （同一锥只是终点从 `CE` 变 `D`），却把 `x_valid` 的扇出从「每列 1 个合并后的 LUT」放大到
  *     「每 (列,通道) 一个 mux LUT」≈ 4 倍 —— 本坑是**布线**主导（5.782 ns / 59%），只会更差；
  *   · 「`!stOut` 从 CE 里去掉」：**不合法** —— 输出相位里上游仍可能有 `rd_valid` 打进来（`rd_ready=0`
  *     但这不阻止 `x_valid` 举一拍），去掉就会写坏行缓冲；
  *   · 「`x_valid` 进 rz 前加一级寄存 / 写口加流水」：会**改变 `ResizeUnit` 的相位/吞吐契约**
  *     （2W/8W 的节奏与"进料 20%"占空被 C3.8/C3.10 依赖）⇒ 本片明确不做。
  *   ⇒ `ResizeUnit` 的源文件**一字未改**；要根治它就得改"喂料长度怎么算"这件事，而那在本模块。
  *
  * ---------------------------------- ★★ C4b-B4：消费者侧的 strided read（conv 平面 ↔ 旁路 NHWC） ---------
  * 冻结契约（`reports/c4b_input_layout.md` §1）：DDR 上激活张量是**通道平面（NCHW）**
  *   `off(c,p) = c*HW + p`（`HW` = 本张量的像素数、`p = y*W + x`）；而四个旁路单元的**自然流形状**是
  *   NHWC（一拍一列 = 一个像素的 C 个通道）。真网里 `conv → maxpool` 的相邻对正是"生产者写平面、
  *   消费者按列流读"——本片把**消费侧那一步补上**：
  *     · `src_planar = 1`：RD 通路**按步长 `HW` 取数**（`SRC + c*HW + p`）⇒ 把平面张量 gather 成
  *       NHWC 列流（与 B3 在 `UnitExec` 宽通路里做的 gather **同一套 idiom**：32 像素一组、
  *       每平面一笔 32 B RD、落一个转置缓冲、再逐列吐出）；
  *     · `dst_planar = 1`：WR 通路把单元吐出的列流**散射**成平面（平面 `c` 的字节 = 第 `c` 道）
  *       —— 这样它的**下一个消费者（conv 的宽通路）**读到的仍是冻结的平面布局。
  * 开关的投递：**每层两位**，由 `LayerSched` 从**既有权重信箱的区域 7 道 2**（`WGT_ADDR[23:20]=0x7`、
  *   `WGT_ADDR[15:8]=LAYER_ID`、`WGT_ADDR[1:0]=2`）按 `LAYER_ID` 索引后送来（与 B2 的
  *   `M/z_pad/bias_adj`、B3 的 `XDMA_EN` **同一手法**）⇒ **不改描述符格式、不改寄存器契约**。
  *   两位的**上电值都是 0** ⇒ 默认行为 = C3/C4a 的"线性 NHWC"⇒ **既有闸门逐字节不变**
  *   （`conv→conv` 与 `bypass→bypass` 也逐字节不变：前者从不进本模块，后者两位都是 0）。
  *
  * 几何前提（`go` 那一刻**响亮**对账，不合 ⇒ `err` 一拍 + 零搬运；绝不静默读错地址）：
  *   · `inCols % 32 == 0`（读侧 32 像素一组；`inCols` = 输入张量的像素数）、
  *     `outPix % 32 == 0`（写侧同）、且**不是 Add**（Add 是两路列交织、两路布局可不同 ⇒ 本代
  *     不支持，响亮 err；见文件头 O1 一节）。
  * 只搬字节：四个单元的端口/数值通路、`outMem`"一字 = 一个像素的 C 个通道"的口径**一字未改**
  *   （转置缓冲 `pgBuf`/`woBuf` 只做字节重排，**没有第二条算术路径**）。
  *
  * ============================================================================================
  * ★★ T-S3a（2026-10-14）**旁路 tiling 的数据流契约**（本片 T-S3a.1 **只冻契约**：
  *   ⚠ **tile 的 FSM / 行跨步窗口读 / 掩码写回都还没实现**（落地在 T-S3a.2）——
  *   本文件除了本节注释**没有**任何行为改动；既有（非 tiled）路径逐字节同形。
  *   spec = `docs/superpowers/specs/2026-10-14-y1-frame-runnable-design.md` §3.1 / §3.1.1；
  *   plan = `docs/superpowers/plans/2026-10-14-y1-frame-runnable.md` Task T-S3a.1。）
  *
  * 契约正文（**逐字冻结**，后续所有任务引用这一份、不另立第三条口径）：
  *
  * 旁路 tiling（T-S3a）契约：
  * · tile 网格：输出 tile 32×32（tNtx=ceil(IMG_W/32)、tNty=ceil(IMG_H/32)；末 tile 取余）；
  *   · pool ：**输出** tile 宽再切 = WIDTH/2（=16），高 32 ⇒ 每 tile 输入 32(列)×64(行)；outPix=512 ≤ MAXPIX=1088；
  *   · resize/add/sigmoid：输出 tile 32×32 ⇒ resize 输入 16×16 / add,sigmoid 输入 == 输出；outPix=1024 ≤ 1088。
  * · 输入窗口（**无 halo**，逐算子）：pool 行 [2·oy0,2·oy1)、列 [2·ox0,2·ox1)；resize 行 [⌊oy0/2⌋,⌊oy1/2⌋)、
  *   列 [⌊ox0/2⌋,⌊ox1/2⌋)；add/sigmoid == 输出窗口。**恒偶对齐**（resize 的 oy0/ox0 偶由既有 isRz 要求保证）。
  * · 读：**按输入行跨步**发 32 B 对齐窗口读（band 基址 &~31；与 UnitExec gather 同一 idiom）。
  * · 写：**每输出行一笔 32 B 对齐 + wstrb 掩码**（DdrMaster.io.wstrb；与宽路 tile WR 同一 idiom）。
  * · 收料：tile 内按局部序 (q-1)·tw+(j-1) 存 outMem[0..outPixTile)；写回段起点 = DST + ((oy0+q)·IMG_W+ox0)·C。
  * · 兼容（**运行期二选一**）：outPix(整层) ≤ MAXPIX(1088) ∧ rowW(整层) ≤ WIDTH ∧ 对齐前提满足 ⇒ **走原整层路径**；
  *   否则走 tile。原路径**行为逐字节同形**（既有闸门零改动）。
  * · **行宽对账口径搬到 tile**：tile 内 rowW = tile 输入列数（pool ≤ 32、resize ≤ 16、逐点 ≤ 32）⇒ 恒 ≤ WIDTH；
  *   MaxPool 的"行宽偶数"改判 **tile 输入列数**（pool 输入列 = 2·tw_out = 32 ⇒ 偶）；outPix 改判 **tile 输出像素**。
  *
  * ⚠ **`outMem` 的尺寸一字不改**（`WIDTH·IMG_H_MAX` 字；本片 `34·32 = 1088`）：板级 `dev_map`
  *   DRM 已到 **375.5 / 415 = 90.5%**（只剩 ~39 块）⇒ tile **必须**复用既有 `outMem`
  *   （tile 输出 ≤ 1024 ≤ `MAXPIX`），**0 新增宽存储**（spec §5-R1）。加宽 `outMem` = 直接顶爆器件的
  *   `Adm-4088`（DRM 不足 ⇒ 掉 LUTRAM），这条是承重约束，不是性能优化。
  *
  * ★ T-S3a.1 **实测观察（给 T-S3a.2 / T-S3a.3 的开口项，不是本契约的一部分）**：
  *   真表 `MaxPool_5`（`gen/desc.bin[3]`）的描述符是 `C_IN = C_OUT = 16`（`IMG_W=IMG_H=160`），
  *   而本模块 `C = 8`（= `DdrMaster` 一拍字节数 = 一拍一个像素的 8 个通道）⇒ `geomOk` 里的
  *   `dw.cIn === C ∧ dw.cOut === C` 这两条**先于** `outPix ≤ MAXPIX` / `rowWOk` 就把 `go` 拦下
  *   （`go` 拍 `err`、零搬运；闸门 `tools/run_bypass_tile_ab.sh` 的 `JUDGE-RED` 即此）。
  *   上面那份 tile 契约只搬走了 `rowW` / `outPix` 两条口径，**没有**动 `cIn/cOut`，也**没有**
  *   给出"通道块（`C_in/8` 趟）"这条口径（真表旁路层有 16ch / 64ch）；
  *   而且契约里写回段起点用的 `·C`（=8）只在 `C_in == C == 8` 时才是"每像素字节数"。
  *   ⇒ 16/64 通道的旁路层要真的跑通，T-S3a.2 必须**另外**解决通道维度（本片不动，仅记账）。
  *
  * ============================================================================================
  * ★★ T-S3a.2a（2026-10-14）**通道分块**（`cIn/C` 趟；本片只做 `C_in ∈ {16, 64}` 的 maxpool/resize，
  *   即 `cIn/C ∈ {2, 8}` —— `C_in = 1` 的 `Sigmoid_*` 是另一套机制（T-S3a.2c）、空间 tiling 是 T-S3a.2b）。
  * ============================================================================================
  * 缺口（实测，`gen/desc.bin` 解码）：真表旁路层 `C_IN = C_OUT ∈ {16, 64, 1}`
  *   （`MaxPool_5`=16；`MaxPool_18/25/32`+`Resize_43/49`=64；`Sigmoid_*`=1），
  *   而改动前 `geomOk` 要求 `dw.cIn === C ∧ dw.cOut === C`（`C = 8`）⇒ 真帧旁路层在**通道**这一维就 `err`。
  *
  * **口径**（`cIn/C` 趟，逐趟跑一遍**既有的整层相位**）：
  *   · 判据换成**运行期**：`cIn == cOut` ∧ `cIn % C == 0` ∧ `cIn ≠ 0`（低 3 位判整除 ⇒ 无除法器）；
  *   · 块数 `nBlk = cIn/C`（`16 ⇒ 2`、`64 ⇒ 8`、`8 ⇒ 1`）；块 `b` 跑的是**通道 `8b .. 8b+7`**；
  *   · 四个算子**通道独立**（maxpool/resize 的空间窗口在 `HW` 平面内、add/sigmoid 逐点）
  *     ⇒ 分块**不引入跨通道状态**、**不新增存储**（`outMem` 尺寸一字不改，逐块复用：每块的输出
  *     像素数 = `outPix` ≤ `MAXPIX`，与整层口径同一个 `outPix`）。
  *   · 通道独立性也保证了单元**相位逐块复位**：一个块喂满 `inW·inH` 拍后，`MaxPoolUnit` 的
  *     `col/rowPar`（`inH` 偶数次翻转）与 `ResizeUnit` 的 `stOut/col/half/oc/orow` 都回到上电值
  *     （与文件头 §"可重入性"同一条依据）⇒ 块间不需要 prime。
  *
  * **地址推导**（块 `b`、平面 `p ∈ [0,8)`；两个偏移都由 32 位**加法器**逐块累加，网表里没有乘法器）：
  *   · 源（NCHW 平面布局，`off(c) = c·HW`）：块 `b` 的平面 `p` = `SRC + (8b+p)·inCols`；
  *     实现 = `pgPlane0 := SRC + blkSrcR`（`blkSrcR = b·8·inCols`），平面内仍用既有的 `+= inColsR` 递推；
  *   · 目标（同布局，`off(c) = c·outPix`）：块 `b` 的平面 `p` = `DST + (8b+p)·outPix`；
  *     实现 = `mDst := DST + blkDstR + p·outPix`（`blkDstR = b·8·outPix`）。
  *   ⇒ 输出张量在 DDR 上仍是**冻结的通道平面布局**（下一个消费者 = conv 宽通路读平面），
  *     通道序与整层一致 ⇒ 块的先后顺序对结果**无影响**。
  *
  * **布局前提**：块的偏移是"通道**平面**"的偏移 ⇒ **多块只用平面通路**（`blkPlanarOk`：
  *   `nBlk == 1 ∨ (src_planar ∧ dst_planar)`）。线性 NHWC 里不存在"某 8 个通道的连续子图"
  *   ⇒ 多块 + 线性 = 同一条**响亮 `err`、零搬运**（绝不静默按错地址读）。
  * **相位前提**：单元的"喂满一张图 ⇒ 相位回上电值"只在**块内输入行数为偶**时成立
  *   （`blkPhaseOk`：`nBlk == 1 ∨ inH 偶`）。`maxpool` 的 `inH = 2·IMG_H` 恒偶；`resize` 的
  *   `inH = IMG_H/2` 只在 `IMG_H ≡ 0 (mod 4)` 时偶 ⇒ 多块 + `resize` + `IMG_H ≡ 2 (mod 4)`
  *   同样**响亮 `err`、零搬运**（本片不给四个单元加 `prime` 口，宁可红、不静默错值）。
  *
  * **等价性（`C_in = C_out = 8` ⇒ 1 块）**：`nBlkR == 1 ⇒ blkNext == False ⇒ blkAdvance ≡ 0`
  *   ⇒ 块推进那一条 `when` 里**每一条赋值都不发生**、`blkSrcR/blkDstR` 恒 0
  *   ⇒ 地址与逐拍波形与改动前**逐字节同形**（证据：既有闸门 `run_bypass_ab.sh`（单元级）、
  *   `run_layoutadapt_ab.sh`（`BypassExec` 平面档 40×40/C=8）零改动全绿）。
  *
  * ⚠ **开口项（本片**不**做，仅记账）**：真表还有 `Add_44`/`Add_50`（`C_IN = C_OUT = 64`、`src2k = 1`）
  *   —— 它们走 E1 的**两趟读**，而 B 趟（`io.src2`）走的是线性通路（没有 gather）⇒ 要支持就得给 B 趟
  *   也配一套平面 gather。本片让它们**继续响亮 `err`**（零搬运），不静默读错；要覆盖须另立任务。
  *
  * ============================================================================================
  * ★★ T-S3a.2b（2026-10-15）**空间 tile 循环落地**（契约 = 上面 T-S3a.1 那一节，**逐字未改**）
  * ============================================================================================
  * 本片把 T-S3a.1 冻结的 tile 契约**实现**进 FSM，并把 T-S3a.2a 的**通道分块**套在外面
  * （块 = 外层，tile 网格 = 内层）：
  *
  * · **运行期二选一**（契约最后一条）：`wholeOk`（= 既有 `geomOk ∧ planarOk ∧ blkPlanarOk ∧ blkPhaseOk`）
  *   成立 ⇒ **走原整层路径**（一个字节、一条相位序列都不变；既有闸门零改动）；否则若 `tileOk`
  *   成立 ⇒ 走 tile；两者都不成立 ⇒ 同一条**响亮 `err` + 零搬运**。`tilingR` 在 `go` 那一刻闩存。
  * · **tile 网格**：输出 tile `TILE_W × TILE_H`（`TILE_W = min(32, WIDTH)`、`TILE_H` = `min(32, IMG_H_MAX)`
  *   向下取 4 的倍数）；`tNtx = ceil(IMG_W/tileW)`、`tNty = ceil(IMG_H/TILE_H)`，末 tile 取余。
  *   `maxpool` 的 tile 宽再切到 `TWP = min(TILE_W, (WIDTH/4)·2)`（⇒ 输入行宽 `2·TWP ≤ WIDTH`）。
  * · **输入窗口（无 halo）**：`pool` 行 `[2·oy0, 2·oy1)`、列 `[2·ox0, 2·ox1)`；`resize` 行/列各 `>>1`。
  *   窗口的行/列数 = 单元的运行期 `rowW`（pool `2·tw`、resize `tw/2`）⇒ `rowW` 每 tile 重新闩存。
  * · **读**：**逐输入行**发 32 B 对齐的窗口读 —— 每个 band 对 **8 个平面各一笔 32 B**（4 拍）灌进既有
  *   `pgBuf`（与 C4b-B4 的 gather **同一张缓冲、同一套转置下标**），再按"本 band 内区间 `[tDk, tDjE)`"
  *   逐列 drain 喂单元。窗口 ≤ 32 像素（pool 输入列 ≤ 32、resize ≤ 16）⇒ 每行至多 3 个 band
  *   （`tBand` 2 位，`tDjE = min(32, tOff + n − 32·band)`）。地址只用**加法**：band 基址
  *   `= (planeBase + rowPix) & ~31`，平面间 `+= inColsR`、行间 `+= inW`、y 带 `+= A·inW`（常量乘）。
  *   ⚠ **以上是 T-S3a.2b 的原始口径**；★★ **T-S3e 把"共享 band"换成"每平面各记 `(chunk 序, band 内
  *   下标)`"（见 §T-S3e）⇒ `tBand/tDjE/tDkC/tBandBase/tOffC` 这套共享量已不在网表里**。
  * · **写**：**每 (平面, 输出行) 一笔** `32 B 对齐 + wstrb 掩码` burst（`DdrMaster.io.wstrb`；与 UnitExec
  *   宽路 tile WR **同一 idiom**）：段 = tile 的 `tTw` 个字节，起点 `DST + blkDstR + p·outPix + q·IMG_W + ox0`；
  *   段内字节 = `outMem[q·tw + j]` 的第 `p` 道。`wstrb` 把段外字节掩掉 ⇒ `outPix % 32 ≠ 0` 的层
  *   （真表 `MaxPool_32` 20×20：`outPix = 400`）也能写回去。
  * · **复用既有 `outMem`**（tile 输出 = `tw·th ≤ 1024 ≤ MAXPIX`）：**0 新增宽存储**（spec §5-R1）。
  * · **单元相位**：tile 的窗口是同一趟运行的**连续子流** ⇒ 单元内部相位跨 tile **连续**（不需要 prime）；
  *   块边界上 `blkPhaseOk`（`nBlk == 1 ∨ inH 偶`）照旧保证相位回上电值（本片不新增相位前提）。
  *
  * ⚠ **本片的两条口径边界**（都是"宁可红、不静默"，不是静默降级）：
  *   (1) **tile 只做 `maxpool` / `resize`**（`tileOpOk`）—— 真表里需要 tile 的大层正是这两类；
  *       `add`/`sigmoid` 的大几何归 T-S3a.2c（`C_in = 1` 逐点折）与 T-S3a.2d（`Add` 的 `src2k` 平面趟），
  *       本片让它们**继续响亮 `err`**（原路径能过的小层不受影响）。
  *       ★★ **T-S3a.2c 已落地 `C_in=1` 的逐点折**（见文件头 §T-S3a.2c：`Sigmoid_*` 走线性折，不再 err）；
  *       ★★ **T-S3a.2d 已落地 `Add` 的 `src2k` 平面趟**（见文件头 §T-S3a.2d：`tileOpOk` 放
  *       `Add ∧ addTwoSrc` + `tPass` 两趟；`planarOk` **一字未改** ⇒ 布局模式下的 `Add` 只走 tile）。
  *   (2) **tile 要求"平面步长 32 B 对齐"**（`inCols % 32 == 0`）—— band 读的 8 个平面**共用同一个
  *       `tOff`**（同一次转置）；真表 `Resize_43`（输出 40×40 ⇒ 输入 20×20、`inCols = 400`）**不满足**
  *       ⇒ 它**继续响亮 `err`**（原计划：要覆盖须给 8 个平面各记自己的 `(bandBase, idx)`）。
  *       ★★ **T-S3e 已落地这条修法**（见文件头 §T-S3e）：`tileAliOk` 的 `inCols % 32 == 0` 前提**已去**，
  *       `Resize_43` 走 tile、逐字节 == 冻结参考（闸门 `run_bypass_tile_ab.sh` 的 `c64_resize_40x40`）。
  *
  * ============================================================================================
  * ★★ T-S3a.2c（2026-10-15）**`C_in = C_out = 1` 逐点算子的布局折**（真表 `Sigmoid_85..125`）
  * ============================================================================================
  * 缺口：真表 `desc[61..66]` 是 6 个 `Sigmoid` 头（`IMG_W ∈ {6400,1600,400}`、`IMG_H = 1`、
  *   `C_IN = C_OUT = 1`）⇒ T-S3a.2a 的 `cBlkOk`（`cIn % 8 == 0`）把它们**响亮 err**
  *   （`tools/run_bypass_cblk_ab.sh` 的 `fold_sigmoid_*` 先红档即此）。
  *
  * 口径 = **布局折**（`foldPt`）：`Sigmoid` **逐点**（一拍一列、无几何状态、`x_ready ≡ 1`）⇒
  *   把 DDR 上**连续的 8 个元素**当**一拍**（= 8 个 lane 各查一次表）——逐元素、**保序**、
  *   **数值口径一字不动**（`SigmoidUnit` 本来就是 8 个独立查表口）。有效像素 = `W/8`：
  *   `6400 ⇒ 800`、`1600 ⇒ 200`、`400 ⇒ 50`（`outPix ≤ MAXPIX` 因此成立）。
  *
  * 布局 = **线性（非平面）**：`C_in = 1` 时"通道平面"只有 1 个平面 ⇒ 线性 NHWC 与 NCHW 平面
  *   **逐字节相同**（`off(0) = 0`）⇒ 折档**强制线性**（`srcPlEff/dstPlEff = io.*_planar ∧ ¬foldPt`）。
  *   为什么不走平面 gather：平面通路的对齐前提 `inCols%32==0 ∧ outPix%32==0` 在折档上
  *   `800%32==0` 但 `200%32==8`、`50%32==18` ⇒ **平面通路装不下 1600/400 两档**；线性无此前提。
  *
  * ★ 传输长度必须 **32 B 对齐**（`DdrMaster` 的 P3）：`len = 有效像素×8` ⇒ 有效像素须是 4 的倍数。
  *   真表 `Sigmoid_400`（`W=400`）折 50 像素 ⇒ 上取整到 **52**（`fpix`）；多出的 2 个填充像素
  *   读到的是张量之后的字节（真表那 16 B 正是 `IN_BYTES=416` 的填充区），**写回时被 `wstrb` 掩掉**
  *   （`ri ≥ outPixXR`）⇒ 写入的有效字节数恰为 `W`、邻居一个字节不动。`W=1600/6400` 无掩码。
  *
  * ★ `foldPt` 只对**逐点**算子成立：`maxpool`/`resize` 是空间窗口（没有这种折）⇒ 继续响亮 err；
  *   `add` 的两路在 `SRC_ADDR` 流里**按列交织**（折会把 A/B 混进同一拍、非 lane 对齐）⇒ 只接受
  *   **E1 两趟读**（`addTwoSrc`：A/B 各一条独立线性流）；其余 `add`+`C_in=1` 继续响亮 err。
  *   `nBlk` 折档恒 **1**（`cIn=1`）、`geomOk` 走**有效**几何 ⇒ `wholeOk` 成立、`tileOk` 恒假。
  *   ★ 等价性：`foldPt = 0`（全部既有 C=8/16/64 / tile 层）⇒ 每个有效量都与改动前**逐位相同**
  *   ⇒ 既有闸门（`run_bypass_ab.sh` / `run_bypass_cblk_ab.sh` / `run_bypass_tile_ab.sh` /
  *   `run_sched_ab.sh` / `run_nputop_sched_ab.sh`）零改动全绿。
  *
  * ============================================================================================
  * ★★ T-S3a.2d（2026-10-15）**`Add` 的第二路源（E1 `src2k`）在多块 + 平面 + tile 下的落地**
  * ============================================================================================
  * 缺口（实测）：真表 `Add_44`（`IMG 40×40`）/ `Add_50`（`80×80`）都是 `C_IN = C_OUT = 64`、`src2k = 1`
  *   （第二路源 = 表序上一行的 `DST_ADDR`，见 E1 契约与 `LayerSched` 的 `src2Addr`）。在 2a/2b/2c 之后
  *   它们仍**响亮 `err`**，两条独立的闸门各自拦下它们：
  *     · **空间维**：`outPix = 1600 / 6400 > MAXPIX(1088)` ⇒ 必须走 tile，而 `tileOpOk` 只放 `maxpool/resize`；
  *     · **布局维**：多块（`cIn/8 = 8`）要求**平面通路**（`blkPlanarOk`），而 `planarOk` 在布局模式下
  *       **禁用 `Add`** —— 因为 E1 的 **B 趟**（`io.src2`）走的是**线性**通路、**没有 gather**
  *       （`inRdPh` 只含 `RDSTART/RDRUN` ⇒ B 趟的主口入参从来不是"逐平面 32 B"）。
  *
  * **口径**（第二路源享有与第一路源**同一套**行跨步平面 gather + 同一套通道块偏移）：
  *   · **B 源的平面 0 基址** = `io.src2 + blkSrcR`（`blkSrcR = blk·8·inCols`，与 A 源**同一个**偏移累加器）；
  *     平面 `8·blk + c` 落在 `src2 + (8·blk+c)·inCols + …` ⇒ B 侧布局与 A 侧**逐字节同构**（都是冻结的 NCHW 平面）。
  *   · **tile 内两趟**（`tPass`）：`A 趟` 读 `SRC`、把 gather 出的列**原样**落 `outMem[tPixN]`（**不喂单元**）；
  *     `B 趟` 读 `io.src2`、`x_a = outMem[tPixN]`（片上 A）、`x_b = 本拍 B 列` ⇒ 同拍出 `clamp8(A+B)`，
  *     再落回 `outMem[tPixN]`。**为什么两趟**（而不是 A/B 各一张转置缓冲）：DRM 余量只剩 39.5 块
  *     （spec §5-R1）⇒ **0 新增宽存储**，A 就借 `outMem` 当缓冲 —— 与 E1 的整层两趟（A 趟落 `outMem`、
  *     B 趟在原位改成 `A+B`）**同一条纪律**，也与 `twoSrcWrEn` 的读后写（read-old-data）语义同源。
  *   · **tile 几何**：`Add` 是**逐点**算子（输入窗口 == 输出窗口，无 halo）⇒ `tWTc = TWA = TILE_W`、
  *     `tNCC = tTwC`、`tWyC = tOyC`、`tNRC = tThC`、`tXOfs = tTx·TILE_W`、`tYBAdv = inW·TILE_H`
  *     （其余算子一字不动）。tile 输出 ≤ `TILE_W·TILE_H ≤ 1024 ≤ MAXPIX` ⇒ 仍然**复用 `outMem`**。
  *   · **只走 tile**：`tileOpOk` 放 `Add ∧ addTwoSrc`；`planarOk` **一字不动**（仍禁用布局模式下的 `Add`）
  *     ⇒ 布局模式的 `Add` **永远**走 tile（`wholeOk` 恒假）。为什么不做"整层平面两趟"：真表两个 `Add`
  *     都超 `MAXPIX`（tile 是**必须**的），而"整层平面 `Add`"这条路径**没有任何闸门覆盖** ⇒ 宁可让它
  *     走 tile（被 `run_bypass_tile_ab.sh` 逐字节证死），也不留一条未验证的通路。
  *   · **不支持的就响亮 `err`**（零搬运，一条不软化）：布局 + `Add` 但 `src2k == 0`（列交织旧约定，
  *     tile 的"逐平面 32 B"装不下列交织的两路）⇒ `tileOpOk` 为假 ⇒ err。
  *     ★★ **T-S3e 起 `inCols % 32 != 0` 不再 err**（原 `tileAliOk` 已去；per-plane band 见 §T-S3e）。
  *   ★ **等价性**（`addTwoSrc = 0`，即全部既有层与既有闸门）：`tileOpOk` 里 `Add` 那一项恒假
  *     ⇒ `tileAddA/tileAddB` 恒假 ⇒ 上面新增的每一个 `Mux` 都选回**原表达式** ⇒ 逐字节同形；
  *     `tPass` 在非 `Add` 的 tile 上恒 `False`（`TILEGO` 清），`tSrc2R` 只被 latch、从不被选
  *     ⇒ `tSrcE` 的 `Mux(tPass, …)` 恒取 `tSrcR`。
  *
  * ============================================================================================
  * ★★ T-S3e（2026-10-16）**旁路 tile 的 per-plane band**（去 `inCols % 32 == 0` 前提；`Resize_43`）
  * ============================================================================================
  * 缺口（T-S3a.2b 的边界 (2)，spec §3.4）：tile 的行窗口读要求**平面步长 32 B 对齐**（`tileAliOk`：
  *   `inCols % 32 == 0`）—— T-S3a.2b 的 band 读把 8 个平面**共用同一个 band 相位** `tOffC = tPixR[4:0]`
  *   （逐平面只有 `+= inColsR` 的地址推进、相位靠"各平面基址同余"成立）。真表 `Resize_43`（输出
  *   40×40 ⇒ 输入 20×20、`inCols = 400`、`400 % 32 = 16`）**不满足** ⇒ 整层被 `outPix = 1600 >
  *   MAXPIX = 1088` 挡、tile 被 `tileAliOk` 挡 ⇒ **无路**（`go` 拍响亮 err、零搬运）。
  *   根因与 **T-S3b 已从 `UnitExec` 宽路 gather 去掉的前提**是同一个（8 平面 band 边界重合）。
  *
  * 修法（**与 T-S3b 同一套**：每平面各记自己的 `(bandBase, idx)`；spec §3.4/§3.2）：
  *   · **每平面各算自己的相位** `tPhP(p) = (tSrcE + tPixR + p·inCols) mod 32`（只有小加法/常量乘）；
  *   · 本行列序 `tDj`（0..`tRowW`）经 `tIdxP(p) = tPhP(p) + tDj`（7 位）给出平面 p 自己的
  *     `band 内下标 = tIdxP(p)[4:0]` 与**相对本行 chunk0 的 chunk 序** `tIdxP(p)[6:5]`（0..2 ——
  *     窗口 ≤ 32 像素/行 + 相位 ≤ 31 ⇒ `tPhP + tDj ≤ 31 + 63 = 94 < 128`）；
  *   · **读 = 按需逐平面补取**：每个平面各记一个**装载账本** `tLdK(p)`（已装 chunk 序；哨兵 3 = 本行
  *     还没装）—— drain 每列先查"`tIdxP(p)[6:5] != tLdK(p)`"，有 ⇒ 先把这些平面各取一笔
  *     32 B（地址 = 该平面 `(B_p & ~31) + (chunk 序 << 5)`，**恒 32 B 对齐** ⇒ 突发合法；`B_p` 由
  *     累加器 `tAdrR` 逐平面 `+= inColsR` 递推 ⇒ 只有加法）。一笔 32 B 装一个 chunk ⇒ 转置缓冲
  *     `pgBuf` **一字不改**（每平面仍 4 字；换 chunk 直接覆写本平面的 4 字）⇒ **0 新增宽存储**（§5-R1）；
  *   · **写侧一字未动**（写本来就是"每 (平面, 输出行) 一笔 32 B 对齐 + `wstrb` 掩码"⇒ 平面基址
  *     不必对齐）；`outMem` 尺寸、`C`、描述符格式、四个单元的数值通路全部不动。
  *   · 去掉 `tileOk` 里的 `tileAliOk` 一项（`inCols % 32 != 0` 的层不再响亮 err）；其余前提一字未动。
  *
  * **等价性**（`inCols % 32 == 0`，即全部既有形状与既有闸门）：`tPhP(p)` 对 p 全等（相位增量
  *   `p·inCols ≡ 0 (mod 32)`）⇒ `tIdxP(p)` 与旧 `tDj`（"本 band 内字节序"）逐位同义 ⇒ 行首 8 平面
  *   各取一笔 chunk0、跨 band 时逐平面各补一笔 chunk1（相位相同 ⇒ 同一列触发）⇒ 与旧 band 循环
  *   **逐字节同形**。证据：`run_bypass_tile_ab.sh`（8 个既有形状 + 前提档）、`run_bypass_ab.sh`、
  *   `run_bypass_cblk_ab.sh`、`run_sched_ab.sh`、`run_nputop_sched_ab.sh` 零改动全绿。
  *   ★ 负对照（闸门 §7）：把 `tIdxP_k[..]` 退回共享 `tIdxP_0[..]`（= 旧共享相位口径）⇒
  *   `Resize_43`（`400 % 32 = 16`）**必红**、`inCols % 32 == 0` 的 80×80 **逐字节不变**（两侧）。
  *
  * @param C         一拍字节数（= `DdrMaster.DATA_W/8` = 8）：一拍 = 一个像素的 C 个通道。
  * @param WIDTH     单元的**展开期行宽 = 分配上限 `W_MAX`**（四个单元共用；★ T-S1 起**输入**宽度
  *                  由**运行期** `rowW = inW32` 给，只要求 `1 ≤ rowW ≤ W_MAX`（逐点算子还可更大））。
  * @param IMG_H_MAX 片上输出存储的行数上限（`MAXPIX = WIDTH*IMG_H_MAX`），与 `UnitExec` 同口径。
  */
class BypassExec(val C: Int = 8, val WIDTH: Int = 32, val IMG_H_MAX: Int = 16) extends Component {

  val ddrCfg = DdrMasterConfig()
  require(C == ddrCfg.DATA_W / 8, "C 必须等于 DdrMaster 一拍字节数（DATA_W/8=8）")
  require(C == 8, "本任务的旁路单元固定 C=8（与 DdrMaster 一拍 8 B 对齐）")
  require(WIDTH >= 2, "2x2 池化至少要 2 列")
  require(WIDTH % 2 == 0, "MaxPool/Resize 的列/行对要求展开期 WIDTH 为偶数")
  require(IMG_H_MAX >= 1, "片上输出存储至少一行")

  /** 片上输出存储的字数上限（一字 = 一个像素的 C 个通道）= 展开期几何，与 `UnitExec.MAXPIX` 同口径。 */
  val MAXPIX: Int = WIDTH * IMG_H_MAX
  val riW: Int = log2Up(MAXPIX)

  // ===========================================================================
  // ★★ T-S3a.2b：**空间 tile 的编译期几何**（tile 输出 `TILE_W × TILE_H`；见文件头 §T-S3a.2b）
  //   · `TILE_W = min(32, WIDTH)`：tile 输出宽 ≤ 32（`outMem` 一格一字装得下，且 ≤ `MAXPIX` 的半边）；
  //   · `TILE_H` = `min(32, IMG_H_MAX)` 向下取 **4 的倍数**（`resize` 的输出行必须落在全局偶数行对的
  //     格点上：`oy0 = ty·TILE_H` 且 `oy0/2` 必须**偶**⇒ `TILE_H ≡ 0 (mod 4)`）；
  //   · `TWP` = `min(TILE_W, (WIDTH/4)·2)`：pool 的**输出** tile 宽（输入行宽 `2·TWP ≤ WIDTH`，
  //     见 spec §3.1.1 —— `MaxPoolUnit` 按展开期 `WIDTH` 数列/配对，输入行宽**不能**超 `WIDTH`）；
  //   · `TWR` = `min(TILE_W, WIDTH·2)`：resize 的**输出** tile 宽（输入行宽 `TWR/2 ≤ WIDTH`）。
  //   `tileConstOk` 为假 ⇒ tile 路径整体不可用（任何大层仍**响亮 err**，绝不静默降级）。
  // ===========================================================================
  val TILE_W: Int = WIDTH min 32
  val TILE_H: Int = ((IMG_H_MAX min 32) / 4) * 4
  val TWP:    Int = (TILE_W min ((WIDTH / 4) * 2)) max 2
  val TWR:    Int = (TILE_W min (WIDTH * 2)) max 2
  /** ★★ T-S3a.2d：`Add` 的 tile 输出宽（**逐点** ⇒ 输入窗口宽 == 输出宽；`TILE_W·TILE_H ≤ MAXPIX`
    *   已由 `tileConstOk` 钉住 ⇒ 仍然**复用 `outMem`**，0 新增宽存储）。 */
  val TWA:    Int = TILE_W
  /** tile 路径的**编译期**可用性（几何退化 ⇒ 恒假 ⇒ 大层继续走那条响亮 err）。 */
  val tileConstOk: Boolean = (TILE_H >= 4) && (TILE_H <= IMG_H_MAX) && (TILE_H * 4 % 4 == 0) &&
                             (TWR >= 2) && ((TWR / 2) >= 1) && ((TWR / 2) <= WIDTH) &&
                             (TWP >= 2) && ((2 * TWP) <= WIDTH) && ((TILE_W * TILE_H) <= MAXPIX)

  val io = new Bundle {
    // ---- 单元控制（与 `UnitExec` 同形：`go` 单拍、`done`/`err` 单拍）----
    val go   = in  Bool()
    /** 描述符的 8 个 32-bit 小端字（与 `DescFetch`/`UnitExec` 同形）。 */
    val desc = in  Vec (Bits(32 bits), 8)
    // ---- 状态 ----
    val busy = out Bool()          // `go` 起、整段搬运（含主口收尾）走完回 IDLE 之间恒 1
    val done = out Bool()          // 单拍脉冲（整段跑完）
    val err  = out Bool()          // 单拍脉冲（几何/长度对账不过，或透传 DdrMaster.err）
    // ---- ★★ C4b-B4：布局模式（**每层**两位；由 `LayerSched` 从信箱区域 7 道 2 按 `LAYER_ID` 送来）----
    /** 源张量在 DDR 上是**通道平面**（conv 写的形状）⇒ RD 通路按步长 `HW` gather 成 NHWC 列流。 */
    val src_planar = in Bool()
    /** 目标张量要按**通道平面**写（下一个消费者 = conv 的宽通路读平面）⇒ WR 通路散射。 */
    val dst_planar = in Bool()
    /** ★★★ E1（2026-10-13）：`Add` 第二路源的 DDR 地址 = 表序下行 `k` 位那条描述符的 `DST_ADDR`
      *   （`k` = 本条目 `w3[31:16]` 的 `SRC2_K`）。由 `LayerSched` 的**表内 DST 历史**算出后送来
      *   （见 spec §4.6）。`SRC2_K == 0` 时本口**被忽略**（走 C3.7 的列交织旧约定）。 */
    val src2 = in UInt (ddrCfg.ADDR_W bits)
    /** ★ C4b-B4 **观察口**（零逻辑）：本拍喂给单元的列 + 该列**被收下**的指示（供闸门逐列逐通道对账）。 */
    val col_dbg    = out Vec (SInt(8 bits), C)
    val col_dbg_ok = out Bool()
    // ---- 遥测 ----
    val rd_bytes = out UInt (32 bits)
    val wr_bytes = out UInt (32 bits)
    /** 本次运行裁决出的算子（0=maxpool 1=resize 2=add 3=sigmoid）；**仅观察**，不参与数据通路。 */
    val opMode   = out UInt (2 bits)
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
  // 被接方：一个 DdrMaster（RD/WR 串行复用）+ 四个旁路单元（同一份 x 流、按 op 选 y）
  // ---------------------------------------------------------------------------
  val ddrMaster = new DdrMaster(ddrCfg)
  io.ddr <> ddrMaster.io.axi

  val mp = new MaxPoolUnit(C = C, WIDTH = WIDTH)
  val rz = new ResizeUnit (C = C, WIDTH = WIDTH)
  val ad = new AddUnit    (C = C, WIDTH = WIDTH)
  val sg = new SigmoidUnit(C = C, WIDTH = WIDTH)

  // 描述符译码（必须在组件体里一次性建好；见 DescDefs 文件头）。
  val dw = DescWords(io.desc(0), io.desc(1), io.desc(2), io.desc(3),
                     io.desc(4), io.desc(5), io.desc(6), io.desc(7))
  val isPool = dw.tpe === U(DescType.MAXPOOL, 8 bits)
  val isRz   = dw.tpe === U(DescType.RESIZE,  8 bits)
  val isAdd  = dw.tpe === U(DescType.ADD,     8 bits)
  val isSg   = dw.tpe === U(DescType.SIGMOID, 8 bits)
  /** ★★ E1（2026-10-13）：本条目带**表内偏移**第二路源（`Add` 且 `w3[31:16] != 0`，spec §4.6）。
    *   此时走**两趟读**：A 趟从 `SRC_ADDR` 读进片上 `outMem`、B 趟从 `io.src2` 读并与 A 逐列饱和相加
    *   ⇒ 输出 = `clamp8(A + B)`。`SRC2_K == 0`（含所有非 Add）⇒ 本标志为假、行为**逐字节不变**。 */
  val addTwoSrc = isAdd && (dw.src2k =/= U(0, 16 bits))

  // ---------------------------------------------------------------------------
  // 几何 / 长度（全部 32 位域内算；输入几何由算子语义反推，不依赖 IN_BYTES —— 见文件头）
  // ---------------------------------------------------------------------------
  val imgW32 = dw.imgW.resize(32)
  val imgH32 = dw.imgH.resize(32)
  /** 输入宽/高（按算子反推）。`>>1` 而不是 `/2`：常量除 2 用移位表达，网表里没有除法器。 */
  val inW32  = Mux(isPool, imgW32 + imgW32, Mux(isRz, imgW32 >> 1, imgW32))
  val inH32  = Mux(isPool, imgH32 + imgH32, Mux(isRz, imgH32 >> 1, imgH32))

  // ===========================================================================================
  // ★★ T-S3a.2c（2026-10-15）：`C_in = C_out = 1` 的**逐点**算子（真表 `Sigmoid_85..125`：
  //   `H = 1`、`W ∈ {400, 1600, 6400}`）—— **布局折**（8 个连续元素 = 一拍 ⇒ `C_eff = 8`）。
  // ===========================================================================================
  //   缺口（`gen/desc.bin` 解码）：这 6 个 `Sigmoid` 头是 `C_IN = C_OUT = 1` ⇒ T-S3a.2a 的
  //     `cBlkOk`（`cIn % 8 == 0`）把它们**响亮 err**（`run_bypass_cblk_ab.sh` 的先红证据即此）。
  //   口径：`Sigmoid` **逐点**（一拍一列、无行/列结构、`x_ready ≡ 1`、零状态）⇒ 把 DDR 上**连续的
  //     8 个元素**当**一拍**（8 个 lane 各查一次表）：逐元素、**保序**、数值口径**一字不动**。
  //     `W=6400 ⇒ 800` 有效像素、`1600 ⇒ 200`、`400 ⇒ 50`（真表 `desc[61..66]`）。
  //   布局：**线性（非平面）**。`C_in = 1` 时"通道平面"只有 1 个平面 ⇒ 线性 NHWC 与 NCHW 平面
  //     **逐字节相同**（`off(0) = 0`）⇒ 折档**强制走线性通路**（与 `io.src_planar/dst_planar` 无关地
  //     读/写同一串字节）。为什么不走平面 gather：平面通路的对齐前提是 `inCols%32==0 ∧ outPix%32==0`
  //     （32 像素一组），而折档 `800%32==0` 但 `200%32==8`、`50%32==18` ⇒ **平面通路装不下 1600/400
  //     两档**；线性通路无这条前提。
  //   ★ 传输长度的 **32 B 对齐**（`DdrMaster` 的 P3 硬前提）：`len = 有效像素 × 8`，而 `DdrMaster.CHK`
  //     要求 `len%32==0` ⇒ 有效像素必须是 **4 的倍数**。真表 `Sigmoid_400`（`W=400`）折 50 像素
  //     **不是** 4 的倍数 ⇒ 上取整到 **52**（`fpix`）；多出的 2 个"填充像素"读到的是张量**之后**的
  //     字节（真表那 16 B 正是 `IN_BYTES=416` 的填充区），**写回时被 `wstrb` 掩掉**（`ri ≥ totEff`）
  //     ⇒ 邻居一个字节都不动（既有闸门的 `NEIGH_MISMATCH=0` 兜住）。`W=1600/6400` 的有效像素
  //     （200/800）本就是 4 的倍数 ⇒ 折档下**无掩码**（`fpix == totEff`）。
  //   ★ `foldPt` 只对**逐点**算子成立（`maxpool`/`resize` 是空间窗口、没有这种折 ⇒ 继续响亮 err）。
  //     `add` 的两路在 `SRC_ADDR` 那个流里**按列交织**（A/B 逐列相间）⇒ 折"8 个连续元素"会把 A/B
  //     混进同一拍、**不是 lane 对齐的** ⇒ 只接受 **E1 两趟读**（`addTwoSrc`：A/B 各一条**独立**线性
  //     流、各按 8 元素折 ⇒ lane 对齐）；其余 `add` + `C_in = 1` 继续**响亮 err**（宁可红、不静默错值）。
  val foldPt: Bool = (isSg || addTwoSrc) && (dw.cIn === U(1, 16 bits)) && (dw.cOut === U(1, 16 bits)) &&
                     (imgW32(2 downto 0) === U(0, 3 bits))
  /** 有效输出宽/高（折档 `W/8`；其余 = 原值）。`H` **不折**（折后仍按 8 元素一拍逐行推进）。 */
  val imgW32e: UInt = Mux(foldPt, (imgW32 >> 3).resize(32), imgW32)
  val imgH32e: UInt = imgH32
  /** 有效输入宽/高（按算子反推；折档下 `isPool/isRz` 恒假 ⇒ 等于 `imgW32e/imgH32e`）。 */
  val inW32e:  UInt = Mux(isPool, imgW32e + imgW32e, Mux(isRz, imgW32e >> 1, imgW32e))
  val inH32e:  UInt = Mux(isPool, imgH32e + imgH32e, Mux(isRz, imgH32e >> 1, imgH32e))
  /** 有效像素数（**未**上取整）= `imgW32e·imgH32e`；`fpix` = 上取整到 4 的倍数（见上"32 B 对齐"）。 */
  val totEff:  UInt = (imgW32e * imgH32e).resize(32)
  val fpix:    UInt = (((totEff + U(3, 32 bits)) >> 2) << 2).resize(32)
  // ===========================================================================
  // ★★ T-S1（2026-10-13）：**运行期行宽 `rowW`** —— 第二处钉子（spec §3.1）
  // ===========================================================================
  //   改动前本单元的对账是**编译期等式** `inW32 == WIDTH`（`MaxPoolUnit`/`ResizeUnit` 是"按展开期
  //   `WIDTH` 数列/配对"的：列回绕、`accRow` 下标、输出列计数）。真表里这些层的输入宽
  //   （`maxpool`：`2·IMG_W` = **320**；`resize`：`IMG_W/2` = **20**）都不等于 `W_MAX=640` ⇒
  //   改动前**一张网表只能过一个行宽**。同理 `Sigmoid` 头（`IMG_W = 6400`、`IMG_H = 1`）更要它。
  //   修法：**运行期行宽 = `inW32`**，
  //     · 带**行宽状态**的两个单元（`MaxPool`/`Resize`）只要求 `1 ≤ rowW ≤ W_MAX`（= `WIDTH`，
  //       = **分配**口径：`accRow` 仍按 `WIDTH/2`、`rb` 仍按 `WIDTH` 分配）⇒ 越界**响亮 err**；
  //     · 两个**零几何状态**的逐点算子（`Add`/`Sigmoid`）与行宽**无关**（一拍一列、无列计数）
  //       ⇒ 只要求 `rowW ≥ 1`（真表 `Sigmoid` 的 6400 就是这么过的）。
  //   ★ `rowW == WIDTH` 时与改动前**逐字节同形**（既有闸门零改动）。
  /** ★★ T-S1：运行期行宽（= 输入行宽；两个逐点算子只把它当"非 0"检查）。
    *   ★★ T-S3a.2c：改用**有效**输入宽（折档 = `W/8`；其余与 `inW32` 逐位相同）。 */
  val rowW   = inW32e
  /** ★★ T-S1：`MaxPool` 的 2x2 列配对要求行宽**偶数**（改动前是展开期 `require(WIDTH%2==0)`；
    *   行宽搬到运行期 ⇒ 同一条要求也必须在 `go` 那一刻**响亮**拦住，绝不静默跨行错位）。 */
  val rowWParOk = !isPool || (rowW(0) === False)
  /** ★★ T-S1：行宽界限（取代改动前的编译期等式 `inW32 == WIDTH`）。 */
  val rowWOk = (rowW =/= U(0, 32 bits)) &&
               Mux(isPool || isRz, rowW <= U(WIDTH, 32 bits), True) &&
               rowWParOk
  /** 输出像素数（**有效**几何：`IMG_W*IMG_H`；★★ T-S3a.2c 折档 = `W/8` 且上取整到 4 的倍数）。 */
  val outPix = Mux(foldPt, fpix, totEff)
  /** 输入列数（**有效**几何；折档 = `outPix` —— 逐点算子输入像素数 == 输出像素数）。 */
  val inCols = Mux(foldPt, fpix, (inW32e * inH32e).resize(32))
  /** 要喂给单元的**输入拍数**：Add 是"列交织"的两路 ⇒ 每列 2 拍（见文件头 O1 一节）。
    *   ★ E1：两趟读时 A/B **各一趟** ⇒ 拍数 = `inCols`（每趟一笔 RD，长度 = `inCols*C`）。 */
  val inBeats = Mux(addTwoSrc, inCols, Mux(isAdd, inCols + inCols, inCols))
  /** RD 字节数 / WR 字节数（都必须是 32 的倍数 —— 由下面的对账钉住）。 */
  val rdLen = (inBeats * U(C, 32 bits)).resize(32)
  val wrLen = (outPix  * U(C, 32 bits)).resize(32)

  // ===========================================================================
  // ★★ T-S3a.2a（2026-10-14）：**通道维** —— 把"编译期等式 `cIn == cOut == C`"换成**运行期**判据
  // ===========================================================================
  //   实测缺口（`gen/desc.bin` 解码）：真表旁路层是 `C_IN = C_OUT ∈ {16, 64, 1}`（`MaxPool_5`=16、
  //   `MaxPool_18/25/32` 与 `Resize_43/49`=64、`Sigmoid_*`=1），而改动前 `geomOk` 要求
  //   `dw.cIn === C ∧ dw.cOut === C`（`C = 8`）⇒ **真帧的旁路层在"通道"这一维就过不了**。
  //   本代口径（与文件头 §T-S3a.2a 一节同源，逐字引用）：
  //     `cIn == cOut` ∧ `cIn % C == 0` ∧ `cIn ≠ 0`（用低 3 位判整除，**没有除法器**）；
  //     块数 `nBlk = cIn/8`（`16 ⇒ 2`、`64 ⇒ 8`、`8 ⇒ 1`），逐块跑一遍**既有的整层相位**，
  //     源/目标平面偏移 `+8·HW`（见文件头 §T-S3a.2a 的地址推导）；
  //     四个算子**通道独立**（maxpool/resize 在空间、add/sigmoid 逐点）⇒ 分块**不引入跨通道状态**、
  //     **不新增存储**（`outMem` 一字不改，仍装**一个块**的输出 ≤ `MAXPIX`）。
  /** `cIn == cOut` 且（`cIn` 是 `C(=8)` 的**正整数倍**（低 3 位为 0 ⇒ 无除法器）**或**折档）。
    *   ★★ T-S3a.2c：折档（`cIn = cOut = 1` 的逐点算子）走**线性布局折**、单块 ⇒ 也接受。 */
  val cBlkOk = (dw.cIn === dw.cOut) && (dw.cIn =/= U(0, 16 bits)) &&
               (foldPt || (dw.cIn(2 downto 0) === U(0, 3 bits)))
  /** 本层的**通道块数** = `cIn/C`（`cIn == 8` ⇒ 1）。★★ T-S3a.2c：折档恒 **1 块**（`cIn = 1 ⇒ >>3 = 0`）。 */
  val nBlk   = Mux(foldPt, U(1, 16 bits), (dw.cIn >> 3).resize(16))

  /** `go` 那一刻的**响亮**对账（不过 ⇒ `err` 一拍、零搬运；与 UnitExec 的 qShift 对账同形）。
    *   ★★ T-S1：第一条从**编译期等式** `inW32 == WIDTH` 改成**运行期界限** `rowWOk`
    *   （`1 ≤ rowW ≤ W_MAX` + `MaxPool` 行宽偶数）—— 见上面「运行期行宽」一节。
    *   ★★ T-S3a.2a：`dw.cIn === C ∧ dw.cOut === C` 换成 `cBlkOk`（见上面「通道维」一节）。 */
  val geomOk = rowWOk &&
               (inH32 =/= U(0, 32 bits)) && (outPix =/= U(0, 32 bits)) &&
               cBlkOk &&
               (!isRz || ((imgW32(0) === False) && (imgH32(0) === False))) &&  // resize 的 >>1 要偶数
               (outPix <= U(MAXPIX, 32 bits)) &&                       // 片上输出存储装得下
               (rdLen(4 downto 0) === U(0, 5 bits)) && (rdLen =/= U(0, 32 bits)) &&
               (wrLen(4 downto 0) === U(0, 5 bits)) && (wrLen =/= U(0, 32 bits))
  /** ★★ T-S3a.2c：**有效**布局模式位（折档强制线性 ⇒ 两位都当 0；见文件头 §T-S3a.2c）。 */
  val srcPlEff = io.src_planar && !foldPt
  val dstPlEff = io.dst_planar && !foldPt
  /** ★★ C4b-B4：**布局模式**的结构性前提（见文件头；不合 ⇒ 同一条响亮 err）。
    *   · 读侧 gather 以 32 像素为一组 ⇒ `inCols % 32 == 0`（用低 5 位判，**没有除法器**）；
    *   · 写侧散射同样以 32 像素为一组 ⇒ `outPix % 32 == 0`；
    *   · Add 是两路列交织、两路布局可不同 ⇒ **本代不支持布局模式**（响亮 err，见文件头 O1）。
    *   ★★ T-S3a.2c：判据建在**有效**模式位上（折档 ⇒ 强制线性 ⇒ 两条对齐前提都**不适用**）。 */
  val planarOk = (!srcPlEff || (inCols(4 downto 0) === U(0, 5 bits))) &&
                 (!dstPlEff || (outPix(4 downto 0) === U(0, 5 bits))) &&
                 (!(srcPlEff || dstPlEff) || !isAdd)
  /** ★★ T-S3a.2a：**多通道块只用平面通路**。块的源/目标偏移是"通道**平面**"的偏移
    *   （`+8·HW` / `+8·outPix`），线性 NHWC 布局里根本不存在"某 8 个通道的连续子图"
    *   ⇒ 多块 + 线性 = **响亮 `err`、零搬运**（绝不静默按错的地址读）。
    *   单块（`cIn == C == 8`）**不限布局** ⇒ 改动前的两条通路（线性 NHWC / 平面）逐字节不变。 */
  val blkPlanarOk = (nBlk === U(1, 16 bits)) || (io.src_planar && io.dst_planar)
  /** ★★ T-S3a.2a：**多块**还要求"块喂完之后单元的相位回到上电值" —— 否则块 1 起会**静默错位**
    *   （块内输入行数 = 奇数 ⇒ 块末停在行对/行奇偶的半途，下一块的头几行与前一块的残料配成对）。
    *   逐块复位的前提就是**块内输入行数为偶**：`MaxPoolUnit` 的 `rowPar` 翻转偶次回 `False`；
    *   `ResizeUnit` 的 `half`/`orow` 按**输入行对**推进 ⇒ 偶数行 = 整数个行对 ⇒ 相位回上电值。
    *   `maxpool` 的 `inH = 2·IMG_H` **恒偶**；`resize` 的 `inH = IMG_H/2` 只在 `IMG_H ≡ 0 (mod 4)` 时偶
    *   ⇒ 多块的 `resize` 且 `IMG_H ≡ 2 (mod 4)` **响亮 `err`、零搬运**
    *   （本片不给四个单元加 `prime` 口 —— 那是另一件事；这里只做"宁可红、不静默错值"）。 */
  val blkPhaseOk  = (nBlk === U(1, 16 bits)) || (inH32(0) === False)

  // ===========================================================================
  // ★★ T-S3a.2b：**空间 tile** 的 `go` 那一刻对账（不合 ⇒ 同一条**响亮 err + 零搬运**）
  //   逐条（与文件头 §T-S3a.2b 的"口径边界"同源）：
  //     · `tileOpOk`  —— tile 做 maxpool/resize + ★★ **T-S3a.2d：`Add ∧ addTwoSrc`**（第二路源走 tile 的
  //                       **两趟**：A 趟落 `outMem`、B 趟读 `io.src2` 并在原位改成 `clamp8(A+B)`；
  //                       列交织的 `Add`（`src2k == 0`）**不**支持布局模式 ⇒ 继续响亮 `err`）；
  //     · `tilePlOk`  —— **必须平面通路**：tile 的读是"8 个平面各一笔 band"、写是"逐平面成行"，
  //                      线性 NHWC 里根本没有"通道平面"这个东西 ⇒ 线性 + 大层 = 响亮 err；
  //     · ★★ T-S3e：**原 `tileAliOk`（`inCols % 32 == 0`，"平面步长 32 B 对齐"）已去** ——
  //                      band 相位改为**每平面各算自己的**（`tPhP(p)`）+ 逐平面装载账本（`tLdK(p)`）
  //                      ⇒ 平面基址**不必**同余（见文件头 §T-S3e；真表 `Resize_43` 就是这条的承重档）；
  //     · `tileRzOk`  —— resize 的 `>>1` 要偶（`IMG_W` 偶）且 **`IMG_H ≡ 0 (mod 4)`**
  //                      （输出 tile 行必须落在全局输入行对的格点上，且每 tile 的输入行数为偶）；
  //     · `tileG0Ok`  —— 输入行数 / 输出像素数非 0（与整层口径同一条）。
  //   `tileConstOk`（编译期几何）为假 ⇒ 恒假。
  // ===========================================================================
  val tileOpOk   = isPool || isRz || (isAdd && addTwoSrc)
  val tilePlOk   = io.src_planar && io.dst_planar
  val tileRzOk   = (!isRz) || ((imgW32(0) === False) && (imgH32(1 downto 0) === U(0, 2 bits)))
  val tileG0Ok   = (inH32 =/= U(0, 32 bits)) && (outPix =/= U(0, 32 bits))
  val tileOk: Bool = (if (tileConstOk)
                        (cBlkOk && blkPlanarOk && tileOpOk && tilePlOk && tileRzOk && tileG0Ok && !foldPt)
                      else False)
  /** 本层走**整层**路径？（`geomOk` 那套条件全过 ⇒ 原路径；与改动前**逐字节同形**。） */
  val wholeOk: Bool = geomOk && planarOk && blkPlanarOk && blkPhaseOk

  // ---------------------------------------------------------------------------
  // 寄存器（全部先声明；Scala class 体是顺序求值）
  // ---------------------------------------------------------------------------
  val state = Reg(BypassPhase()) init BypassPhase.IDLE
  val doneR = Reg(Bool()) init False
  val errR  = Reg(Bool()) init False
  /** ★ 主口入参必须**保持到整笔搬运结束**（同 UnitExec：DdrMaster 在 CHK 态才读 mode/len）。 */
  val mMode = Reg(UInt(2 bits)) init (1)
  val mSrc  = Reg(UInt(ddrCfg.ADDR_W bits)) init (0)
  val mDst  = Reg(UInt(ddrCfg.ADDR_W bits)) init (0)
  val mLen  = Reg(UInt(32 bits)) init (0)
  /** 已吃进的 RD 拍数（0..inBeats）。 */
  val inCol = Reg(UInt(32 bits)) init (0)
  /** ★ C3.18 R4：**本次运行的喂料长度**（`inBeats`）—— 在 `RDSTART` 与 `mSrc/mDst/mLen`
    *   **同一拍**锁存。理由见文件头 §R4；一句话：`inBeats` 是描述符的 **乘法**结果，
    *   运行期每拍拿它跟 `inCol` 比，就成了 ResizeUnit 行缓冲 `CE` 锥里最深的一段。
    *   ⚠ 锁存的是 `inBeats` **原值**（不是 `inBeats-1`）：这样 `RDSTART` 的捕捉路径上
    *   只有「mux → 乘法 → 寄存器」，不额外背一个 32 位减法器；`-1` 那件事交给运行期的
    *   `inCol + 1`（那个自增器**本来就有**，`inCol` 每拍 `+1`）。 */
  val inBeatsR = Reg(UInt(32 bits)) init (0)
  /** ★ C3.18 R4：**本次运行的输出像素数**（`outPix`）的寄存副本（同上，RDSTART 锁存）。 */
  val outPixR = Reg(UInt(32 bits)) init (0)
  /** ★★ T-S3a.2c：**本次运行未上取整的有效像素数**（`totEff`；`RDSTART` 锁存）—— 折档下写侧
    *   尾掩码的界：`ri ≥ outPixXR` ⇒ `wstrb = 0`（上取整多出来的填充像素不写回，邻居不动）。 */
  val outPixXR = Reg(UInt(32 bits)) init (0)
  /** ★ C3.18 R4：**喂料末端粘滞位** —— 与 `inCol == inBeats`（⇔ `!(inCol < inBeats)`）**逐位等价**
    *   （证明见文件头 §R4）：`inTail` 在「把 `inCol` 从 `inBeats-1` 推到 `inBeats` 的那一拍」置起，
    *   之后 `inFeed` 恒 0 ⇒ 不可能再接受拍 ⇒ `inCol` 永远停在 `inBeats`、`inTail` 永远为 1。
    *   有了它，运行期的 `x_valid`（⇒ ResizeUnit 行缓冲 `CE`）锥里**不再有 32 位减法器/比较器**。 */
  val inTail  = Reg(Bool()) init False
  /** 已写进 `outMem` 的输出像素数（写序号）。 */
  val pixIdx = Reg(UInt(32 bits)) init (0)
  /** WR 相位的读序号。 */
  val ri = Reg(UInt(32 bits)) init (0)
  /** ★ Add 的 A 路 1 拍缓冲（偶拍锁 A；见文件头 O1 一节）。 */
  val aReg = Vec(Reg(SInt(8 bits)) init (0), C)
  /** ★ E1：本次运行的**两趟读**标志（`runStart` 锁存；运行期只用寄存器副本）。 */
  val twoSrcR = Reg(Bool()) init False
  /** ★ E1：两趟读的 **B 趟列序**（0..`inCols`）；A 趟复用 `inCol`。 */
  val bCol    = Reg(UInt(32 bits)) init (0)
  /** ★ E1 A 趟（读 `SRC_ADDR` 的 A，落 `outMem`）/ B 趟（读 `io.src2` 的 B，与 A 相加）。 */
  val twoSrcA = twoSrcR && (state === BypassPhase.RDRUN)
  val twoSrcB = twoSrcR && (state === BypassPhase.RDBRUN)

  // ===========================================================================
  // ★★ T-S3a.2a：**通道分块**的本次运行寄存器（`runStart` 清回；见文件头 §T-S3a.2a）
  //   一个块的"源平面偏移"与"目标平面偏移"**逐块累加**（每块一次 32 位加法）⇒ 网表里
  //   **没有乘法器**（`blk·8·inCols` 若直接写就是两个 32 位乘法器；这里是两个加法器，面积口径见文件头）。
  // ===========================================================================
  /** 本层块数 `nBlk = cIn/8`（`runStart` 锁存；运行期只用寄存器副本）。 */
  val nBlkR   = Reg(UInt(16 bits)) init (1)
  /** 当前块号（0..`nBlk-1`）。 */
  val blk     = Reg(UInt(16 bits)) init (0)
  /** 本块的**源**平面偏移（字节）= `blk·8·inCols`（块内 8 个平面 × 每平面 `inCols` 字节）。 */
  val blkSrcR = Reg(UInt(32 bits)) init (0)
  /** 本块的**目标**平面偏移（字节）= `blk·8·outPix`（块内 8 个平面 × 每平面 `outPix` 字节）。 */
  val blkDstR = Reg(UInt(32 bits)) init (0)
  /** 本块之后还有下一块？（`nBlkR ≥ 1` 由 `cBlkOk` 保证 ⇒ `nBlkR-1 ≥ 0`，不会越界。
    *   `cIn == 8` ⇒ `nBlkR == 1` ⇒ 恒 `False` ⇒ 单块作业**一次都不推进**（逐字节同形的前提）。 */
  val blkNext = blk =/= (nBlkR - U(1, 16 bits))

  // ===========================================================================
  // ★★ T-S3a.2b：**空间 tile 循环**的本次运行状态（`runStart` 清回；见文件头 §T-S3a.2b）
  //   分层：**块（2a 的外层）→ tile 网格（本片的内层）→ 该 tile 的 读/算/写**。
  //   `tilingR = 0`（= 整层路径）⇒ 下面每一个寄存器都不落数据通路（行为逐字节不变）。
  // ===========================================================================
  /** 本层是否走 **tile**（`go` 那一刻闩存 = `tileOk ∧ ¬wholeOk`）。 */
  val tilingR = Reg(Bool()) init (False)
  /** ★★ T-S3a.2d：tile 的**两趟**（`Add` 的第二路源）：False = A 趟（读 `SRC`、只把列落 `outMem`）、
    *   True = B 趟（读 `io.src2`、`x_a` = 片上 A、`x_b` = 本拍 B 列 ⇒ `clamp8(A+B)`）。
    *   ★ 对**非 `Add` 的 tile**（pool/resize）恒 False（`TILEGO` 清）⇒ 下面每个新增的 `Mux`
    *     都恒取**原分支**（既有层逐字节同形的前提）。 */
  val tPass = Reg(Bool()) init (False)
  /** ★★ T-S3a.2d：本 tile 的 **B 源平面 0 基址** = `io.src2 + blkSrcR`（与 A 源**同一个**块偏移累加器
    *   ⇒ B 侧享有同一套通道块偏移；`TILEGO` 那一拍闩存）。 */
  val tSrc2R = Reg(UInt(32 bits)) init (0)
  /** ★★ T-S3a.2d：tile 的两趟选择 —— `tileAddA`（落 A 列）/ `tileAddB`（喂单元出 `A+B`）。 */
  val tileAddA: Bool = tilingR && isAdd && !tPass
  val tileAddB: Bool = tilingR && isAdd && tPass
  /** tile 网格（`runStart` 闩存）：`tNtx = ceil(IMG_W/twTile)`、`tNty = ceil(IMG_H/TILE_H)`。 */
  val tNtx = Reg(UInt(16 bits)) init (0)
  val tNty = Reg(UInt(16 bits)) init (0)
  /** 当前 tile 序号（**tile 循环的唯一状态**；其余几何都是它的组合/闩存函数）。 */
  val tTx  = Reg(UInt(16 bits)) init (0)
  val tTy  = Reg(UInt(16 bits)) init (0)
  /** 本 tile 闩存的几何（`TILEGO` 那一拍锁存 ⇒ 运行期只读寄存器）。 */
  val tOxR = Reg(UInt(16 bits)) init (0)    // 输出 tile 原点 x（= 全局输出列）
  val tOyR = Reg(UInt(16 bits)) init (0)    // 输出 tile 原点 y（= 全局输出行）
  val tTwR = Reg(UInt(16 bits)) init (0)    // tile 输出宽（末列为余量）
  val tThR = Reg(UInt(16 bits)) init (0)    // tile 输出高（末行为余量）
  val tRowW= Reg(UInt(16 bits)) init (0)    // 本 tile 的**输入行宽** = 单元 `rowW`
  val tNRR = Reg(UInt(16 bits)) init (0)    // 输入窗口行数
  val tPixR= Reg(UInt(32 bits)) init (0)    // 本行窗口起点的**平面内像素偏移**（逐行 += inW）
  val tSrcR= Reg(UInt(32 bits)) init (0)    // 本块源平面 0 基址 = SRC + blkSrcR
  val tDstR= Reg(UInt(32 bits)) init (0)    // 本块目标平面 0 基址 = DST + blkDstR
  val tPixT= Reg(UInt(32 bits)) init (0)    // 本 tile 期望的输出像素数 = tTwR·tThR
  /** **y 带**（tile 行）的两个基址累加器：读侧 = `A·inW`、写侧 = `TILE_H·IMG_W`（只有加法 / 常量乘）。 */
  val tYBRd= Reg(UInt(32 bits)) init (0)
  val tYBWr= Reg(UInt(32 bits)) init (0)
  // ---- 读子相位（`TILERD` 的 `tRdSt`）----
  val tRdSt = Reg(UInt(2 bits)) init (0)    // 0=行设置 / 1=逐平面 32 B fetch（★ T-S3e：缺自己 chunk 的平面）/ 2=drain / 3=等输出收齐
  val tRow  = Reg(UInt(16 bits)) init (0)   // 本 tile 窗口内的输入行序
  val tPl   = Reg(UInt(3 bits)) init (0)    // fetch 里的平面序（0..C-1）
  val tBe   = Reg(UInt(2 bits)) init (0)    // 本平面已收的拍（0..3）
  val tBK   = Reg(Bool()) init (False)      // fetch 子相位：False = 本拍举 `start` / True = 收拍
  // ---- ★ B1'b（2026-10-25）：`inCols % 32 == 0`（= T-S3a.2b 的**共享相位前提**，8 个平面 band
  //   边界重合）时，tile FETCH 走 **SG 批式**（一次 `start(mode=3)` 跑完全部补取项）；
  //   否则退回**逐平面串行**（原路径逐字保留）。真表里只有 `Resize_43`（inCols=400）走老路。
  //   ★ B1（第一版）对全部形状都用 SG，`inCols%32≠0` 时在"per-plane chunk 补取↔drain"上稳定挂死
  //   （见 `y1/reports/bypass_sg_spec.md §8`）⇒ 本版按前提门控，老路零改动。
  val tSgScan= Reg(UInt(4 bits)) init (0)   // 入队扫描的平面序 0..C（扫完 = C）
  val tSgEnq = Reg(UInt(4 bits)) init (0)   // 本批已入队项数
  val tSgRd  = Reg(Bool()) init (False)     // 整批 RD 收流中
  val tSgGo  = Reg(Bool()) init (False)     // `start(mode=3)` 一拍脉冲
  val tSgDrn = Reg(Bool()) init (False)     // 进门先排空残留一笔
  val tSgPl  = Vec((0 until C).map(_ => Reg(UInt(3 bits)) init (0)))   // 项序 → 平面序
  val tSgCh  = Vec((0 until C).map(_ => Reg(UInt(2 bits)) init (0)))   // 项序 → 该平面本批的 chunk 序（入队快照）
  val tSgMask= Reg(Bits(C bits)) init (B(0, C bits))                   // 本批哪些平面真的取了
  val tAdrR = Reg(UInt(32 bits)) init (0)   // ★ T-S3e：本行窗口起点（**未对齐**）的累加器：平面 p 的基址 = `tAdrR + p·inCols`
  val tDj   = Reg(UInt(7 bits)) init (0)    // ★ T-S3e：drain 的**本行列序**（0..`tRowW`；旧口径是"本 band 内字节序"）
  val tPixN = Reg(UInt(32 bits)) init (0)   // 本 tile 已收的输出像素数
  // ---- 写子相位（`TILEWR` 的 `tWrSt`）----
  val tWrQ  = Reg(UInt(16 bits)) init (0)   // tile 内输出行序
  val tWrP  = Reg(UInt(3 bits)) init (0)    // 平面序
  val tWrSt = Reg(UInt(2 bits)) init (0)    // 0=本笔几何+`start` / 1=填 32 B 行段 / 2=emit / 3=等落地
  val tFk   = Reg(UInt(6 bits)) init (0)    // 行段填充序
  val tWB   = Reg(UInt(4 bits)) init (0)    // 本笔已发的拍
  val tNb   = Reg(UInt(4 bits)) init (0)    // 本笔的拍数（= len/8）
  val tIdxR = Reg(UInt(riW bits)) init (0)  // 本 tile 当前输出行的 `outMem` 行首下标 = tWrQ·tTwR
  val tRowA = Reg(UInt(32 bits)) init (0)   // 本输出行的**目标偏移**（相对 tDstR）= tYBWr + q·IMG_W + ox0
  val tCurA = Reg(UInt(32 bits)) init (0)   // 本笔的**目标基址**（= tDstR + 行 + 平面偏移 + tOxR）
  val tBstR = Reg(UInt(32 bits)) init (0)   // 本笔 burst 的 32 B 对齐基址
  val tBlR  = Reg(UInt(32 bits)) init (0)   // 本笔 burst 字节数（32 的正整数倍）
  /** 本笔的**行段缓冲**（32 字节；≤ 32 的 tile 宽 + `wstrb` 掩码 ⇒ 段外字节是 don't care）。 */
  val tRowB = Vec.fill(32)(Reg(Bits(8 bits)) init (B(0, 8 bits)))

  // ---- tile 网格的**组合**几何（`TILEGO` 那一拍闩存进 `t*R`）----
  /** 本层 tile 的输出宽（pool 切到 `TWP`、resize 用 `TWR`）。 */
  val tWTc  = Mux(isPool, U(TWP, 16 bits), Mux(isRz, U(TWR, 16 bits), U(TWA, 16 bits)))
  /** 当前 tile（`tTx/tTy`）的输出原点与尺寸。 */
  val tOxC  = Mux(isPool, (tTx.resize(20) * U(TWP, 20 bits)).resize(20),
                  Mux(isRz, (tTx.resize(20) * U(TWR, 20 bits)).resize(20),
                            (tTx.resize(20) * U(TWA, 20 bits)).resize(20))).resize(16)
  val tOyC  = (tTy.resize(16) * U(TILE_H, 16 bits)).resize(16)
  val tTwC  = Mux((imgW32.resize(20) - tOxC.resize(20)) > tWTc.resize(20),
                  tWTc.resize(20), (imgW32.resize(20) - tOxC.resize(20))).resize(16)
  val tThC  = Mux((imgH32.resize(20) - tOyC.resize(20)) > U(TILE_H, 20 bits),
                  U(TILE_H, 20 bits), (imgH32.resize(20) - tOyC.resize(20))).resize(16)
  /** 输入窗口（**无 halo**）：行起点（全局输入行）/ 行数 / 列数（= 单元 rowW）。
    *   ★★ T-S3a.2d：`Add` 是**逐点**算子 ⇒ 输入窗口 == 输出窗口（`tWy=tOy`、`tNR=tTh`、`tNC=tTw`）。 */
  val tWyC  = Mux(isPool, (tOyC << 1), Mux(isRz, (tOyC >> 1), tOyC)).resize(16)
  val tNRC  = Mux(isPool, (tThC << 1), Mux(isRz, (tThC >> 1), tThC)).resize(16)
  val tNCC  = Mux(isPool, (tTwC << 1), Mux(isRz, (tTwC >> 1), tTwC)).resize(16)
  /** 本 tile 窗口**列起点**相对量与**行起点**（像素）的增量（只有**常量乘** ⇒ 无乘法器）。 */
  val tXOfs = Mux(isPool, (tTx.resize(20) * U(2 * TWP, 20 bits)).resize(20),
                  Mux(isRz, (tTx.resize(20) * U((TWR / 2) max 1, 20 bits)).resize(20),
                            (tTx.resize(20) * U(TWA, 20 bits)).resize(20))).resize(32)
  /** 一个 **y 带**推进时两个基址的增量：读侧 `A·inW`、写侧 `TILE_H·IMG_W`（常量乘 / 移位）。
    *   ★★ T-S3a.2d：`Add` 的行跨步 = `1·inW`（逐点 ⇒ 一个 y 带 = `TILE_H` 个输入行）。 */
  val tYBAdvR = (inW32 * U(2 * TILE_H, 32 bits)).resize(32)
  val tYBAdvZ = (inW32 * U((TILE_H / 2) max 1, 32 bits)).resize(32)
  val tYBAdvA = (inW32 * U(TILE_H, 32 bits)).resize(32)
  val tYBAdv  = Mux(isPool, tYBAdvR, Mux(isRz, tYBAdvZ, tYBAdvA))
  val tYWAdv  = (imgW32 * U(TILE_H, 32 bits)).resize(32)

  /** ★★ T-S3a.2d：本 tile 的 **B 源（`io.src2`）平面 0 基址** = `io.src2 + blkSrcR`
    *   （与 A 源**同一个**块偏移累加器 ⇒ B 侧享有同一套通道块偏移；见文件头 §T-S3a.2d）。
    *   `tPass == False`（A 趟 / 非 `Add` 的 tile）恒取 `tSrcR` ⇒ 既有层**逐字节不变**。 */
  val tSrcE  = Mux(tPass, tSrc2R, tSrcR).resize(32)

  // ===========================================================================
  // ★★ C4b-B4：布局模式的**本次运行**寄存器（`runStart` 那一拍锁存 ⇒ 运行期只用寄存器副本）
  // ===========================================================================
  /** 本次运行的布局模式（`runStart` 锁存；运行期与 `io.*` 的锥彻底断开）。 */
  val srcPlR  = Reg(Bool()) init False
  val dstPlR  = Reg(Bool()) init False
  /** 本次运行的**输入像素数**（= `inCols`；布局模式里它同时是**平面步长**）的寄存副本。 */
  val inColsR = Reg(UInt(32 bits)) init (0)
  /** ★ B1'b：8 平面 band 相位重合的前提（`inCols % 32 == 0`，= T-S3a.2b 的原始前提）⇒ 走 SG 批式。 */
  val tSgOk = (inColsR(4 downto 0) === U(0, 5 bits))
  val plW: Int = log2Up(C) max 1
  // ---- 读侧：平面 → NHWC 列流 的 gather（32 像素一组；见文件头）----
  /** gather 子 FSM：0 = 未活动 / 1 = FETCH（逐平面一笔 32 B RD）/ 2 = DRAIN（逐列吐出）。 */
  val pgSt  = Reg(UInt(2 bits)) init 0
  /** FETCH 内：`False` = 本平面要发起一笔 RD / `True` = 正在收这 4 拍。 */
  val pgK   = Reg(Bool()) init False
  val pgPl  = Reg(UInt(plW bits)) init 0          // 本组正在收的平面（0..C-1）
  val pgB   = Reg(UInt(2 bits)) init 0            // 本平面已收的拍（0..3）
  val pgG   = Reg(UInt(16 bits)) init 0           // 组序（0..inCols/32-1）
  val pgJ   = Reg(UInt(5 bits)) init 0            // DRAIN 内的列序（0..31）
  /** 转置缓冲：下标 `pl*4 + b`，每格 = 该平面那 8 个字节（一拍 = 8 B）。 */
  val pgBuf = Vec.fill(C * 4)(Reg(Bits(64 bits)) init B(0, 64 bits))
  /** 本组**平面 0** 的基址（= `SRC + 32*g`；组内所有平面地址都从它递推）。 */
  val pgPlane0 = Reg(UInt(32 bits)) init 0
  /** 本组当前平面的 32 B 突发地址（平面 0 = `pgPlane0`，每换平面 `+= inCols`）。 */
  val pgAddrR  = Reg(UInt(32 bits)) init 0
  /** 本趟的组数 = `inCols/32`（`planarOk` 已在 `go` 那一刻把住 32 整除）。 */
  val pgGNum   = (inColsR >> 5).resize(16)
  /** 本拍要发起一笔 32 B RD（FETCH 的进入条件：子 FSM 在 FETCH 且主口空闲）。 */
  val pgStartPulse = (pgSt === U(1, 2 bits)) && (pgK === False) && (!ddrMaster.io.busy)
  /** FETCH 期本拍要收 RD 拍。 */
  val pgRdReady = (pgSt === U(1, 2 bits)) && (pgK === True)
  /** 平面字节的落点下标 = `pgPl*4 + pgB`（硬连线左移 2 位 + 拍号）。 */
  val pgWrIdx = ((pgPl @@ U(0, 2 bits)) + pgB.resize(5)).resize(5)
  /** DRAIN 的列来源：第 `cl` 道 = `pgBuf(cl*4 + pgJ/8)` 的第 `pgJ%8` 个字节（8 个 4:1 mux，无桶形移位）。 */
  val pgJw = pgJ(4 downto 3)
  val pgJb = pgJ(2 downto 0)
  val pgCol = Vec((0 until C).map(cl =>
    Vec((0 until 8).map(k => pgBuf((U(cl * 4, 5 bits) + pgJw.resize(5)).resize(5))(k * 8 + 7 downto k * 8)))(pgJb).asSInt))
  /** DRAIN 相位（本拍手上有一列）。 */
  val pgColVal = srcPlR && (pgSt === U(2, 2 bits))

  // ---- 写侧：NHWC 列流 → 平面 的散射（每个平面**一笔** WR 事务；见文件头）----
  /** 散射子 FSM：0 = 未活动 / 1 = FILL（从 `outMem` 顺序读 32 个像素进 `woBuf`）/ 2 = EMIT（逐拍发）。 */
  val wgSt   = Reg(UInt(2 bits)) init 0
  val wgPl   = Reg(UInt(plW bits)) init 0         // 本笔 WR 事务的平面（= 输出的第几个平面）
  val wgG    = Reg(UInt(16 bits)) init 0          // 组序
  val wgB    = Reg(UInt(2 bits)) init 0           // 组内拍号（0..3）
  val wf     = Reg(UInt(5 bits)) init 0           // FILL 的像素序（0..31）
  /** 转置缓冲：`woBuf(j)` = 本组第 `j` 个像素的 C 个通道（与 `outMem` 一字同宽）。 */
  val woBuf  = Vec.fill(32)(Reg(Bits(64 bits)) init B(0, 64 bits))
  /** 每笔 WR 事务的组数 = `outPix/32`。 */
  val wrGNum = (outPixR >> 5).resize(16)
  /** EMIT 的 8 个数据字节：第 `k` 个字节 = `woBuf(wgB*8+k)` 的第 `wgPl` 道（动态位选）。 */
  val wbK    = (wgB.resize(5) << 3).resize(5)
  val wByteSel = (wgPl.resize(6) << 3).resize(6)
  /** 本拍的 64 位载荷（8 个像素的第 `wgPl` 道；第 0 个像素落**最低字节**）。
    *   ★ SpinalHDL 的 `Cat` 把**第一个元素当最低位**（与 `DdrMaster` 的文件头同一条警告）⇒ 元素必须按
    *     `k = 0,1,...,7` 排（实测踩过：`.reverse` 会让每拍 8 字节整体反序 —— 逐列"整体少一个通道"式的
    *     错位，闸门的 `DST_FIRST_BAD=0` 当场抓住）。 */
  val wEmitDat = Cat((0 until 8).map(k =>
    woBuf((wbK + U(k, 5 bits)).resize(5))(wByteSel, 8 bits)))

  // ===========================================================================
  // ★★ T-S3e：**旁路 tile 的 per-plane band 账本**（见文件头 §T-S3e；spec §3.4）
  //   · 相位 `tPhP(p)`：平面 p 的行窗口起点低 5 位（= 旧共享 `tOffC` 的 **per-plane** 版）；
  //   · 下标 `tIdxP(p)`：平面 p 自己的 band 内下标（`[4:0]`）+ 相对本行 chunk0 的 chunk 序（`[6:5]`）；
  //   · 账本 `tLdK(p)`：平面 p 已装 chunk 序（哨兵 3 = 本行还没装）；
  //   · `tNeedC`：本列还有平面没装好它该用的 chunk ⇒ drain 先不喂列（去 FETCH 补取，见 `when(tRdOn)`）。
  //   `inCols % 32 == 0` 时各平面相位相同 ⇒ 本块给出的每一个量都与旧共享口径同值（逐字节同形）。
  // ===========================================================================
  /** 本行窗口起点的**平面 0** 低 5 位（per-plane 相位的基准；= 旧 `tOffC`）。 */
  val tOff0  = (tSrcE + tPixR)(4 downto 0)
  /** 平面步长 `inCols` 的低 5 位（相位增量；`p·tQ5 mod 32` 只有 5×5 的常量乘）。 */
  val tQ5    = inColsR(4 downto 0)
  /** **每平面自己的 band 相位** `tPhP(p) = (行窗口起点 + p·inCols) mod 32`（= T-S3b `wxPIDX` 的同位物）。 */
  val tPhP   = Vec((0 until C).map(p =>
                 ((tOff0.resize(6) + (tQ5 * U(p, 5 bits)).resize(5).resize(6)).resize(6))(4 downto 0)))
  /** **每平面自己的 band 内下标 + chunk 序**（7 位：`[6:5]` = 相对本行 chunk0 的 chunk 序（0..2）、
    *   `[4:0]` = band 内字节序；`tPhP + tDj ≤ 31 + 63 = 94 < 128` ⇒ 7 位够）。 */
  val tIdxP  = Vec((0 until C).map(p => (tPhP(p).resize(7) + tDj.resize(7)).resize(7)))
  /** 本行行宽的 7 位口径（`tRowW ≤ 2·TWP ≤ 64 < 128`，由 `tileConstOk` 的编译期几何保证）。 */
  val tRw7   = tRowW.resize(7)
  /** 每平面的**装载账本**：已装 chunk 序（行首清回**哨兵 3** = 未装；chunk 序恒 ≤ 2 ⇒ 3 安全）。 */
  val tLdK   = Vec.fill(C)(Reg(UInt(2 bits)) init 3)
  /** 本平面在**当前列**要不要补取（该平面该用的 chunk 序 ≠ 已装序）。`tDj` 单调 ⇒ 序只增不减。 */
  val tChk   = Vec((0 until C).map(p => (tIdxP(p)(6 downto 5) =/= tLdK(p))))
  /** 本列有平面要补取 ⇒ drain 前先起一趟 FETCH（见 `when(tRdOn)` 的 `tRdSt==2` 分支）。 */
  val tNeedC = tChk.reduce(_ || _)

  // 默认值（写在 switch 之前 ⇒ 被 switch 内赋值覆盖）
  errR  := False
  doneR := False
  /** ★ C4b-B4：线性（NHWC）通路的 `start`（与旧写法**逐字同形**；布局模式下被 gather 的脉冲顶掉）。
    *   ★ E1：两趟读的 **B 趟**（`RDBSTART`）也在这里举 `start`（`mSrc` 在这一拍被赋成 `io.src2`）。 */
  val linStart = (state === BypassPhase.RDSTART) || (state === BypassPhase.RDBSTART)
  /** ★ C4b-B4：**读相位**（`RDSTART`/`RDRUN`）—— 只有在这两个相位，布局模式才把主口入参换成
    *   gather 的"逐平面 32 B"（WR 相位必须回到 `mDst/mLen`，否则 WR 会被当成 32 B 的 RD 入参）。 */
  val inRdPh = (state === BypassPhase.RDSTART) || (state === BypassPhase.RDRUN)
  val gatherMux = srcPlR && inRdPh
  ddrMaster.io.start    := Mux(gatherMux, pgStartPulse, linStart)
  ddrMaster.io.mode     := mMode
  ddrMaster.io.sg_valid := False   // ★ B3b：本模块不用 SG-RD
  ddrMaster.io.sg_addr  := U(0, ddrCfg.ADDR_W bits)
  ddrMaster.io.sg_flush := False
  ddrMaster.io.sg_beatsM1 := U(0, 4 bits)
  ddrMaster.io.src      := Mux(gatherMux, pgAddrR.resize(ddrCfg.ADDR_W), mSrc)
  ddrMaster.io.dst      := mDst
  ddrMaster.io.len      := Mux(gatherMux, U(32, 32 bits), mLen)

  // ---------------------------------------------------------------------------
  // 输入侧：RD 流（一拍 = 一个输入列）→ 单元 x
  // ---------------------------------------------------------------------------
  val inRdRun   = (state === BypassPhase.RDRUN)
  /** ★ C3.18 R4：本拍还想喂更多 —— 取值与旧的 `inCol < inBeats` **逐位相同**（等价性见 §R4），
    *   但从「寄存器 + 比较器」变成了**一根寄存器的输出**（`CE` 锥上少 4~5 级）。 */
  val moreIn    = !inTail
  val inFeed    = inRdRun && moreIn
  /** ★ C4b-B4：线性（NHWC）通路的 `beatPres` —— 布局模式下**恒 0**（列改由 gather 提供）。 */
  val beatPres  = inFeed && ddrMaster.io.rd_valid && !srcPlR
  /** Add 的"本拍是 B 路"判定（列交织：偶拍=A、奇拍=B）。 */
  val addOdd    = inCol(0) === True

  val xNow = Vec(SInt(8 bits), C)
  for (ci <- 0 until C) {
    xNow(ci) := ddrMaster.io.rd_data((ci * 8 + 7) downto (ci * 8)).asSInt
  }
  /** ★ C4b-B4：**本拍手上的列**（3:1 三选一：tile drain 列 / 布局 gather 的 drain 列 / 线性 RD 拍）。
    *   ★★ T-S3a.2b：tile 的 drain 列**复用同一张 `pgBuf`**（同一套转置下标；drain 序由 tile 口径给）。
    *   ★★ T-S3e：**每个平面用自己的下标** `tIdxP(cl)[4:0]` —— `[4:3]` 选本平面那 4 个字（32 B chunk）
    *   里的第几个、`[2:0]` 选字内字节（= T-S3b `wxCol` 用 `wxPIDX(cl)` 的同一手法）。 */
  val tCol = Vec((0 until C).map(cl =>
    Vec((0 until 8).map(k =>
      pgBuf((U(cl * 4, 5 bits) + tIdxP(cl)(4 downto 3).resize(5)).resize(5))(k * 8 + 7 downto k * 8)))(tIdxP(cl)(2 downto 0)).asSInt))
  val xCol = Vec(SInt(8 bits), C)
  for (ci <- 0 until C) {
    xCol(ci) := Mux(tilingR, tCol(ci), Mux(srcPlR, pgCol(ci), xNow(ci)))
  }
  for (ci <- 0 until C) {
    mp.io.x(ci) := xCol(ci)
    rz.io.x(ci) := xCol(ci)
    sg.io.x(ci) := xCol(ci)
    ad.io.x_b(ci) := xCol(ci)
    // ★ E1：`ad.io.x_a(ci)` 在 `outMem` 声明之后**单点**赋值（A 趟 = `aReg`、B 趟 = `outMem[bCol]`）。
  }
  /** 选中单元的 ready（四个单元里只有 Resize 会反压：输出相位 x_ready=0）。 */
  val unitReady = Mux(isPool, mp.io.x_ready,
                  Mux(isRz,   rz.io.x_ready,
                  Mux(isSg,   sg.io.x_ready, ad.io.x_ready)))
  // 只给**选中的**单元喂 x_valid：未选中的单元一拍都不推进 ⇒ 它们的内部相位不被本次运行改动。
  //   ★ C4b-B4：列的 valid = 线性拍 或 gather 的 drain 列（**同一根** `colVal`）⇒ 单元侧无感。
  //   ★ E1：两趟读时 **A 趟不喂单元**（只落 `outMem`）、**B 趟才喂**（`x_a`=片上 A、`x_b`=RD 的 B）。
  /** B 趟「还想收」：主口在 `RDBRUN` 且尚未收满 `inCols`。 */
  val bRdRun = (state === BypassPhase.RDBRUN)
  val bFeed  = bRdRun && (bCol =/= inColsR)
  /** ★★ T-S3a.2b：**tile 的 drain 列**是否有效（`TILERD` 的 drain 子相位且本行还有列要喂）。
    *   ★★ T-S3e：本列若还有平面没装好它该用的 chunk（`tNeedC`）⇒ 先不喂（去 FETCH 补取该平面那笔）。 */
  val tileDrain  = (state === BypassPhase.TILERD) && (tRdSt === U(2, 2 bits)) &&
                   (tDj =/= tRw7) && !tNeedC
  val tileColVal = tileDrain
  /** ★★ T-S3a.2d：本拍这一列**被成交**（A 趟 = 落 `outMem`；B 趟 = 单元收下）—— `tDj` 与 A 趟的
    *   落列**同一根**条件（`Add` 的 `x_ready ≡ 1` ⇒ B 趟也同值）。 */
  val tileDrainTake = tileDrain && unitReady
  val colVal = Mux(tilingR, tileColVal,
               Mux(srcPlR, pgColVal,
               Mux(twoSrcR, twoSrcB && bFeed && ddrMaster.io.rd_valid, beatPres)))
  mp.io.x_valid := colVal && isPool
  rz.io.x_valid := colVal && isRz
  sg.io.x_valid := colVal && isSg
  // ★★ T-S1：**运行期行宽**直通两个带行宽状态的单元（`MaxPool` 的列回绕/`accRow` 下标、`Resize` 的
  //   列回绕/输出列计数）。两个逐点算子（`Add`/`Sigmoid`）**没有行宽状态**、也没有 `rowW` 口 ⇒ 不接。
  //   `rowW == WIDTH` 时与改动前逐拍同形（既有闸门零改动）。
  //   ★★ T-S3a.2b：tile 下 `rowW` = **本 tile 的输入行宽**（`TILEGO` 那一拍闩存）—— 末列 tile 更窄
  //     ⇒ 必须每 tile 重闩（单元在每个输入行末把列指针回零 ⇒ 行边界上换 `rowW` 是安全的）。
  val rowWEff = Mux(tilingR, tRowW.resize(32), rowW)
  mp.io.rowW := rowWEff.resize(16)
  rz.io.rowW := rowWEff.resize(16)
  /** ★★ T-S3a.2d：**tile 的 A 趟不喂单元**（只把列落 `outMem`）、**B 趟两路同拍**（`x_a`=片上 A、
    *   `x_b`=本拍 B 列）。非 `Add` 的 tile（`tileAddA/B` 恒假）与整层路径**逐字节同形**。 */
  /** ★ E1：A/B 两路的 valid 合成一根 —— 两趟读时 B 趟两路同拍；否则沿用旧的"奇拍 = B"（列交织）。 */
  val addAB = Mux(tilingR, tileColVal && tPass,
               Mux(twoSrcB, colVal, colVal && isAdd && addOdd))
  ad.io.x_a_valid := addAB
  ad.io.x_b_valid := addAB
  // 偶拍（A 路）只锁进 aReg，不出数；奇拍（B 路）用上一拍锁下的 A 与当拍的 B 同拍喂两路。
  //   ★ E1：两趟读不走这条（A/B 都已就位）⇒ 用 `!twoSrcR` 把它挡开。
  when(colVal && isAdd && !addOdd && !twoSrcR) {
    for (ci <- 0 until C) { aReg(ci) := xCol(ci) }
  }
  /** ★ C4b-B4：布局模式下主口 RD 拍由 gather 自己收（`pgRdReady`），线性模式沿用旧的一根线。
    *   ★ E1：A 趟 `rd_ready = inFeed`（全收）、B 趟 `rd_ready = bFeed`（收满 `inCols` 为止）。
    *   ★★ T-S3a.2b：tile 的 fetch 子相位**全收**本 band 的 4 拍（列由 `tDj` 区间自己控节奏）。 */
  val tRdReady = (state === BypassPhase.TILERD) && (tRdSt === U(1, 2 bits)) && Mux(tSgOk, tSgRd, tBK)
  ddrMaster.io.rd_ready := Mux(tilingR, tRdReady,
                           Mux(srcPlR, pgRdReady,
                           Mux(bRdRun, bFeed,
                           Mux(twoSrcR, inFeed, inFeed && unitReady))))
  /** 本拍真的吃下一拍（RD 流被接受）。★ R4：同一条件既推进 `inCol`，也置 `inTail`。
    *   ★ E1：`(state===RDRUN)` 守卫让"A 拍计数"只在 A 趟推进（B 趟另有 `bCol`）。
    *   ★ C4b-B4：布局模式下"吃下的列"= gather 吐给单元且被单元收下的那一列（同一对寄存器，
    *   等价性证明与 R4 逐字相同：`inCol` 只在成交那一拍 +1，`inTail` 在同一拍按 `inCol+1` 置起）。 */
  val feedBeat = inRdRun && ddrMaster.io.rd_valid && ddrMaster.io.rd_ready && !srcPlR
  val pgColTaken = pgColVal && unitReady
  when(feedBeat || pgColTaken) {
    inCol := inCol + 1
    when((inCol + 1).resize(32) === inBeatsR) { inTail := True }
  }
  /** ★ E1：B 趟列序推进（一拍 = 一列 B；`Add` 不反压 ⇒ 收满 `inCols` 拍）。 */
  val bBeat = bRdRun && ddrMaster.io.rd_valid && ddrMaster.io.rd_ready
  when(bBeat) { bCol := bCol + 1 }

  // ---------------------------------------------------------------------------
  // 输出侧：单元 y（一拍一个输出像素）→ outMem（按产出序号）
  // ---------------------------------------------------------------------------
  val ySel = Vec(SInt(8 bits), C)
  for (ci <- 0 until C) {
    ySel(ci) := Mux(isPool, mp.io.y(ci),
                Mux(isRz,   rz.io.y(ci),
                Mux(isSg,   sg.io.y(ci), ad.io.y(ci))))
  }
  val yVal = Mux(isPool, mp.io.y_valid,
             Mux(isRz,   rz.io.y_valid,
             Mux(isSg,   sg.io.y_valid, ad.io.y_valid)))
  val yWord = Cat((0 until C).map(co => ySel(co).asBits))
  /** ★ E1：A 趟把 RD 的 A 列**原样**写进 `outMem`（B 趟再在原位改成 `clamp(A+B)`）。 */
  val aColWord = Cat((0 until C).map(ci => xNow(ci).asBits))
  // 上电初值 0（Mem 无复位；不给初值 ⇒ 没写过就读是 X ⇒ 一旦有路径被跳过就把 X 写回 DDR）。
  val outMem = Mem(Bits(C * 8 bits), MAXPIX).init(Seq.fill(MAXPIX)(B(0, C * 8 bits)))
  /** ★ E1：两趟读的写口（A 趟写 A 列 @ `inCol`；B 趟写 `clamp(A+B)` @ `bCol`）；非两趟读 = 旧的 `pixIdx`。 */
  val twoSrcWrEn   = Mux(twoSrcA, feedBeat, yVal)
  val twoSrcWrAddr = Mux(twoSrcA, inCol, bCol)
  val twoSrcWrData = Mux(twoSrcA, aColWord, yWord)
  /** ★★ T-S3a.2b：tile 下写序号是**本 tile 的产出序**（`tPixN`，逐像素 +1；tile 输出 ≤ MAXPIX）。 */
  val wrIdxEff = Mux(tilingR, tPixN(riW - 1 downto 0), pixIdx(riW - 1 downto 0))
  /** ★★ T-S3a.2d：tile 的 **A 趟写口** —— gather 出的 A 列**原样**落 `outMem[tPixN]`（不喂单元），
    *   与 E1 整层 A 趟（`twoSrcWrEn = feedBeat`、数据 = RD 的 A 列）**同一条纪律**。
    *   注意 drain 的"成交"条件与 `tDj` 推进**同一根**（`tileDrain && unitReady`；`Add` 的 `x_ready ≡ 1`）。 */
  val tAStore   = tileAddA && tileDrainTake
  val tColWord  = Cat((0 until C).map(ci => tCol(ci).asBits))
  outMem.write(Mux(tilingR, wrIdxEff, Mux(twoSrcR, twoSrcWrAddr(riW - 1 downto 0), wrIdxEff)),
               Mux(tilingR, Mux(tileAddA, tColWord, yWord), Mux(twoSrcR, twoSrcWrData, yWord)),
               Mux(tilingR, Mux(tileAddA, tAStore,  yVal),  Mux(twoSrcR, twoSrcWrEn,  yVal)))
  /** ★★ T-S3a.2d：本拍写进 `outMem` 的**推进条件**（tile 的 A 趟按"落下的列"推进；
    *   tile 的 B 趟与 pool/resize 的 tile 按单元出料 `yVal` 推进；整层路径**逐字同形**）。 */
  val tPixAdv = Mux(tilingR, Mux(tileAddA, tileDrainTake, yVal), yVal && !twoSrcR)
  when(tPixAdv) {
    when(tilingR) { tPixN := tPixN + 1 } otherwise { pixIdx := pixIdx + 1 }
  }
  /** ★ E1：两趟读的 B 趟 —— `x_a` = 片上存的 A 列（`outMem[bCol]`），`x_b` = 本拍 RD 的 B 列（在 `xCol`）。
    *   ★★ T-S3a.2d：tile 的 B 趟同办，只是片上 A 的下标是**本 tile 的产出序** `tPixN`
    *   （读后写：`Mem.readAsync` 是组合读，写口在时钟沿生效 ⇒ 读到的是本拍的 A ⇒ 与 E1 同一条依据）。 */
  val aRdIdx = Mux(tilingR, tPixN(riW - 1 downto 0), bCol(riW - 1 downto 0))
  val aStoredWord = outMem.readAsync(aRdIdx)
  for (ci <- 0 until C) {
    ad.io.x_a(ci) := Mux(twoSrcB || tileAddB, aStoredWord(ci * 8 + 7 downto ci * 8).asSInt, aReg(ci))
  }
  /** ★ E1：B 趟收满 `inCols` 列 ⇒ 本趟读完（去 WR 相位）。 */
  val bDrained = bRdRun && (bCol === inColsR)

  // WR 相位：还有字没发就举 wr_valid（一拍一字 = 一个像素的 C 个通道）。★ R4：`outPix` 用寄存副本
  // （`outPixR`）—— 否则这条 `wr_valid` 也挂在同一个「描述符 ⇒ 乘法 ⇒ 比较」的深锥上。
  // ★ C4b-B4：布局模式下 WR 由**散射**子 FSM 驱动（每平面一笔事务、逐拍 8 像素的第 `wgPl` 道）。
  ddrMaster.io.wr_valid := Mux(dstPlR,
                               (state === BypassPhase.WRRUN) && (wgSt === U(2, 2 bits)),
                               (state === BypassPhase.WRRUN) && (ri < outPixR))
  ddrMaster.io.wr_data  := Mux(dstPlR, wEmitDat, outMem.readAsync(ri(riW - 1 downto 0)))
  // ★★ T-S2b：写字节掩码（旁路算子无 tile 写 ⇒ 恒"全字节有效"，与改动前逐拍同形）
  // ★★ T-S3a.2c：折档**尾掩码** —— 上取整多出来的填充像素（< 4 个；`ri ≥ outPixXR`）不写，
  //   否则会把张量 `W` 之后的**邻居**字节一起写掉（真表 `Sigmoid_400`：`W=400`、`fpix=52`）。
  //   ⇒ 写入的有效字节数恰为 `W`（既有闸门的 `NEIGH_MISMATCH=0` 就是这条的证据）。
  ddrMaster.io.wstrb    := Mux(foldPt && (ri >= outPixXR), B(0x00, 8 bits), B(0xFF, 8 bits))
  when(ddrMaster.io.wr_valid && ddrMaster.io.wr_ready && !dstPlR) { ri := ri + 1 }

  // ---------------------------------------------------------------------------
  // ★★ C4b-B4：**写侧散射**（NHWC 列流 → 通道平面）。每个平面**一笔** WR 事务（理由见文件头）：
  //   事务内：FILL（从 `outMem` 顺序读 32 个像素进 `woBuf`）→ EMIT（4 拍 × 8 像素的第 `wgPl` 道）。
  //   为什么每平面一笔事务：`DdrMaster` 的 WR 是**线性**流（地址逐 8 B 递增）⇒ 同一平面的字节必须
  //   **连续**发；而 `woBuf` 只装得下一个组（32 像素 × C 通道）⇒ 发序只能是"平面外、组内、拍内"。
  // ---------------------------------------------------------------------------
  when(dstPlR && (state === BypassPhase.WRRUN)) {
    switch(wgSt) {
      is(U(1, 2 bits)) {                                     // FILL：顺序读 32 个像素
        woBuf(wf) := outMem.readAsync(((wgG.resize(32) << 5) + wf.resize(32)).resize(riW))
        when(wf === U(31, 5 bits)) { wf := U(0, 5 bits); wgSt := U(2, 2 bits); wgB := U(0, 2 bits) }
          .otherwise { wf := wf + 1 }
      }
      is(U(2, 2 bits)) {                                     // EMIT：本组 4 拍
        when(ddrMaster.io.wr_valid && ddrMaster.io.wr_ready) {
          when(wgB === U(3, 2 bits)) {
            wgB := U(0, 2 bits)
            when(wgG === (wrGNum - U(1, 16 bits))) { wgSt := U(0, 2 bits) }   // 本平面发完（等主口 done）
              .otherwise { wgG := (wgG + 1).resize(16); wgSt := U(1, 2 bits); wf := U(0, 5 bits) }
          } .otherwise { wgB := (wgB + 1).resize(2) }
        }
      }
      default { }
    }
  }
  // ★ C4b-B4 观察口（零逻辑）：本拍喂给单元的列 + 该列被收下的指示（供闸门逐列逐通道对账）。
  for (ci <- 0 until C) { io.col_dbg(ci) := xCol(ci) }
  io.col_dbg_ok := colVal && unitReady

  // ---------------------------------------------------------------------------
  // 主相位 FSM
  // ---------------------------------------------------------------------------
  /** 本次运行"整条通路收工"的条件：输入喂完 **且** 单元吐完（两者都满足才算 drained）。
    * ★ R4：`inCol == inBeats` 换成等价的粘滞位 `inTail`（判据逐位不变，见 §R4）。 */
  val drained = inTail && (pixIdx === outPixR)
  /** ★★ T-S3a.2b：被受理的 `go` = **整层路径或 tile 路径**任一可用（`runStart` 只做 per-run 前态复位）。
    *   `wholeOk` 与改动前的条件**逐项相同** ⇒ 整层路径的复位时机与内容一字不变。 */
  val runStart = (state === BypassPhase.IDLE) && io.go && (wholeOk || tileOk)

  switch(state) {
    // 几何/长度对账不过 ⇒ 响亮 err、零搬运（一个 AR/AW 都不发；与 UnitExec 同形）。
    is(BypassPhase.IDLE) {
      when(io.go) {
        // ★ C4b-B4：布局模式的结构性前提（32 像素一组 / 非 Add）与几何对账**同一处**把关。
        // ★★ T-S3a.2a：多通道块要求平面通路（`blkPlanarOk`）+ 单元相位逐块可复位（`blkPhaseOk`）
        //   —— 同一条响亮 err。
        // ★★ T-S3a.2b：**运行期二选一** —— 整层合法 ⇒ 原路径（逐字节同形）；否则 tile 合法 ⇒ 走 tile；
        //   两者都不合法 ⇒ 同一条响亮 err + 零搬运。
        when(wholeOk) { state := BypassPhase.RDSTART }
        .elsewhen(tileOk) { state := BypassPhase.TILEGO }
        .otherwise { errR := True }
      }
    }
    is(BypassPhase.RDSTART) {
      // ★ C4b-B4：布局模式下 RD 的发起在 gather 子 FSM（逐平面一笔 32 B）⇒ 这一拍**不**举 start。
      ddrMaster.io.start := !srcPlR
      mMode := U(1, 2 bits)
      mSrc  := dw.srcA.resize(ddrCfg.ADDR_W)
      mDst  := dw.dstA.resize(ddrCfg.ADDR_W)
      mLen  := rdLen
      // ★ R4：**同一拍、同一依据**（`io.desc` 在本拍必须合法 —— 这本来就是 `mLen := rdLen`、
      //   `mSrc := dw.srcA` 的既有前提）把运行期的长度几何钉成寄存器，供 `RDRUN/WRRUN` 用。
      inBeatsR := inBeats
      outPixR := outPix
      // ★★ T-S3a.2c：折档写侧尾掩码的界（未上取整的有效像素数）；非折档下恒等于 `outPix`。
      outPixXR := totEff
      state := BypassPhase.RDRUN
    }
    is(BypassPhase.RDRUN) {
      when(twoSrcR) {
        // ★ E1 A 趟：A 列已全部收进 outMem（`inTail`）⇒ 等主口收尾后起 B 趟。
        when(inTail && !ddrMaster.io.busy) { state := BypassPhase.RDBSTART }
      } otherwise {
        when(drained) { state := BypassPhase.WRWAIT }
      }
    }
    // ★ E1：两趟读的 **B 趟** —— 起一笔从 `io.src2` 的 RD（长度 = 一趟 = `rdLen` = `inCols*C`）。
    //   入参在本拍（`RDBSTART`）落寄存器 ⇒ `DdrMaster` 在**下一拍**的 CHK 才读到它（与 `RDSTART` 同一条既有依据）。
    is(BypassPhase.RDBSTART) {
      mMode := U(1, 2 bits)
      mSrc  := io.src2
      mLen  := rdLen
      bCol  := U(0, 32 bits)
      state := BypassPhase.RDBRUN
    }
    is(BypassPhase.RDBRUN) {
      when(bDrained) { state := BypassPhase.WRWAIT }
    }
    is(BypassPhase.WRWAIT) {
      when(!ddrMaster.io.busy) { state := BypassPhase.WRSTART }
    }
    is(BypassPhase.WRSTART) {
      ddrMaster.io.start := True
      mMode := U(2, 2 bits)
      mSrc  := dw.srcA.resize(ddrCfg.ADDR_W)
      // ★ C4b-B4：布局模式下**每个平面一笔**事务 ⇒ 目标 = `DST + wgPl*outPix`、长度 = `outPix`。
      //   ★★ T-S3a.2a：再加本块的平面偏移 `blkDstR = blk·8·outPix`（单块恒 0 ⇒ 与改动前同值）。
      mDst  := Mux(dstPlR,
                   ((dw.dstA + blkDstR + (wgPl.resize(32) * outPixR).resize(32)).resize(ddrCfg.ADDR_W)),
                   dw.dstA.resize(ddrCfg.ADDR_W))
      mLen  := Mux(dstPlR, outPixR, wrLen)
      ri    := 0
      when(dstPlR) {
        wgSt := U(1, 2 bits); wgG := U(0, 16 bits); wf := U(0, 5 bits); wgB := U(0, 2 bits)
      }
      state := BypassPhase.WRRUN
    }
    is(BypassPhase.WRRUN) {
      when(ddrMaster.io.done) {
        // ★ C4b-B4：布局模式下本平面发完 ⇒ 若不是最后一个平面，回 `WRWAIT` 再起下一笔（`wgPl` 保留）。
        when(dstPlR && (wgPl =/= U(C - 1, plW bits))) {
          wgPl := (wgPl + 1).resize(plW)
          state := BypassPhase.WRWAIT
        } .otherwise {
          // ★★ T-S3a.2a：本块**整块跑完**（读 + 算 + 写）⇒ 还有下一块就回 `RDSTART` 再走一趟
          //   （同一套相位、另一组平面）；否则收工。`nBlk == 1` 时这条恒取 `DONE`（改动前行为）。
          when(blkNext) { state := BypassPhase.RDSTART } .otherwise { state := BypassPhase.DONE }
        }
      }
    }
    is(BypassPhase.DONE) {
      doneR := True
      state := BypassPhase.IDLE
    }
  }

  // ---------------------------------------------------------------------------
  // ★★ C4b-B4：**读侧 gather**（通道平面 → NHWC 列流）。只在布局模式下活动（`srcPlR`）：
  //   每 32 像素一组：FETCH 逐平面各发**一笔 32 B RD**（4 拍灌进 `pgBuf`），DRAIN 逐列吐出
  //   （第 `j` 列的第 `cl` 道 = `pgBuf(cl*4 + j/8)` 的第 `j%8` 个字节）。地址只用**移位与加法**。
  // ---------------------------------------------------------------------------
  /** 一趟喂列相位的起点（= `RDSTART`）。
    *   ★ 基址**必须取描述符的当前值**（`dw.srcA`）而不是寄存器 `mSrc`：`mSrc` 正是在**这一拍**被赋值
    *     （非阻塞）⇒ 读到的会是上一轮的旧值（实测签名：整个 gather 的基址落到 0，于是每个平面读到
    *     的是**前一个平面**的数据、平面 0 读到 0 —— 逐列"整体少一个通道"）。 */
  val pgTripGo = srcPlR && (state === BypassPhase.RDSTART)
  when(pgTripGo) {
    pgSt := U(1, 2 bits); pgK := False; pgPl := U(0, plW bits); pgB := U(0, 2 bits)
    pgG  := U(0, 16 bits); pgJ := U(0, 5 bits)
    // ★★ T-S3a.2a：本趟的**平面 0 基址** = `SRC + blkSrcR`（`blkSrcR = blk·8·inCols`）——
    //   组内第 `c` 个平面的地址仍由 `+= inColsR` 递推 ⇒ 平面 `8·blk + c` 落在
    //   `SRC + (8·blk+c)·inCols + g·32`（**与冻结的 NCHW 平面布局逐字节一致**）。单块恒 0。
    pgPlane0 := (dw.srcA.resize(32) + blkSrcR).resize(32)   // 组 0 的**平面 0** 地址
    pgAddrR  := (dw.srcA.resize(32) + blkSrcR).resize(32)
    for (i <- 0 until C * 4) { pgBuf(i) := B(0, 64 bits) }
  } otherwise {
    when(srcPlR) {
      switch(pgSt) {
        is(U(1, 2 bits)) {                            // FETCH：逐平面一笔 32 B RD
          when(pgK === False) {
            when(!ddrMaster.io.busy) { pgK := True }  // 本拍 `pgStartPulse` 举 start
          } otherwise {
            when(ddrMaster.io.rd_valid) {
              pgBuf(pgWrIdx) := ddrMaster.io.rd_data
              pgB := (pgB + 1).resize(2)
            }
            when(ddrMaster.io.done) {
              pgB := U(0, 2 bits)
              when(pgPl === U(C - 1, plW bits)) {
                pgSt := U(2, 2 bits); pgJ := U(0, 5 bits)          // C 个平面收齐 ⇒ 逐列 drain
              } otherwise {
                pgPl := (pgPl + 1).resize(plW); pgK := False
                pgAddrR := (pgAddrR + inColsR).resize(32)          // 下一平面 = +H*W（**只有加法**）
              }
            }
          }
        }
        is(U(2, 2 bits)) {                            // DRAIN：一拍一列，直到被单元收下
          when(pgColTaken) {
            when(pgJ === U(31, 5 bits)) {
              pgJ := U(0, 5 bits)
              when(pgG === (pgGNum - U(1, 16 bits))) { pgSt := U(0, 2 bits) }   // 本趟喂完
                .otherwise {
                  pgG := (pgG + 1).resize(16); pgPl := U(0, plW bits); pgK := False
                  pgSt := U(1, 2 bits)
                  // 下一组的**平面 0** 地址 = 本趟基址（`pgPlane0` 寄存器，本趟内恒定）+ 32
                  pgAddrR := (pgPlane0 + ((pgG + U(1, 16 bits)) << 5)).resize(32)
                }
            } otherwise { pgJ := (pgJ + 1).resize(5) }
          }
        }
        default { }
      }
    }
  }

  // err：透传（单拍）+ 立刻放弃本次执行（回 IDLE；后续可重试）。
  when(ddrMaster.io.err) {
    errR  := True
    state := BypassPhase.IDLE
  }

  // ===========================================================================
  // ★★ T-S3a.2b：**空间 tile 循环**（`TILEGO` / `TILERD` / `TILEWR`；写在主 FSM 之后 ⇒ 覆盖主口入参）
  //   契约/口径见文件头 §T-S3a.2b + ★★ T-S3e（per-plane band）。三句话：
  //     · `TILERD`：**逐输入行**发 32 B 对齐的窗口读 —— ★ T-S3e 起**每个平面各算自己的**
  //       `(chunk 序, band 内下标)`（`tPhP/tIdxP/tLdK`，复用 `pgBuf` 与 C4b-B4 的转置下标），
  //       drain 前只补取"该用的 chunk 还没装"的那些平面，再按 `tDj`（本行列序 0..`tRowW`）逐列 drain；
  //     · `TILEWR`：**每 (平面, 输出行) 一笔** 32 B 对齐 + `wstrb` 掩码 burst（段 = `tTwR` 字节）；
  //     · 一个 tile 的读/算/写跑完 ⇒ 推进 tile 网格（先 x 后 y）；y 推完 ⇒ 推进通道块（2a）或收工。
  //   `tilingR = 0` ⇒ 下面每一个 `when` 都恒假 ⇒ 既有整层路径**逐字节不变**。
  // ===========================================================================
  val tRdOn = tilingR && (state === BypassPhase.TILERD)
  val tWrOn = tilingR && (state === BypassPhase.TILEWR)
  // ---- ★★ T-S3e：本行窗口的 **per-plane** chunk 几何（组合；账本 `tPhP/tIdxP/tLdK/tChk` 见上面 §T-S3e）----
  /** 本平面本笔 32 B 突发的地址 = 该平面本行窗口起点（累加器 `tAdrR`）`& ~31` + `chunk 序 << 5`。
    *   `& ~31` ⇒ **恒 32 B 对齐**（突发合法 —— 各平面相位不同也各自对齐，这正是旧共享口径给不了的）；
    *   两趟共用同一个式子：行首 `tDj == 0` ⇒ `chunk 序 = 0` = chunk0；drain 中途补取 ⇒ `chunk 序` =
    *   该平面**本列**该用的那个（见 `tIdxP(tPl)[6:5]`）。 */
  val tBstC = ((tAdrR & U(0xFFFFFFE0L, 32 bits)) + (tIdxP(tPl)(6 downto 5).resize(32) << 5)).resize(32)
  /** ★ B1'b：SG 入队扫描时的同一式子，但平面取**扫描指针** `tSgScan`（`tAdrR` 已推进到该平面）。 */
  val tBstS = ((tAdrR & U(0xFFFFFFE0L, 32 bits)) +
               (tIdxP(tSgScan(2 downto 0))(6 downto 5).resize(32) << 5)).resize(32)
  /** 本 chunk 的 fetch 落点（与 C4b-B4 的 gather **同一张 `pgBuf`、同一套下标**）。 */
  val pgWrIdxT = ((tPl @@ U(0, 2 bits)) + tBe.resize(5)).resize(5)
  /** ★ T-S3e：FETCH 的**逐平面推进**（"取完"与"跳过"共用一处收尾）：末平面 ⇒ 回 drain；否则换平面
    *   （地址累加器 `+= inColsR` —— **被跳过的平面也照推**，否则后面各平面的地址就错位了）。 */
  def tPlAdvT(): Unit = {
    when(tPl === U(C - 1, 3 bits)) { tRdSt := U(2, 2 bits); tBK := False }
      .otherwise { tPl := (tPl + 1).resize(3); tAdrR := (tAdrR + inColsR).resize(32); tBK := False }
  }
  // ---- 写相位：本笔的几何 / 掩码 / 载荷（组合）----
  /** 本笔的段起点在本笔 burst 内的偏移 = **当前**目标地址的低 5 位。
    *   ⚠ 必须取 `tCurA` 的**组合**切片：本片实测踩过一个坑 —— 早先把它锁在一个 `tBoff` 寄存器里、
    *   与 `tBlR` 在 `tWrSt==0` 那一拍**同时**赋值 ⇒ 用 `tBoff` 算长度时读到的是**上一笔**的偏移
    *   （签名：长度整笔错位一格，`wstrb` 把段外的字节写进邻居）。该寄存器已删（只用组合切片）。 */
  val tBoffC = tCurA(4 downto 0)
  /** 本笔 burst 的字节数 = `ceil32(段内偏移 + 段长)`（32 的正整数倍；≤ 96）。 */
  val tLenC = (((tBoffC.resize(8) + tTwR.resize(8)) + U(31, 8 bits)) >> 5) << 5
  val tNbC  = (tLenC >> 3).resize(4)
  /** 段内字节 `8·tWB + l`（burst 内字节序 0..103）与"是否在段内"的判定。
    *   ⚠ **全部走无符号**（`UInt` 的 `resize` 零扩展）：段内偏移 `tBoffC` 是 5 位、取值可到 31 ——
    *   本片实测踩过第二个坑：写成 `tBoff.asSInt.resize(9)` 时，31 个取值里 bit4 为 1 的那些（16..31）
    *   会被当成**负数**（签名：`off ≥ 16` 的段被整段掩掉 ⇒ 那些输出行一个字节都没写）。
    *   ⇒ `k - tBoff` 的**下溢**由 `k >= tBoff` 的与项挡住（减运算只在被掩掉时发生，结果不用）。 */
  val tWb9S  = (tWB.resize(9) << 3).resize(9)
  val tBoff9 = tBoffC.resize(9)
  val tTwR9  = tTwR.resize(9)
  val tKkB   = (0 until 8).map(l => (tWb9S + U(l, 9 bits)).resize(9))
  val tInS   = tKkB.map(k => (k >= tBoff9) && ((k - tBoff9) < tTwR9))
  /** 段内序（burst 内字节序 − 段起点）；无效时下溢成一个大数 ⇒ 被 `tInS` 掩掉。 */
  val tIdxS  = tKkB.map(k => (k - tBoff9))
  /** 本拍的 64 位载荷（第 `l` 个字节 = 段内第 `8·tWB+l` 个字节；`Cat` 把第一个元素当**最低字节**）。 */
  val tPackS = Cat((0 until 8).map(l => Mux(tInS(l), tRowB(tIdxS(l)(4 downto 0)), B(0, 8 bits))))
  val tStrbS = Cat((0 until 8).map(l => tInS(l)))
  /** 行段填充：本像素的**第 `tWrP` 道**（一个像素的 C 个通道在 `outMem` 里是一字）。 */
  val tMemW  = outMem.readAsync(((tIdxR.resize(riW) + tFk.resize(riW))).resize(riW))
  val tByteC = (0 until C).map(k => Mux(tWrP === U(k, 3 bits), tMemW(k * 8 + 7 downto k * 8), B(0, 8 bits))).reduce(_ | _)

  when(tRdOn) {
    tSgGo := False                     // ★ B1'b：`start(mode=3)` 只准一拍（扫描收尾处再举）
    switch(tRdSt) {
      is(U(0, 2 bits)) {                              // ROW SETUP（1 拍）：本行账本清零 + 窗口起点归位
        tRdSt := U(1, 2 bits); tPl := U(0, 3 bits); tBe := U(0, 2 bits); tBK := False
        tDj := U(0, 7 bits)                           // ★ T-S3e：本行列序从 0 起（旧口径是 band 内字节序）
        for (p <- 0 until C) { tLdK(p) := U(3, 2 bits) }   // ★ T-S3e：本行还没装任何 chunk（哨兵 3）
        tAdrR := (tSrcE + tPixR).resize(32)           // ★ T-S3e：本行窗口起点的**未对齐** acc（逐平面 += inColsR）
        tSgScan := U(0, 4 bits); tSgEnq := U(0, 4 bits); tSgRd := False; tSgGo := False
        tSgMask := B(0, C bits); tSgDrn := ddrMaster.io.busy
      }
      is(U(1, 2 bits)) {                              // FETCH：缺自己 chunk 的平面才取
        when(!tSgOk) {
          // ---- 老路（`inCols % 32 != 0`；真表里只有 Resize_43）**逐字保留** ----
          when(tBK === False) {
            when(!ddrMaster.io.busy) {
              when(tChk(tPl)) { tBK := True }         // 本拍举本平面的 `start`
                .otherwise { tPlAdvT() }              // ★ T-S3e：已装好 ⇒ 跳过（1 拍/平面）
            }
          } otherwise {
            when(ddrMaster.io.rd_valid) {
              pgBuf(pgWrIdxT) := ddrMaster.io.rd_data
              tBe := (tBe + 1).resize(2)
            }
            when(ddrMaster.io.done) {
              tBe := U(0, 2 bits)
              tLdK(tPl) := tIdxP(tPl)(6 downto 5)
              tPlAdvT()
            }
          }
        } otherwise {
          // ---- ★ B1'b：SG 批式（8 平面相位相同 ⇒ band 边界重合，T-S3a.2b 前提）----
          when(tSgDrn) {                              // 进门排空残留一笔（`done` 或主口已空任一即可收尾）
            when(ddrMaster.io.done || !ddrMaster.io.busy) {
              tSgDrn := False; tSgScan := U(0, 4 bits); tSgEnq := U(0, 4 bits)
              tSgMask := B(0, C bits); tAdrR := (tSrcE + tPixR).resize(32)
            }
          } elsewhen(!tSgRd) {                        // 入队扫描：一拍一平面（`sg_ready` 自然反压）
            when(tSgScan === U(C, 4 bits)) {
              when(tSgEnq =/= U(0, 4 bits)) { tSgRd := True; tSgGo := True; tBe := U(0, 2 bits) }
                .otherwise { tRdSt := U(2, 2 bits) }  // 本列无需补取 ⇒ 直接回 drain
            } otherwise {
              when(tChk(tSgScan(2 downto 0))) {
                when(ddrMaster.io.sg_ready) {
                  tSgPl(tSgEnq(2 downto 0)) := tSgScan(2 downto 0)
                  tSgCh(tSgEnq(2 downto 0)) := tIdxP(tSgScan(2 downto 0))(6 downto 5)
                  tSgMask(tSgScan(2 downto 0)) := True
                  tSgEnq := (tSgEnq + 1).resize(4)
                  tSgScan := (tSgScan + 1).resize(4)
                  tAdrR := (tAdrR + inColsR).resize(32)
                }
              } otherwise {
                tSgScan := (tSgScan + 1).resize(4)
                tAdrR := (tAdrR + inColsR).resize(32)
              }
            }
          } otherwise {                               // 整批 RD：4 拍/项，按**项序**落 `pgBuf`
            when(ddrMaster.io.rd_valid) {
              pgBuf(((tSgPl(tPl).resize(5) << 2) + tBe.resize(5)).resize(5)) := ddrMaster.io.rd_data
              tBe := (tBe + 1).resize(2)
              when(tBe === U(3, 2 bits)) { tPl := (tPl + 1).resize(3) }
            }
            when(ddrMaster.io.done) {
              for (p <- 0 until C) { when(tSgMask(p)) { tLdK(p) := tSgCh(p) } }   // 入队快照落账
              tSgRd := False; tSgGo := False; tSgMask := B(0, C bits)
              tSgScan := U(0, 4 bits); tSgEnq := U(0, 4 bits)
              tPl := U(0, 3 bits); tBe := U(0, 2 bits)
              tRdSt := U(2, 2 bits)
            }
          }
        }
      }
      is(U(2, 2 bits)) {                              // DRAIN：本行的列逐拍喂（被单元收下才推进）
        when((tDj =/= tRw7) && tNeedC) {              // ★ T-S3e：本列有平面缺 chunk ⇒ 先起一趟补取
          tPl := U(0, 3 bits); tBe := U(0, 2 bits); tBK := False
          tAdrR := (tSrcE + tPixR).resize(32)
          tSgScan := U(0, 4 bits); tSgEnq := U(0, 4 bits); tSgRd := False; tSgGo := False
          tSgMask := B(0, C bits); tSgDrn := ddrMaster.io.busy
          tRdSt := U(1, 2 bits)
        } .elsewhen(tDj === tRw7) {                   // 本行喂完 ⇒ 下一行 / 等本 tile 的输出收齐
          tRow  := (tRow + 1).resize(16)
          tPixR := (tPixR + inW32).resize(32)         // 下一输入行
          when((tRow + 1).resize(16) === tNRR) { tRdSt := U(3, 2 bits) }
            .otherwise { tRdSt := U(0, 2 bits) }
        }
      }
      is(U(3, 2 bits)) {                              // 等本 tile 的输出收齐（单元出料可能滞后几拍）
        when(tPixN === tPixT) {
          // ★★ T-S3a.2d：`Add` 的 **A 趟收齐**（`outMem[0..tPixT)` = 本 tile 的 A）⇒ 起 **B 趟**：
          //   同一 tile、同一网格，只把读源换成 `io.src2`（`tPass` 选 `tSrcE`），行/产出序归零。
          //   ★ 非 `Add`（`!isAdd` 或 `tPass` 已为真）⇒ 原分支，一字不改。
          when(isAdd && !tPass) {
            tPass := True
            tRow  := U(0, 16 bits); tRdSt := U(0, 2 bits)
            tPixR := (tYBRd + tXOfs).resize(32)        // 本 tile 第一行的窗口起点（与 TILEGO 同值）
            tPixN := U(0, 32 bits)
            tPl   := U(0, 3 bits); tBe := U(0, 2 bits); tBK := False
            tDj   := U(0, 7 bits); tAdrR := U(0, 32 bits)
          } .otherwise {
            // ★ 前置：本 tile 的输出**必须**收齐（`tPixN == tPixT` 就是判据）⇒ 开写相位。
            state := BypassPhase.TILEWR
            tWrQ := U(0, 16 bits); tWrP := U(0, 3 bits); tWrSt := U(0, 2 bits)
            tFk := U(0, 6 bits); tWB := U(0, 4 bits); tIdxR := U(0, riW bits)
            tRowA := (tYBWr + tOxR.resize(32)).resize(32)
            tCurA := (tDstR + tYBWr + tOxR.resize(32)).resize(32)
          }
        }
      }
      default { }
    }
    /** drain 推进：一列**被单元收下**才 +1（与 C4b-B4 的 `pgColTaken` 同一纪律）。 */
    when(tileColVal && unitReady) { tDj := (tDj + 1).resize(7) }
    // 主口：逐平面一笔 32 B RD（`mode=1`；`dst` 不参与 ⇒ 给 0，与 gather 同一条）。
    ddrMaster.io.start := Mux(tSgOk,
      (tRdSt === U(1, 2 bits)) && tSgGo,
      (tRdSt === U(1, 2 bits)) && (tBK === False) && tChk(tPl) && !ddrMaster.io.busy)
    ddrMaster.io.mode  := Mux(tSgRd, U(3, 2 bits), U(1, 2 bits))
    ddrMaster.io.src   := tBstC.resize(ddrCfg.ADDR_W)
    ddrMaster.io.dst   := U(0, ddrCfg.ADDR_W bits)
    ddrMaster.io.len   := U(32, 32 bits)
    ddrMaster.io.sg_valid   := tSgOk && (tRdSt === U(1, 2 bits)) && !tSgDrn && !tSgRd &&
                               (tSgScan < U(C, 4 bits)) && tChk(tSgScan(2 downto 0))
    ddrMaster.io.sg_addr    := tBstS.resize(ddrCfg.ADDR_W)
    ddrMaster.io.sg_flush   := False
    ddrMaster.io.sg_beatsM1 := U(3, 4 bits)
  }

  when(tWrOn) {
    switch(tWrSt) {
      is(U(0, 2 bits)) {                              // SETUP：算本笔几何（本拍同时举 `start`）
        tBstR := (tCurA & U(0xFFFFFFE0L, 32 bits)).resize(32)
        tBlR  := tLenC.resize(32)
        tNb   := tNbC
        tWrSt := U(1, 2 bits); tFk := U(0, 6 bits); tWB := U(0, 4 bits)
      }
      is(U(1, 2 bits)) {                              // 填 32 B 行段（本输出行的 `tTwR` 个字节）
        when(tFk < tTwR.resize(6)) {
          tRowB(tFk(4 downto 0)) := tByteC
          tFk := (tFk + 1).resize(6)
        } .otherwise { tWrSt := U(2, 2 bits); tWB := U(0, 4 bits) }
      }
      is(U(2, 2 bits)) {                              // EMIT：本笔 `tNb` 拍（掩码 + 载荷）
        when(tWB < tNb) {
          when(ddrMaster.io.wr_ready) {
            when(tWB === (tNb - U(1, 4 bits))) { tWrSt := U(3, 2 bits) }
              .otherwise { tWB := (tWB + 1).resize(4) }
          }
        } .otherwise { tWrSt := U(3, 2 bits) }
      }
      is(U(3, 2 bits)) {                              // 等本笔落地 ⇒ 换平面 / 换行 / 推进 tile
        when(ddrMaster.io.done) {
          when(tWrP === U(C - 1, 3 bits)) {
            tWrP := U(0, 3 bits)
            when(tWrQ === (tThR - U(1, 16 bits))) {   // 本 tile 最后一行也写完了 ⇒ 推进 tile 网格
              tWrSt := U(0, 2 bits)
              when(tTx === (tNtx - U(1, 16 bits))) {
                tTx := U(0, 16 bits)
                when(tTy === (tNty - U(1, 16 bits))) {
                  // 本块的**全部 tile** 跑完 ⇒ 推进通道块（2a）或收工
                  when(blkNext) {
                    blk     := blk + 1
                    blkSrcR := (blkSrcR + (inColsR << 3).resize(32)).resize(32)
                    blkDstR := (blkDstR + (outPixR << 3).resize(32)).resize(32)
                    tTx := U(0, 16 bits); tTy := U(0, 16 bits)
                    tYBRd := U(0, 32 bits); tYBWr := U(0, 32 bits)
                    state := BypassPhase.TILEGO
                  } .otherwise { state := BypassPhase.DONE }
                } .otherwise {
                  tTy   := (tTy + 1).resize(16)
                  tYBRd := (tYBRd + tYBAdv).resize(32)     // 下一 y 带：读侧 += A·inW
                  tYBWr := (tYBWr + tYWAdv).resize(32)     //             写侧 += TILE_H·IMG_W
                  state := BypassPhase.TILEGO
                }
              } .otherwise { tTx := (tTx + 1).resize(16); state := BypassPhase.TILEGO }
            } .otherwise {
              tWrQ  := (tWrQ + 1).resize(16)
              tRowA := (tRowA + imgW32).resize(32)
              tCurA := (tDstR + tRowA + imgW32).resize(32)
              tIdxR := (tIdxR + tTwR.resize(riW)).resize(riW)
              tWrSt := U(0, 2 bits)
            }
          } .otherwise {
            tWrP  := (tWrP + 1).resize(3)
            tCurA := (tCurA + outPixR).resize(32)          // 下一平面 = + 平面字节数
            tWrSt := U(0, 2 bits)
          }
        }
      }
      default { }
    }
    // 主口：本笔 `32 B 对齐 + wstrb 掩码` burst（`mode=2`；`src` 不参与 ⇒ 用描述符的合法 32 B 对齐值）
    ddrMaster.io.start    := (tWrSt === U(0, 2 bits))
    ddrMaster.io.mode     := U(2, 2 bits)
    ddrMaster.io.src      := dw.srcA.resize(ddrCfg.ADDR_W)
    ddrMaster.io.dst      := tBstR.resize(ddrCfg.ADDR_W)
    ddrMaster.io.len      := tBlR
    ddrMaster.io.wr_valid := (tWrSt === U(2, 2 bits)) && (tWB < tNb)
    ddrMaster.io.wr_data  := tPackS
    ddrMaster.io.wstrb    := tStrbS
  }

  // `TILEGO`：一个 tile 的**起点**（闩存本 tile 的几何；1 拍）。放在最后 ⇒ 覆盖上面的默认值。
  when(tilingR && (state === BypassPhase.TILEGO)) {
    tOxR  := tOxC; tOyR := tOyC; tTwR := tTwC; tThR := tThC
    tRowW := tNCC; tNRR := tNRC
    tPixR := (tYBRd + tXOfs).resize(32)                // 本行窗口起点（第一行）
    tSrcR := (dw.srcA.resize(32) + blkSrcR).resize(32)
    // ★★ T-S3a.2d：**B 源**（`io.src2`）的平面 0 基址 = `io.src2 + blkSrcR`（与 A 源**同一个**块偏移）
    //   ⇒ `Add` 的 B 趟享有同一套通道块偏移；非 `Add` 的 tile 只 latch、永不被选中。
    tSrc2R := (io.src2.resize(32) + blkSrcR).resize(32)
    tDstR := (dw.dstA.resize(32) + blkDstR).resize(32)
    tPixT := (tTwC.resize(16) * tThC.resize(16)).resize(32)
    tPass := False                                    // ★ 2d：每个 tile 都从 **A 趟**起
    tRdSt := U(0, 2 bits); tRow := U(0, 16 bits)
    tPl := U(0, 3 bits); tBe := U(0, 2 bits); tBK := False
    tDj := U(0, 7 bits); tPixN := U(0, 32 bits)       // ★ T-S3e：tDj 是"本行列序"（账本 tLdK 由行设置清）
    tAdrR := U(0, 32 bits)
    tWrQ := U(0, 16 bits); tWrP := U(0, 3 bits); tWrSt := U(0, 2 bits)
    tFk := U(0, 6 bits); tWB := U(0, 4 bits); tNb := U(0, 4 bits)
    tIdxR := U(0, riW bits); tRowA := U(0, 32 bits); tCurA := U(0, 32 bits)
    tBstR := U(0, 32 bits); tBlR := U(0, 32 bits)
    state := BypassPhase.TILERD
  }

  // ---------------------------------------------------------------------------
  // ★★ T-S3a.2a：**块推进**（本块的 WR 全部发完、且**还有下一块**的那一拍）
  // ---------------------------------------------------------------------------
  //   做三件事：块号 +1；两个平面偏移各 += 本块平面大小（`8·inCols` / `8·outPix`）；
  //   把"本次运行的前态"按 `runStart` 的**同一组**值清回（下一块要从头读/从头写 `outMem`）。
  //   ★ 等价性（`cIn == 8` ⇒ `cBlkOk` 保证 `nBlkR == 1` ⇒ `blkNext == False` ⇒ 本脉冲**恒 0**）：
  //     下面每一条赋值在单块作业里**一次都不发生** ⇒ 单块路径与改动前逐字节同形。
  //   ★ 逐块复用的寄存器：`inColsR`（块内平面大小）与 `outPixR` 在 `RDSTART` 会被**同值重锁**
  //     （描述符整段运行期间不变，这是既有前提）⇒ 偏移累加器不会漂移。
  val blkAdvance = (state === BypassPhase.WRRUN) && ddrMaster.io.done &&
                   !(dstPlR && (wgPl =/= U(C - 1, plW bits))) && blkNext
  when(blkAdvance) {
    blk     := blk + 1
    blkSrcR := (blkSrcR + (inColsR << 3).resize(32)).resize(32)   // + 8 个平面 × inCols 字节
    blkDstR := (blkDstR + (outPixR << 3).resize(32)).resize(32)   // + 8 个平面 × outPix 字节
    // 与 `runStart` 同一组前态（值相同）：读相位列序 / 输出像素序 / WR 读序号 / 喂料末端 / 写平面。
    inCol  := U(0, 32 bits)
    pixIdx := U(0, 32 bits)
    ri     := U(0, 32 bits)
    inTail := False
    wgPl   := U(0, plW bits)
  }

  // ---------------------------------------------------------------------------
  // per-run 复位（每次被受理的 `go` 一拍，把本次运行的前态清回上电值 ⇒ 可重入）
  // ---------------------------------------------------------------------------
  when(runStart) {
    inCol  := U(0, 32 bits)
    pixIdx := U(0, 32 bits)
    ri     := U(0, 32 bits)
    // ★ R4：喂料末端粘滞位必须与 `inCol` **同拍**清（两者是一对：`inTail ⇔ inCol == inBeats`）。
    //   `inBeatsR`/`outPixR` 不必清 —— 它们在 `RDSTART` 必被覆写（`RDRUN` 之前）。
    inTail := False
    mMode  := U(1, 2 bits)
    mSrc   := U(0, ddrCfg.ADDR_W bits)
    mDst   := U(0, ddrCfg.ADDR_W bits)
    mLen   := U(0, 32 bits)
    for (ci <- 0 until C) { aReg(ci) := S(0, 8 bits) }
    // ★★ C4b-B4：布局模式的 per-run 前态（同一拍清回；模式位在**这一拍**锁存 ⇒ 运行期只用寄存器）。
    // ★★ T-S3a.2c：锁存的是**有效**模式位（折档强制线性 ⇒ 两位为 0；见文件头 §T-S3a.2c）。
    srcPlR  := srcPlEff
    dstPlR  := dstPlEff
    inColsR := inCols
    // ★ E1：两趟读标志 / B 趟列序（同一拍清回并锁存；`addTwoSrc` 由 `io.desc` 组合译出）。
    twoSrcR := addTwoSrc
    bCol    := U(0, 32 bits)
    pgSt := U(0, 2 bits); pgK := False; pgPl := U(0, plW bits); pgB := U(0, 2 bits)
    pgG  := U(0, 16 bits); pgJ := U(0, 5 bits)
    wgSt := U(0, 2 bits); wgPl := U(0, plW bits); wgG := U(0, 16 bits); wgB := U(0, 2 bits)
    wf   := U(0, 5 bits)
    // ★★ T-S3a.2a：通道分块的 per-run 前态（`nBlkR` 锁存 = `cIn/8`；块号与两个偏移归零）。
    nBlkR   := nBlk
    blk     := U(0, 16 bits)
    blkSrcR := U(0, 32 bits)
    blkDstR := U(0, 32 bits)
    // ★★ T-S3a.2b：tile 的 per-run 前态（`tilingR` 锁存 = 二选一的判决；网格与两个 y 带基址归零）。
    //   ★ `outPixR` 在这里也锁一次（与 `RDSTART` 的锁存**同值** —— 描述符整段运行不变，这是既有前提）
    //     ⇒ 整层路径的波形一字不变（`outPixR` 的每一处读都发生在 `RDSTART` 之后）。
    tilingR := tileOk && !wholeOk
    tTx     := U(0, 16 bits)
    tTy     := U(0, 16 bits)
    tNtx    := Mux(isPool, (imgW32 + U(TWP - 1, 32 bits)) / U(TWP, 32 bits),
                   Mux(isRz, (imgW32 + U(TWR - 1, 32 bits)) / U(TWR, 32 bits),
                            (imgW32 + U(TWA - 1, 32 bits)) / U(TWA, 32 bits))).resize(16)
    tNty    := ((imgH32 + U(TILE_H - 1, 32 bits)) / U(TILE_H, 32 bits)).resize(16)
    tYBRd   := U(0, 32 bits)
    tYBWr   := U(0, 32 bits)
    // ★★ T-S3a.2d：`Add` 的两趟前态（`tPass = False` = A 趟起；B 源基址在 `TILEGO` 重闩）。
    tPass   := False
    tSrc2R  := U(0, 32 bits)
    outPixR := outPix
  }

  // ---------------------------------------------------------------------------
  // 状态 / 遥测
  // ---------------------------------------------------------------------------
  io.busy     := (state =/= BypassPhase.IDLE)
  io.done     := doneR
  io.err      := errR
  io.rd_bytes := ddrMaster.io.rd_bytes
  io.wr_bytes := ddrMaster.io.wr_bytes
  io.opMode   := Mux(isPool, U(0, 2 bits),
                 Mux(isRz,   U(1, 2 bits),
                 Mux(isAdd,  U(2, 2 bits), U(3, 2 bits))))
}
