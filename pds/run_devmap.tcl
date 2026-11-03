# ============================================================================
# run_devmap.tcl -- Task 14：**板级一整套**设计的 dev_map（资源 + DRC 预检）
#
# 只做 create_project -> add_design(全部源) -> compile -> synthesize -ads -> dev_map，
# **不**出比特流、**不**跑 pnr（那两步见 Task 15 / run_pnr.tcl）。
#
# 用法（Windows 侧 pds_shell，工作目录必须是 D:/code/PDS/NaxYeshenLinux）：
#   /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file pds/run_devmap.tcl \
#       2>&1 | tee sim/reglogs/m3_devmap.log
#   python scripts/check_devmap.py sim/reglogs/m3_devmap.log ; echo "rc=$?"
#
# 环境变量（可省）：
#   NAXMINI_DEVMAP_TAG     工程标签，只用于区分工程目录（默认 devmap）
#   NAXMINI_DEVMAP_PERIOD  cpu_clk 周期（ns），默认 10.000 = 100MHz **真实值**。
#                          8.0 = 过约束（125MHz）探余量，与既有实践一致。
#
# 结构照 pds/run_probe_fabric.tcl（本工程已跑通的那份）+ NaxYeshenSoC/pds/run_nax_devmap.tcl
# （同器件同 DDR3 IP 的那份，**DDR3 IP 的源文件清单与 glob 写法逐行照抄它** —— 它已经
#  在 PG2L200H/FBB676 上跑通；`rtl/mcdq_ctrl/syn_mod/*` 与 `distributed_fifo/rtl/*`
#  不在它的清单里，说明那些文件对综合无用（漏加会变成"找不到模块"，那条路已被证伪））。
#
# 关键点：
#   * 设计源 = 板级顶层 + 组装层 + PLL + 本项目 rtl + 紫光 DDR3 IP 全套。顶层只有
#     `clk_in`(27M) / `ref_clk_p`(125M 差分) 两个时钟输入；时钟约束全在
#     constraints/nax_mini.fdc 里（RTL 里没有任何 `create_clock`）。
#   * **必须**带 rtl/vendor 的两个文件（否则 compile 报几百条
#     Cannot find file containing module 'Ram_1w_1ra'）：RamXilinx.v / Ram_1w_1ra.v。
#   * 工程目录放在 sim/reglogs/ 下（该目录按计划入 .gitignore，工程 DB 不入库）。
#   * `dev_map -override_pcf false`：引脚以 FDC 为准，不允许 PCF 覆盖。
#
# 注：本文件的 puts 一律不写方括号（YeshenCore 踩过：puts 里的方括号会被 Tcl 当命令替换）。
# ============================================================================

set root "D:/code/PDS/NaxYeshenLinux"

set tag "devmap"
if {[info exists env(NAXMINI_DEVMAP_TAG)]} { set tag $env(NAXMINI_DEVMAP_TAG) }
set period "10.000"
if {[info exists env(NAXMINI_DEVMAP_PERIOD)]} { set period $env(NAXMINI_DEVMAP_PERIOD) }

set board_dir "$root/board"
set rtl_dir   "$root/rtl"
# ★ 2026-10-02：**换 200H 版 DDR3 IP**（原来指向 100H 版）。
#   依据（200mini 板级 bring-up 实测）：PG2L100H 的 DDR3 PHY 生成物装到 PG2L200H 上，PLL 能锁但
#   DQ/DQS 焊盘映射与校准按 100H 走 ⇒ `ddr_init_done` 恒 0 ⇒ 本顶层把它当复位门控（见
#   board/nax_mini_board_top.v 文件头【3】）⇒ SoC 被扣复位 ⇒ 串口 0 字节。A/B 只换该 IP 即 D1+AXI 流动。
#   来源 = 官方 4_10（200H MINI，硬件验证过）那份的自包含副本（YeshenCore/ddr3_ip_200h，未改原件）。
#   ⚠️ `third_party/` 不入库 ⇒ **换版靠本行留痕**，IP 目录本身按上面路径自备。
set ip_dir    "$root/third_party/ddr3_ip_200h/ddr3_test"

set project_name "naxmini_$tag"
set project_dir  "$root/sim/reglogs/pds_${tag}_p${period}"
set project_file "$project_dir/$project_name.pds"

puts "=== Task 14 板级 dev_map：tag = $tag / cpu_clk period = $period ns ==="
puts "=== project = $project_file ==="

if {[file exists $project_dir]} {
    file delete -force $project_dir
}

create_project $project_file -synthesize_tool 2 -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

# ---- 板级顶层（top_module）----
add_design "$board_dir/nax_mini_board_top.v"

# ---- 板级组装层 + PLL ----
# TCP 线副本（含 SD WIP 基线）；原件 nax_mini_soc.v 勿与副本同时 add_design（模块名同为 nax_mini_soc）
add_design "$board_dir/nax_mini_soc_tcp.v"
add_design "$board_dir/pll_100m_125m.v"

# ---- 本项目的 RTL（核网表 / 胶合块 / 内存桥 + 两个黑盒 RAM 模型）----
add_design "$rtl_dir/NaxSocMini.v"
add_design "$rtl_dir/NaxMiniGlue_tcp.v"   # TCP line: pre-LiteEth Glue copy (io_eth_* port surface); HEAD NaxMiniGlue.v is the LiteEth line's
add_design "$rtl_dir/DDR3Bridge.v"
add_design "$rtl_dir/vendor/RamXilinx.v"
add_design "$rtl_dir/vendor/Ram_1w_1ra.v"

# ---- 紫光同创 DDR3 IP（源文件清单照 NaxYeshenSoC/pds/run_nax_devmap.tcl）----
add_design "$ip_dir/ddr3_test.idf"
add_design "$ip_dir/ddr3_test.v"
add_design "$ip_dir/ddr3_test_ddrphy_top.v"
add_design "$ip_dir/rtl/ips2l_rst_sync_v1_3.vp"
foreach f [glob -nocomplain "$ip_dir/rtl/ddrphy/*.vp"]   { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/ddrphy/*.v"]    { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/mcdq_ctrl/*.vp"] { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/mcdq_ctrl/*.v"] { add_design $f }
foreach f [glob -nocomplain "$ip_dir/rtl/pll/*.vp"]      { add_design $f }

# ---- 约束（引脚 + 时钟 + CPD 落点，全在 constraints/nax_mini.fdc 里）----
# ---- 以太网装载器：厂家 UDP/IP/MAC 栈（第三方独立副本）+ 我们的薄包装 ----
# ⚠️ 排除厂家的 demo 顶层 `ethernet_test.v` 与其周期发送 FSM `eth_udp_test.v`：
#    我们的 `eth_mac_wrapper.v` 直接例化 `udp_ip_mac_top`（纯接收 + ARP 应答）。
set eth_dir "$root/third_party/eth_stack_2_11"
foreach f [lsort [glob -nocomplain "$eth_dir/source/*.v"]] {
    set b [file tail $f]
    if {$b eq "ethernet_test.v" || $b eq "eth_udp_test.v"} { continue }
    add_design $f
}
foreach f [lsort [glob -nocomplain "$eth_dir/source/*.vh"]] { add_design $f }
# TCP 线副本：模块已改名 eth_mac_wrapper_tcp；原件 eth_mac_wrapper.v 不入本工程（保持单一拓扑）
add_design "$rtl_dir/eth_tcp_glue/eth_mac_wrapper_tcp.v"
# ---- eth_tcp_glue 9 个模块（TCP 分支线；显式清单，不 glob 以免与 wrapper 副本重复 add_design）----
add_design "$rtl_dir/eth_tcp_glue/eth_frame_rx.v"
add_design "$rtl_dir/eth_tcp_glue/eth_frame_tx.v"
add_design "$rtl_dir/eth_tcp_glue/gmii_tx_arbiter.v"
add_design "$rtl_dir/eth_tcp_glue/stream_group_mux.v"
add_design "$rtl_dir/eth_tcp_glue/shim_gate_sync.v"
add_design "$rtl_dir/eth_tcp_glue/tcp_frame_shim.v"
add_design "$rtl_dir/eth_tcp_glue/ip_min.v"
add_design "$rtl_dir/eth_tcp_glue/tcp_engine.v"
add_design "$rtl_dir/eth_tcp_glue/eth_tcp_wrapper.v"
add_design "$eth_dir/ipcore/icmp_rx_ram_8_256/icmp_rx_ram_8_256.idf"
add_design "$eth_dir/ipcore/udp_shift_register/udp_shift_register.idf"
add_design "$eth_dir/ipcore/ref_clock/ref_clock.idf"

add_constraint "$root/constraints/nax_mini.fdc"

# ⚠️ cpu_clk 的周期已经在 fdc 里写了（10.000ns）。这里**不再**重复 create_clock：
#    PDS 对同一对象建两次钟只会多一份同名/异名时钟，容易把后面的 set_clock_groups 搞乱。
#    要过约束探余量就把 fdc 里那一行改成 8.0（或设 NAXMINI_DEVMAP_PERIOD=8.0 只改工程目录名）。

puts "=== dev_map: compile ==="
# ★ 2026-10-03：与已知-good 参考（YeshenCore/run_bringup_devmap.tcl）对齐，**显式用 SystemVerilog 标准**。
#   原因：256bit 的 firtool 输出在 PDS 的 Verilog-2001 lowering 下会被**静默误解**（参考那边也是为此写 SV）；
#   本设计的 DDR3Bridge 正是 256bit firtool 输出 ⇒ 2001 模式下桥到 DDR 控制器的 AXI 会错，
#   上板症状 = "PHY PLL 锁住（硬读数 C1，core_clk 在翻转）但 ddr_init_done 恒 0（D0）"。
compile -verilog_standard SystemVerilog

puts "=== dev_map: synthesize -ads ==="
synthesize -ads

puts "=== dev_map: dev_map（资源 + DRC）==="
dev_map -override_pcf false

puts "=== dev_map DONE（资源见 Device Utilization Summary；DRC 见 DRC-xxxx 行）==="
puts "NAXMINI_DEVMAP_DONE"
