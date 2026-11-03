#!/usr/bin/env bash
# Build the independent YeshenGui rootfs and TF-card image (Plan Task 14).
#
# Default pair (freeze/bank bitstream 7092e495):
#   cd /mnt/d/code/PDS/YeshenGui && bash scripts/build_board_image.sh
#   Kernel (Image), OpenSBI (fw_jump.bin), DTB and the base rootfs are copied
#   read-only from $VEXII (default ../VexiiYeshenLinux). The script refuses to
#   advance unless scripts/verify_isolation.sh PASSes before and after the
#   build, and it re-checks the original sw/images/sd.img hash, so the
#   reference tree is never modified. Outputs:
#     images/rootfs_gui.cpio.gz, images/linux_gui.dtb, images/sd_gui.img
#
# Snapshot-only default rebuild (when the reference baseline is stale):
#   GUI_VARIANT=default_snapshot bash scripts/build_board_image.sh
#   Rebuilds the default pair from the images/ snapshot inputs only; it does
#   not read or modify VexiiYeshenLinux and does not run or re-record the
#   isolation baseline. Use this to refresh the default yshell/rootfs/image
#   after a source rename; the normal `default` path still requires isolation.
#
# Second-framebuffer A/B pair (YeshenGuiRtl2 source-select bitstream):
#   GUI_VARIANT=gui2 bash scripts/build_board_image.sh
#   Builds only from the existing images/ snapshot inputs (Image, fw_jump.bin,
#   linux.dtb, rootfs_base.cpio) and never reads the reference checkout, whose
#   HEAD has moved since the baseline and whose isolation baseline is
#   intentionally stale; the baseline is NOT re-recorded here. It overlays
#   board/variants/gui2/yshell as /root/gui/yshell and writes:
#     images/rootfs_gui2.cpio.gz, images/linux_gui2.dtb, images/sd_gui2.img
#   The default pair is hashed before and after and must stay byte-identical.
#
# The rootfs is unpacked in WSL-native disk ($HOME/yeshen-gui-build/rootfs*) so
# cpio modes survive; extracting it on /mnt/d would flatten them to 0777.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUI_VARIANT="${GUI_VARIANT:-default}"
VEXII="${VEXII:-/mnt/d/code/PDS/VexiiYeshenLinux}"
IMG="$ROOT/images"
OVERLAY="$ROOT/board/rootfs_overlay"
PACKER="$ROOT/board/mk_sd_gui.py"

INITRD_START=0x83000000
ROOTFS_LIMIT=7864320            # 7.5 MiB (was the assert in the plan)
INITRD_END_16M=0x84000000       # 16 MiB initrd window at 0x83000000
DTB_ADDR=0x82F80000
WALLPAPERS=(wallpaper_ink.bin wallpaper_paper.bin)

die() {
  echo "FAIL: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"
}

hash_or_missing() {
  if [ -f "$1" ]; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo missing
  fi
}

case "$GUI_VARIANT" in
  default)
    ROOTFS_OUT_NAME=rootfs_gui.cpio.gz
    DTB_OUT_NAME=linux_gui.dtb
    SD_OUT_NAME=sd_gui.img
    WS="${WS:-$HOME/yeshen-gui-build/rootfs}"
    ;;
  default_snapshot)
    ROOTFS_OUT_NAME=rootfs_gui.cpio.gz
    DTB_OUT_NAME=linux_gui.dtb
    SD_OUT_NAME=sd_gui.img
    WS="${WS:-$HOME/yeshen-gui-build/rootfs}"
    VARIANT_YSHELL="$OVERLAY/root/gui/yshell"
    ;;
  gui2)
    ROOTFS_OUT_NAME=rootfs_gui2.cpio.gz
    DTB_OUT_NAME=linux_gui2.dtb
    SD_OUT_NAME=sd_gui2.img
    WS="${WS:-$HOME/yeshen-gui-build/rootfs_gui2}"
    VARIANT_YSHELL="$ROOT/board/variants/gui2/yshell"
    ;;
  *)
    die "unknown GUI_VARIANT '$GUI_VARIANT' (expected default, default_snapshot or gui2)"
    ;;
esac

ROOTFS_OUT="$IMG/$ROOTFS_OUT_NAME"
DTB_OUT="$IMG/$DTB_OUT_NAME"
SD_OUT="$IMG/$SD_OUT_NAME"
LIST="$WS/rootfs_${GUI_VARIANT}.list"

cd "$ROOT"
need cpio
need gzip
need python3

# Default outputs that the gui2 variant must not touch. Hashed before and
# after the build; `missing` is a valid "unchanged" state for optional files.
DEFAULT_OUTPUTS=(
  "$IMG/rootfs_gui.cpio.gz"
  "$IMG/linux_gui.dtb"
  "$IMG/sd_gui.img"
  "$OVERLAY/root/gui/yshell"
)
declare -A default_before=()
if [ "$GUI_VARIANT" = gui2 ]; then
  for p in "${DEFAULT_OUTPUTS[@]}"; do
    default_before["$p"]="$(hash_or_missing "$p")"
  done
fi

GUI2_OUTPUTS=(
  "$IMG/rootfs_gui2.cpio.gz"
  "$IMG/linux_gui2.dtb"
  "$IMG/sd_gui2.img"
  "$ROOT/board/variants/gui2/yshell"
)
declare -A gui2_before=()
if [ "$GUI_VARIANT" = default_snapshot ]; then
  for p in "${GUI2_OUTPUTS[@]}"; do
    gui2_before["$p"]="$(hash_or_missing "$p")"
  done
fi

# --- 1. inputs / isolation -------------------------------------------------
if [ "$GUI_VARIANT" = default ]; then
  echo "== [1/8] isolation check (before build)"
  bash "$ROOT/scripts/verify_isolation.sh"

  for f in Image fw_jump.bin linux.dtb rootfs_v2.cpio sd.img; do
    [ -f "$VEXII/sw/images/$f" ] || die "missing reference input: $VEXII/sw/images/$f"
  done
  REF_SD="$VEXII/sw/images/sd.img"
  ref_sd_before="$(sha256sum "$REF_SD" | awk '{print $1}')"
else
  echo "== [1/8] images/ snapshot inputs (reference not read)"
  for f in Image fw_jump.bin linux.dtb rootfs_base.cpio; do
    [ -f "$IMG/$f" ] || die "missing snapshot input: $IMG/$f
  Snapshot builds (default_snapshot/gui2) use only the existing images/
  snapshot and never re-read the moved reference checkout. Restore the file
  (or run the normal default build once in a clean window) before retrying."
  done
  if [ -f "$IMG/inputs.sha256" ]; then
    ( cd "$IMG" && sha256sum -c inputs.sha256 )
  else
    echo "   note: images/inputs.sha256 is missing; input hashes not checked"
  fi
  echo "   reference VexiiYeshenLinux intentionally not read: its HEAD has moved"
  echo "   since the baseline was recorded (stale by design); not re-recorded here."
fi

# --- 2. assets and board binary --------------------------------------------
echo "== [2/8] assets + board binary"
missing_assets=0
for a in "${WALLPAPERS[@]}"; do
  [ -f "$ROOT/ui/assets/$a" ] || missing_assets=1
done
if [ "$missing_assets" -ne 0 ]; then
  echo "   generating wallpapers (scripts/gen_assets.sh)"
  bash "$ROOT/scripts/gen_assets.sh"
fi
for a in "${WALLPAPERS[@]}"; do
  [ -f "$ROOT/ui/assets/$a" ] || die "asset still missing: ui/assets/$a"
done

case "$GUI_VARIANT" in
  default|default_snapshot)
    if [ ! -f "$OVERLAY/root/gui/yshell" ]; then
      echo "   cross-building yshell (scripts/build_board_app.sh)"
      bash "$ROOT/scripts/build_board_app.sh"
    fi
    YSHELL_SRC="$OVERLAY/root/gui/yshell"
    ;;
  gui2)
    if [ ! -f "$VARIANT_YSHELL" ]; then
      echo "   cross-building gui2 yshell (GUI_VARIANT=gui2 scripts/build_board_app.sh)"
      GUI_VARIANT=gui2 bash "$ROOT/scripts/build_board_app.sh"
    fi
    YSHELL_SRC="$VARIANT_YSHELL"
    ;;
esac
[ -f "$YSHELL_SRC" ] || die "missing $YSHELL_SRC"

assets_dst="$OVERLAY/root/gui/assets"
mkdir -p "$assets_dst" "$IMG"
for a in "${WALLPAPERS[@]}"; do
  cp -f "$ROOT/ui/assets/$a" "$assets_dst/$a"
  chmod 0644 "$assets_dst/$a" 2>/dev/null || true
done
echo "   assets: ${WALLPAPERS[*]} -> board/rootfs_overlay/root/gui/assets/"
echo "   yshell: $YSHELL_SRC"

# --- 3. inputs -------------------------------------------------------------
if [ "$GUI_VARIANT" = default ]; then
  echo "== [3/8] copy kernel / OpenSBI / DTB / base rootfs"
  cp -f "$VEXII/sw/images/Image" "$IMG/Image"
  cp -f "$VEXII/sw/images/fw_jump.bin" "$IMG/fw_jump.bin"
  cp -f "$VEXII/sw/images/linux.dtb" "$IMG/linux.dtb"
  cp -f "$VEXII/sw/images/rootfs_v2.cpio" "$IMG/rootfs_base.cpio"
  (
    cd "$IMG"
    sha256sum Image fw_jump.bin linux.dtb rootfs_base.cpio > inputs.sha256
  )
  cat "$IMG/inputs.sha256"
else
  echo "== [3/8] reuse images/ snapshot inputs"
  (
    cd "$IMG"
    sha256sum -c inputs.sha256
  )
fi

# --- 4. unpack, overlay, fix modes -----------------------------------------
echo "== [4/8] unpack rootfs in $WS"
rm -rf "$WS"
mkdir -p "$WS/root"
extract_log="$WS/extract.log"
rc=0
( cd "$WS/root" && cpio -idm < "$IMG/rootfs_base.cpio" ) >"$extract_log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  # The only expected failure is mknod (dev/console) on an unprivileged
  # extract; /init mounts devtmpfs on /dev, which supplies the console node.
  unexpected="$(grep -v -e 'Cannot mknod' -e '^[0-9][0-9]* blocks\?$' "$extract_log" || true)"
  if [ -n "$unexpected" ]; then
    cat "$extract_log" >&2
    die "cpio extraction failed"
  fi
  echo "   note: unprivileged extract skipped device node(s); devtmpfs provides /dev at boot:"
  grep 'Cannot mknod' "$extract_log" || true
fi
rm -f "$extract_log"

[ -x "$WS/root/init" ] || die "extracted rootfs has no executable /init"
[ -e "$WS/root/bin/sh" ] || die "extracted rootfs has no /bin/sh"

# Only the staging copy loses the camera autostart; the reference is untouched.
rm -f "$WS/root/etc/init.d/S99y1cam.sh"
cp -a "$OVERLAY/." "$WS/root/"

# The variant yshell replaces the default staged binary (which may not exist).
if [ "$GUI_VARIANT" = gui2 ]; then
  install -m 0755 "$VARIANT_YSHELL" "$WS/root/root/gui/yshell"
fi

# /mnt/d is drvfs, which reports 0777 for every directory, and `cp -a` would
# carry that onto /, /root and the new asset directories. Restore the base
# rootfs modes (its / is 0755 and its /root is 0700).
mkdir -p "$WS/root/root/gui/assets"
chmod 0755 "$WS/root" "$WS/root/root/gui" "$WS/root/root/gui/assets"
chmod 0700 "$WS/root/root"
chmod 0755 "$WS/root/init" "$WS/root/bin/sh" \
  "$WS/root/root/gui/yshell" "$WS/root/etc/init.d/S99gui.sh"
for a in "${WALLPAPERS[@]}"; do
  chmod 0644 "$WS/root/root/gui/assets/$a"
done
[ "$(stat -c %a "$WS/root")" = 755 ] || die "staging / mode is not 0755"
[ "$(stat -c %a "$WS/root/root")" = 700 ] || die "staging /root mode is not 0700"

[ ! -e "$WS/root/etc/init.d/S99y1cam.sh" ] || die "S99y1cam.sh still in staging rootfs"
for f in init bin/sh root/gui/yshell etc/init.d/S99gui.sh; do
  [ -e "$WS/root/$f" ] || die "overlay/staging missing /$f"
done
echo "   overlay applied; S99y1cam.sh removed from staging only"

# --- 5. repack + member checks ---------------------------------------------
echo "== [5/8] pack images/$ROOTFS_OUT_NAME"
(
  cd "$WS/root"
  # --owner 0:0 keeps the boot-time ownership identical to the reference rootfs
  # (the staging tree is owned by the build user); --reproducible keeps the
  # archive independent of host inode/device numbers.
  find . -print0 | cpio --null -o -H newc --quiet --owner 0:0 --reproducible | gzip -9
) > "$ROOTFS_OUT"
gzip -t "$ROOTFS_OUT" || die "$ROOTFS_OUT_NAME is not valid gzip"

gzip -dc "$ROOTFS_OUT" | cpio -itv > "$LIST" 2>/dev/null

require_member() {
  path="$1"
  want="$2"
  line="$(awk -v p="$path" '{ for (i = 1; i <= NF; i++) if ($i == p) { print; exit } }' "$LIST")"
  [ -n "$line" ] || die "rootfs member missing: $path"
  got="$(printf '%s\n' "$line" | awk '{ print $1 }')"
  owner="$(printf '%s\n' "$line" | awk '{ print $3 }')"
  if [ -n "$want" ] && [ "$got" != "$want" ]; then
    die "rootfs member $path has mode $got, want $want"
  fi
  [ "$owner" = root ] || die "rootfs member $path is owned by $owner, want root"
  echo "   ok $path $got root"
}

require_member root/gui/yshell -rwxr-xr-x
require_member root/gui/assets/wallpaper_ink.bin -rw-r--r--
require_member root/gui/assets/wallpaper_paper.bin -rw-r--r--
require_member . drwxr-xr-x
require_member init -rwxr-xr-x
require_member bin/sh ""
require_member etc/init.d/S99gui.sh -rwxr-xr-x
if awk '$NF == "etc/init.d/S99y1cam.sh" { found = 1 } END { exit(found ? 0 : 1) }' "$LIST"; then
  die "rootfs still contains /etc/init.d/S99y1cam.sh"
fi

if [ "$GUI_VARIANT" != default ]; then
  # Prove the packed /root/gui/yshell is the binary we staged, not a leftover.
  packed_yshell="$WS/packed_yshell"
  ( cd "$WS/root" && gzip -dc "$ROOTFS_OUT" | cpio -i --to-stdout root/gui/yshell ) \
    > "$packed_yshell" 2>/dev/null
  packed_sha="$(sha256sum "$packed_yshell" | awk '{print $1}')"
  expected_sha="$(sha256sum "$YSHELL_SRC" | awk '{print $1}')"
  rm -f "$packed_yshell"
  [ "$packed_sha" = "$expected_sha" ] \
    || die "packed /root/gui/yshell sha256 $packed_sha != $YSHELL_SRC $expected_sha"
  echo "   ok packed /root/gui/yshell sha256 matches $YSHELL_SRC"
  echo "      $expected_sha"
fi

gz_size="$(stat -c %s "$ROOTFS_OUT")"
echo "   members: $(wc -l < "$LIST" | tr -d '[:space:]')"
echo "   $ROOTFS_OUT_NAME: $gz_size bytes ($(du -h "$ROOTFS_OUT" | cut -f1)), limit $ROOTFS_LIMIT"
if [ "$GUI_VARIANT" = gui2 ]; then
  [ "$gz_size" -le "$ROOTFS_LIMIT" ] \
    || die "$ROOTFS_OUT_NAME is $gz_size bytes, over the $ROOTFS_LIMIT limit"
  echo "   rootfs within the 7.5 MiB limit"
fi

# --- 6. DTB: reuse when the rootfs fits, else a 16 MiB initrd window -------
echo "== [6/8] DTB selection"
if [ "$gz_size" -le "$ROOTFS_LIMIT" ]; then
  cp -f "$IMG/linux.dtb" "$DTB_OUT"
  dtb_choice="reuse linux.dtb (initrd 0x83000000..0x83800000, 8 MiB)"
else
  need dtc
  # The reference linux_raw.dts is preprocessed and does not parse as-is, so
  # rebuild from the proven DTB: decompile, move only linux,initrd-end, recompile.
  dtc -I dtb -O dts -o "${DTB_OUT%.dtb}.dts" "$IMG/linux.dtb"
  python3 - "${DTB_OUT%.dtb}.dts" "$INITRD_END_16M" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
end = int(sys.argv[2], 0)
text = path.read_text()
text, n = re.subn(r"linux,initrd-end\s*=\s*<0x[0-9a-fA-F]+>;",
                  f"linux,initrd-end = <0x{end:08X}>;", text)
if n != 1:
    raise SystemExit(f"expected exactly one linux,initrd-end, found {n}")
path.write_text(text)
print(f"   patched linux,initrd-end -> 0x{end:08X}")
PY
  dtc -I dts -O dtb -o "$DTB_OUT" "${DTB_OUT%.dtb}.dts"
  dtb_choice="generated $DTB_OUT_NAME from linux.dtb (initrd 0x83000000..0x84000000, 16 MiB)"
fi

dtc_check="$WS/dtb_check.dts"
dtc -I dtb -O dts -o "$dtc_check" "$DTB_OUT" 2>/dev/null
initrd_start="$(awk -F'[<>]' '/linux,initrd-start/ { print $2; exit }' "$dtc_check")"
initrd_end="$(awk -F'[<>]' '/linux,initrd-end/ { print $2; exit }' "$dtc_check")"
[ -n "$initrd_start" ] && [ -n "$initrd_end" ] || die "DTB lacks linux,initrd-start/end"
python3 - "$initrd_start" "$initrd_end" "$gz_size" "$INITRD_START" "$ROOTFS_OUT_NAME" <<'PY'
import sys

start, end, size, want_start = (int(v, 0) for v in sys.argv[1:5])
name = sys.argv[5]
print(f"   initrd window {start:#010x}..{end:#010x} "
      f"({(end - start) / (1024 * 1024):.2f} MiB), rootfs {size} bytes")
assert start == want_start, f"initrd-start {start:#x} != loader address {want_start:#x}"
assert end > start and end - start >= size, f"initrd window does not cover {name}"
PY
echo "   DTB: $dtb_choice"

# --- 7. SD image -----------------------------------------------------------
echo "== [7/8] build images/$SD_OUT_NAME"
[ -f "$PACKER" ] || die "missing $PACKER (copy of the reference SD packer)"
python3 "$PACKER" --out "$SD_OUT" \
  --entry 0x80000000="$IMG/fw_jump.bin" \
  --entry 0x82000000="$IMG/Image" \
  --entry "$DTB_ADDR"="$DTB_OUT" \
  --entry "$INITRD_START"="$ROOTFS_OUT"

python3 - "$SD_OUT" "$SD_OUT_NAME" <<'PY'
import sys
from pathlib import Path

img = Path(sys.argv[1]).read_bytes()
name = sys.argv[2]
assert img[:4] == b"YSLD", "bad SD image magic"
print(f"   {name} {len(img)} bytes ({len(img) // 512} blocks), YSLD OK")
PY

# --- 8. post checks --------------------------------------------------------
if [ "$GUI_VARIANT" = default ]; then
  echo "== [8/8] isolation check (after build) + reference hash re-check"
  (
    cd "$IMG"
    sha256sum -c inputs.sha256
  )
  ref_sd_after="$(sha256sum "$REF_SD" | awk '{print $1}')"
  [ "$ref_sd_before" = "$ref_sd_after" ] \
    || die "reference sw/images/sd.img changed: $ref_sd_before -> $ref_sd_after"
  echo "   reference sw/images/sd.img sha256 unchanged: $ref_sd_after"

  bash "$ROOT/scripts/verify_isolation.sh"
elif [ "$GUI_VARIANT" = default_snapshot ]; then
  echo "== [8/8] post checks (snapshot inputs + gui2 pair untouched)"
  (
    cd "$IMG"
    sha256sum -c inputs.sha256
  )
  for p in "${GUI2_OUTPUTS[@]}"; do
    now="$(hash_or_missing "$p")"
    [ "$now" = "${gui2_before[$p]}" ] \
      || die "gui2 output changed: $p (${gui2_before[$p]} -> $now)"
    if [ "$now" = missing ]; then
      echo "   unchanged (absent) $p"
    else
      echo "   unchanged $p ${now:0:16}..."
    fi
  done
  echo "   reference checkout not read or modified; isolation baseline not re-recorded"
else
  echo "== [8/8] post checks (snapshot inputs + default pair untouched)"
  (
    cd "$IMG"
    sha256sum -c inputs.sha256
  )
  for p in "${DEFAULT_OUTPUTS[@]}"; do
    now="$(hash_or_missing "$p")"
    [ "$now" = "${default_before[$p]}" ] \
      || die "default output changed: $p (${default_before[$p]} -> $now)"
    if [ "$now" = missing ]; then
      echo "   unchanged (absent) $p"
    else
      echo "   unchanged $p ${now:0:16}..."
    fi
  done
  echo "   reference checkout not read or modified; isolation baseline not re-recorded"
fi

echo "== done ($GUI_VARIANT)"
ls -l "$IMG"
