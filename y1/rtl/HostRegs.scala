import spinal.core._
import spinal.lib._
import spinal.lib.bus.amba4.axilite._

/** 主机寄存器层 —— AxiLite4 从口 + 一张**冻结的寄存器表**（本任务只做寄存器，不含调度器/FSM/FIFO）。
  *
  * 为什么单独成块：调度器（后续任务）要"能把一层卷积编程进去"，就得先有一块**可被穷举验证**的
  * 寄存器表。本块把"表"做成单一真源：地址、位段、访问语义全部只在这里出现一次，TB + 闸门
  * （rtl_test/HostRegsTb.v + tools/run_hostregs_ab.sh）对**每一个**寄存器做写-回读对账，
  * 外加只读语义与"负对照恰好 1"两道判据。判据是穷举的，所以本块必须**没有**时序行为可言。
  *
  * 寄存器表（冻结；偏移 / 名字 / 访问 / 语义）：
  *   0x00 CTRL        WO(混合)  bit0 start(自清) / bit1 soft_reset(自清) / bit8 busy(RO) / bit9 done(RO)
  *   0x04 STATUS      RO        bit0 done_sticky(写 1 清) / bit1 err / [31:8] 已完成单元数（只读遥测）
  *   0x08 IMG_W       RW        输入图宽
  *   0x0C IMG_H       RW        输入图高
  *   0x10 C_IN        RW        输入通道
  *   0x14 C_OUT       RW        输出通道
  *   0x18 GROUP       RW        卷积分组数
  *   0x1C KERNEL      RW        bit0 stride(0=1,1=2) / bit1 pad
  *   0x20 SRC_ADDR    RW        输入特征 DDR 地址(32bit)
  *   0x24 DST_ADDR    RW        输出特征 DDR 地址(32bit)
  *   0x28 QUANT_SHIFT RW        输出重量化算术右移
  *   0x2C LAYER_ID    RW        当前层号(遥测/调试)
  *   0x30 ID          RO        常数 0x594E5031 ("YNP1") —— 从口活着的证明
  *   0x34 DESC_ADDR   RW        描述符表 DDR 基址（C3.12：交给 LayerSched，必须 32 B 对齐）
  *   0x38 DESC_COUNT  RW        描述符表载荷项数（**不含**表尾哨兵；C3.12/CTRL.start 契约见 NpuTop）
  *   0x3C WGT_SEL     RW        权重信箱：目标切片下标（0..L_MAX-1；本代 L_MAX=8 ⇒ 0..7）
  *   0x40 WGT_ADDR    RW        权重信箱：该切片 WeightStore 内的条目下标（0..NENTRY-1；dense 时 576）
  *   0x44 WGT_DATA    RW        权重信箱：载荷 —— **低 8 位 = int8 权重值**（上 24 位照存但不参与）
  *   0x48 WGT_WE      WO        权重信箱：写使能，**自清单拍**（写 1 起效、下一拍自动落 0）
  *
  * ★ C3.16「权重信箱」（register mailbox）—— 这一档补的是**权重装载通路**：
  *   在 C3.12 之前，NPU 的对外端口集里**没有**权重口（权重带外预载被记为 C4/M2 项）⇒ `NpuTop` 只能把
  *   `LayerSched` 的权重口钉 0 ⇒ conv 输出恒为零张量、板级 `dev_map` 把整条卷积数据通路**常量折叠**掉。
  *   现在主机经 AxiLite4 **在同一条寄存器窗里**逐字节把权重写进片上 `WeightStore`：先写 `WGT_SEL`/`WGT_ADDR`，
  *   再写 `WGT_DATA`，最后写 `WGT_WE=1` 落一拍 —— **一次一个 int8**。
  *   四条的口径与既有档位**逐字同源**：三个 RW 档是**整 32 位存储**（同 `IMG_W..LAYER_ID` 那 10 档），
  *   `WGT_WE` 是**自清单拍**（同 `CTRL.start` / `status_clr_r`）；窄语义由**导出的字段切片**表达
  *   （`wgt_data` = 低 8 位并重解释成 `SInt(8)`，`wgt_sel/wgt_addr` 的位宽裁剪由消费方 `NpuTop` 做）。
  *   ★ 为什么不做成"一个 32 位宽字一次 4 字节"：`WeightStore` 的装载口是 `SInt(8 bits)`（冻结口径），
  *   本档只做**最薄**的一层"主机可写"包装，不在寄存器层再造一套打包格式（那会与 `WeightStore` 的
  *   冻结接口形成第二个真源）。
  *
  * ★ 位宽口径（本文件的中心约定，TB/闸门按同一条对账）：
  *   **RW 档一律是整 32 位存储**（IMG_W..LAYER_ID）。这样"写一个地址派生模式、回读必须逐字相等"
  *   这条穷举判据才有唯一解，不需要闸门去猜"这个字段实际只用了几位"。窄语义**由导出的
  *   字段切片表达**：KERNEL 只用 bit0/bit1（kernel_stride/kernel_pad），其余位保留存储。
  *   CTRL/STATUS 不是纯 RW：CTRL 的 bit0/1 自清、bit8/9 只读；STATUS 只读（bit0 写 1 清）。
  *   所以这两个地址的回读期望是**确定值**（见闸门），不是写入的模式。
  *
  * ★ busy/done/err 是**输入端口**（后续由调度器驱动；本任务 TB 里一律接 0）：
  *   busy -> CTRL.bit8（RO）、done -> CTRL.bit9（RO）、err -> STATUS.bit1（RO）。
  *   端口先立起来 ⇒ 后面接调度器时不用重拉线。done_sticky 是 STATUS.bit0 的**粘滞寄存器**：
  *   done 上升沿置 1，主机写 1 到 STATUS.bit0 清 0（这就是"write-1-to-clear"的字面实现）。
  *
  * ★ 未映射访问（表外地址）：读**返回 0**、写**被忽略**（AxiLite4SlaveFactory 的读多路默认值即 0；
  *   写没有对应 handler 就什么都不做）。本块**不做**任何额外地址译码 —— 表的边界就是译码的边界。
  *
  * ★ 导出：每个字段都是一个**类型化输出端口**，后续调度器直接连，不用再从从口里扒位。
  */
case class HostRegs() extends Component {
  val io = new Bundle {
    // 主机侧：AxiLite4 从口（与仓内其它从口同款，接线方式已被证明）。
    val axilite = slave(AxiLite4(32, 32))

    // 调度器侧状态输入（本任务 TB 接 0；端口先行，避免后续重拉线）。
    val sched_busy = in Bool()
    val sched_done = in Bool()
    val sched_err  = in Bool()
    /** ★ 逐单元遥测（只读）：调度器**已消费的载荷条目数**（真表全 plain ⇒ 每单元 +1）。
      *   只进 STATUS[31:8]，不参与任何控制；主机轮询它即可给每个单元打时间戳。 */
    val sched_unitIndex = in UInt(24 bits)

    // 导出的寄存器字段（调度器直接接线）。
    val start         = out Bool()
    val soft_reset    = out Bool()
    val busy          = out Bool()
    val done          = out Bool()
    val done_sticky   = out Bool()
    val err           = out Bool()
    val img_w         = out UInt(32 bits)
    val img_h         = out UInt(32 bits)
    val c_in          = out UInt(32 bits)
    val c_out         = out UInt(32 bits)
    val group         = out UInt(32 bits)
    val kernel_stride = out Bool()
    val kernel_pad    = out Bool()
    val src_addr      = out UInt(32 bits)
    val dst_addr      = out UInt(32 bits)
    val quant_shift   = out UInt(32 bits)
    val layer_id      = out UInt(32 bits)
    // ★ C3.12：层调度器（LayerSched）的描述符表基址 / 载荷项数（**整 32 位存储**，与既有 RW 档同姿）。
    val desc_addr     = out UInt(32 bits)
    val desc_count    = out UInt(32 bits)
    // ★ C3.16：权重信箱（register mailbox）—— 目的一：把"权重装载"变成主机可写的一条**真通路**。
    //   `wgt_sel`/`wgt_addr` 是**整 32 位存储**（与上面所有 RW 档同姿；位宽裁剪在 NpuTop 里显式做，
    //   与 `ddrMaster.io.src := src_addr.resize(28)` 同一手法）；`wgt_data` 是**低 8 位的 int8 载荷**；
    //   `wgt_we` 是**自清单拍**（与 CTRL.start 同姿），消费方（UnitExec）拿它当 WeightStore 的写使能。
    val wgt_sel       = out UInt(32 bits)
    val wgt_addr      = out UInt(32 bits)
    val wgt_data      = out SInt(8 bits)
    val wgt_we        = out Bool()
  }
  noIoPrefix()

  val bus = AxiLite4SlaveFactory(io.axilite)

  // ---------------------------------------------------------------------------
  // 0x00 CTRL —— 混合：bit0 start(自清) / bit1 soft_reset(自清) / bit8 busy(RO) / bit9 done(RO)
  // ---------------------------------------------------------------------------
  // 写侧：两个**各自独立**的 1 位寄存器（不做整字切片，免得同一个信号被两处赋值）。
  val start_r      = Reg(Bool()) init False
  val soft_reset_r = Reg(Bool()) init False
  bus.write(start_r, 0x00, 0)
  bus.write(soft_reset_r, 0x00, 1)
  // 自清：写进去当拍起效，随后**自动**清 0（主机下次写 1 又是新脉冲）。声明在 bus.write 之后
  // ⇒ 优先级更高，本拍起效、下一拍落回 0，正好 1 拍脉冲。
  when(start_r)      { start_r := False }
  when(soft_reset_r) { soft_reset_r := False }

  // 读侧：bit8/9 只读，来自调度器的 busy/done；bit0/1 读回 0（自清）。
  //
  // ★ 这里**必须**用一个"纯表达式"（Cat）而不是多语句赋值（`ctrl_rd := 0; ctrl_rd(8) := ...`）。
  //   原因（实测）：多语句赋值会让 SpinalHDL 落成一个 `always @(*)` 块，其敏感表里只有
  //   sched_busy / sched_done 这两个**永不翻转**的输入；Verilog 语义下这种块只在敏感信号
  //   变化时执行 —— 于是 iverilog 里 ctrl_rd 从头到尾停在 X，回读 CTRL 得到 xxxxxxxx。
  //   写成连续表达式 ⇒ 落成 `assign ctrl_rd = {...}`，time-0 就有定值，闸门才读得对。
  //   （真实硬件里两者等价；这里是为了让**仿真装置**与硬件同口径。）
  val ctrl_rd = Cat(B(0, 22 bits), io.sched_done.asBits, io.sched_busy.asBits, B(0, 8 bits))
  bus.read(ctrl_rd, 0x00)

  // ---------------------------------------------------------------------------
  // 0x04 STATUS —— 只读：bit0 done_sticky(写 1 清) / bit1 err / [31:8] 已完成单元数
  // ---------------------------------------------------------------------------
  // done_sticky：done 上升沿置位、粘住；主机写 1 到 STATUS.bit0 清除。
  val done_sticky_r = Reg(Bool()) init False
  val status_clr_r  = Reg(Bool()) init False   // 写 1 的落点（随后自清）
  bus.write(status_clr_r, 0x04, 0)
  when(status_clr_r) { status_clr_r := False }
  when(io.sched_done) { done_sticky_r := True }
  // 清除优先级**高于**置位（声明在后）⇒ done 与写 1 同拍时以"清"为准（标准 w1c 口径）。
  when(status_clr_r) { done_sticky_r := False }

  // 同 CTRL：读侧用连续表达式（Cat），免得落成敏感表只有常量的 always @(*) 块而停在 X。
  val status_rd = Cat(io.sched_unitIndex, B(0, 6 bits), io.sched_err.asBits, done_sticky_r.asBits)
  bus.read(status_rd, 0x04)

  // ---------------------------------------------------------------------------
  // 0x08..0x2C —— 整 32 位 RW 档
  // ---------------------------------------------------------------------------
  val img_w       = Reg(UInt(32 bits)) init 0
  val img_h       = Reg(UInt(32 bits)) init 0
  val c_in        = Reg(UInt(32 bits)) init 0
  val c_out       = Reg(UInt(32 bits)) init 0
  val group       = Reg(UInt(32 bits)) init 0
  val kernel      = Reg(UInt(32 bits)) init 0
  val src_addr    = Reg(UInt(32 bits)) init 0
  val dst_addr    = Reg(UInt(32 bits)) init 0
  val quant_shift = Reg(UInt(32 bits)) init 0
  val layer_id    = Reg(UInt(32 bits)) init 0
  // ★ C3.12：两个新 RW 档（与上面 10 档**同一种写法**：整 32 位存储 + readAndWrite）。
  //   地址接在 ID(0x30) 之后：DESC_ADDR=0x34 / DESC_COUNT=0x38 ⇒ 既有 13 格的地址/语义一个都不动。
  val desc_addr   = Reg(UInt(32 bits)) init 0
  val desc_count  = Reg(UInt(32 bits)) init 0
  // ★ C3.16：权重信箱的三个 RW 档（**同一种写法**：整 32 位存储 + readAndWrite）。
  //   地址接在 DESC_COUNT(0x38) 之后：WGT_SEL=0x3C / WGT_ADDR=0x40 / WGT_DATA=0x44
  //   ⇒ 既有 15 格的地址/语义一个都不动（台账 `scripts/check_addr_map.py` 也无需改动：
  //     这四个仍落在既有的 16 KiB NPU 窗内）。
  val wgt_sel_r   = Reg(UInt(32 bits)) init 0
  val wgt_addr_r  = Reg(UInt(32 bits)) init 0
  val wgt_data_r  = Reg(UInt(32 bits)) init 0

  bus.readAndWrite(img_w,       0x08)
  bus.readAndWrite(img_h,       0x0C)
  bus.readAndWrite(c_in,        0x10)
  bus.readAndWrite(c_out,       0x14)
  bus.readAndWrite(group,       0x18)
  bus.readAndWrite(kernel,      0x1C)
  bus.readAndWrite(src_addr,    0x20)
  bus.readAndWrite(dst_addr,    0x24)
  bus.readAndWrite(quant_shift, 0x28)
  bus.readAndWrite(layer_id,    0x2C)
  bus.readAndWrite(desc_addr,   0x34)
  bus.readAndWrite(desc_count,  0x38)
  // ★ C3.16：权重信箱的三个 RW 档（WGT_WE 见下一节：它是**自清单拍**，不是一个 RW 存储）。
  bus.readAndWrite(wgt_sel_r,   0x3C)
  bus.readAndWrite(wgt_addr_r,  0x40)
  bus.readAndWrite(wgt_data_r,  0x44)

  // ---------------------------------------------------------------------------
  // 0x48 WGT_WE —— 权重信箱的写使能：**自清单拍**（与 CTRL.start / status_clr_r 同一套写法）
  //   写 1 起效、**下一拍自动清 0**（1 拍脉冲）；写 0 什么也不发生。它是**只写**档 ⇒ 回读恒 0
  //   （与 CTRL 的 bit0/bit1 同口径：写进去的模式不会被读回来）。
  // ---------------------------------------------------------------------------
  val wgt_we_r = Reg(Bool()) init False
  bus.write(wgt_we_r, 0x48, 0)
  when(wgt_we_r) { wgt_we_r := False }

  // ---------------------------------------------------------------------------
  // 0x30 ID —— 只读常数 0x594E5031（"YNP1"）。写它**永远**读回同一个常数。
  // ---------------------------------------------------------------------------
  bus.read(U(0x594E5031L, 32 bits), 0x30)

  // ---------------------------------------------------------------------------
  // 导出（类型化输出）
  // ---------------------------------------------------------------------------
  io.start         := start_r
  io.soft_reset    := soft_reset_r
  io.busy          := io.sched_busy
  io.done          := io.sched_done
  io.done_sticky   := done_sticky_r
  io.err           := io.sched_err
  io.img_w         := img_w
  io.img_h         := img_h
  io.c_in          := c_in
  io.c_out         := c_out
  io.group         := group
  io.kernel_stride := kernel(0)
  io.kernel_pad    := kernel(1)
  io.src_addr      := src_addr
  io.dst_addr      := dst_addr
  io.quant_shift   := quant_shift
  io.layer_id      := layer_id
  io.desc_addr     := desc_addr
  io.desc_count    := desc_count
  // ★ C3.16：权重信箱的四个导出（窄语义在这里显式表达：`wgt_data` = 低 8 位重解释成 int8）。
  io.wgt_sel       := wgt_sel_r
  io.wgt_addr      := wgt_addr_r
  io.wgt_data      := wgt_data_r(7 downto 0).asSInt
  io.wgt_we        := wgt_we_r
}
