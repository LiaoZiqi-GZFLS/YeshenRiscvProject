#!/bin/bash
# run_2d_cdc.sh —— **GPU 独立时钟域**的端到端像素闸门（两个异步时钟）。
#   usage: bash sim/gpu/run_2d_cdc.sh [case ...]     默认 fill_rect blit565 glyph round32 scissor edge blit8
#
# 装置：sim/gpu/tb_gpu_cdc.v → gpu_clock_domain（gpu_top + gpu_axil_cdc + gpu_mem_cdc + 复位同步）
#       + sim/gpu/axi_ram_model.v；命令从 CSR 窗推进去，逐 8 B 字对黄金（与 run_2d.sh 同一套 case 文件）。
#
# 臂（缺一不可）：
#   ① gpu **慢**档（gpu_clk = 14ns = 71.4MHz，与 soc 10ns 非整数比）
#   ② gpu **快**档（gpu_clk = 6ns = 166.7MHz，比 soc 快）—— 提频方向的预演
#   ③ **红臂**：`-DDCFIFO_BAD_SYNC`（dcfifo 跳过指针同步器 = "忘了做 CDC"）必须 FAIL；
#      这是本闸门的灵敏度自证（否则"全绿"可能只是没覆盖）。
set -u
cd "$(dirname "$0")/../.." || exit 9
CASES=${*:-"fill_rect blit565 glyph round32 scissor edge blit8"}
mkdir -p sim/reglogs
fail=0

build_and_run () {          # $1=label $2=extra-defines
  local label="$1"; local extra="$2"
  local obj="/tmp/obj_gpu_cdc_$label"
  rm -rf "$obj"
  verilator --binary --timing -Wall -Wno-fatal -Wno-UNOPTFLAT -Wno-DECLFILENAME \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASTCONST -Wno-LATCH \
    $extra -Isim/gpu -Irtl/gpu --top-module tb_gpu_cdc \
    sim/gpu/tb_gpu_cdc.v sim/gpu/axi_ram_model.v \
    rtl/gpu/gpu_clock_domain.v rtl/gpu/gpu_axil_cdc.v rtl/gpu/gpu_mem_cdc.v \
    rtl/gpu/gpu_top.v rtl/gpu/gpu_csr.v rtl/gpu/gpu_cmd.v rtl/gpu/gpu_2d.v \
    rtl/gpu/gpu_3d.v rtl/gpu/tri_setup.v rtl/gpu/tri_raster.v rtl/gpu/gpu_mem.v \
    board/dcfifo.v \
    -Mdir "$obj" -o tb >"/tmp/obj_gpu_cdc_${label}_build.log" 2>&1
  if [ $? -ne 0 ]; then
    echo "!! verilator build failed ($label)"; tail -25 "/tmp/obj_gpu_cdc_${label}_build.log"; exit 3
  fi
  "$obj/tb"
}

for c in $CASES; do
  python3 sim/gpu/mk_hex.py --case "$c" --gold sim/gpu/gold >/dev/null || { echo "!! hex fail $c"; exit 3; }
  cat > sim/gpu/tb_cfg.svh <<EOF
\`define INIT_FILE "sim/gpu/gold/$c.init.hex"
\`define EXP_FILE  "sim/gpu/gold/$c.exp.hex"
\`define CMD_FILE  "sim/gpu/gold/$c.cmds.hex"
EOF
  for arm in slow fast; do
    if [ "$arm" = fast ]; then EX="-DGPU_FAST"; else EX=""; fi
    echo "== case $c [$arm] =="
    out=$(build_and_run "$arm" "$EX") || { echo "!! build/run 失败（$c/$arm）"; fail=1; continue; }
    printf '%s\n' "$out" | tee "sim/reglogs/gpu_cdc_${arm}_$c.log" \
      | grep -E "MISMATCH|PASS|FAIL|TIMEOUT|cdc:" | head -12
    printf '%s\n' "$out" | grep -q "CDC PASS" || fail=1
  done
done

# ---------------- 红臂：跳过 dcfifo 指针同步器（必须 FAIL）----------------
echo "== RED arm（-DDCFIFO_BAD_SYNC，期望 FAIL）=="
python3 sim/gpu/mk_hex.py --case blit565 --gold sim/gpu/gold >/dev/null
cat > sim/gpu/tb_cfg.svh <<EOF
\`define INIT_FILE "sim/gpu/gold/blit565.init.hex"
\`define EXP_FILE  "sim/gpu/gold/blit565.exp.hex"
\`define CMD_FILE  "sim/gpu/gold/blit565.cmds.hex"
EOF
out=$(build_and_run red "-DDCFIFO_BAD_SYNC") || { echo "!! 红臂 build 失败"; exit 3; }
printf '%s\n' "$out" | tee "sim/reglogs/gpu_cdc_red.log" | grep -E "PASS|FAIL|TIMEOUT" | head -5
if printf '%s\n' "$out" | grep -q "CDC PASS"; then
  echo "!! RED 臂竟然 PASS ⇒ 本闸门对'忘了做 CDC'不敏感，判据作废"
  fail=1
else
  echo "   red arm 如期 FAIL（闸门灵敏度自证 OK）"
fi

# ---------------- 红臂②：dcfifo 数据位取反（必须出 MISMATCH，证明像素判据本身有效）----------------
echo "== RED arm 2（-DDCFIFO_BAD_DATA，期望 MISMATCH/FAIL）=="
out=$(build_and_run red2 "-DDCFIFO_BAD_DATA") || { echo "!! 红臂2 build 失败"; exit 3; }
printf '%s\n' "$out" | tee "sim/reglogs/gpu_cdc_red2.log" | grep -E "MISMATCH|PASS|FAIL|TIMEOUT" | head -5
if printf '%s\n' "$out" | grep -q "CDC PASS"; then
  echo "!! 红臂2 竟然 PASS ⇒ 像素判据不敏感，判据作废"
  fail=1
else
  echo "   red arm 2 如期 FAIL（像素判据灵敏度自证 OK）"
fi

exit $fail
