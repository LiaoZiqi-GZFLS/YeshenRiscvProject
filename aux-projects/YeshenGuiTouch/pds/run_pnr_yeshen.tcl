# ============================================================================
# run_pnr_yeshen.tcl -- **板级一整套**设计跑完 PnR -> report_timing -> 比特流
#
# 承接 run_devmap_yeshen.tcl（结构=它 + 接上 PnR 段）；两种入口：
#
#   A) 快速路径（默认，推荐）：**复用** dev_map 已经跑完的工程
#        sim/reglogs/pds_devmap_p10.000/yeshenmini_devmap.pds
#      => 只做 pnr + report_timing + gen_bit_stream（省掉 compile/synth/dev_map）。
#      工程里的 mapped 网表（prj_tasks/pnr_1/device_map/*_map.adf）与 fdc/源文件都是当轮输入。
#      ⚠️ 前提：**工程建好之后，fdc 与设计源文件不能再改**，否则该工程代表的是旧输入。
#
#   B) 从零路径：$project_file 不存在时（或 YESHENMINI_PNR_FRESH=1）本脚本自己
#      create_project -> add_design(全部源) -> compile -> synthesize -ads -> dev_map
#      -> pnr -> 比特流。源文件清单与 run_devmap_yeshen.tcl **逐行相同**（改一处要两处一起改）。
#
# ---------------------------------------------------------------------------
# 【用法】（Windows 侧 pds_shell，工作目录必须是 D:/code/PDS/YeshenGuiTouch；小时级，放后台）：
#   /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file pds/run_pnr_yeshen.tcl \
#       > sim/reglogs/m_yeshen_pnr.log 2>&1
#   # 判据：grep -c "All Constraints Met" / "YESHENMINI_PNR_DONE" / 比特流文件大小
#
# 本文件是 YeshenGui Phase R 的独立 RTL 副本（基线 VexiiYeshenLinux 212d3a2），
# 只引用 D:/code/PDS/YeshenGuiTouch 下的源文件；不改、不读原工程的 .pds 工程目录。
#
# 【环境变量（可省）】
#   YESHENMINI_PNR_TAG     工程标签（默认 devmap：即复用 dev_map 的工程目录）
#   YESHENMINI_PNR_PERIOD  cpu_clk 周期（ns）**只用于拼工程目录名**（默认 10.000 = 100MHz 真实值）
#   YESHENMINI_PNR_FRESH   置 1 时不复用既有工程，从 create_project 重新跑全套
#   YESHENMINI_SYNTH_MODE  综合档位（**只在 FRESH 从零建工程时生效**）：ads（默认）| speed
#                          （speed = -resource_sharing FALSE -retiming，时序优先；见 y1/pds/pnr_c4a.tcl 头）
#   YESHENMINI_PNR_SEEDS   保留的种子数（默认 4）。只在判据的"会红"负对照里改 1。
#   YESHENMINI_PNR_SCBV    配置 Bank 电压档位（默认 "High Voltage"；盘古676 的
#                          FLASH/JTAG/晶振接口是 3.3V 域）。合法值 Only：None / Low Voltage / High Voltage。
#
# 种子口径（照抄 YeshenCore 2026-09-28 定案 + Task 15 要求）：
#   `-saved_outcome 4`：保留 4 个种子的结果。**单种子布线发散会让整个 pnr 任务不完成
#   => gen_bit_stream 不执行 => 拿不到比特流**（实测过 seed 2 发散）。
#   `-pick_first_timing_convergence_seed true` 是交付脚本里验证过能跑完的写法。
#
# 【前置（同 run_devmap_yeshen.tcl）】rtl/vexiiriscv/VexiiRiscv.v、rtl/YeshenSocGlue.v、
#   rtl/DDR3Bridge.v 三者均已生成（核网表 24,528 行 / 胶合 4,246 行 / 内存桥 698 行）。
# ⚠️ 复用 dev_map 工程时 TAG 必须与那一轮 dev_map 一致（否则找不到工程，会走"从零"路径）。
#
# 注：本文件的 puts 一律不写方括号（YeshenCore 踩过：puts 里的方括号会被 Tcl 当命令替换）。
# ============================================================================

set root "D:/code/PDS/YeshenGuiTouch"

set tag "devmap"
if {[info exists env(YESHENMINI_PNR_TAG)]} { set tag $env(YESHENMINI_PNR_TAG) }
set period "10.000"
if {[info exists env(YESHENMINI_PNR_PERIOD)]} { set period $env(YESHENMINI_PNR_PERIOD) }
set scbv "High Voltage"
if {[info exists env(YESHENMINI_PNR_SCBV)]} { set scbv $env(YESHENMINI_PNR_SCBV) }
set seeds 4
if {[info exists env(YESHENMINI_PNR_SEEDS)]} { set seeds $env(YESHENMINI_PNR_SEEDS) }
set strat 3
if {[info exists env(YESHENMINI_PNR_STRATEGY)]} { set strat $env(YESHENMINI_PNR_STRATEGY) }
set fresh 0
if {[info exists env(YESHENMINI_PNR_FRESH)]} { set fresh $env(YESHENMINI_PNR_FRESH) }

set board_dir "$root/board"
set rtl_dir   "$root/rtl"
set ip_dir    "$root/third_party/ddr3_ip_200h/ddr3_test"

set project_name "yeshenmini_$tag"
set project_dir  "$root/sim/reglogs/pds_${tag}_p${period}"
set project_file "$project_dir/$project_name.pds"

puts "=== PnR（yeshen）：tag = $tag / cpu_clk period = $period ns / scbv = $scbv ==="
puts "=== project = $project_file ==="

# ---- 入口选择：A) 复用 dev_map 工程  B) 从零跑全套 ----
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
    add_design "$board_dir/yeshen_mini_board_top.v"
    # 板级组装层 + PLL
    add_design "$board_dir/yeshen_mini_soc.v"
    add_design "$board_dir/pll_100m_125m.v"
    add_design "$board_dir/pll_50m.v"
    add_design "$board_dir/pll_cpu.v"
    add_design "$board_dir/dcfifo.v"
    add_design "$board_dir/axi4_cdc_fetch.v"
    add_design "$board_dir/axi4_cdc_lsu.v"
    add_design "$board_dir/axi4_cdc_io.v"
    add_design "$board_dir/cpu_domain_cdc.v"
    # ★ V1（2026-10-20，Task 7）：视频链 + 仲裁器 + 寄存器 + LCD PLL + 厂家相机/帧存资产
    #   与 run_devmap_yeshen.tcl 的清单**逐行相同**（改一处要两处一起改）；
    #   SCCB.v / data_init.v 是 camera.v 的直接子模块（必须收）；
    #   **不收**仿真替身 pll_80m.v / stub_rambuf*.v / stub_rd_fram_buf.v。
    add_design "$root/board/cam/video_passthrough.v"
    add_design "$root/board/cam/overlay.v"
    add_design "$root/board/cam/video_regs.v"
    add_design "$root/board/cam/ddr_arbiter_2to1.v"
    # 双目切换（2026-10-27）：两路相机 mux/掐写/黑屏 + KEY 消抖
    add_design "$root/board/cam/cam_switch.v"
    add_design "$root/board/cam/key_toggle.v"
    add_design "$root/board/pll_lcd.v"
    add_design "$root/board/cam/vendor/camera/camera.v"
    add_design "$root/board/cam/vendor/camera/camera_data.v"
    add_design "$root/board/cam/vendor/camera/SCCB.v"
    add_design "$root/board/cam/vendor/camera/data_init.v"
    foreach f [glob -nocomplain "$root/board/cam/vendor/tutorial/*.v"] { add_design $f }
    add_design "$root/board/cam/vendor/sync_vg.v"
    add_design "$root/board/cam/vendor/ip/wr_fram_buf/wr_fram_buf.v"
    foreach f [glob -nocomplain "$root/board/cam/vendor/ip/wr_fram_buf/rtl/*.v"] { add_design $f }
    add_design "$root/board/cam/vendor/ip/rd_fram_buf/rd_fram_buf.v"
    foreach f [glob -nocomplain "$root/board/cam/vendor/ip/rd_fram_buf/rtl/*.v"] { add_design $f }
    # LiteEth 网卡：适配器层 + 生成的 MAC 黑盒 + 厂家 RGMII PHY 层（只这一个文件）
    add_design "$board_dir/liteeth_wrap.v"
    add_design "$root/third_party/liteeth_mac/liteeth_mac_top.v"
    add_design "$root/third_party/eth_stack_2_11/source/rgmii_interface.v"
    # 本项目的 RTL：核网表 + 胶合块 + 内存桥
    add_design "$rtl_dir/vexiiriscv/VexiiRiscv.v"
    add_design "$rtl_dir/YeshenSocGlue.v"
    add_design "$rtl_dir/DDR3Bridge.v"
    # Y1 NPU 生成网表（2026-10-17：与 run_devmap_yeshen.tcl / PnR sources_info 对齐）
    add_design "$root/y1/gen/NpuTop.v"
    add_design "$root/y1/gen/DmaEngine.v"
    add_design "$root/y1/gen/NpuAxiLiteCdc.v"
    add_design "$root/y1/gen/NpuMemCdc.v"
    add_design "$root/y1/gen/NpuIrqCdc.v"
    add_design "$root/y1/gen/NpuResetSync.v"
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
    add_constraint "$root/constraints/yeshen_mini.fdc"

    puts "=== pnr-flow: compile ==="
    compile -verilog_standard SystemVerilog
    # 综合档位（默认 ads = 现状；speed = 时序优先，依据与取值同 y1/pds/pnr_c4a.tcl）：
    set synth_mode "ads"
    if {[info exists env(YESHENMINI_SYNTH_MODE)]} { set synth_mode $env(YESHENMINI_SYNTH_MODE) }
    if {$synth_mode eq "speed"} {
        puts "=== pnr-flow: synthesize -ads（speed：-resource_sharing FALSE -retiming）==="
        synthesize -ads -resource_sharing FALSE -retiming
    } elseif {$synth_mode eq "ads"} {
        puts "=== pnr-flow: synthesize -ads ==="
        synthesize -ads
    } else {
        puts "=== ERROR: YESHENMINI_SYNTH_MODE='$synth_mode' 非法（只支持 ads|speed）==="
        error "YESHENMINI_SYNTH_MODE must be ads|speed"
    }
    puts "=== pnr-flow: dev_map ==="
    dev_map -override_pcf false
} else {
    open_project $project_file
}

# ★ 2026-10-26：可选的**单种子**入口。复用既有工程时，`pnr -saved_outcome N` 只会把已保存的
#   结果再报一遍、**不会**接着跑新的种子（实测：saved_outcome 4 已存在时改成 8，2 秒就"跑完"）。
#   要换一个随机种子只能显式给 `-gplace_seed/-groute_seed`；配合 `YESHENMINI_PNR_SEEDS=1`
#   ⇒ 一轮 ~40 min，可以逐颗试到收敛为止（同 netlist 的种子 0..3 是确定性的，重复跑没意义）。
set gseed ""
if {[info exists env(YESHENMINI_PNR_GSEED)]} { set gseed $env(YESHENMINI_PNR_GSEED) }
if {$gseed ne ""} {
    # ⚠️ 已有结果时 `pnr` 会"Action was skipped as the flow has been run" ⇒ 必须 `-force_to_run`，
    #    否则只是秒退（实测）。
    puts "=== pnr: strategy $strat / gplace_times 4 / **单种子 gseed=$gseed** / saved_outcome $seeds / force ==="
    # `-pick_first_timing_convergence_seed true`：第一颗收敛就停（否则会把这颗起的 4 颗全跑完）。
    pnr -strategy $strat -gplace_times 4 -gplace_seed $gseed -groute_seed $gseed -saved_outcome $seeds \
        -pick_first_timing_convergence_seed true -force_to_run
} else {
    puts "=== pnr: strategy $strat / gplace_times 4 / saved_outcome $seeds / pick_first_timing_convergence_seed true ==="
    pnr -strategy $strat -gplace_times 4 -saved_outcome $seeds -pick_first_timing_convergence_seed true
}

puts "=== pnr: report_timing（判据 1：看 All Constraints Met 与 Performance Summary）==="
report_timing -force_to_run

# 违例明细（只读报告，失败不影响上面的判据）
catch {
    puts "=== pnr: 违例路径明细（slack_less_than 0 / max_path 40）==="
    report_timing -max_path 40 -slack_less_than 0
}

puts "=== pnr: gen_bit_stream（判据 3：比特流文件存在且大小合理）==="
gen_bit_stream -scbv $scbv -force_to_run

puts "=== pnr: DONE。报告在 $project_dir/prj_tasks/pnr_1/place_route/report_timing/，比特流在工程目录下 ==="
puts "YESHENMINI_PNR_DONE"
