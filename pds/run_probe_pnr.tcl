# ============================================================================
# run_probe_pnr.tcl -- M0-c 探针 Step 4：单 seed PnR + report_timing
#
# **复用** run_probe_fabric.tcl 建好的工程（tag + period 必须与 fabric 那一次一致）。
# 只做 pnr + report_timing，**不**出比特流（探针只要资源/时序结论）。
#
# 用法（Windows 侧 pds_shell，工作目录必须是 D:/code/PDS/NaxYeshenLinux）：
#   NAXMINI_PROBE_TAG=nol2 NAXMINI_PROBE_PERIOD=10.0 \
#     /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file pds/run_probe_pnr.tcl
#
# 环境变量：
#   NAXMINI_PROBE_TAG     与 fabric 那次相同：nol2 / l2。默认 nol2
#   NAXMINI_PROBE_PERIOD  与 fabric 那次相同（ns）：10.0 真实值 / 8.0 过约束。默认 10.0
#
# 种子口径（照抄 YeshenCore 2026-09-28 的定案）：
#   -saved_outcome 1（**不是** 4）：探针只要单 seed 结论；多种子一旦发散（布线 iteration
#   跑不完）整任务就拿不到结果。`-pick_first_timing_convergence_seed true` 是 YeshenCore
#   交付脚本里验证过能跑完的那个写法（单 seed 下等价于取 seed 0）。
#
# 判据：report_timing 报告里的 `Design Summary : All Constraints Met.`
#   * 报告落在 <project>/prj_tasks/pnr_1/place_route/report_timing/<top>.rtr
#   * 顶部 `Performance Summary` 表给出每个时钟的 Requested/Estimated 频率 + Slack
#
# 注：本文件的 puts 一律不写方括号（YeshenCore 踩过：puts 里的方括号会被 Tcl 当命令替换）。
# ============================================================================

set root "D:/code/PDS/NaxYeshenLinux"

set tag "nol2"
if {[info exists env(NAXMINI_PROBE_TAG)]} { set tag $env(NAXMINI_PROBE_TAG) }
set period "10.0"
if {[info exists env(NAXMINI_PROBE_PERIOD)]} { set period $env(NAXMINI_PROBE_PERIOD) }

set project_name "probe_$tag"
set project_dir  "$root/sim/reglogs/pds_probe_${tag}_p${period}"
set project_file "$project_dir/$project_name.pds"

puts "=== M0-c PnR 探针：tag = $tag / period = $period ns ==="
puts "=== project = $project_file ==="

if {![file exists $project_file]} {
    puts "ERROR: 找不到 $project_file -- 先跑 run_probe_fabric.tcl（同 tag/period）"
    exit 1
}

open_project $project_file

puts "=== pnr: single seed（strategy 3 / gplace_times 4 / saved_outcome 1）==="
pnr -strategy {3} -gplace_times 4 -saved_outcome 1 -pick_first_timing_convergence_seed true

puts "=== pnr: report_timing（看 All Constraints Met 与 Performance Summary Slack）==="
report_timing -force_to_run

puts "NAXMINI_PNR_DONE"

# 附加（只读报告，失败不影响上面结论）：把所有 setup 违例路径逐条打出来。
catch {
    puts "=== pnr: 违例路径明细（slack_less_than 0 / nworst 1 / max_path 40）==="
    report_timing -nworst 1 -max_path 40 -slack_less_than 0
}

puts "=== pnr: DONE（报告在 $project_dir/prj_tasks/pnr_1/place_route/report_timing/）==="
