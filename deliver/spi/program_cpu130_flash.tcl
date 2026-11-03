# program_cpu130_flash.tcl -- cpu130 永久固化到 SPI flash（XT25BF128）。
# 与 2026-10-30 ctp2 固化同序列；★读回前必须先 assign（Configuration-0016，
# 2026-10-30 也踩过同坑、readback2.tcl 的修法）。
cfg_connect -ip 127.0.0.1 -port 62000
cfg_set_cable_property -index 0 -freq 1MHz
cfg_scan_chain
cfg_jtag_flash_scan_device -device_index 0
# 1) assign cpu130 sfc（后续所有 flash 操作的文件上下文）
cfg_jtag_flash_assign_file -file D:/code/PDS/VexiiYeshenLinux/sim/reglogs/spi_flash/cpu130_20261103.sfc -device_index 0
# 2) 烧前备份当前 flash 内容（应为 2026-10-30 固化的 ctp2_1176）
cfg_jtag_flash_readback -file D:/code/PDS/VexiiYeshenLinux/sim/reglogs/spi_flash/flash_backup_20261103.sfc -device_index 0
# 3) 固化 cpu130
cfg_jtag_flash_erase -device_index 0
cfg_jtag_flash_program -device_index 0
cfg_jtag_flash_verify -device_index 0
# 4) 烧后独立读回
cfg_jtag_flash_readback -file D:/code/PDS/VexiiYeshenLinux/sim/reglogs/spi_flash/cpu130_20261103_rb.sfc -device_index 0
cfg_disconnect
puts "PROGRAM DONE"
