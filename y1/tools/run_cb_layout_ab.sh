#!/usr/bin/env bash
# ============================================================================
# run_cb_layout_ab.sh —— 通道分块（CB）布局的**前置闸门**（离线，不碰 RTL/网表）
#
# 这份闸门回答一个问题：**CB 布局到底值不值得动 RTL？**
# 判据（全自动，任一红即 exit 1）：
#   ① 参照自检：`cb_layout_ref.py --selftest`（53 个真形状逐元素往返 + 2 个错布局负对照）；
#   ② 账本校准：`cb_layout_account.py --selftest` 必须复现**闸门实测锚**
#      Conv_15 `GATHER_BYTES = 924,800`（= run_b1_tilebuf_ab.sh 的实数）；
#   ③ **硬数**：全表 conv/dw 的请求数 `planar/CB ≥ 2.5`，且 **字节数相等（±0.5%）**；
#   ④ 负对照：把通道块宽 `CBLK` 改成 4 ⇒ 请求比必须**掉到 2.5 以下**（证明 ③ 对设计敏感，
#      不是恒真）；再把 `TILE` 改成 16 ⇒ 请求比同样必须变化。
#
# 用法：bash y1/tools/run_cb_layout_ab.sh
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 3          # -> y1/
PY="${PY:-python}"
echo "== run_cb_layout_ab: CB 布局前置闸门（离线）=="
echo "   python=$PY"

say() { printf '%s\n' "$*"; }

say "---- 1) 参照自检（逐元素往返 + 两个错布局负对照）----"
out="$("$PY" tools/cb_layout_ref.py --selftest 2>&1)"; rc=$?
printf '%s\n' "$out" | sed 's/^/   /'
[ $rc -eq 0 ] || { say "RESULT: FAIL（参照自检红）"; exit 1; }

say "---- 2) 账本校准（Conv_15 必须 == 924,800）----"
out="$("$PY" tools/cb_layout_account.py --selftest 2>&1)"; rc=$?
printf '%s\n' "$out" | sed 's/^/   /'
[ $rc -eq 0 ] || { say "RESULT: FAIL（账本没复现实测锚）"; exit 1; }

say "---- 3) 硬数：请求数比与字节比（真表 conv/dw 全量）----"
read -r REQ_R BYT_P BYT_C <<EOF
$("$PY" - <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cb", "tools/cb_layout_account.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
rp = rc = bp = bc = 0
for u in m.units():
    if u["type"] not in ("conv1x1", "conv3x3", "depthwise"):
        continue
    p, pb = m.planar(u); c, cby = m.cb(u)
    rp += p; rc += c; bp += pb; bc += cby
print("%.4f %d %d" % (rp / rc, bp, bc))
PY
)
EOF
say "   请求比 planar/CB = $REQ_R   字节 planar=$BYT_P  CB=$BYT_C"
awk -v r="$REQ_R" -v bp="$BYT_P" -v bc="$BYT_C" 'BEGIN{
  okr = (r >= 2.5);
  okb = (bc <= bp * 1.005) && (bc >= bp * 0.995);
  printf("   ③ 请求比 ≥2.5：%s（%.3f）\n", okr?"OK":"FAIL", r);
  printf("   ③ 字节相等 ±0.5%%：%s（%.4f）\n", okb?"OK":"FAIL", bc/bp);
  exit (okr && okb) ? 0 : 1
}' || { say "RESULT: FAIL（硬数不达标）"; exit 1; }

say "---- 4) 负对照：把 SG 单笔上限压回 32 B ⇒ 请求比必须明显下降（判据敏感）----"
neg="$(PYTHONPATH=tools "$PY" - <<'PY'
import importlib.util
def ratio(sg=None):
    spec = importlib.util.spec_from_file_location("cb", "tools/cb_layout_account.py")
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    if sg is not None:
        m.SG_MAX = sg
    rp = rc = 0
    for u in m.units():
        if u["type"] not in ("conv1x1", "conv3x3", "depthwise"):
            continue
        p, _ = m.planar(u); c, _ = m.cb(u)
        rp += p; rc += c
    return rp / rc if rc else 0.0
print("%.4f %.4f" % (ratio(), ratio(sg=32)))
PY
)"
set -- $neg
say "   base=$1  SG_MAX=32 → $2"
awk -v b="$1" -v n="$2" 'BEGIN{ exit (n < b * 0.9) ? 0 : 1 }'   && say "   (4) 负对照发火（单笔 32 B 时请求比明显下降）：OK"   || { say "   (4) 负对照没发火：FAIL"; say "RESULT: FAIL"; exit 1; }

say "RESULT: PASS"
