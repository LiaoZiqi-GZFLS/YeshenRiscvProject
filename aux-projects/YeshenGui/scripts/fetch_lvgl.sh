#!/usr/bin/env bash
# Clone LVGL at the pinned tag and verify the checkout matches the pin.
#
# Env overrides:
#   ROOT       YeshenGui repository root (default: parent of this script).
#              It must contain scripts/fetch_lvgl.sh; any other root (e.g. the
#              read-only VexiiYeshenLinux reference) is refused before
#              third_party/ is created or modified.
#   LVGL_TAG   May only repeat the documented pin. To bump the pin, update
#              third_party/PINS.md, the plan, and PIN_TAG/PIN_COMMIT below
#              together; an arbitrary override is rejected so PINS.md cannot
#              silently go stale.
#   LVGL_URL   Test-only clone source override (default: the URL in PINS.md).
#              The pin OID is still enforced, so a mirror must contain the
#              exact pinned commit.
#
# third_party/lvgl.commit records the last successful verification. A failed
# run never writes or removes it, so treat an existing file as stale after a
# failure and re-run this script before relying on it.
set -euo pipefail

# Inherited Git environment variables redirect `git -C "$DIR"` at another
# repository, which could verify the wrong checkout. Drop them before running
# any Git command.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${ROOT:-$(cd "$HERE/.." && pwd)}"
PIN_TAG="v9.2.0"
PIN_COMMIT="aa7446344c6ec7631112ef031983ef24077e24d5"
TAG="${LVGL_TAG:-$PIN_TAG}"
URL="${LVGL_URL:-https://github.com/lvgl/lvgl.git}"
DIR="$ROOT/third_party/lvgl"
MARKER="$DIR/.git"
COMMIT_FILE="$ROOT/third_party/lvgl.commit"

if [ "$TAG" != "$PIN_TAG" ]; then
  echo "FAIL: LVGL_TAG=$TAG differs from the documented pin $PIN_TAG." >&2
  echo "      Update third_party/PINS.md and PIN_TAG/PIN_COMMIT in this script to change the pin." >&2
  exit 1
fi

# ROOT must be the YeshenGui checkout: a marker under ROOT keeps a mistyped or
# inherited ROOT from creating third_party/ inside the read-only reference.
if [ ! -f "$ROOT/scripts/fetch_lvgl.sh" ]; then
  echo "FAIL: ROOT is not a YeshenGui checkout (missing scripts/fetch_lvgl.sh): $ROOT" >&2
  echo "      refusing to create or modify third_party/ outside the GUI repository" >&2
  exit 1
fi

not_checkout() {
  echo "FAIL: $DIR is not a git checkout; remove it and rerun." >&2
  echo "      reason: $1" >&2
  printf '      rm -rf %q && bash %q\n' "$DIR" "$0" >&2
  exit 1
}

mkdir -p "$ROOT/third_party"

if [ -L "$DIR" ]; then
  not_checkout "symbolic link"
elif [ -d "$DIR" ]; then
  if [ -e "$MARKER" ]; then
    # .git (directory or file) is the checkout marker; do not let Git resolve
    # a parent repository for a plain nested directory.
    if ! git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
      not_checkout "unusable .git marker"
    fi
    prefix="$(git -C "$DIR" rev-parse --show-prefix 2>/dev/null || true)"
    if [ -n "$prefix" ]; then
      not_checkout "it is inside a worktree at prefix '$prefix'"
    fi
  elif [ -z "$(ls -A -- "$DIR" 2>/dev/null)" ]; then
    # Empty directory is a valid clone target; remove it and clone below.
    rmdir -- "$DIR"
  else
    parent_prefix="$(git -C "$DIR" rev-parse --show-prefix 2>/dev/null || true)"
    if [ -n "$parent_prefix" ]; then
      not_checkout "plain directory inside a parent repository at prefix '$parent_prefix'"
    fi
    not_checkout "no .git directory or file"
  fi
elif [ -e "$DIR" ]; then
  not_checkout "not a directory"
fi

if [ ! -d "$DIR" ]; then
  echo "cloning LVGL $TAG ..."
  git clone --depth 1 --branch "$TAG" -- "$URL" "$DIR"
fi

if ! head_oid="$(git -C "$DIR" rev-parse --verify HEAD 2>/dev/null)"; then
  echo "FAIL: cannot read HEAD from $DIR (empty or corrupt checkout)." >&2
  printf '      Remove it and rerun: rm -rf %q && bash %q\n' "$DIR" "$0" >&2
  exit 1
fi
if ! tag_oid="$(git -C "$DIR" rev-parse --verify "$TAG^{commit}" 2>/dev/null)"; then
  echo "FAIL: tag $TAG not found in $DIR (shallow or foreign checkout)." >&2
  printf '      Remove it and rerun to re-clone: rm -rf %q && bash %q\n' "$DIR" "$0" >&2
  exit 1
fi

# A dirty tracked tree cannot be pinned: the working tree may no longer match
# the commit even when HEAD does. Untracked files are allowed (build output).
dirty="$(GIT_OPTIONAL_LOCKS=0 git -C "$DIR" status --porcelain --untracked-files=no)"
if [ -n "$dirty" ]; then
  echo "FAIL: LVGL checkout has tracked changes; pin not verified." >&2
  printf '%s\n' "$dirty" >&2
  printf '      Restore it or remove/re-clone: rm -rf %q && bash %q\n' "$DIR" "$0" >&2
  exit 1
fi

pin_mismatch() {
  echo "FAIL: LVGL checkout does not match the documented pin" >&2
  echo "  pin  : $PIN_TAG = $PIN_COMMIT" >&2
  echo "  tag  : $TAG^{commit} = $tag_oid" >&2
  echo "  HEAD : $head_oid" >&2
  echo "  The upstream tag may have moved, or this is the wrong checkout." >&2
  echo "  Update third_party/PINS.md (and the plan) intentionally, or remove/re-clone:" >&2
  printf '    rm -rf %q && bash %q\n' "$DIR" "$0" >&2
  exit 1
}

if [ "$tag_oid" != "$PIN_COMMIT" ]; then
  pin_mismatch
fi
if [ "$head_oid" != "$PIN_COMMIT" ]; then
  echo "FAIL: LVGL HEAD is not the pinned commit" >&2
  echo "  expected $PIN_TAG = $PIN_COMMIT" >&2
  echo "  HEAD          = $head_oid" >&2
  printf '  fix: git -C %q checkout --detach %q\n' "$DIR" "$TAG" >&2
  printf '  or : rm -rf %q && bash %q\n' "$DIR" "$0" >&2
  exit 1
fi

# Record the verified commit atomically, and only after the pin check passed.
TMP="$(mktemp "$ROOT/third_party/.lvgl.commit.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$head_oid" > "$TMP"
mv -f "$TMP" "$COMMIT_FILE"
trap - EXIT

echo "LVGL $TAG @ $head_oid (pin verified)"
