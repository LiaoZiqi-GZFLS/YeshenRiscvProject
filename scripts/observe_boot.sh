#!/bin/bash
# ============================================================================
# observe_boot.sh -- 上板观测一条龙（本工程用）
#
#   1) 烧当前比特流（TAG 由 YESHENMINI_TAG 选，默认 m3 = E1 控制台修复版；tcl 用绝对路径）
#   2) **立刻**起串口采集（t=0 起，覆盖完整启动；原始字节落盘）
#   3) 采集期间：先发 ARP（观察网卡中断计数），再**灌串口字节**（观察 UART 的 RX 活动计数）
#   4) 抽取关键行：SDR / marker / IRQDBG / PLICDBG / **UARTDBG** / **RXACTY**
#
# 用法：bash scripts/observe_boot.sh [秒数] [板IP] [波特]
#   默认 90 秒、192.168.1.110、115200（E1 定案：全链回到 115200）
#   第 4 个参数 FLOOD=1 才灌串口字节（灌字节是给旧 RXACTY 探针配激励的；要判"能不能登进去"必须关掉）
#
# ⚠️ 前置：cdt_js.exe 在跑；TF 卡插在**板子**上；卡的镜像里要含 S97uart_dbg.sh 探针。
# ⚠️ 抽取阶段不要漏 UARTDBG/RXACTY —— 上一版就漏了，导致"驱动有没有开 RX 中断"的判据没打出来。
# ⚠️ 不要把采集原文直接 print 到 Windows 控制台（GBK 会崩）—— 见 listen_uart.py。
# ============================================================================
set -u
ROOT="$(cd -- "$(dirname "$0")/.." >/dev/null 2>&1 && pwd -P)"
SECS=${1:-90}
BOARD_IP=${2:-192.168.1.110}
BAUD=${3:-115200}
BIN=/c/Pango/PDS_2025.2-ads/bin
OUT="$ROOT/sim/reglogs/observe_boot.txt"
RAW="$ROOT/sim/reglogs/observe_boot_raw.bin"

echo "== 1/5 烧板（TAG=${YESHENMINI_TAG:-m3}）=="
"$BIN/cdt_cfg_shell.exe" -file "D:/code/PDS/VexiiYeshenLinux/pds/flash_yeshen.tcl" \
  > "$ROOT/sim/reglogs/observe_flash.out" 2>&1
echo "   flash rc=$?  $(grep -a 'done bit is' "$ROOT/sim/reglogs/observe_flash.out" | tail -1)"

echo "== 2/5 串口采集 ${SECS}s @${BAUD}（t=0 起）=="
python -u "$ROOT/scripts/listen_uart.py" COM7 "$SECS" "$BAUD" "$RAW" > "$OUT" 2>&1 &
LPID=$!

echo "== 3/5 同期发 ARP =="
sleep 18
n=0
while [ $n -lt 10 ]; do ping -n 2 -w 400 "$BOARD_IP" > /dev/null 2>&1; n=$((n + 1)); done
echo "   sent $((n * 2)) ping probes"

FPID=0
if [ "${4:-0}" = "1" ]; then
  echo "== 4/5 灌串口字节（FLOOD=1，覆盖探针的 RX 活动计数窗口）=="
  ( k=0; while [ $k -lt 8 ]; do python -u "$ROOT/scripts/uart_flood.py" COM7 "$BAUD" 4000 > /dev/null 2>&1; k=$((k + 1)); done ) &
  FPID=$!
else
  echo "== 4/5 跳过灌字节（FLOOD=0；判登录时不能灌）=="
fi
wait $LPID
[ "$FPID" != "0" ] && wait $FPID 2>/dev/null

echo "== 5/5 抽取关键行 =="
for pat in "SDR" "VEXIIYESHEN-OK|NAXMINI-NET|liteeth|login:" "IRQDBG" "PLICDBG" "UARTDBG" "RXACTY"; do
  echo "--- $pat ---"
  grep -aE "$pat" "$OUT" | sed -E 's/^\[[0-9:]+\] //' | sort -u | head -12
done
echo "--- 采集统计 ---"; tail -2 "$OUT"
