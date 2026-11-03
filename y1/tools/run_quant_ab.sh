#!/usr/bin/env bash
# run_quant_ab.sh —— y1 C4a.1 闸门：冻结 affine 量化口径 + 自研 PTQ 工具的 `--selftest` 四条判据。
#
# 为什么需要它：C4a 的整条链（同口径参考 quant_ref / 转换器 y1_convert / 权重 blob）都建在
#   本工具冻结的 `calibrate/affine_params/quant/dequant` 之上。若这口径本身是错的（或它的自检是
#   橡皮章），后面每一层的"逐字节对账"都会一起错。所以这条闸门**先**把量化口径钉死。
#
# ============================== 判据 ==============================
#  1) **正对照**：`quant_ptq.py --selftest` 必须 `RESULT: PASS` 且退出 0。六条：
#       roundtrip_maxerr <= scale/2（对**数学上界**）
#       monotone=1（对**升序**输入断言 q 不减）
#       clamp=1（与**外部常量** 127/-128 比，不回绕）
#       scale_changed=1（scale 改 1 bit ⇒ dequant 按**解析预测**改变）
#       zero_repr=1（全正张量不得退化：zp 在界内、码点 >= 32、err <= scale/2）
#       percentile_ok=1（`--percentile p` 须 lo<=hi 且真剪尾，p=99 与 p=1 都对）
#  2) **负对照（每一条 check 各来一发，证明它有牙）**：把 `quant_ptq.py` **拷到 /tmp scratch**
#     （**绝不改仓内文件**），用 `--inject <fault>` 在运行期猴补丁打断该 check 的**唯一**来源，
#     逐个断言：**对应 check 被精确打红**（出现 `SELFTEST_PTQ FAIL <check>`）且整体 `RESULT` 非 PASS。
#       floor    -> roundtrip      （quant 用 floor 代替 round ⇒ 误差逼近 1·scale）
#       noclip   -> clamp          （quant 去掉 clamp ⇒ int8 回绕）
#       negscale -> monotone       （scale 取负 ⇒ x 增 q 减）
#       noscale  -> scale_changed  （dequant 忽略 scale ⇒ 改 scale 不再变值 = 橡皮章）
#       nozero   -> zero_repr      （affine_params 去掉零值纳入 ⇒ zp 被 clamp、码点塌缩）
#       badpct   -> percentile_ok  （calibrate 取分位序写反 ⇒ p>50 时 lo>hi）
#     哪一发"没发火"（注入后竟然还 PASS，或没精确命中对应 check）⇒ **退出 2**。
#
# 退出码：0 = 正对照过 且 六发负对照全部精确发火
#         1 = 正对照红（口径/自检不符）
#         2 = 负对照没发火（判据无牙 ⇒ 不可信）
#         3 = 前置缺失（找不到 python / 缺 quant_ptq.py）
#
# 用法：bash y1/tools/run_quant_ab.sh    （可 PY=<python> 覆盖解释器）
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/quant_ptq.py"
deps="$here/../../third_party/yunet/deps"      # numpy 在 deps 里（全仓唯一可用组合）

[ -f "$tool" ] || { echo "FATAL: 缺 $tool"; echo "RESULT: FAIL"; exit 3; }

# 解释器：默认全仓唯一可用组合；允许 PY=... 覆盖；找不到就退回 PATH 上的 python/python3。
PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

if [ -z "${PYTHONPATH:-}" ]; then export PYTHONPATH="$deps"; else export PYTHONPATH="$deps:$PYTHONPATH"; fi
export PYTHONIOENCODING=utf-8

work="$(mktemp -d)"
cleanup() { if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => 保留 $work"; else rm -rf "$work"; fi; }
trap cleanup EXIT

echo "== run_quant_ab: PY=$PY =="
echo "   tool=$tool"
echo "   tmp =$work"

# ---------------- 1) 正对照：--selftest ----------------
"$PY" "$tool" --selftest > "$work/pos.out" 2> "$work/pos.err"
pos_rc=$?
echo "---- [1] quant_ptq.py --selftest（正对照） ----"
# 只回显 SELFTEST_PTQ 行与诊断；**剔掉 selftest 自己的 RESULT 行**，让全脚本只有一条 RESULT 判决。
grep -v '^RESULT:' "$work/pos.out"
[ -s "$work/pos.err" ] && sed -n '1,20p' "$work/pos.err" >&2
if [ "$pos_rc" -ne 0 ] || ! grep -q '^RESULT: PASS$' "$work/pos.out"; then
  echo "JUDGE-RED: 正对照未过（rc=$pos_rc）"
  echo "RESULT: FAIL"
  exit 1
fi
echo "   正对照 OK（exit=0, RESULT: PASS）"

# ---------------- 2) 负对照：scratch 拷贝 + 故障注入（每条 check 一发） ----------------
mut="$work/quant_ptq_mut.py"       # scratch 拷贝：注入只作用在 /tmp，仓内文件一字不动
cp "$tool" "$mut"
[ -f "$mut" ] || { echo "FATAL: scratch 拷贝失败"; echo "RESULT: FAIL"; exit 3; }

# fault -> 必须被打红的 check 名
faults="floor noclip negscale noscale nozero badpct nosym"
check_of_floor="roundtrip"; check_of_noclip="clamp"; check_of_negscale="monotone"; check_of_noscale="scale_changed"
check_of_nozero="zero_repr"; check_of_badpct="percentile_ok"; check_of_nosym="sym_weight"

neg_bad=0
for f in $faults; do
  eval "chk=\$check_of_$f"
  "$PY" "$mut" --selftest --inject "$f" > "$work/neg_$f.out" 2>&1
  nrc=$?
  echo "---- [2] 负对照 inject=$f（须打红 check=$chk） rc=$nrc ----"
  grep -v '^RESULT:' "$work/neg_$f.out" | sed 's/^/    /'
  if grep -q '^RESULT: PASS$' "$work/neg_$f.out"; then
    echo "NEGCTL-FAIL: inject=$f 注入后仍 PASS ⇒ check[$chk] 无牙（橡皮章）"
    neg_bad=1; continue
  fi
  if ! grep -q "SELFTEST_PTQ FAIL $chk" "$work/neg_$f.out"; then
    echo "NEGCTL-FAIL: inject=$f 没精确命中 check[$chk] ⇒ 这条判据口径对不上该故障"
    neg_bad=1; continue
  fi
  if [ "$nrc" -eq 0 ]; then
    echo "NEGCTL-FAIL: inject=$f 打出 FAIL 诊断但退出码仍是 0 ⇒ 未在回路上"
    neg_bad=1; continue
  fi
  echo "   负对照 OK: inject=$f ⇒ check[$chk] 精确打红（rc=$nrc）"
done

if [ "$neg_bad" -ne 0 ]; then
  echo "NEGCTL-FAIL: 有负对照没发火 ⇒ 判据不可信（退出 2）"
  echo "RESULT: FAIL"
  exit 2
fi

# ---------------- 判决 ----------------
echo "=========================================================================="
echo "量化口径冻结 + PTQ --selftest 七条（roundtrip<=scale/2 / monotone / clamp / scale_changed /"
echo "  zero_repr / percentile_ok / sym_weight）："
echo "  正对照   = OK（--selftest RESULT: PASS，exit 0）"
echo "  负对照   = OK（scratch 拷贝 + 7 发注入：floor->roundtrip, noclip->clamp,"
echo "                negscale->monotone, noscale->scale_changed, nozero->zero_repr,"
echo "                badpct->percentile_ok, nosym->sym_weight，各自精确打红）"
echo "RESULT: PASS"
exit 0
