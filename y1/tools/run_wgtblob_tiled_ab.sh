#!/usr/bin/env bash
# run_wgtblob_tiled_ab.sh —— ★★ T-S3d：**`权重 blob（DDR）× tiled 宽路`** 组合的闸门
#   （spec §3.5 的"仿真挂住"：受控实验 → 三臂二分 → 根因 → 修 → 正/负对照）
#
# 被测：`rtl/UnitExec.scala`（`TILING=true`）⇒ `gen/UnitExec_tiled.v`（`WIDTH=34 / IMG_H_MAX=32 / L_MAX=8`）
#   —— 走**宽路 tile 循环**（`tilingWideC ⇒ tilingW`）+ **权重段从 DDR 的 blob 装载**（`dmaEn`/`+WBASE`）。
#   装置 `rtl_test/UnitExecWideTb.v`（`+TILED_W`：激活由 DDR 平面 halo gather 取、装置不喂列；
#   `+WBASE`：权重段从 DDR 装；`+WEXP`：期望读回的权重字节数；`+TMT`：等 done/err 的拍数上限）
#   + `AxiMemModel.v`。
#
# 为什么是这个组合（无既有闸门覆盖）：`+TILED_W` 只在 `run_tiling2d_wide_ab.sh` 出现（**不传 `+WBASE`** ——
#   权重走信箱区域 1）；`+WBASE` 只在 `run_wgtdma_*` / `run_paramdel_ab.sh` 出现（用 `TILING=false` 网表，
#   那里 `tilingW` 恒 0）。而**真帧的编程恰好是"tiled 网表 + 区域 6 投 `WGT_BLOB_BASE` + `--xdma-en`"**
#   （`tools/npu_frame_run.py`）⇒ 本闸门补的就是这条缝。
#
# 根因（两处，RTL；机理与受控实验见 `rtl/UnitExec.scala` 文件尾「T-S3d」一节）：
#   ① `ddrMaster.io.rd_ready` 的 `tilingW` 支漏了装载器（`wlTake`）⇒ `WGTLD/WGTRUN` 期间 `rd_ready` 恒 0
#      ⇒ 主口推完第一块 128 B 就永久等握手（无 done、无 err；`MEM rd=128 bursts=1`）；
#   ② `WGTRUN` 收工那拍的 `wlWideR && !wideGeomOk` 未豁免 tiled 宽路 ⇒ `inWOk`（整层行宽 ≤ W_MAX）
#      把"tile 绕开的那个前提"又搬回来 ⇒ 装对了也被响亮 err（①修好后才走到②）。
#
# 判据（每条都要**正对照 + 能发火的负对照**）：
#   0) **前置**：冻结参考自检（`tiling_ref.py --selftest2d`）；`TILING=false` 三网表 md5 逐字节不变
#      （`7593b189ae8339e291c2fa398d0fcb2b` / `817ab5bbce2ef0bcaae556c8a9ded41b` / `5d2cd81addb84c62b2407f64aa0ac3a2`）；
#      **离线互证**：blob（密集 `[co][ci][tap]`）经装载器的 `dest(co,ci,tap)` 重排 == 冻结参考
#      `multipass_ref.weight_tiles()` 的趟序（不写第三条参考，只用既有冻结工具）。
#   1) **正对照 ×3**（真表几何）：`64→64 40×40`（= 受控实验的复现形状，8×8 趟、2×2 tile）、
#      `64→16 8×32`（`inWMax=32 ≤ WIDTH=34` ⇒ 单 tile；形状无关性）、`16→16 40×40`（小块数 + 多 tile）。
#      每档都要：装置 `PASS`（收工 + 无 err + `busy` 落 0 + `rd_peak == +WEXP`）
#      ∧ `DST` 逐字节 == **整层黄金**（复用 `tiling_ref.conv_tiled`，同 `run_tiling2d_wide_ab.sh`）
#      ∧ `wRam` 段内逐字节 == 期望镜像（blob 重排）、段外一个字节没动（**权重真的只经 DMA 进来**）。
#   2) **负对照①（blob 少一段，必发火 + 定位）**：把 blob 里对应**最后一个趟瓦片**（pass `nCi*nCo-1`）
#      的那 8×8 个 `(co,ci)` 的 9 字节清零 ⇒ `MISMATCH>0` **且错点全部落在该 co-block 的输出字节带**
#      `[(nCo-1)*8*H*W, C_out*H*W)`（外科式：别的 co-block 不受影响）。
#   3) **负对照②（RTL 修复-① 退回，必挂住）**：网表突变把 `tilingW` 支的 `wlTake ||` 拆掉 ⇒
#      必须"不收工"（`+TMT=200000` 压短：`rd_ready` 恒 0 ⇒ 装载挂住）。
#   4) **负对照③（RTL 修复-② 退回，双侧）**：网表突变把 `&& (! tilingW)` 拆掉 ⇒
#      在 `64→64 40×40`（`inWMax=40 > WIDTH`）上必 **err**；在 `64→16 8×32`（`32 ≤ 34`）上**不提**（`PASS`）。
#
# 退出码：0 = 全过 / 1 = 判据红 / 2 = 负对照没发火（或突变锚不唯一）/ 3 = 前置缺失。
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
SRC=131072            # 0x20000：激活（gather 的真源）
DST=2097152           # 0x200000：输出区
WBASE=262144          # 0x40000：权重 blob 的段起点（32 B 对齐）
TMT_NEG=200000        # 负对照②的"挂住"判据拍数（把 4M 压短；正向作业用缺省 4M）
tools_abs="$(pwd)/tools"

find_tool() {
  local n="$1" p d
  p="$(command -v "$n" 2>/dev/null || true)"
  if [ -z "$p" ]; then for d in /c/msys64/ucrt64/bin /mingw64/bin /usr/bin; do [ -x "$d/$n" ] && { p="$d/$n"; break; }; done; fi
  printf '%s' "$p"
}
IVERILOG="$(find_tool iverilog)"; VVP="$(find_tool vvp)"

echo "== run_wgtblob_tiled_ab: 权重 blob(DDR) × tiled 宽路（spec §3.5 的挂住）=="
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

# -----------------------------------------------------------------------------
# 0) 前置：冻结参考自检 + TILING=false 三网表 md5 + blob→wRam 映射互证
# -----------------------------------------------------------------------------
echo "---- 0) 前置：参考自检 + TILING=false 三网表 md5 + blob→wRam 映射互证 ----"
"$PY" "$ref" --selftest2d >/dev/null 2>&1 || { echo "RESULT: FAIL 参考自检没过"; exit 3; }
echo "   参考自检 OK（tiling_ref.py --selftest2d）"

EXPECT_UE="7593b189ae8339e291c2fa398d0fcb2b"
EXPECT_W32="817ab5bbce2ef0bcaae556c8a9ded41b"
EXPECT_W640="5d2cd81addb84c62b2407f64aa0ac3a2"
md5of() { md5sum "$1" 2>/dev/null | awk '{print $1}'; }
MD5_BAD=0
for pair in "gen/UnitExec.v:$EXPECT_UE" "gen/UnitExec_w32.v:$EXPECT_W32" "gen/UnitExec_w640.v:$EXPECT_W640"; do
  f="${pair%%:*}"; e="${pair##*:}"; g="$(md5of "$f")"
  if [ "$g" != "$e" ]; then echo "    JUDGE-RED: $f md5=$g != $e（TILING=false 必须逐字节不变）"; MD5_BAD=1; fi
done
[ "$MD5_BAD" = 0 ] && echo "   TILING=false 三网表 md5 不变（97912901… / 618af338… / ddb9bb8a…）"
[ "$MD5_BAD" = 0 ] || { echo "RESULT: FAIL"; exit 1; }
echo "   TILED_NL_MD5=$(md5of "$nl")（gen/UnitExec_tiled.v，只记账）"

# -----------------------------------------------------------------------------
# 作业生成器（复用冻结参考的算术；只做布局/落盘。blob = **密集 [co][ci][tap]**，装载器按 dest() 重排）
# -----------------------------------------------------------------------------
cat > "$work/genjob.py" <<'PYEOF'
import sys, os
sys.path.insert(0, sys.argv[1])
import numpy as np
import tiling_ref as T
import multipass_ref as MP

Z_Y = -7

def dest(co, ci, tap, nci, cin):
    return ((co // 8) * nci + (ci // 8)) * 576 + (co % 8) * 72 + (ci % 8) * 9 + tap   # ★ 与 run_wgtdma_wide_ab.sh 同式

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
    gold = tiled.reshape(-1).astype(np.int8)
    tiles = MP.weight_tiles(xq, wd, gg)
    n_ci = T.n_passes(cin); n_co = T.n_passes(cout)
    btoks = []
    for j in range(n_co):
        btoks += [int(v) for v in MP.bias_of(biasb, j)]
    xin = xq[0].reshape(-1).astype(np.int8)
    blob = wq.reshape(-1).astype(np.int8)                       # 密集 [co][ci][ky][kx]
    # ★ 互证：blob 经 dest() 重排 == 冻结参考的趟序瓦片（逐字节；两条独立路径）
    exp = bytearray(n_ci * n_co * 576)
    for co in range(cout):
        for ci in range(cin):
            for tap in range(9):
                exp[dest(co, ci, tap, n_ci, cin)] = int(blob[(co * cin + ci) * 9 + tap]) & 0xFF
    refw = np.concatenate([t.reshape(-1) for t in tiles])
    xbad = sum(1 for i in range(len(refw)) if exp[i] != (int(refw[i]) & 0xFF))
    assert xbad == 0, "blob→wRam 映射与 weight_tiles() 不一致：%d 字节" % xbad
    return dict(gold=gold, tiles=refw, b=np.asarray(btoks, dtype=np.int64), M=int(M), xin=xin,
                blob=blob, exp=np.frombuffer(bytes(exp), dtype=np.uint8),
                n_ci=int(n_ci), n_co=int(n_co), distinct=len(set(int(v) for v in gold)))

def dump(path, toks, w=2):
    m = (1 << (4 * w)) - 1
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("".join(("%0" + str(w) + "x\n") % (int(t) & m) for t in toks))

def main():
    tools, work, name = sys.argv[1], sys.argv[2], sys.argv[3]
    cin, cout, gg, H, W, s = (int(x) for x in sys.argv[4:10])
    seed = int(sys.argv[10]); src = int(sys.argv[11]); dst = int(sys.argv[12]); memsz = int(sys.argv[13])
    wbase = int(sys.argv[14])
    r = make(cin, cout, gg, H, W, s, seed)
    d = os.path.join(work, name); os.makedirs(d, exist_ok=True)
    dump(os.path.join(d, "w.hex"), r["tiles"])
    dump(os.path.join(d, "wexp.hex"), r["exp"])            # wRam 段内期望镜像（blob 重排）
    dump(os.path.join(d, "b.hex"), r["b"], w=8)
    dump(os.path.join(d, "gold.hex"), r["gold"])
    dump(os.path.join(d, "x.hex"), np.zeros(8, dtype=np.int64))
    pre = np.array([((i % 251) * 131 + 7) % 251 for i in range(memsz)], dtype=np.int64)
    dif = int(np.count_nonzero(pre[dst:dst + len(r["gold"])] != r["gold"]))
    assert dif >= int(len(r["gold"]) * 0.9), "dst 预载与黄金只差 %d/%d" % (dif, len(r["gold"]))
    mem = pre.copy()
    ex = src + len(r["xin"])
    assert ex <= dst or dst + len(r["gold"]) <= src, "src/dst 重叠"
    assert max(ex, dst + len(r["gold"]), wbase + len(r["blob"])) <= memsz - 64, "越界"
    mem[src:ex] = r["xin"]
    mem[wbase:wbase + len(r["blob"])] = r["blob"]
    dump(os.path.join(d, "mem.hex"), mem)
    dump(os.path.join(d, "pre.hex"), pre)
    # ★ 负对照①的镜像：blob 里**最后一个趟瓦片**（pass n_ci*n_co-1）对应的 (co,ci) 字节清零
    nci, nco, cin_, cout_ = r["n_ci"], r["n_co"], cin, cout
    cob, cib = nco - 1, nci - 1
    drop = set()
    for co in range(cob * 8, min(cout_, cob * 8 + 8)):
        for ci in range(cib * 8, min(cin_, cib * 8 + 8)):
            for tap in range(9):
                drop.add((co * cin_ + ci) * 9 + tap)
    memf = mem.copy()
    for o in drop:
        memf[wbase + o] = 0
    dump(os.path.join(d, "mem_drop.hex"), memf)
    assert len(drop) > 0
    # 错点定位带：该 co-block 的输出字节区间 [cob*8*H*W, min(C_out, cob*8+8)*H*W)
    with open(os.path.join(d, "job.txt"), "w", encoding="ascii", newline="\n") as f:
        f.write("CIN=%d\nCOUT=%d\nGROUP=%d\nH=%d\nW=%d\nS=%d\n" % (cin, cout, gg, H, W, s))
        f.write("SRC=%d\nDST=%d\nM=%d\nZPAD=0\nZY=%d\nNCI=%d\nNCO=%d\nLEN=%d\nDISTINCT=%d\n"
                % (src, dst, r["M"], Z_Y, r["n_ci"], r["n_co"], len(r["gold"]), r["distinct"]))
        f.write("BLOB=%d\nWEXP=%d\nNROWS=%d\nBANDLO=%d\nBANDHI=%d\nDROPN=%d\n"
                % (len(r["blob"]), ((len(r["blob"]) + 31) // 32) * 32, cout_, cob * 8 * H * W,
                   min(cout_, cob * 8 + 8) * H * W, len(drop)))
    print("JOBGEN %s CIN=%d COUT=%d GROUP=%d %dx%d s=%d n_ci=%d n_co=%d M=%d distinct=%d len=%d wram=%d blob=%d drop=%d band=[%d,%d)"
          % (name, cin, cout, gg, H, W, s, r["n_ci"], r["n_co"], r["M"], r["distinct"], len(r["gold"]),
             len(r["exp"]), len(r["blob"]), len(drop), cob * 8 * H * W, min(cout_, cob * 8 + 8) * H * W))

main()
PYEOF

# 编译正网表
echo "---- 1) iverilog 编译（UnitExecWideTb + AxiMemModel + gen/UnitExec_tiled.v）----"
if ! "$IVERILOG" -g2012 -DUE_CGEOM -o "$work/sim.vvp" "$tb" "$memv" "$nl" > "$work/iv.log" 2>&1; then
  echo "JUDGE-RED: iverilog 编译失败"; sed -n '1,30p' "$work/iv.log"; echo "RESULT: FAIL"; exit 1
fi
echo "   编译 OK"

TOTAL_BAD=0; NEG_NOFIRE=0; JOBS=""

# run_pos <name> <memfile> <tag> [extra plusargs...]  -> 跑一次（job.txt 几何；必须 PASS）
run_pos() {
  local name="$1" mf="$2" tag="$3"; shift 3
  eval "$(sed 's/^/X_/' "$work/$name/job.txt" | tr '\n' ' ')"
  ( cd "$work" && "$VVP" "$work/sim.vvp" \
      "+XFILE=$work/$name/x.hex" "+WFILE=$work/$name/w.hex" "+BFILE=$work/$name/b.hex" \
      "+MEMFILE=$mf" "+DUMPFILE=$work/$tag.dump" +dump +TILED_W "+DUMPW=$work/$tag.wram" \
      "+WBASE=$WBASE" "+WEXP=${X_WEXP}" "$@" \
      "+CIN=${X_CIN}" "+COUT=${X_COUT}" "+GROUP=${X_GROUP}" "+H=${X_H}" "+W=${X_W}" "+TYPE=1" "+FLAGS=1" \
      "+SRC=${X_SRC}" "+DST=${X_DST}" "+INB=${X_LEN}" "+QSHIFT=6" "+LID=0" \
      "+M=${X_M}" "+ZPAD=${X_ZPAD}" "+ZY=${X_ZY}" "+NCOL=1" "+NCI=${X_NCI}" "+NCO=${X_NCO}" "+STRIDE=${X_S}" ) \
      > "$work/$tag.log" 2>&1
  grep -q '^RESULT: PASS' "$work/$tag.log"
}

# judge_dst <tag> <name>  -> DST 逐字节 vs 黄金（KV 输出）
judge_dst() {
  "$PY" - "$work" "$1" "$2" "$DST" <<'PYEOF'
import sys
def load(p):
    out = []
    for l in open(p, encoding="utf-8", errors="replace"):
        s = l.strip()
        if not s: continue
        try: out.append(int(s, 16) & 0xFF)
        except ValueError: out.append(-1)
    return out
work, tag, name, dst = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
d = load(work + "/" + tag + ".dump"); g = load(work + "/" + name + "/gold.hex"); p = load(work + "/" + name + "/pre.hex")
ln = len(g)
k = min(ln, max(0, len(d) - dst))
bad = [i for i in range(k) if d[dst+i] != g[i]]
mm = len(bad) + max(0, ln - k)
nb = sum(1 for j in range(32) if d[dst-32+j] != p[dst-32+j]) if dst >= 32 else 0
nb += sum(1 for j in range(32) if d[dst+k+j] != p[dst+k+j]) if dst+k+32 <= len(d) else 0
print("MISMATCH=%d" % mm)
print("NEIGHBOR_BAD=%d" % nb)
print("BADLO=%d" % (min(bad) if bad else -1))
print("BADHI=%d" % (max(bad) if bad else -1))
PYEOF
}

# wramcmp <tag> <name>
wramcmp() {
  "$PY" - "$work" "$1" "$2" <<'PYEOF'
import sys
def load(p):
    try: return [int(l.strip(), 16) for l in open(p, encoding="utf-8", errors="replace") if l.strip()]
    except OSError: return []
work, tag, name = sys.argv[1], sys.argv[2], sys.argv[3]
d = load(work + "/" + tag + ".wram"); e = load(work + "/" + name + "/wexp.hex"); w = load(work + "/" + name + "/w.hex")
n = len(e); MAXW = 8 * 8 * 576
def at(a, i): return a[i] if 0 <= i < len(a) else -1
bad = sum(1 for i in range(n) if at(d, i) != at(e, i))
first = next((i for i in range(n) if at(d, i) != at(e, i)), -1)
out = sum(1 for i in range(n, MAXW) if at(d, i) != 0)
print("WRAM_BAD=%d" % bad)
print("WRAM_FIRST=%d" % first)
print("WRAM_OUTSIDE_NONZERO=%d" % out)
print("WRAM_EXP_NONZERO=%d" % sum(1 for i in range(n) if at(e, i) != 0))
PYEOF
}

# job <name> <cin> <cout> <group> <H> <W> <s> <seed>
job() {
  local name="$1" cin="$2" cout="$3" gg="$4" H="$5" W="$6" s="$7" seed="$8"
  echo "---- job $name: C_in=$cin C_out=$cout GROUP=$gg 输出 ${W}x${H} s=$s ----"
  if ! "$PY" "$work/genjob.py" "$tools_abs" "$work" "$name" "$cin" "$cout" "$gg" "$H" "$W" "$s" "$seed" "$SRC" "$DST" "$MEMSZ" "$WBASE" > "$work/$name.gen" 2>&1; then
    echo "RESULT: FAIL 供料失败（$name）"; tail -8 "$work/$name.gen"; exit 3
  fi
  grep -E '^JOBGEN' "$work/$name.gen" | sed 's/^/    /'
  JOBS="$JOBS $name"
}

# -----------------------------------------------------------------------------
# 2) 正对照 ×3：真表几何 + 权重只经 blob(DDR) 装载
# -----------------------------------------------------------------------------
echo "=========================================================================="
echo "正对照：tiled 宽路 + 权重 blob(DDR)。判据 = 装置 PASS（收工/无 err/rd_peak==WEXP）+ DST 逐字节 + wRam 逐字节"
job c64_40x40   64 64 1  40 40 1 104
job c64to16_8x32 64 16 1  8 32 1 111
job c16_40x40   16 16 1  40 40 1 112

pos_ok=0
for nm in $JOBS; do
  if ! run_pos "$nm" "$work/$nm/mem.hex" "$nm"; then
    echo "JUDGE-RED: 装置未 PASS（$nm）"; grep -E '^(TB TILED_W_EN|TB WIDE RTL|TILED_W|DBG-PHASE|RESULT)' "$work/$nm.log" | tail -8
    TOTAL_BAD=$((TOTAL_BAD+1)); continue
  fi
  grep -E '^(TILED_W |DONE_SEEN)' "$work/$nm.log" | sed "s/^/    [$nm] /"
  eval "$(judge_dst "$nm" "$nm" | sed 's/^/D_/')"
  eval "$(wramcmp "$nm" "$nm" | sed 's/^/W_/')"
  ok=1
  [ "${D_MISMATCH:-x}" = "0" ] || ok=0
  [ "${D_NEIGHBOR_BAD:-x}" = "0" ] || ok=0
  [ "${W_WRAM_BAD:-x}" = "0" ] || ok=0
  [ "${W_WRAM_OUTSIDE_NONZERO:-x}" = "0" ] || ok=0
  if [ "$ok" = 1 ]; then
    pos_ok=$((pos_ok+1))
    echo "   OK: $nm  DST==整层黄金（MISMATCH=0，邻居未动）wRam 段内==blob 重排（$W_WRAM_BAD，非0字节 $W_WRAM_EXP_NONZERO）段外未写"
  else
    echo "JUDGE-RED: $nm 正对照红（DST MISMATCH=${D_MISMATCH:-?} 邻居=${D_NEIGHBOR_BAD:-?} wRam bad=${W_WRAM_BAD:-?} 段外=${W_WRAM_OUTSIDE_NONZERO:-?}）"
    TOTAL_BAD=$((TOTAL_BAD+1))
  fi
done
echo "   正对照通过 $pos_ok/3 例"
[ "$TOTAL_BAD" -eq 0 ] || { echo "RESULT: FAIL 正对照有红"; exit 1; }

NEGJOB=c64_40x40
NEGJOB2=c64to16_8x32

# -----------------------------------------------------------------------------
# 3) 负对照①：blob 少一段（最后一个趟瓦片）⇒ MISMATCH>0 且定位在对应 co-block 带
# -----------------------------------------------------------------------------
echo "---- 负对照①：blob 里最后一个趟瓦片清零（pass nCi*nCo-1）⇒ 必红 + 定位 ----"
eval "$(sed 's/^/X_/' "$work/$NEGJOB/job.txt" | tr '\n' ' ')"
if ! run_pos "$NEGJOB" "$work/$NEGJOB/mem_drop.hex" "${NEGJOB}_drop"; then
  echo "JUDGE-RED: 负对照① 装置未收工"; grep -E '^RESULT' "$work/${NEGJOB}_drop.log" | tail -3; exit 1
fi
N1="$("$PY" - "$work" "${NEGJOB}_drop" "$NEGJOB" "$DST" "$X_BANDLO" "$X_BANDHI" "$X_DROPN" <<'PYEOF'
import sys
def load(p):
    out = []
    for l in open(p, encoding="utf-8", errors="replace"):
        s = l.strip()
        if not s: continue
        try: out.append(int(s, 16) & 0xFF)
        except ValueError: out.append(-1)
    return out
work, tag, name, dst, blo, bhi, dn = (sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]),
                                      int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7]))
d = load(work + "/" + tag + ".dump"); g = load(work + "/" + name + "/gold.hex")
bad = [i for i in range(len(g)) if d[dst+i] != g[i]]
outside = [i for i in bad if not (blo <= i < bhi)]
print("N1_MISMATCH=%d" % len(bad))
print("N1_OUTSIDE=%d" % len(outside))
print("N1_BADLO=%d" % (min(bad) if bad else -1))
print("N1_BADHI=%d" % (max(bad) if bad else -1))
print("N1_DROPN=%d" % dn)
PYEOF
)"
echo "   $N1" | sed 's/^/   /'
eval "$(printf '%s\n' "$N1" | sed 's/^/X1_/')"
if [ "${X1_N1_MISMATCH:-0}" -le 0 ] 2>/dev/null; then
  echo "NEGCTL-FAIL: 负对照① 没发火（blob 少一段却输出全对）"; NEG_NOFIRE=$((NEG_NOFIRE+1))
elif [ "${X1_N1_OUTSIDE:-1}" -ne 0 ] 2>/dev/null; then
  echo "NEGCTL-FAIL: 负对照① 错点跑出该 co-block 带（outside=${X1_N1_OUTSIDE}，带=[${X_BANDLO},${X_BANDHI})）"; NEG_NOFIRE=$((NEG_NOFIRE+1))
else
  echo "   NEG1_OK: blob 少一段 ⇒ MISMATCH=${X1_N1_MISMATCH}（>0）且错点全落在 co-block 带 [${X_BANDLO},${X_BANDHI})（外科式）"
fi

# -----------------------------------------------------------------------------
# 4) 负对照②：RTL 修复-① 退回（tiling 支拆掉 `wlTake ||`）⇒ 必须挂住
# -----------------------------------------------------------------------------
echo "---- 负对照②：网表突变退回修复-①（rd_ready 的 tiling 支拆掉 wlTake）⇒ 必挂住（+TMT=$TMT_NEG）----"
if ! "$PY" - "$nl" "$work/nl_rb1.v" <<'PYEOF'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = "(tilingW ? (wlTake || (((wxSt == 2'b10) && (wxK || wxSgDrn)) && ddrMaster_1_rd_valid)) : (((wlTake || (mayWrite && rowIsDdr)) || xgTake) || tRdReady));"
new = "(tilingW ? 1'b0 : (((wlTake || (mayWrite && rowIsDdr)) || xgTake) || tRdReady));"
n = src.count(old)
print("RB1_HITS=%d (期望 1)" % n)
if n != 1: sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PYEOF
then echo "NEGCTL-FAIL: 修复-① 退回的突变锚不唯一"; echo "RESULT: FAIL"; exit 2; fi
"$IVERILOG" -g2012 -DUE_CGEOM -o "$work/sim_rb1.vvp" "$tb" "$memv" "$work/nl_rb1.v" > "$work/iv_rb1.log" 2>&1 || {
  echo "RESULT: FAIL 突变网表编译失败"; sed -n '1,15p' "$work/iv_rb1.log"; exit 2; }
eval "$(sed 's/^/X_/' "$work/$NEGJOB/job.txt" | tr '\n' ' ')"
( cd "$work" && "$VVP" "$work/sim_rb1.vvp" \
    "+XFILE=$work/$NEGJOB/x.hex" "+WFILE=$work/$NEGJOB/w.hex" "+BFILE=$work/$NEGJOB/b.hex" \
    "+MEMFILE=$work/$NEGJOB/mem.hex" "+DUMPFILE=$work/rb1.dump" +dump +TILED_W "+TMT=$TMT_NEG" \
    "+WBASE=$WBASE" "+WEXP=${X_WEXP}" \
    "+CIN=${X_CIN}" "+COUT=${X_COUT}" "+GROUP=${X_GROUP}" "+H=${X_H}" "+W=${X_W}" "+TYPE=1" "+FLAGS=1" \
    "+SRC=${X_SRC}" "+DST=${X_DST}" "+INB=${X_LEN}" "+QSHIFT=6" "+LID=0" \
    "+M=${X_M}" "+ZPAD=${X_ZPAD}" "+ZY=${X_ZY}" "+NCOL=1" "+NCI=${X_NCI}" "+NCO=${X_NCO}" "+STRIDE=${X_S}" ) \
    > "$work/rb1.log" 2>&1
RB1_TO="$(grep -c 'timeout(宽层多趟等 done/err' "$work/rb1.log")"
grep -m2 '^DBG-PHASE' "$work/rb1.log" | sed 's/^/   /'
RB1_PHASE="$(grep -m1 '^DBG-PHASE' "$work/rb1.log")"
RB1_RDEF="$(printf '%s\n' "$RB1_PHASE" | sed -n 's/.*rd_ready=\([0-9]*\).*/\1/p')"
RB1_DS="$(printf '%s\n' "$RB1_PHASE" | sed -n 's/.*dstate=\([0-9]*\).*/\1/p')"
MEMRB="$(sed -n 's/^MEM rd=\([0-9]*\).*/\1/p' "$work/rb1.log" | head -1)"
if [ "${RB1_TO:-0}" -ge 1 ] 2>/dev/null && [ "${RB1_RDEF:-x}" = "0" ] && [ "${MEMRB:-x}" -ge 128 ] 2>/dev/null; then
  echo "   NEG2_OK: 退回修复-① ⇒ 挂住（timeout）+ DBG-PHASE 显示 rd_ready=0 / dstate=${RB1_DS}（RDSTR 等握手）+ MEM rd=${MEMRB}（只有起始几块）"
else
  echo "NEGCTL-FAIL: 退回修复-① 没发火（timeout=$RB1_TO rd_ready=${RB1_RDEF:-?} MEM rd=${MEMRB:-?}）"
  grep -E '^(RESULT|MEM )' "$work/rb1.log" | tail -3; NEG_NOFIRE=$((NEG_NOFIRE+1))
fi

# -----------------------------------------------------------------------------
# 5) 负对照③：RTL 修复-② 退回（拆掉 `&& (! tilingW)`）⇒ 40×40 必 err；8×32 不提（双侧）
# -----------------------------------------------------------------------------
echo "---- 负对照③：网表突变退回修复-②（WGTRUN 收工判据拆掉 !tilingW）⇒ 40×40 必红 / 8×32 不提 ----"
if ! "$PY" - "$nl" "$work/nl_rb2.v" <<'PYEOF'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = "assign when_UnitExec_l2098 = ((wlWideR && (! wideGeomOk)) && (! tilingW));"
new = "assign when_UnitExec_l2098 = (wlWideR && (! wideGeomOk));"
n = src.count(old)
print("RB2_HITS=%d (期望 1)" % n)
if n != 1: sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PYEOF
then echo "NEGCTL-FAIL: 修复-② 退回的突变锚不唯一"; echo "RESULT: FAIL"; exit 2; fi
"$IVERILOG" -g2012 -DUE_CGEOM -o "$work/sim_rb2.vvp" "$tb" "$memv" "$work/nl_rb2.v" > "$work/iv_rb2.log" 2>&1 || {
  echo "RESULT: FAIL 突变网表编译失败"; sed -n '1,15p' "$work/iv_rb2.log"; exit 2; }
rb2_run() {   # <name> <memfile>
  local name="$1" mf="$2"
  eval "$(sed 's/^/X_/' "$work/$name/job.txt" | tr '\n' ' ')"
  ( cd "$work" && "$VVP" "$work/sim_rb2.vvp" \
      "+XFILE=$work/$name/x.hex" "+WFILE=$work/$name/w.hex" "+BFILE=$work/$name/b.hex" \
      "+MEMFILE=$mf" "+DUMPFILE=$work/${name}_rb2.dump" +dump +TILED_W "+TMT=$TMT_NEG" \
      "+WBASE=$WBASE" "+WEXP=${X_WEXP}" \
      "+CIN=${X_CIN}" "+COUT=${X_COUT}" "+GROUP=${X_GROUP}" "+H=${X_H}" "+W=${X_W}" "+TYPE=1" "+FLAGS=1" \
      "+SRC=${X_SRC}" "+DST=${X_DST}" "+INB=${X_LEN}" "+QSHIFT=6" "+LID=0" \
      "+M=${X_M}" "+ZPAD=${X_ZPAD}" "+ZY=${X_ZY}" "+NCOL=1" "+NCI=${X_NCI}" "+NCO=${X_NCO}" "+STRIDE=${X_S}" ) \
      > "$work/${name}_rb2.log" 2>&1
}
rb2_run "$NEGJOB" "$work/$NEGJOB/mem.hex"
RB2A_ERR="$(sed -n 's/^DONE_SEEN=\([0-9]*\) ERR_SEEN=\([0-9]*\).*/\2/p' "$work/${NEGJOB}_rb2.log" | head -1)"
RB2A_RD="$(sed -n 's/^MEM rd=\([0-9]*\).*/\1/p' "$work/${NEGJOB}_rb2.log" | head -1)"
rb2_run "$NEGJOB2" "$work/$NEGJOB2/mem.hex"
RB2B_ERR="$(sed -n 's/^DONE_SEEN=\([0-9]*\) ERR_SEEN=\([0-9]*\).*/\2/p' "$work/${NEGJOB2}_rb2.log" | head -1)"
RB2B_PASS="$(grep -c '^RESULT: PASS' "$work/${NEGJOB2}_rb2.log")"
eval "$(judge_dst "${NEGJOB2}_rb2" "$NEGJOB2" | sed 's/^/RB2B_/')"
echo "   40×40: ERR_SEEN=${RB2A_ERR:-?}（须 1，MEM rd=${RB2A_RD:-?} = 权重段 ⇒ 装对但被 inWOk err）"
echo "   8×32 : ERR_SEEN=${RB2B_ERR:-?}（须 0）RESULT: PASS×${RB2B_PASS:-?} MISMATCH=${RB2B_MISMATCH:-?}（须 0 ⇒ 32≤34 不提，外科式）"
if [ "${RB2A_ERR:-x}" = "1" ] && [ "${RB2B_ERR:-x}" = "0" ] && [ "${RB2B_PASS:-0}" -ge 1 ] 2>/dev/null && [ "${RB2B_MISMATCH:-x}" = "0" ]; then
  echo "   NEG3_OK: 退回修复-② ⇒ 40×40 响亮 err、8×32 不受影响（双侧断言成立）"
else
  echo "NEGCTL-FAIL: 退回修复-② 的双侧断言不成立（40×40 ERR=${RB2A_ERR:-?} / 8×32 ERR=${RB2B_ERR:-?} PASS=${RB2B_PASS:-?} MISMATCH=${RB2B_MISMATCH:-?}）"
  NEG_NOFIRE=$((NEG_NOFIRE+1))
fi

echo "=========================================================================="
echo "[0] 前置：参考自检 + TILING=false 三网表 md5 不变 + blob→wRam 映射 == weight_tiles()（互证） : OK"
echo "[1] 正对照（tiled 宽 + blob(DDR)，真表几何 ×3）                                       : $pos_ok/3（PASS + DST 逐字节 + wRam 逐字节）"
echo "[2] 负对照① blob 少一个趟瓦片（定位到 co-block 带）                                   : ${X1_N1_MISMATCH:+MISMATCH=${X1_N1_MISMATCH}}（outside=${X1_N1_OUTSIDE:-?}）"
echo "[3] 负对照② 退回修复-①（rd_ready 漏 wlTake）⇒ 挂住                                   : rd_ready=${RB1_RDEF:-?} MEM rd=${MEMRB:-?} timeout=$RB1_TO"
echo "[4] 负对照③ 退回修复-②（WGTRUN 漏 !tilingW）⇒ 40×40 err / 8×32 不提                  : ERR=${RB2A_ERR:-?}/${RB2B_ERR:-?} PASS=${RB2B_PASS:-?}"
if [ "$NEG_NOFIRE" -ne 0 ]; then echo "NEGCTL-FAIL: $NEG_NOFIRE 条负对照没发火 ⇒ 闸门自身不可信"; echo "RESULT: FAIL"; exit 2; fi
if [ "$TOTAL_BAD" -ne 0 ]; then echo "JUDGE-RED: $TOTAL_BAD 条判据未过"; echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
exit 0
