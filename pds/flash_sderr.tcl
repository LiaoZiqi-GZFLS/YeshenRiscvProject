# flash_sdgap2.tcl -- sdgap 版：SdSpi 命令间插入 **一整个 0xFF 字节的 CS 高电平**（= tf_test 的 ST_GAP）
#   + 采样点对齐 tf_test + 初始化 8 次重试 + 32 位诊断（含 misoHi）。
# 判据：ETH 反向信道 12B 帧 `'N','X','B',0x01 | rxBytes(4) | sdDbg(4)`，
#   sdDbg = {misoHi(1), sckCnt(12), lastRx(8), errCode(4), ph(4), st(3)}；errCode=0 且 ph=pReady 即初始化全过。
cfg_connect -ip 127.0.0.1 -port 65420
cfg_scan_chain
cfg_assign_file -file "D:/code/PDS/NaxYeshenLinux/sim/reglogs/sderr.sbit"
cfg_program
cfg_scan_chain
