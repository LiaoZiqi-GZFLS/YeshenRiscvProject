#!/usr/bin/env bash
# run_read_account_ab.sh —— Y1-NPU **B1-T0**（spec `2026-10-20-y1-npu-b-input-reuse-design.md` §1、
#   plan `2026-10-20-y1-npu-b1-input-reuse.md` B1-T0）的闸门：
#   **DDR 输入读账**（`tools/read_account.py`）的**正对照 + 负对照**，并把结论钉在**独立复算**上。
#
# 为什么需要它：B1（宽层输入 tile 跨 co-block 复用）的全部收益都写在"当前读 = nominal × nCo、
#   复用后 = nominal"这一条账上。账若算错（例如把 MAC 表里第二张 `issued Top-12` 排行表也当成
#   单元扫进来 —— 列序不同 ⇒ 12 个单元被重复计入），后面的 RTL/上板收益就无从对账。故先钉账。
#
# 判据（全部在**本次运行**里现算，闸门自己不硬抄几何）：
#   1) **正对照**：`read_account.py`（默认档）exit 0，且三条交叉 CHECK 全 OK
#      （MAC 表几何 == wgt_index.own、desc.bin 译码 == wgt_index.table_geom、desc TYPE 码一致）。
#   2) **独立复算**：闸门用 awk **自己**从 `reports/npu_v2_mac_table.txt` 的**第一张表**
#      （表头 → `MAC_TOTAL=` 之间）重算 Σnominal 与 Σ(nominal·ceil(C_out/8))，必须与工具现印的
#      `TOTAL_NOMINAL_BYTES` / `TOTAL_CURRENT_BYTES` **逐字节相等**；单元数必须 == 53。
#   3) **数值区间**（spec 的验收带，按 MiB）：
#      current ∈ [65,69] MiB（≈67±2）、nominal ∈ [14,15] MiB、amplification ∈ [4.5,4.7]。
#      ★ 精确值同时钉死：nominal = 15,238,400 B、current = 68,647,200 B（表一变 ⇒ 响亮红）。
#   4) **负对照（必须真发火）**：`--force-nco1` 把 nCo 强制成 1 ⇒
#        · 该次 `TOTAL_CURRENT_BYTES` **必须 == 正对照的 `TOTAL_NOMINAL_BYTES`**（塌回 nominal）；
#        · **必须 != 正对照的 `TOTAL_CURRENT_BYTES`**（否则说明工具根本没理这个开关 ⇒ exit 2）；
#        · `AMPLIFICATION` 必须 == 1.000000；两次的 `TOTAL_NOMINAL_BYTES` 必须相同（只动 nCo）。
#   5) **口径防回归**：工具打印的 `NAIVE_RAW_SCAN_*`（整文件行扫 65 行，复现 B1-T0 之前的快速
#      模型 15,021 KiB / 67.17 MiB / 4.579×）必须与正对照不同 ⇒ 若哪天有人把整文件扫当默认，
#      这里和判据 3 会同时红。
#
# 退出码：
#   0 = 正对照 + 独立复算 + 区间 + 负对照全过
#   1 = 正对照/独立复算/区间不符（账不可信）
#   2 = 负对照没发火（工具对 --force-nco1 无反应 ⇒ 闸门自身是橡皮图章）
#   3 = 环境错误（找不到 python / 输入文件缺失）
#
# 用法：bash tools/run_read_account_ab.sh        （在 y1/ 下；PY=… 可覆盖解释器）
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

tool="tools/read_account.py"
table="reports/npu_v2_mac_table.txt"
widx="gen/wgt_index.json"
desc="gen/desc.bin"

echo "== run_read_account_ab: B1-T0 DDR 输入读账（正对照 + 独立复算 + 负对照）=="
echo "   py=$PY  tool=$tool  table=$table"
for f in "$tool" "$table" "$widx" "$desc"; do
  [ -f "$f" ] || { echo "FATAL: 缺文件 $f"; echo "RESULT: FAIL"; exit 3; }
done

TMP="$(mktemp -d)" || { echo "FATAL: mktemp 失败"; echo "RESULT: FAIL"; exit 3; }
trap 'rm -rf "$TMP"' EXIT

FAILN=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; FAILN=$((FAILN + 1)); }

# ---------------------------------------------------------------- 正对照（默认档）
echo
echo "---- 正对照：read_account.py（默认 nCo=ceil(C_out/8)）----"
"$PY" "$tool" >"$TMP/pos.txt" 2>&1
POS_RC=$?
sed -e 's/^/   /' "$TMP/pos.txt"
echo "   POS_RC=$POS_RC"
[ "$POS_RC" -eq 0 ] && pass "正对照 exit 0（三条交叉 CHECK 全 OK）" \
                   || fail "正对照 exit != 0（见上）"

val() { awk -F= -v k="$1" '$1==k {print $2; exit}' "$2"; }
POS_UNITS="$(val TOTAL_UNITS "$TMP/pos.txt")"
POS_NOM="$(val TOTAL_NOMINAL_BYTES "$TMP/pos.txt")"
POS_CUR="$(val TOTAL_CURRENT_BYTES "$TMP/pos.txt")"
POS_AMP="$(val AMPLIFICATION "$TMP/pos.txt")"
POS_CUR_MIB="$(val TOTAL_CURRENT_MIB "$TMP/pos.txt")"
POS_NOM_MIB="$(val TOTAL_NOMINAL_MIB "$TMP/pos.txt")"
NAIVE_UNITS="$(val NAIVE_RAW_SCAN_UNITS "$TMP/pos.txt")"
NAIVE_CUR="$(val NAIVE_RAW_SCAN_CURRENT_BYTES "$TMP/pos.txt")"

[ "$POS_UNITS" = "53" ] && pass "单元数 = 53（conv1x1/conv3x3/depthwise）" \
                        || fail "单元数 = ${POS_UNITS:-<空>}，应为 53"

# ------------------------------------------------------- 独立复算（awk，只读第一张表）
read -r AWK_N AWK_NOM AWK_CUR <<EOF
$(awk '
  /^idx[ \t]+name[ \t]+type/ { if (!seen) { seen = 1; intab = 1 } next }
  /^MAC_TOTAL=/             { intab = 0 }
  intab == 1 && NF >= 9 && ($3 == "conv1x1" || $3 == "conv3x3" || $3 == "depthwise") {
    cin = $5 + 0; cout = $6 + 0; h = $8 + 0; w = $9 + 0
    nco = int((cout + 7) / 8)
    n++; nom += cin * h * w; cur += cin * h * w * nco
  }
  END { printf "%d %d %d\n", n, nom, cur }
' "$table")
EOF
echo
echo "---- 独立复算（awk 现扫 $table 第一张表）----"
echo "   AWK_UNITS=$AWK_N  AWK_NOMINAL=$AWK_NOM  AWK_CURRENT=$AWK_CUR"
[ "$AWK_N" = "$POS_UNITS" ] && pass "单元数 awk == tool（$AWK_N）" \
                            || fail "单元数 awk=$AWK_N != tool=$POS_UNITS"
[ "$AWK_NOM" = "$POS_NOM" ] && pass "Σnominal awk == tool（$AWK_NOM B）" \
                            || fail "Σnominal awk=$AWK_NOM != tool=$POS_NOM"
[ "$AWK_CUR" = "$POS_CUR" ] && pass "Σcurrent awk == tool（$AWK_CUR B）" \
                            || fail "Σcurrent awk=$AWK_CUR != tool=$POS_CUR"

# ------------------------------------------------------------------ 精确值 + 验收带
echo
echo "---- 精确值 + 验收带（spec §1 的 67±2 MB / 4.5–4.7×）----"
[ "$POS_NOM" = "15238400" ] && pass "nominal = 15,238,400 B（14.5325 MiB）" \
                            || fail "nominal = $POS_NOM B，期望 15,238,400"
[ "$POS_CUR" = "68647200" ] && pass "current = 68,647,200 B（65.4671 MiB）" \
                            || fail "current = $POS_CUR B，期望 68,647,200"

awk -v v="$POS_CUR_MIB" 'BEGIN { exit !(v + 0 >= 65.0 && v + 0 <= 69.0) }' \
  && pass "current = $POS_CUR_MIB MiB ∈ [65,69]（67±2）" \
  || fail "current = $POS_CUR_MIB MiB 越出 [65,69]（67±2）"
awk -v v="$POS_NOM_MIB" 'BEGIN { exit !(v + 0 >= 14.0 && v + 0 <= 15.0) }' \
  && pass "nominal/reuse = $POS_NOM_MIB MiB ∈ [14,15]" \
  || fail "nominal = $POS_NOM_MIB MiB 越出 [14,15]"
awk -v v="$POS_AMP" 'BEGIN { exit !(v + 0 >= 4.5 && v + 0 <= 4.7) }' \
  && pass "amplification = $POS_AMP ∈ [4.5,4.7]" \
  || fail "amplification = $POS_AMP 越出 [4.5,4.7]"

[ -n "$NAIVE_CUR" ] && [ "$NAIVE_CUR" != "$POS_CUR" ] \
  && pass "旧口径（整文件 65 行扫）$NAIVE_CUR B 已与正对照区分（$NAIVE_UNITS 行）" \
  || fail "旧口径与正对照相同或缺失（NAIVE_CUR=${NAIVE_CUR:-<空>}）"

# ------------------------------------------------------------------------- 负对照
echo
echo "---- 负对照：--force-nco1（nCo 强制 1 ⇒ 必须塌回 nominal，且必须与正对照不同）----"
"$PY" "$tool" --force-nco1 >"$TMP/neg.txt" 2>&1
NEG_RC=$?
grep -E '^(  mode=|TOTAL_(UNITS|NOMINAL_BYTES|CURRENT_BYTES|CURRENT_MIB)|AMPLIFICATION|RESULT:)' "$TMP/neg.txt"
echo "   NEG_RC=$NEG_RC"
NEG_UNITS="$(val TOTAL_UNITS "$TMP/neg.txt")"
NEG_NOM="$(val TOTAL_NOMINAL_BYTES "$TMP/neg.txt")"
NEG_CUR="$(val TOTAL_CURRENT_BYTES "$TMP/neg.txt")"
NEG_AMP="$(val AMPLIFICATION "$TMP/neg.txt")"

[ "$NEG_RC" -eq 0 ] && pass "负对照 exit 0" || fail "负对照 exit != 0"
[ "$NEG_CUR" != "$POS_CUR" ] \
  && pass "负对照总数 $NEG_CUR != 正对照 $POS_CUR（开关真的生效）" \
  || fail "负对照总数 == 正对照（--force-nco1 无反应 ⇒ 橡皮图章）"
[ "$NEG_CUR" = "$POS_NOM" ] \
  && pass "负对照 current == 正对照 nominal（$NEG_CUR B；nCo=1 ⇒ 只读一次）" \
  || fail "负对照 current=$NEG_CUR != 正对照 nominal=$POS_NOM"
[ "$NEG_NOM" = "$POS_NOM" ] \
  && pass "两次 nominal 相同（只动 nCo，不动几何）" \
  || fail "负对照 nominal=$NEG_NOM != 正对照 nominal=$POS_NOM"
[ "$NEG_AMP" = "1.000000" ] \
  && pass "负对照 amplification = 1.000000" \
  || fail "负对照 amplification = $NEG_AMP，应为 1.000000"
[ "$NEG_UNITS" = "$POS_UNITS" ] \
  && pass "两次单元数相同（$NEG_UNITS）" \
  || fail "负对照单元数=$NEG_UNITS != 正对照=$POS_UNITS"

# --------------------------------------------------------------------------- 结论
echo
echo "---- 结论 ----"
echo "   nominal/reuse = $POS_NOM B = $POS_NOM_MIB MiB"
echo "   current       = $POS_CUR B = $POS_CUR_MIB MiB"
echo "   amplification = $POS_AMP x"
echo "   B1 目标       = $POS_CUR B - $POS_NOM B = $((POS_CUR - POS_NOM)) B 的 DDR 输入读将被消掉"
echo "   top-3 by current_read:"
awk '/^idx  name/ { d = 1; next } d == 1 && NF >= 13 { printf "     %-9s %-9s C_in=%-3s C_out=%-3s nCi=%s nCo=%s  current=%s\n", $2, $3, $4, $5, $8, $9, $12; n++; if (n == 3) exit }' "$TMP/pos.txt"

if [ "$FAILN" -eq 0 ]; then
  echo "RESULT: PASS"
  exit 0
fi
if [ "$NEG_CUR" = "$POS_CUR" ] || [ "$NEG_CUR" != "$POS_NOM" ] || [ "$NEG_AMP" != "1.000000" ]; then
  echo "RESULT: FAIL (negative control did not fire)"
  echo "FAIL_COUNT=$FAILN"
  exit 2
fi
echo "RESULT: FAIL (positive control / recompute / range)"
echo "FAIL_COUNT=$FAILN"
exit 1
