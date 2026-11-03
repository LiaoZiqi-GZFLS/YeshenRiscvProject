# ============================================================================
# pnr_c4a.tcl -- **板级 SoC + NPU(C4a / L_MAX=8 + 宽层多趟 + PartialSumBuf) 一整套 PnR
#                -> report_timing -> 比特流**
#
# 用途：把 C4a 交付的 NPU（`y1/gen/NpuTop.v` = LayerSched(L=8) / UnitExec(宽层多趟 WIDERUN) /
#   MultiPassUnit / PartialSumBuf / 8xConv3x3Slice / FusionBuf / BypassExec(旁路四单元) /
#   DescFetch / HostRegs / DdrMaster 全在里面）连同板级 SoC 一起跑完 PnR，并出**比特流**。
#
# 本文件由 y1/pds/pnr_soc_npu.tcl **逐条照抄**改核而来：器件行 / 源清单 / 约束 / PnR 策略 /
# 环境变量口径**逐行相同**，只换工程名 tag 与结束标记（改一处要两处一起改）。
#
# ---------------------------------------------------------------------------
# 【用法】（Windows 侧 pds_shell，工作目录必须是 D:/code/PDS/VexiiYeshenLinux；**小时级，放后台**）：
#   /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file y1/pds/pnr_c4a.tcl \
#       > y1/pds/pnr_c4a.log 2>&1 ; echo "exit=$?"
#
# 【判据】
#   1) report_timing 的 "All Constraints Met" 与 Performance Summary（WNS/TNS）
#   2) 比特流文件存在且大小合理（gen_bit_stream 产物）
#   3) 结束标记 YESHENMINI_PNR_C4A_DONE
#
# 【环境变量（可省）】
#   YESHENMINI_PNR_PERIOD  cpu_clk 周期（ns）；**只用于拼工程目录名**（默认 10.000 = 100MHz 真实值）
#   YESHENMINI_PNR_SEEDS   保留的种子数（默认 4）
#   YESHENMINI_PNR_SCBV    配置 Bank 电压（默认 "High Voltage"；盘古676 的 FLASH/JTAG/晶振接口是 3.3V 域）
#   YESHENMINI_PNR_TAG     工程目录 tag（默认 c4a；用于把不同轮次工程分开，便于对照与保留证据）
#   YESHENMINI_SYNTH_MODE  综合档位（**只在“从零建工程”那一支生效**；复用既有工程时不影响）：
#     · ads  （默认）= `synthesize -ads` —— 与既有流程**逐字相同**（面积优先，不改变任何行为）。
#     · speed        = `synthesize -ads -resource_sharing FALSE -retiming` —— 时序优先档。
#     ★ 依据（PDS 2025.2 自带文档，不是猜的）：
#        `doc/UG990004_Tcl_Command_User_Guide.pdf` §4.142 synthesize；`doc/UG990102_ADS_Synthesis_User_Guide.pdf` §3.3.1。
#        - `synthesize` 的语法是 `synthesize -ads/-synplify_pro`：**必须选一个综合引擎**，
#          **没有**“不带 -ads 的裸 synthesize”这一档；本机只装了 ADS 引擎（无 Synplify Pro 可执行
#          /只装了它的 VHDL 库目录）⇒ 任务里设想的 `plain` 档**在 PDS 上不存在**，故不提供。
#        - `Resource Sharing`（对应 `-resource_sharing`）默认**开**：会合并加/乘资源，“可优化面积，
#          但**可能降低时序**”（原文档语）⇒ 关掉它 = 不合并算术 = 换时序（代价是资源变多）。
#        - `Retiming`（对应 `-retiming`）默认**关**：打开后通过**搬运电路中已有寄存器**（**不插入**
#          新寄存器）来优化 timing/power/area ⇒ 功能等价、对时序友好。
#      （`-pipelining` 默认开 = 把寄存器前挪以吸收 dpram 异步输出 mux-chain，是**省面积**方向，
#        未纳入 speed 档，避免与“少动结构”冲突。）
#
# 种子口径（照抄 pds/run_pnr_yeshen.tcl 的定案）：
#   `-saved_outcome 4` 保留 4 个种子；**单种子布线发散会让整个 pnr 任务不完成 => gen_bit_stream
#   不执行 => 拿不到比特流**（实测过 seed 2 发散）。`-pick_first_timing_convergence_seed true`
#   是交付脚本里验证过能跑完的写法。
#
# 【前置（必须已生成）】rtl/vexiiriscv/VexiiRiscv.v、rtl/YeshenSocGlue.v、rtl/DDR3Bridge.v、
#   y1/gen/NpuTop.v（含 LayerSched L_MAX=8 全套 + C4a 宽层多趟 + PartialSumBuf）。
#
# 注：本文件的 puts 一律不写方括号（YeshenCore 踩过：puts 里的方括号会被 Tcl 当命令替换）。
# ============================================================================

set root "D:/code/PDS/VexiiYeshenLinux"

set period "10.000"
if {[info exists env(YESHENMINI_PNR_PERIOD)]} { set period $env(YESHENMINI_PNR_PERIOD) }
set scbv "High Voltage"
if {[info exists env(YESHENMINI_PNR_SCBV)]} { set scbv $env(YESHENMINI_PNR_SCBV) }
set seeds 4
if {[info exists env(YESHENMINI_PNR_SEEDS)]} { set seeds $env(YESHENMINI_PNR_SEEDS) }
# 工程标签（用于把不同轮次的工程目录分开，便于对照与保留证据；默认 c4a）
set tag "c4a"
if {[info exists env(YESHENMINI_PNR_TAG)]} { set tag $env(YESHENMINI_PNR_TAG) }

set board_dir "$root/board"
set rtl_dir   "$root/rtl"
set ip_dir    "$root/third_party/ddr3_ip_200h/ddr3_test"

set project_name "yeshenmini_pnr_c4a_$tag"
set project_dir  "$root/sim/reglogs/pds_pnr_c4a_${tag}_p${period}"
set project_file "$project_dir/$project_name.pds"

puts "=== PnR（SoC + NPU C4a / L_MAX=8 + 宽层多趟 + PartialSumBuf）：cpu_clk period = $period ns / scbv = $scbv / seeds = $seeds ==="
puts "=== project = $project_file ==="

# ---- 入口：工程已存在则**复用**（只跑 pnr + report_timing + 比特流，省掉 compile/synth/dev_map）；
#      否则从零跑全套。复用的前提是 fdc 与源文件自建工程以来未改（本轮即是）。
if {[file exists $project_file]} {
    puts "=== 入口 A：复用既有工程 $project_file（只跑 pnr + report_timing + 比特流）==="
    open_project $project_file
} else {
    puts "=== 入口 B：从零 create_project -> compile -> synthesize -> dev_map -> pnr -> 比特流 ==="
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
# ---- 本项目的 RTL：核网表 + 胶合块 + 内存桥 ----
add_design "$rtl_dir/vexiiriscv/VexiiRiscv.v"
add_design "$rtl_dir/YeshenSocGlue.v"
add_design "$rtl_dir/DDR3Bridge.v"
# ---- Y1 NPU 网表（NpuTop + LayerSched(L=8) + UnitExec(宽层多趟) + MultiPassUnit + PartialSumBuf
#      + FusionBuf + 旁路四单元 + DescFetch；全在单文件里）----
add_design "$root/y1/gen/NpuTop.v"
# ---- Y1 DMA 引擎网表（Y1-DMA Phase-2b：多通道通用 DMA 引擎，跑 cpu_clk，板级兄弟例化）----
add_design "$root/y1/gen/DmaEngine.v"
# ---- N5b：NPU 独立时钟域的三座异步桥 + 复位同步器（Verilog 网表，在板级 SoC 内例化）----
add_design "$root/y1/gen/NpuAxiLiteCdc.v"
add_design "$root/y1/gen/NpuMemCdc.v"
add_design "$root/y1/gen/NpuIrqCdc.v"
add_design "$root/y1/gen/NpuResetSync.v"
# ---- 紫光同创 DDR3 IP ----
add_design "$ip_dir/ddr3_test.idf"
add_design "$ip_dir/ddr3_test.v"
add_design "$ip_dir/ddr3_test_ddrphy_top.v"
add_design "$ip_dir/rtl/ips2l_rst_sync_v1_3.vp"
foreach f [glob -nocomplain "$ip_dir/rtl/ddrphy/*.vp"]    { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/ddrphy/*.v"]     { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/mcdq_ctrl/*.vp"] { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/mcdq_ctrl/*.v"]  { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/pll/*.vp"]       { add_design $f }
# ---- 约束（引脚 + 时钟 + CPD 落点）----
add_constraint "$root/constraints/yeshen_mini.fdc"

puts "=== pnr-flow: compile ==="
compile -verilog_standard SystemVerilog
# ---- 综合档位（默认 ads = 现状；speed = 时序优先；依据与取值见文件头 YESHENMINI_SYNTH_MODE）----
set synth_mode "ads"
if {[info exists env(YESHENMINI_SYNTH_MODE)]} { set synth_mode $env(YESHENMINI_SYNTH_MODE) }
if {$synth_mode eq "speed"} {
    puts "=== pnr-flow: synthesize -ads（speed/timing 档：-resource_sharing FALSE -retiming）==="
    synthesize -ads -resource_sharing FALSE -retiming
} elseif {$synth_mode eq "ads"} {
    puts "=== pnr-flow: synthesize -ads ==="
    synthesize -ads
} else {
    puts "=== ERROR: YESHENMINI_SYNTH_MODE='$synth_mode' 非法（只支持 ads|speed；PDS 无 'plain' 档）==="
    error "YESHENMINI_SYNTH_MODE must be ads|speed"
}
puts "=== pnr-flow: dev_map ==="
dev_map -override_pcf false
}

puts "=== pnr: strategy 3 / gplace_times 4 / saved_outcome $seeds / pick_first_timing_convergence_seed true ==="
pnr -strategy {3} -gplace_times 4 -saved_outcome $seeds -pick_first_timing_convergence_seed true

puts "=== pnr: report_timing（判据 1：看 All Constraints Met 与 Performance Summary）==="
report_timing -force_to_run

# 违例明细（只读报告，失败不影响上面的判据）
catch {
    puts "=== pnr: 违例路径明细（slack_less_than 0 / max_path 40）==="
    report_timing -max_path 40 -slack_less_than 0
}

puts "=== pnr: gen_bit_stream（判据 2：比特流文件存在且大小合理）==="
gen_bit_stream -scbv $scbv -force_to_run

puts "=== pnr: DONE。报告在 $project_dir/prj_tasks/pnr_1/place_route/report_timing/，比特流在工程目录下 ==="
puts "YESHENMINI_PNR_C4A_DONE"
