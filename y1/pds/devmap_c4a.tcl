# ============================================================================
# devmap_c4a.tcl -- **Y1-C4a（C4a.8 面积闸门）** 的 dev_map（资源 + DRC 预检）
#
# C4a.8 交付物（Task C4a.8，Step 2）。本文件由 y1/pds/devmap_c3.tcl **逐条照抄**改核而来，
# 器件行 / 源清单 / 约束 / compile 口径与 devmap_c3.tcl 的 `integrated` 模式**一字不差**
# （只换 mode 开关名、工程目录 tag、DONE 标记 —— 改一处要两处一起改）。
#
#   mode = integrated （默认）—— **集成 C4a 顶层**：板级 SoC 全套 + `y1/gen/NpuTop.v`
#        （C4a 起 `NpuTop` 内部已例化 `LayerSched`（`L_MAX=8`）→ `UnitExec`（**宽层多趟通路
#         WIDERUN** + 权置信箱按 `LAYER_ID` 投递 §4.4/§4.5 参数）→ **`MultiPassUnit`**（自带
#         `Conv3x3Slice` + **`PartialSumBuf`**（`C_out×8` 的 block RAM 部分和缓冲））→
#         FusionBuf / BypassExec(MaxPool/Resize/Add/Sigmoid) / DescFetch / HostRegs / DdrMaster）
#         ⇒ 得到"器件总量"并与 C3 权威读数（板级 + 权重信箱，`L=8`：LUT 72381.5 / FF 105282 /
#         APM 465 / DRM 32.5 / Dist.RAM 1767，见 y1/reports/c3_area.md §11.3）算 Δ。
#         源清单 / 器件行 / 约束 / compile 口径与 devmap_c3.tcl **一字不差**。
#   mode = nputop     —— 只 `add_design y1/gen/NpuTop.v` 的**独立 NPU**（无 CPU/以太网/DDR3 IP），
#         把"NPU(C4a) 自身增量"从板级常量里**分离**出来（含 MultiPassUnit/PartialSumBuf）。无约束。
#   mode = layersched —— 只 `add_design y1/gen/LayerSched.v`（★ `L_MAX=8`，其下 UnitExec/宽层多趟/
#         8×Conv3x3Slice/FusionBuf/旁路四单元/DescFetch 全在）的 **C4a 核心独立探针**。
#         权重装载口是顶层自由输入 ⇒ 工具不能把卷积数据通路常量折叠掉（与板级 NpuTop 不同）；
#         裸探针（顶层端口 > 400 当 IO pad）⇒ 预计以 IO 的 DeviceMap-2003/DRC-0018 中止，
#         资源取 `Mapping Summary` + `GTP_*` 行（M0 教训，同 C3）。
#
# ★ C4a 相对 C3 的新增结构（本 tcl 要测的就是这一档）：`PartialSumBuf.scala` 的 **block RAM
#   部分和缓冲** —— `C_out` 行 × 8 B，判据沿用 S5：`DRM` 用量增长 + `LUTs as dram`/`Adm-4088`
#   三样证据表明它**真在 DRM**（不在 FF / LUTRAM）。
#
# ---------------------------------------------------------------------------
# 【用法】（Windows 侧 pds_shell，工作目录必须是 D:/code/PDS/VexiiYeshenLinux）：
#
#   # (a) 集成 C4a 顶层（板级 SoC + NpuTop，默认）—— 给 DRM/CLMA/LUT/APM 全表
#   /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file \
#       D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_c4a.tcl \
#       > y1/pds/devmap_c4a.log 2>&1 ; echo "exit=$?"
#
#   # (a2) 补充：独立 NPU（无 SoC）
#   YESHENMINI_C4A_MODE=nputop /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file \
#       D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_c4a.tcl \
#       > y1/pds/devmap_c4a_nputop.log 2>&1 ; echo "exit=$?"
#
#   # (a3) 补充：C4a 核心（LayerSched，避开权重口的常量折叠）
#   YESHENMINI_C4A_MODE=layersched /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file \
#       D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_c4a.tcl \
#       > y1/pds/devmap_c4a_layersched.log 2>&1 ; echo "exit=$?"
#
#   # 取数（三样证据：DRM 用量 / Adm-4088 / LUTs as dram）
#   grep -nE "Device Utilization Summary" -A 14 y1/pds/devmap_c4a.log
#   grep -nE "Mapping Summary" -A 12 y1/pds/devmap_c4a.log
#   grep -cE "Adm-4088" y1/pds/devmap_c4a.log
#   grep -nE "LUTs as dram|DRC-0018|DeviceMap-2003|Program Error" y1/pds/devmap_c4a.log
#
# 【前置（必须已生成，否则 add_design 找不到文件）】
#   y1/gen/NpuTop.v        （含 LayerSched(L=8) + UnitExec 宽层多趟 + MultiPassUnit + PartialSumBuf；md5 记在报告里）
#   rtl/vexiiriscv/VexiiRiscv.v / rtl/YeshenSocGlue.v / rtl/DDR3Bridge.v / 板级 / DDR3 IP
#
# 【关键点】
#   · **不**出比特流、**不**跑 pnr、**不**碰板 —— 只 create_project -> add_design ->
#     compile -> synthesize -ads -> dev_map。
#   · `compile -verilog_standard SystemVerilog`（与 SoC 口径一致）。
#   · 工程目录按 mode 分开放，绝不与 SoC 基线 / 切片探针交叉。
#   · **M0 教训**：`dev_map` 若因 DRC 中止，则**不会**打印 `Device Utilization Summary`
#     ⇒ 此时资源数退回 `synthesize -ads` 的 `Mapping Summary` 与 `GTP_*` 行，并在报告里说清来源。
#
# 注：本文件的 puts 一律不写方括号（YeshenCore 踩过：puts 里的方括号会被 Tcl 当命令替换）。
# ============================================================================

set root "D:/code/PDS/VexiiYeshenLinux"

set mode "integrated"
if {[info exists env(YESHENMINI_C4A_MODE)]} { set mode $env(YESHENMINI_C4A_MODE) }

set board_dir "$root/board"
set rtl_dir   "$root/rtl"
# 200H 版 DDR3 IP（与 NaxYeshenLinux 上板跑通那份同源）。
set ip_dir    "$root/third_party/ddr3_ip_200h/ddr3_test"

puts "=== Y1-C4a C4a.8 dev_map：mode = $mode ==="

if {$mode eq "nputop"} {

    # ------------------------------------------------------------------
    # (a2) 独立 NPU（NpuTop 自包含 —— LayerSched/UnitExec/宽层多趟 MultiPassUnit/PartialSumBuf/
    #      HostRegs/DdrMaster 及其所有子块全在单文件里）。无板级顶层 ⇒ 无约束。
    # ------------------------------------------------------------------
    set project_name "pds_c4a_nputop"
    set project_dir  "$root/y1/pds/pds_c4a_nputop.000"
    set project_file "$project_dir/$project_name.pds"

    puts "=== 独立 NPU（y1/gen/NpuTop.v，含 LayerSched L_MAX=8 + 宽层多趟 + PartialSumBuf）dev_map，无板级约束 ==="
    puts "=== project = $project_file ==="

    if {[file exists $project_dir]} {
        file delete -force $project_dir
    }

    create_project $project_file -synthesize_tool 2 -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

    add_design "$root/y1/gen/NpuTop.v"

    puts "=== dev_map: compile ==="
    compile -verilog_standard SystemVerilog

    puts "=== dev_map: synthesize -ads ==="
    synthesize -ads

    # 同 C3：裸探针无板级顶层 ⇒ 若顶层端口 > 400 会触发 IO 的 DeviceMap-2003/DRC-0018，
    #   此时无 Device Utilization Summary，资源取 `Mapping Summary` + `GTP_*` 行（M0 教训）。
    puts "=== dev_map: dev_map（纯资源，无 IO 约束）==="
    dev_map

    puts "=== dev_map DONE（资源见 Device Utilization Summary；若无该段则取 Mapping Summary + GTP_* 行）==="
    puts "Y1_C4A_NPUTOP_DEVMAP_DONE"

} elseif {$mode eq "layersched"} {

    # ------------------------------------------------------------------
    # (a3) **C4a 核心独立度**：`y1/gen/LayerSched.v`（★ L_MAX=8，其下 UnitExec/宽层多趟
    #      MultiPassUnit/PartialSumBuf/8×Conv3x3Slice/FusionBuf/旁路四单元/DescFetch 全在）。
    #      `LayerSched` 的权重装载口是**顶层自由输入** ⇒ 工具**不能**把卷积数据通路常量折叠掉。
    #      裸探针（IO 数 > 400）⇒ 预计以 IO 的 DeviceMap-2003/DRC-0018 中止，
    #      资源取 `Mapping Summary`（M0 教训）。
    # ------------------------------------------------------------------
    set project_name "pds_c4a_layersched"
    set project_dir  "$root/y1/pds/pds_c4a_layersched.000"
    set project_file "$project_dir/$project_name.pds"

    puts "=== C4a 核心独立度（y1/gen/LayerSched.v，L_MAX=8 + 宽层多趟）dev_map，无板级约束 ==="
    puts "=== project = $project_file ==="

    if {[file exists $project_dir]} {
        file delete -force $project_dir
    }

    create_project $project_file -synthesize_tool 2 -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

    add_design "$root/y1/gen/LayerSched.v"

    puts "=== dev_map: compile ==="
    compile -verilog_standard SystemVerilog

    puts "=== dev_map: synthesize -ads ==="
    synthesize -ads

    puts "=== dev_map: dev_map（纯资源，裸探针 IO 超限属预期）==="
    dev_map

    puts "=== dev_map DONE（裸探针预计无 Device Utilization Summary；资源取 Mapping Summary + GTP_* 行）==="
    puts "Y1_C4A_LAYERSCHED_DEVMAP_DONE"

} else {

    # ------------------------------------------------------------------
    # (a) 集成 C4a 顶层：板级 SoC 全套 + y1/gen/NpuTop.v（含 C4a 宽层多趟 + PartialSumBuf）
    #     源清单 / 器件行 / 约束 / compile 口径与 devmap_c3.tcl 一字不差（只换工程目录 tag）。
    # ------------------------------------------------------------------
    set period "10.000"
    if {[info exists env(YESHENMINI_DEVMAP_PERIOD)]} { set period $env(YESHENMINI_DEVMAP_PERIOD) }

    set project_name "yeshenmini_devmap_c4a"
    set project_dir  "$root/sim/reglogs/pds_devmap_c4a_p${period}"
    set project_file "$project_dir/$project_name.pds"

    puts "=== 集成 C4a 顶层（板级 SoC + NpuTop(LayerSched L_MAX=8 + 宽层多趟 + PartialSumBuf)）dev_map：period = $period ns ==="
    puts "=== project = $project_file ==="

    if {[file exists $project_dir]} {
        file delete -force $project_dir
    }

    create_project $project_file -synthesize_tool 2 -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

    # ---- 板级顶层（top_module）----
    add_design "$board_dir/yeshen_mini_board_top.v"

    # ---- 板级组装层 + PLL ----
    add_design "$board_dir/yeshen_mini_soc.v"
    add_design "$board_dir/pll_100m_125m.v"
    add_design "$board_dir/pll_50m.v"

    # ---- LiteEth 网卡：适配器层 + 生成的 MAC 黑盒 + 厂家 RGMII PHY 层 ----
    add_design "$board_dir/liteeth_wrap.v"
    add_design "$root/third_party/liteeth_mac/liteeth_mac_top.v"
    add_design "$root/third_party/eth_stack_2_11/source/rgmii_interface.v"

    # ---- 本项目的 RTL：核网表（VexiiRiscv）+ 胶合块（YeshenSocGlue）+ 内存桥（DDR3Bridge）----
    add_design "$rtl_dir/vexiiriscv/VexiiRiscv.v"
    add_design "$rtl_dir/YeshenSocGlue.v"
    add_design "$rtl_dir/DDR3Bridge.v"

    # ---- Y1 NPU 网表（C4a 起 = NpuTop + LayerSched(L=8) + UnitExec(宽层多趟) + MultiPassUnit +
    #      PartialSumBuf + 8xConv3x3Slice + FusionBuf + 旁路四单元 + DescFetch 等；全在单文件里）----
    add_design "$root/y1/gen/NpuTop.v"

    # ---- Y1 DMA 引擎网表（Y1-DMA Phase-2b：多通道通用 DMA 引擎，跑 cpu_clk，板级兄弟例化）----
    add_design "$root/y1/gen/DmaEngine.v"

    # ---- N5b：NPU 独立时钟域的三座异步桥 + 复位同步器（Verilog 网表，在板级 SoC 内例化）----
    add_design "$root/y1/gen/NpuAxiLiteCdc.v"
    add_design "$root/y1/gen/NpuMemCdc.v"
    add_design "$root/y1/gen/NpuIrqCdc.v"
    add_design "$root/y1/gen/NpuResetSync.v"

    # ---- 紫光同创 DDR3 IP（源文件清单照 pds/devmap_c3.tcl）----
    add_design "$ip_dir/ddr3_test.idf"
    add_design "$ip_dir/ddr3_test.v"
    add_design "$ip_dir/ddr3_test_ddrphy_top.v"
    add_design "$ip_dir/rtl/ips2l_rst_sync_v1_3.vp"
    foreach f [glob -nocomplain "$ip_dir/rtl/ddrphy/*.vp"]   { add_design $f }
    foreach f [glob -nocomplain "$ip_dir/rtl/ddrphy/*.v"]    { add_design $f }
    foreach f [glob -nocomplain "$ip_dir/rtl/mcdq_ctrl/*.vp"] { add_design $f }
    foreach f [glob -nocomplain "$ip_dir/rtl/mcdq_ctrl/*.v"]  { add_design $f }
    foreach f [glob -nocomplain "$ip_dir/rtl/pll/*.vp"]      { add_design $f }

    # ---- 约束（引脚 + 时钟 + CPD 落点，全在 constraints/yeshen_mini.fdc 里）----
    add_constraint "$root/constraints/yeshen_mini.fdc"

    puts "=== dev_map: compile ==="
    compile -verilog_standard SystemVerilog

    puts "=== dev_map: synthesize -ads ==="
    synthesize -ads

    puts "=== dev_map: dev_map（资源 + DRC）==="
    dev_map -override_pcf false

    puts "=== dev_map DONE（资源见 Device Utilization Summary；DRC 见 DRC-xxxx 行）==="
    puts "Y1_C4A_INTEGRATED_DEVMAP_DONE"
}

puts "YESHENMINI_C4A_DEVMAP_DONE"
