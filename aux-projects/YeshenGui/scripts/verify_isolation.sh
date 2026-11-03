#!/usr/bin/env bash
# Verify the read-only VexiiYeshenLinux reference is unchanged.
#
# Baseline files (in ../board):
#   vexii_baseline.head              HEAD commit at record time
#   vexii_baseline.status            `git status --porcelain` (staged/unstaged/untracked)
#   vexii_baseline.index             `git ls-files -s` (mode/OID/stage/path)
#   vexii_baseline.artifacts.sha256  sha256 of the key Phase S inputs
#
# Scope: the artifact manifest covers the 52 key Phase S inputs (the six
# sw/images/* files below plus deliver/sbits/*.sbit), not every file under
# sw/images/. All six sw/images key inputs are required: --record refuses a
# root where any is missing (a nested repository, an artifact-less worktree,
# or a fresh clone), and check mode refuses a baseline that does not list all
# six. `git status --porcelain` intentionally keeps its default untracked
# mode: a wholly untracked directory is collapsed to one `?? build/` line, so
# new files inside build/ are out of scope and cannot force a baseline
# re-record.
#
# Check mode is read-only: GIT_OPTIONAL_LOCKS=0 stops `git status` from
# refreshing the reference's .git/index. Index OIDs (not working-tree bytes)
# are compared, so core.autocrlf / CRLF mixtures cannot cause false alarms.
#
# ROOT may be supplied via the environment or --root PATH. The default
# (../VexiiYeshenLinux next to this repository) is resolved only when neither
# is given. ROOT must be a worktree root: subdirectories of a repository, a
# .git directory, and bare repositories are rejected, because `git ls-files`
# would otherwise be relative to a subdirectory or have no work tree at all.
set -euo pipefail

# Inherited Git environment variables redirect `git -C "$ROOT"` at another
# repository, which could produce a false PASS or record the wrong baseline.
# Drop them before running any Git command.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE

export GIT_OPTIONAL_LOCKS=0
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="$HERE/../board"
HEADF="$BASE/vexii_baseline.head"
STATUS="$BASE/vexii_baseline.status"
INDEX="$BASE/vexii_baseline.index"
ARTIFACTS="$BASE/vexii_baseline.artifacts.sha256"

# Key Phase S inputs (relative to the reference root): all six kernel/rootfs/SD
# files are required, plus every deliver/sbits/*.sbit that exists. A changed
# or incomplete set fails the check; --record refuses a missing key input.
ARTIFACT_PATHS=(
  sw/images/Image
  sw/images/fw_jump.bin
  sw/images/linux.dtb
  sw/images/rootfs.cpio
  sw/images/rootfs_v2.cpio
  sw/images/sd.img
)

MODE=check
ROOT="${ROOT:-}"
ROOT_SUPPLIED=0
if [ -n "$ROOT" ]; then
  ROOT_SUPPLIED=1
fi

usage() {
  cat >&2 <<EOF
usage: $0 [--record] [--root PATH]

  --root PATH   reference git worktree root to verify (env ROOT also works).
                Default: $HERE/../../VexiiYeshenLinux
                Subdirectories, .git directories, and bare repositories are
                rejected.
  --record      re-record board/vexii_baseline.{head,status,index,artifacts.sha256}
                after validating the current reference state.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --record) MODE=record ;;
    --root)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "usage error: --root requires a path" >&2
        usage
        exit 2
      fi
      case "$2" in
        -*)
          echo "usage error: --root requires a path, not an option: $2" >&2
          usage
          exit 2
          ;;
      esac
      ROOT="$2"
      ROOT_SUPPLIED=1
      shift
      ;;
    --root=*)
      ROOT="${1#--root=}"
      if [ -z "$ROOT" ]; then
        echo "usage error: --root requires a path" >&2
        usage
        exit 2
      fi
      case "$ROOT" in
        -*)
          echo "usage error: --root requires a path, not an option: $ROOT" >&2
          usage
          exit 2
          ;;
      esac
      ROOT_SUPPLIED=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
  shift
done

if [ "$ROOT_SUPPLIED" -eq 0 ]; then
  if ! DEFAULT_ROOT="$(cd "$HERE/../../VexiiYeshenLinux" 2>/dev/null && pwd)"; then
    echo "FAIL: default reference not found: $HERE/../../VexiiYeshenLinux" >&2
    echo "      pass --root PATH (or set ROOT) to point at the reference checkout" >&2
    exit 1
  fi
  ROOT="$DEFAULT_ROOT"
fi

if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "FAIL: not a git repository: $ROOT" >&2
  exit 1
fi

# Only worktree roots are supported. A bare repo has no work tree, so status
# would be empty and the artifact paths would be meaningless.
if [ "$(git -C "$ROOT" rev-parse --is-bare-repository 2>/dev/null || true)" = "true" ]; then
  echo "FAIL: bare repositories are not supported: $ROOT" >&2
  echo "      pass a worktree root (a checkout with a working tree)" >&2
  exit 1
fi

# A .git directory passes the repository probe but has no work tree; without
# this check `git status` would emit a raw fatal. Require a real work tree.
if [ "$(git -C "$ROOT" rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]; then
  echo "FAIL: --root must be a worktree root, not a git directory: $ROOT" >&2
  echo "      pass the top level of the checkout (the directory containing .git)" >&2
  exit 1
fi

PREFIX="$(git -C "$ROOT" rev-parse --show-prefix 2>/dev/null || true)"
if [ -n "$PREFIX" ]; then
  echo "FAIL: --root must be the worktree root, not a subdirectory: $ROOT" >&2
  echo "      it is inside the worktree at prefix '$PREFIX'; pass the top level instead" >&2
  exit 1
fi

if ! CUR_HEAD="$(git -C "$ROOT" rev-parse --verify HEAD 2>/dev/null)"; then
  echo "FAIL: $ROOT has an unborn HEAD (no commits); nothing to record or verify" >&2
  exit 1
fi

status_manifest() {
  git -C "$ROOT" status --porcelain
}

artifact_manifest() {
  (
    cd "$ROOT" || exit 1
    for rel in "${ARTIFACT_PATHS[@]}"; do
      if [ -f "$rel" ]; then
        sha256sum --text -- "$rel"
      fi
    done
    for rel in deliver/sbits/*.sbit; do
      if [ -f "$rel" ]; then
        sha256sum --text -- "$rel"
      fi
    done
  )
}

record_hint() {
  if [ "$ROOT_SUPPLIED" -eq 1 ]; then
    printf '  bash %q --record --root %q\n' "$0" "$ROOT"
  else
    printf '  bash %q --record\n' "$0"
  fi
}

TMP="$(mktemp -d)"
STAGE=""
cleanup() {
  if [ -n "$STAGE" ]; then
    rm -rf "$STAGE"
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

if [ "$MODE" = record ]; then
  tracked="$(git -C "$ROOT" ls-files | wc -l | tr -d '[:space:]')"
  if [ "$tracked" -eq 0 ]; then
    echo "FAIL: refusing to publish an empty baseline: $ROOT has no tracked files (empty git index)" >&2
    echo "      --root must be the top level of the reference worktree" >&2
    exit 1
  fi

  # All six key inputs must exist before a baseline may be published. This is
  # what distinguishes the reference root from a nested repository (e.g.
  # third_party/VexiiRiscv), an artifact-less linked worktree, or a fresh
  # clone that never received the ignored sw/images artifacts.
  missing_inputs=()
  for rel in "${ARTIFACT_PATHS[@]}"; do
    if [ ! -f "$ROOT/$rel" ]; then
      missing_inputs+=("$rel")
    fi
  done
  if [ ${#missing_inputs[@]} -gt 0 ]; then
    echo "FAIL: this is not the Vexii reference root (missing key inputs): $ROOT" >&2
    printf '  missing: %s\n' "${missing_inputs[@]}" >&2
    echo "      --record requires all six sw/images key inputs; nested repositories," >&2
    echo "      artifact-less worktrees, and fresh clones are refused." >&2
    exit 1
  fi

  mkdir -p "$BASE"
  STAGE="$(mktemp -d "$BASE/.baseline.XXXXXX")"
  printf '%s\n' "$CUR_HEAD" > "$STAGE/head"
  status_manifest > "$STAGE/status"
  git -C "$ROOT" ls-files -s > "$STAGE/index"
  artifact_manifest > "$STAGE/artifacts"

  indexed="$(wc -l < "$STAGE/index" | tr -d '[:space:]')"
  if [ "$tracked" -ne "$indexed" ]; then
    echo "FAIL: index manifest has $indexed lines but git ls-files reports $tracked files" >&2
    exit 1
  fi

  artifact_count="$(wc -l < "$STAGE/artifacts" | tr -d '[:space:]')"
  if [ "$artifact_count" -lt "${#ARTIFACT_PATHS[@]}" ]; then
    echo "FAIL: artifact manifest has $artifact_count entries; all ${#ARTIFACT_PATHS[@]} key inputs are required" >&2
    exit 1
  fi
  for rel in "${ARTIFACT_PATHS[@]}"; do
    if ! awk -v want="$rel" '$2 == want { found = 1 } END { exit(found ? 0 : 1) }' "$STAGE/artifacts"; then
      echo "FAIL: artifact manifest is missing required key input: $rel" >&2
      exit 1
    fi
  done

  # Validated. Publish by renaming staged files from the same filesystem as
  # the baseline. Each rename is atomic, but the four-file set is not one
  # transaction: a crash between renames could leave a mixed baseline, though
  # no unvalidated manifest is ever published.
  mv -f "$STAGE/status" "$STATUS"
  mv -f "$STAGE/index" "$INDEX"
  mv -f "$STAGE/artifacts" "$ARTIFACTS"
  mv -f "$STAGE/head" "$HEADF"
  rmdir "$STAGE"
  STAGE=""

  echo "recorded baseline: $ROOT"
  echo "  HEAD      : $(cat "$HEADF")"
  echo "  status    : $(wc -l < "$STATUS" | tr -d '[:space:]') lines"
  echo "  index     : $(wc -l < "$INDEX" | tr -d '[:space:]') files"
  echo "  artifacts : $(wc -l < "$ARTIFACTS" | tr -d '[:space:]') hashes"
  exit 0
fi

missing=()
for f in "$HEADF" "$STATUS" "$INDEX" "$ARTIFACTS"; do
  if [ ! -f "$f" ]; then
    missing+=("$f")
  fi
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "FAIL: baseline incomplete; missing:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  echo "      after confirming the reference state, record with:" >&2
  record_hint >&2
  exit 1
fi

# A baseline that does not cover all six key inputs cannot prove anything
# (it may have been recorded from a nested repo or artifact-less worktree).
if [ ! -s "$ARTIFACTS" ]; then
  echo "FAIL: corrupt or wrong baseline: artifact manifest is empty: $ARTIFACTS" >&2
  echo "      it was not recorded from a full Vexii reference root." >&2
  echo "      re-record only after confirming the reference state." >&2
  exit 1
fi
for rel in "${ARTIFACT_PATHS[@]}"; do
  if ! awk -v want="$rel" '$2 == want { found = 1 } END { exit(found ? 0 : 1) }' "$ARTIFACTS"; then
    echo "FAIL: corrupt or wrong baseline: $ARTIFACTS lacks required key input '$rel'" >&2
    echo "      re-record only after confirming the reference state." >&2
    exit 1
  fi
done

cur_head="$CUR_HEAD"
base_head="$(cat "$HEADF")"
status_manifest > "$TMP/status"
git -C "$ROOT" ls-files -s > "$TMP/index"
artifact_manifest > "$TMP/artifacts"

failed=0
if [ "$cur_head" != "$base_head" ]; then
  echo "FAIL: HEAD moved for $ROOT" >&2
  echo "  baseline: $base_head" >&2
  echo "  current : $cur_head" >&2
  failed=1
fi
if ! diff -u --label "baseline/status" --label "current/status" "$STATUS" "$TMP/status"; then
  echo "FAIL: git status changed for $ROOT (staged, unstaged, or untracked files)" >&2
  failed=1
fi
if ! diff -u --label "baseline/index" --label "current/index" "$INDEX" "$TMP/index"; then
  echo "FAIL: git index changed for $ROOT (mode/OID/stage/path)" >&2
  failed=1
fi
if ! diff -u --label "baseline/artifacts" --label "current/artifacts" "$ARTIFACTS" "$TMP/artifacts"; then
  echo "FAIL: key Phase S input hashes changed for $ROOT" >&2
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  echo "" >&2
  echo "Isolation check FAILED for $ROOT." >&2
  echo "Another session may own the reference; do not revert its changes." >&2
  echo "After confirming with the user, re-record with:" >&2
  record_hint >&2
  exit 1
fi

echo "PASS: key inputs unchanged for $ROOT (HEAD, status, index OIDs, key artifacts)"
