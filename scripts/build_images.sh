#!/bin/bash
# =============================================================================
# Task 11/22：buildroot 外部树 → 四个镜像（fw_jump.bin / linux.dtb / Image / rootfs.cpio）
#
# 用法（**在 WSL 里跑**；构建宿主必须在 Linux 原生 fs，/mnt/d 的 9p 慢到不可用）：
#   wsl -e bash -lc "cd /mnt/d/code/PDS/VexiiYeshenLinux && bash scripts/build_images.sh"
# 本工程默认：ISA=rv32imac、WS=$HOME/vexii-build、SRC=/mnt/d/code/PDS/VexiiYeshenLinux。
# 长任务，建议带日志后台跑：
#   ... bash scripts/build_images.sh 2>&1 | tee sim/reglogs/rv32_buildroot.log
#
# ★★ 网络前置（不加这条，phase 2 会**假死**，不是报错而是零进展）★★
#   WSL 够不到 Windows 的 Clash 代理（它只绑 127.0.0.1），而 WSL 直连 GitHub 的 git 大对象
#   传输会 `GnuTLS recv error (-110): The TLS connection was non-properly terminated`。
#   ⚠️ `git ls-remote` 能成功 **不代表** clone 能用（实测：ls-remote 秒回，clone 卡 9 分钟零进展）。
#   解法：先在 **Windows** 侧起 relay，再在 WSL 里导出代理：
#     [Windows]  python scripts/win_proxy_relay.py --bind 172.21.128.1 --port 7898
#     [WSL]      export http_proxy=http://172.21.128.1:7898 https_proxy=http://172.21.128.1:7898
#                export no_proxy="sources.buildroot.net,buildroot.net,localhost,127.0.0.1"
#   （宿主 IP 从 WSL 里 `ip route | awk '/^default/{print $3}'` 取；relay 是普通用户进程，
#     Ctrl-C 即停，不改任何配置。若哪天 Clash 开了 allow-lan 或 WSL 用 mirrored 网络，可省掉 relay。）
#
# 环境变量：
#   WS         构建工作区（默认 $HOME/naxmini-build2）—— buildroot 源码 + 外部树拷贝 + 产物
#   SRC        本仓库根（默认 /mnt/d/code/PDS/NaxYeshenLinux）
#   BR_COMMIT  buildroot 钉的 commit（默认 d030e36bbc9669230c015be971b14b6e062cfdde
#              = **tag 2025.02.18** 指向的 commit）
#              ★ Task 22 换版：2020.11 期的 9ef54b7d 在 Ubuntu 24.04（glibc 2.39）上**官方不支持** ——
#                它自带的 host-m4 1.4.18 的 gnulib `c-stack.c:55` 用 `#if SIGSTKSZ < 16384`，
#                而 glibc ≥2.34 起 SIGSTKSZ 变成 `sysconf(_SC_SIGSTKSZ)`（非常量）⇒ 预处理直接报错，
#                构建卡死在 host 前置包阶段（实测日志 sim/reglogs/t21_buildroot.log）。
#                2025.02.18 是**仍在维护的 LTS**（.18 点发布），自带 **m4 1.4.21**（c-stack.c 已不含
#                SIGSTKSZ，实测两版 tarball 对比）与 **OpenSBI 1.6**。
#   ISA        板变体的 ISA 宏文件（默认 rv64imac ⇒ configs/rv64imac.sh）
#   JOBS       并行度（默认 nproc）
#
# 口径（见 docs/superpowers/specs/2026-09-29-naxmini-linux-design.md §5.2/§5.5）：
#   · 外部树 = sw/buildroot-external（BR2_EXTERNAL=<rsync 到 Linux fs 的那份拷贝>）
#   · rsync 排除 output/ 与 host/（这两个是 buildroot 自己的状态，不该来回搬）
#   · 产物复制回 $SRC/sw/images/（**不入库**，.gitignore 已含 sw/images/）
#   · 镜像地址口径（装载链，与 check_addr_map.py / DTS / tb 四处一致）：
#       fw_jump.bin@0x8000_0000  Image@0x8200_0000  linux.dtb@0x82F8_0000  rootfs.cpio@0x8300_0000
#       （★ Y1-C4b H2b：Image/FDT/initrd 抬到 NPU arena 保留区 [0x8040_0000,0x8200_0000) 之上）
#   · ★ Task 22：`BR2_TARGET_OPENSBI_PLAT`(="out-of-tree") / `_PLAT_PATH` 这套**没变**，
#     变的是 OpenSBI 侧的平台目录形态（Kconfig + configs/defconfig + objects.mk，
#     老的 config.mk 由 objects.mk `-include` 进来）。
#   · ★ Task 22 第二轮（修 linux-headers 失败点）：2025.02 里**内核头版本符号改名**了 ——
#     老 buildroot 的 `BR2_KERNEL_HEADERS_*`（第一选择）现在在 `package/linux-headers/Config.in.host`，
#     且多了一个**第二选择** "Custom kernel headers series"，其默认是
#     `BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_REALLY_OLD`（= **2.6.x**）。用自定义 git 内核时
#     buildroot 猜不到 series ⇒ `BR2_TOOLCHAIN_HEADERS_AT_LEAST="2.6"`，而 helpers.mk 的检查是
#     **strict**（`BR2_TOOLCHAIN_HEADERS_LATEST` 未置位）⇒
#     `Incorrect selection of kernel headers: expected 2.6.x, got 5.10.x`。
#     正解（外部树已改）：`BR2_KERNEL_HEADERS_AS_KERNEL=y`（头文件与内核同源，本就是默认）+
#     `BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_5_10=y`（显式声明 series，与 SpinalHDL/linux dev
#     实测的 5.10.1 对齐；strict 检查要求 series 与内核 X.Y 完全相等）。
#     **连带坑（已一并钉死）**：glibc 对 riscv64 要求 headers >= 5.0（`package/glibc/Config.in:40`），
#     所以 2.6.x 时代 C 库选择是**静默掉到 uClibc-ng** 的；只修 series 会让默认的 glibc 生效
#     ⇒ 工具链 tuple 变化。故 defconfig 里显式 `BR2_TOOLCHAIN_BUILDROOT_UCLIBC=y` 钉住 uClibc-ng。
# =============================================================================
set -euo pipefail

WS=${WS:-$HOME/vexii-build}
SRC=${SRC:-/mnt/d/code/PDS/VexiiYeshenLinux}
EXT=$WS/naxmini-ext
BR=$WS/buildroot
BR_URL=${BR_URL:-https://github.com/buildroot/buildroot.git}
BR_COMMIT=${BR_COMMIT:-d030e36bbc9669230c015be971b14b6e062cfdde}
# ★ 本工程 = RV32（VexiiRiscv xlen=32）⇒ 默认宏档改成 rv32imac（模板是 rv64imac）。
#   对应的 XLEN/ABI/ISA/mmu-type 由 configs/rv32imac.sh 提供。
ISA=${ISA:-rv32imac}
JOBS=${JOBS:-$(nproc)}

phase() { echo; echo "========== [$(date +%H:%M:%S)] $* =========="; }

# ---- ★ Task 22：把 PATH 里的 Windows 项剔掉（buildroot 2025.02 对含空格的 PATH 直接退出）----
# 背景：WSL 默认继承 Windows 的 PATH，里面 /mnt/c/Program Files/... 这类项**含空格**
# （本机实测 21 项），而 buildroot 2025.02 的 support/dependencies/dependencies.sh 命中
# `(*" "*|*"$TAB"*|*"$NL"*)` 分支后 `exit 1`（T11 那次 2020.11 的脚本没这么严，所以没暴露）。
# 构建只需要 Linux 原生工具，剔除含空白字符的项即可（日志里打印剔掉了多少项）。
_clean_path="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '[[:space:]]' | paste -sd: -)"
if [ "$_clean_path" != "$PATH" ]; then
  echo "== PATH 净化：剔除 $(($(printf '%s' "$PATH" | tr ':' '\n' | grep -c '[[:space:]]'))) 个含空白字符的项（WSL 继承的 Windows PATH）"
  export PATH="$_clean_path"
fi
echo "== PATH = $PATH"

phase "0/6 环境自检"
echo "WS=$WS  SRC=$SRC  ISA=$ISA  JOBS=$JOBS"
echo "buildroot commit=$BR_COMMIT"
for t in make gcc g++ rsync git cpp bc bison flex unzip ccache python3 file awk wget cpio find perl; do
  command -v "$t" >/dev/null 2>&1 || { echo "ERROR: 缺宿主工具 $t" >&2; exit 9; }
done
mkdir -p "$WS"

phase "1/6 rsync 外部树 → $EXT（排除 output/host）"
mkdir -p "$EXT"
rsync -a --delete --exclude output --exclude host \
      "$SRC/sw/buildroot-external/" "$EXT/"
# 生成物（defconfig / linux.config / linux.dts / opensbi config.mk）落在 /mnt/d 那份里，
# 上面 rsync 已经带过来；这里再跑一次 setup 保证它们一定存在且是最新（幂等）。
bash "$EXT/naxmini_setup.sh" "$ISA"
for f in configs/naxmini_defconfig boards/naxmini/linux/linux.config \
         boards/naxmini/linux/linux.dts boards/naxmini/opensbi/config.mk \
         boards/naxmini/opensbi/objects.mk boards/naxmini/opensbi/Kconfig; do
  [ -s "$EXT/$f" ] || { echo "ERROR: setup 未产出（或外部树缺）$f" >&2; exit 9; }
done
# OpenSBI >= 1.x 的平台目录还必须有 configs/defconfig（可以为空文件，用 -e 而不是 -s）
[ -e "$EXT/boards/naxmini/opensbi/configs/defconfig" ] || \
  { echo "ERROR: 缺 boards/naxmini/opensbi/configs/defconfig（OpenSBI 1.x 的 Kconfig 流程需要它）" >&2; exit 9; }
echo "外部树 $(find "$EXT" -type f | wc -l) 个文件；external.desc = $(cat "$EXT/external.desc")"

phase "2/6 buildroot 源码 @ $BR_COMMIT"
if [ ! -d "$BR/.git" ]; then
  mkdir -p "$BR"
  git init -q "$BR"
  git -C "$BR" remote add origin "$BR_URL"
fi
if [ "$(git -C "$BR" rev-parse HEAD 2>/dev/null || true)" != "$BR_COMMIT" ]; then
  git -C "$BR" fetch --depth 1 origin "$BR_COMMIT"
  git -C "$BR" checkout -q --detach "$BR_COMMIT"
fi
echo "buildroot HEAD = $(git -C "$BR" rev-parse HEAD)  ($(git -C "$BR" log --oneline -1))"
echo "buildroot opensbi 版本 = $(sed -n 's/^OPENSBI_VERSION = //p' "$BR"/boot/opensbi/opensbi.mk)"
bash "$BR"/support/dependencies/dependencies.sh

phase "3/6 buildroot defconfig（BR2_EXTERNAL=$EXT naxmini_defconfig）"
make -C "$BR" BR2_EXTERNAL="$EXT" naxmini_defconfig
# ★ Task 22 修：T11 那句 grep 的路径在带/不带 O= 时不同（默认 O=output 时才在 output/.config），
#   两边都试；`|| true` 保留（这里只是诊断打印，不是判据）。
for cfg in "$BR/output/.config" "$BR/.config"; do
  [ -f "$cfg" ] && { echo "--- defconfig 生效项（$cfg）"; \
    grep -E "BR2_EXTERNAL_NAXMINI_PATH|BR2_TARGET_OPENSBI_PLAT|BR2_LINUX_KERNEL_CUSTOM_REPO|BR2_GCC_VERSION|BR2_TOOLCHAIN_BUILDROOT_LIBC|BR2_TOOLCHAIN_BUILDROOT_UCLIBC|BR2_KERNEL_HEADERS_AS_KERNEL|BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_[0-9_]+=y|BR2_TOOLCHAIN_HEADERS_AT_LEAST=" "$cfg"; }
done

# ★ 用 `${VAR-...}`（**不补空**）而不是 `${VAR:-...}`：显式传 `REBUILD_PKGS=` 空串 = **跳过**重建。
#   （`:-` 会把空串当成"未设"而套上默认值；这条踩过，写进注释免得下次再犯。）
REBUILD_PKGS=${REBUILD_PKGS-"opensbi linux"}
phase "3.5/6 强制重建板级输入已变的包（**先 dirclean 再 rebuild**）：${REBUILD_PKGS:-<无>}"
# ★ 为什么必须显式重建（2026-10-07 定案，**已实际踩过**）：
#   buildroot **不把 BR2_EXTERNAL 里的板级文件当成包的依赖**，所以改了它们
#   （`boards/naxmini/opensbi/platform.c` 的 `NAX_CONSOLE_BAUD`、
#    `boards/naxmini/linux/linux.dts` 这个 `BR2_LINUX_KERNEL_CUSTOM_DTS_PATH` 的 cpp 生成物）
#   再跑 `make` 会**静默沿用上一次的产物**。
#   实证：28800 那轮只重建了 linux、**opensbi 一次都没重建** ⇒ SBI/earlycon 控制台仍停在
#   115200，而内核 console 已是 28800 ⇒ 启动日志前段跨两个波特率、全是垃圾（当时被误判成
#   "OpenSBI 不认这个波特"）。`rootfs.cpio` 不受影响（每次 make 都会重打）。
#   ⇒ 默认两个都重建；想跳过就 `REBUILD_PKGS=` 置空。
REBUILD_PKGS=${REBUILD_PKGS:-"opensbi linux"}
# ⚠️ 只用 `-rebuild` **不可靠**（2026-10-07 实测）：opensbi 的 out-of-tree 平台改 `platform.c`
#    后跑 `make opensbi-rebuild`，产物可能仍与上一版**逐字节相同**（= 没真编）。
#    A/B 实证：platform.c 115200 → 28800 时 `-rebuild` 出了新产物，但把源码改回 115200 再
#    `-rebuild` 得到的还是 28800 那一份 md5；**改成先 `-dirclean` 再重建**，才回到与最初
#    115200 构建**完全相同**的 `fw_jump.bin`（md5 740adce4…）。
#    `-dirclean` 删的是 output/build/<pkg>（不删 DL 缓存/源码包）⇒ 仍然离线。
for p in $REBUILD_PKGS; do
  echo ">>> make $p-dirclean && make $p-rebuild"
  make -C "$BR" BR2_EXTERNAL="$EXT" -j"$JOBS" "$p-dirclean"
  make -C "$BR" BR2_EXTERNAL="$EXT" -j"$JOBS" "$p-rebuild"
done

phase "4/6 buildroot 全量构建（host 工具链 → 交叉工具链 → OpenSBI → 内核 → rootfs）"
echo ">>> 这一步是长任务（第一次通常数小时）；日志里按 buildroot 的 package 名推进。"
make -C "$BR" BR2_EXTERNAL="$EXT" -j"$JOBS"

phase "5/6 复制四个镜像 → $SRC/sw/images/"
mkdir -p "$SRC/sw/images"
cp -f "$BR"/output/images/rootfs.cpio "$SRC/sw/images/"
cp -f "$BR"/output/images/Image       "$SRC/sw/images/"
if [ -f "$BR"/output/images/linux.dtb ]; then
  cp -f "$BR"/output/images/linux.dtb "$SRC/sw/images/"
else
  cp -f "$EXT"/boards/naxmini/linux/linux.dtb "$SRC/sw/images/"
fi
cp -f "$BR"/output/images/fw_jump.bin "$SRC/sw/images/"
ls -l "$SRC/sw/images/"

phase "6/6 镜像形状自检（magic + 尺寸）"
python3 - "$SRC/sw/images" <<'PY'
import struct, sys, pathlib
p = pathlib.Path(sys.argv[1])
img = (p / "Image").read_bytes()
print("Image     ", len(img), "bytes  magic@0x38 =", img[0x38:0x3c].hex(), "(RISC-V 应为 05435352)")
cpio = (p / "rootfs.cpio").read_bytes()
print("rootfs.cpio", len(cpio), "bytes  magic =", cpio[:6], "(应为 b'070701')")
dtb = (p / "linux.dtb").read_bytes()
print("linux.dtb ", len(dtb), "bytes  magic =", hex(struct.unpack(">I", dtb[:4])[0]), "(应为 0xd00dfeed)")
fw = (p / "fw_jump.bin").read_bytes()
print("fw_jump.bin", len(fw), "bytes  magic =", hex(struct.unpack(">I", fw[:4])[0]))
PY
echo
echo "========== [$(date +%H:%M:%S)] DONE =========="
