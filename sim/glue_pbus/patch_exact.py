#!/usr/bin/env python3
# 精确串替换（只替换**第一处**匹配）；找不到就报错退出 1。
# 用途：负对照脚本要把 RTL 里某一道门**准确摘掉**。用 sed 曾静默 no-op（补丁没打上，
# 却被读成"负对照通过"），所以这里改成"替换不到就是错误"。
#
# 来源：复制自 `YeshenCore/sim/patch_exact.py`（该仓库只读参考、未改动），
#       方法论见 `YeshenCore/sim/negctl_ddrgroup.sh` 头部与 YeshenCore 的 §5.13.8。
import sys

path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, 'r', encoding='utf-8') as f:
    s = f.read()

n = s.count(old)
if n == 0:
    print("patch_exact: pattern not found in %s: %r" % (path, old))
    sys.exit(1)
s = s.replace(old, new, 1)
with open(path, 'w', encoding='utf-8', newline='') as f:
    f.write(s)
print("patch_exact: ok（原出现 %d 次，已替换 1 处）" % n)
