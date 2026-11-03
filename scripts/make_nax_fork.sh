#!/usr/bin/env bash
# ============================================================================
# make_nax_fork.sh -- T33 路线 A：把上游复制成"独立目录副本"，在副本里打 F2，
#                     原仓库（/mnt/d/code/PDS/NaxRiscv）逐字节不动（脚本自证）。
#
# 用法（WSL）：  bash scripts/make_nax_fork.sh
# 产物：         third_party/nax-fork/NaxRiscv/   （含打过 F2 的 ext/SpinalHDL）
# 生成（Windows 侧 sbt，用副本的 NaxRiscv 当工作目录；产物进新目录 rtl_hubfix/）：
#   cd <fork>/NaxRiscv
#   sbt "runMain naxriscv.platform.litex.NaxGen \
#     --netlist-directory ../../rtl_hubfix --netlist-name NaxSocMini \
#     --reset-vector 0x80000000 --xlen 64 \
#     --litedram-width 64 --l2-bytes 0 \
#     --memory-region 2147483648,536870912,cx,m \
#     --memory-region 4026531840,16384,rw,p \
#     --scala-file ../../sw/gen/plugins.scala"
#
# !! 区域参数必须与**交付的 rtl/** 一致：外设 region 是 **16384（16 KiB）**，不是 16777216（16 MiB）。
#    用 16 MiB 会让地址译码器不同（argsHits_3_addrHit 的掩码 0xff000000 vs 0xffffc000）⇒ A/B 被混淆。
#    规范命令见 docs/冻结调查-2026-09-30.md §13.10 与 scripts/gen_hubfix.bat。
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # = NaxYeshenLinux
UPSTREAM="${UPSTREAM:-/mnt/d/code/PDS/NaxRiscv}"  # 上游（只读）
FORK="$HERE/third_party/nax-fork"
DST="$FORK/NaxRiscv"
PATCH="$HERE/patches/hub-f2-valids-alloc-priority.patch"
HUB_REL="ext/SpinalHDL/lib/src/main/scala/spinal/lib/bus/tilelink/coherent/Hub.scala"

[ -f "$PATCH" ] || { echo "缺 patch: $PATCH"; exit 1; }
[ -d "$UPSTREAM" ] || { echo "缺上游: $UPSTREAM"; exit 1; }

echo "== 0. 上游 Hub.scala 基线指纹（用于事后自证未被动过）=="
BEFORE=$(sha256sum "$UPSTREAM/$HUB_REL" | awk '{print $1}')
echo "   upstream $HUB_REL = $BEFORE"

echo "== 1. 复制副本（排除 .git/target/obj，保持轻量）=="
mkdir -p "$FORK"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete \
    --exclude '.git' --exclude 'target' --exclude 'obj' --exclude 'obj_dir*' \
    "$UPSTREAM/" "$DST/"
else
  rm -rf "$DST"; mkdir -p "$DST"
  (cd "$UPSTREAM" && tar cf - --exclude=.git --exclude=target --exclude=obj --exclude='obj_dir*' .) \
    | (cd "$DST" && tar xf -)
fi
# build.sbt 直接引用这个**预编译 jar 的路径**（-Xplugin:.../idslplugin/target/.../*.jar），
# 所以 target/ 被排除后必须单独补回这一小棵（196K），否则编译期报找不到 -Xplugin。
mkdir -p "$DST/ext/SpinalHDL/idslplugin/target"
cp -a "$UPSTREAM/ext/SpinalHDL/idslplugin/target/." "$DST/ext/SpinalHDL/idslplugin/target/"
echo "   复制完成: $DST（含 idslplugin/target 的预编译 jar）"

echo "== 2. 在副本里打 F2 =="
# 注意：上游是 **CRLF** 检出（新克隆 / Windows 侧都是）⇒ 不能用 `patch`（报 different line endings）。
# 用 python3 做**保 EOL** 的精确替换；packets 里的 .patch 仍作为"改了什么"的规范留档。
python3 - "$DST/$HUB_REL" <<'PY'
import sys
p = sys.argv[1]
old = "valids := (valids | freeOh.andMask(allocate)) & ~(UIntToOh(release.payload).andMask(release.valid))"
new = "valids := (valids & ~(UIntToOh(release.payload).andMask(release.valid))) | freeOh.andMask(allocate)"
s = open(p, "r", newline="").read()
if new in s:
    print("   已是 F2 版（幂等）"); sys.exit(0)
n = s.count(old)
if n != 1:
    print("   !! 期望匹配 1 处，实际 %d 处" % n); sys.exit(1)
open(p, "w", newline="").write(s.replace(old, new))
print("   F2 applied（1 处，EOL 保持不变）")
PY

echo "== 3. 自证 =="
AFTER=$(sha256sum "$UPSTREAM/$HUB_REL" | awk '{print $1}')
echo "   upstream 现在 = $AFTER"
[ "$BEFORE" = "$AFTER" ] && echo "   OK: 上游零改动" || { echo "   !! 上游被改了，去查"; exit 1; }
echo "   副本里那一行："
grep -n "valids :=" "$DST/$HUB_REL"
echo
echo "下一步：在 Windows 侧按本脚本头部注释里的 sbt 命令，用副本生成 rtl_hubfix/。"
