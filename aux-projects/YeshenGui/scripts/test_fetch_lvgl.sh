#!/usr/bin/env bash
# Offline self-test for fetch_lvgl.sh. Uses local fixture repositories only;
# never touches the real third_party/lvgl checkout or the network.
set -euo pipefail
unset ROOT LVGL_TAG LVGL_URL GIT_OPTIONAL_LOCKS
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/gui/scripts"
cp "$HERE/fetch_lvgl.sh" "$WORK/gui/scripts/"
FETCH="$WORK/gui/scripts/fetch_lvgl.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_msg() { # expect_msg <exit-code> <name> <substring> <command...>
  local want="$1" name="$2" needle="$3" rc=0
  shift 3
  "$@" > "$WORK/out" 2>&1 || rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL $name (rc=$rc, want $want)" >&2
    cat "$WORK/out" >&2
    exit 1
  fi
  if ! grep -Fq -- "$needle" "$WORK/out"; then
    echo "FAIL $name (output lacks: $needle)" >&2
    cat "$WORK/out" >&2
    exit 1
  fi
  echo "ok   $name"
}

expect_also() { # expect_also <name> <substring> -- checks the previous output
  local name="$1" needle="$2"
  if ! grep -Fq -- "$needle" "$WORK/out"; then
    echo "FAIL $name (output lacks: $needle)" >&2
    cat "$WORK/out" >&2
    exit 1
  fi
}

expect_absent() { # expect_absent <name> <substring> -- checks the previous output
  local name="$1" needle="$2"
  if grep -Fq -- "$needle" "$WORK/out"; then
    echo "FAIL $name (output unexpectedly contains: $needle)" >&2
    cat "$WORK/out" >&2
    exit 1
  fi
}

new_root() { # new_root <name>; prints the path
  local root="$WORK/$1"
  mkdir -p "$root/third_party" "$root/scripts"
  # fetch_lvgl.sh requires this marker so it cannot write outside YeshenGui.
  : > "$root/scripts/fetch_lvgl.sh"
  printf '%s\n' "$root"
}

assert_no_pin() { # assert_no_pin <root> <label>
  local root="$1" label="$2" leftover
  [ ! -e "$root/third_party/lvgl.commit" ] || fail "$label: pin file was written"
  leftover="$(find "$root/third_party" -maxdepth 1 -name '.lvgl.commit.*' -print -quit)"
  [ -z "$leftover" ] || fail "$label: temp pin file left behind: $leftover"
}

assert_pin() { # assert_pin <root> <label> <expected-oid>
  local root="$1" label="$2" want="$3" leftover
  [ -f "$root/third_party/lvgl.commit" ] || fail "$label: pin file missing"
  [ "$(cat "$root/third_party/lvgl.commit")" = "$want" ] || fail "$label: pin content mismatch"
  leftover="$(find "$root/third_party" -maxdepth 1 -name '.lvgl.commit.*' -print -quit)"
  [ -z "$leftover" ] || fail "$label: temp pin file left behind: $leftover"
}

# Local "upstream" repository whose v9.2.0 tag intentionally does not match
# the real pinned OID. Every case below must fail without writing the pin.
ORIGIN="$WORK/origin"
git init -q "$ORIGIN"
git -C "$ORIGIN" config user.name test
git -C "$ORIGIN" config user.email test@example.com
git -C "$ORIGIN" config core.autocrlf false
printf 'fixture lvgl\n' > "$ORIGIN/lvgl.h"
git -C "$ORIGIN" add lvgl.h
git -C "$ORIGIN" commit -qm one
git -C "$ORIGIN" tag v9.2.0

root="$(new_root tagvar)"
expect_msg 1 "LVGL_TAG override is rejected" "differs from the documented pin" \
  env ROOT="$root" LVGL_TAG=v9.1.0 bash "$FETCH"
assert_no_pin "$root" "tag override"

# ROOT must look like YeshenGui (scripts/fetch_lvgl.sh marker); otherwise the
# reference or a mistyped path could receive third_party/ writes.
root="$WORK/no_marker"
mkdir -p "$root/third_party"
expect_msg 1 "ROOT without the YeshenGui marker is rejected" "not a YeshenGui checkout" \
  env ROOT="$root" bash "$FETCH"
[ ! -e "$root/third_party/lvgl" ] || fail "marker-less ROOT was written"
assert_no_pin "$root" "marker-less ROOT"

root="$(new_root plain)"
mkdir -p "$root/third_party/lvgl"
printf 'not a checkout\n' > "$root/third_party/lvgl/file"
expect_msg 1 "plain directory is rejected" "not a git checkout" \
  env ROOT="$root" bash "$FETCH"
assert_no_pin "$root" "plain directory"

root="$WORK/parent_plain"
git init -q "$root"
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
git -C "$root" config core.autocrlf false
mkdir -p "$root/scripts"
: > "$root/scripts/fetch_lvgl.sh"
printf 'parent\n' > "$root/tracked.txt"
git -C "$root" add tracked.txt
git -C "$root" commit -qm parent
git -C "$root" tag v9.2.0
mkdir -p "$root/third_party/lvgl"
printf 'not a checkout\n' > "$root/third_party/lvgl/file"
expect_msg 1 "plain directory inside a tagged parent repo is rejected" "not a git checkout" \
  env ROOT="$root" bash "$FETCH"
expect_also "parent repo was not mistaken for the checkout" "inside a parent repository"
expect_absent "parent tag did not produce a false verification" "pin verified"
assert_no_pin "$root" "parent plain directory"

root="$(new_root empty)"
mkdir -p "$root/third_party/lvgl"
expect_msg 1 "empty directory is cloned, then pin mismatch is rejected" "cloning LVGL" \
  env ROOT="$root" LVGL_URL="$ORIGIN" bash "$FETCH"
expect_also "empty directory produced a real clone" "does not match the documented pin"
[ -e "$root/third_party/lvgl/.git" ] || fail "empty directory was not cloned"
assert_no_pin "$root" "empty directory"

root="$WORK/parent_empty"
git init -q "$root"
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
git -C "$root" config core.autocrlf false
mkdir -p "$root/scripts"
: > "$root/scripts/fetch_lvgl.sh"
printf 'parent\n' > "$root/tracked.txt"
git -C "$root" add tracked.txt
git -C "$root" commit -qm parent
git -C "$root" tag v9.2.0
mkdir -p "$root/third_party/lvgl"
expect_msg 1 "empty directory inside a tagged parent repo is cloned" "cloning LVGL" \
  env ROOT="$root" LVGL_URL="$ORIGIN" bash "$FETCH"
expect_also "parent tag did not block the empty-directory clone" "does not match the documented pin"
assert_no_pin "$root" "parent empty directory"

root="$(new_root moved)"
git -c advice.detachedHead=false clone -q --branch v9.2.0 "$ORIGIN" "$root/third_party/lvgl"
git -C "$root/third_party/lvgl" config user.name test
git -C "$root/third_party/lvgl" config user.email test@example.com
git -C "$root/third_party/lvgl" commit -q --allow-empty -m moved
git -C "$root/third_party/lvgl" tag -f v9.2.0 >/dev/null
expect_msg 1 "moved/re-tagged checkout is rejected" "does not match the documented pin" \
  env ROOT="$root" bash "$FETCH"
expect_also "moved tag names the remediation" "upstream tag may have moved"
assert_no_pin "$root" "moved tag"

root="$(new_root dirty)"
git -c advice.detachedHead=false clone -q --branch v9.2.0 "$ORIGIN" "$root/third_party/lvgl"
printf 'dirty\n' >> "$root/third_party/lvgl/lvgl.h"
expect_msg 1 "dirty tracked checkout is rejected" "tracked changes" \
  env ROOT="$root" bash "$FETCH"
expect_also "dirty checkout fails pin verification" "pin not verified"
assert_no_pin "$root" "dirty checkout"

root="$(new_root notag)"
mkdir -p "$root/third_party/lvgl"
git -C "$root/third_party/lvgl" init -q
git -C "$root/third_party/lvgl" config user.name test
git -C "$root/third_party/lvgl" config user.email test@example.com
git -C "$root/third_party/lvgl" config core.autocrlf false
printf 'fixture\n' > "$root/third_party/lvgl/lvgl.h"
git -C "$root/third_party/lvgl" add lvgl.h
git -C "$root/third_party/lvgl" commit -qm one
expect_msg 1 "checkout without the pinned tag is rejected" "tag v9.2.0 not found" \
  env ROOT="$root" bash "$FETCH"
assert_no_pin "$root" "missing tag"

# Success path: a test-only copy with PIN_COMMIT substituted to the local
# fixture OID (the shipped script keeps the real pin). Verifies the pin file
# content, the absence of .lvgl.commit.* temp files, and an idempotent rerun.
FIXTURE_OID="$(git -C "$ORIGIN" rev-parse 'v9.2.0^{commit}')"
OK_FETCH="$WORK/gui/scripts/fetch_lvgl_ok.sh"
sed "s/^PIN_COMMIT=.*/PIN_COMMIT=\"$FIXTURE_OID\"/" "$FETCH" > "$OK_FETCH"
chmod +x "$OK_FETCH"

root="$(new_root success)"
expect_msg 0 "success path clones and writes the pin" "pin verified" \
  env ROOT="$root" LVGL_URL="$ORIGIN" bash "$OK_FETCH"
assert_pin "$root" "success path" "$FIXTURE_OID"
expect_msg 0 "success path rerun is idempotent" "pin verified" \
  env ROOT="$root" LVGL_URL="$ORIGIN" bash "$OK_FETCH"
assert_pin "$root" "success path rerun" "$FIXTURE_OID"

# Inherited GIT_DIR/GIT_WORK_TREE must not redirect verification or the pin
# write at another repository (tag/HEAD there differ from the fixture pin).
POISON="$WORK/poison_env"
git init -q "$POISON"
git -C "$POISON" config user.name test
git -C "$POISON" config user.email test@example.com
git -C "$POISON" config core.autocrlf false
printf 'poison\n' > "$POISON/poison.txt"
git -C "$POISON" add poison.txt
git -C "$POISON" commit -qm poison
git -C "$POISON" tag v9.2.0
root="$(new_root poisoned)"
git -c advice.detachedHead=false clone -q --branch v9.2.0 "$ORIGIN" "$root/third_party/lvgl"
expect_msg 0 "fetch ignores inherited GIT_DIR/GIT_WORK_TREE" "pin verified" \
  env GIT_DIR="$POISON/.git" GIT_WORK_TREE="$POISON" \
  ROOT="$root" LVGL_URL="$ORIGIN" bash "$OK_FETCH"
assert_pin "$root" "poisoned environment" "$FIXTURE_OID"

echo "PASS: fetch_lvgl self-test"
