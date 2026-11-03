import spinal.core._
import spinal.lib._
import spinal.lib.bus.amba4.axi._

/** 单元序列 FSM 的状态（显式枚举 ⇒ 生成 Verilog 里就是一个 `SchedState` 型寄存器）。
  *
  *   IDLE      —— 等 `go`（单拍脉冲语义，与 DdrMaster.start / DescFetch.go 同口径）；
  *   TAILCHK   —— **先**取「第 `descCount` 项」（`descAddr + descCount*32`）＝ 期望的**表尾哨兵**位置；
  *   TAILCHKW  —— 等该次取表回值：**必须是 0xFF 哨兵**，否则 `descCount` 与哨兵不符 ⇒ 响亮 `err`（**零搬运**）；
  *   FETCH     —— 取第 `idx` 项（`idx = 0..descCount-1`）的 32 B 描述符；
  *   FETCHW    —— 等回值：哨兵出现在载荷里 ⇒ `err`（COUNT 与哨兵不符）；否则按 `FLAGS[1:0]` + TYPE 分派；
  *   CHAINSCAN —— 【A-1b】链扫描：取**下一项**（`idx + chainCnt`）看它是不是 `middle`/`tail`；
  *   CHAINSCANW—— 【A-1b】等回值：`middle` ⇒ 继续扫；`tail` ⇒ 链扫完（`chainLen` 定案）去 `RUNSTART`；
  *                其余（plain/head/哨兵/非 conv/保留位非 0）⇒ **响亮 err**（head 没有 tail / 链断裂）；
  *   RUNSTART  —— 把 `UnitExec.go` 举**一拍**（等 `!unitExec.busy` 之后才举，守住"单拍 go + busy 覆盖在途"契约）；
  *   RUNW      —— 等 `UnitExec.done`（单拍）或 `.err`（单拍）；
  *   BYPSTART  —— 【C3.10b】旁路项（maxpool/resize/add/sigmoid）：等 `BypassExec.busy==0` 后把它的 `go` 举一拍；
  *   BYPW      —— 【C3.10b】等 `BypassExec.done`（单拍）或 `.err`（单拍）；
  *   NEXT      —— `idx+chainLen == descCount` ⇒ FRAMEDONE；否则 `idx+chainLen` 回到 FETCH；
  *   FRAMEDONE —— `frameDone` 举**一拍**（**整帧唯一**），回 IDLE。
  *
  * ★★ IRQ 纪律（本片的核心判据）：`frameDone` 只在 FRAMEDONE 态抬一拍 —— **帧内任何一个单元跑完都不抬**。
  *    真源见 `docs/superpowers/specs/2026-10-09-y1-c3-scheduler-design.md` §5 的 S4 与
  *    `docs/superpowers/plans/2026-10-09-y1-c3-scheduler.md` Task C3.10（"frameDone 只在整帧末尾抬一次"）。
  */
object SchedState extends SpinalEnum {
  val IDLE, TAILCHK, TAILCHKW, FETCH, FETCHW, CHAINSCAN, CHAINSCANW, RUNSTART, RUNW,
      BYPSTART, BYPW, NEXT, FRAMEDONE = newElement()
}

/** =====================================================================================
  * C3.10a `LayerSched` —— **单元序列 FSM**：主机在 DDR 写一张**描述符表**，本 FSM 自己走表，
  * 每一项取表（`DescFetch`，32 B/项、RD 模式）→ 译码（`DescDefs.DescWords`）→ 分派给
  * `UnitExec`（conv：`SRC_ADDR` -> conv -> `DST_ADDR`，**一次 `go` 一个单元**），走完**整表**之后
  * 抬**一次** `frameDone`（单拍脉冲，交给调用方锁成保持电平作 IRQ）。
  * =====================================================================================
  *
  * ---------------------------------- 走表纪律（与 S4 spec / 计划 C3.10 对齐） ----------------------------------
  *   · **执行序 = 表序**：`idx` 从 0 起，逐项取表；每项译码后按 `TYPE` 分派。
  *   · **表尾哨兵**：`TYPE == 0xFF`（`DescDefs.DescType.SENTINEL`）。表是
  *       `[unit0, unit1, ..., unit(descCount-1), SENTINEL]`
  *     ⇒ `descCount` = **载荷项数（不含哨兵）**，哨兵**必须**落在下标 `descCount` 上。
  *   · **`descCount` 与哨兵自洽 ⇒ 否则响亮 `err` + 零搬运**（spec §5 S6 的"COUNT 与哨兵不符"这一条：
  *     本片先落它，其余非法表规则归 C3.11）。**做法**：进表之前**先**取下标 `descCount` 项，
  *     它**必须**是哨兵 —— 不是 ⇒ `descCount` 比真实载荷少/多 ⇒ **当场 `err`，一个单元都没跑**
  *     （这就是"零搬运"）：直接命中"`descCount` 比真实项数**少 1**"这条负对照（见闸门负对照 B）。
  *     走表途中若**提前**撞见哨兵（下标 `< descCount`）⇒ 也是 COUNT 与哨兵不符 ⇒ `err`。
  *   · **一个单元一次 `go`**：`UnitExec` 是"可重入"的（C3.8 的 per-run 复位 + C3.9 的 `conv.io.prime`），
  *     所以本 FSM 对每个载荷项各抬一次 `UnitExec.go`，并等它的 `done`（单拍）再取下一项。
  *
  * ---------------------------------- ★ A-1b：per-operator 链式编码 + **塌缩成一次 `go`** ----------------------------------
  *   A-1b 把描述符的 `FLAGS` 改成**逐算子**的链式编码（`FLAGS[7:2]` 收回保留、必须为 0）：
  *
  *     | FLAGS | 名字   | 含义                                                            |
  *     |-------|--------|-----------------------------------------------------------------|
  *     | 0b00  | head   | 输入取 DDR(`srcA`)，输出**留在片上**（进链的第一块中间缓冲）      |
  *     | 0b01  | plain  | 输入取 DDR(`srcA`)，输出落 DDR(`dstA`)（= 既有的 S2 通路）        |
  *     | 0b10  | middle | 输入取**上一个算子的片上输出**，输出**留在片上**                  |
  *     | 0b11  | tail   | 输入取**上一个算子的片上输出**，输出落 DDR(`dstA`)                |
  *
  *   **一条链** = 一段**极大**的相邻条目序列：每个条目的 `FLAGS` 是 head/middle，且它的**后继**是
  *   middle/tail（即"片上那根连线在序列里一直成立"）。链长 = 序列长度；链的 `SRC` = **链首**的
  *   `SRC_ADDR`、`DST` = **链尾**的 `DST_ADDR`。链上各切片的 `C/W/H`（以及 `GROUP`/`QUANT_SHIFT`）
  *   必须相同（这正是"融合"的含义），但 `TYPE`（3x3 / 1x1）与**权重**可以逐片不同。
  *
  *   ---- 本 FSM 干什么 ----
  *   取到一项之后按 `TYPE` + `FLAGS[1:0]` 分派：
  *   · **plain（`0b01`）**：一次 `go`（`chainLen=1`），`UnitExec` 走 S2 档（`srcA` -> DDR(`dstA`)）。
  *   · **head（`0b00`）**：**向前扫**（一项一项取回来）直到撞上 `tail`（`0b11`）—— 中间只允许 `middle`
  *     （`0b10`）。扫描结束时**塌缩成一次 `go`**：`chainLen` = 链长（独立入参给 `UnitExec`）、
  *     `SRC` = 链首的、`DST` = **链尾的**（本 FSM 把链首的 8 个字锁存下来、只把 `w5` 换成链尾的
  *     `DST_ADDR`，凑成 `UnitExec` 要的"链描述符"；见 `UnitExec.scala` 文件头）。
  *   · **旁路项**（maxpool/resize/add/sigmoid）：同 C3.10b，交 `BypassExec`，一次 `go`。
  *
  *   ---- 响亮 `err`（**零设备搬运**；每条都是"不许静默"）----
  *   · `FLAGS[7:2] != 0`（保留位，任一取到的条目上）= **非法编码**；
  *   · `middle`/`tail` **作为一次分派的起点**（= 没有前驱）—— 它俩必须紧跟在 head/middle 之后；
  *   · `head` 后面**不是** `middle`/`tail`（含"直接撞上哨兵/plain/旁路项"）= **head 没有 tail**；
  *   · 链长 **> `L_MAX`**（本网表的切片实例数；`UnitExec` 生成期上限）；
  *   · 链上某个 `middle`/`tail` 的 `IMG_W/IMG_H/C_IN/C_OUT/GROUP/QUANT_SHIFT` 与**链首**不一致
  *     （那样 `UnitExec` 只会用链首的几何 ⇒ 剩下几片的几何**被静默忽略**，必须响亮拦住）；
  *   · 链上某个条目不是 conv（链只能串 conv 切片）。
  *
  * ---------------------------------- ★ C3.11b：**逐项字段校验**（S6 规则 (2)(3)(4) 的 RTL 侧） ----------------------------------
  *   上面那一组是"表的形状 / 链结构"规则；这一组是**每个载荷条目自己的字段**是否合法。判据全部落在
  *   **取表相位**（`FETCHW` = 分派前，`CHAINSCANW` = 链上被扫到的每一项）—— 也就是**在给任何单元举
  *   `go` 之前**（"零搬运"纪律：一个激活字节都还没搬、一个 AR/AW/W 都还没发）。与
  *   `y1/tools/desc_table.py` 的 `validate` 规则 (2)/(3)/(4) **逐条对应**：
  *
  *   · **32 B 对齐**：`SRC_ADDR`/`DST_ADDR` 的低 5 位必须为 0（与 `DdrMaster` CHK 的 P3 纪律同一条）；
  *   · **`IN_BYTES` 合法性**：`IN_BYTES % 32 == 0 && IN_BYTES != 0`。★ 只查"对齐 + 非零"，**不查精确长度**：
  *     对 maxpool/resize/add 这个字段是 `align32(max(Σ读, 写))` 的**上界**（`DescDefs` 的 `inBytes`
  *     注释 + `reports/c3_descriptor_format.md` §7 开口项 O2）⇒ 真实长度由各单元按 `IMG_W/IMG_H/C_IN/C_OUT`
  *     自己算（`BypassExec` 甚至完全不读这个字段）；
  *   · **DDR 窗内**：`SRC_ADDR + IN_BYTES <= DDR_BYTES`（`DST_ADDR` 同）—— 上界 = `2^ADDR_W`
  *     （`DdrMaster.ADDR_W = 28` ⇒ 256 MiB），常量 `DDR_BYTES` 与 `desc_table.py` 的 `DDR_BYTES` **同源**。
  *     ★ 为什么必须在这里拦：描述符的地址域是 **32 bit** 而主口只有 **28 bit** ⇒ 越窗地址会被**静默截断**
  *     （`SRC_ADDR = 0x10000000` ⇒ 送到主口的是 `0`）⇒ 搬到别处却一声不响。`DdrMaster` 自己**没有**窗的概念
  *     （它只查对齐/长度），所以这一条**只能**由本表校验负责；
  *   · **自环**：`SRC_ADDR == DST_ADDR`（规则 (4)）。本判据逐字就是"**同一个条目**的源地址 == 它**自己**的
  *     目标地址"，**不是**"整张表不许出现重复地址"。理由（写成代码形状而不是口号）：相邻的两个**不同**条目
  *     **天然会复用地址** —— 项 `i` 的 `DST` == 项 `i+1` 的 `SRC` 就是生产者-消费者的正常形态；链的
  *     head 的 `DST`（片上占位槽）与 tail 的 `SRC` 也是同一个槽。⇒ 若把它写成"全局地址唯一"，本闸门的
  *     合法表（A 作业 `src->a1->片上->dst`、B 作业同形）**当场误报** ⇒ 那才是错的判据。就地复制
  *     （`SRC == DST`）对硬件是"读自己写自己"，语义未定义 ⇒ 规则 (4) 明确禁止；
  *   · **非法 `TYPE`**：不在 `{conv3x3, conv1x1, depthwise, maxpool, resize, add, sigmoid}` 里的
  *     （如 `0x77`）⇒ 响亮 `err`（绝不静默跳过：静默跳过会把"这层算错了"变成"这层没算却没人知道"）。
  *     哨兵 `0xFF` 由更早的分支处理。
  *     ★ **C4a.6 更新**：`0x03 depthwise` 从"非法"改为**可执行**（走 conv 同一条分派/链路，见
  *     `DescType.isConvClass` 与 `isDw`）。仍与 Python 侧保有一点分歧（比 Python **更严**、方向安全）：
  *     `desc_table.VALID_TYPES` 还含 `0x12 concat`，而本代硬件**没有** concat 单元 ⇒ RTL 仍把它判非法
  *     （宁可响亮报错，也不静默当别的算子跑）。
  *
  *   ---- 与 `DdrMaster` CHK 的关系（诚实记录：一处**故意冗余**、一处**不可替代**）----
  *   · 32 B 对齐 / `len != 0` 这两条：`DdrMaster` 的 CHK 也会拦（且拦在**同一拍**、同样零搬运）⇒ 对
  *     **被单元消费的**地址而言本判据是**纵深防御**（多一层、早一层，观测上等价）；
  *   · DDR 窗 / 自环 / `IN_BYTES != 0`（旁路项）/ 非法 `TYPE` 这四条：**下游任何一层都看不到**
  *     —— 窗越界被主口截断、自环在主口看来是一次合法搬运、旁路单元根本不读 `IN_BYTES`、
  *     未知 `TYPE` 不会被分派给任何单元 ⇒ 这四条**只能**由本表的预检负责。
  *
  *   ★ 代价（明写）：扫链要**逐项取表**（每项 32 B 的 DMA 读）⇒ 帧内每个载荷条目恰好被取一次
  *     （+1 次是表尾哨兵探测）；`err` 是在**扫描途中**发现的 ⇒ 已经取过的描述符字节是既成事实
  *     （"零搬运"指**设备级**：一个激活字节都不搬、一个 AW/W 都不发）。
  *
  *   ---- 单元计数（`unitIndex`）与 IRQ 纪律（不变）----
  *   `unitIndex` = **已消费的载荷条目数**（`+chainLen`；一次 `go` 消费 `chainLen` 个条目）
  *   ⇒ 帧末 == `descCount`（与 C3.10a 的判据逐字一致）。`frameDone` 仍只在 `FRAMEDONE` 抬一次。
  *   · **旁路算子（MaxPool/Resize/Add/Sigmoid）本片接上了**（C3.10b）：`TYPE ∈ {0x10,0x11,0x13,0x14}` 时
  *     本 FSM 走 `BYPSTART -> BYPW`，由 `rtl/BypassExec.scala`（`x`/`x_valid`/`x_ready` + `y`/`y_valid` 的
  *     纯流式旁路单元 **没有 DDR 口**）把 `SRC_ADDR` 的张量搬到 `DST_ADDR`：DDR(RD) -> 单元列流 -> DDR(WR)。
  *     **一个旁路项一次 `go`**，与 conv 项同一条纪律（等 `done`/`err` 单拍才走下一项）。
  *     ⇒ 于是"三个单元各一次中断"这件事在本片**结构性不会发生**：`frameDone` 仍只在整表末尾抬一次
  *       （`FRAMEDONE`）。
  *   · **未知 TYPE**（既不是 conv / 旁路 / 哨兵，如 `0x77` 或 `0x12 concat`）仍走**响亮 `err`**
  *     （绝不静默跳过 —— 静默跳过会让"这层算错了"变成"这层没算却没人知道"）。
  *     （非法 `TYPE` 的六规则校验是 C3.11。）
  *
  * ---------------------------------- ★★ A'-2：**逐片几何投递 + 逐成员权重段基址**（口径修订落地） ----------------------------------
  *   A'-1（`docs/superpowers/plans/2026-10-14-y1-frame-runnable.md` 的 Task A'-1）把接口钉死，本片落地：
  *
  *   · **逐片几何**：本 FSM 在 `CHAINSCAN` 本来就**逐条取回**链上每个成员的描述符（并逐条校验）⇒ 新增
  *     `chainCin/Cout/Grp/Qsh/Lid/Dw/1x1R`（`L_MAX` 槽；槽 0 = 链首）在**每条取回的那一拍**落槽
  *     （`FETCHW` ⇒ 槽 0；`CHAINSCANW` ⇒ 槽 `chainCnt`）。落槽先于校验 ⇒ 即使链随后被拦下，槽里仍是
  *     表里真实值。去向 = `UnitExec` 的**新专用端口**（`chain_cin/…`；8 字描述符线格式**一字未动**）。
  *   · **链的校验口径改"可链谓词"**（A'-1.1）：`IMG_W/IMG_H/STRIDE/PAD` 全 run 相等 ∧
  *     `C_OUT(k) == C_IN(k+1)`；`C_IN/C_OUT/GROUP/QUANT_SHIFT` **逐片自由**（旧口径要求与链首全等）。
  *     原因 = 真表的宽 run 是**异型链**（`reports/ts3g_chain_caliber.md` 的 19-run 标定）。
  *   · **逐成员权重段基址**（A'-1.2）：`base(0) = UnitExec.io.wgt_dma_addr`（口径不变）、
  *     `N_k = C_out(k)·(C_in(k)/GROUP(k))·9`、`len(k) = ceil32(N_k)`、`base(k+1) = base(k) + len(k)`
  *     —— 基址的**推导在 `UnitExec`**（`base(0)` 是它的入参）；本 FSM 只需要**逐片段长**（下一条）。
  *   · **帧级指针推进**（B2 的修法）：`wgtPtrR += Σ_k ceil32(N_k)`（= `nWgtAdvR`，在分派那一拍定案）。
  *     ★ 旧式 = `chainLen × N_head`（**未对齐**、且对逐片几何不同的链必错）：blob 是逐片 32 B 对齐的
  *       （B0 的转换器契约）⇒ 实测 19/19 run 漂移、帧级 52/53 单元错位（A'-1.0 末条）。
  *   · **面积账**：`L_MAX × 59 bit` 寄存器（8 ⇒ 472 bit）+ 一个 32 位推进寄存器，**零新增存储**。
  *
  * ---------------------------------- AXI 主口：三路子主口按时序复用一根 AXI ----------------------------------
  *   本 FSM 例化**三个**带 AXI 主口的子块：`DescFetch`（取表）、`UnitExec`（conv 激活搬运）与
  *   `BypassExec`（旁路算子搬运，C3.10b）。三者的一次活动**在时间上互斥**（取表相位 / conv 相位 /
  *   旁路相位），所以本模块把三路原始地**复用**到**一个**顶层主口 `io.ddr` 上：
  *   `useDesc` 为真时选 `DescFetch`，`useUnit` 为真时选 `UnitExec`，否则选 `BypassExec` 的主口。
  *   ★ 安全性：三路主口**只在各自 `busy==0` 之后**才交还（`DescFetch.busy` 覆盖内部主口在途相位、
  *     `UnitExec.busy` / `BypassExec.busy` 覆盖整单元在途相位）⇒ 切换相位时**没有任何在途事务**
  *     （valid 已落 0），不需要仲裁器、也不会把一笔突发劈给两个主口。
  *   ★ 这里的复用是**结构性的**（不是 TB 的约定）：`io.ddr` 的输出侧由 `useDesc` / `useUnit` 二选一驱动；
  *     三个子主口的**输入侧**（`*_ready` / `r.payload` / `b.payload`）**广播**自 `io.ddr`（同一拍只有
  *     一路在跑，另两路"看到"握手也**发不出**任何东西 —— 它们的 valid 恒 0）。
  *
  * ---------------------------------- 诚实记录（留给 C3.10b / C3.11 / C3.12） ----------------------------------
  *   · **"零搬运"的口径**：`descCount` 与哨兵不符时，本片在**跑任何单元之前**就发现（先取
  *     下标 `descCount` 项）⇒ 真的零搬运；但"载荷里提前出现哨兵"这一档是走表途中发现的 ⇒
  *     **已跑过的前缀单元**的搬运是既成事实（流式调度的固有代价）。C3.11 的 S6 若要求这一档也零搬运，
  *     需要"先全表校验、再执行"的两遍结构（把表读两遍，代价是取表流量翻倍）—— 留作开口项。
  *   · **★ C3.11b 的同一句口径**（逐字沿用上面那句）：逐项字段校验落在**每一项自己的取表相位**里 ⇒
  *     对**第 0 项**（以及负对照用的单/双项表）是**真·零搬运**（表探测两笔 32 B，其余一个字节都不动）；
  *     但一张多条目表里**靠后**的那个非法项，是在前缀条目**已经跑过之后**才被发现的 ⇒ 那些前缀的搬运
  *     是既成事实（同一条流式调度的代价；两遍结构一旦落地，这一档也归零，仍是开口项）。
  *   · **★ RTL 查不到的两件事**（`desc_table.validate` 能查、本片**结构上**查不到）：
  *     ① **"表比 provision 的更长"**：Python 侧 `desc_count == len(descs) - 1` 是拿**整张表**比的；
  *        RTL 只知道 `descCount` 与"下标 `descCount` 处必须是哨兵"，**看不到哨兵之后**还有没有载荷
  *        ⇒ 哨兵之后的项被**静默忽略**（要拦它，只能由主机/转换器保证表长，或加"哨兵后必须到底"的表尾元数据）。
  *     ② **哨兵项的 `FLAGS` 必须为 0**（规则 (6) 的子句）：哨兵**不进分派**（`TYPE` 一看是 `0xFF` 就收口）
  *        ⇒ 它的 `FLAGS` 对硬件没有任何作用 ⇒ 本片不查（无害；`desc_table.py` 的 `selftest` 仍在 Python 侧钉住它）。
  *   · **权重带外**（★ C3.16 更新）：描述符里没有权重指针（`DescDefs`/`desc_table` 的冻结口径）⇒ 权重一律
  *     **带外预载**，必须在 `go` 之前做完。本 FSM 把 `UnitExec` 的**一套"权重信箱"**（`wgt_sel/wgt_addr/
  *     wgt_data/wgt_we`）直通到顶层 IO，由主机预载。信箱的**切片下标**让 `L_MAX` 个链位**各自独立**可写
  *     （旧的四套装载口在 `L_MAX>4` 时把切片 4..7 别名到第 4 套 —— C3.16 已删除该限制）。
  *     ⇒ 每个 **plain** conv 项用的都是**切片 0** 的 `WeightStore`（`chain_len=1`）；
  *       一条链的第 `k` 个切片用**第 `k` 片**的 `WeightStore`（`wgt_sel=k`）⇒ 链上逐片可以有**不同**权重
  *       （这正是"融合"的用法：每层一份权重）。这与"权重常驻片上、`go` 之前装载"的 C3 口径一致。
  *   · **观察口**：`UnitExec` 的中间缓冲读口（`mid_rd_row/col/data`）本片**钉 0**（不引出）；
  *     它只服务 C3.9a 的中间张量读回，本片的判据是"最终张量 + IRQ 纪律"，不需要它。
  *
  * @param C        一拍字节数（= `DdrMaster.DATA_W/8` = 8），与 `UnitExec` 同口径。
  * @param WIDTH    行宽（`Conv3x3Slice`/`FusionBuf` 的展开期常量；描述符的 `IMG_W` 由 TB 在 time 0 对账）。
  * @param IMG_H_MAX 输出存储的行数上限（`UnitExec.MAXPIX = WIDTH*IMG_H_MAX`；本用例恰好 = H）。
  * @param L_MAX    ★ A-1b/A-3：本网表的**生成期切片上限**（= `UnitExec` 的 `L_MAX`：链长不得越过它）。
  *   本 FSM 扫链时用它做**响亮对账**；同时**显式**传给 `UnitExec`，两处不会漂开。
  *   ★ A-3（本片）：**参数化 + 默认值 4 → 8**。链长直方图 `{2:15, 4:2, 6:1, 8:1}`（`c3_fusion_chains.md`）
  *   说 `L_MAX=4` 会把长 6 / 长 8 的两条极大链**切开** ⇒ 只覆盖 31/33 条融合边
  *   （conv-only `14,265,600 B/帧`）；`L_MAX=8` 覆盖 **33/33**（回到 `fuse_both` 下界
  *   `12,576,000 B/帧`）。**装不装得下由面积实测定**（`c3_area.md` §10：实测 L=8 装得下 ⇒ 提交值 = 8）。
  */
class LayerSched(val C: Int = 8, val WIDTH: Int = 32, val IMG_H_MAX: Int = 8, val L_MAX: Int = 8) extends Component {

  /** 与 `DdrMaster` / `DescFetch` / `UnitExec` 同源的一份形状参数（顶层主口与子块都用它）。 */
  val ddrCfg = DdrMasterConfig()

  /** ★ C3.11b：**DDR 窗**的字节上界 = `2^ADDR_W`（`DdrMaster.ADDR_W = 28` ⇒ 256 MiB）。
    *   逐项字段校验拿它判 `SRC_ADDR/DST_ADDR + IN_BYTES` 是否越窗（规则 (3) 的区间口径）。
    *   与 `tools/desc_table.py` 的 `DDR_BYTES = 1 << DDR_ADDR_W` **同源**（那儿的 `DDR_ADDR_W = 28`
    *   也写着"与 RTL 的地址位宽同源"）。
    *   ★ 为什么是 `addr + IN_BYTES <= 2^28` 而不是单看 `addr < 2^28`：那就是 Python 规则 (3) 的**逐字**
    *   口径（`SRC_ADDR + IN_BYTES > ddr_bytes ⇒ addr OOB`），并且它顺带把"32 bit 地址被 28 bit 主口
    *   截断"这条静默错路也堵上（`IN_BYTES` 已非零 ⇒ 该式蕴含 `addr < 2^28`）。 */
  val DDR_BYTES: BigInt = BigInt(1) << ddrCfg.ADDR_W

  require(C == ddrCfg.DATA_W / 8,
    "C 必须等于 DdrMaster 一拍字节数（DATA_W/8=8）：一拍 = 一个像素的 C 个通道")
  require(C == 8, "本任务的 conv 单元固定一块 8x8 阵列（C_IN = C_OUT = 8，与 UnitExec 一致）")
  require(WIDTH >= 3, "3x3 窗口至少要 3 列")
  require(IMG_H_MAX >= 1, "输出存储至少一行")

  /** 权重装载口地址位宽（与 `UnitExec`/`WeightStore` 同口径：NENTRY = C*(C/GROUP)*9，dense 时 576）。 */
  val NENTRY: Int = C * (C / 1) * 9
  /** ★ C4a.5b：信箱**全地址**位宽（与 `UnitExec.MAILBOX_AW` 同源；高 4 位 = 区域）。 */
  val MAILBOX_AW: Int = 24
  val waBits: Int = log2Up(NENTRY)
  /** 列地址位宽（观察口用；本片钉 0，但保持与 FusionBuf/Conv3x3Slice 同口径）。 */
  val cw: Int = (log2Up(WIDTH) max 1)
  /** 描述符表项字节数 = 32（`DescFetch` 的取表口径）。 */
  val DESC_BYTES: Int = 32
  /** ★★ E1（2026-10-13）：表内 DST 历史的深度 `D`（`SRC2_K ∈ [1, D]`；见文件头与 spec §4.6）。
    *   本代取 8（= `L_MAX`）：真网两个 `Add` 的 `k = 1`，取 8 既够用又给负对照留余量。 */
  val DST_HIST_D: Int = 8

  val io = new Bundle {
    // ---- 调度控制（与 HostRegs 的 DESC_ADDR / DESC_COUNT 同口径；C3.12 接）----
    val go        = in  Bool()
    /** 描述符表基址（**必须 32 B 对齐**；对齐性由 `DescFetch` 内部 `DdrMaster` 的 CHK 校验并报 err）。 */
    val descAddr  = in  UInt (28 bits)
    /** 载荷项数（**不含**表尾哨兵）；哨兵必须落在下标 `descCount` 上。 */
    val descCount = in  UInt (32 bits)
    // ---- 状态 / 遥测 ----
    /** 调度器在途（`go` 起、整帧（含末尾那次 `frameDone`）走完回 IDLE 之间恒为 1）。 */
    val busy      = out Bool()
    /** 响亮 `err`（单拍脉冲；透传 `DescFetch.err` / `UnitExec.err`，或本 FSM 自己的一致性检查）。 */
    val err       = out Bool()
    /** 遥测：当前正在执行的单元下标（0 基）；**初始 0、每跑完一个单元 +1、帧末 == `descCount`**。 */
    val unitIndex = out UInt (32 bits)
    /** ★ 原始 IRQ 脉冲：**整帧唯一的一次**（单拍），交给调用方（NpuTop）锁成保持电平。 */
    val frameDone = out Bool()
    // ---- ★ C3.16：权重带外预载 = **一套"权重信箱"**，扇出到全部 `L_MAX` 个链位（切片）----
    //   描述符里**没有**权重指针（冻结口径）⇒ 权重一律**带外**预载，必须在 `go` 之前做完。
    //     · `wgt_sel`  —— 目标切片下标（`0..L_MAX-1`）：一条链的第 k 片用第 k 片自己的 `WeightStore`；
    //     · `wgt_addr` —— 该切片 `WeightStore` 内的条目下标（布局 = `GroupMask.weightAddr`，dense 时 0..575）；
    //     · `wgt_data` —— 一拍一个 int8 载荷（**写进 `WeightStore` 时按同一个 clk 沿生效**）；
    //     · `wgt_we`   —— 写使能（单拍脉冲；只有 `wgt_sel` 选中的那一片真的被写）。
    //   本 FSM **不做**任何译码：位宽裁剪由 `UnitExec` 的端口形状给出（`selBits/waBits`），
    //   切片译码（`sel===i`）在 `UnitExec` 里与它驱动的 `WeightStore` 写口**同一处**（见其文件头）。
    val wgt_sel    = in  UInt (log2Up(L_MAX) max 1 bits)
    /** ★ C4a.5b：**扩宽为信箱全地址**（区域 + 下标；见 `UnitExec.scala` 文件头寄存器/偏移语义）。
      *  旧的窄通路（区域 0，条目下标 < 1024）**逐字节不变**。 */
    val wgt_addr   = in  UInt (MAILBOX_AW bits)
    val wgt_data   = in  SInt (8 bits)
    val wgt_we     = in  Bool()
    // ---- 自报（几何钉死：TB 在 time 0 与描述符对账；来自 `UnitExec` 的自报口）----
    val imgC   = out UInt (16 bits) // = C
    val imgW   = out UInt (16 bits) // = WIDTH
    val grp    = out UInt (4 bits)  // = GROUP（dense = 1）
    val shift  = out UInt (8 bits)  // = SHIFT（requant 右移，展开期常量）
    val maxPix = out UInt (16 bits) // = WIDTH*IMG_H_MAX（输出存储字数上限）
    // ---- 流量遥测（`UnitExec` 的 DdrMaster 计数；TB/闸门交叉对账）----
    val rd_bytes = out UInt (32 bits)
    val wr_bytes = out UInt (32 bits)
    /** ★ C4b-B1：帧内**真正装载的权重字节数**（= Σ 各单元的 `UnitExec.wgt_bytes`）；
      * 与"内存模型数出来的读字节"是**两处独立计数**（闸门一起对上才算数）。未走 DMA 的帧恒 0。 */
    val wgt_bytes = out UInt (32 bits)
    // ---- AXI4 主口（与 DdrMaster.io.axi 同形；三路子主口复用到此）----
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
  // 三个被接方（都带 AXI 主口）
  // ---------------------------------------------------------------------------
  /** 取表器（C3.4）：一笔 `DdrMaster(RD, len=32)` 取一个 32 B 描述符，并把 8 个字纯组合译成字段。 */
  val descFetch = DescFetch()
  /** 单元执行器（C3.8/C3.9b/A-1a/A-1b）：一个 `go` 跑一条链（`chainLen` 片；`chainLen=1` 即单切片）。
    *   ★★ T-S2R：这里**打开 2-D tile 循环**（`TILING = true`）—— 本层（= 板级 `NpuTop`）几何是
    *     `WIDTH = 34 = W_TILE(32) + 2`、`IMG_H_MAX = 32 = H_TILE`（T-S2 的 `dev_map` 仲裁结果），
    *     tile 循环是**生产网表的一部分** ⇒ `dev_map` 必须把它算进去（否则"新循环的占用"根本没被测到）。
    *     `TILING=true` **只在**"窄通路 + `s∈{1,2}` + 单单元 + 非头 + `IMG_W%4==0`"的层上激活
    *     （`tilingOkC`，见 `UnitExec.scala` 那一节）；其余几何（宽通路/链/头）**逐字节沿用**旧路
    *     ⇒ `sched`/`nputop_sched` 的既有作业里只有"单单元窄层"走到了新路，数值仍逐字节相等。 */
  val unitExec  = new UnitExec(C = C, WIDTH = WIDTH, IMG_H_MAX = IMG_H_MAX, L_MAX = L_MAX, TILING = true)
  /** ★ C3.10b **旁路执行器**：一个 `go` 跑一个旁路算子（maxpool/resize/add/sigmoid）的
    * DDR -> 单元列流 -> DDR 搬运（四个流式单元都没有 DDR 口，见 `BypassExec.scala` 文件头）。 */
  val bypassExec = new BypassExec(C = C, WIDTH = WIDTH, IMG_H_MAX = IMG_H_MAX)

  // ---------------------------------------------------------------------------
  // 描述符译码：**本 FSM 自己**用 `DescDefs.DescWords` 把 `DescFetch.words` 译成字段
  //   （与 `DescFetch` 内部那次译码是**同一份真源**、两条独立实例 ⇒ 谁都没被绕过）。
  // ★ 必须在组件体里一次性建好（其方法是组合节点；见 `DescDefs.scala` 文件头）。
  // ---------------------------------------------------------------------------
  val dw = DescWords(descFetch.io.words(0), descFetch.io.words(1), descFetch.io.words(2),
                     descFetch.io.words(3), descFetch.io.words(4), descFetch.io.words(5),
                     descFetch.io.words(6), descFetch.io.words(7))

  /** 本位是否表尾哨兵（`TYPE == 0xFF`）。 */
  val isSentinel = dw.isSentinel
  /** conv3x3 `0x01`。 */
  val isConv3x3 = dw.tpe === U(DescType.CONV3, 8 bits)
  /** conv1x1 `0x02`。 */
  val isConv1x1 = dw.tpe === U(DescType.CONV1, 8 bits)
  /** ★ C4a.6：**depthwise `0x03`**。语义 = 分组卷积特例 `GROUP == C_IN == C_OUT`（`DescType.isConvClass`
    *   的注释有完整口径）。它走**与 conv 完全相同**的分派/链路：`FLAGS` 四态、`geomEq`、
    *   链长 `≤ L_MAX`、一个 `go` 一次。差别只在 `Conv3x3Slice` 的 GROUP 档与 `C>8` 时的多趟。
    *   ⇒ 本代它**不再**落到 C3.11b 规则 (2) 的"非法 TYPE"响亮 err 上（旧行为见文件头"诚实记录"）。 */
  val isDw      = dw.tpe === U(DescType.DW, 8 bits)
  /** 本位是不是本片能跑的 conv 类算子（conv3x3 `0x01` / conv1x1 `0x02` / depthwise `0x03`）。
    *   ★ C4a.6：`isDw` 纳入 —— 与 `DescType.isConvClass` 的语义**逐字一致**（那里是单一真源）。 */
  val isConv = isConv3x3 || isConv1x1 || isDw
  /** ★ C3.10b：本位是不是四类**旁路算子**之一（maxpool `0x10` / resize `0x11` / add `0x13` / sigmoid `0x14`）。 */
  val isPool    = dw.tpe === U(DescType.MAXPOOL, 8 bits)
  val isRz      = dw.tpe === U(DescType.RESIZE,  8 bits)
  val isAdd     = dw.tpe === U(DescType.ADD,     8 bits)
  val isSg      = dw.tpe === U(DescType.SIGMOID, 8 bits)
  val isBypass  = isPool || isRz || isAdd || isSg

  // ---------------------------------------------------------------------------
  // ★ A-1b：`FLAGS[1:0]` 的 per-operator 链式译码（`FLAGS[7:2]` 保留 = 0，非 0 ⇒ 响亮 err）
  //   （这些是**组合节点**：必须在 when 之外建好 —— 见 DescDefs.scala 文件头的用法警告。）
  // ---------------------------------------------------------------------------
  val flagsLo       = dw.flags(1 downto 0)
  val isHeadE       = flagsLo === U(0, 2 bits)   // head  ：输入 DDR，输出**留片上**
  val isPlainE      = flagsLo === U(1, 2 bits)   // plain ：输入 DDR，输出落 DDR
  val isMidE        = flagsLo === U(2, 2 bits)   // middle：输入取上一算子片上输出，输出**留片上**
  val isTailE       = flagsLo === U(3, 2 bits)   // tail  ：输入取上一算子片上输出，输出落 DDR
  val flagsReserved = dw.flags(7 downto 2) =/= U(0, 6 bits)

  // ---------------------------------------------------------------------------
  // ★ C3.11b：**逐项字段校验**（S6 规则 (2)(3)(4) 的 RTL 侧；与 `tools/desc_table.py` 的 `validate`
  //   逐条对应；文件头有完整论证）。全是**组合节点**⇒ 必须建在组件体里（不在 when 里；
  //   见 `DescDefs.scala` 文件头的用法警告）。
  //   判定只在**取表相位**（FETCHW / CHAINSCANW）里用 ⇒ 在给任何单元举 `go` 之前（"零搬运"纪律）。
  // ---------------------------------------------------------------------------
  /** 32 B 对齐（低 5 位为 0）。用**位切片**而不是 `% 32`：切片在网表里就是几根线，
    * 不会落成除法/取模器（`%` 在 SpinalHDL 里是真运算符节点 —— `DdrMaster` 的 CHK 就是这么生成的）。 */
  val srcAlignOk  = dw.srcA(4 downto 0) === U(0, 5 bits)
  val dstAlignOk  = dw.dstA(4 downto 0) === U(0, 5 bits)
  val addrAlignOk = srcAlignOk && dstAlignOk
  /** `IN_BYTES % 32 == 0 && IN_BYTES != 0`（只查对齐/非零，不查精确长度 —— 见文件头 O2 那一段）。 */
  val inBytesOk   = (dw.inBytes(4 downto 0) === U(0, 5 bits)) && (dw.inBytes =/= U(0, 32 bits))
  /** 搬运区间 `[addr, addr + IN_BYTES)` 落在 DDR 窗内（规则 (3)）。
    * `addr`/`IN_BYTES` 都是 32 bit 无符号 ⇒ 和 <= `2^33 - 2`，**33 bit 放得下**（不会回绕）。
    * 两侧都先 `resize(33)` 再 `+`、再 `resize(33)` ⇒ 无论 SpinalHDL 的 `+` 是否加宽都精确
    * （与 `DdrMaster` 里 `beatsM1*8 + 8` 那句同一个写法，理由也一样）。 */
  val srcEnd      = (dw.srcA.resize(33) + dw.inBytes.resize(33)).resize(33)
  val dstEnd      = (dw.dstA.resize(33) + dw.inBytes.resize(33)).resize(33)
  val srcInWin    = srcEnd <= U(DDR_BYTES, 33 bits)
  val dstInWin    = dstEnd <= U(DDR_BYTES, 33 bits)
  /** 自环：**同一个条目**的源地址 == 它自己的目标地址（规则 (4)；**不是**"全局地址唯一" —— 见文件头）。 */
  val selfLoop    = dw.srcA === dw.dstA
  /** 本条目是不是一个"已知 `TYPE`"（可被执行或可被识别为哨兵）。 */
  val typeKnown   = isConv || isBypass || isSentinel
  /** 字段总判据：全通过才算这一项合法（任一不满足 ⇒ 响亮 err + 零搬运）。 */
  val fieldsOk    = addrAlignOk && inBytesOk && srcInWin && dstInWin && !selfLoop

  // ---------------------------------------------------------------------------
  // FSM 寄存器
  // ---------------------------------------------------------------------------
  val state = Reg(SchedState()) init SchedState.IDLE
  /** 当前正在取/跑的**载荷项下标**（0 基）。 */
  val idx = Reg(UInt(32 bits)) init 0
  /** 本次 `go` 锁存的表基址 / 载荷项数（整帧期间不变）。 */
  val descAddrR  = Reg(UInt(28 bits)) init 0
  val descCountR = Reg(UInt(32 bits)) init 0
  /** 响亮 err / frameDone 的单拍脉冲寄存器。 */
  val errR       = Reg(Bool()) init False
  val frameDoneR = Reg(Bool()) init False
  /** 遥测：**已消费的载荷条目数**（★ A-1b：一次 `go` 消费 `chainLen` 个条目 ⇒ 每跑完一个单元
    * `+chainLen`）；帧末 == `descCount`（与 C3.10a 的判据逐字一致）。 */
  val unitIndexR = Reg(UInt(32 bits)) init 0

  // ---- ★ A-1b：链扫描 / 链描述符 的全部 per-run 寄存器 ----
  /** 本次 `go` 的**链长**（= `UnitExec.chain_len`）：非链（plain/旁路）= 1。 */
  val chainLenR = Reg(UInt(16 bits)) init 1
  /** 链扫描**已计入的条目数**（含链首）：链首置 1，每扫到一个 `middle` +1，扫到 `tail` 再 +1。 */
  val chainCnt  = Reg(UInt(16 bits)) init 1
  /** 链描述符的 8 个字 = **链首条目**的 8 个字（扫链期间锁存；扫完下游把 `w5` 换成链尾的 `DST_ADDR`）。
    *   ★★ C4a-R2：链尾 `DST_ADDR` 原来另存一份 `tailDstR` 只给"喂 UnitExec 的组合 mux"用；该 mux
    *   已改成**寄存**的 `unitDescR`（在 `CHAINSCANW` 的 tail 分支直接取 `descFetch.io.words(5)`）⇒
    *   那一份 `tailDstR` 成为死寄存器，**已删除**（`w5` 的口径不变：`unitDescR(5)` = 链尾 DST_ADDR）。 */
  val headW   = Vec.fill(8)(Reg(Bits(32 bits)) init B(0, 32 bits))
  /** ★ E1：**表内 DST 历史**（深度 `DST_HIST_D`）—— 走表时把每条被取到的条目的 `DST_ADDR`（低 28 位）
    *   记进槽 `fetchIdx mod D`；分派 `Add` 时取 `[(idx − SRC2_K) mod D]` 作 `BypassExec.io.src2`（见下）。 */
  val dstHist = Vec.fill(DST_HIST_D)(Reg(UInt(28 bits)) init 0)
  /** 链描述符（= 链首的字 + 链尾的 `DST_ADDR`）—— 纯组合，喂 `UnitExec`（见下）。
    *   ★ 建在组件体里（不在 `when` 里）：见 `DescDefs.scala` 文件头的用法警告。 */
  val headDw = DescWords(headW(0), headW(1), headW(2), headW(3),
                         headW(4), headW(5), headW(6), headW(7))
  /** ★★ A'-2（2026-10-15）：链的**可链谓词**（口径修订，取代 A-1b 的"6 字段与链首全等"）：
    *   · **空间几何**：`IMG_W / IMG_H / STRIDE` 必须全 run 相等（片间张量形状不变的前提）；
    *   · **内部边界**：`C_OUT(k) == C_IN(k+1)`（前一片的输出通道数 = 后一片的输入通道数）；
    *   · `C_IN / C_OUT / GROUP / QUANT_SHIFT` **逐片自由** —— 它们由 A'-2 的**逐片几何端口**
    *     （`chain_cin/chain_cout/chain_grp/chain_qsh/…`，见下）原样投递给 `UnitExec`，
    *     不再"以链首覆盖全链"。
    *   ★ 为什么改：真表的宽 run 是**异型链**（成员 `C_IN/C_OUT` 逐片不同；`reports/ts3g_chain_caliber.md`
    *     的 19-run 标定表），而旧口径（A-1b）与冻结 `desc_table.py` 的"链首几何覆盖"是同一口径的
    *     两处实现 ⇒ 真帧的宽层融合链在旧口径下**根本不可链**（`reports/c4b_frame_preflight.md` §9）。
    *   ★★ **一处与 A'-1 文本的偏差（有据）**：A'-1.1 把 `PAD` 也列进了"全 run 相等"的集合里，但
    *     **冻结 `gen/desc.bin` 的 12 个真 run 里 `PAD` 逐片不同**（1×1 成员 `PAD=0`、3×3/depthwise
    *     成员 `PAD=1`；例：项 4 `Conv_6` pad=0 → 项 5 `Conv_7` pad=1）⇒ 字面实现会把**每一条真 run**
    *     都拦死（恰好与本次口径修订的目的相反）。A'-1 自己的离线自检（`tools/chain_wide_ref.py` 的 L0）
    *     用的也正是"**空间几何（`IMG_H/IMG_W`）一致 ∧ `C_OUT(k)==C_IN(k+1)`**"这套（不含 PAD）
    *     ⇒ 本实现按**参考实现 + 冻结表**落（`IMG_W/IMG_H/STRIDE` 相等 + 通道边界）；`PAD` 不进判据。
    *     报告里如实记账。（`stride` 留在判据里：真 run 全为 1，且 `s>1` 的多片链本代不可执行。）
    *   ★ 纪律不变：不合 ⇒ `CHAINSCANW` 里**响亮 err + 零搬运**（一个 AR/AW 都不发）。 */
  /** ★★ A'-2 落地勘误（2026-10-15，接前一位 agent 的 WIP）：**内部边界是"相邻"判据** ——
    *   扫到成员 k 时比的是 `C_OUT(k-1) == C_IN(k)`（= `chainCoutR(chainCnt-1)`：上一个**已收**成员的
    *   `C_OUT`；扫第一片时 `chainCnt==1` ⇒ 它正是链首的 `C_OUT`），**不是**"链首对每个成员"。
    *   ★ 旧 WIP 写成 `headDw.cOut === dw.cIn`：对**异型链**（真表 run [4..11]：16,16,16,**32**,…）
    *   从第 4 片起必然误杀 ⇒ 与 A'-1 的可链谓词（`C_OUT(k)==C_IN(k+1)`）和离线参考 L0
    *   （`tools/chain_wide_ref.py:241`）不一致；本闸门的作业（run [4..11]）会卡在扫链相位、
    *   永不派发。⇒ 改成相邻比较。本式只在 `CHAINSCANW` 求值，故用 `def`（`chainCoutR` 声明在后面）。 */
  def geomEq: Bool = (dw.imgW === headDw.imgW) && (dw.imgH === headDw.imgH) &&
                     (dw.stride === headDw.stride) &&
                     (chainCoutR((chainCnt - U(1, 16 bits))(L_MAX_W1 - 1 downto 0)) === dw.cIn)

  // ---------------------------------------------------------------------------
  // ★★ A'-2：**逐片几何锁存**（`L_MAX` 槽；槽 k = 链上第 k 个成员，槽 0 = 链首）
  //   · 值 = 当拍 `descFetch.io.words` 的译码（`fetchDw`）⇒ **零新译码逻辑**；
  //     落槽点：`FETCHW` ⇒ 槽 0（链首 / 单单元）；`CHAINSCANW` ⇒ 槽 `chainCnt`（链上第 k 个成员）。
  //   · 落槽**先于**校验（`words_valid` 那一拍就落）⇒ 即使这条链随后被响亮拦下，槽里仍是**表里真实值**
  //     （判据面：TB 用 `+GEOMDUMP` 回读，见 `rtl_test/LayerSchedTb.v`）。
  //   · 去向：**新专用端口**送 `UnitExec`（8 字描述符线格式**一字未动**）。槽 0 与链描述符冗余
  //     ⇒ `UnitExec` 在 `go` 那一刻**断言相等**（不一致 ⇒ 响亮 err），两条来源绝不静默分叉。
  //   · 面积账：`L_MAX × 59 bit` 寄存器（8 ⇒ 472 bit），**零新增存储**（DRAM 余量不动）。
  // ---------------------------------------------------------------------------
  /** 逐片几何**槽号**的位宽（`k = 0..L_MAX-1`；`L_MAX=8` ⇒ 3 位）。 */
  val L_MAX_W1: Int = (log2Up(L_MAX) max 1)
  val chainCinR  = Vec.fill(L_MAX)(Reg(UInt(16 bits)) init 0)
  val chainCoutR = Vec.fill(L_MAX)(Reg(UInt(16 bits)) init 0)
  val chainGrpR  = Vec.fill(L_MAX)(Reg(UInt(8 bits))  init 0)
  val chainQshR  = Vec.fill(L_MAX)(Reg(UInt(8 bits))  init 0)
  val chainLidR  = Vec.fill(L_MAX)(Reg(UInt(8 bits))  init 0)
  val chainDwR   = Vec.fill(L_MAX)(Reg(Bool())        init False)
  val chainX1R   = Vec.fill(L_MAX)(Reg(Bool())        init False)
  /** ★★ A'-2：本单元（plain / 链）的**帧级指针推进量** = `Σ_k ceil32(N_k)`（k 覆盖本单元的全部成员）。
    *   ★ 这是 B2 的修法：旧式（`:829`）= `chainLen × N_head`（**未对齐**的链首段长 × 片数）——
    *     真表 19/19 run 漂移（`reports/ts3g_chain_caliber.md` §3）；blob 是**逐片 32 B 对齐**的
    *     （B0），所以推进必须是**逐片 `ceil32` 的和**。 */
  val chainSegLenR = Vec.fill(L_MAX)(Reg(UInt(32 bits)) init 0)

  /** ★★ E1（2026-10-13）：`SRC2_K`（`w3[31:16]`）合法性（spec §4.6；与 `fieldsOk` **同相位** pre-dispatch）：
    *   · `0` ⇒ 合法（缺省；任何项都可以）；
    *   · `k > 0` ⇒ **仅 `Add` 合法**（非 `Add` 带非零 k ⇒ 表非法），且 **`1 ≤ k ≤ D`**、**`k ≤ idx`**
    *     （否则 `idx − k` 落表首之前 ⇒ 无生产者）。
    *   任一不满足 ⇒ 与 `!fieldsOk` 同一条**响亮 err + 零搬运**（在给任何单元举 `go` 之前）。 */
  val src2kE   = dw.src2k
  val src2Ok   = (src2kE === U(0, 16 bits)) ||
                 (isAdd && (src2kE <= U(DST_HIST_D, 16 bits)) && (idx >= src2kE.resize(32)))

  // 默认值（写在 switch 之前 ⇒ 被 switch 内赋值覆盖；"一拍脉冲"的实现口径）
  errR       := False
  frameDoneR := False
  descFetch.io.go := False
  unitExec.io.go  := False
  bypassExec.io.go := False

  // ---------------------------------------------------------------------------
  // 取表地址：`descAddr + i*32`。用 `i @@ U(0,5 bits)`（硬连线左移 5 位 = *32，**不生成乘法器**），
  //   与 DdrMaster 的 `beatsM1 @@ U(0,3 bits)`（= *8）同一手法。
  //   ★ A-1b：链扫描（CHAINSCAN）取的是 `idx + chainCnt`（= 链首之后的第 chainCnt 项）。
  // ---------------------------------------------------------------------------
  def entryAddr(i: UInt): UInt = (descAddrR + (i @@ U(0, 5 bits)).resize(28)).resize(28)
  val tailAddr  = entryAddr(descCountR)   // 期望的哨兵位置：下标 == descCount
  val fetchAddr = entryAddr(idx)
  val scanAddr  = entryAddr((idx + chainCnt.resize(32)).resize(32))
  val inScan    = (state === SchedState.CHAINSCAN) || (state === SchedState.CHAINSCANW)

  val inTailChk = (state === SchedState.TAILCHK) || (state === SchedState.TAILCHKW)
  descFetch.io.descAddr := Mux(inTailChk, tailAddr, Mux(inScan, scanAddr, fetchAddr))

  /** 本拍用哪一路子主口（取表相位 = DescFetch；conv 相位 = UnitExec；旁路相位 = BypassExec）。
    * 三路时间互斥（见文件头）。★ A-1b：链扫描也是**取表相位**（走 DescFetch）。 */
  val useDesc = (state === SchedState.TAILCHK) || (state === SchedState.TAILCHKW) ||
                (state === SchedState.FETCH)   || (state === SchedState.FETCHW) ||
                (state === SchedState.CHAINSCAN) || (state === SchedState.CHAINSCANW)
  val useUnit = (state === SchedState.RUNSTART) || (state === SchedState.RUNW)

  // ---------------------------------------------------------------------------
  // ★★ C4a-R2（2026-10-11）：`UnitExec` 的描述符**寄存化**（= 斩断 `chainLenR` → 描述符 → `UnitExec`
  //   的**组合**通路）。
  //   为什么：旧写法把 `Mux(chainRun, headW/tailDstR, descFetch.words)` 组合地接到
  //   `unitExec.io.desc` 上，而 `chainRun = chainLenR ≥ 2` 是 `chainLenR` 的 OR 归约 ⇒ 板级 PnR
  //   （`sim/reglogs/pds_pnr_c4a_c4a_p10.000` seed_0 的 `..._rtr`）实测最坏 `cpu_clk` 路径的**头段**
  //   就是它：`chainLenR[9] → BypassExec/N492 → _N4463(fanout 42) → LayerSched/N466 →
  //   _N4(fanout 21，布线 1.510) → UnitExec/mzRam 读地址`。
  //   修法：本 FSM **在进 `RUNSTART` 之前**（`FETCHW` 的 plain 分支 / `CHAINSCANW` 的 tail 分支）
  //   就已经把"链长 + 链首/链尾字"全部定案 ⇒ 在**那两个分支**里把喂给 `UnitExec` 的 8 个字落寄存器，
  //   `RUNSTART` 起 `go` 拍它们已稳定 ⇒ **一拍延迟都没有**（`go` 相位、run 相位、验收判据全不变）。
  //   ⇒ `chainLenR` 到 `UnitExec` 只剩 `io.chain_len` 这条**直连寄存器**（16 位，扇出后段在
  //     `UnitExec` 里的比较器/选择端），描述符通路**不再**依赖它。
  // ---------------------------------------------------------------------------
  val chainRun = chainLenR >= U(2, 16 bits)
  /** 喂 `UnitExec` 的 8 个描述符字（**寄存**；在 `FETCHW`/`CHAINSCANW` 的分派分支里锁存）。 */
  val unitDescR = Vec.fill(8)(Reg(Bits(32 bits)) init B(0, 32 bits))
  for (i <- 0 until 8) {
    unitExec.io.desc(i) := unitDescR(i)
    bypassExec.io.desc(i) := descFetch.io.words(i)
  }
  // ---------------------------------------------------------------------------
  // ★★ E1（2026-10-13）：`Add` 第二路源的**表内偏移**查找（**复用走表** —— 不加第二趟取表；spec §4.6）。
  //   `DST_ADDR` 历史在每条被取到的条目上落槽（`fetchIdx mod D`）；`Add` 取 `[(idx − k) mod D]`。
  //   真网 k=1（生产者紧邻其前）；`src2k == 0`（含所有非 Add）时 `BypassExec` 忽略本口。
  // ---------------------------------------------------------------------------
  val LOG2D: Int = log2Up(DST_HIST_D)
  /** 本拍取表回值的条目的**表序**（`FETCHW` = `idx`；`CHAINSCANW` = `idx + chainCnt`）。 */
  val fetchIdx = Mux(inScan, (idx + chainCnt.resize(32)).resize(32), idx)
  /** 本拍把该条目的 `DST_ADDR` 落历史槽（在 `words_valid` 那一拍）。
    *   ★ 取**低 28 位**（描述符地址域 32 bit、主口 28 bit；越窗已在 `fieldsOk` 里拦掉）。 */
  val histWrEn = ((state === SchedState.FETCHW) || (state === SchedState.CHAINSCANW)) &&
                 descFetch.io.words_valid
  when(histWrEn) {
    dstHist(fetchIdx(LOG2D - 1 downto 0)) := descFetch.io.words(5)(27 downto 0).asUInt
  }
  /** ★ E1：本条目（`Add`）的第二路源地址 = `dstHist[(idx − SRC2_K) mod D]`（`D` = 2^n ⇒ 取低 n 位）。 */
  val src2Addr = dstHist((idx - dw.src2k.resize(32)).resize(32)(LOG2D - 1 downto 0))
  bypassExec.io.src2 := src2Addr
  unitExec.io.chain_len := chainLenR
  // ★★ A'-2：**逐片几何**原样送 `UnitExec`（专用端口；8 字描述符线格式**一字未动**）。
  //   槽 0 与链描述符冗余（同一份值），由 `UnitExec` 在 `go` 那一刻**断言相等** ⇒ 两条来源绝不静默分叉。
  //   ★ 这些端口是 `UnitExec` 的**组件级入参**（不是 `io` 成员；理由见 `UnitExec.scala` 文件尾「A'-2」）。
  for (k <- 0 until L_MAX) {
    unitExec.chain_cin(k)  := chainCinR(k)
    unitExec.chain_cout(k) := chainCoutR(k)
    unitExec.chain_grp(k)  := chainGrpR(k)
    unitExec.chain_qsh(k)  := chainQshR(k)
    unitExec.chain_lid(k)  := chainLidR(k)
    unitExec.chain_dw(k)   := chainDwR(k)
    unitExec.chain_1x1(k)  := chainX1R(k)
  }

  // ===========================================================================
  // ★★ C4b-B1：**WGT_BLOB_BASE + 表序前缀和 `wgt_ptr`**（权重从 DDR 批量装载的"记账"半边）
  //   （装载器本体在 `UnitExec`；本片只负责"每个单元的段起点 = 基址 + Σ_{j<i} N_j"这件事，
  //     并把结果作为**独立入参** `wgt_dma_addr` 送进 `UnitExec`。见 `UnitExec.scala` 文件头。）
  //   · 为什么记账在**调度器**：走表的人才知道"表序"，而"表序 == blob 序"（spec §4.2）正是这条
  //     隐式契约的全部内容；描述符格式**零改动**（权重指针不进描述符，见 §4.2 裁决 (a)）。
  //   · `WGT_BLOB_BASE` 的落点（任务允许"新寄存器 或 复用信箱地址寄存器"，本实现选**后者**）：
  //     经**既有权重信箱**的**区域 6** 投递（4 个字节道，小端）；`HostRegs`/NpuTop/描述符/台账
  //     **一字未动**（寄存器契约不变）。`WGT_BLOB_BASE == 0` ⇒ DMA 主路径**关闭**（既有行为）。
  // ===========================================================================
  /** 本网表的展开期 GROUP（`UnitExec` 恒为 dense ⇒ 1）；运行时由 `UnitExec.dmaGeomOk` 再对一次账。 */
  val GROUP: Int = 1
  /** `log2(GROUP)`：`C_in/GROUP` 在本网表里退化成**移位**（GROUP=1 ⇒ 移 0 位，零代价）。 */
  val LOG2G: Int = log2Up(GROUP)
  /** ★ C4b-B1：信箱**区域 6** = `WGT_BLOB_BASE`（4 个字节道；`WGT_ADDR[1:0]` 选道，小端）。 */
  val RGN_WBASE: Int = 0x6
  /** 主机编程的权重 blob 基址（**整 32 位存储**，与既有 RW 档同姿；驱动时截到 28 位主口宽度，
    * 与 `ddrMaster.io.src := src_addr.resize(28)` 同一手法）。`0` = 未编程 ⇒ `dmaEn` 为假。 */
  val wgtBlobBaseR = Reg(UInt(32 bits)) init 0
  val wgtRgn  = io.wgt_addr(MAILBOX_AW - 1 downto MAILBOX_AW - 4)
  val wgtLane = io.wgt_addr(1 downto 0)
  when(io.wgt_we && (wgtRgn === U(RGN_WBASE, 4 bits))) {
    for (l <- 0 until 4) {
      when(wgtLane === U(l, 2 bits)) { wgtBlobBaseR(l * 8 + 7 downto l * 8) := io.wgt_data.asUInt }
    }
  }

  // ===========================================================================
  // ★★ C4b-B4：**布局模式表**（每层两位）—— 信箱**区域 7 道 2**、按 `LAYER_ID`（`WGT_ADDR[15:8]`）索引
  // ===========================================================================
  // 语义（见 `BypassExec.scala` 文件头 C4b-B4 一节）：`wgt_data[0] = src_planar`（本层的源张量在 DDR
  //   上是**通道平面** ⇒ 旁路消费者按步长 gather 成 NHWC 列流）、`wgt_data[1] = dst_planar`（本层的目标
  //   要按**平面**写 ⇒ 下一个消费者（conv 的宽通路）读到的仍是冻结的平面布局）。
  // · 为什么落在**调度器**：走表的人才知道"本拍这一层是谁"（`dw.layerId` = 表序 = LAYER_ID，与
  //   `UnitExec` 的 `M/z_pad/bias_adj` 索引**同一真源**）；且两个单元里只有 `BypassExec` **没有**
  //   权重信箱口 ⇒ 这里**一处译码、扇出两根线**（与 `RGN_WBASE` 同一手法）。
  // · 上电值 0 ⇒ 默认 = `BypassExec` 的线性 NHWC ⇒ **既有闸门逐字节不变**。
  // · 与 `RGN_XDMA` 道 0（`UnitExec` 的 `XDMA_EN`）**同区域不同道**：道 0 仍是全局开关、语义不变。
  val RGN_LAYOUT: Int = 0x7
  /** 布局表的层数 = `LAYER_ID` 满量程（8 位 ⇒ 256）。 */
  val PN_LAYOUT_L: Int = 256
  /** 每层两位：bit0 = `src_planar`、bit1 = `dst_planar`（深度 = `PN_LAYOUT_L` = `LAYER_ID` 满量程）。 */
  val layoutMem = Mem(Bits(2 bits), PN_LAYOUT_L).init(Seq.fill(PN_LAYOUT_L)(B(0, 2 bits)))
  val lytLid  = io.wgt_addr(15 downto 8)
  /** 本拍正在跑的层的布局位（**寄存器表 + `dw.layerId` 索引**）。运行期 `descFetch.io.words` 恒定
    *   ⇒ 这两位在整段运行内稳定 ⇒ 单元侧在 `runStart` 一拍锁存即可（运行锥上不挂这张表）。 */
  val curLayout = layoutMem.readAsync(dw.layerId.resize(log2Up(PN_LAYOUT_L) bits))
  when(io.wgt_we && (wgtRgn === U(RGN_LAYOUT, 4 bits)) && (wgtLane === U(2, 2 bits))) {
    layoutMem.write(lytLid.resize(log2Up(PN_LAYOUT_L) bits), io.wgt_data.asBits(1 downto 0))
  }
  bypassExec.io.src_planar := curLayout(0)
  bypassExec.io.dst_planar := curLayout(1)
  /** **表序前缀和指针**：帧首 = `WGT_BLOB_BASE`；每跑完一个 conv 单元 `+= Σ_k ceil32(N_k)`（旁路项 `+0`）。
    *   ★★ A'-2（B2 的修法）：推进量从 `chainLen × N_head`（**未对齐**的链首段长 × 片数）改成
    *     **本单元各成员自己**的对齐段长之和 `Σ_k ceil32(N_k)` —— 理由 = blob 的逐片 32 B 对齐
    *     （冻结转换器契约 `y1_convert.py:600-612`；实测 19/19 run 旧式漂移，
    *     `reports/ts3g_chain_caliber.md` §3 + 帧级 52/53 错位）。 */
  val wgtPtrR = Reg(UInt(32 bits)) init 0
  /** 本单元（plain / 链）的**帧级指针推进量** `Σ_k ceil32(N_k)`（在分派那一拍定案；见下 `nWgtAdvOf`）。 */
  val nWgtAdvR = Reg(UInt(32 bits)) init 0
  /** 帧内**真正装载的权重字节数**（= Σ 各单元 `UnitExec.wgt_bytes`；自报/对账用）。 */
  val wgtBytesAccR = Reg(UInt(32 bits)) init 0
  /** ★ DMA 主路径的**开关 + 送地址**：`WGT_BLOB_BASE == 0`（未编程）⇒ **整帧把地址钉 0**
    *   （`UnitExec.dmaEn` 恒假 ⇒ 走旧信箱通路，与 C3/C4a 逐字节同形）；非 0 ⇒ 送"基址 + 表序前缀和"。
    *   ★ 为什么不用"指针是否为 0"当开关：指针**每跑完一个单元就 += N_i**（帧内必然变非 0）⇒
    *     用指针当开关会让"未编程（base=0）"的帧从第 **2** 个单元起**静默地**走起 DMA（实测：本闸门
    *     第一版就这么被 J1b 抓住 —— 那正是"静默错值"的形状）。开关只认**主机编程的基址**。 */
  unitExec.io.wgt_dma_addr := Mux(wgtBlobBaseR =/= U(0, 32 bits),
                                  wgtPtrR.resize(ddrCfg.ADDR_W), U(0, ddrCfg.ADDR_W bits))

  /** 本拍的取表结果的**类型化只读视图**（与 `dw` 同一份真源，只多一次纯组合译码）。
    *   ★ 为什么要另起一份：`nWgtAdvR` 是在**分派那一拍**锁存的，而那一拍 `unitDescR` 正在被赋值
    *   （寄存器值还是**上一个**单元的字）⇒ 必须从**本拍的** `descFetch.io.words` 算 `N_i`。 */
  val fetchDw = DescWords(descFetch.io.words(0), descFetch.io.words(1), descFetch.io.words(2),
                          descFetch.io.words(3), descFetch.io.words(4), descFetch.io.words(5),
                          descFetch.io.words(6), descFetch.io.words(7))
  /** ★★ C4b-B1：`N_i = C_out*(C_in/GROUP)*9`（**从几何导出**，不查表 —— 与转换器 `y1_convert.py`
    *  的 `n_i = co_ * cg_ * 9` 同式；`cg_` 就是 `C_in/GROUP`）。
    *   · **depthwise**（`TYPE==0x03`）：转换器给它的权重张量是 `[C_out][1][kh][kw]`（即 `C_in/GROUP == 1`）
    *     ⇒ `N_i = C_out*9`；本网表 GROUP=1 ⇒ 这一档**必须单独给**（不能与 `C_in/GROUP` 共用）。
    *   · 其余：`C_in/GROUP`（本网表 GROUP=1 ⇒ `C_in`，移位 0 位，零代价）。
    *   ★★ A'-2：本式现在**逐成员**用（成员自己的 `fetchDw`）——它与冻结 `desc_table` 的"链首覆盖"
    *     无关了：`desc_table` 解冻后每条描述符写**自己**的几何（A'-1.3），本式随之逐片正确。
    *     装载路径仍要求"逐片几何一致"由 `UnitExec` 在 `go` 那一刻把住（引擎落地前）。 */
  val perGroupOf = Mux(fetchDw.tpe === U(DescType.DW, 8 bits), U(1, 16 bits), (fetchDw.cIn >> LOG2G).resize(16))
  val nWgtFetch  = ((fetchDw.cOut * perGroupOf).resize(32) * U(9, 32 bits)).resize(32)
  /** ★★ A'-2：本拍条目的**对齐段长** `ceil32(N)`（= blob 里该段的 `aligned_bytes`；B0 的 32 B 对齐）。
    *   一个式子两处用：落**逐片段长槽**（`chainSegLenR`）与**帧级推进**（`nWgtAdvOf`）。 */
  val segLenFetch = (((nWgtFetch + U(31, 32 bits)) >> 5) << 5).resize(32)
  /** ★★ A'-2：**本拍条目的槽号**（`FETCHW` ⇒ 槽 0；`CHAINSCANW` ⇒ 槽 `chainCnt` = 链上第 k 个成员）。
    *   `chainCnt ≤ L_MAX-1` 在落槽点恒成立（middle/tail 的越限检查在**同一拍或更早**就把它拦住）。 */
  val geomSlotIdx = Mux(inScan, chainCnt(L_MAX_W1 - 1 downto 0), U(0, L_MAX_W1 bits))
  /** ★★ A'-2：本拍落槽（`words_valid` 那一拍；与 `histWrEn` 同相位）。 */
  val geomSlotWr  = ((state === SchedState.FETCHW) || (state === SchedState.CHAINSCANW)) &&
                    descFetch.io.words_valid
  when(geomSlotWr) {
    chainCinR(geomSlotIdx)  := fetchDw.cIn
    chainCoutR(geomSlotIdx) := fetchDw.cOut
    chainGrpR(geomSlotIdx)  := fetchDw.group
    chainQshR(geomSlotIdx)  := fetchDw.qShift
    chainLidR(geomSlotIdx)  := fetchDw.layerId
    chainDwR(geomSlotIdx)   := (fetchDw.tpe === U(DescType.DW, 8 bits))
    chainX1R(geomSlotIdx)   := (fetchDw.tpe === U(DescType.CONV1, 8 bits))
    chainSegLenR(geomSlotIdx) := segLenFetch
  }
  /** ★★ A'-2：**本单元（plain / 链）的对齐段长和** `Σ_k ceil32(N_k)`（`k = 0..chainLen-1`）。
    *   槽 `k` 的取值三档（`chainCnt` = 本拍之前的成员数，含链首）：
    *     · `k < chainCnt` ⇒ 已落槽的**寄存器**（扫过的成员）；`k == chainCnt` ⇒ **本拍这一片**的组合值
    *       （它同一拍才落槽 ⇒ 必须用组合值，否则少加最后一片）；`k > chainCnt` ⇒ 0。
    *   ⇒ `chainAdvFetch` 在**链尾**那一拍 == 整条链的和；在 `plain` 那一拍 == `ceil32(N_0)`（单成员）。 */
  val chainAdvFetch = (0 until L_MAX).map { k =>
    Mux(chainCnt.resize(32) > U(k, 32 bits), chainSegLenR(k),
      Mux(chainCnt.resize(32) === U(k, 32 bits), segLenFetch, U(0, 32 bits))).resize(32)
  }.reduce((a, b) => (a.resize(33) + b.resize(33)).resize(32))

  // 权重装载 / 自报 / 流量：直通（★ C3.16：**一套权重信箱**直通到顶层 IO，带外预载；切片译码在
  //   `UnitExec` 里，见其文件头"权重装载口"那一节）。
  unitExec.io.wgt_sel  := io.wgt_sel
  unitExec.io.wgt_addr := io.wgt_addr
  unitExec.io.wgt_data := io.wgt_data
  unitExec.io.wgt_we   := io.wgt_we
  // ★ C4a.5b：宽层多趟通路的**激活列流**在调度器侧**本片钉 0**（"宽层经 `wide_x` 由调用方喂"这条路
  //   还没接进 `LayerSched`；见 `UnitExec.scala` 文件头的 C4b 口径）。`LayerSched` 只跑窄层单元。
  unitExec.io.wide_x_valid := False
  for (ci <- 0 until C) { unitExec.io.wide_x(ci) := S(0, 8 bits) }
  io.imgC   := unitExec.io.imgC
  io.imgW   := unitExec.io.imgW
  io.grp    := unitExec.io.grp
  io.shift  := unitExec.io.shift
  io.maxPix := unitExec.io.maxPix
  // 流量遥测 = 两路子主口（conv + 旁路）的 DdrMaster 计数之和。conv-only 作业里旁路那一路恒 0
  // ⇒ 与 C3.10a 的数**逐字节相同**（回归纪律）。
  io.rd_bytes := unitExec.io.rd_bytes + bypassExec.io.rd_bytes
  io.wr_bytes := unitExec.io.wr_bytes + bypassExec.io.wr_bytes
  // 中间缓冲观察口本片钉 0（见文件头"观察口"）。
  unitExec.io.mid_rd_row := U(0, 2 bits)
  unitExec.io.mid_rd_col := U(0, cw bits)

  // ---------------------------------------------------------------------------
  // ★ AXI 主口复用：三路子主口按时序相位选一路到顶层 `io.ddr`。
  //   输出侧（valid/payload）三选一；输入侧（ready/r.payload/b.payload）广播。
  // ---------------------------------------------------------------------------
  io.ddr.ar.valid := Mux(useDesc, descFetch.io.ddr.ar.valid,
                     Mux(useUnit, unitExec.io.ddr.ar.valid, bypassExec.io.ddr.ar.valid))
  io.ddr.aw.valid := Mux(useDesc, descFetch.io.ddr.aw.valid,
                     Mux(useUnit, unitExec.io.ddr.aw.valid, bypassExec.io.ddr.aw.valid))
  io.ddr.w.valid  := Mux(useDesc, descFetch.io.ddr.w.valid,
                     Mux(useUnit, unitExec.io.ddr.w.valid, bypassExec.io.ddr.w.valid))
  io.ddr.r.ready  := Mux(useDesc, descFetch.io.ddr.r.ready,
                     Mux(useUnit, unitExec.io.ddr.r.ready, bypassExec.io.ddr.r.ready))
  io.ddr.b.ready  := Mux(useDesc, descFetch.io.ddr.b.ready,
                     Mux(useUnit, unitExec.io.ddr.b.ready, bypassExec.io.ddr.b.ready))
  when(useDesc) {
    io.ddr.ar.payload := descFetch.io.ddr.ar.payload
    io.ddr.aw.payload := descFetch.io.ddr.aw.payload
    io.ddr.w.payload  := descFetch.io.ddr.w.payload
  } elsewhen(useUnit) {
    io.ddr.ar.payload := unitExec.io.ddr.ar.payload
    io.ddr.aw.payload := unitExec.io.ddr.aw.payload
    io.ddr.w.payload  := unitExec.io.ddr.w.payload
  } otherwise {
    io.ddr.ar.payload := bypassExec.io.ddr.ar.payload
    io.ddr.aw.payload := bypassExec.io.ddr.aw.payload
    io.ddr.w.payload  := bypassExec.io.ddr.w.payload
  }
  for (m <- Seq(descFetch.io.ddr, unitExec.io.ddr, bypassExec.io.ddr)) {
    m.ar.ready  := io.ddr.ar.ready
    m.aw.ready  := io.ddr.aw.ready
    m.w.ready   := io.ddr.w.ready
    m.r.valid   := io.ddr.r.valid
    m.r.payload := io.ddr.r.payload
    m.b.valid   := io.ddr.b.valid
    m.b.payload := io.ddr.b.payload
  }

  // ---------------------------------------------------------------------------
  // 主 FSM
  // ---------------------------------------------------------------------------
  switch(state) {
    // ---------------- IDLE：等 go（单拍脉冲）----------------
    is(SchedState.IDLE) {
      when(io.go) {
        descAddrR  := io.descAddr
        descCountR := io.descCount
        idx        := U(0, 32 bits)
        unitIndexR := U(0, 32 bits)
        // ★ A-1b：per-run 复位（链长/链计数；`chainLenR=1` ⇒ 非链缺省）。
        chainLenR  := U(1, 16 bits)
        chainCnt   := U(1, 16 bits)
        // ★ C4b-B1：**帧首把前缀和指针打回基址**（`WGT_BLOB_BASE`），并清零帧内装载字节计数。
        //   `wgtBlobBaseR` 是主机经信箱区域 6 编程的（`0` ⇒ `UnitExec.dmaEn` 为假 ⇒ 走旧信箱通路）。
        wgtPtrR      := wgtBlobBaseR
        wgtBytesAccR := U(0, 32 bits)
        state      := SchedState.TAILCHK
      }
    }

    // ---------------- TAILCHK：先取下标 descCount 项（期望的哨兵位置）----------------
    is(SchedState.TAILCHK) {
      // 守 `DescFetch` 的契约：`go` 单拍，且只在 `busy==0` 时举（busy 覆盖内部主口在途相位）。
      when(!descFetch.io.busy) {
        descFetch.io.go := True
        state := SchedState.TAILCHKW
      }
    }

    // ---------------- TAILCHKW：必须有哨兵在 descCount；否则 COUNT 与哨兵不符 ⇒ err（零搬运）----------------
    is(SchedState.TAILCHKW) {
      when(descFetch.io.err) {
        errR  := True
        state := SchedState.IDLE
      }
      when(descFetch.io.words_valid) {
        when(isSentinel) {
          // COUNT 与哨兵自洽：空帧（descCount==0）直接收工，否则从第 0 项起走表。
          when(descCountR === U(0, 32 bits)) {
            state := SchedState.FRAMEDONE
          } otherwise {
            idx   := U(0, 32 bits)
            state := SchedState.FETCH
          }
        } otherwise {
          // 下标 descCount 处不是哨兵 ⇒ 表里还有载荷项没被 COUNT 覆盖（COUNT 少写了）⇒ 响亮 err + 零搬运。
          errR  := True
          state := SchedState.IDLE
        }
      }
    }

    // ---------------- FETCH：取第 idx 项载荷描述符 ----------------
    is(SchedState.FETCH) {
      when(!descFetch.io.busy) {
        descFetch.io.go := True
        state := SchedState.FETCHW
      }
    }

    // ---------------- FETCHW：哨兵出现在载荷里 ⇒ err；否则按 TYPE + ★A-1b `FLAGS[1:0]` 分派 ----------------
    is(SchedState.FETCHW) {
      when(descFetch.io.err) {
        errR  := True
        state := SchedState.IDLE
      }
      when(descFetch.io.words_valid) {
        when(isSentinel) {
          // 载荷里提前撞见哨兵（下标 < descCount）⇒ COUNT 与哨兵不符 ⇒ 响亮 err。
          errR  := True
          state := SchedState.IDLE
        } elsewhen(flagsReserved) {
          // ★ A-1b：`FLAGS[7:2]` 保留位非 0 ⇒ 非法编码 ⇒ 响亮 err + 零搬运。
          errR  := True
          state := SchedState.IDLE
        } elsewhen(!fieldsOk || !src2Ok) {
          // ★ C3.11b 规则 (3)/(4)：SRC/DST 32 B 对齐、IN_BYTES 非零且 32 B 对齐、
          //   `SRC/DST + IN_BYTES` 落在 DDR 窗内、非自环 —— 任一不满足 ⇒ 响亮 err。
          //   ★ E1（2026-10-13）：`!src2Ok` 同办（非 Add 带非零 SRC2_K / k 越界 / k > idx ⇒ 表非法）。
          //   ★ 零搬运：本态在 `unitExec.go` / `bypassExec.go` **之前**（一个激活字节都还没搬，
          //     一个 AR/AW/W 都还没发）；下游任何一层都看不到窗越界/自环/旁路项的 IN_BYTES。
          errR  := True
          state := SchedState.IDLE
        } elsewhen(!typeKnown) {
          // ★ C3.11b 规则 (2)：非法 TYPE（既不是 conv 类 / 旁路 / 哨兵，如 0x77、
          //   0x12 concat）⇒ 响亮 err（绝不静默跳过 —— 那会把"这层算错了"变成"这层没算却没人知道"）。
          //   ★ C4a.6：`0x03 depthwise` 已在 `isConv` 里（走 conv 同一条分派/链路），不再落到这里。
          errR  := True
          state := SchedState.IDLE
        } elsewhen(isConv) {
          when(isPlainE) {
            // plain（`0b01`）：一个 `go` 跑一片（`chainLen=1`），输入 DDR、输出 DDR（= S2 通路）。
            chainLenR := U(1, 16 bits)
            chainCnt  := U(1, 16 bits)
            // ★★ C4a-R2：把"喂 UnitExec 的 8 个字"落寄存器（下一拍 `RUNSTART` 的 `go` 已可用）
            for (k <- 0 until 8) { unitDescR(k) := descFetch.io.words(k) }
            // ★★ A'-2：本单元的**帧级指针推进** = `ceil32(N_0)`（单成员；用**本拍**的组合值 ——
            //   `chainSegLenR(0)` 此刻还是上一次的值）。旧式 `1 × N_0`（未对齐）⇒ 见 B2（A'-1.2）。
            nWgtAdvR  := segLenFetch
            state     := SchedState.RUNSTART
          } elsewhen(isHeadE) {
            // head（`0b00`）：锁存**链首**的 8 个字，开始向前扫链（直到撞上 tail）。
            chainCnt := U(1, 16 bits)
            for (k <- 0 until 8) { headW(k) := descFetch.io.words(k) }
            // ★★ A'-2：链首那一片先计入（随后每个 middle/tail 各累加自己那一片；见 tail 分支）。
            nWgtAdvR := segLenFetch
            state := SchedState.CHAINSCAN
          } otherwise {
            // middle/tail 作为分派起点 ⇒ **没有前驱** ⇒ 响亮 err + 零搬运（这是 A-1b 的新负对照）。
            errR  := True
            state := SchedState.IDLE
          }
        } otherwise {
          // ★ C3.11b：这里是**旁路项**（`TYPE ∈ {0x10,0x11,0x13,0x14}`）—— 上面四个分支已把
          //   `哨兵 / 保留位非 0 / 字段非法 / 非 conv / 非法 TYPE` 全部拦下，剩下的只可能是旁路。
          //   （`isBypass` 在这里**故意**不写成条件：写成条件的话，"未知 TYPE ⇒ err" 就只剩最后一条
          //    `otherwise`；那样一旦预检被改坏，未知 TYPE 会**静默**掉进旁路分派 —— 现在的形状让它
          //   要么被 `!typeKnown` 拦下、要么在这里被 `isPlainE` 之外的旁路项拦下。）
          //   ★ A-1b：旁路项**不在链里**（它没有"片上那根连线"）⇒ 必须恰好是 plain（`0b01`）。
          when(isPlainE) {
            chainLenR := U(1, 16 bits)
            chainCnt  := U(1, 16 bits)
            state     := SchedState.BYPSTART
          } otherwise {
            errR  := True
            state := SchedState.IDLE
          }
        }
      }
    }

    // ---------------- ★ A-1b CHAINSCAN：取链上的下一项（下标 idx + chainCnt）----------------
    is(SchedState.CHAINSCAN) {
      when(!descFetch.io.busy) {
        descFetch.io.go := True
        state := SchedState.CHAINSCANW
      }
    }

    // ---------------- ★ A-1b CHAINSCANW：middle ⇒ 继续扫；tail ⇒ 链扫完；其余 ⇒ 响亮 err ----------------
    is(SchedState.CHAINSCANW) {
      when(descFetch.io.err) {
        errR  := True
        state := SchedState.IDLE
      }
      when(descFetch.io.words_valid) {
        // 链上的条目也必须：不是哨兵、保留位为 0、是 conv、几何与链首一致，且**逐项字段合法**
        // （★ C3.11b：链上的每一项都是载荷项 ⇒ 规则 (3)/(4) 对它同样成立：对齐 / IN_BYTES /
        //   DDR 窗 / 自环。链的 `DST` 取**链尾**的 ⇒ tail 的 `DST_ADDR` 会被真正用到；
        //   而 head/middle 的 `DST_ADDR` 是片上占位槽 —— 主口看不到它，只能在这里查）
        // —— 任一不满足 ⇒ 响亮 err（仍在**取表相位** ⇒ 零搬运）。
        when(isSentinel || flagsReserved || !isConv || !geomEq || !fieldsOk || !src2Ok) {
          errR  := True
          state := SchedState.IDLE
        } elsewhen(isMidE) {
          // middle：还要继续扫（至少还要一个 tail）⇒ 若"再加一个 tail"都超 L_MAX，则链必然过长 ⇒ err。
          when((chainCnt + U(2, 16 bits)) > U(L_MAX, 16 bits)) {
            errR  := True
            state := SchedState.IDLE
          } otherwise {
            chainCnt := chainCnt + U(1, 16 bits)
            state    := SchedState.CHAINSCAN
          }
        } elsewhen(isTailE) {
          // tail：链扫完。链长 = 已计入条目数 + 1（这个 tail）；超过 L_MAX ⇒ 响亮 err。
          when((chainCnt + U(1, 16 bits)) > U(L_MAX, 16 bits)) {
            errR  := True
            state := SchedState.IDLE
          } otherwise {
            chainLenR := chainCnt + U(1, 16 bits)
            chainCnt  := chainCnt + U(1, 16 bits)
            // ★★ C4a-R2：喂 UnitExec 的 8 个字 = 锁存的**链首**字 + 链尾的 `DST_ADDR`（`w5`）。
            //   在这里（而不是 RUNSTART）锁存 ⇒ 下一拍 `go` 时 `unitDescR` 已稳定，**零延迟代价**。
            //   （`headW` 已在 FETCHW 的 head 分支落寄存器 ⇒ 这里只是把它搬到 `UnitExec` 的口上。）
            //   旧的 `tailDstR` 就是这一路的中间量，已随本改动删除（见 `headW` 的声明注释）。
            for (k <- 0 until 8) {
              unitDescR(k) := (if (k == 5) descFetch.io.words(5) else headW(k))
            }
            // ★★ A'-2：**帧级指针推进** = 本条链的**逐片对齐段长和** `Σ_k ceil32(N_k)`
            //   （`chainAdvFetch` 在本拍 == 整条链的和：已扫过的成员取槽寄存器、本拍这一片取组合值）。
            nWgtAdvR  := chainAdvFetch
            state     := SchedState.RUNSTART
          }
        } otherwise {
          // head / plain 跟在一个 head/middle 后面（= 链断裂 / head 没有 tail）⇒ 响亮 err + 零搬运。
          errR  := True
          state := SchedState.IDLE
        }
      }
    }

    // ---------------- RUNSTART：给 UnitExec 举一拍 go（守住 busy==0 才举）----------------
    is(SchedState.RUNSTART) {
      when(!unitExec.io.busy) {
        unitExec.io.go := True
        state := SchedState.RUNW
      }
    }

    // ---------------- RUNW：等本单元 done（单拍）/ err ----------------
    is(SchedState.RUNW) {
      when(unitExec.io.err) {
        errR  := True
        state := SchedState.IDLE
      }
      when(unitExec.io.done) {
        // ★ A-1b：一次 `go` 消费 `chainLenR` 个载荷条目 ⇒ 遥测按**条目数**推进（帧末 == descCount）。
        unitIndexR := unitIndexR + chainLenR.resize(32)
        // ★★ A'-2（B2 修法）：**表序前缀和**推进 —— 本单元的权重段是 blob 里**逐片 32 B 对齐**的
        //   `Σ_k ceil32(N_k)` 字节（`nWgtAdvR` 已在分派那一拍定案：plain = `ceil32(N_0)`、
        //   链 = 沿链逐片累加 **每片自己**的 `ceil32(N_k)`）⇒ 指针 += `nWgtAdvR`。
        //   ★ 旧式 = `chainLen × N_head`（**未对齐**、且对逐片几何不同的链是错的）：实测 19/19 run
        //     漂移（`reports/ts3g_chain_caliber.md` §3）、帧级 52/53 单元错位 ⇒ 本行是 B2 的落点。
        wgtPtrR := (wgtPtrR + nWgtAdvR).resize(32)
        // ★ C4b-B1：帧内真正装载的权重字节数（`UnitExec.wgt_bytes` 是**每 run** 的计数，此刻未复位）。
        wgtBytesAccR := wgtBytesAccR + unitExec.io.wgt_bytes
        state      := SchedState.NEXT
      }
    }

    // ---------------- ★ C3.10b BYPSTART：给 BypassExec 举一拍 go（同一条 busy==0 纪律）----------------
    is(SchedState.BYPSTART) {
      when(!bypassExec.io.busy) {
        bypassExec.io.go := True
        state := SchedState.BYPW
      }
    }

    // ---------------- ★ C3.10b BYPW：等旁路单元 done（单拍）/ err ----------------
    is(SchedState.BYPW) {
      when(bypassExec.io.err) {
        errR  := True
        state := SchedState.IDLE
      }
      when(bypassExec.io.done) {
        unitIndexR := unitIndexR + 1
        state      := SchedState.NEXT
      }
    }

    // ---------------- NEXT：还有载荷就取下一项，否则收工 ----------------
    //   ★ A-1b：步进 = `chainLenR`（一次 `go` 消费了 `chainLenR` 个条目：plain/旁路 = 1，链 = 链长）。
    is(SchedState.NEXT) {
      when((idx + chainLenR.resize(32)) === descCountR) {
        state := SchedState.FRAMEDONE
      } otherwise {
        idx   := idx + chainLenR.resize(32)
        state := SchedState.FETCH
      }
    }

    // ---------------- FRAMEDONE：整帧唯一的一次 frameDone（单拍），回 IDLE ----------------
    is(SchedState.FRAMEDONE) {
      frameDoneR := True
      state      := SchedState.IDLE
    }
  }

  // ---------------------------------------------------------------------------
  // 输出
  // ---------------------------------------------------------------------------
  io.busy      := (state =/= SchedState.IDLE)
  io.err       := errR
  io.unitIndex := unitIndexR
  /** ★ C4b-B1：帧内真正装载的权重字节数（未走 DMA 的帧恒 0）。 */
  io.wgt_bytes := wgtBytesAccR
  // ★ 原始 IRQ 脉冲：整帧唯一。写法刻意保持"判据只看 state==FRAMEDONE"这一条**可读/可突变**的形状
  //   （负对照 A 的网表突变就把它改成"每个单元也抬" ⇒ 帧内中断计数 > 0）。
  val frameEnd = (state === SchedState.FRAMEDONE)
  io.frameDone := frameEnd
}
