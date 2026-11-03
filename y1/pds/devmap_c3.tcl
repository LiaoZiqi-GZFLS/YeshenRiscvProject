# ============================================================================
# devmap_c3.tcl -- **Y1-C3（S5 面积闸门）** 的 dev_map（资源 + DRC 预检）
#
# C3.13 交付物。本文件由 y1/pds/devmap_soc_npu.tcl（板级 SoC+NPU）与
# y1/pds/devmap_slice.tcl（独立资源探针）**逐条照抄**改核而来，只加一个**模式开关**，
# 让同一份 tcl 覆盖 S5 要求的两次（+1 次补充）测量：
#
#   mode = integrated （默认）—— **集成 C3 顶层**：板级 SoC 全套 + `y1/gen/NpuTop.v`
#        （C3.12 起 `NpuTop` 内部已例化 `LayerSched`（★ A-3 起 `L_MAX=8`，其下 `UnitExec` /
#         8×`Conv3x3Slice` / `FusionBuf` / `BypassExec`(MaxPool/Resize/Add/Sigmoid) /
#         `DescFetch` / `HostRegs` / `DdrMaster` 全在里面））⇒ 得到"器件总量"与 S5 第 1 条
#         的"集成总量 ≤ 415 DRM"，并与 C2 基线（SoC+NPU，LUT 14370.5 / FF 17187 /
#         APM 4 / DRM 24.5，见 y1/reports/c2_ddr_master.md §6a）算 Δ。
#         源清单 / 器件行 / 约束 / compile 口径与 devmap_soc_npu.tcl **一字不差**。
#   mode = fusionbuf  —— **孤立 `FusionBuf` 最坏形状**：只 `add_design y1/gen/worst/FusionBuf.v`
#         （同一份 `rtl/FusionBuf.scala` 源码，只差展开期常量 `C=64, WIDTH=160`）
#         ⇒ 3 行窗口 = 3 * 64 * 160 = 30,720 B = **7 个 DRM36K**（C3.0 承重条件）。
#         无板级约束（纯资源探针，不造假引脚）。这条**只**证"S5 第 1/2 条：3 行窗口真的落 DRM"。
#   mode = nputop     —— （补充，非 S5 必需）只 `add_design y1/gen/NpuTop.v` 的**独立 NPU**
#         （无 CPU/以太网/DDR3 IP）。用来把"NPU(C3) 自身的增量"从板级常量里**分离**出来，
#         与板级 `integrated` 一起给"NPU 增量"两块独立读数。无约束。
#
# 为什么 isolated FusionBuf 必须单独跑：集成顶层里 `LayerSched` 用的 `FusionBuf` 是
#   **功能档** `(C=8, WIDTH=32)`（3 行 = 768 B）—— 它**不会**出现 7 块 DRM。S5 要证明的是
#   **最坏单元**那一档（`C=64, WIDTH=160`）的结构本身能被推断成块 RAM，必须拿那一档单独跑。
#
# ---------------------------------------------------------------------------
# 【用法】（Windows 侧 pds_shell，工作目录必须是 D:/code/PDS/VexiiYeshenLinux）：
#
#   # (a) 集成 C3 顶层（板级 SoC + NpuTop）
#   /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file \
#       D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_c3.tcl \
#       > y1/pds/devmap_c3.log 2>&1 ; echo "exit=$?"
#
#   # (b) 孤立 FusionBuf 最坏形状（C=64, WIDTH=160）
#   YESHENMINI_C3_MODE=fusionbuf /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file \
#       D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_c3.tcl \
#       > y1/pds/devmap_c3_fusionbuf.log 2>&1 ; echo "exit=$?"
#
#   # (c) 补充：独立 NPU（无 SoC）
#   YESHENMINI_C3_MODE=nputop /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file \
#       D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_c3.tcl \
#       > y1/pds/devmap_c3_nputop.log 2>&1 ; echo "exit=$?"
#
#   # 取数（三样证据：DRM 用量 / Adm-4088 / LUTs as dram）
#   grep -nE "Device Utilization Summary" -A 14 y1/pds/devmap_c3.log
#   grep -nE "Mapping Summary" -A 12 y1/pds/devmap_c3.log
#   grep -cE "Adm-4088" y1/pds/devmap_c3.log
#   grep -nE "LUTs as dram|DRC-0018|DeviceMap-2003|Program Error" y1/pds/devmap_c3.log
#
# 【前置（必须已生成，否则 add_design 找不到文件）】
#   y1/gen/NpuTop.v          （含 LayerSched 全套；md5 记在报告里）
#   y1/gen/worst/FusionBuf.v （C=64, WIDTH=160；md5 记在报告里）
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
if {[info exists env(YESHENMINI_C3_MODE)]} { set mode $env(YESHENMINI_C3_MODE) }

set board_dir "$root/board"
set rtl_dir   "$root/rtl"
# 200H 版 DDR3 IP（与 NaxYeshenLinux 上板跑通那份同源）。
set ip_dir    "$root/third_party/ddr3_ip_200h/ddr3_test"

puts "=== Y1-C3 S5 dev_map：mode = $mode ==="

if {$mode eq "fusionbuf"} {

    # ------------------------------------------------------------------
    # (b) 孤立 FusionBuf 最坏形状：C=64, WIDTH=160（3 行 = 30,720 B = 7 DRM36K）
    #     纯资源探针：**只有**这一个源文件，无板级顶层 ⇒ 无约束（不造假引脚 FDC）。
    # ------------------------------------------------------------------
    set project_name "pds_c3_fusionbuf"
    set project_dir  "$root/y1/pds/pds_c3_fusionbuf.000"
    set project_file "$project_dir/$project_name.pds"

    puts "=== 孤立 FusionBuf（worst: C=64 WIDTH=160，3 行 = 30720 B）dev_map，无板级约束 ==="
    puts "=== project = $project_file ==="

    if {[file exists $project_dir]} {
        file delete -force $project_dir
    }

    create_project $project_file -synthesize_tool 2 -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

    add_design "$root/y1/gen/worst/FusionBuf.v"

    puts "=== dev_map: compile ==="
    compile -verilog_standard SystemVerilog

    puts "=== dev_map: synthesize -ads ==="
    synthesize -ads

    # 注：裸探针（无板级顶层）会把**全部端口**当 IO pad ⇒ FusionBuf(C=64) 的 1078 个 IO
    #   > FBB676 的 400 个用户 IO ⇒ `dev_map` 以 `DeviceMap-2003`+`DRC-0018`（**IO**）中止，
    #   **不打印** `Device Utilization Summary`（这正是 M0 教训那一幕）。
    #   试过 PDS 2025.2 文档化的 `dev_map -not_check_io_rule_option TRUE` —— 它被翻成
    #   `set_option ... [get_actions dev_map -of_objects [get_tasks pnr_1]]`（挂在 **pnr** 任务的
    #   dev_map 动作上），**没有**抑制本流程的 `DeviceMap-2003` ⇒ 不改结局（如实记）。
    #   ⇒ 资源数按 M0 教训退回 **`synthesize -ads` 的 `Mapping Summary` + `GTP_*` 行**，并在报告里说清来源。
    #   这是探针的**形状产物**（没有板级顶层去复用/裁端口），与"DRM 到底落没落"无关。
    puts "=== dev_map: dev_map（纯资源；裸探针的 IO 数会触发 DeviceMap-2003/DRC-0018，属预期）==="
    dev_map

    puts "=== dev_map DONE（裸探针预计无 Device Utilization Summary；资源取 Mapping Summary + GTP_* 行）==="
    puts "Y1_C3_FUSIONBUF_DEVMAP_DONE"

} elseif {$mode eq "nputop"} {

    # ------------------------------------------------------------------
    # (c) 补充：独立 NPU（NpuTop 自包含 —— LayerSched/HostRegs/DdrMaster 及其所有子块全在单文件里）
    #     无板级顶层 ⇒ 无约束。
    # ------------------------------------------------------------------
    set project_name "pds_c3_nputop"
    set project_dir  "$root/y1/pds/pds_c3_nputop.000"
    set project_file "$project_dir/$project_name.pds"

    puts "=== 独立 NPU（y1/gen/NpuTop.v，含 LayerSched L_MAX=8 全套）dev_map，无板级约束 ==="
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

    # 同 fusionbuf 模式：裸探针无板级顶层 ⇒ 若顶层端口 > 400 会触发 IO 的 DeviceMap-2003/DRC-0018，
    #   此时无 Device Utilization Summary，资源取 `Mapping Summary` + `GTP_*` 行（M0 教训）。
    puts "=== dev_map: dev_map（纯资源，无 IO 约束）==="
    dev_map

    puts "=== dev_map DONE（资源见 Device Utilization Summary；若无该段则取 Mapping Summary + GTP_* 行）==="
    puts "Y1_C3_NPUTOP_DEVMAP_DONE"

} elseif {$mode eq "layersched"} {

    # ------------------------------------------------------------------
    # (a') **C3 核心独立度**：`y1/gen/LayerSched.v`（★ A-3 起 L_MAX=8，其下 UnitExec/8×Conv3x3Slice/
    #      FusionBuf/BypassExec/DescFetch/旁路四单元全在）。**这是"集成 C3 顶层"最干净的读数**：
    #      `LayerSched` 的四个权重装载口（`we/we_t/we2/we3` …）是**顶层自由输入** ⇒ 工具
    #      **不能**把卷积数据通路常量折叠掉（与板级 `NpuTop` 把权重口钉 0 的情形不同）。
    #      裸探针（IO 数 > 400）⇒ 预计以 IO 的 DeviceMap-2003/DRC-0018 中止，
    #      资源取 `Mapping Summary`（M0 教训）。
    # ------------------------------------------------------------------
    set project_name "pds_c3_layersched"
    set project_dir  "$root/y1/pds/pds_c3_layersched.000"
    set project_file "$project_dir/$project_name.pds"

    puts "=== C3 核心独立度（y1/gen/LayerSched.v，L_MAX=8）dev_map，无板级约束 ==="
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
    puts "Y1_C3_LAYERSCHED_DEVMAP_DONE"

} else {

    # ------------------------------------------------------------------
    # (a) 集成 C3 顶层：板级 SoC 全套 + y1/gen/NpuTop.v
    #     源清单 / 器件行 / 约束 / compile 口径与 devmap_soc_npu.tcl 一字不差（只换工程目录 tag）。
    # ------------------------------------------------------------------
    set period "10.000"
    if {[info exists env(YESHENMINI_DEVMAP_PERIOD)]} { set period $env(YESHENMINI_DEVMAP_PERIOD) }

    set project_name "yeshenmini_devmap_c3"
    set project_dir  "$root/sim/reglogs/pds_devmap_c3_p${period}"
    set project_file "$project_dir/$project_name.pds"

    puts "=== 集成 C3 顶层（板级 SoC + NpuTop(LayerSched L_MAX=8)）dev_map：period = $period ns ==="
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

    # ---- LiteEth 网卡：适配器层 + 生成的 MAC 黑盒 + 厂家 RGMII PHY 层 ----
    add_design "$board_dir/liteeth_wrap.v"
    add_design "$root/third_party/liteeth_mac/liteeth_mac_top.v"
    add_design "$root/third_party/eth_stack_2_11/source/rgmii_interface.v"

    # ---- 本项目的 RTL：核网表（VexiiRiscv）+ 胶合块（YeshenSocGlue）+ 内存桥（DDR3Bridge）----
    add_design "$rtl_dir/vexiiriscv/VexiiRiscv.v"
    add_design "$rtl_dir/YeshenSocGlue.v"
    add_design "$rtl_dir/DDR3Bridge.v"

    # ---- Y1 NPU 网表（C3.12 起 = NpuTop + LayerSched + UnitExec + FusionBuf + 旁路四单元 + DescFetch 等）----
    add_design "$root/y1/gen/NpuTop.v"

    # ---- 紫光同创 DDR3 IP（源文件清单照 pds/devmap_soc_npu.tcl）----
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
    puts "Y1_C3_INTEGRATED_DEVMAP_DONE"
}

puts "YESHENMINI_C3_DEVMAP_DONE"
