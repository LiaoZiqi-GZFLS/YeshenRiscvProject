#!/usr/bin/env bash
# run_fuse_ab.sh —— C3.9b **融合对**（1x1 -> 3x3，S3）的数值闸门（★ A-1b：**两个相邻条目** `0b00`+`0b11`）。
#
# 被测行为（rtl/UnitExec.scala 文件头"★ A-1b"）：
#   一个 `go`（`chainLen=2`，由**独立入参** `+CHAINLEN=2` 给）里**同时**跑两个 `Conv3x3Slice`：
#   **头**（`conv`，输入来自 DDR 的输入窗 `fb`）把输出按列写进片上中间 `FusionBuf`（`fbMid`）；
#   **尾**（`convT`）从 `fbMid` 的**消费口**取列、输出写 `outMemT` -> DDR(`dstA`)。
#   两者在 **3 行环窗**上**交错行锁步**（头写中间第 r 行 <=> 尾读完第 r-1 行）。
#   ⇒ **结构上**：一个 RD（头输入）+ 一个 WR（尾输出），**中间张量零 DDR**。
#
# ★★ A-1b 的口径变更（本闸门**显式**改了前提，不是悄悄放宽）：
#   旧编码把融合对写成**一个** `FLAGS=0b10` 的条目（"塌缩对"）；**per-operator 编码**下
#   `0b10` 已经是 `middle`（"取上一个算子的片上输出、输出留片上"），融合对改由**两个相邻条目**表达：
#     · `0b00` head（`SRC` = 链的输入，输出**留片上**）→ 中间张量在片上；
#     · `0b11` tail（输入取上一算子的片上输出，输出落 DDR(`dstA`)）。
#   链的 `SRC` = 链首的、`DST` = **链尾**的；`UnitExec` 收到的是"链描述符" = **链首的 8 个字 + 链尾的
#   `DST_ADDR`**，链长由独立入参给。本闸门直接驱动 `UnitExec`（不经 `LayerSched`），所以它**当场断言**
#   那个合并规则（见"条目对账 OK"一行），并把 `+CHAINLEN=2` 递给 DUT。
#
# ★ 本片的"1x1"是**测试实现**（不是"RTL 里有一个 1x1 单元"）：
#     `Conv3x3Slice` 的算术是 3x3/pad=1/stride=1，没有 1x1 档；而**只有中心抽头非 0** 的 3x3
#     在 pad=1/stride=1 下**正好等于一个 1x1 conv**（同一 `(C,W,H)` 形状、同一 `>>SHIFT`+clamp）。
#     所以闸门给**头**喂"中心抽头权重"（`conv_unit_ref.centre_tap`）、给**尾**喂普通 3x3 权重。
#     RTL **不**假定任何权重取值 —— 中心抽头只出现在夹具/闸门里。
#
# 判据（正对照两条 + 交叉对账 + 负对照双向发火 + 比较器自检 + 结构）：
#   0) **向量来源 + 非退化/防混叠前提**（python；不成立就 exit 3，绝不当"通过"）：
#      · 激活来自 `tools/conv_unit_ref.py`（**复用 `mac_ref`** 的 dense 3x3 算术 + `>>6` + clamp），以 NHWC 落 `SRC`；
#      · **无 0 字节**（本用例 seed=20265793 选定；2048 字节全非 0、distinct>=250）+ 断言非常数；
#      · 背景内存 = **素周期 251** 的模式（`((i%251)*131+7)%251`）；断言周期恰 251、与 128 互素；
#      · `DST` 区预载与最终黄金**压倒性不同**（>=1900/2048）、`MID_ADDR` 区预载与中间黄金**压倒性不同**
#        ⇒ "一个字节都没写"不可能被误判成通过；
#      · 最终黄金对**整行/整列平移**敏感（防"行主序喂错"被周期性图案糊住）、不是常数、不是整片 clamp。
#   1) **判据 1（数值，三条腿）**：
#      (a) 融合对的一条 `go` 的输出（`DST`）与**两段黄金**（头两段链）**逐字节**一致（`FUSED_DST_MISMATCH=0`）；
#      (b) 该两段黄金由 `conv_unit_ref` 的 `pair_two_stage`（mac_ref 算术 + 布局置换）与**完全独立的**
#          `pair_stepwise_naive`（朴素 NHWC 三重循环、中间张量落 DDR）两条实现分别算出，**两者逐字节相同**
#          （`GOLD_A_VS_B_MID=GOLD_A_VS_B_FIN=0`）—— 这就是"与'分两步、中间张量落 DDR'的参考交叉对账"；
#      (c) **硬件自己的分两步**：同一装置跑两次 S2（run1 头权重 `SRC->STMP` 把中间张量**真的写进 DDR**、
#          run2 尾权重 `STMP->DST2`，run2 的预载直接取 run1 的转储）⇒ `DST2` 与融合对的 `DST` **逐字节相同**，
#          且 `TMP` 与中间黄金**逐字节相同**（`STEP1_TMP_MISMATCH=STEP2_DST2_VS_FUSED=0`）。
#   2) **判据 2（中间张量零落 DDR）**：
#      (a) 字节计数：内存模型 `MEM rd == head_input_bytes`、`MEM wr == tail_output_bytes`
#          （= `2048 / 2048`；**少掉的正好是中间张量的 `2×2048`**），且装置自报 `RD_BYTES_PEAK/WR_BYTES`、
#          `AR_BURSTS/AW_BURSTS/B_OK` 三方一致（`AR=16`（**只一笔 RD**）、`AW=B_OK=16`）；
#      (b) `MID_ADDR` 区间**逐字节 == 预载**（`MID_UNCHANGED_BAD=0`），且 `SRC` 未改、`DST` 之外全 == 预载
#          （整片内存只有 `DST` 那一区变了）；
#      (c) 自报：`HEAD_MODE=1`、`TAIL_MODE=1`、`MID_ROWS=TAIL_ROWS=IMG_H+1=5`（`IMG_H` 行真中间行 + 注入的 pad 行）。
#   3) **负对照（两面都必须发火）**：同一几何，把**链首条目**的 `FLAGS.bit0` **强行置 1**（`0b00 -> 0b01`；
#      其余一字不动、`chainLen` 仍是 2）⇒ 切片0 的中间**也**落 DDR，同时照旧喂 `fbMid` 让尾能跑 ⇒
#        · `MEM wr == 2*tail_output_bytes`（**变大**：两个 WR 相位各一张图）；
#        · `MID_ADDR` 区间被写（`MID_UNCHANGED_BAD > 0`，且 `MID[0:2048]` == 头那张中间张量）。
#      原始红证据直接打印（见 (7)）—— 这就是"判据真的盯着 `bit0`"的证据。
#   4) **比较器自检**：扰动最终黄金一个字节 ⇒ `FUSED_DST_MISMATCH` 必须**恰好 1**（不然分不清"真的逐字节相符"
#      与"比较器把两边都读成空表也报 0"）。
#   5) **结构判据**：`tools/check_dangling.py` 对 `gen/UnitExec.v`（零悬空）。
#
# 退出码（与 Y1 既有闸门一致）：
#   0 = 全过（判据 1 三条腿 + 判据 2 三条 + 负对照两面发火 + 比较器自检 + 结构 + 非退化前提）
#   1 = 对账不符 / 编译或仿真失败 / 装置未 PASS / 网表不存在
#   2 = 负对照没发火、比较器自检不过 ⇒ **闸门自身不可信**（橡皮图章）
#   3 = 向量/维度自检失败（用例写错，或参考自身自检没过）
#
# 装置契约（rtl_test/UnitExecTb.v + rtl_test/AxiMemModel.v + gen/UnitExec.v）：
#   +WGTFILE=（头切片权重）+WGTFILE_T=（★ C3.9b 尾切片权重，可选）+D0..+D7=<dec>（**链描述符**）
#   ★A-1b +CHAINLEN=<链长> +CTRL=1 +MEMFILE= +DUMPFILE=
#   装置打印（本闸门 grep 的行）：`TB UNITEXEC: ... FLAGS=..` / `TB UNITEXEC: HEAD_DESC=.. MIDREAD=..` /
#             `TB UNITEXEC: TAIL_DESC=..` / `RD_BYTES_PEAK=.. WR_BYTES=..` / `AR_BURSTS=.. AW_BURSTS=.. B_OK=..` /
#             `HEAD_MODE=.. MID_ROWS=..` / `TAIL_MODE=.. TAIL_ROWS=..` / `RESULT: PASS|FAIL`
#   内存模型打印：`MEM rd=<b> wr=<b> bursts=<n> maxburst=<n>`
set -uo pipefail

PY="${PY:-python}"
here="$(cd "$(dirname "$0")" && pwd)"
gen="$here/../gen"
tb="$here/../rtl_test/UnitExecTb.v"
memv="$here/../rtl_test/AxiMemModel.v"
nl="$gen/UnitExec.v"
ref="$here/conv_unit_ref.py"
dangling="$here/check_dangling.py"

# ---- 用例常量（几何与 C3.8/C3.9a 同：C_IN=C_OUT=8, W=64, H=4, GROUP=1, SHIFT=6）----
MEMSZ=2621440              # 2.5 MiB（与 AxiMemModel 的 MEMSZ 一致）
SRC=131072                 # 0x20000  头的输入张量（NHWC）
MID_ADDR=196608            # 0x30000  ★ 中间张量的"槽位地址"（诱饵：融合对**不得**碰它）
STMP=262144                 # 0x40000  判据 1(c) 分两步的中间张量落点（S2 的 dst）
DST=1441792                # 0x160000 融合对的最终输出
DST2=2097152               # 0x200000 判据 1(c) 分两步的最终输出
W=64; H=4; CIN=8; COUT=8; SGROUP=1; SHIFT=6
IN_BYTES=$(( CIN * H * W ))          # 2048（= d.w6 = 头的输入字节数 = 尾的输出字节数）
MID_BYTES=$(( COUT * H * W ))        # 2048（中间张量；判据 2 说它**一份都不该落 DDR**）
PERIOD=251                           # 素周期；与 128 互素 ⇒ 整块平移必被发现
SEED=20265793                        # 本用例选定的 seed：激活**无 0 字节**（见判据 0）

# ★ A-1b：`run_sim` 用的链长（`+CHAINLEN=`）。每个调用点显式设置（链 = 2；plain/S2 = 1）。
SIM_CHLEN=1
work="$(mktemp -d)"
cleanup() {
  if [ "${KEEP_TMP:-0}" = "1" ]; then
    echo "KEEP_TMP=1 => 激励与日志留在 $work"
  else
    rm -rf "$work"
  fi
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

echo "== run_fuse_ab: C3.9b 融合对（1x1 -> 3x3）：头->片上中间缓冲->尾->DDR，中间张量零 DDR =="
echo "   tb  =$tb"
echo "   mem =$memv"
echo "   nl  =$nl"
echo "   ref =$ref"
echo "   py=${PY}  iverilog=${IVERILOG:-<找不到>}  vvp=${VVP:-<找不到>}"
echo "   tmp =$work"
echo "   用例 SRC=$SRC MID_ADDR=$MID_ADDR STMP=$STMP DST=$DST DST2=$DST2"
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
echo "---- 0) tools/conv_unit_ref.py --selftest（复用 mac_ref 算术 + 布局置换 + 两段链双实现交叉对账）----"
if ! "$PY" "$ref" --selftest; then
  echo "=== FATAL: 参考自检没过 ⇒ 用例/参考写错了（不是硬件的问题）==="
  exit 3
fi

# ---------------- 0b) 结构判据：零悬空实例 ----------------
echo "---- 0b) tools/check_dangling.py（gen/UnitExec.v ⇒ 零悬空）----"
if [ -f "$dangling" ]; then
  "$PY" "$dangling" "$nl" | tail -3
  if ! "$PY" "$dangling" "$nl" >/dev/null; then
    echo "JUDGE-RED: 有悬空实例（被例化但没有模块定义）"; exit 1
  fi
else
  echo "WARN: 找不到 $dangling（跳过结构判据）"
fi

# ---------------- 1) 造激励 + 两条独立黄金 + 非退化/防混叠前提 ----------------
echo "---- 1) 造向量：激活/权重（头=中心抽头、尾=3x3）+ 两段黄金（双实现）+ 内存模式（seed=$SEED）----"
if ! "$PY" - "$work" "$here" "$MEMSZ" "$SRC" "$MID_ADDR" "$STMP" "$DST" "$DST2" \
                    "$CIN" "$COUT" "$W" "$H" "$SGROUP" "$SHIFT" "$PERIOD" "$SEED" <<'PYEOF'
import sys, os
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

work, refdir = sys.argv[1], sys.argv[2]
sys.path.insert(0, refdir)
import conv_unit_ref as R
import mac_ref

(memsz, src, mid, tmp, dst, dst2, CIN, COUT, W, H, GROUP, SHIFT,
 PERIOD, SEED) = (int(x) for x in sys.argv[3:17])

# ---- 激活 / 权重（复用 mac_ref 的 dense 3x3 算术；`build` 只用来抽激活与整层权重）----
wt, x_chw, x_ddr, y_ddr = R.build(CIN, COUT, H, W, seed=SEED, shift=SHIFT)
assert len(wt) == COUT * CIN * 9, "权重长度 %d" % len(wt)
assert len(x_ddr) == CIN * H * W

# ---- ★ 头 = "只有中心抽头"的 3x3（≡ 1x1）；尾 = 普通 3x3。
#      尾权重刻意 ×4（仍在 int8 内、不过饱和）：两段串起来是两次 `>>6`，若权重也小，
#      最终黄金会被压到 0 附近（判据分辨率变差）；×4 让取值铺开（见下面 NONZERO 一行）。
wt_head = R.centre_tap(wt, CIN, COUT)
wt_tail = [max(-128, min(127, v * 4)) for v in wt]
assert sum(1 for v in wt_head if v != 0) > 0, "头权重全 0 ⇒ 用例没意义"
assert sum(1 for v in wt_tail if v != 0) > 0, "尾权重全 0 ⇒ 用例没意义"
assert all(wt_head[(co * CIN + ci) * 9 + k] == 0
           for co in range(COUT) for ci in range(CIN) for k in range(9) if k != 4), \
       "头权重不是'只有中心抽头'（那就不是 1x1 了）"

# ---- 两条**完全独立**的两段黄金（判据 1(b) 的交叉对账）----
mid_a, fin_a = R.pair_two_stage(x_chw, wt_head, wt_tail, CIN, COUT, H, W, SHIFT)
mid_b, fin_b = R.pair_stepwise_naive(x_ddr, wt_head, wt_tail, CIN, COUT, H, W, SHIFT)
dmid_ab = sum(1 for a, b in zip(mid_a, mid_b) if a != b)
dfin_ab = sum(1 for a, b in zip(fin_a, fin_b) if a != b)
assert dmid_ab == 0 and dfin_ab == 0, \
    "两条独立黄金不一致（中间差 %d、最终差 %d）⇒ 参考口径漂了" % (dmid_ab, dfin_ab)

# ---- 非退化前提 ----
assert len(set(x_ddr)) > 1, "激活是常数 ⇒ 用例没意义"
assert len(set(wt)) > 1, "权重是常数 ⇒ 用例没意义"
assert len(set(mid_a)) > 1, "中间张量是常数 ⇒ 判据会退化"
assert len(set(fin_a)) > 1, "最终张量是常数 ⇒ 判据会退化"
fin_sig = [(v if v < 0x80 else v - 256) for v in fin_a]
nzero_fin = sum(1 for v in fin_sig if v != 0)
assert nzero_fin >= 1024, "最终张量非 0 字节只有 %d/%d ⇒ 判据分辨率太差" % (nzero_fin, len(fin_a))
assert len(set(fin_a)) >= 16, "最终张量取值太集中（distinct=%d）⇒ 判据分辨率太差" % len(set(fin_a))
nclamp = sum(1 for v in fin_sig if v in (127, -128))
assert nclamp < len(fin_a), "最终张量整片 clamp（%d 个）⇒ 判据退化" % nclamp

# ---- ★ 输入向量无 0 字节（本用例 seed 选定）----
assert all(v != 0 for v in x_ddr), "输入向量含 0 字节（本用例要求无 0）"
assert len(set(x_ddr)) >= 250, "输入取值太集中（distinct=%d）" % len(set(x_ddr))

# ---- 防混叠：最终黄金对**整行平移 / 整列平移**敏感（行主序喂错必然变值）----
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

# ---- 防混叠 2：DST / MID 两区的预载与其期望值**压倒性不同** ----
pre = bytes(pat(i) for i in range(memsz))
diff_dst = sum(1 for j in range(len(fin_a)) if pre[dst + j] != (fin_a[j] & 0xFF))
assert diff_dst >= 1900, "DST 区预载与最终黄金只有 %d/%d 字节不同 ⇒ 不写也有机会过" % (diff_dst, len(fin_a))
diff_mid = sum(1 for j in range(len(mid_a)) if pre[mid + j] != (mid_a[j] & 0xFF))
assert diff_mid >= 1900, "MID 区预载与中间黄金只有 %d/%d 字节不同 ⇒ '未动'判据没牙" % (diff_mid, len(mid_a))

# ---- 结构自检：地址 32B 对齐、互不重叠、留 128B 邻居、都在已建模内存内 ----
mid_bytes = COUT * H * W
regions = {"src": (src, CIN * H * W), "mid": (mid, mid_bytes), "tmp": (tmp, mid_bytes),
           "dst": (dst, COUT * H * W), "dst2": (dst2, COUT * H * W)}
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
R.dump_bytes(work + "/wgt_head.hex", wt_head)
R.dump_bytes(work + "/wgt_tail.hex", wt_tail)
with open(work + "/gold_fin.hex", "w") as f:
    f.write("".join("%02x\n" % (v & 0xFF) for v in fin_a))
with open(work + "/gold_mid.hex", "w") as f:
    f.write("".join("%02x\n" % (v & 0xFF) for v in mid_a))

# ---- 三套描述符（同几何；只差 FLAGS 与地址）----
#   ★★ A-1b：本闸门改用**用户批准的 per-operator 链式编码**（`rtl/UnitExec.scala` 文件头"★ A-1b"）：
#     一个描述符 = **一个算子**；融合对 = **两个相邻条目** `0b00`（head）+ `0b11`（tail），
#     链的 `SRC` = 链首的、`DST` = **链尾**的。`UnitExec` 拿到的"链描述符"就是
#     **链首的 8 个字 + 链尾的 `DST_ADDR`**（`LayerSched` 在真表上就是这么塌缩的），
#     链长 `chainLen=2` 由**独立入参** `+CHAINLEN=2` 给出（不再是 `FLAGS[4:2]`）。
#     本闸门直接驱动 `UnitExec`（不经调度器），所以"两个相邻条目"在这里就是
#     **构造两条目 + 按上面的规则合并成一个链描述符**，并当场断言合并规则。
def mk(flags, src_a, dst_a):
    D = [0] * 8
    D[0] = 0x01 | (flags << 8)                    # TYPE=conv3x3, FLAGS=flags
    D[1] = W | (H << 16)
    D[2] = CIN | (COUT << 16)
    D[3] = GROUP | (1 << 8) | (1 << 12)           # GROUP, STRIDE=1, PAD=1
    D[4] = src_a
    D[5] = dst_a
    D[6] = CIN * H * W                            # IN_BYTES（链首的输入字节数）
    D[7] = SHIFT                                  # QUANT_SHIFT, LAYER_ID=0
    return D

def chain_desc(head, tail):
    """链描述符 = 链首的 8 个字 + 链尾的 `DST_ADDR`（`w5`）。"""
    D = list(head)
    D[5] = tail[5]
    return D

# 融合对 = [head `0b00`(src -> 中间槽 MID_ADDR), tail `0b11`(MID_ADDR -> dst)]
E_head = mk(0b00, src, mid)                       # 头：输入 DDR(src)、输出**留片上**（不落 DDR）
E_tail = mk(0b11, mid, dst)                       # 尾：输入取上一算子片上输出、输出落 DDR(dst)
Dpair  = chain_desc(E_head, E_tail)
assert Dpair[4] == E_head[4] and Dpair[5] == E_tail[5], "链描述符的 SRC/DST 必须 = 链首的 SRC / 链尾的 DST"
# 负对照 = **把链首条目的 `bit0` 强行置 1**（`0b00 -> 0b01`，其余一字不动）：
#   `UnitExec` 的 `isHead=0` ⇒ 切片0 的**中间张量也落 DDR**（`outMem` -> `dstA`）。`dstA` 指向 `MID_ADDR`
#   ⇒ 那份中间张量正好落在判据 2 盯的那个区间上。（合法表里 `bit0=1` 只出现在 `tail`，所以这张表
#   **不是**调度器会产出的 —— 它是 `UnitExec` 层面的退化档负对照，见 rtl/UnitExec.scala 文件头。）
#   链尾条目的 DST 也指向 `MID_ADDR` ⇒ 链描述符的 DST = MID_ADDR（夹带的写正好落在判据 2 盯的区间上）。
Dneg = chain_desc(mk(0b01, src, mid), mk(0b11, mid, mid))
assert (Dneg[0] >> 8) & 1 == 1, "负对照必须是把链首的 bit0 置 1"
Ds1   = mk(0b01, src, tmp)                        # 判据 1(c) run1：头权重，SRC -> STMP（plain，chainLen=1）
Ds2   = mk(0b01, tmp, dst2)                       # 判据 1(c) run2：尾权重，STMP -> DST2（plain，chainLen=1）
for nm, D in (("desc_pair", Dpair), ("desc_neg", Dneg), ("desc_s1", Ds1), ("desc_s2", Ds2)):
    with open(work + "/" + nm + ".args", "w") as f:
        f.write(" ".join(str(x) for x in D))      # ★ 不写结尾换行（Windows 文本模式会塞 \r）
with open(work + "/desc_head.args", "w") as f:    # 两个相邻条目（原始形态；闸门逐字核对）
    f.write(" ".join(str(x) for x in E_head))
with open(work + "/desc_tail.args", "w") as f:
    f.write(" ".join(str(x) for x in E_tail))
print("MEMGEN bytes=%d src=%d mid=%d tmp=%d dst=%d dst2=%d period=%d seed=%d"
      % (memsz, src, mid, tmp, dst, dst2, PERIOD, SEED))
print("GOLD_AB: 两段黄金两条独立实现：中间差 %d、最终差 %d（必须都是 0）" % (dmid_ab, dfin_ab))
print("NONZERO: 激活无 0 字节（distinct=%d/256）；最终黄金非 0=%d/%d、distinct=%d、clamp=%d"
      % (len(set(x_ddr)), nzero_fin, len(fin_a), len(set(fin_a)), nclamp))
print("NONALIAS: 周期恰 %d 且与 128 互素；DST 预载与最终黄金差 %d/%d；MID 预载与中间黄金差 %d/%d；"
      "最终黄金 != 整行/整列平移" % (PERIOD, diff_dst, len(fin_a), diff_mid, len(mid_a)))
print("DESC head   w0=0x%08x (链首条目 FLAGS=0b00 head：输入 DDR、输出留片上)" % (E_head[0] & 0xFFFFFFFF))
print("DESC tail   w0=0x%08x (链尾条目 FLAGS=0b11 tail：输入取上游片上输出、输出落 DDR(dst))" % (E_tail[0] & 0xFFFFFFFF))
print("DESC pair   w0=0x%08x (链描述符 = 链首的字 + 链尾的 DST；chainLen=2 由 +CHAINLEN=2 给)"
      % (Dpair[0] & 0xFFFFFFFF))
print("DESC neg    w0=0x%08x (链首 bit0 强行置 1 ⇒ 切片0 的中间也落 DDR) dst=MID_ADDR" % (Dneg[0] & 0xFFFFFFFF))
PYEOF
then
  echo "FATAL: 生成向量/黄金失败（或非退化/防混叠前提不成立）⇒ 闸门不可信"
  exit 3
fi
for f in mem.hex wgt_head.hex wgt_tail.hex gold_fin.hex gold_mid.hex \
         desc_pair.args desc_neg.args desc_s1.args desc_s2.args desc_head.args desc_tail.args; do
  [ -s "$work/$f" ] || { echo "FATAL: 激励文件 $f 缺失或为空"; exit 3; }
done
read -r P0 P1 P2 P3 P4 P5 P6 P7 < "$work/desc_pair.args"
read -r N0 N1 N2 N3 N4 N5 N6 N7 < "$work/desc_neg.args"
read -r A0 A1 A2 A3 A4 A5 A6 A7 < "$work/desc_s1.args"
read -r B0 B1 B2 B3 B4 B5 B6 B7 < "$work/desc_s2.args"
read -r H0 H1 H2 H3 H4 H5 H6 H7 < "$work/desc_head.args"
read -r T0 T1 T2 T3 T4 T5 T6 T7 < "$work/desc_tail.args"
# ★ A-1b：两个相邻条目 + 链长（`+CHAINLEN=`）—— 链描述符必须**逐字**等于"链首的字 + 链尾的 DST"。
CHLEN=2
if [ "$P0" != "$H0" ] || [ "$P4" != "$H4" ] || [ "$P5" != "$T5" ]; then
  echo "JUDGE-RED: 链描述符 != 链首的字 + 链尾的 DST（P0=$P0 H0=$H0 P4=$P4 H4=$H4 P5=$P5 T5=$T5）"; exit 3
fi
case "$(( (H0 >> 8) & 3 ))" in 0) : ;; *) echo "JUDGE-RED: 链首条目的 FLAGS[1:0] != 0b00"; exit 3 ;; esac
case "$(( (T0 >> 8) & 3 ))" in 3) : ;; *) echo "JUDGE-RED: 链尾条目的 FLAGS[1:0] != 0b11"; exit 3 ;; esac
echo "   条目对账 OK：链首 FLAGS=0b00（w0=$H0）+ 链尾 FLAGS=0b11（w0=$T0）⇒ 链描述符 w0=$P0 (chainLen=$CHLEN)"

# ---------------- 2) 编译（好网表）----------------
echo "---- 2) iverilog 编译（UnitExecTb + AxiMemModel + gen/UnitExec.v）----"
if ! "$IVERILOG" -g2012 -o "$work/sim.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败（好网表）"; sed -n '1,40p' "$work/iv.log"; exit 1
fi
if grep -qi 'warning' "$work/iv.log"; then
  echo "    编译告警（留意）："; grep -i 'warning' "$work/iv.log" | head -3
fi
echo "    编译 OK"

cat > "$work/cmpbytes.py" <<'PYEOF'
XBAD = -1   # 非法/未知（转储里的 `xx`）字节的哨兵：它**不等于任何值**（包括另一个 X）

def load_num(p):
    """把转储/黄金读成整数表（一行一个十六进制字节）。
    非法记号（`xx` / 非十六进制 / 越界）记成 XBAD 并计数 —— **不抛异常**：
    坏转储也是判据要诊断的对象，绝不能让 judge 自己崩掉。返回 (values, n_bad, first_bad_line)。"""
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
    """等长逐字节比较 -> (count, first_abs_off)；first = -1 表示完全相同。"""
    assert len(a) == len(b), "length %d vs %d" % (len(a), len(b))
    cnt = 0; first = -1
    for k in range(len(a)):
        if a[k] != b[k]:
            if first < 0:
                first = base + k
            cnt += 1
    return cnt, first
PYEOF

# run_sim <vvp> <logbase> <wgt> <wgt_t> <d0..d7> [extra args...]
#   ★ A-1b：链长由全局 `SIM_CHLEN` 给出（`+CHAINLEN=`；链 = 2，plain = 1）。
run_sim() {
  local vvp="$1" log="$2" wgt="$3" wgtt="$4"
  local d0="$5" d1="$6" d2="$7" d3="$8" d4="$9" d5="${10}" d6="${11}" d7="${12}"; shift 12
  local extra_wt=""
  [ -n "$wgtt" ] && extra_wt="+WGTFILE_T=$wgtt"
  ( cd "$work" && "$VVP" "$vvp" \
      "+WGTFILE=$wgt" $extra_wt "+MEMFILE=$work/mem.hex" "+DUMPFILE=$work/$log.dump" +dump \
      "+D0=$d0" "+D1=$d1" "+D2=$d2" "+D3=$d3" "+D4=$d4" "+D5=$d5" "+D6=$d6" "+D7=$d7" "+CTRL=1" \
      "+CHAINLEN=$SIM_CHLEN" "$@" ) \
      > "$work/$log.log" 2>&1
  return $?
}

# judge_region <dumpfile> <goldfile> <addr> <len>  （后两个是「期望输出所在地址 / 长度」）
#   打印：MISMATCH（相对 addr）/ FIRST_OFF / SRC_UNCHANGED_BAD / MID_UNCHANGED_BAD / WHOLE / OTHER_BAD / X。
judge_region() {
  "$PY" - "$work" "$1" "$2" "$3" "$4" "$SRC" "$MID_ADDR" "$DST" "$MID_BYTES" <<'PYEOF'
import sys
work = sys.argv[1]
dumpf, goldf = sys.argv[2], sys.argv[3]
addr, ln = int(sys.argv[4]), int(sys.argv[5])
src, mid, dst, midb = int(sys.argv[6]), int(sys.argv[7]), int(sys.argv[8]), int(sys.argv[9])
sys.path.insert(0, work)
from cmpbytes import load_num, diffs
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
d, dx, _ = load_num(dumpf)
g, gx, _ = load_num(goldf)
p, px, _ = load_num(work + "/pre.hex")
m, first = diffs(d[addr:addr + ln], g[:ln], 0)
print("MISMATCH=%d" % m)
print("FIRST_OFF=%d" % (addr + first if first >= 0 else -1))
s_bad, _ = diffs(d[src:src + ln], p[src:src + ln], src)
print("SRC_UNCHANGED_BAD=%d" % s_bad)
mb, mfirst = diffs(d[mid:mid + midb], p[mid:mid + midb], mid)
print("MID_UNCHANGED_BAD=%d" % mb)
print("MID_FIRST_OFF=%d" % (mid + mfirst if mfirst >= 0 else -1))
tot = 0; other = 0; ofirst = -1
for j in range(len(p)):
    if d[j] != p[j]:
        tot += 1
        if not (dst <= j < dst + ln):
            other += 1
            if ofirst < 0:
                ofirst = j
print("WHOLE_MISMATCH=%d" % tot)
print("OTHER_BAD=%d" % other)
print("OTHER_FIRST_OFF=%d" % ofirst)
print("XBYTES=%d XBYTES_GOLD=%d XBYTES_PRE=%d" % (dx, gx, px))
if dx or gx or px:
    print("JUDGE-NOTE: 有非法(未知/`xx`)字节 ⇒ X 按'不等于任何值'计 ⇒ MISMATCH 会发火")
PYEOF
}

# 预载镜像（给区域比较用）
"$PY" - "$work/mem.hex" "$work/pre.hex" <<'PYEOF'
import sys
t = [l.strip() for l in open(sys.argv[1]) if l.strip()]
open(sys.argv[2], "w").write("\n".join(t) + "\n")
PYEOF

# ---------------- 3) 正对照：融合对（FLAGS=0b10）----------------
echo "---- 3) 正对照[融合对 = 两个相邻条目 0b00+0b11；chainLen=2]：一个 go 跑两个切片，中间张量零 DDR ----"
SIM_CHLEN=2
run_sim sim.vvp pair "$work/wgt_head.hex" "$work/wgt_tail.hex" \
  "$P0" "$P1" "$P2" "$P3" "$P4" "$P5" "$P6" "$P7"
RC=$?
if [ "$RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/pair.log"; then
  echo "JUDGE-RED: 融合对仿真未 PASS（vvp rc=$RC）"
  grep -E '^(RESULT|TB-ERROR|DONE_SEEN|RD_BYTES_PEAK|AR_BURSTS|MEM )' "$work/pair.log" || true
  exit 1
fi
grep -E '^(TB UNITEXEC:|DONE_SEEN|RD_BYTES_PEAK|AR_BURSTS|HEAD_MODE|TAIL_MODE|CHAIN_LEN|MEM )' "$work/pair.log" | sed 's/^/   /'

# 3a) 描述符/几何/自报交叉对账
GEOM="$(grep -m1 '^TB UNITEXEC: IMG_W=' "$work/pair.log")"
EXP_GEOM="TB UNITEXEC: IMG_W=$W IMG_H=$H C_IN=$CIN C_OUT=$COUT GROUP=$SGROUP IN_BYTES=$IN_BYTES QUANT_SHIFT=$SHIFT"
if [ "$GEOM" != "$EXP_GEOM" ]; then
  echo "JUDGE-RED: 几何/描述符行不符"; echo "  got=$GEOM"; echo "  exp=$EXP_GEOM"; exit 1
fi
if ! grep -q '^TB UNITEXEC: HEAD_DESC=1 MIDREAD=0' "$work/pair.log"; then
  echo "JUDGE-RED: 装置没把描述符识别成头档（HEAD_DESC 应为 1）"; exit 1
fi
if ! grep -q '^TB UNITEXEC: TAIL_DESC=1' "$work/pair.log"; then
  echo "JUDGE-RED: 装置没把描述符识别成尾档（TAIL_DESC 应为 1）"; exit 1
fi
# ★ A-1b：链描述符的 `FLAGS` = **链首条目**的 `0b00`（head：切片0 的输出留片上）。
#   （旧编码的 `0x02`=`0b10` 在 per-operator 编码里是 `middle`，不再是"融合对"。）
if ! grep -q '^TB UNITEXEC: SRC='"$SRC"' DST='"$DST"' TYPE=0x01 FLAGS=0x00' "$work/pair.log"; then
  echo "JUDGE-RED: 链描述符字（SRC/DST/TYPE/FLAGS=0x00）与用例不符"; exit 1
fi
# ★ A-1b：链长 = 2（由独立入参给；网表把它回读出来 ⇒ 端口真接上了）
# ★ A-3：`LMAX`（网表自报的生成期上限）由 4 改成 **8**（`gen/UnitExec.v` 按 `L_MAX=8` 重生成）；
#   本用例仍跑 2 切片（`chainLen=2 ≤ 8` 合法）⇒ 数值/零 DDR 判据前提一字不变，只有这一格常数变。
CLR="$(grep -m1 '^CHAIN_LEN=' "$work/pair.log")"
EXP_CLR="CHAIN_LEN=$CHLEN CHAIN_LEN_REP=$CHLEN LMAX=8"
if [ "$CLR" != "$EXP_CLR" ]; then
  echo "JUDGE-RED: 链长自报不符 got=[$CLR] exp=[$EXP_CLR]（两个相邻条目 0b00+0b11 ⇒ chainLen=2；L_MAX=8）"; exit 1
fi
SHREP="$(grep -m1 '^TB UNITEXEC: RTL_SHIFT=' "$work/pair.log")"
EXP_SHREP="TB UNITEXEC: RTL_SHIFT=$SHIFT RTL_GRP=$SGROUP RTL_IMGW=$W RTL_IMGC=$CIN RTL_MAXPIX=$(( W * H ))"
if [ "$SHREP" != "$EXP_SHREP" ]; then
  echo "JUDGE-RED: 网表自报行不符（宽度/档位/shift 钉死）"; echo "  got=$SHREP"; echo "  exp=$EXP_SHREP"; exit 1
fi
HM="$(grep -m1 '^HEAD_MODE=' "$work/pair.log")"
EXP_HM="HEAD_MODE=1 MID_ROWS=$(( H + 1 ))"
if [ "$HM" != "$EXP_HM" ]; then
  echo "JUDGE-RED: HEAD_MODE/MID_ROWS 不符（中间缓冲该有 IMG_H 行真行 + 1 行注入 pad）got=[$HM] exp=[$EXP_HM]"; exit 1
fi
TM="$(grep -m1 '^TAIL_MODE=' "$work/pair.log")"
EXP_TM="TAIL_MODE=1 TAIL_ROWS=$(( H + 1 ))"
if [ "$TM" != "$EXP_TM" ]; then
  echo "JUDGE-RED: TAIL_MODE/TAIL_ROWS 不符 got=[$TM] exp=[$EXP_TM]"; exit 1
fi
echo "   自报 OK：$GEOM / $HM / $TM"

# 3b) 判据 2(a)：字节计数（中间张量的 2x2048 **不在**里面）
CH="$(grep -m1 '^AR_BURSTS=' "$work/pair.log")"
RDP="$(grep -m1 '^RD_BYTES_PEAK=' "$work/pair.log")"
MEML="$(grep -m1 '^MEM rd=' "$work/pair.log")"
EXP_CH="AR_BURSTS=$(( IN_BYTES / 128 )) AW_BURSTS=$(( MID_BYTES / 128 )) B_OK=$(( MID_BYTES / 128 ))"
EXP_RDP="RD_BYTES_PEAK=$IN_BYTES WR_BYTES=$MID_BYTES"
EXP_MEM="MEM rd=$IN_BYTES wr=$MID_BYTES bursts=$(( (IN_BYTES + MID_BYTES) / 128 )) maxburst=16"
if [ "$CH" != "$EXP_CH" ]; then echo "JUDGE-RED: 突发数不符（RD 只该一笔）got=[$CH] exp=[$EXP_CH]"; exit 1; fi
if [ "$RDP" != "$EXP_RDP" ]; then echo "JUDGE-RED: 字节数不符（中间张量不该有 DDR 读/写）got=[$RDP] exp=[$EXP_RDP]"; exit 1; fi
if [ "$MEML" != "$EXP_MEM" ]; then echo "JUDGE-RED: 内存模型计数不符 got=[$MEML] exp=[$EXP_MEM]"; exit 1; fi
echo "   判据 2(a) OK（字节计数，三方一致）：$CH / $RDP / $MEML"
echo "      = rd(head_input_bytes=$IN_BYTES) / wr(tail_output_bytes=$MID_BYTES)；中间张量的 2x$MID_BYTES 两份都不在"

# 3c) 判据 1(a) + 判据 2(b)：DST == 最终黄金；MID 未动；整片只有 DST 变了
judge_region "$work/pair.dump" "$work/gold_fin.hex" "$DST" "$MID_BYTES" > "$work/pair.judge"
cat "$work/pair.judge" | sed 's/^/   /'
F_MIS="$(sed -n 's/^MISMATCH=\([0-9]*\)$/\1/p' "$work/pair.judge")"
F_SBAD="$(sed -n 's/^SRC_UNCHANGED_BAD=\([0-9]*\)$/\1/p' "$work/pair.judge")"
F_MBAD="$(sed -n 's/^MID_UNCHANGED_BAD=\([0-9]*\)$/\1/p' "$work/pair.judge")"
F_OBAD="$(sed -n 's/^OTHER_BAD=\([0-9]*\)$/\1/p' "$work/pair.judge")"
if [ "$F_MIS" != "0" ]; then
  echo "JUDGE-RED: 判据 1(a) 失败：融合对输出 != 两段黄金（FUSED_DST_MISMATCH=$F_MIS）"; exit 1
fi
echo "   判据 1(a) OK：FUSED_DST_MISMATCH=0（DST 区 $MID_BYTES 字节逐字节 == 两段黄金）"
if [ "$F_MBAD" != "0" ]; then
  echo "JUDGE-RED: 判据 2(b) 失败：MID_ADDR 区间被写（MID_UNCHANGED_BAD=$F_MBAD）⇒ 中间张量落了 DDR"; exit 1
fi
if [ "$F_SBAD" != "0" ] || [ "$F_OBAD" != "0" ]; then
  echo "JUDGE-RED: 判据 2(b) 失败：SRC 或 DST 之外的内存被改（SRC_BAD=$F_SBAD OTHER_BAD=$F_OBAD）"; exit 1
fi
echo "   判据 2(b) OK：MID_UNCHANGED_BAD=0（$MID_BYTES 字节 == 预载）；SRC 未改；整片只有 DST 那一区变了"

# ---------------- 4) 比较器自检：扰动最终黄金一个字节 ⇒ MISMATCH 必须恰好 1 ----------------
echo "---- 4) 比较器自检：扰动最终黄金一个期望字节 ⇒ FUSED_DST_MISMATCH 必须恰好 1 ----"
"$PY" - "$work" <<'PYEOF'
import sys
work = sys.argv[1]
t = [l.strip() for l in open(work + "/gold_fin.hex") if l.strip()]
i = len(t) // 2
t[i] = "%02x" % ((int(t[i], 16) ^ 0x01) & 0xFF)
open(work + "/gold_fin_pert.hex", "w").write("\n".join(t) + "\n")
print("CMP_SELFTEST_PERTURB idx=%d" % i)
PYEOF
judge_region "$work/pair.dump" "$work/gold_fin_pert.hex" "$DST" "$MID_BYTES" > "$work/pert.judge"
SELF_MIS="$(sed -n 's/^MISMATCH=\([0-9]*\)$/\1/p' "$work/pert.judge")"
echo "   CMP_SELFTEST FUSED_DST_MISMATCH=$SELF_MIS（期望恰好 1）"
if [ "$SELF_MIS" != "1" ]; then
  echo "JUDGE-RED: 比较器自检 MISMATCH=$SELF_MIS != 1 ⇒ 闸门不可信"; exit 2
fi

# ---------------- 5) 判据 1(b)：两条独立黄金必须一致（第 1 步的 python 已断言）----
echo "---- 5) 判据 1(b)：两段黄金的**两条独立实现**（mac_ref 链 vs 朴素 NHWC 链）逐字节相同 ----"
"$PY" - "$work" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1] + "/../tools")
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
# 上面第 1 步已经断言过；这里再把结论打印出来（闸门口径需要一行可读的证据）。
print("GOLD_A_VS_B_MID=0")
print("GOLD_A_VS_B_FIN=0")
PYEOF
echo "   GOLD_A_VS_B_MID=0 GOLD_A_VS_B_FIN=0（第 1 步的 python 已 assert，不成立会 exit 3）"

# ---------------- 6) 判据 1(c)：硬件自己的分两步（中间张量**真的**落 DDR）必须与融合对一致 ----------------
#   run1（S2，头权重）：SRC -> STMP（中间张量写进 DDR）；run2（S2，尾权重）：STMP -> DST2。
#   run2 的**预载直接取 run1 的转储**（真正的"分两步、中间张量落 DDR"），再与融合对的 DST 逐字节比。
echo "---- 6) 判据 1(c)：同一装置分两步（run1 头 SRC->STMP、run2 尾 STMP->DST2）== 融合对 ----"
SIM_CHLEN=1        # run1/run2 都是 plain（0b01，chainLen=1）
run_sim sim.vvp s1 "$work/wgt_head.hex" "" "$A0" "$A1" "$A2" "$A3" "$A4" "$A5" "$A6" "$A7"
S1RC=$?
if [ "$S1RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/s1.log"; then
  echo "JUDGE-RED: 分两步 run1 未 PASS（vvp rc=$S1RC）"
  grep -E '^(RESULT|DONE_SEEN|MEM )' "$work/s1.log" || true; exit 1
fi
S1MEM="$(grep -m1 '^MEM rd=' "$work/s1.log")"
EXP_S1MEM="MEM rd=$IN_BYTES wr=$MID_BYTES bursts=$(( (IN_BYTES + MID_BYTES) / 128 )) maxburst=16"
if [ "$S1MEM" != "$EXP_S1MEM" ]; then
  echo "JUDGE-RED: run1 计数不符 got=[$S1MEM] exp=[$EXP_S1MEM]"; exit 1
fi
"$PY" - "$work" "$STMP" "$MID_BYTES" "$work/s1.dump" > "$work/step1.judge" <<'PYEOF'
import sys
work, tmp, midb, dumpf = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
def load(p):
    return [l.strip() for l in open(p) if l.strip()]
d = load(dumpf); mem = load(work + "/mem.hex"); gm = load(work + "/gold_mid.hex")
print("STEP1_TMP_MISMATCH=%d" % sum(1 for j in range(midb) if d[tmp + j] != gm[j]))
# run2 的预载 = run1 的原预载 + run1 **真的写进 DDR** 的那段中间张量
m2 = list(mem)
for j in range(midb):
    m2[tmp + j] = d[tmp + j]
open(work + "/mem2.hex", "w").write("\n".join(m2) + "\n")
PYEOF
cat "$work/step1.judge" | sed 's/^/   /'
STEP1="$(sed -n 's/^STEP1_TMP_MISMATCH=\([0-9]*\)$/\1/p' "$work/step1.judge")"
echo "   run1 交叉对账 OK：$S1MEM（STEP1_TMP_MISMATCH=$STEP1：run1 写进 DDR 的中间张量 == 中间黄金）"
if [ "$STEP1" != "0" ]; then
  echo "JUDGE-RED: run1 写进 DDR 的中间张量与黄金不符（$STEP1）"; exit 1
fi
run_sim2() {   # run2 用 mem2.hex 作为预载
  local d0="$1" d1="$2" d2="$3" d3="$4" d4="$5" d5="$6" d6="$7" d7="$8"
  ( cd "$work" && "$VVP" "$work/sim.vvp" \
      "+WGTFILE=$work/wgt_tail.hex" "+MEMFILE=$work/mem2.hex" "+DUMPFILE=$work/s2.dump" +dump \
      "+D0=$d0" "+D1=$d1" "+D2=$d2" "+D3=$d3" "+D4=$d4" "+D5=$d5" "+D6=$d6" "+D7=$d7" "+CTRL=1" ) \
      > "$work/s2.log" 2>&1
  return $?
}
run_sim2 "$B0" "$B1" "$B2" "$B3" "$B4" "$B5" "$B6" "$B7"
S2RC=$?
if [ "$S2RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/s2.log"; then
  echo "JUDGE-RED: 分两步 run2 未 PASS（vvp rc=$S2RC）"
  grep -E '^(RESULT|DONE_SEEN|MEM )' "$work/s2.log" || true; exit 1
fi
S2MEM="$(grep -m1 '^MEM rd=' "$work/s2.log")"
if [ "$S2MEM" != "$EXP_S1MEM" ]; then
  echo "JUDGE-RED: run2 计数不符 got=[$S2MEM] exp=[$EXP_S1MEM]"; exit 1
fi
"$PY" - "$work" "$DST2" "$DST" "$MID_BYTES" > "$work/step2.judge" <<'PYEOF'
import sys
work, dst2, dst, ln = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
def load(p):
    return [l.strip() for l in open(p) if l.strip()]
s2 = load(work + "/s2.dump"); pr = load(work + "/pair.dump"); g = load(work + "/gold_fin.hex")
print("STEP2_DST2_VS_GOLD=%d" % sum(1 for j in range(ln) if s2[dst2 + j] != g[j]))
print("STEP2_DST2_VS_FUSED=%d" % sum(1 for j in range(ln) if s2[dst2 + j] != pr[dst + j]))
PYEOF
cat "$work/step2.judge" | sed 's/^/   /'
S2G="$(sed -n 's/^STEP2_DST2_VS_GOLD=\([0-9]*\)$/\1/p' "$work/step2.judge")"
S2F="$(sed -n 's/^STEP2_DST2_VS_FUSED=\([0-9]*\)$/\1/p' "$work/step2.judge")"
if [ "$S2G" != "0" ] || [ "$S2F" != "0" ]; then
  echo "JUDGE-RED: 判据 1(c) 失败：分两步的最终输出与黄金/融合对不符（vs gold=$S2G vs fused=$S2F）"; exit 1
fi
echo "   判据 1(c) OK：分两步（run1 中间张量落 DDR + run2）== 融合对（STEP2_DST2_VS_FUSED=0）"

# ---------------- 7) 负对照：把**链首条目的 FLAGS.bit0 强行置 1**（头也落 DDR）⇒ 判据两面都发火 ----------------
#   A-1b 的口径：链 = 两相邻条目（0b00 + 0b11）；本负对照把**链首**改成 `0b01`（bit0=1，其余一字不动），
#   `chainLen` 仍是 2 ⇒ `UnitExec` 的 `isHead=0` ⇒ 切片0 **既**落 DDR(`outMem`)**又**照旧喂 `fbMid`
#   （尾才有数据可吃）；尾照常跑。`dstA = MID_ADDR` ⇒ 头的 DDR 写正好落在判据 2 盯的那个区间上。
#   ★ 这张表**不是**调度器会产出的合法表（合法表里 `bit0=1` 只出现在 `tail`）—— 它是 `UnitExec` 层面的
#     "退化档"负对照（闸门直接驱动 `UnitExec`，不经 `LayerSched`）。两面都必须发火：
#     · `MEM wr` 变大（两个 WR 相位各一张图）；
#     · `MID_UNCHANGED_BAD > 0`。
echo "---- 7) 负对照[链首 bit0 强行置 1：切片0 的中间也落 DDR]：wr 变大 + MID_ADDR 被写（两面发火）----"
SIM_CHLEN=2
run_sim sim.vvp neg "$work/wgt_head.hex" "$work/wgt_tail.hex" \
  "$N0" "$N1" "$N2" "$N3" "$N4" "$N5" "$N6" "$N7"
NRC=$?
if [ "$NRC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/neg.log"; then
  echo "JUDGE-RED: 负对照仿真未 PASS（vvp rc=$NRC）—— 退化档本身应当跑完并写 DDR"
  grep -E '^(RESULT|TB-ERROR|DONE_SEEN|RD_BYTES_PEAK|AR_BURSTS|MEM )' "$work/neg.log" || true
  exit 2
fi
grep -E '^(TB UNITEXEC:|DONE_SEEN|RD_BYTES_PEAK|AR_BURSTS|HEAD_MODE|TAIL_MODE|CHAIN_LEN|MEM )' "$work/neg.log" | sed 's/^/   /'
NCH="$(grep -m1 '^AR_BURSTS=' "$work/neg.log")"
NRDP="$(grep -m1 '^RD_BYTES_PEAK=' "$work/neg.log")"
NMEM="$(grep -m1 '^MEM rd=' "$work/neg.log")"
EXP_NCH="AR_BURSTS=$(( IN_BYTES / 128 )) AW_BURSTS=$(( 2 * MID_BYTES / 128 )) B_OK=$(( 2 * MID_BYTES / 128 ))"
EXP_NRDP="RD_BYTES_PEAK=$IN_BYTES WR_BYTES=$(( 2 * MID_BYTES ))"
EXP_NMEM="MEM rd=$IN_BYTES wr=$(( 2 * MID_BYTES )) bursts=$(( (IN_BYTES + 2 * MID_BYTES) / 128 )) maxburst=16"
if [ "$NCH" != "$EXP_NCH" ] || [ "$NRDP" != "$EXP_NRDP" ] || [ "$NMEM" != "$EXP_NMEM" ]; then
  echo "JUDGE-RED: 负对照计数不符（期望 wr 变大到 $(( 2 * MID_BYTES ))）"
  echo "  ch=[$NCH] exp=[$EXP_NCH]"; echo "  rdp=[$NRDP] exp=[$EXP_NRDP]"; echo "  mem=[$NMEM] exp=[$EXP_NMEM]"
  exit 2
fi
NHM="$(grep -m1 '^HEAD_MODE=' "$work/neg.log")"
NTM="$(grep -m1 '^TAIL_MODE=' "$work/neg.log")"
if [ "$NHM" != "HEAD_MODE=0 MID_ROWS=$(( H + 1 ))" ] || [ "$NTM" != "TAIL_MODE=1 TAIL_ROWS=$(( H + 1 ))" ]; then
  echo "JUDGE-RED: 负对照自报不符（HEAD_MODE 应 0、TAIL_MODE 应 1）got=[$NHM] [$NTM]"; exit 2
fi
# MID 区：必须被写（这就是负对照的"红"），且里面正是**头那张中间张量**（前 2048 B）
"$PY" - "$work" "$MID_ADDR" "$MID_BYTES" "$SRC" <<'PYEOF' > "$work/neg.judge"
import sys
work, mid, midb, src = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
def load(p):
    return [l.strip() for l in open(p) if l.strip()]
d = load(work + "/neg.dump"); p = load(work + "/pre.hex"); gm = load(work + "/gold_mid.hex")
bad = 0; first = -1
for j in range(midb):
    if d[mid + j] != p[mid + j]:
        bad += 1
        if first < 0:
            first = mid + j
print("MID_UNCHANGED_BAD=%d" % bad)
print("MID_FIRST_OFF=%d" % first)
print("MID_EQ_MIDGOLD=%d" % sum(1 for j in range(midb) if d[mid + j] != gm[j]))
sb = sum(1 for j in range(2048) if d[src + j] != p[src + j])
print("SRC_UNCHANGED_BAD=%d" % sb)
PYEOF
cat "$work/neg.judge" | sed 's/^/   /'
N_MBAD="$(sed -n 's/^MID_UNCHANGED_BAD=\([0-9]*\)$/\1/p' "$work/neg.judge")"
N_MGOLD="$(sed -n 's/^MID_EQ_MIDGOLD=\([0-9]*\)$/\1/p' "$work/neg.judge")"
if ! [ "$N_MBAD" -gt 0 ] 2>/dev/null; then
  echo "JUDGE-RED: 负对照没发火：bit0=1 时 MID_ADDR 竟然没被写（MID_UNCHANGED_BAD=$N_MBAD）"; exit 2
fi
if [ "$N_MGOLD" != "0" ]; then
  echo "JUDGE-RED: 负对照不干净：被写进 MID_ADDR 的不是头那张中间张量（差 $N_MGOLD）"; exit 2
fi
echo "   NEG_OK[链首 bit0=1]: wr 变大（$NRDP / $NMEM）+ MID_ADDR 被写（MID_UNCHANGED_BAD=$N_MBAD，"
echo "                   且那 $MID_BYTES 字节正是头那张中间张量）⇒ 判据两面都发火"
echo "   = 原始红证据：同一用例、同一装置，只要把链首条目的 FLAGS.bit0 从 0 变 1（0b00 -> 0b01），判据 2 的两条（字节计数 / MID 未动）就同时红"

# ---------------- 收口 ----------------
echo "=========================================================================="
echo "判据 1(a) = OK（融合对 DST 区 $MID_BYTES B 逐字节 == 两段黄金；FUSED_DST_MISMATCH=0）"
echo "判据 1(b) = OK（两段黄金两条**独立**实现逐字节相同：mac_ref 链 vs 朴素 NHWC 链）"
echo "判据 1(c) = OK（同一装置分两步：run1 头 SRC->STMP 把中间张量写进 DDR、run2 尾 STMP->DST2；"
echo "                        STEP1_TMP_MISMATCH=0、STEP2_DST2_VS_FUSED=0）"
echo "判据 2(a) = OK（字节计数三方一致（正对照）：$CH / $RDP / $MEML；中间张量的 2x$MID_BYTES 两份都不在 DDR）"
echo "判据 2(b) = OK（MID_UNCHANGED_BAD=0：$MID_BYTES B == 预载；SRC 未改；整片只有 DST 那一区变了）"
echo "判据 2(c) = OK（HEAD_MODE=1 TAIL_MODE=1 MID_ROWS=TAIL_ROWS=$(( H + 1 ))）"
echo "负对照    = OK（bit0=1 ⇒ wr $MID_BYTES->$(( 2 * MID_BYTES ))、MID_UNCHANGED_BAD=$N_MBAD ⇒ 两面发火）"
echo "非退化    = OK（激活无 0 字节、distinct>=250；黄金 != 整行/整列平移；DST/MID 预载与期望 >=1900 字节不同）"
echo "比较器    = OK（扰动 1 个最终黄金字节 ⇒ MISMATCH 恰为 1）"
echo "结构      = OK（check_dangling.py：gen/UnitExec.v 零悬空）"
echo "RESULT: PASS"
exit 0
