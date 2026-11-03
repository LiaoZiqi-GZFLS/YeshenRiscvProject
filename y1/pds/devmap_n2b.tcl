# ============================================================================
# devmap_n2b.tcl -- **Y1「NPU 独立时钟域」Task N2b** 的 dev_map 证据探针
#
# 本文件由 `y1/pds/devmap_n2.tcl` **逐条照抄**改核而来（同 N2：integrated 模式）：
#   器件行 / 源清单 / 约束 / compile 口径**一字不差**，只换：工程目录 tag、DONE 标记，
#   并在源清单里**加上新增的 `board/pll_50m.v`**（N2b 的第二颗 GTP_GPLL wrapper）。
#   另外：本工程跑完 dev_map 后**不再任何 PnR / 不出比特流**（与 task 书一致）。
#
# 【N2b 要读的三样证据（相对 N2 的差异见下）】
#   ① 约束检查（DRC）：`Found N error(s), …` + **0 error**；且 `create_clock {npu_clk}`
#      **不被报 object 找不到**。N2b 的约束条数应与 N2 **相同**（把 N2 的
#      `create_generated_clock {npu_clk}` 换成了 `create_clock {npu_clk}`，一换一，不是新增）。
#   ② 时钟表：**把 PDS 自己产出的 `synthesize_report_timing_clock_summary.db` 贴进日志**。
#      ⚠️ 与 N2 的关键差别：期望 **cpu_clk 10.0000ns（100MHz）** 与
#      **npu_clk 20.0000ns（50.0000MHz）** 同时在列，且 **npu_clk 的 Type = `Declared`、
#      Source 列为空**（= **不是** "Generated/Source=cpu_clk"）—— 那才是"独立钟"。
#      N2 时 npu_clk 是 `Generated / Source=cpu_clk / Target=u_npuclk_bufg/CLKOUT`（派生钟）；
#      N2b 应为 `Declared / Source=<空> / Target=u_pll_npu/u_gpll/CLKOUT0`（根钟）。
#   ③ 悬空清理证据：`npu_clk` 的**活体负载**（u_soc 里的 npu_clk 域翻转寄存器）必须**没被**清掉；
#      若被清掉，②里 npu_clk 也就不存在了（`Clock Load` 会消失）—— 这条是"脚手架是否真在起作用"
#      的正面证据。第二颗 PLL 的输出若无人用同样会被整条清理（`Public-4060 … is dangling`）。
#
# 【用法】（Windows 侧 pds_shell，工作目录必须是 D:/code/PDS/VexiiYeshenLinux）：
#   /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file \
#       D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_n2b.tcl > y1/pds/devmap_n2b.log 2>&1 ; echo "exit=$?"
#   grep -nE "Found [0-9]+ error|CLOCK-SUMMARY|Device Utilization Summary" -A 3 y1/pds/devmap_n2b.log
#
# 【N2b 实测读数（2026-10-11，两次连跑；日志 y1/pds/devmap_n2b.log 与 devmap_n2b_run1.log，
#   均不入库见 .gitignore 的 *.log）】
#   · dev_map 结果：`Design 'yeshen_mini_board_top' has been successfully mapped to
#     architecture-specific objects.`；`Action from compile to dev_map: Total Real Time elapsed is
#     0h:13m40s`（run1）/ `0h:14m10s`（run2）；完成标记 `Y1_N2B_DEVMAP_DONE` + `YESHENMINI_N2B_DEVMAP_DONE`。
#   · **约束检查（DRC）**：`Found 0 error(s), 0 critical warning(s), 20 warning(s), out of 696
#     constraint(s)` —— 与 N2（devmap_n2.log 同一行）**同为 696 条**（N2b 是"一换一"：把 N2 那条
#     `create_generated_clock {npu_clk}` 换成 `create_clock {npu_clk}`，**不是**新增约束）⇒ **无回归**。
#     两条 `C: Timing-4120 … should be a generated clock`（line 113 = cpu_clk、line 150 = npu_clk）是
#     **注释级提示**（cpu_clk 那条 N2 之前就在；npu_clk 现在与 cpu_clk 同姿 = create_clock 落 PLL 输出
#     脚，故同样触发）—— **不是 error**，本脚本不带任何 `E:` 行 ⇒ `scripts/check_devmap.py` PASS。
#   · **时钟表**（PDS 自己在 synthesize 阶段产出，本脚本原样贴进日志）：
#       `cpu_clk  Declared  10.0000  100.0000MHz  Rise 0.0000 Fall 5.0000  Clock Load 113393  Non-clock 0  Source=（根钟）  Target={ u_pll/u_gpll/CLKOUT0 }`
#       `npu_clk  Declared  20.0000   50.0000MHz  Rise 0.0000 Fall 10.0000 Clock Load 1     Non-clock 0  Source=（空）    Target={ u_pll_npu/u_gpll/CLKOUT0 }`
#     ⇒ **N2b 判据达成**：两个钟同时在列（100.000 / 50.000MHz），且 **npu_clk 的 Type = `Declared`、
#       `Source` 列为空**（**不是** N2 时的 `Generated / Source=cpu_clk / Target=u_npuclk_bufg/CLKOUT`）
#       —— 即它已是**独立钟**（建在**第二颗 PLL** 的输出脚 `u_pll_npu/u_gpll/CLKOUT0` 上）。
#       `Clock Load = 1` 就是那只防悬空的脚手架寄存器（`u_soc/npu_clk_alive_r`）——
#       它一旦被清掉，这一行（乃至本约束）就不存在了。
#   · **device_map 的时钟网清单**（同日志内 `device_map_clock_signal.db`）：
#       `Driver_Pin CLKOUT0 | Clk_Source_Inst u_pll_npu/u_gpll | Clk_Inst_Name u_npuclk_bufg | Net_Name npu_clk | Fanout 1`
#     ⇒ **第二颗 PLL + BUFG 都在网表里活着**，且 `npu_clk` 被工具认成一根**时钟网**（扇出 1 = 脚手架寄存器）。
#   · **确定性 2×**：两次连跑的 `synthesize 时钟表` + `Device Utilization Summary` + `Mapping Summary`
#     + DRC 行**逐字节相同**（本节下方脚本口径）。
#   · **面积读数的诚实标注**：本次 `Device Utilization Summary`（APM 540 / FF 119053 / LUT 100076 /
#     DRM 120 / IO 99）与 N2 的（APM 540 / FF 119054 / LUT 100078 / DRM 120）相比：
#       **FF −1**（= 删掉的 `npu_clk_div` 那只 cpu_clk 域触发器）、**LUT −2**（÷2 逻辑 + 扇出变化）；
#     **第二颗 GTP_GPLL 是硬宏**，**不占** APM/FF/LUT/DRM（故这几项没有"新增 PLL"的增量）。
#     ⇒ N2b 相对 N2 的代价 = **+1 颗 GTP_GPLL 硬核**（+1 个时钟根），FF/LUT 反而略降。
#
# 【前置（必须已生成/已改，否则 add_design 或约束检查会响）】
#   board/pll_50m.v              （N2b 新增：第二颗 GTP_GPLL，专出 50.000MHz）
#   board/yeshen_mini_board_top.v（N2b 改：删 ÷2 回退，换 u_pll_npu + BUFG）
#   board/yeshen_mini_soc.v      （N2 改；N2b 只改注释：npu_clk 入端口 + npu_clk_alive 出端口 + 活体寄存器）
#   constraints/yeshen_mini.fdc  （N2b 改：create_clock {npu_clk} 20ns + 异步组）
#   其余源与 c4a 档完全一致（rtl/ + DDR3 IP + LiteEth + y1/gen/NpuTop.v）。
#
# 注：本文件的 puts 一律不写方括号（YeshenCore 踩过：puts 里的方括号会被 Tcl 当命令替换）。
# ============================================================================

set root "D:/code/PDS/VexiiYeshenLinux"

set period "10.000"
if {[info exists env(YESHENMINI_DEVMAP_PERIOD)]} { set period $env(YESHENMINI_DEVMAP_PERIOD) }

set board_dir "$root/board"
set rtl_dir   "$root/rtl"
# 200H 版 DDR3 IP（与 NaxYeshenLinux 上板跑通那份同源）。
set ip_dir    "$root/third_party/ddr3_ip_200h/ddr3_test"

set project_name "yeshenmini_devmap_n2b"
set project_dir  "$root/sim/reglogs/pds_devmap_n2b_p${period}"
set project_file "$project_dir/$project_name.pds"

puts "=== Y1 N2b（npu_clk = 第二颗独立 PLL 出 50MHz）dev_map 探针：period = $period ns ==="
puts "=== project = $project_file ==="

if {[file exists $project_dir]} {
    file delete -force $project_dir
}

create_project $project_file -synthesize_tool 2 -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

# ---- 板级顶层（top_module）----
add_design "$board_dir/yeshen_mini_board_top.v"

# ---- 板级组装层 + 两颗板级 PLL ----
add_design "$board_dir/yeshen_mini_soc.v"
add_design "$board_dir/pll_100m_125m.v"
add_design "$board_dir/pll_50m.v"

# ---- LiteEth 网卡：适配器层 + 生成的 MAC 黑盒 + 厂家 RGMII PHY 层 ----
add_design "$board_dir/liteeth_wrap.v"
add_design "$root/third_party/liteeth_mac/liteeth_mac_top.v"
add_design "$root/third_party/eth_stack_2_11/source/rgmii_interface.v"

# ---- 本项目的 RTL：核网表（VexiiRiscv）+ 胶合块（YeshenSocGlue）+ 内存桥（DDR3Bridge）----
add_design "$rtl_dir/vexiiriscv/VexiiRiscv.v"
add_design "$rtl_dir/YeshenSocGlue.v"
add_design "$rtl_dir/DDR3Bridge.v"

# ---- Y1 NPU 网表（单文件，与 c4a 档同一份）----
add_design "$root/y1/gen/NpuTop.v"

# ---- 紫光同创 DDR3 IP（源文件清单照 devmap_c4a.tcl）----
add_design "$ip_dir/ddr3_test.idf"
add_design "$ip_dir/ddr3_test.v"
add_design "$ip_dir/ddr3_test_ddrphy_top.v"
add_design "$ip_dir/rtl/ips2l_rst_sync_v1_3.vp"
foreach f [glob -nocomplain "$ip_dir/rtl/ddrphy/*.vp"]   { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/ddrphy/*.v"]    { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/mcdq_ctrl/*.vp"] { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/mcdq_ctrl/*.v"]  { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/pll/*.vp"]      { add_design $f }

# ---- 约束（引脚 + 时钟，含 N2b 新的 create_clock {npu_clk}）----
add_constraint "$root/constraints/yeshen_mini.fdc"

puts "=== dev_map: compile ==="
compile -verilog_standard SystemVerilog

puts "=== dev_map: synthesize -ads ==="
synthesize -ads

puts "=== dev_map: dev_map（资源 + DRC）==="
dev_map -override_pcf false

# ---------------------------------------------------------------------------
# ★ N2b：把 **PDS 自己产出的时钟清单** 打进日志（这是 N2b 判据要的读数）
#   口径同 N2：**不用** `get_property -period`（dev_map 的 task 流程不留 Design Workspace
#   打开状态 ⇒ 会报 `E: UiCommand-0251`，既拿不到读数又污染 check_devmap.py）。
#   改用 PDS 在 **synthesize** 阶段自己生成的报告 DB（XML 文本，可直接读）：
#     · `synthesize_report_timing_clock_summary.db`  = **时钟表**（名字/类型/周期/源/端点数）
#     · `device_map_clock_signal.db`                = device_map 阶段的**时钟网**清单（含插钟信息）
#   期望：cpu_clk 周期 **10.0000**（100MHz）与 npu_clk 周期 **20.0000**（50MHz）**同时在列**，
#         且 npu_clk 的 Type = **Declared**、Source 为空（**独立钟**，不是 Generated/Source=cpu_clk）。
# ---------------------------------------------------------------------------
puts "=== N2b CLOCK-SUMMARY BEGIN（PDS 产物：synthesize 阶段时钟表）==="
set cs_dbs [list \
    "$project_dir/prj_tasks/syn_1/synthesize/report_db/synthesize_report_timing_clock_summary.db" \
    "$project_dir/prj_tasks/pnr_1/device_map/report_db/device_map_clock_signal.db" ]
foreach cs $cs_dbs {
    if {[file exists $cs]} {
        set fh [open $cs r]
        set body [read $fh]
        close $fh
        puts "---- REPORT FILE: $cs ----"
        puts $body
    } else {
        puts "---- REPORT FILE MISSING（本该由 PDS 生成）: $cs ----"
    }
}
puts "=== N2b CLOCK-SUMMARY END ==="

puts "=== dev_map DONE（资源见 Device Utilization Summary；DRC 见 DRC-xxxx 行）==="
puts "Y1_N2B_DEVMAP_DONE"
puts "YESHENMINI_N2B_DEVMAP_DONE"
