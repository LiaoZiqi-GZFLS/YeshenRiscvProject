package wa.xip.memory.xpm

import spinal.core._

class xpm_memory_sdpram(
                           ADDR_WIDTH_A: Int = 6, // DECIMAL
                           ADDR_WIDTH_B: Int = 6, // DECIMAL
                           AUTO_SLEEP_TIME: Int = 0, // DECIMAL
                           BYTE_WRITE_WIDTH_A: Int = 32, // DECIMAL
                           CASCADE_HEIGHT: Int = 0, // DECIMAL
                           CLOCKING_MODE: String = "common_clock", // String
                           ECC_MODE: String = "no_ecc", // String
                           MEMORY_INIT_FILE: String = "none", // String
                           MEMORY_INIT_PARAM: String = "0", // String
                           MEMORY_OPTIMIZATION: String = "true", // String
                           MEMORY_PRIMITIVE: String = "auto", // String
                           MEMORY_SIZE: Int = 2048, // DECIMAL
                           MESSAGE_CONTROL: Int = 0, // DECIMAL
                           READ_DATA_WIDTH_B: Int = 32, // DECIMAL
                           READ_LATENCY_B: Int = 2, // DECIMAL
                           READ_RESET_VALUE_B: String = "0", // String
                           RST_MODE_A: String = "SYNC", // String
                           RST_MODE_B: String = "SYNC", // String
                           SIM_ASSERT_CHK: Int = 0, // DECIMAL; 0=disable simulation messages, 1=enable simulation messages
                           USE_EMBEDDED_CONSTRAINT: Int = 0, // DECIMAL
                           USE_MEM_INIT: Int = 1, // DECIMAL
                           WAKEUP_TIME: String = "disable_sleep", // String
                           WRITE_DATA_WIDTH_A: Int = 32, // DECIMAL
                           WRITE_MODE_B: String = "no_change", // String
                           clka: ClockDomain,
                           clkb: ClockDomain
                       ) extends BlackBox {
    addGeneric("ADDR_WIDTH_A", ADDR_WIDTH_A)
    addGeneric("ADDR_WIDTH_B", ADDR_WIDTH_B)
    addGeneric("AUTO_SLEEP_TIME", AUTO_SLEEP_TIME)
    addGeneric("BYTE_WRITE_WIDTH_A", BYTE_WRITE_WIDTH_A)
    addGeneric("CASCADE_HEIGHT", CASCADE_HEIGHT)
    addGeneric("CLOCKING_MODE", CLOCKING_MODE)
    addGeneric("ECC_MODE", ECC_MODE)
    addGeneric("MEMORY_INIT_FILE", MEMORY_INIT_FILE)
    addGeneric("MEMORY_INIT_PARAM", MEMORY_INIT_PARAM)
    addGeneric("MEMORY_OPTIMIZATION", MEMORY_OPTIMIZATION)
    addGeneric("MEMORY_PRIMITIVE", MEMORY_PRIMITIVE)
    addGeneric("MEMORY_SIZE", MEMORY_SIZE)
    addGeneric("MESSAGE_CONTROL", MESSAGE_CONTROL)
    addGeneric("READ_DATA_WIDTH_B", READ_DATA_WIDTH_B)
    addGeneric("READ_LATENCY_B", READ_LATENCY_B)
    addGeneric("READ_RESET_VALUE_B", READ_RESET_VALUE_B)
    addGeneric("RST_MODE_A", RST_MODE_A)
    addGeneric("RST_MODE_B", RST_MODE_B)
    addGeneric("SIM_ASSERT_CHK", SIM_ASSERT_CHK)
    addGeneric("USE_EMBEDDED_CONSTRAINT", USE_EMBEDDED_CONSTRAINT)
    addGeneric("USE_MEM_INIT", USE_MEM_INIT)
    addGeneric("WAKEUP_TIME", WAKEUP_TIME)
    addGeneric("WRITE_DATA_WIDTH_A", WRITE_DATA_WIDTH_A)
    addGeneric("WRITE_MODE_B", WRITE_MODE_B)
    addGeneric("USE_MEM_INIT_MMI", 0)
    addGeneric("WRITE_PROTECT",1)
    val io = new Bundle {
        val dbiterrb = out Bool()
        val doutb = out Bits (READ_DATA_WIDTH_B bits)
        val sbiterrb = out Bool()
        val addra = in Bits (ADDR_WIDTH_A bits)
        val addrb = in Bits (ADDR_WIDTH_B bits)
        val clka = in Bool()
        val clkb = in Bool()
        val dina = in Bits (WRITE_DATA_WIDTH_A bits)
        val ena = in Bool()
        val enb = in Bool()
        val injectdbiterra = in Bool()
        val injectsbiterra = in Bool()
        val regceb = in Bool()
        val rstb = in Bool()
        val sleep = in Bool()
        val wea = in Bits (WRITE_DATA_WIDTH_A / BYTE_WRITE_WIDTH_A bits)
    }
    mapClockDomain(clka, io.clka)
    mapClockDomain(clkb, io.clkb)
    noIoPrefix()
}


object xpm_memory_sdpram {
    def apply(ADDR_WIDTH_A: Int = 6,
              ADDR_WIDTH_B: Int = 6,
              AUTO_SLEEP_TIME: Int = 0, // DECIMAL
              BYTE_WRITE_WIDTH_A: Int = 32, // DECIMAL
              CASCADE_HEIGHT: Int = 0, // DECIMAL
              CLOCKING_MODE: String = "common_clock", // String
              ECC_MODE: String = "no_ecc", // String
              MEMORY_INIT_FILE: String = "none", // String
              MEMORY_INIT_PARAM: String = "0", // String
              MEMORY_OPTIMIZATION: String = "true", // String
              MEMORY_PRIMITIVE: String = "auto", // String
              MEMORY_SIZE: Int = 2048, // DECIMAL
              MESSAGE_CONTROL: Int = 0, // DECIMAL
              READ_DATA_WIDTH_B: Int = 32, // DECIMAL
              READ_LATENCY_B: Int = 2, // DECIMAL
              READ_RESET_VALUE_B: String = "0", // String
              RST_MODE_A: String = "SYNC", // String
              RST_MODE_B: String = "SYNC", // String
              SIM_ASSERT_CHK: Int = 0, // DECIMAL; 0=disable simulation messages, 1=enable simulation messages
              USE_EMBEDDED_CONSTRAINT: Int = 0, // DECIMAL
              USE_MEM_INIT: Int = 1, // DECIMAL
              WAKEUP_TIME: String = "disable_sleep", // String
              WRITE_DATA_WIDTH_A: Int = 32, // DECIMAL
              WRITE_MODE_B: String = "no_change", // String
              clka: ClockDomain,
              clkb: ClockDomain
             )(dbiterrb: Bool, doutb: Bits, sbiterrb: Bool, addra: Bits, addrb: Bits, dina: Bits, ena: Bool, enb: Bool, injectdbiterra: Bool,
               injectsbiterra: Bool, regceb: Bool, rstb: Bool, sleep: Bool, wea: Bits): xpm_memory_sdpram = {
        val temp = new xpm_memory_sdpram(ADDR_WIDTH_A, ADDR_WIDTH_B, AUTO_SLEEP_TIME, BYTE_WRITE_WIDTH_A, CASCADE_HEIGHT, CLOCKING_MODE, ECC_MODE, MEMORY_INIT_FILE,
            MEMORY_INIT_PARAM, MEMORY_OPTIMIZATION, MEMORY_PRIMITIVE, MEMORY_SIZE, MESSAGE_CONTROL, READ_DATA_WIDTH_B, READ_LATENCY_B, READ_RESET_VALUE_B,
            RST_MODE_A, RST_MODE_B, SIM_ASSERT_CHK, USE_EMBEDDED_CONSTRAINT, USE_MEM_INIT, WAKEUP_TIME, WRITE_DATA_WIDTH_A, WRITE_MODE_B, clka, clkb)
        temp.io.dbiterrb <> dbiterrb
        temp.io.doutb <> doutb
        temp.io.sbiterrb <> sbiterrb
        temp.io.addra <> addra
        temp.io.addrb <> addrb
        temp.io.dina <> dina
        temp.io.ena <> ena
        temp.io.enb <> enb
        temp.io.injectdbiterra <> injectdbiterra
        temp.io.injectsbiterra <> injectsbiterra
        temp.io.regceb <> regceb
        temp.io.rstb <> rstb
        temp.io.sleep <> sleep
        temp.io.wea <> wea


        temp

    }
}

class sdpram(
                WRITE_WIDTH: Int,
                WRITE_DEPTH: Int,
                READ_WIDTH: Int,
                READ_DEPTH:Int,
                MEMORY_TYPE: String = "block",
                READ_LATENCY: Int = 2,
                CLOCK_MODE:String="common_clock",
                clka:ClockDomain,
                clkb:ClockDomain
            ) extends Component {
    assert(WRITE_DEPTH*WRITE_WIDTH == READ_DEPTH*READ_WIDTH,"读写空间大小不匹配")
    assert(READ_LATENCY >= 1, "READ_LATENCY 至少为 1")
    // Pango 化后的两条硬约束（原来的 XPM 能支持，这里显式拒绝而不是静默降级）：
    //  1) 两个端口共用同一时钟域（XPM 的 independent_clock 需要 CDC，SpinalHDL Mem 不提供）；
    //  2) Pango 无 UltraRAM，MEMORY_TYPE=ultra 对应 useUram=true 的死分支。
    assert(CLOCK_MODE == "common_clock", "Pango 化后只支持 CLOCK_MODE=common_clock（两端口同源时钟）")
    assert(MEMORY_TYPE == "auto" || MEMORY_TYPE == "block" || MEMORY_TYPE == "distributed", "Pango 化后 MEMORY_TYPE 只支持 auto/block/distributed（无 URAM）")
    val io = new Bundle {
        val doutb = out Bits (READ_WIDTH bits)
        val addra = in Bits (log2Up(WRITE_DEPTH) bits)
        val addrb = in Bits (log2Up(READ_DEPTH) bits)
        val dina = in Bits (WRITE_WIDTH bits)
        val ena = in Bool()
        val enb = in Bool()
        val wea = in Bits (1 bits)
    }
    noIoPrefix()

    // Pango 化：不再用 Xilinx XPM 原语，改为可综合的 SpinalHDL Mem。
    // 三条位宽相关的事实（都是实测出来的，见 reports/build_notes.md 的 B5 段）：
    //  (a) SpinalHDL 的 Verilog backend 拒绝"写口位宽 != Mem 字宽"（aspectRatio != 1），
    //      所以 Mem 的字宽必须取写位宽；
    //  (b) 读口比字宽"宽"在 SpinalHDL 里被显式拒绝（aspectRatio 会算成 0）；
    //  (c) 于是读比写宽时（本仓 quant RAM：128bit 写 / 512bit 读）用 ratio 个并行的
    //      "子字读"拼出宽字：第 k 个子字在地址 addrb*ratio+k，低地址进低位。
    //      这与 XPM 非对称口的物理实现一致（XPM 也是拆成多个 bank 并行读同一字地址）。
    val ratio: Int = READ_WIDTH / WRITE_WIDTH
    assert(READ_WIDTH >= WRITE_WIDTH && READ_WIDTH == WRITE_WIDTH * ratio && (ratio & (ratio - 1)) == 0,
           "Pango 化后只支持 READ_WIDTH >= WRITE_WIDTH 且为 2 的幂倍（本仓两个调用点：weight 1:1、quant 1:4）")
    // B5-fix：显式声明这块 RAM 要 BRAM。SpinalHDL 1.15.0 只会给"含异步读口"的 Mem 打
    // `ram_style = "distributed"`（PhaseDeviceDefault.onMemReadAsync），**同步读口什么都不打** ——
    // 所以"改成同步读"并不自动得到 block 属性，必须自己请求（本仓上游对 BRAM 存储一律这么写：
    // 例如 shape/MaxPooling.scala 的 rowMem）。这里按 MEMORY_TYPE 请求：auto/block → block，
    // distributed → distributed（调用点显式要求 LUTRAM 时才给）。两个调用点都传 block。
    val memStyle: String = if (MEMORY_TYPE == "distributed") "distributed" else "block"
    val mem = new Mem(Bits(WRITE_WIDTH bits), wordCount = WRITE_DEPTH)
    mem.addAttribute("ram_style = \"" + memStyle + "\"")
    val wrEnable = io.ena && io.wea(0)
    mem.write(address = io.addra.asUInt, data = io.dina, enable = wrEnable)

    // B5-fix：读口从"组合读出（readAsync）+ 全流水"改成"同步读出（readSync）+ 少一级流水"。
    // 为什么必须改：异步读（组合读出）的 Mem 会被 PhaseDeviceDefault 打上
    // `ram_style = "distributed"` ⇒ Pango/Xilinx 按 LUTRAM 实现，而权重 RAM 合计
    // 144×128bit×256 ≈ 4.7Mbit，LUTRAM 根本装不下。同步读口（地址寄存、数据当拍出）才是
    // BRAM 的可推断形状。
    //
    // 契约不变：doutb(t) = mem[addrb(t-READ_LATENCY)]，总延迟 = 1（存储器同步读自带的那一拍）
    //           + (READ_LATENCY-1)（下面的显式流水）。
    // readSync 的 enable 自己负责"enb 低时保持"，所以第 0 级不再需要 Mux(io.enb, …)。
    // 命名刻意保留 doutPipe_<n>（0 .. READ_LATENCY-2），让判据
    // tools/check_sdpram_latency.py 能直接数索引并换算总延迟。
    //
    // 坑：`val doutPipe/enPipe` 必须留在**组件体顶层**。把它们放进 Scala 的 if/else 块里，
    // SpinalHDL 的 val 命名不生效，网表里会退化成 `_zz_doutb*`，判据就数不到 doutPipe_<n>。
    // 因此 Vec 的尺寸在顶层算好（READ_LATENCY==1 时长度 0，不会建任何寄存器）。
    val rdBits: Bits = if (ratio == 1) {
        mem.readSync(address = io.addrb.asUInt, enable = io.enb)
    } else {
        (0 until ratio).map(k => mem.readSync(address = Cat(io.addrb, U(k, log2Up(ratio) bits)).asUInt,
                                               enable = io.enb)).reverse.reduceLeft(_ ## _)
    }
    val pipeDepth: Int = READ_LATENCY - 1
    val doutPipe = Vec(Reg(Bits(READ_WIDTH bits)) init (0), pipeDepth)
    val enPipe   = Vec(Reg(Bool()) init (False), math.max(pipeDepth - 1, 0))
    if (READ_LATENCY == 1) {
        // 只有存储器自带的那一拍：没有显式流水级，也避免索引一个零长度 Vec。
        io.doutb := rdBits
    } else {
        doutPipe(0) := rdBits // enb 的"保持"已由同步读口自己保证
        if (pipeDepth >= 2) {
            enPipe(0) := io.enb
            for (i <- 1 until pipeDepth) {
                doutPipe(i) := Mux(enPipe(i - 1), doutPipe(i - 1), doutPipe(i))
                if (i < pipeDepth - 1) enPipe(i) := enPipe(i - 1)
            }
        }
        io.doutb := doutPipe(pipeDepth - 1)
    }
}

//object sdpram {
//    def main(args: Array[String]): Unit = {
//        SpinalConfig(targetDirectory = "verilog").generateVerilog(new sdpram(64,409600,64,409600,"distributed",0,"common_clock",new ClockDomain(new Bool()),new ClockDomain(new Bool)))
//    }
//}
