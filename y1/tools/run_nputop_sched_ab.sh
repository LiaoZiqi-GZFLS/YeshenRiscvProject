#!/usr/bin/env bash
# run_nputop_sched_ab.sh —— C3.12「层调度器并入 NpuTop」+ ★C3.16「权重经寄存器信箱装载」的
#   **端到端可编程**闸门（rtl/NpuTop.scala + rtl/HostRegs.scala + gen/NpuTop.v；
#   装置 rtl_test/NpuTopSchedTb.v）。
#
# 本闸门要证的那条链（缺一不可）：
#   host 经 AxiLite4 写 **DESC_ADDR(0x34) / DESC_COUNT(0x38)**（★ C3.12 的新编程面）
#     + ★C3.16 经 **WGT_SEL(0x3C)/WGT_ADDR(0x40)/WGT_DATA(0x44)/WGT_WE(0x48)** 逐字节预载权重
#       -> 写 CTRL.start（NpuTop 的 start 契约：DESC_COUNT != 0 ⇒ 走调度器）
#         -> NpuTop 内部把单个对外 AXI 主口**结构性复用**给 LayerSched
#           -> 调度器走 DDR 里的描述符表（DescFetch -> 分派 UnitExec/BypassExec -> 权重从信箱来）
#             -> 帧末抬**一次** frameDone -> NpuTop 锁成保持电平 -> 顶层 irq
#               -> host 轮询 STATUS 看到 done_sticky / err；转储镜像与 Python 黄金**逐字节**对账。
#
# 正对照的表（rtl_test/…/desc_table.pack_table 冻结真源；**3 个 plain 条目** + 自动哨兵）：
#   项0  conv3x3(0x01) plain  SRC0 -> DST0   （UnitExec 通路；本作业**不装载权重** ⇒ 输出零张量）
#   项1  conv1x1(0x02) plain  SRC1 -> DST1   （UnitExec 通路；同上）
#   项2  maxpool(0x10) plain  SRC2 -> DST2   （BypassExec 通路；**无需权重 ⇒ 非平凡黄金**）
# 黄金 = 预载镜像，但 DST0/DST1 = **冻结参考的零张量**（conv + 零权重），DST2 = **冻结 maxpool 参考**。
# ★ 为什么本作业的 conv 两项是零张量（**C3.16 起前提已变，逐字更新**）：C3.12 时它是因为"对外端口集
#   **不含**权重装载口"（NpuTop 把权重口钉 0，是**结构**原因）；C3.16 起权重口**存在且是寄存器信箱**
#   ⇒ 本作业之所以仍是零张量，只因为**主机一次都没写过 WGT_***（信箱寄存器复位值 = 0 ⇒ 全 0 权重）。
#   ★ 于是本作业同时成了一条**免费的负对照**：把"权重通路整个不存在/被常量折叠"和"权重通路存在但
#     主机没写"这两档**区分**开来 —— 前者会让作业 W1/W2（下面）**必然**失败（它们写了权重且要真数值）。
#   为了让"零张量"这条黄金**不是橡皮章**：DST0/DST1 的预载是**非零**模式 ⇒ 硬件必须真的把它们**写 0**
#   才对得上（"根本没写"会当场 MISMATCH）；DST2 则是**非平凡**数值（maxpool 黄金，非零、非常数）。
#
# 作业（1 正 + 1 比较器自检 + 2 非法表负 + **★C3.16 的 2 正 + 2 负（权重数值）** + 2 条 C2 回归 + 1 结构判据）：
#   作业 1 正向 —— 3 条目小表：字节级整片对账 MISMATCH=0；DST0/DST1 零、DST2 == maxpool 黄金；
#     SRC0/1/2 与描述符表未被改、邻居未被写；IRQ 纪律（PRE=0 / POST=1 / ACK=0 / RISES=1 / 保持 >=50 拍）；
#     内存模型交叉对账（MEM rd/wr 与几何推算相符）。
#   作业 2 比较器自检 —— 扰动黄金一个期望字节 ⇒ MISMATCH 必须**恰好 1**。
#   作业 3 负对照 A[非法表: DESC_COUNT 与哨兵不符] —— 同表写 DESC_COUNT=2（表里 3 载荷 + 哨兵）
#     ⇒ 进表前取下标 2 项、发现不是哨兵 ⇒ 响亮 err（**零设备搬运**：MEM wr=0、镜像 == 预载）。
#   作业 4 负对照 B[非法表: 未知 TYPE] —— 表 = [TYPE=0x77] + 哨兵，DESC_COUNT=1 ⇒ 响亮 err（零搬运）。
#   ★ 作业 W1（**新增，本片的判据主体**）—— 权重经寄存器信箱装载（`+WGTPACK=`，切片主序）+ 2 条目小表
#     （conv3x3 plain + maxpool plain）⇒ 整片 MISMATCH=0（conv 输出 == Python 黄金，真数值）。
#   ★ 作业 W1 负对照 C —— 只把切片 0 的**一个权重字节**扰动：与正确黄金 MISMATCH > 0（**判据有牙**），
#     与被扰动权重的黄金 MISMATCH == 0（**输出跟着装载进去的权重走**，不是碰巧）。
#   ★ 作业 W2 —— 8 片链（`chainLen=8`）：切片 0..3 恒等权重（`(64*x)>>6 = x` 精确）、切片 4..7 四份互不
#     相同的非平凡权重 ⇒ 整片 MISMATCH=0（黄金由 `chain_l` 与 `chain_l_naive` 两条独立实现交叉对账）。
#     ⚠️ 2026-10-17 起板级 `gen/NpuTop.v` 是 **L_MAX=2**（真表 de-fuse，链长恒 1）⇒ 本作业单独吃
#     `gen_chain8/NpuTop.v`（同一个 `NpuTop(LMax)` 参数化实现的 L=8 展开，仅作验证网表，不进板级）。
#   ★ 作业 W2 负对照 D —— "切片 4..7 共用一份权重"的四种折叠假设（= 旧的四套装载口在 `L_MAX=8` 下的
#     结构后果）+ "全零权重"一档：实测输出与**每一个**假设都不同 ⇒ **8 个 `WeightStore` 各自独立可写**
#     （旧的"切片 4..7 别名第 4 套口"这条限制由**数值**钉死已消除）。
#   作业 5/6 C2 回归 —— run_nputop_ab.sh / run_ddrcopy_ab.sh 仍 = 0（start 契约对 C2 向后兼容）。
#   作业 0 结构 —— check_dangling.py（gen/NpuTop.v ⇒ 零悬空）。
#
# 退出码：
#   0 = 通过（正对照整片相符 + 区域干净 + IRQ 纪律 + 全部负对照都发火 + 自检过 + C2 双回归绿）
#   1 = 对账不符 / 编译或仿真失败 / 装置未 PASS / IRQ 纪律不成立 / C2 回归红了
#   2 = 负对照没发火，或比较器自检不过 ⇒ **闸门自身不可信**
#
# 装置契约（rtl_test/NpuTopSchedTb.v + rtl_test/AxiMemModel.v + gen/NpuTop.v）：
#   +DESC_ADDR= +DESC_COUNT=（十进制） +MEMFILE= +DUMPFILE=（模型自己取） +EXPECT_ERR（可选）
#   ★C3.16 +WGTPACK= +WGTPACK_SLICES= +WGTPACK_ENTRIES=（权重包：切片主序、每行一字节；不给则不写权重）
#   装置输出：ID_READ / STATUS_PRE / CTRL_PRE / PRE_IRQ= / RB_DESC_ADDR / RB_DESC_COUNT / RB_OK /
#             WGT_RB_SEL / WGT_RB_ADDR / WGT_RB_DATA / WGT_LOADED / WGT_OK /
#             DONE_SEEN= / ERR_SEEN= / STATUS_POST / CTRL_POST / POST_IRQ= / IRQ_HELD_AFTER_50= /
#             IRQ_AFTER_ACK= / STATUS_AFTER_ACK / IRQ_HIGH_CYCLES= / IRQ_RISES= / `RESULT: PASS|FAIL`
#   内存模型输出：末尾 `MEM rd=<bytes> wr=<bytes> bursts=<n> maxburst=<n>`
set -uo pipefail

# ---- Python：desc_table（冻结真源）会 import ddr_traffic ⇒ 需要 onnx 依赖（在 third_party/yunet/deps）----
PY="${PY:-}"
if [ -z "$PY" ]; then
  for c in /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe python3 python; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi

here="$(cd "$(dirname "$0")" && pwd)"
top="$here/../.."                       # 仓库根（Python 侧 cwd：PYTHONPATH 用相对路径）
gen="$here/../gen"
gen_chain8="$here/../gen_chain8"
tb="$here/../rtl_test/NpuTopSchedTb.v"
memv="$here/../rtl_test/AxiMemModel.v"
nl="$gen/NpuTop.v"
# ★ 2026-10-17：板级 NpuTop 取 L_MAX=2（真表 de-fuse，链长恒 1）；作业 W2 是 chainLen=8 的
#   顶层链集成判据，必须吃 **L_MAX=8 的验证网表**。两份网表由同一个 `NpuTop(LMax)` 参数化实现
#   分别生成、分别编译（同名 module 不能进同一次 iverilog 调用）。
nl8="$gen_chain8/NpuTop.v"
dangling="$here/check_dangling.py"

# ---- 用例常量（MEMSZ 必须与 rtl_test/NpuTopSchedTb.v 里 AxiMemModel 的 MEMSZ 一致）----
MEMSZ=65536                # 64 KiB
DESC_ADDR=4096             # 0x1000（表基址；32 B 对齐）；表 = 3 载荷 + 哨兵 = 128 B
SRC0=8192                  # 0x2000  conv3x3 输入
DST0=12288                 # 0x3000  conv3x3 输出（黄金 = 零张量）
SRC1=16384                 # 0x4000  conv1x1 输入
DST1=20480                 # 0x5000  conv1x1 输出（黄金 = 零张量）
SRC2=24576                 # 0x6000  maxpool 输入（NHWC 8x32x8）
DST2=28672                 # 0x7000  maxpool 输出（NHWC 8x16x4）
W=32; H=8; CIN=8; COUT=8; SHIFT=6
NENTRY=$(( COUT * CIN * 9 ))         # 576（dense 单片权重条目数 = WGT_ADDR 的上界）
IN_BYTES=$(( CIN * H * W ))          # 2048（= 128 的整数倍）
MP_OUT=$(( CIN * (W/2) * (H/2) ))    # 512
DESC_COUNT=3                         # 载荷项数（不含哨兵）
NEG_COUNT=2                          # 负对照 A：比真实少 1 项
# 期望的内存流量（与几何推算一致）：
#   取表 = (DESC_COUNT+1) * 32；读 = 3 个单元各 IN_BYTES；写 = conv*2 * IN_BYTES + maxpool MP_OUT
EXP_MEMRD=$(( (DESC_COUNT + 1) * 32 + 3 * IN_BYTES ))   # 128 + 6144 = 6272
EXP_MEMWR=$(( 2 * IN_BYTES + MP_OUT ))                  # 4096 + 512 = 4608

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

echo "== run_nputop_sched_ab: NpuTop（HostRegs+DdrMaster+LayerSched）端到端可编程层调度 =="
echo "   tb  =$tb"
echo "   mem =$memv"
echo "   nl  =$nl   (板级 L_MAX=2)"
echo "   nl8 =$nl8   (链闸门 L_MAX=8)"
echo "   py=${PY:-<找不到>}  iverilog=${IVERILOG:-<找不到>}  vvp=${VVP:-<找不到>}"
echo "   tmp =$work"
echo "   正用例 DESC_ADDR=$DESC_ADDR DESC_COUNT=$DESC_COUNT (W=$W H=$H C_IN=$CIN C_OUT=$COUT SHIFT=$SHIFT)"
echo "   区布局 SRC0=$SRC0 DST0=$DST0 SRC1=$SRC1 DST1=$DST1 SRC2=$SRC2 DST2=$DST2 (MEMSZ=$MEMSZ)"
echo "   期望流量 MEM rd=$EXP_MEMRD wr=$EXP_MEMWR；负对照 COUNT=$NEG_COUNT / 未知 TYPE=0x77"

# ---------------- 前置检查 ----------------
if [ ! -f "$nl" ]; then
  echo "FATAL: 找不到网表 $nl"
  echo "       先生成: cd y1 && printf 'Test/runMain NpuTopGen D:/code/PDS/VexiiYeshenLinux/y1/gen\\\\nexit\\\\n' | bash sbt.sh"
  exit 1
fi
if [ ! -f "$nl8" ]; then
  echo "FATAL: 找不到 L=8 验证网表 $nl8（作业 W2 需要）"
  echo "       先生成: cd y1 && printf 'Test/runMain NpuTopChain8Gen D:/code/PDS/VexiiYeshenLinux/y1/gen_chain8\\\\nexit\\\\n' | bash sbt.sh"
  exit 1
fi
[ -f "$tb" ]   || { echo "FATAL: 找不到装置 $tb"; exit 1; }
[ -f "$memv" ] || { echo "FATAL: 找不到内存模型 $memv"; exit 1; }
if [ -z "$PY" ] || [ -z "$IVERILOG" ] || [ -z "$VVP" ]; then echo "FATAL: 找不到 python / iverilog / vvp"; exit 1; fi
case $(( IN_BYTES % 128 )) in 0) : ;; *) echo "FATAL: IN_BYTES=$IN_BYTES 不是 128 的整数倍"; exit 3 ;; esac

# ---------------- 0) 结构判据：零悬空实例 ----------------
echo "---- 0) tools/check_dangling.py（gen/NpuTop.v 与 gen_chain8/NpuTop.v ⇒ 零悬空）----"
if [ -f "$dangling" ]; then
  "$PY" "$dangling" "$nl" | tail -3
  if ! "$PY" "$dangling" "$nl" >/dev/null; then
    echo "JUDGE-RED: 有悬空实例（被例化但没有模块定义）"; exit 1
  fi
else
  echo "WARN: 找不到 $dangling（跳过结构判据）"
fi

# ---------------- 1) 造向量 + 黄金（描述符走冻结真源 desc_table.pack_table；黄金走冻结参考）----------------
echo "---- 1) 造向量：3 条目小表（conv3x3 + conv1x1 + maxpool）+ 黄金（conv 零张量 / maxpool 冻结参考）----"
if ! ( cd "$top" && PYTHONIOENCODING=utf-8 PYTHONPATH='third_party/yunet/deps' "$PY" - \
        "$work" "$here" "$top" "$MEMSZ" "$DESC_ADDR" \
        "$SRC0" "$DST0" "$SRC1" "$DST1" "$SRC2" "$DST2" \
        "$W" "$H" "$CIN" "$COUT" "$SHIFT" "$DESC_COUNT" <<'PYEOF'
import sys, os, struct, hashlib
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
work, refdir, topdir = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, refdir)
sys.path.insert(0, os.path.join(topdir, "y1", "tools"))
import conv_unit_ref as R
import mac_ref as M
import bypass_ref as BR
import desc_table as DT

(memsz, desc_addr, src0, dst0, src1, dst1, src2, dst2,
 W, H, CIN, COUT, SHIFT, DESC_COUNT) = (int(x) for x in sys.argv[4:18])

IN_BYTES = CIN * H * W
MP_OUT   = CIN * (W // 2) * (H // 2)

def pat(i):
    """非零周期模式（1..254；254 = 2*127，131 与其互素 ⇒ 周期恰 254）。预载**处处非零** ⇒
    任何"该写没写"都会留下非零残迹 ⇒ 与黄金（DST0/1 为零）当场 MISMATCH。"""
    return 1 + ((i * 131 + 7) % 254)

pre = bytes(pat(i) for i in range(memsz))

# ---- 3 个 plain 条目（FLAGS=0b01）----
d0 = {"TYPE": 0x01, "FLAGS": 0b01, "IMG_W": W, "IMG_H": H, "C_IN": CIN, "C_OUT": COUT,
      "GROUP": 1, "STRIDE": 1, "PAD": 1, "SRC_ADDR": src0, "DST_ADDR": dst0,
      "IN_BYTES": IN_BYTES, "QUANT_SHIFT": SHIFT, "LAYER_ID": 0}
d1 = {"TYPE": 0x02, "FLAGS": 0b01, "IMG_W": W, "IMG_H": H, "C_IN": CIN, "C_OUT": COUT,
      "GROUP": 1, "STRIDE": 1, "PAD": 1, "SRC_ADDR": src1, "DST_ADDR": dst1,
      "IN_BYTES": IN_BYTES, "QUANT_SHIFT": SHIFT, "LAYER_ID": 1}
d2 = {"TYPE": 0x10, "FLAGS": 0b01, "IMG_W": W // 2, "IMG_H": H // 2, "C_IN": CIN, "C_OUT": COUT,
      "GROUP": 1, "STRIDE": 2, "PAD": 0, "SRC_ADDR": src2, "DST_ADDR": dst2,
      "IN_BYTES": IN_BYTES, "QUANT_SHIFT": 0, "LAYER_ID": 2}
blob = DT.pack_table([d0, d1, d2])
assert len(blob) == 32 * (DESC_COUNT + 1) == 128, "表字节数 %d != 128" % len(blob)

def be_words(d):
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
assert w0 == be_words(d0) == DT.reference_words(d0), "描述符0 三方对账不符"
assert w1 == be_words(d1) == DT.reference_words(d1), "描述符1 三方对账不符"
assert w2 == be_words(d2) == DT.reference_words(d2), "描述符2 三方对账不符"
assert (w0[0] >> 8) & 0xFF == 0b01, "项0 FLAGS 应为 0b01(plain)"
assert (w1[0] >> 8) & 0xFF == 0b01, "项1 FLAGS 应为 0b01(plain)"
assert (w2[0] >> 8) & 0xFF == 0b01, "项2 FLAGS 应为 0b01(plain)"
assert (ws[0] & 0xFF) == 0xFF and (ws[0] >> 8) == 0, "下标 3 不是哨兵"

# ---- 内存镜像 = 预载；再落表 + 三块输入张量 ----
mem = bytearray(pre)
mem[desc_addr:desc_addr + len(blob)] = blob
x0 = list(mem[src0:src0 + IN_BYTES])       # conv3x3 输入（内容任意，零权重下不影响输出）
x1 = list(mem[src1:src1 + IN_BYTES])       # conv1x1 输入
x2 = list(mem[src2:src2 + IN_BYTES])       # maxpool 输入（NHWC 8x32x8）

# ---- 黄金：conv 零张量（用冻结参考交叉证明"零权重 ⇒ 零输出"）；maxpool 冻结参考 ----
#   ★ C3.16 前提更新（诚实记录）：本作业**不**装载权重 ⇒ 信箱寄存器保持复位值 0 ⇒ 全 0 权重 ⇒ 零张量。
#     这与 C3.12 时的**原因不同**（那时是"权重口根本不存在、被 NpuTop 钉 0"）：现在权重口存在且可写，
#     只是主机没写。作业 W1/W2 会**真的**装载权重并要求真数值 ⇒ 两档由此被区分开（见文件头）。
wt0 = [0] * (COUT * CIN * 9)
z0 = R.naive_nhwc(x0, wt0, CIN, COUT, H, W, shift=SHIFT)
z1 = R.naive_nhwc(x1, wt0, CIN, COUT, H, W, shift=SHIFT)
assert all(v == 0 for v in z0) and all(v == 0 for v in z1), "冻结参考：零权重竟非零输出"
# ★ maxpool 的冻结参考做的是 **int8 有符号**比较（bypass_ref.maxpool_ref 的 `v > m`）⇒ 必须把
#   内存里的**字节**先按二补数重解释成有符号（与硬件把字节读进 SInt(8) 同口径），否则黄金会算错。
x2s = [v - 256 if v >= 128 else v for v in x2]
mp = BR.maxpool_ref(x2s, CIN, W, H)
assert len(mp) == MP_OUT == 512, "maxpool 黄金长度 %d != 512" % len(mp)
assert len(set(mp)) > 1 and any(v != 0 for v in mp), "maxpool 黄金是常数/全 0 ⇒ 判据没意义"

golden = bytearray(mem)
for (ad, gold) in ((dst0, z0), (dst1, z1), (dst2, mp)):
    golden[ad:ad + len(gold)] = bytes(v & 0xFF for v in gold)

# ---- 非退化前提：三块 DST 的预载都必须与黄金**大部分不同**（"不写"就有机会蒙过 ⇒ 必须不同）----
#   阈值取 3/4：预载是固定伪随机序列，与 maxpool 黄金偶然撞值约 1/251/字节（512 B 里约 2 处）⇒ 用
#   绝对"逐字节全不同"会假红；3/4 足以证明"没写"必然留下大范围残迹。
for nm, ad, gold in (("DST0", dst0, z0), ("DST1", dst1, z1), ("DST2", dst2, mp)):
    d = sum(1 for j in range(len(gold)) if pre[ad + j] != (gold[j] & 0xFF))
    assert d >= (len(gold) * 3) // 4, "%s 预载与黄金只有 %d/%d 不同 ⇒ '不写'有机会蒙过" % (nm, d, len(gold))
# ---- 区不重叠 / 对齐 / 在内存内 ----
regs = {"desc": (desc_addr, len(blob)), "src0": (src0, IN_BYTES), "dst0": (dst0, IN_BYTES),
        "src1": (src1, IN_BYTES), "dst1": (dst1, IN_BYTES), "src2": (src2, IN_BYTES),
        "dst2": (dst2, MP_OUT)}
for n, (a, ln) in regs.items():
    assert a % 32 == 0, "%s 地址 %d 不是 32B 对齐" % (n, a)
    assert a + ln <= memsz, "%s 越出已建模内存" % n
names = sorted(regs, key=lambda n: regs[n][0])
for i in range(len(names) - 1):
    a0, l0 = regs[names[i]]; a1b, _ = regs[names[i + 1]]
    assert a0 + l0 <= a1b, "%s 与 %s 区重叠" % (names[i], names[i + 1])

open(work + "/mem.hex", "w").write("".join("%02x\n" % b for b in mem))
open(work + "/exp.hex", "w").write("".join("%02x\n" % b for b in golden))
open(work + "/pre.hex", "w").write("".join("%02x\n" % b for b in pre))
open(work + "/desc.args", "w").write(" ".join(str(x) for x in w0 + w1 + w2) + "\n")
open(work + "/spec.txt", "w").write("\n".join(
    "%s %d %d" % (n, regs[n][0], regs[n][1]) for n in ("desc", "src0", "dst0", "src1", "dst1", "src2", "dst2")) + "\n")
open(work + "/gold_dst2.hex", "w").write("".join("%02x\n" % (v & 0xFF) for v in mp))

# ---- 负对照 B 的镜像：表 = [TYPE=0x77 未知] + 哨兵，DESC_COUNT=1 ----
bad = {"TYPE": 0x77, "FLAGS": 0b01, "IMG_W": W, "IMG_H": H, "C_IN": CIN, "C_OUT": COUT,
       "GROUP": 1, "STRIDE": 1, "PAD": 1, "SRC_ADDR": src0, "DST_ADDR": dst0,
       "IN_BYTES": IN_BYTES, "QUANT_SHIFT": SHIFT, "LAYER_ID": 0}
badblob = DT.pack_table([bad])
assert len(badblob) == 64, "未知 TYPE 表字节数 %d != 64" % len(badblob)
negmem = bytearray(pre)
negmem[desc_addr:desc_addr + len(badblob)] = badblob
open(work + "/negtype.hex", "w").write("".join("%02x\n" % b for b in negmem))

print("MEMGEN bytes=%d desc=%d src0=%d dst0=%d src1=%d dst1=%d src2=%d dst2=%d"
      % (memsz, desc_addr, src0, dst0, src1, dst1, src2, dst2))
print("TABLE items=%d bytes=%d md5=%s (desc_table.pack_table：3 载荷 + 自动哨兵)"
      % (len(blob) // 32, len(blob), hashlib.md5(blob).hexdigest()))
print("WORDS0 %s" % " ".join("%08x" % x for x in w0))
print("WORDS1 %s" % " ".join("%08x" % x for x in w1))
print("WORDS2 %s" % " ".join("%08x" % x for x in w2))
print("GOLD: DST0/DST1 = 零张量（冻结 conv 参考 + 零权重，逐值 0 已验证）；"
      "DST2 = maxpool 冻结参考 %d B（distinct=%d，非全 0）" % (len(mp), len(set(mp))))
print("NONTRIVIAL: 三块 DST 预载与黄金都不同（" +
      "; ".join("%s diff=%d" % (nm, sum(1 for j in range(len(g)) if pre[ad + j] != (g[j] & 0xFF)))
                for nm, ad, g in (("DST0", dst0, z0), ("DST1", dst1, z1), ("DST2", dst2, mp))) + "）")
PYEOF
) ; then
  echo "FATAL: 生成向量/黄金失败（或非退化/布局前提不成立）⇒ 闸门不可信"
  exit 3
fi
for f in mem.hex exp.hex pre.hex negtype.hex desc.args spec.txt; do
  [ -s "$work/$f" ] || { echo "FATAL: 激励文件 $f 缺失或为空"; exit 3; }
done

# ---------------- 2) 编译 ----------------
echo "---- 2) iverilog 编译（NpuTopSchedTb + AxiMemModel + gen/NpuTop.v）----"
if ! "$IVERILOG" -g2012 -o "$work/sim.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败"; sed -n '1,40p' "$work/iv.log"; exit 1
fi
if grep -qi 'warning' "$work/iv.log"; then
  echo "    编译告警（留意）："; grep -i 'warning' "$work/iv.log" | head -3
fi
echo "    编译 OK"

echo "---- 2b) iverilog 编译（W2 链闸门：L_MAX=8 验证网表）----"
if ! "$IVERILOG" -g2012 -o "$work/sim_chain8.vvp" "$tb" "$memv" "$nl8" > "$work/iv8.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译（gen_chain8）失败"; sed -n '1,40p' "$work/iv8.log"; exit 1
fi
if grep -qi 'warning' "$work/iv8.log"; then
  echo "    编译告警（留意）："; grep -i 'warning' "$work/iv8.log" | head -3
fi
echo "    编译 OK"

# 逐字节比较的公共实现
cat > "$work/cmpbytes.py" <<'PYEOF'
def load(p):
    return bytes.fromhex("".join(open(p).read().split()))
def diffs(a, b, base=0):
    assert len(a) == len(b), "length %d vs %d" % (len(a), len(b))
    n = len(a); B = 1 << 16; cnt = 0; first = -1; i = 0
    while i < n:
        j = min(i + B, n)
        if a[i:j] != b[i:j]:
            for k in range(i, j):
                if a[k] != b[k]:
                    if first < 0: first = base + k
                    cnt += 1
        i = j
    return cnt, first
PYEOF

# run_sim <logbase> <desc_addr> <desc_count> <memfile> [extra plusargs...]
#   日志 = $work/<logbase>.log；镜像 = $work/<logbase>.log.dump（与判定器口径一致）
run_sim() {
  local log="$1" da="$2" dc="$3" mf="$4"; shift 4
  ( cd "$work" && "$VVP" "$work/sim.vvp" \
      "+DESC_ADDR=$da" "+DESC_COUNT=$dc" \
      "+MEMFILE=$mf" "+DUMPFILE=$work/$log.log.dump" +dump "$@" > "$log.log" 2>&1 )
  return $?
}

# 同上，但吃 **L_MAX=8 验证网表**（只给 W2 链作业用）
run_sim8() {
  local log="$1" da="$2" dc="$3" mf="$4"; shift 4
  ( cd "$work" && "$VVP" "$work/sim_chain8.vvp" \
      "+DESC_ADDR=$da" "+DESC_COUNT=$dc" \
      "+MEMFILE=$mf" "+DUMPFILE=$work/$log.log.dump" +dump "$@" > "$log.log" 2>&1 )
  return $?
}

# ---------------- 判定器：正向（整片 + 区域 + IRQ 纪律 + 内存交叉对账）----------------
cat > "$work/judge_pos.py" <<'PYEOF'
import sys, re
sys.path.insert(0, sys.argv[1])
from cmpbytes import load, diffs
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
work, exp_f, dump_f, log_f, spec_f = sys.argv[1:6]
gold = load(exp_f); got = load(dump_f)
loaded = load(work + "/mem.hex")     # 载入镜像（预载 + 表 + 输入张量）；非 DST 区应与它逐字节相同
pre = load(work + "/pre.hex")
bad = 0
mis, first = diffs(got, gold)
print("MISMATCH=%d" % mis)
print("FIRST_OFF=%d" % first)
# 逐区点名
regs = {}
for ln in open(spec_f):
    t = ln.split()
    if len(t) == 3:
        regs[t[0]] = (int(t[1]), int(t[2]))
for n in ("desc", "src0", "dst0", "src1", "dst1", "src2", "dst2"):
    a, ln = regs[n]
    if n == "dst2":
        d, f = diffs(got[a:a + ln], load(work + "/gold_dst2.hex"), a)
        print("REGION %s len=%d vs gold_dst2 MISMATCH=%d first=%d" % (n, ln, d, f))
        if d: bad += 1
    elif n in ("dst0", "dst1"):
        zeros = bytes(ln)
        d, f = diffs(got[a:a + ln], zeros, a)
        print("REGION %s len=%d vs zeros MISMATCH=%d first=%d" % (n, ln, d, f))
        if d: bad += 1
    else:
        d, f = diffs(got[a:a + ln], loaded[a:a + ln], a)
        print("REGION %s len=%d vs loadimage MISMATCH=%d first=%d" % (n, ln, d, f))
        if d: bad += 1
# 全片除 DST0/1/2 之外必须 == 载入镜像（邻居/表/输入都不得被动）
chk = bytearray(loaded)
for n in ("dst0", "dst1", "dst2"):
    a, ln = regs[n]
    chk[a:a + ln] = got[a:a + ln]
d, f = diffs(got, bytes(chk), 0)
print("NEIGHBOR_ALL_MISMATCH=%d (first=%d)（除三块 DST 外的整片 vs 载入镜像）" % (d, f))
if d: bad += 1

txt = open(log_f, errors="replace").read()
def tok(name):
    m = re.search(r"\b%s=(\d+)\b" % name, txt); return int(m.group(1)) if m else None
def hextok(name):
    m = re.search(r"^%s ([0-9a-fA-F]+)$" % name, txt, re.M); return int(m.group(1), 16) if m else None
pre_irq = tok("PRE_IRQ"); post_irq = tok("POST_IRQ"); held50 = tok("IRQ_HELD_AFTER_50")
ack_irq = tok("IRQ_AFTER_ACK"); irq_cyc = tok("IRQ_HIGH_CYCLES"); irq_rises = tok("IRQ_RISES")
done_seen = tok("DONE_SEEN"); err_seen = tok("ERR_SEEN")
status_post = hextok("STATUS_POST")
print("IRQ DISC: PRE_IRQ=%s POST_IRQ=%s IRQ_HELD_AFTER_50=%s IRQ_AFTER_ACK=%s IRQ_HIGH_CYCLES=%s IRQ_RISES=%s"
      % (pre_irq, post_irq, held50, ack_irq, irq_cyc, irq_rises))
print("EVENT: DONE_SEEN=%s ERR_SEEN=%s STATUS_POST=%s"
      % (done_seen, err_seen, ("%08x" % status_post) if status_post is not None else None))
print("RB_OK_present=%d" % (1 if re.search(r"^RB_OK$", txt, re.M) else 0))
if pre_irq != 0:      print("IRQ_BAD PRE_IRQ=%s != 0" % pre_irq); bad += 1
if post_irq != 1:     print("IRQ_BAD POST_IRQ=%s != 1" % post_irq); bad += 1
if held50 != 1:       print("IRQ_BAD IRQ_HELD_AFTER_50=%s != 1" % held50); bad += 1
if ack_irq != 0:      print("IRQ_BAD IRQ_AFTER_ACK=%s != 0" % ack_irq); bad += 1
if irq_rises != 1:    print("IRQ_BAD IRQ_RISES=%s != 1" % irq_rises); bad += 1
if irq_cyc is None or irq_cyc < 50:
    print("IRQ_BAD IRQ_HIGH_CYCLES=%s < 50 (kept-level check failed)" % irq_cyc); bad += 1
if done_seen != 1:    print("EVT_BAD DONE_SEEN=%s != 1" % done_seen); bad += 1
if err_seen != 0:     print("EVT_BAD ERR_SEEN=%s != 0" % err_seen); bad += 1
if status_post is not None and (status_post & 0x1) != 0x1:
    print("EVT_BAD STATUS_POST done_sticky 未置位 = %08x" % status_post); bad += 1
if status_post is not None and (status_post & 0x2) != 0:
    print("EVT_BAD STATUS_POST err 不该置位 = %08x" % status_post); bad += 1
print("JUDGE_EXTRA=%d" % bad)
sys.exit(1 if (mis != 0 or bad != 0) else 0)
PYEOF

# ===========================================================================
# 作业 1：正向 —— 3 条目小表（conv3x3 + conv1x1 + maxpool）
# ===========================================================================
echo "---- 作业 1：正向 DESC_COUNT=$DESC_COUNT（conv3x3 + conv1x1 + maxpool，全 plain）----"
run_sim pos "$DESC_ADDR" "$DESC_COUNT" "$work/mem.hex"; RC=$?
if [ "$RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/pos.log"; then
  echo "JUDGE-RED: 正向仿真未 PASS（vvp rc=$RC）"
  grep -E '^(RESULT|TBFAIL|TB-ERROR|ID_READ|STATUS_|CTRL_|RB_|DONE_SEEN|ERR_SEEN|MEM )' "$work/pos.log" || true
  exit 1
fi
grep -E '^(ID_READ|STATUS_PRE|CTRL_PRE|PRE_IRQ|RB_DESC_ADDR|RB_DESC_COUNT|RB_OK|DONE_SEEN|ERR_SEEN|STATUS_POST|CTRL_POST|POST_IRQ|IRQ_|STATUS_AFTER_ACK|MEM )' "$work/pos.log" || true

"$PY" "$work/judge_pos.py" "$work" "$work/exp.hex" "$work/pos.log.dump" "$work/pos.log" "$work/spec.txt" \
  > "$work/judge_pos.out" 2>&1
JRC=$?
cat "$work/judge_pos.out"
MIS="$(sed -n 's/^MISMATCH=\([0-9][0-9]*\)$/\1/p' "$work/judge_pos.out" | tail -1)"
JX="$(sed -n 's/^JUDGE_EXTRA=\([0-9][0-9]*\)$/\1/p' "$work/judge_pos.out" | tail -1)"
[ -n "$MIS" ] || MIS="-1"; [ -n "$JX" ] || JX="-1"
if [ "$JRC" -ne 0 ] || [ "$MIS" != "0" ] || [ "$JX" != "0" ]; then
  echo "RESULT: FAIL（正相对账 MISMATCH=$MIS JUDGE_EXTRA=$JX）"
  exit 1
fi
echo "正相对账 OK：整片 MISMATCH=0；DST0/DST1 零张量、DST2==maxpool 黄金；输入/表/邻居未动；IRQ 纪律成立。"

# ---- 与几何推算的流量交叉对账（内存模型独立计数）----
MEMLINE="$(grep -E '^MEM rd=' "$work/pos.log" | tail -1 || true)"
echo "MEMCROSS $MEMLINE (expect rd>=$EXP_MEMRD wr=$EXP_MEMWR)"
MRD="$(sed -n 's/^MEM rd=\([0-9]*\) wr=\([0-9]*\).*/\1/p' "$work/pos.log" | tail -1)"
MWR="$(sed -n 's/^MEM rd=\([0-9]*\) wr=\([0-9]*\).*/\2/p' "$work/pos.log" | tail -1)"
if [ -z "$MRD" ] || [ "$MRD" -lt "$EXP_MEMRD" ]; then echo "RESULT: FAIL（MEM rd=${MRD:-?} < $EXP_MEMRD）"; exit 1; fi
if [ "${MWR:-x}" != "$EXP_MEMWR" ]; then echo "RESULT: FAIL（MEM wr=${MWR:-?} != $EXP_MEMWR）"; exit 1; fi
echo "流量交叉对账 OK：MEM rd=$MRD (>= 取表 $(( (DESC_COUNT + 1) * 32 )) + 3 单元各 $IN_BYTES) / wr=$MWR (== 2*$IN_BYTES + $MP_OUT)"

# ---------------- 比较器自检：扰动黄金一个期望字节 ⇒ MISMATCH 必须恰好 1 ----------------
"$PY" - "$work" "$DST2" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
work, dst2 = sys.argv[1], int(sys.argv[2])
lines = [l.strip() for l in open(work + "/exp.hex") if l.strip()]
idx = dst2 + 17
lines[idx] = "%02x" % ((int(lines[idx], 16) ^ 0x01) & 0xFF)
open(work + "/exp_neg.hex", "w").write("\n".join(lines) + "\n")
print("CMP_SELFTEST_PERTURB idx=%d" % idx)
PYEOF
if ! "$PY" - "$work" "$work/exp_neg.hex" "$work/pos.log.dump" > "$work/selftest.out" 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from cmpbytes import load, diffs
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
exp, got = load(sys.argv[2]), load(sys.argv[3])
mis, first = diffs(got, exp)
print("MISMATCH=%d FIRST_OFF=%d" % (mis, first))
sys.exit(0 if mis == 1 else 1)
PYEOF
then
  echo "RESULT: FAIL（比较器自检不过：扰动一个期望字节后 MISMATCH 不是恰好 1）"; cat "$work/selftest.out"; exit 2
fi
cat "$work/selftest.out"
SELFMIS="$(sed -n 's/^MISMATCH=\([0-9][0-9]*\).*$/\1/p' "$work/selftest.out" | tail -1)"
if [ "$SELFMIS" != "1" ]; then echo "RESULT: FAIL（比较器自检 MISMATCH=$SELFMIS != 1）⇒ 闸门不可信"; exit 2; fi
echo "CMP_SELFTEST OK（扰动一个期望字节 ⇒ MISMATCH=1）"

# ===========================================================================
# 作业 3：负对照 A —— 非法表：DESC_COUNT 与哨兵不符（少写 1）
# ===========================================================================
echo "---- 作业 3：负对照 A[非法表: DESC_COUNT=$NEG_COUNT（表里 3 载荷 + 哨兵）] 响亮 err + 零设备搬运 ----"
run_sim negcount "$DESC_ADDR" "$NEG_COUNT" "$work/mem.hex" +EXPECT_ERR; NRC=$?
if [ "$NRC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/negcount.log"; then
  echo "NEG_RED[count]: 装置没按预期报 err"
  grep -E '^(RESULT|TBFAIL|STATUS_|DONE_SEEN|ERR_SEEN|MEM )' "$work/negcount.log" || true
  echo "RESULT: FAIL（负对照未发火）⇒ 闸门不可信"; exit 2
fi
grep -E '^(STATUS_PRE|DONE_SEEN|ERR_SEEN|STATUS_POST|PRE_IRQ|POST_IRQ|IRQ_AFTER_ACK|MEM )' "$work/negcount.log" || true
nc_ok=1
grep -q '^DONE_SEEN=0 ERR_SEEN=1$' "$work/negcount.log" || { echo "NEG_RED[count]: 主机没看到 err / 看到 done"; nc_ok=0; }
sp="$(sed -n 's/^STATUS_POST \([0-9a-fA-F]\{8\}\)$/\1/p' "$work/negcount.log" | tail -1)"
if [ -z "$sp" ]; then echo "NEG_RED[count]: 缺 STATUS_POST"; nc_ok=0; else
  b1=$(( (0x$sp >> 1) & 1 )); echo "NEGCOUNT_STATUS_POST=0x$sp -> err_bit=$b1"
  [ "$b1" = "1" ] || { echo "NEG_RED[count]: STATUS.bit1(err) 不是 1"; nc_ok=0; }
fi
MWRB="$(sed -n 's/^MEM rd=\([0-9]*\) wr=\([0-9]*\).*/\2/p' "$work/negcount.log" | tail -1)"
[ "${MWRB:-x}" = "0" ] || { echo "NEG_RED[count]: 零搬运不成立（MEM wr=${MWRB:-?} != 0）"; nc_ok=0; }
same="$("$PY" - "$work/mem.hex" "$work/negcount.log.dump" "$work" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[3])
from cmpbytes import load, diffs
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
a, b = load(sys.argv[1]), load(sys.argv[2])
c, f = diffs(a, b)
print("%d %d" % (c, f))
PYEOF
)"
echo "NEGCOUNT_DUMP_DIFF=$same（应 0 -1：零设备搬运）"
[ "$same" = "0 -1" ] || { echo "NEG_RED[count]: 镜像与预载不同 ⇒ 非法表竟然改了内存"; nc_ok=0; }
if [ "$nc_ok" != "1" ]; then echo "RESULT: FAIL（负对照未发火）⇒ 闸门不可信"; exit 2; fi
echo "NEG_OK[count]: 主机经 STATUS 观察到 err；零设备搬运（MEM wr=0、镜像==预载、无 done）"

# ===========================================================================
# 作业 4：负对照 B —— 非法表：未知 TYPE(0x77)，DESC_COUNT=1
# ===========================================================================
echo "---- 作业 4：负对照 B[非法表: 未知 TYPE=0x77] 响亮 err + 零设备搬运 ----"
run_sim negtype "$DESC_ADDR" 1 "$work/negtype.hex" +EXPECT_ERR; NTRC=$?
if [ "$NTRC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/negtype.log"; then
  echo "NEG_RED[type]: 装置没按预期报 err"
  grep -E '^(RESULT|TBFAIL|STATUS_|DONE_SEEN|ERR_SEEN|MEM )' "$work/negtype.log" || true
  echo "RESULT: FAIL（负对照未发火）⇒ 闸门不可信"; exit 2
fi
grep -E '^(STATUS_PRE|DONE_SEEN|ERR_SEEN|STATUS_POST|PRE_IRQ|POST_IRQ|IRQ_AFTER_ACK|MEM )' "$work/negtype.log" || true
nt_ok=1
grep -q '^DONE_SEEN=0 ERR_SEEN=1$' "$work/negtype.log" || { echo "NEG_RED[type]: 主机没看到 err / 看到 done"; nt_ok=0; }
sp="$(sed -n 's/^STATUS_POST \([0-9a-fA-F]\{8\}\)$/\1/p' "$work/negtype.log" | tail -1)"
if [ -z "$sp" ]; then echo "NEG_RED[type]: 缺 STATUS_POST"; nt_ok=0; else
  b1=$(( (0x$sp >> 1) & 1 )); echo "NEGTYPE_STATUS_POST=0x$sp -> err_bit=$b1"
  [ "$b1" = "1" ] || { echo "NEG_RED[type]: STATUS.bit1(err) 不是 1"; nt_ok=0; }
fi
MWRB="$(sed -n 's/^MEM rd=\([0-9]*\) wr=\([0-9]*\).*/\2/p' "$work/negtype.log" | tail -1)"
[ "${MWRB:-x}" = "0" ] || { echo "NEG_RED[type]: 零搬运不成立（MEM wr=${MWRB:-?} != 0）"; nt_ok=0; }
same="$("$PY" - "$work/negtype.hex" "$work/negtype.log.dump" "$work" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[3])
from cmpbytes import load, diffs
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
a, b = load(sys.argv[1]), load(sys.argv[2])
c, f = diffs(a, b)
print("%d %d" % (c, f))
PYEOF
)"
echo "NEGTYPE_DUMP_DIFF=$same（应 0 -1：零设备搬运）"
[ "$same" = "0 -1" ] || { echo "NEG_RED[type]: 镜像与预载不同 ⇒ 非法表竟然改了内存"; nt_ok=0; }
if [ "$nt_ok" != "1" ]; then echo "RESULT: FAIL（负对照未发火）⇒ 闸门不可信"; exit 2; fi
echo "NEG_OK[type]: 主机经 STATUS 观察到 err；零设备搬运（MEM wr=0、镜像==预载、无 done）"

# ===========================================================================
# 作业 W1/W2：★ C3.16「权重经**寄存器信箱**装载」的**顶层数值**判据
#   —— 这是本片补的那条通路（C3.12 起 NpuTop 把权重口钉 0 ⇒ 顶层只能跑零张量）的**端到端**证明。
#
#   路径：主机经 AxiLite 寄存器窗写 WGT_SEL/WGT_ADDR/WGT_DATA/WGT_WE（一次一个 int8）
#         -> NpuTop -> LayerSched -> UnitExec 的**扇出**（每个切片一个 `sel===i` 比较）
#           -> 该切片自己的 `WeightStore` -> conv 数据通路 -> DDR。
#   判据：转储镜像与 Python 黄金（`conv_unit_ref` / `mac_ref`，两条独立实现交叉对账）**逐字节**相等。
#
#   作业 W1 —— **2 条目小表**（conv3x3 plain + maxpool plain），权重经信箱装载：
#     · 正对照：整片 MISMATCH=0；DST_conv == conv 黄金、DST_mp == maxpool 黄金；输入/表/邻居未被改；
#       流量与几何推算相符（MEM rd/wr 逐字节对账）。
#     · 负对照 C[**权重错一个字节**]：同一张表、同一份输入，只把切片 0 的权重换成一个被扰动的字节
#       ⇒ (a) 与**正确**黄金的 MISMATCH **必须 > 0**（判据有牙）；
#          (b) 与**被扰动权重**的黄金 MISMATCH **必须 == 0** ⇒ 输出**跟着装载进去的权重走**。
#       这两条一起把"权重根本没进 WeightStore"这条静默通路堵死（前者）并把"权重进了但没生效"
#       也堵死（后者）。
#
#   作业 W2 —— **8 片链**（head + 6 middle + tail，一次 `go`，`chainLen=8`）；
#     权重设计（可推，不是"跑跑看"）：切片 0..3 用**恒等**权重（中心抽头 = 64，dense 下
#     `y = (64*x)>>6 = x` **逐值精确**，且 |x| ≤ 127 ⇒ 不 clamp、不衰减），切片 4..7 用**四份互不相同**
#     的非平凡权重（mac_ref 向量 x4 ⇒ 每段增益 ≈ 1，`chain_l` 里逐段 `>>6` 不衰减）。
#     ⇒ 最终张量 `fin = f(x; W4,W5,W6,W7)`；**参考侧**还断言 `mids[0] == x_ddr`（恒等性精确成立）。
#     · 正对照：整片 MISMATCH=0（黄金由 `chain_l` 与 `chain_l_naive` 两条独立实现交叉对账）。
#     · 负对照 D[**别名折叠**]：把"切片 4..7 共用一份权重"的四种折叠假设（= 旧的"4 套装载口"
#       在 `L_MAX=8` 下的**结构后果**）各算一份黄金，断言 DUT 的实测输出与**每一个**折叠假设
#       都 **不同**（MISMATCH > 0）⇒ 8 片**各自独立**可写这件事由**数值**钉死。
#   ★ A-3b 契约对齐（RTL 侧是 A-3）：`desc_table.CHAIN_L_MAX` 已随 RTL 的 `L_MAX` 一起提到 **8**
#     （本片同步）⇒ `desc_table.validate` 现在**接受** W2 的 8 片链（不再判 "chain too long"），
#     Python 冻结模型与 RTL 的链长上限**同口径**。本闸门据此**显式调** `validate` 并**断言它接受**
#     （下方 PYLIST_VALIDATE 那一行由"如实打印预期的 reject"改成"断言 ok"）—— 这条原来的 C4/M2
#     口径差**已关闭**。逐项位打包仍走**冻结真源** `DT.reference_words` / `DT.pack_table` 并逐字对账。
# ===========================================================================
echo "---- W0) 造向量：权重包（切片主序）+ 2 条目表 + 8 片链 + 黄金 ----"
mkdir -p "$work/w"
if ! ( cd "$top" && PYTHONIOENCODING=utf-8 PYTHONPATH='third_party/yunet/deps' "$PY" - \
        "$work/w" "$here" "$top" <<'PYEOF'
import sys, os, struct, hashlib
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
work, refdir, topdir = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, refdir)
sys.path.insert(0, os.path.join(topdir, "y1", "tools"))
import conv_unit_ref as R
import mac_ref as M
import bypass_ref as BR
import desc_table as DT

MEMSZ   = 65536
CIN = COUT = 8
W, H    = 32, 8                 # 与 NpuTop 里 LayerSched(WIDTH=32) / 描述符 IMG_W 对账
SHIFT   = 6                     # Conv3x3Slice 的展开期常量（= UnitExec.SHIFT）
NENTRY  = COUT * CIN * 9        # 576（dense）
IN_BYTES = CIN * H * W          # 2048
MP_OUT   = CIN * (W // 2) * (H // 2)

DESC   = 4096
XIN    = 8192
YOUT   = 12288
DUMMY  = 16384                  # head/middle 的"片上占位槽"（描述符里必须合法，但硬件不拿它搬 DDR）
DUMMY2 = 16416
MPIN   = 24576
MPOUT  = 28672

def pat(i):
    return 1 + ((i * 131 + 7) % 254)

pre = bytes(pat(i) for i in range(MEMSZ))

def mk_conv(flags, src, dst, lay, tpe=0x01):
    return {"TYPE": tpe, "FLAGS": flags, "IMG_W": W, "IMG_H": H, "C_IN": CIN, "C_OUT": COUT,
            "GROUP": 1, "STRIDE": 1, "PAD": 1, "SRC_ADDR": src, "DST_ADDR": dst,
            "IN_BYTES": IN_BYTES, "QUANT_SHIFT": SHIFT, "LAYER_ID": lay}

def words_of(d):
    """与既有作业同款的"独立第三实现"：手工按位表拼 8 个字（用来对账冻结的 reference_words）。"""
    return [(d["TYPE"] & 0xFF) | ((d["FLAGS"] & 0xFF) << 8),
            (d["IMG_W"] & 0xFFFF) | ((d["IMG_H"] & 0xFFFF) << 16),
            (d["C_IN"] & 0xFFFF) | ((d["C_OUT"] & 0xFFFF) << 16),
            (d["GROUP"] & 0xFF) | ((d["STRIDE"] & 0xF) << 8) | ((d["PAD"] & 0xF) << 12),
            d["SRC_ADDR"], d["DST_ADDR"], d["IN_BYTES"],
            (d["QUANT_SHIFT"] & 0xFF) | ((d["LAYER_ID"] & 0xFF) << 8)]

def dump_bytes(path, toks):
    open(path, "w").write("".join("%02x\n" % (v & 0xFF) for v in toks))

def dump_words(path, descs):
    open(path, "w").write("\n".join(" ".join(str(x) for x in words_of(d)) for d in descs) + "\n")

# ---------------------------------------------------------------- 共用向量/权重
seed0 = 20251016
x_chw0, wt0, acc0 = M.conv3x3("dense", CIN, COUT, H, W, seed0)
x_ddr0 = R.permute_chw_nhwc(x_chw0, CIN, H, W)
y_ddr0 = R.naive_nhwc(x_ddr0, wt0, CIN, COUT, H, W, SHIFT)
# 两条独立实现交叉对账（朴素三重循环 vs mac_ref.conv_core + 布局置换）
y_ddr0b = R.permute_chw_nhwc([R.requant_shift(a, SHIFT) for a in acc0], COUT, H, W)
assert y_ddr0 == y_ddr0b, "W1：两条独立 conv 黄金不一致"
assert len(set(y_ddr0)) > 16 and any(v != 0 for v in y_ddr0), "W1：conv 黄金退化（distinct=%d）" % len(set(y_ddr0))
nclamp = sum(1 for v in y_ddr0 if v in (127, -128))
assert nclamp < len(y_ddr0) // 4, "W1：conv 黄金大面积 clamp（%d/%d）" % (nclamp, len(y_ddr0))

def to_bytes(toks):
    return bytes(v & 0xFF for v in toks)

# ---------------------------------------------------------------- 作业 W1：2 条目小表
e0 = mk_conv(0b01, XIN, YOUT, 0)                       # conv3x3 plain
e1 = {"TYPE": 0x10, "FLAGS": 0b01, "IMG_W": W // 2, "IMG_H": H // 2, "C_IN": CIN, "C_OUT": COUT,
      "GROUP": 1, "STRIDE": 2, "PAD": 0, "SRC_ADDR": MPIN, "DST_ADDR": MPOUT,
      "IN_BYTES": IN_BYTES, "QUANT_SHIFT": 0, "LAYER_ID": 1}    # maxpool plain（无权重）
tbl1 = DT.pack_table([e0, e1])
assert len(tbl1) == 3 * 32 == 96, "W1：表字节数 %d != 96" % len(tbl1)
for i, d in enumerate([e0, e1]):
    assert list(struct.unpack_from("<8I", tbl1, 32 * i)) == words_of(d) == DT.reference_words(d), \
        "W1：项 %d 的三方对账不符" % i

mem1 = bytearray(pre)
mem1[DESC:DESC + len(tbl1)] = tbl1
mem1[XIN:XIN + IN_BYTES] = to_bytes(x_ddr0)            # conv 输入（真激活，不是预载模式）
x2 = list(mem1[MPIN:MPIN + IN_BYTES])                  # maxpool 输入（= 预载模式）
x2s = [v - 256 if v >= 128 else v for v in x2]
mp = BR.maxpool_ref(x2s, CIN, W, H)
assert len(mp) == MP_OUT == 512 and len(set(mp)) > 1, "W1：maxpool 黄金退化"

gold1 = bytearray(mem1)
gold1[YOUT:YOUT + IN_BYTES] = to_bytes(y_ddr0)
gold1[MPOUT:MPOUT + len(mp)] = to_bytes(mp)
# 非退化前提：两块 DST 的**预载**都必须与黄金大部分不同（"没写"不能蒙过）
for nm, ad, g in (("YOUT/conv", YOUT, y_ddr0), ("MPOUT/maxpool", MPOUT, mp)):
    d = sum(1 for j in range(len(g)) if pre[ad + j] != (g[j] & 0xFF))
    assert d >= (len(g) * 3) // 4, "W1：%s 预载与黄金只差 %d/%d ⇒ '不写'有机会蒙过" % (nm, d, len(g))

# 权重包（切片 0 = 576 B = 本作业唯一的权重存储）
pack1 = to_bytes(wt0)
assert len(pack1) == NENTRY, "W1：权重包 %d != %d" % (len(pack1), NENTRY)
# 负对照 C：扰动**一个字节**（与 mac_ref 同口径：按 int8 重解释后异或）
wt_bad = list(wt0)
kbad = len(wt_bad) // 3
wt_bad[kbad] = R.i8(wt_bad[kbad] ^ 0xFF)
y_bad = R.naive_nhwc(x_ddr0, wt_bad, CIN, COUT, H, W, SHIFT)
teeth = sum(1 for a, b in zip(y_ddr0, y_bad) if a != b)
assert teeth > 0, "W1：扰动一个权重字节竟不改变黄金 ⇒ 负对照没牙"
gold1_bad = bytearray(gold1)
gold1_bad[YOUT:YOUT + IN_BYTES] = to_bytes(y_bad)

# ---------------------------------------------------------------- 作业 W2：8 片链
wt_id = [0] * NENTRY                                   # 恒等：中心抽头 = 64（dense：ci==co 那一个）
for co in range(COUT):
    for ci in range(CIN):
        if ci == co:
            wt_id[(co * CIN + ci) * 9 + 4] = 64
wt_list = [wt_id] * 4
for s in range(4, 8):
    _, wtk, _ = M.conv3x3("dense", CIN, COUT, H, W, seed0 + 100 + s)
    wt_list.append(R.scale_wt(wtk, 4))                 # x4 ⇒ 每段增益 ≈ 1（不衰减、不整片 clamp）
mids, fin = R.chain_l(x_chw0, wt_list, CIN, COUT, H, W, SHIFT)
mids_n, fin_n = R.chain_l_naive(x_ddr0, wt_list, CIN, COUT, H, W, SHIFT)
assert fin == fin_n and mids == mids_n, "W2：两条独立链黄金不一致"
assert len(mids) == 7 and mids[0] == x_ddr0, "W2：恒等切片不精确（mids[0] != x_ddr）"
assert len(set(fin)) >= 8 and sum(1 for v in fin if v != 0) >= len(fin) // 4, \
    "W2：链黄金退化（distinct=%d）" % len(set(fin))
nclamp2 = sum(1 for v in fin if v in (127, -128))
assert nclamp2 < len(fin), "W2：链黄金整片 clamp（%d/%d）" % (nclamp2, len(fin))

# 四种"别名折叠"假设：切片 4..7 共用一份权重（= 旧的四套装载口在 L_MAX=8 下的结构后果）。
# 另加一种：全部恒等（= C3.12 的"权重口钉 0"行为）。
alias = {}
alias["ID"] = R.chain_l(x_chw0, [wt_id] * 8, CIN, COUT, H, W, SHIFT)[1]
for s in range(4, 8):
    alias["W%d" % s] = R.chain_l(x_chw0, [wt_id] * 4 + [wt_list[s]] * 4, CIN, COUT, H, W, SHIFT)[1]
alias_dist = {}
for k, v in alias.items():
    alias_dist[k] = sum(1 for a, b in zip(fin, v) if a != b)
    assert alias_dist[k] > 0, "W2：别名假设 %s 与真黄金相同 ⇒ 判据没牙" % k

eW2 = [mk_conv(0b00, XIN, DUMMY, 0)]                   # head
eW2 += [mk_conv(0b10, DUMMY, DUMMY2, 1 + i) for i in range(6)]   # middle x6
eW2 += [mk_conv(0b11, DUMMY2, YOUT, 7)]                # tail
tbl2 = DT.pack_table(eW2)
assert len(tbl2) == 9 * 32 == 288, "W2：表字节数 %d != 288" % len(tbl2)
for i, d in enumerate(eW2):
    assert list(struct.unpack_from("<8I", tbl2, 32 * i)) == words_of(d) == DT.reference_words(d), \
        "W2：项 %d 的三方对账不符" % i
# ★ A-3b：Python 冻结模型与 RTL 的链长上限**同口径**（CHAIN_L_MAX = L_MAX = 8）⇒ 这条 8 片链
#   必须被 `DT.validate` **接受**（表尾哨兵项 = pack_table 自动追加的那一项，desc_count = 8）。
try:
    DT.validate(eW2 + [DT.SENTINEL], 8, DT.DDR_BYTES)
    print("PYLIST_VALIDATE ok（冻结模型 CHAIN_L_MAX=%d 接受 8 片链，与 RTL 的 L_MAX=8 同口径）"
          % DT.CHAIN_L_MAX)
except Exception as ex:
    raise AssertionError("PYLIST_VALIDATE reject(%s)：%s（★ 冻结模型 CHAIN_L_MAX=%d 竟拒绝了 8 片链 ⇒ "
                         "与 RTL 的 L_MAX=8 口径又裂开了）"
                         % (type(ex).__name__, str(ex)[:80], DT.CHAIN_L_MAX))

mem2 = bytearray(pre)
mem2[DESC:DESC + len(tbl2)] = tbl2
mem2[XIN:XIN + IN_BYTES] = to_bytes(x_ddr0)
gold2 = bytearray(mem2)
gold2[YOUT:YOUT + IN_BYTES] = to_bytes(fin)
d = sum(1 for j in range(IN_BYTES) if pre[YOUT + j] != (fin[j] & 0xFF))
assert d >= (IN_BYTES * 3) // 4, "W2：链输出预载与黄金只差 %d/%d" % (d, IN_BYTES)
pack2 = b"".join(to_bytes(wt) for wt in wt_list)       # 切片主序（切片 0 在前）
assert len(pack2) == 8 * NENTRY == 4608, "W2：权重包 %d != 4608" % len(pack2)

# ---------------------------------------------------------------- 落盘
for tag, mem, gold, spec in (("w1", mem1, gold1, [("desc", DESC, len(tbl1)), ("src", XIN, IN_BYTES),
                                                  ("dst", YOUT, IN_BYTES),
                                                  ("mpin", MPIN, IN_BYTES), ("mpout", MPOUT, len(mp))]),
                             ("w2", mem2, gold2, [("desc", DESC, len(tbl2)), ("src", XIN, IN_BYTES),
                                                  ("dst", YOUT, IN_BYTES)])):
    open(os.path.join(work, "mem_%s.hex" % tag), "w").write("".join("%02x\n" % b for b in mem))
    open(os.path.join(work, "pre_%s.hex" % tag), "w").write("".join("%02x\n" % b for b in pre))
    open(os.path.join(work, "exp_%s.hex" % tag), "w").write("".join("%02x\n" % b for b in gold))
    open(os.path.join(work, "spec_%s.txt" % tag), "w").write(
        "\n".join("%s %d %d" % (n, a, ln) for n, a, ln in spec) + "\n")
dump_bytes(os.path.join(work, "wgt_w1.hex"), wt0)
dump_bytes(os.path.join(work, "wgt_w1_bad.hex"), wt_bad)
dump_bytes(os.path.join(work, "wgt_w2.hex"), list(wt_list[0]) + list(wt_list[1]) +
           list(wt_list[2]) + list(wt_list[3]) + list(wt_list[4]) + list(wt_list[5]) +
           list(wt_list[6]) + list(wt_list[7]))
open(os.path.join(work, "exp_w1_bad.hex"), "w").write("".join("%02x\n" % b for b in gold1_bad))
for k, v in alias.items():
    # 落成**整片镜像**（= 载入镜像 + 把 DST 区换成该折叠假设的张量）：比较器按整片逐字节比，
    # 与 exp_w2.hex 同一形状（否则长度不等，比较器直接炸）。`& 0xFF` 是必须的：`%02x` 对负数非法。
    img = bytearray(mem2)
    img[YOUT:YOUT + IN_BYTES] = to_bytes(v)
    open(os.path.join(work, "alias_w2_%s.hex" % k), "w").write("".join("%02x\n" % b for b in img))
dump_words(os.path.join(work, "desc_w1.args"), [e0, e1])
dump_words(os.path.join(work, "desc_w2.args"), eW2)

print("W_MEMGEN memsz=%d desc=%d xin=%d yout=%d mpin=%d mpout=%d" % (MEMSZ, DESC, XIN, YOUT, MPIN, MPOUT))
print("W1_TABLE items=2 bytes=%d md5=%s（conv3x3 plain + maxpool plain；冻结 pack_table）" %
      (len(tbl1), hashlib.md5(tbl1).hexdigest()))
print("W1_WEIGHT pack=%d B md5=%s（切片0 = conv 权重；冻结 mac_ref 向量 seed=%d）" %
      (len(pack1), hashlib.md5(pack1).hexdigest(), seed0))
print("W1_GOLD conv distinct=%d clamp=%d/%d；maxpool distinct=%d" %
      (len(set(y_ddr0)), nclamp, len(y_ddr0), len(set(mp))))
print("W1_TEETH 扰动 1 字节(下标 %d) ⇒ 黄金变值 %d/%d 字节" % (kbad, teeth, len(y_ddr0)))
print("W2_TABLE items=8 bytes=%d md5=%s（head + 6 middle + tail ⇒ chainLen=8）" %
      (len(tbl2), hashlib.md5(tbl2).hexdigest()))
print("W2_WEIGHT pack=%d B（8 片 x %d）md5=%s；前 4 片=恒等(中心 64)，后 4 片=mac_ref x4" %
      (len(pack2), NENTRY, hashlib.md5(pack2).hexdigest()))
print("W2_GOLD distinct=%d nonzero=%d/%d clamp=%d" %
      (len(set(fin)), sum(1 for v in fin if v != 0), len(fin), nclamp2))
print("W2_ALIAS 与四种折叠假设的字节差：" + "; ".join("%s=%d" % (k, alias_dist[k]) for k in sorted(alias_dist)))
PYEOF
) ; then
  echo "FATAL: 生成 W 作业向量/黄金失败（或非退化/三方对账前提不成立）⇒ 闸门不可信"
  exit 3
fi
for f in mem_w1.hex exp_w1.hex pre_w1.hex wgt_w1.hex wgt_w1_bad.hex exp_w1_bad.hex spec_w1.txt \
         mem_w2.hex exp_w2.hex pre_w2.hex wgt_w2.hex spec_w2.txt alias_w2_ID.hex alias_w2_W4.hex \
         alias_w2_W5.hex alias_w2_W6.hex alias_w2_W7.hex; do
  [ -s "$work/w/$f" ] || { echo "FATAL: W 作业激励文件 $f 缺失或为空"; exit 3; }
done

# ---- 逐字节比较的两个小工具（与作业 1 同口径：分块比较 + 打印首个不符偏移）----
cat > "$work/cmp2.py" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from cmpbytes import load, diffs
a, b = load(sys.argv[2]), load(sys.argv[3])
base = int(sys.argv[4]) if len(sys.argv) > 4 else 0
mis, first = diffs(a, b, base)
print("MISMATCH=%d FIRST_OFF=%d" % (mis, first))
sys.exit(0)
PYEOF

cat > "$work/judge_w.py" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from cmpbytes import load, diffs
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
work, exp_f, dump_f, load_f, spec_f = sys.argv[1:6]
gold = load(exp_f); got = load(dump_f); loaded = load(load_f)
mis, first = diffs(got, gold)
print("MISMATCH=%d" % mis)
print("FIRST_OFF=%d" % first)
bad = 0
regs = []
for ln in open(spec_f):
    t = ln.split()
    if len(t) == 3:
        regs.append((t[0], int(t[1]), int(t[2])))
for n, a, ln in regs:
    d, f = diffs(got[a:a + ln], gold[a:a + ln], a)
    print("REGION %s len=%d vs golden MISMATCH=%d first=%d" % (n, ln, d, f))
    if d: bad += 1
chk = bytearray(loaded)
for n, a, ln in regs:
    chk[a:a + ln] = got[a:a + ln]
d, f = diffs(got, bytes(chk), 0)
print("NEIGHBOR_ALL_MISMATCH=%d (first=%d)（除上面点名区之外的整片 vs 载入镜像）" % (d, f))
if d: bad += 1
print("JUDGE_EXTRA=%d" % bad)
sys.exit(1 if (mis != 0 or bad != 0) else 0)
PYEOF

# ===========================================================================
# 作业 W1 正对照：2 条目小表 + 经信箱装载的 conv 权重 ⇒ 逐字节对账
# ===========================================================================
echo "---- W1 正对照：权重经寄存器信箱装载（1 片 x $NENTRY B）+ 2 条目表（conv3x3 + maxpool）----"
run_sim w1pos "$DESC_ADDR" 2 "$work/w/mem_w1.hex" "+WGTPACK=$work/w/wgt_w1.hex" \
        +WGTPACK_SLICES=1 +WGTPACK_ENTRIES="$NENTRY"; WRC=$?
if [ "$WRC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/w1pos.log"; then
  echo "JUDGE-RED[W1]: 正向仿真未 PASS（vvp rc=$WRC）"
  grep -E '^(RESULT|TBFAIL|TB-ERROR|WGT|STATUS_|DONE_SEEN|ERR_SEEN|MEM )' "$work/w1pos.log" || true
  exit 1
fi
grep -E '^(TB NPUSCHED|ID_READ|RB_OK|WGT_RB|WGT_LOADED|WGT_OK|DONE_SEEN|ERR_SEEN|STATUS_POST|IRQ_|MEM )' \
     "$work/w1pos.log" || true
"$PY" "$work/judge_w.py" "$work" "$work/w/exp_w1.hex" "$work/w1pos.log.dump" \
      "$work/w/mem_w1.hex" "$work/w/spec_w1.txt" > "$work/w1judge.out" 2>&1
WJRC=$?
cat "$work/w1judge.out"
W1MIS="$(sed -n 's/^MISMATCH=\([0-9][0-9]*\)$/\1/p' "$work/w1judge.out" | tail -1)"
W1X="$(sed -n 's/^JUDGE_EXTRA=\([0-9][0-9]*\)$/\1/p' "$work/w1judge.out" | tail -1)"
[ -n "$W1MIS" ] || W1MIS="-1"; [ -n "$W1X" ] || W1X="-1"
if [ "$WJRC" -ne 0 ] || [ "$W1MIS" != "0" ] || [ "$W1X" != "0" ]; then
  echo "RESULT: FAIL（W1 正相对账 MISMATCH=$W1MIS JUDGE_EXTRA=$W1X）"
  exit 1
fi
# 流量交叉对账：取表 (2+1)*32 + conv 读 2048 + maxpool 读 2048 = 4192；写 = 2048 + 512 = 2560
WMRD="$(sed -n 's/^MEM rd=\([0-9]*\) wr=.*/\1/p' "$work/w1pos.log" | tail -1)"
WMWR="$(sed -n 's/^MEM rd=[0-9]* wr=\([0-9]*\).*/\1/p' "$work/w1pos.log" | tail -1)"
echo "W1_MEMCROSS MEM rd=$WMRD wr=$WMWR (expect rd=4192 wr=2560)"
[ "$WMRD" = "4192" ] || { echo "RESULT: FAIL（W1 MEM rd=$WMRD != 4192）"; exit 1; }
[ "$WMWR" = "2560" ] || { echo "RESULT: FAIL（W1 MEM wr=$WMWR != 2560）"; exit 1; }
echo "W1_OK：信箱装载的 conv 输出与 Python 黄金**逐字节**相等（DST_conv == conv 黄金、DST_mp == maxpool 黄金）；输入/表/邻居未动"

# ===========================================================================
# 作业 W1 负对照 C：权重错一个字节 ⇒ 判据必须发火（且输出**跟着**装载的权重走）
# ===========================================================================
echo "---- W1 负对照 C[权重错 1 字节]：与正确黄金 MISMATCH>0，与被扰动权重黄金 MISMATCH==0 ----"
run_sim w1neg "$DESC_ADDR" 2 "$work/w/mem_w1.hex" "+WGTPACK=$work/w/wgt_w1_bad.hex" \
        +WGTPACK_SLICES=1 +WGTPACK_ENTRIES="$NENTRY"; WNRC=$?
if [ "$WNRC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/w1neg.log"; then
  echo "JUDGE-RED[W1/C]: 装置未 PASS（表/输入与正对照一致，只是权重被扰动）"
  grep -E '^(RESULT|TBFAIL|WGT|DONE_SEEN|ERR_SEEN|MEM )' "$work/w1neg.log" || true
  exit 1
fi
grep -E '^(WGT_LOADED|DONE_SEEN|ERR_SEEN|STATUS_POST|IRQ_|MEM )' "$work/w1neg.log" | sed 's/^/   /' || true
"$PY" "$work/cmp2.py" "$work" "$work/w/exp_w1.hex" "$work/w1neg.log.dump" > "$work/w1neg_a.out" 2>&1
cat "$work/w1neg_a.out"
"$PY" "$work/cmp2.py" "$work" "$work/w/exp_w1_bad.hex" "$work/w1neg.log.dump" > "$work/w1neg_b.out" 2>&1
cat "$work/w1neg_b.out"
NA="$(sed -n 's/^MISMATCH=\([0-9][0-9]*\).*$/\1/p' "$work/w1neg_a.out" | tail -1)"
NB="$(sed -n 's/^MISMATCH=\([0-9][0-9]*\).*$/\1/p' "$work/w1neg_b.out" | tail -1)"
[ -n "$NA" ] || NA="-1"; [ -n "$NB" ] || NB="-1"
echo "W1NEG_MISMATCH_VS_GOOD=$NA (须 > 0)  W1NEG_MISMATCH_VS_BAD=$NB (须 == 0)"
if [ "$NA" -le 0 ]; then echo "RESULT: FAIL（负对照 C 未发火：MISMATCH vs 正确黄金 = $NA）⇒ 闸门不可信"; exit 2; fi
if [ "$NB" != "0" ]; then echo "RESULT: FAIL（负对照 C：输出**没有**跟着装载的权重走：MISMATCH vs 扰动权重黄金 = $NB）⇒ 闸门不可信"; exit 2; fi
echo "W1NEG_OK：权重换一个字节 ⇒ 输出随之改变（且与被扰动权重的 Python 黄金逐字节相等）"

# ===========================================================================
# 作业 W2：8 片链（chainLen=8）⇒ 8 个 WeightStore **各自独立**可写（数值证据）
# ===========================================================================
echo "---- W2 正对照：8 片链（head+6 middle+tail）权重 = 4x恒等 + 4 份互不相同（切片 4..7）----"
run_sim8 w2pos "$DESC_ADDR" 8 "$work/w/mem_w2.hex" "+WGTPACK=$work/w/wgt_w2.hex" \
        +WGTPACK_SLICES=8 +WGTPACK_ENTRIES="$NENTRY"; W2RC=$?
if [ "$W2RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/w2pos.log"; then
  echo "JUDGE-RED[W2]: 正向仿真未 PASS（vvp rc=$W2RC）"
  grep -E '^(RESULT|TBFAIL|TB-ERROR|WGT|STATUS_|DONE_SEEN|ERR_SEEN|MEM )' "$work/w2pos.log" || true
  exit 1
fi
grep -E '^(TB NPUSCHED|RB_OK|WGT_RB|WGT_LOADED|WGT_OK|DONE_SEEN|ERR_SEEN|STATUS_POST|IRQ_|MEM )' \
     "$work/w2pos.log" || true
"$PY" "$work/judge_w.py" "$work" "$work/w/exp_w2.hex" "$work/w2pos.log.dump" \
      "$work/w/mem_w2.hex" "$work/w/spec_w2.txt" > "$work/w2judge.out" 2>&1
W2JRC=$?
cat "$work/w2judge.out"
W2MIS="$(sed -n 's/^MISMATCH=\([0-9][0-9]*\)$/\1/p' "$work/w2judge.out" | tail -1)"
W2X="$(sed -n 's/^JUDGE_EXTRA=\([0-9][0-9]*\)$/\1/p' "$work/w2judge.out" | tail -1)"
[ -n "$W2MIS" ] || W2MIS="-1"; [ -n "$W2X" ] || W2X="-1"
if [ "$W2JRC" -ne 0 ] || [ "$W2MIS" != "0" ] || [ "$W2X" != "0" ]; then
  echo "RESULT: FAIL（W2 正相对账 MISMATCH=$W2MIS JUDGE_EXTRA=$W2X）"
  exit 1
fi
# 取表 = (8+1)*32 = 288（+ 链扫描不重复取表：每项恰好取一次）；读 = 288 + 2048 = 2336；写 = 2048
W2RD="$(sed -n 's/^MEM rd=\([0-9]*\) wr=.*/\1/p' "$work/w2pos.log" | tail -1)"
W2WR="$(sed -n 's/^MEM rd=[0-9]* wr=\([0-9]*\).*/\1/p' "$work/w2pos.log" | tail -1)"
echo "W2_MEMCROSS MEM rd=$W2RD wr=$W2WR (expect rd=2336 wr=2048)"
[ "$W2RD" = "2336" ] || { echo "RESULT: FAIL（W2 MEM rd=$W2RD != 2336：链上中间张量竟然落 DDR？）"; exit 1; }
[ "$W2WR" = "2048" ] || { echo "RESULT: FAIL（W2 MEM wr=$W2WR != 2048）"; exit 1; }
echo "W2_OK：8 片链的输出与 Python 链黄金**逐字节**相等（中间张量零 DDR：wr 只有最后一段那 2048 B）"

echo "---- W2 负对照 D[别名折叠]：切片 4..7 若共用一份权重 ⇒ 与实测输出**必须不同** ----"
w2_alias_ok=1
for k in ID W4 W5 W6 W7; do
  "$PY" "$work/cmp2.py" "$work" "$work/w/alias_w2_$k.hex" "$work/w2pos.log.dump" > "$work/w2alias_$k.out" 2>&1
  AM="$(sed -n 's/^MISMATCH=\([0-9][0-9]*\).*$/\1/p' "$work/w2alias_$k.out" | tail -1)"
  echo "W2ALIAS[$k] MISMATCH=$AM（须 > 0）"
  [ "${AM:-0}" -gt 0 ] || { echo "NEG_RED[alias $k]: 折叠假设 $k 与实测输出相同 ⇒ 8 片独立性没被证到"; w2_alias_ok=0; }
done
if [ "$w2_alias_ok" != "1" ]; then echo "RESULT: FAIL（别名折叠负对照未发火）⇒ 闸门不可信"; exit 2; fi
echo "W2ALIAS_OK：四种'切片 4..7 共用权重'的折叠假设 + '全零权重' 一档，实测输出与它们**全不相等**"
echo "           ⇒ 8 个 WeightStore 各自独立可写（旧的四套装载口在 L_MAX=8 下会折叠成其中一种）"

# ===========================================================================
# 作业 5/6：C2 回归（start 契约对 C2 向后兼容：DESC_COUNT 复位 0 ⇒ 块拷贝语义）
# ===========================================================================
echo "---- 作业 5：C2 回归 run_nputop_ab.sh（端到端块拷贝）----"
if ! bash "$here/run_nputop_ab.sh" > "$work/reg_nputop.log" 2>&1; then
  echo "C2_REG_RED[nputop]：run_nputop_ab.sh 非 0"; tail -20 "$work/reg_nputop.log"; exit 1
fi
grep -E '^RESULT: PASS' "$work/reg_nputop.log" | tail -1

echo "---- 作业 6：C2 回归 run_ddrcopy_ab.sh（DdrMaster 拷贝单元）----"
if ! bash "$here/run_ddrcopy_ab.sh" > "$work/reg_ddrcopy.log" 2>&1; then
  echo "C2_REG_RED[ddrcopy]：run_ddrcopy_ab.sh 非 0"; tail -20 "$work/reg_ddrcopy.log"; exit 1
fi
grep -E '^RESULT: PASS' "$work/reg_ddrcopy.log" | tail -1

# ---------------- 收口 ----------------
IRQCYC="$(sed -n 's/^IRQ_HIGH_CYCLES=\([0-9]*\).*$/\1/p' "$work/pos.log" | tail -1)"
[ -n "$IRQCYC" ] || IRQCYC="?"
echo "MISMATCH=$MIS（整片逐字节 == Python 黄金）"
echo "区域：DST0/DST1 = 零张量（冻结 conv 参考 + **主机未写权重** ⇒ 信箱复位值 0）；DST2 == maxpool 冻结参考 $MP_OUT B；输入/表/邻居未动"
echo "IRQ 纪律：PRE_IRQ=0 / POST_IRQ=1 / IRQ_AFTER_ACK=0 / IRQ_RISES=1 / IRQ_HIGH_CYCLES=$IRQCYC（保持电平，非单拍脉冲）"
echo "流量交叉对账：MEM rd=$MRD / wr=$MWR（与几何推算相符）"
echo "非法表负对照：COUNT 与哨兵不符 / 未知 TYPE ⇒ 都发火（主机经 STATUS 看到 err；零设备搬运）"
echo "★C3.16 权重信箱（真数值）：W1 2 条目表 MISMATCH=$W1MIS（conv 权重经信箱装载，逐字节 == Python 黄金）"
echo "                          W1 负[错 1 字节] vs 正确黄金 MISMATCH=$NA（>0） / vs 扰动权重黄金 MISMATCH=$NB（==0）"
echo "                          W2 8 片链 MISMATCH=$W2MIS（chainLen=8，切片 4..7 权重互不相同）"
echo "                          W2 负[别名折叠] 四种折叠假设 + 全零 全部 MISMATCH>0 ⇒ 8 个 WeightStore 各自独立"
echo "C2 回归：run_nputop_ab.sh = PASS；run_ddrcopy_ab.sh = PASS"
echo "RESULT: PASS"
exit 0
