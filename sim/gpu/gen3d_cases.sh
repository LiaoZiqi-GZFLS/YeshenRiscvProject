#!/bin/bash
set -u
cd "$(dirname "$0")/../.." || exit 9
for c in single two_z zswap zlequal zneg offscreen edge_hit; do
  python3 sim/gpu/tri_ref.py --case "$c" --out sim/gpu/gold3d | tail -1
done
