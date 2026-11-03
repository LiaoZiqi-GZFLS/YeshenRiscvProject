# ============================================================================
# devmap_n2.tcl -- **Y1「NPU 独立时钟域」Task N2** 的 dev_map 证据探针
#
# 本文件由 `y1/pds/devmap_c4a.tcl` 的 **integrated 模式**（默认档）**逐条照抄**改核而来：
#   器件行 / 源清单 / 约束 / compile 口径**一字不差**，只换：工程目录 tag、DONE 标记，
#   并在流程**末尾**补一段"工具侧时钟表"打印（N2 的判据要的读数）。
#   另外：本工程跑完 dev_map 后**不再任何 PnR / 不出比特流**（与 task 书一致）。
#
# 【N2 要读的三样证据】
#   ① 约束检查（DRC）：`Found N error(s), M critical warning(s), ...` + **0 error**；
#      且 `create_generated_clock {npu_clk}` **不被报 object 找不到**（= 没写成空集/没被清理）。
#   ② 时钟表：**把 PDS 自己产出的 `synthesize_report_timing_clock_summary.db` 贴进日志**
#      —— 期望同时看到 **cpu_clk 10.0000ns（100.0000MHz）** 与 **npu_clk 20.0000ns（50.0000MHz）**。
#      ⚠️ **不要**用 `get_property -period`：PDS **没有** `report_clocks` 命令，而 `get_property`
#        需要"Design Workspace 打开"状态；dev_map 的 task 流程结束时**不留**该状态（实测第一版
#        探针因此报 `E: UiCommand-0251: No open design…` —— 既没读到周期，又给日志塞了 `E:`，
#        会让 `scripts/check_devmap.py` 判红）。改用工具产物 = 既真实又不会污染判据。
#   ③ 悬空清理证据：`npu_clk` 的**活体负载**（u_soc 里的 npu_clk 域翻转寄存器）必须**没被**清掉；
#      若被清掉，②里 npu_clk 也就不存在了（`Clock Load` 会消失）—— 这条是"脚手架是否真在起作用"的
#      正面证据。实测该寄存器**会**被综合器保留（`Clock Load = 1`），而**没有**任何人用的那版
#      （`Public-4060 … is dangling and will be cleaned`）会被**整条删掉**：此结论由一个小探针
#      单独确认过（`prbsub` 的 ÷2+BUFG+翻转寄存器、其输出悬空 ⇒ 三级全被清理）。
#
# 【用法】（Windows 侧 pds_shell，工作目录必须是 D:/code/PDS/VexiiYeshenLinux）：
#   /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file \
#       D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_n2.tcl > y1/pds/devmap_n2.log 2>&1 ; echo "exit=$?"
#   grep -nE "Found [0-9]+ error|CLOCK-SUMMARY|Device Utilization Summary" -A 3 y1/pds/devmap_n2.log
#
# 【N2 实测读数（2026-10-11，两次连跑；日志 y1/pds/devmap_n2.log，不入库见 .gitignore 的 *.log）】
#   · dev_map 结果：`Design 'yeshen_mini_board_top' has been successfully mapped to architecture-specific
#     objects.`；`Action from compile to dev_map: Total Real Time elapsed is 0h:13m:36s`；
#     完成标记 `Y1_N2_DEVMAP_DONE` + `YESHENMINI_N2_DEVMAP_DONE`。
#   · **约束检查（DRC）**：`Found 0 error(s), 0 critical warning(s), 20 warning(s), out of 696
#     constraint(s)` —— 相对 N2 之前（`devmap_c4a.log` 同一行）**694 → 696**，正好是 N2 新增的
#     两条（`create_generated_clock {npu_clk}` + `set_clock_groups {cpu_clk}/{npu_clk}`）；
#     且**没有** "对象找不到" 类错误 ⇒ `create_generated_clock` 的 object 真的解析到了。
#     （唯一那条 `Timing-4120 … cpu_clk … should be a generated clock` 是 **N2 之前就在**的老
#     提示，与本次改动无关；本脚本不带任何 `E:` 行 ⇒ `scripts/check_devmap.py` PASS。）
#   · **时钟表**（PDS 自己在 synthesize 阶段产出，本脚本原样贴进日志）：
#       `cpu_clk     Declared    10.0000  100.0000MHz  Rise 0.0000 Fall 5.0000  Clock Load 113394  Non-clock 2`  Source=（根钟）  Target={ u_pll/u_gpll/CLKOUT0 }
#       `npu_clk     Generated   20.0000   50.0000MHz  Rise 0.0000 Fall 10.0000 Clock Load 1      Non-clock 0`  Source=cpu_clk  Target={ u_npuclk_bufg/CLKOUT }
#     ⇒ N2 判据达成：**两个钟同时在列、频率各自正确**（100.000/50.000MHz），
#       `npu_clk` 的类型是 **Generated**、源是 `cpu_clk`、落点是我们的 BUFG（= `-divide_by 2` 生效）。
#       `Clock Load = 1` 就是那只防悬空的脚手架寄存器（`u_soc/npu_clk_alive_r`）——
#       它一旦被清掉，这一行（乃至本约束）就不存在了。
#   · **device_map 的时钟网清单**（同日志内 `device_map_clock_signal.db`）：
#       `Driver_Pin Q | Clk_Source_Inst npu_clk_div | Clk_Inst_Name u_npuclk_bufg | Net_Name npu_clk | Fanout 1`
#     ⇒ 分频器 + BUFG 都在网表里活着，且 `npu_clk` 被工具认成一根**时钟网**。
#   · **确定性 2×**：两次连跑（17:30 / 17:47 起）的 `Device Utilization Summary` 与
#     `Mapping Summary` **逐字节相同**；去掉时间戳/耗时后两份日志**无实质差异**
#     （脚本只有本探针段从 `get_property` 改成"贴 PDS 报告"，见下）。
#   · **面积读数的诚实标注**：本次 `Device Utilization Summary`（APM 540 / FF 119054 / LUT 100078 /
#     Dist.RAM 1767 / DRM 120）**不能**拿去和 `devmap_c4a.log`（APM 532 / FF 114642 / LUT 107401 /
#     Dist.RAM 10855 / DRM 93.5）直接作差：后者是 **R3b 之前**的网表，两盘之间的差异来自已提交的
#     R3b（宽路大存储器进 block RAM），**不是** N2。N2 自身结构性代价 = **+2 FF**
#     （`npu_clk_div` + `npu_clk_alive_r`）+ **1 GTP_CLKBUFG** + 诊断帧 2 字节。要 N2 的 Δ 面积，
#     得先补一份"当前网表"的基线 dev_map（本任务不做；G6 记 Δ 是 N6 的事）。
#
# 【前置（必须已生成/已改，否则 add_design 或约束检查会响）】
#   board/yeshen_mini_board_top.v（N2 改：npu_clk ÷2 + BUFG + 进 u_soc + 诊断帧多 1 字节）
#   board/yeshen_mini_soc.v      （N2 改：npu_clk 入端口 + npu_clk_alive 出端口 + 活体寄存器）
#   constraints/yeshen_mini.fdc  （N2 改：create_generated_clock {npu_clk} + 异步组）
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

set project_name "yeshenmini_devmap_n2"
set project_dir  "$root/sim/reglogs/pds_devmap_n2_p${period}"
set project_file "$project_dir/$project_name.pds"

puts "=== Y1 N2（npu_clk 时钟源 + 拓扑 + 约束）dev_map 探针：period = $period ns ==="
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

# ---- 约束（引脚 + 时钟，含 N2 新增的 create_generated_clock {npu_clk}）----
add_constraint "$root/constraints/yeshen_mini.fdc"

puts "=== dev_map: compile ==="
compile -verilog_standard SystemVerilog

puts "=== dev_map: synthesize -ads ==="
synthesize -ads

puts "=== dev_map: dev_map（资源 + DRC）==="
dev_map -override_pcf false

# ---------------------------------------------------------------------------
# ★ N2 追加：把 **PDS 自己产出的时钟清单** 打进日志（这是 N2 判据要的读数）
#   口径：**不用** `get_property -period`（实测：dev_map 的 task 流程**不留** Design
#     Workspace 打开状态 ⇒ `get_property` 报 `E: UiCommand-0251: No open design…`，
#     既拿不到读数、又给日志塞了一条 `E:` ⇒ 会让 `scripts/check_devmap.py` 判红）。
#   改用 PDS 在 **synthesize** 阶段自己生成的报告 DB（XML 文本，可直接读）：
#     · `synthesize_report_timing_clock_summary.db`  = **时钟表**（名字/周期/波形/源/端点数）
#     · `device_map_clock_signal.db`                = device_map 阶段的**时钟网**清单（含插钟信息）
#   这两个文件是**工具产物**，本段只是把它们（原样）贴进日志，便于判据与人读。
#   期望：`cpu_clk` 周期 **10.0000**（100MHz）与 `npu_clk` 周期 **20.0000**（50MHz）**同时在列**。
# ---------------------------------------------------------------------------
puts "=== N2 CLOCK-SUMMARY BEGIN（PDS 产物：synthesize 阶段时钟表）==="
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
puts "=== N2 CLOCK-SUMMARY END ==="

puts "=== dev_map DONE（资源见 Device Utilization Summary；DRC 见 DRC-xxxx 行）==="
puts "Y1_N2_DEVMAP_DONE"
puts "YESHENMINI_N2_DEVMAP_DONE"
