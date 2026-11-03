# scan_only.tcl -- NON-DESTRUCTIVE: connect to the JTAG server and scan the chain only.
# Reports the device and the configuration "done bit" WITHOUT programming anything.
# Use to tell "our bitstream is still loaded" from "somebody re-flashed / board lost config".
#   cdt_cfg_shell.exe -file <absolute path to this file>
cfg_connect -ip 127.0.0.1 -port 65420
cfg_scan_chain
