# ============================================================================
# run_devmap_yeshen.tcl -- **板级一整套**设计的 dev_map（资源 + DRC 预检）
#
# 只做 create_project -> add_design(全部源) -> compile -> synthesize -ads -> dev_map，
# **不**出比特流、**不**跑 pnr（那两步见同目录 run_pnr_yeshen.tcl）。
#
# 由 NaxYeshenLinux 的 pds/run_devmap_sd.tcl 改核而来：
#   顶层  nax_mini_board_top → yeshen_mini_board_top
#   组装  nax_mini_soc       → yeshen_mini_soc（VexiiRiscv + YeshenSocGlue）
#   约束  nax_mini.fdc       → yeshen_mini.fdc
#   器件行 / `compile -verilog_standard SystemVerilog` / 引脚口径 **全部照抄**。
#
# ---------------------------------------------------------------------------
# 【用法】（Windows 侧 pds_shell，工作目录必须是 D:/code/PDS/YeshenGuiTouch）：
#   /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file pds/run_devmap_yeshen.tcl \
#       2>&1 | tee sim/reglogs/m_yeshen_devmap.log
#   # 判据：Device Utilization Summary / DRC-xxxx / YESHENMINI_DEVMAP_DONE
#
# 本文件是 YeshenGui Phase R 的独立 RTL 副本（基线 VexiiYeshenLinux 212d3a2），
# 只引用 D:/code/PDS/YeshenGuiTouch 下的源文件；不改、不读原工程的 .pds 工程目录。
#
# 【环境变量（可省）】
#   YESHENMINI_DEVMAP_TAG     工程标签，只用于区分工程目录（默认 devmap）
#   YESHENMINI_DEVMAP_PERIOD  cpu_clk 周期（ns），默认 10.000 = 100MHz **真实值**。
#                             8.0 = 过约束（125MHz）探余量，与既有实践一致。
#                             ⚠️ 本脚本**只把它写进工程目录名**；真正的周期在 fdc 里
#                                （要过约束就改 fdc 那一行，或设本变量只改目录名）。
#
# 【前置（必须先生成，否则 add_design 找不到文件）】
#   rtl/vexiiriscv/VexiiRiscv.v   ← bash scripts/gen_core.sh
#   rtl/YeshenSocGlue.v           ← 胶合生成器（scala-cli / firtool，见 src/）
#   rtl/DDR3Bridge.v              ← java -cp YeshenSocGlue.jar DDR3Bridge build_ddr
#                                   后**复制**到 rtl/DDR3Bridge.v（本流程按 rtl/ 路径引用；
#                                   build_*/ 在 .gitignore 里，不入库）
#   （三者均已生成：核网表 24,528 行 / 胶合 4,246 行 / 内存桥 698 行）
#
# 【关键点】
#   * 设计源 = 板级顶层 + 组装层 + PLL + 核网表 + 胶合块 + 内存桥 + LiteEth + 紫光 DDR3 IP 全套。
#     顶层只有 `clk_in`(27M) / `ref_clk_p`(125M 差分) 两个时钟输入；时钟约束全在
#     constraints/yeshen_mini.fdc 里（RTL 里没有任何 create_clock）。
#   * vendor RAM 黑盒（rtl/vendor/RamXilinx.v / Ram_1w_1ra.v）**本工程不再需要**：
#     模板带它们是因为 NaxSocMini（SpinalHDL）里例化了 `Ram_1w_1ra`；本工程核换成
#     VexiiRiscv（RAM 直接推成 `reg` 数组，无厂商黑盒），且 `grep` 证实
#     VexiiRiscv.v / YeshenSocGlue.v / DDR3Bridge.v 都不引用 Ram_1w_1ra / RamXilinx。
#     ⇒ 不加入本清单（若综合日志出现 `Cannot find ... 'Ram_1w_1ra'` 再从 NaxYeshenLinux 复制）。
#   * 工程目录放在 sim/reglogs/ 下（该目录按计划入 .gitignore，工程 DB 不入库）。
#   * `dev_map -override_pcf false`：引脚以 FDC 为准，不允许 PCF 覆盖。
#
# 注：本文件的 puts 一律不写方括号（YeshenCore 踩过：puts 里的方括号会被 Tcl 当命令替换）。
# ============================================================================

set root "D:/code/PDS/YeshenGuiTouch"

set tag "devmap"
if {[info exists env(YESHENMINI_DEVMAP_TAG)]} { set tag $env(YESHENMINI_DEVMAP_TAG) }
set period "10.000"
if {[info exists env(YESHENMINI_DEVMAP_PERIOD)]} { set period $env(YESHENMINI_DEVMAP_PERIOD) }

set board_dir "$root/board"
set rtl_dir   "$root/rtl"
# 200H 版 DDR3 IP（与 NaxYeshenLinux 上板跑通那份同源；PG2L100H 的 PHY 装到 200H 会
# 让 ddr_init_done 恒 0 ⇒ 本顶层把它当复位门控 ⇒ SoC 被扣复位 ⇒ 串口 0 字节）。
set ip_dir    "$root/third_party/ddr3_ip_200h/ddr3_test"

set project_name "yeshenmini_$tag"
set project_dir  "$root/sim/reglogs/pds_${tag}_p${period}"
set project_file "$project_dir/$project_name.pds"

puts "=== 板级 dev_map（yeshen）：tag = $tag / cpu_clk period = $period ns ==="
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
add_design "$board_dir/pll_50m.v"
add_design "$board_dir/pll_cpu.v"
add_design "$board_dir/dcfifo.v"
add_design "$board_dir/axi4_cdc_fetch.v"
add_design "$board_dir/axi4_cdc_lsu.v"
add_design "$board_dir/axi4_cdc_io.v"
add_design "$board_dir/cpu_domain_cdc.v"

# ---- ★ V1（2026-10-20，Task 7）：视频链（相机 → 裁列 → 帧存 → LCD → overlay）+ 仲裁器 + 寄存器 ----
#   · 厂家资产（board/cam/vendor，Task 1 零改动复制，见 PROVENANCE.md）：camera 三件
#     （camera / camera_data / **SCCB + data_init** —— 后两件是 camera.v 的直接子模块，
#      漏掉会在综合期报"Cannot find module"）、tutorial 教程族 8 件、sync_vg、两个 framing IP。
#   · framing IP 的 `rtl/*.v` 里除了 sdpram 包装，还有两个**纯 localparam 片段**
#     （*_Reset_Value.v / *_init_param.v）—— 与厂家 PDS 工程的文件清单一致，照清单收。
#   · **禁止**加入仿真替身：`pll_80m.v` / `stub_rambuf*.v` / `stub_rd_fram_buf.v`
#     （那些只在 sim/video 的 iverilog TB 里用，进综合会造出重复的 PLL/RAM 模型）。
add_design "$root/board/cam/video_passthrough.v"
add_design "$root/board/cam/overlay.v"
add_design "$root/board/cam/video_regs.v"
add_design "$root/board/cam/ddr_arbiter_2to1.v"
# 双目切换（2026-10-27）：两路相机 mux/掐写/黑屏 + KEY 消抖
add_design "$root/board/cam/cam_switch.v"
add_design "$root/board/cam/key_toggle.v"
add_design "$root/board/pll_lcd.v"
add_design "$root/board/cam/vendor/camera/camera.v"
add_design "$root/board/cam/vendor/camera/camera_data.v"
add_design "$root/board/cam/vendor/camera/SCCB.v"
add_design "$root/board/cam/vendor/camera/data_init.v"
foreach f [glob -nocomplain "$root/board/cam/vendor/tutorial/*.v"] { add_design $f }
add_design "$root/board/cam/vendor/sync_vg.v"
add_design "$root/board/cam/vendor/ip/wr_fram_buf/wr_fram_buf.v"
foreach f [glob -nocomplain "$root/board/cam/vendor/ip/wr_fram_buf/rtl/*.v"] { add_design $f }
add_design "$root/board/cam/vendor/ip/rd_fram_buf/rd_fram_buf.v"
foreach f [glob -nocomplain "$root/board/cam/vendor/ip/rd_fram_buf/rtl/*.v"] { add_design $f }

# ---- LiteEth 网卡：适配器层 + 生成的 MAC 黑盒 + 厂家 RGMII PHY 层 ----
#   ⚠️ RGMII PHY **只**要 `rgmii_interface.v` 这一个文件（厂家 2_11 栈里其余全不要）：
#      它自带 GTP_ODDR_E1/IDDR_E1/IODELAY_E2/INBUF/OUTBUF/CLKBUFG —— 板上已跑通的配方。
add_design "$board_dir/liteeth_wrap.v"
add_design "$root/third_party/liteeth_mac/liteeth_mac_top.v"
add_design "$root/third_party/eth_stack_2_11/source/rgmii_interface.v"

# ---- 本项目的 RTL：核网表（VexiiRiscv）+ 胶合块（YeshenSocGlue）+ 内存桥（DDR3Bridge）----
add_design "$rtl_dir/vexiiriscv/VexiiRiscv.v"
add_design "$rtl_dir/YeshenSocGlue.v"
add_design "$rtl_dir/DDR3Bridge.v"
# ---- Y1 NPU 生成网表（2026-10-17：与 PnR 的 sources_info.log 对齐；旧 devmap 列表漏了这 6 件）----
add_design "$root/y1/gen/NpuTop.v"
add_design "$root/y1/gen/DmaEngine.v"
add_design "$root/y1/gen/NpuAxiLiteCdc.v"
add_design "$root/y1/gen/NpuMemCdc.v"
add_design "$root/y1/gen/NpuIrqCdc.v"
add_design "$root/y1/gen/NpuResetSync.v"

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

# ---- 约束（引脚 + 时钟 + CPD 落点，全在 constraints/yeshen_mini.fdc 里）----
add_constraint "$root/constraints/yeshen_mini.fdc"

# ⚠️ cpu_clk 的周期已经在 fdc 里写了（10.000ns）。这里**不再**重复 create_clock：
#    PDS 对同一对象建两次钟只会多一份同名/异名时钟，容易把后面的 set_clock_groups 搞乱。
#    要过约束探余量就把 fdc 里那一行改成 8.0（或设 YESHENMINI_DEVMAP_PERIOD=8.0 只改工程目录名）。

puts "=== dev_map: compile ==="
# 与已知-good 参考（YeshenCore/run_bringup_devmap.tcl）对齐：显式用 SystemVerilog 标准。
#   256bit 的 firtool 输出在 Verilog-2001 lowering 下会被静默误解（本设计的 DDR3Bridge 正是
#   256bit firtool 输出）⇒ 必须 SV。
compile -verilog_standard SystemVerilog

puts "=== dev_map: synthesize -ads ==="
synthesize -ads

puts "=== dev_map: dev_map（资源 + DRC）==="
dev_map -override_pcf false

puts "=== dev_map DONE（资源见 Device Utilization Summary；DRC 见 DRC-xxxx 行）==="
puts "YESHENMINI_DEVMAP_DONE"
