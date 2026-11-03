# YeshenGui Phase S Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver Phase S of YeshenGui — a Debian-style LVGL desktop with Files/System/Settings and 2048/Minesweeper/Snake — first on a 1024×600 host simulator, then as an independent board image that borrows the existing Vexii kernel/DTB without touching its RTL, rootfs, or `sd.img`.

**Architecture:** `ui/` is platform-independent LVGL; `platform/` provides display/input/time backends (SDL2 on host, `/dev/mem` framebuffer + UART on board). Phase S never touches RTL or touch; the board image is a new rootfs/SD image built by unpacking a copy of the known-good rootfs, adding `/root/gui`, and repacking. Phase R (touch/freeze) and Phase S6 (terminal/OSK) are separate plans.

**Tech Stack:** C11, LVGL 9.2.x, SDL2, CMake, WSL GCC, `riscv32-buildroot-linux-uclibc-gcc`, busybox/uClibc, cpio/gzip, Python 3.

**Source spec:** `docs/superpowers/specs/2026-10-28-debian-style-touch-gui-design.md`

**Scope:** Tasks 0–14 cover Phase S (S0–S5). Terminal/OSK (S6) and touch RTL (Phase R) are out of scope here and get their own plans after Phase S is accepted.

---

## Environment preconditions

Run these once; stop and report if any fails.

```bash
# In WSL
sudo apt-get update
sudo apt-get install -y build-essential cmake pkg-config libsdl2-dev python3
echo "DISPLAY=$DISPLAY WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
```

Expected: `DISPLAY` or `WAYLAND_DISPLAY` is non-empty and a trivial SDL2 window can appear via WSLg. If not, stop — do not write UI code against a headless host.

```bash
# In Windows Git Bash, for the one-time LVGL clone (proxy is the known-working path)
export http_proxy=http://127.0.0.1:7897
export https_proxy=$http_proxy
```

---

## File structure (Phase S)

```
YeshenGui/
  .gitattributes
  .gitignore
  README.md
  docs/superpowers/specs/2026-10-28-debian-style-touch-gui-design.md
  docs/superpowers/plans/2026-10-28-phase-s-desktop.md
  third_party/
    PINS.md
    lv_conf.h              # our config, next to the lvgl/ checkout
    lvgl/                  # fetched, gitignored
    lvgl.commit            # pinned commit, gitignored
  tools/
    gen_wallpaper.py
  ui/
    main.c
    app.c / app.h
    theme.c / theme.h
    assets.c / assets.h
    wm.c / wm.h
    desktop.c / desktop.h
    apps/
      system_info.c
      files.c
      settings.c
    games/
      game2048.c
      minesweeper.c
      snake.c
      core/
        game2048_core.c / game2048_core.h
        mines_core.c / mines_core.h
        snake_core.c / snake_core.h
  platform/
    platform.h
    host_sdl.c
    board_fb.c
    input_uart.c
  host/
    CMakeLists.txt
  board/
    CMakeLists.txt
    riscv32-toolchain.cmake
    mk_sd_gui.py
    rootfs_overlay/
      etc/init.d/S99gui.sh
      root/gui/assets/        # generated .bin, gitignored
    vexii_baseline.head
    vexii_baseline.status
    vexii_baseline.index
    vexii_baseline.artifacts.sha256
  tests/
    test_game2048.c
    test_minesweeper.c
    test_snake.c
    run_tests.sh
  scripts/
    fetch_lvgl.sh
    build_host.sh
    build_board_app.sh
    build_board_image.sh
    verify_isolation.sh
    test_isolation.sh
    test_fetch_lvgl.sh
    gen_assets.sh
  images/                   # output, gitignored
  build/                    # output, gitignored
```

Rules:
- All UI layout numbers/colors come from spec §7; do not invent new values.
- All game rules come from spec §8.
- `third_party/lvgl/` is never modified. Put our config at `third_party/lv_conf.h`.
- `VexiiYeshenLinux/` is read-only. All generated files land under `YeshenGui/`.

---

## Task 0: Repo hygiene, isolation baseline, LVGL fetch

**Files:**
- Create: `.gitignore`, `.gitattributes`, `README.md`, `third_party/PINS.md`
- Create: `scripts/verify_isolation.sh`, `scripts/fetch_lvgl.sh`, `scripts/test_isolation.sh`, `scripts/test_fetch_lvgl.sh`
- Create: `board/vexii_baseline.head`, `board/vexii_baseline.status`, `board/vexii_baseline.index`, `board/vexii_baseline.artifacts.sha256` (generated)
- Remove: `board/vexii_baseline.sha256` (superseded by the index + artifact manifests)

- [ ] **Step 1: Write `.gitignore` and `.gitattributes`**

`.gitignore`:
```gitignore
/build/
/images/
/third_party/lvgl/
/third_party/lvgl.commit
/third_party/.lvgl.commit.*
/board/rootfs_overlay/root/gui/yshell
/board/rootfs_overlay/root/gui/assets/*.bin
/host/build/
*.o
*.d
__pycache__/
```

`.gitattributes`:
```gitattributes
* text=auto eol=lf
*.bin binary
*.img binary
*.cpio* binary
*.sbit binary
```

- [ ] **Step 2: Write `README.md` and `third_party/PINS.md`**

`README.md`:
```markdown
# YeshenGui

Debian-style LVGL desktop for the Vexii RV32 Linux board.
Phase S: host simulator + independent board image; no RTL, no touch.
Design: docs/superpowers/specs/2026-10-28-debian-style-touch-gui-design.md
```

`third_party/PINS.md`:
```markdown
# Third-party pins

| Package | Version | Source | Commit |
|---|---|---|---|
| LVGL | v9.2.0 | https://github.com/lvgl/lvgl.git | `aa7446344c6ec7631112ef031983ef24077e24d5` (`v9.2.0^{commit}`; enforced by `scripts/fetch_lvgl.sh`) |
```

The OID lets a fresh checkout know the pin without network access; `fetch_lvgl.sh` refuses to record `third_party/lvgl.commit` unless `HEAD` **and** the tag resolve to this exact OID and the tracked tree is clean.

- [ ] **Step 3: Write `scripts/verify_isolation.sh`**

```bash
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
# sw/images/. `git status --porcelain` intentionally keeps its default
# untracked mode: a wholly untracked directory is collapsed to one
# `?? build/` line, so new files inside build/ are out of scope and cannot
# force a baseline re-record.
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
# files are required, plus every deliver/sbits/*.sbit that exists. --record
# refuses a root missing any key input (nested repo, artifact-less worktree,
# fresh clone); a changed or incomplete set fails the check.
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
```


- [ ] **Step 4: Write `scripts/fetch_lvgl.sh`**

```bash
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
```


- [ ] **Step 5: Write `scripts/test_isolation.sh` and `scripts/test_fetch_lvgl.sh`**

`test_isolation.sh` copies `verify_isolation.sh` into a throwaway tree and drives temporary git repositories; it never touches the real reference or `board/`.

Covered cases:
- PASS on an unchanged reference, with the `.git/index` **hash** and mtime/size staying identical after `touch`ing a tracked file (a missing `GIT_OPTIONAL_LOCKS=0` would rewrite the index), and PASS with a clean CRLF worktree produced by `core.autocrlf=true`.
- FAIL with the specific message on an untracked file, modified tracked file, staged/index change, HEAD move, key-artifact content change, key-artifact set change, corrupted index baseline, and missing baseline.
- `--root` rejects subdirectories (`must be the worktree root`), a `.git` directory (`not a git directory`), and bare repositories (`bare repositories are not supported`); `--record` from a subdirectory, an empty index, or an unborn HEAD fails and leaves the baseline files byte-unchanged; `--root --record`/`--root=--record` is a usage error (exit 2); a failed record leaves no staged temp files.
- `--record` refuses a **nested repo root** (e.g. `third_party/VexiiRiscv`), an **artifact-less linked worktree**, and a **fresh clone** without the ignored `sw/images` inputs (`missing key inputs`), leaving the baseline byte-unchanged. Check mode rejects an empty or partial `board/vexii_baseline.artifacts.sha256` (`corrupt or wrong baseline`), so an empty-to-empty PASS is impossible.
- Inherited `GIT_DIR`/`GIT_WORK_TREE` pointing at another repository are ignored: the check still verifies `--root`.
- `--root` works from a relocated temp copy and a linked worktree; a pre-existing untracked `build/` directory is recorded as one status line and later changes inside it are out of scope; a pre-existing tracked modification can be recorded and is detected again after it is restored.
- A missing default reference exits 1 with a clear message.

`test_fetch_lvgl.sh` uses local fixture repositories only (no network) and checks that `fetch_lvgl.sh` rejects a plain directory, a plain directory inside a tagged parent repo (no false `pin verified`), a marker-less `ROOT`, a moved/re-tagged checkout, a dirty tracked checkout, a missing tag, and a `LVGL_TAG` override, while an empty directory is a valid clone target. Every failure must leave `third_party/lvgl.commit` and `.lvgl.commit.*` absent. A test-only copy with `PIN_COMMIT` substituted to the local fixture OID exercises the success path: pin content, no `.lvgl.commit.*` leftovers, idempotent rerun, and no redirection by inherited `GIT_DIR`/`GIT_WORK_TREE`.

```bash
bash scripts/test_isolation.sh
bash scripts/test_fetch_lvgl.sh
```
Expected: one `ok` line per case plus `PASS: isolation self-test` and `PASS: fetch_lvgl self-test`.

- [ ] **Step 6: Record baseline and fetch LVGL**

Run in Git Bash (proxy exported):
```bash
cd /d/code/PDS/YeshenGui
git rm --ignore-unmatch -q board/vexii_baseline.sha256   # superseded baseline, if present
bash scripts/verify_isolation.sh --record
bash scripts/fetch_lvgl.sh
bash scripts/test_isolation.sh
bash scripts/test_fetch_lvgl.sh
```

Current execution note: the final S0 baseline was re-recorded after the concurrent camsw5 PnR completed and the user confirmed: reference HEAD `212d3a2`, status `?? build/`, 818 index files, 52 key artifact hashes; `verify_isolation.sh` passes. If the reference moves again, stop/report and re-record only after confirmation; never revert another session’s changes. On a clean rerun, record only from a root with all six `sw/images` key inputs.

Expected:
- `recorded baseline: /d/code/PDS/VexiiYeshenLinux` with the **current** HEAD (S0 final `212d3a2`; earlier plan-time `2a0c4ea`), current `git status` (`?? build/`), `index: 818 files`, and `artifacts: 52 hashes` (six `sw/images` key inputs plus `deliver/sbits/*.sbit`; not every file under `sw/images`, and not untracked `build/` contents).
- If HEAD/status differs from the recorded S0 baseline (`212d3a2` + `?? build/`), stop and report; re-record only after user confirmation, and **do not revert** another session’s commit.
- `LVGL v9.2.0 @ aa7446344c6ec7631112ef031983ef24077e24d5 (pin verified)`; `third_party/lvgl.commit` matches both `HEAD` and the `v9.2.0^{commit}` OID in `PINS.md`, and the tracked LVGL tree is clean.
- `PASS: isolation self-test` and `PASS: fetch_lvgl self-test`.
- Do **not** modify `VexiiYeshenLinux`.

- [ ] **Step 7: Verify isolation check passes**

Run:
```bash
bash scripts/verify_isolation.sh
```
Expected when the baseline is aligned: `PASS: key inputs unchanged for /d/code/PDS/VexiiYeshenLinux (HEAD, status, index OIDs, key artifacts)`.

If a concurrent session changed the reference after recording, the expected result is FAIL showing only those changes (e.g. HEAD moved and index changed) plus the "do not revert its changes" advisory and the quoted `--record` hint. Do not re-record without user confirmation, and confirm the baseline files stayed byte-identical. Also confirm `stat -c '%s %Y' /d/code/PDS/VexiiYeshenLinux/.git/index` is identical before and after the check (check mode must not refresh the reference index). `--root` must name the worktree root (not a subdirectory or a `.git` directory); bare repos are rejected, and inherited `GIT_DIR`/`GIT_WORK_TREE` are ignored. `--record` publishes only when all six `sw/images` key inputs exist; nested repos, artifact-less worktrees, and fresh clones are refused.

- [ ] **Step 8: Commit**

```bash
git add .gitignore .gitattributes README.md third_party/PINS.md \
  scripts/verify_isolation.sh scripts/fetch_lvgl.sh scripts/test_isolation.sh scripts/test_fetch_lvgl.sh \
  board/vexii_baseline.head board/vexii_baseline.status \
  board/vexii_baseline.index board/vexii_baseline.artifacts.sha256
git rm --ignore-unmatch -q board/vexii_baseline.sha256
git commit -m "chore: repo hygiene, isolation baseline, LVGL pin"
```


---

## Task 1: Host skeleton — platform API, SDL2 backend, LVGL display (S0)

**Files:**
- Create: `third_party/lv_conf.h`
- Create: `platform/platform.h`, `platform/host_sdl.c`
- Create: `ui/app.c`, `ui/app.h`, `ui/main.c`
- Create: `host/CMakeLists.txt`, `scripts/build_host.sh`

- [ ] **Step 1: Write `third_party/lv_conf.h`**

```c
#ifndef LV_CONF_H
#define LV_CONF_H

#define LV_COLOR_DEPTH 16
#define LV_USE_OS LV_OS_NONE
#define LV_USE_STDLIB_MALLOC LV_STDLIB_BUILTIN
#define LV_MEM_SIZE (2 * 1024 * 1024)
#define LV_DEF_REFR_PERIOD 30
#define LV_DPI_DEF 130

#define LV_USE_LOG 1
#define LV_LOG_LEVEL LV_LOG_LEVEL_WARN
#define LV_LOG_PRINTF 1

#define LV_USE_ASSERT_NULL 1
#define LV_USE_ASSERT_MALLOC 1
#define LV_USE_ASSERT_STYLE 1
#define LV_USE_ASSERT_MEM_INTEGRITY 0
#define LV_USE_ASSERT_OBJ 1

#define LV_FONT_MONTSERRAT_14 1
#define LV_FONT_MONTSERRAT_16 1
#define LV_FONT_MONTSERRAT_20 1
#define LV_FONT_MONTSERRAT_24 1
#define LV_FONT_DEFAULT &lv_font_montserrat_14

#define LV_USE_THEME_DEFAULT 1
#define LV_USE_THEME_SIMPLE 1
#define LV_USE_FLEX 1
#define LV_USE_GRID 1

#define LV_USE_IMAGE 1
#define LV_USE_LABEL 1
#define LV_USE_BUTTON 1
#define LV_USE_CANVAS 1
#define LV_USE_SLIDER 1
#define LV_USE_SWITCH 1
#define LV_USE_MSGBOX 1
#define LV_USE_BAR 1
#define LV_USE_LINE 1

#define LV_USE_PERF_MONITOR 0
#define LV_USE_MEM_MONITOR 0
#define LV_USE_SYSMON 0

#endif
```

- [ ] **Step 2: Write `platform/platform.h`**

```c
#pragma once

#include <stdbool.h>
#include <stdint.h>

#define UI_SCREEN_W 1024
#define UI_SCREEN_H 600

typedef enum {
    UI_KEY_NONE = 0,
    UI_KEY_TAB,
    UI_KEY_ENTER,
    UI_KEY_ESC,
    UI_KEY_BACKSPACE,
    UI_KEY_UP,
    UI_KEY_DOWN,
    UI_KEY_LEFT,
    UI_KEY_RIGHT,
    UI_KEY_CHAR,
    UI_KEY_CTRL_C,
} ui_key_type_t;

typedef struct {
    ui_key_type_t type;
    char ch;
} ui_key_t;

typedef struct {
    int width;
    int height;
    uint16_t *pixels;  /* RGB565, stride_px pixels per row */
    int stride_px;
} ui_surface_t;

void platform_init(int width, int height);
void platform_shutdown(void);
void platform_flush(const ui_surface_t *surface, int x1, int y1, int x2, int y2);
uint32_t platform_time_ms(void);
void platform_delay_ms(uint32_t ms);
bool platform_should_quit(void);

/* Host returns true with mouse coordinates; board Phase S returns false. */
bool platform_poll_touch(int *x, int *y, bool *pressed);
/* Host/SDL and board UART keyboard. */
bool platform_poll_key(ui_key_t *key);

const char *platform_asset_dir(void);
void platform_log(const char *message);

#ifdef UI_HOST
void platform_screenshot(const char *path);
#endif
```

- [ ] **Step 3: Write `platform/host_sdl.c`**

```c
#include "platform.h"

#ifdef UI_HOST

#include <SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static SDL_Window *g_win;
static SDL_Renderer *g_ren;
static SDL_Texture *g_tex;
static uint16_t g_shadow[UI_SCREEN_W * UI_SCREEN_H];
static int g_mx, g_my;
static bool g_mouse_down;
static bool g_quit;
static ui_key_t g_keys[16];
static int g_key_head, g_key_tail;

static void push_key(ui_key_t k)
{
    int next = (g_key_tail + 1) % 16;
    if (next == g_key_head) {
        g_key_head = (g_key_head + 1) % 16; /* drop oldest */
    }
    g_keys[g_key_tail] = k;
    g_key_tail = next;
}

static void pump_events(void)
{
    SDL_Event e;
    while (SDL_PollEvent(&e)) {
        if (e.type == SDL_QUIT) {
            g_quit = true;
        } else if (e.type == SDL_MOUSEMOTION) {
            g_mx = e.motion.x;
            g_my = e.motion.y;
        } else if (e.type == SDL_MOUSEBUTTONDOWN && e.button.button == SDL_BUTTON_LEFT) {
            g_mx = e.button.x;
            g_my = e.button.y;
            g_mouse_down = true;
        } else if (e.type == SDL_MOUSEBUTTONUP && e.button.button == SDL_BUTTON_LEFT) {
            g_mx = e.button.x;
            g_my = e.button.y;
            g_mouse_down = false;
        } else if (e.type == SDL_KEYDOWN && !e.key.repeat) {
            ui_key_t k = { .type = UI_KEY_NONE, .ch = 0 };
            SDL_Keycode s = e.key.keysym.sym;
            if (s == SDLK_TAB) k.type = UI_KEY_TAB;
            else if (s == SDLK_RETURN || s == SDLK_KP_ENTER) k.type = UI_KEY_ENTER;
            else if (s == SDLK_ESCAPE) k.type = UI_KEY_ESC;
            else if (s == SDLK_BACKSPACE) k.type = UI_KEY_BACKSPACE;
            else if (s == SDLK_UP) k.type = UI_KEY_UP;
            else if (s == SDLK_DOWN) k.type = UI_KEY_DOWN;
            else if (s == SDLK_LEFT) k.type = UI_KEY_LEFT;
            else if (s == SDLK_RIGHT) k.type = UI_KEY_RIGHT;
            else if (s == SDLK_c && (SDL_GetModState() & KMOD_CTRL)) k.type = UI_KEY_CTRL_C;
            else if (s >= 32 && s <= 126) {
                k.type = UI_KEY_CHAR;
                k.ch = (char)s;
            }
            if (k.type != UI_KEY_NONE) push_key(k);
        }
    }
}

void platform_init(int width, int height)
{
    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        exit(1);
    }
    g_win = SDL_CreateWindow("YeshenGui", SDL_WINDOWPOS_CENTERED,
                             SDL_WINDOWPOS_CENTERED, width, height, 0);
    if (!g_win) {
        fprintf(stderr, "SDL_CreateWindow: %s\n", SDL_GetError());
        exit(1);
    }
    g_ren = SDL_CreateRenderer(g_win, -1, 0);
    if (!g_ren) {
        fprintf(stderr, "SDL_CreateRenderer: %s\n", SDL_GetError());
        exit(1);
    }
    g_tex = SDL_CreateTexture(g_ren, SDL_PIXELFORMAT_RGB565,
                              SDL_TEXTUREACCESS_STREAMING, width, height);
    if (!g_tex) {
        fprintf(stderr, "SDL_CreateTexture: %s\n", SDL_GetError());
        exit(1);
    }
    SDL_ShowCursor(SDL_ENABLE);
}

void platform_shutdown(void)
{
    if (g_tex) SDL_DestroyTexture(g_tex);
    if (g_ren) SDL_DestroyRenderer(g_ren);
    if (g_win) SDL_DestroyWindow(g_win);
    SDL_Quit();
}

void platform_flush(const ui_surface_t *s, int x1, int y1, int x2, int y2)
{
    if (!s || !s->pixels) return;
    int w = x2 - x1 + 1;
    int h = y2 - y1 + 1;
    if (w <= 0 || h <= 0) return;

    for (int row = 0; row < h; row++) {
        memcpy(&g_shadow[(y1 + row) * UI_SCREEN_W + x1],
               &s->pixels[row * s->stride_px], (size_t)w * 2);
    }

    SDL_Rect r = { x1, y1, w, h };
    SDL_UpdateTexture(g_tex, &r, &g_shadow[y1 * UI_SCREEN_W + x1],
                      UI_SCREEN_W * 2);
    SDL_RenderClear(g_ren);
    SDL_RenderCopy(g_ren, g_tex, NULL, NULL);
    SDL_RenderPresent(g_ren);
}

uint32_t platform_time_ms(void)
{
    return SDL_GetTicks();
}

void platform_delay_ms(uint32_t ms)
{
    SDL_Delay(ms);
}

bool platform_should_quit(void)
{
    pump_events();
    return g_quit;
}

bool platform_poll_touch(int *x, int *y, bool *pressed)
{
    pump_events();
    if (x) *x = g_mx;
    if (y) *y = g_my;
    if (pressed) *pressed = g_mouse_down;
    return true;
}

bool platform_poll_key(ui_key_t *key)
{
    if (g_key_head == g_key_tail) return false;
    *key = g_keys[g_key_head];
    g_key_head = (g_key_head + 1) % 16;
    return true;
}

const char *platform_asset_dir(void)
{
    const char *env = getenv("YESHENGUI_ASSET_DIR");
    return env ? env : "ui/assets";
}

void platform_log(const char *message)
{
    fprintf(stderr, "%s\n", message);
    fflush(stderr);
}

void platform_screenshot(const char *path)
{
    FILE *f = fopen(path, "wb");
    if (!f) {
        fprintf(stderr, "screenshot: cannot open %s\n", path);
        return;
    }
    fprintf(f, "P6\n%d %d\n255\n", UI_SCREEN_W, UI_SCREEN_H);
    for (int i = 0; i < UI_SCREEN_W * UI_SCREEN_H; i++) {
        uint16_t p = g_shadow[i];
        unsigned r = (p >> 11) & 0x1F;
        unsigned g = (p >> 5) & 0x3F;
        unsigned b = p & 0x1F;
        unsigned char rgb[3] = {
            (unsigned char)((r << 3) | (r >> 2)),
            (unsigned char)((g << 2) | (g >> 4)),
            (unsigned char)((b << 3) | (b >> 2)),
        };
        fwrite(rgb, 1, 3, f);
    }
    fclose(f);
}

#endif /* UI_HOST */
```

- [ ] **Step 4: Write `ui/app.h` and the S0 `ui/app.c`**

`ui/app.h`:
```c
#pragma once
int ui_app_main(int argc, char **argv);
```

`ui/app.c` (S0 placeholder; Task 4 replaces the label with `desktop_init()`):
```c
#include "app.h"
#include "platform.h"
#include "lvgl.h"
#include <stdio.h>
#include <string.h>

static uint16_t g_buf1[UI_SCREEN_W * 40];
static uint16_t g_buf2[UI_SCREEN_W * 40];
static lv_display_t *g_disp;

static void flush_cb(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map)
{
    ui_surface_t s = {
        .width = lv_area_get_width(area),
        .height = lv_area_get_height(area),
        .pixels = (uint16_t *)px_map,
        .stride_px = lv_area_get_width(area),
    };
    platform_flush(&s, area->x1, area->y1, area->x2, area->y2);
    lv_display_flush_ready(disp);
}

static void touch_cb(lv_indev_t *indev, lv_indev_data_t *data)
{
    int x = 0, y = 0;
    bool pressed = false;
    platform_poll_touch(&x, &y, &pressed);
    data->point.x = (int32_t)x;
    data->point.y = (int32_t)y;
    data->state = pressed ? LV_INDEV_STATE_PRESSED : LV_INDEV_STATE_RELEASED;
}

static void s0_screen(void)
{
    lv_obj_t *scr = lv_screen_active();
    lv_obj_set_style_bg_color(scr, lv_color_hex(0x121820), 0);
    lv_obj_t *label = lv_label_create(scr);
    lv_label_set_text(label, "YeshenGui S0\n\nLVGL + SDL2 host skeleton");
    lv_obj_set_style_text_color(label, lv_color_hex(0xF5F7FA), 0);
    lv_obj_set_style_text_font(label, &lv_font_montserrat_24, 0);
    lv_obj_center(label);
}

int ui_app_main(int argc, char **argv)
{
    const char *shot = NULL;
    bool demo = false;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--screenshot") && i + 1 < argc) shot = argv[++i];
        else if (!strcmp(argv[i], "--demo")) demo = true;
    }
    (void)demo;

    platform_init(UI_SCREEN_W, UI_SCREEN_H);
    lv_init();
    g_disp = lv_display_create(UI_SCREEN_W, UI_SCREEN_H);
    lv_display_set_color_format(g_disp, LV_COLOR_FORMAT_RGB565);
    lv_display_set_buffers(g_disp, g_buf1, g_buf2, sizeof(g_buf1),
                           LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_set_flush_cb(g_disp, flush_cb);

    lv_indev_t *indev = lv_indev_create();
    lv_indev_set_type(indev, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(indev, touch_cb);

    s0_screen();

    uint32_t last = platform_time_ms();
    if (shot) {
        for (int i = 0; i < 30; i++) {
            uint32_t now = platform_time_ms();
            lv_tick_inc(now - last);
            last = now;
            lv_timer_handler();
            platform_delay_ms(10);
        }
#ifdef UI_HOST
        platform_screenshot(shot);
#else
        (void)shot;
#endif
        platform_shutdown();
        return 0;
    }

    while (!platform_should_quit()) {
        uint32_t now = platform_time_ms();
        lv_tick_inc(now - last);
        last = now;
        uint32_t next = lv_timer_handler();
        platform_delay_ms(next < 5 ? 5 : (next > 20 ? 20 : next));
    }
    platform_shutdown();
    return 0;
}
```

- [ ] **Step 5: Add `main()` wrapper**

Create `ui/main.c`:
```c
#include "app.h"
int main(int argc, char **argv) { return ui_app_main(argc, argv); }
```
(If `ui/app.c` owns `main`, skip this file; the plan uses `ui/main.c` so the board can link the same `ui_app_main`.)

- [ ] **Step 6: Write `host/CMakeLists.txt`**

```cmake
cmake_minimum_required(VERSION 3.16)
project(yshell_host C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

find_package(PkgConfig REQUIRED)
pkg_check_modules(SDL2 REQUIRED sdl2)

# LVGL 9.2 defaults to LV_CONF_INCLUDE_SIMPLE; force our config explicitly.
set(LV_CONF_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/lv_conf.h")

add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../third_party/lvgl
                 ${CMAKE_BINARY_DIR}/lvgl)

file(GLOB_RECURSE UI_SOURCES CONFIGURE_DEPENDS
     ${CMAKE_CURRENT_SOURCE_DIR}/../ui/*.c)

add_executable(yshell_host
    ${UI_SOURCES}
    ${CMAKE_CURRENT_SOURCE_DIR}/../platform/host_sdl.c)

target_include_directories(yshell_host PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../ui
    ${CMAKE_CURRENT_SOURCE_DIR}/../platform
    ${CMAKE_CURRENT_SOURCE_DIR}/../third_party
    ${SDL2_INCLUDE_DIRS})

target_compile_options(yshell_host PRIVATE ${SDL2_CFLAGS_OTHER})
target_compile_definitions(yshell_host PRIVATE UI_HOST=1)
target_link_directories(yshell_host PRIVATE ${SDL2_LIBRARY_DIRS})
target_link_libraries(yshell_host PRIVATE lvgl ${SDL2_LIBRARIES} m)
```

- [ ] **Step 7: Write `scripts/build_host.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD_DIR:-$HOME/yeshen-gui-build/host}"
mkdir -p "$BUILD" "$ROOT/build"
cmake -S "$ROOT/host" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD" -j"$(nproc)"
cp -f "$BUILD/yshell_host" "$ROOT/build/yshell_host"
echo "built: $ROOT/build/yshell_host"
```

- [ ] **Step 8: Build and smoke-test**

Run in WSL:
```bash
cd /mnt/d/code/PDS/YeshenGui
bash scripts/build_host.sh
cd /mnt/d/code/PDS/YeshenGui
YESHENGUI_ASSET_DIR="$PWD/ui/assets" timeout 5 ./build/yshell_host --screenshot build/s0.ppm || true
ls -l build/s0.ppm
```

Expected:
- Build succeeds; `build/yshell_host` exists.
- Screenshot `build/s0.ppm` exists and is > 100 KB.
- Inspect the PPM (or convert) and confirm a 1024×600 dark screen with “YeshenGui S0”.
- If WSLg cannot show a window, stop and report; do not proceed.

- [ ] **Step 9: Commit**

```bash
git add third_party/lv_conf.h platform/platform.h platform/host_sdl.c ui/app.h ui/app.c ui/main.c host/CMakeLists.txt scripts/build_host.sh
git commit -m "feat: host SDL2 skeleton with LVGL display and touch input"
```

---

## Task 2: Wallpaper assets + theme (S1)

**Files:**
- Create: `tools/gen_wallpaper.py`, `scripts/gen_assets.sh`
- Create: `ui/assets.h`, `ui/assets.c`
- Create: `ui/theme.h`, `ui/theme.c`

- [ ] **Step 1: Write `tools/gen_wallpaper.py`**

```python
#!/usr/bin/env python3
"""Generate 1024x600 RGB565 wallpapers: Debian Ink / Debian Paper."""
import math
import struct
import sys
from pathlib import Path

W, H = 1024, 600


def rgb565(r, g, b):
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def lerp(a, b, t):
    return int(a + (b - a) * t)


def generate(path, top, bottom, swirl, alpha):
    data = bytearray(W * H * 2)
    cx, cy = 760.0, 300.0
    for y in range(H):
        t = y / (H - 1)
        br = lerp(top[0], bottom[0], t)
        bg = lerp(top[1], bottom[1], t)
        bb = lerp(top[2], bottom[2], t)
        for x in range(W):
            r, g, b = br, bg, bb
            dx, dy = x - cx, y - cy
            rad = math.hypot(dx, dy)
            if 24.0 < rad < 330.0:
                ang = math.atan2(dy, dx)
                arm = (ang + rad / 42.0) % (2.0 * math.pi)
                band = min(arm, 2.0 * math.pi - arm)
                if band < 0.20:
                    a = alpha * (1.0 - band / 0.20)
                    r = lerp(r, swirl[0], a)
                    g = lerp(g, swirl[1], a)
                    b = lerp(b, swirl[2], a)
            struct.pack_into("<H", data, (y * W + x) * 2, rgb565(r, g, b))
    Path(path).write_bytes(data)
    print(f"{path}: {len(data)} bytes")


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "ui/assets")
    out.mkdir(parents=True, exist_ok=True)
    generate(out / "wallpaper_ink.bin",
             (18, 24, 32), (9, 13, 20), (168, 0, 48), 0.58)
    generate(out / "wallpaper_paper.bin",
             (238, 242, 247), (206, 216, 228), (168, 0, 48), 0.28)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Write `scripts/gen_assets.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/tools/gen_wallpaper.py" "$ROOT/ui/assets"
```

- [ ] **Step 3: Write `ui/assets.h` / `ui/assets.c`**

`ui/assets.h`:
```c
#pragma once
#include "lvgl.h"
#include <stdbool.h>

typedef struct {
    uint8_t *data;
    lv_image_dsc_t dsc;
} ui_wallpaper_t;

bool ui_wallpaper_load(ui_wallpaper_t *wp, const char *name);
void ui_wallpaper_free(ui_wallpaper_t *wp);
```

`ui/assets.c`:
```c
#include "assets.h"
#include "platform.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

bool ui_wallpaper_load(ui_wallpaper_t *wp, const char *name)
{
    memset(wp, 0, sizeof(*wp));
    char path[256];
    snprintf(path, sizeof(path), "%s/%s.bin", platform_asset_dir(), name);

    FILE *f = fopen(path, "rb");
    if (!f) {
        platform_log("wallpaper: missing file");
        return false;
    }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size != UI_SCREEN_W * UI_SCREEN_H * 2) {
        fclose(f);
        platform_log("wallpaper: wrong size");
        return false;
    }
    wp->data = malloc((size_t)size);
    if (!wp->data || fread(wp->data, 1, (size_t)size, f) != (size_t)size) {
        free(wp->data);
        wp->data = NULL;
        fclose(f);
        platform_log("wallpaper: read failed");
        return false;
    }
    fclose(f);

    wp->dsc.header.magic = LV_IMAGE_HEADER_MAGIC;
    wp->dsc.header.cf = LV_COLOR_FORMAT_RGB565;
    wp->dsc.header.w = UI_SCREEN_W;
    wp->dsc.header.h = UI_SCREEN_H;
    wp->dsc.header.stride = UI_SCREEN_W * 2;
    wp->dsc.data_size = (uint32_t)size;
    wp->dsc.data = wp->data;
    return true;
}

void ui_wallpaper_free(ui_wallpaper_t *wp)
{
    free(wp->data);
    memset(wp, 0, sizeof(*wp));
}
```

- [ ] **Step 4: Write `ui/theme.h` / `ui/theme.c`**

`ui/theme.h`:
```c
#pragma once
#include "lvgl.h"
#include <stdbool.h>

typedef struct {
    lv_color_t bg;
    lv_color_t panel;
    lv_color_t panel_text;
    lv_color_t window;
    lv_color_t border;
    lv_color_t title;
    lv_color_t text;
    lv_color_t accent;
    lv_color_t success;
    lv_color_t warning;
} ui_theme_colors_t;

void ui_theme_init(void);
bool ui_theme_is_dark(void);
void ui_theme_set_dark(bool dark);
const ui_theme_colors_t *ui_theme_colors(void);
int ui_theme_wallpaper(void);
void ui_theme_set_wallpaper(int index);
```

`ui/theme.c`:
```c
#include "theme.h"

static bool s_dark;
static int s_wallpaper;
static ui_theme_colors_t s_light;
static ui_theme_colors_t s_dark_c;
static ui_theme_colors_t s_now;

void ui_theme_init(void)
{
    s_light = (ui_theme_colors_t){
        .bg = LV_COLOR_MAKE(0x12, 0x18, 0x20),
        .panel = LV_COLOR_MAKE(0xE9, 0xED, 0xF2),
        .panel_text = LV_COLOR_MAKE(0x1F, 0x29, 0x33),
        .window = LV_COLOR_MAKE(0xF7, 0xF9, 0xFC),
        .border = LV_COLOR_MAKE(0xC9, 0xD1, 0xDB),
        .title = LV_COLOR_MAKE(0xDD, 0xE3, 0xEA),
        .text = LV_COLOR_MAKE(0x1F, 0x29, 0x33),
        .accent = LV_COLOR_MAKE(0xA8, 0x00, 0x30),
        .success = LV_COLOR_MAKE(0x2E, 0x7D, 0x32),
        .warning = LV_COLOR_MAKE(0xE0, 0xA1, 0x00),
    };
    s_dark_c = (ui_theme_colors_t){
        .bg = LV_COLOR_MAKE(0x1F, 0x29, 0x33),
        .panel = LV_COLOR_MAKE(0x1F, 0x29, 0x33),
        .panel_text = LV_COLOR_MAKE(0xF5, 0xF7, 0xFA),
        .window = LV_COLOR_MAKE(0x2B, 0x34, 0x40),
        .border = LV_COLOR_MAKE(0x3E, 0x4C, 0x59),
        .title = LV_COLOR_MAKE(0x34, 0x41, 0x4F),
        .text = LV_COLOR_MAKE(0xF5, 0xF7, 0xFA),
        .accent = LV_COLOR_MAKE(0xE5, 0x48, 0x4D),
        .success = LV_COLOR_MAKE(0x4C, 0xAF, 0x50),
        .warning = LV_COLOR_MAKE(0xFF, 0xC1, 0x07),
    };
    s_dark = false;
    s_wallpaper = 0;
    s_now = s_light;
}

bool ui_theme_is_dark(void) { return s_dark; }
void ui_theme_set_dark(bool dark) { s_dark = dark; s_now = dark ? s_dark_c : s_light; }
const ui_theme_colors_t *ui_theme_colors(void) { return &s_now; }
int ui_theme_wallpaper(void) { return s_wallpaper; }
void ui_theme_set_wallpaper(int index) { s_wallpaper = index ? 1 : 0; }
```

- [ ] **Step 5: Generate and validate assets**

Run:
```bash
cd /mnt/d/code/PDS/YeshenGui
bash scripts/gen_assets.sh
ls -l ui/assets/wallpaper_*.bin
python3 - <<'PY'
from pathlib import Path
for p in Path('ui/assets').glob('wallpaper_*.bin'):
    assert p.stat().st_size == 1024*600*2, p
    print(p, 'OK', p.stat().st_size)
PY
```

Expected: two files, each 1,228,800 bytes.

- [ ] **Step 6: Build and display wallpaper (temporary S1 hook)**

Modify `ui/app.c` `s0_screen()` to load the wallpaper and use it as the screen background. Replace the S0 label body with:

```c
static ui_wallpaper_t g_wallpaper;
static lv_obj_t *g_wallpaper_img;

static void s0_screen(void)
{
    lv_obj_t *scr = lv_screen_active();
    lv_obj_set_style_bg_color(scr, ui_theme_colors()->bg, 0);
    const char *name = ui_theme_wallpaper() ? "wallpaper_paper" : "wallpaper_ink";
    if (ui_wallpaper_load(&g_wallpaper, name)) {
        g_wallpaper_img = lv_image_create(scr);
        lv_image_set_src(g_wallpaper_img, &g_wallpaper.dsc);
        lv_obj_set_pos(g_wallpaper_img, 0, 0);
    }
}
```
Add includes `theme.h` and `assets.h`; call `ui_theme_init()` before `s0_screen()`.

Run:
```bash
bash scripts/build_host.sh
YESHENGUI_ASSET_DIR="$PWD/ui/assets" timeout 5 ./build/yshell_host --screenshot build/s1_wallpaper.ppm || true
ls -l build/s1_wallpaper.ppm
```

Expected: screenshot shows the dark ink wallpaper with a red spiral; no LVGL assert.

- [ ] **Step 7: Commit**

```bash
git add tools/gen_wallpaper.py scripts/gen_assets.sh ui/assets.h ui/assets.c ui/theme.h ui/theme.c ui/app.c
git commit -m "feat: generated wallpapers and Debian light/dark theme"
```

---

## Task 3: Window manager (S1)

**Files:**
- Create: `ui/wm.h`, `ui/wm.c`

- [ ] **Step 1: Write `ui/wm.h`**

```c
#pragma once
#include "lvgl.h"
#include <stdbool.h>

typedef struct ui_window ui_window_t;
typedef void (*ui_close_cb_t)(ui_window_t *win);

void wm_init(lv_obj_t *window_layer, lv_obj_t *taskbar);
ui_window_t *wm_open(const char *title, int w, int h, bool maximized,
                     lv_obj_t **content_out, ui_close_cb_t on_close);
void wm_close(ui_window_t *win);
void wm_close_all(void);
void wm_focus(ui_window_t *win);
void wm_minimize(ui_window_t *win);
void wm_show_desktop(void);
void wm_close_focused(void);
int wm_count(void);
void wm_enable_bubble(lv_obj_t *obj);
```

- [ ] **Step 2: Write `ui/wm.c` (complete behavior)**

Use the spec’s dimensions. Implement:

```c
#include "wm.h"
#include "theme.h"
#include <stdio.h>
#include <string.h>

#define WM_MAX 3
#define WM_DESKTOP_W 1024
#define WM_DESKTOP_H 524
#define WM_MAX_H 508
#define WM_MAX_W 1008

struct ui_window {
    lv_obj_t *root;
    lv_obj_t *title_bar;
    char title_text[32];
    lv_obj_t *content;
    lv_obj_t *close_btn;
    lv_obj_t *min_btn;
    lv_obj_t *task_btn;
    ui_close_cb_t on_close;
    int w, h;
    bool minimized;
};

static ui_window_t *s_wins[WM_MAX];
static int s_count;
static ui_window_t *s_focus;
static lv_obj_t *s_layer;
static lv_obj_t *s_taskbar;

static void update_focus_style(void);
static void focus_event_cb(lv_event_t *e);
static void close_event_cb(lv_event_t *e);
static void min_event_cb(lv_event_t *e);
static void drag_event_cb(lv_event_t *e);
static void task_event_cb(lv_event_t *e);

void wm_init(lv_obj_t *window_layer, lv_obj_t *taskbar)
{
    s_layer = window_layer;
    s_taskbar = taskbar;
    s_count = 0;
    s_focus = NULL;
}

static void taskbar_add(ui_window_t *w)
{
    w->task_btn = lv_button_create(s_taskbar);
    lv_obj_set_size(w->task_btn, 140, 28);
    lv_obj_set_style_radius(w->task_btn, 4, 0);
    lv_obj_t *l = lv_label_create(w->task_btn);
    lv_label_set_text(l, w->title_text);
    lv_obj_center(l);
    lv_obj_add_event_cb(w->task_btn, task_event_cb, LV_EVENT_CLICKED, w);
}

ui_window_t *wm_open(const char *title, int w, int h, bool maximized,
                     lv_obj_t **content_out, ui_close_cb_t on_close)
{
    if (s_count >= WM_MAX) {
        wm_close(s_wins[0]);
    }
    ui_window_t *win = lv_malloc_zeroed(sizeof(*win));
    if (!win) return NULL;
    win->on_close = on_close;
    win->w = maximized ? WM_MAX_W : w;
    win->h = maximized ? WM_MAX_H : h;
    snprintf(win->title_text, sizeof(win->title_text), "%s", title);

    win->root = lv_obj_create(s_layer);
    lv_obj_set_size(win->root, win->w, win->h);
    lv_obj_set_pos(win->root, (WM_DESKTOP_W - win->w) / 2,
                   (WM_DESKTOP_H - win->h) / 2);
    lv_obj_set_style_bg_color(win->root, ui_theme_colors()->window, 0);
    lv_obj_set_style_bg_opa(win->root, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(win->root, 1, 0);
    lv_obj_set_style_border_color(win->root, ui_theme_colors()->border, 0);
    lv_obj_set_style_radius(win->root, 8, 0);
    lv_obj_set_style_pad_all(win->root, 0, 0);
    lv_obj_add_flag(win->root, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_flag(win->root, LV_OBJ_FLAG_EVENT_BUBBLE);
    lv_obj_add_event_cb(win->root, focus_event_cb, LV_EVENT_PRESSED, win);

    win->title_bar = lv_obj_create(win->root);
    lv_obj_set_size(win->title_bar, win->w, 36);
    lv_obj_align(win->title_bar, LV_ALIGN_TOP_MID, 0, 0);
    lv_obj_set_style_bg_color(win->title_bar, ui_theme_colors()->title, 0);
    lv_obj_set_style_bg_opa(win->title_bar, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(win->title_bar, 0, 0);
    lv_obj_set_style_radius(win->title_bar, 8, 0);
    lv_obj_set_style_pad_all(win->title_bar, 4, 0);
    lv_obj_add_event_cb(win->title_bar, drag_event_cb, LV_EVENT_PRESSED, win);
    lv_obj_add_event_cb(win->title_bar, drag_event_cb, LV_EVENT_PRESSING, win);
    lv_obj_add_event_cb(win->title_bar, drag_event_cb, LV_EVENT_RELEASED, win);

    lv_obj_t *l = lv_label_create(win->title_bar);
    lv_label_set_text(l, title);
    lv_obj_set_style_text_font(l, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(l, ui_theme_colors()->text, 0);
    lv_obj_align(l, LV_ALIGN_LEFT_MID, 0, 0);

    win->close_btn = lv_button_create(win->title_bar);
    lv_obj_set_size(win->close_btn, 48, 32);
    lv_obj_align(win->close_btn, LV_ALIGN_RIGHT_MID, 0, 0);
    lv_obj_set_style_bg_color(win->close_btn, ui_theme_colors()->accent, 0);
    lv_obj_set_style_bg_opa(win->close_btn, LV_OPA_COVER, 0);
    lv_obj_t *cl = lv_label_create(win->close_btn);
    lv_label_set_text(cl, LV_SYMBOL_CLOSE);
    lv_obj_center(cl);
    lv_obj_add_event_cb(win->close_btn, close_event_cb, LV_EVENT_CLICKED, win);

    win->min_btn = lv_button_create(win->title_bar);
    lv_obj_set_size(win->min_btn, 48, 32);
    lv_obj_align(win->min_btn, LV_ALIGN_RIGHT_MID, -52, 0);
    lv_obj_t *ml = lv_label_create(win->min_btn);
    lv_label_set_text(ml, LV_SYMBOL_MINUS);
    lv_obj_center(ml);
    lv_obj_add_event_cb(win->min_btn, min_event_cb, LV_EVENT_CLICKED, win);

    win->content = lv_obj_create(win->root);
    lv_obj_set_size(win->content, win->w - 8, win->h - 36 - 8);
    lv_obj_align(win->content, LV_ALIGN_BOTTOM_MID, 0, -4);
    lv_obj_set_style_bg_opa(win->content, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(win->content, 0, 0);
    lv_obj_set_style_pad_all(win->content, 8, 0);

    s_wins[s_count++] = win;
    taskbar_add(win);
    wm_focus(win);
    if (content_out) *content_out = win->content;
    return win;
}

void wm_close(ui_window_t *win)
{
    if (!win) return;
    if (win->on_close) win->on_close(win);
    int idx = -1;
    for (int i = 0; i < s_count; i++) if (s_wins[i] == win) idx = i;
    if (idx >= 0) {
        for (int i = idx; i + 1 < s_count; i++) s_wins[i] = s_wins[i + 1];
        s_count--;
    }
    if (s_focus == win) s_focus = NULL;
    if (win->task_btn) lv_obj_delete(win->task_btn);
    if (win->root) lv_obj_delete(win->root);
    lv_free(win);
    if (!s_focus && s_count > 0) wm_focus(s_wins[s_count - 1]);
    else update_focus_style();
}

void wm_close_all(void)
{
    /* Pop from the top so close callbacks, taskbar buttons and
     * ui_window_t allocations are released. */
    while (s_count > 0) wm_close(s_wins[s_count - 1]);
}

void wm_focus(ui_window_t *win)
{
    if (!win) return;
    s_focus = win;
    win->minimized = false;
    lv_obj_remove_flag(win->root, LV_OBJ_FLAG_HIDDEN);
    lv_obj_move_foreground(win->root);
    update_focus_style();
}

void wm_minimize(ui_window_t *win)
{
    if (!win) return;
    win->minimized = true;
    lv_obj_add_flag(win->root, LV_OBJ_FLAG_HIDDEN);
    if (s_focus == win) s_focus = NULL;
    update_focus_style();
}

void wm_show_desktop(void)
{
    for (int i = 0; i < s_count; i++) {
        s_wins[i]->minimized = true;
        lv_obj_add_flag(s_wins[i]->root, LV_OBJ_FLAG_HIDDEN);
    }
    s_focus = NULL;
    update_focus_style();
}

void wm_close_focused(void)
{
    if (s_focus) wm_close(s_focus);
    else wm_show_desktop();
}

int wm_count(void) { return s_count; }

void wm_enable_bubble(lv_obj_t *obj)
{
    if (!obj) return;
    lv_obj_add_flag(obj, LV_OBJ_FLAG_EVENT_BUBBLE);
    uint32_t n = lv_obj_get_child_count(obj);
    for (uint32_t i = 0; i < n; i++) wm_enable_bubble(lv_obj_get_child(obj, i));
}

static void update_focus_style(void)
{
    for (int i = 0; i < s_count; i++) {
        ui_window_t *w = s_wins[i];
        bool f = (w == s_focus);
        lv_obj_set_style_border_color(w->root,
            f ? ui_theme_colors()->accent : ui_theme_colors()->border, 0);
        lv_obj_set_style_border_width(w->root, f ? 2 : 1, 0);
        if (w->task_btn) {
            lv_obj_set_style_bg_color(w->task_btn,
                f ? ui_theme_colors()->accent : ui_theme_colors()->panel, 0);
            lv_obj_t *l = lv_obj_get_child(w->task_btn, 0);
            if (l) lv_obj_set_style_text_color(l,
                f ? lv_color_white() : ui_theme_colors()->panel_text, 0);
        }
    }
}

static void focus_event_cb(lv_event_t *e)
{
    wm_focus((ui_window_t *)lv_event_get_user_data(e));
}

static void close_event_cb(lv_event_t *e)
{
    wm_close((ui_window_t *)lv_event_get_user_data(e));
}

static void min_event_cb(lv_event_t *e)
{
    wm_minimize((ui_window_t *)lv_event_get_user_data(e));
}

static void task_event_cb(lv_event_t *e)
{
    ui_window_t *w = (ui_window_t *)lv_event_get_user_data(e);
    if (w->minimized) wm_focus(w);
    else if (s_focus == w) wm_minimize(w);
    else wm_focus(w);
}

static void drag_event_cb(lv_event_t *e)
{
    ui_window_t *w = (ui_window_t *)lv_event_get_user_data(e);
    lv_event_code_t code = lv_event_get_code(e);
    static lv_point_t start_p;
    static int start_x, start_y;
    if (code == LV_EVENT_PRESSED) {
        lv_indev_t *indev = lv_indev_active();
        if (indev) lv_indev_get_point(indev, &start_p);
        start_x = lv_obj_get_x(w->root);
        start_y = lv_obj_get_y(w->root);
    } else if (code == LV_EVENT_PRESSING) {
        lv_indev_t *indev = lv_indev_active();
        if (!indev) return;
        lv_point_t p;
        lv_indev_get_point(indev, &p);
        int nx = start_x + (p.x - start_p.x);
        int ny = start_y + (p.y - start_p.y);
        if (nx < 0) nx = 0;
        if (ny < 0) ny = 0;
        if (nx > WM_DESKTOP_W - w->w) nx = WM_DESKTOP_W - w->w;
        if (ny > WM_DESKTOP_H - w->h) ny = WM_DESKTOP_H - w->h;
        lv_obj_set_pos(w->root, nx, ny);
    }
}
```

- [ ] **Step 3: Build and test two windows**

Modify `ui/app.c` `s0_screen()` to initialize the WM on a layer and open two demo windows (temporary until Task 4):

```c
#include "wm.h"
...
static void demo_windows(void)
{
    lv_obj_t *layer = lv_obj_create(lv_screen_active());
    lv_obj_set_size(layer, UI_SCREEN_W, UI_SCREEN_H - 76);
    lv_obj_set_pos(layer, 0, 40);
    lv_obj_set_style_bg_opa(layer, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(layer, 0, 0);
    lv_obj_set_style_pad_all(layer, 0, 0);
    lv_obj_set_scrollbar_mode(layer, LV_SCROLLBAR_MODE_OFF);

    lv_obj_t *taskbar = lv_obj_create(lv_screen_active());
    lv_obj_set_size(taskbar, UI_SCREEN_W, 36);
    lv_obj_set_pos(taskbar, 0, UI_SCREEN_H - 36);
    lv_obj_set_style_bg_color(taskbar, ui_theme_colors()->panel, 0);
    lv_obj_set_style_bg_opa(taskbar, LV_OPA_COVER, 0);

    wm_init(layer, taskbar);
    lv_obj_t *c1, *c2;
    wm_open("Window A", 900, 460, false, &c1, NULL);
    lv_obj_t *l1 = lv_label_create(c1);
    lv_label_set_text(l1, "Drag my title bar.\nClose with X.");
    wm_open("Window B", 900, 460, false, &c2, NULL);
    lv_obj_t *l2 = lv_label_create(c2);
    lv_label_set_text(l2, "Second window; taskbar buttons work.");
}
```
Call `demo_windows()` instead of `s0_screen()` for this test.

Run:
```bash
bash scripts/build_host.sh
YESHENGUI_ASSET_DIR="$PWD/ui/assets" timeout 8 ./build/yshell_host --screenshot build/s1_wm.ppm || true
ls -l build/s1_wm.ppm
```

Expected: screenshot shows two windows with title bars and taskbar buttons; manual run allows dragging/closing; no LVGL assert.

- [ ] **Step 4: Commit**

```bash
git add ui/wm.h ui/wm.c ui/app.c
git commit -m "feat: touch-friendly window manager with taskbar"
```

---

## Task 4: Desktop shell — panel, icons, launcher, demo/screenshots (S1)

**Files:**
- Create: `ui/desktop.h`, `ui/desktop.c`
- Modify: `ui/app.c` (use desktop_init/desktop_run)

- [ ] **Step 1: Write `ui/desktop.h`**

```c
#pragma once
#include "lvgl.h"
#include <stdbool.h>

void desktop_init(void);
void desktop_set_wallpaper(int index);
void desktop_apply_theme(void);
void desktop_demo_start(const char *screenshot_dir);
void desktop_open_placeholder(const char *title);
```

- [ ] **Step 2: Implement `ui/desktop.c`**

Follow spec §7.1–§7.2 exactly. Required structure:

```c
#include "desktop.h"
#include "wm.h"
#include "theme.h"
#include "assets.h"
#include "platform.h"
#include <stdio.h>
#include <string.h>
#include <time.h>

static lv_obj_t *s_root;
static lv_obj_t *s_wall_layer;
static lv_obj_t *s_icon_layer;
static lv_obj_t *s_window_layer;
static lv_obj_t *s_panel;
static lv_obj_t *s_taskbar;
static lv_obj_t *s_menu;
static lv_obj_t *s_wall_img;
static lv_obj_t *s_cpu_label;
static lv_obj_t *s_mem_label;
static lv_obj_t *s_clock_label;
static ui_wallpaper_t s_wall;
static bool s_wall_loaded;

static void menu_toggle_cb(lv_event_t *e);
static void icon_event_cb(lv_event_t *e);
static void menu_item_cb(lv_event_t *e);
static void clock_timer_cb(lv_timer_t *t);
```

Implementation requirements:
1. Create `s_root = lv_screen_active()`; set background to `theme.bg`.
2. `s_wall_layer = lv_obj_create(s_root)` 1024×600 at 0,0; transparent, no border/pad/scroll; load wallpaper `ui_theme_wallpaper()? "wallpaper_paper":"wallpaper_ink"` and create `lv_image`; if load fails, set a solid `theme.bg` background and log.
3. `s_icon_layer = lv_obj_create(s_root)` 1024×524 at 0,40; transparent, no border/pad/scroll.
4. `s_window_layer = lv_obj_create(s_root)` 1024×524 at 0,40; transparent, no border/pad/scroll.
5. `s_panel = lv_obj_create(s_root)` 1024×40 at 0,0; style `theme.panel`, bottom border 2px `theme.accent`; flex row, pad 6, gap 6.
   - Applications button 150×32: label `LV_SYMBOL_LIST "  Applications"`; click toggles menu.
   - Quick launch buttons Games / Files / System / Settings (100×32 each) with symbols; click `desktop_open_placeholder` (Task 5–7 replace with real apps).
   - Spacer: `lv_obj_create(s_panel)` with `lv_obj_set_flex_grow(spacer, 1)`.
   - `s_cpu_label` / `s_mem_label` 80×32 labels `CPU --` / `MEM --`; `s_clock_label` 80×32 `--:--`.
   - Use `lv_obj_set_style_text_color(..., theme.panel_text, 0)`.
6. `s_taskbar = lv_obj_create(s_root)` 1024×36 at y=564; style `theme.panel`; top border 1px `theme.border`; flex row, pad 4; add a `Show Desktop` button 140×28; add a version label `YeshenGui S1`; `wm_init(s_window_layer, s_taskbar)`.
7. Desktop icons: 5 tiles at x=24, y=24 + i*112 (Files/System/Games/Settings/Camera); each 96×96:
   - `lv_button_create(s_icon_layer)`, size 96×96, transparent background, radius 8, no border; a 56×56 colored square with a symbol label (color from spec); label under it (14px). Use `lv_obj_align` inside; click `icon_event_cb` with a `const char *` title.
8. Applications menu: `s_menu = lv_obj_create(s_root)` 320×524 at 0,40; style `theme.window`; border 1px; flex column; hidden. Header label `Applications` 20px bold; group labels `Games`, `Accessories`, `System`; buttons 56px high, full width, with symbol + name; click `menu_item_cb` (closes menu, opens placeholder).
9. Clock/CPU/memory timer:
   - `lv_timer_create(clock_timer_cb, 1000, NULL)`; clock `strftime("%H:%M")`; CPU load from `/proc/loadavg` (first value ×100 / `sysconf(_SC_NPROCESSORS_ONLN)`? 1 CPU; show `CPU xx%` from load average clipped 0–100); memory from `/proc/meminfo` (`MemTotal`/`MemAvailable`) -> percent. If read fails, `--`.
10. `desktop_open_placeholder(title)`: `wm_open(title, 900, 460, false, &content, NULL)`; create a label `title` + `This screen will be implemented in Plan B.`; `wm_enable_bubble(content)`.
11. `desktop_set_wallpaper(index)`: `ui_theme_set_wallpaper(index)`; free old wallpaper; load new; set image src; if fail, log.
12. `desktop_apply_theme()`: update panel/taskbar/icon colors; simplest: call `wm_close_all()` first (so close callbacks, taskbar buttons and `ui_window_t` allocations run before the layers disappear), then delete `s_root` children and call `desktop_init()` again; document that open windows close. Use in Settings Task 7.
13. `desktop_demo_start(const char *dir)`:
    - If `dir` is non-NULL, create it with `mkdir(dir, 0755)` from `<sys/stat.h>`; ignore `EEXIST`.
    - Timer every 3s: step 0 open a placeholder "Welcome"; step 1 open "Files" placeholder; step 2 open "2048" placeholder; step 3 close all via `wm_show_desktop`; step 4 toggle menu; step 5 close menu; step 6 screenshot `desktop.ppm`; step 7 open "2048" placeholder; step 8 screenshot `window.ppm`; step 9 reset step. Use `wm_show_desktop` to hide; close windows by `wm_close` if needed. For S1, placeholders are enough.
    - `platform_screenshot(path)` is host-only (`platform.h` declares it under `#ifdef UI_HOST`): wrap the call in `#ifdef UI_HOST` / `#else` so the board build has no reference; on board, do nothing.
14. Replace `ui/app.c` `s0_screen()` with:
```c
ui_theme_init();
desktop_init();
desktop_demo_start(shot_dir);
```
and remove the temporary demo windows. Parse `--screenshots <dir>` in addition to `--screenshot <file>`. Keep `--screenshot` for a single S0 shot.

- [ ] **Step 3: Build and verify S1**

Run:
```bash
bash scripts/build_host.sh
YESHENGUI_ASSET_DIR="$PWD/ui/assets" timeout 15 ./build/yshell_host --demo --screenshots build/shots || true
ls -l build/shots
```

Expected:
- Host window 1024×600, desktop wallpaper, top panel with Applications/Games/Files/System/Settings, CPU/MEM/clock, left icons, bottom taskbar.
- Clicking Applications opens the 320px menu; clicking an icon opens a 900×460 placeholder window; title bar drags; X closes; taskbar minimizes/shows.
- `build/shots/desktop.ppm` and `window.ppm` exist and are >100 KB.
- No LVGL assert or crash.

- [ ] **Step 4: Commit**

```bash
git add ui/desktop.h ui/desktop.c ui/app.c
git commit -m "feat: Debian-style desktop shell with panel, icons, launcher, taskbar"
```

## Task 5: System Info app (S2)

**Files:**
- Create: `ui/apps/apps.h`, `ui/apps/system_info.c`
- Modify: `ui/desktop.c` (wire System button/icon)

- [ ] **Step 1: Write `ui/apps/apps.h`**

```c
#pragma once
void app_system_info_open(void);
void app_files_open(void);
void app_settings_open(void);
void game_2048_open(void);
void game_minesweeper_open(void);
void game_snake_open(void);
```

- [ ] **Step 2: Implement `ui/apps/system_info.c`**

Requirements:
- `app_system_info_open()` opens `wm_open("System Info", 900, 460, false, &content, NULL)`.
- Two-column card layout using LVGL objects; header `Vexii Debian-style Desktop` (20px).
- Fields (14px, label `#6B7785`, value `theme.text`):
  - `CPU`: `100 MHz`
  - `Load`: from `/proc/loadavg` first value, `Load %.2f`
  - `Memory`: `MemTotal`/`MemAvailable` from `/proc/meminfo`, show `xx / yy MiB`
  - `Uptime`: `/proc/uptime` seconds -> `Xd HH:MM`
  - `IPv4`: `getifaddrs()` first non-loopback `AF_INET`
  - `MAC`: read `/sys/class/net/eth0/address`
  - `Kernel`: `uname()` -> `sysname release`
  - `Board`: `PanGu 100K200K MINI / PG2L200H`
  - `Build`: `YeshenGui Phase S`
- Store value labels in a struct; create `lv_timer_create(update_cb, 1000, ctx)`.
- `update_cb` reads and updates; any failed read shows `n/a`; never blocks > a few ms.
- On `content` `LV_EVENT_DELETE`, delete the timer and free ctx.
- Call `wm_enable_bubble(content)` at the end.

Required helper signatures:
```c
static void read_first_line(const char *path, char *out, size_t out_sz);
static void read_meminfo(unsigned long *total_kb, unsigned long *avail_kb);
static void read_ipv4(char *out, size_t out_sz);
static void format_uptime(char *out, size_t out_sz);
static void update_cb(lv_timer_t *timer);
```

- [ ] **Step 3: Wire System button/icon in `desktop.c`**

Replace the System quick-launch and icon callbacks with `app_system_info_open` (include `apps/apps.h`). Keep other placeholders until their tasks.

- [ ] **Step 4: Build and test**

```bash
bash scripts/build_host.sh
YESHENGUI_ASSET_DIR="$PWD/ui/assets" timeout 10 ./build/yshell_host --demo --screenshots build/shots || true
# Manually run and click System:
YESHENGUI_ASSET_DIR="$PWD/ui/assets" timeout 30 ./build/yshell_host
```

Expected: System Info window opens; fields show real values or `n/a`; refresh every second; closing the window does not crash; no LVGL assert.

- [ ] **Step 5: Commit**

```bash
git add ui/apps/apps.h ui/apps/system_info.c ui/desktop.c
git commit -m "feat: System Info app"
```

---

## Task 6: Files app (S2)

**Files:**
- Create: `ui/apps/files.c`
- Modify: `ui/desktop.c` (wire Files button/icon)

- [ ] **Step 1: Implement `ui/apps/files.c`**

Requirements:
- `app_files_open()` opens `wm_open("Files", 900, 460, false, &content, NULL)`.
- State struct: `char cwd[256]`, `lv_obj_t *path_label`, `lv_obj_t *list`, `lv_obj_t *preview`.
- Start at `/root`; show breadcrumb label (`cwd`) and a `..` button.
- `files_refresh()`:
  - `opendir(cwd)`, iterate `readdir`; skip `.`; include `..` as first row unless `cwd == "/"`.
  - For each entry, `stat` to determine directory; create a 48px `lv_button` with a symbol (`LV_SYMBOL_DIRECTORY` or `LV_SYMBOL_FILE`) and name; click handler:
    - directory: append `/<name>`, normalize, refresh;
    - text file: show first 20 lines in the right preview pane;
    - other: preview `[binary]`.
  - Sort entries: directories first, then case-insensitive name (simple `strcasecmp`).
- Layout: left list 520px wide, right preview 340px; both scrollable; preview uses `LV_LABEL_LONG_WRAP`.
- Read-only; never write/delete.
- `wm_enable_bubble(content)`.

Required helpers:
```c
static void files_refresh(void);
static void row_click_cb(lv_event_t *e);
static void preview_file(const char *path);
static void go_parent_cb(lv_event_t *e);
```

- [ ] **Step 2: Wire Files in `desktop.c`**

Replace Files placeholder with `app_files_open`.

- [ ] **Step 3: Test**

Run host, open Files, enter `/etc`, preview `os-release`, go back, preview `/proc/version`. Expected: list/preview update; no crash; no writes.

```bash
bash scripts/build_host.sh
YESHENGUI_ASSET_DIR="$PWD/ui/assets" timeout 30 ./build/yshell_host
```

- [ ] **Step 4: Commit**

```bash
git add ui/apps/files.c ui/desktop.c
git commit -m "feat: read-only Files app"
```

---

## Task 7: Settings + Camera placeholder (S2)

**Files:**
- Create: `ui/apps/settings.c`
- Modify: `ui/desktop.c` (Settings and Camera entries)

- [ ] **Step 1: Implement `ui/apps/settings.c`**

Requirements:
- `app_settings_open()` opens `wm_open("Settings", 900, 460, false, &content, NULL)`.
- Sections:
  - **Appearance**: two rows:
    - `Theme` with `lv_switch`; toggling calls `ui_theme_set_dark(sw)`, then `desktop_apply_theme()` from the existing `lv_async_call` deferral. The rebuild calls `wm_close_all()` before deleting `s_root` children and re-running `desktop_init()`, so Settings and every other open window close cleanly (close callbacks run, `ui_window_t` allocations are freed); reopen Settings after rebuild — acceptable v1 behavior; document in a small hint label.
    - `Wallpaper` with two buttons `Debian Ink` / `Debian Paper`; calls `desktop_set_wallpaper(0/1)`.
  - **System**: `Reboot` button with an `lv_msgbox` Yes/No; `Yes` calls:
    ```c
    #ifdef UI_HOST
        platform_log("reboot skipped on host");
    #else
        sync(); system("reboot");
    #endif
    ```
  - **About**: version, build date, LVGL version (`LVGL_VERSION_MAJOR.MINOR.PATCH`), original Vexii commit `e79bcf0`, line `Debian-style demo, not Debian`.
  - **Phase R**: `Brightness` and `Camera switch` rows disabled with a `Phase R` label; clicking shows an info msgbox; no RTL calls.
- `wm_enable_bubble(content)`.
- Camera button/icon calls `desktop_open_placeholder("Camera / NPU Demo")`; its content text is `Available in Phase R (requires RTL: camera freeze + touch).`

- [ ] **Step 2: Wire Settings/Camera in `desktop.c`**

Replace placeholders: Settings -> `app_settings_open`; Camera -> `desktop_open_placeholder("Camera / NPU Demo")`.

- [ ] **Step 3: Test**

Host: toggle Light/Dark (desktop rebuilds, no crash); switch wallpaper; open About; click Phase R rows (msgbox); no writes. Reboot must be skipped on host.

- [ ] **Step 4: Commit**

```bash
git add ui/apps/settings.c ui/desktop.c
git commit -m "feat: Settings app, theme/wallpaper switching, Phase R placeholders"
```

---

## Task 8: Game cores and host unit tests (S3)

**Files:**
- Create: `ui/games/core/game2048_core.h`, `ui/games/core/game2048_core.c`
- Create: `ui/games/core/mines_core.h`, `ui/games/core/mines_core.c`
- Create: `ui/games/core/snake_core.h`, `ui/games/core/snake_core.c`
- Create: `tests/test_game2048.c`, `tests/test_minesweeper.c`, `tests/test_snake.c`, `tests/run_tests.sh`

- [ ] **Step 1: Write the core headers**

`game2048_core.h`:
```c
#pragma once
#include <stdbool.h>
#include <stdint.h>

#define G2048_N 4

typedef enum { G2048_RUNNING, G2048_WON, G2048_OVER } g2048_status_t;

typedef struct {
    uint16_t cell[G2048_N][G2048_N];
    uint32_t score;
    uint32_t rng;
    g2048_status_t status;
} g2048_t;

void g2048_init(g2048_t *g, uint32_t seed);
bool g2048_move(g2048_t *g, int dir); /* 0 up, 1 right, 2 down, 3 left */
bool g2048_can_move(const g2048_t *g);
uint32_t g2048_rand(g2048_t *g);
```

`mines_core.h`:
```c
#pragma once
#include <stdbool.h>
#include <stdint.h>

#define MINES_W 10
#define MINES_H 10
#define MINES_COUNT 30

typedef enum { MINES_RUNNING, MINES_WON, MINES_LOST } mines_status_t;

typedef struct {
    uint8_t mine[MINES_H][MINES_W];
    uint8_t open[MINES_H][MINES_W];
    uint8_t flag[MINES_H][MINES_W];
    uint8_t adj[MINES_H][MINES_W];
    uint8_t first;
    mines_status_t status;
    uint32_t rng;
    int opened;
} mines_t;

void mines_init(mines_t *m, uint32_t seed);
void mines_reveal(mines_t *m, int x, int y);
void mines_flag(mines_t *m, int x, int y);
void mines_prepare_test(mines_t *m); /* recompute adj from mine[][] for tests */
uint32_t mines_rand(mines_t *m);
```

`snake_core.h`:
```c
#pragma once
#include <stdbool.h>
#include <stdint.h>

#define SNAKE_W 20
#define SNAKE_H 15
#define SNAKE_MAX (SNAKE_W * SNAKE_H)

typedef enum { SNAKE_READY, SNAKE_RUNNING, SNAKE_OVER } snake_status_t;

typedef struct {
    int8_t x[SNAKE_MAX];
    int8_t y[SNAKE_MAX];
    int len;
    int8_t dir;
    int8_t next_dir;
    int8_t food_x, food_y;
    uint32_t score;
    uint32_t tick_ms;
    uint32_t rng;
    snake_status_t status;
} snake_t;

void snake_init(snake_t *s, uint32_t seed);
void snake_start(snake_t *s);
void snake_set_dir(snake_t *s, int dir); /* 0 up, 1 right, 2 down, 3 left */
void snake_tick(snake_t *s);
uint32_t snake_rand(snake_t *s);
```

- [ ] **Step 2: Implement the cores**

2048 rules:
- `g2048_init`: clear, seed, spawn two tiles (`2` 90%, `4` 10%), status RUNNING.
- `spawn`: choose a random empty cell; value 2 or 4; if none, no-op.
- `move`: for each line in direction, compact non-zero, merge equal adjacent once, compact, write back; add merged value to score; if any change, spawn and update status:
  - if a 2048 tile exists -> WON (only once; UI may continue; core status WON)
  - else if no moves -> OVER.
- `can_move`: any empty or equal neighbor.
- Random: xorshift32.

Mines rules:
- `mines_init`: clear; seed; first=1; status RUNNING.
- `mines_reveal`:
  - if not first and status != RUNNING -> return;
  - if first: generate `MINES_COUNT` mines excluding (x,y); first=0; compute adj; if mine -> move to first non-mine; status stays RUNNING.
  - if flagged or open -> return;
  - if mine -> open, status LOST;
  - else flood-fill open zeros/adjacent; opened++; if opened == W*H - MINES_COUNT -> WON.
- `mines_flag`: toggle flag on closed cell; no-op if open; no win check needed (flags not required).
- `mines_prepare_test`: recompute adj from mine[][]; set first=0, opened=0, status RUNNING; for tests.
- First-click mine move: find first non-mine cell in row-major and move the mine there.

Snake rules:
- `snake_init`: len=3 at center facing right; food via `snake_place_food`; status READY; tick_ms=130; score=0.
- `snake_start`: status RUNNING.
- `set_dir`: reject 180° reversal.
- `tick`: apply next_dir; compute head; wall/self collision -> OVER; if food -> grow, score+10, new food, every 5 foods tick_ms = max(80, tick_ms-5); else move tail.
- `snake_rand`: xorshift32.
- Food placement: random empty cell; retry 200 times, then scan.

- [ ] **Step 3: Write tests**

`tests/test_game2048.c`:
```c
#include "../ui/games/core/game2048_core.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void clear(g2048_t *g) { memset(g, 0, sizeof(*g)); g->status = G2048_RUNNING; g->rng = 1; }

int main(void) {
    g2048_t g;
    g2048_init(&g, 1234);
    int n = 0;
    for (int r=0;r<4;r++) for (int c=0;c<4;c++) if (g.cell[r][c]) n++;
    assert(n == 2);

    clear(&g);
    g.cell[0][0] = 2; g.cell[0][1] = 2; g.cell[0][2] = 2; g.cell[0][3] = 2;
    assert(g2048_move(&g, 3)); /* left */
    assert(g.cell[0][0] == 4);
    assert(g.cell[0][1] == 4);
    assert(g.score == 8);

    clear(&g);
    g.cell[0][0] = 2; g.cell[0][1] = 2; g.cell[0][2] = 4;
    assert(g2048_move(&g, 3));
    assert(g.cell[0][0] == 4 && g.cell[0][1] == 4);

    clear(&g);
    for (int r=0;r<4;r++) for (int c=0;c<4;c++) g.cell[r][c] = (r+c)%2 ? 2 : 4;
    assert(!g2048_can_move(&g));

    clear(&g);
    g.cell[0][0] = 2048;
    g2048_move(&g, 1);
    assert(g.status == G2048_WON);

    printf("test_game2048: PASS\n");
    return 0;
}
```

`tests/test_minesweeper.c`:
```c
#include "../ui/games/core/mines_core.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    mines_t m;
    mines_init(&m, 7);
    mines_reveal(&m, 0, 0);
    assert(!m.mine[0][0]);
    assert(m.status == MINES_RUNNING || m.status == MINES_WON);

    mines_init(&m, 7);
    memset(m.mine, 0, sizeof(m.mine));
    m.mine[9][9] = 1;
    m.mine[0][0] = 1;
    m.first = 0;
    m.status = MINES_RUNNING;
    mines_prepare_test(&m);
    mines_reveal(&m, 9, 9);
    assert(m.status == MINES_LOST);

    mines_init(&m, 7);
    memset(m.mine, 0, sizeof(m.mine));
    m.mine[0][0] = 1;
    m.first = 0;
    m.status = MINES_RUNNING;
    mines_prepare_test(&m);
    mines_flag(&m, 0, 0);
    assert(m.flag[0][0] == 1);
    mines_flag(&m, 0, 0);
    assert(m.flag[0][0] == 0);

    printf("test_minesweeper: PASS\n");
    return 0;
}
```

`tests/test_snake.c`:
```c
#include "../ui/games/core/snake_core.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    snake_t s;
    snake_init(&s, 42);
    assert(s.len == 3);
    snake_start(&s);
    int hx = s.x[0], hy = s.y[0];
    snake_tick(&s);
    assert(s.status == SNAKE_RUNNING);
    assert(s.x[0] == hx + 1 && s.y[0] == hy);

    snake_init(&s, 42);
    snake_start(&s);
    s.food_x = s.x[0] + 1; s.food_y = s.y[0];
    snake_tick(&s);
    assert(s.len == 4);
    assert(s.score == 10);

    snake_init(&s, 42);
    snake_start(&s);
    for (int i = 0; i < SNAKE_W + 2; i++) snake_tick(&s);
    assert(s.status == SNAKE_OVER);

    printf("test_snake: PASS\n");
    return 0;
}
```

- [ ] **Step 4: Write `tests/run_tests.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/yeshen-gui-tests"
mkdir -p "$OUT"
for t in game2048 minesweeper snake; do
  case "$t" in
    game2048) src=tests/test_game2048.c; core=ui/games/core/game2048_core.c ;;
    minesweeper) src=tests/test_minesweeper.c; core=ui/games/core/mines_core.c ;;
    snake) src=tests/test_snake.c; core=ui/games/core/snake_core.c ;;
  esac
  gcc -std=c11 -Wall -Wextra -O2 -I"$ROOT" -o "$OUT/test_$t" \
      "$ROOT/$src" "$ROOT/$core"
  "$OUT/test_$t"
done
echo "all game core tests: PASS"
```

- [ ] **Step 5: Run tests and negative control**

```bash
bash tests/run_tests.sh
```

Expected: three `PASS` lines.

Negative control (do not modify repo):
```bash
cp ui/games/core/game2048_core.c /tmp/g2048_mut.c
sed -i 's/g.cell\[r\]\[c\] == 0/0/' /tmp/g2048_mut.c 2>/dev/null || true
# Simpler: copy the whole repo triples to /tmp and change merge behavior there;
# run gcc with the mutated copy and expect a failed assert. Do not edit the repo.
```

The concrete negative control is: copy `ui/games/core/game2048_core.c` to `/tmp/g2048_mut.c`, replace the line that merges equal tiles with `continue;`, compile `tests/test_game2048.c` against the mutated copy, run; expected: assertion failure. Then delete `/tmp/g2048_mut.c`. If the test still passes, the test is not covering merge.

- [ ] **Step 6: Commit**

```bash
git add ui/games/core tests
git commit -m "feat: deterministic game cores with host unit tests"
```

---

## Task 9: 2048 frontend (S3)

**Files:**
- Create: `ui/games/game2048.c`
- Modify: `ui/apps/apps.h` (already declares `game_2048_open`)

- [ ] **Step 1: Implement the frontend**

Requirements:
- `game_2048_open()` opens `wm_open("2048", 0, 0, true, &content, NULL)`.
- Keep `g2048_t *g = malloc(sizeof(*g)); g2048_init(g, time(NULL));` in a per-window context; free on close.
- Top bar: `Score` and `Best` (session global) labels; `New Game` button 120×48.
- Board: 4×4 grid of 16 `lv_obj` tiles, 80×80, gap 8; each has a centered label. Use a flex container with row/column wrap or absolute positions. Color mapping from spec §8.1; text dark for 2/4, light for >=8.
- Bottom: four 64×48 arrow buttons (`LV_SYMBOL_UP/DOWN/LEFT/RIGHT`) in a cross layout; click calls `do_move`.
- `do_move(dir)`: `if (g2048_move(g, dir)) { update_tiles(); update_labels(); if (g->status == G2048_WON) show_msg("You win", Continue/Restart); else if (OVER) show_msg("Game over", Restart); }`
- Keyboard: add `LV_EVENT_KEY` callback on the window content; map `LV_KEY_UP/RIGHT/DOWN/LEFT` to directions.
- Swipe: add `LV_EVENT_GESTURE` callback; use `lv_indev_get_gesture_dir(lv_indev_active())` and map `LV_DIR_TOP/RIGHT/BOTTOM/LEFT`; call `do_move`.
- `wm_enable_bubble(content)`.

- [ ] **Step 2: Test**

Host: open 2048, press arrows / use buttons / swipe; score changes; New Game resets; no crash. Screenshot via demo.

- [ ] **Step 3: Commit**

```bash
git add ui/games/game2048.c ui/desktop.c
git commit -m "feat: 2048 touch UI"
```

---

## Task 10: Minesweeper frontend (S3)

**Files:**
- Create: `ui/games/minesweeper.c`

- [ ] **Step 1: Implement the frontend**

Requirements:
- `game_minesweeper_open()` opens a maximized window `Minesweeper`.
- Top bar: `Mines left` (30 - flags), `Time` (seconds), `Reset` button.
- Board: 10×10 grid of 36×36 buttons; each cell stores x/y.
- CLICKED -> `mines_reveal`; LONG_PRESSED -> `mines_flag`; after each, `render_all`.
- First click safe is in core; render numbers 1–8 with colors (blue/green/red/dark), flags red, mines black, closed `#B8C4D0`, open `#E9EDF2`.
- Timer: `lv_timer_create` every 1s increments time while RUNNING; stop on WON/LOST.
- Status: overlay label `You win` / `Game over` + `Play again` button (calls `mines_init` + reset timer + render).
- Keyboard: arrows move a cursor (highlight with 2px accent border), Enter reveals, `f` flags.
- `wm_enable_bubble(content)`.

- [ ] **Step 2: Test**

Host: click cells, long-press (hold mouse ~500ms) to flag, reset; ensure first click never loses; no crash. Screenshot via demo.

- [ ] **Step 3: Commit**

```bash
git add ui/games/minesweeper.c ui/desktop.c
git commit -m "feat: Minesweeper touch UI"
```

---

## Task 11: Snake frontend + Games launcher (S3)

**Files:**
- Create: `ui/games/snake.c`
- Modify: `ui/desktop.c` (Games button/icon -> `desktop_open_games`)

- [ ] **Step 1: Implement the Snake frontend**

Requirements:
- `game_snake_open()` opens a maximized window `Snake`.
- Board 20×15, cell 24px, 480×360 centered. Use a 20×15 grid of 24×24 `lv_obj` cells; initialize all to `#1F2933`; only changed cells update.
- Top bar: `Score`, `Speed` (tick ms), `Pause` button; start overlay `Swipe or use D-pad to start`; game-over overlay `Game over` + `Restart`.
- Tick timer: `lv_timer_create` with `tick_ms`; each tick calls `snake_tick`, updates changed cells, and adjusts timer period if speed changed (`lv_timer_set_period`).
- Controls: swipe gesture on content, four D-pad buttons, keyboard arrows; `p` toggles pause.
- `wm_enable_bubble(content)`.

- [ ] **Step 2: Implement `desktop_open_games()`**

In `ui/desktop.c`, add a `Games` launcher window (900×460) with three 280×140 cards: 2048, Minesweeper, Snake; each card has an icon, name, one-line description; click opens the game and closes the launcher. Wire the Games panel/icon to this.

- [ ] **Step 3: Test**

Host: open Games, launch each game; play briefly; restart; no crash. Use `--demo` screenshots for all three.

- [ ] **Step 4: Commit**

```bash
git add ui/games/snake.c ui/desktop.c
git commit -m "feat: Snake UI and Games launcher"
```

---

## Task 12: Keyboard input + focus (S3/S4)

**Files:**
- Create: `platform/input_uart.c`
- Modify: `ui/app.c` (global shortcuts, keypad indev), `ui/wm.c` (group registration)
- Modify: `ui/games/*.c` (key event callbacks)

- [ ] **Step 1: Add global shortcuts and LVGL keypad**

In `ui/app.c`:
- Create a `lv_group_t *g_group = lv_group_create(); lv_group_set_default(g_group);`.
- Create a keypad indev:
```c
static ui_key_t g_key_q[16];
static int g_qh, g_qt;
static void key_read_cb(lv_indev_t *indev, lv_indev_data_t *data)
{
    if (g_qh == g_qt) { data->state = LV_INDEV_STATE_RELEASED; return; }
    ui_key_t k = g_key_q[g_qh]; g_qh = (g_qh + 1) % 16;
    data->key = (uint32_t)k.ch;
    if (k.type == UI_KEY_TAB) data->key = LV_KEY_NEXT;
    else if (k.type == UI_KEY_ENTER) data->key = LV_KEY_ENTER;
    else if (k.type == UI_KEY_ESC) data->key = LV_KEY_ESC;
    else if (k.type == UI_KEY_UP) data->key = LV_KEY_UP;
    else if (k.type == UI_KEY_DOWN) data->key = LV_KEY_DOWN;
    else if (k.type == UI_KEY_LEFT) data->key = LV_KEY_LEFT;
    else if (k.type == UI_KEY_RIGHT) data->key = LV_KEY_RIGHT;
    else if (k.type == UI_KEY_BACKSPACE) data->key = LV_KEY_BACKSPACE;
    data->state = LV_INDEV_STATE_PRESSED;
}
```
- Main loop: for each `platform_poll_key`, call `ui_global_key(&k)`; if false, push into `g_key_q`.
- `ui_global_key`: `g` -> games, `f` -> files, `i` -> system, `s` -> settings, `1/2/3` -> games, `q` -> `wm_close_focused()`, `Ctrl+C` -> quit yshell only if no terminal (S6 not present). Return true if handled.
- `wm_open`/`wm_focus`: add `win->root` to the default group and focus it. `wm_close` deletes it (LVGL removes).
- Add `LV_OBJ_FLAG_CLICKABLE`/`CLICK_FOCUSABLE` to game roots; games handle `LV_EVENT_KEY`.

- [ ] **Step 2: Write `platform/input_uart.c`**

- Open `/dev/ttyS0` (or `$UI_TTY`), `tcgetattr`, set raw (`cfmakeraw`), `VMIN=0`, `VTIME=0`; restore on shutdown.
- `platform_poll_key`: read available bytes with `read(fd, &c, 1)`; parse:
  - printable 32–126 -> `UI_KEY_CHAR`;
  - `\r`/`\n` -> ENTER; `\t` -> TAB; `0x7f`/`\b` -> BACKSPACE; `0x03` -> CTRL_C;
  - `ESC [ A/B/C/D` -> arrows; bare ESC -> ESC.
- Non-blocking; return false if no key.
- Board platform uses this; host uses SDL.

- [ ] **Step 3: Test**

Host keyboard: `g` opens Games, `1` opens 2048, arrows move, `q` closes; `f`/`i`/`s` open apps. Board UART is tested in Task 15. Expected: keys work, no softlock.

- [ ] **Step 4: Commit**

```bash
git add platform/input_uart.c ui/app.c ui/wm.c ui/games/*.c
git commit -m "feat: keyboard input, global shortcuts, focus groups"
```

---

## Task 13: Board platform backend + cross build (S4)

**Files:**
- Create: `platform/board_fb.c`
- Create: `board/CMakeLists.txt`, `board/riscv32-toolchain.cmake`, `scripts/build_board_app.sh`

- [ ] **Step 1: Write `platform/board_fb.c`**

Requirements:
- `platform_init`: open `/dev/mem` (`O_RDWR|O_SYNC`), `mmap` `0x90000000` and `0x91000000`, length `1024*720*2`; if fail, `platform_log` + exit(1). Write `YGUI-BOOT` to `/dev/kmsg`.
- `platform_flush`: for each row y in area, copy `w` pixels from `surface->pixels + row*stride_px` to:
  - bank0: `(uint16_t*)fb0 + (y+60)*1024 + x1`
  - bank1: `(uint16_t*)fb1 + (y+60)*1024 + x1`
  Use 32-bit stores where possible; handle odd widths with a uint16_t tail.
- `platform_time_ms`: `clock_gettime(CLOCK_MONOTONIC)`.
- `platform_delay_ms`: `usleep(ms*1000)`.
- `platform_should_quit`: false.
- `platform_poll_touch`: return false.
- `platform_asset_dir`: `/root/gui/assets`.
- `platform_log`: write the string + newline to `/dev/kmsg` (open/append/close; best-effort).
- `platform_shutdown`: `munmap`, close.
- Mark `YGUI-FB-OK` once after the first successful flush.
- **Do not define `platform_poll_key` here**; it lives in `platform/input_uart.c` (Task 12) and is linked into `yshell` through `board/CMakeLists.txt`. `board_fb.c` must not provide a second definition.

- [ ] **Step 2: Confirm demo is UI-level**

`--demo` is handled by the UI demo timer in `ui/app.c`; there is no `platform/input_demo.c`. Do not add an extra input backend. Board keyboard input is `input_uart.c`; host keyboard is `host_sdl.c`.

- [ ] **Step 3: Write `board/riscv32-toolchain.cmake`**

```cmake
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR riscv32)
set(CMAKE_C_COMPILER "$ENV{HOME}/vexii-build/buildroot/output/host/bin/riscv32-buildroot-linux-uclibc-gcc")
set(CMAKE_C_FLAGS "-O2 -march=rv32imac -mabi=ilp32 -static")
set(CMAKE_EXE_LINKER_FLAGS "-static")
```

The actual buildroot toolchain in this workspace is `riscv32-buildroot-linux-uclibc-*`; the earlier `riscv64-...` path does not exist (Task 12 confirmed the compiler). The toolchain file must `FATAL_ERROR` if this compiler is missing and must not silently fall back to host/riscv64 gcc; `YSHELL_RV32_CC` may override the compiler path explicitly.

- [ ] **Step 4: Write `board/CMakeLists.txt`**

Similar to host, no SDL. Set `LV_CONF_PATH` before `add_subdirectory`, for the same LVGL 9.2 `LV_CONF_INCLUDE_SIMPLE` reason as Task 1:
```cmake
cmake_minimum_required(VERSION 3.16)
project(yshell_board C)
set(CMAKE_C_STANDARD 11)
# LVGL 9.2 defaults to LV_CONF_INCLUDE_SIMPLE; force our config explicitly.
set(LV_CONF_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/lv_conf.h")
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../third_party/lvgl ${CMAKE_BINARY_DIR}/lvgl)
file(GLOB_RECURSE UI_SOURCES CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/../ui/*.c)
add_executable(yshell ${UI_SOURCES}
    ${CMAKE_CURRENT_SOURCE_DIR}/../platform/board_fb.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../platform/input_uart.c)
target_include_directories(yshell PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../ui
    ${CMAKE_CURRENT_SOURCE_DIR}/../platform
    ${CMAKE_CURRENT_SOURCE_DIR}/../third_party)
target_link_libraries(yshell PRIVATE lvgl m)
```

- [ ] **Step 5: Write `scripts/build_board_app.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD_DIR:-$HOME/yeshen-gui-build/board}"
OUT="$ROOT/board/rootfs_overlay/root/gui/yshell"
mkdir -p "$BUILD" "$(dirname "$OUT")"
cmake -S "$ROOT/board" -B "$BUILD" \
  -DCMAKE_TOOLCHAIN_FILE="$ROOT/board/riscv32-toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD" -j"$(nproc)"
cp -f "$BUILD/yshell" "$OUT"
chmod 0755 "$OUT"
file "$OUT"
readelf -h "$OUT" | grep -E "Machine|Flags"
ls -l "$OUT"
```

- [ ] **Step 6: Build and inspect**

Run:
```bash
cd /mnt/d/code/PDS/YeshenGui
bash scripts/build_board_app.sh
```
Expected: `Machine: RISC-V`, size reasonable (a few MB static), no link errors. Do not run on host (RV32 binary).

- [ ] **Step 7: Commit**

```bash
git add platform/board_fb.c platform/input_uart.c board/CMakeLists.txt board/riscv32-toolchain.cmake scripts/build_board_app.sh
git commit -m "feat: board framebuffer/UART backend and RV32 cross build"
```

---

## Task 14: Rootfs + SD image + isolation (S4)

**Files:**
- Create: `scripts/build_board_image.sh`, `board/mk_sd_gui.py`, `board/rootfs_overlay/etc/init.d/S99gui.sh`
- Modify: `board/vexii_baseline.*` only via `--record` after the user confirms a reference change (should not); never re-record silently

- [ ] **Step 1: Copy the proven SD packer (read-only source)**

```bash
cp /mnt/d/code/PDS/VexiiYeshenLinux/sim/mk_sd_image.py board/mk_sd_gui.py
chmod +x board/mk_sd_gui.py
```
Do not edit the original. In `board/mk_sd_gui.py`, add a guard at the top:
```python
if "--out" in sys.argv:
    out = sys.argv[sys.argv.index("--out") + 1]
    if "/VexiiYeshenLinux/" in out:
        raise SystemExit("refusing to overwrite VexiiYeshenLinux images")
```
(Adjust imports/argument handling to the actual file; keep its table format and CRC logic unchanged.)

- [ ] **Step 2: Write `scripts/build_board_image.sh`**

`set -euo pipefail`; steps:

```bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VEXII="${VEXII:-/mnt/d/code/PDS/VexiiYeshenLinux}"
WS="${WS:-$HOME/yeshen-gui-build/rootfs}"
IMG="$ROOT/images"
cd "$ROOT"
mkdir -p "$WS" "$IMG" "$ROOT/board/rootfs_overlay/root/gui/assets"

# 1. isolation baseline before build (worktree root; stop on concurrent WIP)
bash "$ROOT/scripts/verify_isolation.sh"

# 2. copy known-good inputs (read-only source)
cp -f "$VEXII/sw/images/Image" "$IMG/Image"
cp -f "$VEXII/sw/images/fw_jump.bin" "$IMG/fw_jump.bin"
cp -f "$VEXII/sw/images/linux.dtb" "$IMG/linux.dtb"
cp -f "$VEXII/sw/images/rootfs_v2.cpio" "$IMG/rootfs_base.cpio"

# 3. unpack rootfs in WSL-native fs
rm -rf "$WS/root"
mkdir -p "$WS/root"
(cd "$WS/root" && cpio -idmv < "$IMG/rootfs_base.cpio" >/dev/null 2>&1)
test -x "$WS/root/init"
test -x "$WS/root/bin/sh"

# 4. apply GUI overlay; remove y1cam autostart only in this copy
rm -f "$WS/root/etc/init.d/S99y1cam.sh"
cp -a "$ROOT/board/rootfs_overlay/." "$WS/root/"
chmod 0755 "$WS/root/root/gui/yshell" "$WS/root/etc/init.d/S99gui.sh" 2>/dev/null || true

# 5. repack
(cd "$WS/root" && find . -print0 | cpio --null -o -H newc | gzip -9) > "$IMG/rootfs_gui.cpio.gz"
python3 - <<'PY'
import pathlib
p = pathlib.Path("images/rootfs_gui.cpio.gz")
print("rootfs_gui.cpio.gz", p.stat().st_size)
assert p.stat().st_size <= 7_864_320, "rootfs > 7.5 MiB; build a 16 MiB DTB"
PY

# 6. DTB: reuse existing if size fits; otherwise generate a new one with initrd-end=0x84000000
cp -f "$IMG/linux.dtb" "$IMG/linux_gui.dtb"

# 7. SD image
python3 "$ROOT/board/mk_sd_gui.py" --out "$IMG/sd_gui.img" \
  --entry 0x80000000="$IMG/fw_jump.bin" \
  --entry 0x82000000="$IMG/Image" \
  --entry 0x82F80000="$IMG/linux_gui.dtb" \
  --entry 0x83000000="$IMG/rootfs_gui.cpio.gz"

# 8. verify magic and isolation
python3 - <<'PY'
from pathlib import Path
img = Path("images/sd_gui.img").read_bytes()
assert img[:4] == b"YSLD", "bad SD image magic"
print("sd_gui.img", len(img), "bytes, YSLD OK")
PY
bash "$ROOT/scripts/verify_isolation.sh"
```

- [ ] **Step 3: Add `S99gui.sh` (optional autostart)**

```bash
#!/bin/sh
# Only starts when the explicit flag exists; default Phase S keeps getty.
if [ -f /etc/y1gui.autostart ] && [ -x /root/gui/yshell ]; then
    /root/gui/yshell --demo >/dev/null 2>&1 &
    echo "YGUI-AUTOSTART pid=$!" > /dev/kmsg 2>/dev/null
fi
```

- [ ] **Step 4: Build the image**

Run in WSL:
```bash
cd /mnt/d/code/PDS/YeshenGui
bash scripts/build_board_image.sh
```
Expected:
- `images/sd_gui.img` exists; magic `YSLD`; size reasonable.
- `rootfs_gui.cpio.gz` ≤ 7.5MiB; if it fails the assert, stop and build the 16MiB DTB variant (Task 14 Step 5).
- `verify_isolation.sh` uses the reference worktree root and prints PASS only if the recorded baseline is aligned; original Vexii HEAD/status/index OIDs and the 52 key Phase S input hashes are unchanged (all six `sw/images` key inputs are required). If it reports a concurrent change, stop and report; do not revert it or re-record without user confirmation. Untracked `build/` contents are out of scope by design.
- `ls -l images/` shows the new files; `VexiiYeshenLinux/sw/images/sd.img` mtime/sha256 unchanged.

- [ ] **Step 5: DTB variant if needed**

If rootfs > 7.5MiB:
- Copy `$VEXII/sw/buildroot-external/boards/naxmini/linux/linux_raw.dts` to `board/dtb/linux_gui.dts`.
- Change `linux,initrd-end = <0x84000000>;`.
- `dtc -I dts -O dtb -o images/linux_gui.dtb board/dtb/linux_gui.dts` (preprocess `##` if needed; use the existing setup script/cpp).
- Re-run the SD packer with the new DTB.
- Do not rebuild the kernel or touch RTL.

- [ ] **Step 6: Commit**

```bash
git add scripts/build_board_image.sh board/mk_sd_gui.py board/rootfs_overlay/etc/init.d/S99gui.sh
git commit -m "feat: independent rootfs and sd_gui.img build with isolation check"
```

---

## Task 15: Board run, performance, acceptance (S4–S5)

**Files:**
- Create: `docs/phase-s-bringup.md`
- Modify: `ui/app.c` (FPS marker; optional), `README.md`

- [ ] **Step 1: Add FPS/liveness markers**

In `ui/app.c`, count flushes; every 5 seconds write `YGUI-FPS n` via `platform_log`. On host, print to stderr; on board, kmsg. This is diagnostic only.

- [ ] **Step 2: Write `docs/phase-s-bringup.md`**

Include:
- Build commands (host/board).
- SD card writing: use a **different** TF card; do not overwrite the existing camera card. `dd`/Win32DiskImager instructions.
- Boot: JTAG/bitstream unchanged; insert `sd_gui.img`; serial login.
- Run: `/root/gui/yshell` or `--demo`.
- Markers: `YGUI-BOOT`, `YGUI-FB-OK`, `YGUI-FPS`, `YGUI-EXIT`.
- Display test: unplug J10 camera; LCD should show desktop. If not, record `BOARD-DISPLAY-BLOCKED` and defer to Phase R.
- Keyboard: UART arrows/Tab/Enter/Esc/shortcuts; games.
- Phase S limitations: no touch, no camera switch, no terminal yet.
- Acceptance checklist from spec §11.4.

- [ ] **Step 3: Board test**

With the board available:
1. Write `sd_gui.img` to a spare TF card.
2. Boot; login; run `/root/gui/yshell`.
3. Check `YGUI-BOOT`/`YGUI-FB-OK`; open Files/System/Settings, play each game with UART keyboard.
4. Unplug J10; relaunch; confirm LCD desktop. If blocked, record.
5. Measure FPS via `YGUI-FPS`; target static ≥30fps, drag ≥10fps; if lower, reduce animations/wallpaper complexity.
6. Verify original `sd.img`/bitstream untouched; run `verify_isolation.sh` (expect PASS on HEAD/status/index OIDs and the 52 key inputs, including all six required `sw/images` inputs, only when the baseline is aligned; if a concurrent WIP is reported, stop and report it without reverting or re-recording).
7. Save logs/screenshots/photos under `docs/acceptance/`.

- [ ] **Step 4: Update README and commit**

README: how to build/run, Phase S scope/limitations, links to spec/bringup.

```bash
git add README.md docs/phase-s-bringup.md ui/app.c
git commit -m "docs: Phase S bring-up and acceptance"
```

---

## Self-review

### Spec coverage

| Spec area | Task |
|---|---|
| Phase S isolation / no RTL / no touch | Tasks 0, 13, 14 |
| Host 1024×600 simulator | Task 1 |
| Wallpaper/theme | Task 2 |
| Window manager | Task 3 |
| Desktop shell / panel / icons / menu / taskbar | Task 4 |
| System Info | Task 5 |
| Files | Task 6 |
| Settings / Camera Phase R | Task 7 |
| 2048 / Minesweeper / Snake cores + tests | Task 8 |
| Game frontends + Games launcher | Tasks 9–11 |
| Keyboard / focus / UART | Task 12 |
| Board framebuffer / cross build | Task 13 |
| Rootfs / SD image / isolation | Task 14 |
| Board test / performance / acceptance | Task 15 |
| Terminal + OSK (S6) | Out of scope; separate plan |
| Touch / freeze / camera switch (Phase R) | Out of scope; separate plan |

### Placeholder scan

No `TBD`, `TODO`, or “implement later” in this plan. UI layout/color values are referenced from spec §7; game rules/colors from spec §8. Code snippets for the foundational modules, cores, tests, and build scripts are concrete; UI frontend tasks specify exact objects, sizes, callbacks, and acceptance tests.

### Type consistency

- `ui_key_t` / `ui_key_type_t` defined once in `platform.h`; host, UART, and app use the same names.
- `ui_window_t` opaque; `wm_open` returns it; `wm_close/focus/minimize` accept it; apps never dereference it.
- `ui_surface_t` used by both host and board flush.
- `g2048_t`, `mines_t`, `snake_t` defined in their core headers; frontends and tests include those headers.
- `desktop_*` / `app_*_open` / `game_*_open` names match across tasks.
- `platform_asset_dir()` is implemented by host (`YESHENGUI_ASSET_DIR` or `ui/assets`) and board (`/root/gui/assets`).

### Known implementation risks

- LVGL CMake target name: the plan assumes `lvgl`; S0 build verifies and fixes the target name if needed.
- `lv_image_dsc_t`/image header fields: verify against LVGL 9.2.0 at S0; the wallpaper loader is the only image path.
- `i2c`/touch are not in Phase S by design; do not add them.
- Board display without RTL is conditional on the camera being unplugged; record `BOARD-DISPLAY-BLOCKED` honestly if it fails.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-10-28-phase-s-desktop.md`.

Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session with checkpoints for review.

Which approach?
