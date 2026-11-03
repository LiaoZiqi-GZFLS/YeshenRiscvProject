# ============================================================================
# run_probe_fabric.tcl -- M0-c 探针 Step 2：社区 fabric（TileLink + CLINT/PLIC，
#                         可选 L2）在 PG2L200H/FBB676/-6 上的**资源 + DRC 预检**
#
# 只做 create_project -> compile -> synthesize -ads -> dev_map，**不**出比特流。
# PnR / 时序见 run_probe_pnr.tcl（复用本脚本建好的工程）。
#
# 用法（Windows 侧 pds_shell，工作目录必须是 D:/code/PDS/NaxYeshenLinux）：
#   NAXMINI_PROBE_DESIGN=rtl/NaxSocMini.v    NAXMINI_PROBE_TAG=nol2 NAXMINI_PROBE_PERIOD=10.0 \
#     /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file pds/run_probe_fabric.tcl
#   NAXMINI_PROBE_DESIGN=rtl_l2/NaxSocMini.v NAXMINI_PROBE_TAG=l2   NAXMINI_PROBE_PERIOD=10.0 \
#     /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file pds/run_probe_fabric.tcl
#
# 环境变量（三个都可省，省则取默认）：
#   NAXMINI_PROBE_DESIGN  设计源（相对本工程根）：rtl/NaxSocMini.v（无 L2，交付候选）
#                        或 rtl_l2/NaxSocMini.v（带 L2）。默认 rtl/NaxSocMini.v
#   NAXMINI_PROBE_TAG     工程标签：nol2 / l2，只用于区分工程目录。默认 nol2
#   NAXMINI_PROBE_PERIOD  socClk 周期（ns）。10.0 = 100MHz **真实值**；
#                         8.0 = 过约束（125MHz）用来探余量。默认 10.0
#   NAXMINI_PROBE_VSTD    compile 的 -verilog_standard 取值（如 SystemVerilog）。
#                         留空 = 用 PDS 默认（Verilog-2001 口径）。默认留空
#
# 关键点（照抄 M0-b 收口的口径）：
#   * 顶层只有 **socClk** 一个时钟（asyncReset 是异步复位、不是时钟）⇒ create_clock 打给 socClk。
#     本探针**不含 DDR IP**，所以没有 ref_clk/core_clk 那些跨域；违例只可能在 SoC 内部。
#   * **必须**带上 rtl/vendor 的两个文件（否则 compile 报几百条
#     Cannot find file containing module 'Ram_1w_1ra'）：
#       RamXilinx.v   = Ram_1w_1rs（D$ 4 个 way bank + 带 L2 时 L2 的 data/tags）
#       Ram_1w_1ra.v  = 271 个组合读 RAM 的自写行为模型（会被推断成分布式 RAM）
#   * 工程目录放在 sim/reglogs/ 下（该目录按计划入 .gitignore，工程 DB 不入库）。
#
# 注：本文件的 puts 一律不写方括号（YeshenCore 踩过：puts 里的方括号会被 Tcl 当命令替换）。
# ============================================================================

set root "D:/code/PDS/NaxYeshenLinux"

set tag "nol2"
if {[info exists env(NAXMINI_PROBE_TAG)]} { set tag $env(NAXMINI_PROBE_TAG) }
set design "rtl/NaxSocMini.v"
if {[info exists env(NAXMINI_PROBE_DESIGN)]} { set design $env(NAXMINI_PROBE_DESIGN) }
set period "10.0"
if {[info exists env(NAXMINI_PROBE_PERIOD)]} { set period $env(NAXMINI_PROBE_PERIOD) }
set vstd ""
if {[info exists env(NAXMINI_PROBE_VSTD)]} { set vstd $env(NAXMINI_PROBE_VSTD) }
set half [expr {$period / 2.0}]

set project_name "probe_$tag"
set project_dir  "$root/sim/reglogs/pds_probe_${tag}_p${period}"
set project_file "$project_dir/$project_name.pds"

puts "=== M0-c fabric 探针：tag = $tag / design = $design / period = $period ns ==="
puts "=== project = $project_file ==="

if {[file exists $project_dir]} {
    file delete -force $project_dir
}

create_project $project_file -synthesize_tool 2 -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

# ---- 设计源（NaxGen 产物）+ 两个必需的黑盒 RAM 模型 ----
add_design "$root/$design"
add_design "$root/rtl/vendor/RamXilinx.v"
add_design "$root/rtl/vendor/Ram_1w_1ra.v"

# ---- 时钟约束：顶层唯一时钟 socClk ----
# FDC 现场生成到工程目录里（不入库），只含一条 create_clock。
# 两个周期（10.0 真实 / 8.0 过约束）各跑一次，两次都记录。
set fdc "$project_dir/probe_clock.fdc"
set fh [open $fdc w]
puts $fh "# M0-c probe: single top-level clock socClk"
puts $fh "create_clock -name {socClk} \[get_ports {socClk}\] -period {$period} -waveform {0 $half}"
close $fh
add_constraint $fdc

puts "=== fabric probe: compile（verilog_standard = $vstd）==="
if {$vstd eq ""} {
    compile
} else {
    compile -verilog_standard $vstd
}

puts "=== fabric probe: synthesize -ads ==="
synthesize -ads

puts "=== fabric probe: dev_map（资源 + DRC）==="
dev_map -override_pcf false

puts "=== fabric probe: dev_map DONE（资源/DRC 见上方 Device Utilization Summary 与 DRC-xxxx）==="
puts "NAXMINI_PROBE_DONE"
