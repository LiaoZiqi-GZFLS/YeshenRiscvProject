#!/usr/bin/env bash
# run_preflight_ab.sh —— 整表几何预检闸门（T-S3c.1；★★ A2 2026-10-16 重新锚定）
#
# 被测：`y1/tools/frame_preflight.py`（读真表 `gen/desc.bin`，逐单元走 RTL 在 `go` 那一刻的几何判据；
#       每条判据在工具里都注明了 RTL 行号 —— `rtl/UnitExec.scala` / `rtl/BypassExec.scala`）。
#
# 这个闸门判三件事（缺一不可）
# ----------------------------------------------------------------------------------------------
# [1] **正对照（整表全走一遍）**：真表 67 个单元在 `UNIT` 口径（每个单元各跑一条、`chain_len=1`、
#     编程 = 既有闸门那一档：`XDMA_EN=1` + 权重按层预载）下逐条判，要求 **PREFLIGHT_ERR=0**。
#     ★★ A2（2026-10-16，spec §5.0）前的锚是 `{29}`（`Resize_43` 撞 `tileAliOk` 的真开口项）；
#        A2 之后这个开口项**两条路一起闭**：
#        ① 表侧：宽 run 拆成 plain（`y1_convert.py` 的 de-fuse）⇒ 每个单元走"宽单点"路径；
#        ② 镜像侧：`frame_preflight.py` 与两处**已先行修复且有逐字节闸门**的 RTL 同步 ——
#           T-S3d 缺陷修-①（`UnitExec.scala:2079`：tiled 宽路豁免 `inWOk`）与
#           T-S3e（`BypassExec` per-plane band：`tileAliOk` 的 `inCols%32==0` 前提**已去**，
#           `Resize_43` 40×40 在 `run_bypass_tile_ab.sh` 已逐字节证明可跑）。
#        ⇒ **冻结 ERR 集合 = 空**（`EXPECT_UNIT_ERR_UNITS="none"`）。多出缺口 ⇒ 红。
# [2] **负对照必须发火（两条，外科式：ERR 集合恰好 +1）**：
#     ① `Resize_49`（idx 33）`IMG_H 80 -> 82`（⇒ `IMG_H%4=2` 撞 `tileRzOk`；`inH=41` 奇撞 `blkPhaseOk`；
#        整层路仍被 `outPix>MAXPIX` 挡）★ A2 重锚：旧的 `IMG_W 80->82` 在 T-S3e 之后**已合法**
#        （per-plane band 覆盖，本闸门实测 `ERR=0`）⇒ 换成真正非法的 `IMG_H+2`；
#     ② `MaxPool_5`（idx 3）`C_IN 16 -> 17`（⇒ `cBlkOk` 假）。
# [3] **DISPATCH 口径（真派发）**：忠实派发（`LayerSched` 把融合链塌缩成一次 `go` ⇒ `chain_len` = run 长；
#     编程 = 真帧驱动 `XDMA_EN=1` + DDR blob）下，要求 **DISPATCH_ERR=0**。
#     ★★ A2 前 = `54`（宽层的链无通路：`wideGeomOk`/`wgtLoadOk`/`tilingOkC`/`tilingWideC`
#        都带 `chain_len == 1`）；A2 把宽 run 拆成 plain ⇒ 每个单元 `chain_len=1` ⇒ **全表 0 err**
#        ⇒ **表侧 FRAME-RUNNABLE: YES**（整帧实际可跑性仍需 S3 上板终证）。该数变大 ⇒ 又多了缺口。
#
# 退出码：0 = 全过 / 1 = 正对照或锚不符（判据红）/ 2 = 负对照没发火 / 3 = 前置缺失。
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-}"
if [ -z "$PY" ]; then
  for c in /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe python3 python; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi
tool="tools/frame_preflight.py"
desc="gen/desc.bin"

# ---- 冻结预期（改 RTL / 改表 ⇒ 必须重新锚定并写进报告）----
EXPECT_UNIT_ERR_UNITS="none"        # A2 重锚：{29} → 空（de-fuse 列表 + 镜像与 T-S3d/T-S3e 同步）
EXPECT_DISPATCH_ERR=0               # A2 重锚：54 → 0（宽 run 拆 plain ⇒ chain_len 恒 1）

echo "== run_preflight_ab: 整表几何预检（67 单元逐条走 RTL 的 go 判据；★ A2 重锚）=="
echo "   tool=$tool  desc=$desc  py=${PY:-<none>}"

[ -n "$PY" ]    || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }
[ -f "$tool" ]  || { echo "FATAL: 缺 $tool";          echo "RESULT: FAIL"; exit 3; }
[ -f "$desc" ]  || { echo "FATAL: 缺 $desc（先跑 tools/run_convert_ab.sh 生成真表）"; echo "RESULT: FAIL"; exit 3; }

work="$(mktemp -d)"
cleanup() { [ "${KEEP_TMP:-0}" = "1" ] && echo "KEEP_TMP=1 => $work" || rm -rf "$work"; }
trap cleanup EXIT

run_pf() {   # run_pf <logname> [extra args...]
  local log="$1"; shift
  PYTHONIOENCODING=utf-8 "$PY" "$tool" "$@" > "$work/$log" 2>&1
  echo $?
}

# ---------------------------------------------------------------------------------------------
echo "---- [1] 正对照：真表 67 单元（UNIT 口径）必须零 err（冻结集合 = 空）----"
rc="$(run_pf pos.txt)"
sed -n '1,8p' "$work/pos.txt" | sed 's/^/    /'
grep -E '^(PREFLIGHT_ERR|PREFLIGHT_ERR_UNITS|PREFLIGHT_ERR_DETAIL|DISPATCH_ERR|RESULT)' "$work/pos.txt" | sed 's/^/    /'
n_err="$(sed -n 's/^PREFLIGHT_ERR=\([0-9]*\).*/\1/p' "$work/pos.txt" | head -1)"
units="$(sed -n 's/^PREFLIGHT_ERR_UNITS=//p' "$work/pos.txt" | head -1)"
disp="$(sed -n 's/^DISPATCH_ERR=\([0-9]*\).*/\1/p' "$work/pos.txt" | head -1)"

if [ "$n_err" != "0" ]; then
  echo "JUDGE-RED: PREFLIGHT_ERR=$n_err != 0（A2 后整表必须零 err；多了缺口）"
  echo "            冻结 ERR 集合 = {$EXPECT_UNIT_ERR_UNITS}（= 空；改了就要重新锚定）"
  echo "RESULT: FAIL"; exit 1
fi
if [ "$units" != "$EXPECT_UNIT_ERR_UNITS" ]; then
  echo "JUDGE-RED: ERR 集合 = {$units} != 冻结的 {$EXPECT_UNIT_ERR_UNITS}"
  echo "RESULT: FAIL"; exit 1
fi
echo "    正对照 OK：PREFLIGHT_ERR=0（67/67 单元各有合法通路）"

# ---------------------------------------------------------------------------------------------
echo "---- [2] 确定性：同源连跑两次必须逐字节相同 ----"
rc="$(run_pf pos2.txt)"
if ! diff -q "$work/pos.txt" "$work/pos2.txt" >/dev/null; then
  echo "JUDGE-RED: 两次输出不同（预检不确定）"; diff "$work/pos.txt" "$work/pos2.txt" | head -10
  echo "RESULT: FAIL"; exit 1
fi
echo "    DETERMINISM_2X_OK md5=$(md5sum "$work/pos.txt" | cut -d' ' -f1)"

# ---------------------------------------------------------------------------------------------
echo "---- [3] 负对照①：Resize_49（idx 33）IMG_H 80 -> 82 ⇒ 必须翻成 ERR（外科式 +1）----"
echo "        （★ A2 重锚：旧靶 IMG_W+2 在 T-S3e per-plane band 之后已合法，实测 ERR=0 —— 不再发火）"
rc="$(run_pf neg1.txt --quiet --inject 33,IMG_H,+2)"
grep -E '^(INJECT|PREFLIGHT_ERR|PREFLIGHT_ERR_UNITS|  PREFLIGHT_ERR_DETAIL)' "$work/neg1.txt" | sed 's/^/    /'
u1="$(sed -n 's/^PREFLIGHT_ERR_UNITS=//p' "$work/neg1.txt" | head -1)"
case "$u1" in
  *33*) : ;;
  *) echo "JUDGE-RED: 负对照①没发火（ERR 集合 = {$u1}，未见 33）"; echo "RESULT: FAIL"; exit 2 ;;
esac
[ "$u1" = "33" ] || { echo "JUDGE-RED: 负对照①的 ERR 集合 = {$u1} != {33}（外科式：只该那一个）"; echo "RESULT: FAIL"; exit 2; }
n1="$(sed -n 's/^PREFLIGHT_ERR=\([0-9]*\).*/\1/p' "$work/neg1.txt" | head -1)"
[ "$n1" = "1" ] || { echo "JUDGE-RED: 负对照①的 ERR 数 = $n1 != 1（外科式：只该多一个）"; echo "RESULT: FAIL"; exit 2; }
grep -q 'tileRzOk' "$work/neg1.txt" || { echo "JUDGE-RED: 负对照①的靶不是 tileRzOk（换了个缺口）"; echo "RESULT: FAIL"; exit 2; }
echo "    负对照① 发火：ERR 集合 {} -> {$u1}（外科式：恰好 +33，靶 = tileRzOk/blkPhaseOk）"

# ---------------------------------------------------------------------------------------------
echo "---- [4] 负对照②：MaxPool_5（idx 3）C_IN 16 -> 17 ⇒ 必须翻成 ERR（外科式 +1）----"
rc="$(run_pf neg2.txt --quiet --inject 3,C_IN,+1)"
grep -E '^(INJECT|PREFLIGHT_ERR|PREFLIGHT_ERR_UNITS|  PREFLIGHT_ERR_DETAIL)' "$work/neg2.txt" | sed 's/^/    /'
u2="$(sed -n 's/^PREFLIGHT_ERR_UNITS=//p' "$work/neg2.txt" | head -1)"
case "$u2" in
  *3*) : ;;
  *) echo "JUDGE-RED: 负对照②没发火（ERR 集合 = {$u2}，未见 3）"; echo "RESULT: FAIL"; exit 2 ;;
esac
[ "$u2" = "3" ] || { echo "JUDGE-RED: 负对照②的 ERR 集合 = {$u2} != {3}（外科式：只该那一个）"; echo "RESULT: FAIL"; exit 2; }
n2="$(sed -n 's/^PREFLIGHT_ERR=\([0-9]*\).*/\1/p' "$work/neg2.txt" | head -1)"
[ "$n2" = "1" ] || { echo "JUDGE-RED: 负对照②的 ERR 数 = $n2 != 1（外科式：只该多一个）"; echo "RESULT: FAIL"; exit 2; }
echo "    负对照② 发火：ERR 集合 {} -> {$u2}（外科式：恰好 +3）"

# ---------------------------------------------------------------------------------------------
echo "---- [5] DISPATCH 口径（真派发：XDMA_EN=1/blob=1）的 A2 锚 ----"
echo "    DISPATCH_ERR=$disp（冻结 $EXPECT_DISPATCH_ERR）"
if [ "$disp" != "$EXPECT_DISPATCH_ERR" ]; then
  echo "JUDGE-RED: DISPATCH_ERR=$disp != $EXPECT_DISPATCH_ERR"
  echo "            （变大 ⇒ 又多了缺口；变小已不可能 = 0）"
  grep -E '^  run@' "$work/pos.txt" | head -6 | sed 's/^/    /'
  echo "RESULT: FAIL"; exit 1
fi

echo
echo "== 结论 =="
echo "  PREFLIGHT_ERR=0（UNIT 口径）：67/67 单元各有合法通路（A2 前 = {29} Resize_43）"
echo "  DISPATCH_ERR=0（真派发口径）：宽 run 已拆 plain ⇒ chain_len 恒 1 ⇒ 全表零 err"
echo "  ⇒ 表侧 FRAME-RUNNABLE: YES（真帧实际可跑性仍待 S3 上板终证）"
echo "  闸门本身：正对照（冻结 ERR 集合 = 空）+ 2 条能发火的负对照（外科式）+ 确定性 ⇒ 全部成立"
echo "RESULT: PASS"
exit 0
