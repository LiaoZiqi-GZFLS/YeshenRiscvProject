# flash_liteeth.tcl -- 烧 LiteEth 版交付比特流（sim/reglogs/liteeth_v2.sbit）。
# 判据（串口 115200）：`SDR ` + 18 hex 每 100ms 一行（SD 诊断），成功则接着是 Linux 控制台。
cfg_connect -ip 127.0.0.1 -port 65420
cfg_scan_chain
cfg_assign_file -file "D:/code/PDS/NaxYeshenLinux/sim/reglogs/liteeth_v2.sbit"
cfg_program
cfg_scan_chain
