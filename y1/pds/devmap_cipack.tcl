# ============================================================================
# devmap_cipack.tcl -- **NPU v2 切片 C-1**：dense ci-inner 探针的 dev_map（资源 + DRC 预检）
#
# 被测 = `rtl_test/CiPackProbe.scala` 出的**独立探针网表**（一份一次，按 `CIPACK_MODE` 选）：
#   · base  -> `y1/gen/CiPackBase.v`（DCI=0：B1 落地后的切片当量 = dense 广播 + dw 逐 lane AFTER1）
#   · dci   -> `y1/gen/CiPackDci.v` （DCI=1：Base + **c3 ci-inner** —— 本片被测的增量）
#   · mut5  -> `y1/gen/CiPackDciMut5.v`（外科锚，可选）
# 三档**同源同规模**（差的就是 c3 读口/选择器/相位这一件事）⇒ 读数之差 = 该改动的**实测成本**。
#
# 与 `devmap_dwlane.tcl` 同一手法（M0 教训）：裸探针顶层端口 > 400（bias/y 各 8×32 bit）
# ⇒ 预计以 IO 的 DeviceMap-2003/DRC-0018 中止、**没有** `Device Utilization Summary` ⇒
# 资源取 `synthesize -ads` 的 `Mapping Summary`（与集成档同一张表、同一口径）+ `GTP_*` 行。
#
# 【用法】（Windows 侧 pds_shell；工作目录必须是 D:/code/PDS/VexiiYeshenLinux）
#   CIPACK_MODE=base /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file \
#       D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_cipack.tcl \
#       > y1/pds/devmap_cipack_base.log 2>&1 ; echo "exit=$?"
#   （dci / mut5 同法；工程目录按 mode 分开放，绝不与其它探针交叉）
#
# 前置：`cd y1 && printf 'Test/runMain CiPackGen D:/code/PDS/VexiiYeshenLinux/y1/gen <0|1> [MUTX]\nexit\n' | bash sbt.sh`
#
# 注：puts 一律不写方括号（YeshenCore 踩过：puts 里的方括号会被 Tcl 当命令替换）。
# ============================================================================

set root "D:/code/PDS/VexiiYeshenLinux"

set mode "base"
if {[info exists env(CIPACK_MODE)]} { set mode $env(CIPACK_MODE) }

if {$mode eq "dci"} {
    set nl "$root/y1/gen/CiPackDci.v"
} elseif {$mode eq "mut5"} {
    set nl "$root/y1/gen/CiPackDciMut5.v"
} else {
    set nl "$root/y1/gen/CiPackBase.v"
}

set project_name "pds_cipack_$mode"
set project_dir  "$root/y1/pds/pds_cipack_$mode.000"
set project_file "$project_dir/$project_name.pds"

puts "=== Y1 NPU-v2 C-1 cipack probe dev_map：mode = $mode ==="
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
puts "Y1_CIPACK_DEVMAP_DONE mode=$mode"
