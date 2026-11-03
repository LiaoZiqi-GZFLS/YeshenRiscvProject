#!/usr/bin/env bash
# run_chain_ab.sh —— ★ A-1a **L 切片片上融合链**（`UnitExec` 的 `chainLen` 档）的数值闸门。
#
# 被测行为（rtl/UnitExec.scala 文件头"★ A-1a" + "★ A-1b"）：
#   一个 `go` 里串起 **4 个** `Conv3x3Slice`（`chainLen=4`，由**独立入参** `+CHAINLEN=4` 给）：切片0 -> 片上 buf1
#   -> 切片1 -> 片上 buf2 -> 切片2 -> 片上 buf3 -> 切片3 -> **片上输出存储** -> DDR。**中间张量结构性零 DDR**。
#   ★ A-3 前提变更（本闸门**显式**改了常数，不是放宽判据）：网表 `gen/UnitExec_w32.v` 的生成期上限
#     **`L_MAX` 由 4 改成 8**（与 `rtl/LayerSched.scala` 的 `LayerSched.L_MAX` 同一个设计参数；
#     链长直方图 {2:15,4:2,6:1,8:1} ⇒ L_MAX=8 才覆盖 33/33 条融合边）。**本用例的链长仍是 4**
#     （四个相邻条目；只用切片 0..3）⇒ 逐字节黄金/零 DDR 判据的前提一字不变；变的只有两处
#     **L_MAX 依赖**的判据：`(e)` 的自报 `LMAX=8`、`6)` 的实例计数（`Conv3x3Slice=8 / FusionBuf=9`）、
#     以及"链长越限"那条负对照的**越限值**（`6 → 9`，因为 6 已不再越 8 的界）。
#   ★★ C4a.5a 的锚点变更（本闸门**显式**改了前提，不是悄悄放宽）：按 §4.4，切片的 requant 从纯
#     `>>SHIFT` 换成 `((acc·M) >> REQUANT_Q) >> SHIFT`；本单元这一阶段把新口按**单位元**接
#     （`M=2^24`、`ps_in/bias/z_y=0`）⇒ **数值逐字节不变**。网表里 `>>> 3'd6` 仍是**恰好 8 处**
#     （每 co 一处），但来源从 `arr_p_i` 变成乘积那一级 ⇒ 本闸门第 `7)` 节的"文本指纹"由
#     `arr_p_\d+ >>> 3'd6` 改成 `>>> 3'd6`（**命中数不变 = 8**，判据语义一字未改）。
#   ★★ C4a-R2 再次重锚（2026-10-11，**显式**改了前提，不是悄悄放宽）：切片 requant 改成**三级流水**
#     后（`Conv3x3Slice.scala` 的恒等式证明），`((prod >> 24) >> 6)` 被折叠成**一个常量**
#     `RQ = REQUANT_Q + SHIFT = 30` ⇒ 网表里中再没有 `>>> 3'd6`。新写法是
#     `(pLoR >>> 5'd30) + ({2'd0,pHiR} <<< 2'd2)`（= 精确的 `floor(prod/2^30)`）。本闸门第 `7)` 节的
#     "requant 文本指纹"随之从 `>>> 3'd6` 改成**配套的两处常量** `>>> 5'd30` 与 `<<< 2'd2`
#     （**命中数各 8** —— 每 co 一个半积，判据的语义一字未改：仍是"单份 `Conv3x3Slice` 定义里 8 个
#     requant 站点"）。
#   ★★ A-1b 的口径变更（本闸门**显式**改了前提，不是悄悄放宽）：链由**四个相邻条目**表达 ——
#     `0b00`(head) `0b10`(middle) `0b10`(middle) `0b11`(tail)；`UnitExec` 拿到的"链描述符" =
#     **链首的 8 个字 + 链尾的 `DST_ADDR`**，链长由独立入参给（旧编码把它塞在 `FLAGS[4:2]` 里，A-1b 已收回保留）。
#     本闸门直接驱动 `UnitExec`（不经 `LayerSched`），所以它**当场断言**合并规则（见"条目对账 OK"一行）。
#   交错**行锁步**（`read(i+1) ≥ r` / `wrote(i) > t`，占用性自证见 RTL 文件头）在整条链上逐对成立；
#   每个中间缓冲 `bufs(b)`（b=1..3）在切片 b-1 写完 IMG_H 行真行、切片 b 读完这 IMG_H 行后注入一行 0（pad）。
#
# ★ "1x1" 是**测试实现**（不是"RTL 里有一个 1x1 单元"）：`Conv3x3Slice` 没有 1x1 档；只有中心抽头的
#   3x3 在 pad=1/stride=1 下**正好等于** 1x1 conv。本闸门的链权重：
#       段0 = 普通 3x3 (×4)；段1 = **中心抽头 3x3 ≡ 1x1** (×4)；段2 = 普通 3x3 (×4)；段3 = 中心抽头 3x3 (×1)
#   （段间放大抵消每段 >>6 的衰减；RTL **不**假定任何权重取值 —— 中心抽头只出现在夹具里。）
#
# 判据（正对照 + 零 DDR 中间 + 中间片上 + 负对照双向发火 + 比较器自检 + 响亮 err + 结构 + 实例计数）：
#   0) 向量/维度/非退化/防混叠前提（python；不成立 exit 3）：
#      · 激活/权重来自 `tools/conv_unit_ref.py`（**复用 `mac_ref`** 的 dense 3x3 算术 + `>>6` + clamp）；
#      · 两条**完全独立**的链黄金实现（`chain_l` = mac_ref + 布局置换；`chain_l_naive` = 朴素 NHWC 三重循环）
#        逐字节相同；三个中间张量 + 最终张量都非退化（distinct ≥ 8、非 0 字节 ≥ 1/4、非整片 clamp）；
#      · 无 0 字节（本用例 seed 选定）；背景内存 = 素周期 251 模式（与 128 互素）；DST/DEC 两区预载与
#        期望值**压倒性不同**（≥1900/2048）⇒ "一个字节都没写" 不可能被误判成通过；
#      · 最终黄金对**整行/整列平移**敏感（防行主序喂错被周期性图案糊住）。
#   1) **正对照（一条 go 跑 4 切片）**：
#      (a) 最终张量（`DST`）与黄金**逐字节**一致（`CHAIN_FIN_MISMATCH=0`）；
#      (b) **零 DDR 中间**（结构性 + 计数）：`MEM rd == head_input_bytes`、`MEM wr == tail_output_bytes`
#          （= `2048 / 2048`；**中间三张的 3×2048 读 + 3×2048 写一份都不在**），装置自报
#          `RD_BYTES_PEAK/WR_BYTES`、`AR_BURSTS/AW_BURSTS/B_OK` 三方一致（`AR=16` 只一笔 RD、`AW=B_OK=16`）；
#      (c) **诱饵区未动**：两个 `DEC` 区间逐字节 == 预载（`DEC1_UNCHANGED_BAD=DEC2_UNCHANGED_BAD=0`），
#          `SRC` 未改，整片内存**只有 `DST` 那一区变了**（`OTHER_BAD=0`）；
#      (d) **中间张量在片上**：把 `bufs(1)`（切片0↔切片1 的中间缓冲）的 3 行环窗**读回**（`+MIDREAD`），
#          与 `mid0` 的**最后三行**（行 6/7 + 注入的 pad 行 0）逐字节对账（`MID_RING_MISMATCH=0`）；
#      (e) 自报：`CHAIN_LEN=4 CHAIN_LEN_REP=4 LMAX=8`（链长 = 入参 = 网表回读；`LMAX` = 网表的生成期上限）、`HEAD_MODE=1`、
#          `TAIL_MODE=1`、`MID_ROWS=TAIL_ROWS=IMG_H+1=9`。
#   2) **负对照（必须红，两面）**：同一几何、同一链，把**链首条目**的 `FLAGS.bit0` **强行置 1**
#      （`0b00 -> 0b01`，其余一字不动、`chainLen` 仍是 4）⇒ 切片0 的**中间张量**（`mid0`）落 DDR：
#        · `MEM wr == 2*tail_output_bytes`（**变大**：两个 WR 相位各一张图）；
#        · `DEC1` 区间被写（`DEC1_UNCHANGED_BAD > 0`，且 `DEC1[0:2048] == mid0` 黄金）。
#      原始红证据直接打印 —— 这就是"判据真的盯着'中间不落 DDR'"的证据。（flag 式，任务允许。）
#   3) **响亮 err 两档**：`+CHAINLEN=9 > L_MAX=8`（链长越限）、`FLAGS[7:2]` 非 0（保留位非法）
#      ⇒ RTL 必须 **err + 零搬运**（不发一个 AR/AW、`MEM rd=wr=0`）。
#   4) **比较器自检**：扰动最终黄金一个字节 ⇒ `CHAIN_FIN_MISMATCH` 必须**恰好 1**。
#   5) **结构判据**：`tools/check_dangling.py` 对 `gen/UnitExec_w32.v`（零悬空）。
#   6) **实例计数 / 网表规模**（给面积闸门起点）：打印 `Conv3x3Slice`/`FusionBuf`/`WeightStore`
#      例化点数与行数/字节数；断言 `Conv3x3Slice == L_MAX+1 = 9`（= `L_MAX` 自身 + 宽层 `MultiPassUnit`
#      内 1 片）、`FusionBuf == L_MAX+1 = 9`、`WeightStore == 1`（单份 `Conv3x3Slice` 定义里的 1 个例化点）、
#      requant 站点 `>>>5'd30 = 8` 与 `<<<2'd2 = 8`（**作用域 = `Conv3x3Slice` 模块体内**，见 §7 的重锚说明）。
#
# 退出码（与 Y1 既有闸门一致）：
#   0 = 全过；1 = 对账不符 / 编译或仿真失败 / 装置未 PASS / 网表不存在；
#   2 = 负对照没发火 / 响亮 err 没接在回路上 / 比较器自检不过 ⇒ **闸门自身不可信**；
#   3 = 向量/维度/非退化前提不成立（用例写错，或参考自身自检没过）。
#
# 装置契约（rtl_test/UnitExecTb.v + rtl_test/AxiMemModel.v + gen/UnitExec_w32.v）：
#   +WGTFILE=（切片0）+WGTFILE_T=（切片1）+WGTFILE2=（切片2）+WGTFILE3=（切片3）
#   +D0..+D7=<dec>（**链描述符**）+CHAINLEN=<链长> +CTRL=1 +MEMFILE= +DUMPFILE= [+MIDREAD +MIDFILE=] [+EXPECT_ERR]
set -uo pipefail

PY="${PY:-python}"
here="$(cd "$(dirname "$0")" && pwd)"
gen="$here/../gen"
tb="$here/../rtl_test/UnitExecTb.v"
memv="$here/../rtl_test/AxiMemModel.v"
nl="$gen/UnitExec_w32.v"
ref="$here/conv_unit_ref.py"
dangling="$here/check_dangling.py"

# ---- 用例常量（A-1a 的链几何：C_IN=C_OUT=8, W=32, H=8, SHIFT=6；整块尺寸）----
MEMSZ=2621440              # 2.5 MiB（与 AxiMemModel 的 MEMSZ 一致）
SRC=131072                 # 0x20000  链的输入（NHWC）
DEC1=196608                # 0x30000  ★ 诱饵 1：中间张量的"槽位地址"（链**不得**碰它）
DEC2=262144                # 0x40000  ★ 诱饵 2（第二个诱饵，防"只检查一处"）
DST=1441792                # 0x160000 链的最终输出
W=32; H=8; CIN=8; COUT=8; SGROUP=1; SHIFT=6
LMAX=8                               # ★ A-3：网表 gen/UnitExec_w32.v 的生成期切片上限（= 8）
CHAIN_N=4                            # 本用例的链长（四个相邻条目 0b00,0b10,0b10,0b11）⇒ 只用切片 0..3
IN_BYTES=$(( CIN * H * W ))          # 2048（= d.w6 = 链输入字节数）
OUT_BYTES=$(( COUT * H * W ))        # 2048（链输出字节数 = 每层中间张量字节数）
MID_BYTES=$OUT_BYTES                 # 每张中间张量 2048 B（3 张中间 ⇒ 3*2048 读 + 3*2048 写都不该出现）
PERIOD=251                           # 素周期；与 128 互素 ⇒ 整块平移必被发现
SEED=20265793                        # 本用例选定的 seed：激活**无 0 字节**（见判据 0）

# ★ A-1b：`run_sim` 用的链长（`+CHAINLEN=`）；每个调用点显式设置。
SIM_CHLEN=4
work="$(mktemp -d)"
cleanup() {
  if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 => 激励与日志留在 $work"
  else rm -rf "$work"; fi
}
trap cleanup EXIT

find_tool() {
  local n="$1" p d
  p="$(command -v "$n" 2>/dev/null || true)"
  if [ -z "$p" ]; then
    for d in /c/msys64/ucrt64/bin /mingw64/bin /usr/bin; do
      if [ -x "$d/$n" ]; then p="$d/$n"; break; fi
    done
  fi
  printf '%s' "$p"
}
IVERILOG="$(find_tool iverilog)"
VVP="$(find_tool vvp)"

echo "== run_chain_ab: A-1b L 切片片上融合链（四个相邻条目 0b00,0b10,0b10,0b11 ⇒ chainLen=4）：切片0->片上->切片1->片上->切片2->片上->切片3->DDR，中间张量零 DDR =="
echo "   tb  =$tb"
echo "   mem =$memv"
echo "   nl  =$nl"
echo "   ref =$ref"
echo "   py=${PY}  iverilog=${IVERILOG:-<找不到>}  vvp=${VVP:-<找不到>}"
echo "   tmp =$work"
echo "   用例 SRC=$SRC DEC1=$DEC1 DEC2=$DEC2 DST=$DST  L_MAX=$LMAX 用例链长=$CHAIN_N"
echo "        几何 C_IN=$CIN C_OUT=$COUT W=$W H=$H GROUP=$SGROUP SHIFT=$SHIFT 中间=$MID_BYTES B SEED=$SEED"

# ---------------- 前置检查 ----------------
if [ ! -f "$nl" ]; then
  echo "FATAL: 找不到网表 $nl"
  echo "       先生成: cd y1 && printf 'Test/runMain UnitExecGen D:/code/PDS/VexiiYeshenLinux/y1/gen\\\\nexit\\\\n' | bash sbt.sh"
  exit 1
fi
[ -f "$tb" ]  || { echo "FATAL: 找不到装置 $tb"; exit 1; }
[ -f "$memv" ]|| { echo "FATAL: 找不到内存模型 $memv"; exit 1; }
[ -f "$ref" ] || { echo "FATAL: 找不到参考 $ref"; exit 1; }
if [ -z "$IVERILOG" ] || [ -z "$VVP" ]; then echo "FATAL: 找不到 iverilog / vvp"; exit 1; fi
case $(( IN_BYTES % 128 )) in 0) : ;; *) echo "FATAL: IN_BYTES=$IN_BYTES 不是 128 的整数倍"; exit 3 ;; esac

# ---------------- 0) 参考自检 ----------------
echo "---- 0) tools/conv_unit_ref.py --selftest（复用 mac_ref 算术 + 布局置换 + L 段链双实现交叉对账）----"
if ! "$PY" "$ref" --selftest; then
  echo "=== FATAL: 参考自检没过 ⇒ 用例/参考写错了（不是硬件的问题）==="
  exit 3
fi

# ---------------- 0b) 结构判据：零悬空实例 ----------------
echo "---- 0b) tools/check_dangling.py（gen/UnitExec_w32.v ⇒ 零悬空）----"
if [ -f "$dangling" ]; then
  "$PY" "$dangling" "$nl" | tail -3
  if ! "$PY" "$dangling" "$nl" >/dev/null; then
    echo "JUDGE-RED: 有悬空实例（被例化但没有模块定义）"; exit 1
  fi
else
  echo "WARN: 找不到 $dangling（跳过结构判据）"
fi

# ---------------- 1) 造激励 + 链黄金（双实现）+ 非退化/防混叠前提 ----------------
echo "---- 1) 造向量：激活/4 段权重 + 链黄金（双实现）+ 内存模式（seed=$SEED）----"
if ! "$PY" - "$work" "$here" "$MEMSZ" "$SRC" "$DEC1" "$DEC2" "$DST" \
                    "$CIN" "$COUT" "$W" "$H" "$SGROUP" "$SHIFT" "$PERIOD" "$SEED" "$CHAIN_N" "$LMAX" <<'PYEOF'
import sys, os
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

work, refdir = sys.argv[1], sys.argv[2]
sys.path.insert(0, refdir)
import conv_unit_ref as R
import mac_ref

(memsz, src, dec1, dec2, dst, CIN, COUT, W, H, GROUP, SHIFT,
 PERIOD, SEED, SEG, LMAX) = (int(x) for x in sys.argv[3:19])

# ---- 激活 / 权重（复用 mac_ref 的 dense 3x3 算术）----
wt, x_chw, x_ddr, y_ddr = R.build(CIN, COUT, H, W, seed=SEED, shift=SHIFT)
assert len(wt) == COUT * CIN * 9, "权重长度 %d" % len(wt)
assert len(x_ddr) == CIN * H * W

# ---- ★ 4 段链权重：3x3 -> 1x1(中心) -> 3x3 -> 1x1(中心)，段间放大抵消每段 >>6 的衰减 ----
w_raw = [wt, R.centre_tap(wt, CIN, COUT), wt, R.centre_tap(wt, CIN, COUT)]
scales = [4, 4, 4, 1]
wts = [R.scale_wt(w, s) for w, s in zip(w_raw, scales)]
assert len(wts) == SEG, "段数 %d != case %d" % (len(wts), SEG)
for k, w in enumerate(wts):
    assert sum(1 for v in w if v != 0) > 0, "段 %d 权重全 0 ⇒ 用例没意义" % k
# 段1/段3 是"只有中心抽头"（≡ 1x1）。
for k in (1, 3):
    off = sum(1 for co in range(COUT) for ci in range(CIN) for kk in range(9)
              if kk != 4 and wts[k][(co * CIN + ci) * 9 + kk] != 0)
    assert off == 0, "段 %d 不是'只有中心抽头'（%d 个非 0 非中心）" % (k, off)

# ---- ★ 两条**完全独立**的链黄金（判据 0 的交叉对账）----
mids_a, fin_a = R.chain_l(x_chw, wts, CIN, COUT, H, W, SHIFT)
mids_b, fin_b = R.chain_l_naive(x_ddr, wts, CIN, COUT, H, W, SHIFT)
dmids = [sum(1 for a, b in zip(m, n) if a != b) for m, n in zip(mids_a, mids_b)]
dfin = sum(1 for a, b in zip(fin_a, fin_b) if a != b)
assert all(d == 0 for d in dmids) and dfin == 0, \
    "两条独立链黄金不一致（中间差 %s、最终差 %d）⇒ 参考口径漂了" % (dmids, dfin)
assert len(mids_a) == SEG - 1, "中间张量数 = 段数-1 = %d，得到 %d" % (SEG - 1, len(mids_a))

# ---- 非退化前提（每张中间 + 最终）----
for nm, t in [("mid%d" % k, m) for k, m in enumerate(mids_a)] + [("fin", fin_a)]:
    assert len(set(t)) >= 8, "%s 取值太集中（distinct=%d < 8）⇒ 判据分辨率太差" % (nm, len(set(t)))
    nz = sum(1 for v in t if v != 0)
    assert nz >= len(t) // 4, "%s 非 0 字节只有 %d/%d ⇒ 判据分辨率太差" % (nm, nz, len(t))
    ncl = sum(1 for v in t if v in (127, -128))
    assert ncl < len(t), "%s 整片 clamp（%d 个）⇒ 判据退化" % (nm, ncl)

# ---- ★ 输入向量无 0 字节（本用例 seed 选定）----
assert all(v != 0 for v in x_ddr), "输入向量含 0 字节（本用例要求无 0）"
assert len(set(x_ddr)) >= 200, "输入取值太集中（distinct=%d）" % len(set(x_ddr))

# ---- 防混叠：最终黄金对**整行平移 / 整列平移**敏感 ----
def rowshift(a, k):
    out = [0] * len(a)
    for y in range(H):
        for x in range(W):
            for c in range(COUT):
                out[(y * W + x) * COUT + c] = a[(((y + k) % H) * W + x) * COUT + c]
    return out

def colshift(a, k):
    out = [0] * len(a)
    for y in range(H):
        for x in range(W):
            for c in range(COUT):
                out[(y * W + x) * COUT + c] = a[(y * W + (x + k) % W) * COUT + c]
    return out
assert fin_a != rowshift(fin_a, 1), "最终黄金 == 整行平移 ⇒ 行错位不可观测"
assert fin_a != colshift(fin_a, 1), "最终黄金 == 整列平移 ⇒ 列错位不可观测"

# ---- 内存模式：素周期 251 ----
def pat(i):
    return ((i % PERIOD) * 131 + 7) % PERIOD
assert len(set(pat(i) for i in range(PERIOD))) == PERIOD, "模式周期不是恰好 %d" % PERIOD
assert PERIOD % 128 != 0 and 128 % PERIOD != 0, "模式周期与块长不互素"

# ---- 防混叠 2：DST / DEC1 两区的预载与期望值**压倒性不同** ----
pre = bytes(pat(i) for i in range(memsz))
diff_dst = sum(1 for j in range(len(fin_a)) if pre[dst + j] != (fin_a[j] & 0xFF))
assert diff_dst >= 1900, "DST 区预载与最终黄金只有 %d/%d 字节不同 ⇒ 不写也有机会过" % (diff_dst, len(fin_a))
diff_dec = sum(1 for j in range(len(mids_a[0])) if pre[dec1 + j] != (mids_a[0][j] & 0xFF))
assert diff_dec >= 1900, "DEC1 区预载与 mid0 只有 %d/%d 字节不同 ⇒ '未动'判据没牙" % (diff_dec, len(mids_a[0]))

# ---- 结构自检：地址 32B 对齐、互不重叠、留 128B 邻居、都在已建模内存内 ----
regions = {"src": (src, CIN * H * W), "dec1": (dec1, COUT * H * W), "dec2": (dec2, COUT * H * W),
           "dst": (dst, COUT * H * W)}
for n, (a, ln) in regions.items():
    assert a % 32 == 0, "%s 地址 %d 不是 32B 对齐" % (n, a)
    assert a + ln <= memsz, "%s 越出已建模内存" % n
    assert a >= 128 and memsz - (a + ln) >= 128, "%s 前后要留出邻居字节" % n
names = sorted(regions.keys(), key=lambda n: regions[n][0])
for i in range(len(names) - 1):
    a0, l0 = regions[names[i]]
    a1, _ = regions[names[i + 1]]
    assert a0 + l0 <= a1, "%s 与 %s 区重叠" % (names[i], names[i + 1])

# ---- 落盘 ----
mem = bytearray(pre)
mem[src:src + len(x_ddr)] = bytes(v & 0xFF for v in x_ddr)
with open(work + "/mem.hex", "w") as f:
    f.write("".join("%02x\n" % b for b in mem))
for k, w in enumerate(wts):
    R.dump_bytes(work + "/wgt%d.hex" % k, w)
with open(work + "/gold_fin.hex", "w") as f:
    f.write("".join("%02x\n" % (v & 0xFF) for v in fin_a))
for k, m in enumerate(mids_a):
    with open(work + "/gold_mid%d.hex" % k, "w") as f:
        f.write("".join("%02x\n" % (v & 0xFF) for v in m))
# bufs(1) 的 3 行环窗期望（读回口径）：rd_row=0 -> mid0 行 (H-2)=6；rd_row=1 -> 行 (H-1)=7；rd_row=2 -> pad 行全 0。
#   理由：写完 IMG_H 行真行 + 1 行注入 pad（共 H+1=9 行）后 row_ptr = (H+1)%3 = 0 ⇒ 三档 rd_row 对应物理槽
#   0/1/2 = 逻辑行 6 / 7 / pad。
ring = []
r6 = mids_a[0][6 * W * COUT: 7 * W * COUT]
r7 = mids_a[0][7 * W * COUT: 8 * W * COUT]
ring = list(r6) + list(r7) + [0] * (W * COUT)
with open(work + "/gold_midring.hex", "w") as f:
    f.write("".join("%02x\n" % (v & 0xFF) for v in ring))

# ---- ★ A-1b：per-operator 链式编码 —— **四个相邻条目** `0b00`,`0b10`,`0b10`,`0b11` ----
#   一个描述符 = **一个算子**。链 = 相邻条目序列（head/middle 的后继是 middle/tail）；
#   链长由**独立入参** `+CHAINLEN=` 给（不再译自 `FLAGS[4:2]`）；链的 `SRC` = 链首的、`DST` = **链尾**的。
#   `UnitExec` 拿到的"链描述符" = **链首的 8 个字 + 链尾的 `DST_ADDR`**。本闸门直接驱动 `UnitExec`
#   （不经 `LayerSched`）⇒ 它**当场断言**这个合并规则（见"条目对账 OK"一行）。
def mk(flags, src_a, dst_a):
    D = [0] * 8
    D[0] = 0x01 | (flags << 8)                    # TYPE=conv3x3, FLAGS=flags（per-operator 两位）
    D[1] = W | (H << 16)
    D[2] = CIN | (COUT << 16)
    D[3] = GROUP | (1 << 8) | (1 << 12)           # GROUP, STRIDE=1, PAD=1
    D[4] = src_a
    D[5] = dst_a
    D[6] = CIN * H * W                            # IN_BYTES（链输入字节数）
    D[7] = SHIFT                                  # QUANT_SHIFT, LAYER_ID=0
    return D

def chain_desc(head, tail):
    """链描述符 = 链首的 8 个字 + 链尾的 `DST_ADDR`（`w5`）。"""
    D = list(head)
    D[5] = tail[5]
    return D

# 四个相邻条目：head(0b00) / middle(0b10) / middle(0b10) / tail(0b11)。
#   ★ 中间三张张量的"槽位地址"故意写成 DEC1/DEC2（判据 1(c) 的两个诱饵区）—— 链**一个字节都不该碰它们**。
E0 = mk(0b00, src,  dec1)                         # head  ：输入 DDR(src)，输出**留片上**
E1 = mk(0b10, dec1, dec2)                         # middle：输入取上游片上输出，输出留片上
E2 = mk(0b10, dec2, dec1)                         # middle：同上
E3 = mk(0b11, dec1, dst)                          # tail  ：输入取上游片上输出，输出落 DDR(dst)
Dpos = chain_desc(E0, E3)                         # 链描述符：SRC=链首的 src，DST=链尾的 dst
assert Dpos[4] == E0[4] and Dpos[5] == E3[5] and Dpos[0] == E0[0], "链描述符 != 链首的字 + 链尾的 DST"
# 负对照：把**链首条目的 bit0 强行置 1**（`0b00 -> 0b01`，其余一字不动，chainLen 仍是 4）
#   ⇒ 切片0 的中间张量**也**落 DDR，落点 = 链描述符的 DST = DEC1（判据 1(c) 盯的那个区间）。
E0n  = mk(0b01, src, dec1)
E3n  = mk(0b11, dec1, dec1)
Dneg = chain_desc(E0n, E3n)
assert ((Dneg[0] >> 8) & 1) == 1, "负对照必须是把链首的 bit0 置 1"
# 响亮 err 两档（都**零设备搬运**）：
#   · 链长越限：chainLen=9 > L_MAX=8（由 `+CHAINLEN=9` 给；FLAGS 仍是链首的合法 `0b00`）；
#   · 保留位非 0：`FLAGS[7:2]` 里的 bit2 置 1（`0b100`）⇒ 非法编码（chainLen=1）。
Derr  = mk(0b00, src, dst)                        # +CHAINLEN=9 ⇒ 链长越限
Dresv = mk(0b100, src, dst)                       # FLAGS[7:2] 非 0 ⇒ 保留位非 0
for nm, D in (("desc_pos", Dpos), ("desc_neg", Dneg), ("desc_err", Derr), ("desc_resv", Dresv)):
    with open(work + "/" + nm + ".args", "w") as f:
        f.write(" ".join(str(x) for x in D))      # ★ 不写结尾换行（Windows 文本模式会塞 \r）
# 四个**原始条目**（闸门逐字核对它们的两两相邻关系）
for nm, D in (("desc_e0", E0), ("desc_e1", E1), ("desc_e2", E2), ("desc_e3", E3)):
    with open(work + "/" + nm + ".args", "w") as f:
        f.write(" ".join(str(x) for x in D))
print("MEMGEN bytes=%d src=%d dec1=%d dec2=%d dst=%d period=%d seed=%d SEG=%d L_MAX=%d"
      % (memsz, src, dec1, dec2, dst, PERIOD, SEED, SEG, LMAX))
print("GOLD_AB: 链黄金两条独立实现：中间差 %s、最终差 %d（必须都是 0）" % (dmids, dfin))
print("NONZERO: 激活无 0 字节（distinct=%d/256）；各段 distinct=%s；最终非 0=%d/%d"
      % (len(set(x_ddr)), [len(set(m)) for m in mids_a] + [len(set(fin_a))],
         sum(1 for v in fin_a if v != 0), len(fin_a)))
print("NONALIAS: 周期恰 %d 且与 128 互素；DST 预载与最终黄金差 %d/%d；DEC1 预载与 mid0 差 %d/%d；"
      "最终黄金 != 整行/整列平移" % (PERIOD, diff_dst, len(fin_a), diff_dec, len(mids_a[0])))
print("ENTRIES: 0b00(head) 0b10(middle) 0b10(middle) 0b11(tail) ⇒ chainLen=4")
print("DESC pos  w0=0x%08x (链描述符 = 链首 0b00 的字 + 链尾的 DST；chainLen=4 由 +CHAINLEN=4 给)" % (Dpos[0] & 0xFFFFFFFF))
print("DESC neg  w0=0x%08x (链首 bit0 强行置 1 ⇒ 切片0 的中间落 DDR, dst=DEC1)" % (Dneg[0] & 0xFFFFFFFF))
print("DESC err  w0=0x%08x (+CHAINLEN=9 ⇒ chainLen=9 > L_MAX=%d ⇒ 响亮 err)" % (Derr[0] & 0xFFFFFFFF, LMAX))
print("DESC resv w0=0x%08x (FLAGS[7:2] 非 0 ⇒ 保留位非法 ⇒ 响亮 err)" % (Dresv[0] & 0xFFFFFFFF))
PYEOF
then
  echo "FATAL: 生成向量/黄金失败（或非退化/防混叠前提不成立）⇒ 闸门不可信"
  exit 3
fi
for f in mem.hex wgt0.hex wgt1.hex wgt2.hex wgt3.hex gold_fin.hex gold_mid0.hex gold_mid1.hex gold_mid2.hex \
         gold_midring.hex desc_pos.args desc_neg.args desc_err.args desc_resv.args \
         desc_e0.args desc_e1.args desc_e2.args desc_e3.args; do
  [ -s "$work/$f" ] || { echo "FATAL: 激励文件 $f 缺失或为空"; exit 3; }
done
read -r P0 P1 P2 P3 P4 P5 P6 P7 < "$work/desc_pos.args"
read -r N0 N1 N2 N3 N4 N5 N6 N7 < "$work/desc_neg.args"
read -r E0 E1 E2 E3 E4 E5 E6 E7 < "$work/desc_err.args"
read -r V0 V1 V2 V3 V4 V5 V6 V7 < "$work/desc_resv.args"
read -r A0 A1 A2 A3 A4 A5 A6 A7 < "$work/desc_e0.args"
read -r B0 B1 B2 B3 B4 B5 B6 B7 < "$work/desc_e1.args"
read -r C0 C1 C2 C3 C4 C5 C6 C7 < "$work/desc_e2.args"
read -r F0 F1 F2 F3 F4 F5 F6 F7 < "$work/desc_e3.args"
# ★ A-1b：四个相邻条目必须**逐字**满足 per-operator 编码 + "链描述符"合并规则。
for spec in "0:$A0" "1:$B0" "2:$C0" "3:$F0"; do
  k="${spec%%:*}"; w="${spec#*:}"; ff=$(( (w >> 8) & 3 ))
  case "$k:$ff" in 0:0|1:2|2:2|3:3) : ;; *) echo "JUDGE-RED: 条目 $k 的 FLAGS[1:0]=$ff 不是期望的 0/2/2/3"; exit 3 ;; esac
done
if [ "$P0" != "$A0" ] || [ "$P4" != "$A4" ] || [ "$P5" != "$F5" ]; then
  echo "JUDGE-RED: 链描述符 != 链首的字 + 链尾的 DST（P0=$P0 A0=$A0 P4=$P4 A4=$A4 P5=$P5 F5=$F5）"; exit 3
fi
echo "   条目对账 OK：0b00(head) 0b10 0b10 0b11(tail) ⇒ 链描述符 w0=$P0 (chainLen=4, SRC=$P4, DST=$P5)"

# ---------------- 2) 编译（好网表）----------------
echo "---- 2) iverilog 编译（UnitExecTb + AxiMemModel + gen/UnitExec_w32.v）----"
if ! "$IVERILOG" -g2012 -o "$work/sim.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败（好网表）"; sed -n '1,40p' "$work/iv.log"; exit 1
fi
if grep -qi 'warning' "$work/iv.log"; then
  echo "    编译告警（留意）："; grep -i 'warning' "$work/iv.log" | head -3
fi
echo "    编译 OK"

cat > "$work/cmpbytes.py" <<'PYEOF'
XBAD = -1

def load_num(p):
    vals = []; nbad = 0; first = -1
    for ln, raw in enumerate(open(p, encoding="utf-8", errors="replace"), 1):
        s = raw.strip()
        if not s:
            continue
        try:
            v = int(s, 16)
        except ValueError:
            v = None
        if v is None or v < 0 or v > 0xFF:
            if first < 0:
                first = ln
            nbad += 1
            vals.append(XBAD)
        else:
            vals.append(v)
    return vals, nbad, first

def diffs(a, b, base=0):
    assert len(a) == len(b), "length %d vs %d" % (len(a), len(b))
    cnt = 0; first = -1
    for k in range(len(a)):
        if a[k] != b[k]:
            if first < 0:
                first = base + k
            cnt += 1
    return cnt, first
PYEOF

# run_sim <vvp> <logbase> <w0> <w1> <w2> <w3> <d0..d7> [extra args...]
#   ★ A-1b：链长由全局 `SIM_CHLEN` 给（`+CHAINLEN=`；不再译自 `FLAGS[4:2]`）。
run_sim() {
  local vvp="$1" log="$2" w0="$3" w1="$4" w2="$5" w3="$6"
  local d0="$7" d1="$8" d2="$9" d3="${10}" d4="${11}" d5="${12}" d6="${13}" d7="${14}"; shift 14
  ( cd "$work" && "$VVP" "$vvp" \
      "+WGTFILE=$w0" "+WGTFILE_T=$w1" "+WGTFILE2=$w2" "+WGTFILE3=$w3" \
      "+MEMFILE=$work/mem.hex" "+DUMPFILE=$work/$log.dump" +dump \
      "+D0=$d0" "+D1=$d1" "+D2=$d2" "+D3=$d3" "+D4=$d4" "+D5=$d5" "+D6=$d6" "+D7=$d7" "+CTRL=1" \
      "+CHAINLEN=$SIM_CHLEN" "$@" ) \
      > "$work/$log.log" 2>&1
  return $?
}

# judge_region <dumpfile> <addr> <len>  -> MISMATCH / SRC_BAD / DEC1_BAD / DEC2_BAD / OTHER_BAD / WHOLE
judge_region() {
  "$PY" - "$work" "$1" "$2" "$3" "$SRC" "$DEC1" "$DEC2" "$DST" "$MID_BYTES" "$OUT_BYTES" <<'PYEOF'
import sys
work = sys.argv[1]
dumpf, addr, ln = sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
src, dec1, dec2, dst, midb, outb = (int(x) for x in sys.argv[5:11])
sys.path.insert(0, work)
from cmpbytes import load_num, diffs
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
d, dx, _ = load_num(dumpf)
p, px, _ = load_num(work + "/mem.hex")
print("WHOLE_DUMP=%d PRE=%d" % (len(d), len(p)))
n = min(len(d), len(p))
tot = 0; other = 0; ofirst = -1
for j in range(n):
    if d[j] != p[j]:
        tot += 1
        if not (dst <= j < dst + max(ln, outb)):
            other += 1
            if ofirst < 0:
                ofirst = j
print("WHOLE_MISMATCH=%d" % tot)
print("OTHER_BAD=%d" % other)
print("OTHER_FIRST_OFF=%d" % ofirst)
s_bad, _ = diffs(d[src:src + midb], p[src:src + midb], src)
print("SRC_UNCHANGED_BAD=%d" % s_bad)
d1_bad, d1f = diffs(d[dec1:dec1 + midb], p[dec1:dec1 + midb], dec1)
print("DEC1_UNCHANGED_BAD=%d" % d1_bad)
print("DEC1_FIRST_OFF=%d" % (dec1 + d1f if d1f >= 0 else -1))
d2_bad, _ = diffs(d[dec2:dec2 + midb], p[dec2:dec2 + midb], dec2)
print("DEC2_UNCHANGED_BAD=%d" % d2_bad)
print("XBYTES=%d" % dx)
PYEOF
}

# judge_gold <dumpfile> <goldfile> <addr> <len>  -> CHAIN_FIN_MISMATCH
judge_gold() {
  "$PY" - "$work" "$1" "$2" "$3" "$4" <<'PYEOF'
import sys
work = sys.argv[1]
dumpf, goldf, addr, ln = sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
sys.path.insert(0, work)
from cmpbytes import load_num, diffs
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
d, dx, _ = load_num(dumpf)
g, gx, _ = load_num(goldf)
m, first = diffs(d[addr:addr + ln], g[:ln], 0)
print("CHAIN_FIN_MISMATCH=%d" % m)
print("CHAIN_FIN_FIRST_OFF=%d" % (addr + first if first >= 0 else -1))
PYEOF
}

# ---------------- 3) 正对照：4 切片链（FLAGS[4:2]=3, bit0=0）----------------
echo "---- 3) 正对照[链 4 切片 = 四个相邻条目 0b00,0b10,0b10,0b11；+CHAINLEN=4]：一个 go 跑 4 个切片，中间张量零 DDR ----"
run_sim sim.vvp pos "$work/wgt0.hex" "$work/wgt1.hex" "$work/wgt2.hex" "$work/wgt3.hex" \
  "$P0" "$P1" "$P2" "$P3" "$P4" "$P5" "$P6" "$P7"
RC=$?
if [ "$RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/pos.log"; then
  echo "JUDGE-RED: 链仿真未 PASS（vvp rc=$RC）"
  grep -E '^(RESULT|TB-ERROR|DONE_SEEN|RD_BYTES_PEAK|AR_BURSTS|MEM )' "$work/pos.log" || true
  exit 1
fi
grep -E '^(TB UNITEXEC:|DONE_SEEN|RD_BYTES_PEAK|AR_BURSTS|HEAD_MODE|TAIL_MODE|CHAIN_LEN|MEM )' "$work/pos.log" | sed 's/^/   /'

# 3a) 描述符/几何/自报交叉对账
GEOM="$(grep -m1 '^TB UNITEXEC: IMG_W=' "$work/pos.log")"
EXP_GEOM="TB UNITEXEC: IMG_W=$W IMG_H=$H C_IN=$CIN C_OUT=$COUT GROUP=$SGROUP IN_BYTES=$IN_BYTES QUANT_SHIFT=$SHIFT"
if [ "$GEOM" != "$EXP_GEOM" ]; then
  echo "JUDGE-RED: 几何/描述符行不符"; echo "  got=$GEOM"; echo "  exp=$EXP_GEOM"; exit 1
fi
if ! grep -q '^TB UNITEXEC: HEAD_DESC=1 MIDREAD=0' "$work/pos.log"; then
  echo "JUDGE-RED: 装置没把描述符识别成头档（HEAD_DESC 应为 1）"; exit 1
fi
if ! grep -q '^TB UNITEXEC: TAIL_DESC=1' "$work/pos.log"; then
  echo "JUDGE-RED: 装置没把描述符识别成尾档（TAIL_DESC 应为 1）"; exit 1
fi
# ★ A-1b：链长 = 4，由**独立入参**给（`+CHAINLEN=4`；网表把它回读出来 ⇒ 端口真接上了）；
#   ★ A-3：`LMAX`（网表自报的生成期上限）现在是 **8** ⇒ 期望行拆成"链长 4 / 上限 8"。
CL="$(grep -m1 '^CHAIN_LEN=' "$work/pos.log")"
EXP_CL="CHAIN_LEN=$CHAIN_N CHAIN_LEN_REP=$CHAIN_N LMAX=$LMAX"
if [ "$CL" != "$EXP_CL" ]; then
  echo "JUDGE-RED: 链长自报不符（chainLen 应 = $CHAIN_N，L_MAX 应 = $LMAX，且回读 == 入参）got=[$CL] exp=[$EXP_CL]"; exit 1
fi
HM="$(grep -m1 '^HEAD_MODE=' "$work/pos.log")"
EXP_HM="HEAD_MODE=1 MID_ROWS=$(( H + 1 ))"
if [ "$HM" != "$EXP_HM" ]; then
  echo "JUDGE-RED: HEAD_MODE/MID_ROWS 不符（bufs(1) 该有 IMG_H 行真行 + 1 行注入 pad）got=[$HM] exp=[$EXP_HM]"; exit 1
fi
TM="$(grep -m1 '^TAIL_MODE=' "$work/pos.log")"
EXP_TM="TAIL_MODE=1 TAIL_ROWS=$(( H + 1 ))"
if [ "$TM" != "$EXP_TM" ]; then
  echo "JUDGE-RED: TAIL_MODE/TAIL_ROWS 不符 got=[$TM] exp=[$EXP_TM]"; exit 1
fi
echo "   自报 OK：$GEOM / $CL / $HM / $TM"

# 3b) 判据 1(b)：零 DDR 中间（字节计数：中间三张的 3x2048 读 + 3x2048 写一份都不在）
CH="$(grep -m1 '^AR_BURSTS=' "$work/pos.log")"
RDP="$(grep -m1 '^RD_BYTES_PEAK=' "$work/pos.log")"
MEML="$(grep -m1 '^MEM rd=' "$work/pos.log")"
EXP_CH="AR_BURSTS=$(( IN_BYTES / 128 )) AW_BURSTS=$(( OUT_BYTES / 128 )) B_OK=$(( OUT_BYTES / 128 ))"
EXP_RDP="RD_BYTES_PEAK=$IN_BYTES WR_BYTES=$OUT_BYTES"
EXP_MEM="MEM rd=$IN_BYTES wr=$OUT_BYTES bursts=$(( (IN_BYTES + OUT_BYTES) / 128 )) maxburst=16"
if [ "$CH" != "$EXP_CH" ]; then echo "JUDGE-RED: 突发数不符（RD 只该一笔）got=[$CH] exp=[$EXP_CH]"; exit 1; fi
if [ "$RDP" != "$EXP_RDP" ]; then echo "JUDGE-RED: 字节数不符（中间张量不该有 DDR 读/写）got=[$RDP] exp=[$EXP_RDP]"; exit 1; fi
if [ "$MEML" != "$EXP_MEM" ]; then echo "JUDGE-RED: 内存模型计数不符 got=[$MEML] exp=[$EXP_MEM]"; exit 1; fi
echo "   判据 1(b) OK（零 DDR 中间，字节计数三方一致）：$CH / $RDP / $MEML"
echo "      = rd(chain_input=$IN_BYTES) / wr(chain_output=$OUT_BYTES)；中间三张的 3x$MID_BYTES 读 + 3x$MID_BYTES 写都不在"

# 3c) 判据 1(a)：DST == 最终黄金
judge_gold "$work/pos.dump" "$work/gold_fin.hex" "$DST" "$OUT_BYTES" > "$work/pos.gold"
cat "$work/pos.gold" | sed 's/^/   /'
F_MIS="$(sed -n 's/^CHAIN_FIN_MISMATCH=\([0-9]*\)$/\1/p' "$work/pos.gold")"
if [ "$F_MIS" != "0" ]; then
  echo "JUDGE-RED: 判据 1(a) 失败：链输出 != 黄金（CHAIN_FIN_MISMATCH=$F_MIS）"; exit 1
fi
echo "   判据 1(a) OK：CHAIN_FIN_MISMATCH=0（DST 区 $OUT_BYTES 字节逐字节 == 链黄金）"

# 3d) 判据 1(c)：诱饵未动 + SRC 未改 + 整片只有 DST 变了
judge_region "$work/pos.dump" "$DST" "$OUT_BYTES" > "$work/pos.region"
cat "$work/pos.region" | sed 's/^/   /'
P_SBAD="$(sed -n 's/^SRC_UNCHANGED_BAD=\([0-9]*\)$/\1/p' "$work/pos.region")"
P_D1="$(sed -n 's/^DEC1_UNCHANGED_BAD=\([0-9]*\)$/\1/p' "$work/pos.region")"
P_D2="$(sed -n 's/^DEC2_UNCHANGED_BAD=\([0-9]*\)$/\1/p' "$work/pos.region")"
P_OBAD="$(sed -n 's/^OTHER_BAD=\([0-9]*\)$/\1/p' "$work/pos.region")"
if [ "$P_SBAD" != "0" ]; then echo "JUDGE-RED: SRC 被改（SRC_UNCHANGED_BAD=$P_SBAD）"; exit 1; fi
if [ "$P_D1" != "0" ] || [ "$P_D2" != "0" ]; then
  echo "JUDGE-RED: 判据 1(c) 失败：诱饵区被写（DEC1=$P_D1 DEC2=$P_D2）⇒ 中间张量落了 DDR"; exit 1
fi
if [ "$P_OBAD" != "0" ]; then echo "JUDGE-RED: 判据 1(c) 失败：DST 之外内存被改（OTHER_BAD=$P_OBAD）"; exit 1; fi
echo "   判据 1(c) OK：DEC1/DEC2 诱饵区未动、SRC 未改、整片只有 DST 那一区变了"

# 3e) 判据 1(d)：中间张量在片上 —— 读回 bufs(1) 的 3 行环窗，与 mid0 的最后三行对账
echo "---- 3e) 判据 1(d)：读回 bufs(1)（切片0↔切片1 的片上中间缓冲）的 3 行环窗 ----"
SIM_CHLEN=4
run_sim sim.vvp posmid "$work/wgt0.hex" "$work/wgt1.hex" "$work/wgt2.hex" "$work/wgt3.hex" \
  "$P0" "$P1" "$P2" "$P3" "$P4" "$P5" "$P6" "$P7" "+MIDREAD" "+MIDFILE=$work/mid_pos.hex"
RC=$?
if [ "$RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/posmid.log"; then
  echo "JUDGE-RED: 中间读回仿真未 PASS（vvp rc=$RC）"
  grep -E '^(RESULT|MIDDUMP|MEM )' "$work/posmid.log" || true; exit 1
fi
grep -E '^(MIDDUMP|MID_ROWS)' "$work/posmid.log" | sed 's/^/   /'
"$PY" - "$work" > "$work/midring.judge" <<'PYEOF'
import sys
work = sys.argv[1]
sys.path.insert(0, work)
from cmpbytes import load_num, diffs
d, dx, _ = load_num(work + "/mid_pos.hex")
g, gx, _ = load_num(work + "/gold_midring.hex")
m, first = diffs(d, g, 0)
print("MID_RING_MISMATCH=%d" % m)
print("MID_RING_FIRST_OFF=%d" % first)
print("MID_RING_LEN_DUMP=%d MID_RING_LEN_GOLD=%d" % (len(d), len(g)))
PYEOF
cat "$work/midring.judge" | sed 's/^/   /'
M_RING="$(sed -n 's/^MID_RING_MISMATCH=\([0-9]*\)$/\1/p' "$work/midring.judge")"
if [ "$M_RING" != "0" ]; then
  echo "JUDGE-RED: 判据 1(d) 失败：片上中间缓冲环窗 != mid0 的最后三行（MID_RING_MISMATCH=$M_RING）"; exit 1
fi
echo "   判据 1(d) OK：MID_RING_MISMATCH=0（bufs(1) 环窗 = mid0 行 6/7 + pad 行）⇒ 中间张量在片上"

# ---------------- 4) 比较器自检：扰动最终黄金一个字节 ⇒ MISMATCH 必须恰好 1 ----------------
echo "---- 4) 比较器自检：扰动最终黄金一个期望字节 ⇒ CHAIN_FIN_MISMATCH 必须恰好 1 ----"
"$PY" - "$work" <<'PYEOF'
import sys
work = sys.argv[1]
t = [l.strip() for l in open(work + "/gold_fin.hex") if l.strip()]
i = len(t) // 2
t[i] = "%02x" % ((int(t[i], 16) ^ 0x01) & 0xFF)
open(work + "/gold_fin_pert.hex", "w").write("\n".join(t) + "\n")
print("CMP_SELFTEST_PERTURB idx=%d" % i)
PYEOF
judge_gold "$work/pos.dump" "$work/gold_fin_pert.hex" "$DST" "$OUT_BYTES" > "$work/pert.judge"
SELF_MIS="$(sed -n 's/^CHAIN_FIN_MISMATCH=\([0-9]*\)$/\1/p' "$work/pert.judge")"
echo "   CMP_SELFTEST CHAIN_FIN_MISMATCH=$SELF_MIS（期望恰好 1）"
if [ "$SELF_MIS" != "1" ]; then
  echo "JUDGE-RED: 比较器自检 MISMATCH=$SELF_MIS != 1 ⇒ 闸门不可信"; exit 2
fi

# ---------------- 5) 负对照：把 FLAGS.bit0 强行置 1（切片0 的中间也落 DDR）⇒ 判据两面都发火 ----------------
echo "---- 5) 负对照[链首条目 bit0 强行置 1：切片0 的中间也落 DDR]：wr 变大 + DEC1 被写（两面发火）----"
SIM_CHLEN=4
run_sim sim.vvp neg "$work/wgt0.hex" "$work/wgt1.hex" "$work/wgt2.hex" "$work/wgt3.hex" \
  "$N0" "$N1" "$N2" "$N3" "$N4" "$N5" "$N6" "$N7"
NRC=$?
if [ "$NRC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/neg.log"; then
  echo "JUDGE-RED: 负对照仿真未 PASS（vvp rc=$NRC）—— 退化链本身应当跑完并写 DDR"
  grep -E '^(RESULT|TB-ERROR|DONE_SEEN|RD_BYTES_PEAK|AR_BURSTS|MEM )' "$work/neg.log" || true
  exit 2
fi
grep -E '^(TB UNITEXEC:|DONE_SEEN|RD_BYTES_PEAK|AR_BURSTS|HEAD_MODE|TAIL_MODE|CHAIN_LEN|MEM )' "$work/neg.log" | sed 's/^/   /'
NCH="$(grep -m1 '^AR_BURSTS=' "$work/neg.log")"
NRDP="$(grep -m1 '^RD_BYTES_PEAK=' "$work/neg.log")"
NMEM="$(grep -m1 '^MEM rd=' "$work/neg.log")"
EXP_NCH="AR_BURSTS=$(( IN_BYTES / 128 )) AW_BURSTS=$(( 2 * OUT_BYTES / 128 )) B_OK=$(( 2 * OUT_BYTES / 128 ))"
EXP_NRDP="RD_BYTES_PEAK=$IN_BYTES WR_BYTES=$(( 2 * OUT_BYTES ))"
EXP_NMEM="MEM rd=$IN_BYTES wr=$(( 2 * OUT_BYTES )) bursts=$(( (IN_BYTES + 2 * OUT_BYTES) / 128 )) maxburst=16"
if [ "$NCH" != "$EXP_NCH" ] || [ "$NRDP" != "$EXP_NRDP" ] || [ "$NMEM" != "$EXP_NMEM" ]; then
  echo "JUDGE-RED: 负对照计数不符（期望 wr 变大到 $(( 2 * OUT_BYTES ))）"
  echo "  ch=[$NCH] exp=[$EXP_NCH]"; echo "  rdp=[$NRDP] exp=[$EXP_NRDP]"; echo "  mem=[$NMEM] exp=[$EXP_NMEM]"
  exit 2
fi
# DEC1 区：必须被写（这就是负对照的"红"），且里面正是**切片0 的中间张量**（mid0）
"$PY" - "$work" "$DEC1" "$MID_BYTES" "$SRC" <<'PYEOF' > "$work/neg.judge"
import sys
work, dec1, midb, src = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
def load(p):
    return [l.strip() for l in open(p) if l.strip()]
d = load(work + "/neg.dump"); p = load(work + "/mem.hex"); gm = load(work + "/gold_mid0.hex")
bad = 0; first = -1
for j in range(midb):
    if d[dec1 + j] != p[dec1 + j]:
        bad += 1
        if first < 0:
            first = dec1 + j
print("DEC1_UNCHANGED_BAD=%d" % bad)
print("DEC1_FIRST_OFF=%d" % first)
print("DEC1_EQ_MID0=%d" % sum(1 for j in range(midb) if d[dec1 + j] != gm[j]))
sb = sum(1 for j in range(2048) if d[src + j] != p[src + j])
print("SRC_UNCHANGED_BAD=%d" % sb)
PYEOF
cat "$work/neg.judge" | sed 's/^/   /'
N_D1="$(sed -n 's/^DEC1_UNCHANGED_BAD=\([0-9]*\)$/\1/p' "$work/neg.judge")"
N_MID0="$(sed -n 's/^DEC1_EQ_MID0=\([0-9]*\)$/\1/p' "$work/neg.judge")"
if ! [ "$N_D1" -gt 0 ] 2>/dev/null; then
  echo "JUDGE-RED: 负对照没发火：bit0=1 时 DEC1 竟然没被写（DEC1_UNCHANGED_BAD=$N_D1）"; exit 2
fi
if [ "$N_MID0" != "0" ]; then
  echo "JUDGE-RED: 负对照不干净：被写进 DEC1 的不是切片0 的中间张量（差 $N_MID0）"; exit 2
fi
echo "   NEG_OK[链首 bit0=1]: wr 变大（$NRDP / $NMEM）+ DEC1 被写（DEC1_UNCHANGED_BAD=$N_D1，"
echo "                   且那 $MID_BYTES 字节正是切片0 的中间张量 mid0）⇒ 判据两面都发火"
echo "   = 原始红证据：同一用例、同一装置，只要把**链首条目**的 FLAGS.bit0 从 0 变 1（0b00 -> 0b01），"
echo "     判据 1(b)/1(c) 就同时红 ⇒ 切片0 的中间张量去了 DDR（合法表里 bit0=1 只出现在 tail）"

# ---------------- 6) 响亮 err 两档（都"发第一个 AR 之前"就拦住 ⇒ RTL err + 零搬运）----------------
#   ★ A-1b：两档都不再靠 `FLAGS` 里的链长编码（那一段已收回保留）：
#     (a) 链长越限：`+CHAINLEN=9 > L_MAX=8`（`FLAGS` 仍是链首的合法 `0b00`）；
#     (b) 保留位非 0：`FLAGS[7:2]` 的 bit2 置 1（`0b00000100`）⇒ 非法编码（`chainLen=1`）。
#   ★ A-3：越限值 6 → 9（`L_MAX` 已由 4 变 8 ⇒ 6 不再越界；9 = L_MAX+1 正是要测的那一格）。
echo "---- 6a) 响亮 err[链长 $LMAX 越限]：+CHAINLEN=9 > L_MAX=$LMAX ⇒ RTL err + 零搬运 ----"
SIM_CHLEN=9
run_sim sim.vvp err "$work/wgt0.hex" "$work/wgt1.hex" "$work/wgt2.hex" "$work/wgt3.hex" \
  "$E0" "$E1" "$E2" "$E3" "$E4" "$E5" "$E6" "$E7" "+EXPECT_ERR"
ERC=$?
grep -E '^(RESULT|DONE_SEEN|RD_BYTES_PEAK|AR_BURSTS|MEM )' "$work/err.log" | sed 's/^/   /' || true
if [ "$ERC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/err.log"; then
  echo "JUDGE-RED: 链长越限时装置没按预期 err 且零搬运（vvp rc=$ERC）⇒ 链长对账没接在回路上"; exit 2
fi
E_DONE="$(grep -m1 '^DONE_SEEN=' "$work/err.log")"
E_CH="$(grep -m1 '^AR_BURSTS=' "$work/err.log")"
if ! [ "$E_DONE" = "DONE_SEEN=0 ERR_SEEN=1 BUSY=0 GO_COUNT=1 BUSY_AT_GO2=0" ]; then
  echo "JUDGE-RED: 链长越限时应 err 而非 done：[$E_DONE]"; exit 2
fi
case "$E_CH" in
  *"AR_BURSTS=0 AW_BURSTS=0 B_OK=0") : ;;
  *) echo "JUDGE-RED: 链长越限时发了突发：[$E_CH] ⇒ 不是'发第一个 AR 之前'做的对账"; exit 2 ;;
esac
echo "   ERR_OK[+CHAINLEN=9 > L_MAX]: RTL err + 零搬运（$E_DONE；$E_CH）"

echo "---- 6b) 响亮 err[FLAGS[7:2] 保留位非 0]：w0=0x$V0（bit2=1）⇒ 非法编码 ⇒ RTL err + 零搬运 ----"
SIM_CHLEN=1
run_sim sim.vvp resv "$work/wgt0.hex" "$work/wgt1.hex" "$work/wgt2.hex" "$work/wgt3.hex" \
  "$V0" "$V1" "$V2" "$V3" "$V4" "$V5" "$V6" "$V7" "+EXPECT_ERR"
VRC=$?
grep -E '^(RESULT|DONE_SEEN|RD_BYTES_PEAK|AR_BURSTS|MEM )' "$work/resv.log" | sed 's/^/   /' || true
if [ "$VRC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/resv.log"; then
  echo "JUDGE-RED: 保留位非 0 时装置没按预期 err 且零搬运（vvp rc=$VRC）⇒ 保留位对账没接在回路上"; exit 2
fi
V_DONE="$(grep -m1 '^DONE_SEEN=' "$work/resv.log")"
V_CH="$(grep -m1 '^AR_BURSTS=' "$work/resv.log")"
if ! [ "$V_DONE" = "DONE_SEEN=0 ERR_SEEN=1 BUSY=0 GO_COUNT=1 BUSY_AT_GO2=0" ]; then
  echo "JUDGE-RED: 保留位非 0 时应 err 而非 done：[$V_DONE]"; exit 2
fi
case "$V_CH" in
  *"AR_BURSTS=0 AW_BURSTS=0 B_OK=0") : ;;
  *) echo "JUDGE-RED: 保留位非 0 时发了突发：[$V_CH]"; exit 2 ;;
esac
echo "   ERR_OK[FLAGS[7:2] != 0]: RTL err + 零搬运（$V_DONE；$V_CH）"

# ---------------- 7) 实例计数 / 网表规模（给 C3.13 面积闸门起点）----------------
#   ★ C4a.5b 重锚（**与本次宽层数值修复无关的既有口径过时**，A/B 已证）：`UnitExec` 自身仍是
#     `L_MAX` 片 `Conv3x3Slice`，但**宽层通路**（`WIDERUN`）例化的 `MultiPassUnit` **内部自带 1 片**
#     ⇒ 网表文本里的 `Conv3x3Slice` **例化点**数 = **`L_MAX + 1`**。
#     A/B 证据：把 `rtl/UnitExec.scala` 回到 `HEAD`（宽层数值修复之前）重生成，文本计数**同样是 9**
#     （`HEAD^` 那版 `MultiPassUnit.scala` 已经在 `UnitExec` 里被例化）⇒ 这条判据在 HEAD 上就是红的，
#     不是本次修复引入的。
#     ★★ C4a-R2（2026-10-11，**显式重锚**）：requant 改成三级流水后，`>>> 3'd6` 在网表里**已不存在**
#     （`((prod>>24)>>6)` 折叠成常量 `RQ=30`）。新写法 `(pLoR >>> 5'd30) + ({2'd0,pHiR} <<< 2'd2)`
#     ⇒ 文本指纹改数**配套的两处常量**：`>>> 5'd30` **恰好 8** 处、`<<< 2'd2` **恰好 8** 处
#     （单份 `Conv3x3Slice` 模块定义里 8 个输出通道各一份半积；与例化点数无关）。判据语义一字未改。
#     ★★ T-S3g/A'-1（2026-10-15，**再次显式重锚**，两处锚位腐坏的修复 —— T-S3f 报告已如实记账）：
#       · `<<< 2'd2` 的全网表命中从 8 变成 **9**：多出来的那一处**不在** `Conv3x3Slice` 里，而是
#         T-S3b 的**宽路 per-plane band** 在 `UnitExec` 顶层引入的平面字偏移 `cl*4`（= `cl <<< 2`，
#         `UnitExec.scala` 的 `xwBuf(cl*4 + wxIdxW/wxPIDX...)`）。原判据的本意是"**单份 `Conv3x3Slice`
#         定义里** 8 个 requant 站点" ⇒ 把两处常量的**计数作用域收敛到 `Conv3x3Slice` 模块体内**
#         （`module Conv3x3Slice ... endmodule`），两处仍**各 8**，判据语义恢复为原意、且对未来
#         `UnitExec` 顶层的其它 `<<< 2` 站点**免疫**。
#       · `WeightStore` 例化点的文本锚从 `^  WeightStore( #\(|...)` 改成认**参数后缀名**
#         `WeightStore_8 ws (`（SpinalHDL 对带参子模块按 `名字_参数` 落名）—— 旧正则命中 **0**
#         （= 锚腐坏，打印出误导性的 `WeightStore x0`）。新判据：**单份 `Conv3x3Slice` 定义内**该例化点
#         **恰好 1**（跨例化展开后的 elaborated 数 = `Conv3x3Slice` 例化点数 × 1 = `L_MAX+1`）。
echo "---- 7) 网表规模 / 实例计数（gen/UnitExec_w32.v；L_MAX=$LMAX）----"
NLBYTES="$(wc -c < "$nl" | tr -d ' ')"
NLLINES="$(wc -l < "$nl" | tr -d ' ')"
N_SLICE="$(grep -cE '^  Conv3x3Slice( #\(|[[:space:]]+[A-Za-z_])' "$nl")"
N_FBUF="$(grep -cE '^  FusionBuf( #\(|[[:space:]]+[A-Za-z_])' "$nl")"
N_WSTORE="$(grep -cE '^  WeightStore(_[0-9]+)?[[:space:]]+[A-Za-z_]' "$nl")"
N_SHIFT="$(awk '/^module Conv3x3Slice /,/^endmodule/' "$nl" | grep -o ">>> 5'd30" | wc -l | tr -d ' ')"
N_LEFTSHIFT="$(awk '/^module Conv3x3Slice /,/^endmodule/' "$nl" | grep -o "<<< 2'd2" | wc -l | tr -d ' ')"
N_WSTORE_IN_SLICE="$(awk '/^module Conv3x3Slice /,/^endmodule/' "$nl" | grep -cE '^  WeightStore(_[0-9]+)?[[:space:]]+[A-Za-z_]')"
echo "   netsize: lines=$NLLINES bytes=$NLBYTES"
echo "   instances(text): Conv3x3Slice x$N_SLICE  FusionBuf x$N_FBUF  WeightStore x$N_WSTORE  (requant >>>5'd30 x$N_SHIFT / <<<2'd2 x$N_LEFTSHIFT; 作用域=Conv3x3Slice 模块体)"
echo "   instances(elaborated): Conv3x3Slice x$N_SLICE (= L_MAX 自身 + 宽层 MultiPassUnit 内 1 片), FusionBuf x$N_FBUF (= L_MAX+1),"
echo "                          WeightStore x$(( N_SLICE * N_WSTORE )), LineBuffer x$N_SLICE, MacArray/GroupedMacArray x$N_SLICE"
if [ "$N_SLICE" != "$(( LMAX + 1 ))" ] || [ "$N_FBUF" != "$(( LMAX + 1 ))" ] || [ "$N_WSTORE" != "1" ] || [ "$N_WSTORE_IN_SLICE" != "1" ] || [ "$N_SHIFT" != "8" ] || [ "$N_LEFTSHIFT" != "8" ]; then
  echo "JUDGE-RED: 实例计数不符（期望 Conv3x3Slice=$(( LMAX + 1 )) FusionBuf=$(( LMAX + 1 )) WeightStore=1 requant模块体内>>>5'd30=8 <<<2'd2=8；实得 Conv3x3Slice=$N_SLICE FusionBuf=$N_FBUF WeightStore=$N_WSTORE 模块体内WeightStore=$N_WSTORE_IN_SLICE >>>5'd30=$N_SHIFT <<<2'd2=$N_LEFTSHIFT）"; exit 1
fi

# ---------------- 收口 ----------------
echo "=========================================================================="
echo "正对照     = OK（CHAIN_FIN_MISMATCH=0：链输出 $OUT_BYTES B 逐字节 == 链黄金；$CL）"
echo "零 DDR 中间= OK（$MEML / $RDP / $CH（三方一致）：中间三张的 3x$MID_BYTES 读 + 3x$MID_BYTES 写都不在 DDR）"
echo "诱饵未动   = OK（DEC1/DEC2 == 预载；SRC 未改；整片只有 DST 那一区变了）"
echo "中间在片上 = OK（MID_RING_MISMATCH=0：bufs(1) 环窗 = mid0 行 6/7 + pad 行）"
echo "行锁步     = OK（MID_ROWS=TAIL_ROWS=$(( H + 1 )) = IMG_H+1；占用性自证见 rtl/UnitExec.scala 文件头）"
echo "负对照     = OK（bit0=1 ⇒ wr $OUT_BYTES->$(( 2 * OUT_BYTES ))、DEC1_UNCHANGED_BAD=$N_D1 ⇒ 两面发火）"
echo "响亮 err   = OK（chainLen>$LMAX ⇒ RTL err 且零搬运）"
echo "非退化     = OK（激活无 0；各段 distinct>=8、非 0>=1/4、非整片 clamp；黄金 != 整行/整列平移）"
echo "比较器     = OK（扰动 1 个最终黄金字节 ⇒ CHAIN_FIN_MISMATCH 恰为 1）"
echo "结构       = OK（check_dangling.py：gen/UnitExec_w32.v 零悬空）"
echo "实例计数   = Conv3x3Slice x$N_SLICE / FusionBuf x$N_FBUF / WeightStore x$((N_SLICE * N_WSTORE))（elaborated）"
echo "RESULT: PASS"
exit 0
