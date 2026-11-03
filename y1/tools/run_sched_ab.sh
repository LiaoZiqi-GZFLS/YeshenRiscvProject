#!/usr/bin/env bash
# run_sched_ab.sh —— C3.10a/C3.10b **单元序列 FSM**（`LayerSched`，S4 的"帧内零中断"核心）的数值 + IRQ 闸门。
#
# ★★ A-1b：描述符改用 **per-operator 链式编码**（`FLAGS[1:0]`：`00` head / `01` plain / `10` middle /
#   `11` tail；`FLAGS[7:2]` 保留 = 0），**一条链 = 一段相邻条目序列**，调度器把它**塌缩成一次 `go`**
#   （`chainLen` = 跑长，作为独立入参给 `UnitExec`；`SRC` = 链首的、`DST` = **链尾**的）。
#   本闸门的表因此**显式改形**（旧的 `0b10`="塌缩融合对"已作废 —— 那个编码现在是 `middle`）：
#     · A 作业（conv-only）：`[plain 0b01] + [head 0b00] + [tail 0b11]` = **3 载荷**（旧 = 2 项）；
#     · B 作业（旁路链）：`[plain 0b01] + [head 0b00] + [tail 0b11] + [旁路 0b01]` = **4 载荷**（旧 = 3 项）。
#   判据本身的**前提没变**（数值逐字节、IRQ 纪律、旁路逐点、两条负对照），变的只有：
#     (1) `descCount`/取表笔数/流量计数（多一个 head/tail 条目 ⇒ 多 1~2 笔 32 B 取表）；
#     (2) `unitIndex` = **已消费的载荷条目数**（链一次 `go` 消费 2 个）⇒ 帧末仍 == `descCount`；
#     (3) 新增两条**新负对照**：`middle` 无前驱 / `head` 没有 `tail` ⇒ 响亮 err + 零设备搬运。
#   诱饵区 `MID_ADDR/DECOY` 现在**兼任**"链的中间张量槽位"（写成 head 的 DST / tail 的 SRC）——
#   "未动"判据因此更贴题：它盯的就是"中间张量必须零 DDR"。
#
# 被测行为（rtl/LayerSched.scala 文件头）：
#   主机在 DDR 写一张**描述符表**（`[unit0, unit1, ..., 哨兵]`），发一次 `go`；调度器自己走表，
#   按 `TYPE` 把每一项分派给对应单元（项与单元都在时间上串行、**一个单元一次 `go`**），
#   走完**整表**之后抬**一次** `frameDone`（单拍脉冲）；**帧内任何单元跑完都不抬**（S4 的
#   "帧内中断计数 == 0"）。
#
# ★ 本闸门有两组作业：
#   (A) **C3.10a conv-only 作业**（保留，回归）：3 项 = plain conv3x3 + head + tail（head+tail **一次 go**）
#       → 末张量 == 黄金。
#   (B) **★ C3.10b 旁路链作业**（本片新增，S4 的完整判据）：3 项 =
#         conv3x3(8→8, W=32,H=8)          -> T1
#         head(3x3) + tail(1x1=中心抽头)（**两个相邻条目、一次 go**） -> T2
#         **旁路算子**（maxpool / sigmoid / add / resize 各一档）-> T3（末张量）
#       · `maxpool` 档就是计划 Step 2 点名的链：maxpool(2×2/s2) 吃 T2 这个 `(C=8,W=32,H=8)`
#         张量、吐 `(C=8,W=16,H=4)`；`add` 档钉住描述符**单 `SRC_ADDR`** 下的双操作数处置
#         （列交织，见 rtl/BypassExec.scala 文件头 §O1）；`resize` 档钉住"输入/输出相位交替"的
#         流控（`x_ready=0` 的那 8W 拍里 RD 流原地停住）。
#       · **两档数值判据**：(1) 整链逐字节 == Python 黄金（`conv_unit_ref` + `bypass_ref`）；
#         (2) ★ **旁路那一段单独逐点对账**：拿**硬件 dump 里的输入区**喂 `bypass_ref` 的算子参考，
#             与**硬件 dump 里的 T3** 逐点比（输入输出都取自硬件 ⇒ 这一条**不是**"链跑通了"的橡皮章）。
#
# ★ 关于"计划里的链序"（诚实记录）：计划写的是 `conv3x3 → maxpool → conv1x1`。**conv 不能跟在
#   maxpool 后面**：`Conv3x3Slice` 按**展开期 `WIDTH`** 数列（`LineBuffer` 深度、列计数都是常量），
#   而 maxpool 把行宽**减半**（32→16）⇒ 16 宽的张量喂不进一块按 32 宽展开的切片（整幅错位）。
#   `LayerSched` 只有一个 `UnitExec`（展开期 WIDTH=32）⇒ 任何 conv 必须吃 32 宽的张量。所以本闸门
#   把 maxpool 放在**末位**：`conv3x3 → head+tail(3x3→1x1) → maxpool`，其中 maxpool 吃的正是
#   `(C=8,W=32,H=8)`、吐 `(8,16,4)` —— 与计划点名的**张量形状**一致。四个旁路算子都在末位跑一遍。
#
# 判据（正对照 + 三区域 + 旁路逐点 + IRQ 纪律 + 双向负对照 + 比较器自检 + 结构）：
#   0) 向量来源 = 冻结真源 `desc_table.pack_table`；黄金双实现交叉；背景素周期 251；防混叠；各作业
#      自己的非退化前提（maxpool 黄金 != 任何整块平移；add 的 SAT_EVENTS>0；sigmoid 码点分辨度）。
#   1) 正对照：每个作业的 T1/T2/T3 逐字节 == 黄金（MISMATCH=0）。
#   2) 三区域：SRC 未改、诱饵区未改、末张量之外（含近邻）全 == 预载。
#   3) ★ 旁路段逐点：SEG_MISMATCH=0（硬件输入 -> 算子参考 -> 硬件 T3）。
#   4) ★ IRQ 纪律：IRQ_RISES==1、IRQ_INTRA_FRAME==0、IRQ_AT_FRAME_END==1、IRQ_HELD_AFTER_50==1、
#      UNIT_INDEX_FINAL==descCount。旁路档的末单元**就是旁路算子**。
#   5) 负对照 A（必须红）：网表突变让 `frameEnd` 也认 `NEXT_1` ⇒ 每单元都抬 ⇒ IRQ_INTRA_FRAME>0
#      （conv 作业 2 单元与旁路作业 3 单元两档都跑）。
#   6) 负对照 B（必须红）：descCount 少 1 ⇒ 进表前发现哨兵不符 ⇒ 响亮 err + 零搬运。
#   7) 比较器自检：扰动最终黄金一个字节 ⇒ MISMATCH 恰好 1。
#   8) 结构：check_dangling.py（零悬空）。
#   9) ★ C3.11b 逐项字段校验（S6 规则 (2)(3)(4)）：6 道负作业（SRC 不对齐 / DST 越窗 / 自环 /
#      IN_BYTES=0 / 非法 TYPE 0x77 / **片上占位槽**不对齐）—— 每道必须"响亮 err + **零设备搬运**"
#      （`ERR_SEEN=1`、`DONE_SEEN=0`、`AW_BURSTS total=0`、`MEM rd=64` = 只有表探测那 2 笔 32 B 读、
#      `UNIT_INDEX_FINAL=0`、`IRQ_RISES=0`；判据全在**取表相位**，见 rtl/LayerSched.scala 文件头）；
#      再逐条**突变控制**（把那条判据从网表里摘掉 ⇒ 对应负作业必须**不再绿** = 判据有牙的原始红证据）。
#
# 退出码：0 = 全过；1 = 对账不符/编译或仿真失败/装置未 PASS/网表不存在；
#         2 = 负对照没发火或比较器自检不过 ⇒ 闸门自身不可信；3 = 向量/维度自检失败。
#
# 装置契约（rtl_test/LayerSchedTb.v + AxiMemModel.v + gen/LayerSched.v）：
#   +MEMFILE= +DUMPFILE= +DESC_ADDR= +DESC_COUNT= +D0..+D7= +E0..+E7= [+F0..+F7=] [+G0..+G7=]
#   +WGTFILE= +WGTFILE_T= +CTRL=1 +EXPECT_ERR      （★A-1b：`+G0..+G7` = 第 3 项描述符，B 作业用）
set -uo pipefail

# ---- Python：本机 onnx 依赖在 third_party/yunet/deps 里（desc_table 的 GraphView 要它）----
PY="${PY:-}"
if [ -z "$PY" ]; then
  for c in /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe python3 python; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi

here="$(cd "$(dirname "$0")" && pwd)"
top="$here/../.."                     # 仓库根（Python 侧的统一 cwd：PYTHONPATH 用相对路径）
gen="$here/../gen"
tb="$here/../rtl_test/LayerSchedTb.v"
memv="$here/../rtl_test/AxiMemModel.v"
nl="$gen/LayerSched.v"
ref="$here/conv_unit_ref.py"
dangling="$here/check_dangling.py"

# ---- 用例常量（必须与 rtl_test/LayerSchedTb.v 里 AxiMemModel 的 MEMSZ 一致）----
MEMSZ=2621440              # 2.5 MiB
DESC_ADDR=4096             # 0x001000（表基址；32 B 对齐）
SRC=131072                 # 0x020000  A0（项 0 的输入，NHWC）
MID_ADDR=196608            # 0x030000  ★ 诱饵 = **链的中间张量槽位**（head 的 DST / tail 的 SRC）：链**不得**碰它
A1=262144                  # 0x040000  项 0 的输出 = 项 1 的输入（NHWC）
DST=1441792                # 0x160000  链（head+tail）的最终输出 A2 = **tail 的 DST**（NHWC）
W=32; H=8; CIN=8; COUT=8; SGROUP=1; SHIFT=6
IN_BYTES=$(( CIN * H * W ))          # 2048（= d.w6；断言是 128 的整数倍）
PERIOD=251                           # 素周期；与 32/128 互素 ⇒ 整块平移必被发现
SEED=20265793                        # 本用例选定的 seed：激活**无 0 字节**、三段黄金都不 clamp
HSCALE=2; TSCALE=8                   # 头/尾权重放大（int8 内）
# ★★ T-S2：LayerSchedGen 的真几何（`C=8, WIDTH=W_MAX=34, IMG_H_MAX=32`）—— 自报对账用。
#   `WMAX=34 = W_TILE(32) + 2`（2-D tile 的物理行宽，halo 列）；`HMAX=32 = H_TILE`。
#   ★ 为什么不是 spec §4.1 推荐的 64×32（`W_MAX=66`）：**dev_map 是仲裁者**（spec §4.1/§6-R4 明写
#     "以 dev_map 为准"）—— `W_MAX=66/H_TILE=32` 的 nputop dev_map **失败**（`Adm-4088 ×195`，
#     DRM 不够），降到 spec 点名的回落档 **32×32**（`W_MAX=34`）后 `Adm-4088 = 0`。见
#     `y1/reports/c4b_tiling_s2.md` §3。
#   作业几何仍是 C3 的 `W=32,H=8`（**运行期行宽** `rowW=32 <= W_MAX=34` 合法）。
WMAX=34; HMAX=32
MAXPIX=$(( WMAX * HMAX ))             # 1088（LayerSchedGen 的几何）；TB 自报对账
# ★ A-1b：A 作业的载荷 = **3 项**（[plain 0b01] + [head 0b00] + [tail 0b11]）；
#   链的 head+tail 两项由调度器**塌缩成一次 go**（chainLen=2）。取表笔数 = 载荷项数 + 1（哨兵探测）。
A_DESC_COUNT=3
FETCH_N=$(( A_DESC_COUNT + 1 ))                    # 4（哨兵探测 1 + 载荷 3）
EXP_MEMRD=$(( FETCH_N * 32 + 2 * IN_BYTES ))       # 128 + 4096 = 4224
EXP_MEMWR=$(( 2 * IN_BYTES ))                      # 4096
EXP_BURSTS=$(( FETCH_N + 4 * (IN_BYTES / 128) ))   # 4 + 64 = 68

# ---- ★ C3.10b 旁路链作业的地址布局（每个作业一份独立内存镜像）----
BP_DESC_ADDR=4096          # 0x001000（4 项 x 32 B）
BP_A0=131072               # 0x020000（输入张量）
BP_DECOY=196608            # 0x030000（诱饵：片上中间张量不得落这里）
BP_T1=262144               # 0x040000（plain conv3x3 的输出 = **链首（head）的输入**）
BP_T2=327680               # 0x050000（**链尾（tail）的输出** = 旁路算子输入）
BP_T3=393216               # 0x060000（旁路算子输出 = 末张量）
BP_INT=524288              # 0x080000（add 档的**列交织双路流**，只读预载）
BP_DESC_COUNT=4            # ★ A-1b：B 作业的载荷 = 4 项（plain + head + tail + 旁路）
BP_FETCH_N=5               # 取表笔数（4 载荷 + 哨兵探测）
HMP=8                      # maxpool/sigmoid/add 链的 H（张量 (8,32,8)）
HRZ=4                      # resize 链的 H（张量 (8,32,4) -> (8,64,8)）

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

echo "== run_sched_ab: C3.10a/C3.10b 单元序列 FSM LayerSched（走表 + conv/旁路分派 + 帧末一次 IRQ）=="
echo "   tb  =$tb"
echo "   mem =$memv"
echo "   nl  =$nl"
echo "   ref =$ref"
echo "   py=${PY:-<找不到>}  iverilog=${IVERILOG:-<找不到>}  vvp=${VVP:-<找不到>}"
echo "   tmp =$work"
echo "   用例(A conv-only) DESC_ADDR=$DESC_ADDR SRC=$SRC MID_ADDR=$MID_ADDR A1=$A1 DST=$DST"
echo "   用例(B 旁路链)   DESC_ADDR=$BP_DESC_ADDR A0=$BP_A0 T1=$BP_T1 T2=$BP_T2 T3=$BP_T3 INT=$BP_INT"
echo "   几何 C_IN=$CIN C_OUT=$COUT W=$W H=$H GROUP=$SGROUP SHIFT=$SHIFT IN_BYTES=$IN_BYTES SEED=$SEED MAXPIX=$MAXPIX"

# ---------------- 前置检查 ----------------
if [ ! -f "$nl" ]; then
  echo "FATAL: 找不到网表 $nl"
  echo "       先生成: cd y1 && printf 'Test/runMain LayerSchedGen D:/code/PDS/VexiiYeshenLinux/y1/gen\\\\nexit\\\\n' | bash sbt.sh"
  exit 1
fi
[ -f "$tb" ]  || { echo "FATAL: 找不到装置 $tb"; exit 1; }
[ -f "$memv" ]|| { echo "FATAL: 找不到内存模型 $memv"; exit 1; }
[ -f "$ref" ] || { echo "FATAL: 找不到参考 $ref"; exit 1; }
if [ -z "$PY" ] || [ -z "$IVERILOG" ] || [ -z "$VVP" ]; then echo "FATAL: 找不到 python / iverilog / vvp"; exit 1; fi
case $(( IN_BYTES % 128 )) in 0) : ;; *) echo "FATAL: IN_BYTES=$IN_BYTES 不是 128 的整数倍"; exit 3 ;; esac

# ---------------- 0) 参考自检 ----------------
echo "---- 0) tools/conv_unit_ref.py --selftest（mac_ref 算术 + 布局置换 + 三条链双实现交叉对账）----"
if ! "$PY" "$ref" --selftest; then
  echo "=== FATAL: 参考自检没过 ⇒ 用例/参考写错了（不是硬件的问题）==="
  exit 3
fi

# ---------------- 0b) 结构判据：零悬空实例 ----------------
echo "---- 0b) tools/check_dangling.py（gen/LayerSched.v ⇒ 零悬空）----"
if [ -f "$dangling" ]; then
  "$PY" "$dangling" "$nl" | tail -3
  if ! "$PY" "$dangling" "$nl" >/dev/null; then
    echo "JUDGE-RED: 有悬空实例（被例化但没有模块定义）"; exit 1
  fi
else
  echo "WARN: 找不到 $dangling（跳过结构判据）"
fi
# ---------------- 1) 造向量(A)：描述符表 + 激活/权重/三段黄金 + 内存模式 ----------------
echo "---- 1) 造向量(A conv-only)：描述符表（冻结真源 desc_table.pack_table）+ 三段黄金（双实现）----"
if ! ( cd "$top" && PYTHONIOENCODING=utf-8 PYTHONPATH='third_party/yunet/deps' "$PY" - \
        "$work" "$here" "$top" "$MEMSZ" "$DESC_ADDR" "$SRC" "$MID_ADDR" "$A1" "$DST" \
        "$CIN" "$COUT" "$W" "$H" "$SGROUP" "$SHIFT" "$PERIOD" "$SEED" "$HSCALE" "$TSCALE" <<'PYEOF'
import sys, os, struct, hashlib
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
work, refdir, topdir = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, refdir)
sys.path.insert(0, os.path.join(topdir, "y1", "tools"))
import conv_unit_ref as R
import mac_ref
import desc_table as DT

(memsz, desc_addr, src, mid, a1, dst, CIN, COUT, W, H, GROUP, SHIFT, PERIOD, SEED, HS, TS) = \
    (int(x) for x in sys.argv[4:20])

def scale(v, k):
    return [max(-128, min(127, x * k)) for x in v]

wt, x_chw, x_ddr, y_ddr = R.build(CIN, COUT, H, W, seed=SEED, shift=SHIFT)
assert len(wt) == COUT * CIN * 9 and len(x_ddr) == CIN * H * W
wt_head = scale(wt, HS)
wt_tail = R.centre_tap(scale(wt, TS), CIN, COUT)
assert sum(1 for v in wt_head if v != 0) > 0 and sum(1 for v in wt_tail if v != 0) > 0

a1_a, mid_a, a2_a = R.sched_chain(x_chw, wt_head, wt_tail, CIN, COUT, H, W, SHIFT)
a1_b, mid_b, a2_b = R.sched_chain_naive(x_ddr, wt_head, wt_tail, CIN, COUT, H, W, SHIFT)
assert a1_a == a1_b and mid_a == mid_b and a2_a == a2_b, "两条独立黄金不一致 ⇒ 参考口径漂了"

assert len(set(x_ddr)) > 1
for nm, t in (("A1", a1_a), ("MID", mid_a), ("A2", a2_a)):
    assert len(set(t)) > 1, "%s 是常数" % nm
    assert sum(1 for v in t if v != 0) > 0, "%s 是全 0" % nm
    assert sum(1 for v in t if v in (127, -128)) < len(t), "%s 整片 clamp" % nm
nz_a2 = sum(1 for v in a2_a if v != 0)
assert nz_a2 >= 1024 and len(set(a2_a)) >= 16, "A2 分辨率太差（nz=%d dist=%d）" % (nz_a2, len(set(a2_a)))

def rowshift(a, k):
    o = [0] * len(a)
    for y in range(H):
        for x in range(W):
            for c in range(COUT):
                o[(y * W + x) * COUT + c] = a[(((y + k) % H) * W + x) * COUT + c]
    return o
def colshift(a, k):
    o = [0] * len(a)
    for y in range(H):
        for x in range(W):
            for c in range(COUT):
                o[(y * W + x) * COUT + c] = a[(y * W + (x + k) % W) * COUT + c]
    return o
assert a2_a != rowshift(a2_a, 1) and a2_a != colshift(a2_a, 1), "A2 == 整行/整列平移"
assert all(v != 0 for v in x_ddr), "输入向量含 0 字节（本用例要求无 0）"
assert len(set(x_ddr)) >= 250, "输入取值太集中（distinct=%d）" % len(set(x_ddr))

def pat(i):
    return ((i % PERIOD) * 131 + 7) % PERIOD
assert len(set(pat(i) for i in range(PERIOD))) == PERIOD, "模式周期不是恰好 %d" % PERIOD
assert PERIOD % 128 != 0 and 128 % PERIOD != 0, "模式周期与块长不互素"
pre = bytes(pat(i) for i in range(memsz))

for nm, addr, gold in (("A1", a1, a1_a), ("MID", mid, mid_a), ("DST", dst, a2_a)):
    d = sum(1 for j in range(len(gold)) if pre[addr + j] != (gold[j] & 0xFF))
    assert d >= 1900, "%s 区预载与黄金只有 %d/%d 字节不同 ⇒ '不写'有机会蒙过" % (nm, d, len(gold))

regions = {"desc": (desc_addr, 96), "src": (src, CIN * H * W), "mid": (mid, COUT * H * W),
           "a1": (a1, COUT * H * W), "dst": (dst, COUT * H * W)}
for n, (a, ln) in regions.items():
    assert a % 32 == 0, "%s 地址 %d 不是 32B 对齐" % (n, a)
    assert a + ln <= memsz, "%s 越出已建模内存" % n
    assert a >= 128 and memsz - (a + ln) >= 128, "%s 前后要留出邻居字节" % n
names = sorted(regions, key=lambda n: regions[n][0])
for i in range(len(names) - 1):
    a0, l0 = regions[names[i]]
    a1b, _ = regions[names[i + 1]]
    assert a0 + l0 <= a1b, "%s 与 %s 区重叠" % (names[i], names[i + 1])

# ★★ A-1b：per-operator 链式编码 —— 载荷 **3 项**：
#   d0 = plain（`0b01`）：`src` -> `a1`（普通单元，输出落 DDR）；
#   d1 = **head**（`0b00`）：`a1` -> **片上**（`DST_ADDR` 写成诱饵槽 `mid`：链**不得**碰它）；
#   d2 = **tail**（`0b11`）：片上 -> `dst`（1x1 中心抽头权重；链的输出落 DDR）。
#   调度器把 d1+d2 **塌缩成一次 `go`**（`chainLen=2`，`SRC` = d1 的、`DST` = d2 的）。
d0 = {"TYPE": 0x01, "FLAGS": 0b01, "IMG_W": W, "IMG_H": H, "C_IN": CIN, "C_OUT": COUT,
      "GROUP": GROUP, "STRIDE": 1, "PAD": 1, "SRC_ADDR": src, "DST_ADDR": a1,
      "IN_BYTES": CIN * H * W, "QUANT_SHIFT": SHIFT, "LAYER_ID": 0}
d1 = {"TYPE": 0x01, "FLAGS": 0b00, "IMG_W": W, "IMG_H": H, "C_IN": CIN, "C_OUT": COUT,
      "GROUP": GROUP, "STRIDE": 1, "PAD": 1, "SRC_ADDR": a1, "DST_ADDR": mid,
      "IN_BYTES": CIN * H * W, "QUANT_SHIFT": SHIFT, "LAYER_ID": 1}
d2 = {"TYPE": 0x02, "FLAGS": 0b11, "IMG_W": W, "IMG_H": H, "C_IN": CIN, "C_OUT": COUT,
      "GROUP": GROUP, "STRIDE": 1, "PAD": 1, "SRC_ADDR": mid, "DST_ADDR": dst,
      "IN_BYTES": CIN * H * W, "QUANT_SHIFT": SHIFT, "LAYER_ID": 2}
blob = DT.pack_table([d0, d1, d2])
assert len(blob) == 128, "表字节数 %d != 128" % len(blob)

def hand_words(d):
    return [(d["TYPE"] & 0xFF) | ((d["FLAGS"] & 0xFF) << 8),
            (d["IMG_W"] & 0xFFFF) | ((d["IMG_H"] & 0xFFFF) << 16),
            (d["C_IN"] & 0xFFFF) | ((d["C_OUT"] & 0xFFFF) << 16),
            (d["GROUP"] & 0xFF) | ((d["STRIDE"] & 0xF) << 8) | ((d["PAD"] & 0xF) << 12),
            d["SRC_ADDR"], d["DST_ADDR"], d["IN_BYTES"],
            (d["QUANT_SHIFT"] & 0xFF) | ((d["LAYER_ID"] & 0xFF) << 8)]

w0 = list(struct.unpack_from("<8I", blob, 0))
w1 = list(struct.unpack_from("<8I", blob, 32))
w2 = list(struct.unpack_from("<8I", blob, 64))
ws = list(struct.unpack_from("<8I", blob, 96))
assert w0 == hand_words(d0) == DT.reference_words(d0), "描述符0 的字三方对账不符"
assert w1 == hand_words(d1) == DT.reference_words(d1), "描述符1 的字三方对账不符"
assert w2 == hand_words(d2) == DT.reference_words(d2), "描述符2 的字三方对账不符"
assert (w0[0] >> 8) & 0xFF == 0b01, "描述符0 的 FLAGS 应为 0b01（plain）"
assert (w1[0] >> 8) & 0xFF == 0b00, "描述符1 的 FLAGS 应为 0b00（head）"
assert (w2[0] >> 8) & 0xFF == 0b11, "描述符2 的 FLAGS 应为 0b11（tail）"
assert (ws[0] & 0xFF) == 0xFF and (ws[0] >> 8) == 0, "下标 3 不是哨兵（pack_table 没追加？）"

mem = bytearray(pre)
mem[desc_addr:desc_addr + len(blob)] = blob
mem[src:src + len(x_ddr)] = bytes(v & 0xFF for v in x_ddr)
open(work + "/mem.hex", "w").write("".join("%02x\n" % b for b in mem))
R.dump_bytes(work + "/wgt_head.hex", wt_head)
R.dump_bytes(work + "/wgt_tail.hex", wt_tail)
open(work + "/gold_a1.hex", "w").write("".join("%02x\n" % (v & 0xFF) for v in a1_a))
open(work + "/gold_mid.hex", "w").write("".join("%02x\n" % (v & 0xFF) for v in mid_a))
open(work + "/gold_a2.hex", "w").write("".join("%02x\n" % (v & 0xFF) for v in a2_a))
open(work + "/desc0.args", "w").write(" ".join(str(x) for x in w0))
open(work + "/desc1.args", "w").write(" ".join(str(x) for x in w1))
open(work + "/desc2.args", "w").write(" ".join(str(x) for x in w2))

print("MEMGEN bytes=%d desc=%d src=%d mid=%d a1=%d dst=%d period=%d seed=%d" %
      (memsz, desc_addr, src, mid, a1, dst, PERIOD, SEED))
print("TABLE items=4 bytes=%d md5=%s (desc_table.pack_table：3 载荷 + 自动哨兵)" %
      (len(blob), hashlib.md5(blob).hexdigest()))
print("WORDS0 %s" % " ".join("%08x" % x for x in w0))
print("WORDS1 %s" % " ".join("%08x" % x for x in w1))
print("WORDS2 %s" % " ".join("%08x" % x for x in w2))
print("NONZERO: 激活无 0 字节（distinct=%d）；A2 非 0=%d/2048 distinct=%d clamp=%d"
      % (len(set(x_ddr)), nz_a2, len(set(a2_a)), sum(1 for v in a2_a if v in (127, -128))))
print("NONALIAS: 周期恰 %d 且与 128 互素；A1/MID/DST 预载与黄金 >=1900/2048 不同；A2 != 整行/整列平移" % PERIOD)
print("DESC0 w0=0x%08x (TYPE=0x%02x FLAGS=0b%s 项0 plain：src->a1，输出落 DDR)" % (w0[0], w0[0] & 0xFF, format((w0[0] >> 8) & 0xFF, "02b")))
print("DESC1 w0=0x%08x (TYPE=0x%02x FLAGS=0b%s 项1 head：a1->片上（DST 槽 = 诱饵 mid）)" % (w1[0], w1[0] & 0xFF, format((w1[0] >> 8) & 0xFF, "02b")))
print("DESC2 w0=0x%08x (TYPE=0x%02x FLAGS=0b%s 项2 tail：片上->dst ⇒ 项1+项2 = 一个 go(chainLen=2))" % (w2[0], w2[0] & 0xFF, format((w2[0] >> 8) & 0xFF, "02b")))
PYEOF
) ; then
  echo "FATAL: 生成向量/黄金失败（或非退化/防混叠前提不成立）⇒ 闸门不可信"
  exit 3
fi
for f in mem.hex wgt_head.hex wgt_tail.hex gold_a1.hex gold_mid.hex gold_a2.hex desc0.args desc1.args desc2.args; do
  [ -s "$work/$f" ] || { echo "FATAL: 激励文件 $f 缺失或为空"; exit 3; }
done
read -r D0 D1 D2 D3 D4 D5 D6 D7 < "$work/desc0.args"
read -r E0 E1 E2 E3 E4 E5 E6 E7 < "$work/desc1.args"
read -r F0 F1 F2 F3 F4 F5 F6 F7 < "$work/desc2.args"
WGT_HEAD="$work/wgt_head.hex"
WGT_TAIL="$work/wgt_tail.hex"

# ---------------- 2) 编译 ----------------
echo "---- 2) iverilog 编译（LayerSchedTb + AxiMemModel + gen/LayerSched.v）----"
if ! "$IVERILOG" -g2012 -o "$work/sim.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败（好网表）"; sed -n '1,40p' "$work/iv.log"; exit 1
fi
if grep -qi 'warning' "$work/iv.log"; then
  echo "    编译告警（留意）："; grep -i 'warning' "$work/iv.log" | head -3
fi
echo "    编译 OK"

"$PY" - "$work/mem.hex" "$work/pre.hex" <<'PYEOF'
import sys
t = [l.strip() for l in open(sys.argv[1]) if l.strip()]
open(sys.argv[2], "w").write("\n".join(t) + "\n")
PYEOF

# run_sim <vvp> <logbase> <desc_count> [extra args...]   （A conv-only 作业：$work 那一份内存镜像）
run_sim() {
  local vvp="$1" log="$2" dc="$3"; shift 3
  ( cd "$work" && "$VVP" "$vvp" \
      "+WGTFILE=$WGT_HEAD" "+WGTFILE_T=$WGT_TAIL" \
      "+MEMFILE=$work/mem.hex" "+DUMPFILE=$work/$log.dump" +dump \
      "+DESC_ADDR=$DESC_ADDR" "+DESC_COUNT=$dc" \
      "+D0=$D0" "+D1=$D1" "+D2=$D2" "+D3=$D3" "+D4=$D4" "+D5=$D5" "+D6=$D6" "+D7=$D7" \
      "+E0=$E0" "+E1=$E1" "+E2=$E2" "+E3=$E3" "+E4=$E4" "+E5=$E5" "+E6=$E6" "+E7=$E7" \
      "+F0=$F0" "+F1=$F1" "+F2=$F2" "+F3=$F3" "+F4=$F4" "+F5=$F5" "+F6=$F6" "+F7=$F7" \
      "+CTRL=1" "$@" ) > "$work/$log.log" 2>&1
  return $?
}

# run_job <vvp> <jobdir> <logbase> <desc_count> [extra args...]（B 旁路链作业：每作业一份内存镜像）
run_job() {
  local vvp="$1" jd="$2" log="$3" dc="$4"; shift 4
  local -a fa=()
  if [ -f "$jd/descF.args" ]; then
    local F0 F1 F2 F3 F4 F5 F6 F7
    read -r F0 F1 F2 F3 F4 F5 F6 F7 < "$jd/descF.args"
    fa=("+F0=$F0" "+F1=$F1" "+F2=$F2" "+F3=$F3" "+F4=$F4" "+F5=$F5" "+F6=$F6" "+F7=$F7")
  fi
  # ★ A-1b：B 作业的载荷有 **4 项**（plain + head + tail + 旁路）⇒ 第 4 项走 `+G0..+G7`
  #   （`LayerSchedTb` 的 time-0 `chk_desc` 最多核 4 项）。
  if [ -f "$jd/descG.args" ]; then
    local G0 G1 G2 G3 G4 G5 G6 G7
    read -r G0 G1 G2 G3 G4 G5 G6 G7 < "$jd/descG.args"
    fa+=("+G0=$G0" "+G1=$G1" "+G2=$G2" "+G3=$G3" "+G4=$G4" "+G5=$G5" "+G6=$G6" "+G7=$G7")
  fi
  local XD0 XD1 XD2 XD3 XD4 XD5 XD6 XD7 XE0 XE1 XE2 XE3 XE4 XE5 XE6 XE7
  read -r XE0 XE1 XE2 XE3 XE4 XE5 XE6 XE7 < "$jd/descE.args"
  read -r XD0 XD1 XD2 XD3 XD4 XD5 XD6 XD7 < "$jd/descD.args"
  ( cd "$jd" && "$VVP" "$vvp" \
      "+WGTFILE=$WGT_HEAD" "+WGTFILE_T=$WGT_TAIL" \
      "+MEMFILE=$jd/mem.hex" "+DUMPFILE=$jd/$log.dump" +dump \
      "+DESC_ADDR=$BP_DESC_ADDR" "+DESC_COUNT=$dc" \
      "+D0=$XD0" "+D1=$XD1" "+D2=$XD2" "+D3=$XD3" "+D4=$XD4" "+D5=$XD5" "+D6=$XD6" "+D7=$XD7" \
      "+E0=$XE0" "+E1=$XE1" "+E2=$XE2" "+E3=$XE3" "+E4=$XE4" "+E5=$XE5" "+E6=$XE6" "+E7=$XE7" \
      "${fa[@]}" "+CTRL=1" "$@" ) > "$jd/$log.log" 2>&1
  return $?
}

# irq_check <logfile> <expected_unitindex> <tag>
irq_check() {
  local log="$1" want="$2" tag="$3"
  local R I E Hd U
  R="$(sed -n 's/^IRQ_RISES=\([0-9]*\)$/\1/p' "$log" | tail -1)"
  I="$(sed -n 's/^IRQ_INTRA_FRAME=\([0-9]*\)$/\1/p' "$log" | tail -1)"
  E="$(sed -n 's/^IRQ_AT_FRAME_END=\([0-9]*\)$/\1/p' "$log" | tail -1)"
  Hd="$(sed -n 's/^IRQ_HELD_AFTER_50=\([0-9]*\)$/\1/p' "$log" | tail -1)"
  U="$(sed -n 's/^UNIT_INDEX_FINAL=\([0-9]*\)$/\1/p' "$log" | tail -1)"
  if [ "${R:-x}" != "1" ]; then echo "JUDGE-RED[$tag]: IRQ_RISES=${R:-?} != 1（frameDone 不是整帧唯一的一次脉冲）"; return 1; fi
  if [ "${I:-x}" != "0" ]; then echo "JUDGE-RED[$tag]: IRQ_INTRA_FRAME=${I:-?} != 0（帧内抬了中断）"; return 1; fi
  if [ "${E:-x}" != "1" ]; then echo "JUDGE-RED[$tag]: IRQ_AT_FRAME_END=${E:-?} != 1（唯一上升沿不在末单元 done 之后）"; return 1; fi
  if [ "${Hd:-x}" != "1" ]; then echo "JUDGE-RED[$tag]: IRQ_HELD_AFTER_50=${Hd:-?} != 1（锁存的保持电平没举住）"; return 1; fi
  if [ "${U:-x}" != "$want" ]; then echo "JUDGE-RED[$tag]: UNIT_INDEX_FINAL=${U:-?} != $want（descCount）"; return 1; fi
  echo "   ★ IRQ 纪律 OK[$tag]：IRQ_RISES=1 IRQ_INTRA_FRAME=0 IRQ_AT_FRAME_END=1 IRQ_HELD_AFTER_50=1 UNIT_INDEX_FINAL=$want"
  return 0
}
# judge_regions <dumpfile>  -> A1/A2 MISMATCH、三区域、整片（A conv-only 作业专用，保留原口径）
judge_regions() {
  "$PY" - "$work" "$1" "$SRC" "$MID_ADDR" "$A1" "$DST" "$IN_BYTES" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
work, dumpf, src, mid, a1, dst, ln = (sys.argv[1], sys.argv[2], int(sys.argv[3]),
                                     int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7]))
def load_num(p):
    vals = []; nbad = 0
    for raw in open(p, encoding="utf-8", errors="replace"):
        s = raw.strip()
        if not s: continue
        try: v = int(s, 16)
        except ValueError: v = None
        if v is None or v < 0 or v > 0xFF:
            nbad += 1; vals.append(-1)
        else: vals.append(v)
    return vals, nbad
def load_gold(p):
    return [int(l.strip(), 16) for l in open(p, encoding="utf-8") if l.strip()]
def diffs(a, b):
    c = 0; first = -1
    for k in range(min(len(a), len(b))):
        if a[k] != b[k]:
            c += 1
            if first < 0: first = k
    return c, first
d, dx = load_num(dumpf)
p, px = load_num(work + "/pre.hex")
g2 = load_gold(work + "/gold_a2.hex")
g1 = load_gold(work + "/gold_a1.hex")
m2, f2 = diffs(d[dst:dst + ln], g2)
m1, f1 = diffs(d[a1:a1 + ln], g1)
sb, _ = diffs(d[src:src + ln], p[src:src + ln])
mb, _ = diffs(d[mid:mid + ln], p[mid:mid + ln])
nb = (sum(1 for j in range(32) if d[dst - 32 + j] != p[dst - 32 + j]) +
      sum(1 for j in range(32) if d[dst + ln + j] != p[dst + ln + j]))
tot = 0; other = 0; ofirst = -1
for j in range(len(p)):
    if d[j] != p[j]:
        tot += 1
        if not (a1 <= j < a1 + ln) and not (dst <= j < dst + ln):
            other += 1
            if ofirst < 0: ofirst = j
print("A2_MISMATCH=%d" % m2)
print("A2_FIRST_OFF=%d" % (dst + f2 if f2 >= 0 else -1))
print("A1_MISMATCH=%d" % m1)
print("SRC_UNCHANGED_BAD=%d" % sb)
print("MID_UNCHANGED_BAD=%d" % mb)
print("DST_NEIGHBOR32_BAD=%d" % nb)
print("WHOLE_MISMATCH=%d" % tot)
print("OTHER_BAD=%d" % other)
print("OTHER_FIRST_OFF=%d" % ofirst)
print("XBYTES=%d XBYTES_PRE=%d" % (dx, px))
PYEOF
}

# judge_job <jobdir>  -> 通用逐区域对账（读 <jobdir>/spec.txt：`name addr len gold|-`）
judge_job() {
  "$PY" - "$1" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
jd = sys.argv[1]
def load_num(p):
    vals = []; nbad = 0
    for raw in open(p, encoding="utf-8", errors="replace"):
        s = raw.strip()
        if not s: continue
        try: v = int(s, 16)
        except ValueError: v = None
        if v is None or v < 0 or v > 0xFF:
            nbad += 1; vals.append(-1)
        else: vals.append(v)
    return vals, nbad
def diffs(a, b):
    c = 0; first = -1
    for k in range(min(len(a), len(b))):
        if a[k] != b[k]:
            c += 1
            if first < 0: first = k
    return c, first
d, dx = load_num(jd + "/dump.hex")
p, px = load_num(jd + "/pre.hex")
cmp_regions = []
specs = []
for ln in open(jd + "/spec.txt", encoding="utf-8"):
    ln = ln.strip()
    if not ln: continue
    nm, addr, length, gold = ln.split()
    specs.append((nm, int(addr), int(length), gold))
for nm, addr, length, gold in specs:
    if gold == "-":
        n, _ = diffs(d[addr:addr + length], p[addr:addr + length])
        print("UNCHANGED[%s]=%d" % (nm, n))
    else:
        g = [int(x.strip(), 16) for x in open(jd + "/" + gold, encoding="utf-8") if x.strip()]
        n, f = diffs(d[addr:addr + length], g)
        print("MISMATCH[%s]=%d" % (nm, n))
        print("FIRSTOFF[%s]=%d" % (nm, addr + f if f >= 0 else -1))
        cmp_regions.append((addr, addr + length))
tot = 0; other = 0; ofirst = -1
for j in range(len(p)):
    if d[j] != p[j]:
        tot += 1
        if not any(a <= j < b for a, b in cmp_regions):
            other += 1
            if ofirst < 0: ofirst = j
print("WHOLE_MISMATCH=%d" % tot)
print("OTHER_BAD=%d" % other)
print("OTHER_FIRST_OFF=%d" % ofirst)
print("XBYTES=%d XBYTES_PRE=%d" % (dx, px))
PYEOF
}

# judge_seg <jobdir> <op> <C> <inW> <inH> <src_addr> <dst_addr>
#   ★ 旁路**那一段**的逐点对账：输入/输出都取自硬件 dump，算子参考来自 tools/bypass_ref.py
judge_seg() {
  "$PY" - "$here" "$1" "$2" "$3" "$4" "$5" "$6" "$7" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
refdir, jd, op = sys.argv[1], sys.argv[2], sys.argv[3]
C, inW, inH, srcA, dstA = (int(x) for x in sys.argv[4:9])
sys.path.insert(0, refdir)
import bypass_ref as BR
def load_num(p):
    vals = []
    for raw in open(p, encoding="utf-8", errors="replace"):
        s = raw.strip()
        if not s: continue
        try: v = int(s, 16)
        except ValueError: v = -1
        vals.append(v if 0 <= v <= 0xFF else -1)
    return vals
def i8(v):
    # ★ DDR 上的字节是**无符号**的（0..255），而算子参考（bypass_ref）的口径是 **int8 有符号**
    #   （`maxpool_ref` 的 `if v > m` 是**有符号**比较）⇒ 喂参考前必须先重解释成 int8，否则
    #   `0xFE` 会被当成 +254 而不是 -2，黄金会整片跑偏（这正是本判据的第一次真实抓错）。
    return v - 256 if v >= 128 else v
d = load_num(jd + "/dump.hex")
nin = C * inW * inH
if op == "maxpool":
    exp = BR.maxpool_ref([i8(d[srcA + i]) for i in range(nin)], C, inW, inH)
elif op == "resize":
    exp = BR.resize2x_ref([i8(d[srcA + i]) for i in range(nin)], C, inW, inH)
elif op == "sigmoid":
    exp = BR.sigmoid_ref([i8(d[srcA + i]) for i in range(nin)], C, inW, inH)
elif op == "add":
    inter = [i8(d[srcA + i]) for i in range(2 * nin)]
    a, b = BR.split_add(inter, C, inW, inH)
    exp = BR.add_ref(a, b, C, inW, inH)
else:
    print("SEG_UNKNOWN_OP[%s]=1" % op); sys.exit(0)
got = [d[dstA + i] for i in range(len(exp))]
bad = sum(1 for x, y in zip(got, exp) if (y & 0xFF) != x)
print("SEG_MISMATCH[%s]=%d" % (op, bad))
print("SEG_LEN[%s]=%d" % (op, len(exp)))
PYEOF
}

# ============================================================================================
# 3) 正对照(A)：走表（2 项，conv-only）
# ============================================================================================
echo "---- 3) 正对照[A 作业 3 项：plain 0b01(A0->A1) + head 0b00(A1->片上) + tail 0b11(片上->A2)] ----"
echo "      ★ A-1b：head+tail **塌缩成一次 go**（chainLen=2）；诱饵槽 MID_ADDR 是链的中间张量槽位，一个字节都不该被写"
run_sim sim.vvp pos "$A_DESC_COUNT"; RC=$?
if [ "$RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/pos.log"; then
  echo "JUDGE-RED: 正对照仿真未 PASS（vvp rc=$RC）"
  grep -E '^(RESULT|TB-ERROR|TB SCHED|IRQ_|UNIT_INDEX|DONE_SEEN|MEM )' "$work/pos.log" || true
  exit 1
fi
grep -E '^(TB SCHED:|IRQ_|IRQ_HELD|UNIT_INDEX_FINAL|AR_BURSTS|AW_BURSTS|DONE_SEEN|MEM )' "$work/pos.log" | sed 's/^/   /'

SHREP="$(grep -m1 '^TB SCHED: RTL_IMGW=' "$work/pos.log")"
EXP_SHREP="TB SCHED: RTL_IMGW=$WMAX RTL_IMGC=$CIN RTL_GRP=$SGROUP RTL_SHIFT=$SHIFT RTL_MAXPIX=$MAXPIX"
if [ "$SHREP" != "$EXP_SHREP" ]; then
  echo "JUDGE-RED: 网表自报行不符（宽度/档位/shift/maxPix 钉死）"; echo "  got=$SHREP"; echo "  exp=$EXP_SHREP"; exit 1
fi
echo "   自报对账 OK：$SHREP"

ARL="$(grep -m1 '^AR_BURSTS ' "$work/pos.log")"
AWL="$(grep -m1 '^AW_BURSTS ' "$work/pos.log")"
MEML="$(grep -m1 '^MEM rd=' "$work/pos.log")"
EXP_ARL="AR_BURSTS n32=$FETCH_N n128=$(( 2 * IN_BYTES / 128 )) total=$(( FETCH_N + 2 * IN_BYTES / 128 ))"
EXP_AWL="AW_BURSTS n128=$(( 2 * IN_BYTES / 128 )) total=$(( 2 * IN_BYTES / 128 )) B_OK=$(( 2 * IN_BYTES / 128 ))"
EXP_MEML="MEM rd=$EXP_MEMRD wr=$EXP_MEMWR bursts=$EXP_BURSTS maxburst=16"
if [ "$ARL" != "$EXP_ARL" ]; then echo "JUDGE-RED: AR 分档不符 got=[$ARL] exp=[$EXP_ARL]"; exit 1; fi
if [ "$AWL" != "$EXP_AWL" ]; then echo "JUDGE-RED: AW 分档不符 got=[$AWL] exp=[$EXP_AWL]"; exit 1; fi
if [ "$MEML" != "$EXP_MEML" ]; then echo "JUDGE-RED: 内存模型计数不符 got=[$MEML] exp=[$EXP_MEML]"; exit 1; fi
echo "   流量对账 OK（三方一致）：$ARL / $AWL / $MEML"
echo "      = 取表 $FETCH_N 笔 32 B（$(( FETCH_N * 32 )) B，表自身的 DMA 读开销已计入）+ 两个单元各 $IN_BYTES B 读/写"

judge_regions "$work/pos.dump" > "$work/pos.judge"
cat "$work/pos.judge" | sed 's/^/   /'
P_M2="$(sed -n 's/^A2_MISMATCH=\([0-9]*\)$/\1/p' "$work/pos.judge")"
P_M1="$(sed -n 's/^A1_MISMATCH=\([0-9]*\)$/\1/p' "$work/pos.judge")"
P_SB="$(sed -n 's/^SRC_UNCHANGED_BAD=\([0-9]*\)$/\1/p' "$work/pos.judge")"
P_MB="$(sed -n 's/^MID_UNCHANGED_BAD=\([0-9]*\)$/\1/p' "$work/pos.judge")"
P_NB="$(sed -n 's/^DST_NEIGHBOR32_BAD=\([0-9]*\)$/\1/p' "$work/pos.judge")"
P_OB="$(sed -n 's/^OTHER_BAD=\([0-9]*\)$/\1/p' "$work/pos.judge")"
if [ "$P_M2" != "0" ]; then echo "JUDGE-RED: 判据1 失败：A2 != 黄金（A2_MISMATCH=$P_M2）"; exit 1; fi
if [ "$P_M1" != "0" ]; then echo "JUDGE-RED: 判据1 失败：A1 != 黄金（A1_MISMATCH=$P_M1）⇒ 项0 plain conv 分派错"; exit 1; fi
if [ "$P_MB" != "0" ]; then echo "JUDGE-RED: 判据2 失败：MID_ADDR 诱饵区被写（MID_UNCHANGED_BAD=$P_MB）"; exit 1; fi
if [ "$P_SB" != "0" ] || [ "$P_OB" != "0" ] || [ "$P_NB" != "0" ]; then
  echo "JUDGE-RED: 判据2 失败：SRC/邻居/其它区被改（SRC=$P_SB OTHER=$P_OB NEIGHBOR32=$P_NB）"; exit 1
fi
echo "   判据1 OK：A2_MISMATCH=0（末张量逐字节 == 黄金）；A1_MISMATCH=0（项0 输出逐字节 == 黄金）"
# ★ C3.11b 正对照：合法表**不得**被"逐项字段校验"误报（这张表还**故意复用地址**：项0 的 DST==项1 的 SRC、
#   项1 的 DST==项2 的 SRC ⇒ 若自环判据写成"全局地址唯一"这里当场红）。
P_ERR="$(sed -n 's/^DONE_SEEN=[0-9]* ERR_SEEN=\([0-9]*\).*$/\1/p' "$work/pos.log" | tail -1)"
if [ "${P_ERR:-x}" != "0" ]; then
  echo "JUDGE-RED: 正对照(A) 竟然报 err（ERR_SEEN=${P_ERR:-?}）⇒ 合法表被新判据误报"; exit 1
fi
echo "   正对照 OK：ERR_SEEN=0（合法表（3 项、相邻项复用地址）不被字段规则/自环判据误报）"
echo "   判据2 OK：SRC=A0 未改；MID_ADDR（= **链的中间张量槽位**，写成 head 的 DST/tail 的 SRC）未改"
echo "             ⇒ 中间张量零 DDR；A2 之外（含近邻 32 B）全 == 预载"

if ! irq_check "$work/pos.log" "$A_DESC_COUNT" "A conv-only"; then exit 1; fi
echo "      = frameDone 整帧唯一一次、在末单元 done 之后（那一刻 unitIndex==descCount=$A_DESC_COUNT，"
echo "        注意 unitIndex 数的是**载荷条目**：链一次 go 消费 2 个条目）、帧内一次都没抬"

# ---------------- 4) 比较器自检 ----------------
echo "---- 4) 比较器自检：扰动最终黄金一个字节 ⇒ A2_MISMATCH 必须恰好 1 ----"
"$PY" - "$work" <<'PYEOF'
import sys
work = sys.argv[1]
t = [l.strip() for l in open(work + "/gold_a2.hex") if l.strip()]
i = len(t) // 2
t[i] = "%02x" % ((int(t[i], 16) ^ 0x01) & 0xFF)
open(work + "/gold_a2_pert.hex", "w").write("\n".join(t) + "\n")
print("CMP_SELFTEST_PERTURB idx=%d" % i)
PYEOF
mv "$work/gold_a2.hex" "$work/gold_a2_orig.hex"
mv "$work/gold_a2_pert.hex" "$work/gold_a2.hex"
judge_regions "$work/pos.dump" > "$work/pert.judge"
SELF_M2="$(sed -n 's/^A2_MISMATCH=\([0-9]*\)$/\1/p' "$work/pert.judge")"
mv "$work/gold_a2_orig.hex" "$work/gold_a2.hex"
echo "   CMP_SELFTEST A2_MISMATCH=$SELF_M2（期望恰好 1）"
if [ "$SELF_M2" != "1" ]; then echo "JUDGE-RED: 比较器自检 A2_MISMATCH=$SELF_M2 != 1 ⇒ 闸门不可信"; exit 2; fi

# ---------------- 5) 负对照 A：网表突变 —— 让调度器**每单元都抬** frameDone ----------------
echo "---- 5) 负对照 A[网表突变]：frameEnd 也认 NEXT_1（每个单元跑完的那个态）⇒ IRQ_INTRA_FRAME > 0 ----"
if ! "$PY" - "$nl" "$work/LayerSched_mutA.v" > "$work/mutA.out" 2>&1 <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
src = open(sys.argv[1], encoding="utf-8").read()
pat = re.compile(r"assign frameEnd = \(state == SchedState_FRAMEDONE\);")
repl = "assign frameEnd = ((state == SchedState_FRAMEDONE) || (state == SchedState_NEXT_1));"
new, n = pat.subn(repl, src)
print("MUTGEN_HITS=%d (期望 1)" % n)
if n != 1:
    sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(new)
PYEOF
then
  echo "JUDGE-RED: 无法构造负对照 A 突变网表（生成风格变了，请更新本判据）⇒ 闸门不可信"; cat "$work/mutA.out"; exit 2
fi
cat "$work/mutA.out"
if cmp -s "$nl" "$work/LayerSched_mutA.v"; then echo "JUDGE-RED: 突变网表与原文相同"; exit 2; fi
if ! "$IVERILOG" -g2012 -o "$work/mutA.vvp" "$tb" "$memv" "$work/LayerSched_mutA.v" > "$work/iv_mutA.log" 2>&1; then
  echo "JUDGE-RED: 负对照 A 突变网表编译失败"; sed -n '1,20p' "$work/iv_mutA.log"; exit 2
fi
run_sim mutA.vvp mutA "$A_DESC_COUNT"; ARC=$?
echo "   突变件跑完(A conv-only, vvp rc=$ARC；预期装置自己判 FAIL —— 因为帧内抬了中断)"
grep -E '^(IRQ_RISES|IRQ_INTRA_FRAME|IRQ_AT_FRAME_END|IRQ_HELD_AFTER_50|UNIT_INDEX_FINAL|RESULT)' "$work/mutA.log" | sed 's/^/   /' || true
MUT_I="$(sed -n 's/^IRQ_INTRA_FRAME=\([0-9]*\)$/\1/p' "$work/mutA.log" | tail -1)"
MUT_R="$(sed -n 's/^IRQ_RISES=\([0-9]*\)$/\1/p' "$work/mutA.log" | tail -1)"
if ! [ "${MUT_I:-x}" -gt 0 ] 2>/dev/null; then
  echo "JUDGE-RED: 负对照 A(A conv-only) 没发火：IRQ_INTRA_FRAME=${MUT_I:-?} 不是 > 0 ⇒ 判据没牙"; exit 2
fi
echo "   NEG_OK[A/conv-only]（原始红证据）：突变后 IRQ_RISES=${MUT_R:-?} IRQ_INTRA_FRAME=${MUT_I:-?} > 0"
echo "      = 只要把 frameDone 的判据从「只在 FRAMEDONE」放宽到「每个单元跑完的态也认」，帧内中断计数当场 > 0"

# ---------------- 6) 负对照 B：descCount 比真实载荷少 1 ⇒ 响亮 err + 零搬运 ----------------
echo "---- 6) 负对照 B[+DESC_COUNT=1（比真实 2 项少 1）]：响亮 err + 一个单元都不跑 ----"
run_sim sim.vvp negB 1 +EXPECT_ERR; BRC=$?
if [ "$BRC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/negB.log"; then
  echo "JUDGE-RED: 负对照 B 未按预期 err（vvp rc=$BRC）"
  grep -E '^(RESULT|TB-ERROR|TB SCHED|IRQ_|DONE_SEEN|ERR_SEEN|UNIT_INDEX|MEM )' "$work/negB.log" || true
  exit 2
fi
grep -E '^(DONE_SEEN|UNIT_INDEX_FINAL|IRQ_RISES|MEM )' "$work/negB.log" | sed 's/^/   /'
BMEM="$(grep -m1 '^MEM rd=' "$work/negB.log")"
BUIDX="$(sed -n 's/^UNIT_INDEX_FINAL=\([0-9]*\)$/\1/p' "$work/negB.log" | tail -1)"
case "$BMEM" in
  "MEM rd=32 wr=0 bursts=1 maxburst=4") : ;;
  *) echo "JUDGE-RED: 负对照 B 的搬运不是「只一笔取表探测」：[$BMEM]"; exit 2 ;;
esac
if [ "${BUIDX:-x}" != "0" ]; then echo "JUDGE-RED: 负对照 B 竟然跑了单元（UNIT_INDEX_FINAL=${BUIDX:-?} != 0）"; exit 2; fi
echo "   NEG_OK[B/conv-only]（原始红证据）：+DESC_COUNT=1 ⇒ 进表前取下标 1 项、发现不是哨兵 ⇒ 响亮 err；"
echo "                    $BMEM（只有一笔 32 B 的哨兵探测取表；**零单元搬运**）、UNIT_INDEX_FINAL=0、IRQ_RISES=0"
# ============================================================================================
# 7) ★ C3.10b/A-1b：旁路链作业（conv3x3 -> head(3x3)+tail(1x1) -> 旁路算子），四个算子各一档
# ============================================================================================
echo "---- 7) 造向量(B 旁路链)：4 档（maxpool/sigmoid/add/resize），每档一份内存镜像 + 黄金 ----"
mkdir -p "$work/bp"
if ! ( cd "$top" && PYTHONIOENCODING=utf-8 PYTHONPATH='third_party/yunet/deps' "$PY" - \
        "$work" "$here" "$top" "$MEMSZ" "$BP_DESC_ADDR" "$BP_A0" "$BP_DECOY" "$BP_T1" "$BP_T2" "$BP_T3" "$BP_INT" \
        "$CIN" "$COUT" "$W" "$HMP" "$HRZ" "$SGROUP" "$SHIFT" "$PERIOD" "$SEED" "$HSCALE" "$TSCALE" "$BP_FETCH_N" <<'PYEOF'
import sys, os, struct
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
work, refdir, topdir = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, refdir)
sys.path.insert(0, os.path.join(topdir, "y1", "tools"))
import conv_unit_ref as R
import bypass_ref as BR
import desc_table as DT

(memsz, desc_addr, a0, decoy, t1, t2, t3, inta, CIN, COUT, W, HMP, HRZ, GROUP, SHIFT,
 PERIOD, SEED, HS, TS, FETCH_N) = (int(x) for x in sys.argv[4:24])

def scale(v, k):
    return [max(-128, min(127, x * k)) for x in v]

wt, x_chw8, x_ddr8, _ = R.build(CIN, COUT, HMP, W, seed=SEED, shift=SHIFT)
wt_head = scale(wt, HS)
wt_tail = R.centre_tap(scale(wt, TS), CIN, COUT)
_, x_chw4, x_ddr4, _ = R.build(CIN, COUT, HRZ, W, seed=SEED, shift=SHIFT)

def pat(i):
    return ((i % PERIOD) * 131 + 7) % PERIOD
assert PERIOD % 128 != 0 and 128 % PERIOD != 0, "模式周期与块长不互素"

def be_words(d):
    return [(d["TYPE"] & 0xFF) | ((d["FLAGS"] & 0xFF) << 8),
            (d["IMG_W"] & 0xFFFF) | ((d["IMG_H"] & 0xFFFF) << 16),
            (d["C_IN"] & 0xFFFF) | ((d["C_OUT"] & 0xFFFF) << 16),
            (d["GROUP"] & 0xFF) | ((d["STRIDE"] & 0xF) << 8) | ((d["PAD"] & 0xF) << 12),
            d["SRC_ADDR"], d["DST_ADDR"], d["IN_BYTES"],
            (d["QUANT_SHIFT"] & 0xFF) | ((d["LAYER_ID"] & 0xFF) << 8)]

def mk_conv(flags, src, dst, h, lay, tpe=0x01):
    return {"TYPE": tpe, "FLAGS": flags, "IMG_W": W, "IMG_H": h, "C_IN": CIN, "C_OUT": COUT,
            "GROUP": GROUP, "STRIDE": 1, "PAD": 1, "SRC_ADDR": src, "DST_ADDR": dst,
            "IN_BYTES": CIN * h * W, "QUANT_SHIFT": SHIFT, "LAYER_ID": lay}

def emit(job, h, x_chw, x_ddr, byp_item, byp_gold, seg_op, extra_mem=None, note=""):
    jd = os.path.join(work, "bp", job)
    os.makedirs(jd, exist_ok=True)
    a1, mid, a2 = R.sched_chain(x_chw, wt_head, wt_tail, CIN, COUT, h, W, SHIFT)
    a1b, midb, a2b = R.sched_chain_naive(x_ddr, wt_head, wt_tail, CIN, COUT, h, W, SHIFT)
    assert a1 == a1b and mid == midb and a2 == a2b, "作业 %s：两条独立黄金不一致" % job
    assert len(a1) == CIN * h * W and len(a2) == CIN * h * W
    pre = bytes(pat(i) for i in range(memsz))
    mem = bytearray(pre)
    # ★ A-1b：载荷 4 项 —— plain(0b01) + **head(0b00)** + **tail(0b11)** + 旁路(0b01)。
    #   head+tail 由调度器塌缩成**一次 go**（chainLen=2，SRC = head 的 T1、DST = tail 的 T2）；
    #   中间张量的"槽位"写成诱饵 `decoy`（链**不得**碰它 —— 这正好被 `UNCHANGED[DECOY]` 判据盯住）。
    d0 = mk_conv(0b01, a0, t1, h, 0)                    # plain：A0 -> T1
    d1 = mk_conv(0b00, t1, decoy, h, 1)                 # head ：T1 -> 片上（DST 槽 = 诱饵）
    d2 = mk_conv(0b11, decoy, t2, h, 2, tpe=0x02)       # tail ：片上 -> T2（1x1 中心抽头）
    d3 = byp_item                                       # 旁路：T2 -> T3
    blob = DT.pack_table([d0, d1, d2, d3])
    assert len(blob) == 160, "表字节数 %d != 160" % len(blob)
    w0 = list(struct.unpack_from("<8I", blob, 0))
    w1 = list(struct.unpack_from("<8I", blob, 32))
    w2 = list(struct.unpack_from("<8I", blob, 64))
    w3 = list(struct.unpack_from("<8I", blob, 96))
    ws = list(struct.unpack_from("<8I", blob, 128))
    assert w0 == be_words(d0) == DT.reference_words(d0), "作业 %s: 描述符0 三方对账不符" % job
    assert w1 == be_words(d1) == DT.reference_words(d1), "作业 %s: 描述符1 三方对账不符" % job
    assert w2 == be_words(d2) == DT.reference_words(d2), "作业 %s: 描述符2 三方对账不符" % job
    assert w3 == be_words(byp_item) == DT.reference_words(byp_item), "作业 %s: 旁路项 三方对账不符" % job
    assert (w0[0] >> 8) & 0xFF == 0b01, "作业 %s: 项0 FLAGS 应为 0b01(plain)" % job
    assert (w1[0] >> 8) & 0xFF == 0b00, "作业 %s: 项1 FLAGS 应为 0b00(head)" % job
    assert (w2[0] >> 8) & 0xFF == 0b11, "作业 %s: 项2 FLAGS 应为 0b11(tail)" % job
    assert (ws[0] & 0xFF) == 0xFF and (ws[0] >> 8) == 0, "作业 %s: 下标 4 不是哨兵" % job
    mem[desc_addr:desc_addr + len(blob)] = blob
    mem[a0:a0 + len(x_ddr)] = bytes(v & 0xFF for v in x_ddr)
    if extra_mem is not None:
        for (ad, toks) in extra_mem:
            mem[ad:ad + len(toks)] = bytes(v & 0xFF for v in toks)
    for nm, ad, gold in (("T1", t1, a1), ("T2", t2, a2), ("T3", t3, byp_gold)):
        d = sum(1 for j in range(len(gold)) if pre[ad + j] != (gold[j] & 0xFF))
        assert d >= len(gold) - 20, "%s 区预载与黄金只有 %d/%d 不同 ⇒ '不写'有机会蒙过" % (nm, d, len(gold))
    open(jd + "/mem.hex", "w").write("".join("%02x\n" % b for b in mem))
    R.dump_bytes(jd + "/gold_t1.hex", a1)
    R.dump_bytes(jd + "/gold_t2.hex", a2)
    R.dump_bytes(jd + "/gold_t3.hex", byp_gold)
    open(jd + "/descD.args", "w").write(" ".join(str(x) for x in w0))
    open(jd + "/descE.args", "w").write(" ".join(str(x) for x in w1))
    open(jd + "/descF.args", "w").write(" ".join(str(x) for x in w2))
    open(jd + "/descG.args", "w").write(" ".join(str(x) for x in w3))
    clen = CIN * h * W
    spec = ["A0 %d %d -" % (a0, clen),
            "DECOY %d %d -" % (decoy, clen),
            "T1 %d %d gold_t1.hex" % (t1, clen),
            "T2 %d %d gold_t2.hex" % (t2, clen),
            "T3 %d %d gold_t3.hex" % (t3, len(byp_gold))]
    if seg_op == "add":
        spec.insert(3, "INT %d %d -" % (inta, 2 * clen))
    open(jd + "/spec.txt", "w").write("\n".join(spec) + "\n")
    convB = clen
    rd2, wr2 = {"maxpool": (convB, convB // 4), "sigmoid": (convB, convB),
                "add": (2 * convB, convB), "resize": (convB, 4 * convB)}[seg_op]
    assert (2 * convB + rd2) % 128 == 0 and (2 * convB + wr2) % 128 == 0, "作业 %s 流量不是 128 的整数倍" % job
    rd = FETCH_N * 32 + 2 * convB + rd2
    wr = 2 * convB + wr2
    ar128 = (2 * convB + rd2) // 128
    aw128 = (2 * convB + wr2) // 128
    open(jd + "/job.txt", "w").write("\n".join([
        "AR_BURSTS n32=%d n128=%d total=%d" % (FETCH_N, ar128, FETCH_N + ar128),
        "AW_BURSTS n128=%d total=%d B_OK=%d" % (aw128, aw128, aw128),
        "MEM rd=%d wr=%d bursts=%d maxburst=16" % (rd, wr, FETCH_N + ar128 + aw128)]) + "\n")
    open(jd + "/seg.txt", "w").write("%s %d %d %d %d %d\n" % (seg_op, CIN, W, h, byp_item["SRC_ADDR"], t3))
    assert len(set(byp_gold)) > 1, "%s: T3 是常数" % job
    assert sum(1 for v in byp_gold if v != 0) > 0, "%s: T3 全 0" % job
    print("BP_JOB %-3s h=%d tensor=%dB T3=%dB rd=%d wr=%d %s" % (job, h, clen, len(byp_gold), rd, wr, note))

# ---- maxpool 档：计划点名的"2x2/s2 吃 (C=8,W=32,H=8) 吐 (8,16,4)" ----
a1, _, a2mp = R.sched_chain(x_chw8, wt_head, wt_tail, CIN, COUT, HMP, W, SHIFT)
g_mp = BR.maxpool_ref(a2mp, CIN, W, HMP)
assert len(g_mp) == CIN * (W // 2) * (HMP // 2) == 512
TL, TR, BL, BRs = BR.corner_subsamples(a2mp, CIN, W, HMP)
assert g_mp != TL and g_mp != TR and g_mp != BL and g_mp != BRs, "maxpool 黄金 == 某个整块平移（防混叠失败）"
emit("mp", HMP, x_chw8, x_ddr8,
     {"TYPE": 0x10, "FLAGS": 0b01, "IMG_W": W // 2, "IMG_H": HMP // 2, "C_IN": CIN, "C_OUT": COUT,
      "GROUP": GROUP, "STRIDE": 2, "PAD": 0, "SRC_ADDR": t2, "DST_ADDR": t3,
      "IN_BYTES": CIN * W * HMP, "QUANT_SHIFT": 0, "LAYER_ID": 2},
     g_mp, "maxpool", note="(防混叠: 黄金 != 四个整块平移子采样)")

# ---- sigmoid 档：形状保持 ----
g_sg = BR.sigmoid_ref(a2mp, CIN, W, HMP)
assert all(0 <= v <= 127 for v in g_sg), "sigmoid 黄金越界"
assert len(set(g_sg)) >= 4, "sigmoid 黄金分辨率太低（distinct=%d）" % len(set(g_sg))
emit("sig", HMP, x_chw8, x_ddr8,
     {"TYPE": 0x14, "FLAGS": 0b01, "IMG_W": W, "IMG_H": HMP, "C_IN": CIN, "C_OUT": COUT,
      "GROUP": GROUP, "STRIDE": 1, "PAD": 0, "SRC_ADDR": t2, "DST_ADDR": t3,
      "IN_BYTES": CIN * W * HMP, "QUANT_SHIFT": 4, "LAYER_ID": 2},
     g_sg, "sigmoid", note="(distinct=%d)" % len(set(g_sg)))

# ---- add 档：★ O1 —— 两操作数列交织在同一 RD 流里（第二路不占描述符字段）----
b_op = [max(-128, min(127, v * 2)) for v in a2mp]
assert b_op != a2mp, "add 两路相等 ⇒ 加法退化成 ×2"
g_add = BR.add_ref(a2mp, b_op, CIN, W, HMP)
se = BR.add_sat_events(a2mp, b_op)
assert se > 0, "add 向量没有饱和点 ⇒ '饱和 vs 回绕'不可分辨（橡皮章）"
inter = BR.interleave_add(a2mp, b_op, CIN, W, HMP)
assert len(inter) == 2 * CIN * W * HMP
emit("add", HMP, x_chw8, x_ddr8,
     {"TYPE": 0x13, "FLAGS": 0b01, "IMG_W": W, "IMG_H": HMP, "C_IN": CIN, "C_OUT": COUT,
      "GROUP": GROUP, "STRIDE": 1, "PAD": 0, "SRC_ADDR": inta, "DST_ADDR": t3,
      "IN_BYTES": 2 * CIN * W * HMP, "QUANT_SHIFT": 0, "LAYER_ID": 2},
     g_add, "add", extra_mem=[(inta, inter)],
     note="(SAT_EVENTS=%d，双操作数列交织 @SRC_ADDR)" % se)

# ---- resize 档：x2 最近邻（输入/输出相位交替，H=4 -> 输出 (8,64,8)）----
a1r, _, a2r = R.sched_chain(x_chw4, wt_head, wt_tail, CIN, COUT, HRZ, W, SHIFT)
g_rz = BR.resize2x_ref(a2r, CIN, W, HRZ)
assert len(g_rz) == 4 * CIN * W * HRZ == 4096
emit("rz", HRZ, x_chw4, x_ddr4,
     {"TYPE": 0x11, "FLAGS": 0b01, "IMG_W": 2 * W, "IMG_H": 2 * HRZ, "C_IN": CIN, "C_OUT": COUT,
      "GROUP": GROUP, "STRIDE": 2, "PAD": 0, "SRC_ADDR": t2, "DST_ADDR": t3,
      "IN_BYTES": 4 * CIN * W * HRZ, "QUANT_SHIFT": 0, "LAYER_ID": 2},
     g_rz, "resize", note="(输出 4x 输入)")

# ---- ★ A-1b：两个"非法链形状"负对照的小表（每个一份内存镜像 + 首项 args）----
#   (i)  `middle`(0b10) **没有前驱**（表首就是 middle）⇒ 取到它就当场 err；
#   (ii) `head`(0b00) **没有 tail**（表尾哨兵紧跟 head）⇒ 扫链时撞上哨兵 ⇒ err。
#   两档都必须是"**零设备搬运**"（一个激活字节都不搬、一个 AW/W 都不发）。
def emit_neg_shape(name, item, note):
    jd = os.path.join(work, "bp", name)
    os.makedirs(jd, exist_ok=True)
    blob = DT.pack_table([item])                         # 1 载荷 + 哨兵 = 64 B
    assert len(blob) == 64, "作业 %s: 表字节数 %d != 64" % (name, len(blob))
    w0 = list(struct.unpack_from("<8I", blob, 0))
    assert w0 == be_words(item) == DT.reference_words(item), "作业 %s: 项字三方对账不符" % name
    pre = bytes(pat(i) for i in range(memsz))
    mem = bytearray(pre)
    mem[desc_addr:desc_addr + len(blob)] = blob
    open(jd + "/mem.hex", "w").write("".join("%02x\n" % b for b in mem))
    open(jd + "/pre.hex", "w").write("".join("%02x\n" % b for b in mem))
    open(jd + "/descD.args", "w").write(" ".join(str(x) for x in w0))
    open(jd + "/descE.args", "w").write(" ".join(str(x) for x in w0))   # 占位（TB 的 chk_desc(1) 要它）
    print("BP_NEGSHAPE %-8s %s w0=0x%08x" % (name, note, w0[0] & 0xFFFFFFFF))

emit_neg_shape("negmid",  mk_conv(0b10, a0, t1, HMP, 0),
               "(middle 0b10 无前驱 ⇒ err)")
emit_neg_shape("neghead", mk_conv(0b00, a0, t1, HMP, 0),
               "(head 0b00 无 tail ⇒ err)")

print("BP_MEMGEN memsz=%d desc=%d A0=%d DECOY=%d T1=%d T2=%d T3=%d INT=%d" %
      (memsz, desc_addr, a0, decoy, t1, t2, t3, inta))
print("BP_CHAIN conv3x3(0b01) -> head(0b00)+tail(0b11) [= 一个 go, chainLen=2] -> 旁路算子(4 档)；表 = 4 载荷 + 哨兵 = 160 B")
print("BP_WEIGHTS 头 %d B / 尾 %d B（与 conv-only 作业同一份）" % (len(wt_head), len(wt_tail)))
PYEOF
) ; then
  echo "FATAL: 生成旁路链向量/黄金失败（或非退化前提不成立）⇒ 闸门不可信"
  exit 3
fi
for j in mp sig add rz; do
  for f in mem.hex descD.args descE.args descF.args descG.args gold_t1.hex gold_t2.hex gold_t3.hex spec.txt job.txt seg.txt; do
    [ -s "$work/bp/$j/$f" ] || { echo "FATAL: 作业 $j 的激励文件 $f 缺失或为空"; exit 3; }
  done
  # 预载镜像 = mem.hex 本身（golden 不预载；mem.hex 只含背景 + 激活 + 描述符表 + add 的交织源）
  cp -f "$work/bp/$j/mem.hex" "$work/bp/$j/pre.hex"
done
echo "   旁路链向量 OK（4 档：mp/sig/add/rz）"

for j in mp sig add rz; do
  jd="$work/bp/$j"
  case "$j" in
    mp)  segop=maxpool ; label="maxpool(2x2/s2)" ;;
    sig) segop=sigmoid ; label="sigmoid(Q3.4->Q0.7)" ;;
    add) segop=add     ; label="add(饱和, 双操作数列交织)" ;;
    rz)  segop=resize  ; label="resize(x2 最近邻)" ;;
  esac
  echo "---- 7.$j) 旁路链正对照[$label]：conv3x3 -> head+tail(3x3->1x1) -> $segop ----"
  run_job "$work/sim.vvp" "$jd" pos "$BP_DESC_COUNT"; JRC=$?
  if [ "$JRC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$jd/pos.log"; then
    echo "JUDGE-RED[$j]: 正对照仿真未 PASS（vvp rc=$JRC）"
    grep -E '^(RESULT|TB-ERROR|TB SCHED|IRQ_|UNIT_INDEX|DONE_SEEN|MEM )' "$jd/pos.log" || true
    exit 1
  fi
  grep -E '^(TB SCHED:|IRQ_|IRQ_HELD|UNIT_INDEX_FINAL|AR_BURSTS|AW_BURSTS|DONE_SEEN|MEM )' "$jd/pos.log" | sed 's/^/   /'
  ARL="$(grep -m1 '^AR_BURSTS ' "$jd/pos.log")"
  AWL="$(grep -m1 '^AW_BURSTS ' "$jd/pos.log")"
  MEML="$(grep -m1 '^MEM rd=' "$jd/pos.log")"
  EXP_ARL="$(sed -n '1p' "$jd/job.txt")"
  EXP_AWL="$(sed -n '2p' "$jd/job.txt")"
  EXP_MEML="$(sed -n '3p' "$jd/job.txt")"
  if [ "$ARL" != "$EXP_ARL" ]; then echo "JUDGE-RED[$j]: AR 分档不符 got=[$ARL] exp=[$EXP_ARL]"; exit 1; fi
  if [ "$AWL" != "$EXP_AWL" ]; then echo "JUDGE-RED[$j]: AW 分档不符 got=[$AWL] exp=[$EXP_AWL]"; exit 1; fi
  if [ "$MEML" != "$EXP_MEML" ]; then echo "JUDGE-RED[$j]: 内存模型计数不符 got=[$MEML] exp=[$EXP_MEML]"; exit 1; fi
  echo "   流量对账 OK（三方一致）：$ARL / $AWL / $MEML"
  # ★ C3.11b 正对照（B 作业同款）：合法表不得被逐项字段校验误报
  J_ERR="$(sed -n 's/^DONE_SEEN=[0-9]* ERR_SEEN=\([0-9]*\).*$/\1/p' "$jd/pos.log" | tail -1)"
  if [ "${J_ERR:-x}" != "0" ]; then
    echo "JUDGE-RED[$j]: 正对照(B) 竟然报 err（ERR_SEEN=${J_ERR:-?}）⇒ 合法表被新判据误报"; exit 1
  fi
  cp -f "$jd/pos.dump" "$jd/dump.hex"     # judge_job / judge_seg 统一读 <jobdir>/dump.hex
  judge_job "$jd" > "$jd/judge.txt"
  cat "$jd/judge.txt" | sed 's/^/   /'
  JM1="$(sed -n 's/^MISMATCH\[T1\]=\([0-9]*\)$/\1/p' "$jd/judge.txt")"
  JM2="$(sed -n 's/^MISMATCH\[T2\]=\([0-9]*\)$/\1/p' "$jd/judge.txt")"
  JM3="$(sed -n 's/^MISMATCH\[T3\]=\([0-9]*\)$/\1/p' "$jd/judge.txt")"
  JUA0="$(sed -n 's/^UNCHANGED\[A0\]=\([0-9]*\)$/\1/p' "$jd/judge.txt")"
  JUD="$(sed -n 's/^UNCHANGED\[DECOY\]=\([0-9]*\)$/\1/p' "$jd/judge.txt")"
  JOB="$(sed -n 's/^OTHER_BAD=\([0-9]*\)$/\1/p' "$jd/judge.txt")"
  if [ "$JM1" != "0" ]; then echo "JUDGE-RED[$j]: T1 != 黄金（MISMATCH=$JM1）"; exit 1; fi
  if [ "$JM2" != "0" ]; then echo "JUDGE-RED[$j]: T2 != 黄金（MISMATCH=$JM2）⇒ 链（head+tail）/conv 分派错"; exit 1; fi
  if [ "$JM3" != "0" ]; then echo "JUDGE-RED[$j]: T3(末张量) != 黄金（MISMATCH=$JM3）⇒ 旁路算子数值错"; exit 1; fi
  if [ "$JUA0" != "0" ] || [ "$JUD" != "0" ] || [ "$JOB" != "0" ]; then
    echo "JUDGE-RED[$j]: 三区域失败（A0=$JUA0 DECOY=$JUD OTHER=$JOB）"; exit 1
  fi
  echo "   判据1 OK[$j]：T1/T2/T3 逐字节 == 黄金；判据2 OK：A0/DECOY 未改、末张量之外未动"
  read -r _so _sc _sw _sh _ssrc _sdst < "$jd/seg.txt"
  judge_seg "$jd" "$segop" "$_sc" "$_sw" "$_sh" "$_ssrc" "$_sdst" > "$jd/segjudge.txt"
  cat "$jd/segjudge.txt" | sed 's/^/   /'
  SM="$(sed -n "s/^SEG_MISMATCH\[$segop\]=\([0-9]*\)$/\1/p" "$jd/segjudge.txt")"
  SL="$(sed -n "s/^SEG_LEN\[$segop\]=\([0-9]*\)$/\1/p" "$jd/segjudge.txt")"
  if [ "$SM" != "0" ]; then echo "JUDGE-RED[$j]: 旁路段逐点对账失败（SEG_MISMATCH[$segop]=$SM）"; exit 1; fi
  echo "   ★ 判据3 OK[$j]：$label 段逐点 SEG_MISMATCH=0（len=$SL，输入取硬件 T2/INT、输出比硬件 T3）"
  if ! irq_check "$jd/pos.log" "$BP_DESC_COUNT" "B/$j"; then exit 1; fi
done
# 7e) 负对照 A（旁路链，3 单元）：同一份突变网表跑旁路链作业 ⇒ IRQ_INTRA_FRAME > 0
echo "---- 7e) 负对照 A[网表突变] 在**旁路链**（3 单元）上：⇒ IRQ_INTRA_FRAME > 0 ----"
jd="$work/bp/mp"
run_job "$work/mutA.vvp" "$jd" mutA "$BP_DESC_COUNT"; ARC2=$?
echo "   突变件跑完(B 旁路链, vvp rc=$ARC2；预期装置自己判 FAIL —— 因为帧内抬了中断)"
grep -E '^(IRQ_RISES|IRQ_INTRA_FRAME|IRQ_AT_FRAME_END|IRQ_HELD_AFTER_50|UNIT_INDEX_FINAL|RESULT)' "$jd/mutA.log" | sed 's/^/   /' || true
MUT_I2="$(sed -n 's/^IRQ_INTRA_FRAME=\([0-9]*\)$/\1/p' "$jd/mutA.log" | tail -1)"
MUT_R2="$(sed -n 's/^IRQ_RISES=\([0-9]*\)$/\1/p' "$jd/mutA.log" | tail -1)"
if ! [ "${MUT_I2:-x}" -gt 0 ] 2>/dev/null; then
  echo "JUDGE-RED: 负对照 A(B 旁路链) 没发火：IRQ_INTRA_FRAME=${MUT_I2:-?} 不是 > 0 ⇒ 判据没牙"; exit 2
fi
echo "   NEG_OK[A/bypass-chain]（原始红证据）：突变后 IRQ_RISES=${MUT_R2:-?} IRQ_INTRA_FRAME=${MUT_I2:-?} > 0（3 单元的链）"

# 7f) 负对照 B（旁路链）：+DESC_COUNT=2（比真实 3 项少 1）⇒ 响亮 err + 零搬运
echo "---- 7f) 负对照 B[旁路链 +DESC_COUNT=$(( BP_DESC_COUNT - 2 ))（比真实 $BP_DESC_COUNT 项少 2）]：响亮 err + 一个单元都不跑 ----"
run_job "$work/sim.vvp" "$jd" negB "$(( BP_DESC_COUNT - 2 ))" +EXPECT_ERR; BRC2=$?
if [ "$BRC2" -ne 0 ] || ! grep -q '^RESULT: PASS' "$jd/negB.log"; then
  echo "JUDGE-RED: 负对照 B(旁路链) 未按预期 err（vvp rc=$BRC2）"
  grep -E '^(RESULT|TB-ERROR|TB SCHED|IRQ_|DONE_SEEN|ERR_SEEN|UNIT_INDEX|MEM )' "$jd/negB.log" || true
  exit 2
fi
grep -E '^(DONE_SEEN|UNIT_INDEX_FINAL|IRQ_RISES|MEM )' "$jd/negB.log" | sed 's/^/   /'
BMEM2="$(grep -m1 '^MEM rd=' "$jd/negB.log")"
BUIDX2="$(sed -n 's/^UNIT_INDEX_FINAL=\([0-9]*\)$/\1/p' "$jd/negB.log" | tail -1)"
case "$BMEM2" in
  "MEM rd=32 wr=0 bursts=1 maxburst=4") : ;;
  *) echo "JUDGE-RED: 负对照 B(旁路链) 的搬运不是「只一笔取表探测」：[$BMEM2]"; exit 2 ;;
esac
if [ "${BUIDX2:-x}" != "0" ]; then echo "JUDGE-RED: 负对照 B(旁路链) 竟然跑了单元（UNIT_INDEX_FINAL=${BUIDX2:-?} != 0）"; exit 2; fi
echo "   NEG_OK[B/bypass-chain]（原始红证据）：+DESC_COUNT=$(( BP_DESC_COUNT - 2 )) ⇒ 进表前取下标 $(( BP_DESC_COUNT - 2 )) 项"
echo "                   （那是链的 **tail** 项、不是哨兵）"
echo "                    ⇒ 响亮 err；$BMEM2（只有一笔 32 B 的哨兵探测取表；**零单元搬运**）、UNIT_INDEX_FINAL=0、IRQ_RISES=0"

# 7g) 比较器自检（旁路链末张量扰动一个字节 ⇒ 恰好 1）
echo "---- 7g) 比较器自检(B)：扰动旁路链最终黄金一个字节 ⇒ T3 MISMATCH 必须恰好 1 ----"
"$PY" - "$work/bp/mp" <<'PYEOF'
import sys
jd = sys.argv[1]
t = [l.strip() for l in open(jd + "/gold_t3.hex") if l.strip()]
i = len(t) // 2
t[i] = "%02x" % ((int(t[i], 16) ^ 0x01) & 0xFF)
open(jd + "/gold_t3_pert.hex", "w").write("\n".join(t) + "\n")
print("CMP_SELFTEST_PERTURB_B idx=%d" % i)
PYEOF
mv "$work/bp/mp/gold_t3.hex" "$work/bp/mp/gold_t3_orig.hex"
mv "$work/bp/mp/gold_t3_pert.hex" "$work/bp/mp/gold_t3.hex"
judge_job "$work/bp/mp" > "$work/bp/mp/pert.judge"
SELF_T3="$(sed -n 's/^MISMATCH\[T3\]=\([0-9]*\)$/\1/p' "$work/bp/mp/pert.judge")"
mv "$work/bp/mp/gold_t3_orig.hex" "$work/bp/mp/gold_t3.hex"
echo "   CMP_SELFTEST_B T3_MISMATCH=$SELF_T3（期望恰好 1）"
if [ "$SELF_T3" != "1" ]; then echo "JUDGE-RED: 比较器自检(B) T3_MISMATCH=$SELF_T3 != 1 ⇒ 闸门不可信"; exit 2; fi

# ---------------- 7h) ★ A-1b 新负对照：非法链形状 ⇒ 响亮 err + 零设备搬运 ----------------
#   ★ 这是 per-operator 编码**新增**的非法形状（旧编码里没有"middle"这个概念）：
#     · `middle`（0b10）只能紧跟 head/middle ⇒ **表首就是 middle** 必须当场 err；
#     · `head`（0b00）后面必须跟 middle/tail ⇒ **head 撞上哨兵**必须当场 err（"head 没有 tail"）。
#   两档都必须 **err + 零设备搬运**（不发任何激活 AR/AW）；取表字节数按取表笔数算：
#     negmid  = 哨兵探测 1 + 载荷 1 = 2 笔 = 64 B；neghead = 1 + 1 + 扫描中撞哨兵 1 = 3 笔 = 96 B。
echo "---- 7h) 新负对照[middle 无前驱]：表 = [middle(0b10)] + 哨兵 ⇒ 响亮 err + 零搬运 ----"
run_job "$work/sim.vvp" "$work/bp/negmid" negmid 1 +EXPECT_ERR; NMID=$?
if [ "$NMID" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/bp/negmid/negmid.log"; then
  echo "JUDGE-RED: middle 无前驱时装置没按预期 err（vvp rc=$NMID）"
  grep -E '^(RESULT|TB-ERROR|TB SCHED|IRQ_|UNIT_INDEX|DONE_SEEN|MEM )' "$work/bp/negmid/negmid.log" || true
  exit 2
fi
grep -E '^(DONE_SEEN|UNIT_INDEX_FINAL|IRQ_RISES|AW_BURSTS|MEM )' "$work/bp/negmid/negmid.log" | sed 's/^/   /'
NMID_MEM="$(grep -m1 '^MEM rd=' "$work/bp/negmid/negmid.log")"
NMID_UIDX="$(sed -n 's/^UNIT_INDEX_FINAL=\([0-9]*\)$/\1/p' "$work/bp/negmid/negmid.log" | tail -1)"
NMID_IRQ="$(sed -n 's/^IRQ_RISES=\([0-9]*\)$/\1/p' "$work/bp/negmid/negmid.log" | tail -1)"
NMID_AW="$(grep -m1 '^AW_BURSTS ' "$work/bp/negmid/negmid.log")"
case "$NMID_MEM" in
  "MEM rd=64 wr=0 bursts=2 maxburst=4") : ;;
  *) echo "JUDGE-RED: negmid 的搬运不是「只取表、零设备搬运」：[$NMID_MEM]"; exit 2 ;;
esac
if [ "${NMID_UIDX:-x}" != "0" ] || [ "${NMID_IRQ:-x}" != "0" ]; then
  echo "JUDGE-RED: negmid 竟然跑了单元/抬了中断（UNIT_INDEX_FINAL=${NMID_UIDX:-?} IRQ_RISES=${NMID_IRQ:-?}）"; exit 2
fi
echo "   NEG_OK[middle 无前驱]（原始红证据）：$NMID_MEM（**只有两笔 32 B 取表**：哨兵探测 + 那个 middle），"
echo "                   UNIT_INDEX_FINAL=0、IRQ_RISES=0、$NMID_AW ⇒ 零设备搬运"

echo "---- 7i) 新负对照[head 没有 tail]：表 = [head(0b00)] + 哨兵 ⇒ 响亮 err + 零搬运 ----"
run_job "$work/sim.vvp" "$work/bp/neghead" neghead 1 +EXPECT_ERR; NHED=$?
if [ "$NHED" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/bp/neghead/neghead.log"; then
  echo "JUDGE-RED: head 没有 tail 时装置没按预期 err（vvp rc=$NHED）"
  grep -E '^(RESULT|TB-ERROR|TB SCHED|IRQ_|UNIT_INDEX|DONE_SEEN|MEM )' "$work/bp/neghead/neghead.log" || true
  exit 2
fi
grep -E '^(DONE_SEEN|UNIT_INDEX_FINAL|IRQ_RISES|AW_BURSTS|MEM )' "$work/bp/neghead/neghead.log" | sed 's/^/   /'
NHED_MEM="$(grep -m1 '^MEM rd=' "$work/bp/neghead/neghead.log")"
NHED_UIDX="$(sed -n 's/^UNIT_INDEX_FINAL=\([0-9]*\)$/\1/p' "$work/bp/neghead/neghead.log" | tail -1)"
NHED_IRQ="$(sed -n 's/^IRQ_RISES=\([0-9]*\)$/\1/p' "$work/bp/neghead/neghead.log" | tail -1)"
NHED_AW="$(grep -m1 '^AW_BURSTS ' "$work/bp/neghead/neghead.log")"
case "$NHED_MEM" in
  "MEM rd=96 wr=0 bursts=3 maxburst=4") : ;;
  *) echo "JUDGE-RED: neghead 的搬运不是「取表 + 扫描 + 零设备搬运」：[$NHED_MEM]"; exit 2 ;;
esac
if [ "${NHED_UIDX:-x}" != "0" ] || [ "${NHED_IRQ:-x}" != "0" ]; then
  echo "JUDGE-RED: neghead 竟然跑了单元/抬了中断（UNIT_INDEX_FINAL=${NHED_UIDX:-?} IRQ_RISES=${NHED_IRQ:-?}）"; exit 2
fi
echo "   NEG_OK[head 没有 tail]（原始红证据）：$NHED_MEM（**只有三笔 32 B 取表**：哨兵探测 + head + 扫链时撞上的哨兵），"
echo "                   UNIT_INDEX_FINAL=0、IRQ_RISES=0、$NHED_AW ⇒ 零设备搬运"

# ============================================================================================
# 8) ★ C3.11b —— S6 的**逐项字段校验**（每一个载荷条目**自己的字段**是否合法）
#    与 tools/desc_table.py 的 validate 规则 (2)(3)(4) 逐条对应（见 rtl/LayerSched.scala 文件头）：
#      SRC/DST 32 B 对齐 · DDR 窗越界 · 自环 SRC==DST · IN_BYTES 合法（%32==0 且 !=0）· 非法 TYPE
#    每道负作业**必须**：响亮 err（RESULT: PASS under +EXPECT_ERR、ERR_SEEN=1）+ **零设备搬运**
#      （DONE_SEEN=0、AW_BURSTS total=0、MEM rd=64 = 只有两笔 32 B 取表：哨兵探测 + 第 0 项）
#      + UNIT_INDEX_FINAL=0 + IRQ_RISES=0。
#    ★ 这些表的**第 0 个载荷项**就是非法的 ⇒ RTL 在**取表相位**（给任何单元举 go 之前）当场发现
#      ⇒ 真·零搬运。（流式调度下"靠后的条目"只能在跑过前缀之后被发现 —— RTL 文件头的诚实记录。）
#    正对照 = 上面 §3/§7 的合法表（A 作业 3 项、B 作业 4 项）必须**不**报 err（ERR_SEEN=0）；
#      ★ 而且 A/B 的表**故意复用地址**（项 i 的 DST == 项 i+1 的 SRC、head 的 DST == tail 的 SRC）
#      ⇒ 若把自环判据写成"全局地址唯一"，那几张合法表当场误报 —— 这就是"逐条目"口径的活证据。
# ============================================================================================
echo "---- 8) 造向量(C3.11b 字段规则负作业 x6)：每张表故意违反**一条**字段规则（表 = 1~2 载荷 + 哨兵）----"
mkdir -p "$work/fld"
if ! ( cd "$top" && PYTHONIOENCODING=utf-8 PYTHONPATH='third_party/yunet/deps' "$PY" - \
        "$work" "$here" "$top" "$MEMSZ" "$BP_DESC_ADDR" "$PERIOD" <<'PYEOF'
import sys, os, struct
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
work, refdir, topdir = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, refdir)
sys.path.insert(0, os.path.join(topdir, "y1", "tools"))
import desc_table as DT

memsz, desc_addr, PERIOD = (int(x) for x in sys.argv[4:7])

A0  = 131072       # 0x020000 激活输入区（32 B 对齐、窗内）
T1  = 262144       # 0x040000
MID = 196608       # 0x030000 链的**片上占位槽**（head 的 DST / tail 的 SRC；主口看不到它）
DST = 1441792      # 0x160000
WIN = 1 << 28      # = desc_table.DDR_BYTES（与 DdrMaster.ADDR_W = 28 同源）
assert WIN == DT.DDR_BYTES, "DDR 窗口径与 desc_table.py 不一致"

def pat(i):
    return ((i % PERIOD) * 131 + 7) % PERIOD

def be_words(d):
    return [(d["TYPE"] & 0xFF) | ((d["FLAGS"] & 0xFF) << 8),
            d["IMG_W"] | (d["IMG_H"] << 16), d["C_IN"] | (d["C_OUT"] << 16),
            d["GROUP"] | (d["STRIDE"] << 8) | (d["PAD"] << 12),
            d["SRC_ADDR"], d["DST_ADDR"], d["IN_BYTES"],
            d["QUANT_SHIFT"] | (d["LAYER_ID"] << 8)]

def mk(tpe, flags, src, dst, inb, iw=32, ih=8, ci=8, co=8, grp=1, stride=1, pad=1, qs=6, lay=0):
    return {"TYPE": tpe, "FLAGS": flags, "IMG_W": iw, "IMG_H": ih, "C_IN": ci, "C_OUT": co,
            "GROUP": grp, "STRIDE": stride, "PAD": pad, "SRC_ADDR": src, "DST_ADDR": dst,
            "IN_BYTES": inb, "QUANT_SHIFT": qs, "LAYER_ID": lay}

# ---- 六道负作业：每道只违反**一条**规则（其余字段全部合法）----
JOBS = [
    ("neg_alignsrc", [mk(0x01, 0b01, A0 + 4, T1, 2048)],
     "SRC_ADDR % 32 != 0（32 B 不对齐）"),
    ("neg_oobdst", [mk(0x01, 0b01, A0, WIN, 2048)],
     "DST_ADDR + IN_BYTES > 2^28（越 DDR 窗）"),
    ("neg_loop", [mk(0x01, 0b01, MID, MID, 2048)],
     "SRC_ADDR == DST_ADDR（自环）"),
    ("neg_inbytes", [mk(0x10, 0b01, A0, T1, 0, iw=16, ih=4, stride=2, pad=0, qs=0)],
     "IN_BYTES == 0（旁路项 maxpool：BypassExec 根本不读 IN_BYTES，只有本预检能拦）"),
    ("neg_type", [mk(0x77, 0b01, A0, T1, 2048)],
     "TYPE = 0x77（非法 TYPE，不在已知集合里）"),
    # ★ 对齐规则的**可分辨**一档：head 的 DST_ADDR 是**片上占位槽**（链真正用的是 tail 的 DST）
    #   ⇒ 主口永远看不到它 ⇒ 这一档只有本表的预检能拦（见下面 8x) 的突变控制）。
    ("neg_alignhead", [mk(0x01, 0b00, A0, T1 + 4, 2048), mk(0x02, 0b11, MID, DST, 2048)],
     "head 的 DST_ADDR % 32 != 0（片上占位槽不对齐；主口看不到）"),
]
for name, items, why in JOBS:
    jd = os.path.join(work, "fld", name)
    os.makedirs(jd, exist_ok=True)
    blob = DT.pack_table(items)
    assert len(blob) == (len(items) + 1) * 32, "%s: 表字节数 %d 不符" % (name, len(blob))
    words = [list(struct.unpack_from("<8I", blob, i * 32)) for i in range(len(items))]
    for i, w in enumerate(words):
        assert w == be_words(items[i]) == DT.reference_words(items[i]), "%s: 项 %d 字三方对账不符" % (name, i)
    pre = bytes(pat(i) for i in range(memsz))
    mem = bytearray(pre)
    mem[desc_addr:desc_addr + len(blob)] = blob
    open(jd + "/mem.hex", "w").write("".join("%02x\n" % b for b in mem))
    open(jd + "/pre.hex", "w").write("".join("%02x\n" % b for b in mem))
    open(jd + "/descD.args", "w").write(" ".join(str(x) for x in words[0]))
    # run_job 的 descE.args 是必需件：单条目作业里它是占位；2 条目作业里它是第 2 项（+E0..+E7）
    open(jd + "/descE.args", "w").write(" ".join(str(x) for x in words[-1]))
    if len(items) > 1:
        open(jd + "/descF.args", "w").write(" ".join(str(x) for x in words[0]))   # 占位（只喂装置的对账口）
    open(jd + "/why.txt", "w", encoding="utf-8").write("%s\n" % why)
    print("FLD_NEG %-14s items=%d bytes=%-3d 违反: %s" % (name, len(items), len(blob), why))
print("FLD_MEMGEN memsz=%d desc=%d A0=%d T1=%d MID=%d DST=%d WIN=%d" % (memsz, desc_addr, A0, T1, MID, DST, WIN))
PYEOF
) ; then
  echo "FATAL: 生成 C3.11b 字段规则负作业失败 ⇒ 闸门不可信"; exit 3
fi
for j in neg_alignsrc neg_oobdst neg_loop neg_inbytes neg_type neg_alignhead; do
  for f in mem.hex pre.hex descD.args descE.args why.txt; do
    [ -s "$work/fld/$j/$f" ] || { echo "FATAL: 负作业 $j 的激励文件 $f 缺失或为空"; exit 3; }
  done
done
echo "   C3.11b 负作业向量 OK（6 张故意非法的表，每张只违反一条规则）"

FLD_OK=""
for spec in "neg_alignsrc 1" "neg_oobdst 1" "neg_loop 1" "neg_inbytes 1" "neg_type 1" "neg_alignhead 2"; do
  set -- $spec; j="$1"; dc="$2"
  jd="$work/fld/$j"; log="$jd/$j.log"
  why="$(cat "$jd/why.txt")"
  echo "---- 8.$j) 字段规则负作业：$why ⇒ 响亮 err + 零设备搬运 ----"
  run_job "$work/sim.vvp" "$jd" "$j" "$dc" +EXPECT_ERR +SKIP_DESC_CHK; RC=$?
  if [ "$RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$log"; then
    echo "JUDGE-RED[$j]: 装置没按预期 err（vvp rc=$RC）"
    grep -E '^(RESULT|TB-ERROR|TB SCHED|IRQ_|UNIT_INDEX|DONE_SEEN|AW_BURSTS|MEM )' "$log" || true
    exit 2
  fi
  grep -E '^(DONE_SEEN|UNIT_INDEX_FINAL|IRQ_RISES|AW_BURSTS|MEM )' "$log" | sed 's/^/   /'
  DMEM="$(grep -m1 '^MEM rd=' "$log")"
  DAW="$(grep -m1 '^AW_BURSTS ' "$log")"
  DAR="$(grep -m1 '^AR_BURSTS ' "$log")"
  DUIDX="$(sed -n 's/^UNIT_INDEX_FINAL=\([0-9]*\)$/\1/p' "$log" | tail -1)"
  DIRQ="$(sed -n 's/^IRQ_RISES=\([0-9]*\)$/\1/p' "$log" | tail -1)"
  DONE="$(sed -n 's/^DONE_SEEN=\([0-9]*\).*$/\1/p' "$log" | tail -1)"
  ERR="$(sed -n 's/^DONE_SEEN=[0-9]* ERR_SEEN=\([0-9]*\).*$/\1/p' "$log" | tail -1)"
  case "$DMEM" in
    "MEM rd=64 wr=0 bursts=2 maxburst=4") : ;;
    *) echo "JUDGE-RED[$j]: 搬运不是「只有两笔 32 B 取表」：[$DMEM]"; exit 2 ;;
  esac
  if [ "$DAW" != "AW_BURSTS n128=0 total=0 B_OK=0" ]; then
    echo "JUDGE-RED[$j]: 发了 AW ⇒ 不是零设备搬运：[$DAW]"; exit 2
  fi
  if [ "${DONE:-x}" != "0" ] || [ "${ERR:-x}" != "1" ]; then
    echo "JUDGE-RED[$j]: 判定不符（DONE_SEEN=${DONE:-?} ERR_SEEN=${ERR:-?}）"; exit 2
  fi
  if [ "${DUIDX:-x}" != "0" ] || [ "${DIRQ:-x}" != "0" ]; then
    echo "JUDGE-RED[$j]: 竟然跑了单元/抬了中断（UNIT_INDEX_FINAL=${DUIDX:-?} IRQ_RISES=${DIRQ:-?}）"; exit 2
  fi
  FLD_OK="$FLD_OK $j"
  echo "   NEG_OK[$j]（$why）：$DAR / $DAW / $DMEM（= 哨兵探测 + 第 0 项，各一笔 32 B）、"
  echo "                   DONE_SEEN=0 ERR_SEEN=1、UNIT_INDEX_FINAL=0、IRQ_RISES=0 ⇒ 响亮 err + 零设备搬运"
done

# --------------------------------------------------------------------------------------------
# 8x) ★ "每条新判据都能变红"——**突变控制**（把该条判据从网表里摘掉 ⇒ 对应负作业必须不再绿）
#     ★ 为什么对齐这一条的控制用 `neg_alignhead`（而不是 `neg_alignsrc`）：`neg_alignsrc` 的
#       `SRC_ADDR` 是**被单元消费**的地址 ⇒ `DdrMaster` 的 CHK（同一拍、同样零搬运）也会拦它
#       ⇒ 摘掉本预检后该作业**照样 err**（观测等价，控制不可能变红）——这是**故意的纵深防御**，
#       见 RTL 文件头"与 DdrMaster CHK 的关系"。而 `neg_alignhead` 的那个地址是**片上占位槽**
#       （链真正写的是 tail 的 DST）⇒ 主口永远看不到它 ⇒ 摘掉预检后它**会真的跑起来**（变红）。
#       下面 8x-1) 把这两件事都摆出来（前者"摘掉也照样拦"、后者"摘掉当场变红"）。
# --------------------------------------------------------------------------------------------
echo "---- 8x) 突变控制：逐条摘掉本预检 ⇒ 对应负作业**必须不再绿**（判据有牙的原始红证据）----"
mut_netlist() {   # $1 = 规则名（align|window|loop|inbytes|type）$2 = 输出网表
  "$PY" - "$nl" "$2" "$1" <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
src = open(sys.argv[1], encoding="utf-8").read()
out, rule = sys.argv[2], sys.argv[3]
MUT = {
    "align":   ("  assign addrAlignOk = [^\n]*\n", "  assign addrAlignOk = 1'b1;\n",
                "SRC/DST 32 B 对齐（规则 (3) 的对齐半）"),
    "window":  ("  assign dstInWin = [^\n]*\n",    "  assign dstInWin = 1'b1;\n",
                "DST 落在 DDR 窗内（规则 (3) 的窗半）"),
    "loop":    ("  assign selfLoop = [^\n]*\n",    "  assign selfLoop = 1'b0;\n",
                "自环 SRC==DST（规则 (4)）"),
    "inbytes": ("  assign inBytesOk = [^\n]*\n",   "  assign inBytesOk = 1'b1;\n",
                "IN_BYTES %32==0 且 !=0（规则 (3) 的 IN_BYTES 半）"),
    "type":    ("  assign typeKnown = [^\n]*\n",   "  assign typeKnown = 1'b1;\n",
                "非法 TYPE（规则 (2) 的 TYPE 半）"),
}
pat, repl, desc = MUT[rule]
new, n = re.subn(pat, repl, src)
print("MUTGEN %s: hits=%d (期望 1) —— 摘掉「%s」" % (rule, n, desc))
if n != 1:
    sys.exit(2)
open(out, "w", encoding="utf-8").write(new)
PYEOF
}
run_ctl() {   # <rule> <job> <dc>  —— 编译突变件 + 跑对应负作业；把日志留在 <job>/ctl_<rule>.log
  local rule="$1" j="$2" dc="$3" jd="$work/fld/$2"
  if ! mut_netlist "$rule" "$work/LayerSched_mut_$rule.v" > "$work/mut_$rule.out" 2>&1; then
    echo "JUDGE-RED: 无法构造突变网表（$rule）⇒ 闸门不可信"; cat "$work/mut_$rule.out"; exit 2
  fi
  cat "$work/mut_$rule.out" | sed 's/^/   /'
  if cmp -s "$nl" "$work/LayerSched_mut_$rule.v"; then echo "JUDGE-RED: 突变网表（$rule）与原文相同"; exit 2; fi
  if ! "$IVERILOG" -g2012 -o "$work/mut_$rule.vvp" "$tb" "$memv" "$work/LayerSched_mut_$rule.v" > "$work/iv_mut_$rule.log" 2>&1; then
    echo "JUDGE-RED: 突变网表（$rule）编译失败"; sed -n '1,20p' "$work/iv_mut_$rule.log"; exit 2
  fi
  run_job "$work/mut_$rule.vvp" "$jd" "ctl_$rule" "$dc" +EXPECT_ERR +SKIP_DESC_CHK +TIMEOUT=100000
  local log="$jd/ctl_$rule.log"
  grep -E '^(RESULT|DONE_SEEN|UNIT_INDEX_FINAL|IRQ_RISES|AW_BURSTS|MEM )' "$log" | sed 's/^/   /' || true
  # 判据有牙的判据：突变件**不得**再给出"响亮 err + 零搬运"那个绿结论
  if grep -q '^RESULT: PASS' "$log" && \
     grep -q '^AW_BURSTS n128=0 total=0 B_OK=0' "$log" && \
     grep -q '^DONE_SEEN=0 ERR_SEEN=1' "$log"; then
    echo "JUDGE-RED: 摘掉「$rule」判据后 $j 仍然绿 ⇒ 这条判据没牙（闸门不可信）"; exit 2
  fi
}
echo "---- 8x-1) 突变控制[align]：摘掉对齐判据 ⇒ neg_alignhead（占位槽不对齐）**变红**；neg_alignsrc 仍被 DdrMaster 拦下 ----"
run_ctl align neg_alignhead 2
echo "   NEG_OK[ctl align]（原始红证据）：摘掉「addrAlignOk」⇒ head 的占位槽 DST 不再被拦 ⇒ 上面那条不再是"
echo "                    「ERR_SEEN=1 + AW=0 + MEM rd=64」的绿结论（链真的跑起来了）⇒ 这条判据有牙"
run_job "$work/mut_align.vvp" "$work/fld/neg_alignsrc" ctl_align_src 1 +EXPECT_ERR +SKIP_DESC_CHK
grep -E '^(RESULT|DONE_SEEN|UNIT_INDEX_FINAL|AW_BURSTS|MEM )' "$work/fld/neg_alignsrc/ctl_align_src.log" | sed 's/^/   /' || true
if ! grep -q '^RESULT: PASS' "$work/fld/neg_alignsrc/ctl_align_src.log"; then
  echo "JUDGE-RED: 摘掉本预检后 neg_alignsrc 竟然不再 err ⇒ 与「DdrMaster 也会拦」的论证不符（要重看）"; exit 2
fi
echo "   ★ 冗余注记（诚实）：摘掉本预检后 neg_alignsrc（SRC 不对齐）**照样 err**（仍是 MEM rd=64 / AW=0）"
echo "                    —— 因为「DdrMaster」的 CHK 也查同一件事 ⇒ 对**被消费**的地址，本判据是**纵深防御**；"
echo "                    而窗越界 / 自环 / 旁路项 IN_BYTES / 非法 TYPE / 占位槽对齐这五档**下游都看不到**。"
echo "---- 8x-2) 突变控制[window]：摘掉 DDR 窗判据 ⇒ neg_oobdst（DST=2^28，主口截成 0）**变红** ----"
run_ctl window neg_oobdst 1
echo "   NEG_OK[ctl window]（原始红证据）：摘掉「dstInWin」⇒ 越窗的 DST 被 28 bit 主口**静默截断**成 0、"
echo "                    这一项照跑（有 AW 搬运、帧照样走完）⇒ 「越窗必须响亮 err」这条判据有牙"
echo "---- 8x-3) 突变控制[loop]：摘掉自环判据 ⇒ neg_loop（SRC==DST）**变红** ----"
run_ctl loop neg_loop 1
echo "   NEG_OK[ctl loop]（原始红证据）：摘掉「selfLoop」⇒ 就地复制的卷积照跑（读自己写自己）⇒ 有牙"
echo "---- 8x-4) 突变控制[inbytes]：摘掉 IN_BYTES 判据 ⇒ neg_inbytes（旁路项 IN_BYTES=0）**变红** ----"
run_ctl inbytes neg_inbytes 1
echo "   NEG_OK[ctl inbytes]（原始红证据）：摘掉「inBytesOk」⇒ 旁路项（BypassExec 不读 IN_BYTES）照跑 ⇒ 有牙"
echo "---- 8x-5) 突变控制[type]：摘掉非法 TYPE 判据 ⇒ neg_type（0x77 掉进旁路分派，帧走不完）**变红** ----"
run_ctl type neg_type 1
echo "   NEG_OK[ctl type]（原始红证据）：摘掉「typeKnown」⇒ 0x77 掉进旁路分派那一支并被派给「BypassExec」，"
echo "                    而它的四个 is*（pool/resize/add/sigmoid）全不成立 ⇒ 没有任何单元吃这批输入"
echo "                    ⇒ 帧永远走不完（上面那条「RESULT: FAIL timeout」，且「MEM rd=2112」证明 RD 流真的跑了）"
echo "                    ⇒ 「非法 TYPE 必须响亮 err + 零搬运」这条判据有牙"

# ---------------- 收口 ----------------
echo "=========================================================================="
echo "判据1 数值     = OK（A conv-only: A1/A2 == 黄金；B 旁路链 mp/sig/add/rz: T1/T2/T3 == 黄金）"
echo "判据2 三区域   = OK（SRC 未改、诱饵区未改、末张量之外含近邻未动）"
echo "判据3 旁路逐点 = OK（mp/sig/add/rz 四段的 SEG_MISMATCH=0：硬件输入 -> 算子参考 -> 硬件 T3）"
echo "判据4 IRQ 纪律 = OK（IRQ_RISES=1 IRQ_INTRA_FRAME=0 IRQ_AT_FRAME_END=1 IRQ_HELD_AFTER_50=1；末单元含旁路算子）"
echo "负对照 A       = OK（网表突变 ⇒ conv 作业 IRQ_INTRA_FRAME=${MUT_I:-?}>0；旁路链 IRQ_INTRA_FRAME=${MUT_I2:-?}>0）"
echo "负对照 B       = OK（descCount 少 1 ⇒ 响亮 err + 零单元搬运：$BMEM2）"
echo "比较器         = OK（扰动 1 个黄金字节 ⇒ A2_MISMATCH=1 / T3_MISMATCH=1）"
echo "结构           = OK（check_dangling.py：gen/LayerSched.v 零悬空）"
echo "新负对照       = OK（middle 无前驱 / head 无 tail ⇒ 响亮 err + 零设备搬运：$NMID_MEM / $NHED_MEM）"
echo "正对照         = OK（合法表**不**报 err：A 作业 3 项 + B 作业 4 项 ERR_SEEN=0；且 A/B 的表**故意复用地址**"
echo "                 （项 i 的 DST == 项 i+1 的 SRC、head 的 DST == tail 的 SRC）仍不被自环判据误报，"
echo "                  这就是自环判据「只查**同一条目**自己的 SRC==DST」的活证据）"
echo "C3.11b 字段规则 = OK（6 道负作业：[${FLD_OK# }] —— 每道 ERR_SEEN=1 + AW_BURSTS total=0 + MEM rd=64（表探测 2 笔）"
echo "                 + UNIT_INDEX_FINAL=0 + IRQ_RISES=0 = 响亮 err + 零设备搬运；判据全在**取表相位**）"
echo "C3.11b 突变控制 = OK（逐条摘掉预检 ⇒ 对应负作业**不再绿**：align/window/loop/inbytes/type 五条都有原始红证据；"
echo "                 另注：SRC 对齐这一档与 DdrMaster.CHK **冗余**（摘掉本预检后仍被它拦下，已如实打印））"
echo "链塌缩         = OK（head 0b00 + tail 0b11 两个相邻条目 ⇒ **一次 go**（chainLen=2）；中间张量零 DDR）"
echo "非退化         = OK（各档黄金非常数/非全 0；maxpool 黄金 != 四个整块平移；add SAT>0；防混叠三区预载与黄金 >=1900 不同）"
echo "RESULT: PASS"
exit 0
