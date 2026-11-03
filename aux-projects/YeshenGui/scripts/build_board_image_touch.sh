#!/usr/bin/env bash
# Build the Phase R touch image from the independent touch kernel and the
# existing images/ snapshot. Never overwrites the default/gui2 pairs and never
# reads or writes VexiiYeshenLinux.
#
# Usage (inside WSL):
#   bash scripts/build_board_image_touch.sh
#   KERNEL=/mnt/d/code/PDS/YeshenGuiKernel/out bash scripts/build_board_image_touch.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="${KERNEL:-/mnt/d/code/PDS/YeshenGuiKernel/out}"
IMG="$ROOT/images"
OVERLAY="$ROOT/board/rootfs_overlay"
WS="${WS:-$HOME/yeshen-gui-build/rootfs_touch}"

ROOTFS_OUT="$IMG/rootfs_gui_touch.cpio.gz"
DTB_OUT="$IMG/linux_touch.dtb"
SD_OUT="$IMG/sd_gui_touch.img"
IMAGE_IN="$IMG/Image.touch"
DTB_IN="$KERNEL/linux_touch.dtb"
IMAGE_SRC="$KERNEL/Image.touch"
PACKER="$ROOT/board/mk_sd_gui.py"
LIST="$WS/rootfs_touch.list"
DTB_ADDR=0x82F80000
INITRD_START=0x83000000

need() { command -v "$1" >/dev/null 2>&1 || { echo "FAIL: missing tool $1" >&2; exit 1; }; }
die() { echo "FAIL: $*" >&2; exit 1; }
need cpio
need gzip
need python3
need dtc

# Default/gui2 pairs must stay byte-identical.
DEFAULT_OUTPUTS=(
  "$IMG/rootfs_gui.cpio.gz" "$IMG/linux_gui.dtb" "$IMG/sd_gui.img"
  "$IMG/rootfs_gui2.cpio.gz" "$IMG/linux_gui2.dtb" "$IMG/sd_gui2.img"
  "$ROOT/board/rootfs_overlay/root/gui/yshell"
  "$ROOT/board/variants/gui2/yshell"
)
declare -A before=()
for p in "${DEFAULT_OUTPUTS[@]}"; do
  if [ -f "$p" ]; then before["$p"]="$(sha256sum "$p" | awk '{print $1}')"; else before["$p"]=missing; fi
done

echo "== [1/5] inputs"
for f in "$IMG/rootfs_base.cpio" "$IMG/fw_jump.bin" "$IMAGE_SRC" "$DTB_IN"; do
  [ -f "$f" ] || die "missing input $f"
done
cp -f "$IMAGE_SRC" "$IMAGE_IN"
cp -f "$DTB_IN" "$DTB_OUT"
sha256sum "$IMAGE_IN" "$DTB_OUT" "$IMG/rootfs_base.cpio" "$IMG/fw_jump.bin"

echo "== [2/5] unpack + overlay"
rm -rf "$WS"
mkdir -p "$WS/root"
rc=0
( cd "$WS/root" && cpio -idm < "$IMG/rootfs_base.cpio" ) >"$WS/extract.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  unexpected="$(grep -v -e 'Cannot mknod' -e '^[0-9][0-9]* blocks\?$' "$WS/extract.log" || true)"
  [ -z "$unexpected" ] || { cat "$WS/extract.log" >&2; die "cpio extraction failed"; }
fi
rm -f "$WS/extract.log"
[ -x "$WS/root/init" ] || die "no executable /init"
[ -e "$WS/root/bin/sh" ] || die "no /bin/sh"
rm -f "$WS/root/etc/init.d/S99y1cam.sh"
# S99leds writes the whole GPIO DATA_OUT every second, clobbering CTP_RST /
# SCL / SDA (bits 8..10); it must not run in the touch image.
rm -f "$WS/root/etc/init.d/S99leds.sh"
cp -a "$OVERLAY/." "$WS/root/"
mkdir -p "$WS/root/root/gui/assets"
chmod 0755 "$WS/root" "$WS/root/root/gui" "$WS/root/root/gui/assets"
chmod 0700 "$WS/root/root"
chmod 0755 "$WS/root/init" "$WS/root/bin/sh" \
  "$WS/root/root/gui/yshell" "$WS/root/etc/init.d/S99gui.sh"
for a in wallpaper_ink.bin wallpaper_paper.bin; do
  chmod 0644 "$WS/root/root/gui/assets/$a"
done
[ ! -e "$WS/root/etc/init.d/S99y1cam.sh" ] || die "S99y1cam still in staging"
[ ! -e "$WS/root/etc/init.d/S99leds.sh" ] || die "S99leds still in staging"
echo "   yshell: $(sha256sum "$WS/root/root/gui/yshell" | awk '{print $1}')"

echo "== [3/5] pack rootfs"
(
  cd "$WS/root"
  find . -print0 | cpio --null -o -H newc --quiet --owner 0:0 --reproducible | gzip -9
) > "$ROOTFS_OUT"
gzip -t "$ROOTFS_OUT"
gzip -dc "$ROOTFS_OUT" | cpio -itv > "$LIST" 2>/dev/null
for f in init bin/sh root/gui/yshell etc/init.d/S99gui.sh; do
  awk -v p="$f" '{ for (i=1;i<=NF;i++) if ($i==p) { print; exit } }' "$LIST" | grep -q . \
    || die "rootfs member missing: $f"
done
if awk '$NF == "etc/init.d/S99y1cam.sh" || $NF == "etc/init.d/S99leds.sh" { found=1 } END { exit(found?0:1) }' "$LIST"; then
  die "rootfs still contains S99y1cam.sh or S99leds.sh"
fi
line="$(awk '$NF == "root/gui/yshell" { print; exit }' "$LIST")"
[ "$(printf '%s\n' "$line" | awk '{print $1}')" = "-rwxr-xr-x" ] || die "yshell mode"
echo "   members: $(wc -l < "$LIST" | tr -d '[:space:]')  rootfs: $(stat -c %s "$ROOTFS_OUT") B"

echo "== [4/5] DTB + SD image"
dtc -I dtb -O dts -o "$WS/dtb.dts" "$DTB_OUT" 2>/dev/null
start="$(awk -F'[<>]' '/linux,initrd-start/ {print $2; exit}' "$WS/dtb.dts")"
end="$(awk -F'[<>]' '/linux,initrd-end/ {print $2; exit}' "$WS/dtb.dts")"
[ -n "$start" ] && [ -n "$end" ] || die "DTB lacks initrd window"
python3 - "$start" "$end" "$(stat -c %s "$ROOTFS_OUT")" <<'PY'
import sys
start, end, size = (int(v, 0) for v in sys.argv[1:4])
assert start == 0x83000000, hex(start)
assert end - start >= size, (hex(start), hex(end), size)
print(f"   initrd {start:#010x}..{end:#010x} rootfs {size} B")
PY
python3 "$PACKER" --out "$SD_OUT" \
  --entry 0x80000000="$IMG/fw_jump.bin" \
  --entry 0x82000000="$IMAGE_IN" \
  --entry "$DTB_ADDR"="$DTB_OUT" \
  --entry "$INITRD_START"="$ROOTFS_OUT"
python3 - "$SD_OUT" <<'PY'
import sys
from pathlib import Path
b = Path(sys.argv[1]).read_bytes()
assert b[:4] == b"YSLD"
print(f"   sd_gui_touch.img {len(b)} B ({len(b)//512} blocks), YSLD OK")
PY

echo "== [5/5] post checks"
for p in "${DEFAULT_OUTPUTS[@]}"; do
  if [ -f "$p" ]; then now="$(sha256sum "$p" | awk '{print $1}')"; else now=missing; fi
  [ "$now" = "${before[$p]}" ] || die "default/gui2 output changed: $p"
done
echo "   default/gui2 pairs unchanged"
( cd "$IMG" && sha256sum -c inputs.sha256 )
sha256sum "$ROOTFS_OUT" "$DTB_OUT" "$SD_OUT" "$WS/root/root/gui/yshell"
echo "TOUCH_IMAGE_DONE"
