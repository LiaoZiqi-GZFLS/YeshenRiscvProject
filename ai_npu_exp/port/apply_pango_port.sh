#!/usr/bin/env bash
# 复制只读克隆的 Scala 源到 rtl_src/，再用 port/override/ 整文件覆盖。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
src="$root/../third_party/SpinalHDL_CNN_Accelerator/src/main/scala"
dst="$root/rtl_src"

[ -d "$src" ] || { echo "FATAL: 克隆缺失 $src"; exit 1; }
rm -rf "$dst"; mkdir -p "$dst"
cp -r "$src/." "$dst/"

n=0
while IFS= read -r -d '' f; do
  rel="${f#$here/override/}"
  [ -f "$dst/$rel" ] || { echo "FATAL: 覆盖目标不存在 $rel"; exit 1; }
  cp "$f" "$dst/$rel"
  echo "override: $rel"
  n=$((n+1))
done < <(find "$here/override" -name '*.scala' -print0)
echo "applied $n override(s) into $dst"
