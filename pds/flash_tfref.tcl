# ============================================================================
# flash_tfref.tcl -- 上板第 0 步：把**已验收的 tf_test 参考比特流**烧进板子，判"TF 卡
#   模块的硬件/接线还是好的吗"。
#
# 为什么必须先做这一步：如果参考工程都报 `TF-E1 noresp`，那后面我们设计的任何读数都不可信
#   （错在卡/接线/座子，不在我们的 RTL）。参考比特流自带 250ms 自动重试，每 1s 发一行
#   UART（115200 8N1）：
#     成功 = `TF-OK r0=01 r8=01AA ocr=... sts=01 d0=...`
#     失败 = `TF-E1 noresp   resp=FF`
#
# ⚠️ 前置（每次都要）：
#   1) `cdt_js.exe` 先起 JTAG server，**读它自报的 `use port : XXXXX`**，把下面的端口改成
#      自报值（65420 是历史值，不保证还在用）。
#   2) 断电必掉配置（SRAM）⇒ 每次上电都要重烧。
#   3) 烧完等 ~3s 再读串口（配置期间线上在抖）。
#
# 用法：
#   cdt_cfg_shell.exe -file pds/flash_tfref.tcl
#   然后： python -u scripts/listen_uart.py <COM口> <秒数>      # 板载 CP2102
#
# 参考比特流不在本仓（属 tf_test_200mini，只读引用；本仓零改动）。
# ============================================================================
cfg_connect -ip 127.0.0.1 -port 65420
cfg_scan_chain
cfg_assign_file -file "D:/code/PDS/NaxYeshenLinux/sim/reglogs/tf_test_ref.sbit"
cfg_program
cfg_scan_chain
