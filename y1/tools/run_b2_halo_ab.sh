#!/usr/bin/env bash
# run_b2_halo_ab.sh —— ★★ B2（2026-10-20）：**tile 列 halo 复用**（B2b：逐 ci 的 2 列 shadow）+
#   **`s=2` 的 tileBuf 扩展**（B2a）的闸门。
#
# 被测：`rtl/UnitExec.scala` 类体末尾「B1」节之后追加的「B2b」一节 + 两行原地改（`:3018` `b1Depth`、
#   `:3024` 去掉 `tS==1` 门）—— 只在 `TILING=true` elaborate（`gen/UnitExec_tiled.v`；三份
#   `TILING=false` 网表必须逐字节不变）。装置 `rtl_test/UnitExecWideTb.v`（`+TILED_W -DUE_GEOM
#   -DUE_GBYTE`）+ `AxiMemModel.v`。
#
# 判据（map §4；每条都能单独发火）：
#   [0] **冻结**：`TILING=false` 三份网表 md5 == 已知三元组 + 源码中性（base/new 两次现生成逐字节同）。
#   [1] **G1 跨接缝逐字节**：`c64_40x40`（3×3、**2×2 tile、接缝在列 32/行 32** ⇒ 唯一会走 halo 的
#       作业）与 `c16_160x160`（5×5，8 条内接缝）整层 `DST` == 冻结黄金（`tiling_ref.conv_tiled`
#       + `quant_ref.conv_vec` **两条独立参考互证**）。
#   [2] **G2 交付口径不回归**：`gather_bytes` == B1 的同一个数（`c64_40x40` **123,904**、
#       `c16_160x160` **462,400**）—— halo 列仍交给 `mpu`，只是不 fetch。
#   [3] **G3 取数口径 = 模型值**（新口 `gather_fetch_bytes`，`+FEXP=`）：`c64_40x40` **196,608**
#       （B1 后 219,136）、`c16_160x160` **774,144**（B1 后 1,118,208）。模型是**逐列模拟**
#       gather 的 fetch 判决（含每平面 band 账本跨行复用），不是"每行独立数 band"。
#   [4] **G4 dw 宽层逐字节 + 对角趟不变量**：`dw16_80x80` 逐字节、`WIDE_PASSES == nCo`、
#       取数口径 **215,040**（B1 后 258,048）⇒ 列 halo 对 dw 同样生效、对角趟次序不动。
#   [5] **G5 s=2（B2a）**：`s2_3x16`（3→16、64×64、s=2）整层逐字节；`gather_bytes` **53,856**
#       （B2a 之前 = 107,712 = 两趟各读一遍，`gather_bytes` 判据必红）、取数口径 **87,360**
#       （B3a 起 FETCH 只扫 `wxNPl` 个平面：cin=3 从 8 lane 收到 3 lane，232,960 → 87,360）。
#   [6] **负对照（必发火且只在计数上）**：网表一行突变 `assign b2_hit = 1'b0;`（= 退回 B1 行为，不复用）
#       ⇒ `c64_40x40` 数值**仍然逐字节对**、`gather_bytes` **不变**，但 `gather_fetch_bytes` 回到
#       **219,136** ⇒ `+FEXP=`（正对照口径）必须 `FB_OK=0 / RESULT: FAIL`。
#   [7] **G7 CYC 标定**：同一 `c16_160x160` 作业，`b2_hit=0/1` 各一次，比较 `WIDERUN` **喂列拍数**
#       （`CYC_WR`）⇒ 必须**严格更少**；并把减少百分比按 map §4 的 15%/5% 三档写进日志。
#
# 退出码：0 = 全过 / 1 = 判据红 / 2 = 负对照没发火（或锚不唯一）/ 3 = 前置缺失。
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
qref="tools/quant_ref.py"
MEMSZ=2621440
SRC=131072          # 0x20000
DST=2097152         # 0x200000
tools_abs="$(pwd)/tools"

EXPECT_UE="451102f3b2f5404bd180f6c657692f6c"
EXPECT_W32="0f549d2ed375cbb8ab7eaebf7d00e222"
EXPECT_W640="dbfc18db006082e618d753fddb06d981"

find_tool() {
  local n="$1" p d
  p="$(command -v "$n" 2>/dev/null || true)"
  if [ -z "$p" ]; then for d in /c/msys64/ucrt64/bin /mingw64/bin /usr/bin; do [ -x "$d/$n" ] && { p="$d/$n"; break; }; done; fi
  printf '%s' "$p"
}
IVERILOG="$(find_tool iverilog)"; VVP="$(find_tool vvp)"
md5of() { md5sum "$1" 2>/dev/null | awk '{print $1}'; }

echo "== run_b2_halo_ab: B2 列 halo shadow（4,352 B）+ s=2 tileBuf（17,952 B）=="
echo "   nl=$nl  tb=$tb  py=$PY  iverilog=${IVERILOG:-<none>}"

for f in "$nl" "$tb" "$memv" "$ref" "$mpref" "$qref"; do
  [ -f "$f" ] || { echo "FATAL: 缺 $f"; echo "RESULT: FAIL"; exit 3; }
done
[ -n "$IVERILOG" ] && [ -n "$VVP" ] || { echo "FATAL: 缺 iverilog/vvp"; echo "RESULT: FAIL"; exit 3; }

work="$(mktemp -d)"
cleanup() { [ "${KEEP_TMP:-0}" = "1" ] && echo "KEEP_TMP=1 => $work" || rm -rf "$work"; }
trap cleanup EXIT
export PYTHONPATH="./.pydeps;../third_party/yunet/deps"
export PYTHONIOENCODING=utf-8

# -----------------------------------------------------------------------------
# [0] 前置：参考自检 + `TILING=false` 三网表 md5 + 源码中性证据
# -----------------------------------------------------------------------------
echo "---- [0] 前置：参考自检 + TILING=false 三网表 md5 + 源码中性证据 ----"
"$PY" "$ref" --selftest2d >/dev/null 2>&1 || { echo "RESULT: FAIL 参考自检没过"; exit 3; }
echo "   参考自检 OK（tiling_ref.py --selftest2d）"

MD5_BAD=0
for pair in "gen/UnitExec.v:$EXPECT_UE" "gen/UnitExec_w32.v:$EXPECT_W32" "gen/UnitExec_w640.v:$EXPECT_W640"; do
  f="${pair%%:*}"; e="${pair##*:}"; g="$(md5of "$f")"
  if [ "$g" != "$e" ]; then echo "    JUDGE-RED: $f md5=$g != $e（TILING=false 必须逐字节不变）"; MD5_BAD=1; fi
done
[ "$MD5_BAD" = 0 ] && echo "   TILING=false 三网表 md5 不变（$EXPECT_UE / $EXPECT_W32 / $EXPECT_W640）"
[ "$MD5_BAD" = 0 ] || { echo "RESULT: FAIL"; exit 1; }

if [ -d build/b2_regen/base_tfalse ] && [ -d build/b2_regen/new_tfalse ]; then
  NEU_BAD=0
  for f in UnitExec.v UnitExec_w32.v UnitExec_w640.v; do
    a="$(md5of "build/b2_regen/base_tfalse/$f")"; b="$(md5of "build/b2_regen/new_tfalse/$f")"
    if [ "$a" != "$b" ] || [ -z "$a" ]; then echo "    JUDGE-RED: $f 源码中性证据不符（base=$a new=$b）"; NEU_BAD=1; fi
    echo "   NEUTRAL $f base=$a new=$b $([ "$a" = "$b" ] && echo IDENTICAL || echo DIFF)"
  done
  [ "$NEU_BAD" = 0 ] || { echo "RESULT: FAIL"; exit 1; }
else
  echo "   NOTE: 缺 build/b2_regen/{base,new}_tfalse ⇒ 跳过源码中性证据（只保留文件 md5 冻结）"
fi
echo "   TILED_NL_MD5=$(md5of "$nl")（gen/UnitExec_tiled.v，只记账）"
if ! grep -q "b2_hit" "$nl"; then echo "   JUDGE-RED: gen/UnitExec_tiled.v 里没有 b2_hit ⇒ 网表不是 B2 档"; echo "RESULT: FAIL"; exit 1; fi
echo "   B2 标识在网表里：$(grep -c 'b2_hit\|b2_fill\|gather_fetch_bytes' "$nl") 处（b2_hit/b2_fill/gather_fetch_bytes）"

# -----------------------------------------------------------------------------
# [1] iverilog 编译（tiled 网表 + -DUE_CGEOM -DUE_GBYTE）
# -----------------------------------------------------------------------------
echo "---- [1] iverilog 编译（UnitExecWideTb + AxiMemModel + $nl；-DUE_CGEOM -DUE_GBYTE）----"
if ! "$IVERILOG" -g2012 -DUE_CGEOM -DUE_GBYTE -o "$work/sim.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败"; sed -n '1,30p' "$work/iv.log"; echo "RESULT: FAIL"; exit 1
fi
echo "   编译 OK"

# -----------------------------------------------------------------------------
# 作业生成器：NCHW 平面激活 → DDR；整层黄金 = `conv_tiled` 与 `conv_vec` **两条独立参考互证**
# -----------------------------------------------------------------------------
cat > "$work/genjob.py" <<'PYEOF'
import sys, os
sys.path.insert(0, sys.argv[1])
import numpy as np
import tiling_ref as T
import multipass_ref as MP
import quant_ref as Q

Z_Y = -7

def make(cin, cout, gg, H, W, s, seed):
    rng = np.random.default_rng(seed)
    Hin, Win = H * s, W * s
    xq = rng.integers(-20, 21, size=(1, cin, Hin, Win), dtype=np.int64)
    cig = cin // gg
    wq = rng.integers(-20, 21, size=(cout, cig, 3, 3), dtype=np.int64)
    sx = sw = sy = 0.05
    bfloat = rng.uniform(-0.5, 0.5, size=cout)
    biasb = np.round(bfloat / (sx * sw)).astype(np.int64)
    wd = {"q": wq.astype(np.int8), "scale": sw, "zp": 0}
    pads, strides = [1, 1, 1, 1], [s, s]
    tiled, acc_full, parts, M = T.conv_tiled(xq, wd, sx, sy, 0, 0, bfloat, pads, strides, gg, Z_Y,
                                             dump_passes=True)
    # ★ 第二条独立参考（im2col / matmul 口径，不用逐趟状态机）—— 两者必须逐字节同。
    whole = Q.conv_vec(xq, wd, sx, sy, 0, 0, bfloat, pads, strides, gg, Z_Y)
    if not np.array_equal(whole, tiled):
        raise SystemExit("两条独立参考不一致（%dx%d s=%d gg=%d）" % (H, W, s, gg))
    gold = tiled.reshape(-1).astype(np.int8)
    tiles = MP.weight_tiles(xq, wd, gg)
    n_co = (cout + 7) // 8
    btoks = []
    for j in range(n_co):
        btoks += [int(v) for v in MP.bias_of(biasb, j)]
    xin = xq[0].reshape(-1).astype(np.int8)
    return dict(gold=gold, tiles=np.concatenate([t.reshape(-1) for t in tiles]),
                b=np.asarray(btoks, dtype=np.int64), M=int(M), xin=xin,
                n_ci=int(T.n_passes(cin)), n_co=int(T.n_passes(cout)),
                distinct=len(set(int(v) for v in gold)))

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
    dump(os.path.join(d, "x.hex"), np.zeros(8, dtype=np.int64))
    pre = np.array([((i % 251) * 131 + 7) % 251 for i in range(memsz)], dtype=np.int64)
    dif = int(np.count_nonzero(pre[dst:dst + len(r["gold"])] != r["gold"]))
    assert dif >= int(len(r["gold"]) * 0.9), "dst 预载与黄金只差 %d/%d" % (dif, len(r["gold"]))
    mem = pre.copy()
    ex = src + len(r["xin"])
    assert ex <= dst or dst + len(r["gold"]) <= src, "src/dst 重叠"
    assert max(ex, dst + len(r["gold"])) <= memsz - 64, "越界"
    mem[src:ex] = r["xin"]
    dump(os.path.join(d, "mem.hex"), mem)
    dump(os.path.join(d, "pre.hex"), pre)
    with open(os.path.join(d, "job.txt"), "w", encoding="ascii", newline="\n") as f:
        f.write("CIN=%d\nCOUT=%d\nGROUP=%d\nH=%d\nW=%d\nS=%d\n" % (cin, cout, gg, H, W, s))
        f.write("SRC=%d\nDST=%d\nM=%d\nZPAD=0\nZY=%d\nNCI=%d\nNCO=%d\nLEN=%d\nDISTINCT=%d\n"
                % (src, dst, r["M"], Z_Y, r["n_ci"], r["n_co"], len(r["gold"]), r["distinct"]))
    print("JOBGEN %s CIN=%d COUT=%d GROUP=%d %dx%d s=%d n_ci=%d n_co=%d M=%d distinct=%d len=%d in=%d"
          % (name, cin, cout, gg, H, W, s, r["n_ci"], r["n_co"], r["M"], r["distinct"],
             len(r["gold"]), len(r["xin"])))

main()
PYEOF

# -----------------------------------------------------------------------------
# 两个计数口径的模型（与 RTL 逐式对账；不写第三条参考）
#   gexp = 交付口径 = Σ_tile (s·th+2)(s·tw+2) × 有效平面数（B1 的 `gather_bytes`，B2 之后**不变**）
#   fexp = 取数口径 = **逐列模拟** gather 的 fetch 判决（含每平面 band 账本），不是"每行独立数 band"：
#          · 账本按**平面号 p**（0..7）保存"最近一次装过的 band 基址"；相邻行/相邻 tile 的同一 band
#            命中时不重取（`wxPndV/wxBndB` 的真实语义；跨行共享正是 32B 口径被高估的来源）。
#          · `s=1 ∧ tx>0` 的窗口首 2 列 = B2b 命中 ⇒ 整列**不 fetch**（交付照旧）。
#          · pad 列/行（全局坐标越界）不 fetch。
#          · 计数口径与 RTL 一致：只数**窗口行**（`wRow < tNRow`）的完成 fetch。
# -----------------------------------------------------------------------------
cat > "$work/models.py" <<'PYEOF'
import sys
C, WIDTH, HT = 8, 34, 32

def tiles(H, W, s):
    twt = (WIDTH - 2) // s
    out = []
    for ty in range((H + HT - 1) // HT):
        th = min(HT, H - ty * HT)
        for tx in range((W + twt - 1) // twt):
            tw = min(twt, W - tx * twt)
            out.append((tx, ty, tw, th, s * (tx * twt - 1), s * th + 2, s * tw + 2))
    return out

def gexp(cin, H, W, s):
    nci = (cin + 7) // 8
    planes = sum(min(8, cin - 8 * i) for i in range(nci))
    cols = sum(nr * nc for (_, _, _, _, _, nr, nc) in tiles(H, W, s))
    return cols * planes

def fexp(cin, H, W, s, halo=True):
    """逐列模拟（与 UnitExec 的 gather 同序）：tile(ty 外, tx 内) → 趟(ci) → 行 → 列。
    ★ 账本 `last[p]` 跨行/跨 tile/跨趟持久（与 RTL 的 `wxBndV/wxBndB` 同生命周期）。
    ★ dense 只有每个 ci 的**填充趟**取数（重放趟读 tileBuf）；dw 每趟都取（对角趟）。"""
    hin, win = H * s, W * s
    hw = hin * win
    nci = (cin + 7) // 8
    last = {}
    tot = 0
    for (tx, ty, tw, th, fx, nr, nc) in tiles(H, W, s):
        fy = s * (ty * HT - 1)
        for cib in range(nci):
            npl = min(8, cin - 8 * cib)   # ★ B3a（2026-10-21）：FETCH 只扫本 ci-block 的有效平面
            for r in range(nr):
                iy = fy + r
                for c in range(nc):
                    g = fx + c
                    if iy < 0 or iy >= hin or g < 0 or g >= win:
                        continue
                    if halo and s == 1 and tx > 0 and c < 2:
                        continue
                    for p in range(npl):
                        a = (cib * 8 + p) * hw + iy * win + g
                        band = a & ~31
                        if last.get(p) != band:
                            tot += 32
                            last[p] = band
    return tot

if __name__ == "__main__":
    if sys.argv[1] == "gexp":
        print(gexp(*[int(v) for v in sys.argv[2:6]]))
    else:
        halo = not (len(sys.argv) > 6 and sys.argv[6] == "nohalo")
        print(fexp(*[int(v) for v in sys.argv[2:6]], halo=halo))
PYEOF

model() { "$PY" "$work/models.py" "$1" "$2" "$3" "$4" "$5" "${6:-}"; }

TOTAL_BAD=0

# run_job <vvp> <name> <tag> <ge> <fe>  （ge/fe 为空 = 不判）
run_job() {
  local vvp="$1" name="$2" tag="$3" ge="$4" fe="$5"
  eval "$(sed 's/^/X_/' "$work/$name/job.txt" | tr '\n' ' ')"
  local extra=()
  [ -n "$ge" ] && extra+=("+GEXP=$ge")
  [ -n "$fe" ] && extra+=("+FEXP=$fe")
  ( cd "$work" && "$VVP" "$vvp" \
      "+XFILE=$work/$name/x.hex" "+WFILE=$work/$name/w.hex" "+BFILE=$work/$name/b.hex" \
      "+MEMFILE=$work/$name/mem.hex" "+DUMPFILE=$work/$name.$tag.dump" +dump +TILED_W \
      "+CIN=${X_CIN}" "+COUT=${X_COUT}" "+GROUP=${X_GROUP}" "+H=${X_H}" "+W=${X_W}" "+TYPE=1" "+FLAGS=1" \
      "+SRC=${X_SRC}" "+DST=${X_DST}" "+INB=${X_LEN}" "+QSHIFT=6" "+LID=0" \
      "+M=${X_M}" "+ZPAD=${X_ZPAD}" "+ZY=${X_ZY}" "+NCOL=1" "+NCI=${X_NCI}" "+NCO=${X_NCO}" "+STRIDE=${X_S}" \
      "+TMT=12000000" "${extra[@]}" ) > "$work/$name.$tag.log" 2>&1
}

judge_dst() {  # <name> <tag> <dst> <len>
  "$PY" - "$work" "$1" "$2" "$3" "$4" <<'PYEOF'
import sys
def load(p):
    out = []
    for l in open(p, encoding="utf-8", errors="replace"):
        s = l.strip()
        if not s: continue
        try: out.append(int(s, 16) & 0xFF)
        except ValueError: out.append(-1)
    return out
work, name, tag, dst, ln = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
d = load(work + "/" + name + "." + tag + ".dump"); g = load(work + "/" + name + "/gold.hex")
pre = load(work + "/" + name + "/pre.hex")
k = min(ln, len(g), max(0, len(d) - dst))
mm = sum(1 for i in range(k) if d[dst+i] != g[i]) + max(0, ln - k)
nb = sum(1 for j in range(32) if d[dst-32+j] != pre[dst-32+j]) if dst >= 32 else 0
nb += sum(1 for j in range(32) if d[dst+k+j] != pre[dst+k+j]) if dst+k+32 <= len(d) else 0
print("MISMATCH=%d NEIGHBOR_BAD=%d" % (mm, nb))
PYEOF
}

num_of() { sed -n "s/.*$2=\([0-9]*\).*/\1/p" "$1" | tail -1; }

# 正对照：<name> <tag> <cin> <cout> <gg> <H> <W> <s> <seed> <need_gexp:0|1>
run_pos() {
  local name="$1" tag="$2" cin="$3" cout="$4" gg="$5" H="$6" W="$7" s="$8" seed="$9" needg="${10}"
  local G F
  G="$([ "$needg" = "1" ] && model gexp "$cin" "$H" "$W" "$s" || true)"
  F="$(model fexp "$cin" "$H" "$W" "$s")"
  echo "   模型：GEXP=${G:-NA} FEXP=$F（c_in=$cin c_out=$cout gg=$gg ${W}x${H} s=$s）"
  run_job "$work/sim.vvp" "$name" "$tag" "$G" "$F"
  local MM NB GB FB CY
  MM="$(judge_dst "$name" "$tag" "$DST" "$(sed -n 's/^LEN=//p' "$work/$name/job.txt")")"
  GB="$(num_of "$work/$name.$tag.log" GATHER_BYTES)"
  FB="$(num_of "$work/$name.$tag.log" GATHER_FETCH_BYTES)"
  CY="$(num_of "$work/$name.$tag.log" CYC_WR)"
  echo "   [$name/$tag] $MM GATHER_BYTES=${GB:-NA} GATHER_FETCH_BYTES=${FB:-NA} CYC_WR=${CY:-NA}"
  case "$MM" in *"MISMATCH=0 NEIGHBOR_BAD=0"*) ;; *)
    echo "    JUDGE-RED: $name/$tag 数值不对（$MM）"; TOTAL_BAD=$((TOTAL_BAD+1)); return 1;; esac
  if [ "$needg" = "1" ] && [ "${GB:-x}" != "$G" ]; then
    echo "    JUDGE-RED: 交付口径 gather_bytes=${GB} != $G（B2 之后必须**不变**）"; TOTAL_BAD=$((TOTAL_BAD+1)); return 1
  fi
  if [ "${FB:-x}" != "$F" ]; then
    echo "    JUDGE-RED: 取数口径 gather_fetch_bytes=${FB} != 模型 $F"; TOTAL_BAD=$((TOTAL_BAD+1)); return 1
  fi
  if ! grep -q '^RESULT: PASS' "$work/$name.$tag.log"; then
    echo "    JUDGE-RED: 装置未 PASS（$name/$tag）"; grep -E '^(RESULT|FB|GATHER)' "$work/$name.$tag.log" | tail -4
    TOTAL_BAD=$((TOTAL_BAD+1)); return 1
  fi
  echo "   OK: $name/$tag 逐字节 == 冻结黄金 + 交付口径不回归 + 取数口径 == 模型"
  return 0
}

job() {  # <name> <cin> <cout> <gg> <H> <W> <s> <seed> <need_gexp>
  "$PY" "$work/genjob.py" "$tools_abs" "$work" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$SRC" "$DST" "$MEMSZ" \
    > "$work/$1.gen" 2>&1 || { echo "RESULT: FAIL 供料失败（$1）"; tail -8 "$work/$1.gen"; exit 3; }
  grep -E '^JOBGEN' "$work/$1.gen" | sed 's/^/    /'
}

# -----------------------------------------------------------------------------
# [1] G1/G2/G3：跨接缝 2-tile 作业 + 5×5 作业（dense，3×3）
# -----------------------------------------------------------------------------
echo "---- [1] 正对照①：c64_40x40（3×3、2×2 tile、接缝在列 32）----"
job c64_40x40 64 64 1 40 40 1 4101 1
run_pos c64_40x40 pos 64 64 1 40 40 1 4101 1
echo "---- [2] 正对照②：c16_160x160（3×3、5×5 tile、8 条内接缝）----"
job c16_160x160 16 16 1 160 160 1 4102 1
run_pos c16_160x160 pos 16 16 1 160 160 1 4102 1

# -----------------------------------------------------------------------------
# [3] G4：dw 宽层（对角趟不动；列 halo 同样生效）
# -----------------------------------------------------------------------------
echo "---- [3] G4：dw16_80x80（depthwise 16→16、3×3 tile）----"
job dw16_80x80 16 16 16 80 80 1 4103 0
run_pos dw16_80x80 pos 16 16 16 80 80 1 4103 0
WP="$(num_of "$work/dw16_80x80.pos.log" WIDE_PASSES)"
NC="$(sed -n 's/^NCO=//p' "$work/dw16_80x80/job.txt")"
echo "   WIDE_PASSES=$WP（期望 = nCo = $NC）"
if [ "${WP:-x}" != "$NC" ]; then echo "RESULT: FAIL dw 对角趟数变了（WIDE_PASSES=$WP != nCo=$NC）"; exit 1; fi

# -----------------------------------------------------------------------------
# [4] G5：s=2（B2a；B2b 对它关着 ⇒ 取数口径 = 无 halo 的窗口）
# -----------------------------------------------------------------------------
echo "---- [4] G5：s2_3x16（3→16、64×64、s=2；B2a 的 17,952 B tileBuf）----"
job s2_3x16 3 16 1 64 64 2 4104 1
run_pos s2_3x16 pos 3 16 1 64 64 2 4104 1
GB_S2="$(num_of "$work/s2_3x16.pos.log" GATHER_BYTES)"
if [ "${GB_S2:-x}" != "53856" ]; then
  echo "   JUDGE-RED: s=2 交付口径 = ${GB_S2}（期望 53,856 = 8 tile × 2,244 列 × 3 平面 × **1** 趟）"
  echo "           ⇒ B2a 未生效（B2a 之前 = 107,712 = 两趟各读一遍）"; TOTAL_BAD=$((TOTAL_BAD+1))
fi

[ "$TOTAL_BAD" -eq 0 ] || { echo "RESULT: FAIL 正对照有红"; exit 1; }

# -----------------------------------------------------------------------------
# [5] 负对照：`assign b2_hit = 1'b0`（= 退回 B1 行为：halo 列重新 fetch）
#     ⇒ 数值仍逐字节对、`gather_bytes` 不变；`gather_fetch_bytes` 回到**无 halo** 口径
#       ⇒ `+FEXP=`（正对照口径）必红 ⇒ 红点唯一且可归因。
# -----------------------------------------------------------------------------
echo "---- [5] 负对照：assign b2_hit = 1'b0（退回 B1：halo 列重新 fetch）----"
if ! "$PY" - "$nl" "$work/nl_nohit.v" <<'PYEOF'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
lines = src.split("\n")
n = 0
for i, l in enumerate(lines):
    if l.strip().startswith("assign b2_hit ="):
        lines[i] = "  assign b2_hit = 1'b0;"; n += 1
print("MUTGEN_HITS=%d (期望 1)" % n)
if n != 1: sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8", newline="\n").write("\n".join(lines))
PYEOF
then echo "RESULT: FAIL 无法构造 b2_hit 突变网表（锚不唯一）"; exit 2; fi
"$IVERILOG" -g2012 -DUE_CGEOM -DUE_GBYTE -o "$work/sim_nohit.vvp" "$tb" "$memv" "$work/nl_nohit.v" > "$work/ivm.log" 2>&1 \
  || { echo "RESULT: FAIL 突变网表编译失败"; sed -n '1,20p' "$work/ivm.log"; exit 2; }

F_NOHIT="$(model fexp 64 40 40 1 nohalo)"          # 219,136（病态网表的**实测**口径）
G_NOHIT="$(model gexp 64 40 40 1)"                 # 123,904（交付口径不变）
F_POS="$(model fexp 64 40 40 1)"                   # 196,608（**正对照口径**：负对照拿它去判 ⇒ 必红）
run_job "$work/sim_nohit.vvp" c64_40x40 mut "$G_NOHIT" "$F_POS"
MM2="$(judge_dst c64_40x40 mut "$DST" "$(sed -n 's/^LEN=//p' "$work/c64_40x40/job.txt")")"
GB2="$(num_of "$work/c64_40x40.mut.log" GATHER_BYTES)"
FB2="$(num_of "$work/c64_40x40.mut.log" GATHER_FETCH_BYTES)"
OK2="$(num_of "$work/c64_40x40.mut.log" FB_OK)"
CY2="$(num_of "$work/c64_40x40.mut.log" CYC_WR)"
grep -E '^(GATHER_BYTES|GATHER_FETCH_BYTES|RESULT)' "$work/c64_40x40.mut.log" | sed 's/^/   [mut] /'
echo "   [mut] $MM2 GATHER_BYTES=${GB2}（期望 $G_NOHIT）GATHER_FETCH_BYTES=${FB2}（期望 $F_NOHIT）FB_OK=${OK2}（期望 0）"
case "$MM2" in *"MISMATCH=0 NEIGHBOR_BAD=0"*) ;; *)
  echo "RESULT: FAIL 负对照的数值也坏了（$MM2）⇒ 红点不可归因"; exit 1;; esac
if [ "${FB2:-x}" != "$F_NOHIT" ]; then echo "RESULT: FAIL 负对照取数口径没回到无 halo 值（$FB2 != $F_NOHIT）"; exit 2; fi
if [ "${GB2:-x}" != "$G_NOHIT" ]; then echo "RESULT: FAIL 负对照把交付口径也改了（$GB2 != $G_NOHIT）⇒ 红点不可归因"; exit 2; fi
if [ "${OK2:-1}" != "0" ]; then echo "RESULT: FAIL 负对照的 +FEXP 判据没发火（FB_OK=$OK2）"; exit 2; fi
grep -q '^RESULT: FAIL' "$work/c64_40x40.mut.log" || { echo "RESULT: FAIL 负对照没发火（装置仍 PASS）"; exit 2; }
echo "   NEG_OK: 数值逐字节对（MISMATCH=0）、交付口径不变（$G_NOHIT）、取数口径回到 $F_NOHIT ⇒ +FEXP 必红"

# -----------------------------------------------------------------------------
# [6] G7：CYC 标定（同一 c16_160x160 作业，b2_hit=0/1 各一次）
#     判读（map §4，先写死）：hit 比 no-hit 少 ≥15% ⇒ R4（冷突发限帧）；±5% 内 ⇒ R3（交付列限帧）。
# -----------------------------------------------------------------------------
echo "---- [6] G7：CYC 标定（c16_160x160，b2_hit=0/1）----"
F_NH16="$(model fexp 16 160 160 1 nohalo)"
run_job "$work/sim_nohit.vvp" c16_160x160 nohit "" "$F_NH16"
CY_H="$(num_of "$work/c16_160x160.pos.log" CYC_WR)"
CY_N="$(num_of "$work/c16_160x160.nohit.log" CYC_WR)"
FB_N="$(num_of "$work/c16_160x160.nohit.log" GATHER_FETCH_BYTES)"
echo "   CYC_WR: b2_hit=1 → ${CY_H:-NA} 拍 / b2_hit=0 → ${CY_N:-NA} 拍（取数口径 $FB_N）"
if [ -z "${CY_H:-}" ] || [ -z "${CY_N:-}" ] || [ "$CY_N" -le 0 ]; then
  echo "RESULT: FAIL G7 没拿到 CYC_WR"; exit 1
fi
if [ "$CY_H" -ge "$CY_N" ]; then
  echo "RESULT: FAIL G7：b2_hit=1 的喂列拍数没有更少（$CY_H >= $CY_N）"; exit 1
fi
PCT=$("$PY" -c "print('%.1f' % (100.0*($CY_N-$CY_H)/$CY_N))")
echo "   G7 读判：喂列拍数减少 $PCT%"
"$PY" -c "p=$PCT; print('   → 判读：' + ('R4 成立（冷突发限帧，B2b 上界≈0.99 s）' if p>=15 else ('R3 成立（交付列限帧，B2b 只值 0.11 s）' if p<=5 else '中间档（按 R2/AR 字节折算 0.31 s）')))"

echo "--------------------------------------------------------------------------"
echo "[1] 跨接缝 2-tile 逐字节（c64_40x40）      : PASS（MISMATCH=0，交付 123,904 / 取数 $(model fexp 64 40 40 1)）"
echo "[2] 5×5 接缝逐字节（c16_160x160）           : PASS（MISMATCH=0，交付 $(model gexp 16 160 160 1) / 取数 $(model fexp 16 160 160 1)）"
echo "[3] dw 宽层逐字节 + 对角趟（dw16_80x80）    : PASS（WIDE_PASSES=$WP=nCo，取数 $(model fexp 16 80 80 1)）"
echo "[4] s=2 B2a（s2_3x16）                      : PASS（交付 53,856 = 旧 107,712 的一半，取数 $(model fexp 3 64 64 2)）"
echo "[5] 负对照 b2_hit=0                         : PASS（数值对、交付不变、取数 $F_NOHIT ⇒ +FEXP 必红）"
echo "[6] G7 CYC 标定                             : 喂列拍数 −$PCT%（$CY_N → $CY_H）"
echo "RESULT: PASS"
exit 0
