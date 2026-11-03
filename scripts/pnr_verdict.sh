#!/bin/bash
# pnr_verdict.sh —— 从 PDS 工程目录提取 PnR 判据（Design Summary / 各时钟 slack / Best Seed / 比特流指纹）
#   usage: bash scripts/pnr_verdict.sh <tag> [period]    默认 period=10.000
#   判据三条：Design Summary 行、soc_clk/cpu_clk/npu_clk 三行、比特流文件大小+sha256。
set -u
cd "$(dirname "$0")/.." || exit 9
tag=${1:?usage: bash scripts/pnr_verdict.sh <tag> [period]}
period=${2:-10.000}
dir="sim/reglogs/pds_${tag}_p${period}/prj_tasks/pnr_1"
rtr="$dir/report_timing/yeshen_mini_board_top.rtr"
sbit="$dir/generate_bitstream/yeshen_mini_board_top.sbit"

echo "== tag=$tag period=$period =="
if [ ! -f "$rtr" ]; then echo "MISSING: $rtr"; exit 2; fi
grep -m1 "Design Summary" "$rtr"
grep -m1 "Best Seed" "$rtr" 2>/dev/null
awk '/Performance Summary/{f=1} f&&/^ (soc_clk|cpu_clk|npu_clk|core_clk|gpu_clk) /{print; if(++n==5) exit}' "$rtr"
if [ -f "$sbit" ]; then
  echo "sbit: $(stat -c %s "$sbit") B"
  sha256sum "$sbit" | cut -c1-32 | sed 's/^/sha256: /'
  md5sum "$sbit" | cut -d' ' -f1 | sed 's/^/md5:    /'
else
  echo "sbit: MISSING（PnR 未跑到 generate_bitstream）"
fi
# 违例时钟面板（只看 Setup Slow）
awk '/Setup Summary\(Slow Corner\)/{f=1} f&&/^ [a-z_0-9]+ +[a-z_0-9]+ +-/{print} f&&/^$/{if(c++>0) exit}' "$rtr" | head -12
