#!/usr/bin/env bash
# run_tiling2d_wide_ab.sh —— ★★ T-S2b：**宽通路 2-D tile 循环**（平面 NCHW 行跨步 halo gather +
#   每 tile 多趟重跑）的逐字节闸门。
#
# 被测：`rtl/UnitExec.scala`（`TILING=true`）⇒ `gen/UnitExec_tiled.v`（`WIDTH=34 / IMG_H_MAX=32 /
#   L_MAX=8`）的**宽路 tile 循环**（`tilingWideC` ⇒ `tilingW`：gather 走 DDR 平面读、WR 走 wstrb 掩码）。
#   装置 `rtl_test/UnitExecWideTb.v`（`+TILED_W`，激活由 DDR gather 取、装置不喂列）+ `AxiMemModel.v`。
#
# 判据（spec §5 T2 / §7 S2b）：
#   0) **前置**：冻结参考自检（`tiling_ref.py --selftest2d`）。
#   1) **正对照（整层逐字节）**：把**整层平面激活**（NCHW）喂进 DDR 的 `SRC` 区，RTL 内部按
#      `W_TILE=(WIDTH-2)/s × H_TILE=IMG_H_MAX` 的 2-D tile 网格跑（每个 tile 内重跑 `nCi×nCo` 趟，
#      跨 tile 的部分和清零重来）⇒ `DST` 区必须与**整层黄金**逐字节一致。
#      **黄金/权重瓦片 = 冻结参考复用**（`tools/tiling_ref.py` 的 `conv_tiled` + `tools/multipass_ref.py`
#      的 `weight_tiles`/`bias_of`）—— **不写第三条参考**。
#      **真表宽几何**（`gen/wgt_index.json`）覆盖：`C=1`（`Conv_55` 80×80）、`C=4`（`Conv_61` 40×40）、
#      `C=16`（`Conv_3` 160×160）、`C=64`（`Conv_27` 40×40）、**depthwise**（`GROUP=C_in=C_out`；16/64）
#      + `Conv_0` 的 `s=2`（3→16，非对称 halo）。
#      ★★ T-S3b：真表 **`20×20`**（`HW=400`，**`HW%32≠0`**）—— dense `C=64`（`Conv_33/36/39`）与
#      `C=10` depthwise（`Conv_77` 族：`GROUP=C_in=C_out=10`）⇒ 覆盖"平面 band 边界不重合"这条。
#   2) **负对照①（必发火 + 定位）**：网表突变 `tNtx-1 -> tNtx-2`（漏最后一列 tile）⇒ `MISMATCH>0`
#      且错配点**全部落在被漏掉的 tile 列带**里。
#   3) **负对照②（必发火 + 分类）**：网表突变 `tWinLo+1 / tWinHi-1`（**不给 halo**）⇒ 错点**只在
#      tile 接缝列**（错列数 ≤ 8）而 tile 内部全对。
#   4) **负对照③（必发火 + 双侧，T-S3b）**：网表突变把 EMIT 的 **per-plane 索引退回共享 plane-0**
#      （`wxPIDX_k[` -> `wxPIDX_0[`）⇒ 在 `HW%32≠0` 的 `20×20` 上**必红**，在 `HW%32==0` 的 `40×40` 上
#      **不提**（各平面低 5 位相同 ⇒ 共享索引本来就对）。**两侧都要断言**。
#
# ★★ T-S2b-i（本闸门的两处**接线/坐标**修正，判据阈值与两条突变**一字未动**）：
#   ① **每作业一份内存镜像**：原实现把 `mem.hex`/`pre.hex` 写在共享 `$work` 上、每作业生成时覆写 ⇒
#      循环结束后共享镜像只剩**最后一个作业**（`s2_3x16`）。正对照"生成后立刻跑"不受影响（故此前看不见），
#      但两条负对照在循环**之后**跑（用 `c4_40x40` 的 gold + `s2_3x16` 的激活）⇒ 测的是"输入根本不对"
#      （实测漏趟负对照 MISMATCH=6358、错列铺满 0..39）而非注入的故障。⇒ 改成 `$work/<name>/{mem,pre}.hex`。
#   ② **错配列号用冻结布局**：判据取"错点在哪些**输出列**"，原式 `(k // Co) % W` 是"通道交错 `[y][x][co]`"
#      的列号；而黄金与网表写回都是 **NCHW 平面 `[co][y][x]`**（正对照逐字节 ACK 即证）⇒ 改成 `k % W`。
#      原式把真被漏掉的列带 `x∈[32,39]` 映射成 `{8,9,18,19,28,29,38,39}`（`XMIN=8`）⇒ 该断言**恒假**。
#
# 开口项（★ 本闸门**不做**、明写）：PnR / 板级（S3）。
#
# ★★ T-S3b：`HW = inH·inW` **非** 32 整数倍的真层（真表 `20×20`，`HW=400`）**已支持** —— gather 改成
#   **每平面各自的 `(bandBase, idxW, idxB)`**（`tilingWideC` 去掉 `HW%32==0` 前提，其余前提一字未动）；
#   band 基址仍 `& ~31`（突发合法），FETCH **只重取 band 真的变了的平面**（不把读流量乘以 8）。
#   负对照③（EMIT 索引退回共享 plane-0）在 `20×20` 上必红、`40×40` 上不提（见上）。
#
# 退出码：0 = 全过 / 1 = 判据红 / 2 = 负对照没发火 / 3 = 前置缺失。
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.." || { echo "FATAL: 进不去 y1/"; echo "RESULT: FAIL"; exit 3; }

PY="${PY:-/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe}"
[ -x "$PY" ] || PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "FATAL: 找不到 python"; echo "RESULT: FAIL"; exit 3; }

tb="rtl_test/UnitExecWideTb.v"
memv="rtl_test/AxiMemModel.v"
nl="gen/UnitExec_tiled.v"
ref="tools/tiling_ref.py"
mpref="tools/multipass_ref.py"
MEMSZ=2621440
SRC=131072          # 0x20000
DST=2097152         # 0x200000
tools_abs="$(pwd)/tools"

find_tool() {
  local n="$1" p d
  p="$(command -v "$n" 2>/dev/null || true)"
  if [ -z "$p" ]; then for d in /c/msys64/ucrt64/bin /mingw64/bin /usr/bin; do [ -x "$d/$n" ] && { p="$d/$n"; break; }; done; fi
  printf '%s' "$p"
}
IVERILOG="$(find_tool iverilog)"; VVP="$(find_tool vvp)"

echo "== run_tiling2d_wide_ab: 宽通路 2-D tile 循环（平面 halo gather + 每 tile 多趟）整层逐字节对账 =="
echo "   nl=$nl  tb=$tb  py=$PY  iverilog=${IVERILOG:-<none>}"

for f in "$nl" "$tb" "$memv" "$ref" "$mpref"; do
  [ -f "$f" ] || { echo "FATAL: 缺 $f"; echo "RESULT: FAIL"; exit 3; }
done
[ -n "$IVERILOG" ] && [ -n "$VVP" ] || { echo "FATAL: 缺 iverilog/vvp"; echo "RESULT: FAIL"; exit 3; }

work="$(mktemp -d)"
cleanup() { [ "${KEEP_TMP:-0}" = "1" ] && echo "KEEP_TMP=1 => $work" || rm -rf "$work"; }
trap cleanup EXIT
export PYTHONPATH="./.pydeps;../third_party/yunet/deps"
export PYTHONIOENCODING=utf-8

echo "---- 0) 冻结参考自检 tiling_ref.py --selftest2d ----"
"$PY" "$ref" --selftest2d >/dev/null 2>&1 || { echo "RESULT: FAIL 参考自检没过"; exit 3; }
echo "   参考自检 OK"

echo "---- 1) iverilog 编译（UnitExecWideTb + AxiMemModel + gen/UnitExec_tiled.v）----"
if ! "$IVERILOG" -g2012 -DUE_CGEOM -o "$work/sim.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败"; sed -n '1,30p' "$work/iv.log"; echo "RESULT: FAIL"; exit 1
fi
echo "   编译 OK"

# -----------------------------------------------------------------------------
# 作业生成器（复用冻结参考的算术；只做布局/落盘）
# -----------------------------------------------------------------------------
cat > "$work/genjob.py" <<'PYEOF'
import sys, os
sys.path.insert(0, sys.argv[1])
import numpy as np
import tiling_ref as T
import multipass_ref as MP

Z_Y = -7

def make(cin, cout, gg, H, W, s, seed):
    rng = np.random.default_rng(seed)
    Hin, Win = H * s, W * s
    xq = rng.integers(-20, 21, size=(1, cin, Hin, Win), dtype=np.int64)          # (1,ci,Hin,Win)
    cig = cin // gg
    wq = rng.integers(-20, 21, size=(cout, cig, 3, 3), dtype=np.int64)           # (co,cig,3,3)
    sx = sw = sy = 0.05
    bfloat = rng.uniform(-0.5, 0.5, size=cout)
    biasb = np.round(bfloat / (sx * sw)).astype(np.int64)
    wd = {"q": wq.astype(np.int8), "scale": sw, "zp": 0}
    pads, strides = [1, 1, 1, 1], [s, s]
    tiled, acc_full, parts, M = T.conv_tiled(xq, wd, sx, sy, 0, 0, bfloat, pads, strides, gg, Z_Y,
                                             dump_passes=True)
    gold = tiled.reshape(-1).astype(np.int8)      # [co][y][x] 整层黄金
    tiles = MP.weight_tiles(xq, wd, gg)           # 趟序（co-block 外、ci-block 内）每趟 576 B
    n_co = (cout + 7) // 8
    btoks = []
    for j in range(n_co):
        btoks += [int(v) for v in MP.bias_of(biasb, j)]
    xin = xq[0].reshape(-1).astype(np.int8)       # NCHW 平面 [c][y][x]（gather 的真源）
    n_ci = T.n_passes(cin); n_co = T.n_passes(cout)
    return dict(gold=gold, tiles=np.concatenate([t.reshape(-1) for t in tiles]),
                b=np.asarray(btoks, dtype=np.int64), M=int(M), xin=xin,
                n_ci=int(n_ci), n_co=int(n_co), distinct=len(set(int(v) for v in gold)))

def dump(path, toks, w=2):
    m = (1 << (4 * w)) - 1
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("".join(("%0" + str(w) + "x\n") % (int(t) & m) for t in toks))

def main():
    tools, work, name = sys.argv[1], sys.argv[2], sys.argv[3]
    cin, cout, gg, H, W, s = (int(x) for x in sys.argv[4:10])
    seed = int(sys.argv[10]); src = int(sys.argv[11]); dst = int(sys.argv[12]); memsz = int(sys.argv[13])
    r = make(cin, cout, gg, H, W, s, seed)
    d = os.path.join(work, name); os.makedirs(d, exist_ok=True)
    dump(os.path.join(d, "w.hex"), r["tiles"])
    dump(os.path.join(d, "b.hex"), r["b"], w=8)
    dump(os.path.join(d, "gold.hex"), r["gold"])
    dump(os.path.join(d, "x.hex"), np.zeros(8, dtype=np.int64))   # 占位（tiled_w 不喂列流）
    # 内存镜像：背景 + SRC 覆盖平面激活；DST 区背景与黄金不同（"不写"必被抓）
    pre = np.array([((i % 251) * 131 + 7) % 251 for i in range(memsz)], dtype=np.int64)
    dif = int(np.count_nonzero(pre[dst:dst + len(r["gold"])] != r["gold"]))
    assert dif >= int(len(r["gold"]) * 0.9), "dst 预载与黄金只差 %d/%d" % (dif, len(r["gold"]))
    mem = pre.copy()
    ex = src + len(r["xin"])
    assert ex <= dst or dst + len(r["gold"]) <= src, "src/dst 重叠"
    assert max(ex, dst + len(r["gold"])) <= memsz - 64, "越界"
    mem[src:ex] = r["xin"]
    # ★ T-S2b-i（闸门接线修）：内存镜像/背景**按作业落各自目录**。
    #   原实现把 `mem.hex`/`pre.hex` 写在**共享的 `$work`** 上，而每个作业生成时都会覆写它 ⇒
    #   循环结束后共享 `mem.hex` 里只剩**最后一个作业**（`s2_3x16`）的镜像。
    #   正对照是"生成后立刻跑" ⇒ 不受影响（所以此前看不出问题）；但两条**负对照**在循环之后才跑，
    #   用的是 `c4_40x40` 的 job.txt / gold + `s2_3x16` 的**激活镜像** ⇒ 判据测的是"输入根本不对"，
    #   而不是"被注入的故障"（实测：漏趟负对照 MISMATCH=6358、错列铺满 0..39）。
    #   修法：每个作业一份 `$work/<name>/{mem,pre}.hex`，`run_pos`/两条负对照/`judge_dst` 各取自己那份。
    dump(os.path.join(d, "mem.hex"), mem)
    dump(os.path.join(d, "pre.hex"), pre)
    with open(os.path.join(d, "job.txt"), "w", encoding="ascii", newline="\n") as f:
        f.write("CIN=%d\nCOUT=%d\nGROUP=%d\nH=%d\nW=%d\nS=%d\n" % (cin, cout, gg, H, W, s))
        f.write("SRC=%d\nDST=%d\nM=%d\nZPAD=0\nZY=%d\nNCI=%d\nNCO=%d\nLEN=%d\nDISTINCT=%d\n"
                % (src, dst, r["M"], Z_Y, r["n_ci"], r["n_co"], len(r["gold"]), r["distinct"]))
    print("JOBGEN %s CIN=%d COUT=%d GROUP=%d %dx%d s=%d n_ci=%d n_co=%d M=%d distinct=%d len=%d in=%d"
          % (name, cin, cout, gg, H, W, s, r["n_ci"], r["n_co"], r["M"], r["distinct"], len(r["gold"]), len(r["xin"])))

main()
PYEOF

TOTAL_BAD=0; NEG_NOFIRE=0; JOBS=""

# run_pos <name>  -> 跑一次（用 job.txt 里的几何）；装置必须 PASS
run_pos() {
  local name="$1"
  eval "$(sed 's/^/X_/' "$work/$name/job.txt" | tr '\n' ' ')"
  ( cd "$work" && "$VVP" "$work/sim.vvp" \
      "+XFILE=$work/$name/x.hex" "+WFILE=$work/$name/w.hex" "+BFILE=$work/$name/b.hex" \
      "+MEMFILE=$work/$name/mem.hex" "+DUMPFILE=$work/$name.dump" +dump +TILED_W \
      "+CIN=${X_CIN}" "+COUT=${X_COUT}" "+GROUP=${X_GROUP}" "+H=${X_H}" "+W=${X_W}" "+TYPE=1" "+FLAGS=1" \
      "+SRC=${X_SRC}" "+DST=${X_DST}" "+INB=${X_LEN}" "+QSHIFT=6" "+LID=0" \
      "+M=${X_M}" "+ZPAD=${X_ZPAD}" "+ZY=${X_ZY}" "+NCOL=1" "+NCI=${X_NCI}" "+NCO=${X_NCO}" "+STRIDE=${X_S}" ) \
      > "$work/$name.log" 2>&1
  if ! grep -q '^RESULT: PASS' "$work/$name.log"; then
    echo "JUDGE-RED: 装置未 PASS（$name）"; grep -E '^(TB WIDE|RESULT|TILED_W)' "$work/$name.log" | tail -6
    TOTAL_BAD=$((TOTAL_BAD+1)); return 1
  fi
  grep -E '^(TB WIDE|RESULT|TILED_W|DBG|TB TILED_W_EN)' "$work/$name.log" | sed "s/^/    [$name] /"
}

# judge_dst <work> <name> <dst> <len>  -> 逐字节对账（DST vs 整层黄金；邻居 vs 背景）
judge_dst() {
  local work="$1" name="$2" dst="$3" ln="$4"
  "$PY" - "$work" "$name" "$dst" "$ln" <<'PYEOF'
import sys
def load(p):
    out = []
    for l in open(p, encoding="utf-8", errors="replace"):
        s = l.strip()
        if not s: continue
        try: out.append(int(s, 16) & 0xFF)
        except ValueError: out.append(-1)
    return out
work, name, dst, ln = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
d = load(work + "/" + name + ".dump"); g = load(work + "/" + name + "/gold.hex")
p = load(work + "/" + name + "/pre.hex")
k = min(ln, len(g), max(0, len(d) - dst))
mm = sum(1 for i in range(k) if d[dst+i] != g[i]) + max(0, ln - k)
nb = sum(1 for j in range(32) if d[dst-32+j] != p[dst-32+j]) if dst >= 32 else 0
nb += sum(1 for j in range(32) if d[dst+k+j] != p[dst+k+j]) if dst+k+32 <= len(d) else 0
print("MISMATCH=%d NEIGHBOR_BAD=%d" % (mm, nb))
PYEOF
}

# 生成 + 跑一个作业
# job <name> <cin> <cout> <group> <H> <W> <s> <seed>
job() {
  local name="$1" cin="$2" cout="$3" gg="$4" H="$5" W="$6" s="$7" seed="$8"
  echo "---- job $name: C_in=$cin C_out=$cout GROUP=$gg 输出 ${W}x${H} s=$s ----"
  if ! "$PY" "$work/genjob.py" "$tools_abs" "$work" "$name" "$cin" "$cout" "$gg" "$H" "$W" "$s" "$seed" "$SRC" "$DST" "$MEMSZ" > "$work/$name.gen" 2>&1; then
    echo "RESULT: FAIL 供料失败（$name）"; tail -8 "$work/$name.gen"; exit 3
  fi
  grep -E '^JOBGEN' "$work/$name.gen" | sed 's/^/    /'
  JOBS="$JOBS $name"
  run_pos "$name"
}

# -----------------------------------------------------------------------------
# 正对照（真表宽几何）
# -----------------------------------------------------------------------------
echo "=========================================================================="
echo "正对照：真表宽几何（C=1/4/16/64 + depthwise + Conv_0 s=2 + T-S3b 的 20×20），整层 tile 拼接 == 整层逐字节"
job c1_80x80   1  1  1  80  80  1 101
job c4_40x40   4  4  1  40  40  1 102
job c16_160x160 16 16 1 160 160 1 103
job c64_40x40  64 64  1  40  40  1 104
job dw16_80x80 16 16 16  80  80  1 105
job dw64_40x40 64 64 64  40  40  1 106
job s2_3x16    3  16  1  64  64  2 107
# ★★ T-S3b：真表 `20×20`（`HW=400`，`HW%32≠0`）—— dense `C=64` + `C=10` depthwise（band 边界不重合）
job c64_20x20  64  64  1  20  20  1 108
job dw10_20x20 10  10 10  20  20  1 109

pos_ok=0
for nm in $JOBS; do
  ln="$(sed -n 's/^LEN=//p' "$work/$nm/job.txt")"
  J="$(judge_dst "$work" "$nm" "$DST" "$ln")"
  mm="$(printf '%s\n' "$J" | sed -n 's/^MISMATCH=\([0-9]*\).*/\1/p')"
  nb="$(printf '%s\n' "$J" | sed -n 's/.*NEIGHBOR_BAD=\([0-9]*\).*/\1/p')"
  if [ "$mm" != "0" ] || [ "$nb" != "0" ]; then
    echo "JUDGE-RED: $nm 正对照 MISMATCH=$mm NEIGHBOR_BAD=$nb"; TOTAL_BAD=$((TOTAL_BAD+1))
  else
    pos_ok=$((pos_ok+1))
    echo "   OK: $nm DST == 整层黄金（MISMATCH=0，邻居未动）"
  fi
done
echo "   正对照通过 $pos_ok 例"

if [ "$TOTAL_BAD" -ne 0 ]; then echo "RESULT: FAIL 正对照有红"; exit 1; fi

# -----------------------------------------------------------------------------
# 负对照①：漏一趟（tNtx-1 -> tNtx-2）
# -----------------------------------------------------------------------------
NEGJOB=c4_40x40
echo "---- 负对照①：tNtx-1 -> tNtx-2（漏最后一列 tile）⇒ MISMATCH>0 且定位在漏掉的列带 ----"
if ! "$PY" - "$nl" "$work/nl_mut.v" <<'PYEOF'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = "(tNtx - 16'h0001)"; new = "(tNtx - 16'h0002)"
n = src.count(old)
print("MUTGEN_HITS=%d (期望 >=1)" % n)
if n < 1: sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PYEOF
then echo "RESULT: FAIL 无法构造漏趟突变网表"; exit 2; fi
"$IVERILOG" -g2012 -DUE_CGEOM -o "$work/sim_mut.vvp" "$tb" "$memv" "$work/nl_mut.v" > "$work/ivm.log" 2>&1 || { echo "RESULT: FAIL 突变网表编译失败"; exit 2; }
eval "$(sed 's/^/X_/' "$work/$NEGJOB/job.txt" | tr '\n' ' ')"
( cd "$work" && "$VVP" "$work/sim_mut.vvp" \
    "+XFILE=$work/$NEGJOB/x.hex" "+WFILE=$work/$NEGJOB/w.hex" "+BFILE=$work/$NEGJOB/b.hex" \
    "+MEMFILE=$work/$NEGJOB/mem.hex" "+DUMPFILE=$work/mut.dump" +dump +TILED_W \
    "+CIN=${X_CIN}" "+COUT=${X_COUT}" "+GROUP=${X_GROUP}" "+H=${X_H}" "+W=${X_W}" "+TYPE=1" "+FLAGS=1" \
    "+SRC=${X_SRC}" "+DST=${X_DST}" "+INB=${X_LEN}" "+QSHIFT=6" "+LID=0" \
    "+M=${X_M}" "+ZPAD=${X_ZPAD}" "+ZY=${X_ZY}" "+NCOL=1" "+NCI=${X_NCI}" "+NCO=${X_NCO}" "+STRIDE=${X_S}" ) \
    > "$work/mut.log" 2>&1
grep -q '^RESULT: PASS' "$work/mut.log" || { echo "RESULT: FAIL 突变网表装置未收工"; grep -E '^(RESULT|TILED_W)' "$work/mut.log"|head; exit 2; }
MUT="$("$PY" - "$work" "$NEGJOB" "$DST" "${X_W}" "${X_COUT}" <<'PYEOF'
import sys
def load(p):
    out = []
    for l in open(p, encoding="utf-8", errors="replace"):
        s = l.strip()
        if not s: continue
        try: out.append(int(s, 16) & 0xFF)
        except ValueError: out.append(-1)
    return out
work, nj, dst, W, Co = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
d = load(work + "/mut.dump"); g = load(work + "/" + nj + "/gold.hex")
ln = len(g); m = 0; badx = set()
for k in range(ln):
    if d[dst+k] != g[k]:
        # ★ T-S2b-i：错配**列**= 冻结输出布局 `[co][y][x]`（NCHW 平面）里的 `k % W`。
        #   原式 `(k // Co) % W` 是"通道交错 `[y][x][co]`"布局的列号 —— 与黄金/网表布局不符：
        #   真被漏掉的列带 `x∈[32,39]` 经原式被映射成 `{8,9,18,19,28,29,38,39}` ⇒ XMIN=8 假红。
        m += 1; badx.add(k % W)
print("MUT_MISMATCH=%d NBADX=%d XMIN=%d XMAX=%d" % (m, len(badx), min(badx) if badx else -1, max(badx) if badx else -1))
PYEOF
)"
echo "   $MUT"
MM="$(printf '%s\n' "$MUT" | sed -n 's/^MUT_MISMATCH=\([0-9]*\).*/\1/p')"
XMIN="$(printf '%s\n' "$MUT" | sed -n 's/.*XMIN=\([0-9-]*\).*/\1/p')"
if [ "${MM:-0}" -le 0 ] 2>/dev/null; then echo "RESULT: FAIL 漏趟负对照没发火（MISMATCH=0）"; exit 2; fi
if [ "${XMIN:-99}" -lt 32 ] 2>/dev/null; then echo "RESULT: FAIL 漏趟错配没定位到被漏的 tile 列带（XMIN=$XMIN < 32）"; exit 2; fi
echo "   NEG_OK: 漏一趟 ⇒ MISMATCH=$MM（>0），错配 XMIN=$XMIN ≥ 32 ⇒ 落在被漏掉的 tx=1 列带"

# -----------------------------------------------------------------------------
# 负对照②：不给 halo（tWinLo+1 / tWinHi-1）
# -----------------------------------------------------------------------------
echo "---- 负对照②：不给 halo（tWinLo+1 / tWinHi-1）⇒ 错点只在 tile 接缝列 ----"
if ! "$PY" - "$nl" "$work/nl_nh.v" <<'PYEOF'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
o1 = "assign tWinLo = (($signed(tFx) < $signed(26'h0)) ? 24'h0 : _zz_tWinLo);"
n1 = "assign tWinLo = (($signed(tFx) < $signed(26'h0)) ? 24'h1 : (_zz_tWinLo + 24'h1));"
o2 = "? 24'h0 : _zz_tWinHi_2));"
n2 = "? 24'h0 : (_zz_tWinHi_2 - 24'h1)));"
a = src.count(o1); b = src.count(o2)
print("NOHALO_HITS=%d,%d (期望 1,1)" % (a, b))
if a < 1 or b < 1: sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(o1, n1).replace(o2, n2))
PYEOF
then echo "RESULT: FAIL 无法构造 no-halo 突变网表"; exit 2; fi
"$IVERILOG" -g2012 -DUE_CGEOM -o "$work/sim_nh.vvp" "$tb" "$memv" "$work/nl_nh.v" > "$work/ivnh.log" 2>&1 || { echo "RESULT: FAIL no-halo 突变网表编译失败"; exit 2; }
( cd "$work" && "$VVP" "$work/sim_nh.vvp" \
    "+XFILE=$work/$NEGJOB/x.hex" "+WFILE=$work/$NEGJOB/w.hex" "+BFILE=$work/$NEGJOB/b.hex" \
    "+MEMFILE=$work/$NEGJOB/mem.hex" "+DUMPFILE=$work/nh.dump" +dump +TILED_W \
    "+CIN=${X_CIN}" "+COUT=${X_COUT}" "+GROUP=${X_GROUP}" "+H=${X_H}" "+W=${X_W}" "+TYPE=1" "+FLAGS=1" \
    "+SRC=${X_SRC}" "+DST=${X_DST}" "+INB=${X_LEN}" "+QSHIFT=6" "+LID=0" \
    "+M=${X_M}" "+ZPAD=${X_ZPAD}" "+ZY=${X_ZY}" "+NCOL=1" "+NCI=${X_NCI}" "+NCO=${X_NCO}" "+STRIDE=${X_S}" ) \
    > "$work/nh.log" 2>&1
grep -q '^RESULT: PASS' "$work/nh.log" || { echo "RESULT: FAIL no-halo 突变网表装置未收工"; grep -E '^(RESULT|TILED_W)' "$work/nh.log"|head; exit 2; }
NH="$("$PY" - "$work" "$NEGJOB" "$DST" "${X_W}" "${X_COUT}" <<'PYEOF'
import sys
def load(p):
    out = []
    for l in open(p, encoding="utf-8", errors="replace"):
        s = l.strip()
        if not s: continue
        try: out.append(int(s, 16) & 0xFF)
        except ValueError: out.append(-1)
    return out
work, nj, dst, W, Co = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
d = load(work + "/nh.dump"); g = load(work + "/" + nj + "/gold.hex")
ln = len(g); m = 0; badx = set()
for k in range(ln):
    if d[dst+k] != g[k]:
        # ★ T-S2b-i：错配**列**= 冻结输出布局 `[co][y][x]`（NCHW 平面）里的 `k % W`。
        #   原式 `(k // Co) % W` 是"通道交错 `[y][x][co]`"布局的列号 —— 与黄金/网表布局不符：
        #   真被漏掉的列带 `x∈[32,39]` 经原式被映射成 `{8,9,18,19,28,29,38,39}` ⇒ XMIN=8 假红。
        m += 1; badx.add(k % W)
print("NH_MISMATCH=%d NBADX=%d XMIN=%d XMAX=%d XSORT=%s" % (m, len(badx), min(badx) if badx else -1, max(badx) if badx else -1, sorted(badx)[:12]))
PYEOF
)"
echo "   $NH"
NHM="$(printf '%s\n' "$NH" | sed -n 's/^NH_MISMATCH=\([0-9]*\).*/\1/p')"
NHX="$(printf '%s\n' "$NH" | sed -n 's/.*NBADX=\([0-9]*\).*/\1/p')"
if [ "${NHM:-0}" -le 0 ] 2>/dev/null; then echo "RESULT: FAIL no-halo 负对照没发火（MISMATCH=0）"; exit 2; fi
if [ "${NHX:-99}" -gt 8 ] 2>/dev/null; then echo "RESULT: FAIL no-halo 错点不是接缝类（错列数=$NHX > 8）"; exit 2; fi
echo "   NEG2_OK: 不给 halo ⇒ MISMATCH=$NHM（>0），错**列**仅 $NHX 列（⇒ 接缝类）"

# -----------------------------------------------------------------------------
# 负对照③（T-S3b）：EMIT 的 per-plane 索引退回**共享 plane-0**（`wxPIDX_k[` -> `wxPIDX_0[`）
#   ⇒ 在 `HW%32≠0` 的形状（20×20，HW=400）上**必红**；在 `HW%32==0` 的形状（40×40，HW=1600）上**不提**
#     （40×40 各平面低 5 位相同 ⇒ 共享索引本来就对）。**两侧都要断言**。
# -----------------------------------------------------------------------------
echo "---- 负对照③：EMIT 索引退回共享 plane-0（20×20 必红 / 40×40 不提）----"
if ! "$PY" - "$nl" "$work/nl_idx0.v" <<'PYEOF'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
n = 0
for k in range(1, 8):
    n += src.count("wxPIDX_%d[" % k)
    src = src.replace("wxPIDX_%d[" % k, "wxPIDX_0[")
print("IDX0_HITS=%d (期望 >=7)" % n)
if n < 7: sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(src)
PYEOF
then echo "RESULT: FAIL 无法构造 shared-idx 突变网表"; exit 2; fi
"$IVERILOG" -g2012 -DUE_CGEOM -o "$work/sim_idx0.vvp" "$tb" "$memv" "$work/nl_idx0.v" > "$work/iv_idx0.log" 2>&1 || { echo "RESULT: FAIL shared-idx 突变网表编译失败"; exit 2; }
idx0_run() {   # <name>  -> 跑突变网表；dump 落 $work/<name>.dump（judge_dst 的口径）
  local name="$1"
  eval "$(sed 's/^/X_/' "$work/$name/job.txt" | tr '\n' ' ')"
  ( cd "$work" && "$VVP" "$work/sim_idx0.vvp" \
      "+XFILE=$work/$name/x.hex" "+WFILE=$work/$name/w.hex" "+BFILE=$work/$name/b.hex" \
      "+MEMFILE=$work/$name/mem.hex" "+DUMPFILE=$work/$name.dump" +dump +TILED_W \
      "+CIN=${X_CIN}" "+COUT=${X_COUT}" "+GROUP=${X_GROUP}" "+H=${X_H}" "+W=${X_W}" "+TYPE=1" "+FLAGS=1" \
      "+SRC=${X_SRC}" "+DST=${X_DST}" "+INB=${X_LEN}" "+QSHIFT=6" "+LID=0" \
      "+M=${X_M}" "+ZPAD=${X_ZPAD}" "+ZY=${X_ZY}" "+NCOL=1" "+NCI=${X_NCI}" "+NCO=${X_NCO}" "+STRIDE=${X_S}" ) \
      > "$work/$name.idx0.log" 2>&1
  grep -q '^RESULT: PASS' "$work/$name.idx0.log" || { echo "RESULT: FAIL 突变网表装置未收工（$name）"; grep -E '^RESULT' "$work/$name.idx0.log"|head; exit 2; }
}
idx0_run c64_20x20
IM20="$(judge_dst "$work" c64_20x20 "$DST" "$(sed -n 's/^LEN=//p' "$work/c64_20x20/job.txt")" | sed -n 's/^MISMATCH=\([0-9]*\).*/\1/p')"
idx0_run c4_40x40
IM4="$(judge_dst "$work" c4_40x40 "$DST" "$(sed -n 's/^LEN=//p' "$work/c4_40x40/job.txt")" | sed -n 's/^MISMATCH=\([0-9]*\).*/\1/p')"
echo "   shared-idx: 20×20 MISMATCH=$IM20（须 >0） / 40×40 MISMATCH=$IM4（须 ==0）"
if [ "${IM20:-0}" -le 0 ] 2>/dev/null; then echo "RESULT: FAIL 负对照③ 没在 HW%32≠0（20×20）上发火（MISMATCH=0）"; exit 2; fi
if [ "${IM4:-99}" != "0" ] 2>/dev/null; then echo "RESULT: FAIL 负对照③ 在 HW%32==0（40×40）上误红（MISMATCH=$IM4）"; exit 2; fi
echo "   NEG3_OK: shared-idx ⇒ 20×20 MISMATCH=$IM20（>0，HW%32≠0 必红）；40×40 MISMATCH=0（HW%32==0 不提）"

echo "=========================================================================="
echo "[1] 正对照 真表宽几何（C=1/4/16/64 + depthwise + Conv_0 s=2）整层逐字节 : PASS（MISMATCH=0）"
echo "[2] 负对照① 漏一趟（tNtx-1->tNtx-2）        : PASS（MISMATCH=$MM>0，定位 XMIN=$XMIN）"
echo "[3] 负对照② 不给 halo（tWinLo+1/tWinHi-1）   : PASS（MISMATCH=$NHM>0，错列 $NHX ⇒ 接缝类）"
echo "[4] 负对照③ 共享 plane-0 索引（T-S3b）        : PASS（20×20 MISMATCH=$IM20>0；40×40 MISMATCH=0 不提）"
echo "RESULT: PASS"
exit 0
