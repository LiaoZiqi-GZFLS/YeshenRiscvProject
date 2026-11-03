#!/usr/bin/env bash
# run_unitexec_ab.sh —— C3.8 单单元执行器 `UnitExec`（rtl/UnitExec.scala ⇒ gen/UnitExec.v）的 S2 数值闸门。
#
# 通路：DDR(RD) -> FusionBuf(输入 3 行窗口) -> Conv3x3Slice -> 片上输出存储 -> DDR(WR)
#   一次 `go` 里，同一个 DdrMaster 先 `mode=RD` 把 `SRC_ADDR` 的激活读进来（一拍 8 B = 一个像素的
#   C 个通道），再用 `mode=WR` 把整张输出写到 `DST_ADDR`。**S2 的判据是数值**（`MISMATCH=0`），
#   不是性能；几何 = `C_IN=C_OUT=8, W=64, H=4, SHIFT=6, IN_BYTES=2048`（dense）。
#
# 判据（正对照 + 三区域 + 两条负对照 + 交叉对账 + 非退化前提 + 比较器自检 + err 路径 + QUANT_SHIFT 对账 + 连跑 GO2）：
#   0) **向量来源 + 非退化/防混叠前提**（python，写死在用例里；不成立就 exit 3，绝不当"通过"）：
#      · 激活来自 `tools/conv_unit_ref.py`（**复用 `mac_ref`** 的 dense 3x3 算术 + `>>6` + clamp），
#        以 NHWC（`[y][x][ci]`）落到 `SRC_ADDR`；黄金以 NHWC（`[y][x][co]`）落 `DST_ADDR`。
#      · 内存其它区域 = **素周期 251** 的模式（`((i%251)*131+7)%251`，131 与 251 互素 ⇒ 恰 251 周期）；
#        断言：周期恰为 251、模式逐字节两两不同、**dst 区的预载与黄金逐字节全不同**（`!=` 全 2048 字节）
#        ⇒ "一个字节都没写"不可能被误判成通过。
#      · 断言输入非常数、黄金非常数；黄金对**整行/整列平移**敏感（防"行主序喂错"被周期性图案糊住）。
#   1) **正对照**：装置 `RESULT: PASS`，且 `+DUMPFILE` 的 dst 区与黄金**逐字节**一致（`MISMATCH=0`）。
#   2) **三区域**：`DST_EQ_GOLD_BAD=0` / `SRC_UNCHANGED_BAD=0`（源区 == 预载，没被改）/
#      `NEIGHBOR_BAD=0`（dst 之外全 == 预载，含紧邻 dst 前后各 32 B）—— 挡"没写/多写/越界写"。
#   3) **交叉对账**（两处独立计数一起对才算数）：内存模型的 `MEM rd/wr/bursts/maxburst` 与装置自报的
#      `RD_BYTES_PEAK/WR_BYTES`、`AR_BURSTS/AW_BURSTS/B_OK`、以及几何行（IMG_W/H/C_IN/C_OUT/GROUP/
#      IN_BYTES/SHIFT）必须逐条相符（期望 rd=wr=2048、bursts=32（16 读 + 16 写）、maxburst=16）。
#   4) **负对照 A（requant 等效右移 −1，网表突变）**：scratch 拷贝 `gen/UnitExec.v`，把 8 处
#      `(pLoR >>> 5'd30)` 改成 `>>> 5'd29`、同时把 8 处 `(pHiR <<< 2'd2)` 改成 `<<< 2'd3`
#      （**只动"requant 等效右移"这一个自由度**；两处常量必须配套改，理由见第 5 节的注释）。判据三件套：
#        ① 突变体输出 == `conv_unit_ref` 按 `>>5` 算出的**预测黄金**（逐字节 0 差 = 精确命中）；
#        ② != 黄金（`MISMATCH > 0`）；③ 装置照旧 PASS 且字节计数一字不变（突变是**外科式**的）。
#      ★★ C4a.5a **锚点变更（显式，不是悄悄放宽）**：本任务按 §4.4 把切片的 requant 从纯 `>>SHIFT`
#         换成 `((acc·M) >> REQUANT_Q) >> SHIFT`（`Conv3x3Slice.scala` 文件头）。本单元（C4a.5a 阶段）
#         把新口按**单位元**接（`M = 2^24`、`ps_in/bias/z_y = 0`）⇒ 数值**逐字节不变**，网表里
#         `>>> 3'd6` 仍是**恰好 8 处**（每 co 一处），只是它的**来源**从 `arr_p_i` 变成乘积那一级
#         （旧的锚点串 `arr_p_i >>> 3'd6` 在新表达式下**不可能**再出现）。所以本判据把锚点从
#         `arr_p_\d+ >>> 3'd6` 改成 `>>> 3'd6`（**命中数不变 = 8**，判据的语义一字未改）。
#      ★★ C4a-R2 **再次重锚（2026-10-11，显式，不是悄悄放宽）**：requant 改成**三级流水**后，
#         `((prod >> 24) >> 6)` 被折叠成**一个常量** `RQ = REQUANT_Q + SHIFT = 30`（见
#         `Conv3x3Slice.scala` 的恒等式证明）⇒ 网表里再没有 `>>> 3'd6`。新写法是
#         `(pLoR >>> 5'd30) + ({2'd0,pHiR} <<< 2'd2)`；要"只动移位"必须两处常量配套改（q → q−1）：
#         `(pLoR >>> 5'd29) + ({2'd0,pHiR} <<< 2'd3)`（**命中数各 8 处**）。预测黄金仍是
#         `shift = SHIFT−1`（= `>>5`）—— 这一发负对照的**原意与严格性一字未变**（仍是"SHIFT 6→5"）。
#         ⚠ 诚实记录：`shift` 自报口是**常量**（`U(SHIFT,8)`），这条突变**不改**它（仍报 6）—— 所以这一发
#           是**数值**判据抓的，不是自报口抓的。正对照里另有 `SHIFT_DESC==6 && RTL_SHIFT==6` 的交叉对账。
#   5) **负对照 B（权重翻一个字节）**：把 `wgt.hex` 第 `WFLIP` 个字节取反（既不是 0 也不是 255 的位置），
#      用**同一装置**重跑。判据：突变体输出 == `conv_unit_ref` 用**同一份被改过的权重**算出的预测黄金
#      （逐字节 0 差 = 精确命中）且 != 黄金（`MISMATCH > 0`）；字节计数一字不变。
#   6) **比较器自检**：扰动黄金一个字节 ⇒ `MISMATCH` 必须**恰好 1**（不做这步就分不清"真的逐字节相符"
#      与"比较器把两边都读成空表也报 0"）。
#   7) **err 路径**：SRC 非 32 B 对齐 ⇒ DdrMaster 的入参校验必须 err 且零搬运。
#   8) **QUANT_SHIFT 描述符对账**：`+D7=5`（表 != 网表展开期的 6）⇒ RTL 必须 **err + 零搬运**
#      （rtl/UnitExec.scala 在 `go` 那一刻对账）。★ 与负对照 A 分工不同：A 是"网表被改、表对"（只能由
#      数值抓），本条是"表被改、网表对"（由描述符对账抓）—— 两条都在，就没有"`QUANT_SHIFT` 静默错值"的通路。
#   9) **连跑（第二次 `go`，C3.10 前置）**：同一 DUT 实例，第一次跑完（`busy` 落 0）后**换地址**再脉冲
#      一次 `go`（`+GO2`，第二张的输出落 `DST2`）。判据：`GO_COUNT=2`、`RUN2_DONE=1`、`RUN2_ERR=0`、
#      `RUN2_BUSY_AFTER=0`（第二次**跑完**且 `busy` 回 0 —— "第二次 `go` 挂死"就死在这几条）；突发/字节
#      计数**翻倍**（`AR/AW/B` 与内存模型 `MEM rd/wr/bursts` = 两次之和，两处独立计数一起对）；两段 dst 区
#      各自与黄金**逐字节**一致（`RUN1_DST_MISMATCH=RUN2_DST_MISMATCH=0`），第二个 dst 区的邻居与 src 未动。
#      ★ 这一条是 `conv.io.prime := runStart`（conv 流水线 additive 相位复位）的**运行期证据**：把 prime
#        钉成 0（见下"红证据"做法）后，第二次 `go` 会多出一整行像素 ⇒ 挂死或 dst2 != 黄金 ⇒ 本关必红。
#  10) **判据诊断**：转储里出现 `xx`/非法字节时，`judge_region` 先报 `XBYTES=<n>` 与一句说明
#      （X 按"不等于任何值"计 ⇒ 仍然发火），不再把判据打印成空白行。
#
# 退出码（与 Y1 既有闸门一致）：
#   0 = 全过（正对照 MISMATCH=0 + 三区域干净 + 交叉对账全对 + 两条负对照都精确命中且发火 + err 路径 +
#       QUANT_SHIFT 对账 + 连跑 GO2 全绿 + 自检过）
#   1 = 对账不符 / 编译或仿真失败 / 装置未 PASS / 网表不存在 / 连跑 GO2 未跑完或数值不符
#   2 = 负对照没发火、比较器自检不过、err/QUANT_SHIFT 对账没接在回路上 ⇒ **闸门自身不可信**（橡皮图章）
#   3 = 向量/维度自检失败（用例写错，或参考自身自检没过）
#
# 装置契约（rtl_test/UnitExecTb.v + rtl_test/AxiMemModel.v + gen/UnitExec.v）：
#   +WGTFILE= +D0..+D7=<dec> +CTRL=1  +MEMFILE= +DUMPFILE=（后两个模型自己取）
#   （连跑：+GO2 +D0B..+D7B=<dec> —— 第二套描述符，只允许地址（D4B/D5B）不同于第一套，
#     几何/长度/QUANT_SHIFT 逐条相等；装置在 time 0 同样对账，不符立即 fatal）
#   装置打印：`TB UNITEXEC: IMG_W=.. IMG_H=.. C_IN=.. C_OUT=.. GROUP=.. IN_BYTES=.. QUANT_SHIFT=..` /
#             `TB UNITEXEC: RTL_SHIFT=.. RTL_GRP=.. RTL_IMGW=.. RTL_IMGC=.. RTL_MAXPIX=..` /
#             `DONE_SEEN=.. ERR_SEEN=.. BUSY=.. GO_COUNT=.. BUSY_AT_GO2=..` /
#             `RD_BYTES_PEAK=.. WR_BYTES=..` / `AR_BURSTS=.. AW_BURSTS=.. B_OK=..` /
#             （+GO2 时另有）`TB UNITEXEC2: ...` / `RUN2_DONE=.. RUN2_ERR=.. RUN2_BUSY_AFTER=.. RUN2_CYCLES=..` /
#             `RESULT: PASS|FAIL`（FAIL ⇒ $fatal ⇒ vvp 非 0）
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

# ---- 用例常量（必须与 rtl_test/UnitExecTb.v 里 AxiMemModel 的 MEMSZ 一致）----
MEMSZ=2621440              # 2.5 MiB
SRC=131072                 # 0x20000，32B 对齐
DST=1441792                # 0x160000，32B 对齐；与 src 区不重叠
DST2=2097152               # 0x200000，第二次 go 的输出区（与 src/dst 都不重叠，给连跑用）
W=64; H=4; CIN=8; COUT=8; SGROUP=1; SHIFT=6
IN_BYTES=$(( CIN * H * W ))          # 2048（= d.w6）；断言是 128 的整数倍（S2 的尺寸约束）
PERIOD=251                           # 素周期；与 128 互素 ⇒ 整块平移必被发现
WFLIP=193                            # 负对照 B 破坏的权重字节下标（不在头/尾，值不是 0/255）

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

echo "== run_unitexec_ab: 单单元执行器 UnitExec（DDR(RD)->FusionBuf->Conv3x3Slice->输出存储->DDR(WR)）S2 数值对账 =="
echo "   tb  =$tb"
echo "   mem =$memv"
echo "   nl  =$nl"
echo "   ref =$ref"
echo "   py=${PY}  iverilog=${IVERILOG:-<找不到>}  vvp=${VVP:-<找不到>}"
echo "   tmp =$work"
echo "   用例 SRC=$SRC DST=$DST 几何 C_IN=$CIN C_OUT=$COUT W=$W H=$H GROUP=$SGROUP SHIFT=$SHIFT IN_BYTES=$IN_BYTES"

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
case $(( IN_BYTES % 128 )) in 0) : ;; *) echo "FATAL: IN_BYTES=$IN_BYTES 不是 128 的整数倍（S2 的尺寸约束）"; exit 3 ;; esac

# ---------------- 0) 参考自检 ----------------
echo "---- 0) tools/conv_unit_ref.py --selftest（复用 mac_ref 算术 + 布局置换 + 独立朴素实现交叉对账）----"
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

# ---------------- 1) 造激励 + 独立算黄金 + 非退化/防混叠前提 ----------------
echo "---- 1) 造向量：激活/权重/黄金（conv_unit_ref）+ 内存模式 + 负对照预测值 ----"
if ! "$PY" - "$work" "$here" "$MEMSZ" "$SRC" "$DST" "$DST2" "$CIN" "$COUT" "$W" "$H" "$SGROUP" "$SHIFT" "$PERIOD" "$WFLIP" <<'PYEOF'
import sys, os
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

work, refdir = sys.argv[1], sys.argv[2]
sys.path.insert(0, refdir)
import conv_unit_ref as R
import mac_ref

memsz, src, dst, dst2, CIN, COUT, W, H, GROUP, SHIFT, PERIOD, WFLIP = (int(x) for x in sys.argv[3:15])

# ---- 激活 / 权重 / 黄金（复用 mac_ref）----
wt, x_chw, x_ddr, y_ddr = R.build(CIN, COUT, H, W, seed=20251009, shift=SHIFT)
assert len(wt) == COUT * CIN * 9, "权重长度 %d" % len(wt)
assert len(x_ddr) == CIN * H * W and len(y_ddr) == COUT * H * W

# ---- 非退化前提 ----
assert len(set(x_ddr)) > 1, "激活是常数 ⇒ 用例没意义"
assert len(set(y_ddr)) > 1, "黄金是常数 ⇒ 判据会退化"
assert len(set(wt)) > 1, "权重是常数 ⇒ 用例没意义"

# ---- 防混叠 1：黄金对**整行平移 / 整列平移**敏感（行主序喂错必然变值）----
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
assert y_ddr != rowshift(y_ddr, 1), "黄金 == 整行平移 ⇒ 行错位不可观测"
assert y_ddr != colshift(y_ddr, 1), "黄金 == 整列平移 ⇒ 列错位不可观测"

# ---- 内存模式：素周期 251 ----
def pat(i):
    return ((i % PERIOD) * 131 + 7) % PERIOD
assert len(set(pat(i) for i in range(PERIOD))) == PERIOD, "模式周期不是恰好 %d" % PERIOD
assert PERIOD % 128 != 0 and 128 % PERIOD != 0, "模式周期与块长不互素"

# ---- 防混叠 2：dst 区的预载与黄金**几乎逐字节全不同** ⇒ "一个字节都没写"必然报大 MISMATCH ----
#   注：模式取值域 0..250、黄金字节铺满 0..255 ⇒ 统计上必然有 ~2048/251 ≈ 8 个字节偶然相同，
#   所以这里要求的是**压倒性不同**（>= 1900/2048），而不是"全不同"（后者对随机向量恒不成立）。
pre = bytes(pat(i) for i in range(memsz))
diff_pre = sum(1 for j in range(len(y_ddr)) if pre[dst + j] != (y_ddr[j] & 0xFF))
assert diff_pre >= 1900, "dst 区预载与黄金只有 %d/%d 字节不同 ⇒ 不写也有机会过" % (diff_pre, len(y_ddr))
# 第二次 go 的输出区（DST2）同理：预载与黄金压倒性不同 ⇒ 连跑里"第二张一个字节都没写"必被抓住。
diff_pre2 = sum(1 for j in range(len(y_ddr)) if pre[dst2 + j] != (y_ddr[j] & 0xFF))
assert diff_pre2 >= 1900, "DST2 区预载与黄金只有 %d/%d 字节不同 ⇒ 连跑'第二张不写'有机会过" % (diff_pre2, len(y_ddr))

# ---- 结构自检 ----
assert src % 32 == 0 and dst % 32 == 0 and dst2 % 32 == 0, "地址必须 32B 对齐"
assert src + CIN * H * W <= dst or dst + COUT * H * W <= src, "src/dst 区重叠"
assert (dst2 + COUT * H * W <= src or src + CIN * H * W <= dst2) \
   and (dst2 + COUT * H * W <= dst or dst + COUT * H * W <= dst2), "DST2 与 src/dst 区重叠"
assert max(src + CIN * H * W, dst + COUT * H * W, dst2 + COUT * H * W) <= memsz, "越出已建模内存"
assert min(src, dst, dst2) >= 128 and memsz - (dst2 + COUT * H * W) >= 128, "前后要留出邻居字节"

# ---- 落盘：内存镜像（激活铺在 src 区）+ 权重 + 黄金 ----
mem = bytearray(pre)
mem[src:src + len(x_ddr)] = bytes(v & 0xFF for v in x_ddr)
with open(work + "/mem.hex", "w") as f:
    f.write("".join("%02x\n" % b for b in mem))
R.dump_bytes(work + "/wgt.hex", wt)
with open(work + "/gold.hex", "w") as f:
    f.write("".join("%02x\n" % (v & 0xFF) for v in y_ddr))

# ---- 负对照 A 的预测黄金：同一套算术、requant 改成 >>(SHIFT-1) = >>5 ----
#   ★★ C4a-R2：突变体把 `>>> 5'd30` 改成 `>>> 5'd29`（配套 `<<< 2'd2 -> <<< 2'd3`，等效右移 −1）。在本单元
#   （M = 2^24 单位乘子、ps_in/bias/z_y = 0）下突变体算的是 `floor(acc·2^24 / 2^29) = acc >> 5` ⇒ 预测黄金用 `shift = SHIFT-1`。
_, _, _, y_s5 = R.build(CIN, COUT, H, W, seed=20251009, shift=SHIFT - 1)
with open(work + "/gold_shiftmut.hex", "w") as f:
    f.write("".join("%02x\n" % (v & 0xFF) for v in y_s5))
d_s5 = sum(1 for a, b in zip(y_ddr, y_s5) if a != b)
assert d_s5 > 0, ">>5 与 >>6 的黄金相同 ⇒ 负对照 A 没意义"

# ---- 负对照 B 的预测黄金：把第 WFLIP 个权重字节取反（★ 按 **int8** 重解释：硬件读的是 SInt(8)）----
assert 0 <= WFLIP < len(wt), "WFLIP 越界"
assert wt[WFLIP] not in (0, 255), "WFLIP 处的权重是哨兵值 0/255（取反会撞回原值）"
wt_bad = list(wt)
wt_bad[WFLIP] = R.i8(wt_bad[WFLIP] ^ 0xFF)     # 关键：Python 的 ^0xFF 给的是正整数，必须重解释成 int8
_, _, _, y_wbad = R.build(CIN, COUT, H, W, seed=20251009, shift=SHIFT, woverride=wt_bad)
with open(work + "/wgt_flip.hex", "w") as f:
    f.write("".join("%02x\n" % (v & 0xFF) for v in wt_bad))
with open(work + "/gold_wflip.hex", "w") as f:
    f.write("".join("%02x\n" % (v & 0xFF) for v in y_wbad))
d_wf = sum(1 for a, b in zip(y_ddr, y_wbad) if a != b)
assert d_wf > 0, "翻一个权重字节后黄金没变 ⇒ 负对照 B 没意义"

# ---- 描述符 8 个字（与 desc_table.pack 的位打包一致）----
D = [0] * 8
D[0] = 0x01 | (0x01 << 8)                         # TYPE=conv3x3, FLAGS=0b01（独立单元，输出落 DDR）
D[1] = W | (H << 16)
D[2] = CIN | (COUT << 16)
D[3] = GROUP | (1 << 8) | (1 << 12)               # GROUP, STRIDE=1, PAD=1
D[4] = src
D[5] = dst
D[6] = CIN * H * W                                # IN_BYTES
D[7] = SHIFT                                      # QUANT_SHIFT, LAYER_ID=0
with open(work + "/desc.args", "w") as f:
    f.write(" ".join(str(x) for x in D))

print("MEMGEN bytes=%d src=%d dst=%d dst2=%d period=%d" % (memsz, src, dst, dst2, PERIOD))
print("NONALIAS: 周期恰 %d；dst/dst2 区预载与黄金 %d/%d、%d/%d 字节不同（'不写'必被抓住）；黄金 != 整行/整列平移"
      % (PERIOD, diff_pre, len(y_ddr), diff_pre2, len(y_ddr)))
print("GOLD: 黄金 md5 由闸门另记；>>5(=shift-1) 预测差 %d/%d 字节；权重翻字节预测差 %d/%d 字节"
      % (d_s5, len(y_ddr), d_wf, len(y_ddr)))
print("DESC: w0=%d w1=%d w2=%d w3=%d w4=%d w5=%d w6=%d w7=%d" % tuple(D))
PYEOF
then
  echo "FATAL: 生成向量/黄金失败（或非退化/防混叠前提不成立）⇒ 闸门不可信"
  exit 3
fi
for f in mem.hex wgt.hex gold.hex gold_shiftmut.hex wgt_flip.hex gold_wflip.hex desc.args; do
  [ -s "$work/$f" ] || { echo "FATAL: 激励文件 $f 缺失或为空"; exit 3; }
done
read -r D0 D1 D2 D3 D4 D5 D6 D7 < "$work/desc.args"

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

def load(p):
    return [l.strip() for l in open(p, encoding="utf-8", errors="replace") if l.strip()]

def load_num(p):
    """把转储/黄金读成整数表（一行一个十六进制字节）。
    非法记号（`xx` / 非十六进制 / 越界）记成 XBAD 并计数 —— **不抛异常**：
    坏转储也是判据要诊断的对象，绝不能让 judge 自己崩掉、把判据打印成空白。

    返回 (values, n_bad, first_bad_line)。"""
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

# run_sim <vvp> <logbase> <wgtfile> [extra args...]
run_sim() {
  local vvp="$1" log="$2" wgt="$3"; shift 3
  ( cd "$work" && "$VVP" "$vvp" \
      "+WGTFILE=$wgt" "+MEMFILE=$work/mem.hex" "+DUMPFILE=$work/$log.dump" +dump \
      "+D0=$D0" "+D1=$D1" "+D2=$D2" "+D3=$D3" "+D4=$D4" "+D5=$D5" "+D6=$D6" "+D7=$D7" "+CTRL=1" "$@" ) \
      > "$work/$log.log" 2>&1
  return $?
}

# judge_region <dump> <gold> <tag> -> 打印 XBYTES / MISMATCH / 三区域
judge_region() {
  "$PY" - "$work" "$1" "$2" "$SRC" "$DST" "$IN_BYTES" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from cmpbytes import load_num, diffs
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
dump_f, gold_f, src, dst, ln = sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
# ---- X 诊断（先打印，坏转储也能被读出来；X 按"不等于任何值"计 ⇒ MISMATCH 必然发火）----
d, dx, dfl = load_num(dump_f)
g, gx, gfl = load_num(gold_f)
print("XBYTES=%d" % dx)
print("XBYTES_GOLD=%d" % gx)
if dx or gx:
    print("JUDGE-NOTE: 转储/黄金里有非法(未知/`xx`)字节 ⇒ dump %d 个（首个在第 %d 行）、gold %d 个（首个在第 %d 行）；"
          "X 按'不等于任何值'计，所以下面的 MISMATCH 会发火（这是刻意的：坏转储绝不当'没写/写对'）"
          % (dx, dfl, gx, gfl))
p, px, pfl = load_num(sys.argv[1] + "/pre.hex")
if px:
    print("JUDGE-NOTE: 预载镜像 pre.hex 里也有 %d 个非法字节（首个第 %d 行）⇒ 激励文件本身坏了" % (px, pfl))
if len(d) < dst + ln or len(g) < ln:
    print("JUDGE-NOTE: 长度不足（dump=%d gold=%d 需要 %d/%d）⇒ 转储被截断" % (len(d), len(g), dst + ln, ln))
k = min(ln, len(g), max(0, len(d) - dst))
m, first = diffs(d[dst:dst+k], g[:k], 0)
print("MISMATCH=%d" % m)
print("FIRST_OFF=%d" % (dst + first if first >= 0 else -1))
s_bad, s_first = diffs(d[src:src+k], p[src:src+k], src)
print("SRC_UNCHANGED_BAD=%d" % s_bad)
n_bad, n_first = diffs(d[:dst], p[:dst], 0)
t_bad, t_first = diffs(d[dst+ln:], p[dst+ln:], dst+ln)
nb32b = sum(1 for j in range(32) if d[dst-32+j] != p[dst-32+j])
nb32a = sum(1 for j in range(32) if d[dst+ln+j] != p[dst+ln+j])
print("NEIGHBOR_BAD=%d" % (n_bad + t_bad))
print("NEIGHBOR32 before_dst=%d after_dstlen=%d" % (nb32b, nb32a))
PYEOF
}
# 预载镜像（给区域比较用）
"$PY" - "$work/mem.hex" "$work/pre.hex" <<'PYEOF'
import sys
t = [l.strip() for l in open(sys.argv[1]) if l.strip()]
open(sys.argv[2], "w").write("\n".join(t) + "\n")
PYEOF

# ---------------- 3) 作业 1：正对照 ----------------
echo "---- 3) 正对照：SRC->DST 整单元（几何 C_IN=$CIN C_OUT=$COUT W=$W H=$H GROUP=$SGROUP SHIFT=$SHIFT）----"
run_sim sim.vvp pos "$work/wgt.hex"; RC=$?
if [ "$RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/pos.log"; then
  echo "JUDGE-RED: 正对照仿真未 PASS（vvp rc=$RC）"
  grep -E '^(RESULT|TB-ERROR|TBFAIL|DONE_SEEN|RD_BYTES_PEAK|AR_BURSTS|MEM )' "$work/pos.log" || true
  exit 1
fi
grep -E '^(TB UNITEXEC|DONE_SEEN|RD_BYTES_PEAK|AR_BURSTS|MEM )' "$work/pos.log" | sed 's/^/   /'

# 3a) 几何/自报交叉对账
GEOM="$(grep -m1 '^TB UNITEXEC: IMG_W=' "$work/pos.log")"
SHREP="$(grep -m1 '^TB UNITEXEC: RTL_SHIFT=' "$work/pos.log")"
EXP_GEOM="TB UNITEXEC: IMG_W=$W IMG_H=$H C_IN=$CIN C_OUT=$COUT GROUP=$SGROUP IN_BYTES=$IN_BYTES QUANT_SHIFT=$SHIFT"
# `RTL_MAXPIX` = 网表自报的输出存储字数上限 = 展开期 WIDTH*IMG_H_MAX；本用例的网表按 IMG_H_MAX=H=$H 生成
# ⇒ 自报值必须恰好 = W*H（不再是旧版那个"几何 4 倍"的常量 1024）。
EXP_SHREP="TB UNITEXEC: RTL_SHIFT=$SHIFT RTL_GRP=$SGROUP RTL_IMGW=$W RTL_IMGC=$CIN RTL_MAXPIX=$(( W * H ))"
if [ "$GEOM" != "$EXP_GEOM" ]; then
  echo "JUDGE-RED: 几何/描述符行不符"; echo "  got=$GEOM"; echo "  exp=$EXP_GEOM"; exit 1
fi
if [ "$SHREP" != "$EXP_SHREP" ]; then
  echo "JUDGE-RED: 网表自报行不符（宽度/档位/shift 钉死）"; echo "  got=$SHREP"; echo "  exp=$EXP_SHREP"; exit 1
fi
echo "   几何对账 OK：$GEOM"
echo "   自报对账 OK：$SHREP"

# 3b) 字节计数交叉对账（装置自报 vs 内存模型 vs 期望）
CH=$(grep -m1 '^AR_BURSTS=' "$work/pos.log")
RDP=$(grep -m1 '^RD_BYTES_PEAK=' "$work/pos.log")
MEML="$(grep -m1 '^MEM rd=' "$work/pos.log")"
EXP_CH="AR_BURSTS=$(( IN_BYTES / 128 )) AW_BURSTS=$(( IN_BYTES / 128 )) B_OK=$(( IN_BYTES / 128 ))"
EXP_RDP="RD_BYTES_PEAK=$IN_BYTES WR_BYTES=$IN_BYTES"
EXP_MEM="MEM rd=$IN_BYTES wr=$IN_BYTES bursts=$(( 2 * IN_BYTES / 128 )) maxburst=16"
if [ "$CH" != "$EXP_CH" ]; then echo "JUDGE-RED: 突发数不符 got=[$CH] exp=[$EXP_CH]"; exit 1; fi
if [ "$RDP" != "$EXP_RDP" ]; then echo "JUDGE-RED: 字节数不符 got=[$RDP] exp=[$EXP_RDP]"; exit 1; fi
if [ "$MEML" != "$EXP_MEM" ]; then echo "JUDGE-RED: 内存模型计数不符 got=[$MEML] exp=[$EXP_MEM]"; exit 1; fi
echo "   交叉对账 OK：$CH / $RDP / $MEML"

# 3c) 三区域 + 整片
judge_region "$work/pos.dump" "$work/gold.hex" positive > "$work/pos.judge"
cat "$work/pos.judge" | sed 's/^/   /'
MIS="$(sed -n 's/^MISMATCH=\([0-9]*\)$/\1/p' "$work/pos.judge")"
SBAD="$(sed -n 's/^SRC_UNCHANGED_BAD=\([0-9]*\)$/\1/p' "$work/pos.judge")"
NBAD="$(sed -n 's/^NEIGHBOR_BAD=\([0-9]*\)$/\1/p' "$work/pos.judge")"
if [ "$MIS" != "0" ] || [ "$SBAD" != "0" ] || [ "$NBAD" != "0" ]; then
  echo "RESULT: FAIL（正对照 MISMATCH=$MIS SRC_UNCHANGED_BAD=$SBAD NEIGHBOR_BAD=$NBAD）"; exit 1
fi
echo "   正对照 OK：dst 区逐字节 == 黄金（MISMATCH=0）；src 未改；邻居未动。"

# ---------------- 4) 比较器自检：扰动黄金一个字节 ⇒ MISMATCH 必须恰好 1 ----------------
echo "---- 4) 比较器自检：扰动黄金一个期望字节 ⇒ MISMATCH 必须恰好 1 ----"
"$PY" - "$work" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
work = sys.argv[1]
t = [l.strip() for l in open(work + "/gold.hex") if l.strip()]
i = len(t) // 2
t[i] = "%02x" % ((int(t[i], 16) ^ 0x01) & 0xFF)
open(work + "/gold_pert.hex", "w").write("\n".join(t) + "\n")
print("CMP_SELFTEST_PERTURB idx=%d" % i)
PYEOF
judge_region "$work/pos.dump" "$work/gold_pert.hex" pert > "$work/pert.judge"
SELF_MIS="$(sed -n 's/^MISMATCH=\([0-9]*\)$/\1/p' "$work/pert.judge")"
echo "   CMP_SELFTEST MISMATCH=$SELF_MIS（期望恰好 1）"
if [ "$SELF_MIS" != "1" ]; then
  echo "RESULT: FAIL（比较器自检 MISMATCH=$SELF_MIS != 1）⇒ 闸门不可信"; exit 2
fi

# ---------------- 5) 负对照 A：网表突变 —— requant 等效右移 30 -> 31 ----------------
echo "---- 5) 负对照 A[requant 等效右移 30->29 网表突变]: (pLoR >>> 5'd30)->>>>5'd29 且 (pHiR <<< 2'd2)-><<<2'd3（各 8 处）----"
if ! "$PY" - "$nl" "$work/UnitExec_shiftmut.v" > "$work/mutA.out" 2>&1 <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
src = open(sys.argv[1], encoding="utf-8").read()
# ★ C4a.5a：锚点由 `(arr_p_\d+ >>> )3'd6` 改成 `(>>> )3'd6`。
# ★★ C4a-R2（2026-10-11，**显式重锚**，不是悄悄放宽）：`Conv3x3Slice` 的 §4.4 requant 改成三级流水后
#   `((prod >> 24) >> 6)` 被**折叠成一个常量** `RQ = REQUANT_Q + SHIFT = 30`（见 `Conv3x3Slice.scala`
#   的整数恒等式），网表里再没有 `>>> 3'd6`。新写法是
#       shf = (pLoR >>> 5'd30) + ({2'd0,pHiR} <<< 2'd2)     # = floor(prod/2^30)，精确
#   要"只动这一个自由度（requant 的等效右移）"，必须**两处配套改**（同一恒等式 `q -> q-1`：
#   `floor(prod/2^q) = floor(AL·M/2^q) + AH·M·2^(32-q)`，q−1 ⇒ 右移少 1、左移多 1）：
#       shf' = (pLoR >>> 5'd29) + ({2'd0,pHiR} <<< 2'd3)    # = floor(prod/2^29)，精确
#   —— ① 只改第一项 ⇒ "左半按 2^29、右半仍按 2^32" 不自洽（实测 MISMATCH=1029，不是任何纯右移）；
#      ② 左移**只能往大了改（2→3），不能往小了改（2→1）**：`{2'd0,x}` 这条零扩之所以与符号扩等价，
#         靠的是"左移位数 ≥ 2 时 `2^64` 项被推到 `2^66 ≡ 0`"；`<<1` 会把 `2^65` 留在 66 位的符号位上
#         ⇒ 又不自洽（实测同样是 MISMATCH=1029）。
#   命中数**各 8 处**（每 co 一处）。预测黄金 = `conv_unit_ref` 的 `shift = SHIFT-1`：M 为单位乘子时
#   `floor(acc·2^24 / 2^29) = acc >> 5`，与 Python 的 `acc >> 5` 逐值相同（= **旧的"SHIFT 6→5"那一发**
#   的原意，一字未变）。
n1 = len(re.findall(r"pLoR_\d+ >>> 5'd30\b", src))
new, n2 = re.subn(r"(pLoR_\d+ >>> )5'd30\b", r"\g<1>5'd29", src)
new, n3 = re.subn(r"(\{2'd0,pHiR_\d+\} <<< )2'd2\b", r"\g<1>2'd3", new)
print("MUTGEN_HITS=%d+%d+%d (期望 8+8+8=24)" % (n1, n2, n3))
if not (n1 == 8 and n2 == 8 and n3 == 8):
    sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(new)
PYEOF
then
  echo "RESULT: FAIL（无法构造 shift 突变网表：生成风格变了，请更新本判据）⇒ 闸门不可信"; cat "$work/mutA.out"; exit 2
fi
cat "$work/mutA.out"
if cmp -s "$nl" "$work/UnitExec_shiftmut.v"; then echo "RESULT: FAIL（突变网表与原文相同）⇒ 闸门不可信"; exit 2; fi
if ! "$IVERILOG" -g2012 -o "$work/mutA.vvp" "$tb" "$memv" "$work/UnitExec_shiftmut.v" > "$work/iv_mutA.log" 2>&1; then
  echo "RESULT: FAIL（shift 突变网表编译失败）"; sed -n '1,20p' "$work/iv_mutA.log"; exit 2
fi
run_sim mutA.vvp mutA "$work/wgt.hex"; ARC=$?
if ! grep -q '^RESULT: PASS' "$work/mutA.log"; then
  echo "RESULT: FAIL（shift 突变下装置未 PASS ⇒ 突变把主口/时序也改坏了，负对照不干净）"
  grep -E '^(RESULT|DONE_SEEN|RD_BYTES_PEAK)' "$work/mutA.log" || true; exit 2
fi
# 外科式：字节计数一字不变
MUTA_CH=$(grep -m1 '^AR_BURSTS=' "$work/mutA.log")
MUTA_MEM="$(grep -m1 '^MEM rd=' "$work/mutA.log")"
if [ "$MUTA_CH" != "$EXP_CH" ] || [ "$MUTA_MEM" != "$EXP_MEM" ]; then
  echo "RESULT: FAIL（shift 突变把字节数/突发数也改了 ⇒ 它不再是纯 requant 突变，负对照不干净）"
  echo "  ch=[$MUTA_CH] mem=[$MUTA_MEM]"; exit 2
fi
MUTA_SHIFTREP="$(grep -m1 '^TB UNITEXEC: RTL_SHIFT=' "$work/mutA.log")"
echo "   （诚实记录）突变后自报行仍为 [$MUTA_SHIFTREP] —— shift 自报口是常量、突变不改它 ⇒ 这一发是数值判据抓的"
# 精确命中预测 + 发火
judge_region "$work/mutA.dump" "$work/gold_shiftmut.hex" mutA > "$work/mutA.judge"
AMHIT="$(sed -n 's/^MISMATCH=\([0-9]*\)$/\1/p' "$work/mutA.judge")"
judge_region "$work/mutA.dump" "$work/gold.hex" mutA2 > "$work/mutA2.judge"
AMGOLD="$(sed -n 's/^MISMATCH=\([0-9]*\)$/\1/p' "$work/mutA2.judge")"
echo "   MUT_A: 突变体 vs >>5 预测 MISMATCH=$AMHIT（期望 0=精确命中）  vs 黄金 MISMATCH=$AMGOLD（期望 >0）"
if [ "$AMHIT" != "0" ]; then
  echo "RESULT: FAIL（负对照 A 没精确命中 >>5 的预测值：$AMHIT）⇒ 判据口径对不上突变"; exit 2
fi
if ! [ "$AMGOLD" -gt 0 ] 2>/dev/null; then
  echo "RESULT: FAIL（负对照 A 没发火：shift 改了输出却没变）⇒ 判据是橡皮章"; exit 2
fi
echo "   NEG_OK[A]: shift 6->5（网表突变 >>>5'd30->5'd29 配 <<<2'd2->2'd3）⇒ 输出精确命中 >>5 的预测（0 差）、且 != 黄金（差 $AMGOLD 字节）"

# ---------------- 6) 负对照 B：权重翻一个字节 ----------------
echo "---- 6) 负对照 B[权重翻一个字节]: wgt.hex 第 $WFLIP 字节取反 ----"
"$PY" - "$work/wgt.hex" "$work/wgt_flip.hex" "$WFLIP" <<'PYEOF'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
t = [l.strip() for l in open(sys.argv[1]) if l.strip()]
i = int(sys.argv[3])
old = int(t[i], 16)
t[i] = "%02x" % (old ^ 0xFF)
open(sys.argv[2], "w").write("\n".join(t) + "\n")
print("NEGB_PERTURB wgt[%d]: %02x -> %02x" % (i, old, old ^ 0xFF))
PYEOF
run_sim sim.vvp mutB "$work/wgt_flip.hex"; BRC=$?
if ! grep -q '^RESULT: PASS' "$work/mutB.log"; then
  echo "RESULT: FAIL（权重突变下装置未 PASS）"
  grep -E '^(RESULT|DONE_SEEN|RD_BYTES_PEAK)' "$work/mutB.log" || true; exit 2
fi
MUTB_CH=$(grep -m1 '^AR_BURSTS=' "$work/mutB.log")
MUTB_MEM="$(grep -m1 '^MEM rd=' "$work/mutB.log")"
if [ "$MUTB_CH" != "$EXP_CH" ] || [ "$MUTB_MEM" != "$EXP_MEM" ]; then
  echo "RESULT: FAIL（权重突变把字节数/突发数也改了 ⇒ 负对照不干净）"; echo "  ch=[$MUTB_CH] mem=[$MUTB_MEM]"; exit 2
fi
judge_region "$work/mutB.dump" "$work/gold_wflip.hex" mutB > "$work/mutB.judge"
BMHIT="$(sed -n 's/^MISMATCH=\([0-9]*\)$/\1/p' "$work/mutB.judge")"
judge_region "$work/mutB.dump" "$work/gold.hex" mutB2 > "$work/mutB2.judge"
BMGOLD="$(sed -n 's/^MISMATCH=\([0-9]*\)$/\1/p' "$work/mutB2.judge")"
echo "   MUT_B: 突变体 vs 翻转权重预测 MISMATCH=$BMHIT（期望 0=精确命中）  vs 黄金 MISMATCH=$BMGOLD（期望 >0）"
if [ "$BMHIT" != "0" ]; then
  echo "RESULT: FAIL（负对照 B 没精确命中翻转权重的预测：$BMHIT）⇒ 判据口径对不上突变"; exit 2
fi
if ! [ "$BMGOLD" -gt 0 ] 2>/dev/null; then
  echo "RESULT: FAIL（负对照 B 没发火：权重改了输出却没变）⇒ 判据是橡皮章"; exit 2
fi
echo "   NEG_OK[B]: 权重翻一字节 ⇒ 输出精确命中[翻转权重]的预测（0 差）、且 != 黄金（差 $BMGOLD 字节）"

# ---------------- 7) 附带：err 路径（非法 SRC 非 32B 对齐 ⇒ 装置 err 且一个字节都不搬）----------------
#   这一条不在计划的 S2 四条里，但它把"err 真的接到回路上"补上（否则 err 通路完全没被跑过）。
echo "---- 7) err 路径：SRC 非 32B 对齐（$((SRC+8))）⇒ 装置必须 err 且零搬运 ----"
( cd "$work" && "$VVP" "$work/sim.vvp" \
    "+WGTFILE=$work/wgt.hex" "+MEMFILE=$work/mem.hex" "+DUMPFILE=$work/err.dump" +dump \
    "+D0=$D0" "+D1=$D1" "+D2=$D2" "+D3=$D3" "+D4=$(( SRC + 8 ))" "+D5=$D5" "+D6=$D6" "+D7=$D7" \
    "+CTRL=1" +EXPECT_ERR ) > "$work/err.log" 2>&1
ERRC=$?
grep -E '^(DONE_SEEN|RD_BYTES_PEAK|AR_BURSTS|RESULT)' "$work/err.log" | sed 's/^/   /' || true
if [ "$ERRC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/err.log"; then
  echo "RESULT: FAIL（err 路径：SRC 非对齐时装置没按预期 err 且零搬运，rc=$ERRC）⇒ err 没接在回路上"
  exit 2
fi
ERRMEM="$(grep -m1 '^MEM rd=' "$work/err.log")"
case "$ERRMEM" in
  "MEM rd=0 wr=0 bursts=0 maxburst=0") : ;;
  *) echo "RESULT: FAIL（err 路径下内存模型记的不是零搬运：[$ERRMEM]）"; exit 2 ;;
esac
echo "   NEG_OK[err]: SRC 非 32B 对齐 ⇒ 装置 err 且零搬运（$ERRMEM）"

# ---------------- 8) QUANT_SHIFT 描述符对账：+D7=5（表与本网表展开期的 SHIFT=6 不符）----------------
#   为什么单列一发：requant 右移在本档是 `Conv3x3Slice` 的**展开期常量**，描述符里的 `QUANT_SHIFT`
#   若被当"占位字段"读掉不用，一张写着 5 的表就会拿到**按 >>6 算出来的数**（静默错值）。
#   rtl/UnitExec.scala 现在在 `go` 那一刻对账 ⇒ 不符就**响亮 err + 零搬运**（一个 AR/AW 都不发）。
#   ★ 与负对照 A（网表突变 `>>>5'd30 -> >>>5'd31`）**分工不同**：那一条是"表对、网表被改"，只能由**数值**抓；
#     这一条是"网表对、表被改"，由**这条描述符对账**抓。两条都在，才没有静默通路。
echo "---- 8) QUANT_SHIFT 描述符对账：+D7=5（表与网表不符）⇒ RTL 必须 err 且零搬运 ----"
( cd "$work" && "$VVP" "$work/sim.vvp" \
    "+WGTFILE=$work/wgt.hex" "+MEMFILE=$work/mem.hex" "+DUMPFILE=$work/d7bad.dump" +dump \
    "+D0=$D0" "+D1=$D1" "+D2=$D2" "+D3=$D3" "+D4=$D4" "+D5=$D5" "+D6=$D6" "+D7=5" \
    "+CTRL=1" +EXPECT_ERR ) > "$work/d7bad.log" 2>&1
D7RC=$?
grep -E '^(TB UNITEXEC:|DONE_SEEN|RD_BYTES_PEAK|AR_BURSTS|RESULT)' "$work/d7bad.log" | sed 's/^/   /' || true
if [ "$D7RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/d7bad.log"; then
  echo "RESULT: FAIL（+D7=5 时装置没按预期 err 且零搬运，rc=$D7RC）⇒ QUANT_SHIFT 对账没接在回路上"
  exit 2
fi
D7MEM="$(grep -m1 '^MEM rd=' "$work/d7bad.log")"
case "$D7MEM" in
  "MEM rd=0 wr=0 bursts=0 maxburst=0") : ;;
  *) echo "RESULT: FAIL（+D7=5 时内存模型记的不是零搬运：[$D7MEM]）⇒ 描述符对账没有'零搬运'语义"; exit 2 ;;
esac
D7CH="$(grep -m1 '^AR_BURSTS=' "$work/d7bad.log")"
if [ "$D7CH" != "AR_BURSTS=0 AW_BURSTS=0 B_OK=0" ]; then
  echo "RESULT: FAIL（+D7=5 时发了突发：[$D7CH]）⇒ QUANT_SHIFT 对账不是'发第一个 AR 之前'做的"; exit 2
fi
D7SH="$(grep -m1 '^TB UNITEXEC: IMG_W=' "$work/d7bad.log")"
case "$D7SH" in
  *"QUANT_SHIFT=5") : ;;
  *) echo "RESULT: FAIL（+D7=5 没被装置读到：[$D7SH]）"; exit 2 ;;
esac
echo "   NEG_OK[D7]: 描述符 QUANT_SHIFT=5 != 网表展开期 6 ⇒ RTL err 且零搬运（$D7MEM；$D7CH）"

# ---------------- 9) 连跑（第二次 go）：C3.10 前置项的**运行期证据** ----------------
#   同一 DUT 实例：第一次跑完（busy 落 0）后换地址再脉冲一次 go（`+GO2`，第二张输出落 DST2）。
#   这一关是 `conv.io.prime := runStart` 的牙：把 conv 流水线的相位复位钉成 0（红证据）后，第二次 go
#   会多出一整行像素 ⇒ 计数不翻倍 / dst2 != 黄金 / 干脆挂死 ⇒ 本关必红。判据（全部一起成立）：
#     · 装置 `RESULT: PASS`（TB 内部已判：两次都跑完、无 err、busy 落 0、AR/AW/B 翻倍）；
#     · `GO_COUNT=2 BUSY_AT_GO2=0`、`RUN2_DONE=1 RUN2_ERR=0 RUN2_BUSY_AFTER=0`；
#     · 突发/字节计数两处独立对账都翻倍（装置自报 AR/AW/B + 内存模型 MEM rd/wr/bursts）；
#     · 两段 dst 区**各自**与黄金逐字节一致（`RUN1_DST_MISMATCH=RUN2_DST_MISMATCH=0`），
#       src 未改、第二个 dst 区的紧邻 32B 邻居未动（挡"越界写"）。
echo "---- 9) 连跑（+GO2）：同一实例第二次 go（第二张落 DST2=$DST2）⇒ 跑完 + busy 落 0 + 计数翻倍 + dst2 == 黄金 ----"
run_sim sim.vvp go2 "$work/wgt.hex" +GO2 \
  "+D0B=$D0" "+D1B=$D1" "+D2B=$D2" "+D3B=$D3" "+D4B=$SRC" "+D5B=$DST2" "+D6B=$D6" "+D7B=$D7"
GO2RC=$?
grep -E '^(TB UNITEXEC2|RUN2_|DONE_SEEN|RD_BYTES_PEAK|AR_BURSTS|MEM |RESULT)' "$work/go2.log" | sed 's/^/   /' || true
if [ "$GO2RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/go2.log"; then
  echo "RESULT: FAIL（连跑：第二次 go 未跑完 / busy 未落 0 / 计数没翻倍，rc=$GO2RC）⇒ C3.10 连跑前置项没关闭"
  grep -E '^(RESULT|RUN2_|DONE_SEEN|AR_BURSTS|MEM )' "$work/go2.log" || true
  exit 1
fi
GO2_RUN2="$(grep -m1 '^RUN2_DONE=' "$work/go2.log")"
case "$GO2_RUN2" in
  "RUN2_DONE=1 RUN2_ERR=0 RUN2_BUSY_AFTER=0 RUN2_CYCLES="*) : ;;
  *) echo "RESULT: FAIL（连跑 RUN2 行不符（期待 DONE=1 ERR=0 BUSY_AFTER=0）：[$GO2_RUN2]）"; exit 1 ;;
esac
GO2_GS="$(grep -m1 '^DONE_SEEN=' "$work/go2.log")"
case "$GO2_GS" in
  *"GO_COUNT=2 BUSY_AT_GO2=0") : ;;
  *) echo "RESULT: FAIL（连跑 GO_COUNT/BUSY_AT_GO2 不符（期待 GO_COUNT=2 BUSY_AT_GO2=0）：[$GO2_GS]）"; exit 1 ;;
esac
GO2_CH="$(grep -m1 '^AR_BURSTS=' "$work/go2.log")"
EXP2_CH="AR_BURSTS=$(( 2 * IN_BYTES / 128 )) AW_BURSTS=$(( 2 * IN_BYTES / 128 )) B_OK=$(( 2 * IN_BYTES / 128 ))"
if [ "$GO2_CH" != "$EXP2_CH" ]; then echo "RESULT: FAIL（连跑突发数没翻倍 got=[$GO2_CH] exp=[$EXP2_CH]）"; exit 1; fi
GO2_RDP="$(grep -m1 '^RD_BYTES_PEAK=' "$work/go2.log")"
EXP2_RDP="RD_BYTES_PEAK=$IN_BYTES WR_BYTES=$IN_BYTES"
if [ "$GO2_RDP" != "$EXP2_RDP" ]; then echo "RESULT: FAIL（连跑 RD_BYTES_PEAK/WR_BYTES 不符 got=[$GO2_RDP] exp=[$EXP2_RDP]）"; exit 1; fi
GO2_MEM="$(grep -m1 '^MEM rd=' "$work/go2.log")"
EXP2_MEM="MEM rd=$(( 2 * IN_BYTES )) wr=$(( 2 * IN_BYTES )) bursts=$(( 4 * IN_BYTES / 128 )) maxburst=16"
if [ "$GO2_MEM" != "$EXP2_MEM" ]; then echo "RESULT: FAIL（连跑内存模型计数没翻倍 got=[$GO2_MEM] exp=[$EXP2_MEM]）"; exit 1; fi
echo "   连跑交叉对账 OK：$GO2_CH / $GO2_RDP / $GO2_MEM（device 与内存模型两处独立计数都翻倍）"
# 数值：两段 dst 区各自逐字节 == 黄金；src 未改；dst2 的紧邻 32B 邻居未动。
GO2J="$( "$PY" - "$work" "$SRC" "$DST" "$DST2" "$IN_BYTES" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from cmpbytes import load_num, diffs
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
work, src, dst, dst2, ln = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
d, dx, _ = load_num(work + "/go2.dump")
g, gx, _ = load_num(work + "/gold.hex")
p, px, _ = load_num(work + "/pre.hex")
if dx or gx or px:
    print("GO2_NOTE: 非法字节 dump=%d gold=%d pre=%d（X 计为不等 ⇒ MISMATCH 会发火）" % (dx, gx, px))
m1, _ = diffs(d[dst:dst+ln], g[:ln], 0)          # run1 的输出仍 == 黄金
m2, _ = diffs(d[dst2:dst2+ln], g[:ln], 0)        # run2 的输出 == 黄金
sb, _ = diffs(d[src:src+ln], p[src:src+ln], src) # src 未被改
nb = sum(1 for j in range(32) if d[dst2-32+j] != p[dst2-32+j]) \
   + sum(1 for j in range(32) if d[dst2+ln+j] != p[dst2+ln+j])
print("RUN1_DST_MISMATCH=%d" % m1)
print("RUN2_DST_MISMATCH=%d" % m2)
print("SRC_UNCHANGED_BAD=%d" % sb)
print("DST2_NEIGHBOR32_BAD=%d" % nb)
PYEOF
)"
echo "$GO2J" | sed 's/^/   /'
for k in RUN1_DST_MISMATCH RUN2_DST_MISMATCH SRC_UNCHANGED_BAD DST2_NEIGHBOR32_BAD; do
  v="$(printf '%s\n' "$GO2J" | sed -n "s/^$k=//p" | tail -1)"
  if [ "$v" != "0" ]; then
    echo "RESULT: FAIL（连跑 region $k=$v != 0）⇒ 第二张的数值/邻居不对，C3.10 连跑前置项没关闭"; exit 1
  fi
done
echo "   NEG_OK[GO2]: 第二次 go 跑完（busy 回 0）、计数翻倍、dst2 逐字节 == 黄金（run1 dst 与 src/邻居均未动）"

# ---------------- 收口 ----------------
echo "=========================================================================="
echo "MISMATCH=$MIS"
echo "三区域 = OK（dst == 黄金逐字节；src == 预载；dst 之外（含前后 32 B）== 预载）"
echo "交叉对账 = OK（$CH / $RDP / $MEML；与装置/内存模型/期望三方相符）"
echo "几何钉死 = OK（描述符 IMG_W=$W/C_IN=$CIN/GROUP=$SGROUP == 网表自报；SHIFT_DESC=$SHIFT==RTL_SHIFT；RTL_MAXPIX=$(( W * H ))==W*H）"
echo "非退化   = OK（激活/黄金/权重非常数；dst 区预载与黄金 >=1900/2048 字节不同（'不写'必被抓住）；黄金 != 整行/整列平移）"
echo "负对照 A = OK（网表 shift 6->5：>>>5'd30->5'd29 配 <<<2'd2->2'd3 ⇒ 精确命中 >>5 预测 0 差、!= 黄金差 $AMGOLD 字节；装置仍 PASS、计数一字不变）"
echo "负对照 B = OK（权重翻 1 字节 ⇒ 精确命中翻转权重预测 0 差、!= 黄金差 $BMGOLD 字节；计数一字不变）"
echo "err 路径 = OK（SRC 非 32B 对齐 ⇒ 装置 err 且零搬运）"
echo "QUANT_SHIFT 对账 = OK（描述符 +D7=5 != 网表 6 ⇒ RTL err 且零搬运；表侧与网表侧两条负对照各管一段）"
echo "连跑 GO2 = OK（同一实例第二次 go：跑完 + busy 落 0 + $GO2_CH 翻倍 + dst2 逐字节 == 黄金 ⇒ conv.io.prime 相位复位生效；C3.10 前置关闭）"
echo "判据诊断 = OK（dump 里出现非法/'xx' 字节时先报 XBYTES=<n> + 说明，绝不再把判据打印成空白）"
echo "比较器   = OK（扰动 1 个黄金字节 ⇒ MISMATCH 恰为 1）"
echo "结构     = OK（check_dangling.py：gen/UnitExec.v 零悬空）"
echo "RESULT: PASS"
exit 0
