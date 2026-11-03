# ============================================================================
# devmap_npu.tcl -- **独立 NPU 网表**的 dev_map（只出资源，不上板、不出比特流）
#
# 只做 create_project -> add_design(仅 NPU 网表) -> compile -> synthesize -ads -> dev_map，
# **不**跑 pnr、**不**出比特流、**不**碰板。这正是 M0-B10 的交付物：
# 第三方 SpinalHDL CNN 加速器（为 YOLOv5 族 640x640 INT8 设计）Pango 化后的**首个真实资源数**。
#
# 由 pds/run_devmap_yeshen.tcl 改核而来（同一套器件行 / compile 口径 / DONE 打点风格）：
#   顶层  yeshen_mini_board_top → Npu
#   源    board/ + rtl/ + DDR3 IP 全套 → **只有** ai_npu_exp/gen/Npu.v
#   约束  constraints/yeshen_mini.fdc   → **无**（纯资源探针，没有板级顶层，不造假引脚约束）
#   工程  sim/reglogs/pds_devmap_p10.000 → ai_npu_exp/pds/pds_m0_npu.000（与 SoC 工程绝不交叉）
#
# ---------------------------------------------------------------------------
# 【用法】（Windows 侧 pds_shell，工作目录必须是 D:/code/PDS/VexiiYeshenLinux）：
#   /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file \
#       D:/code/PDS/VexiiYeshenLinux/ai_npu_exp/pds/devmap_npu.tcl \
#       > ai_npu_exp/pds/devmap_npu.log 2>&1
#   grep -n "Device Utilization Summary" -A 32 ai_npu_exp/pds/devmap_npu.log
#   grep -nE "YESHENM0_NPU_DEVMAP_DONE|^E:|^Error" ai_npu_exp/pds/devmap_npu.log
#
# 【前置（必须先生成，否则 add_design 找不到文件）】
#   ai_npu_exp/gen/Npu.v  ← cd ai_npu_exp/port && sbt 跑 GenNpu（B4/B9 后的 Pango 化网表）
#     当前指纹：64 个 module 定义 / 1152 个 DSP（MAC）例化 / 17 处 ram_style="block"
#               / 零 Xilinx 原语 / 零悬空实例
#
# 【关键点】
#   * 设计源**只有** gen/Npu.v 一个文件：不掺 SoC、不掺 DDR3 IP、不掺 board/。
#     这是纯加速器资源占用，粒度与 sim/reglogs/m_yeshen_devmap.log（SoC 基线）可比。
#   * **无约束**：本工程没有板级顶层，也没有任何引脚/时钟口径可约束。
#     若 PDS 因此拒绝 dev_map，则**如实报错**，绝不臆造带假引脚的 FDC 来蒙混过关。
#   * 工程目录放 ai_npu_exp/pds/ 下（*.pds 与 *.log 均按 .gitignore 不入库），
#     与 SoC 的 sim/reglogs/pds_devmap_p10.000 完全隔离，不会互相踩。
#
# 注：本文件的 puts 一律不写方括号（YeshenCore 踩过：puts 里的方括号会被 Tcl 当命令替换）。
# ============================================================================

set root "D:/code/PDS/VexiiYeshenLinux"
set npu_dir "$root/ai_npu_exp"

set project_name "pds_m0_npu"
set project_dir  "$npu_dir/pds/pds_m0_npu.000"
set project_file "$project_dir/$project_name.pds"

puts "=== NPU 独立 dev_map（M0-B10）：仅 ai_npu_exp/gen/Npu.v，无板级约束 ==="
puts "=== project = $project_file ==="

if {[file exists $project_dir]} {
    file delete -force $project_dir
}

create_project $project_file -synthesize_tool 2 -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

# ---- 唯一设计源：Pango 化后的 NPU 网表（顶层 = Npu）----
add_design "$npu_dir/gen/Npu.v"

# ---- 无 add_constraint：本工程是纯资源探针。----
# 没有 board/yeshen_mini_board_top.v 的引脚顶层，也就没有可信的 FDC 可写；
# 造一份假引脚 FDC 只会污染资源数结论。若无约束导致 dev_map 失败，如实报错。

puts "=== dev_map: compile ==="
# 与 SoC 口径一致：显式用 SystemVerilog 标准（对 SpinalHDL 输出更宽容，Verilog-2001 子集亦兼容）。
compile -verilog_standard SystemVerilog

puts "=== dev_map: synthesize -ads ==="
synthesize -ads

puts "=== dev_map: dev_map（纯资源，无 IO 约束）==="
dev_map

puts "=== dev_map DONE（资源见 Device Utilization Summary）==="
puts "YESHENM0_NPU_DEVMAP_DONE"
