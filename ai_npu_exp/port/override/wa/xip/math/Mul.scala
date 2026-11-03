package wa.xip.math

import spinal.core._

object MulConfig {
    val signed = "signed"
    val unsigned = "Unsigned"
    val dsp = "DSP"
    val lut = "LUT"
}

/** B8：把乘法器从 Xilinx `mult_gen` IP 换成**行为级乘法 + 等拍数流水**。
  *
  * 契约（两条，都必须保住）：
  *   1. **流水深度** = `PIPELINE_STAGE`（原来 mult_gen 的 `CONFIG.PipeStages`）；
  *      产物里落成 `mulPipe_0 … mulPipe_{PIPELINE_STAGE-1}` 这 N 个寄存器，供判据数。
  *   2. **输出位段语义** = `P = product[outMsb:outLsb]`（原来 mult_gen 的
  *      `OutputWidthHigh/OutputWidthLow`）。**这是本任务最容易静默做错的地方**：
  *      `Quan.scala:99` 取 `[79:48]`、`Concat.scala:114` 取 `[63:31]`，
  *      天真地写 `A*B` 再截低 P_WIDTH 位会得到**完全不同的数**，而 Verilog 不会报错。
  *
  * 为什么选「(a) 仍是 BlackBox + `setInlineVerilog`」而不是「(b) 改成普通 Component」：
  *   - 端口名/方向必须逐字不变（`A`/`B`/`P`/`CLK`，`noIoPrefix`）。BlackBox 原样保留
  *     `mapClockDomain(clockDomain, io.CLK)`，**5 个调用点一行都不用改**；改成 Component 后
  *     SpinalHDL 会按时钟域自动生成 `clk`/`reset` 端口、且注册域要另接，反而不保 IO 契约。
  *   - 与 B7（DSP）同形状，判据/回溯口径一致。
  *   - 内联 Verilog 让我们能**逐字控制**发出的切片与寄存器名，判据才数得准。
  *
  * 类构造参数新增 `outMsb`/`outLsb`/`pipelineStage`；`object Mul.apply` 的两个重载
  * **签名一字未动**（见文件末尾），调用点无需编辑。
  */
class Mul(A_WIDTH: Int, B_WIDTH: Int, P_WIDTH: Int, A_TYPE: String, B_TYPE: String,
          clockDomain: ClockDomain, componentName: String,
          outMsb: Int, outLsb: Int, pipelineStage: Int) extends BlackBox {
    val io = new Bundle {
        val A = if (A_TYPE == MulConfig.signed) {
            in SInt (A_WIDTH bits)
        } else {
            in UInt (A_WIDTH bits)
        }
        val B = if (B_TYPE == MulConfig.signed) {
            in SInt (B_WIDTH bits)
        } else {
            in UInt (B_WIDTH bits)
        }
        val P = if (A_TYPE == MulConfig.signed || B_TYPE == MulConfig.signed) {
            out SInt (P_WIDTH bits)
        } else {
            out UInt (P_WIDTH bits)
        }
        val CLK = in Bool()
    }
    noIoPrefix()
    this.setDefinitionName(componentName)

    mapClockDomain(clockDomain, io.CLK)

    // ------------------------------------------------------------------
    // B8 行为模型（替代 Xilinx mult_gen IP）
    // ------------------------------------------------------------------
    /** 完整乘积的位宽：signed(unsigned) × unsigned(signed) 的精确积恰好装得下 A_WIDTH+B_WIDTH 位。 */
    val PROD_WIDTH: Int = A_WIDTH + B_WIDTH
    /** 流水级数（= 原 mult_gen 的 CONFIG.PipeStages）。 */
    val PIPELINE_STAGE: Int = pipelineStage
    /** P 取的是**完整乘积**的哪一段（= 原 mult_gen 的 OutputWidthHigh/OutputWidthLow）。 */
    val OUT_MSB: Int = outMsb
    val OUT_LSB: Int = outLsb

    require(PIPELINE_STAGE >= 0, s"Mul($componentName): PIPELINE_STAGE 必须 >= 0，实为 $PIPELINE_STAGE")
    require(OUT_LSB >= 0 && OUT_MSB >= OUT_LSB,
        s"Mul($componentName): 非法位段 [$OUT_MSB:$OUT_LSB]")
    require(OUT_MSB < PROD_WIDTH,
        s"Mul($componentName): 位段上界 $OUT_MSB 越出完整乘积位宽 $PROD_WIDTH（A=$A_WIDTH B=$B_WIDTH）")
    require(OUT_MSB - OUT_LSB + 1 == P_WIDTH,
        s"Mul($componentName): 位段宽度 ${OUT_MSB - OUT_LSB + 1} != P_WIDTH $P_WIDTH")

    private def behaviouralVerilog(): String = {
        val prodW = PROD_WIDTH

        // 操作数按各自的 signedness 抬成「显式有符号」再相乘：
        //   signed   → $signed(x)            保持原值
        //   Unsigned → $signed({1'b0, x})    零扩展一位后再当有符号，值不变、且不会被当成负数
        // 若漏掉这一步（直接把 signed × unsigned 丢给 Verilog），Verilog 会按**无符号**做乘法，
        // 有符号操作数为负时低位全错 —— 这正是本任务要防的静默错误。
        val aDecl =
            if (A_TYPE == MulConfig.signed)
                s"  wire signed [${A_WIDTH - 1}:0] aExt;\n  assign aExt = $$signed(A);"
            else
                s"  wire signed [${A_WIDTH}:0] aExt;\n  assign aExt = $$signed({1'b0, A});"
        val bDecl =
            if (B_TYPE == MulConfig.signed)
                s"  wire signed [${B_WIDTH - 1}:0] bExt;\n  assign bExt = $$signed(B);"
            else
                s"  wire signed [${B_WIDTH}:0] bExt;\n  assign bExt = $$signed({1'b0, B});"

        // prod 的声明宽度即上下文宽度，两个有符号操作数会被符号扩展到这个宽度再相乘；
        // 精确积 ≤ PROD_WIDTH 位 ⇒ prod 就是完整的二补数乘积（不是低位截断）。
        val prodDecl =
            s"  wire signed [${prodW - 1}:0] prod;\n  assign prod = aExt * bExt;"

        val (pipeDecl, pipeLogic, lastProd) =
            if (PIPELINE_STAGE == 0) {
                ("", "", "prod")
            } else {
                val decl = (0 until PIPELINE_STAGE)
                    .map(i => s"  reg  signed [${prodW - 1}:0] mulPipe_$i;")
                    .mkString("", "\n", "\n")
                val logic = "  always @(posedge CLK) begin\n" +
                    (0 until PIPELINE_STAGE)
                        .map(i => s"    mulPipe_$i <= " + (if (i == 0) "prod" else s"mulPipe_${i - 1}") + ";")
                        .mkString("", "\n", "\n") +
                    "\n  end\n"
                (decl, logic, s"mulPipe_${PIPELINE_STAGE - 1}")
            }

        s"""// B8: behavioural replacement for the Xilinx multiplier IP core.
           |// This module is intentionally NOT an IP: before B8 the parent only INSTANTIATED
           |//   `$componentName ${componentName}_inst (...)`  (an IP the vendor tcl used to build)
           |// and the IP body was never defined, which Pango cannot synthesise. Arithmetic and
           |// both contracts are kept:
           |//   * pipeline depth   = PIPELINE_STAGE registers, named mulPipe_0 .. mulPipe_${PIPELINE_STAGE - 1}
           |//                        (was the IP property PipeStages = $PIPELINE_STAGE)
           |//   * output segment   = P = fullProduct[${OUT_MSB}:${OUT_LSB}]
           |//                        (was the IP properties OutputWidthHigh/OutputWidthLow)
           |//   * signedness       = A_TYPE=$A_TYPE, B_TYPE=$B_TYPE are re-applied with $$signed() below,
           |//                        because mixing signed with unsigned in Verilog silently makes the
           |//                        whole product UNSIGNED (wrong low bits whenever a signed operand is negative).
           |// The full product is A_WIDTH+B_WIDTH = $A_WIDTH+$B_WIDTH = $prodW bits wide; the pipeline
           |// registers carry that width and the [${OUT_MSB}:${OUT_LSB}] selection is applied at the output,
           |// exactly as the IP applies its output-width selection after its internal pipeline.
           |module $componentName (
           |  input  wire [${A_WIDTH - 1}:0] A,
           |  input  wire [${B_WIDTH - 1}:0] B,
           |  output wire [${P_WIDTH - 1}:0] P,
           |  input  wire CLK
           |);
           |
           |$aDecl
           |$bDecl
           |
           |$prodDecl
           |
           |$pipeDecl$pipeLogic
           |  assign P = $lastProd[$OUT_MSB:$OUT_LSB];
           |
           |endmodule
           |""".stripMargin
    }

    setInlineVerilog(behaviouralVerilog())
}

object Mul {
    /** B8：mult_gen IP 已不存在 ⇒ 本函数变 no-op（不写任何 tcl）。原 `create_ip -name mult_gen`
      * 逻辑整体注释保留，供对照/回溯；`apply` 的 `genTclScript=true` 路径仍可用，只是什么都不做。
      */
    private def genTcl(A_WIDTH: Int, B_WIDTH: Int, P_WIDTH: Int, A_TYPE: String, B_TYPE: String, PIPELINE_STAGE: Int, RESOURCES_TYPE: String, componentName: String): Unit = {
        /* B8-noop-begin（原 Xilinx mult_gen create_ip 逻辑，已停用）
        import java.io._
        val createMulCmd = s"set mulExit [lsearch -exact [get_ips $componentName] $componentName]\n" +
            s"if { $$mulExit <0} {\n" +
            s"create_ip -name mult_gen -vendor xilinx.com -library ip -version 12.0 -module_name $componentName\n" +
            s"}\n"
        FileUtils.forceMkdir(new File(filePath + File.separator + "tcl"))
        val tclHeader = new PrintWriter(new File(filePath + File.separator + "tcl" + File.separator + s"generate$componentName.tcl"))
        tclHeader.write(createMulCmd)
        tclHeader.write(s"set_property -dict [list ")
        tclHeader.write(s"CONFIG.PortAWidth {$A_WIDTH} ")
        tclHeader.write(s"CONFIG.PortAType {$A_TYPE} ")
        tclHeader.write(s"CONFIG.PortBWidth {$B_WIDTH} ")
        tclHeader.write(s"CONFIG.PortBType {$B_TYPE} ")
        val res = if (RESOURCES_TYPE == MulConfig.dsp) {
            "Use_Mults"
        } else {
            "Use_LUTs"
        }
        tclHeader.write(s"CONFIG.Multiplier_Construction {$res} ")
        val w = P_WIDTH - 1
        if (A_WIDTH + B_WIDTH != P_WIDTH) {
            tclHeader.write(s"CONFIG.Use_Custom_Output_Width {true} ")
        }
        tclHeader.write(s"CONFIG.OutputWidthHigh {$w} ")
        tclHeader.write(s"CONFIG.PipeStages {$PIPELINE_STAGE} ")
        tclHeader.write(s"] [get_ips $componentName] \n")
        tclHeader.write(s"set_property generate_synth_checkpoint 0 [get_files $componentName.xci] \n")
        tclHeader.close()
        B8-noop-end */
    }

    private def genTcl(A_WIDTH: Int, B_WIDTH: Int, A_TYPE: String, B_TYPE: String, PIPELINE_STAGE: Int, RESOURCES_TYPE: String, componentName: String, outMsb: Int, outLsb: Int): Unit = {
        /* B8-noop-begin（原 Xilinx mult_gen create_ip 逻辑，已停用）
        import java.io._
        val createMulCmd = s"set mulExit [lsearch -exact [get_ips $componentName] $componentName]\n" +
            s"if { $$mulExit <0} {\n" +
            s"create_ip -name mult_gen -vendor xilinx.com -library ip -version 12.0 -module_name $componentName\n" +
            s"}\n"
        FileUtils.forceMkdir(new File(filePath + File.separator + "tcl"))
        val tclHeader = new PrintWriter(new File(filePath + File.separator + "tcl" + File.separator + s"generate$componentName.tcl"))
        tclHeader.write(createMulCmd)
        tclHeader.write(s"set_property -dict [list ")
        tclHeader.write(s"CONFIG.PortAWidth {$A_WIDTH} ")
        tclHeader.write(s"CONFIG.PortAType {$A_TYPE} ")
        tclHeader.write(s"CONFIG.PortBWidth {$B_WIDTH} ")
        tclHeader.write(s"CONFIG.PortBType {$B_TYPE} ")
        val res = if (RESOURCES_TYPE == MulConfig.dsp) {
            "Use_Mults"
        } else {
            "Use_LUTs"
        }
        tclHeader.write(s"CONFIG.Multiplier_Construction {$res} ")
        tclHeader.write(s"CONFIG.Use_Custom_Output_Width {true} ")
        tclHeader.write(s"CONFIG.OutputWidthHigh {$outMsb} ")
        tclHeader.write(s"CONFIG.OutputWidthLow {$outLsb} ")
        tclHeader.write(s"CONFIG.PipeStages {$PIPELINE_STAGE} ")
        tclHeader.write(s"] [get_ips $componentName] \n")
//        tclHeader.write(s"set_property generate_synth_checkpoint 0 [get_files $componentName.xci] \n")
        tclHeader.close()
        B8-noop-end */
    }

    /** 重载 1（签名与上游一字不差）：不给位段 ⇒ P = product[P_WIDTH-1:0]，
      * 与原 tcl 的 `OutputWidthHigh = P_WIDTH-1` + 默认 `OutputWidthLow = 0` 完全一致。
      */
    def apply(A_WIDTH: Int, B_WIDTH: Int, P_WIDTH: Int, A_TYPE: String, B_TYPE: String, PIPELINE_STAGE: Int, RESOURCES_TYPE: String, clockDomain: ClockDomain, componentName: String, genTclScript: Boolean = true) = {
        if (genTclScript) {
            // mulIndex = mulIndex + 1
            genTcl(A_WIDTH, B_WIDTH, P_WIDTH, A_TYPE, B_TYPE, PIPELINE_STAGE, RESOURCES_TYPE, componentName)
        }
        val mul = new Mul(A_WIDTH, B_WIDTH, P_WIDTH, A_TYPE, B_TYPE, clockDomain, componentName,
            P_WIDTH - 1, 0, PIPELINE_STAGE)
        mul
    }

    /** 重载 2（签名与上游一字不差）：给了位段 ⇒ P = product[outMsb:outLsb]。
      * 这里是真正会出错的一路（Quan `[79:48]`、Concat `[63:31]`），位段原样透传给类。
      */
    def apply(A_WIDTH: Int, B_WIDTH: Int, P_WIDTH: Int, A_TYPE: String, B_TYPE: String, PIPELINE_STAGE: Int, RESOURCES_TYPE: String, clockDomain: ClockDomain, componentName: String, outMsb: Int, outLsb: Int, genTclScript: Boolean) = {
        if (genTclScript) {
            // mulIndex = mulIndex + 1
            genTcl(A_WIDTH, B_WIDTH, A_TYPE, B_TYPE, PIPELINE_STAGE, RESOURCES_TYPE, componentName, outMsb, outLsb)
        }
        val mul = new Mul(A_WIDTH, B_WIDTH, P_WIDTH, A_TYPE, B_TYPE, clockDomain, componentName,
            outMsb, outLsb, PIPELINE_STAGE)
        mul
    }
}
