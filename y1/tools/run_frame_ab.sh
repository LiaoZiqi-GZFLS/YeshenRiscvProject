#!/usr/bin/env bash
# run_frame_ab.sh —— Y1-C4b **B5 闸门**：宿主整帧机器（驱动规划 + CPU 后处理 + float ORT 参考）的**离线**判据。
#
# 为什么需要它：B5 交的是"整帧端到端"的**宿主半**（G7）。上板（B6）之前，能证的东西必须**先证死**，
#   否则 B6 一旦红了，分不清是"驱动/后处理写错了"还是"硬件不对"。
#   本闸门只做**离线可证**的四件事，并把"必须上板才能证"的部分**逐条列出来**。
#
# ============================== 判据 ==============================
#  0) **口径自检** `yunet_post.py --selftest`：
#       · decode 口径：单 anchor(10,10)@stride32 + bbox=(0,0,ln2,ln3) ⇒ 手算框 (288,272,64,96)、kps=(320,320) 逐值对上；
#       · NMS 口径：IoU≈0.9 的两框 ⇒ 只留 1；
#       · **比较器正负对照**：正对照 2 发**必须过**；负对照 4 发（挪框 / 挪关键点 / 抬置信度 / 多检 2 个）**必须全发火**。
#       没发火 ⇒ 退出 2（判据无牙 ⇒ 不可信）。
#  1) **驱动规划确定性 + 结构判据** `npu_frame_run.py --dry`（**不碰板**）跑两遍：
#       · `DRY_PLAN_MD5` 两次相等（确定性）；
#       · `DRY_OUTPUTS=12`、`DRY_FOLD_REWRITES=0`（★ H1 后 desc.bin 自洽 ⇒ 驱动**不需要**任何
#         折叠 SRC 改写）；`--dry` 若发现有改写需求会**响亮失败**（H1 复发哨兵）；
#       · `DRY_RESULT: PASS`（HARD 红旗为 0：对齐 / 28bit / 主机写入区重叠 / 出安全区）。
#  2) **float ORT 基线的两个方向** `ort_ref.py`：
#       · 真脸图（`grace_hopper.jpg`，仓内真照片）⇒ `FLOAT_DETS >= 1`；
#       · 确定性"无人脸"合成图 ⇒ `FLOAT_DETS == 0`。两个方向都有 ⇒ 后处理**不退化**。
#  3) **同口径 int8 的两个方向 + 确定性** `npu_frame_run.py --int8-tensors`（= 冻结黄金 `quant_ref`）：
#       · 真脸 ⇒ `INT8_DETS >= 1`；无人脸 ⇒ `INT8_DETS == 0`；
#       · 连跑两遍 12 路 md5 逐路相等（`INT8 DETERMINISM=OK`）。
#  4) **比较器在"真数据"上**（不只是合成对）：
#       · 正对照：float(脸) vs **同一份**检出 ⇒ `COMPARE ok=True`；
#       · 负对照①：float(脸) vs **框挪 96 px** 的真检出 ⇒ `ok=False`；
#       · 负对照②：float(脸) vs int8(脸) 的 `bbox_32` **注入 +3.0 偏移** ⇒ `ok=False`。
#       任一条"期望不符" ⇒ 退出 2。
#
#  另外**只记录、不判**（诚实报告）：`INT8-vs-FLOAT` 的 G7 四量（IoU / 关键点 L2 / |Δconf| / 检出数）。
#    离线 int8（≈ 板上同口径）与 float 的差就是 **B6 板上差距的最好离线预报**。
#
# ============================== 诚实边界（写在闸门里，不许含糊）==============================
#  **离线可证**：① 后处理口径（decode/NMS）与比较器自身；② 驱动规划的确定性与结构自洽
#              （12 路地址/字节数/折叠改写/对齐/安全区）；③ 同口径 int8 通路的非退化与确定性；
#              ④ float 基线与 int8 通路的**方向一致**（有脸都检出、无脸都不检出）。
#  **必须上板（B6）**：见脚本末尾 `B6_MUST` 段——硬件 12 路真实数值、`done/err`、整帧 DDR 流量与帧时、
#              以及两个**已知的红/黄**：折叠 SRC 改写 + arena 压内核 RAM（详见 `--dry` 输出）。
#
# 退出码：0 = 全绿；1 = 正判据红；2 = 比较器负对照没发火 / 期望不符（判据不可信）；3 = 前置缺失。
#
# 用法：bash y1/tools/run_frame_ab.sh          （PY=<python> 可覆盖解释器）
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

post="tools/yunet_post.py"; ort="tools/ort_ref.py"; drv="tools/npu_frame_run.py"
face="$(ls -1 ../ai_npu_exp/deps_export/matplotlib/mpl-data/sample_data/grace_hopper.jpg 2>/dev/null | head -1)"
[ -n "$face" ] || face="$(ls -1 ../third_party/yolov5_v3.0/inference/images/zidane.jpg 2>/dev/null | head -1)"
onnx="../third_party/yunet/yunet.onnx"
desc="gen/desc.bin"; jidx="gen/wgt_index.json"; blob="gen/wgt_blob.bin"; mult="gen/wgt_mult.bin"
pydeps="./.pydeps"; deps="../third_party/yunet/deps"; pildeps="../ai_npu_exp/deps_export"

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"

rc_pre=0
for f in "$post" "$ort" "$drv"; do [ -f "$f" ] || { echo "FATAL: 缺 $f"; rc_pre=1; }; done
for f in "$onnx" "$desc" "$jidx" "$blob" "$mult"; do [ -f "$f" ] || { echo "FATAL: 缺冻结产物 $f"; rc_pre=1; }; done
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; rc_pre=1; }
[ -n "$face" ] || { echo "FATAL: 找不到真脸图"; rc_pre=1; }
if [ "$rc_pre" -ne 0 ]; then echo "RESULT: FAIL"; exit 3; fi

export PYTHONPATH="$pydeps;$deps;$pildeps"
export PYTHONIOENCODING=utf-8

work="$(mktemp -d)"
cleanup() { if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => 保留 $work"; else rm -rf "$work"; fi; }
trap cleanup EXIT

echo "== run_frame_ab（C4b-B5 宿主整帧机器）=="
echo "   PY=$PY"
echo "   face=$face"
echo "   work=$work"

# ---------------------------------------------------------------- 0) 口径自检
echo "---- [0] yunet_post.py --selftest（decode/NMS 口径 + 比较器正负对照）----"
"$PY" "$post" --selftest > "$work/st.out" 2>&1
rc=$?
sed -n '1,20p' "$work/st.out"
if [ "$rc" -ne 0 ] || ! grep -q '^COMPARATOR selftest: bad_cases=4 fired=4 fails=0$' "$work/st.out"; then
  echo "JUDGE-RED: 口径自检未过（rc=$rc）或负对照没全发火"
  echo "RESULT: FAIL"
  exit 2
fi
echo "   [0] OK（比较器 4/4 负对照发火；decode/NMS 手算口径对上）"

# ---------------------------------------------------------------- 1) 驱动规划（不碰板）
echo "---- [1] npu_frame_run.py --dry ×2（确定性 + 12 路/0 改写(H1)/无 HARD）----"
for i in 1 2; do
  "$PY" "$drv" --dry --img "$face" --json "$work/plan$i.json" > "$work/dry$i.out" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || { echo "JUDGE-RED: --dry 第 $i 次 rc=$rc"; sed -n '1,20p' "$work/dry$i.out"; echo "RESULT: FAIL"; exit 1; }
  grep -qE 'DRY_OUTPUTS=12([^0-9]|$)' "$work/dry$i.out"      || { echo "JUDGE-RED: 12 路输出计划不齐"; echo "RESULT: FAIL"; exit 1; }
  grep -qE 'DRY_FOLD_REWRITES=0([^0-9]|$)' "$work/dry$i.out" || { echo "JUDGE-RED: 折叠 SRC 改写应为 0（H1 后 desc.bin 自洽）"; echo "RESULT: FAIL"; exit 1; }
  grep -qE 'DRY_HARD=0([^0-9]|$)' "$work/dry$i.out"          || { echo "JUDGE-RED: --dry 有 HARD 红旗"; sed -n '/HARD（真 bug）/,$p' "$work/dry$i.out" | head -12; echo "RESULT: FAIL"; exit 1; }
  grep -q '^DRY_RESULT: PASS' "$work/dry$i.out"              || { echo "JUDGE-RED: --dry DRY_RESULT 非 PASS"; echo "RESULT: FAIL"; exit 1; }
done
m1="$(grep -oE '^DRY_PLAN_MD5=[0-9a-f]+' "$work/dry1.out" | cut -d= -f2)"
m2="$(grep -oE '^DRY_PLAN_MD5=[0-9a-f]+' "$work/dry2.out" | cut -d= -f2)"
if [ -z "$m1" ] || [ "$m1" != "$m2" ]; then
  echo "JUDGE-RED: 规划不确定（$m1 vs $m2）"; echo "RESULT: FAIL"; exit 1
fi
echo "   [1] OK（DRY_PLAN_MD5=$m1；12 路 + 0 条折叠改写(H1 自洽) + 0 HARD）"
grep -E '^(DRY_ARENA_LO|DRY_ARENA_TOP)=' "$work/dry1.out" | sed 's/^/       /'
sed -n '/^-- WARN/,/^-- HARD/p' "$work/dry1.out" | sed 's/^/       /'
sed -n '/^-- 折叠 SRC 改写/,/改写条数/p' "$work/dry1.out" | sed 's/^/       /'

# ---------------------------------------------------------------- 2) float ORT 基线
echo "---- [2] ort_ref.py：真脸 >=1 / 无人脸 ==0 ----"
"$PY" "$ort" --img "$face" --out "$work/float_face.json" --tensors-npz "$work/float_face.npz" > "$work/of.out" 2>&1; rcf=$?
"$PY" "$ort" --no-face --out "$work/float_noface.json" > "$work/on.out" 2>&1; rcn=$?
sed -n '1,12p' "$work/of.out" | sed 's/^/   /'
fd="$(grep -oE '^ORT FLOAT_DETS=[0-9]+' "$work/of.out" | cut -d= -f2)"
nd="$(grep -oE '^ORT FLOAT_DETS=[0-9]+' "$work/on.out" | cut -d= -f2)"
if [ "$rcf" -ne 0 ] || [ "${fd:-0}" -lt 1 ]; then echo "JUDGE-RED: float 真脸方向红（rc=$rcf dets=${fd:-?}）"; echo "RESULT: FAIL"; exit 1; fi
if [ "$rcn" -ne 0 ] || [ "${nd:-1}" -ne 0 ]; then echo "JUDGE-RED: float 无人脸方向红（rc=$rcn dets=${nd:-?}）"; echo "RESULT: FAIL"; exit 1; fi
echo "   [2] OK（FLOAT face=$fd no-face=$nd）"

# ---------------------------------------------------------------- 3) 同口径 int8
echo "---- [3] npu_frame_run.py --int8-tensors（quant_ref 黄金）：真脸 >=1 / 无人脸 ==0 / 两跑确定 ----"
"$PY" "$drv" --int8-tensors --img "$face" --npz "$work/int8_face.npz" --json "$work/int8_face.json" > "$work/i8f.out" 2>&1; rc8=$?
"$PY" "$drv" --int8-tensors --no-face --json "$work/int8_noface.json" > "$work/i8n.out" 2>&1; rcn8=$?
sed -n '/^INT8 DETERMINISM/,/INT8_RESULT/p' "$work/i8f.out" | sed 's/^/   /'
i8="$(grep -oE '^INT8 score_thr=.*INT8_DETS=[0-9]+' "$work/i8f.out" | grep -oE 'INT8_DETS=[0-9]+' | cut -d= -f2)"
i8n="$(grep -oE '^INT8 score_thr=.*INT8_DETS=[0-9]+' "$work/i8n.out" | grep -oE 'INT8_DETS=[0-9]+' | cut -d= -f2)"
if [ "$rc8" -ne 0 ] || ! grep -q '^INT8 DETERMINISM=OK' "$work/i8f.out"; then echo "JUDGE-RED: int8 确定性/正方向红（rc=$rc8）"; echo "RESULT: FAIL"; exit 1; fi
if [ "${i8:-0}" -lt 1 ]; then echo "JUDGE-RED: 同口径 int8 真脸方向红（dets=${i8:-?}）"; echo "RESULT: FAIL"; exit 1; fi
if [ "$rcn8" -ne 0 ] || [ "${i8n:-1}" -ne 0 ]; then echo "JUDGE-RED: 同口径 int8 无人脸方向红（dets=${i8n:-?}）"; echo "RESULT: FAIL"; exit 1; fi
echo "   [3] OK（INT8 face=$i8 no-face=$i8n；两跑 12 路 md5 逐路相等）"

# ---------------------------------------------------------------- 4) 比较器在真数据上
echo "---- [4] 比较器（真数据对）：正对照 + 2 条负对照 ----"
cp "$work/float_face.json" "$work/float_face_copy.json"
# 负对照①：把真检出的框挪 +96 px（bbox 的 dx +3.0 ⇒ 3.0*stride32 = 96 px）
"$PY" "$post" --npz "$work/int8_face.npz" --json "$work/int8_face_ok.json" > "$work/p0.out" 2>&1
"$PY" - "$work/int8_face.npz" "$work/int8_face_bad.npz" <<'PYEOF' > "$work/perturb.out" 2>&1
import sys, numpy as np
z = dict(np.load(sys.argv[1], allow_pickle=False))
b = np.array(z["bbox_32"], dtype=np.float64).copy()
b[:, :, 0] += 3.0                      # dx += 3.0 ⇒ 框右移 3.0*32 = 96 px
z["bbox_32"] = b
np.savez(sys.argv[2], **z)
print("PERTURB bbox_32 dx += 3.0 (box +96px)")
PYEOF
cat "$work/perturb.out" | sed 's/^/   /'
"$PY" "$post" --npz "$work/int8_face_bad.npz" --json "$work/int8_face_bad.json" >> "$work/p0.out" 2>&1
sed -n '1,4p' "$work/p0.out" | sed 's/^/   /'

cmp_expect() {   # cmp_expect <A> <B> <pass|fail> <label>
  local a="$1" b="$2" e="$3" lb="$4" out
  out="$("$PY" "$post" --compare-a "$a" --compare-b "$b" --expect "$e" 2>&1)"; local rc=$?
  echo "$out" | grep -E '^COMPARE (count=|iou_min=|ok=|expect=)' | sed 's/^/   /'
  if [ "$rc" -ne 0 ]; then
    echo "NEGCTL-FAIL: $lb 期望 $e 未满足（rc=$rc）⇒ 比较器不可信"
    echo "RESULT: FAIL"; exit 2
  fi
  echo "   [4] $lb OK（期望 $e）"
}
cmp_expect "$work/float_face.json" "$work/float_face_copy.json" pass "正对照 float-vs-同一份"
cmp_expect "$work/float_face.json" "$work/int8_face_bad.json"   fail "负对照① int8 bbox+96px"
# 负对照②：float(脸) vs float 的**框挪 96 px**（纯检出层变异，不经网络）
"$PY" - "$work/float_face.json" "$work/float_face_shift.json" <<'PYEOF' > /dev/null 2>&1
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
for x in d["dets"]:
    x["box"][0] += 96.0
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"))
PYEOF
cmp_expect "$work/float_face.json" "$work/float_face_shift.json" fail "负对照② float 框 +96px"
# 无人脸方向：两侧都 0 ⇒ 正对照（比较器在"都没检出"时不误报）
cmp_expect "$work/float_noface.json" "$work/int8_noface.json" pass "正对照 无人脸 0-vs-0"

# ---------------------------------------------------------------- 5) G7 预览（只记录、不判）
echo "---- [5] G7 预览（**离线 int8 vs float**；只记录、不判 —— 判据在上板 B6）----"
"$PY" "$post" --compare-a "$work/float_face.json" --compare-b "$work/int8_face.json" \
  > "$work/prev.out" 2>&1
grep -E '^COMPARE (count=|iou_min=|thr|ok=|expect=)' "$work/prev.out" | sed 's/^/   /' || true
# 逐量对照 spec §4.3 的容差，逐条给 PASS/FAIL 标记（**只是预报**）
"$PY" - "$work/prev.out" <<'PYEOF' 2>&1 | sed 's/^/   /'
import sys, re
t = open(sys.argv[1], encoding="utf-8").read()
def g(p, d):
    m = re.search(p, t); return float(m.group(1)) if m else d
iou = g(r'iou_min=([0-9.]+)', 0.0); kp = g(r'kp_l2_max=([0-9.]+)', 99.0)
cd = g(r'conf_d_max=([0-9.]+)', 99.0); n = re.search(r'count=(\d+)/(\d+)', t)
diff = abs(int(n.group(1)) - int(n.group(2))) if n else 99
rows = [("IoU >= 0.5", iou, iou >= 0.5), ("关键点平均 L2 <= 2 px", kp, kp <= 2.0),
        ("|dconf| <= 0.1", cd, cd <= 0.1), ("检出数差 <= 1", diff, diff <= 1)]
for nm, v, ok in rows:
    print("G7_PREVIEW %-22s = %8.4f  %s" % (nm, v, "OK" if ok else "**超过拟定容差**"))
print("G7_PREVIEW_VERDICT=%s" % ("all-within" if all(r[2] for r in rows)
                                 else "out-of-tolerance:" + ",".join(r[0] for r in rows if not r[2])))
PYEOF

# ---------------------------------------------------------------- 6) B6 清单
echo "---- [6] B6_MUST（**上板才能证** / 已知红黄）----"
cat <<'TXT'
   B6_MUST_1 硬件 12 路真实数值：走 npu_frame_run.py --run（串口纪律：逐字符慢发 + 等完成标记）
   B6_MUST_2 done/err：STATUS 位（电平保持；done 由 STATUS 写 1 清、err 由 CTRL.soft_reset 清）
   B6_MUST_3 G7 四条容差（IoU/kp L2/|dconf|/检出数差）用 [-5] 的 G7_PREVIEW 当**上界预报**
   B6_MUST_4 整帧 DDR 流量 + 帧时（声明下界/上界口径），与 C4a 的 ddr_traffic 模型合账
   B6_MUST_5 已知黄①（★ H1 已修，2026-10-12）：旧 desc.bin 里 6 条 Sigmoid 的 SRC_ADDR 指到
              从未被写过的"折叠视图"槽位，驱动用 --fold-src 在内存里改写。**H1 把折进做进了转换器**
              （y1_convert.py：34 条被折进源的 SRC_ADDR 一律改到生产者 DST）⇒ desc.bin 已自洽、
              驱动改写恒为 0。B6 板上要**验证这条自洽**（回读到 cls/obj 与 bbox/kps 数值对）。
   B6_MUST_6 已知黄②：冻结 arena ≈ 25–29 MB（NPU 0x0020_0000–0x01C5_05C0）**整段压在内核 RAM**
              （物理 0x8040_0000-0x8FFF_FFFF）。NPU 可达且非内核的窗口只有 4 MB ⇒ **放不下**。
              上板前须先裁决：改 DTS 缩内核窗口 / 改 DDR 基址 / 缩 arena（属 C4b 的内存复用项）。
   B6_MUST_7 权重 blob（404 KB）与 M/z_pad/z_y/bias_adj 的投递通路（B1/B2 的契约）首次上板联调。
   B6_MUST_8 真摄像头 / fps 不在本闸门（Y5 / C5）。
TXT

echo "=========================================================================="
echo "C4b-B5 宿主整帧机器（离线可证部分）："
echo "  口径自检   = OK（比较器 4/4 负对照发火；decode/NMS 手算对上）"
echo "  驱动规划   = OK（DRY_PLAN_MD5=$m1；12 路输出 + 0 条折叠改写(H1 自洽) + 0 HARD；两次一致）"
echo "  float 基线 = OK（真脸 $fd 检出 / 无人脸 $nd 检出；模型=$onnx）"
echo "  同口径 int8= OK（真脸 $i8 检出 / 无人脸 $i8n 检出；两跑 12 路 md5 逐路相等）"
echo "  比较器     = OK（真数据：正对照过 + 2 条负对照发火）"
echo "  诚实标注   = 真脸图取自仓内 $face"
echo "               （matplotlib sample_data 的真照片；**不是**本任务造的合成脸）"
echo "               G7 容差数值取自 spec §4.3（**拟定、可调**）"
echo "RESULT: PASS"
exit 0
