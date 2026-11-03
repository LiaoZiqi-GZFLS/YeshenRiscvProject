# ============================================================================
# devmap_n5b.tcl -- **Y1「NPU 独立时钟域」Task N5b** 的 dev_map 证据探针
#
# 本文件由 `y1/pds/devmap_n2b.tcl` **逐条照抄**改核而来（同为 integrated 模式）：
#   器件行 / 约束 / compile 口径**一字不差**，只换：工程目录 tag、DONE 标记；源清单在 N2b 基础上
#   **再加 4 份 N5b 集成进来的桥/复位同步器网表**（`y1/gen/NpuAxiLiteCdc.v` / `NpuMemCdc.v` /
#   `NpuIrqCdc.v` / `NpuResetSync.v`）。跑完 dev_map 后**不做任何 PnR / 不出比特流**（与 N5b 口径一致）。
#
# 【N5b 要读的样】
#   ① 约束检查（DRC）：`Found N error(s), …` + **0 error**；`create_clock {npu_clk}` 不被报 object
#      找不到。约束条数应与 N2b **相同**（N5b 一个约束都没加：`npu_clk` 早就是独立 create_clock）。
#   ② 时钟表（PDS 产物 `synthesize_report_timing_clock_summary.db`）：**cpu_clk 10.0000ns（100MHz）**
#      与 **npu_clk 20.0000ns（50.0000MHz）** 同时在列，且 **npu_clk 的 Type = `Declared`、Source 空**
#      （独立根钟）。★ 与 N2b 的关键差别：N2b 时 npu_clk 的 `Clock Load = 1`（只有防悬空的脚手架寄存器），
#      **N5b 起 Clock Load 变成整块 NpuTop 域的真实扇出**（NpuTop + 三桥 npu 侧 + NpuResetSync npu 域）
#      —— 这正是"npu_clk 现在有真功能负载、脚手架已删"的正面证据。
#   ③ device_map 的时钟网清单（`device_map_clock_signal.db`）：`u_pll_npu/u_gpll → u_npuclk_bufg →
#      npu_clk` 仍在，且 **Fanout 从 N2b 的 1 变成一个大数**（= 真负载）。
#
# 【用法】（Windows 侧 pds_shell，工作目录必须是 D:/code/PDS/VexiiYeshenLinux）：
#   /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file \
#       D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_n5b.tcl > y1/pds/devmap_n5b.log 2>&1 ; echo "exit=$?"
#   grep -nE "Found [0-9]+ error|CLOCK-SUMMARY|Device Utilization Summary" -A 3 y1/pds/devmap_n5b.log
#
# 【前置（必须已生成/已改）】
#   board/yeshen_mini_soc.v      （N5b：NpuTop 接 npu_clk + 三座桥 + NpuResetSync + 删脚手架）
#   board/yeshen_mini_board_top.v（N5b：删 npu_clk_alive 端口接线 + 诊断帧回到 8 字节）
#   board/pll_50m.v              （N2b 新增：第二颗 GTP_GPLL，N5b 一字未改）
#   constraints/yeshen_mini.fdc  （N2b：create_clock {npu_clk} 20ns + 异步组；N5b 一字未改）
#   y1/gen/NpuTop.v + y1/gen/Npu{AxiLite,Mem,Irq,Rst}*.v（N3/N4/N5 交付的桥/复位同步器网表）
#   其余源与 c4a 档完全一致（rtl/ + DDR3 IP + LiteEth）。
#
# 注：本文件的 puts 一律不写方括号（YeshenCore 踩过：puts 里的方括号会被 Tcl 当命令替换）。
# ============================================================================

set root "D:/code/PDS/VexiiYeshenLinux"

set period "10.000"
if {[info exists env(YESHENMINI_DEVMAP_PERIOD)]} { set period $env(YESHENMINI_DEVMAP_PERIOD) }

set board_dir "$root/board"
set rtl_dir   "$root/rtl"
# 200H 版 DDR3 IP（与 NaxYeshenLinux 上板跑通那份同源）。
set ip_dir    "$root/third_party/ddr3_ip_200h/ddr3_test"

set project_name "yeshenmini_devmap_n5b"
set project_dir  "$root/sim/reglogs/pds_devmap_n5b_p${period}"
set project_file "$project_dir/$project_name.pds"

puts "=== Y1 N5b（NPU 独立时钟域：NpuTop 搬 npu_clk + 三桥 + reset sync）dev_map 探针：period = $period ns ==="
puts "=== project = $project_file ==="

if {[file exists $project_dir]} {
    file delete -force $project_dir
}

create_project $project_file -synthesize_tool 2 -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

# ---- 板级顶层（top_module）----
add_design "$board_dir/yeshen_mini_board_top.v"

# ---- 板级组装层 + 两颗板级 PLL ----
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

# ---- Y1 NPU 网表（单文件，与 c4a 档同一份）----
add_design "$root/y1/gen/NpuTop.v"

# ---- N5b：NPU 独立时钟域的三座异步桥 + 复位同步器（Verilog 网表，在板级 SoC 内例化）----
add_design "$root/y1/gen/NpuAxiLiteCdc.v"
add_design "$root/y1/gen/NpuMemCdc.v"
add_design "$root/y1/gen/NpuIrqCdc.v"
add_design "$root/y1/gen/NpuResetSync.v"

# ---- 紫光同创 DDR3 IP（源文件清单照 devmap_c4a.tcl）----
add_design "$ip_dir/ddr3_test.idf"
add_design "$ip_dir/ddr3_test.v"
add_design "$ip_dir/ddr3_test_ddrphy_top.v"
add_design "$ip_dir/rtl/ips2l_rst_sync_v1_3.vp"
foreach f [glob -nocomplain "$ip_dir/rtl/ddrphy/*.vp"]   { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/ddrphy/*.v"]    { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/mcdq_ctrl/*.vp"] { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/mcdq_ctrl/*.v"]  { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/pll/*.vp"]      { add_design $f }

# ---- 约束（引脚 + 时钟，含 N2b 的 create_clock {npu_clk}）----
add_constraint "$root/constraints/yeshen_mini.fdc"

puts "=== dev_map: compile ==="
compile -verilog_standard SystemVerilog

puts "=== dev_map: synthesize -ads ==="
synthesize -ads

puts "=== dev_map: dev_map（资源 + DRC）==="
dev_map -override_pcf false

# ---------------------------------------------------------------------------
# ★ N5b：把 **PDS 自己产出的时钟清单** 打进日志（这是 N5b 判据要的读数）
#   口径同 N2b：**不用** `get_property -period`（dev_map 的 task 流程不留 Design Workspace
#   打开状态 ⇒ 会报 `E: UiCommand-0251`）。改用 PDS 在 **synthesize / device_map** 阶段自己生成的
#   报告 DB（XML 文本，可直接读）：
#     · `synthesize_report_timing_clock_summary.db`  = **时钟表**（名字/类型/周期/源/端点/Clock Load）
#     · `device_map_clock_signal.db`                = device_map 阶段的**时钟网**清单（含插钟/Fanout）
#   期望：cpu_clk 10.0000ns（100MHz）与 npu_clk 20.0000ns（50MHz）同时在列，
#         npu_clk 的 Type = **Declared**、Source 空（独立根钟），
#         且 **Clock Load / Fanout 是一个大数**（N5b 起 npu_clk 有真负载，不再是 N2b 的 1）。
# ---------------------------------------------------------------------------
puts "=== N5b CLOCK-SUMMARY BEGIN（PDS 产物：synthesize 阶段时钟表）==="
set cs_dbs [list \
    "$project_dir/prj_tasks/syn_1/synthesize/report_db/synthesize_report_timing_clock_summary.db" \
    "$project_dir/prj_tasks/pnr_1/device_map/report_db/device_map_clock_signal.db" ]
foreach cs $cs_dbs {
    if {[file exists $cs]} {
        set fh [open $cs r]
        set body [read $fh]
        close $fh
        puts "---- REPORT FILE: $cs ----"
        puts $body
    } else {
        puts "---- REPORT FILE MISSING（本该由 PDS 生成）: $cs ----"
    }
}
puts "=== N5b CLOCK-SUMMARY END ==="

puts "=== dev_map DONE（资源见 Device Utilization Summary；DRC 见 DRC-xxxx 行）==="
puts "Y1_N5B_DEVMAP_DONE"
puts "YESHENMINI_N5B_DEVMAP_DONE"
