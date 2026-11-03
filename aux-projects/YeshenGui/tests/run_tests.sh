#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/yeshen-gui-tests"
mkdir -p "$OUT"
for t in game2048 minesweeper snake terminal; do
  case "$t" in
    game2048) src=tests/test_game2048.c; core=ui/games/core/game2048_core.c ;;
    minesweeper) src=tests/test_minesweeper.c; core=ui/games/core/mines_core.c ;;
    snake) src=tests/test_snake.c; core=ui/games/core/snake_core.c ;;
    terminal) src=tests/test_terminal_core.c; core=ui/apps/terminal_core.c ;;
  esac
  gcc -std=c11 -Wall -Wextra -O2 -I"$ROOT" -o "$OUT/test_$t" \
      "$ROOT/$src" "$ROOT/$core"
  "$OUT/test_$t"
done
echo "all core tests: PASS"
