# ============================================================================
# devmap_slice.tcl -- **Y1 卷积切片（640 宽行缓冲，GROUP=1）** 的 dev_map（只出资源）
#
# 只做 create_project -> add_design(仅切片网表) -> compile -> synthesize -ads -> dev_map，
# **不**跑 pnr、**不**出比特流、**不**碰板。这是 Y1-B5（G1 面积闸门）的交付物：
# 新设计面积占大头的 datapath（LineBuffer + WeightStore + GroupedMacArray + requant）
# 在 PG2L200H 上的**真实资源数**，用于判定 SoC+切片 是否装得下。
#
# 由 pds/run_devmap_yeshen.tcl（板级 SoC）与 ai_npu_exp/pds/devmap_npu.tcl（M0 探针）改核而来，
# 同一套器件行 / compile 口径 / DONE 打点风格：
#   顶层  yeshen_mini_board_top → Conv3x3Slice
#   源    board/ + rtl/ + DDR3 IP 全套 → **只有** y1/gen/Conv3x3Slice.v（GROUP=1，WIDTH=640）
#   约束  constraints/yeshen_mini.fdc   → **无**（纯资源探针，没有板级顶层，不造假引脚约束）
#   工程  sim/reglogs/pds_devmap_p10.000 → y1/pds/pds_slice_640.000（与 SoC 工程绝不交叉）
#
# ---------------------------------------------------------------------------
# 【用法】（Windows 侧 pds_shell，工作目录必须是 D:/code/PDS/VexiiYeshenLinux）：
#   /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file \
#       D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_slice.tcl \
#       > y1/pds/devmap_slice.log 2>&1
#   grep -nE "Device Utilization Summary|Mapping Summary" -A 16 y1/pds/devmap_slice.log
#   grep -nE "Y1_SLICE_DEVMAP_DONE|DRC-0018|DeviceMap-2003|Program Error" y1/pds/devmap_slice.log
#
# 【前置（必须先生成，否则 add_design 找不到文件）】
#   y1/gen/Conv3x3Slice.v  ← cd y1 && printf 'Test/runMain SliceGen D:/code/PDS/VexiiYeshenLinux/y1/gen 640\nexit\n' | bash sbt.sh
#     即同一份 RTL、只把 WIDTH 从数值定点用例的 16 换成 **640**（行缓冲面积随 WIDTH 缩放，
#     16 宽会低估面积）。GROUP=1 档的权重存储最大（576 项 vs 144/72）⇒ 取最坏情形。
#     本脚本按 y1/gen/Conv3x3Slice.v（GROUP=1）度量。
#
# 【关键点】
#   * 设计源**只有** y1/gen/Conv3x3Slice.v 一个文件：不掺 SoC、不掺 DDR3 IP、不掺 board/。
#     粒度与 sim/reglogs/m_yeshen_devmap.log（SoC 基线，LUT 14130.5 / FF 17124 / APM 4 / DRM 23.5）
#     可比，G1 判据把两者相加再对器件上限比。
#   * **无约束**：本工程没有板级顶层，也没有任何引脚/时钟口径可约束。纯资源探测。
#     若 PDS 因此拒绝 dev_map，则**如实报错**，绝不臆造带假引脚的 FDC 来蒙混过关。
#   * 工程目录放 y1/pds/ 下（*.pds 与 *.log 均按 .gitignore 不入库），
#     与 SoC 的 sim/reglogs/pds_devmap_p10.000 完全隔离，不会互相踩。
#
# 注：本文件的 puts 一律不写方括号（YeshenCore 踩过：puts 里的方括号会被 Tcl 当命令替换）。
# ============================================================================

set root "D:/code/PDS/VexiiYeshenLinux"
set slice_dir "$root/y1"

set project_name "pds_slice_640"
set project_dir  "$slice_dir/pds/pds_slice_640.000"
set project_file "$project_dir/$project_name.pds"

puts "=== 切片独立 dev_map（G1 面积闸门）：仅 y1/gen/Conv3x3Slice.v（GROUP=1, WIDTH=640），无板级约束 ==="
puts "=== project = $project_file ==="

if {[file exists $project_dir]} {
    file delete -force $project_dir
}

create_project $project_file -synthesize_tool 2 -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

# ---- 唯一设计源：640 宽行缓冲的卷积切片网表（顶层 = Conv3x3Slice）----
add_design "$slice_dir/gen/Conv3x3Slice.v"

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

puts "=== dev_map DONE（资源见 Device Utilization Summary；若资源超限则该段不打印，退回 Mapping Summary + GTP_* 行）==="
puts "Y1_SLICE_DEVMAP_DONE"
