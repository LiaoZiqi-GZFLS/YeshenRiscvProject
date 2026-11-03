# ============================================================================
# devmap_soc_ctrl.tcl -- **SoC 基线（未含 NPU）** 的 dev_map —— A/B 的**控制臂**
#
# 用途：与 `devmap_soc_npu.tcl`（实验臂）构成**同会话背靠背的 A/B**，把
#       "把 NPU 集成进 SoC" 的资源代价**单独隔离**出来。
#
# 与实验臂的**唯一差异**（逐条列清，别猜）：
#   1. tag = `devmap_ctrl`（⇒ 独立工程目录 `sim/reglogs/pds_devmap_ctrl_p10.000`）
#   2. 组装层用 C2.2b **之前**的 `board/yeshen_mini_soc.v`（那时还没例化 NpuTop）
#      —— 取自 `git show 2307a56~1:board/yeshen_mini_soc.v`，落在 `y1/gen/ctrl_src/`
#   3. 胶合用 C2.2b **之前**的 `rtl/YeshenSocGlue.v`
#      —— 取自 `git show 2307a56~1:rtl/YeshenSocGlue.v`，md5 9c9107b712fdaea08019487456519cc8
#   4. **无** `add_design …/NpuTop.v` 那一行
#
# **为什么必须换那两个文件而不是只删 NPU 源**：当前组装层已经例化 `NpuTop`，
#   只删源文件会 elaborate 失败 ⇒ 那样"控制臂"根本跑不出来，A/B 就成了假的。
#
# 其余（器件行 / 源清单 / 约束 / compile 口径 / DONE 打点）**逐条照抄**实验臂。
# `pds_*_[gp]10.000` 与 `*.log` 均按 .gitignore 不入库。
#
# 用法（Windows 侧 pds_shell，工作目录必须是 D:/code/PDS/VexiiYeshenLinux）：
#   /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file \
#       D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_soc_ctrl.tcl \
#       > y1/pds/devmap_soc_ctrl.log 2>&1 ; echo "exit=$?"
# ============================================================================

set root "D:/code/PDS/VexiiYeshenLinux"

set tag "devmap_ctrl"
if {[info exists env(YESHENMINI_DEVMAP_TAG)]} { set tag $env(YESHENMINI_DEVMAP_TAG) }
set period "10.000"
if {[info exists env(YESHENMINI_DEVMAP_PERIOD)]} { set period $env(YESHENMINI_DEVMAP_PERIOD) }

set board_dir "$root/board"
set rtl_dir   "$root/rtl"
set ctrl_dir  "$root/y1/gen/ctrl_src"
set ip_dir    "$root/third_party/ddr3_ip_200h/ddr3_test"

set project_name "yeshenmini_$tag"
set project_dir  "$root/sim/reglogs/pds_${tag}_p${period}"
set project_file "$project_dir/$project_name.pds"

puts "=== SoC BASELINE (no NPU) dev_map: tag = $tag / cpu_clk period = $period ns ==="
puts "=== project = $project_file ==="

# 每次从头重建（与实验臂同一口径）
if {[file exists $project_dir]} {
    file delete -force $project_dir
}

create_project $project_file -synthesize_tool 2 -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

# ---- 板级顶层（top_module）----
add_design "$board_dir/yeshen_mini_board_top.v"

# ---- 板级组装层 + PLL（★ 组装层换成 C2.2b 之前那份 = 未含 NPU）----
add_design "$ctrl_dir/yeshen_mini_soc.v"
add_design "$board_dir/pll_100m_125m.v"

# ---- LiteEth 网卡：适配器层 + 生成的 MAC 黑盒 + 厂家 RGMII PHY 层 ----
add_design "$board_dir/liteeth_wrap.v"
add_design "$root/third_party/liteeth_mac/liteeth_mac_top.v"
add_design "$root/third_party/eth_stack_2_11/source/rgmii_interface.v"

# ---- 本项目 RTL：核网表 + 胶合（★ 换成 C2.2b 之前那份）+ 内存桥 ----
add_design "$rtl_dir/vexiiriscv/VexiiRiscv.v"
add_design "$ctrl_dir/YeshenSocGlue.v"
add_design "$rtl_dir/DDR3Bridge.v"

# ---- （控制臂无 NpuTop.v 这一行）----

# ---- 紫光同创 DDR3 IP（源清单照实验臂）----
add_design "$ip_dir/ddr3_test.idf"
add_design "$ip_dir/ddr3_test.v"
add_design "$ip_dir/ddr3_test_ddrphy_top.v"
add_design "$ip_dir/rtl/ips2l_rst_sync_v1_3.vp"
foreach f [glob -nocomplain "$ip_dir/rtl/ddrphy/*.vp"]   { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/ddrphy/*.v"]    { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/mcdq_ctrl/*.vp"] { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/mcdq_ctrl/*.v"]  { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/pll/*.vp"]      { add_design $f }

# ---- 约束（同一份，两臂一致）----
add_constraint "$root/constraints/yeshen_mini.fdc"

puts "=== dev_map: compile ==="
compile -verilog_standard SystemVerilog

puts "=== dev_map: synthesize -ads ==="
synthesize -ads

puts "=== dev_map: dev_map（资源 + DRC）==="
dev_map -override_pcf false

puts "=== dev_map DONE（资源见 Device Utilization Summary；DRC 见 DRC-xxxx 行）==="
puts "YESHENMINI_DEVMAP_DONE"
