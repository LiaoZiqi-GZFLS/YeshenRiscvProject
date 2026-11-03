# ============================================================================
# flash_yeshen.tcl -- 烧本工程的比特流（yeshen_mini_board_top）。
#
# 前置（可选）：TF 卡判卡脚本 flash_tfref.tcl 未随本独立 RTL 副本复制
#   （它烧的是原工程的参考比特流，见 VexiiYeshenLinux/pds/flash_tfref.tcl）。
#
# 比特流路径按 TAG 拼（gen_bit_stream 的产出位置）：
#   sim/reglogs/pds_<TAG>_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit
# 环境变量 YESHENMINI_TAG 选哪一轮的带。
#   m9 = **rx 槽 2→4**（修背靠背突发丢包）那版；m8 = LiteEth dw=32（TX 饿空修复）+ dropbear 镜像那版；
#   m3 = 修好 UARTRx 丢背靠背字节 + UARTTx 多余校验位的那版（E1 控制台修复）；m1 = 旧带。
set tag "m9"
if {[info exists env(YESHENMINI_TAG)]} { set tag $env(YESHENMINI_TAG) }
set sbit "D:/code/PDS/YeshenGuiTouch/sim/reglogs/pds_${tag}_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit"
puts "=== flash: tag=$tag sbit=$sbit ==="
if {[file exists $sbit] == 0} { puts "!!! 比特流不存在：$sbit"; error "no sbit" }
#
# ⚠️ port 必须是 cdt_js.exe 自报的 `use port : XXXXX`（65420 是历史值）。
# 环境变量 YESHENMINI_JTAG_PORT 覆盖（缺省 65420，与 YESHENMINI_TAG 同一手法）：
#   某些开机档 Windows 的动态端口保留区覆盖 65420（`netsh interface ipv4 show
#   excludedportrange protocol=tcp`，2026-10-16 实测 65399-65498 被保留）⇒ cdt_js
#   绑不上 65420（`Cannot create listening port: Socket bind error`）。此时用
#   `cdt_js.exe -port <自由口>` 起服务，并同值导出本变量即可。
#
# 用法：
#   cdt_cfg_shell.exe -file pds/flash_yeshen.tcl
#   然后： python -u scripts/listen_uart.py <COM口> 30
#     · 装载期应看到 `SDR ` + 18 hex 每 100ms 一行（SD 诊断，115200）
#     · 放核后应看到 OpenSBI banner → Linux 启动 → 用户态 marker
# ============================================================================
set jport 65420
if {[info exists env(YESHENMINI_JTAG_PORT)]} { set jport $env(YESHENMINI_JTAG_PORT) }
puts "=== flash: jtag_port=$jport ==="
cfg_connect -ip 127.0.0.1 -port $jport
cfg_scan_chain
cfg_assign_file -file $sbit
cfg_program
cfg_scan_chain
