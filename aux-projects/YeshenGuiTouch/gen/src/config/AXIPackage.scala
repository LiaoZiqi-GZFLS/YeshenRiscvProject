import chisel3._

// ===================== AXI 总线包定义 =====================
// 定义 Dcache、RB、VB、MMIO 和外层总线共享的 AXI4 子集接口。

class AXIAR extends Bundle {
  val arid    = Output(UInt(4.W))
  val araddr  = Output(UInt(32.W))
  val arlen   = Output(UInt(8.W))
  val arsize  = Output(UInt(3.W))
  val arburst = Output(UInt(2.W))
  val arlock  = Output(UInt(3.W))
  val arcache = Output(UInt(4.W))
  val arprot  = Output(UInt(3.W))
  val arvalid = Output(Bool())
  val arready = Input(Bool())
}

class AXIARRBReq extends Bundle {
  val araddr  = Output(UInt(32.W))
  val arlen   = Output(UInt(8.W))
  val arsize  = Output(UInt(3.W))
  val arvalid = Output(Bool())
  val arready = Input(Bool())
}

class AXIR extends Bundle {
  val rid    = Input(UInt(4.W))
  val rdata  = Input(UInt(32.W))
  val rresp  = Input(UInt(2.W))
  val rlast  = Input(Bool())
  val rvalid = Input(Bool())
  val rready = Output(Bool())
}

class AXIRRBReq extends Bundle {
  val rdata  = Input(UInt(32.W))
  val rlast  = Input(Bool())
  val rvalid = Input(Bool())
  val rready = Output(Bool())
}

class AXIAW extends Bundle {
  val awid    = Output(UInt(4.W))
  val awaddr  = Output(UInt(32.W))
  val awlen   = Output(UInt(8.W))
  val awsize  = Output(UInt(3.W))
  val awburst = Output(UInt(2.W))
  val awlock  = Output(UInt(2.W))
  val awcache = Output(UInt(4.W))
  val awprot  = Output(UInt(3.W))
  val awvalid = Output(Bool())
  val awready = Input(Bool())
}

class AXIAWVBReq extends Bundle {
  val awaddr  = Output(UInt(32.W))
  val awlen   = Output(UInt(8.W))
  val awsize  = Output(UInt(3.W))
  val awvalid = Output(Bool())
  val awready = Input(Bool())
}

class AXIW extends Bundle {
  val wid    = Output(UInt(4.W))
  val wdata  = Output(UInt(32.W))
  val wstrb  = Output(UInt(4.W))
  val wlast  = Output(Bool())
  val wvalid = Output(Bool())
  val wready = Input(Bool())
}

class AXIWVBReq extends Bundle {
  val wdata  = Output(UInt(32.W))
  val wstrb  = Output(UInt(4.W))
  val wlast  = Output(Bool())
  val wvalid = Output(Bool())
  val wready = Input(Bool())
}

class AXIB extends Bundle {
  val bid    = Input(UInt(4.W))
  val bresp  = Input(UInt(2.W))
  val bvalid = Input(Bool())
  val bready = Output(Bool())
}

class AXIBVBRsp extends Bundle {
  val bvalid = Input(Bool())
  val bready = Output(Bool())
}

class AXIIO extends Bundle {
  val ar = new AXIAR
  val r  = new AXIR
  val aw = new AXIAW
  val w  = new AXIW
  val b  = new AXIB
}
