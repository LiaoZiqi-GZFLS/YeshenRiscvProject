package wa.xip.math

import config.Config.{dsp2x, filePath}
import org.apache.commons.io.FileUtils
import spinal.core._
import spinal.lib._

class DSP(componentName: String, clockDomain2X: ClockDomain = null, stages: Int = 6) extends BlackBox {

    // B7：MAC 的流水级数。原 Xilinx dsp_macro 按 By_Tier 配了 tier_1..tier_6，即 6 级流水；
    // 这里把这个深度写成 Scala val 并插值进内联 Verilog —— 改这一个数即可做正/负对照，
    // 不是把 6 硬编码进字符串。默认 6 与上游 tcl 的一一对应（见 reports/build_notes.md 的 B7 段）。
    val DSP_STAGES: Int = stages

    val a = in UInt (8 bits)
    val d = in UInt (8 bits)
    val b = in UInt (8 bits)
    val p = if (!config.Config.dsp2x) out UInt (32 bits) else out UInt (64 bits)
    val CLK = in Bool()
    val a1 = config.Config.dsp2x generate (in UInt (8 bits))
    val d1 = config.Config.dsp2x generate (in UInt (8 bits))
    val CLK_2X = config.Config.dsp2x generate (in Bool())
    val RST_2X = config.Config.dsp2x generate (in Bool())
    this.mapClockDomain(clock = CLK)

    if (config.Config.dsp2x) {
        this.mapClockDomain(clockDomain = clockDomain2X, clock = CLK_2X, reset = RST_2X)
    }
    if (config.Config.dsp2x) {
        setInlineVerilog(
            """module DSP (
              input             [7:0] a       ,
              input             [7:0] d       ,
              input             [7:0] a1      ,
              input             [7:0] d1      ,
              input             [7:0] b       ,
              output            [63:0] p      ,
              input             CLK           ,
              input             CLK_2X        ,
              input             RST_2X


          );

          wire  signed       [7:0]   ain;
    assign ain = $signed(a);
    wire  signed       [24:0]  din;
    wire  signed       [7:0]   ain1;
    assign ain1 = $signed(a1);
    wire  signed       [24:0]  din1;
    assign din1 =  $signed({d1,16'd0});

    wire [33:0] pout;
    wire [15:0] pout1;
    wire [15:0] pout2;
    reg  [31:0] dsp2x_out;
    assign pout1 = pout[15:0];
    assign pout2 = pout[31:16];
    always@(*)begin
        if(pout1[15])begin
            dsp2x_out[15:0] = pout1;
            dsp2x_out[31:16] = pout2+1;
        end else begin
            dsp2x_out[15:0] = pout1;
            dsp2x_out[31:16] = pout2;
        end
    end
    assign din =  $signed({d,16'd0});
    reg dataIn ;
    reg dataInq ;
    reg dataInqq ;
    reg dataInqqq ;
    always@(posedge CLK_2X)begin
        if(RST_2X)begin
            dataIn <= 1'b0;
            dataInq <= dataIn;
            dataInqq <= dataInq;
            dataInqqq <= dataInqq;
        end else begin
            dataIn <= !dataIn;
            dataInq <= dataIn;
            dataInqq <= dataInq;
            dataInqqq <= dataInqq;
        end
    end
    reg [63:0] dsp_out;
    reg out_valid;
    always@(posedge CLK_2X)begin
        if(dataInqqq)begin
            dsp_out[63:32] <= dsp2x_out;
            out_valid <= 1'b1;
        end else begin
            dsp_out[31:0] <= dsp2x_out;
            out_valid <= 1'b0;
        end
    end
    wire out_validq;
    xpm_cdc_single #(
    .DEST_SYNC_FF(4), // DECIMAL; range: 2-10
    .INIT_SYNC_FF(0), // DECIMAL; 0=disable simulation init values, 1=enable simulation init values
    .SIM_ASSERT_CHK(0), // DECIMAL; 0=disable simulation messages, 1=enable simulation messages
    .SRC_INPUT_REG(1) // DECIMAL; 0=do not register input, 1=register input
    )
    dsp2x_s (
        .dest_out(out_validq), // 1-bit output: src_in synchronized to the destination clock domain. This output is
        // registered.

        .dest_clk(CLK), // 1-bit input: Clock signal for the destination clock domain.
        .src_clk(CLK_2X), // 1-bit input: optional; required when SRC_INPUT_REG = 1
        .src_in(out_valid) // 1-bit input: Input signal to be synchronized to dest_clk domain.
    );

    wire [63:0] dsp2x_x_out;
    xpm_cdc_gray #(
    .DEST_SYNC_FF(4), // DECIMAL; range: 2-10
    .INIT_SYNC_FF(0), // DECIMAL; 0=disable simulation init values, 1=enable simulation init values
    .REG_OUTPUT(0), // DECIMAL; 0=disable registered output, 1=enable registered output
    .SIM_ASSERT_CHK(0), // DECIMAL; 0=disable simulation messages, 1=enable simulation messages
    .SIM_LOSSLESS_GRAY_CHK(0), // DECIMAL; 0=disable lossless check, 1=enable lossless check
    .WIDTH(32) // DECIMAL; range: 2-32
    )
    dsp2x_x (
        .dest_out_bin(dsp2x_x_out[31:0]), // WIDTH-bit output: Binary input bus (src_in_bin) synchronized to
        // destination clock domain. This output is combinatorial unless REG_OUTPUT
        // is set to 1.

        .dest_clk(CLK), // 1-bit input: Destination clock.
        .src_clk(CLK_2X), // 1-bit input: Source clock.
        .src_in_bin(dsp_out[31:0]) // WIDTH-bit input: Binary input bus that will be synchronized to the
        // destination clock domain.

    );

       xpm_cdc_gray #(
          .DEST_SYNC_FF(4),          // DECIMAL; range: 2-10
          .INIT_SYNC_FF(0),          // DECIMAL; 0=disable simulation init values, 1=enable simulation init values
          .REG_OUTPUT(0),            // DECIMAL; 0=disable registered output, 1=enable registered output
          .SIM_ASSERT_CHK(0),        // DECIMAL; 0=disable simulation messages, 1=enable simulation messages
          .SIM_LOSSLESS_GRAY_CHK(0), // DECIMAL; 0=disable lossless check, 1=enable lossless check
          .WIDTH(32)                  // DECIMAL; range: 2-32
       )
       dsp2x_x1 (
          .dest_out_bin(dsp2x_x_out[63:32]), // WIDTH-bit output: Binary input bus (src_in_bin) synchronized to
                                       // destination clock domain. This output is combinatorial unless REG_OUTPUT
                                       // is set to 1.

          .dest_clk(CLK),         // 1-bit input: Destination clock.
          .src_clk(CLK_2X),           // 1-bit input: Source clock.
          .src_in_bin(dsp_out[63:32])      // WIDTH-bit input: Binary input bus that will be synchronized to the
                                       // destination clock domain.

       );

    reg [31:0] pTemp;
    always@(posedge CLK)begin
//        if(out_validq)begin
//            pTemp = pTemp;
//        end else begin
            pTemp = dsp2x_x_out[31:0];
//        end
    end
    assign p = {dsp2x_x_out[63:32],pTemp};
    reg  signed       [7:0]   dsp_ain;
    reg  signed       [24:0]   dsp_din;
    reg  signed       [8:0]   dsp_bin;

    wire  signed       [7:0]   aout;
    wire  signed       [7:0]   bout;
    wire  signed       [24:0]  dout;
    xpm_cdc_gray #(
          .DEST_SYNC_FF(4),          // DECIMAL; range: 2-10
          .INIT_SYNC_FF(0),          // DECIMAL; 0=disable simulation init values, 1=enable simulation init values
          .REG_OUTPUT(0),            // DECIMAL; 0=disable registered output, 1=enable registered output
          .SIM_ASSERT_CHK(0),        // DECIMAL; 0=disable simulation messages, 1=enable simulation messages
          .SIM_LOSSLESS_GRAY_CHK(0), // DECIMAL; 0=disable lossless check, 1=enable lossless check
          .WIDTH(8)                  // DECIMAL; range: 2-32
       )
       cdc_ain (
          .dest_out_bin(aout), // WIDTH-bit output: Binary input bus (src_in_bin) synchronized to
                                       // destination clock domain. This output is combinatorial unless REG_OUTPUT
                                       // is set to 1.

          .dest_clk(CLK_2X),         // 1-bit input: Destination clock.
          .src_clk(CLK),           // 1-bit input: Source clock.
          .src_in_bin(ain)      // WIDTH-bit input: Binary input bus that will be synchronized to the
                                       // destination clock domain.

       );
    xpm_cdc_gray #(
          .DEST_SYNC_FF(4),          // DECIMAL; range: 2-10
          .INIT_SYNC_FF(0),          // DECIMAL; 0=disable simulation init values, 1=enable simulation init values
          .REG_OUTPUT(0),            // DECIMAL; 0=disable registered output, 1=enable registered output
          .SIM_ASSERT_CHK(0),        // DECIMAL; 0=disable simulation messages, 1=enable simulation messages
          .SIM_LOSSLESS_GRAY_CHK(0), // DECIMAL; 0=disable lossless check, 1=enable lossless check
          .WIDTH(8)                  // DECIMAL; range: 2-32
       )
       cdc_bin (
          .dest_out_bin(bout), // WIDTH-bit output: Binary input bus (src_in_bin) synchronized to
                                       // destination clock domain. This output is combinatorial unless REG_OUTPUT
                                       // is set to 1.

          .dest_clk(CLK_2X),         // 1-bit input: Destination clock.
          .src_clk(CLK),           // 1-bit input: Source clock.
          .src_in_bin(b)      // WIDTH-bit input: Binary input bus that will be synchronized to the
                                       // destination clock domain.

       );
  xpm_cdc_gray #(
          .DEST_SYNC_FF(4),          // DECIMAL; range: 2-10
          .INIT_SYNC_FF(0),          // DECIMAL; 0=disable simulation init values, 1=enable simulation init values
          .REG_OUTPUT(0),            // DECIMAL; 0=disable registered output, 1=enable registered output
          .SIM_ASSERT_CHK(0),        // DECIMAL; 0=disable simulation messages, 1=enable simulation messages
          .SIM_LOSSLESS_GRAY_CHK(0), // DECIMAL; 0=disable lossless check, 1=enable lossless check
          .WIDTH(25)                  // DECIMAL; range: 2-32
       )
       cdc_din (
          .dest_out_bin(dout), // WIDTH-bit output: Binary input bus (src_in_bin) synchronized to
                                       // destination clock domain. This output is combinatorial unless REG_OUTPUT
                                       // is set to 1.

          .dest_clk(CLK_2X),         // 1-bit input: Destination clock.
          .src_clk(CLK),           // 1-bit input: Source clock.
          .src_in_bin(din)      // WIDTH-bit input: Binary input bus that will be synchronized to the
                                       // destination clock domain.

       );
    wire  signed       [7:0]   aout1;
    wire  signed       [24:0]  dout1;
    xpm_cdc_gray #(
          .DEST_SYNC_FF(4),          // DECIMAL; range: 2-10
          .INIT_SYNC_FF(0),          // DECIMAL; 0=disable simulation init values, 1=enable simulation init values
          .REG_OUTPUT(0),            // DECIMAL; 0=disable registered output, 1=enable registered output
          .SIM_ASSERT_CHK(0),        // DECIMAL; 0=disable simulation messages, 1=enable simulation messages
          .SIM_LOSSLESS_GRAY_CHK(0), // DECIMAL; 0=disable lossless check, 1=enable lossless check
          .WIDTH(8)                  // DECIMAL; range: 2-32
       )
       cdc_ain1 (
          .dest_out_bin(aout1), // WIDTH-bit output: Binary input bus (src_in_bin) synchronized to
                                       // destination clock domain. This output is combinatorial unless REG_OUTPUT
                                       // is set to 1.

          .dest_clk(CLK_2X),         // 1-bit input: Destination clock.
          .src_clk(CLK),           // 1-bit input: Source clock.
          .src_in_bin(ain1)      // WIDTH-bit input: Binary input bus that will be synchronized to the
                                       // destination clock domain.

       );
  xpm_cdc_gray #(
          .DEST_SYNC_FF(4),          // DECIMAL; range: 2-10
          .INIT_SYNC_FF(0),          // DECIMAL; 0=disable simulation init values, 1=enable simulation init values
          .REG_OUTPUT(0),            // DECIMAL; 0=disable registered output, 1=enable registered output
          .SIM_ASSERT_CHK(0),        // DECIMAL; 0=disable simulation messages, 1=enable simulation messages
          .SIM_LOSSLESS_GRAY_CHK(0), // DECIMAL; 0=disable lossless check, 1=enable lossless check
          .WIDTH(25)                  // DECIMAL; range: 2-32
       )
       cdc_din1 (
          .dest_out_bin(dout1), // WIDTH-bit output: Binary input bus (src_in_bin) synchronized to
                                       // destination clock domain. This output is combinatorial unless REG_OUTPUT
                                       // is set to 1.

          .dest_clk(CLK_2X),         // 1-bit input: Destination clock.
          .src_clk(CLK),           // 1-bit input: Source clock.
          .src_in_bin(din1)      // WIDTH-bit input: Binary input bus that will be synchronized to the
                                       // destination clock domain.

       );
    always @(posedge CLK_2X)begin
        if(dataIn)begin
            dsp_ain <= aout;
            dsp_bin <= {1'b0,bout};
            dsp_din <= dout;
        end else begin
            dsp_ain <= aout1;
            dsp_bin <= {1'b0,bout};
            dsp_din <= dout1;
        end
    end """ + "\r\n          " + componentName + " " + componentName + "_inst" +
                """ (
            .CLK(CLK_2X), // input wire CLK
            .A(dsp_ain), // input wire [7 : 0] A
            .B(dsp_bin), // input wire [8 : 0] B
            .D(dsp_din), // input wire [24 : 0] D
            .P(pout) // output wire [33 : 0] P
          );

endmodule
      """.stripMargin)
    } else {
        // B7：按 DSP_STAGES 生成流水寄存器声明与移位接线；寄存器名固定 dspPipe_0..dspPipe_(N-1)，
        // 顺序移位（dspPipe_0 收乘积，最后一级驱动 pout），级数 = 上游 tcl 的 tier 数 = 6。
        val pipeDecl = (0 until DSP_STAGES)
            .map(i => "          reg  signed       [33:0] dspPipe_" + i + ";")
            .mkString("", "\r\n", "\r\n")
        val pipeShift = (0 until DSP_STAGES)
            .map(i => "              dspPipe_" + i + " <= " + (if (i == 0) "dspProd" else "dspPipe_" + (i - 1)) + ";")
            .mkString("", "\r\n", "\r\n")
        setInlineVerilog(
            """module DSP (
              input             [7:0] a       ,
              input             [7:0] d       ,
              input             [7:0] b       ,
              output   reg      [31:0] p      ,
              input             CLK

          );

          wire  signed       [7:0]   ain;
          assign ain = $signed(a);
          wire  signed       [24:0]  din;
          wire [33:0] pout;
          wire [15:0] a1;
          wire [15:0] a2;
          assign a1 = pout[15:0];
          assign a2 = pout[31:16];
          always@(*)begin
               if(a1[15])begin
                   p[15:0] = a1;
                   p[31:16] = a2+1;
               end else begin
                   p[15:0] = a1;
                   p[31:16] = a2;
               end
          end
          assign din =  $signed({d,16'd0});

          // B7: this used to be an instance of the Xilinx DSP macro IP core
          // (instruction (A+D)*B, pipeline_options By_Tier, tier_1..tier_6 all true
          //  => 6 pipeline stages). Pango has no such IP, so it is now an equal-latency
          // behavioural pipeline whose depth is DSP_STAGES (default 6); the arithmetic
          // model is identical to the IP: (A+D)*B
          //   A = ain (8-bit signed)
          //   D = din (25-bit signed, = d<<16, so the d*b term lands at pout[31:16])
          //   B = {1'b0,b} (9-bit, always non-negative)
          // Both operands are forced $signed so Verilog performs a SIGNED multiply (otherwise
          // the low bits would be wrong when dspSum is negative). Product 26x9 => 35 bits,
          // truncated to 34 = original P/pout width; the wrapper only reads pout[31:0], so the
          // bit positions used by the rounding logic are unchanged.
          wire  signed       [25:0]  dspSum;
          assign dspSum = ain + din;
          wire  signed       [33:0]  dspProd;
          assign dspProd = dspSum * $signed({1'b0,b});
""" + pipeDecl + """
          always@(posedge CLK)begin
""" + pipeShift + """          end
          assign pout = dspPipe_""" + (DSP_STAGES - 1) + """;

endmodule
      """.stripMargin)
    }

}

object DSP {
    private var genClk = true

    // B7：DSP IP 已被等延迟的行为级流水替代，不再有任何 Xilinx IP 需要 create_ip
    // ⇒ 本函数变 no-op（不写任何 tcl）。原来那一大段 create_ip dsp_macro 配置整体注释保留，
    // 供对照/回溯；调用点 DSP.apply(..., genericTcl=true) 仍可用，只是什么都不做。
    def genTcl(componentName: String): Unit = {
        /* B7-noop-begin（原 Xilinx dsp_macro create_ip 逻辑，已停用）
        import java.io._
        val createDspCmd = s"set dspExit [lsearch -exact [get_ips $componentName] $componentName]\n" +
            s"if { $$dspExit <0} {\n" +
            s"create_ip -name dsp_macro -vendor xilinx.com -library ip -version 1.0 -module_name $componentName\n" +
            s"}\n" + s"set_property -dict [list CONFIG.instruction1 {(A+D)*B} CONFIG.pipeline_options {By_Tier} CONFIG.tier_1 {true} CONFIG.tier_2 {true} CONFIG.tier_3 {true} CONFIG.tier_4 {true} CONFIG.tier_5 {true} CONFIG.tier_6 {true} CONFIG.dreg_1 {true} CONFIG.dreg_2 {true} CONFIG.dreg_3 {true} CONFIG.areg_1 {true} CONFIG.areg_2 {true} CONFIG.areg_3 {true} CONFIG.areg_4 {true} CONFIG.breg_1 {true} CONFIG.breg_2 {true} CONFIG.breg_3 {true} CONFIG.breg_4 {true} CONFIG.creg_3 {false} CONFIG.creg_4 {false} CONFIG.creg_5 {false} CONFIG.mreg_5 {true} CONFIG.preg_6 {true} CONFIG.d_width {25} CONFIG.a_width {8} CONFIG.b_width {9}  CONFIG.d_binarywidth {0} CONFIG.a_width {8} CONFIG.a_binarywidth {0} CONFIG.b_binarywidth {0} CONFIG.concat_width {48} CONFIG.concat_binarywidth {0} CONFIG.c_width {48} CONFIG.c_binarywidth {0} CONFIG.pcin_binarywidth {0} CONFIG.p_full_width {34} CONFIG.p_width {34} CONFIG.p_binarywidth {0}] [get_ips $componentName]"
            //            s"}\n" + s"set_property -dict [list CONFIG.instruction1 {(A+D)*B} CONFIG.pipeline_options {By_Tier} CONFIG.tier_3 {true} CONFIG.tier_4 {true} CONFIG.tier_6 {true} CONFIG.d_width {26} CONFIG.a_width {8} CONFIG.b_width {9} CONFIG.dreg_3 {true} CONFIG.areg_3 {true} CONFIG.areg_4 {true} CONFIG.breg_3 {true} CONFIG.breg_4 {true} CONFIG.creg_3 {false} CONFIG.creg_4 {false} CONFIG.creg_5 {false} CONFIG.mreg_5 {false} CONFIG.preg_6 {true} CONFIG.d_binarywidth {0} CONFIG.a_binarywidth {0} CONFIG.b_binarywidth {0} CONFIG.concat_width {48} CONFIG.concat_binarywidth {0} CONFIG.c_width {48} CONFIG.c_binarywidth {0} CONFIG.pcin_binarywidth {0} CONFIG.p_full_width {36} CONFIG.p_width {35} CONFIG.p_binarywidth {0}] [get_ips $componentName]"
//            {if(!config.Config.dsp2x) s"}\n" + s"set_property -dict [list CONFIG.instruction1 {(A+D)*B} CONFIG.pipeline_options {By_Tier} CONFIG.tier_1 {false} CONFIG.tier_2 {false} CONFIG.tier_5 {false} CONFIG.dreg_1 {false} CONFIG.dreg_2 {false} CONFIG.dreg_3 {true} CONFIG.areg_1 {false} CONFIG.areg_2 {false} CONFIG.areg_3 {true} CONFIG.areg_4 {true} CONFIG.breg_1 {false} CONFIG.breg_2 {false} CONFIG.breg_3 {true} CONFIG.breg_4 {true} CONFIG.mreg_5 {false} CONFIG.preg_6 {true} CONFIG.d_width {25} CONFIG.a_width {8} CONFIG.b_width {9}  CONFIG.d_binarywidth {0} CONFIG.a_width {8} CONFIG.a_binarywidth {0} CONFIG.b_binarywidth {0} CONFIG.concat_width {48} CONFIG.concat_binarywidth {0} CONFIG.c_width {48} CONFIG.c_binarywidth {0} CONFIG.pcin_binarywidth {0} CONFIG.p_full_width {34} CONFIG.p_width {34} CONFIG.p_binarywidth {0}] [get_ips $componentName]"
//            else s"}\n" + s"set_property -dict [list CONFIG.instruction1 {(A+D)*B} CONFIG.pipeline_options {By_Tier} CONFIG.tier_1 {true} CONFIG.tier_2 {true} CONFIG.tier_3 {true} CONFIG.tier_4 {true} CONFIG.tier_5 {true} CONFIG.tier_6 {true} CONFIG.dreg_1 {true} CONFIG.dreg_2 {true} CONFIG.dreg_3 {true} CONFIG.areg_1 {true} CONFIG.areg_2 {true} CONFIG.areg_3 {true} CONFIG.areg_4 {true} CONFIG.breg_1 {true} CONFIG.breg_2 {true} CONFIG.breg_3 {true} CONFIG.breg_4 {true} CONFIG.creg_3 {false} CONFIG.creg_4 {false} CONFIG.creg_5 {false} CONFIG.mreg_5 {true} CONFIG.preg_6 {true} CONFIG.d_width {25} CONFIG.a_width {8} CONFIG.b_width {9}  CONFIG.d_binarywidth {0} CONFIG.a_width {8} CONFIG.a_binarywidth {0} CONFIG.b_binarywidth {0} CONFIG.concat_width {48} CONFIG.concat_binarywidth {0} CONFIG.c_width {48} CONFIG.c_binarywidth {0} CONFIG.pcin_binarywidth {0} CONFIG.p_full_width {34} CONFIG.p_width {34} CONFIG.p_binarywidth {0}] [get_ips $componentName]"}
        FileUtils.forceMkdir(new File(filePath + File.separator + "tcl"))
        val tclHeader = new PrintWriter(new File(filePath + File.separator + "tcl" + File.separator + s"generate$componentName.tcl"))
        tclHeader.write(createDspCmd)
        tclHeader.write("\r\n")
//        tclHeader.write(s"set_property generate_synth_checkpoint 0 [get_files $componentName.xci] \n")
        tclHeader.close()
        B7-noop-end */
    }

    def apply(componentName: String, myClockDomain: ClockDomain = null, genericTcl: Boolean = false) = {
        if (genericTcl) {
            genTcl(componentName)
        }
        val dsp = new DSP(componentName, clockDomain2X = myClockDomain)
        dsp
    }
}

//class TestDSP extends Component {
//    val io = new Bundle {
//        val a = in UInt (8 bits)
//        val d = in UInt (8 bits)
//        val b = in UInt (8 bits)
//        val p = out UInt (32 bits)
//    }
//    noIoPrefix()
//    val a1 = config.Config.dsp2x generate (in UInt (8 bits))
//    val d1 = config.Config.dsp2x generate (in UInt (8 bits))
//
//    val aa = DSP("dsp_macro_0", genericTcl = true)
//    io.a <> aa.a
//    io.b <> aa.b
//    io.d <> aa.d
//    io.p <> aa.p
//    if (config.Config.dsp2x) {
//        a1 <> aa.a1
//        d1 <> aa.d1
//    }
//
//}
//
//class top extends Component {
//    val io = new Bundle {
//        val a = in UInt (8 bits)
//        val d = in UInt (8 bits)
//        val b = in UInt (8 bits)
//        val p = out UInt (32 bits)
//    }
//    noIoPrefix()
//    val a1 = config.Config.dsp2x generate (in UInt (8 bits))
//    val d1 = config.Config.dsp2x generate (in UInt (8 bits))
//    val aa = new TestDSP
//    io.a <> aa.io.a
//    io.b <> aa.io.b
//    io.d <> aa.io.d
//    io.p <> aa.io.p
//    if (config.Config.dsp2x) {
//        a1 <> aa.a1
//        d1 <> aa.d1
//
//    }
//}
//
//object TestDSP extends App {
//    SpinalVerilog(new top)
//}
