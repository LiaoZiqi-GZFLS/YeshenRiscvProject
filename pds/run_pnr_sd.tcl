# ============================================================================
# run_pnr.tcl -- Task 15：**板级一整套**设计跑完 PnR -> report_timing -> 比特流
#
# 承接 Task 14 的 run_devmap.tcl（结构=它 + 接上 PnR 段）；两种入口：
#
#   A) 快速路径（默认，推荐）：**复用** Task 14 已经跑完 dev_map 的工程
#        sim/reglogs/pds_devmap_p10.000/naxmini_devmap.pds
#      => 只做 pnr + report_timing + gen_bit_stream（省掉 4 分钟的 compile/synth/dev_map）。
#      工程里的 mapped 网表（prj_tasks/pnr_1/device_map/*_map.adf）与 fdc/源文件都是当轮的实际输入。
#      ⚠️ 前提：**工程建好之后，fdc 与设计源文件不能再改**，否则该工程代表的是旧输入。
#         本脚本会在 §3 打印工程/源文件的 sha256 供追溯（归档件见 sim/reglogs/devmap_t14_archive/）。
#
#   B) 从零路径：$project_file 不存在时（或 NAXMINI_PNR_FRESH=1）本脚本自己
#      create_project -> add_design(全部源) -> compile -> synthesize -ads -> dev_map -> pnr -> 比特流。
#      源文件清单与 run_devmap.tcl **逐行相同**（改一处要两处一起改）。
#
# 用法（Windows 侧 pds_shell，工作目录必须是 D:/code/PDS/NaxYeshenLinux；小时级，放后台）：
#   /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file pds/run_pnr.tcl \
#       > sim/reglogs/m3_pnr.log 2>&1
#   # 判据：grep -c "All Constraints Met" / "NAXMINI_PNR_DONE" / 比特流文件大小
#
# 环境变量（可省）：
#   NAXMINI_PNR_TAG     工程标签（默认 devmap：即复用 Task 14 的工程目录）
#   NAXMINI_PNR_PERIOD  cpu_clk 周期（ns）**只用于拼工程目录名**（默认 10.000 = 100MHz 真实值）
#   NAXMINI_PNR_FRESH   置 1 时不复用既有工程，从 create_project 重新跑全套
#   NAXMINI_PNR_SEEDS   保留的种子数（默认 4）。**只在判据的"会红"负对照里改 1**：
#                       负对照用的是故意改坏的时钟（1ns），没有种子能收敛 ⇒ 4 个种子会全部跑完、
#                       白等 4 倍时间；改成 1 只跑一个种子，判据同样是 pnr 后的 report_timing。
#   NAXMINI_PNR_SCBV    配置 Bank 电压档位（默认 "High Voltage"，盘古676 的 FLASH/JTAG/晶振
#                       接口是 3.3V 域；不设会报 Bitstream-2001 警告且上板配置电压未声明）。
#                       合法值只有 None / Low Voltage / High Voltage 三个。
#
# 种子口径（照抄 YeshenCore 2026-09-28 的定案 + Task 15 的要求）：
#   `-saved_outcome 4`（**不是** 1）：保留 4 个种子的结果。**单种子布线发散会让整个 pnr 任务
#   不完成 => gen_bit_stream 不执行 => 拿不到比特流**（2026-09-28 实测过 seed 2 发散）。
#   `-pick_first_timing_convergence_seed true` 是既有交付脚本里验证过能跑完的那个写法。
#
# 注：本文件的 puts 一律不写方括号（YeshenCore 踩过：puts 里的方括号会被 Tcl 当命令替换）。
# ============================================================================

set root "D:/code/PDS/NaxYeshenLinux"

set tag "devmap"
if {[info exists env(NAXMINI_PNR_TAG)]} { set tag $env(NAXMINI_PNR_TAG) }
set period "10.000"
if {[info exists env(NAXMINI_PNR_PERIOD)]} { set period $env(NAXMINI_PNR_PERIOD) }
set scbv "High Voltage"
if {[info exists env(NAXMINI_PNR_SCBV)]} { set scbv $env(NAXMINI_PNR_SCBV) }
set seeds 4
if {[info exists env(NAXMINI_PNR_SEEDS)]} { set seeds $env(NAXMINI_PNR_SEEDS) }
set fresh 0
if {[info exists env(NAXMINI_PNR_FRESH)]} { set fresh $env(NAXMINI_PNR_FRESH) }

set board_dir "$root/board"
set rtl_dir   "$root/rtl"
# ★ 2026-10-03 修正：这里曾经仍指向 `third_party/ddr3_ip/ddr3_test`（**100H**）——
#   我只改了 run_devmap.tcl 的 ip_dir，于是"dev_map 日志显示 200H、但真正出比特流的 PnR 一直用 100H PHY"，
#   板上症状就是 `ddr_init_done` 恒 0（PDS 会打 `W: Flow-4058: The device information PG2L100H-… of IP …` 作为铁证）。
#   ⇒ 两处 ip_dir 必须一致；换 IP 后**要核 PnR 日志的 add_design 路径**，不能只看 dev_map。
set ip_dir    "$root/third_party/ddr3_ip_200h/ddr3_test"

set project_name "naxmini_$tag"
set project_dir  "$root/sim/reglogs/pds_${tag}_p${period}"
set project_file "$project_dir/$project_name.pds"

puts "=== Task 15 PnR：tag = $tag / cpu_clk period = $period ns / scbv = $scbv ==="
puts "=== project = $project_file ==="

# ---- 入口选择：A) 复用 Task 14 的 dev_map 工程  B) 从零跑全套 ----
set reuse 0
if {[file exists $project_file] && $fresh != 1} {
    set reuse 1
    puts "=== 入口 A：复用既有 dev_map 工程（只跑 pnr + report_timing + 比特流）==="
} else {
    puts "=== 入口 B：从零 create_project -> compile -> synthesize -> dev_map -> pnr ==="
}

if {$reuse == 0} {
    if {[file exists $project_dir]} {
        file delete -force $project_dir
    }
    create_project $project_file -synthesize_tool 2 -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

    # 板级顶层（top_module）
    add_design "$board_dir/nax_mini_board_top.v"
    # 板级组装层 + PLL
    add_design "$board_dir/nax_mini_soc.v"
    add_design "$board_dir/pll_100m_125m.v"
    # LiteEth 网卡（2026-10-06）：适配器层 + 生成的 MAC 黑盒 + 厂家 RGMII PHY 层（只这一个文件）
    add_design "$board_dir/liteeth_wrap.v"
    add_design "$root/third_party/liteeth_mac/liteeth_mac_top.v"
    add_design "$root/third_party/eth_stack_2_11/source/rgmii_interface.v"
    # 本项目的 RTL（核网表 / 胶合块 / 内存桥 + 两个黑盒 RAM 模型）
    add_design "$rtl_dir/NaxSocMini.v"
    add_design "$rtl_dir/NaxMiniGlue.v"
    add_design "$rtl_dir/DDR3Bridge.v"
    add_design "$rtl_dir/vendor/RamXilinx.v"
    add_design "$rtl_dir/vendor/Ram_1w_1ra.v"
    # 紫光同创 DDR3 IP（源文件清单照 NaxYeshenSoC/pds/run_nax_devmap.tcl）
    add_design "$ip_dir/ddr3_test.idf"
    add_design "$ip_dir/ddr3_test.v"
    add_design "$ip_dir/ddr3_test_ddrphy_top.v"
    add_design "$ip_dir/rtl/ips2l_rst_sync_v1_3.vp"
    foreach f [glob -nocomplain "$ip_dir/rtl/ddrphy/*.vp"]    { add_design $f }
    foreach f [glob -nocomplain "$ip_dir/rtl/ddrphy/*.v"]     { add_design $f }
    foreach f [glob -nocomplain "$ip_dir/rtl/mcdq_ctrl/*.vp"] { add_design $f }
    foreach f [glob -nocomplain "$ip_dir/rtl/mcdq_ctrl/*.v"]  { add_design $f }
    foreach f [glob -nocomplain "$ip_dir/rtl/pll/*.vp"]       { add_design $f }
    # 约束（引脚 + 时钟 + CPD 落点）

add_constraint "$root/constraints/nax_mini.fdc"

    puts "=== pnr-flow: compile ==="
    compile -verilog_standard SystemVerilog
    puts "=== pnr-flow: synthesize -ads（时序首次可见：看 syn_1/synthesize/*.snr 的 Design Summary）==="
    synthesize -ads
    puts "=== pnr-flow: dev_map ==="
    dev_map -override_pcf false
} else {
    open_project $project_file
}

puts "=== pnr: strategy 3 / gplace_times 4 / saved_outcome $seeds / pick_first_timing_convergence_seed true ==="
pnr -strategy {3} -gplace_times 4 -saved_outcome $seeds -pick_first_timing_convergence_seed true

puts "=== pnr: report_timing（判据 1：看 All Constraints Met 与 Performance Summary）==="
report_timing -force_to_run

# 违例明细（只读报告，失败不影响上面的判据）：给下一个动作的输入。
catch {
    puts "=== pnr: 违例路径明细（slack_less_than 0 / max_path 40）==="
    report_timing -max_path 40 -slack_less_than 0
}

puts "=== pnr: gen_bit_stream（判据 3：比特流文件存在且大小合理）==="
gen_bit_stream -scbv $scbv -force_to_run

puts "=== pnr: DONE。报告在 $project_dir/prj_tasks/pnr_1/place_route/report_timing/，比特流在工程目录下 ==="
puts "NAXMINI_PNR_DONE"
