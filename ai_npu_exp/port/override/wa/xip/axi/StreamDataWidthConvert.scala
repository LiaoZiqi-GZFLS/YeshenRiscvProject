package wa.xip.axi

import config.Config.filePath
import org.apache.commons.io.FileUtils
import spinal.core._
import spinal.lib._

/** B9b：把「流位宽转换器」从 Xilinx `axis_dwidth_converter` IP 换成**行为实现**。
  *
  * 契约（来自原 tcl + 唯一的调用点 `conv/dataGenerate/FeatureWidthConvert.scala:82`）：
  *   1. **方向与比例**：`S_DATA_WIDTH = COMPUTE_CHANNEL_NUM*8 = 128`、
  *      `M_DATA_WIDTH = 8*S_DATA_WIDTH = 1024`（见 `FeatureWidthConvert.scala:65,66`），
  *      即 **1:8 升宽（narrow → wide）**，比例 = `M/S = 8`。网表实例端口也是这个方向
  *      （`s_axis_tdata[127:0]` / `m_axis_tdata[1023:0]`，`gen/Npu.v`）。**不做降宽**：
  *      本设计不存在降宽配置，真出现时会由 `require` 在展开期报错（fail fast，不静默发错模块）。
  *   2. **tcl 里没有延迟配置**：`object StreamDataWidthConvert.genTcl` 只写
  *      `CONFIG.S_TDATA_NUM_BYTES` / `CONFIG.M_TDATA_NUM_BYTES` / `CONFIG.HAS_MI_TKEEP {0}`
  *      —— **没有任何 `Latency` / `CONFIG.Latency` 之类的键**。所以本任务**不能**从 tcl 推出
  *      IP 的固有拍数（该 IP 是同步流转换器，内部有寄存器，但拍数不由 tcl 暴露）。
  *      因此这里只保「**结构上必须的**存储级数」：升宽 1:R 至少要把 R 个窄拍收齐才能拼出一个
  *      宽拍 ⇒ `dwcPipe_0 … dwcPipe_{R-1}` 共 R 级；从第一个窄拍被接收算起，宽拍在第 R 拍有效。
  *      **本实现不主张与 Xilinx IP 逐拍等价**（无 tcl 依据），只主张：IO 契约逐字不变、
  *      数据打包顺序正确、R 级存储结构明确且可判。
  *   3. **打包顺序**：升宽时**第一个被接收的窄拍落在宽字的低位**（`m_axis_tdata[S-1:0]`），
  *      第 R 个落在最高位。依据：AXI4-Stream 的 byte-lane 约定（TDATA 的字节序 = 地址递增序，
  *      先到的窄拍在低字节道），且调用点正是按这个序消费 ——
  *      `FeatureWidthConvert.scala:88` 把 `mData.payload` `subdivideIn(8 slices)(i)` 当成第 i 条
  *      通道（slice 0 = `[127:0]` = 最低位），所以 beat 0 必须落在 slice 0。
  *   4. **旁带**：tcl 设 `HAS_MI_TKEEP {0}`，且 blackbox 本身没有 tkeep/tlast 端口 ⇒
  *      行为模型也只有 tdata/tvalid/tready（与实例端口逐个对齐）。
  *
  * 为什么仍是 BlackBox + `setInlineVerilog`：同 B8 §1 —— `slave Stream` / `master Stream` 的
  * 名字是 `s_axis_*` / `m_axis_*`（`setName` 过的），且时钟域由 `aclk`/`aresetn` 映射而来；
  * 改成普通 Component 会动 IO 契约，而 BlackBox 路线**调用点一行都不用改**。
  *
  * 类构造参数新增 `dwcStages`（默认 0 = 自动取比例 R）与 `newestAtMsb`（默认 false，只用于
  * 判据的**负对照**：把打包顺序反过来）。`object StreamDataWidthConvert.apply` 签名一字未动。
  */
class StreamDataWidthConvert(sDataWidth: Int, mDataWidth: Int, componentName: String,
                             dwcStages: Int = 0, newestAtMsb: Boolean = false) extends BlackBox {
    val io = new Bundle {
        val sData = slave Stream UInt(sDataWidth bits)
        val mData = master Stream UInt(mDataWidth bits)
        val aclk = in Bool()
        val aresetn = in Bool()
    }
    noIoPrefix()
    io.sData.payload.setName("s_axis_tdata")
    io.sData.valid.setName("s_axis_tvalid")
    io.sData.ready.setName("s_axis_tready")
    io.mData.payload.setName("m_axis_tdata")
    io.mData.valid.setName("m_axis_tvalid")
    io.mData.ready.setName("m_axis_tready")
    this.mapClockDomain(clock = io.aclk, reset = io.aresetn, resetActiveLevel = LOW)
    this.setDefinitionName(componentName)

    // ------------------------------------------------------------------
    // B9b 行为模型（替代 Xilinx axis_dwidth_converter IP）
    // ------------------------------------------------------------------
    require(sDataWidth > 0 && mDataWidth > 0, s"StreamDataWidthConvert($componentName): 位宽必须 > 0")
    require(mDataWidth > sDataWidth,
        s"StreamDataWidthConvert($componentName): 目前只实现升宽（narrow→wide）；实测 mDataWidth=$mDataWidth sDataWidth=$sDataWidth")
    require(mDataWidth % sDataWidth == 0,
        s"StreamDataWidthConvert($componentName): 比例必须整除：M=$mDataWidth % S=$sDataWidth != 0")

    /** 比例 R = M/S：升宽 1:R 至少要收齐 R 个窄拍。 */
    val RATIO: Int = mDataWidth / sDataWidth
    /** 存储级数：默认 = 比例 R（生产值 8）；负对照传 R-1 等。 */
    val DWC_STAGES: Int = if (dwcStages <= 0) RATIO else dwcStages
    /** 打包顺序：false（默认）= 第一个窄拍在低位（AXI 约定）；true = 反过来（**仅供负对照**）。 */
    val NEWEST_AT_MSB: Boolean = newestAtMsb

    require(DWC_STAGES >= 1, s"StreamDataWidthConvert($componentName): DWC_STAGES 必须 >= 1")

    private def behaviouralVerilog(): String = {
        val n = DWC_STAGES
        val sW = sDataWidth
        val mW = mDataWidth
        // 注意：`scala.math` 必须写全 —— `import spinal.lib._` 把 `spinal.lib.math` 带进作用域，
        // 裸写 `math.max` 会被解析成包名（实测编译错：object max is not a member of package spinal.lib.math）。
        val cw = scala.math.max(1, log2Up(n + 1)) // dwcCount 的位宽（0..n）

        // 槽位语义：`dwcPipe_i` 装的是**本包第 i 个**窄拍（slot 0 = 最先到的拍）。
        // 新拍**按 dwcWrIdx 索引写入**（不是无脑移位）—— 这样"包被取走的那一拍同时进新拍"时，
        // 新拍落在 slot 0，不会残留上一包的旧数据（移位式实现会在这里静默串包）。
        val pipeDecl = (0 until n)
            .map(i => s"  reg  [${sW - 1}:0] dwcPipe_$i;")
            .mkString("", "\n", "\n")
        val pipeReset = (0 until n)
            .map(i => s"      dwcPipe_$i <= ${sW}'d0;")
            .mkString("", "\n", "\n")
        val pipeWrite = (0 until n)
            .map(i => s"      dwcPipe_$i <= (dwcWrIdx == ${cw}'d$i) ? s_axis_tdata : dwcPipe_$i;")
            .mkString("", "\n", "\n")

        // 打包顺序：concat 的**最左**元素放最高位。
        //   NEWEST_AT_MSB=false（默认，正确）：{dwcPipe_{n-1}, ..., dwcPipe_1, dwcPipe_0}
        //       ⇒ slot 0（最先到的拍）在低位 m_axis_tdata[S-1:0]，第 n 拍在最高位 —— AXI 约定
        //   NEWEST_AT_MSB=true（负对照）：反过来（最先到的拍跑到高位），判据的打包顺序检查会 FAIL
        val concatElems =
            if (NEWEST_AT_MSB) (0 until n).map(i => s"dwcPipe_$i").mkString("{", ", ", "}")
            else (0 until n).reverse.map(i => s"dwcPipe_$i").mkString("{", ", ", "}")

        val outSel =
            if (n * sW >= mW) s"dwcData[${mW - 1}:0]" else "dwcData"

        s"""// B9b: behavioural replacement for the Xilinx AXI4-Stream Data Width Converter IP core
           |// (axis_dwidth_converter). The parent used to only INSTANTIATE it
           |//   $componentName <inst> (.s_axis_*, .m_axis_*, .aclk, .aresetn)
           |// while its body came from a vendor tcl that no longer runs (B9), leaving a dangling
           |// instance that Pango cannot elaborate. This is a 1:$RATIO UPSIZER: every $sW-bit input
           |// beat is stored in slot dwcPipe_<k> for k = 0..$n-1 (slot 0 = the FIRST beat of the packet);
           |// the output word is presented once $n beats have been collected. Latency = $n accepted
           |// beats = the structurally required depth (the vendor tcl set only S_TDATA_NUM_BYTES /
           |// M_TDATA_NUM_BYTES / HAS_MI_TKEEP = 0 and exposes NO latency property, so the IP's own
           |// pipeline depth cannot be derived from it; this model claims the IO contract, the packing
           |// order and full throughput, NOT cycle-for-cycle equality with the IP).
           |// Packing order: slot 0 (first beat) drives the lowest bits, m_axis_tdata[${sW - 1}:0]
           |// (AXI4-Stream byte-lane order; the consumer assumes it:
           |//  FeatureWidthConvert.scala subdivides the payload into slices with slice 0 = bits [${sW - 1}:0]).
           |// Handshake: a beat is accepted into slot dwcCount, and a drain (the same cycle the packet is
           |// taken downstream) re-uses slot 0, so back-to-back packets are packed correctly without a bubble.
           |module $componentName (
           |  input  wire [${sW - 1}:0] s_axis_tdata,
           |  input  wire s_axis_tvalid,
           |  output wire s_axis_tready,
           |  output wire [${mW - 1}:0] m_axis_tdata,
           |  output wire m_axis_tvalid,
           |  input  wire m_axis_tready,
           |  input  wire aclk,
           |  input  wire aresetn
           |);
           |
           |$pipeDecl
           |  reg  [${cw - 1}:0] dwcCount;
           |
           |  wire dwcFull;
           |  wire dwcDrain;
           |  wire dwcAccept;
           |  wire [${cw - 1}:0] dwcWrIdx;
           |  assign dwcFull = (dwcCount == ${cw}'d$n);
           |  assign dwcDrain = dwcFull & m_axis_tready;
           |  assign dwcAccept = s_axis_tvalid & s_axis_tready;
           |  assign dwcWrIdx = dwcDrain ? ${cw}'d0 : dwcCount;
           |
           |  assign m_axis_tvalid = dwcFull;
           |  assign s_axis_tready = (~dwcFull) | m_axis_tready;
           |
           |  always @(posedge aclk) begin
           |    if (!aresetn) begin
           |      dwcCount <= ${cw}'d0;
           |$pipeReset
           |    end else begin
           |      if (dwcAccept) begin
           |$pipeWrite
           |      end
           |      if (dwcDrain) begin
           |        dwcCount <= dwcAccept ? ${cw}'d1 : ${cw}'d0;
           |      end else if (dwcAccept) begin
           |        dwcCount <= dwcCount + ${cw}'d1;
           |      end
           |    end
           |  end
           |
           |  wire [${n * sW - 1}:0] dwcData;
           |  assign dwcData = $concatElems;
           |  assign m_axis_tdata = $outSel;
           |
           |endmodule
           |""".stripMargin
    }

    setInlineVerilog(behaviouralVerilog())
}

object StreamDataWidthConvert {
    // B9：本 genTcl 是 8 个残留 IP tcl 里第 8 个（conv11DataCvt）的唯一来源，
    // 来自 `create_ip -name axis_dwidth_converter`。B9 目标「新生成不再产出任何 IP tcl」，
    // 所以这里变 no-op。签名一字未改，调用点 apply(..., generateTcl) 无需改动。
    //
    // B9b 补充：这里停 tcl 只解决「不再让 Vivado 去生成 axis_dwidth_converter」；上面
    // `class StreamDataWidthConvert` 的行为化才解决「模块体缺失 ⇒ 悬空实例」。原来那段
    // create_ip 逻辑整体注释保留，供对照/回溯 —— 也正因为这段注释里只有
    // S_TDATA_NUM_BYTES / M_TDATA_NUM_BYTES / HAS_MI_TKEEP **三个键、没有延迟键**，
    // 才能断言「IP 拍数不从 tcl 可得」（见类头契约 2）。
    private def genTcl(sDataWidth: Int, mDataWidth: Int, componentName: String): Unit = {
        /* B9-noop-begin（原 Xilinx axis_dwidth_converter create_ip 逻辑，已停用）
        import java.io._
        val createAddCmd = s"set dataConvert [lsearch -exact [get_ips $componentName] $componentName]\n" +
            s"if { $$dataConvert <0} {\n" +
            s"create_ip -name axis_dwidth_converter -vendor xilinx.com -library ip -version 1.1 -module_name $componentName\n" +
            s"}\n"
        FileUtils.forceMkdir(new File(filePath + File.separator + "tcl"))
        val tclHeader = new PrintWriter(new File(filePath + File.separator + "tcl" + File.separator + s"generate$componentName.tcl"))
        tclHeader.write(createAddCmd)
        val sByte = sDataWidth / 8
        val mByte = mDataWidth / 8
        tclHeader.write(s"set_property -dict [list ")
        tclHeader.write(s"CONFIG.S_TDATA_NUM_BYTES {$sByte} ")
        tclHeader.write(s"CONFIG.M_TDATA_NUM_BYTES {$mByte} ")
        tclHeader.write(s"CONFIG.HAS_MI_TKEEP {0} ")
        tclHeader.write(s"] [get_ips $componentName] \n")
//        tclHeader.write(s"set_property generate_synth_checkpoint 0 [get_files $componentName.xci] \n")
        tclHeader.close()
        B9-noop-end */
    }

    def apply(sDataWidth: Int, mDataWidth: Int, componentName: String, generateTcl: Boolean = false) = {
        if (generateTcl) {
            genTcl(sDataWidth, mDataWidth, componentName)
        }
        // B9b：不传 dwcStages/newestAtMsb ⇒ 走生产默认（级数 = 比例 R，顺序 = 第一个窄拍在低位）。
        val dataWidthConvert = new StreamDataWidthConvert(sDataWidth, mDataWidth, componentName)
        dataWidthConvert
    }
}

//class TestDataWidthConvert extends Component {
//    val io = new Bundle {
//        val sData = slave Stream UInt(32 bits)
//        val mData = master Stream UInt(64 bits)
//    }
//    noIoPrefix()
//    val data = StreamDataWidthConvert(32, 64, "convData1", true)
//    data.io.sData <> io.sData
//    data.io.mData <> io.mData
//}
//
//object TestDataWidthConvert extends App {
////    val clk = ClockDomainConfig(resetActiveLevel = LOW)
////    SpinalConfig(defaultConfigForClockDomains =  clk).generateVerilog(new TestDataWidthConvert)
//    SpinalVerilog(new TestDataWidthConvert)
//}
