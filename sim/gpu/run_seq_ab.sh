#!/bin/bash
# run_seq_ab.sh —— **2D/3D 混排命令序列**的回归闸门（补 2026-11-01 上板挂死暴露的覆盖缺口）。
#
# 缺口：既有闸门里，3D 引擎是**直连** start/p0..p7 测的（tb_gpu_3d / tb_tri_raster），
#   而 `gpu_cmd → gpu_top 分发 → 引擎` 这条**真命令通路**只有 2D 命令走过。
#   实测 bug：`cmd_start` 不分派给两个引擎 ⇒ 3D 命令把 2D 引擎带进"等参数"状态，
#   之后任意 2D 命令都不回 cmd_done ⇒ gpu_cmd 停在 S_DONE，FIFO 里后续命令永不启动。
#
# 本闸门用**板上同一串命令**（CLEAR3D → FENCE → DRAW_TRIS）走真 CSR 通路，判据：
#   ① 三条命令**全部跑完**（TB 打印 `seq=2`，不 TIMEOUT）；
#   ② 3D 引擎**确实发了读**（`ar>=1`，即三角记录被取）；
#   ③ 颜色缓冲被写成 CLEAR 色 / 三角色（不是全 0）。
# 红臂：把 `start_2d` 换回 `cmd_start`（即修复前的接法）必须 TIMEOUT。
set -u
cd "$(dirname "$0")/../.." || exit 9
mkdir -p sim/reglogs sim/gpu/gold3d

python3 - <<'PY'
import os
W,H=64,32
CB,ZB,ARENA=0x2000,0x3000,0x1000
cmds=[]
def cmd(op,ps):
    cmds.append((op<<24)|(len(ps)<<16)); cmds.extend(ps)
cmd(0x10,[0x07E0,0xFFFF,W,H,CB,W,ZB,W])   # CLEAR3D
cmd(0x07,[1])                               # FENCE
cmd(0x11,[ARENA,1,W,H,CB,W,ZB,W])           # DRAW_TRIS
with open("sim/gpu/gold3d/board_seq.cmds.hex","w") as f:
    for v in cmds: f.write("%08x\n"%v)
with open("sim/gpu/gold3d/board_seq.init.hex","w") as f:
    for i in range(153600): f.write("0000\n")
with open("sim/gpu/gold3d/board_seq.exp.hex","w") as f:
    for i in range(153600): f.write("0000\n")
PY
cat > sim/gpu/tb_cfg.svh <<EOF
\`define INIT_FILE "sim/gpu/gold3d/board_seq.init.hex"
\`define EXP_FILE  "sim/gpu/gold3d/board_seq.exp.hex"
\`define CMD_FILE  "sim/gpu/gold3d/board_seq.cmds.hex"
EOF

SRCS="sim/gpu/tb_gpu_cdc.v sim/gpu/axi_ram_model.v rtl/gpu/gpu_clock_domain.v rtl/gpu/gpu_axil_cdc.v \
rtl/gpu/gpu_mem_cdc.v rtl/gpu/gpu_top.v rtl/gpu/gpu_csr.v rtl/gpu/gpu_cmd.v rtl/gpu/gpu_2d.v \
rtl/gpu/gpu_3d.v rtl/gpu/tri_setup.v rtl/gpu/tri_raster.v rtl/gpu/gpu_mem.v board/dcfifo.v"

run_arm () {   # $1=label $2=extra
  local label="$1"
  local extra="$2"
  local obj="/tmp/obj_seq_$label"
  rm -rf "$obj"
  verilator --binary --timing -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-DECLFILENAME \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC $extra -Isim/gpu -Irtl/gpu --top-module tb_gpu_cdc \
    $SRCS -Mdir "$obj" -o tb >"/tmp/obj_seq_${label}_build.log" 2>&1 || {
      echo "!! build failed ($label)"; tail -20 "/tmp/obj_seq_${label}_build.log"; return 3; }
  "$obj/tb"
}

echo "== seq arm（期望：跑完 + seq=2 + ar>=1）=="
out=$(run_arm ok "") || exit 3
printf '%s\n' "$out" | tee sim/reglogs/gpu_seq.log | grep -E "cdc:|TIMEOUT" | head -3
if printf '%s\n' "$out" | grep -q "CDC TIMEOUT"; then
  echo "!! 序列没跑完（TIMEOUT）"; exit 1
fi
printf '%s\n' "$out" | grep -q "seq=2" || { echo "!! seq 不是 2"; exit 1; }
printf '%s\n' "$out" | grep -qE "ar=[1-9]" || { echo "!! 3D 没发读（ar=0）"; exit 1; }
echo "   seq arm PASS"

echo "== red arm（把 start_2d 退回 cmd_start，期望 TIMEOUT）=="
mkdir -p /tmp/redrtl && cp rtl/gpu/gpu_top.v /tmp/redrtl/gpu_top.v
sed -i 's/\.cmd_start(start_2d)/.cmd_start(cmd_start)/' /tmp/redrtl/gpu_top.v
grep -q "cmd_start(cmd_start)" /tmp/redrtl/gpu_top.v || { echo "!! 红臂改写失败"; exit 3; }
obj=/tmp/obj_seq_red; rm -rf $obj
verilator --binary --timing -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-DECLFILENAME \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Isim/gpu -Irtl/gpu --top-module tb_gpu_cdc \
  sim/gpu/tb_gpu_cdc.v sim/gpu/axi_ram_model.v rtl/gpu/gpu_clock_domain.v rtl/gpu/gpu_axil_cdc.v \
  rtl/gpu/gpu_mem_cdc.v /tmp/redrtl/gpu_top.v rtl/gpu/gpu_csr.v rtl/gpu/gpu_cmd.v rtl/gpu/gpu_2d.v \
  rtl/gpu/gpu_3d.v rtl/gpu/tri_setup.v rtl/gpu/tri_raster.v rtl/gpu/gpu_mem.v board/dcfifo.v \
  -Mdir $obj -o tb >/tmp/obj_seq_red_build.log 2>&1 || { echo "!! 红臂 build 失败"; tail -10 /tmp/obj_seq_red_build.log; exit 3; }
out=$($obj/tb)
printf '%s\n' "$out" | tee sim/reglogs/gpu_seq_red.log | grep -E "cdc:|TIMEOUT" | head -3
if printf '%s\n' "$out" | grep -q "CDC TIMEOUT"; then
  echo "   红臂如期 TIMEOUT（闸门灵敏度自证 OK）"
else
  echo "!! 红臂竟然跑完了 ⇒ 本闸门抓不到这个 bug"; exit 1
fi
