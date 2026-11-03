#!/usr/bin/env bash
# =============================================================================
# build_ddr_bw_test.sh —— 交叉编 y1/partA/ddr_bw_test.c 成 **Linux 用户态**可执行
#
# 为什么这么干：板上已经有 Linux + ssh ⇒ 编个用户态可执行、scp 上去就能跑，
#   **不动比特流 / 镜像 / TF 卡**（裸机那条线才要装载器配合）。本任务只往
#   /tmp 放一个用户态二进制。
#
# 用法（**在 WSL 里跑**，工具链在 WSL 的 buildroot 输出里）：
#   wsl -e bash -lc 'cd /mnt/d/code/PDS/VexiiYeshenLinux && bash y1/partA/build_ddr_bw_test.sh'
#
# 环境变量：
#   CC   交叉编译器（默认取 buildroot 输出里的 riscv32-buildroot-linux-uclibc-gcc）
#
# ⚠️ 参数一律用**数组**传（同 sw/coremark-linux/build_linux.sh 的文件头）：
#    带内层引号的参数若走普通字符串，会在 Git Bash→WSL→bash→gcc 的某层被吃掉引号
#    （实测报 `expected expression before ')'`）。本程序暂无带引号参数，但保持同一
#    形式，便于 A/B 对照与后续加 -D。
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")" || exit 9

CC=${CC:-$HOME/vexii-build/buildroot/output/host/bin/riscv32-buildroot-linux-uclibc-gcc}
[ -x "$CC" ] || { echo "!! 找不到交叉编译器：$CC（先跑过 scripts/build_all.sh --only images 就有了）"; exit 2; }

SRC=ddr_bw_test.c
OUT=ddr_bw_test

# 与 sw/coremark-linux/build_linux.sh 同一套优化旗标（去掉裸机专属项、加 -static），
# 好与既有的板上基线做 A/B 对照。rv32imac_zicsr_zifencei / ilp32 / medany 是本核口径。
CFLAGS=(
  -O3 -fno-common -funroll-loops -finline-functions -falign-functions=16
  -falign-jumps=4 -falign-loops=4 -finline-limit=1000
  -march=rv32imac_zicsr_zifencei -mabi=ilp32 -mcmodel=medany
  -Wall -static
)

echo "CC   = $CC"
echo "SRC  = y1/partA/$SRC   (-O3 -static, rv32imac_zicsr_zifencei/ilp32)"
"$CC" "${CFLAGS[@]}" "$SRC" -o "$OUT" || { echo "!! 编译失败"; exit 3; }

# strip：默认带 debug_info 有 ~270 KB，在这块板子的网络上传输很脆 ⇒ 去掉后 ~50 KB，
# 一次 ssh 就能可靠传完（实测未 strip 时多次 transfer 会话被拖死）。**这一步不可省**。
"${CC%gcc}strip" "$OUT" 2>/dev/null || true
ls -l "$OUT"
echo "下一步："
echo "  scp $OUT root@192.168.1.110:/tmp/    （KEX 见 docs/board_bringup.md §6）"
echo "  ssh root@192.168.1.110 '/tmp/$OUT'"
