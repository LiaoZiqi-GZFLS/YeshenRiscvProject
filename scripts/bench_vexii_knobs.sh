#!/bin/bash
# 用上游 RegressionSingle 台架量化两组旋钮的边际收益（理想内存口径）。
# 在 WSL 里运行；只操作 REPO 指向的 VexiiRiscv 副本，不碰第三方位。
#
# 变体：
#   base : 当前 SoC 配置（无 fetch NL prefetch/refill3、无 LSU refill8/writeback8）
#   fetch: + --fetch-l1-refill-count 3 --fetch-l1-hardware-prefetch nl
#   lsu  : + --lsu-l1-refill-count 8 --lsu-l1-writeback-count 8
#   both : 两组都开
#
# 用法：REPO=$HOME/vexii_knobs bash scripts/bench_vexii_knobs.sh [base fetch lsu both]
set -u

REPO="${REPO:-$HOME/vexii_knobs}"
SBT="${SBT:-sbt}"
LOG_DIR="${LOG_DIR:-$REPO/bench_logs}"
TIMEOUT="${TIMEOUT:-3600}"
VARIANTS=("$@")
[ ${#VARIANTS[@]} -eq 0 ] && VARIANTS=(base fetch lsu both)

cd "$REPO" || { echo "no repo: $REPO"; exit 1; }
mkdir -p "$LOG_DIR"

# 台架改造（幂等）：不 dump FST 波形；benchmark 只跑 coremark；
# 理想内存系数可由 BMK_READY_FACTOR 覆盖（2.0=始终 ready，越小背压越大）。
python3 - "$REPO" <<'PY'
import sys
p = sys.argv[1] + "/src/test/scala/vexiiriscv/tester/RegressionSingle.scala"
s = open(p).read()
s = s.replace("simConfig.withFstWave", "// simConfig.withFstWave // disabled for long benchmarks")
s = s.replace('val benchmarks = ArrayBuffer("dhrystone_vexii", "coremark_vexii")',
              'val benchmarks = ArrayBuffer("coremark_vexii")')
s = s.replace("args.ibusReadyFactor(2.0)",
              'args.ibusReadyFactor(sys.env.getOrElse("BMK_READY_FACTOR", "2.0").toDouble)')
s = s.replace("args.dbusReadyFactor(2.0)",
              'args.dbusReadyFactor(sys.env.getOrElse("BMK_READY_FACTOR", "2.0").toDouble)')
open(p, "w").write(s)
PY
grep -n "withFstWave\|val benchmarks\|BMK_READY_FACTOR" src/test/scala/vexiiriscv/tester/RegressionSingle.scala | head -6

COMMON="--xlen 32 --decoders 2 --lanes 2 --with-isa m,a,c,s,u --with-rdtime
  --with-fetch-l1 --fetch-l1-sets 64 --fetch-l1-ways 8
  --with-lsu-l1 --lsu-l1-sets 64 --lsu-l1-ways 4 --with-lsu-bypass --lsu-l1-mem-data-width-min 64
  --with-late-alu --lsu-l1-store-buffer-slots 4 --lsu-l1-store-buffer-ops 32
  --lsu-hardware-prefetch rpt --lsu-software-prefetch --div-radix 4
  --with-gshare --with-btb --with-ras --with-dispatcher-buffer --with-aligner-buffer"
FILTERS="--without-riscv-tests --without-riscv-arch-tests --without-buildroot-tests
  --without-regular-tests --without-jtag-tests --with-free-rtos-tests-count 0"

export SBT_OPTS="${SBT_OPTS:--Xmx6G -Xss8M}"

for v in "${VARIANTS[@]}"; do
  extra=""
  case "$v" in
    base) ;;
    fetch) extra="--fetch-l1-refill-count 3 --fetch-l1-hardware-prefetch nl" ;;
    lsu)   extra="--lsu-l1-refill-count 8 --lsu-l1-writeback-count 8" ;;
    both)  extra="--fetch-l1-refill-count 3 --fetch-l1-hardware-prefetch nl --lsu-l1-refill-count 8 --lsu-l1-writeback-count 8" ;;
    *) echo "unknown variant: $v"; exit 2 ;;
  esac
  log="$LOG_DIR/$v.log"
  rm -rf regression
  echo "=== $v: $extra ===" | tee "$log"
  timeout "$TIMEOUT" "$SBT" --batch -Dsbt.color=false -Dsbt.log.noformat=true \
    "Test/runMain vexiiriscv.tester.RegressionSingle ${COMMON//$'\n'/ } ${FILTERS//$'\n'/ } $extra" >>"$log" 2>&1
  rc=$?
  echo "rc=$rc" | tee -a "$log"
  grep -E "Coremark/MHz|CoreMark 1.0|Iterations[ /]|ERROR|Exception|Timeout" "$log" | tail -8
  found=$(find regression -path "*benchmark/coremark_vexii/stdout.log" 2>/dev/null | head -1)
  [ -n "$found" ] && cp -f "$found" "$LOG_DIR/$v.stdout.log"
done

echo
echo "=== summary (Coremark/MHz) ==="
for v in "${VARIANTS[@]}"; do
  printf '%-6s ' "$v"
  grep -h "Coremark/MHz" "$LOG_DIR/$v.log" "$LOG_DIR/$v.stdout.log" 2>/dev/null | tail -1 || echo "(no score)"
done
