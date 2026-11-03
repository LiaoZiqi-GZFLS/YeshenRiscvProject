# ============================================================================
# devmap_soc_npu.tcl -- **SoC + NPU（NpuTop 并入胶合）** 的 dev_map（资源 + DRC 预检）
#
# 由 pds/run_devmap_yeshen.tcl（板级 SoC 一整套）**逐条照抄**改核而来，只做一处增补：
#   · 板级源清单**一字未动**（顶层 / 组装层 / PLL / LiteEth 全套 / 核网表 / 胶合 / 内存桥 /
#     紫光 DDR3 IP 全套）；约束仍是 constraints/yeshen_mini.fdc。
#   · **只增**一行 `add_design "$root/y1/gen/NpuTop.v"` —— 因为 C2.2 已把 NpuTop 并进
#     组装层 board/yeshen_mini_soc.v（胶合 io_npuMem_* / io_npuAxi_* / io_npuIrq），
#     没有这一个源文件，板级顶层**elaborate 不出来**。
#   · 器件行 / compile 口径 / DONE 打点风格 **全部照抄**（不凭记忆手写）。
#
# **隔离**：工程目录用 tag = `devmap_npu` ⇒ `sim/reglogs/pds_devmap_npu_p10.000`，
#   与 SoC 基线工程 `sim/reglogs/pds_devmap_p10.000` **绝不交叉**（tag 不同即可）。
#   （sim/reglogs/ 与 *.pds 均按 .gitignore 不入库。）
#
# ---------------------------------------------------------------------------
# 【用法】（Windows 侧 pds_shell，工作目录必须是 D:/code/PDS/VexiiYeshenLinux）：
#   /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file \
#       D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_soc_npu.tcl \
#       > y1/pds/devmap_soc_npu.log 2>&1 ; echo "exit=$?"
#   grep -nE "Device Utilization Summary" -A 14 y1/pds/devmap_soc_npu.log
#   grep -nE "Mapping Summary" -A 12 y1/pds/devmap_soc_npu.log
#   grep -nE "DRC-0018|DeviceMap-2003|Program Error" y1/pds/devmap_soc_npu.log
#
# 【前置（必须已生成，否则 add_design 找不到文件）】
#   rtl/vexiiriscv/VexiiRiscv.v   ← bash scripts/gen_core.sh
#   rtl/YeshenSocGlue.v           ← 胶合生成器（md5 76f70e7ab013a23b47ae464f3fe9beab）
#   rtl/DDR3Bridge.v              ← build_ddr 后复制到 rtl/
#   y1/gen/NpuTop.v               ← cd y1 && printf 'Test/runMain NpuTopGen D:/code/PDS/VexiiYeshenLinux/y1/gen\nexit\n' | bash sbt.sh
#                                   （md5 9bc9ba6f821b36d1fe72079a3ed192e9）
#
# 【关键点】
#   · **不**出比特流、**不**跑 pnr、**不**碰板 —— 只 create_project -> add_design ->
#     compile -> synthesize -ads -> dev_map。
#   · `compile -verilog_standard SystemVerilog`：256bit 的 firtool 输出（DDR3Bridge）在
#     Verilog-2001 lowering 下会被静默误解 ⇒ 必须 SV（照抄 SoC 口径）。
#   · `dev_map -override_pcf false`：引脚以 FDC 为准。
#   · 若资源超限被 DRC 中止，则**不会**打印 Device Utilization Summary ⇒ 此时资源数必须
#     退回 `synthesize -ads` 的 Mapping Summary 与 GTP_* 行，并在报告里**说清用的是哪个来源**。
#
# 注：本文件的 puts 一律不写方括号（YeshenCore 踩过：puts 里的方括号会被 Tcl 当命令替换）。
# ============================================================================

set root "D:/code/PDS/VexiiYeshenLinux"

set tag "devmap_npu"
if {[info exists env(YESHENMINI_DEVMAP_TAG)]} { set tag $env(YESHENMINI_DEVMAP_TAG) }
set period "10.000"
if {[info exists env(YESHENMINI_DEVMAP_PERIOD)]} { set period $env(YESHENMINI_DEVMAP_PERIOD) }

set board_dir "$root/board"
set rtl_dir   "$root/rtl"
# 200H 版 DDR3 IP（与 NaxYeshenLinux 上板跑通那份同源）。
set ip_dir    "$root/third_party/ddr3_ip_200h/ddr3_test"

set project_name "yeshenmini_$tag"
set project_dir  "$root/sim/reglogs/pds_${tag}_p${period}"
set project_file "$project_dir/$project_name.pds"

puts "=== SoC+NPU dev_map：tag = $tag / cpu_clk period = $period ns ==="
puts "=== project = $project_file ==="

if {[file exists $project_dir]} {
    file delete -force $project_dir
}

create_project $project_file -synthesize_tool 2 -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

# ---- 板级顶层（top_module）----
add_design "$board_dir/yeshen_mini_board_top.v"

# ---- 板级组装层 + PLL ----
add_design "$board_dir/yeshen_mini_soc.v"
add_design "$board_dir/pll_100m_125m.v"

# ---- LiteEth 网卡：适配器层 + 生成的 MAC 黑盒 + 厂家 RGMII PHY 层 ----
add_design "$board_dir/liteeth_wrap.v"
add_design "$root/third_party/liteeth_mac/liteeth_mac_top.v"
add_design "$root/third_party/eth_stack_2_11/source/rgmii_interface.v"

# ---- 本项目的 RTL：核网表（VexiiRiscv）+ 胶合块（YeshenSocGlue）+ 内存桥（DDR3Bridge）----
add_design "$rtl_dir/vexiiriscv/VexiiRiscv.v"
add_design "$rtl_dir/YeshenSocGlue.v"
add_design "$rtl_dir/DDR3Bridge.v"

# ---- ★ 本工程相对 SoC 基线的**唯一**增补：Y1 NPU 网表 ----
#   C2.2 已把 NpuTop 并进 board/yeshen_mini_soc.v；板级顶层若要 elaborate，这个源必须在工程里。
add_design "$root/y1/gen/NpuTop.v"

# ---- 紫光同创 DDR3 IP（源文件清单照 pds/run_devmap_yeshen.tcl）----
add_design "$ip_dir/ddr3_test.idf"
add_design "$ip_dir/ddr3_test.v"
add_design "$ip_dir/ddr3_test_ddrphy_top.v"
add_design "$ip_dir/rtl/ips2l_rst_sync_v1_3.vp"
foreach f [glob -nocomplain "$ip_dir/rtl/ddrphy/*.vp"]   { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/ddrphy/*.v"]    { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/mcdq_ctrl/*.vp"] { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/mcdq_ctrl/*.v"]  { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/pll/*.vp"]      { add_design $f }

# ---- 约束（引脚 + 时钟 + CPD 落点，全在 constraints/yeshen_mini.fdc 里）----
add_constraint "$root/constraints/yeshen_mini.fdc"

puts "=== dev_map: compile ==="
compile -verilog_standard SystemVerilog

puts "=== dev_map: synthesize -ads ==="
synthesize -ads

puts "=== dev_map: dev_map（资源 + DRC）==="
dev_map -override_pcf false

puts "=== dev_map DONE（资源见 Device Utilization Summary；DRC 见 DRC-xxxx 行）==="
puts "YESHENMINI_DEVMAP_DONE"
