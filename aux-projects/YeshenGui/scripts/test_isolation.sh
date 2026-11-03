#!/usr/bin/env bash
# Self-test for verify_isolation.sh. Uses throwaway git repositories; never
# touches the real VexiiYeshenLinux reference or the real board/ baseline.
set -euo pipefail
unset ROOT LVGL_TAG LVGL_URL GIT_OPTIONAL_LOCKS
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/gui/scripts" "$WORK/gui/board"
cp "$HERE/verify_isolation.sh" "$WORK/gui/scripts/"
CHECK="$WORK/gui/scripts/verify_isolation.sh"
BOARD="$WORK/gui/board"

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

baseline_hash() {
  sha256sum "$BOARD"/vexii_baseline.* | sha256sum | cut -d' ' -f1
}

assert_no_stage() {
  local leftover
  leftover="$(find "$BOARD" -maxdepth 1 -name '.baseline.*' -print -quit)"
  [ -z "$leftover" ] || fail "staged baseline temp left behind: $leftover"
}

REF="$WORK/ref"
mkdir -p "$REF/sw/images" "$REF/deliver/sbits"
git -C "$REF" init -q
git -C "$REF" config user.name test
git -C "$REF" config user.email test@example.com
git -C "$REF" config core.autocrlf true
printf 'hello\n' > "$REF/tracked.txt"
printf '/sw/images/\n/deliver/\n' > "$REF/.gitignore"
# All six key inputs are required by --record; the fixture must model the
# real reference, not a nested repo or artifact-less worktree.
for key in Image fw_jump.bin linux.dtb rootfs.cpio rootfs_v2.cpio sd.img; do
  printf '%s\n' "$key" > "$REF/sw/images/$key"
done
printf 'bitstream\n' > "$REF/deliver/sbits/a.sbit"
git -C "$REF" add .gitignore tracked.txt
git -C "$REF" commit -qm init

record() { expect_msg 0 "record baseline" "recorded baseline" bash "$CHECK" --record --root "$REF"; }

record

# Inherited GIT_DIR/GIT_WORK_TREE must not redirect `git -C "$ROOT"` at
# another repository: the check must still verify REF (and PASS), never the
# poisoned repository whose HEAD/index differ from the baseline.
POISON="$WORK/poison"
git init -q "$POISON"
git -C "$POISON" config user.name test
git -C "$POISON" config user.email test@example.com
git -C "$POISON" config core.autocrlf false
printf 'poison\n' > "$POISON/poison.txt"
git -C "$POISON" add poison.txt
git -C "$POISON" commit -qm poison
expect_msg 0 "check ignores inherited GIT_DIR/GIT_WORK_TREE" "PASS:" \
  env GIT_DIR="$POISON/.git" GIT_WORK_TREE="$POISON" bash "$CHECK" --root "$REF"

# Touch a tracked file so the index's cached stat data is stale. If check mode
# forgot GIT_OPTIONAL_LOCKS=0, `git status` would refresh (rewrite) the index.
sleep 1
idx_hash_before="$(sha256sum "$REF/.git/index" | cut -d' ' -f1)"
idx_stat_before="$(stat -c '%s %Y' "$REF/.git/index")"
touch "$REF/tracked.txt"
expect_msg 0 "PASS after touching a tracked file" "PASS:" bash "$CHECK" --root "$REF"
idx_hash_after="$(sha256sum "$REF/.git/index" | cut -d' ' -f1)"
idx_stat_after="$(stat -c '%s %Y' "$REF/.git/index")"
[ "$idx_hash_before" = "$idx_hash_after" ] || fail "check modified .git/index content"
[ "$idx_stat_before" = "$idx_stat_after" ] || fail "check modified .git/index mtime/size"
echo "ok   check leaves .git/index byte/mtime/size unchanged"

rm -f "$REF/tracked.txt"
git -C "$REF" checkout -q -- tracked.txt   # autocrlf materializes CRLF, status stays clean
od -An -tx1 "$REF/tracked.txt" | tr -d ' \n' | grep -q '0d0a' \
  || fail "expected CRLF after autocrlf checkout"
expect_msg 0 "PASS with clean CRLF worktree (autocrlf)" "PASS:" bash "$CHECK" --root "$REF"

touch "$REF/untracked.txt"
expect_msg 1 "FAIL on untracked file" "git status changed" bash "$CHECK" --root "$REF"
rm -f "$REF/untracked.txt"
printf 'changed\n' >> "$REF/tracked.txt"
expect_msg 1 "FAIL on modified tracked file" "git status changed" bash "$CHECK" --root "$REF"
git -C "$REF" checkout -q -- tracked.txt

printf 'staged\n' > "$REF/staged.txt"
git -C "$REF" add staged.txt
expect_msg 1 "FAIL on index change" "git index changed" bash "$CHECK" --root "$REF"
git -C "$REF" reset -q
rm -f "$REF/staged.txt"

printf 'changed\n' > "$REF/sw/images/Image"
expect_msg 1 "FAIL on key artifact content change" "key Phase S input hashes changed" bash "$CHECK" --root "$REF"
printf 'Image\n' > "$REF/sw/images/Image"
printf 'rootfs\n' > "$REF/sw/images/rootfs.cpio"
expect_msg 1 "FAIL on key artifact set change" "key Phase S input hashes changed" bash "$CHECK" --root "$REF"
printf 'rootfs.cpio\n' > "$REF/sw/images/rootfs.cpio"

printf '100644 0000000000000000000000000000000000000000 0\tphantom\n' \
  >> "$BOARD/vexii_baseline.index"
expect_msg 1 "FAIL on corrupted index baseline" "git index changed" bash "$CHECK" --root "$REF"
record

git -C "$REF" commit -q --allow-empty -m move
expect_msg 1 "FAIL on HEAD move" "HEAD moved" bash "$CHECK" --root "$REF"
git -C "$REF" reset -q --hard HEAD~1
record

cp -a "$REF" "$WORK/relocated"
expect_msg 0 "PASS with relocated --root" "PASS:" bash "$CHECK" --root "$WORK/relocated"

# A linked worktree has a .git *file* marker and its own index. Seed all six
# ignored key inputs so the same baseline applies.
WT="$WORK/worktree"
git -C "$REF" worktree add -q --detach "$WT" HEAD
mkdir -p "$WT/sw/images" "$WT/deliver/sbits"
cp "$REF"/sw/images/* "$WT/sw/images/"
cp "$REF/deliver/sbits/a.sbit" "$WT/deliver/sbits/a.sbit"
expect_msg 0 "PASS with linked worktree --root" "PASS:" bash "$CHECK" --root "$WT"

# --record must refuse an artifact-less linked worktree: without the ignored
# sw/images inputs the baseline would prove nothing and could PASS empty-to-empty.
before="$(baseline_hash)"
WT_NOART="$WORK/wt_noart"
git -C "$REF" worktree add -q --detach "$WT_NOART" HEAD
[ ! -e "$WT_NOART/sw/images/Image" ] || fail "artifact-less worktree unexpectedly has Image"
expect_msg 1 "record rejects an artifact-less worktree" "missing key inputs" \
  bash "$CHECK" --record --root "$WT_NOART"
after="$(baseline_hash)"
[ "$before" = "$after" ] || fail "artifact-less worktree record modified the baseline"
assert_no_stage
echo "ok   failed artifact-less worktree record leaves baseline unchanged"

git -C "$REF" worktree remove --force "$WT_NOART" >/dev/null 2>&1 || {
  rm -rf "$WT_NOART"
  git -C "$REF" worktree prune
}
git -C "$REF" worktree remove --force "$WT" >/dev/null 2>&1 || {
  rm -rf "$WT"
  git -C "$REF" worktree prune
}

# --root must be the worktree root, not a subdirectory; a failed record must
# not publish or modify any baseline file.
before="$(baseline_hash)"
expect_msg 1 "record rejects a subdirectory --root" "worktree root" \
  bash "$CHECK" --record --root "$REF/sw"
after="$(baseline_hash)"
[ "$before" = "$after" ] || fail "failed record modified the baseline"
assert_no_stage
echo "ok   failed subdirectory record leaves baseline unchanged"
expect_msg 1 "check rejects a subdirectory --root" "worktree root" \
  bash "$CHECK" --root "$REF/sw"

# A .git directory is a repository but not a work tree; reject it cleanly
# instead of letting `git status` emit a raw fatal.
before="$(baseline_hash)"
expect_msg 1 "record rejects a .git directory --root" "not a git directory" \
  bash "$CHECK" --record --root "$REF/.git"
after="$(baseline_hash)"
[ "$before" = "$after" ] || fail "failed .git-directory record modified the baseline"
assert_no_stage
echo "ok   failed .git-directory record leaves baseline unchanged"
expect_msg 1 "check rejects a .git directory --root" "not a git directory" \
  bash "$CHECK" --root "$REF/.git"

git init -q --bare "$WORK/bare.git"
expect_msg 1 "record rejects a bare repo" "bare repositories are not supported" \
  bash "$CHECK" --record --root "$WORK/bare.git"
expect_msg 1 "check rejects a bare repo" "bare repositories are not supported" \
  bash "$CHECK" --root "$WORK/bare.git"

UNBORN="$WORK/unborn"
git init -q "$UNBORN"
git -C "$UNBORN" config user.name test
git -C "$UNBORN" config user.email test@example.com
expect_msg 1 "record rejects an unborn HEAD" "unborn HEAD" \
  bash "$CHECK" --record --root "$UNBORN"
expect_msg 1 "check rejects an unborn HEAD" "unborn HEAD" \
  bash "$CHECK" --root "$UNBORN"
assert_no_stage

EMPTY="$WORK/empty"
git init -q "$EMPTY"
git -C "$EMPTY" config user.name test
git -C "$EMPTY" config user.email test@example.com
git -C "$EMPTY" commit -q --allow-empty -m empty
before="$(baseline_hash)"
expect_msg 1 "record rejects an empty git index" "no tracked files" \
  bash "$CHECK" --record --root "$EMPTY"
after="$(baseline_hash)"
[ "$before" = "$after" ] || fail "empty-index record modified the baseline"
assert_no_stage
echo "ok   failed empty-index record leaves baseline unchanged"
expect_msg 1 "check rejects an empty index against the baseline" "git index changed" \
  bash "$CHECK" --root "$EMPTY"

# A nested repository (like VexiiYeshenLinux/third_party/VexiiRiscv) can have
# commits and tracked files but none of the key inputs; --record must refuse it
# rather than publish an artifact-less baseline.
OUTER="$WORK/outer"
git init -q "$OUTER"
git -C "$OUTER" config user.name test
git -C "$OUTER" config user.email test@example.com
git -C "$OUTER" config core.autocrlf false
printf 'outer\n' > "$OUTER/outer.txt"
git -C "$OUTER" add outer.txt
git -C "$OUTER" commit -qm outer
NESTED="$OUTER/third_party/VexiiRiscv"
git init -q "$NESTED"
git -C "$NESTED" config user.name test
git -C "$NESTED" config user.email test@example.com
git -C "$NESTED" config core.autocrlf false
printf 'rtl\n' > "$NESTED/top.scala"
git -C "$NESTED" add top.scala
git -C "$NESTED" commit -qm nested
before="$(baseline_hash)"
expect_msg 1 "record rejects a nested repo root" "missing key inputs" \
  bash "$CHECK" --record --root "$NESTED"
after="$(baseline_hash)"
[ "$before" = "$after" ] || fail "nested-repo record modified the baseline"
assert_no_stage
echo "ok   failed nested-repo record leaves baseline unchanged"

# A fresh clone only has tracked files, never the ignored sw/images inputs.
git clone -q "$REF" "$WORK/clone"
[ ! -e "$WORK/clone/sw/images/Image" ] || fail "fresh clone unexpectedly has Image"
before="$(baseline_hash)"
expect_msg 1 "record rejects a fresh clone without key inputs" "missing key inputs" \
  bash "$CHECK" --record --root "$WORK/clone"
after="$(baseline_hash)"
[ "$before" = "$after" ] || fail "fresh-clone record modified the baseline"
assert_no_stage
echo "ok   failed fresh-clone record leaves baseline unchanged"

expect_msg 2 "--root without a value is a usage error" "usage error" \
  bash "$CHECK" --root
expect_msg 2 "--root --record is a usage error" "usage error" \
  bash "$CHECK" --root --record
expect_msg 2 "--root=--record is a usage error" "usage error" \
  bash "$CHECK" --root=--record

mkdir -p "$WORK/nobase/scripts" "$WORK/nobase/board"
cp "$HERE/verify_isolation.sh" "$WORK/nobase/scripts/"
expect_msg 1 "FAIL on missing baseline" "baseline incomplete" \
  bash "$WORK/nobase/scripts/verify_isolation.sh" --root "$REF"
expect_msg 1 "FAIL when default root is absent" "default reference not found" \
  bash "$CHECK"

# A pre-existing untracked directory is recorded as one `?? build/` line.
# Contents created inside it later are out of scope by design.
mkdir -p "$REF/build"
printf 'one\n' > "$REF/build/one"
expect_msg 1 "FAIL on a new untracked directory" "git status changed" bash "$CHECK" --root "$REF"
expect_msg 0 "record accepts a pre-existing untracked directory" "recorded baseline" \
  bash "$CHECK" --record --root "$REF"
expect_msg 0 "PASS with a recorded untracked directory" "PASS:" bash "$CHECK" --root "$REF"
printf 'two\n' > "$REF/build/two"
expect_msg 0 "PASS when untracked build contents change (out of scope)" "PASS:" \
  bash "$CHECK" --root "$REF"
rm -rf "$REF/build"
expect_msg 1 "FAIL when the recorded untracked directory disappears" "git status changed" \
  bash "$CHECK" --root "$REF"

# A baseline may legitimately capture a concurrent tracked modification.
printf 'wip\n' >> "$REF/tracked.txt"
expect_msg 1 "FAIL on a tracked modification before recording" "git status changed" \
  bash "$CHECK" --root "$REF"
expect_msg 0 "record accepts a pre-existing tracked modification" "recorded baseline" \
  bash "$CHECK" --record --root "$REF"
expect_msg 0 "PASS with a recorded tracked modification" "PASS:" bash "$CHECK" --root "$REF"
git -C "$REF" checkout -q -- tracked.txt
expect_msg 1 "FAIL after restoring a recorded dirty file" "git status changed" \
  bash "$CHECK" --root "$REF"
record
expect_msg 0 "PASS after re-recording the clean state" "PASS:" bash "$CHECK" --root "$REF"

# A baseline whose artifact manifest is empty or omits a key input is corrupt
# or was recorded from a non-reference root; check mode must refuse it instead
# of comparing empty-to-empty.
cp "$BOARD/vexii_baseline.artifacts.sha256" "$WORK/artifacts.bak"
: > "$BOARD/vexii_baseline.artifacts.sha256"
expect_msg 1 "check rejects an empty artifact baseline" "corrupt or wrong baseline" \
  bash "$CHECK" --root "$REF"
awk '!/  sw\/images\/Image$/' "$WORK/artifacts.bak" \
  > "$BOARD/vexii_baseline.artifacts.sha256"
expect_msg 1 "check rejects a baseline missing a key input" "lacks required key input" \
  bash "$CHECK" --root "$REF"
cp "$WORK/artifacts.bak" "$BOARD/vexii_baseline.artifacts.sha256"
expect_msg 0 "PASS after restoring the artifact baseline" "PASS:" bash "$CHECK" --root "$REF"

echo "PASS: isolation self-test"
