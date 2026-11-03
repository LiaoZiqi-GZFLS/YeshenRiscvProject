#!/usr/bin/env bash
# run_fuse_head_ab.sh —— C3.9a 融合对**头**分支的数值闸门（`UnitExec` 的 `FLAGS.bit0 == OUT_TO_DDR == 0` 路径）。
#
# 被测行为（rtl/UnitExec.scala 文件头"C3.9a 头分支"）：
#   · `FLAGS.bit0 == 0`（头）⇒ 卷积输出**不落 DDR**，而是按"一拍一个输出像素 = 一列（C 个通道）"
#     写进**片上中间 `FusionBuf`**（`fbMid`）。本闸门把 `fbMid` 的消费口（观察口）读回、与黄金逐字节对账。
#   · `FLAGS.bit0 == 1`（S2，非头）⇒ 走旧的 DDR 路径（输出 -> 片上存储 -> DDR 写）。
#
# 判据（正对照 + 负对照 + 三区域 + 交叉对账 + 非退化/防混叠前提 + 比较器自检 + 红证据 + 结构）：
#   0) **向量来源 + 非退化/防混叠前提**（python，写死在用例里；不成立就 exit 3，绝不当"通过"）：
#      · 激活来自 `tools/conv_unit_ref.py`（**复用 `mac_ref`** 的 dense 3x3 算术 + `>>6` + clamp），以 NHWC 落 `SRC`；
#        黄金（NHWC）落 `DST`（非头档的 DDR 输出）。
#      · **无 0 字节**（本用例 seed=20251261，激活 2048 字节全非 0、255 个不同取值）+ 断言非常数。
#      · 背景内存 = **素周期 251** 的模式（`((i%251)*131+7)%251`）；断言周期恰 251、与块长互素、
#        `dst` 区预载与黄金**压倒性不同**（>=1900/2048）⇒ "一个字节都没写"不可能被误判成通过。
#      · 黄金对**整行/整列平移**敏感（防"行主序喂错"被周期性图案糊住）。
#      · **中间环窗 golden**：`fbMid` 是 3 行环窗（`3*WIDTH` 字），本用例 `IMG_H=4 > 3` ⇒ 写完 4 行后
#        环里只剩**最后 3 行**（逻辑行由 `row_ptr = IMG_H mod 3` 起、按 `rd_row` 轮转）。断言环 golden 非常数、
#        且与"全 0（未触碰）"**压倒性不同**（>=1200/1536）⇒ 负对照（"中间缓冲 == 黄金就算发火"）有牙。
#   1) **正对照（头，bit0=0）**：装置 `RESULT: PASS`（头档判据：跑完 + RD 照旧 + **零 DDR 写**）；
#        · `HEAD_MODE=1`、`MID_ROWS=IMG_H`（行末 `wr_row_adv` 推了 IMG_H 次）；
#        · `MEM rd=IN_BYTES wr=0`、`AR_BURSTS=IN_BYTES/128 AW_BURSTS=0`（**结构性无 DDR 写**）；
#        · 转储的**整片内存** == 预载（三区域：src / dst / 邻居全未动）⇒ 一个字节都没写 DDR；
#        · `mid_head.hex`（观察口读回的 3 行环窗）与 `midgold.hex` **逐字节**一致（`MID_MISMATCH=0`）。
#   2) **比较器自检**：扰动环 golden 一个字节 ⇒ `MID_MISMATCH` 必须**恰好 1**（否则分不清"真的相符"与"读成空表")。
#   3) **负对照（非头，bit0=1；判据必须能发火）**：同一几何、`FLAGS.bit0=1` ⇒
#        · `MEM wr=IN_BYTES > 0` 且 `AW_BURSTS=IN_BYTES/128 > 0`（输出**确实**去了 DDR）；
#        · 三区域：`dst == gold`（S2 数值对账）、`src`/邻居未动；
#        · 观察口读回**不是**黄金（`MID_MISMATCH > 0`）且**全 0**（`MID_NONZERO=0`，中间缓冲未触碰）；
#        · `MID_ROWS=0`（头才写中间缓冲）。
#        ★ 若一个设计**忽略** `OUT_TO_DDR`（bit0=1 也照写中间缓冲），这一条的"`MID != 黄金`"就会被违反 ⇒ 见 (5)。
#   4) **红证据（负对照必须能红）**：在 **scratch 拷贝**上做**外科式**网表突变 —— 把中间缓冲的写使能
#      `assign midWrEn = (conv_y_valid && isHead);` 改成 `assign midWrEn = (conv_y_valid);`（= "忽略头位、照写中间缓冲"），
#      重编译后**只跑非头档**：装置仍 `PASS`（S2 通路未坏），但观察口读回**变成了黄金**（`MID_MISMATCH=0`）
#      ⇒ 负对照 (3) 在坏设计上**发火**。这就是"忽略 `OUT_TO_DDR` 会被本闸门打红"的原始证据。
#   5) **结构判据**：`tools/check_dangling.py` 对 `gen/UnitExec.v`（零悬空）。
#
# 退出码（与 Y1 既有闸门一致）：
#   0 = 全过（正对照环窗逐字节对账 + 结构性零 DDR 写 + 三区域干净 + 负对照发火且被红证据钉死 + 自检过）
#   1 = 对账不符 / 编译或仿真失败 / 装置未 PASS / 网表不存在
#   2 = 负对照没发火、比较器自检不过、红证据突变构造不了 ⇒ **闸门自身不可信**（橡皮图章）
#   3 = 向量/维度自检失败（用例写错，或参考自身自检没过）
#
# 装置契约（rtl_test/UnitExecTb.v + rtl_test/AxiMemModel.v + gen/UnitExec.v）：
#   +WGTFILE= +D0..+D7=<dec> +CTRL=1 +MEMFILE= +DUMPFILE=
#   +MIDREAD +MIDFILE=<file>   观察：跑完（DUT 回 IDLE）后把中间 FusionBuf 的 3 行环窗读回、逐字节写 MIDFILE
#                              （展平 [rd_row][rd_col][ci]，同步读 1 拍）。**只观察**，不改任何判据。
#   装置打印（本闸门 grep 的行）：`TB UNITEXEC: ... FLAGS=..` / `TB UNITEXEC: HEAD_DESC=.. MIDREAD=..` /
#             `RD_BYTES_PEAK=.. WR_BYTES=..` / `AR_BURSTS=.. AW_BURSTS=.. B_OK=..` /
#             `MIDDUMP rows=3 cols=.. bytes=.. file=..` / `HEAD_MODE=.. MID_ROWS=..` / `RESULT: PASS|FAIL`
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

# ---- 用例常量（几何与 run_unitexec_ab.sh 同：C_IN=C_OUT=8, W=64, H=4, GROUP=1, SHIFT=6）----
MEMSZ=2621440              # 2.5 MiB（与 AxiMemModel 的 MEMSZ 一致）
SRC=131072                 # 0x20000，32B 对齐
DST=1441792                # 0x160000，32B 对齐；非头档的输出区（与 src 不重叠）
W=64; H=4; CIN=8; COUT=8; SGROUP=1; SHIFT=6
IN_BYTES=$(( CIN * H * W ))          # 2048（= d.w6）
PERIOD=251                           # 素周期；与 128 互素 ⇒ 整块平移必被发现
SEED=20251261                        # 本用例选定的 seed：激活**无 0 字节**（见判据 0）
NROWS=3                              # 环窗档数（FusionBuf 固定 3 行）

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

echo "== run_fuse_head_ab: C3.9a 融合对**头**分支（FLAGS.bit0==0 ⇒ 输出进片上中间 FusionBuf、零 DDR 写） =="
echo "   tb  =$tb"
echo "   mem =$memv"
echo "   nl  =$nl"
echo "   ref =$ref"
echo "   py=${PY}  iverilog=${IVERILOG:-<找不到>}  vvp=${VVP:-<找不到>}"
echo "   tmp =$work"
echo "   用例 SRC=$SRC DST=$DST 几何 C_IN=$CIN C_OUT=$COUT W=$W H=$H GROUP=$SGROUP SHIFT=$SHIFT IN_BYTES=$IN_BYTES SEED=$SEED"

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

# ---------------- 1) 造激励 + 独立算黄金（含中间环窗 golden）+ 非退化/防混叠前提 ----------------
echo "---- 1) 造向量：激活/权重/黄金 + 中间环窗 golden + 内存模式（seed=$SEED，激活无 0 字节）----"
if ! "$PY" - "$work" "$here" "$MEMSZ" "$SRC" "$DST" "$CIN" "$COUT" "$W" "$H" "$SGROUP" "$SHIFT" "$PERIOD" "$SEED" <<'PYEOF'
import sys, os
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

work, refdir = sys.argv[1], sys.argv[2]
sys.path.insert(0, refdir)
import conv_unit_ref as R
import mac_ref

memsz, src, dst, CIN, COUT, W, H, GROUP, SHIFT, PERIOD, SEED = (int(x) for x in sys.argv[3:14])

# ---- 激活 / 权重 / 黄金（复用 mac_ref 的 dense 3x3 算术）----
wt, x_chw, x_ddr, y_ddr = R.build(CIN, COUT, H, W, seed=SEED, shift=SHIFT)
assert len(wt) == COUT * CIN * 9, "权重长度 %d" % len(wt)
assert len(x_ddr) == CIN * H * W and len(y_ddr) == COUT * H * W

# ---- 非退化前提 ----
assert len(set(x_ddr)) > 1, "激活是常数 ⇒ 用例没意义"
assert len(set(y_ddr)) > 1, "黄金是常数 ⇒ 判据会退化"
assert len(set(wt)) > 1, "权重是常数 ⇒ 用例没意义"

# ---- ★ 输入向量无 0 字节（本用例 seed 选定）----
assert all(v != 0 for v in x_ddr), "输入向量含 0 字节（本用例要求无 0）"
assert len(set(x_ddr)) >= 200, "输入取值太集中（distinct=%d）" % len(set(x_ddr))

# ---- 防混叠：黄金对**整行平移 / 整列平移**敏感（行主序喂错必然变值）----
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

# ---- 中间环窗 golden（fbMid 的 3 行环窗在写完 IMG_H 行之后的读回）----
#   物理槽 s（0..2）装的是"最后一个逻辑行 r < IMG_H 且 r%3==s"；row_ptr = IMG_H mod 3；
#   phys(rd_row) = (row_ptr + rd_row) mod 3。本用例 H=4 ⇒ 环里剩逻辑行 1/2/3（行 0 已被覆盖）。
_row_ptr = H % 3
def _slot_logical(s):
    cands = [r for r in range(H) if r % 3 == s]
    return cands[-1] if cands else None
mid_gold = []
for _rr in range(3):
    _slot = (_row_ptr + _rr) % 3
    _L = _slot_logical(_slot)
    for _col in range(W):
        for _ci in range(COUT):
            mid_gold.append(0 if _L is None else (y_ddr[(_L * W + _col) * COUT + _ci] & 0xFF))
assert len(mid_gold) == 3 * W * COUT, "环窗 golden 长度 %d" % len(mid_gold)
assert len(set(mid_gold)) > 1, "环窗 golden 是常数 ⇒ 判据退化"
_nz = sum(1 for v in mid_gold if v != 0)
assert _nz >= 1200, "环窗 golden 非 0 字节只有 %d/%d ⇒ '未触碰(全0)'与黄金太接近" % (_nz, len(mid_gold))

# ---- 防混叠 3：dst 区预载与黄金**压倒性不同** ⇒ "一个字节都没写"必然报大 MISMATCH ----
pre = bytes(pat(i) for i in range(memsz))
diff_pre = sum(1 for j in range(len(y_ddr)) if pre[dst + j] != (y_ddr[j] & 0xFF))
assert diff_pre >= 1900, "dst 区预载与黄金只有 %d/%d 字节不同" % (diff_pre, len(y_ddr))

# ---- 结构自检 ----
assert src % 32 == 0 and dst % 32 == 0, "地址必须 32B 对齐"
assert src + CIN * H * W <= dst or dst + COUT * H * W <= src, "src/dst 区重叠"
assert max(src + CIN * H * W, dst + COUT * H * W) <= memsz, "越出已建模内存"
assert min(src, dst) >= 128 and memsz - (dst + COUT * H * W) >= 128, "前后要留出邻居字节"

# ---- 落盘 ----
mem = bytearray(pre)
mem[src:src + len(x_ddr)] = bytes(v & 0xFF for v in x_ddr)
with open(work + "/mem.hex", "w") as f:
    f.write("".join("%02x\n" % b for b in mem))
R.dump_bytes(work + "/wgt.hex", wt)
with open(work + "/gold.hex", "w") as f:      # 非头档的 DDR 输出（NHWC）
    f.write("".join("%02x\n" % (v & 0xFF) for v in y_ddr))
with open(work + "/midgold.hex", "w") as f:   # 头档的中间环窗（观察口读回的期望）
    f.write("".join("%02x\n" % b for b in mid_gold))

# ---- 两套描述符（同几何；只差 FLAGS.bit0）----
def mk(flags):
    D = [0] * 8
    D[0] = 0x01 | (flags << 8)                    # TYPE=conv3x3, FLAGS=flags
    D[1] = W | (H << 16)
    D[2] = CIN | (COUT << 16)
    D[3] = GROUP | (1 << 8) | (1 << 12)           # GROUP, STRIDE=1, PAD=1
    D[4] = src
    D[5] = dst
    D[6] = CIN * H * W                            # IN_BYTES
    D[7] = SHIFT                                  # QUANT_SHIFT, LAYER_ID=0
    return D
Dh = mk(0)   # 头：OUT_TO_DDR=0
Dn = mk(1)   # 非头：OUT_TO_DDR=1（S2）
with open(work + "/desc_head.args", "w") as f:
    f.write(" ".join(str(x) for x in Dh))
with open(work + "/desc_nonhead.args", "w") as f:
    f.write(" ".join(str(x) for x in Dn))

print("MEMGEN bytes=%d src=%d dst=%d period=%d seed=%d" % (memsz, src, dst, PERIOD, SEED))
print("NONZERO: 激活无 0 字节（distinct=%d/255）；环窗 golden 非 0=%d/%d；dst 预载与黄金差 %d/%d"
      % (len(set(x_ddr)), _nz, len(mid_gold), diff_pre, len(y_ddr)))
print("ALIAS: 黄金 != 整行平移 且 != 整列平移；模式周期恰 %d 且与 128 互素" % PERIOD)
print("DESC head   w0=0x%08x (FLAGS.bit0=0, 头)" % (Dh[0] & 0xFFFFFFFF))
print("DESC nonhead w0=0x%08x (FLAGS.bit0=1, S2)" % (Dn[0] & 0xFFFFFFFF))
PYEOF
then
  echo "FATAL: 生成向量/黄金失败（或非退化/防混叠前提不成立）⇒ 闸门不可信"
  exit 3
fi
for f in mem.hex wgt.hex gold.hex midgold.hex desc_head.args desc_nonhead.args; do
  [ -s "$work/$f" ] || { echo "FATAL: 激励文件 $f 缺失或为空"; exit 3; }
done
read -r H0 H1 H2 H3 H4 H5 H6 H7 < "$work/desc_head.args"
read -r N0 N1 N2 N3 N4 N5 N6 N7 < "$work/desc_nonhead.args"

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
    非法记号（`xx` / 非十六进制 / 越界）记成 XBAD 并计数 —— **不抛异常**。
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

# run_sim <vvp> <logbase> <wgtfile> <d0..d7> [extra args...]
run_sim() {
  local vvp="$1" log="$2" wgt="$3"
  local d0="$4" d1="$5" d2="$6" d3="$7" d4="$8" d5="$9" d6="${10}" d7="${11}"; shift 11
  ( cd "$work" && "$VVP" "$vvp" \
      "+WGTFILE=$wgt" "+MEMFILE=$work/mem.hex" "+DUMPFILE=$work/$log.dump" +dump \
      "+D0=$d0" "+D1=$d1" "+D2=$d2" "+D3=$d3" "+D4=$d4" "+D5=$d5" "+D6=$d6" "+D7=$d7" "+CTRL=1" "$@" ) \
      > "$work/$log.log" 2>&1
  return $?
}

# judge_region <dump> <gold> -> 打印 XBYTES / MISMATCH / 三区域（src 未改；dst 之外 == 预载）
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
d, dx, dfl = load_num(dump_f)
g, gx, gfl = load_num(gold_f)
print("XBYTES=%d" % dx)
print("XBYTES_GOLD=%d" % gx)
if dx or gx:
    print("JUDGE-NOTE: 转储/黄金里有非法(未知/`xx`)字节 ⇒ dump %d 个、gold %d 个；X 按'不等于任何值'计 ⇒ MISMATCH 会发火"
          % (dx, gx))
p, px, pfl = load_num(sys.argv[1] + "/pre.hex")
if px:
    print("JUDGE-NOTE: 预载镜像 pre.hex 里也有 %d 个非法字节 ⇒ 激励文件本身坏了" % px)
if len(d) < dst + ln or len(g) < ln:
    print("JUDGE-NOTE: 长度不足（dump=%d gold=%d 需要 %d/%d）⇒ 转储被截断" % (len(d), len(g), dst + ln, ln))
k = min(ln, len(g), max(0, len(d) - dst))
m, first = diffs(d[dst:dst+k], g[:k], 0)
print("MISMATCH=%d" % m)
print("FIRST_OFF=%d" % (dst + first if first >= 0 else -1))
s_bad, _ = diffs(d[src:src+k], p[src:src+k], src)
print("SRC_UNCHANGED_BAD=%d" % s_bad)
n_bad, _ = diffs(d[:dst], p[:dst], 0)
t_bad, _ = diffs(d[dst+ln:], p[dst+ln:], dst+ln)
nb32b = sum(1 for j in range(32) if d[dst-32+j] != p[dst-32+j])
nb32a = sum(1 for j in range(32) if d[dst+ln+j] != p[dst+ln+j])
print("NEIGHBOR_BAD=%d" % (n_bad + t_bad))
print("NEIGHBOR32 before_dst=%d after_dstlen=%d" % (nb32b, nb32a))
PYEOF
}

# judge_whole <dump> <predump> -> 打印整片内存是否逐字节 == 预载（头档"零 DDR 写"的判据）
judge_whole() {
  "$PY" - "$work" "$1" "$2" "$SRC" "$DST" "$IN_BYTES" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from cmpbytes import load_num, diffs
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
d, dx, _ = load_num(sys.argv[2])
p, px, _ = load_num(sys.argv[3])
src, dst, ln = int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
print("WHOLE_XBYTES=%d WHOLE_XBYTES_PRE=%d" % (dx, px))
print("WHOLE_LEN_D=%d WHOLE_LEN_P=%d" % (len(d), len(p)))
n = min(len(d), len(p))
tot, first = diffs(d[:n], p[:n], 0)
print("WHOLE_MISMATCH=%d" % tot)
print("WHOLE_FIRST_OFF=%d" % first)
sb, _ = diffs(d[src:src+ln], p[src:src+ln], src)
db, _ = diffs(d[dst:dst+ln], p[dst:dst+ln], dst)
print("SRC_UNCHANGED_BAD=%d" % sb)
print("DST_UNCHANGED_BAD=%d" % db)
obad = 0
for j in range(n):
    if (j < dst or j >= dst + ln) and d[j] != p[j]:
        obad += 1
print("OTHER_BAD=%d" % obad)
PYEOF
}

# judge_mid <midfile> <goldfile> -> 打印 MID_MISMATCH / MID_NONZERO / 长度
judge_mid() {
  "$PY" - "$work" "$1" "$2" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from cmpbytes import load_num, diffs
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
d, dx, _ = load_num(sys.argv[2])
g, gx, _ = load_num(sys.argv[3])
print("MID_XBYTES=%d MID_XBYTES_GOLD=%d" % (dx, gx))
print("MID_LEN_D=%d MID_LEN_G=%d" % (len(d), len(g)))
n = min(len(d), len(g))
m, first = diffs(d[:n], g[:n], 0)
print("MID_MISMATCH=%d" % m)
print("MID_FIRST_OFF=%d" % first)
print("MID_NONZERO=%d" % sum(1 for v in d if v != 0))
PYEOF
}

# 预载镜像（给区域比较用）
"$PY" - "$work/mem.hex" "$work/pre.hex" <<'PYEOF'
import sys
t = [l.strip() for l in open(sys.argv[1]) if l.strip()]
open(sys.argv[2], "w").write("\n".join(t) + "\n")
PYEOF

# ---------------- 3) 正对照：头档（bit0=0）----------------
echo "---- 3) 正对照[头, bit0=0]：输出进中间 FusionBuf、零 DDR 写 ----"
run_sim sim.vvp head "$work/wgt.hex" "$H0" "$H1" "$H2" "$H3" "$H4" "$H5" "$H6" "$H7" \
  "+MIDREAD" "+MIDFILE=$work/mid_head.hex"
RC=$?
if [ "$RC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/head.log"; then
  echo "JUDGE-RED: 头档仿真未 PASS（vvp rc=$RC）"
  grep -E '^(RESULT|TB-ERROR|TBFAIL|DONE_SEEN|RD_BYTES_PEAK|AR_BURSTS|MEM )' "$work/head.log" || true
  exit 1
fi
grep -E '^(TB UNITEXEC:|DONE_SEEN|RD_BYTES_PEAK|AR_BURSTS|MIDDUMP|HEAD_MODE|MEM )' "$work/head.log" | sed 's/^/   /'

# 3a) 头档几何/自报交叉对账
EXP_GEOM="TB UNITEXEC: IMG_W=$W IMG_H=$H C_IN=$CIN C_OUT=$COUT GROUP=$SGROUP IN_BYTES=$IN_BYTES QUANT_SHIFT=$SHIFT"
GEOM="$(grep -m1 '^TB UNITEXEC: IMG_W=' "$work/head.log")"
if [ "$GEOM" != "$EXP_GEOM" ]; then
  echo "JUDGE-RED: 几何/描述符行不符"; echo "  got=$GEOM"; echo "  exp=$EXP_GEOM"; exit 1
fi
if ! grep -q '^TB UNITEXEC: HEAD_DESC=1 MIDREAD=1' "$work/head.log"; then
  echo "JUDGE-RED: 装置没把描述符识别成头档（HEAD_DESC 应为 1）"; exit 1
fi
if ! grep -q '^TB UNITEXEC: SRC='"$SRC"' DST='"$DST"' TYPE=0x01 FLAGS=0x00' "$work/head.log"; then
  echo "JUDGE-RED: 描述符字（SRC/DST/TYPE/FLAGS）与用例不符"; exit 1
fi
HM="$(grep -m1 '^HEAD_MODE=' "$work/head.log")"
EXP_HM="HEAD_MODE=1 MID_ROWS=$H"
if [ "$HM" != "$EXP_HM" ]; then
  echo "JUDGE-RED: HEAD_MODE/MID_ROWS 不符 got=[$HM] exp=[$EXP_HM]"; exit 1
fi
echo "   头档自报 OK：$GEOM / $HM"

# 3b) 字节计数交叉对账（**结构性零 DDR 写**：wr=0、AW=0）
CH="$(grep -m1 '^AR_BURSTS=' "$work/head.log")"
RDP="$(grep -m1 '^RD_BYTES_PEAK=' "$work/head.log")"
MEML="$(grep -m1 '^MEM rd=' "$work/head.log")"
EXP_CH="AR_BURSTS=$(( IN_BYTES / 128 )) AW_BURSTS=0 B_OK=0"
EXP_RDP="RD_BYTES_PEAK=$IN_BYTES WR_BYTES=0"
EXP_MEM="MEM rd=$IN_BYTES wr=0 bursts=$(( IN_BYTES / 128 )) maxburst=16"
if [ "$CH" != "$EXP_CH" ]; then echo "JUDGE-RED: 头档突发数不符（AW 必须 0）got=[$CH] exp=[$EXP_CH]"; exit 1; fi
if [ "$RDP" != "$EXP_RDP" ]; then echo "JUDGE-RED: 头档字节数不符（WR_BYTES 必须 0）got=[$RDP] exp=[$EXP_RDP]"; exit 1; fi
if [ "$MEML" != "$EXP_MEM" ]; then echo "JUDGE-RED: 头档内存模型计数不符（wr 必须 0）got=[$MEML] exp=[$EXP_MEM]"; exit 1; fi
echo "   结构性零 DDR 写 OK：$CH / $RDP / $MEML"

# 3c) 三区域：**整片内存 == 预载**（头档一个字节都不写 DDR）
judge_whole "$work/head.dump" "$work/pre.hex" > "$work/head.judge"
cat "$work/head.judge" | sed 's/^/   /'
H_MIS="$(sed -n 's/^WHOLE_MISMATCH=\([0-9]*\)$/\1/p' "$work/head.judge")"
H_SBAD="$(sed -n 's/^SRC_UNCHANGED_BAD=\([0-9]*\)$/\1/p' "$work/head.judge")"
H_DBAD="$(sed -n 's/^DST_UNCHANGED_BAD=\([0-9]*\)$/\1/p' "$work/head.judge")"
H_OBAD="$(sed -n 's/^OTHER_BAD=\([0-9]*\)$/\1/p' "$work/head.judge")"
if [ "$H_MIS" != "0" ] || [ "$H_SBAD" != "0" ] || [ "$H_DBAD" != "0" ] || [ "$H_OBAD" != "0" ]; then
  echo "JUDGE-RED: 头档 DDR 内存被改（整片应 == 预载）：WHOLE=$H_MIS SRC_BAD=$H_SBAD DST_BAD=$H_DBAD OTHER_BAD=$H_OBAD"; exit 1
fi
echo "   头档三区域 OK：整片内存 == 预载（WHOLE_MISMATCH=0；src/dst/其它全 0 差 ⇒ 零 DDR 写）"

# 3d) 数值：观察口读回的中间环窗 == 环窗 golden **逐字节**
judge_mid "$work/mid_head.hex" "$work/midgold.hex" > "$work/mid_head.judge"
cat "$work/mid_head.judge" | sed 's/^/   /'
MHMIS="$(sed -n 's/^MID_MISMATCH=\([0-9]*\)$/\1/p' "$work/mid_head.judge")"
if [ "$MHMIS" != "0" ]; then
  echo "JUDGE-RED: 头档中间缓冲 != 环窗 golden（MID_MISMATCH=$MHMIS）⇒ 头没把输出正确写进片上中间缓冲"; exit 1
fi
echo "   头档数值 OK：中间环窗（观察口读回 3*W*C=$(( NROWS * W * COUT )) 字节）逐字节 == golden（MID_MISMATCH=0）"

# ---------------- 4) 比较器自检：扰动环窗 golden 一个字节 ⇒ MID_MISMATCH 必须恰好 1 ----------------
echo "---- 4) 比较器自检：扰动环窗 golden 一个期望字节 ⇒ MID_MISMATCH 必须恰好 1 ----"
"$PY" - "$work" <<'PYEOF'
import sys
work = sys.argv[1]
t = [l.strip() for l in open(work + "/midgold.hex") if l.strip()]
i = len(t) // 2
t[i] = "%02x" % ((int(t[i], 16) ^ 0x01) & 0xFF)
open(work + "/midgold_pert.hex", "w").write("\n".join(t) + "\n")
print("CMP_SELFTEST_PERTURB idx=%d" % i)
PYEOF
judge_mid "$work/mid_head.hex" "$work/midgold_pert.hex" > "$work/mid_pert.judge"
SELF_MIS="$(sed -n 's/^MID_MISMATCH=\([0-9]*\)$/\1/p' "$work/mid_pert.judge")"
echo "   CMP_SELFTEST MID_MISMATCH=$SELF_MIS（期望恰好 1）"
if [ "$SELF_MIS" != "1" ]; then
  echo "JUDGE-RED: 比较器自检 MID_MISMATCH=$SELF_MIS != 1 ⇒ 闸门不可信"; exit 2
fi

# ---------------- 5) 负对照：非头档（bit0=1）----
#   判据（全部一起成立）：输出**确实**去了 DDR（wr>0、AW>0、dst==gold）、且**中间缓冲不是黄金**（未被触碰、全 0）。
#   ★ 这一条就是"忽略 OUT_TO_DDR"的照妖镜：坏设计在 bit0=1 下也照写中间缓冲 ⇒ MID_MISMATCH 会变 0 ⇒ 发火（见 (6)）。
echo "---- 5) 负对照[非头, bit0=1]：输出去 DDR（wr>0）且中间缓冲**不是**黄金（未触碰、全 0）----"
run_sim sim.vvp nonhead "$work/wgt.hex" "$N0" "$N1" "$N2" "$N3" "$N4" "$N5" "$N6" "$N7" \
  "+MIDREAD" "+MIDFILE=$work/mid_nonhead.hex"
NRC=$?
if [ "$NRC" -ne 0 ] || ! grep -q '^RESULT: PASS' "$work/nonhead.log"; then
  echo "JUDGE-RED: 非头档仿真未 PASS（vvp rc=$NRC）"
  grep -E '^(RESULT|TB-ERROR|DONE_SEEN|RD_BYTES_PEAK|AR_BURSTS|MEM )' "$work/nonhead.log" || true
  exit 1
fi
grep -E '^(TB UNITEXEC:|HEAD_MODE|MIDDUMP|DONE_SEEN|RD_BYTES_PEAK|AR_BURSTS|MEM )' "$work/nonhead.log" | sed 's/^/   /'
NCH="$(grep -m1 '^AR_BURSTS=' "$work/nonhead.log")"
NRDP="$(grep -m1 '^RD_BYTES_PEAK=' "$work/nonhead.log")"
NMEM="$(grep -m1 '^MEM rd=' "$work/nonhead.log")"
EXP_NCH="AR_BURSTS=$(( IN_BYTES / 128 )) AW_BURSTS=$(( IN_BYTES / 128 )) B_OK=$(( IN_BYTES / 128 ))"
EXP_NRDP="RD_BYTES_PEAK=$IN_BYTES WR_BYTES=$IN_BYTES"
EXP_NMEM="MEM rd=$IN_BYTES wr=$IN_BYTES bursts=$(( 2 * IN_BYTES / 128 )) maxburst=16"
if [ "$NCH" != "$EXP_NCH" ] || [ "$NRDP" != "$EXP_NRDP" ] || [ "$NMEM" != "$EXP_NMEM" ]; then
  echo "JUDGE-RED: 非头档计数不符（应照旧走 S2：wr>0）"; echo "  ch=[$NCH] rdp=[$NRDP] mem=[$NMEM]"; exit 1
fi
NHM="$(grep -m1 '^HEAD_MODE=' "$work/nonhead.log")"
if [ "$NHM" != "HEAD_MODE=0 MID_ROWS=0" ]; then
  echo "JUDGE-RED: 非头档 HEAD_MODE/MID_ROWS 不符（应 0/0：头才写中间缓冲）got=[$NHM]"; exit 1
fi
if ! grep -q '^TB UNITEXEC: HEAD_DESC=0 MIDREAD=1' "$work/nonhead.log"; then
  echo "JUDGE-RED: 装置没把描述符识别成非头档（HEAD_DESC 应为 0）"; exit 1
fi
echo "   非头档结构性对账 OK：输出去了 DDR（$NCH / $NRDP / $NMEM）且 $NHM"

# 5a) 非头档三区域：dst == gold、src 未改、邻居未动
judge_region "$work/nonhead.dump" "$work/gold.hex" nonhead > "$work/nonhead.judge"
cat "$work/nonhead.judge" | sed 's/^/   /'
N_MIS="$(sed -n 's/^MISMATCH=\([0-9]*\)$/\1/p' "$work/nonhead.judge")"
N_SBAD="$(sed -n 's/^SRC_UNCHANGED_BAD=\([0-9]*\)$/\1/p' "$work/nonhead.judge")"
N_NBAD="$(sed -n 's/^NEIGHBOR_BAD=\([0-9]*\)$/\1/p' "$work/nonhead.judge")"
if [ "$N_MIS" != "0" ] || [ "$N_SBAD" != "0" ] || [ "$N_NBAD" != "0" ]; then
  echo "JUDGE-RED: 非头档三区域不对：MISMATCH=$N_MIS SRC_BAD=$N_SBAD NEIGHBOR_BAD=$N_NBAD"; exit 1
fi
echo "   非头档三区域 OK：dst 区逐字节 == 黄金；src 未改；邻居未动"

# 5b) **负对照判据**：中间缓冲**不是**黄金（未触碰 ⇒ 全 0）
judge_mid "$work/mid_nonhead.hex" "$work/midgold.hex" > "$work/mid_nonhead.judge"
cat "$work/mid_nonhead.judge" | sed 's/^/   /'
NN_MIS="$(sed -n 's/^MID_MISMATCH=\([0-9]*\)$/\1/p' "$work/mid_nonhead.judge")"
NN_NZ="$(sed -n 's/^MID_NONZERO=\([0-9]*\)$/\1/p' "$work/mid_nonhead.judge")"
if ! [ "$NN_MIS" -gt 0 ] 2>/dev/null; then
  echo "JUDGE-RED: 负对照没发火：非头档中间缓冲竟然 == 黄金（MID_MISMATCH=$NN_MIS）"; exit 2
fi
if [ "$NN_NZ" != "0" ]; then
  echo "JUDGE-RED: 负对照不干净：非头档中间缓冲被写了（MID_NONZERO=$NN_NZ，应为 0=未触碰）"; exit 2
fi
echo "   NEG_OK[nonhead]: bit0=1 ⇒ 输出去 DDR（wr>0）、中间缓冲**不是**黄金且未触碰（MID_MISMATCH=$NN_MIS MID_NONZERO=$NN_NZ）"

# ---------------- 6) 红证据：忽略 OUT_TO_DDR（外科式突变）⇒ 负对照 (5b) 必须发火 ----------------
#   在 **scratch 拷贝**上把中间缓冲的写使能 `(conv_y_valid && isHead)` 改成 `(conv_y_valid)`
#   （= "忽略头位、照写中间缓冲" 这一类坏设计的**最小复现**）。重编译后**只跑非头档**：
#   S2 通路未坏（装置仍 PASS），但中间缓冲**变成了黄金** ⇒ 负对照的 `MID_MISMATCH>0` 被违反。
#   ★ 突变编不过 / 命中数 != 1 / 负对照没发火 ⇒ 本闸门自身不可信（exit 2），绝不当"通过"。
echo "---- 6) 红证据[忽略 OUT_TO_DDR]：scratch 突变 midWrEn 去掉 isHead 门控 ⇒ 负对照必须发火 ----"
if ! "$PY" - "$nl" "$work/UnitExec_mutmid.v" > "$work/mutmid.out" 2>&1 <<'PYEOF'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
src = open(sys.argv[1], encoding="utf-8").read()
new, n = re.subn(r"assign midWrEn = \(conv_y_valid && isHead\);",
                 "assign midWrEn = (conv_y_valid);", src)
print("MUTGEN_HITS=%d (期望 1)" % n)
if n != 1:
    sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(new)
PYEOF
then
  echo "JUDGE-RED: 构造 midWrEn 突变网表失败（生成风格变了）⇒ 闸门不可信"; cat "$work/mutmid.out"; exit 2
fi
cat "$work/mutmid.out"
if cmp -s "$nl" "$work/UnitExec_mutmid.v"; then echo "JUDGE-RED: 突变网表与原文相同 ⇒ 闸门不可信"; exit 2; fi
if ! "$IVERILOG" -g2012 -o "$work/mutmid.vvp" "$tb" "$memv" "$work/UnitExec_mutmid.v" > "$work/iv_mutmid.log" 2>&1; then
  echo "JUDGE-RED: 突变网表编译失败"; sed -n '1,20p' "$work/iv_mutmid.log"; exit 2
fi
run_sim mutmid.vvp mutmid "$work/wgt.hex" "$N0" "$N1" "$N2" "$N3" "$N4" "$N5" "$N6" "$N7" \
  "+MIDREAD" "+MIDFILE=$work/mid_mutmid.hex"
if ! grep -q '^RESULT: PASS' "$work/mutmid.log"; then
  echo "JUDGE-RED: 突变下装置未 PASS（突变把 S2 通路也改坏了 ⇒ 红证据不干净）"
  grep -E '^(RESULT|DONE_SEEN|RD_BYTES_PEAK|MEM )' "$work/mutmid.log" || true; exit 2
fi
MM_MEM="$(grep -m1 '^MEM rd=' "$work/mutmid.log")"
if [ "$MM_MEM" != "$EXP_NMEM" ]; then
  echo "JUDGE-RED: 突变把 DDR 计数也改了（红证据不干净）got=[$MM_MEM]"; exit 2
fi
echo "   （突变下 S2 通路完好：装置仍 PASS、$MM_MEM）"
judge_mid "$work/mid_mutmid.hex" "$work/midgold.hex" > "$work/mid_mutmid.judge"
cat "$work/mid_mutmid.judge" | sed 's/^/   /'
MM_MIS="$(sed -n 's/^MID_MISMATCH=\([0-9]*\)$/\1/p' "$work/mid_mutmid.judge")"
if [ "$MM_MIS" != "0" ]; then
  echo "JUDGE-RED: 红证据失败：忽略头位的坏设计下，非头档中间缓冲仍 != 黄金（MID_MISMATCH=$MM_MIS）⇒ 负对照 (5b) 没有牙"; exit 2
fi
echo "   JUDGE-RED[negative]（这就是负对照的牙）：bit0=1 但中间缓冲**变成了黄金**（MID_MISMATCH=0）"
echo "   = '忽略 OUT_TO_DDR' 的设计会被负对照 (5b) 打红 ⇒ 红证据成立"

# ---------------- 收口 ----------------
echo "=========================================================================="
echo "正对照头档 = OK（BURST $CH / $RDP / $MEML；整片内存 == 预载；中间环窗逐字节 == golden）"
echo "中间缓冲   = OK（观察口读回 3*W*C=$(( NROWS * W * COUT )) 字节，MID_MISMATCH=0；MID_ROWS=$H）"
echo "非退化     = OK（激活无 0 字节、distinct>=200；黄金 != 整行/整列平移；dst 预载与黄金 >=1900/2048 字节不同）"
echo "负对照     = OK（bit0=1 ⇒ 输出去 DDR（wr>0）且中间缓冲 != 黄金、未触碰：MID_MISMATCH=$NN_MIS MID_NONZERO=$NN_NZ）"
echo "红证据     = OK（scratch 突变去掉 midWrEn 的 isHead 门控 ⇒ 非头档中间缓冲 == 黄金 ⇒ 负对照发火）"
echo "比较器     = OK（扰动 1 个环窗 golden 字节 ⇒ MID_MISMATCH 恰为 1）"
echo "结构       = OK（check_dangling.py：gen/UnitExec.v 零悬空）"
echo "RESULT: PASS"
exit 0
