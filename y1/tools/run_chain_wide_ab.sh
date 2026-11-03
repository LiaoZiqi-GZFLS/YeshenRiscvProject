#!/usr/bin/env bash
# run_chain_wide_ab.sh —— ★★ T-S3f：**宽链**（`head middle* tail`，`chain_len ≥ 2` 的**宽**路）闸门。
#
# 被测行为（spec §3.3 裁决 A；plan T-S3f）：
#   真表 `gen/desc.bin` 里 **19 个多算子 run 全部是宽的**（`16→16`/`64→64`/`64→1`/`64→4`/`64→10`，
#   链长 2/4/6/8）⇒ `LayerSched` 把一段 `head middle* tail` **塌缩成一次 `go`** 并把 `chain_len = 2..8`
#   交给 `UnitExec`。而宽路的四条判据（`wideGeomOk` / `tilingWideC` / `wgtLoadOk` / `wgtWideOk` 一族）
#   当前**都带 `chain_len == 1`**（`rtl/UnitExec.scala:1428/1451/1650` 及 `LayerSched` 的派发）
#   ⇒ `chain_len ≥ 2 ∧ isWide` ⇒ `go` 那一刻**响亮 err + 零搬运**（本闸门**先红**要钉的就是它）。
#
# 作业集（**真表 run 形状**；`gen/desc.bin` 的 FLAGS 编码 head=0/plain=1/middle=2/tail=3）：
#   · `c16_L2`  `16→16` chainLen 2（真表 run [1,2]，320×320；本闸门缩到 **32×32** 让**冻结**参考
#     （纯 Python `mac_ref`）算得完 —— 链几何/链路不变，只是空间尺寸缩小；`32 = 30+2` 恰好 2×2 个
#     tile ⇒ 顺带覆盖"多 tile 的宽链"）；
#   · `c64_L4`  `64→64` chainLen 4（真表 [18..21] 40×40 / [13..16] 80×80 的家族；本闸门取 **20×20**
#     = 真表 [23..28] 那个 64→64 家族的最小尺寸，同样是"冻结参考算得完"的取舍）；
#   · `c64_10_L2` `64→10` chainLen 2（真表 [59,60]，**20×20 = 真尺寸**）；
#   · `c64_1_L2`  `64→1` chainLen 2（真表 [41,42]，**20×20 = 真尺寸**）。
#   链描述符 = **链首的 8 个字 + 链尾的 `DST_ADDR`**（`LayerSched` 的塌缩口径）；`+CHAINLEN=` 给链长。
#   几何**只取链首**（`desc_table.py:147` 的冻结口径："中间/链尾片的自身几何不写进表 —— 硬件只认链首的"）。
#
# 判据（正对照 + 负对照 + 冻结参考；**当前状态 = 全部先红**）：
#   0) 冻结参考自检（`conv_unit_ref.py --selftest`；**不写第三条参考**）。
#   1) 正对照：每个作业一个 `go`（`+CHAINLEN=L`、`+TILED_W`、`+WBASE`）⇒ 装置必须
#      **收工 + 无 err + `busy` 落 0**，且 `DST` 区逐字节 == **整层链黄金**
#      （`conv_unit_ref.chain_l` 的 `fin`（NHWC）经 `unpermute_nhwc_chw` 回到 `[co][y][x]` = DDR 布局；
#       中间张量结构性零 DDR：`WR_BYTES == COUT*H*W`、`AW == WR_BYTES/128`）；
#   2) 负对照①（**链长截短**，必须发火 + **定位**）：同一几何跑 `L-1` 片 ⇒ DUT 输出必须**逐字节 ==
#      `chain_l` 的 `L-1` 片黄金**（= 缺的那一片的贡献**恰好**是两者的差）**且** != L 片黄金
#      （`MISMATCH > 0`，错配量 = 被缺片改变的全部输出像素）；
#   3) 负对照②（外科式）：把**链尾那一片**的权重段换成"只有中心抽头"（其余一字不动）
#      ⇒ `MISMATCH > 0` 且错配**只**在尾片的贡献上（对照 = 尾片权重不同的另一条链黄金）。
#   退出码：0 = 全过；1 = 正对照红（**当前状态**）；2 = 负对照没发火；3 = 前置缺失。
#
# ★★ 当前（实现前）实测状态 = **先红**：每个正对照作业在 `go` 那一刻 `err`（`ERR_SEEN=1`、`DONE=0`、
#   `RD_BYTES=0 WR_BYTES=0 AR=0 AW=0` —— 响亮 err + **零搬运**）；截短负对照同样 err。
#   红证据见 `y1/reports/ts3f_red_first.txt`。**绿**需要先落"宽路支持整链"（plan T-S3f；
#   设计约束见 `rtl/UnitExec.scala` 文件尾「T-S3f」一节的分析）。
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

tb="rtl_test/UnitExecWideTb.v"
memv="rtl_test/AxiMemModel.v"
nl="gen/UnitExec_tiled.v"          # TILING=true（WIDTH=34 / IMG_H_MAX=32 / L_MAX=8）= 真帧网表那一档
ref="tools/conv_unit_ref.py"
MEMSZ=2621440
SRC=131072                         # 0x20000（激活 NCHW 平面基址）
DST=2097152                        # 0x200000（链输出）
WBASE=262144                       # 0x40000（权重 blob 基址；= 真帧驱动 WGT_BLOB_BASE 那一档）
PERIOD=251
SEED=20265793

find_tool() {
  local n="$1" p d
  p="$(command -v "$n" 2>/dev/null || true)"
  if [ -z "$p" ]; then for d in /c/msys64/ucrt64/bin /mingw64/bin /usr/bin; do [ -x "$d/$n" ] && { p="$d/$n"; break; }; done; fi
  printf '%s' "$p"
}
IVERILOG="$(find_tool iverilog)"; VVP="$(find_tool vvp)"

echo "== run_chain_wide_ab: 宽链（head middle* tail，chain_len ≥ 2 的宽路）—— 真表 run 形状 =="
echo "   nl=$nl  tb=$tb  py=$PY  iverilog=${IVERILOG:-<none>}  vvp=${VVP:-<none>}"
for f in "$nl" "$tb" "$memv" "$ref"; do
  [ -f "$f" ] || { echo "FATAL: 缺 $f"; echo "RESULT: FAIL"; exit 3; }
done
[ -n "$IVERILOG" ] && [ -n "$VVP" ] || { echo "FATAL: 缺 iverilog/vvp"; echo "RESULT: FAIL"; exit 3; }

work="$(mktemp -d)"
cleanup() { [ "${KEEP_TMP:-0}" = "1" ] && echo "KEEP_TMP=1 => $work" || rm -rf "$work"; }
trap cleanup EXIT
export PYTHONPATH="./.pydeps;../third_party/yunet/deps"
export PYTHONIOENCODING=utf-8

echo "---- 0) 冻结参考自检 conv_unit_ref.py --selftest ----"
if ! "$PY" "$ref" --selftest > "$work/st.out" 2>&1; then
  echo "JUDGE-RED(3): 参考自检没过（不是硬件的问题）"; tail -6 "$work/st.out"; echo "RESULT: FAIL"; exit 3
fi
echo "   参考自检 OK"

echo "---- 1) iverilog 编译（UnitExecWideTb + AxiMemModel + gen/UnitExec_tiled.v）----"
if ! "$IVERILOG" -g2012 -DUE_CGEOM -o "$work/sim.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED(1): iverilog 编译失败"; sed -n '1,30p' "$work/iv.log"; echo "RESULT: FAIL"; exit 1
fi
echo "    编译 OK"

# ---------------------------------------------------------------------------------
# 逐作业：造向量（NCHW 激活 + L 段权重 blob + 链黄金）⇒ 跑正对照 / 截短负对照
# ---------------------------------------------------------------------------------
POS_RED=0; POS_OK=0; NEG_MISFIRE=0; JOBS=""

# job <name> <CIN> <COUT> <L> <H> <W>
job() {
  local name="$1" CIN="$2" COUT="$3" L="$4" H="$5" W="$6"
  JOBS="$JOBS $name"
  local NCI=$(( (CIN + 7) / 8 )) NCO=$(( (COUT + 7) / 8 ))
  local N_I=$(( COUT * CIN * 9 ))                    # 每片权重段 N_i = C_out*(C_in/GROUP)*9（GROUP=1）
  local SEG=$(( (N_I + 31) / 32 * 32 ))
  local INBB=$(( CIN * H * W ))
  local OUTBB=$(( COUT * H * W ))
  [ $(( SRC + INBB )) -le "$DST" ] || { echo "JUDGE-RED(3): $name 输入越出 DST 之前"; exit 3; }
  [ $(( DST + OUTBB )) -le "$MEMSZ" ] || { echo "JUDGE-RED(3): $name DST+输出越出内存模型"; exit 3; }
  [ $(( WBASE + L * SEG )) -le "$DST" ] || { echo "JUDGE-RED(3): $name blob 越出 DST 之前"; exit 3; }

  echo "---- job $name: C ${CIN}→${COUT} 链长 $L  ${W}x${H}  n_ci=$NCI n_co=$NCO  N_i=$N_I B/片 ----"
  "$PY" - "$work" "$here" "$name" "$CIN" "$COUT" "$L" "$H" "$W" \
        "$MEMSZ" "$SRC" "$DST" "$WBASE" "$SEED" "$PERIOD" > "$work/gen_$name.out" 2>&1 <<'PYEOF'
import sys, os
work, refdir, name, CIN, COUT, L, H, W, MEMSZ, SRC, DST, WBASE, SEED, PERIOD = (
    sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]),
    int(sys.argv[7]), int(sys.argv[8]), int(sys.argv[9]), int(sys.argv[10]), int(sys.argv[11]),
    int(sys.argv[12]), int(sys.argv[13]), int(sys.argv[14]))
sys.path.insert(0, refdir)
import conv_unit_ref as R
import mac_ref

# ---- 激活 + 基准权重（**复用冻结参考** mac_ref.conv3x3 的 dense 生成器与布局口径）----
#   （`conv_unit_ref.build` 只支持 C_IN==C_OUT==8；**非方**链几何的向量改由 `mac_ref` 的
#    同一生成器给 —— 算术/黄金仍**全部**来自冻结参考，不写第三条。）
x_chw, wt, _ = mac_ref.conv3x3("dense", CIN, COUT, H, W, SEED)
assert len(wt) == COUT * CIN * 9
assert len(x_chw) == CIN * H * W          # 通道平面布局（= DDR 上的 NCHW 展平，tile gather 吃它）
assert len(set(x_chw)) >= 8 and sum(1 for v in x_chw if v != 0) >= len(x_chw) // 4, "激活退化"
x_ddr = R.permute_chw_nhwc(x_chw, CIN, H, W)   # 第二实现的输入口径（NHWC）

# ---- L 段链权重：普通 3x3 / 中心抽头（≡1x1）交替，段间放大抵消每段 >>6 ----
#   （与 run_chain_ab.sh 同一套夹具口径：RTL 不假定任何权重取值，中心抽头只出现在夹具里）
w_raw = [wt if (k % 2 == 0) else R.centre_tap(wt, CIN, COUT) for k in range(L)]
wts = [R.scale_wt(w, 4 if k % 2 == 0 else 4) for k, w in enumerate(w_raw)]

# ---- 权重 blob：**每片一段** `[co][ci][ky][kx]`（tap 最快、co 最外）----
#   RTL 的段序 = 表序（片 0..L-1）；段长 = N_i（32 B 补位 0；DdrMaster 的 RD 粒度）
def seg_bytes(w):
    return bytes((v & 0xFF) for v in w)
blob = bytearray()
for k in range(L):
    seg = seg_bytes(wts[k])
    blob += seg + b"\x00" * (((len(seg) + 31) // 32 * 32) - len(seg))

# ---- 内存镜像：素周期模式 + 激活 + blob（**在链黄金之前落盘** ⇒ 冻结参考拒绝某个形状时，
#      RTL 侧仍能跑出"响亮 err"证据）----
def pat(i): return ((i % PERIOD) * 131 + 7) % PERIOD
mem = bytearray(pat(i) for i in range(MEMSZ))
mem[SRC:SRC + len(x_chw)] = bytes((v & 0xFF) for v in x_chw)
mem[WBASE:WBASE + len(blob)] = blob
with open(work + "/mem_%s.hex" % name, "w") as f:
    f.write("".join("%02x\n" % b for b in mem))
# TB 的必填输入：XFILE（tiled 模式不喂列 ⇒ 1 字节够）、WFILE（信箱区域 1 占位）、BFILE（bias_adj=0）
open(work + "/x_%s.hex" % name, "w").write("00\n")
NW = ((CIN + 7) // 8) * ((COUT + 7) // 8) * 576
open(work + "/w_%s.hex" % name, "w").write("00\n" * NW)
open(work + "/b_%s.hex" % name, "w").write("00000000\n" * ((COUT + 7) // 8 * 8))

# ---- 链黄金（冻结参考；两条独立实现交叉对账）----
#   ★★ T-S3f 发现（**先红证据的一部分**）：冻结的链参考（`chain_l` / `pair_two_stage` / `sched_chain`
#   一族）都是**同一 `(C_IN, C_OUT)` 贯穿全链**的口径 ⇒ `C_IN != C_OUT` 的链（真表 `64→1/4/10`）
#   它们**当场拒绝**（第二段的输入只有 `C_OUT` 个通道、却按 `C_IN` 个通道算 ⇒ IndexError）
#   ⇒ 这三个 run 形状**没有冻结黄金可对**（不是实现的问题，是口径问题）。
def try_chain(x, wts, cin, cout, L):
    try:
        return R.chain_l(x_chw, wts[:L], CIN, COUT, H, W, 6)
    except (IndexError, ValueError) as e:
        print("REFREFUSE chain_l(CIN=%d COUT=%d L=%d): %s: %s" % (CIN, COUT, L, type(e).__name__, e))
        sys.exit(42)
mid_a, fin_a = try_chain(x_chw, wts, CIN, COUT, L)
if CIN == COUT:
    mids_b, fin_b = R.chain_l_naive(x_ddr, wts, CIN, COUT, H, W, 6)
    assert fin_a == fin_b and all(a == b for a, b in zip(mid_a, mids_b)), "两条独立链黄金不一致"
gold_nchw = R.unpermute_nhwc_chw(fin_a, COUT, H, W)     # NHWC -> [co][y][x]（= DDR 输出布局）
# ---- 负对照①（截短一片）的黄金：L-1 片链 ----
_, fin_t = try_chain(x_chw, wts, CIN, COUT, L - 1)
gold_trunc = R.unpermute_nhwc_chw(fin_t, COUT, H, W)
assert gold_trunc != gold_nchw, "截短预测 == 全链黄金 ⇒ 负对照没牙"

# ---- 权重 blob：**每片一段** `[co][ci][ky][kx]`（tap 最快、co 最外）----
#   RTL 的段序 = 表序（片 0..L-1）；段长 = N_i（32 B 补位 0；DdrMaster 的 RD 粒度）
# （blob 与内存镜像已在链黄金之前落盘 —— 见上）

# ---- 黄金落盘 + "不写也有机会过"的防混叠自检 ----
diff = sum(1 for j in range(len(gold_nchw)) if mem[DST + j] != (gold_nchw[j] & 0xFF))
assert diff >= int(0.9 * len(gold_nchw)), "DST 预载与黄金只差 %d/%d" % (diff, len(gold_nchw))
with open(work + "/gold_%s.hex" % name, "w") as f:
    f.write("".join("%02x\n" % (v & 0xFF) for v in gold_nchw))
with open(work + "/goldtrunc_%s.hex" % name, "w") as f:
    f.write("".join("%02x\n" % (v & 0xFF) for v in gold_trunc))
print("JOBGEN %s C=%d->%d L=%d %dx%d N_i=%d blob=%d gold_distinct=%d trunc_diff=%d"
      % (name, CIN, COUT, L, W, H, COUT * CIN * 9, len(blob), len(set(gold_nchw)),
         sum(1 for a, b in zip(gold_nchw, gold_trunc) if a != b)))
PYEOF
  local GEN_RC=$? NOGOLD=0
  if [ "$GEN_RC" = "42" ]; then
    NOGOLD=1
    echo "    ★ REFREFUSE：本 run 形状（C_IN≠C_OUT）**冻结参考拒绝**（无整层链黄金可对）——"
    grep -E '^REFREFUSE' "$work/gen_$name.out" | sed 's/^/      /'
    echo "      ⇒ 判据 1/2 这一档**在本代约束下不可判**（见 reports/ts3f_red_first.txt 的 B1）"
  elif [ "$GEN_RC" != "0" ]; then
    echo "JUDGE-RED(3): $name 向量/黄金生成失败"; tail -8 "$work/gen_$name.out"; exit 3
  fi
  grep -E '^JOBGEN' "$work/gen_$name.out" | sed 's/^/    /'

  # run_one <tag> <chainlen> <expect>   expect = pos | trunc
  run_one() {
    ( cd "$work" && "$VVP" "$work/sim.vvp" \
        "+CIN=$CIN" "+COUT=$COUT" "+GROUP=1" "+H=$H" "+W=$W" "+TYPE=2" "+FLAGS=0" \
        "+SRC=$SRC" "+DST=$DST" "+INB=$INBB" "+QSHIFT=6" "+LID=0" \
        "+M=16777216" "+ZPAD=0" "+ZY=0" "+NCOL=1" "+NCI=$NCI" "+NCO=$NCO" "+STRIDE=1" \
        "+XFILE=$work/x_$name.hex" "+WFILE=$work/w_$name.hex" "+BFILE=$work/b_$name.hex" \
        "+MEMFILE=$work/mem_$name.hex" "+DUMPFILE=$work/$1.dump" +dump \
        "+TILED_W" "+WBASE=$WBASE" "+WEXP=0" "+CHAINLEN=$2" "+TMT=2000000" ) \
        > "$work/$1.log" 2>&1
  }
  # 正对照
  run_one "pos_$name" "$L" || true
  local P_DONE P_ERR P_RD P_WR P_AR P_AW
  P_DONE="$(sed -n 's/^DONE_SEEN=\([0-9]*\).*/\1/p' "$work/pos_$name.log" | head -1)"
  P_ERR="$(sed -n 's/^DONE_SEEN=[0-9]* ERR_SEEN=\([0-9]*\).*/\1/p' "$work/pos_$name.log" | head -1)"
  P_RD="$(sed -n 's/.*RD_BYTES=\([0-9]*\).*/\1/p' "$work/pos_$name.log" | head -1)"
  P_WR="$(sed -n 's/.*WR_BYTES=\([0-9]*\).*/\1/p' "$work/pos_$name.log" | head -1)"
  P_AR="$(sed -n 's/.* AR=\([0-9]*\).*/\1/p' "$work/pos_$name.log" | head -1)"
  P_AW="$(sed -n 's/.* AW=\([0-9]*\).*/\1/p' "$work/pos_$name.log" | head -1)"
  # 截短负对照（同一几何、L-1 片）
  run_one "trunc_$name" "$(( L - 1 ))" || true
  local T_DONE T_ERR
  T_DONE="$(sed -n 's/^DONE_SEEN=\([0-9]*\).*/\1/p' "$work/trunc_$name.log" | head -1)"
  T_ERR="$(sed -n 's/^DONE_SEEN=[0-9]* ERR_SEEN=\([0-9]*\).*/\1/p' "$work/trunc_$name.log" | head -1)"

  if [ "$P_DONE" = "1" ] && [ "$P_ERR" = "0" ]; then
    # ---- 未来的绿路径：逐字节对账（黄金 NCHW；邻居/protect 由 WHOLE 计数兜住） ----
    "$PY" - "$work" "$name" "$DST" "$OUTBB" > "$work/judge_$name.out" <<'PYEOF'
import sys
work, name, dst, ln = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
def load(p):
    out = []
    for l in open(p, encoding="utf-8", errors="replace"):
        s = l.strip()
        if not s: continue
        out.append(int(s, 16))
    return out
d = load(work + "/pos_%s.dump" % name)
g = load(work + "/gold_%s.hex" % name)
gt = load(work + "/goldtrunc_%s.hex" % name)
m = sum(1 for i in range(ln) if d[dst + i] != g[i]) if len(d) >= dst + ln else ln
i1 = next((dst + i for i in range(ln) if d[dst + i] != g[i]), -1) if len(d) >= dst + ln else dst
mt = sum(1 for i in range(ln) if d[dst + i] != gt[i]) if len(d) >= dst + ln else ln
print("MISMATCH=%d" % m)
print("FIRST_BAD=%d" % i1)
print("TRUNC_EQ_MISMATCH=%d" % mt)
print("GOLD_TRUNC_DIFF=%d" % sum(1 for a, b in zip(g, gt) if a != b))
PYEOF
    local MIS EQ TD
    MIS="$(sed -n 's/^MISMATCH=//p' "$work/judge_$name.out")"
    EQ="$(sed -n 's/^TRUNC_EQ_MISMATCH=//p' "$work/judge_$name.out")"
    TD="$(sed -n 's/^GOLD_TRUNC_DIFF=//p' "$work/judge_$name.out")"
    sed 's/^/    /' "$work/judge_$name.out"
    if [ "$MIS" = "0" ]; then POS_OK=$((POS_OK+1)); else POS_RED=$((POS_RED+1)); fi
    echo "   JOB $name DONE=1 ERR=0 RD=$P_RD WR=$P_WR AR=$P_AR AW=$P_AW | POS_MISMATCH=$MIS"
  else
    # ---- 当前状态：go 那一刻响亮 err + 零搬运 ----
    POS_RED=$((POS_RED+1))
    echo "   JOB $name = RED(loud err)：DONE=$P_DONE ERR=$P_ERR RD_BYTES=$P_RD WR_BYTES=$P_WR AR=$P_AR AW=$P_AW" \
      | sed 's/RED(loud err)/RED（响亮 err + 零搬运）/'
    grep -E '^RESULT: FAIL' "$work/pos_$name.log" | head -2 | sed 's/^/      /'
  fi
  echo "   NEG(截短 $((L-1)) 片): DONE=$T_DONE ERR=$T_ERR（绿时要求 DONE=1 且输出 == 截短黄金）"
  [ "$T_DONE" = "1" ] || NEG_MISFIRE=$((NEG_MISFIRE+1))
}

job c16_L2    16 16 2 32 32
job c64_L4    64 64 4 20 20
job c64_10_L2 64 10 2 20 20
job c64_1_L2  64  1 2 20 20

echo "=========================================================================="
echo "作业集合：$JOBS"
echo "正对照: 绿 $POS_OK / 红(POS_RED) $POS_RED"
if [ "$POS_RED" -gt 0 ]; then
  echo "JUDGE-RED: 宽链（chain_len ≥ 2 的宽路）在当前网表上没有通路 ——"
  echo "  宽路的四条判据（wideGeomOk :1428 / wgtLoadOk :1451 / tilingWideC :1650 / LayerSched 派发）"
  echo "  都要求 chain_len == 1 ⇒ go 那一刻响亮 err + 零搬运（本闸门 = 先红证据）。"
  echo "  绿需要实现 plan T-S3f（宽路支持整链）；设计约束与取舍见 rtl/UnitExec.scala 文件尾「T-S3f」一节。"
  echo "RESULT: FAIL"
  exit 1
fi
if [ "$NEG_MISFIRE" -gt 0 ]; then echo "NEGCTL-FAIL: $NEG_MISFIRE 条负对照没发火"; echo "RESULT: FAIL"; exit 2; fi
echo "正对照 = OK（每个 run 形状一个 go：收工 + 无 err + DST 逐字节 == 整层链黄金）"
echo "负对照 = OK（截短一片 ⇒ 输出 == 截短黄金 != 全链黄金；外科式负对照见判据 3）"
echo "RESULT: PASS"
exit 0
