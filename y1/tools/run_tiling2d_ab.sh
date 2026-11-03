#!/usr/bin/env bash
# run_tiling2d_ab.sh —— y1 T0 闸门：**2-D tiling（64×32）+ halo == 整层** 的 Python 算术等价（零 RTL）。
#
# 为什么需要它（spec §5 T0 / §3 方案 C）：把真帧装进 PG2L200H 要走 **2-D 64×32 tile + 运行期 rowW**。
#   在碰 RTL 之前，必须**离线把 halo 规则钉死**：把一层的输出切成 64×32 tile，每个 tile 只喂它
#   **需要的输入窗口（tile + halo）**，用**冻结参考**算，再把每 tile 输出拼回整层 ⇒ 与整层**逐字节**相等。
#   若这条等价（或它的负对照）没钉死，RTL 会照一张错单子做（halo 跨 tile 边界错一拍 ⇒ 接缝，R2）。
#
# ============================== 判据 ==============================
#  0) **小张量自检**：`tools/tiling_ref.py --selftest2d`
#       · 正对照：conv3x3 / depthwise / stride2 / maxpool / resize / add，tile(+halo) == 整层（逐字节）；
#       · int32 恒等式：拼回的累加平面 == 整层 acc；
#       · 三条负对照都发火（无 halo 接缝 / maxpool 奇数偏移 / add 第二路错网格）。
#  1) **正对照**：`tools/tiling_ref.py --gate2d`——真表 **27 个有 halo 的项**逐项 `tile(+halo) == 整层`
#     （`MISMATCH=0`）；conv1x1（0 halo）全量；maxpool/resize/add 真几何全量；并断言整层参考 == 黄金。
#  2) **负对照（有牙）**：每项**无 halo** ⇒ 接缝必须变（`NEG_NOFIRE=0`）；maxpool 奇数偏移 + add 错网格也发火。
#  3) **发火证据（红）**：注入 `tile-drop`（漏一趟）⇒ 判据必须红（退出 1）；
#     注入 `halo-nofire` / `misalign-nofire`（负对照失效）⇒ 必须红（退出 2）。
#     哪一发**没**发火 ⇒ 本闸门退出 2（判据无牙 ⇒ 不可信）。
#
# 退出码：0 = 全绿；1 = 判据红（MISMATCH>0 / 整层参考 != 黄金）；2 = 负对照没发火（判据无牙）；
#         3 = 前置缺失（缺 python / 缺 onnx / 缺冻结件）。
#
# 用法：bash y1/tools/run_tiling2d_ab.sh   （可 PY=<python> 覆盖解释器）
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }
tool="${TOOL:-tools/tiling_ref.py}"
onnx="../third_party/yunet/yunet.onnx"
index="gen/wgt_index.json"
desc="gen/desc.bin"
pydeps="./.pydeps"
deps="../third_party/yunet/deps"

[ -f "$tool" ] || { echo "FATAL: 缺 $tool"; echo "RESULT: FAIL"; exit 3; }
[ -f "$onnx" ] || { echo "FATAL: 缺模型 $onnx"; echo "RESULT: FAIL"; exit 3; }
[ -f "$index" ] || { echo "FATAL: 缺 $index"; echo "RESULT: FAIL"; exit 3; }
[ -f "tools/bypass_ref.py" ] || { echo "FATAL: 缺冻结件 tools/bypass_ref.py"; echo "RESULT: FAIL"; exit 3; }
[ -f "tools/quant_ref.py" ] || { echo "FATAL: 缺冻结件 tools/quant_ref.py"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

export PYTHONPATH="$pydeps;$deps"
export PYTHONIOENCODING=utf-8

work="$(mktemp -d)"
cleanup() { if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => 保留 $work"; else rm -rf "$work"; fi; }
trap cleanup EXIT

echo "== run_tiling2d_ab: PY=$PY =="
echo "   tool=$tool  onnx=$onnx  index=$index  desc=$desc"
echo "   tmp =$work"

# ---------------- 0) 小张量自检 ----------------
"$PY" "$tool" --selftest2d > "$work/st.out" 2> "$work/st.err"
st_rc=$?
echo "---- [0] tiling_ref.py --selftest2d ----"
grep -v '^RESULT:' "$work/st.out" | sed 's/^/    /'
[ -s "$work/st.err" ] && sed -n '1,20p' "$work/st.err" >&2
if [ "$st_rc" -ne 0 ] || ! grep -q '^SELFTEST2D: PASS$' "$work/st.out"; then
  echo "JUDGE-RED: --selftest2d 未过（rc=$st_rc）"
  echo "RESULT: FAIL"
  exit 1
fi

# ---------------- 1) 真表 2-D tiling 闸门（正对照 + 负对照 + 定位 + 流量） ----------------
"$PY" "$tool" --gate2d > "$work/g2.out" 2> "$work/g2.err"
g_rc=$?
echo "---- [1] T0 2-D tiling(+halo) == 整层（真表 27 halo 项 + 旁路族）----"
grep -E '^(HALO |C1X1|C1X1_TOTAL|MAXPOOL|RESIZE|ADD |ADD_SRC2|TRAFFIC2D|GATE2D_TOTAL)' "$work/g2.out" | sed 's/^/    /'
[ -s "$work/g2.err" ] && sed -n '1,20p' "$work/g2.err" >&2
[ -s "$work/g2.out" ] || { echo "FATAL: 未产出 gate2d 输出"; echo "RESULT: FAIL"; exit 3; }

if [ "$g_rc" -ne 0 ] || ! grep -q '^RESULT: PASS$' "$work/g2.out"; then
  echo "JUDGE-RED: T0 判据未过（rc=$g_rc）"
  grep -E '^(TILING2D_RESULT|RESULT:)' "$work/g2.out" | sed 's/^/    /'
  echo "RESULT: FAIL"
  exit 1
fi
# 把自己抠出判据（不靠一个 blurb）
if ! grep -qE 'positive_mismatch=0( |$)' "$work/g2.out"; then
  echo "JUDGE-RED: 正对照有逐字节不一致（positive_mismatch != 0）"; echo "RESULT: FAIL"; exit 1
fi
if ! grep -qE 'halo_ok=27/27( |$)' "$work/g2.out"; then
  echo "JUDGE-RED: halo 27 项没有全绿"; echo "RESULT: FAIL"; exit 1
fi
if ! grep -qE 'guard_bad=0( |$)' "$work/g2.out"; then
  echo "JUDGE-RED: 整层参考 != 黄金（guard_bad != 0）"; echo "RESULT: FAIL"; exit 1
fi
n_bypass="$(grep -oE 'bypass_ok=[0-9]+' "$work/g2.out" | head -1 | cut -d= -f2)"
echo "   正对照 OK（halo 27/27 逐字节；conv1x1 全量；旁路族 $n_bypass 项；整层参考==黄金）"

# ---------------- 2) 负对照：无 halo / 奇数偏移 / 错网格 必须发火 ----------------
if ! grep -qE 'neg_nofire=0( |$)' "$work/g2.out"; then
  echo "NEGCTL-FAIL: 有负对照没发火（接缝 / 奇数偏移 / 错网格 未变值）⇒ 判据无牙"
  echo "RESULT: FAIL"
  exit 2
fi
echo "   负对照 OK（27 halo 项『无 halo ⇒ 接缝』全发火 + maxpool 奇数偏移 + add 错网格 全发火）"

# ---------------- 4) 发火证据（红）：注入故障，闸门必须变红 ----------------
echo "---- [4a] 发火证据：--inject2d tile-drop（漏一趟）⇒ 正对照必须红（退 1）----"
"$PY" "$tool" --gate2d --inject2d tile-drop > "$work/td.out" 2>&1
td_rc=$?
pm="$(grep -oE 'positive_mismatch=[0-9]+' "$work/td.out" | head -1 | cut -d= -f2)"
echo "    rc=$td_rc positive_mismatch=${pm:-?}（期望 rc=1、>0）"
if [ "$td_rc" -ne 1 ] || [ -z "${pm:-}" ] || [ "$pm" -le 0 ]; then
  echo "NEGCTL-FAIL: tile-drop 注入没把正对照打红（判据无分辨度 ⇒ 橡皮章）"
  echo "RESULT: FAIL"
  exit 2
fi

echo "---- [4b] 发火证据：--inject2d halo-nofire（无 halo 负对照失效）⇒ 必须红（退 2）----"
"$PY" "$tool" --gate2d --inject2d halo-nofire > "$work/hn.out" 2>&1
hn_rc=$?
nf="$(grep -oE 'neg_nofire=[0-9]+' "$work/hn.out" | head -1 | cut -d= -f2)"
echo "    rc=$hn_rc neg_nofire=${nf:-?}（期望 rc=2、>0）"
if [ "$hn_rc" -ne 2 ] || [ -z "${nf:-}" ] || [ "$nf" -le 0 ]; then
  echo "NEGCTL-FAIL: halo-nofire 注入没让负对照判据变红（无牙）"
  echo "RESULT: FAIL"
  exit 2
fi

echo "---- [4c] 发火证据：--inject2d misalign-nofire（奇数偏移/错网格失效）⇒ 必须红（退 2）----"
"$PY" "$tool" --gate2d --inject2d misalign-nofire > "$work/mn.out" 2>&1
mn_rc=$?
nf2="$(grep -oE 'neg_nofire=[0-9]+' "$work/mn.out" | head -1 | cut -d= -f2)"
echo "    rc=$mn_rc neg_nofire=${nf2:-?}（期望 rc=2、>0）"
if [ "$mn_rc" -ne 2 ] || [ -z "${nf2:-}" ] || [ "$nf2" -le 0 ]; then
  echo "NEGCTL-FAIL: misalign-nofire 注入没让负对照判据变红（无牙）"
  echo "RESULT: FAIL"
  exit 2
fi

# ---------------- 判决 ----------------
traffic="$(grep -E '^TRAFFIC2D ' "$work/g2.out" | head -1)"
echo "=========================================================================="
echo "T0：2-D tiling（64×32）+ halo == 整层（离线，零 RTL）："
echo "  小张量自检 = OK（conv3x3/dw/stride2/maxpool/resize/add 正对照 + 三条负对照发火 + int32 恒等式）"
echo "  正对照     = OK（真表 27 halo 项 + conv1x1 全量 + 旁路族 $n_bypass 项；tile(+halo) == 整层，MISMATCH=0）"
echo "  负对照     = OK（无 halo ⇒ 接缝全发火且定位到 tile 边；maxpool 奇数偏移 + add 错网格 全发火）"
echo "  发火证据   = OK（tile-drop ⇒ 退 1；halo-nofire / misalign-nofire ⇒ 退 2）"
echo "  流量       = ${traffic:-（未产出）}"
echo "RESULT: PASS"
exit 0
