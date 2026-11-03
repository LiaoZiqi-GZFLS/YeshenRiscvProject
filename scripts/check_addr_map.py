#!/usr/bin/env python3
"""地址台账一致性：装载表(tb) = DTS = OpenSBI config = 本脚本常量。任何一处不同就非零退出。

用法：
    python3 scripts/check_addr_map.py          # 全绿则打印 PASS 并以 0 退出
    python3 scripts/check_addr_map.py -v       # 额外打印每一条的出处

设计口径（Task 9）：
  * 本文件 **常量表 EXPECT 是唯一的"台账"**，其余四处（OpenSBI config.mk、tb 装载表、
    胶合块 `src/*Glue.scala`、DTS）都只是**消费方**，必须与它逐字相等。
    （⚠️ 板级顶层 `board/yeshen_mini_soc.v` **不是**消费方：它一个常量都没写，
      外设窗全在胶合里解码，板级只把 `io_npuAxi_*` 这类从口接出去 ⇒ 无可对账的字面量。）
  * 一处对不上就**非零退出**，并且把"是哪个文件、写到多少、台账要多少"原文打出来 ——
    这类漂移最怕"静默通过"。
  * 只做**静态文本对账**（故意不解析 ELF/DTB）：判据要的是"写下来的字面量一致"，
    而不是"编译后可能恰好一致"。文本匹配失败要**报红**，不许降级为警告。

Task 21 新增（第 4 节）：
  * 把 **buildroot 外部树的 DTS**（`sw/buildroot-external/boards/naxmini/linux/linux_raw.dts`）
    纳入对账：`linux,initrd-start` / `memory@` 基址 / `serial@f0001000` 的 `reg` 基址。
  * ⚠️ 这份 DTS 由**另一个并行任务**创建 ⇒ **文件存在才查，不存在就 SKIP**（打印 SKIP、
    **不影响退出码**）。绝不能让"还没落地"把回归搞红。
  * 自证/演练用：`LEDGER_DTS=<路径>` 可以覆盖默认路径（文件还没落地时也能验证本检查
    真的会红/会绿）。不设该变量时行为与上面那条完全一致。

Y1-C2.2c 新增（NPU 并入 SoC 的收口）：
  * `NPU_BASE = 0xF000_C000`（16 KiB 寄存器窗）+ `NPU_IRQ_BIT = 3`（PLIC 源 3）+ `PLIC_NDEV = 3`。
  * 承载者只有三处，**刻意不**往别处塞：
    · `src/YeshenSocGlue.scala`（`NPU_BASE` / `NPU_IRQ_BIT`，同 CONSOLE_BASE/CLINT_BASE 一姿）；
    · `src/peripheral/PlicAlite.scala`（`val NDEV`）；
    · DTS（`npu@` 节点的 `reg` 与 `interrupts`、`riscv,ndev`）。
  * **不属于**本台账的：OpenSBI `config.mk` 与 tb 的 `SOC_PROG` 名字表只装**内存**镜像
    （fw_jump / Image / FDT），NPU 是**外设**窗 ⇒ 往那里塞一个外设地址只会变成"没人读的装饰"；
    `board/yeshen_mini_soc.v` 一个常量都没写（窗在胶合里解）⇒ 同样无承载。

Y1-DMA Phase-2b 新增（DMA 引擎并入 SoC 的收口）：
  * `DMA_BASE = 0xF000_6000`（**256 B** CSR 窗）+ `DMA_IRQ_BIT = 4`（PLIC 源 4）+ `PLIC_NDEV = 4`。
  * **记一个 site**（`check_dma_window()`）：把"窗基址 + 源号"当**一对不可分**的台账条目
    —— 它的四处承载者（胶合 `DMA_BASE`/`DMA_IRQ_BIT`、DTS `dma@` 的 `reg`/`interrupts`）
    **同属一个新增硬件特征**（DMA 窗及其中断源），作为一个 site 记账（其余外设仍是"一项一 site"）。
  * 与 NPU 同理，OpenSBI `config.mk` 与 tb 装载表只装内存镜像 ⇒ **不含**本窗（外设窗）。
"""

import os
import re
import sys
import pathlib

# 输出**刻意用 ASCII**：本脚本会被 tee 进 sim/reglogs/*.log，而 Windows 控制台默认 codepage
# 会把中文输出变成乱码（UTF-8 的字节被按 GBK 解码）⇒ 取证日志不可读。注释保留中文即可。
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

# ============================================================================
# ★ 台账（唯一来源）。改这里之前先把 §4.3 的布局重新过一遍。
# ============================================================================
EXPECT = {
    "FW_TEXT_START":   0x8000_0000,   # = 复位 PC = OpenSBI 入口
    # ★ Y1-C4b H2b（2026-10-12）：memory@ 的基址与 Image 落点**从此不能再当成同一个数**
    #   —— H2 把 NPU arena [0x8040_0000, 0x8200_0000) 标成 reserved-memory/no-map 切出内核 RAM，
    #   配套把 Image/FDT/initrd 抬到保留区之上。故新增 MEM_BASE 单独承载「内核声明的 DRAM 起点」，
    #   原来那条 `check_dts_node("DTS memory@ base", ..., EXPECT["IMAGE"])` 改指 MEM_BASE。
    "MEM_BASE":        0x8040_0000,   # DTS memory@ 基址 = 内核声明的 DRAM 起点（≠ IMAGE）
    "IMAGE":           0x8200_0000,   # Linux Image 落点（= OpenSBI FW_JUMP_ADDR；4 MiB 对齐）
    "FDT":             0x82F8_0000,   # = OpenSBI FW_JUMP_FDT_ADDR（传给内核的 a1）
    "INITRD":          0x8300_0000,   # initramfs / cpio（initrd-end = 0x8380_0000）
    "CONSOLE_BASE":    0xF000_1000,
    "NPU_BASE":        0xF000_C000,   # Y1-C2.2c：NPU 寄存器窗（16 KiB，胶合块解码，掩码 0xFFFF_C000）
    "DMA_BASE":        0xF000_6000,   # Y1-DMA P2b：DMA 引擎 CSR 窗（256 B，胶合块解码，掩码 0xFFFF_FF00）
    "VIDEO_BASE":      0xF000_7400,   # 2026-10-19 V1-T6：VIDEO CSR 窗（1 KiB，胶合块解码，掩码 0xFFFF_FC00）
    "GPU_BASE":        0xF000_5000,   # 2026-10-31 GPU P1：GPU CSR 窗（4 KiB，胶合块解码，掩码 0xFFFF_F000）
    "CLINT_BASE":      0xF001_0000,
    # ---- 以下两项不是"地址"，但同样属于"硬件写下的字面量必须与消费方逐字相等" ----
    "NPU_IRQ_BIT":     3,             # NPU 在 PLIC 上的源号（板级 NpuTop.irq ⇒ 胶合 io.npuIrq）
    "DMA_IRQ_BIT":     4,             # DMA 在 PLIC 上的源号（板级 DmaEngine.irq ⇒ 胶合 io.dmaIrq）
    "PLIC_NDEV":       5,             # PlicAlite 的 NDEV（源 1..5，5=GT911 CTP）；DTS 的 riscv,ndev 必须相等
}

ROOT = pathlib.Path(__file__).resolve().parent.parent
VERBOSE = "-v" in sys.argv[1:] or "--verbose" in sys.argv[1:]
fails = []
oks = []
skips = []
warns = []


def check(name, path, pattern, want, note="", radix=0):
    """在 ROOT/path 里用 pattern 抓**第 1 个**捕获组，按 radix 解析成整数，与 want 比。

    radix=0 ⇒ Python 字面量（`0x80000000`）；radix=16 ⇒ Verilog 的 `32'hf0010000` 这类
    裸十六进制串（`int(x, 0)` 不认 `f0010000`，必须显式指定进制）。
    """
    p = ROOT / path
    if not p.exists():
        fails.append(f"{name}: file not found: {path}")
        return
    text = p.read_text(encoding="utf-8", errors="replace")
    m = re.search(pattern, text)
    if not m:
        fails.append(f"{name}: pattern not found in {path}: {pattern!r}")
        return
    try:
        got = int(m.group(1), radix)
    except ValueError:
        fails.append(f"{name}: {path} captured {m.group(1)!r}, not an integer (radix={radix})")
        return
    if got != want:
        fails.append(f"{name}: {path} has 0x{got:08X}, ledger requires 0x{want:08X}")
    else:
        oks.append(f"{name}: {path} = 0x{got:08X}{('  [' + note + ']') if note else ''}")


# ---------------------------------------------------------------------------
# 1) OpenSBI 平台 config.mk —— 复位 PC / 跳转目标 / 设备树地址
# ---------------------------------------------------------------------------
check("OpenSBI FW_TEXT_START", "sw/opensbi-platform/config.mk",
      r"FW_TEXT_START\s*=\s*(0x[0-9A-Fa-f]+)", EXPECT["FW_TEXT_START"],
      "= 复位 PC = OpenSBI 入口")
check("OpenSBI FW_JUMP_ADDR", "sw/opensbi-platform/config.mk",
      r"FW_JUMP_ADDR\s*=\s*(0x[0-9A-Fa-f]+)", EXPECT["IMAGE"],
      "fw_jump 跳 Linux Image 的落点")
check("OpenSBI FW_JUMP_FDT_ADDR", "sw/opensbi-platform/config.mk",
      r"FW_JUMP_FDT_ADDR\s*=\s*(0x[0-9A-Fa-f]+)", EXPECT["FDT"],
      "fw_jump 传给内核的 a1")

# ---------------------------------------------------------------------------
# 2) 仿真装置的装载表 —— SOC_PROG 的名字表（Task 12 起：Image/FDT/INITRD 都从这里取）
# ---------------------------------------------------------------------------
check("tb Image", "sim/tb_naxmini.cpp",
      r"Image\"\s*,\s*(0x[0-9A-Fa-f]+)u", EXPECT["IMAGE"],
      "tb 的 SOC_PROG 名字表")
check("tb FW_TEXT_START", "sim/tb_naxmini.cpp",
      r"FW_TEXT_START\"\s*,\s*(0x[0-9A-Fa-f]+)u", EXPECT["FW_TEXT_START"],
      "tb 的 SOC_PROG 名字表")

# ---------------------------------------------------------------------------
# 3) 我们自己写的胶合块 / 上游生成产物里的外设基址
#    —— CONSOLE_BASE / CLINT_BASE 这两个常量在 EXPECT 里出现过就必须有人认领，
#       否则它们只是"写在那里好看"的死常量。
# ---------------------------------------------------------------------------
check("glue CONSOLE_BASE", "src/NaxMiniGlue.scala",
      r"CONSOLE_BASE\s*=\s*(0x[0-9A-Fa-f]+)L", EXPECT["CONSOLE_BASE"],
      "NaxMiniGlue 的 pBus 解码窗（ns16550a, reg-shift=2）")
# 2026-10-08 修正：原检查指向 Nax 时代的 `rtl/NaxSocMini.v`（该文件在 Vexii 迁移后已不存在）→ 改指当前胶合的常量声明，
# 与上面 CONSOLE_BASE 那项同姿。⚠：这是"+真实承载者"+的修复，不是删检查。
check("glue CLINT_BASE", "src/YeshenSocGlue.scala",
      r"CLINT_BASE\s*=\s*(0x[0-9A-Fa-f]+)L", EXPECT["CLINT_BASE"],
      "YeshenSocGlue 的 CLINT 解码窗（Vexii 迁移后 CLINT 由胶合内的 ClintAlite 提供）")
# Y1-C2.2c（2026-10-08）：NPU 并入 SoC 后必须有人认领的三项。**注意**：NPU 窗是**外设**窗
# ⇒ 它不属于 OpenSBI `config.mk` / tb 装载表（那两处只装**内存**镜像：fw_jump/Image/FDT/initrd），
# 板级顶层（`board/yeshen_mini_soc.v`）也不解这个窗（窗在胶合里解，板级只把 `io_npuAxi_*` 接出去）
# ⇒ 这三项的真实承载者只有**胶合**、**PlicAlite** 与 **DTS** 三处。
check("glue NPU_BASE", "src/YeshenSocGlue.scala",
      r"NPU_BASE\s*=\s*(0x[0-9A-Fa-f]+)L", EXPECT["NPU_BASE"],
      "YeshenSocGlue 的 NPU 寄存器窗解码（16 KiB；下游 NpuTop 的 axilite 从口）")
# 2026-10-19 V1-T6：VIDEO 窗（摄像头/叠加寄存器）并入胶合。与 NPU/DMA 同理，它是**外设**窗
# ⇒ 承载者只有胶合（板级 Task 7 才把 io.videoAxi_* 接到 board/cam/video_regs.v，DTS 节点另案）。
check("glue GPU_BASE", "src/YeshenSocGlue.scala",
      r"GPU_BASE\s*=\s*(0x[0-9A-Fa-f]+)L", EXPECT["GPU_BASE"],
      "GPU CSR 窗（胶合块解码）")
check("glue VIDEO_BASE", "src/YeshenSocGlue.scala",
      r"VIDEO_BASE\s*=\s*(0x[0-9A-Fa-f]+)L", EXPECT["VIDEO_BASE"],
      "YeshenSocGlue 的 VIDEO 寄存器窗解码（1 KiB；0x7400 避开 0x5000/0x7000 探针）")
check("glue NPU_IRQ_BIT", "src/YeshenSocGlue.scala",
      r"NPU_IRQ_BIT\s*=\s*(\d+)", EXPECT["NPU_IRQ_BIT"],
      "NPU 的 PLIC 源号（板级把 NpuTop.irq 接进 io.npuIrq ⇒ 胶合内 PLIC 源 3）")
# ⚠️ 模式必须锚 `val `：本文件 §头部注释第 9 行也写着 `` `NDEV = 3` ``（**注释**），
#    只写 `NDEV\s*=` 会抓到那句注释 ⇒ 声明改了、注释没改时**假绿**。锚 `val ` 唯一指到第 68 行的声明。
check("PLIC NDEV", "src/peripheral/PlicAlite.scala",
      r"val NDEV\s*=\s*(\d+)", EXPECT["PLIC_NDEV"],
      "PlicAlite 的源数（1=控制台 ns16550a / 2=LiteEth / 3=NPU / 4=DMA）")

# ---------------------------------------------------------------------------
# 4) buildroot 外部树的 DTS（Task 21；**存在则查、不存在则 SKIP**）
#    —— 该文件由另一个并行任务创建；SKIP 不算红，但也**不假装通过**（单独一行打印）。
#    每个基址都接受 DTS 里的两种常见写法：节点名里带基址（`memory@80400000`），
#    或 `reg = <0x0 0x80400000 ...>` 的地址首格（64bit 的高位 0 格可有可无）。
# ---------------------------------------------------------------------------
DTS_DEFAULT = "sw/buildroot-external/boards/naxmini/linux/linux_raw.dts"
DTS_PATH = os.environ.get("LEDGER_DTS") or DTS_DEFAULT   # LEDGER_DTS 仅用于演练本检查
DTS_EXISTS = (ROOT / DTS_PATH).exists()
if not DTS_EXISTS:
    skips.append(f"DTS checks SKIPPED: {DTS_PATH} 不存在（并行任务未落地）"
                 f" ⇒ 本轮只查 OpenSBI config.mk / tb 装载表 / 胶合块；"
                 f"文件落地后自动生效（演练：LEDGER_DTS=<路径>）")


def check_any(name, path, sites, want, note=""):
    """sites = [(正则, 进制), ...]：**任意一处**抓到 want 即通过；一处都没有则报红。

    用于 DTS 的**属性**（如 `linux,initrd-start = <0x83000000>`）：写法可能有 1 格/2 格
    （64bit 高位 0 格）两种，这里都收；但**抓到值不等于台账依然算红**（不许静默降级）。
    """
    p = ROOT / path
    if not p.exists():
        return
    text = p.read_text(encoding="utf-8", errors="replace")
    others = []
    for pattern, radix in sites:
        for m in re.finditer(pattern, text):
            got = int(m.group(1), radix)
            if got == want:
                oks.append(f"{name}: {path} = 0x{got:08X}{('  [' + note + ']') if note else ''}")
                return
            others.append(f"0x{got:08X}")
    fails.append(f"{name}: {path} 里没有任何一处等于 0x{want:08X}"
                 f"（抓到的是 {', '.join(others) if others else '空（正则全都没匹配上）'}）")


def check_dts_node(name, path, tag, node_pat, want, note=""):
    """DTS **节点**的基址对账：`reg` 首格是**权威**（语义上决定地址的就是它），
    节点名的单元地址只作 fallback（节点没有 reg 时）。

    * `reg` 首格 != 台账 ⇒ **红**（这一条正是"串口/内存落点漂了"的现场）。
    * 节点名单元地址 != 自己的 `reg` 首格 ⇒ **WARN**（dtc 自己也会告警）：不改变退出码，
      但常驻打印（"名字写一个数、reg 写另一个数"必须被看见）。
    """
    p = ROOT / path
    if not p.exists():
        return
    text = p.read_text(encoding="utf-8", errors="replace")
    nodes = list(re.finditer(node_pat, text))
    if not nodes:
        fails.append(f"{name}: {path} 里找不到 {tag}@<addr> 节点")
        return
    for m in nodes:
        unit = int(m.group(1), 16)
        r = re.search(r"reg\s*=\s*<\s*(?:0x0+\s+)?(0x[0-9A-Fa-f]+)", m.group(2))
        if r is None:
            if unit != want:
                fails.append(f"{name}: {path} {tag}@{m.group(1)} 无 reg，"
                             f"节点名单元地址 = 0x{unit:08X}，台账要求 0x{want:08X}")
            else:
                oks.append(f"{name}: {path} {tag}@<addr> 节点名单元地址 = 0x{unit:08X}"
                           f"{('  [' + note + ']') if note else ''}")
            continue
        base = int(r.group(1), 0)
        if base != want:
            fails.append(f"{name}: {path} {tag}@{m.group(1)} 的 reg 首格 = 0x{base:08X}，"
                         f"台账要求 0x{want:08X}")
            continue
        oks.append(f"{name}: {path} {tag}@{m.group(1)} 的 reg 首格 = 0x{base:08X}"
                   f"{('  [' + note + ']') if note else ''}")
        if unit != base:
            warns.append(f"{name}: {path} {tag}@{m.group(1)} 节点名单元地址 = 0x{unit:08X} "
                         f"≠ 自己的 reg 首格 = 0x{base:08X}（dtc 会告警；台账只认 reg 首格 "
                         f"⇒ 不影响退出码，但请把节点名对齐写法）")


if DTS_EXISTS:
    # 4.1 initrd 落点（= tb/SOC_PROG 的 INITRD；Linux 取 initrd 的地址）
    check_any("DTS linux,initrd-start", DTS_PATH,
              [(r"linux,initrd-start\s*=\s*<\s*(?:0x0+\s+)?(0x[0-9A-Fa-f]+)", 0)],
              EXPECT["INITRD"], "= fw_jump/Linux 的 initrd 落点")
    # 4.2 memory 节点基址（= MEM_BASE 0x8040_0000；注意**不是** 0x8000_0000，也**不再** = IMAGE）
    check_dts_node("DTS memory@ base", DTS_PATH, "memory",
                   r"memory@([0-9A-Fa-f]{1,8})\s*\{([^}]*)\}",
                   EXPECT["MEM_BASE"], "= DRAM 的 Linux 可见起点（内核声明的 DRAM 窗，非 Image 落点）")
    # 4.3 串口节点基址（= CONSOLE_BASE 0xF000_1000）
    check_dts_node("DTS serial@ base", DTS_PATH, "serial",
                   r"serial@([0-9A-Fa-f]{1,8})\s*\{([^}]*)\}",
                   EXPECT["CONSOLE_BASE"], "= ns16550a 的控制台基址（reg-shift=2）")
    # 4.4 NPU 寄存器窗（= NPU_BASE 0xF000_C000；Y1-C2.2c 新增节点）
    check_dts_node("DTS npu@ base", DTS_PATH, "npu",
                   r"npu@([0-9A-Fa-f]{1,8})\s*\{([^}]*)\}",
                   EXPECT["NPU_BASE"], "= NPU 寄存器窗（16 KiB，胶合块按 0xFFFF_C000 解码）")
    # 4.5 PLIC：源数（riscv,ndev）与 NPU 的源号（npu 节点的 interrupts）。
    #     —— 这是"PLIC 源号必须与硬件一致"这条口径最小的一对可对账项（原来的台账一条都没有）。
    check("DTS riscv,ndev", DTS_PATH,
          r"riscv,ndev\s*=\s*<(\d+)>", EXPECT["PLIC_NDEV"],
          "PLIC 源数必须 = PlicAlite 的 NDEV（写大了 Linux 会去读写不存在的 enable 位）")
    check("DTS npu interrupts", DTS_PATH,
          r"npu@[0-9A-Fa-f]+\s*\{[^}]*?interrupts\s*=\s*<(\d+)>", EXPECT["NPU_IRQ_BIT"],
          "NPU 的 PLIC 源号必须 = 胶合 NPU_IRQ_BIT（源 1=控制台 / 2=LiteEth / 3=NPU）")
    # 4.6 ★ 2026-10-29：软件复位的 register offset（DTS reboot.offset ↔ video_regs.A_RSTCTRL）
    #     "内核写哪个偏移"与"RTL 认哪个偏移"之间**只有这一根线**：写错 = 静默重启失败
    #     （界面表现为 `reboot` 之后板子照常跑，或内核卡在 machine_restart 死等）。
    _vr = ROOT / "board/cam/video_regs.v"
    if _vr.exists():
        _vrt = _vr.read_text(encoding="utf-8", errors="replace")
        _m = re.search(r"A_RSTCTRL\s*=\s*12'h([0-9A-Fa-f]{3})", _vrt)
        if not _m:
            fails.append("DTS reboot offset: board/cam/video_regs.v 里找不到 A_RSTCTRL = 12'hXXX")
        else:
            _want = int(_m.group(1), 16)
            _dt = (ROOT / DTS_PATH).read_text(encoding="utf-8", errors="replace")
            _r = re.search(r'compatible\s*=\s*"syscon-reboot"[^}]*?offset\s*=\s*<'
                           r'(0x[0-9A-Fa-f]+|\d+)>', _dt)
            if not _r:
                fails.append("DTS reboot offset: 找不到 syscon-reboot 节点的 offset 属性")
            elif int(_r.group(1), 0) != _want:
                fails.append(f"DTS reboot offset = {_r.group(1)} ≠ "
                             f"video_regs.A_RSTCTRL = 0x{_want:03X}")
            else:
                oks.append(f"DTS reboot offset: = video_regs.A_RSTCTRL = 0x{_want:03X}"
                           f"  [syscon-reboot 写这个偏移触发整片 SoC 复位]")
    # 4.7 reboot 的 regmap 载体 = VIDEO 窗（1 KiB；与胶合 VIDEO_BASE 同源）
    check_dts_node("DTS syscon@ base", DTS_PATH, "syscon",
                   r"syscon@([0-9A-Fa-f]{1,8})\s*\{([^}]*)\}",
                   EXPECT["VIDEO_BASE"],
                   "= VIDEO CSR 窗（reboot 的 regmap 载体，偏移 0x098 = RST_CTRL）")

# ---------------------------------------------------------------------------
# 5) ★ Y1-DMA Phase-2b：**DMA 寄存器窗（窗基址 + PLIC 源 4）** —— 记 **1 个 site**
#    口径：把"窗基址 + 源号"当**一对不可分**的台账条目（它的 DTS 节点把两者写在一起），
#    四处承载者一并核对，任一处漂移即红；全绿才 +1 site。
#      · `src/YeshenSocGlue.scala` 的 `DMA_BASE` / `DMA_IRQ_BIT`（RTL 里真正解码窗、接源的地方）；
#      · DTS `dma@` 节点的 `reg` 首格 / `interrupts`（DTS 存在才查，与上面第 4 节同口径）。
#    ⚠️ OpenSBI `config.mk` 与 tb 的 `SOC_PROG` 只装**内存**镜像 ⇒ **不含**本窗（外设窗），
#      与 NPU 同理（不是"漏了"，是"不适用"）。
# ---------------------------------------------------------------------------
def check_dma_window_site():
    subs = []   # 通过的子项（全绿才记账）
    p = ROOT / "src/YeshenSocGlue.scala"
    if not p.exists():
        fails.append("DMA window: file not found: src/YeshenSocGlue.scala")
        return
    text = p.read_text(encoding="utf-8", errors="replace")
    m = re.search(r"DMA_BASE\s*=\s*(0x[0-9A-Fa-f]+)L", text)
    if not m:
        fails.append("DMA window: pattern not found: DMA_BASE in src/YeshenSocGlue.scala")
    elif int(m.group(1), 0) != EXPECT["DMA_BASE"]:
        fails.append(f"DMA window: glue DMA_BASE = {m.group(1)}, 台账要求 0x{EXPECT['DMA_BASE']:08X}")
    else:
        subs.append(f"glue DMA_BASE=0x{EXPECT['DMA_BASE']:08X}")
    m = re.search(r"DMA_IRQ_BIT\s*=\s*(\d+)", text)
    if not m:
        fails.append("DMA window: pattern not found: DMA_IRQ_BIT in src/YeshenSocGlue.scala")
    elif int(m.group(1)) != EXPECT["DMA_IRQ_BIT"]:
        fails.append(f"DMA window: glue DMA_IRQ_BIT = {m.group(1)}, 台账要求 {EXPECT['DMA_IRQ_BIT']}")
    else:
        subs.append(f"glue DMA_IRQ_BIT={EXPECT['DMA_IRQ_BIT']}")
    want = 2
    if DTS_EXISTS:
        want = 4
        dt = (ROOT / DTS_PATH).read_text(encoding="utf-8", errors="replace")
        nm = re.search(r"dma@([0-9A-Fa-f]{1,8})\s*\{([^}]*)\}", dt)
        if not nm:
            fails.append(f"DMA window: {DTS_PATH} 里找不到 dma@<addr> 节点")
        else:
            r = re.search(r"reg\s*=\s*<\s*(?:0x0+\s+)?(0x[0-9A-Fa-f]+)", nm.group(2))
            if r is None or int(r.group(1), 0) != EXPECT["DMA_BASE"]:
                fails.append(f"DMA window: DTS dma@{nm.group(1)} 的 reg 首格 = "
                             f"{(r.group(1) if r else '无')}, 台账要求 0x{EXPECT['DMA_BASE']:08X}")
            else:
                subs.append(f"DTS dma@ reg=0x{EXPECT['DMA_BASE']:08X}")
            ir = re.search(r"interrupts\s*=\s*<(\d+)>", nm.group(2))
            if ir is None or int(ir.group(1)) != EXPECT["DMA_IRQ_BIT"]:
                fails.append(f"DMA window: DTS dma@ 的 interrupts = "
                             f"{(ir.group(1) if ir else '无')}, 台账要求 {EXPECT['DMA_IRQ_BIT']}")
            else:
                subs.append(f"DTS dma@ interrupts={EXPECT['DMA_IRQ_BIT']}")
    if len(subs) == want:
        oks.append("DMA window (glue+dts): " + ", ".join(subs)
                   + "  [= DMA CSR 窗 256 B + PLIC 源 4]")


check_dma_window_site()

if VERBOSE:
    for line in oks:
        print("  ok:", line)

for w in warns:
    print("WARN:", w)

if fails:
    print("FAIL: address ledger mismatch")
    for f in fails:
        print("  -", f)
    sys.exit(1)

for s in skips:
    print("SKIP:", s)

print(f"PASS: address ledger consistent ({len(oks)} sites reconciled"
      f"{', ' + str(len(skips)) + ' skipped' if skips else ''}"
      f"{', ' + str(len(warns)) + ' warning(s)' if warns else ''})")
