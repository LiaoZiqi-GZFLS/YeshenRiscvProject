package misc

import java.io._
import scala.io.Source

class TotalTcl(srcPath: String = ".", destPath: String = ".") {
    // B9：本方法会扫描 srcPath 下所有 *.tcl 并拼成 totalIpTcl.tcl / totalIpTclList.txt
    // —— 这是 Xilinx IP tcl 的「汇总产物」，B9 停用 Xilinx IP tcl 后它没有输入，
    // 也不该再产出任何东西。变 no-op（不扫描、不写文件）。
    // 类名/构造签名/genTotalTcl 签名一字未改：克隆自己的 Npu.scala:186 与 top.scala:10
    // 仍在调用它，必须保持可编译（我们跑的是 rtl_gen/GenNpu.scala，不经过这两个入口，
    // 所以即便它们被调用也只是空转，不再写 Xilinx tcl）。
    def genTotalTcl: Unit = {
        /* B9-noop-begin（原 Xilinx IP tcl 汇总逻辑，已停用）
        val files = new File(srcPath).listFiles().filter(_.isFile).filter(t => t.toString.endsWith("tcl"))
        val destFile = new PrintWriter(new File(destPath + File.separator + "totalIpTcl.tcl"))
        val destFileList = new PrintWriter(new File(destPath + File.separator + "totalIpTclList.txt"))
        files.foreach(t => {
            destFileList.write(t.toString + "\n")
            destFile.write(Source.fromFile(t.toString).getLines().mkString("\n") + "\n")
        })
        destFileList.close()
        destFile.close()
        B9-noop-end */
    }
}

object TotalTcl {
    def apply(srcPath: String = ".", destPath: String = ".") = new TotalTcl(srcPath, destPath)
}
