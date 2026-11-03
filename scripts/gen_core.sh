#!/bin/bash
# 生成 RV32 VexiiRiscv 核网表（AXI4 3 主口：fetch / lsuL1 / cacheless-IO）。
#
# 前置：
#   - third_party/VexiiRiscv 已按 third_party/PINS.md 克隆（含 ext/SpinalHDL 子模块）
#   - JDK 17（JAVA_HOME），sbt 可用（SBT 变量可覆盖）
# 产物：
#   third_party/VexiiRiscv/VexiiRiscv.v  →  复制到 rtl/vexiiriscv/VexiiRiscv.v
#
# 用法：bash scripts/gen_core.sh
set -u

REPO_ROOT="$(cd -- "$(dirname "$0")/.." >/dev/null 2>&1 && pwd -P)"
SBT="${SBT:-/c/Users/Ziqi/AppData/Local/Coursier/data/bin/sbt.bat}"
VEXII="$REPO_ROOT/third_party/VexiiRiscv"
OUT_DIR="$REPO_ROOT/rtl/vexiiriscv"
LOG="$REPO_ROOT/gen_core.log"

# 地址口径与 NaxYeshenLinux 的软件栈对齐（见 docs 与 OpenSBI platform.c）：
#   0x8000_0000 + 512MiB : 主存（DDR3），可缓存/可执行
#   0xF000_0000 + 256MiB : 外设，非缓存 —— 必须覆盖 CLINT 0xF001_0000 与 PLIC 0xF0C0_0000
GEN_ARGS=(
  --xlen 32
  --decoders 2 --lanes 2
  --reset-vector 0x80000000
  # 2026-10-31 GPU P0：CPU 需要 cbo.flush/clean/inval（上游 LsuL1 的 withCbm 实现）
  --with-isa m,a,c,s,u,zicbom
  # ★ 2026-11-02 指令集扩展：**Zbb 净收益**（并行会话 A/B：zbb +3.23%、zba −1.26%、
  #   zbs 中性、全套 B +2.13% 反不如只开 zbb ⇒ **只开 zbb**）。另加 zbs（单比特操作，
  #   CoreMark 中性、面积小，内核/驱动常用）；不开 zba/zbc（前者实测负收益、后者面积大）。
  --with-rvZbb --with-rvZbs
  --with-rdtime
  # 带 MMU 时 I$/D$ 的组数都 ≤64（Vexii Param.scala:944 硬约束）:
  #   I$ = 64 sets × 8 ways × 64 B = 32 KiB；D$ = 64 sets × 4 ways × 64 B = 16 KiB
  --with-fetch-l1 --fetch-l1-sets 64 --fetch-l1-ways 8 \
  --with-lsu-l1 --lsu-l1-sets 64 --lsu-l1-ways 4 --with-lsu-bypass --lsu-l1-mem-data-width-min 64
  # 上游 max-ipc 的性能项（2026-10-18 实测：以下组合 CoreMark 4.4723 CM/MHz）：
  #   late ALU（+storeRs2Late，allowBypassFrom=0）/ store buffer 4x32 /
  #   LSU RPT + software prefetch / divRadix 4。
  # ⚠️ 不加 fetch NL 预取/refill3 与 LSU refill8/writeback8：本 SoC 上会卡死（见 spec）。
  --with-late-alu
  --lsu-l1-store-buffer-slots 4 --lsu-l1-store-buffer-ops 32
  --lsu-hardware-prefetch rpt --lsu-software-prefetch
  --div-radix 4
  --with-gshare --with-btb --with-ras
  --with-dispatcher-buffer --with-aligner-buffer
  # 130 MHz 频率专线配方（2026-10-27 台账，板级 130.5 MHz / All Constraints Met）：
  #   GShare 32 KiB **单 bank** + BTB 512 sets / tag-h16 + relaxed-mul。
  # ⚠️ 不要 GShare 64K / BTB 1024：专线实测 64K 被 PDS 拼成两块 36Kb DRAM 级联
  #    （X1CASQO，tco 1.747 + 级联 ≈0.9 ns，占 10 ns 周期 1/3），BTB 1024→512 再值 +0.19 ns；
  #    2026-10-29 用 64K+BTB1024+h20 跑 PnR：cpu_clk +0.5→+0.167、npu_clk −0.821 不收敛。
  --relaxed-mul-inputs
  --gshare-bytes 32768
  --btb-sets 512 --btb-hash-width 16
  --fetch-axi4 --lsu-axi4 --lsu-l1-axi4
  --region base=80000000,size=20000000,main=1,exe=1
  --region base=F0000000,size=10000000,main=0,exe=0
)

cd "$VEXII" || exit 1
export http_proxy="${http_proxy:-http://127.0.0.1:7897}"
export https_proxy="${https_proxy:-http://127.0.0.1:7897}"
export SBT_OPTS="-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=7897 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=7897 -Xmx6G"

"$SBT" "runMain vexiiriscv.Generate ${GEN_ARGS[*]}" >"$LOG" 2>&1
rc=$?
tail -25 "$LOG"
[ $rc -ne 0 ] && { echo "gen_core: sbt failed rc=$rc"; exit $rc; }

mkdir -p "$OUT_DIR"
cp -f "$VEXII/VexiiRiscv.v" "$OUT_DIR/VexiiRiscv.v"
echo "gen_core: wrote $OUT_DIR/VexiiRiscv.v ($(wc -l <"$OUT_DIR/VexiiRiscv.v") lines)"
