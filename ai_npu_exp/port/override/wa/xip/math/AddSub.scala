package wa.xip.math

import config.Config.filePath
import org.apache.commons.io.FileUtils
import spinal.core._

object AddSubConfig {
    val signed = "signed"
    val unsigned = "Unsigned"
    val dsp = "DSP"
    val lut = "LUT"
    val subtract = "Subtract"
    val add = "Add"
}

/** B9b：把加/减法器从 Xilinx `c_addsub` IP 换成**等拍数、等符号性、等输出宽度**的行为实现。
  *
  * 契约（三条，全部来自原 tcl 与调用点，见 reports/build_notes.md 的 B9b 节）：
  *   1. **流水深度** = `PIPELINE_STAGE`（原来 c_addsub 的 `CONFIG.Latency`）。产物里落成
  *      `addPipe_0 … addPipe_{PIPELINE_STAGE-1}` 这 N 个寄存器，供判据数。
  *      7 个调用点的实测值：`1`（biasAdd / AddZero / leakySubZ3 / leakyAddZ3）、
  *      `2`（addAdd / concatAdd）、`5`（addAdd64_64，源码写的是 `2 + 3`）。
  *      `Latency=0` 是合法的（组合）⇒ 本类也支持 0。
  *   2. **运算** = `S = A ± B`，± 由 `CONFIG.Add_Mode`（`Add` / `Subtract`）静态决定。
  *   3. **符号性与宽度** = `A_TYPE` / `B_TYPE` 决定 A/B 是 `signed` 还是 `Unsigned`；
  *      `S_WIDTH` = `CONFIG.Out_Width`。**7 个调用点全部满足 `S_WIDTH == max(A_WIDTH,B_WIDTH)`**
  *      （即比精确和/差宽度**少 1 位**）⇒ 高位（进位/借位）被丢弃，
  *      `S = fullSum[S_WIDTH-1:0]`（模 2^S_WIDTH 的补码）。这不是随便选的：
  *      `Out_Width` 就是端口 S 的物理位宽，硬件只能丢掉 MSB，不可能"多"出一位来做饱和。
  *      调用点（`Quan.Zero` / `LeakyRelu`）正是拿 `S.sign` 与 `S > 255` 做饱和，
  *      与"回绕成负 ⇒ 输出 0"的行为一致。
  *
  * 为什么仍是 BlackBox + `setInlineVerilog`（与 B7/B8 同形状，理由同 B8 §1）：
  *   - 端口名/方向必须逐字不变（`A`/`B`/`S`/`CLK`，`noIoPrefix`）。BlackBox 原样保留
  *     `mapClockDomain(clockDomain, io.CLK)`，**8 个调用点一行都不用改**；改成普通 Component 后
  *     SpinalHDL 会按时钟域自动生成 `clk`/`reset` 端口，IO 契约就不保了。
  *   - 内联 Verilog 让我们能逐字控制 `addPipe_<n>` 寄存器名与切片，判据才数得准。
  *
  * 类构造参数新增 `pipelineStage` / `addMode`（都有默认值）；`object AddSub.apply` 的签名
  * **一字未动**（原来就收 `PIPELINE_STAGE` 与 `ADD_MODE`，只是以前只用它们写 tcl、没进行为），
  * 所以 8 个调用点编译与生成都无需编辑。
  */
class AddSub(A_WIDTH: Int, B_WIDTH: Int, S_WIDTH: Int, A_TYPE: String, B_TYPE: String, clockDomain: ClockDomain, componentName: String,
             pipelineStage: Int = 1, addMode: String = AddSubConfig.add)
    extends BlackBox {
    val io = new Bundle {
        val A = if (A_TYPE == AddSubConfig.signed) {
            in SInt (A_WIDTH bits)
        } else {
            in UInt (A_WIDTH bits)
        }
        val B = if (B_TYPE == AddSubConfig.signed) {
            in SInt (B_WIDTH bits)
        } else {
            in UInt (B_WIDTH bits)
        }
        val S = if (A_TYPE == AddSubConfig.signed || B_TYPE == AddSubConfig.signed) {
            out SInt (S_WIDTH bits)
        } else {
            out UInt (S_WIDTH bits)
        }
        val CLK = in Bool()
    }
    noIoPrefix()
    this.setDefinitionName(componentName)

    mapClockDomain(clockDomain, io.CLK)

    // ------------------------------------------------------------------
    // B9b 行为模型（替代 Xilinx c_addsub IP）
    // ------------------------------------------------------------------
    /** 完整精度宽度：`max(A,B) + 1` 恰好装得下"有符号 A ± 无符号 B"的精确值。 */
    val FULL_WIDTH: Int = math.max(A_WIDTH, B_WIDTH) + 1
    /** 流水级数（= 原 c_addsub 的 `CONFIG.Latency`）。 */
    val PIPELINE_STAGE: Int = pipelineStage
    /** 静态的加/减选择（= 原 c_addsub 的 `CONFIG.Add_Mode`）。 */
    val ADD_MODE: String = addMode

    require(PIPELINE_STAGE >= 0,
        s"AddSub($componentName): PIPELINE_STAGE 必须 >= 0，实为 $PIPELINE_STAGE")
    require(S_WIDTH <= FULL_WIDTH,
        s"AddSub($componentName): S_WIDTH $S_WIDTH 超过完整精度宽度 $FULL_WIDTH（A=$A_WIDTH B=$B_WIDTH）")
    require(S_WIDTH >= 1, s"AddSub($componentName): S_WIDTH 必须 >= 1")
    require(ADD_MODE == AddSubConfig.add || ADD_MODE == AddSubConfig.subtract,
        s"AddSub($componentName): Add_Mode 只能是 Add/Subtract，实为 $ADD_MODE")

    private def behaviouralVerilog(): String = {
        val fullW = FULL_WIDTH

        // 操作数按各自的 signedness 抬成「显式有符号」：
        //   signed   → $signed(x)           保持原值（负数是二补数）
        //   Unsigned → $signed({1'b0, x})   零扩展一位后再当有符号，值不变、不会被当成负数
        // 若漏掉这一步，`signed ± unsigned` 会被 Verilog 按**无符号**算，A 为负时结果全错 ——
        // 这正是本任务要防的静默错误（与 B8 的乘法同一个坑）。
        val aDecl =
            if (A_TYPE == AddSubConfig.signed)
                s"  wire signed [${fullW - 1}:0] aExt;\n  assign aExt = $$signed(A);"
            else
                s"  wire signed [${fullW - 1}:0] aExt;\n  assign aExt = $$signed({1'b0, A});"
        val bDecl =
            if (B_TYPE == AddSubConfig.signed)
                s"  wire signed [${fullW - 1}:0] bExt;\n  assign bExt = $$signed(B);"
            else
                s"  wire signed [${fullW - 1}:0] bExt;\n  assign bExt = $$signed({1'b0, B});"

        val op = if (ADD_MODE == AddSubConfig.subtract) "-" else "+"
        val sumDecl =
            s"  wire signed [${fullW - 1}:0] addSubSum;\n  assign addSubSum = aExt $op bExt;"

        val (pipeDecl, pipeLogic, lastSum) =
            if (PIPELINE_STAGE == 0) {
                ("", "", "addSubSum")
            } else {
                val decl = (0 until PIPELINE_STAGE)
                    .map(i => s"  reg  signed [${fullW - 1}:0] addPipe_$i;")
                    .mkString("", "\n", "\n")
                val logic = "  always @(posedge CLK) begin\n" +
                    (0 until PIPELINE_STAGE)
                        .map(i => s"    addPipe_$i <= " + (if (i == 0) "addSubSum" else s"addPipe_${i - 1}") + ";")
                        .mkString("", "\n", "\n") +
                    "\n  end\n"
                (decl, logic, s"addPipe_${PIPELINE_STAGE - 1}")
            }

        s"""// B9b: behavioural replacement for the Xilinx adder/subtractor IP core (c_addsub).
           |// Before B9b the parent only INSTANTIATED
           |//   $componentName <inst> (.A(...), .B(...), .S(...), .CLK(...))
           |// and no module body existed anywhere in the netlist (the vendor tcl used to make
           |// Vivado build the IP), so Pango had 113 such dangling instances. Arithmetic, signedness
           |// and both contracts are kept:
           |//   * operation      = A $op B      (was CONFIG.Add_Mode = $ADD_MODE)
           |//   * latency        = PIPELINE_STAGE registers, named addPipe_0 .. addPipe_${PIPELINE_STAGE - 1}
           |//                      (was CONFIG.Latency = $PIPELINE_STAGE over CLK)
           |//   * signedness     = A_TYPE=$A_TYPE, B_TYPE=$B_TYPE are re-applied with $$signed() below,
           |//                      because mixing signed with unsigned in Verilog silently makes the
           |//                      whole operation UNSIGNED (wrong result whenever the signed operand is negative).
           |//   * output width   = S_WIDTH = $S_WIDTH = CONFIG.Out_Width. The exact sum/difference needs
           |//                      max(A_WIDTH,B_WIDTH)+1 = $fullW bits, so the carry/borrow is discarded:
           |//                      S = result[${S_WIDTH - 1}:0], which is the only physical meaning of Out_Width
           |//                      (a hardware adder cannot saturate without extra logic). The call sites read
           |//                      S.sign / S > 255 afterwards for their own saturation, unchanged.
           |module $componentName (
           |  input  wire [${A_WIDTH - 1}:0] A,
           |  input  wire [${B_WIDTH - 1}:0] B,
           |  output wire [${S_WIDTH - 1}:0] S,
           |  input  wire CLK
           |);
           |
           |$aDecl
           |$bDecl
           |
           |$sumDecl
           |
           |$pipeDecl$pipeLogic
           |  assign S = $lastSum[${S_WIDTH - 1}:0];
           |
           |endmodule
           |""".stripMargin
    }

    setInlineVerilog(behaviouralVerilog())
}

object AddSub {
    // B9：本 genTcl 是 8 个残留 IP tcl 里 7 个（AddZero/addAdd/addAdd64_64/biasAdd/concatAdd/
    // leakyAddZ3/leakySubZ3）的唯一来源，全部来自 `create_ip -name c_addsub`。B9 的目标是
    // 「新生成不再产出任何 IP tcl」，所以这里变 no-op（不建 tcl 目录、不写文件）。
    // 签名一字未改，调用点 AddSub.apply(..., genTclScript) 无需改动。
    //
    // B9b 补充：这里停 tcl 只解决「不再让 Vivado 去生成 c_addsub」；上面 `class AddSub` 的
    // 行为化才解决「模块体缺失 ⇒ 悬空实例」。两者合起来才算把 c_addsub 彻底从设计里去掉。
    // 原来那段 create_ip c_addsub 配置整体注释保留，供对照/回溯。
    private def genTcl(A_WIDTH: Int, B_WIDTH: Int, P_WIDTH: Int, A_TYPE: String, B_TYPE: String, PIPELINE_STAGE: Int, RESOURCES_TYPE: String, ADD_MODE: String, componentName: String): Unit = {
        /* B9-noop-begin（原 Xilinx c_addsub create_ip 逻辑，已停用）
        import java.io._
        val createAddCmd = s"set addSubExit [lsearch -exact [get_ips $componentName] $componentName]\n" +
            s"if { $$addSubExit <0} {\n" +
            s"create_ip -name c_addsub -vendor xilinx.com -library ip -version 12.0 -module_name $componentName\n" +
            s"}\n"
        FileUtils.forceMkdir(new File(filePath + File.separator + "tcl"))
        val tclHeader = new PrintWriter(new File(filePath + File.separator + "tcl" + File.separator + s"generate$componentName.tcl"))
        tclHeader.write(createAddCmd)
        tclHeader.write(s"set_property -dict [list ")
        tclHeader.write(s"CONFIG.A_Width {$A_WIDTH} ")
        tclHeader.write(s"CONFIG.A_Type {$A_TYPE} ")
        tclHeader.write(s"CONFIG.B_Width {$B_WIDTH} ")
        tclHeader.write(s"CONFIG.B_Type {$B_TYPE} ")
        tclHeader.write(s"CONFIG.CE {false} ")
        tclHeader.write(s"CONFIG.Add_Mode {$ADD_MODE} ")
        // tclHeader.write(s"CONFIG.B_Value {false} ")
        val res = if (RESOURCES_TYPE == AddSubConfig.dsp) {
            "DSP48"
        } else {
            "Fabric"
        }
        tclHeader.write(s"CONFIG.Implementation {$res} ")
        //        val w = P_WIDTH - 1
        tclHeader.write(s"CONFIG.Out_Width {$P_WIDTH} ")
        tclHeader.write(s"CONFIG.Latency {$PIPELINE_STAGE} ")
        tclHeader.write(s"] [get_ips $componentName] \n")
//        tclHeader.write(s"set_property generate_synth_checkpoint 0 [get_files $componentName.xci] \n")
        tclHeader.close()
        B9-noop-end */


    }

    def apply(A_WIDTH: Int, B_WIDTH: Int, S_WIDTH: Int, A_TYPE: String, B_TYPE: String, PIPELINE_STAGE: Int, RESOURCES_TYPE: String, clockDomain: ClockDomain, ADD_MODE: String, componentName: String, genTclScript: Boolean = true) = {
        if (genTclScript) {
            genTcl(A_WIDTH, B_WIDTH, S_WIDTH, A_TYPE, B_TYPE, PIPELINE_STAGE, RESOURCES_TYPE, ADD_MODE, componentName)
        }
        // B9b：PIPELINE_STAGE（CONFIG.Latency）与 ADD_MODE（CONFIG.Add_Mode）从"只喂给 tcl"
        // 改成"同时喂给行为模型"。签名不变。
        val addSub = new AddSub(A_WIDTH, B_WIDTH, S_WIDTH, A_TYPE, B_TYPE, clockDomain, componentName,
            PIPELINE_STAGE, ADD_MODE)
        addSub
    }
}

//class testAddSub extends Component{
//    val io = new Bundle{
//        val A = in SInt(8 bits)
//        val B = in UInt(8 bits)
//        val P = out Vec(SInt(8 bits),5)
//    }
//    noIoPrefix()
//    val mul = Array.tabulate(5){i=>
//        def gen = {
//            val m = AddSub(8,8,8,AddSubConfig.signed,AddSubConfig.unsigned,1,AddSubConfig.lut,this.clockDomain,AddSubConfig.add,"add8_8_8",i==0)
//            m.io.A <> io.A
//            m.io.B <> io.B
//            m.io.S <> io.P(i)
//        }
//        gen
//    }
//
//
//}
//object testAddSub extends App {
//    SpinalVerilog(new testAddSub)
//}
