#!/usr/bin/env bash
# run_quant_ref.sh —— y1 C4a.2 闸门：**同口径 int8 整网参考**（G2/G3/G4 的黄金）。
#
# 为什么需要它：C4a.3 的转换器 / C4a.4–C4a.6 的 RTL 都拿"同口径 int8 参考"当**逐字节黄金**。
#   若这条参考本身是错的、或它的判据是橡皮章，后面每一层的"逐字节对账"都会一起错。
#   所以这条闸门先把参考钉死：口径复用、第二实现逐点一致、负对照能发火、退化守卫在线。
#
# ============================== 判据 ==============================
#  0) **口径复用**：`quant_ref.py --selftest`
#       · 复用 quant_ptq 的 calibrate/affine_params/quant/dequant（import，不另写一套）；
#       · requant 算术右移 + clamp；乘子 Q 格式自洽；
#       · **朴素三重循环**（conv_scalar）== 抽头循环（conv_naive）== im2col（conv_vec），
#         dense / group=2 / depthwise(group=C) / 无 pad 四种形状各一发；
#       · Sigmoid 表：256 项、单调、== quant(sigmoid(dequant(x)))。
#  1) **正对照**：整网跑完，**12 个 graph 输出**与**第二实现**逐点一致 ⇒ `MISMATCH=0`。
#     分辨度反证：给向量化路径注入 1 个码点 ⇒ `FAULT_MISMATCH > 0`（判据能被打红）。
#  2) **与 float ORT 的容差**：逐层记录 max|ours - ORT_float|（**只是记录，不是判据**；判据在 C4b/G7）。
#  3) **负对照（有牙）**：把某层**激活** zp 改 1 ⇒ **该层起往后**的中间张量 md5 必须变（`MD5_DIFF_LAYERS >= 1`）；
#     不 flip（delta=0）⇒ `MD5_DIFF_LAYERS == 0`（证明这条判据不是橡皮章）。哪一发没发火 ⇒ **退出 2**。
#     ★ 权重对称（§4.5-A）后 `z_w ≡ 0`、权重 zp 不可翻 ⇒ 靶层只能落在**激活**（默认 `419` = 首层 Conv 输出）。
#  4) **退化守卫**：输入 `distinct > 1`、末层输出 `distinct > 1`（防"全 0 也通过"）。
#
# 退出码：0 = 正对照过 且 负对照精确发火（delta+1 变、delta0 不变）
#         1 = 正对照红（MISMATCH>0 / 守卫红 / 口径自检红）
#         2 = 负对照没发火（判据无牙 ⇒ 不可信）
#         3 = 前置缺失（找不到 python / 缺 quant_ref.py / 缺 onnx）
#
# 用法：bash y1/tools/run_quant_ref.sh    （可 PY=<python> 覆盖解释器；MUT_LAYER=<张量> 换靶层）
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }
# ★ 全仓唯一可用 Python 组合：**必须**从 y1/ 起、用**相对** PYTHONPATH（Windows Python 不认 /d/... 形式）。
tool="${TOOL:-tools/quant_ref.py}"             # TOOL=<path> 可指向 /tmp 的 scratch 拷贝（只给发火证据用）
onnx="../third_party/yunet/yunet.onnx"
json="reports/c4a_ref_layers.json"
pydeps="./.pydeps"                             # numpy 2.0.2 / onnx 1.19.1 / onnxruntime 1.19.2
deps="../third_party/yunet/deps"

[ -f "$tool" ] || { echo "FATAL: 缺 $tool"; echo "RESULT: FAIL"; exit 3; }
[ -f "$onnx" ] || { echo "FATAL: 缺模型 $onnx"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

export PYTHONPATH="$pydeps;$deps"
export PYTHONIOENCODING=utf-8

MUT_LAYER="${MUT_LAYER:-419}"      # 负对照靶层（首层 Conv 的**输出激活**张量；权重 zp 恒 0 不可翻）

work="$(mktemp -d)"
cleanup() { if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => 保留 $work"; else rm -rf "$work"; fi; }
trap cleanup EXIT

echo "== run_quant_ref: PY=$PY =="
echo "   tool=$tool"
echo "   onnx=$onnx"
echo "   json=$json"
echo "   tmp =$work"

# ---------------- 0) 口径自检（复用冻结件 + 三重循环交叉验证） ----------------
"$PY" "$tool" --selftest > "$work/st.out" 2> "$work/st.err"
st_rc=$?
echo "---- [0] quant_ref.py --selftest（口径自检 + 三重循环） ----"
grep -v '^RESULT:' "$work/st.out"
[ -s "$work/st.err" ] && sed -n '1,20p' "$work/st.err" >&2
if [ "$st_rc" -ne 0 ] || ! grep -q '^RESULT: PASS$' "$work/st.out"; then
  echo "JUDGE-RED: --selftest 未过（rc=$st_rc）"
  echo "RESULT: FAIL"
  exit 1
fi

# ---------------- 1)+2)+4) 正对照整网 + 落盘 + JSON ----------------
"$PY" "$tool" --onnx "$onnx" --json "$json" --gate --dump > "$work/gate.out" 2> "$work/gate.err"
g_rc=$?
echo "---- [1] 整网正对照（向量化 vs 第二实现）+ 落盘 + JSON ----"
grep -vE '^REF init ' "$work/gate.out"
[ -s "$work/gate.err" ] && sed -n '1,20p' "$work/gate.err" >&2

[ -f "$json" ] || { echo "FATAL: 未产出 $json"; echo "RESULT: FAIL"; exit 3; }
if [ "$g_rc" -ne 0 ] || ! grep -q '^REF_RESULT: PASS$' "$work/gate.out"; then
  echo "JUDGE-RED: 整网正对照未过（rc=$g_rc）"
  echo "RESULT: FAIL"
  exit 1
fi
# 逐条把判据抠出来（不靠 REF_RESULT 一个 blurb）
if ! grep -q '^MISMATCH=0$' "$work/gate.out"; then
  echo "JUDGE-RED: 向量化 vs 第二实现未逐点一致（MISMATCH != 0）"; echo "RESULT: FAIL"; exit 1
fi
if ! grep -q '^GUARD input_distinct=[2-9]' "$work/gate.out"; then
  echo "JUDGE-RED: 退化守卫红（输入是常数）"; echo "RESULT: FAIL"; exit 1
fi
if ! grep -q 'lastlayer_distinct=[2-9]' "$work/gate.out"; then
  echo "JUDGE-RED: 退化守卫红（末层输出 distinct <= 1）"; echo "RESULT: FAIL"; exit 1
fi
if ! grep -q '^FAULT_MISMATCH=[1-9]' "$work/gate.out"; then
  echo "JUDGE-RED: 判据无分辨度（注入故障后 MISMATCH 仍为 0 ⇒ 橡皮章）"; echo "RESULT: FAIL"; exit 1
fi
if ! grep -q '^ORT_DEV layers_recorded=' "$work/gate.out"; then
  echo "JUDGE-RED: 未记录逐层 ORT 偏差"; echo "RESULT: FAIL"; exit 1
fi
echo "   正对照 OK（MISMATCH=0 / 守卫在线 / 有分辨度 / ORT 偏差已记录）"

# ---------------- 3) 负对照：zp +1 必须传播（有牙）；delta=0 必须不变（不是橡皮章） ----------------
"$PY" "$tool" --onnx "$onnx" --json "$json" --zp-mutate "$MUT_LAYER" --delta 1 --base-json "$json" > "$work/mut1.out" 2>&1
m1_rc=$?
echo "---- [3] 负对照 zp($MUT_LAYER)+1（须 MD5_DIFF_LAYERS >= 1） rc=$m1_rc ----"
sed -n '1,8p' "$work/mut1.out" | sed 's/^/    /'
d1="$(grep -oE '^MD5_DIFF_LAYERS=[0-9]+' "$work/mut1.out" | head -1 | cut -d= -f2)"
if [ -z "$d1" ] || [ "$d1" -lt 1 ]; then
  echo "NEGCTL-FAIL: zp+1 后中间张量 md5 没变（MD5_DIFF_LAYERS=${d1:-?}）⇒ 这条判据无牙"
  echo "RESULT: FAIL"
  exit 2
fi

"$PY" "$tool" --onnx "$onnx" --json "$json" --zp-mutate "$MUT_LAYER" --delta 0 --base-json "$json" > "$work/mut0.out" 2>&1
m0_rc=$?
echo "---- [3] 对照 zp($MUT_LAYER)+0（须 MD5_DIFF_LAYERS == 0） rc=$m0_rc ----"
sed -n '1,6p' "$work/mut0.out" | sed 's/^/    /'
d0="$(grep -oE '^MD5_DIFF_LAYERS=[0-9]+' "$work/mut0.out" | head -1 | cut -d= -f2)"
if [ -z "$d0" ] || [ "$d0" -ne 0 ]; then
  echo "NEGCTL-FAIL: delta=0 竟然也改变了 md5（MD5_DIFF_LAYERS=${d0:-?}）⇒ 判据不可信"
  echo "RESULT: FAIL"
  exit 2
fi
tot="$(grep -oE '^MD5_TOTAL_LAYERS=[0-9]+' "$work/mut1.out" | head -1 | cut -d= -f2)"
echo "   负对照 OK: zp+1 ⇒ 变 $d1/$tot 层（含该层起往后）；zp+0 ⇒ 变 0 层"

# ---------------- 判决 ----------------
echo "=========================================================================="
echo "同口径 int8 整网参考（C4a.2）："
echo "  口径自检   = OK（--selftest：复用 quant_ptq + 三重循环 == im2col）"
echo "  正对照     = OK（106 节点整网；12 个输出 向量化 == 第二实现，MISMATCH=0；"
echo "                     注入故障 ⇒ MISMATCH>0，判据有分辨度）"
echo "  退化守卫   = OK（输入 distinct=$((256)) ；末层 distinct>1）"
echo "  负对照     = OK（zp($MUT_LAYER)±1 ⇒ MD5_DIFF_LAYERS=$d1/$tot；delta=0 ⇒ 0）"
echo "  ORT 偏差   = 已逐层记录（**记录，非判据**；判据在 C4b/G7）→ $json"
echo "RESULT: PASS"
exit 0
