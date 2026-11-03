#!/usr/bin/env bash
# Write the touch image to the TF card. Run only inside a user-approved board
# window, with the card in the reader and the camera backup still intact.
#
# Usage (WSL):
#   TF_DEV=/dev/sdc bash scripts/write_tf_touch.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="$ROOT/images/sd_gui_touch.img"
BAK="$ROOT/build/tf_camera_backup_full.img"
DEV="${TF_DEV:-/dev/sdc}"
WANT_IMG=1495472736bf283a160f45dccfd89143ccff4c2b2dbe124054792dbb13a14fcf
WANT_BAK=74b029c0b47b5eea803a3be5e99cc378af121222f76510a8b59c9af15c512184
BLOCKS=16481
CARD_KB=7761920

die() { echo "ABORT: $*" >&2; exit 1; }
[ -b "$DEV" ] || die "$DEV is not a block device"
[ -f "$IMG" ] || die "missing $IMG"
[ -f "$BAK" ] || die "missing camera backup $BAK"

line=$(awk -v d="${DEV#/dev/}" '$4==d {print $3}' /proc/partitions)
[ "$line" = "$CARD_KB" ] || die "card size=${line:-missing} KB != $CARD_KB"
[ "$(sha256sum "$BAK" | awk '{print $1}')" = "$WANT_BAK" ] || die "backup hash mismatch"
[ "$(sha256sum "$IMG" | awk '{print $1}')" = "$WANT_IMG" ] || die "image hash mismatch"
[ "$(stat -c %s "$IMG")" = "$((BLOCKS * 512))" ] || die "image size mismatch"

echo "writing $IMG ($BLOCKS blocks) -> $DEV"
dd if="$IMG" of="$DEV" bs=512 count="$BLOCKS" conv=fsync status=progress
sync
got=$(dd if="$DEV" bs=512 count="$BLOCKS" status=none | sha256sum | awk '{print $1}')
echo "readback sha=$got"
[ "$got" = "$WANT_IMG" ] || die "readback $got != $WANT_IMG"
echo "TF_TOUCH_WRITE_OK $WANT_IMG"
echo "camera backup remains $WANT_BAK ($(stat -c %s "$BAK") B)"
