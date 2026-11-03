#!/bin/bash
# run_3d_big.sh —— **整屏几何**（默认 640×480）的 3D 端到端闸门，走真 CSR + 双时钟 CDC 通路。
#
# 为什么要有它：既有 3D 闸门（tb_gpu_3d / run_3d_ab / run_seq_ab）全是 64×32 的小几何，
#   只覆盖 2 个 tile；而 640×480 是 **20×15 = 300 个 tile**、每 tile 32 行。
#
# 用法：run_3d_big.sh [W] [H] [tag]     （tag 只用来给向量文件/对象目录起名，方便二分）
#
# 布局：CB=0x000000、ZB=0x096000、ARENA=0x12C000（都是 64-bit 字对齐），
#   默认 640×480 时 `FB_WORDS=153600` 正好从字 0 盖到 Z 缓冲末尾
#   （CB 字 0..76799，Z 字 76800..153599）。W/H 变小时有效区相应变小。
#
# 用例：CLEAR3D(0x0000,0xFFFF) → FENCE(1) → DRAW_TRIS(2 个三角形拼满整屏,
#       color=0x07E0, z=40000, dzdx=dzdy=0, zmode=LESS) → FENCE(2)
# 判据：① 不 TIMEOUT；② 最后一条 FENCE 的 seq 落地（DRAW 真的跑完）；
#       ③ ar>0；④ 逐字比对 CB 全 0x07E0、Z 全 0x9C40（=40000），零失配。
set -u
cd "$(dirname "$0")/../.." || exit 9
W_ARG="${1:-640}"
H_ARG="${2:-480}"
BIG_TAG="${3:-big}"
mkdir -p sim/reglogs sim/gpu/gold3d

python3 - "$W_ARG" "$H_ARG" "$BIG_TAG" <<'PY'
import sys
W, H, TAG = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
CB, ZB, ARENA = 0x000000, 0x096000, 0x12C000
COLOR, Z0 = 0x07E0, 40000

cmds = []
def cmd(op, ps):
    cmds.append((op << 24) | (len(ps) << 16))
    cmds.extend(ps)

cmd(0x10, [COLOR, 0xFFFF, W, H, CB, W, ZB, W])         # CLEAR3D
cmd(0x07, [1])                                          # FENCE(1)

# 三角形记录 48 B = 6 × 64-bit 字（与 gputest3d.c 的 rec_pack 逐字一致）：
#   w0={y0,x0} w1={y1,x1} w2={y2,x2} w3={dzdx, color<<16|z0} w4={zmode, dzdy} w5=0
def rec(x0, y0, x1, y1, x2, y2):
    q8 = lambda v: v << 8
    return [
        (q8(y0) << 32) | q8(x0),
        (q8(y1) << 32) | q8(x1),
        (q8(y2) << 32) | q8(x2),
        (COLOR << 16) | Z0,                             # dzdx = 0
        0,                                              # zmode = LESS(0)，dzdy = 0
        0,
    ]

# 顶点取 (W,H) 而不是 (W-1,H-1)：包围盒会被 tri_setup clamp 到 [0,W-1]/[0,H-1]，
# 而像素中心 (x+0.5,y+0.5) 全落在矩形内 ⇒ 每个像素都被画到。
tris = [rec(0, 0, W, 0, W, H), rec(0, 0, W, H, 0, H)]

cmd(0x11, [ARENA, 2, W, H, CB, W, ZB, W])              # DRAW_TRIS（2 个三角形）
cmd(0x07, [2])                                          # FENCE(2)

with open("sim/gpu/gold3d/%s.cmds.hex" % TAG, "w") as f:
    for v in cmds:
        f.write("%08x\n" % v)

with open("sim/gpu/gold3d/%s.init.hex" % TAG, "w") as f:
    f.write("@%x\n" % (ARENA >> 3))
    for t in tris:
        for wv in t:
            f.write("%016x\n" % wv)

# 期望：CB 全 COLOR、Z 全 Z0（每个 64-bit 字 = 4 个同色像素）；
# CB/ZB 之外的字全是 0（RAM 模型先整体清 0，再由 INIT_FILE 覆盖 ARENA）。
def word(px):
    return "%016x" % ((px << 48) | (px << 32) | (px << 16) | px)

FB_WORDS = 153600
n_half = W * H * 2 // 8            # 一个缓冲占多少个 64-bit 字
cb_w = CB >> 3
zb_w = ZB >> 3
exp = ["0000000000000000"] * FB_WORDS
for k in range(n_half):
    if cb_w + k < FB_WORDS:
        exp[cb_w + k] = word(COLOR)
    if zb_w + k < FB_WORDS:
        exp[zb_w + k] = word(Z0)
with open("sim/gpu/gold3d/%s.exp.hex" % TAG, "w") as f:
    for e in exp:
        f.write(e + "\n")
PY

cat > sim/gpu/tb_cfg.svh <<EOF
\`define INIT_FILE "sim/gpu/gold3d/${BIG_TAG}.init.hex"
\`define EXP_FILE  "sim/gpu/gold3d/${BIG_TAG}.exp.hex"
\`define CMD_FILE  "sim/gpu/gold3d/${BIG_TAG}.cmds.hex"
EOF

SRCS="sim/gpu/tb_gpu_cdc.v sim/gpu/axi_ram_model.v rtl/gpu/gpu_clock_domain.v rtl/gpu/gpu_axil_cdc.v \
rtl/gpu/gpu_mem_cdc.v rtl/gpu/gpu_top.v rtl/gpu/gpu_csr.v rtl/gpu/gpu_cmd.v rtl/gpu/gpu_2d.v \
rtl/gpu/gpu_3d.v rtl/gpu/tri_setup.v rtl/gpu/tri_raster.v rtl/gpu/gpu_mem.v board/dcfifo.v"

OBJ=/tmp/obj_seq_big_${BIG_TAG}
EXTRA="${EXTRA:-}"
rm -rf "$OBJ"
verilator --binary --timing -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-DECLFILENAME \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC $EXTRA -Isim/gpu -Irtl/gpu --top-module tb_gpu_cdc \
  $SRCS -Mdir "$OBJ" -o tb >/tmp/obj_seq_big_${BIG_TAG}_build.log 2>&1 || {
    echo "!! build failed"; tail -20 "/tmp/obj_seq_big_${BIG_TAG}_build.log"; exit 3; }

out=$("$OBJ/tb")
printf '%s\n' "$out" | tee "sim/reglogs/gpu_3d_${BIG_TAG}.log" | grep -E "cdc:|TIMEOUT|MISMATCH" | head -5
if printf '%s\n' "$out" | grep -q "CDC TIMEOUT"; then
  echo "3D_BIG(${W_ARG}x${H_ARG}) FAIL（TIMEOUT）"; exit 1
fi
if printf '%s\n' "$out" | grep -q "CDC PASS"; then
  echo "3D_BIG(${W_ARG}x${H_ARG}) PASS"; exit 0
fi
echo "3D_BIG(${W_ARG}x${H_ARG}) FAIL（没有 PASS 行）"; exit 1