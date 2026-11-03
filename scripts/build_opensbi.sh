#!/bin/bash
# =============================================================================
# Task 22（M2-b）：构建 OpenSBI（out-of-tree 平台 = sw/opensbi-platform）→ sw/images/fw_jump.bin
#
# 用法（在 WSL 里跑；**工作区要在 Linux 原生 fs 上，别用 /mnt/d**，/mnt 下 make 会慢一个数量级）：
#   wsl -e bash -lc "cd /mnt/d/code/PDS/NaxYeshenLinux && WS=~/naxmini-build2 bash scripts/build_opensbi.sh"
#
# 环境变量：
#   WS            构建工作区（默认 $HOME/naxmini-build2）—— opensbi 源码 clone 在这里
#   OPENSBI_REF   opensbi 版本（默认 v1.6，**与 buildroot 2025.02.18 自带的版本一致**）
#   CROSS_COMPILE 交叉前缀（默认 riscv64-unknown-elf-）
#   OPENSBI_ISA   **可选**：覆盖 PLATFORM_RISCV_ISA（Task 10 的无 C 对照用 rv64ima_zicsr_zifencei）
#   OPENSBI_ABI   **可选**：覆盖 PLATFORM_RISCV_ABI（对照用 lp64）
#   OPENSBI_OUT   **可选**：产物在 sw/images/ 下的文件名（默认 fw_jump.bin）
#
# ★ 覆盖是**走 make 命令行变量**（`make PLATFORM_RISCV_ISA=…`）——make 的命令行赋值**优先于**
#   Makefile/`config.mk` 里的赋值，所以 `sw/opensbi-platform/config.mk` 可以**一个字都不改**；
#   （⚠️ 用环境变量 `PLATFORM_RISCV_ISA=… make` 是**无效的**：Makefile 里的 plain assignment
#    会盖掉环境变量，除非 make -e ⇒ 产物会静默保持 rv64imac。Task 10 实测确认了这条。）
#
# -----------------------------------------------------------------------------
# ★ Task 22：为什么从 v0.8 换到 v1.6
#   换 buildroot（→ 2025.02.18，自带 **OpenSBI 1.6**）就必须换 platform.c：v0.8 的
#   `sbi_platform_operations`（pmp_region_count / console_putc / ipi_send / system_reset …）
#   在 v1.x 整族换成了**设备驱动模型**。老版 platform.c 已归档：
#       attic/opensbi08-platform/{platform.c,config.mk,objects.mk}
#   要复现 Task 9/10/11 的 v0.8 构建：把那三个文件拷回 sw/opensbi-platform/ 再
#   `OPENSBI_REF=v0.8 bash scripts/build_opensbi.sh`（本脚本的逻辑对两个版本都成立，
#   区别只是平台目录的内容与 OPENSBI_REF）。
#
# ★ v1.6 的 out-of-tree 挂法与 v0.8 的差别（本脚本与 buildroot 外部树用的是同一口径）：
#   · 用**同一个** `<opensbi>/platform/<name>/` 机制（`make PLATFORM=<name>`），我们是
#     name=`out-of-tree`（buildroot 的 `BR2_TARGET_OPENSBI_PLAT="out-of-tree"` 同值）；
#     v1.6 另外还官方支持 `PLATFORM_DIR=<path>`（Makefile 行 44-53），这里**不用**它，
#     为的是与 buildroot 那条路径逐字一致（Gate 1 验的就是 buildroot 会走的那条）。
#   · 平台目录现在必须带 **`Kconfig`**（声明 PLATFORM_xxx + select 三个驱动）+
#     **`configs/defconfig`**（v1.6 用 Kconfiglib 生成 .config，可以为空）+ **`objects.mk`**；
#     v0.8 的 `config.mk` **不再被 Makefile 自动 include** ⇒ 由 objects.mk 里
#     `-include $(platform_src_dir)/config.mk` 拉进来（三个 FW_* 与 XLEN/ABI/ISA 仍在 config.mk 里）。
#   · 依赖宿主 `python3`（Kconfiglib），下面做了存在性检查。
#
# ★ 工具链：本机同时有 riscv64-linux-gnu-gcc 与 riscv64-unknown-elf-gcc。
#   Task 22 起**按 PIE 能力挑**（见下面的循环）：`riscv64-unknown-elf-ld.bfd` 不支持 `-pie`，
#   编不了 OpenSBI ≥1.0；`riscv64-linux-gnu-` 通过，且与 buildroot 自建的
#   `riscv64-buildroot-linux-gnu-` 是同一类（Step 4 的构建就是走那条）。
#   bare-metal 语义没问题：OpenSBI 全程 `-nostdlib/-ffreestanding`，只借 gcc 当编译器/汇编器。
#
# ★ ABI/ISA 在 sw/opensbi-platform/config.mk 里写死为 **lp64 + rv64imac_zicsr_zifencei**
#   （核没有 F/D；用 lp64d 会直接非法指令）。
# =============================================================================
set -e

WS=${WS:-$HOME/naxmini-build2}         # Linux 原生 fs，不要用 /mnt/d
OPENSBI_REF=${OPENSBI_REF:-v1.6}
OPENSBI=$WS/opensbi
OPENSBI_OUT=${OPENSBI_OUT:-fw_jump.bin}

# ---- 可选：ISA / ABI 覆盖（走 make 命令行变量，config.mk 不动）----------------
# 只有显式传了才覆盖；不传 ⇒ 与 Task 9 完全同一条命令、同一个产物。
ISA_OVERRIDE=()
[ -n "$OPENSBI_ISA" ] && ISA_OVERRIDE+=("PLATFORM_RISCV_ISA=$OPENSBI_ISA")
[ -n "$OPENSBI_ABI" ] && ISA_OVERRIDE+=("PLATFORM_RISCV_ABI=$OPENSBI_ABI")
echo "== isa/abi override: ${ISA_OVERRIDE[*]:-<none: 用 config.mk 原值>}  out=$OPENSBI_OUT"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# ---- 宿主依赖 ---------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || { echo "ERROR: 缺 python3（OpenSBI >= 1.x 的 Kconfiglib 需要它）" >&2; exit 9; }

# ---- 交叉工具链 -------------------------------------------------------------
# ★ Task 22：改成**按能力挑**（PIE 链接能力），不再是"elf 优先"。
#   实测（Ubuntu 24.04，binutils 2.42）：`riscv64-unknown-elf-ld.bfd` 直接报
#   `-pie not supported` ⇒ 连 OpenSBI 自带的检查都过不了（Makefile:196 的
#   `OPENSBI_LD_PIE`，v1.0 起 fw 要 PIE/relocatable），Task 9 时代 v0.8 没有这条要求，
#   所以那时 elf 前缀能用。而 `riscv64-linux-gnu-`（bfd）通过。
#   ★ 这也**正是 buildroot 走的路**：它用自建的 `riscv64-buildroot-linux-gnu-`（同为
#     linux-gnu 类）编 OpenSBI，所以 Gate 1 用它反而与 Step 4 的构建口径一致。
#   判据就是 OpenSBI 自己那条命令（-fuse-ld=bfd -fPIE -nostdlib -Wl,-pie）。
if [ -z "$CROSS_COMPILE" ]; then
  for p in riscv64-linux-gnu- riscv64-unknown-elf-; do
    if command -v "${p}gcc" >/dev/null 2>&1 && \
       "${p}gcc" -fuse-ld=bfd -fPIE -nostdlib -Wl,-pie -x c /dev/null -o /dev/null >/dev/null 2>&1; then
      CROSS_COMPILE=$p
      break
    fi
  done
fi
if [ -z "$CROSS_COMPILE" ] || ! command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
  echo "ERROR: 找不到能编 OpenSBI >=1.x 的交叉工具链（需要支持 -pie 的 bfd；试过 riscv64-linux-gnu- / riscv64-unknown-elf-）" >&2
  exit 9
fi
echo "== toolchain: ${CROSS_COMPILE}gcc ($(${CROSS_COMPILE}gcc -dumpversion))"
echo "== opensbi ref: $OPENSBI_REF   ws: $WS"

# ---- opensbi 源码（按 ref 钉住）---------------------------------------------
if [ ! -d "$OPENSBI" ]; then
  mkdir -p "$WS"
  git clone --branch "$OPENSBI_REF" --depth 1 \
      https://github.com/riscv-software-src/opensbi.git "$OPENSBI"
fi
# 已经存在但不是目标 ref ⇒ 取回该 tag 并切过去（保证可复现）
if ! git -C "$OPENSBI" rev-parse -q --verify "refs/tags/$OPENSBI_REF" >/dev/null 2>&1 \
   && [ "$(git -C "$OPENSBI" describe --tags --abbrev=0 2>/dev/null)" != "$OPENSBI_REF" ]; then
  git -C "$OPENSBI" fetch --depth 1 origin "refs/tags/$OPENSBI_REF:refs/tags/$OPENSBI_REF"
fi
git -C "$OPENSBI" checkout -q "$OPENSBI_REF" 2>/dev/null || true
echo "== opensbi HEAD: $(git -C "$OPENSBI" describe --tags --always) ($(git -C "$OPENSBI" log --oneline -1))"

# ---- 平台目录（out-of-tree 写法：拷进 <opensbi>/platform/out-of-tree）---------
# ★ rm -rf 先清掉：否则上一轮（比如 v0.8 的）build 残留文件会混进来（同 buildroot 的 hook 口径）
rm -rf "$OPENSBI/platform/out-of-tree"
cp -r "$REPO/sw/opensbi-platform" "$OPENSBI/platform/out-of-tree"
ls "$OPENSBI/platform/out-of-tree" "$OPENSBI/platform/out-of-tree/configs"

export OPENSBI_PLATFORM=out-of-tree
export PLATFORM_RISCV_XLEN=64
export CROSS_COMPILE

# ---- 构建 -------------------------------------------------------------------
make -C "$OPENSBI" PLATFORM=$OPENSBI_PLATFORM clean >/dev/null
make -C "$OPENSBI" PLATFORM=$OPENSBI_PLATFORM "${ISA_OVERRIDE[@]}" -j"$(nproc)"

# ---- 产物 -------------------------------------------------------------------
mkdir -p "$REPO/sw/images"
cp "$OPENSBI/build/platform/$OPENSBI_PLATFORM/firmware/fw_jump.bin" "$REPO/sw/images/$OPENSBI_OUT"
echo "fw_jump.bin -> sw/images/$OPENSBI_OUT  $(stat -c%s "$REPO/sw/images/$OPENSBI_OUT") bytes"
echo "fw_jump.elf  = $OPENSBI/build/platform/$OPENSBI_PLATFORM/firmware/fw_jump.elf"

# ---- 取证：编出来的 ELF 自报的 arch 属性（**判据有效性的第一道证**）----------
ELF="$OPENSBI/build/platform/$OPENSBI_PLATFORM/firmware/fw_jump.elf"
if command -v "${CROSS_COMPILE}readelf" >/dev/null 2>&1; then
  echo "== ${CROSS_COMPILE}readelf -A (Tag_RISCV_arch) =="
  "${CROSS_COMPILE}readelf" -A "$ELF" | grep -E "Tag_RISCV_arch" || true
fi

# ---- 取证：Kconfig 生成的选择（确认三个驱动真的被 select 进来了）-------------
AUTOCONF="$OPENSBI/build/platform/$OPENSBI_PLATFORM/kconfig/.config"
if [ -f "$AUTOCONF" ]; then
  echo "== platform kconfig ($AUTOCONF) =="
  grep -E "^CONFIG_(PLATFORM_|SERIAL_|IPI_|TIMER_)" "$AUTOCONF" || true
fi
