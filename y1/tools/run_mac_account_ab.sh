#!/usr/bin/env bash
# run_mac_account_ab.sh —— P0/P0b（spec `2026-10-16-y1-npu-v2-single-skeleton-design.md` §5-P0、§4.5/§4.6）的闸门：
#   **逐层 MAC 账**（`tools/mac_account.py`）的**正/负对照**，并把它的**译码**钉在**冻结流量模型**
#   （`tools/ddr_traffic.py` —— 本闸门**调用**它，绝不重实现、绝不改它一个字节）的两个已知数上；
#   ★ P0b 追加：**按类归因（1×1 / dw / dense3x3）**与**反事实（A/B/A+B）**的**正对照 + 能发火的负对照**。
#
# 为什么需要它：本项目带宽侧有账、算力侧从未做过逐层账（旧 344 M-MAC / 18.6 fps 只是示意）。
#   本闸门先把"译码对不对"证死（否则 MAC 表、天花板、五档场景、类账全部不可信），再证"负对照能发火"。
#
# 判据（全部**独立算**；闸门自己不硬抄 MAC 数，预测增量由 bash 从装置/工具打印的几何现算）：
#   0) 前置：三个权威输入在位且**互证**——
#      · `gen/desc.bin` 的 md5 == `gen/wgt_index.json` 内**记录**的 table.md5（= fec587a1…，2176 B / 67 载荷）；
#      · `gen/wgt_blob.bin` 的 md5 == 同一 json 内记录的 blob.md5（★ P0b：反事实 A 的"槽 0"前提就在这个文件里）；
#      · 冻结工具 `tools/ddr_traffic.py` / `tools/bypass_traffic.py` 只读（md5 作为证据打印，不参与判据）。
#   1) **正对照 A（冻结模型两个锚点，由冻结工具现跑）**：
#      `ddr_traffic.py … baseline` ⇒ TOTAL_BYTES == 31,942,400（= 31.94 MB/帧，十进制 2 位）；
#      `ddr_traffic.py … fuse_both` ⇒ TOTAL_BYTES == 12,576,000（= 12.58 MB/帧）。
#      不满足 ⇒ 闸门自己不可信（exit 1）；**绝不放宽这两个数**。
#   2) **正对照 B（本工具的译码 == 冻结模型的账）**：`mac_account.py --selftest` 打印的
#      `DECODED_UNFUSED_EXACT` / `DECODED_FUSED_EXACT` 必须**逐字节等于正对照 A 里现跑出来的**
#      TOTAL_BYTES（不是硬抄常量：两边都在本次运行里现算）；
#      并额外断言"desc 表口径"总数 == 冻结 + 32 B（2 个 C_in=1 折档平面的 align32 补位，
#      逐单元点名，见 --selftest 的 CHECK 行）——这条是**已知差异**的显式对账，不是放宽。
#   3) **正对照 C（账自洽）**：`mac_account.py --selftest` 的 MAC 合计 == 344,224,000
#      （旧 spec 示意数首次拿到逐层表背书）；其余 CHECK 全 PASS（含 23.3×/2.9× 两个实测放大锚点
#      对读模型的标定、1×1=9× 与 dw=8× 的"多花拍数"断言）。
#   3b) **★ P0b 正对照 D（类账 = 可交叉复算）**：闸门**自己**按 UNIT 行（index 4 = type、9/10 = H/W、
#      12 = macs、13 = passes、14 = issued）用 awk 重算三类的 issued/macs，与工具现印的 `CLASS` 行
#      **逐项相等**；且 Σ三类 == Σ全部 == 工具 CF 行的 `ISSUED_BEATS`；且 CF 的 `A_BEATS` ==
#      `Σall − 8·Σ_{1×1}(passes·H·W)`（= 跳拍档的预测式，bash 现算）——两条独立路径都钉住。
#      ★ 切片 A（NPU v2 §4.6-5）**落 RTL** 档：工具新增的自下而上实计账 `IMPL_A_BEATS`（逐单元
#        `Σ taps_eff·passes·H·W`，1×1 类 = 1 拍）必须 == `CF A_BEATS` == 闸门现算式 == **P0b 价签
#        13,920,400**，且 `FPS_COMPUTE_IMPL_A == 50 MHz ÷ IMPL_A_BEATS`（实测 **3.5919** ≈ 价签 3.59）。
#        这就是"切片 A 的 fps 重新签发"的判据（三条独立路径 + 一个硬价签，任何一侧漂移当场红）。
#   4) **负对照①（★ P0b：类抽头数注入必须按预测量发火）**：`--perturb-taps dw:3` ⇒
#      dw 类的 `issued` 必须恰 == `3·Σ_dw(passes·H·W)`（bash 从**未注入**的 UNIT 行现算），
#      总 issued 必须恰 == 其余两类不变 + dw 新值，且**另两类**的 CLASS 行**逐字不变**；
#      不满足 ⇒ 闸门自身不可信（exit 2，橡皮图章）。
#   5) **负对照②（几何扰动必须按预测量发火，P0 原有 + ★ P0b 追加类断言）**：对**中网层** `idx 20`
#      （`Conv_29`，1×1 64→64 @40×40）注入 `C_OUT += 8` ⇒ 总 MACs 必须**恰好**变化：
#          Δ_pred = H · W · ΔC_OUT · (C_in/GROUP) · taps      （几何/类型从**未扰动**的打印行现取）
#      断言 observed Δ == Δ_pred（精确相等，且 Δ_pred≠0），并断言 Δ_pred+1 ≠ observed；
#      ★ P0b 追加：`CLASS 1x1 … issued` 的 Δ 必须恰 == `9·(C_in/8)·H·W`（ΔnCo=1 ⇒ Δpasses=nCi），
#      且 CF 的 `A_BEATS` 的 Δ 必须恰 == `(C_in/8)·H·W`（跳拍档下新增趟只值 1 拍/像素）。
#
# 退出码：
#   0 = 正对照 A/B/C/D 全过 + 两条负对照按预测量发火
#   1 = 正对照不符（冻结两锚点复现失败 / 译码与冻结账对不上 / 自检 FAIL / 输入互证失败 / ★ 类账交叉不符）
#   2 = 负对照**没发火**或 Δ 与预测不等（闸门自身不可信：橡皮图章）
#   3 = 环境错误（找不到 python / 输入文件缺失 / 冻结工具跑不起来）
#
# 用法：bash tools/run_mac_account_ab.sh          （在 y1/ 下；PY=… 可覆盖解释器）
set -uo pipefail

cd "$(cd "$(dirname "$0")/.." && pwd)" || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-}"
if [ -z "$PY" ]; then
  for c in /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe python3 python; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

export PYTHONIOENCODING=utf-8
export PYTHONPATH="./.pydeps;../third_party/yunet/deps"

tool="tools/mac_account.py"
frozen="tools/ddr_traffic.py"
bypass="tools/bypass_traffic.py"
desc="gen/desc.bin"
widx="gen/wgt_index.json"
blob="gen/wgt_blob.bin"
onnx="../third_party/yunet/yunet.onnx"

echo "== run_mac_account_ab: P0/P0b 逐层 MAC 账（译码交叉 + 类账 + 负对照）=="
echo "   py=$PY  tool=$tool  frozen=$frozen"
for f in "$tool" "$frozen" "$bypass" "$desc" "$widx" "$blob" "$onnx"; do
  [ -f "$f" ] || { echo "FATAL: 缺文件 $f"; echo "RESULT: FAIL"; exit 3; }
done

# ---- 前置 0：两个权威输入互证（desc.bin 的 md5 == wgt_index.json 里记录的值）----
NEED_MD5="$($PY - "$widx" <<'EOF'
import io, json, sys
print(json.load(io.open(sys.argv[1], encoding="utf-8"))["table"]["md5"])
EOF
)" || { echo "FATAL: wgt_index.json 读不出 table.md5"; echo "RESULT: FAIL"; exit 3; }
HAVE_MD5="$(md5sum "$desc" | awk '{print $1}')"
# ★ P0b：blob 也互证（反事实 A 的"1×1 非零权重只在槽 0"就是在这个文件里现扫的）
NEED_BLOB_MD5="$($PY - "$widx" <<'EOF'
import io, json, sys
print(json.load(io.open(sys.argv[1], encoding="utf-8"))["blob"]["md5"])
EOF
)" || { echo "FATAL: wgt_index.json 读不出 blob.md5"; echo "RESULT: FAIL"; exit 3; }
HAVE_BLOB_MD5="$(md5sum "$blob" | awk '{print $1}')"
echo "-- 前置：desc.bin md5=$HAVE_MD5（wgt_index.json 记录=$NEED_MD5）"
echo "-- 前置：wgt_blob.bin md5=$HAVE_BLOB_MD5（wgt_index.json 记录=$NEED_BLOB_MD5）"
echo "-- 冻结工具（只读证据）：ddr_traffic.py $(md5sum "$frozen" | awk '{print $1}')  bypass_traffic.py $(md5sum "$bypass" | awk '{print $1}')"
if [ "$HAVE_MD5" != "$NEED_MD5" ]; then
  echo "FAIL: desc.bin 与 wgt_index.json 记录的 md5 不一致（译码输入不可信）"
  echo "RESULT: FAIL"; exit 1
fi
if [ "$HAVE_BLOB_MD5" != "$NEED_BLOB_MD5" ]; then
  echo "FAIL: wgt_blob.bin 与 wgt_index.json 记录的 md5 不一致（反事实 A 的槽 0 前提不可信）"
  echo "RESULT: FAIL"; exit 1
fi

# ================================ 正对照 A：冻结模型两锚点（现跑冻结工具） ================================
echo
echo "-- 正对照 A：调用冻结 tools/ddr_traffic.py（不重实现、不编辑）--"
run_frozen() { $PY "$frozen" "$onnx" "$1" 2>&1; }
BASE_OUT="$(run_frozen baseline)"; RC_A=$?
FUSED_OUT="$(run_frozen fuse_both)"; RC_B=$?
if [ $RC_A -ne 0 ] || [ $RC_B -ne 0 ]; then
  echo "FATAL: 冻结工具跑不动（rc=$RC_A/$RC_B）"; echo "RESULT: FAIL"; exit 3
fi
BASE_B="$(printf '%s\n' "$BASE_OUT" | grep -o 'TOTAL_BYTES=[0-9]*' | head -1 | cut -d= -f2)"
FUSED_B="$(printf '%s\n' "$FUSED_OUT" | grep -o 'TOTAL_BYTES=[0-9]*' | head -1 | cut -d= -f2)"
[ -n "$BASE_B" ] && [ -n "$FUSED_B" ] || { echo "FATAL: 冻结输出没有 TOTAL_BYTES"; echo "RESULT: FAIL"; exit 3; }
# 十进制 MB 保留 2 位（与冻结模型 print_unit_note 的 1e6 口径一致）
BASE_MB="$(awk -v b="$BASE_B" 'BEGIN{printf "%.2f", b/1e6}')"
FUSED_MB="$(awk -v b="$FUSED_B" 'BEGIN{printf "%.2f", b/1e6}')"
echo "   baseline  TOTAL_BYTES=$BASE_B  ⇒ ${BASE_MB} MB/帧（已知数 31.94）"
echo "   fuse_both TOTAL_BYTES=$FUSED_B  ⇒ ${FUSED_MB} MB/帧（已知数 12.58）"
if [ "$BASE_MB" != "31.94" ] || [ "$BASE_B" != "31942400" ]; then
  echo "FAIL: 复现不出 baseline 31.94 MB/帧（31,942,400 B）"; echo "RESULT: FAIL"; exit 1
fi
if [ "$FUSED_MB" != "12.58" ] || [ "$FUSED_B" != "12576000" ]; then
  echo "FAIL: 复现不出 fuse_both 12.58 MB/帧（12,576,000 B）"; echo "RESULT: FAIL"; exit 1
fi

# ================================ 正对照 B/C：本工具译码 + 账自洽（--selftest） ================================
echo
echo "-- 正对照 B：mac_account.py 的译码独立复算冻结两锚点（现算比对）--"
SELF_OUT="$($PY "$tool" --selftest 2>&1)"; RC_SELF=$?
printf '%s\n' "$SELF_OUT" | grep -E '^(CHECK|SELFTEST|TOTAL_MACS|CLASS|CF )' | head -60
if [ $RC_SELF -ne 0 ]; then
  echo "FAIL: mac_account.py --selftest 非 0（rc=$RC_SELF）"; echo "RESULT: FAIL"; exit 1
fi
DEC_UNF="$(printf '%s\n' "$SELF_OUT" | grep -o 'DECODED_UNFUSED_EXACT=[0-9]*' | head -1 | cut -d= -f2)"
DEC_FUS="$(printf '%s\n' "$SELF_OUT" | grep -o 'DECODED_FUSED_EXACT=[0-9]*' | head -1 | cut -d= -f2)"
SELF_VERDICT="$(printf '%s\n' "$SELF_OUT" | grep -o 'SELFTEST [A-Z]*' | tail -1)"
TOT_MACS="$(printf '%s\n' "$SELF_OUT" | grep -o 'TOTAL_MACS=[0-9]*' | head -1 | cut -d= -f2)"
[ -n "$DEC_UNF" ] && [ -n "$DEC_FUS" ] || { echo "FAIL: selftest 缺 DECODED_* 行"; echo "RESULT: FAIL"; exit 1; }
# ★★ A2（2026-10-16，spec §5.0）重锚：真表**宽 run 已拆成 plain** ⇒ 按-flag 译码 == 冻结 baseline
#   （拆融合口径）；冻结 `fuse_both=12,576,000` 仍由**正对照 A 现跑冻结工具**复现（上面那两条不动）。
if [ "$DEC_UNF" != "$BASE_B" ] || [ "$DEC_FUS" != "$BASE_B" ]; then
  echo "FAIL: 译码复算 != 冻结模型现跑值（A2：unfused $DEC_UNF、按-flag $DEC_FUS，都应 == $BASE_B）"
  echo "      ⇒ 输入译码错了：修译码器，不放宽这两个数。"; echo "RESULT: FAIL"; exit 1
fi
echo "   A2：按-flag 译码 == 冻结 baseline（$DEC_FUS == $BASE_B）；fuse_both（$FUSED_B）已由正对照 A 现跑复现"
if [ "$SELF_VERDICT" != "SELFTEST PASS" ]; then
  echo "FAIL: --selftest 未全 PASS（见上面 CHECK 行）"; echo "RESULT: FAIL"; exit 1
fi
# 正对照 C：MAC 合计（旧 spec 的示意数 344,224,000 首次有逐层表背书）
if [ "$TOT_MACS" != "344224000" ]; then
  echo "FAIL: MAC 合计 != 344,224,000（得 $TOT_MACS）"; echo "RESULT: FAIL"; exit 1
fi
echo "   => 译码复算 == 冻结现跑（unfused $DEC_UNF / fused $DEC_FUS）；MAC_TOTAL=$TOT_MACS"

# 附加证据：desc 表口径总数 = 冻结 + 32 B（2 个 C_in=1 折档平面 align32 补位，逐单元点名）
DEC_TAB="$(printf '%s\n' "$SELF_OUT" | grep -o 'DECODED_UNFUSED_TABLE=[0-9]*' | head -1 | cut -d= -f2)"
if [ -n "$DEC_TAB" ]; then
  if [ "$DEC_TAB" != "$((BASE_B + 32))" ]; then
    echo "FAIL: desc 表口径 unfused=$DEC_TAB != 冻结 $BASE_B + 32（已知 align32 补位）"; echo "RESULT: FAIL"; exit 1
  fi
  echo "   证据：desc 表口径 unfused=$DEC_TAB = 冻结 $BASE_B + 32 B（align32 补位，CHECK 行点名 42/54）"
fi

# ================================ ★ P0b 正对照 D：类账（闸门按 UNIT 行独立复算） ================================
echo
echo "-- 正对照 D（P0b）：类账 —— 闸门按 UNIT 行现算 vs 工具 CLASS 行（两条独立路径）--"
# 行格式：UNIT idx name type flags C_in C_out GROUP H W taps macs passes issued
#   ⇒ $4=type、$9=H、$10=W、$12=macs、$13=passes、$14=issued（awk 全部现算，不硬抄）
cls_sum() {  # cls_sum <type> <col>
  printf '%s\n' "$SELF_OUT" | awk -v T="$1" -v C="$2" '$1=="UNIT" && $4==T {s+=$C} END{print s+0}'
}
S_1X1_ISS="$(cls_sum conv1x1 14)"; S_DW_ISS="$(cls_sum depthwise 14)"; S_D3_ISS="$(cls_sum conv3x3 14)"
S_1X1_MAC="$(cls_sum conv1x1 12)"; S_DW_MAC="$(cls_sum depthwise 12)"; S_D3_MAC="$(cls_sum conv3x3 12)"
S_1X1_PHW="$(printf '%s\n' "$SELF_OUT" | awk '$1=="UNIT" && $4=="conv1x1" {s+=$13*$9*$10} END{print s+0}')"
S_ALL_ISS="$(printf '%s\n' "$SELF_OUT" | awk '$1=="UNIT" {s+=$14} END{print s+0}')"
S_NUNITS="$(printf '%s\n' "$SELF_OUT" | awk '$1=="UNIT" {n++} END{print n+0}')"
S_NCONV="$(printf '%s\n' "$SELF_OUT" | awk '$1=="UNIT" && ($4=="conv1x1"||$4=="depthwise"||$4=="conv3x3") {n++} END{print n+0}')"
# 工具印的 CLASS 行（逐类读 issued/macs）
tool_cls() { printf '%s\n' "$1" | awk -v T="$2" -v V="$3" '$1=="CLASS" && $2==T {for(i=3;i<=NF;i++){split($i,a,"="); if(a[1]==V) print a[2]} }'; }
T_1X1_ISS="$(tool_cls "$SELF_OUT" 1x1 issued)"; T_DW_ISS="$(tool_cls "$SELF_OUT" dw issued)"
T_D3_ISS="$(tool_cls "$SELF_OUT" dense3x3 issued)"
T_1X1_MAC="$(tool_cls "$SELF_OUT" 1x1 macs)"; T_DW_MAC="$(tool_cls "$SELF_OUT" dw macs)"
T_D3_MAC="$(tool_cls "$SELF_OUT" dense3x3 macs)"
CF_ABEATS="$(printf '%s\n' "$SELF_OUT" | grep -o 'A_BEATS=[0-9]*' | head -1 | cut -d= -f2)"
CF_ISSUED="$(printf '%s\n' "$SELF_OUT" | grep -o 'ISSUED_BEATS=[0-9]*' | head -1 | cut -d= -f2)"
A_PRED=$(( S_ALL_ISS - 8 * S_1X1_PHW ))     # 跳拍档预测式：Σall − 8·Σ_1x1(passes·H·W)
echo "   闸门现算：1x1 issued=$S_1X1_ISS macs=$S_1X1_MAC | dw issued=$S_DW_ISS macs=$S_DW_MAC | dense3x3 issued=$S_D3_ISS macs=$S_D3_MAC"
echo "   工具 CLASS：1x1 issued=$T_1X1_ISS macs=$T_1X1_MAC | dw issued=$T_DW_ISS macs=$T_DW_MAC | dense3x3 issued=$T_D3_ISS macs=$T_D3_MAC"
echo "   Σ三类 issued=$(( S_1X1_ISS + S_DW_ISS + S_D3_ISS ))  Σ全部 UNIT issued=$S_ALL_ISS  工具 CF ISSUED_BEATS=$CF_ISSUED"
if [ "$S_NCONV" != "53" ] || [ "$S_1X1_ISS" != "$T_1X1_ISS" ] || [ "$S_DW_ISS" != "$T_DW_ISS" ] || [ "$S_D3_ISS" != "$T_D3_ISS" ]; then
  echo "FAIL: 类账 issued 交叉不符（闸门 vs 工具）"; echo "RESULT: FAIL"; exit 1
fi
if [ "$S_1X1_MAC" != "$T_1X1_MAC" ] || [ "$S_DW_MAC" != "$T_DW_MAC" ] || [ "$S_D3_MAC" != "$T_D3_MAC" ]; then
  echo "FAIL: 类账 macs 交叉不符（闸门 vs 工具）"; echo "RESULT: FAIL"; exit 1
fi
if [ "$(( S_1X1_ISS + S_DW_ISS + S_D3_ISS ))" != "$S_ALL_ISS" ] || [ "$S_ALL_ISS" != "$CF_ISSUED" ]; then
  echo "FAIL: 类账拆分 ≠ 总 issued（类账漏项/重复计数）"; echo "RESULT: FAIL"; exit 1
fi
if [ "$CF_ABEATS" != "$A_PRED" ]; then
  echo "FAIL: 反事实 A != 预测式（A=$CF_ABEATS pred=$A_PRED）"; echo "RESULT: FAIL"; exit 1
fi
echo "   => 类账三条独立路径一致：闸门 Σ 分类 = 工具 CLASS 行 = 总 issued=$S_ALL_ISS；A=$CF_ABEATS == Σall − 8·Σ_1x1(P·H·W)"

# ---- ★ 切片 A（NPU v2 §4.6-5）"落 RTL"档：自下而上的实计账（第三条独立路径）----
#   预期：1×1 类每趟每像素 1 拍、其余不变 ⇒ `IMPL_A == Σall − 8·Σ_1x1(P·H·W) == CF A_BEATS`。
IMPL_A="$(printf '%s\n' "$SELF_OUT" | grep -o 'IMPL_A_BEATS=[0-9]*' | head -1 | cut -d= -f2)"
FPS_IA="$(printf '%s\n' "$SELF_OUT" | grep -o 'FPS_COMPUTE_IMPL_A=[0-9.]*' | head -1 | cut -d= -f2)"
FPS_IA_PRED="$($PY -c "print('%.4f' % (50000000.0 / $IMPL_A))")"
echo "   ★ 切片 A 实计：IMPL_A_BEATS=$IMPL_A（预测 $A_PRED = CF A $CF_ABEATS）FPS_COMPUTE_IMPL_A=$FPS_IA（预测 $FPS_IA_PRED @50 MHz）"
if [ "$A_PRED" != "13920400" ]; then
  echo "FAIL: 价签漂移（Σall − 8·Σ_1x1(P·H·W)=$A_PRED != P0b 价签 13,920,400）"; echo "RESULT: FAIL"; exit 1
fi
if [ -z "$IMPL_A" ] || [ "$IMPL_A" != "$A_PRED" ] || [ "$IMPL_A" != "$CF_ABEATS" ]; then
  echo "FAIL: 切片 A 实计账 != 跳拍档预测式（IMPL_A=$IMPL_A pred=$A_PRED CF A=$CF_ABEATS）"; echo "RESULT: FAIL"; exit 1
fi
if [ "$FPS_IA" != "$FPS_IA_PRED" ]; then
  echo "FAIL: FPS_COMPUTE_IMPL_A=$FPS_IA != 50 MHz / $IMPL_A = $FPS_IA_PRED"; echo "RESULT: FAIL"; exit 1
fi

# ================================ ★ P0b 负对照①：类抽头数注入 ⇒ 归属按预测量移动 ================================
echo
echo "-- 负对照①（P0b）：--perturb-taps dw:3 ⇒ dw 类 issued 必须恰 == 3·Σ_dw(passes·H·W) --"
DT_OUT="$($PY "$tool" --perturb-taps dw:3 2>&1)"; RC_DT=$?
[ $RC_DT -eq 0 ] || { echo "FATAL: --perturb-taps 跑不动"; echo "RESULT: FAIL"; exit 3; }
DW3_PRED="$(printf '%s\n' "$SELF_OUT" | awk '$1=="UNIT" && $4=="depthwise" {s+=3*$13*$9*$10} END{print s+0}')"
ALL3_PRED=$(( S_ALL_ISS - S_DW_ISS + DW3_PRED ))
DW3_OBS="$(tool_cls "$DT_OUT" dw issued)"
ALL3_OBS="$(printf '%s\n' "$DT_OUT" | grep -o 'ISSUED_BEATS=[0-9]*' | head -1 | cut -d= -f2)"
O_1X1="$(tool_cls "$DT_OUT" 1x1 issued)"; O_D3="$(tool_cls "$DT_OUT" dense3x3 issued)"
echo "   dw 注入 9→3：pred dw_issued=$DW3_PRED（=3·Σ P·H·W）  observed=$DW3_OBS（未注入=$S_DW_ISS）"
echo "   总 issued：pred=$ALL3_PRED  observed=$ALL3_OBS；其余两类 observed 1x1=$O_1X1 dense3x3=$O_D3"
if [ "$DW3_PRED" -eq 0 ] || [ "$DW3_OBS" != "$DW3_PRED" ]; then
  echo "FAIL: 类抽头注入没有按预测量移动（obs=$DW3_OBS pred=$DW3_PRED）⇒ 类归属不承重"; echo "RESULT: FAIL"; exit 2
fi
if [ "$DW3_OBS" = "$S_DW_ISS" ]; then
  echo "FAIL: 注入了却没动（obs == 未注入值）"; echo "RESULT: FAIL"; exit 2
fi
if [ "$ALL3_OBS" != "$ALL3_PRED" ] || [ "$O_1X1" != "$S_1X1_ISS" ] || [ "$O_D3" != "$S_D3_ISS" ]; then
  echo "FAIL: 注入泄漏到别的类 / 总量不符（总 obs=$ALL3_OBS pred=$ALL3_PRED；1x1=$O_1X1/$S_1X1_ISS；d3=$O_D3/$S_D3_ISS）"
  echo "RESULT: FAIL"; exit 2
fi
echo "   => 发火正确：dw 归属按预测移动（$S_DW_ISS → $DW3_OBS），另两类逐字不变"

# ================================ 负对照②：几何扰动 ⇒ 按**预测量**发火（P0 原有 + P0b 类断言） ================================
echo
echo "-- 负对照②：idx 20（Conv_29，中网 1×1）注入 C_OUT += 8 ⇒ ΔMACs 必须 == 预测 --"
PER_OUT="$($PY "$tool" --perturb 20:C_OUT:8 2>&1)"; RC_P=$?
[ $RC_P -eq 0 ] || { echo "FATAL: --perturb 跑不动"; echo "RESULT: FAIL"; exit 3; }
U0="$(printf '%s\n' "$SELF_OUT" | awk '$1=="UNIT" && $2==20 {print}')"
U1="$(printf '%s\n' "$PER_OUT"  | awk '$1=="UNIT" && $2==20 {print}')"
[ -n "$U0" ] && [ -n "$U1" ] || { echo "FAIL: 拿不到 UNIT 20 行"; echo "RESULT: FAIL"; exit 2; }
# 行格式：UNIT idx name type flags C_in C_out GROUP H W taps macs passes issued
read -r _ _ _ _ _ CI0 CO0 G0 H0 W0 T0 M0 _ _ <<<"$U0"
read -r _ _ _ _ _ CI1 CO1 G1 H1 W1 T1 M1 _ _ <<<"$U1"
PERT_OUT_TOTAL="$(printf '%s\n' "$PER_OUT" | grep -o 'TOTAL_MACS=[0-9]*' | head -1 | cut -d= -f2)"
OBS_DELTA=$(( PERT_OUT_TOTAL - TOT_MACS ))
# 预测增量：完全由**未扰动**打印行现算（bash 独立算，不抄 python 的数）
PRED_DELTA=$(( H0 * W0 * 8 * (CI0 / G0) * T0 ))
echo "   unit20=$U0"
echo "   unit20(perturbed)=$U1"
echo "   observed ΔTOTAL_MACS=$OBS_DELTA   predicted=$PRED_DELTA（= H·W·8·(C_in/G)·taps）"
if [ "$PRED_DELTA" -eq 0 ]; then
  echo "FAIL: 预测增量为 0 ⇒ 负对照设计错了"; echo "RESULT: FAIL"; exit 2
fi
if [ "$OBS_DELTA" -ne "$PRED_DELTA" ]; then
  echo "FAIL: 负对照 Δ 与预测不等（obs=$OBS_DELTA pred=$PRED_DELTA）⇒ 闸门橡皮图章"; echo "RESULT: FAIL"; exit 2
fi
if [ "$OBS_DELTA" -eq "$(( PRED_DELTA + 1 ))" ]; then
  echo "FAIL: 断言不是精确相等（obs == pred+1）"; echo "RESULT: FAIL"; exit 2
fi
# 逐单元交叉：扰动后的单元 MACs - 未扰动单元 MACs == 预测（与总量差分互为两条独立路径）
U20_DELTA=$(( M1 - M0 ))
if [ "$U20_DELTA" -ne "$PRED_DELTA" ]; then
  echo "FAIL: 单元级 Δ（$U20_DELTA）与预测不等 —— 总量差分与单元差分对不上"; echo "RESULT: FAIL"; exit 2
fi
# 扰动必须只动一个单元（它自己）：其余单元的行必须逐字不变
if ! diff <(printf '%s\n' "$SELF_OUT" | awk '$1=="UNIT" && $2!=20') \
          <(printf '%s\n' "$PER_OUT"  | awk '$1=="UNIT" && $2!=20') >/dev/null; then
  echo "FAIL: 扰动泄漏到别的单元（UNIT 行不全同）"; echo "RESULT: FAIL"; exit 2
fi
echo "   => 负对照按预测量发火：Δ = $OBS_DELTA（单元级与总量差分两条路径一致；其余 66 行逐字不变）"

# ★ P0b 追加：类归属必须同步按预测移动（Δpasses = nCi·ΔnCo = (C_in/8)·1）
P_1X1_ISS="$(tool_cls "$PER_OUT" 1x1 issued)"
P_ABEATS="$(printf '%s\n' "$PER_OUT" | grep -o 'A_BEATS=[0-9]*' | head -1 | cut -d= -f2)"
PRED_CLS_DELTA=$(( 9 * (CI0 / 8) * H0 * W0 ))      # Δissued(1x1 类) = 9·nCi·ΔnCo·H·W
PRED_A_DELTA=$(( 1 * (CI0 / 8) * H0 * W0 ))        # ΔA         = 1·nCi·ΔnCo·H·W（跳拍档只值 1 拍）
OBS_CLS_DELTA=$(( P_1X1_ISS - S_1X1_ISS ))
OBS_A_DELTA=$(( P_ABEATS - CF_ABEATS ))
echo "   类级：1x1 issued $S_1X1_ISS → $P_1X1_ISS（Δ=$OBS_CLS_DELTA，pred=$PRED_CLS_DELTA）；A $CF_ABEATS → $P_ABEATS（Δ=$OBS_A_DELTA，pred=$PRED_A_DELTA）"
if [ "$OBS_CLS_DELTA" -ne "$PRED_CLS_DELTA" ] || [ "$OBS_A_DELTA" -ne "$PRED_A_DELTA" ]; then
  echo "FAIL: 几何扰动下类归属/反事实 A 没有按预测量移动 ⇒ 类账与几何脱钩"; echo "RESULT: FAIL"; exit 2
fi
echo "   => 类账随几何扰动按预测量发火（1×1 类 Δ = 9·nCi·ΔnCo·H·W；A 的 Δ = 1·nCi·ΔnCo·H·W）"

# ================================ 场景表（信息性打印；不参与判据） ================================
echo
echo "-- 信息性：五档逐帧流量（判据写在 y1/reports/npu_v2_accounting.md；数字由同一工具生成）--"
$PY "$tool" --scenarios 2>&1 | grep -E '^\(|^SCEN_|^BURSTS32'

echo
echo "RESULT: PASS"
exit 0
