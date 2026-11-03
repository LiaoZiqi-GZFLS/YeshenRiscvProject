# gen_liteeth.py -- 生成 LiteEth MAC（PIO/SRAM 槽模式，对应主线 litex_liteeth 驱动）的 Verilog 黑盒。
# 用法：  <venv>/Scripts/python.exe sim/liteeth_gen/gen_liteeth.py
# 产物：  third_party/liteeth_mac/liteeth_mac_top.v  (+ .json 端口/CSR 摘要)
#
# ============================ 2026-10-06 第二版（关键修正）============================
# 第一版把 PHY 建成 `LiteEthPHYGMII(model=True)`，它内部是
#     self.comb += [cd_eth_rx.clk.eq(ClockSignal()), cd_eth_tx.clk.eq(ClockSignal())]
# ⇒ **整颗 MAC 只有一个时钟**（产物里就是 `assign eth_rx_clk = sys_clk;`）。
# 那对 RGMII 是**错的**：GMII 是 125MHz 一个字节，sys_clk 是 100MHz，直接采 rx_dv 既丢字节
# 又跨域。板上那层把 RGMII 转成 GMII 的模块（`rgmii_interface`）给出来的正是 `rgmii_clk`
# （125MHz，来自 PHY 的 RXC）域里的 8bit 流 ⇒ 必须让 MAC 的 eth_rx/eth_tx 跑在**它**上面，
# 并在 MAC 与 CPU（sys，100MHz）之间做 CDC。
#
# 这一版改用 **LiteEth 自己原生支持的那条路**：
#   · `LiteEthMAC(..., with_sys_datapath=True)` ⇒ `LiteEthMACCore` 把数据通路整体放 sys 域，
#     并在 PHY 那头自动插 `stream.ClockDomainCrossing(sys↔eth_tx/eth_rx)`（见 mac/core.py 的
#     add_cdc()：`if with_sys_datapath:` 分支，TX/RX 各一次，深度 = *_cdc_depth）。
#     ⇒ **CSR 与槽内存全部留在 sys（100MHz）域**，CPU 侧那条 AXI-Lite→Wishbone 适配器
#       **一行 CDC 都不用写**；跨域只剩 LiteEth 自己那段（它本来就是为此写的）。
#   · PHY 换成本文件下面的 `LiteEthPHYGMIIExt`：**不再用 LiteEthPHYGMII(model=...)**。
#     原版 `model=False` 会插 Xilinx 的 `BUFG`/`DDROutput`（Pango 上是 `GTP_CLKBUFG`/`GTP_ODDR`，
#     名字不同 ⇒ PDS 认不出）；`model=True` 又把两个域钉死在 sys 上（见上）。所以这里**只复用
#     LiteEth 的 GMII 收发两个小块**（纯移位/寄存器，无原语），CDR 由本文件自己建：
#     `cd_eth_rx.clk := clock_pads_rx`、`cd_eth_tx.clk := clock_pads_tx`，复位用
#     `AsyncResetSynchronizer`（通用三段同步器，非厂家原语）。
#   · 于是顶层的 `clock_pads_rx/tx` 变成**真正的输入时钟脚**（板上接 `rgmii_interface.rgmii_clk`）。
#
# 端口/地址（供板级 AXI-Lite→Wishbone 适配器与 DTS 使用）：
#   · wb_csr  (32bit, **word 寻址**) ← 驱动 `base`（DT 的 `mac` 窗口）。寄存器号 = 字节偏移>>2，
#     0x00..0x40 共 17 个，与 `litex_liteeth.c` 的 LITEETH_* 常量逐条对齐（见 .json 的 csrs 顺序）。
#   · bus_rx  (8bit, **byte 寻址**) ← DT 的 `buffer` 窗口前半（2 槽 × 0x800）
#   · bus_tx  (8bit, **byte 寻址**) ← `buffer` 窗口后半（偏移 +0x1000）
#     （`bus_*_adr[11]` 就是槽号选择，见产物 wishbone_interface_decoder*_slave_sel）
import json, os, sys
from migen import *
from migen.fhdl.verilog import convert
from litex.gen import LiteXModule
from litex.soc.interconnect import wishbone, csr_bus
from liteeth.phy.gmii import LiteEthPHYGMIITX, LiteEthPHYGMIIRX
from liteeth.mac import LiteEthMAC


class ResetSync(Module):
    """把 sys 域的复位搬到**目标时钟域**（异步置位 / 同步释放）。

    为什么不用 `AsyncResetSynchronizer`：那是 migen 的 `Special`，要平台插件（Xilinx/Altera…）
    才能 lower，`convert()` 这种无平台流程直接 `NotImplementedError`。这里自己写两拍同步链，
    纯通用逻辑、任何工具都能综合。语义与 LiteEth 原版一致：
      · `reset_in` 一高 ⇒ `reset_out` 组合立刻高（异步置位）；
      · `reset_in` 落 ⇒ 目标域里再数两拍才释放（同步释放，避开 removal 亚稳）。
    """
    def __init__(self, reset_in):
        # ★★★ 2026-10-07 板级定案的**真根因**（就这一行）：`reset_less=True` 不能省。
        #   `sr` 这个移位链**本身就在被它复位的那两个域里**（本模块被 `ClockDomainsRenamer("eth_rx"/"eth_tx")`
        #   包着）⇒ 若 `sr` 可复位，Migen 会给它生成 `if (eth_rx_rst) sr <= 0;`，而
        #       `eth_rx_rst = reset_in | ~(sr[0] & sr[1])`
        #   ⇒ **复位期间把自己清零 ⇒ 链永远填不满 ⇒ 复位永在**（死锁）。
        #   板上症状（m4/m6 实测）：`rxcHi=rxcLo=1`（时钟在跑）、PHY 把帧送进来（`rxBytes` 随主机灌包涨）、
        #   `tx_en` 也在动（`pads_*` 是 `reset_less` ⇒ 不受域复位影响），
        #   但 MAC 的 PHY 侧数据通路**全死**：收字节不存帧、`CRC/PREAMBLE_ERRORS=0`（没走到校验）、
        #   读槽器 `reader_level` 停在 2 永不回落、驱动 `READER_READY` 永不完成。
        #   LiteEth 原版用的是 `AsyncResetSynchronizer`（LiteX 的 Special，要平台原语，Pango 上没有）；
        #   自己写等价物时**必须**让同步链 reset-less（它的初值由 FPGA 配置保证为 0）—— 这是复位同步器的标准写法。
        sr = Signal(2, reset=0, reset_less=True)
        self.sync += sr.eq(Cat(~reset_in, sr[0]))
        self.reset_out = Signal()
        self.comb += self.reset_out.eq(reset_in | ~(sr[0] & sr[1]))


class LiteEthPHYGMIIExt(LiteXModule):
    """GMII PHY：**只保留 LiteEth 的收发逻辑，不带任何 CRG/原语**。

    与 `liteeth.phy.gmii.LiteEthPHYGMII` 的差别只有一处：原版在 `model=False` 时插
    `BUFG`/`DDROutput`（Xilinx 原语）、在 `model=True` 时把 cd_eth_rx/tx 接到当前时钟域。
    这里两样都不要 —— 两个域的 clk 由顶层从 `clock_pads_rx/tx` 驱动（真正的输入时钟脚）。
    """
    dw          = 8
    tx_clk_freq = 125e6
    rx_clk_freq = 125e6
    # 让 LiteEthMACCore 用我们这套行为（不设的话它自己也会默认 True/True，这里显式写清）
    with_preamble_crc = True
    with_padding      = True

    def __init__(self, pads):
        # ⚠️ 必须**显式给域名**：`ClockDomain()` 靠 migen 的 tracer 从源码行里抠变量名，
        #    在本机环境里抠不到（`ValueError: Cannot extract clock domain name from code`）
        #    —— 与本仓从未跑过生成器有关（产物当初是从兄弟工程复制的）。显式写名字最稳。
        self.cd_eth_rx = ClockDomain("eth_rx")
        self.cd_eth_tx = ClockDomain("eth_tx")
        self.tx = ClockDomainsRenamer("eth_tx")(LiteEthPHYGMIITX(pads))
        self.rx = ClockDomainsRenamer("eth_rx")(LiteEthPHYGMIIRX(pads))
        self.sink, self.source = self.tx.sink, self.rx.source


class LiteEthMacTop(LiteXModule):
    # ★★ 2026-10-07（RX 突发丢包）：`nrxslots` 2 → **4**。
    #   为什么：板上实测「主机**背靠背**发 50 个 UDP ⇒ 板子只收到 **+2**」（`rx_dropped=0`，
    #   MAC 在驱动之前就丢）；改成**带间隔**发 20 个 ⇒ **20/20**。收到的帧数 ≈ 槽数，
    #   即"MAC 只有 N 个 rx 槽，驱动来不及搬运时第 N+1 帧就丢"。⇒ 加槽直接换来突发容忍度。
    #   连带（必须同步，四处一起改，见 docs §19）：
    #     · `board/liteeth_wrap.v` 的 rx/tx 分界 `addr[12] → addr[13]`、`tgt_buf` 排除 dbg 窗；
    #     · `src/YeshenSocGlue.scala` 的 `ETH_BUF_MASK 0xFFFF_E000 → 0xFFFF_C000`（窗口 0x2000→0x4000）；
    #     · DTS 的 `litex,rx-slots = <4>` 与 buffer `reg` 尺寸 0x2000 → 0x3000。
    #       （驱动契约：`tx_base = buf_base + num_rx_slots * slot_size`，所以 DTS 一改 tx 就自动挪。）
    def __init__(self, nrxslots=4, ntxslots=2, rx_cdc_depth=2048, tx_cdc_depth=2048):
        # ---- GMII pads / PHY 侧时钟脚（顶层端口；板级接 `rgmii_interface`）----
        self.clock_pads = Record([("rx", 1), ("tx", 1), ("gtx", 1)])
        self.pads       = Record([("tx_data", 8), ("tx_en", 1),
                                  ("rx_data", 8), ("rx_dv", 1), ("rx_er", 1)])
        self.phy = LiteEthPHYGMIIExt(self.pads)
        # ⚠️ 两个 PHY 域的时钟 = 外部时钟脚（板上 = rgmii_interface 的 rgmii_clk）。
        self.comb += [
            self.phy.cd_eth_rx.clk.eq(self.clock_pads.rx),
            self.phy.cd_eth_tx.clk.eq(self.clock_pads.tx),
        ]
        # ⚠️ `ResetSignal("sys")` 必须先在**顶层**落成一个普通 Signal 再传进去：
        #    `ClockDomainsRenamer("eth_rx")` 会把模块里出现的 `_ResetSignal("sys")` **一起改名**
        #    成 "eth_rx" ⇒ 同步器的输入变成它自己的输出 ⇒ 组合环
        #    （第一版产物就是这样：`assign eth_rx_rst = eth_rx_rst | ...`）。
        #    落成 Signal 之后，重命名器就只认它是根普通线，不再动它。
        sys_rst = Signal()
        self.comb += sys_rst.eq(ResetSignal("sys"))
        self.submodules.rs_rx = ClockDomainsRenamer("eth_rx")(ResetSync(sys_rst))
        self.submodules.rs_tx = ClockDomainsRenamer("eth_tx")(ResetSync(sys_rst))
        self.comb += [
            self.phy.cd_eth_rx.rst.eq(self.rs_rx.reset_out),
            self.phy.cd_eth_tx.rst.eq(self.rs_tx.reset_out),
        ]
        # ★★ 2026-10-07（板级定案的第二个真根因）：`dw` **必须 ≥16**（我们取 32）。
        #   为什么：`with_sys_datapath=True` 时，sys 域数据通路是 **1 字节/拍**。
        #   sys = `soc_clk` = 100MHz ⇒ 生产速率 **100 MB/s**；而 GMII PHY 侧是 8bit@125MHz = **125 MB/s**。
        #   sys→eth_tx 的 CDC（`core_tx_cdc_cdc_source_valid = asyncfifo_readable`）**永远追不上**：
        #   一帧中途 FIFO 就饿空 ⇒ `pads_tx_en` 被打成 **≤4 拍的小碎块**（= 线上全是 runt，主机 NIC 全丢），
        #   而 RX 方向（快生产/慢消费）反而正常 —— 这正是板上 `txRunMax=4` / `rxRunMax=203` 的由来。
        #   取 `dw=32` ⇒ sys 域 4 字节/拍 = 400 MB/s ≫ 125 MB/s，FIFO 只填不空。
        #   依据（LiteEth 自己的生成器）：`liteeth/gen.py` 里
        #       `with_sys_datapath = data_width in [16, 32]`
        #   —— 官方只在 16/32 位数据宽度下才开 sys_datapath；`dw=8` + `with_sys_datapath=True`
        #   是**该库不会产出的组合**。LiteX 的 SoC 也正是用 `dw=32` 跑主线 `litex_liteeth` 驱动。
        #   ⚠️ 连带效应：`bus_rx`/`bus_tx` 从 8bit 字节寻址**变成 32bit 字寻址**（带 4bit sel），
        #      `board/liteeth_wrap.v` 的槽闸门随之改成"一次 32bit + wstrb 做字节使能"（反而更简单）。
        #      字节布局不变（槽跨距仍是 0x800 字节、rx 在前 tx 在后）⇒ DTS/driver 契约不变。
        self.mac = LiteEthMAC(phy=self.phy, dw=32, interface="wishbone",
                              nrxslots=nrxslots, ntxslots=ntxslots,
                              # ★★ `endianness` 必须 **little**（dw=8 时它是个 no-op，所以此前无关紧要）：
                              #   驱动是**按字节偏移** `memcpy_fromio/toio(rx_base + slot*size, buf, len)`
                              #   ⇒ 槽内存必须是"字节偏移 k = 帧第 k 字节"的自然布局。逐级推：
                              #     · TX：CPU 写字节 k → `wishbone.SRAM` 的 `sel[i]` 映射到**内存 lane i**
                              #       （`port.we[i].eq(...& bus.sel[i])`，小端 lane 约定）；
                              #       `endianness="little"` ⇒ 读槽器 `source.data = rd_data`（不反字节），
                              #       下行转换器（32→8）**先发 data[7:0]** ⇒ 线上第 0 字节 = lane 0 = 帧第 0 字节 ✓；
                              #       若取 "big"，读槽器做 `reverse_bytes` ⇒ 线上每组 4 字节**组内反序** ✗。
                              #     · RX：上行转换器把**先收到的**字节放进 `data[7:0]`；"little" 写内存不反字节
                              #       ⇒ lane 0 = 帧第 0 字节 ⇒ CPU 字节偏移 0 读到帧第 0 字节 ✓。
                              endianness="little",
                              with_sys_datapath=True,
                              rx_cdc_depth=rx_cdc_depth, tx_cdc_depth=tx_cdc_depth)
        # ---- CSR -> Wishbone 从口（word 寻址，32bit）----
        self.csrs = self.mac.get_csrs()
        self.csrbus = csr_bus.Interface(data_width=32, address_width=16)
        self.submodules.csrbank = csr_bus.CSRBank(self.csrs, address=0, bus=self.csrbus, paging=0x800)
        self.wb_csr = wishbone.Interface(data_width=32, addressing="word")
        self.submodules.wb2csr = wishbone.Wishbone2CSR(
            bus_wishbone = self.wb_csr,
            bus_csr      = self.csrbus,
        )
        # ---- 中断：writer/reader 的 ev_pending 或起来（LiteX 里 ethmac 的 IRQ 就是这个）----
        byname = {c.name: c for c in self.csrs}
        self.irq = Signal()
        self.comb += self.irq.eq(byname["sram_writer_ev_pending"].status |
                                 byname["sram_reader_ev_pending"].status)
        # ---- 槽口（Wishbone **从口**：CPU 经它 `memcpy_fromio(rx_base + slot*size)`）----
        self.wb_slot_rx = self.mac.bus_rx
        self.wb_slot_tx = self.mac.bus_tx


if __name__ == "__main__":
    top = LiteEthMacTop()
    ios = set()
    ios.add(top.irq)
    for r in [top.clock_pads, top.pads]:
        for f in r.flatten(): ios.add(f)
    def leaves(x):
        try:
            return [s for s in x.flatten() if isinstance(s, Signal)]
        except AttributeError:
            return [v for v in x.__dict__.values() if isinstance(v, Signal)]
    for bus in [top.wb_csr, top.wb_slot_rx, top.wb_slot_tx]:
        for sig in leaves(bus): ios.add(sig)
    out = "third_party/liteeth_mac/liteeth_mac_top.v"
    os.makedirs(os.path.dirname(out), exist_ok=True)
    convert(top, ios, name="liteeth_mac_top").write(out)
    summary = {
        "nrxslots": 4, "ntxslots": 2, "dw": 32,
        "with_sys_datapath": True,
        "rx_cdc_depth": 2048, "tx_cdc_depth": 2048,
        "csrs": [c.name for c in top.csrs],
        "csr_bank_bytes": 0x800,
        "wb_csr_bits": 32, "wb_addressing": "word",
        "wb_slot_bits": 32, "wb_slot_addressing": "word",
    }
    with open(out + ".json", "w") as f: json.dump(summary, f, indent=1)
    print("OK ->", out, os.path.getsize(out), "bytes")
    print("CSRs:", ", ".join(summary["csrs"])[:400])
