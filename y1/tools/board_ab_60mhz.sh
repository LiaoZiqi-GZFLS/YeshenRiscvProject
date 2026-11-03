#!/usr/bin/env bash
# ============================================================================
# board_ab_60mhz.sh —— 60 MHz 交付件的**一条命令**板级 A/B（窗口内跑完就出判词）
#
#   前提：板子已烧 60 MHz 比特流（`npu60b`，sbit md5 6906faf1…），网络可达 ssh。
#   判据（全部自动判，任一红即非零退出）：
#     ① 视频在跑：VIDEO STATUS[31:8] 帧序号在 10 s 内递增；
#     ② NPU 12/12：`y1run --frames N` 每帧 `outputs=12/12` 且末行 `Y1RUN: PASS`；
#     ③ 速度：RUN 的 ns 均值 ≤ 阈值（默认 **1673.7 ms** = 1,771.2×54/60×1.05）；
#        ★ 这只是"别回退成 W1 水平"的闸门。**预期值 ~1.33 s**：
#          W1 板级 1,771.2 ms（实测）→ W2 ~1,612 / W3 ~1,473 ms（整帧模型，54 MHz）
#          → ×54/60（60 MHz）≈ **1,326 ms**。实测若 >1.45 s ⇒ W2/W3 的 sim 收益没在板上兑现，
#          要单独归因（先看 `wt_load` 口径与段数，再怀疑写回 FSM）。
#     ④ 画质归因：`video_health.py` 的 idle vs loaded `vid_stall`（NPU 拖累的直接数值）。
#
#   用法：
#     bash y1/tools/board_ab_60mhz.sh                 # 默认 3 帧
#     bash y1/tools/board_ab_60mhz.sh --frames 5 --limit-ms 1650
#     bash y1/tools/board_ab_60mhz.sh --no-health     # 跳过 ④（省 ~40 s）
#
#   口径：**同板/同卡/同会话**。W1(54 MHz) 基线 1,771.2 ms 是历史值，只作折算参照；
#   真要 A/B 就在同一窗口里换烧两版比特流各跑一遍（本脚本对两版通用）。
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3   # 仓库根

PY="${PY:-python}"
FRAMES=3
LIMIT_MS=1673.7
DO_HEALTH=1
VIDEO=0xF0007400

while [ $# -gt 0 ]; do
  case "$1" in
    --frames) FRAMES="$2"; shift 2;;
    --limit-ms) LIMIT_MS="$2"; shift 2;;
    --no-health) DO_HEALTH=0; shift;;
    -h|--help) sed -n '2,22p' "$0"; exit 0;;
    *) echo "unknown arg: $1"; exit 3;;
  esac
done

say() { printf '%s\n' "$*"; }
bad=0

# ---- 0) 通道自检 -----------------------------------------------------------
say "== [0] y1ctl ping =="
if ! "$PY" -u scripts/y1ctl.py ping; then
  say "JUDGE-RED: 板子不可达（先确认在 60 MHz 比特流上、网口/口令正常）"
  exit 2
fi

# ---- ① 视频在跑 ------------------------------------------------------------
read_video() {  # -> "0x........"
  "$PY" -u scripts/y1ctl.py run "devmem $VIDEO 32" 2>/dev/null \
    | grep -oE '0x[0-9a-fA-F]{8}' | tail -1
}
say "== [1] VIDEO STATUS 帧序号（10 s 两读）=="
V1="$(read_video)"; sleep 10; V2="$(read_video)"
say "   STATUS: $V1 -> $V2"
SEQ1=$(( (V1 >> 8) & 0xFFFFFF )); SEQ2=$(( (V2 >> 8) & 0xFFFFFF ))
if [ "$SEQ2" -gt "$SEQ1" ]; then
  say "   OK: 帧序号递增（Δ=$((SEQ2-SEQ1))）⇒ 视频在跑"
else
  say "   JUDGE-RED: 帧序号没递增（视频没跑 / 不在视频比特流上）"; bad=1
fi

# ---- ②③ NPU 12/12 + 速度 --------------------------------------------------
say "== [2] y1run --frames $FRAMES =="
OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT
# ★ 2026-10-25：直连 ssh 跑 y1run 会掉会话（dropbear 在长输出/长命令上不稳，实测只回
#   "sh: C:/Program: not found"）。改**板内后台跑 + 落 /tmp 文件 + 轮询抓取**（已验证）。
"$PY" -u scripts/y1ctl.py run "rm -f /tmp/y1run.log; (setsid /root/y1/y1run --frames $FRAMES > /tmp/y1run.log 2>&1; echo DONE_RC=\$? >> /tmp/y1run.log) </dev/null >/dev/null 2>&1 & echo STARTED" --timeout 60 || true
for _i in $(seq 1 60); do
  sleep 3
  "$PY" -u scripts/y1ctl.py run "tail -40 /tmp/y1run.log" --timeout 60 > "$OUT" 2>/dev/null || true
  grep -q 'DONE_RC' "$OUT" && break
done
cat "$OUT"
if ! grep -q '^Y1RUN: PASS' "$OUT"; then
  say "   JUDGE-RED: 末行不是 Y1RUN: PASS"; bad=1
fi
NFR=$(grep -c '^RUN ' "$OUT")
if [ "$NFR" -ne "$FRAMES" ]; then
  say "   JUDGE-RED: RUN 行数 $NFR != $FRAMES"; bad=1
fi
BADOUT=$(grep '^RUN ' "$OUT" | grep -cvE 'outputs=([0-9]+)/\1' || true)
if [ "${BADOUT:-0}" -ne 0 ]; then
  say "   JUDGE-RED: 有 $BADOUT 帧 outputs 不是 n/n"; bad=1
fi

STATS=$(grep '^RUN ' "$OUT" | sed -n 's/^RUN [0-9]* ns=\([0-9]*\).*/\1/p' \
        | awk '{s+=$1; n++; if(min==""||$1<min)min=$1; if($1>max)max=$1} END{if(n)printf "%.1f %.1f %.1f %d", s/n/1e6, min/1e6, max/1e6, n}')
set -- $STATS
if [ $# -eq 4 ]; then
  say "   RUN: mean=$1 ms  min=$2  max=$3  frames=$4   （阈值 ≤ $LIMIT_MS ms；预期 ~1326 ms）"
  if awk -v m="$1" -v l="$LIMIT_MS" 'BEGIN{exit !(m<=l)}'; then
    say "   OK: 速度达标（≤ $LIMIT_MS ms）"
  else
    say "   JUDGE-RED: 速度未达标（$1 ms > $LIMIT_MS ms）⇒ 先查 NPU 时钟是否真 60 MHz"; bad=1
  fi
else
  say "   JUDGE-RED: 解析不到 RUN ns"; bad=1
fi

# ---- ④ 画质归因（vid_stall idle vs loaded）--------------------------------
if [ "$DO_HEALTH" = 1 ]; then
  say "== [3] video_health.py（idle vs NPU 负载的 vid_stall）=="
  "$PY" -u scripts/video_health.py --window 0.2 --settle 5 || {
    say "   NOTE: video_health 非零退出（看上面的 idle/loaded 采样再判读）"; bad=1; }
else
  say "== [3] 跳过 video_health（--no-health）=="
fi

# ---- 判词 ------------------------------------------------------------------
if [ "$bad" -eq 0 ]; then say "RESULT: PASS（视频在跑 / 12-12 CRC / 速度达标）"; exit 0
else say "RESULT: FAIL（见上面 JUDGE-RED 行）"; exit 1; fi
