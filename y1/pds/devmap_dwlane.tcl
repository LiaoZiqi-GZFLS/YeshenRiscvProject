# ============================================================================
# devmap_dwlane.tcl -- **NPU v2 切片 B-1**：dw lane 打包探针的 dev_map（资源 + DRC 预检）
#
# 被测 = `rtl_test/DwLaneProbe.scala` 出的**独立探针网表**（一份一次，按 `DWLANE_MODE` 选）：
#   · before  -> `y1/gen/DwLaneBefore.v`（MODE 0：as-built 广播 x + 9 拍/像素）
#   · after2  -> `y1/gen/DwLaneAfter2.v`（MODE 1：tap-inner 2 拍/像素）
#   · after1  -> `y1/gen/DwLaneAfter1.v`（MODE 2：tap-inner + 第 9 抽头行 ⇒ 1 拍/像素）
# 三者**同源同规模**（差的就是"加 dw 逐 lane 通路"这一件事）⇒ 读数之差 = 该改动的**实测成本**。
#
# 与 `devmap_c4a.tcl` 的 `layersched` 档同一手法（M0 教训）：裸探针顶层端口 > 400（bias/y 各 8×32 bit）
# ⇒ 预计以 IO 的 DeviceMap-2003/DRC-0018 中止、**没有** `Device Utilization Summary` ⇒
# 资源取 `synthesize -ads` 的 `Mapping Summary`（与集成档同一张表、同一口径）+ `GTP_*` 行。
#
# 【用法】（Windows 侧 pds_shell；工作目录必须是 D:/code/PDS/VexiiYeshenLinux）
#   DWLANE_MODE=before /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file \
#       D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_dwlane.tcl \
#       > y1/pds/devmap_dwlane_before.log 2>&1 ; echo "exit=$?"
#   （after1 / after2 同法；工程目录按 mode 分开放，绝不与其它探针交叉）
#
# 前置：`cd y1 && Test/runMain DwLaneGen <gen> {0|1|2} 8 [-1|5]`（见 rtl_test/DwLaneGen.scala）。
# 注：puts 一律不写方括号（YeshenCore 踩过：puts 里的方括号会被 Tcl 当命令替换）。
# ============================================================================

set root "D:/code/PDS/VexiiYeshenLinux"

set mode "before"
if {[info exists env(DWLANE_MODE)]} { set mode $env(DWLANE_MODE) }

if {$mode eq "after1"} {
    set nl  "$root/y1/gen/DwLaneAfter1.v"
} elseif {$mode eq "after2"} {
    set nl  "$root/y1/gen/DwLaneAfter2.v"
} elseif {$mode eq "after1mut5"} {
    set nl  "$root/y1/gen/DwLaneAfter1Mut5.v"
} else {
    set nl  "$root/y1/gen/DwLaneBefore.v"
}

set project_name "pds_dwlane_$mode"
set project_dir  "$root/y1/pds/pds_dwlane_$mode.000"
set project_file "$project_dir/$project_name.pds"

puts "=== Y1 NPU-v2 B-1 dwlane probe dev_map：mode = $mode ==="
puts "=== netlist = $nl ==="
puts "=== project = $project_file ==="

if {[file exists $project_dir]} {
    file delete -force $project_dir
}

create_project $project_file -synthesize_tool 2 -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

add_design $nl

puts "=== dev_map: compile ==="
compile -verilog_standard SystemVerilog

puts "=== dev_map: synthesize -ads ==="
synthesize -ads

puts "=== dev_map: dev_map（纯资源，裸探针 IO 超限属预期）==="
dev_map

puts "=== dev_map DONE（裸探针预计无 Device Utilization Summary；资源取 Mapping Summary + GTP_* 行）==="
puts "Y1_DWLANE_DEVMAP_DONE mode=$mode"
