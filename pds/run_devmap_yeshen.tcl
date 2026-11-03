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
# 【用法】（Windows 侧 pds_shell，工作目录必须是 D:/code/PDS/VexiiYeshenLinux）：
#   /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file pds/run_devmap_yeshen.tcl \
#       2>&1 | tee sim/reglogs/m_yeshen_devmap.log
#   python scripts/check_devmap.py sim/reglogs/m_yeshen_devmap.log ; echo "rc=$?"
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

set root "D:/code/PDS/VexiiYeshenLinux"

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
# ★ 2026-10-29：D: 盘曾被 PnR 工程写满（59 个历史工程 36 GB）⇒ 允许用 YESHENMINI_RUN_DIR
# 把工程目录整体挪到别的盘（两个 tcl 用同一公式，devmap/pnr 才能对上）。
if {[info exists env(YESHENMINI_RUN_DIR)]} { set project_dir "$env(YESHENMINI_RUN_DIR)/pds_${tag}_p${period}" }
set project_file "$project_dir/$project_name.pds"

puts "=== 板级 dev_map（yeshen）：tag = $tag / cpu_clk period = $period ns ==="
puts "=== project = $project_file ==="

if {[file exists $project_dir]} {
    file delete -force $project_dir
}

create_project $project_file -synthesize_tool 2 -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

# ---- 板级顶层（top_module）----
add_design "$board_dir/yeshen_mini_board_top.v"
# ---- 软复位控制器（RST_CTRL → 20 ms sys_rstn，clk_in 域）----
add_design "$board_dir/rst_ctrl.v"

# ---- 板级组装层 + PLL ----
add_design "$board_dir/yeshen_mini_soc.v"
add_design "$board_dir/pll_100m_125m.v"
add_design "$board_dir/pll_50m.v"
# add_design "$board_dir/pll_gpu.v"   # ★ 2026-11-01 暂不使用（第五颗 GPLL 版本撞 PDS clock planning；改走 u_pll clkout1）
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
# ★ H2（2026-10-28）：以太网硬件读存服务（WB 主口 + 请求解析/组包 + DMA 取数）
add_design "$root/board/eth/eth_service.v"
add_design "$root/board/eth/eth_memread.v"
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

# ---- ★ 2026-10-31 GPU（P1）：2D 引擎 4 个 RTL 文件（手写；顶层 gpu_top 在 yeshen_mini_soc 里例化）----
add_design "$rtl_dir/gpu/gpu_top.v"
add_design "$rtl_dir/gpu/gpu_csr.v"
add_design "$rtl_dir/gpu/gpu_cmd.v"
add_design "$rtl_dir/gpu/gpu_2d.v"
add_design "$rtl_dir/gpu/gpu_3d.v"
add_design "$rtl_dir/gpu/tri_setup.v"
add_design "$rtl_dir/gpu/tri_raster.v"
add_design "$rtl_dir/gpu/gpu_mem.v"
add_design "$rtl_dir/gpu/gpu_clock_domain.v"
add_design "$rtl_dir/gpu/gpu_axil_cdc.v"
add_design "$rtl_dir/gpu/gpu_mem_cdc.v"

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
# ★ 2026-10-29：`YESHENMINI_*_PERIOD` 以前只改工程目录名/日志，**不改约束**（假旋钮）。
#   现在真的生效：period != 10.000 时把 fdc 复制一份、只替换 cpu_clk 的 period/waveform，
#   用副本做约束；仓库里那份 fdc 保持 10.000（= 真实 100 MHz）不动。
if {$period eq "10.000"} {
    add_constraint "$root/constraints/yeshen_mini.fdc"
} else {
    set ovc_fi [open "$root/constraints/yeshen_mini.fdc" r]
    set ovc_txt [read $ovc_fi]
    close $ovc_fi
    set ovc_half [format "%.3f" [expr {$period / 2.0}]]
    set ovc_n [regsub {create_clock -name \{cpu_clk\}\s+\[get_pins \{u_pll_cpu/u_gpll/CLKOUT0\}\]\s+-period \{[0-9.]+\}\s+-waveform \{0 [0-9.]+\}} \
        $ovc_txt "create_clock -name {cpu_clk} \[get_pins {u_pll_cpu/u_gpll/CLKOUT0}\] -period {$period} -waveform {0 $ovc_half}" ovc_txt]
    if {$ovc_n != 1} { error "过约束：fdc 里 cpu_clk 那行没匹配到（n=$ovc_n）" }
    set ovc_path "$root/sim/reglogs/yeshen_mini_ovc_${period}.fdc"
    set ovc_fo [open $ovc_path w]
    puts $ovc_fo $ovc_txt
    close $ovc_fo
    add_constraint $ovc_path
    puts "=== 过约束：cpu_clk period = $period ns（约束用副本 $ovc_path）==="
}

puts "=== dev_map: compile ==="
# 与已知-good 参考（YeshenCore/run_bringup_devmap.tcl）对齐：显式用 SystemVerilog 标准。
#   256bit 的 firtool 输出在 Verilog-2001 lowering 下会被静默误解（本设计的 DDR3Bridge 正是
#   256bit firtool 输出）⇒ 必须 SV。
compile -verilog_standard SystemVerilog

# ★ 2026-10-28：两个综合旋钮（搬自 CPU 频率战役 soc_pnr_108，那边实测有效）——
#   YESHENMINI_NORES=1   ⇒ `-resource_sharing FALSE`（核级实测 +0.95% fmax）
#   YESHENMINI_FANOUT=28 ⇒ `-fanout_guide 28`（头号违例末端 fanout19 那条网）
#   缺省不传 ⇒ 与原行为逐字相同（可复现性不受影响）。
set syn_args ""
if {[info exists env(YESHENMINI_NORES)] && $env(YESHENMINI_NORES) == "1"} {
    set syn_args "$syn_args -resource_sharing FALSE"
}
if {[info exists env(YESHENMINI_FANOUT)]} {
    set syn_args "$syn_args -fanout_guide $env(YESHENMINI_FANOUT)"
}
puts "=== dev_map: synthesize -ads $syn_args ==="
if {$syn_args == ""} { synthesize -ads } else { synthesize -ads {*}$syn_args }

puts "=== dev_map: dev_map（资源 + DRC）==="
dev_map -override_pcf false

puts "=== dev_map DONE（资源见 Device Utilization Summary；DRC 见 DRC-xxxx 行）==="
puts "YESHENMINI_DEVMAP_DONE"
