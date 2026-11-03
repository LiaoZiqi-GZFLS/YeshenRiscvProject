#!/bin/bash
# run_golden.sh —— 生成 2D 黄金（6 用例 + 初始帧存 + 素材），并做两条自检：
#   ① 每个用例的产物 md5 必须互不相同（否则某个用例根本没生效）；
#   ② 负对照：--fb 64x64 重跑 fill_rect，md5 必须与 1024x600 版不同。
set -u
cd "$(dirname "$0")/../.." || exit 9
CC=${CC:-gcc}
G=sim/gpu/gold
mkdir -p "$G"
"$CC" -std=c11 -O2 -Wall -Wextra -o sim/gpu/gpu2d_ref sim/gpu/gpu2d_ref.c || { echo "!! compile failed"; exit 3; }

CASES="fill_rect blit565 glyph round32 scissor edge blit8"
for c in $CASES; do
  ./sim/gpu/gpu2d_ref --case "$c" --fb 1024x600 --out "$G" || exit 4
done

echo "== 尺寸 =="
ls -l "$G"/*.bin | awk '{print $5, $9}'
echo "== md5 =="
md5sum "$G"/*.bin | tee sim/reglogs/gpu_golden_md5.txt

echo "== 自检①：六个用例的最终帧存必须两两不同 =="
python3 - "$G" <<'PY'
import hashlib, os, sys
g = sys.argv[1]
cases = "fill_rect blit565 glyph round32 scissor edge blit8".split()
h = {c: hashlib.md5(open(os.path.join(g, c + '.fb.bin'), 'rb').read()).hexdigest() for c in cases}
inv = {}
for c, v in h.items():
    inv.setdefault(v, []).append(c)
dups = [v for v in inv.values() if len(v) > 1]
assert not dups, f"duplicate outputs: {dups}"
init = hashlib.md5(open(os.path.join(g, 'fb_initial.bin'), 'rb').read()).hexdigest()
same_as_init = [c for c in cases if h[c] == init]
assert not same_as_init, f"case produced no change: {same_as_init}"
print("UNIQUE OK", len(h), "cases, none equals the initial framebuffer")
PY
rc1=$?

echo "== 自检②：负对照（64x64 必须得到不同 md5） =="
mkdir -p /tmp/gold_neg
./sim/gpu/gpu2d_ref --case fill_rect --fb 64x64 --out /tmp/gold_neg >/dev/null || exit 4
a=$(md5sum "$G/fill_rect.fb.bin" | cut -d' ' -f1)
b=$(md5sum /tmp/gold_neg/fill_rect.fb.bin | cut -d' ' -f1)
[ "$a" != "$b" ] && echo "NEG OK ($a != $b)" || { echo "!! NEG FAILED (identical md5)"; exit 5; }

[ $rc1 -eq 0 ] && echo "GOLDEN PASS" || exit 1
