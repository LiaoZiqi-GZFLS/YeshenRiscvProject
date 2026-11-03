import spinal.core._
import spinal.lib._
import spinal.lib.bus.amba4.axi._

/** 状态（显式枚举，生成 Verilog 里就是一个 `DdrState` 型寄存器）。
  * 命名不用裸 `State`：本组件里已经有 `val state`，两者混着写以后不好读。
  *
  * C3.3 在末尾追加两个状态（`WSTR` / `RDSTR`，12 个值仍是 4 bit）：
  *   WSTR  = WR 模式：从 `wr_stream` 收 `beats` 拍填块缓冲（AW/W 之前的那一段）；
  *   RDSTR = RD 模式：把块缓冲按拍推给 `rd_stream`（WR 本来的位置）。
  * 插在 `NEXT` 之后是因为它俩正是 NEXT 的两个岔路：NEXT -> {WSTR? RDSTR? WR}。
  *
  * 块拷贝（mode=0）：**每块 <=128 B，先整块读进块缓冲、再把该块整块写出去，如此往复**。
  *   IDLE -> CHK -> [ AR -> R -> NEXT -> WR -> W -> WB -> WNEXT ] x N -> DONE
  * 读写**不重叠**（桥的 `wrState`/`rdState` 互斥，见 `src/soc/DDR3Bridge.scala:191/287`）：
  * 同一块的 R 数据收完（末拍 -> NEXT）之后才进写相位；下一块的 AR 要等本块的 B 响应落地
  * （WNEXT）之后才举 —— 两个相位在时间上被 FSM 结构性地切开，绝不会同时举读和写。
  * （C3.3 的 RD 模式只有读相位、WR 模式只有写相位，两者各自与 COPY 同形，重叠问题不存在。）
  */
object DdrState extends SpinalEnum {
  val IDLE, CHK, AR, R, NEXT, WSTR, RDSTR, WR, W, WB, WNEXT, DONE, QRUN, SGRUN = newElement()
}

/** AXI4 主口的形状参数（接口冻结：读路径 / 写路径 / 块拷贝共用同一份 cfg）。
  *
  *   ADDR_W      —— 地址位宽 28（与源仓 `src/soc/DDR3Bridge.scala` 的 DDR 侧地址口径同量级；
  *                  也够寻址本任务用到的几百 KB ~ 几 MB 块）。
  *   DATA_W      —— 数据 64 bit（P1）。
  *   ID_W        —— id 4 bit（P1）。
  *   CHUNK_BYTES —— 片上块缓冲字节数 = 一笔突发的字节数 = 128 B（P3：16 拍 x 8 B）。
  */
case class DdrMasterConfig(
  ADDR_W:      Int = 28,
  DATA_W:      Int = 64,
  ID_W:        Int = 4,
  CHUNK_BYTES: Int = 128
)

/** 总线桥的**行为约束**（本文件的中心约定，来自 `src/soc/DDR3Bridge.scala`，不是可选项）：
  *
  *   P1 数据 64 bit / id 4 bit / wstrb 8 bit —— 与 `AXIIO64` 逐条对齐（见 cfg 与 Axi4Config）。
  *   P2 **单 outstanding** —— 任何时刻在途的 AXI 事务**至多一笔**。本文件里这一点是**结构性**的：
  *      只有 AR/AW 通道有 valid 产生逻辑，且下一块 AR 要等本块的 B 响应落地（WNEXT）之后才举
  *      （FSM 里 AR 只从 CHK 和 WNEXT 进，R 到下一次 AR 至少隔着 NEXT/WR/W/WB/WNEXT）；
  *      没有 AR/AW 队列、没有多 id 重排。
  *   P3 突发 **32 B 对齐 + 长度是 4 拍的倍数** —— 本文件把它钉成**唯一形状**：
  *      每笔 AR/AW 一律 `len = beatsM1`（`beats = min(16, remain/8)` 拍，C3.3 之前恒 15 ⇒ 128 B）；
  *      且每一笔的地址低 5 bit **由构造恒为 0**：
  *      rbase/wbase 的初值是校验过的 32B 对齐 src/dst，每次 += `beats*8`（`beats` 是 4 的倍数
  *      ⇒ 是 32 的倍数）也保持对齐；
  *      **更硬的一层**：AR/AW 上驱动的地址是 `Cat(rbase[ADDR_W-1:5], 5'b00000)`（见 arAddr，
  *      写侧 awAddr 同形），低 5 位是 Verilog 里的字面 `5'b00000` ⇒ 静态可查、运行期不可能违反。
  *      为什么要额外钉死：桥对**一笔 DDR 事务 = 32 B** 的拆分依赖"首址 32B 对齐 + 长度是 32B
  *      整数倍"；违反它的主口不会报错，只会**静默搬错数据**。所以宁可让不合规的主口在
  *      `rtl_test/AxiMemModel.v` 里**响亮 $fatal**，也不能让它安静地过闸门。
  *
  * ★★★【操作契约：一次 `start` = 按 `io.mode` 解释的一次搬运】★★★
  *   端口表里**没有**独立的读/写选通脚（`mode` 是 C3.3 新增的**模式位**，与地址语义正交）；
  *   `start / src / dst / len / mode` 五个入参决定这一次搬运：
  *     mode=0（**默认**）：**一次块拷贝** —— 每块 <=128 B，**先整块读进块缓冲、再把该块整块写出去**，
  *                          从 `src` 的第 0 字节一路做到第 `len` 字节（C2 的全部语义都在这里）；
  *     mode=1：**只读** —— 每块 <=128 B，读进块缓冲后按拍推给 `rd_stream`，`dst` 不参与；
  *     mode=2：**只写** —— 每块 <=128 B，从 `wr_stream` 按拍灌进块缓冲后写出去，`src` 不参与。
  *   为什么把 C2.1a/C2.1b 那套"用地址当模式位"的做法整段删掉：
  *     · 旧口径是 `src =/= 0` ⇒ 有读相位、`dst =/= 0` ⇒ 有写相位（存进 `wr_mode`）。
  *       那是"单独测读半边 / 单独测写半边"的**临时装置**，对拷贝**根本不成立** ——
  *       拷贝的两个地址都非 0，两个标志同时成立、互相撞车；
  *     · 更根本的是语义错位：`src`/`dst` 是**地址**，地址 0 是一个合法地址，
  *       不该兼职当"模式位"。现在它们只承担地址语义，模式**只**由 `io.mode` 表达
  *       （C3.3 正是把"读半边/写半边"这件事重新做成一个**显式的、正交的**模式位，
  *        而不是回头去动地址）。
  *
  *   入参校验（CHK 态；非法 ⇒ err 一拍脉冲、回 IDLE、**一个字节都不搬**）：
  *   · `src` / `dst` 低 5 位为 0（32 B 对齐，P3）；
  *   · `len % 32 == 0` 且 `len > 0`（C3.3：128 B -> 32 B 粒度）。
  *   为什么旧口径要求 **128** 的整数倍：那时一笔突发的长度被 P3 钉死成 `arlen/awlen = 15`
  *   （恒 16 拍 = 128 B），**没有**"尾块缩短突发"这回事 —— 若允许 `len % 128 != 0`，尾块就会按
  *   完整 128 B 读/写**越过 len 的边界**，多搬出去几个 32 B 单位。这种越界在桥上**不会报错**，
  *   只会静默改掉别的数据 ⇒ 所以旧口径把它做成**显式 err**：宁可让非法调用一字节不搬，也绝不
  *   允许它安静地多拷一截。C3.3 把"尾块缩短突发"真的实现了（见下），越界这个理由**消失**，
  *   于是粒度放宽到 32 B（一个描述符的大小）。
  *
  * ★★★【尾块缩短突发（C3.3）—— COPY 路径的分块因此逐拍不变】★★★
  *   每块的拍数 `beats` 不再是常量 16，而是 `beats = min(16, remain/8)`，`arlen/awlen = beats-1`：
  *     · `remain >= 128` ⇒ `beats = 16`、`arlen/awlen = 15` —— **COPY 且 len 是 128 的整数倍时
  *       这条恒成立**（remain 从 len 起每块减 128，永远是 128 的倍数且 >= 128）⇒ 分块、地址序列
  *       （每次 +128）、AW/W 次序、`cyc` 与 C2 逐拍同形。
  *     · `remain <  128` ⇒ 尾块只 32/64/96 B（4/8/12 拍），块缓冲仍 128 B、只用前 `beats*8` 字节。
  *   地址仍 32 B 对齐：初值 src/dst 已校验 32B 对齐，每次 += `beats*8`（beats 是 4 的倍数 ⇒
  *   `beats*8` 是 32 的倍数）；**更硬的一层**：AR/AW 上驱动的地址仍是
  *   `Cat(base[ADDR_W-1:5], 5'b00000)`，低 5 位是字面 `5'b00000` ⇒ 运行期不可能违反 P3。
  *   "arlen/awlen <= 15"同样是**结构性**的：驱动它的寄存器 `beatsM1` 只有 4 bit，而它唯一的
  *   装载源是 `beatsM1For()`（两条分支分别给常量 15 与 `(0..11)`）⇒ 不靠"调用点算术恰好正确"。
  *
  * 读相位 FSM：CHK -> AR -> R -> NEXT -> WR（COPY 下 NEXT 之后**必定**进写相位）
  *   IDLE  等 start；
  *   CHK   校验入参（非法 ⇒ err 一拍、回 IDLE）；合法则装载 rbase/wbase/remain/beatsM1 后进 AR
  *         （`mode==2` 则直接进 WSTR，见"三种模式"）；
  *   AR    举 arvalid/araddr/arlen=beatsM1，等 arready；
  *   R     收 `beats` 拍进块缓冲、rd_bytes 每拍 +8；末拍 -> NEXT；
  *   NEXT  本块读完了 ⇒ `mode==1` 去 RDSTR 把缓冲推给 rd_stream，否则进 WR 把这一块写出去。
  * 写相位 FSM：WR -> W -> WB -> WNEXT
  *   WR    举一笔 awvalid/awaddr/awlen=beatsM1（`beats` 拍 x 8B），等 awready；
  *   W     逐拍举 wvalid，wdata = 块缓冲第 wbi 拍的 8 字节、wstrb = 掩码缓冲第 wbi 拍
  *         （★ T-S2b：默认 8'hFF；WR 模式下由 `io.wstrb` 逐拍装入）、wlast= 末拍；
  *         每拍握手 wr_bytes += 8；走完 `beats` 拍 -> WB；
  *   WB    等 bvalid（`b.ready` 只在本状态举）—— 收到响应才算这一块写落地；
  *   WNEXT 还有块（`remain > beats*8`）⇒ `remain/rbase/wbase` 各 += `beats*8`、重算 beatsM1、
  *         `mode==2` 回 WSTR 否则回 AR；没了 -> DONE；
  *   DONE  出 done 一拍脉冲、回 IDLE。
  *
  * ★★★【三种模式（C3.3）——`io.mode`】★★★
  *   0 = COPY（**默认**）：CHK -> [AR -> R -> NEXT -> WR -> W -> WB -> WNEXT] x N -> DONE。
  *       与 C2 **完全相同**（上面已论证逐拍/逐字节同形）。`rd_bytes == wr_bytes == len` 仍成立。
  *   1 = RD（只读；描述符取表、激活流进融合缓冲）：CHK -> [AR -> R -> NEXT -> RDSTR -> WNEXT] x N -> DONE。
  *       R 收满本块后**不做 WR**，把块缓冲按拍推 `rd_data/rd_valid`（等 `rd_ready`）—— 推 `beats` 拍。
  *       `wr_bytes` 恒 0；`rd_bytes == len`。
  *   2 = WR（只写；从融合缓冲/上游流写出去）：CHK -> [WSTR -> WR -> W -> WB -> WNEXT] x N -> DONE。
  *       **不做 AR/R**：WSTR 从 `wr_data/wr_valid` 收 `beats` 拍填块缓冲（`wr_ready` 只在 WSTR 举），
  *       然后走 AW -> W -> B（**W 仍在 AW 成交之后才举**，与 COPY 同一条纪律）。`rd_bytes` 恒 0；
  *       `wr_bytes == len`。
  *   3 = **未定义（保留编码）**：当前**静默等价于 COPY** —— 三处模式判据只在 `mode==2`（CHK/WNEXT）
  *       与 `mode==1`（NEXT）改道，`mode==3` 全部落到 `otherwise` ⇒ 与 COPY 同形。这是**有意保留**
  *       的空档（2 bit 里留一格，未来若加第四种模式再填），**当前不为它另造 err**（避免与"只认 1/2"
  *       的判据重复）。⚠️ 调用方**不得依赖** "mode==3 ≡ COPY" 这条偶然行为：该编码被填时语义会变。
  *   模式的**结构性**保证（不是靠"记得掩掉另一侧"）：
  *     · AR 只从 CHK / WNEXT 进，而这两处 `mode==2` 都改道 WSTR ⇒ WR 模式下 AR 永不被举；
  *     · WR 只从 NEXT（COPY）/ WSTR（WR）进，而 NEXT 在 `mode==1` 改道 RDSTR ⇒ RD 模式下 AW 永不被举；
  *     · `r.ready` / `b.ready` 分别只在 R / WB 态举，AR/AW 分别只在 AR / WR 态举 —— 全是状态可达性。
  *   ★ 入参必须被驱动（**不是**"旧调用方可以不管"）：SpinalHDL 会拒绝**悬空的组件输入**
  *     （`NO DRIVER ON ...`，展开期就报错），所以**树内每个 Scala 调用方都必须显式驱动**
  *     `mode`（以及 `rd_ready`/`wr_valid`/`wr_data`）—— 全 0 即 COPY（`rd_ready=0`/`wr_valid=0`
  *     也正好让流侧静默），见 `NpuTop.scala` 的接法。全部模式判据都写成
  *     `when(mode===1/2) {...} otherwise {...}`（**不用 `Mux`**：三目在条件是 X 时会按位
  *     混合出 X，那会把状态寄存器打进 X）。
  *     ⚠️ "不连它就等价于 mode=0（COPY）"**只在手写 Verilog 的边界上**成立（悬空 = z ⇒
  *     `mode === 1/2` 求值为 X ⇒ `if (X)` 取 else）—— 例如复用的旧 Verilog 装置；它**不能**
  *     当作 Scala 侧的豁免理由：在 Scala 里不驱动就是展开失败，不是"默认走 COPY"。
  *
  * ★ 计数口径（明说）：`rd_bytes` / `wr_bytes` 记的是**总线上真正读回/写出的字节数**。
  *   COPY：每块恰好读一次、写一次 ⇒ `rd_bytes == wr_bytes == len`；
  *   RD  ：只有读相位 ⇒ `rd_bytes == len`、`wr_bytes == 0`（结构性：wr_r 只在 W 态加，RD 到不了 W）；
  *   WR  ：只有写相位 ⇒ `rd_bytes == 0`、`wr_bytes == len`（rd_r 只在 R 态加，WR 到不了 R）。
  *   所以闸门可以用上面这三条当运行期判据，并与内存模型的
  *   `MEM rd=<bytes> wr=<bytes> bursts=<n>` 交叉对账（两处独立计数一起对上才算数）。
  *
  * ★★★【W 必须与 AW 同门 —— 本文件选 (a)：先 AW、等 awready、再 W】★★★
  *   出处 `src/YeshenSocGlue.scala:764` 的 ★ 注释（逐字引用）：
  *     "W 必须与 AW 同门（不能只修 awready）"。
  *   它讲的事（该文件 `:764-775` 逐行核实过）：核的 `Axi4Bridge` 里 **W 的放行与 AW 无关**
  *     （`rtl/NaxSocMini.v:15628 io_down_w_valid = a_data_buffer_valid`，
  *      `:15629 a_data_buffer_ready = io_down_w_ready`），且命令判据是 `valid && ready`
  *     （`rtl/NaxSocMini.v:11133/11154`）⇒ 若只把 `awready` 拉低而让 W 照走，核会**以为写已成交**
  *     而**永不重发**，同时从方把 W 当 orphan 丢掉 ⇒ 写数据丢失。板上下游桥同理：
  *     `DDR3Bridge` 是 `axi.aw.awready := wrState === sWrIdle`（`src/soc/DDR3Bridge.scala:191`）
  *     且 `axi.w.wready := wrState === sWrAgg`（`:192`）—— **awready 与 wready 在两个互斥状态里**，
  *     AW 未收下时它本来就不收 W。所以正确写法只有两种，本文件**选 (a)**：
  *       (a) 先举 AW、等 `awready`（WR 态），**收到之后**才进 W 态举 W —— W 的呈现**结构上晚于**
  *           AW 成交，绝不可能出现"W 已发出而 AW 没被收下"的孤儿 W；
  *       (b) AW 与 W **同一窗口**一起举、W 保持到 `wready`（合法 AXI，桥也兼容）。
  *   选 (a) 的理由：它与桥 `wrState`（AW 只在 sWrIdle 收、W 只在 sWrAgg 收）**逐态同形**，
  *   且对将来的 merger（把"写命令被拒"表达为拉低 `awready`+`wready`）最稳——被拒时我们**根本不会**
  *   举起 W，从根上消掉"AW 压住、W 照发"这一类退化，而不是靠"记得同时掩 W"的纪律。
  *   （不会死锁：桥的 `io_down_aw_valid` 只看 `a_cmd_buffered_valid`，不看 `io_down_w_ready`。）
  *
  *   ★ 写半边的 payload **不再是常值 0**（旧任务里那段"tie-off"已整段删掉）：AW 的
  *   size/burst/id/cache/prot 仍是常值（业务恒定，静态可查），len 是每块量 `beatsM1`
  *   （COPY 时恒 15），addr 由 wbase 派生且低 5 位由构造恒 0（同读侧的 P3 纪律）；
  *   W 的 data/strb/last 是每拍量。
  */
class DdrMaster(cfg: DdrMasterConfig, defName: String = "", rqDepth: Int = 4) extends Component { if (defName != "") setDefinitionName(defName)  // DMA-fix: 空串=保持 SpinalHDL 自动名 DdrMaster（NpuTop 不变）；DmaEngine 传 "DmaDdrMaster" ⇒ 同一设计不撞名（先例 NpuAxiLiteCdc.CdcPipeSp.defName；判据 y1/tools/check_dup_modules.py）。★ 刻意与类声明同行：DdrMaster.scala 的行号会被嵌进内部网名 when_DdrMaster_l<行号>，零净行变化才能「只换模块名、其余逐字节不变」。

  /** 一拍多少字节。 */
  val BYTES_PER_BEAT: Int = cfg.DATA_W / 8
  /** 一笔突发（= 一个块）多少拍。 */
  val BEATS_PER_CHUNK: Int = cfg.CHUNK_BYTES / BYTES_PER_BEAT

  require(cfg.DATA_W == 64, "P1：数据必须 64 bit（与 AXIIO64 对齐）")
  require(cfg.ID_W == 4, "P1：id 必须 4 bit（与 AXIIO64 对齐）")
  require(cfg.CHUNK_BYTES % BYTES_PER_BEAT == 0, "块字节数必须是拍字节数的整数倍")
  require(cfg.CHUNK_BYTES % 32 == 0, "P3：块字节数必须是 32 B 的整数倍")
  require(BEATS_PER_CHUNK == 16, "P3：本任务把一笔突发钉死成 16 拍 = 128 B（arlen=15）")
  require(rqDepth >= 1 && isPow2(rqDepth), "L2b：RD 预取槽数必须是 2 的幂（1 = 退化为单块串行）")

  /** 满块的突发长度域 = 15（16 拍 = 128 B）。C3.3 之后它不再直接驱动 AR/AW（那里是每块量
    * `beatsM1`），只作为 `beatsM1` 的复位值 + "满块口径"的单一真源。 */
  private val ARLEN = BEATS_PER_CHUNK - 1
  /** size 域 = log2(每拍字节数) = 3（64 bit 数据）。 */
  private val ARSIZE = log2Up(BYTES_PER_BEAT)

  val axiCfg = Axi4Config(
    cfg.ADDR_W, cfg.DATA_W, idWidth = cfg.ID_W,
    useId = true, useLen = true, useLock = false, useRegion = false, useQos = false,
    awUserWidth = 0, arUserWidth = 0, wUserWidth = 0, bUserWidth = 0, rUserWidth = 0
  )

  val io = new Bundle {
    val start  = in  Bool()
    val src    = in  UInt(cfg.ADDR_W bits)   // 源地址，必须 32B 对齐
    val dst    = in  UInt(cfg.ADDR_W bits)   // 目标地址，必须 32B 对齐
    val len    = in  UInt(32 bits)           // 字节数，必须是 32 的正整数倍（C3.3 放宽；见文件头）
    /** 模式（C3.3 新增）：0=COPY（默认，块拷贝）1=RD（只读 ⇒ 推到 rd_str）2=WR（只写 ⇐ wr_str）。
      * **树内 Scala 调用方必须显式驱动它**（SpinalHDL 拒绝悬空输入；全 0 即 COPY，见 NpuTop）。
      * Verilog 侧的旧装置若真悬空它，则靠手写 Verilog 的 `if (X)` 取 else ⇒ 等价 mode=0（COPY）。 */
    val mode   = in  UInt(2 bits)
    /** ★★ B3b（2026-10-21）：**多事务散读队列**（mode=3 专用）。
      *   在 IDLE 里逐项入队 `{addr, beatsM1}`（最多 8 项），再 `start(mode=3)` ⇒ 一次处理整批：
      *   AR 按队序背靠背发出（受 `rqDepth` 槽数限制、多笔在飞），R 按序落槽，`rd_stream` 按队序
      *   推出，整批做完才 `done` 一拍。**非 3 模式完全不用这些口**（不接线即无副作用）。
      *   入队只允许 IDLE；非法项（地址非 32 B 对齐 / 拍数不是 4 的倍数）⇒ `sg_ready=0` + `err` 一拍；
      *   队满同样反压（不静默丢）。模式 3 的 `src/dst/len` 不参与（搬运形状由队列决定）。 */
    val sg_valid   = in  Bool()
    val sg_ready   = out Bool()
    val sg_addr    = in  UInt(cfg.ADDR_W bits)
    val sg_beatsM1 = in  UInt(4 bits)
    /** ★★ B3b-2：**清队**（只在 IDLE 生效）。宽路 gather 在趟收工时可能只入队了半批
      *   （pass 结束先于 `start`）⇒ 下一趟起步先清掉这些"永远不会 start"的残留项。 */
    val sg_flush   = in  Bool()
    val busy   = out Bool()
    val done   = out Bool()                  // 单拍脉冲
    val err    = out Bool()                  // 入参非法 ⇒ 立刻 err，不搬
    val cyc    = out UInt(32 bits)           // start 到 done 的拍数
    val rd_bytes = out UInt(32 bits)
    val wr_bytes = out UInt(32 bits)
    // ---- C3.3 新增：RD 模式的块缓冲推出 / WR 模式的块缓冲填入（两者与 AXI 数据相位无关）----
    val rd_valid = out Bool()                // RD 模式：块缓冲的 8 字节推出
    val rd_ready = in  Bool()                //   （只在 RDSTR 态举 valid，等对流 ready）
    val rd_data  = out Bits(cfg.DATA_W bits) //   小端：rd_data[8j+7:8j] = 块缓冲第 (rdi*8+j) 字节
    val wr_valid = in  Bool()                // WR 模式：从流填块缓冲
    val wr_ready = out Bool()                //   （只在 WSTR 态举 ready）
    val wr_data  = in  Bits(cfg.DATA_W bits) //   小端：wr_data[8j+7:8j] -> 块缓冲第 (wbi*8+j) 字节
    /** ★★ T-S2b：**写字节掩码**（每拍 8 bit，与 `wr_data` 同拍；WR 模式专用）。
      *   `8'hFF`（= 全部字节有效）⇒ 与改动前**逐字节/逐拍同形**（COPY / RD 模式恒为它）。
      *   为什么需要它：tile 循环下，一个 tile 的"输出行段"是**非 32 B 整数倍**的连续字节
      *   （例：`s=2` 的 tile 宽 16 B；`Wo=20` 的行段 20 B），而冻结的 DDR 写纪律是
      *   "地址 32 B 对齐 + 长度 32 B 整数倍" ⇒ 必须把**段外**的字节掩掉，否则会踩到邻居
      *   （本 tile 没算过的列）。`wstrb` 就是把"这一段有效"表达出来的唯一手段；
      *   掩掉的字节**不写**（AXI 语义），数据为 don't-care。 */
    val wstrb    = in  Bits(cfg.DATA_W / 8 bits)
    val buf_dout = out Vec (UInt(8 bits), cfg.CHUNK_BYTES)  // 块缓冲内容（供 tb 观察）
    val axi    = master(Axi4(axiCfg))
  }
  noIoPrefix()

  // ---------------------------------------------------------------------------
  // 块缓冲：CHUNK_BYTES 个 8bit 寄存器（一笔突发的落点）。写用**静态下标解码**
  // （beat 索引 -> 8 个字节各一条 when），不用 buf(dynIdx) 的动态写 —— 后者会生成
  // 一把 128 路的桶形移位译码器，Verilog 面目全非、也没法逐字对账。
  // ---------------------------------------------------------------------------
  val buf = Vec(Reg(UInt(8 bits)) init (0), cfg.CHUNK_BYTES)

  // ★★ T-S2b：**写字节掩码的块缓冲**（与 `buf` 同形状、同生命周期；初值 `8'hFF` ⇒ 未被 WR 模式
  //   写过的块恒为"全字节有效" ⇒ COPY / RD 两条既有模式**逐拍同形**，不需要任何模式门）。
  //   只在 `WSTR` 态按 `wbi` 静态下标写入（与 `buf` 的填法同一套纪律）。
  val sbuf = Vec(Reg(Bits(BYTES_PER_BEAT bits)) init (B(0xFF, BYTES_PER_BEAT bits)), BEATS_PER_CHUNK)

  // ---------------------------------------------------------------------------
  // 显式 FSM
  // ---------------------------------------------------------------------------
  val state = Reg(DdrState()) init DdrState.IDLE

  // 读侧寄存器
  val rbase  = Reg(UInt(cfg.ADDR_W bits)) init (0)  // 本块读突发的起始地址（32B 对齐）
  val remain = Reg(UInt(32 bits)) init (0)          // 还没搬完的字节数（块粒度递减，读/写共用一份）
  val bi     = Reg(UInt(4 bits)) init (0)           // 读块内第几拍 0..beats-1
  val cyc_r  = Reg(UInt(32 bits)) init (0)
  val rd_r   = Reg(UInt(32 bits)) init (0)
  val err_r  = Reg(Bool()) init False
  val done_r = Reg(Bool()) init False

  // 写侧寄存器（与读侧同形，各一份 ⇒ 读相位与写相位互不干扰）
  val wbase  = Reg(UInt(cfg.ADDR_W bits)) init (0)  // 本块写突发的起始地址（32B 对齐）
  val wbi    = Reg(UInt(4 bits)) init (0)           // 写/fill 块内第几拍 0..beats-1（WR 模式的 WSTR 也用它）
  val wr_r   = Reg(UInt(32 bits)) init (0)          // 已写出的字节数

  // ---------------------------------------------------------------------------
  // C3.3 新增寄存器
  // ---------------------------------------------------------------------------
  /** 本块拍数 - 1 = 直接驱动 arlen/awlen 的那个值（4 bit ⇒ **结构上不可能 > 15**）。
    * 唯一的装载源是 `beatsM1For()`（见下），CHK 与 WNEXT 各一次。 */
  val beatsM1 = Reg(UInt(4 bits)) init (ARLEN)
  /** RD 模式：块缓冲推出去推到第几拍（0..beats-1）。RDSTR 用它当下标。 */
  val rdi     = Reg(UInt(4 bits)) init (0)

  // ===========================================================================
  // ★★ L2b（2026-10-18）：**mode=1 的块槽预取** —— 只作用于 RD 模式。
  //   `DdrMaster` 的旧 RD 路径对**一行 >128 B** 的请求是「AR→R→RDSTR→WNEXT→AR」逐块串行；
  //   gather 的一行典型 272 B ⇒ 3 次 AR 往返。这里给 RD 模式加 `rqDepth` 个 128 B 槽：
  //   AR 提前发到后面若干块，R 按序落槽，消费端从槽 0 逐拍推出（`rd_valid/rd_ready` 契约不变）。
  //   顺序纪律：同 AXI ID、按序 AR、按序 R ⇒ 槽按「发/收/排」三个自由计数器轮转即可：
  //     slot = counter mod rqDepth；三者差值恒 ≤ rqDepth。
  //   模式 0（COPY）与模式 2（WR）**完全不进这些寄存器**；`rqDepth=1` 时退化为逐块串行
  //   （槽 0 等排空才发下一块，作负对照）。
  // ===========================================================================
  private val RQ = rqDepth
  // 槽数下限 2：SpinalHDL 的 Vec 用 1 个元素时索引位宽为 0，动态下标无法表达；
  // RQ=1 时用 2 个槽轮转（同时只允许 1 块在飞 ⇒ 结构性退化，槽号仍不会冲突）。
  private val QSLOTS = RQ max 2
  private val RQW = log2Up(QSLOTS) max 1
  val qbuf = Vec.fill(QSLOTS)(Vec.fill(cfg.CHUNK_BYTES)(Reg(UInt(8 bits)) init (0)))
  /** 每个槽的块拍数-1（尾块可短）。 */
  val qLen = Vec.fill(QSLOTS)(Reg(UInt(4 bits)) init (0))
  /** 还没发出去的字节数 / 下一块的读地址。 */
  val qRemain = Reg(UInt(32 bits)) init (0)
  val qAddr   = Reg(UInt(cfg.ADDR_W bits)) init (0)
  /** 已发块数 / 已收完块数 / 已排空块数（每笔 `start` 从 0 起，单笔请求内块数很小）。 */
  val qIssCnt = Reg(UInt(16 bits)) init (0)
  val qRcvCnt = Reg(UInt(16 bits)) init (0)
  val qDrCnt  = Reg(UInt(16 bits)) init (0)
  /** 当前收/排的块内拍号。 */
  val qBeat   = Reg(UInt(4 bits)) init (0)
  val qDrBeat = Reg(UInt(4 bits)) init (0)

  // ===========================================================================
  // ★★ B3b（2026-10-21）：**多事务散读队列**（mode=3，SG-RD）。
  //   与 QRUN 的区别：QRUN 的地址在**一笔连续事务内** `qAddr += bytes`；SG 的每一项是
  //   **独立 32B/64B/96B/128B 事务**（地址来自队列），AR 按队序背靠背发、R 按序落同一个 qbuf 槽流。
  //   槽指针 `sgIss/sgRcv/sgDr` 与 QRUN 的三计数器同构；qbuf/qLen 两种状态互斥复用。
  //   队列只在 IDLE 写、只在 SGRUN 读；DONE 清空 ⇒ 下一批重新入队（不做环形回绕，最省）。
  // ===========================================================================
  private val SGD = 8
  private val SGW = 3
  val sgQAddr  = Vec.fill(SGD)(Reg(UInt(cfg.ADDR_W bits)) init (0))
  val sgQLen   = Vec.fill(SGD)(Reg(UInt(4 bits)) init (3))
  val sgCnt    = Reg(UInt(4 bits)) init (0)     // 队内项数 0..SGD
  val sgN      = Reg(UInt(4 bits)) init (0)     // 本批项数（start 那拍闩存）
  val sgIss    = Reg(UInt(16 bits)) init (0)
  val sgRcv    = Reg(UInt(16 bits)) init (0)
  val sgDr     = Reg(UInt(16 bits)) init (0)
  val sgBeat   = Reg(UInt(4 bits)) init (0)
  val sgDrBeat = Reg(UInt(4 bits)) init (0)

  /** 入队：只允许 IDLE 且未满；非法项（地址非 32B 对齐 / 拍数不是 4 的倍数）⇒ ready=0 + err。
    * ★ 本块必须在 FSM **之后**（`err_r` 的默认赋值在 FSM 前；先写会被判 "ASSIGNMENT OVERLAP"）。 */
  val sgRoom   = (state === DdrState.IDLE) && (sgCnt < U(SGD, 4 bits))
  val sgItemOk = ((io.sg_addr % 32) === 0) && (io.sg_beatsM1(1 downto 0) === U(3, 2 bits))
  io.sg_ready := sgRoom && sgItemOk

  /** 本块拍数-1 的组合计算（= 尾块缩短突发）。
    *
    *   remain >= 128  -> 15      （满块 16 拍 = 128 B）
    *   remain <  128  -> remain/8 - 1
    *
    * ★ COPY 路径为什么**逐拍不变**：COPY 且 len 是 128 的整数倍时 remain 永远是 128 的整数倍
    *   （初值 len、每块 -128），所以只要 remain != 0 就有 remain >= 128 ⇒ 这条恒取 15；
    *   加上 curBytes 恒 128、地址恒 +128、AW/W 次序不变 ⇒ 状态序列与 C2 逐拍同形。
    *
    * 判据用位切片 `rem(31 downto 7) =/= 0`（等价于 `rem >= 128`，因为 rem 是 8 的倍数）：
    * 位切片比较与 UInt 宽度无关，SpinalHDL 不会插出意外的 resize。
    * 取值只有 15 与 (0..11) 两种，都装进 4 bit ⇒ **"arlen/awlen <= 15"是结构性的**，
    * 不依赖"调用点算术恰好正确"；就算 rem 被喂了非法值（例如 0 ⇒ 无符号下溢），
    * 结果也只是被截成一个 <= 15 的数，永远不可能让 AxiMemModel 见到 >16 拍的突发。
    */
  def beatsM1For(rem: UInt): UInt = {
    val full = rem(31 downto 7) =/= 0
    Mux(full, U(15, 4 bits), (rem(6 downto 3) - U(1, 4 bits)).resize(4 bits))
  }

  /** 本块的字节数 = `(beatsM1+1)*8`，范围 8..128。
    * 构造方式刻意避开"依赖 `+` 长位宽"的写法：`beatsM1 @@ U(0,3 bits)` 是 7 bit 的 `beatsM1*8`
    * （`@@` = 硬连线左移 3 位，**不生成乘法器** —— B2 有"无死乘法器"判据），再加一拍 `U(8)`。
    * 两个操作数分别 7 / 8 bit，和 <= 128 在 8 bit 里放得下 ⇒ 无论 SpinalHDL 的 `+` 是否长位宽，
    * `resize(8 bits)` 的结果都精确；这一点由 C2 三闸门的 `cyc`/字节数逐字回归兜底。 */
  val curBytes         = ((beatsM1 @@ U(0, 3 bits)) + U(BYTES_PER_BEAT, 8 bits)).resize(8 bits)
  val curBytes32       = curBytes.resize(32 bits)                    // 与 remain 比大小用
  val curBytesAddr     = curBytes.resize(cfg.ADDR_W bits)            // 地址递进用

  // ---- L2b：块槽预取的组合量（只在 QRUN 态使用）----
  val qArM1     = beatsM1For(qRemain)
  val qArBytes  = ((qArM1 @@ U(0, 3 bits)) + U(BYTES_PER_BEAT, 8 bits)).resize(8 bits)
  val qIssueSlot = qIssCnt(RQW - 1 downto 0)
  val qRcvSlot   = qRcvCnt(RQW - 1 downto 0)
  val qDrSlot    = qDrCnt(RQW - 1 downto 0)
  /** 还能发一块：还有字节、且「已发−已排」< RQ（槽未全占）。 */
  val qCanIssue  = (state === DdrState.QRUN) && (qRemain =/= 0) && ((qIssCnt - qDrCnt) < U(RQ, 16 bits))
  /** 有一块已发、数据还没收完 ⇒ R 可以吃。 */
  val qHasRcv    = (qRcvCnt =/= qIssCnt)
  /** 有一块已收完、还没排空 ⇒ 可以推给 rd_stream。 */
  val qDrainValid = (state === DdrState.QRUN) && (qRcvCnt =/= qDrCnt)
  /** 当前排空槽的第 qDrBeat 拍（小端 8 字节）。 */
  val qDrWord = Cat((0 until BYTES_PER_BEAT).map(j => qbuf(qDrSlot)(qDrBeat @@ U(j, 3 bits))))

  // ---- B3b：SG-RD 的同构组合量（状态互斥，qbuf/qLen 复用）----
  val sgHasRcv    = (sgRcv =/= sgIss)
  val sgDrainValid = (state === DdrState.SGRUN) && (sgDr =/= sgRcv)
  val sgDrSlot    = (sgDr(RQW - 1 downto 0))
  val sgDrWord    = Cat((0 until BYTES_PER_BEAT).map(j => qbuf(sgDrSlot)(sgDrBeat @@ U(j, 3 bits))))
  val sgIssueAdr  = sgQAddr(sgIss(SGW - 1 downto 0))
  val sgIssueLen  = sgQLen(sgIss(SGW - 1 downto 0))

  // 默认值（写在 switch 之前 ⇒ 被 switch 内的赋值覆盖；这就是"一拍脉冲"的实现口径）
  err_r  := False
  done_r := False

  // ---------------------------------------------------------------------------
  // AR 通道：默认不举 valid；size/burst/id/cache/prot 是**常值**（业务上永不改变），写在状态机
  // 外面无条件驱动 ⇒ Verilog 里就是常数，静态判据可查。
  // **长度**（C3.3）：不再是常量 15，而是每块量 `beatsM1`（4 bit 寄存器）—— COPY 且 len 是
  // 128 倍数时恒 15（= 旧行为），尾块则 3/7/11（32/64/96 B）。它不是"每态量"，所以仍然写在
  // 状态机外面无条件驱动；"<= 15"由 4 bit 域结构性保证（见 beatsM1For 的注释）。
  // 地址由 rbase 派生且低 5 位由构造恒 0（P3）。
  // ---------------------------------------------------------------------------
  val arAddr = (rbase(cfg.ADDR_W - 1 downto 5) @@ U(0, 5 bits)).resize(cfg.ADDR_W)

  io.axi.ar.valid         := False
  // L2b：QRUN 用 qAddr/qArM1（块槽预取）；B3b：SGRUN 用队列项地址/拍数；其余状态仍用 rbase/beatsM1。
  io.axi.ar.payload.addr  := Mux(state === DdrState.QRUN, qAddr,
                                 Mux(state === DdrState.SGRUN, sgIssueAdr, arAddr))
  io.axi.ar.payload.len   := Mux(state === DdrState.QRUN, qArM1.resize(8 bits),
                                 Mux(state === DdrState.SGRUN, sgIssueLen.resize(8 bits),
                                     beatsM1.resize(8 bits)))
  io.axi.ar.payload.size  := U(ARSIZE, 3 bits)
  io.axi.ar.payload.burst := B(1, 2 bits)      // INCR
  io.axi.ar.payload.id    := U(0)
  io.axi.ar.payload.cache := B(0, 4 bits)
  io.axi.ar.payload.prot  := B(0, 3 bits)

  // R 通道：R 态（COPY）或 QRUN/SGRUN 有在飞块（RD 预取/散读）时收数据。
  io.axi.r.ready := (state === DdrState.R) || ((state === DdrState.QRUN) && qHasRcv) ||
                    ((state === DdrState.SGRUN) && sgHasRcv)

  // ---------------------------------------------------------------------------
  // AW 通道：默认不举 valid；size/burst/id/cache/prot 是**常值**；长度 = 每块量 `beatsM1`
  // （与读侧同源、同一个寄存器 ⇒ 同一块的 AR/AW 长度恒等），低 5 位由构造恒 0（P3 的写侧纪律，
  // 与读侧 arAddr 同形）。
  // ---------------------------------------------------------------------------
  val awAddr = (wbase(cfg.ADDR_W - 1 downto 5) @@ U(0, 5 bits)).resize(cfg.ADDR_W)

  io.axi.aw.valid         := False
  io.axi.aw.payload.addr  := awAddr
  io.axi.aw.payload.len   := beatsM1.resize(8 bits)   // C3.3：不再是常量 15（尾块缩短突发）；COPY 时恒 8'h0f
  io.axi.aw.payload.size  := U(ARSIZE, 3 bits)
  io.axi.aw.payload.burst := B(1, 2 bits)      // INCR
  io.axi.aw.payload.id    := U(0)
  io.axi.aw.payload.cache := B(0, 4 bits)
  io.axi.aw.payload.prot  := B(0, 3 bits)

  // ---------------------------------------------------------------------------
  // W 通道：默认不举 valid；data 是块缓冲第 wbi 拍的 8 字节（**小端**：data[8j+7:8j] =
  // buf[wbi*8+j]），strb 全字节有效（8'hFF），last 在块内末拍（wbi==15）抬起。
  // 从缓冲取第 wbi 拍是**动态读**（128:1 mux，组合即可；写侧才是静态下标解码）。
  // `wbi @@ j(3bit)` 恰好是 7 位地址、值 = wbi*8 + j（拼接=左移 3 位再或 j，j<8 无进位）。
  // ⚠️ SpinalHDL 的 `Cat` 把**第一个元素当最低位**（LSB）⇒ 要让 data[7:0] = buf[wbi*8+0]，
  //    元素必须按 j = 0,1,...,7 排列（实测踩过：写成 (7 downto 0) 会让每拍 8 字节整体反序）。
  // ---------------------------------------------------------------------------
  val wData = Cat((0 until BYTES_PER_BEAT).map(j => buf(wbi @@ U(j, 3 bits))))

  io.axi.w.valid         := False
  io.axi.w.payload.data  := wData
  // ★★ T-S2b：`strb` 由**块内第 `wbi` 拍**的掩码寄存器给（`sbuf` 初值 8'hFF ⇒ COPY/RD 逐拍同形）。
  io.axi.w.payload.strb  := sbuf(wbi)
  io.axi.w.payload.last  := (wbi === beatsM1)   // C3.3：末拍 = 本块最后一拍（COPY 时恒 wbi==15）
  // 注：本配置下 Axi4W 没有 id 域（SpinalHDL 1.15.0 里 Axi4W.id 为 null）⇒ 不能赋值。

  // ---------------------------------------------------------------------------
  // C3.3 流式端口（RD 推出 / WR 填入）。
  //   · `rdData` 与 `wData` **同形**（都是"块缓冲第 i 拍的 8 字节"，小端），但**独立一份**：
  //     用独立的 `rdi` 索引 + 独立的 128:1 mux，为的是让 RD 模式**结构上不碰**写侧的 wbi
  //     （模式互斥本来就不冲突，但独立一份省得以后有人写"RD 模式不得改 wbi"这类判据时打架）。
  //     代价是第二把 128:1 8bit mux；C3.13 的面积闸门若要省这一把，有两条更省的路子可挑：
  //       (a) 直接复用 `wData`、索引改用 `wbi`（RDSTR 进态时 `wbi:=0` 与 rdi 同步）；
  //       (b) 只留**一把** mux、索引改成**状态选择**的组合量 `Mux(state===RDSTR, rdi, wbi)` ——
  //           合法是因为 `W`（用 wbi 推 AXI 写数据）与 `RDSTR`（用 rdi 推 rd_stream）**状态互斥**，
  //           同一拍只有一路在用，因而两路共用一个索引/一把 mux 不会串扰。
  //       何时该省：交给 C3.13 的面积闸门按 dev_map 实测决定（省一把 128:1 8bit mux ≈ 128×8 LUT）。
  //   · 与 wData 一样用 `Cat` 纯表达式构造（多语句赋值会生成敏感表为空的 always @(*) ⇒ X）。
  //   · rd_valid 只在 RDSTR 态举、wr_ready 只在 WSTR 态举 ⇒ 模式之外对流**完全安静**。
  // ---------------------------------------------------------------------------
  val rdData = Cat((0 until BYTES_PER_BEAT).map(j => buf(rdi @@ U(j, 3 bits))))

  io.rd_valid := False
  io.rd_data  := Mux(state === DdrState.QRUN, qDrWord,
                     Mux(state === DdrState.SGRUN, sgDrWord, rdData))
  io.wr_ready := False

  // B 通道：只在本笔写突发的**等响应**状态举 ready（单 outstanding ⇒ 别无他处会来 B）。
  io.axi.b.ready := (state === DdrState.WB)

  switch(state) {
    // ---------------- IDLE：等 start ----------------
    is(DdrState.IDLE) {
      when(io.start) {
        state := DdrState.CHK
        cyc_r := 0
      }
    }

    // ---------------- CHK：校验入参（非法 ⇒ err 一拍，回 IDLE，不搬）----------------
    is(DdrState.CHK) {
      cyc_r := cyc_r + 1
      // 合法条件（见文件头"入参校验"）：src/dst 低 5 位为 0（32B 对齐）；
      // len 是 **32** 的整数倍且 > 0（C3.3 放宽：32 B 粒度 + 尾块缩短突发）。
      val srcOk = (io.src % 32) === 0
      val dstOk = (io.dst % 32) === 0
      val lenOk = ((io.len % 32) === 0) && (io.len =/= 0)
      when(io.mode === U(3, 2 bits)) {
        // ★★ B3b：SG-RD —— src/dst/len 不参与（搬运形状由队列项决定）；队列空 ⇒ err 一拍。
        when(sgCnt === 0) {
          err_r := True
          state := DdrState.IDLE
        } otherwise {
          sgN := sgCnt
          sgIss := 0; sgRcv := 0; sgDr := 0
          sgBeat := 0; sgDrBeat := 0
          rd_r := 0
          state := DdrState.SGRUN
        }
      } elsewhen(srcOk && dstOk && lenOk) {
        rbase   := io.src
        wbase   := io.dst
        remain  := io.len
        beatsM1 := beatsM1For(io.len)     // len 已过 32 倍数校验 ⇒ 尾块正好咬在 len 边界上
        bi      := 0
        rd_r    := 0
        wbi     := 0
        wr_r    := 0
        rdi     := 0
        // 模式分派：mode==1 走**块槽预取**（L2b）；mode==2 才走"先灌缓冲"；COPY(0) 走旧单块读。
        // （Verilog 边界上悬空端口 z ⇒ X 也在这里取 otherwise ⇒ COPY；Scala 调用方必须显式驱动。）
        when(io.mode === U(1, 2 bits)) {
          qRemain := io.len
          qAddr   := io.src
          qIssCnt := 0
          qRcvCnt := 0
          qDrCnt  := 0
          qBeat   := 0
          qDrBeat := 0
          rd_r    := 0
          state   := DdrState.QRUN
        } elsewhen(io.mode === U(2, 2 bits)) {
          state := DdrState.WSTR
        } otherwise {
          state := DdrState.AR          // 拷贝总是先读：把第 0 块读进块缓冲
        }
      } otherwise {
        err_r := True      // 一拍脉冲：下一拍就回 IDLE，默认赋值把它拉回 0
        state := DdrState.IDLE
      }
    }

    // ---------------- AR：举一笔突发（arlen=beatsM1，beats 拍 x 8B）----------------
    is(DdrState.AR) {
      cyc_r := cyc_r + 1
      io.axi.ar.valid := True
      when(io.axi.ar.ready) {
        state := DdrState.R
        bi    := 0
      }
    }

    // ---------------- R：收 beats 拍，逐拍落块缓冲 ----------------
    is(DdrState.R) {
      cyc_r := cyc_r + 1
      when(io.axi.r.valid) {
        // 静态下标解码：只在"本拍就是第 i 拍"这一支里写 buf(i*8+j)。
        for (i <- 0 until BEATS_PER_CHUNK) {
          when(bi === U(i, 4 bits)) {
            for (j <- 0 until BYTES_PER_BEAT) {
              // 小端字节序：data[8j+7:8j] = 地址 rbase + i*8 + j 上的字节。
              // 注：Axi4R.data 是 **Bits**（不是 UInt，见 Axi4R 的字段类型）⇒ 取完切片要 asUInt。
              buf(i * BYTES_PER_BEAT + j) := io.axi.r.payload.data((j * 8 + 7) downto (j * 8)).asUInt
            }
          }
        }
        rd_r := rd_r + BYTES_PER_BEAT
        when(bi === beatsM1) {
          state := DdrState.NEXT          // 本块最后一拍 -> 结算本块
        } otherwise {
          bi := bi + 1
        }
      }
    }

    // ---------------- NEXT：本块读完了 ⇒ 按模式接力（COPY: 写相位 / RD: 推流）----------------
    is(DdrState.NEXT) {
      cyc_r := cyc_r + 1
      when(io.mode === U(1, 2 bits)) {
        state := DdrState.RDSTR         // RD：不做 WR，把本块推给 rd_stream
        rdi   := 0
      } otherwise {
        state := DdrState.WR            // COPY：读的 R 已收完、AR 不再举 -> 把这一块写出去
      }
    }

    // ---------------- WSTR（仅 WR 模式）：从 wr_stream 收 beats 拍填块缓冲 ----------------
    // `wr_ready` 只在本态举；填满本块（wbi == beatsM1）后进 WR（AW -> W -> B）。
    // 块缓冲的写入与 R 态一样是**静态下标解码**（按 wbi 静态展开 16 个 when）。
    is(DdrState.WSTR) {
      cyc_r := cyc_r + 1
      io.wr_ready := True
      when(io.wr_valid) {
        for (i <- 0 until BEATS_PER_CHUNK) {
          when(wbi === U(i, 4 bits)) {
            for (j <- 0 until BYTES_PER_BEAT) {
              // 小端：wr_data[8j+7:8j] -> 本块第 i 拍的第 j 个字节。wr_data 是 **Bits** ⇒ asUInt。
              buf(i * BYTES_PER_BEAT + j) := io.wr_data((j * 8 + 7) downto (j * 8)).asUInt
            }
            // ★★ T-S2b：同一拍把该拍的**写字节掩码**存进 `sbuf`（与 `buf` 同生命周期、同静态下标）。
            sbuf(i) := io.wstrb
          }
        }
        when(wbi === beatsM1) {
          state := DdrState.WR            // 本块灌满 -> 去发 AW
        } otherwise {
          wbi := wbi + 1
        }
      }
    }

    // ---------------- RDSTR（仅 RD 模式）：把块缓冲按拍推给 rd_stream ----------------
    // 推 `beats` 拍（rdi 0..beats-1）；`rd_valid` 只在本态举，等对流 `rd_ready`。
    // 推完 -> WNEXT（RD 模式下 WNEXT 只做"还有没有下一块"的判决 + 指针递进，不写内存）。
    is(DdrState.RDSTR) {
      cyc_r := cyc_r + 1
      io.rd_valid := True
      when(io.rd_ready) {
        when(rdi === beatsM1) {
          state := DdrState.WNEXT
        } otherwise {
          rdi := rdi + 1
        }
      }
    }

    // ---------------- WR：举一笔写地址（awlen=beatsM1），等 awready ----------------
    // 严格 (a)：先 AW，等成交，**之后**才进 W 态举 W（W 的呈现结构上晚于 AW 成交）。
    // 这条纪律对 COPY 与 WR 两种模式一视同仁（WR 模式的填充发生在 WSTR，仍在 AW 之前）。
    is(DdrState.WR) {
      cyc_r := cyc_r + 1
      io.axi.aw.valid := True
      when(io.axi.aw.ready) {
        state := DdrState.W
        wbi   := 0
      }
    }

    // ---------------- W：逐拍举 W（data 从块缓冲第 wbi 拍出），走完 beats 拍 -> WB ----------------
    is(DdrState.W) {
      cyc_r := cyc_r + 1
      io.axi.w.valid := True
      when(io.axi.w.ready) {
        wr_r := wr_r + BYTES_PER_BEAT
        when(wbi === beatsM1) {
          state := DdrState.WB          // 末拍已发出 -> 等 B 响应
        } otherwise {
          wbi := wbi + 1
        }
      }
    }

    // ---------------- WB：等 B（`b.ready` 只在 WB 态举）；收到响应才算这一笔落地 ----------------
    is(DdrState.WB) {
      cyc_r := cyc_r + 1
      when(io.axi.b.valid) {
        state := DdrState.WNEXT
      }
    }

    // ---------------- WNEXT：还有块就进下一块（按模式回 AR / WSTR），没了就去 DONE ----------------
    // 判据 `remain <= beats*8`：COPY（beats 恒 16 ⇒ 128）与 C2 的 `remain <= 128` 逐字等价。
    is(DdrState.WNEXT) {
      cyc_r := cyc_r + 1
      when(remain <= curBytes32) {
        state := DdrState.DONE        // 本块是最后一块（它的读+写都已完成）
      } otherwise {
        remain  := remain - curBytes32
        rbase   := rbase + curBytesAddr
        wbase   := wbase + curBytesAddr
        beatsM1 := beatsM1For(remain - curBytes32)   // 下一块的拍数（尾块就在这一步缩短）
        wbi     := 0
        when(io.mode === U(2, 2 bits)) {
          state := DdrState.WSTR      // WR：直接从流灌下一块
        } otherwise {
          state := DdrState.AR        // COPY / RD：读下一块
        }
      }
    }

    // ---------------- QRUN（mode=1，L2b 块槽预取）：AR 提前发、R 按序落槽、从槽 0 排空 ----------------
    //   三个动作同拍可并行（不同 AXI 通道 + 不同槽）：
    //     · AR：还有字节 且 已发−已排 < RQ ⇒ 发下一块；handshake 时写 qLen[issueSlot]/扣 qRemain/推进 qAddr；
    //     · R ：有在飞块（rcv≠iss）⇒ 收一拍进 qbuf[rcvSlot]，块末抬 qRcvCnt；
    //     · DR：有已收未排块（rcv≠dr）⇒ rd_valid 推一拍，块末抬 qDrCnt。
    //   顺序纪律保证三个槽号互不冲突：dr ≤ rcv ≤ iss 且 iss−dr ≤ RQ；RQ=1 时退化为逐块串行。
    is(DdrState.QRUN) {
      cyc_r := cyc_r + 1
      io.axi.ar.valid := qCanIssue
      when(qCanIssue && io.axi.ar.ready) {
        qLen(qIssueSlot) := qArM1
        qRemain := qRemain - qArBytes.resize(32 bits)
        qAddr   := (qAddr + qArBytes.resize(cfg.ADDR_W bits)).resize(cfg.ADDR_W bits)
        qIssCnt := qIssCnt + 1
      }
      when(qHasRcv && io.axi.r.valid) {
        for (j <- 0 until BYTES_PER_BEAT) {
          qbuf(qRcvSlot)(qBeat @@ U(j, 3 bits)) :=
            io.axi.r.payload.data((j * 8 + 7) downto (j * 8)).asUInt
        }
        when(qBeat === qLen(qRcvSlot)) {
          qRcvCnt := qRcvCnt + 1
          qBeat   := 0
        } otherwise {
          qBeat := qBeat + 1
        }
      }
      io.rd_valid := qDrainValid
      when(qDrainValid && io.rd_ready) {
        rd_r := rd_r + BYTES_PER_BEAT
        when(qDrBeat === qLen(qDrSlot)) {
          qDrCnt  := qDrCnt + 1
          qDrBeat := 0
        } otherwise {
          qDrBeat := qDrBeat + 1
        }
      }
      when(qRemain === 0 && qIssCnt === qDrCnt) {
        state := DdrState.DONE
      }
    }

    // ---------------- SGRUN（mode=3，B3b 多事务散读）----------------
    //   与 QRUN 同构：AR 按**队序**背靠背发（每项一个独立事务，地址来自 sgQ），R 按序落 qbuf 槽，
    //   从槽 0 按序排空；整批（sgN 项）发完且排完才进 DONE ⇒ 一个 done 脉冲。
    is(DdrState.SGRUN) {
      cyc_r := cyc_r + 1
      val sgCanIssue = (sgIss < sgN) && ((sgIss - sgDr) < U(RQ, 16 bits))
      io.axi.ar.valid := sgCanIssue
      when(sgCanIssue && io.axi.ar.ready) {
        qLen(sgIss(RQW - 1 downto 0)) := sgIssueLen
        sgIss := sgIss + 1
      }
      when(sgHasRcv && io.axi.r.valid) {
        for (j <- 0 until BYTES_PER_BEAT) {
          qbuf(sgRcv(RQW - 1 downto 0))(sgBeat @@ U(j, 3 bits)) :=
            io.axi.r.payload.data((j * 8 + 7) downto (j * 8)).asUInt
        }
        when(sgBeat === qLen(sgRcv(RQW - 1 downto 0))) {
          sgRcv := sgRcv + 1
          sgBeat := 0
        } otherwise {
          sgBeat := sgBeat + 1
        }
      }
      io.rd_valid := sgDrainValid
      when(sgDrainValid && io.rd_ready) {
        rd_r := rd_r + BYTES_PER_BEAT
        when(sgDrBeat === qLen(sgDrSlot)) {
          sgDr := sgDr + 1
          sgDrBeat := 0
        } otherwise {
          sgDrBeat := sgDrBeat + 1
        }
      }
      when((sgIss === sgN) && (sgDr === sgN)) {
        state := DdrState.DONE
      }
    }

    // ---------------- DONE：done 一拍脉冲，回 IDLE ----------------
    is(DdrState.DONE) {
      done_r := True
      sgCnt  := 0          // B3b：一批散读做完即清队（下一批重新入队）
      state  := DdrState.IDLE
    }
  }

  // ---- B3b：SG 队写入（FSM 之后 ⇒ `err_r` 的后写覆盖合法；与 DONE 的清队互斥）----
  when(io.sg_valid && sgRoom) {
    when(sgItemOk) {
      sgQAddr(sgCnt(SGW - 1 downto 0)) := io.sg_addr
      sgQLen(sgCnt(SGW - 1 downto 0))  := io.sg_beatsM1
      sgCnt := sgCnt + 1
    } otherwise {
      err_r := True
    }
  }
  // ★ B3b-2：清队放在入队**之后** ⇒ 同拍两者都来时 flush 优先（不会残留半批）
  when(io.sg_flush && (state === DdrState.IDLE)) { sgCnt := 0 }

  io.busy     := (state =/= DdrState.IDLE)
  io.done     := done_r
  io.err      := err_r
  io.cyc      := cyc_r
  io.rd_bytes := rd_r
  io.wr_bytes := wr_r                  // 总线上真正写出去的字节数（拷贝成功时恒 == len）

  for (i <- 0 until cfg.CHUNK_BYTES) {
    io.buf_dout(i) := buf(i)
  }
}
