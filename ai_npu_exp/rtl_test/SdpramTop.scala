import spinal.core._
import wa.xip.memory.xpm.sdpram

class SdpramTop(readLatency: Int) extends Component {
    val io = new Bundle {
        val ena   = in Bool()
        val wea   = in Bits (1 bits)
        val addra = in Bits (9 bits)
        val dina  = in Bits (64 bits)
        val enb   = in Bool()
        val addrb = in Bits (9 bits)
        val doutb = out Bits (64 bits)
    }
    noIoPrefix()
    val m = new sdpram(64, 512, 64, 512, "block", readLatency, "common_clock",
                       this.clockDomain, this.clockDomain)
    m.io.ena <> io.ena
    m.io.wea <> io.wea
    m.io.addra <> io.addra
    m.io.dina <> io.dina
    m.io.enb <> io.enb
    m.io.addrb <> io.addrb
    io.doutb <> m.io.doutb
}

object SdpramGen extends App {
    val outDir = args(0)
    val lat    = args(1).toInt
    SpinalConfig(
        headerWithDate = false,
        headerWithRepoHash = false,
        oneFilePerComponent = false,
        targetDirectory = outDir
    ).generateVerilog(new SdpramTop(lat))
    println("SDPRAMGEN_DONE lat=" + lat + " -> " + outDir)
}
