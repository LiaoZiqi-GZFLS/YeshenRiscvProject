#!/usr/bin/env bash
# run_tiling_ab.sh —— y1 C4a.4 闸门：**拆趟（tiling）== 整层** 的 Python 算术等价（G3 离线半边）。
#
# 为什么需要它：C4a.5 的 RTL 要把"宽层拆成 8 通道多趟、跨趟累加"做进硬件。若这条数据流的
#   **算术等价**本身没钉死（或判据是橡皮章），RTL 会照着一张错单子做、且"逐字节对账"一起错。
#   所以这条闸门先把离线等价钉死：形状集合来自**冻结真表**、整层参考**逐字复用** quant_ref、
#   负对照（漏一趟）能发火、退化守卫在线。
#
# ============================== 判据 ==============================
#  0) **小张量自检**：`tools/tiling_ref.py --selftest`
#       · 正对照：随机 (C_in,C_out,GROUP,pads,strides) 8 发，`拆趟 == 整层` 逐字节；
#       · int32 恒等式：整层 acc == Σ 趟 partial（整数恒等）；
#       · 掩码：C_in 非 8 倍时被 SKIP 的输入通道用 z_w 掩掉（不贡献）；
#       · 负对照 a：漏一个 ci 块 ⇒ MISMATCH>0；负对照 b：逐趟 requant ⇒ 与整层不一致。
#  1) **正对照**：`tools/tiling_ref.py --gate`——对**冻结真表里出现过的每一种 `(C_in,C_out,GROUP)`**
#     各取一个真层跑一趟：**拆趟模拟 == 整层参考**（`MISMATCH=0`）；并断言 int32 恒等式、
#     每层的 `M_two_step` 与转换器发布值一致（消费，不另写公式）。
#  2) **负对照（有牙）**：每层**故意漏一趟**（少一个 ci 块）⇒ `DROP_MISMATCH>0`（`NEG_NOFIRE==0`）。
#  3) **退化守卫**：每层输出非常数（`GUARD_BAD==0`）。
#  4) **发火证据（红）**：注入 `perpass`（逐趟 requant）⇒ 判据必须红（`MISMATCH>0`，退出 1）；
#     注入 `drop-nofire`（负对照失效）⇒ 必须红（`NEG_NOFIRE>0`，退出 2）。
#     哪一发**没**发火 ⇒ 本闸门退出 2（判据无牙 ⇒ 不可信）。
#
# 退出码：0 = 全绿；1 = 判据红（MISMATCH>0 / 恒等式破 / 守卫红）；
#         2 = 负对照没发火（判据无牙）；3 = 前置缺失（缺 python / 缺 onnx / 缺冻结件）。
#
# ★★ 2026-10-11 §4.5-A 重锚（**显式**，不是悄悄放宽）：权重改**对称**量化后，黄金 `quant_ref.py`
#    （md5 d1c75dc262cfd46bb6f7c66bf93ac159，commit a77efb3）逐层张量全变 ⇒ 本闸门曾落盘的
#    `gen/c4a_tiling/`（形状输出 .npy + c4a_tiling.json）是**旧口径**缓存，已作废。**本闸门不存
#    硬编码黄金 md5 锚点**：整层参考**逐字复用** `quant_ref.conv_vec`、形状集合从**冻结真表**读出、
#    乘子**消费**转换器 `wgt_index.json` 的 `M_two_step` ⇒ 每次运行**重算**黄金 ⇒ **自动适配**。
#    重锚动作 = 重跑 `--gate --dump` 刷新 `gen/c4a_tiling/`（gitignore，不入库）。判据与负对照
#    **一字未改**（MISMATCH=0 / int32 恒等式 / 负对照 a·b 发火 / 退化守卫 全绿）。本次重锚后的
#    产物指纹记在 commit message（**不**在本文件钉 md5 —— 免得下次黄金再变又留一个死锚点）。
#
# 用法：bash y1/tools/run_tiling_ab.sh   （可 PY=<python> 覆盖解释器）
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }
# ★ 全仓唯一可用 Python 组合：**必须**从 y1/ 起、用**相对** PYTHONPATH（Windows Python 不认 /d/... 形式）。
tool="${TOOL:-tools/tiling_ref.py}"             # TOOL=<path> 可指向 scratch 拷贝
onnx="../third_party/yunet/yunet.onnx"
index="gen/wgt_index.json"
pydeps="./.pydeps"                              # numpy 2.0.2 / onnx 1.19.1 / onnxruntime 1.19.2
deps="../third_party/yunet/deps"

[ -f "$tool" ] || { echo "FATAL: 缺 $tool"; echo "RESULT: FAIL"; exit 3; }
[ -f "$onnx" ] || { echo "FATAL: 缺模型 $onnx"; echo "RESULT: FAIL"; exit 3; }
[ -f "tools/desc_table.py" ] || { echo "FATAL: 缺冻结件 tools/desc_table.py"; echo "RESULT: FAIL"; exit 3; }
[ -f "tools/quant_ref.py" ] || { echo "FATAL: 缺冻结件 tools/quant_ref.py"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

export PYTHONPATH="$pydeps;$deps"
export PYTHONIOENCODING=utf-8

work="$(mktemp -d)"
cleanup() { if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => 保留 $work"; else rm -rf "$work"; fi; }
trap cleanup EXIT

echo "== run_tiling_ab: PY=$PY =="
echo "   tool=$tool"
echo "   onnx=$onnx"
echo "   index=$index"
echo "   tmp =$work"

# ---------------- 0) 小张量自检（正/负对照都能发火 + 恒等式 + 掩码） ----------------
"$PY" "$tool" --selftest > "$work/st.out" 2> "$work/st.err"
st_rc=$?
echo "---- [0] tiling_ref.py --selftest ----"
grep -v '^RESULT:' "$work/st.out" | sed 's/^/    /'
[ -s "$work/st.err" ] && sed -n '1,20p' "$work/st.err" >&2
if [ "$st_rc" -ne 0 ] || ! grep -q '^RESULT: PASS$' "$work/st.out"; then
  echo "JUDGE-RED: --selftest 未过（rc=$st_rc）"
  echo "RESULT: FAIL"
  exit 1
fi

# ---------------- 1)+2)+3) 真表形状集合：正对照 + 负对照 + 退化守卫 ----------------
"$PY" "$tool" --gate --dump > "$work/gate.out" 2> "$work/gate.err"
g_rc=$?
echo "---- [1] 拆趟 == 整层（真表全形状）+ 负对照 + 退化守卫 ----"
grep -vE '^(RESULT|TILING_RESULT|GATE|JSON):' "$work/gate.out" | grep -E '^(SHAPE|SHAPES_TOTAL|MISMATCH=)' | sed 's/^/    /'
[ -s "$work/gate.err" ] && sed -n '1,20p' "$work/gate.err" >&2
[ -f "$work/gate.out" ] || { echo "FATAL: 未产出 gate 输出"; echo "RESULT: FAIL"; exit 3; }

if [ "$g_rc" -ne 0 ] || ! grep -q '^RESULT: PASS$' "$work/gate.out"; then
  echo "JUDGE-RED: 拆趟等价判据未过（rc=$g_rc）"
  tail -5 "$work/gate.out" | sed 's/^/    /'
  echo "RESULT: FAIL"
  exit 1
fi
# 逐条把判据抠出来（不靠一个 blurb）
if ! grep -q '^MISMATCH=0$' "$work/gate.out"; then
  echo "JUDGE-RED: 拆趟模拟 != 整层参考（MISMATCH != 0）"; echo "RESULT: FAIL"; exit 1
fi
if ! grep -qE 'MISMATCH_TOTAL=0( |$)' "$work/gate.out"; then
  echo "JUDGE-RED: 有形状逐字节不一致"; echo "RESULT: FAIL"; exit 1
fi
if ! grep -qE 'IDENT_BAD=0( |$)' "$work/gate.out"; then
  echo "JUDGE-RED: int32 恒等式破（整层 acc != Σ 趟 partial）"; echo "RESULT: FAIL"; exit 1
fi
if ! grep -qE 'GUARD_BAD=0( |$)' "$work/gate.out"; then
  echo "JUDGE-RED: 退化守卫红（某形状输出是常数）"; echo "RESULT: FAIL"; exit 1
fi
if ! grep -qE 'M_MISMATCH=0( |$)' "$work/gate.out"; then
  echo "JUDGE-RED: 有层的 M_two_step 与转换器发布值不一致（乘子未消费）"; echo "RESULT: FAIL"; exit 1
fi
n_shapes="$(grep -oE '^SHAPES_TOTAL=[0-9]+' "$work/gate.out" | head -1 | cut -d= -f2)"
echo "   正对照 OK（形状集合 $n_shapes 种，全 MISMATCH=0 / 恒等式精确 / 守卫在线 / 转换器 M 已消费）"

# ---------------- 2) 负对照：漏一趟必须发火 ----------------
if ! grep -qE 'NEG_NOFIRE=0( |$)' "$work/gate.out"; then
  echo "NEGCTL-FAIL: 有形状上'漏一趟'没有改变输出（负对照没发火）⇒ 这条判据无牙"
  echo "RESULT: FAIL"
  exit 2
fi

# ---------------- 4) 发火证据（红）：注入故障，闸门必须变红 ----------------
echo "---- [4a] 发火证据：--inject perpass（逐趟 requant，错口径）⇒ 判据必须红 ----"
"$PY" "$tool" --gate --inject perpass > "$work/perpass.out" 2>&1
rp_rc=$?
mp="$(grep -oE '^MISMATCH=[0-9]+' "$work/perpass.out" | head -1 | cut -d= -f2)"
echo "    rc=$rp_rc MISMATCH=${mp:-?}（期望 rc=1、MISMATCH>0）"
if [ "$rp_rc" -ne 1 ] || [ -z "${mp:-}" ] || [ "$mp" -le 0 ]; then
  echo "NEGCTL-FAIL: perpass 注入没把正对照打红（判据无分辨度 ⇒ 橡皮章）"
  echo "RESULT: FAIL"
  exit 2
fi

echo "---- [4b] 发火证据：--inject drop-nofire（负对照失效）⇒ 闸门必须红（退出 2） ----"
"$PY" "$tool" --gate --inject drop-nofire > "$work/nofire.out" 2>&1
rf_rc=$?
nf="$(grep -oE ' NEG_NOFIRE=[0-9]+ ' "$work/nofire.out" | head -1 | tr -d ' =' | sed 's/NEG_NOFIRE//')"
echo "    rc=$rf_rc NEG_NOFIRE=${nf:-?}（期望 rc=2、NEG_NOFIRE>0）"
if [ "$rf_rc" -ne 2 ] || [ -z "${nf:-}" ] || [ "$nf" -le 0 ]; then
  echo "NEGCTL-FAIL: drop-nofire 注入没让负对照判据变红（无牙）"
  echo "RESULT: FAIL"
  exit 2
fi

# ---------------- 判决 ----------------
echo "=========================================================================="
echo "拆趟 == 整层（C4a.4，G3 离线半边）："
echo "  小张量自检 = OK（正对照 8 发逐字节；int32 恒等式；掩码；负对照 a/b 都发火）"
echo "  正对照     = OK（真表全形状 $n_shapes 种；拆趟模拟 == 整层参考，MISMATCH=0；"
echo "                     int32 恒等式精确；转换器 M_two_step 已消费）"
echo "  退化守卫   = OK（每层输出 distinct>1）"
echo "  负对照     = OK（每层'漏一趟' ⇒ DROP_MISMATCH>0，NEG_NOFIRE=0）"
echo "  发火证据   = OK（perpass ⇒ MISMATCH>0 退 1；drop-nofire ⇒ NEG_NOFIRE>0 退 2）"
echo "  产物       = gen/c4a_tiling/（形状输出 .npy + c4a_tiling.json，gitignore）"
echo "RESULT: PASS"
exit 0
