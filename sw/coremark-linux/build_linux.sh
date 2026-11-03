#!/usr/bin/env bash
# =============================================================================
# build_linux.sh —— 交叉编一个 **Linux 用户态** CoreMark（给板子上跑）
#
# 为什么这么干：板上已经有 Linux + ssh ⇒ 编个用户态可执行、scp 上去就能跑，
#   **不用动比特流 / 镜像 / TF 卡**（裸机那条线才要装载器配合）。
#
# 用法（**在 WSL 里跑**，工具链在 WSL 的 buildroot 输出里）：
#   wsl -e bash -lc 'cd /mnt/d/code/PDS/VexiiYeshenLinux && bash sw/coremark-linux/build_linux.sh 10'
#   第一个参数是 ITERATIONS（默认 10 —— 只当**快速判据**用，不是合法分数）
#   合法分数要求跑够 ≥10 秒（CoreMark 自己会在结果里报 "Must execute for at least 10 secs"）
#
# 环境变量：
#   CC   交叉编译器（默认取 buildroot 输出里的 riscv32-buildroot-linux-uclibc-gcc）
#
# ⚠️ 参数一律用**数组**传：`-DFLAGS_STR="..."` 这种带内层引号的参数，若走普通字符串会
#    在 Git Bash→WSL→bash→gcc 的某层被吃掉引号（实测报 `expected expression before ')'`）。
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")" || exit 9

ITERS=${1:-10}
CC=${CC:-$HOME/vexii-build/buildroot/output/host/bin/riscv32-buildroot-linux-uclibc-gcc}
[ -x "$CC" ] || { echo "!! 找不到交叉编译器：$CC（先跑过 scripts/build_all.sh --only images 就有了）"; exit 2; }

# 与 `sw/coremark/Makefile` 的裸机版**同一套优化旗标**（好做 A/B 对照），去掉裸机专属项、加 -static
CFLAGS=(
  -O3 -fno-common -funroll-loops -finline-functions -falign-functions=16
  -falign-jumps=4 -falign-loops=4 -finline-limit=1000 -fno-if-conversion2
  -fno-crossjumping -freorder-blocks-and-partition
  -march=rv32imac_zicsr_zifencei -mabi=ilp32 -mcmodel=medany
  -Wall -static
)
DEFS=(
  -DPERFORMANCE_RUN=1 -DITERATIONS="$ITERS" -DTOTAL_DATA_SIZE=2000
  '-DFLAGS_STR="-O3 rv32imac_zicsr_zifencei/ilp32"'
)
SRCS=( core_list_join.c core_main.c core_matrix.c core_state.c core_util.c port/core_portme.c )
OUT="coremark_linux_i${ITERS}"

echo "CC     = $CC"
echo "ITERS  = $ITERS   (-static, PERFORMANCE_RUN, TOTAL_DATA_SIZE=2000)"
"$CC" "${CFLAGS[@]}" "${DEFS[@]}" -I. -Iport "${SRCS[@]}" -o "$OUT" || { echo "!! 编译失败"; exit 3; }
# strip：默认带 debug_info 有 270 KB，在这块板子的网络上传输很脆 ⇒ 去掉后 ~50 KB，
# 一次 ssh 就能可靠传完（实测未 strip 时多次 transfer 会话被拖死）。
"${CC%gcc}strip" "$OUT" 2>/dev/null || true
ls -l "$OUT"
echo "下一步："
echo "  scp $OUT root@192.168.1.110:/tmp/    （KEX 见 docs/board_bringup.md §6）"
echo "  ssh root@192.168.1.110 '/tmp/$OUT'"
